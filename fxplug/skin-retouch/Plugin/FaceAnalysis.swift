import CoreImage
import CoreVideo
import Foundation
import IOSurface
import Vision

/// 한 프레임의 얼굴 분석 결과.
/// 좌표는 모두 원본 텍스처 좌표(u: 왼쪽 0 → 오른쪽 1, v: 메모리 첫 줄 0 → 마지막 줄 1)다.
struct FaceAnalysis {
    /// 피부 보정 대상 영역 (윤곽 + 이마)
    var face: [CGPoint]
    /// 빼는 영역과 그 둘레에 더할 여유 폭(이미지 픽셀). 눈, 눈썹, 입술, (선택) 수염 영역
    var exclusions: [(points: [CGPoint], pad: CGFloat)]
    /// 얼굴 너비 (이미지 픽셀). 흐림 반경 같은 값을 얼굴 크기에 맞추는 기준이다.
    var faceWidth: CGFloat
    var skin: SkinStats
    /// 메모리 첫 줄이 그림의 아래였는지 (진단용)
    var flipped: Bool
}

/// 볼과 이마에서 뽑은 피부색 기준
struct SkinStats {
    var mean: SIMD2<Float>     // 색도 (r, g) 평균
    var invCov: SIMD3<Float>   // 역공분산 (xx, xy, yy)
    var lumaRef: Float         // 밝기 중앙값
    var samples: Int
}

enum FaceAnalyzer {
    /// 이미지 메모리의 첫 줄이 그림의 위인지 아래인지는 호스트마다 다를 수 있어서,
    /// 얼굴이 잡힌 방향을 기억해 두고 다음 프레임에 먼저 쓴다.
    private static let lock = NSLock()
    private static var preferFlipped: Bool?

    /// surface: 원본 그림 전체. topLeftOrigin: 호스트가 메모리 첫 줄을 그림의 위라고 알려 줬는지.
    /// FxPlug 타입을 쓰지 않아서 플러그인 밖(시험 프로그램)에서도 돌릴 수 있다.
    static func analyze(_ surface: IOSurface, topLeftOrigin: Bool, excludeBeard: Bool) -> FaceAnalysis? {
        let W = CGFloat(surface.width), H = CGFloat(surface.height)
        let image = CIImage(ioSurface: surface)

        // CIImage 는 메모리 첫 줄을 그림의 위로 본다. 호스트가 아래→위 순서(BOTTOM_LEFT)로 주면 뒤집어서 넘긴다.
        lock.lock()
        let first = preferFlipped ?? !topLeftOrigin
        lock.unlock()

        for flipped in [first, !first] {
            let orientation: CGImagePropertyOrientation = flipped ? .downMirrored : .up
            let request = VNDetectFaceLandmarksRequest()
            let handler = VNImageRequestHandler(ciImage: image, orientation: orientation, options: [:])
            do {
                try handler.perform([request])
            } catch {
                log.error("Vision 실패: \(error.localizedDescription, privacy: .public)")
                return nil
            }
            guard let face = (request.results ?? []).max(by: { area($0) < area($1) }),
                  let lm = face.landmarks, let contour = lm.faceContour else {
                continue
            }
            lock.lock(); preferFlipped = flipped; lock.unlock()

            // 그림 좌표(바로 선 그림, 왼쪽 아래 원점, 픽셀) → 텍스처 좌표
            let size = CGSize(width: W, height: H)
            func pts(_ r: VNFaceLandmarkRegion2D?) -> [CGPoint] { r?.pointsInImage(imageSize: size) ?? [] }
            func toUV(_ p: CGPoint) -> CGPoint {
                CGPoint(x: p.x / W, y: flipped ? p.y / H : 1 - p.y / H)
            }
            func toMemory(_ p: CGPoint) -> (col: Int, row: Int) {
                let uv = toUV(p)
                return (Int(uv.x * W), Int(uv.y * H))
            }

            let geo = Geometry(contour: pts(contour), leftEye: pts(lm.leftEye), rightEye: pts(lm.rightEye),
                               leftBrow: pts(lm.leftEyebrow), rightBrow: pts(lm.rightEyebrow),
                               lips: pts(lm.outerLips), nose: pts(lm.nose))
            guard let regions = geo.regions(excludeBeard: excludeBeard) else { return nil }
            guard let skin = sampleSkin(surface, centers: geo.sampleDisks(), toMemory: toMemory) else {
                log.error("피부색 표본을 얻지 못했습니다")
                return nil
            }
            return FaceAnalysis(face: regions.face.map(toUV),
                                exclusions: regions.exclusions.map { (points: $0.points.map(toUV), pad: $0.pad) },
                                faceWidth: geo.faceWidth, skin: skin, flipped: flipped)
        }
        return nil
    }

