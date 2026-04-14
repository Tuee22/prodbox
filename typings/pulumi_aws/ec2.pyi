"""Type stubs for pulumi_aws.ec2 module."""

from typing import Mapping, Sequence

from pulumi import InvokeOptions, Output, ResourceOptions

class GetAmiFilterArgs:
    def __init__(self, name: str, values: Sequence[str]) -> None: ...

class GetAmiResult:
    id: str

class RouteTableRouteArgs:
    def __init__(self, cidr_block: str, gateway_id: object) -> None: ...

class SecurityGroupIngressArgs:
    def __init__(
        __self,
        protocol: str,
        from_port: int,
        to_port: int,
        cidr_blocks: Sequence[str] | None = None,
        self: bool = False,
    ) -> None: ...

class SecurityGroupEgressArgs:
    def __init__(
        self,
        protocol: str,
        from_port: int,
        to_port: int,
        cidr_blocks: Sequence[str] | None = None,
    ) -> None: ...

class InstanceRootBlockDeviceArgs:
    def __init__(
        self,
        volume_type: str,
        volume_size: int,
        delete_on_termination: bool,
    ) -> None: ...

class Vpc:
    id: Output[str]

    def __init__(
        self,
        resource_name: str,
        cidr_block: str,
        enable_dns_hostnames: bool = False,
        enable_dns_support: bool = False,
        tags: Mapping[str, object] | None = None,
        opts: ResourceOptions | None = None,
    ) -> None: ...

class InternetGateway:
    id: Output[str]

    def __init__(
        self,
        resource_name: str,
        vpc_id: object,
        tags: Mapping[str, object] | None = None,
        opts: ResourceOptions | None = None,
    ) -> None: ...

class RouteTable:
    id: Output[str]

    def __init__(
        self,
        resource_name: str,
        vpc_id: object,
        routes: Sequence[RouteTableRouteArgs] | None = None,
        tags: Mapping[str, object] | None = None,
        opts: ResourceOptions | None = None,
    ) -> None: ...

class Subnet:
    id: Output[str]

    def __init__(
        self,
        resource_name: str,
        vpc_id: object,
        cidr_block: str,
        availability_zone: str,
        map_public_ip_on_launch: bool = False,
        tags: Mapping[str, object] | None = None,
        opts: ResourceOptions | None = None,
    ) -> None: ...

class RouteTableAssociation:
    def __init__(
        self,
        resource_name: str,
        subnet_id: object,
        route_table_id: object,
        opts: ResourceOptions | None = None,
    ) -> None: ...

class SecurityGroup:
    id: Output[str]

    def __init__(
        self,
        resource_name: str,
        vpc_id: object,
        description: str,
        ingress: Sequence[SecurityGroupIngressArgs] | None = None,
        egress: Sequence[SecurityGroupEgressArgs] | None = None,
        tags: Mapping[str, object] | None = None,
        opts: ResourceOptions | None = None,
    ) -> None: ...

class KeyPair:
    key_name: Output[str]

    def __init__(
        self,
        resource_name: str,
        key_name: str,
        public_key: str,
        opts: ResourceOptions | None = None,
    ) -> None: ...

class Instance:
    id: Output[str]
    private_ip: Output[str]
    public_ip: Output[str]

    def __init__(
        self,
        resource_name: str,
        ami: str,
        instance_type: str,
        subnet_id: object,
        vpc_security_group_ids: Sequence[object],
        associate_public_ip_address: bool,
        iam_instance_profile: object | None = None,
        key_name: object | None = None,
        user_data: str | None = None,
        root_block_device: InstanceRootBlockDeviceArgs | None = None,
        tags: Mapping[str, object] | None = None,
        opts: ResourceOptions | None = None,
    ) -> None: ...

def get_ami(
    *,
    most_recent: bool,
    owners: Sequence[str],
    filters: Sequence[GetAmiFilterArgs],
    opts: InvokeOptions | None = None,
) -> GetAmiResult: ...

__all__ = [
    "GetAmiFilterArgs",
    "GetAmiResult",
    "Instance",
    "InstanceRootBlockDeviceArgs",
    "InternetGateway",
    "KeyPair",
    "RouteTable",
    "RouteTableAssociation",
    "RouteTableRouteArgs",
    "SecurityGroup",
    "SecurityGroupEgressArgs",
    "SecurityGroupIngressArgs",
    "Subnet",
    "Vpc",
    "get_ami",
]
