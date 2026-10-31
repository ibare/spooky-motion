import Foundation
import simd

/// 화면 확대 계산. FxPlug 타입을 쓰지 않아서 플러그인 밖(시험 프로그램)에서도 같은 코드로 돌릴 수 있다.
///
/// 좌표는 모두 원본 그림의 정규 좌표다: 왼쪽 아래가 (0, 0), 오른쪽 위가 (1, 1).
/// 영역은 화면과 같은 비율의 사각형이라 정규 좌표에서는 가로세로 반폭이 같다(= 0.5 / 배율).
enum ZoomMath {
    // MARK: 설정 (대략값)

    static let minScale = 1.0
    static let maxScale = 8.0
    static let defaultScale = 2.0
    /// 줌 인, 줌 아웃에 걸리는 시간(초)
    static let defaultMoveSeconds = 0.6
    static let maxMoveSeconds = 3.0
    /// 확대 상태로 머무는 시간(초). 0 이면 클립 끝까지 머문다.
    static let defaultHoldSeconds = 0.0
    static let maxHoldSeconds = 600.0
    /// 영역 고르기에서 영역 밖을 어둡게 하는 정도 (1 = 그대로)
    static let outsideDim: Float = 0.4
    /// '고급' 곡선의 용수철 세기. 클수록 더 빨리 출발하고 도착 전 감속 구간이 길어진다.
    /// 6 이면 시간의 1/4 에 약 44%, 절반에 약 81% 를 간다.
    static let springOmega = 6.0
    /// 모션 블러 셔터 (프레임 길이에 대한 비율). 셰이더가 셔터 가운데에 무게를 두는 Hann 창으로 섞으므로,
    /// 1 프레임이면 영화용 180° 셔터(같은 무게로 반 프레임)와 블러 세기(시간 표준편차 약 0.14 프레임)가 같다.
    /// 같은 무게로 섞으면 번진 자국 양 끝에 글자 모양이 남아 두 겹처럼 보인다.
    static let shutter = 1.0
    /// 모션 블러 구간 수 상한과, 구간 사이 간격(4K 기준 픽셀).
    /// 가장 빠를 때 블러 길이는 4K 에서 100~400px 쯤이다 (배율 2~4, 움직임 0.3~0.6초).
    static let maxBlurSamples = 64
    static let blurSampleSpacing = 2.0

    // MARK: 영역

    /// 화면 안에 들어오도록 가운데를 옮긴 영역. 배율이 1 이하면 화면 전체다.
    struct Region: Equatable {
        var center: SIMD2<Double>
        var scale: Double

        var halfSize: Double { 0.5 / scale }
        var minCorner: SIMD2<Double> { center - halfSize }
        var maxCorner: SIMD2<Double> { center + halfSize }
    }

    static func region(center: SIMD2<Double>, scale: Double) -> Region {
        let s = min(maxScale, max(minScale, scale.isFinite ? scale : defaultScale))
        let h = 0.5 / s
        let c = SIMD2(min(1 - h, max(h, center.x.isFinite ? center.x : 0.5)),
                      min(1 - h, max(h, center.y.isFinite ? center.y : 0.5)))
        return Region(center: c, scale: s)
    }

    /// 모서리를 끌면 반대쪽 모서리는 그대로 두고 화면 비율을 지켜 크기를 바꾼다.
    static func resized(_ r: ZoomMath.Region, corner dir: SIMD2<Double>, to m: SIMD2<Double>) -> ZoomMath.Region {
        let anchor = r.center - dir * r.halfSize
        // 끄는 방향을 넘어 반대쪽으로 가도 원래 방향으로 둔다 (사각형이 뒤집히지 않게)
        let reach = simd_max((m - anchor) * dir, .zero)
        let room = SIMD2(dir.x > 0 ? 1 - anchor.x : anchor.x, dir.y > 0 ? 1 - anchor.y : anchor.y)
        let side = min(max(reach.x, reach.y), room.x, room.y, 1)
        let size = max(side, 1 / ZoomMath.maxScale)
        return ZoomMath.region(center: anchor + dir * size / 2, scale: 1 / size)
    }

