import CoreGraphics
import Foundation
import Metal
import MetalPerformanceShaders

/// 인스펙터 값 중 렌더에 쓰는 것
struct RetouchParams {
    var view: Int32 = Int32(VM_Result.rawValue)
    var tolerance: Float = 3
    var excludeBeard = true
    /// 정도 (0 ~ 1)
    var amount: Float = 0.6
    /// 크기: 평평하게 만들 얼룩의 크기, 얼굴 너비에 대한 비율 (0.025 = 2.5%)
    var size: Float = 0.025
    /// 결 살리기 (0 ~ 1)
    var detail: Float = 0.5
    /// 잡티 지우기 (0 ~ 1)
    var spots: Float = 0.7
}

enum PlugInError: Error {
    case apiUnavailable
    case noDevice
    case metal(String)
}

/// 피부 보정 렌더러.
/// FxPlug 타입을 쓰지 않아서 플러그인 밖(시험 프로그램)에서도 같은 코드로 돌릴 수 있다.
final class SkinRenderer {
    /// 가이드 필터의 eps. 0~1 값 기준으로 대비가 약 0.05 이하인 얼룩(잡티, 붉은 기)을 평평하게 한다.
    static let eps: Float = 0.05 * 0.05
    /// 가이드 필터를 계산하는 저해상도에서의 반경(픽셀). 원본 반경이 이보다 크면 그만큼 줄여서 계산한다.
    static let workRadius: Float = 8
    /// 미세 결(모공)을 가르는 반경 = 얼굴 너비의 0.4%
    static let fineFraction: Float = 0.004
    /// 잡티 찾기: 모공이 사라질 만큼의 흐림 = 얼굴 너비의 0.25%
    static let spotFineFraction: Float = 0.0025
    /// 잡티와 비교할 둘레 반경 = 얼굴 너비의 1%. 이보다 큰 점(큰 점, 콧구멍)은 잡티로 보지 않는다
    static let spotRingFraction: Float = 0.01
    /// 잡티 찾기를 계산하는 해상도: 얼굴 너비가 이 픽셀 수가 되도록 줄인다
    static let spotWorkFace: Float = 500
    /// 안경테, 눈썹 둘레에서 잡티로 보지 않는 반경 = 얼굴 너비의 1.2%
    static let spotGuardFraction: Float = 0.012

    let device: MTLDevice
    private let library: MTLLibrary
    private let square: MTLComputePipelineState
    private let coeff: MTLComputePipelineState
    private var pipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private let lock = NSLock()

