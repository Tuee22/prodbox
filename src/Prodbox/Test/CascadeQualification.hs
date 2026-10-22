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
  , cascadeQualificationAttempt
  , cascadeQualificationIdentityKey
  , cascadeQualificationCycleOutcome
  , cascadeQualificationCyclePassed
  , cascadeQualificationRecoveryOnly
  , cascadeQualificationLedgerEntries
  , cascadeQualificationLedgerTip
  , frozenFactLines
  , runCascadeQualificationCandidate
  , CascadeQualificationResumeMode (..)
  , qualificationCyclePurpose
  , cascadeQualificationResumeMode
  )
where

import Control.Exception (IOException, try)
import Control.Monad (void)
import Crypto.Hash.SHA256 qualified as SHA256
import Crypto.Random (getRandomBytes)
import Data.Bifunctor (first)
import Data.ByteString qualified as ByteString
import Data.List (nub, sort)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.IO qualified as TextIO
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.CLI.Rke2
  ( MinioImageSource (MinioBootstrapPublic)
  , ensureInternalControlPlaneChartReady
  , ensureMinioRuntime
  , ensureVaultRuntime
  , revokeHarnessLifecycleProviderCredentialWithEvidence
  )
import Prodbox.Config.Basics (UnencryptedBasics (basicsClusterId))
import Prodbox.Config.ComponentGraph (componentIdForChartName)
import Prodbox.Config.FloorDhall (loadUnencryptedBasics)
import Prodbox.Config.LocalRetainedRoot (LocalRetainedRootEntry (..), LocalRetainedRootError (..))
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
import Prodbox.Lifecycle.CredentialProvisioner.HarnessCredential
  ( HarnessCredentialRevocationEvidence
  , mkHarnessCredentialLineage
  )
import Prodbox.Lifecycle.DnsRecord (HostedZoneId, mkHostedZoneId)
import Prodbox.Lifecycle.HostCleanupCompositionRoot
  ( HostCleanupCompositionError (..)
  , HostCleanupCompositionInputs (..)
  , hostCleanupTerminalIntentStore
  , resolveHostCleanupTerminalComposition
  )
import Prodbox.Lifecycle.HostCleanupIntent
  ( HostCleanupIntentPhase (..)
  , hostCleanupIntentPhase
  , hostCleanupObservationEvidenceScope
  , hostCleanupRunId
  , hostCleanupScope
  , mkHostTerminalPermitId
  , observeHostCleanupIntent
  )
import Prodbox.Lifecycle.Teardown.CascadeCandidate.Internal
  ( CascadeCandidateEnvironment (..)
  , CascadeCandidateError (..)
  , CascadeCandidateHostResume
  , CascadeCandidateInputs (..)
  , CascadeCandidateOutcome (..)
  , CascadeCandidatePlanSummary (..)
  , cascadeCandidateHostResumeInputs
  , cascadeCandidateShapeSummary
  , observeCascadeCandidateHostResume
  , renderCascadeCandidateError
  , runCascadeCandidate
  , runCascadeCandidateHostResume
  )
import Prodbox.Lifecycle.Teardown.CloudRuntimeProduction
  ( derivedEksDrainLeaseSeconds
  , mkEksDrainLeaseSeconds
  )
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (..)
  , AwsRegion (..)
  , AwsScope (..)
  , evidenceAwsDnsZone
  )
import Prodbox.Lifecycle.Teardown.RecoveryRepairProduction
  ( mkSubstrateApiWait
  )
import Prodbox.Lifecycle.Teardown.Registry qualified as Registry
import Prodbox.Lifecycle.Teardown.ResourceScopeBindings
  ( InviteMailSelector (ValidationInviteDomain)
  , mkHomeDns01Scope
  , mkInviteMailScope
  , mkResourceScopeBindingsWithAudit
  , resourceScopeAuditRetainedNames
  )
import Prodbox.Lifecycle.Teardown.RetainedInventory
  ( RetainedNameBinding
  , mkRetainedNameBinding
  )
import Prodbox.PublicEdge (requireSubstrateCertScopeSet, resolveSubstrateHostedZoneId)
import Prodbox.Result (Result (..))
import Prodbox.Settings
  ( ValidatedCoordinates (..)
  , ValidatedSettings
  , renderConfigDhall
  , sesReceiveDomain
  , validateAndLoadSettings
  , validatedConfig
  , validatedCoordinates
  )
import Prodbox.Settings.Coordinate (dnsLabelText, route53ZoneIdText, s3BucketNameText)
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  )
import Prodbox.Substrate (Substrate (SubstrateAws, SubstrateHomeLocal))
import Prodbox.Test.CascadeQualificationCycle
  ( CycleEffects (..)
  , CyclePurpose (..)
  , CycleReport (..)
  , driveQualificationCycle
  )
import Prodbox.Test.CascadeQualificationLocal
  ( executableBinaryDigest
  , recaptureExecutableKey
  , recomputeLocalParts
  , renderLocalRecomputeError
  )
import Prodbox.Test.Qualification.CascadeCycleArtifact
  ( CascadeArtifactFields (..)
  , CycleLabel
  , cascadeArtifactFileName
  , cycleLabelText
  , mkCycleLabel
  , renderCascadeArtifact
  )
