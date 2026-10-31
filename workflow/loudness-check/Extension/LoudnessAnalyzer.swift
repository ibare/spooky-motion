// 음량 측정: ITU-R BS.1770-4 (K 가중, 게이팅, True Peak), EBU R128 / Tech 3341 (Momentary, Short-term),
// EBU Tech 3342 (Loudness Range).
//
// FCP 와 상관없는 순수 계산이다. AppKit 이나 ProExtensionHost 를 쓰지 않으므로
// 리포 밖 시험 프로그램에 이 파일만 넣어 ffmpeg(ebur128) 결과와 비교할 수 있다 (docs/workflow-ext-notes.md 9절).

import Accelerate
import AVFoundation
import Foundation

// MARK: - 설정 (대략값. 사용자가 보고 조정한다)

enum LoudnessSettings {
    /// 튐: 순간 음량(400ms)이 전체 평균(Integrated)보다 이만큼 넘게 크면 표시한다 (LU)
    static let spikeAboveIntegrated = 8.0
    /// 작음: 단기 음량(3초)이 전체 평균보다 이만큼 넘게 작으면 표시한다 (LU)
    static let quietBelowIntegrated = 10.0
    /// 무음 기준: 녹음의 소음 바닥(순간 음량 하위 10%)보다 이만큼 큰 소리까지 쉬는 구간으로 본다 (dB)
    static let silenceAboveNoise = 6.0
    /// 무음 기준의 최솟값 (LUFS). 아주 조용한 녹음에서 기준이 너무 내려가지 않게 한다
    static let silenceFloor = -50.0
    /// 작음은 이 시간 이상 이어질 때만 표시한다 (초)
    static let quietMinDuration = 2.0
    /// 작음 구간 안에서 순간 음량이 한 번은 '평균 - 이 값'을 넘어야 말소리로 본다 (LU).
    /// 숨소리, 키보드 소리처럼 말이 아닌 작은 소리를 거른다
    static let quietSpeechWithin = 20.0
    /// 같은 종류의 문제 구간 사이가 이보다 짧으면 하나로 합친다 (초)
    static let mergeGap = 0.5
    /// Integrated 가 목표와 이만큼 안이면 맞은 것으로 본다 (LU)
    static let tolerance = 1.0
}

/// 목표 기준. 사용자가 강의와 유튜브만 쓰기로 했다.
struct LoudnessTarget: Equatable {
    let id: String
    let name: String
    let integrated: Double   // LUFS
    let truePeak: Double     // dBTP 상한

    static let lecture = LoudnessTarget(id: "lecture", name: "강의", integrated: -16, truePeak: -1)
    static let youtube = LoudnessTarget(id: "youtube", name: "유튜브", integrated: -14, truePeak: -1)
    static let all = [lecture, youtube]
}

struct LoudnessProblem {
    enum Kind { case spike, peak, quiet }
    let kind: Kind
    let start: Double   // 초
    let end: Double
    /// spike, quiet: 그 구간의 음량(LUFS, 가장 크거나 가장 작은 값), peak: True Peak(dBTP)
    let value: Double
}

struct LoudnessResult {
    /// 값 하나가 대표하는 시간 간격 (초). Momentary 와 Short-term 을 이 간격으로 잰다.
    static let step = 0.1

    let duration: Double
    let sampleRate: Double
    let channels: Int
    /// i 번째 값은 (i+1)·step 에서 끝나는 400ms 창의 음량. 창이 덜 찼거나 무음이면 -inf
    let momentary: [Double]
    /// i 번째 값은 (i+1)·step 에서 끝나는 3초 창의 음량
    let shortTerm: [Double]
    /// i 번째 값은 [i·step, (i+1)·step) 구간의 True Peak (dBTP)
    let peaks: [Double]
    let integrated: Double
    let loudnessRange: Double
    /// 녹음의 소음 바닥: 순간 음량의 하위 10% (LUFS). 쉬는 구간의 방 소음 크기에 가깝다
    let noiseFloor: Double
    let momentaryMax: Double
    let shortTermMax: Double
    let truePeakMax: Double

