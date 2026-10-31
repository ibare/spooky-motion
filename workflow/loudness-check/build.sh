#!/usr/bin/env bash
# 음량 검사 워크플로 확장을 빌드해서 /Applications 에 설치하고 등록한다.
#
#   workflow/loudness-check/build.sh              빌드 + 설치 + 등록
#   workflow/loudness-check/build.sh --build-only 빌드만 한다
#
# 필요한 것: Xcode, Workflow Extension SDK(/Library/Developer/SDKs/WorkflowExtensionSDK.sdk), xcodegen
# 애플 문서('Building a Workflow Extension')대로 그릇 앱을 /Applications 에 두고 한 번 실행한다.
# 설치한 뒤에는 FCP 를 다시 실행해야 바뀐 확장을 읽는다.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD="$HERE/build"
APP_NAME="LoudnessCheck.app"
EXT_ID="com.ibare.spooky.LoudnessCheck.Extension"
DEST="/Applications/$APP_NAME"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

mode="install"
case "${1:-}" in
  "") ;;
  --build-only) mode="build" ;;
  -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
  *) echo "[오류] 모르는 옵션: $1" >&2; exit 2 ;;
esac

for need in xcodegen xcodebuild; do
  command -v "$need" >/dev/null || { echo "[오류] $need 이 없습니다" >&2; exit 1; }
done
[[ -d /Library/Developer/SDKs/WorkflowExtensionSDK.sdk ]] || { echo "[오류] Workflow Extension SDK 가 없습니다" >&2; exit 1; }

echo "▶ Xcode 프로젝트 만들기"
(cd "$HERE" && xcodegen generate --quiet)

echo "▶ 빌드"
xcodebuild -project "$HERE/LoudnessCheck.xcodeproj" -scheme LoudnessCheck -configuration Release \
  -derivedDataPath "$BUILD" -quiet build
APP="$BUILD/Build/Products/Release/$APP_NAME"
APPEX="$APP/Contents/PlugIns/LoudnessCheckExtension.appex"
BIN="$APPEX/Contents/MacOS/LoudnessCheckExtension"

# ProExtensionHost.framework 는 FCP 가 실행 중에 넘겨 준다. 직접 링크되면 확장이 뜨지 못한다.
if otool -L "$BIN" | grep -q ProExtensionHost; then
  echo "[오류] 확장이 ProExtensionHost.framework 에 링크되었습니다" >&2; exit 1
fi
if nm -u "$BIN" | grep -q 'OBJC_CLASS_\$_FCPX'; then
  echo "[오류] 확장이 FCPX 클래스 기호를 직접 참조합니다:" >&2
  nm -u "$BIN" | grep 'OBJC_CLASS_\$_FCPX' >&2; exit 1
fi
codesign --verify --deep --strict "$APP"
echo "✔ 빌드 완료: $APP"

if [[ $mode == "build" ]]; then
  exit 0
fi

echo "▶ 내보낸 소리를 둘 폴더: $HOME/Movies/LoudnessCheck"
# 확장은 샌드박스 안에서 이 폴더만 읽을 수 있다 (Extension.entitlements).
mkdir -p "$HOME/Movies/LoudnessCheck"

echo "▶ 설치: $DEST"
# FCP 프레임워크는 확장이 처음 Apple Event 를 보낼 때만 60초를 기다리고(자동화 허락 창에 답할 시간),
# 그 뒤로는 이 표시를 남겨 2초만 기다린다. 허락을 받기 전에 표시가 남으면 허락 창이 다시 뜨지 않으므로
# 설치할 때마다 지운다. 이미 허락했다면 지워도 아무 일이 없다.
defaults delete "$HOME/Library/Containers/$EXT_ID/Data/Library/Preferences/$EXT_ID" \
  com.apple.FinalCut.WorkflowExtension.AutomationPromptKey 2>/dev/null || true
rm -rf "$DEST"
ditto "$APP" "$DEST"
"$LSREGISTER" -f "$DEST"
pluginkit -a "$DEST/Contents/PlugIns/LoudnessCheckExtension.appex"
open -g "$DEST"

if pluginkit -m -p com.apple.FinalCut.WorkflowExtension -i "$EXT_ID" | grep -q .; then
  echo "✔ 등록됨: $(pluginkit -m -p com.apple.FinalCut.WorkflowExtension -i "$EXT_ID" | sed 's/^ *//')"
else
  echo "[경고] pluginkit 목록에 아직 보이지 않습니다" >&2
fi
echo "  FCP 를 다시 실행해야 바뀐 확장을 읽습니다."
