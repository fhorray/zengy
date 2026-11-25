#include "bridge.h"
#include <math.h>
static float lo(float a, float b) { return a < b ? a : b; }
static float hi(float a, float b) { return a > b ? a : b; }
size_t zwgpu_rect(ZWgpuVertex out[6], const float rect[4], const float clip[4], const float color[4], float width, float height) {
    if (!out || !rect || !clip || !color || !isfinite(width) || !isfinite(height) || width <= 0 || height <= 0) return 0;
    for (unsigned i=0;i<4;i++) if (!isfinite(rect[i]) || !isfinite(clip[i]) || !isfinite(color[i])) return 0;
    if (rect[2] <= 0 || rect[3] <= 0 || clip[2] <= 0 || clip[3] <= 0) return 0;
    float x0=hi(0,hi(rect[0],clip[0])), y0=hi(0,hi(rect[1],clip[1]));
    float x1=lo(width,lo(rect[0]+rect[2],clip[0]+clip[2])), y1=lo(height,lo(rect[1]+rect[3],clip[1]+clip[3]));
    if (x1<=x0 || y1<=y0) return 0;
    x0=2*(x0/width)-1; x1=2*(x1/width)-1;
    y0=1-2*(y0/height); y1=1-2*(y1/height);
    const float xy[6][2]={{x0,y0},{x0,y1},{x1,y0},{x1,y0},{x0,y1},{x1,y1}};
    for (unsigned i=0;i<6;i++) out[i]=(ZWgpuVertex){xy[i][0],xy[i][1],color[0],color[1],color[2],color[3]};
    return 6;
}
