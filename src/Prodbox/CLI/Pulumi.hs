{-# LANGUAGE OverloadedStrings #-}

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
  ( AdoptableLegacyStack
  , PerRunPruneTarget (..)
  , Plan
  , PulumiCommand (..)
  , buildPlan
  , runPlanWithOptions
  )
import Prodbox.CLI.Output (writeDiagnosticLine, writeOutputLine)
import Prodbox.Config.Basics (UnencryptedBasics (..))
import Prodbox.ControlPlane.LegacyAdoptionCompositionRoot
  ( LegacyAdoptionCompositionError
  , maximumLegacyAdoptionConfirmationSeconds
  , renderLegacyAdoptionCompositionError
  , withProductionLegacyAdoption
  )
import Prodbox.ControlPlane.LegacyAdoptionManifestRepository
  ( AdoptedCleanupOwnership
  , adoptedCleanupOwnershipEntryIdentities
  , adoptedCleanupOwnershipScope
  , adoptedCleanupOwnershipStackKey
  , adoptedCleanupOwnershipView
  )
import Prodbox.Infra.AwsEksSubzoneStack qualified as SubzoneStack
import Prodbox.Infra.AwsEksTestStack qualified as EksStack
import Prodbox.Infra.AwsSesStack qualified as SesStack
import Prodbox.Infra.AwsStackRepair (runAwsNetworkPurge, runAwsStackDiff)
import Prodbox.Infra.AwsTestStack qualified as TestStack
import Prodbox.Infra.StackOutputs (StackName (..))
import Prodbox.Lifecycle.Authority.AdminAction
  ( RunnerRole (AdminActionRunner)
  )
import Prodbox.Lifecycle.LiveResidue
  ( awsEksSubzoneStackName
  , awsEksTestStackName
  , awsTestStackName
  , pruneCorruptPerRunCheckpoint
  )
import Prodbox.Lifecycle.Teardown.LegacyAdoptionLane
  ( adoptableLegacyStackKey
  , adoptableLegacyStackName
  , applyConfirmedLegacyAdoption
  , renderLegacyAdoptionCandidatePlan
  , renderLegacyAdoptionLaneError
  , renderedLegacyAdoptionDigest
  , renderedLegacyAdoptionDocument
  )
import Prodbox.Lifecycle.Teardown.LegacyAdoptionPlan
  ( AdminLegacyAdoptionPermitRequest (..)
  , LegacyAdoptionPlanDigestRefusal (LegacyAdoptionPlanDigestMalformed)
  , legacyAdoptionExpectedFamily
  , mkLegacyAdoptionPlanDigest
  )
import Prodbox.Lifecycle.Teardown.Model
  ( CleanupSurfaceWitness (ExplicitPerRunSurface)
  , DurableObservationRunScope (DurableObservationRunScope)
  , evidenceDurableRunScope
  )
import Prodbox.Lifecycle.Teardown.Observation
  ( ObservedResourceIdentity (ObservedResourceIdentity)
  )
import Prodbox.Lifecycle.Teardown.OwnershipManifest
  ( LegacyAdoptionPlanDigest
  , OwnershipManifestDecisionView (..)
  , legacyAdoptionPlanDigestText
  )
import Prodbox.Settings (loadUnencryptedBasics)
import Prodbox.Vault.Client
  ( VaultAddress (..)
  , vaultSealStatus
  )
import Prodbox.Vault.Gate
  ( VaultGateOutcome (..)
  , vaultGateOutcome
  )
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
    PulumiStackDiff target -> runAwsStackDiff repoRoot target
    PulumiEksPurgeDependents mode -> runAwsNetworkPurge repoRoot mode
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
    PulumiAdoptLegacyPlan stack -> runAdoptLegacyPlan repoRoot stack
    PulumiAdoptLegacyApply stack digest confirmed ->
      runAdoptLegacyApply repoRoot stack digest confirmed

-- | Render the bounded adoption candidate plan and its digest.
--
-- Read-only in the strongest sense available here: it reaches AWS only through
-- the Provider\'s closed read-only intent vocabulary at the adoption dispatch
-- purpose, which admits no mutation, and it mints no permit and commits
-- nothing. The digest it prints is taken over the exact document it prints, so
-- what the operator confirms later is these bytes and not a summary of them.
runAdoptLegacyPlan :: FilePath -> AdoptableLegacyStack -> IO ExitCode
runAdoptLegacyPlan repoRoot stack = do
  composed <-
    withProductionLegacyAdoption repoRoot stack $ \sources request -> do
      rendered <-
        renderLegacyAdoptionCandidatePlan sources ExplicitPerRunSurface request
      case rendered of
        Left err -> do
          writeDiagnosticLine
            (Text.unpack (renderLegacyAdoptionLaneError err))
          pure (ExitFailure 1)
        Right plan -> do
          writeOutputLine (Text.unpack (renderedLegacyAdoptionDocument plan))
          writeOutputLine ""
          writeOutputLine
            ( "PLAN_DIGEST="
                ++ Text.unpack
                  ( legacyAdoptionPlanDigestText
                      (renderedLegacyAdoptionDigest plan)
                  )
            )
          writeOutputLine
            ( "Confirm within "
                ++ show maximumLegacyAdoptionConfirmationSeconds
                ++ "s of the apply run's own observation: `prodbox aws stack "
                ++ Text.unpack (adoptableLegacyStackName stack)
                ++ " adopt-legacy apply --plan-digest <digest> --yes`."
            )
          pure ExitSuccess
  either compositionFailure pure composed

-- | Adopt the family under the operator\'s confirmed digest.
--
-- The digest is the authorization and the re-observation is what gives it
-- meaning: the lane renders the plan again from a fresh read of the world and
-- refuses when the operator\'s digest names a different one.
runAdoptLegacyApply
  :: FilePath -> AdoptableLegacyStack -> Text.Text -> Bool -> IO ExitCode
runAdoptLegacyApply repoRoot stack rawDigest confirmed
  | not confirmed = do
      writeDiagnosticLine
        ( "Refusing to adopt the "
            ++ Text.unpack (adoptableLegacyStackName stack)
            ++ " family without confirmation: this commits a durable ownership "
            ++ "record that later cleanup treats as authority over the named "
            ++ "resources. Re-run with --yes."
        )
      pure (ExitFailure 1)
  | otherwise = case mkLegacyAdoptionPlanDigest rawDigest of
      -- Admitted before any session is opened, so a transcription error is
      -- reported as one instead of as a plan that no longer matches.
      Left (LegacyAdoptionPlanDigestMalformed value) -> do
        writeDiagnosticLine
          ( "--plan-digest is not a candidate-plan digest: `"
              ++ Text.unpack value
              ++ "` is not 64 lowercase hexadecimal characters. Re-run "
              ++ "`adopt-legacy plan` and copy the PLAN_DIGEST line."
          )
        pure (ExitFailure 1)
      Right digest -> do
        composed <-
          withProductionLegacyAdoption repoRoot stack $ \sources request -> do
            adopted <-
              applyConfirmedLegacyAdoption
                sources
                ExplicitPerRunSurface
                request
                (permitRequestFor stack digest)
            case adopted of
              Left err -> do
                writeDiagnosticLine
                  (Text.unpack (renderLegacyAdoptionLaneError err))
                pure (ExitFailure 1)
              Right ownership -> do
                mapM_ writeOutputLine (renderAdoptedOwnership stack ownership)
                pure ExitSuccess
        either compositionFailure pure composed

-- | The operator\'s submission. The nonce is derived from the digest rather
-- than freshly generated, because a nonce exists so a replay can be recognized
-- as the same permit: re-running the same confirmation is the same permit, and
-- a per-invocation value would make every retry a different one.
permitRequestFor
  :: AdoptableLegacyStack
  -> LegacyAdoptionPlanDigest
  -> AdminLegacyAdoptionPermitRequest
permitRequestFor stack digest =
  AdminLegacyAdoptionPermitRequest
    { adminLegacyPermitRequestAudience = AdminActionRunner
    , adminLegacyPermitRequestStackKey = adoptableLegacyStackKey stack
    , adminLegacyPermitRequestPlanDigest = digest
    , adminLegacyPermitRequestNonce =
        "legacy-adoption:"
          <> adoptableLegacyStackName stack
          <> ":"
          <> legacyAdoptionPlanDigestText digest
    }

-- | What the adoption recorded, read back from the receipt rather than from
-- what was sent. The per-key identities are the allowlist a later
-- desired-absence decision consumes; printing them is what makes the record
-- auditable outside the process that wrote it.
renderAdoptedOwnership
  :: AdoptableLegacyStack -> AdoptedCleanupOwnership -> [String]
renderAdoptedOwnership stack ownership =
  [ "ADOPTED_STACK=" ++ show (adoptedCleanupOwnershipStackKey ownership)
  , -- The scope is the coordinate the receipt is keyed under, so an operator
    -- reading this line can find the object a later cleanup will read.
    "ADOPTED_RUN_SCOPE="
      ++ Text.unpack
        (runScopeText (evidenceDurableRunScope (adoptedCleanupOwnershipScope ownership)))
  , "ADOPTED_PURPOSE=" ++ purposeLine
  ]
    ++ [ "ADOPTED_IDENTITIES="
           ++ show key
           ++ " "
           ++ unwords [Text.unpack value | ObservedResourceIdentity value <- identities]
       | key <- legacyAdoptionExpectedFamily (adoptableLegacyStackKey stack)
       , Just identities <- [adoptedCleanupOwnershipEntryIdentities key ownership]
       ]
 where
  runScopeText (DurableObservationRunScope value) = value

  purposeLine = case adoptedCleanupOwnershipView ownership of
    OwnershipManifestDecisionComplete purpose provenance version ->
      show purpose
        ++ " provenance="
        ++ show provenance
        ++ " version="
        ++ show version
    -- Unreachable through this lane: the repository mints cleanup ownership
    -- only from a byte-exact independent read-back. Named rather than
    -- wildcarded so a later widening of the evidence type fails here.
    OwnershipManifestDecisionObservation observation -> show observation

compositionFailure :: LegacyAdoptionCompositionError -> IO ExitCode
compositionFailure err = do
  writeDiagnosticLine (renderLegacyAdoptionCompositionError err)
  pure (ExitFailure 1)

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
      -- The address comes from the Tier-0 floor, which is readable while Vault is
      -- sealed. The settings loader resolves the in-force config through the
      -- Lifecycle Authority, which needs an unsealed Vault, so asking it first
      -- turned the one case this gate exists to name ("Vault is sealed") into a
      -- failure to load the context the gate needed to ask.
      basicsResult <- loadUnencryptedBasics repoRoot
      case basicsResult of
        Left err ->
          pure
            ( VaultGateRefuse
                ( "Blocked: could not read the sealed-Vault floor for the Vault gate: "
                    ++ err
                )
            )
        Right basics ->
          vaultGateOutcome
            <$> vaultSealStatus (VaultAddress (basicsVaultAddress basics))

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
