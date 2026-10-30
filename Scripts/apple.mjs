// Работа с Apple через официальный App Store Connect API: организации (ключи API),
// сертификаты Developer ID Application, связка ключей macOS, нотаризация.
//
// Модуль не зависит от типа проекта (Tauri, Electron, Xcode) — его можно копировать
// в другие проекты как есть. Без внешних зависимостей: Node 18+, openssl, security, xcrun.
//
// Хранение:
//   ~/.config/apple-signing/teams.json        — список организаций (без секретов)
//   ~/.appstoreconnect/private_keys/AuthKey_*.p8 — ключи API (стандартное место notarytool)

import { spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const API = 'https://api.appstoreconnect.apple.com/v1';
export const TEAMS_FILE = path.join(os.homedir(), '.config', 'apple-signing', 'teams.json');
export const KEYS_DIR = path.join(os.homedir(), '.appstoreconnect', 'private_keys');
export const KEYS_PAGE = 'https://appstoreconnect.apple.com/access/integrations/api';
const KEYCHAIN = path.join(os.homedir(), 'Library', 'Keychains', 'login.keychain-db');
// системный LibreSSL: его .p12 гарантированно понимает `security import`
const OPENSSL = fs.existsSync('/usr/bin/openssl') ? '/usr/bin/openssl' : 'openssl';

/**
 * @typedef {{ name: string, issuerId: string, keyId: string, keyPath: string, teamId?: string }} Team
 */

function sh(cmd, args, opts = {}) {
  return spawnSync(cmd, args, { encoding: 'utf8', ...opts });
}

// ---------- организации ----------

/** @returns {Team[]} */
export function loadTeams() {
  try {
    return JSON.parse(fs.readFileSync(TEAMS_FILE, 'utf8'));
  } catch {
    return [];
  }
}

/** @param {Team[]} teams */
export function saveTeams(teams) {
  fs.mkdirSync(path.dirname(TEAMS_FILE), { recursive: true });
  fs.writeFileSync(TEAMS_FILE, JSON.stringify(teams, null, 2) + '\n', { mode: 0o600 });
}

/** Кладёт .p8 в стандартную папку с правами 600 и возвращает новый путь. */
export function installKey(srcPath, keyId) {
  const src = srcPath.replace(/^~/, os.homedir());
  fs.mkdirSync(KEYS_DIR, { recursive: true, mode: 0o700 });
  const dst = path.join(KEYS_DIR, `AuthKey_${keyId}.p8`);
  if (path.resolve(src) !== path.resolve(dst)) fs.copyFileSync(src, dst);
  fs.chmodSync(dst, 0o600);
  return dst;
}

/** Key ID из имени файла AuthKey_XXXXXXXXXX.p8. */
export function keyIdFromPath(p) {
  return path.basename(p).match(/AuthKey_([A-Z0-9]+)\.p8$/i)?.[1]?.toUpperCase() ?? '';
}

// ---------- App Store Connect API ----------

const b64url = (buf) => Buffer.from(buf).toString('base64').replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');

/** JWT для App Store Connect API (ES256, живёт 15 минут). */
export function ascToken(team) {
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: 'ES256', kid: team.keyId, typ: 'JWT' }));
  const payload = b64url(JSON.stringify({ iss: team.issuerId, iat: now, exp: now + 900, aud: 'appstoreconnect-v1' }));
  const key = fs.readFileSync(team.keyPath, 'utf8');
  const sig = crypto.sign('sha256', Buffer.from(`${header}.${payload}`), { key, dsaEncoding: 'ieee-p1363' });
  return `${header}.${payload}.${b64url(sig)}`;
}

export class AppleApiError extends Error {
  constructor(status, body) {
    const e = body?.errors?.[0];
    super(e ? `${e.title}: ${e.detail ?? ''}`.trim() : `HTTP ${status}`);
    this.status = status;
    this.code = e?.code;
    this.body = body;
  }
}

