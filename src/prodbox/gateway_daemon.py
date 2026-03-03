"""Distributed gateway daemon with mTLS handshake and duplex event sockets."""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import hmac
import json
import ssl
import sys
import uuid
from collections.abc import Mapping
from contextlib import suppress
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Literal, Protocol, cast

import httpx

ChannelName = Literal["mesh", "gateway"]


def _utc_now() -> datetime:
    """Get current UTC timestamp."""
    return datetime.now(UTC)


def _to_utc_iso(value: datetime) -> str:
    """Convert datetime to RFC3339 UTC string."""
    return value.astimezone(UTC).isoformat()


def _parse_utc(value: str) -> datetime:
    """Parse RFC3339 UTC timestamp."""
    parsed = datetime.fromisoformat(value)
    return parsed.astimezone(UTC)


def _parse_json_object(text: str) -> dict[str, object] | None:
    """Parse JSON object text into a typed mapping."""
    try:
        parsed = cast(object, json.loads(text))
    except ValueError:
        return None
    if not isinstance(parsed, dict):
        return None
    parsed_mapping = cast(Mapping[object, object], parsed)
    result: dict[str, object] = {}
    for key, value in parsed_mapping.items():
        result[str(key)] = value
    return result


def _as_object_mapping(value: object) -> Mapping[object, object] | None:
    """Return value as object mapping if compatible."""
    if not isinstance(value, Mapping):
        return None
    return cast(Mapping[object, object], value)


def _as_object_sequence(value: object) -> tuple[object, ...] | None:
    """Return value as immutable object sequence if compatible."""
    if not isinstance(value, list):
        return None
    value_list = cast(list[object], value)
    return tuple(value_list)


def _read_optional_float(value: object, default: float) -> float:
    """Read optional float value with safe fallback."""
    if value is None:
        return default
    if isinstance(value, float):
        return value
    if isinstance(value, int):
        return float(value)
    if isinstance(value, str):
        return float(value)
    raise ValueError("Expected float-like value")


class _PeerCertProvider(Protocol):
    """Minimal protocol for TLS peer certificate retrieval."""

    def getpeercert(self) -> object:
        """Return peer certificate object."""


@dataclass(frozen=True)
class PeerEndpoint:
    """Peer networking endpoint."""

    node_id: str
    stable_dns_name: str
    rest_host: str
    rest_port: int
    socket_host: str
    socket_port: int

    @property
    def rest_url(self) -> str:
        """Build peer REST URL."""
        return f"https://{self.rest_host}:{self.rest_port}"


@dataclass(frozen=True)
class GatewayRule:
    """Deterministic ranked failover rule."""

    ranked_nodes: tuple[str, ...]
    heartbeat_timeout_seconds: int

    @staticmethod
    def from_dict(raw: Mapping[str, object]) -> GatewayRule:
        """Build validated GatewayRule from mapping."""
        ranked_nodes_obj = raw.get("ranked_nodes")
        timeout_obj = raw.get("heartbeat_timeout_seconds")
        if not isinstance(ranked_nodes_obj, list):
            raise ValueError("gateway_rule.ranked_nodes must be a list")
        ranked_nodes = tuple(str(v) for v in ranked_nodes_obj)
        if len(ranked_nodes) == 0:
            raise ValueError("gateway_rule.ranked_nodes must be non-empty")
        if not isinstance(timeout_obj, int):
            raise ValueError("gateway_rule.heartbeat_timeout_seconds must be an int")
        if timeout_obj < 1:
            raise ValueError("gateway_rule.heartbeat_timeout_seconds must be >= 1")
        if len(set(ranked_nodes)) != len(ranked_nodes):
            raise ValueError("gateway_rule.ranked_nodes must be unique")
        return GatewayRule(
            ranked_nodes=ranked_nodes,
            heartbeat_timeout_seconds=timeout_obj,
        )


