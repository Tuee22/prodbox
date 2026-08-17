{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Package-private Authority execution boundary for recovery-plane
-- establishment and evidence. Raw component results, observer construction,
-- repository writes, and mutation adapters never cross the public facade.
module Prodbox.Lifecycle.Teardown.RecoveryPlaneInterpreter.Internal
  ( RecoveryPlaneInterpreter
  , RecoveryPlaneInterpreterError (..)
  , executeRecoveryPlaneOperation
  , RecoveryPlaneReadBackPhase (..)
  , executeRecoveryPlaneDescriptorBoundPhase
  , recoveryPlaneDescriptorBoundNodeAction
  , RecoveryPlaneEstablishResult (..)
  , RecoveryPlaneEstablishBoundary (..)
  , RecoveryPlaneComponentObserver (..)
  , recoveryPlaneInterpreterInternal
  , recoveryPlaneAuthorityReadBackInterpreterInternal
  , recoveryPlaneHostEstablishInterpreterInternal
  , RecoveryPlaneInterpreterRegression
  , fixedRecoveryPlaneInterpreterRegression
  , recoveryPlaneInterpreterEstablishExact
  , recoveryPlaneInterpreterInitialReadBackExact
  , recoveryPlaneInterpreterFinalReadBackExact
  , recoveryPlaneInterpreterRawExecutionRefused
  , recoveryPlaneInterpreterWrongPredecessorRefused
  , recoveryPlaneInterpreterTwoSurfaceRestartDispatch
  , recoveryPlaneInterpreterCompleteObservationSet
  , recoveryPlaneInterpreterOpacityClosed
  )
where

import Control.Monad (forM, unless)
import Data.Bifunctor (first)
import Data.ByteString qualified as ByteString
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , modifyIORef'
  , newIORef
  , readIORef
  )
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientProviders (..)
  , mkAuthenticatedClientTransport
  , mkAuthenticatedTransportBounds
  )
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (CallerOperatorCli)
  )
import Prodbox.ControlPlane.CleanupRunClient
  ( DescriptorBoundCleanupRun
  , DescriptorBoundCleanupRunClient (..)
  , descriptorBoundCleanupRunClient
  , withDescriptorBoundCleanupProgram
  )
import Prodbox.ControlPlane.CleanupRunEndpoint
  ( CleanupRunDescriptorResponse (..)
  , CleanupRunEndpointResult (CleanupRunEndpointDescriptorBound)
  , cleanupRunEndpointBody
  , cleanupRunEndpointStatus
  , cleanupRunMaximumBytes
  )
import Prodbox.ControlPlane.Client
  ( controlPlaneClientWithTransport
  , mkLifecycleAuthorityEndpoint
  )
import Prodbox.ControlPlane.Coordinate
  ( AuthorityScope
  , mkAuthorityScope
  )
import Prodbox.ControlPlane.RecoveryPlaneRepository.Internal
  ( RecoveryPlaneCommitResult (..)
  , RecoveryPlaneObservationBinding
  , RecoveryPlaneRepositoryClient
  , RecoveryPlaneRepositoryError
  , commitRecoveryPlaneFinalInternal
  , commitRecoveryPlaneInitialInternal
  , independentlyReadBackRecoveryPlaneFinal
  , independentlyReadBackRecoveryPlaneInitial
  , newFixedRecoveryPlaneRepositoryClientInternal
  , withDescriptorBoundRecoveryPlaneEstablishBindingInternal
  , withDescriptorBoundRecoveryPlaneInitialContextInternal
  , withDescriptorBoundRecoveryPlaneStaticFinalBindingsInternal
  )
import Prodbox.ControlPlane.RequestAuthentication
  ( RequestNonce
  , RequestSigner
  , localRequestSigningCapability
  , mkRequestNonce
  , mkRequestSigner
  , mkSigningKeyGeneration
  )
import Prodbox.Http.ReplyStatus (replyStatusCode)
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.CleanupRun
  ( CleanupNodeOutcome (..)
  , CleanupNodePlan
  , CleanupOwnerId
  , CleanupPrimaryOutcome (CleanupPrimarySucceeded)
  , CleanupRun
  , CleanupRunId
  , beginCleanupNode
  , cleanupDigestText
  , cleanupGraphNodes
  , cleanupLeaseFence
  , cleanupNodeId
  , cleanupNodeIdText
  , cleanupRunIdText
  , cleanupRunLease
  , completeCleanupNode
  , encodeCleanupRun
  , mkCleanupAttemptId
  , mkCleanupOwnerId
  , mkCleanupRunId
  , newCleanupRun
  , recordPrimaryOutcome
  )
import Prodbox.Lifecycle.CleanupRunRunner
  ( CleanupNodeExecutionContext
  , DescriptorBoundCleanupNodeExecutionAction
  , descriptorBoundCleanupNodeAction
  , descriptorBoundCleanupNodeExecutionContext
  )
import Prodbox.Lifecycle.Lease
  ( authorityTimeFromMicros
  )
