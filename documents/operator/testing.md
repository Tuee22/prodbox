# Testing Workflows

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Target test runner, isolation and evidence contract.

> **Purpose**: Explain how tests use the real product workflow while protecting production and proving assertions can fail.

Author `prodbox.test.dhall` with `test init`. Keep externally chosen sensitive/test inputs in owner-safe `test-secrets.dhall`. `test run NAME` selects a named scenario, generates its own explicit config and `.test-data/<run-id>` context through the production builder, executes actual public handlers, and consumes the shared cleanup result. It never rewrites the operator's production sibling.

A run has distinct kind/context/ports/mounts, MinIO/Vault identities and cloud ownership. Test SES sender/receive identities, SMTP credentials, capture data/buckets, DNS and owned rules are separate from production. Cases may reuse their own campaign's resources. If the AWS account is shared, coordinate its regional active receiving container without switching production's set or deleting another owner's rules. Collision fails before effects.

`test cleanup RUN_ID` resumes that exact run's shared deletion engine and retires disposable local resources only after required cloud absence/credential retirement. Failed cleanup retains the run and needed evidence/capability; deleting a directory is not a successful cleanup report.

Real acceptance uses unmodified built code and actual provider/components, with independent observers and negative controls. Mutation testing executes named faulty source copies offline to prove unchanged assertions detect ownership, false-clean and retirement mistakes. Mutants never receive real AWS/elevated input, production roots, ambient kubeconfig or unrestricted runtime sockets. Compilation errors/timeouts are not kills. See [mutation cases](../../DEVELOPMENT_PLAN/mutation_cases.md).

The target runner exposes cumulative `test run phase-NN`, scoped mutations and final `test run all`. Until implemented, use only actual current binary help. Phase 0 proves its checker acceptance with existing compiler/test tools and does not wait for a future test runner.
