"""<案件>.jsonのうち、実施者が書く項目の形を確かめる。形の定めはjson-format.mdにある。

スクリプトが書き足す項目（scriptの下）は確かめない。
"""

import re
from datetime import datetime

DT_FMT = "%Y-%m-%d %H:%M:%S"
DT_RE = re.compile(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$")
OVERALL = "全体"
VERDICTS = ("承認", "差し戻し")
PHASE_NAMES = ("対応方針の作成", "計画", "対応方針の変更", "依頼元への問い", "全体レビュー", "利用者レビュー")


class F:
    """一つの項目の形。kindはstr、int、bool、datetime、list、object、enumのいずれか。"""

    def __init__(self, kind, null=False, items=None, fields=None, choices=None):
        self.kind = kind
        self.null = null
        self.items = items
        self.fields = fields
        self.choices = choices


TASK = {
    "id": F("str"),
    "name": F("str"),
    "depends": F("list", null=True, items=F("str")),
    "state": F("str", null=True),
    "work": F("str", null=True),
    "deliverables": F("str", null=True),
    "scope": F("str", null=True),
    "record_dir": F("str", null=True),
}
RULING = {
    "time": F("datetime", null=True),
    "text": F("str"),
    "adopted_proposal": F("bool"),
}
PROGRESS = {
    "time": F("datetime", null=True),
    "text": F("str"),
}
REVIEW = {
    "target": F("str"),
    "n": F("int"),
    "verdict": F("enum", null=True, choices=VERDICTS),
    "failed_conditions": F("list", items=F("str")),
    "findings": F("int", null=True),
    "proposals": F("int", null=True),
}
REPORT = {
    "task": F("str"),
    "n": F("int"),
    "conclusion": F("str", null=True),
    "changed_files": F("list", items=F("str")),
}
UNKNOWN = {
    "item": F("str"),
    "reason": F("str"),
}
OVERALL_SENDBACK = {
    "n": F("int"),
    "tasks": F("list", null=True, items=F("str")),
}
USER_SENDBACK = {
    "time": F("datetime", null=True),
    "tasks": F("list", null=True, items=F("str")),
}
PHASE = {
    "name": F("enum", choices=PHASE_NAMES),
    "start": F("datetime", null=True),
    "end": F("datetime", null=True),
}
CASE = {
    "title": F("str"),
    "state": F("str", null=True),
    "started": F("datetime", null=True),
    "finished": F("datetime", null=True),
    "purpose": F("str", null=True),
    "phases": F("list", items=F("object", fields=PHASE)),
    "tasks": F("list", items=F("object", fields=TASK)),
    "rulings": F("list", null=True, items=F("object", fields=RULING)),
    "policy_changes": F("int", null=True),
    "progress": F("list", null=True, items=F("object", fields=PROGRESS)),
    "reviews": F("list", items=F("object", fields=REVIEW)),
    "reports": F("list", items=F("object", fields=REPORT)),
    "reopened": F("int", null=True),
    "overall_sendbacks": F("list", null=True, items=F("object", fields=OVERALL_SENDBACK)),
    "user_sendbacks": F("list", null=True, items=F("object", fields=USER_SENDBACK)),
    "proposals_adopted": F("object", null=True, fields={"count": F("int"), "basis": F("str")}),
    "change": F("object", null=True, fields={"files": F("int", null=True), "added": F("int", null=True),
                                             "removed": F("int", null=True), "basis": F("str")}),
    "unknown": F("list", items=F("object", fields=UNKNOWN)),
}

KIND_LABEL = {
    "str": "文字列",
    "int": "0以上の整数",
    "bool": "真偽（trueまたはfalse）",
    "datetime": "YYYY-MM-DD HH:MM:SSの形の文字列",
    "list": "配列",
    "object": "オブジェクト",
}


def type_name(v):
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "真偽"
    if isinstance(v, int):
        return "整数"
    if isinstance(v, float):
        return "小数"
    if isinstance(v, str):
        return "文字列"
    if isinstance(v, list):
        return "配列"
    if isinstance(v, dict):
        return "オブジェクト"
    return type(v).__name__


def is_datetime(v):
    if not isinstance(v, str) or not DT_RE.match(v):
        return False
    try:
        datetime.strptime(v, DT_FMT)
    except ValueError:
        return False
    return True


def check_value(f, v, path, errors, nulls):
    if v is None:
        if f.null:
            nulls.append(path)
        else:
            errors.append("型が違う: %s（%sを書く。nullは書けない）" % (path, KIND_LABEL.get(f.kind, "選択肢のいずれか")))
        return
    if f.kind == "str":
        ok = isinstance(v, str)
    elif f.kind == "int":
        ok = isinstance(v, int) and not isinstance(v, bool) and v >= 0
    elif f.kind == "bool":
        ok = isinstance(v, bool)
    elif f.kind == "datetime":
        ok = is_datetime(v)
    elif f.kind == "enum":
        if v not in f.choices:
            errors.append("選択肢の外: %s（%sのいずれかを書く。今は%r）" % (path, "、".join(f.choices), v))
        return
    elif f.kind == "list":
        ok = isinstance(v, list)
    else:
        ok = isinstance(v, dict)
    if not ok:
        errors.append("型が違う: %s（%sを書く。今は%s）" % (path, KIND_LABEL[f.kind], type_name(v)))
        return
    if f.kind == "list":
        for i, x in enumerate(v):
            check_value(f.items, x, "%s[%d]" % (path, i), errors, nulls)
    elif f.kind == "object":
        check_fields(f.fields, v, path + ".", errors, nulls)


def check_fields(fields, obj, prefix, errors, nulls):
    for key, f in fields.items():
        path = prefix + key
        if key not in obj:
            errors.append("必須の項目が無い: %s" % path)
            continue
        check_value(f, obj[key], path, errors, nulls)


def validate(data):
    """実施者が書く項目の形を確かめ、誤りの文の並びを返す。誤りが無ければ空の並び。"""
    if not isinstance(data, dict):
        return ["型が違う: 全体（オブジェクトを書く。今は%s）" % type_name(data)]
    errors = []
    nulls = []
    check_fields(CASE, data, "", errors, nulls)
    if errors:
        return errors
    # nullにした項目は、unknownに項目名と理由がある
    explained = {u["item"] for u in data["unknown"]}
    for path in nulls:
        if path not in explained:
            errors.append("nullにした項目がunknownに無い: %s（unknownに{\"item\": \"%s\", \"reason\": \"<理由>\"}を書く）" % (path, path))
    # changeの三つがすべてnullなら、change全体をnullにする
    ch = data["change"]
    if ch is not None and ch["files"] is None and ch["added"] is None and ch["removed"] is None:
        errors.append("changeの三つともnull: change（files、added、removedの三つともnullなら、change全体をnullにし、"
                      "unknownに{\"item\": \"change\", \"reason\": \"<理由>\"}を書く）")
    # タスクのIDの参照
    ids = [t["id"] for t in data["tasks"]]
    seen = set()
    for i, tid in enumerate(ids):
        if tid in seen:
            errors.append("タスクのIDが重なる: tasks[%d].id（%s）" % (i, tid))
        seen.add(tid)
    for i, t in enumerate(data["tasks"]):
        for j, d in enumerate(t["depends"] or []):
            if d not in seen:
                errors.append("tasksに無いタスクのID: tasks[%d].depends[%d]（%s）" % (i, j, d))
    for i, r in enumerate(data["reviews"]):
        if r["target"] != OVERALL and r["target"] not in seen:
            errors.append("tasksに無いタスクのID: reviews[%d].target（%s。タスクのIDか「%s」を書く）" % (i, r["target"], OVERALL))
    for i, r in enumerate(data["reports"]):
        if r["task"] not in seen:
            errors.append("tasksに無いタスクのID: reports[%d].task（%s）" % (i, r["task"]))
    for key in ("overall_sendbacks", "user_sendbacks"):
        for i, sb in enumerate(data[key] or []):
            for j, tid in enumerate(sb["tasks"] or []):
                if tid not in seen:
                    errors.append("tasksに無いタスクのID: %s[%d].tasks[%d]（%s）" % (key, i, j, tid))
    # overall_sendbacksは、判定が差し戻しの全体レビューごとに一つずつある
    if data["overall_sendbacks"] is not None:
        sent_back = {r["n"] for r in data["reviews"] if r["target"] == OVERALL and r["verdict"] == "差し戻し"}
        listed = set()
        for i, sb in enumerate(data["overall_sendbacks"]):
            if sb["n"] not in sent_back:
                errors.append("判定が差し戻しの全体レビューに無い回: overall_sendbacks[%d].n（%d。reviewsでtargetが「%s」、verdictが「差し戻し」のレビューのnを書く）" % (i, sb["n"], OVERALL))
            elif sb["n"] in listed:
                errors.append("全体レビューの回が重なる: overall_sendbacks[%d].n（%d）" % (i, sb["n"]))
            listed.add(sb["n"])
        for n in sorted(sent_back - listed):
            errors.append("判定が差し戻しの全体レビューがoverall_sendbacksに無い: overall_sendbacks（全体レビューの%d回目。{\"n\": %d, \"tasks\": [<差し戻したタスクのID>]}を書く）" % (n, n))
    # 依頼元の差し戻しは、そのたびに案件を実行中に戻すので、reopenedを超えない
    if data["user_sendbacks"] is not None and data["reopened"] is not None and len(data["user_sendbacks"]) > data["reopened"]:
        errors.append("reopenedより多い: user_sendbacks（%d件。reopenedは%d）" % (len(data["user_sendbacks"]), data["reopened"]))
    return errors


def parse_dt(s):
    """実施者が書いた日時（ローカル時刻）をタイムゾーン付きに直す。"""
    if not s:
        return None
    return datetime.strptime(s, DT_FMT).astimezone()
