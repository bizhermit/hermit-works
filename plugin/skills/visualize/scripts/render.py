"""<案件>.jsonの辞書（実施者が書いた項目とscriptの下の項目）から、案件ごとのHTMLと案件一覧のHTMLを作る。

外部の資源を読み込まず、CSSとSVGの図を埋め込んだ一つのファイルにする。
"""

from datetime import datetime
from html import escape

from metrics import no_launch_reason

DT_FMT = "%Y-%m-%d %H:%M:%S"
ROLE_LABEL = {"orchestrator": "統括", "worker": "実行者", "reviewer": "評価者", "overall": "全体レビュー"}
TOKEN_COLS = [("input", "入力"), ("output", "出力"), ("cache_creation", "キャッシュ作成"), ("cache_read", "キャッシュ読み取り")]

CSS = """
:root{--bg:#ffffff;--fg:#1f2328;--muted:#59636e;--line:#d1d9e0;--panel:#f6f8fa;--link:#3b6ea5;
--worker:#2f6fde;--reviewer:#c2571a;--overall:#7d3fc2;--ruling:#cf222e;--stall:#e9b949;--bar:#2f6fde;--na:#8c959f}
@media (prefers-color-scheme: dark){:root{--bg:#0d1117;--fg:#e6edf3;--muted:#9198a1;--line:#3d444d;--panel:#151b23;--link:#79a6dc;
--worker:#4d8ef7;--reviewer:#e3753a;--overall:#a371f7;--ruling:#ff7b72;--stall:#d29922;--bar:#4d8ef7;--na:#6e7681}}
body{background:var(--bg);color:var(--fg);font-family:system-ui,-apple-system,"Hiragino Sans","Noto Sans JP",sans-serif;
margin:0;padding:16px;line-height:1.6}
main{max-width:1200px;margin:0 auto}
a{color:var(--link)}
h1{font-size:1.5rem;margin:.2em 0 .6em}h2{font-size:1.25rem;border-bottom:1px solid var(--line);padding-bottom:.2em;margin-top:2em}
h3{font-size:1.05rem;margin-top:1.4em}
details.section{margin-top:2em}
details.section>summary{font-size:1.25rem;font-weight:bold;border-bottom:1px solid var(--line);padding-bottom:.2em;cursor:pointer}
table{border-collapse:collapse;margin:.5em 0;font-size:.9rem;display:block;overflow-x:auto;max-width:100%}
th,td{border:1px solid var(--line);padding:4px 8px;vertical-align:top;text-align:left}
th{background:var(--panel)}td.num,th.num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
.muted{color:var(--muted)}.na{color:var(--na)}.note{background:var(--panel);border-left:4px solid var(--stall);padding:6px 10px}
.pre{white-space:pre-wrap}
svg{max-width:100%;height:auto;font-family:inherit}
svg text{fill:var(--fg);font-size:12px}svg .muted{fill:var(--muted)}svg a text{fill:var(--link)}
svg .grid{stroke:var(--line);stroke-width:1}
svg .worker{fill:var(--worker)}svg .reviewer{fill:var(--reviewer)}svg .overall{fill:var(--overall)}
svg .ruling{stroke:var(--ruling);stroke-width:1.5}svg .ruling-mark{fill:var(--ruling)}
svg .bar{fill:var(--bar)}
.legend span{display:inline-block;margin-right:1em}.sw{display:inline-block;width:12px;height:12px;vertical-align:middle;margin-right:4px}
nav a{margin-right:1em}
"""


def e(s):
    return escape("" if s is None else str(s))


def na(reason):
    return '<span class="na">不明（理由：%s）</span>' % e(reason)


def num(v):
    return "{:,}".format(v)


def usd(v):
    return "$%.4f" % v


def hms(seconds):
    if seconds is None:
        return None
    s = int(seconds)
    h, rem = divmod(s, 3600)
    m, s = divmod(rem, 60)
    if h:
        return "%d時間%02d分%02d秒" % (h, m, s)
    if m:
        return "%d分%02d秒" % (m, s)
    return "%d秒" % s


def page(title, body, css=CSS):
    return (
        '<!DOCTYPE html>\n<html lang="ja">\n<head>\n<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        "<title>%s</title>\n<style>%s</style>\n</head>\n<body>\n<main>\n%s\n</main>\n</body>\n</html>\n"
        % (e(title), css, body)
    )


def table(headers, rows, num_cols=()):
    h = "".join('<th class="num">%s</th>' % e(x) if i in num_cols else "<th>%s</th>" % e(x) for i, x in enumerate(headers))
    out = ["<table><thead><tr>%s</tr></thead><tbody>" % h]
    for r in rows:
        out.append("<tr>%s</tr>" % "".join(
            '<td class="num">%s</td>' % c if i in num_cols else "<td>%s</td>" % c for i, c in enumerate(r)))
    out.append("</tbody></table>")
    return "".join(out)


def parse_dt(s):
    return datetime.strptime(s, DT_FMT) if s else None


# ---- 図 ----

def bar_chart(items, fmt_value):
    """横棒グラフ。itemsは(ラベル, 値またはNone, リンク先またはNone, ホバーの文字またはNone)の並び。
    リンク先があれば、ラベルをそのリンクにし、ホバーの文字があれば、リンクの中にtitle要素として置く。"""
    label_w, bar_w, row_h = 320, 480, 24
    vals = [v for _, v, _, _ in items if v is not None]
    vmax = max(vals) if vals and max(vals) > 0 else 1
    h = row_h * len(items) + 10
    out = ['<svg viewBox="0 0 %d %d" width="%d" role="img">' % (label_w + bar_w + 140, h, label_w + bar_w + 140)]
    for i, (label, v, href, hover) in enumerate(items):
        y = 5 + i * row_h
        lab = label if len(label) <= 40 else label[:39] + "…"
        text = '<text x="%d" y="%d" text-anchor="end">%s</text>' % (label_w - 6, y + 16, e(lab))
        tip = "<title>%s</title>" % e(hover) if hover is not None else ""
        out.append('<a href="%s">%s%s</a>' % (e(href), tip, text) if href else text)
        if v is None:
            out.append('<text x="%d" y="%d" class="muted">不明</text>' % (label_w + 4, y + 16))
            continue
        w = max(1, bar_w * v / vmax) if v > 0 else 0
        out.append('<rect class="bar" x="%d" y="%d" width="%.1f" height="%d"/>' % (label_w, y + 4, w, row_h - 8))
        out.append('<text x="%.1f" y="%d">%s</text>' % (label_w + w + 6, y + 16, e(fmt_value(v))))
    out.append("</svg>")
    return "".join(out)


def bar_matrix(rows, cols):
    """横棒の図を列ごとに並べたもの。rowsは(ラベル, 値の並び, ホバーの文字またはNone)の並びで、値の並びの各要素は
    None（不明）か(クラス名, 数)の並び（積み上げる区分）。colsは(見出し, 値の書き方)の並び。
    rowsの要素に4つ目として{列の番号: 文字}を加えると、その列の値の後にその文字を添える。
    棒の長さは列ごとの最大の値で決め、棒の横に区分の和を書く。"""
    label_w, col_w, bar_w, row_h, head_h, char_w = 150, 215, 120, 22, 24, 13
    vmax = []
    for j in range(len(cols)):
        vals = [sum(v for _, v in r[1][j]) for r in rows if r[1][j] is not None]
        vmax.append(max(vals) if vals and max(vals) > 0 else 1)
    marks = [r[3] if len(r) > 3 else {} for r in rows]
    w = label_w + col_w * len(cols) + char_w * max([len(t) for m in marks for t in m.values()] or [0])
    h = head_h + row_h * len(rows) + 6
    out = ['<svg viewBox="0 0 %d %d" width="%d" role="img">' % (w, h, w)]
    for j, (head, _) in enumerate(cols):
        out.append('<text x="%d" y="16" class="muted">%s</text>' % (label_w + j * col_w, e(head)))
    for i, (label, values, hover) in enumerate(r[:3] for r in rows):
        y = head_h + i * row_h
        out.append("<g>")
        if hover:
            out.append("<title>%s</title>" % e(hover))
        out.append('<text x="%d" y="%d" text-anchor="end">%s</text>' % (label_w - 8, y + 15, e(label)))
        for j, (_, f) in enumerate(cols):
            x0 = label_w + j * col_w
            segs = values[j]
            if segs is None:
                out.append('<text x="%d" y="%d" class="muted">不明</text>' % (x0, y + 15))
                continue
            x = float(x0)
            for cls, v in segs:
                sw = bar_w * v / vmax[j] if v > 0 else 0
                if sw > 0:
                    out.append('<rect class="%s" x="%.1f" y="%d" width="%.1f" height="%d"/>' % (cls, x, y + 5, max(sw, 1), row_h - 9))
                x += sw
            out.append('<text x="%.1f" y="%d">%s</text>' % (x + 5, y + 15, e(f(sum(v for _, v in segs)) + marks[i].get(j, ""))))
        out.append("</g>")
    out.append("</svg>")
    return "".join(out)


PHASE_GROUPS = (("plan", "方針と計画"), ("tasks", "タスクの実行"), ("overall", "全体レビュー"), ("user", "利用者レビュー"))


