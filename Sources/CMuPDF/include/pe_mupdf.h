#ifndef PE_MUPDF_H
#define PE_MUPDF_H

#include <stddef.h>

/// A rectangle in PDF user space (bottom-left origin, unrotated) on a page.
typedef struct {
    int page;
    double x0, y0, x1, y1;
} pe_region;

/// Physically removes text glyphs inside the given regions from the page
/// content streams (images and line art are kept). Returns a malloc'd buffer
/// with the resulting PDF (free with pe_free), or NULL on failure with a
/// message written to `err`.
unsigned char *pe_remove_text(const unsigned char *data, size_t len,
                              const char *password,
                              const pe_region *regions, int count,
                              size_t *out_len, char *err, size_t err_len);

void pe_free(void *ptr);

#endif
