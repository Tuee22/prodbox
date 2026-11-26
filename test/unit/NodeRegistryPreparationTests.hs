{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module NodeRegistryPreparationTests (nodeRegistryPreparationSuite) where

import Codec.Archive.Tar qualified as Tar
import Codec.Archive.Tar.Entry qualified as TarEntry
import Codec.Serialise (Serialise, serialise)
import Control.Concurrent (newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Concurrent.Async (poll, wait, withAsync)
import Control.Exception (bracket)
import Crypto.Hash (Digest, SHA256, hash)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.Either (isLeft)
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Word (Word32, Word64, Word8)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Generics (Generic)
import Prodbox.Config.BootstrapProjection
  ( BootstrapDraft (..)
  , BootstrapProjection
  , bootstrapKindPlan
  , bootstrapScope
  , decodeOptionalBootstrapSource
  , readBootstrapProjection
  , renderBootstrapDraft
  , renderBootstrapProjection
  )
import Prodbox.Config.DeploymentScope
  ( DeploymentEnvironment (Test)
  , FreshScopeResult (FreshScopePrepared)
  , deploymentScope
  , prepareFreshScope
  , scopeKindName
  , scopeRoot
  )
import Prodbox.Config.KindPlan (KindNodeCreateInput (..), kindNodeRunArguments)
import Prodbox.Control.AuthorityDeploy (deployAuthority)
import Prodbox.Control.AuthorityJournalClient (admitKindTeardown)
import Prodbox.Control.Delete
  ( DeleteStep (..)
  , controlContainerId
  , controlContainerMatches
  , deleteNewTestIdentity
  , networkRemovalRecorded
  , nodeNeverStarted
  , nodeRemovalRecorded
  , priorNetworkRemovalRecorded
  , priorVolumeRemovalRecorded
  , probeCleanupPermitsNodeRemoval
  , probeCleanupRecorded
  , probeRecoveryReceiptMatches
  , volumeRemovalRecorded
  )
import Prodbox.Control.DockerConnectedInfo
  ( DockerAbsenceControlObservation (..)
  , DockerConnectedInfoResult (DockerConnectedInfoCompleted)
  , DockerImageLoadResult (..)
  , DockerImageLoadStream (..)
  , DockerImageReadback (..)
  , DockerImageSubmissionObservation (..)
  , DockerImageVolumes (..)
  , DockerNetworkRemoveResult (..)
  , DockerNodeConfigReadback (..)
  , DockerNodeContainerCreateResult
    ( DockerNodeContainerCreateReply
    , DockerNodeContainerCreateUnconfirmed
    )
  , DockerNodeContainerObservation (..)
  , DockerNodeContainerRemoveResult (..)
  , DockerNodeContainerStartResult (DockerNodeContainerStartReply)
  , DockerNodeVarRemoveResult (..)
  , absenceControlCreateBody
  , parseDockerAbsenceControl
  , parseDockerImageVolumes
  , parseDockerKindNodeCaArchive
  )
import Prodbox.Control.DockerIdentity
  ( DockerDaemonObservation (DockerDaemonObserved)
  , DockerSocketIdentity (DockerSocketIdentity)
  )
import Prodbox.Control.DockerPeer (DockerPeerResult (DockerPeerCompleted))
import Prodbox.Control.ImageIdObservation (ImageIdObservation (..))
import Prodbox.Control.KindAbsenceNodeReadback
  ( AbsenceNodeReadback (..)
  , classifyAbsenceNodeReadback
  , parseAbsenceNodeSample
  )
import Prodbox.Control.KindAbsenceRemoval (AbsenceRemovalOutcome (..), removeRecordedAbsenceControl)
import Prodbox.Control.KindAbsenceSample (AbsenceSampleOutcome (..), recordObservedAbsenceSample)
import Prodbox.Control.KindAbsenceVolumeReadback
  ( AbsenceVolumePhase (..)
  , AbsenceVolumeReadback (..)
  , AbsenceVolumeSample (..)
  , classifyAbsenceVolumeReadback
  , parseAbsenceVolumeSample
  )
import Prodbox.Control.KindController
  ( afterControllerSettlement
  , classifyControllerUnitAbsence
  , observeControllerUnderLease
  , validControllerResultPath
  , waitForUnitAbsenceWith
  )
import Prodbox.Control.KindControllerReceipt
  ( ControllerDomainObservation (..)
  , ControllerDomainWrite (..)
  , ControllerFreshProvider (..)
  , ControllerFreshSender (..)
  , ControllerJobObservation (..)
  , ControllerJobWrite (..)
  , ControllerManagerRead (..)
  , ControllerProviderMaterialWrite (..)
  , ControllerProviderWrite (..)
  , ControllerReceiptObservation (..)
  , ControllerReceiptWrite (..)
  , ControllerSenderWrite (..)
  , ControllerSubmissionObservation (..)
  , ControllerSubmissionWrite (..)
  , FamilyInputClosing (..)
  , FamilyLaunchObservation (..)
  , FamilyLaunchWrite (..)
  , FamilyParentClosing (..)
  , FamilyPostClosing (..)
  , FamilyPostDisposition (..)
  , FamilyPrimary (..)
  , FamilyResult (..)
  , FamilyResultObservation (..)
  , FamilyResultWrite (..)
  , FamilyWorkerClosing (..)
  , RetainedControllerDomain (..)
  , RetainedControllerJob (..)
  , RetainedControllerProvider (..)
  , RetainedControllerProviderMaterial (..)
  , RetainedControllerSender (..)
  , RetainedControllerSubmission (..)
  , compareControllerProviderBinding
  , controllerReceiptNode
  , decodeProviderBinding
  , hostBusUniqueName
  , hostExecutionWindow
  , hostManagerDomain
  , matchesRetainedFamilyRequest
  , observeControllerDomain
  , observeControllerFreshProvider
  , observeControllerFreshSender
  , observeControllerJob
  , observeControllerManagerRead
  , observeControllerProviderMaterial
  , observeControllerReceipt
  , observeControllerSubmissionIntent
  , observeControllerSubmissionStatus
  , observeFamilyLaunch
  , observeFamilyPublicationAttempt
  , observeFamilyResult
  , observeRetainedControllerDomain
  , observeRetainedControllerJob
  , observeRetainedControllerProvider
  , observeRetainedControllerSender
  , observeRetainedControllerSubmission
  , recordControllerDomain
  , recordControllerJob
  , recordControllerProvider
  , recordControllerProviderMaterial
  , recordControllerReceipt
  , recordControllerSender
  , recordControllerSubmissionIntent
  , recordFamilyLaunch
  , recordFamilyPublicationAttempt
  , recordFamilyResult
  , recordFamilyResultUntil
  , withControllerSubmissionIntent
  )
import Prodbox.Control.KindControllerRequest
  ( KindControllerRequestError (..)
  , decodeKindControllerRequest
  , decodeProbeAttemptVerifierRequest
  , decodeProbeRecoveryRequest
  , decodeRetainedKindControllerRequest
  , encodeKindControllerRequest
  , encodeProbeAttemptVerifierRequest
  , encodeProbeRecoveryRequest
  , kindControllerOperationKey
  , kindProbeRecoveryKey
  , mkKindControllerRequest
  , mkProbeAttemptVerifierRequest
  , mkProbeRecoveryRequest
  )
import Prodbox.Control.KindDockerEndpoint
  ( KindDockerBrokerExit (..)
  , KindDockerEndpointResult (..)
  , KindDockerWorkerExit (..)
  )
import Prodbox.Control.KindIntent
  ( KindIntentObservation (..)
  , KindIntentResult (KindIntentAlreadyExists, KindIntentRecorded)
  , observeKindExternalFamilyIntent
  , observeKindFamilyIntent
  , observeKindIntent
  , observeKindOwnerFamilyIntent
  , observeKindTeardownAdmission
  , recordKindFamilyIntent
  , recordKindIntent
  )
import Prodbox.Control.KindLease
  ( KindLeaseError (KindLeaseDeadlineExpired)
  , KindLeaseHandoff (..)
  , KindOperationOutcome (KindOperationCallbackReturned, KindOperationRefused)
  , KindOperationRefusal (KindOperationLeaseRefused)
  , awaitKindLeaseHandoff
  , withNewKindFamilyOperation
  , withNewKindOwnerFamilyOperation
  , withRecoveredKindOperation
  )
import Prodbox.Control.KindNetworkProbeRecord
  ( ProbeCreatedObservation (..)
  , ProbePublicationObservation (..)
  , ProbeRecord (..)
  , ProbeRecordObservation (..)
  , ProbeRecordWrite (..)
  , ProbeRecoveryLaunchObservation (..)
  , ProbeRemovalAttemptObservation (..)
  , observeProbeCreated
  , observeProbePublicationAttempt
  , observeProbeRecord
  , observeProbeRecoveryLaunch
  , recordProbeRecord
  )
import Prodbox.Control.KindNetworkReceipt
  ( NetworkReceiptObservation (..)
  , NetworkReceiptWrite (..)
  , NetworkTransport (NetworkRemovalTransport)
  )
import Prodbox.Control.KindNetworkRecovery
  ( KindNetworkRecordedTransport (..)
  , KindNetworkRemovalAction (KindNetworkRemovalReturned)
  )
import Prodbox.Control.KindNodeCreateIntent
  ( KindAbsenceControlResultObservation (..)
  , KindAbsenceFootprintObservation (..)
  , KindAbsenceIdObservation (..)
  , KindAbsenceObservation (..)
  , KindAbsencePlanRecovery (..)
  , KindAbsenceStage (..)
  , KindAbsenceVolumeResultObservation (..)
  , KindAbsenceWrite (..)
  , KindNodeCreateAttemptObservation (..)
  , KindNodeCreateAttemptWrite (NodeCreateAttemptRecorded)
  , KindNodeCreateIntentWrite (NodeCreateIntentRecorded)
  , KindNodeCreateRecoveryObservation (..)
  , KindNodeCreateResultObservation (..)
  , KindNodeCreateResultWrite (NodeCreateResultRecorded)
  , KindNodeRemoveAttemptObservation (..)
  , KindNodeRemoveControlObservation (..)
  , KindNodeRemoveResultWrite (..)
  , KindNodeStartAttemptObservation (..)
  , KindNodeStartResultObservation (..)
  , KindNodeStartResultWrite (NodeStartResultRecorded)
  , mkKindAbsencePlan
  , mkKindNodeCreateIntent
  , observeKindAbsenceStage
  , recordKindAbsenceStage
  , recordKindNodeCreateAttempt
  , recordKindNodeCreateIntent
  , recordKindNodeCreateResult
  , recoverKindAbsenceControlId
  , recoverKindAbsenceControlResult
  , recoverKindAbsenceFootprint
  , recoverKindAbsencePlan
  , recoverKindAbsenceVolumeResult
  )
import Prodbox.Control.KindNodeCreateOperation
  ( KindNodeCreateAction (NodeCreateActionReturned)
  , KindNodeRemoveAction (NodeRemoveActionReturned)
  , KindNodeRunAction (NodeRunStartObserved)
  , KindNodeStartAction (NodeStartActionReturned)
  )
import Prodbox.Control.KindNodeRemovalReadback
  ( NodeRemovalInventory (..)
  , NodeRemovalReadback (..)
  , confirmRecordedRemovalReadback
  )
import Prodbox.Control.KindNodeVolumeIntent
  ( KindNodeVolumeRemovalReceiptObservation (..)
  , KindNodeVolumeRemovalReceiptWrite (..)
  )
import Prodbox.Control.KindNodeVolumeOperation
  ( KindNodeVolumeRemovalAction (NodeVolumeRemovalActionReturned)
  )
import Prodbox.Control.KindNodeVolumeReadback (NodeVolumeInventory (..))
import Prodbox.Control.KindTool
  ( ArchiveBoundConfinedKindNode (ConfinedNodeConnected)
  , ConfinedKindNodeAttempt (ConfinedNodeObserved)
  , ConfinedKindSnapshotsAttempt (ConfinedSnapshotsReady)
  , ConfinedKindSnapshotsObservation (ConfinedKindSnapshotsAttempted)
  , ConnectedConfinedKindNode (ConfinedNodeBindingObserved)
  , KindDockerMarkerObservation (..)
  , confirmedKindWorkerNode
  )
import Prodbox.Control.KubernetesReadiness (ReadinessObservation (..))
import Prodbox.Control.NetworkEnforcement
  ( EnforcementCleanup (..)
  , EnforcementObservation (..)
  , EnforcementOutcome (..)
  , ProbeAttemptReadbackOutcome (..)
  , ProbeJournalObservation (..)
  , ProbePublicationState (..)
  , ProbeRecoveryOutcome (..)
  , classifyProbePublication
  , confirmAttemptedProbeAbsenceWith
  , enforcementComplete
  , observeNetworkEnforcementRecorded
  , observeNetworkEnforcementWith
  , observeProbeJournal
  , recoverRecordedProbeWith
  )
import Prodbox.Control.NodeArchive (InspectedArchiveResult (..))
import Prodbox.Control.NodeImageIntent (NodeImageResultWrite (..))
import Prodbox.Control.NodeImageOperation (NodeImageRecordedSubmission (..))
import Prodbox.Control.NodeRegistryArchive
  ( NodeRegistryArchiveResult (..)
  , writeNodeRegistryArchive
  )
import Prodbox.Control.NodeRegistryClient (NodeRegistryDocument (..), NodeRegistryReadError (..))
import Prodbox.Control.NodeRegistryManifest (NodeRegistryBlob (..), NodeRegistryPlan (..))
import Prodbox.Control.Reconcile
  ( ReconcileOutcome (..)
  , imageSubmissionAccepted
  , prepareNewOwnerFamilyOperation
  , reconcileFamilyPrerequisites
  )
import Prodbox.Control.Recreate
  ( ArchiveIntentDecision (..)
  , ArchiveOutcome (..)
  , archiveCompletedOperation
  , classifyArchiveIntent
  , probeArchiveRecord
  )
import Prodbox.Control.ServiceSupport (ServiceStep (..))
import Prodbox.Control.Status (NodeCreateStatus (NodeCreateStatus), matchesNodeCreateStatus)
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessWithInputBounded
  )
import Prodbox.Test.FixtureTree (captureFixtureTree, cleanupFixtureTree, cleanupFixtureTrees)
import Prodbox.Test.NodeRegistryPreparation
  ( PreparationFailure (..)
  , PreparationResult (..)
  , RegistrySource (..)
  , prepareAdverseImportSources
  , prepareFreshNodeArchiveWith
  , preparePinnedKindArtifact
  , prepareRegistryNodeArchiveWith
  )
import Prodbox.Test.Phase01Runner
  ( FreshImageInventory (..)
  , ImportAdverseEvidence (..)
  , dockerArguments
  , fixtureBaseMatches
  , fixtureNetworkId
  , fixtureNetworkUntouched
  , observeBareRetainedScope
  , observeFreshImageInventory
  , runFreshImportAdversesWith
  , validateBootIdentity
  , validateScenarioEntropy
  )
import System.Directory
  ( createDirectory
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , listDirectory
  , makeAbsolute
  , removeDirectory
  , removeFile
  , renameFile
  )
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO (IOMode (ReadMode, WriteMode), withBinaryFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (createSymbolicLink, setFileMode)
import System.Posix.IO qualified as Posix
import TestSupport
  ( SuiteBuilder
  , assertMutationInvariant
  , describe
  , it
  , shouldBe
  , shouldNotBe
  , shouldReturn
  , shouldSatisfy
  )

-- Matches the public serialization shape, with synthetic non-secret values.
data FixtureProviderWire
  = FixtureProviderWire !Word8 !BS.ByteString !Word32 !Word64 !Word32 !Word64 !Word64
  deriving (Generic, Serialise)

nodeRegistryPreparationSuite :: SuiteBuilder ()
nodeRegistryPreparationSuite = describe "test node artifact preparation" $ do
  it "compares only the exact bounded node CA archive" $ do
    path <- either (fail . show) pure (TarEntry.toTarPath False "ca.crt")
    wrongPath <- either (fail . show) pure (TarEntry.toTarPath False "other.crt")
    let entry name bytes = TarEntry.fileEntry name (BL.fromStrict bytes)
        archive entries = BL.toStrict (Tar.write entries)
        ca = "test certificate bytes"
    parseDockerKindNodeCaArchive ca (archive [entry path ca]) `shouldBe` Just DockerNodeConfigMatches
    parseDockerKindNodeCaArchive ca (archive [entry path "different"])
      `shouldBe` Just DockerNodeConfigDiffers
    parseDockerKindNodeCaArchive ca (archive [entry wrongPath ca]) `shouldBe` Nothing
    parseDockerKindNodeCaArchive ca (archive [entry path ca, entry wrongPath ca]) `shouldBe` Nothing
    parseDockerKindNodeCaArchive ca (archive [entry path (BS.replicate 65537 65)]) `shouldBe` Nothing
  it "refuses an uncertain image submission even when the image is present" $ do
    let present = DockerImageReadbackStable (Right (ImageIdObserved "linux" "amd64" 0))
        accepted = DockerImageLoadReply 200 (DockerImageLoadMessages 1)
        submission transport readback record =
          NodeImageRecordedSubmission (DockerImageSubmissionObservation transport readback) record
    imageSubmissionAccepted (submission accepted present NodeImageResultRecorded) `shouldBe` True
    imageSubmissionAccepted (submission DockerImageLoadUnconfirmed present NodeImageResultRecorded)
      `shouldBe` False
    imageSubmissionAccepted
      (submission (DockerImageLoadReply 200 DockerImageLoadErrorMessage) present NodeImageResultRecorded)
      `shouldBe` False
    imageSubmissionAccepted (submission accepted present NodeImageResultIncomplete) `shouldBe` False
    imageSubmissionAccepted (submission accepted DockerImageReadbackSkipped NodeImageResultRecorded)
      `shouldBe` False
  it "renders a bootstrap-only controller snapshot without unrelated selected fields" $
    withFixture $ \_ projection _ _ _ -> do
      snapshot <-
        maybe
          (fail "complete bootstrap projection was not rendered")
          pure
          (renderBootstrapProjection projection)
      let secretMarker = "fixture-secret-must-not-be-published"
          selected = Text.replace "\n}\n" ("\n, unrelated_secret = \"" <> secretMarker <> "\"\n}\n") snapshot
      selectedProjection <- decodeOptionalBootstrapSource "selected.dhall" selected
      selectedProjection `shouldBe` Right (Just projection)
      snapshot `shouldSatisfy` (not . Text.isInfixOf secretMarker)
      decodeOptionalBootstrapSource "controller.dhall" snapshot `shouldReturn` Right (Just projection)
  it "requires a separate visible control for node absence inventory" $ do
    let target = replicate 64 'a'
        control = replicate 64 'b'
        daemon = DockerDaemonObserved "daemon-a" (DockerSocketIdentity 1 2 1000 0o140660)
        foreignDaemon = DockerDaemonObserved "daemon-b" (DockerSocketIdentity 1 2 1000 0o140660)
        sample = parseAbsenceNodeSample target control (control ++ "\n") "" "" (control ++ "\n") (control ++ "\n")
        blind = parseAbsenceNodeSample target control (control ++ "\n") "" "" "" ""
        present =
          parseAbsenceNodeSample
            target
            control
            (unlines [target, control])
            (target ++ "\n")
            (target ++ "\n")
            (control ++ "\n")
            (control ++ "\n")
        decide = classifyAbsenceNodeReadback control daemon daemon True
    sample `shouldSatisfy` (/= Nothing)
    fmap (decide sample . Just) sample `shouldBe` (AbsenceNodeSampled <$> sample)
    decide blind blind `shouldBe` AbsenceNodeUnobservable
    decide present present `shouldBe` AbsenceNodeUnobservable
    decide sample present `shouldBe` AbsenceNodeChanged
    classifyAbsenceNodeReadback control daemon foreignDaemon True sample sample
      `shouldBe` AbsenceNodeChanged
    classifyAbsenceNodeReadback control daemon daemon False sample sample
      `shouldBe` AbsenceNodeUnobservable
    parseAbsenceNodeSample target target (target ++ "\n") "" "" (target ++ "\n") (target ++ "\n")
      `shouldBe` Nothing
  it "requires visible control volumes before removal and a retained positive volume afterward" $ do
    let positive = "prodbox-t-fixture-node-volume"
        volume = replicate 64 'f'
        control = replicate 64 'e'
        daemon = DockerDaemonObserved "daemon-a" (DockerSocketIdentity 1 2 1000 0o140660)
        foreignDaemon = DockerDaemonObserved "daemon-b" (DockerSocketIdentity 1 2 1000 0o140660)
        before =
          parseAbsenceVolumeSample positive [volume] (unlines [positive, volume]) [(volume, control ++ "\n")]
        after = parseAbsenceVolumeSample positive [volume] (positive ++ "\n") [(volume, "")]
        blind = parseAbsenceVolumeSample positive [volume] (unlines [positive, volume]) [(volume, "")]
        missingPositive = parseAbsenceVolumeSample positive [volume] (volume ++ "\n") [(volume, control ++ "\n")]
        expectedBefore = AbsenceVolumeSample True [(volume, NodeVolumeInventory True [control])]
        expectedAfter = AbsenceVolumeSample True [(volume, NodeVolumeInventory False [])]
    before `shouldBe` Just expectedBefore
    after `shouldBe` Just expectedAfter
    classifyAbsenceVolumeReadback
      AbsenceVolumesBeforeRemoval
      control
      [volume]
      daemon
      daemon
      True
      before
      before
      `shouldBe` AbsenceVolumeSampled expectedBefore
    classifyAbsenceVolumeReadback
      AbsenceVolumesAfterRemoval
      control
      [volume]
      daemon
      daemon
      True
      after
      after
      `shouldBe` AbsenceVolumeSampled expectedAfter
    classifyAbsenceVolumeReadback
      AbsenceVolumesBeforeRemoval
      control
      [volume]
      daemon
      daemon
      True
      blind
      blind
      `shouldBe` AbsenceVolumeUnobservable
    classifyAbsenceVolumeReadback
      AbsenceVolumesAfterRemoval
      control
      [volume]
      daemon
      daemon
      True
      blind
      blind
      `shouldBe` AbsenceVolumeResidual [volume]
    classifyAbsenceVolumeReadback
      AbsenceVolumesBeforeRemoval
      control
      [volume]
      daemon
      daemon
      True
      missingPositive
      missingPositive
      `shouldBe` AbsenceVolumeUnobservable
    classifyAbsenceVolumeReadback
      AbsenceVolumesAfterRemoval
      control
      [volume]
      daemon
      daemon
      True
      before
      before
      `shouldBe` AbsenceVolumeUnobservable
    classifyAbsenceVolumeReadback
      AbsenceVolumesBeforeRemoval
      control
      [volume]
      daemon
      foreignDaemon
      True
      before
      before
      `shouldBe` AbsenceVolumeChanged
    classifyAbsenceVolumeReadback
      AbsenceVolumesBeforeRemoval
      control
      [volume]
      daemon
      daemon
      True
      before
      after
      `shouldBe` AbsenceVolumeChanged
    parseAbsenceVolumeSample
      positive
      [volume, volume]
      (unlines [positive, volume])
      [(volume, control), (volume, control)]
      `shouldBe` Nothing
  it "does not record an absence sample when control inspection is unavailable" $
    withFixture $ \parent _ _ _ _ -> do
      projection <-
        readBootstrapProjection (takeDirectory parent </> "isolated-status.dhall")
          >>= either (fail . show) pure
      let operation = replicate 32 'd'
          target = replicate 64 'a'
          control = replicate 64 'e'
          volumes = [("/var", replicate 64 'f')]
          image = "sha256:" ++ replicate 64 'c'
          tool = "sha256:50030de23cf40a18505f20426f6a8506bedf13c6e509244bd1fa9463721b0f54"
          input =
            KindNodeCreateInput
              tool
              image
              (replicate 64 'b')
              (replicate 32 'b')
              operation
              (kindNodeRunArguments (bootstrapKindPlan projection) image)
          daemon = DockerDaemonObserved "daemon-a" (DockerSocketIdentity 1 2 1000 0o140660)
      intent <- maybe (fail "node intent fixture") pure (mkKindNodeCreateIntent projection input daemon)
      plan <-
        maybe
          (fail "absence plan fixture")
          pure
          (mkKindAbsencePlan intent target (DockerImageVolumes ["/var"]))
      recordKindIntent projection operation >>= (`shouldBe` KindIntentRecorded)
      prepared <- withRecoveredKindOperation projection operation $ \stable -> do
        recordKindNodeCreateIntent projection intent stable >>= (`shouldBe` NodeCreateIntentRecorded)
        recordKindNodeCreateAttempt projection intent stable >>= (`shouldBe` NodeCreateAttemptRecorded)
        recordKindNodeCreateResult
          projection
          intent
          (DockerNodeContainerCreateReply 201 (Just target))
          stable
          >>= (`shouldBe` NodeCreateResultRecorded)
        recordKindAbsenceStage projection plan AbsenceCreateAttempt stable >>= (`shouldBe` AbsenceRecorded)
        recordKindAbsenceStage
          projection
          plan
          (AbsenceCreateResult DockerNodeContainerCreateUnconfirmed)
          stable
          >>= (`shouldBe` AbsenceRecorded)
        recordKindAbsenceStage projection plan (AbsenceControlIdentified control) stable
          >>= (`shouldBe` AbsenceRecorded)
        recordKindAbsenceStage projection plan (AbsenceFootprintRecorded control volumes) stable
          >>= (`shouldBe` AbsenceRecorded)
      prepared `shouldBe` KindOperationCallbackReturned ()
      recordObservedAbsenceSample projection plan (const (pure False))
        `shouldReturn` KindOperationCallbackReturned AbsenceSampleRecordsUnconfirmed
      recordObservedAbsenceSample projection plan id
        `shouldReturn` KindOperationCallbackReturned AbsenceSampleControlUnconfirmed
      removeRecordedAbsenceControl projection plan id
        `shouldReturn` KindOperationCallbackReturned (Left AbsenceRemovalCreateUnconfirmed)
      withRecoveredKindOperation
        projection
        operation
        (observeKindAbsenceStage projection plan (AbsenceControlSampled control volumes))
        `shouldReturn` KindOperationCallbackReturned AbsenceMissing
      withRecoveredKindOperation
        projection
        operation
        (observeKindAbsenceStage projection plan (AbsenceRemoveAttempt control volumes))
        `shouldReturn` KindOperationCallbackReturned AbsenceMissing
  it "binds a never-started absence control and exact anonymous volume footprint" $
    withFixture $ \_ projection _ _ _ -> do
      let operation = replicate 32 'd'
          target = replicate 64 'a'
          control = replicate 64 'e'
          image = "sha256:" ++ replicate 64 'c'
          volume = replicate 64 'f'
          scope = bootstrapScope projection
          name = "/" ++ scopeKindName scope ++ "-absence-control"
          labels generation =
            Aeson.object
              [ "io.prodbox.absence-control" .= operation
              , "io.prodbox.generation" .= (generation :: String)
              ]
          mount destination volumeId kind =
            Aeson.object
              [ "Type" .= (kind :: String)
              , "Name" .= (volumeId :: String)
              , "Destination" .= (destination :: String)
              , "Driver" .= ("local" :: String)
              , "RW" .= True
              ]
          document identifier selectedName selectedImage generation state networkMode mounts =
            Aeson.object
              [ "Id" .= (identifier :: String)
              , "Name" .= (selectedName :: String)
              , "Image" .= (selectedImage :: String)
              , "Config"
                  .= Aeson.object
                    [ "Image" .= selectedImage
                    , "Labels" .= labels generation
                    , "Entrypoint" .= (["/nonexistent"] :: [String])
                    , "Cmd" .= (["/nonexistent"] :: [String])
                    , "NetworkDisabled" .= True
                    ]
              , "State"
                  .= Aeson.object
                    [ "Running" .= (state :: Bool)
                    , "Paused" .= False
                    , "Restarting" .= False
                    , "Dead" .= False
                    , "Status" .= ("created" :: String)
                    ]
              , "HostConfig"
                  .= Aeson.object
                    [ "NetworkMode" .= (networkMode :: String)
                    , "Privileged" .= False
                    , "Binds" .= Aeson.Null
                    , "ReadonlyRootfs" .= True
                    , "AutoRemove" .= False
                    , "CapDrop" .= (["ALL"] :: [String])
                    , "RestartPolicy" .= Aeson.object ["Name" .= ("no" :: String), "MaximumRetryCount" .= (0 :: Int)]
                    ]
              , "Mounts" .= (mounts :: [Aeson.Value])
              , "NetworkSettings" .= Aeson.object ["Networks" .= Aeson.object []]
              ]
          good = document control name image (replicate 32 'b') False "none" [mount "/var" volume "volume"]
          observe =
            parseDockerAbsenceControl
              projection
              operation
              target
              image
              (DockerImageVolumes ["/var"])
              (Just control)
      observe good `shouldBe` Right (DockerAbsenceControlMatching control [("/var", volume)])
      observe (document control name image (replicate 32 'e') False "none" [mount "/var" volume "volume"])
        `shouldBe` Right DockerAbsenceControlConflict
      observe (document control name image (replicate 32 'b') True "none" [mount "/var" volume "volume"])
        `shouldBe` Right DockerAbsenceControlConflict
      observe
        (document control name image (replicate 32 'b') False "bridge" [mount "/var" volume "volume"])
        `shouldBe` Right DockerAbsenceControlConflict
      observe (document control name image (replicate 32 'b') False "none" [])
        `shouldBe` Right DockerAbsenceControlConflict
      observe (document control name image (replicate 32 'b') False "none" [mount "/var" volume "bind"])
        `shouldSatisfy` isLeft
      observe (document target name image (replicate 32 'b') False "none" [mount "/var" volume "volume"])
        `shouldBe` Right DockerAbsenceControlConflict
      parseDockerAbsenceControl
        projection
        operation
        target
        image
        (DockerImageVolumes ["/var"])
        Nothing
        good
        `shouldBe` Right (DockerAbsenceControlMatching control [("/var", volume)])
      case absenceControlCreateBody projection operation target image (DockerImageVolumes ["/var"]) of
        Just (Aeson.Object body) -> do
          KeyMap.lookup "Image" body `shouldBe` Just (Aeson.String (Text.pack image))
          KeyMap.lookup "NetworkDisabled" body `shouldBe` Just (Aeson.Bool True)
          KeyMap.lookup "Volumes" body `shouldBe` Nothing
          case KeyMap.lookup "HostConfig" body of
            Just (Aeson.Object host) -> do
              KeyMap.lookup "NetworkMode" host `shouldBe` Just (Aeson.String "none")
              KeyMap.lookup "ReadonlyRootfs" host `shouldBe` Just (Aeson.Bool True)
              KeyMap.lookup "AutoRemove" host `shouldBe` Just (Aeson.Bool False)
            _ -> fail "control host configuration missing"
        _ -> fail "valid control body refused"
      absenceControlCreateBody projection operation "not-a-node-id" image (DockerImageVolumes ["/var"])
        `shouldBe` Nothing
  it "binds residual volume removal to the sampled exact footprint" $
    withFixture $ \_ projection _ _ _ -> do
      let operation = replicate 32 'd'
          target = replicate 64 'a'
          control = replicate 64 'e'
          volume = replicate 64 'f'
          volumes = [("/var", volume)]
          image = "sha256:" ++ replicate 64 'c'
          tool = "sha256:50030de23cf40a18505f20426f6a8506bedf13c6e509244bd1fa9463721b0f54"
          input =
            KindNodeCreateInput
              tool
              image
              (replicate 64 'b')
              (replicate 32 'b')
              operation
              (kindNodeRunArguments (bootstrapKindPlan projection) image)
          daemon = DockerDaemonObserved "daemon-a" (DockerSocketIdentity 1 2 1000 0o140660)
      intent <- maybe (fail "node intent fixture") pure (mkKindNodeCreateIntent projection input daemon)
      plan <-
        maybe
          (fail "absence plan fixture")
          pure
          (mkKindAbsencePlan intent target (DockerImageVolumes ["/var"]))
      recordKindIntent projection operation >>= (`shouldBe` KindIntentRecorded)
      outcome <- withRecoveredKindOperation projection operation $ \stable -> do
        recordKindNodeCreateIntent projection intent stable >>= (`shouldBe` NodeCreateIntentRecorded)
        recordKindNodeCreateAttempt projection intent stable >>= (`shouldBe` NodeCreateAttemptRecorded)
        recordKindNodeCreateResult
          projection
          intent
          (DockerNodeContainerCreateReply 201 (Just target))
          stable
          >>= (`shouldBe` NodeCreateResultRecorded)
        recordKindAbsenceStage projection plan AbsenceCreateAttempt stable >>= (`shouldBe` AbsenceRecorded)
        recordKindAbsenceStage
          projection
          plan
          (AbsenceCreateResult (DockerNodeContainerCreateReply 201 (Just control)))
          stable
          >>= (`shouldBe` AbsenceRecorded)
        recordKindAbsenceStage projection plan (AbsenceControlIdentified control) stable
          >>= (`shouldBe` AbsenceRecorded)
        recordKindAbsenceStage projection plan (AbsenceFootprintRecorded control volumes) stable
          >>= (`shouldBe` AbsenceRecorded)
        recordKindAbsenceStage projection plan (AbsenceControlSampled control volumes) stable
          >>= (`shouldBe` AbsenceRecorded)
        recordKindAbsenceStage projection plan (AbsenceRemoveAttempt control volumes) stable
          >>= (`shouldBe` AbsenceRecorded)
        recoverKindAbsenceVolumeResult projection plan control volumes volume stable
          >>= (`shouldBe` AbsenceVolumeAttemptMissing)
        recordKindAbsenceStage
          projection
          plan
          (AbsenceVolumeRemoveAttempt control volumes (replicate 64 '9'))
          stable
          >>= (`shouldBe` AbsenceRefused)
        recordKindAbsenceStage projection plan (AbsenceVolumeRemoveAttempt control volumes volume) stable
          >>= (`shouldBe` AbsenceRecorded)
        recoverKindAbsenceVolumeResult projection plan control volumes volume stable
          >>= (`shouldBe` AbsenceVolumeResultMissing)
        recordKindAbsenceStage projection plan (AbsenceVolumeRemoveAttempt control volumes volume) stable
          >>= (`shouldBe` AbsenceAlreadyExists)
        recordKindAbsenceStage
          projection
          plan
          (AbsenceVolumeRemoveResult control volumes volume DockerNodeVarRemoveUnconfirmed)
          stable
          >>= (`shouldBe` AbsenceRecorded)
        observeKindAbsenceStage
          projection
          plan
          (AbsenceVolumeRemoveResult control volumes volume DockerNodeVarRemoveUnconfirmed)
          stable
          >>= (`shouldBe` AbsenceMatches)
        recoverKindAbsenceVolumeResult projection plan control volumes volume stable
          >>= (`shouldBe` AbsenceVolumeResultObserved DockerNodeVarRemoveUnconfirmed)
        observeKindAbsenceStage
          projection
          plan
          (AbsenceVolumeRemoveResult control volumes volume (DockerNodeVarRemoveReply 204))
          stable
          >>= (`shouldBe` AbsenceConflict)
        BS.writeFile
          ( scopeRoot (bootstrapScope projection)
              </> ("kind-node-absence-control-volume-" ++ volume ++ "-result.json")
          )
          "{}"
        recoverKindAbsenceVolumeResult projection plan control volumes volume stable
          >>= (`shouldBe` AbsenceVolumeResultUnconfirmed)
      outcome `shouldBe` KindOperationCallbackReturned ()
  it "journals the exact absence-control attempt and recovers its identity in order" $
    withFixture $ \parent projection _ _ _ -> do
      let operation = replicate 32 'd'
          target = replicate 64 'a'
          control = replicate 64 'e'
          volumes = [("/var", replicate 64 'f')]
          image = "sha256:" ++ replicate 64 'c'
          tool = "sha256:50030de23cf40a18505f20426f6a8506bedf13c6e509244bd1fa9463721b0f54"
          input =
            KindNodeCreateInput
              tool
              image
              (replicate 64 'b')
              (replicate 32 'b')
              operation
              (kindNodeRunArguments (bootstrapKindPlan projection) image)
          daemon = DockerDaemonObserved "daemon-a" (DockerSocketIdentity 1 2 1000 0o140660)
          attemptPath =
            takeDirectory parent
              </> ".test-data"
              </> "fixture"
              </> "kind-node-absence-control-create-attempt.json"
      intent <- maybe (fail "node intent fixture") pure (mkKindNodeCreateIntent projection input daemon)
      plan <-
        maybe
          (fail "absence plan fixture")
          pure
          (mkKindAbsencePlan intent target (DockerImageVolumes ["/var"]))
      otherPlan <-
        maybe
          (fail "other absence plan fixture")
          pure
          (mkKindAbsencePlan intent target (DockerImageVolumes []))
      mkKindAbsencePlan intent target (DockerImageVolumes ["/var/", "/var"]) `shouldBe` Nothing
      recordKindIntent projection operation >>= (`shouldBe` KindIntentRecorded)
      outcome <- withRecoveredKindOperation projection operation $ \stable -> do
        recordKindNodeCreateIntent projection intent stable >>= (`shouldBe` NodeCreateIntentRecorded)
        recordKindNodeCreateAttempt projection intent stable >>= (`shouldBe` NodeCreateAttemptRecorded)
        recordKindNodeCreateResult
          projection
          intent
          (DockerNodeContainerCreateReply 201 (Just target))
          stable
          >>= (`shouldBe` NodeCreateResultRecorded)
        recordKindAbsenceStage projection plan (AbsenceControlIdentified control) stable
          >>= (`shouldBe` AbsenceRefused)
        recoverKindAbsencePlan projection operation stable >>= (`shouldBe` AbsencePlanMissing)
        observeKindAbsenceStage projection plan AbsenceCreateAttempt stable >>= (`shouldBe` AbsenceMissing)
        recordKindAbsenceStage projection plan AbsenceCreateAttempt stable >>= (`shouldBe` AbsenceRecorded)
        recoverKindAbsencePlan projection operation stable >>= (`shouldBe` AbsencePlanObserved plan)
        recordKindAbsenceStage projection plan AbsenceCreateAttempt stable
          >>= (`shouldBe` AbsenceAlreadyExists)
        recordKindAbsenceStage
          projection
          plan
          (AbsenceCreateResult DockerNodeContainerCreateUnconfirmed)
          stable
          >>= (`shouldBe` AbsenceRecorded)
        observeKindAbsenceStage
          projection
          plan
          (AbsenceCreateResult (DockerNodeContainerCreateReply 201 (Just control)))
          stable
          >>= (`shouldBe` AbsenceConflict)
        observeKindAbsenceStage projection otherPlan AbsenceCreateAttempt stable
          >>= (`shouldBe` AbsenceConflict)
        recordKindAbsenceStage projection plan (AbsenceControlIdentified target) stable
          >>= (`shouldBe` AbsenceRefused)
        recordKindAbsenceStage projection plan (AbsenceControlIdentified control) stable
          >>= (`shouldBe` AbsenceRecorded)
        recoverKindAbsenceControlId projection plan stable >>= (`shouldBe` AbsenceIdObserved control)
        recordKindAbsenceStage projection plan (AbsenceRemoveAttempt control volumes) stable
          >>= (`shouldBe` AbsenceRefused)
        recordKindAbsenceStage projection plan (AbsenceFootprintRecorded control []) stable
          >>= (`shouldBe` AbsenceRefused)
        recordKindAbsenceStage projection plan (AbsenceFootprintRecorded control volumes) stable
          >>= (`shouldBe` AbsenceRecorded)
        recoverKindAbsenceFootprint projection plan control stable
          >>= (`shouldBe` AbsenceFootprintObserved volumes)
        observeKindAbsenceStage projection plan (AbsenceControlSampled control volumes) stable
          >>= (`shouldBe` AbsenceMissing)
        recoverKindAbsenceControlResult projection plan control volumes stable
          >>= (`shouldBe` AbsenceControlAttemptMissing)
        recordKindAbsenceStage projection plan (AbsenceRemoveAttempt control volumes) stable
          >>= (`shouldBe` AbsenceRecorded)
        recoverKindAbsenceControlResult projection plan control volumes stable
          >>= (`shouldBe` AbsenceControlResultMissing)
        recordKindAbsenceStage
          projection
          plan
          (AbsenceVolumeRemoveAttempt control volumes (replicate 64 'f'))
          stable
          >>= (`shouldBe` AbsenceRefused)
        recordKindAbsenceStage projection plan (AbsenceControlSampled control volumes) stable
          >>= (`shouldBe` AbsenceRefused)
        recordKindAbsenceStage
          projection
          plan
          (AbsenceRemoveResult control volumes DockerNodeContainerRemoveUnconfirmed)
          stable
          >>= (`shouldBe` AbsenceRecorded)
        recoverKindAbsenceControlResult projection plan control volumes stable
          >>= (`shouldBe` AbsenceControlResultObserved DockerNodeContainerRemoveUnconfirmed)
        observeKindAbsenceStage
          projection
          plan
          (AbsenceRemoveResult control volumes (DockerNodeContainerRemoveReply 204))
          stable
          >>= (`shouldBe` AbsenceConflict)
        BS.writeFile attemptPath "{}"
        recoverKindAbsencePlan projection operation stable >>= (`shouldBe` AbsencePlanUnconfirmed)
        recoverKindAbsenceControlId projection plan stable >>= (`shouldBe` AbsenceIdUnconfirmed)
        observeKindAbsenceStage projection plan (AbsenceFootprintRecorded control volumes) stable
          >>= (`shouldBe` AbsenceUnobservable)
        recoverKindAbsenceFootprint projection plan control stable
          >>= (`shouldBe` AbsenceFootprintUnconfirmed)
      outcome `shouldBe` KindOperationCallbackReturned ()
  it "observes image-declared volumes without inferring missing configuration is empty" $ do
    let imageId = "sha256:" ++ replicate 64 'a'
        document ident volumes =
          Aeson.object
            ["Id" .= (ident :: String), "Config" .= Aeson.object ["Volumes" .= (volumes :: Aeson.Value)]]
        declared = Aeson.object ["/var" .= Aeson.object [], "/data" .= Aeson.object []]
        invalidPath = Aeson.object ["/var/../host" .= Aeson.object []]
    parseDockerImageVolumes imageId (document imageId Aeson.Null)
      `shouldBe` Right (DockerImageVolumes [])
    parseDockerImageVolumes imageId (document imageId declared)
      `shouldBe` Right (DockerImageVolumes ["/data", "/var"])
    case parseDockerImageVolumes imageId (document ("sha256:" ++ replicate 64 'b') declared) of
      Left _ -> pure ()
      Right _ -> fail "foreign image was accepted"
    case parseDockerImageVolumes imageId (Aeson.object ["Id" .= imageId, "Config" .= Aeson.object []]) of
      Left _ -> pure ()
      Right _ -> fail "missing volume observation was treated as empty"
    case parseDockerImageVolumes imageId (document imageId invalidPath) of
      Left _ -> pure ()
      Right _ -> fail "noncanonical volume path was accepted"
    case parseDockerImageVolumes imageId (document imageId (Aeson.object ["/var/" .= Aeson.object []])) of
      Left _ -> pure ()
      Right _ -> fail "aliased volume path was accepted"
  it "waits for the launcher lease and refuses an expired or changed owner" $
    withFixture $ \_ projection _ _ _ -> do
      let operation = replicate 32 'd'
      recordKindIntent projection operation >>= (`shouldBe` KindIntentRecorded)
      entered <- newEmptyMVar
      release <- newEmptyMVar
      withAsync
        (withRecoveredKindOperation projection operation $ \_ -> putMVar entered () >> takeMVar release)
        $ \owner -> do
          takeMVar entered
          now <- getMonotonicTimeNSec
          awaitKindLeaseHandoff (now + 120000000) projection operation (pure True)
            >>= (`shouldBe` KindLeaseHandoffExpired)
          awaitKindLeaseHandoff (now + 2000000000) projection operation (pure False)
            >>= (`shouldBe` KindLeaseHandoffUnstable)
          withAsync (awaitKindLeaseHandoff (now + 2000000000) projection operation (pure True)) $ \worker -> do
            threadDelay 80000
            pending <- poll worker
            case pending of Nothing -> pure (); Just _ -> fail "worker crossed a held operation lease"
            putMVar release ()
            wait owner >>= (`shouldBe` KindOperationCallbackReturned ())
            wait worker >>= (`shouldBe` KindLeaseHandoffReady)
  it "records a family result once a briefly held scope lease closes" $
    withFixture $ \_ projection _ _ _ -> do
      let operation = replicate 32 'd'
          summaryDigest = replicate 64 'c'
          summary =
            FamilyResult
              FamilyWorkerNotObserved
              FamilyWorkerNotStarted
              FamilyParentComplete
              FamilyInputComplete
              FamilyPostImageClosingUnconfirmed
              FamilyPostNotStarted
      now <- getMonotonicTimeNSec
      withNewKindOwnerFamilyOperation projection operation (const (pure ()))
        `shouldReturn` KindOperationCallbackReturned ()
      entered <- newEmptyMVar
      release <- newEmptyMVar
      withAsync
        (withRecoveredKindOperation projection operation $ \_ -> putMVar entered () >> takeMVar release)
        $ \owner -> do
          takeMVar entered
          recordFamilyResultUntil now projection operation summaryDigest summary
            `shouldReturn` KindOperationRefused (KindOperationLeaseRefused KindLeaseDeadlineExpired)
          withAsync (recordFamilyResultUntil (now + 5000000000) projection operation summaryDigest summary) $ \writer -> do
            threadDelay 80000
            pending <- poll writer
            case pending of
              Nothing -> pure ()
              Just _ -> fail "the result writer returned while a scope reader held the lease"
            putMVar release ()
            wait owner `shouldReturn` KindOperationCallbackReturned ()
            wait writer `shouldReturn` KindOperationCallbackReturned FamilyResultRecorded
      withRecoveredKindOperation projection operation (observeFamilyResult projection operation)
        `shouldReturn` KindOperationCallbackReturned (FamilyResultObserved summaryDigest summary)
  it "retains the original family launch coordinates without treating them as submission" $
    withFixture $ \parent projection _ _ _ -> do
      let operation = replicate 32 'd'
          recordPath = takeDirectory parent </> ".test-data" </> "fixture" </> "kind-family-launch-request.json"
      domain <-
        maybe
          (fail "domain invalid")
          pure
          (hostManagerDomain "11111111-1111-1111-1111-111111111111" (replicate 32 'a') ":1.42" 1000 1234 5678)
      window <- maybe (fail "window invalid") pure (hostExecutionWindow 50 10 20 30 40)
      request <-
        either
          (fail . show)
          pure
          (mkKindControllerRequest projection operation ("sha256:" ++ replicate 64 'a') domain window)
      differentRequest <-
        either
          (fail . show)
          pure
          (mkKindControllerRequest projection operation ("sha256:" ++ replicate 64 'b') domain window)
      decodeRetainedKindControllerRequest projection operation (encodeKindControllerRequest request)
        `shouldBe` Right request
      decodeRetainedKindControllerRequest
        projection
        (replicate 32 'e')
        (encodeKindControllerRequest request)
        `shouldBe` Left KindRequestBindingMismatch
      recordKindFamilyIntent projection operation >>= (`shouldBe` KindIntentRecorded)
      outcome <- withRecoveredKindOperation projection operation $ \stable -> do
        observeKindIntent projection >>= (`shouldBe` KindIntentMatches operation)
        observeKindFamilyIntent projection >>= (`shouldBe` KindIntentMatches operation)
        recordControllerSubmissionIntent projection operation (replicate 64 'a') stable
          >>= (`shouldBe` ControllerSubmissionRefused)
        observeFamilyLaunch projection operation stable >>= (`shouldBe` FamilyLaunchMissing)
        recordFamilyPublicationAttempt projection request stable `shouldReturn` FamilyLaunchRefused
        matchesRetainedFamilyRequest projection request stable `shouldReturn` False
        recordFamilyLaunch projection request stable >>= (`shouldBe` FamilyLaunchRecorded)
        observeFamilyLaunch projection operation stable >>= (`shouldBe` FamilyLaunchObserved request)
        matchesRetainedFamilyRequest projection request stable `shouldReturn` True
        matchesRetainedFamilyRequest projection differentRequest stable `shouldReturn` False
        observeFamilyPublicationAttempt projection operation stable `shouldReturn` FamilyLaunchMissing
        recordFamilyPublicationAttempt projection differentRequest stable `shouldReturn` FamilyLaunchRefused
        recordFamilyPublicationAttempt projection request stable `shouldReturn` FamilyLaunchRecorded
        observeFamilyPublicationAttempt projection operation stable
          `shouldReturn` FamilyLaunchObserved request
        recordFamilyPublicationAttempt projection request stable `shouldReturn` FamilyLaunchAlreadyExists
        matchesRetainedFamilyRequest projection request (pure False) `shouldReturn` False
        recordFamilyLaunch projection request stable >>= (`shouldBe` FamilyLaunchAlreadyExists)
        observeFamilyLaunch projection operation (pure False) >>= (`shouldBe` FamilyLaunchUnobservable)
        stored <- BS.readFile recordPath
        legacy <- case Aeson.decodeStrict' stored of
          Just (Aeson.Object fields) -> pure (Aeson.Object (KeyMap.delete "publication_protocol" fields))
          _ -> fail "family launch record was not an object"
        BL.writeFile recordPath (Aeson.encode legacy)
        observeFamilyLaunch projection operation stable >>= (`shouldBe` FamilyLaunchConflict)
        BS.writeFile recordPath "{}"
        observeFamilyLaunch projection operation stable >>= (`shouldBe` FamilyLaunchConflict)
        matchesRetainedFamilyRequest projection request stable `shouldReturn` False
      outcome `shouldBe` KindOperationCallbackReturned ()
  it "does not retrofit family provenance onto a legacy operation" $
    withFixture $ \_ projection _ _ _ -> do
      let operation = replicate 32 'd'
      recordKindIntent projection operation `shouldReturn` KindIntentRecorded
      observeKindFamilyIntent projection `shouldReturn` KindIntentConflict
      recordKindFamilyIntent projection operation `shouldReturn` KindIntentAlreadyExists
      observeKindIntent projection `shouldReturn` KindIntentMatches operation
      domain <-
        maybe
          (fail "domain invalid")
          pure
          (hostManagerDomain "11111111-1111-1111-1111-111111111111" (replicate 32 'a') ":1.42" 1000 1234 5678)
      window <- maybe (fail "window invalid") pure (hostExecutionWindow 50 10 20 30 40)
      request <-
        either
          (fail . show)
          pure
          (mkKindControllerRequest projection operation ("sha256:" ++ replicate 64 'a') domain window)
      result <- withRecoveredKindOperation projection operation (recordFamilyLaunch projection request)
      result `shouldBe` KindOperationCallbackReturned FamilyLaunchRefused
  it "creates the family protocol under the initial operation lease" $
    withFixture $ \_ projection _ _ _ -> do
      let operation = replicate 32 'd'
      result <- withNewKindFamilyOperation projection operation $ \stable -> do
        observeKindFamilyIntent projection `shouldReturn` KindIntentMatches operation
        observeKindOwnerFamilyIntent projection `shouldReturn` KindIntentConflict
        observeKindExternalFamilyIntent projection `shouldReturn` KindIntentMatches operation
        stable `shouldReturn` True
      result `shouldBe` KindOperationCallbackReturned ()
      recordKindIntent projection operation `shouldReturn` KindIntentAlreadyExists
  it "distinguishes owner-first family intent from externally prepared history" $
    withFixture $ \_ projection _ _ _ -> do
      let operation = replicate 32 'd'
      result <- withNewKindOwnerFamilyOperation projection operation $ \stable -> do
        observeKindIntent projection `shouldReturn` KindIntentMatches operation
        observeKindFamilyIntent projection `shouldReturn` KindIntentMatches operation
        observeKindOwnerFamilyIntent projection `shouldReturn` KindIntentMatches operation
        observeKindExternalFamilyIntent projection `shouldReturn` KindIntentConflict
        stable `shouldReturn` True
      result `shouldBe` KindOperationCallbackReturned ()
      recordKindFamilyIntent projection operation `shouldReturn` KindIntentAlreadyExists
      let path = scopeRoot (bootstrapScope projection) </> "kind-intent.json"
      stored <- BS.readFile path
      external <- case Aeson.decodeStrict' stored of
        Just (Aeson.Object fields) ->
          pure $
            Aeson.Object $
              KeyMap.insert "schema_version" (Aeson.toJSON (3 :: Int)) $
                KeyMap.insert "controller_protocol" (Aeson.toJSON ("family-v1" :: String)) fields
        _ -> fail "owner-family intent was not an object"
      BL.writeFile path (Aeson.encode external)
      observeKindOwnerFamilyIntent projection `shouldReturn` KindIntentConflict
      observeKindExternalFamilyIntent projection `shouldReturn` KindIntentMatches operation
      ending <- (+ 1000000000) <$> getMonotonicTimeNSec
      outcome <- reconcileFamilyPrerequisites ending projection operation id
      assertMutationInvariant
        "controller.rejects_external_family"
        (outcome == ReconcileFamilyAdmissionRefused)
  it "waits for the scope lease before checking owner-family prerequisite admission" $
    withFixture $ \_ projection _ _ _ -> do
      let operation = replicate 32 'd'
          root = scopeRoot (bootstrapScope projection)
      withNewKindOwnerFamilyOperation projection operation (const (pure ()))
        `shouldReturn` KindOperationCallbackReturned ()
      entered <- newEmptyMVar
      release <- newEmptyMVar
      admissionChecks <- newIORef (0 :: Int)
      let admit _ = modifyIORef' admissionChecks (+ 1) >> pure False
      withAsync
        (withRecoveredKindOperation projection operation $ \_ -> putMVar entered () >> takeMVar release)
        $ \owner -> do
          takeMVar entered
          now <- getMonotonicTimeNSec
          reconcileFamilyPrerequisites now projection operation admit
            `shouldReturn` ReconcileFamilyAdmissionRefused
          withAsync (reconcileFamilyPrerequisites (now + 5000000000) projection operation admit) $ \worker -> do
            threadDelay 80000
            poll worker >>= maybe (pure ()) (const (fail "the family worker returned before lease release"))
            readIORef admissionChecks `shouldReturn` 0
            putMVar release ()
            wait owner `shouldReturn` KindOperationCallbackReturned ()
            wait worker `shouldReturn` ReconcileFamilyAdmissionRefused
      readIORef admissionChecks `shouldReturn` 2
      doesFileExist (root </> "kind-network-intent.json") `shouldReturn` False
  it "retains early teardown admission across API loss and fences Authority deployment" $
    withFixture $ \_ projection _ _ _ -> do
      let operation = replicate 32 'd'
          root = scopeRoot (bootstrapScope projection)
          apiConfig = root </> "control" </> "kubeconfig"
          checkpoint = root </> "kind-teardown-admission.json"
      let deploySteps = map (\step -> (serviceStepName step, serviceStepOk step)) <$> deployAuthority projection
      withNewKindOwnerFamilyOperation
        projection
        operation
        ( const $ do
            admitKindTeardown projection >>= (`shouldSatisfy` isLeft)
            deploySteps `shouldReturn` [("authority-admission", False)]
        )
        `shouldReturn` KindOperationCallbackReturned ()
      createDirectoryIfMissing True (root </> "control")
      BS.writeFile apiConfig "invalid"
      unobservable <- admitKindTeardown projection
      assertMutationInvariant "delete.requires_observed_admission" (isLeft unobservable)
      observeKindTeardownAdmission projection `shouldReturn` KindIntentMissing
      removeFile apiConfig
      let localJournal = root </> "authority"
      createSymbolicLink (root </> "missing-local-journal") localJournal
      admitKindTeardown projection >>= (`shouldSatisfy` isLeft)
      observeKindTeardownAdmission projection `shouldReturn` KindIntentMissing
      removeFile localJournal
      admitKindTeardown projection `shouldReturn` Right ()
      observeKindTeardownAdmission projection `shouldReturn` KindIntentMatches operation
      originalCheckpoint <- BS.readFile checkpoint
      case Aeson.decodeStrict' originalCheckpoint of
        Just (Aeson.Object fields) ->
          BL.writeFile checkpoint $
            Aeson.encode $
              Aeson.Object (KeyMap.insert "operation_id" (Aeson.toJSON (replicate 32 'f')) fields)
        _ -> fail "the teardown admission was not an object"
      admitKindTeardown projection >>= (`shouldSatisfy` isLeft)
      observeKindOwnerFamilyIntent projection `shouldReturn` KindIntentMatches operation
      BS.writeFile checkpoint originalCheckpoint
      BS.writeFile apiConfig "invalid"
      admitKindTeardown projection `shouldReturn` Right ()
      archive <- archiveCompletedOperation projection
      case archive of
        ArchiveNotCompletelyRemoved _ -> pure ()
        other -> fail ("archive accepted admission without settled removal: " ++ show other)
      observeKindOwnerFamilyIntent projection `shouldReturn` KindIntentMatches operation
      doesDirectoryExist (root </> "history") `shouldReturn` False
      let reservedArchive = root </> "history" </> operation
      createDirectoryIfMissing True reservedArchive
      admitKindTeardown projection >>= (`shouldSatisfy` isLeft)
      removeDirectory reservedArchive
      admissionSteps <- deploySteps
      assertMutationInvariant
        "delete.fences_authority_deployment"
        (admissionSteps == [("authority-admission", False)])
      doesDirectoryExist (root </> "authority-journal") `shouldReturn` False
      createDirectoryIfMissing False (root </> "authority-journal")
      admitKindTeardown projection >>= (`shouldSatisfy` isLeft)
      BS.readFile (root </> "kind-intent.json") >>= BS.writeFile checkpoint
      observeKindTeardownAdmission projection `shouldReturn` KindIntentConflict
      removeFile checkpoint
      createSymbolicLink (root </> "missing-admission") checkpoint
      admitKindTeardown projection >>= (`shouldSatisfy` isLeft)
  it "prepares an owner-first operation before any prerequisite intent" $
    withFixture $ \_ projection _ _ _ -> do
      result <- prepareNewOwnerFamilyOperation (pure Nothing) projection
      case result of
        ReconcileFamilyOperationReady operation -> do
          observeKindOwnerFamilyIntent projection `shouldReturn` KindIntentMatches operation
          let root = scopeRoot (bootstrapScope projection)
          mapM_
            (\name -> doesFileExist (root </> name) `shouldReturn` False)
            [ "node-image-intent.json"
            , "kind-network-intent.json"
            , "kind-node-var-volume-intent.json"
            , "kind-node-create-intent.json"
            ]
        other -> fail ("owner-first preparation was refused: " ++ show other)
  it "retains distinct family primary and closing dispositions under the operation lease" $
    withFixture $ \parent projection _ _ _ -> do
      let operation = replicate 32 'd'
          digestText = replicate 64 'a'
          result =
            FamilyResult
              FamilyWorkerConfirmed
              FamilyWorkerIoUnconfirmed
              FamilyParentUnconfirmed
              FamilyInputUnconfirmed
              FamilyPostReceiptComplete
              FamilyPostLeaseUnconfirmed
          recordPath = takeDirectory parent </> ".test-data" </> "fixture" </> "kind-family-dispatch-result.json"
      recordKindIntent projection operation >>= (`shouldBe` KindIntentRecorded)
      outcome <- withRecoveredKindOperation projection operation $ \stable -> do
        observeFamilyResult projection operation stable >>= (`shouldBe` FamilyResultMissing)
        recordFamilyResult projection operation digestText result stable
          >>= (`shouldBe` FamilyResultRecorded)
        observeFamilyResult projection operation stable
          >>= (`shouldBe` FamilyResultObserved digestText result)
        recordFamilyResult projection operation digestText result stable
          >>= (`shouldBe` FamilyResultAlreadyExists)
        observeFamilyResult projection operation (pure False) >>= (`shouldBe` FamilyResultUnobservable)
        BS.writeFile recordPath "{}"
        observeFamilyResult projection operation stable >>= (`shouldBe` FamilyResultConflict)
      outcome `shouldBe` KindOperationCallbackReturned ()
  it "binds canonical kind controller requests to scope, operation, manager and original window" $
    withFixture $ \_ projection _ _ _ -> do
      let operation = replicate 32 'd'
          exeDigest = "sha256:" ++ replicate 64 'a'
      domain <-
        maybe
          (fail "domain invalid")
          pure
          (hostManagerDomain "11111111-1111-1111-1111-111111111111" (replicate 32 'a') ":1.42" 1000 1234 5678)
      otherDomain <-
        maybe
          (fail "other domain invalid")
          pure
          (hostManagerDomain "11111111-1111-1111-1111-111111111111" (replicate 32 'a') ":1.43" 1000 1234 5678)
      window <- maybe (fail "window invalid") pure (hostExecutionWindow 50 10 20 30 40)
      otherWindow <- maybe (fail "other window invalid") pure (hostExecutionWindow 51 10 20 30 40)
      key <- maybe (fail "key invalid") pure (kindControllerOperationKey operation)
      otherKey <- maybe (fail "other key invalid") pure (kindControllerOperationKey (replicate 32 'e'))
      recoveryKey <-
        maybe (fail "recovery key invalid") pure (kindProbeRecoveryKey operation (replicate 32 'e'))
      recoveryKey `shouldNotBe` key
      kindProbeRecoveryKey operation operation `shouldBe` Nothing
      kindProbeRecoveryKey operation "invalid" `shouldBe` Nothing
      kindProbeRecoveryKey (replicate 32 'e') operation `shouldNotBe` Just recoveryKey
      request <-
        either (fail . show) pure (mkKindControllerRequest projection operation exeDigest domain window)
      let encoded = encodeKindControllerRequest request
          decode = decodeKindControllerRequest projection key window domain exeDigest
      decode encoded `shouldBe` Right request
      decodeKindControllerRequest projection otherKey window domain exeDigest encoded
        `shouldBe` Left KindRequestBindingMismatch
      decodeKindControllerRequest projection key otherWindow domain exeDigest encoded
        `shouldBe` Left KindRequestBindingMismatch
      decodeKindControllerRequest projection key window otherDomain exeDigest encoded
        `shouldBe` Left KindRequestBindingMismatch
      decodeKindControllerRequest projection key window domain ("sha256:" ++ replicate 64 'b') encoded
        `shouldBe` Left KindRequestBindingMismatch
      withFixture $ \_ otherProjection _ _ _ ->
        decodeKindControllerRequest otherProjection key window domain exeDigest encoded
          `shouldBe` Left KindRequestBindingMismatch
      decode (encoded <> " ") `shouldBe` Left KindRequestNonCanonical
      decode "{}" `shouldBe` Left KindRequestMalformed
      decode (BS.replicate 16385 0) `shouldBe` Left KindRequestTooLarge
      mkKindControllerRequest projection operation "sha256:invalid" domain window
        `shouldBe` Left KindRequestInvalid
  it "binds a worker receipt to the running recorded node" $
    withFixture $ \_ projection _ _ _ -> do
      let identifier = replicate 64 'a'
          image = "sha256:" ++ replicate 64 'c'
          tool = "sha256:50030de23cf40a18505f20426f6a8506bedf13c6e509244bd1fa9463721b0f54"
          plan = bootstrapKindPlan projection
          input =
            KindNodeCreateInput
              tool
              image
              (replicate 64 'b')
              (replicate 32 'b')
              (replicate 32 'd')
              (kindNodeRunArguments plan image)
          daemon = DockerDaemonObserved "daemon-a" (DockerSocketIdentity 1 2 1000 0o140660)
      intent <-
        maybe
          (fail "node intent fixture was rejected")
          pure
          (mkKindNodeCreateIntent projection input daemon)
      let status nodeId inspection removal =
            NodeCreateStatus
              (NodeCreateRecoveryRecorded intent)
              True
              (Just NodeCreateAttemptMatches)
              (Just (NodeCreateResultObserved (DockerNodeContainerCreateReply 201 (Just nodeId))))
              (Just NodeStartAttemptMatches)
              (Just (NodeStartResultObserved (DockerNodeContainerStartReply 204)))
              (Just NodeRemoveControlMissing)
              (Just removal)
              Nothing
              (Just (Right inspection))
          good = status identifier (DockerNodeContainerMatching True) NodeRemoveAttemptMissing
      matchesNodeCreateStatus identifier good `shouldBe` True
      assertMutationInvariant
        "controller.rejects_wrong_node"
        (not (matchesNodeCreateStatus (replicate 64 'e') good))
      matchesNodeCreateStatus
        identifier
        (status identifier (DockerNodeContainerMatching False) NodeRemoveAttemptMissing)
        `shouldBe` False
      matchesNodeCreateStatus
        identifier
        (status identifier (DockerNodeContainerMatching True) NodeRemoveAttemptMatches)
        `shouldBe` False
  it "accepts only a bound worker receipt and a scoped diagnostic path" $
    withFixture $ \parent projection _ _ _ -> do
      let operation = replicate 32 'd'
          identifier = replicate 64 'a'
          root = takeDirectory parent </> ".test-data" </> "fixture"
      validControllerResultPath projection operation (root </> ("kind-controller-result-" ++ operation))
        `shouldBe` True
      validControllerResultPath projection operation (takeDirectory parent </> "foreign") `shouldBe` False
      validControllerResultPath projection "../bad" (root </> "kind-controller-result-../bad")
        `shouldBe` False
      controllerReceiptNode (KindOperationCallbackReturned (ControllerReceiptObserved identifier))
        `shouldBe` Just identifier
      controllerReceiptNode (KindOperationCallbackReturned (ControllerReceiptObserved "invalid"))
        `shouldBe` Nothing
      controllerReceiptNode (KindOperationCallbackReturned ControllerReceiptConflict) `shouldBe` Nothing
      controllerReceiptNode (KindOperationCallbackReturned ControllerReceiptUnobservable)
        `shouldBe` Nothing
  it "binds controller probe to the operation and retains changed results" $ do
    live <- newIORef True
    calls <- newIORef (0 :: Int)
    let stable = readIORef live
        receipt = pure (Just "recorded-node")
        ready = pure (ReadinessObserved True 1 1 3 3)
        probe = modifyIORef' calls (+ 1) >> pure "probe returned"
    successful <- observeControllerUnderLease stable receipt (const (pure True)) ready probe
    successful `shouldBe` (Just "recorded-node", ReadinessObserved True 1 1 3 3, "probe returned")
    refused <- observeControllerUnderLease stable receipt (const (pure False)) ready probe
    case refused of
      (Nothing, ReadinessUnobservable _, _) -> pure ()
      _ -> fail "unmatched node accepted"
    readIORef calls >>= (`shouldBe` 1)
    changed <- observeControllerUnderLease stable receipt (const (pure True)) ready $ do
      writeIORef live False
      probe
    case changed of
      (Nothing, ReadinessUnobservable _, detail) -> ("probe returned" `isInfixOf` detail) `shouldBe` True
      _ -> fail "changed operation accepted"
    readIORef calls >>= (`shouldBe` 2)
  it "requires successful probe observations and confirmed cleanup for enforcement" $ do
    let observation = EnforcementObservation True True True False True
        complete = EnforcementOutcome (Just observation) Nothing EnforcementCleanupConfirmed
    enforcementComplete complete `shouldBe` True
    enforcementComplete (complete {enforcementFailure = Just "probe failed"}) `shouldBe` False
    enforcementComplete
      (complete {enforcementCleanup = EnforcementCleanupUnconfirmed "namespace removed"})
      `shouldBe` False
    enforcementComplete (complete {enforcementObservation = Nothing}) `shouldBe` False
    enforcementComplete
      (complete {enforcementObservation = Just (observation {observedPolicyOther = True})})
      `shouldBe` False
  it "never deletes a namespace whose creation or UID is unconfirmed" $ do
    calls <- newIORef ([] :: [[String]])
    let execute arguments _ = modifyIORef' calls (++ [arguments]) >> pure (Right (1, "already exists"))
    result <- observeNetworkEnforcementWith execute (const (pure ())) "prodbox-test-probe"
    enforcementObservation result `shouldBe` Nothing
    observed <- readIORef calls
    let expected = [["create", "namespace", "prodbox-test-probe", "-o", "jsonpath={.metadata.uid}"]]
    assertMutationInvariant "network.rejects_foreign_namespace_cleanup" (observed == expected)
    malformedCalls <- newIORef ([] :: [[String]])
    let malformed arguments _ = modifyIORef' malformedCalls (++ [arguments]) >> pure (Right (0, "not-a-uid"))
    malformedResult <- observeNetworkEnforcementWith malformed (const (pure ())) "prodbox-test-probe"
    enforcementObservation malformedResult `shouldBe` Nothing
    readIORef malformedCalls >>= (`shouldBe` expected)
  it "requires durable intent and a recorded UID before probe effects" $ do
    calls <- newIORef ([] :: [[String]])
    let uid = "12345678-1234-1234-1234-123456789abc"
        execute arguments _ = modifyIORef' calls (++ [arguments]) >> pure (Right (0, uid))
        namespace = "prodbox-test-probe"
    refused <-
      observeNetworkEnforcementRecorded
        execute
        (const (pure ()))
        (pure False)
        (const (pure True))
        (const (pure True))
        namespace
    enforcementCleanup refused `shouldBe` EnforcementCleanupNotStarted
    readIORef calls >>= (`shouldBe` [])
    unrecorded <-
      observeNetworkEnforcementRecorded
        execute
        (const (pure ()))
        (pure True)
        (const (pure False))
        (const (pure True))
        namespace
    enforcementObservation unrecorded `shouldBe` Nothing
    readIORef calls
      >>= (`shouldBe` [["create", "namespace", namespace, "-o", "jsonpath={.metadata.uid}"]])
  it "binds probe records to operation, namespace, UID and retained root" $
    withFixture $ \_ projection _ _ _ -> do
      let operation = replicate 32 'd'
          namespace = "prodbox-test-probe"
          uid = "12345678-1234-1234-1234-123456789abc"
      recordKindIntent projection operation >>= (`shouldBe` KindIntentRecorded)
      outcome <- withRecoveredKindOperation projection operation $ \stable -> do
        observeProbeJournal projection operation namespace stable `shouldReturn` ProbeJournalEmpty
        observeProbeRecord projection operation namespace ProbeIntent stable >>= (`shouldBe` ProbeMissing)
        recordProbeRecord projection (replicate 32 'e') namespace ProbeIntent stable
          >>= (`shouldBe` ProbeRefused)
        observeProbeRecord projection operation namespace ProbeIntent stable >>= (`shouldBe` ProbeMissing)
        recordProbeRecord projection operation namespace ProbeIntent stable >>= (`shouldBe` ProbeRecorded)
        observeProbeJournal projection operation namespace stable `shouldReturn` ProbeJournalUidUnconfirmed
        observeProbeRecord projection operation namespace ProbeIntent stable >>= (`shouldBe` ProbeMatches)
        recordProbeRecord projection operation namespace ProbeIntent stable
          >>= (`shouldBe` ProbeAlreadyExists)
        observeProbeCreated projection operation namespace stable >>= (`shouldBe` ProbeCreatedMissing)
        recordProbeRecord projection operation namespace (ProbeCreated uid) stable
          >>= (`shouldBe` ProbeRecorded)
        observeProbeJournal projection operation namespace stable
          `shouldReturn` ProbeJournalRemovalMissing uid
        observeProbeCreated projection operation namespace stable >>= (`shouldBe` ProbeCreatedObserved uid)
        observeProbeCreated projection (replicate 32 'e') namespace stable
          >>= (`shouldBe` ProbeCreatedConflict)
        observeProbeRecord projection operation namespace (ProbeCreated uid) stable
          >>= (`shouldBe` ProbeMatches)
        observeProbeRecord
          projection
          operation
          namespace
          (ProbeCreated "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
          stable
          >>= (`shouldBe` ProbeConflict)
        observeProbeRecord projection (replicate 32 'e') namespace ProbeIntent stable
          >>= (`shouldBe` ProbeConflict)
        recordProbeRecord projection operation namespace (ProbeRemovalAttempt uid operation) stable
          `shouldReturn` ProbeRefused
        recordProbeRecord projection operation namespace (ProbeRemovalAttempt uid (replicate 32 'e')) stable
          `shouldReturn` ProbeRecorded
        observeProbeJournal projection operation namespace stable
          `shouldReturn` ProbeJournalRemovalAttempted uid (replicate 32 'e')
        recordProbeRecord projection operation namespace (ProbeRemoved uid) stable
          `shouldReturn` ProbeRecorded
        observeProbeJournal projection operation namespace stable
          `shouldReturn` ProbeJournalRemovalRecorded uid
        observeProbeJournal projection operation namespace (pure False) `shouldReturn` ProbeJournalConflict
        let failedNamespace = "failed-probe"
            recoveryId = replicate 32 'e'
        recordProbeRecord projection operation failedNamespace (ProbeRemovalFailure uid recoveryId 7) stable
          `shouldReturn` ProbeRefused
        mapM_
          ( \stage -> recordProbeRecord projection operation failedNamespace stage stable `shouldReturn` ProbeRecorded
          )
          [ ProbeIntent
          , ProbeCreated uid
          , ProbeRemovalAttempt uid recoveryId
          , ProbeRemovalFailure uid recoveryId 7
          ]
        observeProbeJournal projection operation failedNamespace stable
          `shouldReturn` ProbeJournalRemovalFailed uid recoveryId 7
        recordProbeRecord projection operation failedNamespace (ProbeRemoved uid) stable
          `shouldReturn` ProbeRecorded
        observeProbeJournal projection operation failedNamespace stable
          `shouldReturn` ProbeJournalRemovalRecordedAfterFailure uid recoveryId 7
        recordProbeRecord projection operation "orphan-probe" (ProbeRemoved uid) stable
          `shouldReturn` ProbeRecorded
        observeProbeJournal projection operation "orphan-probe" stable `shouldReturn` ProbeJournalConflict
        recordProbeRecord projection operation "../foreign" ProbeIntent stable >>= (`shouldBe` ProbeRefused)
      outcome `shouldBe` KindOperationCallbackReturned ()
  it "retains exact cleanup launch coordinates before any removal attempt" $
    withFixture $ \parent projection _ _ _ -> do
      let operation = replicate 32 'd'
          recovery = replicate 32 'e'
          namespace = "prodbox-netcheck-" ++ take 12 operation
          uid = "12345678-1234-1234-1234-123456789abc"
          recordPath =
            takeDirectory parent
              </> ".test-data"
              </> "fixture"
              </> ("kind-network-probe-" ++ namespace ++ "-recovery-launch.json")
      domain <-
        maybe
          (fail "domain invalid")
          pure
          (hostManagerDomain "11111111-1111-1111-1111-111111111111" (replicate 32 'a') ":1.42" 1000 1234 5678)
      window <- maybe (fail "window invalid") pure (hostExecutionWindow 50 10 20 30 40)
      controller <-
        either
          (fail . show)
          pure
          (mkKindControllerRequest projection operation ("sha256:" ++ replicate 64 'a') domain window)
      request <- either (fail . show) pure (mkProbeRecoveryRequest controller recovery uid)
      other <-
        either
          (fail . show)
          pure
          (mkProbeRecoveryRequest controller recovery "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
      classifyProbePublication ProbeRecoveryLaunchMissing ProbePublicationMissing
        `shouldBe` ProbePublicationNotRecorded
      classifyProbePublication (ProbeRecoveryLaunchObserved request) ProbePublicationMissing
        `shouldBe` ProbePublicationBeforeAttempt recovery
      classifyProbePublication (ProbeRecoveryLaunchObserved request) (ProbePublicationObserved request)
        `shouldBe` ProbePublicationAttemptRecorded recovery
      classifyProbePublication (ProbeRecoveryLaunchObserved request) (ProbePublicationObserved other)
        `shouldBe` ProbePublicationStateUnconfirmed
      classifyProbePublication ProbeRecoveryLaunchMissing (ProbePublicationObserved request)
        `shouldBe` ProbePublicationStateUnconfirmed
      classifyProbePublication (ProbeRecoveryLaunchObserved request) ProbePublicationUnobservable
        `shouldBe` ProbePublicationStateUnconfirmed
      probeCleanupPermitsNodeRemoval
        (ProbeJournalRemovalRecorded uid)
        (ProbeRecoveryLaunchObserved request)
        `shouldBe` False
      probeRecoveryReceiptMatches uid request (ProbeRemovalAttemptObserved uid recovery) `shouldBe` True
      probeRecoveryReceiptMatches uid request (ProbeRemovalAttemptObserved uid operation) `shouldBe` False
      probeRecoveryReceiptMatches
        "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        request
        (ProbeRemovalAttemptObserved uid recovery)
        `shouldBe` False
      probeRecoveryReceiptMatches uid request ProbeRemovalAttemptUnobservable `shouldBe` False
      mkProbeRecoveryRequest controller operation uid `shouldBe` Left KindRequestInvalid
      mkProbeRecoveryRequest controller recovery "bad" `shouldBe` Left KindRequestInvalid
      decodeProbeRecoveryRequest projection operation (encodeProbeRecoveryRequest request)
        `shouldBe` Right request
      decodeProbeRecoveryRequest projection recovery (encodeProbeRecoveryRequest request)
        `shouldBe` Left KindRequestBindingMismatch
      recordKindFamilyIntent projection operation `shouldReturn` KindIntentRecorded
      outcome <- withRecoveredKindOperation projection operation $ \stable -> do
        observeProbeRecoveryLaunch projection operation namespace stable
          `shouldReturn` ProbeRecoveryLaunchMissing
        recordProbeRecord projection operation namespace (ProbeRecoveryLaunch request) stable
          `shouldReturn` ProbeRefused
        recordProbeRecord projection operation namespace (ProbePublicationAttempt request) stable
          `shouldReturn` ProbeRefused
        recordProbeRecord projection operation namespace ProbeIntent stable `shouldReturn` ProbeRecorded
        recordProbeRecord projection operation namespace (ProbeCreated uid) stable
          `shouldReturn` ProbeRecorded
        recordProbeRecord projection operation namespace (ProbeRecoveryLaunch other) stable
          `shouldReturn` ProbeRefused
        recordProbeRecord projection operation namespace (ProbeRecoveryLaunch request) stable
          `shouldReturn` ProbeRecorded
        observeProbeRecoveryLaunch projection operation namespace stable
          `shouldReturn` ProbeRecoveryLaunchObserved request
        recordProbeRecord projection operation namespace (ProbeRecoveryLaunch request) stable
          `shouldReturn` ProbeAlreadyExists
        observeProbePublicationAttempt projection operation namespace stable
          `shouldReturn` ProbePublicationMissing
        recordProbeRecord projection operation namespace (ProbePublicationAttempt other) stable
          `shouldReturn` ProbeRefused
        recordProbeRecord projection operation namespace (ProbePublicationAttempt request) stable
          `shouldReturn` ProbeRecorded
        observeProbePublicationAttempt projection operation namespace stable
          `shouldReturn` ProbePublicationObserved request
        recordProbeRecord projection operation namespace (ProbePublicationAttempt request) stable
          `shouldReturn` ProbeAlreadyExists
        observeProbeRecoveryLaunch projection operation namespace (pure False)
          `shouldReturn` ProbeRecoveryLaunchUnobservable
        BS.writeFile recordPath "{}"
        observeProbeRecoveryLaunch projection operation namespace stable
          `shouldReturn` ProbeRecoveryLaunchConflict
      outcome `shouldBe` KindOperationCallbackReturned ()
  it "retains distinct verifier coordinates for an uncertain attempt" $
    withFixture $ \parent projection _ _ _ -> do
      let operation = replicate 32 'd'
          prior = replicate 32 'e'
          verifier = replicate 32 'f'
          namespace = "prodbox-netcheck-" ++ take 12 operation
          uid = "12345678-1234-1234-1234-123456789abc"
      domain <-
        maybe
          (fail "domain invalid")
          pure
          (hostManagerDomain "11111111-1111-1111-1111-111111111111" (replicate 32 'a') ":1.42" 1000 1234 5678)
      window <- maybe (fail "window invalid") pure (hostExecutionWindow 50 10 20 30 40)
      controller <-
        either
          (fail . show)
          pure
          (mkKindControllerRequest projection operation ("sha256:" ++ replicate 64 'a') domain window)
      original <- either (fail . show) pure (mkProbeRecoveryRequest controller prior uid)
      verifierCoordinates <- either (fail . show) pure (mkProbeRecoveryRequest controller verifier uid)
      request <- either (fail . show) pure (mkProbeAttemptVerifierRequest verifierCoordinates prior)
      mkProbeAttemptVerifierRequest verifierCoordinates verifier `shouldBe` Left KindRequestInvalid
      mkProbeAttemptVerifierRequest verifierCoordinates operation `shouldBe` Left KindRequestInvalid
      decodeProbeAttemptVerifierRequest projection operation (encodeProbeAttemptVerifierRequest request)
        `shouldBe` Right request
      decodeProbeAttemptVerifierRequest projection prior (encodeProbeAttemptVerifierRequest request)
        `shouldBe` Left KindRequestBindingMismatch
      recordKindFamilyIntent projection operation `shouldReturn` KindIntentRecorded
      outcome <- withRecoveredKindOperation projection operation $ \stable -> do
        recordProbeRecord projection operation namespace (ProbeVerifierLaunch request) stable
          `shouldReturn` ProbeRefused
        recordProbeRecord projection operation namespace (ProbeAttemptReadback uid prior verifier) stable
          `shouldReturn` ProbeRefused
        mapM_
          (\stage -> recordProbeRecord projection operation namespace stage stable `shouldReturn` ProbeRecorded)
          [ ProbeIntent
          , ProbeCreated uid
          , ProbeRecoveryLaunch original
          , ProbePublicationAttempt original
          , ProbeRemovalAttempt uid prior
          ]
        recordProbeRecord projection operation namespace (ProbeVerifierLaunch request) stable
          `shouldReturn` ProbeRecorded
        observeProbeJournal projection operation namespace stable
          `shouldReturn` ProbeJournalVerifierPending uid prior verifier False
        recordProbeRecord projection operation namespace (ProbeAttemptReadback uid prior verifier) stable
          `shouldReturn` ProbeRefused
        recordProbeRecord projection operation namespace (ProbeVerifierPublicationAttempt request) stable
          `shouldReturn` ProbeRecorded
        observeProbeJournal projection operation namespace stable
          `shouldReturn` ProbeJournalVerifierPending uid prior verifier True
        recordProbeRecord projection operation namespace (ProbeAttemptReadback uid prior verifier) stable
          `shouldReturn` ProbeRecorded
        observeProbeJournal projection operation namespace stable
          `shouldReturn` ProbeJournalAttemptReadbackRecorded uid prior verifier
        recordProbeRecord projection operation namespace (ProbeAttemptReadback uid prior prior) stable
          `shouldReturn` ProbeRefused
        removeFile
          ( takeDirectory parent
              </> ".test-data"
              </> "fixture"
              </> ("kind-network-probe-" ++ namespace ++ "-verifier-launch.json")
          )
        observeProbeJournal projection operation namespace stable `shouldReturn` ProbeJournalConflict
      outcome `shouldBe` KindOperationCallbackReturned ()
  it "records an uncertain attempt readback without issuing another delete" $ do
    let operation = replicate 32 'd'
        prior = replicate 32 'e'
        verifier = replicate 32 'f'
        namespace = "prodbox-netcheck-" ++ take 12 operation
        uid = "12345678-1234-1234-1234-123456789abc"
        control = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        emptyList = "{\"apiVersion\":\"v1\",\"kind\":\"NamespaceList\",\"items\":[]}"
    events <- newIORef ([] :: [String])
    let execute arguments _ = do
          modifyIORef' events (++ [unwords arguments])
          case arguments of
            ["get", "namespace", "kube-system", "-o", _] -> pure (Right (0, control))
            "get" : "namespaces" : _ -> pure (Right (0, emptyList))
            _ -> pure (Left "unexpected request")
        record value first second = do
          modifyIORef' events (++ ["record readback"])
          pure (if (value, first, second) == (uid, prior, verifier) then ProbeRecorded else ProbeRefused)
    confirmAttemptedProbeAbsenceWith operation namespace uid prior prior (pure True) execute record
      `shouldReturn` ProbeAttemptReadbackInvalid
    confirmAttemptedProbeAbsenceWith operation namespace uid prior verifier (pure False) execute record
      `shouldReturn` ProbeAttemptReadbackIdentityChanged
    readIORef events `shouldReturn` []
    confirmAttemptedProbeAbsenceWith operation namespace uid prior verifier (pure True) execute record
      `shouldReturn` ProbeAttemptReadbackRecorded
    seen <- readIORef events
    length seen `shouldBe` 4
    last seen `shouldBe` "record readback"
    any (isInfixOf "delete") seen `shouldBe` False
    let blind arguments input = case arguments of
          "get" : "namespaces" : _ -> pure (Left "unavailable")
          _ -> execute arguments input
    confirmAttemptedProbeAbsenceWith operation namespace uid prior verifier (pure True) blind record
      `shouldReturn` ProbeAttemptReadbackAbsenceUnconfirmed
    confirmAttemptedProbeAbsenceWith
      operation
      namespace
      uid
      prior
      verifier
      (pure True)
      execute
      (\_ _ _ -> pure ProbeRefused)
      `shouldReturn` ProbeAttemptReadbackRecordRefused ProbeRefused
    current <- newIORef True
    let changed _ _ _ = writeIORef current False >> pure ProbeRecorded
    confirmAttemptedProbeAbsenceWith
      operation
      namespace
      uid
      prior
      verifier
      (readIORef current)
      execute
      changed
      `shouldReturn` ProbeAttemptReadbackChangedAfterRecord
  it "recovers only the recorded probe UID and requires independent absence" $ do
    let operation = replicate 32 'd'
        namespace = "prodbox-netcheck-" ++ take 12 operation
        uid = "12345678-1234-1234-1234-123456789abc"
        other = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        emptyList = "{\"apiVersion\":\"v1\",\"kind\":\"NamespaceList\",\"items\":[]}"
    events <- newIORef ([] :: [String])
    body <- newIORef BS.empty
    let execute arguments input = do
          modifyIORef' events (++ [unwords arguments])
          case arguments of
            ["get", "namespace", name, "-o", _] | name == namespace -> pure (Right (0, uid))
            ["delete", "--raw", _, "-f", "-"] -> writeIORef body input >> pure (Right (0, ""))
            "wait" : _ -> pure (Right (0, ""))
            ["get", "namespace", "kube-system", "-o", _] -> pure (Right (0, other))
            "get" : "namespaces" : _ -> pure (Right (0, emptyList))
            _ -> pure (Left "unexpected request")
        attempt _ = modifyIORef' events (++ ["record attempt"]) >> pure ProbeRecorded
        failure _ code = modifyIORef' events (++ ["record delete failure " ++ show code]) >> pure ProbeRecorded
        receipt _ = modifyIORef' events (++ ["record receipt"]) >> pure ProbeRecorded
    recoverRecordedProbeWith operation "foreign" uid (pure True) execute attempt failure receipt
      `shouldReturn` ProbeRecoveryInvalid
    recoverRecordedProbeWith operation namespace other (pure True) execute attempt failure receipt
      `shouldReturn` ProbeRecoveryIdentityUnconfirmed
    readIORef events >>= (\seen -> any (isInfixOf "delete") seen `shouldBe` False)
    writeIORef events []
    recoverRecordedProbeWith
      operation
      namespace
      uid
      (pure True)
      execute
      (const (pure ProbeAlreadyExists))
      failure
      receipt
      `shouldReturn` ProbeRecoveryAttemptRefused ProbeAlreadyExists
    readIORef events >>= (\seen -> any (isInfixOf "delete") seen `shouldBe` False)
    let lost arguments input = case arguments of
          "delete" : _ -> pure (Left "reply lost")
          _ -> execute arguments input
        blind arguments input = case arguments of
          "get" : "namespaces" : _ -> pure (Left "inventory unavailable")
          _ -> execute arguments input
        failed arguments input = case arguments of
          "delete" : _ -> pure (Right (1, ""))
          _ -> execute arguments input
        failedBlind arguments input = case arguments of
          "get" : "namespaces" : _ -> pure (Left "inventory unavailable")
          _ -> failed arguments input
    recoverRecordedProbeWith operation namespace uid (pure True) lost attempt failure receipt
      `shouldReturn` ProbeRecoveryDeleteUnconfirmed
    recoverRecordedProbeWith operation namespace uid (pure True) blind attempt failure receipt
      `shouldReturn` ProbeRecoveryAbsenceUnconfirmed
    writeIORef events []
    recoverRecordedProbeWith operation namespace uid (pure True) failed attempt failure receipt
      `shouldReturn` ProbeRecoveryCompletedAfterDeleteFailure 1
    failedEvents <- readIORef events
    take 3 failedEvents
      `shouldBe` [ "get namespace " ++ namespace ++ " -o jsonpath={.metadata.uid}"
                 , "record attempt"
                 , "record delete failure 1"
                 ]
    last failedEvents `shouldBe` "record receipt"
    writeIORef events []
    recoverRecordedProbeWith operation namespace uid (pure True) failedBlind attempt failure receipt
      `shouldReturn` ProbeRecoveryDeleteFailureAbsenceUnconfirmed 1
    readIORef events >>= (\seen -> ("record receipt" `elem` seen) `shouldBe` False)
    recoverRecordedProbeWith
      operation
      namespace
      uid
      (pure True)
      failed
      attempt
      (\_ _ -> pure ProbeRefused)
      receipt
      `shouldReturn` ProbeRecoveryFailureRecordRefused 1 ProbeRefused
    ownership <- newIORef True
    let changing arguments input = do
          result <- execute arguments input
          case arguments of
            ["get", "namespace", name, "-o", _] | name == namespace -> writeIORef ownership False
            _ -> pure ()
          pure result
    writeIORef events []
    recoverRecordedProbeWith
      operation
      namespace
      uid
      (readIORef ownership)
      changing
      attempt
      failure
      receipt
      `shouldReturn` ProbeRecoveryAttemptRefused ProbeRefused
    readIORef events >>= (\seen -> any (isInfixOf "delete") seen `shouldBe` False)
    writeIORef events []
    recoverRecordedProbeWith operation namespace uid (pure True) execute attempt failure receipt
      `shouldReturn` ProbeRecoveryCompleted
    captured <- readIORef body
    Aeson.decodeStrict' captured
      `shouldBe` Just
        ( Aeson.object
            [ "apiVersion" .= ("v1" :: String)
            , "kind" .= ("DeleteOptions" :: String)
            , "preconditions" .= Aeson.object ["uid" .= uid]
            ]
        )
    seen <- readIORef events
    take 2 seen
      `shouldBe` ["get namespace " ++ namespace ++ " -o jsonpath={.metadata.uid}", "record attempt"]
    last seen `shouldBe` "record receipt"
  it "deletes only the created namespace UID after a failed probe" $ do
    calls <- newIORef ([] :: [([String], BS.ByteString)])
    let uid = "12345678-1234-1234-1234-123456789abc"
        execute arguments input = do
          modifyIORef' calls (++ [(arguments, input)])
          pure $ case arguments of
            "create" : _ -> Right (0, uid)
            "delete" : "--raw" : _ -> Right (0, "{}")
            "wait" : "--for=delete" : _ -> Right (0, "deleted")
            ["get", "namespace", "kube-system", "-o", "jsonpath={.metadata.uid}"] -> Right (0, uid)
            ["get", "namespaces", "--field-selector", _, "-o", "json"] -> Right (0, "{\"apiVersion\":\"v1\",\"kind\":\"NamespaceList\",\"items\":[]}")
            _ -> Left "nodes unavailable"
    result <- observeNetworkEnforcementWith execute (const (pure ())) "prodbox-test-probe"
    enforcementCleanup result `shouldBe` EnforcementCleanupConfirmed
    observed <- readIORef calls
    let bodies = [body | ("delete" : "--raw" : _, body) <- observed]
        expected =
          Aeson.object
            [ "apiVersion" .= ("v1" :: String)
            , "kind" .= ("DeleteOptions" :: String)
            , "preconditions" .= Aeson.object ["uid" .= uid]
            ]
    map Aeson.decodeStrict' bodies `shouldBe` [Just expected]
  it "does not confirm probe cleanup from delete and wait replies alone" $ do
    let uid = "12345678-1234-1234-1234-123456789abc"
        namespace = "prodbox-test-probe"
        runWith inventory control = do
          recorded <- newIORef False
          let execute arguments _ = pure $ case arguments of
                "create" : _ -> Right (0, uid)
                "delete" : "--raw" : _ -> Right (0, "{}")
                "wait" : "--for=delete" : _ -> Right (0, "deleted")
                ["get", "namespace", "kube-system", "-o", "jsonpath={.metadata.uid}"] -> control
                ["get", "namespaces", "--field-selector", _, "-o", "json"] -> Right (0, inventory)
                _ -> Left "nodes unavailable"
          result <-
            observeNetworkEnforcementRecorded
              execute
              (const (pure ()))
              (pure True)
              (const (pure True))
              (\_ -> writeIORef recorded True >> pure True)
              namespace
          removed <- readIORef recorded
          pure (enforcementCleanup result, removed)
    let empty = "{\"apiVersion\":\"v1\",\"kind\":\"NamespaceList\",\"items\":[]}"
        present = "{\"apiVersion\":\"v1\",\"kind\":\"NamespaceList\",\"items\":[{}]}"
        unknown = EnforcementCleanupUnconfirmed "namespace absence unconfirmed after removal reply"
    runWith empty (Left "API unavailable") `shouldReturn` (unknown, False)
    runWith present (Right (0, uid)) `shouldReturn` (unknown, False)
    runWith "{}" (Right (0, uid)) `shouldReturn` (unknown, False)
  it "does not apply probe resources after the namespace UID changes" $ do
    calls <- newIORef ([] :: [[String]])
    let uid = "12345678-1234-1234-1234-123456789abc"
        foreignUid = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        execute arguments _ = do
          modifyIORef' calls (++ [arguments])
          pure $ case arguments of
            "create" : _ -> Right (0, uid)
            "get" : "namespace" : _ -> Right (0, foreignUid)
            "delete" : "--raw" : _ -> Right (1, "precondition conflict")
            _ -> Right (0, "ok")
    result <- observeNetworkEnforcementWith execute (const (pure ())) "prodbox-test-probe"
    observed <- readIORef calls
    let didApply arguments = case arguments of
          "apply" : _ -> True
          _ -> False
    assertMutationInvariant "network.rejects_replaced_namespace" (not (any didApply observed))
    enforcementObservation result `shouldBe` Nothing
  it "does not turn an unavailable connection observation into a network denial" $ do
    let uid = "12345678-1234-1234-1234-123456789abc"
        execute arguments _ = pure $ case arguments of
          "create" : _ -> Right (0, uid)
          "get" : "namespace" : _ -> Right (0, uid)
          "-n" : _ : "get" : "pod" : _ -> Right (0, "10.2.3.4")
          "-n" : _ : "logs" : "pol-other" : _ -> Right (0, "")
          "-n" : _ : "logs" : _ -> Right (0, "CONNECTED")
          _ -> Right (0, "ok")
    result <- observeNetworkEnforcementWith execute (const (pure ())) "prodbox-test-probe"
    enforcementObservation result `shouldBe` Nothing
    enforcementFailure result `shouldBe` Just "policy or restored connection observation unavailable"
  it "waits for both exact probe clients before reading connection logs" $ do
    let uid = "12345678-1234-1234-1234-123456789abc"
        namespace = "prodbox-test-probe"
        empty = "{\"apiVersion\":\"v1\",\"kind\":\"NamespaceList\",\"items\":[]}"
        runProbe canFinish = do
          finished <- newIORef ([] :: [String])
          logReads <- newIORef ([] :: [String])
          let execute arguments _ = case arguments of
                "create" : _ -> pure (Right (0, uid))
                "get" : "namespace" : _ -> pure (Right (0, uid))
                ["get", "namespaces", "--field-selector", _, "-o", "json"] -> pure (Right (0, empty))
                "-n" : _ : "get" : "pod" : _ -> pure (Right (0, "10.2.3.4"))
                ["-n", name, "wait", "--for=jsonpath={.status.phase}=Succeeded", first, second, "--timeout=30s"]
                  | name == namespace && canFinish -> do
                      modifyIORef' finished (++ [first, second])
                      pure (Right (0, "completed"))
                  | otherwise -> pure (Right (1, "client still pending"))
                ["-n", name, "logs", pod] | name == namespace -> do
                  modifyIORef' logReads (++ [pod])
                  complete <- elem ("pod/" ++ pod) <$> readIORef finished
                  pure $
                    if not complete
                      then Right (1, "client still pending")
                      else Right (0, if pod == "pol-other" then "REFUSED" else "CONNECTED")
                _ -> pure (Right (0, "ok"))
          result <- observeNetworkEnforcementWith execute (const (pure ())) namespace
          logs <- readIORef logReads
          pure (result, logs)
    (completed, logs) <- runProbe True
    enforcementComplete completed `shouldBe` True
    logs
      `shouldBe` ["base-allowed", "base-other", "pol-allowed", "pol-other", "off-allowed", "off-other"]
    (pending, unavailableLogs) <- runProbe False
    enforcementObservation pending `shouldBe` Nothing
    enforcementCleanup pending `shouldBe` EnforcementCleanupConfirmed
    unavailableLogs `shouldBe` []
  it "records an exclusive scoped controller submission before an effect" $
    withFixture $ \parent _ _ _ _ -> do
      let root = takeDirectory parent </> ".test-data" </> "fixture"
          path = root </> "kind-controller-submission-intent.json"
          operation = replicate 32 'd'
          request = replicate 64 'a'
          changedRequest = replicate 64 'b'
          job = "/org/freedesktop/systemd1/job/42"
          jobPath = root </> "kind-controller-submission-job.json"
          domainPath = root </> "kind-controller-manager-domain.json"
          providerPath = root </> "kind-controller-provider-binding.json"
          providerBytes =
            "prodbox-native-provider-binding/v1\NUL"
              <> BL.toStrict (serialise (FixtureProviderWire 1 (BS.replicate 32 1) 1234 5678 1000 2 3))
          providerDigest = Text.unpack (Text.drop 7 (digest providerBytes))
          materialPath = root </> "kind-controller-provider-material.json"
          senderPath = root </> "kind-controller-sender.json"
          selected = takeDirectory parent </> "isolated-status.dhall"
      projection <- readBootstrapProjection selected >>= either (fail . show) pure
      binding <- either (fail . show) pure (decodeProviderBinding providerBytes)
      sender <- maybe (fail "test sender invalid") pure (hostBusUniqueName ":1.77")
      let manager =
            hostManagerDomain "12345678-1234-1234-1234-123456789abc" (replicate 32 'a') ":1.42" 1000 1234 5678
          otherManager =
            hostManagerDomain "12345678-1234-1234-1234-123456789abc" (replicate 32 'a') ":1.42" 1000 1235 5678
          executionWindow = hostExecutionWindow 50 10 20 30 40
      domain <- maybe (fail "test manager domain invalid") pure manager
      otherDomain <- maybe (fail "test alternate manager domain invalid") pure otherManager
      window <- maybe (fail "test controller window invalid") pure executionWindow
      recordKindIntent projection operation >>= (`shouldBe` KindIntentRecorded)
      outcome <- withRecoveredKindOperation projection operation $ \stable -> do
        observeControllerSubmissionIntent projection operation request stable
          >>= (`shouldBe` ControllerSubmissionMissing)
        recordControllerSubmissionIntent projection (replicate 32 'e') request stable
          >>= (`shouldBe` ControllerSubmissionRefused)
        observeControllerSubmissionIntent projection operation request stable
          >>= (`shouldBe` ControllerSubmissionMissing)
        calls <- newIORef (0 :: Int)
        submitted <-
          withControllerSubmissionIntent projection operation request stable (modifyIORef' calls (+ 1))
        submitted `shouldBe` Right ()
        observeControllerSubmissionIntent projection operation request stable
          >>= (`shouldBe` ControllerSubmissionMatches)
        observeRetainedControllerSubmission projection operation stable
          >>= (`shouldBe` RetainedControllerSubmissionObserved request)
        again <-
          withControllerSubmissionIntent projection operation request stable (modifyIORef' calls (+ 1))
        again `shouldBe` Left ControllerSubmissionAlreadyExists
        readIORef calls >>= (`shouldBe` 1)
        observeControllerSubmissionIntent projection operation changedRequest stable
          >>= (`shouldBe` ControllerSubmissionConflict)
        recordControllerDomain projection operation changedRequest domain window stable
          >>= (`shouldBe` ControllerDomainRefused)
        observeControllerDomain projection operation request domain window stable
          >>= (`shouldBe` ControllerDomainMissing)
        recordControllerDomain projection operation request domain window stable
          >>= (`shouldBe` ControllerDomainRecorded)
        observeControllerDomain projection operation request domain window stable
          >>= (`shouldBe` ControllerDomainMatches)
        observeRetainedControllerDomain projection operation request stable
          >>= (`shouldBe` RetainedControllerDomainObserved domain window)
        observeControllerDomain projection operation request otherDomain window stable
          >>= (`shouldBe` ControllerDomainConflict)
        recordControllerDomain projection operation request domain window stable
          >>= (`shouldBe` ControllerDomainAlreadyExists)
        setFileMode domainPath 0o644
        observeControllerDomain projection operation request domain window stable
          >>= (`shouldBe` ControllerDomainUnobservable)
        setFileMode domainPath 0o600
        recordControllerProvider projection operation changedRequest providerDigest stable
          >>= (`shouldBe` ControllerProviderRefused)
        observeRetainedControllerProvider projection operation request stable
          >>= (`shouldBe` RetainedControllerProviderMissing)
        recordControllerProvider projection operation request providerDigest stable
          >>= (`shouldBe` ControllerProviderRecorded)
        observeRetainedControllerProvider projection operation request stable
          >>= (`shouldBe` RetainedControllerProviderObserved providerDigest)
        recordControllerProvider projection operation request providerDigest stable
          >>= (`shouldBe` ControllerProviderAlreadyExists)
        observeControllerProviderMaterial projection operation request stable
          >>= (`shouldBe` RetainedControllerProviderMaterialMissing)
        recordControllerProviderMaterial projection operation request binding stable
          >>= (`shouldBe` ControllerProviderMaterialRecorded)
        observeControllerProviderMaterial projection operation request stable
          >>= (`shouldBe` RetainedControllerProviderMaterialObserved binding)
        recordControllerProviderMaterial projection operation request binding stable
          >>= (`shouldBe` ControllerProviderMaterialAlreadyExists)
        setFileMode materialPath 0o644
        observeControllerProviderMaterial projection operation request stable
          >>= (`shouldBe` RetainedControllerProviderMaterialUnobservable)
        setFileMode materialPath 0o600
        recordControllerSender projection operation changedRequest sender stable
          >>= (`shouldBe` ControllerSenderRefused)
        observeRetainedControllerSender projection operation request stable
          >>= (`shouldBe` RetainedControllerSenderMissing)
        recordControllerSender projection operation request sender stable
          >>= (`shouldBe` ControllerSenderRecorded)
        observeRetainedControllerSender projection operation request stable
          >>= (`shouldBe` RetainedControllerSenderObserved sender)
        recordControllerSender projection operation request sender stable
          >>= (`shouldBe` ControllerSenderAlreadyExists)
        setFileMode senderPath 0o644
        observeRetainedControllerSender projection operation request stable
          >>= (`shouldBe` RetainedControllerSenderUnobservable)
        setFileMode senderPath 0o600
        setFileMode providerPath 0o644
        observeRetainedControllerProvider projection operation request stable
          >>= (`shouldBe` RetainedControllerProviderUnobservable)
        setFileMode providerPath 0o600
        recordControllerSubmissionIntent projection operation request stable
          >>= (`shouldBe` ControllerSubmissionAlreadyExists)
        recordControllerJob projection operation changedRequest job stable
          >>= (`shouldBe` ControllerJobRefused)
        recordControllerJob projection operation request "/org/freedesktop/systemd1/job/042" stable
          >>= (`shouldBe` ControllerJobRefused)
        observeControllerJob projection operation request job stable >>= (`shouldBe` ControllerJobMissing)
        recordControllerJob projection operation request job stable >>= (`shouldBe` ControllerJobRecorded)
        observeControllerJob projection operation request job stable >>= (`shouldBe` ControllerJobMatches)
        observeRetainedControllerJob projection operation request stable
          >>= (`shouldBe` RetainedControllerJobObserved job)
        observeControllerJob projection operation request "/org/freedesktop/systemd1/job/43" stable
          >>= (`shouldBe` ControllerJobConflict)
        recordControllerJob projection operation request job stable
          >>= (`shouldBe` ControllerJobAlreadyExists)
        setFileMode jobPath 0o644
        observeControllerJob projection operation request job stable
          >>= (`shouldBe` ControllerJobUnobservable)
        setFileMode jobPath 0o600
        setFileMode path 0o644
        observeControllerSubmissionIntent projection operation request stable
          >>= (`shouldBe` ControllerSubmissionUnobservable)
        setFileMode path 0o600
        BS.writeFile path "{}"
        observeControllerSubmissionIntent projection operation request stable
          >>= (`shouldBe` ControllerSubmissionConflict)
      outcome `shouldBe` KindOperationCallbackReturned ()
      status <- observeControllerSubmissionStatus projection
      ("RetainedControllerSubmissionConflict" `isInfixOf` status) `shouldBe` True
      ("worker settlement not observed" `isInfixOf` status) `shouldBe` True
      public <-
        captureSubprocessWithInputBounded
          (BoundedSubprocessLimits 1 65536 65536 30000000)
          BS.empty
          ( Subprocess
              "./.build/prodbox"
              ["--config", selected, "control", "status"]
              (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")])
              Nothing
          )
      case public of
        Right result -> do
          let output = processStdout result ++ processStderr result
          if "RetainedControllerSubmissionConflict" `isInfixOf` output
            && "worker settlement not observed" `isInfixOf` output
            then pure ()
            else fail ("public status omitted retained submission detail: " ++ output)
        Left failure -> fail (show failure)
  it "compares provider bindings and refuses another boot before contacting a manager" $
    withFixture $ \_ projection _ _ _ -> do
      let operation = replicate 32 'd'
          request = replicate 64 'a'
          wire n =
            "prodbox-native-provider-binding/v1\NUL"
              <> BL.toStrict (serialise (FixtureProviderWire 1 (BS.replicate 32 n) 1234 5678 1000 2 3))
      bootText <- BS8.unpack <$> BS.readFile "/proc/sys/kernel/random/boot_id"
      let otherBoot = (if take 1 bootText == "a" then "b" else "a") ++ take 35 (drop 1 bootText)
      binding <- either (fail . show) pure (decodeProviderBinding (wire 1))
      sender <- maybe (fail "sender invalid") pure (hostBusUniqueName ":1.77")
      otherBinding <- either (fail . show) pure (decodeProviderBinding (wire 2))
      domain <-
        maybe
          (fail "domain invalid")
          pure
          (hostManagerDomain otherBoot (replicate 32 'a') ":1.42" 1000 1234 5678)
      otherDomain <-
        maybe
          (fail "alternate domain invalid")
          pure
          (hostManagerDomain otherBoot (replicate 32 'a') ":1.42" 1000 1235 5678)
      window <- maybe (fail "window invalid") pure (hostExecutionWindow 50 10 20 30 40)
      compareControllerProviderBinding domain binding domain binding `shouldBe` True
      compareControllerProviderBinding domain binding otherDomain binding `shouldBe` False
      compareControllerProviderBinding domain binding domain otherBinding `shouldBe` False
      recordKindIntent projection operation >>= (`shouldBe` KindIntentRecorded)
      recorded <- withRecoveredKindOperation projection operation $ \stable -> do
        recordControllerSubmissionIntent projection operation request stable
          >>= (`shouldBe` ControllerSubmissionRecorded)
        recordControllerDomain projection operation request domain window stable
          >>= (`shouldBe` ControllerDomainRecorded)
        recordControllerProvider
          projection
          operation
          request
          (Text.unpack (Text.drop 7 (digest (wire 1))))
          stable
          >>= (`shouldBe` ControllerProviderRecorded)
        recordControllerProviderMaterial projection operation request binding stable
          >>= (`shouldBe` ControllerProviderMaterialRecorded)
        recordControllerSender projection operation request sender stable
          >>= (`shouldBe` ControllerSenderRecorded)
      recorded `shouldBe` KindOperationCallbackReturned ()
      observeControllerFreshProvider projection >>= (`shouldBe` ControllerFreshProviderDifferentDomain)
      observeControllerFreshSender projection >>= (`shouldBe` ControllerFreshSenderDifferentDomain)
      observeControllerManagerRead projection >>= (`shouldBe` ControllerManagerDifferentDomain)
  it "binds a controller worker receipt to the retained operation and refuses changes" $
    withFixture $ \parent projection _ _ _ -> do
      let root = takeDirectory parent </> ".test-data" </> "fixture"
          receipt = root </> "kind-controller-worker-result.json"
          operation = replicate 32 'd'
          identifier = replicate 64 'a'
      recordKindIntent projection operation >>= (`shouldBe` KindIntentRecorded)
      outcome <- withRecoveredKindOperation projection operation $ \stable -> do
        observeControllerReceipt projection operation stable >>= (`shouldBe` ControllerReceiptMissing)
        recordControllerReceipt projection (replicate 32 'e') identifier stable
          >>= (`shouldBe` ControllerReceiptRefused)
        observeControllerReceipt projection operation stable >>= (`shouldBe` ControllerReceiptMissing)
        recordControllerReceipt projection operation identifier stable
          >>= (`shouldBe` ControllerReceiptRecorded)
        observeControllerReceipt projection operation stable
          >>= (`shouldBe` ControllerReceiptObserved identifier)
        recordControllerReceipt projection operation identifier stable
          >>= (`shouldBe` ControllerReceiptAlreadyExists)
        foreignReceipt <- observeControllerReceipt projection (replicate 32 'e') stable
        assertMutationInvariant
          "controller.rejects_foreign_receipt"
          (foreignReceipt == ControllerReceiptConflict)
        setFileMode receipt 0o644
        observeControllerReceipt projection operation stable >>= (`shouldBe` ControllerReceiptUnobservable)
        setFileMode receipt 0o600
        BS.writeFile receipt "{}"
        observeControllerReceipt projection operation stable >>= (`shouldBe` ControllerReceiptInvalid)
      case outcome of
        KindOperationCallbackReturned () -> pure ()
        other -> fail (show other)
  it "refuses orphaned or invalid recreation records without touching them" $
    withFixture $ \parent projection _ _ _ -> do
      let root = takeDirectory parent </> ".test-data" </> "fixture"
          attempt = root </> "kind-node-create-attempt.json"
          intent = root </> "kind-intent.json"
          refused outcome = case outcome of
            ArchiveFailed _ -> True
            _ -> False
      archiveCompletedOperation projection >>= (`shouldBe` ArchiveNothingRecorded)
      BS.writeFile attempt "orphan"
      setFileMode attempt 0o600
      archiveCompletedOperation projection >>= (\outcome -> refused outcome `shouldBe` True)
      BS.readFile attempt >>= (`shouldBe` "orphan")
      removeFile attempt
      BS.writeFile intent "invalid"
      setFileMode intent 0o600
      archiveCompletedOperation projection >>= (\outcome -> refused outcome `shouldBe` True)
      BS.readFile intent >>= (`shouldBe` "invalid")
  it "refuses removal and archival when controller retirement is unconfirmed" $
    withFixture $ \parent projection _ _ _ -> do
      let root = takeDirectory parent </> ".test-data" </> "fixture"
          intent = root </> "kind-intent.json"
          operation = replicate 32 'd'
      recordKindIntent projection operation >>= (`shouldBe` KindIntentRecorded)
      before <- BS.readFile intent
      steps <- deleteNewTestIdentity projection
      case steps of
        [DeleteStep "controller settlement" False reason] ->
          "physical retirement are unconfirmed" `isInfixOf` reason `shouldBe` True
        other -> fail (show other)
      archived <- archiveCompletedOperation projection
      case archived of
        ArchiveFailed reason -> "physical retirement are unconfirmed" `isInfixOf` reason `shouldBe` True
        other -> fail (show other)
      BS.readFile intent >>= (`shouldBe` before)
  it "requires the exact family retirement before removing family resources" $
    withFixture $ \parent projection _ _ _ -> do
      let intent = takeDirectory parent </> ".test-data" </> "fixture" </> "kind-intent.json"
          operation = replicate 32 'd'
      recordKindFamilyIntent projection operation `shouldReturn` KindIntentRecorded
      before <- BS.readFile intent
      steps <- deleteNewTestIdentity projection
      case steps of
        [DeleteStep "family settlement" False reason] ->
          "KindFamilyRecoveryRequestMissing" `isInfixOf` reason `shouldBe` True
        other -> fail (show other)
      let selected = takeDirectory parent </> "family-reconcile.dhall"
      rendered <-
        maybe (fail "family projection could not be rendered") pure (renderBootstrapProjection projection)
      TextIO.writeFile selected rendered
      public <-
        captureSubprocessWithInputBounded
          (BoundedSubprocessLimits 1 65536 65536 30000000)
          BS.empty
          ( Subprocess
              "./.build/prodbox"
              ["--config", selected, "control", "reconcile"]
              (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")])
              Nothing
          )
      case public of
        Right output -> do
          processExitCode output `shouldBe` ExitFailure 1
          ("KindFamilyRecoveryRequestMissing" `isInfixOf` (processStdout output ++ processStderr output))
            `shouldBe` True
        Left failure -> fail (show failure)
      BS.readFile intent `shouldReturn` before
  it "refuses an orphan network attempt even after an unlaunched owner is fenced" $
    withFixture $ \parent projection _ _ _ -> do
      let operation = replicate 32 'd'
          selected = takeDirectory parent </> "network-orphan.dhall"
          attempt = scopeRoot (bootstrapScope projection) </> "kind-network-attempt.json"
      withNewKindOwnerFamilyOperation projection operation (const (pure ()))
        `shouldReturn` KindOperationCallbackReturned ()
      BS.writeFile attempt "orphan"
      rendered <-
        maybe (fail "projection could not be rendered") pure (renderBootstrapProjection projection)
      TextIO.writeFile selected rendered
      public <-
        captureSubprocessWithInputBounded
          (BoundedSubprocessLimits 1 65536 65536 30000000)
          BS.empty
          ( Subprocess
              "./.build/prodbox"
              ["--config", selected, "control", "delete", "--yes"]
              (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")])
              Nothing
          )
      case public of
        Right output -> do
          processExitCode output `shouldBe` ExitFailure 1
          ("network: NOT completed" `isInfixOf` (processStdout output ++ processStderr output))
            `shouldBe` True
          BS.readFile attempt `shouldReturn` "orphan"
        Left failure -> fail (show failure)
  it "does not accept missing, failed or unobservable prior removal receipts" $ do
    probeCleanupRecorded (ProbeJournalRemovalRecorded "12345678-1234-1234-1234-123456789abc")
      `shouldBe` True
    probeCleanupPermitsNodeRemoval
      (ProbeJournalRemovalRecorded "12345678-1234-1234-1234-123456789abc")
      ProbeRecoveryLaunchMissing
      `shouldBe` True
    probeCleanupPermitsNodeRemoval
      (ProbeJournalRemovalRecorded "12345678-1234-1234-1234-123456789abc")
      ProbeRecoveryLaunchUnobservable
      `shouldBe` False
    probeCleanupPermitsNodeRemoval
      (ProbeJournalRemovalRecorded "12345678-1234-1234-1234-123456789abc")
      ProbeRecoveryLaunchConflict
      `shouldBe` False
    mapM_
      (\observation -> probeCleanupRecorded observation `shouldBe` False)
      [ ProbeJournalEmpty
      , ProbeJournalUidUnconfirmed
      , ProbeJournalRemovalMissing "uid"
      , ProbeJournalRemovalAttempted "uid" "recovery"
      , ProbeJournalConflict
      ]
    priorVolumeRemovalRecorded (NodeVolumeRemovalReceiptObserved (DockerNodeVarRemoveReply 204))
      `shouldBe` True
    priorVolumeRemovalRecorded (NodeVolumeRemovalReceiptObserved (DockerNodeVarRemoveReply 409))
      `shouldBe` False
    priorVolumeRemovalRecorded NodeVolumeRemovalReceiptMissing `shouldBe` False
    priorVolumeRemovalRecorded NodeVolumeRemovalReceiptUnobservable `shouldBe` False
    priorNetworkRemovalRecorded
      (NetworkReceiptObserved (NetworkRemovalTransport (DockerNetworkRemoveReply 204)))
      `shouldBe` True
    priorNetworkRemovalRecorded
      (NetworkReceiptObserved (NetworkRemovalTransport (DockerNetworkRemoveReply 500)))
      `shouldBe` False
    priorNetworkRemovalRecorded NetworkReceiptUnobservable `shouldBe` False
    assertMutationInvariant
      "delete.rejects_unbound_receipt"
      ( not (priorVolumeRemovalRecorded NodeVolumeRemovalReceiptUnobservable)
          && not (priorNetworkRemovalRecorded NetworkReceiptInvalid)
      )
  it "requires independent node absence after a successful removal receipt" $ do
    let identifier = replicate 64 'a'
        present = NodeRemovalReadbackSampled (NodeRemovalInventory True [identifier] [identifier])
        empty = NodeRemovalReadbackSampled (NodeRemovalInventory False [] [])
    remained <- confirmRecordedRemovalReadback present (pure True)
    assertMutationInvariant "delete.requires_independent_removal" (not remained)
    confirmRecordedRemovalReadback NodeRemovalReadbackUnobservable (pure True) `shouldReturn` False
    confirmRecordedRemovalReadback empty (pure False) `shouldReturn` False
    confirmRecordedRemovalReadback empty (pure True) `shouldReturn` True
  it "only removes the exact created, stopped and isolated absence control" $ do
    let identifier = replicate 64 'a'
        name = "selected-absence-control"
        operation = replicate 32 'b'
        inspect = Just (unwords [identifier, '/' : name, operation, "false", "none"])
        listed = Just identifier
    controlContainerId (Just (identifier ++ "\n")) `shouldBe` Just identifier
    controlContainerId (Just (identifier ++ " extra")) `shouldBe` Nothing
    controlContainerId (Just "malformed") `shouldBe` Nothing
    controlContainerMatches identifier name operation inspect listed `shouldBe` True
    controlContainerMatches identifier name operation inspect Nothing `shouldBe` False
    controlContainerMatches
      identifier
      name
      operation
      (Just (unwords [identifier, '/' : name, operation, "true", "none"]))
      listed
      `shouldBe` False
    controlContainerMatches
      identifier
      name
      operation
      (Just (unwords [identifier, '/' : name, operation, "false", "bridge"]))
      listed
      `shouldBe` False
    assertMutationInvariant
      "delete.rejects_foreign_control"
      ( not
          ( controlContainerMatches
              identifier
              name
              operation
              (Just (unwords [identifier, "/foreign", operation, "false", "none"]))
              listed
          )
      )
  it "accepts only successful removal replies with recorded receipts" $ do
    let node status receipt = nodeRemovalRecorded (NodeRemoveActionReturned status receipt)
        volume status receipt = volumeRemovalRecorded (NodeVolumeRemovalActionReturned status receipt)
        network status receipt =
          networkRemovalRecorded
            (KindNetworkRemovalReturned (KindNetworkRecordedTransport (NetworkRemovalTransport status) receipt))
    assertMutationInvariant
      "delete.rejects_failed_removal"
      ( not (node (DockerNodeContainerRemoveReply 500) NodeRemoveResultRecorded)
          && not (volume DockerNodeVarRemoveUnconfirmed NodeVolumeRemovalReceiptRecorded)
          && not (network (DockerNetworkRemoveReply 204) NetworkReceiptIncomplete)
      )
    node (DockerNodeContainerRemoveReply 204) NodeRemoveResultRecorded `shouldBe` True
    node (DockerNodeContainerRemoveReply 500) NodeRemoveResultRecorded `shouldBe` False
    node DockerNodeContainerRemoveUnconfirmed NodeRemoveResultRecorded `shouldBe` False
    node (DockerNodeContainerRemoveReply 204) NodeRemoveResultIncomplete `shouldBe` False
    volume (DockerNodeVarRemoveReply 204) NodeVolumeRemovalReceiptRecorded `shouldBe` True
    volume (DockerNodeVarRemoveReply 409) NodeVolumeRemovalReceiptRecorded `shouldBe` False
    volume DockerNodeVarRemoveUnconfirmed NodeVolumeRemovalReceiptRecorded `shouldBe` False
    volume (DockerNodeVarRemoveReply 204) NodeVolumeRemovalReceiptIncomplete `shouldBe` False
    network (DockerNetworkRemoveReply 204) NetworkReceiptRecorded `shouldBe` True
    network (DockerNetworkRemoveReply 500) NetworkReceiptRecorded `shouldBe` False
    network DockerNetworkRemoveUnconfirmed NetworkReceiptRecorded `shouldBe` False
    network (DockerNetworkRemoveReply 204) NetworkReceiptIncomplete `shouldBe` False
  it "distinguishes missing recreation records from unsafe entries" $
    withSystemTempDirectory "prodbox-archive-record" $ \directory -> do
      let flags = Posix.defaultFileFlags {Posix.directory = True, Posix.nofollow = True}
      bracket (Posix.openFd directory Posix.ReadOnly flags) Posix.closeFd $ \root -> do
        probeArchiveRecord root "result" >>= (`shouldBe` Just False)
        BS.writeFile (directory </> "result") "record"
        setFileMode (directory </> "result") 0o600
        probeArchiveRecord root "result" >>= (`shouldBe` Just True)
        setFileMode (directory </> "result") 0o666
        probeArchiveRecord root "result" >>= (`shouldBe` Nothing)
        createSymbolicLink (directory </> "result") (directory </> "link")
        probeArchiveRecord root "link" >>= (`shouldBe` Nothing)
        probeArchiveRecord root "../outside" >>= (`shouldBe` Nothing)
  it "does not treat an invalid or unreadable recreation intent as absent" $ do
    assertMutationInvariant
      "recreate.rejects_unknown_intent"
      (classifyArchiveIntent KindIntentObservationUnobservable == ArchiveIntentUnconfirmed)
    classifyArchiveIntent KindIntentMissing `shouldBe` ArchiveNoIntent
    classifyArchiveIntent (KindIntentMatches (replicate 32 'a'))
      `shouldBe` ArchiveKnownIntent (replicate 32 'a')
    classifyArchiveIntent KindIntentInvalid `shouldBe` ArchiveIntentUnconfirmed
    classifyArchiveIntent KindIntentConflict `shouldBe` ArchiveIntentUnconfirmed
    classifyArchiveIntent KindIntentGenerationUnavailable `shouldBe` ArchiveIntentUnconfirmed
    classifyArchiveIntent KindIntentObservationUnobservable `shouldBe` ArchiveIntentUnconfirmed
  it "never infers that a node was unstarted from a missing or invalid result alone" $ do
    assertMutationInvariant
      "delete.rejects_unconfirmed_node"
      ( not (nodeNeverStarted NodeCreateResultMissing (Just True))
          && not (nodeNeverStarted NodeCreateResultMissing Nothing)
          && not (nodeNeverStarted NodeCreateResultInvalid (Just False))
      )
    nodeNeverStarted NodeCreateResultMissing (Just False) `shouldBe` True
    nodeNeverStarted NodeCreateResultMissing (Just True) `shouldBe` False
    nodeNeverStarted NodeCreateResultMissing Nothing `shouldBe` False
    nodeNeverStarted NodeCreateResultInvalid (Just False) `shouldBe` False
    nodeNeverStarted NodeCreateResultUnobservable (Just False) `shouldBe` False
  it "does not run follow-up work when controller settlement is unconfirmed" $ do
    calls <- newIORef (0 :: Int)
    let followup = modifyIORef' calls (+ 1) >> pure ("observed" :: String)
    afterControllerSettlement (Left "deadline") followup >>= (`shouldBe` Nothing)
    readIORef calls >>= (`shouldBe` 0)
    afterControllerSettlement (classifyControllerUnitAbsence True) followup >>= (`shouldBe` Nothing)
    afterControllerSettlement (classifyControllerUnitAbsence False) followup >>= (`shouldBe` Nothing)
    readIORef calls >>= (`shouldBe` 0)
    afterControllerSettlement (Right "independently confirmed settlement") followup
      >>= (`shouldBe` Just "observed")
    readIORef calls >>= (`shouldBe` 1)
  it "only recognizes a returned, bound worker with recorded create and start" $ do
    let identifier = replicate 64 'a'
        action =
          NodeRunStartObserved
            ( NodeCreateActionReturned
                (DockerNodeContainerCreateReply 201 (Just identifier))
                NodeCreateResultRecorded
            )
            (NodeStartActionReturned (DockerNodeContainerStartReply 204) NodeStartResultRecorded)
        worker exitCode = KindDockerWorkerReturned (Right (ProcessOutput exitCode "" ""))
        attempt broker exitCode marker = ConfinedNodeObserved broker (worker exitCode) (Just action) marker
        bound stable outcome =
          ConfinedNodeConnected
            ( DockerPeerCompleted
                ( DockerConnectedInfoCompleted
                    ( ConfinedNodeBindingObserved
                        ( ConfinedKindSnapshotsAttempted
                            (ConfinedSnapshotsReady (KindOperationCallbackReturned (KindDockerEndpointObserved outcome)))
                            stable
                        )
                    )
                )
            )
        good = attempt KindDockerBrokerCancelled ExitSuccess KindDockerMarkerClear
    confirmedKindWorkerNode (InspectedArchiveCompleted (bound True good)) `shouldBe` Just identifier
    confirmedKindWorkerNode (InspectedArchiveCompleted (bound False good)) `shouldBe` Nothing
    confirmedKindWorkerNode (InspectedArchiveChanged (bound True good)) `shouldBe` Nothing
    confirmedKindWorkerNode
      ( InspectedArchiveCompleted
          (bound True (attempt KindDockerBrokerCancelled (ExitFailure 1) KindDockerMarkerClear))
      )
      `shouldBe` Nothing
    confirmedKindWorkerNode
      ( InspectedArchiveCompleted
          (bound True (attempt KindDockerBrokerCancelled ExitSuccess KindDockerMarkerRetained))
      )
      `shouldBe` Nothing
    confirmedKindWorkerNode
      ( InspectedArchiveCompleted
          ( bound
              True
              (attempt (KindDockerBrokerReturned KindDockerEndpointRefused) ExitSuccess KindDockerMarkerClear)
          )
      )
      `shouldBe` Nothing
  it "rejects unexpected entries in the retained fixture directory" $ do
    let expected = ["a01-03-siblingproject", "a01-03-sibling", "a01-03-nameproject", "a01-03-name"]
    fixtureBaseMatches expected `shouldBe` True
    fixtureBaseMatches ("unexpected" : expected) `shouldBe` False
    fixtureBaseMatches (drop 1 expected) `shouldBe` False
  it "requires observed controller absence before the deadline" $ do
    let advance times = case times of
          [] -> ([], 10)
          value : rest -> (rest, value)
        clockFrom values = do
          remaining <- newIORef values
          pure (atomicModifyIORef' remaining advance)
    onTime <- clockFrom [1, 2]
    waitForUnitAbsenceWith onTime (pure True) (pure ()) 10 >>= (`shouldBe` True)
    late <- clockFrom [1, 10]
    waitForUnitAbsenceWith late (pure True) (pure ()) 10 >>= (`shouldBe` False)
    expired <- clockFrom [10]
    waitForUnitAbsenceWith expired (pure True) (pure ()) 10 >>= (`shouldBe` False)
    unobservable <- clockFrom [1, 2, 10]
    waitForUnitAbsenceWith unobservable (pure False) (pure ()) 10 >>= (`shouldBe` False)
  it "confirms only the selected bare retained scope and rejects an operation record" $
    withFixture $ \parent projection _ _ _ -> do
      let root = takeDirectory parent </> ".test-data" </> "fixture"
          generation = replicate 32 'b'
      observeBareRetainedScope projection root generation >>= (`shouldBe` True)
      observeBareRetainedScope projection root (replicate 32 'c') >>= (`shouldBe` False)
      BS.writeFile (root </> "operation-record") "unexpected"
      observeBareRetainedScope projection root generation >>= (`shouldBe` False)
      removeFile (root </> "operation-record")
      createDirectory (takeDirectory root </> "unexpected-staging")
      observeBareRetainedScope projection root generation >>= (`shouldBe` False)
  it "removes only an unchanged captured fixture tree without following links" $
    withSystemTempDirectory "prodbox-fixture-cleanup" $ \parent -> do
      let directory = parent </> "fixture"
          victim = parent </> "victim"
      createDirectory directory
      setFileMode directory 0o700
      BS.writeFile (directory </> "owned") "fixture"
      setFileMode (directory </> "owned") 0o600
      BS.writeFile victim "untouched"
      createSymbolicLink victim (directory </> "link")
      snapshot <- captureFixtureTree directory
      result <- maybe (pure False) cleanupFixtureTree snapshot
      result `shouldBe` True
      doesDirectoryExist directory >>= (`shouldBe` False)
      BS.readFile victim >>= (`shouldBe` "untouched")
  it "retains an entire fixture when a new entry appears" $
    withSystemTempDirectory "prodbox-fixture-extra" $ \parent -> do
      let directory = parent </> "fixture"
      createDirectory directory
      setFileMode directory 0o700
      BS.writeFile (directory </> "owned") "fixture"
      setFileMode (directory </> "owned") 0o600
      snapshot <- captureFixtureTree directory
      BS.writeFile (directory </> "unexpected") "preserve"
      result <- maybe (pure True) cleanupFixtureTree snapshot
      result `shouldBe` False
      BS.readFile (directory </> "owned") >>= (`shouldBe` "fixture")
      BS.readFile (directory </> "unexpected") >>= (`shouldBe` "preserve")
  it "retains a replacement at a captured fixture name" $
    withSystemTempDirectory "prodbox-fixture-replaced" $ \parent -> do
      let directory = parent </> "fixture"
          owned = directory </> "owned"
      createDirectory directory
      setFileMode directory 0o700
      BS.writeFile owned "original"
      setFileMode owned 0o600
      snapshot <- captureFixtureTree directory
      renameFile owned (parent </> "original")
      BS.writeFile owned "replacement"
      setFileMode owned 0o600
      result <- maybe (pure True) cleanupFixtureTree snapshot
      result `shouldBe` False
      BS.readFile owned >>= (`shouldBe` "replacement")
  it "retains an entire nested fixture when a public command adds state" $
    withSystemTempDirectory "prodbox-fixture-nested" $ \parent -> do
      let directory = parent </> "fixture"
          nested = directory </> "scope"
      createDirectory directory
      setFileMode directory 0o700
      createDirectory nested
      setFileMode nested 0o700
      BS.writeFile (directory </> "owned") "fixture"
      setFileMode (directory </> "owned") 0o600
      snapshot <- captureFixtureTree directory
      BS.writeFile (nested </> "operation-record") "retain"
      result <- maybe (pure True) cleanupFixtureTree snapshot
      result `shouldBe` False
      BS.readFile (directory </> "owned") >>= (`shouldBe` "fixture")
      BS.readFile (nested </> "operation-record") >>= (`shouldBe` "retain")
  it "keeps the recovery configuration when another fixture changes" $
    withSystemTempDirectory "prodbox-fixture-batch" $ \parent -> do
      let configDirectory = parent </> "config"
          scope = parent </> "scope"
      createDirectory configDirectory
      createDirectory scope
      setFileMode configDirectory 0o700
      setFileMode scope 0o700
      BS.writeFile (configDirectory </> "selected.dhall") "recovery"
      setFileMode (configDirectory </> "selected.dhall") 0o600
      configSnapshot <- captureFixtureTree configDirectory
      scopeSnapshot <- captureFixtureTree scope
      BS.writeFile (scope </> "operation-record") "retain"
      result <- cleanupFixtureTrees [scopeSnapshot, configSnapshot]
      result `shouldBe` False
      BS.readFile (configDirectory </> "selected.dhall") >>= (`shouldBe` "recovery")
      BS.readFile (scope </> "operation-record") >>= (`shouldBe` "retain")
  it "drives adverse imports through the public binary without changing retained state" $
    withSystemTempDirectory "prodbox-adverse-import" $ \anchor -> do
      let selected = anchor </> ".test-data" </> "fixture" </> "config" </> "prodbox.dhall"
          nodePath = anchor </> "node-source"
          kindPath = anchor </> "kind-source"
          nodeBytes = "synthetic-node-artifact"
          kindBytes = "synthetic-kind-tool"
          nodeDigest = Text.unpack (digest nodeBytes)
          kindDigest = Text.unpack (digest kindBytes)
          imageDigest = "sha256:" ++ replicate 64 'a'
          setupInput =
            BS8.pack $
              unlines
                [ anchor
                , "/var/run/docker.sock"
                , "test"
                , "fixture"
                , replicate 32 'b'
                , "26443"
                , "kindest/node@" ++ imageDigest
                , "28080"
                , "30080"
                , "28443"
                , "30443"
                , "127.0.0.1"
                , "artifacts/node.tar"
                , nodeDigest
                , "4096"
                , "artifacts/kind"
                , kindDigest
                , "4096"
                ]
          execute args input =
            captureSubprocessWithInputBounded
              (BoundedSubprocessLimits 8192 65536 65536 30000000)
              input
              ( Subprocess
                  "./.build/prodbox"
                  (["--config", selected] ++ args)
                  (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")])
                  Nothing
              )
          expectSuccess action = do
            result <- action
            either (const Nothing) (Just . processExitCode) result `shouldBe` Just ExitSuccess
      BS.writeFile nodePath nodeBytes
      BS.writeFile kindPath kindBytes
      expectSuccess (execute ["config", "setup", "--fresh-test"] setupInput)
      expectSuccess (execute ["control", "import-artifact", "node-archive", nodePath] BS.empty)
      expectSuccess (execute ["control", "import-artifact", "kind-tool", kindPath] BS.empty)
      loaded <- readBootstrapProjection selected
      projection <- either (fail . show) pure loaded
      executable <- makeAbsolute ".build/prodbox"
      result <- runFreshImportAdversesWith executable selected projection
      result `shouldBe` Right (ImportAdverseEvidence [True, True, True] [True, True, True] True)

  it "binds Docker observations to the selected socket" $ do
    dockerArguments "/tmp/one.sock" ["image", "ls"]
      `shouldBe` ["--host", "unix:///tmp/one.sock", "image", "ls"]
    dockerArguments "/tmp/two.sock" ["network", "inspect", "target"]
      `shouldBe` ["--host", "unix:///tmp/two.sock", "network", "inspect", "target"]

  it "never authorizes fixture cleanup without the exact created and unchanged network" $ do
    let identifier = replicate 64 'a'
        created = Right (0, identifier ++ "\n", "")
        intact = Right (0, identifier ++ " 2026-01-01 {\"owner\":\"foreign-a01-03\"} 0\n", "")
        attached = Right (0, identifier ++ " 2026-01-01 {\"owner\":\"foreign-a01-03\"} 1\n", "")
        other = Right (0, replicate 64 'b' ++ " 2026-01-01 {\"owner\":\"foreign-a01-03\"} 0\n", "")
    fixtureNetworkId created `shouldBe` Just identifier
    fixtureNetworkId (Right (1, identifier, "failure")) `shouldBe` Nothing
    fixtureNetworkId (Right (0, "malformed", "")) `shouldBe` Nothing
    fixtureNetworkUntouched identifier intact intact `shouldBe` True
    fixtureNetworkUntouched identifier intact attached `shouldBe` False
    assertMutationInvariant
      "context.rejects_foreign_network"
      (not (fixtureNetworkUntouched identifier intact other))
    fixtureNetworkUntouched identifier (Left "unobservable") intact `shouldBe` False

  it "refuses missing or malformed boot identity instead of inventing one" $ do
    validateBootIdentity Nothing `shouldBe` Nothing
    validateBootIdentity (Just "not-a-boot-id\n") `shouldBe` Nothing
    validateBootIdentity (Just "01234567-89ab-cdef-0123-456789abcdef\n")
      `shouldBe` Just "01234567-89ab-cdef-0123-456789abcdef"
    validateBootIdentity (Just "01234567-89ab-cdef-0123-456789abcdef\nextra") `shouldBe` Nothing

  it "distinguishes absent, present, and unobservable image inventories" $ do
    observeFreshImageInventory (Right (0, "", "")) `shouldBe` FreshImageAbsent
    observeFreshImageInventory (Right (0, "sha256:" ++ replicate 64 'a', ""))
      `shouldBe` FreshImageAbsent
    observeFreshImageInventory
      (Right (0, "sha256:152b34afd8a2de5c8348a264426bc99b71058ee0e1a15eab9b30849605e4752d", ""))
      `shouldBe` FreshImagePresent
    observeFreshImageInventory (Right (0, "malformed", "")) `shouldBe` FreshImageUnobservable
    observeFreshImageInventory (Right (1, "", "unavailable")) `shouldBe` FreshImageUnobservable
    observeFreshImageInventory (Left "unobservable") `shouldBe` FreshImageUnobservable

  it "rejects unsupported default Phase 1 options before preparation" $ do
    let limits = BoundedSubprocessLimits 1 65536 65536 30000000
        command flag =
          Subprocess
            "./.build/prodbox"
            (["test", "run", "phase-01"] ++ flag)
            (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")])
            Nothing
        check flags expected = do
          result <- captureSubprocessWithInputBounded limits BS.empty (command flags)
          case result of
            Left failure -> fail (show failure)
            Right output -> do
              processExitCode output `shouldBe` ExitFailure 1
              (expected `isInfixOf` (processStdout output ++ processStderr output)) `shouldBe` True
    check ["--coverage"] "Coverage is not supported"
    check ["--substrate", "aws"] "does not select an AWS substrate"

  it "refuses missing or incomplete scenario entropy" $ do
    validateScenarioEntropy Nothing `shouldBe` Left "fresh random bytes were unavailable or incomplete"
    validateScenarioEntropy (Just (BS.replicate 15 1))
      `shouldBe` Left "fresh random bytes were unavailable or incomplete"
    validateScenarioEntropy (Just (BS.replicate 16 1)) `shouldBe` Right (BS.replicate 16 1)

  it "stages bounded adverse sources and cleans the exact fixtures" $
    withFixture $ \_ projection _ _ _ -> do
      result <- prepareAdverseImportSources projection "foreign-fixture" $ \altered missing foreignPath -> do
        BS.readFile altered >>= (`shouldBe` "prodbox-controlled-altered-artifact")
        doesFileExist missing >>= (`shouldBe` False)
        BS.readFile foreignPath >>= (`shouldBe` "foreign-fixture")
        pure ("observed" :: String)
      result `shouldBe` PreparationResult (Right "observed") True Nothing

  it "stages a fresh test scope without adopting an existing root" $
    withFixture $ \parent _ image source expected -> do
      manifestReads <- newIORef (0 :: Int)
      let counted =
            source
              { readRegistryManifest = \selected -> modifyIORef' manifestReads (+ 1) >> readRegistryManifest source selected
              }
      fresh <- either (fail . show) pure (deploymentScope (takeDirectory parent) Test "new-run" 26444)
      result <- prepareFreshNodeArchiveWith counted parent image fresh $ \path actual size -> do
        bytes <- BS.readFile path
        bytes `shouldBe` expected
        actual `shouldBe` digest bytes
        size `shouldBe` fromIntegral (BS.length bytes)
        pure ("staged" :: String)
      result `shouldBe` PreparationResult (Right "staged") True Nothing
      existing <- either (fail . show) pure (deploymentScope (takeDirectory parent) Test "fixture" 26443)
      refused <- prepareFreshNodeArchiveWith counted parent image existing (\_ _ _ -> pure ())
      refused `shouldBe` PreparationResult (Left PreparationFreshScopeUnavailable) True Nothing
      readIORef manifestReads >>= (`shouldBe` 1)
      listDirectory parent >>= (`shouldBe` [])

  it "creates only a fresh test identity through the public setup command" $
    withSystemTempDirectory "prodbox-fresh-test-setup" $ \anchor -> do
      let root = anchor </> ".test-data" </> "fixture"
          selected = root </> "config" </> "prodbox.dhall"
          marker = root </> "scope-generation.json"
          digestText = "sha256:" ++ replicate 64 'a'
          input environment =
            BS8.pack $
              unlines
                [ anchor
                , "/var/run/docker.sock"
                , environment
                , "fixture"
                , replicate 32 'b'
                , "26443"
                , "kindest/node@" ++ digestText
                , "28080"
                , "30080"
                , "28443"
                , "30443"
                , "127.0.0.1"
                , "artifacts/node.tar"
                , digestText
                , "4096"
                , "artifacts/kind"
                , digestText
                , "1048576"
                ]
          command =
            Subprocess
              "./.build/prodbox"
              ["--config", selected, "config", "setup", "--fresh-test"]
              (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")])
              Nothing
          execute environment =
            captureSubprocessWithInputBounded
              (BoundedSubprocessLimits 8192 65536 65536 30000000)
              (input environment)
              command
      first <- execute "test"
      either (const Nothing) (Just . processExitCode) first `shouldBe` Just ExitSuccess
      beforeMarker <- BS.readFile marker
      beforeConfig <- BS.readFile selected
      second <- execute "test"
      either (const Nothing) (Just . processExitCode) second `shouldBe` Just (ExitFailure 1)
      BS.readFile marker >>= (`shouldBe` beforeMarker)
      BS.readFile selected >>= (`shouldBe` beforeConfig)
      production <- execute "production"
      either (const Nothing) (Just . processExitCode) production `shouldBe` Just (ExitFailure 1)
      doesDirectoryExist (anchor </> ".data") >>= (`shouldBe` False)

  it "refuses an unreviewed kind executable before import" $
    withFixture $ \_ projection _ _ _ -> do
      calls <- newIORef (0 :: Int)
      result <- preparePinnedKindArtifact projection (\_ -> modifyIORef' calls (+ 1))
      result
        `shouldBe` PreparationResult (Left (PreparationSourceFailure NodeRegistryReadInvalidDigest)) True Nothing
      readIORef calls >>= (`shouldBe` 0)

  it "imports only a matching staged archive and confirms cleanup" $
    withFixture $ \parent projection image source expected -> do
      calls <- newIORef (0 :: Int)
      result <- prepareRegistryNodeArchiveWith source parent projection image $ \path -> do
        modifyIORef' calls (+ 1)
        BS.readFile path >>= (`shouldBe` expected)
        pure ("imported" :: String)
      result `shouldBe` PreparationResult (Right "imported") True Nothing
      readIORef calls >>= (`shouldBe` 1)
      listDirectory parent >>= (`shouldBe` [])

  it "refuses unavailable or changed manifest data before import and removes staging" $
    withFixture $ \parent projection image source _ -> do
      calls <- newIORef (0 :: Int)
      let unavailable = source {readRegistryManifest = \_ -> pure (Left NodeRegistryReadUnavailable)}
          changed =
            source
              { readRegistryManifest = \_ -> pure (Right (NodeRegistryDocument "wrong" (NodeRegistryPlan config [layer])))
              }
          publish _ = modifyIORef' calls (+ 1)
      prepareRegistryNodeArchiveWith unavailable parent projection image publish
        >>= ( `shouldBe`
                PreparationResult (Left (PreparationSourceFailure NodeRegistryReadUnavailable)) True Nothing
            )
      prepareRegistryNodeArchiveWith changed parent projection image publish
        >>= (`shouldBe` PreparationResult (Left PreparationManifestMismatch) True Nothing)
      readIORef calls >>= (`shouldBe` 0)
      listDirectory parent >>= (`shouldBe` [])

  it "refuses changed blob bytes before invoking the importer" $
    withFixture $ \parent projection image source _ -> do
      calls <- newIORef (0 :: Int)
      let changed =
            source
              { readRegistryBlob = \blob handle -> do
                  BS.hPut handle (if blob == config then configBytes else "layer-contenu")
                  pure (Right ())
              }
      result <-
        prepareRegistryNodeArchiveWith changed parent projection image (\_ -> modifyIORef' calls (+ 1))
      result
        `shouldBe` PreparationResult (Left (PreparationArchiveFailure NodeRegistryArchiveMismatch)) True Nothing
      readIORef calls >>= (`shouldBe` 0)
      listDirectory parent >>= (`shouldBe` [])

  it "refuses a staging plan above the budget before fetching any blob" $
    withFixture $ \parent projection _ source _ -> do
      calls <- newIORef (0 :: Int)
      let largeLayer = layer {nodeRegistryBlobSize = 600 * 1048576}
          bytes = manifestFor config largeLayer
          largeImage = "kindest/node@" ++ Text.unpack (digest bytes)
          largeSource =
            source
              { readRegistryManifest = \_ -> pure (Right (NodeRegistryDocument bytes (NodeRegistryPlan config [largeLayer])))
              , readRegistryBlob = \_ _ -> modifyIORef' calls (+ 1) >> pure (Right ())
              }
      result <-
        prepareRegistryNodeArchiveWith
          largeSource
          parent
          projection
          largeImage
          (\_ -> modifyIORef' calls (+ 1))
      result `shouldBe` PreparationResult (Left PreparationCapacityExceeded) True Nothing
      readIORef calls >>= (`shouldBe` 0)
      listDirectory parent >>= (`shouldBe` [])

  it "preserves the primary result and retains unexpected staging contents" $
    withFixture $ \parent projection image source _ -> do
      result <- prepareRegistryNodeArchiveWith source parent projection image $ \path -> do
        BS.writeFile (takeDirectory path </> "blob-999") "keep"
        pure ("imported" :: String)
      preparationPrimary result `shouldBe` Right "imported"
      preparationCleanupConfirmed result `shouldBe` False
      case preparationRetainedDirectory result of
        Nothing -> fail "unconfirmed cleanup omitted the retained identity"
        Just directory -> BS.readFile (directory </> "blob-999") >>= (`shouldBe` "keep")

  it "does not remove a replacement at an owned staging name" $
    withFixture $ \parent projection image source _ -> do
      result <- prepareRegistryNodeArchiveWith source parent projection image $ \path -> do
        withBinaryFile path ReadMode $ \_ -> do
          removeFile path
          BS.writeFile path "replacement"
        pure ("imported" :: String)
      preparationPrimary result `shouldBe` Right "imported"
      preparationCleanupConfirmed result `shouldBe` False
      case preparationRetainedDirectory result of
        Nothing -> fail "replaced file omitted the staging identity"
        Just directory -> BS.readFile (directory </> "node-archive.tar") >>= (`shouldBe` "replacement")

  it "does not report cleanup confirmed when a staged file disappeared" $
    withFixture $ \parent projection image source _ -> do
      result <- prepareRegistryNodeArchiveWith source parent projection image $ \path -> do
        removeFile path
        pure ("imported" :: String)
      preparationPrimary result `shouldBe` Right "imported"
      preparationCleanupConfirmed result `shouldBe` False

configBytes, layerBytes :: BS.ByteString
configBytes = "config-content"
layerBytes = "layer-content"

config, layer :: NodeRegistryBlob
config =
  NodeRegistryBlob
    (digest configBytes)
    (fromIntegral (BS.length configBytes))
    "application/vnd.oci.image.config.v1+json"
layer =
  NodeRegistryBlob
    (digest layerBytes)
    (fromIntegral (BS.length layerBytes))
    "application/vnd.oci.image.layer.v1.tar+gzip"

digest :: BS.ByteString -> Text.Text
digest bytes = "sha256:" <> Text.pack (show (hash bytes :: Digest SHA256))

manifest :: BS.ByteString
manifest = manifestFor config layer

manifestFor :: NodeRegistryBlob -> NodeRegistryBlob -> BS.ByteString
manifestFor selectedConfig selectedLayer =
  BL.toStrict $
    Aeson.encode $
      Aeson.object
        [ "schemaVersion" .= (2 :: Int)
        , "mediaType" .= ("application/vnd.oci.image.manifest.v1+json" :: Text.Text)
        , "config" .= blob selectedConfig
        , "layers" .= [blob selectedLayer]
        ]
 where
  blob value =
    Aeson.object
      [ "digest" .= nodeRegistryBlobDigest value
      , "size" .= nodeRegistryBlobSize value
      , "mediaType" .= nodeRegistryBlobMediaType value
      ]

withFixture
  :: ( FilePath
       -> BootstrapProjection
       -> String
       -> RegistrySource
       -> BS.ByteString
       -> IO ()
     )
  -> IO ()
withFixture action = withSystemTempDirectory "prodbox-node-preparation-test" $ \anchor -> do
  let parent = anchor </> "staging"
      configPath = anchor </> "config-blob"
      layerPath = anchor </> "layer-blob"
      archivePath = anchor </> "expected.tar"
      selected = digest manifest
      document = NodeRegistryDocument manifest (NodeRegistryPlan config [layer])
      image = "kindest/node@" ++ Text.unpack selected
  createDirectory parent
  BS.writeFile configPath configBytes
  BS.writeFile layerPath layerBytes
  generated <- withBinaryFile configPath ReadMode $ \c -> withBinaryFile layerPath ReadMode $ \l ->
    withBinaryFile archivePath WriteMode (writeNodeRegistryArchive selected document [c, l])
  (archiveDigest, archiveSize) <- case generated of
    NodeRegistryArchiveWritten d n -> pure (d, n)
    other -> fail (show other)
  expected <- BS.readFile archivePath
  let draft =
        BootstrapDraft
          { draftProjectAnchor = Text.pack anchor
          , draftRuntimeSocket = "/var/run/docker.sock"
          , draftEnvironment = "test"
          , draftDeploymentId = "fixture"
          , draftRootGeneration = Text.replicate 32 "b"
          , draftApiPort = 26443
          , draftNodeImage = Text.pack image
          , draftHttpHostPort = 28080
          , draftHttpNodePort = 30080
          , draftHttpsHostPort = 28443
          , draftHttpsNodePort = 30443
          , draftListenAddress = "127.0.0.1"
          , draftNodePath = "artifacts/node.tar"
          , draftNodeDigest = archiveDigest
          , draftNodeMaximumBytes = fromInteger archiveSize
          , draftKindPath = "artifacts/kind"
          , draftKindDigest = digest "kind"
          , draftKindMaximumBytes = 1048576
          }
      source =
        RegistrySource
          { readRegistryManifest = \_ -> pure (Right document)
          , readRegistryBlob = \blob handle -> do
              BS.hPut handle (if blob == config then configBytes else layerBytes)
              pure (Right ())
          }
  scope <- either (fail . show) pure (deploymentScope anchor Test "fixture" 26443)
  prepareFreshScope scope (replicate 32 'b') >>= (`shouldBe` FreshScopePrepared)
  let isolatedDraft = draft {draftRuntimeSocket = Text.pack (anchor </> "missing-docker.sock")}
  TextIO.writeFile (anchor </> "isolated-status.dhall") (renderBootstrapDraft isolatedDraft)
  decoded <- decodeOptionalBootstrapSource (anchor </> "selected.dhall") (renderBootstrapDraft draft)
  projection <- case decoded of
    Right (Just value) -> pure value
    other -> fail (show other)
  action parent projection image source expected
