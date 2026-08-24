{-# LANGUAGE OverloadedStrings #-}

-- | Installed, qualification-only composition for the recover-to-clean
-- cascade.  The public @cluster delete --cascade@ writer remains outside this
-- module until Standard-P evidence authorizes activation; this runner is
-- reachable only through the dedicated destructive integration suite.
module Prodbox.Test.CascadeQualification
  ( CascadeQualificationOutcome
  , cascadeQualificationRunId
  , cascadeQualificationLifecycleResult
  , cascadeQualificationEvidenceDigest
  , cascadeQualificationEvidencePath
  , runCascadeQualificationCandidate
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.Bifunctor (first)
import Data.ByteString qualified as ByteString
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import Data.Time.Clock (UTCTime, getCurrentTime)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.CLI.Rke2
  ( MinioImageSource (MinioBootstrapPublic)
  , ensureInternalControlPlaneChartReady
  , ensureMinioRuntime
  , ensureVaultRuntime
  )
import Prodbox.Config.Basics (UnencryptedBasics (basicsClusterId))
import Prodbox.Config.ComponentGraph (componentIdForChartName)
import Prodbox.Config.FloorDhall (loadUnencryptedBasics)
import Prodbox.Config.OrdinaryTeardownRecovery
  ( OrdinaryTeardownTargetAgent (OrdinaryTeardownWithTargetAgent)
  )
import Prodbox.Config.OrdinaryTeardownRepair
  ( RecoveryPlatformComponent (..)
  )
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller (LifecycleAuthorityOperator)
  )
import Prodbox.ControlPlane.LifecycleAuthorityRestoreProduction
  ( mkLifecycleAuthorityAdmissionWait
  )
import Prodbox.ControlPlane.RegisteredStackCreationSubmitter
  ( homeLinuxRke2FoundationId
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupRunId
  , cleanupDigestText
  , cleanupRunIdText
  , mkCleanupOwnerId
  , mkCleanupRunId
  )
import Prodbox.Lifecycle.CleanupRunEntry
  ( LifecycleCleanupResult
  , lifecycleCleanupResultSucceeded
  )
import Prodbox.Lifecycle.DnsRecord (mkHostedZoneId)
import Prodbox.Lifecycle.HostCleanupCompositionRoot
  ( HostCleanupCompositionInputs (..)
  )
import Prodbox.Lifecycle.HostCleanupIntent (mkHostTerminalPermitId)
import Prodbox.Lifecycle.Teardown.CascadeCandidate.Internal
  ( CascadeCandidateEnvironment (..)
  , CascadeCandidateInputs (..)
  , CascadeCandidateOutcome (..)
  , renderCascadeCandidateError
  , runCascadeCandidate
  )
import Prodbox.Lifecycle.Teardown.CloudRuntimeProduction
  ( mkEksDrainLeaseSeconds
  )
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (..)
  , AwsRegion (..)
  , AwsScope (..)
  )
import Prodbox.Lifecycle.Teardown.RecoveryRepairProduction
  ( mkSubstrateApiWait
  )
import Prodbox.Lifecycle.Teardown.Registry qualified as Registry
import Prodbox.Lifecycle.Teardown.RetainedInventory
  ( RetainedNameBinding
  , mkRetainedNameBinding
  )
import Prodbox.Result (Result (..))
import Prodbox.Settings
  ( ValidatedCoordinates (..)
  , ValidatedSettings
  , renderConfigDhall
  , validateAndLoadSettings
  , validatedConfig
  , validatedCoordinates
  , validatedResourcePlan
  )
import Prodbox.Settings.Coordinate
  ( route53ZoneIdText
  , s3BucketNameText
  )
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  )
import Prodbox.Substrate (Substrate (SubstrateHomeLocal))
import Prodbox.Test.Qualification.SourceIdentity
  ( SourceIdentity
  , sourceManifestDigest
  )
