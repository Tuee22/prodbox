# Critical Source Mutation Cases

**Status**: Authoritative source
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Target validation contract; no mutation result is claimed by writing this catalog.

> **Purpose**: Define the bounded source faults and intended assertion failures required to validate critical lifecycle tests in numerical phase order.

[Acceptance cases](acceptance_cases.md) define real unmodified workflows. This catalog defines deliberate implementation faults used to determine whether unchanged tests detect violations of those same invariants. A source mutation is distinct from changing a test input, injecting infrastructure failure, or changing an AWS resource. Each owning phase must establish its required result before it closes; phase state lives only in [README.md](README.md#resume-here).

## Required catalog

Each family below expands into named variant records in the owning implementation. Every variant records exact patch-site preconditions, baseline source/build/toolchain identity, patch digest, selected unchanged tests, expected assertion/test ID, execution budget, observed result and outer cleanup. A missing/changed patch site is not a silent skip. The first owning phase cannot require a later adapter; later phases extend the relevant family to the real adapters they add.

| Mutation | First owner | Required semantic variants | Intended unchanged assertion | Acceptance binding |
|---|---:|---|---|---|
| M00 | 0 | Disable future-phase dependency rejection; disable removal-owner validity; accept missing/foreign evidence references; admit a known missing current source | `plan.rejects_future_dependency`, `plan.requires_valid_remover`, `plan.requires_bound_evidence` and `plan.rejects_missing_source` each fail for its own malformed-plan fixture | A00-02, A00-04 |
| M01 | 1 | Remove environment/root/context or Docker effect ownership checks; admit a cross-root alias, foreign context, foreign network, namespace or control-container removal, namespace replacement, wrong controller node, or unowned pull; accept changed or truncated node-artifact bytes; treat an unconfirmed create attempt as never started, an unknown recreation intent as absent, a failed removal as successful, or an unbound controller/removal receipt as valid | The corresponding unchanged `context.rejects_foreign_scope`, `context.rejects_root_alias`, `context.rejects_foreign_network`, `context.rejects_unowned_pull`, `artifact.rejects_changed_bytes`, `delete.rejects_unconfirmed_node`, `recreate.rejects_unknown_intent`, `delete.rejects_failed_removal`, `delete.rejects_foreign_control`, `delete.rejects_unbound_receipt`, `controller.rejects_foreign_receipt`, `controller.rejects_wrong_node`, `controller.rejects_external_family`, `network.rejects_foreign_namespace_cleanup` or `network.rejects_replaced_namespace` assertion fails without touching real production | A01-03, A01-07, A01-08 |
| M02 | 1 | Evidence validator accepts absent, fabricated, stale or wrong-scope results | `evidence.rejects_unbound_result` fails on the corresponding adversarial report; observer meta-test stays unmodified | A01-06, A01-07 |
| M03 | 2 | Permit test MinIO self-unseal in production policy; call init over a recorded storage-generation mismatch; omit backup file contents from its integrity commitment | `bootstrap.production_rejects_test_unlock` / `bootstrap.preserves_vault_incarnation` / `backup.rejects_same_size_corruption` fail | A02-03, A02-04, A02-05, A02-06 |
| M04 | 3 | Recode an unobservable resource/journal or missing existing history as absence / NeverAdmitted | `lifecycle.unknown_requires_recovery` / `lifecycle.missing_history_is_not_fresh` fail | A03-02, A03-03, A03-04 |
| M05 | 3 | Return `NoChange` while a durable admitted operation remains unresolved | `lifecycle.pending_intent_blocks_noop` fails | A03-01, A03-04 |
| M06 | 4 | Omit IAM intent registration before the first possible create; revoke an operational credential before its resource dependants are terminal | `credentials.intent_precedes_effect` / `credentials.dependants_precede_retirement` fail | A04-01, A04-02, A04-03 |
| M07 | 5 | Skip a required provider delete, skip its independent read-back, or retire checkpoint/recovery custody before absence | `delete.requires_resource_absence` / `delete.requires_readback` / `delete.preserves_recovery_custody` fail | A05-01, A05-02, A05-03, A05-04 |
| M08 | 5 | Make an independent observer return `Clean` despite retained residue, denied inventory or unanswered query | `observer.rejects_residue` / `observer.unanswered_is_unobservable` fail under independent unmodified meta-tests | A05-03, A05-04 |
| M09 | 6 | Bypass application persistence, desired-selection or dependency checks | `services.preserves_data_binding` / `services.deleted_selection_stays_absent` / `services.requires_dependencies` fail | A06-03, A06-04 |
| M10 | 7 | Omit an owned DNS/SES/S3/IAM family; retain the former SES exemption; mutate another environment's receipt rules or replace/deactivate its active regional rule set | `delete.covers_owned_families` / `email.retains_foreign_receipt_rules` / `email.test_cannot_switch_production_receiving` fail | A07-02, A07-04, A07-05 |
| M11 | 8 | Omit an EKS controller-dependent family; select a drain target from another stack/checkpoint | `eks.covers_controller_dependants` / `eks.drain_requires_exact_cluster` fail | A08-03, A08-04 |
| M12 | 9 | Admit a successor before actual predecessor settlement; accept stale worker or federation identity | `recovery.settlement_precedes_successor` / `federation.rejects_stale_identity` fail | A09-02, A09-03 |
| M13 | 10 | Permit old/new competing writers during import; replace the original deployment identity with a new one to escape unresolved history | `migration.exclusive_writer` / `migration.preserves_original_identity` fail | A10-01, A10-02 |

The assertion identifiers name required behavioral checks to implement; they are not claims that tests with those names already exist. A phase binds them to actual test/source identifiers before running its catalog. Pure fixtures and recorded provider contracts can isolate faults, but tests execute the actual mutated implementation rather than a hand-written description of its expected behavior.

### Phase 1 preliminary assertion binding

The owner-first M01 variant ignores the owner-family protocol decision at
the entry to `reconcileFamilyPrerequisites`. The unchanged
`distinguishes owner-first family intent from externally prepared history`
test marks the required assertion as `controller.rejects_external_family`.
The reviewed patch is registered. Isolated execution remains pending.

A01-01 also requires an authority-observation bypass variant, an
Authority-deployment fence bypass variant and a receipt-only removal variant.
Their marked assertions refuse unavailable early admission, deployment after
a committed teardown checkpoint and a successful removal receipt when the
exact node remains visible. Source bindings are recorded below. Compiled
isolated results remain open.

`delete.rejects_unconfirmed_node` is bound to the unchanged node disposition
assertion in `test/unit/NodeRegistryPreparationTests.hs`. The reviewed patch is
registered; isolated execution remains pending and is not a mutation kill.
The same test suite binds `recreate.rejects_unknown_intent` and
`delete.rejects_failed_removal`, with reviewed patches registered and isolated
execution pending.
The reviewed patches for `delete.rejects_foreign_control`,
`delete.rejects_unbound_receipt`, `controller.rejects_foreign_receipt`,
`controller.rejects_wrong_node`, `network.rejects_foreign_namespace_cleanup`
and `network.rejects_replaced_namespace` are registered below. Each selects
its existing behavioral test in `test/unit/NodeRegistryPreparationTests.hs`.
Isolated execution remains pending.

The missing-report variant of `evidence.rejects_unbound_result` is bound to
`scenario evidence comparison.rejects an unbound report for the mutation catalog`
in `test/unit/ScenarioEvidenceTests.hs`. Its marked assertion exercises
`compareScenarioEvidence` in `src/Prodbox/Test/ScenarioEvidence.hs`. This binds
one adverse case only. `Prodbox.Test.ReviewedMutation` defines the first
source-bound candidate: for source SHA-256
`e838f617e90537a56bc7ee9af2e113bb9a5bc939dfe95c4c663dece5645b22f1`, it
replaces the single adjacent report/observer lookup with a lookup that
constructs a report from the supplied observer when the report is absent. The
candidate must match that exact preimage and one site; a changed source needs a
new review. Its domain-separated implementation-binding digest is
`6a953a78bf1ac83ffa3878581d4f65005adc43281a3a371e417ed4cb7ba9d944`;
the resulting source bytes hash to
`121bd7e3312b33fab6f8177b356643d9c45b6eadfcb973fc26d20438d0da37e4`.
These are not unified-diff hashes. Preparing candidate bytes is not a mutation execution. The
isolated execution and observer meta-test still need evidence.

Three additional M02 variants keep the selected observer inputs unchanged.
They discard the report's stale source or foreign scope, or substitute the
report's primary outcome for the independent observation. The marked tests
require separate rejections. Compiled isolated results remain open.

| Variant | Source SHA-256 | Binding SHA-256 | Candidate SHA-256 |
|---|---|---|---|
| `M02-stale-source` | `e838f617e90537a56bc7ee9af2e113bb9a5bc939dfe95c4c663dece5645b22f1` | `41ac59c41f7599df28e827b6dd0ad2a6abd80a83f2a957fbc957af987b795920` | `ae47c8c5510e8294cb3a8c18ce42449ecbcf859c2baab111c6e04d1ebf2d2097` |
| `M02-wrong-scope` | `e838f617e90537a56bc7ee9af2e113bb9a5bc939dfe95c4c663dece5645b22f1` | `121f29556d929dfd15c3896e763542684024829f383c103df9582d243d4aa5d0` | `fc771e98b88c2f422e6c87ade82b843c64cb5ae0cb0e52edc778c366c304fb5d` |
| `M02-fabricated-success` | `e838f617e90537a56bc7ee9af2e113bb9a5bc939dfe95c4c663dece5645b22f1` | `48a179134bda867a06dbe1e78a9279f0a26926b57509b80f8968aaf5a8e976d4` | `772377b1a8105bde074e7622228c901d40c4b3e4de36a702c4b9cf3688e8ff44` |

The reviewed M01 overlapping-root variant is bound to
`deployment scope coordinates.rejects overlapping roots for the mutation catalog`
and `context.rejects_root_alias`. It changes the root-overlap check in
`src/Prodbox/Config/DeploymentScope.hs` so it cannot reject valid API ports.
The required source SHA-256 is
`5c03d6f72122af8438cf609c5a51d144774c67bb9fe6cbc79240b66fa3591e12`;
the domain-separated binding digest is
`7f4768eb52164aace4c7d2362e90da868a3c72d159e64832eaa9c65de88aca6c`
and the candidate source SHA-256 is
`84107b0f446d7cbbf816ddb4cf809b613fa95c7eecc1d3605aab5630e2c9bc33`.
The baseline assertion and preparation passed; isolated compilation, actual
assertion failure, cleanup and M01 acceptance remain open.

The reviewed M01 artifact-byte variant targets
`src/Prodbox/Control/NodeRegistryArchive.hs` and the assertion
`artifact.rejects_changed_bytes` in the digest-bound archive test. It removes
the digest condition while preserving the length condition. The source SHA-256
is `7284e324f79d558274f7afb567f9f2443920371cc9156128d689bf93de74f4e2`,
the binding digest is `a40fceb185c28948aa9b5c2abca29cf3df5d9e067a79f0ac4147a4e948e5e3e5`,
and the candidate SHA-256 is `a7c12da0afa0b1f5777abfb9575e32657ad6adcafd1544f66e5c2f1ff16f998a`.
Its isolated execution and designated-assertion kill remain open.

Four additional reviewed M01 variants select their designated assertions in
the bounded executor. Isolated results are pending.

| Variant | Source SHA-256 | Binding SHA-256 | Candidate SHA-256 |
|---|---|---|---|
| `M01-unconfirmed-node` | `7036faac60c71259193bb46ab0bda1f7752bb854d81dff5c7de21864ebd292d0` | `8101661dbf2a63df3fff20c67b2c2283aaf7c21c998fbd01595e8ae6dd5f155a` | `715216f89871cdf93b289ec90c9ba92b61f55160d6ffca0d2cbcbda2a5409b1c` |
| `M01-unknown-recreate` | `5198083b3503309deb0014aa746718c1731a599014029a1ff20af8d75710f369` | `1f28e4bfb71aa8c087c01dc815116ad3b5567a1b3d49b15cac948dfc9f428dc4` | `eb8ced93fd010effdd458074383926fe1358fae0510da576d24944b22e01cbfa` |
| `M01-external-family` | `ece7a31811fc8ab93eaddb6ca044bd9f672954878a13415931c3ed1511637461` | `f97d1338d2d889face8986c14eb4c0f222ab4df0794fe33f0c6c5b3362afb364` | `8bc253d48513fb19773cc643dcdc8821e41384fa48e6347711f2a0e53b4d545e` |
| `M01-failed-removal` | `bc0b010a6ab203cf5d7bf4e74316f3583a2807acb42c512469f2cd9becc76381` | `95393fb7afbde8d8344f9f4dccd0aabf86922c8a5ec998222d6d7f8caf9dd37a` | `8fc21b1842a23d4db0269a6735cfb7680729d0069203353a52defa6211d97113` |

Six reviewed M01 ownership checks now select exact marked baseline assertions.
Each replacement changes one source condition within the named guard. The
selected tests use synthetic provider observations. Isolated execution is
required for the intended-assertion result.

| Variant | Source SHA-256 | Binding SHA-256 | Candidate SHA-256 |
|---|---|---|---|
| `M01-foreign-control` | `7036faac60c71259193bb46ab0bda1f7752bb854d81dff5c7de21864ebd292d0` | `0e00c87ea01501d1270796bf5ed521565917b596e5c5f595b054e140238124d9` | `91edd0e6be9e1512621755f5b589613d35ba051266929418c688aea15b74aa09` |
| `M01-unbound-receipt` | `2a7e891c2464c374f4ab15c8b212da8c802063eed09ab797e02485217146f1cf` | `492e78c94c2cf7b03a856aecda66146a3fef7464313503615c881037f8fe3876` | `71ddc9e824774ed18b305db29867fdedb520cddb3b9e432c6ff4f6e846d31c7c` |
| `M01-foreign-controller-receipt` | `b8d0a9703e50e4a6289279b760845d148295533fa261187c8eadab4d8f1126ee` | `be5715655d8182441b38ec3101d886ee59b16c63a192516a78417cc85a7d7b57` | `4f8b899a282402b0e5a901f6619255ec1a07a793c755910e8e88d7b646ff2809` |
| `M01-wrong-controller-node` | `581ccbbd117ec9ebed9aac3b00df662ada24523673845521b25744794875dc5a` | `c8ebd63c55b0fab7d9e7a0a21c007c1b39451c95f144e34f0e5bab225b0a8de5` | `6fb395e9240ad2e6e17c8bac9a0973af7b180c7599aa812e9f4110015248c452` |
| `M01-foreign-namespace-cleanup` | `7c7dc233a4f597258868548e2ca7b489d7bf8b72b949e216447b9b0985409539` | `223dedf27607c3478b9588d233a3da5159ec08f893aabb41c5a097344e66c57f` | `98bb56d5fd81363de02342f01b9332d1b1c47e31f5d3adebc29e332a7c5731d2` |
| `M01-replaced-namespace` | `7c7dc233a4f597258868548e2ca7b489d7bf8b72b949e216447b9b0985409539` | `847d4f22aba4bf3fea22d45ec3c0e6ac7da19217b1bd3ce3b3f4a08e031830e8` | `bf8d157466f7a3f1fb677736e7f2b7f18350cef35c4d6c943842b5fb0e0b81fd` |

The remaining scope and admission bindings exercise foreign Docker identity,
unauthorized command admission, the early teardown fence and the requirement
for independent read-back after successful node removal.
The pull case admits the forbidden CLI request as a read operation in the
mutated gate. Its unchanged controlled observer requires refusal before
any callback. Compiled isolated results remain open.

| Variant | Source SHA-256 | Binding SHA-256 | Candidate SHA-256 |
|---|---|---|---|
| `M01-foreign-scope` | `e36f928e3370ecad2433dc753d2f53ae1c8af85cc214db1842b9dcdc8f304d20` | `936f20080df3e8b398a9858514c13af4f85108d40c38db649a6c7d7d99369bce` | `bb87087f7aad1f777f630b28a73df0610dc89abc899b78c4d5994b8bd76563b2` |
| `M01-foreign-network` | `e36f928e3370ecad2433dc753d2f53ae1c8af85cc214db1842b9dcdc8f304d20` | `7d7ed4b0105a003e5fcf045476481cfde6dcab91a86444f45f0257550119c327` | `a92de2d3289a69bf99164f7bb0343e2309a016ce0251096c4cd33d4091c3dacd` |
| `M01-unowned-pull` | `e6d5e8de5018e6682c007baa317d030dfa12b2736ee93a0d4245f46a495054d3` | `c2a0fc8874fbba78a37ef6c844fdc0941361b0d4f30f7a9f7ced83fd5bd1e67d` | `a9501114ff2e629318ab75466d77f52fcd20dfe387e2dddbda687d7f32668442` |
| `M01-authority-unobservable` | `9e2f68318192293a74189bc8de465a7d97df1e80bd30445b3c54657429b7c2c2` | `0b0fb96e0bbb9d4d985fd4aced44ce9a74bfcaa551097972583c4cee187f1bcc` | `4588f172f95a26da54b3d137df8c108da85403a974c579fd6adcd70132f8fb01` |
| `M01-authority-fence` | `dc9db941adcb13581209d04773c281d4a1764eab3872465a80a1aee838eb9d67` | `825d2d635bd2ca7ded99deaaeb93663619fa8b19374cfa9f89fdce69ed0ccbb0` | `eb1c75551a5df9af8ba8a73765c1cc8d20c4bf695bc6c3c4b0fe768add2ba765` |
| `M01-receipt-only-removal` | `bc0b010a6ab203cf5d7bf4e74316f3583a2807acb42c512469f2cd9becc76381` | `bf867be7e1e25664db38ce949183ff2e0e2e4aeead6ebaaf1d8a21738fbeb71d` | `5648c4f2f2aa1cea82f097b72800595531710876a1082f14f7adc3f658879160` |

### Phase 3 assertion bindings

The reviewed M04 and M05 variants are three source-bound candidates in
`src/Prodbox/Lifecycle/AdmissionHistory.hs`; all require source SHA-256
`03844695f0097ed3338ca2a28f99ef9a3b5dde528d1f0b1a1325e0cc12f202da`.

M04a is bound to `prodbox-unit.admission history.never recodes an unobservable journal as never admitted for the mutation catalog` and `lifecycle.unknown_requires_recovery`. Its
domain-separated binding digest is `5708c5477913f657a8f5077021e9a676c2b392559e74b01341fffb292e927c18` and the candidate source
SHA-256 is `fab80904d0ef111244fdc4455cf472025c7245858ef8cfc77760e5f7197f0360`.
Campaign `1870490296166714` killed this candidate on its intended
assertion. [Phase 3 evidence](phase_03_authority_and_local_lifecycle.md)

M04b is bound to `prodbox-unit.admission history.never relabels missing existing history as never admitted for the mutation catalog` and `lifecycle.missing_history_is_not_fresh`. Its
domain-separated binding digest is `76183f982bf9ec7e5fe7f9d968be73784815e719c1ec77d4c2b816706c18f5ea` and the candidate source
SHA-256 is `7f3fa1d0c2dfe552abc4f9d6ad349daa20b744f4cd88dfb61fb588055a000db7`.
Campaign `1871271215949209` killed this candidate on its intended
assertion. [Phase 3 evidence](phase_03_authority_and_local_lifecycle.md)

M05 is bound to `prodbox-unit.admission history.blocks a no-change answer while an intent is unresolved for the mutation catalog` and `lifecycle.pending_intent_blocks_noop`. Its
domain-separated binding digest is `1317a84b87b354520515cb814a370b8766926673f1e0893587f717fd70039ed0` and the candidate source
SHA-256 is `b93fa4e240eb4a0dfd4ca1e4e0f2c14a13fff72a72bcefb15d2357c6f32eac84`.
Campaign `1872502208857401` killed this candidate on its intended
assertion. [Phase 3 evidence](phase_03_authority_and_local_lifecycle.md)

The M04c variant is bound to `prodbox-unit.admission history.never reads a journal mirror without its genesis record as never admitted for the mutation catalog`
and `lifecycle.uninitialized_mirror_is_not_fresh` in `src/Prodbox/ControlPlane/AdmissionJournalMirror.hs` (source SHA-256 `23e4f7fcd35ef5007aff170f780d28bde976688be3542695665c9097f1578807`): it makes a
journal mirror with no genesis record read as an empty, successfully read journal,
that is as never admitted. The historical binding digest
`b47816515089cc9bfa61cb0ee36f522fbe7c14b99aed274b191b1c9b6798f861` and
candidate source SHA-256 `88e548df6f6953a733bed25a54e7b21843d7a1c3194ea8dd8f3db3563d55087e`
belong to an earlier mirror source. The later campaign binding
digest was `e52d8412b652d8c291724d8cae31eeb9eaeccbf90abea219514af4d099bf20d6`
and its candidate source SHA-256 was
`6ecbbe4402fd02e2af9c1539407fe878adc1cb114d4ca16ecc858ee88acecd54`.
Campaign `1869360179899150` killed this source-bound candidate on the
intended assertion. [Phase 3 evidence](phase_03_authority_and_local_lifecycle.md)

The prior M04d campaign used the same mounted-journal source SHA-256 `23e4f7fcd35ef5007aff170f780d28bde976688be3542695665c9097f1578807`.
It accepts a successful bounded read of a same-size substitute despite the retained
commitment. The unchanged test `prodbox-unit.admission history.requires recovery when the journal disappears after its genesis reservation was used`
requires `lifecycle.modified_mirror_requires_recovery`. The binding SHA-256 is
`d7021a844ea7e9d0671cefff308a25a06ec105cf8675249916b8649995b7b328` and the candidate SHA-256 is
`20d5b49cc4b41be5e7286ddfaadcc651472b57806a4d3a34c3dee47764faa1dc`. Campaign
`1867284175735692` killed this candidate on its intended assertion. The
independent cleanup and exact source binding are recorded in [Phase 3](phase_03_authority_and_local_lifecycle.md).

M04c current binding uses source SHA-256 `e0029b4e3483c56b049b8ce3093372fbff0befc0ad775d7cdc00200982a3b3bd`, patch SHA-256 `986ba0eec85db181b7c419b56d1f36d4e41fa94dad534f1bebbe095fdc353fcb`, and candidate SHA-256 `f1566f78dabca3bda3a461f245867a62a0c73093c93c5fa73378b0b83bf5629e`.

M04d current binding uses source SHA-256 `e0029b4e3483c56b049b8ce3093372fbff0befc0ad775d7cdc00200982a3b3bd`, patch SHA-256 `a3642d88c592dd2081a48a7e23683043074ce8b71b518f14018a3e8652481ff7`, and candidate SHA-256 `a20060233e7c18d4c359b8a12bfef5bf9f4036f03d37db62c5f568107573f7cf`.

### Phase 2 assertion bindings

The A02-06 backup-content variant M03c is bound to
`prodbox-unit.backup content integrity.detects a same-size content change for the mutation catalog`
and `backup.rejects_same_size_corruption`. It omits file bytes from the keyed
commitment while preserving paths and sizes. The current source SHA-256 is
`c04744eb50e05203f065b9b7a075573ea77bfc77aa38b652fbecdae60aa9ffac`, its
binding digest is `5aa1df6dc2f6e71b86d5bd23aa5458722280d82b14f58485ad5679b0dfbad5b7`,
and the candidate source SHA-256 is
`1e2c51d66d8ae3602a544258e12589ff6efda16d667030d9c26475b6dc3f2437`.
Phase 3 campaign `1874476381296207` killed the pre-format source
`7aca5ecab9ef52645619545082a003149a03f6e0db687cdacc082b390478c7f4`
on the same assertion, with independent cleanup. The current source
and candidate have identical formatter-normalized forms.
[Phase 3 evidence](phase_03_authority_and_local_lifecycle.md)
Historical campaign `1850537365253977` killed the Phase 2 source
`ea7a7eba1baad1eac748deb9d56cd1517bdafd0026c8f2226b7730d0cc02fa2d` on the same assertion.
The historical receipt and exact cleanup are recorded in
[Phase 2](phase_02_vault_minio_and_bootstrap.md).

The reviewed M03 variants are two source-bound candidates in
`src/Prodbox/Control/Unlock.hs`, one per assertion of the catalog row. Both
require source SHA-256 `ca2b33da348d85b5ecd16dd66ff01a6729453b2d7bfe4e4cd3c9ce4f20d4ce09`.
The M03a variant (production policy) is bound to
`bootstrap unlock policy.never selects the test self-unseal policy for production for the mutation catalog`
and `bootstrap.production_rejects_test_unlock`: it makes `unlockPolicyFor`
select the test self-unseal policy for every environment. Its domain-separated
binding digest is
`fbd0ccc75bf249dbbe4379555a6c95726ff1f45a60b3329ccae7db8ed55f9102` and the
candidate source SHA-256 is
`52520d8d04326ccde9ddc120d235b5f90c0b9100baa499e4ff1f207612abd72e`.
The M03b variant (Vault incarnation) is bound to
`bootstrap unlock policy.initializes only an uninitialized Vault with no unlock object or pending record for the mutation catalog`
and `bootstrap.preserves_vault_incarnation`: it makes `initialisationAllowed`
ignore a recorded unlock object, so an initialization over a storage-identity
disagreement is permitted. Its binding digest is
`21b28e5ab6d01a75283fe9b15828c6e561115340f4f3c9ef87bab3d1f6053e4d` and the
candidate source SHA-256 is
`37dc65b9a1386118736e98827f8b88b67638a0f4dc95350dddf37f9046fb4b5f`.

### Phase 0 assertion bindings

These bindings identify unchanged assertions in `test/unit/Main.hs`; they are
not mutation results. The first three are in `numerical phase plan contracts`,
and the final assertion is in `Sprint 0.21 citedSourcePathsInDoc`. Both groups
exercise `src/Prodbox/CheckCode.hs`.

| Assertion ID | Selected test | Required failure |
|---|---|---|
| `plan.rejects_future_dependency` | `rejects future numerical phase dependencies including range endpoints` | The unchanged future-phase assertion fails when dependency direction rejection is removed. |
| `plan.requires_valid_remover` | `checks canonical removal row owners and duplicate identities` | The unchanged invalid-owner assertion fails when owner validation is removed. |
| `plan.requires_bound_evidence` | `requires available scoped evidence and removed owned rows before closure` | Separate missing-record and foreign-phase mutations fail their corresponding unchanged assertions. |
| `plan.rejects_missing_source` | `refuses missing or escaping source paths` | The unchanged missing-source assertion fails when a known absent current path is admitted. |

The initial M00 source variants are one change each in `CheckCode.hs`: make the
`dependency >= owner` guard false; make the removal-row owner-validity disjunct
false; make the missing-evidence guard false; make the foreign-phase guard
false; or add an early success for the deliberately absent Host/Tool fixture
path in `currentSourceObjectExists`. The last patch uses this exact guard:

```haskell
| path == "src/Prodbox/Host/Tool.hs" = pure True
```

Each patch must match its exact reviewed site
once. The unchanged test selection is the corresponding group above, and a kill requires the designated
assertion's failure, not merely a nonzero exit. The five variants were compiled
and each failed its intended unchanged assertion; baseline, identities, budgets,
and cleanup observations are recorded in the [Phase 0 evidence](evidence/phase_00_validation.md).

At checker source SHA-256
`2eef04e221c26d84c8794c4cf986c8b3c06b59d6d6981c357d8275c39b8d6464`,
the five proposed one-site patches were generated in memory as Python
`difflib.unified_diff` over the complete source with `a/` and `b/` path labels.
Their SHA-256 values are listed below to identify the candidates; regenerate and
re-review them if the source, patch generation or assertions change.

| Variant | Proposed patch SHA-256 |
|---|---|
| Future dependency | `6b8b4b8b01b3c240db252e1203eb3c7a7052b810dbd96350962ae551746e8a40` |
| Invalid remover | `ca951983a39edd484e4b520566f257a851278f8fdae3f9edfd500182c4089abe` |
| Missing evidence | `7e0f9923877daf9af1ab68b987852dd5ff54fd00c29dc3a418f14327b2f84d42` |
| Foreign evidence | `9e792e8e979f4f8851fc49411a40df57a9777585545ff2bab86e162f8ef13abf` |
| Missing current source | `aeba094c1f58ba0e97fbc97a714cf9be679784c331d426b43ac99be8608c4505` |

### Phase 1 executor replay of M00

The public mutation catalog includes the five checker variants against the
current checker bytes. Each uses the existing focused fixture with its
designated assertion marker. The Phase 0 scratch results remain tied to
their original build. The registered replay is pending.

| Variant | Source SHA-256 | Binding SHA-256 | Candidate SHA-256 |
|---|---|---|---|
| `M00-future-dependency` | `db296023a0fb91727b57c4b52d45d3adbd7da70b4e9b624a1497d130dd6e82f5` | `08f34c8aa4ee0dde6797500cb6cc602d68198f5394504c5e6c0794e34b3567bb` | `23916bfe58a2662aaad4635868bf64d03d8ab042bd42dfa152941a6c3fb940ad` |
| `M00-invalid-remover` | `db296023a0fb91727b57c4b52d45d3adbd7da70b4e9b624a1497d130dd6e82f5` | `5655b1b9145512a6e4a42014310f7e53d342fc41412116d55bbdf8a5291204c4` | `630ec88932fcf1ef04ebc0363f7310c535078f40bd096a0f09ebd502197aa215` |
| `M00-missing-evidence` | `db296023a0fb91727b57c4b52d45d3adbd7da70b4e9b624a1497d130dd6e82f5` | `8159ef86ef5e5d2f16244089ec5f8927d834b79092e1df8f34fb5bd88a97c9f5` | `f97b267020643b5b037570dc960fba46fcd7ec25b69af5c800de03269cab4984` |
| `M00-foreign-evidence` | `db296023a0fb91727b57c4b52d45d3adbd7da70b4e9b624a1497d130dd6e82f5` | `eb6d2bbf63c26c8ee67c52d5ce8187f0ae731c31333ebdc8428d5aa2567ded23` | `61be07dde762bdebc3e6786a6aa9b15e1de71f5b40772c912dbf033510114ffc` |
| `M00-missing-current-source` | `db296023a0fb91727b57c4b52d45d3adbd7da70b4e9b624a1497d130dd6e82f5` | `1c7150a66bc1a79355c53b90cf467b19bd833c4a5967e55b79e646054616173c` | `74744f5134337a1f0259c81121103baa478cb14dbf4bd507f9acd50f8291db8d` |

## Result rules

| Outcome | Meaning | Counts toward required critical detection? |
|---|---|---|
| Killed | The mutated code compiles and the designated unchanged behavioral test/assertion fails for the intended invariant | Yes, with exact failure evidence |
| Survived | Mutated code compiles and relevant tests complete without detecting the defect | No; strengthen the tests or establish reviewed equivalence |
| Invalid | Patch-site preconditions fail, the patch does not apply, or compilation/typechecking fails | No; replace with a compile-valid meaningful fault |
| Inconclusive | Baseline failure, unavailable dependency, harness crash, unrelated test failure, generic timeout, or missing result | No; repair execution and rerun within an explicitly declared budget |
| Equivalent | A documented review establishes the mutation cannot change supported behavior under the recorded contract/source identity | Only as an explicit justified exclusion; seek a meaningful replacement fault |

An unrelated test failure cannot be relabeled Killed. A timeout alone does not prove the intended fault was detected. The expected assertion remains unchanged between baseline and mutant. Do not weaken tests, delete a case or silently alter the scope to obtain a green gate. Surviving non-equivalent critical variants, invalid/inconclusive substitutes and missing required results keep the phase open.

## Execution and isolation

1. Pass the unmodified baseline using the same selected tests, trusted dependencies and toolchain. Bind results to the baseline source/build identity so a stale artifact cannot kill a new mutant.
2. Apply exactly one reviewed semantic source mutation to an isolated non-secret snapshot with a separate build directory. Do not modify the working checkout, operator executable or tests under evaluation. When testing an observer, keep its external meta-test independent and unchanged.
3. Run within fixed build, test, memory/disk and cleanup budgets declared before execution. A budget extension is an explicit new attempt, not invisible deadline refresh. Record patch identity, intended and actual assertion/test outcome, elapsed time and cleanup.
4. Dangerous ownership/deletion/credential mutants execute offline against pure or provider-boundary fixtures. They receive no real AWS credential, `test-secrets.dhall`, elevated input, operator data root, current kubeconfig, unrestricted runtime socket or artifact publication capability. Enforce isolation through the process/container boundary; environment clearing alone is insufficient.
5. Build with prepared trusted dependencies and no provider egress. An unmodified outer runner may create a reviewed disposable local fixture and expose only its exact scoped interface. It verifies cleanup independently; a mutant cannot authorize its own boundary or certify its own resource absence.
6. Never deploy/publish mutated images or binaries to production or real AWS. Live provider/public-edge qualification runs separately identified unmodified code. Mutation evidence demonstrates test sensitivity, not actual AWS/Kubernetes success.

Re-run affected variants when implementation, relevant tests, observers, patch definitions or supported contracts change. Reuse the same named invariant across the offline mutant and real acceptance scenario. Maintain small selected cases around changed critical code rather than a global mutation percentage or a mutation of every expression.

## Delivery order and cost

Phase 0 defines the catalog, result schema and closure rule and runs M00 with current build/test tooling in safe scratch copies. It does not wait for a general mutation runner. Phase 1 implements the minimal bounded executor in the existing scenario/evidence path, proves isolation and outcome classification, and reruns M00 plus M01/M02 through it. Include a real compiled surviving calibration fault and separate invalid/inconclusive executions so “any nonzero exit means killed” cannot pass.

Expose named cases through the same scenario registry, including `test run mutations`; cumulative phase execution includes the relevant owned variants. Exact-source and expected-test selectors are data in this Markdown catalog and its implementation bindings, not a second test orchestrator. Pure build/fixture cases may enter `dev check` within its declared budget. Do not run a real cloud campaign per mutant or make a generic mutation framework a prerequisite for product delivery.

Each later phase adds its current-capability variants and includes them in its own closure. Phase 10 reruns the final affected catalog; it is not the first point at which earlier mutations must detect their faults. State mutation outcome counts and scope without treating their percentage as a reliability guarantee.
