"""Interactive onboarding and elevated AWS helper flows for Phase 7."""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import time
import urllib.parse
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import cast

import click

from prodbox.cli.command_adt import (
    AWSCheckQuotasCommand,
    AWSRequestQuotasCommand,
    AWSSetupCommand,
    AWSTeardownCommand,
    ConfigSetupCommand,
    PolicyTier,
    aws_check_quotas_command,
    aws_request_quotas_command,
    aws_setup_command,
    aws_teardown_command,
    config_setup_command,
)
from prodbox.cli.types import Failure, Result, Success
from prodbox.settings import REPOSITORY_ROOT, validate_config_json

DEFAULT_AWS_REGION: str = "us-east-1"
ZERO_SSL_ACME_SERVER: str = "https://acme.zerossl.com/v2/DV90"
LETS_ENCRYPT_ACME_SERVER: str = "https://acme-v02.api.letsencrypt.org/directory"
PRODBOX_IAM_USER_NAME: str = "prodbox"
PRODBOX_IAM_INLINE_POLICY_NAME: str = "prodbox-inline"
OPERATIONAL_CREDENTIAL_READY_TIMEOUT_SECONDS: float = 60.0
OPERATIONAL_CREDENTIAL_READY_RETRY_INTERVAL_SECONDS: float = 2.0

_AWS_ERROR_CODE_PATTERN: re.Pattern[str] = re.compile(r"An error occurred \(([^)]+)\)")


@dataclass(frozen=True)
class AdminAWSCredentials:
    """Ephemeral elevated AWS credentials used for onboarding and IAM automation."""

    access_key_id: str
    secret_access_key: str
    session_token: str | None
    region: str


@dataclass(frozen=True)
class RegionChoice:
    """One AWS region option returned by `describe-regions`."""

    region_name: str
    opt_in_status: str


@dataclass(frozen=True)
class HostedZoneChoice:
    """One Route 53 hosted-zone option returned by `list-hosted-zones`."""

    zone_id: str
    zone_name: str


@dataclass(frozen=True)
class QuotaSpec:
    """One Service Quotas target owned by prodbox."""

    display_name: str
    service_code: str
    quota_code: str
    target_value: float


@dataclass(frozen=True)
class QuotaStatus:
    """Observed and requested state for one quota."""

    display_name: str
    service_code: str
    quota_code: str
    current_value: float
    target_value: float
    source: str
    meets_target: bool
    request_status: str | None = None
    note: str | None = None


@dataclass(frozen=True)
class IAMSetupResult:
    """Outcome of creating or refreshing the operational IAM user."""

    user_name: str
    policy_tier: PolicyTier
    access_key_id: str
    quota_statuses: tuple[QuotaStatus, ...]
    dhall_path: Path


@dataclass(frozen=True)
class IAMTeardownResult:
    """Outcome of deleting or clearing the operational IAM user."""

    user_name: str
    deleted_access_keys: tuple[str, ...]
    user_deleted: bool
    dhall_path: Path


@dataclass(frozen=True)
class ConfigSetupResult:
    """Outcome of the full interactive config setup wizard."""

    region: str
    route53_zone_id: str
    demo_fqdn: str
    vscode_fqdn: str | None
    policy_tier: PolicyTier
    access_key_id: str
    quota_statuses: tuple[QuotaStatus, ...]
    dhall_path: Path


BASELINE_QUOTA_SPECS: tuple[QuotaSpec, ...] = (
    QuotaSpec(
        display_name="Running On-Demand Standard vCPU",
        service_code="ec2",
        quota_code="L-1216C47A",
        target_value=32.0,
    ),
    QuotaSpec(
        display_name="VPCs per Region",
        service_code="vpc",
        quota_code="L-F678F1CE",
        target_value=10.0,
    ),
    QuotaSpec(
        display_name="Internet gateways per Region",
        service_code="vpc",
        quota_code="L-A4707A72",
        target_value=10.0,
    ),
)

FULL_QUOTA_SPECS: tuple[QuotaSpec, ...] = BASELINE_QUOTA_SPECS + (
    QuotaSpec(
        display_name="Elastic IP addresses",
        service_code="ec2",
        quota_code="L-0263D0A3",
        target_value=10.0,
    ),
    QuotaSpec(
        display_name="Security groups per Region",
        service_code="vpc",
        quota_code="L-E79EC296",
        target_value=300.0,
    ),
    QuotaSpec(
        display_name="Hosted zones per account",
        service_code="route53",
        quota_code="L-4EA4796A",
        target_value=500.0,
    ),
    QuotaSpec(
        display_name="Subnets per VPC",
        service_code="vpc",
        quota_code="L-407747CB",
        target_value=200.0,
    ),
)

CORE_POLICY_STATEMENTS: tuple[dict[str, object], ...] = (
    {
        "Sid": "StsIdentity",
        "Effect": "Allow",
        "Action": ["sts:GetCallerIdentity"],
        "Resource": "*",
    },
    {
        "Sid": "Route53RecordManagement",
        "Effect": "Allow",
        "Action": [
            "route53:ChangeResourceRecordSets",
            "route53:GetHostedZone",
            "route53:ListResourceRecordSets",
        ],
        "Resource": "arn:aws:route53:::hostedzone/*",
    },
    {
        "Sid": "Route53ChangePolling",
        "Effect": "Allow",
        "Action": ["route53:GetChange"],
        "Resource": "arn:aws:route53:::change/*",
    },
)

FULL_POLICY_EXTRA_STATEMENTS: tuple[dict[str, object], ...] = (
    {
        "Sid": "Route53HostedZoneLifecycle",
        "Effect": "Allow",
        "Action": [
            "route53:CreateHostedZone",
            "route53:DeleteHostedZone",
            "route53:ListHostedZones",
        ],
        "Resource": "*",
    },
    {
        "Sid": "Ec2HaTestStackLifecycle",
        "Effect": "Allow",
        "Action": [
            "ec2:AssociateRouteTable",
            "ec2:AttachInternetGateway",
            "ec2:AuthorizeSecurityGroupEgress",
            "ec2:AuthorizeSecurityGroupIngress",
            "ec2:CreateInternetGateway",
            "ec2:CreateRoute",
            "ec2:CreateRouteTable",
            "ec2:CreateSecurityGroup",
            "ec2:CreateSubnet",
            "ec2:CreateTags",
            "ec2:CreateVpc",
            "ec2:DeleteInternetGateway",
            "ec2:DeleteRoute",
            "ec2:DeleteRouteTable",
            "ec2:DeleteSecurityGroup",
            "ec2:DeleteSubnet",
            "ec2:DeleteTags",
            "ec2:DeleteVpc",
            "ec2:Describe*",
            "ec2:DetachInternetGateway",
            "ec2:DisassociateRouteTable",
            "ec2:ModifySubnetAttribute",
            "ec2:ModifyVpcAttribute",
            "ec2:RunInstances",
            "ec2:RevokeSecurityGroupEgress",
            "ec2:RevokeSecurityGroupIngress",
            "ec2:TerminateInstances",
        ],
        "Resource": "*",
    },
    {
        "Sid": "IamEksRoleLifecycle",
        "Effect": "Allow",
        "Action": [
            "iam:AttachRolePolicy",
            "iam:CreateRole",
            "iam:CreateServiceLinkedRole",
            "iam:DeleteRole",
            "iam:DetachRolePolicy",
            "iam:GetRole",
            "iam:GetRolePolicy",
            "iam:ListAttachedRolePolicies",
            "iam:ListInstanceProfilesForRole",
            "iam:ListRolePolicies",
            "iam:ListRoleTags",
            "iam:PassRole",
            "iam:TagRole",
            "iam:UntagRole",
        ],
        "Resource": "*",
    },
    {
        "Sid": "EksTestStackLifecycle",
        "Effect": "Allow",
        "Action": [
            "eks:CreateCluster",
            "eks:CreateNodegroup",
            "eks:DeleteCluster",
            "eks:DeleteNodegroup",
            "eks:Describe*",
            "eks:List*",
            "eks:TagResource",
            "eks:UntagResource",
        ],
        "Resource": "*",
    },
)


