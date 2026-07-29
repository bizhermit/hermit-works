# ダイジェスト固定: 2026-07-28 時点で `docker buildx imagetools inspect ubuntu:26.04`
# (または `docker manifest inspect ubuntu:26.04`) が返す、タグ ubuntu:26.04 が指す
# マルチアーキテクチャ manifest list のダイジェスト。latest 相当の floating tag への
# 依存を避け、再ビルド時に意図せず内容が変わらないようにする。
# 更新する場合は上記コマンドで最新のダイジェストを取得し、この行を置き換えること。
FROM ubuntu:26.04@sha256:3131b4cc82a783df6c9df078f86e01819a13594b865c2cad47bd1bca2b7063bb

ARG NODE_MAJOR=26

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Tokyo \
    LANG=ja_JP.UTF-8 \
    LC_ALL=ja_JP.UTF-8

# 基本ツール + ロケール/タイムゾーン
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        wget \
        git \
        sudo \
        locales \
        tzdata \
        ripgrep \
        jq \
        unzip \
        zip \
        less \
        procps \
        gnupg \
        openssh-client \
        build-essential \
        vim \
        nano \
        python3 \
        python3-openpyxl \
        python3-pil \
    && locale-gen ja_JP.UTF-8 \
    && ln -fs /usr/share/zoneinfo/Asia/Tokyo /etc/localtime \
    && dpkg-reconfigure -f noninteractive tzdata \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI
RUN GH_VERSION=$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/cli/cli/releases/latest | grep -oP 'v\K[\d.]+') \
    && ARCH=$(dpkg --print-architecture) \
    && cd /tmp \
    && curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${ARCH}.tar.gz" -o "gh_${GH_VERSION}_linux_${ARCH}.tar.gz" \
    && curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_checksums.txt" -o gh_checksums.txt \
    && sha256sum --check --ignore-missing gh_checksums.txt \
    && tar -xzf "gh_${GH_VERSION}_linux_${ARCH}.tar.gz" \
    && mv "gh_${GH_VERSION}_linux_${ARCH}/bin/gh" /usr/local/bin/ \
    && rm -rf "gh_${GH_VERSION}_linux_${ARCH}.tar.gz" gh_checksums.txt "gh_${GH_VERSION}_linux_${ARCH}"

# Node.js
# NodeSource の setup_*.x スクリプトを curl | bash で直接実行すると、スクリプト自体の
# 改ざん検知手段がない (ダウンロード内容の署名検証なしにそのままシェルで実行される)。
# そのため同スクリプトが内部で行っている手順 (GPG 鍵を keyring として配置し、
# signed-by 付きの APT リポジトリとして登録する) を明示的に行い、以降の
# `apt-get install` で APT 自体の署名検証が効くようにする。
RUN curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg \
    && ARCH=$(dpkg --print-architecture) \
    && echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg arch=${ARCH}] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Playwright (テスト実施フェーズの UI テスト・画面キャプチャ用)
# - Python 版を使用する。ドライバのランタイムはパッケージに同梱されるため、
#   システムの Node.js バージョンに依存しない
# - システム Python への pip install は不可 (externally managed) のため venv に導入し、CLI のみパスを通す
#   スクリプトからの利用は /opt/playwright/bin/python3 で実行する
# - ブラウザ本体は dev ユーザーからも参照できる共有パスに置く
# - fonts-noto-cjk はスクリーンショットの日本語表示用
ENV PLAYWRIGHT_BROWSERS_PATH=/usr/local/share/ms-playwright
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3-venv fonts-noto-cjk \
    && python3 -m venv /opt/playwright \
    && /opt/playwright/bin/pip install --no-cache-dir playwright \
    && ln -s /opt/playwright/bin/playwright /usr/local/bin/playwright \
    && playwright install --with-deps chromium \
    && chmod -R a+rX "${PLAYWRIGHT_BROWSERS_PATH}" \
    && rm -rf /var/lib/apt/lists/*

# 開発用ユーザー (dev) を新規作成する
# ベースイメージ標準の ubuntu ユーザーは sudo グループ等に最初から所属しているため使用せず、
# 削除したうえで必要最小限の権限のユーザーを作り直す (権限は足し算で管理する)
# UID / GID はホスト側ユーザーに合わせる (.devcontainer/.env で指定)
ARG UID=1000
ARG GID=1000
RUN userdel -r ubuntu \
    && if getent group ubuntu > /dev/null; then groupdel ubuntu; fi \
    && groupadd -g "${GID}" dev \
    && useradd -m -s /bin/bash -u "${UID}" -g "${GID}" dev \
    # .claude と .config/gh はボリュームのマウントポイント。イメージ内に dev 所有で
    # 作成しておくことで、初回のボリューム初期化時に所有権が引き継がれる
    && mkdir -p /home/dev/.claude /home/dev/.config/gh \
    && chown -R "${UID}:${GID}" /home/dev

# dev ユーザーには sudo 権限を与えない。
# どうしても必要になった場合は、以下のコメントアウトを外して
# "Dev Containers: Rebuild Container" で作り直すことで付与できる
# RUN echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev \
#     && chmod 0440 /etc/sudoers.d/dev

USER dev

# Claude Code (ネイティブバイナリ版)
# ランタイム同梱のスタンドアロンバイナリのため、システムの Node.js バージョンに依存しない
#
# [セキュリティ: リスク受容 / MEDIUM指摘への対応]
# インストールスクリプト (claude.ai/install.sh がリダイレクトする
# downloads.claude.ai/claude-code-releases/bootstrap.sh) は GPG 署名や APT 等の
# パッケージマネージャ配布を持たず、curl | bash 自体の改ざん検知はできない。
# ただしスクリプトが実際に取得するバイナリ本体は、TLS 経由の manifest に記載された
# SHA256 チェックサムと照合したうえで設置される (破損・取り違えの検知はある)。
# 実行はこの USER dev より後段であり、dev には sudo を付与していないため
# (本 Dockerfile 参照)、install.sh もホームディレクトリ配下へ非rootでインストールする
# 前提で作られている。したがって万一スクリプトが改ざんされていた場合の被害範囲は
# コンテナ内 dev ユーザー権限に限定される。
# 公式に署名検証やパッケージ配布が提供されていない現時点ではこの方式を受容するが、
# せめて "latest" ではなく明示的な "stable" チャンネル指定にし、再現性が必要な場合は
# CLAUDE_CODE_VERSION に具体的なバージョン番号 (install.sh が受け付ける
# stable / latest / X.Y.Z 形式) を指定して固定できるようにしている。
ARG CLAUDE_CODE_VERSION=stable
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- "${CLAUDE_CODE_VERSION}"
ENV PATH="/home/dev/.local/bin:${PATH}"

WORKDIR /workspace
