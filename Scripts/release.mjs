#!/usr/bin/env node
// PageYard — интерактивная сборка подписанного и нотаризованного приложения для macOS.
//
//   npm run release              — спросит всё по шагам
//   npm run release -- --yes     — взять сохранённые ответы, спросить только секреты
//   npm run release -- --dry-run — показать план и команды, ничего не выполняя
//
// Секреты (пароли, ключи) никогда не сохраняются. В .release.json (в .gitignore)
// пишутся только ответы вроде Bundle ID, сертификата и способа нотаризации.

import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';
import {
  CERT_ADD_PAGE, createDeveloperIdCert, downloadedCer, importCerWithKey, importP12, installKey, keyIdFromPath, KEYS_PAGE,
  listDeveloperIdCerts, loadTeams, localIdentities, pendingKeys, prepareCsr, saveTeams, usableIdentities, verifyTeam,
} from './apple.mjs';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PLIST = path.join(ROOT, 'Resources', 'Info.plist');
const SETTINGS = path.join(ROOT, '.release.json');
const args = new Set(process.argv.slice(2));
const DRY = args.has('--dry-run');
const YES = args.has('--yes') || args.has('-y');

if (args.has('-h') || args.has('--help')) {
  console.log(`Сборка PageYard для macOS

  npm run release              интерактивно
  npm run release -- --yes     использовать сохранённые ответы
  npm run release -- --dry-run показать план без выполнения`);
  process.exit(0);
}

// ---------- вывод ----------

const tty = process.stdout.isTTY;
const c = (code) => (s) => (tty ? `\x1b[${code}m${s}\x1b[0m` : String(s));
const bold = c('1'), dim = c('2'), red = c('31'), green = c('32'), yellow = c('33'), cyan = c('36');

const step = (n, title) => console.log(`\n${cyan(bold(`[${n}]`))} ${bold(title)}`);
const info = (s) => console.log(`    ${s}`);
const ok = (s) => console.log(`    ${green('✓')} ${s}`);
const warn = (s) => console.log(`    ${yellow('!')} ${s}`);
const fail = (s) => {
  console.error(`\n${red('✗')} ${s}`);
  process.exit(1);
};

// ---------- ввод ----------

const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: !!process.stdin.isTTY });
let muted = false;
const origWrite = rl._writeToOutput.bind(rl);
rl._writeToOutput = (s) => {
  // при вводе секрета эхо подавляется, но перевод строки показываем
  if (!muted) return origWrite(s);
  if (s.includes('\n') || s.includes('\r')) origWrite('\n');
};

// очередь строк: при вводе через pipe readline читает всё сразу, и rl.question терял бы ответы
const pending = [];
let waiter = null;
let inputClosed = false;
rl.on('line', (l) => {
  if (waiter) {
    const w = waiter;
    waiter = null;
    w(l);
  } else pending.push(l);
});
rl.on('close', () => {
  inputClosed = true;
  if (waiter) waiter(null);
});

function question(q, { secret = false } = {}) {
  rl.setPrompt(q);
  rl.prompt();
  muted = secret;
  return new Promise((resolve) => {
    const done = (v) => {
      muted = false;
      if (v === null) fail('Ввод закончился раньше, чем были заданы все вопросы');
      resolve(v);
    };
    if (pending.length) done(pending.shift());
    else if (inputClosed) done(null);
    else waiter = done;
  });
}

async function ask(label, def = '', { required = true, validate } = {}) {
  for (;;) {
    const v = (await question(`    ${label}${def ? dim(` [${def}]`) : ''}: `)).trim() || def;
    if (!v && required) {
      warn('Нужно значение');
      continue;
    }
    const err = validate?.(v);
    if (err) {
      warn(err);
      continue;
    }
    return v;
  }
}

async function askSecret(label) {
  return (await question(`    ${label}: `, { secret: true })).trim();
}

async function confirm(label, def = true) {
  const v = (await question(`    ${label} ${dim(def ? '[Д/н]' : '[д/Н]')}: `)).trim().toLowerCase();
  if (!v) return def;
  return ['д', 'да', 'y', 'yes'].includes(v);
}

async function choose(label, options, defIndex = 0) {
  console.log(`    ${label}`);
  options.forEach((o, i) => console.log(`      ${i === defIndex ? cyan('›') : ' '} ${bold(i + 1)}. ${o.label}${o.hint ? dim(`  — ${o.hint}`) : ''}`));
  for (;;) {
    const v = (await question(`    Выбор ${dim(`[${defIndex + 1}]`)}: `)).trim();
    const n = v ? Number(v) - 1 : defIndex;
    if (Number.isInteger(n) && n >= 0 && n < options.length) return options[n].value;
    warn(`Введите число от 1 до ${options.length}`);
  }
}

