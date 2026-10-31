import CoreMedia
import Foundation
import Metal
import os

/// 피부 보정 효과.
///
/// 2단계(피부 마스크): 얼굴 특징점과 피부색으로 보정할 피부를 고른다.
/// '보기'를 '피부 마스크'로 두면 고른 곳만 원래 색으로 보여 준다. '결과'는 아직 원본 그대로다.
/// 구조는 SDK 템플릿의 예제(TileableRemoteBrightness)를 따랐다.
@objc(SkinRetouchPlugIn)
class SkinRetouchPlugIn: NSObject, FxTileableEffect {

    /// 파라미터 id. FCP 템플릿(packs/skin-retouch/generate.py)이 "./<id>" 로 퍼블리시한다. 바꾸면 양쪽을 함께 고친다.
    /// (1 은 뼈대 단계의 '확인용 밝기'가 썼으므로 다시 쓰지 않는다.)
    enum Param {
        static let view: UInt32 = 10
        static let tolerance: UInt32 = 11
        static let excludeBeard: UInt32 = 12
    }

    /// 렌더로 넘기는 파라미터 값 묶음
    struct State {
        var view: Int32 = Int32(VM_Result.rawValue)
        var excludeBeard: Int32 = 1
        var tolerance: Float = 3
    }

    private let apiManager: PROAPIAccessing

    required init?(apiManager: PROAPIAccessing) {
        self.apiManager = apiManager
        super.init()
    }

    // MARK: 파라미터

    func addParameters() throws {
        guard let api = apiManager.api(for: FxParameterCreationAPI_v5.self) as? FxParameterCreationAPI_v5 else {
            throw PlugInError.apiUnavailable
        }
        let flags = FxParameterFlags(kFxParameterFlag_DEFAULT)
        api.addPopupMenu(withName: "보기", parameterID: Param.view, defaultValue: 0,
                         menuEntries: ["결과", "피부 마스크"], parameterFlags: flags)
        api.addFloatSlider(withName: "피부색 범위", parameterID: Param.tolerance,
                           defaultValue: 3.0, parameterMin: 0.5, parameterMax: 6.0,
                           sliderMin: 0.5, sliderMax: 5.0, delta: 0.1, parameterFlags: flags)
        api.addToggleButton(withName: "수염 영역 제외", parameterID: Param.excludeBeard,
                            defaultValue: true, parameterFlags: flags)
    }

    func properties(_ properties: AutoreleasingUnsafeMutablePointer<NSDictionary>?) throws {
        properties?.pointee = [
            kFxPropertyKey_MayRemapTime: false,
            kFxPropertyKey_PixelTransformSupport: kFxPixelTransform_ScaleTranslate,
            kFxPropertyKey_VariesWhenParamsAreStatic: false,
        ] as NSDictionary
    }

    /// 렌더에 필요한 파라미터 값을 묶어 넘긴다. 렌더는 다른 스레드에서 불리므로 값만 담는다.
    func pluginState(_ pluginState: AutoreleasingUnsafeMutablePointer<NSData>?,
                     at renderTime: CMTime, quality qualityLevel: UInt) throws {
        guard let api = apiManager.api(for: FxParameterRetrievalAPI_v6.self) as? FxParameterRetrievalAPI_v6 else {
            throw PlugInError.apiUnavailable
        }
        var view: Int32 = 0
        var beard = ObjCBool(true)
        var tolerance = 3.0
        api.getIntValue(&view, fromParameter: Param.view, at: renderTime)
        api.getBoolValue(&beard, fromParameter: Param.excludeBeard, at: renderTime)
        api.getFloatValue(&tolerance, fromParameter: Param.tolerance, at: renderTime)
        var state = State(view: view, excludeBeard: beard.boolValue ? 1 : 0, tolerance: Float(tolerance))
        pluginState?.pointee = withUnsafeBytes(of: &state) { NSData(bytes: $0.baseAddress, length: $0.count) }
    }

    // MARK: 영역

    func destinationImageRect(_ destinationImageRect: UnsafeMutablePointer<FxRect>,
                              sourceImages: [FxImageTile], destinationImage: FxImageTile,
                              pluginState: Data?, at renderTime: CMTime) throws {
        destinationImageRect.pointee = sourceImages[0].imagePixelBounds
    }

    /// 얼굴 분석은 그림 전체가 필요하므로, 출력 조각이 무엇이든 원본 전체를 받는다.
    func sourceTileRect(_ sourceTileRect: UnsafeMutablePointer<FxRect>, sourceImageIndex: UInt,
                        sourceImages: [FxImageTile], destinationTileRect: FxRect,
                        destinationImage: FxImageTile, pluginState: Data?, at renderTime: CMTime) throws {
        sourceTileRect.pointee = sourceImages[0].imagePixelBounds
    }

    // MARK: 렌더