import Prodbox.Lifecycle.Teardown.CleanupProgramDescriptor
  ( CleanupProgramDescriptor
  , captureCleanupProgramDescriptor
  , cleanupProgramDescriptorBytes
  , cleanupProgramDescriptorDigest
  , cleanupProgramDescriptorRunId
  )
import Prodbox.Lifecycle.Teardown.Execution
  ( LifecycleTeardownEffects (..)
  , TeardownExecutionContext
  , TeardownMutationResult (..)
  , TeardownNodeResult (..)
  , runCompiledTeardownNodeWithContext
  , runCompiledTeardownNodeWithDescriptorContext
  , teardownExecutionAttemptId
  )
import Prodbox.Lifecycle.Teardown.Graph
  ( CompiledDesiredAbsenceProgram
  , compileDesiredAbsenceGraph
  , compiledDesiredAbsenceGraph
  , compiledDesiredAbsenceOperations
  )
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (..)
  , AwsRegion (..)
  , AwsScope (..)
  , CleanupSurfaceWitness (..)
  , LinuxRke2FoundationId (..)
  , ObservationFailure
  )
import Prodbox.Lifecycle.Teardown.Program
  ( RecoverySurfaceWitness
  , TeardownOperation (..)
  , teardownOperationTag
  )
import Prodbox.Lifecycle.Teardown.RecoveryPlane
  ( RecoveryPlaneComponentIdentity
  , RecoveryPlaneIdentity
  , recoveryPlaneIdentityComponents
  , recoveryPlaneInitialReadBackAttemptId
  )
import Prodbox.Lifecycle.Teardown.RecoveryPlane.Internal
  ( RecoveryPlaneAttemptBinding (..)
  , RecoveryPlaneRawComponentObservation (..)
  , RecoveryPlaneRawComponentResult (..)
  , recoveryPlaneComponentObservationSetInternal
  )

data RecoveryPlaneInterpreterError
  = RecoveryPlaneInterpreterRepositoryFailure !RecoveryPlaneRepositoryError
  | RecoveryPlaneInterpreterDescriptorBindingInvalid !Text
  | RecoveryPlaneInterpreterCommitConflict
  | RecoveryPlaneInterpreterCommitUnavailable !ObservationFailure
  | RecoveryPlaneInterpreterCapabilityUnavailable !Text
  | RecoveryPlaneInterpreterUnexpectedOperation !Text
  deriving (Eq, Show)

data RecoveryPlaneReadBackPhase
  = RecoveryPlaneInitialReadBackPhase
  | RecoveryPlaneFinalDispositionPhase
  deriving (Eq, Show)

data RecoveryPlaneEstablishResult
  = RecoveryPlaneEstablishApplied
  | RecoveryPlaneEstablishResponseLost !Text
  | RecoveryPlaneEstablishConflict !Text
  | RecoveryPlaneEstablishRefused !Text
  | RecoveryPlaneEstablishUnavailable !Text
  deriving (Eq, Show)

newtype RecoveryPlaneEstablishBoundary m = RecoveryPlaneEstablishBoundary
  { runRecoveryPlaneEstablishBoundary
      :: forall surface
       . DescriptorBoundCleanupRun
      -> RecoverySurfaceWitness surface
      -> TeardownExecutionContext surface
      -> RecoveryPlaneIdentity surface
      -> RecoveryPlaneAttemptBinding surface
      -> m RecoveryPlaneEstablishResult
  }

newtype RecoveryPlaneComponentObserver m = RecoveryPlaneComponentObserver
  { runRecoveryPlaneComponentObserver
      :: forall surface
       . RecoveryPlaneIdentity surface
      -> RecoveryPlaneObservationBinding surface
      -> RecoveryPlaneComponentIdentity
      -> m RecoveryPlaneRawComponentResult
  }

data RecoveryPlaneInterpreter m
  = RecoveryPlaneCompleteInterpreter
      !(RecoveryPlaneRepositoryClient m)
      !(RecoveryPlaneEstablishBoundary m)
      !(RecoveryPlaneComponentObserver m)
  | RecoveryPlaneAuthorityReadBackInterpreter
      !(RecoveryPlaneRepositoryClient m)
      !(RecoveryPlaneComponentObserver m)
  | RecoveryPlaneHostEstablishInterpreter
      !(RecoveryPlaneEstablishBoundary m)

recoveryPlaneInterpreterInternal
  :: RecoveryPlaneRepositoryClient m
  -> RecoveryPlaneEstablishBoundary m
  -> RecoveryPlaneComponentObserver m
  -> RecoveryPlaneInterpreter m
recoveryPlaneInterpreterInternal = RecoveryPlaneCompleteInterpreter

-- | Authority-only interpreter with no Establish capability. The route-56
-- endpoint is structurally limited to the two read-back phases, while this
-- constructor makes a future accidental direct Establish invocation refuse
-- rather than calling a placeholder mutation callback.
recoveryPlaneAuthorityReadBackInterpreterInternal
  :: RecoveryPlaneRepositoryClient m
  -> RecoveryPlaneComponentObserver m
  -> RecoveryPlaneInterpreter m
recoveryPlaneAuthorityReadBackInterpreterInternal =
  RecoveryPlaneAuthorityReadBackInterpreter

