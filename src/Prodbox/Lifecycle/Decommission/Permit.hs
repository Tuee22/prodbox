-- | Sprint 4.50: the Decommission Runner's one-time permit family and acceptance
-- fold — the gate that authorizes a total-teardown run past the point of no
-- return.
--
-- A total teardown is a distinct runner role. Its permit is disjoint from the
-- Admin Action Runner's family (see 'Prodbox.Lifecycle.Authority.AdminAction',
-- whose @AdminAction@ type explicitly cannot represent decommission): a decommission
-- permit binds the exact committed plan (by manifest digest) it authorizes, and its
-- acceptance requires more than freshness — admission must already be frozen and the
-- exported/pinned verifier + Decommission-Runner artifact preflight must have
-- succeeded, because Authority shutdown and the point-of-no-return receipt are
-- illegal until then.
--
-- The acceptance is one-time: a fresh matching permit under a frozen admission and a
-- ready verifier is accepted and consumed once; replaying the same nonce is
-- idempotent (a lost response recovers by the stable nonce); a divergent nonce after
-- consumption conflicts. Audience and bound plan are structural — a cross-role or
-- cross-plan permit is refused regardless of state. This module is pure: admission,
-- verifier readiness, and freshness are supplied by the interpreter as observations.
module Prodbox.Lifecycle.Decommission.Permit
  ( DecommissionPermit (..)
  , AdmissionState (..)
  , VerifierPreflight (..)
  , DecommissionRunnerState (..)
  , initialDecommissionRunnerState
  , DecommissionPermitDecision (..)
  , DecommissionPermitRefusal (..)
  , decideDecommissionPermit
  , applyDecommissionPermit
  , stepDecommissionPermit
  )
where

import Data.Text (Text)
import Prodbox.Lifecycle.Authority.AdminAction
  ( PermitFreshness (PermitExpired)
  , RunnerRole (DecommissionRunner)
  )
import Prodbox.Lifecycle.Decommission.Frame (FrameDigest)

-- | A signed one-time decommission permit: the runner role it is issued for, the
-- committed plan (manifest digest) it authorizes, and a nonce.
data DecommissionPermit = DecommissionPermit
  { decommissionPermitAudience :: !RunnerRole
  , decommissionPermitPlanDigest :: !FrameDigest
  , decommissionPermitNonce :: !Text
  }
  deriving (Eq, Show)

-- | Whether normal admission has been frozen, as observed by the interpreter. A
-- decommission run may not proceed while normal operations can still be admitted.
data AdmissionState
  = AdmissionFrozen
  | AdmissionOpen
  deriving (Eq, Show)

-- | Whether the exported/pinned verifier + Decommission-Runner artifact preflight
-- has succeeded (the artifact lives outside every deletion target, is fsynced and
-- byte-for-byte read back, and passed its digest/schema/registry self-check).
data VerifierPreflight
  = VerifierArtifactReady
  | VerifierArtifactMissing
  deriving (Eq, Show)

-- | The runner's one-time acceptance state: awaiting its permit, or already
-- consumed (carrying the nonce so replay is recognized and a divergent nonce
-- conflicts).
data DecommissionRunnerState
  = DecommissionAwaitingPermit
  | DecommissionPermitConsumed !Text
  deriving (Eq, Show)

initialDecommissionRunnerState :: DecommissionRunnerState
initialDecommissionRunnerState = DecommissionAwaitingPermit

data DecommissionPermitRefusal
  = -- | The permit is issued for a different runner role.
    DecommissionWrongAudience
  | -- | The permit's bound plan is not the runner's committed plan.
    DecommissionWrongPlan
  | -- | Normal admission is still open; freeze it before teardown.
    DecommissionAdmissionNotFrozen
  | -- | The exported verifier/runner artifact preflight has not succeeded.
    DecommissionVerifierNotReady
  | -- | The permit is past its validity window.
    DecommissionPermitExpired
  | -- | A different nonce after a permit has already been consumed.
    DecommissionNonceConflict
  deriving (Eq, Show)

data DecommissionPermitDecision
  = -- | Accept and consume the permit; cross the point of no return. Carries the nonce.
    DecommissionPermitAccepted !Text
  | -- | The exact permit was already consumed (idempotent replay); do nothing new.
    DecommissionPermitAlreadyConsumed !Text
  | DecommissionPermitRefused !DecommissionPermitRefusal
  deriving (Eq, Show)

-- | Decide whether the Decommission Runner, committed to @expectedPlan@, accepts
-- @permit@ under the observed admission/verifier/freshness and its current state.
-- Audience and bound plan are checked first (a cross-role or cross-plan permit is
-- always refused, regardless of state). While awaiting, the permit is accepted only
-- when admission is frozen, the verifier artifact is ready, and the permit is fresh.
-- Once consumed, replaying the same nonce is idempotent and a different nonce
-- conflicts.
decideDecommissionPermit
  :: FrameDigest
  -> AdmissionState
  -> VerifierPreflight
  -> PermitFreshness
  -> DecommissionRunnerState
  -> DecommissionPermit
  -> DecommissionPermitDecision
decideDecommissionPermit expectedPlan admission verifier freshness state permit
  | decommissionPermitAudience permit /= DecommissionRunner =
      DecommissionPermitRefused DecommissionWrongAudience
  | decommissionPermitPlanDigest permit /= expectedPlan =
      DecommissionPermitRefused DecommissionWrongPlan
  | otherwise = case state of
      DecommissionAwaitingPermit
        | admission /= AdmissionFrozen ->
            DecommissionPermitRefused DecommissionAdmissionNotFrozen
        | verifier /= VerifierArtifactReady ->
            DecommissionPermitRefused DecommissionVerifierNotReady
        | freshness == PermitExpired ->
            DecommissionPermitRefused DecommissionPermitExpired
        | otherwise -> DecommissionPermitAccepted (decommissionPermitNonce permit)
      DecommissionPermitConsumed consumed
        | consumed == decommissionPermitNonce permit ->
            DecommissionPermitAlreadyConsumed consumed
        | otherwise -> DecommissionPermitRefused DecommissionNonceConflict

-- | Fold an acceptance decision into the runner state. Consuming a permit records
-- its nonce; every other decision leaves the state unchanged.
applyDecommissionPermit
  :: DecommissionPermitDecision -> DecommissionRunnerState -> DecommissionRunnerState
applyDecommissionPermit decision state = case decision of
  DecommissionPermitAccepted nonce -> DecommissionPermitConsumed nonce
  DecommissionPermitAlreadyConsumed _ -> state
  DecommissionPermitRefused _ -> state

-- | 'decideDecommissionPermit' then apply, returning the decision and evolved state.
stepDecommissionPermit
  :: FrameDigest
  -> AdmissionState
  -> VerifierPreflight
  -> PermitFreshness
  -> DecommissionRunnerState
  -> DecommissionPermit
  -> (DecommissionPermitDecision, DecommissionRunnerState)
stepDecommissionPermit expectedPlan admission verifier freshness state permit =
  let decision = decideDecommissionPermit expectedPlan admission verifier freshness state permit
   in (decision, applyDecommissionPermit decision state)
