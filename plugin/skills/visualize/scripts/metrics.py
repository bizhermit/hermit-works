"""実施者が書いた<案件>.jsonの値と、セッション記録と単価表から、スクリプトが書き足す項目（scriptの下）を組み立てる。

案件ファイルは読まない。
"""

from datetime import datetime, timedelta

from json_format import DT_FMT, parse_dt
from session_log import TOKEN_KEYS, add_tokens, empty_tiers, empty_tokens, merge_tiers

STALL_SECONDS = 600
ROLE_OF_KIND = {"worker": "worker", "report": "worker", "reviewer": "reviewer", "review": "reviewer"}
NO_SESSION = "セッション記録が無い"
NO_LAUNCH = "案件に結び付く担当の起動が無い"
NO_PRICING = "単価表が無い"
NOT_IN_PRICING = "単価表に無いモデル"
NO_STARTED = "着手日時が不明"
NO_BRANCH = "案件の期間内の記録にgitBranchが無い"


def no_launch_reason(session_dir_exists):
    """結び付いた担当の起動が無いときの理由。セッション記録のディレクトリの有無で分ける。"""
    return NO_LAUNCH if session_dir_exists else NO_SESSION


def fmt(dt):
    return dt.strftime(DT_FMT) if dt else None


def merge_tokens(dst, src):
    for model, t in src.items():
        add_tokens(dst, model, t)


def token_total(by_model):
    t = empty_tokens()
    for v in by_model.values():
        for k in TOKEN_KEYS:
            t[k] += v[k]
    return t


def cost_of(tokens, price):
    return (
        tokens["input"] * price["input"]
        + tokens["output"] * price["output"]
        + tokens["cache_creation_5m"] * price["cache_write_5m"]
        + tokens["cache_creation_1h"] * price["cache_write_1h"]
        + tokens["cache_read"] * price["cache_read"]
    ) / 1000000


def compute_cost(by_model, pricing):
    rows = {}
    total = 0.0
    excluded = []
    for model, t in sorted(by_model.items()):
        price = pricing.get("models", {}).get(model) if pricing else None
        if pricing is None:
            rows[model] = {"usd": None, "reason": NO_PRICING}
            excluded.append(model)
        elif price is None:
            rows[model] = {"usd": None, "reason": NOT_IN_PRICING}
            excluded.append(model)
        else:
            usd = cost_of(t, price)
            rows[model] = {"usd": usd, "reason": None}
            total += usd
    priced = [m for m, r in rows.items() if r["usd"] is not None]
    return {
        "by_model": rows,
        "total_usd": total if priced else None,
        "excluded_models": excluded,
        "as_of": (pricing or {}).get("as_of"),
        "source": (pricing or {}).get("source"),
        "unit": (pricing or {}).get("unit"),
    }


def priced_usd(by_model, pricing):
    """単価表にあるモデルの費用の和。トークンが無ければ0、費用を求められるモデルが無ければNone。"""
    if not by_model:
        return 0.0
    prices = (pricing or {}).get("models", {})
    priced = [cost_of(t, prices[m]) for m, t in by_model.items() if m in prices]
    return sum(priced) if priced else None


def overlaps(a0, a1, b0, b1):
    return a0 < b1 and b0 < a1


def record_dir_key(s):
    """記録のディレクトリ（tasks/<NN>_<slug>/）から<NN>_<slug>を取り出す。"""
    s = (s or "").strip().strip("/")
    if s.startswith("tasks/"):
        s = s[len("tasks/"):]
    return s or None


def period_end(finished, now):
    """記録を数えるかの判定に使う案件の期間の終わり（この時刻を含まない）。完了日時があれば完了日時に1秒を足した時刻、無ければnow。"""
    return finished + timedelta(seconds=1) if finished else now


def case_launches(project_log, name, started, finished, now):
    """書き先のパスで案件に結び付いた担当の起動のうち、起動の時刻が着手日時以上、期間の終わり（period_end）未満のもの。
    着手日時が無ければ、書き先のパスで結び付いたものをすべて返す。"""
    raw = project_log.launches.get(name, []) if project_log.exists else []
    if started is None:
        return list(raw)
    end = period_end(finished, now)
    return [l for l in raw if l["start"] is not None and started <= l["start"] < end]