    /// 목표 기준으로 문제 구간을 고른다. 시작 시각 순서.
    func problems(target: LoudnessTarget) -> [LoudnessProblem] {
        let step = Self.step
        var found: [LoudnessProblem] = []

        if integrated.isFinite {
            // 튐: 400ms 창 전체를 표시한다. 큰 소리가 창 안 어딘가에 있다.
            let spikeLimit = integrated + LoudnessSettings.spikeAboveIntegrated
            var spikes: [LoudnessProblem] = []
            for (i, m) in momentary.enumerated() where m > spikeLimit {
                let end = Double(i + 1) * step
                spikes.append(.init(kind: .spike, start: max(0, end - 0.4), end: end, value: m))
            }
            found += Self.merge(spikes, keepLarger: true)

            // 작음: 3초 평균이 작고, 그 가운데 순간에 말소리가 있는 칸만 고른다.
            // 쉬는 구간(방 소음)은 순간 음량이 무음 기준 아래라서 빠진다.
            // 3초 창의 가운데 한 칸만 표시하고 이어 붙인 뒤, 짧은 것은 버린다.
            let quietLimit = integrated - LoudnessSettings.quietBelowIntegrated
            let silence = max(LoudnessSettings.silenceFloor, noiseFloor + LoudnessSettings.silenceAboveNoise)
            var quiet: [LoudnessProblem] = []
            for (i, s) in shortTerm.enumerated() where s.isFinite && s < quietLimit && s > silence {
                let center = Double(i + 1) * step - 1.5
                let around = i - 13   // 가운데를 둘러싼 400ms 창: (i+1)·step - 1.3 에서 끝난다
                guard around >= 0, momentary[around] > silence else { continue }
                quiet.append(.init(kind: .quiet, start: center - step / 2, end: center + step / 2, value: s))
            }
            let speechLevel = integrated - LoudnessSettings.quietSpeechWithin
            found += Self.merge(quiet, keepLarger: false)
                .filter { $0.end - $0.start >= LoudnessSettings.quietMinDuration }
                .filter { problem in
                    let first = max(0, Int(problem.start / step))
                    let last = min(momentary.count, Int(problem.end / step) + 1)
                    return first < last && (momentary[first..<last].max() ?? -.infinity) > speechLevel
                }
        }

        var peakProblems: [LoudnessProblem] = []
        for (i, p) in peaks.enumerated() where p > target.truePeak {
            peakProblems.append(.init(kind: .peak, start: Double(i) * step, end: Double(i + 1) * step, value: p))
        }
        found += Self.merge(peakProblems, keepLarger: true)

        return found.sorted { $0.start < $1.start }
    }

    private static func merge(_ items: [LoudnessProblem], keepLarger: Bool) -> [LoudnessProblem] {
        var merged: [LoudnessProblem] = []
        for item in items.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, item.start - last.end <= LoudnessSettings.mergeGap {
                let value = keepLarger ? max(last.value, item.value) : min(last.value, item.value)
                merged[merged.count - 1] = .init(kind: last.kind, start: last.start,
                                                 end: max(last.end, item.end), value: value)
            } else {
                merged.append(item)
            }
        }
        return merged
    }
}

