import CoreMedia
import Foundation
import Metal
import os
import simd

/// 파라미터 id. FCP 템플릿(packs/screen-zoom/generate.py)이 "./<id>" 로 퍼블리시한다. 바꾸면 양쪽을 함께 고친다.
enum ZoomParam {
    static let select: UInt32 = 1
    static let center: UInt32 = 2
    static let scale: UInt32 = 3
    static let move: UInt32 = 4
    static let hold: UInt32 = 5
    static let curve: UInt32 = 6
    static let blur: UInt32 = 7
}

/// 인스펙터 값
struct ZoomSettings {
    var select = false
    var center = SIMD2<Double>(0.5, 0.5)
    var scale = ZoomMath.defaultScale
    var move = ZoomMath.defaultMoveSeconds
    var hold = ZoomMath.defaultHoldSeconds
    var curve = ZoomMath.Curve.premium
    var blur = true

    var region: ZoomMath.Region { ZoomMath.region(center: center, scale: scale) }

    static func read(_ api: FxParameterRetrievalAPI_v6, at time: CMTime) -> ZoomSettings {
        var s = ZoomSettings()
        var select = ObjCBool(false), blur = ObjCBool(s.blur)
        var curve = s.curve.rawValue
        var x = s.center.x, y = s.center.y
        api.getBoolValue(&select, fromParameter: ZoomParam.select, at: time)
        api.getXValue(&x, yValue: &y, fromParameter: ZoomParam.center, at: time)
        api.getFloatValue(&s.scale, fromParameter: ZoomParam.scale, at: time)
        api.getFloatValue(&s.move, fromParameter: ZoomParam.move, at: time)
        api.getFloatValue(&s.hold, fromParameter: ZoomParam.hold, at: time)
        api.getIntValue(&curve, fromParameter: ZoomParam.curve, at: time)
        api.getBoolValue(&blur, fromParameter: ZoomParam.blur, at: time)
        s.select = select.boolValue
        s.curve = ZoomMath.Curve(rawValue: curve) ?? .premium
        s.blur = blur.boolValue
        s.center = SIMD2(x, y)
        return s
    }

    /// 클립 처음부터 지난 시간(초) → 곡선을 적용한 진행도
    func eased(_ clock: Clock) -> (Double) -> Double {
        { t in ZoomMath.eased(time: t, duration: clock.duration, frame: clock.frame, move: move, hold: hold,
                              curve: curve) }
    }

    /// 이 시각의 확대 변환 (영역 고르기와 상관없이 결과 화면 기준). 렌더와 뷰어 조절점이 함께 쓴다.
    func transform(apiManager: PROAPIAccessing, at time: CMTime) -> (ZoomMath.Transform, Clock, Double) {
        let clock = Clock(apiManager: apiManager, renderTime: time)
        let e = eased(clock)(clock.local)
        return (ZoomMath.transform(region: region, eased: e), clock, e)
    }
}

