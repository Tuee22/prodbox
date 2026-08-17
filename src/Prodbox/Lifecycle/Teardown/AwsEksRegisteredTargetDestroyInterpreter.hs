{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Receipt-gated Provider destruction for a currently present registered EKS
-- stack.  Every durable input is recovered by the exact identity sealed into
-- 'TeardownExecutionContext'; the interpreter retains no process-local proof
-- cache and allocates no retry identity.
module Prodbox.Lifecycle.Teardown.AwsEksRegisteredTargetDestroyInterpreter
  ( AwsEksRegisteredTargetDestroyInterpreter
  , mkAwsEksRegisteredTargetDestroyInterpreter
  , awsEksRegisteredTargetDestroyBoundary
  , reconcilePresentAwsEksRegisteredTarget
  , AwsEksDestroyPredecessorIdentity (..)
  , AwsEksRegisteredTargetDestroyError (..)
  )
where

import Data.Bifunctor (first)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AwsStackReaderRepository
  ( AwsStackReaderClient
  , AwsStackReaderClientError
  , CommittedAwsStackReaderBundle
  , awsStackReaderAuthorityCoordinateDigest
  , awsStackReaderAuthorityGraphDigest
  , awsStackReaderAuthorityKey
  , awsStackReaderAuthorityOperationId
  , awsStackReaderAuthorityRunId
  , awsStackReaderAuthorityScope
  , committedAwsStackReaderDecisionInputs
  , committedAwsStackReaderIdentity
  , committedAwsStackReaderProviderBinding
  , independentlyReadBackCommittedAwsStackReaderBundle
  )
import Prodbox.ControlPlane.EksDrainIntentRepository
  ( eksDrainIntentAuthorityRecoveryIdentity
  )
import Prodbox.ControlPlane.EksDrainReadBackReceiptClient
  ( EksDrainReadBackReceiptClient (..)
  , EksDrainReadBackReceiptClientError
  )
import Prodbox.ControlPlane.EksDrainReadBackReceiptRepository
  ( committedEksDrainTargetsAbsentEvidence
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupOperationId
  )
import Prodbox.Lifecycle.Teardown.AwsEksAdapter
  ( AwsEksObservationPurpose (ObserveEksForDecision)
  , VerifiedAwsEksObservation
  , verifiedAwsEksExactObservation
  )
import Prodbox.Lifecycle.Teardown.AwsEksDestroyAdapter
  ( AwsEksDestroyRefusal
  , awsEksDestroyRequestProviderIntent
  , mkAwsEksDestroyRequest
  )
import Prodbox.Lifecycle.Teardown.AwsRegisteredTargetInterpreter
  ( AwsEksPresentDestroyBoundary
  , AwsRegisteredTargetInterpreterError (..)
  , AwsStackDecisionInputs
  , AwsStackProviderBinding
  , awsStackDecisionInputsCheckpointPair
  , awsStackDecisionInputsKey
  , awsStackDecisionInputsManifest
  , awsStackDecisionInputsOperationId
  , awsStackDecisionInputsScope
  , awsStackProviderBindingConfig
  , awsStackProviderBindingKey
  , awsStackProviderBindingOperationId
  , awsStackProviderBindingRevision
  , awsStackProviderBindingScope
  , mkAwsEksPresentDestroyBoundary
  )
import Prodbox.Lifecycle.Teardown.Decision
  ( StackDecisionBindingError
  , StackDesiredAbsenceDecision (..)
  , decideStackDesiredAbsence
  )
import Prodbox.Lifecycle.Teardown.EksDrainIntent
  ( EksDrainTargetsAbsentDisposition (..)
  , eksDrainIntentBinding
  , eksDrainTargetsAbsentDisposition
  , eksDrainTargetsAbsentIntent
  )
import Prodbox.Lifecycle.Teardown.EksDrainInterpreter
  ( EksDrainCommitSelectionBoundary
  , EksDrainDestroyAdmissionError
  , EksDrainInterpreter
  , acquireAwsEksDestroyAuthorization
  )
import Prodbox.Lifecycle.Teardown.EksTeardownExecutor
  ( EksTeardownExecutorError
  , eksDrainOperationBindingForContext
  )
import Prodbox.Lifecycle.Teardown.Execution
  ( TeardownAttemptedPredecessor
  , TeardownExecutionContext
  , TeardownSucceededPredecessor
  , teardownAttemptedPredecessorOperation
  , teardownAttemptedPredecessorOperationId
  , teardownExecutionAttemptedPredecessors
  , teardownExecutionGraphDigest
  , teardownExecutionIdentity
  , teardownExecutionObservationScope
  , teardownExecutionOperationId
  , teardownExecutionOperationIdFor
  , teardownExecutionRunId
  , teardownExecutionSuccessfulPredecessors
  , teardownSucceededPredecessorOperation
  , teardownSucceededPredecessorOperationId
  )
import Prodbox.Lifecycle.Teardown.ExecutionIdentity
  ( TeardownExecutionIdentity
  )
import Prodbox.Lifecycle.Teardown.Model
  ( LifecycleClass
  , ManagedResourceCoordinateDigest
  , ObservationEvidenceScope
  , RegisteredResourceKey (..)
  , ResourceKind (..)
  )
import Prodbox.Lifecycle.Teardown.Observation
  ( CompleteObservationSetError
  , mkCompleteObservationSet
  )
import Prodbox.Lifecycle.Teardown.Program
  ( RegisteredTargetBinding
  , TeardownOperation (..)
  , registeredTargetCoordinateDigest
  , registeredTargetKey
  , registeredTargetKind
  , registeredTargetLifecycleClass
  , teardownOperationTag
  )
import Prodbox.Lifecycle.Teardown.ProviderDispatch
  ( ProviderDispatchError
  , ProviderDispatchPurpose (ProviderRegisteredMutation)
  , TeardownProviderBoundary
  , dispatchRegisteredProviderMutation
  , mkProviderDispatchKey
  , observationRevisionForProviderDispatchKey
  )
import Prodbox.Lifecycle.Teardown.RegisteredTargetResult
  ( RegisteredTargetReconcileError
  , RegisteredTargetReconcileResult
  , mkAwsEksRegisteredTargetReconcile
  )
import Prodbox.Lifecycle.Teardown.Registry
  ( lookupRegisteredIdentity
  , registeredIdentityCoordinateDigest
  , registeredIdentityKind
  , registeredIdentityLifecycleClass
  )

-- | Closed dependency inventory.  The deadline callback receives the opaque
-- execution identity, so an implementation cannot choose a different run,
-- graph, node, operation, or attempt.  It supplies liveness only; every proof
-- identity is derived or recovered below.
data AwsEksRegisteredTargetDestroyInterpreter m
  = AwsEksRegisteredTargetDestroyInterpreter
  { internalStackReaderClient :: !(AwsStackReaderClient m)
  , internalDrainReceiptClient :: !(EksDrainReadBackReceiptClient m)
  , internalDrainInterpreter :: !(EksDrainInterpreter m)
  , internalFreshSessionBoundary :: !(EksDrainCommitSelectionBoundary m)
  , internalProviderBoundary :: !(TeardownProviderBoundary m)
  , internalReadFreshSessionDeadline
      :: TeardownExecutionIdentity
      -> m (Either Text Integer)
  }

mkAwsEksRegisteredTargetDestroyInterpreter
  :: AwsStackReaderClient m
  -> EksDrainReadBackReceiptClient m
  -> EksDrainInterpreter m
  -> EksDrainCommitSelectionBoundary m
  -> TeardownProviderBoundary m
  -> (TeardownExecutionIdentity -> m (Either Text Integer))
  -> AwsEksRegisteredTargetDestroyInterpreter m
mkAwsEksRegisteredTargetDestroyInterpreter
  stackReader
  receiptClient
  drainInterpreter
  sessionBoundary
  providerBoundary
  deadlineReader =
    AwsEksRegisteredTargetDestroyInterpreter
      { internalStackReaderClient = stackReader
      , internalDrainReceiptClient = receiptClient
      , internalDrainInterpreter = drainInterpreter
      , internalFreshSessionBoundary = sessionBoundary
      , internalProviderBoundary = providerBoundary
      , internalReadFreshSessionDeadline = deadlineReader
      }

-- | Surface-independent diagnostic identity for the exact direct predecessor
-- set.  The operation ID is the compiled catalog value, never parsed text.
data AwsEksDestroyPredecessorIdentity = AwsEksDestroyPredecessorIdentity
  { awsEksDestroyPredecessorOperationTag :: !Text
  , awsEksDestroyPredecessorOperationId :: !CleanupOperationId
  }
  deriving (Eq, Ord, Show)

data AwsEksRegisteredTargetDestroyError
  = AwsEksRegisteredTargetDestroyTargetUnregistered !RegisteredResourceKey
  | AwsEksRegisteredTargetDestroyTargetKeyMismatch
      !RegisteredResourceKey
      !RegisteredResourceKey
  | AwsEksRegisteredTargetDestroyTargetKindMismatch
      !ResourceKind
      !ResourceKind
  | AwsEksRegisteredTargetDestroyTargetLifecycleMismatch
      !(Maybe LifecycleClass)
      !(Maybe LifecycleClass)
  | AwsEksRegisteredTargetDestroyTargetCoordinateMismatch
      !ManagedResourceCoordinateDigest
      !ManagedResourceCoordinateDigest
  | AwsEksRegisteredTargetDestroyCurrentOperationMissing
  | AwsEksRegisteredTargetDestroyCurrentOperationMismatch
      !CleanupOperationId
      !CleanupOperationId
  | AwsEksRegisteredTargetDestroyEbsBackstopMissing
  | AwsEksRegisteredTargetDestroyEbsBackstopAmbiguous !Int
  | AwsEksRegisteredTargetDestroyCatalogOperationMissing !Text
  | AwsEksRegisteredTargetDestroySuccessfulPredecessorsMismatch
      ![AwsEksDestroyPredecessorIdentity]
      ![AwsEksDestroyPredecessorIdentity]
  | AwsEksRegisteredTargetDestroyAttemptedPredecessorsUnexpected
      ![AwsEksDestroyPredecessorIdentity]
  | AwsEksRegisteredTargetDestroyDrainBindingInvalid
      !EksTeardownExecutorError
  | AwsEksRegisteredTargetDestroyStackReaderRecoveryFailed
      !AwsStackReaderClientError
  | AwsEksRegisteredTargetDestroyStackReaderIdentityMismatch
  | AwsEksRegisteredTargetDestroyDecisionInputsBindingMismatch
  | AwsEksRegisteredTargetDestroyProviderBindingMismatch
  | AwsEksRegisteredTargetDestroyObservationSetInvalid
      !CompleteObservationSetError
  | AwsEksRegisteredTargetDestroyDecisionInvalid
      !StackDecisionBindingError
  | AwsEksRegisteredTargetDestroyDecisionNotAuthorized
      !StackDesiredAbsenceDecision
  | AwsEksRegisteredTargetDestroyReceiptRecoveryFailed
      !EksDrainReadBackReceiptClientError
  | AwsEksRegisteredTargetDestroyReceiptBindingMismatch
  | AwsEksRegisteredTargetDestroyNoKubernetesTarget
  | AwsEksRegisteredTargetDestroyDispatchKeyInvalid
      !ProviderDispatchError
  | AwsEksRegisteredTargetDestroyDeadlineUnavailable !Text
  | AwsEksRegisteredTargetDestroyAuthorizationFailed
      !EksDrainDestroyAdmissionError
  | AwsEksRegisteredTargetDestroyRequestInvalid !AwsEksDestroyRefusal
  | AwsEksRegisteredTargetDestroyDispatchFailed !ProviderDispatchError
  | AwsEksRegisteredTargetDestroyResultInvalid
      !RegisteredTargetReconcileError
  deriving (Eq, Show)

-- | Adapter for the continuation slot in 'AwsRegisteredTargetInterpreter'.
-- Detailed failures stay available from
-- 'reconcilePresentAwsEksRegisteredTarget'; the generic interpreter receives
-- only its closed, typed refusal algebra.
awsEksRegisteredTargetDestroyBoundary
  :: (Monad m)
  => AwsEksRegisteredTargetDestroyInterpreter m
  -> AwsEksPresentDestroyBoundary m
awsEksRegisteredTargetDestroyBoundary interpreter =
  mkAwsEksPresentDestroyBoundary $ \context target verified ->
    first mapBoundaryError
      <$> reconcilePresentAwsEksRegisteredTarget
        interpreter
        context
        target
        verified

-- | Recover all durable authority and submit one stable EKS Provider destroy
-- mutation.  A Provider response is retained only as an attempt disposition;
-- final physical absence remains the separate registered-target read-back.
reconcilePresentAwsEksRegisteredTarget
  :: (Monad m)
  => AwsEksRegisteredTargetDestroyInterpreter m
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> VerifiedAwsEksObservation 'ObserveEksForDecision
  -> m
       ( Either
           AwsEksRegisteredTargetDestroyError
           RegisteredTargetReconcileResult
       )
reconcilePresentAwsEksRegisteredTarget interpreter context target verified =
  case validateInvocation context target of
    Left err -> pure (Left err)
    Right () -> case eksDrainOperationBindingForContext context target of
      Left err -> pure (Left (AwsEksRegisteredTargetDestroyDrainBindingInvalid err))
      Right drainBinding -> recoverStackAuthority drainBinding
 where
  operationId = teardownExecutionOperationId context
  scope = teardownExecutionObservationScope context
  key = registeredTargetKey target
  exact = verifiedAwsEksExactObservation verified

  recoverStackAuthority drainBinding = do
    loadedBundle <-
      independentlyReadBackCommittedAwsStackReaderBundle
        (internalStackReaderClient interpreter)
        operationId
        key
        scope
    case loadedBundle of
      Left err ->
        pure
          ( Left
              (AwsEksRegisteredTargetDestroyStackReaderRecoveryFailed err)
          )
      Right bundle
        | not (stackReaderIdentityMatches context target bundle) ->
            pure (Left AwsEksRegisteredTargetDestroyStackReaderIdentityMismatch)
        | otherwise ->
            let inputs = committedAwsStackReaderDecisionInputs bundle
                providerBinding = committedAwsStackReaderProviderBinding bundle
             in if not (decisionInputsMatch operationId key scope inputs)
                  then pure (Left AwsEksRegisteredTargetDestroyDecisionInputsBindingMismatch)
                  else
                    if not (providerBindingMatches operationId key scope providerBinding)
                      then pure (Left AwsEksRegisteredTargetDestroyProviderBindingMismatch)
                      else decideAndRecoverReceipt drainBinding inputs providerBinding

  decideAndRecoverReceipt drainBinding inputs providerBinding =
    case mkCompleteObservationSet scope [key] [exact] of
      Left err ->
        pure (Left (AwsEksRegisteredTargetDestroyObservationSetInvalid err))
      Right observations ->
        case decideStackDesiredAbsence
          key
          observations
          (awsStackDecisionInputsCheckpointPair inputs)
          (awsStackDecisionInputsManifest inputs) of
          Left err -> pure (Left (AwsEksRegisteredTargetDestroyDecisionInvalid err))
          Right decision -> case decision of
            StackDestroyFromVerifiedPrimary {} ->
              recoverReceipt drainBinding providerBinding decision
            StackDestroyFromVerifiedManifest {} ->
              recoverReceipt drainBinding providerBinding decision
            _ ->
              pure
                (Left (AwsEksRegisteredTargetDestroyDecisionNotAuthorized decision))

  recoverReceipt drainBinding providerBinding decision = do
    recovered <-
      recoverEksDrainReceiptFromIntentIdentity
        (internalDrainReceiptClient interpreter)
        (eksDrainIntentAuthorityRecoveryIdentity drainBinding)
    case recovered of
      Left err ->
        pure (Left (AwsEksRegisteredTargetDestroyReceiptRecoveryFailed err))
      Right receipt ->
        let evidence = committedEksDrainTargetsAbsentEvidence receipt
         in if eksDrainIntentBinding (eksDrainTargetsAbsentIntent evidence) /= drainBinding
              then pure (Left AwsEksRegisteredTargetDestroyReceiptBindingMismatch)
              else case eksDrainTargetsAbsentDisposition evidence of
                NoKubernetesDrainTargetRequired ->
                  pure (Left AwsEksRegisteredTargetDestroyNoKubernetesTarget)
                ExactKubernetesDrainTargetsAbsent ->
                  authorizeAndDispatch drainBinding providerBinding decision evidence

  authorizeAndDispatch drainBinding providerBinding decision evidence =
    case mkProviderDispatchKey operationId ProviderRegisteredMutation of
      Left err ->
        pure (Left (AwsEksRegisteredTargetDestroyDispatchKeyInvalid err))
      Right dispatchKey -> do
        deadlineResult <-
          internalReadFreshSessionDeadline
            interpreter
            (teardownExecutionIdentity context)
        case deadlineResult of
          Left detail ->
            pure
              (Left (AwsEksRegisteredTargetDestroyDeadlineUnavailable (bounded detail)))
          Right deadline -> do
            authorization <-
              acquireAwsEksDestroyAuthorization
                (internalDrainInterpreter interpreter)
                (internalFreshSessionBoundary interpreter)
                context
                target
                drainBinding
                (awsStackProviderBindingRevision providerBinding)
                decision
                evidence
                (observationRevisionForProviderDispatchKey dispatchKey)
                deadline
                verified
            case authorization of
              Left err ->
                pure (Left (AwsEksRegisteredTargetDestroyAuthorizationFailed err))
              Right admitted ->
                case mkAwsEksDestroyRequest
                  admitted
                  (awsStackProviderBindingRevision providerBinding)
                  (awsStackProviderBindingConfig providerBinding) of
                  Left err ->
                    pure (Left (AwsEksRegisteredTargetDestroyRequestInvalid err))
                  Right request -> do
                    attempted <-
                      dispatchRegisteredProviderMutation
                        (internalProviderBoundary interpreter)
                        dispatchKey
                        (awsEksDestroyRequestProviderIntent request)
                    pure $ do
                      mutation <-
                        first AwsEksRegisteredTargetDestroyDispatchFailed attempted
                      first
                        AwsEksRegisteredTargetDestroyResultInvalid
                        ( mkAwsEksRegisteredTargetReconcile
                            operationId
                            target
                            scope
                            admitted
                            mutation
                        )

validateInvocation
  :: TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> Either AwsEksRegisteredTargetDestroyError ()
validateInvocation context target = do
  validateStaticTarget AwsEksKey target
  case teardownExecutionOperationIdFor
    context
    (ReconcileRegisteredTargetAbsent target) of
    Nothing -> Left AwsEksRegisteredTargetDestroyCurrentOperationMissing
    Just catalogOperation
      | catalogOperation == teardownExecutionOperationId context -> Right ()
      | otherwise ->
          Left
            ( AwsEksRegisteredTargetDestroyCurrentOperationMismatch
                catalogOperation
                (teardownExecutionOperationId context)
            )
  validateSuccessfulPredecessors context target

validateSuccessfulPredecessors
  :: TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> Either AwsEksRegisteredTargetDestroyError ()
validateSuccessfulPredecessors context target = do
  ebsTarget <- case ebsBackstops of
    [] -> Left AwsEksRegisteredTargetDestroyEbsBackstopMissing
    [backstop] -> Right backstop
    candidates ->
      Left (AwsEksRegisteredTargetDestroyEbsBackstopAmbiguous (length candidates))
  validateStaticTarget AwsEbsPerRunTestKey ebsTarget
  expected <-
    mapM
      expectedIdentity
      [ ObserveRegisteredTarget target
      , ReadBackStackCheckpointRecovery target
      , ReadBackAwsStackReaderBundle target
      , ReadBackEksKubernetesDrain target
      , ReadBackRegisteredTargetAbsent ebsTarget
      ]
  let actual = map succeededIdentity successful
      attempted = map attemptedIdentity (teardownExecutionAttemptedPredecessors context)
  if sort actual == sort expected
    then Right ()
    else
      Left
        ( AwsEksRegisteredTargetDestroySuccessfulPredecessorsMismatch
            (sort expected)
            (sort actual)
        )
  case attempted of
    [] -> Right ()
    _ ->
      Left
        ( AwsEksRegisteredTargetDestroyAttemptedPredecessorsUnexpected
            (sort attempted)
        )
 where
  successful = teardownExecutionSuccessfulPredecessors context
  ebsBackstops =
    [ backstop
    | predecessor <- successful
    , ReadBackRegisteredTargetAbsent backstop <-
        [teardownSucceededPredecessorOperation predecessor]
    , registeredTargetKey backstop == AwsEbsPerRunTestKey
    ]
  expectedIdentity operation = case teardownExecutionOperationIdFor context operation of
    Nothing ->
      Left
        ( AwsEksRegisteredTargetDestroyCatalogOperationMissing
            (teardownOperationTag operation)
        )
    Just operationId ->
      Right
        AwsEksDestroyPredecessorIdentity
          { awsEksDestroyPredecessorOperationTag = teardownOperationTag operation
          , awsEksDestroyPredecessorOperationId = operationId
          }

succeededIdentity
  :: TeardownSucceededPredecessor surface
  -> AwsEksDestroyPredecessorIdentity
succeededIdentity predecessor =
  AwsEksDestroyPredecessorIdentity
    { awsEksDestroyPredecessorOperationTag =
        teardownOperationTag (teardownSucceededPredecessorOperation predecessor)
    , awsEksDestroyPredecessorOperationId =
        teardownSucceededPredecessorOperationId predecessor
    }

attemptedIdentity
  :: TeardownAttemptedPredecessor surface
  -> AwsEksDestroyPredecessorIdentity
attemptedIdentity predecessor =
  AwsEksDestroyPredecessorIdentity
    { awsEksDestroyPredecessorOperationTag =
        teardownOperationTag (teardownAttemptedPredecessorOperation predecessor)
    , awsEksDestroyPredecessorOperationId =
        teardownAttemptedPredecessorOperationId predecessor
    }

validateStaticTarget
  :: RegisteredResourceKey
  -> RegisteredTargetBinding
  -> Either AwsEksRegisteredTargetDestroyError ()
validateStaticTarget expectedKey target = do
  if registeredTargetKey target == expectedKey
    then Right ()
    else
      Left
        ( AwsEksRegisteredTargetDestroyTargetKeyMismatch
            expectedKey
            (registeredTargetKey target)
        )
  identity <-
    maybe
      (Left (AwsEksRegisteredTargetDestroyTargetUnregistered expectedKey))
      Right
      (lookupRegisteredIdentity expectedKey)
  if registeredTargetKind target == registeredIdentityKind identity
    then Right ()
    else
      Left
        ( AwsEksRegisteredTargetDestroyTargetKindMismatch
            (registeredIdentityKind identity)
            (registeredTargetKind target)
        )
  if registeredTargetLifecycleClass target
    == registeredIdentityLifecycleClass identity
    then Right ()
    else
      Left
        ( AwsEksRegisteredTargetDestroyTargetLifecycleMismatch
            (registeredIdentityLifecycleClass identity)
            (registeredTargetLifecycleClass target)
        )
  if registeredTargetCoordinateDigest target
    == registeredIdentityCoordinateDigest identity
    then Right ()
    else
      Left
        ( AwsEksRegisteredTargetDestroyTargetCoordinateMismatch
            (registeredIdentityCoordinateDigest identity)
            (registeredTargetCoordinateDigest target)
        )

decisionInputsMatch
  :: CleanupOperationId
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> AwsStackDecisionInputs
  -> Bool
decisionInputsMatch operationId key scope inputs =
  awsStackDecisionInputsOperationId inputs == operationId
    && awsStackDecisionInputsKey inputs == key
    && awsStackDecisionInputsScope inputs == scope

providerBindingMatches
  :: CleanupOperationId
  -> RegisteredResourceKey
  -> ObservationEvidenceScope
  -> AwsStackProviderBinding
  -> Bool
providerBindingMatches operationId key scope binding =
  awsStackProviderBindingOperationId binding == operationId
    && awsStackProviderBindingKey binding == key
    && awsStackProviderBindingScope binding == scope

stackReaderIdentityMatches
  :: TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> CommittedAwsStackReaderBundle
  -> Bool
stackReaderIdentityMatches context target bundle =
  awsStackReaderAuthorityRunId identity == teardownExecutionRunId context
    && awsStackReaderAuthorityGraphDigest identity == teardownExecutionGraphDigest context
    && awsStackReaderAuthorityOperationId identity == teardownExecutionOperationId context
    && awsStackReaderAuthorityKey identity == registeredTargetKey target
    && awsStackReaderAuthorityCoordinateDigest identity
      == registeredTargetCoordinateDigest target
    && awsStackReaderAuthorityScope identity == teardownExecutionObservationScope context
 where
  identity = committedAwsStackReaderIdentity bundle

mapBoundaryError
  :: AwsEksRegisteredTargetDestroyError
  -> AwsRegisteredTargetInterpreterError
mapBoundaryError err = case err of
  AwsEksRegisteredTargetDestroyStackReaderRecoveryFailed detail ->
    AwsRegisteredTargetDecisionInputsUnavailable (bounded (Text.pack (show detail)))
  AwsEksRegisteredTargetDestroyDecisionInputsBindingMismatch ->
    AwsRegisteredTargetDecisionInputsBindingMismatch
  AwsEksRegisteredTargetDestroyProviderBindingMismatch ->
    AwsRegisteredTargetProviderBindingMismatch
  AwsEksRegisteredTargetDestroyObservationSetInvalid detail ->
    AwsRegisteredTargetObservationSetInvalid detail
  AwsEksRegisteredTargetDestroyDecisionInvalid detail ->
    AwsRegisteredTargetDecisionBindingInvalid detail
  AwsEksRegisteredTargetDestroyDecisionNotAuthorized decision -> case decision of
    StackAlreadyAbsent {} -> AwsRegisteredTargetDecisionContradictedObservation AwsEksKey
    StackRestoreBackupThenDestroy {} ->
      AwsRegisteredTargetCheckpointRecoveryRequired AwsEksKey
    StackDesiredAbsenceRefused key refusals ->
      AwsRegisteredTargetDecisionRefused key refusals
    _ -> AwsRegisteredTargetEksDestroyBoundaryInvalid
  AwsEksRegisteredTargetDestroyDispatchKeyInvalid detail ->
    AwsRegisteredTargetDispatchKeyInvalid detail
  AwsEksRegisteredTargetDestroyDispatchFailed detail ->
    AwsRegisteredTargetDispatchInvalid detail
  AwsEksRegisteredTargetDestroyResultInvalid detail ->
    AwsRegisteredTargetResultInvalid detail
  _ -> AwsRegisteredTargetEksDestroyBoundaryInvalid

bounded :: Text -> Text
bounded = Text.take 1024
