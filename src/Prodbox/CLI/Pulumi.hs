module Prodbox.CLI.Pulumi
  ( EphemeralPulumiStack (..)
  , EphemeralPulumiOutputs (..)
  , readEphemeralPulumiOutputs
  , runPulumiCommandWithGate
  , renderPulumiPlan
  , runPulumiCommand
  , withEphemeralPulumiStack
  , writeEphemeralPulumiOutputs
  )
where

import Control.Exception (bracketOnError, finally)
import Data.Aeson
  ( Value (..)
  , eitherDecode
  , encode
  , object
  , (.=)
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Prodbox.CLI.Command
  ( PerRunPruneTarget (..)
  , Plan
  , PulumiCommand (..)
  , buildPlan
  , runPlanWithOptions
  )
import Prodbox.CLI.Output (writeDiagnosticLine, writeOutputLine)
import Prodbox.Infra.AwsEksSubzoneStack qualified as SubzoneStack
import Prodbox.Infra.AwsEksTestStack qualified as EksStack
import Prodbox.Infra.AwsSesStack qualified as SesStack
import Prodbox.Infra.AwsTestStack qualified as TestStack
import Prodbox.Infra.StackOutputs (StackName (..))
import Prodbox.Lifecycle.LiveResidue
  ( awsEksSubzoneStackName
  , awsEksTestStackName
  , awsTestStackName
  , pruneCorruptPerRunCheckpoint
  )
import Prodbox.Settings
  ( validateAndLoadSettings
  , validatedDeploymentContext
  )
import Prodbox.Vault.Client
  ( vaultSealStatus
  )
import Prodbox.Vault.Gate
  ( VaultGateOutcome (..)
  , vaultGateOutcome
  )
import Prodbox.Vault.Host (vaultAddressForDeploymentContext)
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , removeFile
  , removePathForcibly
  )
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)

data EphemeralPulumiStack = EphemeralPulumiStack
  { ephemeralPulumiStackName :: String
  , ephemeralPulumiStackRoot :: FilePath
  , ephemeralPulumiOutputsPath :: FilePath
  }
  deriving (Eq, Show)

data EphemeralPulumiOutputs = EphemeralPulumiOutputs
  { ephemeralOutputsStackName :: String
  , ephemeralOutputsValues :: Map String String
  }
  deriving (Eq, Show)

runPulumiCommand :: FilePath -> PulumiCommand -> IO ExitCode
runPulumiCommand repoRoot =
  runPulumiCommandWithGate (probePulumiVaultGate repoRoot) repoRoot

runPulumiCommandWithGate :: IO VaultGateOutcome -> FilePath -> PulumiCommand -> IO ExitCode
runPulumiCommandWithGate gate repoRoot command =
  case command of
    PulumiEksResources planOptions ->
      runPlanWithOptions
        planOptions
        (buildPulumiExecutionPlan "eks-resources" False)
        (\_ -> runGatedPulumiApply gate (EksStack.ensureAwsEksTestStackResources repoRoot))
    PulumiEksDestroy confirmed planOptions ->
      runPlanWithOptions
        planOptions
        (buildPulumiExecutionPlan "eks-destroy" confirmed)
        ( \_ ->
            requireDestroyConfirmation "prodbox aws stack eks destroy" confirmed $
              runGatedPulumiApply gate (EksStack.destroyAwsEksTestStack repoRoot destroyOutputIsQuiet)
        )
    PulumiTestResources planOptions ->
      runPlanWithOptions
        planOptions
        (buildPulumiExecutionPlan "test-resources" False)
        (\_ -> runGatedPulumiApply gate (TestStack.ensureAwsTestStackResources repoRoot))
    PulumiTestDestroy confirmed planOptions ->
      runPlanWithOptions
        planOptions
        (buildPulumiExecutionPlan "test-destroy" confirmed)
        ( \_ ->
            requireDestroyConfirmation "prodbox aws stack test destroy" confirmed $
              runGatedPulumiApply gate (TestStack.destroyAwsTestStack repoRoot destroyOutputIsQuiet)
        )
    PulumiAwsSubzoneResources planOptions ->
      runPlanWithOptions
        planOptions
        (buildPulumiExecutionPlan "aws-subzone-resources" False)
        (\_ -> runGatedPulumiApply gate (SubzoneStack.ensureAwsEksSubzoneStackResources repoRoot))
    PulumiAwsSubzoneDestroy confirmed planOptions ->
      runPlanWithOptions
        planOptions
        (buildPulumiExecutionPlan "aws-subzone-destroy" confirmed)
        ( \_ ->
            requireDestroyConfirmation "prodbox aws stack aws-subzone destroy" confirmed $
              runGatedPulumiApply gate (SubzoneStack.destroyAwsEksSubzoneStack repoRoot destroyOutputIsQuiet)
        )
    PulumiAwsSesResources planOptions ->
      runPlanWithOptions
        planOptions
        (buildPulumiExecutionPlan "aws-ses-resources" False)
        (\_ -> runGatedPulumiApply gate (SesStack.ensureAwsSesStackResources repoRoot))
    PulumiAwsSesDestroy confirmed planOptions ->
      runPlanWithOptions
        planOptions
        (buildPulumiExecutionPlan "aws-ses-destroy" confirmed)
        ( \_ ->
            requireDestroyConfirmation "prodbox aws stack aws-ses destroy" confirmed $
              runGatedPulumiApply gate (SesStack.destroyAwsSesStack repoRoot destroyOutputIsQuiet)
        )
    PulumiAwsSesMigrateBackend planOptions ->
      runPlanWithOptions
        planOptions
        (buildPulumiExecutionPlan "aws-ses-migrate-backend" False)
        (\_ -> runGatedPulumiApply gate (SesStack.migrateAwsSesStackBackend repoRoot))
    PulumiPruneCorruptCheckpoint target confirmed ->
      runGatedPulumiApply gate (runPruneCorruptCheckpoint repoRoot target confirmed)

