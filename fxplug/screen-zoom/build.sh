#!/usr/bin/env bash
# 화면 확대 FxPlug 플러그인을 빌드해서 ~/Applications 에 설치하고 등록한다.
#
#   fxplug/screen-zoom/build.sh            빌드 + 설치 + 등록
#   fxplug/screen-zoom/build.sh --build-only  빌드만 한다
#
# 필요한 것: Xcode, FxPlug SDK(/Library/Developer/SDKs/FxPlug.sdk), xcodegen
# 설치한 뒤에는 FCP 와 Motion 을 다시 실행해야 바뀐 플러그인을 읽는다.
# FCP 에서 보이려면 감싸는 템플릿도 있어야 한다: 리포 맨 위에서 ./install.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$HERE/build"
APP_NAME="ScreenZoom.app"
DEST="$HOME/Applications/$APP_NAME"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

mode="install"
case "${1:-}" in
  "") ;;
  --build-only) mode="build" ;;
  -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
  *) echo "[오류] 모르는 옵션: $1" >&2; exit 2 ;;
esac

for need in xcodegen xcodebuild; do
  command -v "$need" >/dev/null || { echo "[오류] $need 이 없습니다" >&2; exit 1; }
done
[[ -d /Library/Developer/SDKs/FxPlug.sdk ]] || { echo "[오류] FxPlug SDK 가 없습니다" >&2; exit 1; }

echo "▶ Xcode 프로젝트 만들기"
(cd "$HERE" && xcodegen generate --quiet)

echo "▶ 빌드"
xcodebuild -project "$HERE/ScreenZoom.xcodeproj" -scheme ScreenZoom -configuration Release \
  -derivedDataPath "$BUILD" -quiet build
APP="$BUILD/Build/Products/Release/$APP_NAME"
echo "✔ 빌드 완료: $APP"

if [[ $mode == "build" ]]; then
  exit 0
fi

echo "▶ 설치: $DEST"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$APP" "$DEST"
"$LSREGISTER" -f "$DEST"
pluginkit -a "$DEST/Contents/PlugIns/ScreenZoomPlugIn.pluginkit"

if pluginkit -m -p FxPlug -i com.ibare.spooky.ScreenZoom.PlugIn | grep -q .; then
  echo "✔ 등록됨: $(pluginkit -m -p FxPlug -i com.ibare.spooky.ScreenZoom.PlugIn | sed 's/^ *//')"
else
  echo "[경고] pluginkit 목록에 아직 보이지 않습니다. 앱을 한 번 실행해 보세요: open \"$DEST\"" >&2
fi
echo "  FCP 와 Motion 을 다시 실행해야 바뀐 플러그인을 읽습니다."
