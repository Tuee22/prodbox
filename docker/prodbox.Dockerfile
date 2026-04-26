# syntax=docker/dockerfile:1.7
FROM ubuntu:24.04

ARG GHC_VERSION=9.14.1
ARG CABAL_VERSION=3.16.1.0
ENV DEBIAN_FRONTEND=noninteractive
ENV PATH=/root/.ghcup/bin:/root/.cabal/bin:$PATH

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

ENTRYPOINT ["/usr/local/bin/prodbox"]