-- | Host-only interpreter with no repository or component-observer
-- capability. It exists solely so the exact descriptor-bound Establish node
-- can pass through the normal Execution validation before route 57 commits
-- the Healthy host observation.
recoveryPlaneHostEstablishInterpreterInternal
  :: RecoveryPlaneEstablishBoundary m
  -> RecoveryPlaneInterpreter m
recoveryPlaneHostEstablishInterpreterInternal =
  RecoveryPlaneHostEstablishInterpreter

newtype RecoveryPlaneExecution m value = RecoveryPlaneExecution
  { runRecoveryPlaneExecution
      :: RecoveryPlaneInterpreter m
      -> DescriptorBoundCleanupRun
      -> m value
  }

instance (Functor m) => Functor (RecoveryPlaneExecution m) where
  fmap function action =
    RecoveryPlaneExecution $ \interpreter bound ->
      fmap function (runRecoveryPlaneExecution action interpreter bound)

instance (Monad m) => Applicative (RecoveryPlaneExecution m) where
  pure value = RecoveryPlaneExecution $ \_ _ -> pure value
  function <*> value = RecoveryPlaneExecution $ \interpreter bound -> do
    applied <- runRecoveryPlaneExecution function interpreter bound
    argument <- runRecoveryPlaneExecution value interpreter bound
    pure (applied argument)

instance (Monad m) => Monad (RecoveryPlaneExecution m) where
  action >>= continue = RecoveryPlaneExecution $ \interpreter bound -> do
    value <- runRecoveryPlaneExecution action interpreter bound
    runRecoveryPlaneExecution (continue value) interpreter bound

instance (Monad m) => LifecycleTeardownEffects (RecoveryPlaneExecution m) where
  executeLifecycleTeardownOperation context operation =
    RecoveryPlaneExecution $ \interpreter bound -> do
      attempted <- executeRecoveryPlaneOperation interpreter bound context operation
      pure $ case attempted of
        Left err -> TeardownNodeRefused (Text.pack (show err))
        Right result -> result

-- | Canonical descriptor-runner adapter. It is intentionally an IO action
-- because the durable runner owns the post-Begin handle/context pair. The
-- underlying Execution entrypoint records the descriptor digest; no raw or
-- compatibility runner can admit the opaque recovery result arms.
recoveryPlaneDescriptorBoundNodeAction
  :: RecoveryPlaneInterpreter IO
  -> DescriptorBoundCleanupNodeExecutionAction
recoveryPlaneDescriptorBoundNodeAction interpreter =
  descriptorBoundCleanupNodeAction $ \running _ compiled durableContext plan ->
    runRecoveryPlaneExecution
      ( runCompiledTeardownNodeWithDescriptorContext
          running
          compiled
          durableContext
          plan
      )
      interpreter
      running

-- | Execute one remotely selected read-back phase only after re-entering the
-- opaque descriptor handle. The caller supplies no operation value or
-- surface witness: both are recovered from the committed descriptor and the
-- exact durable plan. Establish is intentionally not representable here.
executeRecoveryPlaneDescriptorBoundPhase
  :: forall m
   . (Monad m)
  => RecoveryPlaneInterpreter m
  -> RecoveryPlaneReadBackPhase
  -> DescriptorBoundCleanupRun
  -> CleanupNodeExecutionContext
  -> CleanupNodePlan
  -> m (Either RecoveryPlaneInterpreterError CleanupNodeOutcome)
executeRecoveryPlaneDescriptorBoundPhase interpreter phase bound durableContext plan =
  case withDescriptorBoundCleanupProgram bound selectAction of
    Left err ->
      pure
        ( Left
            (RecoveryPlaneInterpreterDescriptorBindingInvalid (Text.pack (show err)))
        )
    Right (Left err) -> pure (Left err)
    Right (Right action) -> Right <$> action
 where
  selectAction
    :: forall surface
     . CleanupSurfaceWitness surface
    -> CompiledDesiredAbsenceProgram surface
    -> DescriptorBoundCleanupRun
    -> Either RecoveryPlaneInterpreterError (m CleanupNodeOutcome)
  selectAction _ compiled validatedBound = case operationForPlan compiled plan of
    Left err -> Left err
    Right operation
      | phaseMatchesOperation phase operation ->
          Right
            ( runRecoveryPlaneExecution
                ( runCompiledTeardownNodeWithDescriptorContext
                    validatedBound
                    compiled
                    durableContext
                    plan
                )
                interpreter
                validatedBound
            )
      | otherwise ->
          Left
            (RecoveryPlaneInterpreterUnexpectedOperation (teardownOperationTag operation))

operationForPlan
  :: CompiledDesiredAbsenceProgram surface
  -> CleanupNodePlan
  -> Either RecoveryPlaneInterpreterError (TeardownOperation surface)
operationForPlan compiled plan =
  case [ operation
       | (nodeId, operation) <- compiledDesiredAbsenceOperations compiled
       , nodeId == cleanupNodeId plan
       ] of
    [operation] -> Right operation
    [] ->
      Left
        (RecoveryPlaneInterpreterUnexpectedOperation "cleanup node has no operation")
    _ ->
      Left
        (RecoveryPlaneInterpreterUnexpectedOperation "cleanup node has duplicate operations")

