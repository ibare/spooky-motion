# OZML 작업 노트

Motion 템플릿(.moef 효과, .motr 트랜지션, .moti 타이틀, .motn 제너레이터)을 XML로 직접 만들면서 확인한 사실을 모았습니다.
항목마다 **근거**를 함께 적었습니다. 새로 알게 된 사실은 근거와 함께 여기에 추가합니다.

- **확인됨**: FCP에서 실제 결과로 확인했습니다.
- **애플 템플릿**: FCP에 들어 있는 애플 템플릿에서 같은 형식을 찾았습니다. 아래 "조사 방법"을 참고하세요.

---

## 1. 파일 기본 구조

- 머리말은 `<ozml version="5.13">`, `<displayversion>5.6.3.1</displayversion>`, `<factory>` 목록, `<build></build>`, `<description></description>` 순서입니다. 그다음에 `<scene>`이 옵니다.
- `<scene>`은 `sceneSettings` → `publishSettings` → `timeRange`/`playRange` → … → 노드들(Project, Rig, 레이어, footage) 순서입니다.
- **형제 순서**: 앞에 쓴 레이어가 화면에서 **위**에 놓입니다. (확인됨: 효과의 둥근 창이 강사 영상보다 앞에 있어야 영상을 잘랐습니다.)
- **레이어 요소 순서**: 자식 레이어 → `aspectRatio`/`flags`/`timing`/`foldFlags`/`baseFlags` → `Properties`/`Object` 파라미터 → `behavior` 순서입니다.
- **시간 표기**: `"값 120000 1 0"`입니다. 59.94fps에서 한 프레임은 2002입니다. 300프레임 템플릿의 마지막 프레임은 598598입니다. 위젯과 Project 노드의 out은 `-2002`입니다.
- **캔버스**: 이 리포는 3840×2160, 300프레임으로 통일합니다. FCP가 템플릿을 실제 클립이나 트랜지션 길이에 맞춰 늘이거나 줄입니다.
- **좌표**: 원점이 화면 중앙이고 Y는 위쪽이 +입니다.

### 팩토리 UUID

| 이름 | UUID |
|---|---|
| Project | 7d468273c013498e9806a0d7bc32fddf |
| 프로젝트 화면비 Widget | 65cb4dc9d4504fa281921f5f751fba06 |
| Image (드롭존, Effect Source) | 66fc0d6af6a911d6a7a7000393670732 |
| Shape | 712462a4323911d78f8400039389b702 |
| Clone Layer | 84414060b0fd11d99bb5000a957d5fce |
| Rig | 402246385249454b90e08b2ee1b6bf06 |
| Rig Widget | e35c74f01d5042f6b468eb530169bfb7 |
| Rig Behavior | dd0036f96c9e4bfdadb82f71fbf5c9d8 |
| 채널: Position | 98458b1125bc499897c399d6d1240f52 |
| 채널: Scale | 11615b89cbc0483fb92e95eb0c80e59c |
| 채널: Double (X/Y/Z) | fdc1944b229111d7b1c300039389b702 |
| 채널: Opacity | 27f3ee8b229211d7925a00039389b702 |
| 채널: 일반 | 46c844a813d311d8a438000a95af9f7e |
| 그룹(layer) | ee6b4918387a11d7a02100039375d2ba — 리그 `affectingFactory`에만 씁니다 |

## 2. 파라미터 ID

| 묶음 | ID |
|---|---|
| Transform | 100: Position 101, Rotation 109, Scale 105, Anchor 107 |
| Blending | 200: Opacity 202, Blend Mode 203 |
| Drop Shadow | 208: Opacity 211, Distance 212, Blur 213, Angle 214, Fixed Source 232 |
| Crop | 216: Left 1, Right 2, Bottom 3, Top 4 |
| Shape (Object 아래 353) | Shape Type 100 (5 = 사각형), Roundness 144, Fill 113, Outline 108, Size 160 (Width 1, Height 2) |
| 위젯 (Object 아래) | 값 100, Snapshots 101, Hidden 102, Options 103 (Initial Value 106) |