import Prodbox.Test.Qualification.SourceManifest (captureSourceIdentity)
import Prodbox.Test.Qualification.TeardownCounterexample
  ( FrozenCompositionIdentity (..)
  , FrozenSourceIdentity (..)
  , FrozenTeardownCounterexample
  , ReplacementTeardownResult
  , TeardownTraceFixture (CanonicalTeardownTrace)
  , canonicalTeardownRecoveryInterpreter
  , frozenTeardownArtifactDigest
  , frozenTeardownCausalProfile
  , frozenTeardownExternalStateRows
  , frozenTeardownFixtureId
  , frozenTeardownInterruptionSchedule
  , frozenTeardownProductionProfile
  , frozenTeardownReplacementIdentity
  , frozenTeardownSupersededIdentity
  , loadTeardownCounterexampleFixture
  , runTeardownRecoveryOracle
  , supersededGlobalCopyOracle
  , teardownArtifactDigestText
  , teardownFixtureIdText
  )
import Prodbox.Tls.CertScope (fqdnText)
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Error (tryIOError)

data CascadeQualificationOutcome = CascadeQualificationOutcome
  { internalQualificationRunId :: !CleanupRunId
  , internalQualificationLifecycleResult :: !LifecycleCleanupResult
  , internalQualificationEvidenceDigest :: !Text
  , internalQualificationEvidencePath :: !FilePath
  }

cascadeQualificationRunId :: CascadeQualificationOutcome -> Text
cascadeQualificationRunId = cleanupRunIdText . internalQualificationRunId

cascadeQualificationLifecycleResult
  :: CascadeQualificationOutcome -> LifecycleCleanupResult
cascadeQualificationLifecycleResult = internalQualificationLifecycleResult

cascadeQualificationEvidenceDigest :: CascadeQualificationOutcome -> Text
cascadeQualificationEvidenceDigest = internalQualificationEvidenceDigest

cascadeQualificationEvidencePath :: CascadeQualificationOutcome -> FilePath
cascadeQualificationEvidencePath = internalQualificationEvidencePath

-- | Drive one named qualification cycle.  The cycle identifier is part of
-- every durable identity, so restarting the same cycle resumes it while the
-- second consecutive cycle must use a distinct identifier.
runCascadeQualificationCandidate
  :: FilePath
  -> [(String, String)]
  -> Text
  -> IO (Either String CascadeQualificationOutcome)
runCascadeQualificationCandidate repoRoot environment cycleLabel = do
  startedAt <- getCurrentTime
  settingsResult <- validateAndLoadSettings repoRoot
  basicsResult <- loadUnencryptedBasics repoRoot
  sourceResult <- captureSourceIdentity repoRoot []
  fixtureResult <- loadTeardownCounterexampleFixture repoRoot CanonicalTeardownTrace
  oracleResult <-
    case fixtureResult of
      Left _ -> pure Nothing
      Right fixture ->
        Just <$> runTeardownRecoveryOracle fixture (canonicalTeardownRecoveryInterpreter fixture)
  case (settingsResult, basicsResult, sourceResult, fixtureResult, oracleResult) of
    (Left err, _, _, _, _) -> pure (Left ("load qualification settings: " ++ err))
    (_, Left err, _, _, _) -> pure (Left ("load qualification Tier-0 floor: " ++ err))
    (_, _, Left err, _, _) -> pure (Left ("capture qualification source identity: " ++ show err))
    (_, _, _, Left err, _) -> pure (Left ("load teardown counterexample: " ++ show err))
    (_, _, _, _, Just (Left err)) -> pure (Left ("run teardown counterexample oracle: " ++ show err))
    (_, _, _, _, Nothing) -> pure (Left "the teardown counterexample oracle was not constructed")
    (Right settings, Right basics, Right sourceIdentity, Right fixture, Just (Right oracle)) ->
      case qualificationComposition repoRoot environment cycleLabel settings basics of
        Left err -> pure (Left err)
        Right (runId, inputs, candidateEnvironment, retainedBinding) -> do
          -- The candidate's terminal node uninstalls the local cluster, so
          -- bind the immutable running-image inventory before that mutation.
          -- Capturing afterward would either fail to reach Kubernetes or,
          -- worse, identify a subsequently rebuilt deployment.
          imageInventoryResult <- observeComponentImageInventory repoRoot environment
          case imageInventoryResult of
            Left err -> pure (Left err)
            Right imageInventory -> do
              driven <- runCascadeCandidate inputs candidateEnvironment
              case driven of
                Left err -> pure (Left (renderCascadeCandidateError err))
                Right candidateOutcome -> do
                  completedAt <- getCurrentTime
                  artifact <-
                    writeQualificationEvidence
                      repoRoot
                      cycleLabel
                      runId
                      startedAt
                      completedAt
                      sourceIdentity
                      settings
                      retainedBinding
                      fixture
                      oracle
                      imageInventory
                      candidateOutcome
                  pure $ do
                    (artifactPath, artifactDigest) <- artifact
                    Right
                      CascadeQualificationOutcome
                        { internalQualificationRunId = runId
                        , internalQualificationLifecycleResult =
                            cascadeCandidateOutcomeLifecycleResult candidateOutcome
                        , internalQualificationEvidenceDigest = artifactDigest
                        , internalQualificationEvidencePath = artifactPath
                        }

