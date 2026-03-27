"""Pulumi provider setup for Kubernetes and AWS."""

from __future__ import annotations

from typing import TYPE_CHECKING

import pulumi_aws as aws
import pulumi_kubernetes as k8s

from prodbox.lib.aws_auth import assert_ambient_aws_auth_only

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
        settings: Application settings with AWS region

    Returns:
        Configured AWS provider
    """
    assert_ambient_aws_auth_only()
    return aws.Provider(
        "aws-provider",
        region=settings.aws_region,
    )