- **채널 경로**는 ID를 이어 씁니다. 예: Position `./1/100/101`, Opacity `./1/200/202`, Roundness `./2/353/144`, 위젯 값 `./2/100`.
- **켜고 끄는 묶음**: Drop Shadow, Outline처럼 체크박스가 있는 묶음은 `flags`의 2048 비트가 켜짐입니다. 켠 Drop Shadow는 `8589940752`, 끈 Outline은 `8589971472`입니다.
- **Drop Shadow 각도**는 라디안입니다. 0이 오른쪽이고 반시계 방향으로 늘어납니다. 바로 아래는 `1.5π`, 기본값 `5.4978`은 오른쪽 아래입니다.

## 3. 혼합 모드 번호 (Blend Mode 203)

| 값 | 모드 |
|---|---|
| 0 | 일반 |
| 25 | **스텐실 알파**: 아래 레이어를 이 레이어 모양대로만 남깁니다 |
| 26 | 스텐실 루마 |
| 27 | **실루엣 알파**: 아래 레이어를 이 레이어 모양대로 뚫습니다 |
| 28 | 실루엣 루마 |
| 29 | 뒤(Behind) |
| 34 | 통과 (그룹 기본값) |

- **근거**
  - 확인됨: 27을 '스텐실'로 알고 넣었더니 FCP에서 창 모양으로 **구멍이 뚫렸습니다**. 25로 바꾸자 창 안쪽만 남았습니다.
  - 애플 템플릿: `Color Solid Behind` 레이어가 29를 씁니다.
  - Motion 메뉴 순서가 스텐실 알파, 스텐실 루마, 실루엣 알파, 실루엣 루마, 뒤입니다. 25~29가 이 순서와 맞습니다.
  - 애플 템플릿에 `Rectangle Stencil`이라는 레이어가 27을 쓰는 경우가 있습니다. 레이어 이름만 보고 모드를 짐작하면 안 됩니다.
- **그룹은 통과(34)로 두면 안 됩니다.** 안쪽 스텐실이나 실루엣이 그룹 밖 레이어까지 잘라냅니다. 스텐실을 담는 그룹은 일반(0)으로 고정합니다. 그룹에 실루엣(27)을 주면 그룹 전체를 하나의 실루엣으로 쓸 수 있습니다.

## 4. 키프레임

- **keypoint에 `interpolation` 속성을 넣지 않아야 베지어**가 됩니다. `interpolation="1"`은 선형이라 접선을 무시합니다.
  - 확인됨: `"1"`과 수평 접선을 함께 넣었더니 FCP에서 완전히 선형으로 움직였습니다. 속성을 빼자 이징이 됐습니다.
  - 애플 템플릿: 슬라이드 트랜지션들의 keypoint에 이 속성이 없습니다.
- **접선 단위**: `outputTangentTime`/`inputTangentTime`은 **초**입니다. `...TangentValue`는 채널 값 단위입니다.
  - 2키 베지어는 첫 키 출력 핸들을 (x1·길이, y1·변화량), 끝 키 입력 핸들을 (−(1−x2)·길이, −(1−y2)·변화량)으로 두면 CSS `cubic-bezier`와 같아집니다.
  - 복잡한 곡선(용수철 등)은 프레임을 고르게 나눠 값과 기울기를 찍습니다. 핸들은 이웃 키까지 거리의 1/3로 둡니다(`ozml.sampled_curve`).
- **드롭존 Retime 곡선**은 `interpolation="1"`(선형)이 맞습니다. 재생 속도용이기 때문입니다.

## 5. 리그 — 인스펙터 팝업과 체크박스

