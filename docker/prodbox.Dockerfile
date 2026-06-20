# syntax=docker/dockerfile:1.7
FROM ubuntu:24.04

ARG GHC_VERSION=9.14.1
ARG CABAL_VERSION=3.16.1.0
ENV DEBIAN_FRONTEND=noninteractive
ENV PATH=/root/.ghcup/bin:/root/.cabal/bin:$PATH
# Default container locale is C/POSIX with no UTF-8 support. The workload's
# Dhall decoder fails on UTF-8 byte sequences such as `§` (0xC2 0xA7) that
# appear in chart-rendered config comments without this. See
# documents/engineering/config_doctrine.md §6.
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

WORKDIR /opt/build

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
        xz-utils \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

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

RUN --mount=type=cache,target=/root/.cabal \
    --mount=type=cache,target=/root/.config/cabal \
    cabal update \
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

ENTRYPOINT ["/usr/local/bin/prodbox"]