enum LoudnessAnalyzer {
    enum Failure: LocalizedError {
        case unreadable(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .unreadable(let why): return "파일을 읽지 못했습니다: \(why)"
            case .cancelled: return "분석을 멈췄습니다"
            }
        }
    }

    /// 파일 전체를 읽어 잰다. 오래 걸리므로 메인 스레드에서 부르지 않는다.
    static func analyze(url: URL,
                        progress: (Double) -> Void = { _ in },
                        isCancelled: () -> Bool = { false }) throws -> LoudnessResult {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw Failure.unreadable(error.localizedDescription)
        }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        let channels = Int(format.channelCount)
        guard channels > 0, sampleRate > 0 else { throw Failure.unreadable("채널이나 샘플레이트가 없음") }

        let blockSize = Int((sampleRate * LoudnessResult.step).rounded())   // 100ms 의 샘플 수
        let chunkFrames = blockSize * 10                                     // 한 번에 1초씩 읽는다
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunkFrames)) else {
            throw Failure.unreadable("버퍼를 만들지 못함")
        }

        let weighting = KWeighting(sampleRate: sampleRate, channels: channels)
        let truePeak = TruePeakMeter(sampleRate: sampleRate, channels: channels, maxFrames: chunkFrames)
        let weights = channelWeights(channels)
        var filtered = [Float](repeating: 0, count: chunkFrames)

        var energies: [Double] = []   // 100ms 칸마다 채널 가중 제곱합
        var peakLinear: [Float] = []  // 100ms 칸마다 True Peak (선형)
        let totalFrames = max(1, Double(file.length))
        var readFrames = 0.0

        // 파일 끝에서 더 읽으려 하면 AVAudioFile 이 오류를 내므로 남은 길이만큼만 읽는다.
        while file.framePosition < file.length {
            if isCancelled() { throw Failure.cancelled }
            let remaining = Int(file.length - file.framePosition)
            do {
                try file.read(into: buffer, frameCount: AVAudioFrameCount(min(chunkFrames, remaining)))
            } catch {
                throw Failure.unreadable(error.localizedDescription)
            }
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let data = buffer.floatChannelData else { throw Failure.unreadable("소리 데이터 없음") }

            // 파일 끝의 100ms 가 안 되는 나머지는 버린다 (게이팅 블록은 꽉 찬 칸만 쓴다).
            let blocks = frames / blockSize
            var blockEnergy = [Double](repeating: 0, count: blocks)
            var blockPeak = [Float](repeating: 0, count: blocks)

            for ch in 0..<channels {
                filtered.withUnsafeMutableBufferPointer { out in
                    weighting.process(channel: ch, input: data[ch], output: out.baseAddress!, count: frames)
                    for b in 0..<blocks {
                        var sum: Float = 0
                        vDSP_svesq(out.baseAddress! + b * blockSize, 1, &sum, vDSP_Length(blockSize))
                        blockEnergy[b] += Double(sum) * weights[ch]
                    }
                }
                truePeak.process(channel: ch, input: data[ch], count: frames,
                                 blockSize: blockSize, blocks: blocks, into: &blockPeak)
            }
            energies += blockEnergy
            peakLinear += blockPeak
            readFrames += Double(frames)
            progress(min(1, readFrames / totalFrames))
        }

        return summarize(energies: energies, peakLinear: peakLinear, blockSize: blockSize,
                         sampleRate: sampleRate, channels: channels,
                         duration: Double(file.length) / sampleRate)
    }

    /// BS.1770-4 의 채널 가중치. 5.1(L R C LFE Ls Rs)만 따로 다루고 나머지는 모두 1이다.
    private static func channelWeights(_ channels: Int) -> [Double] {
        if channels == 6 { return [1, 1, 1, 0, 1.41, 1.41] }
        return Array(repeating: 1, count: channels)
    }

    private static func loudness(_ meanSquare: Double) -> Double {
        meanSquare > 0 ? -0.691 + 10 * log10(meanSquare) : -.infinity
    }

    private static func summarize(energies: [Double], peakLinear: [Float], blockSize: Int,
                                  sampleRate: Double, channels: Int, duration: Double) -> LoudnessResult {
        let count = energies.count
        // 창 하나의 평균 제곱. 창이 덜 찼으면 nil.
        func window(_ end: Int, _ length: Int) -> Double? {
            guard end + 1 >= length else { return nil }
            var sum = 0.0
            for j in (end + 1 - length)...end { sum += energies[j] }
            return sum / Double(length * blockSize)
        }

        var momentaryZ: [Double] = []   // 게이팅 블록(400ms, 75% 겹침)의 평균 제곱
        var momentary: [Double] = []
        var shortTermZ: [Double] = []
        var shortTerm: [Double] = []
        momentary.reserveCapacity(count)
        shortTerm.reserveCapacity(count)
        for i in 0..<count {
            if let z = window(i, 4) {
                momentaryZ.append(z)
                momentary.append(loudness(z))
            } else {
                momentary.append(-.infinity)
            }
            if let z = window(i, 30) {
                shortTermZ.append(z)
                shortTerm.append(loudness(z))
            } else {
                shortTerm.append(-.infinity)
            }
        }

        // Integrated: 절대 게이트 -70 LUFS, 상대 게이트 -10 LU (BS.1770-4)
        let absGated = momentaryZ.filter { loudness($0) > -70 }
        var integrated = -Double.infinity
        if !absGated.isEmpty {
            let relative = loudness(absGated.reduce(0, +) / Double(absGated.count)) - 10
            let gated = absGated.filter { loudness($0) > relative }
            if !gated.isEmpty { integrated = loudness(gated.reduce(0, +) / Double(gated.count)) }
        }

        // Loudness Range: 절대 게이트 -70 LUFS, 상대 게이트 -20 LU, 10~95 백분위 차이 (Tech 3342)
        var range = 0.0
        let stAbs = shortTermZ.filter { loudness($0) > -70 }
        if !stAbs.isEmpty {
            let relative = loudness(stAbs.reduce(0, +) / Double(stAbs.count)) - 20
            let values = stAbs.map(loudness).filter { $0 > relative }.sorted()
            if values.count > 1 {
                func percentile(_ p: Double) -> Double { values[Int((Double(values.count - 1) * p).rounded())] }
                range = percentile(0.95) - percentile(0.10)
            }
        }

        // 소음 바닥: 순간 음량(-70 LUFS 넘는 것)의 하위 10%
        let audible = momentary.filter { $0 > -70 }.sorted()
        let noiseFloor = audible.isEmpty ? -70 : audible[Int(Double(audible.count - 1) * 0.1)]

        let peaks = peakLinear.map { $0 > 0 ? 20 * log10(Double($0)) : -.infinity }
        return LoudnessResult(
            duration: duration, sampleRate: sampleRate, channels: channels,
            momentary: momentary, shortTerm: shortTerm, peaks: peaks,
            integrated: integrated, loudnessRange: range, noiseFloor: noiseFloor,
            momentaryMax: momentary.max() ?? -.infinity,
            shortTermMax: shortTerm.max() ?? -.infinity,
            truePeakMax: peaks.max() ?? -.infinity)
    }
}

