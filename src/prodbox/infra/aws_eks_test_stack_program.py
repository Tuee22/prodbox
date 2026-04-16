"""Pulumi program for the AWS-backed EKS validation stack."""

from __future__ import annotations

import json
import os

import pulumi
import pulumi_aws as aws

from prodbox.infra.providers import create_aws_provider
from prodbox.settings import Settings

_EKS_NODE_INSTANCE_TYPE: str = "t3.medium"
_EKS_NODE_DISK_SIZE_GIB: int = 20
_EKS_NODE_DESIRED_SIZE: int = 2
_EKS_NODE_MIN_SIZE: int = 2
_EKS_NODE_MAX_SIZE: int = 2


def _required_env(name: str) -> str:
    """Return one required environment variable."""
    value = os.environ.get(name)
    if not isinstance(value, str) or value == "":
        raise ValueError(f"missing required environment variable {name}")
    return value


def _assume_role_policy(*, service: str) -> str:
    """Render the canonical IAM assume-role policy for one AWS service principal."""
    statement: dict[str, object] = {
        "Effect": "Allow",
        "Principal": {"Service": service},
        "Action": "sts:AssumeRole",
    }
    payload: dict[str, object] = {
        "Version": "2012-10-17",
        "Statement": [statement],
    }
    return json.dumps(payload)


def main() -> None:
    """Provision the dedicated AWS EKS test stack used by `aws-eks`."""
    settings = Settings.from_config_json()
    provider = create_aws_provider(settings)
    operator_cidr = _required_env("PRODBOX_AWS_EKS_TEST_OPERATOR_CIDR")
    stack = pulumi.get_stack()

    availability_zones = aws.get_availability_zones(
        state="available",
        opts=pulumi.InvokeOptions(provider=provider),
    )
    zone_names = tuple(availability_zones.names[:2])
    if len(zone_names) != 2:
        raise ValueError("AWS EKS test stack requires at least 2 available availability zones")

    cluster_name = f"{stack}-cluster"
    node_group_name = f"{stack}-node-group"

    vpc = aws.ec2.Vpc(
        "aws-eks-test-vpc",
        cidr_block="10.91.0.0/16",
        enable_dns_hostnames=True,
        enable_dns_support=True,
        tags={"Name": f"{stack}-vpc"},
        opts=pulumi.ResourceOptions(provider=provider),
    )
    internet_gateway = aws.ec2.InternetGateway(
        "aws-eks-test-igw",
        vpc_id=vpc.id,
        tags={"Name": f"{stack}-igw"},
        opts=pulumi.ResourceOptions(provider=provider),
    )
    route_table = aws.ec2.RouteTable(
        "aws-eks-test-public-route-table",
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
            f"aws-eks-test-public-subnet-{index}",
            vpc_id=vpc.id,
            cidr_block=f"10.91.{index}.0/24",
            availability_zone=zone_name,
            map_public_ip_on_launch=True,
            tags={"Name": f"{stack}-public-subnet-{index}"},
            opts=pulumi.ResourceOptions(provider=provider),
        )
        aws.ec2.RouteTableAssociation(
            f"aws-eks-test-public-rta-{index}",
            subnet_id=subnet.id,
            route_table_id=route_table.id,
            opts=pulumi.ResourceOptions(provider=provider),
        )
        public_subnets.append(subnet)

    cluster_role = aws.iam.Role(
        "aws-eks-test-cluster-role",
        assume_role_policy=_assume_role_policy(service="eks.amazonaws.com"),
        tags={"Name": f"{stack}-cluster-role"},
        opts=pulumi.ResourceOptions(provider=provider),
    )
    cluster_role_attachments = [
        aws.iam.RolePolicyAttachment(
            "aws-eks-test-cluster-policy",
            role=cluster_role.name,
            policy_arn="arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
            opts=pulumi.ResourceOptions(provider=provider),
        )
    ]

    node_role = aws.iam.Role(
        "aws-eks-test-node-role",
        assume_role_policy=_assume_role_policy(service="ec2.amazonaws.com"),
        tags={"Name": f"{stack}-node-role"},
        opts=pulumi.ResourceOptions(provider=provider),
    )
    node_role_attachments = [
        aws.iam.RolePolicyAttachment(
            "aws-eks-test-node-policy",
            role=node_role.name,
            policy_arn="arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
            opts=pulumi.ResourceOptions(provider=provider),
        ),
        aws.iam.RolePolicyAttachment(
            "aws-eks-test-cni-policy",
            role=node_role.name,
            policy_arn="arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
            opts=pulumi.ResourceOptions(provider=provider),
        ),
        aws.iam.RolePolicyAttachment(
            "aws-eks-test-ecr-read-policy",
            role=node_role.name,
            policy_arn="arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
            opts=pulumi.ResourceOptions(provider=provider),
        ),
    ]

    cluster = aws.eks.Cluster(
        "aws-eks-test-cluster",
        name=cluster_name,
        role_arn=cluster_role.arn,
        access_config=aws.eks.ClusterAccessConfigArgs(
            authentication_mode="API_AND_CONFIG_MAP",
            bootstrap_cluster_creator_admin_permissions=True,
        ),
        vpc_config=aws.eks.ClusterVpcConfigArgs(
            subnet_ids=[subnet.id for subnet in public_subnets],
            endpoint_private_access=True,
            endpoint_public_access=True,
            public_access_cidrs=[operator_cidr],
        ),
        tags={"Name": cluster_name},
        opts=pulumi.ResourceOptions(provider=provider, depends_on=cluster_role_attachments),
    )

    node_group = aws.eks.NodeGroup(
        "aws-eks-test-node-group",
        cluster_name=cluster.name,
        node_group_name=node_group_name,
        node_role_arn=node_role.arn,
        subnet_ids=[subnet.id for subnet in public_subnets],
        instance_types=[_EKS_NODE_INSTANCE_TYPE],
        disk_size=_EKS_NODE_DISK_SIZE_GIB,
        scaling_config=aws.eks.NodeGroupScalingConfigArgs(
            desired_size=_EKS_NODE_DESIRED_SIZE,
            min_size=_EKS_NODE_MIN_SIZE,
            max_size=_EKS_NODE_MAX_SIZE,
        ),
        tags={"Name": node_group_name},
        opts=pulumi.ResourceOptions(
            provider=provider,
            depends_on=[cluster, *node_role_attachments],
        ),
    )

    pulumi.export("backend_bucket", "prodbox-test-pulumi-backends")
    pulumi.export("cluster_name", cluster.name)
    pulumi.export("cluster_role_name", cluster_role.name)
    pulumi.export("node_group_name", node_group.node_group_name)
    pulumi.export("node_role_name", node_role.name)
    pulumi.export("vpc_id", vpc.id)
    pulumi.export("subnet_ids", pulumi.Output.all(*[subnet.id for subnet in public_subnets]))
    pulumi.export("cluster_security_group_id", cluster.vpc_config.cluster_security_group_id)


__all__ = ["main", "_assume_role_policy"]
