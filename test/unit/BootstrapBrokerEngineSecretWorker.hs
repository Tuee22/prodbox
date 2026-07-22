{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Focused composition tests for the crash-safe secret-worker driver.
module BootstrapBrokerEngineSecretWorker
  ( engineSecretWorkerSuite
  , main
  )
where

import Control.Monad (forM_)
import Data.Functor.Identity (Identity (..))
import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  )
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.EngineSecretWorker
import Prodbox.Bootstrap.Broker.Fence
import Prodbox.Bootstrap.Broker.Program (BootstrapMutationReceipt (..))
import Prodbox.Bootstrap.Broker.Request
  ( RequestDigest
  , mkRequestDigest
  )
import Prodbox.Bootstrap.Broker.SecretWorker
import Prodbox.Bootstrap.Broker.StoreBoundary
  ( StoreBoundaryError (..)
  , StoreReadBack (..)
  , StoreVersion (..)
  , StoreWriteResult (..)
  )
import Prodbox.Bootstrap.Broker.Types
  ( ArtifactDigest
  , VaultStorageGeneration
  , mkArtifactDigest
  , mkVaultStorageGeneration
  )
import Prodbox.ControlPlane.AuthorityClock
  ( AuthorityClockObservation (..)
  , clockUncertaintyFromMicros
  )
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , MonotonicInstant
  , deadlineFromInstant
  , monotonicInstantFromMicros
  )
import Prodbox.Lifecycle.Lease
  ( OwnerNonce
  , authorityTimeFromMicros
  , mkOwnerNonce
  )
import TestSupport

main :: IO ()
main = mainWithSuite "BootstrapBrokerEngineSecretWorker" engineSecretWorkerSuite

