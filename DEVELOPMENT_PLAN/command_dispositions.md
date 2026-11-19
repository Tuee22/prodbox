# Command Dispositions

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Adopted target contract and captured current-binary migration inventory

> **Purpose**: Account for every current command leaf and option while simplifying operator commands without dropping capabilities.

## Baseline and interpretation

Captured from the existing built binary's `commands --json` at source baseline `583443f`: **138 leaves, 65 distinct long-option names, 554 inherited/leaf option occurrences**. The generated [current command reference](../documents/cli/commands.md) remains a current-binary artifact. This table is the migration contract, not a claim that target paths run today. Phase 0 must bind this capture to source `CommandSpec` and test exact coverage before new parser work.

Phase 1 adds an inherited `--config` occurrence to each current leaf; local
runtime `--config` occurrences remain separate. The selected path currently
works for authored configuration validation, bootstrap setup and local control
status/plan. Other
commands refuse it until their handlers carry the selected context.

Each current leaf has one disposition and final owning phase. The required-options column captures inherited and leaf requiredness from the current registry; it does not independently prove parser behavior. Earlier partial capability activation is allowed only with real acceptance. For operator/maintenance leaves, the listed owner closes their retained scope. Internalized launcher rows owned by Phase 1 close only namespace/parser/visibility relocation with unchanged authenticated dispatch; they do not claim that later Authority, Provisioner, TLS or application runtime behavior already works. Those actual capabilities are validated by their consuming phases in the component/objective catalogs. Temporary cleanup for original identities belongs to L18/Phase 10, not a second ordinary command. Every alias and short option must follow its long-option disposition. Meaningful positional operands are specified after the leaf table.

Disposition `Preserved` retains capability with the common context/engine. `Replaced` changes its path/semantics explicitly. `Internalized` retains authenticated runtime capability outside normal help. `Removed` eliminates an overloaded route only after its stated replacement works. `plan|apply` denotes two closed subcommands, not shell passthrough.

## Exact leaf coverage

