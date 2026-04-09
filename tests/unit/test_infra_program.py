"""Unit tests for Pulumi infra program orchestration."""

from __future__ import annotations

import importlib
import sys
from types import ModuleType
from unittest.mock import MagicMock, patch

import prodbox.infra.cert_manager as cert_manager_module
import prodbox.infra.cluster_issuer as cluster_issuer_module
from prodbox.settings import LanAddressing

_TEST_LAN = LanAddressing(
    interface_name="eno1",
    interface_ipv4="192.168.1.20",
    network_cidr="192.168.1.0/24",
    metallb_pool="192.168.1.240-192.168.1.250",
    ingress_lb_ip="192.168.1.240",
)


def _import_fresh_infra_main() -> ModuleType:
    """Import the Pulumi program entrypoint with a clean module cache."""
    sys.modules.pop("prodbox.infra.__main__", None)
    return importlib.import_module("prodbox.infra.__main__")


def test_deploy_cert_manager_wraps_chart_values_with_prodbox_metadata() -> None:
    """cert-manager deployment should include prodbox labels in podLabels."""
    namespace = MagicMock()
    namespace.metadata.name = "cert-manager"
    release = MagicMock()
    test_labels = {"prodbox.io/managed-by": "prodbox-123"}

    with (
        patch.object(cert_manager_module, "object_meta", return_value={"name": "cert-manager"}),
        patch.object(
            cert_manager_module,
            "prodbox_labels",
            return_value=test_labels,
        ),
        patch.object(cert_manager_module.k8s.core.v1, "Namespace", return_value=namespace),
        patch.object(
            cert_manager_module.k8s.helm.v3,
            "Release",
            return_value=release,
        ) as mock_release,
        patch.object(
            cert_manager_module.k8s.helm.v3,
            "RepositoryOptsArgs",
            side_effect=lambda **kwargs: kwargs,
        ),
        patch.object(
            cert_manager_module.pulumi,
            "ResourceOptions",
            side_effect=lambda **kwargs: kwargs,
        ),
        patch.object(cert_manager_module.pulumi, "export"),
    ):
        result = cert_manager_module.deploy_cert_manager(
            MagicMock(),
            MagicMock(),
            prodbox_id="prodbox-123",
        )

    assert result.namespace is namespace
    assert result.release is release
    release_kwargs = mock_release.call_args.kwargs
    assert release_kwargs["values"]["podLabels"] == test_labels
    assert release_kwargs["values"]["crds"]["enabled"] is True
    assert release_kwargs["opts"]["depends_on"] == [namespace]


def test_deploy_cluster_issuer_passes_explicit_dependencies() -> None:
    """ClusterIssuer deployment should preserve explicit dependency ordering."""
    aws_secret = MagicMock()
    cluster_issuer = MagicMock()
    dep_one = MagicMock()
    dep_two = MagicMock()
    settings = MagicMock(
        acme_server="https://acme-v02.api.letsencrypt.org/directory",
        acme_email="test@example.com",
        aws_access_key_id="AKIATEST",
        aws_secret_access_key="secret",
        aws_region="us-east-1",
        route53_zone_id="ZTEST",
    )

    with (
        patch.object(
            cluster_issuer_module,
            "object_meta",
            return_value={"name": "letsencrypt-http01"},
        ),
        patch.object(
            cluster_issuer_module.k8s.core.v1,
            "Secret",
            return_value=aws_secret,
        ),
        patch.object(
            cluster_issuer_module.k8s.apiextensions,
            "CustomResource",
            return_value=cluster_issuer,
        ) as mock_custom_resource,
        patch.object(
            cluster_issuer_module.pulumi,
            "ResourceOptions",
            side_effect=lambda **kwargs: kwargs,
        ),
        patch.object(cluster_issuer_module.pulumi, "export"),
    ):
        result = cluster_issuer_module.deploy_cluster_issuer(
            settings,
            MagicMock(),
            prodbox_id="prodbox-123",
            depends_on=(dep_one, dep_two),
        )

    assert result.cluster_issuer is cluster_issuer
    deps = mock_custom_resource.call_args.kwargs["opts"]["depends_on"]
    assert deps[0] is aws_secret
    assert dep_one in deps
    assert dep_two in deps


