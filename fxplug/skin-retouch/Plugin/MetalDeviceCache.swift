import Foundation
import Metal
import os

/// 플러그인 기록. NSLog 는 통합 로그에 남지 않아서(확인됨) os.Logger 를 쓴다.
/// 보기: /usr/bin/log show --last 10m --predicate 'subsystem == "com.ibare.spooky.SkinRetouch"'
let log = Logger(subsystem: "com.ibare.spooky.SkinRetouch", category: "plugin")

/// GPU 장치마다 명령 큐와 렌더러를 한 번만 만들어 두고 다시 쓴다.
/// FCP 는 여러 스레드에서 동시에 렌더를 부르므로 잠금으로 보호한다.
/// (SDK 템플릿의 MetalDeviceCache 를 단순하게 줄인 것. MTLCommandQueue 는 여러 스레드에서 써도 된다.)
final class MetalDeviceCache {
    static let shared = MetalDeviceCache()

    struct Entry {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let renderer: SkinRenderer
    }

    private var entries: [UInt64: Entry] = [:]
    private let lock = NSLock()

    func entry(registryID: UInt64) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        if let e = entries[registryID] { return e }
        guard let device = MTLCopyAllDevices().first(where: { $0.registryID == registryID }),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else {
            log.error("GPU 장치(\(registryID, privacy: .public))를 준비하지 못했습니다")
            return nil
        }
        do {
            let e = Entry(device: device, queue: queue, renderer: try SkinRenderer(device: device, library: library))
            entries[registryID] = e
            return e
        } catch {
            log.error("렌더러를 만들지 못했습니다: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