// ---------- команды ----------

function sh(cmd, argv, opts = {}) {
  return spawnSync(cmd, argv, { encoding: 'utf8', cwd: ROOT, ...opts });
}

/** Команда с выводом в терминал; при --dry-run только печатается. */
function run(cmd, argv, { env, cwd = ROOT, secretArgs = [] } = {}) {
  const shown = argv.map((a) => (secretArgs.includes(a) ? '••••' : /\s/.test(a) ? JSON.stringify(a) : a)).join(' ');
  console.log(dim(`    $ ${cmd} ${shown}`));
  if (DRY) return Promise.resolve(0);
  return new Promise((resolve, reject) => {
    const p = spawn(cmd, argv, { cwd, env: { ...process.env, ...env }, stdio: 'inherit' });
    p.on('exit', (code) => (code === 0 ? resolve(0) : reject(new Error(`${cmd} завершился с кодом ${code}`))));
    p.on('error', reject);
  });
}

function have(cmd) {
  return sh('/usr/bin/which', [cmd]).status === 0;
}

// ---------- настройки ----------

const saved = (() => {
  try {
    return JSON.parse(fs.readFileSync(SETTINGS, 'utf8'));
  } catch {
    return {};
  }
})();

function readJson(p) {
  return JSON.parse(fs.readFileSync(p, 'utf8'));
}

function bumpVersion(v, kind) {
  const [maj, min, pat] = v.split('-')[0].split('.').map(Number);
  if (kind === 'major') return `${maj + 1}.0.0`;
  if (kind === 'minor') return `${maj}.${min + 1}.0`;
  return `${maj}.${min}.${pat + 1}`;
}

const SEMVER = /^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/;

function setVersion(v) {
  const pkgPath = path.join(ROOT, 'package.json');
  const pkg = readJson(pkgPath);
  pkg.version = v;
  fs.writeFileSync(pkgPath, JSON.stringify(pkg, null, 2) + '\n');
  // версия, которую видит macOS («О программе», Finder)
  sh('/usr/libexec/PlistBuddy', ['-c', `Set :CFBundleShortVersionString ${v}`, PLIST]);
}


function profileWorks(name) {
  return sh('xcrun', ['notarytool', 'history', '--keychain-profile', name, '--output-format', 'json']).status === 0;
}

// ---------- организации Apple ----------

/** Самый свежий AuthKey_*.p8 в «Загрузках» — подставляется по умолчанию. */
function downloadedKey() {
  const dir = path.join(os.homedir(), 'Downloads');
  try {
    return fs.readdirSync(dir)
      .filter((f) => /^AuthKey_[A-Z0-9]+\.p8$/i.test(f))
      .map((f) => ({ f: path.join(dir, f), t: fs.statSync(path.join(dir, f)).mtimeMs }))
      .sort((a, b) => b.t - a.t)[0]?.f ?? '';
  } catch {
    return '';
  }
}

const exists = (v) => (fs.existsSync(v.replace(/^~/, os.homedir())) ? null : 'Файл не найден');

/** Добавление организации: ключ App Store Connect API, проверка запросом к Apple. */
async function addTeam(teams) {
  info(bold('Ключ App Store Connect API — один раз на организацию:'));
  info(`1. Откройте ${cyan(KEYS_PAGE)}`);
  info('   (если у вас несколько организаций — выберите нужную в переключателе вверху справа)');
  info('2. «Team Keys» → «+» → любое имя, роль Admin → Generate');
  info('3. Скачайте AuthKey_XXXXXXXXXX.p8 (Apple даёт скачать его только один раз)');
  info('4. Скопируйте Issuer ID — он над таблицей ключей');
  info(dim('   Выпуск сертификатов Developer ID Apple обычно разрешает только владельцу аккаунта (Account Holder).'));
  if (!DRY && (await confirm('Открыть страницу в браузере?', true))) sh('open', [KEYS_PAGE]);
  const p8 = await ask('Путь к AuthKey_XXXX.p8', downloadedKey(), { validate: exists });
  const keyId = await ask('Key ID', keyIdFromPath(p8), { validate: (v) => (/^[A-Z0-9]{10}$/.test(v) ? null : '10 символов, например 2X9R4HXF34') });
  const issuerId = await ask('Issuer ID', '', {
    validate: (v) => (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v) ? null : 'UUID вида 57246542-96fe-1a63-e053-0824d011072a'),
  });
  const name = await ask('Как назвать организацию в списке', `Организация ${teams.length + 1}`);
  const team = { name, issuerId, keyId, keyPath: DRY ? p8 : installKey(p8, keyId) };
  if (!DRY) {
    info('Проверяю ключ…');
    try {
      await verifyTeam(team);
    } catch (e) {
      fail(`Apple не приняла ключ: ${e.message}\n  Проверьте Issuer ID и Key ID, и что ключ не отозван.`);
    }
    saveTeams([...loadTeams().filter((t) => t.keyId !== keyId), team]);
    ok(`Ключ работает, организация «${name}» сохранена (${team.keyPath.replace(os.homedir(), '~')})`);
  }
  return team;
}

