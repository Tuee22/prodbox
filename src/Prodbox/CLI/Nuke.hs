{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Operator-only total decommission entrypoint.
--
-- The legacy process-local five-command teardown is intentionally not reachable
-- from this module.  Apply requires one complete production composition: an
-- Authority-authenticated manifest/export preparation, the total closed-node
-- interpreter registry, an external receipt acknowledgement, pinned-process
-- verification/replacement, and an explicit point-of-no-return transition.
module Prodbox.CLI.Nuke
  ( abortOrContinue
  , confirmationLiteral
  , defaultNukeOptions
  , ProductionDecommissionAvailability (..)
  , ProductionNukeRemoteCapabilities (..)
  , NukeDecommissionComposition (..)
  , PreparedNukeDecommission (..)
  , productionDecommissionAvailability
  , productionNukeDecommissionComposition
  , nukeInterpreterRegistryIdentity
  , nukePlanNodeLines
  , nukeRunnerDependencyMetadata
  , nukeVerifierMetadata
  , renderNukePlan
  , runNukeCommand
  , validateProductionManifest
  , runNukeCommandWithComposition
  )
where

import Control.Exception (IOException, try)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as Char8
import Data.Either (fromLeft)
import Data.List (nub)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Version (showVersion)
import Prodbox.AwsEnvironment (awsCliSubprocessEnvironment)
import Prodbox.CLI.Command
  ( NukeLocalDataDisposition (NukeDeleteLocalData, NukeRetainLocalData)
  , NukeOptions (..)
  , PlanOptions (..)
  , buildPlan
  , runPlanWithOptions
  )
import Prodbox.CLI.Interactive
  ( InteractiveGuard (..)
  , requireInteractiveTty
  )
import Prodbox.CLI.Output
  ( writeDiagnosticLine
  , writeError
  , writeOutput
  , writeOutputLine
  )
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientTransport
  )
import Prodbox.ControlPlane.DecommissionClient
  ( enterAuthorityDecommissionPointOfNoReturnViaTransport
  , requestAuthorityDecommissionManifestViaTransport
  , retainedCustodyTombstoneCapability
  , targetGenerationTombstoneCapabilityViaTransport
  )
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller (LifecycleAuthorityOperator)
  , LifecycleAuthorityAuthentication
  , LifecycleAuthorityAuthenticationError
  , lifecycleAuthorityManifestSignerDigest
  , renderLifecycleAuthorityAuthenticationError
  , withHostLifecycleAuthorityAuthentication
  , withLifecycleAuthorityAuthenticatedTransport
  , withTargetSecretAgentAuthenticatedTransport
  )
import Prodbox.Error (fatalError)
import Prodbox.Infra.AwsEksTestStack (awsEksCanonicalClusterName)
import Prodbox.Infra.AwsSesDecommission
  ( AwsSesDecommissionPrimitive
  , AwsSesDecommissionScope (AwsSesProviderOnly, AwsSesSmtpIamOnly)
  , awsSesProviderStackCapability
  , awsSesProviderStackDestroyPrimitive
  , awsSesSmtpIamCapability
  , awsSesSmtpIamDestroyPrimitive
  )
import Prodbox.Infra.LongLivedDecommission
  ( ProductionLongLivedDecommissionCapabilities
  , loadProductionLongLivedDecommissionCapabilities
  , productionBackupAllPrefixesAbsentCapability
  , productionBackupObjectsIdentityCapability
  , productionSharedObjectBucketCapability
  , productionTlsRetainedObjectsCapability
  , productionTlsRetentionIdentityCapability
  )
import Prodbox.Infra.LongLivedPulumiBackend (loadAdminAwsCredentials)
import Prodbox.Infra.SesConsumerQuiescence
  ( loadProductionSesConsumerQuiescenceCapability
  )
import Prodbox.Lifecycle.CleanupRun
  ( mkCleanupOperationId
  )
import Prodbox.Lifecycle.Decommission.Frame
  ( FrameAttemptId
  , contentDigest
  , frameAttemptIdForNode
  , frameAttemptIdText
  )
import Prodbox.Lifecycle.Decommission.Graph
  ( productionDecommissionPlanNodes
  , reportBlocked
  , reportConverged
  , reportFailed
  )
import Prodbox.Lifecycle.Decommission.Manifest
  ( DecommissionLocalDataDisposition (..)
  , DecommissionNode (..)
  , DecommissionNodeFamily (..)
  , VerifiedDecommissionManifest
  , currentManifestVersion
  , decommissionLocalDataDispositionText
  , decommissionNodeFamily
  , decommissionNodeFrameId
  , manifestClusterId
  , manifestNodes
  , mkDecommissionTargetGeneration
  , renderDecommissionPlanCardinalityError
  , validateDecommissionPlanCardinality
  , verifiedManifestPlan
  , verifiedVerifierBinding
  )
import Prodbox.Lifecycle.Decommission.NodeEffect
  ( DecommissionTerminalReceiptCapability (..)
  , FinalNoRetentionAuditCapability (..)
  , HomeSubstrateUninstallCapability (..)
  , LocalDataDispositionCapability (..)
  , NodeOperation (..)
  , ProductionDecommissionCapabilities (..)
  , RetainedCustodyTombstoneCapability (..)
  , SesConsumerQuiescenceCapability
  , TargetGenerationTombstoneCapability (..)
  , decommissionInterpreterFromRegistry
  , decommissionRegistryFromProductionCapabilities
  )
import Prodbox.Lifecycle.Decommission.ProgramTag
  ( decommissionNodeProgramTag
  , decommissionProgramTagText
  , decommissionRunnerInterpreterIdentity
  , decommissionRunnerInterpreterRegistry
  )
import Prodbox.Lifecycle.Decommission.Receipt
  ( AcknowledgedExternalReceipt
  , PendingExternalReceipt
  , acknowledgeExternalReceipt
  , pendingExternalReceiptPath
  , prepareExternalReceiptAcknowledgement
  , readBoundReceiptFramesReadOnly
  , receiptAcknowledgementLiteral
  )
import Prodbox.Lifecycle.Decommission.Runner
  ( decommissionRunTerminalEvidence
  , renderDecommissionRunTerminalError
  , runBoundDecommission
  )
import Prodbox.Lifecycle.Decommission.Verifier
  ( DeletionRootPath
  , ExternalArtifactPath
  , ExternalReceiptPath
  , HostValidatedExternalDurablePaths
  , PinnedProcessTransition (PinnedProcessAlreadyCurrent, PinnedProcessReplacementInvoked)
  , VerifierArtifact
  , VerifierBinding
  , VerifierMetadata
  , VerifierPreflightResult (VerifierReady, VerifierRefused)
  , decidePinnedArtifactExecution
  , exportVerifierArtifact
  , externalArtifactPath
  , externalReceiptPath
  , inspectRunningVerifierArtifact
  , mkDeletionRootPath
  , mkExternalArtifactPath
  , mkExternalReceiptPath
  , mkVerifierMetadata
  , replaceWithPinnedVerifier
  , runVerifierPreflight
  , validateExternalDurablePathsOnHost
  , verifierBindingOf
  , verifierDependencyPath
  , verifierMetadataPath
  )
import Prodbox.Lifecycle.HostCleanupLocalData
  ( LocalDataRootPath
  , LocalDataTerminalAdapter
  , attemptLocalDataDisposition
  , classifyLocalDataDisposition
  , localDataDispositionResidue
  , mkLocalDataRootPath
  , observeLocalDataRoot
  , productionLocalDataTerminalAdapter
  )
