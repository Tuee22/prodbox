{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.50 (Increment DD): the server side of the fenced Provider Worker
-- role's @apply@ and @observe@ routes.
--
-- The pure decision algebra ('Prodbox.Lifecycle.ProviderWorker.ProviderWork')
-- decides whether a provider-work command admits a new narrow-session intent, is an
-- idempotent resubmission, drives the in-flight intent's clean close or
-- recovery/grace lifecycle, or is refused. This endpoint fronts that decision:
-- @apply@ decodes a bounded, versioned, canonical request into a command, rebuilds
-- and re-validates its resource references through the same smart constructors the
-- algebra requires, reads the registered resource set / bound revision / session
-- clock from an injected repository, drives 'stepProviderWork', and compare-and-swaps
-- the work state only when it advanced; @observe@ returns the current state.
--
-- It is pure over the injected repository, so an in-memory fixture exercises every
-- arm without a live cluster, Vault, or provider session. Binding the admitted
-- decision to the real narrow-session provider execution (Pulumi/AWS effect +
-- authoritative read-back) and the real retained-store compare-and-swap are the
-- live-coupled follow-ons (Standard-O).
module Prodbox.ControlPlane.ProviderWorkEndpoint
  ( ProviderWorkRepository (..)
  , ProviderWorkEndpointResult (..)
  , ProviderWorkCommandKind (..)
  , ProviderIntentKind (..)
  , ProviderWorkApplyPayload (..)
  , serveProviderWorkApplyCommand
  , serveProviderWorkApplyRequest
  , serveProviderWorkObserve
  , providerWorkApplyHttpStatus
  , providerWorkApplySummary
  , providerWorkObserveStatus
  , providerWorkObserveSummary
  )
where

import Codec.Serialise (Serialise)
import Data.Bifunctor (first)
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy (ByteString)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError
  , controlPlaneRequestCodecToken
  , decodeControlPlaneRequest
  )
import Prodbox.Lifecycle.Lease (AuthorityTime)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent
      ( BoundedScratchCheckpoint
      , DestroyRegisteredStack
      , IssueEksClientAuth
      , ObserveOperationalIdentity
      , ObserveProviderReadiness
      , ObservePublicARecord
      , ObserveRegisteredStack
      , ObserveSpotPrice
      , ReadBackRegisteredStack
      , ReapTestEbsVolumes
      , ReconcilePublicARecord
      , ReconcileRegisteredStack
      , ReconcileSesCaptureBucket
      , ReconcileSesDkim
      , ReconcileSesDns
      , ReconcileSesReceiptRules
      , ReconcileSesSendingIdentity
      )
  , ProviderReadinessProbe (ProviderReadinessRoute53Zone, ProviderReadinessStsIdentity)
  , ProviderRevision
  , ProviderStackConfig
  , ProviderWorkCommand
    ( CloseProviderWork
    , RecoverProviderWork
    , ResolveProviderRecovery
    , SubmitProviderIntent
    )
  , ProviderWorkDecision
    ( ProviderWorkAdmitted
    , ProviderWorkAlreadyInFlight
    , ProviderWorkClosed
    , ProviderWorkRecovering
    , ProviderWorkRefused
    , ProviderWorkResolved
    )
  , ProviderWorkRefusal
    ( ProviderWorkCoordinateMismatch
    , ProviderWorkDeadlineReached
    , ProviderWorkInRecovery
    , ProviderWorkInvalidStackConfig
    , ProviderWorkNotInFlight
    , ProviderWorkNotInRecovery
    , ProviderWorkOutstandingIntent
    , ProviderWorkRevisionStale
    , ProviderWorkUnregisteredResource
    )
  , ProviderWorkState
    ( ProviderGrace
    , ProviderIdle
    , ProviderInFlight
    , ProviderRecovering
    )
  , RegisteredProviderResources
  , mkEksClientAuthRequest
  , mkProviderCheckpointRef
  , mkProviderRevision
  , mkProviderSpotPriceQuery
  , mkProviderStackRef
  , mkPublicARecordRef
  , mkSesBucketRef
  , mkSesDnsRef
  , mkSesIdentityRef
  , mkSesRuleSetRef
  , providerIntentCoordinateFromText
  , providerStackRefText
  , stepProviderWork
  )

