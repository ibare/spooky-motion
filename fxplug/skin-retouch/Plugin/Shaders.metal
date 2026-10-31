// 피부 보정 셰이더
//
// 매끈하게: 빠른 가이드 필터(He et al.)로 피부의 낮은 대비 얼룩(잡티, 붉은 기)을 평평하게 하고,
// 원본의 미세한 결(모공)을 일부 되돌린 뒤, 피부 마스크만큼 원본과 섞는다.
// 가이드 필터 계수(a, b)는 저해상도에서 구하고(squareKernel, coeffKernel, MPS 흐림),
// 여기서 원본 해상도로 q = mean(a) * I + mean(b) 를 계산한다.
// 잡티 지우기: 모공만 지운 흐린 영상에서 둘레 8방향보다 모두 어둡거나 붉은 점을 찾아 둘레 피부색으로 메운다.

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

// MARK: 가이드 필터 (저해상도)

/// out = in * in (채널별)
kernel void squareKernel(texture2d<float, access::read> input [[texture(0)]],
                         texture2d<float, access::write> output [[texture(1)]],
                         uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float4 c = input.read(gid);
    output.write(float4(c.rgb * c.rgb, 1.0), gid);
}

/// 창 안의 분산이 eps 보다 작으면(잡티 같은 낮은 대비) a → 0 이라 평균으로 평평해지고,
/// 크면(눈꺼풀, 콧날 같은 경계) a → 1 이라 원본이 남는다. (채널별로 자기 자신을 길잡이로 쓴다)
kernel void coeffKernel(texture2d<float, access::read> meanI [[texture(0)]],
                        texture2d<float, access::read> meanII [[texture(1)]],
                        texture2d<float, access::write> outA [[texture(2)]],
                        texture2d<float, access::write> outB [[texture(3)]],
                        constant GuidedUniforms &g [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outA.get_width() || gid.y >= outA.get_height()) return;
    float3 m = meanI.read(gid).rgb;
    float3 var = max(meanII.read(gid).rgb - m * m, 0.0);
    float3 a = var / (var + g.eps);
    float3 b = m - a * m;
    outA.write(float4(a, 1.0), gid);
    outB.write(float4(b, 1.0), gid);
}

// MARK: 최종 합성 (원본 해상도)

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

/// 미세 결: 원본 - (반경 fineRadius 의 3x3 가중 평균). 모공, 솜털 크기의 무늬만 남는다.
static float3 fineDetail(texture2d<float> source, sampler s, float2 uv, float4 c, constant SkinUniforms &u)
{
    float2 o = u.texel * u.fineRadius;
    float3 sum = c.rgb * 4.0;
    sum += source.sample(s, uv + float2(o.x, 0)).rgb * 2.0;
    sum += source.sample(s, uv - float2(o.x, 0)).rgb * 2.0;
    sum += source.sample(s, uv + float2(0, o.y)).rgb * 2.0;
    sum += source.sample(s, uv - float2(0, o.y)).rgb * 2.0;
    sum += source.sample(s, uv + o).rgb;
    sum += source.sample(s, uv - o).rgb;
    sum += source.sample(s, uv + float2(o.x, -o.y)).rgb;
    sum += source.sample(s, uv + float2(-o.x, o.y)).rgb;
    return c.rgb - sum / 16.0;
}

// MARK: 잡티 찾기

// 주변보다 어두운 비율. 이 범위에서 0 → 1 로 잡티라고 본다 (갈색 점, 기미)
constant float kDark0 = 0.015;
constant float kDark1 = 0.05;
// 주변보다 붉은 정도 (색도 r 의 차이). 붉은 뾰루지
constant float kRed0 = 0.004;
constant float kRed1 = 0.012;

/// 작은 값 두 개 (가장 작은 것, 두 번째로 작은 것) 를 갱신한다
static void pushMin2(thread float2 &m, float v)
{
    if (v < m.x) { m.y = m.x; m.x = v; }
    else if (v < m.y) { m.y = v; }
}

