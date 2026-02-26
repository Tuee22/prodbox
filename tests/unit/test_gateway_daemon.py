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
    GatewayDaemon,
    ManagedConnection,
    Orders,
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
        tampered = SignedEvent(
            event_hash=event.event_hash,
            emitter_node_id=event.emitter_node_id,
            timestamp_utc=event.timestamp_utc,
            event_type=event.event_type,
            payload_json=json.dumps({"node_id": "tampered"}),
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


class TestDaemonConfig:
    """Tests for daemon config parsing."""

    def test_from_json_file_parses_fields(self, tmp_path: Path) -> None:
        orders_path = tmp_path / "orders.json"
        orders_path.write_text(json.dumps(_orders_dict()), encoding="utf-8")
        config_path = tmp_path / "config.json"
        config_path.write_text(
            json.dumps(
                {
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
            ),
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
        config_path.write_text(
            json.dumps(
                {
                    "node_id": "node-a",
                    "cert_file": str(tmp_path / "node-a.crt"),
                    "key_file": str(tmp_path / "node-a.key"),
                    "ca_file": str(tmp_path / "ca.crt"),
                    "orders_file": str(orders_path),
                    "event_keys": ["bad"],
                }
            ),
            encoding="utf-8",
        )

        with pytest.raises(ValueError):
            DaemonConfig.from_json_file(config_path)
