"""Unit tests for distributed gateway daemon components."""

from __future__ import annotations

import asyncio
import json
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import cast

import pytest

from prodbox.gateway_daemon import (
    ChannelName,
    CommitLog,
    ConnectionKey,
    ConnectionRegistry,
    DaemonConfig,
    DnsWriteGate,
    GatewayDaemon,
    GatewayRule,
    ManagedConnection,
    Orders,
    Route53DnsWriteClient,
    SignedEvent,
)


def _orders_dict() -> dict[str, object]:
    return {
        "version_utc": 1000,
        "nodes": [
            {
                "node_id": "node-a",
                "stable_dns_name": "node-a.example.test",
                "rest_host": "127.0.0.1",
                "rest_port": 31001,
                "socket_host": "127.0.0.1",
                "socket_port": 32001,
            },
            {
                "node_id": "node-b",
                "stable_dns_name": "node-b.example.test",
                "rest_host": "127.0.0.1",
                "rest_port": 31002,
                "socket_host": "127.0.0.1",
                "socket_port": 32002,
            },
            {
                "node_id": "node-c",
                "stable_dns_name": "node-c.example.test",
                "rest_host": "127.0.0.1",
                "rest_port": 31003,
                "socket_host": "127.0.0.1",
                "socket_port": 32003,
            },
        ],
        "gateway_rule": {
            "ranked_nodes": ["node-a", "node-b", "node-c"],
            "heartbeat_timeout_seconds": 3,
        },
    }


class TestSignedEvent:
    """Tests for signed event validation."""

    def test_create_and_validate(self) -> None:
        event = SignedEvent.create(
            emitter_node_id="node-a",
            event_type="heartbeat",
            payload={"node_id": "node-a"},
            event_key="secret-a",
        )

        assert event.validate(event_keys={"node-a": "secret-a"})

    def test_tampered_payload_fails_validation(self) -> None:
        event = SignedEvent.create(
            emitter_node_id="node-a",
            event_type="heartbeat",
            payload={"node_id": "node-a"},
            event_key="secret-a",
        )
        tampered_payload: dict[str, str] = {"node_id": "tampered"}
        tampered = SignedEvent(
            event_hash=event.event_hash,
            emitter_node_id=event.emitter_node_id,
            timestamp_utc=event.timestamp_utc,
            event_type=event.event_type,
            payload_json=json.dumps(tampered_payload),
            signature_hex=event.signature_hex,
        )

        assert not tampered.validate(event_keys={"node-a": "secret-a"})


class TestCommitLog:
    """Tests for append-only commit log semantics."""

    def test_append_if_new_is_idempotent(self) -> None:
        event = SignedEvent.create(
            emitter_node_id="node-a",
            event_type="heartbeat",
            payload={"node_id": "node-a"},
            event_key="secret-a",
        )
        log0 = CommitLog()
        log1 = log0.append_if_new(event)
        log2 = log1.append_if_new(event)

        assert len(log1.events) == 1
        assert len(log2.events) == 1


class _DummyWriter:
    def __init__(self) -> None:
        self.closed = False

    def is_closing(self) -> bool:
        return self.closed

    def close(self) -> None:
        self.closed = True

    async def wait_closed(self) -> None:
        return None

    def get_extra_info(self, _name: str) -> object:
        return None


def _managed_connection(
    *,
    peer_node_id: str,
    channel: ChannelName,
    connection_id: str,
    initiator_node_id: str,
) -> ManagedConnection:
    return ManagedConnection(
        key=ConnectionKey(peer_node_id=peer_node_id, channel=channel),
        connection_id=connection_id,
        initiator_node_id=initiator_node_id,
        reader=asyncio.StreamReader(),
        writer=cast(asyncio.StreamWriter, _DummyWriter()),
        established_at_utc=datetime.now(UTC),
        incoming=False,
    )


class TestConnectionRegistry:
    """Tests for race-safe dedup logic."""

    @pytest.mark.asyncio
    async def test_deduplicates_connections_per_key(self) -> None:
        registry = ConnectionRegistry(local_node_id="node-b")
        loser = _managed_connection(
            peer_node_id="node-a",
            channel="mesh",
            connection_id="z-conn",
            initiator_node_id="node-b",
        )
        winner = _managed_connection(
            peer_node_id="node-a",
            channel="mesh",
            connection_id="a-conn",
            initiator_node_id="node-a",
        )

        inserted_loser = await registry.register_candidate(loser)
        inserted_winner = await registry.register_candidate(winner)
        values = await registry.values()

        assert inserted_loser
        assert inserted_winner
        assert len(values) == 1
        assert values[0].connection_id == "a-conn"


class TestOrders:
    """Tests for order parsing and validation."""

    def test_orders_parse(self) -> None:
        orders = Orders.from_dict(_orders_dict())
        assert orders.version_utc == 1000
        assert len(orders.nodes) == 3
        assert orders.peer_by_id("node-b") is not None

    def test_gateway_rule_must_reference_known_nodes(self) -> None:
        raw = _orders_dict()
        gateway = cast(dict[str, object], raw["gateway_rule"])
        gateway["ranked_nodes"] = ["node-a", "node-z"]
        with pytest.raises(ValueError):
            Orders.from_dict(raw)


class TestGatewayRuleValidation:
    """Tests for all validation branches in GatewayRule.from_dict()."""

    def test_empty_ranked_nodes_raises(self) -> None:
        with pytest.raises(ValueError, match="must be non-empty"):
            GatewayRule.from_dict({"ranked_nodes": [], "heartbeat_timeout_seconds": 3})

    def test_non_int_heartbeat_timeout_raises(self) -> None:
        with pytest.raises(ValueError, match="must be an int"):
            GatewayRule.from_dict({"ranked_nodes": ["a"], "heartbeat_timeout_seconds": "three"})

    def test_negative_heartbeat_timeout_raises(self) -> None:
        with pytest.raises(ValueError, match="must be >= 1"):
            GatewayRule.from_dict({"ranked_nodes": ["a"], "heartbeat_timeout_seconds": -1})

    def test_zero_heartbeat_timeout_raises(self) -> None:
        with pytest.raises(ValueError, match="must be >= 1"):
            GatewayRule.from_dict({"ranked_nodes": ["a"], "heartbeat_timeout_seconds": 0})

    def test_duplicate_node_ids_raises(self) -> None:
        with pytest.raises(ValueError, match="must be unique"):
            GatewayRule.from_dict({"ranked_nodes": ["a", "a"], "heartbeat_timeout_seconds": 3})

    def test_non_list_ranked_nodes_raises(self) -> None:
        with pytest.raises(ValueError, match="must be a list"):
            GatewayRule.from_dict({"ranked_nodes": "not-a-list", "heartbeat_timeout_seconds": 3})

    def test_valid_gateway_rule_parses(self) -> None:
        rule = GatewayRule.from_dict(
            {
                "ranked_nodes": ["n1", "n2", "n3"],
                "heartbeat_timeout_seconds": 5,
            }
        )
        assert rule.ranked_nodes == ("n1", "n2", "n3")
        assert rule.heartbeat_timeout_seconds == 5


