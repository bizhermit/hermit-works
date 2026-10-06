#!/usr/bin/env python3
"""実施者が書いた<案件>.jsonを読んで形を確かめ、セッション記録から取る値を同じJSONに書き足し、
案件ごとのHTMLと案件一覧のindex.htmlを生成する。案件ファイルは読まない。

使い方:
    python3 visualize.py <案件ディレクトリ> [--out <出力先>] [--config-dir <設定ディレクトリ>] [--pricing <単価表>]

<案件ディレクトリ>は、案件名と、セッション記録との結び付けに使うパス文字列（.hw/cases/<案件>/）を得るためだけに使う。
引数のディレクトリにplan.mdが無く、直下にplan.mdを持つディレクトリが一つ以上あれば、親ディレクトリとして扱い、
plan.mdを持つディレクトリのうち<出力先>/<案件>.jsonがあるものを順に処理する。plan.mdはあるかどうかを見るだけで、中身は読まない。
"""

import argparse
import glob
import json
import os
import sys
from datetime import datetime

sys.dont_write_bytecode = True  # 配布するディレクトリに__pycache__を作らない
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import json_format  # noqa: E402
import metrics  # noqa: E402
import render  # noqa: E402
from session_log import ProjectLog, project_log_dir  # noqa: E402

SCRIPT_KEY = "script"


def find_project_dir(case_dir):
    env = os.environ.get("CLAUDE_PROJECT_DIR")
    if env:
        return os.path.abspath(env)
    cur = os.path.abspath(case_dir)
    while True:
        if os.path.basename(cur) == ".hw":
            return os.path.dirname(cur)
        parent = os.path.dirname(cur)
        if parent == cur:
            return os.getcwd()
        cur = parent


PLAN = "plan.md"


def has_plan(d):
    """ディレクトリにplan.mdがあるか（中身は読まない）。"""
    return os.path.isfile(os.path.join(d, PLAN))


def child_cases(target):
    """直下のディレクトリのうち、plan.mdを持つもの。"""
    return sorted(p for p in glob.glob(os.path.join(target, "*")) if os.path.isdir(p) and has_plan(p))


