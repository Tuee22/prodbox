{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Sprint 7.14: decrypt-to-scratch Pulumi backend interposition.
--
-- Pulumi works against a temporary @file://@ backend while persistent state is
-- stored as a Model-B logical object in MinIO. The production resolver obtains
-- the object-store cipher/HMAC inputs from Vault; tests use the explicit hook
-- seam below.
module Prodbox.Pulumi.EncryptedBackend
  ( EncryptedBackendError (..)
  , EncryptedBackendHooks (..)
  , LegacyPulumiBackend (..)
  , PulumiScratch (..)
  , PulumiStackRef (..)
  , collectScratchCheckpoint
  , deleteLogicalPulumiStackWith
  , fileBackendEnvironment
  , hydrateScratchCheckpoint
  , renderEncryptedBackendError
  , stackCheckpointPath
  , withDecryptedStack
  , withDecryptedStackEnvironment
  , withMigratedDecryptedStackEnvironment
  , withDecryptedStackWith
  )
where

import Control.Exception (IOException, bracket, try)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Char (toLower)
import Data.Foldable (traverse_)
import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Config.Basics (UnencryptedBasics (..))
import Prodbox.Crypto.Envelope (DekCipher)
import Prodbox.Http.Client (renderHttpError)
import Prodbox.Infra.MinioBackend
  ( minioEndpointUrl
  , pulumiBackendLoginTimeoutSeconds
  , withMinioPortForward
  )
import Prodbox.Minio.EncryptedObject
  ( EncryptedObjectError (..)
  , LogicalObject (LogicalPulumiStack)
  , getLogical
  , objectKeyForOpaqueId
  , opaqueObjectId
  , putLogical
  , renderEncryptedObjectError
  )
import Prodbox.Minio.ObjectStore
  ( ObjectStoreConfig (..)
  , defaultObjectStoreBucket
  , deleteObject
  )
import Prodbox.Result (Result (..))
import Prodbox.Settings (loadUnencryptedBasics)
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  )
import Prodbox.Vault.Client
  ( VaultAddress (..)
  , VaultToken
  , vaultKvReadV2
  , vaultSealStatus
  )
import Prodbox.Vault.Gate
  ( VaultGateOutcome (..)
  , vaultGateOutcome
  )
import Prodbox.Vault.Host (loadReadyVaultRootToken)
import Prodbox.Vault.TransitCipher (vaultTransitDekCipher)
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , getTemporaryDirectory
  , removeFile
  )
import System.Exit (ExitCode (..))
import System.FilePath
  ( takeDirectory
  , (</>)
  )
import System.IO (Handle, hClose, openTempFile)
import System.IO.Temp (withSystemTempDirectory, withTempDirectory)

data PulumiStackRef = PulumiStackRef
  { pulumiProjectName :: Text
  , pulumiStackName :: Text
  }
  deriving (Eq, Show)

data PulumiScratch = PulumiScratch
  { pulumiScratchRoot :: FilePath
  , pulumiScratchBackendUrl :: String
  , pulumiScratchCheckpointPath :: FilePath
  }
  deriving (Eq, Show)

data LegacyPulumiBackend = LegacyPulumiBackend
  { legacyPulumiProjectDir :: FilePath
  , legacyPulumiEnvironment :: [(String, String)]
  , legacyPulumiStackName :: Text
  }
  deriving (Eq, Show)

data EncryptedBackendError
  = EncryptedBackendVaultRefused String
  | EncryptedBackendLoadFailed String
  | EncryptedBackendHydrateFailed String
  | EncryptedBackendActionFailed String
  | EncryptedBackendCollectFailed String
  | EncryptedBackendStoreFailed String
  | EncryptedBackendDeleteFailed String
  | EncryptedBackendLegacyDeleteFailed String
  deriving (Eq, Show)

