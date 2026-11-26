{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The local storage transaction holds the existing kind scope lease.
-- Original directories stay under the same root throughout an interrupted swap.
module Prodbox.Control.ManagementRestore
  ( ManagementRestoreState (..)
  , ManagementRestore
  , ManagementRestoreOperation (..)
  , CompletedRestoreObservation (..)
  , managementDirectories
  , validBackupName
  , managementRestoreIdle
  , observeManagementRestore
  , observeManagementRestoreOperation
  , observeCompletedManagementRestore
  , reserveManagementRestore
  , resumeManagementSwap
  , markManagementInstalled
  , finishManagementRestore
  ) where

import Control.Exception (IOException, bracket, try)
import Control.Monad (unless)
import Data.Aeson (FromJSON, ToJSON)
import Data.Aeson qualified as Aeson
import Data.Bits ((.&.))
import Data.ByteString.Char8 qualified as ByteString
import Data.Char (isAsciiLower, isDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import Foreign.C.Error (throwErrnoIfMinus1_)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..), CUInt (..))
import GHC.Generics (Generic)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapRootGeneration
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope (scopeKindName, validRootGeneration, withScopeRootDescriptor)
import Prodbox.Control.KindNodeBootstrap
  ( JournalRecordObservation (..)
  , observeJournalRecord
  , writeJournalRecord
  )
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files qualified as Files
import System.Posix.IO qualified as Posix
import System.Posix.Types (Fd (..))
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)

data DirectoryIdentity = DirectoryIdentity !Integer !Integer
  deriving (Eq, Generic, FromJSON, ToJSON)

data StorageSwap = StorageSwap
  { originalStorage :: !DirectoryIdentity
  , stagedStorage :: !DirectoryIdentity
  }
  deriving (Eq, Generic, FromJSON, ToJSON)

data ManagementRestore = ManagementRestore
  { restoreSchemaVersion :: !Int
  , restoreScope :: !String
  , restoreGeneration :: !Text
  , restoreBackup :: !String
  , restoreCommitment :: !Text
  , restoreStage :: !FilePath
  , restoreStageIdentity :: !DirectoryIdentity
  , restoreVault :: !StorageSwap
  , restoreMinio :: !StorageSwap
  }
  deriving (Eq, Generic, FromJSON, ToJSON)

data ManagementRestoreState
  = ManagementRestoreFresh
  | ManagementRestorePrepared !ManagementRestore
  | ManagementRestoreInstalled !ManagementRestore
  | ManagementRestoreSettled
  | ManagementRestoreUnconfirmed

data ManagementRestoreOperation
  = NoManagementRestoreOperation
  | PendingManagementRestore !String !String
  | UnconfirmedManagementRestoreOperation

data CompletedRestoreObservation
  = NoCompletedRestore
  | CompletedRestore !String
  | UnconfirmedCompletedRestore

managementDirectories :: [FilePath]
managementDirectories = ["vault-data", "minio-data"]

activeRecord :: FilePath
activeRecord = "management-restore-intent.json"

installedRecord :: String -> FilePath
installedRecord name = "management-restore-" ++ name ++ "-installed.json"

completedRecord :: String -> FilePath
completedRecord name = "management-restore-" ++ name ++ "-complete.json"

operationReceipt :: String -> FilePath
operationReceipt operation = "management-restore-operation-" ++ operation ++ ".json"

validStage :: FilePath -> Bool
validStage path = case splitAt 15 path of
  ("restore-staged-", suffix) ->
    length suffix == 24 && all (\c -> isDigit c || c >= 'a' && c <= 'f') suffix
  _ -> False

validBackupName :: String -> Bool
validBackupName name =
  not (null name) && length name <= 40 && all (\c -> isAsciiLower c || isDigit c || c == '-') name

matches :: BootstrapProjection -> String -> Text -> ManagementRestore -> Bool
matches bootstrap name commitment record =
  restoreSchemaVersion record == 1
    && restoreScope record == scopeKindName (bootstrapScope bootstrap)
    && restoreGeneration record == bootstrapRootGeneration bootstrap
    && restoreBackup record == name
    && restoreCommitment record == commitment
    && validBackupName name
    && validStage (restoreStage record)