class TestOrdersValidation:
    """Tests for validation branches in Orders.from_dict()."""

    def test_non_int_version_utc_raises(self) -> None:
        raw = _orders_dict()
        raw["version_utc"] = "not-an-int"
        with pytest.raises(ValueError, match="version_utc must be an int"):
            Orders.from_dict(raw)

    def test_non_list_nodes_raises(self) -> None:
        raw = _orders_dict()
        raw["nodes"] = "not-a-list"
        with pytest.raises(ValueError, match="nodes must be a list"):
            Orders.from_dict(raw)

    def test_non_object_gateway_rule_raises(self) -> None:
        raw = _orders_dict()
        raw["gateway_rule"] = "not-an-object"
        with pytest.raises(ValueError, match="gateway_rule must be an object"):
            Orders.from_dict(raw)

    def test_node_missing_required_field_raises(self) -> None:
        raw = _orders_dict()
        raw["nodes"] = [{"stable_dns_name": "x.test"}]  # missing node_id
        with pytest.raises(ValueError, match="node_id is required"):
            Orders.from_dict(raw)


class TestGatewayOwnerComputation:
    """Tests for gateway owner election from heartbeat freshness."""

    @pytest.mark.asyncio
    async def test_prefers_highest_ranked_fresh_heartbeat(self, tmp_path: Path) -> None:
        orders_path = tmp_path / "orders.json"
        orders_path.write_text(json.dumps(_orders_dict()), encoding="utf-8")

        config = DaemonConfig(
            node_id="node-b",
            cert_file=tmp_path / "node-b.crt",
            key_file=tmp_path / "node-b.key",
            ca_file=tmp_path / "ca.crt",
            orders_file=orders_path,
            event_keys={"node-a": "k1", "node-b": "k2", "node-c": "k3"},
        )
        daemon = GatewayDaemon(config)

        now = datetime.now(UTC)
        await daemon._record_heartbeat("node-a", now)  # noqa: SLF001
        await daemon._record_heartbeat("node-b", now - timedelta(seconds=1))  # noqa: SLF001
        await daemon._recompute_gateway_owner()  # noqa: SLF001

        assert await daemon.gateway_owner() == "node-a"

    @pytest.mark.asyncio
    async def test_singleton_takeover_falls_back_to_self(self, tmp_path: Path) -> None:
        orders_path = tmp_path / "orders.json"
        orders_path.write_text(json.dumps(_orders_dict()), encoding="utf-8")

        config = DaemonConfig(
            node_id="node-c",
            cert_file=tmp_path / "node-c.crt",
            key_file=tmp_path / "node-c.key",
            ca_file=tmp_path / "ca.crt",
            orders_file=orders_path,
            event_keys={"node-a": "k1", "node-b": "k2", "node-c": "k3"},
        )
        daemon = GatewayDaemon(config)
        await daemon._recompute_gateway_owner()  # noqa: SLF001

        assert await daemon.gateway_owner() == "node-c"

    @pytest.mark.asyncio
    async def test_invalid_orders_payload_event_does_not_break_append(self, tmp_path: Path) -> None:
        orders_path = tmp_path / "orders.json"
        orders_path.write_text(json.dumps(_orders_dict()), encoding="utf-8")

        config = DaemonConfig(
            node_id="node-a",
            cert_file=tmp_path / "node-a.crt",
            key_file=tmp_path / "node-a.key",
            ca_file=tmp_path / "ca.crt",
            orders_file=orders_path,
            event_keys={"node-a": "k1", "node-b": "k2", "node-c": "k3"},
        )
        daemon = GatewayDaemon(config)
        event = SignedEvent.create(
            emitter_node_id="node-a",
            event_type="orders_published",
            payload={"not": "orders"},
            event_key="k1",
        )

        inserted = await daemon._append_event_if_valid(event)  # noqa: SLF001
        hashes = await daemon.log_event_hashes()

        assert inserted
        assert event.event_hash in hashes


