// Swift 와 Metal 셰이더가 함께 쓰는 타입과 버퍼 번호
#ifndef ShaderTypes_h
#define ShaderTypes_h

#import <simd/simd.h>

typedef enum VertexInputIndex {
    VI_Vertices     = 0,
    VI_ViewportSize = 1
} VertexInputIndex;

/// skinFragment 의 텍스처 자리. 원본 외에는 모두 원본과 같은 텍스처 좌표로 읽는다.
typedef enum TextureIndex {
    TI_Source  = 0,   // 원본 영상
    TI_Region  = 1,   // 얼굴 영역 마스크 (특징점으로 그리고 흐린 것)
    TI_LowPass = 2,   // 피부색 판정용 저해상도 흐린 영상
    TI_MeanA   = 3,   // 가이드 필터 계수 a 의 평균 (저해상도)
    TI_MeanB   = 4    // 가이드 필터 계수 b 의 평균 (저해상도)
} TextureIndex;

typedef enum FragmentIndex {
    FI_Uniforms = 0
} FragmentIndex;

typedef struct Vertex2D {
    vector_float2 position;
    vector_float2 textureCoordinate;
} Vertex2D;

/// 보기 방식 (인스펙터 '보기' 팝업 순번)
typedef enum ViewMode {
    VM_Result = 0,
    VM_Mask   = 1
} ViewMode;

typedef struct SkinUniforms {
    vector_float2 skinMean;   // 피부 색도 (r/(r+g+b), g/(r+g+b)) 평균
    vector_float3 invCov;     // 색도 역공분산 [[x y][y z]]
    vector_float2 texel;      // 원본 한 픽셀의 텍스처 좌표 크기 (1/너비, 1/높이)
    float tolerance;          // 피부색 범위 (클수록 넓게)
    float lumaRef;            // 피부 밝기 중앙값. 이보다 많이 어두우면 피부가 아니다
    float hasFace;            // 0 이면 마스크는 0
    float amount;             // 정도 (0 ~ 1)
    float detail;             // 결 살리기 (0 ~ 1)
    float fineRadius;         // 미세 결을 가르는 반경 (원본 픽셀)
    int viewMode;             // ViewMode
} SkinUniforms;

/// 가이드 필터 계수 계산용
typedef struct GuidedUniforms {
    float eps;                // 클수록 더 큰 대비까지 평평하게 만든다
} GuidedUniforms;

#endif /* ShaderTypes_h */
