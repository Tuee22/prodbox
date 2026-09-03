FROM ubuntu:24.04

ARG GHC_VERSION=9.12.4
ARG CABAL_VERSION=3.16.1.0
ARG PULUMI_VERSION=3.228.0
ARG KUBECTL_VERSION=v1.35.5
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

# Provider Worker runs only the checked-in, typed Pulumi programs below. Pin
# the CLI in the image so execution never depends on a mutable host binary.
RUN arch_name="$(dpkg --print-architecture)" \
    && case "${arch_name}" in \
        amd64) pulumi_arch=x64 ;; \
        arm64) pulumi_arch=arm64 ;; \
        *) echo "Unsupported Debian architecture: ${arch_name}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://get.pulumi.com/releases/sdk/pulumi-v${PULUMI_VERSION}-linux-${pulumi_arch}.tar.gz" -o /tmp/pulumi.tar.gz \
    && tar -xzf /tmp/pulumi.tar.gz -C /tmp \
    && install -m 0755 /tmp/pulumi/pulumi /usr/local/bin/pulumi \
    && rm -rf /tmp/pulumi /tmp/pulumi.tar.gz

# The Target Secret Agent coordinates exact one-shot Jobs through its
# namespaced RBAC. Pin kubectl to the proven RKE2 Kubernetes minor and verify
# the release checksum before installing it into the union runtime image.
RUN arch_name="$(dpkg --print-architecture)" \
    && case "${arch_name}" in \
        amd64) kubectl_arch=amd64 ;; \
        arm64) kubectl_arch=arm64 ;; \
        *) echo "Unsupported Debian architecture: ${arch_name}" >&2; exit 1 ;; \
    esac \
    && kubectl_url="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${kubectl_arch}/kubectl" \
    && curl -fsSL "${kubectl_url}" -o /tmp/kubectl \
    && curl -fsSL "${kubectl_url}.sha256" -o /tmp/kubectl.sha256 \
    && echo "$(cat /tmp/kubectl.sha256)  /tmp/kubectl" | sha256sum --check \
    && install -m 0755 /tmp/kubectl /usr/local/bin/kubectl \
    && rm -f /tmp/kubectl /tmp/kubectl.sha256

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
COPY pulumi ./pulumi

# Plain RUN — no BuildKit cache mounts. The build uses basic `docker build`
# with the daemon's default builder (no `docker buildx`, no docker-container
# builder, no BuildKit-only Dockerfile features). See
# documents/engineering/dependency_management.md §1.
RUN cabal update \
    && cabal build --builddir=.build exe:prodbox \
    && cp "$(cabal list-bin --builddir=.build exe:prodbox)" /usr/local/bin/prodbox \
    && rm -rf \
        .build \
        /root/.cache/cabal \
        /root/.local/state/cabal

# Sprint 1.49: the binary owns its config — there is NO committed/COPY-ed
# `docker/default-prodbox.dhall`. After the binary is installed, RUN it to
# generate the binary-sibling Tier-0 `prodbox.dhall` (beside the executable at
# `/usr/local/bin/prodbox.dhall`), the same filename/resolution the host CLI
# uses (config_doctrine.md §0, §3). This serves ephemeral in-container CLI
# commands; the long-running cluster daemon is configured by the
# `gateway-config-<nodeId>` ConfigMap override (unchanged). It carries no secret
# values — only `SecretRef.Vault` pointers. `--portable` keeps the baked
# host_capacity host-agnostic (the build container is not the deploy host, and
# the daemon overwrites this file from the ConfigMap at runtime); an operator
# generating on a real deploy host omits it to fit the observed machine
# (resource_scaling_doctrine.md §2B).
RUN /usr/local/bin/prodbox config generate --portable

# Bare `prodbox` under tini. Each chart supplies its own subcommand via the pod
# `args:` — the gateway chart passes `gateway start …`, the api/websocket charts
# pass `workload start …`.
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/prodbox"]
