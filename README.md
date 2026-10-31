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

## 구조

```
install.sh            모든 팩 생성 → 검사(xmllint) → 설치
lib/ozml.py           공용 도구: XML, 그룹·도형·클론, 리그 팝업/체크박스, 키프레임 곡선, 드롭존
docs/ozml-notes.md    OZML 작업 노트: 번호의 뜻, 함정, 조사 방법
packs/<팩>/
  generate.py         생성기 (`--out <폴더>`)
  templates/          (선택) Motion에서 직접 만든 템플릿. <종류>.localized/<카테고리>/... 구조 그대로
  README.md           사용법
```

만든 결과물(`build/`)은 언제든 다시 만들 수 있어서 커밋하지 않습니다.

## 새 팩 추가

1. `packs/<팩 이름>/generate.py`를 만듭니다. 기존 팩처럼 `lib`를 경로에 넣고 `from ozml import *`로 시작하며, `--out` 폴더에 `write_template(...)`로 저장합니다.
2. Motion에서 직접 만든 템플릿이라면 `packs/<팩 이름>/templates/` 아래에 `Effects.localized/<카테고리>/...` 구조 그대로 넣습니다.
3. `./install.sh --dry-run`으로 확인하고 `./install.sh`로 설치합니다.
4. 새로 알게 된 OZML 규칙은 근거와 함께 `docs/ozml-notes.md`에 적습니다.