renderEncryptedBackendError :: EncryptedBackendError -> String
renderEncryptedBackendError err = case err of
  EncryptedBackendVaultRefused detail -> detail
  EncryptedBackendLoadFailed detail -> "failed to load encrypted Pulumi checkpoint: " ++ detail
  EncryptedBackendHydrateFailed detail -> "failed to hydrate Pulumi scratch backend: " ++ detail
  EncryptedBackendActionFailed detail -> detail
  EncryptedBackendCollectFailed detail -> "failed to collect Pulumi scratch checkpoint: " ++ detail
  EncryptedBackendStoreFailed detail -> "failed to store encrypted Pulumi checkpoint: " ++ detail
  EncryptedBackendDeleteFailed detail -> "failed to delete encrypted Pulumi checkpoint: " ++ detail
  EncryptedBackendLegacyDeleteFailed detail ->
    "failed to delete legacy Pulumi checkpoint after encrypted migration: " ++ detail

data EncryptedBackendHooks a = EncryptedBackendHooks
  { encryptedBackendGate :: IO VaultGateOutcome
  , encryptedBackendLoad :: PulumiStackRef -> IO (Either String (Maybe ByteString))
  , encryptedBackendLoadLegacy :: PulumiStackRef -> IO (Either String (Maybe ByteString))
  , encryptedBackendStore :: PulumiStackRef -> ByteString -> IO (Either String ())
  , encryptedBackendDelete :: PulumiStackRef -> IO (Either String ())
  , encryptedBackendDeleteLegacy :: PulumiStackRef -> IO (Either String ())
  , encryptedBackendWithScratch
      :: PulumiStackRef
      -> (PulumiScratch -> IO (Either EncryptedBackendError a))
      -> IO (Either EncryptedBackendError a)
  }

data LoadedCheckpoint = LoadedCheckpoint
  { loadedCheckpointBytes :: Maybe ByteString
  , loadedCheckpointFromLegacy :: Bool
  }

withDecryptedStack
  :: FilePath
  -> PulumiStackRef
  -> (PulumiScratch -> IO (Either String a))
  -> IO (Either EncryptedBackendError a)
withDecryptedStack repoRoot stackRef action = do
  materialInputResult <- resolvePulumiBackendMaterialInput repoRoot
  case materialInputResult of
    Left err -> pure (Left (EncryptedBackendLoadFailed err))
    Right materialInput -> do
      forwardResult <-
        withMinioPortForward $ \localPort ->
          withDecryptedStackWith
            (productionHooks (materialFromInput materialInput localPort))
            stackRef
            action
      pure $ case forwardResult of
        Left err -> Left (EncryptedBackendLoadFailed ("failed to reach Pulumi object-store MinIO backend: " ++ err))
        Right result -> result

withDecryptedStackEnvironment
  :: FilePath
  -> PulumiStackRef
  -> [(String, String)]
  -> ([(String, String)] -> IO (Either String a))
  -> IO (Either EncryptedBackendError a)
withDecryptedStackEnvironment repoRoot stackRef environment action =
  withDecryptedStack repoRoot stackRef $ \scratch ->
    action (fileBackendEnvironment scratch environment)

withMigratedDecryptedStackEnvironment
  :: FilePath
  -> PulumiStackRef
  -> LegacyPulumiBackend
  -> [(String, String)]
  -> ([(String, String)] -> IO (Either String a))
  -> IO (Either EncryptedBackendError a)
withMigratedDecryptedStackEnvironment repoRoot stackRef legacy environment action =
  withDecryptedStackMigrating repoRoot stackRef legacy $ \scratch ->
    action (fileBackendEnvironment scratch environment)

withDecryptedStackMigrating
  :: FilePath
  -> PulumiStackRef
  -> LegacyPulumiBackend
  -> (PulumiScratch -> IO (Either String a))
  -> IO (Either EncryptedBackendError a)