    // MARK: 시간

    /// 줌 곡선 (인스펙터 '움직임 곡선' 팝업 순번)
    enum Curve: Int32 {
        /// 임계 감쇠 용수철: 부드럽게 출발해 빠르게 가속하고, 길고 부드럽게 멈춘다 (SwiftUI `.smooth` 와 같은 성질)
        case premium = 0
        /// 대칭 이징 (easeInOutCubic)
        case smooth = 1
    }

    /// 줌 인 진행도(in)와 줌 아웃 쪽 남은 정도(out). 둘 다 0~1 이고 이징 전이다.
    /// - time: 클립 처음부터 지난 시간(초)
    /// - duration: 클립 길이(초). 마지막 프레임에서 원래 화면이 되도록 frame 만큼 앞당겨 끝낸다.
    ///   움직임 시간이 0 이면 바로 바뀌는 것이라 마지막 프레임까지 확대해 둔다.
    /// - move: 줌 인·아웃 시간(초), hold: 확대 상태로 머무는 시간(초, 0 = 클립 끝까지)
    static func ramps(time t: Double, duration: Double, frame: Double, move: Double,
                      hold: Double) -> (in: Double, out: Double) {
        func ramp(_ x: Double) -> Double {
            let r = move > 0 ? min(1, max(0, x / move)) : (x >= 0 ? 1 : 0)
            // 시각 계산의 부동소수 오차(1e-15 수준)로 원래 화면이어야 할 프레임이 미세하게 확대되지 않게 한다
            return r < 1e-6 ? 0 : (r > 1 - 1e-6 ? 1 : r)
        }
        var out = 1.0
        if duration > 0 {
            out = min(out, ramp(duration - t - (move > 0 ? max(0, frame) : 0)))
        }
        if hold > 0 {
            out = min(out, ramp(move + hold + move - t))
        }
        return (ramp(t), out)
    }

    /// 확대 진행도(0 = 원래 화면, 1 = 다 확대함, 이징 전)
    static func progress(time t: Double, duration: Double, frame: Double, move: Double, hold: Double) -> Double {
        let r = ramps(time: t, duration: duration, frame: frame, move: move, hold: hold)
        return min(r.in, r.out)
    }

    /// 곡선을 적용한 진행도. 줌 아웃도 시간 순서대로 같은 곡선을 따라가게 뒤집어 적용한다
    /// (고급 곡선은 비대칭이라, 그냥 거꾸로 돌리면 줌 아웃이 느리게 출발해 급하게 멈춘다).
    static func eased(time t: Double, duration: Double, frame: Double, move: Double, hold: Double,
                      curve: Curve) -> Double {
        let r = ramps(time: t, duration: duration, frame: frame, move: move, hold: hold)
        return min(ease(r.in, curve: curve), 1 - ease(1 - r.out, curve: curve))
    }

    static func ease(_ p: Double, curve: Curve) -> Double {
        let x = min(1, max(0, p))
        switch curve {
        case .smooth:
            return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
        case .premium:
            // 임계 감쇠 용수철의 계단 응답 s(x) = 1 - (1 + ωx)e^(-ωx). 출발 속도는 0 이다.
            // x = 1 에서 정확히 1 이고 속도가 0 이 되도록, 남은 값과 남은 속도를 끝쪽에서만 큰 다항식으로 메운다
            // (끝값은 smoothstep, 끝속도는 x³ - x² 로. 둘 다 x = 0 에서 값과 기울기가 0 이라 출발은 그대로다).
            let w = springOmega
            func s(_ x: Double) -> Double { 1 - (1 + w * x) * exp(-w * x) }
            let rest = 1 - s(1), speed = w * w * exp(-w)
            return s(x) + rest * (3 * x * x - 2 * x * x * x) - speed * (x * x * x - x * x)
        }
    }

    // MARK: 변환

    /// 출력 좌표 p 에 그릴 원본 좌표는 q = p / zoom + offset 이다.
    struct Transform: Equatable {
        var zoom: Double
        var offset: SIMD2<Double>

        static let identity = Transform(zoom: 1, offset: .zero)