-- | Sprint 4.77: @--yes@ on the four @aws stack \<stack\> destroy@ verbs now
-- gates the destroy, in the shape 'runPruneCorruptCheckpoint' below has always
-- used.
--
-- The flag was parsed as @confirmed@ with help text "Skip confirmation
-- prompts", renamed @summary@ at dispatch, wildcarded by three of the four
-- sinks, and consumed by the fourth (@aws-ses@) as a **quietness** selector.
-- Omitting it was therefore byte-identical to passing it: a surface
-- advertising a safety property it did not have. These commands are
-- deliberately non-interactive (see @CLAUDE.md@), so the fix is not a prompt —
-- it is making the flag load-bearing, so the flag and the effect agree.
--
-- @--dry-run@ is unaffected: the gate lives inside the apply closure, so a plan
-- still renders without @--yes@.
requireDestroyConfirmation :: String -> Bool -> IO ExitCode -> IO ExitCode
requireDestroyConfirmation commandName confirmed destroy
  | confirmed = destroy
  | otherwise = do
      writeDiagnosticLine
        ( "Refusing to destroy without confirmation: `"
            ++ commandName
            ++ "` deletes live AWS resources. This command is non-interactive by "
            ++ "design, so `--yes` IS the confirmation rather than a way to skip "
            ++ "one. Re-run with --yes, or use --dry-run to see the plan."
        )
      pure (ExitFailure 1)

-- | Sprint 4.77: the stack destroys run under the lifecycle-local quiet path.
--
-- This was previously the @--yes@ flag's second, undeclared job at the
-- @aws-ses@ sink (@| summary = pulumiLoginQuiet@). Confirmation and output
-- verbosity are unrelated decisions, and threading one value through both is
-- how the flag came to have an observable effect that had nothing to do with
-- what its help text said. Naming the constant separates them; the value is the
-- one every automation call site already passed.
destroyOutputIsQuiet :: Bool
destroyOutputIsQuiet = True

-- | Sprint 7.22: clear a genuinely-corrupt per-run encrypted Pulumi
-- checkpoint via 'pruneCorruptPerRunCheckpoint' (which observes first and
-- refuses to prune a valid checkpoint). Requires @--yes@.
runPruneCorruptCheckpoint :: FilePath -> PerRunPruneTarget -> Bool -> IO ExitCode
runPruneCorruptCheckpoint repoRoot target confirmed
  | not confirmed = do
      writeDiagnosticLine
        ( "Refusing to prune the "
            ++ pruneTargetStackName target
            ++ " per-run checkpoint without confirmation. Re-run with --yes."
        )
      pure (ExitFailure 1)
  | otherwise = do
      result <-
        pruneCorruptPerRunCheckpoint
          repoRoot
          (StackName (Text.pack (pruneTargetStackName target)))
      case result of
        Right message -> do
          writeOutputLine (pruneTargetStackName target ++ ": " ++ message)
          pure ExitSuccess
        Left err -> do
          writeDiagnosticLine err
          pure (ExitFailure 1)

pruneTargetStackName :: PerRunPruneTarget -> String
pruneTargetStackName target = case target of
  PrunePerRunEks -> awsEksTestStackName
  PrunePerRunSubzone -> awsEksSubzoneStackName
  PrunePerRunTest -> awsTestStackName

runGatedPulumiApply :: IO VaultGateOutcome -> IO ExitCode -> IO ExitCode
runGatedPulumiApply gate action = do
  outcome <- gate
  case outcome of
    VaultGateProceed -> action
    VaultGateRefuse message -> do
      writeDiagnosticLine message
      pure (ExitFailure 1)

