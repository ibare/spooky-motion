import AppKit
import CoreMedia
import Foundation
import Metal
import simd

/// 뷰어 조절점: 확대할 영역을 사각형으로 보여 주고, 끌어서 옮기거나 모서리를 끌어 크기를 바꾼다.
///
/// 효과를 고르면 늘 보인다. 사각형은 지금 프레임의 확대 상태대로 그린다
/// (확대 전 프레임에서는 영역 자리, 다 확대한 프레임에서는 화면 테두리).
/// 끌기 시작하면 '영역 고르기'를 켜서 원래 화면을 보여 주고, 놓으면 원래 값으로 되돌린다.
/// 확대한 화면 위에서는 영역이 화면 전체라서 영역을 눈으로 맞출 수 없기 때문이다.
/// 끄는 동안에는 마우스가 움직인 만큼만 옮겨서, 누른 순간 사각형이 튀지 않는다.
///
/// 그리기는 캔버스 좌표(뷰어 픽셀, 왼쪽 아래가 원점)로 하고, 값은 객체 좌표(원본 그림의 0~1)로 바꿔 저장한다.
/// Info.plist 의 supportedPlugins 로 ScreenZoomPlugIn 과 이어진다.
@objc(ScreenZoomOSC)
class ScreenZoomOSC: NSObject, FxOnScreenControl_v4 {

    // MARK: 설정 (대략값, 캔버스 포인트)

    private static let handleSize: Double = 10
    private static let hitSlop: Double = 6
    private static let lineWidth: Double = 1.5
    private static let shadowWidth: Double = 3.5
    private static let crossSize: Double = 7

    /// 조절점의 부분 번호. 0 은 아무것도 아님(호스트 약속).
    private enum Part: Int {
        case none = 0
        case body = 1
        case cornerMinMin = 2   // 왼쪽 아래
        case cornerMaxMin = 3   // 오른쪽 아래
        case cornerMinMax = 4   // 왼쪽 위
        case cornerMaxMax = 5   // 오른쪽 위

        /// 이 모서리의 방향 (-1 = 작은 쪽, +1 = 큰 쪽)
        var direction: SIMD2<Double>? {
            switch self {
            case .cornerMinMin: return SIMD2(-1, -1)
            case .cornerMaxMin: return SIMD2(1, -1)
            case .cornerMinMax: return SIMD2(-1, 1)
            case .cornerMaxMax: return SIMD2(1, 1)
            default: return nil
            }
        }
    }

    /// 끌기 상태
    private struct Drag {
        /// 누른 순간의 마우스(객체 좌표)와 영역
        var mouse: SIMD2<Double>
        var region: ZoomMath.Region
        /// 누르기 전 '영역 고르기' 값. 놓을 때 이 값으로 되돌린다.
        var wasSelecting: Bool
        /// 끌기 시작하면서 '영역 고르기'를 켰는지
        var switched = false
    }

    private let apiManager: PROAPIAccessing
    private var loggedDraw = false

    // 끌기 상태는 프로세스 전체에 둔다. FCP 가 끄는 도중(값이 바뀔 때) 조절점 객체를 새로 만들어도
    // 상태를 잃지 않고, 켜 둔 '영역 고르기'를 반드시 되돌리기 위해서다.
    // (확인됨: 객체마다 두었을 때 놓은 뒤에도 '영역 고르기'가 켜진 채로 남았다. 원인이 객체 교체인지는 아직 모른다.)
    private static let stateLock = NSLock()
    private static var sharedDrag: Drag?
    /// 끌면서 켠 '영역 고르기'를 아직 끄지 못했다
    private static var pendingRestore = false

    private var drag: Drag? {
        get { Self.stateLock.lock(); defer { Self.stateLock.unlock() }; return Self.sharedDrag }
        set { Self.stateLock.lock(); Self.sharedDrag = newValue; Self.stateLock.unlock() }
    }