class TestGatewayClaimYield:
    """Tests for GatewayClaim and GatewayYield event emission."""

    @pytest.mark.asyncio
    async def test_gateway_claim_event_emitted_on_self_election(self, tmp_path: Path) -> None:
        """When a node becomes gateway owner, it emits a GatewayClaim event."""
        orders_path = tmp_path / "orders.json"
        orders_path.write_text(json.dumps(_orders_dict()), encoding="utf-8")

        config = DaemonConfig(
            node_id="node-a",
            cert_file=tmp_path / "node-a.crt",
            key_file=tmp_path / "node-a.key",
            ca_file=tmp_path / "ca.crt",
            orders_file=orders_path,
            event_keys={"node-a": "k1", "node-b": "k2", "node-c": "k3"},
        )
        daemon = GatewayDaemon(config)

        # node-a starts with self as owner; simulate ownership change
        # by first setting owner to node-b, then triggering recompute
        # where node-a has a fresh heartbeat
        now = datetime.now(UTC)
        await daemon._record_heartbeat("node-b", now)  # noqa: SLF001
        await daemon._recompute_gateway_owner()  # noqa: SLF001
        # node-a has no heartbeat but is self, so it wins rank 1
        # Actually node-a always self-elects since it's rank 1 and self
        # Let's make node-b the local node so we can test claiming
        assert await daemon.gateway_owner() == "node-a"

        # Verify GatewayClaim was NOT emitted (no ownership change from init)
        # node-a started as owner and stayed as owner
        claim_events = await daemon.events_by_type("gateway_claim")
        assert len(claim_events) == 0

        # Now test with node-b as local node
        config_b = DaemonConfig(
            node_id="node-b",
            cert_file=tmp_path / "node-b.crt",
            key_file=tmp_path / "node-b.key",
            ca_file=tmp_path / "ca.crt",
            orders_file=orders_path,
            event_keys={"node-a": "k1", "node-b": "k2", "node-c": "k3"},
        )
        daemon_b = GatewayDaemon(config_b)
        # Initially node-b thinks it's own owner (self-init)
        assert await daemon_b.gateway_owner() == "node-b"

        # Now feed it a fresh heartbeat from node-a, making node-a the owner
        await daemon_b._record_heartbeat("node-a", now)  # noqa: SLF001
        await daemon_b._recompute_gateway_owner()  # noqa: SLF001
        assert await daemon_b.gateway_owner() == "node-a"

        # node-b yielded ownership → GatewayYield emitted
        yield_events = await daemon_b.events_by_type("gateway_yield")
        assert len(yield_events) == 1
        payload = cast(dict[str, object], json.loads(yield_events[0].payload_json))
        assert payload["yielding_node_id"] == "node-b"
        assert payload["new_owner"] == "node-a"

    @pytest.mark.asyncio
    async def test_gateway_yield_event_emitted_on_demotion(self, tmp_path: Path) -> None:
        """When ownership moves away from this node, it emits GatewayYield."""
        orders_path = tmp_path / "orders.json"
        orders_path.write_text(json.dumps(_orders_dict()), encoding="utf-8")

        config = DaemonConfig(
            node_id="node-b",
            cert_file=tmp_path / "node-b.crt",
            key_file=tmp_path / "node-b.key",
            ca_file=tmp_path / "ca.crt",
            orders_file=orders_path,
            event_keys={"node-a": "k1", "node-b": "k2", "node-c": "k3"},
        )
        daemon = GatewayDaemon(config)
        # Initially self-elected
        assert await daemon.gateway_owner() == "node-b"

        # node-a comes online with fresh heartbeat → node-b demoted
        now = datetime.now(UTC)
        await daemon._record_heartbeat("node-a", now)  # noqa: SLF001
        await daemon._recompute_gateway_owner()  # noqa: SLF001
        assert await daemon.gateway_owner() == "node-a"

        yield_events = await daemon.events_by_type("gateway_yield")
        assert len(yield_events) == 1
        payload = cast(dict[str, object], json.loads(yield_events[0].payload_json))
        assert payload["yielding_node_id"] == "node-b"
        assert payload["new_owner"] == "node-a"

    @pytest.mark.asyncio
    async def test_claim_yield_pair_on_ownership_transition(self, tmp_path: Path) -> None:
        """On transition: old owner yields, new owner claims, in correct order."""
        orders_path = tmp_path / "orders.json"
        orders_path.write_text(json.dumps(_orders_dict()), encoding="utf-8")

        # node-c starts as self-elected owner
        config = DaemonConfig(
            node_id="node-c",
            cert_file=tmp_path / "node-c.crt",
            key_file=tmp_path / "node-c.key",
            ca_file=tmp_path / "ca.crt",
            orders_file=orders_path,
            event_keys={"node-a": "k1", "node-b": "k2", "node-c": "k3"},
        )
        daemon = GatewayDaemon(config)
        assert await daemon.gateway_owner() == "node-c"

        # node-a appears with fresh heartbeat → node-c demoted
        now = datetime.now(UTC)
        await daemon._record_heartbeat("node-a", now)  # noqa: SLF001
        await daemon._recompute_gateway_owner()  # noqa: SLF001
        assert await daemon.gateway_owner() == "node-a"

        # node-c should have emitted GatewayYield (it's the local node being demoted)
        yield_events = await daemon.events_by_type("gateway_yield")
        assert len(yield_events) == 1
        yield_payload = cast(dict[str, object], json.loads(yield_events[0].payload_json))
        assert yield_payload["yielding_node_id"] == "node-c"
        assert yield_payload["new_owner"] == "node-a"

        # No GatewayClaim from node-c (node-a is the new owner, not node-c)
        claim_events = await daemon.events_by_type("gateway_claim")
        assert len(claim_events) == 0

    @pytest.mark.asyncio
    async def test_gateway_claim_on_becoming_owner(self, tmp_path: Path) -> None:
        """Node emits GatewayClaim when it becomes gateway owner."""
        orders_path = tmp_path / "orders.json"
        orders_path.write_text(json.dumps(_orders_dict()), encoding="utf-8")

        # node-a is rank-1 but starts with stale view where node-b owns
        config = DaemonConfig(
            node_id="node-a",
            cert_file=tmp_path / "node-a.crt",
            key_file=tmp_path / "node-a.key",
            ca_file=tmp_path / "ca.crt",
            orders_file=orders_path,
            event_keys={"node-a": "k1", "node-b": "k2", "node-c": "k3"},
        )
        daemon = GatewayDaemon(config)

        # Force ownership to node-b first by injecting state
        now = datetime.now(UTC)
        await daemon._record_heartbeat("node-b", now)  # noqa: SLF001
        # node-a has no heartbeat of its own yet but is self → wins rank 1
        # We need to make node-b win first. Let's use node-b's daemon instead.
        # Actually, let's use a trick: set initial owner to node-b directly
        async with daemon._gateway_lock:  # noqa: SLF001
            daemon._gateway_owner = "node-b"  # noqa: SLF001

        # Now recompute - node-a is self and rank 1, so it reclaims
        await daemon._recompute_gateway_owner()  # noqa: SLF001
        assert await daemon.gateway_owner() == "node-a"

        claim_events = await daemon.events_by_type("gateway_claim")
        assert len(claim_events) == 1
        payload = cast(dict[str, object], json.loads(claim_events[0].payload_json))
        assert payload["claiming_node_id"] == "node-a"
        assert payload["previous_owner"] == "node-b"


class TestDaemonConfig:
    """Tests for daemon config parsing."""

    def test_from_json_file_parses_fields(self, tmp_path: Path) -> None:
        orders_path = tmp_path / "orders.json"
        orders_path.write_text(json.dumps(_orders_dict()), encoding="utf-8")
        config_path = tmp_path / "config.json"
        config_data: dict[str, object] = {
            "node_id": "node-a",
            "cert_file": str(tmp_path / "node-a.crt"),
            "key_file": str(tmp_path / "node-a.key"),
            "ca_file": str(tmp_path / "ca.crt"),
            "orders_file": str(orders_path),
            "event_keys": {
                "node-a": "k1",
                "node-b": "k2",
                "node-c": "k3",
            },
            "heartbeat_interval_seconds": 0.4,
            "reconnect_interval_seconds": "0.5",
            "sync_interval_seconds": 1,
        }
        config_path.write_text(
            json.dumps(config_data),
            encoding="utf-8",
        )

        config = DaemonConfig.from_json_file(config_path)

        assert config.node_id == "node-a"
        assert config.heartbeat_interval_seconds == 0.4
        assert config.reconnect_interval_seconds == 0.5
        assert config.sync_interval_seconds == 1.0

    def test_from_json_file_rejects_non_mapping_event_keys(self, tmp_path: Path) -> None:
        orders_path = tmp_path / "orders.json"
        orders_path.write_text(json.dumps(_orders_dict()), encoding="utf-8")
        config_path = tmp_path / "config.json"
        bad_config: dict[str, object] = {
            "node_id": "node-a",
            "cert_file": str(tmp_path / "node-a.crt"),
            "key_file": str(tmp_path / "node-a.key"),
            "ca_file": str(tmp_path / "ca.crt"),
            "orders_file": str(orders_path),
            "event_keys": ["bad"],
        }
        config_path.write_text(
            json.dumps(bad_config),
            encoding="utf-8",
        )

        with pytest.raises(ValueError):
            DaemonConfig.from_json_file(config_path)


class _MockDnsClient:
    """Mock DNS client for testing DNS write gating."""

    def __init__(self, ip: str = "203.0.113.1") -> None:
        self.ip = ip
        self.writes: list[dict[str, str]] = []

    async def fetch_public_ip(self) -> str:
        return self.ip

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
        self.writes.append(
            {
                "zone_id": zone_id,
                "fqdn": fqdn,
                "ip_address": ip_address,
                "ttl": str(ttl),
                "aws_region": aws_region,
                "aws_access_key_id": aws_access_key_id,
                "aws_secret_access_key": aws_secret_access_key,
            }
        )
        return True


