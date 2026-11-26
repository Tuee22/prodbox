{-# LANGUAGE OverloadedStrings #-}

-- | Observe whether the cluster's pod network enforces NetworkPolicy, with
-- real TCP connections and a positive control. In a throwaway namespace a
-- server pod accepts connections; before any policy both a client labelled
-- allowed and one labelled other must connect (the observer works); after an
-- ingress policy that admits only the allowed label, the allowed client must
-- still connect and the other must not; after the policy is deleted the
-- other client must connect again (the policy, not something else, was the
-- cause). The namespace is deleted afterwards and that result is reported
-- separately. Every image is one that ships in the pinned node image and is
-- run with pull policy Never, so nothing is pulled. A successful policy apply
-- is not evidence: only the four connection observations are.
module Prodbox.Control.NetworkEnforcement
  ( EnforcementObservation (..)
  , EnforcementCleanup (..)
  , renderEnforcementCleanup
  , enforcementComplete
  , EnforcementOutcome (..)
  , clientProbeScript
  , observeNetworkEnforcementScoped
  , observeNetworkEnforcementUnderLease
  , observeNetworkEnforcementUnderBoundLease
  , observeNetworkEnforcementUnderFamily
  , observeNetworkEnforcementWith
  , observeNetworkEnforcementRecorded
  , withProbeRecordAdmission
  , observeReconcileProbeRecords
  , ProbePublicationState (..)
  , classifyProbePublication
  , ProbeJournalObservation (..)
  , observeProbeJournal
  , ProbeRecoveryOutcome (..)
  , recoverRecordedProbeWith
  , recoverRecordedProbeUnderFamily
  , ProbeAttemptReadbackOutcome (..)
  , confirmAttemptedProbeAbsenceWith
  , confirmAttemptedProbeAbsenceUnderFamily
  , confirmSuccessorProbeAbsenceUnderFamily
  , createdNamespaceUid
  , enforcementProven
  ) where

import Control.Concurrent (threadDelay)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither, (.:))
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAsciiLower, isDigit)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Config.BootstrapProjection (BootstrapProjection)
import Prodbox.Config.DeploymentScope (validRootGeneration)
import Prodbox.Control.KindControllerRequest
  ( ProbeAttemptVerifierRequest
  , kindProbeRecoveryKey
  , kindRequestOperation
  , kindRequestWindow
  , probeRecoveryControllerRequest
  , probeRecoveryId
  , probeRecoveryNamespaceUid
  , probeVerifierPriorId
  , probeVerifierRecoveryRequest
  )
import Prodbox.Control.KindControllerRequest qualified as Request
import Prodbox.Control.KindIntent (KindIntentObservation (KindIntentMatches), observeKindIntent)
import Prodbox.Control.KindKubeconfig (KindKubeconfig)
import Prodbox.Control.KindKubeconfigFile (withKindKubeconfigSnapshotBound)
import Prodbox.Control.KindKubeconfigYaml (decodeBoundedYamlValue)
import Prodbox.Control.KindLease
  ( KindOperationOutcome (KindOperationCallbackReturned)
  , withRecoveredKindOperation
  )
import Prodbox.Control.KindNetworkProbeRecord
  ( ProbeAttemptReadbackObservation (..)
  , ProbeCreatedObservation (..)
  , ProbePublicationObservation (..)
  , ProbeRecord (..)
  , ProbeRecordObservation (..)
  , ProbeRecordWrite (..)
  , ProbeRecoveryLaunchObservation (..)
  , ProbeRemovalAttemptObservation (..)
  , ProbeRemovalFailureObservation (..)
  , ProbeSuccessorObservation (..)
  , ProbeVerifierLaunchObservation (..)
  , observeProbeAttemptReadback
  , observeProbeCreated
  , observeProbePublicationAttempt
  , observeProbeRecord
  , observeProbeRecoveryLaunch
  , observeProbeRemovalAttempt
  , observeProbeRemovalFailure
  , observeProbeSuccessorChain
  , observeProbeSuccessorPublication
  , observeProbeVerifierLaunch
  , observeProbeVerifierPublicationAttempt
  , recordProbeRecord
  )
import Prodbox.Control.KindTool (kindFamilyBindingMatches)
import Prodbox.Control.ManagementPolicy
  ( managementClientLabel
  , managementPlaneLabel
  , managementPolicyManifest
  )
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , OperationSubprocesses
  , ProcessOutput (..)
  , Subprocess (..)
  , captureOperationCommandWithInputBefore
  , captureSubprocessWithInputBounded
  , operationProcessExitCode
  , operationProcessStdout
  , operationSubprocessExecutionKey
  , operationSubprocessKind
  , operationSubprocessWindow
  , verifyOperationSubprocessesBeforeEffect
  )
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import System.Exit (ExitCode (..))

data EnforcementObservation = EnforcementObservation
  { observedBaselineAllowed :: !Bool
  , observedBaselineOther :: !Bool
  , observedPolicyAllowed :: !Bool
  , observedPolicyOther :: !Bool
  , observedRemovedOther :: !Bool
  }
  deriving (Eq, Show)

data EnforcementCleanup
  = EnforcementCleanupNotStarted
  | EnforcementCleanupUnconfirmed !String
  | EnforcementCleanupConfirmed
  deriving (Eq, Show)

renderEnforcementCleanup :: EnforcementCleanup -> String
renderEnforcementCleanup cleanup = case cleanup of
  EnforcementCleanupNotStarted -> "not started"
  EnforcementCleanupUnconfirmed detail -> detail
  EnforcementCleanupConfirmed -> "namespace removed"

data EnforcementOutcome = EnforcementOutcome
  { enforcementObservation :: !(Maybe EnforcementObservation)
  , enforcementFailure :: !(Maybe String)
  , enforcementCleanup :: !EnforcementCleanup
  }
  deriving (Eq, Show)

-- These describe local records only. None implies namespace absence or that
-- a previously interrupted kubectl and its descendants have settled.
data ProbeJournalObservation
  = ProbeJournalEmpty
  | ProbeJournalUidUnconfirmed
  | ProbeJournalRemovalMissing !String
  | ProbeJournalRemovalAttempted !String !String
  | ProbeJournalRemovalRecorded !String
  | ProbeJournalRemovalFailed !String !String !Int
  | ProbeJournalRemovalRecordedAfterFailure !String !String !Int
  | ProbeJournalAttemptReadbackRecorded !String !String !String
  | ProbeJournalVerifierPending !String !String !String !Bool
  | ProbeJournalConflict
  deriving (Eq, Show)

observeProbeJournal
  :: BootstrapProjection -> String -> String -> IO Bool -> IO ProbeJournalObservation
