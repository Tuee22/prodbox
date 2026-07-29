{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.50 (Increment DD): the pure decision algebra for the fenced Provider
-- Worker role.
--
-- The Provider Worker is the one control-plane role that runs rare provider tooling
-- (registered-stack Pulumi reconcile, bounded scratch checkpoint execution,
-- authoritative observation and read-back, and the @aws-ses@ non-credential
-- inventory) under one narrow session, on an already sealed/read-back
-- Lifecycle-provider generation supplied by the Lifecycle Authority. Its fence is
-- both structural and dynamic:
--
--   * __Structural.__ 'ProviderIntent' is a closed sum. It cannot represent a
--     credential IAM identity/access-key create/delete/remint, an admin or
--     credential permit, an Authority state write, a backup/TLS identity, a target
--     secret, a Gateway/DNS election, or any SMTP IAM principal/policy/key — those
--     capabilities are unrepresentable, not merely rejected. The @aws-ses@ arm is
--     limited to the sending identity, DKIM, receipt rules, and capture bucket.
--   * __Dynamic.__ 'decideProviderWork' refuses an intent naming an unregistered
--     resource, a stale provider revision, or an expired session; and it admits at
--     most one intent at a time (a second, different intent is refused while one is
--     in flight). Canceled, expired, or ambiguous work enters explicit recovery and
--     a post-recovery grace state before a successor is admitted; a clean,
--     re-observed close returns straight to idle for immediate successor admission.
--
-- This module is pure and total. It mirrors the @decide@ / @evolve@ /
-- @decisionEvents@ / @step@ shape of 'Prodbox.Lifecycle.Authority.BackupRepair' and
-- 'Prodbox.Lifecycle.Authority.Genesis'. Binding the admitted decision to the real
-- narrow-session provider execution (Pulumi/AWS effect + authoritative read-back)
-- and to the retained-store compare-and-swap of the work state is the live-coupled
-- follow-on (Standard-O); the algebra fixes the admission/idempotency/fence
-- discipline so that follow-on cannot loosen it.
module Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( -- * Smart-constructed resource references
    ProviderRefError (..)
  , ProviderStackRef
  , mkProviderStackRef
  , providerStackRefText
  , ProviderCheckpointRef
  , mkProviderCheckpointRef
  , providerCheckpointRefText
  , SesIdentityRef
  , mkSesIdentityRef
  , sesIdentityRefText
  , SesRuleSetRef
  , mkSesRuleSetRef
  , sesRuleSetRefText
  , SesBucketRef
  , mkSesBucketRef
  , sesBucketRefText

    -- * Provider revision
  , ProviderRevision
  , mkProviderRevision
  , providerRevisionNatural

    -- * Registered provider resources
  , RegisteredProviderResources
  , mkRegisteredProviderResources
  , registeredProviderResourceKeys
  , isProviderResourceRegistered

    -- * Intents and coordinates
  , ProviderIntent (..)
  , providerIntentResourceKey
  , ProviderIntentCoordinate
  , providerIntentCoordinate
  , providerIntentCoordinateFromText
  , providerIntentCoordinateText

    -- * State
  , ProviderWorkState (..)
  , initialProviderWorkState
  , providerWorkActiveCoordinate

    -- * Decision algebra
  , ProviderWorkCommand (..)
  , ProviderWorkDecision (..)
  , ProviderWorkRefusal (..)
  , ProviderWorkEvent (..)
  , decideProviderWork
  , providerWorkDecisionEvents
  , evolveProviderWork
  , stepProviderWork
  )
where

import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeMicros)

-- | Why a raw provider-resource reference failed validation.
data ProviderRefError
  = ProviderRefEmpty
  | ProviderRefTooLong !Int
  deriving (Eq, Show)

-- | The maximum reference length; a bounded key keeps coordinates and registered
-- sets small and prevents an unbounded body from smuggling a huge key.
maximumProviderRefLength :: Int
maximumProviderRefLength = 200

validateProviderRef :: Text -> Either ProviderRefError Text
validateProviderRef raw
  | Text.null raw = Left ProviderRefEmpty
  | Text.length raw > maximumProviderRefLength = Left (ProviderRefTooLong (Text.length raw))
  | otherwise = Right raw

