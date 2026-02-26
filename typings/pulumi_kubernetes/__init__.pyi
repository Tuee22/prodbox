"""Type stubs for pulumi-kubernetes.

Provides typed interfaces for Kubernetes provider and resources.
"""

from typing import Sequence
from pathlib import Path

class Provider:
    """Kubernetes provider."""

    def __init__(
        self,
        resource_name: str,
        kubeconfig: str | None = None,
        context: str | None = None,
        cluster: str | None = None,
        namespace: str | None = None,
        enable_server_side_apply: bool = False,
        suppress_deprecation_warnings: bool = False,
        suppress_helm_hook_warnings: bool = False,
    ) -> None: ...

# Re-export submodules
from pulumi_kubernetes import helm as helm
from pulumi_kubernetes import core as core
from pulumi_kubernetes import meta as meta
from pulumi_kubernetes import apiextensions as apiextensions

__all__ = ["Provider", "helm", "core", "meta", "apiextensions"]