qualificationComposition
  :: FilePath
  -> [(String, String)]
  -> Text
  -> ValidatedSettings
  -> UnencryptedBasics
  -> Either
       String
       ( CleanupRunId
       , CascadeCandidateInputs
       , CascadeCandidateEnvironment
       , RetainedNameBinding
       )
qualificationComposition repoRoot environment cycleLabel settings basics = do
  runId <-
    first
      Text.unpack
      (mkCleanupRunId ("cascade-qualification-" <> cycleLabel))
  owner <-
    first
      Text.unpack
      (mkCleanupOwnerId ("cascade-qualification-owner-" <> cycleLabel))
  terminalPermit <-
    first
      show
      (mkHostTerminalPermitId ("cascade-qualification-permit-" <> cycleLabel))
  apiWait <- first Text.unpack (mkSubstrateApiWait 120 5_000_000)
  admissionWait <-
    first Text.unpack (mkLifecycleAuthorityAdmissionWait 180 5_000_000)
  drainLease <- first show (mkEksDrainLeaseSeconds 900)
  stateBucket <-
    requireCoordinate
      "pulumi_state_backend.bucket_name"
      (s3BucketNameText <$> coordinatePulumiBackendBucket coordinates)
  captureBucket <-
    requireCoordinate
      "ses.capture_bucket"
      (s3BucketNameText <$> coordinateSesCaptureBucket coordinates)
  senderDomain <-
    requireCoordinate
      "ses.sender_domain"
      (fqdnText <$> coordinateSesSenderDomain coordinates)
  binding <-
    first
      show
      ( mkRetainedNameBinding
          stateBucket
          captureBucket
          senderDomain
          Registry.awsEksProvisionedClusterName
      )
  dnsZone <-
    traverse
      (first show . mkHostedZoneId . route53ZoneIdText)
      (coordinateAwsSubstrateZoneId coordinates)
  let composition =
        HostCleanupCompositionInputs
          { hostCleanupRepositoryRoot = repoRoot
          , hostCleanupCaller = LifecycleAuthorityOperator
          , hostCleanupRecoveryTargetAgent = OrdinaryTeardownWithTargetAgent
          , hostCleanupSubstrateApiWait = apiWait
          , hostCleanupAdmissionWait = admissionWait
          , hostCleanupPlatformReconciler = reconcilePlatform settings
          , hostCleanupChartReconciler = reconcileChart settings
          }
      inputs =
        CascadeCandidateInputs
          { cascadeCandidateRunId = runId
          , cascadeCandidateOwner = owner
          , cascadeCandidateFoundation =
              homeLinuxRke2FoundationId (basicsClusterId basics)
          , cascadeCandidateAwsDnsZone = dnsZone
          , cascadeCandidateTerminalPermitId = terminalPermit
          , cascadeCandidateDeclaredLeaseMicros = declaredLeaseMicros
          }
      candidateEnvironment =
        CascadeCandidateEnvironment
          { cascadeCandidateComposition = composition
          , cascadeCandidateRetainedNameBinding = binding
          , cascadeCandidateKubectlPath = "kubectl"
          , cascadeCandidateKubectlEnvironment = environment
          , cascadeCandidateKubectlWorkingDirectory = Just repoRoot
          , cascadeCandidateDrainLease = drainLease
          , cascadeCandidateLeaseWindowMicros = activeLeaseMicros
          , cascadeCandidateReportRetentionMicros = reportRetentionMicros
          }
  Right (runId, inputs, candidateEnvironment, binding)
 where
  coordinates = validatedCoordinates settings

  reconcilePlatform currentSettings platform =
    exitAsResult ("reconcile recovery platform " <> Text.pack (show platform))
      =<< case platform of
        RecoveryPlatformMinio ->
          ensureMinioRuntime
            repoRoot
            currentSettings
            SubstrateHomeLocal
            MinioBootstrapPublic
        RecoveryPlatformVault -> ensureVaultRuntime repoRoot currentSettings

  reconcileChart currentSettings chartName =
    case componentIdForChartName chartName of
      Nothing ->
        pure
          (Left ("the recovery closure named an unknown chart `" <> Text.pack chartName <> "`"))
      Just component ->
        exitAsResult ("reconcile recovery chart " <> Text.pack chartName)
          =<< ensureInternalControlPlaneChartReady
            repoRoot
            currentSettings
            SubstrateHomeLocal
            component