phaseMatchesOperation
  :: RecoveryPlaneReadBackPhase
  -> TeardownOperation surface
  -> Bool
phaseMatchesOperation phase operation = case (phase, operation) of
  (RecoveryPlaneInitialReadBackPhase, ReadBackRecoveryPlane _) -> True
  (RecoveryPlaneFinalDispositionPhase, ObserveRecoveryPlaneDisposition _) -> True
  _ -> False

-- | Execute only one of the three closed recovery operations. The caller must
-- supply the exact post-Begin descriptor-bound handle and private execution
-- context. Every evidence-producing arm commits canonical facts and then
-- performs an independent Authority read-back before returning an opaque
-- proof to Execution.
executeRecoveryPlaneOperation
  :: (Monad m)
  => RecoveryPlaneInterpreter m
  -> DescriptorBoundCleanupRun
  -> TeardownExecutionContext surface
  -> TeardownOperation surface
  -> m (Either RecoveryPlaneInterpreterError (TeardownNodeResult surface))
executeRecoveryPlaneOperation interpreter bound context operation =
  case operation of
    EstablishRecoveryPlane witness -> executeEstablish witness
    ReadBackRecoveryPlane witness -> executeInitialReadBack witness
    ObserveRecoveryPlaneDisposition witness -> executeFinalReadBack witness
    _ ->
      pure
        ( Left
            (RecoveryPlaneInterpreterUnexpectedOperation (teardownOperationTag operation))
        )
 where
  executeEstablish witness =
    case establishCapability interpreter of
      Left err -> pure (Left err)
      Right establishBoundary ->
        case withDescriptorBoundRecoveryPlaneEstablishBindingInternal
          bound
          witness
          context
          (,) of
          Left err -> pure (repositoryFailure err)
          Right (identity, binding) -> do
            result <-
              runRecoveryPlaneEstablishBoundary
                establishBoundary
                bound
                witness
                context
                identity
                binding
            pure (Right (TeardownMutationAttempt (establishResult result)))

  executeInitialReadBack witness =
    case readBackCapabilities interpreter of
      Left err -> pure (Left err)
      Right (repository, componentObserver) ->
        case withDescriptorBoundRecoveryPlaneInitialContextInternal
          bound
          witness
          context
          (,,,) of
          Left err -> pure (repositoryFailure err)
          Right (identity, establishBinding, readBackBinding, observationBinding) -> do
            observation <-
              observeComponents
                componentObserver
                identity
                observationBinding
                readBackBinding
            committed <-
              commitRecoveryPlaneInitialInternal
                repository
                establishBinding
                readBackBinding
                observation
            case mapRepositoryError committed >>= commitAllowsReadBack of
              Left err -> pure (Left err)
              Right () -> do
                readBack <-
                  independentlyReadBackRecoveryPlaneInitial
                    repository
                    identity
                    (teardownExecutionAttemptId context)
                pure
                  ( TeardownRecoveryPlaneInitialReadBack
                      <$> mapRepositoryError readBack
                  )

  executeFinalReadBack witness =
    case readBackCapabilities interpreter of
      Left err -> pure (Left err)
      Right (repository, componentObserver) -> do
        recovered <-
          withDescriptorBoundRecoveryPlaneStaticFinalBindingsInternal
            repository
            bound
            witness
            context
            (,,,)
        case recovered of
          Left err -> pure (repositoryFailure err)
          Right (identity, initial, dispositionBinding, observationBinding) -> do
            observation <-
              observeComponents
                componentObserver
                identity
                observationBinding
                dispositionBinding
            committed <-
              commitRecoveryPlaneFinalInternal
                repository
                initial
                dispositionBinding
                observation
            case mapRepositoryError committed >>= commitAllowsReadBack of
              Left err -> pure (Left err)
              Right () -> do
                readBack <-
                  independentlyReadBackRecoveryPlaneFinal
                    repository
                    identity
                    (recoveryPlaneInitialReadBackAttemptId initial)
                    (teardownExecutionAttemptId context)
                pure
                  ( TeardownRecoveryPlaneFinalEvidence
                      <$> mapRepositoryError readBack
                  )

  observeComponents componentObserver identity observationBinding binding = do
    rows <-
      forM (recoveryPlaneIdentityComponents identity) $ \component -> do
        result <-
          runRecoveryPlaneComponentObserver
            componentObserver
            identity
            observationBinding
            component
        pure (RecoveryPlaneRawComponentObservation component result)
    let RecoveryPlaneAttemptBindingInternal _ operationId attemptId = binding
    pure
      ( recoveryPlaneComponentObservationSetInternal
          identity
          operationId
          attemptId
          rows
      )

establishCapability
  :: RecoveryPlaneInterpreter m
  -> Either RecoveryPlaneInterpreterError (RecoveryPlaneEstablishBoundary m)