    private var pendingRestore: Bool {
        get { Self.stateLock.lock(); defer { Self.stateLock.unlock() }; return Self.pendingRestore }
        set { Self.stateLock.lock(); Self.pendingRestore = newValue; Self.stateLock.unlock() }
    }

    private var tag: String { String(UInt(bitPattern: ObjectIdentifier(self).hashValue) & 0xffff, radix: 16) }

    @objc(initWithAPIManager:)
    init?(apiManager: PROAPIAccessing) {
        self.apiManager = apiManager
        super.init()
    }

    private var osc: FxOnScreenControlAPI_v4? {
        apiManager.api(for: FxOnScreenControlAPI_v4.self) as? FxOnScreenControlAPI_v4
    }

    private func settings(at time: CMTime) -> ZoomSettings? {
        guard let api = apiManager.api(for: FxParameterRetrievalAPI_v6.self) as? FxParameterRetrievalAPI_v6 else {
            return nil
        }
        return ZoomSettings.read(api, at: time)
    }

    // MARK: 좌표

    func drawingCoordinates() -> FxDrawingCoordinates {
        FxDrawingCoordinates(kFxDrawingCoordinates_CANVAS)
    }

    private func toCanvas(_ p: SIMD2<Double>, _ api: FxOnScreenControlAPI_v4) -> SIMD2<Double> {
        var x = 0.0, y = 0.0
        api.convertPoint(fromSpace: FxDrawingCoordinates(kFxDrawingCoordinates_OBJECT), fromX: p.x, fromY: p.y,
                         toSpace: FxDrawingCoordinates(kFxDrawingCoordinates_CANVAS), toX: &x, toY: &y)
        return SIMD2(x, y)
    }

    private func toObject(_ x: Double, _ y: Double, _ api: FxOnScreenControlAPI_v4) -> SIMD2<Double> {
        var ox = 0.0, oy = 0.0
        api.convertPoint(fromSpace: FxDrawingCoordinates(kFxDrawingCoordinates_CANVAS), fromX: x, fromY: y,
                         toSpace: FxDrawingCoordinates(kFxDrawingCoordinates_OBJECT), toX: &ox, toY: &oy)
        return SIMD2(ox, oy)
    }

    /// 영역이 지금 뷰어에 보이는 캔버스 사각형 (왼쪽 아래, 오른쪽 위).
    /// 영역 고르기 화면은 원래 화면 그대로이고, 결과 화면은 이 시각의 확대 변환을 거친 자리다.
    private func canvasRect(_ s: ZoomSettings, at time: CMTime,
                            _ api: FxOnScreenControlAPI_v4) -> (SIMD2<Double>, SIMD2<Double>) {
        let r = s.region
        let tr = s.select ? .identity : s.transform(apiManager: apiManager, at: time).0
        let a = toCanvas(tr.output(of: r.minCorner), api), b = toCanvas(tr.output(of: r.maxCorner), api)
        return (simd_min(a, b), simd_max(a, b))
    }

    private func corner(_ part: Part, lo: SIMD2<Double>, hi: SIMD2<Double>) -> SIMD2<Double> {
        let d = part.direction ?? .zero
        return SIMD2(d.x < 0 ? lo.x : hi.x, d.y < 0 ? lo.y : hi.y)
    }

    private func scale(_ api: FxOnScreenControlAPI_v4) -> Double {
        max(1, api.backingScaleFactor())
    }

    private func part(atX x: Double, y: Double, time: CMTime) -> Part {
        guard let s = settings(at: time), let api = osc else { return .none }
        let (lo, hi) = canvasRect(s, at: time, api)
        let reach = (Self.handleSize / 2 + Self.hitSlop) * scale(api)
        let m = SIMD2(x, y)
        for p in [Part.cornerMinMin, .cornerMaxMin, .cornerMinMax, .cornerMaxMax] {
            let c = corner(p, lo: lo, hi: hi)
            if abs(m.x - c.x) <= reach && abs(m.y - c.y) <= reach { return p }
        }
        if m.x >= lo.x && m.x <= hi.x && m.y >= lo.y && m.y <= hi.y { return .body }
        return .none
    }