function updateTeam(team) {
  saveTeams(loadTeams().map((t) => (t.keyId === team.keyId ? team : t)));
}

/** Сертификат Developer ID организации на этом Mac: найти или выпустить через API. */
async function teamIdentity(team) {
  if (DRY) {
    info('--dry-run: сертификат не проверяется');
    return { name: `Developer ID Application: ${team.name} (${team.teamId ?? 'TEAMID'})`, team: team.teamId ?? '' };
  }
  info('Ищу сертификаты Developer ID организации…');
  let usable;
  try {
    usable = await usableIdentities(team);
  } catch (e) {
    fail(`Apple: ${e.message}`);
  }
  let identity = null;
  if (usable.length === 1) identity = usable[0];
  else if (usable.length > 1) {
    identity = await choose('Найдено несколько сертификатов — какой использовать?', usable.map((u) => ({ label: u.name, value: u, hint: `действует до ${String(u.expires).slice(0, 10)}` })), 0);
  } else {
    const remote = await listDeveloperIdCerts(team);
    if (remote.length) warn(`У организации есть сертификаты Developer ID (${remote.length}), но закрытых ключей к ним на этом Mac нет`);
    else warn('У организации ещё нет сертификата Developer ID Application');
    identity = await obtainCertificate(team);
  }
  if (identity.team && team.teamId !== identity.team) {
    team.teamId = identity.team;
    updateTeam(team);
  }
  ok(identity.name);
  return identity;
}

/** Как получить Developer ID, если на этом Mac его нет: меню повторяется до успеха или отмены. */
async function obtainCertificate(team) {
  const email = () => sh('git', ['config', 'user.email']).stdout?.trim() ?? '';
  for (;;) {
    const pending = pendingKeys();
    const options = [
      ...(pending.length ? [{ label: 'Завершить выпуск: подключить скачанный .cer', value: 'cer', hint: 'запрос (CSR) уже создан раньше' }] : []),
      ...(!team.devIdForbidden ? [{ label: 'Выпустить автоматически через API', value: 'create', hint: 'сработает, если ключ создан владельцем аккаунта' }] : []),
      { label: 'Выпустить через сайт Apple', value: 'web', hint: 'вход на developer.apple.com под владельцем аккаунта, 3 клика' },
      { label: 'Импортировать .p12', value: 'p12', hint: 'если сертификат прислали или он есть на другом Mac' },
      { label: 'Проверить снова', value: 'recheck', hint: 'если сертификат уже выпустили в Xcode или на сайте' },
      { label: 'Отмена', value: 'cancel' },
    ];
    const how = await choose('Как получить сертификат?', options, 0);
    try {
      if (how === 'cancel') fail('Отменено');
      if (how === 'create') {
        const id = await createDeveloperIdCert(team, { email: await ask('Email в сертификате', email()), commonName: `${team.name} Developer ID` }, ok);
        keyWarning();
        return id;
      }
      if (how === 'web') {
        const { keyPath, csrPath } = prepareCsr({ email: await ask('Email в сертификате', email()), commonName: `${team.name} Developer ID` });
        ok(`Запрос на сертификат: ${csrPath.replace(os.homedir(), '~')}`);
        info(bold('На сайте Apple (под владельцем аккаунта):'));
        info('1. Developer ID Application → Continue');
        info('2. Profile Type: G2 Sub-CA → Choose File → выберите файл запроса (он на рабочем столе) → Continue');
        info('3. Download — сертификат скачается в «Загрузки»');
        sh('open', [CERT_ADD_PAGE]);
        sh('open', ['-R', csrPath]);
        await question(`    ${dim('Нажмите Enter, когда .cer скачан…')}`);
        const cer = await ask('Путь к скачанному .cer', downloadedCer(), { validate: exists });
        const id = await importCerWithKey(cer, keyPath, ok);
        fs.rmSync(csrPath, { force: true });
        keyWarning();
        return id;
      }
      if (how === 'cer') {
        const cer = await ask('Путь к скачанному .cer', downloadedCer(), { validate: exists });
        // к сертификату подойдёт только один из ожидающих ключей — пробуем по очереди
        let lastErr = null;
        for (const keyPath of pending) {
          try {
            const id = await importCerWithKey(cer, keyPath, ok);
            keyWarning();
            return id;
          } catch (e) {
            lastErr = e;
          }
        }
        throw lastErr ?? new Error('Нет подходящего ключа');
      }
      if (how === 'p12') {
        const p12 = await ask('Путь к .p12', '', { validate: exists });
        importP12(p12, await askSecret('Пароль от .p12 (ввод скрыт)'));
        const after = await usableIdentities(team);
        if (after.length) return after[0];
        warn('Этот .p12 не относится к выбранной организации');
        continue;
      }
      if (how === 'recheck') {
        const after = await usableIdentities(team);
        if (after.length) return after[0];
        warn('Сертификат Developer ID этой организации в связке ключей пока не найден');
      }
    } catch (e) {
      if (e.forbidden) {
        // запоминаем: этой организации автоматический выпуск больше не предлагаем
        team.devIdForbidden = true;
        updateTeam(team);
      }
      warn(e.message);
    }
  }
}