@dataclass(frozen=True)
class Orders:
    """Declarative global orders document."""

    version_utc: int
    nodes: tuple[PeerEndpoint, ...]
    gateway_rule: GatewayRule

    @staticmethod
    def from_dict(raw: Mapping[str, object]) -> Orders:
        """Parse and validate orders from mapping."""
        version_obj = raw.get("version_utc")
        nodes_obj = raw.get("nodes")
        rule_obj = raw.get("gateway_rule")

        if not isinstance(version_obj, int):
            raise ValueError("orders.version_utc must be an int")
        nodes_list = _as_object_sequence(nodes_obj)
        if nodes_list is None:
            raise ValueError("orders.nodes must be a list")
        rule_mapping = _as_object_mapping(rule_obj)
        if rule_mapping is None:
            raise ValueError("orders.gateway_rule must be an object")
        rule_dict = {str(key): value for key, value in rule_mapping.items()}

        nodes: list[PeerEndpoint] = []
        for raw_node in nodes_list:
            node_mapping = _as_object_mapping(raw_node)
            if node_mapping is None:
                raise ValueError("orders.nodes entries must be objects")
            node_dict = {str(key): value for key, value in node_mapping.items()}
            node_id_obj = node_dict.get("node_id")
            stable_dns_name_obj = node_dict.get("stable_dns_name")
            rest_host_obj = node_dict.get("rest_host")
            rest_port_obj = node_dict.get("rest_port")
            socket_host_obj = node_dict.get("socket_host")
            socket_port_obj = node_dict.get("socket_port")

            if not isinstance(node_id_obj, str) or not node_id_obj:
                raise ValueError("orders.nodes[].node_id is required")
            if not isinstance(stable_dns_name_obj, str) or not stable_dns_name_obj:
                raise ValueError("orders.nodes[].stable_dns_name is required")
            if not isinstance(rest_host_obj, str) or not rest_host_obj:
                raise ValueError("orders.nodes[].rest_host is required")
            if not isinstance(socket_host_obj, str) or not socket_host_obj:
                raise ValueError("orders.nodes[].socket_host is required")
            if not isinstance(rest_port_obj, int):
                raise ValueError("orders.nodes[].rest_port must be int")
            if not isinstance(socket_port_obj, int):
                raise ValueError("orders.nodes[].socket_port must be int")

            nodes.append(
                PeerEndpoint(
                    node_id=node_id_obj,
                    stable_dns_name=stable_dns_name_obj,
                    rest_host=rest_host_obj,
                    rest_port=rest_port_obj,
                    socket_host=socket_host_obj,
                    socket_port=socket_port_obj,
                )
            )

        node_ids: tuple[str, ...] = tuple(node.node_id for node in nodes)
        node_id_set: frozenset[str] = frozenset(node_ids)
        if len(node_id_set) != len(node_ids):
            raise ValueError("orders.nodes node_id values must be unique")

        gateway_rule = GatewayRule.from_dict(rule_dict)
        ranked_node_set: frozenset[str] = frozenset(gateway_rule.ranked_nodes)
        if not ranked_node_set.issubset(node_id_set):
            raise ValueError("gateway_rule.ranked_nodes must be a subset of orders.nodes.node_id")

        return Orders(
            version_utc=version_obj,
            nodes=tuple(nodes),
            gateway_rule=gateway_rule,
        )

    def peer_by_id(self, node_id: str) -> PeerEndpoint | None:
        """Find node by id."""
        for node in self.nodes:
            if node.node_id == node_id:
                return node
        return None

    @property
    def node_ids(self) -> frozenset[str]:
        """Get node ids as immutable set."""
        return frozenset(node.node_id for node in self.nodes)


@dataclass(frozen=True)
class SignedEvent:
    """Signed event message for append-only replication."""

    event_hash: str
    emitter_node_id: str
    timestamp_utc: str
    event_type: str
    payload_json: str
    signature_hex: str

    def canonical_unsigned_json(self) -> str:
        """Get canonical unsigned event payload."""
        payload: dict[str, str] = {
            "emitter_node_id": self.emitter_node_id,
            "timestamp_utc": self.timestamp_utc,
            "event_type": self.event_type,
            "payload_json": self.payload_json,
        }
        return json.dumps(payload, sort_keys=True, separators=(",", ":"))

    def to_wire_dict(self) -> dict[str, str]:
        """Encode for wire transfer."""
        return {
            "event_hash": self.event_hash,
            "emitter_node_id": self.emitter_node_id,
            "timestamp_utc": self.timestamp_utc,
            "event_type": self.event_type,
            "payload_json": self.payload_json,
            "signature_hex": self.signature_hex,
        }

    @staticmethod
    def from_wire_dict(raw: Mapping[str, object]) -> SignedEvent:
        """Decode event from wire mapping."""
        return SignedEvent(
            event_hash=str(raw.get("event_hash")),
            emitter_node_id=str(raw.get("emitter_node_id")),
            timestamp_utc=str(raw.get("timestamp_utc")),
            event_type=str(raw.get("event_type")),
            payload_json=str(raw.get("payload_json")),
            signature_hex=str(raw.get("signature_hex")),
        )

    @staticmethod
    def create(
        *,
        emitter_node_id: str,
        event_type: str,
        payload: Mapping[str, object],
        event_key: str,
    ) -> SignedEvent:
        """Create signed event from payload."""
        timestamp_utc = _to_utc_iso(_utc_now())
        payload_json = json.dumps(payload, sort_keys=True, separators=(",", ":"))
        unsigned_payload: dict[str, str] = {
            "emitter_node_id": emitter_node_id,
            "timestamp_utc": timestamp_utc,
            "event_type": event_type,
            "payload_json": payload_json,
        }
        unsigned = json.dumps(
            unsigned_payload,
            sort_keys=True,
            separators=(",", ":"),
        )
        event_hash = hashlib.sha256(unsigned.encode("utf-8")).hexdigest()
        signature_hex = hmac.new(
            event_key.encode("utf-8"),
            event_hash.encode("utf-8"),
            hashlib.sha256,
        ).hexdigest()
        return SignedEvent(
            event_hash=event_hash,
            emitter_node_id=emitter_node_id,
            timestamp_utc=timestamp_utc,
            event_type=event_type,
            payload_json=payload_json,
            signature_hex=signature_hex,
        )

    def validate(self, *, event_keys: Mapping[str, str]) -> bool:
        """Validate event hash and signature."""
        try:
            _parse_utc(self.timestamp_utc)
        except ValueError:
            return False

        expected_hash = hashlib.sha256(self.canonical_unsigned_json().encode("utf-8")).hexdigest()
        if expected_hash != self.event_hash:
            return False

        key = event_keys.get(self.emitter_node_id)
        if key is None:
            return False
        expected_signature = hmac.new(
            key.encode("utf-8"),
            self.event_hash.encode("utf-8"),
            hashlib.sha256,
        ).hexdigest()
        return hmac.compare_digest(expected_signature, self.signature_hex)