engineSecretWorkerSuite :: SuiteBuilder ()
engineSecretWorkerSuite =
  describe "Sprint 2.33 secret-worker engine composition" $ do
    it "runs every operation through receipt, revoke, zero exit, delete, and absence" $
      forM_ driverTestOperations $ \operation -> do
        let request = workerRequest "success" 'a' operation canonicalFence
        harness <- newHarness NoFault [request] Nothing healthyTimes
        result <-
          drive
            harness
            SecretWorkerControllerRestarted
            operation
            canonicalFence
            (vaultPermitFor canonicalFence operation)
            (successfulRunner harness request)
            (unexpectedRecovery harness)
        case result of
          Left failure -> expectationFailure (show failure)
          Right (receipt, outcome) -> do
            secretWorkerReceiptOutcome receipt `shouldBe` outcomeFor operation
            outcome `shouldBe` "executed"
            assertCompletedCheckpoint harness request receipt
        events <- harnessEvents harness
        lifecycleEvents events
          `shouldBe` [WorkerRan, SessionRevoked, ProcessExited, PodDeleted, PodAbsent]
        checkpointWrites events `shouldBe` 6
        countEvent WorkerRecovered events `shouldBe` 0

    it "resumes exactly the next action from every receipt checkpoint" $ do
      let request = workerRequest "resume" 'b' SecretWorkerInitialize canonicalFence
          (receipt, stages) = checkpointStages request canonicalFence
      forM_ stages $ \(checkpoint, expectedLifecycle) -> do
        harness <-
          newHarness
            NoFault
            []
            (Just (StoreVersion 7, checkpointDigest, checkpoint))
            healthyTimes
        result <-
          drive
            harness
            SecretWorkerControllerRestarted
            SecretWorkerInitialize
            canonicalFence
            (vaultPermitFor canonicalFence SecretWorkerInitialize)
            (unexpectedRunner harness)
            (successfulRecovery harness)
        result `shouldBe` Right (receipt, "recovered")
        events <- harnessEvents harness
        lifecycleEvents events `shouldBe` (expectedLifecycle ++ [WorkerRecovered])
        countEvent WorkerAllocated events `shouldBe` 0
        countEvent WorkerRan events `shouldBe` 0
        assertCompletedCheckpoint harness request receipt

    it "recovers durable results in a recreated driver after both worker CAS loss windows" $
      forM_ driverTestOperations $ \operation ->
        forM_
          [LoseReceiptCheckpointResponse, LoseAbsentCheckpointResponse]
          $ \fault -> do
            let request =
                  workerRequest
                    ("recreated-" <> Text.pack (show operation))
                    '9'
                    operation
                    canonicalFence
            harness <- newHarness fault [request] Nothing healthyTimes
            first <-
              drive
                harness
                SecretWorkerControllerRestarted
                operation
                canonicalFence
                (vaultPermitFor canonicalFence operation)
                (successfulRunner harness request)
                (unexpectedRecovery harness)
            first
              `shouldBe` Left
                (EngineSecretWorkerStoreRefused BootstrapStoreUnavailable)
            second <-
              drive
                harness
                SecretWorkerControllerRestarted
                operation
                canonicalFence
                (vaultPermitFor canonicalFence operation)
                (unexpectedRunner harness)
                (successfulRecovery harness)
            case second of
              Left failure -> expectationFailure (show failure)
              Right (receipt, recovered) -> do
                recovered `shouldBe` "recovered"
                assertCompletedCheckpoint harness request receipt
            events <- harnessEvents harness
            countEvent WorkerRan events `shouldBe` 1
            countEvent WorkerRecovered events `shouldBe` 1

    it "refuses an authoritative result with a wrong constructor or stale binding" $ do
      let request =
            workerRequest
              "authoritative-mismatch"
              '9'
              SecretWorkerUnseal
              canonicalFence
          (_, stages) = checkpointStages request canonicalFence
          completed = fst (last stages)
          staleReceipt =
            BootstrapMutationReceipt
              { bootstrapMutationDigest = successorAction
              , bootstrapMutationChanged = True
              }
      harness <-
        newHarness
          NoFault
          []
          (Just (StoreVersion 7, checkpointDigest, completed))
          healthyTimes
      wrongConstructor <-
        reconcileAuthoritativeSecretWorkerResult
          (boundaryFor harness)
          SecretWorkerControllerRestarted
          SecretWorkerUnseal
          canonicalFence
          (transitRotationWorkerResult staleReceipt)
      wrongConstructor
        `shouldBe` Left EngineSecretWorkerAuthoritativeResultMismatch
      staleBinding <-
        reconcileAuthoritativeSecretWorkerResult
          (boundaryFor harness)
          SecretWorkerControllerRestarted
          SecretWorkerUnseal
          canonicalFence
          (unsealWorkerResult staleReceipt)
      staleBinding
        `shouldBe` Left EngineSecretWorkerAuthoritativeResultMismatch
      events <- harnessEvents harness
      countEvent WorkerRan events `shouldBe` 0
      lifecycleEvents events `shouldBe` []

    it "reads the fixed checkpoint first and recovers a lost pre-receipt Pod with a fresh identity" $ do
      let lost = workerRequest "lost" 'c' SecretWorkerInitialize canonicalFence
          replacement =
            workerRequest "replacement" 'd' SecretWorkerInitialize canonicalFence
      harness <-
        newHarness
          NoFault
          [replacement]
          ( Just
              ( StoreVersion 11
              , checkpointDigest
              , noSecretWorkerReceipt lost
              )
          )
          healthyTimes
      result <-
        drive
          harness
          SecretWorkerPodLost
          SecretWorkerInitialize
          canonicalFence
          (vaultPermitFor canonicalFence SecretWorkerInitialize)
          (successfulRunner harness replacement)
          (unexpectedRecovery harness)
      case result of
        Left failure -> expectationFailure (show failure)
        Right (receipt, "executed") ->
          assertCompletedCheckpoint harness replacement receipt
        Right success -> expectationFailure ("unexpected result: " ++ show success)
      events <- harnessEvents harness
      take 3 (withoutReads events)
        `shouldBe` [WorkerDiscarded, WorkerAllocated, PermitRequested BootstrapStoreCasSecretWorkerCheckpoint]
      countEvent WorkerAllocated events `shouldBe` 1
      countEvent WorkerDiscarded events `shouldBe` 1
      countEvent WorkerRan events `shouldBe` 1

    it "rolls an absent predecessor to a differently bound next operation" $ do
      let firstRequest =
            workerRequest "first" 'e' SecretWorkerInitialize canonicalFence
          secondRequest =
            workerRequest "second" 'f' SecretWorkerUnseal successorFence
      harness <-
        newHarness
          NoFault
          [firstRequest, secondRequest]
          Nothing
          healthyTimes
      first <-
        drive
          harness
          SecretWorkerControllerRestarted
          SecretWorkerInitialize
          canonicalFence
          (vaultPermitFor canonicalFence SecretWorkerInitialize)
          (successfulRunner harness firstRequest)
          (unexpectedRecovery harness)
      first `shouldSatisfy` isSuccessful
      second <-
        drive
          harness
          SecretWorkerControllerRestarted
          SecretWorkerUnseal
          successorFence
          (vaultPermitFor successorFence SecretWorkerUnseal)
          (successfulRunner harness secondRequest)
          (unexpectedRecovery harness)
      case second of
        Left failure -> expectationFailure (show failure)
        Right (receipt, "executed") ->
          assertCompletedCheckpoint harness secondRequest receipt
        Right success -> expectationFailure ("unexpected result: " ++ show success)
      events <- harnessEvents harness
      countEvent WorkerAllocated events `shouldBe` 2
      countEvent WorkerRan events `shouldBe` 2
      countEvent WorkerRecovered events `shouldBe` 0

    it "fails closed on every incomplete operation/fence/action/request/storage/deadline mismatch" $ do
      let storedRequest =
            workerRequest "bound" '1' SecretWorkerInitialize canonicalFence
          cases
            :: [(String, SecretWorkerOperation, BootstrapSessionFence)]
          cases =
            [ ("operation", SecretWorkerUnseal, canonicalFence)
            , ("generation", SecretWorkerInitialize, generationFence)
            , ("owner", SecretWorkerInitialize, ownerFence)
            , ("action", SecretWorkerInitialize, actionFence)
            , ("request", SecretWorkerInitialize, requestFence)
            , ("storage", SecretWorkerInitialize, storageFence)
            , ("deadline", SecretWorkerInitialize, deadlineFence)
            ]
      forM_ cases $ \(label, operation, suppliedFence) -> do
        harness <-
          newHarness
            NoFault
            []
            ( Just
                ( StoreVersion 4
                , checkpointDigest
                , noSecretWorkerReceipt storedRequest
                )
            )
            healthyTimes
        result <-
          drive
            harness
            SecretWorkerControllerRestarted
            operation
            suppliedFence
            (vaultPermitFor suppliedFence operation)
            (unexpectedRunner harness)
            (unexpectedRecovery harness)
        (label, result)
          `shouldBe` (label, Left EngineSecretWorkerStoredRequestBindingMismatch)
        events <- harnessEvents harness
        withoutReads events `shouldBe` []

    it "destroys and refuses every non-repromptable pre-receipt interruption"
      $ forM_
        [ SecretWorkerAttestationInvalidated
        , SecretWorkerFenceLost
        , SecretWorkerDeadlineElapsed
        ]
      $ \interruption -> do
        let request =
              workerRequest "refuse" '2' SecretWorkerInitialize canonicalFence
        harness <-
          newHarness
            NoFault
            []
            ( Just
                ( StoreVersion 2
                , checkpointDigest
                , noSecretWorkerReceipt request
                )
            )
            healthyTimes
        result <-
          drive
            harness
            interruption
            SecretWorkerInitialize
            canonicalFence
            (vaultPermitFor canonicalFence SecretWorkerInitialize)
            (unexpectedRunner harness)
            (unexpectedRecovery harness)
        result
          `shouldBe` Left
            (EngineSecretWorkerRecoveryDestroyedAndRefused interruption)
        events <- harnessEvents harness
        withoutReads events `shouldBe` [WorkerDiscarded]

    it "refuses unobservable checkpoints and exact-attestation failures" $ do
      checkpointHarness <-
        newHarness
          NoFault
          []
          ( Just
              ( StoreVersion 3
              , checkpointDigest
              , unobservableWorkerCheckpoint "store observation lost"
              )
          )
          healthyTimes
      checkpointResult <-
        drive
          checkpointHarness
          SecretWorkerControllerRestarted
          SecretWorkerInitialize
          canonicalFence
          (vaultPermitFor canonicalFence SecretWorkerInitialize)
          (unexpectedRunner checkpointHarness)
          (unexpectedRecovery checkpointHarness)
      checkpointResult
        `shouldBe` Left
          ( EngineSecretWorkerRecoveryRefused
              (SecretWorkerRecoveryCheckpointUnobservable "store observation lost")
          )

      forM_ [AttestationUnobservable, AttestationMismatched] $ \fault -> do
        let request =
              workerRequest "attestation" '3' SecretWorkerInitialize canonicalFence
        harness <- newHarness fault [request] Nothing healthyTimes
        result <-
          drive
            harness
            SecretWorkerControllerRestarted
            SecretWorkerInitialize
            canonicalFence
            (vaultPermitFor canonicalFence SecretWorkerInitialize)
            (unexpectedRunner harness)
            (unexpectedRecovery harness)
        result `shouldSatisfy` isAttestationRefusal
        events <- harnessEvents harness
        countEvent WorkerDiscarded events `shouldBe` 1
        countEvent WorkerRan events `shouldBe` 0

    it "rejects wrong-effect, wrong-mutation, wrong-fence, and unavailable-store authority" $ do
      let request = workerRequest "authority" '4' SecretWorkerInitialize canonicalFence
          cases =
            [
              ( NoFault
              , vaultPermitFor canonicalFence SecretWorkerUnseal
              , isEffectRefusal
              )
            , (WrongMutationPermit, vaultPermitFor canonicalFence SecretWorkerInitialize, isPermitRefusal)
            , (WrongFencePermit, vaultPermitFor canonicalFence SecretWorkerInitialize, isPermitRefusal)
            ]
      forM_ cases $ \(fault, vaultPermit, expectedRefusal) -> do
        harness <- newHarness fault [request] Nothing healthyTimes
        result <-
          drive
            harness
            SecretWorkerControllerRestarted
            SecretWorkerInitialize
            canonicalFence
            vaultPermit
            (unexpectedRunner harness)
            (unexpectedRecovery harness)
        result `shouldSatisfy` expectedRefusal
        events <- harnessEvents harness
        countEvent WorkerRan events `shouldBe` 0

      unavailable <- newHarness StoreUnavailable [request] Nothing healthyTimes
      unavailableResult <-
        drive
          unavailable
          SecretWorkerControllerRestarted
          SecretWorkerInitialize
          canonicalFence
          (vaultPermitFor canonicalFence SecretWorkerInitialize)
          (unexpectedRunner unavailable)
          (unexpectedRecovery unavailable)
      unavailableResult
        `shouldBe` Left (EngineSecretWorkerStoreRefused BootstrapStoreUnavailable)

    it "samples time after attestation and refuses an elapsed effect before ingress" $ do
      let request = workerRequest "late-effect" '5' SecretWorkerInitialize canonicalFence
      harness <-
        newHarness
          NoFault
          [request]
          Nothing
          [freshNow, deadlineNow]
      result <-
        drive
          harness
          SecretWorkerControllerRestarted
          SecretWorkerInitialize
          canonicalFence
          (vaultPermitFor canonicalFence SecretWorkerInitialize)
          (unexpectedRunner harness)
          (unexpectedRecovery harness)
      result
        `shouldBe` Left
          (EngineSecretWorkerEffectRefused SecretWorkerEffectDeadlineElapsed)
      events <- harnessEvents harness
      countEvent WorkerRan events `shouldBe` 0
      countEvent WorkerDiscarded events `shouldBe` 1
      checkpointWrites events `shouldBe` 1

    it "refuses a fence clock crossing before transfer with effect count zero" $ do
      let request =
            workerRequest
              "late-fence-refresh"
              '9'
              SecretWorkerInitialize
              canonicalFence
          refreshedPermit =
            case authorizeBootstrapVaultEffect
              deadlineNow
              requestDeadline
              trustedNow
              canonicalFence
              (BootstrapFenceStoreHeld canonicalFence)
              (leaseFor canonicalFence)
              BootstrapVaultInitialize of
              Left _ -> Left PermitCouldNotBeMinted
              Right permit -> Right permit
      harness <- newHarness NoFault [request] Nothing healthyTimes
      result <-
        driveSecretWorker
          (boundaryFor harness)
          SecretWorkerControllerRestarted
          SecretWorkerInitialize
          canonicalFence
          (pure refreshedPermit)
          (unexpectedRunner harness)
          (const (Right ambiguousInitializationWorkerResult))
          (\_receipt _result -> pure (Left UnexpectedReceiptRecovery))
      result
        `shouldBe` Left
          (EngineSecretWorkerBoundaryRefused PermitCouldNotBeMinted)
      events <- harnessEvents harness
      countEvent WorkerRan events `shouldBe` 0
      countEvent WorkerDiscarded events `shouldBe` 1
      checkpointWrites events `shouldBe` 1

    it "rechecks time for cleanup CAS and stops before the next physical mutation" $ do
      let request = workerRequest "late-cleanup" '6' SecretWorkerInitialize canonicalFence
      harness <-
        newHarness
          NoFault
          [request]
          Nothing
          [freshNow, freshNow, freshNow, deadlineNow]
      result <-
        drive
          harness
          SecretWorkerControllerRestarted
          SecretWorkerInitialize
          canonicalFence
          (vaultPermitFor canonicalFence SecretWorkerInitialize)
          (successfulRunner harness request)
          (unexpectedRecovery harness)
      result `shouldBe` Left EngineSecretWorkerCheckpointPermitDeadlineElapsed
      events <- harnessEvents harness
      lifecycleEvents events `shouldBe` [WorkerRan, SessionRevoked]
      countEvent CheckpointCased events `shouldBe` 1

    it "never reports completion until authoritative absence is checkpointed and read back" $ do
      let request = workerRequest "absence" '7' SecretWorkerInitialize canonicalFence
      harness <-
        newHarness
          (CleanupUnobservable AtAbsence)
          [request]
          Nothing
          healthyTimes
      result <-
        drive
          harness
          SecretWorkerControllerRestarted
          SecretWorkerInitialize
          canonicalFence
          (vaultPermitFor canonicalFence SecretWorkerInitialize)
          (successfulRunner harness request)
          (unexpectedRecovery harness)
      result `shouldSatisfy` isCleanupRefusal
      events <- harnessEvents harness
      lifecycleEvents events
        `shouldBe` [WorkerRan, SessionRevoked, ProcessExited, PodDeleted, PodAbsent]
      countEvent WorkerRecovered events `shouldBe` 0
      stored <- currentCheckpoint harness
      case stored of
        Nothing -> expectationFailure "expected durable WorkerDeleted checkpoint"
        Just (_, _, checkpoint) ->
          decideSecretWorkerRecovery
            request
            SecretWorkerControllerRestarted
            checkpoint
            `shouldSatisfy` isObserveAbsence

    it "refuses cleanup mismatch, non-zero exit, and unobservable lifecycle evidence" $ do
      let request = workerRequest "cleanup" '8' SecretWorkerInitialize canonicalFence
          faults =
            [ CleanupMismatched AtRevoke
            , CleanupNonZeroExit
            , CleanupUnobservable AtDelete
            ]
      forM_ faults $ \fault -> do
        harness <- newHarness fault [request] Nothing healthyTimes
        result <-
          drive
            harness
            SecretWorkerControllerRestarted
            SecretWorkerInitialize
            canonicalFence
            (vaultPermitFor canonicalFence SecretWorkerInitialize)
            (successfulRunner harness request)
            (unexpectedRecovery harness)
        result `shouldSatisfy` isCleanupRefusal