function keyWarning() {
  warn('Закрытый ключ сертификата есть только в связке ключей этого Mac.');
  info('Для сборки на другом Mac: «Связка ключей» → «Мои сертификаты» → сертификат → «Экспортировать» (.p12).');
  info('macOS при первой подписи спросит доступ к ключу — нажмите «Всегда разрешать».');
}

/** Ручной режим: сертификат из связки ключей или импорт .p12. */
async function manualIdentity() {
  let ids = localIdentities();
  if (!ids.length && !DRY && (await confirm('В связке ключей нет сертификатов подписи. Импортировать .p12?', true))) {
    const p12 = await ask('Путь к .p12', '', { validate: exists });
    try {
      importP12(p12, await askSecret('Пароль от .p12 (ввод скрыт)'));
    } catch (e) {
      fail(`Не удалось импортировать: ${e.message}`);
    }
    ids = localIdentities();
  }
  const options = [
    ...ids.map((i) => ({ label: i.name, value: i, hint: i.name.startsWith('Developer ID Application') ? 'для распространения' : 'не подходит для нотаризации' })),
    { label: 'Без подписи', value: null },
  ];
  const idx = options.findIndex((o) => o.value && o.value.name === saved.identity);
  const identity = YES && idx >= 0 ? options[idx].value : await choose('Чем подписать?', options, Math.max(0, idx));
  if (identity) ok(identity.name);
  return identity;
}

/** Ручная нотаризация: профиль notarytool или Apple ID с паролем приложения. */
async function manualNotary(identity) {
  if (!identity.name.startsWith('Developer ID Application')) {
    info('Нотаризация доступна только с сертификатом Developer ID Application');
    return { method: 'none' };
  }
  const methods = [
    { label: 'Профиль в связке ключей (notarytool)', value: 'profile', hint: 'пароль хранит macOS' },
    { label: 'Apple ID + пароль приложения', value: 'appleid', hint: 'appleid.apple.com → Пароли приложений' },
    { label: 'Не нотаризовать', value: 'none' },
  ];
  const savedM = methods.findIndex((m) => m.value === saved.notaryMethod);
  const method = YES && savedM >= 0 ? methods[savedM].value : await choose('Как нотаризовать?', methods, Math.max(0, savedM));
  if (method === 'profile') {
    const profile = YES && saved.notaryProfile ? saved.notaryProfile : await ask('Имя профиля', saved.notaryProfile ?? 'pageyard-notary');
    if (!DRY && !profileWorks(profile)) {
      warn(`Профиль «${profile}» не найден — создадим (notarytool спросит пароль приложения)`);
      const appleId = await ask('Apple ID (email)', saved.appleId ?? '');
      await run('xcrun', ['notarytool', 'store-credentials', profile, '--apple-id', appleId, '--team-id', identity.team]);
      saved.appleId = appleId;
    }
    saved.notaryProfile = profile;
    return { method, profile };
  }
  if (method === 'appleid') {
    const appleId = YES && saved.appleId ? saved.appleId : await ask('Apple ID (email)', saved.appleId ?? '');
    saved.appleId = appleId;
    return { method, appleId, password: await askSecret('Пароль приложения (не пароль Apple ID; ввод скрыт)'), team: identity.team };
  }
  return { method: 'none' };
}

