# 워크플로 확장 작업 노트

FCP 워크플로 확장(`workflow/<확장>/`)을 만들면서 확인한 사실을 모았습니다. FxPlug 쪽은 `docs/fxplug-notes.md`에 있습니다.
항목마다 근거를 적습니다.

- **확인됨(빌드)**: 이 맥에서 빌드나 서명 검사로 확인했습니다.
- **확인됨(FCP 결과)**: FCP 12.4에서 실제 동작이나 로그로 확인했습니다.
- **애플 문서 / SDK**: 애플 개발자 문서나 Workflow Extension SDK(헤더, Xcode 템플릿)에 있습니다.
- **디스어셈블**: FCP 안의 `ProExtensionHost.framework`를 `otool`로 읽어 추론했습니다. 동작으로 다시 확인하지 않은 것은 그렇게 적습니다.

---

## 1. 무엇을 할 수 있나

- 워크플로 확장은 **FCP 안에 뜨는 창**입니다. 툴바의 확장 버튼이나 윈도우 메뉴 > 확장 프로그램에서 엽니다(애플 문서 'Building a Workflow Extension').
- 타임라인 API(`FCPXHost.h`): 플레이헤드 읽기와 옮기기, 열린 시퀀스 정보, 바뀜 알림. **소리나 영상 내용은 읽을 수 없습니다.** FCP의 스크립트 사전(`ProEditor.sdef`)에도 라이브러리 구조만 있고 플레이헤드나 소리는 없습니다.
- FxPlug과 달리 감싸는 Motion 템플릿이 필요 없습니다.

## 2. 필요한 것

- SDK는 https://developer.apple.com/download/all/?q=WorkflowExtensions 에서 받습니다(애플 문서). SDK 1.0.3 설치 기록(`pkgutil --files com.apple.pkg.WorkflowExtensionsSDK`):
  - `/Library/Developer/SDKs/WorkflowExtensionSDK.sdk`: 헤더(`FCPXHost.h`, `ProExtension.h`), `ProExtensionHost.tbd`, `libProExtension.a`.
  - `/Library/Developer/Xcode/Templates/ProVideo/WorkflowExtension/FCP Workflow Extension.xctemplate`: Xcode 템플릿. 프로젝트 구성의 원본입니다.
- **실행용 프레임워크는 설치되지 않습니다.** 실행할 때 FCP가 자기 안의 `ProExtensionHost.framework`를 확장에 불러 줍니다(디스어셈블: `libProExtension.a`의 `loadPlugInSupportFrameworks:`가 FCP가 보낸 북마크로 번들을 엽니다).

## 3. 구조

- **그릇 앱 안의 `.appex`**입니다(SDK 템플릿). XcodeGen의 `type: app-extension`으로 만듭니다.
- 확장 Info.plist: `NSExtensionPointIdentifier = com.apple.FinalCut.WorkflowExtension`, `ProExtensionPrincipalViewControllerClass = <뷰 컨트롤러 이름>`. `ProExtensionAttributes`로 창 최소 크기를 정합니다(SDK 템플릿, 애플 문서).
- 진입점은 `LD_ENTRY_POINT = _ProExtensionMain`이고 `-lProExtension`을 링크합니다(SDK 템플릿).
- Swift 뷰 컨트롤러는 `@objc(이름)`으로 Objective-C 이름을 고정해야 Info.plist의 이름과 맞습니다. 템플릿처럼 xib를 쓰지 않고 `loadView`에서 코드로 그려도 됩니다. 확인됨(FCP 결과).

## 4. 빌드와 서명의 함정

