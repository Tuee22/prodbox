{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Prepare a retained root for a new operation after a previous one was
-- completely removed. Nothing is deleted: the previous operation's records,
-- its worker directory and its cluster credential are moved with renameat
-- into @history/<operation>/@, so the new operation can create its own
-- exclusive records while the old ones stay as evidence. The host data, the
-- generation record and the retained artifacts are not touched. The move is
-- refused until the old operation settles and its owned resources have been
-- independently checked. The owner-family path also requires the retained
-- teardown admission and the original probe's removal receipt.
module Prodbox.Control.Recreate
  ( ArchiveOutcome (..)
  , ArchiveIntentDecision (..)
  , classifyArchiveIntent
  , probeArchiveRecord
  , archiveCompletedOperation
  ) where

import Control.Exception (IOException, bracket, try)
import Control.Monad (forM, forM_)
import Data.Bits ((.&.))
import Data.Either (isRight)
import Data.List (isPrefixOf, nub, stripPrefix)
import Data.Maybe (isJust, mapMaybe)
import Foreign.C.Error (throwErrnoIfMinus1_)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..), CUInt (..))
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapRootGeneration
  , bootstrapRuntimeSocket
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope (scopeKindName, withScopeRootDescriptor)
import Prodbox.Control.AuthorityJournalClient
  ( AuthorityRemovalObservation (..)
  , authorityRemovalValue
  , observeAuthorityRemoval
  , observeKindTeardownAdmissionUnderLease
  , withBoundAuthorityRemoval
  )
import Prodbox.Control.DockerConnectedInfo
  ( DockerConnectedInfo (..)
  , DockerConnectedInfoResult (..)
  , DockerNetworkCreateResult (DockerNetworkCreateReply)
  , DockerNetworkRemoveResult (DockerNetworkRemoveReply)
  , DockerNodeContainerCreateResult (DockerNodeContainerCreateReply)
  , DockerNodeContainerRemoveResult (DockerNodeContainerRemoveReply)
  , DockerNodeVarRemoveResult (DockerNodeVarRemoveReply)
  , DockerNodeVarVolumeObservation (DockerNodeVarVolumeNotFound)
  , inspectDockerSessionNodeVarVolume
  , readDockerSessionKindContainers
  , readDockerSessionKindNodeNameNotFound
  , withConnectedDockerInfo
  )
import Prodbox.Control.DockerIdentity
  ( DockerDaemonObservation (DockerDaemonObserved)
  , observeDockerDaemon
  , readDocker
  )
import Prodbox.Control.DockerPeer (DockerPeer (..), DockerPeerResult (..))
import Prodbox.Control.KindArchiveTransaction
  ( ArchiveTransactionRecovery (..)
  , authorityArchiveRecordName
  , confirmPublishedAuthorityArchive
  , publishKindArchive
  , recoverKindArchive
  , retireArchivedAuthorityFence
  )
import Prodbox.Control.KindControllerReceipt (withControllerRecoverySettlement)
import Prodbox.Control.KindFamilyRecovery
  ( KindFamilyRetirementOutcome (KindFamilyRetirementReturned)
  , verifyKindFamilyRetirement
  , withKindFamilyRetirement
  )
import Prodbox.Control.KindIntent
  ( KindIntentObservation (..)
  , observeKindIntent
  , observeKindOwnerFamilyIntent
  )
import Prodbox.Control.KindLease
  ( KindLeaseOutcome (KindLeaseCompleted)
  , KindOperationOutcome (KindOperationCallbackReturned)
  , withKindLease
  , withRecoveredKindOperation
  )
import Prodbox.Control.KindNetworkIntent
  ( KindNetworkRecoveryObservation (NetworkRecoveryRecorded)
  , kindNetworkDaemon
  , observeRecordedKindNetworkIntent
  )
import Prodbox.Control.KindNetworkProbeRecord
  ( ProbePublicationObservation (ProbePublicationMissing)
  , ProbeRecoveryLaunchObservation (ProbeRecoveryLaunchMissing)
  , observeProbePublicationAttempt
  , observeProbeRecoveryLaunch
  )
import Prodbox.Control.KindNetworkReceipt
  ( NetworkReceiptKind (..)
  , NetworkReceiptObservation (NetworkReceiptObserved)
  , NetworkTransport (..)
  , observeNetworkReceipt
  )
import Prodbox.Control.KindNetworkRecovery
  ( observeRecordedNetworkAbsent
  , observeUnattemptedNetworkAbsent
  )
import Prodbox.Control.KindNodeBootstrap
  ( JournalRecordObservation (..)
  , observeJournalRecord
  , writeJournalRecord
  )
