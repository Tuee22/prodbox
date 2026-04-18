FROM haskell:9.6.7 AS build

WORKDIR /opt/build

COPY prodbox.cabal cabal.project ./
RUN cabal update

COPY app ./app
COPY src ./src
COPY LICENSE README.md ./

RUN cabal build --builddir=.build exe:prodbox
RUN cp "$(cabal list-bin --builddir=.build exe:prodbox)" /opt/build/prodbox

FROM debian:bookworm-slim AS runtime

WORKDIR /opt/build
COPY --from=build /opt/build/.build /opt/build/.build
COPY --from=build /opt/build/prodbox /usr/local/bin/prodbox

ENTRYPOINT ["/usr/local/bin/prodbox"]