@dataclass(frozen=True)
class CommitLog:
    """Append-only commit log with idempotent insert."""

    events: tuple[SignedEvent, ...] = ()

    def contains(self, event_hash: str) -> bool:
        """Check if event exists."""
        return any(event.event_hash == event_hash for event in self.events)

    def append_if_new(self, event: SignedEvent) -> CommitLog:
        """Append event if hash not yet present."""
        if self.contains(event.event_hash):
            return self
        return CommitLog(events=self.events + (event,))

    def sorted_events(self) -> tuple[SignedEvent, ...]:
        """Get events in deterministic order."""

        def _sort_key(event: SignedEvent) -> tuple[str, str]:
            return event.timestamp_utc, event.event_hash

        return tuple(
            sorted(
                self.events,
                key=_sort_key,
            )
        )

    def latest_timestamp(self) -> datetime | None:
        """Get latest event timestamp."""
        if len(self.events) == 0:
            return None
        timestamps = tuple(_parse_utc(event.timestamp_utc) for event in self.events)
        return max(timestamps)


@dataclass(frozen=True)
class ConnectionKey:
    """Unique key for managed sockets."""

    peer_node_id: str
    channel: ChannelName


@dataclass(frozen=True)
class ManagedConnection:
    """Runtime socket connection."""

    key: ConnectionKey
    connection_id: str
    initiator_node_id: str
    reader: asyncio.StreamReader
    writer: asyncio.StreamWriter
    established_at_utc: datetime
    incoming: bool
    send_lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    @property
    def alive(self) -> bool:
        """Whether the writer is still open."""
        return not self.writer.is_closing()

    async def close(self) -> None:
        """Close writer safely."""
        if self.writer.is_closing():
            return
        self.writer.close()
        await self.writer.wait_closed()


class ConnectionRegistry:
    """Race-safe connection registry with deterministic deduplication."""

    def __init__(self, local_node_id: str) -> None:
        self._local_node_id = local_node_id
        self._connections: dict[ConnectionKey, ManagedConnection] = {}
        self._lock = asyncio.Lock()

    def _prefers(
        self,
        *,
        candidate: ManagedConnection,
        existing: ManagedConnection,
    ) -> bool:
        pair_min = min(self._local_node_id, candidate.key.peer_node_id)
        candidate_pref = 0 if candidate.initiator_node_id == pair_min else 1
        existing_pref = 0 if existing.initiator_node_id == pair_min else 1
        candidate_rank = (candidate_pref, candidate.connection_id)
        existing_rank = (existing_pref, existing.connection_id)
        return candidate_rank < existing_rank

    async def register_candidate(self, candidate: ManagedConnection) -> bool:
        """Register a candidate connection and deduplicate by key."""
        async with self._lock:
            existing = self._connections.get(candidate.key)
            if existing is None:
                self._connections[candidate.key] = candidate
                return True

            if self._prefers(candidate=candidate, existing=existing):
                self._connections[candidate.key] = candidate
                await existing.close()
                return True

            await candidate.close()
            return False

    async def remove(self, key: ConnectionKey, connection_id: str) -> None:
        """Remove active connection by key and id."""
        async with self._lock:
            existing = self._connections.get(key)
            if existing is None:
                return
            if existing.connection_id != connection_id:
                return
            self._connections.pop(key, None)

    async def close_all(self) -> None:
        """Close all connections."""
        async with self._lock:
            current = tuple(self._connections.values())
            self._connections.clear()
        for conn in current:
            await conn.close()

    async def get(self, key: ConnectionKey) -> ManagedConnection | None:
        """Get connection by key."""
        async with self._lock:
            return self._connections.get(key)

    async def values(self) -> tuple[ManagedConnection, ...]:
        """Get snapshot of managed connections."""
        async with self._lock:
            return tuple(self._connections.values())

    async def keys(self) -> tuple[ConnectionKey, ...]:
        """Get snapshot of connection keys."""
        async with self._lock:
            return tuple(self._connections.keys())


@dataclass(frozen=True)
class DaemonConfig:
    """Gateway daemon runtime configuration."""

    node_id: str
    cert_file: Path
    key_file: Path
    ca_file: Path
    orders_file: Path
    event_keys: Mapping[str, str]
    heartbeat_interval_seconds: float = 1.0
    reconnect_interval_seconds: float = 1.0
    sync_interval_seconds: float = 5.0
    dns_write_gate: DnsWriteGate | None = None

    @staticmethod
    def from_json_file(path: Path) -> DaemonConfig:
        """Parse daemon config from JSON file."""
        raw = _parse_json_object(path.read_text(encoding="utf-8"))
        if raw is None:
            raise ValueError("gateway daemon config must be a JSON object")

        node_id = str(raw.get("node_id"))
        cert_file = Path(str(raw.get("cert_file")))
        key_file = Path(str(raw.get("key_file")))
        ca_file = Path(str(raw.get("ca_file")))
        orders_file = Path(str(raw.get("orders_file")))
        event_keys_obj = raw.get("event_keys")
        if not isinstance(event_keys_obj, dict):
            raise ValueError("event_keys must be a JSON object")

        event_keys: dict[str, str] = {}
        for key, value in event_keys_obj.items():
            event_keys[str(key)] = str(value)

        heartbeat_interval_seconds = _read_optional_float(
            raw.get("heartbeat_interval_seconds"),
            1.0,
        )
        reconnect_interval_seconds = _read_optional_float(
            raw.get("reconnect_interval_seconds"),
            1.0,
        )
        sync_interval_seconds = _read_optional_float(
            raw.get("sync_interval_seconds"),
            5.0,
        )

        dns_gate_raw = raw.get("dns_write_gate")
        dns_write_gate: DnsWriteGate | None = None
        match dns_gate_raw:
            case dict() as gate_dict:
                dns_write_gate = DnsWriteGate(
                    zone_id=str(gate_dict.get("zone_id")),
                    fqdn=str(gate_dict.get("fqdn")),
                    ttl=int(str(gate_dict.get("ttl", 300))),
                    aws_region=str(gate_dict.get("aws_region")),
                    aws_access_key_id=str(gate_dict.get("aws_access_key_id")),
                    aws_secret_access_key=str(gate_dict.get("aws_secret_access_key")),
                )
            case None:
                pass

        if not node_id:
            raise ValueError("node_id is required")
        return DaemonConfig(
            node_id=node_id,
            cert_file=cert_file,
            key_file=key_file,
            ca_file=ca_file,
            orders_file=orders_file,
            event_keys=event_keys,
            heartbeat_interval_seconds=heartbeat_interval_seconds,
            reconnect_interval_seconds=reconnect_interval_seconds,
            sync_interval_seconds=sync_interval_seconds,
            dns_write_gate=dns_write_gate,
        )