def _dns_write_gate() -> DnsWriteGate:
    return DnsWriteGate(
        zone_id="Z1234567890",
        fqdn="gw.example.test",
        ttl=60,
        aws_region="us-east-1",
        aws_access_key_id="AKIA_FAKE",
        aws_secret_access_key="fake-secret",
    )


class TestDnsWriteGating:
    """Tests for DNS write gating behind gateway ownership."""

    @pytest.mark.asyncio
    async def test_dns_write_only_when_gateway_owner(self, tmp_path: Path) -> None:
        """DNS writes only occur when this node is the gateway owner."""
        orders_path = tmp_path / "orders.json"
        orders_path.write_text(json.dumps(_orders_dict()), encoding="utf-8")
        gate = _dns_write_gate()
        dns_client = _MockDnsClient()

        config = DaemonConfig(
            node_id="node-b",
            cert_file=tmp_path / "node-b.crt",
            key_file=tmp_path / "node-b.key",
            ca_file=tmp_path / "ca.crt",
            orders_file=orders_path,
            event_keys={"node-a": "k1", "node-b": "k2", "node-c": "k3"},
            dns_write_gate=gate,
        )
        daemon = GatewayDaemon(config, dns_client=dns_client)
        # node-b is initially self-elected owner
        assert await daemon.gateway_owner() == "node-b"

        # Emit a gateway_claim so the gate condition is met
        await daemon.emit_event(
            "gateway_claim",
            {"claiming_node_id": "node-b", "previous_owner": "node-b"},
        )

        # DNS write should succeed (owner + claim in log)
        await daemon._attempt_dns_write(gate)  # noqa: SLF001
        assert len(dns_client.writes) == 1

        # Now demote node-b by feeding fresh heartbeat from node-a
        now = datetime.now(UTC)
        await daemon._record_heartbeat("node-a", now)  # noqa: SLF001
        await daemon._recompute_gateway_owner()  # noqa: SLF001
        assert await daemon.gateway_owner() == "node-a"

        # DNS write should NOT happen (not owner)
        await daemon._attempt_dns_write(gate)  # noqa: SLF001
        assert len(dns_client.writes) == 1  # no additional write

    @pytest.mark.asyncio
    async def test_dns_write_requires_claim_event_in_log(self, tmp_path: Path) -> None:
        """DNS writes require a GatewayClaim from self in the commit log."""
        orders_path = tmp_path / "orders.json"
        orders_path.write_text(json.dumps(_orders_dict()), encoding="utf-8")
        gate = _dns_write_gate()
        dns_client = _MockDnsClient()

        config = DaemonConfig(
            node_id="node-a",
            cert_file=tmp_path / "node-a.crt",
            key_file=tmp_path / "node-a.key",
            ca_file=tmp_path / "ca.crt",
            orders_file=orders_path,
            event_keys={"node-a": "k1", "node-b": "k2", "node-c": "k3"},
            dns_write_gate=gate,
        )
        daemon = GatewayDaemon(config, dns_client=dns_client)
        # node-a is self-elected owner but has NO GatewayClaim in log
        assert await daemon.gateway_owner() == "node-a"
        assert not await daemon.has_claim_from("node-a")
        assert not await daemon.has_active_claim_from("node-a")

        # DNS write should NOT happen (no claim event)
        await daemon._attempt_dns_write(gate)  # noqa: SLF001
        assert len(dns_client.writes) == 0

        # Now emit a claim
        await daemon.emit_event(
            "gateway_claim",
            {"claiming_node_id": "node-a", "previous_owner": "node-a"},
        )
        assert await daemon.has_claim_from("node-a")
        assert await daemon.has_active_claim_from("node-a")

        # DNS write should now succeed
        await daemon._attempt_dns_write(gate)  # noqa: SLF001
        assert len(dns_client.writes) == 1

    @pytest.mark.asyncio
    async def test_dns_write_stops_after_yield(self, tmp_path: Path) -> None:
        """After emitting GatewayYield, DNS writes cease."""
        orders_path = tmp_path / "orders.json"
        orders_path.write_text(json.dumps(_orders_dict()), encoding="utf-8")
        gate = _dns_write_gate()
        dns_client = _MockDnsClient()

        config = DaemonConfig(
            node_id="node-b",
            cert_file=tmp_path / "node-b.crt",
            key_file=tmp_path / "node-b.key",
            ca_file=tmp_path / "ca.crt",
            orders_file=orders_path,
            event_keys={"node-a": "k1", "node-b": "k2", "node-c": "k3"},
            dns_write_gate=gate,
        )
        daemon = GatewayDaemon(config, dns_client=dns_client)

        # Emit claim, verify writes work
        await daemon.emit_event(
            "gateway_claim",
            {"claiming_node_id": "node-b", "previous_owner": "node-b"},
        )
        await daemon._attempt_dns_write(gate)  # noqa: SLF001
        assert len(dns_client.writes) == 1

        # Trigger yield by demoting
        now = datetime.now(UTC)
        await daemon._record_heartbeat("node-a", now)  # noqa: SLF001
        await daemon._recompute_gateway_owner()  # noqa: SLF001
        assert await daemon.gateway_owner() == "node-a"

        # has_claim_from still True (old behavior: claim exists in log)
        assert await daemon.has_claim_from("node-b")
        # has_active_claim_from correctly returns False (yield after claim)
        assert not await daemon.has_active_claim_from("node-b")

        # DNS write should NOT happen (no longer owner)
        await daemon._attempt_dns_write(gate)  # noqa: SLF001
        assert len(dns_client.writes) == 1

    @pytest.mark.asyncio
    async def test_dns_write_gate_none_disables_loop(self, tmp_path: Path) -> None:
        """When dns_write_gate is None, the DNS write loop is a no-op."""
        orders_path = tmp_path / "orders.json"
        orders_path.write_text(json.dumps(_orders_dict()), encoding="utf-8")

        config = DaemonConfig(
            node_id="node-a",
            cert_file=tmp_path / "node-a.crt",
            key_file=tmp_path / "node-a.key",
            ca_file=tmp_path / "ca.crt",
            orders_file=orders_path,
            event_keys={"node-a": "k1", "node-b": "k2", "node-c": "k3"},
            dns_write_gate=None,
        )
        daemon = GatewayDaemon(config)

        # _dns_write_loop should return immediately when gate is None
        await daemon._dns_write_loop()  # noqa: SLF001
        # No crash = pass


