{-# LANGUAGE OverloadedStrings #-}

-- | Local backup and restore of the bootstrap services' retained data (Vault's
-- file storage and MinIO's data directory) for one test environment. A backup
-- stops the Vault and MinIO Pods so the copy is consistent, copies both data
-- directories with their ownership and times into
-- @<root>/backups/<name>/@, records a manifest naming the scope, the root
-- generation and a SHA-256 over the sorted file list with sizes, and starts the
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
  ) where

import Control.Exception (IOException, try)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAsciiLower, isDigit)
import Data.List (sort)
import Data.Text qualified as Text
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapRootGeneration
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope (scopeKindName, scopeRoot)
import Prodbox.Control.Services (ServiceStep (..), startServicePods, stopServicePods)
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessWithInputBounded
  )
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , renameDirectory
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (IOMode (ReadMode), withBinaryFile)
import System.Posix.Files (setFileMode)

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

validName :: String -> Bool
validName name = not (null name) && length name <= 40 && all (\c -> isAsciiLower c || isDigit c || c == '-') name

-- | SHA-256 over the sorted "relative-path size" lines of both data trees.
treeDigest :: FilePath -> IO (Either String String)
treeDigest directory = do
  listed <- run "/usr/bin/find" [directory, "-type", "f", "-printf", "%P %s\n"]
  pure $ case listed of
    Right (0, out) -> Right (ByteString8.unpack (hexSha256 (ByteString8.pack (unlines (sort (lines out))))))
    Right (code, _) -> Left ("find exit " ++ show code)
    Left failure -> Left failure

dataDirectories :: [FilePath]
dataDirectories = ["vault-data", "minio-data"]

backupServices :: BootstrapProjection -> IO [BackupStep]
backupServices bootstrap = do
  let scope = bootstrapScope bootstrap
      root = scopeRoot scope
      kubeconfig = root </> "control" </> "kubeconfig"
  present <- doesFileExist kubeconfig
  present' <- and <$> mapM (\d -> doesDirectoryExist (root </> d)) dataDirectories
  if not (present && present')
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
          copies <- mapM (\d -> run "/usr/bin/cp" ["-a", root </> d, target </> d]) dataDirectories
          digests <- mapM (\d -> treeDigest (target </> d)) dataDirectories
          let copied = all copySucceeded copies
              combined = fmap concat (sequence digests)
          case (copied, combined) of
            (True, Right text) -> do
              let manifest =
                    Aeson.object
                      [ "schema_version" .= (1 :: Int)
                      , "scope" .= Text.pack (scopeKindName scope)
                      , "root_generation" .= bootstrapRootGeneration bootstrap
                      , "tree_sha256" .= text
                      , "directories" .= map Text.pack dataDirectories
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
restoreServices bootstrap name = do
  let scope = bootstrapScope bootstrap
      root = scopeRoot scope
      kubeconfig = root </> "control" </> "kubeconfig"
      source = root </> "backups" </> name
  if not (validName name)
    then
      pure [BackupStep "backup-name" False "the backup name must be lowercase letters, digits and dashes"]
    else do
      manifestBytes <-
        try (ByteString.readFile (source </> "manifest.json"))
          :: IO (Either IOException ByteString.ByteString)
      case manifestBytes of
        Left _ -> pure [BackupStep "backup" False "no such backup or its manifest is missing"]
        Right bytes -> case Aeson.decodeStrict bytes of
          Just (Aeson.Object fields)
            | KeyMap.lookup (Key.fromString "scope") fields
                /= Just (Aeson.String (Text.pack (scopeKindName scope)))
                || KeyMap.lookup (Key.fromString "root_generation") fields
                  /= Just (Aeson.String (bootstrapRootGeneration bootstrap)) ->
                pure
                  [ BackupStep
                      "manifest"
                      False
                      "the backup names another environment or root generation; it was not used"
                  ]
            | otherwise -> do
                digests <- mapM (\d -> treeDigest (source </> d)) dataDirectories
                let expected = case KeyMap.lookup (Key.fromString "tree_sha256") fields of
                      Just (Aeson.String text) -> Just (Text.unpack text)
                      _ -> Nothing
                    actual = fmap concat (sequence digests)
                if expected == Nothing || actual /= maybe (Left "") Right expected
                  then
                    pure [BackupStep "manifest" False "the backup's files do not match its manifest; it was not used"]
                  else do
                    stopped <- stopServicePods kubeconfig
                    if not (serviceStepOk stopped)
                      then pure [fromService stopped]
                      else do
                        aside <-
                          mapM
                            ( \d ->
                                try (renameDirectory (root </> d) (root </> ("replaced-" ++ name ++ "-" ++ d)))
                                  :: IO (Either IOException ())
                            )
                            dataDirectories
                        copies <- mapM (\d -> run "/usr/bin/cp" ["-a", source </> d, root </> d]) dataDirectories
                        let ok =
                              all (either (const False) (const True)) aside
                                && all copySucceeded copies
                        started <- startServicePods kubeconfig
                        pure
                          [ fromService stopped
                          , BackupStep
                              "restore"
                              ok
                              ( if ok
                                  then "the current data was moved to replaced-" ++ name ++ "-*, the backup copied into place"
                                  else "moving or copying failed; the replaced data is kept under replaced-" ++ name ++ "-*"
                              )
                          , fromService started
                          ]
          _ -> pure [BackupStep "manifest" False "the backup manifest is unreadable"]