def test_infra_main_enables_dns_bootstrap_and_cert_manager() -> None:
    """Pulumi entrypoint should deploy DNS bootstrap when enabled."""
    settings = MagicMock(
        demo_fqdn="demo.example.com",
        pulumi_enable_dns_bootstrap=True,
    )
    aws_provider = MagicMock()
    k8s_provider = MagicMock()
    metallb_resources = MagicMock()
    ingress_resources = MagicMock(release=MagicMock())
    cert_manager_resources = MagicMock(release=MagicMock())

    with (
        patch("prodbox.settings.Settings.from_config_json", return_value=settings),
        patch("prodbox.settings.discover_lan_addressing", return_value=_TEST_LAN),
        patch("prodbox.infra.metadata.resolve_prodbox_id", return_value="prodbox-123"),
        patch("prodbox.infra.providers.create_k8s_provider", return_value=k8s_provider),
        patch(
            "prodbox.infra.providers.create_aws_provider",
            return_value=aws_provider,
        ) as mock_aws,
        patch("prodbox.infra.dns.deploy_dns", return_value=MagicMock()) as mock_dns,
        patch("prodbox.infra.metallb.deploy_metallb", return_value=metallb_resources),
        patch("prodbox.infra.ingress.deploy_ingress", return_value=ingress_resources),
        patch(
            "prodbox.infra.cert_manager.deploy_cert_manager",
            return_value=cert_manager_resources,
        ) as mock_cert_manager,
        patch(
            "prodbox.infra.cluster_issuer.deploy_cluster_issuer",
            return_value=MagicMock(),
        ) as mock_cluster_issuer,
        patch("pulumi.export") as mock_export,
    ):
        _import_fresh_infra_main()

    mock_aws.assert_called_once_with(settings)
    mock_dns.assert_called_once_with(settings, aws_provider)
    mock_cert_manager.assert_called_once_with(
        settings,
        k8s_provider,
        prodbox_id="prodbox-123",
    )
    assert mock_cluster_issuer.call_args.kwargs["depends_on"] == (
        cert_manager_resources.release,
        ingress_resources.release,
    )
    mock_export.assert_any_call(
        "summary",
        {
            "fqdn": "demo.example.com",
            "ingress_ip": "192.168.1.240",
            "metallb_pool": "192.168.1.240-192.168.1.250",
            "cluster_issuer": "letsencrypt-http01",
            "dns_bootstrap_enabled": True,
            "prodbox_id": "prodbox-123",
        },
    )


def test_infra_main_can_disable_dns_bootstrap() -> None:
    """Pulumi entrypoint should skip Route53 bootstrap when explicitly disabled."""
    settings = MagicMock(
        demo_fqdn="demo.example.com",
        pulumi_enable_dns_bootstrap=False,
    )

    with (
        patch("prodbox.settings.Settings.from_config_json", return_value=settings),
        patch("prodbox.settings.discover_lan_addressing", return_value=_TEST_LAN),
        patch("prodbox.infra.metadata.resolve_prodbox_id", return_value="prodbox-123"),
        patch("prodbox.infra.providers.create_k8s_provider", return_value=MagicMock()),
        patch("prodbox.infra.providers.create_aws_provider") as mock_aws,
        patch("prodbox.infra.dns.deploy_dns") as mock_dns,
        patch("prodbox.infra.metallb.deploy_metallb", return_value=MagicMock()),
        patch(
            "prodbox.infra.ingress.deploy_ingress",
            return_value=MagicMock(release=MagicMock()),
        ),
        patch(
            "prodbox.infra.cert_manager.deploy_cert_manager",
            return_value=MagicMock(release=MagicMock()),
        ),
        patch("prodbox.infra.cluster_issuer.deploy_cluster_issuer", return_value=MagicMock()),
        patch("pulumi.export") as mock_export,
    ):
        _import_fresh_infra_main()

    mock_aws.assert_not_called()
    mock_dns.assert_not_called()
    mock_export.assert_any_call("dns_bootstrap", "disabled")
    mock_export.assert_any_call(
        "summary",
        {
            "fqdn": "demo.example.com",
            "ingress_ip": "192.168.1.240",
            "metallb_pool": "192.168.1.240-192.168.1.250",
            "cluster_issuer": "letsencrypt-http01",
            "dns_bootstrap_enabled": False,
            "prodbox_id": "prodbox-123",
        },
    )