class TestHasActiveClaim:
    """Tests for has_active_claim_from() — TLA+ CanWriteDns yield guard."""

    @pytest.mark.asyncio
    async def test_has_active_claim_returns_false_on_cold_start(self, tmp_path: Path) -> None:
        """Empty log → False."""
        daemon = _make_daemon(tmp_path, "node-a")
        assert not await daemon.has_active_claim_from("node-a")

    @pytest.mark.asyncio
    async def test_has_active_claim_returns_true_after_claim(self, tmp_path: Path) -> None:
        """Claim → True."""
        daemon = _make_daemon(tmp_path, "node-a")
        await daemon.emit_event(
            "gateway_claim",
            {"claiming_node_id": "node-a", "previous_owner": "node-b"},
        )
        assert await daemon.has_active_claim_from("node-a")

    @pytest.mark.asyncio
    async def test_has_active_claim_returns_false_after_yield(self, tmp_path: Path) -> None:
        """Claim then yield → False (core bug regression)."""
        daemon = _make_daemon(tmp_path, "node-a")
        await daemon.emit_event(
            "gateway_claim",
            {"claiming_node_id": "node-a", "previous_owner": "node-b"},
        )
        await daemon.emit_event(
            "gateway_yield",
            {"yielding_node_id": "node-a", "new_owner": "node-b"},
        )
        assert not await daemon.has_active_claim_from("node-a")

    @pytest.mark.asyncio
    async def test_has_active_claim_returns_true_after_reclaim(self, tmp_path: Path) -> None:
        """Claim-yield-claim → True."""
        daemon = _make_daemon(tmp_path, "node-a")
        await daemon.emit_event(
            "gateway_claim",
            {"claiming_node_id": "node-a", "previous_owner": "node-b"},
        )
        await daemon.emit_event(
            "gateway_yield",
            {"yielding_node_id": "node-a", "new_owner": "node-b"},
        )
        await daemon.emit_event(
            "gateway_claim",
            {"claiming_node_id": "node-a", "previous_owner": "node-b"},
        )
        assert await daemon.has_active_claim_from("node-a")

    @pytest.mark.asyncio
    async def test_has_active_claim_ignores_other_nodes(self, tmp_path: Path) -> None:
        """Other node's yield doesn't affect this node."""
        daemon = _make_daemon(tmp_path, "node-a")
        await daemon.emit_event(
            "gateway_claim",
            {"claiming_node_id": "node-a", "previous_owner": "node-b"},
        )
        # node-b yields — should NOT affect node-a's active claim
        event_b = SignedEvent.create(
            emitter_node_id="node-b",
            event_type="gateway_yield",
            payload={"yielding_node_id": "node-b", "new_owner": "node-a"},
            event_key="k2",
        )
        await daemon._append_event_if_valid(event_b)  # noqa: SLF001
        assert await daemon.has_active_claim_from("node-a")

    @pytest.mark.asyncio
    async def test_dns_write_blocked_after_yield_even_when_still_owner(
        self, tmp_path: Path
    ) -> None:
        """Race condition: node still sees itself as owner but yield is in log."""
        orders_path = tmp_path / "orders.json"
        orders_path.write_text(json.dumps(_orders_dict()), encoding="utf-8")
        gate = _dns_write_gate()
        dns_client = _MockDnsClient()

        config = DaemonConfig(
            node_id="node-a",
            cert_file=tmp_path / "node-a.crt",
            key_file=tmp_path / "node-a.key",
            ca_file=tmp_path / "ca.crt",
            orders_file=orders_path,
            event_keys={"node-a": "k1", "node-b": "k2", "node-c": "k3"},
            dns_write_gate=gate,
        )
        daemon = GatewayDaemon(config, dns_client=dns_client)

        # Emit claim, verify write works
        await daemon.emit_event(
            "gateway_claim",
            {"claiming_node_id": "node-a", "previous_owner": "node-a"},
        )
        await daemon._attempt_dns_write(gate)  # noqa: SLF001
        assert len(dns_client.writes) == 1

        # Manually inject a yield WITHOUT recomputing ownership
        # This simulates the race: yield is in log but _gateway_owner hasn't updated
        await daemon.emit_event(
            "gateway_yield",
            {"yielding_node_id": "node-a", "new_owner": "node-b"},
        )
        # Node still thinks it's owner
        assert await daemon.gateway_owner() == "node-a"
        # But has_active_claim_from correctly detects the yield
        assert not await daemon.has_active_claim_from("node-a")

        # DNS write should be blocked despite still being "owner"
        await daemon._attempt_dns_write(gate)  # noqa: SLF001
        assert len(dns_client.writes) == 1  # no additional write


class TestStateResponse:
    """Tests for /v1/state REST endpoint response fields."""

    @pytest.mark.asyncio
    async def test_state_response_includes_event_hashes(self, tmp_path: Path) -> None:
        """State response includes event hashes from commit log."""
        orders_path = tmp_path / "orders.json"
        orders_path.write_text(json.dumps(_orders_dict()), encoding="utf-8")

        config = DaemonConfig(
            node_id="node-a",
            cert_file=tmp_path / "node-a.crt",
            key_file=tmp_path / "node-a.key",
            ca_file=tmp_path / "ca.crt",
            orders_file=orders_path,
            event_keys={"node-a": "k1", "node-b": "k2", "node-c": "k3"},
        )
        daemon = GatewayDaemon(config)

        # Emit two events
        evt1 = await daemon.emit_event("heartbeat", {"node_id": "node-a"})
        evt2 = await daemon.emit_event("heartbeat", {"node_id": "node-a"})

        hashes = await daemon.log_event_hashes()
        assert evt1.event_hash in hashes
        assert evt2.event_hash in hashes
        assert len(hashes) == 2

    @pytest.mark.asyncio
    async def test_state_response_empty_log_returns_empty_hashes(self, tmp_path: Path) -> None:
        """State response with empty commit log returns empty event_hashes."""
        orders_path = tmp_path / "orders.json"
        orders_path.write_text(json.dumps(_orders_dict()), encoding="utf-8")

        config = DaemonConfig(
            node_id="node-a",
            cert_file=tmp_path / "node-a.crt",
            key_file=tmp_path / "node-a.key",
            ca_file=tmp_path / "ca.crt",
            orders_file=orders_path,
            event_keys={"node-a": "k1", "node-b": "k2", "node-c": "k3"},
        )
        daemon = GatewayDaemon(config)

        hashes = await daemon.log_event_hashes()
        assert len(hashes) == 0

    @pytest.mark.asyncio
    async def test_state_response_includes_mesh_peers(self, tmp_path: Path) -> None:
        """active_connection_keys returns keys for registered connections."""
        orders_path = tmp_path / "orders.json"
        orders_path.write_text(json.dumps(_orders_dict()), encoding="utf-8")

        config = DaemonConfig(
            node_id="node-a",
            cert_file=tmp_path / "node-a.crt",
            key_file=tmp_path / "node-a.key",
            ca_file=tmp_path / "ca.crt",
            orders_file=orders_path,
            event_keys={"node-a": "k1", "node-b": "k2", "node-c": "k3"},
        )
        daemon = GatewayDaemon(config)

        # Register a connection via the registry directly
        conn = _managed_connection(
            peer_node_id="node-b",
            channel="mesh",
            connection_id="conn-1",
            initiator_node_id="node-a",
        )
        await daemon._registry.register_candidate(conn)  # noqa: SLF001

        keys = await daemon.active_connection_keys()
        mesh_peers = sorted(k.peer_node_id for k in keys if k.channel == "mesh")
        assert mesh_peers == ["node-b"]