    // MARK: 그리기

    func drawOSC(withWidth width: Int, height: Int, activePart: Int, destinationImage: FxImageTile, at time: CMTime) {
        guard let api = osc,
              let e = MetalDeviceCache.shared.entry(registryID: destinationImage.deviceRegistryID),
              let output = destinationImage.metalTexture(for: e.device),
              let cb = e.queue.makeCommandBuffer() else {
            return
        }
        cb.label = "ScreenZoom OSC"
        let bounds = destinationImage.tilePixelBounds
        let topLeft = destinationImage.imageOrigin == UInt(kFxImageOrigin_TOP_LEFT)
        let w = Double(output.width), h = Double(output.height)

        var vertices: [OSCVertex] = []
        // 캔버스 좌표 → 화면 좌표(-1 ~ 1). 메모리 첫 줄(화면 좌표 y = +1)이 캔버스 아래인지 위인지는 imageOrigin 이 알려 준다.
        func ndc(_ x: Double, _ y: Double) -> SIMD2<Float> {
            let nx = (x - Double(bounds.left)) / w * 2 - 1
            let ry = (y - Double(bounds.bottom)) / h
            return SIMD2(Float(nx), Float(topLeft ? ry * 2 - 1 : 1 - ry * 2))
        }
        func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ c: SIMD4<Float>) {
            let a = ndc(x0, y0), b = ndc(x1, y0), cc = ndc(x0, y1), d = ndc(x1, y1)
            vertices += [OSCVertex(position: a, color: c), OSCVertex(position: b, color: c),
                         OSCVertex(position: cc, color: c), OSCVertex(position: b, color: c),
                         OSCVertex(position: d, color: c), OSCVertex(position: cc, color: c)]
        }
        func frame(_ lo: SIMD2<Double>, _ hi: SIMD2<Double>, width t: Double, _ c: SIMD4<Float>) {
            let k = t / 2
            rect(lo.x - k, lo.y - k, hi.x + k, lo.y + k, c)   // 아래
            rect(lo.x - k, hi.y - k, hi.x + k, hi.y + k, c)   // 위
            rect(lo.x - k, lo.y + k, lo.x + k, hi.y - k, c)   // 왼쪽
            rect(hi.x - k, lo.y + k, hi.x + k, hi.y - k, c)   // 오른쪽
        }