data TestBoundaryError
  = NoAllocatedRequest
  | UnexpectedWorkerRun
  | UnexpectedReceiptRecovery
  | PermitCouldNotBeMinted
  deriving (Eq, Show)

data CleanupPoint
  = AtRevoke
  | AtExit
  | AtDelete
  | AtAbsence
  deriving (Eq, Show)

data Fault
  = NoFault
  | LoseReceiptCheckpointResponse
  | LoseAbsentCheckpointResponse
  | AttestationUnobservable
  | AttestationMismatched
  | CleanupUnobservable !CleanupPoint
  | CleanupMismatched !CleanupPoint
  | CleanupNonZeroExit
  | WrongMutationPermit
  | WrongFencePermit
  | StoreUnavailable
  deriving (Eq, Show)

data Event
  = CheckpointRead
  | WorkerAllocated
  | WorkloadCreated
  | AttestationObserved
  | ClockObserved
  | PermitRequested !BootstrapStoreMutation
  | CheckpointCreated
  | CheckpointCased
  | WorkerRan
  | WorkerRecovered
  | WorkerDiscarded
  | SessionRevoked
  | ProcessExited
  | PodDeleted
  | PodAbsent
  deriving (Eq, Show)

data HarnessState = HarnessState
  { stateRequests :: ![SecretFreeWorkerRequest]
  , stateCheckpoint
      :: !( Maybe
              (StoreVersion, ArtifactDigest, SecretWorkerDurableCheckpoint)
          )
  , stateEvents :: ![Event]
  , stateFault :: !Fault
  , stateTimes :: ![MonotonicInstant]
  }

