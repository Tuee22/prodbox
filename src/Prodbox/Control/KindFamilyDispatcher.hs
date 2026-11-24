{-# LANGUAGE ImportQualifiedPost #-}

-- | Composition for the kind operation-family controller. This internal
-- dispatcher is not a launcher, lifecycle admission or retirement proof.
module Prodbox.Control.KindFamilyDispatcher
  ( KindFamilyDispatchOutcome (..)
  , KindFamilyResultRecording (..)
  , dispatchKindFamilyController
  , KindProbeRecoveryDispatchOutcome (..)
  , KindProbeRecoveryWorkerOutcome (..)
  , dispatchKindProbeRecoveryController
  , isKindProbeRecoveryArguments
  , kindProbeRecoveryDispatchCompleted
  , KindProbeFamilyDispatchOutcome (..)
  , KindProbeFamilyWorkerOutcome (..)
  , dispatchKindProbeFamilyController
  , kindProbeFamilyDispatchCompleted
  , kindProbeFamilyDispatchFailureCode
  , kindFamilyDispatchCompleted
  , summarizeFamilyResult
  ) where

import Prodbox.Control.KindController
  ( KindFamilyParentOutcome (..)
  , KindFamilyParentError (..)
  , KindFamilyPreparationError
  , KindFamilyPostAction (..)
  , KindFamilyWorkOutcome (..)
  , prepareKindFamilyController
  , prepareKindProbeRecoveryController
  , prepareKindProbeVerifierController
  , prepareKindProbeSuccessorController
  , runKindFamilyWorker
  , withKindFamilyProcesses
  )
import Prodbox.Control.KindControllerInput
  ( KindControllerInputError (..), KindControllerInputOutcome (..)
  , withPinnedKindControllerInput
  , withPinnedKindProbeRecoveryInput
  , KindProbeFamilyRequest (..)
  , withPinnedKindProbeFamilyInput
  )
import Data.ByteString.Char8 qualified as Bytes
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.List (isPrefixOf)
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Control.KindControllerReceipt
  ( ControllerReceiptWrite (ControllerReceiptRecorded)
  , FamilyPrimary (..), FamilyWorkerClosing (..), FamilyParentClosing (..), FamilyInputClosing (..)
  , FamilyPostDisposition (..), FamilyPostClosing (..), FamilyResult (..), FamilyResultWrite (..)
  , recordFamilyResult
  )
import Prodbox.Control.KindControllerRequest (encodeKindControllerRequest, kindRequestOperation, probeRecoveryControllerRequest, probeRecoveryId, probeVerifierRecoveryRequest, probeSuccessorVerifier)
import Prodbox.Control.KindNetworkProbeRecord (ProbeRecord (ProbeVerifierDiagnosticRecord, ProbeSuccessorDiagnosticRecord), ProbeRecordWrite (..), ProbeVerifierDiagnostic (..), recordProbeRecord)
import Prodbox.Control.KindFamilyRecovery (KindFamilyRetirementOutcome (..), KindProbeSuccessorChainOutcome (..), KindProbeSuccessorWorkerOutcome (..), recoverKindFamilyProbeWithWorker, recoverKindFamilyProbeAttemptWithVerifier, recoverKindFamilyProbeWithSuccessor)
import Prodbox.Control.KindKubeconfigInstall (KindKubeconfigInstall (KindKubeconfigInstalled))
import Prodbox.Control.NetworkEnforcement (EnforcementOutcome (..), ProbeRecoveryOutcome (..), ProbeAttemptReadbackOutcome (..), enforcementComplete)
import Prodbox.Control.Reconcile (ImageAttemptFailure (..), ReconcileOutcome (..))
import Prodbox.Control.KindLease (KindLeaseOutcome (..), KindLeaseHandoff (..), KindOperationOutcome (..), awaitKindLeaseHandoff, withRecoveredKindOperation)
import Prodbox.Subprocess qualified as Subprocess
import Prodbox.Subprocess.HostOperationFamily qualified as HostFamily
import Prodbox.Subprocess.HostControllerInputs qualified as HostInputs
import Prodbox.Control.KindTool (confirmedKindWorkerNode)
import Prodbox.Subprocess.HostControllerArguments qualified as Arguments
import Prodbox.Subprocess.SystemdBus qualified as Bus
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

data KindFamilyResultRecording
  = KindFamilyResultNoContext
  | KindFamilyResultDeadlineExpired
  | KindFamilyResultTimedOut
  | KindFamilyResultLease !(KindOperationOutcome FamilyResultWrite)
  deriving (Show)

data KindFamilyDispatchOutcome
  = KindFamilyDispatchManagerRefused !Bus.BusError
  | KindFamilyDispatchInput
      !(KindControllerInputOutcome (Either KindFamilyPreparationError (KindFamilyParentOutcome KindFamilyWorkOutcome)))
      !KindFamilyResultRecording
  deriving (Show)

data KindProbeRecoveryDispatchOutcome
  = KindProbeRecoveryDispatchManagerRefused !Bus.BusError
  | KindProbeRecoveryDispatchInput
      !(KindControllerInputOutcome (Either KindFamilyPreparationError
        (KindFamilyParentOutcome KindProbeRecoveryWorkerOutcome)))
  deriving (Show)

data KindProbeRecoveryWorkerOutcome
  = KindProbeRecoveryHandoffRefused !KindLeaseHandoff
  | KindProbeRecoveryWorkerObserved !(KindFamilyRetirementOutcome (KindOperationOutcome ProbeRecoveryOutcome))
  deriving (Show)

data KindProbeFamilyWorkerOutcome
  = KindProbeFamilyHandoffRefused !KindLeaseHandoff
  | KindProbeFamilyCleanup !(KindFamilyRetirementOutcome (KindOperationOutcome ProbeRecoveryOutcome))
  | KindProbeFamilyVerifier !(KindFamilyRetirementOutcome (KindFamilyRetirementOutcome (KindOperationOutcome ProbeAttemptReadbackOutcome)))
  | KindProbeFamilySuccessor !KindProbeSuccessorWorkerOutcome
  deriving (Show)

data KindProbeFamilyDispatchOutcome
  = KindProbeFamilyDispatchManagerRefused !Bus.BusError
  | KindProbeFamilyDispatchInput !(KindControllerInputOutcome
      (Either KindFamilyPreparationError (KindFamilyParentOutcome KindProbeFamilyWorkerOutcome)))
  deriving (Show)

-- Completion describes the worker callback only; its family still needs
-- independent retirement before any successor can use its result.
kindProbeFamilyDispatchCompleted :: KindProbeFamilyDispatchOutcome -> Bool
kindProbeFamilyDispatchCompleted outcome = case outcome of
  KindProbeFamilyDispatchInput (KindInputCompleted (Right (KindFamilyParentCompleted
    (KindProbeFamilyCleanup (KindFamilyRetirementReturned
      (KindOperationCallbackReturned ProbeRecoveryCompleted) (Right ()) True))))) -> True
  KindProbeFamilyDispatchInput (KindInputCompleted (Right (KindFamilyParentCompleted
    (KindProbeFamilyVerifier (KindFamilyRetirementReturned (KindFamilyRetirementReturned
      (KindOperationCallbackReturned ProbeAttemptReadbackRecorded) (Right ()) True) (Right ()) True))))) -> True
  KindProbeFamilyDispatchInput (KindInputCompleted (Right (KindFamilyParentCompleted
    (KindProbeFamilySuccessor (KindProbeSuccessorWorkerObserved (KindFamilyRetirementReturned (KindFamilyRetirementReturned
      (KindFamilyRetirementReturned (KindProbeSuccessorChainReturned (KindOperationCallbackReturned ProbeAttemptReadbackRecorded) True) (Right ()) True) (Right ()) True) (Right ()) True)))))) -> True
  _ -> False

-- Small, fixed manager exit categories carry no input or subprocess output.
-- They diagnose the worker; they do not establish its retirement or success.
kindProbeFamilyDispatchFailureCode :: KindProbeFamilyDispatchOutcome -> Int
kindProbeFamilyDispatchFailureCode outcome = case outcome of
  KindProbeFamilyDispatchManagerRefused _ -> 10
  KindProbeFamilyDispatchInput input -> case input of
    KindInputRefused failure -> case failure of
      KindInputOwnerRefused _ -> 11
      KindInputInvalidUtf8 -> 12
      KindInputBootstrapRefused _ -> 13
      KindInputBootstrapMissing -> 14
      KindInputRequestRefused _ -> 15
    KindInputChangedAfter _ _ -> 16
    KindInputCompleted result -> diagnosticCode (summarizeSuccessor result)

diagnosticCode :: ProbeVerifierDiagnostic -> Int
diagnosticCode diagnostic = case diagnostic of
  VerifierPreparationRefused -> 20
  VerifierParentRefused -> 21
  VerifierParentUnconfirmed -> 22
  VerifierHandoffRefused -> 23
  VerifierOriginalRetirementRefused -> 24
  VerifierPriorRetirementRefused -> 25
  VerifierSuccessorRetirementRefused -> 42
  VerifierLeaseUnconfirmed -> 26
  VerifierOriginalLeaseUnconfirmed -> 37
  VerifierCleanupLeaseUnconfirmed -> 38
  VerifierFirstLeaseUnconfirmed -> 39
  VerifierChainLeaseUnconfirmed -> 40
  VerifierOperationLeaseUnconfirmed -> 41
  VerifierReadbackInvalid -> 27
  VerifierFamilyRefused -> 28
  VerifierSnapshotUnobservable -> 29
  VerifierJournalRefused -> 30
  VerifierIdentityChanged -> 31
  VerifierAbsenceUnconfirmed -> 32
  VerifierRecordRefused -> 33
  VerifierRecordAlreadyExists -> 43
  VerifierRecordIncomplete -> 44
  VerifierRecordUnexpected -> 45
  VerifierChangedAfterRecord -> 34
  VerifierReadbackRecorded -> 35
  VerifierClosingUnconfirmed -> 36

dispatchKindProbeFamilyController :: Arguments.HostControllerArguments -> IO KindProbeFamilyDispatchOutcome
dispatchKindProbeFamilyController arguments = do
  uid <- getEffectiveUserID
  let work = Identity.hostExecutionWorkEnd (Arguments.controllerOriginalWindow arguments)
      socket = "/run/user/" ++ show uid ++ "/bus"
  observed <- Bus.withSystemdBus work socket Bus.observeManagerDomain
  case observed of
    Left failure -> pure (KindProbeFamilyDispatchManagerRefused failure)
    Right domain -> KindProbeFamilyDispatchInput <$> withPinnedKindProbeFamilyInput arguments domain
      (\bootstrap request program stable -> do
        prepared <- case request of
          KindProbeCleanupRequest recovery -> prepareKindProbeRecoveryController bootstrap recovery
          KindProbeVerifierRequest verifier -> prepareKindProbeVerifierController bootstrap verifier
          KindProbeSuccessorRequest successor -> prepareKindProbeSuccessorController bootstrap successor
        result <- case prepared of
          Left failure -> pure (Left failure)
          Right preparation -> Right <$> withKindFamilyProcesses preparation program domain
            (\processes -> do
              let recovery = case request of
                    KindProbeCleanupRequest value -> value
                    KindProbeVerifierRequest value -> probeVerifierRecoveryRequest value
                    KindProbeSuccessorRequest value -> probeVerifierRecoveryRequest (probeSuccessorVerifier value)
                  operation = kindRequestOperation (probeRecoveryControllerRequest recovery)
                  parentStable = do
                    held <- stable
                    parent <- Subprocess.verifyOperationSubprocessesBeforeEffect processes
                    pure (held == Right () && parent == Right ())
              handoff <- awaitKindLeaseHandoff work bootstrap operation parentStable
              case handoff of
                KindLeaseHandoffReady -> case request of
                  KindProbeCleanupRequest value -> KindProbeFamilyCleanup <$>
                    recoverKindFamilyProbeWithWorker work bootstrap operation (probeRecoveryId value) processes stable
                  KindProbeVerifierRequest value -> KindProbeFamilyVerifier <$>
                    recoverKindFamilyProbeAttemptWithVerifier work bootstrap value processes stable
                  KindProbeSuccessorRequest value -> KindProbeFamilySuccessor <$>
                    recoverKindFamilyProbeWithSuccessor work bootstrap value processes stable
                failure -> pure (KindProbeFamilyHandoffRefused failure))
        case request of
          KindProbeVerifierRequest verifier -> do
            let coordinates = probeVerifierRecoveryRequest verifier
                operation = kindRequestOperation (probeRecoveryControllerRequest coordinates)
                namespace = "prodbox-netcheck-" ++ take 12 operation
                admitted = (== Right ()) <$> stable
            _ <- withRecoveredKindOperation bootstrap operation $ \lease ->
              recordProbeRecord bootstrap operation namespace (ProbeVerifierDiagnosticRecord verifier (summarizeVerifier result))
                ((&&) <$> lease <*> admitted)
            pure ()
          KindProbeCleanupRequest _ -> pure ()
          KindProbeSuccessorRequest successor -> do
            let coordinates = probeVerifierRecoveryRequest (probeSuccessorVerifier successor)
                operation = kindRequestOperation (probeRecoveryControllerRequest coordinates)
                namespace = "prodbox-netcheck-" ++ take 12 operation
                admitted = (== Right ()) <$> stable
            _ <- withRecoveredKindOperation bootstrap operation $ \lease ->
              recordProbeRecord bootstrap operation namespace (ProbeSuccessorDiagnosticRecord successor (summarizeSuccessor result))
                ((&&) <$> lease <*> admitted)
            pure ()
        pure result)

-- Diagnostic only: closed constructors deliberately exclude command output,
-- exceptions and configuration values, and never authorize a successor.
summarizeVerifier :: Either KindFamilyPreparationError (KindFamilyParentOutcome KindProbeFamilyWorkerOutcome) -> ProbeVerifierDiagnostic
summarizeVerifier result = case result of
  Left _ -> VerifierPreparationRefused
  Right (KindFamilyParentRefused _) -> VerifierParentRefused
  Right (KindFamilyParentUnconfirmedAfter _ _) -> VerifierParentUnconfirmed
  Right (KindFamilyParentCompleted worker) -> case worker of
    KindProbeFamilyHandoffRefused _ -> VerifierHandoffRefused
    KindProbeFamilyCleanup _ -> VerifierFamilyRefused
    KindProbeFamilySuccessor _ -> VerifierFamilyRefused
    KindProbeFamilyVerifier original -> case original of
      KindFamilyRetirementRefused _ -> VerifierOriginalRetirementRefused
      KindFamilyRetirementLeaseUnconfirmed -> VerifierLeaseUnconfirmed
      KindFamilyRetirementReturned previous (Right ()) True -> case previous of
        KindFamilyRetirementRefused _ -> VerifierPriorRetirementRefused
        KindFamilyRetirementLeaseUnconfirmed -> VerifierLeaseUnconfirmed
        KindFamilyRetirementReturned operation (Right ()) True -> case operation of
          KindOperationCallbackReturned readback -> summarizeReadback readback
          _ -> VerifierLeaseUnconfirmed
        _ -> VerifierClosingUnconfirmed
      _ -> VerifierClosingUnconfirmed

summarizeSuccessor :: Either KindFamilyPreparationError (KindFamilyParentOutcome KindProbeFamilyWorkerOutcome) -> ProbeVerifierDiagnostic
summarizeSuccessor result = case result of
  Left _ -> VerifierPreparationRefused
  Right (KindFamilyParentRefused _) -> VerifierParentRefused
  Right (KindFamilyParentUnconfirmedAfter _ _) -> VerifierParentUnconfirmed
  Right (KindFamilyParentCompleted worker) -> case worker of
    KindProbeFamilyHandoffRefused _ -> VerifierHandoffRefused
    KindProbeFamilySuccessor KindProbeSuccessorWorkerIdentityUnconfirmed -> VerifierIdentityChanged
    KindProbeFamilySuccessor (KindProbeSuccessorWorkerObserved original) -> case original of
      KindFamilyRetirementRefused _ -> VerifierOriginalRetirementRefused
      KindFamilyRetirementLeaseUnconfirmed -> VerifierOriginalLeaseUnconfirmed
      KindFamilyRetirementReturned prior (Right ()) True -> case prior of
        KindFamilyRetirementRefused _ -> VerifierPriorRetirementRefused
        KindFamilyRetirementLeaseUnconfirmed -> VerifierCleanupLeaseUnconfirmed
        KindFamilyRetirementReturned first (Right ()) True -> case first of
          KindFamilyRetirementRefused _ -> VerifierPriorRetirementRefused
          KindFamilyRetirementLeaseUnconfirmed -> VerifierFirstLeaseUnconfirmed
          KindFamilyRetirementReturned chain (Right ()) True -> case chain of
            KindProbeSuccessorChainReturned (KindOperationCallbackReturned readback) True -> summarizeReadback readback
            KindProbeSuccessorChainReturned _ True -> VerifierOperationLeaseUnconfirmed
            KindProbeSuccessorChainUnconfirmed -> VerifierChainLeaseUnconfirmed
            KindProbeSuccessorChainRefused _ _ -> VerifierSuccessorRetirementRefused
            _ -> VerifierClosingUnconfirmed
          _ -> VerifierClosingUnconfirmed
        _ -> VerifierClosingUnconfirmed
      _ -> VerifierClosingUnconfirmed
    _ -> VerifierFamilyRefused

summarizeReadback :: ProbeAttemptReadbackOutcome -> ProbeVerifierDiagnostic
summarizeReadback readback = case readback of
  ProbeAttemptReadbackInvalid -> VerifierReadbackInvalid
  ProbeAttemptReadbackFamilyRefused -> VerifierFamilyRefused
  ProbeAttemptReadbackSnapshotUnobservable -> VerifierSnapshotUnobservable
  ProbeAttemptReadbackJournalRefused _ -> VerifierJournalRefused
  ProbeAttemptReadbackIdentityChanged -> VerifierIdentityChanged
  ProbeAttemptReadbackAbsenceUnconfirmed -> VerifierAbsenceUnconfirmed
  ProbeAttemptReadbackRecordRefused result -> case result of
    ProbeRefused -> VerifierRecordRefused
    ProbeAlreadyExists -> VerifierRecordAlreadyExists
    ProbeIncomplete -> VerifierRecordIncomplete
    ProbeRecorded -> VerifierRecordUnexpected
  ProbeAttemptReadbackChangedAfterRecord -> VerifierChangedAfterRecord
  ProbeAttemptReadbackRecorded -> VerifierReadbackRecorded

-- A node family repeats its operation ID in both halves; a recovery family
-- has a distinct ID in the second half. Pinned decoding still authenticates
-- all request fields before either path can enter its worker.
isKindProbeRecoveryArguments :: Arguments.HostControllerArguments -> Bool
isKindProbeRecoveryArguments arguments = take 32 key /= drop 32 key
 where
  key = Identity.hostExecutionKeyText (Arguments.controllerOperationKey arguments)

-- Completion here is only the worker's observed callback and original-family
-- closing; a caller still must settle the cleanup family independently.
kindProbeRecoveryDispatchCompleted :: KindProbeRecoveryDispatchOutcome -> Bool
kindProbeRecoveryDispatchCompleted outcome = case outcome of
  KindProbeRecoveryDispatchInput (KindInputCompleted (Right (KindFamilyParentCompleted
    (KindProbeRecoveryWorkerObserved (KindFamilyRetirementReturned
      (KindOperationCallbackReturned ProbeRecoveryCompleted) (Right ()) True))))) -> True
  _ -> False

-- This internal composition does not submit or prove retirement of the
-- cleanup family. Its caller must settle that family even after a return.
dispatchKindProbeRecoveryController :: Arguments.HostControllerArguments -> IO KindProbeRecoveryDispatchOutcome
dispatchKindProbeRecoveryController arguments = do
  uid <- getEffectiveUserID
  let work = Identity.hostExecutionWorkEnd (Arguments.controllerOriginalWindow arguments)
      socket = "/run/user/" ++ show uid ++ "/bus"
  observed <- Bus.withSystemdBus work socket Bus.observeManagerDomain
  case observed of
    Left failure -> pure (KindProbeRecoveryDispatchManagerRefused failure)
    Right domain -> KindProbeRecoveryDispatchInput <$> withPinnedKindProbeRecoveryInput arguments domain
      (\bootstrap recovery program stable -> do
        prepared <- prepareKindProbeRecoveryController bootstrap recovery
        case prepared of
          Left failure -> pure (Left failure)
          Right preparation -> Right <$> withKindFamilyProcesses preparation program domain
            (\processes -> do
              let operation = kindRequestOperation (probeRecoveryControllerRequest recovery)
                  parentStable = do
                    held <- stable
                    parent <- Subprocess.verifyOperationSubprocessesBeforeEffect processes
                    pure (held == Right () && parent == Right ())
              handoff <- awaitKindLeaseHandoff work bootstrap operation parentStable
              case handoff of
                KindLeaseHandoffReady -> KindProbeRecoveryWorkerObserved <$>
                  recoverKindFamilyProbeWithWorker work bootstrap operation (probeRecoveryId recovery) processes stable
                failure -> pure (KindProbeRecoveryHandoffRefused failure)))

-- This means the controller observed its worker and a completed probe. The
-- caller still must prove job processing and physical retirement.
kindFamilyDispatchCompleted :: KindFamilyDispatchOutcome -> Bool
kindFamilyDispatchCompleted outcome = case outcome of
  KindFamilyDispatchInput
    (KindInputCompleted (Right (KindFamilyParentCompleted
      (KindFamilyWorkObserved observed
        (Just (KindOperationCallbackReturned (KindFamilyPostProbe probe True)))))))
    (KindFamilyResultLease (KindOperationCallbackReturned FamilyResultRecorded)) ->
          enforcementComplete probe && case confirmedKindWorkerNode observed of Just _ -> True; Nothing -> False
  _ -> False

-- The first manager domain is only data for pinned request decoding. The
-- process owner independently qualifies the same domain and verifies the
-- actual operation family before the worker callback can run.
dispatchKindFamilyController :: Arguments.HostControllerArguments -> IO KindFamilyDispatchOutcome
dispatchKindFamilyController arguments = do
  uid <- getEffectiveUserID
  let work = Identity.hostExecutionWorkEnd (Arguments.controllerOriginalWindow arguments)
      socket = "/run/user/" ++ show uid ++ "/bus"
  observed <- Bus.withSystemdBus work socket Bus.observeManagerDomain
  case observed of
    Left failure -> pure (KindFamilyDispatchManagerRefused failure)
    Right domain -> do
      retained <- newIORef Nothing
      loaded <- withPinnedKindControllerInput arguments domain $ \bootstrap request program stable -> do
        writeIORef retained (Just (bootstrap, request))
        prepared <- prepareKindFamilyController bootstrap request
        case prepared of
          Left failure -> pure (Left failure)
          Right preparation -> Right <$> withKindFamilyProcesses preparation program domain
            (\processes -> runKindFamilyWorker preparation processes stable)
      known <- readIORef retained
      recorded <- case known of
        Nothing -> pure KindFamilyResultNoContext
        Just (bootstrap, request) -> do
          let operation = kindRequestOperation request
              digest = Bytes.unpack (hexSha256 (encodeKindControllerRequest request))
              outer = Identity.hostExecutionOuterEnd (Arguments.controllerOriginalWindow arguments)
          now <- getMonotonicTimeNSec
          if now >= outer || (outer - now) `div` 1000 == 0
            then pure KindFamilyResultDeadlineExpired
            else do
              let remaining = min 10000000 ((outer - now) `div` 1000)
              result <- timeout (fromIntegral remaining) $ withRecoveredKindOperation bootstrap operation
                (recordFamilyResult bootstrap operation digest (summarizeFamilyResult loaded))
              pure (maybe KindFamilyResultTimedOut KindFamilyResultLease result)
      pure (KindFamilyDispatchInput loaded recorded)

-- Only closed constructors are projected; arbitrary exceptions and captured
-- subprocess streams are never rendered into the retained summary.
summarizeFamilyResult
  :: KindControllerInputOutcome (Either KindFamilyPreparationError (KindFamilyParentOutcome KindFamilyWorkOutcome))
  -> FamilyResult
summarizeFamilyResult input = case input of
  KindInputRefused _ -> emptyResult FamilyPreparationRefused FamilyInputUnconfirmed
  KindInputCompleted result -> summarize FamilyInputComplete result
  KindInputChangedAfter result failure -> summarize (inputClosingFailure failure) result
 where
  summarize inputClosing result = case result of
    Left _ -> emptyResult FamilyPreparationRefused inputClosing
    Right parent -> case parent of
      KindFamilyParentRefused _ -> FamilyResult FamilyParentRefused FamilyWorkerUnobserved FamilyParentUnconfirmed inputClosing FamilyPostNotAttempted FamilyPostNotStarted
      KindFamilyParentCompleted work -> fromWork FamilyParentComplete inputClosing work
      KindFamilyParentUnconfirmedAfter work failure -> fromWork (parentClosingFailure failure) inputClosing work
  fromWork parentClosing inputClosing work = case work of
    KindFamilyWorkHandoffRefused _ -> FamilyResult FamilyWorkerNotObserved FamilyWorkerNotStarted parentClosing inputClosing FamilyPostNotAttempted FamilyPostNotStarted
    KindFamilyWorkAdmissionRefused -> FamilyResult FamilyWorkerNotObserved FamilyWorkerNotStarted parentClosing inputClosing FamilyPostNotAttempted FamilyPostNotStarted
    KindFamilyWorkPrerequisitesUnconfirmed reason -> FamilyResult FamilyWorkerNotObserved FamilyWorkerNotStarted parentClosing inputClosing (prerequisiteDisposition reason) FamilyPostNotStarted
    KindFamilyWorkIoUnconfirmed _ -> FamilyResult FamilyWorkerNotObserved FamilyWorkerIoUnconfirmed parentClosing inputClosing FamilyPostNotAttempted FamilyPostNotStarted
    KindFamilyWorkIoUnconfirmedAfter observed _ -> FamilyResult (workerPrimary observed) FamilyWorkerIoUnconfirmed parentClosing inputClosing FamilyPostNotAttempted FamilyPostNotStarted
    KindFamilyWorkDescriptorShapeRefused -> FamilyResult FamilyWorkerNotObserved FamilyWorkerDescriptorRefused parentClosing inputClosing FamilyPostNotAttempted FamilyPostNotStarted
    KindFamilyWorkObserved observed post ->
      let (postPrimary, postClosing) = postDisposition post
       in FamilyResult (workerPrimary observed) FamilyWorkerComplete parentClosing inputClosing postPrimary postClosing
  emptyResult primary inputClosing = FamilyResult primary FamilyWorkerNotStarted FamilyParentNotStarted inputClosing FamilyPostNotAttempted FamilyPostNotStarted

  inputClosingFailure failure = case failure of
    HostFamily.HostOperationExpired -> FamilyInputExpired
    HostFamily.HostOperationInputsRefused HostInputs.ControllerInputsExpired -> FamilyInputExpired
    HostFamily.HostOperationInputsRefused (HostInputs.ControllerInputChanged _) -> FamilyInputChanged
    HostFamily.HostOperationInputsRefused (HostInputs.ControllerInputIoRefused {}) -> FamilyInputIoUnconfirmed
    _ -> FamilyInputUnconfirmed
  parentClosingFailure failure = case failure of
    KindFamilyParentKernelRefused _ -> FamilyParentKernelUnconfirmed
    KindFamilyParentProviderRefused _ -> FamilyParentProviderUnconfirmed
    KindFamilyParentProgramRefused _ -> FamilyParentProgramUnconfirmed
    _ -> FamilyParentUnconfirmed

  prerequisiteDisposition reason = case reason of
    ReconcileImageAttempt _ _ failure -> case failure of
      ImageAttemptResultUnconfirmed -> FamilyPostImageResultUnconfirmed
      ImageAttemptReadbackUnconfirmed -> FamilyPostImageReadbackUnconfirmed
      ImageAttemptTransportUnconfirmed -> FamilyPostImageTransportUnconfirmed
      ImageAttemptClosingUnconfirmed -> FamilyPostImageClosingUnconfirmed
      ImageAttemptOther -> FamilyPostImageAttemptFailed
    ReconcileImageNotObserved {} -> FamilyPostImageObservationFailed
    ReconcileDaemonUnobserved {} -> FamilyPostNetworkFailed
    ReconcileNetworkProposalInvalid -> FamilyPostNetworkFailed
    ReconcileNetworkProposalRefused {} -> FamilyPostNetworkFailed
    ReconcileNetworkAttempt {} -> FamilyPostNetworkFailed
    ReconcileVolumeProposalRefused {} -> FamilyPostVolumeFailed
    ReconcileVolumeProposalInvalid {} -> FamilyPostVolumeFailed
    ReconcileVolumeAttempt {} -> FamilyPostVolumeFailed
    ReconcileNodeProposal {} -> FamilyPostNodeIntentFailed
    ReconcileNodeProposalInvalid {} -> FamilyPostNodeIntentFailed
    _ -> FamilyPostPreconditionFailed
  workerPrimary observed = case confirmedKindWorkerNode observed of Just _ -> FamilyWorkerConfirmed; Nothing -> FamilyWorkerUnconfirmed
  postDisposition post = case post of
    Nothing -> (FamilyPostNotAttempted, FamilyPostNotStarted)
    Just outcome ->
      let closing = case outcome of KindOperationCallbackReturned _ -> FamilyPostLeaseComplete; _ -> FamilyPostLeaseUnconfirmed
       in (maybe FamilyPostNotAttempted actionDisposition (postAction outcome), closing)
  actionDisposition action = case action of
    KindFamilyPostPreconditionUnconfirmed -> FamilyPostPreconditionFailed
    KindFamilyPostInstallUnconfirmed _ _ -> FamilyPostInstallFailed
    KindFamilyPostReceipt KindKubeconfigInstalled ControllerReceiptRecorded True -> FamilyPostReceiptComplete
    KindFamilyPostReceipt {} -> FamilyPostReceiptFailed
    KindFamilyPostProbe probe True | enforcementComplete probe -> FamilyPostProbeComplete
    KindFamilyPostProbe probe _ -> case enforcementFailure probe of
      Just "validated kubeconfig snapshot unavailable" -> FamilyPostProbeSnapshotRefused
      Just "network probe family binding refused" -> FamilyPostProbeBindingRefused
      Just reason | "probe intent not recorded: " `isPrefixOf` reason -> FamilyPostProbeIntentRefused
      _ -> FamilyPostProbeFailed
  postAction outcome = case outcome of
    KindOperationCallbackReturned action -> Just action
    KindOperationRootChanged (Right action) -> Just action
    KindOperationUnlockFailed lease _ -> leaseAction lease
    KindOperationScopeCleanupFailed lease _ -> leaseAction lease
    _ -> Nothing
  leaseAction lease = case lease of
    KindLeaseCompleted (Right action) -> Just action
    KindLeaseRootChanged (Right action) -> Just action
    KindLeaseUnlockFailed inner _ -> leaseAction inner
    KindLeaseScopeCleanupFailed inner _ -> leaseAction inner
    _ -> Nothing