    private static func area(_ o: VNFaceObservation) -> CGFloat {
        o.boundingBox.width * o.boundingBox.height
    }

    // MARK: 피부색 표본

    /// 원 안의 픽셀을 메모리에서 직접 읽어 색도 평균과 공분산을 구한다.
    private static func sampleSkin(_ surface: IOSurface, centers: [(CGPoint, CGFloat)],
                                   toMemory: (CGPoint) -> (col: Int, row: Int)) -> SkinStats? {
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let base = surface.baseAddress
        let stride = surface.bytesPerRow
        let width = surface.width, height = surface.height
        let format = surface.pixelFormat

        func read(_ col: Int, _ row: Int) -> SIMD3<Float>? {
            guard col >= 0, row >= 0, col < width, row < height else { return nil }
            let p = base + row * stride
            switch format {
            case kCVPixelFormatType_64RGBAHalf:
                let o = col * 8
                return SIMD3(Float(p.load(fromByteOffset: o, as: Float16.self)),
                             Float(p.load(fromByteOffset: o + 2, as: Float16.self)),
                             Float(p.load(fromByteOffset: o + 4, as: Float16.self)))
            case kCVPixelFormatType_128RGBAFloat:
                let o = col * 16
                return SIMD3(p.load(fromByteOffset: o, as: Float.self),
                             p.load(fromByteOffset: o + 4, as: Float.self),
                             p.load(fromByteOffset: o + 8, as: Float.self))
            case kCVPixelFormatType_32BGRA:
                let o = col * 4
                return SIMD3(Float(p.load(fromByteOffset: o + 2, as: UInt8.self)),
                             Float(p.load(fromByteOffset: o + 1, as: UInt8.self)),
                             Float(p.load(fromByteOffset: o, as: UInt8.self))) / 255
            default:
                return nil
            }
        }

        var colors: [SIMD3<Float>] = []
        for (c, r) in centers {
            let step = max(r / 7, 1)
            var dy = -r
            while dy <= r {
                var dx = -r
                while dx <= r {
                    if dx * dx + dy * dy <= r * r {
                        let m = toMemory(CGPoint(x: c.x + dx, y: c.y + dy))
                        if let v = read(m.col, m.row) { colors.append(v) }
                    }
                    dx += step
                }
                dy += step
            }
        }
        guard colors.count >= 20 else { return nil }

        // 밝기 중앙값 근처만 쓴다 (그늘, 번들거림, 안경테 제외)
        let lumas = colors.map { simd_dot($0, SIMD3(0.2126, 0.7152, 0.0722)) }
        let median = lumas.sorted()[lumas.count / 2]
        var chroma: [SIMD2<Float>] = []
        for (c, y) in zip(colors, lumas) where y > median * 0.6 && y < median * 1.6 {
            let s = c.x + c.y + c.z
            if s > 1e-4 { chroma.append(SIMD2(c.x / s, c.y / s)) }
        }
        guard chroma.count >= 20 else { return nil }

        let n = Float(chroma.count)
        let mean = chroma.reduce(SIMD2<Float>(0, 0), +) / n
        var xx: Float = 0, xy: Float = 0, yy: Float = 0
        for c in chroma {
            let d = c - mean
            xx += d.x * d.x; xy += d.x * d.y; yy += d.y * d.y
        }
        // 표본이 한쪽으로 몰려도 범위가 지나치게 좁아지지 않게 최소 분산을 더한다.
        let floorVar: Float = 0.004 * 0.004
        xx = xx / n + floorVar; xy /= n; yy = yy / n + floorVar
        let det = xx * yy - xy * xy
        return SkinStats(mean: mean, invCov: SIMD3(yy / det, -xy / det, xx / det),
                         lumaRef: median, samples: chroma.count)
    }
}

/// 특징점으로 영역을 만드는 계산. 좌표는 바로 선 그림 기준(왼쪽 아래 원점, 위가 +y, 픽셀).
private struct Geometry {
    var contour, leftEye, rightEye, leftBrow, rightBrow, lips, nose: [CGPoint]

    var faceWidth: CGFloat {
        let xs = contour.map(\.x)
        return (xs.max() ?? 0) - (xs.min() ?? 0)
    }

