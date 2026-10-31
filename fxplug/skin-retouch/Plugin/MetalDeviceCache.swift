import Foundation
import Metal
import os

/// 플러그인 기록. NSLog 는 통합 로그에 남지 않아서(확인됨) os.Logger 를 쓴다.
/// 보기: /usr/bin/log show --last 10m --predicate 'subsystem == "com.ibare.spooky.SkinRetouch"'
let log = Logger(subsystem: "com.ibare.spooky.SkinRetouch", category: "plugin")

/// GPU 장치마다 명령 큐와 렌더 파이프라인을 한 번만 만들어 두고 다시 쓴다.
/// FCP 는 여러 스레드에서 동시에 렌더를 부르므로 잠금으로 보호한다.
/// (SDK 템플릿의 MetalDeviceCache 를 단순하게 줄인 것. MTLCommandQueue 는 여러 스레드에서 써도 된다.)
final class MetalDeviceCache {
    static let shared = MetalDeviceCache()

    private struct Entry {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let library: MTLLibrary
        var pipelines: [MTLPixelFormat: MTLRenderPipelineState]
    }

    private var entries: [UInt64: Entry] = [:]
    private let lock = NSLock()

    func device(registryID: UInt64) -> MTLDevice? {
        lock.lock(); defer { lock.unlock() }
        return entry(registryID)?.device
    }

    func commandQueue(registryID: UInt64) -> MTLCommandQueue? {
        lock.lock(); defer { lock.unlock() }
        return entry(registryID)?.queue
    }

    /// 출력 픽셀 형식에 맞는 렌더 파이프라인 (vertexShader + skinFragment)
    func pipeline(registryID: UInt64, pixelFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        lock.lock(); defer { lock.unlock() }
        guard var e = entry(registryID) else { throw PlugInError.noDevice }
        if let p = e.pipelines[pixelFormat] { return p }
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "SkinRetouch"
        desc.vertexFunction = e.library.makeFunction(name: "vertexShader")
        desc.fragmentFunction = e.library.makeFunction(name: "skinFragment")
        desc.colorAttachments[0].pixelFormat = pixelFormat
        let p = try e.device.makeRenderPipelineState(descriptor: desc)
        e.pipelines[pixelFormat] = p
        entries[registryID] = e
        return p
    }

    /// 잠금을 잡은 상태에서만 부른다.
    private func entry(_ registryID: UInt64) -> Entry? {
        if let e = entries[registryID] { return e }
        guard let device = MTLCopyAllDevices().first(where: { $0.registryID == registryID }),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            log.error("GPU 장치(\(registryID, privacy: .public))를 준비하지 못했습니다")
            return nil
        }
        let e = Entry(device: device, queue: queue, library: library, pipelines: [:])
        entries[registryID] = e
        return e
    }

    /// 호스트가 넘긴 이미지(IOSurface)의 픽셀 형식을 Metal 형식으로 바꾼다.
    static func pixelFormat(for tile: FxImageTile) -> MTLPixelFormat {
        switch tile.ioSurface.pixelFormat {
        case kCVPixelFormatType_128RGBAFloat: return .rgba32Float
        case kCVPixelFormatType_32BGRA: return .bgra8Unorm
        case kCVPixelFormatType_64RGBAHalf: return .rgba16Float
        default:
            log.error("예상하지 못한 픽셀 형식 0x\(String(tile.ioSurface.pixelFormat, radix: 16), privacy: .public)")
            return .rgba16Float
        }
    }
}

enum PlugInError: Error {
    case apiUnavailable
    case noDevice
    case metal(String)
}
