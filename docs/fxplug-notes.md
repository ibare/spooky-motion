# FxPlug 작업 노트

FxPlug 4 플러그인(`fxplug/<플러그인>/`)을 만들면서 확인한 사실을 모았습니다. 템플릿(OZML) 쪽 사실은 `docs/ozml-notes.md`에 있습니다.
항목마다 근거를 적습니다.

- **확인됨(빌드)**: 이 맥에서 빌드나 서명 검사로 확인했습니다.
- **확인됨(FCP 결과)**: FCP에서 실제 결과로 확인했습니다.
- **애플 문서 / SDK**: 애플 개발자 문서나 FxPlug SDK(헤더, Xcode 템플릿)에 있습니다.

---

## 1. 필요한 것

- Xcode, FxPlug 4 SDK, Motion, FCP가 필요합니다. SDK는 https://developer.apple.com/download/all/?q=FxPlug 에서 받습니다(애플 문서 'Setting up for FxPlug development').
- SDK를 설치하면 다음이 깔립니다(SDK 4.3.5 설치 기록).
  - `/Library/Developer/SDKs/FxPlug.sdk`: 빌드용 헤더와 `.tbd`. `ADDITIONAL_SDKS`로 붙입니다.
  - `/Library/Developer/Frameworks/{FxPlug,PluginManager}.framework`: 실행용 프레임워크. 플러그인 안에 복사해 넣습니다.
  - `/Library/Developer/Xcode/Templates/FxPlug/FxPlug 4.xctemplate`: Xcode 템플릿. 프로젝트 구성과 예제 코드(Metal 밝기 필터)의 원본입니다.
- 이 리포는 Xcode 프로젝트를 `project.yml`(XcodeGen)로 만듭니다. 구성은 SDK 템플릿과 같게 맞췄습니다.

## 2. 구조

- 플러그인은 **그릇 앱 안의 `.pluginkit` 번들**입니다(SDK 템플릿).
  - 그릇 앱: 샌드박스 권한(`com.apple.security.app-sandbox`)만 있습니다. 하는 일은 없습니다.
  - `.pluginkit`: `MACH_O_TYPE = mh_execute`, `WRAPPER_EXTENSION = pluginkit`인 번들입니다. 앱의 `Contents/PlugIns`에 들어갑니다. 권한 파일은 없습니다(Beauty Box도 비어 있습니다).
  - Info.plist의 `ProPlugPlugInList`에 필터마다 `className`(Swift의 `@objc` 이름), `uuid`, `displayName`, `protocolNames = [FxFilter]`를 적습니다.
- **FCP는 플러그인을 바로 보여 주지 않습니다.** 플러그인 필터를 건 Motion 템플릿(.moef)으로 감싸야 효과 목록에 나옵니다(애플 문서 'Preparing plug-ins for use in Final Cut Pro'). 감싸는 템플릿은 `packs/<팩>/generate.py`가 만듭니다. 형식은 `ozml-notes.md` 11절에 있습니다.

## 3. 빌드와 서명의 함정

- **앱에 플러그인을 넣을 때 Xcode가 안쪽 프레임워크의 `Headers`와 `Modules`를 지웁니다.** 그 전에 서명해 둔 프레임워크는 서명이 깨집니다.
  - 확인됨(빌드): `codesign --verify --deep --strict`가 `PluginManager.framework/.../Modules/module.modulemap` 누락으로 실패했습니다.
  - 그래서 프레임워크를 복사할 때 처음부터 `Headers`와 `Modules`를 뺍니다. SDK 템플릿은 `Headers`만 뺍니다.
  - rsync에서 제외한 파일은 `--delete`만으로는 지워지지 않습니다. 앞선 빌드에서 남은 파일까지 지우려면 `--delete-excluded`가 필요합니다. 확인됨(빌드).
- 서명은 이 맥의 Apple Development 인증서로 합니다. 혼자 쓰므로 Developer ID 서명과 공증은 하지 않습니다.

## 4. 설치와 등록

- 앱을 `~/Applications`에 두고 `lsregister -f <앱>`과 `pluginkit -a <.pluginkit>`로 등록합니다. 등록은 `pluginkit -m -p FxPlug`로 확인합니다. 확인됨(빌드).
- 플러그인이나 템플릿을 바꾼 뒤에는 FCP와 Motion을 다시 실행해야 읽습니다.

## 5. 진단

- **`NSLog`는 통합 로그에 남지 않습니다.** 확인됨(빌드): 작은 시험 프로그램의 `NSLog`가 `log show`에 보이지 않았습니다. `os.Logger`의 `notice`는 남았습니다.
  - 플러그인은 `Logger(subsystem: "com.ibare.spooky.SkinRetouch", ...)`로 기록합니다. 보기: `/usr/bin/log show --last 10m --predicate 'subsystem == "com.ibare.spooky.SkinRetouch"'`.
  - 값은 `privacy: .public`을 붙여야 보입니다. 붙이지 않으면 `<private>`로 가려집니다.
  - zsh에서는 `log`가 내장 명령이라 `/usr/bin/log`로 불러야 합니다.
- FCP는 시작할 때 모든 FxPlug 플러그인 프로세스를 띄웁니다. 플러그인 프로세스가 떠 있다고 해서 필터가 불린 것은 아닙니다.
- 플러그인 프로세스의 `failed to get my own sandbox container` 오류는 Beauty Box에도 똑같이 있습니다. 무시해도 됩니다.

## 6. 쓸 수 있는 API (SDK 헤더)

- **`FxTileableEffect`**: 렌더의 기본 틀입니다. 출력은 조각(tile) 단위로 그립니다. 주변 픽셀이 필요한 처리(흐림 등)는 `sourceTileRect`에서 입력 영역을 넓혀야 합니다.
- **`kFxPropertyKey_PixelTransformSupport`**: 호스트가 축소된 이미지(미리보기 화질 등)를 넘길 수 있습니다. 픽셀 단위 반경은 변환 배율에 맞춰야 합니다.
- **`scheduleInputs:withPluginState:atTime:error:`** + `FxImageTileRequest`: **다른 시점의 원본 프레임**을 요청할 수 있습니다(`FxTileableEffect.h`). 잡티 판정 깜빡임을 줄이는 데 쓸 수 있습니다.
- **`FxAnalyzer`**(`FxAnalysis.h`): 클립의 프레임 구간을 **미리 훑어 분석**하는 기능입니다. 얼굴 위치 같은 값을 미리 구해 두는 데 쓸 수 있습니다.
