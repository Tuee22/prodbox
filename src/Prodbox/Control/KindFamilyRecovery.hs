{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE TupleSections #-}

-- | Recovery of the original kind family, never a replacement work window.
module Prodbox.Control.KindFamilyRecovery
  ( KindFamilyRecoveryError (..)
  , KindFamilySubmissionObservation (..)
  , KindFamilyInputRetirement (..)
  , KindFamilyRetirement
  , KindFamilyRetirementOutcome (..)
  , withKindFamilyRetirement
  , KindFamilyCompletionStep (..)
  , withKindFamilyCompletion
  , KindFamilyReadiness (..)
  , KindFamilyNetworkEvidence (..)
  , kindFamilyReadinessComplete
  , observeKindFamilyReadinessWith
  , observeKindFamilyCompletion
  , awaitKindFamilyCompletionWith
  , KindFamilyCompletionWait (..)
  , recoverKindFamilyProbeWithWorker
  , recoverKindFamilyProbeAttemptWithVerifier
  , KindProbeSuccessorWorkerOutcome (..)
  , recoverKindFamilyProbeWithSuccessor
  , KindProbeFamilyRetirement
  , withKindProbeFamilyRetirement
  , verifyKindProbeFamilyRetirement
  , retireKindProbeFamilyPublishedInputs
  , KindProbeVerifierRetirement
  , withKindProbeVerifierRetirement
  , verifyKindProbeVerifierRetirement
  , retireKindProbeVerifierPublishedInputs
  , KindProbeSuccessorRetirement
  , withKindProbeSuccessorRetirement
  , verifyKindProbeSuccessorRetirement
  , retireKindProbeSuccessorPublishedInputs
  , KindProbeSuccessorChainOutcome (..)
  , withKindProbeSuccessorRetirementChain
  , verifyKindProbeSuccessorRetirementChain
  , withKindProbeSuccessorRetirementPrefix
  , verifyKindProbeSuccessorRetirementPrefix
  , withKindProbeSuccessorRetirementTransition
  , withKindProbeSuccessorRetirementStaged
  , KindProbeVerifierNeverSentOutcome (..)
  , recoverNeverSentKindProbeVerifierInputs
  , KindProbeNeverSentOutcome (..)
  , retireNeverSentKindProbeInputs
  , recoverNeverSentKindProbeInputs
  , KindFamilyNeverSentOutcome (..)
  , recoverNeverSentKindFamilyInputs
  , KindFamilyNeverSentScopeOutcome (..)
  , withNeverSentKindFamily
  , KindFamilyPrePublicationOutcome (..)
  , withCancelledPrePublicationKindFamily
  , withCancelledUnlaunchedOwnerFamily
  , verifyKindFamilyRetirement
  , retireKindFamilyPublishedInputs
  , observeKindFamilySubmission
  , observeKindFamilySubmissionStatus
  , KindFamilyPublicationState (..)
  , classifyKindFamilyPublication
  , retireKindFamilyInputs
  ) where

import Control.Monad (void)
import Control.Monad.Trans.Class (lift)
import Data.ByteString.Char8 qualified as Bytes
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Config.BootstrapProjection (BootstrapProjection)
import Prodbox.Control.KindControllerReceipt qualified as Receipt
import Prodbox.Control.KindControllerRequest qualified as Request
import Prodbox.Control.KindIntent
  ( KindIntentObservation (KindIntentMatches)
  , observeKindExternalFamilyIntent
  , observeKindFamilyIntent
  , observeKindIntent
  , observeKindOwnerFamilyIntent
  )
import Prodbox.Control.KindKubeconfigFile (withKindKubeconfigSnapshotBound)
import Prodbox.Control.KindLease qualified as Lease
import Prodbox.Control.KindNetworkProbeRecord qualified as Probe
import Prodbox.Control.KubernetesReadiness
  ( ReadinessObservation (..)
  , observeKubernetesReadinessSnapshot
  )
import Prodbox.Control.NetworkEnforcement
  ( EnforcementOutcome
  , ProbeAttemptReadbackOutcome (..)
  , ProbeJournalObservation (..)
  , ProbeRecoveryOutcome (..)
  , confirmAttemptedProbeAbsenceUnderFamily
  , confirmSuccessorProbeAbsenceUnderFamily
  , enforcementComplete
  , observeProbeJournal
  , recoverRecordedProbeUnderFamily
  )
import Prodbox.Control.Status
  ( matchesScopedWorkerNode
  , observeNodeCaBindingUnderLease
  , observeNodeCreateUnderLease
  )
import Prodbox.Subprocess qualified as Subprocess
import Prodbox.Subprocess.HostControllerInputRetirement qualified as InputRetirement
import Prodbox.Subprocess.HostControllerInputs qualified as Inputs
import Prodbox.Subprocess.HostControllerPublication qualified as Publication
import Prodbox.Subprocess.HostOperationFamily qualified as Family
import Prodbox.Subprocess.HostOperationRetirement qualified as Retirement
import Prodbox.Subprocess.SystemdBus qualified as Bus
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import System.Posix.User (getEffectiveUserID)

data KindFamilyRecoveryError
  = KindFamilyRecoveryRequestMissing
  | KindFamilyRecoveryProtocolUnconfirmed
  | KindFamilyRecoveryRequestConflict
  | KindFamilyRecoveryRequestUnobservable
  | KindFamilyRecoveryKeyInvalid
  | KindFamilyRecoverySubmissionUnobservable !Inputs.HostControllerInputError
  | KindFamilyRecoverySubmissionMismatch
  | KindFamilyRecoveryManagerRefused !Bus.BusError
  | KindFamilyRecoveryRetirementRefused !Retirement.RetirementError
  | KindFamilyRecoveryRetirementAndLeaseChanged !Retirement.RetirementError
  | KindFamilyRecoveryProvenanceAndRetirement !KindFamilyRecoveryError !Retirement.RetirementError
  | KindFamilyRecoverySuccessorNeverSentRefused
      !KindFamilyRecoveryError
      !Publication.HostControllerPublicationError
  | KindFamilyRecoveryNeverSentProofRefused !Publication.HostControllerPublicationError
  | KindFamilyRecoveryLeaseChanged
  deriving (Eq, Show)

data KindFamilySubmissionObservation = KindFamilySubmissionRecorded
  deriving (Eq, Show)

data KindFamilyPublicationState
  = KindFamilyPublicationNotRecorded
  | KindFamilyPublicationBeforeAttempt
  | KindFamilyPublicationAttemptRecorded
  | KindFamilyPublicationCancelled
  | KindFamilyPublicationUnconfirmed
  deriving (Eq, Show)

classifyKindFamilyPublication
  :: Receipt.FamilyLaunchObservation
  -> Receipt.FamilyLaunchObservation
  -> Receipt.FamilyLaunchObservation
  -> KindFamilyPublicationState
classifyKindFamilyPublication launch marker cancellation = case (launch, marker, cancellation) of
  (Receipt.FamilyLaunchMissing, Receipt.FamilyLaunchMissing, Receipt.FamilyLaunchMissing) -> KindFamilyPublicationNotRecorded
  (Receipt.FamilyLaunchObserved _, Receipt.FamilyLaunchMissing, Receipt.FamilyLaunchMissing) -> KindFamilyPublicationBeforeAttempt
  ( Receipt.FamilyLaunchObserved request
    , Receipt.FamilyLaunchObserved attempted
    , Receipt.FamilyLaunchMissing
    )
      | request == attempted -> KindFamilyPublicationAttemptRecorded
  ( Receipt.FamilyLaunchObserved request
    , Receipt.FamilyLaunchMissing
    , Receipt.FamilyLaunchObserved cancelled
    )
      | request == cancelled -> KindFamilyPublicationCancelled
  _ -> KindFamilyPublicationUnconfirmed

-- Both the payload-removal result and closing checks survive independently.
data KindFamilyInputRetirement = KindFamilyInputRetirement
  { kindFamilyInputsRemoved :: !(Either InputRetirement.InputRetirementError ())
  , kindFamilyRetirementClosing :: !(Either Retirement.RetirementError ())
  , kindFamilyLeaseClosing :: !Bool
  }
  deriving (Eq, Show)

data KindProbeNeverSentOutcome
  = KindProbeNeverSentIdentityUnconfirmed
  | KindProbeNeverSentBeforePublication !(Either KindFamilyRecoveryError ()) !Bool
  | KindProbeNeverSentInputs
      !(Either InputRetirement.InputRetirementError ())
      !(Either KindFamilyRecoveryError ())
      !Bool
  deriving (Eq, Show)

data KindProbeVerifierNeverSentOutcome
  = KindProbeVerifierNeverSentIdentityUnconfirmed
  | KindProbeVerifierNeverSentBeforePublication
      !(Either KindFamilyRecoveryError ())
      !(Either KindFamilyRecoveryError ())
      !Bool
  | KindProbeVerifierNeverSentInputs
      !(Either InputRetirement.InputRetirementError ())
      !(Either KindFamilyRecoveryError ())
      !(Either KindFamilyRecoveryError ())
      !Bool
  deriving (Eq, Show)

data KindFamilyNeverSentOutcome
  = KindFamilyNeverSentIdentityUnconfirmed
  | KindFamilyNeverSentBeforePublication !Bool
  | KindFamilyNeverSentInputs !(Either InputRetirement.InputRetirementError ()) !Bool
  deriving (Eq, Show)

data KindFamilyNeverSentScopeOutcome value
  = KindFamilyNeverSentScopeRefused !String
  | KindFamilyNeverSentScopeReturned
      !value
      !(Either Publication.HostControllerPublicationError ())
      !Bool
  deriving (Eq, Show)

data KindFamilyPrePublicationOutcome value
  = KindFamilyPrePublicationRefused
  | KindFamilyPrePublicationReturned !value !Bool
  deriving (Eq, Show)

-- This owner is valid only inside the callback; the manager, provider and
-- kernel handles are borrowed from the exact recorded submission.
data KindFamilyRetirement
  = KindFamilyRetirement
      !Retirement.HostOperationRetirement
      !Inputs.HostControllerSubmissionRecord
      !BootstrapProjection
      !String
      !Word64

-- This owner identifies the separate cleanup family, not the original node
-- family. It is valid only inside the matching callback.
data KindProbeFamilyRetirement
  = KindProbeFamilyRetirement
      !Retirement.HostOperationRetirement
      !Inputs.HostControllerSubmissionRecord
      !BootstrapProjection
      !String
      !Request.ProbeRecoveryRequest
      !Word64

data KindProbeVerifierRetirement
  = KindProbeVerifierRetirement
      !Retirement.HostOperationRetirement
      !Inputs.HostControllerSubmissionRecord
      !BootstrapProjection
      !String
      !Request.ProbeAttemptVerifierRequest
      !Word64

data KindProbeSuccessorRetirement
  = KindProbeSuccessorRetirement
      !Retirement.HostOperationRetirement
      !Inputs.HostControllerSubmissionRecord
      !BootstrapProjection
      !String
      !Request.ProbeSuccessorRequest
      !Word64
  | KindProbeSuccessorNeverSent
      !Publication.HostPublicationNeverSent
      !BootstrapProjection
      !String
      !Request.ProbeSuccessorRequest
      !Word64
  | KindProbeSuccessorCancelled !BootstrapProjection !String !Request.ProbeSuccessorRequest !Word64
  | KindProbeSuccessorCancelledPublished
      !Publication.HostPublicationNeverSent
      !BootstrapProjection
      !String
      !Request.ProbeSuccessorRequest
      !Word64

data KindProbeSuccessorChainOutcome value
  = KindProbeSuccessorChainRefused !KindFamilyRecoveryError !Bool
  | KindProbeSuccessorChainUnconfirmed
  | KindProbeSuccessorChainReturned !value !Bool
  deriving (Show)

data KindFamilyRetirementOutcome value
  = KindFamilyRetirementRefused !KindFamilyRecoveryError
  | KindFamilyRetirementLeaseUnconfirmed
  | KindFamilyRetirementReturned !value !(Either Retirement.RetirementError ()) !Bool
  deriving (Eq, Show)

data KindFamilyCompletionWait value
  = KindFamilyCompletionObserved !(KindFamilyRetirementOutcome value)
  | KindFamilyCompletionDeadline !(Maybe (KindFamilyRetirementOutcome value))
  deriving (Eq, Show)

-- A busy or unconfirmed operation lease and positive observations of a
-- still-present family may be observed again. They never imply retirement;
-- an unobservable manager or other refusal remains an immediate failure.
awaitKindFamilyCompletionWith
  :: IO Word64
  -> (Int -> IO ())
  -> Word64
  -> IO (KindFamilyRetirementOutcome value)
  -> IO (KindFamilyCompletionWait value)
awaitKindFamilyCompletionWith clock delay ending observe = loop Nothing
 where
  loop previous = do
    now <- clock
    if now >= ending
      then pure (KindFamilyCompletionDeadline previous)
      else do
        outcome <- observe
        if pending outcome
          then do
            after <- clock
            if after >= ending
              then pure (KindFamilyCompletionDeadline (Just outcome))
              else do
                let micros = min 250000 ((ending - after) `div` 1000)
                if micros == 0
                  then pure (KindFamilyCompletionDeadline (Just outcome))
                  else do
                    delay (fromIntegral micros)
                    loop (Just outcome)
          else pure (KindFamilyCompletionObserved outcome)
  pending (KindFamilyRetirementRefused (KindFamilyRecoveryRetirementRefused reason)) = case reason of
    Retirement.RetirementRolePresent _ -> True
    Retirement.RetirementKernelPresent -> True
    Retirement.RetirementWorkspacePresent -> True
    Retirement.RetirementProcessingRefused Family.HostSubmissionSenderPresent -> True
    _ -> False
  pending KindFamilyRetirementLeaseUnconfirmed = True
  pending _ = False

data KindFamilyCompletionStep value
  = KindFamilyCompletionRefused
  | KindFamilyCompletionReturned !value
  | KindFamilyCompletionChangedAfter !value
  deriving (Eq, Show)

data KindFamilyNetworkEvidence
  = FamilyProbeRecorded !String
  | FamilyProbeObserved !EnforcementOutcome
  | FamilyProbeUnavailable
  deriving (Eq, Show)

data KindFamilyReadiness = KindFamilyReadiness
  { familyReadyNode :: !(Maybe String)
  , familyInitialReadiness :: !ReadinessObservation
  , familyNetworkObservation :: !(Maybe KindFamilyNetworkEvidence)
  , familyFinalReadiness :: !ReadinessObservation
  , familyFinalBinding :: !Bool
  }
  deriving (Eq, Show)

kindFamilyReadinessComplete :: KindFamilyReadiness -> Bool
kindFamilyReadinessComplete observed =
  case observed of
    KindFamilyReadiness (Just _) first (Just network) lastRead True ->
      ready first && networkComplete network && ready lastRead
    _ -> False
 where
  ready (ReadinessObserved True 1 1 _ _) = True
  ready _ = False
  networkComplete (FamilyProbeRecorded _) = True
  networkComplete (FamilyProbeObserved network) = enforcementComplete network
  networkComplete FamilyProbeUnavailable = False

-- The supplied callbacks are independent observations. Probe effects receive
-- the same retirement and lease recheck used for all other observations.
observeKindFamilyReadinessWith
  :: IO Bool
  -> IO (Maybe String)
  -> (String -> IO Bool)
  -> IO ReadinessObservation
  -> (IO Bool -> IO EnforcementOutcome)
  -> IO KindFamilyReadiness
observeKindFamilyReadinessWith stable readReceipt nodeMatches readReadiness probe =
  observeKindFamilyReadinessEvidence
    stable
    readReceipt
    nodeMatches
    readReadiness
    (fmap FamilyProbeObserved . probe)

observeKindFamilyReadinessEvidence
  :: IO Bool
  -> IO (Maybe String)
  -> (String -> IO Bool)
  -> IO ReadinessObservation
  -> (IO Bool -> IO KindFamilyNetworkEvidence)
  -> IO KindFamilyReadiness
observeKindFamilyReadinessEvidence stable readReceipt nodeMatches readReadiness probe = do
  before <- stable
  node <- if before then readReceipt else pure Nothing
  nodeReady <- maybe (pure False) nodeMatches node
  held <- stable
  initial <-
    if before && nodeReady && held
      then readReadiness
      else pure (ReadinessUnobservable "bound running node unconfirmed")
  readyForProbe <- stable
  network <- case initial of
    ReadinessObserved True 1 1 _ _ | nodeReady && readyForProbe -> Just <$> probe stable
    _ -> pure Nothing
  finalStable <- stable
  finalNode <- if finalStable then readReceipt else pure Nothing
  finalMatches <- case (node, finalNode) of
    (Just first, Just lastNode) | first == lastNode -> nodeMatches first
    _ -> pure False
  finalReadiness <-
    if finalMatches
      then readReadiness
      else pure (ReadinessUnobservable "final node identity unconfirmed")
  closingMatches <- if finalMatches then maybe (pure False) nodeMatches node else pure False
  after <- stable
  pure
    ( KindFamilyReadiness
        node
        initial
        network
        finalReadiness
        (finalStable && finalMatches && closingMatches && after)
    )

observeKindFamilyCompletion
  :: Word64
  -> BootstrapProjection
  -> String
  -> IO
       ( KindFamilyRetirementOutcome
           (Lease.KindOperationOutcome (KindFamilyCompletionStep KindFamilyReadiness))
       )
observeKindFamilyCompletion ending bootstrap operation =
  withKindFamilyCompletion ending bootstrap operation $ \stable -> do
    journal <- observeProbeJournal bootstrap operation ("prodbox-netcheck-" ++ take 12 operation) stable
    let probe = case journal of
          ProbeJournalRemovalRecorded uid -> FamilyProbeRecorded uid
          _ -> FamilyProbeUnavailable
    snapshot <- withKindKubeconfigSnapshotBound bootstrap $ \config path ->
      observeKindFamilyReadinessEvidence
        stable
        ( Receipt.controllerReceiptNode . Lease.KindOperationCallbackReturned
            <$> Receipt.observeControllerReceipt bootstrap operation stable
        )
        ( \identifier -> do
            running <-
              matchesScopedWorkerNode identifier <$> observeNodeCreateUnderLease bootstrap operation stable
            if running
              then observeNodeCaBindingUnderLease bootstrap operation identifier config stable
              else pure False
        )
        (observeKubernetesReadinessSnapshot path)
        (const (pure probe))
    pure $
      either
        ( const
            (KindFamilyReadiness Nothing ReadinessKubeconfigRefused Nothing ReadinessKubeconfigRefused False)
        )
        id
        snapshot

-- The recovery controller itself must run inside the separately identified
-- family. The original family is held retired through the cleanup, while the
-- callback repeatedly binds the API CA to its recorded running node. A return
-- does not prove retirement of the recovery controller or its descendants.
recoverKindFamilyProbeWithWorker
  :: Word64
  -> BootstrapProjection
  -> String
  -> String
  -> Subprocess.OperationSubprocesses
  -> IO (Either Family.HostOperationError ())
  -> IO (KindFamilyRetirementOutcome (Lease.KindOperationOutcome ProbeRecoveryOutcome))
recoverKindFamilyProbeWithWorker ending bootstrap operation recovery processes inputStable =
  withKindFamilyRetirement ending bootstrap operation $ \owner ->
    Lease.withRecoveredKindOperationUntil ending bootstrap operation $ \stable -> do
      receipt <- Receipt.observeControllerReceipt bootstrap operation stable
      case Receipt.controllerReceiptNode (Lease.KindOperationCallbackReturned receipt) of
        Nothing -> pure ProbeRecoveryIdentityUnconfirmed
        Just node -> do
          let originalStable = do
                input <- inputStable
                retired <- verifyKindFamilyRetirement owner stable
                pure (input == Right () && retired == Right ())
              bind config = do
                current <- Receipt.observeControllerReceipt bootstrap operation stable
                if Receipt.controllerReceiptNode (Lease.KindOperationCallbackReturned current) /= Just node
                  then pure False
                  else observeNodeCaBindingUnderLease bootstrap operation node config originalStable
          recoverRecordedProbeUnderFamily processes bootstrap operation recovery originalStable bind

-- The verifier borrows both retired predecessor families. Its own family must
-- still be independently settled before a successor accepts the readback.
recoverKindFamilyProbeAttemptWithVerifier
  :: Word64
  -> BootstrapProjection
  -> Request.ProbeAttemptVerifierRequest
  -> Subprocess.OperationSubprocesses
  -> IO (Either Family.HostOperationError ())
  -> IO
       ( KindFamilyRetirementOutcome
           (KindFamilyRetirementOutcome (Lease.KindOperationOutcome ProbeAttemptReadbackOutcome))
       )
recoverKindFamilyProbeAttemptWithVerifier ending bootstrap request processes inputStable =
  withKindFamilyRetirement ending bootstrap operation $ \originalOwner ->
    withKindProbeFamilyRetirement ending bootstrap operation $ \priorOwner ->
      Lease.withRecoveredKindOperationUntil ending bootstrap operation $ \stable -> do
        let predecessors = do
              input <- inputStable
              original <- verifyKindFamilyRetirement originalOwner stable
              prior <- verifyKindProbeFamilyRetirement priorOwner stable
              pure (input == Right () && original == Right () && prior == Right ())
        initial <- predecessors
        receipt <-
          if initial
            then Receipt.observeControllerReceipt bootstrap operation stable
            else pure Receipt.ControllerReceiptUnobservable
        case Receipt.controllerReceiptNode (Lease.KindOperationCallbackReturned receipt) of
          Nothing -> pure ProbeAttemptReadbackIdentityChanged
          Just node -> do
            let bind config = do
                  current <- Receipt.observeControllerReceipt bootstrap operation stable
                  if Receipt.controllerReceiptNode (Lease.KindOperationCallbackReturned current) /= Just node
                    then pure False
                    else observeNodeCaBindingUnderLease bootstrap operation node config predecessors
            confirmAttemptedProbeAbsenceUnderFamily processes bootstrap operation request predecessors bind
 where
  operation =
    Request.kindRequestOperation
      (Request.probeRecoveryControllerRequest (Request.probeVerifierRecoveryRequest request))

data KindProbeSuccessorWorkerOutcome
  = KindProbeSuccessorWorkerIdentityUnconfirmed
  | KindProbeSuccessorWorkerObserved
      !( KindFamilyRetirementOutcome
           ( KindFamilyRetirementOutcome
               ( KindFamilyRetirementOutcome
                   (KindProbeSuccessorChainOutcome (Lease.KindOperationOutcome ProbeAttemptReadbackOutcome))
               )
           )
       )
  deriving (Show)

recoverKindFamilyProbeWithSuccessor
  :: Word64
  -> BootstrapProjection
  -> Request.ProbeSuccessorRequest
  -> Subprocess.OperationSubprocesses
  -> IO (Either Family.HostOperationError ())
  -> IO KindProbeSuccessorWorkerOutcome
recoverKindFamilyProbeWithSuccessor ending bootstrap successor processes inputStable = do
  recorded <- Lease.withRecoveredKindOperationUntil ending bootstrap operation $ \stable -> do
    first <- Probe.observeProbeVerifierLaunch bootstrap operation namespace stable
    marker <- Probe.observeProbeVerifierPublicationAttempt bootstrap operation namespace stable
    case first of
      Probe.ProbeVerifierLaunchObserved root | marker == Probe.ProbeVerifierLaunchObserved root -> do
        chain <- Probe.observeProbeSuccessorChain bootstrap operation namespace root stable
        pure $ case chain of
          Right entries -> case reverse entries of
            latest : previous | latest == successor -> Just (root, reverse previous)
            _ -> Nothing
          _ -> Nothing
      _ -> pure Nothing
  case recorded of
    Lease.KindOperationCallbackReturned (Just (first, successors)) ->
      KindProbeSuccessorWorkerObserved
        <$> withKindFamilyRetirement
          ending
          bootstrap
          operation
          ( \originalOwner ->
              withKindProbeFamilyRetirement
                ending
                bootstrap
                operation
                ( \priorOwner ->
                    withKindProbeVerifierRetirement
                      ending
                      bootstrap
                      operation
                      ( \verifierOwner -> do
                          let admission = do
                                input <- inputStable
                                original <- verifyKindFamilyRetirement originalOwner (pure True)
                                prior <- verifyKindProbeFamilyRetirement priorOwner (pure True)
                                firstRetired <- verifyKindProbeVerifierRetirement verifierOwner (pure True)
                                pure (input == Right () && original == Right () && prior == Right () && firstRetired == Right ())
                          withKindProbeSuccessorRetirementPrefix
                            ending
                            bootstrap
                            operation
                            first
                            successors
                            successor
                            admission
                            $ \owners ->
                              Lease.withRecoveredKindOperationUntil ending bootstrap operation $ \stable -> do
                                let base = (&&) <$> stable <*> admission
                                    predecessors =
                                      verifyKindProbeSuccessorRetirementPrefix bootstrap operation first successors successor owners base
                                initial <- predecessors
                                receipt <-
                                  if initial
                                    then Receipt.observeControllerReceipt bootstrap operation stable
                                    else pure Receipt.ControllerReceiptUnobservable
                                case Receipt.controllerReceiptNode (Lease.KindOperationCallbackReturned receipt) of
                                  Nothing -> pure ProbeAttemptReadbackIdentityChanged
                                  Just node -> do
                                    let bind config = do
                                          current <- Receipt.observeControllerReceipt bootstrap operation stable
                                          if Receipt.controllerReceiptNode (Lease.KindOperationCallbackReturned current) /= Just node
                                            then pure False
                                            else observeNodeCaBindingUnderLease bootstrap operation node config predecessors
                                    confirmSuccessorProbeAbsenceUnderFamily
                                      processes
                                      bootstrap
                                      operation
                                      first
                                      successors
                                      successor
                                      predecessors
                                      bind
                      )
                )
          )
    _ -> pure KindProbeSuccessorWorkerIdentityUnconfirmed
 where
  operation =
    Request.kindRequestOperation
      ( Request.probeRecoveryControllerRequest
          (Request.probeVerifierRecoveryRequest (Request.probeSuccessorVerifier successor))
      )
  namespace = "prodbox-netcheck-" ++ take 12 operation

-- Borrow physical retirement across the caller's independent observations.
-- The callback receives a recheck for its own effect boundaries. A matching
-- result is necessary but does not itself prove Kubernetes readiness.
withKindFamilyCompletion
  :: Word64
  -> BootstrapProjection
  -> String
  -> (IO Bool -> IO value)
  -> IO (KindFamilyRetirementOutcome (Lease.KindOperationOutcome (KindFamilyCompletionStep value)))
withKindFamilyCompletion ending bootstrap operation action =
  withKindFamilyRetirement ending bootstrap operation $ \owner ->
    Lease.withRecoveredKindOperationUntil ending bootstrap operation $ \stable -> do
      retained <- Receipt.observeFamilyLaunch bootstrap operation stable
      case retained of
        Receipt.FamilyLaunchObserved request -> do
          journal <- observeProbeJournal bootstrap operation ("prodbox-netcheck-" ++ take 12 operation) stable
          let expectedDigest = Bytes.unpack (hexSha256 (Request.encodeKindControllerRequest request))
              expectedResult =
                Receipt.FamilyResult
                  Receipt.FamilyWorkerConfirmed
                  Receipt.FamilyWorkerComplete
                  Receipt.FamilyParentComplete
                  Receipt.FamilyInputComplete
                  Receipt.FamilyPostProbeComplete
                  Receipt.FamilyPostLeaseComplete
              recheck = do
                retired <- verifyKindFamilyRetirement owner stable
                matching <- Receipt.matchesRetainedFamilyRequest bootstrap request stable
                result <- Receipt.observeFamilyResult bootstrap operation stable
                currentJournal <-
                  observeProbeJournal bootstrap operation ("prodbox-netcheck-" ++ take 12 operation) stable
                recovery <-
                  Probe.observeProbeRecoveryLaunch
                    bootstrap
                    operation
                    ("prodbox-netcheck-" ++ take 12 operation)
                    stable
                publication <-
                  Probe.observeProbePublicationAttempt
                    bootstrap
                    operation
                    ("prodbox-netcheck-" ++ take 12 operation)
                    stable
                final <- stable
                pure
                  ( retired == Right ()
                      && matching
                      && result == Receipt.FamilyResultObserved expectedDigest expectedResult
                      && recovery == Probe.ProbeRecoveryLaunchMissing
                      && publication == Probe.ProbePublicationMissing
                      && case journal of ProbeJournalRemovalRecorded _ -> currentJournal == journal && final; _ -> False
                  )
          initial <- recheck
          if not initial
            then pure KindFamilyCompletionRefused
            else do
              value <- action recheck
              final <- recheck
              pure (if final then KindFamilyCompletionReturned value else KindFamilyCompletionChangedAfter value)
        _ -> pure KindFamilyCompletionRefused

-- The supplied stability check comes from the caller's currently held kind
-- operation lease. It is checked on both sides of the physical observation.
verifyKindFamilyRetirement
  :: KindFamilyRetirement -> IO Bool -> IO (Either KindFamilyRecoveryError ())
verifyKindFamilyRetirement (KindFamilyRetirement owner record bootstrap operation ending) stable = do
  before <- stable
  matched <-
    if before
      then matchedSubmission ending bootstrap operation stable
      else pure (Left KindFamilyRecoveryLeaseChanged)
  physical <- Retirement.verifyHostOperationRetirement owner
  after <- stable
  let provenance = case matched of
        Left failure -> Left failure
        Right current | current /= record -> Left KindFamilyRecoverySubmissionMismatch
        Right _ | not after -> Left KindFamilyRecoveryLeaseChanged
        Right _ -> Right ()
  pure $ case (provenance, physical) of
    (Left KindFamilyRecoveryLeaseChanged, Left failure) -> Left (KindFamilyRecoveryRetirementAndLeaseChanged failure)
    (Left cause, Left failure) -> Left (KindFamilyRecoveryProvenanceAndRetirement cause failure)
    (Left cause, Right ()) -> Left cause
    (Right (), Left failure) -> Left (KindFamilyRecoveryRetirementRefused failure)
    (Right (), Right ()) -> Right ()

-- Capture the original record under the scope lease, then borrow physical
-- retirement while downstream operations acquire their own lease. An owner
-- does not establish settlement of the superseded static controller.
withKindFamilyRetirement
  :: Word64
  -> BootstrapProjection
  -> String
  -> (KindFamilyRetirement -> IO value)
  -> IO (KindFamilyRetirementOutcome value)
withKindFamilyRetirement ending bootstrap operation action = do
  original <-
    Lease.withRecoveredKindOperationUntil
      ending
      bootstrap
      operation
      (matchedSubmission ending bootstrap operation)
  case original of
    Lease.KindOperationCallbackReturned (Left failure) -> pure (KindFamilyRetirementRefused failure)
    Lease.KindOperationCallbackReturned (Right record) -> do
      uid <- getEffectiveUserID
      observed <- Bus.withSystemdBus ending ("/run/user/" ++ show uid ++ "/bus") $ \connection -> lift $
        Retirement.withHostOperationRetirement connection record $ \owner -> do
          current <-
            Lease.withRecoveredKindOperationUntil
              ending
              bootstrap
              operation
              (matchedSubmission ending bootstrap operation)
          case current of
            Lease.KindOperationCallbackReturned (Right same) | same == record -> do
              value <- action (KindFamilyRetirement owner record bootstrap operation ending)
              physicalClosing <- Retirement.verifyHostOperationRetirement owner
              final <-
                Lease.withRecoveredKindOperationUntil
                  ending
                  bootstrap
                  operation
                  (matchedSubmission ending bootstrap operation)
              pure $
                KindFamilyRetirementReturned
                  value
                  physicalClosing
                  ( case final of
                      Lease.KindOperationCallbackReturned (Right sameFinal) -> sameFinal == record
                      _ -> False
                  )
            Lease.KindOperationCallbackReturned (Left failure) -> pure (KindFamilyRetirementRefused failure)
            _ -> pure KindFamilyRetirementLeaseUnconfirmed
      pure $ case observed of
        Left failure -> KindFamilyRetirementRefused (KindFamilyRecoveryManagerRefused failure)
        Right (Left failure) -> KindFamilyRetirementRefused (KindFamilyRecoveryRetirementRefused failure)
        Right (Right result) -> result
    _ -> pure KindFamilyRetirementLeaseUnconfirmed

-- Match the recovery locator to the distinct family's retained submission.
-- The submission record is provenance only; it does not establish processing
-- or retirement, and a missing record is never interpreted as unsent.
matchedProbeSubmission
  :: Word64
  -> BootstrapProjection
  -> String
  -> IO Bool
  -> IO
       (Either KindFamilyRecoveryError (Request.ProbeRecoveryRequest, Inputs.HostControllerSubmissionRecord))
matchedProbeSubmission ending bootstrap operation stable = do
  protocol <- observeKindFamilyIntent bootstrap
  let namespace = "prodbox-netcheck-" ++ take 12 operation
  retained <-
    if protocol == KindIntentMatches operation
      then Probe.observeProbeRecoveryLaunch bootstrap operation namespace stable
      else pure Probe.ProbeRecoveryLaunchUnobservable
  case retained of
    Probe.ProbeRecoveryLaunchMissing -> pure (Left KindFamilyRecoveryRequestMissing)
    Probe.ProbeRecoveryLaunchConflict -> pure (Left KindFamilyRecoveryRequestConflict)
    Probe.ProbeRecoveryLaunchUnobservable ->
      pure
        ( Left
            ( if protocol == KindIntentMatches operation
                then KindFamilyRecoveryRequestUnobservable
                else KindFamilyRecoveryProtocolUnconfirmed
            )
        )
    Probe.ProbeRecoveryLaunchObserved recovery -> case Request.kindProbeRecoveryKey operation (Request.probeRecoveryId recovery) of
      Nothing -> pure (Left KindFamilyRecoveryKeyInvalid)
      Just key -> do
        marker <-
          Probe.observeProbeRecord
            bootstrap
            operation
            namespace
            (Probe.ProbePublicationAttempt recovery)
            stable
        uid <- getEffectiveUserID
        let request = Request.probeRecoveryControllerRequest recovery
            path =
              Publication.hostControllerPublishedDirectory Identity.KindController uid key
                ++ "/"
                ++ Publication.hostControllerRequestName
        loaded <- Inputs.readHostControllerSubmission ending path key
        unchanged <- stable
        pure $
          if not unchanged
            then Left KindFamilyRecoveryLeaseChanged
            else
              if marker /= Probe.ProbeMatches
                then Left KindFamilyRecoverySubmissionMismatch
                else case loaded of
                  Left failure -> Left (KindFamilyRecoverySubmissionUnobservable failure)
                  Right record
                    | Inputs.hostControllerSubmissionKind record == Identity.KindController
                        && Inputs.hostControllerSubmissionKey record == key
                        && Inputs.hostControllerSubmissionWindow record == Request.kindRequestWindow request
                        && Inputs.hostControllerSubmissionDomain record == Request.kindRequestManagerDomain request
                        && Inputs.hostControllerSubmissionProvider record /= Nothing ->
                        Right (recovery, record)
                    | otherwise -> Left KindFamilyRecoverySubmissionMismatch

verifyKindProbeFamilyRetirement
  :: KindProbeFamilyRetirement -> IO Bool -> IO (Either KindFamilyRecoveryError ())
verifyKindProbeFamilyRetirement (KindProbeFamilyRetirement owner record bootstrap operation request ending) stable = do
  before <- stable
  matched <-
    if before
      then matchedProbeSubmission ending bootstrap operation stable
      else pure (Left KindFamilyRecoveryLeaseChanged)
  physical <- Retirement.verifyHostOperationRetirement owner
  after <- stable
  let provenance = case matched of
        Left failure -> Left failure
        Right current | current /= (request, record) -> Left KindFamilyRecoverySubmissionMismatch
        Right _ | not after -> Left KindFamilyRecoveryLeaseChanged
        Right _ -> Right ()
  pure $ case (provenance, physical) of
    (Left KindFamilyRecoveryLeaseChanged, Left failure) -> Left (KindFamilyRecoveryRetirementAndLeaseChanged failure)
    (Left cause, Left failure) -> Left (KindFamilyRecoveryProvenanceAndRetirement cause failure)
    (Left cause, Right ()) -> Left cause
    (Right (), Left failure) -> Left (KindFamilyRecoveryRetirementRefused failure)
    (Right (), Right ()) -> Right ()

withKindProbeFamilyRetirement
  :: Word64
  -> BootstrapProjection
  -> String
  -> (KindProbeFamilyRetirement -> IO value)
  -> IO (KindFamilyRetirementOutcome value)
withKindProbeFamilyRetirement ending bootstrap operation action = do
  original <-
    Lease.withRecoveredKindOperationUntil
      ending
      bootstrap
      operation
      (matchedProbeSubmission ending bootstrap operation)
  case original of
    Lease.KindOperationCallbackReturned (Left failure) -> pure (KindFamilyRetirementRefused failure)
    Lease.KindOperationCallbackReturned (Right expected@(request, record)) -> do
      uid <- getEffectiveUserID
      observed <- Bus.withSystemdBus ending ("/run/user/" ++ show uid ++ "/bus") $ \connection -> lift $
        Retirement.withHostOperationRetirement connection record $ \owner -> do
          current <-
            Lease.withRecoveredKindOperationUntil
              ending
              bootstrap
              operation
              (matchedProbeSubmission ending bootstrap operation)
          case current of
            Lease.KindOperationCallbackReturned (Right same) | same == expected -> do
              value <- action (KindProbeFamilyRetirement owner record bootstrap operation request ending)
              physicalClosing <- Retirement.verifyHostOperationRetirement owner
              final <-
                Lease.withRecoveredKindOperationUntil
                  ending
                  bootstrap
                  operation
                  (matchedProbeSubmission ending bootstrap operation)
              pure $
                KindFamilyRetirementReturned
                  value
                  physicalClosing
                  ( case final of
                      Lease.KindOperationCallbackReturned (Right sameFinal) -> sameFinal == expected
                      _ -> False
                  )
            Lease.KindOperationCallbackReturned (Left failure) -> pure (KindFamilyRetirementRefused failure)
            _ -> pure KindFamilyRetirementLeaseUnconfirmed
      pure $ case observed of
        Left failure -> KindFamilyRetirementRefused (KindFamilyRecoveryManagerRefused failure)
        Right (Left failure) -> KindFamilyRetirementRefused (KindFamilyRecoveryRetirementRefused failure)
        Right (Right result) -> result
    _ -> pure KindFamilyRetirementLeaseUnconfirmed

retireKindProbeFamilyPublishedInputs
  :: Word64 -> KindProbeFamilyRetirement -> IO Bool -> IO KindFamilyInputRetirement
retireKindProbeFamilyPublishedInputs ending owner@(KindProbeFamilyRetirement physical record bootstrap operation request _) stable = do
  let admission = (== Right (request, record)) <$> matchedProbeSubmission ending bootstrap operation stable
  removed <- InputRetirement.retireHostControllerInputsWithAdmission ending physical record admission
  closing <- Retirement.verifyHostOperationRetirement physical
  leaseClosing <- (== Right ()) <$> verifyKindProbeFamilyRetirement owner stable
  pure (KindFamilyInputRetirement (void removed) closing leaseClosing)

-- The verifier's distinct locator and execution key are required even after
-- readback: neither a worker return nor its record establishes retirement.
matchedProbeVerifierSubmission
  :: Word64
  -> BootstrapProjection
  -> String
  -> IO Bool
  -> IO
       ( Either
           KindFamilyRecoveryError
           (Request.ProbeAttemptVerifierRequest, Inputs.HostControllerSubmissionRecord)
       )
matchedProbeVerifierSubmission ending bootstrap operation stable = do
  protocol <- observeKindFamilyIntent bootstrap
  let namespace = "prodbox-netcheck-" ++ take 12 operation
  retained <-
    if protocol == KindIntentMatches operation
      then Probe.observeProbeVerifierLaunch bootstrap operation namespace stable
      else pure Probe.ProbeVerifierLaunchUnobservable
  case retained of
    Probe.ProbeVerifierLaunchMissing -> pure (Left KindFamilyRecoveryRequestMissing)
    Probe.ProbeVerifierLaunchConflict -> pure (Left KindFamilyRecoveryRequestConflict)
    Probe.ProbeVerifierLaunchUnobservable ->
      pure
        ( Left
            ( if protocol == KindIntentMatches operation
                then KindFamilyRecoveryRequestUnobservable
                else KindFamilyRecoveryProtocolUnconfirmed
            )
        )
    Probe.ProbeVerifierLaunchObserved verifier -> do
      let recovery = Request.probeVerifierRecoveryRequest verifier
          request = Request.probeRecoveryControllerRequest recovery
      case Request.kindProbeRecoveryKey operation (Request.probeRecoveryId recovery) of
        Nothing -> pure (Left KindFamilyRecoveryKeyInvalid)
        Just key -> do
          marker <-
            Probe.observeProbeRecord
              bootstrap
              operation
              namespace
              (Probe.ProbeVerifierPublicationAttempt verifier)
              stable
          uid <- getEffectiveUserID
          let kind =
                if Request.probeVerifierIsIsolated verifier
                  then Identity.KindProbeVerifierController
                  else Identity.KindController
              path =
                Publication.hostControllerPublishedDirectory kind uid key
                  ++ "/"
                  ++ Publication.hostControllerRequestName
          loaded <- Inputs.readHostControllerSubmission ending path key
          unchanged <- stable
          pure $
            if not unchanged
              then Left KindFamilyRecoveryLeaseChanged
              else
                if marker /= Probe.ProbeMatches
                  then Left KindFamilyRecoverySubmissionMismatch
                  else case loaded of
                    Left failure -> Left (KindFamilyRecoverySubmissionUnobservable failure)
                    Right record
                      | Inputs.hostControllerSubmissionKind record == kind
                          && Inputs.hostControllerSubmissionKey record == key
                          && Inputs.hostControllerSubmissionWindow record == Request.kindRequestWindow request
                          && Inputs.hostControllerSubmissionDomain record == Request.kindRequestManagerDomain request
                          && Inputs.hostControllerSubmissionProvider record /= Nothing ->
                          Right (verifier, record)
                      | otherwise -> Left KindFamilyRecoverySubmissionMismatch

verifyKindProbeVerifierRetirement
  :: KindProbeVerifierRetirement -> IO Bool -> IO (Either KindFamilyRecoveryError ())
verifyKindProbeVerifierRetirement (KindProbeVerifierRetirement owner record bootstrap operation request ending) stable = do
  before <- stable
  matched <-
    if before
      then matchedProbeVerifierSubmission ending bootstrap operation stable
      else pure (Left KindFamilyRecoveryLeaseChanged)
  physical <- Retirement.verifyHostOperationRetirement owner
  after <- stable
  let provenance = case matched of
        Left failure -> Left failure
        Right current | current /= (request, record) -> Left KindFamilyRecoverySubmissionMismatch
        Right _ | not after -> Left KindFamilyRecoveryLeaseChanged
        Right _ -> Right ()
  pure $ case (provenance, physical) of
    (Left KindFamilyRecoveryLeaseChanged, Left failure) -> Left (KindFamilyRecoveryRetirementAndLeaseChanged failure)
    (Left cause, Left failure) -> Left (KindFamilyRecoveryProvenanceAndRetirement cause failure)
    (Left cause, Right ()) -> Left cause
    (Right (), Left failure) -> Left (KindFamilyRecoveryRetirementRefused failure)
    (Right (), Right ()) -> Right ()

withKindProbeVerifierRetirement
  :: Word64
  -> BootstrapProjection
  -> String
  -> (KindProbeVerifierRetirement -> IO value)
  -> IO (KindFamilyRetirementOutcome value)
withKindProbeVerifierRetirement ending bootstrap operation action = do
  original <-
    Lease.withRecoveredKindOperationUntil
      ending
      bootstrap
      operation
      (matchedProbeVerifierSubmission ending bootstrap operation)
  case original of
    Lease.KindOperationCallbackReturned (Left failure) -> pure (KindFamilyRetirementRefused failure)
    Lease.KindOperationCallbackReturned (Right expected@(request, record)) -> do
      uid <- getEffectiveUserID
      observed <- Bus.withSystemdBus ending ("/run/user/" ++ show uid ++ "/bus") $ \connection -> lift $
        Retirement.withHostOperationRetirement connection record $ \owner -> do
          current <-
            Lease.withRecoveredKindOperationUntil
              ending
              bootstrap
              operation
              (matchedProbeVerifierSubmission ending bootstrap operation)
          case current of
            Lease.KindOperationCallbackReturned (Right same) | same == expected -> do
              value <- action (KindProbeVerifierRetirement owner record bootstrap operation request ending)
              physicalClosing <- Retirement.verifyHostOperationRetirement owner
              final <-
                Lease.withRecoveredKindOperationUntil
                  ending
                  bootstrap
                  operation
                  (matchedProbeVerifierSubmission ending bootstrap operation)
              pure $
                KindFamilyRetirementReturned
                  value
                  physicalClosing
                  ( case final of
                      Lease.KindOperationCallbackReturned (Right sameFinal) -> sameFinal == expected
                      _ -> False
                  )
            Lease.KindOperationCallbackReturned (Left failure) -> pure (KindFamilyRetirementRefused failure)
            _ -> pure KindFamilyRetirementLeaseUnconfirmed
      pure $ case observed of
        Left failure -> KindFamilyRetirementRefused (KindFamilyRecoveryManagerRefused failure)
        Right (Left failure) -> KindFamilyRetirementRefused (KindFamilyRecoveryRetirementRefused failure)
        Right (Right result) -> result
    _ -> pure KindFamilyRetirementLeaseUnconfirmed

retireKindProbeVerifierPublishedInputs
  :: Word64 -> KindProbeVerifierRetirement -> IO Bool -> IO KindFamilyInputRetirement
retireKindProbeVerifierPublishedInputs ending owner@(KindProbeVerifierRetirement physical record bootstrap operation request _) stable = do
  let admission = (== Right (request, record)) <$> matchedProbeVerifierSubmission ending bootstrap operation stable
  removed <- InputRetirement.retireHostControllerInputsWithAdmission ending physical record admission
  closing <- Retirement.verifyHostOperationRetirement physical
  leaseClosing <- (== Right ()) <$> verifyKindProbeVerifierRetirement owner stable
  pure (KindFamilyInputRetirement (void removed) closing leaseClosing)

-- This verifies one exact successor. The caller must also bind its complete
-- predecessor chain and hold each predecessor retirement independently.
matchedProbeSuccessorSubmission
  :: Word64
  -> BootstrapProjection
  -> String
  -> Request.ProbeSuccessorRequest
  -> IO Bool
  -> IO (Either KindFamilyRecoveryError Inputs.HostControllerSubmissionRecord)
matchedProbeSuccessorSubmission ending bootstrap operation successor stable = do
  protocol <- observeKindFamilyIntent bootstrap
  let namespace = "prodbox-netcheck-" ++ take 12 operation
      verifier = Request.probeSuccessorVerifier successor
      coordinates = Request.probeVerifierRecoveryRequest verifier
      request = Request.probeRecoveryControllerRequest coordinates
      identity = Request.probeRecoveryId coordinates
  launch <-
    if protocol == KindIntentMatches operation
      then
        Probe.observeProbeSuccessorLaunch
          bootstrap
          operation
          namespace
          (Request.probeSuccessorPredecessorId successor)
          stable
      else pure Probe.ProbeSuccessorUnobservable
  marker <- Probe.observeProbeSuccessorPublication bootstrap operation namespace identity stable
  cancelled <-
    Probe.observeProbeRecord
      bootstrap
      operation
      namespace
      (Probe.ProbeSuccessorCancellation successor)
      stable
  case Request.kindProbeRecoveryKey operation identity of
    Nothing -> pure (Left KindFamilyRecoveryKeyInvalid)
    Just key -> do
      uid <- getEffectiveUserID
      let path =
            Publication.hostControllerPublishedDirectory Identity.KindProbeSuccessorController uid key
              ++ "/"
              ++ Publication.hostControllerRequestName
      loaded <- Inputs.readHostControllerSubmission ending path key
      unchanged <- stable
      pure $
        if not unchanged
          then Left KindFamilyRecoveryLeaseChanged
          else
            if launch /= Probe.ProbeSuccessorObserved successor
              || marker /= Probe.ProbeSuccessorObserved successor
              || cancelled /= Probe.ProbeMissing
              then Left KindFamilyRecoverySubmissionMismatch
              else case loaded of
                Left failure -> Left (KindFamilyRecoverySubmissionUnobservable failure)
                Right record
                  | Inputs.hostControllerSubmissionKind record == Identity.KindProbeSuccessorController
                      && Inputs.hostControllerSubmissionKey record == key
                      && Inputs.hostControllerSubmissionWindow record == Request.kindRequestWindow request
                      && Inputs.hostControllerSubmissionDomain record == Request.kindRequestManagerDomain request
                      && Inputs.hostControllerSubmissionProvider record /= Nothing ->
                      Right record
                  | otherwise -> Left KindFamilyRecoverySubmissionMismatch

verifyKindProbeSuccessorRetirement
  :: KindProbeSuccessorRetirement -> IO Bool -> IO (Either KindFamilyRecoveryError ())
verifyKindProbeSuccessorRetirement (KindProbeSuccessorRetirement owner record bootstrap operation successor ending) stable = do
  before <- stable
  matched <-
    if before
      then matchedProbeSuccessorSubmission ending bootstrap operation successor stable
      else pure (Left KindFamilyRecoveryLeaseChanged)
  physical <- Retirement.verifyHostOperationRetirement owner
  after <- stable
  let provenance = case matched of
        Left failure -> Left failure
        Right current | current /= record -> Left KindFamilyRecoverySubmissionMismatch
        Right _ | not after -> Left KindFamilyRecoveryLeaseChanged
        Right _ -> Right ()
  pure $ case (provenance, physical) of
    (Left KindFamilyRecoveryLeaseChanged, Left failure) -> Left (KindFamilyRecoveryRetirementAndLeaseChanged failure)
    (Left cause, Left failure) -> Left (KindFamilyRecoveryProvenanceAndRetirement cause failure)
    (Left cause, Right ()) -> Left cause
    (Right (), Left failure) -> Left (KindFamilyRecoveryRetirementRefused failure)
    (Right (), Right ()) -> Right ()
verifyKindProbeSuccessorRetirement (KindProbeSuccessorNeverSent owner bootstrap operation successor ending) stable = do
  before <- stable
  provenance <-
    if before then successorLocatorMatches bootstrap operation successor stable else pure False
  proof <- Publication.verifyHostPublicationNeverSentBefore ending owner
  after <- stable
  pure $
    if not (before && provenance && after)
      then Left KindFamilyRecoveryLeaseChanged
      else either (Left . KindFamilyRecoveryNeverSentProofRefused) (const (Right ())) proof
verifyKindProbeSuccessorRetirement (KindProbeSuccessorCancelled bootstrap operation successor ending) stable = do
  matched <- successorCancellationMatches bootstrap operation successor stable
  absent <- case Request.kindProbeRecoveryKey
    operation
    ( Request.probeRecoveryId
        (Request.probeVerifierRecoveryRequest (Request.probeSuccessorVerifier successor))
    ) of
    Nothing -> pure (Left KindFamilyRecoveryKeyInvalid)
    Just key ->
      either (Left . KindFamilyRecoveryNeverSentProofRefused) Right
        <$> Publication.observeHostPublicationDirectoryAbsent ending Identity.KindProbeSuccessorController key
  after <- stable
  pure $
    if not (matched && after)
      then Left KindFamilyRecoveryLeaseChanged
      else case absent of
        Right True -> Right ()
        Right False -> Left KindFamilyRecoverySubmissionMismatch
        Left failure -> Left failure
verifyKindProbeSuccessorRetirement (KindProbeSuccessorCancelledPublished proof bootstrap operation successor ending) stable = do
  matched <- successorCancellationMatches bootstrap operation successor stable
  observed <- Publication.verifyHostPublicationNeverSentBefore ending proof
  after <- stable
  pure $
    if not (matched && after)
      then Left KindFamilyRecoveryLeaseChanged
      else either (Left . KindFamilyRecoveryNeverSentProofRefused) (const (Right ())) observed

successorCancellationMatches
  :: BootstrapProjection -> String -> Request.ProbeSuccessorRequest -> IO Bool -> IO Bool
successorCancellationMatches bootstrap operation successor stable = do
  before <- stable
  let namespace = "prodbox-netcheck-" ++ take 12 operation
      identity =
        Request.probeRecoveryId
          (Request.probeVerifierRecoveryRequest (Request.probeSuccessorVerifier successor))
  protocol <- observeKindFamilyIntent bootstrap
  launch <-
    Probe.observeProbeSuccessorLaunch
      bootstrap
      operation
      namespace
      (Request.probeSuccessorPredecessorId successor)
      stable
  marker <- Probe.observeProbeSuccessorPublication bootstrap operation namespace identity stable
  cancelled <-
    Probe.observeProbeRecord
      bootstrap
      operation
      namespace
      (Probe.ProbeSuccessorCancellation successor)
      stable
  readback <-
    Probe.observeProbeRecord
      bootstrap
      operation
      namespace
      (Probe.ProbeSuccessorReadback successor)
      stable
  after <- stable
  pure
    ( before
        && after
        && protocol == KindIntentMatches operation
        && launch == Probe.ProbeSuccessorObserved successor
        && marker == Probe.ProbeSuccessorMissing
        && cancelled == Probe.ProbeMatches
        && readback == Probe.ProbeMissing
    )

successorLocatorMatches
  :: BootstrapProjection -> String -> Request.ProbeSuccessorRequest -> IO Bool -> IO Bool
successorLocatorMatches bootstrap operation successor stable = do
  let namespace = "prodbox-netcheck-" ++ take 12 operation
      identity =
        Request.probeRecoveryId
          (Request.probeVerifierRecoveryRequest (Request.probeSuccessorVerifier successor))
  protocol <- observeKindFamilyIntent bootstrap
  launch <-
    Probe.observeProbeSuccessorLaunch
      bootstrap
      operation
      namespace
      (Request.probeSuccessorPredecessorId successor)
      stable
  marker <- Probe.observeProbeSuccessorPublication bootstrap operation namespace identity stable
  cancelled <-
    Probe.observeProbeRecord
      bootstrap
      operation
      namespace
      (Probe.ProbeSuccessorCancellation successor)
      stable
  after <- stable
  pure
    ( protocol == KindIntentMatches operation
        && launch == Probe.ProbeSuccessorObserved successor
        && marker == Probe.ProbeSuccessorObserved successor
        && cancelled == Probe.ProbeMissing
        && after
    )

withKindProbeSuccessorRetirement
  :: Word64
  -> BootstrapProjection
  -> String
  -> Request.ProbeSuccessorRequest
  -> (KindProbeSuccessorRetirement -> IO value)
  -> IO (KindFamilyRetirementOutcome value)
withKindProbeSuccessorRetirement ending bootstrap operation successor action = do
  original <-
    Lease.withRecoveredKindOperationUntil
      ending
      bootstrap
      operation
      (matchedProbeSuccessorSubmission ending bootstrap operation successor)
  case original of
    Lease.KindOperationCallbackReturned (Left failure) -> do
      cancelled <-
        Lease.withRecoveredKindOperationUntil
          ending
          bootstrap
          operation
          (successorCancellationMatches bootstrap operation successor)
      case cancelled of
        Lease.KindOperationCallbackReturned True -> do
          case Request.kindProbeRecoveryKey
            operation
            ( Request.probeRecoveryId
                (Request.probeVerifierRecoveryRequest (Request.probeSuccessorVerifier successor))
            ) of
            Nothing -> pure (KindFamilyRetirementRefused KindFamilyRecoveryKeyInvalid)
            Just key -> do
              absent <-
                Publication.observeHostPublicationDirectoryAbsent ending Identity.KindProbeSuccessorController key
              case absent of
                Left observationFailure -> pure (KindFamilyRetirementRefused (KindFamilyRecoveryNeverSentProofRefused observationFailure))
                Right True -> do
                  let owner = KindProbeSuccessorCancelled bootstrap operation successor ending
                  value <- action owner
                  closing <-
                    Lease.withRecoveredKindOperationUntil
                      ending
                      bootstrap
                      operation
                      (\stable -> verifyKindProbeSuccessorRetirement owner stable)
                  pure
                    ( KindFamilyRetirementReturned
                        value
                        (Right ())
                        (closing == Lease.KindOperationCallbackReturned (Right ()))
                    )
                Right False -> borrowCancelledPublication failure key
        _ -> borrowNeverSent failure
    Lease.KindOperationCallbackReturned (Right expected) -> do
      uid <- getEffectiveUserID
      observed <- Bus.withSystemdBus ending ("/run/user/" ++ show uid ++ "/bus") $ \connection -> lift $
        Retirement.withHostOperationRetirement connection expected $ \owner -> do
          current <-
            Lease.withRecoveredKindOperationUntil
              ending
              bootstrap
              operation
              (matchedProbeSuccessorSubmission ending bootstrap operation successor)
          case current of
            Lease.KindOperationCallbackReturned (Right same) | same == expected -> do
              value <- action (KindProbeSuccessorRetirement owner expected bootstrap operation successor ending)
              physicalClosing <- Retirement.verifyHostOperationRetirement owner
              final <-
                Lease.withRecoveredKindOperationUntil
                  ending
                  bootstrap
                  operation
                  (matchedProbeSuccessorSubmission ending bootstrap operation successor)
              pure $
                KindFamilyRetirementReturned
                  value
                  physicalClosing
                  ( case final of
                      Lease.KindOperationCallbackReturned (Right sameFinal) -> sameFinal == expected
                      _ -> False
                  )
            Lease.KindOperationCallbackReturned (Left failure) -> pure (KindFamilyRetirementRefused failure)
            _ -> pure KindFamilyRetirementLeaseUnconfirmed
      pure $ case observed of
        Left failure -> KindFamilyRetirementRefused (KindFamilyRecoveryManagerRefused failure)
        Right (Left failure) -> KindFamilyRetirementRefused (KindFamilyRecoveryRetirementRefused failure)
        Right (Right result) -> result
    _ -> pure KindFamilyRetirementLeaseUnconfirmed
 where
  borrowNeverSent originalFailure = case Request.kindProbeRecoveryKey
    operation
    ( Request.probeRecoveryId
        (Request.probeVerifierRecoveryRequest (Request.probeSuccessorVerifier successor))
    ) of
    Nothing -> pure (KindFamilyRetirementRefused KindFamilyRecoveryKeyInvalid)
    Just key -> do
      borrowed <- Publication.withRecoveredHostPublicationNeverSent Identity.KindProbeSuccessorController ending key $ \proof -> do
        initial <-
          Lease.withRecoveredKindOperationUntil
            ending
            bootstrap
            operation
            (successorLocatorMatches bootstrap operation successor)
        case initial of
          Lease.KindOperationCallbackReturned True -> do
            value <- action (KindProbeSuccessorNeverSent proof bootstrap operation successor ending)
            physical <- Publication.verifyHostPublicationNeverSentBefore ending proof
            final <-
              Lease.withRecoveredKindOperationUntil
                ending
                bootstrap
                operation
                (successorLocatorMatches bootstrap operation successor)
            pure
              ( KindFamilyRetirementReturned
                  value
                  (Right ())
                  (physical == Right () && final == Lease.KindOperationCallbackReturned True)
              )
          _ -> pure KindFamilyRetirementLeaseUnconfirmed
      pure $
        either
          (KindFamilyRetirementRefused . KindFamilyRecoverySuccessorNeverSentRefused originalFailure)
          id
          borrowed
  borrowCancelledPublication originalFailure key = do
    borrowed <- Publication.withRecoveredHostPublicationNeverSent Identity.KindProbeSuccessorController ending key $ \proof -> do
      let owner = KindProbeSuccessorCancelledPublished proof bootstrap operation successor ending
      initial <-
        Lease.withRecoveredKindOperationUntil
          ending
          bootstrap
          operation
          (\stable -> verifyKindProbeSuccessorRetirement owner stable)
      case initial of
        Lease.KindOperationCallbackReturned (Right ()) -> do
          value <- action owner
          final <-
            Lease.withRecoveredKindOperationUntil
              ending
              bootstrap
              operation
              (\stable -> verifyKindProbeSuccessorRetirement owner stable)
          pure
            ( KindFamilyRetirementReturned
                value
                (Right ())
                (final == Lease.KindOperationCallbackReturned (Right ()))
            )
        _ -> pure KindFamilyRetirementLeaseUnconfirmed
    pure $
      either
        (KindFamilyRetirementRefused . KindFamilyRecoverySuccessorNeverSentRefused originalFailure)
        id
        borrowed

retireKindProbeSuccessorPublishedInputs
  :: Word64 -> KindProbeSuccessorRetirement -> IO Bool -> IO KindFamilyInputRetirement
retireKindProbeSuccessorPublishedInputs ending owner@(KindProbeSuccessorRetirement physical record bootstrap operation successor _) stable = do
  let admission = (== Right record) <$> matchedProbeSuccessorSubmission ending bootstrap operation successor stable
  removed <- InputRetirement.retireHostControllerInputsWithAdmission ending physical record admission
  closing <- Retirement.verifyHostOperationRetirement physical
  leaseClosing <- (== Right ()) <$> verifyKindProbeSuccessorRetirement owner stable
  pure (KindFamilyInputRetirement (void removed) closing leaseClosing)
retireKindProbeSuccessorPublishedInputs ending owner@(KindProbeSuccessorNeverSent proof _ _ _ _) stable = do
  removed <- InputRetirement.retireNeverSentHostControllerInputs ending proof
  closing <- Publication.verifyHostPublicationNeverSentBefore ending proof
  leaseClosing <- (== Right ()) <$> verifyKindProbeSuccessorRetirement owner stable
  pure (KindFamilyInputRetirement (void removed) (Right ()) (closing == Right () && leaseClosing))
retireKindProbeSuccessorPublishedInputs _ owner@KindProbeSuccessorCancelled {} stable = do
  confirmed <- (== Right ()) <$> verifyKindProbeSuccessorRetirement owner stable
  pure (KindFamilyInputRetirement (Right ()) (Right ()) confirmed)
retireKindProbeSuccessorPublishedInputs ending owner@(KindProbeSuccessorCancelledPublished proof _ _ _ _) stable = do
  removed <- InputRetirement.retireNeverSentHostControllerInputs ending proof
  closing <- Publication.verifyHostPublicationNeverSentBefore ending proof
  leaseClosing <- (== Right ()) <$> verifyKindProbeSuccessorRetirement owner stable
  pure (KindFamilyInputRetirement (void removed) (Right ()) (closing == Right () && leaseClosing))

-- The supplied admission must itself hold the original, cleanup and first
-- verifier retirements. The recovered operation lease must span this check.
verifyKindProbeSuccessorRetirementChain
  :: BootstrapProjection
  -> String
  -> Request.ProbeAttemptVerifierRequest
  -> [Request.ProbeSuccessorRequest]
  -> [KindProbeSuccessorRetirement]
  -> IO Bool
  -> IO Bool
verifyKindProbeSuccessorRetirementChain bootstrap operation first successors =
  verifySuccessorRetirementSet bootstrap operation first successors Nothing

verifyKindProbeSuccessorRetirementPrefix
  :: BootstrapProjection
  -> String
  -> Request.ProbeAttemptVerifierRequest
  -> [Request.ProbeSuccessorRequest]
  -> Request.ProbeSuccessorRequest
  -> [KindProbeSuccessorRetirement]
  -> IO Bool
  -> IO Bool
verifyKindProbeSuccessorRetirementPrefix bootstrap operation first successors pending =
  verifySuccessorRetirementSet bootstrap operation first successors (Just pending)

verifySuccessorRetirementSet
  :: BootstrapProjection
  -> String
  -> Request.ProbeAttemptVerifierRequest
  -> [Request.ProbeSuccessorRequest]
  -> Maybe Request.ProbeSuccessorRequest
  -> [KindProbeSuccessorRetirement]
  -> IO Bool
  -> IO Bool
verifySuccessorRetirementSet bootstrap operation first successors pending owners stable = do
  before <- stable
  let namespace = "prodbox-netcheck-" ++ take 12 operation
      matchesOwner successor (KindProbeSuccessorRetirement _ _ _ ownerOperation held _) =
        ownerOperation == operation && held == successor
      matchesOwner successor (KindProbeSuccessorNeverSent _ _ ownerOperation held _) =
        ownerOperation == operation && held == successor
      matchesOwner successor (KindProbeSuccessorCancelled _ ownerOperation held _) =
        ownerOperation == operation && held == successor
      matchesOwner successor (KindProbeSuccessorCancelledPublished _ _ ownerOperation held _) =
        ownerOperation == operation && held == successor
  -- The complete local snapshot is bracketed by the caller's lease and
  -- predecessor admission. Nested observations still verify their own
  -- descriptors and each owner verifies its physical retirement.
  root <-
    if before
      then Probe.observeProbeVerifierLaunch bootstrap operation namespace (pure True)
      else pure Probe.ProbeVerifierLaunchUnobservable
  marker <-
    if before
      then Probe.observeProbeVerifierPublicationAttempt bootstrap operation namespace (pure True)
      else pure Probe.ProbeVerifierLaunchUnobservable
  chain <-
    if before
      then Probe.observeProbeSuccessorChain bootstrap operation namespace first (pure True)
      else pure (Left Probe.ProbeSuccessorUnobservable)
  checks <-
    if before
      then mapM (\owner -> verifyKindProbeSuccessorRetirement owner (pure True)) owners
      else pure []
  after <- stable
  let expected = successors ++ maybe [] pure pending
  pure
    ( before
        && after
        && Request.validProbeSuccessorChain first expected
        && root == Probe.ProbeVerifierLaunchObserved first
        && marker == Probe.ProbeVerifierLaunchObserved first
        && chain == Right expected
        && length successors == length owners
        && and (zipWith matchesOwner successors owners)
        && all (== Right ()) checks
    )

verifyStagedSuccessorRetirementSet
  :: BootstrapProjection
  -> String
  -> Request.ProbeAttemptVerifierRequest
  -> [Request.ProbeSuccessorRequest]
  -> Request.ProbeSuccessorRequest
  -> [KindProbeSuccessorRetirement]
  -> IO Bool
  -> IO Bool
verifyStagedSuccessorRetirementSet bootstrap operation first successors pending owners stable = do
  before <- stable
  let namespace = "prodbox-netcheck-" ++ take 12 operation
      matchesOwner successor (KindProbeSuccessorRetirement _ _ _ ownerOperation held _) = ownerOperation == operation && held == successor
      matchesOwner successor (KindProbeSuccessorNeverSent _ _ ownerOperation held _) = ownerOperation == operation && held == successor
      matchesOwner successor (KindProbeSuccessorCancelled _ ownerOperation held _) = ownerOperation == operation && held == successor
      matchesOwner successor (KindProbeSuccessorCancelledPublished _ _ ownerOperation held _) = ownerOperation == operation && held == successor
      inspect entry = do
        let identity =
              Request.probeRecoveryId
                (Request.probeVerifierRecoveryRequest (Request.probeSuccessorVerifier entry))
        launch <-
          Probe.observeProbeSuccessorLaunch
            bootstrap
            operation
            namespace
            (Request.probeSuccessorPredecessorId entry)
            (pure True)
        marker <- Probe.observeProbeSuccessorPublication bootstrap operation namespace identity (pure True)
        cancelled <-
          Probe.observeProbeRecord
            bootstrap
            operation
            namespace
            (Probe.ProbeSuccessorCancellation entry)
            (pure True)
        readback <-
          Probe.observeProbeRecord
            bootstrap
            operation
            namespace
            (Probe.ProbeSuccessorReadback entry)
            (pure True)
        pure
          ( launch == Probe.ProbeSuccessorObserved entry
              && readback == Probe.ProbeMissing
              && ( (marker == Probe.ProbeSuccessorObserved entry && cancelled == Probe.ProbeMissing)
                     || (marker == Probe.ProbeSuccessorMissing && cancelled == Probe.ProbeMatches)
                 )
          )
  root <-
    if before
      then Probe.observeProbeVerifierLaunch bootstrap operation namespace (pure True)
      else pure Probe.ProbeVerifierLaunchUnobservable
  rootMarker <-
    if before
      then Probe.observeProbeVerifierPublicationAttempt bootstrap operation namespace (pure True)
      else pure Probe.ProbeVerifierLaunchUnobservable
  previous <- if before then mapM inspect successors else pure []
  let identity =
        Request.probeRecoveryId
          (Request.probeVerifierRecoveryRequest (Request.probeSuccessorVerifier pending))
  stagedLaunch <-
    if before
      then
        Probe.observeProbeSuccessorLaunch
          bootstrap
          operation
          namespace
          (Request.probeSuccessorPredecessorId pending)
          (pure True)
      else pure Probe.ProbeSuccessorUnobservable
  stagedMarker <-
    if before
      then Probe.observeProbeSuccessorPublication bootstrap operation namespace identity (pure True)
      else pure Probe.ProbeSuccessorUnobservable
  stagedCancelled <-
    if before
      then
        Probe.observeProbeRecord
          bootstrap
          operation
          namespace
          (Probe.ProbeSuccessorCancellation pending)
          (pure True)
      else pure Probe.ProbeUnobservable
  checks <-
    if before
      then mapM (\owner -> verifyKindProbeSuccessorRetirement owner (pure True)) owners
      else pure []
  after <- stable
  pure
    ( before
        && after
        && Request.validProbeSuccessorChain first (successors ++ [pending])
        && root == Probe.ProbeVerifierLaunchObserved first
        && rootMarker == Probe.ProbeVerifierLaunchObserved first
        && and previous
        && stagedLaunch == Probe.ProbeSuccessorObserved pending
        && stagedMarker == Probe.ProbeSuccessorMissing
        && stagedCancelled == Probe.ProbeMissing
        && length successors == length owners
        && and (zipWith matchesOwner successors owners)
        && all (== Right ()) checks
    )

-- All owners remain borrowed through the callback. Each unwind preserves the
-- callback value and flags a failed physical or scope closing observation.
withKindProbeSuccessorRetirementChain
  :: Word64
  -> BootstrapProjection
  -> String
  -> Request.ProbeAttemptVerifierRequest
  -> [Request.ProbeSuccessorRequest]
  -> IO Bool
  -> ([KindProbeSuccessorRetirement] -> IO value)
  -> IO (KindProbeSuccessorChainOutcome value)
withKindProbeSuccessorRetirementChain ending bootstrap operation first successors =
  withSuccessorRetirementSet ending bootstrap operation first successors Nothing Nothing False

withKindProbeSuccessorRetirementPrefix
  :: Word64
  -> BootstrapProjection
  -> String
  -> Request.ProbeAttemptVerifierRequest
  -> [Request.ProbeSuccessorRequest]
  -> Request.ProbeSuccessorRequest
  -> IO Bool
  -> ([KindProbeSuccessorRetirement] -> IO value)
  -> IO (KindProbeSuccessorChainOutcome value)
withKindProbeSuccessorRetirementPrefix ending bootstrap operation first successors pending =
  withSuccessorRetirementSet ending bootstrap operation first successors (Just pending) Nothing False

-- A publisher holds the same predecessor owners while the observed chain
-- changes from the old terminal link to the newly published link. A partial
-- publication remains unconfirmed and retains its primary result.
withKindProbeSuccessorRetirementTransition
  :: Word64
  -> BootstrapProjection
  -> String
  -> Request.ProbeAttemptVerifierRequest
  -> [Request.ProbeSuccessorRequest]
  -> Request.ProbeSuccessorRequest
  -> IO Bool
  -> ([KindProbeSuccessorRetirement] -> IO value)
  -> IO (KindProbeSuccessorChainOutcome value)
withKindProbeSuccessorRetirementTransition ending bootstrap operation first successors pending =
  withSuccessorRetirementSet ending bootstrap operation first successors Nothing (Just pending) False

withKindProbeSuccessorRetirementStaged
  :: Word64
  -> BootstrapProjection
  -> String
  -> Request.ProbeAttemptVerifierRequest
  -> [Request.ProbeSuccessorRequest]
  -> Request.ProbeSuccessorRequest
  -> IO Bool
  -> ([KindProbeSuccessorRetirement] -> IO value)
  -> IO (KindProbeSuccessorChainOutcome value)
withKindProbeSuccessorRetirementStaged ending bootstrap operation first successors pending =
  withSuccessorRetirementSet ending bootstrap operation first successors Nothing (Just pending) True

withSuccessorRetirementSet
  :: Word64
  -> BootstrapProjection
  -> String
  -> Request.ProbeAttemptVerifierRequest
  -> [Request.ProbeSuccessorRequest]
  -> Maybe Request.ProbeSuccessorRequest
  -> Maybe Request.ProbeSuccessorRequest
  -> Bool
  -> IO Bool
  -> ([KindProbeSuccessorRetirement] -> IO value)
  -> IO (KindProbeSuccessorChainOutcome value)
withSuccessorRetirementSet ending bootstrap operation first successors pending transition staged admission action
  | not
      ( Request.validProbeSuccessorChain
          first
          (successors ++ maybe [] pure pending ++ maybe [] pure transition)
      ) =
      pure KindProbeSuccessorChainUnconfirmed
  | otherwise = borrow [] successors
 where
  borrow owners [] = do
    checked <- Lease.withRecoveredKindOperationUntil ending bootstrap operation $ \stable ->
      entryCheck owners ((&&) <$> stable <*> admission)
    case checked of
      Lease.KindOperationCallbackReturned True -> do
        value <- action owners
        closing <- Lease.withRecoveredKindOperationUntil ending bootstrap operation $ \stable ->
          do
            let held = (&&) <$> stable <*> admission
            unchanged <- entryCheck owners held
            advanced <- case transition of
              Nothing -> pure False
              Just next -> verifySuccessorRetirementSet bootstrap operation first successors (Just next) owners held
            pure (unchanged || advanced)
        pure (KindProbeSuccessorChainReturned value (closing == Lease.KindOperationCallbackReturned True))
      _ -> pure KindProbeSuccessorChainUnconfirmed
  borrow owners (successor : rest) = do
    borrowed <- withKindProbeSuccessorRetirement ending bootstrap operation successor $ \owner ->
      borrow (owners ++ [owner]) rest
    pure $ case borrowed of
      KindFamilyRetirementRefused failure -> KindProbeSuccessorChainRefused failure True
      KindFamilyRetirementLeaseUnconfirmed -> KindProbeSuccessorChainUnconfirmed
      KindFamilyRetirementReturned result closing scope -> case result of
        KindProbeSuccessorChainRefused failure held -> KindProbeSuccessorChainRefused failure (held && closing == Right () && scope)
        KindProbeSuccessorChainUnconfirmed -> KindProbeSuccessorChainUnconfirmed
        KindProbeSuccessorChainReturned value held -> KindProbeSuccessorChainReturned value (held && closing == Right () && scope)
  entryCheck owners held = case (staged, transition) of
    (True, Just next) -> verifyStagedSuccessorRetirementSet bootstrap operation first successors next owners held
    (True, Nothing) -> pure False
    (False, _) -> verifySuccessorRetirementSet bootstrap operation first successors pending owners held

-- No replacement is authorized by this observation. Both predecessor
-- retirements remain borrowed while proving that this verifier could not send.
recoverNeverSentKindProbeVerifierInputs
  :: Word64
  -> BootstrapProjection
  -> String
  -> IO
       ( KindFamilyRetirementOutcome
           (KindFamilyRetirementOutcome (Lease.KindOperationOutcome KindProbeVerifierNeverSentOutcome))
       )
recoverNeverSentKindProbeVerifierInputs ending bootstrap operation =
  withKindFamilyRetirement ending bootstrap operation $ \originalOwner ->
    withKindProbeFamilyRetirement ending bootstrap operation $ \priorOwner ->
      Lease.withRecoveredKindOperation bootstrap operation $ \stable -> do
        let namespace = "prodbox-netcheck-" ++ take 12 operation
            admitted = do
              original <- verifyKindFamilyRetirement originalOwner stable
              prior <- verifyKindProbeFamilyRetirement priorOwner stable
              pure (original == Right () && prior == Right ())
        before <- admitted
        launch <- Probe.observeProbeVerifierLaunch bootstrap operation namespace admitted
        journal <- observeProbeJournal bootstrap operation namespace admitted
        case (before, launch, journal) of
          ( True
            , Probe.ProbeVerifierLaunchObserved request
            , ProbeJournalVerifierPending uid prior verifierId published
            )
              | let recovery = Request.probeVerifierRecoveryRequest request
              , uid == Request.probeRecoveryNamespaceUid recovery
              , prior == Request.probeVerifierPriorId request
              , verifierId == Request.probeRecoveryId recovery -> do
                  result <-
                    if not published
                      then pure Nothing
                      else case Request.kindProbeRecoveryKey operation verifierId of
                        Nothing -> pure (Just (Left InputRetirement.InputRetirementRecordMismatch))
                        Just key ->
                          Just . void
                            <$> InputRetirement.recoverNeverSentHostControllerInputs
                              ending
                              ( if Request.probeVerifierIsIsolated request
                                  then Identity.KindProbeVerifierController
                                  else Identity.KindController
                              )
                              key
                  original <- verifyKindFamilyRetirement originalOwner stable
                  previous <- verifyKindProbeFamilyRetirement priorOwner stable
                  retained <- Probe.observeProbeVerifierLaunch bootstrap operation namespace admitted
                  finalJournal <- observeProbeJournal bootstrap operation namespace admitted
                  final <- admitted
                  let unchanged = retained == Probe.ProbeVerifierLaunchObserved request && finalJournal == journal && final
                  pure $ case result of
                    Nothing -> KindProbeVerifierNeverSentBeforePublication original previous unchanged
                    Just removed -> KindProbeVerifierNeverSentInputs removed original previous unchanged
          _ -> pure KindProbeVerifierNeverSentIdentityUnconfirmed

-- A missing publication or submission is not evidence of no send. This can
-- retire only a recoverable publication whose durable birth and send latch
-- independently establish never-sent, while the original family is retired.
-- The locator remains in place and this outcome alone does not authorize a
-- replacement cleanup family.
retireNeverSentKindProbeInputs
  :: Word64
  -> KindFamilyRetirement
  -> BootstrapProjection
  -> String
  -> IO Bool
  -> IO KindProbeNeverSentOutcome
retireNeverSentKindProbeInputs ending owner@(KindFamilyRetirement _ _ ownerBootstrap ownerOperation _) bootstrap operation stable
  | ownerBootstrap /= bootstrap || ownerOperation /= operation =
      pure KindProbeNeverSentIdentityUnconfirmed
  | otherwise = do
      let namespace = "prodbox-netcheck-" ++ take 12 operation
          admitted = (== Right ()) <$> verifyKindFamilyRetirement owner stable
      before <- admitted
      launch <- Probe.observeProbeRecoveryLaunch bootstrap operation namespace admitted
      journal <- observeProbeJournal bootstrap operation namespace admitted
      case (before, launch, journal) of
        (True, Probe.ProbeRecoveryLaunchObserved request, ProbeJournalRemovalMissing uid)
          | uid == Request.probeRecoveryNamespaceUid request ->
              do
                marker <-
                  Probe.observeProbeRecord
                    bootstrap
                    operation
                    namespace
                    (Probe.ProbePublicationAttempt request)
                    admitted
                case marker of
                  Probe.ProbeMissing -> do
                    closing <- verifyKindFamilyRetirement owner stable
                    retained <- Probe.observeProbeRecoveryLaunch bootstrap operation namespace admitted
                    finalMarker <-
                      Probe.observeProbeRecord
                        bootstrap
                        operation
                        namespace
                        (Probe.ProbePublicationAttempt request)
                        admitted
                    finalJournal <- observeProbeJournal bootstrap operation namespace admitted
                    final <- stable
                    pure
                      ( KindProbeNeverSentBeforePublication
                          closing
                          ( retained == Probe.ProbeRecoveryLaunchObserved request
                              && finalMarker == Probe.ProbeMissing
                              && finalJournal == journal
                              && final
                          )
                      )
                  Probe.ProbeMatches -> case Request.kindProbeRecoveryKey operation (Request.probeRecoveryId request) of
                    Nothing -> pure KindProbeNeverSentIdentityUnconfirmed
                    Just key -> do
                      removed <- InputRetirement.recoverNeverSentHostControllerInputs ending Identity.KindController key
                      closing <- verifyKindFamilyRetirement owner stable
                      retained <- Probe.observeProbeRecoveryLaunch bootstrap operation namespace admitted
                      finalJournal <- observeProbeJournal bootstrap operation namespace admitted
                      final <- stable
                      pure
                        ( KindProbeNeverSentInputs
                            (void removed)
                            closing
                            (retained == Probe.ProbeRecoveryLaunchObserved request && finalJournal == journal && final)
                        )
                  _ -> pure KindProbeNeverSentIdentityUnconfirmed
        _ -> pure KindProbeNeverSentIdentityUnconfirmed

recoverNeverSentKindProbeInputs
  :: Word64
  -> BootstrapProjection
  -> String
  -> IO (KindFamilyRetirementOutcome (Lease.KindOperationOutcome KindProbeNeverSentOutcome))
recoverNeverSentKindProbeInputs ending bootstrap operation =
  withKindFamilyRetirement ending bootstrap operation $ \owner ->
    Lease.withRecoveredKindOperation
      bootstrap
      operation
      (retireNeverSentKindProbeInputs ending owner bootstrap operation)

-- Only the publisher's durable never-sent proof authorizes input retirement.
-- The scope lease, family request and absence of legacy submission are
-- rechecked around it. This does not establish node or dependent absence.
recoverNeverSentKindFamilyInputs
  :: Word64
  -> BootstrapProjection
  -> String
  -> IO (Lease.KindOperationOutcome KindFamilyNeverSentOutcome)
recoverNeverSentKindFamilyInputs ending bootstrap operation =
  Lease.withRecoveredKindOperation bootstrap operation $ \stable -> do
    request <- Receipt.observeFamilyLaunch bootstrap operation stable
    legacy <- Receipt.observeRetainedControllerSubmission bootstrap operation stable
    case (request, legacy, Request.kindControllerOperationKey operation) of
      (Receipt.FamilyLaunchObserved retained, Receipt.RetainedControllerSubmissionMissing, Just key) -> do
        before <- Receipt.matchesRetainedFamilyRequest bootstrap retained stable
        if not before
          then pure KindFamilyNeverSentIdentityUnconfirmed
          else do
            marker <- Receipt.observeFamilyPublicationAttempt bootstrap operation stable
            case marker of
              Receipt.FamilyLaunchMissing -> do
                stillRetained <- Receipt.matchesRetainedFamilyRequest bootstrap retained stable
                finalMarker <- Receipt.observeFamilyPublicationAttempt bootstrap operation stable
                finalLegacy <- Receipt.observeRetainedControllerSubmission bootstrap operation stable
                final <- stable
                pure
                  ( KindFamilyNeverSentBeforePublication
                      ( stillRetained
                          && finalMarker == Receipt.FamilyLaunchMissing
                          && finalLegacy == Receipt.RetainedControllerSubmissionMissing
                          && final
                      )
                  )
              Receipt.FamilyLaunchObserved current | current == retained -> do
                removed <- InputRetirement.recoverNeverSentHostControllerInputs ending Identity.KindController key
                stillRetained <- Receipt.matchesRetainedFamilyRequest bootstrap retained stable
                finalMarker <- Receipt.observeFamilyPublicationAttempt bootstrap operation stable
                finalLegacy <- Receipt.observeRetainedControllerSubmission bootstrap operation stable
                final <- stable
                pure
                  ( KindFamilyNeverSentInputs
                      (void removed)
                      ( stillRetained
                          && finalMarker == Receipt.FamilyLaunchObserved retained
                          && finalLegacy == Receipt.RetainedControllerSubmissionMissing
                          && final
                      )
                  )
              _ -> pure KindFamilyNeverSentIdentityUnconfirmed
      _ -> pure KindFamilyNeverSentIdentityUnconfirmed

-- Borrow the publisher's durable never-sent proof across downstream actions.
-- The caller must recheck the supplied admission inside each effect lease.
withNeverSentKindFamily
  :: Word64
  -> BootstrapProjection
  -> String
  -> ((IO Bool -> IO Bool) -> IO value)
  -> IO (KindFamilyNeverSentScopeOutcome value)
withNeverSentKindFamily ending bootstrap operation action = do
  initial <- Lease.withRecoveredKindOperation bootstrap operation $ \stable -> do
    request <- Receipt.observeFamilyLaunch bootstrap operation stable
    legacy <- Receipt.observeRetainedControllerSubmission bootstrap operation stable
    marker <- Receipt.observeFamilyPublicationAttempt bootstrap operation stable
    cancelled <- Receipt.observeFamilyPrePublicationCancellation bootstrap operation stable
    final <- stable
    pure $ case (request, legacy, marker, cancelled, final) of
      ( Receipt.FamilyLaunchObserved retained
        , Receipt.RetainedControllerSubmissionMissing
        , Receipt.FamilyLaunchObserved attempted
        , Receipt.FamilyLaunchMissing
        , True
        )
          | retained == attempted -> Just retained
      _ -> Nothing
  case (initial, Request.kindControllerOperationKey operation) of
    (Lease.KindOperationCallbackReturned (Just request), Just key) -> do
      borrowed <- Publication.withRecoveredHostPublicationNeverSent Identity.KindController ending key $ \owner -> do
        let admission stable = do
              before <- stable
              physical <- Publication.verifyHostPublicationNeverSentBefore ending owner
              matching <- Receipt.matchesRetainedFamilyRequest bootstrap request stable
              marker <- Receipt.observeFamilyPublicationAttempt bootstrap operation stable
              cancelled <- Receipt.observeFamilyPrePublicationCancellation bootstrap operation stable
              legacy <- Receipt.observeRetainedControllerSubmission bootstrap operation stable
              final <- stable
              pure
                ( before
                    && physical == Right ()
                    && matching
                    && marker == Receipt.FamilyLaunchObserved request
                    && cancelled == Receipt.FamilyLaunchMissing
                    && legacy == Receipt.RetainedControllerSubmissionMissing
                    && final
                )
        retired <- Lease.withRecoveredKindOperation bootstrap operation $ \stable -> do
          admitted <- admission stable
          if admitted
            then InputRetirement.retireNeverSentHostControllerInputs ending owner
            else
              pure
                (Left (InputRetirement.InputRetirementPublicationRefused Publication.ControllerPublicationChanged))
        case retired of
          Lease.KindOperationCallbackReturned (Right _) -> do
            value <- action admission
            closing <- Publication.verifyHostPublicationNeverSentBefore ending owner
            final <- Lease.withRecoveredKindOperation bootstrap operation admission
            pure
              (KindFamilyNeverSentScopeReturned value closing (final == Lease.KindOperationCallbackReturned True))
          _ -> pure (KindFamilyNeverSentScopeRefused "never-sent input retirement unconfirmed")
      pure $ either (KindFamilyNeverSentScopeRefused . show) id borrowed
    _ -> pure (KindFamilyNeverSentScopeRefused "family request, publication marker or lease unconfirmed")

-- The exclusive cancellation is durable before the callback. The launcher
-- checks it under the same lease before publication, so later effects can
-- borrow rechecks without keeping a non-reentrant lease across the callback.
withCancelledPrePublicationKindFamily
  :: BootstrapProjection
  -> String
  -> ((IO Bool -> IO Bool) -> IO value)
  -> IO (KindFamilyPrePublicationOutcome value)
withCancelledPrePublicationKindFamily bootstrap operation =
  withCancelledPrePublicationKindFamilyUsing bootstrap operation Nothing

-- Only owner-first operations promise that prerequisite effects cannot run
-- before a family launch. Older family records require worker settlement.
withCancelledUnlaunchedOwnerFamily
  :: BootstrapProjection
  -> Request.KindControllerRequest
  -> ((IO Bool -> IO Bool) -> IO value)
  -> IO (KindFamilyPrePublicationOutcome value)
withCancelledUnlaunchedOwnerFamily bootstrap request =
  withCancelledPrePublicationKindFamilyUsing
    bootstrap
    (Request.kindRequestOperation request)
    (Just request)

withCancelledPrePublicationKindFamilyUsing
  :: BootstrapProjection
  -> String
  -> Maybe Request.KindControllerRequest
  -> ((IO Bool -> IO Bool) -> IO value)
  -> IO (KindFamilyPrePublicationOutcome value)
withCancelledPrePublicationKindFamilyUsing bootstrap operation candidate action = do
  prepared <- Lease.withRecoveredKindOperation bootstrap operation $ \stable -> do
    observed <- Receipt.observeFamilyLaunch bootstrap operation stable
    request <- case (observed, candidate) of
      (Receipt.FamilyLaunchMissing, Just proposed) -> do
        owner <- observeKindOwnerFamilyIntent bootstrap
        marker <- Receipt.observeFamilyPublicationAttempt bootstrap operation stable
        cancelled <- Receipt.observeFamilyPrePublicationCancellation bootstrap operation stable
        before <- stable
        if owner /= KindIntentMatches operation
          || marker /= Receipt.FamilyLaunchMissing
          || cancelled /= Receipt.FamilyLaunchMissing
          || not before
          then pure Receipt.FamilyLaunchUnobservable
          else do
            written <- Receipt.recordFamilyLaunch bootstrap proposed stable
            after <- stable
            if written == Receipt.FamilyLaunchRecorded && after
              then pure (Receipt.FamilyLaunchObserved proposed)
              else pure Receipt.FamilyLaunchUnobservable
      (Receipt.FamilyLaunchMissing, Nothing) -> pure Receipt.FamilyLaunchMissing
      (other, Nothing) -> pure other
      _ -> pure Receipt.FamilyLaunchUnobservable
    case request of
      Receipt.FamilyLaunchObserved retained -> do
        marker <- Receipt.observeFamilyPublicationAttempt bootstrap operation stable
        owner <- observeKindOwnerFamilyIntent bootstrap
        external <- observeKindExternalFamilyIntent bootstrap
        let protocol = case (owner, external) of
              (KindIntentMatches current, _) | current == operation -> Just True
              (_, KindIntentMatches current) | current == operation && candidate == Nothing -> Just False
              _ -> Nothing
        if marker /= Receipt.FamilyLaunchMissing || protocol == Nothing
          then pure Nothing
          else do
            cancelled <- Receipt.recordFamilyPrePublicationCancellation bootstrap retained stable
            current <- Receipt.observeFamilyPrePublicationCancellation bootstrap operation stable
            final <- stable
            finalProtocol <- case protocol of
              Just True -> (== KindIntentMatches operation) <$> observeKindOwnerFamilyIntent bootstrap
              Just False -> (== KindIntentMatches operation) <$> observeKindExternalFamilyIntent bootstrap
              Nothing -> pure False
            pure $
              if cancelled `elem` [Receipt.FamilyLaunchRecorded, Receipt.FamilyLaunchAlreadyExists]
                && current == Receipt.FamilyLaunchObserved retained
                && final
                && finalProtocol
                then fmap (retained,) protocol
                else Nothing
      _ -> pure Nothing
  case prepared of
    Lease.KindOperationCallbackReturned (Just (request, ownerFirst)) -> do
      let admission stable = do
            before <- stable
            protocol <-
              if ownerFirst
                then (== KindIntentMatches operation) <$> observeKindOwnerFamilyIntent bootstrap
                else (== KindIntentMatches operation) <$> observeKindExternalFamilyIntent bootstrap
            matching <- Receipt.matchesRetainedFamilyRequest bootstrap request stable
            marker <- Receipt.observeFamilyPublicationAttempt bootstrap operation stable
            cancelled <- Receipt.observeFamilyPrePublicationCancellation bootstrap operation stable
            legacy <- Receipt.observeRetainedControllerSubmission bootstrap operation stable
            final <- stable
            pure
              ( before
                  && protocol
                  && matching
                  && marker == Receipt.FamilyLaunchMissing
                  && cancelled == Receipt.FamilyLaunchObserved request
                  && legacy == Receipt.RetainedControllerSubmissionMissing
                  && final
              )
      value <- action admission
      final <- Lease.withRecoveredKindOperation bootstrap operation admission
      pure (KindFamilyPrePublicationReturned value (final == Lease.KindOperationCallbackReturned True))
    _ -> pure KindFamilyPrePublicationRefused

-- Must be called while holding the recovered lease. The submission metadata
-- records the original sender, provider and exact published inode versions.
matchedSubmission
  :: Word64
  -> BootstrapProjection
  -> String
  -> IO Bool
  -> IO (Either KindFamilyRecoveryError Inputs.HostControllerSubmissionRecord)
matchedSubmission ending bootstrap operation stable = do
  protocol <- observeKindFamilyIntent bootstrap
  retained <-
    if protocol == KindIntentMatches operation
      then Receipt.observeFamilyLaunch bootstrap operation stable
      else pure Receipt.FamilyLaunchUnobservable
  case retained of
    Receipt.FamilyLaunchMissing -> pure (Left KindFamilyRecoveryRequestMissing)
    Receipt.FamilyLaunchConflict -> pure (Left KindFamilyRecoveryRequestConflict)
    Receipt.FamilyLaunchUnobservable ->
      pure
        ( Left
            ( if protocol == KindIntentMatches operation
                then KindFamilyRecoveryRequestUnobservable
                else KindFamilyRecoveryProtocolUnconfirmed
            )
        )
    Receipt.FamilyLaunchObserved request -> case Request.kindControllerOperationKey operation of
      Nothing -> pure (Left KindFamilyRecoveryKeyInvalid)
      Just key -> do
        marker <- Receipt.observeFamilyPublicationAttempt bootstrap operation stable
        cancelled <- Receipt.observeFamilyPrePublicationCancellation bootstrap operation stable
        uid <- getEffectiveUserID
        let path =
              Publication.hostControllerPublishedDirectory Identity.KindController uid key
                ++ "/"
                ++ Publication.hostControllerRequestName
        loaded <- Inputs.readHostControllerSubmission ending path key
        unchanged <- stable
        pure $
          if not unchanged
            then Left KindFamilyRecoveryLeaseChanged
            else
              if marker /= Receipt.FamilyLaunchObserved request || cancelled /= Receipt.FamilyLaunchMissing
                then Left KindFamilyRecoverySubmissionMismatch
                else case loaded of
                  Left failure -> Left (KindFamilyRecoverySubmissionUnobservable failure)
                  Right record
                    | Inputs.hostControllerSubmissionKind record == Identity.KindController
                        && Inputs.hostControllerSubmissionKey record == key
                        && Inputs.hostControllerSubmissionWindow record == Request.kindRequestWindow request
                        && Inputs.hostControllerSubmissionDomain record == Request.kindRequestManagerDomain request
                        && Inputs.hostControllerSubmissionProvider record /= Nothing ->
                        Right record
                    | otherwise -> Left KindFamilyRecoverySubmissionMismatch

-- This is only provenance; even a matching record does not prove a send,
-- method processing, worker exit, physical absence or payload retirement.
observeKindFamilySubmission
  :: Word64
  -> BootstrapProjection
  -> String
  -> IO (Lease.KindOperationOutcome (Either KindFamilyRecoveryError KindFamilySubmissionObservation))
observeKindFamilySubmission ending bootstrap operation =
  Lease.withRecoveredKindOperation bootstrap operation $ \stable ->
    fmap
      (fmap (const KindFamilySubmissionRecorded))
      (matchedSubmission ending bootstrap operation stable)

observeKindFamilySubmissionStatus :: BootstrapProjection -> IO String
observeKindFamilySubmissionStatus bootstrap = do
  intent <- observeKindIntent bootstrap
  case intent of
    KindIntentMatches operation -> do
      now <- getMonotonicTimeNSec
      observed <- Lease.withRecoveredKindOperation bootstrap operation $ \stable -> do
        launch <- Receipt.observeFamilyLaunch bootstrap operation stable
        marker <- Receipt.observeFamilyPublicationAttempt bootstrap operation stable
        cancellation <- Receipt.observeFamilyPrePublicationCancellation bootstrap operation stable
        submission <- matchedSubmission (now + 2000000000) bootstrap operation stable
        pure
          ( classifyKindFamilyPublication launch marker cancellation
          , fmap (const KindFamilySubmissionRecorded) submission
          )
      pure $
        "Kind family submission " ++ operation ++ ": " ++ case observed of
          Lease.KindOperationCallbackReturned (publication, result) -> show publication ++ "; " ++ show result ++ "; send and retirement not established.\n"
          _ -> "operation lease or provenance unconfirmed; send and retirement not established.\n"
    _ ->
      pure
        "Kind family submission: operation identity unavailable; send and retirement not established.\n"

retireKindFamilyPublishedInputs
  :: Word64 -> KindFamilyRetirement -> IO Bool -> IO KindFamilyInputRetirement
retireKindFamilyPublishedInputs ending (KindFamilyRetirement owner record bootstrap operation _) stable = do
  let admission = (== Right record) <$> matchedSubmission ending bootstrap operation stable
  removed <- InputRetirement.retireHostControllerInputsWithAdmission ending owner record admission
  closing <- Retirement.verifyHostOperationRetirement owner
  leaseClosing <- stable
  pure (KindFamilyInputRetirement (void removed) closing leaseClosing)

-- A fresh deadline funds only recovery and exact input retirement. The held
-- manager/provider/kernel owner establishes processed sender and family
-- absence independently; no missing record is interpreted as never sent.
retireKindFamilyInputs
  :: Word64
  -> BootstrapProjection
  -> String
  -> IO (Lease.KindOperationOutcome (Either KindFamilyRecoveryError KindFamilyInputRetirement))
retireKindFamilyInputs ending bootstrap operation =
  Lease.withRecoveredKindOperation bootstrap operation $ \stable -> do
    matched <- matchedSubmission ending bootstrap operation stable
    case matched of
      Left failure -> pure (Left failure)
      Right record -> do
        uid <- getEffectiveUserID
        connected <- Bus.withSystemdBus ending ("/run/user/" ++ show uid ++ "/bus") $ \connection -> lift $
          Retirement.withHostOperationRetirement connection record $ \owner -> do
            before <- stable
            if not before
              then pure (Left KindFamilyRecoveryLeaseChanged)
              else do
                Right
                  <$> retireKindFamilyPublishedInputs
                    ending
                    (KindFamilyRetirement owner record bootstrap operation ending)
                    stable
        pure $ case connected of
          Left failure -> Left (KindFamilyRecoveryManagerRefused failure)
          Right (Left failure) -> Left (KindFamilyRecoveryRetirementRefused failure)
          Right (Right result) -> result
