// 피부 보정 셰이더
//
// 2단계(피부 마스크): 결과는 원본 그대로이고, '피부 마스크' 보기에서는
// 피부로 판정한 곳만 원래 색으로, 나머지는 어두운 흑백으로 보여 준다.

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

static float luma(float3 c)
{
    return dot(c, float3(0.2126, 0.7152, 0.0722));
}

/// 피부일 정도 (0 ~ 1) = 얼굴 영역 × 피부색에 가까운 정도 × 너무 어둡지 않음
///   c   : 원본 픽셀 (밝기 판정. 가는 안경테도 걸러지도록 원본 해상도로 본다)
///   low : 저해상도 흐린 영상 (색 판정. 잡티와 모공이 주변 피부에 섞여 구멍이 나지 않는다)
static float skinMask(float4 c, float4 low, float region, constant SkinUniforms &u)
{
    if (u.hasFace < 0.5 || region <= 0.0) {
        return 0.0;
    }
    float sum = low.r + low.g + low.b;
    if (sum <= 1e-4) {
        return 0.0;
    }
    // 색도: 밝기와 상관없는 색의 비율. 그늘진 피부와 밝은 피부가 같은 값을 갖는다.
    float2 d = low.rg / sum - u.skinMean;
    float d2 = d.x * d.x * u.invCov.x + 2.0 * d.x * d.y * u.invCov.y + d.y * d.y * u.invCov.z;
    float colorScore = exp(-0.5 * d2 / (u.tolerance * u.tolerance));
    // 안경테, 눈썹, 수염처럼 피부보다 훨씬 어두운 곳은 거른다. 잡티(피부의 60~80% 밝기)는 통과한다.
    float lumaGate = smoothstep(0.25, 0.45, luma(c.rgb) / max(u.lumaRef, 1e-4));
    return region * colorScore * lumaGate;
}

fragment float4 skinFragment(RasterizerData in [[stage_in]],
                             texture2d<float> source [[texture(TI_Source)]],
                             texture2d<float> region [[texture(TI_Region)]],
                             texture2d<float> lowPass [[texture(TI_LowPass)]],
                             constant SkinUniforms &u [[buffer(FI_Uniforms)]])
{
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float2 uv = in.textureCoordinate;
    float4 c = source.sample(s, uv);
    if (u.viewMode == VM_Result) {
        return c;
    }
    float m = skinMask(c, lowPass.sample(s, uv), region.sample(s, uv).r, u);
    float3 dim = float3(luma(c.rgb) * 0.25);
    return float4(mix(dim, c.rgb, m), c.a);
}