def phase_group(name):
    """段階の名前から、まとまりを決める。「利用者レビュー」を含めば利用者レビュー、「全体レビュー」を含めば全体レビュー、
    それ以外は方針と計画。"""
    if "利用者レビュー" in name:
        return "user"
    if "全体レビュー" in name:
        return "overall"
    return "plan"


PHASE_CLASS = {"plan": "phase", "overall": "overall", "user": "user"}


def launch_label(l):
    """担当の起動の名前（「T1の実行者（2回目）」「全体レビュー（1回目）」）。"""
    if l["role"] == "overall":
        return "全体レビュー（%d回目）" % l["n"]
    return "%sの%s（%d回目）" % (l["task"] or "（タスク不明）", ROLE_LABEL[l["role"]], l["n"])


def review_label(r):
    """レビューの名前（「T1のレビュー（2回目）」「全体レビュー（1回目）」）。"""
    if r["target"] == OVERALL:
        return "全体レビュー（%d回目）" % r["n"]
    return "%sのレビュー（%d回目）" % (r["target"], r["n"])


def short(text, n):
    return text if len(text) <= n else text[:n - 1] + "…"


def process_rows(d):
    """処理の図の行を、まとまりごとに返す。返すのは(まとまりのキーごとの行の並びの辞書, 図に描けない項目の文の並び)。
    行は(ラベル, ホバーの文字, 棒の並び)で、棒は(クラス名, 始め, 終わり, ホバーの文字)。"""
    s = d["script"]
    groups = {k: [] for k, _ in PHASE_GROUPS}
    undrawn = []
    # 段階（同じ名前の段階は同じ行）
    by_name = {}
    for p in d["phases"]:
        if p["start"] is None or p["end"] is None:
            undrawn.append("段階「%s」（%s）" % (p["name"], "開始日時が不明" if p["start"] is None else "終了日時が不明"))
            continue
        bar = (PHASE_CLASS[phase_group(p["name"])], parse_dt(p["start"]), parse_dt(p["end"]),
               "%s：%sから%sまで" % (p["name"], p["start"], p["end"]))
        by_name.setdefault(p["name"], []).append(bar)
    for name, bars in sorted(by_name.items(), key=lambda kv: min(b[1] for b in kv[1])):
        groups[phase_group(name)].append((short(name, 16), name, bars))
    # 担当の起動（タスクごとに一行、全体レビューは一行）
    names = {t["id"]: t["name"] for t in d["tasks"]}
    order = [t["id"] for t in d["tasks"]]
    task_bars = {}
    overall_bars = []
    for l in s["launches"]:
        label = launch_label(l)
        if not (l["start"] and l["end"]):
            undrawn.append("%s（開始時刻か終了時刻が不明）" % label)
            continue
        bar = (l["role"], parse_dt(l["start"]), parse_dt(l["end"]), "%s：%sから%sまで（所要時間：%s。所要時間の出どころ：%s。モデル：%s）" % (
            label, l["start"], l["end"], hms(l["duration_ms"] / 1000) if l["duration_ms"] is not None else "不明",
            l["duration_source"] or "なし", l["model"] or "不明"))
        if l["role"] == "overall":
            overall_bars.append(bar)
        else:
            tid = l["task"] or "（タスク不明）"
            if tid not in order:
                order.append(tid)
            task_bars.setdefault(tid, []).append(bar)
    for tid in order:
        if tid in task_bars:
            full = "%s %s" % (tid, names.get(tid, ""))
            groups["tasks"].append((short(full.strip(), 16), full.strip(), task_bars[tid]))
    if overall_bars:
        groups["overall"].insert(0, ("全体レビューの起動", "全体レビューの起動", overall_bars))
    return groups, undrawn


def process_svg(d):
    """処理のガントチャート。行はまとまりごとの段階と担当の起動で、まとまりの間に区切り線を引く。
    裁定の時点を縦線と印で、待機の区間を図の高さいっぱいの帯で示す。"""
    s = d["script"]
    groups, undrawn = process_rows(d)
    rulings = [r for r in (d["rulings"] or []) if r["time"]]
    waits = (s["durations"].get("wait_intervals") or [])
    t0 = parse_dt(d["started"])
    t1 = parse_dt(d["finished"]) or parse_dt(s["generated_at"])
    pts = [b[1] for rows in groups.values() for _, _, bars in rows for b in bars]
    pts += [b[2] for rows in groups.values() for _, _, bars in rows for b in bars]
    pts += [parse_dt(r["time"]) for r in rulings]
    lo = t0 or (min(pts) if pts else None)
    hi = t1 if t0 else (max(pts) if pts else None)
    if lo is None or hi is None or hi <= lo:
        return '<p class="muted">図にする時刻：なし</p>', undrawn
    span = (hi - lo).total_seconds()
    label_w, plot_w, row_h, group_h, top = 210, 860, 18, 22, 30
    shown = [(key, title, groups[key]) for key, title in PHASE_GROUPS if groups[key]]
    height = top + sum(group_h + row_h * len(rows) for _, _, rows in shown) + 34
    bottom = height - 28

    def x(dt):
        dt = min(max(dt, lo), hi)
        return label_w + plot_w * (dt - lo).total_seconds() / span

    out = ['<svg viewBox="0 0 %d %d" width="%d" role="img">' % (label_w + plot_w + 50, height, label_w + plot_w + 50)]
    for w in waits:
        a, b = x(parse_dt(w["start"])), x(parse_dt(w["end"]))
        out.append('<rect class="wait" x="%.1f" y="%d" width="%.1f" height="%d"><title>待機：%sから%sまで</title></rect>'
                   % (a, top - 4, max(b - a, 1), bottom - top + 4, e(w["start"]), e(w["end"])))
    ticks = 6
    for i in range(ticks + 1):
        tx = label_w + plot_w * i / ticks
        dt = lo + (hi - lo) * i / ticks
        out.append('<line class="grid" x1="%.1f" y1="%d" x2="%.1f" y2="%d"/>' % (tx, top - 4, tx, bottom))
        out.append('<text x="%.1f" y="%d" text-anchor="middle" class="muted">%s</text>' % (tx, bottom + 16, dt.strftime("%m-%d %H:%M")))
    y = top
    for gi, (key, title, rows) in enumerate(shown):
        if gi:
            out.append('<line class="sep" x1="0" y1="%d" x2="%d" y2="%d"/>' % (y, label_w + plot_w, y))
        out.append('<text x="4" y="%d" class="group">%s</text>' % (y + 15, e(title)))
        y += group_h
        for label, hover, bars in rows:
            out.append('<g><title>%s</title><text x="%d" y="%d" text-anchor="end">%s</text></g>' % (e(hover), label_w - 6, y + 13, e(label)))
            for cls, a, b, tip in bars:
                xa, xb = x(a), x(b)
                out.append('<rect class="%s" x="%.1f" y="%d" width="%.1f" height="%d"><title>%s</title></rect>'
                           % (cls, xa, y + 3, max(xb - xa, 2), row_h - 6, e(tip)))
            y += row_h
    for r in rulings:
        rx = x(parse_dt(r["time"]))
        out.append('<line class="ruling" x1="%.1f" y1="%d" x2="%.1f" y2="%d"/>' % (rx, top - 8, rx, bottom))
        out.append('<polygon class="ruling-mark" points="%.1f,%d %.1f,%d %.1f,%d"><title>裁定（%s）：%s</title></polygon>'
                   % (rx - 5, top - 16, rx + 5, top - 16, rx, top - 7, e(r["time"]), e(short(r["text"], 120))))
    out.append("</svg>")
    return "".join(out), undrawn


# ---- フローチャート ----

FC_W, FC_H, FC_G, FC_LANE = 240, 40, 56, 6
FC_BEND_PAD, FC_BEND_LANE = 18, 10  # 矢印が向きを変える行の間の、ノードの枠と横の線との間と、横の線どうしの間
FC_KIND = (("plan", "段階"), ("task", "タスク"), ("overall", "全体レビュー"), ("user", "利用者レビュー"))
FC_EDGE = (("flow", "流れ"), ("dep", "依存（依存先から依存するタスクへ）"), ("back", "差し戻しで戻った流れ"))


def text_width(text):
    """12pxの文字の幅の見積もり。ASCIIの文字を7、それ以外を12とする。"""
    return sum(7 if ord(c) < 128 else 12 for c in text)


def fit(text, width):
    """文字の幅の見積もりがwidthに収まるよう、収まらなければ末尾を「…」にして縮める。"""
    if text_width(text) <= width:
        return text
    while text and text_width(text) + 12 > width:
        text = text[:-1]
    return text + "…"


def task_levels(tasks):
    """タスクのIDごとの依存の段。依存の無いタスクは0、依存するタスクは依存先の段の最大に1を足した段。
    dependsがnullのタスクは依存が無いものとし、循環する依存は0とする。"""
    deps = {t["id"]: t["depends"] or [] for t in tasks}
    levels = {}

    def level(tid, seen):
        if tid in levels:
            return levels[tid]
        if tid in seen:
            return 0
        lv = max([level(x, seen | {tid}) + 1 for x in deps.get(tid, []) if x in deps] or [0])
        levels[tid] = lv
        return lv

    for t in tasks:
        level(t["id"], frozenset())
    return levels


def short_time(a, b):
    """段階の区間の文（「10-03 12:43〜12:47」）。終わりが無ければ「〜不明」。"""
    if b is None:
        return "%s〜不明" % a.strftime("%m-%d %H:%M")
    return "%s〜%s" % (a.strftime("%m-%d %H:%M"), b.strftime("%H:%M" if a.date() == b.date() else "%m-%d %H:%M"))


