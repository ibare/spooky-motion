import CoreMedia
import Foundation
import Metal
import os

/// 피부 보정 효과.
///
/// 얼굴 특징점과 피부색으로 피부를 고르고(FaceAnalysis, RegionMask),
/// 가이드 필터로 잡티 같은 낮은 대비 얼룩을 평평하게 한 뒤 미세한 결을 되돌린다(SkinRenderer).
/// 이 파일은 FxPlug 와의 연결(파라미터, 영역, 렌더 호출)만 맡는다.
/// 구조는 SDK 템플릿의 예제(TileableRemoteBrightness)를 따랐다.
@objc(SkinRetouchPlugIn)
class SkinRetouchPlugIn: NSObject, FxTileableEffect {

    /// 파라미터 id. FCP 템플릿(packs/skin-retouch/generate.py)이 "./<id>" 로 퍼블리시한다. 바꾸면 양쪽을 함께 고친다.
    /// (1 은 뼈대 단계의 '확인용 밝기'가 썼으므로 다시 쓰지 않는다.)
    enum Param {
        static let view: UInt32 = 10
        static let tolerance: UInt32 = 11
        static let excludeBeard: UInt32 = 12
        static let amount: UInt32 = 13
        static let size: UInt32 = 14
        static let detail: UInt32 = 15
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
        let d = RetouchParams()
        let flags = FxParameterFlags(kFxParameterFlag_DEFAULT)
        api.addPopupMenu(withName: "보기", parameterID: Param.view, defaultValue: UInt32(d.view),
                         menuEntries: ["결과", "피부 마스크"], parameterFlags: flags)
        api.addFloatSlider(withName: "정도", parameterID: Param.amount,
                           defaultValue: Double(d.amount * 100), parameterMin: 0, parameterMax: 100,
                           sliderMin: 0, sliderMax: 100, delta: 1, parameterFlags: flags)
        api.addFloatSlider(withName: "크기", parameterID: Param.size,
                           defaultValue: Double(d.size * 100), parameterMin: 0.5, parameterMax: 8,
                           sliderMin: 0.5, sliderMax: 6, delta: 0.1, parameterFlags: flags)
        api.addFloatSlider(withName: "결 살리기", parameterID: Param.detail,
                           defaultValue: Double(d.detail * 100), parameterMin: 0, parameterMax: 100,
                           sliderMin: 0, sliderMax: 100, delta: 1, parameterFlags: flags)
        api.addFloatSlider(withName: "피부색 범위", parameterID: Param.tolerance,
                           defaultValue: Double(d.tolerance), parameterMin: 0.5, parameterMax: 6.0,
                           sliderMin: 0.5, sliderMax: 5.0, delta: 0.1, parameterFlags: flags)
        api.addToggleButton(withName: "수염 영역 제외", parameterID: Param.excludeBeard,
                            defaultValue: d.excludeBeard, parameterFlags: flags)
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
        var p = RetouchParams()
        var view: Int32 = 0
        var beard = ObjCBool(true)
        var tolerance = Double(p.tolerance), amount = Double(p.amount * 100)
        var size = Double(p.size * 100), detail = Double(p.detail * 100)
        api.getIntValue(&view, fromParameter: Param.view, at: renderTime)
        api.getBoolValue(&beard, fromParameter: Param.excludeBeard, at: renderTime)
        api.getFloatValue(&tolerance, fromParameter: Param.tolerance, at: renderTime)
        api.getFloatValue(&amount, fromParameter: Param.amount, at: renderTime)
        api.getFloatValue(&size, fromParameter: Param.size, at: renderTime)
        api.getFloatValue(&detail, fromParameter: Param.detail, at: renderTime)
        p.view = view
        p.excludeBeard = beard.boolValue
        p.tolerance = Float(tolerance)
        p.amount = Float(amount / 100)
        p.size = Float(size / 100)
        p.detail = Float(detail / 100)
        pluginState?.pointee = withUnsafeBytes(of: &p) { NSData(bytes: $0.baseAddress, length: $0.count) }
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
        let p: RetouchParams = pluginState?.withUnsafeBytes { $0.loadUnaligned(as: RetouchParams.self) }
            ?? RetouchParams()
        let src = sourceImages[0]
        let started = Date()

        guard let e = MetalDeviceCache.shared.entry(registryID: src.deviceRegistryID),
              let cb = e.queue.makeCommandBuffer(),
              let input = src.metalTexture(for: e.device),
              let output = destinationImage.metalTexture(for: e.device) else {
            throw PlugInError.noDevice
        }
        cb.label = "SkinRetouch"

        // 정도가 0 이고 결과 보기이면 원본 그대로라 얼굴을 찾을 필요가 없다.
        let needFace = p.view == Int32(VM_Mask.rawValue) || p.amount > 0
        let analysis = needFace
            ? src.ioSurface.flatMap {
                FaceAnalyzer.analyze($0, topLeftOrigin: src.imageOrigin == UInt(kFxImageOrigin_TOP_LEFT),
                                     excludeBeard: p.excludeBeard)
            }
            : nil
        let analysisMs = Date().timeIntervalSince(started) * 1000

        // 출력 조각이 원본 텍스처에서 차지하는 범위. 메모리 첫 줄은 조각의 bottom 값 쪽이다.
        let d = destinationImage.tilePixelBounds, s = src.tilePixelBounds
        let sw = Float(s.right - s.left), sh = Float(s.top - s.bottom)
        let texRect = SIMD4<Float>(Float(d.left - s.left) / sw, Float(d.right - s.left) / sw,
                                   Float(d.bottom - s.bottom) / sh, Float(d.top - s.bottom) / sh)

        try e.renderer.encode(cb, input: input, output: output, analysis: analysis, params: p, texRect: texRect)
        cb.commit()
        cb.waitUntilCompleted()

        let totalMs = Date().timeIntervalSince(started) * 1000
        logThrottled(p, analysis, src, destinationImage,
                     timing: String(format: "분석=%.0fms 전체=%.0fms", analysisMs, totalMs))
    }

    // MARK: 진단

    private static let logLock = NSLock()
    private static var lastLog = Date.distantPast

    /// 렌더는 프레임마다 불리므로 1초에 한 번만 기록한다.
    private func logThrottled(_ p: RetouchParams, _ a: FaceAnalysis?, _ src: FxImageTile, _ dst: FxImageTile,
                              timing: String) {
        Self.logLock.lock()
        let now = Date()
        let due = now.timeIntervalSince(Self.lastLog) >= 1
        if due { Self.lastLog = now }
        Self.logLock.unlock()
        guard due else { return }

        let b = dst.tilePixelBounds
        let head = "render 보기=\(p.view) 정도=\(p.amount) 크기=\(p.size) 결=\(p.detail) \(timing) "
            + "\(b.right - b.left)x\(b.top - b.bottom) 원점=\(src.imageOrigin)"
        if let a {
            let m = a.skin.mean
            log.notice("""
                \(head, privacy: .public) 얼굴너비=\(Int(a.faceWidth), privacy: .public) \
                뒤집힘=\(a.flipped, privacy: .public) 피부색도=(\(m.x, privacy: .public), \(m.y, privacy: .public)) \
                밝기=\(a.skin.lumaRef, privacy: .public) 표본=\(a.skin.samples, privacy: .public)
                """)
        } else {
            log.notice("\(head, privacy: .public) 얼굴=없음")
        }
    }
}