observeComponentImageInventory
  :: FilePath -> [(String, String)] -> IO (Either String [Text])
observeComponentImageInventory repoRoot environment = do
  observed <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            [ "get"
            , "pods"
            , "--all-namespaces"
            , "-o"
            , "jsonpath={range .items[*]}{range .status.containerStatuses[*]}{.name}{\"=\"}{.imageID}{\"\\n\"}{end}{end}"
            ]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just repoRoot
        }
  pure $ case observed of
    Failure err -> Left ("observe qualification component images: " ++ err)
    Success output -> case processExitCode output of
      ExitFailure code ->
        Left
          ( "observe qualification component images exited "
              ++ show code
              ++ ": "
              ++ processStderr output
          )
      ExitSuccess ->
        let rawLines = filter (not . Text.null) (Text.lines (Text.pack (processStdout output)))
            normalized = traverse normalizeComponentImageLine rawLines
         in case normalized of
              Left err -> Left err
              Right [] -> Left "qualification observed no running component image identities"
              Right values -> Right (nub (sort values))

normalizeComponentImageLine :: Text -> Either String Text
normalizeComponentImageLine raw =
  case Text.breakOn "=" raw of
    (component, referenceWithEquals)
      | Text.null component || Text.null referenceWithEquals -> malformed
      | otherwise ->
          let reference = Text.drop 1 referenceWithEquals
              (_, digestSuffix) = Text.breakOnEnd "sha256:" reference
              digest = Text.take 64 digestSuffix
           in if Text.length digest == 64 && Text.all isLowerHex digest
                then Right (component <> "=sha256:" <> digest)
                else malformed
 where
  malformed = Left ("qualification component image identity is not an immutable sha256: " ++ Text.unpack raw)
  isLowerHex character =
    character >= '0' && character <= '9' || character >= 'a' && character <= 'f'

writeQualificationEvidence
  :: FilePath
  -> Text
  -> CleanupRunId
  -> UTCTime
  -> UTCTime
  -> SourceIdentity
  -> ValidatedSettings
  -> RetainedNameBinding
  -> FrozenTeardownCounterexample
  -> ReplacementTeardownResult
  -> [Text]
  -> CascadeCandidateOutcome
  -> IO (Either String (FilePath, Text))