-- | The authority-side inputs a provider-work decision needs, read (never
-- request-carried) so the registered set, bound revision, and session clock stay
-- authority-owned. An in-memory fixture supplies these in a unit test; the
-- production binding derives them from the Authority-minted session permit, the
-- committed provider revision, and the retained work state (Standard-O).
data ProviderWorkRepository m = ProviderWorkRepository
  { readProviderWorkState :: m ProviderWorkState
  , readRegisteredProviderResources :: m RegisteredProviderResources
  , readBoundProviderRevision :: m ProviderRevision
  , readProviderAuthorityNow :: m AuthorityTime
  , readProviderSessionDeadline :: m AuthorityTime
  , commitProviderWorkState :: ProviderWorkState -> m (Either Text ())
  }

-- | The closed outcome of serving an @apply@ request.
data ProviderWorkEndpointResult
  = -- | A well-formed command the proven algebra decided.
    ProviderWorkDecided !ProviderWorkDecision
  | -- | A state advance was decided but its durable commit failed (retry).
    ProviderWorkWriteFailed !Text
  | -- | The request body was not a bounded, canonical, supported-version payload.
    ProviderWorkBadRequest !ControlPlaneRequestCodecError
  | -- | A well-formed body carried a primitive that failed re-validation (empty or
    -- oversized reference, zero revision); the rendered field reason is diagnostic.
    ProviderWorkFieldRejected !Text
  deriving (Eq, Show)

-- | The wire tag for which command arm the @apply@ body carries.
data ProviderWorkCommandKind
  = SubmitCommand
  | CloseCommand
  | RecoverCommand
  | ResolveCommand
  deriving stock (Eq, Show, Enum, Bounded, Generic)
  deriving anyclass (Serialise)

-- | The wire tag for which 'ProviderIntent' constructor a 'SubmitCommand' carries.
data ProviderIntentKind
  = ReconcileStackIntent
  | DestroyStackIntent
  | ObserveStackIntent
  | ReadBackStackIntent
  | ScratchCheckpointIntent
  | SesSendingIdentityIntent
  | SesDkimIntent
  | SesReceiptRulesIntent
  | SesCaptureBucketIntent
  | ReapTestEbsVolumesIntent
  | ObserveSpotPriceIntent
  | ObserveOperationalIdentityIntent
  | ObserveReadinessStsIntent
  | ObserveReadinessRoute53Intent
  | SesDnsIntent
  | EksClientAuthIntent
  | ObservePublicARecordIntent
  | ReconcilePublicARecordIntent
  deriving stock (Eq, Show, Enum, Bounded, Generic)
  deriving anyclass (Serialise)