observeProbeJournal bootstrap operation namespace stable = do
  intent <- observeProbeRecord bootstrap operation namespace ProbeIntent stable
  created <- observeProbeCreated bootstrap operation namespace stable
  let absentRemoval =
        observeProbeRecord
          bootstrap
          operation
          namespace
          (ProbeRemoved "00000000-0000-0000-0000-000000000000")
          stable
      readAttempt = observeProbeRemovalAttempt bootstrap operation namespace stable
  raw <- case (intent, created) of
    (ProbeMissing, ProbeCreatedMissing) -> do
      removed <- absentRemoval
      attempt <- readAttempt
      failure <- observeProbeRemovalFailure bootstrap operation namespace stable
      readback <- observeProbeAttemptReadback bootstrap operation namespace stable
      pure
        ( if removed == ProbeMissing
            && attempt == ProbeRemovalAttemptMissing
            && failure == ProbeRemovalFailureMissing
            && readback == ProbeAttemptReadbackMissing
            then ProbeJournalEmpty
            else ProbeJournalConflict
        )
    (ProbeMatches, ProbeCreatedMissing) -> do
      removed <- absentRemoval
      attempt <- readAttempt
      failure <- observeProbeRemovalFailure bootstrap operation namespace stable
      readback <- observeProbeAttemptReadback bootstrap operation namespace stable
      pure
        ( if removed == ProbeMissing
            && attempt == ProbeRemovalAttemptMissing
            && failure == ProbeRemovalFailureMissing
            && readback == ProbeAttemptReadbackMissing
            then ProbeJournalUidUnconfirmed
            else ProbeJournalConflict
        )
    (ProbeMatches, ProbeCreatedObserved uid) -> do
      removed <- observeProbeRecord bootstrap operation namespace (ProbeRemoved uid) stable
      attempt <- readAttempt
      failure <- observeProbeRemovalFailure bootstrap operation namespace stable
      readback <- observeProbeAttemptReadback bootstrap operation namespace stable
      pure $ case (removed, attempt, failure, readback) of
        (ProbeMatches, ProbeRemovalAttemptMissing, ProbeRemovalFailureMissing, ProbeAttemptReadbackMissing) -> ProbeJournalRemovalRecorded uid
        ( ProbeMatches
          , ProbeRemovalAttemptObserved attempted _
          , ProbeRemovalFailureMissing
          , ProbeAttemptReadbackMissing
          ) | attempted == uid -> ProbeJournalRemovalRecorded uid
        (ProbeMissing, ProbeRemovalAttemptMissing, ProbeRemovalFailureMissing, ProbeAttemptReadbackMissing) -> ProbeJournalRemovalMissing uid
        ( ProbeMissing
          , ProbeRemovalAttemptObserved attempted recovery
          , ProbeRemovalFailureMissing
          , ProbeAttemptReadbackMissing
          ) | attempted == uid -> ProbeJournalRemovalAttempted uid recovery
        ( ProbeMissing
          , ProbeRemovalAttemptObserved attempted recovery
          , ProbeRemovalFailureObserved failed failureId code
          , ProbeAttemptReadbackMissing
          )
            | attempted == uid && failed == uid && recovery == failureId ->
                ProbeJournalRemovalFailed uid recovery code
        ( ProbeMatches
          , ProbeRemovalAttemptObserved attempted recovery
          , ProbeRemovalFailureObserved failed failureId code
          , ProbeAttemptReadbackMissing
          )
            | attempted == uid && failed == uid && recovery == failureId ->
                ProbeJournalRemovalRecordedAfterFailure uid recovery code
        ( ProbeMissing
          , ProbeRemovalAttemptObserved attempted recovery
          , ProbeRemovalFailureMissing
          , ProbeAttemptReadbackObserved observed prior verifier
          )
            | attempted == uid && observed == uid && recovery == prior ->
                ProbeJournalAttemptReadbackRecorded uid recovery verifier
        ( ProbeMissing
          , ProbeRemovalAttemptMissing
          , ProbeRemovalFailureMissing
          , ProbeAttemptReadbackObserved observed prior verifier
          )
            | observed == uid -> ProbeJournalAttemptReadbackRecorded uid prior verifier
        _ -> ProbeJournalConflict
    _ -> pure ProbeJournalConflict
  verifier <- observeProbeVerifierLaunch bootstrap operation namespace stable
  publication <- observeProbeVerifierPublicationAttempt bootstrap operation namespace stable
  case (raw, verifier, publication) of
    (_, ProbeVerifierLaunchMissing, ProbeVerifierLaunchMissing) -> pure $ case raw of
      ProbeJournalAttemptReadbackRecorded {} -> ProbeJournalConflict
      _ -> raw
    ( ProbeJournalRemovalAttempted uid prior
      , ProbeVerifierLaunchObserved request
      , ProbeVerifierLaunchMissing
      )
        | verifierMatches uid prior (probeRecoveryId (probeVerifierRecoveryRequest request)) request ->
            pure
              (ProbeJournalVerifierPending uid prior (probeRecoveryId (probeVerifierRecoveryRequest request)) False)
    ( ProbeJournalRemovalAttempted uid prior
      , ProbeVerifierLaunchObserved request
      , ProbeVerifierLaunchObserved published
      )
        | request == published
            && verifierMatches uid prior (probeRecoveryId (probeVerifierRecoveryRequest request)) request ->
            pure
              (ProbeJournalVerifierPending uid prior (probeRecoveryId (probeVerifierRecoveryRequest request)) True)
    _ -> do
      priorLaunch <- observeProbeRecoveryLaunch bootstrap operation namespace stable
      priorPublication <- observeProbePublicationAttempt bootstrap operation namespace stable
      currentAttempt <- readAttempt
      pure $ classify raw verifier publication priorLaunch priorPublication currentAttempt
 where
  classify raw verifier publication priorLaunch priorPublication currentAttempt = case (raw, verifier, publication) of
    ( ProbeJournalAttemptReadbackRecorded uid prior verifierId
      , ProbeVerifierLaunchObserved request
      , ProbeVerifierLaunchObserved published
      )
        | request == published
            && verifierMatches uid prior verifierId request
            && priorMatches uid prior request priorLaunch priorPublication
            && ( currentAttempt == ProbeRemovalAttemptObserved uid prior
                   || (Request.probeVerifierIsIsolated request && currentAttempt == ProbeRemovalAttemptMissing)
               ) ->
            raw
    (ProbeJournalRemovalMissing uid, ProbeVerifierLaunchObserved request, ProbeVerifierLaunchMissing)
      | Request.probeVerifierIsIsolated request
          && verifierMatches
            uid
            (probeVerifierPriorId request)
            (probeRecoveryId (probeVerifierRecoveryRequest request))
            request
          && priorMatches uid (probeVerifierPriorId request) request priorLaunch priorPublication ->
          ProbeJournalVerifierPending
            uid
            (probeVerifierPriorId request)
            (probeRecoveryId (probeVerifierRecoveryRequest request))
            False
    ( ProbeJournalRemovalMissing uid
      , ProbeVerifierLaunchObserved request
      , ProbeVerifierLaunchObserved published
      )
        | request == published
            && Request.probeVerifierIsIsolated request
            && verifierMatches
              uid
              (probeVerifierPriorId request)
              (probeRecoveryId (probeVerifierRecoveryRequest request))
              request
            && priorMatches uid (probeVerifierPriorId request) request priorLaunch priorPublication ->
            ProbeJournalVerifierPending
              uid
              (probeVerifierPriorId request)
              (probeRecoveryId (probeVerifierRecoveryRequest request))
              True
    (ProbeJournalAttemptReadbackRecorded {}, _, _) -> ProbeJournalConflict
    (_, ProbeVerifierLaunchMissing, ProbeVerifierLaunchMissing) -> raw
    _ -> ProbeJournalConflict
  verifierMatches uid prior verifierId request =
    let coordinates = probeVerifierRecoveryRequest request
     in probeRecoveryNamespaceUid coordinates == uid
          && probeVerifierPriorId request == prior
          && probeRecoveryId coordinates == verifierId
  priorMatches uid prior request launch publication = case launch of
    ProbeRecoveryLaunchObserved previous ->
      probeRecoveryId previous == prior
        && probeRecoveryNamespaceUid previous == uid
        && publication == ProbePublicationObserved previous
        && probeVerifierPriorId request == prior
    _ -> False