probePulumiVaultGate :: FilePath -> IO VaultGateOutcome
probePulumiVaultGate repoRoot = do
  testGate <- lookupEnv "PRODBOX_TEST_PULUMI_VAULT_GATE"
  case testGate of
    Just "allow" -> pure VaultGateProceed
    _ -> do
      settingsResult <- validateAndLoadSettings repoRoot
      case settingsResult of
        Left err ->
          pure
            ( VaultGateRefuse
                ( "Blocked: could not load the sealed deployment context for the Vault gate: "
                    ++ err
                )
            )
        Right settings ->
          vaultGateOutcome
            <$> vaultSealStatus
              (vaultAddressForDeploymentContext (validatedDeploymentContext settings))

buildPulumiExecutionPlan :: String -> Bool -> Plan String
buildPulumiExecutionPlan commandName confirmed =
  buildPlan id (renderPulumiPlan commandName confirmed)

renderPulumiPlan :: String -> Bool -> String
renderPulumiPlan commandName confirmed =
  unlines
    [ "PULUMI_PLAN"
    , "COMMAND=" ++ commandName
    , "CONFIRMED=" ++ if confirmed then "true" else "false"
    ]

withEphemeralPulumiStack :: FilePath -> String -> (EphemeralPulumiStack -> IO value) -> IO value
withEphemeralPulumiStack parentDir stackPrefix action = do
  createDirectoryIfMissing True parentDir
  bracketOnError
    (createEphemeralPulumiStack parentDir stackPrefix)
    cleanupEphemeralPulumiStack
    (\stack -> finally (action stack) (cleanupEphemeralPulumiStack stack))

writeEphemeralPulumiOutputs :: EphemeralPulumiStack -> Map String String -> IO ()
writeEphemeralPulumiOutputs stack outputs =
  BL8.writeFile
    (ephemeralPulumiOutputsPath stack)
    ( encode
        ( object
            [ Key.fromString "stack_name" .= ephemeralPulumiStackName stack
            , Key.fromString "outputs" .= outputs
            ]
        )
    )

readEphemeralPulumiOutputs :: EphemeralPulumiStack -> IO (Either String EphemeralPulumiOutputs)
readEphemeralPulumiOutputs stack = do
  contents <- BL8.readFile (ephemeralPulumiOutputsPath stack)
  pure $
    case eitherDecode contents of
      Left err -> Left ("failed to parse ephemeral Pulumi outputs: " ++ err)
      Right value -> decodeEphemeralPulumiOutputs value

createEphemeralPulumiStack :: FilePath -> String -> IO EphemeralPulumiStack
createEphemeralPulumiStack parentDir stackPrefix = do
  (tempPath, handle) <- openTempFile parentDir (stackPrefix ++ "-stack-")
  hClose handle
  removeFile tempPath
  createDirectoryIfMissing True tempPath
  pure
    EphemeralPulumiStack
      { ephemeralPulumiStackName = takeFileName tempPath
      , ephemeralPulumiStackRoot = tempPath
      , ephemeralPulumiOutputsPath = tempPath </> "stack-outputs.json"
      }
 where
  takeFileName = reverse . takeWhile (/= '/') . reverse

cleanupEphemeralPulumiStack :: EphemeralPulumiStack -> IO ()
cleanupEphemeralPulumiStack stack = do
  exists <- doesDirectoryExist (ephemeralPulumiStackRoot stack)
  if exists
    then removePathForcibly (ephemeralPulumiStackRoot stack)
    else pure ()

decodeEphemeralPulumiOutputs :: Value -> Either String EphemeralPulumiOutputs
decodeEphemeralPulumiOutputs (Object obj) = do
  stackName <- requireStringField obj "stack_name"
  outputsValue <- requireObjectField obj "outputs"
  outputPairs <- traverse toOutputPair (KeyMap.toList outputsValue)
  pure
    EphemeralPulumiOutputs
      { ephemeralOutputsStackName = stackName
      , ephemeralOutputsValues = Map.fromList outputPairs
      }
 where
  toOutputPair (key, String value) = Right (Key.toString key, Text.unpack value)
  toOutputPair (key, _) = Left ("output `" ++ show key ++ "` must be a JSON string")
decodeEphemeralPulumiOutputs _ = Left "ephemeral Pulumi outputs must be a JSON object"

requireStringField :: KeyMap.KeyMap Value -> String -> Either String String
requireStringField obj fieldName =
  case KeyMap.lookup (Key.fromString fieldName) obj of
    Just (String value) -> Right (Text.unpack value)
    _ -> Left ("missing string field `" ++ fieldName ++ "`")

requireObjectField :: KeyMap.KeyMap Value -> String -> Either String (KeyMap.KeyMap Value)
requireObjectField obj fieldName =
  case KeyMap.lookup (Key.fromString fieldName) obj of
    Just (Object value) -> Right value
    _ -> Left ("missing object field `" ++ fieldName ++ "`")
