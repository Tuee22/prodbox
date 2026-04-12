"""Integration tests for the live vscode.resolvefintech.com deployment.

charts-vscode suite – end-to-end validation of the vscode chart stack at
its public hostname, including:
  - HTTPS reachability
  - Valid TLS certificate (issued by the configured public ACME CA)
  - HTTP 302 redirect to Keycloak username/password login page (auth wall enforced)

Prerequisites (must be satisfied before running this suite):
  - The vscode chart stack is deployed and all workloads are Running
  - `VSCODE_FQDN` env var is set (or defaults to `vscode.resolvefintech.com`)
  - Live public DNS resolves the FQDN to the cluster edge
  - The configured public ACME CA has issued a valid certificate

These tests make outbound HTTPS requests from the test runner host.
They do NOT require a cluster kubeconfig or kubectl.
"""

from __future__ import annotations

import json
import os
import ssl
import time
import urllib.parse
import urllib.request
from functools import lru_cache
from http.client import HTTPException, HTTPSConnection
from typing import NamedTuple, cast
from urllib.error import URLError

import pytest

pytestmark = [pytest.mark.integration, pytest.mark.timeout(120)]

_DEFAULT_FQDN = "vscode.resolvefintech.com"
_FQDN = os.environ.get("VSCODE_FQDN", _DEFAULT_FQDN)
_BASE_URL = f"https://{_FQDN}"
_CONNECT_TIMEOUT = 15.0
_PUBLIC_DOH_RESOLVER = "https://dns.google/resolve"
_CONNECT_HOST_ENV_VAR = "PRODBOX_PUBLIC_EDGE_CONNECT_HOST"
_REDIRECT_STATUSES = frozenset({301, 302, 303, 307, 308})


class HttpProbeResult(NamedTuple):
    """HTTP probe result for one URL fetch."""

    status: int
    location: str | None
    body_fragment: str
    tls_subject: str | None
    tls_issuer: str | None


class _ResolvedHTTPSConnection(HTTPSConnection):
    """HTTPS connection that dials one explicit IP while preserving SNI/Host."""

    def __init__(
        self,
        *,
        host: str,
        connect_host: str,
        context: ssl.SSLContext,
        timeout: float,
    ) -> None:
        super().__init__(host=host, timeout=timeout, context=context)
        self._connect_host = connect_host

    def connect(self) -> None:
        self.sock = self._create_connection(
            (self._connect_host, self.port),
            self.timeout,
            self.source_address,
        )
        self.sock = self._context.wrap_socket(self.sock, server_hostname=self.host)


def _request_path(parsed: urllib.parse.ParseResult) -> str:
    """Build the request path from one parsed HTTPS URL."""
    path = parsed.path or "/"
    if parsed.query:
        return f"{path}?{parsed.query}"
    return path


def _cert_subject_and_issuer(cert: dict[str, object] | None) -> tuple[str | None, str | None]:
    """Extract subject CN and issuer organization/CN from one peer certificate."""
    if cert is None:
        return None, None
    subject_tuples = cert.get("subject", ())
    issuer_tuples = cert.get("issuer", ())
    if not isinstance(subject_tuples, tuple) or not isinstance(issuer_tuples, tuple):
        return None, None
    subject_map = dict(pair for group in subject_tuples for pair in group)
    issuer_map = dict(pair for group in issuer_tuples for pair in group)
    subject = cast(str | None, subject_map.get("commonName") or subject_map.get("CN"))
    issuer = cast(
        str | None,
        issuer_map.get("organizationName") or issuer_map.get("O") or issuer_map.get("CN"),
    )
    return subject, issuer