-- A successful socket sequence is insufficient when the probe itself failed
-- or its exact cleanup was not independently observed and recorded.
enforcementComplete :: EnforcementOutcome -> Bool
enforcementComplete outcome =
  enforcementFailure outcome == Nothing
    && maybe False enforcementProven (enforcementObservation outcome)
    && enforcementCleanup outcome == EnforcementCleanupConfirmed

-- A successful delete or wait is not absence. Require a structured empty
-- inventory bracketed by the same live, independently read namespace UID.
-- Any error, malformed inventory, replacement or changed API control is unknown.
observeNamespaceAbsence
  :: ([String] -> ByteString.ByteString -> IO (Either String (Int, String)))
  -> String
  -> IO Bool
observeNamespaceAbsence execute namespace = do
  before <-
    execute ["get", "namespace", "kube-system", "-o", "jsonpath={.metadata.uid}"] ByteString.empty
  listing <-
    execute
      ["get", "namespaces", "--field-selector", "metadata.name=" ++ namespace, "-o", "json"]
      ByteString.empty
  after <-
    execute ["get", "namespace", "kube-system", "-o", "jsonpath={.metadata.uid}"] ByteString.empty
  empty <- case listing of
    Right (0, output) -> namespaceListEmpty output
    _ -> pure False
  pure
    ( empty && case (createdNamespaceUid before, createdNamespaceUid after) of
        (Just first, Just second) -> first == second
        _ -> False
    )

data ProbeAttemptReadbackOutcome
  = ProbeAttemptReadbackInvalid
  | ProbeAttemptReadbackFamilyRefused
  | ProbeAttemptReadbackSnapshotUnobservable
  | ProbeAttemptReadbackJournalRefused !ProbeJournalObservation
  | ProbeAttemptReadbackIdentityChanged
  | ProbeAttemptReadbackAbsenceUnconfirmed
  | ProbeAttemptReadbackRecordRefused !ProbeRecordWrite
  | ProbeAttemptReadbackChangedAfterRecord
  | ProbeAttemptReadbackRecorded
  deriving (Eq, Show)

-- The caller borrows both predecessor retirement owners and the operation
-- lease. bindConfig ties this exact snapshot to the original running node.
-- This boundary owns only verifier commands, not verifier retirement.
confirmAttemptedProbeAbsenceUnderFamily
  :: OperationSubprocesses
  -> BootstrapProjection
  -> String
  -> ProbeAttemptVerifierRequest
  -> IO Bool
  -> (KindKubeconfig -> IO Bool)
  -> IO ProbeAttemptReadbackOutcome
confirmAttemptedProbeAbsenceUnderFamily processes bootstrap operation request stable bindConfig
  | operationSubprocessKind processes
      /= ( if Request.probeVerifierIsIsolated request
             then Identity.KindProbeVerifierController
             else Identity.KindController
         )
      || kindRequestOperation (probeRecoveryControllerRequest coordinates) /= operation
      || kindProbeRecoveryKey operation verifierId /= Just (operationSubprocessExecutionKey processes)
      || operationSubprocessWindow processes
        /= kindRequestWindow (probeRecoveryControllerRequest coordinates) =
      pure ProbeAttemptReadbackFamilyRefused
  | otherwise = do
      snapshot <- withKindKubeconfigSnapshotBound bootstrap $ \config path -> do
        let baseAdmitted = do
              scope <- stable
              owner <- verifyOperationSubprocessesBeforeEffect processes
              bound <- if scope && owner == Right () then bindConfig config else pure False
              final <- stable
              pure (scope && owner == Right () && bound && final)
            admitted = do
              launch <- observeProbeVerifierLaunch bootstrap operation namespace baseAdmitted
              marker <- observeProbeVerifierPublicationAttempt bootstrap operation namespace baseAdmitted
              pure
                (launch == ProbeVerifierLaunchObserved request && marker == ProbeVerifierLaunchObserved request)
        journal <- observeProbeJournal bootstrap operation namespace admitted
        if journal /= ProbeJournalVerifierPending uid prior verifierId True
          then pure (ProbeAttemptReadbackJournalRefused journal)
          else
            confirmAttemptedProbeAbsenceWith
              operation
              namespace
              uid
              prior
              verifierId
              admitted
              (familyKubectl processes path)
              ( \value previous observer ->
                  recordProbeRecord
                    bootstrap
                    operation
                    namespace
                    (ProbeAttemptReadback value previous observer)
                    admitted
              )
      pure (either (const ProbeAttemptReadbackSnapshotUnobservable) id snapshot)
 where
  coordinates = probeVerifierRecoveryRequest request
  uid = probeRecoveryNamespaceUid coordinates
  prior = probeVerifierPriorId request
  verifierId = probeRecoveryId coordinates
  namespace = "prodbox-netcheck-" ++ take 12 operation

-- A successor observes only; the caller holds the original, cleanup, first
-- verifier and every earlier successor retirement throughout this boundary.
confirmSuccessorProbeAbsenceUnderFamily
  :: OperationSubprocesses
  -> BootstrapProjection
  -> String
  -> ProbeAttemptVerifierRequest
  -> [Request.ProbeSuccessorRequest]
  -> Request.ProbeSuccessorRequest
  -> IO Bool
  -> (KindKubeconfig -> IO Bool)
  -> IO ProbeAttemptReadbackOutcome
confirmSuccessorProbeAbsenceUnderFamily processes bootstrap operation first predecessors successor stable bindConfig
  | operationSubprocessKind processes /= Identity.KindProbeSuccessorController
      || kindRequestOperation (probeRecoveryControllerRequest coordinates) /= operation
      || kindProbeRecoveryKey operation successorId /= Just (operationSubprocessExecutionKey processes)
      || operationSubprocessWindow processes
        /= kindRequestWindow (probeRecoveryControllerRequest coordinates)
      || not (Request.validProbeSuccessorChain first (predecessors ++ [successor])) =
      pure ProbeAttemptReadbackFamilyRefused
  | otherwise = do
      snapshot <- withKindKubeconfigSnapshotBound bootstrap $ \config path -> do
        let admitted = do
              scope <- stable
              owner <- verifyOperationSubprocessesBeforeEffect processes
              bound <- if scope && owner == Right () then bindConfig config else pure False
              final <- stable
              pure (scope && owner == Right () && bound && final)
        before <- admitted
        chain <-
          if before
            then observeProbeSuccessorChain bootstrap operation namespace first (pure True)
            else pure (Left ProbeSuccessorUnobservable)
        publication <-
          if before
            then observeProbeSuccessorPublication bootstrap operation namespace successorId (pure True)
            else pure ProbeSuccessorUnobservable
        cancelled <-
          if before
            then
              observeProbeRecord bootstrap operation namespace (ProbeSuccessorCancellation successor) (pure True)
            else pure ProbeUnobservable
        journal <-
          if before
            then observeProbeJournal bootstrap operation namespace (pure True)
            else pure ProbeJournalConflict
        readbacks <-
          if before
            then
              mapM
                ( \entry -> observeProbeRecord bootstrap operation namespace (ProbeSuccessorReadback entry) (pure True)
                )
                (predecessors ++ [successor])
            else pure []
        after <- admitted
        let firstCoordinates = probeVerifierRecoveryRequest first
            firstId = probeRecoveryId firstCoordinates
        if not (before && after)
          || chain /= Right (predecessors ++ [successor])
          || publication /= ProbeSuccessorObserved successor
          || cancelled /= ProbeMissing
          || journal /= ProbeJournalVerifierPending uid prior firstId True
          || any (/= ProbeMissing) readbacks
          then pure (ProbeAttemptReadbackJournalRefused journal)
          else
            confirmAttemptedProbeAbsenceWith
              operation
              namespace
              uid
              prior
              successorId
              admitted
              (familyKubectl processes path)
              ( \_ _ _ -> recordProbeRecord bootstrap operation namespace (ProbeSuccessorReadback successor) admitted
              )
      pure (either (const ProbeAttemptReadbackSnapshotUnobservable) id snapshot)
 where
  coordinates = probeVerifierRecoveryRequest (Request.probeSuccessorVerifier successor)
  uid = probeRecoveryNamespaceUid coordinates
  prior = probeVerifierPriorId (Request.probeSuccessorVerifier successor)
  successorId = probeRecoveryId coordinates
  namespace = "prodbox-netcheck-" ++ take 12 operation