-- | A registered Pulumi/provider stack the worker may reconcile, observe, or read
-- back. The named IAM roles it owns are non-credential by construction.
newtype ProviderStackRef = ProviderStackRef Text
  deriving (Eq, Ord, Show)

mkProviderStackRef :: Text -> Either ProviderRefError ProviderStackRef
mkProviderStackRef = fmap ProviderStackRef . validateProviderRef

providerStackRefText :: ProviderStackRef -> Text
providerStackRefText (ProviderStackRef value) = value

-- | A bounded scratch-checkpoint execution target.
newtype ProviderCheckpointRef = ProviderCheckpointRef Text
  deriving (Eq, Ord, Show)

mkProviderCheckpointRef :: Text -> Either ProviderRefError ProviderCheckpointRef
mkProviderCheckpointRef = fmap ProviderCheckpointRef . validateProviderRef

providerCheckpointRefText :: ProviderCheckpointRef -> Text
providerCheckpointRefText (ProviderCheckpointRef value) = value

-- | An @aws-ses@ sending identity (also the DKIM subject).
newtype SesIdentityRef = SesIdentityRef Text
  deriving (Eq, Ord, Show)

mkSesIdentityRef :: Text -> Either ProviderRefError SesIdentityRef
mkSesIdentityRef = fmap SesIdentityRef . validateProviderRef

sesIdentityRefText :: SesIdentityRef -> Text
sesIdentityRefText (SesIdentityRef value) = value

-- | An @aws-ses@ receipt rule set.
newtype SesRuleSetRef = SesRuleSetRef Text
  deriving (Eq, Ord, Show)

mkSesRuleSetRef :: Text -> Either ProviderRefError SesRuleSetRef
mkSesRuleSetRef = fmap SesRuleSetRef . validateProviderRef

sesRuleSetRefText :: SesRuleSetRef -> Text
sesRuleSetRefText (SesRuleSetRef value) = value

-- | An @aws-ses@ capture (inbound-mail) bucket.
newtype SesBucketRef = SesBucketRef Text
  deriving (Eq, Ord, Show)

mkSesBucketRef :: Text -> Either ProviderRefError SesBucketRef
mkSesBucketRef = fmap SesBucketRef . validateProviderRef

sesBucketRefText :: SesBucketRef -> Text
sesBucketRefText (SesBucketRef value) = value

-- | A monotone provider revision. The worker only ever advances toward the bound
-- (committed) revision; a request naming an older revision is refused.
newtype ProviderRevision = ProviderRevision Natural
  deriving (Eq, Ord, Show)

-- | Smart constructor: a provider revision is @>= 1@ (the genesis revision).
mkProviderRevision :: Natural -> Either Text ProviderRevision
mkProviderRevision value
  | value == 0 = Left "provider revision must be >= 1"
  | otherwise = Right (ProviderRevision value)

providerRevisionNatural :: ProviderRevision -> Natural
providerRevisionNatural (ProviderRevision value) = value

-- | The closed set of resource keys the current committed provider intent
-- authorizes. An intent naming a key outside this set is refused before any effect.
newtype RegisteredProviderResources = RegisteredProviderResources (Set Text)
  deriving (Eq, Show)

mkRegisteredProviderResources :: [Text] -> RegisteredProviderResources
mkRegisteredProviderResources = RegisteredProviderResources . Set.fromList

registeredProviderResourceKeys :: RegisteredProviderResources -> Set Text
registeredProviderResourceKeys (RegisteredProviderResources keys) = keys

isProviderResourceRegistered :: Text -> RegisteredProviderResources -> Bool
isProviderResourceRegistered key (RegisteredProviderResources keys) = Set.member key keys