def fmt_dt(dt):
    return dt.strftime(DT_FMT) if dt else "不明"


def flow_layout(d):
    """フローチャートのノード、行、矢印を求める。返すのは(ノードの辞書, 行の並び, 矢印の並び, 図に置けない項目の文の並び)。
    ノードは{"kind", "name", "sub", "title"}（種類、一行目、二行目、ホバーの文字）、行はノードのIDの並び、
    矢印は(元のID, 先のID, 種類)。"""
    s = d["script"]
    undrawn = []
    nodes = {}
    # 段階：始めのある段階を始めの順に並べる
    phases = []
    for i, p in enumerate(d["phases"]):
        if p["start"] is None:
            undrawn.append("段階「%s」（開始日時が不明）" % p["name"])
            continue
        phases.append((parse_dt(p["start"]), i, p))
    phases.sort(key=lambda x: (x[0], x[1]))
    seen_names = {}
    counts = {}
    for _, _, p in phases:
        counts[p["name"]] = counts.get(p["name"], 0) + 1
    for start, i, p in phases:
        seen_names[p["name"]] = seen_names.get(p["name"], 0) + 1
        name = p["name"] + ("（%d回目）" % seen_names[p["name"]] if counts[p["name"]] > 1 else "")
        nodes["p%d" % i] = {"kind": phase_group(p["name"]), "name": name, "start": start, "end": parse_dt(p["end"]),
                            "marks": [], "title": "%s：%sから%sまで" % (name, p["start"], p["end"] or "不明")}
    order = ["p%d" % i for _, i, _ in phases]
    reviews = [pid for pid in order if nodes[pid]["kind"] in ("overall", "user")]

    # タスク：着手した時刻（担当の最初の起動の開始時刻。無ければtasksの順で前のタスクの時刻）
    firsts = {}
    for l in s["launches"]:
        if l["task"] and l["start"]:
            t0 = parse_dt(l["start"])
            firsts[l["task"]] = min(firsts.get(l["task"], t0), t0)
    levels = task_levels(d["tasks"])
    lc = s["launch_counts"]
    rework = {r["id"]: r["total"] for r in task_rework(d)[0]}
    keys = {}
    prev = None
    for idx, t in enumerate(d["tasks"]):
        key = firsts.get(t["id"], prev)
        prev = key
        keys[t["id"]] = (key is not None, key or datetime.min, idx)
        parts = []
        if lc is not None:
            c = lc["tasks"].get(t["id"]) or {"worker": 0, "reviewer": 0}
            parts += ["実行者%d" % c["worker"], "評価者%d" % c["reviewer"]]
        if rework[t["id"]] is not None:
            parts.append("差戻%d" % rework[t["id"]])
        nodes["t:" + t["id"]] = {"kind": "task", "name": "%s %s" % (t["id"], t["name"]), "sub": "・".join(parts),
                                 "title": "%s %s\n着手：%s\n依存：%s\n担当の起動と差し戻し：%s" % (
                                     t["id"], t["name"], fmt_dt(firsts.get(t["id"])),
                                     "不明" if t["depends"] is None else "、".join(t["depends"]) or "なし", "、".join(parts) or "不明")}
        if t["depends"] is None:
            undrawn.append("%sの依存（依存が不明）" % t["id"])

    # タスクのまとまりは、着手した時刻以後に始まった最初の全体レビューか利用者レビューの段階の直前に置く
    clusters = {}
    for t in d["tasks"]:
        has, key, _ = keys[t["id"]]
        pos = len(order)
        for k, pid in enumerate(order):
            if pid in reviews and (not has or nodes[pid]["start"] >= key):
                pos = k
                break
        clusters.setdefault(pos, []).append(t["id"])
    backbone = []
    for k in range(len(order) + 1):
        if k in clusters:
            backbone.append(("tasks", clusters[k]))
        if k < len(order):
            backbone.append(("phase", order[k]))

    # 行：段階は一つで一行、タスクのまとまりは依存の段ごとに一行
    rows = []
    for kind, item in backbone:
        if kind == "phase":
            rows.append([item])
            continue
        for lv in sorted({levels[tid] for tid in item}):
            rows.append(["t:" + tid for tid in sorted((x for x in item if levels[x] == lv), key=lambda x: keys[x])])

    deps = {t["id"]: t["depends"] or [] for t in d["tasks"]}

    def heads(item):
        """まとまりに入る先のノード（まとまりの中に依存先が無いタスク）。"""
        kind, v = item
        return [v] if kind == "phase" else ["t:" + x for x in v if not set(deps[x]) & set(v)]

    def tails(item):
        """まとまりから出る元のノード（まとまりの中に依存されないタスク）。"""
        kind, v = item
        return [v] if kind == "phase" else ["t:" + x for x in v if not any(x in deps[y] for y in v)]

    edges = []
    # 差し戻し：全体レビューの差し戻しはn回目の全体レビューの段階から、利用者レビューの差し戻しは差し戻した日時までに
    # 終わった全体レビューか利用者レビューの段階のうち最後に終わったものから、差し戻したタスクと、
    # その段階の後ろにある次の全体レビューか利用者レビューの段階までに置いたタスク（無ければ次のノード）へ
    overall_ids = [pid for pid in order if nodes[pid]["kind"] == "overall"]

    def back_targets(src, tids):
        k = next(i for i, it in enumerate(backbone) if it == ("phase", src))
        added = []
        for it in backbone[k + 1:]:
            if it[0] == "phase" and it[1] in reviews:
                break
            if it[0] == "tasks":
                added += ["t:" + x for x in it[1]]
        targets = ["t:" + x for x in tids] + [x for x in added if x[2:] not in tids]
        if not targets and k + 1 < len(backbone):
            targets = heads(backbone[k + 1])
        return targets

    def add_back(src, tids, label, mark):
        if tids is None:
            undrawn.append("%sで差し戻したタスク（記録に無い）" % label)
        targets = back_targets(src, tids or [])
        if not targets:
            undrawn.append("%s（戻した先が図に無い）" % label)
        nodes[src]["marks"].append(mark)
        nodes[src]["title"] += "\n%s" % label
        for t in targets:
            edges.append((src, t, "back"))

    for sb in d["overall_sendbacks"] or []:
        label = "全体レビュー（%d回目）の差し戻し" % sb["n"]
        if not 1 <= sb["n"] <= len(overall_ids):
            undrawn.append("%s（全体レビューの段階が図に無い）" % label)
            continue
        add_back(overall_ids[sb["n"] - 1], sb["tasks"], label, "差戻")
    for sb in d["user_sendbacks"] or []:
        label = "利用者レビューの差し戻し（%s）" % (sb["time"] or "日時が不明")
        if sb["time"] is None:
            undrawn.append(label)
            continue
        t = parse_dt(sb["time"])
        done = [pid for pid in reviews if nodes[pid]["end"] is not None and nodes[pid]["end"] <= t]
        if not done:
            undrawn.append("%s（差し戻した日時までに終わったレビューの段階が無い）" % label)
            continue
        src = max(done, key=lambda pid: (nodes[pid]["end"], order.index(pid)))
        add_back(src, sb["tasks"], label, "差戻" if nodes[src]["kind"] == "user" else "利用者が差戻")
    # 流れ：段階の順に、段階からまとまりの入る先へ、まとまりの出る元から段階へ（差し戻しの矢印と同じものは除く）
    backs = {(a, b) for a, b, _ in edges}
    for a, b in zip(backbone, backbone[1:]):
        for x in tails(a):
            for y in heads(b):
                if (x, y) not in backs:
                    edges.append((x, y, "flow"))
    # 依存：依存先から依存するタスクへ
    for t in d["tasks"]:
        for dep in t["depends"] or []:
            edges.append(("t:" + dep, "t:" + t["id"], "dep"))
    for nid, n in nodes.items():
        if n["kind"] != "task":
            n["sub"] = "・".join([short_time(n["start"], n["end"])] + n["marks"])
    return nodes, rows, edges, undrawn


def lanes(spans, pad):
    """区間の並び（(始め, 終わり)）に、重ならないよう番号を振る。返すのは(区間ごとの番号の並び, 番号の数)。"""
    ends = []
    result = [0] * len(spans)
    for i in sorted(range(len(spans)), key=lambda i: spans[i]):
        a, b = spans[i]
        for j, e_ in enumerate(ends):
            if e_ + pad < a:
                ends[j] = b
                result[i] = j
                break
        else:
            ends.append(b)
            result[i] = len(ends) - 1
    return result, len(ends)