import Prodbox.Lifecycle.HostCleanupRke2
  ( LocalRke2InstallObservation (..)
  , LocalRke2TerminalAdapter
  , attemptLocalRke2Uninstall
  , localRke2UninstallResultToHostEffect
  , observeLocalRke2Install
  , productionLocalRke2TerminalAdapter
  )
import Prodbox.Lifecycle.HostCleanupRunner
  ( HostCleanupEffectOutcome (..)
  )
import Prodbox.Lifecycle.ResidueStatus
  ( ResidueDetails (..)
  , ResidueStatus (ResidueAbsent, ResiduePresent, ResidueUnreachable)
  , ResidueUnreachableReason (ResidueQueryFailed)
  )
import Prodbox.Lifecycle.TagSweep qualified as TagSweep
import Prodbox.Runtime.Role
  ( RuntimeRole (TargetSecretAgentRuntime)
  )
import Prodbox.Settings
  ( ConfigFile (storage)
  , Credentials
  , StorageSection (manual_pv_host_root)
  , loadConfigFile
  )
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesFileExist)
import System.Environment (getArgs)
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute, normalise, takeDirectory, (</>))
import System.IO (hFlush, stdout)
import System.Info (compilerName, compilerVersion)

defaultNukeOptions :: NukeOptions
defaultNukeOptions =
  NukeOptions
    { nukeDryRun = False
    , nukePlanFile = Nothing
    , nukeReceiptPath = Nothing
    , nukeLocalDataDisposition = Nothing
    }

confirmationLiteral :: String
confirmationLiteral = "NUKE EVERYTHING"

newtype ProductionDecommissionAvailability
  = ProductionDecommissionReady NukeDecommissionComposition

-- | Boundary supplied only once the Authority/export and every production node
-- client exist.  Preparation may freeze admission, sign/commit the complete
-- manifest, export/read-back the runner, and durably initialize the receipt; it
-- must not permanently stop Authority or begin destructive work.  That explicit
-- transition is a separate field invoked only after preflight and acknowledgement.
newtype NukeDecommissionComposition = NukeDecommissionComposition
  { prepareNukeDecommission
      :: ExternalReceiptPath
      -> FilePath
      -> DecommissionLocalDataDisposition
      -> Credentials
      -> IO (Either Text PreparedNukeDecommission)
  }

-- | The five role/provider boundaries still supplied by their exact production
-- clients.  The constructor below owns the external verifier/receipt, exact
-- SMTP-IAM teardown, and all five long-lived store capabilities itself; callers
-- cannot replace those with a broad process-local teardown.
data ProductionNukeRemoteCapabilities = ProductionNukeRemoteCapabilities
  { productionRequestDecommissionManifest
      :: VerifierBinding
      -> DecommissionLocalDataDisposition
      -> IO (Either Text VerifiedDecommissionManifest)
  , productionEnterNukePointOfNoReturn
      :: VerifiedDecommissionManifest
      -> AcknowledgedExternalReceipt
      -> IO (Either Text ())
  , productionSesConsumersQuiescence
      :: !(SesConsumerQuiescenceCapability IO)
  , productionTargetGenerationTombstones
      :: VerifiedDecommissionManifest
      -> TargetGenerationTombstoneCapability IO
  , productionRetainedCustodyTombstones
      :: VerifiedDecommissionManifest
      -> RetainedCustodyTombstoneCapability IO
  }

-- | Everything required for an authenticated run. The production capability
-- inventory has a distinct required wrapper for every external role/resource
-- family; a partially wired or read/write-confused runner is not constructible.
data PreparedNukeDecommission = PreparedNukeDecommission
  { preparedVerifiedManifest :: !VerifiedDecommissionManifest
  , preparedRunningVerifierIdentity :: !VerifierBinding
  , preparedExternalReceipt :: !PendingExternalReceipt
  , preparedAttemptIdFor :: !(DecommissionNode -> FrameAttemptId)
  , preparedProductionCapabilities :: !(ProductionDecommissionCapabilities IO)
  , preparedMaximumFrameBytes :: !Int
  , preparedEnterPointOfNoReturn
      :: AcknowledgedExternalReceipt
      -> IO (Either Text ())
  }

-- | The default CLI uses the complete authenticated composition.  Authentication
-- is acquired only during apply, after the external path and interactive gate
-- have been validated; dry-run remains side-effect free.
productionDecommissionAvailability :: ProductionDecommissionAvailability
productionDecommissionAvailability =
  ProductionDecommissionReady productionAuthenticatedNukeComposition

productionAuthenticatedNukeComposition :: NukeDecommissionComposition
productionAuthenticatedNukeComposition =
  NukeDecommissionComposition $ \receiptPath repoRoot localDataDisposition credentials -> do
    quiescenceResult <- loadProductionSesConsumerQuiescenceCapability repoRoot
    case quiescenceResult of
      Left detail -> pure (Left detail)
      Right quiescence -> do
        authenticated <-
          withHostLifecycleAuthorityAuthentication
            LifecycleAuthorityOperator
            repoRoot
            ( \authentication ->
                prepareNukeDecommission
                  ( productionNukeDecommissionComposition
                      (productionRemoteCapabilities authentication quiescence)
                  )
                  receiptPath
                  repoRoot
                  localDataDisposition
                  credentials
            )
        pure $ case authenticated of
          Left err ->
            Left
              ( Text.pack
                  (renderLifecycleAuthorityAuthenticationError err)
              )
          Right prepared -> prepared

productionRemoteCapabilities
  :: LifecycleAuthorityAuthentication
  -> SesConsumerQuiescenceCapability IO
  -> ProductionNukeRemoteCapabilities
productionRemoteCapabilities authentication quiescence =
  ProductionNukeRemoteCapabilities
    { productionRequestDecommissionManifest = \verifier localDataDisposition -> do
        result <-
          withLifecycleAuthorityAuthenticatedTransport authentication $ \transport ->
            requestAuthorityDecommissionManifestViaTransport
              transport
              (lifecycleAuthorityManifestSignerDigest authentication)
              verifier
              localDataDisposition
        pure (flattenAuthenticatedResult result)
    , productionEnterNukePointOfNoReturn = \verified acknowledged -> do
        result <-
          withLifecycleAuthorityAuthenticatedTransport authentication $ \transport ->
            enterAuthorityDecommissionPointOfNoReturnViaTransport
              transport
              verified
              acknowledged
        pure (flattenAuthenticatedResult result)
    , productionSesConsumersQuiescence = quiescence
    , productionTargetGenerationTombstones =
        targetGenerationThroughAuthentication authentication
    , productionRetainedCustodyTombstones =
        retainedCustodyThroughAuthentication authentication
    }

flattenAuthenticatedResult
  :: (Show err)
  => Either
       LifecycleAuthorityAuthenticationError
       (Either err value)
  -> Either Text value
flattenAuthenticatedResult result = case result of
  Left err ->
    Left (Text.pack (renderLifecycleAuthorityAuthenticationError err))
  Right attempted -> first (Text.pack . show) attempted

targetGenerationThroughAuthentication
  :: LifecycleAuthorityAuthentication
  -> VerifiedDecommissionManifest
  -> TargetGenerationTombstoneCapability IO
targetGenerationThroughAuthentication authentication verified =
  TargetGenerationTombstoneCapability $ \reference generation ->
    targetOperationThroughAuthentication authentication $ \transport ->
      runTargetGenerationTombstoneCapability
        (targetGenerationTombstoneCapabilityViaTransport transport verified)
        reference
        generation

retainedCustodyThroughAuthentication
  :: LifecycleAuthorityAuthentication
  -> VerifiedDecommissionManifest
  -> RetainedCustodyTombstoneCapability IO
retainedCustodyThroughAuthentication authentication verified =
  RetainedCustodyTombstoneCapability
    ( targetOperationThroughAuthentication authentication $ \transport ->
        runRetainedCustodyTombstoneCapability
          (retainedCustodyTombstoneCapability transport verified)
    )

