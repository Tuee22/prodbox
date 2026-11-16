# Public Edge, Email and User Access

**Status**: Authoritative source
**Supersedes**: Pre-refactor Envoy edge and ACME workflow doctrine
**Generated sections**: none
**Applicability**: Adopted target contract; real public proof is owned by the edge and parity phases

> **Purpose**: Define one routed public host per target, real TLS/authentication, SES, and user lifecycle.

## Traffic and route catalog

Each local/AWS application target has an explicit validated served FQDN. One catalog owns `/auth`, `/vscode`, `/api`, `/ws` and `/minio`, their services and route policies. The Keycloak issuer derives from the same served host and `/auth` realm path. Do not restore the retired five-independent-host design or a second proxy topology.

Port 80 redirects permanently to the same path on HTTPS; 443 is the application routing listener. Envoy Gateway/Gateway API owns listeners, routes and policy. Keycloak owns identity; application services own their authorization logic. The registry has no admin web UI. The MinIO console is an explicitly authenticated administrative surface, not a general object-store credential API.

Local kind uses the configured host publication path through MetalLB/Envoy; EKS uses AWS Load Balancer Controller/Envoy. Validate actual DNS-to-public-edge reachability independently of Kubernetes Service/Pod readiness. A Route 53 A record, issued certificate or Ready flag alone does not prove a served route works.

## Certificate scope and issuance

Real ZeroSSL through cert-manager DNS01 is the supported public proof. The configured certificate scope set must cover the actual served host before listener rendering. Wildcard SANs do not invent extra listeners, DNS records or public routes. Validate hostnames, IPs, explicit parent/delegated-zone ownership and account/region before any DNS operation.

Register challenge record and certificate-consumer obligations before issuance. DNS01 identities are least-privilege and target-specific; an EKS identity cannot mutate home/production records. Parent zones are external; exact managed records are owned and cleaned. Observe DNS propagation, Certificate/Challenge behavior and the certificate actually served with hostname/trust verification.

Retain local certificate material for intentional local rebuild/restart and restore the exact scope/generation before ordering again. Remote TLS objects/versions/buckets created by this deployment are included in explicit cloud delete. Agents read/write allowlisted generations; Authority/transport see ciphertext/receipts, not a generic private-key export. Preserve rotation and wrong-scope rejection. [Security](security_and_credentials.md#secret-delivery-encryption-and-rotation)

## Authentication and APIs

Use explicit OIDC code flow for browser surfaces. Envoy's edge OIDC policy protects apps that do not manage their own browser login; application-managed OIDC remains available where its client/session semantics are explicit. Keep secure cookies, callback/origin/proxy settings and issuer/audience validation derived from the same public-host catalog.

API and websocket routes enforce JWT signature, issuer, audience and expiry against Keycloak. Browser redirect success is not API authorization. Test unauthorized requests, wrong issuer/audience, expired tokens, key rotation and authenticated calls. Websocket acceptance, origin/auth handling, reconnect and revocation behavior are observable product contracts; a successful HTTP upgrade alone does not validate message authorization.

Redis supplies shared realtime state with declared persistence/availability policy. Stateful services cannot silently fall back to per-Pod process memory during a parity proof. [Platform](platform_and_services.md)

## SES and users

`users invite/list/revoke` uses real Keycloak/SES capability and the durable operation engine. Register invitation/capture cleanup before effects. Invitation proof includes real sent/received email, expected recipient/capture binding, usable login flow and revoked access. A local mail fake is useful for unit cases but not real-email phase completion.

Production and each test campaign have distinct SES identities, SMTP principals/material, capture buckets/prefixes, DNS records and recipient rules. Cases may reuse their own campaign resources. Shared-account receipt activation must preserve production, as specified by [AWS receiving isolation](aws_resources.md#ses-and-receiving-isolation). Slow DNS verification justifies reuse, not exemption from explicit deployment delete.

Ordinary cloud delete quiesces local consumers of deleted DNS/SES credentials and reports cloud-dependent edge/email features inactive. Local services can remain running; that does not mean public TLS/DNS/email remained healthy after their cloud support was intentionally removed.

## Evidence

The local platform phase proves local protocols without pretending to have issued a public certificate. The edge phase proves real DNS/ZeroSSL/SES/user journeys; EKS parity repeats them on EKS. Independent DNS/TLS/protocol observers and negative controls reject wrong host/certificate/token, missing records, unavailable email and residual owned resources. [Acceptance cases](../../DEVELOPMENT_PLAN/acceptance_cases.md)
