# Manual AWS Cleanup Before Refactor

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Historical point-in-time hand-action record from 2026-11; not deployment qualification.

> **Purpose**: Record the explicit manual AWS cleanup without treating it as evidence that the existing lifecycle implementation works.

The operator explicitly requested use of the owner-safe `test-secrets.dhall` elevated fixture to inspect AWS directly and remove deployed prodbox resources. This one-time authorization superseded the normal prodbox-only mutation boundary for that task; it is not a standing permission for future manual work.

Service-specific inventory covered all 17 then-enabled commercial regions and global IAM/S3/Route 53. No deployed prodbox compute, network, volume, SES, registry, managed-bucket or generated-IAM family was identified. Five legacy prodbox public-edge A records were deleted; Route 53 reported INSYNC and independent read-back confirmed their absence while unrelated records stayed exact. The parent domain/zone, bootstrap principal, unrelated bucket, default VPC scaffolding and preexisting unowned SSH metadata were preserved.

Local Kubernetes, `.data/`, `.test-data/`, configuration and Vault state were not reset. The report does not establish an empty AWS account, future absence, or usable local retained custody. Any later lifecycle admission takes fresh scoped observations.

The recorded non-secret local evidence path was `.build/manual-aws-cleanup/summary.json`, with adjacent service inventories and deletion receipts. Those files are not present in this checkout; their availability must be established before relying on them, and L20 governs retention if they are needed. No elevated key material was written into these reports.
