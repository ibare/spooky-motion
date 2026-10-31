#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
강의 PIP 팩 생성기

만드는 것 (카테고리 '강의 PIP')
  - 효과    : PIP 레이아웃.moef  (인스펙터: 배치 / 좌우 반전 / 인물 위치 / 인물 크기 / 노출 / 모서리 둥글기)
  - 트랜지션: PIP 전환.motr      (인스펙터: 움직임 = 고급 / 부드럽게)

실행
  python3 generate.py --out <폴더>      보통은 리포 맨 위의 ./install.sh 로 실행한다.

배치 좌표·크기·움직임은 아래 '설정' 구역만 고친다.
효과와 트랜지션은 같은 좌표를 공유한다. Motion 에서 한쪽 템플릿만 직접 고치면
전환이 어긋나므로, 좌표는 항상 이 파일에서 바꾼다.

동작 원리
  효과: 그룹 안에 [둥근 사각형(스텐실 알파) + 강사 영상]을 넣고,
        팝업 리그가 그룹의 위치·배율을 배치별 값으로 바꾼다.
        '좌우 반전' 체크박스는 강사 영상만 뒤집는다 (배치 위치는 그대로).
        클립 자체의 변형·자르기는 FCP 가 효과 다음에 적용하므로 꺼 두어야 한다.
        모든 배치는 같은 비율이고 배율만 다르므로, 전환 중 모양이 그대로 닮은꼴로 움직인다.
  전환: FCP 는 효과가 적용된 앞/뒤 조각을 Transition A/B 로 넘긴다.
        배치 조합(앞 X → 뒤 Y)마다 그룹을 하나씩 두고,
        '탐침'(A·B 영상에서 각 배치 자리의 한 점을 크게 확대한 클론)으로
        실제 조합에 맞는 그룹만 보이게 한다.
        판정은 [탐침(실루엣) + 화면 크기 바탕] 그룹을 다시 실루엣으로 얹는 방식이라,
        탐침 자리가 비어 있으면 영상이 지워지고 차 있으면 그대로 남는다.
        보이는 그룹 안에서는 원래 크기가 더 큰 쪽 영상 하나만 옮기고 줄이거나 키운다.
        움직임마다 9개 조합 묶음을 따로 두고, '움직임' 팝업이 고른 묶음만 보이게 한다.
