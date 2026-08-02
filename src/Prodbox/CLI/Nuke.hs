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
  , nukeRunnerDependencyMetadata
  , nukeVerifierMetadata
  , renderNukePlan
  , runNukeCommand
  , runNukeCommandWithComposition
  )
where

import Control.Exception (IOException, try)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as Char8
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Version (showVersion)
import Prodbox.CLI.Command
  ( NukeOptions (..)
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
import Prodbox.Lifecycle.Decommission.Frame
  ( FrameAttemptId
  , contentDigest
  , frameAttemptIdForNode
  )
import Prodbox.Lifecycle.Decommission.Graph
  ( reportBlocked
  , reportConverged
  , reportFailed
  )
import Prodbox.Lifecycle.Decommission.Manifest
  ( DecommissionNode (..)
  , VerifiedDecommissionManifest
  , currentManifestVersion
  , decommissionNodeFrameId
  , manifestClusterId
  , manifestNodes
  , verifiedManifestPlan
  , verifiedVerifierBinding
  )
import Prodbox.Lifecycle.Decommission.NodeEffect
  ( NodeOperation (..)
  , ProductionDecommissionCapabilities (..)
  , RetainedCustodyTombstoneCapability (..)
  , SesConsumerQuiescenceCapability
  , TargetGenerationTombstoneCapability (..)
  , decommissionInterpreterFromRegistry
  , decommissionRegistryFromProductionCapabilities
  )
import Prodbox.Lifecycle.Decommission.Receipt
  ( AcknowledgedExternalReceipt
  , PendingExternalReceipt
  , acknowledgeExternalReceipt
  , pendingExternalReceiptPath
  , prepareExternalReceiptAcknowledgement
  , receiptAcknowledgementLiteral
  )
import Prodbox.Lifecycle.Decommission.Runner (runBoundDecommission)
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
import Prodbox.Lifecycle.ResidueStatus
  ( ResidueStatus (ResidueUnreachable)
  , ResidueUnreachableReason (ResidueQueryFailed)
  )
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
  NukeDecommissionComposition $ \receiptPath repoRoot credentials -> do
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
    { productionRequestDecommissionManifest = \verifier -> do
        result <-
          withLifecycleAuthorityAuthenticatedTransport authentication $ \transport ->
            requestAuthorityDecommissionManifestViaTransport
              transport
              (lifecycleAuthorityManifestSignerDigest authentication)
              verifier
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
  -> Credentials
  -> IO (Either Text PreparedNukeDecommission)
prepareProductionNukeDecommission remote receiptPath repoRoot credentials =
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
            credentials
            runningPath
            artifact

prepareWithRunningArtifact
  :: ProductionNukeRemoteCapabilities
  -> ExternalReceiptPath
  -> FilePath
  -> Credentials
  -> ExternalArtifactPath
  -> VerifierArtifact
  -> IO (Either Text PreparedNukeDecommission)
prepareWithRunningArtifact remote receiptPath repoRoot credentials runningPath artifact = do
  coordinateResult <- prepareProductionVerifierCoordinate receiptPath repoRoot artifact
  case coordinateResult of
    Left detail -> pure (Left detail)
    Right (hostPaths, exportedBinding) -> do
      longLivedResult <- loadProductionLongLivedDecommissionCapabilities repoRoot credentials
      case longLivedResult of
        Left detail -> pure (Left detail)
        Right longLived -> do
          smtpPrimitive <- awsSesSmtpIamDestroyPrimitive repoRoot credentials
          let providerPrimitive =
                awsSesProviderStackDestroyPrimitive repoRoot credentials
          manifestResult <- productionRequestDecommissionManifest remote exportedBinding
          case manifestResult of
            Left detail -> pure (Left ("Authority decommission export refused: " <> detail))
            Right verified ->
              case validateProductionManifest exportedBinding verified of
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

loadNukeDeletionRoots :: FilePath -> IO (Either Text [DeletionRootPath])
loadNukeDeletionRoots repoRoot = do
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
        Left detail -> Left ("cannot load Config for decommission path validation: " <> Text.pack detail)
        Right config ->
          let configuredManualRoot = Text.unpack (manual_pv_host_root (storage config))
              manualRoot =
                normalise
                  ( if isAbsolute configuredManualRoot
                      then configuredManualRoot
                      else canonicalRepo </> configuredManualRoot
                  )
              rawRoots =
                [ manualRoot
                , "/var/lib/rancher/rke2"
                , "/var/lib/rancher"
                , "/etc/rancher/rke2"
                , "/usr/local/bin/rke2"
                , "/usr/local/bin/rke2-killall.sh"
                , "/usr/local/bin/rke2-uninstall.sh"
                ]
           in first
                (\err -> "invalid compiled decommission deletion root: " <> Text.pack (show err))
                (traverse mkDeletionRootPath (nub rawRoots))

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
  -> VerifiedDecommissionManifest
  -> Either Text ()
validateProductionManifest expectedBinding verified
  | verifiedVerifierBinding verified /= expectedBinding =
      Left "Authority signed a different verifier binding than the exported pinned runner"
  | not (null missingSingletons) =
      Left
        ( "Authority signed an incomplete production decommission manifest; missing nodes: "
            <> Text.pack (show missingSingletons)
        )
  | length targetReferences > 1 =
      Left "Authority signed more than one production Target Agent generation"
  | any (/= manifestClusterId plan) targetReferences =
      Left "Authority signed a Target Agent reference outside the production cluster identity"
  | not (all (not . ByteString.null . nukeNodeProgramTag) nodes) =
      Left "Authority signed a node without a compiled decommission interpreter tag"
  | otherwise = Right ()
 where
  plan = verifiedManifestPlan verified
  nodes = manifestNodes plan
  targetReferences = [reference | TargetGeneration reference _ <- nodes]
  missingSingletons = filter (`notElem` nodes) requiredSingletonNodes

requiredSingletonNodes :: [DecommissionNode]
requiredSingletonNodes =
  [ SesConsumerQuiescence
  , SesProviderStack
  , SesSmtpIam
  , RetainedCustody
  , TlsRetainedObjects
  , TlsRetentionIdentity
  , BackupObjects
  , BackupPrefixAbsenceProof
  , SharedObjectBucket
  ]

nukeNodeProgramTag :: DecommissionNode -> ByteString
nukeNodeProgramTag node = case node of
  SesConsumerQuiescence -> "ses-consumer-quiescence-v1"
  SesProviderStack -> "ses-provider-stack-v1"
  SesSmtpIam -> "ses-smtp-iam-v1"
  TargetGeneration _ _ -> "target-generation-v1"
  RetainedCustody -> "retained-custody-v1"
  TlsRetainedObjects -> "tls-retained-objects-v1"
  TlsRetentionIdentity -> "tls-retention-identity-v1"
  BackupPrefixAbsenceProof -> "backup-prefix-absence-proof-v1"
  BackupObjects -> "backup-objects-identity-v1"
  SharedObjectBucket -> "shared-object-bucket-v1"

productionCapabilities
  :: ProductionNukeRemoteCapabilities
  -> VerifiedDecommissionManifest
  -> AwsSesDecommissionPrimitive 'AwsSesSmtpIamOnly IO
  -> ProductionLongLivedDecommissionCapabilities IO
  -> AwsSesDecommissionPrimitive 'AwsSesProviderOnly IO
  -> ProductionDecommissionCapabilities IO
productionCapabilities
  remote
  verified
  smtpPrimitive
  longLived
  providerPrimitive =
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

nukeInterpreterRegistryVersion :: Word
nukeInterpreterRegistryVersion = 1

nukeManifestSchemaIdentity :: ByteString
nukeManifestSchemaIdentity =
  Char8.unlines
    [ "prodbox-decommission-manifest-schema-v1"
    , "cluster-id:text"
    , "nodes:ordered-unique"
    , "target-generation:(target-ref:text,generation:positive-natural)"
    , "verifier-binding:(absolute-path,artifact-digest,dependency/schema/registry-metadata)"
    ]

nukeInterpreterRegistryIdentity :: ByteString
nukeInterpreterRegistryIdentity =
  Char8.unlines
    [ "prodbox-decommission-interpreter-registry-v1"
    , "ses-consumer-quiescence-v1"
    , "ses-provider-stack-v1"
    , "ses-smtp-iam-v1"
    , "target-generation-v1"
    , "retained-custody-v1"
    , "tls-retained-objects-v1"
    , "tls-retention-identity-v1"
    , "backup-prefix-absence-proof-v1"
    , "backup-objects-identity-v1"
    , "shared-object-bucket-v1"
    ]

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
    (buildPlan (const (renderNukePlanWithReceipt repoRoot (nukeReceiptPath options))) ())
    (\() -> runNukeInteractive availability repoRoot (nukeReceiptPath options))

runNukeInteractive
  :: ProductionDecommissionAvailability
  -> FilePath
  -> Maybe FilePath
  -> IO ExitCode
runNukeInteractive availability repoRoot suppliedReceipt =
  case availability of
    ProductionDecommissionReady composition ->
      case requireExternalReceiptPath suppliedReceipt of
        Left detail -> refuse detail
        Right receiptPath -> do
          requireInteractiveTty nukeInteractiveGuard
          writeOutputLine "prodbox nuke — authenticated total decommission."
          writeOutputLine ""
          writeOutputLine "This executes the signed dependency-ordered decommission manifest, including:"
          writeOutputLine "  - SES consumer quiescence, provider-stack and SMTP-IAM absence"
          writeOutputLine "  - still-live Target-Agent generation and retained-custody tombstones"
          writeOutputLine "  - TLS objects and TLS identity before Authority-backup objects"
          writeOutputLine "  - all-prefix absence proof before the shared bucket is destroyed last"
          writeOutputLine ("  - external receipt: " ++ externalReceiptPath receiptPath)
          writeOutputLine ""
          writeOutputLine ("Type `" ++ confirmationLiteral ++ "` to begin preparation (case-sensitive).")
          writeOutputLine "Anything else aborts without creating the external receipt."
          writeOutputLine ""
          writeOutput "> "
          hFlush stdout
          typed <- getLine
          if normalizeConfirmation typed == confirmationLiteral
            then runNukeOrchestration composition receiptPath repoRoot
            else do
              writeDiagnosticLine "prodbox nuke: confirmation rejected; nothing destroyed."
              pure (ExitFailure 1)

runNukeOrchestration
  :: NukeDecommissionComposition
  -> ExternalReceiptPath
  -> FilePath
  -> IO ExitCode
runNukeOrchestration composition receiptPath repoRoot = do
  writeOutputLine ""
  writeOutputLine "prodbox nuke: acquiring one ephemeral admin AWS credential."
  adminResult <- loadAdminAwsCredentials repoRoot
  case adminResult of
    Left err -> do
      writeError (fatalError (Text.pack ("nuke aborted while loading admin credentials: " ++ err)))
      pure (ExitFailure 1)
    Right adminCredentials -> do
      preparedResult <- prepareNukeDecommission composition receiptPath repoRoot adminCredentials
      case preparedResult of
        Left detail -> refuse ("decommission preparation refused: " <> detail)
        Right prepared -> runPreparedNuke prepared

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
renderNukePlan repoRoot = renderNukePlanWithReceipt repoRoot Nothing

renderNukePlanWithReceipt :: FilePath -> Maybe FilePath -> String
renderNukePlanWithReceipt _repoRoot suppliedReceipt =
  unlines
    [ "PRODBOX_NUKE_PLAN"
    , "PROTOCOL=signed-external-decommission-v1"
    , "EXTERNAL_RECEIPT=" ++ renderedReceipt
    , "PINNED_RUNNER=" ++ renderedRunner
    , "GATE=freeze admission; commit and authenticate complete manifest"
    , "GATE=export/fsync/read-back exact runner, dependency closure, schema and registry metadata outside every deletion root"
    , "GATE=create/fsync/read-back external receipt and require its exact acknowledgement"
    , "GATE=execute only the pinned artifact; a new/missing/drifted build refuses"
    , "NODE=ses-consumer-quiescence"
    , "NODE=ses-provider-stack"
    , "NODE=ses-smtp-iam"
    , "NODE=target-generation (one per signed manifest target)"
    , "NODE=retained-custody"
    , "NODE=tls-retained-objects"
    , "NODE=tls-retention-identity"
    , "NODE=backup-objects-and-identity"
    , "NODE=backup-prefix-absence-proof"
    , "NODE=shared-object-bucket (unique terminal)"
    , "RECEIPT=durable intent before every effect; authoritative read-back; stable attempt on resume"
    , "ADMIN_CREDENTIAL_SOURCE=one ephemeral admin AWS credential from the interactive prompt; never persisted"
    , "STATUS=plan-only"
    , "CONFIRMATION_LITERAL=" ++ confirmationLiteral
    , "APPLY_READINESS=fail closed unless the complete production node registry and Authority export composition are supplied"
    ]
 where
  renderedReceipt = maybe "<required-for-apply>" id suppliedReceipt
  renderedRunner = maybe "<derived-from-external-receipt>.runner" (++ ".runner") suppliedReceipt

abortOrContinue :: ExitCode -> IO ExitCode -> IO ExitCode
abortOrContinue ExitSuccess continuation = continuation
abortOrContinue failure@(ExitFailure _) _ = pure failure

normalizeConfirmation :: String -> String
normalizeConfirmation value = reverse (dropWhile (== ' ') (reverse value))

refuse :: Text -> IO ExitCode
refuse detail = do
  writeError (fatalError detail)
  pure (ExitFailure 1)
