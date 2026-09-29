---
name: release
description: "本リポジトリのリリースを次の一作業だけ進める（バージョンを上げる、リリースPRを作成する、タグとリリースノートを作成する）"
argument-hint: "[バージョン]"
---

# release

本リポジトリのリリースを進める。リリースは`develop`から`main`へのPRを単位とする。

## 入力

- 引数：$ARGUMENTS。バージョンを上げる作業で採るバージョン（任意）

## バージョンの規則

`MAJOR.MINOR.PATCH`の形で付ける。

- **MAJOR**：互換を壊す変更。スキル・エージェントの名前や引数の変更・削除、`.hw/`の構成や記録の雛形の互換のない変更、利用側の`CLAUDE.md`や設定に対応を求める変更
- **MINOR**：互換を保つ機能の追加や挙動の変更
- **PATCH**：不具合の修正、文言の修正、挙動を変えない変更

次に従って決める。

- リリースに含まれる変更のうち、最も上位の桁を一つ上げ、下位の桁は`0`に戻す
- MAJORが`0`の間は、互換を壊す変更があってもMAJORを上げず、MINORを上げる。MAJORを`1`にするのはメジャーリリースのときだけである
- バージョンは`plugin/.claude-plugin/plugin.json`の`version`にだけ書く。`.claude-plugin/marketplace.json`には書かない
- タグ名はバージョンの文字列そのもの（例：`0.1.0`）とし、`v`を付けない

## 手順

### 流れ

一つのリリースは次の順で進む。奇数番は本スキルの作業、偶数番は人が行うマージである。本スキルは起動のたびに現物から状態を取り、次に行う一つの作業だけを行って停止する。前の作業を飛ばして後の作業を行わない。

1. バージョンを上げる（本スキル）：`work/bump-<version>`で`plugin.json`の`version`を上げ、`develop`へPRを作成する
2. 人がそのPRを`develop`へマージする
3. リリースPRを作成する（本スキル）：リリースノートを書き、`develop`から`main`へPRを作成する
4. 人がそのPRを`main`へマージする
5. タグとリリースノートを作成する（本スキル）：`main`にタグを打ち、GitHubのリリースを作成する

5が終わると、次のリリースは1から始まる。

### 状態を取る

`git fetch origin --tags --prune`の後、次を取る。ローカルのブランチは見ず、`origin`の参照だけで判じる。

- `V_main`：`origin/main`の`plugin/.claude-plugin/plugin.json`の`version`
- `V_dev`：`origin/develop`の同じ値
- `T_main`：タグ`V_main`の有無
- 開いているPR：`work/bump-*`から`develop`へのものと、`develop`から`main`へのもの

```bash
git show origin/main:plugin/.claude-plugin/plugin.json | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p'
git show origin/develop:plugin/.claude-plugin/plugin.json | sed -n 's/.*"version": *"\([^"]*\)".*/\1/p'
git ls-remote --tags origin "refs/tags/<V_main>"
gh pr list --base develop --state open --json number,headRefName --jq '[.[] | select(.headRefName | startswith("work/bump-"))]'
gh pr list --base main --head develop --state open --json number
```

状態は流れのどこまで終わったかを表す。次の表で、次に行う作業を決める。三行の条件は互いに排他である。

| 状態 | 終わっている所 | 次に行う作業 |
| :- | :- | :- |
| `V_dev`が`V_main`と同じで、`T_main`がある | 5まで（前のリリースが完了） | 1. バージョンを上げる |
| `V_dev`が`V_main`と異なり、`T_main`がある | 2まで | 3. リリースPRを作成する |
| `T_main`が無い | 4まで | 5. タグとリリースノートを作成する |

次に行う作業に対応する開いているPRがあれば、その作業は既に行われ、マージ待ちである。番号を示し、マージを待つよう伝えて停止する。

- 1に対応するPR：`work/bump-*`から`develop`へのPR
- 3に対応するPR：`develop`から`main`へのPR

`V_dev`が`V_main`と異なり、かつ`T_main`が無い状態は、前のリリースの5が終わらないまま次の1と2が進んだ状態である。表のとおり5を行うが、その前に、`V_main`のタグが未作成のまま`develop`が進んでいることを示して問う。