targetOperationThroughAuthentication
  :: LifecycleAuthorityAuthentication
  -> ( AuthenticatedClientTransport 'TargetSecretAgentRuntime
       -> NodeOperation IO
     )
  -> NodeOperation IO
targetOperationThroughAuthentication authentication operationFor =
  NodeOperation
    { nodeDestroy = \nodeId attemptId -> do
        result <-
          withTargetSecretAgentAuthenticatedTransport authentication $ \transport ->
            nodeDestroy (operationFor transport) nodeId attemptId
        pure $ case result of
          Left err ->
            Left
              ( Text.pack
                  (renderLifecycleAuthorityAuthenticationError err)
              )
          Right destroyed -> destroyed
    , nodeReadBack = \nodeId attemptId -> do
        result <-
          withTargetSecretAgentAuthenticatedTransport authentication $ \transport ->
            nodeReadBack (operationFor transport) nodeId attemptId
        pure $ case result of
          Left err ->
            ResidueUnreachable
              ( ResidueQueryFailed
                  (renderLifecycleAuthorityAuthenticationError err)
              )
          Right observed -> observed
    }

-- | Assemble every landed local production boundary around the remaining
-- authenticated remote clients.  The runner path is derived solely from the
-- operator-supplied receipt coordinate, and both files plus their sidecars are
-- host-proved outside the exact local deletion-root inventory before export.
productionNukeDecommissionComposition
  :: ProductionNukeRemoteCapabilities
  -> NukeDecommissionComposition
productionNukeDecommissionComposition remote =
  NukeDecommissionComposition (prepareProductionNukeDecommission remote)

prepareProductionNukeDecommission
  :: ProductionNukeRemoteCapabilities
  -> ExternalReceiptPath
  -> FilePath
  -> DecommissionLocalDataDisposition
  -> Credentials
  -> IO (Either Text PreparedNukeDecommission)
prepareProductionNukeDecommission remote receiptPath repoRoot localDataDisposition credentials =
  case nukeVerifierMetadata of
    Left detail -> pure (Left detail)
    Right metadata -> do
      runningResult <- inspectRunningVerifierArtifact nukeRunnerDependencyMetadata metadata
      case runningResult of
        Left err ->
          pure (Left ("cannot inspect the running decommission verifier: " <> Text.pack (show err)))
        Right (runningPath, artifact) ->
          prepareWithRunningArtifact
            remote
            receiptPath
            repoRoot
            localDataDisposition
            credentials
            runningPath
            artifact

prepareWithRunningArtifact
  :: ProductionNukeRemoteCapabilities
  -> ExternalReceiptPath
  -> FilePath
  -> DecommissionLocalDataDisposition
  -> Credentials
  -> ExternalArtifactPath
  -> VerifierArtifact
  -> IO (Either Text PreparedNukeDecommission)
prepareWithRunningArtifact remote receiptPath repoRoot localDataDisposition credentials runningPath artifact = do
  coordinateResult <- prepareProductionVerifierCoordinate receiptPath repoRoot artifact
  case coordinateResult of
    Left detail -> pure (Left detail)
    Right (hostPaths, exportedBinding) -> do
      localDataRootResult <- resolveNukeLocalDataRoot repoRoot
      longLivedResult <- loadProductionLongLivedDecommissionCapabilities repoRoot credentials
      case (,) <$> localDataRootResult <*> longLivedResult of
        Left detail -> pure (Left detail)
        Right (localDataRoot, longLived) -> do
          smtpPrimitive <- awsSesSmtpIamDestroyPrimitive repoRoot credentials
          let providerPrimitive =
                awsSesProviderStackDestroyPrimitive repoRoot credentials
          manifestResult <-
            productionRequestDecommissionManifest remote exportedBinding localDataDisposition
          case manifestResult of
            Left detail -> pure (Left ("Authority decommission export refused: " <> detail))
            Right verified ->
              case validateProductionManifest exportedBinding localDataDisposition verified of
                Left detail -> pure (Left detail)
                Right () -> do
                  receiptResult <- prepareExternalReceiptAcknowledgement hostPaths verified
                  pure $ case receiptResult of
                    Left err ->
                      Left
                        ( "external decommission receipt initialization refused: "
                            <> Text.pack (show err)
                        )
                    Right pending ->
                      Right
                        PreparedNukeDecommission
                          { preparedVerifiedManifest = verified
                          , preparedRunningVerifierIdentity = verifierBindingOf runningPath artifact
                          , preparedExternalReceipt = pending
                          , preparedAttemptIdFor =
                              frameAttemptIdForNode . decommissionNodeFrameId
                          , preparedProductionCapabilities =
                              productionCapabilities
                                remote
                                verified
                                smtpPrimitive
                                longLived
                                providerPrimitive
                                ( productionFinalNoRetentionAuditCapability
                                    repoRoot
                                    credentials
                                )
                                (productionHomeSubstrateUninstallCapability repoRoot)
                                ( productionLocalDataDispositionCapability
                                    localDataRoot
                                    repoRoot
                                )
                                ( productionDecommissionTerminalReceiptCapability
                                    verified
                                    receiptPath
                                )
                          , preparedMaximumFrameBytes = nukeMaximumFrameBytes
                          , preparedEnterPointOfNoReturn =
                              productionEnterNukePointOfNoReturn remote verified
                          }

prepareProductionVerifierCoordinate
  :: ExternalReceiptPath
  -> FilePath
  -> VerifierArtifact
  -> IO
       ( Either
           Text
           (HostValidatedExternalDurablePaths, VerifierBinding)
       )
prepareProductionVerifierCoordinate receiptPath repoRoot artifact =
  case deriveVerifierArtifactPath receiptPath of
    Left detail -> pure (Left detail)
    Right artifactPath -> do
      deletionRootsResult <- loadNukeDeletionRoots repoRoot
      case deletionRootsResult of
        Left detail -> pure (Left detail)
        Right deletionRoots -> do
          lexicalHostResult <-
            validateExternalDurablePathsOnHost deletionRoots artifactPath receiptPath
          case lexicalHostResult of
            Left err -> pure (Left (renderExternalPathFailure err))
            Right _ -> do
              directoryResult <- prepareExternalDirectories artifactPath receiptPath
              case directoryResult of
                Left detail -> pure (Left detail)
                Right () -> do
                  hostResult <-
                    validateExternalDurablePathsOnHost deletionRoots artifactPath receiptPath
                  case hostResult of
                    Left err -> pure (Left (renderExternalPathFailure err))
                    Right hostPaths -> do
                      bindingResult <- ensureVerifierExport artifactPath artifact
                      pure ((,) hostPaths <$> bindingResult)

deriveVerifierArtifactPath :: ExternalReceiptPath -> Either Text ExternalArtifactPath
deriveVerifierArtifactPath receiptPath =
  first
    (\err -> "invalid receipt-derived verifier artifact path: " <> Text.pack (show err))
    (mkExternalArtifactPath (externalReceiptPath receiptPath ++ ".runner"))