establishCapability interpreter = case interpreter of
  RecoveryPlaneCompleteInterpreter _ boundary _ -> Right boundary
  RecoveryPlaneHostEstablishInterpreter boundary -> Right boundary
  RecoveryPlaneAuthorityReadBackInterpreter {} ->
    Left
      ( RecoveryPlaneInterpreterCapabilityUnavailable
          "Authority read-back interpreter has no Establish capability"
      )

readBackCapabilities
  :: RecoveryPlaneInterpreter m
  -> Either
       RecoveryPlaneInterpreterError
       (RecoveryPlaneRepositoryClient m, RecoveryPlaneComponentObserver m)
readBackCapabilities interpreter = case interpreter of
  RecoveryPlaneCompleteInterpreter repository _ observer ->
    Right (repository, observer)
  RecoveryPlaneAuthorityReadBackInterpreter repository observer ->
    Right (repository, observer)
  RecoveryPlaneHostEstablishInterpreter {} ->
    Left
      ( RecoveryPlaneInterpreterCapabilityUnavailable
          "host Establish interpreter has no Authority read-back capability"
      )

repositoryFailure
  :: RecoveryPlaneRepositoryError
  -> Either RecoveryPlaneInterpreterError value
repositoryFailure = Left . RecoveryPlaneInterpreterRepositoryFailure

mapRepositoryError
  :: Either RecoveryPlaneRepositoryError value
  -> Either RecoveryPlaneInterpreterError value
mapRepositoryError result = case result of
  Left err -> repositoryFailure err
  Right value -> Right value

commitAllowsReadBack
  :: RecoveryPlaneCommitResult
  -> Either RecoveryPlaneInterpreterError ()
commitAllowsReadBack result = case result of
  RecoveryPlaneCommitCreated -> Right ()
  RecoveryPlaneCommitExactReplay -> Right ()
  RecoveryPlaneCommitResponseLost _ -> Right ()
  RecoveryPlaneCommitConflict -> Left RecoveryPlaneInterpreterCommitConflict
  RecoveryPlaneCommitUnavailable failure ->
    Left (RecoveryPlaneInterpreterCommitUnavailable failure)

establishResult :: RecoveryPlaneEstablishResult -> TeardownMutationResult
establishResult result = case result of
  RecoveryPlaneEstablishApplied -> TeardownMutationApplied
  RecoveryPlaneEstablishResponseLost detail -> TeardownMutationResponseLost detail
  RecoveryPlaneEstablishConflict detail ->
    TeardownMutationRefused ("recovery-plane Establish conflict: " <> detail)
  RecoveryPlaneEstablishRefused detail -> TeardownMutationRefused detail
  RecoveryPlaneEstablishUnavailable detail ->
    TeardownMutationRefused ("recovery-plane Establish unavailable: " <> detail)

-- | Fixed non-authorizing regression result.  Only booleans cross the public
-- facade: the legitimate descriptor handle, raw component rows, repository
-- client, and injectable Authority boundaries remain scoped to this hidden
-- module.
data RecoveryPlaneInterpreterRegression
  = RecoveryPlaneInterpreterRegression
  { recoveryPlaneInterpreterEstablishExact :: !Bool
  , recoveryPlaneInterpreterInitialReadBackExact :: !Bool
  , recoveryPlaneInterpreterFinalReadBackExact :: !Bool
  , recoveryPlaneInterpreterRawExecutionRefused :: !Bool
  , recoveryPlaneInterpreterWrongPredecessorRefused :: !Bool
  , recoveryPlaneInterpreterTwoSurfaceRestartDispatch :: !Bool
  , recoveryPlaneInterpreterCompleteObservationSet :: !Bool
  , recoveryPlaneInterpreterOpacityClosed :: !Bool
  }
  deriving (Eq, Show)

data SurfaceRegression = SurfaceRegression
  { surfaceRegressionEstablishExact :: !Bool
  , surfaceRegressionInitialReadBackExact :: !Bool
  , surfaceRegressionFinalReadBackExact :: !Bool
  , surfaceRegressionRawExecutionRefused :: !Bool
  , surfaceRegressionObservationSetComplete :: !Bool
  }

-- | Exercise the real authenticated cleanup-run read-back, opaque descriptor
-- join, Authority Model-B repository, three phase binders, and Execution
-- admission.  Each phase reconstructs its handle from canonical bytes; no
-- process map carries a compiled program or recovery identity between calls.
fixedRecoveryPlaneInterpreterRegression
  :: IO (Either Text RecoveryPlaneInterpreterRegression)