withDecryptedStackMigrating repoRoot stackRef legacy action = do
  materialInputResult <- resolvePulumiBackendMaterialInput repoRoot
  case materialInputResult of
    Left err -> pure (Left (EncryptedBackendLoadFailed err))
    Right materialInput -> do
      forwardResult <-
        withMinioPortForward $ \localPort ->
          withDecryptedStackWith
            (productionHooksWithLegacy legacy (materialFromInput materialInput localPort))
            stackRef
            action
      pure $ case forwardResult of
        Left err -> Left (EncryptedBackendLoadFailed ("failed to reach Pulumi object-store MinIO backend: " ++ err))
        Right result -> result

withDecryptedStackWith
  :: EncryptedBackendHooks a
  -> PulumiStackRef
  -> (PulumiScratch -> IO (Either String a))
  -> IO (Either EncryptedBackendError a)
withDecryptedStackWith hooks stackRef action = do
  gateResult <- encryptedBackendGate hooks
  case gateResult of
    VaultGateRefuse message -> pure (Left (EncryptedBackendVaultRefused message))
    VaultGateProceed -> do
      loadResult <- loadEncryptedOrLegacyCheckpoint hooks stackRef
      case loadResult of
        Left err -> pure (Left (EncryptedBackendLoadFailed err))
        Right loaded ->
          encryptedBackendWithScratch hooks stackRef $ \scratch -> do
            hydrateResult <- hydrateScratchCheckpoint scratch (loadedCheckpointBytes loaded)
            case hydrateResult of
              Left err -> pure (Left (EncryptedBackendHydrateFailed err))
              Right () -> do
                actionResult <- action scratch
                collectResult <- collectScratchCheckpoint scratch
                case collectResult of
                  Left err -> pure (Left (EncryptedBackendCollectFailed err))
                  Right Nothing -> do
                    deleteResult <- encryptedBackendDelete hooks stackRef
                    case deleteResult of
                      Left err -> pure (Left (EncryptedBackendDeleteFailed err))
                      Right () ->
                        finalizeAction hooks stackRef (loadedCheckpointFromLegacy loaded) actionResult
                  Right (Just bytes) -> do
                    storeResult <- encryptedBackendStore hooks stackRef bytes
                    case storeResult of
                      Left err -> pure (Left (EncryptedBackendStoreFailed err))
                      Right () ->
                        finalizeAction hooks stackRef (loadedCheckpointFromLegacy loaded) actionResult

loadEncryptedOrLegacyCheckpoint
  :: EncryptedBackendHooks a -> PulumiStackRef -> IO (Either String LoadedCheckpoint)
loadEncryptedOrLegacyCheckpoint hooks stackRef = do
  encryptedResult <- encryptedBackendLoad hooks stackRef
  case encryptedResult of
    Left err -> pure (Left err)
    Right (Just checkpoint) ->
      pure
        ( Right
            LoadedCheckpoint
              { loadedCheckpointBytes = Just checkpoint
              , loadedCheckpointFromLegacy = False
              }
        )
    Right Nothing -> do
      legacyResult <- encryptedBackendLoadLegacy hooks stackRef
      pure $ case legacyResult of
        Left err -> Left err
        Right checkpoint ->
          Right
            LoadedCheckpoint
              { loadedCheckpointBytes = checkpoint
              , loadedCheckpointFromLegacy = maybe False (const True) checkpoint
              }

finalizeAction
  :: EncryptedBackendHooks a
  -> PulumiStackRef
  -> Bool
  -> Either String a
  -> IO (Either EncryptedBackendError a)
finalizeAction hooks stackRef migratedFromLegacy actionResult =
  case actionResult of
    Left err -> pure (Left (EncryptedBackendActionFailed err))
    Right value ->
      if not migratedFromLegacy
        then pure (Right value)
        else do
          deleteLegacyResult <- encryptedBackendDeleteLegacy hooks stackRef
          pure $ case deleteLegacyResult of
            Left err -> Left (EncryptedBackendLegacyDeleteFailed err)
            Right () -> Right value

