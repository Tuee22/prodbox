# syntax=docker/dockerfile:1.7
FROM ubuntu:24.04

ARG GHC_VERSION=9.6.7
ENV DEBIAN_FRONTEND=noninteractive
ENV PATH=/opt/ghc/${GHC_VERSION}/bin:/usr/local/bin:$PATH

WORKDIR /opt/build

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        file \
        git \
        libffi-dev \
        libgmp-dev \
        libncurses-dev \
        libnuma-dev \
        libssl-dev \
        pkg-config \
        xz-utils \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

RUN --mount=type=bind,from=haskell-toolchain,src=/opt/ghc,target=/mnt/ghc,ro \
    --mount=type=bind,from=haskell-toolchain,src=/usr/local/bin/cabal,target=/mnt/cabal,ro \
    mkdir -p /opt/ghc /usr/local/bin \
    && cp -a /mnt/ghc/. /opt/ghc/ \
    && cp /mnt/cabal /usr/local/bin/cabal \
    && ln -sf /opt/ghc/${GHC_VERSION}/bin/ghc-${GHC_VERSION} /usr/local/bin/ghc \
    && ln -sf /opt/ghc/${GHC_VERSION}/bin/ghc-pkg-${GHC_VERSION} /usr/local/bin/ghc-pkg \
    && ln -sf /opt/ghc/${GHC_VERSION}/bin/ghci-${GHC_VERSION} /usr/local/bin/ghci \
    && ln -sf /opt/ghc/${GHC_VERSION}/bin/runghc-${GHC_VERSION} /usr/local/bin/runghc \
    && ln -sf /opt/ghc/${GHC_VERSION}/bin/runhaskell-${GHC_VERSION} /usr/local/bin/runhaskell \
    && ln -sf /opt/ghc/${GHC_VERSION}/bin/hsc2hs-ghc-${GHC_VERSION} /usr/local/bin/hsc2hs \
    && ln -sf /opt/ghc/${GHC_VERSION}/bin/haddock-ghc-${GHC_VERSION} /usr/local/bin/haddock \
    && ln -sf /opt/ghc/${GHC_VERSION}/bin/hp2ps-ghc-${GHC_VERSION} /usr/local/bin/hp2ps \
    && ln -sf /opt/ghc/${GHC_VERSION}/bin/hpc-ghc-${GHC_VERSION} /usr/local/bin/hpc

COPY prodbox.cabal cabal.project LICENSE README.md ./
COPY app ./app
COPY src ./src

RUN --mount=type=cache,target=/root/.cabal \
    --mount=type=cache,target=/root/.config/cabal \
    cabal update \
    && cabal build --builddir=.build exe:prodbox \
    && cp "$(cabal list-bin --builddir=.build exe:prodbox)" /usr/local/bin/prodbox

ENTRYPOINT ["/usr/local/bin/prodbox"]
