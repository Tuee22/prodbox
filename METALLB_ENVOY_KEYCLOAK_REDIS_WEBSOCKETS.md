# MetalLB + Envoy Gateway + Keycloak + Redis + WebSockets

This document describes a Kubernetes-native ingress and authentication setup using:

- MetalLB for bare-metal or on-prem `LoadBalancer` IP allocation
- Envoy Gateway as the ingress / gateway / edge enforcement layer
- Keycloak as the OpenID Connect identity provider
- Redis as shared application infrastructure, not as Envoy's JWT cache
- Stateless WebSocket application pods behind Envoy

The intended architecture is:

```text
Client / Browser / API Consumer
        |
        v
MetalLB external IP
        |
        v
Envoy Gateway / Envoy data plane
        |
        +--> Keycloak
        |
        +--> HTTP applications
        |
        +--> WebSocket applications
```

---

## 1. Component responsibilities

### MetalLB

MetalLB provides external IP addresses for Kubernetes `Service` objects of type `LoadBalancer`.

In this stack, MetalLB does not understand HTTP, TLS, OIDC, JWTs, WebSockets, or application routing. Its job is simply to make the Envoy Gateway service reachable from outside the cluster.

Typical role:

```text
External client -> MetalLB-assigned IP -> Envoy Gateway Service
```

MetalLB may run in either:

- L2 mode
- BGP mode

The choice affects how the external IP is advertised, but not how Envoy, Keycloak, Redis, or WebSockets behave.

---

### Envoy Gateway / Envoy

Envoy Gateway is the Kubernetes control plane that manages Envoy proxies. Envoy is the actual data plane handling traffic.

Envoy is responsible for:

- TLS termination
- HTTP routing
- Gateway API routing
- forwarding traffic to services
- optional OIDC login flow handling
- optional JWT validation
- optional claim-based authorization
- WebSocket proxying
- observability at the edge

Envoy is not responsible for durable storage.

Envoy should be treated as a stateless edge proxy.

---

### Keycloak

Keycloak is the identity provider.

Keycloak is responsible for:

- user login
- password / MFA / SSO policy
- OIDC flows
- issuing tokens
- signing JWTs
- managing users, groups, roles, clients, and realms
- maintaining identity/session state

Keycloak should use its own database for durable storage.

Envoy trusts Keycloak by validating tokens that Keycloak issued.

---

### Redis

Redis is optional shared infrastructure for the applications.

Redis can be used for:

- WebSocket presence state
- pub/sub fanout
- shared session-like application state
- distributed locks
- app-level caching
- global rate-limit backends, if using an external rate-limit service

Redis is not used by Envoy to cache JWT validation results.

JWT validation is designed to be local and stateless at Envoy.

---

### Application pods

Application pods sit behind Envoy.

They may be:

- normal HTTP apps
- APIs
- WebSocket servers
- legacy apps that do not understand OIDC
- modern apps that integrate with Keycloak directly

For stateless operation, application pods should not rely on local in-memory state for anything that must survive reconnects, pod restarts, or load balancing.

Shared state should live in Redis, a database, NATS, Kafka, or another external system.

---

## 2. High-level traffic model

The external entrypoint is the MetalLB-assigned IP for Envoy.

```text
Client
  -> MetalLB external IP
  -> Kubernetes LoadBalancer Service
  -> Envoy Gateway managed Envoy pods
  -> backend Kubernetes Services
  -> application pods or Keycloak
```

Example hostname routing:

```text
auth.example.com -> Envoy -> Keycloak Service
app.example.com  -> Envoy -> App Service
ws.example.com   -> Envoy -> WebSocket Service
```

In this model, Nginx is usually removed from the edge path.

The old model:

```text
Client -> Nginx reverse proxy -> Keycloak / Apps
```

becomes:

```text
Client -> MetalLB -> Envoy Gateway -> Keycloak / Apps
```

Nginx is only kept if there is a specific Nginx-only feature still required.

---

## 3. Authentication model

There are two common authentication patterns.

---

### Pattern A: Application handles OIDC

In this pattern, Envoy only routes traffic.

```text
Client
  -> Envoy
  -> App
  -> redirect to Keycloak
  -> login
  -> App receives tokens/session
```

Responsibilities:

```text
Keycloak = authenticates user
App      = performs OIDC flow and validates login/session
Envoy    = TLS termination and routing
```

Use this when:

- the application already supports OIDC well
- the application needs to manage its own session
- app-level business logic depends heavily on identity claims

This is often the simplest migration path from an existing Keycloak setup.

---

### Pattern B: Envoy enforces auth at the edge

In this pattern, Envoy acts as the policy enforcement point.

```text
Client
  -> Envoy
  -> redirect to Keycloak if not logged in
  -> Keycloak authenticates user
  -> Keycloak issues tokens
  -> Client returns to Envoy
  -> Envoy validates identity
  -> Envoy forwards to App
```