// ---------- публикация на GitHub ----------

/** Раздел CHANGELOG.md для версии (между «## [x.y.z]» и следующим «## »). */
function changelogSection(version) {
  try {
    const text = fs.readFileSync(path.join(ROOT, 'CHANGELOG.md'), 'utf8');
    const esc = version.replace(/\./g, '\\.');
    const m = text.match(new RegExp(`^## \\[?${esc}\\]?[^\\n]*\\n([\\s\\S]*?)(?=^## |^\\[[^\\]]+\\]:|$(?![\\s\\S]))`, 'm'));
    return m ? m[1].trim() : null;
  } catch {
    return null;
  }
}

/** Публикация релиза через GitHub CLI: тег, описание из CHANGELOG, файлы. */
async function publishGithub({ version, productName, files, gitTagCreated }) {
  const remote = sh('git', ['remote', 'get-url', 'origin']).stdout?.trim() ?? '';
  if (!/github\.com/.test(remote)) return;
  if (!have('gh')) {
    info(dim('Публикация на GitHub: установите GitHub CLI (brew install gh) и войдите (gh auth login)'));
    return;
  }
  if (sh('gh', ['auth', 'status']).status !== 0) {
    warn('GitHub CLI не авторизован — выполните gh auth login, чтобы публиковать релизы отсюда');
    return;
  }
  step(13, 'GitHub');
  const tag = `v${version}`;
  const publish = YES && saved.githubPublish !== undefined ? saved.githubPublish : await confirm(`Опубликовать релиз ${tag} на GitHub?`, saved.githubPublish ?? true);
  saved.githubPublish = publish;
  if (!DRY) fs.writeFileSync(SETTINGS, JSON.stringify(saved, null, 2) + '\n');
  if (!publish) return;
  const draft = YES ? !!saved.githubDraft : await confirm('Черновиком (опубликуете сами на сайте)?', saved.githubDraft ?? false);
  saved.githubDraft = draft;
  if (!DRY) fs.writeFileSync(SETTINGS, JSON.stringify(saved, null, 2) + '\n');

  let notes = changelogSection(version);
  if (!notes) {
    warn(`В CHANGELOG.md нет раздела «## [${version}]» — в описание пойдёт короткий текст`);
    notes = `${productName} ${version}\n\nПодписано Developer ID и нотаризовано Apple.\n\nПроверка: \`shasum -a 256 -c SHA256SUMS\``;
  }
  const notesFile = path.join(os.tmpdir(), `release-notes-${process.pid}.md`);
  if (!DRY) fs.writeFileSync(notesFile, notes + '\n');

  // тег — если инструмент не создал его на шаге git
  const hasTag = sh('git', ['rev-parse', '-q', '--verify', `refs/tags/${tag}`]).status === 0;
  if (!hasTag && !gitTagCreated) await run('git', ['tag', '-a', tag, '-m', `${productName} ${version}`]);
  await run('git', ['push', 'origin', 'HEAD']);
  await run('git', ['push', 'origin', tag]);

  const exists = !DRY && sh('gh', ['release', 'view', tag]).status === 0;
  if (exists) {
    if (!(await confirm(`Релиз ${tag} уже есть. Перезалить файлы?`, true))) return;
    await run('gh', ['release', 'upload', tag, ...files, '--clobber']);
  } else {
    await run('gh', ['release', 'create', tag, ...files, '--title', `${productName} ${version}`, '--notes-file', notesFile, ...(draft ? ['--draft'] : [])]);
  }
  if (!DRY) fs.rmSync(notesFile, { force: true });
  const url = sh('gh', ['release', 'view', tag, '--json', 'url', '-q', '.url']).stdout?.trim();
  ok(`Релиз ${draft ? '(черновик) ' : ''}на GitHub${url ? `: ${url}` : ''}`);
}

// ---------- шаги ----------