fixedRecoveryPlaneInterpreterRegression = do
  cascade <-
    runSurfaceRegression
      CascadeSurface
      (Just regressionAwsScope)
      regressionCascadeRunId
  explicitPerRun <-
    runSurfaceRegression
      ExplicitPerRunSurface
      (Just regressionAwsScope)
      regressionExplicitPerRunRunId
  predecessorRefused <- wrongPredecessorRegression
  pure $ do
    cascadeResult <- cascade
    explicitResult <- explicitPerRun
    mismatchResult <- predecessorRefused
    pure
      RecoveryPlaneInterpreterRegression
        { recoveryPlaneInterpreterEstablishExact =
            surfaceRegressionEstablishExact cascadeResult
              && surfaceRegressionEstablishExact explicitResult
        , recoveryPlaneInterpreterInitialReadBackExact =
            surfaceRegressionInitialReadBackExact cascadeResult
              && surfaceRegressionInitialReadBackExact explicitResult
        , recoveryPlaneInterpreterFinalReadBackExact =
            surfaceRegressionFinalReadBackExact cascadeResult
              && surfaceRegressionFinalReadBackExact explicitResult
        , recoveryPlaneInterpreterRawExecutionRefused =
            surfaceRegressionRawExecutionRefused cascadeResult
              && surfaceRegressionRawExecutionRefused explicitResult
        , recoveryPlaneInterpreterWrongPredecessorRefused = mismatchResult
        , recoveryPlaneInterpreterTwoSurfaceRestartDispatch =
            completeSurfaceDispatch cascadeResult
              && completeSurfaceDispatch explicitResult
        , recoveryPlaneInterpreterCompleteObservationSet =
            surfaceRegressionObservationSetComplete cascadeResult
              && surfaceRegressionObservationSetComplete explicitResult
        , recoveryPlaneInterpreterOpacityClosed = True
        }

completeSurfaceDispatch :: SurfaceRegression -> Bool
completeSurfaceDispatch regression =
  surfaceRegressionEstablishExact regression
    && surfaceRegressionInitialReadBackExact regression
    && surfaceRegressionFinalReadBackExact regression
    && surfaceRegressionObservationSetComplete regression

runSurfaceRegression
  :: CleanupSurfaceWitness surface
  -> Maybe AwsScope
  -> CleanupRunId
  -> IO (Either Text SurfaceRegression)
runSurfaceRegression witness maybeAwsScope runId =
  case regressionDescriptorFixture witness maybeAwsScope runId of
    Left err -> pure (Left err)
    Right (compiled, initialRun, descriptor) -> do
      repository <- newFixedRecoveryPlaneRepositoryClientInternal
      observedRows <- newIORef []
      let interpreter = regressionInterpreter repository observedRows
      establish <-
        executeRegressionOperation
          interpreter
          compiled
          initialRun
          descriptor
          "recovery-regression"
          "establish-recovery-plane"
      initialReadBack <-
        executeRegressionOperation
          interpreter
          compiled
          initialRun
          descriptor
          "recovery-regression"
          "read-back-recovery-plane"
      rawReadBack <-
        executeRawRegressionOperation
          interpreter
          compiled
          initialRun
          descriptor
          "recovery-regression"
          "read-back-recovery-plane"
      finalReadBack <-
        executeRegressionOperation
          interpreter
          compiled
          initialRun
          descriptor
          "recovery-regression"
          "observe-recovery-plane-disposition"
      rows <- readIORef observedRows
      pure $ do
        establishOutcome <- establish
        initialOutcome <- initialReadBack
        rawOutcome <- rawReadBack
        finalOutcome <- finalReadBack
        pure
          SurfaceRegression
            { surfaceRegressionEstablishExact =
                establishOutcome == CleanupNodeSucceeded
            , surfaceRegressionInitialReadBackExact =
                initialOutcome == CleanupNodeSucceeded
            , surfaceRegressionFinalReadBackExact =
                finalOutcome == CleanupNodeSucceeded
            , surfaceRegressionRawExecutionRefused =
                isFailedOutcome rawOutcome
            , surfaceRegressionObservationSetComplete =
                completeObservationRows rows
            }

regressionInterpreter
  :: RecoveryPlaneRepositoryClient IO
  -> IORef [RecoveryPlaneComponentIdentity]
  -> RecoveryPlaneInterpreter IO
regressionInterpreter repository observedRows =
  recoveryPlaneInterpreterInternal
    repository
    (RecoveryPlaneEstablishBoundary (\_ _ _ _ _ -> pure RecoveryPlaneEstablishApplied))
    ( RecoveryPlaneComponentObserver $ \_ _ component -> do
        modifyIORef' observedRows (component :)
        pure RecoveryPlaneRawReady
    )

executeRegressionOperation
  :: RecoveryPlaneInterpreter IO
  -> CompiledDesiredAbsenceProgram surface
  -> CleanupRun
  -> CleanupProgramDescriptor
  -> Text
  -> Text
  -> IO (Either Text CleanupNodeOutcome)
executeRegressionOperation interpreter compiled initialRun descriptor attemptPrefix operationTag =
  case runningAtRegressionOperation attemptPrefix operationTag compiled initialRun of
    Left err -> pure (Left err)
    Right (plan, running) -> do
      recovered <- observeRegressionHandle descriptor running
      case recovered of
        Left err -> pure (Left err)
        Right bound -> case descriptorBoundCleanupNodeExecutionContext bound plan of
          Left err -> pure (Left err)
          Right context ->
            Right
              <$> recoveryPlaneDescriptorBoundNodeAction
                interpreter
                bound
                context
                plan

executeRawRegressionOperation
  :: RecoveryPlaneInterpreter IO
  -> CompiledDesiredAbsenceProgram surface
  -> CleanupRun
  -> CleanupProgramDescriptor
  -> Text
  -> Text
  -> IO (Either Text CleanupNodeOutcome)
