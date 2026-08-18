{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Exact registered-target interpreter for the AWS resources selected by a
-- compiled teardown program.  Every Provider call uses a deterministic
-- lifecycle-operation subkey through the local Lifecycle Authority.  Runtime
-- provider output cannot choose a registry key, lifecycle class, or cleanup
-- surface, and mutation responses never stand in for the mandatory absence
-- read-back.
module Prodbox.Lifecycle.Teardown.AwsRegisteredTargetInterpreter
  ( AwsStackDecisionInputs
  , awsStackDecisionInputsOperationId
  , awsStackDecisionInputsKey
  , awsStackDecisionInputsScope
  , awsStackDecisionInputsCheckpointPair
  , awsStackDecisionInputsManifest
  , mkAwsStackDecisionInputs
  , AwsStackProviderBinding
  , awsStackProviderBindingOperationId
  , awsStackProviderBindingKey
  , awsStackProviderBindingScope
  , awsStackProviderBindingRevision
  , awsStackProviderBindingConfig
  , mkAwsStackProviderBinding
  , AwsEksPresentDestroyBoundary
  , mkAwsEksPresentDestroyBoundary
  , AwsRegisteredTargetInterpreter (..)
  , observeVerifiedAwsEksForDecision
  , observeAwsRegisteredTarget
  , reconcileAwsRegisteredTargetAbsent
  , readBackAwsRegisteredTargetAbsent
  , AwsRegisteredTargetInterpreterError (..)
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.CleanupRun (CleanupOperationId)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderRefError
  , ProviderRevision
  , ProviderStackConfig
  , ProviderStackConfigError
  , ProviderStackRef
  , mkProviderStackRef
  , validateProviderStackConfig
  )
import Prodbox.Lifecycle.Teardown.AwsEbsAdapter
import Prodbox.Lifecycle.Teardown.AwsEksAdapter
import Prodbox.Lifecycle.Teardown.AwsStackAdapter
import Prodbox.Lifecycle.Teardown.Decision
import Prodbox.Lifecycle.Teardown.Execution
  ( TeardownExecutionContext
  , teardownExecutionObservationScope
  , teardownExecutionOperationId
  )
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.OwnershipManifest
import Prodbox.Lifecycle.Teardown.Program
import Prodbox.Lifecycle.Teardown.ProviderDispatch
import Prodbox.Lifecycle.Teardown.RegisteredTargetExecutor
import Prodbox.Lifecycle.Teardown.RegisteredTargetResult
import Prodbox.Lifecycle.Teardown.Registry

-- | Opaque, durable-reader-produced inputs for the total stack decision.  The
-- smart constructor rechecks key and scope before an effect interpreter can
-- consume checkpoint or ownership authority.
data AwsStackDecisionInputs = AwsStackDecisionInputs
  { internalAwsStackDecisionInputsOperationId :: !CleanupOperationId
  , internalAwsStackDecisionInputsKey :: !RegisteredResourceKey
  , internalAwsStackDecisionInputsScope :: !ObservationEvidenceScope
  , internalAwsStackDecisionInputsCheckpointPair :: !CheckpointPairObservation
  , internalAwsStackDecisionInputsManifest :: !OwnershipManifestDecisionEvidence
  }

awsStackDecisionInputsOperationId
  :: AwsStackDecisionInputs -> CleanupOperationId
awsStackDecisionInputsOperationId = internalAwsStackDecisionInputsOperationId

awsStackDecisionInputsKey
  :: AwsStackDecisionInputs -> RegisteredResourceKey
awsStackDecisionInputsKey = internalAwsStackDecisionInputsKey

awsStackDecisionInputsScope
  :: AwsStackDecisionInputs -> ObservationEvidenceScope
awsStackDecisionInputsScope = internalAwsStackDecisionInputsScope

awsStackDecisionInputsCheckpointPair
  :: AwsStackDecisionInputs -> CheckpointPairObservation
awsStackDecisionInputsCheckpointPair =
  internalAwsStackDecisionInputsCheckpointPair

awsStackDecisionInputsManifest
  :: AwsStackDecisionInputs -> OwnershipManifestDecisionEvidence
awsStackDecisionInputsManifest = internalAwsStackDecisionInputsManifest

mkAwsStackDecisionInputs
  :: CleanupOperationId
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> CheckpointPairObservation
  -> OwnershipManifestDecisionEvidence
  -> Either AwsRegisteredTargetInterpreterError AwsStackDecisionInputs
mkAwsStackDecisionInputs operationId key scope checkpoints manifest = do
  identity <- requireStackIdentity key
  if registeredIdentityKind identity == Stack
    then Right ()
    else
      Left
        ( AwsRegisteredTargetKindUnsupported
            key
            (registeredIdentityKind identity)
        )
  if checkpointPairStackKey checkpoints == key
    then Right ()
    else
      Left
        ( AwsRegisteredTargetCheckpointKeyMismatch
            key
            (checkpointPairStackKey checkpoints)
        )
  if checkpointPairEvidenceScope checkpoints == scope
    then Right ()
    else
      Left
        ( AwsRegisteredTargetCheckpointScopeMismatch
            scope
            (checkpointPairEvidenceScope checkpoints)
        )
  if ownershipManifestDecisionStackKey manifest == key
    then Right ()
    else
      Left
        ( AwsRegisteredTargetManifestKeyMismatch
            key
            (ownershipManifestDecisionStackKey manifest)
        )
  if ownershipManifestDecisionScope manifest == scope
    then Right ()
    else
      Left
        ( AwsRegisteredTargetManifestScopeMismatch
            scope
            (ownershipManifestDecisionScope manifest)
        )
  Right
    AwsStackDecisionInputs
      { internalAwsStackDecisionInputsOperationId = operationId
      , internalAwsStackDecisionInputsKey = key
      , internalAwsStackDecisionInputsScope = scope
      , internalAwsStackDecisionInputsCheckpointPair = checkpoints
      , internalAwsStackDecisionInputsManifest = manifest
      }

-- | Exact Provider generation/configuration admitted for one registered stack
-- operation.  It contains no credential material.  Configuration is checked
-- against the repository-owned stack reference before it can be returned by a
-- production durable reader.
data AwsStackProviderBinding = AwsStackProviderBinding
  { internalAwsStackProviderBindingOperationId :: !CleanupOperationId
  , internalAwsStackProviderBindingKey :: !RegisteredResourceKey
  , internalAwsStackProviderBindingScope :: !ObservationEvidenceScope
  , internalAwsStackProviderBindingRevision :: !ProviderRevision
  , internalAwsStackProviderBindingConfig :: !ProviderStackConfig
  }
  deriving (Eq, Show)

awsStackProviderBindingOperationId
  :: AwsStackProviderBinding -> CleanupOperationId
awsStackProviderBindingOperationId = internalAwsStackProviderBindingOperationId

awsStackProviderBindingKey
  :: AwsStackProviderBinding -> RegisteredResourceKey
awsStackProviderBindingKey = internalAwsStackProviderBindingKey

awsStackProviderBindingScope
  :: AwsStackProviderBinding -> ObservationEvidenceScope
awsStackProviderBindingScope = internalAwsStackProviderBindingScope

awsStackProviderBindingRevision
  :: AwsStackProviderBinding -> ProviderRevision
awsStackProviderBindingRevision = internalAwsStackProviderBindingRevision

awsStackProviderBindingConfig
  :: AwsStackProviderBinding -> ProviderStackConfig
awsStackProviderBindingConfig = internalAwsStackProviderBindingConfig

mkAwsStackProviderBinding
  :: CleanupOperationId
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> ProviderRevision
  -> ProviderStackConfig
  -> Either AwsRegisteredTargetInterpreterError AwsStackProviderBinding
mkAwsStackProviderBinding operationId key scope revision config = do
  ref <- providerStackRefForKey key
  case validateProviderStackConfig ref config of
    Left err -> Left (AwsRegisteredTargetProviderConfigInvalid key err)
    Right () -> Right ()
  Right
    AwsStackProviderBinding
      { internalAwsStackProviderBindingOperationId = operationId
      , internalAwsStackProviderBindingKey = key
      , internalAwsStackProviderBindingScope = scope
      , internalAwsStackProviderBindingRevision = revision
      , internalAwsStackProviderBindingConfig = config
      }

-- | Typed effect boundary.  The two readers must obtain their opaque values
-- from durable, exact read-back; they are not action callbacks embedded in the
-- cleanup graph.  Any diagnostic text supplied here must be bounded and
-- secret-free.
newtype AwsEksPresentDestroyBoundary m = AwsEksPresentDestroyBoundary
  { internalReconcilePresentAwsEks
      :: forall surface
       . TeardownExecutionContext surface
      -> RegisteredTargetBinding
      -> VerifiedAwsEksObservation 'ObserveEksForDecision
      -> m
           ( Either
               AwsRegisteredTargetInterpreterError
               RegisteredTargetReconcileResult
           )
  }

-- | Install the production EKS-present destroy continuation.  The callback
-- cannot manufacture mutation authority: its successful value remains the
-- opaque registered-target result minted from a closed EKS destroy
-- authorization.  Keeping the continuation separate also avoids a module
-- cycle between the generic registered-target interpreter and the EKS
-- teardown composition.
mkAwsEksPresentDestroyBoundary
  :: ( forall surface
        . TeardownExecutionContext surface
       -> RegisteredTargetBinding
       -> VerifiedAwsEksObservation 'ObserveEksForDecision
       -> m
            ( Either
                AwsRegisteredTargetInterpreterError
                RegisteredTargetReconcileResult
            )
     )
  -> AwsEksPresentDestroyBoundary m
mkAwsEksPresentDestroyBoundary = AwsEksPresentDestroyBoundary

data AwsRegisteredTargetInterpreter m = AwsRegisteredTargetInterpreter
  { awsRegisteredTargetProviderBoundary :: !(TeardownProviderBoundary m)
  , awsRegisteredTargetReadStackDecisionInputs
      :: CleanupOperationId
      -> RegisteredResourceKey
      -> ObservationEvidenceScope
      -> m (Either Text AwsStackDecisionInputs)
  , awsRegisteredTargetReadStackProviderBinding
      :: CleanupOperationId
      -> RegisteredResourceKey
      -> ObservationEvidenceScope
      -> m (Either Text AwsStackProviderBinding)
  , awsRegisteredTargetPresentEksDestroyBoundary
      :: !(AwsEksPresentDestroyBoundary m)
  }

data AwsRegisteredTargetInterpreterError
  = AwsRegisteredTargetBindingMissing !RegisteredResourceKey
  | AwsRegisteredTargetBindingKeyMismatch
      !RegisteredResourceKey
      !RegisteredResourceKey
  | AwsRegisteredTargetBindingKindMismatch
      !RegisteredResourceKey
      !ResourceKind
      !ResourceKind
  | AwsRegisteredTargetBindingCoordinateMismatch
      !RegisteredResourceKey
      !ManagedResourceCoordinateDigest
      !ManagedResourceCoordinateDigest
  | AwsRegisteredTargetKindUnsupported !RegisteredResourceKey !ResourceKind
  | -- | The key is registered but is not an AWS registered target at all.
    -- The local foundation is projected as a separately typed local target and
    -- has no business reaching this interpreter.
    AwsRegisteredTargetNotAnAwsTarget !RegisteredResourceKey
  | -- | The key is a registered AWS target with no production executor. The
    -- gap names the missing adapter rather than the resource kind, because the
    -- kind is not what is missing.
    AwsRegisteredTargetAdapterUnbuilt
      !RegisteredResourceKey
      !RegisteredTargetAdapterGap
  | AwsRegisteredTargetProviderRefInvalid
      !RegisteredResourceKey
      !ProviderRefError
  | AwsRegisteredTargetProviderConfigInvalid
      !RegisteredResourceKey
      !ProviderStackConfigError
  | AwsRegisteredTargetDispatchKeyInvalid !ProviderDispatchError
  | AwsRegisteredTargetDispatchInvalid !ProviderDispatchError
  | AwsRegisteredTargetStackBindingInvalid !AwsStackBindingError
  | AwsRegisteredTargetStackDestroyRefused !AwsStackDestroyRefusal
  | AwsRegisteredTargetEbsInvalid !AwsEbsAdapterError
  | AwsRegisteredTargetEksInvalid !AwsEksAdapterError
  | AwsRegisteredTargetEksKeyMismatch !RegisteredResourceKey
  | AwsRegisteredTargetObservationSetInvalid !CompleteObservationSetError
  | AwsRegisteredTargetDecisionBindingInvalid !StackDecisionBindingError
  | AwsRegisteredTargetDecisionRefused
      !RegisteredResourceKey
      !(NonEmpty StackDecisionRefusal)
  | AwsRegisteredTargetDecisionContradictedObservation !RegisteredResourceKey
  | AwsRegisteredTargetCheckpointRecoveryRequired !RegisteredResourceKey
  | AwsRegisteredTargetEksDrainProofRequired
  | AwsRegisteredTargetEksDestroyBoundaryInvalid
  | AwsRegisteredTargetDecisionInputsUnavailable !Text
  | AwsRegisteredTargetDecisionInputsBindingMismatch
  | AwsRegisteredTargetProviderBindingUnavailable !Text
  | AwsRegisteredTargetProviderBindingMismatch
  | AwsRegisteredTargetCheckpointKeyMismatch
      !RegisteredResourceKey
      !RegisteredResourceKey
  | AwsRegisteredTargetCheckpointScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | AwsRegisteredTargetManifestKeyMismatch
      !RegisteredResourceKey
      !RegisteredResourceKey
  | AwsRegisteredTargetManifestScopeMismatch
      !ObservationEvidenceScope
      !ObservationEvidenceScope
  | AwsRegisteredTargetResultInvalid !RegisteredTargetReconcileError
  deriving (Eq, Show)

-- | Execute one exact read-only observation.  Unsupported registry kinds fail
-- structurally; transport/refusal while observing becomes an exact
-- Unobservable result, never absence.
observeAwsRegisteredTarget
  :: (Monad m)
  => AwsRegisteredTargetInterpreter m
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> m (Either AwsRegisteredTargetInterpreterError ExactResourceObservation)
observeAwsRegisteredTarget interpreter context target =
  case validateInvocation context target of
    Left err -> pure (Left err)
    Right identity ->
      case registeredTargetExecutorFor (registeredTargetKey target) of
        Right EksStackExecutor ->
          fmap verifiedAwsEksExactObservation
            <$> observeVerifiedAwsEksForDecision interpreter context target
        Right GenericStackExecutor -> do
          observed <-
            observeStackForDecision
              interpreter
              (teardownExecutionOperationId context)
              (registeredTargetKey target)
              (teardownExecutionObservationScope context)
          pure (stackDecisionObservationExact <$> observed)
        Right PerRunTestEbsFamilyExecutor ->
          observeEbs
            interpreter
            ProviderDecisionObservation
            context
        Left unexecutable ->
          pure
            ( Right
                ( exactResourceObservationFor
                    identity
                    (observationRevision context ProviderDecisionObservation)
                    (teardownExecutionObservationScope context)
                    ( ExactResourceUnobservable
                        ( ObservationFailure
                            ( unexecutableRegisteredTargetDetail
                                (registeredTargetKey target)
                                unexecutable
                            )
                            :| []
                        )
                    )
                )
            )

-- | Re-observe immediately before deciding, then admit mutation only through
-- a closed adapter authorization.  A present EKS stack delegates to the
-- separately composed destroy boundary; that boundary must recover the
-- durable drain/read-back proof instead of hiding it in process memory.
reconcileAwsRegisteredTargetAbsent
  :: (Monad m)
  => AwsRegisteredTargetInterpreter m
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> m (Either AwsRegisteredTargetInterpreterError RegisteredTargetReconcileResult)
reconcileAwsRegisteredTargetAbsent interpreter context target =
  case validateInvocation context target of
    Left err -> pure (Left err)
    Right _ -> case registeredTargetExecutorFor (registeredTargetKey target) of
      Right EksStackExecutor -> reconcileEks interpreter context target
      Right GenericStackExecutor -> reconcileStack interpreter context target
      Right PerRunTestEbsFamilyExecutor ->
        reconcileEbs interpreter context target
      Left unexecutable ->
        pure
          ( refusedResult
              context
              target
              (unexecutableTargetError (registeredTargetKey target) unexecutable)
          )

-- | Independently observe final absence under the read-back node's own stable
-- submission key.  Mutation return text is not an input.
readBackAwsRegisteredTargetAbsent
  :: (Monad m)
  => AwsRegisteredTargetInterpreter m
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> m (Either AwsRegisteredTargetInterpreterError ExactResourceObservation)
readBackAwsRegisteredTargetAbsent interpreter context target =
  case validateInvocation context target of
    Left err -> pure (Left err)
    Right _ -> case registeredTargetExecutorFor (registeredTargetKey target) of
      Right EksStackExecutor -> observeEksDesiredAbsence interpreter context
      Right GenericStackExecutor ->
        readBackStackDesiredAbsence
          interpreter
          (teardownExecutionOperationId context)
          (registeredTargetKey target)
          (teardownExecutionObservationScope context)
      Right PerRunTestEbsFamilyExecutor ->
        observeEbs
          interpreter
          ProviderAbsenceReadBack
          context
      Left unexecutable ->
        pure
          ( Left
              (unexecutableTargetError (registeredTargetKey target) unexecutable)
          )

data StackDecisionObservation
  = StackDecisionObservationVerified
      !(VerifiedAwsStackObservation 'ObserveStackForDecision)
  | StackDecisionObservationUnverified !ExactResourceObservation

stackDecisionObservationExact
  :: StackDecisionObservation -> ExactResourceObservation
stackDecisionObservationExact observation = case observation of
  StackDecisionObservationVerified verified ->
    verifiedAwsStackExactObservation verified
  StackDecisionObservationUnverified exact -> exact

observeStackForDecision
  :: (Monad m)
  => AwsRegisteredTargetInterpreter m
  -> CleanupOperationId
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> m (Either AwsRegisteredTargetInterpreterError StackDecisionObservation)
observeStackForDecision interpreter operationId key scope =
  case mkProviderDispatchKey operationId ProviderDecisionObservation of
    Left err -> pure (Left (AwsRegisteredTargetDispatchKeyInvalid err))
    Right dispatchKey ->
      case mkAwsStackObserveRequest
        key
        scope
        (observationRevisionForProviderDispatchKey dispatchKey) of
        Left err -> pure (Left (AwsRegisteredTargetStackBindingInvalid err))
        Right request -> do
          dispatched <-
            dispatchRegisteredProviderObservation
              (awsRegisteredTargetProviderBoundary interpreter)
              dispatchKey
              (awsStackObservationRequestIntent request)
          pure $ case dispatched of
            Left err@ProviderDispatchObservationUnobservable {} ->
              StackDecisionObservationUnverified
                <$> stackRequestFailureObservation request err
            Left err@ProviderDispatchObservationRefused {} ->
              StackDecisionObservationUnverified
                <$> stackRequestFailureObservation request err
            Left err -> Left (AwsRegisteredTargetDispatchInvalid err)
            Right result -> case decodeAwsStackExecutionResult request result of
              AwsStackObservationDecoded verified ->
                Right (StackDecisionObservationVerified verified)
              AwsStackObservationRejected _ exact ->
                Right (StackDecisionObservationUnverified exact)

readBackStackDesiredAbsence
  :: (Monad m)
  => AwsRegisteredTargetInterpreter m
  -> CleanupOperationId
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> m (Either AwsRegisteredTargetInterpreterError ExactResourceObservation)
readBackStackDesiredAbsence interpreter operationId key scope =
  case mkProviderDispatchKey operationId ProviderAbsenceReadBack of
    Left err -> pure (Left (AwsRegisteredTargetDispatchKeyInvalid err))
    Right dispatchKey ->
      case mkAwsStackDesiredAbsenceReadBackRequest
        key
        scope
        (observationRevisionForProviderDispatchKey dispatchKey) of
        Left err -> pure (Left (AwsRegisteredTargetStackBindingInvalid err))
        Right request -> do
          dispatched <-
            dispatchRegisteredProviderObservation
              (awsRegisteredTargetProviderBoundary interpreter)
              dispatchKey
              (awsStackObservationRequestIntent request)
          pure $ case dispatched of
            Left err@ProviderDispatchObservationUnobservable {} ->
              stackRequestFailureObservation request err
            Left err@ProviderDispatchObservationRefused {} ->
              stackRequestFailureObservation request err
            Left err -> Left (AwsRegisteredTargetDispatchInvalid err)
            Right result ->
              Right
                ( awsStackObservationDecodeObservation
                    (decodeAwsStackExecutionResult request result)
                )

observeEbs
  :: (Monad m)
  => AwsRegisteredTargetInterpreter m
  -> ProviderDispatchPurpose
  -> TeardownExecutionContext surface
  -> m (Either AwsRegisteredTargetInterpreterError ExactResourceObservation)
observeEbs interpreter purpose context =
  case mkProviderDispatchKey operationId purpose of
    Left err -> pure (Left (AwsRegisteredTargetDispatchKeyInvalid err))
    Right dispatchKey ->
      case mkEbsObservationRequest
        (observationRevisionForProviderDispatchKey dispatchKey)
        scope of
        Left err -> pure (Left (AwsRegisteredTargetEbsInvalid err))
        Right request -> do
          dispatched <-
            dispatchRegisteredProviderObservation
              (awsRegisteredTargetProviderBoundary interpreter)
              dispatchKey
              (awsEbsObservationRequestProviderIntent request)
          pure $ case dispatched of
            Left (ProviderDispatchObservationUnobservable detail) ->
              mapEbs (decodeExactAwsEbsObservation request (Left detail))
            Left (ProviderDispatchObservationRefused detail) ->
              mapEbs (decodeExactAwsEbsObservation request (Left detail))
            Left err -> Left (AwsRegisteredTargetDispatchInvalid err)
            Right result ->
              mapEbs (decodeExactAwsEbsObservation request (Right result))
 where
  operationId = teardownExecutionOperationId context
  scope = teardownExecutionObservationScope context

-- | Obtain the opaque, exact Provider-decoded EKS observation used by drain
-- admission.  The registered target is validated before dispatch, and only a
-- successful exact decoder result can cross this boundary.  Provider
-- unavailability/refusal and malformed or mismatched evidence remain typed
-- failures; none can be flattened into absence.
observeVerifiedAwsEksForDecision
  :: (Monad m)
  => AwsRegisteredTargetInterpreter m
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> m
       ( Either
           AwsRegisteredTargetInterpreterError
           (VerifiedAwsEksObservation 'ObserveEksForDecision)
       )
observeVerifiedAwsEksForDecision interpreter context target =
  case validateInvocation context target of
    Left err -> pure (Left err)
    Right _
      | registeredTargetKey target /= AwsEksKey ->
          pure (Left (AwsRegisteredTargetEksKeyMismatch (registeredTargetKey target)))
      | otherwise ->
          case mkProviderDispatchKey operationId ProviderDecisionObservation of
            Left err -> pure (Left (AwsRegisteredTargetDispatchKeyInvalid err))
            Right dispatchKey ->
              case mkAwsEksDecisionObservationRequest
                (observationRevisionForProviderDispatchKey dispatchKey)
                scope of
                Left err -> pure (Left (AwsRegisteredTargetEksInvalid err))
                Right request -> do
                  dispatched <-
                    dispatchRegisteredProviderObservation
                      (awsRegisteredTargetProviderBoundary interpreter)
                      dispatchKey
                      (awsEksObservationRequestProviderIntent request)
                  pure $ case dispatched of
                    Left err -> Left (AwsRegisteredTargetDispatchInvalid err)
                    Right result -> case decodeAwsEksObservation request (Right result) of
                      AwsEksObservationDecoded verified -> Right verified
                      AwsEksObservationRejected err _ ->
                        Left (AwsRegisteredTargetEksInvalid err)
 where
  operationId = teardownExecutionOperationId context
  scope = teardownExecutionObservationScope context

observeEksDesiredAbsence
  :: (Monad m)
  => AwsRegisteredTargetInterpreter m
  -> TeardownExecutionContext surface
  -> m (Either AwsRegisteredTargetInterpreterError ExactResourceObservation)
observeEksDesiredAbsence interpreter context =
  case mkProviderDispatchKey operationId ProviderAbsenceReadBack of
    Left err -> pure (Left (AwsRegisteredTargetDispatchKeyInvalid err))
    Right dispatchKey ->
      case mkAwsEksDesiredAbsenceReadBackRequest
        (observationRevisionForProviderDispatchKey dispatchKey)
        scope of
        Left err -> pure (Left (AwsRegisteredTargetEksInvalid err))
        Right request -> do
          dispatched <-
            dispatchRegisteredProviderObservation
              (awsRegisteredTargetProviderBoundary interpreter)
              dispatchKey
              (awsEksObservationRequestProviderIntent request)
          pure $ case dispatched of
            Left (ProviderDispatchObservationUnobservable detail) ->
              Right
                ( awsEksObservationDecodeObservation
                    (decodeAwsEksObservation request (Left detail))
                )
            Left (ProviderDispatchObservationRefused detail) ->
              Right
                ( awsEksObservationDecodeObservation
                    (decodeAwsEksObservation request (Left detail))
                )
            Left err -> Left (AwsRegisteredTargetDispatchInvalid err)
            Right result ->
              Right
                ( awsEksObservationDecodeObservation
                    (decodeAwsEksObservation request (Right result))
                )
 where
  operationId = teardownExecutionOperationId context
  scope = teardownExecutionObservationScope context

reconcileEks
  :: (Monad m)
  => AwsRegisteredTargetInterpreter m
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> m (Either AwsRegisteredTargetInterpreterError RegisteredTargetReconcileResult)
reconcileEks interpreter context target = do
  observed <- observeVerifiedAwsEksForDecision interpreter context target
  case observed of
    Left err -> pure (refusedResult context target err)
    Right verified -> case exactObservationResult (verifiedAwsEksExactObservation verified) of
      ExactResourceAbsent _ ->
        pure
          ( mapResult
              ( mkAlreadyAbsentRegisteredTargetReconcile
                  operationId
                  target
                  scope
                  (verifiedAwsEksExactObservation verified)
              )
          )
      ExactResourcePresent _ -> do
        reconciled <-
          internalReconcilePresentAwsEks
            (awsRegisteredTargetPresentEksDestroyBoundary interpreter)
            context
            target
            verified
        pure $ case reconciled of
          Left err -> refusedResult context target err
          Right result
            | presentEksResultMatches result -> Right result
            | otherwise ->
                refusedResult
                  context
                  target
                  AwsRegisteredTargetEksDestroyBoundaryInvalid
      ExactResourcePartial {} ->
        pure
          ( refusedResult
              context
              target
              ( AwsRegisteredTargetDecisionInputsUnavailable
                  "exact EKS identity observation was partial"
              )
          )
      ExactResourceUnobservable {} ->
        pure
          ( refusedResult
              context
              target
              ( AwsRegisteredTargetDecisionInputsUnavailable
                  "exact EKS identity observation was unobservable"
              )
          )
 where
  operationId = teardownExecutionOperationId context
  scope = teardownExecutionObservationScope context
  presentEksResultMatches result =
    registeredTargetReconcileKey result == registeredTargetKey target
      && registeredTargetReconcileCoordinateDigest result
        == registeredTargetCoordinateDigest target
      && registeredTargetReconcileScope result == scope
      && registeredTargetReconcileOperationId result == operationId
      && case registeredTargetReconcileDisposition result of
        RegisteredTargetAwsEksMutation _ -> True
        _ -> False

reconcileStack
  :: (Monad m)
  => AwsRegisteredTargetInterpreter m
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> m (Either AwsRegisteredTargetInterpreterError RegisteredTargetReconcileResult)
reconcileStack interpreter context target = do
  observed <- observeStackForDecision interpreter operationId key scope
  case observed of
    Left err -> pure (refusedResult context target err)
    Right stackObservation ->
      let exact = stackDecisionObservationExact stackObservation
          observationRefusal =
            AwsRegisteredTargetDecisionInputsUnavailable
              "exact registered stack observation did not authorize a decision"
       in case exactObservationResult exact of
            ExactResourceAbsent _ ->
              pure
                ( mapResult
                    (mkAlreadyAbsentRegisteredTargetReconcile operationId target scope exact)
                )
            ExactResourcePartial {} -> pure (refusedResult context target observationRefusal)
            ExactResourceUnobservable {} ->
              pure (refusedResult context target observationRefusal)
            ExactResourcePresent _ -> case stackObservation of
              StackDecisionObservationUnverified _ ->
                pure (refusedResult context target observationRefusal)
              StackDecisionObservationVerified verified ->
                reconcilePresentStack interpreter context target verified
 where
  operationId = teardownExecutionOperationId context
  scope = teardownExecutionObservationScope context
  key = registeredTargetKey target

reconcilePresentStack
  :: (Monad m)
  => AwsRegisteredTargetInterpreter m
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> VerifiedAwsStackObservation 'ObserveStackForDecision
  -> m (Either AwsRegisteredTargetInterpreterError RegisteredTargetReconcileResult)
reconcilePresentStack interpreter context target verified = do
  loadedInputs <-
    awsRegisteredTargetReadStackDecisionInputs interpreter operationId key scope
  case loadedInputs of
    Left detail -> pure (refused (AwsRegisteredTargetDecisionInputsUnavailable detail))
    Right inputs
      | awsStackDecisionInputsOperationId inputs /= operationId
          || awsStackDecisionInputsKey inputs /= key
          || awsStackDecisionInputsScope inputs /= scope ->
          pure (refused AwsRegisteredTargetDecisionInputsBindingMismatch)
      | otherwise ->
          case mkCompleteObservationSet scope [key] [exact] of
            Left err ->
              pure (refused (AwsRegisteredTargetObservationSetInvalid err))
            Right complete ->
              case decideStackDesiredAbsence
                key
                complete
                (internalAwsStackDecisionInputsCheckpointPair inputs)
                (internalAwsStackDecisionInputsManifest inputs) of
                Left err ->
                  pure (refused (AwsRegisteredTargetDecisionBindingInvalid err))
                Right decision -> applyDecision decision
 where
  operationId = teardownExecutionOperationId context
  scope = teardownExecutionObservationScope context
  key = registeredTargetKey target
  exact = verifiedAwsStackExactObservation verified
  refused = refusedResult context target

  applyDecision decision = case decision of
    StackAlreadyAbsent {} ->
      pure (refused (AwsRegisteredTargetDecisionContradictedObservation key))
    StackRestoreBackupThenDestroy {} ->
      pure (refused (AwsRegisteredTargetCheckpointRecoveryRequired key))
    StackDesiredAbsenceRefused _ refusals ->
      pure (refused (AwsRegisteredTargetDecisionRefused key refusals))
    StackDestroyFromVerifiedPrimary {}
      | key == AwsEksKey ->
          pure (refused AwsRegisteredTargetEksDrainProofRequired)
    StackDestroyFromVerifiedManifest {}
      | key == AwsEksKey ->
          pure (refused AwsRegisteredTargetEksDrainProofRequired)
    _ -> destroyWithDecision decision

  destroyWithDecision decision =
    do
      loadedBinding <-
        awsRegisteredTargetReadStackProviderBinding interpreter operationId key scope
      case loadedBinding of
        Left detail ->
          pure (refused (AwsRegisteredTargetProviderBindingUnavailable detail))
        Right binding
          | awsStackProviderBindingOperationId binding /= operationId
              || awsStackProviderBindingKey binding /= key
              || awsStackProviderBindingScope binding /= scope ->
              pure (refused AwsRegisteredTargetProviderBindingMismatch)
          | otherwise ->
              applyBoundDestroy decision binding

  applyBoundDestroy decision binding =
    case authorizeAwsStackDestroy
      (internalAwsStackProviderBindingRevision binding)
      verified
      decision of
      Left err -> pure (refused (AwsRegisteredTargetStackDestroyRefused err))
      Right authorization ->
        case mkAwsStackDestroyRequest
          authorization
          (internalAwsStackProviderBindingRevision binding)
          (internalAwsStackProviderBindingConfig binding) of
          Left err -> pure (refused (AwsRegisteredTargetStackDestroyRefused err))
          Right request ->
            case mkProviderDispatchKey operationId ProviderRegisteredMutation of
              Left err ->
                pure (refused (AwsRegisteredTargetDispatchKeyInvalid err))
              Right dispatchKey -> do
                attempted <-
                  dispatchRegisteredProviderMutation
                    (awsRegisteredTargetProviderBoundary interpreter)
                    dispatchKey
                    (awsStackDestroyRequestIntent request)
                pure $ case attempted of
                  Left err -> refused (AwsRegisteredTargetDispatchInvalid err)
                  Right mutation ->
                    mapResult
                      ( mkAwsStackRegisteredTargetReconcile
                          operationId
                          target
                          scope
                          authorization
                          mutation
                      )

reconcileEbs
  :: (Monad m)
  => AwsRegisteredTargetInterpreter m
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> m (Either AwsRegisteredTargetInterpreterError RegisteredTargetReconcileResult)
reconcileEbs interpreter context target = do
  exactResult <-
    observeEbs
      interpreter
      ProviderDecisionObservation
      context
  case exactResult of
    Left err -> pure (refusedResult context target err)
    Right exact ->
      case mkProviderDispatchKey operationId ProviderDecisionObservation of
        Left err ->
          pure
            ( refusedResult
                context
                target
                (AwsRegisteredTargetDispatchKeyInvalid err)
            )
        Right dispatchKey ->
          case mkEbsObservationRequest
            (observationRevisionForProviderDispatchKey dispatchKey)
            scope of
            Left err ->
              pure
                ( refusedResult
                    context
                    target
                    (AwsRegisteredTargetEbsInvalid err)
                )
            Right request ->
              case authorizeExactAwsEbsReap request exact of
                Left err ->
                  pure
                    ( refusedResult
                        context
                        target
                        (AwsRegisteredTargetEbsInvalid err)
                    )
                Right Nothing ->
                  pure
                    ( mapResult
                        ( mkAlreadyAbsentRegisteredTargetReconcile
                            operationId
                            target
                            scope
                            exact
                        )
                    )
                Right (Just authorization) ->
                  applyEbsReap authorization
 where
  operationId = teardownExecutionOperationId context
  scope = teardownExecutionObservationScope context

  applyEbsReap authorization =
    case mkProviderDispatchKey operationId ProviderRegisteredMutation of
      Left err ->
        pure
          ( refusedResult
              context
              target
              (AwsRegisteredTargetDispatchKeyInvalid err)
          )
      Right dispatchKey -> do
        attempted <-
          dispatchRegisteredProviderMutation
            (awsRegisteredTargetProviderBoundary interpreter)
            dispatchKey
            (awsEbsReapProviderIntent authorization)
        pure $ case attempted of
          Left err ->
            refusedResult context target (AwsRegisteredTargetDispatchInvalid err)
          Right mutation ->
            mapResult
              ( mkAwsEbsRegisteredTargetReconcile
                  operationId
                  target
                  scope
                  authorization
                  mutation
              )

-- | Carry the executor gap into this interpreter's own error algebra.  The two
-- arms stay distinct: a key that should never reach this interpreter and a key
-- whose adapter is unbuilt are different defects with different owners.
unexecutableTargetError
  :: RegisteredResourceKey
  -> UnexecutableRegisteredTarget
  -> AwsRegisteredTargetInterpreterError
unexecutableTargetError key unexecutable = case unexecutable of
  NotAnAwsRegisteredTarget -> AwsRegisteredTargetNotAnAwsTarget key
  NoProductionExecutor gap -> AwsRegisteredTargetAdapterUnbuilt key gap

validateInvocation
  :: TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> Either AwsRegisteredTargetInterpreterError RegisteredIdentity
validateInvocation _context target = do
  let key = registeredTargetKey target
  identity <-
    maybe
      (Left (AwsRegisteredTargetBindingMissing key))
      Right
      (lookupRegisteredIdentity key)
  if registeredIdentityKey identity == key
    then Right ()
    else
      Left
        ( AwsRegisteredTargetBindingKeyMismatch
            key
            (registeredIdentityKey identity)
        )
  if registeredIdentityKind identity == registeredTargetKind target
    then Right ()
    else
      Left
        ( AwsRegisteredTargetBindingKindMismatch
            key
            (registeredIdentityKind identity)
            (registeredTargetKind target)
        )
  if registeredIdentityCoordinateDigest identity
    == registeredTargetCoordinateDigest target
    then Right identity
    else
      Left
        ( AwsRegisteredTargetBindingCoordinateMismatch
            key
            (registeredIdentityCoordinateDigest identity)
            (registeredTargetCoordinateDigest target)
        )

mkEbsObservationRequest
  :: ObservationRevision
  -> ObservationEvidenceScope
  -> Either AwsEbsAdapterError ExactAwsEbsObservationRequest
mkEbsObservationRequest revision scope =
  case evidenceCleanupSurface scope of
    LocalOnly ->
      mkExactAwsEbsObservationRequest LocalOnlySurface revision scope
    Cascade ->
      mkExactAwsEbsObservationRequest CascadeSurface revision scope
    ExplicitPerRun ->
      mkExactAwsEbsObservationRequest ExplicitPerRunSurface revision scope
    OperationalTeardown ->
      mkExactAwsEbsObservationRequest OperationalTeardownSurface revision scope
    ExplicitLongLived ->
      mkExactAwsEbsObservationRequest ExplicitLongLivedSurface revision scope
    TotalDecommission ->
      mkExactAwsEbsObservationRequest TotalDecommissionSurface revision scope

stackRequestFailureObservation
  :: AwsStackObservationRequest purpose
  -> ProviderDispatchError
  -> Either AwsRegisteredTargetInterpreterError ExactResourceObservation
stackRequestFailureObservation request dispatchError =
  case lookupRegisteredIdentity (awsStackObservationRequestKey request) of
    Just identity ->
      Right
        ( exactResourceObservationFor
            identity
            (awsStackObservationRequestRevision request)
            (awsStackObservationRequestScope request)
            ( ExactResourceUnobservable
                (ObservationFailure (renderDispatchError dispatchError) :| [])
            )
        )
    Nothing ->
      Left
        (AwsRegisteredTargetBindingMissing (awsStackObservationRequestKey request))

renderDispatchError :: ProviderDispatchError -> Text
renderDispatchError = Text.take 512 . Text.pack . show

observationRevision
  :: TeardownExecutionContext surface
  -> ProviderDispatchPurpose
  -> ObservationRevision
observationRevision context purpose =
  case mkProviderDispatchKey (teardownExecutionOperationId context) purpose of
    Right dispatchKey -> observationRevisionForProviderDispatchKey dispatchKey
    Left _ -> ObservationRevision 0

refusedResult
  :: TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> AwsRegisteredTargetInterpreterError
  -> Either AwsRegisteredTargetInterpreterError RegisteredTargetReconcileResult
refusedResult context target err =
  mapResult
    ( mkRefusedRegisteredTargetReconcile
        (teardownExecutionOperationId context)
        target
        (teardownExecutionObservationScope context)
        (Text.take 1024 (Text.pack (show err)))
    )

mapResult
  :: Either RegisteredTargetReconcileError value
  -> Either AwsRegisteredTargetInterpreterError value
mapResult = either (Left . AwsRegisteredTargetResultInvalid) Right

mapEbs
  :: Either AwsEbsAdapterError value
  -> Either AwsRegisteredTargetInterpreterError value
mapEbs = either (Left . AwsRegisteredTargetEbsInvalid) Right

requireStackIdentity
  :: RegisteredResourceKey
  -> Either AwsRegisteredTargetInterpreterError RegisteredIdentity
requireStackIdentity key =
  maybe
    (Left (AwsRegisteredTargetBindingMissing key))
    Right
    (lookupRegisteredIdentity key)

providerStackRefForKey
  :: RegisteredResourceKey
  -> Either AwsRegisteredTargetInterpreterError ProviderStackRef
providerStackRefForKey key = do
  _ <- requireStackIdentity key
  raw <- case key of
    AwsEksKey -> Right "aws-eks"
    AwsEksSubzoneKey -> Right "aws-eks-subzone"
    AwsTestKey -> Right "aws-test"
    _ -> Left (AwsRegisteredTargetKindUnsupported key (registeredKind key))
  either
    (Left . AwsRegisteredTargetProviderRefInvalid key)
    Right
    (mkProviderStackRef raw)
 where
  registeredKind selected =
    maybe Stack registeredIdentityKind (lookupRegisteredIdentity selected)