writeQualificationEvidence repoRoot cycleLabel runId startedAt completedAt sourceIdentity settings retainedBinding fixture oracle imageInventory candidateOutcome = do
  let artifactDirectory = repoRoot </> ".test-data" </> "qualification"
      artifactPath =
        artifactDirectory
          </> ("cascade-" ++ Text.unpack (Text.take 24 (sha256Text cycleLabel)) ++ ".evidence")
      result = cascadeCandidateOutcomeLifecycleResult candidateOutcome
      succeeded = lifecycleCleanupResultSucceeded result
      AwsScope (AwsAccountId awsAccount) (AwsRegion awsRegion) =
        cascadeCandidateOutcomeAwsScope candidateOutcome
      supersededIdentity = frozenTeardownSupersededIdentity fixture
      frozenReplacementIdentity = frozenTeardownReplacementIdentity fixture
      causalProfile = frozenTeardownCausalProfile fixture
      productionProfile = frozenTeardownProductionProfile fixture
      configDigest = sha256Text (Text.pack (renderConfigDhall (validatedConfig settings)))
      imageInventoryDigest = sha256Text (Text.unlines imageInventory)
      sourceDigest = sourceManifestDigest sourceIdentity
      graphDigest = cleanupDigestText (cascadeCandidateOutcomeGraphDigest candidateOutcome)
      descriptorDigest =
        cleanupDigestText (cascadeCandidateOutcomeDescriptorDigest candidateOutcome)
      normalizedEnvelopeMappingDigest =
        digestValue (causalProfile, productionProfile)
      authoredLoadFaultDigest =
        digestValue
          ( frozenTeardownExternalStateRows fixture
          , frozenTeardownInterruptionSchedule fixture
          , causalProfile
          , productionProfile
          )
      resourceEnvelopeDigest = digestValue (validatedResourcePlan settings)
      supersededResourceEnvelopeDigest = digestValue causalProfile
      supersededLoadFaultDigest =
        digestValue
          ( frozenTeardownExternalStateRows fixture
          , frozenTeardownInterruptionSchedule fixture
          , causalProfile
          )
      supersededInterpreterDigest =
        sha256Text
          ( frozenSourceDigest supersededIdentity
              <> "\NULlegacy-runNativeDeleteCascade/v1"
          )
      supersededPersistenceDigest =
        sha256Text
          ( frozenSourceDigest supersededIdentity
              <> "\NULlegacy-resource-registry/v1"
          )
      supersededCleanupSchemaDigest =
        sha256Text
          ( frozenSourceDigest supersededIdentity
              <> "\NULlegacy-cascade-report/v1"
          )
      replacementInterpreterDigest =
        sha256Text
          ( sourceDigest
              <> "\NULdescriptor-bound-cascade-dispatch/v2"
          )
      replacementPersistenceDigest =
        sha256Text
          ( sourceDigest
              <> "\NULcleanup-program-descriptor/v2\NULauthority-aggregate/v1"
          )
      replacementCleanupSchemaDigest =
        sha256Text
          ( sourceDigest
              <> "\NULcleanup-run-report/v1\NULcascade-complete-evidence/v1"
          )
      baseLines =
        [ "format_version=1"
        , "qualification_kind=typed-recover-to-clean-cascade"
        , "cycle=" <> cycleLabel
        , "control_plane_substrate=home-local"
        , "managed_target_substrate=aws"
        , "canonical_command=PRODBOX_TEST_CASCADE_QUALIFICATION_CYCLE="
            <> cycleLabel
            <> " prodbox test integration cascade-qualification --substrate aws"
        , "started_at=" <> Text.pack (show startedAt)
        , "completed_at=" <> Text.pack (show completedAt)
        , "aws_account=" <> awsAccount
        , "aws_region=" <> awsRegion
        , "cleanup_run_id=" <> cleanupRunIdText runId
        , "superseded_source_identity=" <> Text.pack (show (frozenCompositionSource supersededIdentity))
        , "superseded_generated_config_digest=" <> frozenCompositionGeneratedConfigDigest supersededIdentity
        , "superseded_component_images=" <> Text.pack (show (frozenCompositionImages supersededIdentity))
        , "superseded_topology_digest=" <> frozenCompositionTopologyDigest supersededIdentity
        , "superseded_wiring_digest=" <> frozenCompositionWiringDigest supersededIdentity
        , "superseded_resource_envelope_digest=" <> supersededResourceEnvelopeDigest
        , "superseded_load_fault_digest=" <> supersededLoadFaultDigest
        , "superseded_interpreter_digest=" <> supersededInterpreterDigest
        , "superseded_persistence_digest=" <> supersededPersistenceDigest
        , "superseded_cleanup_schema_digest=" <> supersededCleanupSchemaDigest
        , "replacement_source_identity=" <> Text.pack (show sourceIdentity)
        , "replacement_generated_config_digest=" <> configDigest
        , "replacement_component_image_inventory_digest=" <> imageInventoryDigest
        , "replacement_topology_digest=" <> graphDigest
        , "replacement_wiring_digest=" <> descriptorDigest
        , "replacement_resource_envelope_digest=" <> resourceEnvelopeDigest
        , "replacement_load_fault_digest=" <> authoredLoadFaultDigest
        , "replacement_interpreter_digest=" <> replacementInterpreterDigest
        , "replacement_persistence_digest=" <> replacementPersistenceDigest
        , "replacement_cleanup_schema_digest=" <> replacementCleanupSchemaDigest
        , "frozen_replacement_identity=" <> Text.pack (show frozenReplacementIdentity)
        , "normalized_envelope_mapping_digest=" <> normalizedEnvelopeMappingDigest
        , "causal_profile=" <> Text.pack (show causalProfile)
        , "production_profile=" <> Text.pack (show productionProfile)
        , "counterexample_id=" <> teardownFixtureIdText (frozenTeardownFixtureId fixture)
        , "counterexample_artifact_digest="
            <> teardownArtifactDigestText (frozenTeardownArtifactDigest fixture)
        , "counterexample_superseded_result="
            <> Text.pack (show (supersededGlobalCopyOracle fixture))
        , "counterexample_replacement_result=" <> Text.pack (show oracle)
        , "intended_retained_set=" <> Text.pack (show retainedBinding)
        , "aggregate_succeeded=" <> renderBool succeeded
        , "cleanup_residue_absent=" <> renderBool succeeded
        , "lifecycle_result=" <> Text.pack (show result)
        ]
          ++ map (("component_image=" <>) . escapeEvidenceLine) imageInventory
          ++ map
            (("fault_external_state=" <>) . escapeEvidenceLine . Text.pack . show)
            (frozenTeardownExternalStateRows fixture)
          ++ map
            (("fault_interruption=" <>) . escapeEvidenceLine . Text.pack . show)
            (frozenTeardownInterruptionSchedule fixture)
      artifactDigest = sha256Text (Text.unlines baseLines)
      artifactText = Text.unlines (baseLines ++ ["evidence_digest=" <> artifactDigest])
  created <- tryIOError (createDirectoryIfMissing True artifactDirectory)
  case created of
    Left err -> pure (Left ("create qualification evidence directory: " ++ show err))
    Right () -> do
      written <- tryIOError (TextIO.writeFile artifactPath artifactText)
      pure $ case written of
        Left err -> Left ("write qualification evidence: " ++ show err)
        Right () -> Right (artifactPath, artifactDigest)

