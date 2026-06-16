{-# LANGUAGE OverloadedStrings #-}

-- | Pure Sprint 4.32 decisions for the federated Vault lifecycle. The effectful
-- interpreter in "Prodbox.CLI.Rke2" deploys charts and talks to Vault; this
-- module owns the total root/child classification and fail-closed parent
-- readiness policy.
module Prodbox.Lifecycle.FederatedVault
  ( FederatedVaultLifecycle (..)
  , ParentVaultReadiness (..)
  , parentReadinessDecision
  , renderParentReadinessBlock
  , vaultLifecycleFromBasics
  , vaultLifecycleHelmSealArgs
  , renderVaultLifecyclePlan
  )
where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Config.Basics
  ( ParentRef (..)
  , SealMode (..)
  , UnencryptedBasics (..)
  )
import Prodbox.Vault.Client (SealStatus (..))

data FederatedVaultLifecycle
  = RootVaultLifecycle Text Text
  | ChildVaultLifecycle Text Text ParentRef
  deriving (Eq, Show)

data ParentVaultReadiness
  = ParentVaultReady
  | ParentVaultUninitialized
  | ParentVaultSealed
  | ParentVaultUnreachable String
  deriving (Eq, Show)

vaultLifecycleFromBasics :: UnencryptedBasics -> Either String FederatedVaultLifecycle
vaultLifecycleFromBasics basics =
  case (basicsSealMode basics, basicsParentRef basics) of
    (SealModeShamir, Nothing) ->
      Right (RootVaultLifecycle (basicsClusterId basics) (basicsVaultAddress basics))
    (SealModeTransit, Just parent) ->
      Right (ChildVaultLifecycle (basicsClusterId basics) (basicsVaultAddress basics) parent)
    (SealModeShamir, Just _) ->
      Left "root (shamir) Vault lifecycle cannot carry a parent_ref"
    (SealModeTransit, Nothing) ->
      Left "child (transit) Vault lifecycle requires a parent_ref"

parentReadinessDecision :: Either String SealStatus -> ParentVaultReadiness
parentReadinessDecision statusResult =
  case statusResult of
    Left err -> ParentVaultUnreachable err
    Right status
      | not (sealStatusInitialized status) -> ParentVaultUninitialized
      | sealStatusSealed status -> ParentVaultSealed
      | otherwise -> ParentVaultReady

renderParentReadinessBlock :: ParentRef -> ParentVaultReadiness -> Maybe String
renderParentReadinessBlock parent readiness =
  case readiness of
    ParentVaultReady -> Nothing
    ParentVaultUninitialized ->
      Just
        ( "Blocked: parent Vault "
            ++ Text.unpack (parentRefClusterId parent)
            ++ " is not initialized; child auto-unseal cannot proceed."
        )
    ParentVaultSealed ->
      Just
        ( "Blocked: parent Vault "
            ++ Text.unpack (parentRefClusterId parent)
            ++ " is sealed; child auto-unseal cannot proceed. Unseal the parent first."
        )
    ParentVaultUnreachable err ->
      Just
        ( "Blocked: parent Vault "
            ++ Text.unpack (parentRefClusterId parent)
            ++ " is unreachable at "
            ++ Text.unpack (parentRefVaultAddress parent)
            ++ "; child auto-unseal cannot proceed: "
            ++ err
        )

vaultLifecycleHelmSealArgs :: FederatedVaultLifecycle -> [String]
vaultLifecycleHelmSealArgs lifecycle =
  case lifecycle of
    RootVaultLifecycle _ _ -> []
    ChildVaultLifecycle _ _ parent ->
      [ "--set"
      , "seal.mode=transit"
      , "--set"
      , "seal.transit.address=" ++ Text.unpack (parentRefVaultAddress parent)
      , "--set"
      , "seal.transit.keyName=" ++ transitKeyNameForHelm parent
      ]

renderVaultLifecyclePlan :: FederatedVaultLifecycle -> [String]
renderVaultLifecyclePlan lifecycle =
  case lifecycle of
    RootVaultLifecycle clusterId address ->
      [ "VAULT_LIFECYCLE=root"
      , "VAULT_CLUSTER_ID=" ++ Text.unpack clusterId
      , "VAULT_ADDRESS=" ++ Text.unpack address
      , "VAULT_SEAL_MODE=shamir"
      ]
    ChildVaultLifecycle clusterId address parent ->
      [ "VAULT_LIFECYCLE=child"
      , "VAULT_CLUSTER_ID=" ++ Text.unpack clusterId
      , "VAULT_ADDRESS=" ++ Text.unpack address
      , "VAULT_SEAL_MODE=transit"
      , "PARENT_CLUSTER_ID=" ++ Text.unpack (parentRefClusterId parent)
      , "PARENT_VAULT_ADDRESS=" ++ Text.unpack (parentRefVaultAddress parent)
      , "PARENT_TRANSIT_KEY=" ++ transitKeyNameForHelm parent
      ]

transitKeyNameForHelm :: ParentRef -> String
transitKeyNameForHelm parent =
  Text.unpack (normalizeTransitKeyRef (parentRefTransitKey parent))

normalizeTransitKeyRef :: Text -> Text
normalizeTransitKeyRef raw =
  fromMaybe stripped (Text.stripPrefix "transit/" stripped)
 where
  stripped = Text.dropWhileEnd (== '/') (Text.dropWhile (== '/') raw)