    init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        self.library = library
        guard let sq = library.makeFunction(name: "squareKernel"),
              let co = library.makeFunction(name: "coeffKernel") else {
            throw PlugInError.metal("셰이더 함수를 찾지 못했습니다")
        }
        square = try device.makeComputePipelineState(function: sq)
        coeff = try device.makeComputePipelineState(function: co)
    }

    /// 출력 픽셀 형식에 맞는 렌더 파이프라인 (vertexShader + skinFragment)
    private func pipeline(_ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        lock.lock(); defer { lock.unlock() }
        if let p = pipelines[format] { return p }
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "SkinRetouch"
        desc.vertexFunction = library.makeFunction(name: "vertexShader")
        desc.fragmentFunction = library.makeFunction(name: "skinFragment")
        desc.colorAttachments[0].pixelFormat = format
        let p = try device.makeRenderPipelineState(descriptor: desc)
        pipelines[format] = p
        return p
    }

    /// 출력 조각 하나를 그린다.
    ///   input  : 원본 그림 전체
    ///   texRect: 출력 조각이 원본 텍스처에서 차지하는 범위 (u0, u1, v0, v1). v0 이 출력의 첫 줄 쪽이다.
    func encode(_ cb: MTLCommandBuffer, input: MTLTexture, output: MTLTexture, analysis: FaceAnalysis?,
                params p: RetouchParams, texRect: SIMD4<Float>) throws {
        let srcSize = CGSize(width: input.width, height: input.height)
        guard let region = RegionMask.make(analysis, sourceSize: srcSize, device: device, commandBuffer: cb),
              let blank = RegionMask.blank(device) else {
            throw PlugInError.metal("마스크 텍스처를 만들지 못했습니다")
        }
        var low = blank, meanA = blank, meanB = blank, spotFine = blank
        var u = SkinUniforms()
        u.viewMode = p.view
        u.tolerance = p.tolerance
        u.amount = p.amount
        u.detail = p.detail
        u.texel = SIMD2(1 / Float(input.width), 1 / Float(input.height))
        u.spots = p.spots
        if let a = analysis {
            u.hasFace = 1
            u.skinMean = a.skin.mean
            u.invCov = a.skin.invCov
            u.lumaRef = a.skin.lumaRef
            u.fineRadius = max(0.75, Float(a.faceWidth) * Self.fineFraction)
            if let l = RegionMask.lowPass(input, faceWidth: a.faceWidth, device: device, commandBuffer: cb) {
                low = l
            }
            if p.view == Int32(VM_Result.rawValue), p.amount > 0,
               let (ma, mb) = guidedCoefficients(cb, input: input, radius: Float(a.faceWidth) * p.size) {
                meanA = ma; meanB = mb
            }
            u.spotGuard = Float(a.faceWidth) * Self.spotGuardFraction
            u.spotRing = Float(a.faceWidth) * Self.spotRingFraction
            let wantSpots = p.view == Int32(VM_Spots.rawValue) || (p.view == Int32(VM_Result.rawValue) && p.spots > 0)
            if wantSpots, let f = spotLayer(cb, input: input, faceWidth: Float(a.faceWidth)) {
                spotFine = f
            }
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else {
            throw PlugInError.metal("렌더 인코더를 만들지 못했습니다")
        }
        // 출력 조각을 덮는 사각형. 화면 좌표의 위쪽(출력 첫 줄)이 v0 이다 (SDK 예제와 같은 배치).
        let w = Float(output.width), h = Float(output.height)
        let (u0, u1, v0, v1) = (texRect.x, texRect.y, texRect.z, texRect.w)
        var vertices = [
            Vertex2D(position: SIMD2(w / 2, -h / 2), textureCoordinate: SIMD2(u1, v1)),
            Vertex2D(position: SIMD2(-w / 2, -h / 2), textureCoordinate: SIMD2(u0, v1)),
            Vertex2D(position: SIMD2(w / 2, h / 2), textureCoordinate: SIMD2(u1, v0)),
            Vertex2D(position: SIMD2(-w / 2, h / 2), textureCoordinate: SIMD2(u0, v0)),
        ]
        var viewport = SIMD2<UInt32>(UInt32(w), UInt32(h))
        enc.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(w), height: Double(h), znear: -1, zfar: 1))
        enc.setRenderPipelineState(try pipeline(output.pixelFormat))
        enc.setVertexBytes(&vertices, length: MemoryLayout<Vertex2D>.stride * vertices.count,
                           index: Int(VI_Vertices.rawValue))
        enc.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<UInt32>>.size, index: Int(VI_ViewportSize.rawValue))
        enc.setFragmentTexture(input, index: Int(TI_Source.rawValue))
        enc.setFragmentTexture(region, index: Int(TI_Region.rawValue))
        enc.setFragmentTexture(low, index: Int(TI_LowPass.rawValue))
        enc.setFragmentTexture(meanA, index: Int(TI_MeanA.rawValue))
        enc.setFragmentTexture(meanB, index: Int(TI_MeanB.rawValue))
        enc.setFragmentTexture(spotFine, index: Int(TI_SpotFine.rawValue))
        enc.setFragmentBytes(&u, length: MemoryLayout<SkinUniforms>.stride, index: Int(FI_Uniforms.rawValue))
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }

    /// 빠른 가이드 필터의 계수 평균 (mean(a), mean(b)) 을 저해상도에서 구한다.
    /// radius 는 원본 픽셀 단위. 저해상도에서의 반경이 workRadius 가 되도록 줄인다.
    /// 분산(mean(I²) - mean(I)²)은 16비트로 계산하면 오차가 eps 와 비슷해지므로 32비트로 한다.
    private func guidedCoefficients(_ cb: MTLCommandBuffer, input: MTLTexture,
                                    radius: Float) -> (MTLTexture, MTLTexture)? {
        let scale = min(1, Self.workRadius / max(radius, 1))
        let ww = max(8, Int((Float(input.width) * scale).rounded()))
        let wh = max(8, Int((Float(input.height) * scale).rounded()))
        let r = max(0.5, radius * Float(ww) / Float(input.width))

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: ww, height: wh,
                                                            mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        func tex() -> MTLTexture? { device.makeTexture(descriptor: desc) }
        guard let i = tex(), let ii = tex(), let mi = tex(), let mii = tex(),
              let a = tex(), let b = tex(), let ma = tex(), let mb = tex() else { return nil }

        MPSImageBilinearScale(device: device).encode(commandBuffer: cb, sourceTexture: input, destinationTexture: i)
        dispatch(cb, square, textures: [i, ii], width: ww, height: wh)
        let blur = MPSImageGaussianBlur(device: device, sigma: r)
        blur.encode(commandBuffer: cb, sourceTexture: i, destinationTexture: mi)
        blur.encode(commandBuffer: cb, sourceTexture: ii, destinationTexture: mii)
        var g = GuidedUniforms(eps: Self.eps)
        dispatch(cb, coeff, textures: [mi, mii, a, b], width: ww, height: wh, bytes: &g,
                 length: MemoryLayout<GuidedUniforms>.size)
        blur.encode(commandBuffer: cb, sourceTexture: a, destinationTexture: ma)
        blur.encode(commandBuffer: cb, sourceTexture: b, destinationTexture: mb)
        return (ma, mb)
    }

    /// 잡티 찾기용 흐린 영상: 모공만 사라질 만큼 흐린 것. 얼굴 너비가 spotWorkFace 가 되도록 줄여서 계산한다.
    private func spotLayer(_ cb: MTLCommandBuffer, input: MTLTexture, faceWidth: Float) -> MTLTexture? {
        let scale = min(1, Self.spotWorkFace / max(faceWidth, 1))
        let ww = max(8, Int((Float(input.width) * scale).rounded()))
        let wh = max(8, Int((Float(input.height) * scale).rounded()))
        let face = faceWidth * Float(ww) / Float(input.width)

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: ww, height: wh,
                                                            mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        guard let small = device.makeTexture(descriptor: desc), let fine = device.makeTexture(descriptor: desc) else {
            return nil
        }
        MPSImageBilinearScale(device: device).encode(commandBuffer: cb, sourceTexture: input, destinationTexture: small)
        MPSImageGaussianBlur(device: device, sigma: max(0.5, face * Self.spotFineFraction))
            .encode(commandBuffer: cb, sourceTexture: small, destinationTexture: fine)
        return fine
    }

    private func dispatch(_ cb: MTLCommandBuffer, _ ps: MTLComputePipelineState, textures: [MTLTexture],
                          width: Int, height: Int, bytes: UnsafeRawPointer? = nil, length: Int = 0) {
        guard let enc = cb.makeComputeCommandEncoder() else { return }
        enc.setComputePipelineState(ps)
        for (k, t) in textures.enumerated() { enc.setTexture(t, index: k) }
        if let bytes { enc.setBytes(bytes, length: length, index: 0) }
        let tw = ps.threadExecutionWidth
        let th = max(1, ps.maxTotalThreadsPerThreadgroup / tw)
        enc.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        enc.endEncoding()
    }
}