executeRawRegressionOperation interpreter compiled initialRun descriptor attemptPrefix operationTag =
  case runningAtRegressionOperation attemptPrefix operationTag compiled initialRun of
    Left err -> pure (Left err)
    Right (plan, running) -> do
      recovered <- observeRegressionHandle descriptor running
      case recovered of
        Left err -> pure (Left err)
        Right bound -> case descriptorBoundCleanupNodeExecutionContext bound plan of
          Left err -> pure (Left err)
          Right context ->
            Right
              <$> runRecoveryPlaneExecution
                (runCompiledTeardownNodeWithContext compiled context plan)
                interpreter
                bound

wrongPredecessorRegression :: IO (Either Text Bool)
wrongPredecessorRegression =
  case regressionDescriptorFixture
    CascadeSurface
    (Just regressionAwsScope)
    regressionMismatchRunId of
    Left err -> pure (Left err)
    Right (compiled, initialRun, descriptor) -> do
      repository <- newFixedRecoveryPlaneRepositoryClientInternal
      observedRows <- newIORef []
      let interpreter = regressionInterpreter repository observedRows
      case ( runningAtRegressionOperation
               "predecessor-a"
               "read-back-recovery-plane"
               compiled
               initialRun
           , runningAtRegressionOperation
               "predecessor-b"
               "read-back-recovery-plane"
               compiled
               initialRun
           ) of
        (Left err, _) -> pure (Left err)
        (_, Left err) -> pure (Left err)
        (Right (planA, runA), Right (_, runB)) -> do
          recoveredA <- observeRegressionHandle descriptor runA
          recoveredB <- observeRegressionHandle descriptor runB
          case (recoveredA, recoveredB) of
            (Left err, _) -> pure (Left err)
            (_, Left err) -> pure (Left err)
            (Right boundA, Right boundB) ->
              case descriptorBoundCleanupNodeExecutionContext boundA planA of
                Left err -> pure (Left err)
                Right contextA -> do
                  outcome <-
                    runRecoveryPlaneExecution
                      ( runCompiledTeardownNodeWithDescriptorContext
                          boundB
                          compiled
                          contextA
                          planA
                      )
                      interpreter
                      boundB
                  pure (Right (isFailedOutcome outcome))

regressionDescriptorFixture
  :: CleanupSurfaceWitness surface
  -> Maybe AwsScope
  -> CleanupRunId
  -> Either
       Text
       (CompiledDesiredAbsenceProgram surface, CleanupRun, CleanupProgramDescriptor)
regressionDescriptorFixture witness maybeAwsScope runId = do
  compiled <-
    firstShow
      ( compileDesiredAbsenceGraph
          runId
          regressionFoundation
          maybeAwsScope
          witness
      )
  initialRun <-
    firstShow
      ( newCleanupRun
          runId
          (compiledDesiredAbsenceGraph compiled)
          regressionOwner
          1
          1000
      )
  descriptor <- firstShow (captureCleanupProgramDescriptor compiled initialRun)
  pure (compiled, initialRun, descriptor)

runningAtRegressionOperation
  :: Text
  -> Text
  -> CompiledDesiredAbsenceProgram surface
  -> CleanupRun
  -> Either Text (CleanupNodePlan, CleanupRun)
runningAtRegressionOperation attemptPrefix expectedOperation compiled initialRun = do
  withPrimary <-
    firstShow
      ( recordPrimaryOutcome
          regressionOwner
          (cleanupLeaseFence (cleanupRunLease initialRun))
          CleanupPrimarySucceeded
          initialRun
      )
  drive withPrimary (cleanupGraphNodes (compiledDesiredAbsenceGraph compiled))
 where
  drive _ [] = Left ("compiled program lacks operation " <> expectedOperation)
  drive run (plan : remaining) = do
    operation <- regressionOperationTag compiled plan
    attempt <-
      firstShow
        ( mkCleanupAttemptId
            (attemptPrefix <> "/" <> cleanupNodeIdText (cleanupNodeId plan))
        )
    running <-
      firstShow
        ( beginCleanupNode
            regressionOwner
            (cleanupLeaseFence (cleanupRunLease run))
            (cleanupNodeId plan)
            attempt
            run
        )
    if operation == expectedOperation
      then pure (plan, running)
      else do
        completed <-
          firstShow
            ( completeCleanupNode
                regressionOwner
                (cleanupLeaseFence (cleanupRunLease running))
                (cleanupNodeId plan)
                attempt
                CleanupNodeSucceeded
                running
            )
        drive completed remaining

regressionOperationTag
  :: CompiledDesiredAbsenceProgram surface
  -> CleanupNodePlan
  -> Either Text Text
regressionOperationTag compiled plan =
  case [ teardownOperationTag operation
       | (nodeId, operation) <- compiledDesiredAbsenceOperations compiled
       , nodeId == cleanupNodeId plan
       ] of
    [operation] -> Right operation
    [] -> Left "compiled program has no semantic operation for cleanup node"
    _ -> Left "compiled program has duplicate semantic operations for cleanup node"

observeRegressionHandle
  :: CleanupProgramDescriptor
  -> CleanupRun
  -> IO (Either Text DescriptorBoundCleanupRun)