/// 화면 확대 효과.
///
/// 클립(보통 잘라 낸 구간)이 시작하면 고른 영역으로 확대해 들어가고, 끝나기 전에(또는 '유지 시간' 뒤에) 원래 화면으로 돌아온다.
/// 영역은 뷰어의 조절점(ScreenZoomOSC)이나 인스펙터의 '가운데', '배율'로 정한다.
/// 계산은 ZoomMath, 그리기는 Shaders.metal 이 맡고, 이 파일은 FxPlug 와의 연결만 한다.
@objc(ScreenZoomPlugIn)
class ScreenZoomPlugIn: NSObject, FxTileableEffect {

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
        // 구간마다 영역이 하나이므로 키프레임은 쓰지 않는다
        let flags = FxParameterFlags(kFxParameterFlag_NOT_ANIMATABLE)
        let d = ZoomSettings()
        api.addToggleButton(withName: "영역 고르기", parameterID: ZoomParam.select,
                            defaultValue: d.select, parameterFlags: flags)
        api.addPointParameter(withName: "가운데", parameterID: ZoomParam.center,
                              defaultX: d.center.x, defaultY: d.center.y, parameterFlags: flags)
        api.addFloatSlider(withName: "배율", parameterID: ZoomParam.scale,
                           defaultValue: d.scale, parameterMin: ZoomMath.minScale, parameterMax: ZoomMath.maxScale,
                           sliderMin: ZoomMath.minScale, sliderMax: 5, delta: 0.1, parameterFlags: flags)
        api.addFloatSlider(withName: "움직임 시간", parameterID: ZoomParam.move,
                           defaultValue: d.move, parameterMin: 0, parameterMax: ZoomMath.maxMoveSeconds,
                           sliderMin: 0, sliderMax: 2, delta: 0.05, parameterFlags: flags)
        api.addFloatSlider(withName: "유지 시간", parameterID: ZoomParam.hold,
                           defaultValue: d.hold, parameterMin: 0, parameterMax: ZoomMath.maxHoldSeconds,
                           sliderMin: 0, sliderMax: 30, delta: 0.5, parameterFlags: flags)
        // 메뉴 순서는 ZoomMath.Curve 의 값 순서와 같다
        api.addPopupMenu(withName: "움직임 곡선", parameterID: ZoomParam.curve, defaultValue: UInt32(d.curve.rawValue),
                         menuEntries: ["고급", "부드럽게"], parameterFlags: flags)
        api.addToggleButton(withName: "모션 블러", parameterID: ZoomParam.blur,
                            defaultValue: d.blur, parameterFlags: flags)
    }

    func properties(_ properties: AutoreleasingUnsafeMutablePointer<NSDictionary>?) throws {
        properties?.pointee = [
            kFxPropertyKey_MayRemapTime: false,
            kFxPropertyKey_PixelTransformSupport: kFxPixelTransform_ScaleTranslate,
            // 파라미터가 그대로여도 시간에 따라 배율이 바뀐다
            kFxPropertyKey_VariesWhenParamsAreStatic: true,
        ] as NSDictionary
    }

    /// 지금 시각의 확대 상태를 계산해 렌더에 넘긴다.
    func pluginState(_ pluginState: AutoreleasingUnsafeMutablePointer<NSData>?,
                     at renderTime: CMTime, quality qualityLevel: UInt) throws {
        guard let params = apiManager.api(for: FxParameterRetrievalAPI_v6.self) as? FxParameterRetrievalAPI_v6 else {
            throw PlugInError.apiUnavailable
        }
        let s = ZoomSettings.read(params, at: renderTime)
        let r = s.region
        var st = ZoomState()
        st.region = SIMD4(Float(r.minCorner.x), Float(r.minCorner.y), Float(r.maxCorner.x), Float(r.maxCorner.y))

        if s.select {
            st.mode = Int32(ZM_Select.rawValue)
        } else {
            let clock = Clock(apiManager: apiManager, renderTime: renderTime, effect: self)
            let eased = s.eased(clock)
            let e = eased(clock.local)
            let tr = ZoomMath.transform(region: r, eased: e)
            st.offset = SIMD2(Float(tr.offset.x), Float(tr.offset.y))
            st.zoom = Float(tr.zoom)
            // 모션 블러: 셔터가 열린 동안의 변환 표본. 출력(타임라인) 프레임 길이 기준이다.
            let samples = s.blur
                ? ZoomMath.shutterSamples(region: r, at: clock.local, shutter: ZoomMath.shutter * clock.outputFrame,
                                          eased: eased)
                : [tr]
            logThrottled("state \(clock.description) 진행=\(String(format: "%.3f", e)) 배율=\(String(format: "%.3f", tr.zoom)) "
                         + "곡선=\(s.curve.rawValue) 블러표본=\(samples.count)")
            pluginState?.pointee = ZoomState.pack(st, samples: samples.count > 1 ? samples : []) as NSData
            return
        }
        pluginState?.pointee = ZoomState.pack(st, samples: []) as NSData
    }

    // MARK: 영역

    func destinationImageRect(_ destinationImageRect: UnsafeMutablePointer<FxRect>,
                              sourceImages: [FxImageTile], destinationImage: FxImageTile,
                              pluginState: Data?, at renderTime: CMTime) throws {
        destinationImageRect.pointee = sourceImages[0].imagePixelBounds
    }

    /// 확대하면 출력 조각이 원본의 어느 곳이든 읽을 수 있으므로 원본 전체를 받는다.
    func sourceTileRect(_ sourceTileRect: UnsafeMutablePointer<FxRect>, sourceImageIndex: UInt,
                        sourceImages: [FxImageTile], destinationTileRect: FxRect,
                        destinationImage: FxImageTile, pluginState: Data?, at renderTime: CMTime) throws {
        sourceTileRect.pointee = sourceImages[0].imagePixelBounds
    }

    // MARK: 렌더

    func renderDestinationImage(_ destinationImage: FxImageTile, sourceImages: [FxImageTile],
                                pluginState: Data?, at renderTime: CMTime) throws {
        let (st, samples) = ZoomState.unpack(pluginState)
        let src = sourceImages[0]
        guard let e = MetalDeviceCache.shared.entry(registryID: src.deviceRegistryID),
              let cb = e.queue.makeCommandBuffer(),
              let input = src.metalTexture(for: e.device),
              let output = destinationImage.metalTexture(for: e.device) else {
            throw PlugInError.noDevice
        }
        cb.label = "ScreenZoom"

        func rect(_ r: FxRect) -> PixelRect { PixelRect(left: r.left, bottom: r.bottom, right: r.right, top: r.top) }
        let img = src.imagePixelBounds, d = destinationImage.tilePixelBounds, s = src.tilePixelBounds
        let u = ZoomRenderer.uniforms(st, image: rect(img),
                                      destination: rect(d),
                                      destinationTopLeft: destinationImage.imageOrigin == UInt(kFxImageOrigin_TOP_LEFT),
                                      source: rect(s),
                                      sourceTopLeft: src.imageOrigin == UInt(kFxImageOrigin_TOP_LEFT))
        try ZoomRenderer.encode(cb, pipeline: try e.zoomPipeline(output.pixelFormat), input: input, output: output,
                                uniforms: u, samples: samples)
        cb.commit()
        cb.waitUntilCompleted()

        logThrottled("render \(d.right - d.left)x\(d.top - d.bottom) 원본조각=\(s.right - s.left)x\(s.top - s.bottom) "
                     + "전체=\(img.right - img.left)x\(img.top - img.bottom) 원점=\(src.imageOrigin)/\(destinationImage.imageOrigin) "
                     + "보기=\(st.mode) 배율=\(st.zoom) 표본=\(samples.count)", key: 1)
    }

    // MARK: 진단

    private static let logLock = NSLock()
    private static var lastLog: [Int: Date] = [:]

    /// 렌더는 프레임마다 불리므로 종류마다 1초에 한 번만 기록한다.
    func logThrottled(_ message: @autoclosure () -> String, key: Int = 0) {
        Self.logLock.lock()
        let now = Date()
        let due = now.timeIntervalSince(Self.lastLog[key] ?? .distantPast) >= 1
        if due { Self.lastLog[key] = now }
        Self.logLock.unlock()
        guard due else { return }
        let text = message()
        log.notice("\(text, privacy: .public)")
    }
}

