"""Claude Codeのセッション記録（<設定ディレクトリ>/projects/<プロジェクト>/）を読む。

セッション記録には書き込まない。
"""

import glob
import json
import os
import re
from datetime import datetime

WRITE_RE = re.compile(
    r"\.hw/cases/([^/\s`'\"]+)/(?:tasks/([^/\s`'\"]+)/)?((worker|reviewer|report|review)-(\d+)\.md)"
)
DEST_HEAD_RE = re.compile(r"^#+\s*書き先\s*$", re.M)
NOTICE_ID_RE = re.compile(r"<tool-use-id>([^<]+)</tool-use-id>")
NOTICE_MS_RE = re.compile(r"<duration_ms>(\d+)</duration_ms>")

AUTO_TEXT_PREFIXES = ("<local-command-", "<command-name>", "<task-notification>", "<system-reminder>", "<ide_",
                      "[Request interrupted")
TOKEN_KEYS = ("input", "output", "cache_creation", "cache_creation_5m", "cache_creation_1h", "cache_read")
TIER_KEYS = ("service_tier", "speed")
STANDARD = "standard"


def project_log_dir(config_dir, project_dir):
    return os.path.join(config_dir, "projects", re.sub(r"[^A-Za-z0-9]", "-", project_dir))


def parse_ts(s):
    """ISO 8601のUTCの時刻を、実行環境のローカル時刻（タイムゾーン付き）に直す。"""
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone()
    except ValueError:
        return None


def iter_jsonl(path):
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if isinstance(d, dict):
                yield d


def find_destination(prompt):
    """担当へ渡した指示から書き先を当てる。「書き先」の見出しがあればその下の最初のパス、無ければ最後のパス。"""
    m = DEST_HEAD_RE.search(prompt)
    if m:
        w = WRITE_RE.search(prompt, m.end())
        if w:
            return w
    found = list(WRITE_RE.finditer(prompt))
    return found[-1] if found else None


def is_requester_utterance(d):
    """主会話の記録が依頼元の発言か。typeがuserで、isSidechain、isMeta、isCompactSummaryが真でなく、
    message.contentが文字列か、textのブロックを持ち、その文字列かtextのいずれかが自動の文の書き出しで始まらないもの。"""
    if d.get("type") != "user" or d.get("isSidechain") or d.get("isMeta") or d.get("isCompactSummary"):
        return False
    msg = d.get("message")
    content = msg.get("content") if isinstance(msg, dict) else None
    if isinstance(content, str):
        texts = [content]
    elif isinstance(content, list):
        texts = [b.get("text") or "" for b in content if isinstance(b, dict) and b.get("type") == "text"]
    else:
        return False
    return any(not t.lstrip().startswith(AUTO_TEXT_PREFIXES) for t in texts)


def main_events(records):
    """主会話の統括の応答（assistant）と依頼元の発言（human）を、記録の順に(時刻, 種類)の並びで返す。"""
    out = []
    for d in records:
        if d.get("isSidechain"):
            continue
        if d.get("type") == "assistant":
            kind = "assistant"
        elif is_requester_utterance(d):
            kind = "human"
        else:
            continue
        ts = parse_ts(d.get("timestamp"))
        if ts is not None:
            out.append((ts, kind))
    return out


def session_waits(events):
    """統括の応答の後、次の依頼元の発言までの区間を(始め, 終わり)の並びで返す。
    始めは、直前の依頼元の発言より後にある統括の応答のうち最後のものの時刻。"""
    out = []
    last_assistant = None
    for ts, kind in events:
        if kind == "assistant":
            last_assistant = ts
        else:
            if last_assistant is not None and ts > last_assistant:
                out.append((last_assistant, ts))
            last_assistant = None
    return out


def merge_intervals(ivs):
    """重なる区間を一つにまとめ、始めの順に並べる。"""
    out = []
    for a, b in sorted(ivs):
        if out and a <= out[-1][1]:
            if b > out[-1][1]:
                out[-1] = (out[-1][0], b)
        else:
            out.append((a, b))
    return out


def empty_tokens():
    return {k: 0 for k in TOKEN_KEYS}


def usage_tokens(u):
    """usageをトークンの内訳に直す。cache_creationの内訳が無いときは5分のキャッシュ作成とみなす。"""
    cc = int(u.get("cache_creation_input_tokens") or 0)
    detail = u.get("cache_creation")
    if isinstance(detail, dict):
        c5 = int(detail.get("ephemeral_5m_input_tokens") or 0)
        c1 = int(detail.get("ephemeral_1h_input_tokens") or 0)
    else:
        c5, c1 = cc, 0
    return {
        "input": int(u.get("input_tokens") or 0),
        "output": int(u.get("output_tokens") or 0),
        "cache_creation": cc,
        "cache_creation_5m": c5,
        "cache_creation_1h": c1,
        "cache_read": int(u.get("cache_read_input_tokens") or 0),
    }