def flow_svg(d):
    """処理の流れのフローチャート。上から下へ時間の順に、段階とタスクのノードを置き、矢印でつなぐ。
    矢印の横の線は行の間に、縦の線はノードの列の間か右端に引き、ノードの上と一番左の列より左を通さない。
    列の間と右端の幅は、そこに引く縦の線の本数に合わせて広げ、右の列のノードを右にずらす。
    矢印が向きを変える行の間（横の線の長さが0でない行の間）は、ノードの枠と横の線との間と、横の線どうしの間を広く取る。
    返すのは(SVG, 図に置けない項目の文の並び, 「利用者が差戻」の印を付けた段階があるか)。"""
    nodes, rows, edges, undrawn = flow_layout(d)
    user_back = any("利用者が差戻" in n["marks"] for n in nodes.values() if n["kind"] != "task")
    if not rows:
        return '<p class="muted">図にする段階とタスク：なし</p>', undrawn, user_back
    W, H, G = FC_W, FC_H, FC_G
    pos = {nid: (r, c) for r, row in enumerate(rows) for c, nid in enumerate(row)}
    nslots = max(len(row) for row in rows)

    # 経路：隣の行へは行の間の横の線だけ、それ以外は列の間か右端の縦の線を通す。
    # 縦の線を引く所の番号cは、c列目の左（cが列の数なら右端）であり、両端のノードの中心から近い所を選ぶ
    routes = []
    for a, b, kind in edges:
        (ra, ca), (rb, cb) = pos[a], pos[b]
        if rb == ra + 1:
            routes.append({"a": a, "b": b, "kind": kind, "c": None, "ga": ra, "gb": ra})
        else:
            c = min(range(1, nslots + 1), key=lambda c: (abs(2 * c - 2 * ca - 1) + abs(2 * c - 2 * cb - 1), c))
            routes.append({"a": a, "b": b, "kind": kind, "c": c, "ga": ra, "gb": rb - 1})
    # 縦の線の番号：縦の線を引く所ごとに、行の範囲が重なる線に別の番号を振る
    by_c = {}
    for rt in routes:
        if rt["c"] is not None:
            by_c.setdefault(rt["c"], []).append(rt)
    lane_n = {}
    for c, rs in by_c.items():
        idx, lane_n[c] = lanes([(min(rt["ga"], rt["gb"]), max(rt["ga"], rt["gb"])) for rt in rs], 0)
        for rt, j in zip(rs, idx):
            rt["j"] = j
    # 列の位置：c列目の左の幅は、縦の線の間隔で線を並べ、ノードの枠との間を8空ける幅とし、Gより狭くしない
    gw = {c: max(G, 16 + FC_LANE * (lane_n.get(c, 1) - 1)) for c in range(1, nslots + 1)}
    col_left = [4]
    for c in range(1, nslots):
        col_left.append(col_left[-1] + W + gw[c])

    def cx(nid):
        return col_left[pos[nid][1]] + W / 2

    def corridor_x(c):
        return col_left[c - 1] + W + gw[c] / 2

    # 出入りの位置：行の間ごと、列ごとに、上のノードの下の辺から出る線と下のノードの上の辺に入る線を合わせて、
    # 向かう先の横の位置の順にノードの幅に等間隔に置き、別の矢印の縦の線を同じ横の位置に置かない。
    # 上のノードから真下のノードへ向かう矢印は、出る位置と入る位置を同じにする
    ends = {}
    for rt in routes:
        (ra, ca), (rb, cb) = pos[rt["a"]], pos[rt["b"]]
        if rt["c"] is None and ca == cb:
            ends.setdefault((ra, ca), []).append(((cx(rt["a"]), cx(rt["a"])), rt, ("xa", "xb")))
            continue
        for g, c, side, other in ((ra, ca, "xa", "b"), (rb - 1, cb, "xb", "a")):
            key = corridor_x(rt["c"]) if rt["c"] is not None else cx(rt[other])
            ends.setdefault((g, c), []).append(((key, cx(rt[other])), rt, (side,)))
    for (g, c), es in ends.items():
        es.sort(key=lambda en: en[0])
        left = col_left[c]
        for i, (_, rt, sides) in enumerate(es):
            for side in sides:
                rt[side] = left + W * (i + 1) / (len(es) + 1)
    # 縦の線の位置：縦の線を引く所ごとに、番号の順に縦の線の間隔で並べる
    for rt in routes:
        if rt["c"] is not None:
            rt["x"] = corridor_x(rt["c"]) + (rt["j"] - (lane_n[rt["c"]] - 1) / 2) * FC_LANE
    # 横の線の位置：行の間ごとに、横の範囲が重なる線を縦にずらす
    segs = {}
    for rt in routes:
        if rt["c"] is None:
            segs.setdefault(rt["ga"], []).append((rt, "ya", rt["xa"], rt["xb"]))
        else:
            segs.setdefault(rt["ga"], []).append((rt, "ya", rt["xa"], rt["x"]))
            segs.setdefault(rt["gb"], []).append((rt, "yb", rt["x"], rt["xb"]))
    gap_lane = {}
    gap_n = {}
    bent = {g for g, ss in segs.items() if any(x0 != x1 for _, _, x0, x1 in ss)}
    for g, ss in segs.items():
        idx, n = lanes([(min(x0, x1), max(x0, x1)) for _, _, x0, x1 in ss], 4)
        gap_n[g] = n
        gap_lane[g] = [(rt, side, j) for (rt, side, _, _), j in zip(ss, idx)]
    gap_top, row_top = {}, {}
    y = 4
    for g in range(-1, len(rows)):
        if g >= 0:
            row_top[g] = y
            y += H
        gap_top[g] = y
        if g in bent:
            y += 2 * FC_BEND_PAD + FC_BEND_LANE * max(gap_n.get(g, 0) - 1, 0)
        else:
            y += 16 + FC_LANE * gap_n[g] if gap_n.get(g) else 14
    height = y + 4
    for g, ls in gap_lane.items():
        first, step = (FC_BEND_PAD, FC_BEND_LANE) if g in bent else (8, FC_LANE)
        for rt, side, j in ls:
            rt[side] = gap_top[g] + first + step * j
    width = col_left[-1] + W + gw[nslots]
    out = ['<svg viewBox="0 0 %d %d" width="%d" role="img">' % (width, height, width)]
    for rt in routes:
        r0, r1 = pos[rt["a"]][0], pos[rt["b"]][0]
        y0, y1 = row_top[r0] + H, row_top[r1]
        pts = [(rt["xa"], y0), (rt["xa"], rt["ya"])]
        if rt["c"] is None:
            pts += [(rt["xb"], rt["ya"])]
        else:
            pts += [(rt["x"], rt["ya"]), (rt["x"], rt["yb"]), (rt["xb"], rt["yb"])]
        pts.append((rt["xb"], y1 - 7))
        label = dict(FC_EDGE)[rt["kind"]].split("（")[0]
        tip = "%s：%sから%sへ" % (label, nodes[rt["a"]]["name"], nodes[rt["b"]]["name"])
        out.append('<path class="fc-%s" d="M%s"><title>%s</title></path>' % (
            rt["kind"], " L".join("%.1f %.1f" % p for p in pts), e(tip)))
        out.append('<polygon class="fc-%s-head" points="%.1f,%d %.1f,%d %.1f,%d"/>' % (
            rt["kind"], rt["xb"] - 4, y1 - 7, rt["xb"] + 4, y1 - 7, rt["xb"], y1))
    for nid, (r, c) in pos.items():
        n = nodes[nid]
        x0 = col_left[c]
        y0 = row_top[r]
        out.append('<g><title>%s</title><rect class="fc-node fc-%s" x="%d" y="%d" width="%d" height="%d" rx="%d"/>'
                   '<text x="%d" y="%d">%s</text><text x="%d" y="%d" class="muted">%s</text></g>' % (
                       e(n["title"]), n["kind"], x0, y0, W, H, 3 if n["kind"] == "task" else 14,
                       x0 + 12, y0 + 16, e(fit(n["name"], W - 24)), x0 + 12, y0 + 33, e(fit(n["sub"], W - 24))))
    out.append("</svg>")
    return "".join(out), undrawn, user_back


def flow_section(d):
    """処理の節のフローチャートの凡例、図、注記。"""
    out = ['<p class="legend">%s%s</p>' % (
        "".join('<span><span class="sw fc-sw fc-sw-%s"></span>%s</span>' % (k, e(lab)) for k, lab in FC_KIND),
        "".join('<span><span class="sw fc-line-%s"></span>%s</span>' % (k, e(lab)) for k, lab in FC_EDGE))]
    svg, undrawn, user_back = flow_svg(d)
    out.append(svg)
    items = ["上から下へ時間の順に並ぶ。タスクは依存の段ごとに一行に並べ、同じ行のタスクは互いに依存しない",
             "タスクの下の行は、担当の起動回数（実行者、評価者）と差し戻し回数",
             "段階の下の行は、区間と差し戻し"
             + ("。「利用者が差戻」は、そのレビューの後に利用者レビューで差し戻したこと" if user_back else "")]
    if undrawn:
        items.append("図に置けなかったもの：%s" % e("、".join(undrawn)))
    out.append(notes(items))
    return out


# ---- 案件のHTML ----

OVERALL = "全体"
ITEM_LABEL = {
    "title": "表題", "state": "状態", "started": "着手日時", "finished": "完了日時", "purpose": "目的", "phases": "段階の一覧",
    "tasks": "タスクの一覧", "rulings": "裁定の一覧", "policy_changes": "対応方針の変更の回数", "progress": "経過の一覧",
    "reviews": "レビューの一覧", "reports": "報告の一覧", "reopened": "完了から実行中に戻した回数",
    "overall_sendbacks": "全体レビューの差し戻しで差し戻したタスク", "user_sendbacks": "利用者レビューの差し戻しで差し戻したタスク",
    "proposals_adopted": "採り入れた提案の数", "change": "変更量",
    "change.files": "変更量のファイル数", "change.added": "変更量の追加行数", "change.removed": "変更量の削除行数",
}
TIER_ORDER = ("service_tier", "speed")