// MARK: - K 가중 필터

/// BS.1770-4 의 2단 필터(고역 선반 + RLB 고역 통과). 계수는 샘플레이트에 맞춰 계산한다
/// (libebur128 과 같은 식. 48kHz 에서 표준 계수와 같다).
private final class KWeighting {
    private let setup: vDSP_biquad_Setup
    private var delays: [[Float]]

    init(sampleRate fs: Double, channels: Int) {
        // 1단: 고역 선반
        var f0 = 1681.974450955533
        let gain = 3.999843853973347
        var q = 0.7071752369554196
        var k = tan(Double.pi * f0 / fs)
        let vh = pow(10, gain / 20)
        let vb = pow(vh, 0.4996667741545416)
        var a0 = 1 + k / q + k * k
        let shelf = [(vh + vb * k / q + k * k) / a0,
                     2 * (k * k - vh) / a0,
                     (vh - vb * k / q + k * k) / a0,
                     2 * (k * k - 1) / a0,
                     (1 - k / q + k * k) / a0]
        // 2단: 고역 통과
        f0 = 38.13547087602444
        q = 0.5003270373238773
        k = tan(Double.pi * f0 / fs)
        a0 = 1 + k / q + k * k
        let highpass = [1, -2, 1,
                        2 * (k * k - 1) / a0,
                        (1 - k / q + k * k) / a0]
        setup = vDSP_biquad_CreateSetup(shelf + highpass, 2)!
        delays = Array(repeating: [Float](repeating: 0, count: 2 * 2 + 2), count: channels)
    }

    deinit { vDSP_biquad_DestroySetup(setup) }

    func process(channel: Int, input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, count: Int) {
        vDSP_biquad(setup, &delays[channel], input, 1, output, 1, vDSP_Length(count))
    }
}

// MARK: - True Peak

/// 4배 오버샘플링(48kHz 기준)으로 샘플 사이의 봉우리까지 잰다 (BS.1770-4 부록 2).
/// 다상(polyphase) 보간 필터는 카이저 창을 씌운 sinc 다. 원래 샘플 값도 함께 본다.
/// 탭 수와 차단 주파수는 고정밀 리샘플러(ffmpeg aresample filter_size=512)로 잰 기준값에 맞춰 정했다.
/// 강의 녹음에서 기준 +0.03 dB, 고정 사인파에서 이론값과 같다 (docs/workflow-ext-notes.md 9절).
private final class TruePeakMeter {
    static let tapsPerPhase = 32
    static let kaiserBeta = 8.0
    /// 원래 나이퀴스트에 대한 차단 주파수 비율
    static let cutoff = 0.95

