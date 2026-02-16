
# HOME_SERVER_CONFIG_PULUMI.md
## Home Kubernetes Demo Stack (Python-Native Pulumi)
### RKE2 + MetalLB + Route 53 + cert-manager + Ingress + Dynamic DNS

This document is the **Pulumi (Python) refactor** of the earlier Terraform-based plan.

## Goals

- Ubuntu 24.04 single physical machine
- RKE2 already installed and running (Pulumi does **not** bootstrap RKE2)
- MetalLB provides a **dedicated LAN LoadBalancer IP** for ingress (Layer 2)
- Home router forwards WAN **80/443 → MetalLB ingress IP** (not the node IP)
- Home router forwards WAN **44444 → node:22** (SSH)
- Public DNS in **Route 53**
- Public IP changes handled by a **DDNS updater** that updates Route 53
- Pulumi manages k8s add-ons (MetalLB / ingress / cert-manager / optional external-dns), app ingress, and (optionally) Route 53 record *existence*

> Router port-forwarding remains manual unless your router exposes an API/provider you can automate.

---

# 1. Architecture Overview

### HTTP/S traffic flow

Internet → Router (80/443 port-forward) → **MetalLB IP** → Ingress Controller (LB Service) → Services → Pods

### SSH flow

Internet → Router:44444 → Node IP:22

### Why forward to the MetalLB IP (not the node IP)?

Forwarding 80/443 to a dedicated MetalLB IP ensures **host services on the node IP cannot be reached from WAN on 80/443** because WAN traffic never targets the node IP for those ports.

---

# 2. Network Design

Example LAN:

- Node IP: `192.168.1.10`
- MetalLB pool: `192.168.1.240-192.168.1.250`
- Ingress LB IP (reserved): `192.168.1.240`

Router forwards:

- WAN:80  → `192.168.1.240:80`
- WAN:443 → `192.168.1.240:443`
- WAN:44444 → `192.168.1.10:22`

Recommendations:

- Static DHCP reservation for the node
- Disable UPnP

---

# 3. Host Notes (Ubuntu 24.04 + Docker Compose coexistence)

You can keep Docker + docker-compose. Key rules:

- Do **not** bind Docker containers to 80/443
- Do **not** run a Docker reverse-proxy on 80/443
- Let Kubernetes ingress own 80/443 via the MetalLB IP

Sanity checks:

```bash
sudo ss -tulpn | grep -E ':80|:443' || true
```

Optional firewall baseline:

```bash
sudo ufw default deny incoming
sudo ufw allow 22/tcp
```

---

# 4. RKE2 (Out of Scope for Pulumi)

Pulumi assumes your kubeconfig works on the server where you run `pulumi up`.

Typical RKE2 kubeconfig path:

- `/etc/rancher/rke2/rke2.yaml`

Copy it to your user kubeconfig:

```bash
sudo mkdir -p ~/.kube
sudo cp /etc/rancher/rke2/rke2.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
kubectl get nodes
```

---

# 5. Route 53 Ownership Model

### Option A (recommended): Pulumi owns record *existence*, DDNS owns record *value*
- Pulumi creates the `A` record (TTL=60) so `pulumi destroy` deletes it
- A systemd timer updates the A record value to the current public IP

This is ideal for dynamic home IPs and clean teardown.

---

# 6. Let’s Encrypt via cert-manager (DNS-01 + Route 53)

Use **DNS-01** validation for reliability with dynamic IPs:

- No dependency on port 80 for ACME validation
- cert-manager creates temporary Route 53 TXT records

---

# 7. Pulumi Repository Sketch

```
repo-root/
├── HOME_SERVER_CONFIG_PULUMI.md
├── README.md
├── .gitignore
├── requirements.txt
├── Pulumi.yaml
├── Pulumi.home.yaml
├── src/
│   ├── settings.py
│   ├── __main__.py
│   └── infra/
│       ├── k8s_provider.py
│       ├── aws_provider.py
│       ├── metallb.py
│       ├── ingress.py
│       ├── cert_manager.py
│       └── dns.py
└── scripts/
    ├── update_route53_ddns.py
    ├── route53-ddns.service
    └── route53-ddns.timer
```

---

# 8. Dependencies

`requirements.txt`:

```txt
pulumi>=3.0.0
pulumi-kubernetes>=4.0.0
pulumi-aws>=6.0.0
pydantic>=2.0.0
pydantic-settings>=2.0.0
boto3>=1.28.0
requests>=2.31.0
```

---

# 9. Pydantic Settings (Idiomatic env-driven config)

