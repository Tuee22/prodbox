# Setup and Target Selection

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Target operation; commands become supported only through their phase acceptance.

> **Purpose**: Describe the short setup path and distinguish control-plane preparation from application/cloud provisioning.

The target is Linux with pinned container-runtime/kind tooling, one explicit production specification, and retained management state. Use `config setup` or `config generate` to author the binary-sibling non-secret Dhall specification, then validate it. Secrets are references or separately prompted input. Never paste elevated AWS credentials into ordinary configuration.

`control reconcile` creates/restores kind, exact host mounts, pinned management images, Vault/MinIO/Broker and the management capability closure. It does not provision an AWS application. A cold start does not need the registry, public DNS/TLS, SES or remote AWS backup. Production data belongs under `.data/<installation-id>`; control-cluster recreation preserves that root.

`reconcile --target local` installs the canonical local application services. `reconcile --target aws` uses the retained local control plane to provision the same application/platform projection on EKS. The latter becomes supported in Phase 8; the earlier storage-canary is not a pretend EKS target. Select desired targets in the explicit specification; no checkpoint chooses the substrate for you.

Supply only external prerequisites needed by the requested feature. Local status/bootstrap must not demand an application domain or AWS region. Real public edge needs declared domain/parent-zone and ACME/SES inputs. Cloud creation uses the ephemeral credential workflow in [credentials](credentials.md).

See [configuration](../engineering/configuration.md) for exact source partition and [control plane](../engineering/control_plane.md) for mounts, network publication, resource reserves and recovery. The current binary may still call its old local path `cluster`; documentation adoption does not rename its parser or convert live mounts.
