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
-- consumption conflicts. Audience and complete-manifest identity are structural —
-- a cross-role or cross-manifest permit is refused regardless of state. This module
-- is pure: admission, verifier readiness, and freshness are supplied by the
-- interpreter as observations.
module Prodbox.Lifecycle.Decommission.Permit
  ( DecommissionPermit (..)
  , AdmissionState (..)
  , DecommissionPreflight
  , DecommissionPreflightError (..)
  , bindDecommissionPreflight
  , decommissionPreflightManifestDigest
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
import Prodbox.Lifecycle.Decommission.Manifest
  ( VerifiedDecommissionManifest
  , verifiedManifestDigest
  , verifiedVerifierBinding
  )
import Prodbox.Lifecycle.Decommission.Verifier
  ( ExternalArtifactPath
  , PinnedExecutionDecision
  , PreflightedVerifierArtifact
  , VerifierBinding
  , pinnedExecutionBinding
  , pinnedExecutionIsCurrent
  , pinnedSelfExecutionPath
  , preflightedVerifierBinding
  )

-- | A signed one-time decommission permit: the runner role it is issued for, the
-- committed plan (manifest digest) it authorizes, and a nonce.
data DecommissionPermit = DecommissionPermit
  { decommissionPermitAudience :: !RunnerRole
  , decommissionPermitManifestDigest :: !FrameDigest
  , decommissionPermitNonce :: !Text
  }
  deriving (Eq, Show)

-- | Whether normal admission has been frozen, as observed by the interpreter. A
-- decommission run may not proceed while normal operations can still be admitted.
data AdmissionState
  = AdmissionFrozen
  | AdmissionOpen
  deriving (Eq, Show)

-- | Opaque evidence that the exact verifier bound into one authenticated complete
-- manifest was reopened successfully and that this process is that pinned build.
-- There is deliberately no public constructor: neither a Boolean nor a caller-made
-- enum may authorize the point of no return.
data DecommissionPreflight = DecommissionPreflight
  { decommissionPreflightManifestDigest :: !FrameDigest
  , decommissionPreflightVerifierBinding :: !VerifierBinding
  }
  deriving (Eq, Show)

data DecommissionPreflightError
  = -- | The reopened artifact is not the verifier bound by the signed manifest.
    DecommissionPreflightVerifierBindingMismatch
  | -- | The execution decision was produced from a different reopened artifact.
    DecommissionPreflightExecutionBindingMismatch
  | -- | An internally inconsistent opaque execution decision was supplied.
    DecommissionPreflightExecutionDecisionInvalid
  | -- | A different/new build is running and must replace itself with this path.
    DecommissionPreflightPinnedSelfExecutionRequired !ExternalArtifactPath
  deriving (Eq, Show)

-- | Join independently opaque authentication, disk-preflight, and running-build
-- evidence.  Success is the only way to obtain readiness accepted by the permit
-- fold.
bindDecommissionPreflight
  :: VerifiedDecommissionManifest
  -> PreflightedVerifierArtifact
  -> PinnedExecutionDecision
  -> Either DecommissionPreflightError DecommissionPreflight
bindDecommissionPreflight verified preflighted execution
  | preflightedBinding /= expectedBinding =
      Left DecommissionPreflightVerifierBindingMismatch
  | pinnedExecutionBinding execution /= expectedBinding =
      Left DecommissionPreflightExecutionBindingMismatch
  | Just path <- pinnedSelfExecutionPath execution =
      Left (DecommissionPreflightPinnedSelfExecutionRequired path)
  | not (pinnedExecutionIsCurrent execution) =
      Left DecommissionPreflightExecutionDecisionInvalid
  | otherwise =
      Right
        DecommissionPreflight
          { decommissionPreflightManifestDigest = verifiedManifestDigest verified
          , decommissionPreflightVerifierBinding = expectedBinding
          }
 where
  expectedBinding = verifiedVerifierBinding verified
  preflightedBinding = preflightedVerifierBinding preflighted

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
  | -- | The permit is not bound to the authenticated complete manifest.
    DecommissionWrongManifest
  | -- | Normal admission is still open; freeze it before teardown.
    DecommissionAdmissionNotFrozen
  | -- | The exported verifier/runner artifact preflight has not succeeded.
    DecommissionVerifierNotReady
  | -- | The supplied readiness evidence belongs to another manifest/build.
    DecommissionVerifierBoundToDifferentManifest
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

-- | Decide whether the Decommission Runner, committed to @verified@, accepts
-- @permit@ under the observed admission/verifier/freshness and its current state.
-- Audience and complete-manifest identity are checked first.  Both first acceptance
-- and replay require current preflight evidence for that manifest; permit expiry is
-- checked only before first consumption so a lost response remains recoverable.
decideDecommissionPermit
  :: VerifiedDecommissionManifest
  -> AdmissionState
  -> Maybe DecommissionPreflight
  -> PermitFreshness
  -> DecommissionRunnerState
  -> DecommissionPermit
  -> DecommissionPermitDecision
decideDecommissionPermit verified admission preflight freshness state permit
  | decommissionPermitAudience permit /= DecommissionRunner =
      DecommissionPermitRefused DecommissionWrongAudience
  | decommissionPermitManifestDigest permit /= expectedDigest =
      DecommissionPermitRefused DecommissionWrongManifest
  | admission /= AdmissionFrozen =
      DecommissionPermitRefused DecommissionAdmissionNotFrozen
  | otherwise = case preflight of
      Nothing -> DecommissionPermitRefused DecommissionVerifierNotReady
      Just ready
        | decommissionPreflightManifestDigest ready /= expectedDigest
            || decommissionPreflightVerifierBinding ready /= expectedBinding ->
            DecommissionPermitRefused DecommissionVerifierBoundToDifferentManifest
        | otherwise -> decideReady state
 where
  expectedDigest = verifiedManifestDigest verified
  expectedBinding = verifiedVerifierBinding verified
  decideReady runnerState = case runnerState of
    DecommissionAwaitingPermit
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
  :: VerifiedDecommissionManifest
  -> AdmissionState
  -> Maybe DecommissionPreflight
  -> PermitFreshness
  -> DecommissionRunnerState
  -> DecommissionPermit
  -> (DecommissionPermitDecision, DecommissionRunnerState)
stepDecommissionPermit verified admission verifier freshness state permit =
  let decision = decideDecommissionPermit verified admission verifier freshness state permit
   in (decision, applyDecommissionPermit decision state)