export async function asc(team, method, url, body) {
  const res = await fetch(url.startsWith('http') ? url : API + url, {
    method,
    headers: { Authorization: `Bearer ${ascToken(team)}`, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  const json = text ? JSON.parse(text) : {};
  if (!res.ok) throw new AppleApiError(res.status, json);
  return json;
}

/** Проверяет, что ключ рабочий. Бросает AppleApiError с понятным текстом. */
export async function verifyTeam(team) {
  if (!fs.existsSync(team.keyPath)) throw new Error(`Нет файла ключа ${team.keyPath}`);
  await asc(team, 'GET', '/certificates?limit=1');
}

const sha1 = (der) => crypto.createHash('sha1').update(der).digest('hex').toUpperCase();

/** Сертификаты Developer ID Application организации (с отпечатками SHA-1). */
export async function listDeveloperIdCerts(team) {
  const out = [];
  let url = '/certificates?limit=200';
  while (url) {
    const page = await asc(team, 'GET', url);
    for (const c of page.data ?? []) {
      const a = c.attributes ?? {};
      if (!String(a.certificateType ?? '').startsWith('DEVELOPER_ID_APPLICATION')) continue;
      const der = a.certificateContent ? Buffer.from(a.certificateContent, 'base64') : null;
      out.push({ id: c.id, name: a.name ?? a.displayName, type: a.certificateType, expires: a.expirationDate, serial: a.serialNumber, sha1: der ? sha1(der) : null, der });
    }
    url = page.links?.next ?? null;
  }
  return out.sort((x, y) => String(y.expires).localeCompare(String(x.expires)));
}

// ---------- связка ключей ----------

/** Identity для подписи кода из связки ключей: { hash, name, team }. */
export function localIdentities() {
  const out = sh('security', ['find-identity', '-v', '-p', 'codesigning']).stdout ?? '';
  const ids = [];
  for (const line of out.split('\n')) {
    const m = line.match(/^\s*\d+\)\s+([0-9A-F]{40})\s+"(.+)"$/);
    if (m) ids.push({ hash: m[1], name: m[2], team: (m[2].match(/\(([A-Z0-9]{10})\)\s*$/) ?? [])[1] ?? '' });
  }
  return ids;
}

/** Сертификаты организации, у которых закрытый ключ есть в этой связке. */
export async function usableIdentities(team) {
  const remote = await listDeveloperIdCerts(team);
  const local = localIdentities();
  return remote
    .map((r) => ({ remote: r, local: local.find((l) => l.hash === r.sha1) }))
    .filter((x) => x.local)
    .map((x) => ({ ...x.local, expires: x.remote.expires, certId: x.remote.id }));
}

const INTERMEDIATES = [
  { cn: 'Developer ID Certification Authority', url: 'https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer', g2: true },
  { cn: 'Developer ID Certification Authority', url: 'https://www.apple.com/certificateauthority/DeveloperIDCA.cer', g2: false },
];

/** Промежуточные сертификаты Apple: без них identity в связке считается недоверенной. */
export async function ensureIntermediates(log = () => {}) {
  const have = sh('security', ['find-certificate', '-a', '-c', 'Developer ID Certification Authority', '-p']).stdout ?? '';
  const count = (have.match(/BEGIN CERTIFICATE/g) ?? []).length;
  if (count >= 2) return;
  for (const ca of INTERMEDIATES) {
    const res = await fetch(ca.url);
    if (!res.ok) continue;
    const file = path.join(os.tmpdir(), `apple-ca-${ca.g2 ? 'g2' : 'g1'}.cer`);
    fs.writeFileSync(file, Buffer.from(await res.arrayBuffer()));
    // уже установленный сертификат security вернёт с ошибкой «already exists» — это нормально
    sh('security', ['add-certificates', '-k', KEYCHAIN, file]);
    fs.rmSync(file, { force: true });
  }
  log('Промежуточные сертификаты Apple Developer ID установлены');
}

/**
 * Выпускает новый сертификат Developer ID Application через API и импортирует его
 * вместе с закрытым ключом в связку ключей. Возвращает identity.
 */
export async function createDeveloperIdCert(team, { email, commonName = 'Developer ID' } = {}, log = () => {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'devid-'));
  try {
    const keyPem = path.join(dir, 'key.pem'), csr = path.join(dir, 'req.csr');
    const subj = `/CN=${commonName.replace(/[/=]/g, ' ')}${email ? `/emailAddress=${email}` : ''}`;
    const r = sh(OPENSSL, ['req', '-new', '-newkey', 'rsa:2048', '-nodes', '-keyout', keyPem, '-out', csr, '-subj', subj]);
    if (r.status !== 0) throw new Error(`openssl req: ${r.stderr}`);
    const csrContent = fs.readFileSync(csr, 'utf8');
    let created = null, lastErr = null;
    // G2 — актуальный тип; старый оставлен на случай, если API его не примет
    for (const certificateType of ['DEVELOPER_ID_APPLICATION_G2', 'DEVELOPER_ID_APPLICATION']) {
      try {
        created = await asc(team, 'POST', '/certificates', { data: { type: 'certificates', attributes: { csrContent, certificateType } } });
        break;
      } catch (e) {
        lastErr = e;
        if (e.status === 403 || e.status === 401) break; // дело в правах, другой тип не поможет
      }
    }
    if (!created) {
      if (lastErr?.status === 403) {
        const err = new Error(
          'Apple выдаёт Developer ID только владельцу аккаунта (Account Holder), а ключам API организации — запрещает. ' +
            'Выпустите сертификат один раз через сайт Apple (вход владельца) или в Xcode — дальше всё снова автоматически.\n' +
            `Ответ Apple: ${lastErr.message}`,
        );
        err.forbidden = true;
        throw err;
      }
      throw lastErr ?? new Error('Не удалось выпустить сертификат');
    }
    const der = Buffer.from(created.data.attributes.certificateContent, 'base64');
    const certDer = path.join(dir, 'cert.der'), certPem = path.join(dir, 'cert.pem'), p12 = path.join(dir, 'id.p12');
    fs.writeFileSync(certDer, der);
    sh(OPENSSL, ['x509', '-inform', 'DER', '-in', certDer, '-out', certPem]);
    const pass = crypto.randomBytes(12).toString('hex');
    const e = sh(OPENSSL, ['pkcs12', '-export', '-inkey', keyPem, '-in', certPem, '-out', p12, '-passout', `pass:${pass}`]);
    if (e.status !== 0) throw new Error(`openssl pkcs12: ${e.stderr}`);
    await ensureIntermediates(log);
    const imp = sh('security', ['import', p12, '-k', KEYCHAIN, '-P', pass, '-T', '/usr/bin/codesign', '-T', '/usr/bin/security', '-T', '/usr/bin/productsign']);
    if (imp.status !== 0) throw new Error(`Импорт в связку ключей: ${imp.stderr.trim()}`);
    const hash = sha1(der);
    const id = localIdentities().find((i) => i.hash === hash);
    if (!id) throw new Error('Сертификат импортирован, но macOS не считает его действительным — проверьте промежуточные сертификаты Apple');
    log(`Выпущен и установлен: ${id.name}`);
    return { ...id, expires: created.data.attributes.expirationDate, certId: created.data.id };
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

// ---------- выпуск через сайт Apple (для владельца аккаунта) ----------

/**
 * Developer ID Apple выдаёт только владельцу аккаунта (Account Holder) — ключам API
 * организации это запрещено. Обходной путь без Xcode: готовим ключ и CSR, владелец
 * загружает CSR на developer.apple.com и скачивает .cer, а мы соединяем их в связке.
 */
export const CERT_ADD_PAGE = 'https://developer.apple.com/account/resources/certificates/add';
export const PENDING_DIR = path.join(os.homedir(), '.config', 'apple-signing', 'pending');

/** Создаёт закрытый ключ (ждёт .cer в PENDING_DIR, права 600) и CSR для загрузки на сайт. */
export function prepareCsr({ email, commonName = 'Developer ID', csrDir = path.join(os.homedir(), 'Desktop') } = {}) {
  fs.mkdirSync(PENDING_DIR, { recursive: true, mode: 0o700 });
  const stamp = new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-');
  const keyPath = path.join(PENDING_DIR, `devid-${stamp}.key`);
  const csrPath = path.join(csrDir, `DeveloperID-${stamp}.certSigningRequest`);
  const subj = `/CN=${commonName.replace(/[/=]/g, ' ')}${email ? `/emailAddress=${email}` : ''}`;
  const r = sh(OPENSSL, ['req', '-new', '-newkey', 'rsa:2048', '-nodes', '-keyout', keyPath, '-out', csrPath, '-subj', subj]);
  if (r.status !== 0) throw new Error(`openssl req: ${r.stderr}`);
  fs.chmodSync(keyPath, 0o600);
  return { keyPath, csrPath };
}

/** Ключи, ожидающие свой .cer (если прошлый запуск прервался после создания CSR). */
export function pendingKeys() {
  try {
    return fs.readdirSync(PENDING_DIR).filter((f) => f.endsWith('.key')).map((f) => path.join(PENDING_DIR, f)).sort().reverse();
  } catch {
    return [];
  }
}

/** Самый свежий скачанный сертификат Developer ID в «Загрузках». */
export function downloadedCer() {
  const dir = path.join(os.homedir(), 'Downloads');
  try {
    return fs.readdirSync(dir)
      .filter((f) => /\.cer$/i.test(f) && /developer|devid/i.test(f))
      .map((f) => ({ f: path.join(dir, f), t: fs.statSync(path.join(dir, f)).mtimeMs }))
      .sort((a, b) => b.t - a.t)[0]?.f ?? '';
  } catch {
    return '';
  }
}

/** Соединяет скачанный .cer с ожидающим ключом, импортирует в связку, удаляет ключ из pending. */
export async function importCerWithKey(cerPath, keyPath, log = () => {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'devid-'));
  try {
    const cer = cerPath.replace(/^~/, os.homedir());
    const der = fs.readFileSync(cer);
    const certPem = path.join(dir, 'cert.pem'), p12 = path.join(dir, 'id.p12');
    // .cer с сайта Apple — DER; на всякий случай принимаем и PEM
    const isPem = der.toString('utf8', 0, 30).includes('BEGIN CERTIFICATE');
    const conv = sh(OPENSSL, ['x509', '-inform', isPem ? 'PEM' : 'DER', '-in', cer, '-out', certPem]);
    if (conv.status !== 0) throw new Error(`Это не сертификат: ${conv.stderr.trim()}`);
    // ключ должен подходить к сертификату — сравниваем открытые части
    const pubCert = sh(OPENSSL, ['x509', '-in', certPem, '-noout', '-pubkey']).stdout;
    const pubKey = sh(OPENSSL, ['rsa', '-in', keyPath, '-pubout']).stdout;
    if (!pubCert || pubCert.trim() !== pubKey.trim()) throw new Error('Сертификат выпущен не по этому CSR — закрытый ключ к нему не подходит');
    const pass = crypto.randomBytes(12).toString('hex');
    const e = sh(OPENSSL, ['pkcs12', '-export', '-inkey', keyPath, '-in', certPem, '-out', p12, '-passout', `pass:${pass}`]);
    if (e.status !== 0) throw new Error(`openssl pkcs12: ${e.stderr}`);
    await ensureIntermediates(log);
    const imp = sh('security', ['import', p12, '-k', KEYCHAIN, '-P', pass, '-T', '/usr/bin/codesign', '-T', '/usr/bin/security', '-T', '/usr/bin/productsign']);
    if (imp.status !== 0) throw new Error(`Импорт в связку ключей: ${imp.stderr.trim()}`);
    const pemDer = sh(OPENSSL, ['x509', '-in', certPem, '-outform', 'DER'], { encoding: 'buffer' }).stdout;
    const hash = sha1(pemDer);
    const id = localIdentities().find((i) => i.hash === hash);
    if (!id) throw new Error('Сертификат импортирован, но macOS не считает его действительным — проверьте промежуточные сертификаты Apple');
    fs.rmSync(keyPath, { force: true });
    log(`Установлен: ${id.name}`);
    return id;
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

/** Импорт .p12 в связку ключей. */
export function importP12(p12Path, password) {
  const r = sh('security', ['import', p12Path.replace(/^~/, os.homedir()), '-k', KEYCHAIN, '-P', password, '-T', '/usr/bin/codesign', '-T', '/usr/bin/security']);
  if (r.status !== 0) throw new Error(r.stderr.trim());
}

// ---------- нотаризация ----------

/** Аргументы notarytool для ключа организации. */
export function notaryArgs(team) {
  return ['--key', team.keyPath, '--key-id', team.keyId, '--issuer', team.issuerId];
}
