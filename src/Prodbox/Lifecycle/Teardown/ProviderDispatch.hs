{-# LANGUAGE OverloadedStrings #-}

-- | Stable, Lifecycle-Authority-mediated Provider dispatch for registered
-- teardown targets.  A graph operation receives distinct deterministic keys
-- for its decision observation, mutation, and mandatory absence read-back;
-- no cleanup call allocates a wall-clock/fresh submission identity.
module Prodbox.Lifecycle.Teardown.ProviderDispatch
  ( ProviderDispatchPurpose (..)
  , ProviderDispatchKey
  , providerDispatchKeyOperationId
  , providerDispatchKeyPurpose
  , providerDispatchSubmissionKey
  , observationRevisionForProviderDispatchKey
  , mkProviderDispatchKey
  , TeardownProviderBoundaryResult (..)
  , TeardownProviderBoundary (..)
  , productionTeardownProviderBoundary
  , providerDispatchKeyCleanupOwner
  , teardownProviderDispatchOwnershipIsTotal
  , dispatchRegisteredProviderObservation
  , dispatchRegisteredProviderMutation
  , ProviderDispatchError (..)
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word64, Word8)
import Prodbox.ControlPlane.AuthorityProviderEndpoint
  ( AuthorityProviderClientError (..)
  )
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller
  )
import Prodbox.ControlPlane.ProviderCaller
  ( ProviderCallerError (..)
  , dispatchHostProviderIntentOwnedBy
  , renderProviderCallerError
  )
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (ProviderIntentExecutionObserved)
  )
import Prodbox.Lifecycle.Authority.Admission
  ( ProviderOperationCleanupOwner (ProviderOperationOwnedByCleanupOperation)
  )
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( ClientSubmissionKey
  , ClientSubmissionKeyError
  , clientSubmissionKeyText
  , mkClientSubmissionKey
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupOperationId
  , cleanupOperationIdText
  , mkCleanupOperationId
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  , providerIntentCoordinate
  )
import Prodbox.Lifecycle.Teardown.Model (ObservationRevision (..))
import Prodbox.Lifecycle.Teardown.RegisteredTargetResult
  ( RegisteredTargetMutationAttempt (..)
  )

-- | One graph operation may need a fresh decision observation immediately
-- before mutation.  These are deterministic sub-identities, not retries with
-- newly allocated keys.
data ProviderDispatchPurpose
  = ProviderDecisionObservation
  | ProviderRegisteredMutation
  | ProviderAbsenceReadBack
  deriving (Bounded, Enum, Eq, Ord, Show)

data ProviderDispatchKey = ProviderDispatchKey
  { internalProviderDispatchOperationId :: !CleanupOperationId
  , internalProviderDispatchPurpose :: !ProviderDispatchPurpose
  , internalProviderDispatchSubmissionKey :: !ClientSubmissionKey
  }
  deriving (Eq, Show)

providerDispatchKeyOperationId
  :: ProviderDispatchKey -> CleanupOperationId
providerDispatchKeyOperationId = internalProviderDispatchOperationId

providerDispatchKeyPurpose
  :: ProviderDispatchKey -> ProviderDispatchPurpose
providerDispatchKeyPurpose = internalProviderDispatchPurpose

providerDispatchSubmissionKey
  :: ProviderDispatchKey -> ClientSubmissionKey
providerDispatchSubmissionKey = internalProviderDispatchSubmissionKey

-- | Stable observation identity for the exact Authority submission.  It is
-- derived from the complete validated submission key rather than a clock, so
-- retrying one graph operation retains its revision while decision and
-- read-back observations remain distinct.  The surrounding exact evidence
-- scope still carries the full run, registry, foundation, account, and region
-- binding; this compact revision is not used as a standalone authority.
observationRevisionForProviderDispatchKey
  :: ProviderDispatchKey -> ObservationRevision
observationRevisionForProviderDispatchKey dispatchKey =
  ObservationRevision
    ( foldl'
        accumulate
        0
        (take 8 (ByteString.unpack digest))
    )
 where
  digest =
    SHA256.hash
      ( TextEncoding.encodeUtf8
          (clientSubmissionKeyText (providerDispatchSubmissionKey dispatchKey))
      )
  accumulate :: Word64 -> Word8 -> Word64
  accumulate value byte = value * 256 + fromIntegral byte

data ProviderDispatchError
  = ProviderDispatchKeyInvalid !ClientSubmissionKeyError
  | ProviderDispatchIntentPurposeMismatch
      !ProviderDispatchPurpose
      !ProviderIntent
  | ProviderDispatchObservationUnobservable !Text
  | ProviderDispatchObservationRefused !Text
  deriving (Eq, Show)