managementRestoreIdle :: BootstrapProjection -> IO Bool
managementRestoreIdle bootstrap = (== JournalRecordMissing) <$> observeJournalRecord bootstrap activeRecord

-- | A secret-free operation identity derived from the exact retained staging
-- transaction and scope. Show and resume never publish the backup commitment.
observeManagementRestoreOperation :: BootstrapProjection -> IO ManagementRestoreOperation
observeManagementRestoreOperation bootstrap = do
  active <- observeJournalRecord bootstrap activeRecord
  pure $ case active of
    JournalRecordMissing -> NoManagementRestoreOperation
    JournalRecordObserved value
      | Aeson.Success record <- Aeson.fromJSON value
      , let name = restoreBackup record
      , matches bootstrap name (restoreCommitment record) record ->
          PendingManagementRestore (restoreOperationId record) name
    _ -> UnconfirmedManagementRestoreOperation

restoreOperationId :: ManagementRestore -> String
restoreOperationId record =
  take 32 $
    ByteString.unpack $
      hexSha256 $
        ByteString.pack
          (restoreScope record ++ ":" ++ Text.unpack (restoreGeneration record) ++ ":" ++ restoreStage record)

-- The operation lookup is published before the active intent is renamed.
-- It can replay completion only after both bound terminal records agree.
observeCompletedManagementRestore :: BootstrapProjection -> String -> IO CompletedRestoreObservation
observeCompletedManagementRestore bootstrap operation
  | not (validRootGeneration operation) = pure UnconfirmedCompletedRestore
  | otherwise = do
      indexed <- observeJournalRecord bootstrap (operationReceipt operation)
      case indexed of
        JournalRecordMissing -> pure NoCompletedRestore
        JournalRecordObserved value
          | Aeson.Success record <- Aeson.fromJSON value
          , let backup = restoreBackup record
          , matches bootstrap backup (restoreCommitment record) record
          , restoreOperationId record == operation -> do
              installed <- observeJournalRecord bootstrap (installedRecord backup)
              completed <- observeJournalRecord bootstrap (completedRecord backup)
              let exact = JournalRecordObserved value
              pure $
                if installed == exact && completed == exact
                  then CompletedRestore backup
                  else UnconfirmedCompletedRestore
        _ -> pure UnconfirmedCompletedRestore

observeManagementRestore :: BootstrapProjection -> String -> Text -> IO ManagementRestoreState
observeManagementRestore bootstrap name commitment = do
  active <- observeJournalRecord bootstrap activeRecord
  installed <- observeJournalRecord bootstrap (installedRecord name)
  completed <- observeJournalRecord bootstrap (completedRecord name)
  pure $ case (active, installed, completed) of
    (JournalRecordMissing, JournalRecordMissing, JournalRecordMissing) -> ManagementRestoreFresh
    (JournalRecordObserved value, receipt, JournalRecordMissing)
      | Aeson.Success record <- Aeson.fromJSON value
      , matches bootstrap name commitment record -> case receipt of
          JournalRecordMissing -> ManagementRestorePrepared record
          JournalRecordObserved accepted
            | value == accepted -> ManagementRestoreInstalled record
          _ -> ManagementRestoreUnconfirmed
    (JournalRecordMissing, JournalRecordObserved accepted, JournalRecordObserved archived)
      | archived == accepted
      , Aeson.Success record <- Aeson.fromJSON archived
      , matches bootstrap name commitment record ->
          ManagementRestoreSettled
    _ -> ManagementRestoreUnconfirmed

reserveManagementRestore
  :: BootstrapProjection -> String -> Text -> FilePath -> IO Bool -> IO ManagementRestoreState
