"""CLI-invocable runner for the AWS fixture janitor sweep.

Usage: python -m tests.integration.sweep_runner

Exit codes:
    0 - sweep completed (may or may not have deleted resources)
    1 - sweep failed
"""

from __future__ import annotations

import json

from tests.integration.aws_helpers import sweep_expired_fixture_resources


def main() -> int:
    """Run the fixture sweep and print JSON result to stdout."""
    result = sweep_expired_fixture_resources()
    payload: dict[str, int] = {
        "deleted_hosted_zones": result.deleted_hosted_zones,
        "deleted_buckets": result.deleted_buckets,
        "deleted_vpcs": result.deleted_vpcs,
        "deleted_eks_clusters": result.deleted_eks_clusters,
        "deleted_iam_roles": result.deleted_iam_roles,
    }
    print(json.dumps(payload))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