-- | The configured manual PV host root, resolved against the repository root.
--
-- Sprint 4.85: one resolution serves two consumers that must not disagree.
-- @nuke@ has always treated this root as the first entry of its deletion-root
-- inventory — which is why the external receipt and pinned runner are refused
-- inside it — and it is now also the exact target of the operator's
-- retained-local-data disposition. Resolving it twice would let @nuke@ refuse
-- a receipt path under one root while disposing of another.
resolveNukeManualPvRoot :: FilePath -> IO (Either Text FilePath)
resolveNukeManualPvRoot repoRoot = do
  canonicalRepoResult <- try (canonicalizePath repoRoot)
  case canonicalRepoResult of
    Left err ->
      pure
        ( Left
            ( "cannot resolve the repository root for decommission path validation: "
                <> Text.pack (show (err :: IOException))
            )
        )
    Right canonicalRepo -> do
      configResult <- loadConfigFile repoRoot
      pure $ case configResult of
        Left detail ->
          Left ("cannot load Config for decommission path validation: " <> Text.pack detail)
        Right config ->
          let configuredManualRoot = Text.unpack (manual_pv_host_root (storage config))
           in Right
                ( normalise
                    ( if isAbsolute configuredManualRoot
                        then configuredManualRoot
                        else canonicalRepo </> configuredManualRoot
                    )
                )

loadNukeDeletionRoots :: FilePath -> IO (Either Text [DeletionRootPath])
loadNukeDeletionRoots repoRoot = do
  manualRootResult <- resolveNukeManualPvRoot repoRoot
  pure $ do
    manualRoot <- manualRootResult
    let rawRoots =
          [ manualRoot
          , "/var/lib/rancher/rke2"
          , "/var/lib/rancher"
          , "/etc/rancher/rke2"
          , "/usr/local/bin/rke2"
          , "/usr/local/bin/rke2-killall.sh"
          , "/usr/local/bin/rke2-uninstall.sh"
          ]
    first
      (\err -> "invalid compiled decommission deletion root: " <> Text.pack (show err))
      (traverse mkDeletionRootPath (nub rawRoots))

-- | The same root, admitted through the stricter guard the removal argument
-- needs.
resolveNukeLocalDataRoot :: FilePath -> IO (Either Text LocalDataRootPath)
resolveNukeLocalDataRoot repoRoot = do
  manualRootResult <- resolveNukeManualPvRoot repoRoot
  pure $ do
    manualRoot <- manualRootResult
    first
      ( \err ->
          "the configured manual PV host root cannot be a decommission disposition"
            <> " target: "
            <> Text.pack (show err)
      )
      (mkLocalDataRootPath manualRoot)

prepareExternalDirectories
  :: ExternalArtifactPath
  -> ExternalReceiptPath
  -> IO (Either Text ())
prepareExternalDirectories artifactPath receiptPath = do
  let directories =
        nub
          [ takeDirectory (externalArtifactPath artifactPath)
          , takeDirectory (externalReceiptPath receiptPath)
          ]
  result <- try (mapM_ (createDirectoryIfMissing True) directories)
  pure $ case result of
    Left err ->
      Left
        ( "cannot prepare the external decommission directory: "
            <> Text.pack (show (err :: IOException))
        )
    Right () -> Right ()

ensureVerifierExport
  :: ExternalArtifactPath
  -> VerifierArtifact
  -> IO (Either Text VerifierBinding)
ensureVerifierExport artifactPath artifact = do
  let expected = verifierBindingOf artifactPath artifact
      paths =
        [ externalArtifactPath artifactPath
        , verifierDependencyPath artifactPath
        , verifierMetadataPath artifactPath
        ]
  present <- mapM doesFileExist paths
  case present of
    [False, False, False] -> do
      exported <- exportVerifierArtifact artifactPath artifact
      pure
        ( first
            (\err -> "cannot durably export the pinned verifier: " <> Text.pack (show err))
            exported
        )
    [True, True, True] -> do
      preflight <- runVerifierPreflight expected
      pure $ case preflight of
        VerifierReady _ -> Right expected
        VerifierRefused refusal ->
          Left
            ( "existing pinned verifier does not match the running build: "
                <> Text.pack (show refusal)
            )
    _ ->
      pure
        ( Left
            "partial pinned-verifier export exists; artifact, .deps, and .meta must all be absent or all match exactly"
        )

validateProductionManifest
  :: VerifierBinding
  -> DecommissionLocalDataDisposition
  -> VerifiedDecommissionManifest
  -> Either Text ()
validateProductionManifest expectedBinding requestedDisposition verified
  | verifiedVerifierBinding verified /= expectedBinding =
      Left "Authority signed a different verifier binding than the exported pinned runner"
  | not (null cardinalityErrors) =
      Left
        ( "Authority signed an incomplete production decommission manifest: "
            <> Text.intercalate
              "; "
              (map renderDecommissionPlanCardinalityError cardinalityErrors)
        )
  | signedDispositions /= [requestedDisposition] =
      Left
        ( "Authority signed a retained-local-data disposition the operator did not"
            <> " request; requested="
            <> decommissionLocalDataDispositionText requestedDisposition
            <> ", signed="
            <> Text.intercalate
              ","
              (map decommissionLocalDataDispositionText signedDispositions)
        )
  | length targetReferences > 1 =
      Left "Authority signed more than one production Target Agent generation"
  | any (/= manifestClusterId plan) targetReferences =
      Left "Authority signed a Target Agent reference outside the production cluster identity"
  | not (null nodesWithoutInterpreter) =
      Left
        ( "Authority signed nodes with no compiled decommission interpreter"
            <> " identity in the signed registry: "
            <> Text.pack (show nodesWithoutInterpreter)
        )
  | otherwise = Right ()
 where
  plan = verifiedManifestPlan verified
  nodes = manifestNodes plan
  targetReferences = [reference | TargetGeneration reference _ <- nodes]
  -- Sprint 4.85: every mandatory-node refusal is derived from the closed
  -- family classification rather than authored here. A newly added mandatory
  -- node -- singleton or parameterized choice -- was otherwise silently
  -- optional: the verifier would accept a manifest that never names it.
  cardinalityErrors =
    fromLeft [] (validateDecommissionPlanCardinality nodes)
  -- The cardinality check proves exactly one disposition node is present; this
  -- proves it carries the decision the operator actually typed. Without it a
  -- compromised or defective Authority could sign `retain` over an operator's
  -- `delete` and the run would converge reporting success.
  signedDispositions = [disposition | LocalDataDisposition disposition <- nodes]
  nodesWithoutInterpreter =
    [node | node <- nodes, nukeNodeInterpreterIdentity node == Nothing]

-- | The compiled interpreter identity for a node, taken from the closed
-- semantic tag universe rather than authored here.
--
-- Sprint 4.85: this was a second authored copy of
-- 'decommissionRunnerInterpreterIdentity', joined to neither the tag universe
-- nor 'nukeInterpreterRegistryIdentity' — the list whose digest is actually
-- signed. 'Nothing' is now reachable (a node whose tag the runner does not
-- interpret), which is what makes the production-manifest check above a real
-- refusal instead of a non-empty-literal test no arm could fail.
nukeNodeInterpreterIdentity :: DecommissionNode -> Maybe Text
nukeNodeInterpreterIdentity =
  decommissionRunnerInterpreterIdentity . decommissionNodeProgramTag

productionCapabilities
  :: ProductionNukeRemoteCapabilities
  -> VerifiedDecommissionManifest
  -> AwsSesDecommissionPrimitive 'AwsSesSmtpIamOnly IO
  -> ProductionLongLivedDecommissionCapabilities IO
  -> AwsSesDecommissionPrimitive 'AwsSesProviderOnly IO
  -> FinalNoRetentionAuditCapability IO
  -> HomeSubstrateUninstallCapability IO
  -> LocalDataDispositionCapability IO
  -> DecommissionTerminalReceiptCapability IO
  -> ProductionDecommissionCapabilities IO
