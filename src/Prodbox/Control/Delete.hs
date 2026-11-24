{-# LANGUAGE ScopedTypeVariables #-}

-- | Early control removal for a /new test identity/ whose cloud admission is
-- impossible: remove the recorded kind node, node volume and kind network
-- through the retained removal operations, in dependency order, stopping at the
-- first step that is not completely recorded and observed. Each effect keeps
-- its own write-ahead attempt and result record; an independent Docker
-- inventory then checks the result. Foreign, unrecorded or production
-- identities are refused. Host data, the retained root, artifacts and every
-- record stay in place.
module Prodbox.Control.Delete
  ( DeleteStep (..)
  , deleteNewTestIdentity
  , recoverProbeForDelete
  , nodeNeverStarted
  , nodeRemovalRecorded
  , volumeRemovalRecorded
  , networkRemovalRecorded
  , controlContainerId
  , controlContainerMatches
  , priorVolumeRemovalRecorded
  , priorNetworkRemovalRecorded
  , probeCleanupRecorded
  , probeCleanupPermitsNodeRemoval
  , probeRecoveryReceiptMatches
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, try)
import Data.Either (isRight)
import Data.Text qualified as Text
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapRootGeneration
  , bootstrapRuntimeSocket
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope
  ( DeploymentEnvironment (Test)
  , ScopeGenerationObservation (ScopeGenerationMatches)
  , observeScopeGeneration
  , scopeEnvironment
  , withScopeRootDescriptor
  )
import Prodbox.Control.DockerConnectedInfo
  ( DockerConnectedInfoResult (..)
  , DockerNetworkCreateResult (..)
  , DockerNetworkRemoveResult (..)
  , DockerNodeContainerCreateResult (..)
  , DockerNodeContainerRemoveResult (..)
  , DockerNodeVarRemoveResult (..)
  , removeDockerSessionKindNetwork
  , removeDockerSessionNodeVarVolume
  )
import Prodbox.Control.DockerIdentity (DockerDaemonObservation (..), observeDockerDaemon)
import Prodbox.Control.DockerPeer (DockerPeerResult (..))
import Prodbox.Control.KindAbsenceRecovery (recoverExistingAbsenceControl)
import Prodbox.Control.ImageIdObservation (validImageId)
import Prodbox.Control.KindControllerReceipt (withControllerRecoverySettlement)
import Prodbox.Control.KindFamilyLaunch (prepareFreshKindFamilyRequest, launchKindProbeVerifier, launchKindProbeSuccessor, cancelKindProbeSuccessorBeforePublication)
import Prodbox.Control.Reconcile (randomOperationId)
import Prodbox.Control.KindFamilyRecovery
  ( KindFamilyRetirement
  , KindFamilyRecoveryError (KindFamilyRecoveryRequestMissing)
  , KindFamilyRetirementOutcome (..)
  , KindFamilyInputRetirement (..)
  , awaitKindFamilyCompletionWith
  , retireKindFamilyPublishedInputs
  , retireKindProbeFamilyPublishedInputs
  , retireKindProbeVerifierPublishedInputs
  , retireNeverSentKindProbeInputs
  , recoverNeverSentKindFamilyInputs
  , KindFamilyNeverSentScopeOutcome (..)
  , withNeverSentKindFamily
  , KindFamilyPrePublicationOutcome (..)
  , withCancelledPrePublicationKindFamily
  , withCancelledUnlaunchedOwnerFamily
  , verifyKindFamilyRetirement
  , verifyKindProbeFamilyRetirement
  , verifyKindProbeVerifierRetirement
  , withKindFamilyRetirement
  , withKindProbeFamilyRetirement
  , withKindProbeVerifierRetirement
  , KindProbeSuccessorChainOutcome (..)
  , withKindProbeSuccessorRetirementChain
  , verifyKindProbeSuccessorRetirementChain
  , retireKindProbeSuccessorPublishedInputs
  , withKindProbeSuccessorRetirement
  )
import Prodbox.Control.KindControllerRequest qualified as Request
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import Prodbox.Control.KindIntent (KindIntentObservation (..), observeKindFamilyIntent, observeKindOwnerFamilyIntent, observeKindIntent)
import Prodbox.Control.KindLease
  ( KindOperationOutcome (..)
  , withRecoveredKindOperation
  )
import Prodbox.Control.NetworkEnforcement (ProbeJournalObservation (..), observeProbeJournal)
import Prodbox.Control.KindNetworkProbeRecord
  ( ProbeRecoveryLaunchObservation (..), ProbeRemovalAttemptObservation (..), ProbePublicationObservation (..), ProbeVerifierLaunchObservation (..)
  , ProbeSuccessorChainObservation (..), ProbeSuccessorObservation (..), ProbeRecord (..), ProbeRecordObservation (..)
  , observeProbeRecoveryLaunch, observeProbeRemovalAttempt, observeProbePublicationAttempt, observeProbeVerifierLaunch
  , observeProbeVerifierPublicationAttempt, observeProbeSuccessorChainState, observeProbeSuccessorPublication, observeProbeRecord )
import Prodbox.Control.KindNetworkIntent
  ( KindNetworkRecoveryObservation (..)
  , kindNetworkDaemon
  , observeRecordedKindNetworkIntent
  )
import Prodbox.Control.KindNetworkReceipt
  ( NetworkReceiptKind (..)
  , NetworkReceiptObservation (..)
  , NetworkReceiptWrite (..)
  , NetworkTransport (..)
  , observeNetworkReceipt
  )
import Prodbox.Control.KindNetworkRecovery
  ( KindNetworkRecordedTransport (..)
  , KindNetworkRemovalAction (..)
  , withNewConnectedKindNetworkRecordedRemovalGuarded
  )
import Prodbox.Control.KindNodeCreateIntent
  ( KindNodeCreateRecoveryObservation (..)
  , KindAbsencePlanRecovery (..)
  , KindNodeCreateResultObservation (..)
  , KindNodeRemoveControlWrite (..)
  , KindNodeRemoveControlObservation (..)
  , KindNodeRemoveResultWrite (..)
  , kindNodeCreateDaemon
  , observeKindNodeCreateResult
  , observeKindNodeRemoveControl
  , observeRecordedKindNodeCreateIntent
  , recordKindNodeRemoveControl
  , recoverKindAbsencePlan
  )
import Prodbox.Control.KindNodeCreateOperation
  ( KindNodeRemoveAction (..)
  , withNewConnectedKindNodeRemoveGuarded
  )
import Prodbox.Control.KindNodeRemovalSampling
  ( nodeRemovalPositive
  , observeNodeRemovalPositiveControl
  )
import Prodbox.Control.KindNodeVolumeIntent
  ( KindNodeVolumeRemovalReceiptObservation (..)
  , KindNodeVolumeRemovalReceiptWrite (..)
  , mkKindNodeVolumeIntent
  , observeKindNodeVolumeRemovalReceipt
  )
import Prodbox.Control.KindNodeVolumeOperation
  ( KindNodeVolumeRemovalAction (..)
  , withNewConnectedKindNodeVolumeRemovalGuarded
  )
import System.FilePath ((</>))
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (getSymbolicLinkStatus)
import System.Posix.Types (Fd (..))

-- | One removal step and what was observed, never a bare success flag.
data DeleteStep = DeleteStep
  { deleteStepName :: !String
  , deleteStepCompleted :: !Bool
  , deleteStepDetail :: !String
  }
  deriving (Eq, Show)

-- A missing result alone says nothing about whether a request was submitted.
nodeNeverStarted :: KindNodeCreateResultObservation -> Maybe Bool -> Bool
nodeNeverStarted result attempted = result == NodeCreateResultMissing && attempted == Just False

-- These indicate a recorded successful transport reply only. Independent
-- resource read-back is still required before claiming absence.
nodeRemovalRecorded :: KindNodeRemoveAction -> Bool
nodeRemovalRecorded action = case action of
  NodeRemoveActionReturned (DockerNodeContainerRemoveReply 204) NodeRemoveResultRecorded -> True
  _ -> False

volumeRemovalRecorded :: KindNodeVolumeRemovalAction -> Bool
volumeRemovalRecorded action = case action of
  NodeVolumeRemovalActionReturned (DockerNodeVarRemoveReply 204) NodeVolumeRemovalReceiptRecorded -> True
  _ -> False

networkRemovalRecorded :: KindNetworkRemovalAction KindNetworkRecordedTransport -> Bool
networkRemovalRecorded action = case action of
  KindNetworkRemovalReturned
    ( KindNetworkRecordedTransport
        (NetworkRemovalTransport (DockerNetworkRemoveReply 204))
        NetworkReceiptRecorded
      ) -> True
  _ -> False

controlContainerId :: Maybe String -> Maybe String
controlContainerId output = case fmap words output of
  Just [identifier] | validImageId ("sha256:" ++ identifier) -> Just identifier
  _ -> Nothing

controlContainerMatches :: String -> String -> String -> Maybe String -> Maybe String -> Bool
controlContainerMatches identifier name operation inspected listed =
  validImageId ("sha256:" ++ identifier)
    && fmap words inspected == Just [identifier, '/' : name, operation, "false", "none"]
    && fmap words listed == Just [identifier]

priorVolumeRemovalRecorded :: KindNodeVolumeRemovalReceiptObservation -> Bool
priorVolumeRemovalRecorded observed = case observed of
  NodeVolumeRemovalReceiptObserved (DockerNodeVarRemoveReply 204) -> True
  _ -> False

priorNetworkRemovalRecorded :: NetworkReceiptObservation -> Bool
priorNetworkRemovalRecorded observed = case observed of
  NetworkReceiptObserved (NetworkRemovalTransport (DockerNetworkRemoveReply 204)) -> True
  _ -> False

-- A missing or incomplete probe journal does not establish namespace absence.
probeCleanupRecorded :: ProbeJournalObservation -> Bool
probeCleanupRecorded observed = case observed of
  ProbeJournalRemovalRecorded _ -> True
  _ -> False

-- A recorded recovery launch may still own a live worker. Until that
-- family's settlement is independently observed, its receipt cannot admit
-- node removal, even when the namespace removal itself was recorded.
probeCleanupPermitsNodeRemoval :: ProbeJournalObservation -> ProbeRecoveryLaunchObservation -> Bool
probeCleanupPermitsNodeRemoval journal launch = probeCleanupRecorded journal && launch == ProbeRecoveryLaunchMissing

probeRecoveryReceiptMatches :: String -> Request.ProbeRecoveryRequest -> ProbeRemovalAttemptObservation -> Bool
probeRecoveryReceiptMatches uid recovery attempt =
  uid == Request.probeRecoveryNamespaceUid recovery
    && attempt == ProbeRemovalAttemptObserved uid (Request.probeRecoveryId recovery)

-- Observe an existing cleanup family for an exact owner-first probe. New
-- sends remain unavailable until their slice can coexist with the retained
-- retirement proof. A return here is not itself a cleanup receipt.
recoverProbeForDelete :: BootstrapProjection -> IO (Maybe String)
recoverProbeForDelete bootstrap
  | scopeEnvironment (bootstrapScope bootstrap) /= Test = pure Nothing
  | otherwise = do
      intent <- observeKindOwnerFamilyIntent bootstrap
      case intent of
        KindIntentMatches operation -> do
          let namespace = "prodbox-netcheck-" ++ take 12 operation
          observed <- withRecoveredKindOperation bootstrap operation $ \stable -> do
            journal <- observeProbeJournal bootstrap operation namespace stable
            launch <- observeProbeRecoveryLaunch bootstrap operation namespace stable
            publication <- observeProbePublicationAttempt bootstrap operation namespace stable
            attempt <- observeProbeRemovalAttempt bootstrap operation namespace stable
            held <- stable
            pure (journal, launch, publication, attempt, held)
          case observed of
            KindOperationCallbackReturned (ProbeJournalRemovalMissing _, ProbeRecoveryLaunchMissing, ProbePublicationMissing, ProbeRemovalAttemptMissing, True) ->
              pure (Just "cleanup launch unavailable until family slice isolation is established")
            KindOperationCallbackReturned (ProbeJournalRemovalMissing uid, ProbeRecoveryLaunchObserved recovery, ProbePublicationMissing, ProbeRemovalAttemptMissing, True)
              | uid == Request.probeRecoveryNamespaceUid recovery ->
                  pure (Just "cleanup launch unavailable until family slice isolation is established")
            KindOperationCallbackReturned (ProbeJournalRemovalMissing uid, ProbeRecoveryLaunchObserved recovery, ProbePublicationObserved published, ProbeRemovalAttemptMissing, True)
              | recovery == published && uid == Request.probeRecoveryNamespaceUid recovery -> startVerifier operation recovery uid
            KindOperationCallbackReturned (ProbeJournalVerifierPending _ _ _ sent, ProbeRecoveryLaunchObserved _, ProbePublicationObserved _, _, True) ->
              if sent then recoverSuccessor operation namespace else resumeVerifier operation namespace
            KindOperationCallbackReturned (journal, ProbeRecoveryLaunchObserved recovery, ProbePublicationObserved published, _, True)
              | recovery == published && journalMatches recovery journal -> wait operation
            _ -> pure Nothing
        _ -> pure Nothing
 where
  budget = 600000000000 :: Word64
  journalMatches recovery journal = case journal of
    ProbeJournalRemovalMissing uid -> uid == Request.probeRecoveryNamespaceUid recovery
    ProbeJournalRemovalRecorded uid -> uid == Request.probeRecoveryNamespaceUid recovery
    ProbeJournalRemovalAttempted uid _ -> uid == Request.probeRecoveryNamespaceUid recovery
    ProbeJournalRemovalFailed uid _ _ -> uid == Request.probeRecoveryNamespaceUid recovery
    ProbeJournalRemovalRecordedAfterFailure uid _ _ -> uid == Request.probeRecoveryNamespaceUid recovery
    _ -> False
  wait operation = do
    now <- getMonotonicTimeNSec
    if now > maxBound - budget then pure (Just "cleanup observation deadline unavailable") else do
      let ending = now + budget
      outcome <- awaitKindFamilyCompletionWith getMonotonicTimeNSec threadDelay ending
        (withKindProbeFamilyRetirement ending bootstrap operation (const (pure ())))
      pure (Just ("cleanup family settlement: " ++ show outcome))
  startVerifier operation prior uid = do
    fresh <- prepareFreshKindFamilyRequest bootstrap operation
    identifier <- randomOperationId
    case (fresh, identifier) of
      (Right (controller, ending), Just verifierId) ->
        case Request.mkProbeRecoveryRequest controller verifierId uid >>= (\coordinates -> Request.mkIsolatedProbeVerifierRequest coordinates (Request.probeRecoveryId prior)) of
          Left failure -> pure (Just ("probe verifier request refused: " ++ show failure))
          Right verifier -> do
            launched <- launchKindProbeVerifier ending bootstrap verifier
            settleVerifier operation ("probe verifier submission: " ++ show launched)
      (Left failure, _) -> pure (Just ("probe verifier preparation refused: " ++ show failure))
      (_, Nothing) -> pure (Just "probe verifier identity unavailable")
  resumeVerifier operation namespace = do
    retained <- withRecoveredKindOperation bootstrap operation $ \stable -> observeProbeVerifierLaunch bootstrap operation namespace stable
    case retained of
      KindOperationCallbackReturned (ProbeVerifierLaunchObserved verifier) -> do
        now <- getMonotonicTimeNSec
        if now > maxBound - budget then pure (Just "probe verifier deadline unavailable") else do
          launched <- launchKindProbeVerifier (now + budget) bootstrap verifier
          settleVerifier operation ("probe verifier resumed: " ++ show launched)
      _ -> pure (Just "probe verifier identity unconfirmed")
  settleVerifier operation message = do
    let namespace = "prodbox-netcheck-" ++ take 12 operation
    observed <- withRecoveredKindOperation bootstrap operation $ \stable -> observeProbeJournal bootstrap operation namespace stable
    case observed of
      KindOperationCallbackReturned (ProbeJournalVerifierPending _ _ _ True) -> do
        settled <- waitVerifier operation
        pure (Just (message ++ "; " ++ maybe "verifier settlement unavailable" id settled))
      _ -> pure (Just (message ++ "; verifier journal: " ++ show observed))
  waitVerifier operation = do
    now <- getMonotonicTimeNSec
    if now > maxBound - budget then pure (Just "probe verifier observation deadline unavailable") else do
      let ending = now + budget
      outcome <- awaitKindFamilyCompletionWith getMonotonicTimeNSec threadDelay ending
        (withKindProbeVerifierRetirement ending bootstrap operation (const (pure ())))
      pure (Just ("probe verifier settlement: " ++ show outcome))
  recoverSuccessor operation namespace = do
    recorded <- withRecoveredKindOperation bootstrap operation $ \stable -> do
      first <- observeProbeVerifierLaunch bootstrap operation namespace stable
      marker <- observeProbeVerifierPublicationAttempt bootstrap operation namespace stable
      case first of
        ProbeVerifierLaunchObserved root | marker == ProbeVerifierLaunchObserved root -> do
          chain <- observeProbeSuccessorChainState bootstrap operation namespace root stable
          results <- case chain of
            ProbeSuccessorChainComplete entries -> mapM (\entry -> observeProbeRecord bootstrap operation namespace (ProbeSuccessorReadback entry) stable) entries
            ProbeSuccessorChainStaged entries _ -> mapM (\entry -> observeProbeRecord bootstrap operation namespace (ProbeSuccessorReadback entry) stable) entries
            _ -> pure []
          held <- stable
          pure (Just (root, chain, results, held))
        _ -> pure Nothing
    case recorded of
      KindOperationCallbackReturned (Just (first, ProbeSuccessorChainComplete entries, results, True))
        | not (null entries) && results == replicate (length entries - 1) ProbeMissing ++ [ProbeMatches] -> pure Nothing
        | all (== ProbeMissing) results -> startSuccessor operation first entries
      KindOperationCallbackReturned (Just (first, ProbeSuccessorChainStaged entries successor, results, True))
        | all (== ProbeMissing) results -> do
            now <- getMonotonicTimeNSec
            if now > maxBound - budget then pure (Just "successor observation deadline unavailable")
              else if now < Identity.hostExecutionWorkEnd (Request.kindRequestWindow (Request.probeRecoveryControllerRequest (Request.probeVerifierRecoveryRequest (Request.probeSuccessorVerifier successor))))
                then launchAndSettleSuccessor (now + budget) operation first entries successor
                else do
                  cancelled <- cancelKindProbeSuccessorBeforePublication (now + budget) bootstrap first entries successor
                  pure (Just ("staged successor cancellation: " ++ show cancelled))
      _ -> pure (Just ("successor chain unconfirmed: " ++ show recorded))
  startSuccessor operation first entries = do
    fresh <- prepareFreshKindFamilyRequest bootstrap operation
    identifier <- randomOperationId
    case (fresh, identifier) of
      (Right (controller, ending), Just successorId) -> do
        let firstCoordinates = Request.probeVerifierRecoveryRequest first
            predecessor = case reverse entries of
              latest : _ -> Request.probeRecoveryId (Request.probeVerifierRecoveryRequest (Request.probeSuccessorVerifier latest))
              [] -> Request.probeRecoveryId firstCoordinates
        case Request.mkProbeRecoveryRequest controller successorId (Request.probeRecoveryNamespaceUid firstCoordinates)
          >>= (\coordinates -> Request.mkIsolatedProbeVerifierRequest coordinates (Request.probeVerifierPriorId first))
          >>= (\verifier -> Request.mkProbeSuccessorRequest verifier predecessor) of
            Left failure -> pure (Just ("successor request refused: " ++ show failure))
            Right successor -> launchAndSettleSuccessor ending operation first entries successor
      (Left failure, _) -> pure (Just ("successor preparation refused: " ++ show failure))
      (_, Nothing) -> pure (Just "successor identity unavailable")
  launchAndSettleSuccessor ending operation first entries successor = do
    launched <- launchKindProbeSuccessor ending bootstrap first entries successor
    let namespace = "prodbox-netcheck-" ++ take 12 operation
        identity = Request.probeRecoveryId (Request.probeVerifierRecoveryRequest (Request.probeSuccessorVerifier successor))
    marker <- withRecoveredKindOperation bootstrap operation $ \stable ->
      observeProbeSuccessorPublication bootstrap operation namespace identity stable
    case marker of
      KindOperationCallbackReturned (ProbeSuccessorObserved retained) | retained == successor -> do
        now <- getMonotonicTimeNSec
        if now > maxBound - budget then pure (Just ("successor submission: " ++ show launched ++ "; observation deadline unavailable")) else do
          let observationEnd = now + budget
          settled <- awaitKindFamilyCompletionWith getMonotonicTimeNSec threadDelay observationEnd
            (withKindProbeSuccessorRetirement observationEnd bootstrap operation successor (const (pure ())))
          pure (Just ("successor submission: " ++ show launched ++ "; settlement: " ++ show settled))
      _ -> pure (Just ("successor submission: " ++ show launched ++ "; publication: " ++ show marker))

-- | Remove the recorded resources. Steps stop at the first failure and the
-- returned list says which ran. Nothing here proves absence on its own: the
-- caller should read the independent inventory afterwards.
deleteNewTestIdentity :: BootstrapProjection -> IO [DeleteStep]
deleteNewTestIdentity bootstrap
  | scopeEnvironment (bootstrapScope bootstrap) /= Test =
      pure [DeleteStep "scope" False "only a test identity may use early removal"]
  | otherwise = do
      recorded <- observeKindIntent bootstrap
      case recorded of
        KindIntentMatches operation -> do
          protocol <- observeKindFamilyIntent bootstrap
          let recoverFamily = do
                now <- getMonotonicTimeNSec
                let ending = now + 600000000000
                family <- withKindFamilyRetirement ending bootstrap operation $ \owner -> do
                  retired <- withRecoveredKindOperation bootstrap operation (retireKindFamilyPublishedInputs ending owner)
                  case retired of
                    KindOperationCallbackReturned (KindFamilyInputRetirement (Right ()) (Right ()) True) -> removeResources owner operation
                    other -> pure [DeleteStep "family inputs" False ("input retirement unconfirmed: " ++ show other)]
                case family of
                  KindFamilyRetirementRefused failure -> do
                    neverSent <- withNeverSentKindFamily ending bootstrap operation (removeNeverSent operation)
                    case neverSent of
                      KindFamilyNeverSentScopeReturned steps (Right ()) True ->
                        pure (DeleteStep "family settlement" True ("never-sent publication confirmed; submitted-family observation: " ++ show failure) : steps)
                      KindFamilyNeverSentScopeReturned steps closing scope ->
                        pure (steps ++ [DeleteStep "family settlement" False ("never-sent proof closing unconfirmed: " ++ show closing ++ "; scope stable: " ++ show scope)])
                      _ -> do
                        prePublication <- withCancelledPrePublicationKindFamily bootstrap operation (removeNeverSent operation)
                        case prePublication of
                          KindFamilyPrePublicationReturned steps True ->
                            pure (DeleteStep "family settlement" True ("pre-publication family cancelled; submitted-family observation: " ++ show failure) : steps)
                          KindFamilyPrePublicationReturned steps False ->
                            pure (steps ++ [DeleteStep "family settlement" False "pre-publication cancellation closing unconfirmed"])
                          KindFamilyPrePublicationRefused -> do
                            candidate <- case failure of
                              KindFamilyRecoveryRequestMissing -> either (const Nothing) Just <$> prepareFreshKindFamilyRequest bootstrap operation
                              _ -> pure Nothing
                            case candidate of
                              Just (request, _) -> do
                                unlaunched <- withCancelledUnlaunchedOwnerFamily bootstrap request (removeNeverSent operation)
                                case unlaunched of
                                  KindFamilyPrePublicationReturned steps True ->
                                    pure (DeleteStep "family settlement" True "unlaunched owner-family fenced before cleanup" : steps)
                                  KindFamilyPrePublicationReturned steps False ->
                                    pure (steps ++ [DeleteStep "family settlement" False "unlaunched owner-family cancellation closing unconfirmed"])
                                  KindFamilyPrePublicationRefused -> fallback failure neverSent ending operation
                              Nothing -> fallback failure neverSent ending operation
                  KindFamilyRetirementLeaseUnconfirmed -> pure [DeleteStep "family settlement" False "operation identity or lease unconfirmed"]
                  KindFamilyRetirementReturned steps closing scope ->
                    pure $ if closing == Right () && scope
                      then steps
                      else steps ++ [DeleteStep "family settlement" False ("closing observation unconfirmed: " ++ show closing ++ "; scope stable: " ++ show scope)]
          if protocol == KindIntentMatches operation
            then recoverFamily
            else do
              settlement <- withControllerRecoverySettlement recoverFamily
              pure $ either (\reason -> [DeleteStep "controller settlement" False reason]) id settlement
        other -> pure [DeleteStep "operation" False ("no exactly matching recorded operation: " ++ show other)]
 where
  fallback failure neverSent ending operation = do
    result <- recoverNeverSentKindFamilyInputs ending bootstrap operation
    pure [DeleteStep "family settlement" False (show failure ++ "; never-sent input recovery: " ++ show result
      ++ "; borrowed proof: " ++ show neverSent)]
  removeNeverSent operation admitted = do
    probe <- withRecoveredKindOperation bootstrap operation $ \stable -> do
      let namespace = "prodbox-netcheck-" ++ take 12 operation
          checked = admitted stable
      journal <- observeProbeJournal bootstrap operation namespace checked
      launch <- observeProbeRecoveryLaunch bootstrap operation namespace checked
      publication <- observeProbePublicationAttempt bootstrap operation namespace checked
      final <- checked
      pure (journal, launch, publication, final)
    case probe of
      KindOperationCallbackReturned (ProbeJournalEmpty, ProbeRecoveryLaunchMissing, ProbePublicationMissing, True) ->
        removeAll admitted operation
      other -> pure [DeleteStep "probe cleanup" False ("never-sent probe state unconfirmed: " ++ show other)]
  removeResources owner operation = do
    probe <- withRecoveredKindOperation bootstrap operation $ \stable -> do
      let namespace = "prodbox-netcheck-" ++ take 12 operation
          admitted = familyStable owner stable
      journal <- observeProbeJournal bootstrap operation namespace admitted
      launch <- observeProbeRecoveryLaunch bootstrap operation namespace admitted
      attempt <- observeProbeRemovalAttempt bootstrap operation namespace admitted
      publication <- observeProbePublicationAttempt bootstrap operation namespace admitted
      pure (journal, launch, attempt, publication)
    case probe of
      KindOperationCallbackReturned (ProbeJournalEmpty, ProbeRecoveryLaunchMissing, ProbeRemovalAttemptMissing, ProbePublicationMissing) -> do
        let admitted stable = do
              let original = familyStable owner stable
                  namespace = "prodbox-netcheck-" ++ take 12 operation
              before <- original
              protocol <- observeKindOwnerFamilyIntent bootstrap
              -- The original family and operation lease are checked around
              -- this whole local snapshot. Repeating that expensive proof
              -- inside each nested record read can exhaust a smaller record
              -- deadline before the exclusive removal attempt is written.
              journal <- observeProbeJournal bootstrap operation namespace (pure True)
              launch <- observeProbeRecoveryLaunch bootstrap operation namespace (pure True)
              publication <- observeProbePublicationAttempt bootstrap operation namespace (pure True)
              after <- original
              pure (before && protocol == KindIntentMatches operation && journal == ProbeJournalEmpty && launch == ProbeRecoveryLaunchMissing
                && publication == ProbePublicationMissing && after)
        qualified <- withRecoveredKindOperation bootstrap operation admitted
        if qualified == KindOperationCallbackReturned True
          then removeAll admitted operation
          else pure [DeleteStep "probe cleanup" False "empty probe journal is not bound to a settled owner-first family"]
      KindOperationCallbackReturned (journal, launch, ProbeRemovalAttemptMissing, ProbePublicationMissing)
        | probeCleanupPermitsNodeRemoval journal launch -> removeAll (familyStable owner) operation
      KindOperationCallbackReturned (ProbeJournalRemovalMissing uid, ProbeRecoveryLaunchObserved recovery, ProbeRemovalAttemptMissing, ProbePublicationObserved published)
        | uid == Request.probeRecoveryNamespaceUid recovery && recovery == published -> do
            now <- getMonotonicTimeNSec
            let ending = now + 600000000000
            settled <- withKindProbeFamilyRetirement ending bootstrap operation $ \cleanupOwner ->
              withRecoveredKindOperation bootstrap operation $ \stable ->
                retireKindProbeFamilyPublishedInputs ending cleanupOwner (familyStable owner stable)
            neverSent <- case settled of
              KindFamilyRetirementRefused _ -> Just <$> withRecoveredKindOperation bootstrap operation
                (\stable -> retireNeverSentKindProbeInputs ending owner bootstrap operation stable)
              _ -> pure Nothing
            pure [DeleteStep "probe cleanup" False
              ("probe namespace removal remains unconfirmed; cleanup family retirement and input disposition: " ++ show settled
                ++ "; never-sent publication recovery: " ++ show neverSent)]
      KindOperationCallbackReturned (ProbeJournalRemovalMissing uid, ProbeRecoveryLaunchObserved recovery, ProbeRemovalAttemptMissing, _)
        | uid == Request.probeRecoveryNamespaceUid recovery -> do
            now <- getMonotonicTimeNSec
            neverSent <- withRecoveredKindOperation bootstrap operation $
              retireNeverSentKindProbeInputs (now + 600000000000) owner bootstrap operation
            pure [DeleteStep "probe cleanup" False
              ("probe namespace removal remains unconfirmed; never-sent publication recovery: " ++ show neverSent)]
      KindOperationCallbackReturned (ProbeJournalRemovalRecorded uid, ProbeRecoveryLaunchObserved recovery, ProbeRemovalAttemptMissing, ProbePublicationObserved published)
        | recovery == published && uid == Request.probeRecoveryNamespaceUid recovery -> do
            now <- getMonotonicTimeNSec
            let ending = now + 600000000000
                namespace = "prodbox-netcheck-" ++ take 12 operation
            settled <- withKindProbeFamilyRetirement ending bootstrap operation $ \cleanupOwner -> do
              inputs <- withRecoveredKindOperation bootstrap operation $ \stable ->
                retireKindProbeFamilyPublishedInputs ending cleanupOwner (familyStable owner stable)
              case inputs of
                KindOperationCallbackReturned (KindFamilyInputRetirement (Right ()) (Right ()) True) -> do
                  let admitted stable = do
                        let original = familyStable owner stable
                        before <- original
                        physical <- verifyKindProbeFamilyRetirement cleanupOwner original
                        journal <- observeProbeJournal bootstrap operation namespace (pure True)
                        launch <- observeProbeRecoveryLaunch bootstrap operation namespace (pure True)
                        attempt <- observeProbeRemovalAttempt bootstrap operation namespace (pure True)
                        final <- original
                        pure (before && physical == Right () && journal == ProbeJournalRemovalRecorded uid
                          && launch == ProbeRecoveryLaunchObserved recovery && attempt == ProbeRemovalAttemptMissing && final)
                  removeAll admitted operation
                other -> pure [DeleteStep "probe family inputs" False ("input retirement unconfirmed: " ++ show other)]
            pure $ case settled of
              KindFamilyRetirementRefused failure -> [DeleteStep "probe family settlement" False (show failure)]
              KindFamilyRetirementLeaseUnconfirmed -> [DeleteStep "probe family settlement" False "operation identity or lease unconfirmed"]
              KindFamilyRetirementReturned steps closing scope ->
                if closing == Right () && scope then steps
                else steps ++ [DeleteStep "probe family settlement" False ("closing observation unconfirmed: " ++ show closing ++ "; scope stable: " ++ show scope)]
      KindOperationCallbackReturned (initialJournal, ProbeRecoveryLaunchObserved recovery, attempt, ProbePublicationObserved published)
        | recovery == published
        , let uid = Request.probeRecoveryNamespaceUid recovery
        , initialJournal == ProbeJournalRemovalRecorded uid || journalRecoveryFailureMatches initialJournal recovery
        , probeRecoveryReceiptMatches uid recovery attempt -> do
            now <- getMonotonicTimeNSec
            let ending = now + 600000000000
                namespace = "prodbox-netcheck-" ++ take 12 operation
                recoveryId = Request.probeRecoveryId recovery
            settled <- withKindProbeFamilyRetirement ending bootstrap operation $ \cleanupOwner -> do
              inputs <- withRecoveredKindOperation bootstrap operation $ \stable ->
                retireKindProbeFamilyPublishedInputs ending cleanupOwner (familyStable owner stable)
              case inputs of
                KindOperationCallbackReturned (KindFamilyInputRetirement (Right ()) (Right ()) True) -> do
                  let admitted stable = do
                        let original = familyStable owner stable
                        physical <- verifyKindProbeFamilyRetirement cleanupOwner original
                        journal <- observeProbeJournal bootstrap operation namespace original
                        launch <- observeProbeRecoveryLaunch bootstrap operation namespace original
                        currentAttempt <- observeProbeRemovalAttempt bootstrap operation namespace original
                        final <- original
                        pure (physical == Right () && journal == initialJournal
                          && launch == ProbeRecoveryLaunchObserved recovery
                          && currentAttempt == ProbeRemovalAttemptObserved uid recoveryId && final)
                  removeAll admitted operation
                other -> pure [DeleteStep "probe family inputs" False ("input retirement unconfirmed: " ++ show other)]
            pure $ case settled of
              KindFamilyRetirementRefused failure -> [DeleteStep "probe family settlement" False (show failure)]
              KindFamilyRetirementLeaseUnconfirmed -> [DeleteStep "probe family settlement" False "operation identity or lease unconfirmed"]
              KindFamilyRetirementReturned steps closing scope ->
                if closing == Right () && scope then steps
                else steps ++ [DeleteStep "probe family settlement" False ("closing observation unconfirmed: " ++ show closing ++ "; scope stable: " ++ show scope)]
      KindOperationCallbackReturned (initialJournal@(ProbeJournalAttemptReadbackRecorded uid recoveryId _), ProbeRecoveryLaunchObserved recovery, attempt, ProbePublicationObserved published)
        | recovery == published && uid == Request.probeRecoveryNamespaceUid recovery
        , recoveryId == Request.probeRecoveryId recovery
        , attempt == ProbeRemovalAttemptMissing || probeRecoveryReceiptMatches uid recovery attempt -> do
            now <- getMonotonicTimeNSec
            let ending = now + 600000000000
                namespace = "prodbox-netcheck-" ++ take 12 operation
            settled <- withKindProbeFamilyRetirement ending bootstrap operation $ \cleanupOwner ->
              withKindProbeVerifierRetirement ending bootstrap operation $ \verifierOwner -> do
                inputs <- withRecoveredKindOperation bootstrap operation $ \stable -> do
                  let original = familyStable owner stable
                      previous = (== Right ()) <$> verifyKindProbeFamilyRetirement cleanupOwner original
                  cleanup <- retireKindProbeFamilyPublishedInputs ending cleanupOwner original
                  verifier <- retireKindProbeVerifierPublishedInputs ending verifierOwner previous
                  pure (cleanup, verifier)
                case inputs of
                  KindOperationCallbackReturned (KindFamilyInputRetirement (Right ()) (Right ()) True, KindFamilyInputRetirement (Right ()) (Right ()) True) -> do
                    let admitted stable = do
                          let original = familyStable owner stable
                          cleanup <- verifyKindProbeFamilyRetirement cleanupOwner original
                          verifier <- verifyKindProbeVerifierRetirement verifierOwner original
                          journal <- observeProbeJournal bootstrap operation namespace original
                          final <- original
                          pure (cleanup == Right () && verifier == Right () && journal == initialJournal && final)
                    removeAll admitted operation
                  other -> pure [DeleteStep "probe family inputs" False ("input retirement unconfirmed: " ++ show other)]
            pure $ case settled of
              KindFamilyRetirementRefused failure -> [DeleteStep "probe family settlement" False (show failure)]
              KindFamilyRetirementLeaseUnconfirmed -> [DeleteStep "probe family settlement" False "operation identity or lease unconfirmed"]
              KindFamilyRetirementReturned inner closing scope ->
                let steps = case inner of
                      KindFamilyRetirementRefused failure -> [DeleteStep "probe verifier settlement" False (show failure)]
                      KindFamilyRetirementLeaseUnconfirmed -> [DeleteStep "probe verifier settlement" False "operation identity or lease unconfirmed"]
                      KindFamilyRetirementReturned result verifierClosing verifierScope ->
                        if verifierClosing == Right () && verifierScope then result
                        else result ++ [DeleteStep "probe verifier settlement" False ("closing observation unconfirmed: " ++ show verifierClosing ++ "; scope stable: " ++ show verifierScope)]
                 in if closing == Right () && scope then steps
                    else steps ++ [DeleteStep "probe family settlement" False ("closing observation unconfirmed: " ++ show closing ++ "; scope stable: " ++ show scope)]
      KindOperationCallbackReturned (initialJournal@(ProbeJournalVerifierPending _ _ _ True), ProbeRecoveryLaunchObserved recovery, _, ProbePublicationObserved published)
        | recovery == published -> removeSuccessorReadback owner operation initialJournal
      other -> pure [DeleteStep "probe cleanup" False ("probe cleanup unconfirmed: " ++ show other)]
  removeSuccessorReadback owner operation initialJournal = do
    let namespace = "prodbox-netcheck-" ++ take 12 operation
    observed <- withRecoveredKindOperation bootstrap operation $ \stable -> do
      let admitted = familyStable owner stable
      first <- observeProbeVerifierLaunch bootstrap operation namespace admitted
      marker <- observeProbeVerifierPublicationAttempt bootstrap operation namespace admitted
      case first of
        ProbeVerifierLaunchObserved root | marker == ProbeVerifierLaunchObserved root -> do
          chain <- observeProbeSuccessorChainState bootstrap operation namespace root admitted
          case chain of
            ProbeSuccessorChainComplete entries -> case reverse entries of
              latest : previous -> do
                results <- mapM (\entry -> observeProbeRecord bootstrap operation namespace (ProbeSuccessorReadback entry) admitted) entries
                pure $ if results == replicate (length previous) ProbeMissing ++ [ProbeMatches]
                  then Just (root, entries, latest) else Nothing
              [] -> pure Nothing
            _ -> pure Nothing
        _ -> pure Nothing
    case observed of
      KindOperationCallbackReturned (Just (first, successors, latest)) -> do
        now <- getMonotonicTimeNSec
        let ending = now + 600000000000
        settled <- withKindProbeFamilyRetirement ending bootstrap operation $ \priorOwner ->
          withKindProbeVerifierRetirement ending bootstrap operation $ \firstOwner -> do
            let admission = do
                  original <- verifyKindFamilyRetirement owner (pure True)
                  prior <- verifyKindProbeFamilyRetirement priorOwner (pure True)
                  firstRetired <- verifyKindProbeVerifierRetirement firstOwner (pure True)
                  pure (original == Right () && prior == Right () && firstRetired == Right ())
            withKindProbeSuccessorRetirementChain ending bootstrap operation first successors admission $ \owners -> do
              retired <- withRecoveredKindOperation bootstrap operation $ \stable -> do
                let original = familyStable owner stable
                    previous = (== Right ()) <$> verifyKindProbeFamilyRetirement priorOwner original
                cleanup <- retireKindProbeFamilyPublishedInputs ending priorOwner original
                verifier <- retireKindProbeVerifierPublishedInputs ending firstOwner previous
                children <- mapM (\child -> retireKindProbeSuccessorPublishedInputs ending child ((&&) <$> stable <*> admission)) owners
                pure (cleanup, verifier, children)
              case retired of
                KindOperationCallbackReturned (KindFamilyInputRetirement (Right ()) (Right ()) True, KindFamilyInputRetirement (Right ()) (Right ()) True, children)
                  | all (== KindFamilyInputRetirement (Right ()) (Right ()) True) children -> do
                      let admitted stable = do
                            let base = (&&) <$> stable <*> admission
                            held <- verifyKindProbeSuccessorRetirementChain bootstrap operation first successors owners base
                            journal <- observeProbeJournal bootstrap operation namespace (pure True)
                            results <- mapM (\entry -> observeProbeRecord bootstrap operation namespace (ProbeSuccessorReadback entry) (pure True)) successors
                            after <- base
                            pure (held && journal == initialJournal && results == replicate (length successors - 1) ProbeMissing ++ [ProbeMatches]
                              && latest `elem` successors && after)
                      removeAll admitted operation
                other -> pure [DeleteStep "probe successor inputs" False ("input retirement unconfirmed: " ++ show other)]
        pure $ case settled of
          KindFamilyRetirementReturned (KindFamilyRetirementReturned (KindProbeSuccessorChainReturned steps chainClosing) firstClosing firstScope) priorClosing priorScope ->
            if chainClosing && firstClosing == Right () && firstScope && priorClosing == Right () && priorScope then steps
            else steps ++ [DeleteStep "probe successor settlement" False "predecessor closing observation unconfirmed"]
          other -> [DeleteStep "probe successor settlement" False (show other)]
      _ -> pure [DeleteStep "probe cleanup" False "successor readback or identity unconfirmed"]
  journalRecoveryFailureMatches observed recovery = case observed of
    ProbeJournalRemovalRecordedAfterFailure uid recoveryId _ ->
      uid == Request.probeRecoveryNamespaceUid recovery && recoveryId == Request.probeRecoveryId recovery
    _ -> False
  removeAll admitted operation = do
    node <- removeNode admitted operation
    if not (deleteStepCompleted (last node)) then pure node else do
      volume <- removeVolume admitted operation
      if not (deleteStepCompleted volume) then pure (node ++ [volume]) else do
        network <- removeNetwork admitted operation
        pure (node ++ [volume, network])
  familyStable :: KindFamilyRetirement -> IO Bool -> IO Bool
  familyStable owner stable = isRight <$> verifyKindFamilyRetirement owner stable
  removeNode admitted operation = do
    known <- withRecoveredKindOperation bootstrap operation $ \stable -> do
      proposal <- observeRecordedKindNodeCreateIntent bootstrap operation stable
      observed <- case proposal of
        NodeCreateRecoveryRecorded intent -> do
          created <- observeKindNodeCreateResult bootstrap intent stable
          pure (Just (intent, created))
        _ -> pure Nothing
      planned <- recordPresent "kind-node-create-intent.json"
      attempted <- recordPresent "kind-node-create-attempt.json"
      unchanged <- admitted stable
      pure (observed, planned, attempted, unchanged)
    case known of
      KindOperationCallbackReturned
        ( Just (intent, NodeCreateResultObserved (DockerNodeContainerCreateReply 201 (Just containerId)))
          , _
          , _
          , True
          ) -> do
          daemon <- observeDockerDaemon socketOf
          positive <-
            observeNodeRemovalPositiveControl bootstrap (kindNodeCreateDaemon intent) containerId (pure True)
          if daemon /= kindNodeCreateDaemon intent
            then pure [DeleteStep "node" False "the daemon is not the one recorded for this node"]
            else
              if not (nodeRemovalPositive containerId positive)
                then recoverAbsenceControl admitted operation
                else do
                  control <-
                    withRecoveredKindOperation bootstrap operation $ \stable -> do
                      let qualified = admitted stable
                      recorded <- recordKindNodeRemoveControl bootstrap intent containerId qualified
                      case recorded of
                        NodeRemoveControlRecorded -> pure True
                        NodeRemoveControlAlreadyExists -> do
                          retained <- observeKindNodeRemoveControl bootstrap intent containerId qualified
                          final <- qualified
                          pure (retained == NodeRemoveControlMatches && final)
                        _ -> pure False
                  case control of
                    KindOperationCallbackReturned True -> do
                      removed <- withNewConnectedKindNodeRemoveGuarded bootstrap operation admitted (\_ _ _ stable -> stable)
                      pure [DeleteStep "node" (nodeRemoved removed) (show removed)]
                    other -> pure [DeleteStep "node" False ("removal control record not written: " ++ show other)]
      KindOperationCallbackReturned (Just (_, observed), _, attempted, True) -> do
        -- A missing result and an independently absent attempt are both
        -- required; invalid or unreadable results retain their state.
        pure $
          if nodeNeverStarted observed attempted
            then [DeleteStep "node" True "no node create attempt was recorded, so no node effect was started"]
            else
              [ DeleteStep
                  "node"
                  False
                  "node create result or attempt is present or unobservable; records are retained for recovery"
              ]
      KindOperationCallbackReturned (Nothing, planned, attempted, True) -> do
        -- No node proposal was recoverable. Only an absent intent record (no
        -- node effect was ever planned) is a disposition; a present but
        -- unreadable one keeps its records for recovery.
        pure $
          if planned == Just False && attempted == Just False
            then
              [ DeleteStep
                  "node"
                  True
                  "no node create intent was recorded, so no node effect was planned or started"
              ]
            else
              [ DeleteStep
                  "node"
                  False
                  "a node create record exists but its identity is unavailable; records are retained for recovery"
              ]
      other -> pure [DeleteStep "node" False ("recorded node identity unavailable: " ++ show other)]
  recoverAbsenceControl admitted operation = do
    recovered <- withRecoveredKindOperation bootstrap operation $ \stable ->
      recoverKindAbsencePlan bootstrap operation (admitted stable)
    case recovered of
      KindOperationCallbackReturned (AbsencePlanObserved plan) -> do
        cleanup <- recoverExistingAbsenceControl bootstrap plan admitted
        pure
          [ DeleteStep "absence-control cleanup" False (show cleanup)
          , DeleteStep "node" False "node and control-container absence remain unconfirmed; records are retained"
          ]
      other -> pure [DeleteStep "node" False ("node absence needs an owned, recoverable positive control: " ++ show other)]
  nodeRemoved outcome = case outcome of
    KindOperationCallbackReturned
      (DockerPeerCompleted (DockerConnectedInfoCompleted action)) -> nodeRemovalRecorded action
    _ -> False
  removeVolume admitted operation = do
    records <- withRecoveredKindOperation bootstrap operation $ \stable -> do
      planned <- recordPresent "kind-node-var-volume-intent.json"
      attempted <- recordPresent "kind-node-var-volume-attempt.json"
      removed <- recordPresent "kind-node-var-volume-removal-result.json"
      unchanged <- admitted stable
      pure (planned, attempted, removed, unchanged)
    case records of
      KindOperationCallbackReturned (Just False, Just False, Just False, True) ->
        pure (DeleteStep "volume" True "no volume create intent or attempt was recorded")
      KindOperationCallbackReturned (Just True, _, Just True, True) -> verifyPriorVolume operation
      KindOperationCallbackReturned (Just True, _, Just False, True) -> removeRecordedVolume admitted operation
      _ ->
        pure
          (DeleteStep "volume" False "volume records are inconsistent or unobservable; recovery is required")
  verifyPriorVolume operation = do
    daemon <- observeDockerDaemon socketOf
    observed <- case mkKindNodeVolumeIntent operation daemon of
      Nothing -> pure Nothing
      Just intent -> do
        outcome <- withRecoveredKindOperation bootstrap operation $ \stable ->
          observeKindNodeVolumeRemovalReceipt bootstrap intent stable
        pure $ case outcome of
          KindOperationCallbackReturned receipt -> Just receipt
          _ -> Nothing
    pure $
      if maybe False priorVolumeRemovalRecorded observed
        then DeleteStep "volume" True "the bound volume removal receipt records a successful reply"
        else DeleteStep "volume" False "the prior volume removal receipt is invalid or unobservable"
  removeRecordedVolume admitted operation = do
    removed <-
      withNewConnectedKindNodeVolumeRemovalGuarded
        bootstrap
        operation
        admitted
        (\_ stable -> stable)
        (\session stable -> removeDockerSessionNodeVarVolume session bootstrap operation stable)
    pure (DeleteStep "volume" (volumeRemoved removed) (show removed))
  removeNetwork admitted operation = do
    observed <- withRecoveredKindOperation bootstrap operation $ \stable -> do
      protocol <- observeKindOwnerFamilyIntent bootstrap
      records <- traverse recordPresent
        [ "kind-network-intent.json", "kind-network-attempt.json"
        , "kind-network-create-result.json", "kind-network-removal.json"
        , "kind-network-removal-result.json" ]
      unchanged <- admitted stable
      pure (protocol, records, unchanged)
    case observed of
      KindOperationCallbackReturned (KindIntentMatches current, records, True)
        | current == operation && records == replicate 5 (Just False) ->
            pure (DeleteStep "network" True "no owner-family network intent or attempt was recorded")
      KindOperationCallbackReturned (_, [_, _, _, _, Just True], True) -> verifyPriorNetwork operation
      KindOperationCallbackReturned (_, [_, _, _, _, Just False], True) -> removeRecordedNetwork admitted operation
      _ -> pure (DeleteStep "network" False "network removal record is unobservable; recovery is required")
  verifyPriorNetwork operation = do
    observed <- withRecoveredKindOperation bootstrap operation $ \stable -> do
      proposal <- observeRecordedKindNetworkIntent bootstrap operation stable
      case proposal of
        NetworkRecoveryRecorded intent -> do
          created <- observeNetworkReceipt bootstrap intent NetworkCreateReceipt stable
          case created of
            NetworkReceiptObserved (NetworkCreateTransport (DockerNetworkCreateReply 201 (Just networkId))) ->
              Just <$> observeNetworkReceipt bootstrap intent (NetworkRemovalReceipt networkId) stable
            _ -> pure Nothing
        _ -> pure Nothing
    pure $ case observed of
      KindOperationCallbackReturned (Just receipt)
        | priorNetworkRemovalRecorded receipt ->
            DeleteStep "network" True "the bound network removal receipt records a successful reply"
      _ -> DeleteStep "network" False "the prior network removal receipt is invalid or unobservable"
  removeRecordedNetwork admitted operation = do
    identifier <- withRecoveredKindOperation bootstrap operation $ \stable -> do
      proposal <- observeRecordedKindNetworkIntent bootstrap operation stable
      case proposal of
        NetworkRecoveryRecorded intent -> do
          receipt <- observeNetworkReceipt bootstrap intent NetworkCreateReceipt stable
          pure $ case receipt of
            NetworkReceiptObserved (NetworkCreateTransport (DockerNetworkCreateReply 201 (Just networkId)))
              | kindNetworkDaemon intent /= DockerDaemonUnobservable -> Just (Right networkId)
            NetworkReceiptObserved (NetworkCreateTransport (DockerNetworkCreateReply 409 Nothing)) -> Just (Left (409 :: Int))
            _ -> Nothing
        _ -> pure Nothing
    case identifier of
      KindOperationCallbackReturned (Just (Left status)) ->
        pure
          ( DeleteStep
              "network"
              True
              ("the network create was refused with status " ++ show status ++ ", so no network was created")
          )
      KindOperationCallbackReturned (Just (Right networkId)) -> do
        removed <-
          withNewConnectedKindNetworkRecordedRemovalGuarded bootstrap operation networkId admitted $ \session stable ->
            removeDockerSessionKindNetwork session networkId stable
        pure (DeleteStep "network" (networkRemoved removed) (show removed))
      other -> pure (DeleteStep "network" False ("recorded network identity unavailable: " ++ show other))
  volumeRemoved outcome = case outcome of
    KindOperationCallbackReturned
      (DockerPeerCompleted (DockerConnectedInfoCompleted action)) -> volumeRemovalRecorded action
    _ -> False
  networkRemoved outcome = case outcome of
    KindOperationCallbackReturned
      (DockerPeerCompleted (DockerConnectedInfoCompleted action)) -> networkRemovalRecorded action
    _ -> False
  socketOf = bootstrapRuntimeSocket bootstrap
  recordPresent name = do
    let scope = bootstrapScope bootstrap
        generation = Text.unpack (bootstrapRootGeneration bootstrap)
    observed <- withScopeRootDescriptor scope $ \(Fd raw) sameRoot -> do
      before <- observeScopeGeneration scope generation
      status <- try (getSymbolicLinkStatus ("/proc/self/fd/" ++ show raw </> name))
      stable <- sameRoot
      after <- observeScopeGeneration scope generation
      pure $
        if not stable || before /= Right ScopeGenerationMatches || after /= before
          then Nothing
          else case status of
            Right _ -> Just True
            Left (failure :: IOException) -> if isDoesNotExistError failure then Just False else Nothing
    pure (either (const Nothing) id observed)