mkProviderDispatchKey
  :: CleanupOperationId
  -> ProviderDispatchPurpose
  -> Either ProviderDispatchError ProviderDispatchKey
mkProviderDispatchKey operationId purpose = do
  submissionKey <-
    either
      (Left . ProviderDispatchKeyInvalid)
      Right
      ( mkClientSubmissionKey
          ( cleanupOperationIdText operationId
              <> ":"
              <> purposeSuffix purpose
          )
      )
  Right
    ProviderDispatchKey
      { internalProviderDispatchOperationId = operationId
      , internalProviderDispatchPurpose = purpose
      , internalProviderDispatchSubmissionKey = submissionKey
      }

purposeSuffix :: ProviderDispatchPurpose -> Text
purposeSuffix purpose = case purpose of
  ProviderDecisionObservation -> "decision-observe"
  ProviderRegisteredMutation -> "mutate"
  ProviderAbsenceReadBack -> "absence-readback"

-- | Preserve the Authority's definite refusal separately from a transport or
-- availability failure.  A refused mutation is terminal; an unavailable
-- response remains ambiguous and must be closed by its independent read-back.
data TeardownProviderBoundaryResult
  = TeardownProviderCompleted !Text
  | TeardownProviderRefused !Text
  | TeardownProviderUnavailable !Text
  deriving (Eq, Show)

-- | The only physical seam used here.  Production routes through the local
-- Lifecycle Authority, which journals and dispatches a closed ProviderIntent.
-- Tests inject a deterministic fake at the same boundary.
-- | Sprint 4.85: the boundary receives the whole dispatch key rather than only
-- its submission key.
--
-- The key already carried the cleanup operation the dispatch belongs to, and
-- passing only the derived submission string threw that away at exactly the
-- seam where the Authority could have retained it — which is what
-- @ProviderOperationCleanupRunOwnershipUnavailable@ named. Recovering the
-- operation id by parsing the submission string back apart would be deriving an
-- identity from a rendering; the key is the identity.
newtype TeardownProviderBoundary m = TeardownProviderBoundary
  { runTeardownProviderBoundary
      :: ProviderDispatchKey
      -> ProviderIntent
      -> m TeardownProviderBoundaryResult
  }

productionTeardownProviderBoundary
  :: ExternalLifecycleAuthorityCaller
  -> FilePath
  -> TeardownProviderBoundary IO
productionTeardownProviderBoundary caller repoRoot =
  TeardownProviderBoundary $ \dispatchKey intent -> do
    dispatched <-
      dispatchHostProviderIntentOwnedBy
        caller
        repoRoot
        (clientSubmissionKeyText (providerDispatchSubmissionKey dispatchKey))
        intent
        (providerDispatchKeyCleanupOwner dispatchKey)
    pure (classifyProviderCallerResult dispatched)

-- | The cleanup operation a teardown dispatch belongs to, as the owner the
-- Authority retains beside the intent.
--
-- Total by construction: every dispatch key holds a 'CleanupOperationId',
-- because a teardown dispatch has no other way to name itself. The production
-- boundary above is defined in terms of this, so the ownership the Authority
-- records and the ownership this projection claims cannot drift apart.
providerDispatchKeyCleanupOwner
  :: ProviderDispatchKey -> ProviderOperationCleanupOwner
providerDispatchKeyCleanupOwner =
  ProviderOperationOwnedByCleanupOperation . providerDispatchKeyOperationId

-- | Sprint 4.85: does every teardown dispatch purpose name its cleanup
-- operation?
--
-- @ProviderOperationCleanupRunOwnershipUnavailable@ is derived from this. It is
-- a measurement rather than a constant because the projection above is total
-- over the closed purpose enumeration: a purpose that stopped carrying its
-- operation id would fail here, and the blocker would be re-established.
teardownProviderDispatchOwnershipIsTotal :: Bool
teardownProviderDispatchOwnershipIsTotal =
  case mkCleanupOperationId "operational-credential-disposition-witness" of
    Left _ -> False
    Right operationId ->
      all (ownedForPurpose operationId) [minBound .. maxBound]
 where
  ownedForPurpose operationId purpose =
    case mkProviderDispatchKey operationId purpose of
      Left _ -> False
      Right dispatchKey ->
        providerDispatchKeyCleanupOwner dispatchKey
          == ProviderOperationOwnedByCleanupOperation operationId

