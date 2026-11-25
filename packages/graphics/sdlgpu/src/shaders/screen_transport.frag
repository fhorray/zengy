#version 450
layout(location=0) in vec2 v_ndc;
layout(location=0) out vec4 frag_color;
layout(set=2,binding=0) uniform sampler2D u_hdr;
layout(set=2,binding=1) uniform sampler2D u_depth;
layout(set=2,binding=2) uniform sampler2D u_surface;
layout(set=2,binding=3) uniform sampler2D u_diffuse;
layout(set=2,binding=4) uniform sampler2D u_specular;
layout(set=2,binding=5) uniform sampler2D u_brdf;
layout(std430,set=2,binding=6) readonly buffer DepthBounds {vec2 bounds[];};
layout(std140,set=3,binding=0) uniform ScreenParams {
    mat4 view_proj;
    mat4 inv_view_proj;
    vec4 camera_gain; // world position, HDR pre-exposure gain
    vec4 controls; // SSR strength, SSGI strength, max distance, world thickness
    uvec4 levels[16]; // offset, width, height, unused
    uvec4 budget; // level count, max iterations, diffuse ray count, unused
};
const float PI=3.14159265359;
vec3 safeNormalize(vec3 v){return v*inversesqrt(max(dot(v,v),1e-12));}
vec3 worldAt(vec2 uv,float d){vec4 h=inv_view_proj*vec4(uv.x*2.0-1.0,1.0-uv.y*2.0,d,1.0);return h.xyz/max(h.w,1e-6);}
vec3 projectPoint(vec4 h){vec3 n=h.xyz/h.w;return vec3(n.x*0.5+0.5,0.5-n.y*0.5,n.z);}
vec3 decodeNormal(vec2 e){vec3 n=vec3(e,1.0-abs(e.x)-abs(e.y));if(n.z<0.0)n.xy=(1.0-abs(n.yx))*mix(vec2(-1.0),vec2(1.0),greaterThanEqual(n.xy,vec2(0)));return safeNormalize(n);}
vec3 unpackRgb(float v){uint p=uint(clamp(v,0.0,16777215.0));return vec3(p&255u,(p>>8)&255u,(p>>16)&255u)/255.0;}
float hash(vec2 p){return fract(52.9829189*fract(dot(p,vec2(0.06711056,0.00583715))));}
struct Hit{vec2 uv;float confidence;};
Hit traceRay(vec3 origin,vec3 direction){
    Hit miss=Hit(vec2(0),0.0);
    vec4 a=view_proj*vec4(origin,1.0);
    vec4 b=view_proj*vec4(origin+direction*controls.z,1.0);
    if(a.w<=1e-4)return miss;
    // Clip the endpoint before perspective division; do not trace behind the eye.
    if(b.w<1e-3){float t=clamp((a.w-1e-3)/max(a.w-b.w,1e-6),0.0,1.0);b=mix(a,b,t);}
    vec3 p=projectPoint(a),q=projectPoint(b),d=q-p;
    vec2 full=vec2(levels[0].yz);
    float pixels=length(d.xy*full);
    if(pixels<2.0)return miss;
    float t=min(2.0/pixels,0.99),epsilon=0.05/pixels;
    int top=int(min(budget.x,16u))-1;
    int level=min(top,4);
    for(uint i=0u;i<min(budget.y,128u);++i){
        if(t>=1.0)return miss;
        vec3 s=p+d*t;
        if(any(lessThan(s.xy,vec2(0)))||any(greaterThanEqual(s.xy,vec2(1)))||s.z<=0.0||s.z>=1.0)return miss;
        uvec4 info=levels[level];
        // Ceil-reduced mips cover 2^level source pixels (odd dimensions included).
        float scale=exp2(float(level));
        vec2 grid=full/scale;
        ivec2 cell=clamp(ivec2(floor(s.xy*grid)),ivec2(0),ivec2(info.yz)-1);
        vec2 edge=(vec2(cell)+mix(vec2(0),vec2(1),greaterThan(d.xy,vec2(0))))/grid;
        vec2 dt=vec2(1e20);
        if(abs(d.x)>1e-8)dt.x=(edge.x-s.x)/d.x;
        if(abs(d.y)>1e-8)dt.y=(edge.y-s.y)/d.y;
        float endT=min(1.0,t+max(min(dt.x,dt.y),epsilon));
        float endZ=p.z+d.z*endT;
        vec2 range=bounds[info.x+uint(cell.y)*info.y+uint(cell.x)];
        bool overlaps=range.x<0.99999 && max(s.z,endZ)>=range.x && min(s.z,endZ)<=range.y+0.0001;
        if(overlaps&&level>0){--level;continue;}
        if(overlaps){
            float depth=range.x;
            float hitT=abs(d.z)>1e-8?clamp((depth-p.z)/d.z,t,endT):t;
            vec3 hitPos=p+d*hitT;
            vec2 hitUV=(vec2(cell)+0.5)/full;
            vec3 surface=worldAt(hitUV,depth);
            vec3 rayPos=worldAt(hitPos.xy,hitPos.z);
            float err=length(surface-rayPos);
            float distance=length(surface-origin);
            if(err<=controls.w&&distance>controls.w*1.5&&distance<=controls.z+controls.w){
                vec4 target=texelFetch(u_surface,cell,0);
                // Reject unlit/transparent targets and back-facing intersections.
                if(target.z>=0.0 && dot(decodeNormal(target.xy),-direction)>0.02){
                    float edgeFade=clamp(min(min(hitUV.x,1.0-hitUV.x),min(hitUV.y,1.0-hitUV.y))*12.0,0.0,1.0);
                    return Hit(hitUV,edgeFade*(1.0-clamp(distance/controls.z,0.0,1.0))*clamp(1.0-err/max(controls.w,1e-4),0.0,1.0));
                }
            }
        }
        t=endT+epsilon;
        level=min(top,level+1);
    }
    return miss;
}
void main(){
    ivec2 px=ivec2(gl_FragCoord.xy);
    vec3 hdr=texelFetch(u_hdr,px,0).rgb;
    vec4 surface=texelFetch(u_surface,px,0);
    float depth=texelFetch(u_depth,px,0).r;
    if(surface.z<0.0||depth>=0.99999||budget.x==0u){frag_color=vec4(hdr,1);return;}
    vec3 props=unpackRgb(surface.z);
    float rough=max(props.x,0.045),metal=props.y,reflectance=props.z;
    vec3 albedo=unpackRgb(surface.w);
    vec2 uv=(vec2(px)+0.5)/vec2(levels[0].yz);
    vec3 pos=worldAt(uv,depth),N=decodeNormal(surface.xy),V=safeNormalize(camera_gain.xyz-pos);
    float nv=max(dot(N,V),0.0);
    vec3 F0=mix(vec3(0.16*reflectance*reflectance),albedo,metal);
    vec3 F=F0+(max(vec3(1.0-rough),F0)-F0)*pow(1.0-nv,5.0);
    vec3 origin=pos+N*max(0.025,controls.w*0.4);
    vec4 oldSpec=texelFetch(u_specular,px,0),oldDiff=texelFetch(u_diffuse,px,0);
    vec3 delta=vec3(0);
    if(controls.x>0.0 && rough<0.65){
        Hit hit=traceRay(origin,reflect(-V,N));
        if(hit.confidence>0.0){
            vec2 brdf=textureLod(u_brdf,vec2(nv,rough),0.0).rg;
            vec3 fss=F0*brdf.x+brdf.y;
            float ems=clamp(1.0-brdf.x-brdf.y,0.0,1.0);
            vec3 favg=F0+(1.0-F0)/21.0;
            vec3 factor=fss+ems*fss*favg/max(vec3(1e-4),1.0-ems*favg);
            vec3 reflected=textureLod(u_hdr,hit.uv,0.0).rgb*factor*oldSpec.a;
            delta+=(reflected-oldSpec.rgb)*(hit.confidence*controls.x*(1.0-smoothstep(0.15,0.65,rough)));
        }
    }
    if(controls.y>0.0 && metal<0.99){
        vec3 tangent=safeNormalize(cross(abs(N.y)<0.99?vec3(0,1,0):vec3(1,0,0),N));
        vec3 bitangent=cross(N,tangent);
        uint rays=clamp(budget.z,1u,4u);
        for(uint j=0u;j<rays;++j){
            float r=sqrt((float(j)+0.5)/float(rays));
            float angle=2.0*PI*fract(hash(vec2(px))+float(j)*0.61803398875);
            vec3 dir=safeNormalize(tangent*(r*cos(angle))+bitangent*(r*sin(angle))+N*sqrt(1.0-r*r));
            Hit hit=traceRay(origin,dir);
            if(hit.confidence>0.0){
                vec3 diffuse=textureLod(u_hdr,hit.uv,0.0).rgb*(1.0-F)*(1.0-metal)*albedo*oldDiff.a;
                delta+=(diffuse-oldDiff.rgb)*(controls.y*hit.confidence/float(rays));
            }
        }
    }
    // Replace only the sampled indirect term. Misses retain existing probe/sky lighting.
    vec3 result=max(hdr+delta,vec3(0));
    if(any(isnan(result))||any(isinf(result)))result=hdr;
    frag_color=vec4(clamp(result,vec3(0),vec3(65000)),1);
}
