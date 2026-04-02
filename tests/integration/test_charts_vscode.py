"""Integration tests for the live vscode.resolvefintech.com deployment.

charts-vscode suite – end-to-end validation of the vscode chart stack at
its public hostname, including:
  - HTTPS reachability
  - Valid TLS certificate (issued by Let's Encrypt)
  - HTTP 302 redirect to Keycloak username/password login page (auth wall enforced)

Prerequisites (must be satisfied before running this suite):
  - The vscode chart stack is deployed and all workloads are Running
  - `VSCODE_FQDN` env var is set (or defaults to `vscode.resolvefintech.com`)
  - Live DNS resolves the FQDN to the cluster MetalLB address
  - Let's Encrypt has issued a valid certificate

These tests make outbound HTTPS requests from the test runner host.
They do NOT require a cluster kubeconfig or kubectl.
"""

from __future__ import annotations

import os
import ssl
import urllib.parse
import urllib.request
from http.client import HTTPResponse
from typing import NamedTuple
from urllib.error import HTTPError, URLError

import pytest

pytestmark = [pytest.mark.integration, pytest.mark.timeout(120)]

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

_DEFAULT_FQDN = "vscode.resolvefintech.com"
_FQDN = os.environ.get("VSCODE_FQDN", _DEFAULT_FQDN)
_BASE_URL = f"https://{_FQDN}"
_CONNECT_TIMEOUT = 15.0


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


class HttpProbeResult(NamedTuple):
    """HTTP probe result for one URL fetch."""

    status: int
    location: str | None
    body_fragment: str
    tls_subject: str | None
    tls_issuer: str | None


def _probe(url: str, *, follow_redirects: bool = False) -> HttpProbeResult:
    """Fetch one URL and return structured probe data."""
    context = ssl.create_default_context()
    opener = urllib.request.OpenerDirector()
    opener.add_handler(urllib.request.HTTPHandler())
    opener.add_handler(urllib.request.HTTPSHandler(context=context))
    opener.add_handler(urllib.request.HTTPDefaultErrorHandler())
    if follow_redirects:
        opener.add_handler(urllib.request.HTTPRedirectHandler())

    tls_subject: str | None = None
    tls_issuer: str | None = None

    try:
        request = urllib.request.Request(url, method="GET")
        request.add_header("Accept", "text/html,application/xhtml+xml")
        response = opener.open(request, timeout=_CONNECT_TIMEOUT)
        if isinstance(response, HTTPResponse):
            body = response.read(4096).decode("utf-8", errors="replace")
            location = response.headers.get("Location")
            status = response.status
        else:
            body = ""
            location = None
            status = 200
    except HTTPError as error:
        body = error.read(4096).decode("utf-8", errors="replace") if error.fp else ""
        location = error.headers.get("Location")
        status = error.code
    except URLError as error:
        raise AssertionError(f"URL probe failed for {url}: {error}") from error

    # Attempt to read TLS cert info from the connection.
    try:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        import socket

        with socket.create_connection(
            (_FQDN, 443), timeout=_CONNECT_TIMEOUT
        ) as sock, ctx.wrap_socket(sock, server_hostname=_FQDN) as ssock:
            cert = ssock.getpeercert()
            if cert:
                subject_tuples = cert.get("subject", ())
                issuer_tuples = cert.get("issuer", ())
                subject_map = dict(pair for group in subject_tuples for pair in group)
                issuer_map = dict(pair for group in issuer_tuples for pair in group)
                tls_subject = subject_map.get("commonName") or subject_map.get("CN")
                tls_issuer = issuer_map.get("organizationName") or issuer_map.get("O")
    except Exception:
        pass

    return HttpProbeResult(
        status=status,
        location=location,
        body_fragment=body[:4096],
        tls_subject=tls_subject,
        tls_issuer=tls_issuer,
    )