productionCapabilities
  remote
  verified
  smtpPrimitive
  longLived
  providerPrimitive
  finalAudit
  homeUninstall
  localData
  terminalReceipt =
    ProductionDecommissionCapabilities
      { productionSesConsumerQuiescence = productionSesConsumersQuiescence remote
      , productionSesProviderStack = awsSesProviderStackCapability providerPrimitive
      , productionSesSmtpIam = awsSesSmtpIamCapability smtpPrimitive
      , productionTargetGenerationTombstone =
          productionTargetGenerationTombstones remote verified
      , productionRetainedCustodyTombstone =
          productionRetainedCustodyTombstones remote verified
      , productionTlsRetainedObjects =
          productionTlsRetainedObjectsCapability longLived
      , productionTlsRetentionIdentity =
          productionTlsRetentionIdentityCapability longLived
      , productionBackupObjectsIdentity =
          productionBackupObjectsIdentityCapability longLived
      , productionBackupAllPrefixesAbsent =
          productionBackupAllPrefixesAbsentCapability longLived
      , productionSharedObjectBucket =
          productionSharedObjectBucketCapability longLived
      , productionFinalNoRetentionAudit = finalAudit
      , productionHomeSubstrateUninstall = homeUninstall
      , productionLocalDataDisposition = localData
      , productionDecommissionTerminalReceipt = terminalReceipt
      }

nukeMaximumFrameBytes :: Int
nukeMaximumFrameBytes = 64 * 1024

renderExternalPathFailure :: (Show err) => err -> Text
renderExternalPathFailure err =
  "external verifier/receipt path validation refused: " <> Text.pack (show err)

-- | Selected linked-package identities compiled into the executable.  The
-- bytes are exported next to the exact runner and their digest is signed into
-- the manifest; no mutable repository file or ambient package database is
-- consulted during preparation or resume.
nukeRunnerDependencyMetadata :: ByteString
nukeRunnerDependencyMetadata =
  Char8.pack
    ( unlines
        [ "prodbox-decommission-runner-dependencies-v1"
        , "compiler=" ++ compilerName ++ "-" ++ showVersion compilerVersion
        , "prodbox=" ++ VERSION_prodbox
        , "aeson=" ++ VERSION_aeson
        , "aeson-pretty=" ++ VERSION_aeson_pretty
        , "async=" ++ VERSION_async
        , "base=" ++ VERSION_base
        , "base64-bytestring=" ++ VERSION_base64_bytestring
        , "bytestring=" ++ VERSION_bytestring
        , "case-insensitive=" ++ VERSION_case_insensitive
        , "cborg=" ++ VERSION_cborg
        , "co-log=" ++ VERSION_co_log
        , "co-log-core=" ++ VERSION_co_log_core
        , "containers=" ++ VERSION_containers
        , "crypton=" ++ VERSION_crypton
        , "memory=" ++ VERSION_memory
        , "cryptohash-sha1=" ++ VERSION_cryptohash_sha1
        , "cryptohash-sha256=" ++ VERSION_cryptohash_sha256
        , "dhall=" ++ VERSION_dhall
        , "either=" ++ VERSION_either
        , "exceptions=" ++ VERSION_exceptions
        , "directory=" ++ VERSION_directory
        , "filepath=" ++ VERSION_filepath
        , "fsnotify=" ++ VERSION_fsnotify
        , "crypton-connection=" ++ VERSION_crypton_connection
        , "crypton-x509-store=" ++ VERSION_crypton_x509_store
        , "http-client=" ++ VERSION_http_client
        , "http-client-tls=" ++ VERSION_http_client_tls
        , "http-types=" ++ VERSION_http_types
        , "tls=" ++ VERSION_tls
        , "network=" ++ VERSION_network
        , "optparse-applicative=" ++ VERSION_optparse_applicative
        , "scientific=" ++ VERSION_scientific
        , "serialise=" ++ VERSION_serialise
        , "stm=" ++ VERSION_stm
        , "temporary=" ++ VERSION_temporary
        , "text=" ++ VERSION_text
        , "time=" ++ VERSION_time
        , "transformers=" ++ VERSION_transformers
        , "typed-process=" ++ VERSION_typed_process
        , "unix=" ++ VERSION_unix
        , "vector=" ++ VERSION_vector
        , "websockets=" ++ VERSION_websockets
        , "wuss=" ++ VERSION_wuss
        ]
    )

nukeVerifierMetadata :: Either Text VerifierMetadata
nukeVerifierMetadata =
  first
    (\err -> "invalid compiled nuke verifier metadata: " <> Text.pack (show err))
    ( mkVerifierMetadata
        (contentDigest nukeRunnerDependencyMetadata)
        currentManifestVersion
        (contentDigest nukeManifestSchemaIdentity)
        nukeInterpreterRegistryVersion
        (contentDigest nukeInterpreterRegistryIdentity)
    )

-- | Sprint 4.85: bumped to @2@ when 'FinalNoRetentionAudit' gave the runner its
-- first interpreter for the total-decommission escape audit, to @3@ when
-- 'HomeSubstrateUninstall' gave it the local-foundation uninstaller, and to @4@
-- when 'LocalDataDisposition' gave it the retained-local-data disposition, and
-- to @5@ when 'DecommissionTerminalReceipt' gave it the terminal-convergence
-- read-back. The registry identity the Authority signs genuinely changed each
-- time, so a receipt signed under an earlier version must not verify against
-- this runner.
nukeInterpreterRegistryVersion :: Word
nukeInterpreterRegistryVersion = 5

nukeManifestSchemaIdentity :: ByteString
nukeManifestSchemaIdentity =
  Char8.unlines
    [ "prodbox-decommission-manifest-schema-v1"
    , "cluster-id:text"
    , "nodes:ordered-unique"
    , "target-generation:(target-ref:text,generation:positive-natural)"
    , "verifier-binding:(absolute-path,artifact-digest,dependency/schema/registry-metadata)"
    ]

-- | The interpreter inventory whose digest the Authority signs into
-- 'VerifierMetadata'.
--
-- Sprint 4.85: derived from the closed decommission tag universe. It was a
-- hand-authored list of ten strings sitting beside a @case@ of the same ten,
-- with nothing joining either to the node universe — so a node implemented with
-- a new interpreter would have been absent from the identity the operator
-- signs, while a manifest naming that node still verified. The derived bytes
-- are identical to the authored ones, so this is a cannot-drift guard rather
-- than a signed-identity change.
nukeInterpreterRegistryIdentity :: ByteString
nukeInterpreterRegistryIdentity =
  Char8.unlines
    ( "prodbox-decommission-interpreter-registry-v1"
        : map (Char8.pack . Text.unpack) decommissionRunnerInterpreterRegistry
    )

nukeInteractiveGuard :: InteractiveGuard
nukeInteractiveGuard =
  InteractiveGuard
    { guardCommand = "prodbox nuke"
    , guardAutomationHint =
        unlines
          [ "prodbox nuke has no command-by-command automation substitute."
          , "Automation must supply the same signed external manifest, pinned"
          , "runner artifact, acknowledged receipt, and complete node registry."
          , "Broad aws/cluster teardown commands are not a decommission receipt."
          ]
    }

runNukeCommand :: FilePath -> NukeOptions -> IO ExitCode
runNukeCommand = runNukeCommandWithComposition productionDecommissionAvailability

runNukeCommandWithComposition
  :: ProductionDecommissionAvailability
  -> FilePath
  -> NukeOptions
  -> IO ExitCode
runNukeCommandWithComposition availability repoRoot options =
  runPlanWithOptions
    PlanOptions {dryRun = nukeDryRun options, planFile = nukePlanFile options}
    ( buildPlan
        ( const
            ( renderNukePlanWithReceipt
                repoRoot
                (nukeReceiptPath options)
                requestedDisposition
            )
        )
        ()
    )
    ( \() ->
        runNukeInteractive
          availability
          repoRoot
          (nukeReceiptPath options)
          requestedDisposition
    )
 where
  requestedDisposition =
    fmap localDataDispositionOf (nukeLocalDataDisposition options)