    private let factor: Int
    private let taps = TruePeakMeter.tapsPerPhase   // 위상 하나의 탭 수
    private var phases: [[Float]] = []    // vDSP_conv 용으로 뒤집어 둔 위상별 계수
    private var history: [[Float]]        // 채널마다 앞 청크의 끝 (taps - 1) 샘플
    private var work: [Float]
    private var out: [Float]

    init(sampleRate: Double, channels: Int, maxFrames: Int) {
        factor = sampleRate < 96_000 ? 4 : (sampleRate < 192_000 ? 2 : 1)
        history = Array(repeating: [Float](repeating: 0, count: taps - 1), count: channels)
        work = [Float](repeating: 0, count: taps - 1 + maxFrames)
        out = [Float](repeating: 0, count: maxFrames)
        guard factor > 1 else { return }

        // 위상 p 는 x[n-D] 에서 p/factor 칸 뒤의 값을 만든다: h_p[m] = c·sinc(c·(m - D + p/factor))·창.
        // D 가 정수라서 위상 0 은 원래 샘플을 그대로 돌려주고, 나머지 위상은 정확히 1/4 칸씩 뒤다.
        let delay = Double(taps / 2)
        let cutoff = Self.cutoff
        for p in 0..<factor {
            var phase = (0..<taps).map { m -> Double in
                let x = Double(m) - delay + Double(p) / Double(factor)
                let arg = Double.pi * cutoff * x
                let sinc = arg == 0 ? 1 : sin(arg) / arg
                let r = min(1, abs(x) / (delay + 1))
                let kaiser = Self.besselI0(Self.kaiserBeta * (1 - r * r).squareRoot()) / Self.besselI0(Self.kaiserBeta)
                return sinc * kaiser
            }
            let sum = phase.reduce(0, +)
            phase = phase.map { $0 / sum }   // 위상마다 직류 이득 1
            phases.append(phase.reversed().map(Float.init))
        }
    }

    /// 0차 변형 베셀 함수 (카이저 창용 급수)
    private static func besselI0(_ x: Double) -> Double {
        var sum = 1.0, term = 1.0
        for k in 1..<50 {
            term *= (x / (2 * Double(k))) * (x / (2 * Double(k)))
            sum += term
            if term < 1e-12 * sum { break }
        }
        return sum
    }

    /// 100ms 칸마다 가장 큰 절댓값을 blockPeak 에 더한다(큰 쪽으로).
    func process(channel: Int, input: UnsafePointer<Float>, count: Int,
                 blockSize: Int, blocks: Int, into blockPeak: inout [Float]) {
        // 원래 샘플
        for b in 0..<blocks {
            var m: Float = 0
            vDSP_maxmgv(input + b * blockSize, 1, &m, vDSP_Length(blockSize))
            blockPeak[b] = max(blockPeak[b], m)
        }
        guard factor > 1 else { return }

        let keep = taps - 1
        work.withUnsafeMutableBufferPointer { w in
            history[channel].withUnsafeBufferPointer { h in
                w.baseAddress!.update(from: h.baseAddress!, count: keep)
            }
            (w.baseAddress! + keep).update(from: input, count: count)
            out.withUnsafeMutableBufferPointer { o in
                for phase in phases {
                    // o[n] = Σ w[n+m]·phase[m] : 이 청크의 n 번째 샘플 근처의 보간 값
                    vDSP_conv(w.baseAddress!, 1, phase, 1, o.baseAddress!, 1,
                              vDSP_Length(count), vDSP_Length(taps))
                    for b in 0..<blocks {
                        var m: Float = 0
                        vDSP_maxmgv(o.baseAddress! + b * blockSize, 1, &m, vDSP_Length(blockSize))
                        blockPeak[b] = max(blockPeak[b], m)
                    }
                }
            }
            history[channel].withUnsafeMutableBufferPointer { h in
                h.baseAddress!.update(from: w.baseAddress! + count, count: keep)
            }
        }
    }
}