| ID | Current leaf | Target path/capability | Disposition | Phase | Visibility | Current options (including inherited globals) | Required options |
|---|---|---|---|---:|---|---|---|
| C001 | `prodbox admin-action run` | `prodbox internal admin-action run` | Internalized | 1 | Internal | `--verbose`, `--version`, `--action`, `--operation-id`, `--deadline-micros`, `--pod-name-file`, `--pod-uid-file`, `--service-account-token-file`, `--dry-run`, `--plan-file`, `--config` | `--action`, `--operation-id`, `--deadline-micros`, `--pod-name-file`, `--pod-uid-file`, `--service-account-token-file` |
| C002 | `prodbox aws policy` | `prodbox admin aws credentials policy` | Replaced | 5 | Maintenance | `--verbose`, `--version`, `--tier`, `--config` | — |
| C003 | `prodbox aws setup` | `prodbox admin aws credentials reconcile` | Replaced | 4 | Maintenance | `--verbose`, `--version`, `--tier`, `--dry-run`, `--plan-file`, `--config` | — |
| C004 | `prodbox aws teardown` | `prodbox admin aws credentials revoke` | Replaced | 4 | Maintenance | `--verbose`, `--version`, `--dry-run`, `--plan-file`, `--destroy-pulumi-residue`, `--allow-pulumi-residue`, `--config` | — |
| C005 | `prodbox aws quotas check` | `prodbox admin aws quotas check` | Preserved | 5 | Maintenance | `--verbose`, `--version`, `--config` | — |
| C006 | `prodbox aws quotas request` | `prodbox admin aws quotas request` | Preserved | 5 | Maintenance | `--verbose`, `--version`, `--tier`, `--config` | — |
| C007 | `prodbox aws audit` | `prodbox admin aws audit` | Preserved | 8 | Maintenance | `--verbose`, `--version`, `--stack`, `--emit-readonly-script`, `--config` | — |
| C008 | `prodbox aws ebs reap-test` | `prodbox admin aws recovery plan / apply ebs` | Replaced | 8 | Maintenance | `--verbose`, `--version`, `--yes`, `--config` | — |
| C009 | `prodbox aws stack eks diff` | `prodbox admin aws stack eks diff` | Replaced | 8 | Maintenance | `--verbose`, `--version`, `--config` | — |
| C010 | `prodbox aws stack eks reconcile` | `prodbox admin aws stack eks reconcile` | Replaced | 8 | Maintenance | `--verbose`, `--version`, `--dry-run`, `--plan-file`, `--config` | — |
| C011 | `prodbox aws stack eks destroy` | `prodbox admin aws stack eks delete` | Replaced | 8 | Maintenance | `--verbose`, `--version`, `--yes`, `--dry-run`, `--plan-file`, `--config` | — |
| C012 | `prodbox aws stack eks prune-corrupt-checkpoint` | `prodbox admin aws recovery plan / apply checkpoint-eks` | Replaced | 8 | Maintenance | `--verbose`, `--version`, `--yes`, `--config` | — |
| C013 | `prodbox aws stack eks adopt-legacy plan` | `prodbox admin aws recovery plan adopt-eks` | Replaced | 8 | Maintenance | `--verbose`, `--version`, `--config` | — |
| C014 | `prodbox aws stack eks adopt-legacy apply` | `prodbox admin aws recovery apply adopt-eks` | Replaced | 8 | Maintenance | `--verbose`, `--version`, `--plan-digest`, `--yes`, `--config` | `--plan-digest` |
| C015 | `prodbox aws stack eks purge-dependents` | `prodbox admin aws recovery plan / apply eks-dependents` | Replaced | 8 | Maintenance | `--verbose`, `--version`, `--yes`, `--plan-digest`, `--config` | — |
| C016 | `prodbox aws stack test diff` | `prodbox admin migration inspect aws-test` | Replaced | 10 | Maintenance | `--verbose`, `--version`, `--config` | — |
| C017 | `prodbox aws stack test reconcile` | `prodbox test run gateway-ha` | Removed | 9 | Developer | `--verbose`, `--version`, `--dry-run`, `--plan-file`, `--config` | — |
| C018 | `prodbox aws stack test destroy` | `prodbox admin migration cleanup aws-test` | Replaced | 10 | Maintenance | `--verbose`, `--version`, `--yes`, `--dry-run`, `--plan-file`, `--config` | — |
| C019 | `prodbox aws stack test prune-corrupt-checkpoint` | `prodbox admin migration recovery plan / apply aws-test` | Replaced | 10 | Maintenance | `--verbose`, `--version`, `--yes`, `--config` | — |
| C020 | `prodbox aws stack test adopt-legacy plan` | `prodbox admin migration recovery plan / apply aws-test` | Replaced | 10 | Maintenance | `--verbose`, `--version`, `--config` | — |
| C021 | `prodbox aws stack test adopt-legacy apply` | `prodbox admin migration recovery plan / apply aws-test` | Replaced | 10 | Maintenance | `--verbose`, `--version`, `--plan-digest`, `--yes`, `--config` | `--plan-digest` |
| C022 | `prodbox aws stack aws-subzone diff` | `prodbox admin aws stack subzone diff` | Replaced | 8 | Maintenance | `--verbose`, `--version`, `--config` | — |
| C023 | `prodbox aws stack aws-subzone reconcile` | `prodbox admin aws stack subzone reconcile` | Replaced | 8 | Maintenance | `--verbose`, `--version`, `--dry-run`, `--plan-file`, `--config` | — |
| C024 | `prodbox aws stack aws-subzone destroy` | `prodbox admin aws stack subzone delete` | Replaced | 8 | Maintenance | `--verbose`, `--version`, `--yes`, `--dry-run`, `--plan-file`, `--config` | — |
| C025 | `prodbox aws stack aws-subzone prune-corrupt-checkpoint` | `prodbox admin aws recovery plan / apply checkpoint-subzone` | Replaced | 8 | Maintenance | `--verbose`, `--version`, `--yes`, `--config` | — |
| C026 | `prodbox aws stack aws-subzone adopt-legacy plan` | `prodbox admin aws recovery plan adopt-subzone` | Replaced | 8 | Maintenance | `--verbose`, `--version`, `--config` | — |
| C027 | `prodbox aws stack aws-subzone adopt-legacy apply` | `prodbox admin aws recovery apply adopt-subzone` | Replaced | 8 | Maintenance | `--verbose`, `--version`, `--plan-digest`, `--yes`, `--config` | `--plan-digest` |
| C028 | `prodbox aws stack aws-ses diff` | `prodbox admin aws stack ses diff` | Replaced | 7 | Maintenance | `--verbose`, `--version`, `--config` | — |
| C029 | `prodbox aws stack aws-ses reconcile` | `prodbox admin aws stack ses reconcile` | Replaced | 7 | Maintenance | `--verbose`, `--version`, `--dry-run`, `--plan-file`, `--config` | — |
| C030 | `prodbox aws stack aws-ses destroy` | `prodbox admin aws stack ses delete` | Replaced | 7 | Maintenance | `--verbose`, `--version`, `--yes`, `--dry-run`, `--plan-file`, `--config` | — |
| C031 | `prodbox aws stack aws-ses migrate-backend` | `prodbox admin aws recovery plan / apply ses-backend` | Replaced | 7 | Maintenance | `--verbose`, `--version`, `--dry-run`, `--plan-file`, `--config` | — |
| C032 | `prodbox bootstrap-broker start` | `prodbox internal bootstrap-broker start` | Internalized | 1 | Internal | `--verbose`, `--version`, `--config`, `--dry-run`, `--plan-file`, `--config` | `--config` |
| C033 | `prodbox bootstrap-broker secret-worker` | `prodbox internal bootstrap-broker secret-worker` | Internalized | 1 | Internal | `--verbose`, `--version`, `--operation`, `--config`, `--config` | `--operation`, `--config` |
| C034 | `prodbox credential-provisioner run` | `prodbox internal credential-provisioner run` | Internalized | 1 | Internal | `--verbose`, `--version`, `--ingress-schema`, `--mode`, `--operation-id`, `--permit-id`, `--request-digest`, `--deadline-micros`, `--image-digest`, `--authority-scope`, `--authority-endpoint`, `--pod-name-file`, `--pod-uid-file`, `--service-account-token-file`, `--dry-run`, `--plan-file`, `--config` | `--ingress-schema`, `--permit-id`, `--request-digest`, `--deadline-micros`, `--pod-uid-file`, `--service-account-token-file` |
| C035 | `prodbox credential-provisioner target-worker` | `prodbox internal credential-provisioner target-worker` | Internalized | 1 | Internal | `--verbose`, `--version`, `--target`, `--target-agent-identity`, `--material-schema`, `--image-digest`, `--request-digest`, `--deadline-micros`, `--pod-uid-file`, `--pod-name-file`, `--service-account-token-file`, `--dry-run`, `--plan-file`, `--config` | `--target`, `--target-agent-identity`, `--material-schema`, `--image-digest`, `--request-digest`, `--deadline-micros`, `--pod-uid-file`, `--pod-name-file`, `--service-account-token-file` |
| C036 | `prodbox lifecycle-authority start` | `prodbox internal lifecycle-authority start` | Internalized | 1 | Internal | `--verbose`, `--version`, `--config`, `--dry-run`, `--plan-file`, `--config` | `--config` |
| C037 | `prodbox provider-worker start` | `prodbox internal provider-worker start` | Internalized | 1 | Internal | `--verbose`, `--version`, `--config`, `--dry-run`, `--plan-file`, `--config` | `--config` |
| C038 | `prodbox authority-backup start` | `prodbox internal authority-backup start` | Internalized | 1 | Internal | `--verbose`, `--version`, `--config`, `--dry-run`, `--plan-file`, `--config` | `--config` |
| C039 | `prodbox tls-retention start` | `prodbox internal tls-retention start` | Internalized | 1 | Internal | `--verbose`, `--version`, `--config`, `--dry-run`, `--plan-file`, `--config` | `--config` |
| C040 | `prodbox target-secret-agent start` | `prodbox internal target-secret-agent start` | Internalized | 1 | Internal | `--verbose`, `--version`, `--config`, `--dry-run`, `--plan-file`, `--config` | `--config` |
| C041 | `prodbox charts list` | `prodbox services list` | Replaced | 6 | Operator | `--verbose`, `--version`, `--config` | — |
| C042 | `prodbox charts status` | `prodbox services status` | Replaced | 6 | Operator | `--verbose`, `--version`, `--config` | — |
| C043 | `prodbox charts reconcile` | `prodbox admin services reconcile` | Replaced | 6 | Maintenance | `--verbose`, `--version`, `--dry-run`, `--plan-file`, `--substrate`, `--config` | — |
| C044 | `prodbox charts delete` | `prodbox admin services delete` | Replaced | 6 | Maintenance | `--verbose`, `--version`, `--yes`, `--dry-run`, `--plan-file`, `--substrate`, `--config` | — |
| C045 | `prodbox cluster status` | `prodbox status` | Replaced | 3 | Operator | `--verbose`, `--version`, `--config` | — |
| C046 | `prodbox cluster health` | `prodbox admin control health` | Replaced | 3 | Maintenance | `--verbose`, `--version`, `--config` | — |
| C047 | `prodbox cluster start` | `prodbox admin control start` | Replaced | 1 | Maintenance | `--verbose`, `--version`, `--config` | — |
| C048 | `prodbox cluster stop` | `prodbox admin control stop` | Replaced | 3 | Maintenance | `--verbose`, `--version`, `--config` | — |
| C049 | `prodbox cluster restart` | `prodbox admin control restart` | Replaced | 3 | Maintenance | `--verbose`, `--version`, `--config` | — |
| C050 | `prodbox cluster reconcile` | `prodbox reconcile` | Replaced | 8 | Operator | `--verbose`, `--version`, `--dry-run`, `--plan-file`, `--with-edge`, `--config` | — |
| C051 | `prodbox cluster delete` | `prodbox delete / control delete` | Replaced | 8 | Operator | `--verbose`, `--version`, `--yes`, `--cascade`, `--dry-run`, `--plan-file`, `--config` | — |
| C052 | `prodbox cluster logs` | `prodbox admin control logs` | Replaced | 1 | Maintenance | `--verbose`, `--version`, `--lines`, `--config` | — |
| C053 | `prodbox cluster federation register` | `prodbox admin federation register` | Replaced | 9 | Maintenance | `--verbose`, `--version`, `--dry-run`, `--plan-file`, `--child-vault-address`, `--child-kubeconfig`, `--child-endpoint`, `--child-kubeconfig-reference`, `--child-account-id`, `--child-pulumi-stack`, `--config` | — |
| C054 | `prodbox cluster wait` | `prodbox admin control wait` | Replaced | 3 | Maintenance | `--verbose`, `--version`, `--timeout`, `--namespace`, `--config` | — |
| C055 | `prodbox cluster workload-logs` | `prodbox services logs` | Replaced | 6 | Operator | `--verbose`, `--version`, `--namespace`, `--tail`, `--config` | — |
| C056 | `prodbox commands` | `prodbox commands` | Preserved | 1 | Operator | `--verbose`, `--version`, `--tree`, `--json`, `--config` | — |
| C057 | `prodbox config setup` | `prodbox config setup` | Preserved | 1 | Operator | `--verbose`, `--version`, `--dry-run`, `--plan-file`, `--config` | — |
| C058 | `prodbox config show` | `prodbox config show` | Preserved | 1 | Operator | `--verbose`, `--version`, `--config` | — |
| C059 | `prodbox config validate` | `prodbox config validate` | Preserved | 1 | Operator | `--verbose`, `--version`, `--config` | — |
| C060 | `prodbox config schema` | `prodbox config schema` | Preserved | 1 | Operator | `--verbose`, `--version`, `--config` | — |
| C061 | `prodbox config generate` | `prodbox config generate` | Preserved | 1 | Operator | `--verbose`, `--version`, `--config` | — |
| C062 | `prodbox dev check` | `prodbox dev check` | Preserved | 0 | Developer | `--verbose`, `--version`, `--config` | — |
| C063 | `prodbox dev lint all` | `prodbox dev lint all` | Preserved | 0 | Developer | `--verbose`, `--version`, `--config` | — |
| C064 | `prodbox dev lint files` | `prodbox dev lint files` | Preserved | 0 | Developer | `--verbose`, `--version`, `--write`, `--config` | — |
| C065 | `prodbox dev lint docs` | `prodbox dev lint docs` | Preserved | 0 | Developer | `--verbose`, `--version`, `--write`, `--config` | — |
| C066 | `prodbox dev lint haskell` | `prodbox dev lint haskell` | Preserved | 0 | Developer | `--verbose`, `--version`, `--write`, `--config` | — |
| C067 | `prodbox dev lint chart` | `prodbox dev lint chart` | Preserved | 0 | Developer | `--verbose`, `--version`, `--config` | — |
| C068 | `prodbox dev docs check` | `prodbox dev docs check` | Preserved | 0 | Developer | `--verbose`, `--version`, `--config` | — |
| C069 | `prodbox dev docs generate` | `prodbox dev docs generate` | Preserved | 0 | Developer | `--verbose`, `--version`, `--config` | — |
| C070 | `prodbox dev tla-check` | `prodbox dev tla-check` | Preserved | 0 | Developer | `--verbose`, `--version`, `--config` | — |
| C071 | `prodbox dns check` | `prodbox admin dns check` | Replaced | 7 | Maintenance | `--verbose`, `--version`, `--config` | — |
| C072 | `prodbox edge reconcile` | `prodbox admin edge reconcile` | Replaced | 7 | Maintenance | `--verbose`, `--version`, `--dry-run`, `--plan-file`, `--config` | — |
| C073 | `prodbox edge status` | `prodbox admin edge status` | Replaced | 7 | Maintenance | `--verbose`, `--version`, `--substrate`, `--config` | — |
| C074 | `prodbox gateway start` | `prodbox internal gateway start` | Internalized | 1 | Internal | `--verbose`, `--version`, `--config`, `--dry-run`, `--plan-file`, `--config` | — |
| C075 | `prodbox gateway status` | `prodbox services status gateway` | Replaced | 6 | Operator | `--verbose`, `--version`, `--config`, `--config` | — |
| C076 | `prodbox gateway config-gen` | `prodbox dev config gateway` | Replaced | 6 | Developer | `--verbose`, `--version`, `--node-id`, `--config` | `--node-id` |
| C077 | `prodbox help` | `prodbox help` | Preserved | 1 | Operator | `--verbose`, `--version`, `--config` | — |
| C078 | `prodbox host ensure-tools` | `prodbox admin host ensure-tools` | Replaced | 1 | Maintenance | `--verbose`, `--version`, `--config` | — |
| C079 | `prodbox host check-ses-readiness` | `prodbox admin host check-ses-readiness` | Replaced | 7 | Maintenance | `--verbose`, `--version`, `--config` | — |
| C080 | `prodbox host check-ports` | `prodbox admin host check-ports` | Replaced | 1 | Maintenance | `--verbose`, `--version`, `--config` | — |
| C081 | `prodbox host info` | `prodbox admin host info` | Replaced | 1 | Maintenance | `--verbose`, `--version`, `--config` | — |
| C082 | `prodbox host firewall gateway-restrict` | `prodbox admin host firewall gateway-restrict` | Replaced | 1 | Maintenance | `--verbose`, `--version`, `--port`, `--config` | — |
| C083 | `prodbox host firewall gateway-unrestrict` | `prodbox admin host firewall gateway-unrestrict` | Replaced | 1 | Maintenance | `--verbose`, `--version`, `--port`, `--config` | — |
| C084 | `prodbox internal-rpc-birth-controller` | `prodbox internal rpc-birth-controller` | Internalized | 1 | Internal | `--verbose`, `--version`, `--config`, `--request`, `--input-fingerprint`, `--operation-key`, `--outer-ns`, `--work-ns`, `--hard-ns`, `--stop-ns`, `--finish-ns`, `--config` | `--config`, `--request`, `--input-fingerprint`, `--operation-key`, `--outer-ns`, `--work-ns`, `--hard-ns`, `--stop-ns`, `--finish-ns` |
| C085 | `prodbox nuke` | `prodbox delete / admin control purge-data` | Removed | 8 | Operator / Maintenance | `--verbose`, `--version`, `--dry-run`, `--plan-file`, `--receipt`, `--local-data`, `--config` | — |
| C086 | `prodbox test init` | `prodbox test init` | Preserved | 1 | Developer | `--verbose`, `--version`, `--force`, `--config` | — |
| C087 | `prodbox test run` | `prodbox test run NAME` | Preserved | 1 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C088 | `prodbox test all` | `prodbox test run all` | Replaced | 10 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C089 | `prodbox test lint` | `prodbox dev check` | Replaced | 0 | Developer | `--verbose`, `--version`, `--config` | — |
| C090 | `prodbox test unit` | `prodbox test run unit` | Replaced | 1 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C091 | `prodbox test integration all` | `prodbox test run all` | Replaced | 10 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C092 | `prodbox test integration cli` | `prodbox test run cli` | Replaced | 1 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C093 | `prodbox test integration aws-iam` | `prodbox test run aws-iam` | Replaced | 4 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C094 | `prodbox test integration dns-aws` | `prodbox test run dns-aws` | Replaced | 7 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C095 | `prodbox test integration aws-eks` | `prodbox test run aws-eks` | Replaced | 8 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C096 | `prodbox test integration env` | `prodbox test run env` | Replaced | 1 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C097 | `prodbox test integration gateway-daemon` | `prodbox test run gateway-daemon` | Replaced | 6 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C098 | `prodbox test integration gateway-pods` | `prodbox test run gateway-pods` | Replaced | 9 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--record-profile`, `--config` | — |
| C099 | `prodbox test integration control-plane-counterexample` | `prodbox test run control-plane-counterexample` | Replaced | 3 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C100 | `prodbox test integration teardown-recovery` | `prodbox test run teardown-recovery` | Replaced | 3 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C101 | `prodbox test integration create-interrupted` | `prodbox test run create-interrupted` | Replaced | 5 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C102 | `prodbox test integration certificate-scope` | `prodbox test run certificate-scope` | Replaced | 7 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C103 | `prodbox test integration clean-room-handoff` | `prodbox test run clean-room-handoff` | Replaced | 10 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C104 | `prodbox test integration cascade-qualification` | `prodbox test run delete-qualification` | Replaced | 8 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C105 | `prodbox test integration cascade-qualification-receipt` | `prodbox test run delete-qualification-receipt` | Replaced | 8 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C106 | `prodbox test integration aws-lifecycle-receipt` | `prodbox test run aws-lifecycle-receipt` | Replaced | 5 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C107 | `prodbox test integration aws-lifecycle` | `prodbox test run aws-lifecycle` | Replaced | 8 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C108 | `prodbox test integration aws-lifecycle-canary` | `prodbox test run aws-lifecycle-canary` | Replaced | 5 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C109 | `prodbox test integration ha-rke2-aws` | `prodbox test run gateway-ha` | Replaced | 9 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C110 | `prodbox test integration lifecycle` | `prodbox test run lifecycle` | Replaced | 3 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C111 | `prodbox test integration pulumi` | `prodbox test run pulumi` | Replaced | 9 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C112 | `prodbox test integration eks-volume-rebind` | `prodbox test run eks-volume-rebind` | Replaced | 8 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C113 | `prodbox test integration charts-storage` | `prodbox test run charts-storage` | Replaced | 6 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C114 | `prodbox test integration charts-platform` | `prodbox test run charts-platform` | Replaced | 6 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C115 | `prodbox test integration resource-guardrails` | `prodbox test run resource-guardrails` | Replaced | 6 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C116 | `prodbox test integration daemon-bootstrap` | `prodbox test run daemon-bootstrap` | Replaced | 2 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C117 | `prodbox test integration pulsar-broker` | `prodbox test run pulsar-broker` | Replaced | 6 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C118 | `prodbox test integration charts-vscode` | `prodbox test run charts-vscode` | Replaced | 6 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C119 | `prodbox test integration charts-api` | `prodbox test run charts-api` | Replaced | 6 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C120 | `prodbox test integration charts-websocket` | `prodbox test run charts-websocket` | Replaced | 6 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C121 | `prodbox test integration admin-routes` | `prodbox test run admin-routes` | Replaced | 7 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C122 | `prodbox test integration public-dns` | `prodbox test run public-dns` | Replaced | 7 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C123 | `prodbox test integration keycloak-invite` | `prodbox test run keycloak-invite` | Replaced | 7 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C124 | `prodbox test integration sealed-vault` | `prodbox test run sealed-vault` | Replaced | 2 | Developer | `--verbose`, `--version`, `--coverage`, `--cov-fail-under`, `--substrate`, `--config` | — |
| C125 | `prodbox users invite` | `prodbox users invite` | Preserved | 7 | Operator | `--verbose`, `--version`, `--role`, `--dry-run`, `--plan-file`, `--config` | — |
| C126 | `prodbox users list` | `prodbox users list` | Preserved | 7 | Operator | `--verbose`, `--version`, `--status`, `--status-unverified`, `--config` | — |
| C127 | `prodbox users revoke` | `prodbox users revoke` | Preserved | 7 | Operator | `--verbose`, `--version`, `--delete`, `--dry-run`, `--plan-file`, `--config` | — |
| C128 | `prodbox vault status` | `prodbox admin vault status` | Replaced | 2 | Maintenance | `--verbose`, `--version`, `--config` | — |
| C129 | `prodbox vault init` | `prodbox admin vault init` | Replaced | 2 | Maintenance | `--verbose`, `--version`, `--config` | — |
| C130 | `prodbox vault reset-ambiguous-initialization` | `prodbox admin vault reset-ambiguous-initialization` | Replaced | 3 | Maintenance | `--verbose`, `--version`, `--yes`, `--config` | — |
| C131 | `prodbox vault unseal` | `prodbox admin vault unseal` | Replaced | 2 | Maintenance | `--verbose`, `--version`, `--config` | — |
| C132 | `prodbox vault seal` | `prodbox admin vault seal` | Replaced | 2 | Maintenance | `--verbose`, `--version`, `--config` | — |
| C133 | `prodbox vault reconcile` | `prodbox admin vault reconcile` | Replaced | 2 | Maintenance | `--verbose`, `--version`, `--config` | — |
| C134 | `prodbox vault rotate-unlock-bundle` | `prodbox admin vault rotate-unlock-bundle` | Replaced | 3 | Maintenance | `--verbose`, `--version`, `--config` | — |
| C135 | `prodbox vault rotate-transit-key` | `prodbox admin vault rotate-transit-key` | Replaced | 3 | Maintenance | `--verbose`, `--version`, `--config` | — |
| C136 | `prodbox vault pki status` | `prodbox admin vault pki status` | Replaced | 3 | Maintenance | `--verbose`, `--version`, `--config` | — |
| C137 | `prodbox vault pki issue-test-cert` | `prodbox admin vault pki issue-test-cert` | Replaced | 3 | Maintenance | `--verbose`, `--version`, `--config` | — |
| C138 | `prodbox workload start` | `prodbox internal workload start` | Internalized | 1 | Internal | `--verbose`, `--version`, `--config`, `--config` | — |
| C139 | `prodbox control status` | `prodbox control status` | Preserved | 1 | Operator | `--verbose`, `--version`, `--config` | — |
| C140 | `prodbox control plan` | `prodbox control plan` | Preserved | 1 | Operator | `--verbose`, `--version`, `--config` | — |
| C141 | `prodbox control import-artifact` | `prodbox control import-artifact` | Preserved | 1 | Operator | `--verbose`, `--version`, `--config` | — |
| C142 | `prodbox control discard-artifact-staging` | `prodbox control discard-artifact-staging` | Preserved | 1 | Operator | `--verbose`, `--version`, `--config` | — |
| C143 | `prodbox control inspect-node-archive` | `prodbox control inspect-node-archive` | Preserved | 1 | Operator | `--verbose`, `--version`, `--config` | — |
| C144 | `prodbox control inspect-image-attempt` | `prodbox control inspect-image-attempt` | Preserved | 1 | Operator | `--verbose`, `--version`, `--config` | — |
| C145 | `prodbox test list` | `prodbox test list` | Preserved | 1 | Developer | `--verbose`, `--version`, `--config` | — |
| C146 | `prodbox control reconcile` | `prodbox control reconcile` | Preserved | 1 | Operator | `--verbose`, `--version`, `--config` | — |
| C148 | `prodbox control delete` | `prodbox control delete` | Preserved | 1 | Operator | `--verbose`, `--version`, `--yes`, `--config` | — |
| C147 | `prodbox internal-kind-controller` | `prodbox internal kind-controller` | Internalized | 1 | Internal | `--verbose`, `--version`, `--config` | — |

## Option disposition

This list accounts for every distinct baseline long option; the leaf table records all 554 occurrences. Phase 0 tests names, requiredness, short aliases and parser scope against source. A shared spelling such as `--config`, `--target` or `--json` may have internal and public meanings; do not conflate their types. Positional and flag input validation remains fail-closed.

| Baseline option | Short alias | Target policy |
|---|---|---|
| `--action` | — | Internalize with authenticated worker/controller launch; preserve exact immutable binding and validation, never an ordinary operator permission shortcut. |
| `--allow-pulumi-residue` | — | Remove. Never revoke recovery credentials while unresolved resource obligations remain. |
| `--authority-endpoint` | — | Internalize with authenticated worker/controller launch; preserve exact immutable binding and validation, never an ordinary operator permission shortcut. |
| `--authority-scope` | — | Internalize with authenticated worker/controller launch; preserve exact immutable binding and validation, never an ordinary operator permission shortcut. |
| `--cascade` | — | Remove. Ordinary `delete` includes every owned AWS family; control removal is a separate explicit operation (Phase 3 new surface, Phase 8 ordinary legacy routes). |
| `--child-account-id` | — | Preserve explicit child account scope. |
| `--child-endpoint` | — | Preserve repeatable typed NAME=URL child inventory; validation before effects. |
| `--child-kubeconfig` | — | Preserve scoped child registration input; no copying unrelated admin kubeconfigs into workers. |
| `--child-kubeconfig-reference` | — | Preserve protected child kubeconfig reference; never plaintext config custody. |
| `--child-pulumi-stack` | — | Preserve repeatable exact child stack references in admitted scope. |
| `--child-vault-address` | — | Preserve validated explicit child Vault endpoint. |
| `--config` | — | Preserve internal mounted config; add explicit global public `--config PATH` selecting the validated deployment. Never select production via ambient context. |
| `--cov-fail-under` | — | Preserve optional test threshold; not phase closure by coverage percentage. |
| `--coverage` | — | Preserve as a test diagnostic, not real-effect proof. |
| `--deadline-micros` | — | Internalize with authenticated worker/controller launch; preserve exact immutable binding and validation, never an ordinary operator permission shortcut. |
| `--delete` | — | Preserve explicit full user removal versus disable under `users revoke`; unrelated to AWS deletion scope. |
| `--destroy-pulumi-residue` | — | Remove. Resource-before-credential cleanup is mandatory common-engine ordering. |
| `--dry-run` | — | Map public mutation preview to `plan` over the same request/planner. Internal bounded plan support may remain explicit; no hidden effects. |
| `--emit-readonly-script` | — | Preserve read-only provider diagnostics with their declared field; never emit a mutating fallback script. |
| `--finish-ns` | — | Internalize with authenticated worker/controller launch; preserve exact immutable binding and validation, never an ordinary operator permission shortcut. |
| `--force` | — | Preserve overwrite only for authored test-plan generation; never force infrastructure or retained-state reset. |
| `--hard-ns` | — | Internalize with authenticated worker/controller launch; preserve exact immutable binding and validation, never an ordinary operator permission shortcut. |
| `--image-digest` | — | Internalize with authenticated worker/controller launch; preserve exact immutable binding and validation, never an ordinary operator permission shortcut. |
| `--ingress-schema` | — | Internalize with authenticated worker/controller launch; preserve exact immutable binding and validation, never an ordinary operator permission shortcut. |
| `--input-fingerprint` | — | Internalize with authenticated worker/controller launch; preserve exact immutable binding and validation, never an ordinary operator permission shortcut. |
| `--json` | — | Preserve registry JSON and add global structured outcome output; same outcome semantics, no green report from missing observations. |
| `--lines` | `-n` | Preserve bounded control log selection. |
| `--local-data` | — | Remove from ordinary/cloud deletion; explicit operator-only `admin control purge-data` owns local destruction. |
| `--material-schema` | — | Internalize with authenticated worker/controller launch; preserve exact immutable binding and validation, never an ordinary operator permission shortcut. |
| `--mode` | — | Internalize with authenticated worker/controller launch; preserve exact immutable binding and validation, never an ordinary operator permission shortcut. |
| `--namespace` | `-n` | Preserve exact selected-cluster namespace diagnostics; no ambient kubeconfig. |
| `--node-id` | — | Preserve gateway config-generation identity; match selected context. |
| `--operation` | — | Internalize with authenticated worker/controller launch; preserve exact immutable binding and validation, never an ordinary operator permission shortcut. |
| `--operation-id` | — | Internalize with authenticated worker/controller launch; preserve exact immutable binding and validation, never an ordinary operator permission shortcut. |
| `--operation-key` | — | Internalize with authenticated worker/controller launch; preserve exact immutable binding and validation, never an ordinary operator permission shortcut. |
| `--outer-ns` | — | Internalize with authenticated worker/controller launch; preserve exact immutable binding and validation, never an ordinary operator permission shortcut. |
| `--permit-id` | — | Internalize with authenticated worker/controller launch; preserve exact immutable binding and validation, never an ordinary operator permission shortcut. |
| `--plan-digest` | — | Preserve for exceptional scoped recovery/adoption; reobserve exact targets and refuse stale digests. |
| `--plan-file` | — | Preserve plan export as `plan --output PATH`; normal execution reobserves conditions and does not require a plan-file ceremony. |
| `--pod-name-file` | — | Internalize with authenticated worker/controller launch; preserve exact immutable binding and validation, never an ordinary operator permission shortcut. |
| `--pod-uid-file` | — | Internalize with authenticated worker/controller launch; preserve exact immutable binding and validation, never an ordinary operator permission shortcut. |
| `--port` | — | Preserve explicit maintenance port selection validated against the kind publication plan. |
| `--receipt` | — | Replace monolithic nuke export with local terminal operation evidence; migration may retain exact old receipt inputs until Phase 10. |
| `--record-profile` | — | Preserve explicit measured-profile evidence; measurements do not silently certify arbitrary budgets. |
| `--request` | — | Internalize with authenticated worker/controller launch; preserve exact immutable binding and validation, never an ordinary operator permission shortcut. |
| `--request-digest` | — | Internalize with authenticated worker/controller launch; preserve exact immutable binding and validation, never an ordinary operator permission shortcut. |
| `--role` | — | Preserve typed invitation role assignment. |
| `--service-account-token-file` | — | Internalize with authenticated worker/controller launch; preserve exact immutable binding and validation, never an ordinary operator permission shortcut. |
| `--stack` | — | Preserve exact stack/family audit selection; no identity inferred from checkpoint presence. |
| `--status` | `-s` | Preserve user listing/status filter; an unobserved status is reported honestly. |
| `--status-unverified` | — | Preserve unverified-email filtering; it cannot manufacture verified state. |
| `--stop-ns` | — | Internalize with authenticated worker/controller launch; preserve exact immutable binding and validation, never an ordinary operator permission shortcut. |
| `--substrate` | — | Replace with explicit `--target local\|aws` for applicable service/application actions or the test plan variant. Local control is always kind. |
| `--tail` | — | Preserve bounded per-container logs on the selected target. |
| `--target` | — | Internal worker target remains exact signed identity; public target selection uses explicit local/aws context and does not accept a worker permit. |
| `--target-agent-identity` | — | Internalize with authenticated worker/controller launch; preserve exact immutable binding and validation, never an ordinary operator permission shortcut. |
| `--tier` | — | Preserve read-only policy description/selection; runtime mutation permission is derived from registered intent, not an operator-selected broad tier. |
| `--timeout` | `-t` | Preserve bounded diagnostics; cumulative operation deadline remains authoritative. |
| `--tree` | — | Preserve command-tree introspection; internal entries require explicit inclusion. |
| `--verbose` | `-v` | Preserve diagnostics with redaction; ordinary output remains operator vocabulary. |
| `--version` | — | Preserve deterministic binary/toolchain identification. |
| `--with-edge` | — | Replace with explicit edge selection in the deployment specification; main reconcile plans its capability closure. |
| `--work-ns` | — | Internalize with authenticated worker/controller launch; preserve exact immutable binding and validation, never an ordinary operator permission shortcut. |
| `--write` | — | Preserve explicit dev formatting/generation mode. Docs-only user requests cannot trigger code/config regeneration. |
| `--yes` | —, `-y` where supported | Preserve exact-scope destructive confirmation. It neither supplies secrets nor bypasses ownership/evidence checks. |

## Parser and helper inventory outside captured JSON

The current `config generate` parser accepts `--portable`, and optparse supplies
`--help` / `-h`; neither appears in the captured registry option inventory. The
exported `outputOptionsParser` defines `--format`, `--color`, and `--no-color`,
but has no current caller: the built binary rejects those options. Its rows
record Phase 1 target work, not current accepted arguments. Phase 0 reconciles
the current parser and helper inventory; Phase 1 delivers the common typed
command model and tests the supported output options.

| Parser option | Observed source | Target disposition | Owner |
|---|---|---|---:|
| `--portable` | `CLI.Spec` config-generation parser | Preserve explicit portable template generation without claiming live host fit; default generation observes host | 1 |
| `--format plain/table/json` | `CLI.Spec.outputOptionsParser` | Preserve explicit formatting where routed; normalize with common structured JSON option and test conflicting selections | 1 |
| `--color auto/always/never` | `CLI.Spec.outputOptionsParser` | Preserve terminal rendering policy, never affect machine outcome/evidence | 1 |
| `--no-color` | `CLI.Spec.outputOptionsParser` | Preserve alias for disabled color; no hidden behavior branch | 1 |
| `--help` / `-h` | optparse helper in `CLI.Parser` | Preserve generated help at every level; internal visibility remains explicit | 1 |

## Positional operands and added target capabilities

The captured registry JSON does not serialize positional operand metadata. `CLI.Spec` already has typed `ArgumentSpec` metadata, while the current parser keeps separate positional bindings. The additional parser cases below remain mandatory coverage, not optional undocumented flags. Phase 0 inspects `CLI.Spec`/parser and installed help examples to reconcile this inventory; Phase 1 unifies the command model and parser behavior.

| Current operand family | Target policy | Phase |
|---|---|---:|
| Chart/root-service name | Validated service catalog key for status/logs and desired-state component reconcile/delete | 6 |
| User email/identity and revoke target | Validated Keycloak user/email identity; maintain invite/list/revoke semantics | 7 |
| Gateway config OUTPUT_PATH | Preserve explicit non-secret output destination in dev config generation; no implicit overwrite of operational config | 6 |
| Transit key name | Closed allowed maintenance key, no arbitrary root/session fallback | 3 |
| Federation CHILD | Explicit cluster identity and trust/custody admission | 9 |
| Test run SUITE | Named scenario in the shared registry, never arbitrary source-file selection | 1 |
| Control image-attempt OPERATION | Exact retained operation identifier for a read-only diagnostic; never permission to retry | 1 |
| Help command path | Registry-derived path with explicit visibility | 1 |
| Stack/repair family operands | Declared family plus exact recorded scope, never arbitrary AWS identifiers granting ownership | 5–8 |

New paths with no baseline leaf are explicitly owned: `plan reconcile/delete`, `operations list/show/resume/cancel`, `control delete` and aggregate `status` in Phase 3; initial `control reconcile/status` in Phase 1 then management services in Phase 2; `test list/status/cleanup` and bounded mutation execution in Phase 1 (cloud cleanup extends with introduced families); `services logs` in Phase 6; credential status in Phase 4; federation status in Phase 9. Real cloud/application reconcile becomes available only in its owning phase.

Target `reconcile --target aws` means the EKS application projection and closes in Phase 8; the cheap Phase 5 S3 resource uses the separately named `admin aws stack storage-canary` / test family without pretending EKS exists. The ordinary root `delete` handles all families admitted so far, starting with credential-family resources in Phase 4.

## Pulumi and legacy compute assertion split

The old `test integration pulumi` is a live inventory assembly over `aws-test` (three EC2/RKE2 machines), not the cheap S3 canary. Its final named `test run pulumi` aggregation is owned by Phase 9: retain encrypted-backend/checkpoint/provider laws as Phase 5 cases, rebind HA assertions to supported kind/EKS in Phase 9, and retain only exact original-stack cleanup/import checks in Phase 10. Phase 5 does not run that old assembly against nonexistent EC2 and call it preserved. No new S3 deployment reuses the old compute identity.

`aws policy`'s final public maintenance command/registry acceptance is owned by Phase 5. Phase 4 separately proves the actual generated credential's least-privilege policy and denied actions; that proof does not depend on the later human policy-rendering/quota command.

## Closure

Phase 0 migrates the code-side registry/checkers to read this Markdown contract and tests exact baseline coverage; current code has not been changed by documentation adoption. Each owning phase updates command availability, parser/help/manpages/completions/fixture goldens and removes the obsolete ordinary leaf after real acceptance. Migration-only original-install cleanup is fenced and removed in Phase 10. A new session starts at [Resume Here](README.md#resume-here).
