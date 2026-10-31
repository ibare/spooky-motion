#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
피부 보정 팩 생성기

만드는 것 (카테고리 '피부 보정')
  - 효과: 피부 보정.moef  — FxPlug 플러그인 SkinRetouchPlugIn(fxplug/skin-retouch)을 감싸는 템플릿

실행
  python3 generate.py --out <폴더>      보통은 리포 맨 위의 ./install.sh 로 실행한다.

FCP 는 FxPlug 플러그인을 바로 보여 주지 않는다. 플러그인 필터를 건 Motion 템플릿으로만 보여 준다
(애플 문서 'Preparing plug-ins for use in Final Cut Pro'). 그래서 이 템플릿은
[Effect Source + 플러그인 필터] 하나이고, 플러그인 파라미터를 인스펙터에 퍼블리시만 한다.
플러그인 자체는 fxplug/skin-retouch/build.sh 로 빌드하고 설치한다.
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
CATEGORY = "피부 보정"
EFFECT_NAME = "피부 보정"

# 인스펙터 항목 (플러그인 파라미터 id, 표시 이름). 적은 순서대로 보인다.
# id 는 fxplug/skin-retouch/Plugin/SkinRetouchPlugIn.swift 의 Param 과 같아야 한다.
PUBLISHED = [
    (10, "보기"),
    (13, "정도"),
    (14, "크기"),
    (15, "결 살리기"),
    (16, "잡티 지우기"),
    (17, "번들거림 줄이기"),
    (11, "피부색 범위"),
    (12, "수염 영역 제외"),
]
# ────────────────────────────────────────────────────────────────────

PLUGIN_INFO = os.path.join(REPO, "fxplug", "skin-retouch", "Plugin", "Info.plist")


def plugin_entry():
    """플러그인 Info.plist 의 필터 항목 (uuid, version, displayName). 템플릿과 플러그인이 어긋나지 않게 여기서 읽는다."""
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

    flt = fxplug_filter(F, filter_id, entry["displayName"], entry["uuid"], entry["version"])
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