-- The caller must hold both prior family retirement owners, the operation
-- lease and an authenticated API snapshot, and must run these reads within a
-- separately identified managed family. This callback neither deletes nor
-- proves retirement of its own family.
confirmAttemptedProbeAbsenceWith
  :: String
  -> String
  -> String
  -> String
  -> String
  -> IO Bool
  -> ([String] -> ByteString.ByteString -> IO (Either String (Int, String)))
  -> (String -> String -> String -> IO ProbeRecordWrite)
  -> IO ProbeAttemptReadbackOutcome
confirmAttemptedProbeAbsenceWith operation namespace uid prior verifier stable execute record
  | not (all validRootGeneration [operation, prior, verifier])
      || operation == prior
      || operation == verifier
      || prior == verifier
      || namespace /= "prodbox-netcheck-" ++ take 12 operation
      || createdNamespaceUid (Right (0, uid)) /= Just uid =
      pure ProbeAttemptReadbackInvalid
  | otherwise = do
      before <- stable
      if not before
        then pure ProbeAttemptReadbackIdentityChanged
        else do
          absent <- observeNamespaceAbsence guardedExecute namespace
          after <- stable
          if not after
            then pure ProbeAttemptReadbackIdentityChanged
            else
              if not absent
                then pure ProbeAttemptReadbackAbsenceUnconfirmed
                else do
                  written <- record uid prior verifier
                  if written /= ProbeRecorded
                    then pure (ProbeAttemptReadbackRecordRefused written)
                    else do
                      final <- stable
                      pure (if final then ProbeAttemptReadbackRecorded else ProbeAttemptReadbackChangedAfterRecord)
 where
  guardedExecute arguments input = do
    allowed <- stable
    if allowed then execute arguments input else pure (Left "operation identity changed")

data ProbeRecoveryOutcome
  = ProbeRecoveryInvalid
  | ProbeRecoveryFamilyRefused
  | ProbeRecoverySnapshotUnobservable
  | ProbeRecoveryJournalRefused !ProbeJournalObservation
  | ProbeRecoveryLaunchRefused !ProbeRecoveryLaunchObservation
  | ProbeRecoveryIdentityUnconfirmed
  | ProbeRecoveryAttemptRefused !ProbeRecordWrite
  | ProbeRecoveryChangedBeforeDelete
  | ProbeRecoveryDeleteUnconfirmed
  | ProbeRecoveryFailureRecordRefused !Int !ProbeRecordWrite
  | ProbeRecoveryDeleteFailureAbsenceUnconfirmed !Int
  | ProbeRecoveryAbsenceUnconfirmed
  | ProbeRecoveryReceiptRefused !ProbeRecordWrite
  | ProbeRecoveryChangedAfterReceipt
  | ProbeRecoveryCompleted
  | ProbeRecoveryCompletedAfterDeleteFailure !Int
  deriving (Eq, Show)

-- The caller holds the original retired-family owner and the matching lease.
-- bindConfig must recheck that owner and the node CA against this exact
-- snapshot. This function owns only the recovery family's command execution;
-- its caller must independently settle that family before successor effects.
recoverRecordedProbeUnderFamily
  :: OperationSubprocesses
  -> BootstrapProjection
  -> String
  -> String
  -> IO Bool
  -> (KindKubeconfig -> IO Bool)
  -> IO ProbeRecoveryOutcome
recoverRecordedProbeUnderFamily processes bootstrap operation recovery stable bindConfig
  | operationSubprocessKind processes /= Identity.KindController
      || kindProbeRecoveryKey operation recovery /= Just (operationSubprocessExecutionKey processes) =
      pure ProbeRecoveryFamilyRefused
  | otherwise = do
      snapshot <- withKindKubeconfigSnapshotBound bootstrap $ \config path -> do
        let ownerStable = do
              scope <- stable
              owner <- verifyOperationSubprocessesBeforeEffect processes
              final <- stable
              pure (scope && owner == Right () && final)
            baseAdmitted = do
              before <- ownerStable
              bound <- if before then bindConfig config else pure False
              after <- ownerStable
              pure (before && bound && after)
            namespace = "prodbox-netcheck-" ++ take 12 operation
        beforeLaunch <- baseAdmitted
        launch <-
          if beforeLaunch
            then observeProbeRecoveryLaunch bootstrap operation namespace (pure True)
            else pure ProbeRecoveryLaunchUnobservable
        afterLaunch <- baseAdmitted
        case launch of
          ProbeRecoveryLaunchObserved request
            | probeRecoveryId request == recovery
            , beforeLaunch && afterLaunch
            , kindRequestWindow (probeRecoveryControllerRequest request) == operationSubprocessWindow processes -> do
                let admitted = do
                      before <- baseAdmitted
                      current <- observeProbeRecoveryLaunch bootstrap operation namespace (pure True)
                      marker <-
                        observeProbeRecord bootstrap operation namespace (ProbePublicationAttempt request) (pure True)
                      after <- baseAdmitted
                      pure (before && current == ProbeRecoveryLaunchObserved request && marker == ProbeMatches && after)
                    recordBound stage = do
                      before <- admitted
                      if not before
                        then pure ProbeRefused
                        else do
                          written <- recordProbeRecord bootstrap operation namespace stage ownerStable
                          after <- admitted
                          pure $
                            if after
                              then written
                              else case written of
                                ProbeRecorded -> ProbeIncomplete
                                ProbeIncomplete -> ProbeIncomplete
                                _ -> ProbeRefused
                beforeJournal <- admitted
                sampled <-
                  if beforeJournal
                    then observeProbeJournal bootstrap operation namespace (pure True)
                    else pure ProbeJournalConflict
                afterJournal <- admitted
                let journal = if beforeJournal && afterJournal then sampled else ProbeJournalConflict
                case journal of
                  ProbeJournalRemovalMissing uid
                    | uid == probeRecoveryNamespaceUid request ->
                        recoverRecordedProbeWith
                          operation
                          namespace
                          uid
                          admitted
                          (familyKubectl processes path)
                          (\value -> recordBound (ProbeRemovalAttempt value recovery))
                          (\value code -> recordBound (ProbeRemovalFailure value recovery code))
                          (\value -> recordBound (ProbeRemoved value))
                  _ -> pure (ProbeRecoveryJournalRefused journal)
          _ -> pure (ProbeRecoveryLaunchRefused launch)
      pure (either (const ProbeRecoverySnapshotUnobservable) id snapshot)

