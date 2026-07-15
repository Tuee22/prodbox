{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 2.34: one compiled source of truth for the gateway chart's static
-- identities — the REST/event container ports, the host-facing NodePort, the
-- Pod ServiceAccount name, and the Vault Kubernetes-auth role. Every one of
-- these was previously a hand-maintained literal duplicated between
-- @charts/gateway/values.yaml@, the hand-written templates, and the Haskell
-- render, free to drift.
--
-- 'GatewayChartStatics' feeds BOTH the deployed values JSON (through
-- 'Prodbox.Lib.ChartPlatform.valuesForGateway') and the generated
-- @gateway-chart-statics.values@ section of @values.yaml@ (through
-- 'renderGatewayChartStaticsYaml'). A chart lint forbids the raw literals in the
-- hand-written templates and a conformance gate proves the committed
-- @values.yaml@ defaults equal this projection, so the three copies can no
-- longer diverge.
--
-- The NodePort and the ServiceAccount/Vault-role identity are read from their
-- existing compiled owners ('Prodbox.Host.defaultGatewayNodePort' and
-- 'Prodbox.Vault.RoleId.VaultRoleGatewayDaemon'), so this module unifies them
-- rather than introducing a fourth copy.
module Prodbox.Gateway.ChartStatics
  ( GatewayChartStatics (..)
  , gatewayChartStatics
  , gatewayChartStaticsPortsValue
  , gatewayChartStaticsNodePortValue
  , gatewayChartStaticsServiceAccountValue
  , renderGatewayChartStaticsYaml
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Host (defaultGatewayNodePort)
import Prodbox.Vault.RoleId (VaultRoleId (VaultRoleGatewayDaemon), vaultRoleIdText)

-- | The gateway chart's compiled static identities.
data GatewayChartStatics = GatewayChartStatics
  { gatewayStaticRestPort :: Int
  , gatewayStaticEventsPort :: Int
  , gatewayStaticNodePort :: Int
  , gatewayStaticServiceAccount :: Text
  , gatewayStaticVaultRole :: Text
  }
  deriving (Eq, Show)

-- | The one compiled instance. The ServiceAccount name and the Vault role are
-- the SAME identity ('VaultRoleGatewayDaemon'): the Pod authenticates to Vault
-- Kubernetes auth as this ServiceAccount, which is bound to the role of the
-- same name.
gatewayChartStatics :: GatewayChartStatics
gatewayChartStatics =
  GatewayChartStatics
    { gatewayStaticRestPort = 8443
    , gatewayStaticEventsPort = 8444
    , gatewayStaticNodePort = defaultGatewayNodePort
    , gatewayStaticServiceAccount = vaultRoleIdText VaultRoleGatewayDaemon
    , gatewayStaticVaultRole = vaultRoleIdText VaultRoleGatewayDaemon
    }

-- | @ports@ block for the deployed values JSON.
gatewayChartStaticsPortsValue :: Value
gatewayChartStaticsPortsValue =
  object
    [ "rest" .= gatewayStaticRestPort gatewayChartStatics
    , "events" .= gatewayStaticEventsPort gatewayChartStatics
    ]

-- | @nodePort@ block for the deployed values JSON.
gatewayChartStaticsNodePortValue :: Value
gatewayChartStaticsNodePortValue =
  object
    [ "rest" .= gatewayStaticNodePort gatewayChartStatics
    ]

-- | @serviceAccount@ block for the deployed values JSON.
gatewayChartStaticsServiceAccountValue :: Value
gatewayChartStaticsServiceAccountValue =
  object
    [ "name" .= gatewayStaticServiceAccount gatewayChartStatics
    ]

-- | The @gateway-chart-statics.values@ generated section body. The same typed
-- statics are emitted into the supported Haskell chart plan through the aeson
-- projections above, so the committed @values.yaml@ defaults cannot drift from
-- the deployed values.
renderGatewayChartStaticsYaml :: String
renderGatewayChartStaticsYaml =
  unlines
    [ "ports:"
    , "  rest: " ++ show (gatewayStaticRestPort gatewayChartStatics)
    , "  events: " ++ show (gatewayStaticEventsPort gatewayChartStatics)
    , "nodePort:"
    , "  rest: " ++ show (gatewayStaticNodePort gatewayChartStatics)
    , "serviceAccount:"
    , "  name: " ++ Text.unpack (gatewayStaticServiceAccount gatewayChartStatics)
    ]