-- | The raw wire payload for the Provider Worker @apply@ route. It carries only
-- primitive specifics — the command kind, the intent kind and its single resource
-- reference (for a submit), the requested revision (for a stack reconcile), and the
-- coordinate text (for a close/recover/resolve). No credential, key, or ciphertext
-- material crosses this boundary, and the closed 'ProviderIntentKind' cannot name a
-- forbidden capability.
data ProviderWorkApplyPayload = ProviderWorkApplyPayload
  { applyCommandKind :: !ProviderWorkCommandKind
  , applyIntentKind :: !ProviderIntentKind
  , applyResourceRef :: !Text
  , applySecondaryRef :: !Text
  , applyTertiaryRef :: !Text
  , applyRequestedRevision :: !Natural
  , applyStackConfig :: !(Maybe ProviderStackConfig)
  , applyCoordinate :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Serve an already-decoded provider-work command: read the authority-side inputs,
-- decide through 'stepProviderWork', and compare-and-swap the work state only when
-- it advanced.
serveProviderWorkApplyCommand
  :: (Monad m)
  => ProviderWorkRepository m
  -> ProviderWorkCommand
  -> m ProviderWorkEndpointResult
serveProviderWorkApplyCommand repository command = do
  registered <- readRegisteredProviderResources repository
  bound <- readBoundProviderRevision repository
  now <- readProviderAuthorityNow repository
  deadline <- readProviderSessionDeadline repository
  state <- readProviderWorkState repository
  let (decision, next) = stepProviderWork registered bound now deadline state command
  if next == state
    then pure (ProviderWorkDecided decision)
    else do
      committed <- commitProviderWorkState repository next
      pure $ case committed of
        Left detail -> ProviderWorkWriteFailed detail
        Right () -> ProviderWorkDecided decision

-- | Serve an @apply@ request from a raw body: decode the bounded, canonical
-- 'ProviderWorkApplyPayload', rebuild and re-validate its command through the same
-- smart constructors the algebra requires, and run 'serveProviderWorkApplyCommand'.
-- A malformed body or an invalid field is refused before any decision. Pure over the
-- repository; the production repository binding and the narrow-session execution of
-- an admitted decision are the Standard-O follow-ons.
serveProviderWorkApplyRequest
  :: (Monad m)
  => Int
  -> ProviderWorkRepository m
  -> ByteString
  -> m ProviderWorkEndpointResult
serveProviderWorkApplyRequest maximumBytes repository body =
  case decodeControlPlaneRequest maximumBytes body of
    Left err -> pure (ProviderWorkBadRequest err)
    Right payload -> case rebuildProviderWorkCommand payload of
      Left reason -> pure (ProviderWorkFieldRejected reason)
      Right command -> serveProviderWorkApplyCommand repository command

-- | Serve an @observe@: the current provider-work state, no mutation.
serveProviderWorkObserve :: (Monad m) => ProviderWorkRepository m -> m ProviderWorkState
serveProviderWorkObserve = readProviderWorkState

-- | Rebuild the typed command from the raw payload, re-validating references and the
-- requested revision through the algebra's smart constructors. The first failing
-- field's diagnostic reason is returned.
rebuildProviderWorkCommand :: ProviderWorkApplyPayload -> Either Text ProviderWorkCommand
rebuildProviderWorkCommand payload = case applyCommandKind payload of
  SubmitCommand -> SubmitProviderIntent <$> rebuildIntent payload
  CloseCommand -> Right (CloseProviderWork (coordinate payload))
  RecoverCommand -> Right (RecoverProviderWork (coordinate payload))
  ResolveCommand -> Right (ResolveProviderRecovery (coordinate payload))
 where
  coordinate = providerIntentCoordinateFromText . applyCoordinate

-- | Rebuild the 'ProviderIntent' from the intent-kind tag and the single reference.
rebuildIntent :: ProviderWorkApplyPayload -> Either Text ProviderIntent
rebuildIntent payload = case applyIntentKind payload of
  ReconcileStackIntent -> do
    ref <- first (fieldReason "stack") (mkProviderStackRef rawRef)
    revision <- first (fieldReason "revision") (mkProviderRevision (applyRequestedRevision payload))
    config <- maybe (Left "stack-config:missing") Right (applyStackConfig payload)
    Right (ReconcileRegisteredStack ref revision config)
  DestroyStackIntent -> do
    ref <- first (fieldReason "stack") (mkProviderStackRef rawRef)
    revision <- first (fieldReason "revision") (mkProviderRevision (applyRequestedRevision payload))
    config <- maybe (Left "stack-config:missing") Right (applyStackConfig payload)
    Right (DestroyRegisteredStack ref revision config)
  ObserveStackIntent ->
    ObserveRegisteredStack <$> first (fieldReason "stack") (mkProviderStackRef rawRef)
  ReadBackStackIntent ->
    ReadBackRegisteredStack <$> first (fieldReason "stack") (mkProviderStackRef rawRef)
  ScratchCheckpointIntent ->
    BoundedScratchCheckpoint <$> first (fieldReason "checkpoint") (mkProviderCheckpointRef rawRef)
  SesSendingIdentityIntent ->
    ReconcileSesSendingIdentity <$> first (fieldReason "ses-identity") (mkSesIdentityRef rawRef)
  SesDkimIntent ->
    ReconcileSesDkim <$> first (fieldReason "ses-identity") (mkSesIdentityRef rawRef)
  SesReceiptRulesIntent ->
    ReconcileSesReceiptRules
      <$> first
        (fieldReason "ses-rules")
        (mkSesRuleSetRef rawRef (applySecondaryRef payload) (applyTertiaryRef payload))
  SesCaptureBucketIntent ->
    ReconcileSesCaptureBucket <$> first (fieldReason "ses-bucket") (mkSesBucketRef rawRef)
  SesDnsIntent ->
    ReconcileSesDns
      <$> first
        (fieldReason "ses-dns")
        (mkSesDnsRef rawRef (applySecondaryRef payload) (applyTertiaryRef payload))
  ReapTestEbsVolumesIntent ->
    ReapTestEbsVolumes . providerStackRefText
      <$> first (fieldReason "cluster") (mkProviderStackRef rawRef)
  ObserveSpotPriceIntent ->
    ObserveSpotPrice
      <$> first
        (fieldReason "spot-price")
        (mkProviderSpotPriceQuery rawRef (applySecondaryRef payload))
  ObserveOperationalIdentityIntent -> Right ObserveOperationalIdentity
  ObserveReadinessStsIntent -> Right (ObserveProviderReadiness ProviderReadinessStsIdentity)
  ObserveReadinessRoute53Intent ->
    ObserveProviderReadiness . ProviderReadinessRoute53Zone . providerStackRefText
      <$> first (fieldReason "route53-zone") (mkProviderStackRef rawRef)
  EksClientAuthIntent -> do
    publicKey <-
      first
        (const "eks-client-auth-public-key:invalid-base64")
        (Base64.decode (TextEncoding.encodeUtf8 (applyCoordinate payload)))
    IssueEksClientAuth
      <$> first
        (fieldReason "eks-client-auth")
        ( mkEksClientAuthRequest
            rawRef
            (applySecondaryRef payload)
            (applyTertiaryRef payload)
            publicKey
        )
  ObservePublicARecordIntent ->
    ObservePublicARecord
      <$> first
        (fieldReason "public-a-record")
        ( mkPublicARecordRef
            rawRef
            (applySecondaryRef payload)
            (applyRequestedRevision payload)
            (Text.splitOn "," (applyTertiaryRef payload))
        )
  ReconcilePublicARecordIntent ->
    ReconcilePublicARecord
      <$> first
        (fieldReason "public-a-record")
        ( mkPublicARecordRef
            rawRef
            (applySecondaryRef payload)
            (applyRequestedRevision payload)
            (Text.splitOn "," (applyTertiaryRef payload))
        )
 where
  rawRef = applyResourceRef payload
  fieldReason :: (Show e) => Text -> e -> Text
  fieldReason field err = field <> ":" <> Text.pack (show err)

-- | Total HTTP status for an @apply@ result. Every accepted transition (admit,
-- idempotent already-in-flight, clean close, recover, resolve) is @200@; a refused
-- command is @409@; a failed durable commit is @503@; a malformed or invalid body is
-- @400@.
providerWorkApplyHttpStatus :: ProviderWorkEndpointResult -> Int
providerWorkApplyHttpStatus result = case result of
  ProviderWorkBadRequest _ -> 400
  ProviderWorkFieldRejected _ -> 400
  ProviderWorkWriteFailed _ -> 503
  ProviderWorkDecided decision -> case decision of
    ProviderWorkAdmitted _ -> 200
    ProviderWorkAlreadyInFlight _ -> 200
    ProviderWorkClosed _ -> 200
    ProviderWorkRecovering _ -> 200
    ProviderWorkResolved _ -> 200
    ProviderWorkRefused _ -> 409

-- | Stable single-line summary for an @apply@ result.
providerWorkApplySummary :: ProviderWorkEndpointResult -> Text
providerWorkApplySummary result = case result of
  ProviderWorkBadRequest err -> "provider-work-bad-request:" <> controlPlaneRequestCodecToken err
  ProviderWorkFieldRejected reason -> "provider-work-invalid-field:" <> reason
  ProviderWorkWriteFailed _ -> "provider-work-write-failed"
  ProviderWorkDecided decision -> case decision of
    ProviderWorkAdmitted _ -> "provider-work-admitted"
    ProviderWorkAlreadyInFlight _ -> "provider-work-already-in-flight"
    ProviderWorkClosed _ -> "provider-work-closed"
    ProviderWorkRecovering _ -> "provider-work-recovering"
    ProviderWorkResolved _ -> "provider-work-resolved"
    ProviderWorkRefused refusal -> "provider-work-refused:" <> refusalToken refusal

-- | Stable kebab token for every refusal constructor (exhaustive).
refusalToken :: ProviderWorkRefusal -> Text
refusalToken refusal = case refusal of
  ProviderWorkUnregisteredResource _ -> "unregistered-resource"
  ProviderWorkInvalidStackConfig _ -> "invalid-stack-config"
  ProviderWorkRevisionStale _ _ -> "revision-stale"
  ProviderWorkDeadlineReached -> "deadline-reached"
  ProviderWorkOutstandingIntent _ -> "outstanding-intent"
  ProviderWorkNotInFlight -> "not-in-flight"
  ProviderWorkCoordinateMismatch _ -> "coordinate-mismatch"
  ProviderWorkInRecovery _ -> "in-recovery"
  ProviderWorkNotInRecovery -> "not-in-recovery"

-- | Total HTTP status for an @observe@ read. A read never fails at this layer, so
-- the observed state is always @200@.
providerWorkObserveStatus :: ProviderWorkState -> Int
providerWorkObserveStatus _ = 200

-- | Stable single-line summary naming the observed session phase. Exhaustive over
-- 'ProviderWorkState'.
providerWorkObserveSummary :: ProviderWorkState -> Text
providerWorkObserveSummary state = case state of
  ProviderIdle -> "provider-work-observe:idle"
  ProviderInFlight _ -> "provider-work-observe:in-flight"
  ProviderRecovering _ -> "provider-work-observe:recovering"
  ProviderGrace _ -> "provider-work-observe:grace"