### 1. バージョンを上げる

1. 変更を読む。取れた変更が無ければ、リリースするものが無いと報告して停止する。

    ```bash
    git log <V_main>..origin/develop --oneline
    ```

2. 変更を規則に照らしてバージョンを決める。引数があれば規則に照らし、合えば採り、合わなければ理由を示して問う。
3. 変更の一覧、バージョン、桁を選んだ根拠を示して承認を得る。
4. 作業ツリーに未コミットの変更が無いことを確かめ、`origin/develop`から`work/bump-<version>`を作る。
5. `plugin/.claude-plugin/plugin.json`の`version`を書き換え、`claude plugin validate ./plugin`を通す。
6. コミットし、pushし、`develop`へPRを作成する。表題は「バージョンを<version>に上げる」、本文は変更の一覧とする。
7. 報告する。

### 3. リリースPRを作成する

1. 変更を読む。

    ```bash
    git log <V_main>..origin/develop --oneline
    ```

2. [templates/release-notes.md](${CLAUDE_SKILL_DIR}/templates/release-notes.md)に従ってリリースノートを書く。`<バージョン>`は`V_dev`、`<前のバージョン>`は`V_main`とする。変更は、取れた変更のうち利用者に届くもの（`plugin/`とREADME）を、PRごとではなく内容ごとにまとめて箇条書きにする。変更の内容は、コミットの表題ではなく差分の現物から書く。保守用の変更（開発環境、CI、保守用のスキルやスクリプト等）と、バージョンを上げた変更は含めない。比較リンクはタグ`V_dev`を打つまで開けないため、5で確かめる。
3. リリースノートの全文を示して承認を得る。
4. `develop`から`main`へPRを作成する。表題は「リリース <V_dev>」、本文はリリースノートとする。

    ```bash
    gh pr create --base main --head develop --title "リリース <V_dev>" --body-file <リリースノート>
    ```

5. 報告する。

### 5. タグとリリースノートを作成する

1. `main`にマージされたリリースPRを取る。該当が無い、または複数ある場合は、候補を示して問う。

    ```bash
    gh pr list --base main --state merged --search "リリース <V_main>" --json number,title,body
    ```

2. PRの本文をリリースノートとし、その全文と、タグ`<V_main>`を`origin/main`の先頭に打つことを示して承認を得る。
3. リリースを作成する。タグは`gh release create`が作る。

    ```bash
    gh release create <V_main> --target main --title "<V_main>" --notes-file <リリースノート>
    ```

4. 作成と、リリースノートの比較リンクが開けることを確かめる。`<前のバージョン>`はリリースノートの比較リンクにある値とする。

    ```bash
    git ls-remote --tags origin "refs/tags/<V_main>"
    gh release view <V_main>
    gh api "repos/bizhermit/hermit-works/compare/<前のバージョン>...<V_main>" --jq .status
    ```

5. 報告する。

## 問い方

問いは一件ずつ行い、答えを得てから次へ進む。承認を求めるときは、これから行う操作（実行するコマンド、作成する内容の全文）と、影響の及ぶ先（ブランチ、PR、タグ、リリース）を示す。判断を求めるときは、問題、原因、案と各案の利害得失、推奨と根拠を添える。推奨は既定値ではなく、答えに従う。

## 報告

作業の最後に次を報告する。

- 行った作業と、作成したもののURL（PR、リリース）
- 次に行う作業と、その前に人が行うこと（PRのマージ等）
- 停止した場合は、その理由

## 境界

- 書き込むのは、`work/bump-*`ブランチ上の`plugin/.claude-plugin/plugin.json`と、GitHub上のPR、タグ、リリースだけである
- `develop`と`main`には直接pushしない。PRのマージは人が行い、本スキルは行わない
- push、PRの作成、リリースの作成は、承認を得てから行う
- 一時ファイル（リリースノートの下書き等）はリポジトリの外に置く

## 停止条件

- 承認または答えが得られない：示したまま停止する
- 作業に対応するPRが開いている：番号を示して停止する
- 作業ツリーに未コミットの変更がある（バージョンを上げるとき）：`git status --short`を示して停止する
- 状態を取るコマンドが失敗した：コマンドと応答を示して停止する