-- | The closed set of normal provider intents. Forbidden capabilities are
-- unrepresentable: there is no constructor for a credential IAM identity/key, an
-- Authority state write, a backup/TLS identity, a target secret, a Gateway/DNS
-- election, or any SMTP IAM principal/policy/key. Only @ReconcileRegisteredStack@
-- carries a requested 'ProviderRevision'; the @aws-ses@ arm reconciles single
-- objects at the bound session revision.
data ProviderIntent
  = ReconcileRegisteredStack !ProviderStackRef !ProviderRevision
  | ObserveRegisteredStack !ProviderStackRef
  | ReadBackRegisteredStack !ProviderStackRef
  | BoundedScratchCheckpoint !ProviderCheckpointRef
  | ReconcileSesSendingIdentity !SesIdentityRef
  | ReconcileSesDkim !SesIdentityRef
  | ReconcileSesReceiptRules !SesRuleSetRef
  | ReconcileSesCaptureBucket !SesBucketRef
  deriving (Eq, Show)

-- | The registered-resource key an intent draws on (the granularity at which the
-- Authority registers what the committed provider intent authorizes).
providerIntentResourceKey :: ProviderIntent -> Text
providerIntentResourceKey intent = case intent of
  ReconcileRegisteredStack ref _ -> "stack:" <> providerStackRefText ref
  ObserveRegisteredStack ref -> "stack:" <> providerStackRefText ref
  ReadBackRegisteredStack ref -> "stack:" <> providerStackRefText ref
  BoundedScratchCheckpoint ref -> "checkpoint:" <> providerCheckpointRefText ref
  ReconcileSesSendingIdentity ref -> "ses-identity:" <> sesIdentityRefText ref
  ReconcileSesDkim ref -> "ses-dkim:" <> sesIdentityRefText ref
  ReconcileSesReceiptRules ref -> "ses-rules:" <> sesRuleSetRefText ref
  ReconcileSesCaptureBucket ref -> "ses-bucket:" <> sesBucketRefText ref

-- | The requested revision an intent is bound to, if it is a revision-bound
-- reconcile.
providerIntentRequestedRevision :: ProviderIntent -> Maybe ProviderRevision
providerIntentRequestedRevision intent = case intent of
  ReconcileRegisteredStack _ revision -> Just revision
  _ -> Nothing

-- | A stable coordinate for an intent: operation kind plus resource key (plus the
-- requested revision for a stack reconcile). Two identical intents share a
-- coordinate, so a resubmission is idempotent; two distinct intents never collide,
-- so a different intent submitted while one is in flight is refused.
newtype ProviderIntentCoordinate = ProviderIntentCoordinate Text
  deriving (Eq, Ord, Show)

providerIntentCoordinate :: ProviderIntent -> ProviderIntentCoordinate
providerIntentCoordinate intent = ProviderIntentCoordinate $ case intent of
  ReconcileRegisteredStack ref revision ->
    "reconcile-stack:"
      <> providerStackRefText ref
      <> "@"
      <> Text.pack (show (providerRevisionNatural revision))
  ObserveRegisteredStack ref -> "observe-stack:" <> providerStackRefText ref
  ReadBackRegisteredStack ref -> "readback-stack:" <> providerStackRefText ref
  BoundedScratchCheckpoint ref -> "scratch-checkpoint:" <> providerCheckpointRefText ref
  ReconcileSesSendingIdentity ref -> "reconcile-ses-identity:" <> sesIdentityRefText ref
  ReconcileSesDkim ref -> "reconcile-ses-dkim:" <> sesIdentityRefText ref
  ReconcileSesReceiptRules ref -> "reconcile-ses-rules:" <> sesRuleSetRefText ref
  ReconcileSesCaptureBucket ref -> "reconcile-ses-bucket:" <> sesBucketRefText ref

-- | A coordinate reference for a @close@/@recover@/@resolve@ command. It is an
-- opaque key the decision matches against the in-flight coordinate; an unknown key
-- simply fails to match and is refused.
providerIntentCoordinateFromText :: Text -> ProviderIntentCoordinate
providerIntentCoordinateFromText = ProviderIntentCoordinate

providerIntentCoordinateText :: ProviderIntentCoordinate -> Text
providerIntentCoordinateText (ProviderIntentCoordinate value) = value