```python
# src/settings.py
from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict

class Settings(BaseSettings):
    model_config = SettingsConfigDict(extra="ignore")

    # Kubernetes
    kubeconfig: str = Field(default="~/.kube/config", alias="KUBECONFIG")

    # AWS / Route 53
    aws_region: str = Field(default="us-east-1", alias="AWS_REGION")
    aws_access_key_id: str = Field(alias="AWS_ACCESS_KEY_ID")
    aws_secret_access_key: str = Field(alias="AWS_SECRET_ACCESS_KEY")
    route53_zone_id: str = Field(alias="ROUTE53_ZONE_ID")
    demo_fqdn: str = Field(default="demo.resolvefintech.com", alias="DEMO_FQDN")

    # MetalLB / Ingress
    metallb_pool: str = Field(default="192.168.1.240-192.168.1.250", alias="METALLB_POOL")
    ingress_lb_ip: str = Field(default="192.168.1.240", alias="INGRESS_LB_IP")

    # ACME
    acme_email: str = Field(alias="ACME_EMAIL")
    acme_server: str = Field(default="https://acme-v02.api.letsencrypt.org/directory", alias="ACME_SERVER")

def get_settings() -> Settings:
    return Settings()
```

Minimum env vars to export before `pulumi up`:

```bash
export AWS_REGION="us-east-1"
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
export ROUTE53_ZONE_ID="Z123..."
export ACME_EMAIL="you@resolvefintech.com"

export DEMO_FQDN="demo.resolvefintech.com"
export METALLB_POOL="192.168.1.240-192.168.1.250"
export INGRESS_LB_IP="192.168.1.240"
# optional:
# export KUBECONFIG="~/.kube/config"
```

---

# 10. IAM Policy (Least privilege for Route 53 changes)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ChangeRecordsInZone",
      "Effect": "Allow",
      "Action": ["route53:ChangeResourceRecordSets"],
      "Resource": "arn:aws:route53:::hostedzone/YOUR_HOSTED_ZONE_ID"
    },
    {
      "Sid": "ReadZonesAndRecords",
      "Effect": "Allow",
      "Action": ["route53:ListHostedZones", "route53:ListResourceRecordSets"],
      "Resource": "*"
    }
  ]
}
```

---

# 11. Pulumi Core Implementation Sketch

You’ll typically implement:

- MetalLB Helm release + CRs (IPAddressPool + L2Advertisement)
- Ingress controller Helm release (Traefik suggested) with:
  - `service.type=LoadBalancer`
  - `service.spec.loadBalancerIP=INGRESS_LB_IP`
- cert-manager Helm release with CRDs
- Route 53 DNS-01 ClusterIssuer using a Secret for AWS secret access key
- Route 53 `A` record existence (optional) so `pulumi destroy` removes it

---

# 12. Dynamic DNS Updater (systemd timer)

Place `scripts/update_route53_ddns.py` at `/usr/local/bin/update_route53_ddns.py` and install the service/timer units.

Script:

```python
#!/usr/bin/env python3
import os
import requests
import boto3

ZONE_ID = os.environ["ROUTE53_ZONE_ID"]
FQDN = os.environ.get("DEMO_FQDN", "demo.resolvefintech.com")
TTL = int(os.environ.get("DEMO_TTL", "60"))

def public_ip() -> str:
    return requests.get("https://api.ipify.org", timeout=10).text.strip()

def current_ip(client) -> str | None:
    resp = client.list_resource_record_sets(
        HostedZoneId=ZONE_ID,
        StartRecordName=FQDN,
        StartRecordType="A",
        MaxItems="1",
    )
    rrsets = resp.get("ResourceRecordSets", [])
    if not rrsets:
        return None
    rr = rrsets[0]
    if rr.get("Name", "").rstrip(".") != FQDN.rstrip(".") or rr.get("Type") != "A":
        return None
    recs = rr.get("ResourceRecords", [])
    return recs[0]["Value"] if recs else None

def upsert(client, ip: str):
    client.change_resource_record_sets(
        HostedZoneId=ZONE_ID,
        ChangeBatch={
            "Changes": [
                {
                    "Action": "UPSERT",
                    "ResourceRecordSet": {
                        "Name": FQDN,
                        "Type": "A",
                        "TTL": TTL,
                        "ResourceRecords": [{"Value": ip}],
                    },
                }
            ]
        },
    )

def main():
    client = boto3.client("route53")
    ip = public_ip()
    old = current_ip(client)
    if old == ip:
        print(f"[ddns] no change: {ip}")
        return
    print(f"[ddns] updating {FQDN}: {old} -> {ip}")
    upsert(client, ip)

if __name__ == "__main__":
    main()
