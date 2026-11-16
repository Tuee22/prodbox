# Credentials and Vault Unlock

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Accepted production/test input and custody contract.

> **Purpose**: Explain when an operator supplies elevated input and how test automation simulates that same workflow.

The ordinary operator supplies elevated AWS input through the protected prompt. It is used ephemerally by a bounded credential worker to create/recover/revoke narrowly scoped prodbox identities after durable intent registration. Generated operational credentials are delivered to scoped Vault paths and used only by their authorized roles. Elevation is never copied into ordinary config, Vault, MinIO, Kubernetes objects, argv, environment, logs or reports.

The harness reads `aws_admin_for_test_simulation` from the owner-safe `test-secrets.dhall` fixture and feeds the same ingress. That user-owned fixture is the deliberate test source; no second runtime copy is created. It must be a regular non-symlink file owned by the effective user with no group/other mode bits, validated on the opened descriptor. Ambient AWS login/profile/env state is not an alternative.

An initialized sealed Vault is unlocked within an operation when needed. Production uses configured protected custody or prompts for its password. Without an interactive terminal or configured secure input, return NeedsInput with a remedy. `--yes` is deletion confirmation, not secret input.

Tests may explicitly use their own MinIO bootstrap unlock object to self-unseal. That access is available before Vault, scoped to the run and forbidden for production. It never contains elevated AWS credentials. Same-Vault recovery preserves its data; a missing or mismatched retained root is not an invitation to initialize over it.

On incomplete cloud cleanup, credentials and their exact ownership remain available or recoverable. Successful cleanup removes dependants first, verifies IAM retirement through the separately established verifier, then retires the corresponding Vault generation. [Security contract](../engineering/security_and_credentials.md)