-- This protocol does not provide the caller's operation lease, prior family
-- retirement, authenticated API, bounded worker or worker settlement. The
-- caller must hold those capabilities across every callback and must settle
-- this cleanup worker before admitting any successor effects.
recoverRecordedProbeWith
  :: String
  -> String
  -> String
  -> IO Bool
  -> ([String] -> ByteString.ByteString -> IO (Either String (Int, String)))
  -> (String -> IO ProbeRecordWrite)
  -> (String -> Int -> IO ProbeRecordWrite)
  -> (String -> IO ProbeRecordWrite)
  -> IO ProbeRecoveryOutcome
recoverRecordedProbeWith operation namespace uid stable execute recordAttempt recordFailure recordRemoved
  | not (validRootGeneration operation)
      || namespace /= "prodbox-netcheck-" ++ take 12 operation
      || createdNamespaceUid (Right (0, uid)) /= Just uid =
      pure ProbeRecoveryInvalid
  | otherwise = do
      before <- stable
      current <-
        if before
          then
            guardedExecute ["get", "namespace", namespace, "-o", "jsonpath={.metadata.uid}"] ByteString.empty
          else pure (Left "operation identity changed")
      case createdNamespaceUid current of
        Nothing -> confirmAlreadyAbsent
        Just observed | observed /= uid -> pure ProbeRecoveryIdentityUnconfirmed
        Just _ -> deleteRecorded
 where
  confirmAlreadyAbsent = do
    absent <- observeNamespaceAbsence guardedExecute namespace
    if not absent
      then pure ProbeRecoveryIdentityUnconfirmed
      else do
        ready <- stable
        recorded <- if ready then recordRemoved uid else pure ProbeRefused
        if recorded /= ProbeRecorded
          then pure (ProbeRecoveryReceiptRefused recorded)
          else do
            after <- stable
            pure (if after then ProbeRecoveryCompleted else ProbeRecoveryChangedAfterReceipt)
  deleteRecorded = do
    attemptStable <- stable
    attempted <- if attemptStable then recordAttempt uid else pure ProbeRefused
    if attempted /= ProbeRecorded
      then pure (ProbeRecoveryAttemptRefused attempted)
      else do
        admitted <- stable
        if not admitted
          then pure ProbeRecoveryChangedBeforeDelete
          else do
            let options =
                  LazyByteString.toStrict $
                    Aeson.encode $
                      Aeson.object
                        [ "apiVersion" Aeson..= ("v1" :: String)
                        , "kind" Aeson..= ("DeleteOptions" :: String)
                        , "preconditions" Aeson..= Aeson.object ["uid" Aeson..= uid]
                        ]
            deleted <- guardedExecute ["delete", "--raw", "/api/v1/namespaces/" ++ namespace, "-f", "-"] options
            case deleted of
              Right (0, _) -> do
                waited <-
                  guardedExecute ["wait", "--for=delete", "namespace/" ++ namespace, "--timeout=90s"] ByteString.empty
                absence <- case waited of
                  Right (0, _) -> observeNamespaceAbsence guardedExecute namespace
                  _ -> pure False
                if not absence
                  then pure ProbeRecoveryAbsenceUnconfirmed
                  else do
                    receiptStable <- stable
                    recorded <- if receiptStable then recordRemoved uid else pure ProbeRefused
                    if recorded /= ProbeRecorded
                      then pure (ProbeRecoveryReceiptRefused recorded)
                      else do
                        after <- stable
                        pure (if after then ProbeRecoveryCompleted else ProbeRecoveryChangedAfterReceipt)
              Right (code, _) | code > 0 && code <= 255 -> do
                failureStable <- stable
                failure <- if failureStable then recordFailure uid code else pure ProbeRefused
                if failure /= ProbeRecorded
                  then pure (ProbeRecoveryFailureRecordRefused code failure)
                  else do
                    absent <- observeNamespaceAbsence guardedExecute namespace
                    if not absent
                      then pure (ProbeRecoveryDeleteFailureAbsenceUnconfirmed code)
                      else do
                        receiptStable <- stable
                        recorded <- if receiptStable then recordRemoved uid else pure ProbeRefused
                        if recorded /= ProbeRecorded
                          then pure (ProbeRecoveryReceiptRefused recorded)
                          else do
                            after <- stable
                            pure
                              (if after then ProbeRecoveryCompletedAfterDeleteFailure code else ProbeRecoveryChangedAfterReceipt)
              _ -> pure ProbeRecoveryDeleteUnconfirmed
  guardedExecute arguments input = do
    allowed <- stable
    if allowed then execute arguments input else pure (Left "operation identity changed")

