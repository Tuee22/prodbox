# Everyday Workflows

**Status**: Reference only
**Supersedes**: N/A
**Generated sections**: none
**Applicability**: Target public command behavior, not current-binary availability.

> **Purpose**: Explain goal-oriented operation and explicit deletion scope.

## Observe, plan and reconcile

Use `status` to see the selected deployment, retained control plane, application targets, pending operation and next action. Each fact names whether it is fresh, last-known or unobserved. Status is read-only and remains useful with sealed Vault, unavailable Broker or broken registry.

`plan reconcile` or `plan delete` uses the execution planner and prints scope, work and unresolved inputs. It does not silently repair infrastructure. `reconcile` acquires only the capabilities required by its selected desired targets, prompts for needed protected input, and resumes registered work.

`services list/status/logs` names application/control components and selected target. Advanced component deletion changes desired selection before effects; an ordinary reconcile must not recreate a deliberately removed service. Temporary stop/restart is a separate named maintenance action.

## Delete AWS application resources

`delete --yes` removes all AWS resources created/adopted by the selected deployment, including its SES, EBS/data buckets, DNS, backing stores and generated IAM. There is no cascade flag and no local uninstall branch. The plan makes the destructive data scope explicit.

Successful deletion independently verifies absence, retires obsolete checkpoints/credentials, records the AWS target absent and retains kind, Vault, MinIO, management trust, the operation journal and bounded terminal report. External account/domain/parent-zone resources and unrelated resources are outside its scope. Local application data/services are reported separately.

Repeating satisfied deletion reports Nothing to delete without unnecessary elevation or Vault initialization. A retained specification is a recipe for an intentional later reconcile, not evidence that AWS still exists.

## Remove control or data separately

`control delete --yes` removes kind only after exact cloud obligations are clean or positively never admitted. It preserves the host roots. `admin control purge-data` additionally requires exact root identity, no mounted consumers, satisfied obligations and explicit typed operator confirmation. A normal AWS delete cannot imply either action.

`operations list/show/resume/cancel` manages durable work. Cancellation requests settlement and eligible cleanup; it never certifies that a provider stopped. See [recovery](recovery.md).