hydrateScratchCheckpoint :: PulumiScratch -> Maybe ByteString -> IO (Either String ())
hydrateScratchCheckpoint scratch checkpoint = do
  let path = pulumiScratchCheckpointPath scratch
  tryWrite path checkpoint

collectScratchCheckpoint :: PulumiScratch -> IO (Either String (Maybe ByteString))
collectScratchCheckpoint scratch = do
  exists <- doesFileExist (pulumiScratchCheckpointPath scratch)
  if not exists
    then pure (Right Nothing)
    else do
      readResult <- tryRead (pulumiScratchCheckpointPath scratch)
      pure (Just <$> readResult)

stackCheckpointPath :: FilePath -> PulumiStackRef -> FilePath
stackCheckpointPath scratchRoot stackRef =
  scratchRoot
    </> ".pulumi"
    </> "stacks"
    </> Text.unpack (pulumiProjectName stackRef)
    </> Text.unpack (pulumiStackName stackRef)
    ++ ".json"

fileBackendEnvironment :: PulumiScratch -> [(String, String)] -> [(String, String)]
fileBackendEnvironment scratch =
  upsert "PULUMI_BACKEND_URL" (pulumiScratchBackendUrl scratch)
    . filter ((`notElem` removedBackendKeys) . fst)
 where
  removedBackendKeys =
    [ "AWS_ACCESS_KEY_ID"
    , "AWS_SECRET_ACCESS_KEY"
    , "AWS_SESSION_TOKEN"
    , "AWS_REGION"
    , "AWS_DEFAULT_REGION"
    , "PULUMI_CONFIG_PASSPHRASE"
    ]

deleteLogicalPulumiStackWith
  :: ObjectStoreConfig
  -> ByteString
  -> PulumiStackRef
  -> IO (Either String ())
deleteLogicalPulumiStackWith config hmacKey stackRef =
  deleteObject config (logicalPulumiObjectKey hmacKey stackRef)

data PulumiBackendMaterialInput = PulumiBackendMaterialInput
  { materialInputAccessKey :: Text
  , materialInputSecretKey :: Text
  , materialInputCipher :: DekCipher
  , materialInputHmacKey :: ByteString
  , materialInputClusterId :: Text
  }

data PulumiBackendMaterial = PulumiBackendMaterial
  { materialObjectStore :: ObjectStoreConfig
  , materialCipher :: DekCipher
  , materialHmacKey :: ByteString
  , materialClusterId :: Text
  }

productionHooks :: PulumiBackendMaterial -> EncryptedBackendHooks a
productionHooks material =
  EncryptedBackendHooks
    { encryptedBackendGate = pure VaultGateProceed
    , encryptedBackendLoad = \stackRef -> do
        result <-
          getLogical
            (materialObjectStore material)
            (materialCipher material)
            (materialHmacKey material)
            (materialClusterId material)
            (logicalPulumiStack stackRef)
        pure $ case result of
          Left (EncryptedObjectMissing _) -> Right Nothing
          Left err -> Left (renderEncryptedObjectError err)
          Right bytes -> Right (Just bytes)
    , encryptedBackendLoadLegacy = \_ -> pure (Right Nothing)
    , encryptedBackendStore = \stackRef bytes ->
        mapLeft renderEncryptedObjectError
          <$> putLogical
            (materialObjectStore material)
            (materialCipher material)
            (materialHmacKey material)
            (materialClusterId material)
            (logicalPulumiStack stackRef)
            bytes
    , encryptedBackendDelete =
        deleteLogicalPulumiStackWith (materialObjectStore material) (materialHmacKey material)
    , encryptedBackendDeleteLegacy = \_ -> pure (Right ())
    , encryptedBackendWithScratch = withRamScratch
    }