type Harness = IORef HarnessState

newHarness
  :: Fault
  -> [SecretFreeWorkerRequest]
  -> Maybe (StoreVersion, ArtifactDigest, SecretWorkerDurableCheckpoint)
  -> [MonotonicInstant]
  -> IO Harness
newHarness fault requests checkpoint times =
  newIORef
    HarnessState
      { stateRequests = requests
      , stateCheckpoint = checkpoint
      , stateEvents = []
      , stateFault = fault
      , stateTimes = times
      }

drive
  :: Harness
  -> SecretWorkerInterruption
  -> SecretWorkerOperation
  -> BootstrapSessionFence
  -> BootstrapVaultEffectPermit
  -> ( forall scope
        . BootstrapVaultEffectPermit
       -> SecretWorkerEffectPermit
       -> RunningSecretWorker scope
       %1 -> IO
               ( Either
                   TestBoundaryError
                   (ExecutedSecretWorker, RawSecretWorkerReceipt, String)
               )
     )
  -> (SecretWorkerReceipt -> IO (Either TestBoundaryError String))
  -> IO
       ( Either
           (EngineSecretWorkerError TestBoundaryError)
           (SecretWorkerReceipt, String)
       )
drive harness interruption operation fence permit runOperation recoverResult =
  driveSecretWorker
    (boundaryFor harness)
    interruption
    operation
    fence
    (pure (Right permit))
    runOperation
    (const (Right (durableResultFor operation)))
    ( \receipt durableResult ->
        if secretWorkerDurableResultOperation durableResult == operation
          then recoverResult receipt
          else pure (Left UnexpectedReceiptRecovery)
    )

boundaryFor
  :: Harness -> EngineSecretWorkerBoundary IO TestBoundaryError