/// 잡티일 정도 (0 ~ 1) 와 메울 색.
/// 모공이 사라질 만큼 흐린 영상(fineTex)에서, 가운데를 둘레 8방향(반경 spotRing)과 비교한다.
/// 잡티는 모든 방향보다 어둡거나 붉지만, 그늘진 경계나 주름은 한쪽(선을 따라가는 방향)이 똑같이 어둡다.
/// 그래서 8방향 대비 중 두 번째로 작은 값을 쓴다 (옆에 다른 잡티가 하나 있어도 견딘다).
/// (확인됨(시험 프로그램): 두 크기 흐림의 차이로 찾으면 콧볼 옆 그늘, 얼굴 가장자리, 눈 밑 주름이 잡혔다)
/// 둘레보다 큰 점(큰 점, 콧구멍)은 둘레가 점 안에 들어가 대비가 없으므로 잡히지 않는다.
static float spotScore(texture2d<float> fineTex, sampler s, float2 uv, constant SkinUniforms &u,
                       thread float3 &ringMean)
{
    float3 center = fineTex.sample(s, uv).rgb;
    float yc = luma(center);
    float rc = center.r / max(center.r + center.g + center.b, 1e-4);
    float2 o = u.texel * u.spotRing;
    float2 dark = float2(1e9), red = float2(1e9);
    ringMean = float3(0.0);
    for (int i = 0; i < 8; i++) {
        float ang = float(i) * M_PI_F / 4.0;
        float3 c = fineTex.sample(s, uv + o * float2(cos(ang), sin(ang))).rgb;
        ringMean += c;
        float y = luma(c);
        pushMin2(dark, (y - yc) / max(y, 1e-4));
        pushMin2(red, rc - c.r / max(c.r + c.g + c.b, 1e-4));
    }
    ringMean /= 8.0;
    return max(smoothstep(kDark0, kDark1, dark.y), smoothstep(kRed0, kRed1, red.y));
}

/// 둘레(반경 spotGuard)에 안경테, 눈썹, 머리카락처럼 피부보다 훨씬 어두운 것이 있으면 0.
/// 그런 것의 가장자리는 흐린 영상에서 어두운 점처럼 보여 잡티로 잘못 잡히기 쉽다.
static float spotGuard(texture2d<float> source, sampler s, float2 uv, constant SkinUniforms &u)
{
    float2 o = u.texel * u.spotGuard;
    float g = 1.0;
    for (int i = 0; i < 8; i++) {
        float ang = float(i) * M_PI_F / 4.0;
        float3 c = source.sample(s, uv + o * float2(cos(ang), sin(ang))).rgb;
        g = min(g, smoothstep(0.35, 0.55, luma(c) / max(u.lumaRef, 1e-4)));
    }
    return g;
}

fragment float4 skinFragment(RasterizerData in [[stage_in]],
                             texture2d<float> source [[texture(TI_Source)]],
                             texture2d<float> region [[texture(TI_Region)]],
                             texture2d<float> lowPass [[texture(TI_LowPass)]],
                             texture2d<float> meanA [[texture(TI_MeanA)]],
                             texture2d<float> meanB [[texture(TI_MeanB)]],
                             texture2d<float> spotFine [[texture(TI_SpotFine)]],
                             constant SkinUniforms &u [[buffer(FI_Uniforms)]])
{
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float2 uv = in.textureCoordinate;
    float4 c = source.sample(s, uv);
    float m = skinMask(c, lowPass.sample(s, uv), region.sample(s, uv).r, u);

    if (u.viewMode == VM_Mask) {
        float3 dim = float3(luma(c.rgb) * 0.25);
        return float4(mix(dim, c.rgb, m), c.a);
    }
    if (m <= 0.0) {
        return c;
    }

    // 잡티: 찾은 자리를 둘레 피부색의 평균으로 메우고 미세한 결을 다시 얹는다.
    float wSpot = 0.0;
    float3 fill = c.rgb;
    float3 fine = fineDetail(source, s, uv, c, u);
    if (u.spots > 0.0 || u.viewMode == VM_Spots) {
        float3 ringMean;
        wSpot = spotScore(spotFine, s, uv, u, ringMean) * spotGuard(source, s, uv, u) * m;
        fill = ringMean + u.detail * fine;
    }
    if (u.viewMode == VM_Spots) {
        return float4(mix(c.rgb, float3(1.0, 0.1, 0.1), wSpot * 0.8), c.a);
    }

    // 매끈하게
    float3 out = c.rgb;
    if (u.amount > 0.0) {
        float3 smooth = meanA.sample(s, uv).rgb * c.rgb + meanB.sample(s, uv).rgb;
        out = mix(c.rgb, smooth + u.detail * fine, m * u.amount);
    }
    out = mix(out, fill, wSpot * u.spots);
    return float4(out, c.a);
}
