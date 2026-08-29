# Hermit Works 設計書

## リポジトリ構成

```text
/                          # 保守側（非配布）
├── .claude-plugin/
│   └── marketplace.json   # マーケットプレイス定義
├── CLAUDE.md              # 本リポジトリ保守用の指示
├── LICENSE                # ライセンス全文の正本
├── docs/
│   └── design/            # 設計書（本ディレクトリ）
└── plugin/                # 配布側（インストール時にコピーされる範囲）
    ├── .claude-plugin/
    │   └── plugin.json    # プラグインマニフェスト
    ├── LICENSE            # 配布用の写し
    ├── agents/            # エージェント
    ├── skills/            # スキル
    └── assets/            # 共通資材
```