def add_tokens(by_model, model, t):
    if not any(t.values()):
        return
    cur = by_model.setdefault(model or "（モデル不明）", empty_tokens())
    for k in TOKEN_KEYS:
        cur[k] += t[k]


def assistant_records(records, main_only):
    """assistantの記録を(時刻, message.id, モデル, トークン, {service_tier, speed})の並びで返す。重複は除かない。"""
    out = []
    for d in records:
        if d.get("type") != "assistant":
            continue
        if main_only and d.get("isSidechain"):
            continue
        msg = d.get("message")
        if not isinstance(msg, dict) or not isinstance(msg.get("usage"), dict):
            continue
        u = msg["usage"]
        out.append((parse_ts(d.get("timestamp")), msg.get("id") or d.get("uuid"), msg.get("model"), usage_tokens(u),
                    {k: u.get(k) for k in TIER_KEYS}))
    return out


def final_records(rows):
    """message.idごとに一つの記録を採る。

    同じmessage.idの記録は、一つの応答のストリーミングの途中経過が重なって書かれたものであり、
    最後の記録（出力トークンが最大のもの）のusageが応答全体の値である。
    出力トークンが同じなら後に書かれた記録を採る。
    """
    picked = {}
    order = []
    for row in rows:
        key = row[1]
        if key not in picked:
            order.append(key)
            picked[key] = row
        elif row[3]["output"] >= picked[key][3]["output"]:
            picked[key] = row
    return [picked[k] for k in order]


def sum_tokens(rows, by_model):
    """記録のトークンをモデル別に足す。"""
    for row in rows:
        add_tokens(by_model, row[2], row[3])


def empty_tiers():
    return {k: {} for k in TIER_KEYS}


def count_tiers(rows, counts):
    """usageのservice_tierとspeedが文字列でstandard以外の記録の数を、項目ごと、値ごとに足す。"""
    for row in rows:
        for k in TIER_KEYS:
            v = row[4].get(k)
            if isinstance(v, str) and v != STANDARD:
                counts[k][v] = counts[k].get(v, 0) + 1


def merge_tiers(dst, src):
    for k in TIER_KEYS:
        for v, n in src.get(k, {}).items():
            dst[k][v] = dst[k].get(v, 0) + n