namespaceListEmpty :: String -> IO Bool
namespaceListEmpty output = do
  let bytes = TextEncoding.encodeUtf8 (Text.pack output)
  if ByteString.length bytes > 65536
    then pure False
    else do
      checked <- decodeBoundedYamlValue bytes
      pure $ case (Aeson.eitherDecodeStrict' bytes, checked) of
        (Right value, Right checkedValue) | value == checkedValue ->
          case parseEither
            ( Aeson.withObject "namespace list" $ \object -> do
                version <- object .: "apiVersion"
                kind <- object .: "kind"
                items <- object .: "items"
                pure
                  ( (version :: String) == "v1"
                      && (kind :: String) `elem` ["NamespaceList", "List"]
                      && null (items :: [Aeson.Value])
                  )
            )
            value of
            Right True -> True
            _ -> False
        _ -> False

-- | Enforcement is proven only by a working observer, a held allow, a real
-- deny and a restored connection after the policy is removed.
enforcementProven :: EnforcementObservation -> Bool
enforcementProven observation =
  observedBaselineAllowed observation
    && observedBaselineOther observation
    && observedPolicyAllowed observation
    && not (observedPolicyOther observation)
    && observedRemovedOther observation

helperImage, serverImage :: String
helperImage = "docker.io/kindest/local-path-helper:v20260131-7181c60a"
serverImage = "registry.k8s.io/coredns/coredns:v1.14.2"

limits :: BoundedSubprocessLimits
limits = BoundedSubprocessLimits 65536 65536 16384 120000000

kubectl :: FilePath -> [String] -> ByteString.ByteString -> IO (Either String (Int, String))
kubectl kubeconfig arguments input = do
  result <-
    captureSubprocessWithInputBounded
      limits
      input
      ( Subprocess
          "/usr/bin/kubectl"
          (["--kubeconfig", kubeconfig, "--request-timeout=60s"] ++ arguments)
          (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")])
          Nothing
      )
  pure $ case result of
    Right output ->
      Right
        ( case processExitCode output of
            ExitSuccess -> 0
            ExitFailure code -> code
        , processStdout output
        )
    Left failure -> Left (show failure)

-- This command uses the held family owner and its original work window; a
-- completed command is not, by itself, proof that the whole family retired.
familyKubectl
  :: OperationSubprocesses
  -> FilePath
  -> [String]
  -> ByteString.ByteString
  -> IO (Either String (Int, String))
familyKubectl processes kubeconfig arguments input = do
  now <- getMonotonicTimeNSec
  let limit = 120000000000
      work = Identity.hostExecutionWorkEnd (operationSubprocessWindow processes)
      ending = if now > maxBound - limit then work else min work (now + limit)
  result <-
    captureOperationCommandWithInputBefore
      65536
      65536
      16384
      ending
      processes
      input
      ( Subprocess
          "/usr/bin/kubectl"
          (["--kubeconfig", kubeconfig, "--request-timeout=60s"] ++ arguments)
          (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")])
          Nothing
      )
  pure $ case result of
    Right output ->
      Right
        ( case operationProcessExitCode output of ExitSuccess -> 0; ExitFailure code -> code
        , ByteString8.unpack (operationProcessStdout output)
        )
    Left failure -> Left (show failure)

serverManifest :: String -> ByteString.ByteString
serverManifest namespace =
  ByteString8.pack $
    unlines
      [ "apiVersion: v1"
      , "kind: ConfigMap"
      , "metadata: {name: corefile, namespace: " ++ namespace ++ "}"
      , "data: {Corefile: \".:5353 {\\n whoami\\n}\\n\"}"
      , "---"
      , "apiVersion: v1"
      , "kind: Pod"
      , "metadata: {name: server, namespace: "
          ++ namespace
          ++ ", labels: {"
          ++ managementPlaneLabelFlow
          ++ "}}"
      , "spec:"
      , "  containers: [{name: s, image: "
          ++ serverImage
          ++ ", imagePullPolicy: Never, args: [\"-conf\", \"/etc/c/Corefile\"], volumeMounts: [{name: v, mountPath: /etc/c}]}]"
      , "  volumes: [{name: v, configMap: {name: corefile}}]"
      ]

managementPlaneLabelFlow, managementClientLabelFlow :: String
managementPlaneLabelFlow = managementPlaneLabel
managementClientLabelFlow = managementClientLabel

clientManifest :: String -> String -> String -> String -> ByteString.ByteString
clientManifest namespace name role address =
  ByteString8.pack $
    unlines
      [ "apiVersion: v1"
      , "kind: Pod"
      , "metadata: {name: "
          ++ name
          ++ ", namespace: "
          ++ namespace
          ++ ", labels: {"
          ++ (if role == "allowed" then managementClientLabelFlow else "role: other")
          ++ "}}"
      , "spec:"
      , "  restartPolicy: Never"
      , "  activeDeadlineSeconds: 12"
      , "  containers: [{name: c, image: "
          ++ helperImage
          ++ ", imagePullPolicy: Never, command: "
          ++ ByteString8.unpack (LazyByteString.toStrict (Aeson.encode command))
          ++ "}]"
      ]
 where
  command = ["bash", "-c", clientProbeScript, "prodbox-connection-probe", address, "5353"]

-- The pinned local-path helper contains Bash and no timeout executable.
-- Only an acknowledged socket attempt, or its observed timed cancellation,
-- supplies a connection result. The pod deadline bounds abnormal cleanup.
clientProbeScript :: String
clientProbeScript =
  unlines
    [ "exec {result_fd}< <("
    , "  printf '%s\\n' STARTED"
    , "  if { exec 3<>\"/dev/tcp/$1/$2\"; } 2>/dev/null; then"
    , "    printf '%s\\n' CONNECTED"
    , "  else"
    , "    printf '%s\\n' REFUSED"
    , "  fi"
    , ")"
    , "child=$!"
    , "if ! IFS= read -r -t 1 started <&\"$result_fd\" || [[ $started != STARTED ]]; then"
    , "  kill \"$child\" 2>/dev/null || :"
    , "  wait \"$child\" 2>/dev/null || :"
    , "  printf '%s\\n' OBSERVER_UNAVAILABLE"
    , "  exit 0"
    , "fi"
    , "IFS= read -r -t 5 result <&\"$result_fd\""
    , "read_status=$?"
    , "exec {result_fd}<&-"
    , "if (( read_status == 0 )); then"
    , "  if wait \"$child\" && [[ $result == CONNECTED || $result == REFUSED ]]; then"
    , "    printf '%s\\n' \"$result\""
    , "  else"
    , "    printf '%s\\n' OBSERVER_UNAVAILABLE"
    , "  fi"
    , "elif (( read_status > 128 )) && kill \"$child\" 2>/dev/null; then"
    , "  wait \"$child\" 2>/dev/null"
    , "  if (( $? == 143 )); then"
    , "    printf '%s\\n' REFUSED"
    , "  else"
    , "    printf '%s\\n' OBSERVER_UNAVAILABLE"
    , "  fi"
    , "else"
    , "  wait \"$child\" 2>/dev/null || :"
    , "  printf '%s\\n' OBSERVER_UNAVAILABLE"
    , "fi"
    ]

policyManifest :: String -> ByteString.ByteString
policyManifest = managementPolicyManifest

-- The operation lease and durable intent precede namespace creation. A
-- successful create must also record its UID before any later probe effect.
observeNetworkEnforcementScoped :: BootstrapProjection -> String -> String -> IO EnforcementOutcome
observeNetworkEnforcementScoped bootstrap operation namespace = do
  outcome <-
    withRecoveredKindOperation
      bootstrap
      operation
      (observeNetworkEnforcementUnderLease bootstrap operation namespace)
  pure $ case outcome of
    KindOperationCallbackReturned result -> result
    _ ->
      EnforcementOutcome
        Nothing
        (Just ("probe operation lease unconfirmed: " ++ operation))
        (EnforcementCleanupUnconfirmed "not confirmed; inspect retained records")

-- The caller must hold the matching recovered operation lease throughout.
observeNetworkEnforcementUnderLease
  :: BootstrapProjection -> String -> String -> IO Bool -> IO EnforcementOutcome
observeNetworkEnforcementUnderLease bootstrap operation namespace stable = do
  observeNetworkEnforcementUsing bootstrap operation namespace stable kubectl

-- The probe borrows the caller's held operation and verifies the exact node
-- against each sealed kubeconfig snapshot before admitting a request.
observeNetworkEnforcementUnderBoundLease
  :: BootstrapProjection
  -> String
  -> String
  -> IO Bool
  -> (KindKubeconfig -> IO Bool)
  -> IO EnforcementOutcome
observeNetworkEnforcementUnderBoundLease bootstrap operation namespace stable bindConfig =
  observeNetworkEnforcementUsingBound bootstrap operation namespace stable bindConfig kubectl

-- The node controller's owner supplies the exact operation-family identity.
-- Callers must hold its matching operation lease and retain family retirement
-- and namespace recovery separately before admitting a later operation.
observeNetworkEnforcementUnderFamily
  :: OperationSubprocesses
  -> BootstrapProjection
  -> String
  -> String
  -> IO Bool
  -> (KindKubeconfig -> IO Bool)
  -> IO EnforcementOutcome
observeNetworkEnforcementUnderFamily processes bootstrap operation namespace stable bindConfig
  | not
      ( kindFamilyBindingMatches
          (operationSubprocessKind processes)
          (operationSubprocessExecutionKey processes)
          operation
      ) =
      pure
        ( EnforcementOutcome
            Nothing
            (Just "network probe family binding refused")
            EnforcementCleanupNotStarted
        )
  | otherwise =
      observeNetworkEnforcementUsingBound
        bootstrap
        operation
        namespace
        stable
        bindConfig
        (familyKubectl processes)

observeNetworkEnforcementUsing
  :: BootstrapProjection
  -> String
  -> String
  -> IO Bool
  -> (FilePath -> [String] -> ByteString.ByteString -> IO (Either String (Int, String)))
  -> IO EnforcementOutcome
observeNetworkEnforcementUsing bootstrap operation namespace stable runKubectl = do
  observeNetworkEnforcementUsingBound
    bootstrap
    operation
    namespace
    stable
    (const (pure True))
    runKubectl

observeNetworkEnforcementUsingBound
  :: BootstrapProjection
  -> String
  -> String
  -> IO Bool
  -> (KindKubeconfig -> IO Bool)
  -> (FilePath -> [String] -> ByteString.ByteString -> IO (Either String (Int, String)))
  -> IO EnforcementOutcome
observeNetworkEnforcementUsingBound bootstrap operation namespace stable bindConfig runKubectl = do
  snapshot <- withKindKubeconfigSnapshotBound bootstrap $ \config kubeconfig -> do
    let admitted = do
          before <- stable
          bound <- if before then bindConfig config else pure False
          after <- stable
          pure (before && bound && after)
        record stage =
          withProbeRecordAdmission admitted $
            (== ProbeRecorded) <$> recordProbeRecord bootstrap operation namespace stage stable
        execute arguments input = do
          allowed <- admitted
          if allowed
            then runKubectl kubeconfig arguments input
            else pure (Left "probe operation identity changed")
    observeNetworkEnforcementRecorded
      execute
      threadDelay
      (record ProbeIntent)
      (record . ProbeCreated)
      (record . ProbeRemoved)
      namespace
  pure $
    either
      ( const
          ( EnforcementOutcome
              Nothing
              (Just "validated kubeconfig snapshot unavailable")
              EnforcementCleanupNotStarted
          )
      )
      id
      snapshot

-- The expensive API/node binding brackets the local journal write; its
-- retained family admission is still checked inside the writer. No kubectl
-- effect follows unless the closing binding check also succeeds.
withProbeRecordAdmission :: IO Bool -> IO Bool -> IO Bool
withProbeRecordAdmission admitted record = do
  before <- admitted
  if not before
    then pure False
    else do
      written <- record
      after <- admitted
      pure (written && after)

data ProbePublicationState
  = ProbePublicationNotRecorded
  | ProbePublicationBeforeAttempt !String
  | ProbePublicationAttemptRecorded !String
  | ProbePublicationStateUnconfirmed
  deriving (Eq, Show)

-- Local records describe the protocol stage, not a manager send or worker
-- retirement. Foreign, incomplete or unobservable pairs remain unconfirmed.
classifyProbePublication
  :: ProbeRecoveryLaunchObservation -> ProbePublicationObservation -> ProbePublicationState
classifyProbePublication launch publication = case (launch, publication) of
  (ProbeRecoveryLaunchMissing, ProbePublicationMissing) -> ProbePublicationNotRecorded
  (ProbeRecoveryLaunchObserved request, ProbePublicationMissing) -> ProbePublicationBeforeAttempt (probeRecoveryId request)
  (ProbeRecoveryLaunchObserved request, ProbePublicationObserved recorded)
    | request == recorded -> ProbePublicationAttemptRecorded (probeRecoveryId request)
  _ -> ProbePublicationStateUnconfirmed

-- This is a local-record observation only. It never authorizes cleanup and
-- does not assert namespace presence, absence or predecessor settlement.
observeReconcileProbeRecords :: BootstrapProjection -> IO String
observeReconcileProbeRecords bootstrap = do
  intent <- observeKindIntent bootstrap
  case intent of
    KindIntentMatches operation -> do
      let namespace = "prodbox-netcheck-" ++ take 12 operation
      result <- withRecoveredKindOperation bootstrap operation $ \stable -> do
        journal <- observeProbeJournal bootstrap operation namespace stable
        launch <- observeProbeRecoveryLaunch bootstrap operation namespace stable
        publication <- observeProbePublicationAttempt bootstrap operation namespace stable
        pure (journal, classifyProbePublication launch publication)
      pure $
        "Reconcile network probe "
          ++ namespace
          ++ ": "
          ++ case result of
            KindOperationCallbackReturned (description, publication) ->
              renderJournal description
                ++ "; "
                ++ renderPublication publication
                ++ "; worker settlement and namespace state not observed.\n"
            _ -> "operation lease unconfirmed; worker settlement and namespace state not observed.\n"
    _ -> pure "Reconcile network probe: operation identity unavailable; records not observed.\n"
 where
  renderJournal observed = case observed of
    ProbeJournalEmpty -> "no probe intent or creation record observed"
    ProbeJournalUidUnconfirmed -> "intent recorded; namespace UID unconfirmed"
    ProbeJournalRemovalMissing uid -> "recorded namespace UID " ++ uid ++ "; removal receipt missing"
    ProbeJournalRemovalAttempted uid recovery ->
      "recorded namespace UID "
        ++ uid
        ++ "; recovery "
        ++ recovery
        ++ " attempted removal, outcome unconfirmed"
    ProbeJournalRemovalRecorded uid -> "recorded namespace UID " ++ uid ++ "; removal receipt recorded"
    ProbeJournalRemovalFailed uid recovery code ->
      "recorded namespace UID "
        ++ uid
        ++ "; recovery "
        ++ recovery
        ++ " delete exited "
        ++ show code
        ++ "; absence unconfirmed"
    ProbeJournalRemovalRecordedAfterFailure uid recovery code ->
      "recorded namespace UID "
        ++ uid
        ++ "; recovery "
        ++ recovery
        ++ " delete exited "
        ++ show code
        ++ "; absence receipt recorded"
    ProbeJournalAttemptReadbackRecorded uid recovery verifier ->
      "recorded namespace UID "
        ++ uid
        ++ "; recovery "
        ++ recovery
        ++ " outcome unconfirmed; verifier "
        ++ verifier
        ++ " recorded absence, settlement not established"
    ProbeJournalVerifierPending uid recovery verifier attempted ->
      "recorded namespace UID "
        ++ uid
        ++ "; recovery "
        ++ recovery
        ++ " outcome unconfirmed; verifier "
        ++ verifier
        ++ " publication attempt recorded: "
        ++ show attempted
    ProbeJournalConflict -> "probe records conflicting or unobservable"
  renderPublication observed = case observed of
    ProbePublicationNotRecorded -> "no cleanup publication record observed"
    ProbePublicationBeforeAttempt recovery -> "cleanup recovery " ++ recovery ++ " has no publication-attempt record"
    ProbePublicationAttemptRecorded recovery -> "cleanup recovery " ++ recovery ++ " has a publication-attempt record; send not established"
    ProbePublicationStateUnconfirmed -> "cleanup publication records conflicting or unobservable"

createdNamespaceUid :: Either String (Int, String) -> Maybe String
createdNamespaceUid result = case result of
  Right (0, output) -> case words output of
    [uid] | validUid uid -> Just uid
    _ -> Nothing
  _ -> Nothing
 where
  validUid value =
    length value == 36
      && and
        [ if index `elem` [8, 13, 18, 23] then character == '-' else hex character
        | (index, character) <- zip [0 :: Int ..] value
        ]
  hex character = (character >= '0' && character <= '9') || (character >= 'a' && character <= 'f')

observeNetworkEnforcementWith
  :: ([String] -> ByteString.ByteString -> IO (Either String (Int, String)))
  -> (Int -> IO ())
  -> String
  -> IO EnforcementOutcome
observeNetworkEnforcementWith execute pause namespace =
  observeNetworkEnforcementRecorded
    execute
    pause
    (pure True)
    (const (pure True))
    (const (pure True))
    namespace

observeNetworkEnforcementRecorded
  :: ([String] -> ByteString.ByteString -> IO (Either String (Int, String)))
  -> (Int -> IO ())
  -> IO Bool
  -> (String -> IO Bool)
  -> (String -> IO Bool)
  -> String
  -> IO EnforcementOutcome
observeNetworkEnforcementRecorded execute pause recordIntent recordCreated recordRemoved namespace
  | not (validNamespace namespace) =
      pure (EnforcementOutcome Nothing (Just "invalid probe namespace") EnforcementCleanupNotStarted)
  | otherwise = do
      admitted <- recordIntent
      if admitted
        then create
        else
          pure
            ( EnforcementOutcome
                Nothing
                (Just ("probe intent not recorded: " ++ namespace))
                EnforcementCleanupNotStarted
            )
 where
  create = do
    created <-
      execute ["create", "namespace", namespace, "-o", "jsonpath={.metadata.uid}"] ByteString.empty
    case createdNamespaceUid created of
      Nothing ->
        pure
          ( EnforcementOutcome
              Nothing
              (Just ("namespace creation or identity unconfirmed: " ++ namespace))
              (EnforcementCleanupUnconfirmed "not removed; inspect namespace identity")
          )
      Just uid -> do
        recorded <- recordCreated uid
        if recorded
          then runCreated uid
          else
            pure
              ( EnforcementOutcome
                  Nothing
                  (Just ("namespace UID not durably recorded: " ++ namespace ++ " " ++ uid))
                  (EnforcementCleanupUnconfirmed "not removed; inspect retained intent and namespace")
              )
  runCreated uid = do
    outcome <- sequenceObservation uid
    let options =
          LazyByteString.toStrict $
            Aeson.encode $
              Aeson.object
                [ "apiVersion" Aeson..= ("v1" :: String)
                , "kind" Aeson..= ("DeleteOptions" :: String)
                , "preconditions" Aeson..= Aeson.object ["uid" Aeson..= uid]
                ]
    deleted <- execute ["delete", "--raw", "/api/v1/namespaces/" ++ namespace, "-f", "-"] options
    cleanup <- case deleted of
      Right (0, _) -> execute ["wait", "--for=delete", "namespace/" ++ namespace, "--timeout=90s"] ByteString.empty
      other -> pure other
    absence <- case cleanup of
      Right (0, _) -> observeNamespaceAbsence execute namespace
      _ -> pure False
    recordedRemoval <- if absence then recordRemoved uid else pure False
    pure
      outcome
        { enforcementCleanup = case cleanup of
            Right (0, _) | recordedRemoval -> EnforcementCleanupConfirmed
            Right (0, _) | absence -> EnforcementCleanupUnconfirmed "namespace absence observed but receipt not recorded"
            Right (0, _) -> EnforcementCleanupUnconfirmed "namespace absence unconfirmed after removal reply"
            Right (code, text) -> EnforcementCleanupUnconfirmed ("namespace removal exit " ++ show code ++ ": " ++ take 200 text)
            Left failure -> EnforcementCleanupUnconfirmed ("namespace removal not confirmed: " ++ failure)
        }
  validNamespace value =
    not (null value)
      && length value <= 63
      && all (\c -> isAsciiLower c || isDigit c && c <= '9' || c == '-') value
      && take 1 value /= "-"
      && take 1 (reverse value) /= "-"
  failed reason =
    pure
      (EnforcementOutcome Nothing (Just reason) (EnforcementCleanupUnconfirmed "cleanup not yet attempted"))
  step description action = do
    result <- action
    pure $ case result of
      Right (0, text) -> Right text
      Right (code, text) -> Left (description ++ " exit " ++ show code ++ ": " ++ take 200 text)
      Left failure -> Left (description ++ ": " ++ failure)
  checkedEffect uid arguments input = do
    current <-
      execute ["get", "namespace", namespace, "-o", "jsonpath={.metadata.uid}"] ByteString.empty
    if createdNamespaceUid current == Just uid
      then execute arguments input
      else pure (Left "probe namespace identity changed or is unobservable")
  sequenceObservation uid = do
    nodes <-
      step
        "nodes ready"
        ( execute
            ["wait", "--for=condition=Ready", "node", "--all", "--timeout=120s"]
            ByteString.empty
        )
    case nodes of
      Left reason -> failed reason
      Right _ -> do
        server <- step "server apply" (checkedEffect uid ["apply", "-f", "-"] (serverManifest namespace))
        case server of
          Left reason -> failed reason
          Right _ -> do
            ready <-
              step
                "server ready"
                ( execute
                    ["-n", namespace, "wait", "--for=condition=Ready", "pod/server", "--timeout=90s"]
                    ByteString.empty
                )
            address <-
              step
                "server address"
                ( execute
                    ["-n", namespace, "get", "pod", "server", "-o", "jsonpath={.status.podIP}"]
                    ByteString.empty
                )
            case (ready, address) of
              (Left reason, _) -> failed reason
              (_, Left reason) -> failed reason
              (Right _, Right ip) | not (validIpv4 ip) -> failed "server pod address is not a valid IPv4 address"
              (Right _, Right ip) -> observe uid ip
  -- Both short-lived clients must reach Succeeded before their logs count.
  -- A delayed Pod or missing log remains unobservable.
  probe uid phase ip = do
    let allowedName = phase ++ "-allowed"
        otherName = phase ++ "-other"
    applied <-
      checkedEffect
        uid
        ["apply", "-f", "-"]
        ( clientManifest namespace allowedName "allowed" ip
            <> "---\n"
            <> clientManifest namespace otherName "other" ip
        )
    case applied of
      Right (0, _) -> do
        complete <-
          execute
            [ "-n"
            , namespace
            , "wait"
            , "--for=jsonpath={.status.phase}=Succeeded"
            , "pod/" ++ allowedName
            , "pod/" ++ otherName
            , "--timeout=30s"
            ]
            ByteString.empty
        case complete of
          Right (0, _) -> do
            allowed <- connected allowedName
            other <- connected otherName
            pure ((,) <$> allowed <*> other)
          _ -> pure Nothing
      _ -> pure Nothing
  connected name = do
    logs <- execute ["-n", namespace, "logs", name] ByteString.empty
    pure $ case logs of
      Right (0, text) -> case words text of
        ["CONNECTED"] -> Just True
        ["REFUSED"] -> Just False
        _ -> Nothing
      _ -> Nothing
  observe uid ip = do
    baseline <- probe uid "base" ip
    case baseline of
      Just (True, True) -> do
        applied <- step "policy apply" (checkedEffect uid ["apply", "-f", "-"] (policyManifest namespace))
        case applied of
          Left reason -> failed reason
          Right _ -> do
            pause 5000000
            policy <- probe uid "pol" ip
            removed <-
              step
                "policy delete"
                ( checkedEffect
                    uid
                    ["-n", namespace, "delete", "networkpolicy", "management-default-deny", "management-allow-clients"]
                    ByteString.empty
                )
            case removed of
              Left reason -> failed reason
              Right _ -> do
                pause 5000000
                restored <- probe uid "off" ip
                case (policy, restored) of
                  (Just (policyAllowed, policyOther), Just (_, removedOther)) ->
                    pure
                      ( EnforcementOutcome
                          (Just (EnforcementObservation True True policyAllowed policyOther removedOther))
                          Nothing
                          (EnforcementCleanupUnconfirmed "cleanup not yet attempted")
                      )
                  _ -> failed "policy or restored connection observation unavailable"
      _ -> failed "baseline connections were not both observed"

validIpv4 :: String -> Bool
validIpv4 input = case Text.splitOn "." (Text.pack input) of
  [a, b, c, d] -> all octet [a, b, c, d]
  _ -> False
 where
  octet part =
    not (Text.null part)
      && Text.length part <= 3
      && Text.all (\c -> c >= '0' && c <= '9') part
      && case reads (Text.unpack part) :: [(Int, String)] of
        [(n, "")] -> n <= 255
        _ -> False
