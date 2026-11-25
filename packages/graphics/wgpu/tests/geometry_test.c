#include "../src/bridge.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
int main(void) {
    ZWgpuVertex v[6];
    const float full[]={0,0,100,100}, color[]={1,0,0,1};
    assert(zwgpu_rect(v,full,full,color,100,100)==6);
    assert(v[0].x==-1 && v[0].y==1 && v[5].x==1 && v[5].y==-1);
    const float clip[]={25,25,50,50};
    assert(zwgpu_rect(v,full,clip,color,100,100)==6);
    assert(v[0].x==-0.5f && v[0].y==0.5f && v[5].x==0.5f && v[5].y==-0.5f);
    const float outside[]={200,200,10,10}, negative[]={0,0,-1,10}, invalid[]={NAN,0,10,10};
    assert(!zwgpu_rect(v,outside,full,color,100,100));
    assert(!zwgpu_rect(v,negative,full,color,100,100));
    assert(!zwgpu_rect(v,invalid,full,color,100,100));
    assert(!zwgpu_rect(v,full,full,color,0,100));
    assert(!zwgpu_rect(v,full,full,color,100,INFINITY));
    puts("7 geometry cases passed"); return 0;
}
