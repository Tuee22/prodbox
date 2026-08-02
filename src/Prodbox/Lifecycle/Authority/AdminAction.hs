{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.48: the retained Lifecycle Authority's disjoint admin-action permit
-- family and the Admin Action Runner's one-time acceptance fold.
--
-- The Admin Action Runner performs exactly ONE receipt-committed exceptional
-- action per signed permit — one of the disjoint 'AdminAction' family
-- (@DestroyAwsSes@, legacy-backend migrate / retained-store compatibility, or a
-- quota reconcile-and-status action). It is a distinct runner role: it cannot
-- create or deliver credentials, accept a normal provider intent, widen
-- coordinates, or perform decommission — those are other runners' disjoint permit
-- families, and this type cannot even represent them.
--
-- A permit names its audience 'RunnerRole' and its single bound 'AdminAction'. The
-- Admin Action Runner, instantiated for exactly one expected action, accepts a
-- permit only if the audience is the Admin Action Runner AND the bound action is
-- its expected one AND the permit is fresh — and only once. A cross-role permit
-- (issued for a different runner) or a cross-action permit is refused; replaying
-- the consumed permit is idempotent (so a lost response recovers by the stable
-- nonce); a different nonce after consumption conflicts.
--
-- This module is pure. Freshness (expiry) is supplied by the interpreter as an
-- observation, so the fold stays decoupled from the authority clock.
module Prodbox.Lifecycle.Authority.AdminAction
  ( -- * Disjoint action family and audiences
    AdminAction (..)
  , RunnerRole (..)
  , AdminActionPermit (..)
  , PermitFreshness (..)

    -- * Runner acceptance state
  , AdminRunnerState (..)
  , initialAdminRunnerState

    -- * Acceptance fold
  , AdminPermitDecision (..)
  , AdminPermitRefusal (..)
  , decideAdminPermit
  , applyAdminPermit
  , stepAdminPermit
  )
where

import Codec.Serialise (Serialise)
import Data.Text (Text)
import GHC.Generics (Generic)

-- | The disjoint family of exceptional admin actions. The Admin Action Runner
-- performs exactly one per receipt-committed permit. This family excludes normal
-- provider intents, credential creation/delivery, and decommission by
-- construction.
data AdminAction
  = -- | The closed always-run SES teardown action.
    DestroyAwsSes
  | -- | Legacy-backend migrate / retained-store compatibility.
    MigrateLegacyBackend
  | -- | Quota reconcile-and-status.
    ReconcileQuota
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | The permit-selected runner role a permit authorizes. An 'AdminActionPermit'
-- authorizes only the 'AdminActionRunner'; the Provider Worker and Credential
-- Provisioner have their own disjoint permit families and cannot accept this one.
data RunnerRole
  = AdminActionRunner
  | CredentialProvisioner
  | ProviderWorker
  | DecommissionRunner
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | A signed one-time admin-action permit: the runner role it is issued for, its
-- single bound action, and a nonce. (Signing-generation, coordinate, and expiry
-- binding are the interpreter's; this fold owns the acceptance invariant, taking
-- expiry as a 'PermitFreshness' observation.)
data AdminActionPermit = AdminActionPermit
  { adminPermitAudience :: !RunnerRole
  , adminPermitAction :: !AdminAction
  , adminPermitNonce :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Whether the permit is still within its validity window, as observed by the
-- interpreter.
data PermitFreshness
  = PermitFresh
  | PermitExpired
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | The Admin Action Runner's one-time acceptance state for its instantiated
-- action: awaiting its permit, or already consumed (carrying the consumed nonce
-- so replay is recognized and a divergent nonce conflicts).
data AdminRunnerState
  = AdminAwaitingPermit
  | AdminPermitConsumed !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

initialAdminRunnerState :: AdminRunnerState
initialAdminRunnerState = AdminAwaitingPermit

data AdminPermitRefusal
  = -- | The permit is issued for a different runner role.
    AdminPermitWrongAudience
  | -- | The permit's bound action is not the runner's instantiated action.
    AdminPermitWrongAction
  | -- | The permit is past its validity window.
    AdminPermitExpired
  | -- | A different nonce after a permit has already been consumed.
    AdminPermitNonceConflict
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AdminPermitDecision
  = -- | Accept and consume the permit; run the bound action. Carries the nonce.
    AdminPermitAccepted !Text
  | -- | The exact permit was already consumed (idempotent replay); run nothing.
    AdminPermitAlreadyConsumed !Text
  | AdminPermitRefused !AdminPermitRefusal
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Decide whether the Admin Action Runner instantiated for @expectedAction@
-- accepts @permit@ under @freshness@ and its current @state@. Audience and action
-- are checked first (a cross-role or cross-action permit is always refused,
-- regardless of state). While awaiting, a fresh matching permit is accepted; an
-- expired one is refused. Once consumed, replaying the same nonce is idempotent
-- and a different nonce conflicts.
decideAdminPermit
  :: AdminAction
  -> PermitFreshness
  -> AdminRunnerState
  -> AdminActionPermit
  -> AdminPermitDecision
decideAdminPermit expectedAction freshness state permit
  | adminPermitAudience permit /= AdminActionRunner =
      AdminPermitRefused AdminPermitWrongAudience
  | adminPermitAction permit /= expectedAction =
      AdminPermitRefused AdminPermitWrongAction
  | otherwise = case state of
      AdminAwaitingPermit -> case freshness of
        PermitExpired -> AdminPermitRefused AdminPermitExpired
        PermitFresh -> AdminPermitAccepted (adminPermitNonce permit)
      AdminPermitConsumed consumed
        | consumed == adminPermitNonce permit -> AdminPermitAlreadyConsumed consumed
        | otherwise -> AdminPermitRefused AdminPermitNonceConflict

-- | Fold an acceptance decision into the runner state. Consuming a permit records
-- its nonce; every other decision leaves the state unchanged.
applyAdminPermit :: AdminPermitDecision -> AdminRunnerState -> AdminRunnerState
applyAdminPermit decision state = case decision of
  AdminPermitAccepted nonce -> AdminPermitConsumed nonce
  AdminPermitAlreadyConsumed _ -> state
  AdminPermitRefused _ -> state

-- | 'decideAdminPermit' then apply, returning the decision and the evolved state.
stepAdminPermit
  :: AdminAction
  -> PermitFreshness
  -> AdminRunnerState
  -> AdminActionPermit
  -> (AdminPermitDecision, AdminRunnerState)
stepAdminPermit expectedAction freshness state permit =
  let decision = decideAdminPermit expectedAction freshness state permit
   in (decision, applyAdminPermit decision state)