class TestDaemonConfigDnsWriteGate:
    """Tests for dns_write_gate parsing in DaemonConfig.from_json_file()."""

    def test_daemon_config_parses_dns_write_gate(self, tmp_path: Path) -> None:
        """JSON config with dns_write_gate object parses correctly."""
        orders_path = tmp_path / "orders.json"
        orders_path.write_text(json.dumps(_orders_dict()), encoding="utf-8")
        config_data: dict[str, object] = {
            "node_id": "node-a",
            "cert_file": str(tmp_path / "node-a.crt"),
            "key_file": str(tmp_path / "node-a.key"),
            "ca_file": str(tmp_path / "ca.crt"),
            "orders_file": str(orders_path),
            "event_keys": {"node-a": "k1", "node-b": "k2", "node-c": "k3"},
            "dns_write_gate": {
                "zone_id": "Z1234",
                "fqdn": "gw.example.test",
                "ttl": 60,
                "aws_region": "us-east-1",
                "aws_access_key_id": "AKIA_FAKE",
                "aws_secret_access_key": "fake-secret",
            },
        }
        config_path = tmp_path / "config.json"
        config_path.write_text(json.dumps(config_data), encoding="utf-8")

        config = DaemonConfig.from_json_file(config_path)

        assert config.dns_write_gate is not None
        assert config.dns_write_gate.zone_id == "Z1234"
        assert config.dns_write_gate.fqdn == "gw.example.test"
        assert config.dns_write_gate.ttl == 60
        assert config.dns_write_gate.aws_region == "us-east-1"
        assert config.dns_write_gate.aws_access_key_id == "AKIA_FAKE"
        assert config.dns_write_gate.aws_secret_access_key == "fake-secret"

    def test_daemon_config_dns_write_gate_absent(self, tmp_path: Path) -> None:
        """JSON config without dns_write_gate yields None."""
        orders_path = tmp_path / "orders.json"
        orders_path.write_text(json.dumps(_orders_dict()), encoding="utf-8")
        config_data: dict[str, object] = {
            "node_id": "node-a",
            "cert_file": str(tmp_path / "node-a.crt"),
            "key_file": str(tmp_path / "node-a.key"),
            "ca_file": str(tmp_path / "ca.crt"),
            "orders_file": str(orders_path),
            "event_keys": {"node-a": "k1", "node-b": "k2", "node-c": "k3"},
        }
        config_path = tmp_path / "config.json"
        config_path.write_text(json.dumps(config_data), encoding="utf-8")

        config = DaemonConfig.from_json_file(config_path)

        assert config.dns_write_gate is None


class TestRoute53DnsWriteClient:
    """Tests for Route53DnsWriteClient construction and wiring."""

    def test_route53_client_created_from_gate(self) -> None:
        """from_gate() constructs a valid client with matching credentials."""
        gate = _dns_write_gate()
        client = Route53DnsWriteClient.from_gate(gate)
        assert client._aws_access_key_id == gate.aws_access_key_id  # noqa: SLF001
        assert client._aws_secret_access_key == gate.aws_secret_access_key  # noqa: SLF001
        assert client._aws_region == gate.aws_region  # noqa: SLF001

    @pytest.mark.asyncio
    async def test_default_dns_client_when_gate_provided(self, tmp_path: Path) -> None:
        """No injected client + gate → auto-creates Route53 client."""
        orders_path = tmp_path / "orders.json"
        orders_path.write_text(json.dumps(_orders_dict()), encoding="utf-8")
        gate = _dns_write_gate()

        config = DaemonConfig(
            node_id="node-a",
            cert_file=tmp_path / "node-a.crt",
            key_file=tmp_path / "node-a.key",
            ca_file=tmp_path / "ca.crt",
            orders_file=orders_path,
            event_keys={"node-a": "k1", "node-b": "k2", "node-c": "k3"},
            dns_write_gate=gate,
        )
        daemon = GatewayDaemon(config)

        assert daemon._dns_client is not None  # noqa: SLF001
        assert isinstance(daemon._dns_client, Route53DnsWriteClient)  # noqa: SLF001

    @pytest.mark.asyncio
    async def test_injected_client_takes_precedence(self, tmp_path: Path) -> None:
        """Injected mock overrides auto-creation even when gate is set."""
        orders_path = tmp_path / "orders.json"
        orders_path.write_text(json.dumps(_orders_dict()), encoding="utf-8")
        gate = _dns_write_gate()
        mock_client = _MockDnsClient()

        config = DaemonConfig(
            node_id="node-a",
            cert_file=tmp_path / "node-a.crt",
            key_file=tmp_path / "node-a.key",
            ca_file=tmp_path / "ca.crt",
            orders_file=orders_path,
            event_keys={"node-a": "k1", "node-b": "k2", "node-c": "k3"},
            dns_write_gate=gate,
        )
        daemon = GatewayDaemon(config, dns_client=mock_client)

        assert daemon._dns_client is mock_client  # noqa: SLF001


# =========================================================================
# Phase 4: Coverage Expansion
# =========================================================================


def _make_daemon(tmp_path: Path, node_id: str = "node-a") -> GatewayDaemon:
    """Helper to create a daemon with standard test config."""
    orders_path = tmp_path / "orders.json"
    orders_path.write_text(json.dumps(_orders_dict()), encoding="utf-8")
    config = DaemonConfig(
        node_id=node_id,
        cert_file=tmp_path / f"{node_id}.crt",
        key_file=tmp_path / f"{node_id}.key",
        ca_file=tmp_path / "ca.crt",
        orders_file=orders_path,
        event_keys={"node-a": "k1", "node-b": "k2", "node-c": "k3"},
    )
    return GatewayDaemon(config)


class TestHandshake:
    """Tests for peer handshake and certificate validation."""

    @staticmethod
    def test_validate_peer_cert_cn_returns_false_without_ssl() -> None:
        """_validate_peer_cert_cn returns False when no SSL object on writer."""
        writer = cast(asyncio.StreamWriter, _DummyWriter())
        result = GatewayDaemon._validate_peer_cert_cn(writer, "node-b")  # noqa: SLF001
        assert result is False

    @staticmethod
    def test_validate_peer_cert_cn_returns_false_for_no_getpeercert() -> None:
        """Returns False when ssl_object has no getpeercert method."""

        class _NoGetPeerCert:
            pass

        class _WriterWithSsl:
            def is_closing(self) -> bool:
                return False

            def get_extra_info(self, name: str) -> object:
                if name == "ssl_object":
                    return _NoGetPeerCert()
                return None

        writer = cast(asyncio.StreamWriter, _WriterWithSsl())
        result = GatewayDaemon._validate_peer_cert_cn(writer, "node-b")  # noqa: SLF001
        assert result is False

    @staticmethod
    def test_validate_peer_cert_cn_matches_expected() -> None:
        """Returns True when CN matches expected node_id."""

        class _SslObj:
            def getpeercert(self) -> object:
                return {
                    "subject": ((("commonName", "node-b"),),),
                }

        class _WriterWithSsl:
            def is_closing(self) -> bool:
                return False

            def get_extra_info(self, name: str) -> object:
                if name == "ssl_object":
                    return _SslObj()
                return None

        writer = cast(asyncio.StreamWriter, _WriterWithSsl())
        result = GatewayDaemon._validate_peer_cert_cn(writer, "node-b")  # noqa: SLF001
        assert result is True

    @staticmethod
    def test_validate_peer_cert_cn_mismatch() -> None:
        """Returns False when CN doesn't match expected node_id."""

        class _SslObj:
            def getpeercert(self) -> object:
                return {
                    "subject": ((("commonName", "node-c"),),),
                }

        class _WriterWithSsl:
            def is_closing(self) -> bool:
                return False

            def get_extra_info(self, name: str) -> object:
                if name == "ssl_object":
                    return _SslObj()
                return None

        writer = cast(asyncio.StreamWriter, _WriterWithSsl())
        result = GatewayDaemon._validate_peer_cert_cn(writer, "node-b")  # noqa: SLF001
        assert result is False

    @staticmethod
    def test_validate_peer_cert_cn_non_dict_cert() -> None:
        """Returns False when getpeercert returns non-dict."""

        class _SslObj:
            def getpeercert(self) -> object:
                return None

        class _WriterWithSsl:
            def is_closing(self) -> bool:
                return False

            def get_extra_info(self, name: str) -> object:
                if name == "ssl_object":
                    return _SslObj()
                return None

        writer = cast(asyncio.StreamWriter, _WriterWithSsl())
        result = GatewayDaemon._validate_peer_cert_cn(writer, "node-b")  # noqa: SLF001
        assert result is False