boundaryFor harness =
  EngineSecretWorkerBoundary
    { observeSecretWorkerMonotonicNow = do
        recordEvent harness ClockObserved
        Right <$> takeTime harness
    , allocateSecretWorkerRequest = \_operation _fence -> do
        recordEvent harness WorkerAllocated
        takeRequest harness
    , createSecretWorkerWorkload = \_request -> do
        recordEvent harness WorkloadCreated
        pure (Right ())
    , observeSecretWorkerAttestation = \request -> do
        recordEvent harness AttestationObserved
        fault <- stateFault <$> readIORef harness
        pure . Right $ case fault of
          AttestationUnobservable ->
            SecretWorkerAttestationUnobservable "Pod API unavailable"
          AttestationMismatched ->
            SecretWorkerAttestationObserved
              ( (attestationFor request)
                  { rawWorkerOperation = differentOperation request
                  }
              )
          _ -> SecretWorkerAttestationObserved (attestationFor request)
    , discardUnreceiptedSecretWorker = \_request _interruption -> do
        recordEvent harness WorkerDiscarded
        pure (Right ())
    , withSecretWorkerCheckpointPermit = \fence mutation use -> do
        recordEvent harness (PermitRequested mutation)
        now <- takeTime harness
        fault <- stateFault <$> readIORef harness
        let permitFence = case fault of
              WrongFencePermit -> ownerFence
              _ -> fence
            permitMutation = case fault of
              WrongMutationPermit -> differentMutation mutation
              _ -> mutation
        case storePermitFor permitFence permitMutation of
          Left _ -> pure (Left PermitCouldNotBeMinted)
          Right permit -> Right <$> use now permit
    , readSecretWorkerCheckpoint = do
        recordEvent harness CheckpointRead
        state <- readIORef harness
        pure $ case stateFault state of
          StoreUnavailable -> Left BootstrapStoreUnavailable
          _ -> Right (checkpointReadBack (stateCheckpoint state))
    , createSecretWorkerCheckpoint = \_permit checkpoint -> do
        recordEvent harness CheckpointCreated
        applyCreate harness checkpoint
    , casSecretWorkerCheckpoint = \_permit expectedVersion checkpoint -> do
        recordEvent harness CheckpointCased
        applyCas harness expectedVersion checkpoint
    , revokeSecretWorkerSession =
        lifecycleObservation harness AtRevoke SecretWorkerSessionRevoked
    , observeSecretWorkerExit =
        lifecycleObservation
          harness
          AtExit
          (\binding -> SecretWorkerProcessExited binding 0)
    , deleteSecretWorkerPod =
        lifecycleObservation harness AtDelete SecretWorkerPodDeleted
    , observeSecretWorkerAbsence =
        lifecycleObservation harness AtAbsence SecretWorkerPodAbsent
    }

lifecycleObservation
  :: Harness
  -> CleanupPoint
  -> (SecretWorkerCleanupBinding -> SecretWorkerLifecycleObservation)
  -> SecretWorkerCleanupBinding
  -> IO (Either TestBoundaryError SecretWorkerLifecycleObservation)
lifecycleObservation harness point exactObservation binding = do
  recordEvent harness (cleanupEvent point)
  fault <- stateFault <$> readIORef harness
  pure . Right $ case fault of
    CleanupUnobservable failedPoint
      | failedPoint == point ->
          SecretWorkerLifecycleUnobservable "lifecycle API unavailable"
    CleanupMismatched failedPoint
      | failedPoint == point ->
          exactObservation
            binding {cleanupWorkerPodUid = alternatePodUid}
    CleanupNonZeroExit
      | point == AtExit -> SecretWorkerProcessExited binding 17
    _ -> exactObservation binding

cleanupEvent :: CleanupPoint -> Event
cleanupEvent point = case point of
  AtRevoke -> SessionRevoked
  AtExit -> ProcessExited
  AtDelete -> PodDeleted
  AtAbsence -> PodAbsent

differentMutation :: BootstrapStoreMutation -> BootstrapStoreMutation
differentMutation mutation = case mutation of
  BootstrapStoreCreateSecretWorkerCheckpoint ->
    BootstrapStoreCasSecretWorkerCheckpoint
  _ -> BootstrapStoreCreateSecretWorkerCheckpoint

applyCreate
  :: Harness
  -> SecretWorkerDurableCheckpoint
  -> IO
       ( Either
           StoreBoundaryError
           (StoreWriteResult SecretWorkerDurableCheckpoint)
       )
applyCreate harness checkpoint = do
  state <- readIORef harness
  case stateCheckpoint state of
    Nothing -> do
      let version = StoreVersion 1
      setCheckpoint harness (Just (version, checkpointDigest, checkpoint))
      pure (Right (StoreWriteApplied version checkpointDigest checkpoint))
    Just existing ->
      pure (Right (StoreWriteConflict (checkpointReadBack (Just existing))))

applyCas
  :: Harness
  -> StoreVersion
  -> SecretWorkerDurableCheckpoint
  -> IO
       ( Either
           StoreBoundaryError
           (StoreWriteResult SecretWorkerDurableCheckpoint)
       )
applyCas harness expectedVersion checkpoint = do
  state <- readIORef harness
  case stateCheckpoint state of
    Just (currentVersion, _, _)
      | currentVersion == expectedVersion -> do
          let version = nextVersion currentVersion
          setCheckpoint harness (Just (version, checkpointDigest, checkpoint))
          loseResponse <- shouldLoseCheckpointResponse harness checkpoint
          if loseResponse
            then pure (Left BootstrapStoreUnavailable)
            else
              pure
                (Right (StoreWriteApplied version checkpointDigest checkpoint))
    existing ->
      pure (Right (StoreWriteConflict (checkpointReadBack existing)))

shouldLoseCheckpointResponse
  :: Harness -> SecretWorkerDurableCheckpoint -> IO Bool
shouldLoseCheckpointResponse harness checkpoint = do
  state <- readIORef harness
  let decision = do
        request <- either (const Nothing) Just (secretWorkerCheckpointRequest checkpoint)
        pure
          ( decideSecretWorkerRecovery
              request
              SecretWorkerControllerRestarted
              checkpoint
          )
      shouldLose = case (stateFault state, decision) of
        (LoseReceiptCheckpointResponse, Just SecretWorkerRecoveryRevokeSession {}) -> True
        (LoseAbsentCheckpointResponse, Just SecretWorkerRecoveryComplete {}) -> True
        _ -> False
  if shouldLose
    then do
      modifyIORef' harness $ \current -> current {stateFault = NoFault}
      pure True
    else pure False

checkpointReadBack
  :: Maybe (StoreVersion, ArtifactDigest, value) -> StoreReadBack value
checkpointReadBack checkpoint = case checkpoint of
  Nothing -> StoreObjectAbsent
  Just (version, digest, value) -> StoreObjectPresent version digest value

nextVersion :: StoreVersion -> StoreVersion
nextVersion (StoreVersion version) = StoreVersion (version + 1)

setCheckpoint
  :: Harness
  -> Maybe (StoreVersion, ArtifactDigest, SecretWorkerDurableCheckpoint)
  -> IO ()
setCheckpoint harness checkpoint =
  modifyIORef' harness $ \state -> state {stateCheckpoint = checkpoint}

currentCheckpoint
  :: Harness
  -> IO
       ( Maybe
           (StoreVersion, ArtifactDigest, SecretWorkerDurableCheckpoint)
       )
