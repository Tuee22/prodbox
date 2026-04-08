"""Pulumi provider setup for Kubernetes and AWS."""

from __future__ import annotations

from pathlib import Path
from typing import TYPE_CHECKING

import pulumi_aws as aws
import pulumi_kubernetes as k8s

if TYPE_CHECKING:
    from prodbox.settings import Settings

_DEFAULT_KUBECONFIG: Path = Path.home() / ".kube" / "config"


def create_k8s_provider(_settings: Settings) -> k8s.Provider:
    """Create a Kubernetes provider using the default kubeconfig.

    Args:
        _settings: Application settings (kubeconfig always uses default path)

    Returns:
        Configured Kubernetes provider
    """
    return k8s.Provider(
        "k8s-provider",
        kubeconfig=str(_DEFAULT_KUBECONFIG),
    )


def create_aws_provider(settings: Settings) -> aws.Provider:
    """Create an AWS provider from settings.

    Args:
        settings: Application settings with AWS region

    Returns:
        Configured AWS provider
    """
    return aws.Provider(
        "aws-provider",
        region=settings.aws_region,
        access_key=settings.aws_access_key_id,
        secret_key=settings.aws_secret_access_key,
        token=settings.aws_session_token,
    )