@lru_cache(maxsize=8)
def _public_ipv4_address(hostname: str) -> str:
    """Resolve one hostname through public DNS-over-HTTPS only."""
    query = urllib.parse.urlencode({"name": hostname, "type": "A"})
    request = urllib.request.Request(
        f"{_PUBLIC_DOH_RESOLVER}?{query}",
        headers={"Accept": "application/dns-json"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=_CONNECT_TIMEOUT) as response:
            payload = cast(dict[str, object], json.loads(response.read().decode("utf-8")))
    except URLError as error:
        raise AssertionError(f"public DNS query failed for {hostname}: {error}") from error

    status = payload.get("Status")
    if status != 0:
        raise AssertionError(f"public DNS query returned non-zero status for {hostname}: {status}")
    raw_answers = payload.get("Answer")
    if not isinstance(raw_answers, list):
        raise AssertionError(f"public DNS query returned no Answer section for {hostname}")

    addresses = sorted(
        str(data)
        for answer in raw_answers
        if isinstance(answer, dict)
        for answer_type in (answer.get("type"),)
        for data in (answer.get("data"),)
        if answer_type == 1 and isinstance(data, str) and data != ""
    )
    if not addresses:
        raise AssertionError(f"public DNS query returned no A records for {hostname}")
    return addresses[0]


@lru_cache(maxsize=8)
def _connect_host_for_probe(hostname: str) -> str:
    """Return the connect target for one probe while still requiring public DNS proof."""
    public_ip = _public_ipv4_address(hostname)
    match os.environ.get(_CONNECT_HOST_ENV_VAR):
        case str() as value if value.strip():
            return value.strip()
        case _:
            return public_ip


def _perform_https_request(
    *,
    url: str,
    context: ssl.SSLContext,
) -> tuple[int, str | None, str, str | None, str | None]:
    """Perform one HTTPS GET through the public DNS answer for the target host."""
    parsed = urllib.parse.urlparse(url)
    hostname = parsed.hostname
    if parsed.scheme != "https" or hostname in (None, ""):
        raise AssertionError(f"expected one https URL, got {url!r}")
    connect_host = _connect_host_for_probe(hostname)
    connection = _ResolvedHTTPSConnection(
        host=hostname,
        connect_host=connect_host,
        context=context,
        timeout=_CONNECT_TIMEOUT,
    )
    try:
        connection.request(
            "GET",
            _request_path(parsed),
            headers={
                "Accept": "text/html,application/xhtml+xml",
                "Host": hostname,
            },
        )
        response = connection.getresponse()
        body = response.read(4096).decode("utf-8", errors="replace")
        location = response.headers.get("Location")
        cert = connection.sock.getpeercert() if connection.sock is not None else None
        tls_subject, tls_issuer = _cert_subject_and_issuer(cert)
        return response.status, location, body[:4096], tls_subject, tls_issuer
    except (OSError, ssl.SSLError, HTTPException) as error:
        raise AssertionError(
            f"URL probe failed for {url}: {type(error).__name__}: {error}"
        ) from error
    finally:
        connection.close()


@lru_cache(maxsize=1)
def _verified_peer_certificate() -> dict[str, object]:
    """Fetch the verified peer certificate from the public edge."""
    context = ssl.create_default_context()
    connect_host = _connect_host_for_probe(_FQDN)
    connection = _ResolvedHTTPSConnection(
        host=_FQDN,
        connect_host=connect_host,
        context=context,
        timeout=_CONNECT_TIMEOUT,
    )
    try:
        connection.connect()
        cert = connection.sock.getpeercert() if connection.sock is not None else None
    except ssl.SSLError as error:
        raise AssertionError(f"TLS handshake failed for {_FQDN}: {error}") from error
    except OSError as error:
        raise AssertionError(f"TLS connection failed for {_FQDN}: {error}") from error
    finally:
        connection.close()

    if not isinstance(cert, dict):
        raise AssertionError(f"TLS peer certificate missing for {_FQDN}")
    return cert


def _probe(url: str, *, follow_redirects: bool = False) -> HttpProbeResult:
    """Fetch one URL and return structured probe data via public DNS resolution."""
    current_url = url
    max_hops = 5 if follow_redirects else 1
    result: HttpProbeResult | None = None
    context = ssl.create_default_context()

    for _ in range(max_hops):
        status, location, body_fragment, tls_subject, tls_issuer = _perform_https_request(
            url=current_url,
            context=context,
        )
        result = HttpProbeResult(
            status=status,
            location=location,
            body_fragment=body_fragment,
            tls_subject=tls_subject,
            tls_issuer=tls_issuer,
        )
        if not follow_redirects or status not in _REDIRECT_STATUSES or location in (None, ""):
            break
        current_url = urllib.parse.urljoin(current_url, location)

    if result is None:
        raise AssertionError(f"no HTTP probe result produced for {url}")
    return result


def _probe_with_retry(
    url: str,
    *,
    follow_redirects: bool = False,
    attempts: int = 3,
    retryable_statuses: frozenset[int] = frozenset({500, 502, 503, 504}),
    retry_delay_seconds: float = 2.0,
) -> HttpProbeResult:
    """Retry transient 5xx responses before failing a live public-host assertion."""
    result = _probe(url, follow_redirects=follow_redirects)
    for _ in range(1, attempts):
        if result.status not in retryable_statuses:
            return result
        time.sleep(retry_delay_seconds)
        result = _probe(url, follow_redirects=follow_redirects)
    return result


def _probe_with_ssl_context() -> tuple[str | None, str | None]:
    """Fetch TLS certificate info directly from the public edge."""
    cert = _verified_peer_certificate()
    return _cert_subject_and_issuer(cert)


def test_https_endpoint_is_reachable() -> None:
    """HTTPS GET to the root path must return a non-5xx response."""
    result = _probe(_BASE_URL)
    assert result.status < 500, f"Unexpected server error from {_BASE_URL}: HTTP {result.status}"


def test_http_root_returns_redirect_not_200() -> None:
    """Root path must redirect to auth (status 302/301) rather than serving content directly."""
    result = _probe(_BASE_URL)
    assert result.status in (
        301,
        302,
        303,
        307,
        308,
    ), f"Expected redirect from {_BASE_URL}, got HTTP {result.status}"


def test_tls_certificate_is_valid() -> None:
    """TLS handshake must succeed and cert must pass default verification."""
    try:
        _probe_with_ssl_context()
    except AssertionError:
        raise
    except Exception as error:
        raise AssertionError(f"TLS verification failed for {_FQDN}: {error}") from error


def test_tls_cert_covers_expected_fqdn() -> None:
    """TLS certificate subject/SAN must cover the configured FQDN."""
    cert = _verified_peer_certificate()
    san_entries = cert.get("subjectAltName", ()) if cert else ()
    dns_names = [v for k, v in san_entries if k == "DNS"]
    assert any(
        name == _FQDN or name.startswith("*.") and _FQDN.endswith(name[1:]) for name in dns_names
    ) or any(
        _FQDN in (v for inner in cert.get("subject", ()) for k, v in [inner] if k == "commonName")
    ), f"FQDN {_FQDN!r} not covered by cert SANs: {dns_names}"


def test_tls_cert_issued_by_supported_public_ca() -> None:
    """TLS certificate must be issued by a supported public ACME CA."""
    cert = _verified_peer_certificate()
    issuer_tuples = cert.get("issuer", ()) if cert else ()
    issuer_map = dict(pair for group in issuer_tuples for pair in group)
    org = cast(str, issuer_map.get("organizationName", ""))
    cn = cast(str, issuer_map.get("commonName", ""))
    assert (
        "let's encrypt" in org.lower()
        or "let's encrypt" in cn.lower()
        or "zerossl" in org.lower()
        or "zerossl" in cn.lower()
        or "sectigo" in org.lower()
        or "sectigo" in cn.lower()
    ), f"Expected supported public CA issuer, got org={org!r} cn={cn!r}"


def test_root_redirects_to_keycloak_login() -> None:
    """Root path must redirect unauthenticated requests into the Keycloak login flow."""
    result = _probe(_BASE_URL)
    assert result.status in (
        301,
        302,
        303,
        307,
        308,
    ), f"Expected redirect from root, got HTTP {result.status}"
    location = (result.location or "").lower()
    assert (
        "/auth/realms/" in location or "keycloak" in location
    ), f"Redirect location {result.location!r} does not point to Keycloak login"


def test_keycloak_auth_endpoint_is_reachable() -> None:
    """The /auth/realms/prodbox/ endpoint on the public FQDN must be reachable."""
    keycloak_url = f"{_BASE_URL}/auth/realms/prodbox/"
    result = _probe(keycloak_url)
    assert (
        result.status < 500
    ), f"Keycloak realm endpoint returned server error: HTTP {result.status}"
    assert (
        result.status != 404
    ), "Keycloak realm endpoint not found (404): realm 'prodbox' may not be configured"


def test_keycloak_login_page_offers_username_password_form() -> None:
    """The Keycloak login page must offer a username/password form, not an external IdP only."""
    login_url = f"{_BASE_URL}/auth/realms/prodbox/protocol/openid-connect/auth"
    callback = urllib.parse.quote(f"https://{_FQDN}/auth/callback", safe="")
    params = f"?client_id=vscode-nginx&response_type=code&scope=openid&redirect_uri={callback}"
    result = _probe_with_retry(login_url + params)
    assert result.status in (
        200,
        302,
        303,
    ), f"Unexpected status from Keycloak login endpoint: HTTP {result.status}"
    body_lower = result.body_fragment.lower()
    location = (result.location or "").lower()
    assert (
        "password" in body_lower
        or "username" in body_lower
        or "sign in" in body_lower
        or "kc-form-login" in body_lower
        or "login" in body_lower
        or "login" in location
    ), (
        f"Keycloak login page does not appear to offer username/password form: "
        f"status={result.status}, body_fragment={result.body_fragment[:300]!r}"
    )
    assert (
        "accounts.google.com" not in body_lower
    ), "Keycloak login page references Google OAuth, which is not a supported auth path"