import Prodbox.Test.Qualification.CascadeCycleIdentity
  ( CompareOnlyParts (..)
  , CycleAnnotations
  , CycleIdentityParts (..)
  , IdentityKey
  , RecomputedLocalParts (..)
  , annotationsOf
  , canonicalKeyPolicy
  , identityKeyOfParts
  , identityKeyText
  , partsFromLocal
  , topologyWiringDigest
  )
import Prodbox.Test.Qualification.CascadeCycleLedger
  ( BegunRecord (..)
  , CycleFailureClass (FailedHistoricalRecovery)
  , CycleOutcome (..)
  , LedgerEntry (..)
  , LedgerRecord (..)
  , LedgerRefusal
  , labelDisposition
  , ledgerEntries
  , renderCycleOutcome
  , renderLedgerRefusal
  )
import Prodbox.Test.Qualification.CascadeCycleLedgerStore
  ( appendCycleRecord
  , cycleLedgerPath
  , mkQualificationResumeSnapshot
  , observeQualificationResumeSnapshot
  , persistQualificationResumeSnapshot
  , qualificationResumeBegun
  , qualificationResumeImages
  , readCycleLedger
  , renderLedgerStoreError
  )
import Prodbox.Test.Qualification.Evidence
  ( PublicEvidenceDigest
  , hashPublicEvidence
  , mkPublicEvidenceDigest
  , publicEvidenceDigestText
  )
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
import Prodbox.Tls.CertScope (certScopeSetDnsNames, fqdnText)
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Error (tryIOError)

