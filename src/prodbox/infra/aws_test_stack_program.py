"""Pulumi program for the AWS-backed HA-RKE2 validation stack."""

from __future__ import annotations

import os

import pulumi
import pulumi_aws as aws

from prodbox.infra.providers import create_aws_provider
from prodbox.settings import Settings

_CANONICAL_UBUNTU_OWNER: str = "099720109477"
_UBUNTU_2404_AMI_NAME_FILTER: str = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
_INSTANCE_TYPE: str = "t3.large"
_ROOT_VOLUME_SIZE_GIB: int = 30


def _required_env(name: str) -> str:
    """Return one required environment variable."""
    value = os.environ.get(name)
    if not isinstance(value, str) or value == "":
        raise ValueError(f"missing required environment variable {name}")
    return value


def _node_output_payload(values: tuple[object, ...], *, node_name: str) -> dict[str, object]:
    """Build one exported node payload from Pulumi output values."""
    if len(values) != 4:
        raise ValueError(f"unexpected node output payload for {node_name}")
    instance_id, private_ip, public_ip, availability_zone = values
    if not isinstance(instance_id, str) or instance_id == "":
        raise ValueError(f"missing instance_id for {node_name}")
    if not isinstance(private_ip, str) or private_ip == "":
        raise ValueError(f"missing private_ip for {node_name}")
    if not isinstance(public_ip, str) or public_ip == "":
        raise ValueError(f"missing public_ip for {node_name}")
    if not isinstance(availability_zone, str) or availability_zone == "":
        raise ValueError(f"missing availability_zone for {node_name}")
    return {
        "name": node_name,
        "instance_id": instance_id,
        "private_ip": private_ip,
        "public_ip": public_ip,
        "availability_zone": availability_zone,
    }


def _build_node_output(
    instance: aws.ec2.Instance,
    *,
    node_name: str,
    availability_zone: str,
) -> pulumi.Output[dict[str, object]]:
    """Build one exported node payload from EC2 instance outputs."""

    def render(values: tuple[object, ...]) -> dict[str, object]:
        return _node_output_payload(values, node_name=node_name)

    return pulumi.Output.all(
        instance.id,
        instance.private_ip,
        instance.public_ip,
        pulumi.Output.from_input(availability_zone),
    ).apply(render)