currentCheckpoint harness = stateCheckpoint <$> readIORef harness

recordEvent :: Harness -> Event -> IO ()
recordEvent harness event =
  modifyIORef' harness $ \state ->
    state {stateEvents = stateEvents state ++ [event]}

harnessEvents :: Harness -> IO [Event]
harnessEvents harness = stateEvents <$> readIORef harness

takeRequest
  :: Harness -> IO (Either TestBoundaryError SecretFreeWorkerRequest)
takeRequest harness = do
  state <- readIORef harness
  case stateRequests state of
    [] -> pure (Left NoAllocatedRequest)
    request : remaining -> do
      modifyIORef' harness $ \current ->
        current {stateRequests = remaining}
      pure (Right request)

takeTime :: Harness -> IO MonotonicInstant
takeTime harness = do
  state <- readIORef harness
  case stateTimes state of
    [] -> pure freshNow
    now : remaining -> do
      modifyIORef' harness $ \current -> current {stateTimes = remaining}
      pure now

successfulRunner
  :: Harness
  -> SecretFreeWorkerRequest
  -> BootstrapVaultEffectPermit
  -> SecretWorkerEffectPermit
  -> RunningSecretWorker scope
  %1 -> IO
          ( Either
              TestBoundaryError
              (ExecutedSecretWorker, RawSecretWorkerReceipt, String)
          )
successfulRunner harness request _physicalPermit effectPermit running =
  finishSecretWorkerExecution
    effectPermit
    ( do
        recordEvent harness WorkerRan
        pure (Right (receiptFor request, "executed"))
    )
    running

unexpectedRunner
  :: Harness
  -> BootstrapVaultEffectPermit
  -> SecretWorkerEffectPermit
  -> RunningSecretWorker scope
  %1 -> IO
          ( Either
              TestBoundaryError
              (ExecutedSecretWorker, RawSecretWorkerReceipt, String)
          )
unexpectedRunner harness _physicalPermit effectPermit running =
  finishSecretWorkerExecution
    effectPermit
    ( do
        recordEvent harness WorkerRan
        pure (Left UnexpectedWorkerRun)
    )
    running

successfulRecovery
  :: Harness
  -> SecretWorkerReceipt
  -> IO (Either TestBoundaryError String)
successfulRecovery harness _receipt = do
  recordEvent harness WorkerRecovered
  pure (Right "recovered")

executedWorker
  :: SecretWorkerEffectPermit
  -> RawSecretWorkerReceipt
  -> ExecutedSecretWorker
executedWorker permit rawReceipt =
  case runIdentity
    ( executeAuthorizedSecretWorker
        permit
        (testTransfer permit rawReceipt)
    ) of
    Right (executed, _, ()) -> executed
    Left () -> error "impossible secret-worker test execution refusal"

testTransfer
  :: SecretWorkerEffectPermit
  -> RawSecretWorkerReceipt
  -> RunningSecretWorker scope
  %1 -> Identity
          ( Either
              ()
              (ExecutedSecretWorker, RawSecretWorkerReceipt, ())
          )
testTransfer permit rawReceipt running =
  finishSecretWorkerExecution
    permit
    (pure (Right (rawReceipt, ())))
    running

unexpectedRecovery
  :: Harness
  -> SecretWorkerReceipt
  -> IO (Either TestBoundaryError String)
unexpectedRecovery harness _receipt = do
  recordEvent harness WorkerRecovered
  pure (Left UnexpectedReceiptRecovery)

assertCompletedCheckpoint
  :: Harness -> SecretFreeWorkerRequest -> SecretWorkerReceipt -> Expectation
assertCompletedCheckpoint harness request receipt = do
  stored <- currentCheckpoint harness
  case stored of
    Nothing -> expectationFailure "expected a durable completion checkpoint"
    Just (_, _, checkpoint) ->
      decideSecretWorkerRecovery
        request
        SecretWorkerControllerRestarted
        checkpoint
        `shouldBe` SecretWorkerRecoveryComplete receipt

checkpointStages
  :: SecretFreeWorkerRequest
  -> BootstrapSessionFence
  -> ( SecretWorkerReceipt
     , [(SecretWorkerDurableCheckpoint, [Event])]
     )
checkpointStages request fence =
  let attested =
        mustRight
          ( attestSecretWorker
              request
              (SecretWorkerAttestationObserved (attestationFor request))
          )
      effectPermit =
        mustRight
          ( authorizeSecretWorkerEffect
              freshNow
              attested
              (vaultPermitFor fence (secretWorkerRequestOperation request))
          )
      rawReceipt = receiptFor request
      executed = executedWorker effectPermit rawReceipt
      captured =
        mustRight
          ( captureSecretWorkerReceipt
              executed
              rawReceipt
              (durableResultFor (secretWorkerRequestOperation request))
          )
      receipt = capturedSecretWorkerReceipt captured
      binding = secretWorkerCleanupBinding receipt
      capturedCheckpoint = receiptCapturedCheckpoint captured
      revokedCheckpoint =
        advance
          request
          capturedCheckpoint
          (SecretWorkerSessionRevoked binding)
      exitedCheckpoint =
        advance
          request
          revokedCheckpoint
          (SecretWorkerProcessExited binding 0)
      deletedCheckpoint =
        advance request exitedCheckpoint (SecretWorkerPodDeleted binding)
      absentCheckpoint =
        advance request deletedCheckpoint (SecretWorkerPodAbsent binding)
   in ( receipt
      ,
        [
          ( capturedCheckpoint
          , [SessionRevoked, ProcessExited, PodDeleted, PodAbsent]
          )
        , (revokedCheckpoint, [ProcessExited, PodDeleted, PodAbsent])
        , (exitedCheckpoint, [PodDeleted, PodAbsent])
        , (deletedCheckpoint, [PodAbsent])
        , (absentCheckpoint, [])
        ]
      )
 where
  advance expected checkpoint observation =
    mustRight
      ( advanceSecretWorkerCleanupCheckpoint
          expected
          checkpoint
          observation
      )