"""

import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(REPO, "lib"))

from ozml import *  # noqa: E402,F401,F403

guard(30)

# ─────────────────────────────── 설정 ───────────────────────────────
# 좌표 기준: 1920x1080 화면, 원점은 화면 중앙, Y 는 위쪽이 + (Motion 좌표계)
LARGE_W = 440          # '크게' 배치의 창 너비
LARGE_H = 672          # '크게' 배치의 창 높이
ROUNDNESS = 60         # '크게' 배치의 모서리 반경 (작은 배치는 배율만큼 줄어든다)

# (팝업 이름, 중심 X, 중심 Y, 배율)  ─ 배율 1 = LARGE_W x LARGE_H
LAYOUTS = [
    ("크게", 620, -12, 1.0),
    ("작게 · 아래", 781, -309, 0.45),
    ("작게 · 위", 781, 309, 0.45),
]
DEFAULT_LAYOUT = 1     # 효과를 처음 적용했을 때의 배치 (LAYOUTS 의 순번)

FRAMING_SCALE = 0.8    # 창 안에서 강사 영상의 기본 확대율 (인스펙터 '인물 크기')
MIRROR_DEFAULT = 0     # '좌우 반전' 체크박스의 처음 값 (0 = 꺼짐, 1 = 켜짐)
# '노출'은 Motion 감마 필터라 흰색과 검은색은 두고 중간 톤만 움직인다. 1 = 그대로.
# FCP '색상 조정'의 노출처럼 전체를 같은 비율로 낮추면 흰 벽까지 회색이 되고 얼굴이 탁해지는데,
# 감마는 흰색이 그대로이고 어둡게 할수록 색이 조금 진해져서 과노출을 자연스럽게 되돌린다.
EXPOSURE_DEFAULT = 1.0

# 트랜지션은 하나이고, 인스펙터의 '움직임' 팝업으로 아래 항목 중 하나를 고른다: (팝업 이름, 움직임)
#   ("bezier", (x1, y1, x2, y2)) : CSS cubic-bezier 와 같은 뜻의 이징 곡선
#   ("spring", (감쇠비, 진동수))  : 목표를 살짝 지나쳤다 돌아오는 용수철.
#                                  감쇠비가 작을수록 많이 튕기고, 진동수가 클수록 빨리 도착한다.
#   ("premium", None)            : 애플식 용수철 + 휘어진 경로 + 들었다 놓기 (PREMIUM 설정)
TRANSITION_NAME = "PIP 전환"
MOTION_STYLES = [
    ("고급", ("premium", None)),
    ("부드럽게", ("bezier", (0.65, 0.0, 0.35, 1.0))),  # 천천히 출발, 천천히 멈춤
]
DEFAULT_STYLE = 0      # 트랜지션을 처음 넣었을 때의 움직임 (MOTION_STYLES 의 순번)

# '고급' 전환: 애플식 용수철 + 휘어진 경로 + 들었다 놓기. 길이 단위는 1080 기준 픽셀.
PREMIUM = {
    "spring": (0.8, 9.0),        # 감쇠비 0.8 → 약 1.5% 지나침 (튕김이 보이지 않고 느껴지는 정도)
    "arc": 0.12,                 # 경로가 휘는 정도 (이동 거리 대비). 화면 가운데(왼쪽) 쪽으로 휜다
    "lift": 0.03,                # 가장 높이 들렸을 때 커지는 비율
    "shadow_opacity": 0.45,      # 가장 높이 들렸을 때 그림자 진하기 (출발·도착 때는 0)
    "shadow_blur": (10, 35),     # 그림자 흐림 (낮을 때, 가장 높을 때)
    "shadow_distance": (4, 20),  # 그림자가 아래로 떨어진 거리 (낮을 때, 가장 높을 때)
}

CATEGORY = "강의 PIP"
EFFECT_NAME = "PIP 레이아웃"
# ────────────────────────────────────────────────────────────────────

# 탐침: 잘라낼 정사각형 한 변(4K 픽셀)과 확대 배율. 변 x 배율이 화면 너비보다 커야 한다.
PROBE_CROP = 48
PROBE_SCALE = 100
assert PROBE_CROP * PROBE_SCALE > OUT_W * 1.1


# ─────────────────────────── 기하 계산 ───────────────────────────
def layout_geo(i):
    """배치 i 의 (중심x, 중심y, 배율, 너비, 높이) — 4K 템플릿 좌표"""
    _, cx, cy, k = LAYOUTS[i]
    return cx * K, cy * K, k, LARGE_W * k * K, LARGE_H * k * K


def rect(i):
    cx, cy, _, w, h = layout_geo(i)
    return cx - w / 2, cx + w / 2, cy - h / 2, cy + h / 2


def find_probe(i):
    """배치 i 의 창 안이면서 다른 배치 창과는 겹치지 않는 점 중, 가장 여유 있는 점."""
    l, r, b, t = rect(i)
    cx, cy, k, _, _ = layout_geo(i)
    corner = ROUNDNESS * k * K
    best, best_score = None, -1
    steps = 60
    for ix in range(steps + 1):
        for iy in range(steps + 1):
            x = l + (r - l) * ix / steps
            y = b + (t - b) * iy / steps
            inner = min(x - l, r - x, y - b, t - y)
            # 둥근 모서리 근처는 투명할 수 있으니 피한다
            if (min(x - l, r - x) < corner) and (min(y - b, t - y) < corner):
                inner = min(inner, corner * 0.3)
            outer = float("inf")
            for j in range(len(LAYOUTS)):
                if j == i:
                    continue
                l2, r2, b2, t2 = rect(j)
                dx = max(l2 - x, 0, x - r2)
                dy = max(b2 - y, 0, y - t2)
                outer = min(outer, math.hypot(dx, dy))
            score = min(inner, outer)
            if score > best_score:
                best, best_score = (x, y), score
    margin = PROBE_CROP / 2 + 8
    if best_score < margin:
        sys.exit(f"[오류] '{LAYOUTS[i][0]}' 배치에 다른 배치와 겹치지 않는 탐침 자리가 부족합니다 "
                 f"(여유 {best_score:.1f}px < {margin}px). 배치 좌표를 조정하세요.")
    return best, best_score


# ─────────────────────────── 효과 (.moef) ───────────────────────────
GAMMA_UUID = "9F2DAEB8-1875-4E0E-B62F-DF1E28C1999B"  # Motion '감마' 필터 (PAEGamma)

def build_effect():
    F = Factories(["Project", "Widget", "Image", "Shape", "Rig", "Rig Widget",
                   "Rig Behavior", "ChPosition", "ChScale", "ChDouble", "Channel", "ProPlugin Filter"])
    ids = Ids()
    ids.project = ids()
    rig_id, widget_id, mirror_widget_id = ids(), ids(), ids()
    group_id, shape_id, src_id = ids(), ids(), ids()
    person_id, mirror_id = ids(), ids()
    footage_id, clip_id = ids(), ids()
    rb_pos_id, rb_scale_id, rb_mirror_id = ids(), ids(), ids()
    exposure_id = ids()  # 기존 노드 id 가 밀리지 않도록 맨 뒤에 받는다

    n = len(LAYOUTS)
    widget = popup_widget(F, "배치", widget_id, [lb for lb, *_ in LAYOUTS], DEFAULT_LAYOUT)
    mirror_widget = checkbox_widget(F, "좌우 반전", mirror_widget_id, MIRROR_DEFAULT)
    rig = rig_node(F, rig_id, [widget, mirror_widget])

    pos_vals = [(layout_geo(i)[0], layout_geo(i)[1]) for i in range(n)]
    scale_vals = [(layout_geo(i)[2], layout_geo(i)[2]) for i in range(n)]

    # 둥근 창 (스텐실 알파): 그룹 원점 기준, '크게' 크기. 창 안쪽만 남긴다.
    shape = shape_node(F, "둥근 창", shape_id, LARGE_W * K, LARGE_H * K, ROUNDNESS * K, STENCIL_ALPHA)

    # 강사 영상 (Effect Source) + 노출(감마) 필터. 창 안의 강사 영상에만 걸린다.
    # 감마 필터 형식은 애플 템플릿(Heat Wave, X-Ray, Bleach Bypass)과 같다. 파라미터 'Gamma' 는 id 1.
    gamma_params = [] if EXPOSURE_DEFAULT == 1.0 else [P("Gamma", 1, 8606711824, 1, EXPOSURE_DEFAULT)]
    exposure = fxplug_filter(F, exposure_id, "노출", GAMMA_UUID, 0, params=gamma_params, plugin_name="PAEGamma")
    source = effect_source(F, src_id, clip_id, filters=[exposure])

    # 그룹 3겹: PIP(배치 리그) > 인물(위치·크기, 퍼블리시) > 반전(체크박스 리그) > Effect Source
    # 반전을 가장 안쪽에 두어야 반전을 켜도 '인물 위치' X 를 늘리면 화면에서 오른쪽으로 간다.
    mirror_vals = [(1, 1), (-1, 1)]
    m = MIRROR_DEFAULT
    mirror = group("반전", mirror_id, [source],
                   props=[transform(scale=mirror_vals[m])],
                   behaviors=[
                       vector_rig(F, rb_mirror_id, "Rig Behavior 2", "./1/100/105",
                                  4, "Scale", mirror_vals, mirror_id, mirror_widget_id),
                   ])
    person = group("인물", person_id, [mirror],
                   props=[transform(scale=(FRAMING_SCALE, FRAMING_SCALE))])

    d = DEFAULT_LAYOUT
    layer = group("PIP", group_id, [shape, person],
                  props=[transform(pos=pos_vals[d], scale=scale_vals[d])],
                  behaviors=[
                      vector_rig(F, rb_pos_id, "Rig Behavior", "./1/100/101",
                                 "3.4028234663852886e+38", "Position", pos_vals,
                                 group_id, widget_id),
                      vector_rig(F, rb_scale_id, "Rig Behavior 1", "./1/100/105",
                                 4, "Scale", scale_vals, group_id, widget_id),
                  ])

    targets = [
        E("target", {"object": widget_id, "channel": "./2/100", "name": "배치"}),
        E("target", {"object": mirror_widget_id, "channel": "./2/100", "name": "좌우 반전"}),
        E("target", {"object": person_id, "channel": "./1/100/101", "name": "인물 위치"}),
        E("target", {"object": person_id, "channel": "./1/100/105", "name": "인물 크기"}),
        E("target", {"object": exposure_id, "channel": "./1", "name": "노출"}),
        E("target", {"object": shape_id, "channel": "./2/353/144", "name": "모서리 둥글기"}),
    ]
    fc = footage(footage_id, [media_clip("Effect Source", clip_id, "Drop Zone.tiff", 1200)])
    return document(F, [project_node(F, ids), rig, layer, fc], targets)


# ─────────────────────────── 트랜지션 (.motr) ───────────────────────────
def build_transition():
    F = Factories(["Project", "Widget", "Image", "Shape", "Clone Layer", "Channel",
                   "Rig", "Rig Widget", "Rig Behavior", "ChOpacity"])
    ids = Ids()
    ids.project = ids()
    rig_id, widget_id = ids(), ids()
    root_id = ids()
    src_a, src_b = ids(), ids()
    footage_id, clip_a, clip_b = ids(), ids(), ids()

    n = len(LAYOUTS)
    probes = [find_probe(i) for i in range(n)]

    def clone(name, source_id, props, tail=()):
        return clone_layer(F, ids(), name, source_id, props, tail)

    def probe(label, source_id, i):
        (px, py), _ = probes[i]
        c = PROBE_CROP
        left = px + OUT_W / 2 - c / 2
        right = OUT_W / 2 - (px + c / 2)
        bottom = py + OUT_H / 2 - c / 2
        top = OUT_H / 2 - (py + c / 2)
        s = PROBE_SCALE
        return clone(label, source_id, [
            transform(pos=(-s * px, -s * py), scale=(s, s)),
            blending_layer(SILHOUETTE_ALPHA),
            crop(left, right, bottom, top),
        ])

    def judge(label, side, source_id, i):
        """판정 그룹: 탐침 자리가 비었으면 화면 전체가 불투명, 차 있으면 텅 빈 그룹이 된다.
        이 그룹을 실루엣 알파로 얹어 아래 영상을 지운다.
        렌더러가 빈 레이어를 건너뛰어도 결과가 같도록 스텐실 대신 실루엣을 두 번 쓴다.
        (스텐실은 탐침이 비었을 때 건너뛰어지면 아무것도 가리지 못한다 — 실제로 9개 조합이 다 보였다)"""
        return group(f"판정 {side} · {label}", ids(), [
            probe(f"탐침 {side} · {label}", source_id, i),
            shape_node(F, "바탕", ids(), OUT_W, OUT_H, 0, 0),
        ], blend=SILHOUETTE_ALPHA)

    def premium(x, y, use_b):
        """고급 움직임: 용수철 진행도 s(u), 가운데 쪽으로 휘는 경로, 들었다 놓기(살짝 커짐 + 그림자).
        반환: (변형 파라미터, 드롭 섀도 파라미터)"""
        pr = PREMIUM
        cx0, cy0, k0, _, _ = layout_geo(x)
        cx1, cy1, k1, _, _ = layout_geo(y)
        cxn, cyn, kn = (cx1, cy1, k1) if use_b else (cx0, cy0, k0)
        dx, dy = cx1 - cx0, cy1 - cy0
        dist = math.hypot(dx, dy)
        # 이동 방향에 수직이면서 왼쪽(화면 가운데)을 향하는 방향. 되돌아갈 때도 같은 곡선을 그린다.
        nx, ny = -dy / dist, dx / dist
        if nx > 1e-9 or (abs(nx) <= 1e-9 and ny < 0):
            nx, ny = -nx, -ny
        bulge = pr["arc"] * dist

        def S(u):
            return spring_s(u, *pr["spring"])

        def lift(u):  # 0(바닥) ~ 1(가장 높이)
            return max(0.0, math.sin(math.pi * min(1.0, S(u))))

        def geo(u):
            s_ = S(u)
            b_ = bulge * math.sin(math.pi * s_)
            cx = cx0 + s_ * dx + b_ * nx
            cy = cy0 + s_ * dy + b_ * ny
            a_ = (k0 + s_ * (k1 - k0)) * (1 + pr["lift"] * lift(u)) / kn
            return cx - a_ * cxn, cy - a_ * cyn, a_

        def track(i, default):
            return [sampled_curve(lambda u: geo(u)[i], default)]

        tr = P("Transform", 100, 8589938704, children=[
            P("Position", 101, 8589938704, children=[
                fold(11),
                P("X", 1, 8606711824, children=track(0, 0)),
                P("Y", 2, 8606711824, children=track(1, 0)),
                P("Z", 3, 8606711824, 0, 0),
            ]),
            P("Scale", 105, 8589938704, children=[
                fold(11),
                P("X", 1, 8606711824, children=track(2, 1)),
                P("Y", 2, 8606711824, children=track(2, 1)),
                P("Z", 3, 8589934610, 1, 1),
            ]),
        ])
        o = pr["shadow_opacity"]
        (b0, b1), (d0, d1) = pr["shadow_blur"], pr["shadow_distance"]
        shadow = P("Drop Shadow", 208, 8589940752, children=[
            fold(131083),
            P("Opacity", 211, 8606711824, children=[sampled_curve(lambda u: o * lift(u), 0.75)]),
            P("Blur", 213, 8606711824, children=[
                sampled_curve(lambda u: K * (b0 + (b1 - b0) * lift(u)), 5)]),
            P("Distance", 212, 8606711824, children=[
                sampled_curve(lambda u: K * (d0 + (d1 - d0) * lift(u)), 5)]),
            P("Angle", 214, 8606711824, 5.497787143782138, 1.5 * math.pi),  # 바로 아래로
            P("Fixed Source", 232, 8606711824, 0, 1),
        ])
        return tr, shadow

    def pairs_for(ease):
        pairs = []
        for x in range(n):
            for y in range(n):
                cx0, cy0, k0, _, _ = layout_geo(x)
                cx1, cy1, k1, _, _ = layout_geo(y)
                # 원래 크기가 더 큰 쪽을 보여준다 (작은 쪽을 키우면 흐려진다). 같으면 A.
                use_b = k1 > k0 + 1e-9
                src = src_b if use_b else src_a
                cxn, cyn, kn = (cx1, cy1, k1) if use_b else (cx0, cy0, k0)
                a0, a1 = k0 / kn, k1 / kn
                p0 = (cx0 - a0 * cxn, cy0 - a0 * cyn)
                p1 = (cx1 - a1 * cxn, cy1 - a1 * cyn)
                if ease[0] == "premium" and x != y:
                    tr, shadow = premium(x, y, use_b)
                    content = clone("영상 B" if use_b else "영상 A", src, [tr], [shadow])
                else:
                    content = clone("영상 B" if use_b else "영상 A", src, [
                        transform(pos=p0, scale=(a0, a0), pos1=p1, scale1=(a1, a1), ease=ease),
                    ])
                name = f"{LAYOUTS[x][0]} → {LAYOUTS[y][0]}"
                pairs.append(group(name, ids(), [
                    judge(LAYOUTS[y][0], "B", src_b, y),  # 위
                    judge(LAYOUTS[x][0], "A", src_a, x),
                    content,                                        # 아래
                ]))
        return pairs

    # 움직임마다 9개 조합 그룹을 따로 두고, 팝업 리그가 고른 움직임의 그룹만 불투명도 1로 둔다.
    styles = []
    for i, (label, ease) in enumerate(MOTION_STYLES):
        gid = ids()
        styles.append(group(f"움직임 · {label}", gid, pairs_for(ease),
                            opacity=1 if i == DEFAULT_STYLE else 0,
                            behaviors=[opacity_rig(F, ids(), f"Rig Behavior {i}", gid, widget_id,
                                                   [1 if j == i else 0 for j in range(len(MOTION_STYLES))])]))
    rig = rig_node(F, rig_id, [popup_widget(F, "움직임", widget_id,
                                            [lb for lb, _ in MOTION_STYLES], DEFAULT_STYLE)])
    root = group(TRANSITION_NAME, root_id, styles + [
        transition_source(F, "Transition B", src_b, clip_b, 2),
        transition_source(F, "Transition A", src_a, clip_a, 1),
    ])
    fc = footage(footage_id, [
        media_clip("Transition A", clip_a, "Drop Zone Transition A.tiff", 600),
        media_clip("Transition B", clip_b, "Drop Zone Transition B.tiff", 600),
    ])
    targets = [E("target", {"object": widget_id, "channel": "./2/100", "name": "움직임"})]
    return document(F, [project_node(F, ids), rig, root, fc], targets), probes


# ─────────────────────────── 저장 ───────────────────────────
def main():
    out = out_dir_from_argv(os.path.join(REPO, "build"))
    print(f"효과     : {write_template(out, CATEGORY, EFFECT_NAME, 'moef', build_effect())}")
    text, probes = build_transition()
    print(f"트랜지션 : {write_template(out, CATEGORY, TRANSITION_NAME, 'motr', text)}")
    print("탐침 위치 (1080 기준 좌표, 여유):")
    for (name, *_), ((x, y), score) in zip(LAYOUTS, probes):
        print(f"  {name:8s} ({x / K:7.1f}, {y / K:7.1f})  여유 {score / K:5.1f}px")


if __name__ == "__main__":
    main()