-- | The single-narrow-session state. At most one intent is in flight; recovery and
-- grace mark the canceled/expired/ambiguous path back to admission.
data ProviderWorkState
  = -- | No work in flight; ready to admit a new intent.
    ProviderIdle
  | -- | Exactly one intent is executing under the narrow session.
    ProviderInFlight !ProviderIntentCoordinate
  | -- | The in-flight intent was canceled/expired/ambiguous and is being recovered.
    ProviderRecovering !ProviderIntentCoordinate
  | -- | Recovery resolved; a post-recovery grace state that admits a successor.
    ProviderGrace !ProviderIntentCoordinate
  deriving (Eq, Show)

initialProviderWorkState :: ProviderWorkState
initialProviderWorkState = ProviderIdle

-- | The coordinate currently occupying the session, if any.
providerWorkActiveCoordinate :: ProviderWorkState -> Maybe ProviderIntentCoordinate
providerWorkActiveCoordinate state = case state of
  ProviderIdle -> Nothing
  ProviderInFlight coordinate -> Just coordinate
  ProviderRecovering coordinate -> Just coordinate
  ProviderGrace coordinate -> Just coordinate

-- | The apply-route commands: admit a new intent, or drive the in-flight intent
-- through its clean close or its recovery/grace lifecycle.
data ProviderWorkCommand
  = SubmitProviderIntent !ProviderIntent
  | CloseProviderWork !ProviderIntentCoordinate
  | RecoverProviderWork !ProviderIntentCoordinate
  | ResolveProviderRecovery !ProviderIntentCoordinate
  deriving (Eq, Show)

-- | Why a provider-work command was refused. Every arm is a precise, caller-actionable
-- reason.
data ProviderWorkRefusal
  = -- | The named resource is not in the registered set.
    ProviderWorkUnregisteredResource !Text
  | -- | A stack reconcile requested a revision older than the bound revision
    -- (requested, bound).
    ProviderWorkRevisionStale !Natural !Natural
  | -- | The session deadline has passed.
    ProviderWorkDeadlineReached
  | -- | A different intent is already in flight (the occupying coordinate).
    ProviderWorkOutstandingIntent !ProviderIntentCoordinate
  | -- | A close/recover was issued but nothing is in flight.
    ProviderWorkNotInFlight
  | -- | A close/recover/resolve named a coordinate other than the active one.
    ProviderWorkCoordinateMismatch !ProviderIntentCoordinate
  | -- | A submit arrived while the session was recovering.
    ProviderWorkInRecovery !ProviderIntentCoordinate
  | -- | A resolve arrived but the session was not recovering.
    ProviderWorkNotInRecovery
  deriving (Eq, Show)

-- | The decision over a command against the current state.
data ProviderWorkDecision
  = -- | A new intent is admitted into the narrow session.
    ProviderWorkAdmitted !ProviderIntentCoordinate
  | -- | An idempotent resubmission of the already-in-flight intent (response-loss
    -- safe: never a second admission).
    ProviderWorkAlreadyInFlight !ProviderIntentCoordinate
  | -- | The in-flight intent cleanly closed; the session returns to idle.
    ProviderWorkClosed !ProviderIntentCoordinate
  | -- | The in-flight intent entered recovery.
    ProviderWorkRecovering !ProviderIntentCoordinate
  | -- | Recovery resolved; the session enters grace and admits a successor.
    ProviderWorkResolved !ProviderIntentCoordinate
  | -- | The command was refused; no state advance.
    ProviderWorkRefused !ProviderWorkRefusal
  deriving (Eq, Show)

-- | The state-transition events a decision folds into the next state.
data ProviderWorkEvent
  = ProviderWorkBecameInFlight !ProviderIntentCoordinate
  | ProviderWorkBecameIdle
  | ProviderWorkBecameRecovering !ProviderIntentCoordinate
  | ProviderWorkBecameGrace !ProviderIntentCoordinate
  deriving (Eq, Show)

-- | Decide a command against the current state, the registered resource set, the
-- bound provider revision, and the session clock/deadline. Total: every
-- (state, command) pair yields a decision.
decideProviderWork
  :: RegisteredProviderResources
  -> ProviderRevision
  -- ^ The bound (committed) session revision.
  -> AuthorityTime
  -- ^ Authority-supplied now.
  -> AuthorityTime
  -- ^ The session deadline.
  -> ProviderWorkState
  -> ProviderWorkCommand
  -> ProviderWorkDecision