frozenSourceDigest :: FrozenCompositionIdentity -> Text
frozenSourceDigest = frozenSourceManifestDigest . frozenCompositionSource

escapeEvidenceLine :: Text -> Text
escapeEvidenceLine = Text.replace "\n" "\\n" . Text.replace "\r" "\\r"

renderBool :: Bool -> Text
renderBool value = if value then "true" else "false"

digestValue :: (Show value) => value -> Text
digestValue = sha256Text . Text.pack . show

sha256Text :: Text -> Text
sha256Text =
  Text.pack
    . concatMap renderHexByte
    . ByteString.unpack
    . SHA256.hash
    . TextEncoding.encodeUtf8
 where
  renderHexByte byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits

requireCoordinate :: String -> Maybe Text -> Either String Text
requireCoordinate field value =
  case value of
    Nothing -> Left ("qualification requires `" ++ field ++ "`")
    Just coordinate -> Right coordinate

exitAsResult :: Text -> ExitCode -> IO (Either Text ())
exitAsResult label exitCode =
  pure $ case exitCode of
    ExitSuccess -> Right ()
    ExitFailure code ->
      Left (label <> " exited " <> Text.pack (show code))

declaredLeaseMicros :: Natural
declaredLeaseMicros = 15 * 60 * 1_000_000

activeLeaseMicros :: Natural
activeLeaseMicros = 30 * 60 * 1_000_000

reportRetentionMicros :: Natural
reportRetentionMicros = 30 * 24 * 60 * 60 * 1_000_000
