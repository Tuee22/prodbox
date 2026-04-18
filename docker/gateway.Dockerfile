# Gateway container: Haskell-owned daemon runtime
FROM haskell:9.6.7 AS build

WORKDIR /opt/build

COPY prodbox.cabal cabal.project ./
RUN cabal update && cabal build --builddir=.build --only-dependencies exe:prodbox

COPY . .
RUN cabal build --builddir=.build exe:prodbox \
    && cp "$(cabal list-bin --builddir=.build exe:prodbox)" /usr/local/bin/prodbox

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends tini curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/local/bin/prodbox /usr/local/bin/prodbox

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/prodbox", "gateway", "start"]