def build_iam_policy_document(*, tier: PolicyTier) -> dict[str, object]:
    """Return the supported operational inline-policy document."""
    statements = (
        CORE_POLICY_STATEMENTS
        if tier == "core"
        else CORE_POLICY_STATEMENTS + FULL_POLICY_EXTRA_STATEMENTS
    )
    return {
        "Version": "2012-10-17",
        "Statement": list(statements),
    }


def build_iam_policy_json(*, tier: PolicyTier) -> str:
    """Render the supported operational inline policy as deterministic JSON."""
    return json.dumps(build_iam_policy_document(tier=tier), indent=2) + "\n"


def _subprocess_base_env() -> dict[str, str]:
    """Return a minimal subprocess environment with no ambient AWS credentials."""
    env: dict[str, str] = {
        "PATH": os.environ.get("PATH", ""),
        "HOME": os.environ.get("HOME", ""),
        "LANG": os.environ.get("LANG", "C.UTF-8"),
        "AWS_PAGER": "",
        "AWS_EC2_METADATA_DISABLED": "true",
    }
    term = os.environ.get("TERM")
    if term is not None:
        env["TERM"] = term
    user = os.environ.get("USER")
    if user is not None:
        env["USER"] = user
    return env


def _admin_aws_env(credentials: AdminAWSCredentials) -> dict[str, str]:
    """Build explicit AWS CLI environment from ephemeral admin credentials."""
    env = _subprocess_base_env()
    env["AWS_ACCESS_KEY_ID"] = credentials.access_key_id
    env["AWS_SECRET_ACCESS_KEY"] = credentials.secret_access_key
    env["AWS_REGION"] = credentials.region
    env["AWS_DEFAULT_REGION"] = credentials.region
    if credentials.session_token is not None:
        env["AWS_SESSION_TOKEN"] = credentials.session_token
    return env


def _operational_aws_env(
    *,
    access_key_id: str,
    secret_access_key: str,
    session_token: str | None = None,
    region: str,
) -> dict[str, str]:
    """Build explicit AWS CLI environment from generated operational credentials."""
    env = _subprocess_base_env()
    env["AWS_ACCESS_KEY_ID"] = access_key_id
    env["AWS_SECRET_ACCESS_KEY"] = secret_access_key
    env["AWS_REGION"] = region
    env["AWS_DEFAULT_REGION"] = region
    if session_token is not None:
        env["AWS_SESSION_TOKEN"] = session_token
    return env


