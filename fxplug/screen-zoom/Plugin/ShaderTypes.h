// Swift 와 Metal 셰이더가 함께 쓰는 타입과 버퍼 번호
#ifndef ShaderTypes_h
#define ShaderTypes_h

#import <simd/simd.h>

typedef enum VertexInputIndex {
    VI_Vertices     = 0,
    VI_ViewportSize = 1
} VertexInputIndex;

typedef enum FragmentIndex {
    FI_Uniforms = 0,
    FI_Samples  = 1    // 모션 블러 표본 (zoom, offset.x, offset.y, 0) 배열
} FragmentIndex;

typedef enum TextureIndex {
    TI_Source = 0
} TextureIndex;

typedef struct Vertex2D {
    vector_float2 position;
    vector_float2 textureCoordinate;
} Vertex2D;

/// 보기 방식 (인스펙터 '영역 고르기' 체크박스)
typedef enum ZoomMode {
    ZM_Result = 0,   // 확대한 결과
    ZM_Select = 1    // 원래 화면에서 영역 밖을 어둡게
} ZoomMode;

/// zoomFragment 가 쓰는 값. 좌표는 모두 원본 그림 전체 기준의 픽셀(y 는 위쪽이 +)이다.
/// 메모리 줄 r 의 그림 y 는 origin.y + rowSign * (r + 0.5) 이다 (원점이 왼쪽 아래면 rowSign = +1).
typedef struct ZoomUniforms {
    vector_float2 imageSize;    // 원본 그림 전체 크기 (픽셀)
    vector_float2 dstOrigin;    // 출력 조각 메모리 첫 픽셀 모서리의 그림 좌표
    vector_float2 srcOrigin;    // 원본 조각 메모리 첫 픽셀 모서리의 그림 좌표
    vector_float2 srcSize;      // 원본 조각 크기 (픽셀)
    vector_float2 offset;       // 원본 좌표 = 출력 좌표 / zoom + offset (정규 좌표 0~1)
    vector_float4 region;       // 영역 (정규 좌표: 왼쪽, 아래, 오른쪽, 위)
    float dstRowSign;
    float srcRowSign;
    float zoom;                 // 지금 배율 (1 = 그대로)
    float dim;                  // 영역 고르기에서 영역 밖 밝기
    int mode;                   // ZoomMode
    int sampleCount;            // 모션 블러 표본 수. 1 이면 zoom, offset 하나로 그린다
} ZoomUniforms;

/// 조절점(OSC) 그리기용 꼭짓점. 위치는 화면 좌표(-1 ~ 1), 색은 알파를 곱한 값이다.
typedef struct OSCVertex {
    vector_float2 position;
    vector_float4 color;
} OSCVertex;

#endif /* ShaderTypes_h */