-- | The one place the CLI's parsed argument becomes the lifecycle-owned
-- decision the manifest carries.
localDataDispositionOf
  :: NukeLocalDataDisposition -> DecommissionLocalDataDisposition
localDataDispositionOf parsed = case parsed of
  NukeRetainLocalData -> RetainLocalData
  NukeDeleteLocalData -> DeleteLocalData

-- | Apply refuses without an explicit disposition. There is no default: both
-- candidates silently decide the fate of the retained data root, and one of
-- them is irreversible.
requireLocalDataDisposition
  :: Maybe DecommissionLocalDataDisposition
  -> Either Text DecommissionLocalDataDisposition
requireLocalDataDisposition supplied = case supplied of
  Nothing ->
    Left
      "prodbox nuke apply requires --local-data <retain|delete>; --dry-run may omit it"
  Just disposition -> Right disposition

runNukeInteractive
  :: ProductionDecommissionAvailability
  -> FilePath
  -> Maybe FilePath
  -> Maybe DecommissionLocalDataDisposition
  -> IO ExitCode
runNukeInteractive availability repoRoot suppliedReceipt suppliedDisposition =
  case availability of
    ProductionDecommissionReady composition ->
      case (,)
        <$> requireExternalReceiptPath suppliedReceipt
        <*> requireLocalDataDisposition suppliedDisposition of
        Left detail -> refuse detail
        Right (receiptPath, localDataDisposition) -> do
          requireInteractiveTty nukeInteractiveGuard
          writeOutputLine "prodbox nuke — authenticated total decommission."
          writeOutputLine ""
          writeOutputLine "This executes the signed dependency-ordered decommission manifest, including:"
          writeOutputLine "  - SES consumer quiescence, provider-stack and SMTP-IAM absence"
          writeOutputLine "  - still-live Target-Agent generation and retained-custody tombstones"
          writeOutputLine "  - TLS objects and TLS identity before Authority-backup objects"
          writeOutputLine "  - all-prefix absence proof before the shared bucket is destroyed last"
          writeOutputLine ("  - external receipt: " ++ externalReceiptPath receiptPath)
          writeOutputLine
            ( "  - retained local data root: "
                ++ Text.unpack
                  (decommissionLocalDataDispositionText localDataDisposition)
            )
          writeOutputLine ""
          writeOutputLine ("Type `" ++ confirmationLiteral ++ "` to begin preparation (case-sensitive).")
          writeOutputLine "Anything else aborts without creating the external receipt."
          writeOutputLine ""
          writeOutput "> "
          hFlush stdout
          typed <- getLine
          if normalizeConfirmation typed == confirmationLiteral
            then
              runNukeOrchestration
                composition
                receiptPath
                repoRoot
                localDataDisposition
            else do
              writeDiagnosticLine "prodbox nuke: confirmation rejected; nothing destroyed."
              pure (ExitFailure 1)

runNukeOrchestration
  :: NukeDecommissionComposition
  -> ExternalReceiptPath
  -> FilePath
  -> DecommissionLocalDataDisposition
  -> IO ExitCode
runNukeOrchestration composition receiptPath repoRoot localDataDisposition = do
  writeOutputLine ""
  writeOutputLine "prodbox nuke: acquiring one ephemeral admin AWS credential."
  adminResult <- loadAdminAwsCredentials repoRoot
  case adminResult of
    Left err -> do
      writeError (fatalError (Text.pack ("nuke aborted while loading admin credentials: " ++ err)))
      pure (ExitFailure 1)
    Right adminCredentials -> do
      preparedResult <-
        prepareNukeDecommission
          composition
          receiptPath
          repoRoot
          localDataDisposition
          adminCredentials
      case preparedResult of
        Left detail -> refuse ("decommission preparation refused: " <> detail)
        Right prepared -> do
          runPreparedNuke prepared

-- | Sprint 4.85: the terminal scoped tag sweep, as the read-back half of the
-- receipt graph's 'FinalNoRetentionAudit' node.
--
-- Sprint 4.76 gave this sweep its first call site — the doctrine had assigned
-- it to @nuke@ all along and nothing ran it — but it ran **outside** the
-- receipt graph, after 'runPreparedNuke' had already returned success. A crash
-- or a lost response there could not resume through the manifest: the run had
-- converged on paper while the only proof that nothing escaped had never been
-- taken, and re-running @nuke@ would start from a plan whose every node was
-- already terminal.
--
-- As a node it is read-only by construction — 'FinalNoRetentionAuditCapability'
-- has no destructive half — and it inherits the graph's durable intent, stable
-- attempt identity, and authoritative re-observation on resume.
--
-- It remains fail-closed with no skip arm. @nuke@ has already refused without
-- an ephemeral admin credential by the time this runs, so "the API could not be
-- read" is the only unconfirmed case and it is 'ResidueUnreachable', which
-- 'classifyNodeObservation' refuses. Unlike the cascade's sweep it applies
-- **no** retained-long-lived carve-out ('TagSweep.TagSweepNuke'), because
-- destroying that class transitively is what @nuke@ is for — a surviving
-- @pulumi_state_backend@ bucket or @aws-ses@ resource is an escapee here, not a
-- resource retained by design.
productionFinalNoRetentionAuditCapability
  :: FilePath -> Credentials -> FinalNoRetentionAuditCapability IO
productionFinalNoRetentionAuditCapability repoRoot adminCredentials =
  FinalNoRetentionAuditCapability $ \_nodeId _attemptId -> do
    environment <- awsCliSubprocessEnvironment adminCredentials
    verdict <-
      TagSweep.decideTagSweep TagSweep.TagSweepNuke
        <$> TagSweep.discoverClusterTaggedAwsResources
          TagSweep.TagSweepInput
            { TagSweep.tagSweepEnvironment = environment
            , TagSweep.tagSweepClusterName = Just awsEksCanonicalClusterName
            , TagSweep.tagSweepWorkingDirectory = Just repoRoot
            }
    let narration = TagSweep.renderTagSweepVerdict TagSweep.TagSweepNuke verdict
    -- The three verdicts stay three. Collapsing "escapees found" and "the
    -- Tagging API could not be read" into one failure would record the wrong
    -- fact in the receipt: an escapee is a resource that survived, while an
    -- unreadable API is an absence nobody observed. Both refuse the node, and
    -- the receipt says which happened.
    pure $ case verdict of
      TagSweep.TagSweepConfirmedClean _ -> ResidueAbsent
      TagSweep.TagSweepEscaped _ _ ->
        ResiduePresent
          ResidueDetails
            { residueEvidence = narration
            , residueStackName = "total-decommission-escape-audit"
            }
      TagSweep.TagSweepUnconfirmed detail ->
        ResidueUnreachable (ResidueQueryFailed detail)

-- | Sprint 4.85: the home-substrate uninstall as the last node of the signed
-- receipt graph.
--
-- The compiled @TotalDecommission@ program has emitted
-- @decommission/uninstall-local@ and its read-back since the program algebra
-- landed, and no runner executed either: a total decommission destroyed every
-- AWS resource class and left the local RKE2 substrate installed.
--
-- The stable 'CleanupOperationId' is __derived from the receipt attempt__ rather
-- than freshly generated. That is the property the whole graph rests on: the
-- uninstaller is invoked under an identity the durable intent already recorded,
-- so a lost response resumes by re-observing markers under the same operation
-- instead of running a second uninstall.
--
-- The destroy half is deliberately not the read-back.
-- 'attemptLocalRke2Uninstall' distinguishes applied, already-absent, refused,
-- and response-lost, and only a fresh all-markers-absent observation closes the
-- node — so an uninstaller that exits zero without removing the install cannot
-- report success.
productionHomeSubstrateUninstallCapability
  :: FilePath -> HomeSubstrateUninstallCapability IO
