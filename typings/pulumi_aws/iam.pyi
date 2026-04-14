"""Type stubs for pulumi_aws.iam module."""

from typing import Sequence

from pulumi import InvokeOptions, Output, ResourceOptions

class GetPolicyDocumentStatementPrincipalArgs:
    def __init__(self, type: str, identifiers: Sequence[str]) -> None: ...

class GetPolicyDocumentStatementArgs:
    def __init__(
        self,
        actions: Sequence[str],
        principals: Sequence[GetPolicyDocumentStatementPrincipalArgs] | None = None,
    ) -> None: ...

class GetPolicyDocumentResult:
    json: Output[str]

class AwaitableGetPolicyDocumentResult:
    json: str


class Role:
    name: Output[str]

    def __init__(
        self,
        resource_name: str,
        assume_role_policy: object,
        name: str,
        opts: ResourceOptions | None = None,
    ) -> None: ...

class RolePolicyAttachment:
    def __init__(
        self,
        resource_name: str,
        role: object,
        policy_arn: str,
        opts: ResourceOptions | None = None,
    ) -> None: ...

class InstanceProfile:
    name: Output[str]

    def __init__(
        self,
        resource_name: str,
        role: object,
        name: str,
        opts: ResourceOptions | None = None,
    ) -> None: ...

def get_policy_document(
    *,
    statements: Sequence[GetPolicyDocumentStatementArgs],
    opts: InvokeOptions | None = None,
) -> AwaitableGetPolicyDocumentResult: ...

def get_policy_document_output(
    *,
    statements: Sequence[GetPolicyDocumentStatementArgs],
) -> GetPolicyDocumentResult: ...

__all__ = [
    "AwaitableGetPolicyDocumentResult",
    "GetPolicyDocumentResult",
    "GetPolicyDocumentStatementArgs",
    "GetPolicyDocumentStatementPrincipalArgs",
    "InstanceProfile",
    "Role",
    "RolePolicyAttachment",
    "get_policy_document",
    "get_policy_document_output",
]
