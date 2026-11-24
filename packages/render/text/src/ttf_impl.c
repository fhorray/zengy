#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"

typedef struct ZengyBakedChar {
    unsigned short x0, y0, x1, y1;
    float xoff, yoff, xadvance;
} ZengyBakedChar;

int zengy_ttf_bake(
    const unsigned char *ttf_data,
    float pixel_height,
    unsigned char *out_alpha,
    int pw,
    int ph,
    ZengyBakedChar *out_chars,
    float *out_ascent
) {
    stbtt_bakedchar baked[95];
    int res = stbtt_BakeFontBitmap(ttf_data, 0, pixel_height, out_alpha, pw, ph, 32, 95, baked);
    if (res <= 0) return 0;
    for (int i = 0; i < 95; ++i) {
        out_chars[i].x0 = baked[i].x0;
        out_chars[i].y0 = baked[i].y0;
        out_chars[i].x1 = baked[i].x1;
        out_chars[i].y1 = baked[i].y1;
        out_chars[i].xoff = baked[i].xoff;
        out_chars[i].yoff = baked[i].yoff;
        out_chars[i].xadvance = baked[i].xadvance;
    }
    stbtt_fontinfo info;
    if (stbtt_InitFont(&info, ttf_data, 0)) {
        int asc = 0, desc = 0, gap = 0;
        stbtt_GetFontVMetrics(&info, &asc, &desc, &gap);
        float scale = stbtt_ScaleForPixelHeight(&info, pixel_height);
        *out_ascent = (float)asc * scale;
    } else {
        *out_ascent = pixel_height * 0.8f;
    }
    return 1;
}

int zengy_ttf_bake_codepoints(
    const unsigned char *ttf_data,
    float pixel_height,
    unsigned char *out_alpha,
    int pw,
    int ph,
    const int *codepoints,
    int count,
    ZengyBakedChar *out_chars
) {
    stbtt_fontinfo info;
    if (!stbtt_InitFont(&info, ttf_data, 0)) return 0;
    float scale = stbtt_ScaleForPixelHeight(&info, pixel_height);
    int x = 1, y = 1, row_h = 0;
    for (int i = 0; i < count; ++i) {
        int glyph = stbtt_FindGlyphIndex(&info, codepoints[i]);
        int gw = 0, gh = 0, xoff = 0, yoff = 0;
        unsigned char *bmp = stbtt_GetGlyphBitmap(&info, scale, scale, glyph, &gw, &gh, &xoff, &yoff);
        int min_x = gw, min_y = gh, max_x = -1, max_y = -1;
        if (bmp) {
            for (int r = 0; r < gh; ++r) {
                for (int c = 0; c < gw; ++c) {
                    if (bmp[r * gw + c] > 8) {
                        if (c < min_x) min_x = c;
                        if (c > max_x) max_x = c;
                        if (r < min_y) min_y = r;
                        if (r > max_y) max_y = r;
                    }
                }
            }
        }
        int tw = (max_x >= min_x) ? (max_x - min_x + 1) : 0;
        int th = (max_y >= min_y) ? (max_y - min_y + 1) : 0;
        if (x + tw + 2 > pw) {
            x = 1;
            y += row_h + 2;
            row_h = 0;
        }
        if (y + th + 2 > ph) {
            if (bmp) stbtt_FreeBitmap(bmp, NULL);
            break;
        }
        if (bmp && tw > 0 && th > 0) {
            for (int r = 0; r < th; ++r) {
                for (int c = 0; c < tw; ++c) {
                    out_alpha[(y + r) * pw + (x + c)] = bmp[(min_y + r) * gw + (min_x + c)];
                }
            }
        }
        if (bmp) stbtt_FreeBitmap(bmp, NULL);
        out_chars[i].x0 = (unsigned short)x;
        out_chars[i].y0 = (unsigned short)y;
        out_chars[i].x1 = (unsigned short)(x + tw);
        out_chars[i].y1 = (unsigned short)(y + th);
        out_chars[i].xoff = (float)xoff;
        out_chars[i].yoff = (float)yoff;
        out_chars[i].xadvance = pixel_height;
        x += tw + 2;
        if (th > row_h) row_h = th;
    }
    return 1;
}

/* Packs `count` extra codepoints below row `start_y` of an already partially filled alpha bitmap.
 * Unlike zengy_ttf_bake_codepoints this keeps the true horizontal advance and the trimmed-box
 * offsets (xoff/yoff already include the trim). Codepoints the font lacks, or that no longer fit,
 * get xadvance = -1 so callers can fall back to another glyph. Returns the number baked. */
int zengy_ttf_bake_extra(
    const unsigned char *ttf_data,
    float pixel_height,
    unsigned char *out_alpha,
    int pw,
    int ph,
    int start_y,
    const int *codepoints,
    int count,
    ZengyBakedChar *out_chars
) {
    stbtt_fontinfo info;
    for (int i = 0; i < count; ++i) {
        out_chars[i].x0 = out_chars[i].y0 = out_chars[i].x1 = out_chars[i].y1 = 0;
        out_chars[i].xoff = out_chars[i].yoff = 0.0f;
        out_chars[i].xadvance = -1.0f;
    }
    if (!stbtt_InitFont(&info, ttf_data, 0)) return 0;
    float scale = stbtt_ScaleForPixelHeight(&info, pixel_height);
    int x = 1, y = start_y, row_h = 0, baked = 0;
    for (int i = 0; i < count; ++i) {
        int glyph = stbtt_FindGlyphIndex(&info, codepoints[i]);
        if (glyph == 0) continue;
        int adv = 0, lsb = 0;
        stbtt_GetGlyphHMetrics(&info, glyph, &adv, &lsb);
        int gw = 0, gh = 0, xoff = 0, yoff = 0;
        unsigned char *bmp = stbtt_GetGlyphBitmap(&info, scale, scale, glyph, &gw, &gh, &xoff, &yoff);
        if (x + gw + 2 > pw) {
            x = 1;
            y += row_h + 2;
            row_h = 0;
        }
        if (y + gh + 2 > ph) {
            if (bmp) stbtt_FreeBitmap(bmp, NULL);
            break;
        }
        if (bmp) {
            for (int r = 0; r < gh; ++r)
                for (int c = 0; c < gw; ++c)
                    out_alpha[(y + r) * pw + (x + c)] = bmp[r * gw + c];
            stbtt_FreeBitmap(bmp, NULL);
        }
        out_chars[i].x0 = (unsigned short)x;
        out_chars[i].y0 = (unsigned short)y;
        out_chars[i].x1 = (unsigned short)(x + gw);
        out_chars[i].y1 = (unsigned short)(y + gh);
        out_chars[i].xoff = (float)xoff;
        out_chars[i].yoff = (float)yoff;
        out_chars[i].xadvance = (float)adv * scale;
        x += gw + 2;
        if (gh > row_h) row_h = gh;
        baked++;
    }
    return baked;
}