    func renderDestinationImage(_ destinationImage: FxImageTile, sourceImages: [FxImageTile],
                                pluginState: Data?, at renderTime: CMTime) throws {
        let st: State = pluginState?.withUnsafeBytes { $0.loadUnaligned(as: State.self) } ?? State()
        let src = sourceImages[0]
        let started = Date()

        let cache = MetalDeviceCache.shared
        let registryID = src.deviceRegistryID
        let pixelFormat = MetalDeviceCache.pixelFormat(for: destinationImage)
        guard let device = cache.device(registryID: registryID),
              let queue = cache.commandQueue(registryID: registryID),
              let commandBuffer = queue.makeCommandBuffer() else {
            throw PlugInError.noDevice
        }
        let pipeline = try cache.pipeline(registryID: registryID, pixelFormat: pixelFormat)
        commandBuffer.label = "SkinRetouch"

        // 얼굴 분석은 마스크가 필요할 때만 한다 (2단계에서는 '피부 마스크' 보기일 때만).
        let wantMask = st.view == Int32(VM_Mask.rawValue)
        let analysis = wantMask
            ? src.ioSurface.flatMap {
                FaceAnalyzer.analyze($0, topLeftOrigin: src.imageOrigin == UInt(kFxImageOrigin_TOP_LEFT),
                                     excludeBeard: st.excludeBeard != 0)
            }
            : nil
        let analysisMs = Date().timeIntervalSince(started) * 1000
        let srcSize = CGSize(width: src.ioSurface.width, height: src.ioSurface.height)
        guard let region = RegionMask.make(analysis, sourceSize: srcSize, device: device,
                                           commandBuffer: commandBuffer) else {
            throw PlugInError.metal("마스크 텍스처를 만들지 못했습니다")
        }

        var u = SkinUniforms()
        u.viewMode = st.view
        u.tolerance = st.tolerance
        if let a = analysis {
            u.hasFace = 1
            u.skinMean = a.skin.mean
            u.invCov = a.skin.invCov
            u.lumaRef = a.skin.lumaRef
        }

        let inputTexture = src.metalTexture(for: device)
        let outputTexture = destinationImage.metalTexture(for: device)
        var lowPass: MTLTexture? = nil
        if let a = analysis, let input = inputTexture {
            lowPass = RegionMask.lowPass(input, faceWidth: a.faceWidth, device: device, commandBuffer: commandBuffer)
        }
        guard let low = lowPass ?? RegionMask.blank(device) else {
            throw PlugInError.metal("흐린 영상 텍스처를 만들지 못했습니다")
        }

        let attachment = MTLRenderPassColorAttachmentDescriptor()
        attachment.texture = outputTexture
        attachment.clearColor = MTLClearColorMake(0, 0, 0, 0)
        attachment.loadAction = .clear
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0] = attachment
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw PlugInError.metal("렌더 인코더를 만들지 못했습니다")
        }

        // 출력 조각을 덮는 사각형. 텍스처 좌표는 원본 전체에서 이 조각이 차지하는 부분이다.
        // 출력의 첫 줄(화면 좌표 위쪽)이 메모리 첫 줄이며, 그 줄은 조각의 bottom 값 쪽이다 (SDK 예제와 같은 배치).
        let d = destinationImage.tilePixelBounds, s = src.tilePixelBounds
        let sw = Float(s.right - s.left), sh = Float(s.top - s.bottom)
        let u0 = Float(d.left - s.left) / sw, u1 = Float(d.right - s.left) / sw
        let v0 = Float(d.bottom - s.bottom) / sh, v1 = Float(d.top - s.bottom) / sh
        let w = Float(d.right - d.left), h = Float(d.top - d.bottom)
        var vertices = [
            Vertex2D(position: vector_float2(w / 2, -h / 2), textureCoordinate: vector_float2(u1, v1)),
            Vertex2D(position: vector_float2(-w / 2, -h / 2), textureCoordinate: vector_float2(u0, v1)),
            Vertex2D(position: vector_float2(w / 2, h / 2), textureCoordinate: vector_float2(u1, v0)),
            Vertex2D(position: vector_float2(-w / 2, h / 2), textureCoordinate: vector_float2(u0, v0)),
        ]
        var viewportSize = simd_uint2(UInt32(w), UInt32(h))

        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(w), height: Double(h),
                                        znear: -1, zfar: 1))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&vertices, length: MemoryLayout<Vertex2D>.stride * vertices.count,
                               index: Int(VI_Vertices.rawValue))
        encoder.setVertexBytes(&viewportSize, length: MemoryLayout<simd_uint2>.size,
                               index: Int(VI_ViewportSize.rawValue))
        encoder.setFragmentTexture(inputTexture, index: Int(TI_Source.rawValue))
        encoder.setFragmentTexture(region, index: Int(TI_Region.rawValue))
        encoder.setFragmentTexture(low, index: Int(TI_LowPass.rawValue))
        encoder.setFragmentBytes(&u, length: MemoryLayout<SkinUniforms>.stride, index: Int(FI_Uniforms.rawValue))
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let totalMs = Date().timeIntervalSince(started) * 1000
        logThrottled(st, analysis, src, destinationImage,
                     timing: String(format: "분석=%.0fms 전체=%.0fms", analysisMs, totalMs))
    }

    // MARK: 진단

    private static let logLock = NSLock()
    private static var lastLog = Date.distantPast

    /// 렌더는 프레임마다 불리므로 1초에 한 번만 기록한다.
    private func logThrottled(_ st: State, _ a: FaceAnalysis?, _ src: FxImageTile, _ dst: FxImageTile,
                              timing: String) {
        Self.logLock.lock()
        let now = Date()
        let due = now.timeIntervalSince(Self.lastLog) >= 1
        if due { Self.lastLog = now }
        Self.logLock.unlock()
        guard due else { return }

        let b = dst.tilePixelBounds
        let tile = "\(timing) \(b.right - b.left)x\(b.top - b.bottom) 원점=\(src.imageOrigin)"
        if let a {
            let m = a.skin.mean
            log.notice("""
                render 보기=\(st.view, privacy: .public) \(tile, privacy: .public) \
                얼굴너비=\(Int(a.faceWidth), privacy: .public) 뒤집힘=\(a.flipped, privacy: .public) \
                피부색도=(\(m.x, privacy: .public), \(m.y, privacy: .public)) 밝기=\(a.skin.lumaRef, privacy: .public) \
                표본=\(a.skin.samples, privacy: .public) 색공간=\(String(describing: src.colorSpace), privacy: .public)
                """)
        } else {
            log.notice("render 보기=\(st.view, privacy: .public) \(tile, privacy: .public) 얼굴=없음")
        }
    }
}