def build(name, case, project_dir, project_log, pricing, pricing_path, others, now=None):
    """scriptの下に書く辞書を返す。

    name: 案件名。case: 実施者が書いた<案件>.json。others: 他の案件の(案件名, 着手日時, 完了日時)の並び。
    """
    now = now or datetime.now().astimezone()
    unknown = []

    def note(item, reason):
        unknown.append({"item": item, "reason": reason})

    started = parse_dt(case["started"])
    finished = parse_dt(case["finished"])
    end_excl = period_end(finished, now)

    # 担当の起動（書き先のパスと期間で案件に結び付ける）
    raw = case_launches(project_log, name, started, finished, now)
    if started is None:
        note("担当の起動の結び付け", "着手日時が不明（期間の条件を使わず、書き先のパスだけで結び付けた）")
    dir_to_task = {}
    for t in case["tasks"]:
        key = record_dir_key(t["record_dir"])
        if key:
            dir_to_task[key] = t["id"]
    launches = []
    unmatched_dirs = set()
    for l in sorted(raw, key=lambda x: (x["start"] or now)):
        if l["task_dir"] is None:
            role = "overall"
            task = None
        else:
            role = ROLE_OF_KIND[l["kind"]]
            task = dir_to_task.get(l["task_dir"])
            if task is None:
                unmatched_dirs.add(l["task_dir"])
                if l["task_dir"][:2].isdigit():
                    task = "T%d" % int(l["task_dir"].split("_")[0])
        sub = project_log.subagent_usage(l["session"], l["agent_id"])
        duration_ms = l["duration_ms"]
        source = l["duration_source"]
        if duration_ms is None and sub and sub["first"] and sub["last"]:
            duration_ms = int((sub["last"] - sub["first"]).total_seconds() * 1000)
            source = "サブエージェントの記録の最初と最後の時刻"
        end = None
        if l["start"] and duration_ms is not None:
            end = l["start"] + timedelta(milliseconds=duration_ms)
        elif sub and sub["last"]:
            end = sub["last"]
        model = l["resolved_model"] or ("、".join(sub["models"]) if sub and sub["models"] else None)
        agent_type = l["subagent_type"] or project_log.subagent_type(l["session"], l["agent_id"])
        launches.append({
            "task": task,
            "role": role,
            "n": l["n"],
            "start": fmt(l["start"]),
            "end": fmt(end),
            "duration_ms": duration_ms,
            "duration_source": source,
            "model": model,
            "agent_type": agent_type,
            "effort": sub["efforts"] if sub else None,
            "tokens": sub["tokens"] if sub else None,
            "tokens_reason": None if sub else "サブエージェントの記録が無い",
            "session": l["session"],
            "tool_use_id": l["tool_use_id"],
            "agent_id": l["agent_id"],
            "subagent_type": l["subagent_type"],
            "record_dir": l["task_dir"],
            "file": l["file"],
            "_start": l["start"],
            "_end": end,
            "_tiers": sub["tiers"] if sub else None,
        })
    for key in sorted(unmatched_dirs):
        note("担当の起動の記録のディレクトリ tasks/%s/" % key, "tasksのrecord_dirに結び付かない（ディレクトリ名の番号からタスクのIDを当てた）")
    has_session = bool(launches)
    sessions = sorted({l["session"] for l in launches})
    if not has_session:
        for m in ("トークン量", "費用", "担当の起動回数", "担当の起動ごとの所要時間", "タスクごとの所要時間",
                  "時系列の担当の起動", "止まっていた区間", "並列か直列か"):
            note(m, no_launch_reason(project_log.exists))

    # トークン量（役割別とタスク別）
    tokens = None
    task_tokens = None
    non_standard = None
    if has_session:
        tokens = {"orchestrator": {}, "worker": {}, "reviewer": {}}
        task_tokens = {}
        non_standard = empty_tiers()
        for l in launches:
            if l["tokens"] is None:
                continue
            merge_tiers(non_standard, l["_tiers"])
            role = "worker" if l["role"] == "worker" else "reviewer"
            merge_tokens(tokens[role], l["tokens"])
            key = l["task"] or "全体レビュー"
            per = task_tokens.setdefault(key, {"worker": {}, "reviewer": {}})
            merge_tokens(per[role], l["tokens"])
        if started:
            orch = project_log.orchestrator_usage(sessions, started, end_excl)
            tokens["orchestrator"] = orch["tokens"]
            merge_tiers(non_standard, orch["tiers"])
        else:
            note("統括のトークン量", NO_STARTED)
        missing = [l["file"] for l in launches if l["tokens"] is None]
        if missing:
            note("一部の担当の起動のトークン量", "サブエージェントの記録が無い（%d件）" % len(missing))
            note("一部の担当の起動のeffort", "サブエージェントの記録が無い（%d件）" % len(missing))
        no_effort = [l for l in launches if l["effort"] == []]
        if no_effort:
            note("一部の担当の起動のeffort", "サブエージェントの記録にeffortが無い（%d件）" % len(no_effort))
        no_type = [l for l in launches if l["agent_type"] is None]
        if no_type:
            note("一部の担当の起動のエージェントの種類", "記録にエージェントの種類が無い（%d件）" % len(no_type))
    tokens_by_model = None
    if tokens is not None:
        tokens_by_model = {}
        for v in tokens.values():
            merge_tokens(tokens_by_model, v)

    # 費用
    cost = None
    if has_session:
        cost = compute_cost(tokens_by_model, pricing)
        cost["by_role"] = {role: priced_usd(v, pricing) for role, v in tokens.items()}
        cost["by_task"] = {key: {role: priced_usd(v, pricing) for role, v in per.items()} for key, per in task_tokens.items()}
        if pricing is None:
            note("費用", NO_PRICING)
        elif cost["excluded_models"]:
            note("一部のモデルの費用", "%s（%s）" % (NOT_IN_PRICING, "、".join(cost["excluded_models"])))

    # 統括の期間が重なる案件（他の案件の着手日時と完了日時は、出力先の他の<案件>.jsonから取る）
    overlap_cases = []
    if has_session and started:
        for other, s1, e1 in others:
            if other == name or s1 is None:
                continue
            other_sessions = {x["session"] for x in case_launches(project_log, other, s1, e1, now)}
            if overlaps(started, end_excl, s1, period_end(e1, now)) and other_sessions & set(sessions):
                overlap_cases.append(other)

    # タスクごとの起動回数
    launch_counts = None
    if has_session:
        launch_counts = {"worker": 0, "reviewer": 0, "overall": 0, "tasks": {}}
        for l in launches:
            launch_counts[l["role"]] += 1
    for t in case["tasks"]:
        ls = [l for l in launches if l["task"] == t["id"]]
        if has_session:
            launch_counts["tasks"][t["id"]] = {"worker": sum(1 for l in ls if l["role"] == "worker"),
                                               "reviewer": sum(1 for l in ls if l["role"] == "reviewer")}

    # 時系列：並列、止まっていた区間
    parallel = None
    stalls = None
    if has_session:
        pairs = set()
        tl = [l for l in launches if l["task"] and l["_start"] and l["_end"]]
        for i, a in enumerate(tl):
            for b in tl[i + 1:]:
                if a["task"] != b["task"] and overlaps(a["_start"], a["_end"], b["_start"], b["_end"]):
                    pairs.add(tuple(sorted((a["task"], b["task"]))))
        parallel = {"parallel": bool(pairs), "pairs": [list(p) for p in sorted(pairs)]}
        ivs = sorted((l["_start"], l["_end"]) for l in launches if l["_start"] and l["_end"])
        lo = started or (ivs[0][0] if ivs else None)
        hi = finished or now
        stalls = []
        cur = lo
        for s, e in ivs + [(hi, hi)]:
            if cur and s and (s - cur).total_seconds() >= STALL_SECONDS:
                stalls.append({"start": fmt(cur), "end": fmt(s), "seconds": int((s - cur).total_seconds())})
            if e and (cur is None or e > cur):
                cur = e

    # 案件全体の所要時間
    case_seconds = None
    if started and finished:
        case_seconds = int((finished - started).total_seconds())
    elif not started:
        note("案件全体の所要時間", NO_STARTED)
    else:
        note("案件全体の所要時間", "完了日時が無い（未完了または不明）")

    # 所要時間の内訳（待機時間とAIの作業時間）と作業ブランチ
    span_seconds = None
    wait_seconds = None
    ai_seconds = None
    wait_intervals = None
    wait_ivs = []
    branches = None
    if started:
        # 時間の長さ（全体、待機の区間の切り取り、AIの作業時間）は着手日時から完了日時（無ければnow）までで測る
        span_end = finished or now
        span_seconds = int((span_end - started).total_seconds())
    if not has_session:
        note("所要時間の内訳（AIの作業時間、待機時間）", no_launch_reason(project_log.exists))
        note("作業ブランチ", no_launch_reason(project_log.exists))
    elif not started:
        note("所要時間の内訳（AIの作業時間、待機時間）", NO_STARTED)
        note("作業ブランチ", NO_STARTED)
    else:
        wait_ivs = project_log.wait_intervals(sessions, started, span_end)
        wait_intervals = [{"start": fmt(a), "end": fmt(b), "seconds": int((b - a).total_seconds())} for a, b in wait_ivs]
        wait_seconds = int(sum((b - a).total_seconds() for a, b in wait_ivs))
        ai_seconds = span_seconds - wait_seconds
        branches = project_log.branches(sessions, started, end_excl)
        if not branches:
            branches = None
            note("作業ブランチ", NO_BRANCH)

    # タスクごとの所要時間（秒未満を切り捨てた最初の起動の開始から最後の起動の終わりまで。待機時間はその区間と待機の区間が重なる時間の和）
    task_durations = {}
    for t in case["tasks"]:
        ls = [l for l in launches if l["task"] == t["id"]]
        a = ls[0]["_start"].replace(microsecond=0) if ls and ls[0]["_start"] else None
        b = ls[-1]["_end"].replace(microsecond=0) if ls and ls[-1]["_end"] else None
        span = None
        if a and b:
            span = {"start": fmt(a), "end": fmt(b), "seconds": int((b - a).total_seconds()),
                    "ai_seconds": None, "wait_seconds": None}
            if wait_intervals is not None:
                overlap = sum(max(0.0, (min(b, wb) - max(a, wa)).total_seconds()) for wa, wb in wait_ivs)
                span["wait_seconds"] = int(overlap)
                span["ai_seconds"] = span["seconds"] - span["wait_seconds"]
        task_durations[t["id"]] = span

    for l in launches:
        l.pop("_start")
        l.pop("_end")
        l.pop("_tiers")

    total_tokens = None
    if tokens_by_model is not None:
        tt = token_total(tokens_by_model)
        total_tokens = tt["input"] + tt["output"] + tt["cache_creation"] + tt["cache_read"]

    return {
        "generated_at": fmt(now),
        "case": name,
        "project_dir": project_dir,
        "session_dir": project_log.log_dir,
        "session_dir_exists": project_log.exists,
        "sessions": sessions,
        "pricing_path": pricing_path if pricing is not None else None,
        "launches": launches,
        "launch_counts": launch_counts,
        "tokens": tokens,
        "tokens_by_model": tokens_by_model,
        "task_tokens": task_tokens,
        "total_tokens": total_tokens,
        "cost": cost,
        "non_standard_calls": non_standard,
        "durations": {"case_seconds": case_seconds, "tasks": task_durations, "span_seconds": span_seconds,
                      "wait_seconds": wait_seconds, "ai_seconds": ai_seconds, "wait_intervals": wait_intervals},
        "branches": branches,
        "overlap_cases": overlap_cases,
        "parallel": parallel,
        "stalls": stalls,
        "unknown": unknown,
    }
