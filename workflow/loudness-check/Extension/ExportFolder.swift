// FCP 에서 소리만 내보낸 파일을 두는 폴더 (~/Movies/LoudnessCheck) 를 지켜본다.
//
// 확장은 샌드박스 안에서 돌아서 이 폴더만 읽을 수 있다
// (Extension.entitlements 의 home-relative-path 예외. 폴더는 build.sh 가 만든다).

import Foundation
import os

private let log = Logger(subsystem: "com.ibare.spooky.LoudnessCheck", category: "folder")

final class ExportFolder {
    static let name = "LoudnessCheck"
    static let audioExtensions: Set<String> = ["wav", "wave", "aif", "aiff", "caf", "m4a", "mp3"]

    /// 진짜 홈 폴더 아래의 경로. 샌드박스 안의 NSHomeDirectory() 는 컨테이너를 가리키므로 쓰지 않는다.
    static let url: URL = {
        let home = getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Movies/\(name)", isDirectory: true)
    }()

    struct File: Equatable {
        let url: URL
        let modified: Date
        let size: Int
        var key: String { "\(url.path)|\(modified.timeIntervalSince1970)|\(size)" }
        var baseName: String { url.deletingPathExtension().lastPathComponent }
    }

    /// 폴더 안 파일이 생기거나 바뀌면 메인 스레드에서 부른다 (1초 모아서).
    var onChange: (() -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    /// 감시를 시작한다. 폴더를 열 수 없으면 false.
    @discardableResult
    func start() -> Bool {
        stop()
        let fd = open(Self.url.path, O_EVTONLY)
        guard fd >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .link, .extend, .attrib], queue: .main)
        source.setEventHandler { [weak self] in self?.schedule() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        return true
    }

    func stop() {
        source?.cancel()
        source = nil
        pending?.cancel()
        pending = nil
    }

    deinit { stop() }

    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange?() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// 소리 파일 목록. 최근에 바뀐 것부터.
    func files() -> [File] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: Self.url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        return urls.compactMap { url -> File? in
            guard Self.audioExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { return nil }
            return File(url: url, modified: values.contentModificationDate ?? .distantPast, size: values.fileSize ?? 0)
        }
        .sorted { $0.modified > $1.modified }
    }

    /// 파일 크기가 두 번 잴 동안(약 1.4초) 그대로면 다 쓴 것으로 보고 ready 를 부른다.
    /// FCP 가 아직 쓰는 중이면 waiting 을 부르며 기다린다. 파일이 사라지거나 7분이 지나면 abandoned 를 부른다.
    func whenStable(_ file: File,
                    waiting: @escaping () -> Void,
                    ready: @escaping (File) -> Void,
                    abandoned: @escaping () -> Void) {
        check(file, lastSize: Self.size(of: file.url), stableCount: 0, attempt: 0,
              waiting: waiting, ready: ready, abandoned: abandoned)
    }

    private func check(_ file: File, lastSize: Int, stableCount: Int, attempt: Int,
                       waiting: @escaping () -> Void,
                       ready: @escaping (File) -> Void,
                       abandoned: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            let size = Self.size(of: file.url)
            guard size >= 0, attempt < 600 else {
                log.error("기다림을 그만둠: \(file.url.lastPathComponent, privacy: .public) 크기 \(size) 시도 \(attempt)")
                abandoned()
                return
            }
            if size > 0, size == lastSize {
                if stableCount + 1 >= 2 {
                    ready(self.files().first { $0.url == file.url } ?? file)
                } else {
                    self.check(file, lastSize: size, stableCount: stableCount + 1, attempt: attempt + 1,
                               waiting: waiting, ready: ready, abandoned: abandoned)
                }
            } else {
                waiting()
                self.check(file, lastSize: size, stableCount: 0, attempt: attempt + 1,
                           waiting: waiting, ready: ready, abandoned: abandoned)
            }
        }
    }

    /// 지금 크기. URL.resourceValues 는 같은 URL 객체에 대해 처음 값을 기억해 두고 계속 돌려주므로
    /// (FCP 가 막 만든 0바이트 파일이 끝까지 0으로 보였다) 매번 파일 시스템에 묻는다.
    private static func size(of url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return -1 }
        return size.intValue
    }
}
