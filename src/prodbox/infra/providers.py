"""Pulumi provider setup for Kubernetes and AWS."""

from __future__ import annotations

from typing import TYPE_CHECKING

import pulumi_aws as aws
import pulumi_kubernetes as k8s

if TYPE_CHECKING:
    from prodbox.settings import Settings


def create_k8s_provider(settings: Settings) -> k8s.Provider:
    """Create a Kubernetes provider from settings.

    Args:
        settings: Application settings with kubeconfig path

    Returns:
        Configured Kubernetes provider
    """
    return k8s.Provider(
        "k8s-provider",
        kubeconfig=str(settings.kubeconfig),
    )


def create_aws_provider(settings: Settings) -> aws.Provider:
    """Create an AWS provider from settings.

    Args:
        settings: Application settings with AWS credentials

    Returns:
        Configured AWS provider
    """
    return aws.Provider(
        "aws-provider",
        region=settings.aws_region,
        access_key=settings.aws_access_key_id,
        secret_key=settings.aws_secret_access_key,
    )
