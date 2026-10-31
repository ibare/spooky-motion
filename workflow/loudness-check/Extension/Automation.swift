// FCP 에 Apple Event 를 보낼 자동화 허락을 받는다.
//
// 시퀀스 정보(activeSequence 의 이름, 프레임 길이 등)는 프레임워크가 FCP 에 Apple Event 로 물어서 얻는다.
// 프레임워크는 허락 창을 띄우지 않는 옵션으로 묻기 때문에, 허락을 받은 적이 없으면 -1743 으로 거부되고
// activeSequence 가 nil 이 된다. 그래서 패널이 열릴 때 허락 창을 직접 요청한다.
// 시스템은 이 요청을 그릇 앱의 요청으로 보므로 NSAppleEventsUsageDescription 이 그릇 앱 Info.plist 에 있어야 한다.
// 자세한 내용은 docs/workflow-ext-notes.md 6절.

import CoreServices
import Foundation
import os

enum Automation {
    private static let log = Logger(subsystem: "com.ibare.spooky.LoudnessCheck", category: "automation")

    /// 허락을 확인하고, 아직 묻지 않았으면 허락 창을 띄운다.
    /// 사용자가 답할 때까지 막히므로 메인 스레드에서 부르지 않는다.
    /// 돌려주는 값: 0 허락됨, -1743 거부됨, -1744 물어봐야 함, -600 FCP 가 실행 중이 아님
    static func requestPermission() -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.FinalCut")
        let status = AEDeterminePermissionToAutomateTarget(
            target.aeDesc, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), true)
        log.notice("자동화 허락 확인: \(status, privacy: .public)")
        return status
    }
}