reserveManagementRestore bootstrap name commitment stage stable
  | not (validBackupName name && validStage stage) = pure ManagementRestoreUnconfirmed
  | otherwise = do
      prepared <- withRestoreRoot bootstrap stable $ \root check ->
        withDirectory root stage $ \staging -> do
          vault <- storagePair root staging "vault-data"
          minio <- storagePair root staging "minio-data"
          stagingIdentity <- directoryIdentity staging
          ensure check
          writeJournalRecord bootstrap activeRecord $
            Aeson.toJSON
              ManagementRestore
                { restoreSchemaVersion = 1
                , restoreScope = scopeKindName (bootstrapScope bootstrap)
                , restoreGeneration = bootstrapRootGeneration bootstrap
                , restoreBackup = name
                , restoreCommitment = commitment
                , restoreStage = stage
                , restoreStageIdentity = stagingIdentity
                , restoreVault = vault
                , restoreMinio = minio
                }
      if prepared == Just True
        then observeManagementRestore bootstrap name commitment
        else pure ManagementRestoreUnconfirmed
 where
  storagePair root stageDirectory name' = do
    assert (previousName name name') root Nothing
    original <- withDirectory root name' directoryIdentity
    staged <- withDirectory stageDirectory name' directoryIdentity
    unless (original /= staged) (ioError (userError "restore directory identity is ambiguous"))
    pure (StorageSwap original staged)

previousName :: String -> FilePath -> FilePath
previousName name member = "replaced-" ++ name ++ "-" ++ member

swaps :: ManagementRestore -> [(FilePath, StorageSwap)]
swaps record = [("vault-data", restoreVault record), ("minio-data", restoreMinio record)]

-- | The checked states are the only ones a process can leave by interruption.
-- If any name refers to an unexpected inode it is preserved for recovery.
resumeManagementSwap :: BootstrapProjection -> IO Bool -> ManagementRestore -> IO Bool
resumeManagementSwap bootstrap stable record = do
  outcome <- withRestoreRoot bootstrap stable $ \root check ->
    withDirectory root (restoreStage record) $ \stage -> do
      identity <- directoryIdentity stage
      unless
        (identity == restoreStageIdentity record)
        (ioError (userError "restore staging directory was replaced"))
      mapM_ (resumeOne check root stage) (swaps record)
      ensure check
  pure (outcome == Just ())
 where
  resumeOne check root stage (name, swap) = do
    let previous = previousName (restoreBackup record) name
        original = Just (originalStorage swap)
        staged = Just (stagedStorage swap)
    current <- observeDirectory root name
    saved <- observeDirectory root previous
    candidate <- observeDirectory stage name
    case (current, saved, candidate) of
      (Nothing, found, copied) | found == original && copied == staged -> pure ()
      (found, Nothing, copied) | found == original && copied == staged -> do
        ensure check
        move root name root previous
      (found, old, Nothing) | found == staged && old == original -> pure ()
      _ -> ioError (userError "restore storage placement is unconfirmed")
    now <- observeDirectory root name
    case now of
      Nothing -> do
        assert previous root original
        assert name stage staged
        ensure check
        move stage name root name
      Just _ -> pure ()
    assert name root staged
    assert previous root original
    assert name stage Nothing

markManagementInstalled :: BootstrapProjection -> ManagementRestore -> IO Bool
markManagementInstalled bootstrap record = do
  let name = installedRecord (restoreBackup record)
      value = Aeson.toJSON record
  _ <- writeJournalRecord bootstrap name value
  (== JournalRecordObserved value) <$> observeJournalRecord bootstrap name

-- | Once Kubernetes has been restarted, its service data may change. The
-- installed receipt freezes the verified swap and replay checks its identities.
finishManagementRestore :: BootstrapProjection -> IO Bool -> ManagementRestore -> IO Bool -> IO Bool
finishManagementRestore bootstrap stable record restart = do
  outcome <- withRestoreRoot bootstrap stable $ \root check -> do
    mapM_ (verifyInstalled root) (swaps record)
    ensure check
    ready <- restart
    unless ready (ioError (userError "management services did not restart"))
    mapM_ (verifyInstalled root) (swaps record)
    remaining <- observeDirectory root (restoreStage record)
    case remaining of
      Nothing -> pure ()
      Just identity
        | identity == restoreStageIdentity record -> do
            ensure check
            removeEmpty root (restoreStage record)
      _ -> ioError (userError "restore staging directory was replaced")
    checkpoint <- observeJournalRecord bootstrap activeRecord
    let value = Aeson.toJSON record
        index = operationReceipt (restoreOperationId record)
        finished = completedRecord (restoreBackup record)
    unless (checkpoint == JournalRecordObserved value) $
      ioError (userError "active restore record changed")
    ensure check
    _ <- writeJournalRecord bootstrap index value
    indexed <- observeJournalRecord bootstrap index
    unless (indexed == JournalRecordObserved value) $
      ioError (userError "restore operation receipt could not be bound")
    ensure check
    move root activeRecord root finished
    terminal <- observeJournalRecord bootstrap finished
    unless (terminal == JournalRecordObserved value) $
      ioError (userError "terminal restore receipt could not be confirmed")
    ensure check
  pure (outcome == Just ())
 where
  verifyInstalled root (name, swap) = do
    assert name root (Just (stagedStorage swap))
    assert (previousName (restoreBackup record) name) root (Just (originalStorage swap))

withRestoreRoot
  :: BootstrapProjection -> IO Bool -> (Fd -> IO Bool -> IO a) -> IO (Maybe a)
withRestoreRoot bootstrap stable action = do
  result <- try $
    withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
      let check = (&&) <$> sameRoot <*> stable
      ensure check
      action root check
  pure $ case result of
    Right (Right value) -> Just value
    Right (Left _) -> Nothing
    Left (_ :: IOException) -> Nothing

ensure :: IO Bool -> IO ()
ensure check = check >>= \held -> unless held (ioError (userError "the restore scope lease changed"))

directoryFlags :: Posix.OpenFileFlags
directoryFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.directory = True, Posix.cloexec = True}