data CascadeQualificationOutcome = CascadeQualificationOutcome
  { internalQualificationRunId :: !CleanupRunId
  , internalQualificationLifecycleResult :: !LifecycleCleanupResult
  , internalQualificationEvidenceDigest :: !Text
  , internalQualificationEvidencePath :: !FilePath
  , internalQualificationAttempt :: !Int
  , internalQualificationIdentityKey :: !IdentityKey
  , internalQualificationCycleOutcome :: !CycleOutcome
  , internalQualificationLedgerEntries :: !Int
  , internalQualificationLedgerTip :: !Text
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

-- | Which attempt of its label this cycle was.
cascadeQualificationAttempt :: CascadeQualificationOutcome -> Int
cascadeQualificationAttempt = internalQualificationAttempt

-- | The key of the deployment the cycle began on, as lowercase hexadecimal.
cascadeQualificationIdentityKey :: CascadeQualificationOutcome -> Text
cascadeQualificationIdentityKey = identityKeyText . internalQualificationIdentityKey

-- | How the cycle ended, as one word: @passed@, @source-drifted@, or
-- @failed-...@ with the class of failure.
cascadeQualificationCycleOutcome :: CascadeQualificationOutcome -> Text
cascadeQualificationCycleOutcome = renderCycleOutcome . internalQualificationCycleOutcome

-- | Whether the cycle qualifies: it ended in success and on the source it began
-- with. A cycle whose lifecycle succeeded but whose source moved does not.
cascadeQualificationCyclePassed :: CascadeQualificationOutcome -> Bool
cascadeQualificationCyclePassed outcome =
  internalQualificationCycleOutcome outcome == CyclePassed

cascadeQualificationRecoveryOnly :: CascadeQualificationOutcome -> Bool
cascadeQualificationRecoveryOnly outcome =
  internalQualificationCycleOutcome outcome == CycleFailed FailedHistoricalRecovery

-- | How many entries the ledger holds after this cycle closed.
cascadeQualificationLedgerEntries :: CascadeQualificationOutcome -> Int
cascadeQualificationLedgerEntries = internalQualificationLedgerEntries

-- | The ledger's tip after this cycle closed, to be recorded in the plan.
cascadeQualificationLedgerTip :: CascadeQualificationOutcome -> Text
cascadeQualificationLedgerTip = internalQualificationLedgerTip

qualificationCanonicalCommand :: Substrate -> CycleLabel -> Text
qualificationCanonicalCommand substrate label =
  "PRODBOX_TEST_CASCADE_QUALIFICATION_CYCLE="
    <> cycleLabelText label
    <> " prodbox test integration cascade-qualification"
    <> case substrate of
      SubstrateHomeLocal -> ""
      SubstrateAws -> " --substrate aws"

-- | Drive one named qualification cycle.  The cycle identifier is part of
-- every durable identity. Restarting a label recovers its cleanup; a new
-- qualification cycle requires a distinct identifier.
runCascadeQualificationCandidate
  :: FilePath
  -> [(String, String)]
  -> Substrate
  -> Text
  -> IO (Either String CascadeQualificationOutcome)
runCascadeQualificationCandidate repoRoot environment substrate rawLabel =
  case mkCycleLabel rawLabel of
    Left err -> pure (Left ("invalid qualification cycle label: " ++ show err))
    Right cycleLabel -> runLabelledCycle repoRoot environment substrate cycleLabel

-- | Admission hint only; it authorizes no cleanup or credential effect.
-- A registered predecessor bypasses fresh install, while an observed handoff
-- additionally bypasses every service prerequisite in the qualification body.
data CascadeQualificationResumeMode
  = QualificationFresh
  | QualificationRegistered
  | QualificationNative
  deriving (Eq, Show)

qualificationCyclePurpose :: CascadeQualificationResumeMode -> CyclePurpose
qualificationCyclePurpose mode = case mode of
  QualificationFresh -> QualifyNewRun
  QualificationRegistered -> RecoverExistingRun
  QualificationNative -> RecoverExistingRun

cascadeQualificationResumeMode
  :: FilePath -> Text -> IO (Either String CascadeQualificationResumeMode)
cascadeQualificationResumeMode repoRoot rawLabel = case mkCycleLabel rawLabel of
  Left err -> pure (Left ("invalid qualification cycle label: " <> show err))
  Right label -> fmap (fmap fst) (observeLabelledQualificationResume repoRoot label)

observeLabelledQualificationResume
  :: FilePath
  -> CycleLabel
  -> IO (Either String (CascadeQualificationResumeMode, Maybe CascadeCandidateHostResume))
observeLabelledQualificationResume repoRoot label = case qualificationRunIdFor label of
  Left detail -> pure (Left detail)
  Right runId -> do
    native <- observeCascadeCandidateHostResume repoRoot runId
    case native of
      Right (Just captured) -> pure (Right (QualificationNative, Just captured))
      Right Nothing -> do
        resolved <- resolveHostCleanupTerminalComposition repoRoot
        case resolved of
          Left err -> pure (Left (show err))
          Right local -> do
            active <- observeHostCleanupIntent (hostCleanupTerminalIntentStore local)
            pure $ case active of
              Left err -> Left ("the qualification host intent is unobservable: " <> show err)
              Right Nothing -> Right (QualificationFresh, Nothing)
              Right (Just intent)
                | hostCleanupRunId intent /= runId ->
                    Left
                      ( "finish the existing cascade run before starting another qualification label: "
                          <> Text.unpack (cleanupRunIdText (hostCleanupRunId intent))
                      )
                | otherwise -> case hostCleanupIntentPhase intent of
                    HostCleanupPrepared -> Right (QualificationRegistered, Nothing)
                    HostCleanupAuthorityAccepted -> Right (QualificationRegistered, Nothing)
                    HostCleanupTerminalArmed -> Right (QualificationRegistered, Nothing)
                    _ ->
                      Left
                        "the local cleanup tail has no independently observed credential-retired handoff; fresh bootstrap and credential installation are refused"
      Left err
        | missingBootstrapRoot err -> freshWithoutHistory
        | otherwise -> pure (Left (renderCascadeCandidateError err))
 where
  freshWithoutHistory = do
    snapshot <- observeQualificationResumeSnapshot repoRoot label
    ledger <- readCycleLedger (cycleLedgerPath repoRoot)
    pure $ case (snapshot, ledger) of
      (Left detail, _) -> Left detail
      (_, Left err) -> Left (renderLedgerStoreError err)
      (Right Nothing, Right history) | null (ledgerEntries history) -> Right (QualificationFresh, Nothing)
      _ ->
        Left
          "the recorded qualification history has no observable retained host root; a fresh bootstrap cannot replace its licensing evidence"

  missingBootstrapRoot err = case err of
    CascadeCandidateCompositionFailed
      (HostCleanupCompositionRetainedRootUnusable (LocalRetainedRootEntryMissing entry)) ->
        entry
          `elem` [ LocalRetainedRootDirectory
                 , LocalRetainedRootControlDirectory
                 , LocalRetainedRootMinioDirectory
                 , LocalRetainedRootVaultDirectory
                 , LocalRetainedRootEstablishmentMarker
                 ]
    _ -> False

qualificationRunIdFor :: CycleLabel -> Either String CleanupRunId
qualificationRunIdFor label = first Text.unpack (mkCleanupRunId ("cascade-qualification-" <> cycleLabelText label))

runNativeQualificationResume
  :: FilePath
  -> Substrate
  -> CycleLabel
  -> CascadeCandidateHostResume
  -> IO (Either String CascadeQualificationOutcome)
runNativeQualificationResume repoRoot substrate label native = do
  observed <- observeQualificationResumeSnapshot repoRoot label
  localResult <- recomputeLocalParts repoRoot
  fixtureResult <- loadTeardownCounterexampleFixture repoRoot CanonicalTeardownTrace
  case (observed, localResult, fixtureResult) of
    (Left detail, _, _) -> pure (Left detail)
    (Right Nothing, _, _) ->
      pure
        ( Left
            "the native qualification resume has no pre-uninstall named image capture; its historical evidence cannot be reconstructed from a rebuilt cluster"
        )
    (_, Left err, _) -> pure (Left (renderLocalRecomputeError err))
    (_, _, Left err) -> pure (Left ("load teardown counterexample: " <> show err))
    (Right (Just snapshot), Right local, Right fixture) -> do
      let begun = qualificationResumeBegun snapshot
          inputs = cascadeCandidateHostResumeInputs native
          images = qualificationResumeImages snapshot
          restored = do
            current <- qualificationIdentityParts local inputs images
            if current == begunParts begun
              then Right ()
              else
                Left
                  "the frozen qualification identity changed; the original cycle label cannot qualify a different source, config, resource envelope or program"
            names <-
              maybe
                (Left "the historical cascade has no sealed audit names")
                Right
                (resourceScopeAuditRetainedNames (cascadeCandidateResourceScopeBindings inputs))
            Right (current, names)
      case restored of
        Left detail -> pure (Left detail)
        Right (parts, names) -> do
          oracleResult <- runTeardownRecoveryOracle fixture (canonicalTeardownRecoveryInterpreter fixture)
          case oracleResult of
            Left err -> pure (Left ("run teardown counterexample oracle: " <> show err))
            Right oracle -> do
              startedAt <- getCurrentTime
              let context =
                    CycleContext
                      { contextRepoRoot = repoRoot
                      , contextPurpose = RecoverExistingRun
                      , contextLabel = label
                      , contextCanonicalCommand = qualificationCanonicalCommand substrate label
                      , contextStartedAt = startedAt
                      , contextRunId = cascadeCandidateRunId inputs
                      , contextParts = parts
                      , contextAnnotations = begunAnnotations begun
                      , contextConfigDigest = partsGeneratedConfig parts
                      , contextRetainedBinding = names
                      , contextFixture = fixture
                      , contextOracle = oracle
                      , contextImageInventory = images
                      , contextRunCandidate = first renderCascadeCandidateError <$> runCascadeCandidateHostResume native
                      }
              driven <-
                driveQualificationCycle (productionCycleEffects context) label parts (begunAnnotations begun)
              pure (outcomeOf context <$> driven)

runLabelledCycle
  :: FilePath
  -> [(String, String)]
  -> Substrate
  -> CycleLabel
  -> IO (Either String CascadeQualificationOutcome)
runLabelledCycle repoRoot environment substrate cycleLabel = do
  resumed <- observeLabelledQualificationResume repoRoot cycleLabel
  case resumed of
    Left detail -> pure (Left detail)
    Right (_, Just native) -> runNativeQualificationResume repoRoot substrate cycleLabel native
    Right (mode, Nothing) -> runConnectedLabelledCycle repoRoot environment substrate cycleLabel mode

runConnectedLabelledCycle
  :: FilePath
  -> [(String, String)]
  -> Substrate
  -> CycleLabel
  -> CascadeQualificationResumeMode
  -> IO (Either String CascadeQualificationOutcome)
runConnectedLabelledCycle repoRoot environment substrate cycleLabel mode = do
  startedAt <- getCurrentTime
  settingsResult <- validateAndLoadSettings repoRoot
  basicsResult <- loadUnencryptedBasics repoRoot
  localResult <- recomputeLocalParts repoRoot
  fixtureResult <- loadTeardownCounterexampleFixture repoRoot CanonicalTeardownTrace
  oracleResult <-
    case fixtureResult of
      Left _ -> pure Nothing
      Right fixture ->
        Just <$> runTeardownRecoveryOracle fixture (canonicalTeardownRecoveryInterpreter fixture)
  case (settingsResult, basicsResult, localResult, fixtureResult, oracleResult) of
    (Left err, _, _, _, _) -> pure (Left ("load qualification settings: " ++ err))
    (_, Left err, _, _, _) -> pure (Left ("load qualification Tier-0 floor: " ++ err))
    (_, _, Left err, _, _) -> pure (Left (renderLocalRecomputeError err))
    (_, _, _, Left err, _) -> pure (Left ("load teardown counterexample: " ++ show err))
    (_, _, _, _, Just (Left err)) -> pure (Left ("run teardown counterexample oracle: " ++ show err))
    (_, _, _, _, Nothing) -> pure (Left "the teardown counterexample oracle was not constructed")
    (Right settings, Right basics, Right local, Right fixture, Just (Right oracle))
      | inForceConfigDigest settings /= localGeneratedConfig local ->
          pure (Left bootstrapConfigDisagrees)
      | otherwise -> do
          dnsZoneResult <- qualificationDnsZoneForMode repoRoot substrate cycleLabel mode settings
          case dnsZoneResult >>= \dnsZone ->
            qualificationComposition repoRoot environment cycleLabel settings basics dnsZone of
            Left err -> pure (Left err)
            Right (runId, inputs, candidateEnvironment, retainedBinding) -> do
              -- The candidate's terminal node uninstalls the local cluster, so
              -- bind the immutable running-image inventory before that mutation.
              -- Capturing afterward would either fail to reach Kubernetes or,
              -- worse, identify a subsequently rebuilt deployment.
              observed <- qualificationIdentityForMode repoRoot environment cycleLabel mode local inputs
              case observed of
                Left err -> pure (Left err)
                Right (imageInventory, parts) -> do
                  binaryDigest <- executableBinaryDigest
                  let annotations = annotationsOf (localFullSource local) binaryDigest
                      context =
                        CycleContext
                          { contextRepoRoot = repoRoot
                          , contextPurpose = qualificationCyclePurpose mode
                          , contextLabel = cycleLabel
                          , contextCanonicalCommand = qualificationCanonicalCommand substrate cycleLabel
                          , contextStartedAt = startedAt
                          , contextRunId = runId
                          , contextParts = parts
                          , contextAnnotations = annotations
                          , contextConfigDigest = inForceConfigDigest settings
                          , contextRetainedBinding = retainedBinding
                          , contextFixture = fixture
                          , contextOracle = oracle
                          , contextImageInventory = imageInventory
                          , contextRunCandidate =
                              first renderCascadeCandidateError <$> runCascadeCandidate inputs candidateEnvironment
                          }
                  captured <- captureQualificationResumeSnapshot context
                  case captured of
                    Left detail -> pure (Left detail)
                    Right () -> do
                      driven <- driveQualificationCycle (productionCycleEffects context) cycleLabel parts annotations
                      pure (outcomeOf context <$> driven)

-- The registered recovery lane uses its stored zone and named image capture.
-- Neither read submits Provider work after the terminal audit fence.
qualificationDnsZoneForMode
  :: FilePath
  -> Substrate
  -> CycleLabel
  -> CascadeQualificationResumeMode
  -> ValidatedSettings
  -> IO (Either String HostedZoneId)
qualificationDnsZoneForMode repoRoot substrate label mode settings = case mode of
  QualificationFresh -> resolveQualificationDnsZone repoRoot substrate settings
  QualificationNative -> pure (Left "the native handoff cannot fall back to connected qualification")
  QualificationRegistered -> do
    resolved <- resolveHostCleanupTerminalComposition repoRoot
    case resolved of
      Left err -> pure (Left (show err))
      Right local -> do
        observed <- observeHostCleanupIntent (hostCleanupTerminalIntentStore local)
        pure $ do
          runId <- qualificationRunIdFor label
          intent <- case observed of
            Left err -> Left ("the registered qualification host intent is unobservable: " <> show err)
            Right Nothing -> Left "the registered qualification host intent disappeared"
            Right (Just actual) | hostCleanupRunId actual == runId -> Right actual
            Right (Just _) -> Left "the registered qualification host intent changed runs"
          maybe
            (Left "the registered qualification has no sealed AWS DNS zone")
            Right
            (evidenceAwsDnsZone (hostCleanupObservationEvidenceScope (hostCleanupScope intent)))

qualificationIdentityForMode
  :: FilePath
  -> [(String, String)]
  -> CycleLabel
  -> CascadeQualificationResumeMode
  -> RecomputedLocalParts
  -> CascadeCandidateInputs
  -> IO (Either String ([Text], CycleIdentityParts))
qualificationIdentityForMode repoRoot environment label mode local inputs = case mode of
  QualificationFresh -> observeIdentityParts repoRoot environment local inputs
  QualificationNative -> pure (Left "the native handoff cannot request a new component inventory")
  QualificationRegistered -> do
    observed <- observeQualificationResumeSnapshot repoRoot label
    pure $ do
      snapshot <- case observed of
        Left detail -> Left detail
        Right Nothing -> Left "the registered qualification has no pre-uninstall named image capture"
        Right (Just actual) -> Right actual
      let images = qualificationResumeImages snapshot
      current <- qualificationIdentityParts local inputs images
      if current == begunParts (qualificationResumeBegun snapshot)
        then Right (images, current)
        else
          Left
            "the frozen registered qualification identity changed; no Provider work or credential installation is admitted for this cycle label"

-- | Store the actual named image observation before Begin can admit any
-- destructive effect. An older interrupted cycle without this capture cannot
-- borrow the inventory of a rebuilt cluster to qualify its historical work.
captureQualificationResumeSnapshot :: CycleContext -> IO (Either String ())
captureQualificationResumeSnapshot context = do
  let repoRoot = contextRepoRoot context
      label = contextLabel context
  observed <- observeQualificationResumeSnapshot repoRoot label
  case observed of
    Left detail -> pure (Left detail)
    Right (Just snapshot)
      | begunParts (qualificationResumeBegun snapshot) == contextParts context
      , qualificationResumeImages snapshot == contextImageInventory context ->
          pure (Right ())
      | otherwise ->
          pure (Left "the current qualification identity differs from its immutable pre-uninstall capture")
    Right Nothing -> do
      recorded <- readCycleLedger (cycleLedgerPath repoRoot)
      case recorded of
        Left err -> pure (Left (renderLedgerStoreError err))
        Right ledger
          | any (ownsLabel label . entryRecord) (ledgerEntries ledger) ->
              pure
                ( Left
                    "the existing qualification cycle has no pre-uninstall image capture; historical cleanup remains unresolved and cannot borrow a new inventory to qualify"
                )
          | otherwise -> do
              let begun =
                    BegunRecord
                      { begunLabel = label
                      , begunAttempt = 1
                      , begunKey = identityKeyOfParts (contextParts context)
                      , begunParts = contextParts context
                      , begunAnnotations = contextAnnotations context
                      , begunStartedAt = Text.pack (iso8601Show (contextStartedAt context))
                      }
              case mkQualificationResumeSnapshot begun (contextImageInventory context) of
                Left detail -> pure (Left detail)
                Right snapshot -> fmap void (persistQualificationResumeSnapshot repoRoot snapshot)
 where
  ownsLabel label record = case record of
    RecordCycleBegun begun -> begunLabel begun == label
    RecordCycleClosed _ -> False
    RecordCutoverMark _ -> False

-- | The config the Lifecycle Authority holds, as a digest. A cycle's identity is
-- recomputed after the cascade from the bootstrap seed, because the Authority
-- is gone by then; the two have to agree, or what was certified is not what
-- can be recomputed.
inForceConfigDigest :: ValidatedSettings -> PublicEvidenceDigest
inForceConfigDigest settings =
  hashPublicEvidence (Text.pack (renderConfigDhall (validatedConfig settings)))

bootstrapConfigDisagrees :: String
bootstrapConfigDisagrees =
  "the bootstrap seed config (prodbox.dhall) is not the config the Lifecycle Authority holds in force, "
    ++ "so this cycle's identity could not be recomputed after the cascade; nothing was mutated and nothing "
    ++ "was recorded. Submit the seed (`prodbox cluster reconcile`) or regenerate prodbox.dhall, then rerun."

-- | Everything one cycle needs from the repository, the cluster and its own plan.
data CycleContext = CycleContext
  { contextRepoRoot :: !FilePath
  , contextPurpose :: !CyclePurpose
  , contextLabel :: !CycleLabel
  , contextCanonicalCommand :: !Text
  , contextStartedAt :: !UTCTime
  , contextRunId :: !CleanupRunId
  , contextParts :: !CycleIdentityParts
  , contextAnnotations :: !CycleAnnotations
  , contextConfigDigest :: !PublicEvidenceDigest
  , contextRetainedBinding :: !RetainedNameBinding
  , contextFixture :: !FrozenTeardownCounterexample
  , contextOracle :: !ReplacementTeardownResult
  , contextImageInventory :: ![Text]
  , contextRunCandidate :: !(IO (Either String CascadeCandidateOutcome))
  }

-- | The effects of a cycle over the real ledger, source tree and cluster.
productionCycleEffects :: CycleContext -> CycleEffects IO CascadeCandidateOutcome
productionCycleEffects context =
  CycleEffects
    { effectAttemptNumber = attemptNumberFor ledgerPath (contextLabel context)
    , effectNow = Text.pack . iso8601Show <$> getCurrentTime
    , effectAppend = \record -> first renderLedgerStoreError <$> appendCycleRecord ledgerPath record
    , effectRunCandidate = contextRunCandidate context
    , effectWriteArtifact = \attempt candidate ->
        fmap snd <$> writeQualificationEvidence context attempt candidate
    , effectRecaptureKey =
        first renderLocalRecomputeError
          <$> recaptureExecutableKey (contextRepoRoot context) (contextParts context)
    , effectCandidateSucceeded =
        lifecycleCleanupResultSucceeded . cascadeCandidateOutcomeLifecycleResult
    , effectCyclePurpose = contextPurpose context
    , effectCleanupRunId = cleanupRunIdText (contextRunId context)
    }
 where
  ledgerPath = cycleLedgerPath (contextRepoRoot context)

-- | Which attempt of a label the ledger says the next run is, or why it is none.
attemptNumberFor :: FilePath -> CycleLabel -> IO (Either String Int)
attemptNumberFor ledgerPath label = do
  ledgerResult <- readCycleLedger ledgerPath
  pure $ case ledgerResult of
    Left err -> Left (renderLedgerStoreError err)
    Right ledger -> first renderRefusal (labelDisposition ledger label)
 where
  renderRefusal :: LedgerRefusal -> String
  renderRefusal = Text.unpack . renderLedgerRefusal

-- | What the caller of a cycle is told once the cycle has closed.
outcomeOf
  :: CycleContext
  -> CycleReport CascadeCandidateOutcome
  -> CascadeQualificationOutcome
outcomeOf context report =
  CascadeQualificationOutcome
    { internalQualificationRunId = contextRunId context
    , internalQualificationLifecycleResult =
        cascadeCandidateOutcomeLifecycleResult (reportCandidate report)
    , internalQualificationEvidenceDigest = fromMaybe "none" (reportArtifactDigest report)
    , internalQualificationEvidencePath =
        contextRepoRoot context
          </> ".test-data"
          </> "qualification"
          </> cascadeArtifactFileName (contextLabel context)
    , internalQualificationAttempt = reportAttempt report
    , internalQualificationIdentityKey = identityKeyOfParts (contextParts context)
    , internalQualificationCycleOutcome = reportOutcome report
    , internalQualificationLedgerEntries = entrySequence (reportLastEntry report) + 1
    , internalQualificationLedgerTip = publicEvidenceDigestText (entryDigest (reportLastEntry report))
    }

-- | The running images, observed while the cluster still exists, and the
-- identity parts that depend on them and on the compiled program's shape.
observeIdentityParts
  :: FilePath
  -> [(String, String)]
  -> RecomputedLocalParts
  -> CascadeCandidateInputs
  -> IO (Either String ([Text], CycleIdentityParts))
observeIdentityParts repoRoot environment local inputs = do
  inventoryResult <- observeComponentImageInventory repoRoot environment
  pure $ do
    imageInventory <- inventoryResult
    parts <- qualificationIdentityParts local inputs imageInventory
    Right (imageInventory, parts)

-- | The parts of the qualification identity that are not recomputable once the
-- cluster is gone: the images that ran and the shape of the program that ran.
-- The shape holds the run id, owner and terminal permit constant, so two cycles
-- of one deployment agree on it even though their own plans never do.
qualificationIdentityParts
  :: RecomputedLocalParts
  -> CascadeCandidateInputs
  -> [Text]
  -> Either String CycleIdentityParts
qualificationIdentityParts local inputs imageInventory = do
  images <- traverse inventoryImageDigest imageInventory
  shape <-
    cascadeCandidateShapeSummary
      (cascadeCandidateFoundation inputs)
      (cascadeCandidateAwsDnsZone inputs)
      (cascadeCandidateDeclaredLeaseMicros inputs)
  Right
    ( partsFromLocal
        canonicalKeyPolicy
        local
        CompareOnlyParts
          { compareImages = images
          , compareTopologyWiring =
              topologyWiringDigest
                (cascadeCandidateSummaryGraphDigest shape)
                (cascadeCandidateSummaryDescriptorDigest shape)
          }
    )

-- | The digest of one @component=sha256:hex@ inventory line.
inventoryImageDigest :: Text -> Either String PublicEvidenceDigest
inventoryImageDigest line =
  case mkPublicEvidenceDigest (snd (Text.breakOnEnd "=sha256:" line)) of
    Just digest | "=sha256:" `Text.isInfixOf` line -> Right digest
    _ -> Left ("qualification component image identity is not an immutable sha256: " ++ Text.unpack line)

qualificationComposition
  :: FilePath
  -> [(String, String)]
  -> CycleLabel
  -> ValidatedSettings
  -> UnencryptedBasics
  -> HostedZoneId
  -> Either
       String
       ( CleanupRunId
       , CascadeCandidateInputs
       , CascadeCandidateEnvironment
       , RetainedNameBinding
       )
qualificationComposition repoRoot environment cycleLabel settings basics dnsZone = do
  runId <-
    first
      Text.unpack
      (mkCleanupRunId ("cascade-qualification-" <> cycleLabelText cycleLabel))
  owner <-
    first
      Text.unpack
      (mkCleanupOwnerId ("cascade-qualification-owner-" <> cycleLabelText cycleLabel))
  terminalPermit <-
    first
      show
      (mkHostTerminalPermitId ("cascade-qualification-permit-" <> cycleLabelText cycleLabel))
  apiWait <- first Text.unpack (mkSubstrateApiWait 120 5_000_000)
  admissionWait <-
    first Text.unpack (mkLifecycleAuthorityAdmissionWait 180 5_000_000)
  drainLease <- first show (mkEksDrainLeaseSeconds derivedEksDrainLeaseSeconds)
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
  homeZone <-
    maybe
      (Left "cascade cleanup requires the home route53.zone_id")
      Right
      (coordinateHomeZoneId coordinates)
  typedHomeZone <- first show (mkHostedZoneId (route53ZoneIdText homeZone))
  certificates <- requireSubstrateCertScopeSet settings SubstrateHomeLocal
  certificateNames <-
    maybe
      (Left "cascade cleanup requires configured home certificate names")
      Right
      (NonEmpty.nonEmpty (certScopeSetDnsNames certificates))
  home <- first show (mkHomeDns01Scope typedHomeZone certificateNames)
  typedCaptureBucket <-
    maybe
      (Left "cascade cleanup requires ses.capture_bucket")
      Right
      (coordinateSesCaptureBucket coordinates)
  receiveLabel <-
    requireCoordinate
      "ses.receive_subdomain"
      (dnsLabelText <$> coordinateSesReceiveSubdomain coordinates)
  receiveDomain <- sesReceiveDomain senderDomain receiveLabel
  mail <- first show (mkInviteMailScope typedCaptureBucket (ValidationInviteDomain receiveDomain))
  let resourceBindings = mkResourceScopeBindingsWithAudit (Just home) (Just mail) binding
      composition =
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
          , cascadeCandidateAwsDnsZone = Just dnsZone
          , cascadeCandidateResourceScopeBindings = resourceBindings
          , cascadeCandidateTerminalPermitId = terminalPermit
          , cascadeCandidateDeclaredLeaseMicros = declaredLeaseMicros
          }
      candidateEnvironment =
        CascadeCandidateEnvironment
          { cascadeCandidateComposition = composition
          , cascadeCandidateRevokeProviderCredential = revokeCascadeCredential repoRoot runId
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

-- | Fresh qualification seals the selected substrate's exact DNS coordinate.
-- Home uses its authored parent zone; AWS uses the provisioned subzone through
-- the shared config-or-stack resolver. Recovery above keeps the stored zone.
resolveQualificationDnsZone
  :: FilePath -> Substrate -> ValidatedSettings -> IO (Either String HostedZoneId)
resolveQualificationDnsZone repoRoot substrate settings = do
  resolved <- resolveSubstrateHostedZoneId repoRoot settings substrate
  pure (resolved >>= first show . mkHostedZoneId)

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
  :: CycleContext
  -> Int
  -> CascadeCandidateOutcome
  -> IO (Either String (FilePath, Text))
writeQualificationEvidence context attempt candidateOutcome = do
  completedAt <- getCurrentTime
  let repoRoot = contextRepoRoot context
      cycleLabel = contextLabel context
      artifactDirectory = repoRoot </> ".test-data" </> "qualification"
      artifactPath = artifactDirectory </> cascadeArtifactFileName cycleLabel
      result = cascadeCandidateOutcomeLifecycleResult candidateOutcome
      succeeded = lifecycleCleanupResultSucceeded result
      AwsScope (AwsAccountId awsAccount) (AwsRegion awsRegion) =
        cascadeCandidateOutcomeAwsScope candidateOutcome
      fields =
        CascadeArtifactFields
          { fieldsLabel = cycleLabel
          , fieldsAttempt = attempt
          , fieldsCanonicalCommand = contextCanonicalCommand context
          , fieldsStartedAt = Text.pack (iso8601Show (contextStartedAt context))
          , fieldsCompletedAt = Text.pack (iso8601Show completedAt)
          , fieldsAwsAccount = awsAccount
          , fieldsAwsRegion = awsRegion
          , fieldsCleanupRunId = cleanupRunIdText (contextRunId context)
          , fieldsParts = contextParts context
          , fieldsAnnotations = contextAnnotations context
          , fieldsComponentImages = contextImageInventory context
          , fieldsRunScopedTopologyDigest =
              cleanupDigestText (cascadeCandidateOutcomeGraphDigest candidateOutcome)
          , fieldsRunScopedWiringDigest =
              cleanupDigestText (cascadeCandidateOutcomeDescriptorDigest candidateOutcome)
          , fieldsInForceConfigDigest =
              publicEvidenceDigestText (contextConfigDigest context)
          , fieldsFrozenLines =
              frozenFactLines (contextFixture context) (contextOracle context)
                ++ [("intended_retained_set", Text.pack (show (contextRetainedBinding context)))]
          , fieldsAggregateSucceeded = succeeded
          , fieldsResidueAbsent = succeeded
          , fieldsLifecycleSucceeded = succeeded
          , fieldsLifecycleResult = Text.pack (show result)
          }
  case renderCascadeArtifact fields of
    Left err -> pure (Left ("render qualification evidence: " ++ show err))
    Right (artifactText, artifactDigest) -> do
      created <- tryIOError (createDirectoryIfMissing True artifactDirectory)
      case created of
        Left err -> pure (Left ("create qualification evidence directory: " ++ show err))
        Right () -> do
          written <- tryIOError (TextIO.writeFile artifactPath artifactText)
          pure $ case written of
            Left err -> Left ("write qualification evidence: " ++ show err)
            Right () -> Right (artifactPath, artifactDigest)

-- | The superseded-side and counterexample facts of a cycle, as artifact lines.
--
-- They live here, not in the artifact codec, because the superseded
-- interpreter formula names the legacy route the single-writer cutover deletes,
-- and the clean-room scan registers this module as one of that route's sites.
frozenFactLines
  :: FrozenTeardownCounterexample -> ReplacementTeardownResult -> [(Text, Text)]
frozenFactLines fixture oracle =
  [ ("superseded_source_identity", shown (frozenCompositionSource supersededIdentity))
  , ("superseded_generated_config_digest", frozenCompositionGeneratedConfigDigest supersededIdentity)
  , ("superseded_component_images", shown (frozenCompositionImages supersededIdentity))
  , ("superseded_topology_digest", frozenCompositionTopologyDigest supersededIdentity)
  , ("superseded_wiring_digest", frozenCompositionWiringDigest supersededIdentity)
  , ("superseded_resource_envelope_digest", digestValue causalProfile)
  ,
    ( "superseded_load_fault_digest"
    , digestValue
        ( frozenTeardownExternalStateRows fixture
        , frozenTeardownInterruptionSchedule fixture
        , causalProfile
        )
    )
  ,
    ( "superseded_interpreter_digest"
    , sha256Text (frozenSourceDigest supersededIdentity <> "\NULlegacy-runNativeDeleteCascade/v1")
    )
  ,
    ( "superseded_persistence_digest"
    , sha256Text (frozenSourceDigest supersededIdentity <> "\NULlegacy-resource-registry/v1")
    )
  ,
    ( "superseded_cleanup_schema_digest"
    , sha256Text (frozenSourceDigest supersededIdentity <> "\NULlegacy-cascade-report/v1")
    )
  , ("frozen_replacement_identity", shown (frozenTeardownReplacementIdentity fixture))
  , ("normalized_envelope_mapping_digest", digestValue (causalProfile, productionProfile))
  , ("causal_profile", shown causalProfile)
  , ("production_profile", shown productionProfile)
  , ("counterexample_id", teardownFixtureIdText (frozenTeardownFixtureId fixture))
  ,
    ( "counterexample_artifact_digest"
    , teardownArtifactDigestText (frozenTeardownArtifactDigest fixture)
    )
  , ("counterexample_superseded_result", shown (supersededGlobalCopyOracle fixture))
  , ("counterexample_replacement_result", shown oracle)
  ]
    ++ [("fault_external_state", shown row) | row <- frozenTeardownExternalStateRows fixture]
    ++ [("fault_interruption", shown item) | item <- frozenTeardownInterruptionSchedule fixture]
 where
  supersededIdentity = frozenTeardownSupersededIdentity fixture
  causalProfile = frozenTeardownCausalProfile fixture
  productionProfile = frozenTeardownProductionProfile fixture
  shown :: (Show value) => value -> Text
  shown = Text.pack . show

frozenSourceDigest :: FrozenCompositionIdentity -> Text
frozenSourceDigest = frozenSourceManifestDigest . frozenCompositionSource

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

-- | Fresh per-entry lineage heals an interrupted Provisioner revoke without
-- borrowing the install operation of this or any previous qualification cycle.
revokeCascadeCredential
  :: FilePath -> CleanupRunId -> IO (Either Text HarnessCredentialRevocationEvidence)
revokeCascadeCredential repoRoot runId = do
  entropy <-
    try (getRandomBytes 32 :: IO ByteString.ByteString) :: IO (Either IOException ByteString.ByteString)
  case entropy of
    Left _ -> pure (Left "cannot allocate the cascade credential-retirement lineage")
    Right nonce -> case mkHarnessCredentialLineage ("cascade-retirement:" <> cleanupRunIdText runId) nonce of
      Left err -> pure (Left (Text.pack (show err)))
      Right lineage -> first Text.pack <$> revokeHarnessLifecycleProviderCredentialWithEvidence repoRoot lineage
