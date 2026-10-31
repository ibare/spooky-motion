import CoreGraphics
import Foundation
import Metal
import MetalPerformanceShaders

/// 얼굴 영역 마스크 텍스처를 만든다.
/// 특징점 다각형을 작은 흑백 비트맵에 그리고(흰색 = 보정 대상), GPU 에서 흐려 경계를 부드럽게 한다.
/// 텍스처 좌표는 원본과 같아서 셰이더가 같은 좌표로 읽는다.
enum RegionMask {
    /// 마스크 비트맵의 너비. 경계를 흐리므로 원본보다 훨씬 작아도 된다.
    static let width = 512

    static func make(_ a: FaceAnalysis?, sourceSize: CGSize, device: MTLDevice,
                     commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard let a else { return blank(device) }
        let mw = width
        let mh = max(1, Int((CGFloat(mw) * sourceSize.height / sourceSize.width).rounded()))
        let k = CGFloat(mw) / sourceSize.width   // 이미지 픽셀 → 마스크 픽셀

        var bytes = [UInt8](repeating: 0, count: mw * mh)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: mw, height: mh, bitsPerComponent: 8,
                                      bytesPerRow: mw, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            // 사용자 좌표의 y 를 메모리 줄 번호와 같게 맞춘다 (CG 는 기본이 아래→위).
            ctx.translateBy(x: 0, y: CGFloat(mh))
            ctx.scaleBy(x: 1, y: -1)
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)

            func path(_ uv: [CGPoint]) -> CGPath {
                let p = CGMutablePath()
                p.addLines(between: uv.map { CGPoint(x: $0.x * CGFloat(mw), y: $0.y * CGFloat(mh)) })
                p.closeSubpath()
                return p
            }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.addPath(path(a.face))
            ctx.fillPath()

            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.setStrokeColor(gray: 0, alpha: 1)
            for e in a.exclusions {
                let p = path(e.points)
                ctx.addPath(p); ctx.fillPath()
                ctx.setLineWidth(max(1, e.pad * 2 * k))
                ctx.addPath(p); ctx.strokePath()
            }
            return true
        }
        guard drawn else { return blank(device) }

        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: mw, height: mh,
                                                            mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        guard let raw = device.makeTexture(descriptor: desc), let soft = device.makeTexture(descriptor: desc) else {
            return nil
        }
        raw.replace(region: MTLRegionMake2D(0, 0, mw, mh), mipmapLevel: 0, withBytes: bytes, bytesPerRow: mw)

        // 경계 흐림: 얼굴 너비의 3.5% (마스크 픽셀 단위). 보정한 곳과 안 한 곳의 경계가 드러나지 않을 만큼.
        let sigma = Float(max(1, a.faceWidth * k * 0.035))
        MPSImageGaussianBlur(device: device, sigma: sigma)
            .encode(commandBuffer: commandBuffer, sourceTexture: raw, destinationTexture: soft)
        return soft
    }

    /// 피부색 판정용 저해상도 흐린 영상. 잡티와 모공이 주변 피부에 섞여서 마스크에 구멍을 내지 않는다.
    /// (확인됨: 원본 해상도로 판정하면 갈색 잡티 자리마다 마스크가 비었다)
    /// 크기는 마스크와 같고, 흐림은 얼굴 너비의 2% 이다.
    static func lowPass(_ source: MTLTexture, faceWidth: CGFloat, device: MTLDevice,
                        commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        let mw = width
        let mh = max(1, Int((CGFloat(mw) * CGFloat(source.height) / CGFloat(source.width)).rounded()))
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: mw, height: mh,
                                                            mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]
        guard let small = device.makeTexture(descriptor: desc), let soft = device.makeTexture(descriptor: desc) else {
            return nil
        }
        MPSImageBilinearScale(device: device)
            .encode(commandBuffer: commandBuffer, sourceTexture: source, destinationTexture: small)
        let k = CGFloat(mw) / CGFloat(source.width)
        let sigma = Float(max(0.5, faceWidth * k * 0.02))
        MPSImageGaussianBlur(device: device, sigma: sigma)
            .encode(commandBuffer: commandBuffer, sourceTexture: small, destinationTexture: soft)
        return soft
    }

    /// 얼굴이 없을 때 쓰는 1x1 검은 텍스처
    static func blank(_ device: MTLDevice) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 1, height: 1,
                                                            mipmapped: false)
        let t = device.makeTexture(descriptor: desc)
        var zero: UInt8 = 0
        t?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 1)
        return t
    }
}
