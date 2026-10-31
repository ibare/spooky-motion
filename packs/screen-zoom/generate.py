#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
화면 확대 팩 생성기

만드는 것 (카테고리 '화면 확대')
  - 효과: 화면 확대.moef  — FxPlug 플러그인 ScreenZoomPlugIn(fxplug/screen-zoom)을 감싸는 템플릿

실행
  python3 generate.py --out <폴더>      보통은 리포 맨 위의 ./install.sh 로 실행한다.

FCP 는 FxPlug 플러그인을 바로 보여 주지 않는다. 플러그인 필터를 건 Motion 템플릿으로만 보여 준다
(애플 문서 'Preparing plug-ins for use in Final Cut Pro'). 그래서 이 템플릿은
[Effect Source + 플러그인 필터] 하나이고, 플러그인 파라미터를 인스펙터에 퍼블리시만 한다.
뷰어 조절점(영역 사각형)은 필터의 'Publish OSC' 를 켜야 FCP 에 보인다 (애플 템플릿 Vignette.moef 와 같은 형식).
플러그인 자체는 fxplug/screen-zoom/build.sh 로 빌드하고 설치한다.
"""

import os
import plistlib
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, "lib"))

from ozml import *  # noqa: E402,F401,F403

guard(30)

# ─────────────────────────────── 설정 ───────────────────────────────
CATEGORY = "화면 확대"
EFFECT_NAME = "화면 확대"

# 인스펙터 항목 (플러그인 파라미터 id, 표시 이름). 적은 순서대로 보인다.
# id 는 fxplug/screen-zoom/Plugin/ScreenZoomPlugIn.swift 의 ZoomParam 과 같아야 한다.
PUBLISHED = [
    (1, "영역 고르기"),
    (2, "가운데"),
    (3, "배율"),
    (4, "움직임 시간"),
    (5, "유지 시간 (0 = 끝까지)"),
    (6, "움직임 곡선"),
    (7, "모션 블러"),
]
# ────────────────────────────────────────────────────────────────────

PLUGIN_INFO = os.path.join(REPO, "fxplug", "screen-zoom", "Plugin", "Info.plist")

# 필터의 화면 조절점을 FCP 에 보이게 하는 파라미터. 형식은 애플 템플릿 Vignette.moef 와 같다.
PUBLISH_OSC = P("Publish OSC", 10005, 8606711808, 0, 1)


def plugin_entry():
    """플러그인 Info.plist 의 필터 항목 (uuid, version, displayName). 템플릿과 플러그인이 어긋나지 않게 여기서 읽는다.
    조절점 항목(FxOnScreenControl)은 필터가 아니므로 고르지 않는다."""
    with open(PLUGIN_INFO, "rb") as f:
        info = plistlib.load(f)
    filters = [e for e in info["ProPlugPlugInList"] if "FxFilter" in e["protocolNames"]]
    if len(filters) != 1:
        sys.exit(f"[오류] {PLUGIN_INFO} 에 필터가 하나여야 합니다 (지금 {len(filters)}개)")
    return filters[0]


def build_effect():
    entry = plugin_entry()
    F = Factories(["Project", "Widget", "Image", "ProPlugin Filter"])
    ids = Ids()
    ids.project = ids()
    group_id, src_id, filter_id = ids(), ids(), ids()
    footage_id, clip_id = ids(), ids()

    flt = fxplug_filter(F, filter_id, entry["displayName"], entry["uuid"], entry["version"],
                        params=[PUBLISH_OSC])
    source = effect_source(F, src_id, clip_id, filters=[flt])
    layer = group(EFFECT_NAME, group_id, [source])

    targets = [E("target", {"object": filter_id, "channel": f"./{pid}", "name": label})
               for pid, label in PUBLISHED]
    fc = footage(footage_id, [media_clip("Effect Source", clip_id, "Drop Zone.tiff", 1200)])
    return document(F, [project_node(F, ids), layer, fc], targets)


def main():
    out = out_dir_from_argv(os.path.join(REPO, "build"))
    print(f"효과 : {write_template(out, CATEGORY, EFFECT_NAME, 'moef', build_effect())}")


if __name__ == "__main__":
    main()
