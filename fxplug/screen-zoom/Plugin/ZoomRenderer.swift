import Foundation
import Metal
import simd

enum PlugInError: Error {
    case apiUnavailable
    case noDevice
    case metal(String)
}

/// 렌더에 넘기는 값. 렌더는 다른 스레드에서 불리므로 값만 담는다.
struct ZoomState {
    var mode: Int32 = Int32(ZM_Result.rawValue)
    var zoom: Float = 1
    /// 원본 좌표 = 출력 좌표 / zoom + offset (정규 좌표)
    var offset = SIMD2<Float>(0, 0)
    /// 영역 (정규 좌표: 왼쪽, 아래, 오른쪽, 위)
    var region = SIMD4<Float>(0, 0, 1, 1)
    /// 뒤에 붙는 모션 블러 표본 수
    var sampleCount: Int32 = 0

    /// 렌더에 넘길 바이트: 상태 뒤에 표본 (zoom, offset.x, offset.y, 0) 들을 붙인다
    static func pack(_ st: ZoomState, samples: [ZoomMath.Transform]) -> Data {
        var st = st
        st.sampleCount = Int32(samples.count)
        var data = withUnsafeBytes(of: &st) { Data($0) }
        let packed = samples.map { SIMD4<Float>(Float($0.zoom), Float($0.offset.x), Float($0.offset.y), 0) }
        packed.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }

    static func unpack(_ data: Data?) -> (ZoomState, [SIMD4<Float>]) {
        guard let data, data.count >= MemoryLayout<ZoomState>.size else { return (ZoomState(), []) }
        let st = data.withUnsafeBytes { $0.loadUnaligned(as: ZoomState.self) }
        let stride = MemoryLayout<SIMD4<Float>>.stride
        let n = max(0, min(Int(st.sampleCount), (data.count - MemoryLayout<ZoomState>.size) / stride))
        let samples = (0..<n).map { k in
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: MemoryLayout<ZoomState>.size + k * stride,
                                                    as: SIMD4<Float>.self) }
        }
        return (st, samples)
    }
}

/// 픽셀 사각형 (FxRect 와 같은 뜻: y 는 위쪽이 +)
struct PixelRect {
    var left: Int32, bottom: Int32, right: Int32, top: Int32
    var width: Int32 { right - left }
    var height: Int32 { top - bottom }
}

/// 확대 렌더. FxPlug 타입을 쓰지 않아서 플러그인 밖(시험 프로그램)에서도 같은 코드로 돌릴 수 있다.
enum ZoomRenderer {
    /// 셰이더 값. 좌표는 원본 그림 전체 기준 픽셀(y 위쪽이 +)이고,
    /// 메모리 첫 줄이 위(topLeft)인지 아래인지에 따라 줄 방향을 정한다.
    static func uniforms(_ st: ZoomState, image img: PixelRect, destination d: PixelRect, destinationTopLeft: Bool,
                         source s: PixelRect, sourceTopLeft: Bool) -> ZoomUniforms {
        func origin(_ t: PixelRect, topLeft: Bool) -> SIMD2<Float> {
            SIMD2(Float(t.left - img.left), Float((topLeft ? t.top : t.bottom) - img.bottom))
        }
        var u = ZoomUniforms()
        u.imageSize = SIMD2(Float(img.width), Float(img.height))
        u.dstOrigin = origin(d, topLeft: destinationTopLeft)
        u.dstRowSign = destinationTopLeft ? -1 : 1
        u.srcOrigin = origin(s, topLeft: sourceTopLeft)
        u.srcRowSign = sourceTopLeft ? -1 : 1
        u.srcSize = SIMD2(Float(s.width), Float(s.height))
        u.offset = st.offset
        u.zoom = st.zoom
        u.region = st.region
        u.dim = ZoomMath.outsideDim
        u.mode = st.mode
        u.sampleCount = 1
        return u
    }

    /// 출력 텍스처 전체를 덮는 사각형 하나로 zoomFragment 를 그린다.
    /// samples 가 둘 이상이면 모션 블러로 그린다 (셰이더가 표본마다 읽어 평균한다).
    static func encode(_ cb: MTLCommandBuffer, pipeline: MTLRenderPipelineState, input: MTLTexture,
                       output: MTLTexture, uniforms: ZoomUniforms, samples: [SIMD4<Float>] = []) throws {
        var u = uniforms
        // 셰이더가 표본 버퍼를 늘 받도록 하나는 채워 둔다
        var bound = samples.isEmpty ? [SIMD4<Float>(u.zoom, u.offset.x, u.offset.y, 0)] : samples
        u.sampleCount = Int32(samples.count > 1 ? samples.count : 1)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else {
            throw PlugInError.metal("렌더 인코더를 만들지 못했습니다")
        }
        let w = Float(output.width), h = Float(output.height)
        var vertices = [
            Vertex2D(position: SIMD2(w / 2, -h / 2), textureCoordinate: SIMD2(1, 1)),
            Vertex2D(position: SIMD2(-w / 2, -h / 2), textureCoordinate: SIMD2(0, 1)),
            Vertex2D(position: SIMD2(w / 2, h / 2), textureCoordinate: SIMD2(1, 0)),
            Vertex2D(position: SIMD2(-w / 2, h / 2), textureCoordinate: SIMD2(0, 0)),
        ]
        var viewport = SIMD2<UInt32>(UInt32(w), UInt32(h))
        enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(w), height: Double(h), znear: -1, zfar: 1))
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&vertices, length: MemoryLayout<Vertex2D>.stride * vertices.count,
                           index: Int(VI_Vertices.rawValue))
        enc.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<UInt32>>.size, index: Int(VI_ViewportSize.rawValue))
        enc.setFragmentTexture(input, index: Int(TI_Source.rawValue))
        enc.setFragmentBytes(&u, length: MemoryLayout<ZoomUniforms>.stride, index: Int(FI_Uniforms.rawValue))
        enc.setFragmentBytes(&bound, length: MemoryLayout<SIMD4<Float>>.stride * bound.count,
                             index: Int(FI_Samples.rawValue))
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }
}
