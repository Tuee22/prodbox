"""Type stubs for pulumi_aws.eks module."""

from typing import Mapping, Sequence

from pulumi import Output, ResourceOptions

class ClusterAccessConfigArgs:
    def __init__(
        self,
        authentication_mode: str,
        bootstrap_cluster_creator_admin_permissions: bool,
    ) -> None: ...

class ClusterVpcConfigArgs:
    def __init__(
        self,
        subnet_ids: Sequence[object],
        endpoint_private_access: bool,
        endpoint_public_access: bool,
        public_access_cidrs: Sequence[str],
    ) -> None: ...

class NodeGroupScalingConfigArgs:
    def __init__(
        self,
        desired_size: int,
        min_size: int,
        max_size: int,
    ) -> None: ...

class ClusterVpcConfig:
    cluster_security_group_id: Output[str]

class Cluster:
    name: Output[str]
    vpc_config: ClusterVpcConfig

    def __init__(
        self,
        resource_name: str,
        name: str,
        role_arn: object,
        access_config: ClusterAccessConfigArgs,
        vpc_config: ClusterVpcConfigArgs,
        tags: Mapping[str, object] | None = None,
        opts: ResourceOptions | None = None,
    ) -> None: ...

class NodeGroup:
    node_group_name: Output[str]

    def __init__(
        self,
        resource_name: str,
        cluster_name: object,
        node_group_name: str,
        node_role_arn: object,
        subnet_ids: Sequence[object],
        instance_types: Sequence[str] | None = None,
        disk_size: int | None = None,
        scaling_config: NodeGroupScalingConfigArgs | None = None,
        tags: Mapping[str, object] | None = None,
        opts: ResourceOptions | None = None,
    ) -> None: ...

__all__ = [
    "Cluster",
    "ClusterAccessConfigArgs",
    "ClusterVpcConfig",
    "ClusterVpcConfigArgs",
    "NodeGroup",
    "NodeGroupScalingConfigArgs",
]