        if let s = settings(at: time) {
            let bs = scale(api)
            let (lo, hi) = canvasRect(s, at: time, api)
            let shadow = SIMD4<Float>(0, 0, 0, 0.55)
            let white = SIMD4<Float>(1, 1, 1, 1)
            let accent = SIMD4<Float>(1, 0.8, 0.1, 1)   // 누르고 있는 부분
            frame(lo, hi, width: Self.shadowWidth * bs, shadow)
            frame(lo, hi, width: Self.lineWidth * bs, activePart == Part.body.rawValue ? accent : white)

            // 가운데 표시 (+)
            let c = (lo + hi) / 2, arm = Self.crossSize * bs, t = Self.lineWidth * bs / 2
            rect(c.x - arm - 1, c.y - t - 1, c.x + arm + 1, c.y + t + 1, shadow)
            rect(c.x - t - 1, c.y - arm - 1, c.x + t + 1, c.y + arm + 1, shadow)
            rect(c.x - arm, c.y - t, c.x + arm, c.y + t, white)
            rect(c.x - t, c.y - arm, c.x + t, c.y + arm, white)

            // 모서리 손잡이
            let half = Self.handleSize * bs / 2
            for p in [Part.cornerMinMin, .cornerMaxMin, .cornerMinMax, .cornerMaxMax] {
                let k = corner(p, lo: lo, hi: hi)
                rect(k.x - half - bs, k.y - half - bs, k.x + half + bs, k.y + half + bs, shadow)
                rect(k.x - half, k.y - half, k.x + half, k.y + half, activePart == p.rawValue ? accent : white)
            }

            if !loggedDraw {
                loggedDraw = true
                // 조절점이 받는 시각이 렌더와 같은 기준(클립 원본 시각)인지 확인하려고 남긴다
                let clock = s.transform(apiManager: apiManager, at: time).1
                log.notice("""
                    osc draw \(clock.description, privacy: .public) 고르기=\(s.select, privacy: .public) \
                    \(width, privacy: .public)x\(height, privacy: .public) \
                    텍스처=\(output.width, privacy: .public)x\(output.height, privacy: .public) \
                    조각=(\(bounds.left, privacy: .public),\(bounds.bottom, privacy: .public),\(bounds.right, privacy: .public),\(bounds.top, privacy: .public)) \
                    원점=\(destinationImage.imageOrigin, privacy: .public) 배율=\(bs, privacy: .public) \
                    영역캔버스=(\(lo.x, privacy: .public),\(lo.y, privacy: .public))-(\(hi.x, privacy: .public),\(hi.y, privacy: .public))
                    """)
            }
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        if !vertices.isEmpty, let pipeline = try? e.oscPipeline(output.pixelFormat) {
            enc.setViewport(MTLViewport(originX: 0, originY: 0, width: w, height: h, znear: -1, zfar: 1))
            enc.setRenderPipelineState(pipeline)
            vertices.withUnsafeBytes { buf in
                if let buffer = enc.device.makeBuffer(bytes: buf.baseAddress!, length: buf.count) {
                    enc.setVertexBuffer(buffer, offset: 0, index: Int(VI_Vertices.rawValue))
                }
            }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        }
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
    }

    // MARK: 마우스

    func hitTestOSC(atMousePositionX mousePositionX: Double, mousePositionY: Double,
                    activePart: UnsafeMutablePointer<Int>, at time: CMTime) {
        activePart.pointee = part(atX: mousePositionX, y: mousePositionY, time: time).rawValue
    }

    func mouseDown(atPositionX mousePositionX: Double, positionY mousePositionY: Double, activePart: Int,
                   modifiers: FxModifierKeys, forceUpdate: UnsafeMutablePointer<ObjCBool>, at time: CMTime) {
        guard let api = osc, let s = settings(at: time) else { return }
        // 앞선 끌기에서 켠 '영역 고르기'가 남아 있으면, 그건 사용자가 켠 것이 아니므로 놓을 때 함께 끈다
        let leftover = pendingRestore
        drag = Drag(mouse: toObject(mousePositionX, mousePositionY, api), region: s.region,
                    wasSelecting: s.select && !leftover, switched: leftover)
        log.notice("osc down [\(self.tag, privacy: .public)] 부분=\(activePart, privacy: .public) 고르기=\(s.select, privacy: .public) 남은것=\(leftover, privacy: .public)")
        forceUpdate.pointee = true
    }

    func mouseDragged(atPositionX mousePositionX: Double, positionY mousePositionY: Double, activePart: Int,
                      modifiers: FxModifierKeys, forceUpdate: UnsafeMutablePointer<ObjCBool>, at time: CMTime) {
        guard let api = osc, var d = drag, let part = Part(rawValue: activePart), part != .none else {
            log.notice("osc drag 무시 [\(self.tag, privacy: .public)] 끌기상태=\(self.drag != nil, privacy: .public) 부분=\(activePart, privacy: .public)")
            return
        }
        // 처음 움직일 때 원래 화면으로 바꾼다. 누르기만 하고 놓으면 화면이 깜빡이지 않는다.
        if !d.wasSelecting && !d.switched {
            d.switched = true
            drag = d
            pendingRestore = true
            setSelecting(true, at: time)
            log.notice("osc drag 시작 [\(self.tag, privacy: .public)] 영역 고르기 켬")
        }
        // 영역 고르기 화면에서는 객체 좌표가 곧 원본 좌표라서, 마우스가 움직인 만큼 사각형이 따라간다
        let delta = toObject(mousePositionX, mousePositionY, api) - d.mouse
        let r: ZoomMath.Region
        if let dir = part.direction {
            let corner = d.region.center + dir * d.region.halfSize
            r = ZoomMath.resized(d.region, corner: dir, to: corner + delta)
        } else {
            r = ZoomMath.region(center: d.region.center + delta, scale: d.region.scale)
        }
        apply(r, at: time)
        forceUpdate.pointee = true
    }

