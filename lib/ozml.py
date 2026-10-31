# -*- coding: utf-8 -*-
"""
Motion 템플릿(OZML) 공용 도구

팩 생성기(packs/*/generate.py)가 `from ozml import *` 로 가져다 쓴다.
여기 있는 형식은 모두 애플 번들 템플릿에서 확인한 것이다. 근거와 함정은 docs/ozml-notes.md 참고.

캔버스 기준 (모든 팩 공통)
  - 템플릿 크기 3840x2160, 원점은 화면 중앙, Y 는 위쪽이 +
  - 59.94fps, 300프레임. FCP 가 실제 길이에 맞춰 늘이거나 줄인다.
  - 팩 설정은 1920x1080 기준 좌표로 쓰고 K 를 곱해 템플릿 좌표로 바꾼다.

공용 함수를 고치면 모든 팩의 결과물이 바뀐다. 고치기 전후 결과물을 비교할 것 (CLAUDE.md).
"""

import math
import os
import signal
import sys

# ─────────────────────────── 캔버스 / 시간 ───────────────────────────
OUT_W, OUT_H = 3840, 2160
K = OUT_W / 1920.0            # 1080 기준 좌표 → 템플릿(4K) 좌표

TS = 120000                   # 시간 단위: "값 120000 1 0"
FRAME = 2002                  # 59.94fps 한 프레임
NFRAMES = 300
LAST = (NFRAMES - 1) * FRAME
DUR_SEC = LAST / TS
ZERO = "0 1 1 0"
SAMPLE_KEYS = 31              # 표본 곡선(용수철 등)을 나눠 찍는 키프레임 수


def T(units):
    return f"{units} {TS} 1 0"


END = T(LAST)
NEG = T(-FRAME)               # 위젯·프로젝트 노드의 out 값


def guard(seconds=30):
    """생성은 1초 안에 끝난다. 혹시 멈추면 스스로 종료한다."""
    signal.signal(signal.SIGALRM, lambda *_: sys.exit(f"[timeout] {seconds}초 초과로 종료"))
    signal.alarm(seconds)


# ─────────────────────────── 팩토리 UUID ───────────────────────────
UUID = {
    "Project": "7d468273c013498e9806a0d7bc32fddf",
    "Widget": "65cb4dc9d4504fa281921f5f751fba06",       # 프로젝트 화면비 위젯
    "Image": "66fc0d6af6a911d6a7a7000393670732",
    "Shape": "712462a4323911d78f8400039389b702",
    "Clone Layer": "84414060b0fd11d99bb5000a957d5fce",
    "Rig": "402246385249454b90e08b2ee1b6bf06",
    "Rig Widget": "e35c74f01d5042f6b468eb530169bfb7",
    "Rig Behavior": "dd0036f96c9e4bfdadb82f71fbf5c9d8",
    "ChPosition": "98458b1125bc499897c399d6d1240f52",
    "ChScale": "11615b89cbc0483fb92e95eb0c80e59c",
    "ChDouble": "fdc1944b229111d7b1c300039389b702",
    "Channel": "46c844a813d311d8a438000a95af9f7e",
    "ChOpacity": "27f3ee8b229211d7925a00039389b702",
}
GROUP_UUID = "ee6b4918387a11d7a02100039375d2ba"  # 그룹(layer) 팩토리, 리그 대상 지정에만 쓴다

# 혼합 모드 번호. 25~29 는 Motion 목록 순서대로 스텐실 알파, 스텐실 루마, 실루엣 알파,
# 실루엣 루마, 뒤(Behind). 근거: 애플 템플릿의 'Color Solid Behind' 가 29 이고,
# 27 을 넣었더니 FCP 에서 창 모양으로 구멍이 뚫렸다(= 실루엣 알파).
STENCIL_ALPHA = 25
SILHOUETTE_ALPHA = 27
DESC = {
    "Rig Widget": "Widget", "ChPosition": "Channel", "ChScale": "Channel",
    "ChDouble": "Channel", "Channel": "Channel", "ChOpacity": "Channel",
}


