# spooky-motion

Final Cut Pro에서 쓰는 Motion 템플릿(효과, 트랜지션, 타이틀, 제너레이터) 모음입니다.

템플릿은 대부분 **파이썬 생성기로 만듭니다**. Motion 템플릿 파일(OZML)은 XML이라서, 좌표나 움직임 곡선을 코드로 정하면 다음과 같은 이점이 있습니다.
- 위치나 크기를 숫자 하나만 고쳐서 다시 만들 수 있습니다.
- 서로 짝이 맞아야 하는 템플릿(예: 효과와 그 효과용 트랜지션)이 어긋나지 않습니다.
- Motion에서 손으로 하기 어려운 곡선(용수철, 휘어진 경로)을 만들 수 있습니다.

## 설치

```sh
./install.sh               # 모든 팩을 만들고 검사한 뒤 설치
./install.sh --dry-run     # 설치하면 무엇이 바뀌는지 미리 보기
./install.sh --build-only  # build/ 에만 만들기
```

- 설치 위치는 `~/Movies/Motion Templates.localized`입니다. `MOTION_TEMPLATES_DIR`로 바꿀 수 있습니다.
- 팩이 만든 카테고리 폴더만 맞추고, 다른 템플릿은 건드리지 않습니다.
- 설치한 뒤에는 **FCP를 다시 실행**해야 보입니다.
- 필요한 것은 macOS 기본 `python3`, `xmllint`, `rsync`뿐입니다.

## 팩

| 팩 | 카테고리 | 내용 |
|---|---|---|
| [lecture-pip](packs/lecture-pip/README.md) | 강의 PIP | 강사 PIP 배치 효과(크게 / 작게 · 아래 / 작게 · 위)와, 앞뒤 배치를 스스로 알아내는 전환 |
| [skin-retouch](packs/skin-retouch/README.md) | 피부 보정 | 얼굴 피부 보정 효과. FxPlug 플러그인(`fxplug/skin-retouch`)을 감싼 템플릿 |
| [screen-zoom](packs/screen-zoom/README.md) | 화면 확대 | 고른 영역으로 확대했다가 돌아오는 효과. 뷰어 핸들로 영역을 고른다. FxPlug 플러그인(`fxplug/screen-zoom`)을 감싼 템플릿 |

## FxPlug 플러그인

Motion 필터만으로 안 되는 효과는 FxPlug 플러그인(Swift + Metal)으로 직접 만듭니다. 혼자 쓰는 용도라서 이 맥의 개발 인증서로만 서명합니다.

```sh
fxplug/skin-retouch/build.sh   # 빌드 → ~/Applications 에 설치 → 등록 (플러그인마다)
fxplug/screen-zoom/build.sh
./install.sh                   # FCP 에서 보이게 감싸는 템플릿 설치
```

- 필요한 것: Xcode, FxPlug SDK, `xcodegen`. 자세한 내용은 `docs/fxplug-notes.md`에 있습니다.

## 워크플로 확장

FCP 안에 창으로 뜨는 도구는 워크플로 확장으로 만듭니다. 플레이헤드를 읽고 옮길 수 있습니다.

```sh
workflow/loudness-check/build.sh   # 빌드 → /Applications 에 설치 → 등록
```

- `loudness-check`: 음량 검사 패널. FCP의 윈도우 메뉴 > 확장 프로그램 > '음량 검사'.
  - FCP에서 소리만 WAV로 `~/Movies/LoudnessCheck`에 내보내면 자동으로 잽니다. 5개 값(Integrated, Short-Term Max, Momentary Max, Loudness Range, True Peak), 목표(강의 -16 / 유튜브 -14 LUFS) 대비 조정량, 음량 그래프, 문제 구간(튐, 피크, 작음)을 보여 줍니다.
  - 그래프나 문제 구간을 누르면 FCP 플레이헤드가 그 위치로 갑니다.
  - 공유 대상은 처음 한 번만 만듭니다: Final Cut Pro > Settings…(⌘,) > Destinations 탭에서 Add Destination을 누르고 Export File을 왼쪽 목록으로 끌어 놓은 뒤, Format은 Audio Only, Audio file format은 WAVE로 정합니다. File > Share 하위 메뉴는 타임라인이나 프로젝트가 선택돼 있어야 쓸 수 있습니다.
- 처음 열 때 'Final Cut Pro 제어' 허락 창이 뜨면 허용합니다. 프로젝트 정보를 읽는 데 필요합니다.
- 필요한 것: Xcode, Workflow Extension SDK, `xcodegen`. 자세한 내용은 `docs/workflow-ext-notes.md`에 있습니다.
- FCP는 플러그인을 Motion 템플릿으로 감싸야 보여 줍니다. 감싸는 템플릿은 해당 팩의 `generate.py`가 만듭니다.

## 구조

```
install.sh            모든 팩 생성 → 검사(xmllint) → 설치
lib/ozml.py           공용 도구: XML, 그룹·도형·클론, 리그 팝업/체크박스, 키프레임 곡선, 드롭존, 필터
docs/ozml-notes.md    OZML 작업 노트: 번호의 뜻, 함정, 조사 방법
docs/fxplug-notes.md  FxPlug 작업 노트: 구조, 빌드·서명 함정, 쓸 수 있는 API
docs/workflow-ext-notes.md  워크플로 확장 작업 노트: 구조, 자동화 허락 함정, 타임라인 API 동작
packs/<팩>/
  generate.py         생성기 (`--out <폴더>`)
  templates/          (선택) Motion에서 직접 만든 템플릿. <종류>.localized/<카테고리>/... 구조 그대로
  README.md           사용법
fxplug/<플러그인>/
  project.yml         Xcode 프로젝트 설정 (XcodeGen). .xcodeproj 는 build.sh 가 만든다
  build.sh            빌드 → 설치 → 등록
  App/                그릇 앱
  Plugin/             플러그인 코드와 Metal 셰이더
workflow/<확장>/
  project.yml         Xcode 프로젝트 설정 (XcodeGen). .xcodeproj 는 build.sh 가 만든다
  build.sh            빌드 → /Applications 에 설치 → 등록
  App/                그릇 앱
  Extension/          FCP 안에 뜨는 패널
```

만든 결과물(`build/`)은 언제든 다시 만들 수 있어서 커밋하지 않습니다.

## 새 팩 추가

1. `packs/<팩 이름>/generate.py`를 만듭니다. 기존 팩처럼 `lib`를 경로에 넣고 `from ozml import *`로 시작하며, `--out` 폴더에 `write_template(...)`로 저장합니다.
2. Motion에서 직접 만든 템플릿이라면 `packs/<팩 이름>/templates/` 아래에 `Effects.localized/<카테고리>/...` 구조 그대로 넣습니다.
3. `./install.sh --dry-run`으로 확인하고 `./install.sh`로 설치합니다.
4. 새로 알게 된 OZML 규칙은 근거와 함께 `docs/ozml-notes.md`에 적습니다.
