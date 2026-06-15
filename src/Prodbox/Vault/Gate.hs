{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.37: the sealed-Vault readiness gate that every
-- @prodbox aws stack ...@ operation consults before touching Pulumi state.
-- The decision is pure (it folds a 'SealStatus' probe, or its failure, into a
-- typed verdict) so it is unit-tested without a live Vault; the apply-path
-- wiring that runs the probe and refuses before any Pulumi command starts is
-- the activation step that lands once the in-cluster Vault is deployable
-- (Sprint 3.17). See
-- @documents/engineering/vault_doctrine.md@ §10 (Pulumi backend under Vault).
module Prodbox.Vault.Gate
  ( VaultGateDecision (..)
  , VaultGateOutcome (..)
  , vaultGateDecision
  , vaultGateOutcome
  , vaultGateAllows
  , renderVaultGateBlock
  )
where

import Prodbox.Http.Client (HttpError, renderHttpError)
import Prodbox.Vault.Client (SealStatus (..))

-- | The verdict for a secret-dependent operation (Pulumi preview / update /
-- destroy, AWS deployment-credential retrieval). Only 'VaultGateAllow'
-- permits the operation; every other constructor is fail-closed.
data VaultGateDecision
  = VaultGateAllow
  | VaultGateBlockUnreachable String
  | VaultGateBlockUninitialized
  | VaultGateBlockSealed
  deriving (Eq, Show)

-- | Fold a seal-status probe (or its failure) into the gate verdict. A
-- sealed, uninitialized, or unreachable Vault blocks; only an initialized,
-- unsealed Vault allows.
vaultGateDecision :: Either HttpError SealStatus -> VaultGateDecision
vaultGateDecision result = case result of
  Left err -> VaultGateBlockUnreachable (renderHttpError err)
  Right status
    | not (sealStatusInitialized status) -> VaultGateBlockUninitialized
    | sealStatusSealed status -> VaultGateBlockSealed
    | otherwise -> VaultGateAllow

vaultGateAllows :: VaultGateDecision -> Bool
vaultGateAllows decision = case decision of
  VaultGateAllow -> True
  _ -> False

-- | The fail-closed operator message for a blocked decision (per
-- vault_doctrine.md §10). 'Nothing' when the gate allows. The message never
-- includes secret values and makes clear that no Pulumi command was started.
renderVaultGateBlock :: VaultGateDecision -> Maybe String
renderVaultGateBlock decision = case decision of
  VaultGateAllow -> Nothing
  VaultGateBlockUnreachable detail ->
    Just (gateBlockMessage ("Vault is unreachable (" ++ detail ++ ")."))
  VaultGateBlockUninitialized ->
    Just (gateBlockMessage "Vault is not initialized.")
  VaultGateBlockSealed ->
    Just (gateBlockMessage "Vault is sealed.")

-- | The pure result of consulting the gate at an apply-path call site: either
-- proceed, or refuse with the rendered operator message (which the caller
-- prints to stderr before returning a non-zero exit). 'vaultGateOutcome' is
-- total — 'renderVaultGateBlock' returns 'Nothing' iff the decision allows — so
-- allow maps to proceed and every fail-closed decision maps to a refusal. This
-- is the unit-testable decision→action seam the @prodbox aws stack ...@ wiring
-- folds over (the live wiring itself activates with the deployed Vault, Sprint
-- 3.17).
data VaultGateOutcome
  = VaultGateProceed
  | VaultGateRefuse String
  deriving (Eq, Show)

vaultGateOutcome :: Either HttpError SealStatus -> VaultGateOutcome
vaultGateOutcome probe =
  case renderVaultGateBlock (vaultGateDecision probe) of
    Nothing -> VaultGateProceed
    Just message -> VaultGateRefuse message

gateBlockMessage :: String -> String
gateBlockMessage reason =
  "Blocked: "
    ++ reason
    ++ " Pulumi backend state and AWS deployment credentials are intentionally"
    ++ " unavailable. No preview/update/destroy was started."
    ++ " Run: prodbox vault unseal"