def why(d, path):
    """実施者がnullにした項目の理由（unknownに書いたもの）。"""
    for u in d["unknown"]:
        if u["item"] == path:
            return u["reason"]
    return "記録に無い"


def item_label(path):
    top = path.split(".")[0].split("[")[0]
    label = ITEM_LABEL.get(path) or ITEM_LABEL.get(top)
    return "%s（%s）" % (label, path) if label else path


def or_na(d, path, value, show=None):
    if value is None:
        return na(why(d, path))
    return show(value) if show else e(value)


def pre(text):
    return '<span class="pre">%s</span>' % e(text)


def change_parts(d):
    """変更量の(ファイル数, 追加行数, 削除行数)。changeがnullなら三つともNone。"""
    ch = d["change"]
    if ch is None:
        return None, None, None
    return ch["files"], ch["added"], ch["removed"]


def change_text(files, added, removed, unknown):
    """変更量の文。値の無い部分はunknown(部分の名前)の結果を使う。"""
    return "%s、%s、%s" % (
        "%sファイル" % num(files) if files is not None else "ファイル数：" + unknown("files"),
        "追加%s行" % num(added) if added is not None else "追加行数：" + unknown("added"),
        "削除%s行" % num(removed) if removed is not None else "削除行数：" + unknown("removed"),
    )


def non_standard_text(ns):
    """標準以外の呼び出しの数の文。"""
    items = ["%sの%sが%s件" % (key, v, num(n)) for key in TIER_ORDER for v, n in sorted((ns.get(key) or {}).items())]
    return "、".join(items) if items else "0件"


def sendback_counts(d, key):
    """overall_sendbacksまたはuser_sendbacksから、タスクのIDごとの差し戻された数を求める。
    実施者がnullにした箇所があれば、数の代わりに(None, 理由)を返す。"""
    sbs = d[key]
    if sbs is None:
        return None, why(d, key)
    counts = {}
    for i, sb in enumerate(sbs):
        if sb["tasks"] is None:
            return None, why(d, "%s[%d].tasks" % (key, i))
        for tid in sb["tasks"]:
            counts[tid] = counts.get(tid, 0) + 1
    return counts, None


def task_rework(d):
    """タスクごとの差し戻し回数。内訳は、タスクのレビューの判定が差し戻しの数、全体レビューの差し戻しで
    差し戻された数、利用者レビューの差し戻しで差し戻された数で、合計はその和。数えられない内訳はNone。
    返すのは(タスクのIDごとの辞書の並び, 全体レビューの内訳が数えられない理由, 利用者レビューの内訳が数えられない理由)。"""
    overall, overall_reason = sendback_counts(d, "overall_sendbacks")
    user, user_reason = sendback_counts(d, "user_sendbacks")
    rows = []
    for t in d["tasks"]:
        rs = [r for r in d["reviews"] if r["target"] == t["id"]]
        row = {
            "id": t["id"],
            "reviews": len(rs),
            "review": sum(1 for r in rs if r["verdict"] == "差し戻し"),
            "overall": overall.get(t["id"], 0) if overall is not None else None,
            "user": user.get(t["id"], 0) if user is not None else None,
        }
        parts = (row["review"], row["overall"], row["user"])
        row["total"] = None if None in parts else sum(parts)
        rows.append(row)
    return rows, overall_reason, user_reason


def summary(d):
    """一覧と比較に使う指標。実施者が書いた値とスクリプトが書き足した値から求める。"""
    s = d["script"]
    reviews = d["reviews"]
    overall = [r for r in reviews if r["target"] == OVERALL]
    proposals = None
    if all(r["proposals"] is not None for r in reviews):
        proposals = sum(r["proposals"] for r in reviews)
    prefix = (s.get("project_dir") or "").rstrip("/") + "/"
    changed = sorted({f[len(prefix):] if prefix != "/" and f.startswith(prefix) else f
                      for r in d["reports"] for f in r["changed_files"]})
    lc = s["launch_counts"]
    cost = s["cost"]
    ch_files, ch_added, ch_removed = change_parts(d)
    rework_rows = task_rework(d)[0]
    rework_total = None if any(r["total"] is None for r in rework_rows) else sum(r["total"] for r in rework_rows)
    return {
        "total_tokens": s["total_tokens"],
        "total_usd": cost["total_usd"] if cost else None,
        "cost_excludes_unknown": bool(cost and cost["excluded_models"] and cost["total_usd"] is not None),
        "case_seconds": s["durations"]["case_seconds"],
        "tasks": len(d["tasks"]),
        "launches_worker": lc["worker"] if lc else None,
        "launches_reviewer": lc["reviewer"] if lc else None,
        "launches_overall": lc["overall"] if lc else None,
        "rework": rework_total,
        "overall_reviews": len(overall),
        "reopened": d["reopened"],
        "rulings": len(d["rulings"]) if d["rulings"] is not None else None,
        "policy_changes": d["policy_changes"],
        "proposals": proposals,
        "proposals_known": sum(r["proposals"] for r in reviews if r["proposals"] is not None),
        "proposals_adopted": d["proposals_adopted"]["count"] if d["proposals_adopted"] else None,
        "change_files": ch_files,
        "change_added": ch_added,
        "change_removed": ch_removed,
        "changed_files": changed,
    }


CASE_CSS = CSS + """
:root{--orch:#1b7c83;--phase:#1a7f37;--user:#bf3989;--wait:#8c959f;--sep:#59636e;--dep:#1b7c83}
@media (prefers-color-scheme: dark){:root{--orch:#39c5cf;--phase:#3fb950;--user:#db61a2;--wait:#6e7681;--sep:#9198a1;--dep:#39c5cf}}
svg .orchestrator{fill:var(--orch)}svg .phase{fill:var(--phase)}svg .user{fill:var(--user)}
svg .wait{fill:var(--wait);opacity:.25}svg .sep{stroke:var(--sep);stroke-width:1;stroke-dasharray:4 3}
svg .group{font-weight:bold}
svg .fc-node{fill:var(--panel);stroke-width:2}svg .fc-plan{stroke:var(--phase)}svg .fc-task{stroke:var(--worker)}
svg .fc-overall{stroke:var(--overall)}svg .fc-user{stroke:var(--user)}
svg .fc-flow,svg .fc-dep,svg .fc-back{fill:none;stroke-width:1.5}
svg .fc-flow{stroke:var(--muted)}svg .fc-dep{stroke:var(--dep);stroke-dasharray:5 3}svg .fc-back{stroke:var(--ruling)}
svg .fc-flow-head{fill:var(--muted)}svg .fc-dep-head{fill:var(--dep)}svg .fc-back-head{fill:var(--ruling)}
.legend .fc-sw{background:var(--panel);border:2px solid;box-sizing:border-box}.legend .fc-sw-plan{border-color:var(--phase);border-radius:6px}
.legend .fc-sw-task{border-color:var(--worker)}.legend .fc-sw-overall{border-color:var(--overall);border-radius:6px}
.legend .fc-sw-user{border-color:var(--user);border-radius:6px}
.legend .fc-line-flow{border-top:2px solid var(--muted)}.legend .fc-line-dep{border-top:2px dashed var(--dep)}
.legend .fc-line-back{border-top:2px solid var(--ruling)}
table.info th{white-space:nowrap}table.info ul{margin:0;padding-left:1.2em}
details.section>summary h2{display:inline;border:0;font-size:1.25rem;margin:0;padding:0}
details.sub{margin:.8em 0}details.sub>summary{cursor:pointer;font-weight:bold}
h4{font-size:.95rem;margin:1em 0 .3em}h5{font-size:.9rem;margin:.8em 0 .3em}div.task{margin-left:1.5em}
div.task-cols,div.launches{display:flex;flex-wrap:wrap;align-items:flex-start}
div.task-cols{gap:0 2em}div.launches{gap:0 1em}
div.task-cols>div,div.launches>table{min-width:0;max-width:100%}
div.task-cols>div.launch-col{flex:1 1 16em}
div.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(min(100%,11em),1fr));gap:.6em;margin:.6em 0}
div.cards.big{grid-template-columns:repeat(auto-fill,minmax(min(100%,16em),1fr))}
div.card{background:var(--panel);border:1px solid var(--line);border-radius:6px;padding:.5em .8em;min-width:0}
div.card .label{color:var(--muted);font-size:.85rem}
div.card .value{font-size:1.3rem;font-weight:bold;font-variant-numeric:tabular-nums;overflow-wrap:anywhere}
div.cards.big div.card .value{font-size:2rem}
div.card .unit{font-size:.8rem;font-weight:normal;margin-left:.2em}
div.card .sub{color:var(--muted);font-size:.85rem;overflow-wrap:anywhere}
ul.notes{color:var(--muted);font-size:.85rem;padding-left:1.2em}
"""


def hhmmss(seconds):
    s = int(seconds)
    h, rem = divmod(s, 3600)
    m, s = divmod(rem, 60)
    return "%02d:%02d:%02d" % (h, m, s)


def one_or_list(values):
    """値が一つなら文、複数なら箇条書き。"""
    if len(values) == 1:
        return e(values[0])
    return "<ul>%s</ul>" % "".join("<li>%s</li>" % e(v) for v in values)