class DnsWriteClient(Protocol):
    """Protocol for DNS write operations (injectable for testing)."""

    async def fetch_public_ip(self) -> str:
        """Fetch the current public IP address."""

    async def update_route53_record(
        self,
        *,
        zone_id: str,
        fqdn: str,
        ip_address: str,
        ttl: int,
        aws_region: str,
        aws_access_key_id: str,
        aws_secret_access_key: str,
    ) -> bool:
        """Update a Route 53 A record. Returns True on success."""


@dataclass(frozen=True)
class DnsWriteGate:
    """Configuration for DNS write gating behind gateway ownership."""

    zone_id: str
    fqdn: str
    ttl: int
    aws_region: str
    aws_access_key_id: str
    aws_secret_access_key: str


@dataclass(frozen=True)
class Route53DnsWriteClient:
    """Real Route 53 DNS write client backed by boto3."""

    _aws_access_key_id: str
    _aws_secret_access_key: str
    _aws_region: str

    @staticmethod
    def from_gate(gate: DnsWriteGate) -> Route53DnsWriteClient:
        """Create client from DnsWriteGate configuration."""
        return Route53DnsWriteClient(
            _aws_access_key_id=gate.aws_access_key_id,
            _aws_secret_access_key=gate.aws_secret_access_key,
            _aws_region=gate.aws_region,
        )

    async def fetch_public_ip(self) -> str:
        """Fetch public IP from checkip.amazonaws.com."""
        async with httpx.AsyncClient(timeout=10.0) as client:
            response = await client.get("https://checkip.amazonaws.com")
            response.raise_for_status()
            return response.text.strip()

    async def update_route53_record(
        self,
        *,
        zone_id: str,
        fqdn: str,
        ip_address: str,
        ttl: int,
        aws_region: str,
        aws_access_key_id: str,
        aws_secret_access_key: str,
    ) -> bool:
        """UPSERT A record via Route 53 change_resource_record_sets."""
        import asyncio

        import boto3

        def _do_upsert() -> bool:
            session = boto3.Session(
                aws_access_key_id=aws_access_key_id,
                aws_secret_access_key=aws_secret_access_key,
                region_name=aws_region,
            )
            r53 = session.client("route53")
            change_batch: dict[str, object] = {
                "Comment": f"Gateway DDNS update: {fqdn} -> {ip_address}",
                "Changes": [
                    {
                        "Action": "UPSERT",
                        "ResourceRecordSet": {
                            "Name": fqdn,
                            "Type": "A",
                            "TTL": ttl,
                            "ResourceRecords": [{"Value": ip_address}],
                        },
                    },
                ],
            }
            r53.change_resource_record_sets(
                HostedZoneId=zone_id,
                ChangeBatch=change_batch,
            )
            return True

        return await asyncio.to_thread(_do_upsert)


