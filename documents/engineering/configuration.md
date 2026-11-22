# Configuration and Deployment Context

**Status**: Authoritative source
**Supersedes**: Pre-refactor configuration doctrine and duplicated prerequisite configuration rules
**Generated sections**: none
**Applicability**: Adopted target contract; current configuration loaders are not yet replaced

> **Purpose**: Define one authored Dhall specification, explicit contexts, and capability-specific validation.

## Sources

Keep Dhall and its versioned schemas. The binary-sibling `prodbox.dhall` remains the production default; a global `--config PATH` selects another explicit specification. Resolve relative storage paths from the specification's validated project/context anchor, never incidental working directory or ambient configuration.

The selected Dhall file is the authored desired specification. The Authority records accepted request/specification digest, applied generation and actual observations. It is not a second hidden configuration source with different values. Retaining the specification after cloud deletion permits an intentional future reconcile; it does not imply resources still exist.

| Input class | Source |
|---|---|
| Product constants and protocol vocabulary | Typed compiled catalogs; no operator copy of the same fact |
| Deployment identity and non-secret operator choices | Selected `prodbox.dhall` and validated bootstrap identity |
| Operational secrets | Typed Vault references resolved only by the authorized role |
| Elevated creation/retirement input | Ephemeral prompt, or test-only prompt simulation |
| Test topology and budgets | Separately authored `prodbox.test.dhall` |
| Test external/secret inputs | Owner-safe `test-secrets.dhall`; never copied into production config |
| Per-run identities/endpoints/paths | Derived from the validated test plan and stable run ID |

Do not use `AWS_*`, `PRODBOX_*`, shared AWS profiles or daemon environment fallback as supported auth/config sources. Daemon launch takes an explicitly mounted role-scoped configuration. Secrets cannot appear in argv, logs, compiled artifacts or generated non-secret projections.

The sealed kind bridge client accepts `PRODBOX_KIND_BRIDGE` as a non-secret
subprocess endpoint selector. It accepts a bounded absolute path without `..`
components or colons. The selector is not deployment configuration or
evidence of endpoint or worker authority; its caller must supply and
authenticate those boundaries. The public kind lifecycle does not yet launch
this client.

## Minimal bootstrap projection

Status, never-admitted delete and control bootstrap require only installation/root identity, local endpoints, kind topology, artifact identity and unlock policy as applicable. They do not require application FQDN, ACME, SES or AWS settings. Validate a feature's configuration only when that requested capability needs it.

Separate decoding, semantic validation, context narrowing and effect execution. Structured failures name the field/capability and remedy without leaking values. No malformed optional projection may become an invented default region, account, domain or address.