def info_table(rows):
    """二列の表。rowsは(見出し, 値のHTML)の並び。"""
    return '<table class="info"><tbody>%s</tbody></table>' % "".join(
        "<tr><th>%s</th><td>%s</td></tr>" % (e(h), v) for h, v in rows)


def card(label, values, subs=()):
    """カード。valuesは目立たせる値のHTMLの並び、subsは値の下に添える行のHTMLの並び。"""
    return '<div class="card"><div class="label">%s</div>%s%s</div>' % (
        e(label), "".join('<div class="value">%s</div>' % v for v in values), "".join('<div class="sub">%s</div>' % x for x in subs))


def cards(items, big=False):
    """カードを折り返して並べる。bigなら値を大きく示す。"""
    return '<div class="cards%s">%s</div>' % (" big" if big else "", "".join(items))


def unit(value_html, label):
    return '%s<span class="unit">%s</span>' % (value_html, e(label))


def notes(items):
    """短い注記の箇条書き。itemsは項目のHTMLの並び。"""
    return '<ul class="notes">%s</ul>' % "".join("<li>%s</li>" % x for x in items) if items else ""


def case_durations(d, no_launch):
    """案件の所要時間（全体、AIの作業時間、待機時間）の値のHTML。値の無いものは「不明」と理由。"""
    s = d["script"]
    dur = s["durations"]
    span, ai, wait = dur.get("span_seconds"), dur.get("ai_seconds"), dur.get("wait_seconds")
    span_html = e(hhmmss(span)) if span is not None else na("着手日時が不明")
    reason = "着手日時が不明" if span is None else script_reason(s, "所要時間の内訳（AIの作業時間、待機時間）") or no_launch
    return [span_html] + [e(hhmmss(v)) if v is not None else na(reason) for v in (ai, wait)]


def script_reason(s, item):
    for u in s["unknown"]:
        if u["item"] == item:
            return u["reason"]
    return None


def tokens_sum(by_model):
    return {k: sum(t[k] for t in by_model.values()) for k, _ in TOKEN_COLS}


def token_breakdown(by_model):
    """モデルごとのトークン量の文。"""
    return "、".join("%s（%s）" % (m, "、".join("%s：%s" % (lab, num(t[k])) for k, lab in TOKEN_COLS))
                    for m, t in sorted(by_model.items())) or "なし"


EXCLUDES_UNKNOWN = "（不明のモデルを除く）"
TOKEN_CHART_COLS = [(lab, num) for _, lab in TOKEN_COLS] + [("費用（USD）", usd)]
ROLE_CHART_COLS = [(lab, num) for _, lab in TOKEN_COLS] + [("トークン量の合計", num), ("費用（USD）", usd)]


def cost_charts(d):
    """費用の節のカード、図、注記。"""
    s = d["script"]
    c = s["cost"]
    out = []
    by_role = c.get("by_role") or {}
    by_task = c.get("by_task") or {}

    def excludes(models):
        """単価表に無いモデルを含むか。"""
        return any(m in c["excluded_models"] for m in models)

    total_cost = (na("費用を求められるモデルが無い") if c["total_usd"] is None
                  else unit(e(usd(c["total_usd"])), EXCLUDES_UNKNOWN) if c["excluded_models"] else e(usd(c["total_usd"])))
    out.append(cards([
        card("トークン量の合計", [num(s["total_tokens"])]),
        card("費用の合計（USD）", [total_cost]),
    ], big=True))
    role_cards = []
    for role in ("orchestrator", "worker", "reviewer"):
        models = s["tokens"].get(role) or {}
        u = by_role.get(role)
        label = ROLE_LABEL[role] + ("（全体レビューを含む）" if role == "reviewer" else "")
        role_cards.append(card(label, [
            na("費用を求められるモデルが無い") if u is None
            else unit(e(usd(u)), EXCLUDES_UNKNOWN) if excludes(models) else e(usd(u)),
            unit(num(sum(tokens_sum(models).values())), "トークン"),
        ], ["モデル：%s" % e("、".join(sorted(models)) if models else "記録なし")]))
    out.append(cards(role_cards))
    if s["overlap_cases"]:
        out.append('<p class="note">統括のトークン量は%sと期間が重なり、どちらにも数えている。</p>' % e("、".join(s["overlap_cases"])))

    out.append('<h3 id="cost-role">担当ごと</h3>')
    rows = []
    for role in ("orchestrator", "worker", "reviewer"):
        models = s["tokens"].get(role) or {}
        t = tokens_sum(models)
        u = by_role.get(role)
        rows.append((ROLE_LABEL[role], [[(role, t[k])] for k, _ in TOKEN_COLS] + [[(role, sum(t.values()))]]
                     + [None if u is None else [(role, u)]],
                     "%s：%s" % (ROLE_LABEL[role], token_breakdown(models)),
                     {len(ROLE_CHART_COLS) - 1: EXCLUDES_UNKNOWN} if u is not None and excludes(models) else {}))
    out.append(bar_matrix(rows, ROLE_CHART_COLS))

    out.append('<h3 id="cost-model">モデルごと</h3>')
    rows = []
    for model, t in sorted(s["tokens_by_model"].items()):
        r = c["by_model"].get(model) or {"usd": None, "reason": None}
        rows.append((short(model, 20), [[("bar", t[k])] for k, _ in TOKEN_COLS] + [None if r["usd"] is None else [("bar", r["usd"])]],
                     model if r["usd"] is not None else "%s（費用：不明。理由：%s）" % (model, r["reason"])))
    out.append(bar_matrix(rows, TOKEN_CHART_COLS) if rows else '<p class="muted">なし</p>')

    out.append('<h3 id="cost-task">タスクごと</h3>')
    rows = []
    keys = [t["id"] for t in d["tasks"]] + [k for k in by_task if k not in {t["id"] for t in d["tasks"]} and k != "全体レビュー"]
    for key in keys + ["全体レビュー"]:
        per = (s["task_tokens"] or {}).get(key)
        if not per:
            continue
        tw, tr = tokens_sum(per["worker"]), tokens_sum(per["reviewer"])
        uc = by_task.get(key) or {}
        models = set(per["worker"]) | set(per["reviewer"])
        parts = [(role, uc[role]) for role in ("worker", "reviewer") if uc.get(role) is not None]
        cost_v = parts if parts and not (models and models <= set(c["excluded_models"])) else None
        hover = "%s 実行者：%s。評価者：%s" % (key, token_breakdown(per["worker"]), token_breakdown(per["reviewer"]))
        rows.append((key, [[("worker", tw[k]), ("reviewer", tr[k])] for k, _ in TOKEN_COLS] + [cost_v], hover,
                     {len(TOKEN_CHART_COLS) - 1: EXCLUDES_UNKNOWN} if cost_v and excludes(models) else {}))
    if rows:
        out.append('<p class="legend"><span><span class="sw" style="background:var(--worker)"></span>実行者</span>'
                   '<span><span class="sw" style="background:var(--reviewer)"></span>評価者</span></p>')
        out.append(bar_matrix(rows, TOKEN_CHART_COLS))
    else:
        out.append('<p class="muted">なし</p>')

    items = []
    if c["as_of"] is None and c["source"] is None and all(r["reason"] == "単価表が無い" for r in c["by_model"].values()):
        items.append("単価表：%s" % na("単価表が無い"))
    else:
        items.append("単価：%s時点、出所<code>%s</code>（単位：%s）" % (e(c["as_of"]), e(c["source"]), e(c["unit"])))
        items.append("費用の求め方：モデルごとに（入力×入力の単価 ＋ 出力×出力の単価 ＋ 5分のキャッシュ作成×その単価 ＋ "
                     "1時間のキャッシュ作成×その単価 ＋ キャッシュ読み取り×その単価）÷1,000,000")
    if c["excluded_models"]:
        items.append("費用が分からないモデル：%s（理由：%s）。費用の合計、担当とタスクの費用は、このモデルを除いて求めた"
                     % (e("、".join(c["excluded_models"])), e("、".join(sorted({c["by_model"][m]["reason"] for m in c["excluded_models"]})))))
    items.append("標準以外の呼び出し：%s（統括と担当の呼び出しのうち、usageのservice_tierまたはspeedがstandard以外のもの）。"
                 "費用はすべての呼び出しを標準の単価で求めた" % e(non_standard_text(s["non_standard_calls"] or {})))
    items.append("同じAPI応答の記録は、message.idごとに最後の記録だけを数えた")
    out.append(notes(items))
    return out