attestationFor :: SecretFreeWorkerRequest -> RawSecretWorkerAttestation
attestationFor request =
  RawSecretWorkerAttestation
    { rawWorkerPodUid = secretWorkerRequestPodUid request
    , rawWorkerImageDigest = secretWorkerRequestImageDigest request
    , rawWorkerServiceAccount = secretWorkerRequestServiceAccount request
    , rawWorkerSessionId = secretWorkerRequestSessionId request
    , rawWorkerSessionAccessor = secretWorkerRequestSessionAccessor request
    , rawWorkerOperation = secretWorkerRequestOperation request
    , rawWorkerFenceGeneration = secretWorkerRequestFenceGeneration request
    , rawWorkerOwnerNonce = secretWorkerRequestOwnerNonce request
    , rawWorkerActionDigest = secretWorkerRequestActionDigest request
    , rawWorkerRequestDigest = secretWorkerRequestDigest request
    , rawWorkerStorageGeneration = secretWorkerRequestStorageGeneration request
    , rawWorkerOperationDeadline = secretWorkerRequestOperationDeadline request
    }

differentOperation :: SecretFreeWorkerRequest -> SecretWorkerOperation
differentOperation request = case secretWorkerRequestOperation request of
  SecretWorkerInitialize -> SecretWorkerUnseal
  _ -> SecretWorkerInitialize

receiptFor :: SecretFreeWorkerRequest -> RawSecretWorkerReceipt
receiptFor request =
  RawSecretWorkerReceipt
    { rawWorkerReceiptOperation = secretWorkerRequestOperation request
    , rawWorkerReceiptPodUid = secretWorkerRequestPodUid request
    , rawWorkerReceiptSessionId = secretWorkerRequestSessionId request
    , rawWorkerReceiptSessionAccessor = secretWorkerRequestSessionAccessor request
    , rawWorkerReceiptRequestDigest = secretWorkerRequestDigest request
    , rawWorkerReceiptStorageGeneration = secretWorkerRequestStorageGeneration request
    , rawWorkerReceiptFenceGeneration = secretWorkerRequestFenceGeneration request
    , rawWorkerReceiptOutcome = outcomeFor (secretWorkerRequestOperation request)
    , rawWorkerReceiptDigest = receiptDigest
    }

workerRequest
  :: Text
  -> Char
  -> SecretWorkerOperation
  -> BootstrapSessionFence
  -> SecretFreeWorkerRequest
workerRequest suffix digestCharacter operation =
  mkSecretFreeWorkerRequest
    operation
    (mustRight (mkWorkerPodUid ("pod-uid-" <> suffix)))
    ( mustRight
        ( mkWorkerImageDigest
            ("sha256:" <> Text.replicate 64 (Text.singleton digestCharacter))
        )
    )
    (mustRight (mkWorkerServiceAccount ("bootstrap-worker-" <> suffix)))
    (mustRight (mkWorkerSessionId ("session-" <> suffix)))
    (mustRight (mkWorkerSessionAccessor ("accessor-" <> suffix)))

effectFor :: SecretWorkerOperation -> BootstrapVaultEffect
effectFor operation = case operation of
  SecretWorkerPrepareInitialization -> BootstrapVaultInitialize
  SecretWorkerResumeInitialization -> BootstrapVaultInitialize
  SecretWorkerInitialize -> BootstrapVaultInitialize
  SecretWorkerFinalizeInitialization -> BootstrapVaultInitialize
  SecretWorkerUnseal -> BootstrapVaultSubmitUnsealShare
  SecretWorkerRotateUnlockBundle -> BootstrapVaultRotateUnlockBundle
  SecretWorkerRotateTransitKey -> BootstrapVaultRotateTransitKey

outcomeFor :: SecretWorkerOperation -> SecretWorkerOutcome
outcomeFor operation = case operation of
  SecretWorkerPrepareInitialization -> SecretWorkerInitialized
  SecretWorkerResumeInitialization -> SecretWorkerInitialized
  SecretWorkerInitialize -> SecretWorkerInitialized
  SecretWorkerFinalizeInitialization -> SecretWorkerInitialized
  SecretWorkerUnseal -> SecretWorkerUnsealed
  SecretWorkerRotateUnlockBundle -> SecretWorkerUnlockBundleRotated
  SecretWorkerRotateTransitKey -> SecretWorkerTransitKeyRotated

driverTestOperations :: [SecretWorkerOperation]
driverTestOperations =
  [ SecretWorkerInitialize
  , SecretWorkerUnseal
  , SecretWorkerRotateUnlockBundle
  , SecretWorkerRotateTransitKey
  ]

durableResultFor :: SecretWorkerOperation -> SecretWorkerDurableResult
durableResultFor operation = case operation of
  SecretWorkerInitialize -> ambiguousInitializationWorkerResult
  SecretWorkerUnseal -> unsealWorkerResult mutationReceipt
  SecretWorkerRotateUnlockBundle -> unlockRotationWorkerResult mutationReceipt
  SecretWorkerRotateTransitKey -> transitRotationWorkerResult mutationReceipt
  _ -> error "test durable result requires an operation-specific encrypted fixture"
 where
  mutationReceipt =
    BootstrapMutationReceipt
      { bootstrapMutationDigest = canonicalAction
      , bootstrapMutationChanged = True
      }

vaultPermitFor
  :: BootstrapSessionFence
  -> SecretWorkerOperation
  -> BootstrapVaultEffectPermit
vaultPermitFor fence operation =
  mustRight
    ( authorizeBootstrapVaultEffect
        freshNow
        requestDeadline
        trustedNow
        fence
        (BootstrapFenceStoreHeld fence)
        (leaseFor fence)
        (effectFor operation)
    )

storePermitFor
  :: BootstrapSessionFence
  -> BootstrapStoreMutation
  -> Either BootstrapFenceUseRefusal BootstrapStoreMutationPermit
storePermitFor fence mutation =
  authorizeBootstrapStoreMutation
    freshNow
    requestDeadline
    trustedNow
    fence
    (BootstrapFenceStoreHeld fence)
    (leaseFor fence)
    mutation

leaseFor :: BootstrapSessionFence -> BootstrapLeaseObservation
leaseFor fence =
  BootstrapLeaseObserved
    (bootstrapLeaseBindingForFence fence)
    permitDeadline
    "resource-version-1"