async function main() {
  console.log(bold('\nPageYard — сборка подписанного приложения для macOS'));
  if (DRY) console.log(yellow('    Режим --dry-run: команды будут только показаны'));

  // 1. окружение
  step(1, 'Проверка окружения');
  if (process.platform !== 'darwin') fail('Сборка под macOS возможна только на macOS');
  for (const [cmd, hint] of [
    ['swift', 'установите Xcode Command Line Tools: xcode-select --install'],
    ['lipo', 'нужны Xcode Command Line Tools'],
    ['xcrun', 'установите Xcode Command Line Tools: xcode-select --install'],
    ['codesign', 'нужны Xcode Command Line Tools'],
    ['hdiutil', 'системная утилита macOS'],
  ]) {
    if (!have(cmd)) fail(`Не найдено: ${cmd} — ${hint}`);
  }
  if (sh('xcrun', ['notarytool', '--version']).status !== 0) warn('notarytool не найден — нотаризация будет недоступна (нужен Xcode 13+ или свежие CLT)');
  if (!fs.existsSync(path.join(ROOT, 'vendor', 'mupdf', 'lib', 'libmupdf.a'))) {
    info('MuPDF ещё не собран — собираю (несколько минут, один раз)');
    await run('./Scripts/build_mupdf.sh', []);
  }
  const dirty = sh('git', ['status', '--porcelain']).stdout?.trim();
  if (dirty) warn('В рабочей копии есть незакоммиченные изменения — они попадут в сборку');
  ok('Окружение в порядке');

  // 2. версия
  step(2, 'Версия');
  const current = readJson(path.join(ROOT, 'package.json')).version;
  let version = current;
  if (!YES) {
    const kind = await choose(`Текущая версия ${bold(current)}. Какой будет новая?`, [
      { label: `Оставить ${current}`, value: 'keep' },
      { label: `Исправления → ${bumpVersion(current, 'patch')}`, value: 'patch', hint: 'patch' },
      { label: `Новые функции → ${bumpVersion(current, 'minor')}`, value: 'minor', hint: 'minor' },
      { label: `Крупный релиз → ${bumpVersion(current, 'major')}`, value: 'major', hint: 'major' },
      { label: 'Ввести вручную', value: 'custom' },
    ]);
    if (kind === 'custom') version = await ask('Версия (semver, например 1.2.0)', current, { validate: (v) => (SEMVER.test(v) ? null : 'Формат X.Y.Z') });
    else if (kind !== 'keep') version = bumpVersion(current, kind);
  }
  ok(`Версия ${version}`);

  // 3. метаданные приложения
  step(3, 'Приложение');
  const productName = 'PageYard';
  let identifier = saved.identifier ?? 'com.zed.pageyard';
  let copyright = saved.copyright ?? `© ${new Date().getFullYear()}`;
  if (!YES) {
    identifier = await ask('Bundle ID (обратный домен, уникальный)', identifier, {
      validate: (v) => (/^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/.test(v) ? null : 'Формат com.company.app'),
    });
    copyright = await ask('Копирайт (показывается в «О программе» Finder)', copyright);
  }
  ok(`${productName} · ${identifier} · macOS 13+`);

  // 4. архитектура
  step(4, 'Архитектура');
  const archs = [
    { label: 'Universal (arm64 + x86_64)', value: 'universal', hint: 'один файл для всех Mac' },
    { label: 'Apple Silicon (arm64)', value: 'arm64', hint: 'M1 и новее' },
    { label: 'Intel (x86_64)', value: 'x86_64' },
  ];
  const target = YES && saved.target ? saved.target : await choose('Под какие Mac собирать?', archs, Math.max(0, archs.findIndex((a) => a.value === saved.target)));
  ok(target);

  // 5. аккаунт Apple: сертификат и нотаризация
  step(5, 'Аккаунт Apple');
  let identity = null;
  let notary = { method: 'none' };
  const teams = loadTeams();
  const accOptions = [
    ...teams.map((t) => ({ label: t.name, value: { kind: 'team', team: t }, hint: `${t.teamId ? `Team ID ${t.teamId} · ` : ''}ключ ${t.keyId}` })),
    { label: 'Добавить организацию', value: { kind: 'add' }, hint: 'ключ App Store Connect API — сертификат и нотаризация автоматически' },
    { label: 'Вручную', value: { kind: 'manual' }, hint: 'сертификат из связки ключей или .p12, нотаризация паролем' },
    { label: 'Без подписи', value: { kind: 'none' }, hint: 'только для проверки, Gatekeeper будет ругаться' },
  ];
  const savedAcc = accOptions.findIndex((o) => (o.value.kind === 'team' ? o.value.team.keyId === saved.teamKeyId : o.value.kind === saved.account));
  let acc = YES && savedAcc >= 0 ? accOptions[savedAcc].value : await choose('От какой организации подписывать?', accOptions, savedAcc >= 0 ? savedAcc : 0);
  if (acc.kind === 'add') acc = { kind: 'team', team: await addTeam(teams) };
  if (acc.kind === 'team') {
    identity = await teamIdentity(acc.team);
    notary = { method: 'apikey', keyPath: acc.team.keyPath, keyId: acc.team.keyId, issuer: acc.team.issuerId };
    saved.account = 'team';
    saved.teamKeyId = acc.team.keyId;
    ok('Нотаризация — тем же ключом API');
  } else if (acc.kind === 'manual') {
    identity = await manualIdentity();
    notary = identity ? await manualNotary(identity) : notary;
    saved.account = 'manual';
  } else {
    saved.account = 'none';
    warn('Сборка без подписи');
  }

  // 7. git
  let gitTag = false;
  if (version !== current && sh('git', ['rev-parse', '--git-dir']).status === 0 && !YES) {
    gitTag = await confirm(`После сборки закоммитить версию и поставить тег v${version}?`, true);
  }

  // сводка
  step(6, 'Сводка');
  info(`Приложение:   ${bold(productName)} ${version}  (${identifier})`);
  info(`Архитектура:  ${target}`);
  info(`Подпись:      ${identity ? identity.name : red('нет')}`);
  info(`Нотаризация:  ${notary.method === 'none' ? yellow('нет') : { apikey: 'ключ API организации', profile: `профиль «${notary.profile}»`, appleid: 'Apple ID' }[notary.method]}`);
  info(`Результат:    release/${version}/`);
  if (have('gh') && /github\.com/.test(sh('git', ['remote', 'get-url', 'origin']).stdout ?? '')) info(`GitHub:       спрошу в конце, публиковать ли релиз v${version}`);
  if (!YES && !(await confirm('Собираем?', true))) {
    rl.close();
    return;
  }

  // сохраняем ответы без секретов
  Object.assign(saved, {
    identifier, copyright, target,
    identity: identity ? identity.name : null,
    notaryMethod: notary.method === 'apikey' && saved.account === 'team' ? saved.notaryMethod : notary.method,
    notaryProfile: notary.profile ?? saved.notaryProfile,
  });
  if (!DRY) fs.writeFileSync(SETTINGS, JSON.stringify(saved, null, 2) + '\n');
  if (version !== current && !DRY) setVersion(version);

  // 8. сборка
  step(7, 'Сборка');
  const buildDir = path.join(ROOT, 'build', 'release');
  await run('./Scripts/build_app.sh', [], {
    env: {
      VERSION: version,
      BUNDLE_ID: identifier,
      COPYRIGHT: copyright,
      ARCHS: target === 'universal' ? 'arm64 x86_64' : target,
      SIGN_IDENTITY: identity ? identity.name : '-',
      OUT_DIR: buildDir,
    },
  });
  const appPath = path.join(buildDir, `${productName}.app`);
  if (!DRY && !fs.existsSync(appPath)) fail(`Не найден результат сборки: ${appPath}`);
  ok(appPath.replace(ROOT + '/', ''));

  // 9. проверка подписи
  if (identity) {
    step(8, 'Проверка подписи');
    await run('codesign', ['--verify', '--deep', '--strict', '--verbose=2', appPath]);
    if (!DRY) {
      const d = sh('codesign', ['-dv', '--verbose=4', appPath]).stderr;
      const flags = d.match(/flags=0x[0-9a-f]+\(([^)]*)\)/)?.[1] ?? '';
      if (!flags.includes('runtime')) warn('Hardened Runtime не включён — нотаризация не пройдёт');
      else ok('Hardened Runtime включён');
      const team = d.match(/TeamIdentifier=(\S+)/)?.[1];
      if (team) ok(`Team ID ${team}`);
    }
  }

  const notaryArgs = () => {
    if (notary.method === 'profile') return ['--keychain-profile', notary.profile];
    if (notary.method === 'appleid') return ['--apple-id', notary.appleId, '--password', notary.password, '--team-id', notary.team];
    return ['--key', notary.keyPath, '--key-id', notary.keyId, '--issuer', notary.issuer];
  };

  async function notarize(file, what) {
    info(`Отправка ${what} в Apple (обычно 1–10 минут)…`);
    const argv = ['notarytool', 'submit', file, ...notaryArgs(), '--wait', '--output-format', 'json'];
    console.log(dim(`    $ xcrun ${argv.map((a) => (a === notary.password ? '••••' : a)).join(' ')}`));
    if (DRY) return;
    const r = sh('xcrun', argv, { maxBuffer: 16 * 1024 * 1024 });
    let res = {};
    try {
      res = JSON.parse(r.stdout);
    } catch {
      fail(`notarytool: ${r.stderr || r.stdout}`);
    }
    if (res.status !== 'Accepted') {
      // журнал Apple объясняет, что именно не так (неподписанный бинарник, нет runtime и т.п.)
      const log = sh('xcrun', ['notarytool', 'log', res.id, ...notaryArgs()]).stdout;
      console.error(log);
      fail(`Нотаризация ${what}: ${res.status ?? 'ошибка'} — журнал выше`);
    }
    ok(`${what}: Accepted (${res.id})`);
  }

  // 10. нотаризация .app
  const outDir = path.join(ROOT, 'release', version);
  if (!DRY) fs.mkdirSync(outDir, { recursive: true });
  const arch = { arm64: 'arm64', x86_64: 'x64', universal: 'universal' }[target];
  const base = `${productName}_${version}_${arch}`;
  if (notary.method !== 'none') {
    step(9, 'Нотаризация приложения');
    const zipForNotary = path.join(os.tmpdir(), `${base}-notary.zip`);
    await run('ditto', ['-c', '-k', '--keepParent', appPath, zipForNotary]);
    await notarize(zipForNotary, 'приложение');
    if (!DRY) fs.rmSync(zipForNotary, { force: true });
    await run('xcrun', ['stapler', 'staple', appPath]);
    await run('xcrun', ['stapler', 'validate', appPath]);
  }

  // 11. образ диска и архив
  step(10, 'Образ диска и архив');
  const zipPath = path.join(outDir, `${base}.zip`);
  await run('ditto', ['-c', '-k', '--keepParent', appPath, zipPath]);
  const dmgPath = path.join(outDir, `${base}.dmg`);
  await run('./Scripts/make_dmg.sh', [appPath, dmgPath, `${productName} ${version}`]);
  if (identity) await run('codesign', ['--force', '--sign', identity.name, '--timestamp', dmgPath]);
  if (notary.method !== 'none') {
    await notarize(dmgPath, 'образ диска');
    await run('xcrun', ['stapler', 'staple', dmgPath]);
  }

  // 12. Gatekeeper
  if (identity && !DRY) {
    step(11, 'Проверка Gatekeeper');
    const a = sh('spctl', ['-a', '-vvv', '-t', 'exec', appPath]);
    const dmg = sh('spctl', ['-a', '-vvv', '-t', 'open', '--context', 'context:primary-signature', dmgPath]);
    (a.status === 0 ? ok : warn)(`Приложение: ${(a.stderr || a.stdout).trim().split('\n').slice(0, 2).join(' · ')}`);
    (dmg.status === 0 ? ok : warn)(`Образ: ${(dmg.stderr || dmg.stdout).trim().split('\n').slice(0, 2).join(' · ')}`);
    if (notary.method === 'none') info('Без нотаризации Gatekeeper на других Mac отклонит приложение — это ожидаемо');
  }

  // контрольные суммы
  if (!DRY) {
    const sums = [zipPath, dmgPath]
      .map((f) => `${sh('shasum', ['-a', '256', f]).stdout.split(' ')[0]}  ${path.basename(f)}`)
      .join('\n');
    fs.writeFileSync(path.join(outDir, 'SHA256SUMS'), sums + '\n');
  }

  // 13. git
  if (gitTag) {
    step(12, 'Git');
    await run('git', ['add', 'package.json', 'Resources/Info.plist']);
    await run('git', ['commit', '-m', `Версия ${version}`]);
    await run('git', ['tag', '-a', `v${version}`, '-m', `${productName} ${version}`]);
    info(`Отправить: git push && git push origin v${version}`);
  }

  // 13. GitHub
  await publishGithub({ version, productName, files: [dmgPath, zipPath, path.join(outDir, 'SHA256SUMS')], gitTagCreated: gitTag });

  console.log(`\n${green(bold('Готово.'))} Файлы в ${bold(path.relative(ROOT, outDir) + '/')}:`);
  console.log(`    ${path.basename(dmgPath)}  — для раздачи пользователям`);
  console.log(`    ${path.basename(zipPath)}  — архив приложения`);
  console.log('    SHA256SUMS');
  rl.close();
}

main().catch((e) => {
  rl.close();
  fail(e.message ?? String(e));
});
