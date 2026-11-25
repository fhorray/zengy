#version 450
layout(location=0) in vec2 v_ndc;
layout(location=0) out vec4 frag_color;
layout(set=2,binding=0) uniform sampler2D u_froxels;
layout(set=2,binding=1) uniform sampler2D u_depth;
layout(std140,set=3,binding=0) uniform FroxelIntegrateParams {
    mat4 inv_view_proj;
    vec4 cam_max; // camera position, max distance
    vec4 dimensions; // columns, rows, slices, density
};
float boundary(float k,float count){return cam_max.w*(exp2(4.0*k/count)-1.0)/15.0;}
void main(){
    vec2 uv=vec2(v_ndc.x*0.5+0.5,0.5-v_ndc.y*0.5);
    float d=textureLod(u_depth,uv,0.0).r;
    vec4 h=inv_view_proj*vec4(v_ndc,d,1.0);
    float maxDist=d>=0.9999?cam_max.w:min(length(h.xyz/max(h.w,1e-5)-cam_max.xyz),cam_max.w);
    float T=1.0;vec3 L=vec3(0);
    int count=clamp(int(dimensions.z),1,64);
    vec2 xy=clamp(uv*dimensions.xy,vec2(0.5),dimensions.xy-0.5);
    float density=max(dimensions.w,0.0);
    for(int i=0;i<count;++i){
        float nearD=boundary(float(i),float(count));
        if(nearD>=maxDist||T<0.005)break;
        float farD=boundary(float(i+1),float(count));
        float len=min(maxDist,farD)-nearD;
        // Each froxel stores the unintegrated in-scatter source per metre.
        vec2 atlasUV=vec2(xy.x/dimensions.x,(xy.y+float(i)*dimensions.y)/(dimensions.y*float(count)));
        vec3 source=textureLod(u_froxels,atlasUV,0.0).rgb;
        float stepT=exp(-density*len);
        float integral=density*len>1e-4?(1.0-stepT)/density:len;
        L+=T*source*integral;T*=stepT;
    }
    frag_color=vec4(clamp(L,vec3(0),vec3(65000)),maxDist);
}
