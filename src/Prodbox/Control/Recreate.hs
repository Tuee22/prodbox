{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Prepare a retained root for a new operation after a previous one was
-- completely removed. Nothing is deleted: the previous operation's records,
-- its worker directory and its cluster credential are moved with renameat
-- into @history/<operation>/@, so the new operation can create its own
-- exclusive records while the old ones stay as evidence. The host data, the
-- generation record and the retained artifacts are not touched. The move is
-- refused unless removal results were recorded for the node, the volume and the
-- network, and an independent Docker listing shows no container of the
-- selected cluster; a half-removed operation keeps its records for recovery.
module Prodbox.Control.Recreate
  ( ArchiveOutcome (..)
  , ArchiveIntentDecision (..)
  , classifyArchiveIntent
  , probeArchiveRecord
  , archiveCompletedOperation
  ) where

import Control.Exception (IOException, bracket, try)
import Control.Monad (forM)
import Data.Bits ((.&.))
import Data.List (isPrefixOf)
import Foreign.C.Error (throwErrnoIfMinus1_)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapRuntimeSocket
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope (scopeKindName, withScopeRootDescriptor)
import Prodbox.Control.DockerConnectedInfo
  ( DockerNetworkCreateResult (DockerNetworkCreateReply)
  , DockerNetworkRemoveResult (DockerNetworkRemoveReply)
  , DockerNodeContainerCreateResult (DockerNodeContainerCreateReply)
  , DockerNodeContainerRemoveResult (DockerNodeContainerRemoveReply)
  , DockerNodeVarRemoveResult (DockerNodeVarRemoveReply)
  )
import Prodbox.Control.DockerIdentity (observeDockerDaemon, readDocker)
import Prodbox.Control.KindControllerReceipt (withControllerRecoverySettlement)
import Prodbox.Control.KindIntent (KindIntentObservation (..), observeKindIntent)
import Prodbox.Control.KindLease
  ( KindLeaseOutcome (KindLeaseCompleted)
  , KindOperationOutcome (KindOperationCallbackReturned)
  , withKindLease
  , withRecoveredKindOperation
  )
import Prodbox.Control.KindNetworkIntent
  ( KindNetworkRecoveryObservation (NetworkRecoveryRecorded)
  , observeRecordedKindNetworkIntent
  )
import Prodbox.Control.KindNetworkReceipt
  ( NetworkReceiptKind (..)
  , NetworkReceiptObservation (NetworkReceiptObserved)
  , NetworkTransport (..)
  , observeNetworkReceipt
  )
import Prodbox.Control.KindNodeCreateIntent
  ( KindNodeCreateRecoveryObservation (NodeCreateRecoveryRecorded)
  , KindNodeCreateResultObservation (..)
  , KindNodeRemoveResultObservation (NodeRemoveResultObserved)
  , observeKindNodeCreateResult
  , observeKindNodeRemoveResult
  , observeRecordedKindNodeCreateIntent
  )
import Prodbox.Control.KindNodeVolumeIntent
  ( KindNodeVolumeRemovalReceiptObservation (NodeVolumeRemovalReceiptObserved)
  , mkKindNodeVolumeIntent
  , observeKindNodeVolumeRemovalReceipt
  )
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)
import System.Posix.Directory (closeDirStream, openDirStream, readDirStream)
import System.Posix.Files qualified as Files
import System.Posix.IO qualified as Posix
import System.Posix.Types (CMode (..), Fd (..))
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

foreign import capi "stdio.h renameat" renameAt :: CInt -> CString -> CInt -> CString -> IO CInt
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

archiveCompletedOperation :: BootstrapProjection -> IO ArchiveOutcome
archiveCompletedOperation bootstrap = do
  recorded <- observeKindIntent bootstrap
  case classifyArchiveIntent recorded of
    ArchiveKnownIntent operation -> do
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
    ArchiveNoIntent -> noOperationRecords
    ArchiveIntentUnconfirmed -> pure (ArchiveFailed "operation intent is conflicting, unavailable or unsupported")
 where
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
        scopeStable <- sameRoot
        leaseStable <- stable
        pure $ case result of
          Right names
            | scopeStable && leaseStable && intent == KindIntentMissing && not (any (belongsToOperation "") names) ->
                ArchiveNothingRecorded
          _ -> ArchiveFailed "operation records are present or unobservable without an intent"
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
        let moving = [name | name <- names, belongsToOperation operation name]
        created <- try (makeDirectory root "history" >> makeDirectory' root "history" operation)
        case created of
          Left (failure :: IOException) -> pure (ArchiveFailed ("operation " ++ operation ++ " history directory: " ++ show failure))
          Right () -> do
            result <- try $ bracket (Posix.openFdAt (Just root) "history" Posix.ReadOnly directoryFlags) Posix.closeFd $ \history ->
              bracket (Posix.openFdAt (Just history) operation Posix.ReadOnly directoryFlags) Posix.closeFd $ \target -> do
                mapM_ (\name -> rename root name target name) moving
                credentialMoved <-
                  if credential
                    then bracket (Posix.openFdAt (Just root) "control" Posix.ReadOnly directoryFlags) Posix.closeFd $ \control -> do
                      rename control "kubeconfig" target "retired-kubeconfig"
                      pure ["control/kubeconfig"]
                    else pure []
                pure (moving ++ credentialMoved)
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
      throwErrnoIfMinus1_ "move record" (renameAt (fdNumber fromDirectory) from (fdNumber toDirectory) to)