    private func center(_ p: [CGPoint]) -> CGPoint {
        CGPoint(x: p.map(\.x).reduce(0, +) / CGFloat(max(p.count, 1)),
                y: p.map(\.y).reduce(0, +) / CGFloat(max(p.count, 1)))
    }

    private func width(_ p: [CGPoint]) -> CGFloat {
        (p.map(\.x).max() ?? 0) - (p.map(\.x).min() ?? 0)
    }

    func regions(excludeBeard: Bool) -> (face: [CGPoint], exclusions: [(points: [CGPoint], pad: CGFloat)])? {
        guard contour.count >= 5, let a = contour.first, let b = contour.last else { return nil }
        let fw = faceWidth
        let brows = leftBrow + rightBrow
        let browTop = brows.map(\.y).max() ?? contour.map(\.y).max()!
        let chin = contour.map(\.y).min()!
        let faceH = browTop - chin

        // 이마: 윤곽 양 끝(관자놀이)을 잇는 위쪽 반타원. 머리카락은 색과 밝기로 걸러진다.
        let cx = (a.x + b.x) / 2, cy = max(a.y, b.y)
        let rx = abs(b.x - a.x) / 2, ry = (browTop - cy) + faceH * 0.45
        let leftToRight = b.x > a.x
        var arc: [CGPoint] = []
        for i in 1..<24 {
            let t = CGFloat(i) / 24 * .pi
            let ang = leftToRight ? t : .pi - t   // b(끝)에서 출발해 위를 지나 a(처음)로
            arc.append(CGPoint(x: cx + rx * cos(ang), y: cy + ry * sin(ang)))
        }
        let face = contour + arc

        var ex: [(points: [CGPoint], pad: CGFloat)] = []
        for eye in [leftEye, rightEye] where eye.count >= 3 {
            ex.append((eye, width(eye) * 0.30))           // 눈꺼풀과 속눈썹까지
        }
        for brow in [leftBrow, rightBrow] where brow.count >= 3 {
            ex.append((brow, fw * 0.035))
        }
        if lips.count >= 3 {
            ex.append((lips, fw * 0.03))
        }
        if excludeBeard, let noseBottom = nose.map(\.y).min(),
           let mouthL = lips.map(\.x).min(), let mouthR = lips.map(\.x).max() {
            // 입과 턱(콧수염, 턱수염): 코 밑부터 턱 끝 조금 아래까지, 가로로는 입꼬리에서 얼굴 너비의 12% 바깥까지.
            // 모서리가 둥근 사각형(초타원)이라 세로로 잘린 경계가 생기지 않는다.
            // (확인됨(FCP 결과): 직선으로 자르면 입 옆에 세로 경계가 또렷하게 보였다)
            // 아래쪽 볼(잡티가 많은 곳)은 남긴다.
            let top = noseBottom, bottom = chin - faceH * 0.05
            let cx = (mouthL + mouthR) / 2, cy = (top + bottom) / 2
            let rx = (mouthR - mouthL) / 2 + fw * 0.12, ry = (top - bottom) / 2
            let n: CGFloat = 3   // 2 = 타원, 클수록 사각형에 가깝다
            var beard: [CGPoint] = []
            for i in 0..<48 {
                let t = CGFloat(i) / 48 * 2 * .pi
                let c = cos(t), s = sin(t)
                beard.append(CGPoint(x: cx + rx * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n),
                                     y: cy + ry * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)))
            }
            ex.append((beard, 0))
        }
        return (face, ex)
    }

    /// 피부색 표본을 뽑을 원들 (중심, 반지름): 양 볼과 이마
    func sampleDisks() -> [(CGPoint, CGFloat)] {
        let fw = faceWidth
        let mid = center(contour).x
        var disks: [(CGPoint, CGFloat)] = []
        let corners = [lips.min(by: { $0.x < $1.x }), lips.max(by: { $0.x < $1.x })]
        for (eye, corner) in zip([leftEye, rightEye], corners) {
            guard eye.count >= 3, let corner else { continue }
            let e = center(eye)
            var c = CGPoint(x: (e.x + corner.x) / 2, y: (e.y + corner.y) / 2)
            c.x += (c.x < mid ? -1 : 1) * fw * 0.10       // 코에서 바깥쪽으로
            disks.append((c, fw * 0.06))
        }
        let brows = leftBrow + rightBrow
        if !brows.isEmpty {
            let top = brows.map(\.y).max()!
            disks.append((CGPoint(x: center(brows).x, y: top + fw * 0.12), fw * 0.07))
        }
        return disks
    }
}