def _run_subprocess(
    command: Sequence[str],
    *,
    env: Mapping[str, str],
    cwd: Path | None = None,
    input_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    """Run one subprocess with explicit environment only."""
    return subprocess.run(
        list(command),
        check=False,
        capture_output=True,
        text=True,
        cwd=cwd,
        env=dict(env),
        input=input_text,
    )


def _aws_error_code(stderr_text: str) -> str | None:
    """Extract one AWS error code from CLI stderr text when present."""
    match _AWS_ERROR_CODE_PATTERN.search(stderr_text):
        case re.Match() as match_obj:
            group_value = match_obj.group(1)
            return group_value if isinstance(group_value, str) else None
        case None:
            return None


def _json_loads(text: str) -> object:
    """Parse one JSON payload without leaking `Any`."""
    parsed: object = json.loads(text)
    return parsed


def _require_success(
    completed: subprocess.CompletedProcess[str],
    *,
    command_label: str,
) -> str:
    """Return stdout or raise a runtime error with deterministic detail."""
    if completed.returncode == 0:
        return completed.stdout
    stderr_text = completed.stderr.strip() or completed.stdout.strip() or "command failed"
    raise RuntimeError(f"{command_label} failed: {stderr_text}")


def _run_aws_cli_json(
    credentials: AdminAWSCredentials,
    *args: str,
    command_label: str,
) -> object:
    """Run one AWS CLI command and parse the JSON stdout payload."""
    completed = _run_subprocess(
        ("aws", *args, "--output", "json"),
        env=_admin_aws_env(credentials),
        cwd=REPOSITORY_ROOT,
    )
    stdout_text = _require_success(completed, command_label=command_label)
    return _json_loads(stdout_text)


def _run_aws_cli_json_completed(
    credentials: AdminAWSCredentials,
    *args: str,
) -> subprocess.CompletedProcess[str]:
    """Run one AWS CLI JSON command and return the completed process."""
    return _run_subprocess(
        ("aws", *args, "--output", "json"),
        env=_admin_aws_env(credentials),
        cwd=REPOSITORY_ROOT,
    )


def _mapping_from_object(value: object, *, context: str) -> dict[str, object]:
    """Require a string-keyed mapping parsed from JSON."""
    if not isinstance(value, dict):
        raise RuntimeError(f"{context} must be a JSON object")
    return {str(key): item for key, item in value.items()}


def _list_from_object(value: object, *, context: str) -> list[object]:
    """Require a list parsed from JSON."""
    if not isinstance(value, list):
        raise RuntimeError(f"{context} must be a JSON list")
    return list(value)


def _string_from_mapping(mapping: Mapping[str, object], key: str, *, context: str) -> str:
    """Require one non-empty string value from a mapping."""
    value = mapping.get(key)
    if not isinstance(value, str) or value == "":
        raise RuntimeError(f"{context} missing required string field {key}")
    return value


def _float_from_mapping(mapping: Mapping[str, object], key: str, *, context: str) -> float:
    """Require one numeric field from a mapping and normalize to float."""
    value = mapping.get(key)
    if isinstance(value, int | float):
        return float(value)
    raise RuntimeError(f"{context} missing required numeric field {key}")


def _int_or_default(value: object, *, default: int, context: str) -> int:
    """Normalize an integer-like object or return the provided default."""
    match value:
        case int() as integer_value:
            return integer_value
        case None:
            return default
        case _:
            raise RuntimeError(f"{context} must be an integer")


def _bool_or_default(value: object, *, default: bool, context: str) -> bool:
    """Normalize a bool object or return the provided default."""
    match value:
        case bool() as bool_value:
            return bool_value
        case None:
            return default
        case _:
            raise RuntimeError(f"{context} must be a bool")


def _dhall_escape(value: str) -> str:
    """Escape one string for embedding in a Dhall Text literal."""
    return value.replace("\\", "\\\\").replace('"', '\\"')


def _dhall_text(value: str) -> str:
    """Render one Dhall Text literal."""
    return f'"{_dhall_escape(value)}"'


def _dhall_optional_text(value: str | None) -> str:
    """Render one Dhall Optional Text literal."""
    return "None Text" if value is None else f'Some "{_dhall_escape(value)}"'


def _dhall_bool(value: bool) -> str:
    """Render one Dhall Bool literal."""
    return "True" if value else "False"


def _default_config_mapping() -> dict[str, object]:
    """Return a default configuration mapping aligned with the Dhall schema."""
    return {
        "aws": {
            "access_key_id": "",
            "secret_access_key": "",
            "session_token": None,
            "region": DEFAULT_AWS_REGION,
        },
        "aws_admin": {
            "access_key_id": "",
            "secret_access_key": "",
            "session_token": None,
            "region": "",
        },
        "route53": {"zone_id": ""},
        "domain": {
            "demo_fqdn": "demo.example.com",
            "demo_ttl": 60,
            "vscode_fqdn": None,
        },
        "acme": {
            "email": "",
            "server": LETS_ENCRYPT_ACME_SERVER,
            "eab_key_id": None,
            "eab_hmac_key": None,
        },
        "deployment": {
            "dev_mode": True,
            "bootstrap_public_ip_override": None,
            "pulumi_enable_dns_bootstrap": True,
        },
        "storage": {"manual_pv_host_root": ".data"},
    }


def _load_current_config_mapping() -> dict[str, object]:
    """Load the canonical config mapping without requiring prior validation."""
    dhall_path = REPOSITORY_ROOT / "prodbox-config.dhall"
    json_path = REPOSITORY_ROOT / "prodbox-config.json"
    if dhall_path.exists():
        completed = _run_subprocess(
            ("dhall-to-json",),
            env=_subprocess_base_env(),
            cwd=REPOSITORY_ROOT,
            input_text=dhall_path.read_text(encoding="utf-8"),
        )
        stdout_text = _require_success(completed, command_label="dhall-to-json")
        return _mapping_from_object(_json_loads(stdout_text), context="prodbox-config.dhall")
    if json_path.exists():
        json_text = json_path.read_text(encoding="utf-8")
        return _mapping_from_object(_json_loads(json_text), context="prodbox-config.json")
    return _default_config_mapping()


def _write_dhall_config_mapping(mapping: Mapping[str, object]) -> Path:
    """Write the canonical Dhall config from a nested mapping."""
    aws = _mapping_from_object(mapping.get("aws", {}), context="aws")
    aws_admin = _mapping_from_object(mapping.get("aws_admin", {}), context="aws_admin")
    route53 = _mapping_from_object(mapping.get("route53", {}), context="route53")
    domain = _mapping_from_object(mapping.get("domain", {}), context="domain")
    acme = _mapping_from_object(mapping.get("acme", {}), context="acme")
    deployment = _mapping_from_object(mapping.get("deployment", {}), context="deployment")
    storage = _mapping_from_object(mapping.get("storage", {}), context="storage")

    lines = (
        "let Config = ./prodbox-config-types.dhall",
        "",
        "in  Config::{",
        "    , aws = Config.default.aws // {",
        f"        , access_key_id = {_dhall_text(str(aws.get('access_key_id', '')))}",
        f"        , secret_access_key = {_dhall_text(str(aws.get('secret_access_key', '')))}",
        f"        , session_token = {_dhall_optional_text(_optional_text_value(aws.get('session_token')))}",
        f"        , region = {_dhall_text(str(aws.get('region', DEFAULT_AWS_REGION)))}",
        "        }",
        "    , aws_admin = Config.default.aws_admin // {",
        f"        , access_key_id = {_dhall_text(str(aws_admin.get('access_key_id', '')))}",
        f"        , secret_access_key = {_dhall_text(str(aws_admin.get('secret_access_key', '')))}",
        f"        , session_token = {_dhall_optional_text(_optional_text_value(aws_admin.get('session_token')))}",
        f"        , region = {_dhall_text(str(aws_admin.get('region', '')))}",
        "        }",
        f"    , route53 = {{ zone_id = {_dhall_text(str(route53.get('zone_id', '')))} }}",
        "    , domain = Config.default.domain // {",
        f"        , demo_fqdn = {_dhall_text(str(domain.get('demo_fqdn', 'demo.example.com')))}",
        f"        , demo_ttl = {_int_or_default(domain.get('demo_ttl'), default=60, context='domain.demo_ttl')}",
        f"        , vscode_fqdn = {_dhall_optional_text(_optional_text_value(domain.get('vscode_fqdn')))}",
        "        }",
        "    , acme = Config.default.acme // {",
        f"        , email = {_dhall_text(str(acme.get('email', '')))}",
        f"        , server = {_dhall_text(str(acme.get('server', LETS_ENCRYPT_ACME_SERVER)))}",
        f"        , eab_key_id = {_dhall_optional_text(_optional_text_value(acme.get('eab_key_id')))}",
        f"        , eab_hmac_key = {_dhall_optional_text(_optional_text_value(acme.get('eab_hmac_key')))}",
        "        }",
        "    , deployment = Config.default.deployment // {",
        f"        , dev_mode = {_dhall_bool(_bool_or_default(deployment.get('dev_mode'), default=True, context='deployment.dev_mode'))}",
        f"        , bootstrap_public_ip_override = {_dhall_optional_text(_optional_text_value(deployment.get('bootstrap_public_ip_override')))}",
        f"        , pulumi_enable_dns_bootstrap = {_dhall_bool(_bool_or_default(deployment.get('pulumi_enable_dns_bootstrap'), default=True, context='deployment.pulumi_enable_dns_bootstrap'))}",
        "        }",
        "    , storage = Config.default.storage // {",
        f"        , manual_pv_host_root = {_dhall_text(str(storage.get('manual_pv_host_root', '.data')))}",
        "        }",
        "    }",
        "",
    )
    dhall_path = REPOSITORY_ROOT / "prodbox-config.dhall"
    dhall_path.write_text("\n".join(lines), encoding="utf-8")
    return dhall_path


def _optional_text_value(value: object) -> str | None:
    """Normalize blank-ish text-like values to `None`."""
    return value if isinstance(value, str) and value != "" else None


def _compile_dhall_to_json() -> Path:
    """Compile the canonical Dhall config to JSON and return the JSON path."""
    dhall_path = REPOSITORY_ROOT / "prodbox-config.dhall"
    json_path = REPOSITORY_ROOT / "prodbox-config.json"
    completed = _run_subprocess(
        ("dhall-to-json",),
        env=_subprocess_base_env(),
        cwd=REPOSITORY_ROOT,
        input_text=dhall_path.read_text(encoding="utf-8"),
    )
    stdout_text = _require_success(completed, command_label="dhall-to-json")
    json_path.write_text(stdout_text, encoding="utf-8")
    return json_path


def _compile_and_validate_config() -> Path:
    """Compile the canonical Dhall config and validate the JSON payload."""
    json_path = _compile_dhall_to_json()
    validate_config_json(json_path)
    return json_path


def _current_region_default() -> str:
    """Return the configured operational AWS region or the canonical default."""
    config = _load_current_config_mapping()
    aws = _mapping_from_object(config.get("aws", {}), context="aws")
    region = aws.get("region")
    if isinstance(region, str) and region != "":
        return region
    return DEFAULT_AWS_REGION


def _with_operational_credentials(
    config: dict[str, object],
    *,
    access_key_id: str,
    secret_access_key: str,
    session_token: str | None,
    region: str,
) -> dict[str, object]:
    """Return a config mapping with the operational AWS credential section replaced."""
    updated = dict(config)
    updated["aws"] = {
        "access_key_id": access_key_id,
        "secret_access_key": secret_access_key,
        "session_token": session_token,
        "region": region,
    }
    return updated


def _ensure_service_quota(
    credentials: AdminAWSCredentials,
    spec: QuotaSpec,
    *,
    request_if_needed: bool,
) -> QuotaStatus:
    """Inspect one quota and optionally submit a quota increase request."""
    primary = _run_aws_cli_json_completed(
        credentials,
        "service-quotas",
        "get-service-quota",
        "--service-code",
        spec.service_code,
        "--quota-code",
        spec.quota_code,
    )
    source = "current"
    quota_payload: dict[str, object]
    if primary.returncode == 0:
        parsed = _json_loads(primary.stdout)
        quota_payload = _mapping_from_object(parsed, context=spec.display_name)
    else:
        fallback = _run_aws_cli_json_completed(
            credentials,
            "service-quotas",
            "get-aws-default-service-quota",
            "--service-code",
            spec.service_code,
            "--quota-code",
            spec.quota_code,
        )
        parsed = _json_loads(_require_success(fallback, command_label=spec.display_name))
        quota_payload = _mapping_from_object(parsed, context=spec.display_name)
        source = "default"
    quota_mapping = _mapping_from_object(quota_payload.get("Quota"), context=spec.display_name)
    current_value = _float_from_mapping(quota_mapping, "Value", context=spec.display_name)
    meets_target = current_value >= spec.target_value
    if meets_target or not request_if_needed:
        return QuotaStatus(
            display_name=spec.display_name,
            service_code=spec.service_code,
            quota_code=spec.quota_code,
            current_value=current_value,
            target_value=spec.target_value,
            source=source,
            meets_target=meets_target,
        )
    request_completed = _run_aws_cli_json_completed(
        credentials,
        "service-quotas",
        "request-service-quota-increase",
        "--service-code",
        spec.service_code,
        "--quota-code",
        spec.quota_code,
        "--desired-value",
        str(spec.target_value),
    )
    if request_completed.returncode != 0:
        stderr_text = request_completed.stderr.strip() or request_completed.stdout.strip()
        return QuotaStatus(
            display_name=spec.display_name,
            service_code=spec.service_code,
            quota_code=spec.quota_code,
            current_value=current_value,
            target_value=spec.target_value,
            source=source,
            meets_target=False,
            request_status="error",
            note=stderr_text,
        )
    request_parsed = _json_loads(request_completed.stdout)
    request_payload = _mapping_from_object(request_parsed, context=spec.display_name)
    requested_quota = _mapping_from_object(
        request_payload.get("RequestedQuota"), context=spec.display_name
    )
    status = _string_from_mapping(requested_quota, "Status", context=spec.display_name)
    return QuotaStatus(
        display_name=spec.display_name,
        service_code=spec.service_code,
        quota_code=spec.quota_code,
        current_value=current_value,
        target_value=spec.target_value,
        source=source,
        meets_target=False,
        request_status=status,
    )


def _quota_specs_for_tier(tier: PolicyTier) -> tuple[QuotaSpec, ...]:
    """Return the supported quota set for one tier."""
    return BASELINE_QUOTA_SPECS if tier == "core" else FULL_QUOTA_SPECS


def _list_aws_regions(credentials: AdminAWSCredentials) -> tuple[RegionChoice, ...]:
    """Return the live AWS region list from the EC2 API."""
    payload = _run_aws_cli_json(
        credentials,
        "ec2",
        "describe-regions",
        command_label="aws ec2 describe-regions",
    )
    parsed = _mapping_from_object(payload, context="describe-regions")
    regions = _list_from_object(parsed.get("Regions"), context="Regions")
    return tuple(
        RegionChoice(
            region_name=_string_from_mapping(mapping, "RegionName", context="describe-regions"),
            opt_in_status=str(mapping.get("OptInStatus", "opt-in-not-required")),
        )
        for item in regions
        for mapping in (_mapping_from_object(item, context="describe-regions"),)
    )


def _list_hosted_zones(credentials: AdminAWSCredentials) -> tuple[HostedZoneChoice, ...]:
    """Return the live Route 53 hosted-zone list."""
    payload = _run_aws_cli_json(
        credentials,
        "route53",
        "list-hosted-zones",
        command_label="aws route53 list-hosted-zones",
    )
    parsed = _mapping_from_object(payload, context="list-hosted-zones")
    zones = _list_from_object(parsed.get("HostedZones"), context="HostedZones")
    return tuple(
        HostedZoneChoice(
            zone_id=_string_from_mapping(mapping, "Id", context="list-hosted-zones").removeprefix(
                "/hostedzone/"
            ),
            zone_name=_string_from_mapping(mapping, "Name", context="list-hosted-zones").rstrip(
                "."
            ),
        )
        for item in zones
        for mapping in (_mapping_from_object(item, context="list-hosted-zones"),)
    )


def _ensure_operational_iam_user(
    credentials: AdminAWSCredentials,
    *,
    policy_tier: PolicyTier,
) -> tuple[str, str, tuple[QuotaStatus, ...]]:
    """Create or refresh the canonical operational IAM user and baseline quotas."""
    create_user = _run_aws_cli_json_completed(
        credentials,
        "iam",
        "create-user",
        "--user-name",
        PRODBOX_IAM_USER_NAME,
    )
    if create_user.returncode != 0:
        stderr_text = create_user.stderr.strip() or create_user.stdout.strip()
        if _aws_error_code(stderr_text) != "EntityAlreadyExists":
            raise RuntimeError(f"aws iam create-user failed: {stderr_text}")
    list_keys = _run_aws_cli_json_completed(
        credentials,
        "iam",
        "list-access-keys",
        "--user-name",
        PRODBOX_IAM_USER_NAME,
    )
    list_payload = _json_loads(
        _require_success(list_keys, command_label="aws iam list-access-keys")
    )
    list_mapping = _mapping_from_object(list_payload, context="list-access-keys")
    access_keys = _list_from_object(
        list_mapping.get("AccessKeyMetadata"), context="AccessKeyMetadata"
    )
    for item in access_keys:
        metadata = _mapping_from_object(item, context="AccessKeyMetadata")
        access_key_id = _string_from_mapping(metadata, "AccessKeyId", context="AccessKeyMetadata")
        delete_key = _run_aws_cli_json_completed(
            credentials,
            "iam",
            "delete-access-key",
            "--user-name",
            PRODBOX_IAM_USER_NAME,
            "--access-key-id",
            access_key_id,
        )
        _require_success(delete_key, command_label=f"aws iam delete-access-key {access_key_id}")

    put_policy = _run_aws_cli_json_completed(
        credentials,
        "iam",
        "put-user-policy",
        "--user-name",
        PRODBOX_IAM_USER_NAME,
        "--policy-name",
        PRODBOX_IAM_INLINE_POLICY_NAME,
        "--policy-document",
        build_iam_policy_json(tier=policy_tier),
    )
    _require_success(put_policy, command_label="aws iam put-user-policy")

    create_key = _run_aws_cli_json_completed(
        credentials,
        "iam",
        "create-access-key",
        "--user-name",
        PRODBOX_IAM_USER_NAME,
    )
    create_key_payload = _json_loads(
        _require_success(create_key, command_label="aws iam create-access-key")
    )
    create_key_mapping = _mapping_from_object(create_key_payload, context="create-access-key")
    access_key = _mapping_from_object(create_key_mapping.get("AccessKey"), context="AccessKey")
    new_access_key_id = _string_from_mapping(access_key, "AccessKeyId", context="AccessKey")
    new_secret_key = _string_from_mapping(access_key, "SecretAccessKey", context="AccessKey")
    quota_statuses = tuple(
        _ensure_service_quota(credentials, spec, request_if_needed=True)
        for spec in BASELINE_QUOTA_SPECS
    )
    return new_access_key_id, new_secret_key, quota_statuses


def _wait_for_operational_credentials_ready(
    *,
    access_key_id: str,
    secret_access_key: str,
    region: str,
) -> None:
    """Wait until the generated operational key succeeds against STS."""
    env = _operational_aws_env(
        access_key_id=access_key_id,
        secret_access_key=secret_access_key,
        region=region,
    )
    deadline = time.monotonic() + OPERATIONAL_CREDENTIAL_READY_TIMEOUT_SECONDS
    last_error = "STS validation did not return a result"
    while True:
        completed = _run_subprocess(
            ("aws", "sts", "get-caller-identity", "--output", "json"),
            env=env,
        )
        if completed.returncode == 0:
            return
        stderr_text = completed.stderr.strip() or completed.stdout.strip()
        if stderr_text != "":
            last_error = stderr_text
        if time.monotonic() >= deadline:
            raise RuntimeError(
                "Generated operational AWS credentials failed validation via "
                f"`aws sts get-caller-identity`: {last_error}"
            )
        time.sleep(OPERATIONAL_CREDENTIAL_READY_RETRY_INTERVAL_SECONDS)


def _admin_credentials_from_current_config() -> AdminAWSCredentials:
    """Load elevated AWS credentials from the raw repository-root config mapping."""
    config = _load_current_config_mapping()
    aws_admin = _mapping_from_object(config.get("aws_admin", {}), context="aws_admin")
    return AdminAWSCredentials(
        access_key_id=_string_from_mapping(aws_admin, "access_key_id", context="aws_admin"),
        secret_access_key=_string_from_mapping(aws_admin, "secret_access_key", context="aws_admin"),
        session_token=_optional_text_value(aws_admin.get("session_token")),
        region=_string_from_mapping(aws_admin, "region", context="aws_admin"),
    )


def operational_aws_credentials_are_valid() -> bool:
    """Return whether the current operational AWS credentials succeed against STS."""
    from prodbox.settings import Settings, clear_settings_cache

    try:
        clear_settings_cache()
        settings = Settings.from_config_json()
    except Exception:
        return False

    completed = _run_subprocess(
        ("aws", "sts", "get-caller-identity", "--output", "json"),
        env=_operational_aws_env(
            access_key_id=settings.aws_access_key_id,
            secret_access_key=settings.aws_secret_access_key,
            session_token=settings.aws_session_token,
            region=settings.aws_region,
        ),
        cwd=REPOSITORY_ROOT,
    )
    return completed.returncode == 0


def operational_aws_policy_is_current() -> bool:
    """Return whether the supported operational IAM inline policy is already installed."""
    try:
        credentials = _admin_credentials_from_current_config()
    except RuntimeError:
        return True

    completed = _run_aws_cli_json_completed(
        credentials,
        "iam",
        "get-user-policy",
        "--user-name",
        PRODBOX_IAM_USER_NAME,
        "--policy-name",
        PRODBOX_IAM_INLINE_POLICY_NAME,
    )
    if completed.returncode != 0:
        stderr_text = completed.stderr.strip() or completed.stdout.strip()
        if "NoSuchEntity" in stderr_text:
            return False
        raise RuntimeError(f"aws iam get-user-policy failed: {stderr_text}")

    payload = _mapping_from_object(_json_loads(completed.stdout), context="get-user-policy")
    policy_document = payload.get("PolicyDocument")
    match policy_document:
        case dict() as document_mapping:
            current_policy = _mapping_from_object(document_mapping, context="PolicyDocument")
        case str() as encoded_document:
            current_policy = _mapping_from_object(
                _json_loads(urllib.parse.unquote(encoded_document)),
                context="PolicyDocument",
            )
        case _:
            raise RuntimeError("aws iam get-user-policy returned an unexpected PolicyDocument")
    return current_policy == build_iam_policy_document(tier="full")


def restore_operational_aws_identity_from_admin_harness() -> str:
    """Recreate the canonical operational IAM user from raw-config `aws_admin` credentials."""
    from prodbox.settings import Settings, clear_settings_cache

    clear_settings_cache()
    try:
        credentials = _admin_credentials_from_current_config()
    except RuntimeError as error:
        raise RuntimeError(
            "Operational AWS credentials are unavailable and the repository-root aws_admin "
            "config is incomplete. Populate aws_admin.access_key_id, "
            "aws_admin.secret_access_key, and aws_admin.region to allow automatic recovery. "
            f"Detail: {error}"
        ) from error

    match aws_setup_command(
        admin_access_key_id=credentials.access_key_id,
        admin_secret_access_key=credentials.secret_access_key,
        admin_session_token=credentials.session_token,
        admin_region=credentials.region,
        tier="full",
    ):
        case Failure(error=command_error):
            raise RuntimeError(
                f"failed to construct operational AWS restore command: {command_error}"
            )
        case Success(command):
            result = run_aws_setup(command)

    clear_settings_cache()
    Settings.from_config_json()
    return (
        "Restored operational AWS IAM user "
        f"{result.user_name} with {result.policy_tier} policy tier"
    )


def ensure_operational_aws_credentials_from_admin_harness() -> str:
    """Repair operational AWS credentials or stale policy from the `aws_admin` harness."""
    if operational_aws_credentials_are_valid() and operational_aws_policy_is_current():
        return "Operational AWS credentials and IAM policy already valid"
    return restore_operational_aws_identity_from_admin_harness()


def run_aws_setup(command: AWSSetupCommand) -> IAMSetupResult:
    """Create or refresh the supported operational IAM user and injected credentials."""
    credentials = AdminAWSCredentials(
        access_key_id=command.admin_access_key_id,
        secret_access_key=command.admin_secret_access_key,
        session_token=command.admin_session_token,
        region=command.admin_region,
    )
    access_key_id, secret_access_key, quota_statuses = _ensure_operational_iam_user(
        credentials,
        policy_tier=command.tier,
    )
    _wait_for_operational_credentials_ready(
        access_key_id=access_key_id,
        secret_access_key=secret_access_key,
        region=command.admin_region,
    )
    config = _load_current_config_mapping()
    updated = _with_operational_credentials(
        config,
        access_key_id=access_key_id,
        secret_access_key=secret_access_key,
        session_token=None,
        region=command.admin_region,
    )
    dhall_path = _write_dhall_config_mapping(updated)
    try:
        _compile_and_validate_config()
    except Exception as error:
        raise RuntimeError(
            "Operational IAM user was created, but the updated config did not validate. "
            "Complete the remaining config fields with `prodbox config setup` and rerun. "
            f"Detail: {error}"
        ) from error
    return IAMSetupResult(
        user_name=PRODBOX_IAM_USER_NAME,
        policy_tier=command.tier,
        access_key_id=access_key_id,
        quota_statuses=quota_statuses,
        dhall_path=dhall_path,
    )


def run_aws_teardown(command: AWSTeardownCommand) -> IAMTeardownResult:
    """Delete the supported operational IAM user and clear the Dhall credential section."""
    credentials = AdminAWSCredentials(
        access_key_id=command.admin_access_key_id,
        secret_access_key=command.admin_secret_access_key,
        session_token=command.admin_session_token,
        region=command.admin_region,
    )
    deleted_access_keys: list[str] = []
    list_keys = _run_aws_cli_json_completed(
        credentials,
        "iam",
        "list-access-keys",
        "--user-name",
        PRODBOX_IAM_USER_NAME,
    )
    list_stderr = list_keys.stderr.strip() or list_keys.stdout.strip()
    if list_keys.returncode == 0:
        payload = _json_loads(list_keys.stdout)
        mapping = _mapping_from_object(payload, context="list-access-keys")
        access_keys = _list_from_object(
            mapping.get("AccessKeyMetadata"), context="AccessKeyMetadata"
        )
        for item in access_keys:
            metadata = _mapping_from_object(item, context="AccessKeyMetadata")
            access_key_id = _string_from_mapping(
                metadata, "AccessKeyId", context="AccessKeyMetadata"
            )
            delete_key = _run_aws_cli_json_completed(
                credentials,
                "iam",
                "delete-access-key",
                "--user-name",
                PRODBOX_IAM_USER_NAME,
                "--access-key-id",
                access_key_id,
            )
            _require_success(delete_key, command_label=f"aws iam delete-access-key {access_key_id}")
            deleted_access_keys.append(access_key_id)
    elif _aws_error_code(list_stderr) != "NoSuchEntity":
        raise RuntimeError(f"aws iam list-access-keys failed: {list_stderr}")

    delete_policy = _run_aws_cli_json_completed(
        credentials,
        "iam",
        "delete-user-policy",
        "--user-name",
        PRODBOX_IAM_USER_NAME,
        "--policy-name",
        PRODBOX_IAM_INLINE_POLICY_NAME,
    )
    delete_policy_stderr = delete_policy.stderr.strip() or delete_policy.stdout.strip()
    if delete_policy.returncode != 0 and _aws_error_code(delete_policy_stderr) != "NoSuchEntity":
        raise RuntimeError(f"aws iam delete-user-policy failed: {delete_policy_stderr}")

    delete_user = _run_aws_cli_json_completed(
        credentials,
        "iam",
        "delete-user",
        "--user-name",
        PRODBOX_IAM_USER_NAME,
    )
    delete_user_stderr = delete_user.stderr.strip() or delete_user.stdout.strip()
    user_deleted = delete_user.returncode == 0
    if delete_user.returncode != 0 and _aws_error_code(delete_user_stderr) != "NoSuchEntity":
        raise RuntimeError(f"aws iam delete-user failed: {delete_user_stderr}")

    config = _load_current_config_mapping()
    current_region = command.admin_region
    current_aws = _mapping_from_object(config.get("aws", {}), context="aws")
    existing_region = current_aws.get("region")
    if isinstance(existing_region, str) and existing_region != "":
        current_region = existing_region
    updated = _with_operational_credentials(
        config,
        access_key_id="",
        secret_access_key="",
        session_token=None,
        region=current_region,
    )
    dhall_path = _write_dhall_config_mapping(updated)
    _compile_dhall_to_json()
    return IAMTeardownResult(
        user_name=PRODBOX_IAM_USER_NAME,
        deleted_access_keys=tuple(deleted_access_keys),
        user_deleted=user_deleted,
        dhall_path=dhall_path,
    )


def run_aws_check_quotas(command: AWSCheckQuotasCommand) -> tuple[QuotaStatus, ...]:
    """Inspect all supported service quotas without requesting changes."""
    credentials = AdminAWSCredentials(
        access_key_id=command.admin_access_key_id,
        secret_access_key=command.admin_secret_access_key,
        session_token=command.admin_session_token,
        region=command.admin_region,
    )
    return tuple(
        _ensure_service_quota(credentials, spec, request_if_needed=False)
        for spec in FULL_QUOTA_SPECS
    )


def run_aws_request_quotas(command: AWSRequestQuotasCommand) -> tuple[QuotaStatus, ...]:
    """Request supported service quota increases where current values are too low."""
    credentials = AdminAWSCredentials(
        access_key_id=command.admin_access_key_id,
        secret_access_key=command.admin_secret_access_key,
        session_token=command.admin_session_token,
        region=command.admin_region,
    )
    return tuple(
        _ensure_service_quota(credentials, spec, request_if_needed=True)
        for spec in _quota_specs_for_tier(command.tier)
    )


def run_config_setup(command: ConfigSetupCommand) -> ConfigSetupResult:
    """Generate a complete Dhall config and operational IAM user from wizard inputs."""
    credentials = AdminAWSCredentials(
        access_key_id=command.admin_access_key_id,
        secret_access_key=command.admin_secret_access_key,
        session_token=command.admin_session_token,
        region=command.admin_region,
    )
    access_key_id, secret_access_key, quota_statuses = _ensure_operational_iam_user(
        credentials,
        policy_tier=command.policy_tier,
    )
    _wait_for_operational_credentials_ready(
        access_key_id=access_key_id,
        secret_access_key=secret_access_key,
        region=command.admin_region,
    )
    current = _load_current_config_mapping()
    updated = dict(current)
    updated["aws"] = {
        "access_key_id": access_key_id,
        "secret_access_key": secret_access_key,
        "session_token": None,
        "region": command.admin_region,
    }
    updated["route53"] = {"zone_id": command.route53_zone_id}
    updated["domain"] = {
        "demo_fqdn": command.demo_fqdn,
        "demo_ttl": command.demo_ttl,
        "vscode_fqdn": command.vscode_fqdn,
    }
    updated["acme"] = {
        "email": command.acme_email,
        "server": command.acme_server,
        "eab_key_id": command.acme_eab_key_id,
        "eab_hmac_key": command.acme_eab_hmac_key,
    }
    updated["deployment"] = {
        "dev_mode": command.prodbox_dev_mode,
        "bootstrap_public_ip_override": command.bootstrap_public_ip_override,
        "pulumi_enable_dns_bootstrap": command.pulumi_enable_dns_bootstrap,
    }
    updated["storage"] = {
        "manual_pv_host_root": str(command.manual_pv_host_root),
    }
    if "aws_admin" not in updated:
        updated["aws_admin"] = _default_config_mapping()["aws_admin"]
    dhall_path = _write_dhall_config_mapping(updated)
    _compile_and_validate_config()
    return ConfigSetupResult(
        region=command.admin_region,
        route53_zone_id=command.route53_zone_id,
        demo_fqdn=command.demo_fqdn,
        vscode_fqdn=command.vscode_fqdn,
        policy_tier=command.policy_tier,
        access_key_id=access_key_id,
        quota_statuses=quota_statuses,
        dhall_path=dhall_path,
    )


def render_aws_setup_result(result: object) -> str:
    """Render a deterministic user-facing summary for `prodbox aws setup`."""
    if not isinstance(result, IAMSetupResult):
        raise RuntimeError("AWS setup result had an unexpected type")
    quota_requests = tuple(
        status for status in result.quota_statuses if status.request_status not in (None, "")
    )
    quota_line = (
        f"QUOTA_REQUESTS_SUBMITTED={len(quota_requests)}"
        if quota_requests
        else "QUOTA_REQUESTS_SUBMITTED=0"
    )
    return (
        f"IAM_USER={result.user_name}\n"
        f"POLICY_TIER={result.policy_tier}\n"
        f"AWS_ACCESS_KEY_ID={result.access_key_id}\n"
        f"CONFIG_PATH={result.dhall_path}\n"
        f"{quota_line}\n"
    )


def render_aws_teardown_result(result: object) -> str:
    """Render a deterministic user-facing summary for `prodbox aws teardown`."""
    if not isinstance(result, IAMTeardownResult):
        raise RuntimeError("AWS teardown result had an unexpected type")
    return (
        f"IAM_USER={result.user_name}\n"
        f"USER_DELETED={'true' if result.user_deleted else 'false'}\n"
        f"DELETED_ACCESS_KEYS={len(result.deleted_access_keys)}\n"
        f"CONFIG_PATH={result.dhall_path}\n"
    )


def render_config_setup_result(result: object) -> str:
    """Render a deterministic user-facing summary for `prodbox config setup`."""
    if not isinstance(result, ConfigSetupResult):
        raise RuntimeError("Config setup result had an unexpected type")
    quota_requests = tuple(
        status for status in result.quota_statuses if status.request_status not in (None, "")
    )
    return (
        f"AWS_REGION={result.region}\n"
        f"ROUTE53_ZONE_ID={result.route53_zone_id}\n"
        f"DEMO_FQDN={result.demo_fqdn}\n"
        f"VSCODE_FQDN={result.vscode_fqdn or ''}\n"
        f"POLICY_TIER={result.policy_tier}\n"
        f"AWS_ACCESS_KEY_ID={result.access_key_id}\n"
        f"CONFIG_PATH={result.dhall_path}\n"
        f"QUOTA_REQUESTS_SUBMITTED={len(quota_requests)}\n"
        "POST_SETUP_GUIDANCE=Delete the temporary elevated/root access key you used for setup; "
        "prodbox now owns a dedicated IAM user for normal operations.\n"
    )


def quota_status_rows(statuses: object) -> tuple[tuple[str, ...], ...]:
    """Render quota records into Rich-table row tuples."""
    if not isinstance(statuses, tuple) or not all(
        isinstance(item, QuotaStatus) for item in statuses
    ):
        raise RuntimeError("Quota status payload had an unexpected type")
    typed_statuses: tuple[QuotaStatus, ...] = statuses
    return tuple(
        (
            status.display_name,
            f"{status.current_value:g}",
            f"{status.target_value:g}",
            "yes" if status.meets_target else "no",
            status.request_status or "",
            status.note or "",
        )
        for status in typed_statuses
    )


def _show_aws_account_guidance() -> None:
    """Print the canonical AWS account creation guidance."""
    click.echo("AWS account guidance:")
    click.echo("1. Sign up at https://aws.amazon.com and choose the Free Tier.")
    click.echo("2. Add a payment method; AWS requires it even for Free Tier usage.")
    click.echo("3. Complete identity verification and keep the Basic (free) support plan.")
    click.echo("4. Create one temporary elevated access key from IAM or root security credentials.")
    click.echo("5. Use that key only for onboarding, then delete it after `prodbox config setup`.")
    click.echo("Free Tier notes: 750 hours/month of t2.micro or t3.micro for 12 months,")
    click.echo("5 GiB of S3 standard storage, and Route 53 usage billed separately.")
    click.echo("")


def _show_admin_credentials_guidance() -> None:
    """Explain how to obtain one temporary elevated AWS credential set."""
    click.echo("Temporary elevated AWS credential guidance:")
    click.echo(
        "1. Sign in to the AWS console with an identity that can manage IAM users, access keys,"
    )
    click.echo("   Route 53 hosted zones, and Service Quotas.")
    click.echo(
        "2. Preferred path: IAM -> Users -> <temporary admin user> -> Security credentials ->"
    )
    click.echo("   Create access key.")
    click.echo("3. Root fallback only when intentional: account menu -> Security credentials ->")
    click.echo("   Access keys -> Create access key.")
    click.echo("4. Paste the access key ID and secret below. If AWS gave you temporary STS")
    click.echo("   credentials, also paste the session token; otherwise leave it blank.")
    click.echo("5. `prodbox` never persists this elevated key. Delete it in the AWS console after")
    click.echo("   the command completes.")
    click.echo("")


def _show_region_choice_guidance() -> None:
    """Explain what the region selection controls."""
    click.echo("AWS region guidance:")
    click.echo("Choose the region that should own EC2-based validation and quota targets.")
    click.echo("Route 53 hosted zones are selected separately in the next step.")
    click.echo("")


def _show_hosted_zone_choice_guidance() -> None:
    """Explain how to choose the canonical public hosted zone."""
    click.echo("Route 53 hosted zone guidance:")
    click.echo("Choose the public hosted zone that should own the demo and vscode records.")
    click.echo("If the desired zone is missing, open AWS console -> Route 53 -> Hosted zones,")
    click.echo("create or delegate the zone, then rerun this command.")
    click.echo("")


def _show_acme_provider_guidance() -> None:
    """Explain the supported ACME provider options."""
    click.echo("ACME provider guidance:")
    click.echo("1. ZeroSSL (recommended): open https://app.zerossl.com -> Developer -> EAB")
    click.echo("   Credentials, then copy the EAB Key ID and HMAC key.")
    click.echo("2. Let's Encrypt: no account or EAB credentials are required; you only need")
    click.echo("   the notification email below.")
    click.echo("")


def _show_policy_tier_guidance() -> None:
    """Explain the supported operational IAM policy tiers."""
    click.echo("Operational IAM policy tier guidance:")
    click.echo(
        "1. full (recommended): Route 53, EC2 HA validation, and quota-management permissions."
    )
    click.echo("2. core: Route 53 runtime permissions only.")
    click.echo("")


def _prompt_text(
    message: str,
    *,
    default: str | None = None,
    show_default: bool = True,
    hide_input: bool = False,
) -> str:
    """Prompt for text and return a typed string."""
    raw_value = cast(
        str,
        click.prompt(
            message,
            default=default,
            show_default=show_default,
            hide_input=hide_input,
            type=str,
        ),
    )
    return raw_value


def _prompt_int(message: str, *, default: int) -> int:
    """Prompt for an integer and return a typed value."""
    raw_value = cast(int, click.prompt(message, default=default, type=int))
    return raw_value


def _confirm(message: str, *, default: bool) -> bool:
    """Prompt for a boolean confirmation."""
    return click.confirm(message, default=default)


def _prompt_numbered_choice(
    *,
    prompt_text: str,
    options: tuple[str, ...],
    default_index: int,
) -> int:
    """Prompt for one numbered choice until the user selects a valid index."""
    while True:
        raw_choice = _prompt_text(
            prompt_text,
            default=str(default_index + 1),
            show_default=True,
        )
        try:
            selected = int(raw_choice) - 1
        except ValueError:
            click.echo("Enter the number shown beside the option.")
            continue
        if 0 <= selected < len(options):
            return selected
        click.echo("Selected option is out of range.")


def _prompt_admin_credentials(*, default_region: str) -> Result[AdminAWSCredentials, str]:
    """Prompt for ephemeral elevated AWS credentials."""
    if shutil.which("aws") is None:
        return Failure("The AWS CLI is required for interactive setup flows")
    _show_admin_credentials_guidance()
    access_key_id = _prompt_text("Elevated AWS access key ID (from the AWS console)").strip()
    secret_access_key = _prompt_text(
        "Elevated AWS secret access key (hidden input)",
        hide_input=True,
    ).strip()
    session_token = _prompt_text(
        "Elevated AWS session token (optional; STS/session credentials only)",
        default="",
        show_default=False,
    ).strip()
    region = _prompt_text(
        "AWS region for elevated operations (you can change it after regions are listed)",
        default=default_region,
    ).strip()
    if access_key_id == "":
        return Failure("Elevated AWS access key ID is required")
    if secret_access_key == "":
        return Failure("Elevated AWS secret access key is required")
    if region == "":
        return Failure("Elevated AWS region is required")
    return Success(
        AdminAWSCredentials(
            access_key_id=access_key_id,
            secret_access_key=secret_access_key,
            session_token=session_token or None,
            region=region,
        )
    )


def _prompt_region_choice(credentials: AdminAWSCredentials) -> Result[str, str]:
    """Prompt for one AWS region from the live EC2 region list."""
    try:
        regions = _list_aws_regions(credentials)
    except Exception as error:
        return Failure(str(error))
    if regions == ():
        return Failure("No AWS regions were returned by `aws ec2 describe-regions`")
    _show_region_choice_guidance()
    click.echo("Available AWS regions:")
    for index, region in enumerate(regions, start=1):
        click.echo(f"{index}. {region.region_name} ({region.opt_in_status})")
    default_index = next(
        (index for index, region in enumerate(regions) if region.region_name == credentials.region),
        0,
    )
    selected_index = _prompt_numbered_choice(
        prompt_text="Choose the AWS region number for prodbox operations",
        options=tuple(region.region_name for region in regions),
        default_index=default_index,
    )
    return Success(regions[selected_index].region_name)


def _prompt_hosted_zone_choice(credentials: AdminAWSCredentials) -> Result[HostedZoneChoice, str]:
    """Prompt for one Route 53 hosted zone from the live account list."""
    try:
        zones = _list_hosted_zones(credentials)
    except Exception as error:
        return Failure(str(error))
    if zones == ():
        click.echo("No hosted zones were found in Route 53.")
        click.echo("Create one in the Route 53 console or delegate an existing domain, then rerun.")
        return Failure("No Route 53 hosted zones are available")
    _show_hosted_zone_choice_guidance()
    click.echo("Available Route 53 hosted zones:")
    for index, zone in enumerate(zones, start=1):
        click.echo(f"{index}. {zone.zone_name} ({zone.zone_id})")
    selected_index = _prompt_numbered_choice(
        prompt_text="Choose the public hosted zone number for prodbox DNS",
        options=tuple(zone.zone_name for zone in zones),
        default_index=0,
    )
    return Success(zones[selected_index])


def interactive_config_setup_command() -> Result[ConfigSetupCommand, str]:
    """Collect interactive onboarding inputs and return a ConfigSetupCommand."""
    click.echo("Config setup writes `prodbox-config.dhall`, creates the operational IAM user,")
    click.echo("and validates the result. The elevated credential entered below is not persisted.")
    click.echo("")
    if not _confirm("Do you already have an AWS account?", default=True):
        _show_aws_account_guidance()
    match _prompt_admin_credentials(default_region=_current_region_default()):
        case Failure(error):
            return Failure(error)
        case Success(value=initial_credentials):
            match _prompt_region_choice(initial_credentials):
                case Failure(error):
                    return Failure(error)
                case Success(value=selected_region):
                    credentials = AdminAWSCredentials(
                        access_key_id=initial_credentials.access_key_id,
                        secret_access_key=initial_credentials.secret_access_key,
                        session_token=initial_credentials.session_token,
                        region=selected_region,
                    )
                    match _prompt_hosted_zone_choice(credentials):
                        case Failure(error):
                            return Failure(error)
                        case Success(value=zone):
                            zone_name = zone.zone_name
                            demo_fqdn = _prompt_text(
                                "Demo public FQDN (for example demo.example.com)",
                                default=f"demo.{zone_name}",
                            ).strip()
                            demo_ttl = _prompt_int("Demo DNS TTL seconds", default=60)
                            vscode_fqdn = _prompt_text(
                                (
                                    "VS Code public FQDN (blank uses the demo FQDN; "
                                    "for example vscode.example.com)"
                                ),
                                default="",
                                show_default=False,
                            ).strip()
                            _show_acme_provider_guidance()
                            provider_options = ("ZeroSSL", "Let's Encrypt")
                            provider_index = _prompt_numbered_choice(
                                prompt_text="Choose the ACME provider number",
                                options=provider_options,
                                default_index=0,
                            )
                            acme_email = _prompt_text(
                                "ACME notification email (certificate expiry notices)"
                            ).strip()
                            acme_eab_key_id: str | None
                            acme_eab_hmac_key: str | None
                            match provider_options[provider_index]:
                                case "ZeroSSL":
                                    acme_server = ZERO_SSL_ACME_SERVER
                                    acme_eab_key_id = _prompt_text(
                                        "ZeroSSL EAB key ID (from ZeroSSL Developer settings)"
                                    ).strip()
                                    acme_eab_hmac_key = _prompt_text(
                                        "ZeroSSL EAB HMAC key (hidden input)",
                                        hide_input=True,
                                    ).strip()
                                case _:
                                    acme_server = LETS_ENCRYPT_ACME_SERVER
                                    acme_eab_key_id = None
                                    acme_eab_hmac_key = None
                            _show_policy_tier_guidance()
                            policy_options = ("full", "core")
                            policy_index = _prompt_numbered_choice(
                                prompt_text="Choose the operational IAM policy tier number",
                                options=policy_options,
                                default_index=0,
                            )
                            dev_mode = _confirm(
                                "Enable dev mode? (recommended for local or single-node work)",
                                default=True,
                            )
                            bootstrap_public_ip_override = _prompt_text(
                                (
                                    "Bootstrap public IP override (optional; leave blank unless "
                                    "public-edge auto-detection is wrong)"
                                ),
                                default="",
                                show_default=False,
                            ).strip()
                            pulumi_enable_dns_bootstrap = _confirm(
                                (
                                    "Enable Pulumi DNS bootstrap? (recommended; creates or "
                                    "reconciles the initial demo Route 53 record)"
                                ),
                                default=True,
                            )
                            manual_pv_host_root = _prompt_text(
                                (
                                    "Manual PV host root (host path reserved for retained PV "
                                    "contents)"
                                ),
                                default=".data",
                            ).strip()
                            return config_setup_command(
                                admin_access_key_id=credentials.access_key_id,
                                admin_secret_access_key=credentials.secret_access_key,
                                admin_session_token=credentials.session_token,
                                admin_region=credentials.region,
                                route53_zone_id=zone.zone_id,
                                demo_fqdn=demo_fqdn,
                                demo_ttl=demo_ttl,
                                vscode_fqdn=vscode_fqdn or None,
                                acme_email=acme_email,
                                acme_server=acme_server,
                                acme_eab_key_id=acme_eab_key_id,
                                acme_eab_hmac_key=acme_eab_hmac_key,
                                prodbox_dev_mode=dev_mode,
                                bootstrap_public_ip_override=bootstrap_public_ip_override or None,
                                pulumi_enable_dns_bootstrap=pulumi_enable_dns_bootstrap,
                                manual_pv_host_root=Path(manual_pv_host_root),
                                policy_tier=policy_options[policy_index],
                            )


def interactive_aws_setup_command(*, tier: str) -> Result[AWSSetupCommand, str]:
    """Collect elevated AWS inputs and return an AWSSetupCommand."""
    click.echo("AWS setup creates or refreshes the dedicated `prodbox` IAM user, writes")
    click.echo("operational `aws.*` credentials, and can request baseline service quotas.")
    click.echo("")
    match _prompt_admin_credentials(default_region=_current_region_default()):
        case Failure(error):
            return Failure(error)
        case Success(value=initial_credentials):
            match _prompt_region_choice(initial_credentials):
                case Failure(error):
                    return Failure(error)
                case Success(value=selected_region):
                    return aws_setup_command(
                        admin_access_key_id=initial_credentials.access_key_id,
                        admin_secret_access_key=initial_credentials.secret_access_key,
                        admin_session_token=initial_credentials.session_token,
                        admin_region=selected_region,
                        tier=tier,
                    )


def interactive_aws_teardown_command() -> Result[AWSTeardownCommand, str]:
    """Collect elevated AWS inputs and return an AWSTeardownCommand."""
    click.echo("AWS teardown deletes the dedicated `prodbox` IAM user and clears operational")
    click.echo("`aws.*` credentials from Dhall. The elevated credential entered below is not kept.")
    click.echo("")
    match _prompt_admin_credentials(default_region=_current_region_default()):
        case Failure(error):
            return Failure(error)
        case Success(value=credentials):
            return aws_teardown_command(
                admin_access_key_id=credentials.access_key_id,
                admin_secret_access_key=credentials.secret_access_key,
                admin_session_token=credentials.session_token,
                admin_region=credentials.region,
            )


def interactive_aws_check_quotas_command() -> Result[AWSCheckQuotasCommand, str]:
    """Collect elevated AWS inputs and return an AWSCheckQuotasCommand."""
    click.echo("AWS quota inspection reads the supported Service Quotas targets without changing")
    click.echo("the Dhall config or creating IAM users.")
    click.echo("")
    match _prompt_admin_credentials(default_region=_current_region_default()):
        case Failure(error):
            return Failure(error)
        case Success(value=initial_credentials):
            match _prompt_region_choice(initial_credentials):
                case Failure(error):
                    return Failure(error)
                case Success(value=selected_region):
                    return aws_check_quotas_command(
                        admin_access_key_id=initial_credentials.access_key_id,
                        admin_secret_access_key=initial_credentials.secret_access_key,
                        admin_session_token=initial_credentials.session_token,
                        admin_region=selected_region,
                    )


def interactive_aws_request_quotas_command(*, tier: str) -> Result[AWSRequestQuotasCommand, str]:
    """Collect elevated AWS inputs and return an AWSRequestQuotasCommand."""
    click.echo("AWS quota requests submit increases only for supported targets that are still")
    click.echo("below the required threshold.")
    click.echo("")
    match _prompt_admin_credentials(default_region=_current_region_default()):
        case Failure(error):
            return Failure(error)
        case Success(value=initial_credentials):
            match _prompt_region_choice(initial_credentials):
                case Failure(error):
                    return Failure(error)
                case Success(value=selected_region):
                    return aws_request_quotas_command(
                        admin_access_key_id=initial_credentials.access_key_id,
                        admin_secret_access_key=initial_credentials.secret_access_key,
                        admin_session_token=initial_credentials.session_token,
                        admin_region=selected_region,
                        tier=tier,
                    )


__all__ = [
    "AdminAWSCredentials",
    "BASELINE_QUOTA_SPECS",
    "ConfigSetupResult",
    "FULL_QUOTA_SPECS",
    "HostedZoneChoice",
    "IAMSetupResult",
    "IAMTeardownResult",
    "PolicyTier",
    "QuotaSpec",
    "QuotaStatus",
    "RegionChoice",
    "build_iam_policy_document",
    "build_iam_policy_json",
    "ensure_operational_aws_credentials_from_admin_harness",
    "interactive_aws_check_quotas_command",
    "interactive_aws_request_quotas_command",
    "interactive_aws_setup_command",
    "interactive_aws_teardown_command",
    "interactive_config_setup_command",
    "operational_aws_credentials_are_valid",
    "quota_status_rows",
    "render_aws_setup_result",
    "render_aws_teardown_result",
    "render_config_setup_result",
    "restore_operational_aws_identity_from_admin_harness",
    "run_aws_check_quotas",
    "run_aws_request_quotas",
    "run_aws_setup",
    "run_aws_teardown",
    "run_config_setup",
]
