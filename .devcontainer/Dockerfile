FROM ubuntu:26.04@sha256:2260313b31c8c011cd2eebe728008efac1b3982be73eb71348ea2648d2c0e09b

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Tokyo \
    LANG=ja_JP.UTF-8 \
    LC_ALL=ja_JP.UTF-8

# Claude Code を運用するのに必要な最小構成に絞る。追加する場合は「何が壊れるか」を
# 説明できるものだけにすること (下記コメントが判断基準)。
RUN apt-get update && apt-get install -y --no-install-recommends \
        # curl の Recommends のため --no-install-recommends だと入らない。HTTPS 全般に必須
        ca-certificates \
        # claude.ai/install.sh・GitHub CLI の取得に必須
        curl \
        git \
        # gh auth login --git-protocol ssh (postStart.sh の案内) で必要
        openssh-client \
        # git / gh のページャ。無いと対話時の git log や gh pr view が失敗する
        less \
        # ps 等。VS Code Server のプロセス管理が参照する
        procps \
        # LANG=ja_JP.UTF-8 の locale-gen に必要
        locales \
        tzdata \
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

USER dev

# Claude Code (ネイティブバイナリ版)
# ランタイム同梱のスタンドアロンバイナリのため、システムの Node.js バージョンに依存しない
# ripgrep も同梱されるため OS 側への導入は不要
ARG CLAUDE_CODE_VERSION=stable
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- "${CLAUDE_CODE_VERSION}"
ENV PATH="/home/dev/.local/bin:${PATH}"

WORKDIR /workspace
