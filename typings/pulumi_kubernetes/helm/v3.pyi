"""Type stubs for pulumi_kubernetes.helm.v3 module."""

from typing import Mapping, Sequence
from pulumi import ResourceOptions

class RepositoryOptsArgs:
    """Repository options for Helm charts."""

    def __init__(
        self,
        repo: str | None = None,
        ca_file: str | None = None,
        cert_file: str | None = None,
        key_file: str | None = None,
        password: str | None = None,
        username: str | None = None,
    ) -> None: ...

class Release:
    """Helm release resource."""

    def __init__(
        self,
        resource_name: str,
        chart: str | None = None,
        name: str | None = None,
        namespace: str | None = None,
        repository_opts: RepositoryOptsArgs | None = None,
        version: str | None = None,
        values: Mapping[str, object] | None = None,
        skip_await: bool = False,
        skip_crds: bool = False,
        create_namespace: bool = False,
        dependency_update: bool = False,
        atomic: bool = False,
        cleanup_on_fail: bool = False,
        disable_crd_hooks: bool = False,
        disable_webhooks: bool = False,
        force_update: bool = False,
        lint: bool = False,
        max_history: int | None = None,
        recreate_pods: bool = False,
        render_subchart_notes: bool = False,
        replace: bool = False,
        reset_values: bool = False,
        reuse_values: bool = False,
        timeout: int | None = None,
        wait: bool = False,
        wait_for_jobs: bool = False,
        opts: ResourceOptions | None = None,
    ) -> None: ...

    @property
    def status(self) -> object: ...

__all__ = ["Release", "RepositoryOptsArgs"]
