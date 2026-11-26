{-# LANGUAGE OverloadedStrings #-}

-- | Local backup and restore of the bootstrap services' retained data (Vault's
-- file storage and MinIO's data directory) for one test environment. A backup
-- stops the Vault and MinIO Pods so the copy is consistent, copies both data
-- directories with their ownership and times into
-- @<root>/backups/<name>/@, records a manifest naming the scope, the root
-- generation and private keyed commitments over the copied trees, and starts the
-- Pods again. A restore verifies the manifest against this scope and generation
-- and against the copied files, stops the Pods, moves the current data aside
-- (nothing is deleted), copies the backup into place and starts the Pods; the
-- Vault then comes up sealed and is unsealed as usual. A backup holds sealed
-- Vault data and the MinIO objects, including the test unlock object: it is
-- as sensitive as the retained root and stays inside it with the same private
-- permissions.
module Prodbox.Control.Backup
  ( BackupStep (..)
  , backupServices
  , restoreServices
  , renderBackupOutcome
  , protectedRestoreHistoryMatches
  , treeDigest
  ) where

import Control.Exception (IOException, bracket, try)
import Crypto.Hash (SHA256)
import Crypto.MAC.HMAC qualified as HMAC
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (sort)
import Data.Text qualified as Text
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapRootGeneration
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope (scopeKindName, scopeRoot)
import Prodbox.Control.AuthorityDeploy
  ( RetainedAuthorityJournal (..)
  , observeRetainedAuthorityJournal
  , retainedAuthorityCustody
  )
import Prodbox.Control.BrokerDeploy (localBrokerStoreBucket)
import Prodbox.Control.KindIntent
  ( KindIntentObservation (KindIntentMissing)
  , observeKindTeardownAdmission
  )
import Prodbox.Control.KindKubeconfigFile (withKindKubeconfigSnapshot)
import Prodbox.Control.KindLease (KindLeaseOutcome (KindLeaseCompleted), withKindLease)
import Prodbox.Control.ManagementRestore
  ( ManagementRestoreState (..)
  , finishManagementRestore
  , managementDirectories
  , managementRestoreIdle
  , markManagementInstalled
  , observeManagementRestore
  , reserveManagementRestore
  , resumeManagementSwap
  , validBackupName
  )
import Prodbox.Control.Services (ServiceStep (..), startServicePods, stopServicePods)
import Prodbox.ControlPlane.AdmissionJournalMirror
  ( JournalRemovalFence (JournalRemovalFenceAbsent)
  , observeJournalRemovalFence
  , observeRetainedJournalMirror
  , withJournalCustodyLease
  )
import Prodbox.Lifecycle.AdmissionHistory
  ( JournalObservation (JournalRead)
  , OperationState (OperationUnresolved)
  )
import Prodbox.Minio.ObjectStoreTypes (defaultObjectStoreBucket)
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessWithInputBounded
  )
import System.Directory
  ( createDirectory
  , createDirectoryIfMissing
  , doesDirectoryExist
  , listDirectory
  )
import System.Exit (ExitCode (..))
import System.FilePath (splitDirectories, takeFileName, (</>))
import System.IO (IOMode (ReadMode), hClose, withBinaryFile)
import System.Posix.Files
  ( FileStatus
  , fileSize
  , getSymbolicLinkStatus
  , isDirectory
  , isRegularFile
  , isSymbolicLink
  , readSymbolicLink
  , setFileMode
  )
import System.Posix.IO
  ( OpenFileFlags (..)
  , OpenMode (WriteOnly)
  , defaultFileFlags
  , fdToHandle
  , openFd
  )

data BackupStep = BackupStep
  { backupStepName :: !String
  , backupStepOk :: !Bool
  , backupStepDetail :: !String
  }
  deriving (Eq, Show)

renderBackupOutcome :: [BackupStep] -> (Bool, String)
renderBackupOutcome steps =
  ( not (null steps) && all backupStepOk steps
  , unlines
      [ "  "
          ++ backupStepName step
          ++ ": "
          ++ (if backupStepOk step then "ok" else "NOT completed")
          ++ " - "
          ++ backupStepDetail step
      | step <- steps
      ]
  )

fromService :: ServiceStep -> BackupStep
fromService step = BackupStep (serviceStepName step) (serviceStepOk step) (serviceStepDetail step)