decideProviderWork registered bound now deadline state command = case command of
  SubmitProviderIntent intent -> decideSubmit intent
  CloseProviderWork coordinate -> decideTransition coordinate onInFlight ProviderWorkClosed
  RecoverProviderWork coordinate -> decideTransition coordinate onInFlight ProviderWorkRecovering
  ResolveProviderRecovery coordinate -> decideResolve coordinate
 where
  decideSubmit intent
    | authorityTimeMicros now >= authorityTimeMicros deadline =
        ProviderWorkRefused ProviderWorkDeadlineReached
    | not (isProviderResourceRegistered key registered) =
        ProviderWorkRefused (ProviderWorkUnregisteredResource key)
    | Just requested <- providerIntentRequestedRevision intent
    , providerRevisionNatural requested < providerRevisionNatural bound =
        ProviderWorkRefused
          (ProviderWorkRevisionStale (providerRevisionNatural requested) (providerRevisionNatural bound))
    | otherwise = case state of
        ProviderIdle -> ProviderWorkAdmitted coordinate
        ProviderGrace _ -> ProviderWorkAdmitted coordinate
        ProviderInFlight active
          | active == coordinate -> ProviderWorkAlreadyInFlight active
          | otherwise -> ProviderWorkRefused (ProviderWorkOutstandingIntent active)
        ProviderRecovering active -> ProviderWorkRefused (ProviderWorkInRecovery active)
   where
    key = providerIntentResourceKey intent
    coordinate = providerIntentCoordinate intent

  -- A close/recover only applies to an in-flight session and only for the exact
  -- in-flight coordinate.
  onInFlight :: ProviderWorkState -> Maybe ProviderIntentCoordinate
  onInFlight st = case st of
    ProviderInFlight active -> Just active
    _ -> Nothing

  decideTransition coordinate select build = case select state of
    Just active
      | active == coordinate -> build coordinate
      | otherwise -> ProviderWorkRefused (ProviderWorkCoordinateMismatch active)
    Nothing -> ProviderWorkRefused ProviderWorkNotInFlight

  decideResolve coordinate = case state of
    ProviderRecovering active
      | active == coordinate -> ProviderWorkResolved coordinate
      | otherwise -> ProviderWorkRefused (ProviderWorkCoordinateMismatch active)
    _ -> ProviderWorkRefused ProviderWorkNotInRecovery

-- | The state-transition events a decision implies. A refusal or an idempotent
-- resubmission implies no transition.
providerWorkDecisionEvents :: ProviderWorkDecision -> [ProviderWorkEvent]
providerWorkDecisionEvents decision = case decision of
  ProviderWorkAdmitted coordinate -> [ProviderWorkBecameInFlight coordinate]
  ProviderWorkAlreadyInFlight _ -> []
  ProviderWorkClosed _ -> [ProviderWorkBecameIdle]
  ProviderWorkRecovering coordinate -> [ProviderWorkBecameRecovering coordinate]
  ProviderWorkResolved coordinate -> [ProviderWorkBecameGrace coordinate]
  ProviderWorkRefused _ -> []

-- | Fold one event into the next state. Total.
evolveProviderWork :: ProviderWorkState -> ProviderWorkEvent -> ProviderWorkState
evolveProviderWork _ event = case event of
  ProviderWorkBecameInFlight coordinate -> ProviderInFlight coordinate
  ProviderWorkBecameIdle -> ProviderIdle
  ProviderWorkBecameRecovering coordinate -> ProviderRecovering coordinate
  ProviderWorkBecameGrace coordinate -> ProviderGrace coordinate

-- | Decide and apply in one step, returning the decision and the resulting state.
stepProviderWork
  :: RegisteredProviderResources
  -> ProviderRevision
  -> AuthorityTime
  -> AuthorityTime
  -> ProviderWorkState
  -> ProviderWorkCommand
  -> (ProviderWorkDecision, ProviderWorkState)
stepProviderWork registered bound now deadline state command =
  let decision = decideProviderWork registered bound now deadline state command
   in (decision, foldl evolveProviderWork state (providerWorkDecisionEvents decision))