import Prodbox.Control.KindNodeCreateIntent
  ( KindNodeCreateAttemptObservation (NodeCreateAttemptMissing)
  , KindNodeCreateRecoveryObservation (NodeCreateRecoveryRecorded)
  , KindNodeCreateResultObservation (..)
  , KindNodeRemoveResultObservation (NodeRemoveResultObserved)
  , observeKindNodeCreateAttempt
  , observeKindNodeCreateResult
  , observeKindNodeRemoveResult
  , observeRecordedKindNodeCreateIntent
  )
import Prodbox.Control.KindNodeRemovalReadback
  ( observeProposedNodeNameAbsent
  , observeRecordedNodeAbsent
  )
import Prodbox.Control.KindNodeVolumeIntent
  ( KindNodeVolumeRemovalReceiptObservation (NodeVolumeRemovalReceiptObserved)
  , mkKindNodeVolumeIntent
  , observeKindNodeVolumeRemovalReceipt
  )
import Prodbox.Control.KindNodeVolumeReadback (observeRecordedNodeVolumeAbsent)
import Prodbox.Control.NetworkEnforcement
  ( ProbeJournalObservation (ProbeJournalEmpty, ProbeJournalRemovalRecorded)
  , observeProbeJournal
  )
import Prodbox.Control.ServiceSupport (serviceOperationRecordNames)
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)
import System.Posix.Directory (closeDirStream, openDirStream, readDirStream)
import System.Posix.Files qualified as Files
import System.Posix.IO qualified as Posix
import System.Posix.Types (CMode (..), Fd (..))
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

data ArchiveOutcome
  = ArchiveNothingRecorded
  | ArchiveNotCompletelyRemoved !String
  | ArchiveContainerStillListed
  | ArchiveInventoryUnobservable
  | ArchiveMoved !String ![String]
  | ArchiveFailed !String
  deriving (Eq, Show)

data ArchiveIntentDecision
  = ArchiveNoIntent
  | ArchiveKnownIntent !String
  | ArchiveIntentUnconfirmed
  deriving (Eq, Show)

-- A conflicting or unreadable record cannot authorize a new operation. The
-- volume-bound variant requires its own recovery adapter and is not silently
-- treated as an absent record.
classifyArchiveIntent :: KindIntentObservation -> ArchiveIntentDecision
classifyArchiveIntent observation = case observation of
  KindIntentMissing -> ArchiveNoIntent
  KindIntentMatches operation -> ArchiveKnownIntent operation
  KindIntentVolumeMatches {} -> ArchiveIntentUnconfirmed
  KindIntentConflict -> ArchiveIntentUnconfirmed
  KindIntentInvalid -> ArchiveIntentUnconfirmed
  KindIntentGenerationUnavailable -> ArchiveIntentUnconfirmed
  KindIntentObservationUnobservable -> ArchiveIntentUnconfirmed

foreign import capi "stdio.h renameat2"
  renameAt :: CInt -> CString -> CInt -> CString -> CUInt -> IO CInt
foreign import capi "stdio.h value RENAME_NOREPLACE" noReplace :: CUInt
foreign import capi "sys/stat.h mkdirat" makeDirectoryAt :: CInt -> CString -> CMode -> IO CInt

directoryFlags :: Posix.OpenFileFlags
directoryFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.directory = True}

-- Nothing denotes an unsafe or unobservable entry; only ENOENT is absence.
probeArchiveRecord :: Fd -> FilePath -> IO (Maybe Bool)
probeArchiveRecord root name
  | null name || name `elem` [".", ".."] || '/' `elem` name = pure Nothing
  | otherwise = do
      owner <- getEffectiveUserID
      status <-
        try (Files.getSymbolicLinkStatus ("/proc/self/fd/" ++ show (fdNumber root) ++ "/" ++ name))
      pure $ case status of
        Right observed
          | Files.isRegularFile observed
              && Files.fileOwner observed == owner
              && Files.fileMode observed .&. 0o022 == 0
              && Files.linkCount observed == 1 ->
              Just True
          | otherwise -> Nothing
        Left (failure :: IOException)
          | isDoesNotExistError failure -> Just False
          | otherwise -> Nothing

fdNumber :: Fd -> CInt
fdNumber (Fd descriptor) = descriptor

removalResults :: [FilePath]
removalResults =
  [ "kind-node-remove-result.json"
  , "kind-node-var-volume-removal-result.json"
  , "kind-network-removal-result.json"
  ]