Responsibilities:

```text
Keycloak = authenticates user and issues signed tokens
Envoy    = verifies token/session and enforces access
App      = receives only authenticated traffic
```

Use this when:

- the app does not support OIDC
- centralized edge auth is desired
- you want unauthenticated traffic blocked before it reaches the app
- many internal apps should share the same authentication enforcement model

---

## 4. OIDC versus JWT in this stack

OIDC and JWT are related but not the same thing.

```text
OIDC = login/authentication protocol
JWT  = signed token format often produced by OIDC
```

Keycloak acts as the OIDC provider.

After successful authentication, Keycloak issues tokens. These tokens are often JWTs.

A JWT usually contains claims such as:

```json
{
  "iss": "https://auth.example.com/realms/example",
  "sub": "user-id",
  "aud": "my-app",
  "exp": 1710000000,
  "groups": ["users"],
  "realm_access": {
    "roles": ["user"]
  }
}
```

Envoy can validate the JWT and enforce access decisions based on those claims.

---

## 5. How Envoy validates JWTs

Envoy validates JWTs locally.

The request usually contains a token like:

```http
Authorization: Bearer eyJhbGciOiJSUzI1NiIs...
```

The validation process is:

```text
1. Extract JWT from the request
2. Decode JWT header and payload
3. Fetch Keycloak public signing keys from JWKS endpoint
4. Verify the JWT signature
5. Check standard claims
6. Optionally check custom claims
7. Allow or deny the request
```

Typical checks include:

```text
Signature: Was this token signed by Keycloak?
exp:       Has the token expired?
iss:       Did it come from the expected Keycloak realm?
aud:       Was it issued for the expected client/API?
claims:    Does it contain required roles/groups/scopes?
```

The important part is that Envoy does not call Keycloak for every request.

Keycloak signs the token once.

Envoy verifies the token locally using Keycloak's public keys.

That means the hot path is:

```text
Request -> Envoy -> local JWT verification -> App
```

not:

```text
Request -> Envoy -> Keycloak -> database -> Envoy -> App
```

This is what makes JWT enforcement fast and horizontally scalable.

---

## 6. Where Envoy gets the JWT

Envoy gets the JWT from the incoming request.

Common locations:

```text
Authorization: Bearer <jwt>
```

or:

```text
Cookie: <session or token cookie>
```

The token originally comes from Keycloak after a successful OIDC login.

Depending on the design, either:

1. the application performs the OIDC flow and the client later sends JWTs to Envoy, or
2. Envoy performs the OIDC flow and manages the login/session at the edge.

---

## 7. Why Redis is not used for JWT validation

Envoy does not normally use Redis to accelerate JWT validation.

JWT validation is fast because it is local and stateless:

```text
Envoy has Keycloak public key
JWT has signed claims
Envoy verifies signature and claims locally
```

Adding Redis to this path would usually make it slower and more fragile because it would add:

- a network call
- a shared dependency
- additional failure modes
- state that must be coordinated

Redis may still be valuable, but not as Envoy's JWT validation cache.

---

## 8. Appropriate Redis use cases

Redis is useful when the application needs shared state.

Examples:

### WebSocket presence

```text
user-123 -> connected to pod websocket-abc
```

### Pub/sub fanout

```text
App pod A publishes message
Redis distributes event
App pod B sends message to connected clients
```

### Shared app state

```text
session metadata
temporary room state
rate counters
collaboration state
```

### Global rate limiting

If using Envoy with an external rate-limit service:

```text
Envoy -> external rate-limit service -> Redis
```

In that case Redis stores counters, not JWT validation state.

---

## 9. WebSocket support

This ingress and authentication model supports WebSockets.

Typical WebSocket connection flow:

```text
Client
  -> Envoy HTTPS request
  -> Envoy validates auth at connection time
  -> Envoy upgrades connection
  -> Envoy proxies WebSocket stream to backend pod
```

After the WebSocket upgrade, Envoy keeps proxying the long-lived connection to the selected backend pod.

The backend pod owns that live connection until it closes.

---

## 10. Stateless WebSocket servers

A WebSocket server can be stateless in this model, but this needs a precise definition.

A live WebSocket connection is always tied to one backend pod while it is open.

Stateless means:

```text
If the connection drops and reconnects, any pod can handle the new connection.
```

It does not mean:

```text
A single active WebSocket connection moves between pods.
```

To make WebSocket pods stateless, move important state out of the pod.

Good external state locations include:

- Redis
- NATS
- Kafka
- Postgres
- another database
- a dedicated presence/session service

Application pods should not be the only place that knows:

- which users are online
- which rooms they joined
- what messages need to be delivered
- what subscriptions exist
- what state must survive a restart

