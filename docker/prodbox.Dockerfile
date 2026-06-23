FROM ubuntu:24.04

ARG GHC_VERSION=9.12.4
ARG CABAL_VERSION=3.16.1.0
ENV DEBIAN_FRONTEND=noninteractive
ENV PATH=/root/.ghcup/bin:/root/.cabal/bin:$PATH
# Default container locale is C/POSIX with no UTF-8 support. The prodbox binary's
# Dhall decoder fails on UTF-8 byte sequences such as `§` (0xC2 0xA7) that
# appear in chart-rendered config comments without this. See
# documents/engineering/config_doctrine.md §6.
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

WORKDIR /opt/build

# One union runtime image for every in-cluster role (gateway daemon + api /
# websocket workloads). It is the SAME compiled `prodbox` binary; the role is
# selected by each chart's container `args:` (`gateway start` vs `workload
# start`). `tini` is PID 1 for clean signal handling / graceful drain of the
# long-running gateway daemon; the AWS CLI is bundled because the gateway shells
# out to `aws route53 change-resource-record-sets` for DNS writes.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        file \
        git \
        gnupg \
        libffi-dev \
        libgmp-dev \
        libncurses-dev \
        libnuma-dev \
        libssl-dev \
        pkg-config \
        tini \
        unzip \
        xz-utils \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

RUN arch_name="$(dpkg --print-architecture)" \
    && case "${arch_name}" in \
        amd64) aws_arch=x86_64 ;; \
        arm64) aws_arch=aarch64 ;; \
        *) echo "Unsupported Debian architecture: ${arch_name}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${aws_arch}.zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscliv2.zip

RUN curl --proto '=https' --tlsv1.2 -fsSL https://get-ghcup.haskell.org -o /tmp/ghcup.sh \
    && chmod +x /tmp/ghcup.sh \
    && BOOTSTRAP_HASKELL_NONINTERACTIVE=1 \
       BOOTSTRAP_HASKELL_MINIMAL=1 \
       BOOTSTRAP_HASKELL_ADJUST_BASHRC=0 \
       /tmp/ghcup.sh \
    && ghcup install ghc "${GHC_VERSION}" \
    && ghcup set ghc "${GHC_VERSION}" \
    && ghcup install cabal "${CABAL_VERSION}" \
    && ghcup set cabal "${CABAL_VERSION}" \
    && rm -f /tmp/ghcup.sh

COPY prodbox.cabal cabal.project LICENSE README.md ./
COPY app ./app
COPY src ./src

# Plain RUN — no BuildKit cache mounts. The build uses basic `docker build`
# with the daemon's default builder (no `docker buildx`, no docker-container
# builder, no BuildKit-only Dockerfile features). See
# documents/engineering/dependency_management.md §1.
RUN cabal update \
    && cabal build --builddir=.build exe:prodbox \
    && cp "$(cabal list-bin --builddir=.build exe:prodbox)" /usr/local/bin/prodbox

# Sprint 1.40: bake in the default Tier-0 `prodbox.dhall` binary context so a
# freshly started container has a valid non-secret binary context BEFORE any
# ConfigMap is mounted (config_doctrine.md §0, §3). The in-cluster daemon
# OVERWRITES this from the `gateway-config-<nodeId>` ConfigMap mount at startup.
# The file is the Haskell-rendered source of truth
# (`Prodbox.Config.Tier0.defaultDaemonProjectConfig`), kept in sync with the
# renderer by `prodbox dev check` (a tracked generated artifact). It carries no
# secret values — only `SecretRef.Vault` pointers.
COPY docker/default-prodbox.dhall /etc/prodbox/prodbox.dhall

# Bare `prodbox` under tini. Each chart supplies its own subcommand via the pod
# `args:` — the gateway chart passes `gateway start …`, the api/websocket charts
# pass `workload start …`.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/prodbox"]
