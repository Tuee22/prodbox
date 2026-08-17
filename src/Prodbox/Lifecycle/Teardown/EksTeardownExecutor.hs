{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Lifecycle-owned interpreter for the four EKS Kubernetes-drain nodes in a
-- compiled desired-absence program.  The graph and operation identities come
-- exclusively from 'TeardownExecutionContext'.  Durable intent and read-back
-- evidence live behind the home Lifecycle Authority clients; this module has
-- no process-local proof cache and allocates no retry identities.
module Prodbox.Lifecycle.Teardown.EksTeardownExecutor
  ( EksDrainSelectionParameters (..)
  , EksTeardownExecutor (..)
  , executeEksTeardownOperation
  , eksDrainOperationBindingForContext
  , EksTeardownExecutorError (..)
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.EksDrainIntentClient
import Prodbox.ControlPlane.EksDrainIntentRepository
  ( eksDrainIntentAuthorityRecoveryIdentity
  )
import Prodbox.ControlPlane.EksDrainReadBackReceiptClient
import Prodbox.ControlPlane.EksDrainReadBackReceiptRepository
  ( committedEksDrainTargetsAbsentEvidence
  )
import Prodbox.Lifecycle.Teardown.AwsEksAdapter
  ( AwsEksObservationPurpose (ObserveEksForDecision)
  , VerifiedAwsEksObservation
  , verifiedAwsEksExactObservation
  )
import Prodbox.Lifecycle.Teardown.AwsRegisteredTargetInterpreter
import Prodbox.Lifecycle.Teardown.EksDrainAttemptRecovery
import Prodbox.Lifecycle.Teardown.EksDrainIntent
import Prodbox.Lifecycle.Teardown.EksDrainInterpreter
import Prodbox.Lifecycle.Teardown.Execution
import Prodbox.Lifecycle.Teardown.ExecutionIdentity
  ( TeardownExecutionIdentity
  )
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.Program
import Prodbox.Lifecycle.Teardown.Registry

-- | Ephemeral facts needed when an exact live EKS target requires a fresh
-- Kubernetes session. Stable replay of a no-target intent never asks for
-- these values.
data EksDrainSelectionParameters = EksDrainSelectionParameters
  { eksDrainSelectionKubernetesRevision :: !ObservationRevision
  , eksDrainSelectionInventoryRevision :: !ObservationRevision
  , eksDrainSelectionDeadlineEpochSeconds :: !Integer
  }
  deriving (Eq, Show)

-- | Closed dependency inventory for this interpreter.  The selection
-- callback receives only the opaque current execution identity, not the
-- compiled graph or predecessor proof set.
data EksTeardownExecutor m = EksTeardownExecutor
  { eksTeardownRegisteredTargetInterpreter
      :: !(AwsRegisteredTargetInterpreter m)
  , eksTeardownDrainInterpreter :: !(EksDrainInterpreter m)
  , eksTeardownCommitSelectionBoundary
      :: !(EksDrainCommitSelectionBoundary m)
  , eksTeardownAttemptBoundary :: !(EksDrainAttemptBoundary m)
  , eksTeardownIntentClient :: !(EksDrainIntentClient m)
  , eksTeardownReceiptClient :: !(EksDrainReadBackReceiptClient m)
  , eksTeardownSelectionParameters
      :: TeardownExecutionIdentity
      -> m (Either Text EksDrainSelectionParameters)
  }

data EksTeardownExecutorError
  = EksTeardownTargetMissing !RegisteredResourceKey
  | EksTeardownTargetKeyMismatch
      !RegisteredResourceKey
      !RegisteredResourceKey
  | EksTeardownTargetKindMismatch !ResourceKind !ResourceKind
  | EksTeardownTargetLifecycleMismatch
      !(Maybe LifecycleClass)
      !(Maybe LifecycleClass)
  | EksTeardownTargetCoordinateMismatch
      !ManagedResourceCoordinateDigest
      !ManagedResourceCoordinateDigest
  | EksTeardownOperationMissing !Text
  | EksTeardownRequiredAttemptMissing !Text
  | EksTeardownOperationBindingInvalid !EksDrainIntentError
  | EksTeardownProviderObservationFailed
      !AwsRegisteredTargetInterpreterError
  | EksTeardownProviderObservationIncomplete !ExactObservationResult
  | EksTeardownSelectionParametersUnavailable !Text
  | EksTeardownSelectionFailed !EksDrainCommitSelectionError
  | EksTeardownIntentPreparationFailed !EksDrainIntentError
  | EksTeardownIntentRecoveryFailed !EksDrainIntentClientError
  | EksTeardownIntentCommitUnconfirmed !EksDrainIntentClientError
  | EksTeardownAttemptRecoveryFailed !EksDrainAttemptRecoveryError
  | EksTeardownReceiptRecoveryFailed
      !EksDrainReadBackReceiptClientError
  | EksTeardownReceiptCommitUnconfirmed
      !EksDrainReadBackReceiptClientError
  deriving (Eq, Show)

-- | Interpret only the four EKS drain operations.  'Nothing' means the caller
-- must dispatch the operation to another member of the one aggregate
-- lifecycle interpreter.
executeEksTeardownOperation
  :: (Monad m)
  => EksTeardownExecutor m
  -> TeardownExecutionContext surface
  -> TeardownOperation surface
  -> m (Maybe (TeardownNodeResult surface))
executeEksTeardownOperation executor context operation = case operation of
  CommitEksDrainIntent target ->
    Just <$> executeCommit executor context target
  ReadBackEksDrainIntent target ->
    Just <$> executeIntentReadBack executor context target
  DrainEksKubernetesResources target ->
    Just <$> executeDrain executor context target
  ReadBackEksKubernetesDrain target ->
    Just <$> executeDrainReadBack executor context target
  _ -> pure Nothing

-- | Reconstruct the exact four-operation identity from the sealed compiled
-- catalog.  No caller-supplied operation text can enter the durable intent.
eksDrainOperationBindingForContext
  :: TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> Either EksTeardownExecutorError EksDrainOperationBinding
eksDrainOperationBindingForContext context target = do
  validateEksTarget target
  commitOperation <- required "commit EKS drain intent" (CommitEksDrainIntent target)
  intentReadBackOperation <-
    required "read back EKS drain intent" (ReadBackEksDrainIntent target)
  effectOperation <-
    required "drain EKS Kubernetes resources" (DrainEksKubernetesResources target)
  drainReadBackOperation <-
    required "read back EKS Kubernetes drain" (ReadBackEksKubernetesDrain target)
  either
    (Left . EksTeardownOperationBindingInvalid)
    Right
    ( mkEksDrainOperationBinding
        (teardownExecutionObservationScope context)
        (teardownExecutionRunId context)
        (teardownExecutionGraphDigest context)
        commitOperation
        intentReadBackOperation
        effectOperation
        drainReadBackOperation
    )
 where
  required label wanted =
    maybe
      (Left (EksTeardownOperationMissing label))
      Right
      (teardownExecutionOperationIdFor context wanted)

executeCommit
  :: (Monad m)
  => EksTeardownExecutor m
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> m (TeardownNodeResult surface)
executeCommit executor context target = case eksDrainOperationBindingForContext context target of
  Left err -> pure (refused err)
  Right binding -> case requireAttemptedPredecessor context (ObserveRegisteredTarget target) of
    Left err -> pure (refused err)
    Right () -> do
      recovered <- recoverIntent executor binding
      case recovered of
        Right _ -> pure (TeardownMutationAttempt TeardownMutationApplied)
        Left EksDrainIntentClientRecoveryMissing ->
          commitNewIntent executor context target binding
        Left err -> pure (refused (EksTeardownIntentRecoveryFailed err))

commitNewIntent
  :: (Monad m)
  => EksTeardownExecutor m
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> EksDrainOperationBinding
  -> m (TeardownNodeResult surface)
commitNewIntent executor context target binding = do
  observed <-
    observeVerifiedAwsEksForDecision
      (eksTeardownRegisteredTargetInterpreter executor)
      context
      target
  case observed of
    Left err -> pure (refused (EksTeardownProviderObservationFailed err))
    Right verified -> case exactObservationResult (verifiedAwsEksExactObservation verified) of
      ExactResourceAbsent _ ->
        commitPrepared
          executor
          ( mapLeft
              EksTeardownIntentPreparationFailed
              (prepareEksNoKubernetesTargetIntent binding verified)
          )
      ExactResourcePresent _ -> do
        parameters <-
          eksTeardownSelectionParameters executor (teardownExecutionIdentity context)
        case parameters of
          Left detail ->
            pure (refused (EksTeardownSelectionParametersUnavailable detail))
          Right selected -> do
            acquired <-
              acquireVerifiedEksDrainSelection
                (eksTeardownDrainInterpreter executor)
                (eksTeardownCommitSelectionBoundary executor)
                context
                target
                binding
                (eksDrainSelectionKubernetesRevision selected)
                (eksDrainSelectionInventoryRevision selected)
                (eksDrainSelectionDeadlineEpochSeconds selected)
                verified
            case acquired of
              Left err -> pure (refused (EksTeardownSelectionFailed err))
              Right selection ->
                commitPrepared
                  executor
                  ( mapLeft
                      EksTeardownIntentPreparationFailed
                      (prepareEksDrainIntentFromVerifiedSelection selection)
                  )
      incomplete ->
        pure (refused (EksTeardownProviderObservationIncomplete incomplete))

commitPrepared
  :: (Monad m)
  => EksTeardownExecutor m
  -> Either EksTeardownExecutorError EksDrainIntent
  -> m (TeardownNodeResult surface)
commitPrepared _ (Left err) = pure (refused err)
commitPrepared executor (Right intent) = do
  committed <- commitAndReadBackEksDrainIntent (eksTeardownIntentClient executor) intent
  pure $ case committed of
    Right _ -> TeardownMutationAttempt TeardownMutationApplied
    -- The commit request may have reached the Authority.  Its mandatory graph
    -- read-back will determine truth; never rewrite ambiguity as refusal.
    Left err ->
      TeardownMutationAttempt
        ( TeardownMutationResponseLost
            (renderError (EksTeardownIntentCommitUnconfirmed err))
        )

executeIntentReadBack
  :: (Monad m)
  => EksTeardownExecutor m
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> m (TeardownNodeResult surface)
executeIntentReadBack executor context target = case eksDrainOperationBindingForContext context target of
  Left err -> pure (refused err)
  Right binding -> case requireAttemptedPredecessor context (CommitEksDrainIntent target) of
    Left err -> pure (refused err)
    Right () -> do
      recovered <- recoverIntent executor binding
      pure $ case recovered of
        Left err -> refused (EksTeardownIntentRecoveryFailed err)
        Right committed -> TeardownEksDrainIntentReadBack (Right committed)

executeDrain
  :: (Monad m)
  => EksTeardownExecutor m
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> m (TeardownNodeResult surface)
executeDrain executor context target = case eksDrainOperationBindingForContext context target of
  Left err -> pure (refused err)
  Right binding -> case requireAttemptedPredecessor context (ReadBackEksDrainIntent target) of
    Left err -> pure (refused err)
    Right () -> do
      recovered <- recoverIntent executor binding
      case recovered of
        Left err -> pure (refused (EksTeardownIntentRecoveryFailed err))
        Right committed -> do
          withFreshEksExecutionInputs
            executor
            context
            target
            committed
            ( \kubernetesRevision deadline verified ->
                TeardownEksDrainAttempt
                  <$> executeCommittedEksDrainIntentWithContext
                    (eksTeardownDrainInterpreter executor)
                    (eksTeardownAttemptBoundary executor)
                    context
                    target
                    kubernetesRevision
                    deadline
                    verified
                    committed
            )

executeDrainReadBack
  :: (Monad m)
  => EksTeardownExecutor m
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> m (TeardownNodeResult surface)
executeDrainReadBack executor context target = case eksDrainOperationBindingForContext context target of
  Left err -> pure (refused err)
  Right binding -> case requireAttemptedPredecessor context (DrainEksKubernetesResources target) of
    Left err -> pure (refused err)
    Right () -> do
      let identity = eksDrainIntentAuthorityRecoveryIdentity binding
      existing <-
        recoverEksDrainReceiptFromIntentIdentity
          (eksTeardownReceiptClient executor)
          identity
      case existing of
        Right receipt ->
          pure
            ( TeardownEksDrainTargetReadBack
                (Right (committedEksDrainTargetsAbsentEvidence receipt))
            )
        Left err
          | isReceiptMissing err -> createReceipt executor context target binding
          | otherwise ->
              pure (refused (EksTeardownReceiptRecoveryFailed err))

createReceipt
  :: (Monad m)
  => EksTeardownExecutor m
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> EksDrainOperationBinding
  -> m (TeardownNodeResult surface)
createReceipt executor context target binding = do
  recovered <- recoverIntent executor binding
  case recovered of
    Left err -> pure (refused (EksTeardownIntentRecoveryFailed err))
    Right committed ->
      case recoverEksDrainAttemptEvidence
        target
        (eksDrainBindingEffectOperationId binding)
        context
        committed of
        Left err -> pure (refused (EksTeardownAttemptRecoveryFailed err))
        Right attempt ->
          withFreshEksExecutionInputs
            executor
            context
            target
            committed
            ( \kubernetesRevision deadline verified -> do
                observation <-
                  observeEksDrainTargetsReadBackWithContext
                    (eksTeardownDrainInterpreter executor)
                    (eksTeardownAttemptBoundary executor)
                    context
                    target
                    kubernetesRevision
                    deadline
                    verified
                    committed
                    attempt
                receipt <-
                  commitAndReadBackEksDrainReceipt
                    (eksTeardownReceiptClient executor)
                    committed
                    attempt
                    observation
                pure $ case receipt of
                  Left err -> refused (EksTeardownReceiptCommitUnconfirmed err)
                  Right committedReceipt ->
                    TeardownEksDrainTargetReadBack
                      (Right (committedEksDrainTargetsAbsentEvidence committedReceipt))
            )

withFreshEksExecutionInputs
  :: (Monad m)
  => EksTeardownExecutor m
  -> TeardownExecutionContext surface
  -> RegisteredTargetBinding
  -> CommittedEksDrainIntent
  -> ( ObservationRevision
       -> Integer
       -> Maybe (VerifiedAwsEksObservation 'ObserveEksForDecision)
       -> m (TeardownNodeResult surface)
     )
  -> m (TeardownNodeResult surface)
withFreshEksExecutionInputs executor context target committed continue =
  case eksDrainIntentTarget (committedEksDrainIntent committed) of
    EksDrainNoKubernetesTarget {} ->
      continue (ObservationRevision 0) 0 Nothing
    EksDrainExactKubernetesTarget {} -> do
      observed <-
        observeVerifiedAwsEksForDecision
          (eksTeardownRegisteredTargetInterpreter executor)
          context
          target
      case observed of
        Left err -> pure (refused (EksTeardownProviderObservationFailed err))
        Right verified ->
          case exactObservationResult (verifiedAwsEksExactObservation verified) of
            ExactResourcePresent _ -> do
              parameters <-
                eksTeardownSelectionParameters executor (teardownExecutionIdentity context)
              case parameters of
                Left detail ->
                  pure (refused (EksTeardownSelectionParametersUnavailable detail))
                Right selected ->
                  continue
                    (eksDrainSelectionKubernetesRevision selected)
                    (eksDrainSelectionDeadlineEpochSeconds selected)
                    (Just verified)
            incomplete ->
              pure (refused (EksTeardownProviderObservationIncomplete incomplete))

recoverIntent
  :: (Monad m)
  => EksTeardownExecutor m
  -> EksDrainOperationBinding
  -> m (Either EksDrainIntentClientError CommittedEksDrainIntent)
recoverIntent executor =
  recoverCommittedEksDrainIntent (eksTeardownIntentClient executor)
    . eksDrainIntentAuthorityRecoveryIdentity

requireAttemptedPredecessor
  :: TeardownExecutionContext surface
  -> TeardownOperation surface
  -> Either EksTeardownExecutorError ()
requireAttemptedPredecessor context wanted = do
  expectedOperation <-
    maybe
      (Left (EksTeardownOperationMissing "required attempted predecessor"))
      Right
      (teardownExecutionOperationIdFor context wanted)
  case [ predecessor
       | predecessor <- teardownExecutionAttemptedPredecessors context
       , teardownAttemptedPredecessorOperation predecessor == wanted
       , teardownAttemptedPredecessorOperationId predecessor == expectedOperation
       ] of
    [_] -> Right ()
    _ ->
      Left
        ( EksTeardownRequiredAttemptMissing
            (teardownOperationTag wanted)
        )

validateEksTarget
  :: RegisteredTargetBinding -> Either EksTeardownExecutorError ()
validateEksTarget target = do
  identity <-
    maybe
      (Left (EksTeardownTargetMissing (registeredTargetKey target)))
      Right
      (lookupRegisteredIdentity (registeredTargetKey target))
  if registeredIdentityKey identity == AwsEksKey
    then Right ()
    else
      Left
        ( EksTeardownTargetKeyMismatch
            AwsEksKey
            (registeredIdentityKey identity)
        )
  requireEqual
    EksTeardownTargetKindMismatch
    (registeredIdentityKind identity)
    (registeredTargetKind target)
  requireEqual
    EksTeardownTargetLifecycleMismatch
    (registeredIdentityLifecycleClass identity)
    (registeredTargetLifecycleClass target)
  requireEqual
    EksTeardownTargetCoordinateMismatch
    (registeredIdentityCoordinateDigest identity)
    (registeredTargetCoordinateDigest target)

requireEqual
  :: (Eq value)
  => (value -> value -> error)
  -> value
  -> value
  -> Either error ()
requireEqual constructor expected actual
  | expected == actual = Right ()
  | otherwise = Left (constructor expected actual)

-- This constructor is added by the authenticated receipt client specifically
-- so missing is the sole state that may trigger a fresh read-back.  All other
-- transport/store failures fail closed.
isReceiptMissing :: EksDrainReadBackReceiptClientError -> Bool
isReceiptMissing err = case err of
  EksDrainReadBackReceiptClientRecoveryMissing -> True
  _ -> False

refused :: (Show err) => err -> TeardownNodeResult surface
refused = TeardownNodeRefused . renderError

renderError :: (Show err) => err -> Text
renderError = Text.take 4096 . Text.pack . show

mapLeft :: (left -> other) -> Either left value -> Either other value
mapLeft constructor result = case result of
  Left err -> Left (constructor err)
  Right value -> Right value