def process_section(d, no_launch):
    s = d["script"]
    out = []
    total, ai, wait = case_durations(d, no_launch)
    w = s["durations"].get("wait_intervals")
    out.append(cards([
        card("所要時間（全体）", [total], [] if d["finished"] else ["可視化した日時まで"]),
        card("所要時間（AI）", [ai]),
        card("所要時間（待機）", [wait], [] if w is None else ["待機の区間：%s件" % num(len(w))]),
    ], big=True))
    lc = s["launch_counts"]
    launch_cards = [card(label, [na(no_launch) if lc is None else unit(num(lc[key]), "回")])
                    for key, label in (("worker", "実行者の起動"), ("reviewer", "評価者（タスクのレビュー）の起動"), ("overall", "全体レビューの起動"))]
    if s["parallel"] is None:
        launch_cards.append(card("並列か直列か", [na(no_launch)]))
    elif s["parallel"]["parallel"]:
        launch_cards.append(card("並列か直列か", ["並列"], ["起動の時間帯が重なるタスク：%s" % e("、".join("%sと%s" % tuple(p) for p in s["parallel"]["pairs"]))]))
    else:
        launch_cards.append(card("並列か直列か", ["直列"], ["起動の時間帯が重なるタスク：なし"]))
    out.append(cards(launch_cards))

    out.append('<p class="legend">'
               '<span><span class="sw" style="background:var(--phase)"></span>方針と計画の段階</span>'
               '<span><span class="sw" style="background:var(--worker)"></span>実行者</span>'
               '<span><span class="sw" style="background:var(--reviewer)"></span>評価者</span>'
               '<span><span class="sw" style="background:var(--overall)"></span>全体レビュー</span>'
               '<span><span class="sw" style="background:var(--user)"></span>利用者レビュー</span>'
               '<span><span class="sw" style="background:var(--ruling)"></span>裁定の時点</span>'
               '<span><span class="sw" style="background:var(--wait);opacity:.5"></span>待機の区間</span>'
               '<span><span class="sw" style="border-top:2px dashed var(--sep)"></span>まとまりの区切り</span></p>')
    svg, undrawn = process_svg(d)
    out.append(svg)
    end_label = "完了日時" if d["finished"] else "可視化した日時（%s）" % s["generated_at"]
    items = ["図の範囲：着手日時から%sまで" % e(end_label)]
    if not d["phases"]:
        items.append("段階：%s" % (na(why(d, "phases")) if any(u["item"] == "phases" for u in d["unknown"]) else "記録なし"))
    if not s["launches"]:
        items.append("担当の起動：%s" % na(no_launch))
    if undrawn:
        items.append("図に描けなかったもの：%s" % e("、".join(undrawn)))
    out.append(notes(items))

    out.append('<h3 id="stalls">担当の起動が無く10分以上空いた区間</h3>')
    if s["stalls"] is None:
        out.append("<p>%s</p>" % na(no_launch))
    elif not s["stalls"]:
        out.append("<p>なし</p>")
    else:
        out.append("<ul>%s</ul>" % "".join("<li>%sから%sまで（%s）</li>" % (e(x["start"]), e(x["end"]), e(hhmmss(x["seconds"])))
                                           for x in s["stalls"]))

    out.append('<h3 id="flow">段階とタスクの流れ</h3>')
    out.extend(flow_section(d))

    if d["progress"] is None:
        out.append("<p>経過：%s</p>" % na(why(d, "progress")))
    else:
        out.append('<details class="sub"><summary>経過（%d件）</summary><ul>%s</ul></details>' % (len(d["progress"]), "".join(
            "<li>%s：%s</li>" % (or_na(d, "progress[%d].time" % i, p["time"]), pre(p["text"])) for i, p in enumerate(d["progress"]))
            or '<li class="muted">項目なし</li>'))
    return out


def task_rows(d, i, t, rework, no_launch):
    """タスクの表の行（状態、開始日時、完了日時、所要時間の三つ、差し戻し回数、依存）。"""
    s = d["script"]
    span = s["durations"]["tasks"].get(t["id"])
    if span is None:
        if not s["launches"]:
            reason = no_launch
        elif not any(l["task"] == t["id"] for l in s["launches"]):
            reason = "このタスクに結び付いた担当の起動が無い"
        else:
            reason = "担当の起動の開始時刻か終了時刻が無い"
        start = end = total = ai = wait = na(reason)
    else:
        start, end, total = e(span["start"]), e(span["end"]), e(hhmmss(span["seconds"]))
        if span["wait_seconds"] is None:
            reason = script_reason(s, "所要時間の内訳（AIの作業時間、待機時間）") or no_launch
            ai = wait = na(reason)
        else:
            ai, wait = e(hhmmss(span["ai_seconds"])), e(hhmmss(span["wait_seconds"]))
    r, overall_reason, user_reason = rework
    count = num(r["total"]) + "回" if r["total"] is not None else na(overall_reason or user_reason)
    return [
        ("状態", or_na(d, "tasks[%d].state" % i, t["state"])),
        ("開始日時", start),
        ("完了日時", end),
        ("所要時間（トータル）", total),
        ("所要時間（AI）", ai),
        ("所要時間（待機時間）", wait),
        ("差戻回数", count),
        ("依存", depends_text(d, i, t)),
    ]


def depends_text(d, i, t):
    """依存の値。依存するタスクがあればそのIDの並び、dependsが[]なら「なし」、nullなら「不明」と理由。"""
    if t["depends"] is None:
        return na(why(d, "tasks[%d].depends" % i))
    return e("、".join(t["depends"])) if t["depends"] else "なし"


def launch_rows(l):
    """担当の表の行（役割、agent、model、effort）。"""
    if l["effort"] is None:
        effort = na("サブエージェントの記録が無い")
    elif not l["effort"]:
        effort = na("サブエージェントの記録にeffortが無い")
    else:
        effort = e("、".join(l["effort"]))
    return [
        ("役割", e(ROLE_LABEL[l["role"]])),
        ("agent", e(l["agent_type"]) if l["agent_type"] else na("記録にエージェントの種類が無い")),
        ("model", e(l["model"]) if l["model"] else na("記録にモデルが無い")),
        ("effort", effort),
    ]


def launch_rounds(ls):
    """担当の起動（時刻の順）を組に分ける。評価者の起動の後に来る実行者の起動で新しい組を始め、評価者の起動の前に続く実行者の起動は同じ組に入れる。
    最初の実行者の起動より前の評価者の起動は初回の組に入れる。"""
    rounds = [[]]
    for l in ls:
        cur = rounds[-1]
        if l["role"] == "worker" and cur and cur[-1]["role"] != "worker" and any(x["role"] == "worker" for x in cur):
            rounds.append([])
        rounds[-1].append(l)
    return rounds


def task_list_section(d, no_launch):
    s = d["script"]
    if not d["tasks"]:
        return ['<p class="muted">タスク：なし</p>']
    rework_rows, overall_reason, user_reason = task_rework(d)
    out = []
    for i, (t, r) in enumerate(zip(d["tasks"], rework_rows)):
        out.append('<h3 id="task-%s">%s %s</h3>' % (e(t["id"]), e(t["id"]), e(t["name"])))
        out.append('<div class="task">')
        out.append("<p>%s</p>" % or_na(d, "tasks[%d].work" % i, t["work"], pre))
        out.append('<div class="task-cols">')
        out.append("<div><h4>タスク</h4>%s</div>" % info_table(task_rows(d, i, t, (r, overall_reason, user_reason), no_launch)))
        out.append('<div class="launch-col"><h4>担当</h4>')
        ls = [l for l in s["launches"] if l["task"] == t["id"]]
        if not ls:
            out.append("<p>担当の起動：%s</p>" % na(no_launch if not s["launches"] else "このタスクに結び付いた担当の起動が無い"))
        else:
            for n, rl in enumerate(launch_rounds(ls)):
                if n:
                    out.append("<h5>差戻%d</h5>" % n)
                out.append('<div class="launches">%s</div>' % "".join(info_table(launch_rows(l)) for l in rl))
        out.append("</div>")
        out.append("</div>")
        out.append("<ul><li>成果物：%s</li><li>変えてよい範囲：%s</li></ul>" % (
            or_na(d, "tasks[%d].deliverables" % i, t["deliverables"], pre), or_na(d, "tasks[%d].scope" % i, t["scope"], pre)))
        out.append("</div>")
    return out