productionHooksWithLegacy :: LegacyPulumiBackend -> PulumiBackendMaterial -> EncryptedBackendHooks a
productionHooksWithLegacy legacy material =
  (productionHooks material)
    { encryptedBackendLoadLegacy = \_ -> exportLegacyPulumiCheckpoint legacy
    , encryptedBackendDeleteLegacy = \_ -> removeLegacyPulumiStack legacy
    }

exportLegacyPulumiCheckpoint :: LegacyPulumiBackend -> IO (Either String (Maybe ByteString))
exportLegacyPulumiCheckpoint legacy =
  case legacyBackendUrl legacy of
    Left err -> pure (Left err)
    Right backendUrl -> do
      loginResult <-
        runLegacyPulumiExit
          "pulumi login against legacy backend"
          legacy
          ["login", backendUrl]
      case loginResult of
        Left err -> pure (Left err)
        Right _ -> do
          selectResult <-
            runLegacyPulumi legacy ["stack", "select", Text.unpack (legacyPulumiStackName legacy)]
          case selectResult of
            Left err -> pure (Left err)
            Right selectOutput ->
              case processExitCode selectOutput of
                ExitSuccess ->
                  bracket openCheckpointTemp removeCheckpointTemp $ \(path, handle) -> do
                    _ <- try (hClose handle) :: IO (Either IOException ())
                    exportResult <-
                      runLegacyPulumiExit
                        "pulumi stack export from legacy backend"
                        legacy
                        [ "stack"
                        , "export"
                        , "--stack"
                        , Text.unpack (legacyPulumiStackName legacy)
                        , "--file"
                        , path
                        ]
                    case exportResult of
                      Left err -> pure (Left err)
                      Right _ -> fmap Just <$> tryRead path
                ExitFailure _
                  | isMissingPulumiStackError
                      (Text.unpack (legacyPulumiStackName legacy))
                      (renderProcessDetail selectOutput) ->
                      pure (Right Nothing)
                  | otherwise ->
                      pure
                        ( Left
                            ( "pulumi stack select against legacy backend failed: "
                                ++ renderProcessDetail selectOutput
                            )
                        )

removeLegacyPulumiStack :: LegacyPulumiBackend -> IO (Either String ())
removeLegacyPulumiStack legacy =
  case legacyBackendUrl legacy of
    Left err -> pure (Left err)
    Right backendUrl -> do
      loginResult <-
        runLegacyPulumiExit
          "pulumi login against legacy backend"
          legacy
          ["login", backendUrl]
      case loginResult of
        Left err -> pure (Left err)
        Right _ -> do
          removeResult <-
            runLegacyPulumi
              legacy
              [ "stack"
              , "rm"
              , "--yes"
              , "--remove-backups"
              , "--force"
              , Text.unpack (legacyPulumiStackName legacy)
              ]
          pure $ case removeResult of
            Left err -> Left err
            Right output ->
              case processExitCode output of
                ExitSuccess -> Right ()
                ExitFailure _
                  | isMissingPulumiStackError
                      (Text.unpack (legacyPulumiStackName legacy))
                      (renderProcessDetail output) ->
                      Right ()
                  | otherwise ->
                      Left
                        ( "pulumi stack rm against legacy backend failed: "
                            ++ renderProcessDetail output
                        )

legacyBackendUrl :: LegacyPulumiBackend -> Either String String
legacyBackendUrl legacy =
  case lookup "PULUMI_BACKEND_URL" (legacyPulumiEnvironment legacy) of
    Just value | not (null (trim value)) -> Right value
    _ -> Left "legacy Pulumi backend environment is missing PULUMI_BACKEND_URL"

runLegacyPulumiExit
  :: String -> LegacyPulumiBackend -> [String] -> IO (Either String ProcessOutput)
