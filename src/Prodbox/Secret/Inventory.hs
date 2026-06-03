{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Secret.Inventory
  ( DerivedSecretEntry (..)
  , derivedSecretInventoryFor
  )
where

import Data.Text (Text)
import Prodbox.Secret.Derive
  ( PatroniRole (..)
  , gatewayEventKeyContext
  , keycloakAdminContext
  , keycloakDemoUserContext
  , oidcClientSecretContext
  , patroniRoleContext
  )

-- | Sprint 3.13: one row from the doctrine-prescribed derived-secret
--   inventory in
--   [Secret Derivation Doctrine §6](../../documents/engineering/secret_derivation_doctrine.md#6-derived-vs-generated-inventory).
--   Captures the k8s @Secret@ object name the daemon's
--   @/v1/secret/ensure-namespace@ handler materializes, the list of
--   @(key, context)@ derived-field pairs that populate the Secret's
--   @stringData@ map at materialization time, and any companion static
--   fields the consumer requires alongside the derived value (e.g. the
--   Crunchy Postgres operator demands both @username@ and @password@
--   in the same Secret it watches).
--
-- Sprint 3.13 chunk 11 widened the derived-fields field from a single
-- @(key, context)@ to a list so the daemon can atomically PUT a Secret
-- with multiple master-seed-derived fields (the OAuth client secrets
-- and demo-user password all live in the @keycloak-oidc-clients@ Secret,
-- and a multi-entry-same-name approach would PUT-overwrite earlier
-- entries since each PUT replaces the entire @stringData@ map).
data DerivedSecretEntry = DerivedSecretEntry
  { derivedSecretEntryName :: Text
  , derivedSecretEntryDerivedFields :: [(Text, Text)]
  -- ^ @[(stringDataKey, contextString)]@ — each pair becomes one
  --   @stringData@ entry whose value is
  --   @deriveBase64Url masterSeed contextString@. Keys must be unique
  --   within the list.
  , derivedSecretEntryStaticFields :: [(Text, Text)]
  -- ^ Non-derived companion fields. Same shape as the chunk-8 contract:
  --   @[(stringDataKey, literalValue)]@. Empty list = the Secret has only
  --   the derived keys.
  }
  deriving (Eq, Show)

-- | Sprint 3.13: doctrine-prescribed derived-secret inventory for a given
--   @(namespace, release)@ pair. Mirrors the @derived@-class rows of
--   [Secret Derivation Doctrine §6](../../documents/engineering/secret_derivation_doctrine.md#6-derived-vs-generated-inventory).
--   Returns @[]@ when the release has no derived secrets (e.g. @vscode@ /
--   @api@ / @websocket@: those charts read their OAuth client secret via
--   cross-namespace Helm @lookup@ of the keycloak namespace's
--   @keycloak-oidc-clients@ Secret rather than carrying their own
--   per-release inventory entry). Gateway per-node event-key Secrets are
--   intentionally not enumerated here because their count is a function
--   of the live gateway node inventory, not a static doctrine table; the
--   daemon's @ensure-namespace@ handler injects them dynamically when
--   materializing the gateway release.
derivedSecretInventoryFor :: Text -> Text -> [DerivedSecretEntry]
derivedSecretInventoryFor namespace release =
  case (namespace, release) of
    (_, "keycloak-postgres") ->
      -- Sprint 3.13 chunk 21: the Crunchy operator names the Patroni Secrets
      -- after the cluster, which is named after the rootChart (which equals
      -- the namespace for a Helm-released chart). vscode + keycloak both
      -- pull in @keycloak-postgres@ as a dependency, so we see this entry
      -- fire with two distinct namespaces (`vscode` → `prodbox-vscode-pg-*`
      -- and `keycloak` → `prodbox-keycloak-pg-*`). Naming mirrors
      -- 'Prodbox.PostgresPlatform.patroniClusterName' /
      -- 'patroniCredentialsSecretName' / 'patroniSuperuserSecretName' /
      -- 'patroniStandbySecretName' to keep both sides in sync.
      let clusterPrefix = "prodbox-" <> namespace <> "-pg"
       in [ patroniEntry (clusterPrefix <> "-pguser-keycloak") "keycloak" PatroniRoleApp
          , patroniEntry (clusterPrefix <> "-pguser-postgres") "postgres" PatroniRoleSuperuser
          , patroniEntry (clusterPrefix <> "-primaryuser") "primaryuser" PatroniRoleStandby
          ]
    (_, "keycloak") ->
      -- Sprint 3.13 chunk 28: like chunk 21 for the Patroni release,
      -- the keycloak release inherits its deploy namespace from its
      -- root chart. The keycloak root chart deploys to the @keycloak@
      -- namespace; the vscode root chart's transitive
      -- (vscode → keycloak) dep deploys keycloak into the @vscode@
      -- namespace. Both deployments need their @keycloak-runtime@ and
      -- @keycloak-oidc-clients@ Secrets in their own namespace, with
      -- derivation contexts namespace-scoped so the two deployments
      -- get distinct values (and the chart-side Helm `lookup` in
      -- @configmap.yaml@ + cross-namespace lookups in vscode /
      -- websocket workload charts all read the same per-namespace
      -- values).
      [ DerivedSecretEntry
          { derivedSecretEntryName = "keycloak-runtime"
          , derivedSecretEntryDerivedFields =
              [("KEYCLOAK_ADMIN_PASSWORD", keycloakAdminContext namespace)]
          , derivedSecretEntryStaticFields = []
          }
      , DerivedSecretEntry
          { derivedSecretEntryName = "keycloak-oidc-clients"
          , derivedSecretEntryDerivedFields =
              [ ("VSCODE_CLIENT_SECRET", oidcClientSecretContext namespace "vscode")
              , ("API_CLIENT_SECRET", oidcClientSecretContext namespace "prodbox-api")
              , ("WEBSOCKET_CLIENT_SECRET", oidcClientSecretContext namespace "prodbox-websocket")
              , ("DEMO_USER_PASSWORD", keycloakDemoUserContext namespace)
              ]
          , derivedSecretEntryStaticFields = []
          }
      ]
    ("gateway", "gateway") ->
      -- Sprint 3.13 chunk 16: gateway per-node event-signing keys join the
      -- daemon-derived inventory. Each gateway Pod, after acquiring the
      -- master seed from MinIO, self-bootstraps its own
      -- @gateway-event-keys@ Secret in the @gateway@ namespace via
      -- 'EnsureNamespace.applyDerivedSecrets' — granted by the
      -- @rbac.targetNamespaces@ extension that adds the daemon's own
      -- namespace alongside @keycloak@. The chart's
      -- @configmap-config.yaml@ reads the three @NODE_<X>_EVENT_KEY@
      -- fields via Helm @lookup@ so every Pod's @event_keys@ list agrees
      -- with every peer's. Self-bootstrap avoids the
      -- pre-install-Job-vs-daemon-Pod chicken-and-egg the other charts
      -- escape because they POST to an already-running gateway daemon.
      -- Canonical node ids match 'Prodbox.Lib.ChartPlatform.gatewayNodeIds'
      -- (3 nodes today; the dynamic-node-inventory extension lands when
      -- node-count becomes a runtime parameter rather than a chart
      -- constant).
      [ DerivedSecretEntry
          { derivedSecretEntryName = "gateway-event-keys"
          , derivedSecretEntryDerivedFields =
              [ ("NODE_A_EVENT_KEY", gatewayEventKeyContext namespace "node-a")
              , ("NODE_B_EVENT_KEY", gatewayEventKeyContext namespace "node-b")
              , ("NODE_C_EVENT_KEY", gatewayEventKeyContext namespace "node-c")
              ]
          , derivedSecretEntryStaticFields = []
          }
      ]
    _ -> []
 where
  patroniEntry secretName username role =
    DerivedSecretEntry
      { derivedSecretEntryName = secretName
      , derivedSecretEntryDerivedFields =
          [("password", patroniRoleContext namespace release role)]
      , derivedSecretEntryStaticFields = [("username", username)]
      }