def load_pricing(path):
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    if not isinstance(data, dict) or not isinstance(data.get("models"), dict):
        raise ValueError("単価表の形が違う（modelsの辞書が無い）: %s" % path)
    return data


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def write_text(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def other_periods(out_dir):
    """出力先の<案件>.jsonから、(案件名, 着手日時, 完了日時, tasksのrecord_dirの並び)の並びを返す。日時が読めない案件は飛ばす。"""
    out = []
    for p in sorted(glob.glob(os.path.join(out_dir, "*.json"))):
        try:
            d = load_json(p)
        except (OSError, ValueError):
            continue
        if not isinstance(d, dict) or not json_format.is_datetime(d.get("started")):
            continue
        finished = d.get("finished") if json_format.is_datetime(d.get("finished")) else None
        tasks = d.get("tasks") if isinstance(d.get("tasks"), list) else []
        record_dirs = [t.get("record_dir") for t in tasks if isinstance(t, dict) and isinstance(t.get("record_dir"), str)]
        out.append((os.path.splitext(os.path.basename(p))[0], json_format.parse_dt(d["started"]), json_format.parse_dt(finished), record_dirs))
    return out


def build_index(out_dir):
    cases = []
    for p in sorted(glob.glob(os.path.join(out_dir, "*.json"))):
        try:
            d = load_json(p)
        except (OSError, ValueError):
            continue
        if isinstance(d, dict) and isinstance(d.get(SCRIPT_KEY), dict) and not json_format.validate(d):
            cases.append(d)
    cases.sort(key=lambda d: d[SCRIPT_KEY].get("case") or "")
    path = os.path.join(out_dir, "index.html")
    write_text(path, render.index_html(cases))
    return path


def main(argv=None):
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description="hw:executeの案件記録を可視化する（実施者が書いた<案件>.jsonを読む）")
    ap.add_argument("case_dir", help="案件ディレクトリ（.hw/cases/<案件>/）のパス、または案件の親ディレクトリ（.hw/cases/）のパス")
    ap.add_argument("--out", help="出力先（既定は<プロジェクト>/.hw/analysis/）")
    ap.add_argument("--config-dir", help="Claude Codeの設定ディレクトリ（既定はCLAUDE_CONFIG_DIR、無ければ~/.claude）")
    ap.add_argument("--pricing", help="単価表（既定はスクリプトの一つ上のpricing.json）")
    args = ap.parse_args(argv)

    if not os.path.isdir(args.case_dir):
        print("エラー: 案件ディレクトリが無い: %s" % args.case_dir, file=sys.stderr)
        return 2
    target = os.path.abspath(args.case_dir)
    children = [] if has_plan(target) else child_cases(target)
    parent_mode = bool(children)
    case_dirs = children if parent_mode else [target]

    project_dir = find_project_dir(case_dirs[0] if case_dirs else target)
    out_dir = os.path.abspath(args.out) if args.out else os.path.join(project_dir, ".hw", "analysis")
    config_dir = args.config_dir or os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    pricing_path = os.path.abspath(args.pricing) if args.pricing else os.path.normpath(os.path.join(here, "..", "pricing.json"))

    # 処理する案件（<出力先>/<案件>.jsonがあるもの）
    todo = []
    for case_dir in case_dirs:
        name = os.path.basename(case_dir)
        jpath = os.path.join(out_dir, name + ".json")
        if os.path.isfile(jpath):
            todo.append((name, jpath))
        elif parent_mode:
            print("飛ばした案件: %s（%s が無い。実施者が案件ファイルを読み、json-format.mdの形で先に書く）" % (name, jpath))
        else:
            print("エラー: %s が無い。実施者が案件ファイルを読み、json-format.mdの形で<出力先>/<案件>.jsonを先に書く必要がある" % jpath,
                  file=sys.stderr)
            return 2

    try:
        pricing = load_pricing(pricing_path)
    except (OSError, ValueError) as ex:
        print("エラー: 単価表を読めない: %s" % ex, file=sys.stderr)
        return 1

    os.makedirs(out_dir, exist_ok=True)
    log = ProjectLog(project_log_dir(os.path.abspath(config_dir), project_dir))
    now = datetime.now().astimezone()
    others = other_periods(out_dir)
    failed = 0
    written = []
    unknown_lines = []
    for name, jpath in todo:
        try:
            data = load_json(jpath)
        except (OSError, ValueError) as ex:
            failed += 1
            print("エラー: %s をJSONとして読めない: %s" % (jpath, ex), file=sys.stderr)
            continue
        errors = json_format.validate(data)
        if errors:
            failed += 1
            print("エラー: %s の形がjson-format.mdと違う（%d件）:" % (jpath, len(errors)), file=sys.stderr)
            for msg in errors:
                print("  " + msg, file=sys.stderr)
            continue
        try:
            data[SCRIPT_KEY] = metrics.build(name, data, project_dir, log, pricing, pricing_path if pricing else None, others, now=now)
            hpath = os.path.join(out_dir, name + ".html")
            write_text(jpath, json.dumps(data, ensure_ascii=False, indent=2) + "\n")
            write_text(hpath, render.case_html(data))
            written += [jpath, hpath]
            for u in data["unknown"]:
                unknown_lines.append("%s: %s（理由：%s）" % (name, render.item_label(u["item"]), u["reason"]))
            for u in data[SCRIPT_KEY]["unknown"]:
                unknown_lines.append("%s: %s（理由：%s）" % (name, u["item"], u["reason"]))
        except Exception as ex:  # 一つの案件の失敗で他の案件を止めない
            failed += 1
            print("エラー: %s を可視化できない: %s: %s" % (name, type(ex).__name__, ex), file=sys.stderr)
    try:
        written.append(build_index(out_dir))
    except Exception as ex:
        failed += 1
        print("エラー: index.htmlを作れない: %s: %s" % (type(ex).__name__, ex), file=sys.stderr)

    print("出力したファイル:")
    for p in written:
        print("  " + p)
    print("取れなかった指標:")
    if unknown_lines:
        for line in unknown_lines:
            print("  " + line)
    else:
        print("  なし")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