runLegacyPulumiExit label legacy arguments = do
  outputResult <- runLegacyPulumi legacy arguments
  pure $ case outputResult of
    Left err -> Left err
    Right output ->
      case processExitCode output of
        ExitSuccess -> Right output
        ExitFailure 124
          | isPulumiLoginCommand arguments ->
              Left
                ( "timed out after "
                    ++ show pulumiBackendLoginTimeoutSeconds
                    ++ " seconds while running `pulumi login` against the legacy backend"
                )
        ExitFailure _ -> Left (label ++ " failed: " ++ renderProcessDetail output)

runLegacyPulumi :: LegacyPulumiBackend -> [String] -> IO (Either String ProcessOutput)
runLegacyPulumi legacy arguments = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath =
            if isPulumiLoginCommand arguments
              then "timeout"
              else "pulumi"
        , subprocessArguments =
            if isPulumiLoginCommand arguments
              then
                [ "--kill-after=10s"
                , show pulumiBackendLoginTimeoutSeconds
                , "pulumi"
                ]
                  ++ arguments
                  ++ ["--non-interactive"]
              else arguments
        , subprocessEnvironment = Just (legacyPulumiEnvironment legacy)
        , subprocessWorkingDirectory = Just (legacyPulumiProjectDir legacy)
        }
  pure $ case result of
    Failure err -> Left err
    Success output -> Right output

isPulumiLoginCommand :: [String] -> Bool
isPulumiLoginCommand arguments =
  case arguments of
    "login" : _ -> True
    _ -> False

isMissingPulumiStackError :: String -> String -> Bool
isMissingPulumiStackError stackName detail =
  let lowered = map toLower detail
      loweredStackName = map toLower stackName
   in "no stack named" `isInfixOf` lowered
        && loweredStackName `isInfixOf` lowered
        && "found" `isInfixOf` lowered

renderProcessDetail :: ProcessOutput -> String
renderProcessDetail output =
  case filter (not . null) [trim (processStderr output), trim (processStdout output)] of
    [] -> "subprocess exited without output"
    rendered -> foldr1 (\left right -> left ++ " | " ++ right) rendered

openCheckpointTemp :: IO (FilePath, Handle)
openCheckpointTemp = do
  parent <- getTemporaryDirectory
  openTempFile parent "prodbox-pulumi-legacy-export.json"

removeCheckpointTemp :: (FilePath, Handle) -> IO ()
removeCheckpointTemp (path, handle) = do
  _ <- try (hClose handle) :: IO (Either IOException ())
  _ <- try (removeFile path) :: IO (Either IOException ())
  pure ()

materialFromInput :: PulumiBackendMaterialInput -> Int -> PulumiBackendMaterial
materialFromInput input localPort =
  PulumiBackendMaterial
    { materialObjectStore =
        ObjectStoreConfig
          { objectStoreEndpoint = minioEndpointUrl localPort
          , objectStoreBucket = defaultObjectStoreBucket
          , objectStoreAccessKey = Text.unpack (materialInputAccessKey input)
          , objectStoreSecretKey = Text.unpack (materialInputSecretKey input)
          }
    , materialCipher = materialInputCipher input
    , materialHmacKey = materialInputHmacKey input
    , materialClusterId = materialInputClusterId input
    }

resolvePulumiBackendMaterialInput :: FilePath -> IO (Either String PulumiBackendMaterialInput)
resolvePulumiBackendMaterialInput repoRoot = do
  basicsResult <- loadUnencryptedBasics repoRoot
  case basicsResult of
    Left err -> pure (Left err)
    Right basics -> do
      let address = VaultAddress (basicsVaultAddress basics)
      gateResult <- vaultGateOutcome <$> vaultSealStatus address
      case gateResult of
        VaultGateRefuse message -> pure (Left message)
        VaultGateProceed -> do
          tokenResult <- loadReadyVaultRootToken repoRoot address
          case tokenResult of
            Left err -> pure (Left err)
            Right token -> resolveInputWithToken basics address token

resolveInputWithToken
  :: UnencryptedBasics -> VaultAddress -> VaultToken -> IO (Either String PulumiBackendMaterialInput)
