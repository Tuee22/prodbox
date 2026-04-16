"""Unit tests for the AWS EKS test-stack Pulumi program."""

from __future__ import annotations

import json
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import prodbox.infra.aws_eks_test_stack_program as program_module


def test_assume_role_policy_renders_requested_service_principal() -> None:
    """The IAM assume-role policy should target the requested AWS service."""
    payload = json.loads(program_module._assume_role_policy(service="eks.amazonaws.com"))

    assert payload == {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Principal": {"Service": "eks.amazonaws.com"},
                "Action": "sts:AssumeRole",
            }
        ],
    }


def test_main_provisions_two_subnets_and_exports_canonical_identifiers() -> None:
    """The Pulumi program should build the EKS stack in two availability zones."""
    settings = MagicMock()
    provider = MagicMock()
    vpc = MagicMock(id="vpc-123")
    subnet_a = MagicMock(id="subnet-1")
    subnet_b = MagicMock(id="subnet-2")
    cluster_role = MagicMock(name="cluster-role", arn="arn:aws:iam::123:role/cluster-role")
    node_role = MagicMock(name="node-role", arn="arn:aws:iam::123:role/node-role")
    cluster = MagicMock(name="aws-eks-test-cluster")
    cluster.vpc_config.cluster_security_group_id = "sg-123"
    node_group = MagicMock(node_group_name="aws-eks-test-node-group")
    fake_ec2 = SimpleNamespace(
        Vpc=MagicMock(return_value=vpc),
        InternetGateway=MagicMock(return_value=MagicMock()),
        RouteTable=MagicMock(return_value=MagicMock()),
        RouteTableRouteArgs=MagicMock(side_effect=lambda **kwargs: SimpleNamespace(**kwargs)),
        Subnet=MagicMock(side_effect=[subnet_a, subnet_b]),
        RouteTableAssociation=MagicMock(return_value=MagicMock()),
    )
    fake_iam = SimpleNamespace(
        Role=MagicMock(side_effect=[cluster_role, node_role]),
        RolePolicyAttachment=MagicMock(return_value=MagicMock()),
    )
    fake_eks = SimpleNamespace(
        Cluster=MagicMock(return_value=cluster),
        NodeGroup=MagicMock(return_value=node_group),
        ClusterAccessConfigArgs=program_module.aws.eks.ClusterAccessConfigArgs,
        ClusterVpcConfigArgs=program_module.aws.eks.ClusterVpcConfigArgs,
        NodeGroupScalingConfigArgs=program_module.aws.eks.NodeGroupScalingConfigArgs,
    )

    with (
        patch.object(program_module.Settings, "from_config_json", return_value=settings),
        patch.object(program_module, "create_aws_provider", return_value=provider),
        patch.object(
            program_module.aws,
            "get_availability_zones",
            return_value=SimpleNamespace(names=["us-east-1a", "us-east-1b", "us-east-1c"]),
        ),
        patch.object(program_module.aws, "ec2", new=fake_ec2),
        patch.object(program_module.aws, "iam", new=fake_iam),
        patch.object(program_module.aws, "eks", new=fake_eks),
        patch.object(program_module.pulumi, "get_stack", return_value="aws-eks-test"),
        patch.object(
            program_module.pulumi,
            "InvokeOptions",
            side_effect=lambda **kwargs: kwargs,
        ),
        patch.object(
            program_module.pulumi,
            "ResourceOptions",
            side_effect=lambda **kwargs: kwargs,
        ),
        patch.object(
            program_module.pulumi.Output,
            "all",
            side_effect=lambda *args: list(args),
        ),
        patch.object(program_module.pulumi, "export") as mock_export,
        patch.dict(
            program_module.os.environ, {"PRODBOX_AWS_EKS_TEST_OPERATOR_CIDR": "203.0.113.10/32"}
        ),
    ):
        program_module.main()

    assert fake_ec2.Subnet.call_count == 2
    cluster_kwargs = fake_eks.Cluster.call_args.kwargs
    assert cluster_kwargs["name"] == "aws-eks-test-cluster"
    assert cluster_kwargs["vpc_config"].public_access_cidrs == ["203.0.113.10/32"]
    assert cluster_kwargs["vpc_config"].endpoint_private_access is True
    assert cluster_kwargs["vpc_config"].endpoint_public_access is True
    assert cluster_kwargs["access_config"].bootstrap_cluster_creator_admin_permissions is True

    node_group_kwargs = fake_eks.NodeGroup.call_args.kwargs
    assert node_group_kwargs["node_group_name"] == "aws-eks-test-node-group"
    assert node_group_kwargs["instance_types"] == ["t3.medium"]
    assert node_group_kwargs["subnet_ids"] == ["subnet-1", "subnet-2"]

    exported = {call.args[0]: call.args[1] for call in mock_export.call_args_list}
    assert exported["backend_bucket"] == "prodbox-test-pulumi-backends"
    assert exported["cluster_name"] == cluster.name
    assert exported["node_group_name"] == node_group.node_group_name
    assert exported["cluster_role_name"] == cluster_role.name
    assert exported["node_role_name"] == node_role.name
    assert exported["vpc_id"] == vpc.id
    assert exported["subnet_ids"] == ["subnet-1", "subnet-2"]
    assert exported["cluster_security_group_id"] == "sg-123"