- **위젯 종류**: `<affecting>`이 1이면 체크박스, 2이면 팝업, 3이면 슬라이더입니다. 위젯은 `Rig` 노드 아래에 둡니다.
- **팝업 항목**: `<entry name tag>`의 tag가 곧 위젯 값입니다. 스냅샷마다 `Value`(id 1) = 그 tag입니다. 이 리포는 tag = 순번, 스냅샷 id = 순번 + 1로 둡니다.
- **Hidden(102)은 Motion이 마지막으로 편집하던 스냅샷 id입니다.** 그 스냅샷은 저장된 값 대신 **대상의 현재(저장된) 값**을 씁니다.
  - 그래서 Hidden은 반드시 **대상에 저장한 값과 같은 스냅샷**(= 기본 항목)을 가리켜야 합니다.
  - 확인됨: Hidden=1('크게')인데 그룹에 '작게 · 아래' 값을 저장했더니, '크게'를 골라도 작게 · 아래로 그려졌습니다. 체크박스도 같았습니다.
  - 애플 템플릿: Hidden이 현재 값과 다른 경우 21건 중 17건에서 저장값이 Hidden 스냅샷 값과 같았습니다.
- **리그 동작(Rig Behavior)** 형식:
  - `<channelBehavior affectingFactory affectingChannel sliderRange/>`를 둡니다. 대상 객체는 id 199, 위젯은 id 200, 스냅샷 묶음은 id 202입니다.
  - 위치·배율 스냅샷은 `Position`/`Scale` 채널 팩토리 아래에 X/Y/Z(Double)를 `<curve type="1" default value/>`로 둡니다(`ozml.vector_rig`). sliderRange는 위치 `3.4028234663852886e+38`, 배율 `4`입니다.
  - 불투명도 스냅샷은 Opacity 채널 팩토리에 `<min>0</min><max>1</max>`를 넣습니다(`ozml.opacity_rig`, 애플 `Aged Film`과 같은 형식). sliderRange는 `1`입니다.
  - `affectingFactory`는 대상 종류의 UUID입니다. 그룹은 그룹 UUID, 이미지는 Image, 클론은 Clone Layer UUID를 씁니다.
- **선택지별로 통째로 바꾸기**: 리그는 값만 바꿉니다. 키프레임 곡선 자체를 바꿀 수는 없습니다. 선택지마다 레이어 묶음을 따로 만들고, 리그로 각 묶음의 **불투명도를 1/0으로** 바꿉니다(트랜지션 '움직임' 팝업). 확인됨.

## 6. 퍼블리시 (FCP 인스펙터에 보이는 항목)

- `publishSettings` 안의 `<target object="노드 id" channel="경로" name="표시 이름"/>`가 인스펙터 항목이 됩니다. **적은 순서대로** 보입니다.
- 위젯은 `./2/100`, 레이어 파라미터는 `./1/100/101` 같은 경로를 씁니다.
- 체크박스는 체크로, 팝업은 팝업으로, 위치는 X/Y/Z 숫자로, 배율은 전체와 X/Y 슬라이더로 보입니다.

## 7. 효과(.moef)와 트랜지션(.motr)의 입력

- **효과**: `Effect Source`라는 Image 노드에 Drop Zone 311 = 1, Type 321 = 3을 둡니다. footage에 `Drop Zone.tiff` 클립을 둡니다(`ozml.effect_source`).
- **트랜지션**: Image 노드 두 개에 Drop Zone Type 321을 1 = 앞(A), 2 = 뒤(B)로 둡니다(`ozml.transition_source`).
  - 원본은 `<enabled>0</enabled>`로 숨기고 **클론으로만** 써도 됩니다(애플 `Sequence Transition 01`, 확인됨).
  - FCP는 **효과까지 적용된** 앞뒤 조각을 A/B로 넘깁니다. 확인됨: 트랜지션이 PIP 효과가 그려진 화면을 받았습니다.
  - 트랜지션 길이는 FCP가 정합니다(`shouldOverrideFCDuration` 0). 템플릿의 300프레임이 실제 길이에 맞춰 늘거나 줄어듭니다.