run :: FilePath -> [String] -> IO (Either String (Int, String))
run program arguments = do
  result <-
    captureSubprocessWithInputBounded
      (BoundedSubprocessLimits 1 (8 * 1024 * 1024) (256 * 1024) 600000000)
      ByteString.empty
      (Subprocess program arguments (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")]) Nothing)
  pure $ case result of
    Right output ->
      Right
        (case processExitCode output of ExitSuccess -> 0; ExitFailure code -> code, processStdout output)
    Left failure -> Left (show failure)

copySucceeded :: Either String (Int, String) -> Bool
copySucceeded result = case result of
  Right (0, _) -> True
  _ -> False

-- | A private keyed commitment over names, entry types and file contents. The
-- key and commitment remain in the protected backup; neither is evidence or
-- an unkeyed hash of secret material. Refuse unknown filesystem entries.
treeDigest :: ByteString.ByteString -> FilePath -> IO (Either String String)
treeDigest key directory = do
  result <-
    try (walk "" (HMAC.initialize key :: HMAC.Context SHA256))
      :: IO (Either IOException (HMAC.Context SHA256))
  pure $ case result of
    Left _ -> Left "backup tree could not be read"
    Right context -> Right (ByteString8.unpack (convertToBase Base16 (HMAC.finalize context :: HMAC.HMAC SHA256)))
 where
  frame fields = LazyByteString.toStrict (Aeson.encode fields) <> "\n"
  walk relative context = do
    let path = if null relative then directory else directory </> relative
    status <- getSymbolicLinkStatus path
    if isDirectory status
      then do
        names <- sort <$> listDirectory path
        let next = HMAC.update context (frame (["directory", relative] :: [String]))
        foldlM (\state name -> walk (if null relative then name else relative </> name) state) next names
      else
        if isRegularFile status
          then withBinaryFile path ReadMode $ \handle -> do
            let next = HMAC.update context (frame (["file", relative, show (fileSize status)] :: [String]))
                consume state = do
                  chunk <- ByteString.hGetSome handle 65536
                  if ByteString.null chunk
                    then pure state
                    else let nextState = HMAC.update state chunk in nextState `seq` consume nextState
            consume next
          else
            if isSymbolicLink status
              then do
                destination <- readSymbolicLink path
                pure (HMAC.update context (frame (["symlink", relative, destination] :: [String])))
              else ioError (userError "unsupported backup tree entry")

  foldlM _ state [] = pure state
  foldlM step state (value : rest) = step state value >>= \next -> foldlM step next rest

writeIntegrityKey :: FilePath -> ByteString.ByteString -> IO ()
writeIntegrityKey path key =
  bracket
    (openFd path WriteOnly defaultFileFlags {creat = Just 0o600, exclusive = True} >>= fdToHandle)
    hClose
    (\handle -> ByteString.hPut handle key)

data BackupScope = BootstrapServices | ServicesAndAuthority
  deriving (Eq)

backupDirectories :: BootstrapProjection -> BackupScope -> [FilePath]
backupDirectories bootstrap scope =
  managementDirectories ++ case scope of
    BootstrapServices -> []
    ServicesAndAuthority -> ["authority-journal", takeFileName (retainedAuthorityCustody bootstrap)]

backupServices :: BootstrapProjection -> IO [BackupStep]
backupServices bootstrap = withBackupScope bootstrap $ \kubeconfig storage stable -> do
  idle <- managementRestoreIdle bootstrap
  if idle
    then backupSelected bootstrap kubeconfig storage stable
    else
      pure
        [BackupStep "storage-scope" False "an unfinished restore holds the selected management storage"]

withBackupScope
  :: BootstrapProjection
  -> (FilePath -> BackupScope -> IO Bool -> IO [BackupStep])
  -> IO [BackupStep]
withBackupScope bootstrap action = do
  leased <- withKindLease bootstrap $ \kindStable -> do
    teardown <- observeKindTeardownAdmission bootstrap
    if teardown == KindIntentMissing
      then selected kindStable
      else pure (scopeRefusal "control removal is present or unobservable")
  pure $ case leased of
    Right (KindLeaseCompleted steps) -> steps
    _ -> scopeRefusal "the retained kind scope could not be held through storage maintenance"
 where
  selected kindStable = do
    snapshot <- withKindKubeconfigSnapshot bootstrap $ \kubeconfig -> do
      retained <- observeRetainedAuthorityJournal bootstrap
      case retained of
        RetainedAuthorityJournalAbsent ->
          action kubeconfig BootstrapServices kindStable
        RetainedAuthorityJournalBound -> do
          let custody = retainedAuthorityCustody bootstrap
              journal = scopeRoot (bootstrapScope bootstrap) </> "authority-journal"
          held <- withJournalCustodyLease custody $ \descriptor custodyStable -> do
            fence <- observeJournalRemovalFence descriptor ByteString.empty
            before <- observeRetainedJournalMirror journal custody
            case before of
              JournalRead operations
                | fence == JournalRemovalFenceAbsent
                , all ((/= OperationUnresolved) . snd) operations -> do
                    let unchanged = do
                          roots <- (&&) <$> kindStable <*> custodyStable
                          observed <- observeRetainedJournalMirror journal custody
                          pure (roots && observed == before)
                    action kubeconfig ServicesAndAuthority unchanged
              _ -> pure (scopeRefusal "the Authority journal needs settlement before storage maintenance")
          pure (maybe (scopeRefusal "the Authority journal lease is unavailable") id held)
        _ -> pure (scopeRefusal "retained Authority storage could not be confirmed")
    pure (either (const (scopeRefusal "the selected control kubeconfig was refused")) id snapshot)
  scopeRefusal detail = [BackupStep "storage-scope" False detail]

backupSelected :: BootstrapProjection -> FilePath -> BackupScope -> IO Bool -> IO [BackupStep]
backupSelected bootstrap kubeconfig storage stable = do
  let scope = bootstrapScope bootstrap
      root = scopeRoot scope
      directories = backupDirectories bootstrap storage
      schemaVersion :: Int
      schemaVersion = case storage of
        BootstrapServices -> 2
        ServicesAndAuthority -> 3
  present <- and <$> mapM (\d -> doesDirectoryExist (root </> d)) directories
  held <- stable
  if not (present && held)
    then
      pure
        [ BackupStep
            "environment"
            False
            "no installed cluster credential or no service data directories; run `control services` first"
        ]
    else do
      random <- withBinaryFile "/dev/urandom" ReadMode (\handle -> ByteString.hGet handle 8)
      let name = "backup-" ++ take 12 (ByteString8.unpack (hexSha256 random))
          target = root </> "backups" </> name
      stopped <- stopServicePods kubeconfig
      if not (serviceStepOk stopped)
        then pure [fromService stopped]
        else do
          createDirectoryIfMissing False (root </> "backups")
          setFileMode (root </> "backups") 0o700
          createDirectoryIfMissing False target
          setFileMode target 0o700
          copies <- mapM (\d -> run "/usr/bin/cp" ["-a", root </> d, target </> d]) directories
          key <- withBinaryFile "/dev/urandom" ReadMode (\handle -> ByteString.hGet handle 32)
          keyWritten <- try (writeIntegrityKey (target </> "integrity.key") key) :: IO (Either IOException ())
          digests <- mapM (\d -> treeDigest key (target </> d)) directories
          originalDigests <- mapM (\d -> treeDigest key (root </> d)) directories
          unchanged <- stable
          let copied = all copySucceeded copies
              combined = fmap concat (sequence digests)
          case (copied, keyWritten, combined) of
            (True, Right (), Right text)
              | ByteString.length key == 32
              , unchanged
              , originalDigests == digests -> do
                  let manifest =
                        Aeson.object
                          [ "schema_version" .= schemaVersion
                          , "scope" .= Text.pack (scopeKindName scope)
                          , "root_generation" .= bootstrapRootGeneration bootstrap
                          , "tree_hmac_sha256" .= text
                          , "directories" .= map Text.pack directories
                          ]
                  ByteString.writeFile (target </> "manifest.json") (LazyByteString.toStrict (Aeson.encode manifest))
                  setFileMode (target </> "manifest.json") 0o600
                  started <- startServicePods kubeconfig
                  pure
                    [ fromService stopped
                    , BackupStep "backup" True ("data directories copied to backups/" ++ name ++ " with manifest")
                    , fromService started
                    ]
            _ -> do
              started <- startServicePods kubeconfig
              pure
                [ fromService stopped
                , BackupStep
                    "backup"
                    False
                    "copying or digesting the data directories failed; the partial backup was kept for inspection"
                , fromService started
                ]

restoreServices :: BootstrapProjection -> String -> IO [BackupStep]
restoreServices bootstrap name
  | not (validBackupName name) =
      pure [BackupStep "backup-name" False "the backup name must be lowercase letters, digits and dashes"]
  | otherwise = do
      observed <- readRestoreManifest bootstrap name
      case observed of
        Left problem -> pure [problem]
        Right _ -> withBackupScope bootstrap (restoreSelected bootstrap name)

readRestoreManifest :: BootstrapProjection -> String -> IO (Either BackupStep Aeson.Object)
readRestoreManifest bootstrap name = do
  let scope = bootstrapScope bootstrap
      path = scopeRoot scope </> "backups" </> name </> "manifest.json"
  manifestBytes <-
    try (withBinaryFile path ReadMode (\handle -> ByteString.hGet handle 16385))
      :: IO (Either IOException ByteString.ByteString)
  pure $ case manifestBytes of
    Left _ -> Left (BackupStep "backup" False "no such backup or its manifest is missing")
    Right bytes
      | ByteString.length bytes > 16384 ->
          Left (BackupStep "manifest" False "the backup manifest exceeds its limit")
      | otherwise -> case Aeson.decodeStrict bytes of
          Just (Aeson.Object fields)
            | field "scope" fields /= Just (Aeson.String (Text.pack (scopeKindName scope)))
                || field "root_generation" fields /= Just (Aeson.String (bootstrapRootGeneration bootstrap)) ->
                Left (BackupStep "manifest" False "the backup names another environment or root generation")
            | field "schema_version" fields == Just (Aeson.Number 1) ->
                Left
                  ( BackupStep
                      "manifest"
                      False
                      "format-1 backup contents cannot be verified; it was retained unchanged. Create a new backup from an independently known-good live source or use a verified backup; otherwise recovery remains incomplete"
                  )
            | otherwise -> Right fields
          _ -> Left (BackupStep "manifest" False "the backup manifest is unreadable")

field :: String -> Aeson.Object -> Maybe Aeson.Value
field = KeyMap.lookup . Key.fromString

restoreSelected
  :: BootstrapProjection -> String -> FilePath -> BackupScope -> IO Bool -> IO [BackupStep]
restoreSelected bootstrap name kubeconfig storage stable = do
  let scope = bootstrapScope bootstrap
      root = scopeRoot scope
      source = root </> "backups" </> name
      directories = backupDirectories bootstrap storage
      schemaVersion = case storage of
        BootstrapServices -> 2
        ServicesAndAuthority -> 3
  manifest <- readRestoreManifest bootstrap name
  case manifest of
    Left problem -> pure [problem]
    Right fields
      | field "schema_version" fields /= Just (Aeson.Number schemaVersion)
          || field "directories" fields /= Just (Aeson.toJSON directories) ->
          pure
            [BackupStep "manifest" False "the backup format or directory set conflicts with the selected scope"]
      | otherwise -> do
          keyResult <-
            try (withBinaryFile (source </> "integrity.key") ReadMode (\handle -> ByteString.hGet handle 33))
              :: IO (Either IOException ByteString.ByteString)
          case keyResult of
            Right key | ByteString.length key == 32 -> do
              digests <- mapM (\directory -> treeDigest key (source </> directory)) directories
              case (field "tree_hmac_sha256" fields, sequence digests) of
                (Just (Aeson.String expected), Right actual)
                  | Text.pack (concat actual) == expected -> do
                      let journalDirectories = drop (length managementDirectories) directories
                      current <- mapM (\directory -> treeDigest key (root </> directory)) journalDirectories
                      unchanged <- stable
                      if unchanged && current == drop (length managementDirectories) digests
                        then
                          restoreManagement
                            bootstrap
                            kubeconfig
                            source
                            name
                            expected
                            key
                            (take (length managementDirectories) digests)
                            ( case storage of
                                BootstrapServices -> pure True
                                ServicesAndAuthority -> protectedRestoreHistoryMatches key source root
                            )
                            stable
                        else pure [BackupStep "journal" False "the Authority journal has changed or cannot be confirmed"]
                _ -> pure [BackupStep "manifest" False "the backup's files do not match its manifest"]
            _ -> pure [BackupStep "manifest" False "the backup integrity key is unavailable"]

restoreManagement
  :: BootstrapProjection
  -> FilePath
  -> FilePath
  -> String
  -> Text.Text
  -> ByteString.ByteString
  -> [Either String String]
  -> IO Bool
  -> IO Bool
  -> IO [BackupStep]
restoreManagement bootstrap kubeconfig source name commitment key expected historyMatches stable =
  observeManagementRestore bootstrap name commitment >>= continue
 where
  root = scopeRoot (bootstrapScope bootstrap)
  continue state = case state of
    ManagementRestoreFresh -> do
      matches <- historyMatches
      if matches
        then stageManagement >>= either (pure . pure) continue
        else pure [historyRefused]
    ManagementRestorePrepared record -> do
      held <- stable
      if not held
        then pure [recovery]
        else do
          stopped <- stopServicePods kubeconfig
          if not (serviceStepOk stopped)
            then pure [fromService stopped]
            else do
              swapped <- resumeManagementSwap bootstrap stable record
              verified <- if swapped then verifyLive else pure False
              installed <- if verified then markManagementInstalled bootstrap record else pure False
              steps <- if installed then continue (ManagementRestoreInstalled record) else pure [recovery]
              pure (fromService stopped : steps)
    ManagementRestoreInstalled record -> do
      settled <-
        finishManagementRestore bootstrap stable record (serviceStepOk <$> startServicePods kubeconfig)
      pure
        [ if settled
            then
              BackupStep
                "restore"
                True
                ("restored management storage; original data remains under replaced-" ++ name ++ "-*")
            else recovery
        ]
    ManagementRestoreSettled -> pure [BackupStep "restore" True "the selected backup restore is already settled"]
    ManagementRestoreUnconfirmed ->
      pure
        [BackupStep "restore" False "the retained restore belongs to another input or cannot be confirmed"]
  stageManagement = do
    random <- withBinaryFile "/dev/urandom" ReadMode (\handle -> ByteString.hGet handle 16)
    let name' = "restore-staged-" ++ take 24 (ByteString8.unpack (hexSha256 random))
        stage = root </> name'
    createDirectory stage
    setFileMode stage 0o700
    copies <-
      traverse
        (\member -> run "/usr/bin/cp" ["-a", source </> member, stage </> member])
        managementDirectories
    staged <- traverse (treeDigest key . (stage </>)) managementDirectories
    synced <- run "/usr/bin/sync" ["-f", stage]
    unchanged <- stable
    historyStillMatches <- historyMatches
    if all copySucceeded copies && copySucceeded synced && staged == expected && unchanged
      then
        if historyStillMatches
          then Right <$> reserveManagementRestore bootstrap name commitment name' stable
          else pure (Left historyRefused)
      else
        pure
          ( Left
              ( BackupStep
                  "stage"
                  False
                  "the staged copies could not be verified; the original data remains in place"
              )
          )
  verifyLive = do
    live <- traverse (treeDigest key . (root </>)) managementDirectories
    held <- stable
    pure (held && live == expected)
  recovery =
    BackupStep
      "restore"
      False
      "management restore remains unsettled; retry the same verified backup for this scope"
  historyRefused =
    BackupStep
      "storage-history"
      False
      "the current Vault or retained MinIO history differs from this backup or cannot be confirmed"

-- | Match the state behind the selected Authority before admitting a storage
-- swap. MinIO's temporary and usage files may change when it restarts, but
-- its durable Broker and Authority buckets and configuration may not rewind.
protectedRestoreHistoryMatches :: ByteString.ByteString -> FilePath -> FilePath -> IO Bool
protectedRestoreHistoryMatches key backup live = do
  saved <- traverse (commitment backup) protected
  current <- traverse (commitment live) protected
  pure $ case (sequence saved, sequence current) of
    (Right expected, Right observed) -> expected == observed
    _ -> False
 where
  protected =
    [ "vault-data"
    , "minio-data" </> localBrokerStoreBucket
    , "minio-data" </> defaultObjectStoreBucket
    , "minio-data" </> ".minio.sys" </> "config"
    ]
  commitment root member = do
    let path = root </> member
        chain = scanl (</>) root (splitDirectories member)
    observed <- try (traverse getSymbolicLinkStatus chain) :: IO (Either IOException [FileStatus])
    case observed of
      Right directories | all isDirectory directories -> treeDigest key path
      _ -> pure (Left "protected restore directory is unobservable")
