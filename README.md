# Hermit Works

## リポジトリ構成

```text
/                          # 保守側（非配布）
├── .claude-plugin/
│   └── marketplace.json   # マーケットプレイス定義
├── .claude/
│   └── settings.json      # 本リポジトリ自身でプラグインを有効にする設定
├── CLAUDE.md              # 本リポジトリ保守用の指示
├── LICENSE                # ライセンス全文の正本
├── docs/
│   └── design/            # 設計書
├── scripts/
│   └── git-cleanup-branch.sh # リモートで消えた作業ブランチをローカルから掃除する
└── plugin/                # 配布側（インストール時にコピーされる範囲）
    ├── .claude-plugin/
    │   └── plugin.json    # プラグインマニフェスト
    ├── LICENSE            # 配布用の写し
    ├── agents/            # エージェント
    │   ├── worker.md      # hw:worker（実行者）
    │   └── reviewer.md    # hw:reviewer（評価者）
    ├── hooks/             # フック
    │   ├── hooks.json     # 起動時に作業品質の基盤を加えるフックの定義
    │   └── foundation.sh  # 作業品質の基盤をフックの出力の形にする
    ├── skills/            # スキル
    │   ├── request/       # hw:request
    │   │   ├── SKILL.md
    │   │   └── templates/ # 指示書の雛形
    │   └── execute/       # hw:execute
    │       ├── SKILL.md
    │       └── templates/ # 実行計画、報告、レビューの雛形
    └── assets/            # 共通資材
        └── foundation.md  # 作業品質の基盤（四節）の本文
```