    func mouseUp(atPositionX mousePositionX: Double, positionY mousePositionY: Double, activePart: Int,
                 modifiers: FxModifierKeys, forceUpdate: UnsafeMutablePointer<ObjCBool>, at time: CMTime) {
        let d = drag
        log.notice("osc up [\(self.tag, privacy: .public)] 끌기상태=\(d != nil, privacy: .public) 켰음=\(d?.switched ?? false, privacy: .public) 남은것=\(self.pendingRestore, privacy: .public)")
        if d?.switched == true || pendingRestore {
            restoreSelecting(at: time)
        }
        drag = nil
        forceUpdate.pointee = true
    }

    func mouseMoved(atPositionX mousePositionX: Double, positionY mousePositionY: Double, activePart: Int,
                    modifiers: FxModifierKeys, forceUpdate: UnsafeMutablePointer<ObjCBool>, at time: CMTime) {
        // 놓을 때 되돌리지 못했으면(놓기가 오지 않았거나 실패) 버튼을 놓은 채 움직일 때 되돌린다
        if drag == nil && pendingRestore {
            log.notice("osc move [\(self.tag, privacy: .public)] 남은 영역 고르기를 끔")
            restoreSelecting(at: time)
            forceUpdate.pointee = true
        }
        let p = part(atX: mousePositionX, y: mousePositionY, time: time)
        osc?.setCursor(p == .body ? .openHand : (p == .none ? .arrow : .crosshair))
    }

    func keyDown(atPositionX mousePositionX: Double, positionY mousePositionY: Double, keyPressed asciiKey: UInt16,
                 modifiers: FxModifierKeys, forceUpdate: UnsafeMutablePointer<ObjCBool>,
                 didHandle: UnsafeMutablePointer<ObjCBool>, at time: CMTime) {
        didHandle.pointee = false
    }

    func keyUp(atPositionX mousePositionX: Double, positionY mousePositionY: Double, keyPressed asciiKey: UInt16,
               modifiers: FxModifierKeys, forceUpdate: UnsafeMutablePointer<ObjCBool>,
               didHandle: UnsafeMutablePointer<ObjCBool>, at time: CMTime) {
        didHandle.pointee = false
    }

    // MARK: 값 바꾸기

    private var setter: FxParameterSettingAPI_v5? {
        apiManager.api(for: FxParameterSettingAPI_v5.self) as? FxParameterSettingAPI_v5
    }

    private func apply(_ r: ZoomMath.Region, at time: CMTime) {
        setter?.setXValue(r.center.x, yValue: r.center.y, toParameter: ZoomParam.center, at: time)
        setter?.setFloatValue(r.scale, toParameter: ZoomParam.scale, at: time)
    }

    private func setSelecting(_ on: Bool, at time: CMTime) {
        let ok = setter?.setBoolValue(on, toParameter: ZoomParam.select, at: time) ?? false
        if !ok {
            log.error("영역 고르기를 \(on ? "켜지" : "끄지", privacy: .public) 못했습니다")
        }
    }

    /// 끌면서 켠 '영역 고르기'를 끈다
    private func restoreSelecting(at time: CMTime) {
        setSelecting(false, at: time)
        pendingRestore = false
    }
}