productionHomeSubstrateUninstallCapability repoRoot =
  HomeSubstrateUninstallCapability
    NodeOperation
      { nodeDestroy = \_nodeId attemptId -> uninstallHomeSubstrate adapter attemptId
      , nodeReadBack = \_nodeId _attemptId ->
          homeSubstrateInstallResidue <$> observeLocalRke2Install adapter
      }
 where
  adapter = productionLocalRke2TerminalAdapter repoRoot

-- | Run the uninstaller under the identity the durable intent recorded.
uninstallHomeSubstrate
  :: LocalRke2TerminalAdapter IO -> FrameAttemptId -> IO (Either Text ())
uninstallHomeSubstrate adapter attemptId =
  case mkCleanupOperationId (frameAttemptIdText attemptId) of
    Left detail ->
      pure (Left ("home substrate uninstall has no stable operation identity: " <> detail))
    Right operationId ->
      homeSubstrateUninstallOutcome
        . localRke2UninstallResultToHostEffect
        <$> attemptLocalRke2Uninstall adapter operationId

-- | A response loss is not a refusal: the runner re-observes markers under the
-- same attempt rather than mutating again, so both arms stay distinct here.
homeSubstrateUninstallOutcome :: HostCleanupEffectOutcome -> Either Text ()
homeSubstrateUninstallOutcome outcome = case outcome of
  HostCleanupEffectApplied -> Right ()
  HostCleanupEffectResponseLost detail ->
    Left ("home substrate uninstall response lost: " <> detail)
  HostCleanupEffectRefused detail ->
    Left ("home substrate uninstall refused: " <> detail)

-- | Only an all-markers-absent observation closes the node. Surviving markers
-- and unobservable markers are different facts and neither is absence.
homeSubstrateInstallResidue :: LocalRke2InstallObservation -> ResidueStatus
homeSubstrateInstallResidue observed = case observed of
  LocalRke2InstallAbsent _ -> ResidueAbsent
  LocalRke2InstallPresent markers _ ->
    ResiduePresent
      ResidueDetails
        { residueEvidence =
            "surviving local RKE2 install markers: " ++ show (NonEmpty.toList markers)
        , residueStackName = "home-substrate-uninstall"
        }
  LocalRke2InstallUnconfirmed failures ->
    ResidueUnreachable
      ( ResidueQueryFailed
          ( "local RKE2 install markers could not be observed: "
              ++ show (NonEmpty.toList failures)
          )
      )

-- | Sprint 4.85: the operator's retained-local-data disposition as the last
-- node of the signed receipt graph.
--
-- @nuke@ named the manual PV host root as a deletion root from the day the
-- external-path guard landed, and nothing ever disposed of it: a total
-- decommission destroyed every AWS resource class, uninstalled the home
-- substrate, and left the retained data tree on disk with no record of whether
-- that was intended.
--
-- The decision is taken from the __signed manifest node__ rather than from the
-- composition, so a capability built on a host cannot delete under a plan that
-- said retain. The stable 'Prodbox.Lifecycle.CleanupRun.CleanupOperationId' is
-- derived from the receipt attempt, exactly as the home uninstall derives its
-- own: a lost removal response resumes by re-observing the root under the same
-- operation instead of issuing a second removal.
--
-- The read-back is disposition-indexed and refuses in both directions. A
-- surviving root under @delete@ and a missing root under @retain@ are both
-- residue; an unobservable root is neither, and closes nothing.
productionLocalDataDispositionCapability
  :: LocalDataRootPath -> FilePath -> LocalDataDispositionCapability IO
productionLocalDataDispositionCapability root repoRoot =
  LocalDataDispositionCapability $ \disposition ->
    NodeOperation
      { nodeDestroy = \_nodeId attemptId ->
          applyLocalDataDisposition adapter disposition attemptId
      , nodeReadBack = \_nodeId _attemptId ->
          localDataDispositionResidue root disposition
            <$> observeLocalDataRoot adapter
      }
 where
  adapter = productionLocalDataTerminalAdapter root repoRoot

applyLocalDataDisposition
  :: LocalDataTerminalAdapter IO
  -> DecommissionLocalDataDisposition
  -> FrameAttemptId
  -> IO (Either Text ())
applyLocalDataDisposition adapter disposition attemptId =
  case mkCleanupOperationId (frameAttemptIdText attemptId) of
    Left detail ->
      pure
        ( Left
            ( "retained local data disposition has no stable operation identity: "
                <> detail
            )
        )
    Right operationId ->
      classifyLocalDataDisposition
        <$> attemptLocalDataDisposition adapter disposition operationId

-- | Sprint 4.85: the terminal-receipt node's read-back.
--
-- The receipt records each node's intent, observation, and result, and never
-- recorded that the __run__ converged. A receipt ending at the last node's
-- result frame is byte-identical to one whose run crashed immediately after
-- that frame; @reportConverged@ is the only place that fact existed, and it
-- lives in the process that produced it.
--
-- The node closes that gap by being last in the derived order and refusing
-- unless the durable record already carries a terminal success for every other
-- node of the signed plan. Its own success frame is then the declaration, and
-- it is written through the same fsync/reopen/validate append primitive as
-- every other frame — so a crash before it leaves a receipt that visibly does
-- not claim convergence, and a resume re-observes rather than assuming.
--
-- The read is deliberately read-only: 'readBoundReceiptFramesReadOnly' refuses
-- a torn tail instead of repairing it, because this node reads the very record
-- it is a node of and must not mutate the history it is proving something
-- about. The three verdicts stay three — outstanding nodes are residue, an
-- unreadable or semantically refused receipt is an absence nobody observed.
productionDecommissionTerminalReceiptCapability
  :: VerifiedDecommissionManifest
  -> ExternalReceiptPath
  -> DecommissionTerminalReceiptCapability IO
productionDecommissionTerminalReceiptCapability verified receiptPath =
  DecommissionTerminalReceiptCapability $ \_nodeId _attemptId -> do
    framesResult <-
      readBoundReceiptFramesReadOnly
        nukeMaximumFrameBytes
        verified
        (externalReceiptPath receiptPath)
    pure $ case framesResult of
      Left refusal ->
        ResidueUnreachable
          ( ResidueQueryFailed
              ("the external decommission receipt could not be read: " ++ show refusal)
          )
      Right frames ->
        case decommissionRunTerminalEvidence
          (manifestNodes (verifiedManifestPlan verified))
          DecommissionTerminalReceipt
          frames of
          Right () -> ResidueAbsent
          Left err ->
            ResiduePresent
              ResidueDetails
                { residueEvidence =
                    Text.unpack (renderDecommissionRunTerminalError err)
                , residueStackName = "decommission-terminal-receipt"
                }

requireExternalReceiptPath :: Maybe FilePath -> Either Text ExternalReceiptPath
requireExternalReceiptPath supplied = case supplied of
  Nothing ->
    Left
      "prodbox nuke apply requires --receipt <absolute-external-path>; --dry-run may omit it"
  Just raw ->
    first
      (\err -> "invalid external decommission receipt path: " <> Text.pack (show err))
      (mkExternalReceiptPath raw)