class ProjectLog:
    """プロジェクトのセッション記録の全体。主会話を一度だけ走査する。"""

    def __init__(self, log_dir):
        self.log_dir = log_dir
        self.exists = os.path.isdir(log_dir)
        self.launches = {}  # 案件名 -> 担当の起動の並び
        self.main_messages = {}  # セッションID -> 主会話のassistantの並び
        self.main_events = {}  # セッションID -> 主会話の統括の応答と依頼元の発言の並び
        self.branch_records = {}  # セッションID -> (時刻, gitBranch)の並び
        if self.exists:
            for path in sorted(glob.glob(os.path.join(log_dir, "*.jsonl"))):
                self._scan(path)

    def _scan(self, path):
        session = os.path.splitext(os.path.basename(path))[0]
        records = list(iter_jsonl(path))
        calls = []
        results = {}
        notices = {}
        for d in records:
            t = d.get("type")
            msg = d.get("message") if isinstance(d.get("message"), dict) else {}
            content = msg.get("content")
            if t == "assistant" and isinstance(content, list):
                for b in content:
                    if not (isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "Agent"):
                        continue
                    inp = b.get("input") or {}
                    w = find_destination(str(inp.get("prompt") or ""))
                    if not w:
                        continue
                    calls.append((d, b, w))
            elif t == "user" and isinstance(content, list) and isinstance(d.get("toolUseResult"), dict):
                for c in content:
                    if isinstance(c, dict) and c.get("type") == "tool_result":
                        results[c.get("tool_use_id")] = (d, d["toolUseResult"])
            elif t == "attachment":
                a = d.get("attachment") or {}
                if isinstance(a, dict) and (a.get("origin") or {}).get("kind") == "task-notification":
                    prompt = str(a.get("prompt") or "")
                    m = NOTICE_ID_RE.search(prompt)
                    ms = (a.get("usage") or {}).get("durationMs")
                    if ms is None:
                        mm = NOTICE_MS_RE.search(prompt)
                        ms = int(mm.group(1)) if mm else None
                    if m and ms is not None:
                        notices.setdefault(m.group(1), (ms, parse_ts(d.get("timestamp"))))
        if not calls:
            return
        self.main_messages[session] = assistant_records(records, main_only=True)
        self.main_events[session] = main_events(records)
        self.branch_records[session] = [(parse_ts(d.get("timestamp")), d.get("gitBranch")) for d in records
                                        if isinstance(d.get("gitBranch"), str)]
        for d, b, w in calls:
            inp = b.get("input") or {}
            res = results.get(b.get("id"))
            tur = res[1] if res else {}
            launch = {
                "session": session,
                "tool_use_id": b.get("id"),
                "subagent_type": inp.get("subagent_type"),
                "description": inp.get("description"),
                "case": w.group(1),
                "task_dir": w.group(2),
                "file": w.group(3),
                "kind": w.group(4),
                "n": int(w.group(5)),
                "start": parse_ts(d.get("timestamp")),
                "agent_id": tur.get("agentId"),
                "resolved_model": tur.get("resolvedModel"),
                "duration_ms": tur.get("totalDurationMs"),
                "duration_source": "totalDurationMs" if tur.get("totalDurationMs") is not None else None,
                "tool_stats": tur.get("toolStats") if isinstance(tur.get("toolStats"), dict) else None,
            }
            if launch["duration_ms"] is None and b.get("id") in notices:
                launch["duration_ms"] = notices[b.get("id")][0]
                launch["duration_source"] = "完了通知のdurationMs"
            self.launches.setdefault(w.group(1), []).append(launch)

    def subagent_usage(self, session, agent_id):
        """サブエージェントの記録から、モデル別のトークン量、標準以外の呼び出しの数、最初と最後の記録の時刻と、
        assistantの記録のmessage.modelとeffortの値（それぞれ現れた順に重ねずに並べたもの）を返す。"""
        if not agent_id:
            return None
        path = os.path.join(self.log_dir, session, "subagents", "agent-%s.jsonl" % agent_id)
        if not os.path.isfile(path):
            return None
        records = list(iter_jsonl(path))
        rows = final_records(assistant_records(records, main_only=False))
        by_model = {}
        sum_tokens(rows, by_model)
        tiers = empty_tiers()
        count_tiers(rows, tiers)
        times = [parse_ts(d.get("timestamp")) for d in records if d.get("timestamp")]
        times = [x for x in times if x]
        models = []
        efforts = []
        for d in records:
            if d.get("type") != "assistant":
                continue
            msg = d.get("message")
            m = msg.get("model") if isinstance(msg, dict) else None
            if isinstance(m, str) and m and m not in models:
                models.append(m)
            v = d.get("effort")
            if isinstance(v, str) and v and v not in efforts:
                efforts.append(v)
        return {
            "tokens": by_model,
            "tiers": tiers,
            "first": min(times) if times else None,
            "last": max(times) if times else None,
            "models": models,
            "efforts": efforts,
        }

    def subagent_type(self, session, agent_id):
        """サブエージェントの記録のmeta.jsonのagentType。無ければNone。"""
        if not agent_id:
            return None
        path = os.path.join(self.log_dir, session, "subagents", "agent-%s.meta.json" % agent_id)
        try:
            with open(path, encoding="utf-8") as f:
                meta = json.load(f)
        except (OSError, ValueError):
            return None
        v = meta.get("agentType") if isinstance(meta, dict) else None
        return v if isinstance(v, str) and v else None

    def orchestrator_usage(self, sessions, start, end):
        """主会話のassistantの記録をmessage.idごとに一つにまとめてから、時刻がstart以上end未満のものを合計する。
        モデル別のトークン量と、標準以外の呼び出しの数を返す。"""
        rows = []
        for s in sessions:
            rows.extend(self.main_messages.get(s, []))
        picked = [r for r in final_records(rows) if r[0] is not None and start <= r[0] < end]
        by_model = {}
        sum_tokens(picked, by_model)
        tiers = empty_tiers()
        count_tiers(picked, tiers)
        return {"tokens": by_model, "tiers": tiers}

    def wait_intervals(self, sessions, start, end):
        """セッションごとの待機の区間を、startからendまでで切り、重なりをまとめて返す。"""
        ivs = []
        for s in sessions:
            for a, b in session_waits(self.main_events.get(s, [])):
                a, b = max(a, start), min(b, end)
                if a < b:
                    ivs.append((a, b))
        return merge_intervals(ivs)

    def branches(self, sessions, start, end):
        """記録の時刻がstart以上end未満のgitBranchを、最初に現れた順に重ねずに返す。HEADと空は除く。"""
        rows = []
        for s in sessions:
            rows.extend((ts, b) for ts, b in self.branch_records.get(s, []) if ts is not None and start <= ts < end)
        out = []
        for _, b in sorted(rows, key=lambda r: r[0]):
            b = b.strip()
            if b and b != "HEAD" and b not in out:
                out.append(b)
        return out