---

## 11. WebSocket authentication caveats

For WebSockets, authentication usually happens at connection time.

Example:

```text
Client opens WebSocket with JWT
Envoy validates JWT
Envoy allows upgrade
WebSocket remains open
```

Important caveats:

### Token expiry

If the JWT expires while the WebSocket is already open, Envoy may not automatically re-check every WebSocket message.

Common approaches:

- keep WebSocket lifetimes bounded
- require reconnect after token expiry
- perform app-level re-auth over the WebSocket
- use short-lived access tokens plus refresh flow outside the socket
- close connections during periodic auth refresh windows

### Authorization changes

If a user is removed from a group while a socket is open, the existing connection may continue until it is closed unless the app or infrastructure actively terminates it.

For high-security systems, build explicit revocation or reconnect logic.

### Per-message authorization

Envoy can enforce access to the WebSocket endpoint.

It generally does not understand application-level WebSocket messages.

If different WebSocket messages have different permissions, the application should enforce that.

Example:

```text
Envoy: user may connect to /ws
App:   user may or may not send "delete-room"
```

---

## 12. Scaling model

This stack scales horizontally.

### Envoy

Run multiple Envoy replicas.

Envoy should be stateless.

Each Envoy pod can validate JWTs locally.

### Apps

Run multiple app replicas.

For HTTP workloads, requests can be load-balanced normally.

For WebSockets, each connection lands on one pod and stays there until disconnect.

### Redis

Use Redis for shared app state where needed.

For production, consider Redis high availability depending on how critical the state is.

### Keycloak

Keycloak is stateful and should be deployed with a proper database.

Keycloak availability matters for new logins and token refreshes.

Existing JWT validation at Envoy can continue briefly as long as Envoy has cached JWKS keys and tokens remain valid.

---

## 13. Operational guidance

### TLS

Usually terminate TLS at Envoy.

```text
Client HTTPS -> Envoy -> backend HTTP or HTTPS
```

For internal zero-trust requirements, use TLS/mTLS from Envoy to backends as well.

### Hostnames

Use separate hostnames for clarity:

```text
auth.example.com
app.example.com
api.example.com
ws.example.com
```

### Keycloak proxy awareness

When Keycloak is behind Envoy, configure Keycloak with the correct external hostname and proxy settings.

Keycloak must generate redirects and issuer URLs that match the public URL users access.

### Headers

Ensure Envoy forwards appropriate proxy headers if required by the backend:

```text
X-Forwarded-For
X-Forwarded-Proto
X-Forwarded-Host
```

### Health checks

Do not expose Keycloak management or health endpoints publicly unless explicitly intended.

Route only the public frontend paths through Envoy.

### Graceful shutdown for WebSockets

For WebSocket apps, configure graceful termination:

```text
1. Pod receives termination signal
2. Pod stops accepting new sockets
3. Pod keeps existing sockets alive for a drain period
4. Clients reconnect to another pod
```

Use Kubernetes readiness probes so terminating pods are removed from service endpoints before they exit.

---

## 14. Recommended migration path

Starting point:

```text
Client -> Nginx -> Keycloak / Apps
```

Target:

```text
Client -> MetalLB -> Envoy Gateway -> Keycloak / Apps
```

Recommended phases:

### Phase 1: Replace Nginx routing with Envoy routing

- Deploy MetalLB
- Deploy Envoy Gateway
- Expose Envoy Gateway with a `LoadBalancer` service
- Route `auth.example.com` to Keycloak
- Route app hostnames to app services
- Keep application-managed OIDC initially

### Phase 2: Add JWT validation for APIs

- Configure Envoy to trust Keycloak JWKS
- Require valid JWTs for selected API routes
- Enforce issuer and audience
- Add role/group/scope checks where appropriate

### Phase 3: Add edge OIDC for apps that need it

- Use Envoy-managed OIDC login for apps that do not support OIDC
- Keep app-managed OIDC for apps that need deeper identity integration

### Phase 4: Harden WebSocket behavior

- Authenticate WebSocket connections at Envoy
- Move presence and fanout state to Redis or another shared backend
- Add reconnect and token-refresh behavior
- Add graceful drain behavior for deploys

---

## 15. Final architecture summary

The final model is:

```text
MetalLB
  = gives Envoy an external IP

Envoy Gateway / Envoy
  = stateless edge proxy, TLS termination, routing, auth enforcement, WebSocket proxying

Keycloak
  = identity provider, OIDC login, JWT issuer, users/roles/groups

Redis
  = shared app state, WebSocket presence/fanout, optional rate-limit backend

Apps
  = stateless HTTP/WebSocket services behind Envoy
```

The most important design principle:

```text
Keycloak authenticates.
Envoy enforces.
Apps serve.
Redis shares state.
MetalLB exposes the entrypoint.
```