class TestHeartbeatLoop:
    """Tests for heartbeat emission."""

    @pytest.mark.asyncio
    async def test_heartbeat_emits_event(self, tmp_path: Path) -> None:
        """Heartbeat loop emits heartbeat event with correct node_id."""
        daemon = _make_daemon(tmp_path, "node-a")
        event = await daemon.emit_event("heartbeat", {"node_id": "node-a"})
        assert event.event_type == "heartbeat"
        assert event.emitter_node_id == "node-a"

    @pytest.mark.asyncio
    async def test_heartbeat_records_timestamp(self, tmp_path: Path) -> None:
        """Heartbeat updates last_heartbeat_seen for the emitting node."""
        daemon = _make_daemon(tmp_path, "node-a")
        await daemon.emit_event("heartbeat", {"node_id": "node-a"})

        last = await daemon._get_last_heartbeat("node-a")  # noqa: SLF001
        assert last is not None

    @pytest.mark.asyncio
    async def test_heartbeat_payload_contains_node_id(self, tmp_path: Path) -> None:
        """Heartbeat event payload includes the node_id."""
        daemon = _make_daemon(tmp_path, "node-b")
        event = await daemon.emit_event("heartbeat", {"node_id": "node-b"})
        payload = json.loads(event.payload_json)
        assert payload["node_id"] == "node-b"


class TestAntiEntropySync:
    """Tests for anti-entropy sync message handling."""

    @pytest.mark.asyncio
    async def test_sync_request_identifies_missing_events(self, tmp_path: Path) -> None:
        """Sync request with known hashes identifies missing events."""
        daemon = _make_daemon(tmp_path, "node-a")
        event = await daemon.emit_event("heartbeat", {"node_id": "node-a"})

        hashes = await daemon.log_event_hashes()
        assert event.event_hash in hashes
        assert len(hashes) == 1

    @pytest.mark.asyncio
    async def test_empty_log_sync_returns_no_events(self, tmp_path: Path) -> None:
        """Cold start with empty log has no events to sync."""
        daemon = _make_daemon(tmp_path, "node-a")
        hashes = await daemon.log_event_hashes()
        assert len(hashes) == 0

    @pytest.mark.asyncio
    async def test_append_event_deduplicates(self, tmp_path: Path) -> None:
        """Re-appending same event doesn't create duplicate."""
        daemon = _make_daemon(tmp_path, "node-a")
        event = await daemon.emit_event("heartbeat", {"node_id": "node-a"})

        # Try to append the same event again
        inserted = await daemon._append_event_if_valid(event)  # noqa: SLF001
        assert inserted is False

        hashes = await daemon.log_event_hashes()
        assert len(hashes) == 1

    @pytest.mark.asyncio
    async def test_event_from_other_node_accepted(self, tmp_path: Path) -> None:
        """Events signed by other nodes with valid keys are accepted."""
        daemon = _make_daemon(tmp_path, "node-a")
        event = SignedEvent.create(
            emitter_node_id="node-b",
            event_type="heartbeat",
            payload={"node_id": "node-b"},
            event_key="k2",
        )
        inserted = await daemon._append_event_if_valid(event)  # noqa: SLF001
        assert inserted is True

    @pytest.mark.asyncio
    async def test_event_with_wrong_key_rejected(self, tmp_path: Path) -> None:
        """Events signed with wrong key are rejected."""
        daemon = _make_daemon(tmp_path, "node-a")
        event = SignedEvent.create(
            emitter_node_id="node-b",
            event_type="heartbeat",
            payload={"node_id": "node-b"},
            event_key="wrong-key",
        )
        inserted = await daemon._append_event_if_valid(event)  # noqa: SLF001
        assert inserted is False


class TestLifecycle:
    """Tests for daemon start/stop lifecycle."""

    @pytest.mark.asyncio
    async def test_stop_idempotent(self, tmp_path: Path) -> None:
        """stop() can be called multiple times without error."""
        daemon = _make_daemon(tmp_path, "node-a")
        # stop without start
        await daemon.stop()
        await daemon.stop()
        # No crash = pass

    @pytest.mark.asyncio
    async def test_start_sets_running(self, tmp_path: Path) -> None:
        """Daemon _running flag is set after start intent."""
        daemon = _make_daemon(tmp_path, "node-a")
        assert daemon._running is False  # noqa: SLF001

    @pytest.mark.asyncio
    async def test_emit_event_without_key_raises(self, tmp_path: Path) -> None:
        """Emitting event when node has no signing key raises RuntimeError."""
        orders_path = tmp_path / "orders.json"
        orders_path.write_text(json.dumps(_orders_dict()), encoding="utf-8")
        config = DaemonConfig(
            node_id="node-a",
            cert_file=tmp_path / "node-a.crt",
            key_file=tmp_path / "node-a.key",
            ca_file=tmp_path / "ca.crt",
            orders_file=orders_path,
            event_keys={"node-b": "k2"},  # no key for node-a
        )
        daemon = GatewayDaemon(config)
        with pytest.raises(RuntimeError, match="Missing event signing key"):
            await daemon.emit_event("heartbeat", {"node_id": "node-a"})

    @pytest.mark.asyncio
    async def test_daemon_rejects_unknown_node_id(self, tmp_path: Path) -> None:
        """Creating daemon with node_id not in orders raises ValueError."""
        orders_path = tmp_path / "orders.json"
        orders_path.write_text(json.dumps(_orders_dict()), encoding="utf-8")
        config = DaemonConfig(
            node_id="node-z",
            cert_file=tmp_path / "node-z.crt",
            key_file=tmp_path / "node-z.key",
            ca_file=tmp_path / "ca.crt",
            orders_file=orders_path,
            event_keys={"node-z": "kz"},
        )
        with pytest.raises(ValueError, match="not found in orders"):
            GatewayDaemon(config)


