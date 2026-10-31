// FCP 와 같은 모양의 타임코드 (HH:MM:SS:FF, 드롭 프레임은 HH:MM:SS;FF).

import CoreMedia
import Foundation

struct Timecode {
    let frameSeconds: Double
    let nominalFPS: Int
    let dropFrame: Bool

    /// formatRaw: FCPXSequenceTimecodeFormat 의 원래 값 (0 NDF, 1 DF).
    /// FCP 12.4 는 DF/NDF 가 아닌 값을 준다(docs/workflow-ext-notes.md 7절). 그때는 1001 계열 프레임 속도면
    /// DF 로 본다. 59.94fps 프로젝트에서 FCP 눈금자가 ';' 로 DF 를 보였다.
    init(frameDuration: CMTime?, formatRaw: Int?) {
        if let frame = frameDuration, frame.isValid, frame.seconds > 0 {
            frameSeconds = frame.seconds
        } else {
            frameSeconds = 1.0 / 30
        }
        nominalFPS = max(1, Int((1 / frameSeconds).rounded()))
        let is1001 = frameDuration.map { $0.isValid && $0.value % 1001 == 0 } ?? false
        switch formatRaw {
        case 0: dropFrame = false
        case 1: dropFrame = is1001
        default: dropFrame = is1001 && nominalFPS % 30 == 0
        }
    }

    func string(_ seconds: Double) -> String {
        var frame = Int((max(0, seconds) / frameSeconds + 1e-6).rounded(.down))
        if dropFrame {
            // 10분마다를 빼고 매 분 처음 drop 개의 번호를 건너뛴다 (29.97 은 2, 59.94 는 4)
            let drop = nominalFPS / 15
            let perMinute = nominalFPS * 60 - drop
            let perTenMinutes = nominalFPS * 600 - drop * 9
            let tens = frame / perTenMinutes
            let rest = frame % perTenMinutes
            frame += drop * 9 * tens + (rest > drop ? drop * ((rest - drop) / perMinute) : 0)
        }
        let ff = frame % nominalFPS
        let total = frame / nominalFPS
        let separator = dropFrame ? ";" : ":"
        return String(format: "%02d:%02d:%02d%@%02d", total / 3600, (total / 60) % 60, total % 60, separator, ff)
    }
}
