# File: docker/gateway.Dockerfile
FROM python:3.12-slim

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends tini \
    && rm -rf /var/lib/apt/lists/*

RUN python -m pip install --upgrade pip setuptools wheel poetry

COPY . /app

RUN printf "[virtualenvs]\ncreate = false\n\n[keyring]\nenabled = false\n" > /app/poetry.toml
RUN poetry install --only main --no-interaction --no-ansi

ENTRYPOINT ["/usr/bin/tini", "--", "daemon"]