classifyProviderCallerResult
  :: Either ProviderCallerError Text -> TeardownProviderBoundaryResult
classifyProviderCallerResult result = case result of
  Right evidence -> TeardownProviderCompleted evidence
  Left err -> case err of
    ProviderCallerSubmissionKeyInvalid _ ->
      TeardownProviderRefused (rendered err)
    ProviderCallerAuthenticationFailed _ ->
      TeardownProviderUnavailable (rendered err)
    ProviderCallerDispatchFailed dispatchError ->
      case dispatchError of
        AuthorityProviderRemoteRefused status detail
          | status >= 500 -> TeardownProviderUnavailable detail
          | otherwise -> TeardownProviderRefused detail
        AuthorityProviderTransportFailed _ ->
          TeardownProviderUnavailable (rendered err)
        AuthorityProviderResponseInvalid _ ->
          TeardownProviderUnavailable (rendered err)
        AuthorityProviderResponseStatusMismatch _ ->
          TeardownProviderUnavailable (rendered err)
 where
  rendered = Text.pack . renderProviderCallerError

-- | Read-only evidence is reconstructed only for the exact intent and
-- coordinate supplied to the Authority.  Transport inability remains
-- unobservable data for the exact adapter; it is never an empty inventory.
dispatchRegisteredProviderObservation
  :: (Monad m)
  => TeardownProviderBoundary m
  -> ProviderDispatchKey
  -> ProviderIntent
  -> m (Either ProviderDispatchError ProviderIntentExecutionResult)
dispatchRegisteredProviderObservation boundary dispatchKey intent =
  case validateObservationIntent (providerDispatchKeyPurpose dispatchKey) intent of
    Left err -> pure (Left err)
    Right () -> do
      dispatched <-
        runTeardownProviderBoundary boundary dispatchKey intent
      pure $ case dispatched of
        TeardownProviderUnavailable detail ->
          Left (ProviderDispatchObservationUnobservable detail)
        TeardownProviderRefused detail ->
          Left (ProviderDispatchObservationRefused detail)
        TeardownProviderCompleted evidence ->
          Right
            ( ProviderIntentExecutionObserved
                (providerIntentCoordinate intent)
                evidence
            )

-- | A transport failure after mutation submission is ambiguous.  The caller
-- must run its separately keyed absence read-back; this boundary never turns
-- such a failure into a definite refusal or success.
dispatchRegisteredProviderMutation
  :: (Monad m)
  => TeardownProviderBoundary m
  -> ProviderDispatchKey
  -> ProviderIntent
  -> m (Either ProviderDispatchError RegisteredTargetMutationAttempt)
dispatchRegisteredProviderMutation boundary dispatchKey intent =
  case validateMutationIntent (providerDispatchKeyPurpose dispatchKey) intent of
    Left err -> pure (Left err)
    Right () -> do
      dispatched <-
        runTeardownProviderBoundary boundary dispatchKey intent
      pure $ case dispatched of
        TeardownProviderUnavailable detail ->
          Right (RegisteredTargetMutationResponseLost detail)
        TeardownProviderRefused detail ->
          Right (RegisteredTargetMutationRefused detail)
        TeardownProviderCompleted _ -> Right RegisteredTargetMutationApplied

validateObservationIntent
  :: ProviderDispatchPurpose
  -> ProviderIntent
  -> Either ProviderDispatchError ()
validateObservationIntent purpose intent =
  if allowed
    then Right ()
    else Left (ProviderDispatchIntentPurposeMismatch purpose intent)
 where
  allowed = case (purpose, intent) of
    (ProviderDecisionObservation, ObserveRegisteredStack {}) -> True
    (ProviderDecisionObservation, ObserveTestEbsVolumes {}) -> True
    (ProviderDecisionObservation, ObserveEksClusterIdentity {}) -> True
    (ProviderAbsenceReadBack, ReadBackRegisteredStack {}) -> True
    (ProviderAbsenceReadBack, ObserveTestEbsVolumes {}) -> True
    (ProviderAbsenceReadBack, ObserveEksClusterIdentity {}) -> True
    _ -> False

validateMutationIntent
  :: ProviderDispatchPurpose
  -> ProviderIntent
  -> Either ProviderDispatchError ()
validateMutationIntent purpose intent =
  if allowed
    then Right ()
    else Left (ProviderDispatchIntentPurposeMismatch purpose intent)
 where
  allowed = case (purpose, intent) of
    (ProviderRegisteredMutation, DestroyRegisteredStack {}) -> True
    (ProviderRegisteredMutation, ReapTestEbsVolumes {}) -> True
    _ -> False
