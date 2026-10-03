# DevContainer

## compose.yml

### セキュリティ：受け入れたリスクと、重大度HIGHの指摘への対応

dev-containerのdocker-outside-of-docker feature（`ghcr.io/devcontainers/features/docker-outside-of-docker:1`。`devcontainer-lock.json`が指すバージョンは1.10.0）は、コンテナの起動時にENTRYPOINT（`/usr/local/share/docker-init.sh`）で、「マウントしたホストの`docker.sock`のGIDに、コンテナ内の`docker`グループのGIDを合わせる（`groupmod`）」と「`socat`で、権限を中継するためのソケットを作る」の二つの処理を、`sudoIf`（rootでなければ`sudo`を通す）で実行する。  
このイメージの`dev`ユーザーには`sudo`を一切付与していない（`Dockerfile`を参照）ため、compose上で`user: dev`にするとENTRYPOINTでの`sudo`の呼び出しが失敗し、featureが機能しなくなる。そのため、compose上でコンテナを起動するユーザーはrootのままとする。  
実際の開発作業は、`devcontainer.json`の`remoteUser: dev`により非rootのユーザーで行うため、このコンテナ内での作業そのものがrootの権限で行われるわけではない。  
なお、`docker.sock`をコンテナに渡した時点で、ホストのDockerデーモンに対してrootと同等の操作ができるようになること（docker-outside-of-docker方式が持つリスク）は把握している。本リポジトリでは「ローカルでの開発体験を優先し、ホストは開発者個人のマシンに限る」という前提で、このリスクを受け入れる。将来、コンテナを起動するユーザーをrootから変える必要が出た場合は、`dev`に、該当するコマンドだけを`NOPASSWD`で許すsudoersのエントリを付与する方式へ変えることを検討すること。  

## Dockerfile

## postStart.sh

###