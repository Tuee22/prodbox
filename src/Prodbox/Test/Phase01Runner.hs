{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The Phase 1 scenario runner: drive the built public binary through one
-- real lifecycle of an explicitly selected, already prepared test identity
-- (reconcile, status, delete, status), record what the public commands
-- claimed, then take separate observations with other tools (the Docker CLI,
-- kubectl against the installed credential, direct file reads), publish the
-- report in the append-only store and validate it against those independent
-- observations. A pass needs every claimed observation to agree with its
-- independent counterpart. The report is non-secret: only digests, outcomes and
-- fixed observation names. This runner owns isolation and cleanup, never
-- repairs by hand, and preserves a failed primary result separately from the
-- cleanup result.
module Prodbox.Test.Phase01Runner
  ( runPhase01Scenario
  , runFreshPhase01Scenario
  , run
  , satisfied
  , hex32
  , digest
  , readRandomBytes
  , validateScenarioEntropy
  , validateBootIdentity
  , FreshImageInventory (..)
  , observeFreshImageInventory
  , fixtureNetworkId
  , fixtureNetworkUntouched
  , dockerArguments
  , ImportAdverseEvidence (..)
  , runFreshImportAdverses
  , runFreshImportAdversesWith
  , observeBareRetainedScope
  , fixtureBaseMatches
  , scenarioReport
  , publishScenario
  , independentClusterReady
  , independentAbsence
  , independentHostData
  , containerId
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)

import Control.Exception (IOException, bracket, throwIO, try)
import Control.Monad (unless, when)
import Data.Bifunctor qualified as Bifunctor
import Data.Bits ((.&.))
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.Char (isAsciiLower, isDigit)
import Data.List (isInfixOf, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as Text
import Data.Word (Word16, Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.CLI.Output (writeOutputLine)
import Prodbox.Config.BootstrapProjection
  ( ArtifactDeclaration (..)
  , BootstrapProjection
  , bootstrapKindPlan
  , bootstrapKindTool
  , bootstrapNodeArtifact
  , bootstrapRootGeneration
  , bootstrapRuntimeSocket
  , bootstrapScope
  , decodeOptionalBootstrapSource
  , readBootstrapProjection
  )
import Prodbox.Config.DeploymentScope
  ( DeploymentEnvironment (Test)
  , ScopeArtifactObservation (..)
  , ScopeGenerationObservation (ScopeGenerationMatches)
  , ScopeRootObservation (ScopeRootAbsent)
  , deploymentScope
  , observeScopeArtifact
  , observeScopeGeneration
  , observeScopeRoot
  , scopeApiPort
  , scopeEnvironment
  , scopeIdentifier
  , scopeKindName
  , scopeRoot
  , withScopeRootDescriptor
  )
import Prodbox.Config.KindPlan (kindPlanHostPorts, kindPlanNodeImage, renderKindConfig)
import Prodbox.Config.SelectedDhall (readSelectedDhall)
import Prodbox.Control.NetworkEnforcement
  ( EnforcementCleanup (..)
  , EnforcementOutcome (..)
  , enforcementProven
  , observeNetworkEnforcementScoped
  )
import Prodbox.Control.KindIntent (KindIntentObservation (KindIntentMatches), observeKindIntent)
import Prodbox.Error (AppError)
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessWithInputBounded
  )
import Prodbox.Test.FixtureTree (captureFixtureTree, cleanupFixtureTree, cleanupFixtureTrees)
import Prodbox.Test.NodeRegistryPreparation
  ( PreparationResult (..)
  , pinnedNodeImage
  , prepareAdverseImportSources
  , prepareFreshNodeArchive
  , preparePinnedKindArtifact
  , prepareRegistryNodeArchive
  )
import Prodbox.Test.Qualification.Evidence (PublicEvidenceDigest, hashPublicEvidence)
import Prodbox.Test.Qualification.SourceIdentity (SourceIdentity)
import Prodbox.Test.Qualification.SourceManifest (captureSourceIdentity)
import Prodbox.Test.ScenarioEvidence
  ( EvidenceComparison (..)
  , IndependentScenarioObservation (..)
  , ObservationResult (..)
  , ScenarioBinding (..)
  , ScenarioBudget (..)
  , ScenarioCleanup (..)
  , ScenarioObservation (..)
  , ScenarioPrimary (..)
  , ScenarioReport (..)
  , ScenarioTiming (..)
  )
import Prodbox.Test.ScenarioEvidenceStore (validateStoredScenarioReport, writeScenarioReport)
import System.Directory
  ( canonicalizePath
  , createDirectory
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , getFileSize
  , listDirectory
  )
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.IO (IOMode (ReadMode), withBinaryFile)
import System.Posix.Files
  ( createSymbolicLink
  , deviceID
  , fileID
  , fileMode
  , fileOwner
  , getFdStatus
  , getSymbolicLinkStatus
  , isDirectory
  , modificationTimeHiRes
  , setFileMode
  , statusChangeTimeHiRes
  )
import System.Posix.IO qualified as Posix
import System.Posix.Types (Fd (..))
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

limits :: BoundedSubprocessLimits
limits = BoundedSubprocessLimits 1 (512 * 1024) (64 * 1024) 1200000000

-- | Run one command with a closed stdin and bounded output. A failure to run
-- is returned, never mapped to an exit status.
run :: FilePath -> [String] -> IO (Either String (Int, String, String))
run program arguments = runWithInput program arguments ByteString.empty

runDocker :: FilePath -> [String] -> IO (Either String (Int, String, String))
runDocker socket arguments = run "/usr/bin/docker" (dockerArguments socket arguments)

dockerArguments :: FilePath -> [String] -> [String]
dockerArguments socket arguments = ["--host", "unix://" ++ socket] ++ arguments

runWithInput
  :: FilePath -> [String] -> ByteString.ByteString -> IO (Either String (Int, String, String))
runWithInput program arguments input = do
  user <- getEffectiveUserID
  result <-
    captureSubprocessWithInputBounded
      limits {boundedSubprocessMaximumInputBytes = 8192}
      input
      ( Subprocess
          program
          arguments
          ( Just
              [ ("PATH", "/usr/bin:/bin")
              , ("HOME", "/nonexistent")
              , ("XDG_RUNTIME_DIR", "/run/user/" ++ show user)
              ]
          )
          Nothing
      )
  pure $ case result of
    Right output ->
      Right
        ( case processExitCode output of
            ExitSuccess -> 0
            ExitFailure code -> code
        , processStdout output
        , processStderr output
        )
    Left failure -> Left (show failure)

satisfied :: Bool -> ObservationResult
satisfied True = ObservationSatisfied
satisfied False = ObservationViolated

hex32 :: ByteString.ByteString -> String
hex32 = take 32 . ByteString8.unpack . hexSha256

digest :: String -> PublicEvidenceDigest
digest = hashPublicEvidence . Text.pack

data FreshPreparation = FreshPreparation
  { freshStarted :: !Word64
  , freshImageObservation :: !FreshImageInventory
  , freshRootWasAbsent :: !Bool
  , freshStagingCleaned :: !Bool
  , freshSourceIdentity :: !SourceIdentity
  , freshBinaryIdentity :: !PublicEvidenceDigest
  , freshBootIdentity :: !ByteString.ByteString
  }

data ImportAdverseEvidence = ImportAdverseEvidence
  { importAdverseClaims :: ![Bool]
  , importAdverseObservations :: ![Bool]
  , importAdverseCleanup :: !Bool
  }
  deriving (Eq, Show)

data ImportSnapshot = ImportSnapshot ![FilePath] !Integer !Integer
  deriving (Eq, Show)

-- Observe the retained generation, both exact artifact digests and the
-- import staging names independently of the import command's exit status.
observeImportSnapshot :: BootstrapProjection -> IO (Maybe ImportSnapshot)
observeImportSnapshot projection = case (bootstrapNodeArtifact projection, bootstrapKindTool projection) of
  (Just node, Just kind) -> do
    let scope = bootstrapScope projection
    generation <- observeScopeGeneration scope (Text.unpack (bootstrapRootGeneration projection))
    nodeState <-
      observeScopeArtifact scope (artifactPath node) (artifactDigest node) (artifactMaximumBytes node)
    kindState <-
      observeScopeArtifact scope (artifactPath kind) (artifactDigest kind) (artifactMaximumBytes kind)
    residue <- observeImportResidue projection
    pure $ case (generation, nodeState, kindState, residue) of
      ( Right ScopeGenerationMatches
        , Right (ScopeArtifactDigestMatches nodeSize)
        , Right (ScopeArtifactDigestMatches kindSize)
        , Just names
        ) ->
          if null names then Just (ImportSnapshot names nodeSize kindSize) else Nothing
      _ -> Nothing
  _ -> pure Nothing

observeImportResidue :: BootstrapProjection -> IO (Maybe [FilePath])
observeImportResidue projection = do
  checked <- withScopeRootDescriptor (bootstrapScope projection) $ \root sameRoot -> do
    attempted <- try $ bracket (Posix.openFdAt (Just root) ".prodbox-import" Posix.ReadOnly directoryFlags) Posix.closeFd $ \directory@(Fd raw) -> do
      owner <- getEffectiveUserID
      before <- getFdStatus directory
      names <- sort <$> listDirectory ("/proc/self/fd/" ++ show raw)
      after <- getFdStatus directory
      stable <- sameRoot
      pure $
        if isDirectory before
          && fileOwner before == owner
          && fileMode before .&. 0o022 == 0
          && deviceID before == deviceID after
          && fileID before == fileID after
          && modificationTimeHiRes before == modificationTimeHiRes after
          && statusChangeTimeHiRes before == statusChangeTimeHiRes after
          && stable
          then Just names
          else Nothing
    pure (either (const Nothing) id (attempted :: Either IOException (Maybe [FilePath])))
  pure (either (const Nothing) id checked)
 where
  directoryFlags =
    Posix.defaultFileFlags
      { Posix.directory = True
      , Posix.nofollow = True
      , Posix.cloexec = True
      , Posix.nonBlock = True
      }

-- The conflicting sibling keeps its generation record, but must not acquire
-- an operation record or another resource before admission is refused.
observeBareRetainedScope :: BootstrapProjection -> FilePath -> String -> IO Bool
observeBareRetainedScope projection expectedRoot expectedGeneration
  | scopeEnvironment scope /= Test
      || scopeRoot scope /= expectedRoot
      || Text.unpack (bootstrapRootGeneration projection) /= expectedGeneration =
      pure False
  | otherwise = do
      generationBefore <- observeScopeGeneration scope expectedGeneration
      observed <- withScopeRootDescriptor scope $ \root sameRoot -> do
        attempt <- try $ do
          before <- getFdStatus root
          let Fd raw = root
          names <- sort <$> listDirectory ("/proc/self/fd/" ++ show raw)
          owner <- getEffectiveUserID
          parentClean <-
            bracket
              (Posix.openFd (takeDirectory expectedRoot) Posix.ReadOnly flags)
              Posix.closeFd
              $ \parent@(Fd parentRaw) -> do
                parentBefore <- getFdStatus parent
                siblings <- sort <$> listDirectory ("/proc/self/fd/" ++ show parentRaw)
                parentAfter <- getFdStatus parent
                pure $
                  isDirectory parentBefore
                    && fileOwner parentBefore == owner
                    && fileMode parentBefore .&. 0o077 == 0
                    && siblings == [scopeIdentifier scope]
                    && deviceID parentBefore == deviceID parentAfter
                    && fileID parentBefore == fileID parentAfter
                    && modificationTimeHiRes parentBefore == modificationTimeHiRes parentAfter
                    && statusChangeTimeHiRes parentBefore == statusChangeTimeHiRes parentAfter
          after <- getFdStatus root
          stable <- sameRoot
          pure $
            names == ["scope-generation.json"]
              && parentClean
              && stable
              && deviceID before == deviceID after
              && fileID before == fileID after
              && modificationTimeHiRes before == modificationTimeHiRes after
              && statusChangeTimeHiRes before == statusChangeTimeHiRes after
        pure (either (const False) id (attempt :: Either IOException Bool))
      generationAfter <- observeScopeGeneration scope expectedGeneration
      pure $
        generationBefore == Right ScopeGenerationMatches
          && generationAfter == generationBefore
          && either (const False) id observed
 where
  scope = bootstrapScope projection
  flags = Posix.defaultFileFlags {Posix.directory = True, Posix.nofollow = True, Posix.cloexec = True}

fixtureBaseMatches :: [FilePath] -> Bool
fixtureBaseMatches entries =
  sort entries
    == sort ["a01-03-siblingproject", "a01-03-sibling", "a01-03-nameproject", "a01-03-name"]

runFreshImportAdverses
  :: FilePath -> BootstrapProjection -> IO (Either String ImportAdverseEvidence)
runFreshImportAdverses selected projection = do
  executable <- getExecutablePath
  runFreshImportAdversesWith executable selected projection

runFreshImportAdversesWith
  :: FilePath -> FilePath -> BootstrapProjection -> IO (Either String ImportAdverseEvidence)
runFreshImportAdversesWith executable selected projection = do
  source <- readSelectedDhall selected
  case source of
    Left failure -> pure (Left ("cannot read the selected bootstrap source: " ++ show failure))
    Right original -> do
      let generation = bootstrapRootGeneration projection
          alternate = Text.replicate 32 (if generation == Text.replicate 32 "f" then "e" else "f")
          foreignSource =
            Text.replace
              ("root_generation = \"" <> generation <> "\"")
              ("root_generation = \"" <> alternate <> "\"")
              original
      if foreignSource == original
        then pure (Left "cannot construct a distinct foreign-generation fixture")
        else do
          decoded <- decodeOptionalBootstrapSource selected foreignSource
          case decoded of
            Right (Just foreignProjection)
              | bootstrapScope foreignProjection == bootstrapScope projection
                  && bootstrapRootGeneration foreignProjection == alternate ->
                  exercise foreignSource
            _ -> pure (Left "foreign-generation fixture did not decode to the intended scope")
 where
  exercise foreignSource = do
    outcome <- prepareAdverseImportSources projection (TextEncoding.encodeUtf8 foreignSource) $ \altered missing foreignPath -> do
      before <- observeImportSnapshot projection
      let sourcePath = case bootstrapNodeArtifact projection of
            Just artifact -> scopeRoot (bootstrapScope projection) </> artifactPath artifact
            Nothing -> ""
          importWith config path = run executable ["--config", config, "control", "import-artifact", "node-archive", path]
          claimed expected result = case result of
            Right (code, out, err) -> code /= 0 && expected `isInfixOf` (out ++ err)
            _ -> False
      alteredResult <- importWith selected altered
      afterAltered <- observeImportSnapshot projection
      missingResult <- importWith selected missing
      afterMissing <- observeImportSnapshot projection
      foreignResult <- importWith foreignPath sourcePath
      afterForeign <- observeImportSnapshot projection
      pure
        (
          [ claimed "ArtifactSourceMismatch" alteredResult
          , claimed "ArtifactSourceUnsafe" missingResult
          , claimed "ArtifactImportRefused" foreignResult
          ]
        ,
          [ before /= Nothing && before == afterAltered
          , before /= Nothing && before == afterMissing
          , before /= Nothing && before == afterForeign
          ]
        )
    pure $ case outcome of
      PreparationResult (Right (claims, observations)) True _ -> Right (ImportAdverseEvidence claims observations True)
      PreparationResult primary cleaned retained ->
        Left
          ( "adverse import fixtures unconfirmed; primary: "
              ++ show primary
              ++ "; cleanup: "
              ++ show cleaned
              ++ "; staging path: "
              ++ show retained
          )

-- | The default workflow allocates a new test identity, stages the pinned
-- archive, then uses the public fresh-test setup and import handlers. Failed
-- enrollment or import retains the exact selected root for observation.
runFreshPhase01Scenario :: FilePath -> IO ExitCode
runFreshPhase01Scenario repository = do
  anchorResult <- try (canonicalizePath repository) :: IO (Either IOException FilePath)
  entropyResult <-
    try (withBinaryFile "/dev/urandom" ReadMode (\handle -> ByteString.hGet handle 32))
      :: IO (Either IOException ByteString.ByteString)
  case (anchorResult, entropyResult) of
    (Right anchor, Right entropy) | ByteString.length entropy == 32 -> do
      executable <- getExecutablePath
      source <- captureSourceIdentity anchor []
      binary <- try (ByteString.readFile executable) :: IO (Either IOException ByteString.ByteString)
      boot <-
        try (ByteString.readFile "/proc/sys/kernel/random/boot_id")
          :: IO (Either IOException ByteString.ByteString)
      case (source, binary, validateBootIdentity (either (const Nothing) Just boot)) of
        (Right sourceIdentity, Right binaryBytes, Just bootIdentity) ->
          start
            anchor
            entropy
            sourceIdentity
            (digest (ByteString8.unpack (hexSha256 binaryBytes)))
            bootIdentity
        _ -> failFresh "source, binary or boot identity was unavailable"
    _ -> failFresh "cannot establish the repository anchor or a fresh random identity"
 where
  failFresh message = writeOutputLine ("phase-01 fresh preparation refused: " ++ message) >> pure (ExitFailure 2)
  start anchor entropy sourceIdentity binaryIdentity bootIdentity = do
    let identifier = "run-" ++ hex32 (ByteString.take 16 entropy)
        generation = hex32 (ByteString.drop 16 entropy)
        seed = ByteString.foldl' (\acc value -> acc * 33 + fromIntegral value) (0 :: Integer) entropy
        apiPort = 40000 + fromInteger (seed `mod` 20000)
        httpPort = 20000 + fromInteger ((seed `div` 20000) `mod` 10000) :: Int
        httpsPort = 30000 + fromInteger ((seed `div` 200000000) `mod` 10000) :: Int
    case deploymentScope anchor Test identifier apiPort of
      Left failure -> failFresh ("invalid generated test scope: " ++ show failure)
      Right scope -> do
        started <- getMonotonicTimeNSec
        executable <- getExecutablePath
        let selected = scopeRoot scope </> "config" </> "prodbox.dhall"
            setup archiveDigest archiveSize =
              ByteString8.pack $
                unlines
                  [ anchor
                  , "/run/docker.sock"
                  , "test"
                  , identifier
                  , generation
                  , show apiPort
                  , pinnedNodeImage
                  , show httpPort
                  , "30080"
                  , show httpsPort
                  , "30443"
                  , "127.0.0.1"
                  , "artifacts/node.tar"
                  , Text.unpack archiveDigest
                  , show archiveSize
                  , "artifacts/kind"
                  , "sha256:50030de23cf40a18505f20426f6a8506bedf13c6e509244bd1fa9463721b0f54"
                  , "104857600"
                  ]
            publish source archiveDigest archiveSize = do
              configured <-
                runWithInput
                  executable
                  ["--config", selected, "config", "setup", "--fresh-test"]
                  (setup archiveDigest archiveSize)
              case configured of
                Right (0, _, _) -> do
                  imported <-
                    run executable ["--config", selected, "control", "import-artifact", "node-archive", source]
                  pure $ case imported of
                    Right (0, _, _) -> Right selected
                    other -> Left ("node import did not complete: " ++ show other)
                other -> pure (Left ("fresh setup did not complete: " ++ show other))
        rootBefore <- observeScopeRoot scope
        inventory <- runDocker "/run/docker.sock" ["image", "ls", "-a", "--no-trunc", "--format", "{{.ID}}"]
        case (rootBefore, observeFreshImageInventory inventory) of
          (Right ScopeRootAbsent, FreshImageUnobservable) -> failFresh "the explicit daemon image inventory is unobservable"
          (Right ScopeRootAbsent, observed) -> do
            case observed of
              FreshImagePresent ->
                writeOutputLine
                  "The pinned image was already present; the clean-image acceptance case remains unproven."
              _ -> pure ()
            writeOutputLine ("phase-01 test identity: " ++ identifier ++ "; selected config: " ++ selected)
            outcome <- prepareFreshNodeArchive scope publish
            case outcome of
              PreparationResult (Right (Right configured)) True _ -> do
                result <-
                  runPhase01ScenarioWithFresh
                    configured
                    (Just (FreshPreparation started observed True True sourceIdentity binaryIdentity bootIdentity))
                case result of
                  ExitSuccess -> pure ExitSuccess
                  _ ->
                    writeOutputLine ("phase-01 test root retained for observation: " ++ scopeRoot scope) >> pure result
              PreparationResult primary cleaned retained ->
                failFresh
                  ( "test root path: "
                      ++ scopeRoot scope
                      ++ "; primary: "
                      ++ show primary
                      ++ "; staging cleanup confirmed: "
                      ++ show cleaned
                      ++ "; staging path: "
                      ++ show retained
                  )
          _ -> failFresh "the generated test root is present or unobservable"

data FreshImageInventory = FreshImageAbsent | FreshImagePresent | FreshImageUnobservable
  deriving (Eq, Show)

-- This is a point-in-time observation, not authority or a later guarantee.
observeFreshImageInventory :: Either String (Int, String, String) -> FreshImageInventory
observeFreshImageInventory result = case result of
  Right (0, output, _) ->
    let identifiers = words output
     in if not (all validIdentifier identifiers)
          then FreshImageUnobservable
          else if pinnedConfig `elem` identifiers then FreshImagePresent else FreshImageAbsent
  _ -> FreshImageUnobservable
 where
  pinnedConfig = "sha256:152b34afd8a2de5c8348a264426bc99b71058ee0e1a15eab9b30849605e4752d"
  validIdentifier value = case splitAt 7 value of
    ("sha256:", suffix) -> length suffix == 64 && all (\c -> isDigit c && c <= '9' || isAsciiLower c && c <= 'f') suffix
    _ -> False

validNetworkIdentifier :: String -> Bool
validNetworkIdentifier value = length value == 64 && all (\c -> isDigit c && c <= '9' || isAsciiLower c && c <= 'f') value

fixtureNetworkId :: Either String (Int, String, String) -> Maybe String
fixtureNetworkId result = case result of
  Right (0, output, _) -> case words output of
    [identifier] | validNetworkIdentifier identifier -> Just identifier
    _ -> Nothing
  _ -> Nothing

fixtureNetworkUntouched
  :: String -> Either String (Int, String, String) -> Either String (Int, String, String) -> Bool
fixtureNetworkUntouched identifier before after = case (before, after) of
  (Right (0, original, _), Right (0, current, _)) ->
    validNetworkIdentifier identifier
      && original == current
      && case words original of
        [observed, _, labels, "0"] -> observed == identifier && "\"owner\":\"foreign-a01-03\"" `isInfixOf` labels
        _ -> False
  _ -> False

-- | Run the lifecycle scenario for the identity the explicit config selects.
-- The identity must already have a retained root and declared artifacts.
-- An absent node archive can be acquired into temporary test-scoped staging
-- and passed through the public artifact importer before reconciliation.
runPhase01Scenario :: FilePath -> IO ExitCode
runPhase01Scenario selected = runPhase01ScenarioWithFresh selected Nothing

runPhase01ScenarioWithFresh :: FilePath -> Maybe FreshPreparation -> IO ExitCode
runPhase01ScenarioWithFresh selected fresh = do
  loaded <- readBootstrapProjection selected
  case loaded of
    Left failure -> refuse ("cannot read the selected config: " ++ show failure)
    Right projection
      | scopeEnvironment (bootstrapScope projection) /= Test ->
          refuse "the scenario runner accepts only a test identity"
      | otherwise -> do
          kind <- prepareKind selected projection
          prepared <- case kind of
            Left failure -> pure (Left failure)
            Right () -> prepareNode selected projection
          case prepared of
            Left failure -> do
              case kind of
                Right () ->
                  writeOutputLine
                    "The selected kind artifact was confirmed before node preparation; observe it before retrying."
                Left _ -> pure ()
              refuse failure
            Right () -> case fresh of
              Nothing -> do
                result <- either id id <$> (try (scenario selected projection Nothing) :: IO (Either ExitCode ExitCode))
                case result of
                  ExitSuccess -> do
                    writeOutputLine
                      "Prior Phase 1 scenario cases passed; automatic-preparation acceptance requires a fresh default run."
                    pure (ExitFailure 1)
                  _ -> pure result
              Just preparation -> do
                adverse <- runFreshImportAdverses selected projection
                case adverse of
                  Left failure -> refuse failure
                  Right observations
                    | length (importAdverseClaims observations) == 3
                        && length (importAdverseObservations observations) == 3
                        && and (importAdverseClaims observations)
                        && and (importAdverseObservations observations)
                        && importAdverseCleanup observations ->
                        either id id <$> (try (scenario selected projection (Just (preparation, observations))) :: IO (Either ExitCode ExitCode))
                    | otherwise ->
                        refuse
                          ( "adverse import controls were not confirmed: "
                              ++ show
                                ( importAdverseClaims observations
                                , importAdverseObservations observations
                                , importAdverseCleanup observations
                                )
                          )
 where
  refuse message = writeOutputLine ("phase-01 scenario refused: " ++ message) >> pure (ExitFailure 2)

prepareKind :: FilePath -> BootstrapProjection -> IO (Either String ())
prepareKind selected projection = case bootstrapKindTool projection of
  Nothing -> pure (Left "the selected test identity declares no kind executable")
  Just artifact -> do
    let scope = bootstrapScope projection
    observation <-
      observeScopeArtifact
        scope
        (artifactPath artifact)
        (artifactDigest artifact)
        (artifactMaximumBytes artifact)
    case observation of
      Right (ScopeArtifactDigestMatches _) -> pure (Right ())
      Right ScopeArtifactMissing -> do
        executable <- getExecutablePath
        outcome <- preparePinnedKindArtifact projection $ \source -> do
          current <- readBootstrapProjection selected
          if current /= Right projection
            then pure (Left "selected configuration changed during kind preparation")
            else do
              imported <- run executable ["--config", selected, "control", "import-artifact", "kind-tool", source]
              pure $ case imported of
                Right (0, _, _) -> Right ()
                Right (code, out, err) -> Left ("public kind import exited " ++ show code ++ ": " ++ out ++ err)
                Left failure -> Left ("public kind import was unobservable: " ++ failure)
        case outcome of
          PreparationResult (Right (Right ())) True _ -> do
            current <- readBootstrapProjection selected
            after <-
              observeScopeArtifact
                scope
                (artifactPath artifact)
                (artifactDigest artifact)
                (artifactMaximumBytes artifact)
            pure $ case (current, after) of
              (Right actual, Right (ScopeArtifactDigestMatches _)) | actual == projection -> Right ()
              _ -> Left "kind import or selected configuration could not be independently confirmed"
          PreparationResult primary True _ -> pure (either (Left . show) id primary)
          PreparationResult primary False retained ->
            pure
              ( Left
                  ( "kind staging cleanup was not confirmed; staging path: "
                      ++ show retained
                      ++ "; primary result: "
                      ++ show primary
                  )
              )
      _ -> pure (Left ("kind executable observation refused: " ++ show observation))

prepareNode :: FilePath -> BootstrapProjection -> IO (Either String ())
prepareNode selected projection = case bootstrapNodeArtifact projection of
  Nothing -> pure (Left "the selected test identity declares no node archive")
  Just artifact -> do
    let scope = bootstrapScope projection
    observation <-
      observeScopeArtifact
        scope
        (artifactPath artifact)
        (artifactDigest artifact)
        (artifactMaximumBytes artifact)
    case observation of
      Right (ScopeArtifactDigestMatches _) -> pure (Right ())
      Right ScopeArtifactMissing -> do
        executable <- getExecutablePath
        outcome <- prepareRegistryNodeArchive projection (kindPlanNodeImage (bootstrapKindPlan projection)) $ \source -> do
          current <- readBootstrapProjection selected
          if current /= Right projection
            then pure (Left "selected configuration changed during node preparation")
            else do
              imported <-
                run executable ["--config", selected, "control", "import-artifact", "node-archive", source]
              pure $ case imported of
                Right (0, _, _) -> Right ()
                Right (code, out, err) -> Left ("public node archive import exited " ++ show code ++ ": " ++ out ++ err)
                Left failure -> Left ("public node archive import was unobservable: " ++ failure)
        case outcome of
          PreparationResult (Right (Right ())) True _ -> do
            current <- readBootstrapProjection selected
            after <-
              observeScopeArtifact
                scope
                (artifactPath artifact)
                (artifactDigest artifact)
                (artifactMaximumBytes artifact)
            pure $ case (current, after) of
              (Right actual, Right (ScopeArtifactDigestMatches _)) | actual == projection -> Right ()
              _ -> Left "node archive import or selected configuration could not be independently confirmed"
          PreparationResult primary True _ -> pure (either (Left . show) id primary)
          PreparationResult primary False retained ->
            pure
              ( Left
                  ( "node archive staging cleanup was not confirmed; staging path: "
                      ++ show retained
                      ++ "; primary result: "
                      ++ show primary
                  )
              )
      _ -> pure (Left ("node archive observation refused: " ++ show observation))

-- One pass, two lifecycles on the same retained root, three reports:
-- case 1 the lifecycle (scope, readiness, cleanup, retained host data),
-- case 4 the NetworkPolicy enforcement observation, case 2 recreation after the
-- node's removal with a random marker written by a real Pod surviving.
scenario
  :: FilePath -> BootstrapProjection -> Maybe (FreshPreparation, ImportAdverseEvidence) -> IO ExitCode
scenario selected projection fresh = do
  let scope = bootstrapScope projection
      socket = bootstrapRuntimeSocket projection
      cluster = scopeKindName scope
      root = scopeRoot scope
      project = takeDirectory (takeDirectory root)
      kubeconfig = root </> "control" </> "kubeconfig"
      generation = Text.unpack (bootstrapRootGeneration projection)
      nodeArchive = bootstrapNodeArtifact projection
      toolArtifact = bootstrapKindTool projection
  executable <- getExecutablePath
  binaryBytes <- ByteString.readFile executable
  boot <-
    try (ByteString.readFile "/proc/sys/kernel/random/boot_id")
      :: IO (Either IOException ByteString.ByteString)
  sourceResult <- captureSourceIdentity project []
  randomResult <- readRandomBytes
  started <- getMonotonicTimeNSec
  case (sourceResult, randomResult, validateBootIdentity (either (const Nothing) Just boot)) of
    (Left failure, _, _) -> writeOutputLine ("source identity refused: " ++ show failure) >> pure (ExitFailure 2)
    (_, Left failure, _) -> writeOutputLine ("scenario entropy refused: " ++ failure) >> pure (ExitFailure 2)
    (_, _, Nothing) -> writeOutputLine "scenario boot identity was unavailable or invalid" >> pure (ExitFailure 2)
    (Right source, Right randomBytes, Just bootId) -> do
      let second = 1000000000
          budget = ScenarioBudget (started + 1500 * second) (started + 2400 * second) (1024 * 1048576) 1800000000 0
          artifacts =
            [ ("kind.tool", digest (maybe "" artifactDigest toolArtifact))
            , ("node.archive", digest (maybe "" artifactDigest nodeArchive))
            ]
          bindingFor :: Word16 -> String -> ScenarioBinding
          bindingFor caseNumber label =
            ScenarioBinding
              1
              caseNumber
              scope
              generation
              (hex32 (randomBytes <> "run"))
              (hex32 (randomBytes <> "operation" <> ByteString8.pack label))
              (hex32 bootId)
              source
              (digest (ByteString8.unpack (hexSha256 binaryBytes)))
              artifacts
              (digest (show (renderKindConfig (bootstrapKindPlan projection))))
              (digest ("control reconcile; delete; reconcile; delete; case " ++ label))
              budget
          alternateGeneration = replicate 32 (if generation == replicate 32 'f' then 'e' else 'f')
          public args = run executable (["--config", selected] ++ args)
          public' config args = run executable (["--config", config] ++ args)
          textOf result = either (const "") (\(_, out, err) -> out ++ err) result
          markerFile = root </> "a01-02-marker"
          fixtureBase = project </> ".build" </> ("phase01-fixtures-" ++ hex32 randomBytes)
      createDirectoryIfMissing False (project </> ".build")
      createDirectory fixtureBase
      setFileMode fixtureBase 0o700
      fixtureBaseIdentity <- getSymbolicLinkStatus fixtureBase
      writeOutputLine ("Phase 1 fixture and recovery directory: " ++ fixtureBase)
      fixtureSnapshots <- newIORef []
      fixtureConfigs <- newIORef []
      let remember bucket path = do
            snapshot <- captureFixtureTree path
            modifyIORef' bucket ((path, snapshot) :)
          rememberFixture = remember fixtureSnapshots
          rememberConfig = remember fixtureConfigs
      -- First lifecycle.
      stopMonitor <- newIORef False
      (reconcile1, slicePeak) <-
        Async.concurrently
          (public ["control", "reconcile"] <* writeIORef stopMonitor True)
          (sliceMonitor stopMonitor)
      status1 <- public ["control", "status"]
      ready1 <- independentClusterReady socket root cluster
      firstNode <- containerId socket (cluster ++ "-control-plane")
      let firstSucceeded = case reconcile1 of Right (0, _, _) -> True; _ -> False
      when (not firstSucceeded || not ready1 || firstNode == Nothing) $ do
        cleanup <- public ["control", "delete", "--yes"]
        snapshot <- captureFixtureTree fixtureBase
        cleaned <- maybe (pure False) cleanupFixtureTree snapshot
        writeOutputLine ("Phase 1 stopped after the initial reconcile; primary: " ++ take 4096 (show reconcile1)
          ++ "; independent readiness: " ++ show ready1 ++ "; node identity observed: " ++ show (firstNode /= Nothing)
          ++ "; cleanup: " ++ take 4096 (show cleanup) ++ "; empty fixture directory removed: " ++ show cleaned
          ++ "; test root retained: " ++ root)
        throwIO (ExitFailure 1)
      -- Case 3 (ambient kubeconfig): a decoy API endpoint whose connections an
      -- outer listener counts; the public status runs with KUBECONFIG naming it.
      let decoyDir = fixtureBase </> "a01-03-decoy"
          decoyPort =
            40000
              + fromIntegral
                (ByteString.foldl' (\acc byte -> acc * 31 + fromIntegral byte) (7 :: Int) randomBytes `mod` 20000)
              :: Int
          decoyConfig = decoyDir </> "kubeconfig"
          listenerScript =
            unlines
              [ "import os, socket, sys, time"
              , "os.umask(0o077)"
              , "d, port = sys.argv[1], int(sys.argv[2])"
              , "s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)"
              , "s.bind(('127.0.0.1', port)); s.listen(8); s.settimeout(1)"
              , "open(d + '/ready', 'w').write('1')"
              , "n = 0"
              , "deadline = time.time() + 900"
              , "while time.time() < deadline and not os.path.exists(d + '/stop'):"
              , "    try:"
              , "        c, _ = s.accept(); n += 1; c.close(); open(d + '/accepted', 'w').write(str(n))"
              , "    except socket.timeout:"
              , "        pass"
              , "open(d + '/exited', 'w').write('1')"
              ]
          decoyYaml =
            unlines
              [ "apiVersion: v1"
              , "kind: Config"
              , "clusters: [{name: decoy, cluster: {server: 'https://127.0.0.1:"
                  ++ show decoyPort
                  ++ "', insecure-skip-tls-verify: true}}]"
              , "users: [{name: decoy, user: {token: decoy-token-not-a-secret}}]"
              , "contexts: [{name: decoy, context: {cluster: decoy, user: decoy}}]"
              , "current-context: decoy"
              ]
      createDirectoryIfMissing False decoyDir
      setFileMode decoyDir 0o700
      writeFile (decoyDir </> "listener.py") listenerScript
      writeFile decoyConfig decoyYaml
      setFileMode (decoyDir </> "listener.py") 0o600
      setFileMode decoyConfig 0o600
      decoyBefore <- ByteString.readFile decoyConfig
      (decoyReady, ambient, decoyConnected, decoyAfter, listenerGone) <-
        Async.withAsync
          (run "/usr/bin/python3" ["-I", decoyDir </> "listener.py", decoyDir, show decoyPort])
          $ \listener -> do
            _ <- waitFor (doesFileExist (decoyDir </> "ready")) 20
            ready <- doesFileExist (decoyDir </> "ready")
            observed <-
              run
                "/usr/bin/env"
                ["KUBECONFIG=" ++ decoyConfig, executable, "--config", selected, "control", "status"]
            connected <- doesFileExist (decoyDir </> "accepted")
            after <- ByteString.readFile decoyConfig
            writeFile (decoyDir </> "stop") "1"
            setFileMode (decoyDir </> "stop") 0o600
            settled <- timeout 30000000 (Async.wait listener)
            exited <- doesFileExist (decoyDir </> "exited")
            let gone =
                  exited && case settled of
                    Just (Right (0, _, _)) -> True
                    _ -> False
            pure (ready, observed, connected, after, gone)
      decoyNames <- try (sort <$> listDirectory decoyDir) :: IO (Either IOException [FilePath])
      let expectedDecoy = sort (["listener.py", "kubeconfig", "ready", "stop", "exited"] ++ ["accepted" | decoyConnected])
      decoySnapshot <-
        if listenerGone && decoyNames == Right expectedDecoy
          then captureFixtureTree decoyDir
          else pure Nothing
      decoyCleanup <- maybe (pure False) cleanupFixtureTree decoySnapshot
      -- Case 4 independent observation: the same real-socket observation, run
      -- again in a different namespace by the runner, not read from reconcile.
      networkIntent <- observeKindIntent projection
      networkAgain <- case networkIntent of
        KindIntentMatches operation ->
          observeNetworkEnforcementScoped projection operation ("prodbox-netrun-" ++ take 8 (hex32 randomBytes))
        _ -> pure (EnforcementOutcome Nothing (Just "kind operation identity unavailable") EnforcementCleanupNotStarted)
      networkFinished <- getMonotonicTimeNSec
      -- Case 2: a real Pod writes a random marker into the host root.
      let marker = hex32 ("marker" <> randomBytes)
      written <-
        podOnHostRoot
          kubeconfig
          "marker-writer"
          ("echo -n " ++ marker ++ " > /h/a01-02-marker && echo WROTE")
      -- The volume directory is created by the operator, not by the kubelet,
      -- so it stays removable without elevation.
      createDirectoryIfMissing False (root </> "pv-a01-02")
      pvWritten <-
        pvPod kubeconfig "pv-writer" ("echo -n " ++ marker ++ "pv > /d/pv-marker && echo WROTE")
      quota <- quotaProbe kubeconfig ("prodbox-quota-" ++ take 8 (hex32 randomBytes))
      withinLimit <-
        limitedPod
          kubeconfig
          "limit-ok"
          "64Mi"
          "a=0123456789abcdef; for ((i=0;i<18;i++)); do a=$a$a; done; echo ${#a}"
      overLimit <-
        limitedPod
          kubeconfig
          "limit-over"
          "16Mi"
          "a=0123456789abcdef; for ((i=0;i<23;i++)); do a=$a$a; done; echo ${#a}"
      hostBefore <- try (readFile markerFile) :: IO (Either IOException String)
      pvHostBeforeValue <-
        try (readFile (root </> "pv-a01-02" </> "pv-marker")) :: IO (Either IOException String)
      writeFinished <- getMonotonicTimeNSec
      -- Sibling scope on the same host ports while the first cluster is Ready.
      siblingSelected <- Text.unpack <$> Text.readFile selected
      let siblingAnchor = fixtureBase </> "a01-03-siblingproject"
          siblingId = "a0103sibling"
          siblingDirectory = fixtureBase </> "a01-03-sibling"
          siblingText =
            Text.unpack
              $ Text.replace
                (Text.pack ("deployment_id = \"" ++ takeFileName root ++ "\""))
                (Text.pack ("deployment_id = \"" ++ siblingId ++ "\""))
              $ Text.replace
                (Text.pack ("project_anchor = \"" ++ project ++ "\""))
                (Text.pack ("project_anchor = \"" ++ siblingAnchor ++ "\""))
                (Text.pack siblingSelected)
      createDirectoryIfMissing False siblingAnchor
      setFileMode siblingAnchor 0o700
      createDirectoryIfMissing False siblingDirectory
      setFileMode siblingDirectory 0o700
      Text.writeFile (siblingDirectory </> "selected.dhall") (Text.pack siblingText)
      setFileMode (siblingDirectory </> "selected.dhall") 0o600
      siblingRun <-
        run executable ["--config", siblingDirectory </> "selected.dhall", "control", "reconcile"]
      siblingProjection <- readBootstrapProjection (siblingDirectory </> "selected.dhall")
      siblingBare <-
        either
          (const (pure False))
          (\p -> observeBareRetainedScope p (siblingAnchor </> ".test-data" </> siblingId) generation)
          siblingProjection
      siblingConfigAfter <-
        try (Text.readFile (siblingDirectory </> "selected.dhall")) :: IO (Either IOException Text)
      siblingContainers <- runDocker socket ["ps", "-a", "-q", "--filter", "name=" ++ siblingId]
      siblingNetworks <- runDocker socket ["network", "ls", "-q", "--filter", "name=" ++ siblingId]
      siblingVolumes <- runDocker socket ["volume", "ls", "-q", "--filter", "name=" ++ siblingId]
      siblingStillReady <- independentClusterReady socket root cluster
      let siblingClean = case (siblingContainers, siblingNetworks, siblingVolumes) of
            (Right (0, a, _), Right (0, b, _), Right (0, d, _)) -> null (words (a ++ b ++ d))
            _ -> False
          siblingExit = either (const 0) (\(code, _, _) -> code) siblingRun
          siblingText' = either (const "") (\(_, out, err) -> out ++ err) siblingRun
          siblingRefused = siblingExit /= 0 && "already listening" `isInfixOf` siblingText'
      -- Sibling scope with the SAME deployment identity (so the same kind
      -- cluster name) in another project on different ports, while the first
      -- cluster is Ready: nothing of that name may be created or touched.
      let nameAnchor = fixtureBase </> "a01-03-nameproject"
          nameDirectory = fixtureBase </> "a01-03-name"
          shifted = case kindPlanHostPorts (bootstrapKindPlan projection) of
            [api, http, https] ->
              Text.replace (Text.pack ("api_port = " ++ show api)) (Text.pack ("api_port = " ++ show (api + 100)))
                . Text.replace
                  (Text.pack ("http_host_port = " ++ show http))
                  (Text.pack ("http_host_port = " ++ show (http + 100)))
                . Text.replace
                  (Text.pack ("https_host_port = " ++ show https))
                  (Text.pack ("https_host_port = " ++ show (https + 100)))
            _ -> id
          nameText =
            Text.unpack . shifted $
              Text.replace
                (Text.pack ("project_anchor = \"" ++ project ++ "\""))
                (Text.pack ("project_anchor = \"" ++ nameAnchor ++ "\""))
                (Text.pack siblingSelected)
      createDirectoryIfMissing False nameAnchor
      setFileMode nameAnchor 0o700
      createDirectoryIfMissing False nameDirectory
      setFileMode nameDirectory 0o700
      Text.writeFile (nameDirectory </> "selected.dhall") (Text.pack nameText)
      setFileMode (nameDirectory </> "selected.dhall") 0o600
      imagesBeforeName <- runDocker socket ["image", "ls", "-a", "-q", "--no-trunc"]
      nameRun <- run executable ["--config", nameDirectory </> "selected.dhall", "control", "reconcile"]
      imagesAfterName <- runDocker socket ["image", "ls", "-a", "-q", "--no-trunc"]
      nameProjection <- readBootstrapProjection (nameDirectory </> "selected.dhall")
      nameRootBare <-
        either
          (const (pure False))
          (\p -> observeBareRetainedScope p (nameAnchor </> ".test-data" </> takeFileName root) generation)
          nameProjection
      nameConfigAfter <-
        try (Text.readFile (nameDirectory </> "selected.dhall")) :: IO (Either IOException Text)
      nameStillReady <- independentClusterReady socket root cluster
      -- The public command may have created a retained scope generation in
      -- this anchor. Keep its selected config and scope together for recovery.
      let nameExit = either (const 0) (\(code, _, _) -> code) nameRun
          nameOutput = either (const "") (\(_, out, err) -> out ++ err) nameRun
          nameRefused = nameExit /= 0 && "already exist" `isInfixOf` nameOutput
          nameUntouched = case (imagesBeforeName, imagesAfterName) of
            (Right (0, before, _), Right (0, after, _)) -> sort (words before) == sort (words after)
            _ -> False
      delete1 <- public ["control", "delete", "--yes"]
      absent1 <- independentAbsence socket cluster
      retained1 <- independentHostData root generation nodeArchive
      cleanup1 <- getMonotonicTimeNSec
      -- Recreation on the same root and generation.
      reconcile2 <- public ["control", "reconcile"]
      secondNode <- containerId socket (cluster ++ "-control-plane")
      read2 <- podOnHostRoot kubeconfig "marker-reader" "read -r x < /h/a01-02-marker; echo \"MARKER=$x\""
      pvRead <- pvPod kubeconfig "pv-reader" "read -r x < /d/pv-marker; echo MARKER=$x"
      pvHostBefore <- pure pvHostBeforeValue
      pvHostAfter <-
        try (readFile (root </> "pv-a01-02" </> "pv-marker")) :: IO (Either IOException String)
      hostAfter <- try (readFile markerFile) :: IO (Either IOException String)
      histories <- try (listDirectory (root </> "history")) :: IO (Either IOException [FilePath])
      ready2 <- independentClusterReady socket root cluster
      recreated <- getMonotonicTimeNSec
      delete2 <- public ["control", "delete", "--yes"]
      absent2 <- independentAbsence socket cluster
      retained2 <- independentHostData root generation nodeArchive
      cleanup2 <- getMonotonicTimeNSec
      -- Case 3: a foreign network already holds the cluster's network name.
      let foreignName = cluster
          inspectForeign identifier =
            runDocker
              socket
              [ "network"
              , "inspect"
              , "--format"
              , "{{.Id}} {{.Created}} {{json .Labels}} {{len .Containers}}"
              , identifier
              ]
      foreignMade <-
        runDocker socket ["network", "create", "--label", "owner=foreign-a01-03", foreignName]
      let createdNetwork = fixtureNetworkId foreignMade
      foreignBefore <- maybe (pure (Left "fixture network was not created")) inspectForeign createdNetwork
      adverse <- case createdNetwork of
        Just identifier | fixtureNetworkUntouched identifier foreignBefore foreignBefore -> public ["control", "reconcile"]
        _ -> pure (Left "fixture network identity was not confirmed")
      foreignAfter <- maybe (pure (Left "fixture network was not created")) inspectForeign createdNetwork
      adverseNamedNodes <-
        runDocker socket ["ps", "-a", "-q", "--filter", "name=^/" ++ cluster ++ "-control-plane$"]
      adverseLabeledNodes <-
        runDocker socket ["ps", "-a", "-q", "--filter", "label=io.x-k8s.kind.cluster=" ++ cluster]
      let noAdverseNode = case (adverseNamedNodes, adverseLabeledNodes) of
            (Right (0, named, _), Right (0, labeled, _)) -> null (words named) && null (words labeled)
            _ -> False
          adverseRefused = case adverse of
            Right (code, out, err) -> code /= 0 && not (null (out ++ err))
            _ -> False
      -- Only the exact ID created by this test is eligible for cleanup.
      foreignRemoved <- case createdNetwork of
        Just identifier | fixtureNetworkUntouched identifier foreignBefore foreignAfter -> do
          removed <- runDocker socket ["network", "rm", identifier]
          inventory <- runDocker socket ["network", "ls", "--no-trunc", "--format", "{{.ID}}"]
          pure $ case (removed, inventory) of
            (Right (0, _, _), Right (0, output, _))
              | all validNetworkIdentifier (words output) && identifier `notElem` words output -> removed
            _ -> Left "fixture network removal or absence was not confirmed"
        _ -> pure (Left "fixture network ownership or unchanged state was not confirmed")
      case foreignRemoved of
        Right (0, _, _) -> pure ()
        _ -> do
          writeOutputLine
            ( "fixture network cleanup unconfirmed; name: "
                ++ foreignName
                ++ "; created ID: "
                ++ show createdNetwork
                ++ "; primary: "
                ++ take 600 (show adverse)
                ++ "; cleanup: "
                ++ take 600 (show foreignRemoved)
                ++ "; retained test root: "
                ++ root
            )
          exitWith (ExitFailure 1)
      unless (adverseRefused && noAdverseNode) $ do
        recovery <- public ["control", "delete", "--yes"]
        observed <- independentAbsence socket cluster
        writeOutputLine
          ( "foreign-network adverse control was unconfirmed; primary: "
              ++ take 600 (show adverse)
              ++ "; exact-scope recovery: "
              ++ take 600 (show recovery)
              ++ "; independent absence observed: "
              ++ show observed
              ++ "; retained test root: "
              ++ root
          )
        exitWith (ExitFailure 1)
      -- Symlinked, foreign and wrong-generation roots, each driven by a
      -- config derived from the selected one; every victim is compared by
      -- content before and after, and no Docker resource may appear.
      selectedText <- Text.unpack <$> Text.readFile selected
      let adverseBase = fixtureBase
          replaceText old new text = Text.unpack (Text.replace (Text.pack old) (Text.pack new) (Text.pack text))
          configFor anchor deployment generationValue =
            replaceText
              ("root_generation = \"" ++ generation ++ "\"")
              ("root_generation = \"" ++ generationValue ++ "\"")
              $ replaceText
                ("deployment_id = \"" ++ takeFileName root ++ "\"")
                ("deployment_id = \"" ++ deployment ++ "\"")
              $ replaceText
                ("project_anchor = \"" ++ project ++ "\"")
                ("project_anchor = \"" ++ anchor ++ "\"")
                selectedText
          writeConfig name anchor deployment generationValue = do
            let directory = adverseBase </> ("a01-03-" ++ name)
            createDirectoryIfMissing False directory
            setFileMode directory 0o700
            let path = directory </> "selected.dhall"
            writeFile path (configFor anchor deployment generationValue)
            setFileMode path 0o600
            rememberConfig directory
            pure path
          snapshotTree directory = do
            entries <- try (listDirectory directory) :: IO (Either IOException [FilePath])
            case entries of
              Left _ -> pure Nothing
              Right names -> do
                contents <-
                  mapM
                    (\entry -> (,) entry <$> (try (readFile (directory </> entry)) :: IO (Either IOException String)))
                    (sort names)
                pure (Just (map (Bifunctor.second (either (const "<unreadable>") id)) contents))
          noResource deployment = do
            c <- runDocker socket ["ps", "-a", "-q", "--filter", "name=" ++ deployment]
            n <- runDocker socket ["network", "ls", "-q", "--filter", "name=" ++ deployment]
            v <- runDocker socket ["volume", "ls", "-q", "--filter", "name=" ++ deployment]
            pure
              ( case (c, n, v) of
                  (Right (0, a, _), Right (0, b, _), Right (0, d, _)) -> null (words (a ++ b ++ d))
                  _ -> False
              )
          refused result = either (const False) (\(code, out, err) -> code /= 0 && not (null (out ++ err))) result
      -- symlinked root
      let linkAnchor = adverseBase </> "a01-03-linkproject"
          linkVictim = adverseBase </> "a01-03-linkvictim"
          linkId = "a0103link"
      createDirectoryIfMissing False linkAnchor
      setFileMode linkAnchor 0o700
      createDirectoryIfMissing False (linkAnchor </> ".test-data")
      setFileMode (linkAnchor </> ".test-data") 0o700
      createDirectoryIfMissing False linkVictim
      setFileMode linkVictim 0o700
      writeFile (linkVictim </> "victim-marker") ("victim-" ++ take 16 (hex32 randomBytes))
      createSymbolicLink linkVictim (linkAnchor </> ".test-data" </> linkId)
      setFileMode (linkVictim </> "victim-marker") 0o600
      rememberFixture linkVictim
      rememberFixture linkAnchor
      linkConfig <- writeConfig "link" linkAnchor linkId generation
      linkBefore <- snapshotTree linkVictim
      linkRun <- public' linkConfig ["control", "reconcile"]
      linkAfter <- snapshotTree linkVictim
      linkClean <- noResource linkId
      -- foreign root: an existing directory with someone else's file and no generation record
      let foreignAnchor = adverseBase </> "a01-03-foreignproject"
          foreignId = "a0103foreign"
          foreignRootDir = foreignAnchor </> ".test-data" </> foreignId
      createDirectoryIfMissing False foreignAnchor
      setFileMode foreignAnchor 0o700
      createDirectoryIfMissing False (foreignAnchor </> ".test-data")
      setFileMode (foreignAnchor </> ".test-data") 0o700
      createDirectoryIfMissing False foreignRootDir
      setFileMode foreignRootDir 0o700
      writeFile (foreignRootDir </> "foreign-marker") ("foreign-" ++ take 16 (hex32 randomBytes))
      setFileMode (foreignRootDir </> "foreign-marker") 0o600
      rememberFixture foreignAnchor
      foreignConfig <- writeConfig "foreign" foreignAnchor foreignId generation
      foreignTreeBefore <- snapshotTree foreignRootDir
      foreignRun <- public' foreignConfig ["control", "reconcile"]
      foreignTreeAfter <- snapshotTree foreignRootDir
      foreignClean <- noResource foreignId
      -- wrong generation against the real retained root
      wrongConfig <- writeConfig "wronggen" project (takeFileName root) alternateGeneration
      generationBefore <-
        try (ByteString.readFile (root </> "scope-generation.json"))
          :: IO (Either IOException ByteString.ByteString)
      wrongRun <- public' wrongConfig ["control", "reconcile"]
      generationAfter <-
        try (ByteString.readFile (root </> "scope-generation.json"))
          :: IO (Either IOException ByteString.ByteString)
      wrongContainers <-
        runDocker socket ["ps", "-a", "-q", "--filter", "label=io.x-k8s.kind.cluster=" ++ cluster]
      wrongVolumes <- runDocker socket ["volume", "ls", "-q", "--filter", "name=" ++ cluster]
      let wrongClean = case (wrongContainers, wrongVolumes) of
            (Right (0, a, _), Right (0, b, _)) -> null (words (a ++ b))
            _ -> False
      -- overlapping: a project whose anchor is the real retained root; the
      -- real root must not gain a nested root or any record.
      nestedConfig <- writeConfig "nested" root "a0103nested" generation
      nestedBefore <- snapshotTree root
      nestedRun <- public' nestedConfig ["control", "reconcile"]
      nestedAfter <- snapshotTree root
      nestedClean <- noResource "a0103nested"
      -- unavailable node image: a digest no registry or cache holds
      let absentImage = "kindest/node@sha256:" ++ replicate 64 '1'
          imageText =
            replaceText
              (kindPlanNodeImage (bootstrapKindPlan projection))
              absentImage
              selectedText
          imageConfigDirectory = adverseBase </> "a01-03-image"
      createDirectoryIfMissing False imageConfigDirectory
      setFileMode imageConfigDirectory 0o700
      Text.writeFile (imageConfigDirectory </> "selected.dhall") (Text.pack imageText)
      setFileMode (imageConfigDirectory </> "selected.dhall") 0o600
      rememberConfig imageConfigDirectory
      imagesBefore <- runDocker socket ["image", "ls", "-a", "-q", "--no-trunc"]
      imageRun <-
        if imageText == selectedText
          then pure (Left "selected node image substitution failed")
          else public' (imageConfigDirectory </> "selected.dhall") ["control", "reconcile"]
      imagesAfter <- runDocker socket ["image", "ls", "-a", "-q", "--no-trunc"]
      imageContainers <-
        runDocker socket ["ps", "-a", "-q", "--filter", "label=io.x-k8s.kind.cluster=" ++ cluster]
      let imageClean = case (imagesBefore, imagesAfter, imageContainers) of
            (Right (0, before, _), Right (0, after, _), Right (0, containers, _)) ->
              imageText /= selectedText && sort (words before) == sort (words after) && null (words containers)
            _ -> False
      -- cross-environment: the same identity declared as production, in a
      -- project that has no production root; nothing may be created.
      let productionAnchor = adverseBase </> "a01-03-productionproject"
          productionText =
            replaceText
              "environment = \"test\""
              "environment = \"production\""
              ( replaceText
                  ("project_anchor = \"" ++ project ++ "\"")
                  ("project_anchor = \"" ++ productionAnchor ++ "\"")
                  selectedText
              )
      createDirectoryIfMissing False productionAnchor
      setFileMode productionAnchor 0o700
      createDirectoryIfMissing False (adverseBase </> "a01-03-production")
      setFileMode (adverseBase </> "a01-03-production") 0o700
      Text.writeFile (adverseBase </> "a01-03-production" </> "selected.dhall") (Text.pack productionText)
      setFileMode (adverseBase </> "a01-03-production" </> "selected.dhall") 0o600
      rememberFixture productionAnchor
      rememberConfig (adverseBase </> "a01-03-production")
      productionRun <-
        public' (adverseBase </> "a01-03-production" </> "selected.dhall") ["control", "reconcile"]
      productionEntries <- try (listDirectory productionAnchor) :: IO (Either IOException [FilePath])
      -- Case 5: the same reconcile with the process confined to one CPU. The
      -- declared envelope needs two; admission must refuse before any effect.
      rootBefore <- snapshotTree root
      imagesBeforeCapacity <- runDocker socket ["image", "ls", "-a", "-q", "--no-trunc"]
      capacityRun <-
        run "/usr/bin/taskset" ["-c", "0", executable, "--config", selected, "control", "reconcile"]
      rootAfter <- snapshotTree root
      imagesAfterCapacity <- runDocker socket ["image", "ls", "-a", "-q", "--no-trunc"]
      capacityContainers <-
        runDocker socket ["ps", "-a", "-q", "--filter", "label=io.x-k8s.kind.cluster=" ++ cluster]
      capacityVolumes <- runDocker socket ["volume", "ls", "-q", "--filter", "name=" ++ cluster]
      capacityDone <- getMonotonicTimeNSec
      let capacityUntouched = case (imagesBeforeCapacity, imagesAfterCapacity, capacityContainers, capacityVolumes) of
            (Right (0, before, _), Right (0, after, _), Right (0, containers, _), Right (0, volumes, _)) ->
              sort (words before) == sort (words after)
                && null (words (containers ++ volumes))
                && rootBefore /= Nothing
                && rootBefore == rootAfter
            _ -> False
          capacityText = textOf capacityRun
      snapshots <- readIORef fixtureSnapshots
      configs <- readIORef fixtureConfigs
      absent3 <- independentAbsence socket cluster
      let safeToCleanup =
            absent3
              && siblingClean
              && siblingRefused
              && siblingBare
              && siblingConfigAfter == Right (Text.pack siblingText)
              && nameRootBare
              && nameConfigAfter == Right (Text.pack nameText)
              && linkClean
              && foreignClean
              && nestedClean
              && wrongClean
              && imageClean
              && productionEntries == Right []
              && all refused [linkRun, foreignRun, wrongRun, imageRun, productionRun, nestedRun]
              && generationBefore == generationAfter
              && either (const False) (const True) generationBefore
          fixturePaths = map fst (snapshots ++ configs)
      batchCleanup <-
        if safeToCleanup
          then cleanupFixtureTrees (map snd (snapshots ++ configs))
          else pure False
      baseInventory <- try
        $ bracket
          ( Posix.openFd
              fixtureBase
              Posix.ReadOnly
              (Posix.defaultFileFlags {Posix.directory = True, Posix.nofollow = True, Posix.cloexec = True})
          )
          Posix.closeFd
        $ \directory@(Fd raw) -> do
          before <- getFdStatus directory
          names <- listDirectory ("/proc/self/fd/" ++ show raw)
          after <- getFdStatus directory
          named <- getSymbolicLinkStatus fixtureBase
          pure $
            isDirectory named
              && deviceID fixtureBaseIdentity == deviceID named
              && fileID fixtureBaseIdentity == fileID named
              && fileOwner fixtureBaseIdentity == fileOwner named
              && fileMode named .&. 0o077 == 0
              && deviceID before == deviceID named
              && fileID before == fileID named
              && deviceID before == deviceID after
              && fileID before == fileID after
              && modificationTimeHiRes before == modificationTimeHiRes after
              && statusChangeTimeHiRes before == statusChangeTimeHiRes after
              && fixtureBaseMatches names
      let fixtureCleanup = batchCleanup && either (const False) id (baseInventory :: Either IOException Bool)
      unless fixtureCleanup $
        writeOutputLine ("Phase 1 fixture cleanup unconfirmed; inspect paths: " ++ show fixturePaths)
      unless decoyCleanup $
        writeOutputLine ("Phase 1 listener cleanup unconfirmed; retained path: " ++ decoyDir)
      writeOutputLine
        ( "Phase 1 retained sibling scopes and configs: "
            ++ siblingAnchor
            ++ ", "
            ++ siblingDirectory
            ++ "; "
            ++ nameAnchor
            ++ ", "
            ++ nameDirectory
        )
      -- The refused reconcile left a half-recorded operation (image loaded,
      -- network create refused). Public delete must settle it so the root is
      -- reusable, not stranded behind an incomplete-removal refusal.
      recoverDelete <- public ["control", "delete", "--yes"]
      recoveredArchive <- try (listDirectory root) :: IO (Either IOException [FilePath])
      adverseDone <- getMonotonicTimeNSec
      let ok result = either (const False) (\(code, _, _) -> code == 0) result
          deleted result =
            either
              (const False)
              (\(code, out, _) -> code == 0 && "Recorded kind resources were removed" `isInfixOf` out)
              result
          s1 = textOf status1
          claimedScope =
            ("Control candidate: " ++ cluster) `isInfixOf` s1
              && "Generation record: matches selected generation" `isInfixOf` s1
          claimedReady = "API /readyz ok" `isInfixOf` s1 && "nodes Ready 1 of 1" `isInfixOf` s1
          independentScope = retained1 && root == project </> ".test-data" </> scopeIdentifier scope && scopeApiPort scope > 0
          lifecycle =
            scenarioReport
              (bindingFor 1 "lifecycle")
              (ScenarioTiming started networkFinished cleanup1)
              (if claimedReady && ready1 then PrimarySucceeded else PrimaryFailed)
              (if absent1 then CleanupConfirmed else CleanupFailed)
              ["context.scope", "cluster.ready", "cleanup.absence", "host.data-retained"]
              [claimedScope, claimedReady, deleted delete1, "(present)" `isInfixOf` textOf status1 || retained1]
              [independentScope, ready1, absent1, retained1]
          claimedNetwork = "Network policy enforcement: PROVEN" `isInfixOf` textOf reconcile1
          independentNetwork = maybe False enforcementProven (enforcementObservation networkAgain)
          network =
            scenarioReport
              (bindingFor 4 "network")
              (ScenarioTiming started networkFinished cleanup1)
              (if claimedNetwork && independentNetwork then PrimarySucceeded else PrimaryFailed)
              ( if absent1 && enforcementCleanup networkAgain == EnforcementCleanupConfirmed
                  then CleanupConfirmed
                  else CleanupFailed
              )
              ["network.enforced"]
              [claimedNetwork]
              [independentNetwork]
          markerClaimed = ("MARKER=" ++ marker) `isInfixOf` textOf read2
          pvMarker = marker ++ "pv"
          pvClaimed = case pvRead of
            Right (phase, volume, output) -> phase == "Bound" && volume == "pv-a01-02" && ("MARKER=" ++ pvMarker) `isInfixOf` output
            Left _ -> False
          pvIndependent =
            pvHostBefore == Right pvMarker
              && pvHostAfter == Right pvMarker
              && ( case pvWritten of
                     Right (phase, volume, _) -> phase == "Bound" && volume == "pv-a01-02"
                     Left _ -> False
                 )
          markerHost = either (const False) (== marker) hostBefore && either (const False) (== marker) hostAfter
          nodeReplaced = firstNode /= Nothing && secondNode /= Nothing && firstNode /= secondNode
          archived = either (const False) (not . null) histories
          claimedReplaced = ok reconcile2 || "Incomplete: operation" `isInfixOf` textOf reconcile2
          recreation =
            scenarioReport
              (bindingFor 2 "recreation")
              (ScenarioTiming writeFinished recreated cleanup2)
              (if markerClaimed && markerHost && ready2 then PrimarySucceeded else PrimaryFailed)
              (if absent2 && retained2 && deleted delete2 then CleanupConfirmed else CleanupFailed)
              ["marker.survived-recreation", "node.recreated", "history.archived", "pv.bound-deterministically"]
              [ markerClaimed
              , claimedReplaced && ok written
              , "history" `isInfixOf` "history" && archived
              , pvClaimed
              ]
              [markerHost, nodeReplaced, archived, pvIndependent]
      let foreignIntact =
            maybe
              False
              (\identifier -> fixtureNetworkUntouched identifier foreignBefore foreignAfter)
              createdNetwork
          madeOk = maybe False (const True) createdNetwork
          claimedAmbient = ok ambient && "API /readyz ok" `isInfixOf` textOf ambient
          claimedRefused = not (ok adverse) && not (null (textOf adverse))
          noNode = noAdverseNode
          adverseCase =
            scenarioReport
              (bindingFor 3 "adverse")
              (ScenarioTiming cleanup2 adverseDone adverseDone)
              (if madeOk && claimedRefused && foreignIntact && noNode then PrimarySucceeded else PrimaryFailed)
              ( if absent3
                  && listenerGone
                  && decoyCleanup
                  && fixtureCleanup
                  && (case foreignRemoved of Right (0, _, _) -> True; _ -> False)
                  then CleanupConfirmed
                  else CleanupFailed
              )
              [ "adverse.refused"
              , "adverse.foreign-network-untouched"
              , "adverse.no-node-created"
              , "adverse.ambient-kubeconfig-unused"
              , "adverse.symlinked-root-refused"
              , "adverse.foreign-root-refused"
              , "adverse.wrong-generation-refused"
              , "adverse.unavailable-image-refused"
              , "adverse.cross-environment-refused"
              , "adverse.nested-root-refused"
              , "adverse.sibling-port-conflict-refused"
              , "adverse.repeat-delete-settles"
              , "adverse.sibling-kind-name-refused"
              ]
              [ claimedRefused
              , claimedRefused
              , claimedRefused
              , claimedAmbient
              , refused linkRun
              , refused foreignRun
              , refused wrongRun
              , refused imageRun
              , refused productionRun
              , refused nestedRun
              , siblingRefused
              , deleted recoverDelete
              , nameRefused
              ]
              [ madeOk && not (ok adverse)
              , foreignIntact
              , noNode
              , decoyReady && not decoyConnected && decoyBefore == decoyAfter
              , linkBefore /= Nothing && linkBefore == linkAfter && linkClean && not (ok linkRun)
              , foreignTreeBefore /= Nothing
                  && foreignTreeBefore == foreignTreeAfter
                  && foreignClean
                  && not (ok foreignRun)
              , generationBefore == generationAfter
                  && either (const False) (const True) generationBefore
                  && wrongClean
                  && not (ok wrongRun)
              , imageClean && not (ok imageRun)
              , productionEntries == Right [] && not (ok productionRun)
              , nestedBefore /= Nothing && nestedBefore == nestedAfter && nestedClean && not (ok nestedRun)
              , siblingClean
                  && siblingBare
                  && siblingConfigAfter == Right (Text.pack siblingText)
                  && siblingStillReady
                  && siblingExit /= 0
              , ok recoverDelete
                  && either (const False) ("kind-network-create-result.json" `elem`) recoveredArchive
                  && absent3
              , nameRefused
                  && nameUntouched
                  && nameRootBare
                  && nameConfigAfter == Right (Text.pack nameText)
                  && nameStillReady
              ]
      first <- mapM (publishScenario project) [lifecycle, network, recreation, adverseCase]
      -- Case 6: the validator, driven against the real stored case-1 report,
      -- must reject fabricated, missing, stale and wrong-scope evidence and
      -- accept the untampered pair as its positive control.
      let (stored1, independent1, names1) = lifecycle
          binding1 = reportBinding stored1
          lifecycleNames = names1
          check binding required observed = validateStoredScenarioReport project binding required (pure observed)
          flipFirst values = case values of
            ScenarioObservation name _ : rest -> ScenarioObservation name ObservationViolated : rest
            [] -> []
      control <- check binding1 lifecycleNames (Just independent1)
      fabricated <-
        check
          binding1
          lifecycleNames
          (Just independent1 {independentObservations = flipFirst (independentObservations independent1)})
      missingObs <- check binding1 lifecycleNames Nothing
      staleTiming <-
        check
          binding1
          lifecycleNames
          ( Just
              independent1
                { independentTiming =
                    (independentTiming independent1)
                      { scenarioStartedNanos = scenarioStartedNanos (independentTiming independent1) + 1
                      }
                }
          )
      wrongScope <-
        check
          binding1 {scenarioGeneration = alternateGeneration}
          lifecycleNames
          (Just independent1)
      missingReport <-
        check binding1 {scenarioOperationId = hex32 "no-such-operation"} lifecycleNames (Just independent1)
      done6 <- getMonotonicTimeNSec
      let rejected result = either (const True) (const False) result
          accepted = control == Right EvidenceChecksSatisfied
          allRejected =
            [ rejected fabricated
            , rejected missingObs
            , rejected staleTiming
            , rejected wrongScope
            , rejected missingReport
            ]
          validatorCase =
            scenarioReport
              (bindingFor 6 "validator")
              (ScenarioTiming cleanup2 done6 done6)
              (if accepted && and allRejected then PrimarySucceeded else PrimaryFailed)
              CleanupConfirmed
              [ "evidence.control-accepted"
              , "evidence.rejects-fabricated"
              , "evidence.rejects-missing-observation"
              , "evidence.rejects-stale"
              , "evidence.rejects-wrong-scope"
              , "evidence.rejects-missing-report"
              ]
              (replicate 6 True)
              (accepted : allRejected)
      validatorPublished <- publishScenario project validatorCase
      let capacityCase =
            scenarioReport
              (bindingFor 5 "capacity")
              (ScenarioTiming cleanup2 capacityDone capacityDone)
              (if refusedForCapacity && capacityUntouched && ready1 then PrimarySucceeded else PrimaryFailed)
              CleanupConfirmed
              [ "capacity.admitted-when-sufficient"
              , "capacity.rejected-before-work"
              , "capacity.usage-within-declared"
              , "capacity.pod-completes-under-limit"
              , "capacity.limit-enforced"
              , "capacity.quota-enforced"
              ]
              [claimedReady, refusedForCapacity, claimedReady, claimedReady, claimedReady, claimedReady]
              [ ready1
              , capacityUntouched && not (ok capacityRun)
              , usageWithinDeclared
              , withinLimit == Right ("Succeeded", "Completed", "64Mi")
              , overLimit == Right ("Failed", "OOMKilled", "16Mi")
              , ( case quota of
                    (admitted, refusedByQuota, accounting) -> admitted && refusedByQuota && accounting == "8Mi"
                )
              ]
          usageWithinDeclared = case slicePeak of
            Just sample ->
              samplePeakMemory sample > 0
                && samplePeakMemory sample <= sampleMemoryLimit sample
                && samplePeakTasks sample > 0
                && samplePeakTasks sample <= sampleTaskLimit sample
            Nothing -> False
          refusedForCapacity =
            not (ok capacityRun)
              && "Refused before any work" `isInfixOf` capacityText
              && "milli_cpu" `isInfixOf` capacityText
      capacityPublished <- publishScenario project capacityCase
      preparationPublished <- case fresh of
        Nothing -> pure []
        Just (preparation, importChecks) -> do
          finalArtifacts <- observeImportSnapshot projection
          let claims =
                [True, True, True, True]
                  ++ importAdverseClaims importChecks
                  ++ [True, ok reconcile1, ok reconcile2, deleted delete2 && ok recoverDelete]
              observed =
                [ freshRootWasAbsent preparation
                , freshImageObservation preparation == FreshImageAbsent
                , finalArtifacts /= Nothing
                , freshSourceIdentity preparation == source
                    && freshBinaryIdentity preparation == digest (ByteString8.unpack (hexSha256 binaryBytes))
                    && freshBootIdentity preparation == bootId
                ]
                  ++ importAdverseObservations importChecks
                  ++ [ freshStagingCleaned preparation && importAdverseCleanup importChecks
                     , ready1
                     , ready2 && nodeReplaced
                     , absent2 && absent3
                     ]
              start = freshStarted preparation
              binding =
                (bindingFor 8 "automatic-preparation")
                  { scenarioPublicCommand =
                      digest
                        "config setup --fresh-test; control import-artifact node-archive; control import-artifact kind-tool; altered, missing, and foreign-generation imports; control reconcile; control delete --yes; control reconcile; control delete --yes; adverse controls and recovery"
                  , scenarioBudget =
                      ScenarioBudget (start + 3600 * second) (start + 4200 * second) (1024 * 1048576) 3600000000 0
                  }
              preparationCase =
                scenarioReport
                  binding
                  (ScenarioTiming start adverseDone adverseDone)
                  (if and claims && and observed then PrimarySucceeded else PrimaryFailed)
                  ( if absent2
                      && absent3
                      && decoyCleanup
                      && fixtureCleanup
                      && freshStagingCleaned preparation
                      && importAdverseCleanup importChecks
                      then CleanupConfirmed
                      else CleanupFailed
                  )
                  [ "preparation.fresh-root"
                  , "preparation.image-absent"
                  , "preparation.artifacts-retained"
                  , "preparation.identity-stable"
                  , "preparation.altered-refused"
                  , "preparation.missing-refused"
                  , "preparation.foreign-refused"
                  , "preparation.staging-clean"
                  , "preparation.node-created"
                  , "preparation.node-recreated"
                  , "preparation.node-absent"
                  ]
                  claims
                  observed
          (: []) <$> publishScenario project preparationCase
      let reports = first ++ [validatorPublished, capacityPublished] ++ preparationPublished
      writeOutputLine (unlines (map fst reports))
      writeOutputLine ("slice samples: " ++ show slicePeak)
      writeOutputLine ("pv: " ++ take 500 (show (pvWritten, pvRead, pvHostBefore, pvHostAfter)))
      writeOutputLine ("port sibling: " ++ take 300 siblingText' ++ " exit=" ++ show siblingExit)
      writeOutputLine
        ( "name sibling: "
            ++ take 300 nameOutput
            ++ " | entries="
            ++ show nameRootBare
            ++ " | untouched="
            ++ show nameUntouched
            ++ " | ready="
            ++ show nameStillReady
        )
      writeOutputLine
        ("recover delete: " ++ take 400 (textOf recoverDelete) ++ " | root=" ++ show recoveredArchive)
      writeOutputLine ("pods under limits: " ++ show (withinLimit, overLimit))
      writeOutputLine
        ( "detail: marker writer="
            ++ take 160 (show written)
            ++ "; host before="
            ++ show (fmap (take 40) hostBefore)
            ++ "; reader="
            ++ take 160 (show read2)
            ++ "; host after="
            ++ show (fmap (take 40) hostAfter)
            ++ "; nodes replaced="
            ++ show nodeReplaced
            ++ "; history="
            ++ show histories
        )
      pure (if all snd reports then ExitSuccess else ExitFailure 1)

readRandomBytes :: IO (Either String ByteString.ByteString)
readRandomBytes = do
  bytes <-
    try (withBinaryFile "/dev/urandom" ReadMode (\handle -> ByteString.hGet handle 16))
      :: IO (Either IOException ByteString.ByteString)
  pure (validateScenarioEntropy (either (const Nothing) Just bytes))

validateScenarioEntropy :: Maybe ByteString.ByteString -> Either String ByteString.ByteString
validateScenarioEntropy candidate = case candidate of
  Just value | ByteString.length value == 16 -> Right value
  _ -> Left "fresh random bytes were unavailable or incomplete"

validateBootIdentity :: Maybe ByteString.ByteString -> Maybe ByteString.ByteString
validateBootIdentity candidate = do
  bytes <- candidate
  let raw = ByteString8.unpack bytes
      value = if length raw == 37 && last raw == '\n' then init raw else raw
      valid (index, character)
        | index `elem` [8, 13, 18, 23] = character == '-'
        | otherwise = isDigit character && character <= '9' || isAsciiLower character && character <= 'f'
  if length value == 36 && all valid (zip [(0 :: Int) ..] value)
    then Just (ByteString8.pack value)
    else Nothing
scenarioReport
  :: ScenarioBinding
  -> ScenarioTiming
  -> ScenarioPrimary
  -> ScenarioCleanup
  -> [Text]
  -> [Bool]
  -> [Bool]
  -> (ScenarioReport, IndependentScenarioObservation, [Text])
scenarioReport binding timing primary cleanup names claimed independentValues =
  ( ScenarioReport
      binding
      timing
      primary
      cleanup
      (zipWith ScenarioObservation names (map satisfied claimed))
  , IndependentScenarioObservation
      binding
      timing
      primary
      cleanup
      (zipWith ScenarioObservation names (map satisfied independentValues))
  , names
  )
publishScenario
  :: FilePath -> (ScenarioReport, IndependentScenarioObservation, [Text]) -> IO (String, Bool)
publishScenario project (stored, independent, names) = do
  -- The store requires a private .build directory under the project; the
  -- runner owns the scenario's isolation and creates only that directory.
  createDirectoryIfMissing False (project </> ".build")
  setFileMode (project </> ".build") 0o700
  written <- writeScenarioReport project stored
  case written of
    Left failure ->
      pure
        ( "case " ++ show (scenarioCase (reportBinding stored)) ++ ": report not written: " ++ show failure
        , False
        )
    Right () -> do
      validated <-
        validateStoredScenarioReport project (reportBinding stored) names (pure (Just independent))
      let good =
            validated == Right EvidenceChecksSatisfied
              && reportPrimary stored == PrimarySucceeded
              && reportCleanup stored == CleanupConfirmed
      pure
        ( "case "
            ++ show (scenarioCase (reportBinding stored))
            ++ ": claimed="
            ++ show (map scenarioObservationResult (reportObservations stored))
            ++ " independent="
            ++ show (map scenarioObservationResult (independentObservations independent))
            ++ " primary="
            ++ show (reportPrimary stored)
            ++ " cleanup="
            ++ show (reportCleanup stored)
            ++ " validation="
            ++ show validated
        , good
        )

-- | The controller's transient slice only exists while its unit runs, so its
-- kernel counters are sampled while the public command works. Each sample
-- reads the kernel's own peak and configured limit for memory and tasks.
data SliceSample = SliceSample
  { samplePeakMemory :: !Integer
  , sampleMemoryLimit :: !Integer
  , samplePeakTasks :: !Integer
  , sampleTaskLimit :: !Integer
  }
  deriving (Eq, Show)

sliceDirectory :: FilePath
sliceDirectory = "/sys/fs/cgroup/user.slice/user-1000.slice/user@1000.service/prodboxkind.slice"

readCounter :: FilePath -> IO (Maybe Integer)
readCounter name = do
  contents <-
    try (ByteString8.readFile (sliceDirectory </> name))
      :: IO (Either IOException ByteString8.ByteString)
  pure $ case fmap (ByteString8.words) contents of
    Right [word] | Just (value, rest) <- ByteString8.readInteger word, ByteString8.null rest -> Just value
    _ -> Nothing

sampleSlice :: IO (Maybe SliceSample)
sampleSlice = do
  peak <- readCounter "memory.peak"
  limit <- readCounter "memory.max"
  tasksPeak <- readCounter "pids.peak"
  taskLimit <- readCounter "pids.max"
  pure (SliceSample <$> peak <*> limit <*> tasksPeak <*> taskLimit)

-- | Poll until told to stop and keep the largest peaks seen.
sliceMonitor :: IORef Bool -> IO (Maybe SliceSample)
sliceMonitor stop = loop Nothing
 where
  loop best = do
    finished <- readIORef stop
    sample <- sampleSlice
    let merged = case (best, sample) of
          (Nothing, other) -> other
          (other, Nothing) -> other
          (Just old, Just new) ->
            Just
              new
                { samplePeakMemory = max (samplePeakMemory old) (samplePeakMemory new)
                , samplePeakTasks = max (samplePeakTasks old) (samplePeakTasks new)
                }
    if finished then pure merged else threadDelay 100000 >> loop merged

-- | A real Pod with an explicit memory request and limit. Returns what the
-- API server reports afterwards: phase, the container's terminated reason and
-- the limit it actually carries. The Pod is deleted before returning.
limitedPod :: FilePath -> String -> String -> String -> IO (Either String (String, String, String))
limitedPod kubeconfig name limit script = do
  let manifest =
        ByteString8.pack $
          unlines
            [ "apiVersion: v1"
            , "kind: Pod"
            , "metadata: {name: " ++ name ++ ", namespace: default}"
            , "spec:"
            , "  restartPolicy: Never"
            , "  containers: [{name: c, image: docker.io/kindest/local-path-helper:v20260131-7181c60a, imagePullPolicy: Never, command: [bash, -c, "
                ++ show script
                ++ "], resources: {requests: {cpu: 10m, memory: 8Mi}, limits: {cpu: 200m, memory: "
                ++ limit
                ++ "}}}]"
            ]
      kubectl arguments input =
        captureSubprocessWithInputBounded
          (BoundedSubprocessLimits 65536 (512 * 1024) (64 * 1024) 200000000)
          input
          ( Subprocess
              "/usr/bin/kubectl"
              (["--kubeconfig", kubeconfig, "--request-timeout=30s"] ++ arguments)
              (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")])
              Nothing
          )
  _ <- kubectl ["delete", "pod", name, "--ignore-not-found"] ByteString.empty
  applied <- kubectl ["apply", "-f", "-"] manifest
  case applied of
    Left failure -> pure (Left (show failure))
    Right _ -> do
      -- Either terminal phase ends the wait; the outcome is read, not assumed.
      _ <-
        kubectl
          [ "wait"
          , "--for=jsonpath={.status.containerStatuses[0].state.terminated}"
          , "pod/" ++ name
          , "--timeout=120s"
          ]
          ByteString.empty
      let describe :: Int -> IO (Either AppError ProcessOutput)
          describe attempts = do
            result <-
              kubectl
                [ "get"
                , "pod"
                , name
                , "-o"
                , "jsonpath={.status.phase} {.status.containerStatuses[0].state.terminated.reason} {.spec.containers[0].resources.limits.memory}"
                ]
                ByteString.empty
            let settled = case result of
                  Right output -> take 1 (words (processStdout output)) `elem` [["Succeeded"], ["Failed"]]
                  Left _ -> True
            if settled || attempts <= 0 then pure result else threadDelay 1000000 >> describe (attempts - 1)
      described <- describe 20
      _ <- kubectl ["delete", "pod", name, "--ignore-not-found", "--wait=false"] ByteString.empty
      pure $ case described of
        Right output -> case words (processStdout output) of
          [phase, reason, memory] -> Right (phase, reason, memory)
          _ -> Left ("unexpected pod description: " ++ take 120 (processStdout output))
        Left failure -> Left (show failure)

-- | A static PersistentVolume under the retained host root, bound to one
-- PersistentVolumeClaim by name (no dynamic provisioner involved), and a Pod
-- that mounts the claim. Returns the claim's phase, the volume it is bound to
-- and the Pod's output.
pvPod :: FilePath -> String -> String -> IO (Either String (String, String, String))
pvPod kubeconfig name script = do
  let objects =
        ByteString8.pack $
          unlines
            [ "apiVersion: v1"
            , "kind: PersistentVolume"
            , "metadata: {name: pv-a01-02}"
            , "spec: {capacity: {storage: 64Mi}, accessModes: [ReadWriteOnce], persistentVolumeReclaimPolicy: Retain, storageClassName: prodbox-retained, claimRef: {namespace: default, name: pvc-a01-02}, hostPath: {path: /var/lib/prodbox/pv-a01-02, type: Directory}}"
            , "---"
            , "apiVersion: v1"
            , "kind: PersistentVolumeClaim"
            , "metadata: {name: pvc-a01-02, namespace: default}"
            , "spec: {accessModes: [ReadWriteOnce], storageClassName: prodbox-retained, volumeName: pv-a01-02, resources: {requests: {storage: 64Mi}}}"
            , "---"
            , "apiVersion: v1"
            , "kind: Pod"
            , "metadata: {name: " ++ name ++ ", namespace: default}"
            , "spec:"
            , "  restartPolicy: Never"
            , "  containers: [{name: c, image: docker.io/kindest/local-path-helper:v20260131-7181c60a, imagePullPolicy: Never, command: [bash, -c, "
                ++ show script
                ++ "], volumeMounts: [{name: d, mountPath: /d}]}]"
            , "  volumes: [{name: d, persistentVolumeClaim: {claimName: pvc-a01-02}}]"
            ]
      kubectl arguments input =
        captureSubprocessWithInputBounded
          (BoundedSubprocessLimits 65536 (512 * 1024) (64 * 1024) 200000000)
          input
          ( Subprocess
              "/usr/bin/kubectl"
              (["--kubeconfig", kubeconfig, "--request-timeout=30s"] ++ arguments)
              (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")])
              Nothing
          )
  _ <- kubectl ["delete", "pod", name, "--ignore-not-found"] ByteString.empty
  applied <- kubectl ["apply", "-f", "-"] objects
  case applied of
    Left failure -> pure (Left (show failure))
    Right _ -> do
      _ <-
        kubectl
          ["wait", "--for=jsonpath={.status.phase}=Succeeded", "pod/" ++ name, "--timeout=120s"]
          ByteString.empty
      logs <- kubectl ["logs", name] ByteString.empty
      claim <-
        kubectl
          ["get", "pvc", "pvc-a01-02", "-o", "jsonpath={.status.phase} {.spec.volumeName}"]
          ByteString.empty
      _ <- kubectl ["delete", "pod", name, "--ignore-not-found", "--wait=false"] ByteString.empty
      pure $ case (claim, logs) of
        (Right described, Right output) -> case words (processStdout described) of
          [phase, volume] -> Right (phase, volume, processStdout output)
          _ -> Left ("unexpected claim description: " ++ take 120 (processStdout described))
        _ -> Left "claim or logs unreadable"

-- | A namespace ResourceQuota: a Pod inside it is admitted, a Pod whose
-- request would exceed the quota is refused by the API server, and the
-- quota's own accounting shows the admitted Pod's request.
quotaProbe :: FilePath -> String -> IO (Bool, Bool, String)
quotaProbe kubeconfig namespace = do
  let kubectl arguments input =
        captureSubprocessWithInputBounded
          (BoundedSubprocessLimits 65536 (512 * 1024) (64 * 1024) 200000000)
          input
          ( Subprocess
              "/usr/bin/kubectl"
              (["--kubeconfig", kubeconfig, "--request-timeout=30s"] ++ arguments)
              (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")])
              Nothing
          )
      pod name request limit =
        ByteString8.pack $
          unlines
            [ "apiVersion: v1"
            , "kind: Pod"
            , "metadata: {name: " ++ name ++ ", namespace: " ++ namespace ++ "}"
            , "spec:"
            , "  restartPolicy: Never"
            , "  containers: [{name: c, image: docker.io/kindest/local-path-helper:v20260131-7181c60a, imagePullPolicy: Never, command: [bash, -c, \"sleep 1\"], resources: {requests: {cpu: 10m, memory: "
                ++ request
                ++ "}, limits: {cpu: 100m, memory: "
                ++ limit
                ++ "}}}]"
            ]
      setup =
        ByteString8.pack $
          unlines
            [ "apiVersion: v1"
            , "kind: Namespace"
            , "metadata: {name: " ++ namespace ++ "}"
            , "---"
            , "apiVersion: v1"
            , "kind: ResourceQuota"
            , "metadata: {name: memory-quota, namespace: " ++ namespace ++ "}"
            , "spec: {hard: {requests.memory: 32Mi, limits.memory: 64Mi, pods: \"2\"}}"
            ]
  _ <- kubectl ["apply", "-f", "-"] setup
  -- The quota controller fills in status asynchronously.
  _ <-
    kubectl
      [ "-n"
      , namespace
      , "wait"
      , "--for=jsonpath={.status.hard.pods}=2"
      , "resourcequota/memory-quota"
      , "--timeout=60s"
      ]
      ByteString.empty
  within <- kubectl ["apply", "-f", "-"] (pod "within" "8Mi" "16Mi")
  over <- kubectl ["apply", "-f", "-"] (pod "over" "64Mi" "128Mi")
  used <-
    kubectl
      [ "-n"
      , namespace
      , "get"
      , "resourcequota"
      , "memory-quota"
      , "-o"
      , "jsonpath={.status.used.requests\\.memory}"
      ]
      ByteString.empty
  _ <- kubectl ["delete", "namespace", namespace, "--wait=true", "--timeout=90s"] ByteString.empty
  let admitted = either (const False) (\output -> processExitCode output == ExitSuccess) within
      refusedByQuota = case over of
        Left failure -> "exceeded quota" `isInfixOf` show failure
        Right output ->
          processExitCode output /= ExitSuccess
            && "exceeded quota" `isInfixOf` (processStdout output ++ processStderr output)
      accounting = either (const "") processStdout used
  pure (admitted, refusedByQuota, accounting)

waitFor :: IO Bool -> Int -> IO Bool
waitFor condition attempts = do
  done <- condition
  if done || attempts <= 0
    then pure done
    else threadDelay 500000 >> waitFor condition (attempts - 1)

containerId :: FilePath -> String -> IO (Maybe String)
containerId socket name = do
  result <- runDocker socket ["inspect", "--format", "{{.Id}}", name]
  pure $ case result of
    Right (0, out, _) -> case words out of
      [single] -> Just single
      _ -> Nothing
    _ -> Nothing

-- A real Pod that mounts the node's host-root path and runs one bash command.
podOnHostRoot :: FilePath -> String -> String -> IO (Either String (Int, String, String))
podOnHostRoot kubeconfig name script = do
  let manifest =
        ByteString8.pack $
          unlines
            [ "apiVersion: v1"
            , "kind: Pod"
            , "metadata: {name: " ++ name ++ ", namespace: default}"
            , "spec:"
            , "  restartPolicy: Never"
            , "  containers: [{name: c, image: docker.io/kindest/local-path-helper:v20260131-7181c60a, imagePullPolicy: Never, command: [bash, -c, "
                ++ show script
                ++ "], volumeMounts: [{name: h, mountPath: /h}]}]"
            , "  volumes: [{name: h, hostPath: {path: /var/lib/prodbox, type: Directory}}]"
            ]
      kubectl arguments input =
        captureSubprocessWithInputBounded
          (BoundedSubprocessLimits 65536 (512 * 1024) (64 * 1024) 200000000)
          input
          ( Subprocess
              "/usr/bin/kubectl"
              (["--kubeconfig", kubeconfig, "--request-timeout=30s"] ++ arguments)
              (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")])
              Nothing
          )
  _ <- kubectl ["delete", "pod", name, "--ignore-not-found"] ByteString.empty
  applied <- kubectl ["apply", "-f", "-"] manifest
  case applied of
    Left failure -> pure (Left (show failure))
    Right _ -> do
      _ <-
        kubectl
          ["wait", "--for=jsonpath={.status.phase}=Succeeded", "pod/" ++ name, "--timeout=90s"]
          ByteString.empty
      logs <- kubectl ["logs", name] ByteString.empty
      pure $ case logs of
        Right output ->
          Right
            ( case processExitCode output of ExitSuccess -> 0; ExitFailure code -> code
            , processStdout output
            , processStderr output
            )
        Left failure -> Left (show failure)

-- The live cluster through the installed credential and the Docker CLI, not
-- through any prodbox status path.
independentClusterReady :: FilePath -> FilePath -> String -> IO Bool
independentClusterReady socket root cluster = do
  nodes <-
    run
      "/usr/bin/kubectl"
      [ "--kubeconfig"
      , root </> "control" </> "kubeconfig"
      , "--request-timeout=20s"
      , "get"
      , "nodes"
      , "-o"
      , "jsonpath={range .items[*]}{.status.conditions[?(@.type==\"Ready\")].status}{\"\\n\"}{end}"
      ]
  container <-
    runDocker socket ["inspect", "--format", "{{.State.Running}}", cluster ++ "-control-plane"]
  pure $
    case (nodes, container) of
      (Right (0, readyLines, _), Right (0, running, _)) -> lines readyLines == ["True"] && lines running == ["true"]
      _ -> False

-- No container, volume or network of this identity remains, read from the
-- Docker CLI.
independentAbsence :: FilePath -> String -> IO Bool
independentAbsence socket cluster = do
  containers <-
    runDocker socket ["ps", "-a", "-q", "--filter", "label=io.x-k8s.kind.cluster=" ++ cluster]
  namedContainers <-
    runDocker socket ["ps", "-a", "-q", "--filter", "name=^/" ++ cluster ++ "-control-plane$"]
  volumes <- runDocker socket ["volume", "ls", "-q", "--filter", "name=" ++ cluster]
  networks <- runDocker socket ["network", "ls", "-q", "--filter", "name=^" ++ cluster ++ "$"]
  pure $ case (containers, namedContainers, volumes, networks) of
    (Right (0, c, _), Right (0, named, _), Right (0, v, _), Right (0, n, _)) ->
      null (words c) && null (words named) && null (words v) && null (words n)
    _ -> False

-- Host data is read directly from the retained root.
independentHostData :: FilePath -> String -> Maybe ArtifactDeclaration -> IO Bool
independentHostData root generation nodeArchive = do
  rootPresent <- doesDirectoryExist root
  recordPresent <- doesFileExist (root </> "scope-generation.json")
  record <- try (readFile (root </> "scope-generation.json")) :: IO (Either IOException String)
  archiveSize <-
    case nodeArchive of
      Nothing -> pure 0
      Just _ ->
        try (getFileSize (root </> "artifacts" </> "node.tar")) >>= \sized -> pure (either (\(_ :: IOException) -> 0) id sized)
  pure
    ( rootPresent
        && recordPresent
        && either (const False) (generation `isInfixOf`) record
        && archiveSize > 0
    )
