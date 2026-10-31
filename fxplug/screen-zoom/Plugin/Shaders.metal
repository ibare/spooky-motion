// 화면 확대 셰이더
//
// zoomFragment: 출력 픽셀마다 원본 좌표 q = p / zoom + offset 을 구해 Catmull-Rom 으로 읽는다.
//   배율이 1 이면 원본 픽셀을 그대로 옮긴다(보간으로 흐려지지 않게).
//   움직이는 프레임은 셔터가 열린 동안의 변환 표본마다 읽어 평균한다(모션 블러). 흐려지므로 선형 보간으로 충분하다.
//   영역 고르기에서는 원래 화면을 두고 영역 밖만 어둡게 한다.
// oscVertex / oscFragment: 뷰어 조절점(영역 테두리와 모서리 손잡이)을 단색 삼각형으로 그린다.

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

#include "ShaderTypes.h"

typedef struct
{
    float4 clipSpacePosition [[position]];
    float2 textureCoordinate;
} RasterizerData;

// 픽셀 좌표로 받은 사각형 꼭짓점을 화면 좌표(-1 ~ 1)로 바꾼다. (SDK 예제와 같다)
vertex RasterizerData
vertexShader(uint vertexID [[vertex_id]],
             constant Vertex2D *vertexArray [[buffer(VI_Vertices)]],
             constant vector_uint2 *viewportSizePointer [[buffer(VI_ViewportSize)]])
{
    RasterizerData out;
    float2 pixelSpacePosition = vertexArray[vertexID].position.xy;
    float2 viewportSize = float2(*viewportSizePointer);
    out.clipSpacePosition.xy = pixelSpacePosition / (viewportSize / 2.0);
    out.clipSpacePosition.z = 0.0;
    out.clipSpacePosition.w = 1.0;
    out.textureCoordinate = vertexArray[vertexID].textureCoordinate;
    return out;
}

// Catmull-Rom 보간을 선형 표본 9번으로 계산한다. pos 는 텍셀 좌표(텍셀 가운데가 i + 0.5).
// 확대할 때 글자 가장자리가 선형 보간보다 또렷하다.
static float4 catmullRom(texture2d<float> tex, sampler s, float2 pos, float2 size)
{
    float2 p1 = floor(pos - 0.5) + 0.5;
    float2 f = pos - p1;
    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);
    float2 w12 = w1 + w2;
    float2 t0 = (p1 - 1.0) / size;
    float2 t3 = (p1 + 2.0) / size;
    float2 t12 = (p1 + w2 / w12) / size;

    float4 c = 0;
    c += tex.sample(s, float2(t0.x,  t0.y))  * w0.x  * w0.y;
    c += tex.sample(s, float2(t12.x, t0.y))  * w12.x * w0.y;
    c += tex.sample(s, float2(t3.x,  t0.y))  * w3.x  * w0.y;
    c += tex.sample(s, float2(t0.x,  t12.y)) * w0.x  * w12.y;
    c += tex.sample(s, float2(t12.x, t12.y)) * w12.x * w12.y;
    c += tex.sample(s, float2(t3.x,  t12.y)) * w3.x  * w12.y;
    c += tex.sample(s, float2(t0.x,  t3.y))  * w0.x  * w3.y;
    c += tex.sample(s, float2(t12.x, t3.y))  * w12.x * w3.y;
    c += tex.sample(s, float2(t3.x,  t3.y))  * w3.x  * w3.y;
    // 음의 가중치 때문에 경계에서 0 아래로 내려가는 값만 막는다 (1 을 넘는 HDR 값은 그대로 둔다)
    c.a = saturate(c.a);
    c.rgb = max(c.rgb, 0.0);
    return c;
}

fragment float4 zoomFragment(RasterizerData in [[stage_in]],
                             texture2d<float> source [[texture(TI_Source)]],
                             constant ZoomUniforms &u [[buffer(FI_Uniforms)]],
                             constant float4 *samples [[buffer(FI_Samples)]])
{
    constexpr sampler linearClamp(coord::normalized, address::clamp_to_edge, filter::linear);

    // 출력 픽셀의 그림 좌표 (픽셀, y 위쪽이 +)
    float2 img = float2(u.dstOrigin.x + in.clipSpacePosition.x,
                        u.dstOrigin.y + u.dstRowSign * in.clipSpacePosition.y);
    float2 p = img / u.imageSize;

    if (u.mode == ZM_Result && u.sampleCount > 1) {
        // 셔터를 (표본 수 - 1) 구간으로 나눈 경계가 표본이다. 구간마다 픽셀별로 어긋난 시각(지터)에서
        // 두 경계를 보간해 읽어, 고정된 시각에서만 읽을 때 생기는 겹친 가장자리를 고른 블러로 바꾼다.
        // 지터는 interleaved gradient noise (Jimenez 2014).
        float jitter = fract(52.9829189 * fract(dot(in.clipSpacePosition.xy, float2(0.06711056, 0.00583715))));
        // 셔터 가운데에 무게를 두는 Hann 창(sin²)으로 섞어, 번진 자국의 양 끝이 부드럽게 사라지게 한다.
        int intervals = u.sampleCount - 1;
        float4 sum = 0;
        float weights = 0;
        for (int k = 0; k < intervals; k++) {
            float tau = (float(k) + jitter) / float(intervals);
            float w = sinpi(tau);
            w *= w;
            float4 s = mix(samples[k], samples[k + 1], jitter);
            float2 qk = p / s.x + s.yz;
            float2 srcK = qk * u.imageSize;
            float2 texelK = float2(srcK.x - u.srcOrigin.x, (srcK.y - u.srcOrigin.y) * u.srcRowSign);
            sum += source.sample(linearClamp, texelK / u.srcSize) * w;
            weights += w;
        }
        return sum / max(weights, 1e-6);
    }

    float2 q = p;
    bool zoomed = u.mode == ZM_Result && u.zoom > 1.00001;
    if (zoomed) {
        q = p / u.zoom + u.offset;
    }
    // 원본 조각의 텍셀 좌표
    float2 srcImg = q * u.imageSize;
    float2 texel = float2(srcImg.x - u.srcOrigin.x, (srcImg.y - u.srcOrigin.y) * u.srcRowSign);

    float4 c;
    if (zoomed) {
        c = catmullRom(source, linearClamp, texel, u.srcSize);
    } else {
        uint2 at = uint2(clamp(floor(texel), float2(0), u.srcSize - 1.0));
        c = source.read(at);
    }

    if (u.mode == ZM_Select) {
        bool inside = p.x >= u.region.x && p.x <= u.region.z && p.y >= u.region.y && p.y <= u.region.w;
        if (!inside) {
            c.rgb *= u.dim;
        }
    }
    return c;
}

// MARK: 조절점

typedef struct
{
    float4 position [[position]];
    float4 color;
} OSCRasterizerData;

vertex OSCRasterizerData oscVertex(uint vertexID [[vertex_id]],
                                   constant OSCVertex *vertices [[buffer(VI_Vertices)]])
{
    OSCRasterizerData out;
    out.position = float4(vertices[vertexID].position, 0.0, 1.0);
    out.color = vertices[vertexID].color;
    return out;
}

fragment float4 oscFragment(OSCRasterizerData in [[stage_in]])
{
    return in.color;
}