## 8. FCP 쪽 동작

- **클립 자체의 변형·자르기·왜곡은 효과보다 나중에** 적용됩니다.
  - 효과가 화면 배치를 정하는 경우, 클립에 손으로 넣은 변형·자르기 때문에 결과가 잘려 사라집니다. 확인됨.
  - 사용자에게 클립의 변형·자르기를 꺼 달라고 안내하거나, 필요한 기능(예: 좌우 반전)을 효과 안에 넣습니다.
- **템플릿을 바꾸면 FCP를 다시 실행**해야 반영됩니다.
- **템플릿을 지우면** 그 템플릿을 쓰던 타임라인 항목이 '없음'으로 표시됩니다. 이름을 유지하면 새 버전으로 바뀝니다.
- 트랜지션 인스펙터의 '유형'(S자 곡선, +3dB, −3dB, 선형)은 **오디오 크로스페이드** 방식입니다. 템플릿 움직임과는 상관없습니다.
- 효과 브라우저의 미리보기 썸네일은 FCP가 효과를 실제로 그린 것입니다. '효과는 그려지는데 뷰어에서 안 보인다'를 가리는 단서가 됩니다.

## 9. 렌더러 함정

- **빈 레이어는 건너뛰어질 수 있습니다.**
  - 클론을 잘라 보니 투명한 부분만 남거나 영역 밖이 되면, 렌더러가 그 레이어를 아예 건너뛰는 것으로 보입니다.
  - 그래서 **"비었으면 아래를 지운다"를 스텐실로 만들면 동작하지 않습니다.** 건너뛰어진 스텐실은 아무것도 가리지 못합니다.
  - 확인됨: 9개 조합 그룹이 전부 보였습니다.
- **해법(이중 실루엣)**: [탐침(실루엣) + 화면 크기 불투명 바탕]을 한 그룹에 넣고, 그 그룹을 실루엣으로 얹습니다.
  - 탐침이 비거나 건너뛰어지면 바탕이 남아 아래를 지웁니다.
  - 탐침이 차 있으면 그룹이 비어서 아래가 그대로 남습니다.
  - 어느 쪽이든 결과가 맞습니다.
- **탐침 기법**: 클론을 작은 정사각형으로 자르고 크게 확대(×100)하면, 그 점이 차 있는지를 화면 전체 크기의 마스크로 바꿀 수 있습니다. 앞뒤 화면의 상태를 판별하는 유일한 조건 분기 수단입니다.

## 10. 조사 방법

- **애플 번들 템플릿**: `/Applications/Final Cut Pro.app/Contents/PlugIns/MediaProviders/MotionEffect.fxp/Contents/Resources/Templates.localized/`
  - 새 기능을 넣을 때는 먼저 여기서 같은 기능을 쓰는 템플릿을 찾아 형식을 그대로 따릅니다.
  - 파이썬 `xml.etree`로 값 분포를 집계하면 번호 뜻을 추정할 수 있습니다. 예: 혼합 모드 값별 레이어 이름, 리그 Hidden과 저장값의 관계.
- **Motion 문자열**: `/Applications/Motion.app/Contents/Frameworks/*/Resources/en.lproj/*.strings`에 메뉴 항목 순서가 있습니다. 예: `Blend Modes`.
- **FCP 캡처 분석**: 사용자가 보내 준 뷰어 캡처에서 사본들의 위치와 크기를 재고, 가설마다 예상 위치를 계산해서 맞춰 봅니다. 어떤 그룹이 보이는지 역산할 수 있습니다.
- **Motion 창 캡처**: `screencapture -x -o -l <창 id>`를 씁니다. 창 id는 CGWindowListCopyWindowInfo로 찾습니다. 단, `open -a Motion 파일`로는 문서가 열리지 않은 적이 있습니다.
