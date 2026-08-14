{-# LANGUAGE ImportQualifiedPost #-}

-- | Sprint 3.35: the one compiled owner of the control-plane role listen port.
--
-- Every control-plane role — Bootstrap Broker, Lifecycle Authority, Target
-- Secret Agent, Provider Worker, Authority Backup Adapter, TLS Retention
-- Adapter — is served by the same 'Prodbox.ControlPlane.Runtime.runControlPlaneServer',
-- which binds one port. Before this sprint that port was the bare literal
-- @8600@ restated in fourteen places across nine modules, five of them as
-- separately-named per-role constants, with no owner for any of them to drift
-- from.
--
-- __The row that scheduled this left one question open, and it is settled by
-- measurement rather than by preference__: whether the five roles are
-- /required/ to share one port, or whether naming the five constants
-- individually anticipated divergence. They are required to share it.
-- @runControlPlaneServer@ receives the role and binds the port without
-- consulting it, so a per-role port is not representable in the binder at all;
-- the five constants restated one fact five times and could never have
-- diverged. Giving them one owner takes nothing away.
--
-- This also corrects a claim
-- 'Prodbox.Bootstrap.Broker.ChartStatics' made about this value — see the
-- Standard-C note there. The listen port is not operator-chosen per cluster;
-- the compiled binder decides it, and the chart values follow.
module Prodbox.ControlPlane.ListenPort
  ( controlPlaneListenPort
  , controlPlaneListenPortNumber
  , controlPlaneClusterServiceUrl
  , controlPlaneClusterServiceUrlText
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Network.Socket (PortNumber)

-- | The TCP port every control-plane role listens on.
--
-- Renders into chart values, the rendered broker Dhall, the AWS role-transport
-- isolation table, and the loopback port-forward targets, so those cannot drift
-- from what the binder actually opens.
controlPlaneListenPort :: Int
controlPlaneListenPort = 8600

-- | 'controlPlaneListenPort' as the binder wants it. Separate projection rather
-- than a second literal, so the socket cannot be opened on a port the rendered
-- Services do not name.
controlPlaneListenPortNumber :: PortNumber
controlPlaneListenPortNumber = fromIntegral controlPlaneListenPort

-- | The in-cluster URL of a control-plane role's Service.
--
-- Nine call sites authored this string themselves, each repeating both the
-- @.svc.cluster.local@ suffix and the port. One derived encoder, per
-- [chaos_hardening_doctrine.md § 23](../../../documents/engineering/chaos_hardening_doctrine.md).
controlPlaneClusterServiceUrl :: String -> String -> String
controlPlaneClusterServiceUrl service namespace =
  "http://"
    ++ service
    ++ "."
    ++ namespace
    ++ ".svc.cluster.local:"
    ++ show controlPlaneListenPort

-- | 'controlPlaneClusterServiceUrl' for the majority of call sites, which hold
-- the endpoint as 'Text'.
--
-- __Derived, not a second encoder.__ Writing the URL shape twice is exactly the
-- restatement this module exists to remove, so this projects the one above
-- rather than repeating it.
controlPlaneClusterServiceUrlText :: Text -> Text -> Text
controlPlaneClusterServiceUrlText service namespace =
  Text.pack
    ( controlPlaneClusterServiceUrl
        (Text.unpack service)
        (Text.unpack namespace)
    )