        func source(of p: SIMD2<Double>) -> SIMD2<Double> { p / zoom + offset }
        func output(of q: SIMD2<Double>) -> SIMD2<Double> { (q - offset) * zoom }
    }

    /// 진행도 e(이징 후)의 변환.
    ///
    /// 영역 가운데(목표)는 화면에서 제자리 → 화면 가운데로 e 만큼 곧게 옮기고, 그 둘레로 배율을 키운다.
    /// 이동과 확대가 함께 진행되게 하려는 것이다. 한 점 둘레로만 키우면 목표가 확대보다 늦게 따라온다.
    ///
    /// 배율은 로그 비율(s^e, 처음부터 끝까지 같은 빠르기로 보인다)로 키우되, 화면 밖이 드러나지 않을 만큼은 앞당긴다.
    /// 목표가 가운데에서 d 만큼 떨어져 있고 반대쪽 여유가 0.5 - d 이면, 화면 끝이 들어오지 않으려면
    /// zoom ≥ 1 + e · d / (0.5 - d) 여야 한다. 영역이 화면 가장자리에 붙으면 이 값이 직선 배율 1 + (s - 1) · e 가 된다.
    /// 그래서 가장자리에 가까운 정도 a 만큼 로그 배율과 직선 배율을 섞는다. 섞은 값은 늘 이 조건을 지킨다.
    static func transform(region r: Region, eased e: Double) -> Transform {
        let s = r.scale
        guard s > 1.0001, e > 0 else { return .identity }
        let e = min(1, e)
        let d = simd_abs(r.center - 0.5)
        let room = 0.5 - d   // 영역이 화면 안에 있으므로 0.5 / s 이상이다
        let a = min(1, max(d.x / room.x, d.y / room.y) / (s - 1))
        // 플러그인의 기록용 전역 `log` 와 겹치지 않게 Foundation 의 로그 함수를 부른다
        let zoom = (1 - a) * exp(e * Foundation.log(s)) + a * (1 + (s - 1) * e)
        let target = r.center + (0.5 - r.center) * e   // 목표가 지금 화면에 있는 곳
        return Transform(zoom: zoom, offset: r.center - target / zoom)
    }

    // MARK: 모션 블러

    /// 셔터가 열린 동안(t - shutter/2 ~ t + shutter/2)의 변환 표본.
    /// 셔터를 n 구간으로 나눈 경계 n + 1 개를 돌려준다. 셰이더는 구간마다 픽셀별로 어긋난 시각(지터)에서
    /// 두 경계 사이를 보간해 읽는다. 표본을 고정된 시각에서만 읽으면 글자 가장자리가 여러 겹으로 보인다.
    /// 구간 수는 셔터 동안 화면 모서리가 움직이는 거리(4K 기준 픽셀)에 맞춘다.
    /// 거의 움직이지 않거나 지금 프레임이 원래 화면이면 지금 변환 하나만 돌려준다
    /// (컷 경계의 첫·마지막 프레임은 원본과 똑같아야 튀지 않는다).
    /// - eased: 시각(초) → 곡선을 적용한 진행도
    static func shutterSamples(region r: Region, at t: Double, shutter: Double,
                               eased: (Double) -> Double) -> [Transform] {
        let e = eased(t)
        let now = transform(region: r, eased: e)
        guard shutter > 0, e > 0 else { return [now] }
        let a = transform(region: r, eased: eased(t - shutter / 2))
        let b = transform(region: r, eased: eased(t + shutter / 2))
        var travel = 0.0
        for p in [SIMD2<Double>(0, 0), SIMD2(1, 0), SIMD2(0, 1), SIMD2(1, 1), SIMD2(0.5, 0.5)] {
            let d = (b.output(of: a.source(of: p)) - p) * SIMD2(3840, 2160)
            travel = max(travel, simd_length(d))
        }
        let n = min(maxBlurSamples, Int((travel / blurSampleSpacing).rounded(.up)))
        guard n > 1 else { return [now] }
        return (0...n).map { k in
            transform(region: r, eased: eased(t + shutter * (Double(k) / Double(n) - 0.5)))
        }
    }
}
