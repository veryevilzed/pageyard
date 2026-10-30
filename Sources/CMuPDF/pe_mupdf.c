#include "pe_mupdf.h"

#include <mupdf/fitz.h>
#include <mupdf/pdf.h>
#include <stdlib.h>
#include <string.h>

static int compare_regions(const void *a, const void *b)
{
    return ((const pe_region *)a)->page - ((const pe_region *)b)->page;
}

unsigned char *pe_remove_text(const unsigned char *data, size_t len,
                              const char *password,
                              const pe_region *regions, int count,
                              size_t *out_len, char *err, size_t err_len)
{
    unsigned char *result = NULL;
    fz_context *ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
    if (!ctx) {
        snprintf(err, err_len, "cannot create MuPDF context");
        return NULL;
    }

    pe_region *sorted = malloc(sizeof(pe_region) * (count > 0 ? count : 1));
    memcpy(sorted, regions, sizeof(pe_region) * count);
    qsort(sorted, count, sizeof(pe_region), compare_regions);

    fz_stream *stm = NULL;
    pdf_document *doc = NULL;
    pdf_page *page = NULL;
    fz_buffer *buf = NULL;
    fz_output *out = NULL;

    fz_var(stm);
    fz_var(doc);
    fz_var(page);
    fz_var(buf);
    fz_var(out);

    fz_try(ctx) {
        stm = fz_open_memory(ctx, data, len);
        doc = pdf_open_document_with_stream(ctx, stm);
        if (pdf_needs_password(ctx, doc) && !pdf_authenticate_password(ctx, doc, password ? password : ""))
            fz_throw(ctx, FZ_ERROR_GENERIC, "wrong password");

        pdf_redact_options opts = {0};
        opts.black_boxes = 0;
        opts.image_method = PDF_REDACT_IMAGE_NONE;
        opts.line_art = PDF_REDACT_LINE_ART_NONE;
        opts.text = PDF_REDACT_TEXT_REMOVE;

        int i = 0;
        while (i < count) {
            int number = sorted[i].page;
            page = pdf_load_page(ctx, doc, number);
            fz_rect mediabox;
            fz_matrix ctm;
            pdf_page_transform(ctx, page, &mediabox, &ctm);
            for (; i < count && sorted[i].page == number; i++) {
                fz_rect r = fz_make_rect(sorted[i].x0, sorted[i].y0, sorted[i].x1, sorted[i].y1);
                pdf_annot *annot = pdf_create_annot(ctx, page, PDF_ANNOT_REDACT);
                pdf_set_annot_rect(ctx, annot, fz_transform_rect(r, ctm));
                pdf_drop_annot(ctx, annot);
            }
            pdf_redact_page(ctx, doc, page, &opts);
            fz_drop_page(ctx, (fz_page *)page);
            page = NULL;
        }

        buf = fz_new_buffer(ctx, len + 1024);
        out = fz_new_output_with_buffer(ctx, buf);
        pdf_write_options wopts = pdf_default_write_options;
        pdf_write_document(ctx, doc, out, &wopts);
        fz_close_output(ctx, out);

        unsigned char *bytes = NULL;
        size_t n = fz_buffer_storage(ctx, buf, &bytes);
        result = malloc(n);
        memcpy(result, bytes, n);
        *out_len = n;
    }
    fz_always(ctx) {
        fz_drop_output(ctx, out);
        fz_drop_buffer(ctx, buf);
        if (page)
            fz_drop_page(ctx, (fz_page *)page);
        pdf_drop_document(ctx, doc);
        fz_drop_stream(ctx, stm);
    }
    fz_catch(ctx) {
        snprintf(err, err_len, "%s", fz_caught_message(ctx));
        result = NULL;
    }

    free(sorted);
    fz_drop_context(ctx);
    return result;
}

void pe_free(void *ptr)
{
    free(ptr);
}
