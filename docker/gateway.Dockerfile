# syntax=docker/dockerfile:1.7
FROM ubuntu:24.04

WORKDIR /opt/build

ARG GHC_VERSION=9.14.1
ARG CABAL_VERSION=3.16.1.0
ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive
ENV PATH=/root/.ghcup/bin:/root/.cabal/bin:$PATH

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

RUN case "${TARGETARCH}" in \
        amd64) aws_arch=x86_64 ;; \
        arm64) aws_arch=aarch64 ;; \
        *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
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

RUN --mount=type=cache,target=/root/.cabal \
    --mount=type=cache,target=/root/.config/cabal \
    cabal update \
    && cabal build --builddir=.build exe:prodbox \
    && cp "$(cabal list-bin --builddir=.build exe:prodbox)" /usr/local/bin/prodbox

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/prodbox", "gateway", "start"]
