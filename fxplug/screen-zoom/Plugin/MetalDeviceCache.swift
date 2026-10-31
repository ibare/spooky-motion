import Foundation
import Metal
import os

/// 플러그인 기록. NSLog 는 통합 로그에 남지 않아서(확인됨) os.Logger 를 쓴다.
/// 보기: /usr/bin/log show --last 10m --predicate 'subsystem == "com.ibare.spooky.ScreenZoom"'
let log = Logger(subsystem: "com.ibare.spooky.ScreenZoom", category: "plugin")

/// GPU 장치마다 명령 큐와 파이프라인을 한 번만 만들어 두고 다시 쓴다.
/// FCP 는 여러 스레드에서 동시에 렌더를 부르므로 잠금으로 보호한다.
final class MetalDeviceCache {
    static let shared = MetalDeviceCache()

    final class Entry {
        let device: MTLDevice
        let queue: MTLCommandQueue
        private let library: MTLLibrary
        private var pipelines: [String: MTLRenderPipelineState] = [:]
        private let lock = NSLock()

        init(device: MTLDevice, queue: MTLCommandQueue, library: MTLLibrary) {
            self.device = device
            self.queue = queue
            self.library = library
        }

        /// 확대 렌더 (vertexShader + zoomFragment)
        func zoomPipeline(_ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            try pipeline("zoom", format, vertex: "vertexShader", fragment: "zoomFragment", blend: false)
        }

        /// 조절점 그리기 (oscVertex + oscFragment). 알파를 곱한 색을 겹쳐 그린다.
        func oscPipeline(_ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            try pipeline("osc", format, vertex: "oscVertex", fragment: "oscFragment", blend: true)
        }

        private func pipeline(_ name: String, _ format: MTLPixelFormat, vertex: String, fragment: String,
                              blend: Bool) throws -> MTLRenderPipelineState {
            lock.lock(); defer { lock.unlock() }
            let key = "\(name)-\(format.rawValue)"
            if let p = pipelines[key] { return p }
            let desc = MTLRenderPipelineDescriptor()
            desc.label = "ScreenZoom \(name)"
            desc.vertexFunction = library.makeFunction(name: vertex)
            desc.fragmentFunction = library.makeFunction(name: fragment)
            guard desc.vertexFunction != nil, desc.fragmentFunction != nil else {
                throw PlugInError.metal("셰이더 함수를 찾지 못했습니다: \(vertex), \(fragment)")
            }
            let color = desc.colorAttachments[0]!
            color.pixelFormat = format
            if blend {
                color.isBlendingEnabled = true
                color.sourceRGBBlendFactor = .one
                color.sourceAlphaBlendFactor = .one
                color.destinationRGBBlendFactor = .oneMinusSourceAlpha
                color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            let p = try device.makeRenderPipelineState(descriptor: desc)
            pipelines[key] = p
            return p
        }
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
        let e = Entry(device: device, queue: queue, library: library)
        entries[registryID] = e
        return e
    }
}