resolveInputWithToken basics address token = do
  minioResult <- readVaultFields address token "secret/minio/root" ["rootUser", "rootPassword"]
  hmacResult <- readVaultFields address token "secret/object-store/hmac" ["key"]
  case (minioResult, hmacResult) of
    (Left err, _) -> pure (Left err)
    (_, Left err) -> pure (Left err)
    (Right minioFields, Right hmacFields) ->
      pure
        ( Right
            PulumiBackendMaterialInput
              { materialInputAccessKey = Map.findWithDefault "" "rootUser" minioFields
              , materialInputSecretKey = Map.findWithDefault "" "rootPassword" minioFields
              , materialInputCipher = vaultTransitDekCipher address token "prodbox-pulumi-state"
              , materialInputHmacKey = TextEncoding.encodeUtf8 (Map.findWithDefault "" "key" hmacFields)
              , materialInputClusterId = basicsClusterId basics
              }
        )

readVaultFields
  :: VaultAddress -> VaultToken -> Text -> [Text] -> IO (Either String (Map.Map Text Text))
readVaultFields address token path fields = do
  let kvPath = maybe path id (Text.stripPrefix "secret/" path)
  result <- vaultKvReadV2 address token "secret" kvPath
  pure $ case result of
    Left err -> Left ("failed to read " ++ Text.unpack path ++ " from Vault: " ++ renderHttpError err)
    Right values -> do
      traverse_ (requireField values) fields
      Right values
 where
  requireField values field =
    case Map.lookup field values of
      Just value | not (Text.null (Text.strip value)) -> Right ()
      _ -> Left ("Vault path " ++ Text.unpack path ++ " is missing field " ++ Text.unpack field)

withRamScratch
  :: PulumiStackRef
  -> (PulumiScratch -> IO (Either EncryptedBackendError a))
  -> IO (Either EncryptedBackendError a)
withRamScratch stackRef action = do
  shmExists <- doesDirectoryExist "/dev/shm"
  let runWith parent = withTempDirectory parent "prodbox-pulumi-" (action . scratchAt)
      scratchAt root =
        PulumiScratch
          { pulumiScratchRoot = root
          , pulumiScratchBackendUrl = "file://" ++ root
          , pulumiScratchCheckpointPath = stackCheckpointPath root stackRef
          }
  if shmExists
    then runWith "/dev/shm"
    else withSystemTempDirectory "prodbox-pulumi-" (action . scratchAt)

logicalPulumiStack :: PulumiStackRef -> LogicalObject
logicalPulumiStack stackRef =
  LogicalPulumiStack (pulumiStackName stackRef)

logicalPulumiObjectKey :: ByteString -> PulumiStackRef -> Text
logicalPulumiObjectKey hmacKey =
  objectKeyForOpaqueId . opaqueObjectId hmacKey . logicalPulumiStack

tryWrite :: FilePath -> Maybe ByteString -> IO (Either String ())
tryWrite path Nothing = do
  createDirectoryIfMissing True (takeDirectory path)
  pure (Right ())
tryWrite path (Just bytes) = do
  tryIo $ do
    createDirectoryIfMissing True (takeDirectory path)
    BS.writeFile path bytes

tryRead :: FilePath -> IO (Either String ByteString)
tryRead path = tryIo (BS.readFile path)

tryIo :: IO a -> IO (Either String a)
tryIo action = do
  result <- try action
  pure $ case result of
    Left (err :: IOException) -> Left (show err)
    Right value -> Right value

upsert :: String -> String -> [(String, String)] -> [(String, String)]
upsert key value environment =
  (key, value) : filter ((/= key) . fst) environment

mapLeft :: (a -> b) -> Either a c -> Either b c
mapLeft f value = case value of
  Left err -> Left (f err)
  Right ok -> Right ok

trim :: String -> String
trim = reverse . dropWhile (\c -> c == '\n' || c == '\r' || c == ' ') . reverse