class GatewayDaemon:
    """Long-running distributed gateway daemon."""

    def __init__(
        self,
        config: DaemonConfig,
        *,
        dns_client: DnsWriteClient | None = None,
    ) -> None:
        self._config = config
        self._orders = self._load_orders(config.orders_file)
        self._orders_lock = asyncio.Lock()
        if self._orders.peer_by_id(config.node_id) is None:
            raise ValueError(f"Local node_id '{config.node_id}' not found in orders")

        self._registry = ConnectionRegistry(local_node_id=config.node_id)
        self._commit_log = CommitLog()
        self._commit_log_lock = asyncio.Lock()
        self._last_heartbeat_seen: dict[str, datetime] = {}
        self._last_heartbeat_lock = asyncio.Lock()

        self._rest_server: asyncio.AbstractServer | None = None
        self._event_server: asyncio.AbstractServer | None = None
        self._tasks: list[asyncio.Task[None]] = []
        self._running = False
        self._gateway_owner: str = config.node_id
        self._gateway_lock = asyncio.Lock()

        # DNS client: injected mock takes precedence, otherwise auto-create from gate
        resolved_client: DnsWriteClient | None = dns_client
        if resolved_client is None and config.dns_write_gate is not None:
            resolved_client = Route53DnsWriteClient.from_gate(config.dns_write_gate)
        self._dns_client = resolved_client
        self._last_dns_write_ip: str | None = None

    @staticmethod
    def _load_orders(path: Path) -> Orders:
        raw = _parse_json_object(path.read_text(encoding="utf-8"))
        if raw is None:
            raise ValueError("orders file must be a JSON object")
        return Orders.from_dict(raw)

    def _server_ssl_context(self) -> ssl.SSLContext:
        context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        context.load_cert_chain(
            certfile=str(self._config.cert_file),
            keyfile=str(self._config.key_file),
        )
        context.load_verify_locations(cafile=str(self._config.ca_file))
        context.verify_mode = ssl.CERT_REQUIRED
        context.check_hostname = False
        return context

    def _client_ssl_context(self) -> ssl.SSLContext:
        context = ssl.create_default_context(
            ssl.Purpose.SERVER_AUTH,
            cafile=str(self._config.ca_file),
        )
        context.load_cert_chain(
            certfile=str(self._config.cert_file),
            keyfile=str(self._config.key_file),
        )
        context.check_hostname = False
        return context

    async def start(self) -> None:
        """Start daemon servers and background loops."""
        if self._running:
            return
        self._running = True
        local = self._local_endpoint

        server_ctx = self._server_ssl_context()
        self._rest_server = await asyncio.start_server(
            self._handle_rest_connection,
            host=local.rest_host,
            port=local.rest_port,
            ssl=server_ctx,
        )
        self._event_server = await asyncio.start_server(
            self._handle_event_connection,
            host=local.socket_host,
            port=local.socket_port,
            ssl=server_ctx,
        )

        self._tasks.append(asyncio.create_task(self._heartbeat_loop()))
        self._tasks.append(asyncio.create_task(self._connection_reconcile_loop()))
        self._tasks.append(asyncio.create_task(self._sync_loop()))
        self._tasks.append(asyncio.create_task(self._gateway_loop()))
        self._tasks.append(asyncio.create_task(self._dns_write_loop()))

    async def stop(self) -> None:
        """Stop daemon and close resources."""
        self._running = False

        for task in self._tasks:
            task.cancel()
        if len(self._tasks) > 0:
            await asyncio.gather(*self._tasks, return_exceptions=True)
        self._tasks.clear()

        if self._rest_server is not None:
            self._rest_server.close()
            await self._rest_server.wait_closed()
            self._rest_server = None
        if self._event_server is not None:
            self._event_server.close()
            await self._event_server.wait_closed()
            self._event_server = None

        await self._registry.close_all()

    @property
    def _local_endpoint(self) -> PeerEndpoint:
        local = self._orders.peer_by_id(self._config.node_id)
        if local is None:
            raise RuntimeError(f"Local node '{self._config.node_id}' missing from orders")
        return local

    async def emit_event(self, event_type: str, payload: Mapping[str, object]) -> SignedEvent:
        """Emit a locally signed event and broadcast."""
        key = self._config.event_keys.get(self._config.node_id)
        if key is None:
            raise RuntimeError(f"Missing event signing key for node '{self._config.node_id}'")
        event = SignedEvent.create(
            emitter_node_id=self._config.node_id,
            event_type=event_type,
            payload=payload,
            event_key=key,
        )
        inserted = await self._append_event_if_valid(event)
        if inserted:
            await self._broadcast_event(event, exclude_connection_id=None)
        return event

    async def active_connection_keys(self) -> tuple[ConnectionKey, ...]:
        """Get active connection keys."""
        return await self._registry.keys()

    async def log_event_hashes(self) -> tuple[str, ...]:
        """Get deterministic event hashes snapshot."""
        async with self._commit_log_lock:
            return tuple(event.event_hash for event in self._commit_log.sorted_events())

    async def gateway_owner(self) -> str:
        """Get current computed gateway owner."""
        async with self._gateway_lock:
            return self._gateway_owner

    async def has_claim_from(self, node_id: str) -> bool:
        """Check if a GatewayClaim event from a node exists in the commit log."""
        async with self._commit_log_lock:
            return any(
                event.event_type == "gateway_claim" and event.emitter_node_id == node_id
                for event in self._commit_log.events
            )

    async def has_active_claim_from(self, node_id: str) -> bool:
        """Check if node has an active GatewayClaim with no subsequent GatewayYield.

        Mirrors TLA+ CanWriteDns guard: HasClaim(n) /\\ ~HasYieldAfterLastClaim(n).
        """
        async with self._commit_log_lock:
            sorted_events = self._commit_log.sorted_events()

        last_claim_index: int | None = None
        for i, event in enumerate(sorted_events):
            if event.event_type == "gateway_claim" and event.emitter_node_id == node_id:
                last_claim_index = i

        if last_claim_index is None:
            return False

        for event in sorted_events[last_claim_index + 1 :]:
            if event.event_type == "gateway_yield" and event.emitter_node_id == node_id:
                return False

        return True

    async def events_by_type(self, event_type: str) -> tuple[SignedEvent, ...]:
        """Get all events of a given type from the commit log."""
        async with self._commit_log_lock:
            return tuple(
                event
                for event in self._commit_log.sorted_events()
                if event.event_type == event_type
            )

    async def promote_orders_if_newer(self, orders: Orders) -> bool:
        """Promote active orders if timestamp increases."""
        async with self._orders_lock:
            if orders.version_utc <= self._orders.version_utc:
                return False
            self._orders = orders
            return True

    async def _append_event_if_valid(self, event: SignedEvent) -> bool:
        if not event.validate(event_keys=self._config.event_keys):
            return False

        async with self._commit_log_lock:
            before_count = len(self._commit_log.events)
            self._commit_log = self._commit_log.append_if_new(event)
            after_count = len(self._commit_log.events)
        inserted = after_count > before_count
        if not inserted:
            return False

        if event.event_type == "heartbeat":
            await self._record_heartbeat(event.emitter_node_id, _parse_utc(event.timestamp_utc))
        elif event.event_type == "orders_published":
            payload_raw = _parse_json_object(event.payload_json)
            if payload_raw is not None:
                with suppress(ValueError):
                    promoted = await self.promote_orders_if_newer(Orders.from_dict(payload_raw))
                    if promoted:
                        await self._recompute_gateway_owner()
        elif event.event_type in ("gateway_claim", "gateway_yield", "dns_write"):
            pass
        return True

    async def _record_heartbeat(self, node_id: str, seen_at: datetime) -> None:
        async with self._last_heartbeat_lock:
            existing = self._last_heartbeat_seen.get(node_id)
            if existing is None or seen_at > existing:
                self._last_heartbeat_seen[node_id] = seen_at

    async def _get_last_heartbeat(self, node_id: str) -> datetime | None:
        async with self._last_heartbeat_lock:
            return self._last_heartbeat_seen.get(node_id)

    async def _connection_reconcile_loop(self) -> None:
        while self._running:
            with suppress(Exception):
                await self._reconcile_connections_once()
            await asyncio.sleep(self._config.reconnect_interval_seconds)

    async def _sync_loop(self) -> None:
        while self._running:
            with suppress(Exception):
                await self._broadcast_sync_requests()
            await asyncio.sleep(self._config.sync_interval_seconds)

    async def _gateway_loop(self) -> None:
        while self._running:
            await self._recompute_gateway_owner()
            await asyncio.sleep(self._config.heartbeat_interval_seconds)

    async def _heartbeat_loop(self) -> None:
        while self._running:
            with suppress(Exception):
                await self.emit_event(
                    "heartbeat",
                    {"node_id": self._config.node_id},
                )
            await asyncio.sleep(self._config.heartbeat_interval_seconds)

    async def _dns_write_loop(self) -> None:
        gate = self._config.dns_write_gate
        if gate is None:
            return
        if self._dns_client is None:
            return
        while self._running:
            with suppress(Exception):
                await self._attempt_dns_write(gate)
            await asyncio.sleep(float(gate.ttl))

    async def _attempt_dns_write(self, gate: DnsWriteGate) -> None:
        async with self._gateway_lock:
            is_owner = self._gateway_owner == self._config.node_id
        if not is_owner:
            return

        has_claim = await self.has_active_claim_from(self._config.node_id)
        if not has_claim:
            return

        if self._dns_client is None:
            return
        ip_address = await self._dns_client.fetch_public_ip()
        success = await self._dns_client.update_route53_record(
            zone_id=gate.zone_id,
            fqdn=gate.fqdn,
            ip_address=ip_address,
            ttl=gate.ttl,
            aws_region=gate.aws_region,
            aws_access_key_id=gate.aws_access_key_id,
            aws_secret_access_key=gate.aws_secret_access_key,
        )
        if success:
            self._last_dns_write_ip = ip_address
            await self.emit_event(
                "dns_write",
                {
                    "ip_address": ip_address,
                    "zone_id": gate.zone_id,
                    "fqdn": gate.fqdn,
                },
            )

    async def _reconcile_connections_once(self) -> None:
        async with self._orders_lock:
            orders = self._orders
            gateway_owner = self._gateway_owner

        peers = tuple(node for node in orders.nodes if node.node_id != self._config.node_id)
        for peer in peers:
            await self._ensure_connection(peer, channel="mesh")

        if gateway_owner != self._config.node_id:
            gateway_peer = orders.peer_by_id(gateway_owner)
            if gateway_peer is not None and gateway_peer.node_id != self._config.node_id:
                await self._ensure_connection(gateway_peer, channel="gateway")

    async def _ensure_connection(self, peer: PeerEndpoint, channel: ChannelName) -> None:
        key = ConnectionKey(peer_node_id=peer.node_id, channel=channel)
        existing = await self._registry.get(key)
        if existing is not None and existing.alive:
            return

        handshake_ok = await self._handshake(peer=peer, channel=channel)
        if not handshake_ok:
            return

        client_ctx = self._client_ssl_context()
        reader, writer = await asyncio.open_connection(
            host=peer.socket_host,
            port=peer.socket_port,
            ssl=client_ctx,
        )
        conn = ManagedConnection(
            key=key,
            connection_id=str(uuid.uuid4()),
            initiator_node_id=self._config.node_id,
            reader=reader,
            writer=writer,
            established_at_utc=_utc_now(),
            incoming=False,
        )

        await self._send_json(
            conn,
            {
                "kind": "hello",
                "node_id": self._config.node_id,
                "connection_id": conn.connection_id,
                "initiator_node_id": self._config.node_id,
                "channel": channel,
            },
        )
        accepted = await self._registry.register_candidate(conn)
        if not accepted:
            return
        asyncio.create_task(self._connection_reader_loop(conn))

    async def _handshake(self, *, peer: PeerEndpoint, channel: ChannelName) -> bool:
        payload = {
            "from_node_id": self._config.node_id,
            "channel": channel,
        }
        url = f"{peer.rest_url}/v1/handshake"
        cert_tuple = (str(self._config.cert_file), str(self._config.key_file))
        async with httpx.AsyncClient(
            verify=str(self._config.ca_file),
            cert=cert_tuple,
            timeout=5.0,
        ) as client:
            try:
                response = await client.post(url, json=payload)
            except httpx.HTTPError:
                return False
        if response.status_code != 200:
            return False
        parsed = _parse_json_object(response.text)
        if parsed is None:
            return False
        return bool(parsed.get("accepted"))

    async def _broadcast_sync_requests(self) -> None:
        snapshot = await self._registry.values()
        hashes = await self.log_event_hashes()
        message = {
            "kind": "sync_request",
            "known_event_hashes": list(hashes),
            "from_node_id": self._config.node_id,
        }
        for conn in snapshot:
            if conn.alive:
                await self._send_json(conn, message)

    async def _broadcast_event(
        self,
        event: SignedEvent,
        *,
        exclude_connection_id: str | None,
    ) -> None:
        snapshot = await self._registry.values()
        message = {
            "kind": "event",
            "event": event.to_wire_dict(),
        }
        for conn in snapshot:
            if exclude_connection_id is not None and conn.connection_id == exclude_connection_id:
                continue
            if conn.alive:
                await self._send_json(conn, message)

    async def _send_json(self, conn: ManagedConnection, payload: Mapping[str, object]) -> None:
        data = json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n"
        async with conn.send_lock:
            conn.writer.write(data.encode("utf-8"))
            await conn.writer.drain()

    async def _connection_reader_loop(self, conn: ManagedConnection) -> None:
        try:
            while self._running and conn.alive:
                line = await conn.reader.readline()
                if not line:
                    break
                payload = _parse_json_object(line.decode("utf-8"))
                if payload is None:
                    continue
                await self._handle_socket_message(conn, payload)
        finally:
            await self._registry.remove(conn.key, conn.connection_id)
            await conn.close()

    async def _handle_socket_message(
        self,
        conn: ManagedConnection,
        payload: Mapping[str, object],
    ) -> None:
        kind = payload.get("kind")
        if kind == "event":
            raw_event = payload.get("event")
            if isinstance(raw_event, dict):
                event = SignedEvent.from_wire_dict(raw_event)
                inserted = await self._append_event_if_valid(event)
                if inserted:
                    await self._broadcast_event(
                        event,
                        exclude_connection_id=conn.connection_id,
                    )
        elif kind == "sync_request":
            known_obj = payload.get("known_event_hashes")
            if not isinstance(known_obj, list):
                return
            known_hashes = frozenset(str(v) for v in known_obj)
            async with self._commit_log_lock:
                missing = tuple(
                    event.to_wire_dict()
                    for event in self._commit_log.sorted_events()
                    if event.event_hash not in known_hashes
                )
            await self._send_json(
                conn,
                {
                    "kind": "sync_response",
                    "events": list(missing),
                },
            )
        elif kind == "sync_response":
            events_obj = payload.get("events")
            if not isinstance(events_obj, list):
                return
            for raw_event in events_obj:
                if isinstance(raw_event, dict):
                    event = SignedEvent.from_wire_dict(raw_event)
                    inserted = await self._append_event_if_valid(event)
                    if inserted:
                        await self._broadcast_event(
                            event,
                            exclude_connection_id=conn.connection_id,
                        )

    async def _recompute_gateway_owner(self) -> None:
        async with self._orders_lock:
            orders = self._orders
        now = _utc_now()

        owner: str | None = None
        for ranked in orders.gateway_rule.ranked_nodes:
            last = await self._get_last_heartbeat(ranked)
            if ranked == self._config.node_id and last is None:
                owner = ranked
                break
            if last is None:
                continue
            delta = now - last
            if delta.total_seconds() <= orders.gateway_rule.heartbeat_timeout_seconds:
                owner = ranked
                break

        if owner is None:
            owner = self._config.node_id

        async with self._gateway_lock:
            previous_owner = self._gateway_owner
            changed = owner != previous_owner
            self._gateway_owner = owner
        if changed:
            await self._emit_ownership_transition_events(
                previous_owner=previous_owner,
                new_owner=owner,
            )

    async def _emit_ownership_transition_events(
        self,
        *,
        previous_owner: str,
        new_owner: str,
    ) -> None:
        if previous_owner == self._config.node_id:
            await self.emit_event(
                "gateway_yield",
                {
                    "yielding_node_id": self._config.node_id,
                    "new_owner": new_owner,
                },
            )
        if new_owner == self._config.node_id:
            await self.emit_event(
                "gateway_claim",
                {
                    "claiming_node_id": self._config.node_id,
                    "previous_owner": previous_owner,
                },
            )

    async def _handle_rest_connection(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
    ) -> None:
        try:
            request = await self._read_http_request(reader)
            status = 404
            body: Mapping[str, object] = {"error": "not found"}
            if request is not None:
                method, path, payload = request
                if method == "POST" and path == "/v1/handshake":
                    from_node_id = str(payload.get("from_node_id"))
                    if self._validate_peer_cert_cn(writer, from_node_id):
                        status = 200
                        body = {"accepted": True, "node_id": self._config.node_id}
                    else:
                        status = 403
                        body = {"accepted": False, "error": "peer CN mismatch"}
                elif method == "GET" and path == "/v1/state":
                    status = 200
                    owner = await self.gateway_owner()
                    hashes = await self.log_event_hashes()
                    active_keys = await self.active_connection_keys()
                    mesh_peers = sorted(k.peer_node_id for k in active_keys if k.channel == "mesh")
                    body = {
                        "node_id": self._config.node_id,
                        "gateway_owner": owner,
                        "event_count": len(hashes),
                        "event_hashes": sorted(hashes),
                        "mesh_peers": mesh_peers,
                    }
            await self._write_http_response(writer, status=status, payload=body)
        finally:
            writer.close()
            await writer.wait_closed()

    async def _handle_event_connection(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
    ) -> None:
        try:
            line = await reader.readline()
            if not line:
                writer.close()
                await writer.wait_closed()
                return
            payload = _parse_json_object(line.decode("utf-8"))
            if payload is None:
                writer.close()
                await writer.wait_closed()
                return
            if payload.get("kind") != "hello":
                writer.close()
                await writer.wait_closed()
                return

            peer_node_id = str(payload.get("node_id"))
            connection_id = str(payload.get("connection_id"))
            initiator_node_id = str(payload.get("initiator_node_id"))
            channel_obj = payload.get("channel")
            channel: ChannelName = "mesh"
            if channel_obj == "gateway":
                channel = "gateway"

            if not self._validate_peer_cert_cn(writer, peer_node_id):
                writer.close()
                await writer.wait_closed()
                return

            conn = ManagedConnection(
                key=ConnectionKey(peer_node_id=peer_node_id, channel=channel),
                connection_id=connection_id,
                initiator_node_id=initiator_node_id,
                reader=reader,
                writer=writer,
                established_at_utc=_utc_now(),
                incoming=True,
            )
            accepted = await self._registry.register_candidate(conn)
            if not accepted:
                return
            asyncio.create_task(self._connection_reader_loop(conn))
        except Exception:
            writer.close()
            await writer.wait_closed()

    @staticmethod
    def _validate_peer_cert_cn(writer: asyncio.StreamWriter, expected_cn: str) -> bool:
        ssl_object = cast(object, writer.get_extra_info("ssl_object"))
        if ssl_object is None:
            return False
        if not hasattr(ssl_object, "getpeercert"):
            return False
        peer_cert_provider = cast(_PeerCertProvider, ssl_object)
        peer_cert_obj = peer_cert_provider.getpeercert()
        if not isinstance(peer_cert_obj, dict):
            return False
        subject_obj = peer_cert_obj.get("subject")
        if not isinstance(subject_obj, tuple):
            return False
        for entry in subject_obj:
            if not isinstance(entry, tuple):
                continue
            for name_value in entry:
                if (
                    isinstance(name_value, tuple)
                    and len(name_value) == 2
                    and str(name_value[0]) == "commonName"
                ):
                    return str(name_value[1]) == expected_cn
        return False

    async def _read_http_request(
        self,
        reader: asyncio.StreamReader,
    ) -> tuple[str, str, dict[str, object]] | None:
        try:
            header_blob = await reader.readuntil(b"\r\n\r\n")
        except asyncio.IncompleteReadError:
            return None
        except asyncio.LimitOverrunError:
            return None

        header_text = header_blob.decode("utf-8", errors="replace")
        lines = header_text.split("\r\n")
        if len(lines) == 0:
            return None

        request_line = lines[0]
        parts = request_line.split(" ")
        if len(parts) != 3:
            return None
        method = parts[0]
        path = parts[1]

        headers: dict[str, str] = {}
        for line in lines[1:]:
            if not line:
                continue
            if ":" not in line:
                continue
            key, value = line.split(":", 1)
            headers[key.lower().strip()] = value.strip()

        body: dict[str, object] = {}
        content_length_raw = headers.get("content-length")
        if content_length_raw is not None:
            try:
                content_length = int(content_length_raw)
            except ValueError:
                return None
            if content_length > 0:
                raw_body = await reader.readexactly(content_length)
                parsed = _parse_json_object(raw_body.decode("utf-8"))
                if parsed is not None:
                    body = {str(k): v for k, v in parsed.items()}

        return method, path, body

    async def _write_http_response(
        self,
        writer: asyncio.StreamWriter,
        *,
        status: int,
        payload: Mapping[str, object],
    ) -> None:
        reason = "OK" if status == 200 else "ERROR"
        body = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
        response = (
            f"HTTP/1.1 {status} {reason}\r\n"
            "Content-Type: application/json\r\n"
            f"Content-Length: {len(body)}\r\n"
            "Connection: close\r\n"
            "\r\n"
        ).encode() + body
        writer.write(response)
        await writer.drain()


def _parse_config_path(argv: tuple[str, ...]) -> Path:
    parser = argparse.ArgumentParser(
        prog="prodbox-gateway-loop",
        description="Run distributed gateway daemon loop.",
    )
    parser.add_argument(
        "--config",
        required=True,
        help="Path to gateway daemon JSON config file.",
    )
    parsed = parser.parse_args(argv)
    raw_config_value = cast(object, getattr(parsed, "config", None))
    if not isinstance(raw_config_value, str):
        raise ValueError("Invalid --config argument")
    return Path(raw_config_value)


async def _run_daemon(config_path: Path) -> int:
    config = DaemonConfig.from_json_file(config_path)
    daemon = GatewayDaemon(config)
    await daemon.start()
    stop_event = asyncio.Event()
    try:
        await stop_event.wait()
    except asyncio.CancelledError:
        pass
    except KeyboardInterrupt:
        pass
    finally:
        await daemon.stop()
    return 0


def main() -> None:
    """CLI entrypoint for gateway daemon."""
    config_path = _parse_config_path(tuple(sys.argv[1:]))
    raise SystemExit(asyncio.run(_run_daemon(config_path)))


if __name__ == "__main__":
    main()