- **`HEADER_SEARCH_PATHS = /usr/include`를 넣어야 합니다.** 템플릿은 프로젝트 수준에서 정해서 대상 설정만 옮기면 빠집니다. 빠지면 `'ProExtension/ProExtension.h' file not found`가 납니다. 확인됨(빌드).
- **`ProExtensionHost.framework`에 직접 링크하면 안 됩니다.** 2절처럼 실행용 프레임워크가 확장 안에 없기 때문입니다. Swift의 `import ProExtensionHost`는 자동 링크를 넣으므로 `-Xfrontend -disable-autolink-framework -Xfrontend ProExtensionHost`로 끕니다. `FCPX…` 클래스 기호를 참조해도 링크가 생기므로 `as? FCPXTimeline` 같은 클래스 변환을 쓰지 않습니다. `build.sh`가 `otool -L`과 `nm -u`로 검사합니다. 확인됨(빌드).
- Swift 이름: `addTimelineObserver:` → `add(_:)`, `removeTimelineObserver:` → `remove(_:)`, `movePlayheadTo:` → `movePlayhead(to:)`. 확인됨(빌드).
- 서명은 이 맥의 Apple Development 인증서로 합니다. **FCP는 개발 서명 확장을 불러 줍니다.** 확인됨(FCP 결과).

## 5. 설치와 등록

- 그릇 앱을 **`/Applications`**에 두고 한 번 실행합니다(애플 문서). `build.sh`는 `lsregister -f`, `pluginkit -a`, `open -g`를 합니다. 등록은 `pluginkit -m -p com.apple.FinalCut.WorkflowExtension`으로 확인합니다. 확인됨(빌드).
- 확장을 바꾼 뒤에는 FCP를 다시 실행해야 읽습니다.

## 6. 시퀀스 정보와 자동화 허락 (가장 큰 함정)

`activeSequence`가 nil이면 이 절의 단계 중 하나가 막힌 것입니다.

- **`activeSequence`의 속성은 확장이 FCP에 Apple Event로 물어서 얻습니다.** 알림으로는 시퀀스 위치(라이브러리 → 이벤트 → 프로젝트 이름으로 된 지정자)만 오고, 프레임워크가 `core/getd`로 `pESE`(기본 속성)를 묻습니다. 답이 없으면 객체를 만들지 않아 nil이 됩니다. 확인됨(FCP 결과, 이벤트 가로채기 로그).
- **샌드박스 권한**: FCP 사전의 접근 묶음 `com.apple.FinalCut.library.inspection`(읽기)을 `com.apple.security.scripting-targets`로 받습니다. 없으면 `sandboxd`가 `deny(1) appleevent-send com.apple.finalcut`을 기록합니다. 확인됨(FCP 결과).
- **자동화 허락(TCC)은 그릇 앱의 허락으로 판정됩니다.** 확장이 보내도 tccd는 `target_identifier = com.ibare.spooky.LoudnessCheck`(그릇 앱)로 처리합니다. 그래서 **`NSAppleEventsUsageDescription`이 그릇 앱 Info.plist에 있어야** 합니다. 없으면 허락 창 없이 `-1743`으로 거부되고, tccd 로그에 `No usage string found`가 남습니다. 이 거부는 허락 기록에 저장되지 않습니다. 확인됨(FCP 결과, tccd 로그).
- **프레임워크는 허락 창이 뜰 수 없는 옵션으로 묻습니다**(디스어셈블: `sendEventWithOptions:` 옵션 `0x13` = 답 기다림 + 상호작용 안 함). 허락 기록이 없으면 `-1743`이 납니다. 그래서 패널이 열릴 때 `AEDeterminePermissionToAutomateTarget(FCP, 'core', 'getd', true)`로 허락 창을 직접 요청합니다(`Automation.swift`). 이 요청과 함께 허락 창이 떴고, 허용한 뒤 시퀀스 정보가 들어왔습니다. 확인됨(FCP 결과).
- **처음 한 번만 오래 기다립니다**(디스어셈블): 프레임워크는 확장의 기본 설정에 `com.apple.FinalCut.WorkflowExtension.AutomationPromptKey`가 없으면 60초, 있으면 2초를 기다리고, 보낸 뒤 이 값을 남깁니다. 허락 전에 값이 남으면 허락 창에 답할 시간이 없어집니다. `build.sh`가 설치할 때마다 지웁니다. 값의 위치는 `~/Library/Containers/<확장 id>/Data/Library/Preferences/<확장 id>.plist`입니다. 확인됨(파일).
- 허락 상태는 `~/Library/Application Support/com.apple.TCC/TCC.db`의 `access` 표에서 `service = 'kTCCServiceAppleEvents'`로 볼 수 있습니다.