/// 클립 처음부터 지난 시간과 클립 길이(초).
///
/// FCP 에서 startTimeOfInputToFilter 는 클립 원본 기준의 시작 시각(앞을 잘라 낸 만큼)이고,
/// durationTimeOfInputToFilter 는 효과를 건 클립의 길이다 (FxTimingAPI.h).
/// 렌더 시각도 같은 원본 기준이라고 보고 시작 시각을 뺀다. 기록에 값들을 남겨 FCP 에서 확인한다.
struct Clock: CustomStringConvertible {
    var render = CMTime.zero
    var start = CMTime.zero
    var length = CMTime.zero
    var frameDuration = CMTime.zero
    var effectStart = CMTime.zero
    var effectLength = CMTime.zero
    var timeline = CMTime.zero
    /// 타임라인 프레임 길이(초). 효과를 넘기지 않으면 0 이고 outputFrame 은 클립 프레임 길이를 쓴다.
    var timelineFrame = 0.0

    init(apiManager: PROAPIAccessing, renderTime: CMTime, effect: FxTileableEffect? = nil) {
        render = renderTime
        guard let api = apiManager.api(for: FxTimingAPI_v4.self) as? FxTimingAPI_v4 else {
            log.error("FxTimingAPI_v4 를 얻지 못했습니다")
            return
        }
        api.startTimeOfInput(toFilter: &start)
        api.durationTimeOfInput(toFilter: &length)
        api.frameDuration(&frameDuration)
        api.startTime(forEffect: &effectStart)
        api.durationTime(forEffect: &effectLength)
        api.timelineTime(&timeline, fromInputTime: renderTime)
        if let effect {
            let num = api.timelineFpsNumerator(for: effect), den = api.timelineFpsDenominator(for: effect)
            if num > 0 && den > 0 { timelineFrame = Double(den) / Double(num) }
        }
    }

    private static func seconds(_ t: CMTime) -> Double {
        t.isNumeric ? CMTimeGetSeconds(t) : 0
    }

    var local: Double { Self.seconds(render) - Self.seconds(start) }
    var duration: Double { Self.seconds(length) }
    var frame: Double { Self.seconds(frameDuration) }
    /// 출력 프레임 길이(초): 타임라인 것을 쓰고, 모르면 클립 것, 그것도 모르면 1/60 초
    var outputFrame: Double { timelineFrame > 0 ? timelineFrame : (frame > 0 ? frame : 1.0 / 60) }

    var description: String {
        func f(_ t: CMTime) -> String { String(format: "%.3f", Self.seconds(t)) }
        return "시각=\(f(render)) 입력시작=\(f(start)) 입력길이=\(f(length)) 효과시작=\(f(effectStart)) "
            + "효과길이=\(f(effectLength)) 타임라인=\(f(timeline)) 프레임=\(f(frameDuration)) "
            + "출력프레임=\(String(format: "%.4f", outputFrame)) 지남=\(String(format: "%.3f", local))"
    }
}