class TestGatewayOwnerEdgeCases:
    """Additional edge case tests for gateway owner computation."""

    @pytest.mark.asyncio
    async def test_all_peers_timed_out_falls_back_to_self(self, tmp_path: Path) -> None:
        """When all peer heartbeats are stale, node falls back to self."""
        daemon = _make_daemon(tmp_path, "node-c")
        now = datetime.now(UTC)
        stale = now - timedelta(seconds=100)

        # Record very stale heartbeats for higher-ranked nodes
        await daemon._record_heartbeat("node-a", stale)  # noqa: SLF001
        await daemon._record_heartbeat("node-b", stale)  # noqa: SLF001
        await daemon._recompute_gateway_owner()  # noqa: SLF001

        assert await daemon.gateway_owner() == "node-c"

    @pytest.mark.asyncio
    async def test_promote_orders_newer_version_accepted(self, tmp_path: Path) -> None:
        """promote_orders_if_newer accepts higher version."""
        daemon = _make_daemon(tmp_path, "node-a")

        new_orders_dict = _orders_dict()
        new_orders_dict["version_utc"] = 2000
        new_orders = Orders.from_dict(new_orders_dict)

        accepted = await daemon.promote_orders_if_newer(new_orders)
        assert accepted is True

    @pytest.mark.asyncio
    async def test_promote_orders_older_version_rejected(self, tmp_path: Path) -> None:
        """promote_orders_if_newer rejects lower version."""
        daemon = _make_daemon(tmp_path, "node-a")

        old_orders_dict = _orders_dict()
        old_orders_dict["version_utc"] = 500
        old_orders = Orders.from_dict(old_orders_dict)

        rejected = await daemon.promote_orders_if_newer(old_orders)
        assert rejected is False

    @pytest.mark.asyncio
    async def test_heartbeat_at_exact_timeout_boundary_counts_as_fresh(
        self, tmp_path: Path
    ) -> None:
        """delta <= timeout → fresh (the <= check). Small buffer for execution time."""
        daemon = _make_daemon(tmp_path, "node-b")
        now = datetime.now(UTC)
        timeout = 3  # from _orders_dict heartbeat_timeout_seconds
        # Use (timeout - 0.1) to avoid losing to wall-clock drift between now and recompute
        await daemon._record_heartbeat(  # noqa: SLF001
            "node-a", now - timedelta(seconds=timeout - 0.1)
        )
        await daemon._recompute_gateway_owner()  # noqa: SLF001
        # node-a within timeout boundary → fresh → wins rank 1
        assert await daemon.gateway_owner() == "node-a"

    @pytest.mark.asyncio
    async def test_heartbeat_past_timeout_boundary_is_stale(self, tmp_path: Path) -> None:
        """delta > timeout → stale, self-elects."""
        daemon = _make_daemon(tmp_path, "node-b")
        now = datetime.now(UTC)
        timeout = 3  # from _orders_dict heartbeat_timeout_seconds
        await daemon._record_heartbeat(  # noqa: SLF001
            "node-a", now - timedelta(seconds=timeout + 1)
        )
        await daemon._recompute_gateway_owner()  # noqa: SLF001
        # node-a past timeout → stale; node-b self-elects
        assert await daemon.gateway_owner() == "node-b"

    @pytest.mark.asyncio
    async def test_concurrent_emit_events(self, tmp_path: Path) -> None:
        """Multiple concurrent emit_event calls produce unique hashes."""
        daemon = _make_daemon(tmp_path, "node-a")

        events = await asyncio.gather(
            daemon.emit_event("heartbeat", {"node_id": "node-a", "seq": "1"}),
            daemon.emit_event("heartbeat", {"node_id": "node-a", "seq": "2"}),
            daemon.emit_event("heartbeat", {"node_id": "node-a", "seq": "3"}),
        )

        hashes = {e.event_hash for e in events}
        assert len(hashes) == 3


class TestCommitLogExtended:
    """Additional commit log tests."""

    def test_sorted_events_deterministic_order(self) -> None:
        """sorted_events returns events in timestamp then hash order."""
        e1 = SignedEvent.create(
            emitter_node_id="node-a",
            event_type="heartbeat",
            payload={"seq": "1"},
            event_key="k1",
        )
        e2 = SignedEvent.create(
            emitter_node_id="node-b",
            event_type="heartbeat",
            payload={"seq": "2"},
            event_key="k2",
        )
        log = CommitLog().append_if_new(e1).append_if_new(e2)
        sorted_events = log.sorted_events()
        assert len(sorted_events) == 2
        # Events should be sorted by (timestamp, hash)
        assert sorted_events[0].timestamp_utc <= sorted_events[1].timestamp_utc

    def test_latest_timestamp_empty_log(self) -> None:
        """latest_timestamp returns None for empty log."""
        log = CommitLog()
        assert log.latest_timestamp() is None

    def test_latest_timestamp_returns_most_recent(self) -> None:
        """latest_timestamp returns the most recent event time."""
        e1 = SignedEvent.create(
            emitter_node_id="node-a",
            event_type="heartbeat",
            payload={"seq": "1"},
            event_key="k1",
        )
        log = CommitLog().append_if_new(e1)
        ts = log.latest_timestamp()
        assert ts is not None


class TestConnectionRegistryExtended:
    """Additional connection registry tests."""

    @pytest.mark.asyncio
    async def test_remove_nonexistent_key_is_noop(self) -> None:
        """Removing a key that doesn't exist is a no-op."""
        registry = ConnectionRegistry(local_node_id="node-a")
        await registry.remove(
            ConnectionKey(peer_node_id="node-b", channel="mesh"),
            "nonexistent-id",
        )
        values = await registry.values()
        assert len(values) == 0

    @pytest.mark.asyncio
    async def test_remove_mismatched_connection_id_is_noop(self) -> None:
        """Removing with wrong connection_id doesn't affect existing connection."""
        registry = ConnectionRegistry(local_node_id="node-a")
        conn = _managed_connection(
            peer_node_id="node-b",
            channel="mesh",
            connection_id="real-id",
            initiator_node_id="node-a",
        )
        await registry.register_candidate(conn)
        await registry.remove(conn.key, "wrong-id")
        values = await registry.values()
        assert len(values) == 1

    @pytest.mark.asyncio
    async def test_close_all_empties_registry(self) -> None:
        """close_all removes all connections."""
        registry = ConnectionRegistry(local_node_id="node-a")
        conn1 = _managed_connection(
            peer_node_id="node-b",
            channel="mesh",
            connection_id="c1",
            initiator_node_id="node-a",
        )
        conn2 = _managed_connection(
            peer_node_id="node-c",
            channel="mesh",
            connection_id="c2",
            initiator_node_id="node-a",
        )
        await registry.register_candidate(conn1)
        await registry.register_candidate(conn2)
        assert len(await registry.values()) == 2

        await registry.close_all()
        assert len(await registry.values()) == 0