def main() -> None:
    """Provision the dedicated AWS test stack used by `ha-rke2-aws`."""
    settings = Settings.from_config_json()
    provider = create_aws_provider(settings)
    operator_cidr = _required_env("PRODBOX_AWS_TEST_OPERATOR_CIDR")
    public_key = _required_env("PRODBOX_AWS_TEST_PUBLIC_KEY")
    stack = pulumi.get_stack()

    availability_zones = aws.get_availability_zones(
        state="available",
        opts=pulumi.InvokeOptions(provider=provider),
    )
    zone_names = tuple(availability_zones.names[:3])
    if len(zone_names) != 3:
        raise ValueError("AWS test stack requires exactly 3 available availability zones")

    ubuntu_ami = aws.ec2.get_ami(
        most_recent=True,
        owners=[_CANONICAL_UBUNTU_OWNER],
        filters=[
            aws.ec2.GetAmiFilterArgs(name="name", values=[_UBUNTU_2404_AMI_NAME_FILTER]),
            aws.ec2.GetAmiFilterArgs(name="virtualization-type", values=["hvm"]),
            aws.ec2.GetAmiFilterArgs(name="architecture", values=["x86_64"]),
        ],
        opts=pulumi.InvokeOptions(provider=provider),
    )

    vpc = aws.ec2.Vpc(
        "aws-test-vpc",
        cidr_block="10.90.0.0/16",
        tags={"Name": f"{stack}-vpc"},
        opts=pulumi.ResourceOptions(provider=provider),
    )
    internet_gateway = aws.ec2.InternetGateway(
        "aws-test-igw",
        vpc_id=vpc.id,
        tags={"Name": f"{stack}-igw"},
        opts=pulumi.ResourceOptions(provider=provider),
    )
    route_table = aws.ec2.RouteTable(
        "aws-test-public-route-table",
        vpc_id=vpc.id,
        routes=[
            aws.ec2.RouteTableRouteArgs(cidr_block="0.0.0.0/0", gateway_id=internet_gateway.id),
        ],
        tags={"Name": f"{stack}-public-rt"},
        opts=pulumi.ResourceOptions(provider=provider),
    )

    public_subnets: list[aws.ec2.Subnet] = []
    for index, zone_name in enumerate(zone_names):
        subnet = aws.ec2.Subnet(
            f"aws-test-public-subnet-{index}",
            vpc_id=vpc.id,
            cidr_block=f"10.90.{index}.0/24",
            availability_zone=zone_name,
            map_public_ip_on_launch=True,
            tags={"Name": f"{stack}-public-subnet-{index}"},
            opts=pulumi.ResourceOptions(provider=provider),
        )
        aws.ec2.RouteTableAssociation(
            f"aws-test-public-rta-{index}",
            subnet_id=subnet.id,
            route_table_id=route_table.id,
            opts=pulumi.ResourceOptions(provider=provider),
        )
        public_subnets.append(subnet)

    security_group = aws.ec2.SecurityGroup(
        "aws-test-security-group",
        vpc_id=vpc.id,
        description="Security group for the prodbox AWS HA-RKE2 test stack",
        ingress=[
            aws.ec2.SecurityGroupIngressArgs(
                protocol="tcp",
                from_port=22,
                to_port=22,
                cidr_blocks=[operator_cidr],
            ),
            aws.ec2.SecurityGroupIngressArgs(
                protocol="tcp",
                from_port=6443,
                to_port=6443,
                cidr_blocks=[operator_cidr],
            ),
            aws.ec2.SecurityGroupIngressArgs(
                protocol="-1",
                from_port=0,
                to_port=0,
                self=True,
            ),
        ],
        egress=[
            aws.ec2.SecurityGroupEgressArgs(
                protocol="-1",
                from_port=0,
                to_port=0,
                cidr_blocks=["0.0.0.0/0"],
            )
        ],
        tags={"Name": f"{stack}-sg"},
        opts=pulumi.ResourceOptions(provider=provider),
    )

    user_data = "\n".join(
        [
            "#cloud-config",
            "users:",
            "  - default",
            "ssh_authorized_keys:",
            f"  - {public_key}",
            "package_update: true",
            "packages:",
            "  - curl",
            "  - jq",
        ]
    )

    nodes: list[aws.ec2.Instance] = []
    for index, subnet in enumerate(public_subnets):
        instance = aws.ec2.Instance(
            f"aws-test-node-{index}",
            ami=ubuntu_ami.id,
            instance_type=_INSTANCE_TYPE,
            subnet_id=subnet.id,
            vpc_security_group_ids=[security_group.id],
            associate_public_ip_address=True,
            user_data=user_data,
            root_block_device=aws.ec2.InstanceRootBlockDeviceArgs(
                volume_type="gp3",
                volume_size=_ROOT_VOLUME_SIZE_GIB,
                delete_on_termination=True,
            ),
            tags={"Name": f"{stack}-node-{index}"},
            opts=pulumi.ResourceOptions(provider=provider),
        )
        nodes.append(instance)

    pulumi.export("backend_bucket", "prodbox-test-pulumi-backends")
    pulumi.export("vpc_id", vpc.id)
    pulumi.export("subnet_ids", pulumi.Output.all(*[subnet.id for subnet in public_subnets]))
    pulumi.export("security_group_id", security_group.id)
    node_outputs = [
        _build_node_output(
            instance,
            node_name=f"{stack}-node-{index}",
            availability_zone=zone_names[index],
        )
        for index, instance in enumerate(nodes)
    ]
    pulumi.export("nodes", pulumi.Output.all(*node_outputs))


__all__ = ["main"]