canonicalFence :: BootstrapSessionFence
canonicalFence =
  fenceAt
    1
    canonicalOwner
    canonicalAction
    canonicalRequestDigest
    canonicalStorage
    1_000

successorFence :: BootstrapSessionFence
successorFence =
  fenceAt
    2
    canonicalOwner
    successorAction
    successorRequestDigest
    canonicalStorage
    1_200

generationFence :: BootstrapSessionFence
generationFence =
  fenceAt
    2
    canonicalOwner
    canonicalAction
    canonicalRequestDigest
    canonicalStorage
    1_000

ownerFence :: BootstrapSessionFence
ownerFence =
  fenceAt
    1
    alternateOwner
    canonicalAction
    canonicalRequestDigest
    canonicalStorage
    1_000

actionFence :: BootstrapSessionFence
actionFence =
  fenceAt
    1
    canonicalOwner
    successorAction
    canonicalRequestDigest
    canonicalStorage
    1_000

requestFence :: BootstrapSessionFence
requestFence =
  fenceAt
    1
    canonicalOwner
    canonicalAction
    successorRequestDigest
    canonicalStorage
    1_000

storageFence :: BootstrapSessionFence
storageFence =
  fenceAt
    1
    canonicalOwner
    canonicalAction
    canonicalRequestDigest
    alternateStorage
    1_000

deadlineFence :: BootstrapSessionFence
deadlineFence =
  fenceAt
    1
    canonicalOwner
    canonicalAction
    canonicalRequestDigest
    canonicalStorage
    1_100

fenceAt
  :: Natural
  -> OwnerNonce
  -> ArtifactDigest
  -> RequestDigest
  -> VaultStorageGeneration
  -> Natural
  -> BootstrapSessionFence
fenceAt fenceGeneration owner action request storage operationDeadline =
  mustRight
    ( reloadBootstrapSessionFence
        fenceGeneration
        owner
        action
        request
        storage
        operationDeadline
    )

canonicalOwner :: OwnerNonce
canonicalOwner = mustRight (mkOwnerNonce "owner-a")

alternateOwner :: OwnerNonce
alternateOwner = mustRight (mkOwnerNonce "owner-b")

canonicalAction :: ArtifactDigest
canonicalAction = digestOf 'a'

successorAction :: ArtifactDigest
successorAction = digestOf 'b'

checkpointDigest :: ArtifactDigest
checkpointDigest = digestOf 'c'

receiptDigest :: ArtifactDigest
receiptDigest = digestOf 'd'

canonicalRequestDigest :: RequestDigest
canonicalRequestDigest = requestDigestOf 'e'

successorRequestDigest :: RequestDigest
successorRequestDigest = requestDigestOf 'f'

canonicalStorage :: VaultStorageGeneration
canonicalStorage = mustRight (mkVaultStorageGeneration "vault-pv-a")

alternateStorage :: VaultStorageGeneration
alternateStorage = mustRight (mkVaultStorageGeneration "vault-pv-b")

alternatePodUid :: WorkerPodUid
alternatePodUid = mustRight (mkWorkerPodUid "pod-uid-mismatch")

requestDeadline :: Deadline
requestDeadline = deadline 5_000

permitDeadline :: Deadline
permitDeadline = deadline 800

freshNow :: MonotonicInstant
freshNow = monotonicInstantFromMicros 10

deadlineNow :: MonotonicInstant
deadlineNow = monotonicInstantFromMicros 800

healthyTimes :: [MonotonicInstant]
healthyTimes = repeat freshNow

trustedNow :: AuthorityClockObservation
trustedNow =
  AuthorityTimeTrusted
    (authorityTimeFromMicros 100)
    (clockUncertaintyFromMicros 0)

deadline :: Natural -> Deadline
deadline = deadlineFromInstant . monotonicInstantFromMicros

digestOf :: Char -> ArtifactDigest
digestOf character =
  mustRight (mkArtifactDigest (Text.replicate 64 (Text.singleton character)))

requestDigestOf :: Char -> RequestDigest
requestDigestOf character =
  mustRight (mkRequestDigest (Text.replicate 64 (Text.singleton character)))

withoutReads :: [Event] -> [Event]
withoutReads = filter (/= CheckpointRead)

lifecycleEvents :: [Event] -> [Event]
lifecycleEvents =
  filter
    ( \event ->
        event
          `elem` [ WorkerRan
                 , WorkerRecovered
                 , SessionRevoked
                 , ProcessExited
                 , PodDeleted
                 , PodAbsent
                 ]
    )

checkpointWrites :: [Event] -> Int
checkpointWrites events =
  countEvent CheckpointCreated events + countEvent CheckpointCased events

countEvent :: Event -> [Event] -> Int
countEvent expected = length . filter (== expected)

isSuccessful
  :: Either (EngineSecretWorkerError TestBoundaryError) value -> Bool
isSuccessful result = case result of
  Right _ -> True
  Left _ -> False

isAttestationRefusal
  :: Either (EngineSecretWorkerError TestBoundaryError) value -> Bool
isAttestationRefusal result = case result of
  Left (EngineSecretWorkerAttestationRefused _) -> True
  _ -> False

isEffectRefusal
  :: Either (EngineSecretWorkerError TestBoundaryError) value -> Bool
isEffectRefusal result = case result of
  Left (EngineSecretWorkerEffectRefused _) -> True
  _ -> False

isPermitRefusal
  :: Either (EngineSecretWorkerError TestBoundaryError) value -> Bool
isPermitRefusal result = case result of
  Left EngineSecretWorkerCheckpointPermitFenceMismatch -> True
  Left (EngineSecretWorkerCheckpointPermitMutationMismatch _ _) -> True
  _ -> False

isCleanupRefusal
  :: Either (EngineSecretWorkerError TestBoundaryError) value -> Bool
isCleanupRefusal result = case result of
  Left (EngineSecretWorkerCleanupRefused _) -> True
  _ -> False

isObserveAbsence :: SecretWorkerRecoveryDecision -> Bool
isObserveAbsence decision = case decision of
  SecretWorkerRecoveryObserveAbsence _ -> True
  _ -> False

mustRight :: (Show error) => Either error value -> value
mustRight = either (error . show) id