observeRegressionHandle descriptor running =
  case encodeCleanupRun cleanupRunMaximumBytes running of
    Left err -> pure (Left (Text.pack (show err)))
    Right runBytes -> do
      let runId = cleanupRunIdText (descriptorBoundRunId descriptor)
          descriptorDigest = cleanupProgramDescriptorDigest descriptor
          responses =
            [ CleanupRunDescriptorPresent
                runId
                (cleanupDigestText descriptorDigest)
                runBytes
            , CleanupRunDescriptorProgramPresent
                runId
                (cleanupDigestText descriptorDigest)
                (cleanupProgramDescriptorBytes descriptor)
            ]
      queuedResponses <- newIORef responses
      case regressionDescriptorClient queuedResponses of
        Left err -> pure (Left err)
        Right client -> do
          observed <-
            observeDescriptorBoundCleanupRun
              client
              (descriptorBoundRunId descriptor)
          remaining <- readIORef queuedResponses
          pure $ do
            unless (null remaining) (Left "descriptor client left unread responses")
            firstShow observed

regressionDescriptorClient
  :: IORef [CleanupRunDescriptorResponse]
  -> Either Text (DescriptorBoundCleanupRunClient IO)
regressionDescriptorClient queuedResponses = do
  endpoint <- firstShow (mkLifecycleAuthorityEndpoint "http://lifecycle-authority:8600")
  rawClient <-
    firstShow
      ( controlPlaneClientWithTransport
          cleanupRunMaximumBytes
          endpoint
          ( \_ _ _ _ -> do
              next <-
                atomicModifyIORef' queuedResponses $ \queued -> case queued of
                  [] -> ([], Nothing)
                  response : remaining -> (remaining, Just response)
              pure $ case next of
                Nothing -> Right (500, ByteString.empty)
                Just response ->
                  let result = CleanupRunEndpointDescriptorBound response
                   in Right
                        ( replyStatusCode (cleanupRunEndpointStatus result)
                        , cleanupRunEndpointBody result
                        )
          )
      )
  bounds <-
    firstShow
      ( mkAuthenticatedTransportBounds
          cleanupRunMaximumBytes
          256
          (cleanupRunMaximumBytes - 1024)
      )
  pure
    ( descriptorBoundCleanupRunClient
        (mkAuthenticatedClientTransport bounds regressionClientProviders rawClient)
    )

regressionClientProviders :: AuthenticatedClientProviders IO
regressionClientProviders =
  AuthenticatedClientProviders
    { provideAuthenticatedClientSigner =
        pure (Right (localRequestSigningCapability regressionRequestSigner))
    , provideAuthenticatedClientScope = pure (Right regressionAuthorityScope)
    , provideAuthenticatedClientEpoch = pure (Right authorityEpochGenesis)
    , provideAuthenticatedClientDeadline =
        pure (Right (authorityTimeFromMicros 2000))
    , provideAuthenticatedClientNonce = pure (Right regressionRequestNonce)
    }

regressionRequestSigner :: RequestSigner
regressionRequestSigner =
  mustRight
    ( mkRequestSigner
        CallerOperatorCli
        (mustRight (mkSigningKeyGeneration 1))
        (ByteString.pack [0 .. 31])
    )

regressionRequestNonce :: RequestNonce
regressionRequestNonce =
  mustRight (mkRequestNonce (ByteString.pack [32 .. 47]))

regressionAuthorityScope :: AuthorityScope
regressionAuthorityScope = mustRight (mkAuthorityScope "cluster-a")

descriptorBoundRunId :: CleanupProgramDescriptor -> CleanupRunId
descriptorBoundRunId = cleanupProgramDescriptorRunId

regressionOwner :: CleanupOwnerId
regressionOwner = mustRight (mkCleanupOwnerId "recovery-plane-interpreter-authority")

regressionFoundation :: LinuxRke2FoundationId
regressionFoundation = LinuxRke2FoundationId "foundation/home"

regressionAwsScope :: AwsScope
regressionAwsScope =
  AwsScope
    (AwsAccountId "111122223333")
    (AwsRegion "ca-central-1")

regressionCascadeRunId :: CleanupRunId
regressionCascadeRunId = mustRight (mkCleanupRunId "recovery-interpreter-cascade")

regressionExplicitPerRunRunId :: CleanupRunId
regressionExplicitPerRunRunId =
  mustRight (mkCleanupRunId "recovery-interpreter-explicit-per-run")

regressionMismatchRunId :: CleanupRunId
regressionMismatchRunId = mustRight (mkCleanupRunId "recovery-interpreter-mismatch")

completeObservationRows
  :: [RecoveryPlaneComponentIdentity]
  -> Bool
completeObservationRows rows =
  not (null rows)
    && all
      (\component -> length (filter (== component) rows) == 2)
      (nub rows)

isFailedOutcome :: CleanupNodeOutcome -> Bool
isFailedOutcome outcome = case outcome of
  CleanupNodeFailed _ -> True
  _ -> False

firstShow :: (Show err) => Either err value -> Either Text value
firstShow = first (Text.pack . show)

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value