```

`/etc/systemd/system/route53-ddns.service`:

```ini
[Unit]
Description=Route 53 DDNS updater for demo.resolvefintech.com
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
Environment=ROUTE53_ZONE_ID=Z123...
Environment=DEMO_FQDN=demo.resolvefintech.com
Environment=DEMO_TTL=60
Environment=AWS_REGION=us-east-1
Environment=AWS_ACCESS_KEY_ID=...
Environment=AWS_SECRET_ACCESS_KEY=...
ExecStart=/usr/bin/python3 /usr/local/bin/update_route53_ddns.py
```

`/etc/systemd/system/route53-ddns.timer`:

```ini
[Unit]
Description=Run Route 53 DDNS updater every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
```

Enable:

```bash
sudo install -m 0755 scripts/update_route53_ddns.py /usr/local/bin/update_route53_ddns.py
sudo systemctl daemon-reload
sudo systemctl enable --now route53-ddns.timer
```

---

# 13. Operations

Apply:

```bash
pulumi stack init home   # first time only
pulumi up
```

Destroy:

```bash
pulumi destroy
```

---

END OF DOCUMENT

---

# 16. Implementation Principles (Explicit Requirements)

This project is intentionally **Python-native**, with a small set of non-negotiable engineering constraints so the system is easy to operate, repeat, and audit.

## 16.1 All Python logic is implemented as Click CLI tools

- Every operational action is a **Click** command (or subcommand) under a single CLI entrypoint, e.g. `homek8s`.
- No “loose scripts” are invoked directly for core operations (except systemd calling the DDNS CLI command).
- Example command groups (suggested):

```
homek8s env    (validate/print effective config)
homek8s host   (install prerequisites via subprocess; optional)
homek8s rke2   (install/configure/start/stop status; optional)
homek8s pulumi (up/destroy/preview)
homek8s dns    (ddns update, create/delete record checks)
homek8s k8s    (health checks, wait-for-ready helpers)
```

## 16.2 All commands are declarative and idempotent

- “Apply” commands converge the system to a target state.
- Re-running commands must be safe and produce no unintended changes.
- Patterns to follow:
  - Ensure resource existence via UPSERT/create-if-missing
  - Compare current state before mutating (e.g. Route 53 current A record vs desired)
  - Use deterministic naming for k8s resources and AWS resources
  - Pin Helm chart versions and image tags for repeatability

## 16.3 Concurrency is handled via asyncio

- Any command that performs multiple independent operations (e.g. checking multiple endpoints, waiting for multiple resources, applying multiple steps that can run in parallel) should use **asyncio**.
- Concurrency goals:
  - Faster feedback (parallel readiness checks)
  - Controlled fan-out (use semaphores to cap concurrency)
  - Clear cancellation semantics (CTRL+C cancels async tasks cleanly)

Recommended internal structure:

- Click command → calls `asyncio.run(main_async(...))`
- Internal helpers are `async def` and use `await` for I/O-bound work

## 16.4 Environment configuration can be managed via an awaitable subprocess

- Host-level setup is handled by an **awaitable subprocess layer**.
- This is allowed and encouraged for:
  - Installing RKE2 (optional, if you want the CLI to manage it)
  - Installing Helm / kubectl / pulumi CLI (if you choose)
  - Writing systemd units
  - Applying sysctl settings / kernel modules (if desired)

Key requirement: subprocess execution must be:

- Awaitable (`asyncio.create_subprocess_exec` / `asyncio.create_subprocess_shell`)
- Idempotent (check before you install/configure)
- Transparent (log commands, capture stdout/stderr, return non-zero as errors)

Example model (high-level):

- `homek8s host ensure-tools` → ensures binaries exist at desired versions
- `homek8s rke2 ensure` → ensures RKE2 installed/configured/running
- `homek8s dns ensure-timer` → ensures systemd timer installed/enabled

## 16.5 There is always a single Pydantic BaseSettings object parsed on every call

- Every Click command must begin by constructing **one and only one** settings object:

```python
from settings import Settings
settings = Settings()
```

- That `Settings()` object is passed down through all functions.
- No global mutable config; no reading env vars ad-hoc in random modules.
- The only acceptable configuration source is:
  - environment variables (and optionally `.env` if you enable it in SettingsConfigDict)

This guarantees:

- reproducible behavior
- centralized validation
- consistent defaults
- easy debugging (`homek8s env show` prints effective config)

## 16.6 Suggested repo additions to support these requirements

Add these files:

```
src/cli/
  __init__.py
  main.py          # click group
  env.py           # env commands
  host.py          # subprocess-based host tools
  rke2.py          # optional rke2 ensure/start/stop/status
  pulumi_cmd.py    # wrapper for pulumi up/destroy using subprocess
  dns.py           # ddns update + ensure timer
  k8s.py           # kubectl/health checks
src/lib/
  subprocess.py    # async subprocess runner
  concurrency.py   # semaphores, gather helpers
  idempotency.py   # state comparisons
```