def _probe_with_ssl_context() -> tuple[str | None, str | None]:
    """Fetch TLS certificate info directly from the server."""
    import socket

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = True
    ctx.verify_mode = ssl.CERT_REQUIRED
    ctx.load_default_certs()
    try:
        with socket.create_connection(
            (_FQDN, 443), timeout=_CONNECT_TIMEOUT
        ) as sock, ctx.wrap_socket(sock, server_hostname=_FQDN) as ssock:
            cert = ssock.getpeercert()
            subject_tuples = cert.get("subject", ()) if cert else ()
            issuer_tuples = cert.get("issuer", ()) if cert else ()
            subject_map = dict(pair for group in subject_tuples for pair in group)
            issuer_map = dict(pair for group in issuer_tuples for pair in group)
            cn = subject_map.get("commonName")
            org = issuer_map.get("organizationName")
            return cn, org
    except ssl.SSLError as error:
        raise AssertionError(f"TLS handshake failed for {_FQDN}: {error}") from error


# ---------------------------------------------------------------------------
# Tests: HTTPS reachability
# ---------------------------------------------------------------------------


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


# ---------------------------------------------------------------------------
# Tests: valid TLS certificate
# ---------------------------------------------------------------------------


def test_tls_certificate_is_valid() -> None:
    """TLS handshake must succeed and cert must pass default verification."""
    try:
        cn, org = _probe_with_ssl_context()
    except AssertionError:
        raise
    except Exception as error:
        raise AssertionError(f"TLS verification failed for {_FQDN}: {error}") from error


def test_tls_cert_covers_expected_fqdn() -> None:
    """TLS certificate subject/SAN must cover the configured FQDN."""
    import socket

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = True
    ctx.verify_mode = ssl.CERT_REQUIRED
    ctx.load_default_certs()
    try:
        with socket.create_connection(
            (_FQDN, 443), timeout=_CONNECT_TIMEOUT
        ) as sock, ctx.wrap_socket(sock, server_hostname=_FQDN) as ssock:
            cert = ssock.getpeercert()
            san_entries = cert.get("subjectAltName", ()) if cert else ()
            dns_names = [v for k, v in san_entries if k == "DNS"]
            assert any(
                name == _FQDN or name.startswith("*.") and _FQDN.endswith(name[1:])
                for name in dns_names
            ) or any(
                _FQDN
                in (v for inner in cert.get("subject", ()) for k, v in [inner] if k == "commonName")
            ), f"FQDN {_FQDN!r} not covered by cert SANs: {dns_names}"
    except ssl.SSLError as error:
        raise AssertionError(f"TLS check failed for {_FQDN}: {error}") from error


def test_tls_cert_issued_by_lets_encrypt() -> None:
    """TLS certificate must be issued by Let's Encrypt (R or E series issuer)."""
    import socket

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = True
    ctx.verify_mode = ssl.CERT_REQUIRED
    ctx.load_default_certs()
    try:
        with socket.create_connection(
            (_FQDN, 443), timeout=_CONNECT_TIMEOUT
        ) as sock, ctx.wrap_socket(sock, server_hostname=_FQDN) as ssock:
            cert = ssock.getpeercert()
            issuer_tuples = cert.get("issuer", ()) if cert else ()
            issuer_map = dict(pair for group in issuer_tuples for pair in group)
            org = issuer_map.get("organizationName", "")
            cn = issuer_map.get("commonName", "")
            assert (
                "let's encrypt" in org.lower() or "let's encrypt" in cn.lower()
            ), f"Expected Let's Encrypt issuer, got org={org!r} cn={cn!r}"
    except ssl.SSLError as error:
        raise AssertionError(f"TLS issuer check failed for {_FQDN}: {error}") from error


# ---------------------------------------------------------------------------
# Tests: auth redirect to Keycloak username/password login
# ---------------------------------------------------------------------------


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
    result = _probe(login_url + params)
    # Keycloak may redirect to its login page (302) or return the page directly (200).
    assert result.status in (
        200,
        302,
        303,
    ), f"Unexpected status from Keycloak login endpoint: HTTP {result.status}"
    body_lower = result.body_fragment.lower()
    location = (result.location or "").lower()
    # The login page must contain a password input field (username/password form)
    # or redirect to a page that does. It must NOT have Google OAuth exclusively.
    assert "password" in body_lower or "login" in body_lower or "login" in location, (
        f"Keycloak login page does not appear to offer username/password form: "
        f"status={result.status}, body_fragment={result.body_fragment[:300]!r}"
    )
    # Confirm no Google OAuth dependency
    assert (
        "accounts.google.com" not in body_lower
    ), "Keycloak login page references Google OAuth, which was removed in Sprint 9"