runPreparedNuke :: PreparedNukeDecommission -> IO ExitCode
runPreparedNuke prepared = do
  preflightResult <-
    runVerifierPreflight (verifiedVerifierBinding (preparedVerifiedManifest prepared))
  case preflightResult of
    VerifierRefused refusal ->
      refuse ("pinned runner preflight refused: " <> Text.pack (show refusal))
    VerifierReady preflighted -> do
      arguments <- getArgs
      let executionDecision =
            decidePinnedArtifactExecution
              preflighted
              (preparedRunningVerifierIdentity prepared)
      replacementResult <-
        try (replaceWithPinnedVerifier arguments executionDecision)
          :: IO (Either IOException PinnedProcessTransition)
      case replacementResult of
        Left err -> refuse ("pinned runner process replacement failed: " <> Text.pack (show err))
        Right (PinnedProcessReplacementInvoked _) ->
          refuse "pinned runner process replacement unexpectedly returned"
        Right PinnedProcessAlreadyCurrent -> acknowledgeAndRun prepared

acknowledgeAndRun :: PreparedNukeDecommission -> IO ExitCode
acknowledgeAndRun prepared = do
  let pending = preparedExternalReceipt prepared
      receiptPath = externalReceiptPath (pendingExternalReceiptPath pending)
      acknowledgement = receiptAcknowledgementLiteral pending
  writeOutputLine ""
  writeOutputLine ("External receipt durably initialized and read back at: " ++ receiptPath)
  writeOutputLine "Authority permanent stop and destructive effects remain forbidden."
  writeOutputLine "Type the following exact receipt acknowledgement to cross the point of no return:"
  writeOutputLine (Text.unpack acknowledgement)
  writeOutput "> "
  hFlush stdout
  supplied <- Text.pack <$> getLine
  case acknowledgeExternalReceipt supplied pending of
    Left _ -> refuse "external receipt acknowledgement rejected; no destructive effect was run"
    Right acknowledged -> do
      entered <- preparedEnterPointOfNoReturn prepared acknowledged
      case entered of
        Left detail -> refuse ("point-of-no-return transition refused: " <> detail)
        Right () -> executeAcknowledgedRun prepared acknowledged

executeAcknowledgedRun
  :: PreparedNukeDecommission
  -> AcknowledgedExternalReceipt
  -> IO ExitCode
executeAcknowledgedRun prepared acknowledged = do
  outcome <-
    runBoundDecommission
      (preparedMaximumFrameBytes prepared)
      (preparedVerifiedManifest prepared)
      (preparedRunningVerifierIdentity prepared)
      acknowledged
      (preparedAttemptIdFor prepared)
      ( decommissionInterpreterFromRegistry
          (decommissionRegistryFromProductionCapabilities (preparedProductionCapabilities prepared))
      )
  case outcome of
    Left refusal -> refuse ("decommission runner refused: " <> Text.pack (show refusal))
    Right report
      | reportConverged report -> do
          writeOutputLine "prodbox nuke: authenticated decommission converged."
          pure ExitSuccess
      | otherwise -> do
          writeDiagnosticLine
            ( "prodbox nuke: decommission incomplete; failed="
                ++ show (reportFailed report)
                ++ "; blocked="
                ++ show (reportBlocked report)
                ++ ". Re-run the pinned artifact against the same external receipt."
            )
          pure (ExitFailure 1)

renderNukePlan :: FilePath -> String
renderNukePlan repoRoot = renderNukePlanWithReceipt repoRoot Nothing Nothing

renderNukePlanWithReceipt
  :: FilePath
  -> Maybe FilePath
  -> Maybe DecommissionLocalDataDisposition
  -> String
renderNukePlanWithReceipt _repoRoot suppliedReceipt localDataDisposition =
  unlines
    ( [ "PRODBOX_NUKE_PLAN"
      , "PROTOCOL=signed-external-decommission-v1"
      , "EXTERNAL_RECEIPT=" ++ renderedReceipt
      , "PINNED_RUNNER=" ++ renderedRunner
      , "GATE=freeze admission; commit and authenticate complete manifest"
      , "GATE=export/fsync/read-back exact runner, dependency closure, schema and registry metadata outside every deletion root"
      , "GATE=create/fsync/read-back external receipt and require its exact acknowledgement"
      , "GATE=execute only the pinned artifact; a new/missing/drifted build refuses"
      , "LOCAL_DATA=" ++ renderedLocalData
      ]
        ++ nukePlanNodeLines localDataDisposition
        ++ [ "RECEIPT=durable intent before every effect; authoritative read-back; stable attempt on resume"
           , "ADMIN_CREDENTIAL_SOURCE=one ephemeral admin AWS credential from the interactive prompt; never persisted"
           , "STATUS=plan-only"
           , "CONFIRMATION_LITERAL=" ++ confirmationLiteral
           , "APPLY_READINESS=fail closed unless the complete production node registry and Authority export composition are supplied"
           ]
    )
 where
  renderedReceipt = maybe "<required-for-apply>" id suppliedReceipt
  renderedRunner = maybe "<derived-from-external-receipt>.runner" (++ ".runner") suppliedReceipt
  renderedLocalData =
    maybe
      "<required-for-apply>"
      (Text.unpack . decommissionLocalDataDispositionText)
      localDataDisposition

-- | The @NODE=@ lines of the @--dry-run@ plan, derived from the inventory the
-- Authority will actually sign.
--
-- Sprint 4.85: these were a sixth hand-authored copy of the node universe, with
-- their own third set of names, joined to nothing. This is the artifact an
-- operator reads and approves before running the real command, so a node added
-- to the signed plan would have been destroyed without ever appearing in the
-- plan that authorized it.
--
-- Both annotations are derived rather than asserted: the parameterized note is
-- attached to the node the plan carries a representative of, and the terminal
-- note only to whatever the derived order actually ends with.
nukePlanNodeLines :: Maybe DecommissionLocalDataDisposition -> [String]
nukePlanNodeLines suppliedDisposition =
  [ "NODE="
      ++ Text.unpack (decommissionProgramTagText (decommissionNodeProgramTag node))
      ++ annotation node
  | node <- plannedNodes
  ]
 where
  -- The layout disposition is only ever a placeholder for the /position/ of
  -- the mandatory choice node, which every decision in the family shares. The
  -- decision the plan reports is the operator's, and `--dry-run` says so
  -- rather than inventing one.
  plannedNodes =
    productionDecommissionPlanNodes
      (fromMaybe layoutDisposition suppliedDisposition)
      representativeTargetGeneration
  layoutDisposition = RetainLocalData
  representativeTargetGeneration =
    [ TargetGeneration "target/plan-representative" generation
    | Right generation <- [mkDecommissionTargetGeneration 1]
    ]
  terminalNode = case reverse plannedNodes of
    (final : _) -> Just final
    [] -> Nothing
  -- Both notes are derived rather than asserted: the family note comes from
  -- the node's own cardinality classification, and the terminal note attaches
  -- only to whatever the derived order actually ends with. Sprint 4.85 moved
  -- that terminal from the home uninstall to the disposition node, and the
  -- rendered plan followed without being edited.
  annotation node = familyNote node ++ terminalNote node
  familyNote node = case decommissionNodeFamily node of
    PerAgentTargetFamily -> " (one per signed manifest target)"
    MandatoryChoiceFamily _ ->
      " ("
        ++ maybe
          "<required-for-apply>"
          (Text.unpack . decommissionLocalDataDispositionText)
          suppliedDisposition
        ++ ")"
    MandatorySingletonFamily _ -> ""
  terminalNote node
    | Just node == terminalNode = " (unique terminal)"
    | otherwise = ""

abortOrContinue :: ExitCode -> IO ExitCode -> IO ExitCode
abortOrContinue ExitSuccess continuation = continuation
abortOrContinue failure@(ExitFailure _) _ = pure failure

normalizeConfirmation :: String -> String
normalizeConfirmation value = reverse (dropWhile (== ' ') (reverse value))

refuse :: Text -> IO ExitCode
refuse detail = do
  writeError (fatalError detail)
  pure (ExitFailure 1)