-- | Names that belong to one operation and are moved aside. The generation
-- record, the artifacts, the history directory itself and all host data stay.
belongsToOperation :: String -> FilePath -> Bool
belongsToOperation operation name =
  ("kind-" `isPrefixOf` name && name /= "kind-intent-history")
    || "node-image-" `isPrefixOf` name
    || name == "kind-worker-" ++ operation

data FamilyTeardownBasis = EarlyFamilyTeardown | AuthorityFamilyTeardown
  deriving (Eq)

archiveCompletedOperation :: BootstrapProjection -> IO ArchiveOutcome
archiveCompletedOperation bootstrap = do
  recovered <- withKindLease bootstrap $ \stable ->
    withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot ->
      timeout 20000000 $
        recoverKindArchive
          root
          ((&&) <$> sameRoot <*> stable)
          (bootstrapRootGeneration bootstrap)
          archiveRecordName
  case recovered of
    Right (KindLeaseCompleted (Right (Just ArchiveTransactionAbsent))) -> archiveObservedOperation
    Right (KindLeaseCompleted (Right (Just ArchiveTransactionRestored))) -> archiveObservedOperation
    _ -> pure (ArchiveFailed "the retained archive transaction or scope lease is unconfirmed")
 where
  archiveObservedOperation = do
    recorded <- observeKindIntent bootstrap
    case classifyArchiveIntent recorded of
      ArchiveKnownIntent operation -> do
        owner <- observeKindOwnerFamilyIntent bootstrap
        if owner == KindIntentMatches operation
          then archiveRetiredFamily operation
          else archiveLegacy operation
      ArchiveNoIntent -> noOperationRecords
      ArchiveIntentUnconfirmed -> pure (ArchiveFailed "operation intent is conflicting, unavailable or unsupported")
  archiveLegacy operation = do
    settlement <- withControllerRecoverySettlement $ do
      leased <- withRecoveredKindOperation bootstrap operation $ \stable -> do
        before <- stable
        if before
          then inspectInventory operation stable
          else pure (ArchiveFailed "operation identity changed")
      pure $ case leased of
        KindOperationCallbackReturned outcome -> outcome
        _ ->
          ArchiveFailed
            ( "operation "
                ++ operation
                ++ " lease or identity is unconfirmed; inspect retained root and history/"
                ++ operation
            )
    pure (either ArchiveFailed id settlement)
  archiveRetiredFamily operation = do
    now <- getMonotonicTimeNSec
    let duration = 120000000000
    if now > maxBound - duration
      then pure (ArchiveFailed "retirement deadline unavailable")
      else do
        retired <- withKindFamilyRetirement (now + duration) bootstrap operation $ \owner ->
          withRecoveredKindOperation bootstrap operation $ \stable ->
            confirmFamilyRemoval operation (isRight <$> verifyKindFamilyRetirement owner stable)
        case retired of
          KindFamilyRetirementReturned
            (KindOperationCallbackReturned (Just (credentialExpected, basis)))
            (Right ())
            True -> do
              moved <- withKindLease bootstrap $ \stable -> do
                confirmed <- confirmFamilyRemoval operation stable
                if confirmed /= Just (credentialExpected, basis)
                  then pure (ArchiveNotCompletelyRemoved "teardown observations changed before archiving")
                  else do
                    archived <- withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
                      let selected = (&&) <$> sameRoot <*> stable
                      credential <- existsNested root
                      held <- selected
                      if held && credential == Just credentialExpected
                        then archiveFamily root selected operation credentialExpected basis
                        else pure (ArchiveFailed "the retained scope or credential changed before archiving")
                    pure (either (const (ArchiveFailed "scope root unobservable")) id archived)
              pure $ case moved of
                Right (KindLeaseCompleted outcome) -> outcome
                _ -> ArchiveFailed ("archive closing unconfirmed for operation " ++ operation)
          _ ->
            pure
              ( ArchiveNotCompletelyRemoved
                  "teardown admission, resource read-back or family retirement unconfirmed"
              )
  archiveFamily root stable operation credential basis = case basis of
    EarlyFamilyTeardown -> moveOwnerOperationRecords root stable operation credential "kind-teardown-admission.json"
    AuthorityFamilyTeardown -> do
      let expected = authorityRemovalValue bootstrap operation
      _ <- writeJournalRecord bootstrap authorityArchiveRecordName expected
      current <- observeJournalRecord bootstrap authorityArchiveRecordName
      ready <- stable
      if current == JournalRecordObserved expected && ready
        then do
          moved <- moveOwnerOperationRecords root stable operation credential authorityArchiveRecordName
          case moved of
            archived@ArchiveMoved {} -> do
              released <- retireAuthorityAfterArchive root stable operation
              pure $
                if released
                  then archived
                  else
                    ArchiveFailed
                      ("kind archive was published; Authority removal retirement is unconfirmed for " ++ operation)
            _ -> pure moved
        else pure (ArchiveFailed "Authority archive record is unconfirmed")
  retireAuthorityAfterArchive root stable operation = do
    let expected = authorityRemovalValue bootstrap operation
    released <- withBoundAuthorityRemoval bootstrap operation stable $ \custody held -> do
      confirmed <-
        confirmPublishedAuthorityArchive
          root
          held
          (bootstrapRootGeneration bootstrap)
          operation
          (archiveRecordName operation)
          expected
      if confirmed
        then retireArchivedAuthorityFence custody held operation expected
        else pure False
    pure (released == Just True)
  confirmFamilyRemoval operation stable = do
    early <- observeKindTeardownAdmissionUnderLease bootstrap operation stable
    authority <- if early then pure NoAuthorityRemoval else observeAuthorityRemoval bootstrap
    case (early, authority) of
      (True, _) ->
        confirmWith EarlyFamilyTeardown (observeKindTeardownAdmissionUnderLease bootstrap operation stable)
      (False, BoundAuthorityRemoval original) | original == operation ->
        confirmWith AuthorityFamilyTeardown $ do
          held <- stable
          fence <- observeAuthorityRemoval bootstrap
          closing <- stable
          pure (held && closing && fence == BoundAuthorityRemoval operation)
      _ -> pure Nothing
   where
    confirmWith basis held = do
      let namespace = "prodbox-netcheck-" ++ take 12 operation
      admitted <- held
      if not admitted
        then pure Nothing
        else do
          journal <- observeProbeJournal bootstrap operation namespace held
          launch <- observeProbeRecoveryLaunch bootstrap operation namespace held
          publication <- observeProbePublicationAttempt bootstrap operation namespace held
          confirmed <- case (journal, launch, publication) of
            (ProbeJournalRemovalRecorded _, ProbeRecoveryLaunchMissing, ProbePublicationMissing) ->
              qualifyFamilyRemoval operation held True (confirmFamilyNodeRemoval operation held)
            (ProbeJournalEmpty, ProbeRecoveryLaunchMissing, ProbePublicationMissing) ->
              confirmPreNodeFamilyRemoval operation held
            _ -> pure Nothing
          pure ((,basis) <$> confirmed)
  qualifyFamilyRemoval operation held credentialExpected nodeObservation = do
    independentProbes <- confirmIndependentProbeRemoval operation held
    node <- nodeObservation
    if not (independentProbes && node)
      then pure Nothing
      else do
        volume <- observeRecordedNodeVolumeAbsent bootstrap operation (\peer -> (&&) <$> held <*> peer)
        network <- observeRecordedNetworkAbsent bootstrap operation held
        closing <- held
        pure (if volume && network && closing then Just credentialExpected else Nothing)
  confirmPreNodeFamilyRemoval operation held = do
    node <- observeRecordedKindNodeCreateIntent bootstrap operation held
    case node of
      NodeCreateRecoveryRecorded _ ->
        qualifyFamilyRemoval operation held False (confirmUnattemptedFamilyNode operation held)
      _ -> do
        empty <- confirmUnattemptedFamilyNetwork operation held
        pure (if empty then Just False else Nothing)
  confirmUnattemptedFamilyNetwork operation held = do
    let preNetwork = do
          seen <- withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
            names <- listEntries root
            let launched name =
                  "kind-node-" `isPrefixOf` name
                    || ("kind-network-" `isPrefixOf` name && name /= "kind-network-intent.json")
            unchanged <- (&&) <$> sameRoot <*> held
            pure (unchanged && not (any launched names))
          pure (seen == Right True)
    before <- preNetwork
    proposal <- observeRecordedKindNetworkIntent bootstrap operation held
    case proposal of
      NetworkRecoveryRecorded intent | before -> do
        network <- observeUnattemptedNetworkAbsent bootstrap intent held
        dependants <- observeUnstartedNetworkDependants operation (kindNetworkDaemon intent) held
        closing <- preNetwork
        pure (network && dependants && closing)
      _ -> pure False
  observeUnstartedNetworkDependants operation expectedDaemon held = do
    observed <-
      withConnectedDockerInfo 15000000 (bootstrapRuntimeSocket bootstrap) $
        \session (DockerConnectedInfo daemon (DockerPeer _ _ _ identity)) peerStable -> do
          before <- held
          if before && DockerDaemonObserved daemon identity == expectedDaemon
            then do
              let scope = bootstrapScope bootstrap
              volume <- inspectDockerSessionNodeVarVolume session bootstrap operation
              byLabel <- readDockerSessionKindContainers session scope
              byName <- readDockerSessionKindNodeNameNotFound session scope
              peer <- peerStable
              closing <- held
              pure
                (volume == Right DockerNodeVarVolumeNotFound && byLabel == Right [] && byName && peer && closing)
            else pure False
    pure (observed == DockerPeerCompleted (DockerConnectedInfoCompleted True))
  confirmIndependentProbeRemoval operation held = do
    observed <- withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
      names <- listEntries root
      let namespaces = nub (mapMaybe scenarioProbeNamespace names)
      settled <-
        traverse (\namespace -> observeProbeJournal bootstrap operation namespace held) namespaces
      closing <- (&&) <$> sameRoot <*> held
      pure (all probeRemoved settled && closing)
    pure (observed == Right True)
  probeRemoved (ProbeJournalRemovalRecorded _) = True
  probeRemoved _ = False
  confirmFamilyNodeRemoval operation held = do
    proposal <- observeRecordedKindNodeCreateIntent bootstrap operation held
    case proposal of
      NodeCreateRecoveryRecorded intent -> do
        created <- observeKindNodeCreateResult bootstrap intent held
        case created of
          NodeCreateResultObserved (DockerNodeContainerCreateReply 201 (Just identifier)) ->
            observeRecordedNodeAbsent bootstrap intent identifier held
          _ -> pure False
      _ -> pure False
  confirmUnattemptedFamilyNode operation held = do
    proposal <- observeRecordedKindNodeCreateIntent bootstrap operation held
    case proposal of
      NodeCreateRecoveryRecorded intent -> do
        attempt <- observeKindNodeCreateAttempt bootstrap intent held
        records <- withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
          names <- listEntries root
          let onlyPrerequisites name =
                not ("kind-node-" `isPrefixOf` name)
                  || name == "kind-node-create-intent.json"
                  || "kind-node-var-volume-" `isPrefixOf` name
              noSecondaryProbe = not (any (isJust . scenarioProbeNamespace) names)
          current <- (&&) <$> sameRoot <*> held
          pure (noSecondaryProbe && current && all onlyPrerequisites names)
        if attempt == NodeCreateAttemptMissing && records == Right True
          then observeProposedNodeNameAbsent bootstrap intent held
          else pure False
      _ -> pure False
  inspectInventory operation stable = do
    labelled <-
      readDocker
        (bootstrapRuntimeSocket bootstrap)
        [ "ps"
        , "-a"
        , "--filter"
        , "label=io.x-k8s.kind.cluster=" ++ scopeKindName (bootstrapScope bootstrap)
        , "--format"
        , "{{.Names}}"
        ]
    named <-
      readDocker
        (bootstrapRuntimeSocket bootstrap)
        [ "ps"
        , "-a"
        , "--filter"
        , "name=^/" ++ scopeKindName (bootstrapScope bootstrap) ++ "-control-plane$"
        , "--format"
        , "{{.Names}}"
        ]
    case (labelled, named) of
      (Just byLabel, Just byName)
        | null (words byLabel) && null (words byName) -> do
            unchanged <- stable
            if unchanged
              then moveRecords operation stable
              else pure (ArchiveFailed "operation identity changed")
        | otherwise -> pure ArchiveContainerStillListed
      _ -> pure ArchiveInventoryUnobservable
  noOperationRecords = do
    leased <- withKindLease bootstrap $ \stable -> do
      observed <- withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
        result <- try (listEntries root) :: IO (Either IOException [String])
        intent <- observeKindIntent bootstrap
        let selected = (&&) <$> sameRoot <*> stable
        held <- selected
        case result of
          Right names
            | held && intent == KindIntentMissing && not (any (belongsToOperation "") names) -> do
                authority <- observeAuthorityRemoval bootstrap
                case authority of
                  NoAuthorityRemoval -> pure ArchiveNothingRecorded
                  BoundAuthorityRemoval operation -> do
                    released <- retireAuthorityAfterArchive root selected operation
                    pure $
                      if released
                        then ArchiveNothingRecorded
                        else ArchiveFailed ("the prior Authority fence is unconfirmed after archive of " ++ operation)
                  UnconfirmedAuthorityRemoval -> pure (ArchiveFailed "retained Authority removal is unobservable")
          _ -> pure (ArchiveFailed "operation records are present or unobservable without an intent")
      pure (either (const (ArchiveFailed "scope root unobservable")) id observed)
    pure $ case leased of
      Right (KindLeaseCompleted outcome) -> outcome
      _ -> ArchiveFailed "scope lease or identity is unconfirmed"
  moveRecords operation stable = do
    outcome <- timeout 20000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
      present <- forM removalResults $ \name -> probeArchiveRecord root name
      absent <- probeArchiveRecord root "kind-node-absence-observed.json"
      attempted <- probeArchiveRecord root "kind-node-create-attempt.json"
      volumePlanned <- probeArchiveRecord root "kind-node-var-volume-intent.json"
      credential <- existsNested root
      networkRefused <- networkNeverCreated operation stable
      nodeConfirmed <- confirmedNodeRemoval root operation stable
      volumeConfirmed <- confirmedVolumeRemoval root operation stable
      networkConfirmed <- confirmedNetworkRemoval operation stable
      scopeStable <- sameRoot
      operationStable <- stable
      case (sequence present, absent, attempted, volumePlanned, credential) of
        (Just receipts, Just absence, Just attempt, Just volume, Just credentialPresent)
          | scopeStable && operationStable && nodeConfirmed && volumeConfirmed && networkConfirmed ->
              moveObserved root operation receipts absence attempt volume credentialPresent networkRefused
          | scopeStable && operationStable ->
              pure (ArchiveNotCompletelyRemoved "bound removal receipts are missing, invalid or unconfirmed")
        _ -> pure (ArchiveFailed "operation records, credential or scope are unobservable")
    pure $ case outcome of
      Just (Right value) -> value
      _ ->
        ArchiveFailed
          ("operation " ++ operation ++ " archive unconfirmed; inspect retained root and history/" ++ operation)
  moveObserved root operation present absent attempted volumePlanned credential networkRefused = do
    -- An observed absence with its control (written by `control delete`), or
    -- a node whose create attempt was never recorded, stands in for the node
    -- removal result and nothing else.
    let missing =
          [ name
          | (name, False) <- zip removalResults present
          , not ((absent || not attempted) && name == "kind-node-remove-result.json")
          , not (not volumePlanned && name == "kind-node-var-volume-removal-result.json")
          , not (networkRefused && name == "kind-network-removal-result.json")
          ]
    if not (null missing)
      then pure (ArchiveNotCompletelyRemoved (unwords missing))
      else do
        names <- listEntries root
        let intentName = "kind-intent.json"
            moving = [name | name <- names, name /= intentName, belongsToOperation operation name]
        moveCheckedRecords root operation credential [intentName] moving
  moveOwnerOperationRecords root stable operation credential fenceName = do
    names <- listEntries root
    let intentName = "kind-intent.json"
        finalRecords = [intentName, fenceName]
        moving = [name | name <- names, name `notElem` finalRecords, belongsToOperation operation name]
    archiveReady <- and <$> traverse (ownerArchiveEntry root operation) moving
    if archiveReady
      then do
        moved <-
          timeout 20000000 $
            try
              ( publishKindArchive
                  root
                  stable
                  (bootstrapRootGeneration bootstrap)
                  operation
                  (moving ++ finalRecords)
                  credential
              )
        pure $ case moved of
          Just (Right published) -> ArchiveMoved operation published
          Just (Left (failure :: IOException)) -> ArchiveFailed ("operation " ++ operation ++ " archive transaction: " ++ show failure)
          Nothing -> ArchiveFailed ("operation " ++ operation ++ " archive transaction exceeded its deadline")
      else
        pure (ArchiveFailed "the retained owner-family inventory contains an unexpected or unsafe entry")
  moveCheckedRecords root operation credential finalRecords moving = do
    created <- try (makeDirectory root "history" >> makeDirectory' root "history" operation)
    case created of
      Left (failure :: IOException) -> pure (ArchiveFailed ("operation " ++ operation ++ " history directory: " ++ show failure))
      Right () -> do
        result <- try $ bracket (Posix.openFdAt (Just root) "history" Posix.ReadOnly directoryFlags) Posix.closeFd $ \history ->
          bracket (Posix.openFdAt (Just history) operation Posix.ReadOnly directoryFlags) Posix.closeFd $ \target -> do
            fileSynchronise history
            fileSynchronise root
            mapM_ (\name -> rename root name target name) moving
            credentialMoved <-
              if credential
                then bracket (Posix.openFdAt (Just root) "control" Posix.ReadOnly directoryFlags) Posix.closeFd $ \control -> do
                  rename control "kubeconfig" target "retired-kubeconfig"
                  fileSynchronise control
                  pure ["control/kubeconfig"]
                else pure []
            fileSynchronise target
            fileSynchronise root
            forM_ finalRecords $ \name -> do
              rename root name target name
              fileSynchronise target
              fileSynchronise root
            pure (moving ++ credentialMoved ++ finalRecords)
        pure $ case result of
          Left (failure :: IOException) ->
            ArchiveFailed
              ( "operation "
                  ++ operation
                  ++ " move unconfirmed; inspect history/"
                  ++ operation
                  ++ ": "
                  ++ show failure
              )
          Right moved -> ArchiveMoved operation moved
  ownerArchiveEntry root operation name
    | name == "kind-worker-" ++ operation = do
        inspected <-
          try $
            bracket
              (Posix.openFdAt (Just root) name Posix.ReadOnly directoryFlags)
              Posix.closeFd
              Files.getFdStatus
        owner <- getEffectiveUserID
        pure $ case inspected of
          Right status ->
            Files.isDirectory status && Files.fileOwner status == owner && Files.fileMode status .&. 0o022 == 0
          Left (_ :: IOException) -> False
    | name `elem` ownerArchiveRecords operation || isJust (scenarioProbeNamespace name) =
        (== Just True) <$> probeArchiveRecord root name
    | otherwise = pure False
  -- The network create result records a refused reply (a name collision) and
  -- no network id: there was no network to remove.
  networkNeverCreated operation stable = do
    proposal <- observeRecordedKindNetworkIntent bootstrap operation stable
    case proposal of
      NetworkRecoveryRecorded intent -> do
        receipt <- observeNetworkReceipt bootstrap intent NetworkCreateReceipt stable
        pure $ case receipt of
          NetworkReceiptObserved (NetworkCreateTransport (DockerNetworkCreateReply 409 Nothing)) -> True
          _ -> False
      _ -> pure False
  confirmedNodeRemoval root operation stable = do
    planned <- probeArchiveRecord root "kind-node-create-intent.json"
    attempted <- probeArchiveRecord root "kind-node-create-attempt.json"
    case (planned, attempted) of
      (Just False, Just False) -> pure True
      (Just True, _) -> do
        proposal <- observeRecordedKindNodeCreateIntent bootstrap operation stable
        case proposal of
          NodeCreateRecoveryRecorded intent -> do
            created <- observeKindNodeCreateResult bootstrap intent stable
            case created of
              NodeCreateResultMissing -> pure (attempted == Just False)
              NodeCreateResultObserved (DockerNodeContainerCreateReply 201 (Just identifier)) -> do
                removed <- observeKindNodeRemoveResult bootstrap intent identifier stable
                pure (removed == NodeRemoveResultObserved (DockerNodeContainerRemoveReply 204))
              _ -> pure False
          _ -> pure False
      _ -> pure False
  confirmedVolumeRemoval root operation stable = do
    planned <- probeArchiveRecord root "kind-node-var-volume-intent.json"
    attempted <- probeArchiveRecord root "kind-node-var-volume-attempt.json"
    case (planned, attempted) of
      (Just False, Just False) -> pure True
      (Just True, _) -> do
        daemon <- observeDockerDaemon (bootstrapRuntimeSocket bootstrap)
        case mkKindNodeVolumeIntent operation daemon of
          Nothing -> pure False
          Just intent -> do
            receipt <- observeKindNodeVolumeRemovalReceipt bootstrap intent stable
            pure (receipt == NodeVolumeRemovalReceiptObserved (DockerNodeVarRemoveReply 204))
      _ -> pure False
  confirmedNetworkRemoval operation stable = do
    proposal <- observeRecordedKindNetworkIntent bootstrap operation stable
    case proposal of
      NetworkRecoveryRecorded intent -> do
        created <- observeNetworkReceipt bootstrap intent NetworkCreateReceipt stable
        case created of
          NetworkReceiptObserved (NetworkCreateTransport (DockerNetworkCreateReply 409 Nothing)) -> pure True
          NetworkReceiptObserved (NetworkCreateTransport (DockerNetworkCreateReply 201 (Just identifier))) -> do
            removed <- observeNetworkReceipt bootstrap intent (NetworkRemovalReceipt identifier) stable
            pure (removed == NetworkReceiptObserved (NetworkRemovalTransport (DockerNetworkRemoveReply 204)))
          _ -> pure False
      _ -> pure False
  existsNested root = do
    opened <- try (Posix.openFdAt (Just root) "control" Posix.ReadOnly directoryFlags)
    case opened of
      Left (failure :: IOException)
        | isDoesNotExistError failure -> pure (Just False)
        | otherwise -> pure Nothing
      Right directory -> bracket (pure directory) Posix.closeFd $ \control -> do
        owner <- getEffectiveUserID
        status <- Files.getFdStatus control
        if Files.isDirectory status && Files.fileOwner status == owner && Files.fileMode status .&. 0o022 == 0
          then probeArchiveRecord control "kubeconfig"
          else pure Nothing
  listEntries root =
    bracket (openDirStream ("/proc/self/fd/" ++ show (fdNumber root))) closeDirStream $ \stream -> do
      let loop count accumulated = do
            entry <- readDirStream stream
            if null entry
              then pure accumulated
              else
                if entry `elem` [".", ".."]
                  then loop count accumulated
                  else
                    if count >= (4096 :: Int)
                      then ioError (userError "operation record inventory exceeds bound")
                      else loop (count + 1) (entry : accumulated)
      loop 0 []
  makeDirectory root name = do
    created <-
      try
        ( withCString name $ \encoded -> throwErrnoIfMinus1_ "create directory" (makeDirectoryAt (fdNumber root) encoded 0o700)
        )
    case created of
      Left (failure :: IOException) | isAlreadyExistsError failure -> pure ()
      Left failure -> ioError failure
      Right () -> pure ()
  makeDirectory' root parent name =
    bracket (Posix.openFdAt (Just root) parent Posix.ReadOnly directoryFlags) Posix.closeFd $ \parentFd -> do
      owner <- getEffectiveUserID
      status <- Files.getFdStatus parentFd
      if Files.fileOwner status /= owner || Files.fileMode status .&. 0o077 /= 0
        then ioError (userError "the history directory is not private to its owner")
        else do
          created <-
            try
              ( withCString name $ \encoded ->
                  throwErrnoIfMinus1_ "create operation history" (makeDirectoryAt (fdNumber parentFd) encoded 0o700)
              )
          case created of
            Left (failure :: IOException) | isAlreadyExistsError failure -> ioError (userError "history for this operation already exists")
            Left failure -> ioError failure
            Right () -> pure ()
  rename fromDirectory fromName toDirectory toName =
    withCString fromName $ \from -> withCString toName $ \to ->
      throwErrnoIfMinus1_
        "move record"
        (renameAt (fdNumber fromDirectory) from (fdNumber toDirectory) to noReplace)

ownerArchiveRecords :: String -> [FilePath]
ownerArchiveRecords operation =
  [ "kind-controller-worker-result.json"
  , "kind-family-dispatch-result.json"
  , "kind-family-launch-request.json"
  , "kind-family-publication-attempt.json"
  , "kind-network-attempt.json"
  , "kind-network-create-result.json"
  , "kind-network-intent.json"
  , "kind-network-removal-result.json"
  , "kind-network-removal.json"
  , "kind-node-config-attempt.json"
  , "kind-node-config-result.json"
  , "kind-node-create-attempt.json"
  , "kind-node-create-intent.json"
  , "kind-node-create-result.json"
  , "kind-node-remove-attempt.json"
  , "kind-node-remove-positive-control.json"
  , "kind-node-remove-result.json"
  , "kind-node-remove-retry-attempt.json"
  , "kind-node-remove-retry-result.json"
  , "kind-node-start-attempt.json"
  , "kind-node-start-result.json"
  , "kind-node-var-volume-attempt.json"
  , "kind-node-var-volume-create-result.json"
  , "kind-node-var-volume-intent.json"
  , "kind-node-var-volume-removal-result.json"
  , "kind-node-var-volume-removal.json"
  , "node-image-attempt.json"
  , "node-image-intent.json"
  , "node-image-result.json"
  ]
    ++ [ "kind-node-bootstrap-" ++ stage ++ "-" ++ record ++ ".json"
       | stage <- ["cni", "init", "label", "storage", "taint"]
       , record <- ["attempt", "result"]
       ]
    ++ [ "kind-network-probe-prodbox-netcheck-" ++ take 12 operation ++ "-" ++ record ++ ".json"
       | record <- ["created", "intent", "removed"]
       ]
    ++ serviceOperationRecordNames operation

archiveRecordName :: String -> FilePath -> Bool
archiveRecordName operation name =
  name `elem` ["kind-intent.json", "kind-teardown-admission.json", authorityArchiveRecordName]
    || name `elem` ownerArchiveRecords operation
    || isJust (scenarioProbeNamespace name)

-- The public acceptance runner repeats the policy check under the same
-- operation in a separate namespace. The observer above still requires the
-- exact operation's matching removal journal before this record can move.
scenarioProbeNamespace :: FilePath -> Maybe String
scenarioProbeNamespace name = do
  remainder <- stripPrefix "kind-network-probe-prodbox-netrun-" name
  let (token, suffix) = splitAt 8 remainder
  if length token == 8
    && all (`elem` ("0123456789abcdef" :: String)) token
    && suffix `elem` ["-created.json", "-intent.json", "-removed.json"]
    then Just ("prodbox-netrun-" ++ token)
    else Nothing
