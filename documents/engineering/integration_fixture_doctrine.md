# Integration Fixture Doctrine

**Status**: Authoritative source
**Supersedes**: N/A
**Referenced by**: documents/engineering/README.md, documents/engineering/unit_testing_policy.md, documents/engineering/storage_lifecycle_doctrine.md, documents/engineering/prerequisite_doctrine.md

> **Purpose**: Define pytest fixture doctrine for cluster-backed integration test setup, teardown, and cleanup failure handling.

---

## 0. Canonical Doctrine Statements

Cluster-backed integration tests must establish the conditions required to pass through pytest fixtures; tests must not rely on residual cluster state from prior tests.

Test outcomes are pass/fail only; pytest warnings are prohibited in the suite.

Fixture teardown must always attempt cleanup after the test, including failing tests, using pytest yield-fixture or finalizer semantics.

Any teardown cleanup failure must abort the entire pytest session immediately.

---

## 1. Scope

This doctrine applies to integration tests that mutate real cluster state:

1. Namespace-scoped gateway pod tests.
2. Shared-runtime lifecycle tests that exercise canonical `prodbox` resources.
3. Any future cluster-backed pytest integration that creates or mutates Kubernetes resources.

It does not restate `prodbox test` prerequisite/runbook gating. That operator-facing contract remains owned by [Unit Testing Policy](./unit_testing_policy.md#two-phase-test-command-doctrine).

---

## 2. Fixture Ownership Rules

### 2.1 Setup Ownership

The fixture, not the test body, owns cluster preconditions.

Examples:

1. Create a unique namespace and certificates before yielding a gateway mesh fixture.
2. Reconcile shared baseline runtime before yielding a lifecycle fixture.
3. Wait for required readiness/convergence signals before yielding when those signals are baseline preconditions for the assertions.

### 2.2 Teardown Ownership

The same fixture that established cluster state owns teardown.

Idiomatic pattern:

```python
# Example: tests/integration/conftest.py
@pytest_asyncio.fixture
async def cluster_fixture() -> AsyncIterator[ClusterContext]:
    context = await build_cluster_context()
    yield context
    await cleanup_cluster_context(context)
```

Cluster cleanup must not be open-coded in each test body via repeated `try/finally` blocks when a fixture can own that lifecycle once.

---

## 3. Isolation Modes

### 3.1 Isolated Namespace Fixtures

Default mode for ephemeral integration resources:

1. Allocate a unique namespace per test.
2. Create only the resources needed for that test.
3. Delete the namespace during fixture teardown.

### 3.2 Shared Runtime Baseline Fixtures

Some lifecycle tests intentionally target canonical shared runtime objects in `prodbox`.

For those tests, the fixture contract is:

1. Reconcile the canonical post-deploy baseline runtime before yield.
2. Remove all test-created resources after yield, including any temporary storage artifacts owned by the fixture.
3. Reconcile the same post-deploy baseline runtime again before fixture teardown returns.

This is the only allowed alternative to unique-namespace isolation.

---

## 4. Cleanup Failure Handling

Cleanup must always be attempted, but warning-only cleanup outcomes are prohibited.

Required behavior:

1. Pytest warnings are treated as errors so the suite remains pass/fail only.
2. Teardown catches cleanup exceptions only long enough to convert them into an immediate session abort with explicit target and error text.
3. Shared-runtime baseline restore failure is a teardown cleanup failure and must stop the suite.
4. Observational runtime objects such as Kubernetes `Event` resources are not fixture-owned pass conditions and must not be treated as teardown blockers.

Rationale: a teardown cleanup failure can invalidate the baseline needed for every later cluster-backed test, so the suite must stop instead of continuing on ambiguous state.

---

## 5. Relationship To Other Doctrine

1. Test command prerequisite/runbook gating is defined in [Unit Testing Policy](./unit_testing_policy.md#two-phase-test-command-doctrine).
2. Shared runtime retention/rebinding expectations and the definition of post-deploy baseline are defined in [Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md#6-test-expectations).
3. Runtime-managed prodbox namespace ownership is defined in [Prerequisite Doctrine](./prerequisite_doctrine.md#0-canonical-doctrine-statements).

---

## Cross-References

- [Unit Testing Policy](./unit_testing_policy.md)
- [Storage Lifecycle Doctrine](./storage_lifecycle_doctrine.md)
- [Prerequisite Doctrine](./prerequisite_doctrine.md)
- [Documentation Standards](../documentation_standards.md)