# ─────────────────────────── XML 도우미 ───────────────────────────
def fmt(v):
    if isinstance(v, str):
        return v
    if isinstance(v, bool):
        return "1" if v else "0"
    f = float(v)
    if f == int(f) and abs(f) < 1e15:
        return str(int(f))
    s = f"{f:.9f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def esc(s):
    return (str(s).replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;").replace('"', "&quot;"))


class E:
    """간단한 XML 요소. 속성 순서를 지킨다."""

    def __init__(self, tag, attrs=None, children=None, text=None):
        self.tag = tag
        self.attrs = attrs or {}
        self.children = [c for c in (children or []) if c is not None]
        self.text = text

    def render(self, depth=0):
        pad = "\t" * depth
        a = "".join(f' {k}="{esc(fmt(v))}"' for k, v in self.attrs.items())
        if self.text is not None:
            return f"{pad}<{self.tag}{a}>{esc(fmt(self.text))}</{self.tag}>\n"
        if not self.children:
            return f"{pad}<{self.tag}{a}/>\n"
        inner = "".join(c.render(depth + 1) for c in self.children)
        return f"{pad}<{self.tag}{a}>\n{inner}{pad}</{self.tag}>\n"


def V(tag, value):
    """<tag>value</tag>"""
    return E(tag, text=value)


def P(name, pid, flags, default=None, value=None, children=None):
    attrs = {"name": name, "id": pid, "flags": flags}
    if default is not None:
        attrs["default"] = default
    if value is not None:
        attrs["value"] = value
    return E("parameter", attrs, children)


def fold(n):
    return V("foldFlags", n)


def timing(out=END):
    return E("timing", {"in": ZERO, "out": out, "offset": ZERO})


class Ids:
    """노드 id 발급기. 호출 순서가 바뀌면 결과 파일의 id 도 바뀐다."""

    def __init__(self, start=10000):
        self.n = start

    def __call__(self):
        self.n += 1
        return self.n


class Factories:
    """파일마다 쓰는 팩토리를 번호로 등록한다."""

    def __init__(self, names):
        self.order = sorted(names, key=lambda n: UUID[n])
        self.num = {n: i + 1 for i, n in enumerate(self.order)}

    def __getitem__(self, name):
        return self.num[name]

    def elements(self):
        out = []
        for n in self.order:
            out.append(E("factory", {"id": self.num[n], "uuid": UUID[n]}, [
                V("description", DESC.get(n, n)),
                V("manufacturer", "Apple"),
                V("version", 1),
            ]))
        return out


# ─────────────────────────── 키프레임 곡선 ───────────────────────────
def spring(u, zeta, omega):
    """감쇠 용수철의 계단 응답 s(u)와 기울기 s'(u). u 는 0~1 정규화 시간."""
    sigma = zeta * omega
    wd = omega * math.sqrt(1 - zeta * zeta)
    env = math.exp(-sigma * u)
    s = 1 - env * (math.cos(wd * u) + sigma / wd * math.sin(wd * u))
    ds = env * math.sin(wd * u) * omega * omega / wd
    return s, ds


def spring_s(u, zeta, omega):
    """용수철 진행도. 끝(u=1)에서 정확히 1이 되도록 맞춘다."""
    return spring(u, zeta, omega)[0] / spring(1, zeta, omega)[0]


def sampled_curve(f, default):
    """f(u) (u: 0~1 정규화 시간)를 고르게 나눈 프레임마다 찍고,
    기울기를 맞춘 접선(이웃 키까지 거리의 1/3 핸들)으로 매끄럽게 잇는다."""
    frames = sorted({round(i * (NFRAMES - 1) / (SAMPLE_KEYS - 1)) for i in range(SAMPLE_KEYS)})
    eps = 1e-4
    pts = []
    for fr in frames:
        u = fr / (NFRAMES - 1)
        lo, hi = max(0.0, u - eps), min(1.0, u + eps)
        pts.append((fr * FRAME / TS, f(u), (f(hi) - f(lo)) / (hi - lo) / DUR_SEC))  # (초, 값, 초당 기울기)
    keys = []
    for i, (t, v, d) in enumerate(pts):
        ch = [V("time", T(frames[i] * FRAME)), V("value", v)]
        if i > 0:
            h = (t - pts[i - 1][0]) / 3
            ch += [V("inputTangentTime", -h), V("inputTangentValue", -d * h)]
        if i < len(pts) - 1:
            h = (pts[i + 1][0] - t) / 3
            ch += [V("outputTangentTime", h), V("outputTangentValue", d * h)]
        keys.append(E("keypoint", {"flags": 0}, ch))
    return E("curve", {"type": 1, "default": default, "value": pts[0][1]},
             [V("numberOfKeypoints", len(keys))] + keys)


def curve(v0, v1, default, ease):
    """v0 → v1 키프레임 곡선.
    ease = ("bezier", (x1, y1, x2, y2))  CSS cubic-bezier 와 같은 뜻
         | ("spring", (감쇠비, 진동수))   목표를 살짝 지나쳤다 돌아오는 용수철
    keypoint 에 interpolation 속성을 넣지 않아야 베지어가 된다 (1 은 선형이라 접선이 무시된다)."""
    kind, prm = ease
    dv = v1 - v0
    if kind == "bezier":
        x1, y1, x2, y2 = prm
        keys = [
            E("keypoint", {"flags": 0}, [
                V("time", ZERO), V("value", v0),
                V("outputTangentTime", DUR_SEC * x1), V("outputTangentValue", dv * y1),
            ]),
            E("keypoint", {"flags": 0}, [
                V("time", END), V("value", v1),
                V("inputTangentTime", -DUR_SEC * (1 - x2)), V("inputTangentValue", -dv * (1 - y2)),
            ]),
        ]
    else:
        # 용수철: 표본 곡선으로 찍는다
        return sampled_curve(lambda u: v0 + dv * spring_s(u, *prm), default)
    return E("curve", {"type": 1, "default": default, "value": v0},
             [V("numberOfKeypoints", len(keys))] + keys)


def chan(name, pid, flags, default, v0, v1=None, ease=None):
    """값이 변하면 키프레임, 같으면 고정값."""
    if v1 is None or abs(v1 - v0) < 1e-9:
        return P(name, pid, flags, default, v0)
    return P(name, pid, flags, children=[curve(v0, v1, default, ease)])


# ─────────────────────────── 파라미터 묶음 ───────────────────────────
def transform(pos=(0, 0), scale=(1, 1), pos1=None, scale1=None, ease=None):
    pos1 = pos1 or pos
    scale1 = scale1 or scale
    return P("Transform", 100, 8589938704, children=[
        P("Position", 101, 8589938704, children=[
            fold(11),
            chan("X", 1, 8606711824, 0, pos[0], pos1[0], ease),
            chan("Y", 2, 8606711824, 0, pos[1], pos1[1], ease),
            P("Z", 3, 8606711824, 0, 0),
        ]),
        P("Scale", 105, 8589938704, children=[
            fold(11),
            chan("X", 1, 8606711824, 1, scale[0], scale1[0], ease),
            chan("Y", 2, 8606711824, 1, scale[1], scale1[1], ease),
            P("Z", 3, 8589934610, 1, 1),
        ]),
    ])


def blending_layer(mode=0):
    return P("Blending", 200, 8589938704, children=[
        P("Blend Mode", 203, 8606777360, 0, mode),
    ])


def blending_group(mode=0, opacity=None):
    # 그룹 기본값(34, 통과)이면 안쪽 스텐실이 그룹 밖 레이어까지 잘라낸다. 통과가 아닌 값으로 고정.
    return P("Blending", 200, 8589938704, children=[
        None if opacity is None else P("Opacity", 202, 8606711824, 1, opacity),
        P("Blend Mode", 203, 8606779408, 34, mode),
    ])


def lighting_etc():
    return [
        P("Lighting", 230, 8589938706, children=[fold(15)]),
        P("Shadows", 234, 8589938706, children=[fold(15)]),
        P("Reflection", 223, 8589971474, children=[fold(131087)]),
    ]


def crop(left, right, bottom, top):
    return P("Crop", 216, 8589938704, children=[
        fold(131083),
        P("Left", 1, 8606711824, 0, left),
        P("Right", 2, 8606711824, 0, right),
        P("Bottom", 3, 8606711824, 0, bottom),
        P("Top", 4, 8606711824, 0, top),
    ])


def group_object():
    return P("Object", 2, 8589938704, children=[
        P("Fixed Width", 302, 12884901908, OUT_W, OUT_W),
        P("Fixed Height", 303, 12884901908, OUT_H, OUT_H),
        P("Flatten", 311, 8589934610, 0, 0),
        P("Layer Order", 305, 8589934610, 0, 0),
        P("Aperture Width", 312, 12884901906, OUT_W, OUT_W),
        P("Aperture Height", 313, 12884901906, OUT_H, OUT_H),
    ])


# ─────────────────────────── 레이어 ───────────────────────────
def group(name, gid, children, props=None, behaviors=None, enabled=True, blend=0, opacity=None):
    """그룹. children 은 앞쪽이 화면에서 위에 놓인다."""
    props = props or []
    return E("layer", {"name": name, "id": gid}, children + [
        V("aspectRatio", 1),
        V("flags", 0),
        timing(),
        V("foldFlags", 0),
        V("baseFlags", 524304),
        None if enabled else V("enabled", 0),
        P("Properties", 1, 8589938704, children=props + [blending_group(blend, opacity)] + lighting_etc()),
        group_object(),
    ] + (behaviors or []))


def shape_node(F, name, sid, w, h, roundness, blend):
    """원점 중심 사각형 도형 (흰색 채움, 외곽선 없음)"""
    return E("scenenode", {"name": name, "id": sid, "factoryID": F["Shape"], "version": 5}, [
        V("isShapeStyle", 0), V("aspectRatio", 1), V("flags", 0), timing(),
        V("foldFlags", 0), V("baseFlags", 524304),
        P("Properties", 1, 8589938704, children=[
            transform(),
            blending_layer(blend),
            P("Lighting", 230, 8589938706, children=[fold(15)]),
            P("Shadows", 234, 8589938706, children=[fold(15)]),
        ]),
        P("Object", 2, 8589938704, children=[
            P("Shape", 353, 8589938704, children=[
                P("Animation", 117, 8589934610, 0, 0, children=[
                    E("curve_X"), E("curve_Y"), V("closed", 0)]),
                P("Shape Type", 100, 12884967442, 5, 5),  # 5 = 사각형
                P("Closed", 116, 8590000146, 0, 1),
                P("Roundness", 144, 8606711824, 0, roundness),
                P("Fill", 113, 8589938704, children=[
                    fold(131072),
                    P("Fill Color", 111, 12884906000, children=[
                        fold(15),
                        P("Red", 1, 8606711824, 1, 1),
                        P("Green", 2, 8606711824, 1, 1),
                        P("Blue", 3, 8606711824, 1, 1),
                    ]),
                ]),
                P("Outline", 108, 8589971472, children=[fold(131072)]),
                P("Size", 160, 8589938704, children=[
                    fold(8388619),
                    P("Width", 1, 12901679120, w, w),
                    P("Height", 2, 12901679120, h, h),
                ]),
                P("Completed", 157, 8589934610, 0, 1),
            ]),
        ]),
    ])


def clone_layer(F, cid, name, source_id, props, tail=()):
    """클론 레이어. props 는 변형·혼합·자르기 등, tail 은 Lighting 묶음 뒤에 붙는 것(드롭 섀도 등)."""
    return E("scenenode", {"name": name, "id": cid, "factoryID": F["Clone Layer"], "version": 5}, [
        V("aspectRatio", 1), V("flags", 0), timing(),
        V("foldFlags", 0), V("baseFlags", 524368),
        P("Properties", 1, 8589938704, children=props + lighting_etc() + list(tail)),
        P("Object", 2, 8589938704, children=[
            P(name, 1, 8589938704, children=[
                P("Source", 300, 77326254096, 0, source_id),
            ]),
        ]),
    ])


def effect_source(F, sid, clip_id, props=None):
    """효과(.moef)에서 FCP 클립이 들어오는 자리. footage 에 'Drop Zone.tiff' 클립이 있어야 한다."""
    return E("scenenode", {"name": "Effect Source", "id": sid, "factoryID": F["Image"], "version": 5}, [
        V("validTracks", 1), V("aspectRatio", 1), V("flags", 0), timing(),
        V("foldFlags", 16384), V("baseFlags", 524304),
        P("Properties", 1, 8589938704, children=[
            transform(),
        ] + (props or []) + lighting_etc() + [
            P("Media", 324, 8589938704, children=[
                fold(4),
                P("Source Media", 300, 81621221392, clip_id, clip_id),
                P("Source Media", 325, 8590000146),
            ]),
            P("Page Number", 301, 8589934610, 1, 1),
            P("Retime Value", 304, 8590066066, 1, 1),
            P("Retime Value Cache", 319, 8590065810, 1, 1),
        ]),
        P("Object", 2, 8589938704, children=[
            P("Drop Zone", 311, 8589934738, 0, 1),
            P("Type", 321, 8590000146, 0, 3),  # 3 = 효과 원본
            P("Pan", 326, 77309415442, children=[fold(15)]),
            P("Scale", 327, 77309415442, children=[fold(15)]),
            P("Fill Opaque", 328, 8606711824, 0, 0),
            P("Fill Color", 329, 8589938704, children=[fold(15)]),
            P("Clear", 315, 8606777360, 0, 0),
            P("Width", 313, 8589934610, 1, OUT_W),
            P("Height", 314, 8589934610, 1, OUT_H),
        ]),
    ])


def transition_source(F, name, nid, clip_id, zone_type):
    """트랜지션(.motr)에서 앞(zone_type 1 = A)/뒤(2 = B) 클립이 들어오는 자리.
    원본은 숨기고(enabled 0) 클론으로만 쓴다 (애플 'Sequence Transition 01' 과 같은 방식)."""
    return E("scenenode", {"name": name, "id": nid, "factoryID": F["Image"], "version": 5}, [
        V("validTracks", 1), V("aspectRatio", 1), V("flags", 0), timing(),
        V("foldFlags", 16384), V("baseFlags", 524304),
        V("enabled", 0),  # 원본은 숨기고 클론으로만 쓴다
        P("Properties", 1, 8589938704, children=lighting_etc() + [
            P("Media", 324, 8589938704, children=[
                fold(4),
                P("Source Media", 300, 81621221392, clip_id, clip_id),
                P("Source Media", 325, 8590000146, children=[E("referencedObjectID")]),
            ]),
            P("Page Number", 301, 8589934610, 1, 1),
            P("Retime Value", 304, 8590066066, children=[
                E("curve", {"type": 1, "default": 1, "value": 1, "round": 0,
                            "retimingExtrapolation": 1}, [
                    V("numberOfKeypoints", 2),
                    E("keypoint", {"interpolation": 1, "flags": 32},
                      [V("time", ZERO), V("value", 1)]),
                    E("keypoint", {"interpolation": 1, "flags": 32},
                      [V("time", T(NFRAMES * FRAME)), V("value", NFRAMES + 1)]),
                ]),
            ]),
            P("Retime Value Cache", 319, 8590065810, children=[
                E("curve", {"type": 1, "default": 1, "value": 1}, [
                    V("numberOfKeypoints", 2),
                    E("keypoint", {"interpolation": 1, "flags": 160},
                      [V("time", ZERO), V("value", 1)]),
                    E("keypoint", {"interpolation": 1, "flags": 160},
                      [V("time", T(NFRAMES * FRAME)), V("value", NFRAMES + 1)]),
                ]),
            ]),
            P("Duration Cache", 320, 8589934610, 0, NFRAMES),
        ]),
        P("Object", 2, 8589938704, children=[
            P("Drop Zone", 311, 8589934738, 0, 1),
            P("Drop Zone Type", 321, 8590000146, 0, zone_type),  # 1 = A, 2 = B
            P("Pan", 326, 77309415440, children=[fold(15)]),
            P("Scale", 327, 77309415440, children=[fold(15)]),
            P("Fill Opaque", 328, 8606711824, 0, 0),
            P("Fill Color", 329, 8589938704, children=[fold(15)]),
            P("Clear", 315, 8606777360, 0, 0),
            P("Width", 313, 8589934610, 1, OUT_W),
            P("Height", 314, 8589934610, 1, OUT_H),
        ]),
    ])


# ─────────────────────────── 리그 (인스펙터 팝업·체크박스) ───────────────────────────
def popup_widget(F, name, wid, labels, default):
    """리그 팝업 위젯. 항목 tag = 순번, 스냅샷 id = 순번 + 1."""
    snap_ids = list(range(1, len(labels) + 1))
    return E("scenenode", {"name": name, "id": wid, "factoryID": F["Rig Widget"], "version": 5}, [
        V("affecting", 2),  # 2 = 팝업
    ] + [V("snapshot", sid) for sid in snap_ids] + [
        V("flags", 0), timing(NEG), V("foldFlags", 0), V("baseFlags", 16),
        P("Properties", 1, 8589938704),
        P("Object", 2, 8589938704, children=[
            P("Options", 103, 8589938688, children=[
                P("Initial Value", 106, 77326254096, 0, default),
            ]),
            # Hidden = Motion 이 마지막으로 편집하던 스냅샷 id. 그 스냅샷은 저장된 값 대신
            # 대상의 현재 값을 쓰므로, 대상에 저장한 기본 항목의 스냅샷을 가리켜야 한다.
            # (1 = '크게'로 두었더니 '크게'를 골라도 작게 · 아래 값이 쓰였다)
            P("Hidden", 102, 8606711824, 0, default + 1),
            P("Snapshots", 101, 8589938706, children=[
                P("Snapshots", sid, 8589938704, children=[
                    P("Value", 1, 8589934608, 0, sid - 1),
                    P("Interpolation", 2, 8590000144, 1, 1),
                ]) for sid in snap_ids
            ]),
            P(name, 100, 8606777360, default, default, children=[
                E("entry", {"name": lb, "tag": i}) for i, lb in enumerate(labels)
            ]),
        ]),
    ])


def checkbox_widget(F, name, wid, default):
    """리그 체크박스 위젯 (애플 'Negative' 효과의 체크박스와 같은 형식). 스냅샷 1 = 꺼짐, 2 = 켜짐"""
    return E("scenenode", {"name": name, "id": wid, "factoryID": F["Rig Widget"], "version": 5}, [
        V("affecting", 1),  # 1 = 체크박스
        V("snapshot", 1), V("snapshot", 2),
        V("flags", 0), timing(NEG), V("foldFlags", 0), V("baseFlags", 16),
        P("Properties", 1, 8589938704),
        P("Object", 2, 8589938704, children=[
            P("Options", 103, 8589938688),
            P("Hidden", 102, 8606711824, 0, default + 1),  # 팝업과 같은 이유
            P("Snapshots", 101, 8589938706, children=[
                P("Snapshots", s, 8589938704, children=[
                    P("Value", 1, 8589934608, 0, s - 1),
                    P("Interpolation", 2, 8590000144, 1, 1),
                ]) for s in (1, 2)
            ]),
            P(name, 100, 8606711824, 0, default),
        ]),
    ])


def rig_node(F, rig_id, widgets):
    return E("scenenode", {"name": "Rig", "id": rig_id, "factoryID": F["Rig"], "version": 5}, widgets + [
        V("flags", 0), timing(NEG), V("foldFlags", 0), V("baseFlags", 16),
        P("Properties", 1, 8589938704),
        P("Object", 2, 8589938704),
    ])


def vector_rig(F, bid, name, channel, slider_range, kind, values, target, wid):
    """위젯 항목마다 대상 그룹의 위치(kind="Position") 또는 배율(kind="Scale")을 바꾸는 리그 동작.
    values[k] = 스냅샷 k+1 일 때의 (X, Y) 값. 대상 그룹에 저장한 값은 위젯 기본 항목의 값과 같아야 한다."""
    def snap_vec(sid, vals):
        if kind == "Position":
            fac, flags, z_flags, dflt = F["ChPosition"], [8606711824] * 2, 8606711824, 0
        else:
            fac, flags, z_flags, dflt = F["ChScale"], [8606711824] * 2, 8589934610, 1
        subs = []
        for (axis, aid), v, fl in zip((("X", 1), ("Y", 2)), vals, flags):
            subs.append(E("parameter", {"name": axis, "id": aid, "factoryID": F["ChDouble"]}, [
                V("flags", fl), E("curve", {"type": 1, "default": dflt, "value": v}),
            ]))
        subs.append(E("parameter", {"name": "Z", "id": 3, "factoryID": F["ChDouble"]}, [
            V("flags", z_flags), E("curve", {"type": 1, "default": dflt, "value": dflt}),
        ]))
        return E("parameter", {"name": kind, "id": sid, "factoryID": fac},
                 [V("flags", 8589938704), V("foldFlags", 15)] + subs)

    return E("behavior", {"name": name, "id": bid, "factoryID": F["Rig Behavior"]}, [
        E("channelBehavior", {"affectingFactory": GROUP_UUID, "affectingChannel": channel,
                              "sliderRange": slider_range}),
        timing(NEG),
        V("baseFlags", 8589934610),
        P("Affecting Object (Hidden)", 199, 77309476882, 0, target),
        P("Widget", 200, 77309476880, 0, wid),
        E("parameter", {"name": "Snapshots", "id": 202, "flags": 8590004242}, [
            V("flags", 8590004242),
        ] + [snap_vec(k + 1, v) for k, v in enumerate(values)]),
    ])


def opacity_rig(F, bid, name, target, wid, values):
    """팝업 항목마다 대상 그룹의 불투명도를 values[항목 순번] 으로 바꾸는 리그 동작
    (애플 'Aged Film' 효과의 불투명도 리그와 같은 형식)"""
    return E("behavior", {"name": name, "id": bid, "factoryID": F["Rig Behavior"]}, [
        E("channelBehavior", {"affectingFactory": GROUP_UUID, "affectingChannel": "./1/200/202",
                              "sliderRange": 1}),
        timing(NEG),
        V("baseFlags", 8589934610),
        P("Affecting Object (Hidden)", 199, 77309476882, 0, target),
        P("Widget", 200, 77309476880, 0, wid),
        E("parameter", {"name": "Snapshots", "id": 202, "flags": 8590004242}, [V("flags", 8590004242)] + [
            E("parameter", {"name": "Opacity", "id": k + 1, "factoryID": F["ChOpacity"]}, [
                V("flags", 8606711824),
                E("curve", {"type": 1, "default": 1, "value": v}, [V("min", 0), V("max", 1)]),
            ]) for k, v in enumerate(values)
        ]),
    ])


# ─────────────────────────── 문서 ───────────────────────────
def project_node(F, ids):
    return E("scenenode", {"name": "Project", "id": ids.project, "factoryID": F["Project"], "version": 5}, [
        E("scenenode", {"name": "Widget", "id": ids(), "factoryID": F["Widget"], "version": 5}, [
            V("flags", 0), timing(NEG), V("foldFlags", 0), V("baseFlags", 16),
            P("Properties", 1, 8589938704),
            P("Object", 2, 8589938704, children=[
                P("Options", 103, 8589938688),
                P("Hidden", 102, 8589934608, 0, 1),
                P("Snapshots", 101, 8589938706),
                P("Widget", 100, 8589934608, 1.7777777777777777, 1.7777777777777777),
            ]),
        ]),
        V("flags", 0), timing(NEG), V("foldFlags", 0), V("baseFlags", 16),
        P("Properties", 1, 8589938704),
        P("Object", 2, 8589938704),
    ])


def scene_settings():
    s = [
        ("width", OUT_W), ("height", OUT_H), ("duration", NFRAMES),
        ("shouldOverrideFCDuration", 0), ("frameRate", 60), ("NTSC", 1),
        ("pixelAspectRatio", 1), ("workingGamut", 0), ("viewGamut", -1),
        ("optimizeForDisplay", 0),
    ]
    out = [V(k, v) for k, v in s]
    out.append(E("backgroundColor", {"red": 0, "green": 0, "blue": 0, "alpha": 1}))
    for k, v in [
        ("audioChannels", 2), ("audioBitsPerSample", 32), ("fieldRenderingMode", 0),
        ("motionBlurSamples", 8), ("motionBlurDuration", 1), ("sharpScaling", 0),
        ("startTimecode", 0),
    ]:
        out.append(V(k, v))
    out.append(E("presetPath"))
    for k, v in [
        ("backgroundMode", 0), ("reflectionRecursionLimit", 2), ("glyphOSCMode", 0),
        ("animateFlag", 0), ("parameterColorSpaceID", 3), ("savePreviewMovie", 0),
        ("Object3DEnvironments", 100), ("DRTSupport", 1), ("onHDRDisplay", 0),
    ]:
        out.append(V(k, v))
    return E("sceneSettings", children=out)


def media_clip(name, cid, path, missing):
    return E("clip", {"name": name, "id": cid}, [
        V("pathURL", path),
        V("missingWidth", missing), V("missingHeight", missing),
        V("missingDuration", "0.033333333333333333"),
        V("creationDuration", 1),
        E("mediaID"),
        V("flags", 0),
        E("timing", {"in": ZERO, "out": T(0), "offset": ZERO}),
        V("foldFlags", 0),
        V("baseFlags", 524304),
        P("Properties", 1, 8589938704),
        P("Object", 2, 8589938704, children=[
            P("Pixel Aspect Ratio", 104, 12884901888, 1, 1),
            P("Frame Rate", 107, 8589934592, 0, 30),
            P("Fixed Width", 114, 12884901888, missing, missing),
            P("Fixed Height", 115, 12884901888, missing, missing),
            P("Use Background Color", 116, 8589934594, 0, 0),
            P("Background Color", 117, 8589971458, children=[
                fold(15),
                P("Red", 1, 8589967376, 1, 1),
                P("Green", 2, 8589967376, 1, 1),
                P("Blue", 3, 8589967376, 1, 1),
            ]),
            P("Missing Is Still", 128, 8589934610, 0, 1),
        ]),
    ])


def footage(fid, clips):
    return E("footage", {"name": "Media Layer", "id": fid}, clips + [
        V("flags", 0), timing(NEG), V("foldFlags", 0), V("baseFlags", 524304),
        P("Properties", 1, 8589938704),
        P("Object", 2, 8589938704),
    ])


def document(F, scene_children, publish_targets):
    """publish_targets 순서가 FCP 인스펙터에 나오는 순서다."""
    head = '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE ozxmlscene>\n<ozml version="5.13">\n\n'
    head += E("displayversion", text="5.6.3.1").render(0) + "\n"
    for f in F.elements():
        head += f.render(0) + "\n"
    head += "<build></build>\n\n<description></description>\n\n"
    scene = E("scene", children=[
        scene_settings(),
        E("publishSettings", children=[V("version", 2)] + publish_targets),
        E("timeRange", {"offset": ZERO, "duration": T(NFRAMES * FRAME)}),
        E("playRange", {"offset": ZERO, "duration": T(NFRAMES * FRAME)}),
        V("flags", 1),
        V("audioTracks", 0),
        E("timemarkerset"),
        E("guideset"),
        E("curvesets", {"selected": 1}),
    ] + scene_children)
    return head + scene.render(0) + "</ozml>\n"


# ─────────────────────────── 저장 ───────────────────────────
KIND_DIRS = {
    "moef": "Effects.localized",
    "motr": "Transitions.localized",
    "moti": "Titles.localized",
    "motn": "Generators.localized",
}


def write_template(out_root, category, name, ext, text):
    """out_root/<종류>.localized/<카테고리>/<이름>/<이름>.<확장자> 로 저장한다."""
    d = os.path.join(out_root, KIND_DIRS[ext], category, name)
    os.makedirs(d, exist_ok=True)
    path = os.path.join(d, f"{name}.{ext}")
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    return path


def out_dir_from_argv(default):
    """`--out <폴더>` 인자를 읽는다. 없으면 default."""
    args = sys.argv[1:]
    if "--out" in args:
        i = args.index("--out")
        if i + 1 >= len(args):
            sys.exit("[오류] --out 뒤에 폴더가 필요합니다")
        return os.path.abspath(args[i + 1])
    return default
