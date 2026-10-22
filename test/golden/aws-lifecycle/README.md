# AWS lifecycle recordings

**Status**: Supporting document
**Supersedes**: N/A
**Generated sections**: none

> **Purpose**: Identify each fixture's provenance and the boundary of the behaviour it supports.

Every JSON artifact is emitted by `scrubProviderRecording`. Its envelope identifies the scrubber
version and hashes the canonical, scrubbed transcript. Raw transcripts remain outside the repository.
Explicit name substitutions accompany input containing operator-authored domains, bucket names or
principal names. The scrubber independently replaces accounts, ARNs, EC2 identifiers, IP addresses
and request ids, preserves call order and relative delays, and refuses credential-shaped content.
It refuses an oversized recording instead of truncating it.

| Artifact | Provenance | What it supports |
|---|---|---|
| `operator-inventory-2026-10-14.json` | Shapes transcribed by hand in Sprint 4.111 from the operator's inventory; original provider bytes are unavailable | Normalized CNI interface and orphaned cluster-group fields. The hand transcription records the projected cluster field, not original tag keys or provider bytes; no raw tags or timing are inferred. |
| `dependency-contract-assumptions.json` | Authored dependency examples | Assumption-labelled interface-held and mutually referenced group semantics. It is not a live error capture. |
| `requester-managed-release-assumption.json` | Authored virtual release schedule | Assumption-labelled requester-managed release lag. The ninety seconds are a test input. |
| `dependency-cli-loopback.json` | Installed AWS CLI 2.34.18, unsigned requests to a local HTTP fixture returning EC2 Query errors | Actual CLI stderr framing, exit codes and call intervals. The response is authored; no AWS service was contacted. |
| `network-projections-cli-loopback.json` | Installed AWS CLI 2.34.18, unsigned describe requests to local EC2 Query XML fixtures | Optional rule lists project to null when omitted; the consumed `not_null` query produces empty arrays. The normalized query digest binds the recording to its consumer. |
| `stack-dependency-assumptions.json` | Authored subnet, VPC, cluster and load-balancer dependency examples | Assumption-labelled parent dependencies and a ninety-second virtual load-balancer release; no live timing measurement. |

The EC2 [CreateNetworkInterface API](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_CreateNetworkInterface.html)
defines client-token idempotency and tag-on-create; the
[CreateSecurityGroup API](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_CreateSecurityGroup.html)
defines VPC-local name uniqueness and tag-on-create; the
[DeleteSecurityGroup API](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_DeleteSecurityGroup.html)
defines interface and peer-reference dependencies. Those API contracts inform the authored cases;
they do not turn them into provider observations.

Live recording acquisition and class-closure status belong to
[the resumption ledger](../../../DEVELOPMENT_PLAN/README.md#resume-here) and
[Sprint 5.59](../../../DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md).

The [SecurityGroup](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_SecurityGroup.html)
and [IpPermission](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/API_IpPermission.html)
response contracts make these list fields optional. Identity, VPC and owned-tag projections stay
required at the decoder; normalizing optional rule arrays does not relax those checks.
