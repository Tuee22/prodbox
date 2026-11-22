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
  , archiveCompletedOperation
  ) where

import Control.Exception (IOException, bracket, try)
import Control.Monad (forM)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.List (isPrefixOf)
import Data.Text qualified as Text
import Foreign.C.Error (throwErrnoIfMinus1_)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapRuntimeSocket
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope (scopeKindName, withScopeRootDescriptor)
import Prodbox.Control.DockerIdentity (readDocker)
import Prodbox.Control.KindIntent (KindIntentObservation (..), observeKindIntent)
import System.IO.Error (isAlreadyExistsError)
import System.Posix.Directory (closeDirStream, openDirStream, readDirStream)
import System.Posix.Files qualified as Files
import System.Posix.IO qualified as Posix
import System.Posix.Types (CMode (..), Fd (..))
import System.Timeout (timeout)

data ArchiveOutcome
  = ArchiveNothingRecorded
  | ArchiveNotCompletelyRemoved !String
  | ArchiveContainerStillListed
  | ArchiveInventoryUnobservable
  | ArchiveMoved !String ![String]
  | ArchiveFailed !String
  deriving (Eq, Show)

foreign import capi "stdio.h renameat" renameAt :: CInt -> CString -> CInt -> CString -> IO CInt
foreign import capi "sys/stat.h mkdirat" makeDirectoryAt :: CInt -> CString -> CMode -> IO CInt

directoryFlags :: Posix.OpenFileFlags
directoryFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.directory = True}

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
  case recorded of
    KindIntentMatches operation -> do
      listing <-
        readDocker
          (bootstrapRuntimeSocket bootstrap)
          [ "ps"
          , "-a"
          , "--filter"
          , "label=io.x-k8s.kind.cluster=" ++ scopeKindName (bootstrapScope bootstrap)
          , "--format"
          , "{{.Names}}"
          ]
      case listing of
        Nothing -> pure ArchiveInventoryUnobservable
        Just output
          | not (null (words output)) -> pure ArchiveContainerStillListed
          | otherwise -> moveRecords operation
    _ -> pure ArchiveNothingRecorded
 where
  moveRecords operation = do
    outcome <- timeout 20000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root _ -> do
      present <- forM removalResults $ \name -> exists root name
      absent <- exists root "kind-node-absence-observed.json"
      attempted <- exists root "kind-node-create-attempt.json"
      volumePlanned <- exists root "kind-node-var-volume-intent.json"
      networkRefused <- networkNeverCreated root
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
            Left (failure :: IOException) -> pure (ArchiveFailed ("history directory: " ++ show failure))
            Right () -> do
              result <- try $ bracket (Posix.openFdAt (Just root) "history" Posix.ReadOnly directoryFlags) Posix.closeFd $ \history ->
                bracket (Posix.openFdAt (Just history) operation Posix.ReadOnly directoryFlags) Posix.closeFd $ \target -> do
                  mapM_ (\name -> rename root name target name) moving
                  credential <- exists root "control/kubeconfig"
                  credentialMoved <-
                    if credential
                      then bracket (Posix.openFdAt (Just root) "control" Posix.ReadOnly directoryFlags) Posix.closeFd $ \control -> do
                        rename control "kubeconfig" target "retired-kubeconfig"
                        pure ["control/kubeconfig"]
                      else pure []
                  pure (moving ++ credentialMoved)
              pure $ case result of
                Left (failure :: IOException) -> ArchiveFailed ("move: " ++ show failure)
                Right moved -> ArchiveMoved operation moved
    pure $ case outcome of
      Just (Right value) -> value
      _ -> ArchiveFailed "root unobservable or timed out"
  exists root name
    | '/' `elem` name = existsNested root name
    | otherwise = do
        status <-
          try (Files.getSymbolicLinkStatus ("/proc/self/fd/" ++ show (fdNumber root) ++ "/" ++ name))
        pure (either (\(_ :: IOException) -> False) (const True) status)
  -- The network create result records a refused reply (a name collision) and
  -- no network id: there was no network to remove.
  networkNeverCreated root = do
    contents <-
      try
        (ByteString.readFile ("/proc/self/fd/" ++ show (fdNumber root) ++ "/kind-network-create-result.json"))
    pure $ case contents of
      Left (_ :: IOException) -> False
      Right bytes -> case Aeson.decodeStrict bytes of
        Just (Aeson.Object record) -> case KeyMap.lookup (Key.fromString "transport") record of
          Just (Aeson.Object transport) ->
            KeyMap.lookup (Key.fromString "network_id") transport == Just Aeson.Null
              && KeyMap.lookup (Key.fromString "status") transport /= Just (Aeson.Number 201)
              && KeyMap.lookup (Key.fromString "state") transport == Just (Aeson.String (Text.pack "reply"))
          _ -> False
        _ -> False
  existsNested root name = do
    status <-
      try (Files.getSymbolicLinkStatus ("/proc/self/fd/" ++ show (fdNumber root) ++ "/" ++ name))
    pure (either (\(_ :: IOException) -> False) (const True) status)
  listEntries root = do
    stream <- openDirStream ("/proc/self/fd/" ++ show (fdNumber root))
    let loop accumulated = do
          entry <- readDirStream stream
          if null entry
            then pure accumulated
            else loop (if entry `elem` [".", ".."] then accumulated else entry : accumulated)
    entries <- loop []
    closeDirStream stream
    pure entries
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