withDirectory :: Fd -> FilePath -> (Fd -> IO a) -> IO a
withDirectory root name =
  bracket (Posix.openFdAt (Just root) name Posix.ReadOnly directoryFlags) Posix.closeFd

directoryIdentity :: Fd -> IO DirectoryIdentity
directoryIdentity descriptor = do
  status <- Files.getFdStatus descriptor
  owner <- getEffectiveUserID
  unless (Files.fileOwner status == owner && Files.fileMode status .&. 0o077 == 0) $
    ioError (userError "restore directory ownership or permissions changed")
  pure (DirectoryIdentity (toInteger (Files.deviceID status)) (toInteger (Files.fileID status)))

observeDirectory :: Fd -> FilePath -> IO (Maybe DirectoryIdentity)
observeDirectory root name = do
  opened <- try (Posix.openFdAt (Just root) name Posix.ReadOnly directoryFlags)
  case opened of
    Left failure
      | isDoesNotExistError failure -> pure Nothing
      | otherwise -> ioError failure
    Right descriptor -> bracket (pure descriptor) Posix.closeFd (fmap Just . directoryIdentity)

assert :: FilePath -> Fd -> Maybe DirectoryIdentity -> IO ()
assert name parent expected = do
  observed <- observeDirectory parent name
  unless (observed == expected) (ioError (userError "restore directory identity is unconfirmed"))

foreign import capi "stdio.h renameat2"
  renameAt :: CInt -> CString -> CInt -> CString -> CUInt -> IO CInt
foreign import capi "stdio.h value RENAME_NOREPLACE" noReplace :: CUInt
foreign import capi "unistd.h unlinkat" unlinkAt :: CInt -> CString -> CInt -> IO CInt
foreign import capi "fcntl.h value AT_REMOVEDIR" removeDirectoryFlag :: CInt

move :: Fd -> FilePath -> Fd -> FilePath -> IO ()
move from@(Fd source) old to@(Fd destination) new = do
  withCString old $ \sourceName ->
    withCString new $ \destinationName ->
      throwErrnoIfMinus1_ "rename retained restore entry" $
        renameAt source sourceName destination destinationName noReplace
  fileSynchronise to
  unless (from == to) (fileSynchronise from)

removeEmpty :: Fd -> FilePath -> IO ()
removeEmpty root@(Fd descriptor) name = do
  withCString name $ \entry ->
    throwErrnoIfMinus1_ "remove empty restore staging directory" $
      unlinkAt descriptor entry removeDirectoryFlag
  fileSynchronise root