## 7. 타임라인 API의 실제 동작

모두 확인됨(FCP 결과). FCP 12.4, 59.94fps 프로젝트 기준입니다.

- **`movePlayhead(to:)`는 요청한 위치로 정확히 옮깁니다.** 돌려받는 값은 요청값과 같고, timescale만 720000으로 바뀝니다.
- **재생 중에는 플레이헤드 알림이 오지 않습니다.** `playheadTime`은 알림으로 받아 둔 값을 돌려주므로(디스어셈블: 변수 읽기만 함) 재생 중 위치는 알 수 없습니다. 멈추거나, 클릭하거나, 훑을 때 갱신됩니다.
- 알림은 메인 스레드로 옵니다. 패널을 열면 `activeSequenceChanged`와 `sequenceTimeRangeChanged`가 한 번씩 옵니다.
- `sequenceTimeRange`는 Apple Event 없이 알림으로 옵니다. 그래서 자동화 허락이 없어도 길이는 알 수 있습니다.
- 59.94fps 프로젝트의 `frameDuration`은 `1001/60000`입니다. `timecodeFormat`은 **-1(Unspecified)**이 옵니다. 그런데 FCP 눈금자는 `;`로 드롭 프레임을 보였으므로, 1001 계열 프레임 속도면 DF로 표시합니다(`Timecode.swift`).

## 8. 진단

- 패널 로그: `/usr/bin/log show --last 10m --predicate 'subsystem == "com.ibare.spooky.LoudnessCheck"'`
- 샌드박스 거부: `/usr/bin/log show --last 10m --predicate 'process == "sandboxd" AND eventMessage CONTAINS "LoudnessCheck"'`
- 허락 판정: `/usr/bin/log show --info --last 10m --predicate 'process == "tccd"'`. `REQUEST_MSG`, `Handling access request`, `No usage string found`를 찾습니다.
- 프레임워크의 `sendAppleEvent: host return result:` 로그는 결과를 `<private>`로 가립니다. 답의 내용을 보려면 확장 안에서 `-[ProExtensionHostBase sendAppleEvent:]`를 가로채 같은 이벤트를 `sendEvent(options:timeout:)`로 다시 보내 `errn`을 읽습니다.
- **`NSAppleEventDescriptor`의 description은 한글을 깨뜨립니다.** 프로세스에 따라 UTF-8이나 시스템 인코딩(MacKorean) 바이트를 MacRoman 글자로 보여 줍니다. 이름이 깨져 보여도 실제 값은 멀쩡할 수 있으니 글자 코드로 확인합니다. 확인됨(시험 프로그램).
- Swift의 `==`는 NFC와 NFD를 같은 문자열로 봅니다. 정규화 형태를 비교하려면 `unicodeScalars`끼리 비교합니다.

## 9. 음량 측정의 검증

`Extension/LoudnessAnalyzer.swift`는 FCP와 상관없는 순수 계산이라 리포 밖 시험 프로그램에 그대로 넣어 검증합니다.

