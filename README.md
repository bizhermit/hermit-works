# Hermit Works

Claude Code用のプラグイン。要望を指示書として言語化し、指示書を計画・実行・レビューの分業で仕上げる。

## インストール

マーケットプレイスを登録し、プラグインをインストールする。`<scope>`は`user`、`project`、`local`のいずれかで、省くと`user`になる。

```bash
claude plugin marketplace add bizhermit/hermit-works --scope <scope>
claude plugin install hw@hermit-works --scope <scope>
```

| `<scope>` | 書き込む設定ファイル | 有効になる範囲 |
| :- | :- | :- |
| `user` | `~/.claude/settings.json` | 自分のすべてのプロジェクト |
| `project` | `<プロジェクト>/.claude/settings.json` | そのプロジェクトの貢献者全員 |
| `local` | `<プロジェクト>/.claude/settings.local.json` | そのプロジェクトの自分だけ |

`project`の設定を共有された貢献者は、同じ二つのコマンドを`--scope project`で一度実行する。

指示書と案件の記録はプロジェクト直下の`.hw/`に置かれるため、`.gitignore`に次を追記する。

```gitignore
.hw/
```

## 使い方

### `/hw:request`：要望を指示書にする

```text
/hw:request <要望または相談>
```

目的が定まらないときと、指示書全体に対する問題（現物を指す語が見つからない、答えが互いに矛盾する等）があるときに問う。どう対処するか（どのファイルにどういう修正を行うか、対象範囲、完了条件等）は、言われない限り問わず、`/hw:execute`が対応方針で定める。相談の形で始めてもよい。目的が定まるまで、答えを言語化して確かめ、要るなら目的の候補を示しながら指示書にする。承認を得てから指示書を`.hw/instructions/`に出力する。

### `/hw:execute`：指示書を実行する

```text
/hw:execute <指示書のパス>
```

指示書から対応方針を立てて承認を求め、承認後は実行計画を立ててタスクごとに実行者と評価者を起動し、評価者が承認するまで差し戻す。すべてのタスクの完了後に全体レビューを行い、結果を報告する。引数を省くと`.hw/instructions/`の指示書を一覧して問う。