The current Phase 1 `control status` diagnostic reads a self-contained Dhall
record's `bootstrap` field. It requires `schema_version`, `project_anchor`,
`runtime_socket`, `environment` (`production` or `test`), `deployment_id`,
`root_generation` (32 lowercase hexadecimal characters), `api_port`,
`node_image` (a digest-pinned reference), `http_host_port`, `http_node_port`,
`https_host_port`, `https_node_port`, and `listen_address`. Ports are Dhall
`Natural` values. The two node ports must be in Kubernetes' default NodePort
range, 30000 through 32767, because the rendered kind configuration does not
change that range. The remaining coordinates are `Text`, except
`schema_version`, which may be `1`, `2` or `3`. Version 2 additionally requires
`node_artifact`, a record with `path` under `artifacts/` relative to the
selected root, a lowercase `sha256:` file digest, and `maximum_bytes` as a
positive `Natural` no larger than 4 GiB. Version 1 must not include this
record. Version 3 requires both `node_artifact` and a distinct `kind_tool`
record with the same fields; the tool's `maximum_bytes` is at most 128 MiB.
Versions 1 and 2 must not include `kind_tool`. The project anchor and Docker socket must be
absolute paths. The selected source currently must not contain
Dhall imports. The selected reader opens every parent and the file without
following symlinks, reads bounded bytes, and checks the reopened path and file
identity after the read. This observation does not bind the selected document
to a deployment or authorize a later effect. The diagnostic observes the selected root, generation record,
and local Docker inventory; it reports the checks it cannot yet perform. It
does not create a cluster or establish lifecycle authority. With a version 2
declaration and an observable root, it also hashes the selected retained file
and reports whether its bytes match the declared file digest. This does not
verify archive structure, image identity, architecture or provenance.
For version 3, status separately reports the retained kind executable's file
digest; it does not execute the tool or verify its version or provenance.
The diagnostic separately queries the selected Docker daemon for the pinned
node image. If inspect succeeds, it reports the daemon's image ID, OS,
architecture and whether the selected digest appears in its repository-digest
metadata. A failed query is unobservable, not an absence finding. These
metadata do not establish that the retained file produced the daemon image.
Status also reads the daemon ID twice and compares the selected socket's local
identity around those reads. A changed or unavailable observation is reported
as such. A repeated ID does not authenticate the daemon or rule out a socket
replacement between observations. Docker documents this field in its
[system information output](https://docs.docker.com/reference/cli/docker/system/info/).
Status also opens a separate Unix-socket connection and reports its kernel peer
credentials when observable. The
[socket library](https://hackage-content.haskell.org/package/network-3.1.4.0/docs/Network-Socket.html#v:getPeerCredential)
uses the operating system's Unix peer-credential mechanism. Socket activation or a proxy can make that peer
different from the process serving Docker requests. The observation is not
bound to the separate Docker CLI queries and does not authenticate the daemon.
Status also reads the daemon's system information through a held Unix-socket
connection and reports the ID and peer observed on that connection. This
bounded read is still an unauthenticated observation; it is not a load or an
operation-settlement receipt.
For the explicitly selected `/run/docker.sock`, status holds a connection
while reading the fixed Docker socket and service units from the root-owned
system bus. It reports the manager PID, held peer credentials, listener list,
unit states, trigger list, accept mode and service PID when observable. The
peer PID comparison and listener configuration do not prove socket-inode
ownership or authenticate the daemon. Other selected sockets do not use this
manager observation.
For an observable root generation, status also reports a locally stored kind
operation record as matching the selected configuration, conflicting, invalid,
missing or unobservable. A match is a read-only observation: it does not prove
admission or completion, and a missing file does not prove operation absence.
Status reads the local node-configuration attempt and result independently of
the Docker connection. It reports an unconfirmed submission as unconfirmed;
neither a record nor a daemon response proves file contents or worker
settlement. If Docker inventory is unavailable, status still prints the local
observations, reports the inventory failure and exits nonzero.
When the parent kind operation matches, status also checks the local node-image
intent record. A matching record does not establish that the daemon effect
completed or that its worker settled; an absent local record is not proof that
an image is absent. If the record includes a daemon observation, status also
compares it with the separately sampled current daemon and socket identity.
That comparison is not atomic and does not authenticate either observation.
Status also reports the local image-attempt marker when it can validate the
parent operation and image intent. A matching marker means an effect may have
been attempted; neither a matching nor missing marker establishes whether a
daemon worker ran or settled. Invalid, conflicting or unsafe records remain
separate observations.
For a matching kind operation, status also attempts to reacquire the operation
lease and reports the retained network proposal and attempt alongside scoped
Docker inventory and, when available, exact network details. A busy lease,
changed daemon or unreadable record is reported separately. Empty inventory
does not prove absence; the sampled daemon is not authenticated, and network
ownership and worker settlement remain unverified. A configuration match
compares the proposed subnet, MTU, driver, IPv6 setting and scoped labels; it
is not proof that this operation created or owns the network. Status also
reports the retained removal target and rechecks that record around the Docker
observation; the local record does not establish that removal completed. When
the target is recorded, status separately queries Docker inventory by its full
ID. An empty response is a point observation, not an absence proof. When
transport receipts are available, status reports create and removal responses
separately from resource observations; a receipt does not establish a
postcondition or worker settlement. When
the removal target is recorded, a separate Docker CLI query also observes
that exact ID; the two results are reported separately. Each query first checks
that its ID filter can see the built-in bridge, and reports a blind control
instead of a target result when it cannot. When
an exact network is observable, status also compares it with a read through a
separate Docker client, bracketed by daemon and scope observations. Both reads
still depend on the selected daemon and do not authenticate it.
For a matching kind operation, status checks the retained node-create proposal
against the selected plan and connected daemon identity, and reports any
retained node create and start attempts and transport results separately. A
matching proposal, marker or reply is not admission, resource provenance,
readiness or worker settlement; node creation remains unavailable through the
public lifecycle.
When the recorded create result includes a full container ID, status also reads
that exact ID and compares the selected identity, image, network and mounts.
A matching running container remains an observation; it does not establish
provenance or Kubernetes readiness. An inspect failure is unobservable.
For a matching kind operation, status also derives its candidate node `/var`
volume name and reads that exact name on the selected Docker connection under
the recovered operation lease. A 404 is reported as a daemon response, while
matching labels/configuration and conflicting configuration are distinct.
Status also checks for a local node-volume proposal bound to the operation,
root generation, selected socket and observed daemon. A missing, conflicting,
invalid or unobservable proposal is distinct from a matching record. When the
proposal matches, status also reports its separately recorded volume attempt
and any retained create or removal transport result. A missing or matching
attempt or removal marker does not establish the outcome of an effect; a
response does not prove resource ownership or absence.
For a matching removal marker, status also repeats an unfiltered Docker volume
inventory and a container-by-volume query through a separate Docker client on
the selected socket, with operation and daemon identity rechecks. A sampled
empty result is a point observation, not proof of absence, ownership, daemon
authenticity or worker settlement.
The recording primitives and bounded Docker request are not yet connected to a
public lifecycle operation with admission and cleanup. Neither the candidate
read, a matching proposal nor a Docker response proves admission, volume
ownership, daemon authenticity or worker settlement.
`control inspect-image-attempt OPERATION` additionally rebuilds an anonymous
stage from the retained node archive under the exact recorded operation and
reads its config image ID through the selected Docker connection. It reports
attempt-marker samples from before and after the image query and any recorded
transport outcome. It also samples the exact image ID using a separate Docker
CLI request bracketed by daemon and operation checks. The outcome is a local
record, not a daemon receipt or evidence that a worker settled. The samples are
not atomic, and the command neither submits an image load nor proves daemon
worker settlement, resource ownership or image absence. Staging can consume
up to 4 GiB of temporary space under the selected root. The command reserves
the calculated archive size before conversion and refuses if the filesystem
cannot provide the reservation. This does not reserve capacity for other
operations or for Docker's image storage.
For a matching volume-specific record, status also observes the corresponding
host directory and rechecks the record. This does not establish that a node or
Pod mounts the directory, or that a missing directory proves resource absence.
When a selected kubeconfig is readable, status also reads the named PV and PVC
through its configured loopback endpoint and rechecks the record and kubeconfig
contents. The configured CA has not been independently tied to an owned
cluster; the read does not establish cluster ownership or a node or Pod mount.
When the selected root is present, status samples host CPU affinity, total
host memory and total filesystem sizes for `/` and the retained root. It also
samples host `MemAvailable` and filesystem space available to unprivileged
users for both paths. These volatile host observations are not reservations
and do not establish cgroup limits, quotas or workload fit. A failed or
changed observation is reported as unobservable.
Status also checks whether the selected root's kubeconfig can be read safely
and has the expected structural scope. This local check does not authenticate
the cluster or validate its certificates.
For an observed control-plane container, its mount report covers the bind
source, target, and Docker's configured writable flag; it does not prove a Pod
can write or that the data generation has survived node recreation.
`control plan` renders the selected bootstrap's candidate kind configuration
from the same projection used by the operation intent. It does not inspect
root ownership, retained artifacts, ports, runtime, CNI or cluster state and
does not create resources.
`config schema` also generates `prodbox-bootstrap-types.dhall`, with Version1,
Version2 and Version3 field types derived from the corresponding runtime
decoders. These types do not enforce semantic bounds; selected validation does.
The selected-source lane currently refuses imports, so the generated schema is
an authoring reference and an inline type annotation may be used in a selected
document. `prodbox --config PATH config setup` can create a new bootstrap-only
version 3 document from prompted non-secret coordinates. It validates the
rendered fields before exclusive publication and does not overwrite an existing
file or pending publication. Cooperating selected-document publishers acquire
a nonblocking lease on the configuration parent; a busy or unobservable lease
refuses publication. The lease cannot establish that an older non-cooperating
writer has stopped. A document must be named `prodbox.dhall` in
the selected deployment root's `config/` directory. If its generation is unavailable,
the operator may explicitly choose to enroll a fresh production or test root; existing roots
and incomplete enrollment are never adopted or replaced. The generation must
match before and after publication. A root enrolled before a publication
failure is retained for recovery. The command does not verify artifact bytes
or create a cluster. Selected setup currently
refuses `--dry-run` and `--plan-file`. For a v2 pending publication, setup can
offer recovery after the operator re-enters the exact draft; recovery requires
the same bytes, a settled cooperating lease, and an absent destination.
Legacy pending files and mismatches are retained. An uncertain outcome still
requires observation; setup can compare an existing destination against the
re-entered exact draft when no pending file is present. A match reports the
observed content only, with publication origin unverified. Setup does not
overwrite a competing specification.
After setup, `prodbox --config PATH control import-artifact kind-tool SOURCE`
and `control import-artifact node-archive SOURCE` retain the declared files
from absolute local paths. The command checks the configured digest and size,
never replaces a conflicting destination, and can resume an exact staged
prefix by repeating the command with the same source. It refuses a symlink,
hard-linked source or a source named `test-secrets.dhall` before reading it.
An incomplete or
conflicting staged file is retained. To discard only that staging file, run
`prodbox --config PATH control discard-artifact-staging ROLE`; a retry also
handles a staging discard interrupted after its quarantine rename. If both
the pending and quarantine files are present, discard reports incomplete after
removing the quarantine; repeat it to discard the remaining pending file.
Digest agreement does not establish image contents or provenance.
`prodbox --config PATH control inspect-node-archive` reads a retained,
uncompressed OCI layout, including Docker schema-2 manifests, and checks the configured image digest, selected
Linux platform, and the digest and size of its referenced config and layers.
It reports the number of top-level descriptors and how many carry either of
two recognized image-name annotations, without printing their values. That
count is not a complete inventory of possible load effects.
Unsupported layouts, malformed entries, missing blobs and mismatches are
refused. The command also compares the verified config digest and platform
with separately observed metadata from the selected Docker socket while the
archive descriptor is held and its identity is rechecked; a missing daemon
observation is unobservable. Docker can report either a config digest
or an image descriptor as its image ID. A descriptor match is reported
separately because it does not independently expose the daemon's config digest.
The diagnostic also queries the config and selected manifest IDs individually
and reports the daemon's platform and tag count when an exact ID is observed.
Tag values are not printed. A failed ID lookup is unobservable; it does not
establish that the image is absent or owned by this deployment.
These observations are not atomic and do not grant lifecycle admission.
Inspection does not extract or load the image,
validate its publisher or establish that a daemon can run it.
The legacy authoring
writer refuses an observed top-level field it cannot preserve, rather
than silently removing it. Imported dependencies are not yet bound to the
later publication; the selected bootstrap diagnostic currently refuses imports.
`--config PATH config validate` accepts an exact bootstrap-only record and
reports that application settings and runtime state were not checked. For a
legacy configuration it validates parameters and context, plus a bootstrap
field when present; absence remains valid for legacy configurations. A partial
legacy record is not treated as bootstrap-only. This validation does not
establish root ownership.
When both `bootstrap` and the legacy `context` are present, the bootstrap
`deployment_id` must equal `context.cluster_id`; a mismatch is refused before
the control diagnostic contacts Docker. A bootstrap-only diagnostic does not
require a legacy context. Existing identities needing a different mapping must
use the explicit migration path owned by Phase 10.

## Environment and target selection

A context binds production/test environment, installation/run ID, root generation, control endpoints and selected application targets. AWS additionally binds the independently verified account and explicit regions. Local and AWS are explicit target constructors; checkpoint presence does not select a substrate or EKS drain target.

Production uses `.data`; tests use isolated `.test-data` contexts with unique kind names, mounts, kubeconfigs, ports, object namespaces, credentials and ownership. Test generation calls the production builder with its own inputs and output path. It never rewrites or borrows the operator's production sibling.

## Publication and component changes

`config setup/generate` authors non-secret specifications; `show` redacts handles/value classes appropriately; `validate/schema` remain read-only tools. Publish changes atomically with durable read-back and exact source identity. Register the intended change before any effect and recover interrupted publication without silently overwriting a competing specification.

Component desired-state deletion updates the selected specification and Authority request before removing resources. A temporary stop/restart is explicitly named as such. A normal reconcile must not unexpectedly recreate an intentionally removed component. [CLI](cli_command_surface.md#operator-commands)

## Prerequisites

Prerequisites are typed capabilities derived from the selected operation, not a global all-services gate. Observe and classify unavailable, needs-input and unobservable separately. Acquire only required tools, caller identities, unlock material and provider credentials. Read-only status never repairs state implicitly; mutation commands own their visible recovery steps.

Phase 1 proves source partition/path selection. Later phases extend projections and the same shared builder, not replace the context contract. [Acceptance cases](../../DEVELOPMENT_PLAN/acceptance_cases.md)

## Implemented through Phase 1

The selected bootstrap document (schema version 3) fixes the project anchor, identity, generation, ports, node image and artifact digests; roots, kind names and kubeconfigs derive from it. No ambient `KUBECONFIG`, `DOCKER_HOST` or RKE2 setting selects a target in the new control modules (a unit test scans them), and a decoy kubeconfig named in the environment receives no connection. Cross-environment declarations, an unavailable node image and a sibling scope on the same host ports or kind name are refused before effects. Evidence: [Phase 1 validation](../../DEVELOPMENT_PLAN/evidence/phase_01_validation.md).

## Implemented through Phase 2

The MinIO bootstrap root credential is a compiled bootstrap-floor constant because the Broker's object-store code requires it; per-environment access is the random unlock-reader user. Service Pod limits are Vault 128Mi/512Mi, MinIO 256Mi/1Gi and the client 32Mi/512Mi, and the management NetworkPolicy is a pinned default-deny with an allow from pods labelled `prodbox.io/management-client: "true"` and from the Broker namespace.
