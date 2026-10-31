#!/usr/bin/env bash
# 모든 팩을 만들어 FCP/Motion 템플릿 폴더에 설치한다.
#
#   ./install.sh               만들기 + 검사 + 설치
#   ./install.sh --build-only  build/ 에 만들고 검사만 한다
#   ./install.sh --dry-run     만들고 검사한 뒤, 설치하면 바뀔 파일만 보여 준다
#
# 설치 위치: $MOTION_TEMPLATES_DIR (기본 ~/Movies/Motion Templates.localized)
# 팩이 만든 카테고리 폴더만 통째로 맞춘다(--delete). 다른 템플릿은 건드리지 않는다.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
BUILD="$REPO/build"
DEST="${MOTION_TEMPLATES_DIR:-$HOME/Movies/Motion Templates.localized}"

mode="install"
case "${1:-}" in
  "") ;;
  --build-only) mode="build" ;;
  --dry-run) mode="dry" ;;
  -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
  *) echo "[오류] 모르는 옵션: $1 (도움말: ./install.sh --help)" >&2; exit 2 ;;
esac

# 1) 만들기 ---------------------------------------------------------------
rm -rf "$BUILD"
mkdir -p "$BUILD"
found=0
for pack in "$REPO"/packs/*/; do
  name="$(basename "$pack")"
  if [[ -f "$pack/generate.py" ]]; then
    echo "▶ $name: 생성"
    python3 -B "$pack/generate.py" --out "$BUILD" | sed 's/^/    /'
    found=1
  fi
  if [[ -d "$pack/templates" ]]; then
    echo "▶ $name: Motion 에서 만든 템플릿 복사"
    rsync -a "$pack/templates/" "$BUILD/"
    found=1
  fi
done
if [[ $found -eq 0 ]]; then
  echo "[오류] packs/ 아래에 팩이 없습니다" >&2
  exit 1
fi

# 2) 검사 ----------------------------------------------------------------
count=0
while IFS= read -r -d '' f; do
  xmllint --noout "$f"
  count=$((count + 1))
done < <(find "$BUILD" -type f \( -name '*.moef' -o -name '*.motr' -o -name '*.moti' -o -name '*.motn' \) -print0)
echo "✔ XML 검사 통과: ${count}개"

if [[ $mode == "build" ]]; then
  echo "build/ 에만 만들었습니다: $BUILD"
  exit 0
fi

# 3) 설치 ----------------------------------------------------------------
if [[ ! -d "$DEST" ]]; then
  echo "[오류] 템플릿 폴더가 없습니다: $DEST" >&2
  echo "       Motion 을 한 번 실행하거나 MOTION_TEMPLATES_DIR 로 위치를 지정하세요." >&2
  exit 1
fi

for kind in "$BUILD"/*/; do
  kind_name="$(basename "$kind")"
  for cat in "$kind"*/; do
    cat_name="$(basename "$cat")"
    target="$DEST/$kind_name/$cat_name"
    echo "▶ $kind_name/$cat_name"
    if [[ $mode == "dry" ]]; then
      if [[ ! -d "$target" ]]; then
        echo "    새로 설치"
      elif changes="$(diff -rq "$cat" "$target/" 2>&1)"; then
        echo "    바뀐 것 없음"
      else
        printf '%s\n' "$changes" | sed -e "s|$BUILD/||g" -e "s|$DEST/||g" -e 's/^/    /'
      fi
    else
      mkdir -p "$target"
      rsync -a --delete "$cat" "$target/"
    fi
  done
done

if [[ $mode == "dry" ]]; then
  echo "(미리 보기만 했습니다. 실제 설치는 ./install.sh)"
else
  echo "✔ 설치 완료: $DEST"
  echo "  FCP 를 다시 실행해야 바뀐 템플릿이 보입니다."
fi