def review_section(d, sm):
    out = []
    out.append('<h3 id="rework">差し戻し</h3>')
    out.append(notes(["タスクごとの差し戻しの回数：そのタスクのレビューの判定が差し戻しの数、全体レビューの差し戻しで"
                      "そのタスクが差し戻された数、利用者レビューの差し戻しでそのタスクが差し戻された数の合計"]))
    rework_rows, overall_reason, user_reason = task_rework(d)
    items = []
    for r in rework_rows:
        total = num(r["total"]) + "回" if r["total"] is not None else na(overall_reason or user_reason)
        items.append("<li>%s：差し戻し%s（タスクのレビュー%s回、全体レビュー%s、利用者レビュー%s）、レビュー%s回</li>" % (
            e(r["id"]), total, num(r["review"]),
            num(r["overall"]) + "回" if r["overall"] is not None else na(overall_reason),
            num(r["user"]) + "回" if r["user"] is not None else na(user_reason), num(r["reviews"])))
    out.append("<ul>%s</ul>" % "".join(items) if items else '<p class="muted">タスク：なし</p>')
    out.append("<ul><li>全体レビュー：%s回</li><li>完了から実行中に戻した回数：%s</li><li>対応方針の変更：%s</li></ul>" % (
        num(sm["overall_reviews"]), or_na(d, "reopened", d["reopened"], lambda v: num(v) + "回"),
        or_na(d, "policy_changes", d["policy_changes"], lambda v: num(v) + "回")))

    out.append('<h3 id="reasons">差し戻しの理由</h3>')
    sent_back = [(i, r) for i, r in enumerate(d["reviews"]) if r["verdict"] == "差し戻し"]
    if not sent_back:
        out.append("<p>判定が差し戻しのレビュー：なし</p>")
    else:
        out.append("<ul>%s</ul>" % "".join(
            "<li>%s（指摘%s）：%s</li>" % (
                e(review_label(r)), or_na(d, "reviews[%d].findings" % i, r["findings"], lambda v: num(v) + "件"),
                "、".join(e(f) for f in r["failed_conditions"]) or '<span class="muted">落ちた完了条件の記載なし</span>')
            for i, r in sent_back))
    out.append('<details class="sub"><summary>レビューの一覧（%d件）</summary><ul>%s</ul></details>' % (len(d["reviews"]), "".join(
        "<li>%s：%s。指摘%s、提案%s</li>" % (
            e(review_label(r)), or_na(d, "reviews[%d].verdict" % i, r["verdict"]),
            or_na(d, "reviews[%d].findings" % i, r["findings"], lambda v: num(v) + "件"),
            or_na(d, "reviews[%d].proposals" % i, r["proposals"], lambda v: num(v) + "件"))
        for i, r in enumerate(d["reviews"])) or '<li class="muted">なし</li>'))

    out.append('<h3 id="rulings">裁定</h3>')
    if d["rulings"] is None:
        out.append("<p>裁定の回数：%s</p>" % na(why(d, "rulings")))
    else:
        out.append("<p>裁定の回数：%d件</p>" % len(d["rulings"]))
        if d["rulings"]:
            out.append("<ul>%s</ul>" % "".join(
                "<li>%s%s：%s</li>" % (or_na(d, "rulings[%d].time" % i, r["time"]), "（評価者の提案を採り入れた）" if r["adopted_proposal"] else "",
                                     pre(r["text"])) for i, r in enumerate(d["rulings"])))

    out.append('<h3 id="proposals">評価者の提案</h3>')
    if sm["proposals"] is not None:
        proposals_html = num(sm["proposals"]) + "件"
    else:
        proposals_html = e(num(sm["proposals_known"])) + "件（提案の数が不明のレビューを除く）"
    pa = d["proposals_adopted"]
    adopted = (num(pa["count"]) + "件（根拠：%s）" % pre(pa["basis"])) if pa else na(why(d, "proposals_adopted"))
    out.append("<ul><li>評価者の提案の数（レビューの一覧の合計）：%s</li><li>採り入れた提案の数：%s</li></ul>" % (proposals_html, adopted))

    out.append('<h3 id="change">成果物の変更量</h3>')
    ch = d["change"]
    change_html = (change_text(*change_parts(d), unknown=lambda k: na(why(d, "change." + k))) + "（根拠：%s）" % pre(ch["basis"])) if ch \
        else na(why(d, "change"))
    out.append("<ul><li>変更量：%s</li><li>報告の「変更したファイル」を合わせたファイル数：%sファイル</li></ul>" % (change_html, num(len(sm["changed_files"]))))
    if d["reports"]:
        out.append('<details class="sub"><summary>報告の一覧（%d件）</summary><ul>%s</ul></details>' % (len(d["reports"]), "".join(
            "<li>%sの報告（%s回目）：%s。変更したファイル%s件</li>" % (e(r["task"]), num(r["n"]), or_na(d, "reports[%d].conclusion" % i, r["conclusion"]),
                                                    num(len(r["changed_files"]))) for i, r in enumerate(d["reports"]))))
    if sm["changed_files"]:
        out.append('<details class="sub"><summary>報告に書かれた変更したファイル（%d件）</summary><ul>%s</ul></details>'
                   % (len(sm["changed_files"]), "".join("<li><code>%s</code></li>" % e(f) for f in sm["changed_files"])))

    out.append('<h3 id="unknown">取れなかった指標</h3>')
    items = ["<li>%s：%s（実施者が案件ファイルから取れなかった）</li>" % (e(item_label(u["item"])), e(u["reason"])) for u in d["unknown"]]
    items += ["<li>%s：%s（スクリプトがセッション記録と単価表から取れなかった）</li>" % (e(u["item"]), e(u["reason"])) for u in d["script"]["unknown"]]
    out.append("<ul>%s</ul>" % "".join(items) if items else "<p>なし</p>")
    return out


def case_html(d):
    s = d["script"]
    sm = summary(d)
    no_launch = no_launch_reason(s["session_dir_exists"])
    dur = s["durations"]
    parts = []
    parts.append('<nav><a href="index.html">案件一覧へ</a></nav>')
    parts.append("<h1>%s</h1>" % e(d["title"]))
    parts.append('<p class="muted">案件：%s、生成日時：%s</p>' % (e(s["case"]), e(s["generated_at"])))

    parts.append('<h2 id="overview">概要</h2>')
    parts.append("<p>%s</p>" % or_na(d, "purpose", d["purpose"], pre))

    parts.append('<h2 id="basic">基本情報</h2>')
    total, ai, wait = case_durations(d, no_launch)
    if d["finished"] is None and dur.get("span_seconds") is not None:
        total += '<span class="muted">（可視化した日時まで）</span>'
    branches = s.get("branches")
    row = '<tr><th colspan="2">%s</th><td>%s</td></tr>'
    parts.append('<table class="info"><tbody>%s</tbody></table>' % "".join([
        row % ("状態", or_na(d, "state", d["state"])),
        row % ("着手日時", or_na(d, "started", d["started"])),
        row % ("完了日時", e(d["finished"]) if d["finished"] is not None else "（実行中）"),
        '<tr><th rowspan="3">所要時間</th><th>全体</th><td>%s</td></tr>' % total,
        "<tr><th>AI</th><td>%s</td></tr>" % ai,
        "<tr><th>待機</th><td>%s</td></tr>" % wait,
        row % ("セッションID", one_or_list(s["sessions"]) if s["sessions"] else na(no_launch)),
        row % ("作業ブランチ", one_or_list(branches) if branches else na(script_reason(s, "作業ブランチ") or no_launch)),
    ]))

    parts.append('<h2 id="cost">費用</h2>')
    if s["tokens"] is None or s["cost"] is None:
        parts.append("<p>トークン量と費用：%s</p>" % na(no_launch))
    else:
        parts.extend(cost_charts(d))

    parts.append('<h2 id="process">処理</h2>')
    parts.extend(process_section(d, no_launch))

    parts.append('<details class="section" id="tasks"><summary><h2>タスク一覧</h2></summary>')
    parts.extend(task_list_section(d, no_launch))
    parts.append("</details>")

    parts.append('<details class="section" id="review"><summary><h2>レビューと差し戻し</h2></summary>')
    parts.extend(review_section(d, sm))
    parts.append("</details>")
    return page("%s の可視化" % s["case"], "\n".join(parts), CASE_CSS)


# ---- 一覧のHTML ----

INDEX_METRICS = [
    ("total_tokens", "トークン量の合計", num),
    ("total_usd", "費用（USD）", usd),
    ("case_seconds", "所要時間", hms),
    ("tasks", "タスク数", num),
    ("launches_worker", "実行者の起動回数", num),
    ("launches_reviewer", "評価者の起動回数", num),
    ("launches_overall", "全体レビューの起動回数", num),
    ("rework", "差し戻し回数", num),
    ("overall_reviews", "全体レビューの回数", num),
    ("reopened", "完了から実行中に戻した回数", num),
    ("rulings", "裁定の回数", num),
    ("policy_changes", "対応方針の変更の回数", num),
    ("proposals", "評価者の提案の数", num),
    ("proposals_adopted", "採り入れた提案の数", num),
    ("change_files", "変更量（ファイル数）", num),
]


def index_html(cases):
    parts = ["<h1>案件の一覧</h1>", '<p class="muted">%d件。各案件の表題から、その案件の可視化を開ける。</p>' % len(cases)]
    parts.append('<h2 id="list">一覧</h2>')
    parts.append(table(["", "表題", "案件", "状態", "着手日時", "完了日時"], [
        [num(i), '<a href="%s.html">%s</a>' % (e(c["script"]["case"]), e(c["title"])), e(c["script"]["case"]),
         e(c["state"]) if c["state"] is not None else '<span class="na">不明</span>',
         e(c["started"]) if c["started"] is not None else '<span class="na">不明</span>',
         e(c["finished"]) if c["finished"] is not None else '<span class="na">不明</span>']
        for i, c in enumerate(cases, 1)], num_cols=(0,)))
    sums = [(c["script"]["case"], c["title"] or c["script"]["case"], summary(c)) for c in cases]
    parts.append('<details class="section" id="charts"><summary>指標の比較</summary>')
    parts.append("<p>案件名から、その案件の可視化を開ける。「不明」の理由は各案件のページの「取れなかった指標」にある。</p>")
    for key, label, f in INDEX_METRICS:
        parts.append("<h3>%s</h3>" % e(label))
        parts.append(bar_chart([(name, s.get(key), "%s.html" % name, title) for name, title, s in sums], f))
        if key == "total_usd":
            excluded = [name for name, _, s in sums if s["cost_excludes_unknown"]]
            if excluded:
                parts.append("<p>次の案件の費用は、単価が分からないモデルの分を除いた値である：%s。</p>" % e("、".join(excluded)))
        if key == "change_files":
            parts.append("<p>案件ごとの変更量（ファイル数、追加行数、削除行数）：</p><ul>%s</ul>" % "".join(
                "<li>%s：%s</li>" % (e(name), change_text(s["change_files"], s["change_added"], s["change_removed"],
                                                          lambda k: '<span class="na">不明</span>'))
                for name, _, s in sums))
    parts.append("</details>")
    return page("案件の一覧", "\n".join(parts))
