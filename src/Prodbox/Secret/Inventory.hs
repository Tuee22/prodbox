{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Secret.Inventory
  ( DerivedSecretEntry (..)
  , derivedSecretInventoryFor
  )
where

import Data.Text (Text)
import Prodbox.Secret.Derive
  ( PatroniRole (..)
  , keycloakAdminContext
  , patroniRoleContext
  )

-- | Sprint 3.13: one row from the doctrine-prescribed derived-secret
--   inventory in
--   [Secret Derivation Doctrine §6](../../documents/engineering/secret_derivation_doctrine.md#6-derived-vs-generated-inventory).
--   Captures the k8s @Secret@ object name the daemon's
--   @/v1/secret/ensure-namespace@ handler materializes, the key inside
--   that Secret's @data@ map that holds the derived value, and the
--   master-seed derivation context string (per
--   [Secret Derivation Doctrine §3](../../documents/engineering/secret_derivation_doctrine.md#3-derivation-algorithm)).
--   The value itself is computed at materialization time via
--   'Prodbox.Secret.Derive.derive' over the master seed and the context.
data DerivedSecretEntry = DerivedSecretEntry
  { derivedSecretEntryName :: Text
  , derivedSecretEntryKey :: Text
  , derivedSecretEntryContext :: Text
  }
  deriving (Eq, Show)

-- | Sprint 3.13: doctrine-prescribed derived-secret inventory for a given
--   @(namespace, release)@ pair. Mirrors the @derived@-class rows of
--   [Secret Derivation Doctrine §6](../../documents/engineering/secret_derivation_doctrine.md#6-derived-vs-generated-inventory).
--   Returns @[]@ when the release has no derived secrets (e.g. @vscode@ /
--   @api@ / @websocket@, whose chart-side Secrets use Helm @lookup@ +
--   @randAlphaNum@). Gateway per-node event-key Secrets are intentionally
--   not enumerated here because their count is a function of the live
--   gateway node inventory, not a static doctrine table; the daemon's
--   @ensure-namespace@ handler injects them dynamically when materializing
--   the gateway release.
derivedSecretInventoryFor :: Text -> Text -> [DerivedSecretEntry]
derivedSecretInventoryFor namespace release =
  case (namespace, release) of
    ("keycloak", "keycloak-postgres") ->
      [ patroniEntry "prodbox-keycloak-pg-pguser-keycloak" PatroniRoleApp
      , patroniEntry "prodbox-keycloak-pg-pguser-postgres" PatroniRoleSuperuser
      , patroniEntry "prodbox-keycloak-pg-primaryuser" PatroniRoleStandby
      ]
    ("keycloak", "keycloak") ->
      [ DerivedSecretEntry
          { derivedSecretEntryName = "keycloak-runtime"
          , derivedSecretEntryKey = "KEYCLOAK_ADMIN_PASSWORD"
          , derivedSecretEntryContext = keycloakAdminContext namespace
          }
      ]
    _ -> []
 where
  patroniEntry secretName role =
    DerivedSecretEntry
      { derivedSecretEntryName = secretName
      , derivedSecretEntryKey = "password"
      , derivedSecretEntryContext = patroniRoleContext namespace release role
      }