- 시험 방법: 시험 프로그램(`main.swift`)과 `LoudnessAnalyzer.swift`를 `swiftc -O`로 함께 빌드해서 파일을 재고, `ffmpeg -af ebur128=peak=true:metadata=1,ametadata=print:file=…`의 값과 비교합니다. Momentary/Short-term 최대값은 `lavfi.r128.M`/`lavfi.r128.S`의 최대값입니다.
- 결과(확인됨, 2026-10-31): 1kHz 사인파, 실제 강의 녹음 10분(48kHz 스테레오), 44.1kHz 모노에서 Integrated, Short-Term Max, Momentary Max, LRA가 ffmpeg와 0.05 LU 안에서 같습니다. 10분 녹음을 0.3초에 잽니다.
- **True Peak 기준은 ffmpeg ebur128이 아니라 고정밀 리샘플러로 잽니다.** `aformat=sample_fmts=dbl,aresample=192000:filter_size=512:phase_shift=10:cutoff=0.98,aformat=sample_fmts=dbl,astats`의 Peak level이 기준입니다. 고정 사인파에서 이론값과 같았습니다. ffmpeg ebur128은 같은 강의 녹음을 0.13 dB 작게 잽니다.
  - 정수 형식(s16, s24)을 그대로 올리면 0 dBFS에서 잘리므로 `aformat=sample_fmts=dbl`을 먼저 씁니다.
  - 사인파를 갑자기 시작하거나 자르면 경계에서 울림이 생겨 높게 잽니다. 올린 뒤에 가운데만 잘라(`atrim`) 잽니다.
- True Peak 필터(확인됨): 위상마다 계수를 직접 계산해 위상 0이 원래 샘플, 나머지가 정확히 1/4칸씩 뒤가 되게 합니다. 짝수 길이 원형 필터를 나누면 1/8칸 어긋나 반 칸 지점의 봉우리를 놓칩니다. 위상당 32탭, 카이저 β 8, 차단 0.95에서 강의 녹음이 기준 +0.03 dB입니다.
- '작음' 판정(확인됨): 고정 무음 기준(-45 LUFS)은 방 소음(-46 LUFS)과 붙어서 쉬는 구간 11곳을 '작음'으로 잘못 잡았습니다. 무음 기준을 녹음의 소음 바닥(순간 음량 하위 10%) + 6 dB로 정하고, 3초 창 가운데 순간에 소리가 있을 때만 잡게 바꾸자 말소리가 있는 도입부만 남았습니다.
  - 편집을 마친 프로젝트(소음 제거 후 소음 바닥 -54 LUFS)에서는 숨소리, 키보드 소리 같은 작은 소리(-35~-45 LUFS)가 무음 기준을 넘어 잡혔습니다. 구간 안에서 순간 음량이 한 번은 '평균 - 20 LU'를 넘어야 말소리로 보게 하자 9곳이 4곳으로 줄었습니다.
- `AVAudioFile.read(into:frameCount:)`는 파일 끝에서 더 읽으려 하면 오류를 냅니다. 남은 길이만큼만 읽습니다. 확인됨(시험 프로그램).

## 10. 샌드박스에서 파일 읽기와 내보내기 감지

- 확장은 `com.apple.security.temporary-exception.files.home-relative-path.read-only`에 적은 `~/Movies/LoudnessCheck/`만 읽습니다. 폴더는 `build.sh`가 만듭니다.
- 샌드박스 안의 `NSHomeDirectory()`는 컨테이너를 가리키므로, 진짜 홈은 `getpwuid(getuid())`로 얻습니다.
- **`URL.resourceValues(forKeys:)`는 같은 URL 객체에 대해 처음 값을 기억해 둡니다.** 파일을 키운 뒤 다시 물어도 처음 크기(0)를 돌려줬습니다. 확인됨(시험 프로그램). 커지는 파일의 크기는 `FileManager.attributesOfItem(atPath:)`로 매번 읽습니다.
- FCP는 내보낼 파일을 처음에 만들고 끝까지 키워 갑니다. 20분 31초 프로젝트(24비트 WAV 354MB)에 1~2분쯤 걸렸습니다. 확인됨(FCP 결과).
- 파일이 커지는 것만으로는 폴더 감시(`DispatchSource` 디렉터리 `.write`) 알림이 오지 않습니다. 그래서 패널이 열려 있는 동안 2초마다 폴더를 다시 보고, 크기가 1.4초 동안 그대로여야 다 쓴 것으로 봅니다.
