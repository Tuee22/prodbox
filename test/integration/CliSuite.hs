{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE TupleSections #-}

module CliSuite
  ( integrationCliSuite
  , runSelectedAuthorityRefusalFixture
  , runInstalledWithFakeAuthority
  , runRke2AdmissionRefusalFixture
  , runRunbookFailureFixture
  , runStreamingCancellationFixture
  )
where

import BootstrapSourceFixture
  ( readyMinioControllerJson
  , readyMinioPodJson
  , readyVaultClaimJson
  , readyVaultControllerJson
  , readyVaultNodeJson
  , readyVaultPodJson
  , writeBootstrapSourceFixture
  )
import Codec.Archive.Tar qualified as Tar
import Codec.Archive.Tar.Entry qualified as TarEntry
import Codec.Serialise (serialise)
import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.MVar
  ( MVar
  , modifyMVar
  , modifyMVar_
  , newEmptyMVar
  , newMVar
  , putMVar
  , readMVar
  , takeMVar
  , tryReadMVar
  )
import Control.Exception
  ( AsyncException (ThreadKilled)
  , IOException
  , SomeException
  , bracket
  , finally
  , fromException
  , throwIO
  , try
  )
import Control.Monad (filterM, forM_, forever, unless, void, when)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as AesonKey
import Data.Aeson.KeyMap qualified as AesonKeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy.Char8 qualified as LazyBS8
import Data.Char (isDigit, toLower)
import Data.Either (isLeft)
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List
  ( find
  , findIndex
  , intercalate
  , isInfixOf
  , isPrefixOf
  , isSuffixOf
  , sort
  , stripPrefix
  )
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (nominalDiffTimeToSeconds)
import Data.Time.Clock.POSIX (getPOSIXTime)
import FixtureServer
  ( withAuthorityFixtureServerForConfig
  , withVaultFixtureServer
  , withVaultFixtureServerSealStatus
  )
import Network.Socket
  ( Family (AF_INET, AF_UNIX)
  , SockAddr (SockAddrInet, SockAddrUnix)
  , Socket
  , SocketOption (ReuseAddr)
  , SocketType (Stream)
  , accept
  , bind
  , close
  , defaultProtocol
  , getSocketName
  , listen
  , setSocketOption
  , socket
  , tupleToHostAddress
  , withSocketsDo
  )
import Network.Socket.ByteString (recv, sendAll)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.BuildSupport
  ( addBuildSupportEnvironment
  , canonicalOperatorBinaryPath
  , syncBuiltOperatorBinary
  )
import Prodbox.CLI.Nuke qualified as Nuke
import Prodbox.CLI.Rke2 qualified as Rke2
import Prodbox.Capacity.Config qualified as Capacity
import Prodbox.Capacity.RuntimeMemory qualified as RuntimeMemory
import Prodbox.Config.BootstrapProjection
  ( bootstrapKindPlan
  , bootstrapScope
  , readBootstrapProjection
  )
import Prodbox.Config.ComponentGraph qualified as ComponentGraph
import Prodbox.Config.DeploymentScope
  ( DeploymentEnvironment (Test)
  , DeploymentScopeError
  , FreshScopeResult (..)
  , ScopeDescriptorInterrupted (..)
  , ScopeDescriptorIoFailure (..)
  , ScopeDescriptorOutcome (..)
  , deploymentScope
  , prepareFreshScope
  , scopeRoot
  , withScopeRootDescriptor
  , withScopeRootDescriptorPreserving
  )
import Prodbox.Config.KindPlan (KindNodeCreateInput (..), kindNodeVarVolumeName)
import Prodbox.Config.Tier0 qualified as Tier0
import Prodbox.Control.DockerConnectedInfo
  ( DockerConnectedInfo (..)
  , DockerConnectedInfoFailure (..)
  , DockerConnectedInfoResult (..)
  , DockerImageLoadResult (..)
  , DockerImageLoadStream (..)
  , DockerImageReadback (..)
  , DockerImageSubmissionObservation (..)
  , DockerKindInfo (..)
  , DockerKindStorage (..)
  , DockerNetworkCreateResult (..)
  , DockerNetworkDetails (..)
  , DockerNetworkRemoveResult (..)
  , DockerNodeConfigPath (..)
  , DockerNodeConfigPathObservation (..)
  , DockerNodeConfigReadback (..)
  , DockerNodeConfigWriteResult (..)
  , DockerNodeContainerCreateResult (..)
  , DockerNodeContainerObservation (..)
  , DockerNodeContainerRemoveResult (..)
  , DockerNodeContainerStartResult (..)
  , DockerNodeVarCreateResult (..)
  , DockerNodeVarRemoveResult (..)
  , DockerNodeVarVolumeObservation (..)
  , classifyDockerImageLoadStream
  , createDockerSessionKindNetwork
  , createDockerSessionKindNode
  , createDockerSessionNodeVarVolume
  , inspectDockerSessionImage
  , inspectDockerSessionKindNetwork
  , inspectDockerSessionKindNode
  , inspectDockerSessionNodeVarVolume
  , loadAndObserveDockerSessionImage
  , loadDockerSessionImage
  , observeConnectedDockerInfo
  , observeDockerSessionKindNodeConfigPath
  , parseDockerBridgeMtu
  , parseDockerKindNetworks
  , parseDockerKindNodeAddresses
  , parseDockerKindNodeConfigArchive
  , parseDockerKindNodeVersionArchive
  , parseDockerKindStorage
  , parseDockerNetworkDetails
  , parseDockerNodeContainer
  , parseDockerNodeVarVolume
  , pingDockerSession
  , readDockerSessionKindNetworkId
  , readDockerSessionKindNodeConfig
  , removeDockerSessionKindNetwork
  , removeDockerSessionKindNode
  , removeDockerSessionNodeVarVolume
  , startDockerSessionKindNode
  , withConnectedDockerInfo
  , writeDockerSessionKindNodeConfig
  )
import Prodbox.Control.DockerIdentity
  ( DockerDaemonObservation (..)
  , DockerSocketIdentity (..)
  , observeDockerSocketIdentity
  )
import Prodbox.Control.DockerPeer
  ( DockerPeer (..)
  , DockerPeerFailure (..)
  , DockerPeerResult (..)
  , observeDockerPeer
  , withConnectedDockerPeer
  )
import Prodbox.Control.ImageIdObservation (ImageIdObservation (..))
import Prodbox.Control.KindDockerClient (prepareKindDockerRequest, validKindDockerBridgePath)
import Prodbox.Control.KindDockerEndpoint
  ( KindDockerBrokerExit (..)
  , KindDockerEndpointResult (..)
  , KindDockerRootIoFailure (..)
  , KindDockerWorkerExit (..)
  , endpointLock
  , endpointReply
  , endpointRequest
  , exchangeBoundKindDockerRead
  , exchangeBoundKindDockerRequest
  , runBoundKindDockerReadWorker
  , serveBoundKindDockerReads
  , withKindDockerEndpoint
  )
import Prodbox.Control.KindDockerReadGate
  ( KindDockerConnectedObservation (..)
  , KindDockerReadResult (..)
  , KindDockerReply (..)
  , kindDockerInventoryObserved
  , newKindDockerReadGate
  , runConnectedKindDockerImageRead
  , runConnectedKindDockerRead
  , runConnectedKindDockerReply
  )
import Prodbox.Control.KindDockerReadProtocol
  ( KindDockerClientFailure (..)
  , KindDockerProtocolOutcome (..)
  , KindDockerRequest (..)
  , exchangeKindDockerRead
  , exchangeKindDockerRequest
  , exchangeSerializedKindDockerRead
  , serveKindDockerInputRequestsWhile
  , serveKindDockerReads
  , serveKindDockerRequestsWhile
  )
import Prodbox.Control.KindDockerWorker
  ( KindDockerWorkerError (KindDockerWorkerInvalidClientDescriptor)
  , prepareKindDockerWorkerWithSealedClient
  )
import Prodbox.Control.KindDockerWorkerPrepare
  ( KindDockerClientLinkPreparation (..)
  , KindDockerClientLinkRemoval (..)
  , KindDockerWorkerPreparation (..)
  , prepareKindDockerClientLink
  , prepareKindDockerWorkerPaths
  , prepareNewKindDockerWorker
  , removeKindDockerClientLink
  )
import Prodbox.Control.KindDockerWorkerRoots
  ( withKindDockerWorkerRoots
  , withRecoveredKindDockerWorkerRoots
  , workerBridge
  , workerLock
  , workerReply
  , workerRequest
  , workerScratch
  )
import Prodbox.Control.KindIntent (KindIntentObservation (..), KindIntentResult (..))
import Prodbox.Control.KindKubeconfigYaml
  ( KindKubeconfigDecodeError (..)
  , decodeBoundedYamlDocuments
  , matchesKindKubeadmScope
  , matchesPinnedKindKubeadmConfig
  )
import Prodbox.Control.KindLease
  ( KindLeaseError (..)
  , KindLeaseInterrupted (..)
  , KindLeaseOutcome (..)
  , KindOperationOutcome (..)
  , KindOperationRefusal (..)
  , withLockedKindScope
  , withNewKindOperation
  , withRecoveredKindOperation
  )
import Prodbox.Control.KindNetworkIntent
  ( KindNetworkAttemptObservation (..)
  , KindNetworkAttemptWrite (..)
  , KindNetworkIntentObservation (..)
  , KindNetworkIntentWrite (..)
  , KindNetworkRecoveryObservation (..)
  , KindNetworkRemovalObservation (..)
  , KindNetworkRemovalRecovery (..)
  , KindNetworkRemovalWrite (..)
  , mkKindNetworkIntent
  , observeKindNetworkAttempt
  , observeKindNetworkIntent
  , observeKindNetworkRemoval
  , observeRecordedKindNetworkAttempt
  , observeRecordedKindNetworkIntent
  , observeRecordedKindNetworkRemoval
  , recordKindNetworkAttempt
  , recordKindNetworkIntent
  , recordKindNetworkRemoval
  , sameKindNetworkSubnet
  )
import Prodbox.Control.KindNetworkReceipt
  ( NetworkReceiptKind (..)
  , NetworkReceiptObservation (..)
  , NetworkReceiptWrite (..)
  , NetworkTransport (..)
  , observeNetworkReceipt
  , recordNetworkReceipt
  )
import Prodbox.Control.KindNetworkRecovery
  ( KindNetworkAttemptAction (..)
  , KindNetworkConfigurationObservation (..)
  , KindNetworkIndependentIdObservation (..)
  , KindNetworkIndependentObservation (..)
  , KindNetworkRecordedTransport (..)
  , KindNetworkRecoveryResult (..)
  , KindNetworkRecoverySample (..)
  , KindNetworkRemovalAction (..)
  , compareKindNetworkConfiguration
  , observeRecoveredKindNetwork
  , runKindNetworkRecordedAttemptOnSession
  , withNewConnectedKindNetworkAttempt
  , withNewConnectedKindNetworkRecordedRemoval
  , withNewConnectedKindNetworkRemoval
  )
import Prodbox.Control.KindNodeCreateIntent
  ( KindNodeCandidateObservation (..)
  , KindNodeCandidateWrite (..)
  , KindNodeConfigAttemptObservation (..)
  , KindNodeConfigAttemptWrite (..)
  , KindNodeConfigResultObservation (..)
  , KindNodeConfigResultWrite (..)
  , KindNodeCreateAttemptObservation (..)
  , KindNodeCreateAttemptWrite (..)
  , KindNodeCreateIntentObservation (..)
  , KindNodeCreateIntentWrite (..)
  , KindNodeCreateRecoveryObservation (..)
  , KindNodeCreateResultObservation (..)
  , KindNodeCreateResultWrite (..)
  , KindNodeRemoveAttemptObservation (..)
  , KindNodeRemoveAttemptWrite (..)
  , KindNodeRemoveControlObservation (..)
  , KindNodeRemoveResultObservation (..)
  , KindNodeRemoveResultWrite (..)
  , KindNodeStartAttemptObservation (..)
  , KindNodeStartAttemptWrite (..)
  , KindNodeStartResultObservation (..)
  , KindNodeStartResultWrite (..)
  , mkKindNodeCreateIntent
  , observeKindNodeConfigAttempt
  , observeKindNodeConfigResult
  , observeKindNodeCreateAttempt
  , observeKindNodeCreateIntent
  , observeKindNodeCreateResult
  , observeKindNodeRemoveAttempt
  , observeKindNodeRemoveControl
  , observeKindNodeRemoveResult
  , observeKindNodeStartAttempt
  , observeKindNodeStartResult
  , observeRecordedKindNodeCandidate
  , observeRecordedKindNodeCreateIntent
  , recordKindNodeCandidate
  , recordKindNodeConfigAttempt
  , recordKindNodeConfigResult
  , recordKindNodeCreateAttempt
  , recordKindNodeCreateIntent
  , recordKindNodeCreateResult
  , recordKindNodeRemoveAttempt
  , recordKindNodeRemoveResult
  , recordKindNodeStartAttempt
  , recordKindNodeStartResult
  )
import Prodbox.Control.KindNodeCreateOperation
  ( KindNodeCandidateAction (..)
  , KindNodeConfigAction (..)
  , KindNodeConfigCandidateObservation (..)
  , KindNodeCreateAction (..)
  , KindNodeRemoveAction (..)
  , KindNodeRunAction (..)
  , KindNodeStartAction (..)
  , newKindNodeBroker
  , newKindNodeBrokerWithConfig
  , observeKindNodeBrokerConfigAction
  , observeKindNodeBrokerConfigCandidate
  , observeKindNodeBrokerResult
  , runKindNodeBrokerInput
  , runKindNodeBrokerRequest
  , runKindNodeConfigOnSession
  , runKindNodeStartOnSession
  , serveKindNodeBroker
  , withNewConnectedKindNodeCandidate
  , withNewConnectedKindNodeCreate
  , withNewConnectedKindNodeRemove
  , withNewConnectedKindNodeStart
  )
import Prodbox.Control.KindNodeCreateReadback (NodeCreateCandidate (..), parseNodeCreateCandidate)
import Prodbox.Control.KindNodeRemovalReadback
  ( NodeRemovalInventory (..)
  , NodeRemovalReadback (..)
  , classifyNodeRemovalReadback
  , nodeRemovalPositive
  , parseNodeRemovalInventory
  )
import Prodbox.Control.KindNodeVolumeIntent
  ( KindNodeVolumeAttemptWrite (..)
  , KindNodeVolumeIntentWrite (..)
  , KindNodeVolumeReceiptObservation (..)
  , KindNodeVolumeReceiptWrite (..)
  , KindNodeVolumeRemovalObservation (..)
  , KindNodeVolumeRemovalReceiptObservation (..)
  , KindNodeVolumeRemovalReceiptWrite (..)
  , KindNodeVolumeRemovalWrite (..)
  , mkKindNodeVolumeIntent
  , observeKindNodeVolumeReceipt
  , observeKindNodeVolumeRemoval
  , observeKindNodeVolumeRemovalReceipt
  , recordKindNodeVolumeAttempt
  , recordKindNodeVolumeIntent
  , recordKindNodeVolumeReceipt
  , recordKindNodeVolumeRemoval
  , recordKindNodeVolumeRemovalReceipt
  )
import Prodbox.Control.KindNodeVolumeOperation
  ( KindNodeVolumeAction (..)
  , KindNodeVolumeRemovalAction (..)
  , withNewConnectedKindNodeVolumeAttempt
  , withNewConnectedKindNodeVolumeRemoval
  )
import Prodbox.Control.KindNodeVolumeReadback
  ( NodeVolumeInventory (..)
  , NodeVolumeReadback (..)
  , classifyNodeVolumeReadback
  , parseNodeVolumeInventory
  )
import Prodbox.Control.KindRuntimeConfig (renderKindConfigForArchive)
import Prodbox.Control.KindTool
  ( ArchiveBoundConfinedKindInventory (..)
  , ArchiveBoundConfinedKindNode (..)
  , ConfinedKindInventory (..)
  , ConfinedKindInventoryConclusion (..)
  , ConfinedKindNodeAttempt (..)
  , ConfinedKindSnapshotsAttempt (..)
  , ConfinedKindSnapshotsObservation (..)
  , ConfinedNodeImageObservation (..)
  , ConfinedNodeNetworkObservation (..)
  , ConnectedConfinedKindInventory (..)
  , KindDockerMarkerObservation (..)
  , RecordedConfinedKindInventory (..)
  , interpretArchiveBoundConfinedKindInventory
  , interpretConfinedKindInventory
  , interpretConnectedConfinedKindInventory
  , interpretVerifiedConfinedKindInventory
  , kindNodeWorkerEnvironment
  , observeArchiveBoundConfinedKindInventoryOnHost
  , observeConfinedKindInventoryOnHost
  , observeConfinedNodeImage
  , observeConfinedNodeNetwork
  , observeConnectedConfinedKindInventoryOnHost
  , observeKindDockerMarker
  , observeRecordedConfinedKindInventoryOnHost
  , runArchiveBoundConfinedKindNodeOnHost
  , runConfinedKindNodeOnHost
  , runVerifiedConfinedKindNodeOnHost
  )
import Prodbox.Control.NodeArchive
  ( ArchiveCallbackProgress (..)
  , InspectedArchiveResult (..)
  , NodeArchiveObservation (..)
  , NodeLoadBlob (..)
  , NodeLoadPlan (..)
  , VerifiedNodeArchive (..)
  , classifyArchiveInterruption
  , withInspectedNodeArchive
  )
import Prodbox.Control.NodeArchiveExport
  ( DockerArchiveFailure (..)
  , DockerArchiveResult (..)
  , maximumDockerArchiveBytes
  , writeUntaggedDockerArchive
  )
import Prodbox.Control.NodeArchiveStage (StagedNodeResult (..), reserveStage, withStagedNodeArchive)
import Prodbox.Control.NodeImageIntent
  ( NodeImageAttemptObservation (..)
  , NodeImageAttemptWrite (..)
  , NodeImageIdentityObservation (..)
  , NodeImageIntentObservation (..)
  , NodeImageIntentWrite (..)
  , NodeImageResultObservation (..)
  , NodeImageResultWrite (..)
  , bindNodeImageIntent
  , mkNodeImageIntent
  , observeNodeImageAttempt
  , observeNodeImageIntent
  , observeRecordedNodeImageAttempt
  , observeRecordedNodeImageIdentity
  , observeRecordedNodeImageIntent
  , observeRecordedNodeImageResult
  , recordNodeImageAttempt
  , recordNodeImageIntent
  , recordNodeImageResult
  )
import Prodbox.Control.NodeImageOperation
  ( NodeImageAttemptAction (..)
  , NodeImageConnectedObservation (..)
  , NodeImageConnectionResult (..)
  , NodeImageIndependentObservation (..)
  , NodeImagePreparation (..)
  , NodeImageRecordedSubmission (..)
  , NodeImageRecovery (..)
  , NodeImageRecoveryPoint (..)
  , observeRecoveredConnectedNodeImage
  , observeRecoveredNodeImagePreparation
  , withConnectedNodeImageRecord
  , withNewConnectedNodeImageAttempt
  , withNewConnectedNodeImageRecordedAttempt
  , withNewNodeImagePreparation
  )
import Prodbox.Control.SealedTool (planSealedToolBudget, withSealedTool)
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication qualified as AuthorityAuthentication
import Prodbox.ControlPlane.LocalClient qualified as LocalClient
import Prodbox.Http.Client
  ( HttpConfig (..)
  , HttpError (..)
  , defaultHttpConfig
  , httpGetText
  )
import Prodbox.Lib.ChartPlatform qualified as ChartPlatform
import Prodbox.Lifecycle.CredentialProvisioner.Substrate qualified as CredentialProvisionerSubstrate

-- Sprint 4.64: the empty admission set is package-internal so no production
-- module can begin a phase with one; a fixture driving the executor directly
-- still needs it, and the `dev check` rule barring this import is scoped to
-- `src/`.
import Prodbox.Lifecycle.DependencyAdmission.Internal (noAdmissions)
import Prodbox.Lifecycle.HostCleanupIntent qualified as HostCleanup
import Prodbox.Settings qualified as Settings
import Prodbox.Settings.SecretRef
  ( SecretRef (SecretRefVault)
  , VaultSecretRef (..)
  )
import Prodbox.Subprocess qualified as Subprocess
import Prodbox.Substrate (Substrate (..))
import Prodbox.TestRunner qualified as TestRunner
import Prodbox.TestTopology (defaultTestTopology, renderTestTopologyDhall)
import Prodbox.TestValidation qualified as TestValidation
import System.Directory
  ( Permissions (..)
  , copyFile
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , getCurrentDirectory
  , getPermissions
  , listDirectory
  , removeFile
  , renameDirectory
  , renameFile
  , setPermissions
  )
import System.Environment (getEnvironment, getExecutablePath)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath (takeDirectory, (</>))
import System.IO qualified as IO
import System.IO.Temp (withSystemTempDirectory)
import System.Info qualified as SystemInfo
import System.Posix.Files (createLink, createSymbolicLink, setFileMode)
import System.Posix.Files qualified as PosixFiles
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as PosixBytes
import System.Posix.Process (getProcessID)
import System.Posix.Types (Fd (..))
import System.Posix.User (getEffectiveGroupID, getEffectiveUserID)
import System.Process
  ( CreateProcess (create_group, cwd, env, std_err, std_out)
  , ProcessHandle
  , StdStream (CreatePipe)
  , createProcess
  , getProcessExitCode
  , interruptProcessGroupOf
  , proc
  , readCreateProcessWithExitCode
  , terminateProcess
  , waitForProcess
  )
import System.Timeout (timeout)
import TestSupport
import Tier0Fixture
  ( RawTier0Reason (MustNotTypeCheckAgainst)
  , rawTier0Fixture
  , tier0FixtureWithContext
  , tier0FixtureWithParameters
  , writeTier0Fixture
  )

integrationCliSuite :: SuiteBuilder ()
integrationCliSuite = do
  describe "selected bootstrap setup" $
    it "authors a validated test document only inside its run config directory" $
      withSystemTempDirectory "prodbox-bootstrap-setup" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \path -> installOperatorBinaryInDir path tmpDir
        let runRoot = tmpDir </> ".test-data" </> "run"
            selected = runRoot </> "config" </> "prodbox.dhall"
            production = tmpDir </> "prodbox.dhall"
            digest = "sha256:" ++ replicate 64 'a'
            inputs =
              unlines
                [ tmpDir
                , "/var/run/docker.sock"
                , "test"
                , "run"
                , replicate 32 'b'
                , "26443"
                , "kindest/node@" ++ digest
                , "28080"
                , "30080"
                , "28443"
                , "30443"
                , "127.0.0.1"
                , "artifacts/node.tar"
                , digest
                , "4096"
                , "artifacts/kind"
                , digest
                , "1048576"
                ]
            run arguments input = readCreateProcessWithExitCode (proc binary arguments) {cwd = Just tmpDir} input
        writeTier0Fixture
          tmpDir
          (rawTier0Fixture (MustNotTypeCheckAgainst "foreign production marker") "production marker")
        (helpExit, helpOutput, _) <- run ["config", "setup", "--help"] ""
        helpExit `shouldBe` ExitSuccess
        helpOutput `shouldContain` "unavailable"
        helpOutput `shouldContain` "--config"
        (foreignExit, _, foreignError) <- run ["--config", production, "config", "setup"] inputs
        foreignExit `shouldBe` ExitFailure 1
        foreignError `shouldContain` "BootstrapDraftUnsafeDestination"
        readFile production `shouldReturn` "production marker"
        (dryExit, _, dryError) <- run ["--config", selected, "config", "setup", "--dry-run"] ""
        dryExit `shouldBe` ExitFailure 1
        dryError `shouldContain` "does not support --dry-run"
        (shortExit, _, shortError) <- run ["--config", selected, "config", "setup"] (tmpDir ++ "\n")
        shortExit `shouldBe` ExitFailure 1
        shortError `shouldContain` "input ended"
        doesFileExist selected `shouldReturn` False
        (declineExit, _, declineError) <- run ["--config", selected, "config", "setup"] (inputs ++ "no\n")
        declineExit `shouldBe` ExitFailure 1
        declineError `shouldContain` "BootstrapDraftRootUnavailable"
        doesDirectoryExist runRoot `shouldReturn` False
        (setupExit, setupOutput, setupError) <-
          run ["--config", selected, "config", "setup"] (inputs ++ "yes\n")
        setupExit `shouldBe` ExitSuccess
        setupOutput `shouldContain` "Fresh selected root enrolled"
        setupOutput `shouldContain` "Bootstrap configuration published"
        setupError `shouldBe` ""
        original <- BS8.readFile selected
        (planExit, planOutput, planError) <- run ["--config", selected, "control", "plan"] ""
        planExit `shouldBe` ExitSuccess
        planError `shouldBe` ""
        planOutput `shouldContain` "\"name\":\"prodbox-t-run\""
        planOutput `shouldContain` ("\"hostPath\":\"" ++ runRoot ++ "\"")
        planOutput `shouldContain` "no resources were changed"
        doesDirectoryExist (runRoot </> "artifacts") `shouldReturn` False
        (validateExit, _, _) <- run ["--config", selected, "config", "validate"] ""
        validateExit `shouldBe` ExitSuccess
        (againExit, _, againError) <- run ["--config", selected, "config", "setup"] inputs
        againExit `shouldBe` ExitFailure 1
        againError `shouldContain` "SelectedDhallDestinationExists"
        BS8.readFile selected `shouldReturn` original
        readFile production `shouldReturn` "production marker"
        let pending = runRoot </> "config" </> ".prodbox.dhall.prodbox-v2-pending"
        renameFile selected pending
        (recoverExit, recoverOutput, recoverError) <-
          run ["--config", selected, "config", "setup"] (inputs ++ "yes\n")
        recoverExit `shouldBe` ExitSuccess
        recoverOutput `shouldContain` "recover matching v2 document"
        recoverError `shouldBe` ""
        BS8.readFile selected `shouldReturn` original
        doesFileExist pending `shouldReturn` False
        (verifyExit, verifyOutput, verifyError) <-
          run ["--config", selected, "config", "setup"] (inputs ++ "yes\n")
        verifyExit `shouldBe` ExitSuccess
        verifyOutput `shouldContain` "Existing bootstrap configuration matches the draft"
        verifyOutput `shouldContain` "publication origin"
        verifyError `shouldBe` ""
        BS8.readFile selected `shouldReturn` original
        let foreignRoot = tmpDir </> ".test-data" </> "foreign"
            foreignSelected = foreignRoot </> "config" </> "prodbox.dhall"
            foreignInputs = unlines (map (\value -> if value == "run" then "foreign" else value) (lines inputs))
        createDirectoryIfMissing True foreignRoot
        writeFile (foreignRoot </> "owner-marker") "preserve"
        (existingExit, _, existingError) <-
          run ["--config", foreignSelected, "config", "setup"] (foreignInputs ++ "yes\n")
        existingExit `shouldBe` ExitFailure 1
        existingError `shouldContain` "FreshScopeAlreadyExists"
        readFile (foreignRoot </> "owner-marker") `shouldReturn` "preserve"
        doesDirectoryExist (foreignRoot </> "config") `shouldReturn` False
        let productionRoot = tmpDir </> ".data" </> "prod"
            productionSelected = productionRoot </> "config" </> "prodbox.dhall"
            productionInputs = unlines (map productionValue (lines inputs))
            productionValue "test" = "production"
            productionValue "run" = "prod"
            productionValue value = value
        (productionDeclined, _, _) <-
          run ["--config", productionSelected, "config", "setup"] (productionInputs ++ "no\n")
        productionDeclined `shouldBe` ExitFailure 1
        doesDirectoryExist productionRoot `shouldReturn` False
        (productionExit, productionOutput, productionError) <-
          run ["--config", productionSelected, "config", "setup"] (productionInputs ++ "yes\n")
        productionExit `shouldBe` ExitSuccess
        productionOutput `shouldContain` "Fresh selected root enrolled"
        productionError `shouldBe` ""
        (productionPlanExit, productionPlan, _) <-
          run ["--config", productionSelected, "control", "plan"] ""
        productionPlanExit `shouldBe` ExitSuccess
        productionPlan `shouldContain` "\"name\":\"prodbox-p-prod\""
        productionPlan `shouldContain` ("\"hostPath\":\"" ++ productionRoot ++ "\"")
        BS8.readFile selected `shouldReturn` original
        readFile production `shouldReturn` "production marker"

  describe "selected bootstrap artifact ingress" $
    it "retains declared bytes, resumes a matching prefix and preserves conflicts" $
      withSystemTempDirectory "prodbox-artifact-ingress" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \path -> installOperatorBinaryInDir path tmpDir
        let root = tmpDir </> ".test-data" </> "artifact"
            selected = root </> "config" </> "prodbox.dhall"
            source = tmpDir </> "source"
            wrong = tmpDir </> "wrong"
            link = tmpDir </> "link"
            protected = tmpDir </> "test-secrets.dhall"
            hardlink = tmpDir </> "hardlink"
            bytes = BS8.replicate 1048576 'a'
            digest = BS8.unpack (hexSha256 bytes)
            nodeBytes = BS8.replicate 524288 'b'
            nodeDigest = BS8.unpack (hexSha256 nodeBytes)
            nodeSource = tmpDir </> "node-source"
            values =
              unlines
                [ tmpDir
                , "/var/run/docker.sock"
                , "test"
                , "artifact"
                , replicate 32 'a'
                , "26443"
                , "kindest/node@sha256:" ++ replicate 64 'b'
                , "28080"
                , "30080"
                , "28443"
                , "30443"
                , "127.0.0.1"
                , "artifacts/node.tar"
                , "sha256:" ++ nodeDigest
                , "1048576"
                , "artifacts/kind"
                , "sha256:" ++ digest
                , "2097152"
                , "yes"
                ]
            run arguments input = readCreateProcessWithExitCode (proc binary arguments) {cwd = Just tmpDir} input
            importFile role path = run ["--config", selected, "control", "import-artifact", role, path] ""
        BS8.writeFile source bytes
        BS8.writeFile nodeSource nodeBytes
        BS8.writeFile wrong (BS8.pack "wrong")
        BS8.writeFile protected (BS8.pack "synthetic protected fixture")
        mapM_ (`setFileMode` 0o600) [source, nodeSource, wrong, protected]
        createSymbolicLink source link
        createLink source hardlink
        (setupExit, _, _) <- run ["--config", selected, "config", "setup"] values
        setupExit `shouldBe` ExitSuccess
        (wrongExit, _, wrongError) <- importFile "kind-tool" wrong
        wrongExit `shouldBe` ExitFailure 1
        wrongError `shouldContain` "ArtifactSourceMismatch"
        doesDirectoryExist (root </> "artifacts") `shouldReturn` False
        (linkExit, _, linkError) <- importFile "kind-tool" link
        linkExit `shouldBe` ExitFailure 1
        linkError `shouldContain` "ArtifactSourceUnsafe"
        (protectedExit, _, protectedError) <- importFile "kind-tool" protected
        protectedExit `shouldBe` ExitFailure 1
        protectedError `shouldContain` "ArtifactSourceUnsafe"
        (hardlinkExit, _, hardlinkError) <- importFile "kind-tool" hardlink
        hardlinkExit `shouldBe` ExitFailure 1
        hardlinkError `shouldContain` "ArtifactSourceUnsafe"
        removeFile hardlink
        (importExit, _, _) <- importFile "kind-tool" source
        importExit `shouldBe` ExitSuccess
        BS8.readFile (root </> "artifacts" </> "kind") `shouldReturn` bytes
        (againExit, againOutput, _) <- importFile "kind-tool" source
        againExit `shouldBe` ExitSuccess
        againOutput `shouldContain` "already matches"
        let staged = root </> ".prodbox-import" </> ("node-" ++ nodeDigest)
        BS8.writeFile staged (BS8.pack "conflicting prefix")
        setFileMode staged 0o600
        (pendingExit, _, pendingError) <- importFile "node-archive" nodeSource
        pendingExit `shouldBe` ExitFailure 1
        pendingError `shouldContain` "ArtifactPendingConflict"
        BS8.readFile staged `shouldReturn` BS8.pack "conflicting prefix"
        (discardExit, discardOutput, _) <-
          run ["--config", selected, "control", "discard-artifact-staging", "node-archive"] ""
        discardExit `shouldBe` ExitSuccess
        discardOutput `shouldContain` "staging discarded"
        doesFileExist staged `shouldReturn` False
        BS8.readFile (root </> "artifacts" </> "kind") `shouldReturn` bytes
        let quarantine = root </> ".prodbox-import" </> (".discard-node-" ++ nodeDigest)
        BS8.writeFile quarantine (BS8.pack "interrupted discard")
        setFileMode quarantine 0o600
        (quarantineImportExit, _, quarantineImportError) <- importFile "node-archive" nodeSource
        quarantineImportExit `shouldBe` ExitFailure 1
        quarantineImportError `shouldContain` "ArtifactImportIncomplete"
        doesFileExist (root </> "artifacts" </> "node.tar") `shouldReturn` False
        (retryDiscardExit, _, _) <-
          run ["--config", selected, "control", "discard-artifact-staging", "node-archive"] ""
        retryDiscardExit `shouldBe` ExitSuccess
        doesFileExist quarantine `shouldReturn` False
        BS8.writeFile staged (BS8.pack "old pending")
        BS8.writeFile quarantine (BS8.pack "old quarantine")
        setFileMode staged 0o600
        setFileMode quarantine 0o600
        (bothExit, _, bothError) <-
          run ["--config", selected, "control", "discard-artifact-staging", "node-archive"] ""
        bothExit `shouldBe` ExitFailure 1
        bothError `shouldContain` "ArtifactStagingDiscardIncomplete"
        BS8.readFile staged `shouldReturn` BS8.pack "old pending"
        doesFileExist quarantine `shouldReturn` False
        (secondDiscardExit, _, _) <-
          run ["--config", selected, "control", "discard-artifact-staging", "node-archive"] ""
        secondDiscardExit `shouldBe` ExitSuccess
        doesFileExist staged `shouldReturn` False
        BS8.writeFile staged (BS8.take 12345 nodeBytes)
        setFileMode staged 0o600
        (resumeExit, _, _) <- importFile "node-archive" nodeSource
        resumeExit `shouldBe` ExitSuccess
        BS8.readFile (root </> "artifacts" </> "node.tar") `shouldReturn` nodeBytes
        doesFileExist staged `shouldReturn` False
        createSymbolicLink nodeSource staged
        (unsafeDiscardExit, _, _) <-
          run ["--config", selected, "control", "discard-artifact-staging", "node-archive"] ""
        unsafeDiscardExit `shouldBe` ExitFailure 1
        BS8.readFile nodeSource `shouldReturn` nodeBytes
        removeFile staged
        BS8.writeFile (root </> "artifacts" </> "node.tar") (BS8.pack "foreign")
        (conflictExit, _, conflictError) <- importFile "node-archive" nodeSource
        conflictExit `shouldBe` ExitFailure 1
        conflictError `shouldContain` "ArtifactDestinationConflict"
        BS8.readFile (root </> "artifacts" </> "node.tar") `shouldReturn` BS8.pack "foreign"

  describe "kind worker client descriptor" $ do
    it "rejects ambiguous bridge paths before opening endpoints" $ do
      validKindDockerBridgePath "/tmp/owned/bridge" `shouldBe` True
      validKindDockerBridgePath "/tmp/owned/../bridge" `shouldBe` False
      validKindDockerBridgePath "/tmp/bridge:other" `shouldBe` False
      validKindDockerBridgePath "/tmp/bridge\0other" `shouldBe` False
      validKindDockerBridgePath "relative/bridge" `shouldBe` False
      validKindDockerBridgePath ("/" <> replicate 4097 'a') `shouldBe` False
    it "refuses an unsealed descriptor before applying worker restrictions" $
      withSystemTempDirectory "prodbox-kind-client" $ \directory -> do
        let path = directory </> "client"
            invalid = Fd (-1)
        BS.writeFile path (BS8.pack "not a sealed executable")
        bracket (Posix.openFd path Posix.ReadOnly Posix.defaultFileFlags) Posix.closeFd $ \client -> do
          prepareKindDockerWorkerWithSealedClient invalid [] invalid invalid invalid invalid client
            `shouldReturn` Left KindDockerWorkerInvalidClientDescriptor

  describe "connected Docker peer observation" $
    it "holds the socket, reports peer credentials and distinguishes interruption and replacement" $
      withSystemTempDirectory "prodbox-peer" $ \directory -> do
        let path = directory </> "docker.sock"
            relocated = directory </> "relocated.sock"
        bracket (socket AF_UNIX Stream defaultProtocol) close $ \listener -> do
          bind listener (SockAddrUnix path)
          listen listener 8
          process <- getProcessID
          user <- getEffectiveUserID
          group <- getEffectiveGroupID
          observed <- observeDockerPeer path
          case observed of
            DockerPeerCompleted (DockerPeer pid uid gid _) ->
              (pid, uid, gid) `shouldBe` (toInteger process, toInteger user, toInteger group)
            other -> expectationFailure ("peer observation failed: " ++ show other)
          withConnectedDockerPeer 0 path (\_ _ _ -> pure ())
            `shouldReturn` DockerPeerRefused DockerPeerInvalidInput
          timed <- withConnectedDockerPeer 100000 path $ \_ _ _ -> threadDelay 300000
          timed `shouldBe` DockerPeerUnconfirmed DockerPeerTimedOut
          closed <- withConnectedDockerPeer 1000000 path $ \connection _ _ -> do
            close connection
            pure ("receipt" :: String)
          closed `shouldBe` DockerPeerUnconfirmedAfter "receipt" DockerPeerIoFailure
          changed <- withConnectedDockerPeer 1000000 path $ \_ _ stable -> do
            stable `shouldReturn` True
            renameFile path relocated
            createSymbolicLink relocated path
            stable `shouldReturn` False
            pure ("receipt" :: String)
          changed `shouldBe` DockerPeerChanged "receipt"
          observeDockerPeer path `shouldReturn` DockerPeerRefused DockerPeerEndpointUnavailable

  describe "connected Docker info observation" $ do
    it "observes bounded container path metadata without treating a 404 as absence" $
      withSystemTempDirectory "prodbox-config-path" $ \directory -> do
        let encoded raw = Base64.encode (BS8.pack raw)
            timestamp = Text.pack "2026-01-01T00:00:00Z"
            directoryStat =
              encoded
                "{\"name\":\"kind\",\"size\":4096,\"mode\":2147484141,\"mtime\":\"2026-01-01T00:00:00Z\",\"linkTarget\":\"\"}"
            linkStat =
              encoded
                "{\"name\":\"kind\",\"size\":4,\"mode\":134218239,\"mtime\":\"2026-01-01T00:00:00Z\",\"linkTarget\":\"/tmp\"}"
            fileStat =
              encoded
                "{\"name\":\"kubeadm.conf\",\"size\":11,\"mode\":420,\"mtime\":\"2026-01-01T00:00:00Z\",\"linkTarget\":\"\"}"
            duplicateStat =
              encoded
                "{\"name\":\"kind\",\"name\":\"foreign\",\"size\":1,\"mode\":2147484141,\"mtime\":\"2026-01-01T00:00:00Z\",\"linkTarget\":\"\"}"
            header value = BS8.pack "X-Docker-Container-Path-Stat: " <> value <> BS8.pack "\r\n"
            cases =
              [
                ( DockerNodeConfigDirectory
                , "200 OK"
                , header directoryStat
                , Right (DockerNodeConfigDirectoryObserved 2147484141 4096 timestamp)
                )
              , (DockerNodeConfigDirectory, "200 OK", header linkStat, Right DockerNodeConfigOtherObserved)
              ,
                ( DockerNodeConfigFile
                , "200 OK"
                , header fileStat
                , Right (DockerNodeConfigRegularObserved 420 11 timestamp)
                )
              , (DockerNodeConfigFile, "404 Not Found", BS8.empty, Right DockerNodeConfigNotFoundResponse)
              , (DockerNodeConfigDirectory, "200 OK", header duplicateStat, Left DockerConnectedInfoInvalid)
              ,
                ( DockerNodeConfigDirectory
                , "200 OK"
                , header directoryStat <> header directoryStat
                , Left DockerConnectedInfoInvalid
                )
              ]
        forM_ (zip [(1 :: Int) ..] cases) $ \(number, (selected, status, fields, expected)) -> do
          let socketPath = directory </> ("docker-" ++ show number ++ ".sock")
          withDockerConfigPathFixture socketPath status fields $ do
            outcome <- withConnectedDockerInfo 5000000 socketPath $ \session _ _ ->
              observeDockerSessionKindNodeConfigPath session (replicate 64 'c') selected
            outcome `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted expected)

    it "decodes bounded multi-document YAML without aliases or duplicate keys" $ do
      let document = BS8.pack "kind: ClusterConfiguration\n---\nkind: InitConfiguration\n"
      decoded <- decodeBoundedYamlDocuments document
      case decoded of
        Right [Aeson.Object _, Aeson.Object _] -> pure ()
        _ -> fail "valid multi-document input refused"
      forM_
        [ "kind: ClusterConfiguration\n---\nkind: InitConfiguration\nkind: Other\n"
        , "first: &anchor sample\nsecond: *anchor\n---\nkind: InitConfiguration\n"
        , intercalate "\n---\n" (replicate 17 "kind: Item")
        ]
        $ \invalid -> do
          result <- decodeBoundedYamlDocuments (BS8.pack invalid)
          result `shouldSatisfy` isLeft
      decodeBoundedYamlDocuments (BS.replicate 65537 42)
        `shouldReturn` Left KindKubeconfigDocumentTooLarge

    it "submits one bounded node configuration archive and independently compares its read-back" $
      withSystemTempDirectory "prodbox-config-archive" $ \directory -> do
        let contents = BS8.pack "synthetic configuration\n"
            identifier = replicate 64 'c'
            socketPath = directory </> "docker.sock"
        path <- either fail pure (TarEntry.toTarPath False "kubeadm.conf")
        wrongPath <- either fail pure (TarEntry.toTarPath False "other")
        let entry = TarEntry.fileEntry path (LazyBS8.fromStrict contents)
            wrong = TarEntry.fileEntry wrongPath (LazyBS8.fromStrict contents)
            archive entries = LazyBS8.toStrict (Tar.write entries)
        parseDockerKindNodeConfigArchive contents (archive [entry]) `shouldBe` Just DockerNodeConfigMatches
        parseDockerKindNodeConfigArchive (BS8.pack "different") (archive [entry])
          `shouldBe` Just DockerNodeConfigDiffers
        parseDockerKindNodeConfigArchive contents (archive [entry, entry]) `shouldBe` Nothing
        parseDockerKindNodeConfigArchive contents (archive [wrong]) `shouldBe` Nothing
        withDockerConfigFixture socketPath (archive [entry]) True $ \received -> do
          outcome <- withConnectedDockerInfo 10000000 socketPath $ \session _ stable -> do
            writeDockerSessionKindNodeConfig session identifier contents (pure False)
              `shouldReturn` DockerNodeConfigWriteNotStarted
            writeDockerSessionKindNodeConfig session identifier (BS.replicate 65537 42) stable
              `shouldReturn` DockerNodeConfigWriteNotStarted
            writeDockerSessionKindNodeConfig session identifier contents stable
              `shouldReturn` DockerNodeConfigWriteReply 200
            readDockerSessionKindNodeConfig session identifier contents
              `shouldReturn` Right DockerNodeConfigMatches
            readMVar received `shouldReturn` archive [entry]
          outcome `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted ())
        let lostSocket = directory </> "lost.sock"
        withDockerConfigFixture lostSocket (archive [entry]) False $ \received -> do
          outcome <- withConnectedDockerInfo 10000000 lostSocket $ \session _ stable -> do
            writeDockerSessionKindNodeConfig session identifier contents stable
              `shouldReturn` DockerNodeConfigWriteUnconfirmed
            readMVar received `shouldReturn` archive [entry]
          outcome `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted ())

    it "accepts only a single bounded regular version file in the node archive" $ do
      path <- either fail pure (TarEntry.toTarPath False "version")
      otherPath <- either fail pure (TarEntry.toTarPath False "other")
      let entry = TarEntry.fileEntry path (LazyBS8.pack "v1.30.0\n")
          other = TarEntry.fileEntry otherPath (LazyBS8.pack "other")
          oversized = TarEntry.fileEntry path (LazyBS8.replicate 4097 'x')
          archive = LazyBS8.toStrict . Tar.write
      parseDockerKindNodeVersionArchive (archive [entry]) `shouldBe` Just (BS8.pack "v1.30.0\n")
      parseDockerKindNodeVersionArchive (archive [other]) `shouldBe` Nothing
      parseDockerKindNodeVersionArchive (archive [entry, entry]) `shouldBe` Nothing
      parseDockerKindNodeVersionArchive (archive [oversized]) `shouldBe` Nothing
      parseDockerKindNodeVersionArchive (BS8.pack "broken") `shouldBe` Nothing

    it "reads bounded information and keeps the peer and subsequent request on one connection" $
      withDockerInfoFixture (BS8.pack "{\"ID\":\"daemon-a\"}") True $ \path -> do
        process <- getProcessID
        user <- getEffectiveUserID
        group <- getEffectiveGroupID
        result <- withConnectedDockerInfo 2000000 path $ \session (DockerConnectedInfo identifier (DockerPeer pid uid gid _)) stable -> do
          identifier `shouldBe` "daemon-a"
          (pid, uid, gid) `shouldBe` (toInteger process, toInteger user, toInteger group)
          stable `shouldReturn` True
          pingDockerSession session `shouldReturn` Right ()
          pure ("read-only receipt" :: String)
        result `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted "read-only receipt")

    it "rejects duplicate keys, oversized bodies and invalid identifiers" $ do
      let failures =
            [ (BS8.pack "{\"ID\":\"daemon-a\",\"ID\":\"daemon-b\"}", DockerConnectedInfoInvalid)
            , (BS8.pack "{\"ID\":\"bad id\"}", DockerConnectedInfoInvalid)
            ,
              ( BS8.pack "{\"ID\":\"daemon-a\",\"padding\":\"" <> BS8.replicate 65537 'x' <> BS8.pack "\"}"
              , DockerConnectedInfoTooLarge
              )
            ]
      forM_ failures $ \(body, failure) ->
        withDockerInfoFixture body False $ \path ->
          observeConnectedDockerInfo path
            `shouldReturn` DockerPeerCompleted (DockerConnectedInfoRefused failure)

    it "refuses a server-declared closing connection before the callback" $
      withDockerInfoFixtureWithClose (BS8.pack "{\"ID\":\"daemon-a\"}") $ \path -> do
        called <- newIORef False
        result <- withConnectedDockerInfo 2000000 path $ \_ _ _ -> writeIORef called True
        result
          `shouldBe` DockerPeerCompleted (DockerConnectedInfoRefused DockerConnectedInfoConnectionClosing)
        readIORef called `shouldReturn` False

    it "refuses EOF-delimited responses before the callback" $
      withDockerInfoFixtureUnframed (BS8.pack "{\"ID\":\"daemon-a\"}") $ \path -> do
        called <- newIORef False
        result <- withConnectedDockerInfo 2000000 path $ \_ _ _ -> writeIORef called True
        result `shouldBe` DockerPeerCompleted (DockerConnectedInfoRefused DockerConnectedInfoFramingInvalid)
        readIORef called `shouldReturn` False

    it "does not discard bytes buffered after the info response" $
      withDockerInfoFixtureTrailing (BS8.pack "{\"ID\":\"daemon-a\"}") $ \path -> do
        result <- withConnectedDockerInfo 2000000 path $ \session _ _ -> pingDockerSession session
        case result of
          DockerPeerCompleted (DockerConnectedInfoCompleted pingResult) -> pingResult `shouldSatisfy` isLeft
          other -> expectationFailure ("unexpected session result: " ++ show other)

    it "reads one exact image ID on the held session and treats failures as unobservable" $
      withSystemTempDirectory "prodbox-session-image" $ \directory -> do
        let path = directory </> "docker.sock"
            digest character = "sha256:" ++ replicate 64 character
        withDockerDaemonFixture path False $ \requests -> do
          result <- withConnectedDockerInfo 5000000 path $ \session _ stable -> do
            stable `shouldReturn` True
            inspectDockerSessionImage session "sha256:../bad" `shouldReturn` Left DockerConnectedInfoInvalid
            inspectDockerSessionImage session (digest 'a')
              `shouldReturn` Right (ImageIdObserved "linux" "amd64" 0)
            inspectDockerSessionImage session (digest 'b') `shouldReturn` Left DockerConnectedInfoInvalid
            inspectDockerSessionImage session (digest 'd') `shouldReturn` Left DockerConnectedInfoInvalid
            inspectDockerSessionImage session (digest 'c') `shouldReturn` Left DockerConnectedInfoStatus
            pingDockerSession session `shouldReturn` Right ()
            pure ("image observations" :: String)
          result `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted "image observations")
          observed <- readMVar requests
          length observed `shouldBe` 6
          observed `shouldSatisfy` all (not . isInfixOf "../bad")

    it "gates connected image reads and never forwards a foreign request" $
      withSystemTempDirectory "prodbox-gated-session-image" $ \directory -> do
        let path = directory </> "docker.sock"
            imageId = "sha256:" ++ replicate 64 'a'
            otherId = "sha256:" ++ replicate 64 'b'
        scope <- either (fail . show) pure (deploymentScope directory Test "run" 26443)
        withDockerDaemonFixture path False $ \requests -> do
          result <- withConnectedDockerInfo 5000000 path $ \session _ _ -> do
            Just gate <- newKindDockerReadGate scope imageId
            runConnectedKindDockerImageRead gate session ["inspect", "--type=image", imageId]
              `shouldReturn` KindDockerReadCompleted (ImageIdObserved "linux" "amd64" 0)
            runConnectedKindDockerImageRead gate session ["inspect", "--type=image", otherId]
              `shouldReturn` KindDockerReadRefused
            runConnectedKindDockerImageRead gate session ["inspect", "--type=image", imageId]
              `shouldReturn` KindDockerReadRefused
          result `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted ())
          observed <- readMVar requests
          length observed `shouldBe` 2
          observed `shouldSatisfy` all (not . isInfixOf otherId)

    it "binds provider information to the held daemon and closes on mismatch" $
      withSystemTempDirectory "prodbox-gated-session-info" $ \directory -> do
        let path = directory </> "docker.sock"
            imageId = "sha256:" ++ replicate 64 'a'
            infoRequest = ["info", "--format", "{{json .}}"]
            imageRequest = ["inspect", "--type=image", imageId]
            listRequest = ["ps", "-a", "--filter", "label=io.x-k8s.kind.cluster=prodbox-t-run", "--format", "{{.Names}}"]
        scope <- either (fail . show) pure (deploymentScope directory Test "run" 26443)
        withDockerDaemonFixture path False $ \requests -> do
          result <- withConnectedDockerInfo 5000000 path $ \session (DockerConnectedInfo identifier _) _ -> do
            Just gate <- newKindDockerReadGate scope imageId
            runConnectedKindDockerRead gate session identifier infoRequest
              `shouldReturn` KindDockerReadCompleted (KindDockerProviderInfo (DockerKindInfo "systemd" "2" True True True []))
            runConnectedKindDockerRead gate session identifier imageRequest
              `shouldReturn` KindDockerReadCompleted (KindDockerImageInfo (ImageIdObserved "linux" "amd64" 0))
            runConnectedKindDockerRead gate session identifier listRequest
              `shouldReturn` KindDockerReadCompleted (KindDockerContainerNames [])
            Just changed <- newKindDockerReadGate scope imageId
            runConnectedKindDockerRead changed session "daemon-b" infoRequest
              `shouldReturn` KindDockerReadFailed DockerConnectedInfoInvalid
            runConnectedKindDockerRead changed session identifier imageRequest
              `shouldReturn` KindDockerReadRefused
          result `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted ())
          observed <- readMVar requests
          length observed `shouldBe` 5
          length (filter (isInfixOf "/images/") observed) `shouldBe` 1
          filter (isInfixOf "/containers/json?") observed
            `shouldSatisfy` \queries -> length queries == 1 && all (isInfixOf "prodbox-t-run") queries

    it "closes the held-session gate when container inventory is foreign" $
      withSystemTempDirectory "prodbox-gated-session-foreign-container" $ \directory -> do
        let path = directory </> "docker.sock"
            imageId = "sha256:" ++ replicate 64 'a'
            listRequest = ["ps", "-a", "--filter", "label=io.x-k8s.kind.cluster=prodbox-t-run", "--format", "{{.Names}}"]
            foreignBody =
              BS8.pack $
                "[{\"Id\":\""
                  ++ replicate 64 'b'
                  ++ "\",\"Names\":[\"/prodbox-t-run-control-plane\"],\"Labels\":{\"io.x-k8s.kind.cluster\":\"foreign\"}}]"
        scope <- either (fail . show) pure (deploymentScope directory Test "run" 26443)
        withDockerDaemonFixtureContainers path foreignBody $ \requests -> do
          result <- withConnectedDockerInfo 5000000 path $ \session (DockerConnectedInfo identifier _) _ -> do
            Just gate <- newKindDockerReadGate scope imageId
            runConnectedKindDockerRead gate session identifier listRequest
              `shouldReturn` KindDockerReadFailed DockerConnectedInfoInvalid
            runConnectedKindDockerRead gate session identifier ["inspect", "--type=image", imageId]
              `shouldReturn` KindDockerReadRefused
          result `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted ())
          observed <- readMVar requests
          length observed `shouldBe` 2
          observed `shouldSatisfy` all (not . isInfixOf "/images/")

    it "serves the pinned provider's security and storage info formats from the connected daemon" $
      withSystemTempDirectory "prodbox-gated-storage-info" $ \directory -> do
        let path = directory </> "docker.sock"
            imageId = "sha256:" ++ replicate 64 'a'
            storage driver statusRows =
              Aeson.object
                [ AesonKey.fromString "ID" Aeson..= ("daemon-a" :: String)
                , AesonKey.fromString "Driver" Aeson..= (driver :: String)
                , AesonKey.fromString "DriverStatus" Aeson..= statusRows
                ]
            rows = [["Backing Filesystem", "extfs"]] :: [[String]]
        scope <- either (fail . show) pure (deploymentScope directory Test "run" 26443)
        parseDockerKindStorage "daemon-a" (storage "overlay2" rows)
          `shouldBe` Right (DockerKindStorage "overlay2" (Just rows))
        parseDockerKindStorage "daemon-a" (storage "overlay2" Aeson.Null)
          `shouldBe` Right (DockerKindStorage "overlay2" Nothing)
        parseDockerKindStorage "daemon-b" (storage "overlay2" rows) `shouldSatisfy` isLeft
        parseDockerKindStorage "daemon-a" (storage "overlay2" [["missing value"]]) `shouldSatisfy` isLeft
        parseDockerKindStorage "daemon-a" (storage "" rows) `shouldSatisfy` isLeft
        parseDockerKindStorage
          "daemon-a"
          ( Aeson.object
              [ AesonKey.fromString "ID" Aeson..= ("daemon-a" :: String)
              , AesonKey.fromString "Driver" Aeson..= ("overlay2" :: String)
              ]
          )
          `shouldSatisfy` isLeft
        withDockerDaemonFixture path False $ \requests -> do
          result <- withConnectedDockerInfo 5000000 path $ \session (DockerConnectedInfo identifier _) _ -> do
            Just gate <- newKindDockerReadGate scope imageId
            runConnectedKindDockerReply
              gate
              session
              identifier
              ["info", "--format", "'{{json .SecurityOptions}}'"]
              `shouldReturn` KindDockerReply 0 (BS8.pack "'[]'\n") BS8.empty
            runConnectedKindDockerReply gate session identifier ["info", "-f", "{{.Driver}}"]
              `shouldReturn` KindDockerReply 0 (BS8.pack "overlay2\n") BS8.empty
            runConnectedKindDockerReply gate session identifier ["info", "-f", "{{json .DriverStatus }}"]
              `shouldReturn` KindDockerReply 0 (BS8.pack "[[\"Backing Filesystem\",\"extfs\"]]\n") BS8.empty
            runConnectedKindDockerRead gate session identifier ["info", "-f", "{{.Other}}"]
              `shouldReturn` KindDockerReadRefused
          result `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted ())
          observed <- readMVar requests
          length (filter (isInfixOf "/info") observed) `shouldBe` 4

    it "observes one derived node volume and refuses foreign or conflicting configuration" $
      withSystemTempDirectory "prodbox-node-var-volume" $ \directory -> do
        let path = directory </> "docker.sock"
            selected = directory </> "selected.dhall"
            generation = replicate 32 'a'
            operation = replicate 32 'b'
            document =
              "{ bootstrap = { schema_version = 1, project_anchor = \""
                ++ directory
                ++ "\", runtime_socket = \""
                ++ path
                ++ "\", environment = \"test\", deployment_id = \"run\", root_generation = \""
                ++ generation
                ++ "\", api_port = 26443, node_image = \"kindest/node@sha256:"
                ++ replicate 64 'a'
                ++ "\", http_host_port = 28080, http_node_port = 30080, https_host_port = 28443, https_node_port = 30443, listen_address = \"127.0.0.1\" } }"
        writeFile selected document
        bootstrap <- readBootstrapProjection selected >>= either (fail . show) pure
        name <-
          maybe
            (fail "invalid volume name")
            pure
            (kindNodeVarVolumeName (bootstrapKindPlan bootstrap) generation operation)
        let labels =
              Aeson.object
                [ AesonKey.fromString "io.prodbox.deployment" Aeson..= ("prodbox-t-run" :: String)
                , AesonKey.fromString "io.prodbox.generation" Aeson..= generation
                , AesonKey.fromString "io.prodbox.operation" Aeson..= operation
                , AesonKey.fromString "io.prodbox.resource" Aeson..= ("kind-node-var" :: String)
                ]
            response volumeName driver options =
              Aeson.object
                [ AesonKey.fromString "Name" Aeson..= (volumeName :: String)
                , AesonKey.fromString "Driver" Aeson..= (driver :: String)
                , AesonKey.fromString "Scope" Aeson..= ("local" :: String)
                , AesonKey.fromString "Labels" Aeson..= labels
                , AesonKey.fromString "Options" Aeson..= options
                ]
        parseDockerNodeVarVolume bootstrap operation name (response name "local" Aeson.Null)
          `shouldBe` Right DockerNodeVarVolumeMatching
        let missingLabels = case response name "local" Aeson.Null of
              Aeson.Object value -> Aeson.Object (AesonKeyMap.insert (AesonKey.fromString "Labels") (Aeson.object []) value)
              value -> value
        parseDockerNodeVarVolume bootstrap operation name missingLabels
          `shouldBe` Right DockerNodeVarVolumeConflict
        parseDockerNodeVarVolume bootstrap operation name (response name "foreign" Aeson.Null)
          `shouldBe` Right DockerNodeVarVolumeConflict
        parseDockerNodeVarVolume
          bootstrap
          operation
          name
          (response name "local" (Aeson.object [AesonKey.fromString "device" Aeson..= ("foreign" :: String)]))
          `shouldBe` Right DockerNodeVarVolumeConflict
        parseDockerNodeVarVolume bootstrap operation name (response "foreign" "local" Aeson.Null)
          `shouldSatisfy` isLeft
        withDockerDaemonFixture path False $ \requests -> do
          result <- withConnectedDockerInfo 5000000 path $ \session _ _ -> do
            inspectDockerSessionNodeVarVolume session bootstrap "invalid"
              `shouldReturn` Left DockerConnectedInfoInvalid
            inspectDockerSessionNodeVarVolume session bootstrap operation
              `shouldReturn` Right DockerNodeVarVolumeNotFound
          result `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted ())
          observed <- readMVar requests
          length (filter (isInfixOf ("/volumes/" ++ name)) observed) `shouldBe` 1
        let matchingPath = directory </> "docker-matching.sock"
            matchingDocument = Text.unpack (Text.replace (Text.pack path) (Text.pack matchingPath) (Text.pack document))
            matchingBody = LazyBS8.toStrict (Aeson.encode (response name "local" Aeson.Null))
        writeFile selected matchingDocument
        matchingBootstrap <- readBootstrapProjection selected >>= either (fail . show) pure
        prepareFreshScope (bootstrapScope matchingBootstrap) generation `shouldReturn` FreshScopePrepared
        withNewKindOperation matchingBootstrap operation (const (pure ()))
          `shouldReturn` KindOperationCallbackReturned ()
        binary <- resolveBinaryPath
        tamper <- newIORef False
        varyInventory <- newIORef False
        volumeReads <- newIORef (0 :: Int)
        let volumeList = do
              varying <- readIORef varyInventory
              count <- if varying then atomicModifyIORef' volumeReads (\value -> (value + 1, value)) else pure 0
              let items = [Aeson.object [AesonKey.fromString "Name" Aeson..= name] | varying && count > 0]
              pure
                ( LazyBS8.toStrict
                    ( Aeson.encode
                        ( Aeson.object
                            [ AesonKey.fromString "Volumes" Aeson..= items
                            , AesonKey.fromString "Warnings" Aeson..= ([] :: [String])
                            ]
                        )
                    )
                )
            tamperOnVolume request = when (("GET /volumes/" ++ name ++ " ") `isPrefixOf` request) $ do
              enabled <- readIORef tamper
              when
                enabled
                (writeFile (scopeRoot (bootstrapScope matchingBootstrap) </> "kind-intent.json") "damaged")
            withMatchingVolume =
              withDockerDaemonFixtureControlVolumeList
                matchingPath
                False
                tamperOnVolume
                (pure False)
                (BS8.pack "[]")
                (BS8.pack "[]")
                (pure True)
                (Just (name, matchingBody))
                volumeList
        withMatchingVolume $ \requests -> do
          (exitCode, output, errors) <-
            readCreateProcessWithExitCode (proc binary ["--config", selected, "control", "status"]) ""
          (exitCode, errors) `shouldBe` (ExitSuccess, "")
          output
            `shouldContain` "Candidate node /var volume: configuration and labels match; provenance, admission and worker settlement unverified"
          output `shouldContain` "volume proposal not found locally"
          observed <- readMVar requests
          length (filter (isInfixOf ("/volumes/" ++ name)) observed) `shouldBe` 1
          recorded <- withRecoveredKindOperation matchingBootstrap operation $ \operationStable ->
            withConnectedDockerInfo 5000000 matchingPath $ \_ (DockerConnectedInfo identifier (DockerPeer _ _ _ identity)) peerStable -> do
              intent <-
                maybe
                  (fail "invalid node volume intent")
                  pure
                  (mkKindNodeVolumeIntent operation (DockerDaemonObserved identifier identity))
              recordKindNodeVolumeIntent matchingBootstrap intent ((&&) <$> operationStable <*> peerStable)
          recorded
            `shouldBe` KindOperationCallbackReturned
              (DockerPeerCompleted (DockerConnectedInfoCompleted NodeVolumeIntentRecorded))
          (recordedCode, recordedOutput, recordedErrors) <-
            readCreateProcessWithExitCode (proc binary ["--config", selected, "control", "status"]) ""
          (recordedCode, recordedErrors) `shouldBe` (ExitSuccess, "")
          recordedOutput
            `shouldContain` "volume proposal matches current operation and daemon; effect and settlement unverified"
          recordedOutput `shouldContain` "volume attempt not found locally; effect and settlement unverified"
          attempt <- withRecoveredKindOperation matchingBootstrap operation $ \operationStable ->
            withConnectedDockerInfo 5000000 matchingPath $ \_ (DockerConnectedInfo identifier (DockerPeer _ _ _ identity)) peerStable -> do
              intent <-
                maybe
                  (fail "invalid node volume intent")
                  pure
                  (mkKindNodeVolumeIntent operation (DockerDaemonObserved identifier identity))
              recordKindNodeVolumeAttempt matchingBootstrap intent ((&&) <$> operationStable <*> peerStable)
          attempt
            `shouldBe` KindOperationCallbackReturned
              (DockerPeerCompleted (DockerConnectedInfoCompleted NodeVolumeAttemptRecorded))
          (attemptCode, attemptOutput, attemptErrors) <-
            readCreateProcessWithExitCode (proc binary ["--config", selected, "control", "status"]) ""
          (attemptCode, attemptErrors) `shouldBe` (ExitSuccess, "")
          attemptOutput `shouldContain` "volume attempt recorded; effect and settlement unverified"
          attemptOutput `shouldContain` "volume result not found locally; effect and settlement unverified"
          receipt <- withRecoveredKindOperation matchingBootstrap operation $ \operationStable ->
            withConnectedDockerInfo 5000000 matchingPath $ \_ (DockerConnectedInfo identifier (DockerPeer _ _ _ identity)) peerStable -> do
              intent <-
                maybe
                  (fail "invalid node volume intent")
                  pure
                  (mkKindNodeVolumeIntent operation (DockerDaemonObserved identifier identity))
              recordKindNodeVolumeReceipt
                matchingBootstrap
                intent
                DockerNodeVarCreateUnconfirmed
                ((&&) <$> operationStable <*> peerStable)
          receipt
            `shouldBe` KindOperationCallbackReturned
              (DockerPeerCompleted (DockerConnectedInfoCompleted NodeVolumeReceiptRecorded))
          (receiptCode, receiptOutput, receiptErrors) <-
            readCreateProcessWithExitCode (proc binary ["--config", selected, "control", "status"]) ""
          (receiptCode, receiptErrors) `shouldBe` (ExitSuccess, "")
          receiptOutput `shouldContain` "volume request outcome unconfirmed; settlement unverified"
          receiptOutput `shouldContain` "volume removal not found locally; absence and settlement unverified"
          removal <- withRecoveredKindOperation matchingBootstrap operation $ \operationStable ->
            withConnectedDockerInfo 5000000 matchingPath $ \_ (DockerConnectedInfo identifier (DockerPeer _ _ _ identity)) peerStable -> do
              intent <-
                maybe
                  (fail "invalid node volume intent")
                  pure
                  (mkKindNodeVolumeIntent operation (DockerDaemonObserved identifier identity))
              let stable = (&&) <$> operationStable <*> peerStable
              observeKindNodeVolumeRemoval matchingBootstrap intent stable `shouldReturn` NodeVolumeRemovalMissing
              recordKindNodeVolumeRemoval matchingBootstrap intent stable `shouldReturn` NodeVolumeRemovalRecorded
              observeKindNodeVolumeRemoval matchingBootstrap intent stable `shouldReturn` NodeVolumeRemovalMatches
              recordKindNodeVolumeRemoval matchingBootstrap intent stable
                `shouldReturn` NodeVolumeRemovalAlreadyExists
          removal
            `shouldBe` KindOperationCallbackReturned (DockerPeerCompleted (DockerConnectedInfoCompleted ()))
          (removalCode, removalOutput, removalErrors) <-
            readCreateProcessWithExitCode (proc binary ["--config", selected, "control", "status"]) ""
          (removalCode, removalErrors) `shouldBe` (ExitSuccess, "")
          removalOutput `shouldContain` "volume removal recorded; absence and settlement unverified"
          removalOutput
            `shouldContain` "volume removal result not found locally; absence and settlement unverified"
          writeIORef varyInventory True
          (inventoryCode, inventoryOutput, inventoryErrors) <-
            readCreateProcessWithExitCode (proc binary ["--config", selected, "control", "status"]) ""
          (inventoryCode, inventoryErrors) `shouldBe` (ExitSuccess, "")
          inventoryOutput
            `shouldContain` "Independent volume inventory: inventory or scope changed during observation; absence and settlement unverified"
          readIORef volumeReads `shouldReturn` 2
          writeIORef varyInventory False
          resultRecord <- withRecoveredKindOperation matchingBootstrap operation $ \operationStable ->
            withConnectedDockerInfo 5000000 matchingPath $ \_ (DockerConnectedInfo identifier (DockerPeer _ _ _ identity)) peerStable -> do
              intent <-
                maybe
                  (fail "invalid node volume intent")
                  pure
                  (mkKindNodeVolumeIntent operation (DockerDaemonObserved identifier identity))
              recordKindNodeVolumeRemovalReceipt
                matchingBootstrap
                intent
                DockerNodeVarRemoveUnconfirmed
                ((&&) <$> operationStable <*> peerStable)
          resultRecord
            `shouldBe` KindOperationCallbackReturned
              (DockerPeerCompleted (DockerConnectedInfoCompleted NodeVolumeRemovalReceiptRecorded))
          (resultCode, resultOutput, resultErrors) <-
            readCreateProcessWithExitCode (proc binary ["--config", selected, "control", "status"]) ""
          (resultCode, resultErrors) `shouldBe` (ExitSuccess, "")
          resultOutput `shouldContain` "volume removal outcome unconfirmed; absence and settlement unverified"
          let removalPath = scopeRoot (bootstrapScope matchingBootstrap) </> "kind-node-var-volume-removal.json"
          writeFile removalPath "{\"kind\":1,\"kind\":1}"
          (damagedCode, damagedOutput, damagedErrors) <-
            readCreateProcessWithExitCode (proc binary ["--config", selected, "control", "status"]) ""
          (damagedCode, damagedErrors) `shouldBe` (ExitSuccess, "")
          damagedOutput `shouldContain` "volume removal is invalid or incomplete"
          removeFile removalPath
          writeFile (directory </> "foreign-removal") "foreign"
          createSymbolicLink (directory </> "foreign-removal") removalPath
          (linkCode, linkOutput, linkErrors) <-
            readCreateProcessWithExitCode (proc binary ["--config", selected, "control", "status"]) ""
          (linkCode, linkErrors) `shouldBe` (ExitSuccess, "")
          linkOutput `shouldContain` "volume removal could not be safely observed"
          readFile (directory </> "foreign-removal") `shouldReturn` "foreign"
          writeIORef tamper True
          (changedCode, changedOutput, changedErrors) <-
            readCreateProcessWithExitCode (proc binary ["--config", selected, "control", "status"]) ""
          (changedCode, changedErrors) `shouldBe` (ExitSuccess, "")
          changedOutput
            `shouldContain` "Candidate node /var volume: unobservable or changed; volume state and worker settlement unverified"

    it "validates independent volume and container inventory without inferring absence" $ do
      let name = "prodbox-t-run-var-" ++ replicate 32 'a' ++ "-" ++ replicate 32 'b'
          first = replicate 64 'a'
          second = replicate 64 'b'
      parseNodeVolumeInventory name ("other\n" ++ name ++ "\n") (second ++ "\n" ++ first ++ "\n")
        `shouldBe` Just (NodeVolumeInventory True [first, second])
      parseNodeVolumeInventory name "other\n" "" `shouldBe` Just (NodeVolumeInventory False [])
      parseNodeVolumeInventory name (name ++ "\n" ++ name ++ "\n") "" `shouldBe` Nothing
      parseNodeVolumeInventory name "other\n" (first ++ "\n" ++ first ++ "\n") `shouldBe` Nothing
      parseNodeVolumeInventory name "other\n" "short\n" `shouldBe` Nothing
      parseNodeVolumeInventory name "invalid name\n" "" `shouldBe` Nothing
      let daemon = DockerDaemonObserved "daemon-a" (DockerSocketIdentity 1 2 1000 0o140660)
          differentDaemon = DockerDaemonObserved "daemon-b" (DockerSocketIdentity 1 2 1000 0o140660)
          absent = NodeVolumeInventory False []
          present = NodeVolumeInventory True []
      classifyNodeVolumeReadback daemon daemon (Just True) (Just absent) (Just absent)
        `shouldBe` NodeVolumeReadbackSampled absent
      classifyNodeVolumeReadback daemon daemon (Just True) (Just absent) (Just present)
        `shouldBe` NodeVolumeReadbackChanged
      classifyNodeVolumeReadback daemon differentDaemon (Just True) (Just absent) (Just absent)
        `shouldBe` NodeVolumeReadbackChanged
      classifyNodeVolumeReadback daemon DockerDaemonChanged (Just True) (Just absent) (Just absent)
        `shouldBe` NodeVolumeReadbackChanged
      classifyNodeVolumeReadback daemon DockerDaemonUnobservable (Just True) (Just absent) (Just absent)
        `shouldBe` NodeVolumeReadbackUnobservable
      classifyNodeVolumeReadback daemon daemon Nothing (Just absent) (Just absent)
        `shouldBe` NodeVolumeReadbackUnobservable
      classifyNodeVolumeReadback daemon daemon (Just False) (Just absent) (Just absent)
        `shouldBe` NodeVolumeReadbackUnobservable
      classifyNodeVolumeReadback daemon daemon (Just True) Nothing (Just absent)
        `shouldBe` NodeVolumeReadbackUnobservable

    it "discovers only one consistently visible unconfirmed node candidate" $ do
      let target = replicate 64 'a'
          other = replicate 64 'b'
      parseNodeCreateCandidate "" "" "" `shouldBe` Just NodeCandidateNone
      parseNodeCreateCandidate (target ++ "\n") (target ++ "\n") (target ++ "\n")
        `shouldBe` Just (NodeCandidateUnique target)
      parseNodeCreateCandidate "" (target ++ "\n") (target ++ "\n") `shouldBe` Just NodeCandidateConflict
      parseNodeCreateCandidate (target ++ "\n") (target ++ "\n") (other ++ "\n")
        `shouldBe` Just NodeCandidateConflict
      parseNodeCreateCandidate
        (target ++ "\n" ++ other ++ "\n")
        (target ++ "\n" ++ other ++ "\n")
        (target ++ "\n")
        `shouldBe` Just NodeCandidateConflict
      parseNodeCreateCandidate "invalid\n" "" "" `shouldBe` Nothing

    it "samples the exact node ID and refuses malformed or changing inventories" $ do
      let target = replicate 64 'a'
          foreignId = replicate 64 'b'
          present = NodeRemovalInventory True [target] [target, foreignId]
          empty = NodeRemovalInventory False [] []
          daemon = DockerDaemonObserved "daemon-a" (DockerSocketIdentity 1 2 1000 0o140660)
          otherDaemon = DockerDaemonObserved "daemon-b" (DockerSocketIdentity 1 2 1000 0o140660)
      parseNodeRemovalInventory
        target
        (target ++ "\n")
        (target ++ "\n")
        (foreignId ++ "\n" ++ target ++ "\n")
        `shouldBe` Just present
      parseNodeRemovalInventory target "" "" "" `shouldBe` Just empty
      nodeRemovalPositive target (NodeRemovalReadbackSampled present) `shouldBe` True
      nodeRemovalPositive target (NodeRemovalReadbackSampled empty) `shouldBe` False
      nodeRemovalPositive target NodeRemovalReadbackUnobservable `shouldBe` False
      nodeRemovalPositive
        target
        (NodeRemovalReadbackSampled present {nodeRemovalNameIds = [target, foreignId]})
        `shouldBe` False
      parseNodeRemovalInventory target (target ++ "\n" ++ target ++ "\n") "" "" `shouldBe` Nothing
      parseNodeRemovalInventory target "short\n" "" "" `shouldBe` Nothing
      parseNodeRemovalInventory "bad" "" "" "" `shouldBe` Nothing
      classifyNodeRemovalReadback daemon daemon (Just True) (Just present) (Just present)
        `shouldBe` NodeRemovalReadbackSampled present
      classifyNodeRemovalReadback daemon daemon (Just True) (Just empty) (Just present)
        `shouldBe` NodeRemovalReadbackChanged
      classifyNodeRemovalReadback daemon otherDaemon (Just True) (Just empty) (Just empty)
        `shouldBe` NodeRemovalReadbackChanged
      classifyNodeRemovalReadback daemon daemon Nothing (Just empty) (Just empty)
        `shouldBe` NodeRemovalReadbackUnobservable
      classifyNodeRemovalReadback daemon daemon (Just True) Nothing (Just empty)
        `shouldBe` NodeRemovalReadbackUnobservable

    it "sends one derived volume request and preserves uncertain outcomes" $
      withSystemTempDirectory "prodbox-node-volume-create" $ \directory -> do
        let generation = replicate 32 'a'
            operation = replicate 32 'b'
            name = "prodbox-t-run-var-" ++ generation ++ "-" ++ operation
            selected = directory </> "selected.dhall"
            socketPath = directory </> "docker.sock"
            document =
              "{ bootstrap = { schema_version = 1, project_anchor = \""
                ++ directory
                ++ "\", runtime_socket = \""
                ++ socketPath
                ++ "\", environment = \"test\", deployment_id = \"run\", root_generation = \""
                ++ generation
                ++ "\", api_port = 26443, node_image = \"kindest/node@sha256:"
                ++ replicate 64 'a'
                ++ "\", http_host_port = 28080, http_node_port = 30080, https_host_port = 28443, https_node_port = 30443, listen_address = \"127.0.0.1\" } }"
            labels =
              Aeson.object
                [ AesonKey.fromString "io.prodbox.deployment" Aeson..= ("prodbox-t-run" :: String)
                , AesonKey.fromString "io.prodbox.generation" Aeson..= generation
                , AesonKey.fromString "io.prodbox.operation" Aeson..= operation
                , AesonKey.fromString "io.prodbox.resource" Aeson..= ("kind-node-var" :: String)
                ]
            response =
              LazyBS8.toStrict $
                Aeson.encode $
                  Aeson.object
                    [ AesonKey.fromString "Name" Aeson..= name
                    , AesonKey.fromString "Driver" Aeson..= ("local" :: String)
                    , AesonKey.fromString "Scope" Aeson..= ("local" :: String)
                    , AesonKey.fromString "Labels" Aeson..= labels
                    , AesonKey.fromString "Options" Aeson..= Aeson.Null
                    ]
        writeFile selected document
        bootstrap <- readBootstrapProjection selected >>= either (fail . show) pure
        let rootPath = scopeRoot (bootstrapScope bootstrap)
            image = "sha256:" ++ replicate 64 'a'
            tool = "sha256:50030de23cf40a18505f20426f6a8506bedf13c6e509244bd1fa9463721b0f54"
            nodeArgs =
              [ "run"
              , "--name"
              , "prodbox-t-run-control-plane"
              , "--hostname"
              , "prodbox-t-run-control-plane"
              , "--label"
              , "io.x-k8s.kind.role=control-plane"
              , "--privileged"
              , "--security-opt"
              , "seccomp=unconfined"
              , "--security-opt"
              , "apparmor=unconfined"
              , "--tmpfs"
              , "/tmp"
              , "--tmpfs"
              , "/run"
              , "--volume"
              , "/var"
              , "--volume"
              , "/lib/modules:/lib/modules:ro"
              , "-e"
              , "KIND_EXPERIMENTAL_CONTAINERD_SNAPSHOTTER"
              , "--detach"
              , "--tty"
              , "--label"
              , "io.x-k8s.kind.cluster=prodbox-t-run"
              , "--net"
              , "prodbox-t-run"
              , "--restart=on-failure:1"
              , "--init=false"
              , "--cgroupns=private"
              , "--volume=" ++ rootPath ++ ":/var/lib/prodbox"
              , "--publish=127.0.0.1:28080:30080/TCP"
              , "--publish=127.0.0.1:28443:30443/TCP"
              , "--publish=127.0.0.1:26443:6443/TCP"
              , "-e"
              , "KUBECONFIG=/etc/kubernetes/admin.conf"
              , image
              ]
            nodeInput = KindNodeCreateInput tool image (replicate 64 'c') generation operation nodeArgs
        let nodeInspect actualImage actualNetwork actualVolume volumeSource actualRoot =
              Aeson.object
                [ AesonKey.fromString "Id" Aeson..= replicate 64 'c'
                , AesonKey.fromString "Name" Aeson..= ("/prodbox-t-run-control-plane" :: String)
                , AesonKey.fromString "Image" Aeson..= actualImage
                , AesonKey.fromString "Config"
                    Aeson..= Aeson.object
                      [ AesonKey.fromString "Hostname" Aeson..= ("prodbox-t-run-control-plane" :: String)
                      , AesonKey.fromString "Tty" Aeson..= True
                      , AesonKey.fromString "ExposedPorts"
                          Aeson..= Aeson.object
                            [ AesonKey.fromString "30080/tcp" Aeson..= Aeson.object []
                            , AesonKey.fromString "30443/tcp" Aeson..= Aeson.object []
                            , AesonKey.fromString "6443/tcp" Aeson..= Aeson.object []
                            ]
                      , AesonKey.fromString "Labels"
                          Aeson..= Aeson.object
                            [ AesonKey.fromString "io.x-k8s.kind.cluster" Aeson..= ("prodbox-t-run" :: String)
                            , AesonKey.fromString "io.x-k8s.kind.role" Aeson..= ("control-plane" :: String)
                            , AesonKey.fromString "io.prodbox.generation" Aeson..= generation
                            , AesonKey.fromString "io.prodbox.operation" Aeson..= operation
                            ]
                      ]
                , AesonKey.fromString "HostConfig"
                    Aeson..= Aeson.object
                      [ AesonKey.fromString "PublishAllPorts" Aeson..= False
                      , AesonKey.fromString "Privileged" Aeson..= True
                      , AesonKey.fromString "CgroupnsMode" Aeson..= ("private" :: String)
                      , AesonKey.fromString "NetworkMode" Aeson..= replicate 64 'c'
                      , AesonKey.fromString "RestartPolicy"
                          Aeson..= Aeson.object
                            [ AesonKey.fromString "Name" Aeson..= ("on-failure" :: String)
                            , AesonKey.fromString "MaximumRetryCount" Aeson..= (1 :: Int)
                            ]
                      , AesonKey.fromString "SecurityOpt"
                          Aeson..= (["seccomp=unconfined", "apparmor=unconfined"] :: [String])
                      , AesonKey.fromString "Tmpfs"
                          Aeson..= Aeson.object
                            [ AesonKey.fromString "/tmp" Aeson..= ("" :: String)
                            , AesonKey.fromString "/run" Aeson..= ("" :: String)
                            ]
                      , AesonKey.fromString "Init" Aeson..= False
                      , AesonKey.fromString "PortBindings"
                          Aeson..= Aeson.object
                            [ AesonKey.fromString "30080/tcp" Aeson..= [portBinding "127.0.0.1" "28080"]
                            , AesonKey.fromString "30443/tcp" Aeson..= [portBinding "127.0.0.1" "28443"]
                            , AesonKey.fromString "6443/tcp" Aeson..= [portBinding "127.0.0.1" "26443"]
                            ]
                      ]
                , AesonKey.fromString "State"
                    Aeson..= Aeson.object
                      [ AesonKey.fromString "Running" Aeson..= True
                      , AesonKey.fromString "Paused" Aeson..= False
                      , AesonKey.fromString "Restarting" Aeson..= False
                      , AesonKey.fromString "Dead" Aeson..= False
                      , AesonKey.fromString "Status" Aeson..= ("running" :: String)
                      ]
                , AesonKey.fromString "Mounts"
                    Aeson..= [ mount "volume" (Just actualVolume) volumeSource "/var" True
                             , mount "bind" Nothing actualRoot "/var/lib/prodbox" True
                             , mount "bind" Nothing "/lib/modules" "/lib/modules" False
                             ]
                , AesonKey.fromString "NetworkSettings"
                    Aeson..= Aeson.object
                      [ AesonKey.fromString "Networks"
                          Aeson..= Aeson.object
                            [ AesonKey.fromString "prodbox-t-run"
                                Aeson..= Aeson.object
                                  [ AesonKey.fromString "NetworkID" Aeson..= actualNetwork
                                  , AesonKey.fromString "IPAddress" Aeson..= ("172.18.0.2" :: String)
                                  , AesonKey.fromString "GlobalIPv6Address" Aeson..= ("fd00::2" :: String)
                                  ]
                            ]
                      ]
                ]
            portBinding address port =
              Aeson.object
                [ AesonKey.fromString "HostIp" Aeson..= (address :: String)
                , AesonKey.fromString "HostPort" Aeson..= (port :: String)
                ]
            changePorts change value = case value of
              Aeson.Object node -> case AesonKeyMap.lookup (AesonKey.fromString "HostConfig") node of
                Just (Aeson.Object host) -> case AesonKeyMap.lookup (AesonKey.fromString "PortBindings") host of
                  Just (Aeson.Object ports) ->
                    Aeson.Object
                      ( AesonKeyMap.insert
                          (AesonKey.fromString "HostConfig")
                          ( Aeson.Object
                              (AesonKeyMap.insert (AesonKey.fromString "PortBindings") (Aeson.Object (change ports)) host)
                          )
                          node
                      )
                  _ -> value
                _ -> value
              _ -> value
            exposeApi =
              changePorts
                (AesonKeyMap.insert (AesonKey.fromString "6443/tcp") (Aeson.toJSON [portBinding "0.0.0.0" "26443"]))
            addForeignPort =
              changePorts
                (AesonKeyMap.insert (AesonKey.fromString "22/tcp") (Aeson.toJSON [portBinding "0.0.0.0" "2222"]))
            publishAllPorts value = case value of
              Aeson.Object node -> case AesonKeyMap.lookup (AesonKey.fromString "HostConfig") node of
                Just (Aeson.Object host) ->
                  Aeson.Object
                    ( AesonKeyMap.insert
                        (AesonKey.fromString "HostConfig")
                        (Aeson.Object (AesonKeyMap.insert (AesonKey.fromString "PublishAllPorts") (Aeson.Bool True) host))
                        node
                    )
                _ -> value
              _ -> value
            mount kind volumeName source target writable =
              Aeson.object
                [ AesonKey.fromString "Type" Aeson..= (kind :: String)
                , AesonKey.fromString "Name" Aeson..= (volumeName :: Maybe String)
                , AesonKey.fromString "Source" Aeson..= (source :: String)
                , AesonKey.fromString "Destination" Aeson..= (target :: String)
                , AesonKey.fromString "RW" Aeson..= (writable :: Bool)
                ]
            addForeignMount value = case value of
              Aeson.Object node -> case AesonKeyMap.lookup (AesonKey.fromString "Mounts") node of
                Just (Aeson.Array mounts) ->
                  Aeson.Object
                    ( AesonKeyMap.insert
                        (AesonKey.fromString "Mounts")
                        (Aeson.Array (mounts <> pure (mount "bind" Nothing "/etc" "/host-etc" True)))
                        node
                    )
                _ -> value
              _ -> value
            inspected = nodeInspect image (replicate 64 'c') name "/var/lib/docker/volumes/example/_data" rootPath
            nodeId = replicate 64 'c'
        withSystemTempDirectory "prodbox-node-intent" $ \intentDirectory -> do
          let intentSocket = intentDirectory </> "docker.sock"
              intentSelected = intentDirectory </> "selected.dhall"
              intentDocument = Text.unpack (Text.replace (Text.pack directory) (Text.pack intentDirectory) (Text.pack document))
          writeFile intentSelected intentDocument
          intentBootstrap <- readBootstrapProjection intentSelected >>= either (fail . show) pure
          prepareFreshScope (bootstrapScope intentBootstrap) generation `shouldReturn` FreshScopePrepared
          let intentRoot = scopeRoot (bootstrapScope intentBootstrap)
              intentArgs =
                map
                  ( \arg ->
                      if arg == "--volume=" ++ rootPath ++ ":/var/lib/prodbox"
                        then "--volume=" ++ intentRoot ++ ":/var/lib/prodbox"
                        else arg
                  )
                  nodeArgs
              selectedInput = nodeInput {nodeCreateArguments = intentArgs}
          let intentNodeBody =
                LazyBS8.toStrict
                  ( Aeson.encode
                      (nodeInspect image (replicate 64 'c') name "/var/lib/docker/volumes/example/_data" intentRoot)
                  )
          withDockerDaemonFixtureControlVolumeAndNode
            intentSocket
            False
            (const (pure ()))
            (pure False)
            ( BS8.pack
                ( "[{\"Id\":\""
                    ++ replicate 64 'c'
                    ++ "\",\"Names\":[\"/prodbox-t-run-control-plane\"],\"Image\":\"example\",\"ImageID\":\"sha256:"
                    ++ replicate 64 'a'
                    ++ "\",\"Command\":\"\",\"Created\":1,\"Ports\":[],\"Labels\":{},\"State\":\"running\",\"Status\":\"Up\",\"HostConfig\":{},\"NetworkSettings\":{\"Networks\":{}},\"Mounts\":[]}]"
                )
            )
            (BS8.pack "[]")
            (pure True)
            Nothing
            (pure (BS8.pack "{\"Volumes\":[],\"Warnings\":[]}"))
            (Just (replicate 64 'c', intentNodeBody))
            $ \_ -> do
              socketIdentity <-
                observeDockerSocketIdentity intentSocket >>= maybe (fail "missing fixture socket") pure
              proposal <-
                maybe
                  (fail "invalid node intent")
                  pure
                  ( mkKindNodeCreateIntent
                      intentBootstrap
                      selectedInput
                      (DockerDaemonObserved "daemon-a" socketIdentity)
                  )
              foreignProposal <-
                maybe
                  (fail "invalid foreign node intent")
                  pure
                  ( mkKindNodeCreateIntent
                      intentBootstrap
                      (selectedInput {nodeCreateNetworkId = replicate 64 'd'})
                      (DockerDaemonObserved "daemon-a" socketIdentity)
                  )
              mkKindNodeCreateIntent
                intentBootstrap
                (selectedInput {nodeCreateGeneration = replicate 32 'e'})
                (DockerDaemonObserved "daemon-a" socketIdentity)
                `shouldBe` Nothing
              withSystemTempDirectory "prodbox-node-foreign-scope" $ \foreignDirectory -> do
                let foreignSelected = foreignDirectory </> "selected.dhall"
                    foreignDocument =
                      Text.unpack (Text.replace (Text.pack directory) (Text.pack foreignDirectory) (Text.pack document))
                writeFile foreignSelected foreignDocument
                foreignBootstrap <- readBootstrapProjection foreignSelected >>= either (fail . show) pure
                prepareFreshScope (bootstrapScope foreignBootstrap) generation `shouldReturn` FreshScopePrepared
                withNewKindOperation
                  foreignBootstrap
                  operation
                  (recordKindNodeCreateIntent foreignBootstrap proposal)
                  `shouldReturn` KindOperationCallbackReturned NodeCreateIntentRefused
                doesFileExist (scopeRoot (bootstrapScope foreignBootstrap) </> "kind-node-create-intent.json")
                  `shouldReturn` False
              recorded <- withNewKindOperation intentBootstrap operation $ \stable -> do
                observeKindNodeCreateIntent intentBootstrap proposal stable `shouldReturn` NodeCreateIntentMissing
                recordKindNodeCreateIntent intentBootstrap proposal (pure False)
                  `shouldReturn` NodeCreateIntentRefused
                recordKindNodeCreateIntent intentBootstrap proposal stable `shouldReturn` NodeCreateIntentRecorded
                observeKindNodeCreateIntent intentBootstrap proposal stable `shouldReturn` NodeCreateIntentMatches
                observeKindNodeCreateIntent intentBootstrap foreignProposal stable
                  `shouldReturn` NodeCreateIntentConflict
                recordKindNodeCreateIntent intentBootstrap proposal stable
                  `shouldReturn` NodeCreateIntentAlreadyExists
                observeRecordedKindNodeCreateIntent intentBootstrap operation stable
                  `shouldReturn` NodeCreateRecoveryRecorded proposal
              recorded `shouldBe` KindOperationCallbackReturned ()
              binary <- resolveBinaryPath
              (statusCode, statusOutput, statusErrors) <-
                readCreateProcessWithExitCode (proc binary ["--config", intentSelected, "control", "status"]) ""
              (statusCode, statusErrors) `shouldBe` (ExitSuccess, "")
              statusOutput
                `shouldContain` "Node create proposal: matches the selected operation and daemon; admission and settlement unverified"
              statusOutput `shouldContain` "node attempt not found locally; effect and settlement unverified"
              withRecoveredKindOperation
                intentBootstrap
                operation
                ( \stable -> do
                    recordKindNodeCreateAttempt intentBootstrap proposal stable `shouldReturn` NodeCreateAttemptRecorded
                    recordKindNodeStartAttempt intentBootstrap proposal (replicate 64 'c') stable
                      `shouldReturn` NodeStartAttemptRefused
                    recordKindNodeCreateResult
                      intentBootstrap
                      proposal
                      (DockerNodeContainerCreateReply 201 (Just (replicate 64 'c')))
                      stable
                      `shouldReturn` NodeCreateResultRecorded
                    recordKindNodeStartAttempt intentBootstrap proposal (replicate 64 'd') stable
                      `shouldReturn` NodeStartAttemptRefused
                    observeKindNodeStartAttempt intentBootstrap proposal (replicate 64 'c') stable
                      `shouldReturn` NodeStartAttemptMissing
                    recordKindNodeStartAttempt intentBootstrap proposal (replicate 64 'c') stable
                      `shouldReturn` NodeStartAttemptRecorded
                    observeKindNodeStartAttempt intentBootstrap proposal (replicate 64 'c') stable
                      `shouldReturn` NodeStartAttemptMatches
                    recordKindNodeStartAttempt intentBootstrap proposal (replicate 64 'c') stable
                      `shouldReturn` NodeStartAttemptAlreadyExists
                )
                `shouldReturn` KindOperationCallbackReturned ()
              (attemptCode, attemptOutput, attemptErrors) <-
                readCreateProcessWithExitCode (proc binary ["--config", intentSelected, "control", "status"]) ""
              (attemptCode, attemptErrors) `shouldBe` (ExitSuccess, "")
              attemptOutput `shouldContain` "node attempt recorded; effect and settlement unverified"
              attemptOutput `shouldContain` "node daemon replied 201; ownership and settlement unverified"
              attemptOutput `shouldContain` "node start attempt recorded; effect and settlement unverified"
              attemptOutput
                `shouldContain` "node start result not found locally; readiness and settlement unverified"
              withRecoveredKindOperation
                intentBootstrap
                operation
                ( recordKindNodeStartResult
                    intentBootstrap
                    proposal
                    (replicate 64 'c')
                    DockerNodeContainerStartUnconfirmed
                )
                `shouldReturn` KindOperationCallbackReturned NodeStartResultRecorded
              (startCode, startOutput, startErrors) <-
                readCreateProcessWithExitCode (proc binary ["--config", intentSelected, "control", "status"]) ""
              (startCode, startErrors) `shouldBe` (ExitSuccess, "")
              startOutput `shouldContain` "node start outcome unconfirmed; readiness and settlement unverified"
              startOutput
                `shouldContain` "node identity, image, network, ports and mounts match; running; ownership and readiness unverified"
              withRecoveredKindOperation
                intentBootstrap
                operation
                ( \stable -> do
                    recordKindNodeRemoveAttempt intentBootstrap proposal (replicate 64 'd') stable
                      `shouldReturn` NodeRemoveAttemptRefused
                    recordKindNodeRemoveAttempt intentBootstrap proposal (replicate 64 'c') stable
                      `shouldReturn` NodeRemoveAttemptRecorded
                    recordKindNodeRemoveResult
                      intentBootstrap
                      proposal
                      (replicate 64 'c')
                      DockerNodeContainerRemoveUnconfirmed
                      stable
                      `shouldReturn` NodeRemoveResultRecorded
                )
                `shouldReturn` KindOperationCallbackReturned ()
              (removeCode, removeOutput, removeErrors) <-
                readCreateProcessWithExitCode (proc binary ["--config", intentSelected, "control", "status"]) ""
              (removeCode, removeErrors) `shouldBe` (ExitSuccess, "")
              removeOutput
                `shouldContain` "node removal positive control recorded; authenticity and settlement unverified"
              removeOutput `shouldContain` "node removal attempt recorded; absence and settlement unverified"
              removeOutput `shouldContain` "node removal outcome unconfirmed; absence and settlement unverified"
              removeOutput
                `shouldContain` "Independent node removal inventory: target listed, 1 name matches, 1 cluster-label matches in repeated reads; absence and settlement unverified"
              let startResultPath = intentRoot </> "kind-node-start-result.json"
              writeFile startResultPath "{\"kind\":1,\"kind\":1}"
              withRecoveredKindOperation
                intentBootstrap
                operation
                (observeKindNodeStartResult intentBootstrap proposal (replicate 64 'c'))
                `shouldReturn` KindOperationCallbackReturned NodeStartResultInvalid
              removeFile startResultPath
              writeFile (intentDirectory </> "foreign-start-result") "foreign"
              createSymbolicLink (intentDirectory </> "foreign-start-result") startResultPath
              withRecoveredKindOperation
                intentBootstrap
                operation
                (observeKindNodeStartResult intentBootstrap proposal (replicate 64 'c'))
                `shouldReturn` KindOperationCallbackReturned NodeStartResultUnobservable
              readFile (intentDirectory </> "foreign-start-result") `shouldReturn` "foreign"
              let startPath = intentRoot </> "kind-node-start-attempt.json"
              writeFile startPath "{\"kind\":1,\"kind\":1}"
              withRecoveredKindOperation
                intentBootstrap
                operation
                (observeKindNodeStartAttempt intentBootstrap proposal (replicate 64 'c'))
                `shouldReturn` KindOperationCallbackReturned NodeStartAttemptInvalid
              removeFile startPath
              writeFile (intentDirectory </> "foreign-start") "foreign"
              createSymbolicLink (intentDirectory </> "foreign-start") startPath
              withRecoveredKindOperation
                intentBootstrap
                operation
                (observeKindNodeStartAttempt intentBootstrap proposal (replicate 64 'c'))
                `shouldReturn` KindOperationCallbackReturned NodeStartAttemptUnobservable
              readFile (intentDirectory </> "foreign-start") `shouldReturn` "foreign"
              let resultPath = intentRoot </> "kind-node-create-result.json"
              writeFile resultPath "{\"kind\":1,\"kind\":1}"
              withRecoveredKindOperation
                intentBootstrap
                operation
                (observeKindNodeCreateResult intentBootstrap proposal)
                `shouldReturn` KindOperationCallbackReturned NodeCreateResultInvalid
              removeFile resultPath
              writeFile (intentDirectory </> "foreign-result") "foreign"
              createSymbolicLink (intentDirectory </> "foreign-result") resultPath
              withRecoveredKindOperation
                intentBootstrap
                operation
                (observeKindNodeCreateResult intentBootstrap proposal)
                `shouldReturn` KindOperationCallbackReturned NodeCreateResultUnobservable
              readFile (intentDirectory </> "foreign-result") `shouldReturn` "foreign"
              let recordPath = intentRoot </> "kind-node-create-intent.json"
              writeFile recordPath "{\"schema_version\":1,\"schema_version\":1}"
              withRecoveredKindOperation
                intentBootstrap
                operation
                (observeRecordedKindNodeCreateIntent intentBootstrap operation)
                `shouldReturn` KindOperationCallbackReturned NodeCreateRecoveryInvalid
              removeFile recordPath
              writeFile (intentDirectory </> "foreign-intent") "foreign"
              createSymbolicLink (intentDirectory </> "foreign-intent") recordPath
              withRecoveredKindOperation
                intentBootstrap
                operation
                (observeRecordedKindNodeCreateIntent intentBootstrap operation)
                `shouldReturn` KindOperationCallbackReturned NodeCreateRecoveryUnobservable
              readFile (intentDirectory </> "foreign-intent") `shouldReturn` "foreign"
        withSystemTempDirectory "prodbox-config-status" $ \statusDirectory -> do
          let statusSocket = statusDirectory </> "docker.sock"
              statusSelected = statusDirectory </> "selected.dhall"
              statusDocument = Text.unpack (Text.replace (Text.pack directory) (Text.pack statusDirectory) (Text.pack document))
          writeFile statusSelected statusDocument
          statusBootstrap <- readBootstrapProjection statusSelected >>= either (fail . show) pure
          prepareFreshScope (bootstrapScope statusBootstrap) generation `shouldReturn` FreshScopePrepared
          let statusRoot = scopeRoot (bootstrapScope statusBootstrap)
              statusArgs =
                map
                  ( \arg ->
                      if arg == "--volume=" ++ rootPath ++ ":/var/lib/prodbox"
                        then "--volume=" ++ statusRoot ++ ":/var/lib/prodbox"
                        else arg
                  )
                  nodeArgs
              statusInput = nodeInput {nodeCreateArguments = statusArgs}
              statusBody =
                LazyBS8.toStrict
                  (Aeson.encode (nodeInspect image nodeId name "/var/lib/docker/volumes/example/_data" statusRoot))
              statusContainers =
                BS8.pack
                  ( "[{\"Id\":\""
                      ++ nodeId
                      ++ "\",\"Names\":[\"/prodbox-t-run-control-plane\"],\"Image\":\"example\",\"ImageID\":\"sha256:"
                      ++ replicate 64 'a'
                      ++ "\",\"Command\":\"\",\"Created\":1,\"Ports\":[],\"Labels\":{},\"State\":\"running\",\"Status\":\"Up\",\"HostConfig\":{},\"NetworkSettings\":{\"Networks\":{}},\"Mounts\":[]}]"
                  )
          withDockerDaemonFixtureControlVolumeAndNode
            statusSocket
            False
            (const (pure ()))
            (pure False)
            statusContainers
            (BS8.pack "[]")
            (pure True)
            Nothing
            (pure (BS8.pack "{\"Volumes\":[],\"Warnings\":[]}"))
            (Just (nodeId, statusBody))
            $ \_ -> do
              identity <- observeDockerSocketIdentity statusSocket >>= maybe (fail "missing status socket") pure
              intent <-
                maybe
                  (fail "invalid status intent")
                  pure
                  (mkKindNodeCreateIntent statusBootstrap statusInput (DockerDaemonObserved "daemon-a" identity))
              withNewKindOperation
                statusBootstrap
                operation
                ( \stable -> do
                    recordKindNodeCreateIntent statusBootstrap intent stable `shouldReturn` NodeCreateIntentRecorded
                    recordKindNodeCreateAttempt statusBootstrap intent stable `shouldReturn` NodeCreateAttemptRecorded
                    recordKindNodeCreateResult
                      statusBootstrap
                      intent
                      (DockerNodeContainerCreateReply 201 (Just nodeId))
                      stable
                      `shouldReturn` NodeCreateResultRecorded
                    recordKindNodeStartAttempt statusBootstrap intent nodeId stable
                      `shouldReturn` NodeStartAttemptRecorded
                    recordKindNodeStartResult statusBootstrap intent nodeId (DockerNodeContainerStartReply 204) stable
                      `shouldReturn` NodeStartResultRecorded
                    recordKindNodeConfigAttempt statusBootstrap intent nodeId stable
                      `shouldReturn` NodeConfigAttemptRecorded
                    recordKindNodeConfigResult statusBootstrap intent nodeId DockerNodeConfigWriteUnconfirmed stable
                      `shouldReturn` NodeConfigResultRecorded
                )
                `shouldReturn` KindOperationCallbackReturned ()
              binary <- resolveBinaryPath
              let checkStatus = do
                    (code, output, errors) <-
                      readCreateProcessWithExitCode (proc binary ["--config", statusSelected, "control", "status"]) ""
                    (code, errors) `shouldBe` (ExitSuccess, "")
                    output `shouldContain` "node configuration attempt recorded; effect and settlement unverified"
                    output `shouldContain` "node configuration write outcome unconfirmed; settlement unverified"
              checkStatus
              let removalMarker = statusRoot </> "kind-node-remove-attempt.json"
              writeFile removalMarker "synthetic conflicting removal"
              setFileMode removalMarker 0o600
              checkStatus
          removeFile statusSocket
          binary <- resolveBinaryPath
          (offlineCode, offlineOutput, offlineErrors) <-
            readCreateProcessWithExitCode (proc binary ["--config", statusSelected, "control", "status"]) ""
          offlineCode `shouldBe` ExitFailure 1
          offlineErrors `shouldContain` "Cannot observe local control:"
          offlineOutput
            `shouldContain` "node configuration attempt recorded; effect and settlement unverified"
          offlineOutput `shouldContain` "node configuration write outcome unconfirmed; settlement unverified"
        parseDockerNodeContainer bootstrap nodeInput nodeId inspected
          `shouldBe` Right (DockerNodeContainerMatching True)
        parseDockerKindNodeAddresses bootstrap nodeInput nodeId inspected
          `shouldBe` Right (BS8.pack "172.18.0.2,fd00::2\n")
        parseDockerKindNodeAddresses bootstrap nodeInput nodeId (exposeApi inspected)
          `shouldSatisfy` isLeft
        let replaceNetwork field replacement value = case value of
              Aeson.Object node ->
                Aeson.Object
                  (adjustKey (modifySettings field replacement) (AesonKey.fromString "NetworkSettings") node)
              _ -> value
            modifySettings field replacement value = case value of
              Aeson.Object settings ->
                Aeson.Object
                  (adjustKey (modifyNetworks field replacement) (AesonKey.fromString "Networks") settings)
              _ -> value
            modifyNetworks field replacement value = case value of
              Aeson.Object networks ->
                Aeson.Object
                  (adjustKey (modifyFields field replacement) (AesonKey.fromString "prodbox-t-run") networks)
              _ -> value
            modifyFields field replacement value = case value of
              Aeson.Object fields ->
                Aeson.Object
                  (AesonKeyMap.insert (AesonKey.fromString field) (Aeson.toJSON (replacement :: String)) fields)
              _ -> value
            adjustKey update key object = case AesonKeyMap.lookup key object of
              Just value -> AesonKeyMap.insert key (update value) object
              Nothing -> object
        parseDockerKindNodeAddresses
          bootstrap
          nodeInput
          nodeId
          (replaceNetwork "IPAddress" "172.18.0.2\nforeign" inspected)
          `shouldSatisfy` isLeft
        parseDockerKindNodeAddresses
          bootstrap
          nodeInput
          nodeId
          (replaceNetwork "GlobalIPv6Address" "172.18.0.2" inspected)
          `shouldSatisfy` isLeft
        parseDockerNodeContainer
          bootstrap
          nodeInput
          nodeId
          ( nodeInspect
              ("sha256:" ++ replicate 64 'd')
              (replicate 64 'c')
              name
              "/var/lib/docker/volumes/example/_data"
              rootPath
          )
          `shouldBe` Right DockerNodeContainerConflict
        parseDockerNodeContainer
          bootstrap
          nodeInput
          nodeId
          (nodeInspect image (replicate 64 'd') name "/var/lib/docker/volumes/example/_data" rootPath)
          `shouldBe` Right DockerNodeContainerConflict
        parseDockerNodeContainer
          bootstrap
          nodeInput
          nodeId
          (nodeInspect image (replicate 64 'c') "foreign" "/var/lib/docker/volumes/example/_data" rootPath)
          `shouldBe` Right DockerNodeContainerConflict
        parseDockerNodeContainer
          bootstrap
          nodeInput
          nodeId
          (nodeInspect image (replicate 64 'c') name "/var/lib/docker/volumes/example/_data" "/foreign")
          `shouldBe` Right DockerNodeContainerConflict
        parseDockerNodeContainer
          bootstrap
          nodeInput
          nodeId
          (nodeInspect image (replicate 64 'c') name "" rootPath)
          `shouldBe` Right DockerNodeContainerConflict
        parseDockerNodeContainer bootstrap nodeInput nodeId (addForeignMount inspected)
          `shouldBe` Right DockerNodeContainerConflict
        parseDockerNodeContainer bootstrap nodeInput nodeId (exposeApi inspected)
          `shouldBe` Right DockerNodeContainerConflict
        parseDockerNodeContainer bootstrap nodeInput nodeId (addForeignPort inspected)
          `shouldBe` Right DockerNodeContainerConflict
        let changeState fields = case inspected of
              Aeson.Object node ->
                Aeson.Object (AesonKeyMap.insert (AesonKey.fromString "State") (Aeson.object fields) node)
              other -> other
            state running paused restarting dead status =
              [ AesonKey.fromString "Running" Aeson..= running
              , AesonKey.fromString "Paused" Aeson..= paused
              , AesonKey.fromString "Restarting" Aeson..= restarting
              , AesonKey.fromString "Dead" Aeson..= dead
              , AesonKey.fromString "Status" Aeson..= (status :: String)
              ]
        mapM_
          ( \fields ->
              parseDockerNodeContainer bootstrap nodeInput nodeId (changeState fields)
                `shouldBe` Right DockerNodeContainerConflict
          )
          [ state True True False False "paused"
          , state True True False False "running"
          , state True False True False "restarting"
          , state True False True False "running"
          , state False False False True "dead"
          , state False False False True "exited"
          , state True False False False "exited"
          , state False False False False "running"
          , state False False False False "removing"
          ]
        parseDockerNodeContainer
          bootstrap
          nodeInput
          nodeId
          (changeState (state False False False False "created"))
          `shouldBe` Right (DockerNodeContainerMatching False)
        -- Real Docker appends label=disable to a privileged container's
        -- options, normalizes NetworkMode to the network ID and leaves a
        -- created container's NetworkID empty until it starts.
        let changeHost key value target = case target of
              Aeson.Object node -> case AesonKeyMap.lookup (AesonKey.fromString "HostConfig") node of
                Just (Aeson.Object host) ->
                  Aeson.Object
                    ( AesonKeyMap.insert
                        (AesonKey.fromString "HostConfig")
                        (Aeson.Object (AesonKeyMap.insert (AesonKey.fromString key) value host))
                        node
                    )
                _ -> target
              _ -> target
            labelDisable =
              changeHost
                "SecurityOpt"
                (Aeson.toJSON (["seccomp=unconfined", "apparmor=unconfined", "label=disable"] :: [String]))
            foreignSecurity =
              changeHost "SecurityOpt" (Aeson.toJSON (["seccomp=unconfined", "label=disable"] :: [String]))
        parseDockerNodeContainer bootstrap nodeInput nodeId (labelDisable inspected)
          `shouldBe` Right (DockerNodeContainerMatching True)
        parseDockerNodeContainer bootstrap nodeInput nodeId (foreignSecurity inspected)
          `shouldBe` Right DockerNodeContainerConflict
        parseDockerNodeContainer
          bootstrap
          nodeInput
          nodeId
          (changeHost "NetworkMode" (Aeson.toJSON (replicate 64 'f')) inspected)
          `shouldBe` Right DockerNodeContainerConflict
        parseDockerNodeContainer
          bootstrap
          nodeInput
          nodeId
          (nodeInspect image "" name "/var/lib/docker/volumes/example/_data" rootPath)
          `shouldBe` Right DockerNodeContainerConflict
        parseDockerNodeContainer
          bootstrap
          nodeInput
          nodeId
          ( case nodeInspect image "" name "/var/lib/docker/volumes/example/_data" rootPath of
              Aeson.Object node ->
                Aeson.Object
                  ( AesonKeyMap.insert
                      (AesonKey.fromString "State")
                      (Aeson.object (state False False False False "created"))
                      node
                  )
              other -> other
          )
          `shouldBe` Right (DockerNodeContainerMatching False)
        parseDockerNodeContainer bootstrap nodeInput nodeId (changeState []) `shouldSatisfy` isLeft
        parseDockerNodeContainer bootstrap nodeInput nodeId (publishAllPorts inspected)
          `shouldBe` Right DockerNodeContainerConflict
        let changeHostField fieldName value = case inspected of
              Aeson.Object node -> case AesonKeyMap.lookup (AesonKey.fromString "HostConfig") node of
                Just (Aeson.Object host) ->
                  Aeson.Object
                    ( AesonKeyMap.insert
                        (AesonKey.fromString "HostConfig")
                        (Aeson.Object (AesonKeyMap.insert (AesonKey.fromString fieldName) value host))
                        node
                    )
                _ -> inspected
              _ -> inspected
        forM_
          [ ("Privileged", Aeson.Bool False)
          , ("CgroupnsMode", Aeson.toJSON ("host" :: String))
          ,
            ( "RestartPolicy"
            , Aeson.object
                [ AesonKey.fromString "Name" Aeson..= ("no" :: String)
                , AesonKey.fromString "MaximumRetryCount" Aeson..= (0 :: Int)
                ]
            )
          , ("SecurityOpt", Aeson.toJSON (["seccomp=unconfined"] :: [String]))
          , ("Tmpfs", Aeson.object [AesonKey.fromString "/tmp" Aeson..= ("" :: String)])
          , ("Init", Aeson.Bool True)
          ]
          $ \(field, value) ->
            parseDockerNodeContainer bootstrap nodeInput nodeId (changeHostField field value)
              `shouldBe` Right DockerNodeContainerConflict
        let missingPrivilege = case inspected of
              Aeson.Object node -> case AesonKeyMap.lookup (AesonKey.fromString "HostConfig") node of
                Just (Aeson.Object host) ->
                  Aeson.Object
                    ( AesonKeyMap.insert
                        (AesonKey.fromString "HostConfig")
                        (Aeson.Object (AesonKeyMap.delete (AesonKey.fromString "Privileged") host))
                        node
                    )
                _ -> inspected
              _ -> inspected
        parseDockerNodeContainer bootstrap nodeInput nodeId missingPrivilege `shouldSatisfy` isLeft
        let missingPorts = case inspected of
              Aeson.Object node -> Aeson.Object (AesonKeyMap.delete (AesonKey.fromString "HostConfig") node)
              value -> value
        parseDockerNodeContainer bootstrap nodeInput nodeId missingPorts `shouldSatisfy` isLeft
        let missingMounts = case inspected of
              Aeson.Object value -> Aeson.Object (AesonKeyMap.delete (AesonKey.fromString "Mounts") value)
              value -> value
        parseDockerNodeContainer bootstrap nodeInput nodeId missingMounts `shouldSatisfy` isLeft
        let changedGeneration = case inspected of
              Aeson.Object node -> case AesonKeyMap.lookup (AesonKey.fromString "Config") node of
                Just (Aeson.Object config) -> case AesonKeyMap.lookup (AesonKey.fromString "Labels") config of
                  Just (Aeson.Object labelsObject) ->
                    Aeson.Object
                      ( AesonKeyMap.insert
                          (AesonKey.fromString "Config")
                          ( Aeson.Object
                              ( AesonKeyMap.insert
                                  (AesonKey.fromString "Labels")
                                  ( Aeson.Object
                                      ( AesonKeyMap.insert
                                          (AesonKey.fromString "io.prodbox.generation")
                                          (Aeson.toJSON (replicate 32 'e'))
                                          labelsObject
                                      )
                                  )
                                  config
                              )
                          )
                          node
                      )
                  _ -> inspected
                _ -> inspected
              _ -> inspected
        parseDockerNodeContainer bootstrap nodeInput nodeId changedGeneration
          `shouldBe` Right DockerNodeContainerConflict
        withDockerNodeInspectFixture socketPath nodeId (Just (LazyBS8.toStrict (Aeson.encode inspected))) $ \requests -> do
          result <- withConnectedDockerInfo 5000000 socketPath $ \session _ _ -> do
            inspectDockerSessionKindNode session bootstrap nodeInput "invalid"
              `shouldReturn` Left DockerConnectedInfoInvalid
            inspectDockerSessionKindNode session bootstrap nodeInput nodeId
              `shouldReturn` Right (DockerNodeContainerMatching True)
          result `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted ())
          request <- takeMVar requests
          request `shouldBe` ("GET /containers/" ++ nodeId ++ "/json HTTP/1.1")
        removeFile socketPath
        withDockerNodeInspectFixture socketPath nodeId Nothing $ \requests -> do
          result <- withConnectedDockerInfo 5000000 socketPath $ \session _ _ -> inspectDockerSessionKindNode session bootstrap nodeInput nodeId
          result
            `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted (Left DockerConnectedInfoStatus))
          void (takeMVar requests)
        removeFile socketPath
        forM_ [False, True] $ \visible ->
          withSystemTempDirectory "prodbox-node-create-uncertain" $ \recoveryDirectory -> do
            let recoverySocket = recoveryDirectory </> "docker.sock"
                recoverySelected = recoveryDirectory </> "selected.dhall"
                recoveryDocument =
                  Text.unpack (Text.replace (Text.pack directory) (Text.pack recoveryDirectory) (Text.pack document))
            writeFile recoverySelected recoveryDocument
            recoveryBootstrap <- readBootstrapProjection recoverySelected >>= either (fail . show) pure
            prepareFreshScope (bootstrapScope recoveryBootstrap) generation `shouldReturn` FreshScopePrepared
            let recoveryRoot = scopeRoot (bootstrapScope recoveryBootstrap)
                recoveryArgs =
                  map
                    ( \arg ->
                        if arg == "--volume=" ++ rootPath ++ ":/var/lib/prodbox"
                          then "--volume=" ++ recoveryRoot ++ ":/var/lib/prodbox"
                          else arg
                    )
                    nodeArgs
                recoveryInput = nodeInput {nodeCreateArguments = recoveryArgs}
                containerId = replicate 64 'c'
                body =
                  LazyBS8.toStrict
                    ( Aeson.encode
                        (nodeInspect image containerId name "/var/lib/docker/volumes/example/_data" recoveryRoot)
                    )
                listing =
                  if visible
                    then
                      BS8.pack
                        ( "[{\"Id\":\""
                            ++ containerId
                            ++ "\",\"Names\":[\"/prodbox-t-run-control-plane\"],\"Image\":\"example\",\"ImageID\":\"sha256:"
                            ++ replicate 64 'a'
                            ++ "\",\"Command\":\"\",\"Created\":1,\"Ports\":[],\"Labels\":{},\"State\":\"running\",\"Status\":\"Up\",\"HostConfig\":{},\"NetworkSettings\":{\"Networks\":{}},\"Mounts\":[]}]"
                        )
                    else BS8.pack "[]"
            withDockerDaemonFixtureControlVolumeAndNode
              recoverySocket
              False
              (const (pure ()))
              (pure False)
              listing
              (BS8.pack "[]")
              (pure True)
              Nothing
              (pure (BS8.pack "{\"Volumes\":[],\"Warnings\":[]}"))
              (Just (containerId, body))
              $ \_ -> do
                socketIdentity <- observeDockerSocketIdentity recoverySocket >>= maybe (fail "missing socket") pure
                proposal <-
                  maybe
                    (fail "invalid node intent")
                    pure
                    ( mkKindNodeCreateIntent
                        recoveryBootstrap
                        recoveryInput
                        (DockerDaemonObserved "daemon-a" socketIdentity)
                    )
                withNewKindOperation
                  recoveryBootstrap
                  operation
                  ( \stable -> do
                      recordKindNodeCreateIntent recoveryBootstrap proposal stable `shouldReturn` NodeCreateIntentRecorded
                      recordKindNodeCreateAttempt recoveryBootstrap proposal stable
                        `shouldReturn` NodeCreateAttemptRecorded
                      recordKindNodeCreateResult recoveryBootstrap proposal DockerNodeContainerCreateUnconfirmed stable
                        `shouldReturn` NodeCreateResultRecorded
                  )
                  `shouldReturn` KindOperationCallbackReturned ()
                binary <- resolveBinaryPath
                (code, output, errors) <-
                  readCreateProcessWithExitCode (proc binary ["--config", recoverySelected, "control", "status"]) ""
                (code, errors) `shouldBe` (ExitSuccess, "")
                if visible
                  then
                    output
                      `shouldContain` ( "Unconfirmed node candidate: candidate "
                                          ++ containerId
                                          ++ "; node identity, image, network, ports and mounts match"
                                      )
                  else
                    output
                      `shouldContain` "Unconfirmed node candidate: no candidate sampled; absence and settlement unverified"
                output `shouldContain` "node request outcome unconfirmed; settlement unverified"
                let candidatePath = recoveryRoot </> "kind-node-create-candidate.json"
                    createResultPath = recoveryRoot </> "kind-node-create-result.json"
                originalResult <- BS8.readFile createResultPath
                if visible
                  then do
                    withNewConnectedKindNodeCandidate recoveryBootstrap operation (replicate 64 'd')
                      `shouldReturn` KindOperationCallbackReturned
                        ( DockerPeerCompleted
                            (DockerConnectedInfoCompleted (NodeCandidateActionInspectionRefused (Left DockerConnectedInfoStatus)))
                        )
                    doesFileExist candidatePath `shouldReturn` False
                    withNewConnectedKindNodeCandidate recoveryBootstrap operation containerId
                      `shouldReturn` KindOperationCallbackReturned
                        ( DockerPeerCompleted
                            (DockerConnectedInfoCompleted (NodeCandidateActionReturned NodeCandidateRecorded))
                        )
                    withRecoveredKindOperation
                      recoveryBootstrap
                      operation
                      (observeRecordedKindNodeCandidate recoveryBootstrap proposal)
                      `shouldReturn` KindOperationCallbackReturned (NodeCandidateRecordObserved containerId)
                    withNewConnectedKindNodeCandidate recoveryBootstrap operation containerId
                      `shouldReturn` KindOperationCallbackReturned
                        ( DockerPeerCompleted
                            (DockerConnectedInfoCompleted (NodeCandidateActionReturned NodeCandidateAlreadyExists))
                        )
                    withRecoveredKindOperation
                      recoveryBootstrap
                      operation
                      (\stable -> recordKindNodeCandidate recoveryBootstrap proposal (replicate 64 'd') stable)
                      `shouldReturn` KindOperationCallbackReturned NodeCandidateRefused
                    (recordCode, recordOutput, recordErrors) <-
                      readCreateProcessWithExitCode (proc binary ["--config", recoverySelected, "control", "status"]) ""
                    (recordCode, recordErrors) `shouldBe` (ExitSuccess, "")
                    recordOutput
                      `shouldContain` ( "Recorded unconfirmed node candidate: candidate "
                                          ++ containerId
                                          ++ " recorded; ownership and settlement unverified"
                                      )
                    writeFile candidatePath "{\"container_id\":1,\"container_id\":1}"
                    withRecoveredKindOperation
                      recoveryBootstrap
                      operation
                      (observeRecordedKindNodeCandidate recoveryBootstrap proposal)
                      `shouldReturn` KindOperationCallbackReturned NodeCandidateRecordInvalid
                  else do
                    withNewConnectedKindNodeCandidate recoveryBootstrap operation containerId
                      `shouldReturn` KindOperationCallbackReturned
                        ( DockerPeerCompleted
                            ( DockerConnectedInfoCompleted
                                ( NodeCandidateActionReturned
                                    (NodeCandidatePositiveControlRefused (NodeRemovalReadbackSampled (NodeRemovalInventory False [] [])))
                                )
                            )
                        )
                    doesFileExist candidatePath `shouldReturn` False
                BS8.readFile createResultPath `shouldReturn` originalResult

        withSystemTempDirectory "prodbox-node-submission" $ \nodeDirectory -> do
          let nodeSocket = nodeDirectory </> "docker.sock"
              nodeSelected = nodeDirectory </> "selected.dhall"
              nodeDocument = Text.unpack (Text.replace (Text.pack directory) (Text.pack nodeDirectory) (Text.pack document))
          writeFile nodeSelected nodeDocument
          nodeBootstrap <- readBootstrapProjection nodeSelected >>= either (fail . show) pure
          let workerEnvironment = kindNodeWorkerEnvironment nodeBootstrap operation
              pair key value = AesonKey.fromString key Aeson..= (value :: String)
              doc api kind extra = Aeson.object (pair "apiVersion" api : pair "kind" kind : extra)
              cluster =
                doc
                  "kubeadm.k8s.io/v1beta3"
                  "ClusterConfiguration"
                  [ pair "clusterName" "prodbox-t-run"
                  , pair "kubernetesVersion" "v1.30.0"
                  , pair "controlPlaneEndpoint" "prodbox-t-run-control-plane:6443"
                  , AesonKey.fromString "networking"
                      Aeson..= Aeson.object [pair "podSubnet" "10.244.0.0/16", pair "serviceSubnet" "10.96.0.0/16"]
                  ]
              initial =
                doc
                  "kubeadm.k8s.io/v1beta3"
                  "InitConfiguration"
                  [ AesonKey.fromString "localAPIEndpoint"
                      Aeson..= Aeson.object
                        [pair "advertiseAddress" "172.18.0.2", AesonKey.fromString "bindPort" Aeson..= (6443 :: Int)]
                  ]
              projections =
                [ cluster
                , initial
                , doc "kubeadm.k8s.io/v1beta3" "JoinConfiguration" []
                , doc "kubelet.config.k8s.io/v1beta1" "KubeletConfiguration" []
                , doc "kubeproxy.config.k8s.io/v1alpha1" "KubeProxyConfiguration" []
                ]
              matches =
                matchesKindKubeadmScope
                  (bootstrapScope nodeBootstrap)
                  (Text.pack "172.18.0.2")
                  (Text.pack "v1.30.0")
              foreignCluster = case cluster of
                Aeson.Object fields ->
                  Aeson.Object
                    (AesonKeyMap.insert (AesonKey.fromString "clusterName") (Aeson.toJSON ("foreign" :: String)) fields)
                other -> other
          matches projections `shouldBe` True
          matchesPinnedKindKubeadmConfig
            (bootstrapScope nodeBootstrap)
            (Text.pack "172.18.0.2")
            (Text.pack "v1.30.0")
            (Text.pack "systemd")
            projections
            `shouldBe` False
          let syntheticConfig =
                BS8.pack $
                  unlines
                    [ "apiVersion: kubeadm.k8s.io/v1beta3"
                    , "kind: ClusterConfiguration"
                    , "clusterName: prodbox-t-run"
                    , "kubernetesVersion: v1.30.0"
                    , "controlPlaneEndpoint: prodbox-t-run-control-plane:6443"
                    , "networking: {podSubnet: 10.244.0.0/16, serviceSubnet: 10.96.0.0/16}"
                    , "apiServer: {certSANs: [localhost, 127.0.0.1], extraArgs: {runtime-config: ''}}"
                    , "controllerManager: {extraArgs: {enable-hostpath-provisioner: 'true'}}"
                    , "scheduler: {extraArgs: null}"
                    , "---"
                    , "apiVersion: kubeadm.k8s.io/v1beta3"
                    , "kind: InitConfiguration"
                    , "bootstrapTokens: [{token: aaaaaa.bbbbbbbbbbbbbbbb}]"
                    , "localAPIEndpoint: {advertiseAddress: 172.18.0.2, bindPort: 6443}"
                    , "nodeRegistration: {criSocket: 'unix:///run/containerd/containerd.sock', kubeletExtraArgs: {node-ip: 172.18.0.2, node-labels: '', provider-id: 'kind://docker/prodbox-t-run/prodbox-t-run-control-plane'}}"
                    , "skipPhases: [preflight]"
                    , "---"
                    , "apiVersion: kubeadm.k8s.io/v1beta3"
                    , "kind: JoinConfiguration"
                    , "controlPlane: {localAPIEndpoint: {advertiseAddress: 172.18.0.2, bindPort: 6443}}"
                    , "discovery: {bootstrapToken: {apiServerEndpoint: 'prodbox-t-run-control-plane:6443', token: aaaaaa.bbbbbbbbbbbbbbbb, unsafeSkipCAVerification: true}}"
                    , "nodeRegistration: {criSocket: 'unix:///run/containerd/containerd.sock', kubeletExtraArgs: {node-ip: 172.18.0.2, node-labels: '', provider-id: 'kind://docker/prodbox-t-run/prodbox-t-run-control-plane'}}"
                    , "skipPhases: [preflight]"
                    , "---"
                    , "apiVersion: kubelet.config.k8s.io/v1beta1"
                    , "kind: KubeletConfiguration"
                    , "cgroupDriver: systemd"
                    , "cgroupRoot: /kubelet"
                    , "evictionHard: {imagefs.available: '0%', nodefs.available: '0%', nodefs.inodesFree: '0%'}"
                    , "failSwapOn: false"
                    , "imageGCHighThresholdPercent: 100"
                    , "---"
                    , "apiVersion: kubeproxy.config.k8s.io/v1alpha1"
                    , "kind: KubeProxyConfiguration"
                    , "conntrack: {maxPerCore: 0}"
                    , "iptables: {minSyncPeriod: 1s}"
                    , "mode: iptables"
                    ]
              exact =
                matchesPinnedKindKubeadmConfig
                  (bootstrapScope nodeBootstrap)
                  (Text.pack "172.18.0.2")
                  (Text.pack "v1.30.0")
                  (Text.pack "systemd")
          parsedConfig <- decodeBoundedYamlDocuments syntheticConfig
          case parsedConfig of
            Right docs@(first : remaining) -> do
              exact docs `shouldBe` True
              let altered = case first of
                    Aeson.Object fields -> Aeson.Object (AesonKeyMap.insert (AesonKey.fromString "extraVolumes") Aeson.Null fields)
                    other -> other
              exact (altered : remaining) `shouldBe` False
              case docs of
                [firstDoc, initDoc, joinDoc, kubeletDoc, proxyDoc] -> do
                  let update key change value = case value of
                        Aeson.Object fields -> case AesonKeyMap.lookup (AesonKey.fromString key) fields of
                          Just field -> Aeson.Object (AesonKeyMap.insert (AesonKey.fromString key) (change field) fields)
                          Nothing -> value
                        _ -> value
                      changedToken =
                        update
                          "discovery"
                          ( update
                              "bootstrapToken"
                              (update "token" (const (Aeson.toJSON ("cccccc.dddddddddddddddd" :: String))))
                          )
                          joinDoc
                  exact [firstDoc, initDoc, changedToken, kubeletDoc, proxyDoc] `shouldBe` False
                _ -> fail "unexpected kubeadm document count"
              matchesPinnedKindKubeadmConfig
                (bootstrapScope nodeBootstrap)
                (Text.pack "172.18.0.2")
                (Text.pack "v1.30.0")
                (Text.pack "wrong")
                docs
                `shouldBe` False
            _ -> fail "synthetic kubeadm documents refused"
          matches (reverse projections) `shouldBe` False
          matches (drop 1 projections) `shouldBe` False
          matches (foreignCluster : drop 1 projections) `shouldBe` False
          matchesKindKubeadmScope
            (bootstrapScope nodeBootstrap)
            (Text.pack "172.18.0.3")
            (Text.pack "v1.30.0")
            projections
            `shouldBe` False
          matchesKindKubeadmScope
            (bootstrapScope nodeBootstrap)
            (Text.pack "172.18.0.2")
            (Text.pack "v1.31.0")
            projections
            `shouldBe` False
          lookup "KIND_EXPERIMENTAL_DOCKER_NETWORK" workerEnvironment `shouldBe` Just "prodbox-t-run"
          lookup "KIND_EXPERIMENTAL_PROVIDER" workerEnvironment `shouldBe` Just "docker"
          lookup "DOCKER_HOST" workerEnvironment `shouldBe` Nothing
          length (filter ((== "KIND_EXPERIMENTAL_DOCKER_NETWORK") . fst) workerEnvironment) `shouldBe` 1
          prepareFreshScope (bootstrapScope nodeBootstrap) generation `shouldReturn` FreshScopePrepared
          let selectedRoot = scopeRoot (bootstrapScope nodeBootstrap)
              selectedArgs =
                map
                  ( \arg ->
                      if arg == "--volume=" ++ rootPath ++ ":/var/lib/prodbox"
                        then "--volume=" ++ selectedRoot ++ ":/var/lib/prodbox"
                        else arg
                  )
                  nodeArgs
              selectedInput = nodeInput {nodeCreateArguments = selectedArgs}
              nodeBody =
                LazyBS8.toStrict $
                  Aeson.encode $
                    nodeInspect image (replicate 64 'c') name "/var/lib/docker/volumes/example/_data" selectedRoot
          withDockerNodeRunFixture nodeSocket nodeBody $ \requests -> do
            socketIdentity <-
              observeDockerSocketIdentity nodeSocket >>= maybe (fail "missing fixture socket") pure
            proposal <-
              maybe
                (fail "invalid node intent")
                pure
                (mkKindNodeCreateIntent nodeBootstrap selectedInput (DockerDaemonObserved "daemon-a" socketIdentity))
            withNewKindOperation
              nodeBootstrap
              operation
              ( \stable -> do
                  recordKindNodeCreateIntent nodeBootstrap proposal stable `shouldReturn` NodeCreateIntentRecorded
                  recordKindNodeConfigAttempt nodeBootstrap proposal (replicate 64 'c') stable
                    `shouldReturn` NodeConfigAttemptRefused
                  recordKindNodeConfigResult
                    nodeBootstrap
                    proposal
                    (replicate 64 'c')
                    DockerNodeConfigWriteUnconfirmed
                    stable
                    `shouldReturn` NodeConfigResultRefused
                  prepareKindDockerWorkerPaths nodeBootstrap operation stable
              )
              `shouldReturn` KindOperationCallbackReturned KindDockerWorkerPrepared
            let unavailable = error "node preflight evaluated an unavailable capability"
            preflight <-
              runConfinedKindNodeOnHost
                unavailable
                unavailable
                unavailable
                nodeBootstrap
                operation
                []
                unavailable
                unavailable
                unavailable
                unavailable
                unavailable
                (pure True)
                unavailable
                unavailable
            case preflight of
              KindOperationCallbackReturned (KindDockerEndpointObserved ConfinedNodeToolMismatch) -> pure ()
              other -> fail ("undeclared kind tool was not refused: " ++ show other)
            verified <-
              runVerifiedConfinedKindNodeOnHost
                unavailable
                unavailable
                unavailable
                nodeBootstrap
                operation
                "unused"
                1
                []
                unavailable
                unavailable
                unavailable
                (pure True)
                unavailable
                unavailable
            case verified of
              ConfinedKindNotDeclared -> pure ()
              other -> fail ("verified node path accepted an undeclared tool: " ++ show other)
            let admit candidate _ _ = pure (candidate == proposal)
                admitStart candidate actual _ _ = pure (candidate == proposal && actual == replicate 64 'c')
            result <- withRecoveredKindOperation nodeBootstrap operation $ \operationStable ->
              withConnectedDockerInfo 30000000 nodeSocket $ \session info peerStable -> do
                let stable = (&&) <$> operationStable <*> peerStable
                    newBroker = do
                      Just broker <- newKindNodeBroker nodeBootstrap operation session info stable admit admitStart
                      pure broker
                fresh <- newIORef True
                Just stale <-
                  newKindNodeBroker
                    nodeBootstrap
                    operation
                    session
                    info
                    ((&&) <$> stable <*> readIORef fresh)
                    admit
                    admitStart
                writeIORef fresh False
                staleReply <- runKindNodeBrokerRequest stale selectedArgs
                kindDockerReplyExit staleReply `shouldBe` 1
                observeKindNodeBrokerResult stale `shouldReturn` Nothing
                bad <- newBroker
                badReply <- runKindNodeBrokerRequest bad (selectedArgs ++ ["foreign"])
                kindDockerReplyExit badReply `shouldBe` 1
                observeKindNodeBrokerResult bad `shouldReturn` Just NodeRunArgumentsRefused
                runKindNodeBrokerRequest bad selectedArgs `shouldReturn` badReply
                premature <- newBroker
                prematureReply <- runKindNodeBrokerRequest premature ["logs", "-f", "prodbox-t-run-control-plane"]
                kindDockerReplyExit prematureReply `shouldBe` 1
                observeKindNodeBrokerResult premature `shouldReturn` Nothing
                let copyArguments =
                      [ "exec"
                      , "--privileged"
                      , "-i"
                      , "prodbox-t-run-control-plane"
                      , "cp"
                      , "/dev/stdin"
                      , "/kind/kubeadm.conf"
                      ]
                earlyInput <- newBroker
                earlyReply <- runKindNodeBrokerInput earlyInput (KindDockerRequest copyArguments syntheticConfig)
                kindDockerReplyExit earlyReply `shouldBe` 1
                observeKindNodeBrokerConfigCandidate earlyInput `shouldReturn` Just NodeConfigCandidateUnobservable
                foreignInput <- newBroker
                foreignReply <-
                  runKindNodeBrokerInput
                    foreignInput
                    (KindDockerRequest (copyArguments ++ ["foreign"]) syntheticConfig)
                kindDockerReplyExit foreignReply `shouldBe` 1
                observeKindNodeBrokerConfigCandidate foreignInput `shouldReturn` Just NodeConfigCandidateRejected
                broker <- newBroker
                held <- withScopeRootDescriptor (bootstrapScope nodeBootstrap) $ \root sameRoot ->
                  withKindDockerWorkerRoots root operation ((&&) <$> stable <*> sameRoot) $ \roots rootsStable -> do
                    outcome <- newEmptyMVar
                    bracket
                      (forkIO (try (serveKindNodeBroker (workerBridge roots) rootsStable broker) >>= putMVar outcome))
                      killThread
                      $ \_ -> do
                        exchangeBoundKindDockerRead 10000000 (workerBridge roots) rootsStable selectedArgs
                          `shouldReturn` KindDockerEndpointObserved
                            (Right (KindDockerReply 0 (BS8.pack (replicate 64 'c' ++ "\n")) BS8.empty))
                        (PosixFiles.fileSize <$> PosixFiles.getFdStatus (workerLock roots)) `shouldReturn` 0
                        exchangeBoundKindDockerRead
                          10000000
                          (workerBridge roots)
                          rootsStable
                          ["logs", "-f", "prodbox-t-run-control-plane"]
                          `shouldReturn` KindDockerEndpointObserved
                            (Right (KindDockerReply 0 (BS8.pack "Reached target Multi-User System\n") BS8.empty))
                        exchangeBoundKindDockerRead
                          10000000
                          (workerBridge roots)
                          rootsStable
                          [ "inspect"
                          , "--format"
                          , "{{ index .Config.Labels \"io.x-k8s.kind.role\"}}"
                          , "prodbox-t-run-control-plane"
                          ]
                          `shouldReturn` KindDockerEndpointObserved (Right (KindDockerReply 0 (BS8.pack "control-plane\n") BS8.empty))
                        exchangeBoundKindDockerRead
                          10000000
                          (workerBridge roots)
                          rootsStable
                          ["exec", "--privileged", "prodbox-t-run-control-plane", "cat", "/kind/version"]
                          `shouldReturn` KindDockerEndpointObserved (Right (KindDockerReply 0 (BS8.pack "v1.30.0\n") BS8.empty))
                        exchangeBoundKindDockerRead
                          10000000
                          (workerBridge roots)
                          rootsStable
                          [ "inspect"
                          , "-f"
                          , "{{range .NetworkSettings.Networks}}{{.IPAddress}},{{.GlobalIPv6Address}}{{end}}"
                          , "prodbox-t-run-control-plane"
                          ]
                          `shouldReturn` KindDockerEndpointObserved (Right (KindDockerReply 0 (BS8.pack "172.18.0.2,fd00::2\n") BS8.empty))
                        exchangeBoundKindDockerRead
                          10000000
                          (workerBridge roots)
                          rootsStable
                          ["exec", "--privileged", "prodbox-t-run-control-plane", "mkdir", "-p", "/kind"]
                          `shouldReturn` KindDockerEndpointObserved (Right (KindDockerReply 0 BS.empty BS.empty))
                        observeKindNodeConfigAttempt nodeBootstrap proposal (replicate 64 'c') rootsStable
                          `shouldReturn` NodeConfigAttemptMissing
                        recordKindNodeConfigAttempt nodeBootstrap proposal (replicate 64 'c') rootsStable
                          `shouldReturn` NodeConfigAttemptRecorded
                        observeKindNodeConfigAttempt nodeBootstrap proposal (replicate 64 'c') rootsStable
                          `shouldReturn` NodeConfigAttemptMatches
                        observeKindNodeConfigResult nodeBootstrap proposal (replicate 64 'c') rootsStable
                          `shouldReturn` NodeConfigResultMissing
                        recordKindNodeConfigResult
                          nodeBootstrap
                          proposal
                          (replicate 64 'c')
                          (DockerNodeConfigWriteReply 99)
                          rootsStable
                          `shouldReturn` NodeConfigResultRefused
                        recordKindNodeConfigResult
                          nodeBootstrap
                          proposal
                          (replicate 64 'c')
                          DockerNodeConfigWriteUnconfirmed
                          rootsStable
                          `shouldReturn` NodeConfigResultRecorded
                        observeKindNodeConfigResult nodeBootstrap proposal (replicate 64 'c') rootsStable
                          `shouldReturn` NodeConfigResultObserved DockerNodeConfigWriteUnconfirmed
                        recordKindNodeConfigResult
                          nodeBootstrap
                          proposal
                          (replicate 64 'c')
                          (DockerNodeConfigWriteReply 200)
                          rootsStable
                          `shouldReturn` NodeConfigResultAlreadyExists
                        let removalMarker = selectedRoot </> "kind-node-remove-attempt.json"
                        writeFile removalMarker "synthetic conflicting removal"
                        setFileMode removalMarker 0o600
                        observeKindNodeConfigAttempt nodeBootstrap proposal (replicate 64 'c') rootsStable
                          `shouldReturn` NodeConfigAttemptMatches
                        observeKindNodeConfigResult nodeBootstrap proposal (replicate 64 'c') rootsStable
                          `shouldReturn` NodeConfigResultObserved DockerNodeConfigWriteUnconfirmed
                        recordKindNodeConfigAttempt nodeBootstrap proposal (replicate 64 'c') rootsStable
                          `shouldReturn` NodeConfigAttemptRefused
                        removeFile removalMarker
                        recordKindNodeConfigAttempt nodeBootstrap proposal (replicate 64 'c') rootsStable
                          `shouldReturn` NodeConfigAttemptAlreadyExists
                        recordKindNodeConfigAttempt nodeBootstrap proposal (replicate 64 'd') rootsStable
                          `shouldReturn` NodeConfigAttemptRefused
                        denied <-
                          exchangeBoundKindDockerRequest
                            10000000
                            (workerBridge roots)
                            rootsStable
                            ( KindDockerRequest
                                [ "exec"
                                , "--privileged"
                                , "-i"
                                , "prodbox-t-run-control-plane"
                                , "cp"
                                , "/dev/stdin"
                                , "/kind/kubeadm.conf"
                                ]
                                syntheticConfig
                            )
                        case denied of
                          KindDockerEndpointObserved (Right reply) -> kindDockerReplyExit reply `shouldBe` 1
                          other -> fail (show other)
                        observeKindNodeBrokerConfigCandidate broker `shouldReturn` Just NodeConfigCandidateMatches
                        completed <- timeout 3000000 (takeMVar outcome)
                        case completed :: Maybe (Either SomeException (KindDockerEndpointResult KindDockerProtocolOutcome)) of
                          Just (Right (KindDockerEndpointObserved KindDockerProtocolRejected)) -> pure ()
                          _ -> fail "broker did not settle after refusal"
                        (PosixFiles.fileSize <$> PosixFiles.getFdStatus (workerLock roots)) `shouldReturn` 1
                        observeKindNodeBrokerResult broker
                case held of
                  Right (KindDockerEndpointObserved value) -> pure value
                  other -> fail ("worker roots unavailable: " ++ show other)
            result
              `shouldBe` KindOperationCallbackReturned
                ( DockerPeerCompleted
                    ( DockerConnectedInfoCompleted
                        ( Just $
                            NodeRunStartObserved
                              ( NodeCreateActionReturned
                                  (DockerNodeContainerCreateReply 201 (Just (replicate 64 'c')))
                                  NodeCreateResultRecorded
                              )
                              (NodeStartActionReturned (DockerNodeContainerStartReply 204) NodeStartResultRecorded)
                        )
                    )
                )
            takeMVar requests `shouldReturn` ("POST /containers/" ++ replicate 64 'c' ++ "/start HTTP/1.1")
            withRecoveredKindOperation
              nodeBootstrap
              operation
              (observeKindNodeCreateAttempt nodeBootstrap proposal)
              `shouldReturn` KindOperationCallbackReturned NodeCreateAttemptMatches
            withRecoveredKindOperation
              nodeBootstrap
              operation
              (observeKindNodeCreateResult nodeBootstrap proposal)
              `shouldReturn` KindOperationCallbackReturned
                (NodeCreateResultObserved (DockerNodeContainerCreateReply 201 (Just (replicate 64 'c'))))
          forM_ [(False, False), (True, False), (False, True)] $ \(lostReply, wrongReadback) -> withSystemTempDirectory "prodbox-config-action" $ \actionDirectory -> do
            let actionSocket = actionDirectory </> "docker.sock"
                actionSelected = actionDirectory </> "selected.dhall"
                actionDocument = Text.unpack (Text.replace (Text.pack directory) (Text.pack actionDirectory) (Text.pack document))
            writeFile actionSelected actionDocument
            actionBootstrap <- readBootstrapProjection actionSelected >>= either (fail . show) pure
            prepareFreshScope (bootstrapScope actionBootstrap) generation `shouldReturn` FreshScopePrepared
            let actionRoot = scopeRoot (bootstrapScope actionBootstrap)
                actionArgs =
                  map
                    ( \arg ->
                        if arg == "--volume=" ++ rootPath ++ ":/var/lib/prodbox"
                          then "--volume=" ++ actionRoot ++ ":/var/lib/prodbox"
                          else arg
                    )
                    nodeArgs
                actionInput = nodeInput {nodeCreateArguments = actionArgs}
                actionBody =
                  LazyBS8.toStrict $
                    Aeson.encode $
                      nodeInspect image (replicate 64 'c') name "/var/lib/docker/volumes/example/_data" actionRoot
            withDockerNodeRunFixtureMode actionSocket actionBody lostReply wrongReadback $ \actionRequests -> do
              actionIdentity <-
                observeDockerSocketIdentity actionSocket >>= maybe (fail "missing action socket") pure
              actionIntent <-
                maybe
                  (fail "invalid action intent")
                  pure
                  (mkKindNodeCreateIntent actionBootstrap actionInput (DockerDaemonObserved "daemon-a" actionIdentity))
              withNewKindOperation
                actionBootstrap
                operation
                ( \stable -> do
                    recordKindNodeCreateIntent actionBootstrap actionIntent stable
                      `shouldReturn` NodeCreateIntentRecorded
                    prepareKindDockerWorkerPaths actionBootstrap operation stable
                )
                `shouldReturn` KindOperationCallbackReturned KindDockerWorkerPrepared
              actionOutcome <- withRecoveredKindOperation actionBootstrap operation $ \operationStable ->
                withConnectedDockerInfo 60000000 actionSocket $ \session info peerStable -> do
                  let stable = (&&) <$> operationStable <*> peerStable
                      admitCreate candidate _ _ = pure (candidate == actionIntent)
                      admitNode candidate actual _ _ = pure (candidate == actionIntent && actual == replicate 64 'c')
                      copyArgs =
                        [ "exec"
                        , "--privileged"
                        , "-i"
                        , "prodbox-t-run-control-plane"
                        , "cp"
                        , "/dev/stdin"
                        , "/kind/kubeadm.conf"
                        ]
                  Just configBroker <-
                    newKindNodeBrokerWithConfig
                      actionBootstrap
                      operation
                      session
                      info
                      stable
                      admitCreate
                      admitNode
                      admitNode
                  started <- runKindNodeBrokerRequest configBroker actionArgs
                  kindDockerReplyExit started `shouldBe` 0
                  previous <- observeKindNodeBrokerResult configBroker
                  denied <-
                    runKindNodeConfigOnSession
                      actionBootstrap
                      operation
                      session
                      info
                      stable
                      previous
                      copyArgs
                      syntheticConfig
                      (\_ _ _ _ -> pure False)
                  denied `shouldBe` NodeConfigActionAdmissionRefused
                  observeKindNodeConfigAttempt actionBootstrap actionIntent (replicate 64 'c') stable
                    `shouldReturn` NodeConfigAttemptMissing
                  bridge <- withScopeRootDescriptor (bootstrapScope actionBootstrap) $ \root sameRoot ->
                    withKindDockerWorkerRoots root operation ((&&) <$> stable <*> sameRoot) $ \roots rootsStable -> do
                      completed <- newEmptyMVar
                      bracket
                        ( forkIO
                            (try (serveKindNodeBroker (workerBridge roots) rootsStable configBroker) >>= putMVar completed)
                        )
                        killThread
                        $ \_ -> do
                          first <-
                            exchangeBoundKindDockerRequest
                              20000000
                              (workerBridge roots)
                              rootsStable
                              (KindDockerRequest copyArgs syntheticConfig)
                          case first of
                            KindDockerEndpointObserved (Right reply) -> kindDockerReplyExit reply `shouldBe` (if lostReply || wrongReadback then 1 else 0)
                            other -> fail (show other)
                          written <- observeKindNodeBrokerConfigAction configBroker
                          if lostReply
                            then do
                              written
                                `shouldBe` Just (NodeConfigActionChangedAfter DockerNodeConfigWriteUnconfirmed NodeConfigResultRecorded)
                              observeKindNodeConfigResult actionBootstrap actionIntent (replicate 64 'c') stable
                                `shouldReturn` NodeConfigResultObserved DockerNodeConfigWriteUnconfirmed
                            else
                              if wrongReadback
                                then do
                                  written
                                    `shouldBe` Just
                                      ( NodeConfigActionReturned
                                          (DockerNodeConfigWriteReply 200)
                                          NodeConfigResultRecorded
                                          (Just (Right DockerNodeConfigDiffers))
                                      )
                                  observeKindNodeConfigResult actionBootstrap actionIntent (replicate 64 'c') stable
                                    `shouldReturn` NodeConfigResultObserved (DockerNodeConfigWriteReply 200)
                                else do
                                  written
                                    `shouldBe` Just
                                      ( NodeConfigActionReturned
                                          (DockerNodeConfigWriteReply 200)
                                          NodeConfigResultRecorded
                                          (Just (Right DockerNodeConfigMatches))
                                      )
                                  observeKindNodeConfigResult actionBootstrap actionIntent (replicate 64 'c') stable
                                    `shouldReturn` NodeConfigResultObserved (DockerNodeConfigWriteReply 200)
                                  repeated <-
                                    exchangeBoundKindDockerRequest
                                      20000000
                                      (workerBridge roots)
                                      rootsStable
                                      (KindDockerRequest copyArgs syntheticConfig)
                                  case repeated of
                                    KindDockerEndpointObserved (Right reply) -> kindDockerReplyExit reply `shouldBe` 1
                                    other -> fail (show other)
                                  observeKindNodeBrokerConfigAction configBroker
                                    `shouldReturn` Just (NodeConfigActionAttemptRefused NodeConfigAttemptAlreadyExists)
                          observed <- timeout 3000000 (takeMVar completed)
                          case observed :: Maybe (Either SomeException (KindDockerEndpointResult KindDockerProtocolOutcome)) of
                            Just (Right (KindDockerEndpointObserved KindDockerProtocolRejected)) -> pure ()
                            _ -> fail "config broker did not settle after refusal"
                          (PosixFiles.fileSize <$> PosixFiles.getFdStatus (workerLock roots)) `shouldReturn` 1
                  case bridge of
                    Right (KindDockerEndpointObserved ()) -> pure ()
                    other -> fail ("config bridge unavailable: " ++ show other)
              actionOutcome
                `shouldBe` KindOperationCallbackReturned (DockerPeerCompleted (DockerConnectedInfoCompleted ()))
              takeMVar actionRequests
                `shouldReturn` ("POST /containers/" ++ replicate 64 'c' ++ "/start HTTP/1.1")
        withSystemTempDirectory "prodbox-node-submission-refused" $ \nodeDirectory -> do
          let nodeSocket = nodeDirectory </> "docker.sock"
              nodeSelected = nodeDirectory </> "selected.dhall"
              nodeDocument = Text.unpack (Text.replace (Text.pack directory) (Text.pack nodeDirectory) (Text.pack document))
          writeFile nodeSelected nodeDocument
          nodeBootstrap <- readBootstrapProjection nodeSelected >>= either (fail . show) pure
          prepareFreshScope (bootstrapScope nodeBootstrap) generation `shouldReturn` FreshScopePrepared
          let selectedRoot = scopeRoot (bootstrapScope nodeBootstrap)
              selectedArgs =
                map
                  ( \arg ->
                      if arg == "--volume=" ++ rootPath ++ ":/var/lib/prodbox"
                        then "--volume=" ++ selectedRoot ++ ":/var/lib/prodbox"
                        else arg
                  )
                  nodeArgs
              selectedInput = nodeInput {nodeCreateArguments = selectedArgs}
          withDockerNodeContainerCreateFixture nodeSocket Nothing $ \_ -> do
            socketIdentity <-
              observeDockerSocketIdentity nodeSocket >>= maybe (fail "missing fixture socket") pure
            proposal <-
              maybe
                (fail "invalid node intent")
                pure
                (mkKindNodeCreateIntent nodeBootstrap selectedInput (DockerDaemonObserved "daemon-a" socketIdentity))
            withNewKindOperation nodeBootstrap operation (recordKindNodeCreateIntent nodeBootstrap proposal)
              `shouldReturn` KindOperationCallbackReturned NodeCreateIntentRecorded
            refused <- withNewConnectedKindNodeCreate nodeBootstrap operation (\_ _ _ -> pure False)
            refused
              `shouldBe` KindOperationCallbackReturned
                (DockerPeerCompleted (DockerConnectedInfoCompleted NodeCreateActionAdmissionRefused))
            withRecoveredKindOperation
              nodeBootstrap
              operation
              (observeKindNodeCreateAttempt nodeBootstrap proposal)
              `shouldReturn` KindOperationCallbackReturned NodeCreateAttemptMissing
        withSystemTempDirectory "prodbox-node-submission-changed" $ \nodeDirectory -> do
          let nodeSocket = nodeDirectory </> "docker.sock"
              nodeSelected = nodeDirectory </> "selected.dhall"
              nodeDocument = Text.unpack (Text.replace (Text.pack directory) (Text.pack nodeDirectory) (Text.pack document))
          writeFile nodeSelected nodeDocument
          nodeBootstrap <- readBootstrapProjection nodeSelected >>= either (fail . show) pure
          prepareFreshScope (bootstrapScope nodeBootstrap) generation `shouldReturn` FreshScopePrepared
          let selectedRoot = scopeRoot (bootstrapScope nodeBootstrap)
              selectedArgs =
                map
                  ( \arg ->
                      if arg == "--volume=" ++ rootPath ++ ":/var/lib/prodbox"
                        then "--volume=" ++ selectedRoot ++ ":/var/lib/prodbox"
                        else arg
                  )
                  nodeArgs
              selectedInput = nodeInput {nodeCreateArguments = selectedArgs}
          withDockerNodeContainerCreateFixture nodeSocket Nothing $ \_ -> do
            socketIdentity <-
              observeDockerSocketIdentity nodeSocket >>= maybe (fail "missing fixture socket") pure
            proposal <-
              maybe
                (fail "invalid node intent")
                pure
                (mkKindNodeCreateIntent nodeBootstrap selectedInput (DockerDaemonObserved "daemon-a" socketIdentity))
            withNewKindOperation nodeBootstrap operation (recordKindNodeCreateIntent nodeBootstrap proposal)
              `shouldReturn` KindOperationCallbackReturned NodeCreateIntentRecorded
            checks <- newIORef (0 :: Int)
            let admit _ _ _ = atomicModifyIORef' checks (\value -> (value + 1, value == 0))
            refused <- withNewConnectedKindNodeCreate nodeBootstrap operation admit
            refused
              `shouldBe` KindOperationCallbackReturned
                ( DockerPeerCompleted
                    (DockerConnectedInfoCompleted (NodeCreateActionResultRefused NodeCreateResultUnobservable))
                )
            withRecoveredKindOperation
              nodeBootstrap
              operation
              (observeKindNodeCreateAttempt nodeBootstrap proposal)
              `shouldReturn` KindOperationCallbackReturned NodeCreateAttemptMatches
        forM_
          [ (True, False, False, False)
          , (False, False, False, False)
          , (True, True, False, False)
          , (True, False, True, False)
          , (True, False, False, True)
          ]
          $ \(admitted, conflict, foreignMount, foreignPort) ->
            withSystemTempDirectory "prodbox-node-start-operation" $ \startDirectory -> do
              let startSocket = startDirectory </> "docker.sock"
                  startSelected = startDirectory </> "selected.dhall"
                  startDocument = Text.unpack (Text.replace (Text.pack directory) (Text.pack startDirectory) (Text.pack document))
              writeFile startSelected startDocument
              startBootstrap <- readBootstrapProjection startSelected >>= either (fail . show) pure
              prepareFreshScope (bootstrapScope startBootstrap) generation `shouldReturn` FreshScopePrepared
              let startRoot = scopeRoot (bootstrapScope startBootstrap)
                  startArgs =
                    map
                      ( \arg ->
                          if arg == "--volume=" ++ rootPath ++ ":/var/lib/prodbox"
                            then "--volume=" ++ startRoot ++ ":/var/lib/prodbox"
                            else arg
                      )
                      nodeArgs
                  startInput = nodeInput {nodeCreateArguments = startArgs}
                  containerId = replicate 64 'c'
              withDockerNodeStartFixture
                startSocket
                ( pure
                    ( LazyBS8.toStrict
                        ( Aeson.encode
                            ( (if foreignPort then exposeApi else id) $
                                (if foreignMount then addForeignMount else id) $
                                  nodeInspect
                                    (if conflict then "foreign" else image)
                                    (replicate 64 'c')
                                    name
                                    "/var/lib/docker/volumes/example/_data"
                                    startRoot
                            )
                        )
                    )
                )
                $ \requests -> do
                  socketIdentity <-
                    observeDockerSocketIdentity startSocket >>= maybe (fail "missing fixture socket") pure
                  proposal <-
                    maybe
                      (fail "invalid node intent")
                      pure
                      (mkKindNodeCreateIntent startBootstrap startInput (DockerDaemonObserved "daemon-a" socketIdentity))
                  withNewKindOperation
                    startBootstrap
                    operation
                    ( \stable -> do
                        recordKindNodeCreateIntent startBootstrap proposal stable `shouldReturn` NodeCreateIntentRecorded
                        recordKindNodeCreateAttempt startBootstrap proposal stable `shouldReturn` NodeCreateAttemptRecorded
                        recordKindNodeCreateResult
                          startBootstrap
                          proposal
                          (DockerNodeContainerCreateReply 201 (Just containerId))
                          stable
                          `shouldReturn` NodeCreateResultRecorded
                    )
                    `shouldReturn` KindOperationCallbackReturned ()
                  let admit candidate actual _ _ = pure (admitted && candidate == proposal && actual == containerId)
                  result <- withRecoveredKindOperation startBootstrap operation $ \operationStable ->
                    withConnectedDockerInfo 30000000 startSocket $ \session info peerStable ->
                      runKindNodeStartOnSession
                        startBootstrap
                        operation
                        session
                        info
                        ((&&) <$> operationStable <*> peerStable)
                        admit
                  if admitted && not conflict && not foreignMount && not foreignPort
                    then do
                      result
                        `shouldBe` KindOperationCallbackReturned
                          ( DockerPeerCompleted
                              ( DockerConnectedInfoCompleted
                                  (NodeStartActionReturned (DockerNodeContainerStartReply 204) NodeStartResultRecorded)
                              )
                          )
                      request <- takeMVar requests
                      request `shouldBe` ("POST /containers/" ++ containerId ++ "/start HTTP/1.1")
                      withRecoveredKindOperation
                        startBootstrap
                        operation
                        (observeKindNodeStartResult startBootstrap proposal containerId)
                        `shouldReturn` KindOperationCallbackReturned (NodeStartResultObserved (DockerNodeContainerStartReply 204))
                    else do
                      tryReadMVar requests `shouldReturn` Nothing
                      result
                        `shouldBe` KindOperationCallbackReturned
                          ( DockerPeerCompleted
                              ( DockerConnectedInfoCompleted
                                  ( if conflict || foreignMount || foreignPort
                                      then NodeStartActionInspectionRefused (Right DockerNodeContainerConflict)
                                      else NodeStartActionAdmissionRefused
                                  )
                              )
                          )
                      withRecoveredKindOperation
                        startBootstrap
                        operation
                        (observeKindNodeStartAttempt startBootstrap proposal containerId)
                        `shouldReturn` KindOperationCallbackReturned NodeStartAttemptMissing
        forM_ [False, True] $ \changeInspection ->
          withSystemTempDirectory "prodbox-node-start-changed" $ \startDirectory -> do
            let startSocket = startDirectory </> "docker.sock"
                startSelected = startDirectory </> "selected.dhall"
                startDocument = Text.unpack (Text.replace (Text.pack directory) (Text.pack startDirectory) (Text.pack document))
            writeFile startSelected startDocument
            startBootstrap <- readBootstrapProjection startSelected >>= either (fail . show) pure
            prepareFreshScope (bootstrapScope startBootstrap) generation `shouldReturn` FreshScopePrepared
            let startRoot = scopeRoot (bootstrapScope startBootstrap)
                startArgs =
                  map
                    ( \arg ->
                        if arg == "--volume=" ++ rootPath ++ ":/var/lib/prodbox"
                          then "--volume=" ++ startRoot ++ ":/var/lib/prodbox"
                          else arg
                    )
                    nodeArgs
                startInput = nodeInput {nodeCreateArguments = startArgs}
                containerId = replicate 64 'c'
            inspections <- newIORef (0 :: Int)
            let nodeBody = do
                  first <- atomicModifyIORef' inspections (\value -> (value + 1, value == 0))
                  pure
                    ( LazyBS8.toStrict
                        ( Aeson.encode
                            ( nodeInspect
                                (if changeInspection && not first then "foreign" else image)
                                (replicate 64 'c')
                                name
                                "/var/lib/docker/volumes/example/_data"
                                startRoot
                            )
                        )
                    )
            withDockerNodeStartFixture startSocket nodeBody $
              \requests -> do
                socketIdentity <-
                  observeDockerSocketIdentity startSocket >>= maybe (fail "missing fixture socket") pure
                proposal <-
                  maybe
                    (fail "invalid node intent")
                    pure
                    (mkKindNodeCreateIntent startBootstrap startInput (DockerDaemonObserved "daemon-a" socketIdentity))
                withNewKindOperation
                  startBootstrap
                  operation
                  ( \stable -> do
                      recordKindNodeCreateIntent startBootstrap proposal stable `shouldReturn` NodeCreateIntentRecorded
                      recordKindNodeCreateAttempt startBootstrap proposal stable `shouldReturn` NodeCreateAttemptRecorded
                      recordKindNodeCreateResult
                        startBootstrap
                        proposal
                        (DockerNodeContainerCreateReply 201 (Just containerId))
                        stable
                        `shouldReturn` NodeCreateResultRecorded
                  )
                  `shouldReturn` KindOperationCallbackReturned ()
                checks <- newIORef (0 :: Int)
                let admit candidate actual _ _ = do
                      first <- atomicModifyIORef' checks (\value -> (value + 1, value == 0))
                      pure ((first || changeInspection) && candidate == proposal && actual == containerId)
                result <- withNewConnectedKindNodeStart startBootstrap operation admit
                tryReadMVar requests `shouldReturn` Nothing
                result
                  `shouldBe` KindOperationCallbackReturned
                    ( DockerPeerCompleted
                        ( DockerConnectedInfoCompleted
                            (NodeStartActionResultRefused NodeStartResultUnobservable)
                        )
                    )
                withRecoveredKindOperation
                  startBootstrap
                  operation
                  (observeKindNodeStartAttempt startBootstrap proposal containerId)
                  `shouldReturn` KindOperationCallbackReturned NodeStartAttemptMatches
        withDockerNodeContainerCreateFixture
          socketPath
          (Just (BS8.pack ("{\"Id\":\"" ++ replicate 64 'c' ++ "\"}")))
          $ \requests -> do
            result <- withConnectedDockerInfo 5000000 socketPath $ \session _ _ -> do
              createDockerSessionKindNode
                session
                bootstrap
                (nodeInput {nodeCreateGeneration = replicate 32 'e'})
                (pure True)
                `shouldReturn` DockerNodeContainerCreateNotStarted
              createDockerSessionKindNode
                session
                bootstrap
                (nodeInput {nodeCreateArguments = nodeArgs ++ ["--privileged"]})
                (pure True)
                `shouldReturn` DockerNodeContainerCreateNotStarted
              createDockerSessionKindNode session bootstrap nodeInput (pure False)
                `shouldReturn` DockerNodeContainerCreateNotStarted
              createDockerSessionKindNode session bootstrap nodeInput (pure True)
                `shouldReturn` DockerNodeContainerCreateReply 201 (Just (replicate 64 'c'))
            result `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted ())
            payload <- takeMVar requests
            case Aeson.eitherDecodeStrict' payload of
              Right (Aeson.Object body) -> do
                AesonKeyMap.lookup (AesonKey.fromString "Image") body `shouldBe` Just (Aeson.toJSON image)
                case AesonKeyMap.lookup (AesonKey.fromString "HostConfig") body of
                  Just (Aeson.Object host) -> do
                    AesonKeyMap.lookup (AesonKey.fromString "NetworkMode") host
                      `shouldBe` Just (Aeson.toJSON (replicate 64 'c'))
                    AesonKeyMap.lookup (AesonKey.fromString "Binds") host
                      `shouldBe` Just
                        ( Aeson.toJSON
                            ([name ++ ":/var", "/lib/modules:/lib/modules:ro", rootPath ++ ":/var/lib/prodbox"] :: [String])
                        )
                  other -> expectationFailure (show other)
              other -> expectationFailure (show (other :: Either String Aeson.Value))
        removeFile socketPath
        withDockerNodeContainerCreateFixture socketPath Nothing $ \requests -> do
          result <- withConnectedDockerInfo 5000000 socketPath $ \session _ _ -> createDockerSessionKindNode session bootstrap nodeInput (pure True)
          result
            `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted DockerNodeContainerCreateUnconfirmed)
          void (takeMVar requests)
        removeFile socketPath
        withDockerNodeContainerCreateFixture
          socketPath
          (Just (BS8.pack ("{\"Id\":\"" ++ replicate 64 'c' ++ "\"}")))
          $ \requests -> do
            count <- newIORef (0 :: Int)
            let stable = atomicModifyIORef' count (\value -> (value + 1, value == 0))
            result <- withConnectedDockerInfo 5000000 socketPath $ \session _ _ -> createDockerSessionKindNode session bootstrap nodeInput stable
            result
              `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted DockerNodeContainerCreateUnconfirmed)
            void (takeMVar requests)
        removeFile socketPath
        withDockerNodeContainerCreateFixture
          socketPath
          (Just (BS8.pack "{\"Id\":\"duplicate\",\"Id\":\"duplicate\"}"))
          $ \requests -> do
            result <- withConnectedDockerInfo 5000000 socketPath $ \session _ _ -> createDockerSessionKindNode session bootstrap nodeInput (pure True)
            result
              `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted DockerNodeContainerCreateUnconfirmed)
            void (takeMVar requests)
        removeFile socketPath
        forM_ ["remove", "blind", "deny", "start-after-remove"] $ \mode ->
          withSystemTempDirectory "prodbox-node-remove" $ \removeDirectory -> do
            let removeSocket = removeDirectory </> "docker.sock"
                removeSelected = removeDirectory </> "selected.dhall"
                removeDocument = Text.unpack (Text.replace (Text.pack directory) (Text.pack removeDirectory) (Text.pack document))
            writeFile removeSelected removeDocument
            removeBootstrap <- readBootstrapProjection removeSelected >>= either (fail . show) pure
            prepareFreshScope (bootstrapScope removeBootstrap) generation `shouldReturn` FreshScopePrepared
            let removeRoot = scopeRoot (bootstrapScope removeBootstrap)
                removeArgs =
                  map
                    ( \arg ->
                        if arg == "--volume=" ++ rootPath ++ ":/var/lib/prodbox"
                          then "--volume=" ++ removeRoot ++ ":/var/lib/prodbox"
                          else arg
                    )
                    nodeArgs
                removeInput = nodeInput {nodeCreateArguments = removeArgs}
                containerId = replicate 64 'c'
                nodeBody =
                  pure
                    ( LazyBS8.toStrict
                        ( Aeson.encode
                            (nodeInspect image (replicate 64 'c') name "/var/lib/docker/volumes/example/_data" removeRoot)
                        )
                    )
            body <- nodeBody
            let listing =
                  if mode == "blind"
                    then BS8.pack "[]"
                    else
                      BS8.pack
                        ( "[{\"Id\":\""
                            ++ containerId
                            ++ "\",\"Names\":[\"/prodbox-t-run-control-plane\"],\"Image\":\"example\",\"ImageID\":\"sha256:"
                            ++ replicate 64 'a'
                            ++ "\",\"Command\":\"\",\"Created\":1,\"Ports\":[],\"Labels\":{},\"State\":\"running\",\"Status\":\"Up\",\"HostConfig\":{},\"NetworkSettings\":{\"Networks\":{}},\"Mounts\":[]}]"
                        )
            withDockerDaemonFixtureControlVolumeAndNode
              removeSocket
              False
              (const (pure ()))
              (pure False)
              listing
              (BS8.pack "[]")
              (pure True)
              Nothing
              (pure (BS8.pack "{\"Volumes\":[],\"Warnings\":[]}"))
              (Just (containerId, body))
              $ \requests -> do
                let effects = filter ("DELETE /containers/" `isPrefixOf`) <$> readMVar requests
                socketIdentity <-
                  observeDockerSocketIdentity removeSocket >>= maybe (fail "missing fixture socket") pure
                proposal <-
                  maybe
                    (fail "invalid node intent")
                    pure
                    (mkKindNodeCreateIntent removeBootstrap removeInput (DockerDaemonObserved "daemon-a" socketIdentity))
                withNewKindOperation
                  removeBootstrap
                  operation
                  ( \stable -> do
                      recordKindNodeCreateIntent removeBootstrap proposal stable `shouldReturn` NodeCreateIntentRecorded
                      recordKindNodeCreateAttempt removeBootstrap proposal stable `shouldReturn` NodeCreateAttemptRecorded
                      recordKindNodeCreateResult
                        removeBootstrap
                        proposal
                        (DockerNodeContainerCreateReply 201 (Just containerId))
                        stable
                        `shouldReturn` NodeCreateResultRecorded
                      when (mode == "start-after-remove") $
                        recordKindNodeRemoveAttempt removeBootstrap proposal containerId stable
                          `shouldReturn` NodeRemoveAttemptRecorded
                  )
                  `shouldReturn` KindOperationCallbackReturned ()
                if mode == "start-after-remove"
                  then do
                    result <- withNewConnectedKindNodeStart removeBootstrap operation (\_ _ _ _ -> pure True)
                    result
                      `shouldBe` KindOperationCallbackReturned
                        ( DockerPeerCompleted
                            (DockerConnectedInfoCompleted (NodeStartActionRemovalRefused NodeRemoveAttemptMatches))
                        )
                    effects `shouldReturn` []
                  else do
                    let admit candidate actual _ _ = pure (mode /= "deny" && candidate == proposal && actual == containerId)
                    result <- withNewConnectedKindNodeRemove removeBootstrap operation admit
                    if mode == "remove"
                      then do
                        result
                          `shouldBe` KindOperationCallbackReturned
                            ( DockerPeerCompleted
                                ( DockerConnectedInfoCompleted
                                    (NodeRemoveActionReturned (DockerNodeContainerRemoveReply 204) NodeRemoveResultRecorded)
                                )
                            )
                        effects `shouldReturn` ["DELETE /containers/" ++ containerId ++ "?force=1&v=1 HTTP/1.1"]
                        withRecoveredKindOperation
                          removeBootstrap
                          operation
                          (observeKindNodeRemoveControl removeBootstrap proposal containerId)
                          `shouldReturn` KindOperationCallbackReturned NodeRemoveControlMatches
                        withRecoveredKindOperation
                          removeBootstrap
                          operation
                          (observeKindNodeRemoveResult removeBootstrap proposal containerId)
                          `shouldReturn` KindOperationCallbackReturned (NodeRemoveResultObserved (DockerNodeContainerRemoveReply 204))
                        withRecoveredKindOperation
                          removeBootstrap
                          operation
                          (\stable -> recordKindNodeRemoveAttempt removeBootstrap proposal containerId stable)
                          `shouldReturn` KindOperationCallbackReturned NodeRemoveAttemptAlreadyExists
                        let controlPath = removeRoot </> "kind-node-remove-positive-control.json"
                        writeFile controlPath "{\"kind\":1,\"kind\":1}"
                        withRecoveredKindOperation
                          removeBootstrap
                          operation
                          (observeKindNodeRemoveControl removeBootstrap proposal containerId)
                          `shouldReturn` KindOperationCallbackReturned NodeRemoveControlInvalid
                        withRecoveredKindOperation
                          removeBootstrap
                          operation
                          (observeKindNodeRemoveAttempt removeBootstrap proposal containerId)
                          `shouldReturn` KindOperationCallbackReturned NodeRemoveAttemptMatches
                        removeFile controlPath
                        withRecoveredKindOperation
                          removeBootstrap
                          operation
                          (observeKindNodeRemoveControl removeBootstrap proposal containerId)
                          `shouldReturn` KindOperationCallbackReturned NodeRemoveControlMissing
                        withRecoveredKindOperation
                          removeBootstrap
                          operation
                          (observeKindNodeRemoveResult removeBootstrap proposal containerId)
                          `shouldReturn` KindOperationCallbackReturned (NodeRemoveResultObserved (DockerNodeContainerRemoveReply 204))
                      else do
                        result
                          `shouldBe` KindOperationCallbackReturned
                            ( DockerPeerCompleted
                                ( DockerConnectedInfoCompleted
                                    ( if mode == "blind"
                                        then
                                          NodeRemoveActionPositiveControlRefused
                                            (NodeRemovalReadbackSampled (NodeRemovalInventory False [] []))
                                        else NodeRemoveActionAdmissionRefused
                                    )
                                )
                            )
                        effects `shouldReturn` []
                        doesFileExist (removeRoot </> "kind-node-remove-positive-control.json") `shouldReturn` False
                        withRecoveredKindOperation
                          removeBootstrap
                          operation
                          (observeKindNodeRemoveAttempt removeBootstrap proposal containerId)
                          `shouldReturn` KindOperationCallbackReturned NodeRemoveAttemptMissing
        forM_
          [ (Just 204, DockerNodeContainerRemoveReply 204)
          , (Just 404, DockerNodeContainerRemoveReply 404)
          , (Nothing, DockerNodeContainerRemoveUnconfirmed)
          ]
          $ \(reply, wanted) -> do
            withDockerNetworkRemoveFixture socketPath reply $ \requests -> do
              result <- withConnectedDockerInfo 5000000 socketPath $ \session _ _ -> do
                removeDockerSessionKindNode session "invalid" (pure True) (pure True)
                  `shouldReturn` DockerNodeContainerRemoveNotStarted
                removeDockerSessionKindNode session (replicate 64 'c') (pure False) (pure True)
                  `shouldReturn` DockerNodeContainerRemoveNotStarted
                removeDockerSessionKindNode session (replicate 64 'c') (pure True) (pure True)
              result `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted wanted)
              takeMVar requests
                `shouldReturn` ("DELETE /containers/" ++ replicate 64 'c' ++ "?force=1&v=1 HTTP/1.1")
            removeFile socketPath
        withDockerNetworkRemoveFixture socketPath (Just 204) $ \requests -> do
          result <- withConnectedDockerInfo 5000000 socketPath $ \session _ _ ->
            removeDockerSessionKindNode session (replicate 64 'c') (pure True) (pure False)
          result
            `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted DockerNodeContainerRemoveUnconfirmed)
          void (takeMVar requests)
        removeFile socketPath
        forM_
          [ (Just 204, DockerNodeContainerStartReply 204)
          , (Just 304, DockerNodeContainerStartReply 304)
          , (Nothing, DockerNodeContainerStartUnconfirmed)
          ]
          $ \(reply, wanted) -> do
            withDockerNetworkRemoveFixture socketPath reply $ \requests -> do
              result <- withConnectedDockerInfo 5000000 socketPath $ \session _ _ -> do
                startDockerSessionKindNode session "invalid" (pure True)
                  `shouldReturn` DockerNodeContainerStartNotStarted
                startDockerSessionKindNode session (replicate 64 'c') (pure False)
                  `shouldReturn` DockerNodeContainerStartNotStarted
                startDockerSessionKindNode session (replicate 64 'c') (pure True)
              result `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted wanted)
              request <- takeMVar requests
              request `shouldBe` ("POST /containers/" ++ replicate 64 'c' ++ "/start HTTP/1.1")
            removeFile socketPath
        withDockerNetworkRemoveFixture socketPath (Just 204) $ \requests -> do
          count <- newIORef (0 :: Int)
          let stable = atomicModifyIORef' count (\value -> (value + 1, value == 0))
          result <- withConnectedDockerInfo 5000000 socketPath $ \session _ _ -> startDockerSessionKindNode session (replicate 64 'c') stable
          result
            `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted DockerNodeContainerStartUnconfirmed)
          void (takeMVar requests)
        removeFile socketPath
        withDockerNodeVolumeCreateFixture socketPath (Just response) $ \requests -> do
          result <- withConnectedDockerInfo 5000000 socketPath $ \session _ _ -> do
            createDockerSessionNodeVarVolume session bootstrap "invalid" (pure True)
              `shouldReturn` DockerNodeVarCreateNotStarted
            createDockerSessionNodeVarVolume session bootstrap operation (pure False)
              `shouldReturn` DockerNodeVarCreateNotStarted
            createDockerSessionNodeVarVolume session bootstrap operation (pure True)
              `shouldReturn` DockerNodeVarCreateReply 201 (Just DockerNodeVarVolumeMatching)
          result `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted ())
          payload <- takeMVar requests
          Aeson.eitherDecodeStrict' payload
            `shouldBe` Right
              ( Aeson.object
                  [ AesonKey.fromString "Name" Aeson..= name
                  , AesonKey.fromString "Driver" Aeson..= ("local" :: String)
                  , AesonKey.fromString "DriverOpts" Aeson..= Aeson.object []
                  , AesonKey.fromString "Labels" Aeson..= labels
                  ]
              )
        removeFile socketPath
        withDockerNodeVolumeCreateFixture socketPath (Just (BS8.pack "{\"Name\":1,\"Name\":1}")) $ \requests -> do
          result <- withConnectedDockerInfo 5000000 socketPath $ \session _ _ ->
            createDockerSessionNodeVarVolume session bootstrap operation (pure True)
          result `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted DockerNodeVarCreateUnconfirmed)
          void (takeMVar requests)
        removeFile socketPath
        withDockerNodeVolumeCreateFixture socketPath Nothing $ \requests -> do
          result <- withConnectedDockerInfo 5000000 socketPath $ \session _ _ ->
            createDockerSessionNodeVarVolume session bootstrap operation (pure True)
          result `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted DockerNodeVarCreateUnconfirmed)
          void (takeMVar requests)
        removeFile socketPath
        withDockerNodeVolumeCreateFixture socketPath (Just response) $ \requests -> do
          count <- newIORef (0 :: Int)
          let stable = atomicModifyIORef' count (\value -> (value + 1, value == 0))
          result <- withConnectedDockerInfo 5000000 socketPath $ \session _ _ ->
            createDockerSessionNodeVarVolume session bootstrap operation stable
          result `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted DockerNodeVarCreateUnconfirmed)
          void (takeMVar requests)
        removeFile socketPath
        prepareFreshScope (bootstrapScope bootstrap) generation `shouldReturn` FreshScopePrepared
        withDockerNodeVolumeCreateFixture socketPath (Just response) $ \requests -> do
          socketIdentity <-
            observeDockerSocketIdentity socketPath >>= maybe (fail "missing fixture socket") pure
          intent <-
            maybe
              (fail "invalid volume intent")
              pure
              (mkKindNodeVolumeIntent operation (DockerDaemonObserved "daemon-a" socketIdentity))
          withNewKindOperation bootstrap operation (recordKindNodeVolumeIntent bootstrap intent)
            `shouldReturn` KindOperationCallbackReturned NodeVolumeIntentRecorded
          let create session stable = createDockerSessionNodeVarVolume session bootstrap operation stable
          sent <- withNewConnectedKindNodeVolumeAttempt bootstrap operation create
          sent
            `shouldBe` KindOperationCallbackReturned
              ( DockerPeerCompleted
                  ( DockerConnectedInfoCompleted
                      ( NodeVolumeActionReturned
                          (DockerNodeVarCreateReply 201 (Just DockerNodeVarVolumeMatching))
                          NodeVolumeReceiptRecorded
                      )
                  )
              )
          void (takeMVar requests)
          withRecoveredKindOperation bootstrap operation (observeKindNodeVolumeReceipt bootstrap intent)
            `shouldReturn` KindOperationCallbackReturned
              (NodeVolumeReceiptObserved (DockerNodeVarCreateReply 201 (Just DockerNodeVarVolumeMatching)))
          let resultPath = scopeRoot (bootstrapScope bootstrap) </> "kind-node-var-volume-create-result.json"
          writeFile resultPath "{\"kind\":1,\"kind\":1}"
          withRecoveredKindOperation bootstrap operation (observeKindNodeVolumeReceipt bootstrap intent)
            `shouldReturn` KindOperationCallbackReturned NodeVolumeReceiptInvalid
          removeFile resultPath
          writeFile (directory </> "foreign-result") "foreign"
          createSymbolicLink (directory </> "foreign-result") resultPath
          withRecoveredKindOperation bootstrap operation (observeKindNodeVolumeReceipt bootstrap intent)
            `shouldReturn` KindOperationCallbackReturned NodeVolumeReceiptUnobservable
          readFile (directory </> "foreign-result") `shouldReturn` "foreign"
        removeFile socketPath
        forM_
          [ (Just 204, DockerNodeVarRemoveReply 204)
          , (Just 404, DockerNodeVarRemoveReply 404)
          , (Nothing, DockerNodeVarRemoveUnconfirmed)
          ]
          $ \(reply, wanted) -> do
            withDockerNetworkRemoveFixture socketPath reply $ \requests -> do
              result <- withConnectedDockerInfo 5000000 socketPath $ \session _ _ -> do
                removeDockerSessionNodeVarVolume session bootstrap "invalid" (pure True)
                  `shouldReturn` DockerNodeVarRemoveNotStarted
                removeDockerSessionNodeVarVolume session bootstrap operation (pure False)
                  `shouldReturn` DockerNodeVarRemoveNotStarted
                removeDockerSessionNodeVarVolume session bootstrap operation (pure True)
              result `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted wanted)
              request <- takeMVar requests
              request `shouldBe` ("DELETE /volumes/" ++ name ++ " HTTP/1.1")
            removeFile socketPath
        withDockerNetworkRemoveFixture socketPath (Just 204) $ \requests -> do
          count <- newIORef (0 :: Int)
          let stable = atomicModifyIORef' count (\value -> (value + 1, value == 0))
          result <- withConnectedDockerInfo 5000000 socketPath $ \session _ _ ->
            removeDockerSessionNodeVarVolume session bootstrap operation stable
          result `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted DockerNodeVarRemoveUnconfirmed)
          void (takeMVar requests)
        withSystemTempDirectory "prodbox-volume-removal" $ \removalDirectory -> do
          let removalSocket = removalDirectory </> "docker.sock"
              removalSelected = removalDirectory </> "selected.dhall"
              removalDocument =
                Text.unpack (Text.replace (Text.pack directory) (Text.pack removalDirectory) (Text.pack document))
          writeFile removalSelected removalDocument
          removalBootstrap <- readBootstrapProjection removalSelected >>= either (fail . show) pure
          prepareFreshScope (bootstrapScope removalBootstrap) generation `shouldReturn` FreshScopePrepared
          withDockerVolumeRemovalFixture removalSocket name response $ \requests -> do
            socketIdentity <-
              observeDockerSocketIdentity removalSocket >>= maybe (fail "missing fixture socket") pure
            intent <-
              maybe
                (fail "invalid volume intent")
                pure
                (mkKindNodeVolumeIntent operation (DockerDaemonObserved "daemon-a" socketIdentity))
            prepared <- withNewKindOperation removalBootstrap operation $ \stable -> do
              recordKindNodeVolumeIntent removalBootstrap intent stable `shouldReturn` NodeVolumeIntentRecorded
              recordKindNodeVolumeAttempt removalBootstrap intent stable `shouldReturn` NodeVolumeAttemptRecorded
            prepared `shouldBe` KindOperationCallbackReturned ()
            let admit _ _ = pure True
                remove session stable = removeDockerSessionNodeVarVolume session removalBootstrap operation stable
            removed <- withNewConnectedKindNodeVolumeRemoval removalBootstrap operation admit remove
            removed
              `shouldBe` KindOperationCallbackReturned
                ( DockerPeerCompleted
                    ( DockerConnectedInfoCompleted
                        (NodeVolumeRemovalActionReturned (DockerNodeVarRemoveReply 204) NodeVolumeRemovalReceiptRecorded)
                    )
                )
            request <- takeMVar requests
            request `shouldBe` ("DELETE /volumes/" ++ name ++ " HTTP/1.1")
            withRecoveredKindOperation
              removalBootstrap
              operation
              (observeKindNodeVolumeRemovalReceipt removalBootstrap intent)
              `shouldReturn` KindOperationCallbackReturned (NodeVolumeRemovalReceiptObserved (DockerNodeVarRemoveReply 204))
        withSystemTempDirectory "prodbox-volume-removal-refused" $ \removalDirectory -> do
          let removalSocket = removalDirectory </> "docker.sock"
              removalSelected = removalDirectory </> "selected.dhall"
              removalDocument =
                Text.unpack (Text.replace (Text.pack directory) (Text.pack removalDirectory) (Text.pack document))
          writeFile removalSelected removalDocument
          removalBootstrap <- readBootstrapProjection removalSelected >>= either (fail . show) pure
          prepareFreshScope (bootstrapScope removalBootstrap) generation `shouldReturn` FreshScopePrepared
          withDockerVolumeRemovalFixture removalSocket name response $ \_ -> do
            socketIdentity <-
              observeDockerSocketIdentity removalSocket >>= maybe (fail "missing fixture socket") pure
            intent <-
              maybe
                (fail "invalid volume intent")
                pure
                (mkKindNodeVolumeIntent operation (DockerDaemonObserved "daemon-a" socketIdentity))
            withNewKindOperation
              removalBootstrap
              operation
              ( \stable -> do
                  recordKindNodeVolumeIntent removalBootstrap intent stable `shouldReturn` NodeVolumeIntentRecorded
                  recordKindNodeVolumeAttempt removalBootstrap intent stable `shouldReturn` NodeVolumeAttemptRecorded
              )
              `shouldReturn` KindOperationCallbackReturned ()
            called <- newIORef False
            let admit _ _ = pure False
                remove _ _ = writeIORef called True >> pure DockerNodeVarRemoveNotStarted
            refused <- withNewConnectedKindNodeVolumeRemoval removalBootstrap operation admit remove
            refused
              `shouldBe` KindOperationCallbackReturned
                (DockerPeerCompleted (DockerConnectedInfoCompleted NodeVolumeRemovalActionAdmissionRefused))
            readIORef called `shouldReturn` False
            withRecoveredKindOperation
              removalBootstrap
              operation
              (observeKindNodeVolumeRemoval removalBootstrap intent)
              `shouldReturn` KindOperationCallbackReturned NodeVolumeRemovalMissing
        withSystemTempDirectory "prodbox-volume-removal-changed" $ \removalDirectory -> do
          let removalSocket = removalDirectory </> "docker.sock"
              removalSelected = removalDirectory </> "selected.dhall"
              removalDocument =
                Text.unpack (Text.replace (Text.pack directory) (Text.pack removalDirectory) (Text.pack document))
          writeFile removalSelected removalDocument
          removalBootstrap <- readBootstrapProjection removalSelected >>= either (fail . show) pure
          prepareFreshScope (bootstrapScope removalBootstrap) generation `shouldReturn` FreshScopePrepared
          withDockerVolumeRemovalFixture removalSocket name response $ \_ -> do
            socketIdentity <-
              observeDockerSocketIdentity removalSocket >>= maybe (fail "missing fixture socket") pure
            intent <-
              maybe
                (fail "invalid volume intent")
                pure
                (mkKindNodeVolumeIntent operation (DockerDaemonObserved "daemon-a" socketIdentity))
            withNewKindOperation
              removalBootstrap
              operation
              ( \stable -> do
                  recordKindNodeVolumeIntent removalBootstrap intent stable `shouldReturn` NodeVolumeIntentRecorded
                  recordKindNodeVolumeAttempt removalBootstrap intent stable `shouldReturn` NodeVolumeAttemptRecorded
              )
              `shouldReturn` KindOperationCallbackReturned ()
            called <- newIORef False
            checks <- newIORef (0 :: Int)
            let admit _ _ = atomicModifyIORef' checks (\value -> (value + 1, value == 0))
                remove _ _ = writeIORef called True >> pure DockerNodeVarRemoveNotStarted
            changed <- withNewConnectedKindNodeVolumeRemoval removalBootstrap operation admit remove
            changed
              `shouldBe` KindOperationCallbackReturned
                ( DockerPeerCompleted
                    ( DockerConnectedInfoCompleted
                        (NodeVolumeRemovalActionReceiptRefused NodeVolumeRemovalReceiptUnobservable)
                    )
                )
            readIORef called `shouldReturn` False
            withRecoveredKindOperation
              removalBootstrap
              operation
              (observeKindNodeVolumeRemoval removalBootstrap intent)
              `shouldReturn` KindOperationCallbackReturned NodeVolumeRemovalMatches

    it "observes only the selected network and rejects ambiguous inventory" $
      withSystemTempDirectory "prodbox-gated-network" $ \directory -> do
        let path = directory </> "docker.sock"
            imageId = "sha256:" ++ replicate 64 'a'
            networkId = replicate 64 'b'
            network name identifier =
              Aeson.object
                [ AesonKey.fromString "Name" Aeson..= (name :: String)
                , AesonKey.fromString "Id" Aeson..= (identifier :: String)
                ]
            inventory entries = Aeson.toJSON (entries :: [Aeson.Value])
            request = ["network", "ls", "--filter=name=^prodbox-t-run$", "--format={{.ID}}"]
            foreignRequest = ["network", "ls", "--filter=name=^kind$", "--format={{.ID}}"]
        scope <- either (fail . show) pure (deploymentScope directory Test "run" 26443)
        parseDockerKindNetworks scope (inventory []) `shouldBe` Right []
        parseDockerKindNetworks scope (inventory [network "prodbox-t-run" networkId])
          `shouldBe` Right [networkId]
        parseDockerKindNetworks scope (inventory [network "foreign" networkId]) `shouldSatisfy` isLeft
        parseDockerKindNetworks scope (inventory [network "prodbox-t-run" "invalid"]) `shouldSatisfy` isLeft
        parseDockerKindNetworks
          scope
          (inventory [network "prodbox-t-run" networkId, network "prodbox-t-run" networkId])
          `shouldSatisfy` isLeft
        withDockerDaemonFixture path False $ \requests -> do
          result <- withConnectedDockerInfo 5000000 path $ \session (DockerConnectedInfo identifier _) _ -> do
            Just gate <- newKindDockerReadGate scope imageId
            runConnectedKindDockerRead gate session identifier request
              `shouldReturn` KindDockerReadCompleted (KindDockerNetworkIds [])
            readDockerSessionKindNetworkId session scope networkId `shouldReturn` Right False
            readDockerSessionKindNetworkId session scope "../invalid"
              `shouldReturn` Left DockerConnectedInfoInvalid
            runConnectedKindDockerRead gate session identifier foreignRequest
              `shouldReturn` KindDockerReadRefused
            runConnectedKindDockerRead gate session identifier request `shouldReturn` KindDockerReadRefused
          result `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted ())
          observed <- readMVar requests
          length (filter (isInfixOf "/networks?") observed) `shouldBe` 2
        forM_ [("prodbox-t-run", True), ("foreign", False)] $ \(name, expected) -> do
          let body = LazyBS8.toStrict (Aeson.encode (inventory [network name networkId]))
              fixturePath = path ++ show expected
          withDockerDaemonFixtureNetworks fixturePath body $ \_ -> do
            result <- withConnectedDockerInfo 5000000 fixturePath $ \session (DockerConnectedInfo identifier _) _ -> do
              Just gate <- newKindDockerReadGate scope imageId
              observed <- runConnectedKindDockerRead gate session identifier request
              observed
                `shouldBe` if expected
                  then KindDockerReadCompleted (KindDockerNetworkIds [networkId])
                  else KindDockerReadFailed DockerConnectedInfoInvalid
              readDockerSessionKindNetworkId session scope networkId
                `shouldReturn` if expected then Right True else Left DockerConnectedInfoInvalid
              when expected $
                readDockerSessionKindNetworkId session scope (replicate 64 'c')
                  `shouldReturn` Left DockerConnectedInfoInvalid
            result `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted ())

    it "observes only the built-in bridge MTU and rejects invalid options" $
      withSystemTempDirectory "prodbox-gated-bridge" $ \directory -> do
        let path = directory </> "docker.sock"
            imageId = "sha256:" ++ replicate 64 'a'
            bridge name driver options =
              Aeson.object
                [ AesonKey.fromString "Name" Aeson..= (name :: String)
                , AesonKey.fromString "Driver" Aeson..= (driver :: String)
                , AesonKey.fromString "Options" Aeson..= options
                ]
            option value = Aeson.object [AesonKey.fromString "com.docker.network.driver.mtu" Aeson..= (value :: String)]
            request = ["network", "inspect", "bridge", "-f", "{{ index .Options \"com.docker.network.driver.mtu\" }}"]
        scope <- either (fail . show) pure (deploymentScope directory Test "run" 26443)
        parseDockerBridgeMtu (bridge "bridge" "bridge" (Aeson.object [])) `shouldBe` Right Nothing
        parseDockerBridgeMtu (bridge "bridge" "bridge" (option "1500")) `shouldBe` Right (Just 1500)
        parseDockerBridgeMtu (bridge "foreign" "bridge" (option "1500")) `shouldSatisfy` isLeft
        parseDockerBridgeMtu (bridge "bridge" "overlay" (option "1500")) `shouldSatisfy` isLeft
        forM_ ["0", "65536", "01500", "1e3", "-1"] $ \invalid ->
          parseDockerBridgeMtu (bridge "bridge" "bridge" (option invalid)) `shouldSatisfy` isLeft
        withDockerDaemonFixture path False $ \requests -> do
          result <- withConnectedDockerInfo 5000000 path $ \session (DockerConnectedInfo identifier _) _ -> do
            Just gate <- newKindDockerReadGate scope imageId
            runConnectedKindDockerReply gate session identifier request
              `shouldReturn` KindDockerReply 0 (BS8.pack "<no value>\n") BS8.empty
            runConnectedKindDockerRead
              gate
              session
              identifier
              ["network", "inspect", "foreign", "-f", last request]
              `shouldReturn` KindDockerReadRefused
          result `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted ())
          observed <- readMVar requests
          length (filter (isInfixOf "/networks/bridge") observed) `shouldBe` 1
          observed `shouldSatisfy` all (not . isInfixOf "/networks/foreign")

    it "reads exact network details without treating an absent reply as absence" $
      withSystemTempDirectory "prodbox-network-details" $ \directory -> do
        let path = directory </> "docker.sock"
            networkId = replicate 64 'b'
            decode name identifier =
              Aeson.eitherDecodeStrict' $
                BS8.pack $
                  "{\"Name\":\""
                    ++ name
                    ++ "\",\"Id\":\""
                    ++ identifier
                    ++ "\",\"Driver\":\"bridge\",\"EnableIPv6\":true,\"Options\":null,\"Labels\":null,"
                    ++ "\"IPAM\":{\"Config\":[{\"Subnet\":\"fc00:c1c8:9c54:6b75::/64\"}]}}"
        scope <- either (fail . show) pure (deploymentScope directory Test "run" 26443)
        value <- either fail pure (decode "prodbox-t-run" networkId)
        foreignName <- either fail pure (decode "foreign" networkId)
        foreignId <- either fail pure (decode "prodbox-t-run" (replicate 64 'c'))
        parseDockerNetworkDetails scope networkId foreignName `shouldSatisfy` isLeft
        parseDockerNetworkDetails scope networkId foreignId `shouldSatisfy` isLeft
        details <- either fail pure (parseDockerNetworkDetails scope networkId value)
        dockerNetworkId details `shouldBe` networkId
        dockerNetworkSubnets details `shouldBe` ["fc00:c1c8:9c54:6b75::/64"]
        withDockerDaemonFixture path False $ \requests -> do
          result <- withConnectedDockerInfo 5000000 path $ \session _ _ -> do
            inspectDockerSessionKindNetwork session scope "../bridge"
              `shouldReturn` Left DockerConnectedInfoInvalid
            inspectDockerSessionKindNetwork session scope networkId `shouldReturn` Right details
            inspectDockerSessionKindNetwork session scope (replicate 64 'c')
              `shouldReturn` Left DockerConnectedInfoStatus
          result `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted ())
          observed <- readMVar requests
          length (filter (isInfixOf "/networks/") observed) `shouldBe` 2
          observed `shouldSatisfy` all (not . isInfixOf "../bridge")

    it "reconnects a recorded network attempt to the selected daemon" $
      withSystemTempDirectory "prodbox-network-recovery" $ \directory -> do
        let path = directory </> "docker.sock"
            selected = directory </> "selected.dhall"
            generation = replicate 32 'a'
            operation = replicate 32 'b'
            networkId = replicate 64 'b'
            body = BS8.pack ("[{\"Name\":\"prodbox-t-run\",\"Id\":\"" ++ networkId ++ "\"}]")
            document =
              "{ bootstrap = { schema_version = 2, project_anchor = \""
                ++ directory
                ++ "\", runtime_socket = \""
                ++ path
                ++ "\", environment = \"test\", deployment_id = \"run\", root_generation = \""
                ++ generation
                ++ "\", api_port = 26443, node_image = \"kindest/node@sha256:"
                ++ replicate 64 'a'
                ++ "\", http_host_port = 28080, http_node_port = 30080, https_host_port = 28443, https_node_port = 30443, "
                ++ "node_artifact = { path = \"artifacts/node.tar\", digest = \"sha256:"
                ++ replicate 64 'a'
                ++ "\", maximum_bytes = 4096 }, listen_address = \"127.0.0.1\" } }"
        writeFile selected document
        bootstrap <- readBootstrapProjection selected >>= either (fail . show) pure
        prepareFreshScope (bootstrapScope bootstrap) generation `shouldReturn` FreshScopePrepared
        daemonChanged <- newIORef False
        controlVisible <- newIORef True
        withDockerDaemonFixtureControl
          path
          False
          (const (pure ()))
          (readIORef daemonChanged)
          (BS8.pack "[]")
          body
          (readIORef controlVisible)
          $ \requests -> do
            identity <- observeDockerSocketIdentity path >>= maybe (fail "missing socket") pure
            intent <-
              maybe (fail "invalid network intent") pure $
                mkKindNetworkIntent
                  operation
                  "fc00:c1c8:9c54:6b75::/64"
                  (Just 1500)
                  (DockerDaemonObserved "daemon-a" identity)
            prepared <- withNewKindOperation bootstrap operation $ \stable -> do
              recordKindNetworkIntent bootstrap intent stable `shouldReturn` NetworkIntentRecorded
              recordKindNetworkAttempt bootstrap intent stable `shouldReturn` NetworkAttemptRecorded
            prepared `shouldBe` KindOperationCallbackReturned ()
            missingReceipt <- withRecoveredKindOperation bootstrap operation $ \operationStable ->
              withConnectedDockerInfo 5000000 path $ \session _ peerStable ->
                observeConfinedNodeNetwork
                  bootstrap
                  operation
                  networkId
                  (DockerDaemonObserved "daemon-a" identity)
                  session
                  ((&&) <$> operationStable <*> peerStable)
            missingReceipt
              `shouldBe` KindOperationCallbackReturned
                ( DockerPeerCompleted
                    (DockerConnectedInfoCompleted (ConfinedNodeNetworkReceiptRefused NetworkReceiptMissing))
                )
            result <- observeRecoveredKindNetwork bootstrap operation
            case result of
              KindOperationCallbackReturned
                (DockerPeerCompleted (DockerConnectedInfoCompleted (KindNetworkRecoverySampled sample))) -> do
                  networkAttemptBefore sample `shouldBe` NetworkAttemptMatches
                  networkAttemptAfter sample `shouldBe` NetworkAttemptMatches
                  networkRemovalBefore sample `shouldBe` NetworkRemovalRecoveryMissing
                  networkRemovalAfter sample `shouldBe` NetworkRemovalRecoveryMissing
                  networkInventory sample `shouldBe` Right [networkId]
                  case networkDetails sample of
                    Just (Right details) -> do
                      dockerNetworkId details `shouldBe` networkId
                      networkIndependent sample `shouldBe` NetworkIndependentObserved details
                      networkConfiguration sample `shouldBe` NetworkConfigurationDiffers
                      let correct =
                            details
                              { dockerNetworkOptions =
                                  Map.fromList
                                    [ ("com.docker.network.bridge.enable_ip_masquerade", "true")
                                    , ("com.docker.network.driver.mtu", "1500")
                                    ]
                              , dockerNetworkLabels =
                                  Map.fromList
                                    [ ("io.prodbox.deployment", "prodbox-t-run")
                                    , ("io.prodbox.generation", generation)
                                    , ("io.prodbox.operation", operation)
                                    ]
                              , dockerNetworkSubnets = ["172.20.0.0/16", "fc00:c1c8:9c54:6b75:0:0:0:0/64"]
                              }
                      compareKindNetworkConfiguration bootstrap intent correct `shouldBe` NetworkConfigurationMatches
                      compareKindNetworkConfiguration bootstrap intent (correct {dockerNetworkLabels = Map.empty})
                        `shouldBe` NetworkConfigurationDiffers
                      compareKindNetworkConfiguration bootstrap intent (correct {dockerNetworkIpv6 = False})
                        `shouldBe` NetworkConfigurationDiffers
                      compareKindNetworkConfiguration
                        bootstrap
                        intent
                        (correct {dockerNetworkSubnets = ["fc00:c1c8:9c54:6b76::/64"]})
                        `shouldBe` NetworkConfigurationDiffers
                      compareKindNetworkConfiguration bootstrap intent (correct {dockerNetworkOptions = Map.empty})
                        `shouldBe` NetworkConfigurationDiffers
                      sameKindNetworkSubnet "invalid" "invalid" `shouldBe` False
                    other -> expectationFailure ("unexpected network details: " ++ show other)
                  networkDaemonAfter sample `shouldBe` Right (DockerKindInfo "systemd" "2" True True True [])
              other -> expectationFailure ("unexpected network recovery: " ++ show other)
            observed <- readMVar requests
            length (filter (isInfixOf "/networks?") observed) `shouldBe` 1
            length (filter (isInfixOf ("/networks/" ++ networkId)) observed) `shouldBe` 2
            writeIORef daemonChanged True
            observeRecoveredKindNetwork bootstrap operation
              `shouldReturn` KindOperationCallbackReturned
                (DockerPeerCompleted (DockerConnectedInfoCompleted KindNetworkRecoveryDaemonMismatch))
            afterMismatch <- readMVar requests
            length (filter (isInfixOf "/networks?") afterMismatch) `shouldBe` 1
            writeIORef daemonChanged False
            called <- newIORef False
            refused <- withNewConnectedKindNetworkAttempt bootstrap operation $ \_ _ _ -> writeIORef called True
            refused
              `shouldBe` KindOperationCallbackReturned
                ( DockerPeerCompleted
                    (DockerConnectedInfoCompleted (KindNetworkAttemptMarkerRefused NetworkAttemptAlreadyExists))
                )
            readIORef called `shouldReturn` False
            removal <- withNewConnectedKindNetworkRemoval bootstrap operation networkId $ \_ _ -> writeIORef called True
            removal
              `shouldBe` KindOperationCallbackReturned
                (DockerPeerCompleted (DockerConnectedInfoCompleted KindNetworkRemovalConfigurationDiffers))
            readIORef called `shouldReturn` False
            withRecoveredKindOperation
              bootstrap
              operation
              (observeRecordedKindNetworkRemoval bootstrap operation)
              `shouldReturn` KindOperationCallbackReturned NetworkRemovalRecoveryMissing
            let contradictory = NetworkCreateTransport (DockerNetworkCreateReply 201 (Just (replicate 64 'c')))
            withRecoveredKindOperation
              bootstrap
              operation
              (recordNetworkReceipt bootstrap intent NetworkCreateReceipt contradictory)
              `shouldReturn` KindOperationCallbackReturned NetworkReceiptRecorded
            wrongReceipt <- withRecoveredKindOperation bootstrap operation $ \operationStable ->
              withConnectedDockerInfo 5000000 path $ \session _ peerStable ->
                observeConfinedNodeNetwork
                  bootstrap
                  operation
                  networkId
                  (DockerDaemonObserved "daemon-a" identity)
                  session
                  ((&&) <$> operationStable <*> peerStable)
            wrongReceipt
              `shouldBe` KindOperationCallbackReturned
                ( DockerPeerCompleted
                    ( DockerConnectedInfoCompleted
                        (ConfinedNodeNetworkReceiptRefused (NetworkReceiptObserved contradictory))
                    )
                )
            beforeContradiction <- readMVar requests
            contradiction <- withNewConnectedKindNetworkRemoval bootstrap operation networkId $ \_ _ -> writeIORef called True
            contradiction
              `shouldBe` KindOperationCallbackReturned
                ( DockerPeerCompleted
                    ( DockerConnectedInfoCompleted $
                        KindNetworkRemovalCreateReceiptRefused (NetworkReceiptObserved contradictory)
                    )
                )
            afterContradiction <- readMVar requests
            length (filter (isInfixOf ("/networks/" ++ networkId)) afterContradiction)
              `shouldBe` length (filter (isInfixOf ("/networks/" ++ networkId)) beforeContradiction)
            readIORef called `shouldReturn` False
            let createReceiptPath = scopeRoot (bootstrapScope bootstrap) </> "kind-network-create-result.json"
            BS8.writeFile createReceiptPath (BS8.pack "{")
            corrupt <- withNewConnectedKindNetworkRemoval bootstrap operation networkId $ \_ _ -> writeIORef called True
            corrupt
              `shouldBe` KindOperationCallbackReturned
                ( DockerPeerCompleted
                    ( DockerConnectedInfoCompleted $
                        KindNetworkRemovalCreateReceiptRefused NetworkReceiptInvalid
                    )
                )
            readIORef called `shouldReturn` False
            removeFile createReceiptPath
            withRecoveredKindOperation bootstrap operation (recordKindNetworkRemoval bootstrap intent networkId)
              `shouldReturn` KindOperationCallbackReturned NetworkRemovalRecorded
            afterRecord <- observeRecoveredKindNetwork bootstrap operation
            case afterRecord of
              KindOperationCallbackReturned
                (DockerPeerCompleted (DockerConnectedInfoCompleted (KindNetworkRecoverySampled sample))) -> do
                  networkRemovalIdObservation sample `shouldBe` Just (Right (Just True))
                  networkRemovalIndependentId sample `shouldBe` NetworkIndependentIdObserved True
              other -> expectationFailure ("unexpected removal observation: " ++ show other)
            beforeBlind <- readMVar requests
            writeIORef controlVisible False
            blind <- observeRecoveredKindNetwork bootstrap operation
            case blind of
              KindOperationCallbackReturned
                (DockerPeerCompleted (DockerConnectedInfoCompleted (KindNetworkRecoverySampled sample))) -> do
                  networkRemovalIdObservation sample `shouldBe` Just (Right Nothing)
                  networkRemovalIndependentId sample `shouldBe` NetworkIndependentIdBlind
              other -> expectationFailure ("unexpected blind observer: " ++ show other)
            afterBlind <- readMVar requests
            let targetQueries = filter (\line -> "/networks?" `isInfixOf` line && networkId `isInfixOf` line)
            length (targetQueries afterBlind) `shouldBe` length (targetQueries beforeBlind)
            writeIORef controlVisible True
            requestsBeforeRetry <- readMVar requests
            duplicate <- withNewConnectedKindNetworkRemoval bootstrap operation networkId $ \_ _ -> writeIORef called True
            duplicate
              `shouldBe` KindOperationCallbackReturned
                (DockerPeerCompleted (DockerConnectedInfoCompleted (KindNetworkRemovalPrior NetworkRemovalMatches)))
            readIORef called `shouldReturn` False
            requestsAfterRetry <- readMVar requests
            length (filter (isInfixOf ("/networks/" ++ networkId)) requestsAfterRetry)
              `shouldBe` length (filter (isInfixOf ("/networks/" ++ networkId)) requestsBeforeRetry)

    it "requires the recorded network and current matching Docker configuration for node work" $
      withSystemTempDirectory "prodbox-node-network-binding" $ \directory -> do
        let path = directory </> "docker.sock"
            selected = directory </> "selected.dhall"
            generation = replicate 32 'a'
            operation = replicate 32 'b'
            networkId = replicate 64 'c'
            document =
              "{ bootstrap = { schema_version = 1, project_anchor = \""
                ++ directory
                ++ "\", runtime_socket = \""
                ++ path
                ++ "\", environment = \"test\", deployment_id = \"run\", root_generation = \""
                ++ generation
                ++ "\", api_port = 26443, node_image = \"kindest/node@sha256:"
                ++ replicate 64 'a'
                ++ "\", http_host_port = 28080, http_node_port = 30080, https_host_port = 28443, https_node_port = 30443, listen_address = \"127.0.0.1\" } }"
        writeFile selected document
        bootstrap <- readBootstrapProjection selected >>= either (fail . show) pure
        prepareFreshScope (bootstrapScope bootstrap) generation `shouldReturn` FreshScopePrepared
        changed <- newIORef False
        withDockerNetworkBindingFixture path networkId generation operation (readIORef changed) $ do
          identity <- observeDockerSocketIdentity path >>= maybe (fail "missing socket") pure
          intent <-
            maybe (fail "invalid network intent") pure $
              mkKindNetworkIntent
                operation
                "fc00:c1c8:9c54:6b75::/64"
                (Just 1500)
                (DockerDaemonObserved "daemon-a" identity)
          withNewKindOperation
            bootstrap
            operation
            ( \stable -> do
                recordKindNetworkIntent bootstrap intent stable `shouldReturn` NetworkIntentRecorded
                recordKindNetworkAttempt bootstrap intent stable `shouldReturn` NetworkAttemptRecorded
                recordNetworkReceipt
                  bootstrap
                  intent
                  NetworkCreateReceipt
                  (NetworkCreateTransport (DockerNetworkCreateReply 201 (Just networkId)))
                  stable
            )
            `shouldReturn` KindOperationCallbackReturned NetworkReceiptRecorded
          observed <- withRecoveredKindOperation bootstrap operation $ \operationStable ->
            withConnectedDockerInfo 5000000 path $ \session _ peerStable -> do
              let stable = (&&) <$> operationStable <*> peerStable
                  sample =
                    observeConfinedNodeNetwork
                      bootstrap
                      operation
                      networkId
                      (DockerDaemonObserved "daemon-a" identity)
                      session
                      stable
              sample `shouldReturn` ConfinedNodeNetworkReady
              writeIORef changed True
              sample `shouldReturn` ConfinedNodeNetworkDetailsRefused Nothing
          observed
            `shouldBe` KindOperationCallbackReturned (DockerPeerCompleted (DockerConnectedInfoCompleted ()))

    it "submits one scoped network request and retains a lost reply as unconfirmed" $
      forM_ [True, False] $ \reply ->
        withSystemTempDirectory "prodbox-network-create" $ \directory -> do
          let path = directory </> "docker.sock"
              selected = directory </> "selected.dhall"
              operation = replicate 32 'b'
              document =
                "{ bootstrap = { schema_version = 2, project_anchor = \""
                  ++ directory
                  ++ "\", runtime_socket = \""
                  ++ path
                  ++ "\", environment = \"test\", deployment_id = \"run\", root_generation = \""
                  ++ replicate 32 'a'
                  ++ "\", api_port = 26443, node_image = \"kindest/node@sha256:"
                  ++ replicate 64 'a'
                  ++ "\", http_host_port = 28080, http_node_port = 30080, https_host_port = 28443, https_node_port = 30443, "
                  ++ "node_artifact = { path = \"artifacts/node.tar\", digest = \"sha256:"
                  ++ replicate 64 'a'
                  ++ "\", maximum_bytes = 4096 }, listen_address = \"127.0.0.1\" } }"
          writeFile selected document
          bootstrap <- readBootstrapProjection selected >>= either (fail . show) pure
          prepareFreshScope (bootstrapScope bootstrap) (replicate 32 'a') `shouldReturn` FreshScopePrepared
          withDockerNetworkCreateFixture path reply $ \received -> do
            identity <- observeDockerSocketIdentity path >>= maybe (fail "missing socket") pure
            intent <-
              maybe (fail "invalid network intent") pure $
                mkKindNetworkIntent
                  operation
                  "fc00:c1c8:9c54:6b75::/64"
                  (Just 1500)
                  (DockerDaemonObserved "daemon-a" identity)
            withNewKindOperation bootstrap operation (recordKindNetworkIntent bootstrap intent)
              `shouldReturn` KindOperationCallbackReturned NetworkIntentRecorded
            result <- withRecoveredKindOperation bootstrap operation $ \operationStable ->
              withConnectedDockerInfo 30000000 path $ \session info peerStable ->
                runKindNetworkRecordedAttemptOnSession
                  bootstrap
                  operation
                  session
                  info
                  ((&&) <$> operationStable <*> peerStable)
                  $ \recorded held stable -> do
                    recorded `shouldBe` intent
                    createDockerSessionKindNetwork held bootstrap intent (pure False)
                      `shouldReturn` DockerNetworkCreateNotStarted
                    createDockerSessionKindNetwork held bootstrap intent stable
            let transport =
                  NetworkCreateTransport $
                    if reply
                      then DockerNetworkCreateReply 201 (Just (replicate 64 'c'))
                      else DockerNetworkCreateUnconfirmed
            result
              `shouldBe` KindOperationCallbackReturned
                ( DockerPeerCompleted
                    ( DockerConnectedInfoCompleted
                        ( KindNetworkAttemptReturned $
                            KindNetworkRecordedTransport transport NetworkReceiptRecorded
                        )
                    )
                )
            withRecoveredKindOperation bootstrap operation (observeKindNetworkAttempt bootstrap intent)
              `shouldReturn` KindOperationCallbackReturned NetworkAttemptMatches
            withRecoveredKindOperation
              bootstrap
              operation
              (observeNetworkReceipt bootstrap intent NetworkCreateReceipt)
              `shouldReturn` KindOperationCallbackReturned (NetworkReceiptObserved transport)
            withRecoveredKindOperation
              bootstrap
              operation
              (recordNetworkReceipt bootstrap intent NetworkCreateReceipt transport)
              `shouldReturn` KindOperationCallbackReturned NetworkReceiptAlreadyExists
            withRecoveredKindOperation
              bootstrap
              operation
              ( recordNetworkReceipt
                  bootstrap
                  intent
                  NetworkCreateReceipt
                  (NetworkCreateTransport (DockerNetworkCreateReply 201 Nothing))
              )
              `shouldReturn` KindOperationCallbackReturned NetworkReceiptRefused
            let receiptPath = scopeRoot (bootstrapScope bootstrap) </> "kind-network-create-result.json"
                receiptBackup = directory </> "network-receipt-backup"
            receiptBytes <- BS8.readFile receiptPath
            BS8.writeFile receiptPath (BS8.pack "{")
            withRecoveredKindOperation
              bootstrap
              operation
              (observeNetworkReceipt bootstrap intent NetworkCreateReceipt)
              `shouldReturn` KindOperationCallbackReturned NetworkReceiptInvalid
            BS8.writeFile receiptPath receiptBytes
            renameFile receiptPath receiptBackup
            createSymbolicLink receiptBackup receiptPath
            withRecoveredKindOperation
              bootstrap
              operation
              (observeNetworkReceipt bootstrap intent NetworkCreateReceipt)
              `shouldReturn` KindOperationCallbackReturned NetworkReceiptUnobservable
            BS8.readFile receiptBackup `shouldReturn` receiptBytes
            removeFile receiptPath
            renameFile receiptBackup receiptPath
            bytes <- readMVar received
            let expected =
                  Aeson.object
                    [ AesonKey.fromString "Name" Aeson..= ("prodbox-t-run" :: String)
                    , AesonKey.fromString "CheckDuplicate" Aeson..= True
                    , AesonKey.fromString "Driver" Aeson..= ("bridge" :: String)
                    , AesonKey.fromString "EnableIPv6" Aeson..= True
                    , AesonKey.fromString "Options"
                        Aeson..= Aeson.object
                          [ AesonKey.fromString "com.docker.network.bridge.enable_ip_masquerade" Aeson..= ("true" :: String)
                          , AesonKey.fromString "com.docker.network.driver.mtu" Aeson..= ("1500" :: String)
                          ]
                    , AesonKey.fromString "Labels"
                        Aeson..= Aeson.object
                          [ AesonKey.fromString "io.prodbox.deployment" Aeson..= ("prodbox-t-run" :: String)
                          , AesonKey.fromString "io.prodbox.generation" Aeson..= replicate 32 'a'
                          , AesonKey.fromString "io.prodbox.operation" Aeson..= operation
                          ]
                    , AesonKey.fromString "IPAM"
                        Aeson..= Aeson.object
                          [ AesonKey.fromString "Config"
                              Aeson..= [ Aeson.object
                                           [AesonKey.fromString "Subnet" Aeson..= ("fc00:c1c8:9c54:6b75::/64" :: String)]
                                       ]
                          ]
                    ]
            Aeson.decodeStrict' bytes `shouldBe` Just expected

    it "removes only a full network ID and preserves an interrupted reply" $
      forM_ [Just 204, Just 404, Nothing] $ \reply ->
        withSystemTempDirectory "prodbox-network-remove" $ \directory -> do
          let path = directory </> "docker.sock"
              identifier = replicate 64 'c'
          withDockerNetworkRemoveFixture path reply $ \received -> do
            result <- withConnectedDockerInfo 5000000 path $ \session _ stable -> do
              removeDockerSessionKindNetwork session "../bridge" stable
                `shouldReturn` DockerNetworkRemoveNotStarted
              removeDockerSessionKindNetwork session identifier (pure False)
                `shouldReturn` DockerNetworkRemoveNotStarted
              removeDockerSessionKindNetwork session identifier stable
            result
              `shouldBe` DockerPeerCompleted
                ( DockerConnectedInfoCompleted $
                    maybe DockerNetworkRemoveUnconfirmed DockerNetworkRemoveReply reply
                )
            readMVar received `shouldReturn` ("DELETE /networks/" ++ identifier ++ " HTTP/1.1")

    it "records a scoped removal before entering its connected callback" $
      forM_ [Just 204, Nothing, Just 418] $ \reply ->
        withSystemTempDirectory "prodbox-network-remove-bound" $ \directory -> do
          let path = directory </> "docker.sock"
              selected = directory </> "selected.dhall"
              operation = replicate 32 'b'
              networkId = replicate 64 'c'
              generation = replicate 32 'a'
              document =
                "{ bootstrap = { schema_version = 2, project_anchor = \""
                  ++ directory
                  ++ "\", runtime_socket = \""
                  ++ path
                  ++ "\", environment = \"test\", deployment_id = \"run\", root_generation = \""
                  ++ generation
                  ++ "\", api_port = 26443, node_image = \"kindest/node@sha256:"
                  ++ replicate 64 'a'
                  ++ "\", http_host_port = 28080, http_node_port = 30080, https_host_port = 28443, https_node_port = 30443, "
                  ++ "node_artifact = { path = \"artifacts/node.tar\", digest = \"sha256:"
                  ++ replicate 64 'a'
                  ++ "\", maximum_bytes = 4096 }, listen_address = \"127.0.0.1\" } }"
          writeFile selected document
          bootstrap <- readBootstrapProjection selected >>= either (fail . show) pure
          prepareFreshScope (bootstrapScope bootstrap) generation `shouldReturn` FreshScopePrepared
          withDockerNetworkRemoveFixtureMode path reply True $ \received -> do
            identity <- observeDockerSocketIdentity path >>= maybe (fail "missing socket") pure
            intent <-
              maybe (fail "invalid network intent") pure $
                mkKindNetworkIntent
                  operation
                  "fc00:c1c8:9c54:6b75::/64"
                  (Just 1500)
                  (DockerDaemonObserved "daemon-a" identity)
            prepared <- withNewKindOperation bootstrap operation $ \stable -> do
              recordKindNetworkIntent bootstrap intent stable `shouldReturn` NetworkIntentRecorded
              recordKindNetworkAttempt bootstrap intent stable `shouldReturn` NetworkAttemptRecorded
              let createResult =
                    if reply == Just 204
                      then DockerNetworkCreateReply 201 (Just networkId)
                      else DockerNetworkCreateUnconfirmed
              recordNetworkReceipt
                bootstrap
                intent
                NetworkCreateReceipt
                (NetworkCreateTransport createResult)
                stable
                `shouldReturn` NetworkReceiptRecorded
            prepared `shouldBe` KindOperationCallbackReturned ()
            result <- withNewConnectedKindNetworkRecordedRemoval bootstrap operation networkId $ \session stable -> do
              observeKindNetworkRemoval bootstrap intent networkId stable `shouldReturn` NetworkRemovalMatches
              when (reply == Just 418) $
                BS8.writeFile
                  (scopeRoot (bootstrapScope bootstrap) </> "kind-network-create-result.json")
                  (BS8.pack "{")
              removeDockerSessionKindNetwork session networkId stable
            let transport = NetworkRemovalTransport (maybe DockerNetworkRemoveUnconfirmed DockerNetworkRemoveReply reply)
            if reply == Just 418
              then do
                result
                  `shouldBe` KindOperationCallbackReturned
                    ( DockerPeerCompleted
                        ( DockerConnectedInfoCompleted
                            ( KindNetworkRemovalChangedAfter $
                                KindNetworkRecordedTransport
                                  (NetworkRemovalTransport DockerNetworkRemoveNotStarted)
                                  NetworkReceiptRefused
                            )
                        )
                    )
                tryReadMVar received `shouldReturn` Nothing
              else do
                result
                  `shouldBe` KindOperationCallbackReturned
                    ( DockerPeerCompleted
                        ( DockerConnectedInfoCompleted
                            ( KindNetworkRemovalReturned $
                                KindNetworkRecordedTransport transport NetworkReceiptRecorded
                            )
                        )
                    )
                readMVar received `shouldReturn` ("DELETE /networks/" ++ networkId ++ " HTTP/1.1")
            withRecoveredKindOperation
              bootstrap
              operation
              (observeRecordedKindNetworkRemoval bootstrap operation)
              `shouldReturn` KindOperationCallbackReturned (NetworkRemovalRecoveryRecorded networkId)
            when (reply /= Just 418) $
              withRecoveredKindOperation
                bootstrap
                operation
                (observeNetworkReceipt bootstrap intent (NetworkRemovalReceipt networkId))
                `shouldReturn` KindOperationCallbackReturned (NetworkReceiptObserved transport)

    it "refuses network effects when a stale receipt predates the new marker" $
      forM_ [False, True] $ \removal ->
        withSystemTempDirectory "prodbox-network-stale-receipt" $ \directory -> do
          let path = directory </> "docker.sock"
              selected = directory </> "selected.dhall"
              operation = replicate 32 'b'
              networkId = replicate 64 'c'
              generation = replicate 32 'a'
              document =
                "{ bootstrap = { schema_version = 2, project_anchor = \""
                  ++ directory
                  ++ "\", runtime_socket = \""
                  ++ path
                  ++ "\", environment = \"test\", deployment_id = \"run\", root_generation = \""
                  ++ generation
                  ++ "\", api_port = 26443, node_image = \"kindest/node@sha256:"
                  ++ replicate 64 'a'
                  ++ "\", http_host_port = 28080, http_node_port = 30080, https_host_port = 28443, https_node_port = 30443, "
                  ++ "node_artifact = { path = \"artifacts/node.tar\", digest = \"sha256:"
                  ++ replicate 64 'a'
                  ++ "\", maximum_bytes = 4096 }, listen_address = \"127.0.0.1\" } }"
          writeFile selected document
          bootstrap <- readBootstrapProjection selected >>= either (fail . show) pure
          prepareFreshScope (bootstrapScope bootstrap) generation `shouldReturn` FreshScopePrepared
          let exercise = do
                identity <- observeDockerSocketIdentity path >>= maybe (fail "missing socket") pure
                intent <-
                  maybe (fail "invalid network intent") pure $
                    mkKindNetworkIntent
                      operation
                      "fc00:c1c8:9c54:6b75::/64"
                      (Just 1500)
                      (DockerDaemonObserved "daemon-a" identity)
                prepared <- withNewKindOperation bootstrap operation $ \stable -> do
                  recordKindNetworkIntent bootstrap intent stable `shouldReturn` NetworkIntentRecorded
                  when
                    removal
                    (recordKindNetworkAttempt bootstrap intent stable `shouldReturn` NetworkAttemptRecorded)
                prepared `shouldBe` KindOperationCallbackReturned ()
                let filename = if removal then "kind-network-removal-result.json" else "kind-network-create-result.json"
                    receiptPath = scopeRoot (bootstrapScope bootstrap) </> filename
                BS8.writeFile receiptPath (BS8.pack "{}")
                setFileMode receiptPath 0o600
                called <- newIORef False
                if removal
                  then do
                    result <- withNewConnectedKindNetworkRemoval bootstrap operation networkId $ \_ _ -> writeIORef called True
                    result
                      `shouldBe` KindOperationCallbackReturned
                        ( DockerPeerCompleted
                            (DockerConnectedInfoCompleted (KindNetworkRemovalReceiptRefused NetworkReceiptInvalid))
                        )
                    withRecoveredKindOperation
                      bootstrap
                      operation
                      (observeRecordedKindNetworkRemoval bootstrap operation)
                      `shouldReturn` KindOperationCallbackReturned (NetworkRemovalRecoveryRecorded networkId)
                  else do
                    result <- withNewConnectedKindNetworkAttempt bootstrap operation $ \_ _ _ -> writeIORef called True
                    result
                      `shouldBe` KindOperationCallbackReturned
                        ( DockerPeerCompleted
                            (DockerConnectedInfoCompleted (KindNetworkAttemptReceiptRefused NetworkReceiptInvalid))
                        )
                    withRecoveredKindOperation bootstrap operation (observeKindNetworkAttempt bootstrap intent)
                      `shouldReturn` KindOperationCallbackReturned NetworkAttemptMatches
                readIORef called `shouldReturn` False
                BS8.readFile receiptPath `shouldReturn` BS8.pack "{}"
          if removal
            then withDockerNetworkRemoveFixtureMode path (Just 204) True (const exercise)
            else withDockerDaemonFixture path False (const exercise)

    it "returns the exact selected control-plane name from held inventory" $
      withSystemTempDirectory "prodbox-gated-session-owned-name" $ \directory -> do
        let path = directory </> "docker.sock"
            imageId = "sha256:" ++ replicate 64 'a'
            listRequest = ["ps", "-a", "--filter", "label=io.x-k8s.kind.cluster=prodbox-t-run", "--format", "{{.Names}}"]
            body =
              BS8.pack $
                "[{\"Id\":\""
                  ++ replicate 64 'b'
                  ++ "\",\"Names\":[\"/prodbox-t-run-control-plane\"],\"Labels\":{\"io.x-k8s.kind.cluster\":\"prodbox-t-run\"}}]"
        scope <- either (fail . show) pure (deploymentScope directory Test "run" 26443)
        withDockerDaemonFixtureContainers path body $ \_ -> do
          result <- withConnectedDockerInfo 5000000 path $ \session (DockerConnectedInfo identifier _) _ -> do
            Just gate <- newKindDockerReadGate scope imageId
            runConnectedKindDockerRead gate session identifier listRequest
              `shouldReturn` KindDockerReadCompleted (KindDockerContainerNames ["prodbox-t-run-control-plane"])
          result `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted ())

    it "projects kind cluster inventory only from validated selected containers" $
      withSystemTempDirectory "prodbox-gated-cluster-label" $ \directory -> do
        let path = directory </> "docker.sock"
            imageId = "sha256:" ++ replicate 64 'a'
            request =
              [ "ps"
              , "-a"
              , "--filter"
              , "label=io.x-k8s.kind.cluster"
              , "--format"
              , "{{.Label \"io.x-k8s.kind.cluster\"}}"
              ]
            body label =
              BS8.pack $
                "[{\"Id\":\""
                  ++ replicate 64 'b'
                  ++ "\",\"Names\":[\"/prodbox-t-run-control-plane\"],\"Labels\":{\"io.x-k8s.kind.cluster\":\""
                  ++ label
                  ++ "\"}}]"
        scope <- either (fail . show) pure (deploymentScope directory Test "run" 26443)
        forM_ [(body "prodbox-t-run", True), (body "foreign", False), (BS8.pack "[]", True)] $ \(contents, valid) ->
          withDockerDaemonFixtureContainers path contents $ \requests -> do
            result <- withConnectedDockerInfo 5000000 path $ \session (DockerConnectedInfo identifier _) _ -> do
              Just gate <- newKindDockerReadGate scope imageId
              kindDockerInventoryObserved gate `shouldReturn` False
              reply <- runConnectedKindDockerReply gate session identifier request
              kindDockerInventoryObserved gate `shouldReturn` valid
              if valid
                then
                  reply
                    `shouldBe` KindDockerReply
                      0
                      (if contents == BS8.pack "[]" then BS8.empty else BS8.pack "prodbox-t-run\n")
                      BS8.empty
                else kindDockerReplyExit reply `shouldBe` 1
            result `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted ())
            observed <- readMVar requests
            observed `shouldSatisfy` any (isInfixOf "io.x-k8s.kind.cluster%3Dprodbox-t-run")

    it "requires a settled broker exchange before interpreting confined kind inventory" $ do
      let selected = "prodbox-t-run"
          wrap broker output observed clear =
            KindOperationCallbackReturned $
              KindDockerEndpointObserved $
                ConfinedKindInventoryObserved
                  broker
                  (KindDockerWorkerReturned (Right output))
                  observed
                  (if clear then KindDockerMarkerClear else KindDockerMarkerRetained)
                  (Just KindDockerClientLinkRemoved)
          success stdout = Subprocess.ProcessOutput ExitSuccess stdout ""
          conclude = interpretConfinedKindInventory selected
      conclude (wrap KindDockerBrokerCancelled (success "") True True)
        `shouldBe` ConfinedKindInventorySelected False
      conclude (wrap KindDockerBrokerCancelled (success (selected ++ "\n")) True True)
        `shouldBe` ConfinedKindInventorySelected True
      let verified = ConfinedSnapshotsReady (wrap KindDockerBrokerCancelled (success "") True True)
      interpretVerifiedConfinedKindInventory selected (ConfinedKindSnapshotsAttempted verified True)
        `shouldBe` ConfinedKindInventorySelected False
      interpretVerifiedConfinedKindInventory selected (ConfinedKindSnapshotsAttempted verified False)
        `shouldBe` ConfinedKindInventoryUnconfirmed
      let verifiedResult = ConfinedKindSnapshotsAttempted verified True
          connected value = DockerConnectedInfoCompleted value
      interpretConnectedConfinedKindInventory
        selected
        (DockerPeerCompleted (connected (ConfinedDockerBindingObserved verifiedResult)))
        `shouldBe` ConfinedKindInventorySelected False
      interpretConnectedConfinedKindInventory
        selected
        (DockerPeerCompleted (connected (ConfinedDockerBindingChanged verifiedResult)))
        `shouldBe` ConfinedKindInventoryUnconfirmed
      interpretConnectedConfinedKindInventory
        selected
        (DockerPeerChanged (connected (ConfinedDockerBindingObserved verifiedResult)))
        `shouldBe` ConfinedKindInventoryUnconfirmed
      let archiveResult =
            ConfinedArchiveInventoryObserved $
              ConfinedImageRecordObserved $
                DockerPeerCompleted (connected (ConfinedDockerBindingObserved verifiedResult))
      interpretArchiveBoundConfinedKindInventory selected (InspectedArchiveCompleted archiveResult)
        `shouldBe` ConfinedKindInventorySelected False
      interpretArchiveBoundConfinedKindInventory selected (InspectedArchiveChanged archiveResult)
        `shouldBe` ConfinedKindInventoryUnconfirmed
      interpretArchiveBoundConfinedKindInventory
        selected
        (InspectedArchiveUnconfirmedAfter archiveResult NodeArchiveTimedOut)
        `shouldBe` ConfinedKindInventoryUnconfirmed
      forM_
        [ wrap KindDockerBrokerCancelled (success "") False True
        , wrap KindDockerBrokerCancelled (success "") True False
        , wrap KindDockerBrokerCancelled (success "foreign\n") True True
        , wrap KindDockerBrokerCancelled (success (selected ++ "\nforeign\n")) True True
        , wrap KindDockerBrokerCancelled (Subprocess.ProcessOutput (ExitFailure 1) "" "") True True
        , wrap (KindDockerBrokerReturned KindDockerEndpointRefused) (success "") True True
        , KindOperationCallbackReturned $
            KindDockerEndpointObserved $
              ConfinedKindInventoryObserved
                KindDockerBrokerCancelled
                (KindDockerWorkerReturned (Right (success "")))
                True
                KindDockerMarkerClear
                Nothing
        ]
        $ \outcome -> conclude outcome `shouldBe` ConfinedKindInventoryUnconfirmed
      withSystemTempDirectory "prodbox-kind-marker-observation" $ \directory -> do
        let path = directory </> "marker"
        writeFile path ""
        descriptor <- Posix.openFd path Posix.ReadOnly Posix.defaultFileFlags
        observeKindDockerMarker descriptor `shouldReturn` KindDockerMarkerClear
        writeFile path "in flight"
        observeKindDockerMarker descriptor `shouldReturn` KindDockerMarkerRetained
        Posix.closeFd descriptor
        marker <- observeKindDockerMarker descriptor
        case marker of
          KindDockerMarkerUnobservable _ -> pure ()
          other -> expectationFailure ("failed marker read was not preserved: " ++ show other)
        let interrupted =
              KindOperationCallbackReturned $
                KindDockerEndpointObserved $
                  ConfinedKindInventoryObserved
                    KindDockerBrokerCancelled
                    (KindDockerWorkerReturned (Right (success "")))
                    True
                    marker
                    Nothing
        conclude interrupted `shouldBe` ConfinedKindInventoryUnconfirmed

    it "projects only validated kind replies and stays closed after a pull request" $
      withSystemTempDirectory "prodbox-kind-reply" $ \directory -> do
        let path = directory </> "docker.sock"
            imageId = "sha256:" ++ replicate 64 'a'
            infoRequest = ["info", "--format", "{{json .}}"]
            imageRequest = ["inspect", "--type=image", imageId]
            listRequest = ["ps", "-a", "--filter", "label=io.x-k8s.kind.cluster=prodbox-t-run", "--format", "{{.Names}}"]
        scope <- either (fail . show) pure (deploymentScope directory Test "run" 26443)
        withDockerDaemonFixture path False $ \requests -> do
          result <- withConnectedDockerInfo 5000000 path $ \session (DockerConnectedInfo identifier _) _ -> do
            Just gate <- newKindDockerReadGate scope imageId
            info <- runConnectedKindDockerReply gate session identifier infoRequest
            kindDockerReplyExit info `shouldBe` 0
            Aeson.decodeStrict' (kindDockerReplyStdout info)
              `shouldBe` Just
                ( Aeson.object
                    [ AesonKey.fromString "CgroupDriver" Aeson..= ("systemd" :: String)
                    , AesonKey.fromString "CgroupVersion" Aeson..= ("2" :: String)
                    , AesonKey.fromString "MemoryLimit" Aeson..= True
                    , AesonKey.fromString "PidsLimit" Aeson..= True
                    , AesonKey.fromString "CPUShares" Aeson..= True
                    , AesonKey.fromString "SecurityOptions" Aeson..= ([] :: [String])
                    ]
                )
            runConnectedKindDockerReply gate session identifier imageRequest
              `shouldReturn` KindDockerReply 0 BS8.empty BS8.empty
            runConnectedKindDockerReply gate session identifier listRequest
              `shouldReturn` KindDockerReply 0 BS8.empty BS8.empty
            denied <- runConnectedKindDockerReply gate session identifier ["pull", imageId]
            kindDockerReplyExit denied `shouldBe` 1
            kindDockerReplyStderr denied `shouldSatisfy` (not . BS8.null)
            runConnectedKindDockerReply gate session identifier imageRequest `shouldReturn` denied
          result `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted ())
          observed <- readMVar requests
          length observed `shouldBe` 4
          observed `shouldSatisfy` all (not . isInfixOf "/images/create")

    it "serves bounded read frames and stops at the first refused request" $
      withSystemTempDirectory "prodbox-kind-framed-reads" $ \directory -> do
        let path = directory </> "docker.sock"
            inputPath = directory </> "requests"
            outputPath = directory </> "replies"
            imageId = "sha256:" ++ replicate 64 'a'
            infoRequest = ["info", "--format", "{{json .}}"]
            imageRequest = ["inspect", "--type=image", imageId]
            frame argv =
              let payload = LazyBS8.toStrict (Aeson.encode (argv :: [String]))
                  size = BS.length payload
               in BS.pack (map (fromIntegral . (size `div`)) [16777216, 65536, 256, 1]) <> payload
            unframe bytes
              | BS.null bytes = Just []
              | BS.length bytes < 4 = Nothing
              | otherwise =
                  let (header, rest) = BS.splitAt 4 bytes
                      size = BS.foldl' (\value byte -> value * 256 + fromIntegral byte) 0 header
                      (payload, remaining) = BS.splitAt size rest
                   in if size > BS.length rest then Nothing else (payload :) <$> unframe remaining
        scope <- either (fail . show) pure (deploymentScope directory Test "run" 26443)
        BS.writeFile
          inputPath
          (BS.concat (map frame [infoRequest, imageRequest, ["pull", imageId], imageRequest]))
        withDockerDaemonFixture path False $ \requests -> do
          result <- withConnectedDockerInfo 5000000 path $ \session (DockerConnectedInfo identifier _) _ -> do
            Just gate <- newKindDockerReadGate scope imageId
            IO.withBinaryFile inputPath IO.ReadMode $ \input ->
              IO.withBinaryFile outputPath IO.WriteMode $ \output ->
                serveKindDockerReads gate session identifier input output `shouldReturn` KindDockerProtocolRejected
            runConnectedKindDockerReply gate session identifier imageRequest
              `shouldReturn` KindDockerReply 1 BS.empty (BS8.pack "Error: kind Docker request unavailable\n")
            let malformedPath = directory </> "malformed"
                malformedFrames =
                  [ BS.pack [0, 1]
                  , BS.pack [0, 0, 0, 0]
                  , BS.pack [0, 0, 64, 1]
                  , BS.pack [255, 255, 255, 255]
                  , BS.pack [0, 0, 0, 2, 91]
                  , BS.pack [0, 0, 0, 1, 91]
                  , BS.pack [0, 0, 0, 2, 91, 93]
                  ]
            forM_ malformedFrames $ \bytes -> do
              BS.writeFile malformedPath bytes
              Just malformedGate <- newKindDockerReadGate scope imageId
              IO.withBinaryFile malformedPath IO.ReadMode $ \input ->
                IO.withBinaryFile (directory </> "malformed-replies") IO.WriteMode $ \output ->
                  serveKindDockerReads malformedGate session identifier input output
                    `shouldReturn` KindDockerProtocolMalformed
              runConnectedKindDockerReply malformedGate session identifier imageRequest
                `shouldReturn` KindDockerReply 1 BS.empty (BS8.pack "Error: kind Docker request unavailable\n")
            let failingPath = directory </> "failing-output-input"
            BS.writeFile failingPath (frame infoRequest)
            Just failedOutputGate <- newKindDockerReadGate scope imageId
            closedOutput <- IO.openBinaryFile (directory </> "closed-output") IO.WriteMode
            IO.hClose closedOutput
            outputFailure <-
              IO.withBinaryFile failingPath IO.ReadMode $ \input ->
                try (serveKindDockerReads failedOutputGate session identifier input closedOutput)
            case outputFailure :: Either IOException KindDockerProtocolOutcome of
              Left _ -> pure ()
              Right other -> expectationFailure ("closed output did not fail: " ++ show other)
            runConnectedKindDockerReply failedOutputGate session identifier imageRequest
              `shouldReturn` KindDockerReply 1 BS.empty (BS8.pack "Error: kind Docker request unavailable\n")
          result `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted ())
          replies <- maybe (fail "invalid response framing") pure . unframe =<< BS.readFile outputPath
          length replies `shouldBe` 3
          map (BS8.isInfixOf (BS8.pack "\"exit\":0")) replies `shouldBe` [True, True, False]
          last replies `shouldSatisfy` BS8.isInfixOf (BS8.pack "\"exit\":1")
          observed <- readMVar requests
          length observed `shouldBe` 4
          length (filter (isInfixOf "/images/") observed) `shouldBe` 1

    it "exchanges kind reads over a framed duplex channel" $
      withSystemTempDirectory "prodbox-kind-duplex" $ \directory -> do
        let path = directory </> "docker.sock"
            imageId = "sha256:" ++ replicate 64 'a'
            infoRequest = ["info", "--format", "{{json .}}"]
            imageRequest = ["inspect", "--type=image", imageId]
            withPipe action =
              bracket
                ( do
                    (readEnd, writeEnd) <- Posix.createPipe
                    (,) <$> Posix.fdToHandle readEnd <*> Posix.fdToHandle writeEnd
                )
                (\(reader, writer) -> IO.hClose reader >> IO.hClose writer)
                action
        scope <- either (fail . show) pure (deploymentScope directory Test "run" 26443)
        withDockerDaemonFixture path False $ \requests -> do
          result <- withConnectedDockerInfo 5000000 path $ \session (DockerConnectedInfo identifier _) _ -> do
            Just gate <- newKindDockerReadGate scope imageId
            withPipe $ \(serverInput, clientOutput) ->
              withPipe $ \(clientInput, serverOutput) -> do
                outcome <- newEmptyMVar
                bracket
                  ( forkIO
                      (try (serveKindDockerReads gate session identifier serverInput serverOutput) >>= putMVar outcome)
                  )
                  killThread
                  $ \_ -> do
                    reply <- exchangeKindDockerRead clientInput clientOutput infoRequest
                    case reply of
                      Right value -> kindDockerReplyExit value `shouldBe` 0
                      Left failure -> expectationFailure (show failure)
                    exchangeKindDockerRead clientInput clientOutput imageRequest
                      `shouldReturn` Right (KindDockerReply 0 BS.empty BS.empty)
                    denied <- exchangeKindDockerRead clientInput clientOutput ("run" : replicate 37 "unadmitted")
                    case denied of
                      Right value -> kindDockerReplyExit value `shouldBe` 1
                      Left failure -> expectationFailure (show failure)
                    completed <- timeout 3000000 (takeMVar outcome)
                    case completed :: Maybe (Either SomeException KindDockerProtocolOutcome) of
                      Just (Right KindDockerProtocolRejected) -> pure ()
                      other -> expectationFailure ("server did not settle: " ++ show other)
          result `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted ())
          observed <- readMVar requests
          length observed `shouldBe` 3
          length (filter (isInfixOf "/images/") observed) `shouldBe` 1

    it "rejects malformed and ambiguous framed client replies" $
      withSystemTempDirectory "prodbox-kind-client-replies" $ \directory -> do
        let inputPath = directory </> "reply"
            outputPath = directory </> "request"
            frame body =
              let size = BS.length body
               in BS.pack (map (fromIntegral . (size `div`)) [16777216, 65536, 256, 1]) <> body
            malformed =
              [ BS.pack [0, 1]
              , BS.pack [0, 0, 0, 0]
              , BS.pack [0, 2, 0, 1]
              , BS.pack [255, 255, 255, 255]
              , BS.pack [0, 0, 0, 2, 91]
              , frame (BS8.pack "{")
              , frame (BS8.pack "{\"exit\":0,\"exit\":1,\"stdout\":\"\",\"stderr\":\"\"}")
              , frame (BS8.pack "{\"exit\":2,\"stdout\":\"\",\"stderr\":\"\"}")
              , frame (BS8.pack "{\"exit\":0,\"stdout\":\"\",\"stderr\":\"error\"}")
              , frame (BS8.pack "{\"exit\":0,\"stdout\":\"\\u00e9\",\"stderr\":\"\"}")
              , frame (BS8.pack "{\"exit\":0,\"stdout\":\"\",\"stderr\":\"\",\"extra\":1}")
              ]
        forM_ malformed $ \bytes -> do
          BS.writeFile inputPath bytes
          IO.withBinaryFile inputPath IO.ReadMode $ \input ->
            IO.withBinaryFile outputPath IO.WriteMode $ \output ->
              exchangeKindDockerRead input output ["info", "--format", "{{json .}}"]
                `shouldReturn` Left KindDockerClientInvalidReply
        BS.writeFile inputPath BS.empty
        IO.withBinaryFile inputPath IO.ReadMode $ \input ->
          IO.withBinaryFile outputPath IO.WriteMode $ \output ->
            exchangeKindDockerRead input output [] `shouldReturn` Left KindDockerClientInvalidRequest
        IO.withBinaryFile inputPath IO.ReadMode $ \input ->
          IO.withBinaryFile outputPath IO.WriteMode $ \output ->
            exchangeKindDockerRead input output (replicate 65 "x")
              `shouldReturn` Left KindDockerClientInvalidRequest

    it "bounds binary kind request input and refuses malformed frames" $
      withSystemTempDirectory "prodbox-kind-input-frame" $ \directory -> do
        let requestPath = directory </> "request"
            replyPath = directory </> "reply"
            resultPath = directory </> "result"
            payload = BS.pack [0, 1, 127, 128, 255] <> BS.replicate 65531 42
            frame body =
              let size = BS.length body
               in BS.pack (map (fromIntegral . (size `div`)) [16777216, 65536, 256, 1]) <> body
            response = frame (BS8.pack "{\"exit\":0,\"stdout\":\"\",\"stderr\":\"\"}")
        BS.writeFile replyPath response
        IO.withBinaryFile replyPath IO.ReadMode $ \input ->
          IO.withBinaryFile requestPath IO.WriteMode $ \output -> do
            exchangeKindDockerRequest input output (KindDockerRequest ["exec", "-i"] payload)
              `shouldReturn` Right (KindDockerReply 0 BS.empty BS.empty)
        observed <- newIORef BS.empty
        IO.withBinaryFile requestPath IO.ReadMode $ \input ->
          IO.withBinaryFile resultPath IO.WriteMode $ \output ->
            serveKindDockerInputRequestsWhile
              (pure True)
              ( \(KindDockerRequest argv bytes) -> do
                  argv `shouldBe` ["exec", "-i"]
                  writeIORef observed bytes
                  pure (KindDockerReply 1 BS.empty (BS8.pack "refused\n"))
              )
              (pure ())
              input
              output
              `shouldReturn` KindDockerProtocolRejected
        readIORef observed `shouldReturn` payload
        IO.withBinaryFile requestPath IO.ReadMode $ \input ->
          IO.withBinaryFile resultPath IO.WriteMode $ \output ->
            serveKindDockerRequestsWhile
              (pure True)
              (const (fail "read-only interpreter received input"))
              (pure ())
              input
              output
              `shouldReturn` KindDockerProtocolRejected
        IO.withBinaryFile replyPath IO.ReadMode $ \input ->
          IO.withBinaryFile requestPath IO.WriteMode $ \output ->
            exchangeKindDockerRequest input output (KindDockerRequest ["exec"] (BS.replicate 65537 1))
              `shouldReturn` Left KindDockerClientInvalidRequest
        forM_
          [ "{\"argv\":[\"exec\"],\"input\":\"!\"}"
          , "{\"argv\":[\"exec\"],\"input\":\"YQ==\",\"input\":\"Yg==\"}"
          ]
          $ \bad -> do
            BS.writeFile requestPath (frame (BS8.pack bad))
            IO.withBinaryFile requestPath IO.ReadMode $ \input ->
              IO.withBinaryFile resultPath IO.WriteMode $ \output ->
                serveKindDockerInputRequestsWhile
                  (pure True)
                  (const (fail "malformed request accepted"))
                  (pure ())
                  input
                  output
                  `shouldReturn` KindDockerProtocolMalformed
        let copyArgs = ["exec", "--privileged", "-i", "node", "cp", "/dev/stdin", "/kind/kubeadm.conf"]
        BS.writeFile requestPath payload
        IO.withBinaryFile requestPath IO.ReadMode $ \input -> do
          prepared <- prepareKindDockerRequest input copyArgs
          case prepared of
            Just (KindDockerRequest args bytes) -> (args, bytes) `shouldBe` (copyArgs, payload)
            Nothing -> fail "bounded input was not captured"
        IO.withBinaryFile requestPath IO.ReadMode $ \input -> do
          prepared <- prepareKindDockerRequest input ["info"]
          case prepared of
            Just (KindDockerRequest args bytes) -> (args, bytes) `shouldBe` (["info"], BS.empty)
            Nothing -> fail "read-only arguments were refused"
          IO.hTell input `shouldReturn` 0
        BS.writeFile requestPath (BS.replicate 65537 42)
        IO.withBinaryFile requestPath IO.ReadMode $ \input -> do
          prepared <- prepareKindDockerRequest input copyArgs
          case prepared of
            Nothing -> pure ()
            Just _ -> fail "oversized input was accepted"

    it "bounds client lock contention and releases the lock on cancellation" $
      withSystemTempDirectory "prodbox-kind-client-lock" $ \directory -> do
        let lockPath = directory </> "lock"
            emptyPath = directory </> "empty"
            outputPath = directory </> "output"
            request = ["info", "--format", "{{json .}}"]
            withPipe action =
              bracket
                ( do
                    (readEnd, writeEnd) <- Posix.createPipe
                    (,) <$> Posix.fdToHandle readEnd <*> Posix.fdToHandle writeEnd
                )
                (\(reader, writer) -> IO.hClose reader >> IO.hClose writer)
                action
        BS.writeFile lockPath BS.empty
        BS.writeFile emptyPath BS.empty
        setFileMode lockPath 0o644
        bracket (Posix.openFd lockPath Posix.ReadWrite Posix.defaultFileFlags) Posix.closeFd $ \unsafeLock ->
          IO.withBinaryFile emptyPath IO.ReadMode $ \input ->
            IO.withBinaryFile outputPath IO.WriteMode $ \output ->
              exchangeSerializedKindDockerRead 1000000 unsafeLock input output request
                `shouldReturn` Left KindDockerClientInvalidLock
        setFileMode lockPath 0o600
        bracket (Posix.openFd lockPath Posix.ReadWrite Posix.defaultFileFlags) Posix.closeFd $ \firstLock ->
          bracket (Posix.openFd lockPath Posix.ReadWrite Posix.defaultFileFlags) Posix.closeFd $ \secondLock ->
            withPipe $ \(clientInput, _peerOutput) ->
              withPipe $ \(peerInput, clientOutput) -> do
                result <- newEmptyMVar
                bracket
                  ( forkIO
                      ( try (exchangeSerializedKindDockerRead 3000000 firstLock clientInput clientOutput request)
                          >>= putMVar result
                      )
                  )
                  killThread
                  $ \worker -> do
                    received <- timeout 1000000 (BS.hGet peerInput 4)
                    fmap BS.length received `shouldBe` Just 4
                    IO.withBinaryFile emptyPath IO.ReadMode $ \input ->
                      IO.withBinaryFile outputPath IO.WriteMode $ \output ->
                        exchangeSerializedKindDockerRead 100000 secondLock input output request
                          `shouldReturn` Left KindDockerClientTimedOut
                    killThread worker
                    completed <- timeout 1000000 (takeMVar result)
                    case completed :: Maybe (Either SomeException (Either KindDockerClientFailure KindDockerReply)) of
                      Just (Left _) -> pure ()
                      other -> expectationFailure ("client did not settle after cancellation: " ++ show other)
                    IO.withBinaryFile emptyPath IO.ReadMode $ \input ->
                      IO.withBinaryFile outputPath IO.WriteMode $ \output ->
                        exchangeSerializedKindDockerRead 1000000 secondLock input output request
                          `shouldReturn` Left KindDockerClientUnsettled

    it "retains an in-flight marker after an unconfirmed or refused client exchange" $
      withSystemTempDirectory "prodbox-kind-client-marker" $ \directory -> do
        let lockPath = directory </> "lock"
            inputPath = directory </> "reply"
            outputPath = directory </> "request"
            request = ["info", "--format", "{{json .}}"]
            frame body =
              let size = BS.length body
               in BS.pack (map (fromIntegral . (size `div`)) [16777216, 65536, 256, 1]) <> body
            exchange lock body = do
              BS.writeFile inputPath (frame (BS8.pack body))
              IO.withBinaryFile inputPath IO.ReadMode $ \input ->
                IO.withBinaryFile outputPath IO.WriteMode $ \output ->
                  exchangeSerializedKindDockerRead 1000000 lock input output request
        BS.writeFile lockPath BS.empty
        setFileMode lockPath 0o600
        bracket (Posix.openFd lockPath Posix.ReadWrite Posix.defaultFileFlags) Posix.closeFd $ \lock -> do
          exchange lock "{\"exit\":0,\"stdout\":\"\",\"stderr\":\"\"}"
            `shouldReturn` Right (KindDockerReply 0 BS.empty BS.empty)
          BS.readFile lockPath `shouldReturn` BS.empty
          exchange lock "{\"exit\":1,\"stdout\":\"\",\"stderr\":\"refused\"}"
            `shouldReturn` Right (KindDockerReply 1 BS.empty (BS8.pack "refused"))
          BS.readFile lockPath `shouldReturn` BS8.pack "!"
          exchange lock "{\"exit\":0,\"stdout\":\"\",\"stderr\":\"\"}"
            `shouldReturn` Left KindDockerClientUnsettled

    it "binds existing FIFO endpoints and preserves changed or unconfirmed outcomes" $
      withSystemTempDirectory "prodbox-kind-endpoint" $ \directory -> do
        let lock = directory </> "lock"
            request = directory </> "request"
            reply = directory </> "reply"
        BS.writeFile lock BS.empty
        setFileMode lock 0o600
        PosixFiles.createNamedPipe request 0o600
        PosixFiles.createNamedPipe reply 0o600
        bracket (Posix.openFd directory Posix.ReadOnly Posix.defaultFileFlags) Posix.closeFd $ \root -> do
          observed <- withKindDockerEndpoint root (pure True) $ \endpoint stable -> do
            stable `shouldReturn` True
            statuses <-
              traverse
                PosixFiles.getFdStatus
                [endpointLock endpoint, endpointRequest endpoint, endpointReply endpoint]
            length statuses `shouldBe` 3
            traverse
              (\descriptor -> Posix.queryFdOption descriptor Posix.CloseOnExec)
              [endpointLock endpoint, endpointRequest endpoint, endpointReply endpoint]
              `shouldReturn` [True, True, True]
            pure ("receipt" :: String)
          observed `shouldBe` KindDockerEndpointObserved "receipt"
          changed <- withKindDockerEndpoint root (pure True) $ \_ stable -> do
            renameFile request (directory </> "old-request")
            PosixFiles.createNamedPipe request 0o600
            stable `shouldReturn` False
            pure ("receipt" :: String)
          changed `shouldBe` KindDockerEndpointChanged "receipt"
          removeFile request
          createSymbolicLink (directory </> "old-request") request
          withKindDockerEndpoint root (pure True) (\_ _ -> pure ()) `shouldReturn` KindDockerEndpointRefused
          removeFile request
          renameFile (directory </> "old-request") request
          createLink lock (directory </> "extra-lock")
          withKindDockerEndpoint root (pure True) (\_ _ -> pure ()) `shouldReturn` KindDockerEndpointRefused
          removeFile (directory </> "extra-lock")
          setFileMode directory 0o755
          withKindDockerEndpoint root (pure True) (\_ _ -> pure ()) `shouldReturn` KindDockerEndpointRefused
          setFileMode directory 0o700
          unavailable <- newIORef False
          let rootCheck = do
                failed <- readIORef unavailable
                if failed then ioError (userError "fixture recheck failed") else pure True
          result <- withKindDockerEndpoint root rootCheck $ \_ _ -> do
            writeIORef unavailable True
            pure ("receipt" :: String)
          result `shouldBe` KindDockerEndpointUnconfirmedAfter "receipt"

    it "exchanges framed reads through the bound FIFO endpoints" $
      withSystemTempDirectory "prodbox-kind-bound-fifos" $ \directory -> do
        let path = directory </> "docker.sock"
            client = directory </> "docker"
            lock = directory </> "lock"
            request = directory </> "request"
            reply = directory </> "reply"
            imageId = "sha256:" ++ replicate 64 'a'
            infoRequest = ["info", "--format", "{{json .}}"]
            clusterRequest =
              [ "ps"
              , "-a"
              , "--filter"
              , "label=io.x-k8s.kind.cluster"
              , "--format"
              , "{{.Label \"io.x-k8s.kind.cluster\"}}"
              ]
            pullRequest = ["pull", imageId]
        binary <- resolveBinaryPath
        copyFile binary client
        setFileMode client 0o700
        (unavailableExit, unavailableOutput, unavailableError) <-
          readCreateProcessWithExitCode (proc client infoRequest) ""
        (unavailableExit, unavailableOutput) `shouldBe` (ExitFailure 1, "")
        unavailableError `shouldContain` "kind Docker bridge unavailable"
        BS.writeFile lock BS.empty
        setFileMode lock 0o600
        PosixFiles.createNamedPipe request 0o600
        PosixFiles.createNamedPipe reply 0o600
        scope <- either (fail . show) pure (deploymentScope directory Test "run" 26443)
        bracket (Posix.openFd directory Posix.ReadOnly Posix.defaultFileFlags) Posix.closeFd $ \root ->
          withDockerDaemonFixture path False $ \requests -> do
            result <- withConnectedDockerInfo 5000000 path $ \session (DockerConnectedInfo identifier _) _ -> do
              Just gate <- newKindDockerReadGate scope imageId
              outcome <- newEmptyMVar
              bracket
                ( forkIO
                    (try (serveBoundKindDockerReads root (pure True) gate session identifier) >>= putMVar outcome)
                )
                killThread
                $ \_ -> do
                  (firstExit, firstOutput, firstError) <- readCreateProcessWithExitCode (proc client infoRequest) ""
                  firstExit `shouldBe` ExitSuccess
                  firstError `shouldBe` ""
                  firstOutput `shouldContain` "CgroupDriver"
                  (inventoryExit, inventoryOutput, inventoryError) <-
                    readCreateProcessWithExitCode (proc client clusterRequest) ""
                  (inventoryExit, inventoryOutput, inventoryError) `shouldBe` (ExitSuccess, "", "")
                  (secondExit, secondOutput, secondError) <-
                    readCreateProcessWithExitCode (proc client pullRequest) ""
                  secondExit `shouldBe` ExitFailure 1
                  secondOutput `shouldBe` ""
                  secondError `shouldContain` "kind Docker request unavailable"
                  completed <- timeout 3000000 (takeMVar outcome)
                  case completed :: Maybe (Either SomeException (KindDockerEndpointResult KindDockerProtocolOutcome)) of
                    Just (Right (KindDockerEndpointObserved KindDockerProtocolRejected)) -> pure ()
                    other -> expectationFailure ("server did not settle: " ++ show other)
            result `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted ())
            BS.readFile lock `shouldReturn` BS8.pack "!"
            observed <- readMVar requests
            length observed `shouldBe` 3
            observed `shouldSatisfy` any (isInfixOf "io.x-k8s.kind.cluster%3Dprodbox-t-run")
            observed `shouldSatisfy` all (not . isInfixOf "/images/create")

    it "settles the bound broker and worker when either exits first" $
      forM_ [False, True] $ \reject ->
        withSystemTempDirectory "prodbox-kind-bound-worker" $ \directory -> do
          let path = directory </> "docker.sock"
              lock = directory </> "lock"
              request = directory </> "request"
              reply = directory </> "reply"
              imageId = "sha256:" ++ replicate 64 'a'
              command = if reject then ["pull", imageId] else ["info", "--format", "{{json .}}"]
          BS.writeFile lock BS.empty
          setFileMode lock 0o600
          PosixFiles.createNamedPipe request 0o600
          PosixFiles.createNamedPipe reply 0o600
          scope <- either (fail . show) pure (deploymentScope directory Test "run" 26443)
          bracket (Posix.openFd directory Posix.ReadOnly Posix.defaultFileFlags) Posix.closeFd $ \root ->
            withDockerDaemonFixture path False $ \_ -> do
              result <- withConnectedDockerInfo 5000000 path $ \session (DockerConnectedInfo identifier _) _ -> do
                Just gate <- newKindDockerReadGate scope imageId
                outcomes <- runBoundKindDockerReadWorker root (pure True) gate session identifier $ do
                  observed <- exchangeBoundKindDockerRead 1000000 root (pure True) command
                  case observed of
                    KindDockerEndpointObserved (Right response) ->
                      kindDockerReplyExit response `shouldBe` if reject then 1 else 0
                    other -> expectationFailure ("exchange failed: " ++ show other)
                  if reject then threadDelay 3000000 else pure ()
                case outcomes of
                  (KindDockerBrokerCancelled, KindDockerWorkerReturned ()) | not reject -> pure ()
                  ( KindDockerBrokerReturned (KindDockerEndpointObserved KindDockerProtocolRejected)
                    , KindDockerWorkerCancelled
                    )
                      | reject -> pure ()
                  other -> expectationFailure ("unexpected broker or worker outcome: " ++ show other)
              result `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted ())
              BS.readFile lock `shouldReturn` if reject then BS8.pack "!" else BS8.empty

    it "stops bound FIFO reads when endpoint identity becomes unavailable" $
      withSystemTempDirectory "prodbox-kind-bound-change" $ \directory -> do
        let path = directory </> "docker.sock"
            lock = directory </> "lock"
            request = directory </> "request"
            reply = directory </> "reply"
            imageId = "sha256:" ++ replicate 64 'a'
            infoRequest = ["info", "--format", "{{json .}}"]
        BS.writeFile lock BS.empty
        setFileMode lock 0o600
        PosixFiles.createNamedPipe request 0o600
        PosixFiles.createNamedPipe reply 0o600
        scope <- either (fail . show) pure (deploymentScope directory Test "run" 26443)
        changed <- newIORef False
        infoCount <- newIORef (0 :: Int)
        let rootStable = not <$> readIORef changed
            hook requestLine = when ("GET /info " `isPrefixOf` requestLine) $ do
              prior <- atomicModifyIORef' infoCount (\count -> (count + 1, count))
              when (prior == 1) (writeIORef changed True)
        bracket (Posix.openFd directory Posix.ReadOnly Posix.defaultFileFlags) Posix.closeFd $ \root ->
          withDockerDaemonFixtureHook path False hook $ \requests -> do
            result <- withConnectedDockerInfo 5000000 path $ \session (DockerConnectedInfo identifier _) _ -> do
              Just gate <- newKindDockerReadGate scope imageId
              outcome <- newEmptyMVar
              bracket
                (forkIO (try (serveBoundKindDockerReads root rootStable gate session identifier) >>= putMVar outcome))
                killThread
                $ \_ -> do
                  exchanged <- exchangeBoundKindDockerRead 1000000 root rootStable infoRequest
                  exchanged `shouldBe` KindDockerEndpointChanged (Left KindDockerClientTimedOut)
                  completed <- timeout 3000000 (takeMVar outcome)
                  case completed :: Maybe (Either SomeException (KindDockerEndpointResult KindDockerProtocolOutcome)) of
                    Just (Right (KindDockerEndpointChanged KindDockerProtocolEndpointChanged)) -> pure ()
                    other -> expectationFailure ("changed server did not settle: " ++ show other)
            result `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted ())
            BS.readFile lock `shouldReturn` BS8.pack "!"
            observed <- readMVar requests
            length observed `shouldBe` 2
            observed `shouldSatisfy` all (not . isInfixOf "/images/")

    it "binds worker roots beneath the supplied operation root" $
      withSystemTempDirectory "prodbox-kind-worker-roots" $ \directory -> do
        let operation = replicate 32 'a'
            worker = directory </> ("kind-worker-" ++ operation)
            scratch = worker </> "scratch"
            bridge = worker </> "bridge"
            lock = bridge </> "lock"
            request = bridge </> "request"
            reply = bridge </> "reply"
        createDirectoryIfMissing True scratch
        createDirectoryIfMissing True bridge
        mapM_ (\path -> setFileMode path 0o700) [worker, scratch, bridge]
        BS.writeFile lock BS.empty
        setFileMode lock 0o600
        PosixFiles.createNamedPipe request 0o600
        PosixFiles.createNamedPipe reply 0o600
        bracket (Posix.openFd directory Posix.ReadOnly Posix.defaultFileFlags) Posix.closeFd $ \root -> do
          withKindDockerWorkerRoots root "invalid" (pure True) (\_ _ -> pure ())
            `shouldReturn` KindDockerEndpointRefused
          withKindDockerWorkerRoots root operation (pure False) (\_ _ -> pure ())
            `shouldReturn` KindDockerEndpointRefused
          observed <- withKindDockerWorkerRoots root operation (pure True) $ \roots stable -> do
            stable `shouldReturn` True
            traverse
              (\descriptor -> Posix.queryFdOption descriptor Posix.CloseOnExec)
              [workerScratch roots, workerBridge roots, workerLock roots, workerRequest roots, workerReply roots]
              `shouldReturn` [True, True, True, True, True]
            pure ("receipt" :: String)
          observed `shouldBe` KindDockerEndpointObserved "receipt"
          changed <- withKindDockerWorkerRoots root operation (pure True) $ \_ stable -> do
            renameDirectory scratch (worker </> "old-scratch")
            createDirectoryIfMissing True scratch
            setFileMode scratch 0o700
            observedStable <- try stable
            case observedStable :: Either IOException Bool of
              Right False -> pure ()
              other -> expectationFailure ("scratch recheck: " ++ show other)
            pure ("receipt" :: String)
          changed `shouldBe` KindDockerEndpointChanged "receipt"
          removeFile request
          createSymbolicLink "/dev/null" request
          withKindDockerWorkerRoots root operation (pure True) (\_ _ -> pure ())
            `shouldReturn` KindDockerEndpointRefused

    it "binds worker roots to the recovered scope and operation" $
      withSystemTempDirectory "prodbox-kind-scoped-roots" $ \directory -> do
        let selected = directory </> "selected.dhall"
            generation = replicate 32 'a'
            operation = replicate 32 'b'
            otherOperation = replicate 32 'c'
            document =
              "{ bootstrap = { schema_version = 2, project_anchor = \""
                ++ directory
                ++ "\", runtime_socket = \""
                ++ (directory </> "docker.sock")
                ++ "\", environment = \"test\", deployment_id = \"run\", root_generation = \""
                ++ generation
                ++ "\", api_port = 26443, node_image = \"kindest/node@sha256:"
                ++ replicate 64 'a'
                ++ "\", http_host_port = 28080, http_node_port = 30080, https_host_port = 28443, https_node_port = 30443, "
                ++ "node_artifact = { path = \"artifacts/node.tar\", digest = \"sha256:"
                ++ replicate 64 'a'
                ++ "\", maximum_bytes = 4096 }, listen_address = \"127.0.0.1\" } }"
        writeFile selected document
        bootstrap <- readBootstrapProjection selected >>= either (fail . show) pure
        prepareFreshScope (bootstrapScope bootstrap) generation `shouldReturn` FreshScopePrepared
        withScopeRootDescriptorPreserving (bootstrapScope bootstrap) (\_ stable -> stable)
          `shouldReturn` ScopeDescriptorReturned True
        withScopeRootDescriptor (bootstrapScope bootstrap) (\_ stable -> stable) `shouldReturn` Right True
        legacyFailure <-
          try
            ( withScopeRootDescriptor
                (bootstrapScope bootstrap)
                (\_ _ -> ioError (userError "nonsecret legacy callback failure"))
            )
            :: IO (Either IOException (Either DeploymentScopeError ()))
        case legacyFailure of
          Left _ -> pure ()
          Right value -> expectationFailure ("legacy scope callback failure was swallowed: " ++ show value)
        scopeCleanup <- withScopeRootDescriptorPreserving (bootstrapScope bootstrap) $ \rootFd _ -> do
          Posix.closeFd rootFd
          pure ("scope receipt" :: String)
        case scopeCleanup of
          ScopeDescriptorCleanupFailedAfter "scope receipt" [ScopeDescriptorCloseIo _] -> pure ()
          other -> expectationFailure ("scope receipt or cleanup failure was lost: " ++ show other)
        scopeBoth <- withScopeRootDescriptorPreserving (bootstrapScope bootstrap) $ \rootFd _ -> do
          Posix.closeFd rootFd
          ioError (userError "nonsecret scope callback failure")
        case scopeBoth of
          ScopeDescriptorCallbackFailed _ [ScopeDescriptorCloseIo _] -> pure ()
          other ->
            expectationFailure
              ("scope callback or cleanup failure was lost: " ++ show (other :: ScopeDescriptorOutcome ()))
        unlockAfter <- withScopeRootDescriptorPreserving (bootstrapScope bootstrap) $ \rootFd _ ->
          withLockedKindScope rootFd (pure True) $ \_ -> do
            Posix.closeFd rootFd
            pure ("lease receipt" :: String)
        case unlockAfter of
          ScopeDescriptorCleanupFailedAfter
            (Right (KindLeaseUnlockFailed (KindLeaseCompleted "lease receipt") 9))
            [ScopeDescriptorCloseIo _] -> pure ()
          other -> expectationFailure ("lease receipt or cleanup failure was lost: " ++ show other)
        unlockBoth <- withScopeRootDescriptorPreserving (bootstrapScope bootstrap) $ \rootFd _ ->
          withLockedKindScope rootFd (pure True) $ \_ -> do
            Posix.closeFd rootFd
            ioError (userError "nonsecret lease callback failure")
        case unlockBoth of
          ScopeDescriptorCleanupFailedAfter
            (Left (KindLeaseCallbackAndUnlockFailed _ 9))
            [ScopeDescriptorCloseIo _] -> pure ()
          other ->
            expectationFailure
              ( "lease callback or cleanup failure was lost: "
                  ++ show (other :: ScopeDescriptorOutcome (Either KindLeaseError (KindLeaseOutcome ())))
              )
        interrupted <- try $ withScopeRootDescriptorPreserving (bootstrapScope bootstrap) $ \rootFd _ ->
          withLockedKindScope rootFd (pure True) $ \_ -> do
            Posix.closeFd rootFd
            throwIO ThreadKilled
        case interrupted of
          Left failure -> case fromException failure of
            Just (ScopeDescriptorInterrupted leaseFailure [ScopeDescriptorCloseIo _]) ->
              case fromException leaseFailure of
                Just (KindLeaseInterrupted original 9) ->
                  (fromException original :: Maybe AsyncException) `shouldBe` Just ThreadKilled
                other -> expectationFailure ("lease interruption lost: " ++ show other)
            other -> expectationFailure ("scope interruption lost: " ++ show other)
          Right value ->
            expectationFailure
              ( "interruption swallowed: "
                  ++ show (value :: ScopeDescriptorOutcome (Either KindLeaseError (KindLeaseOutcome ())))
              )
        let root = scopeRoot (bootstrapScope bootstrap)
            worker = root </> ("kind-worker-" ++ operation)
            scratch = worker </> "scratch"
            bridge = worker </> "bridge"
        withRecoveredKindDockerWorkerRoots bootstrap operation (\_ _ -> pure ())
          `shouldReturn` KindOperationRefused (KindOperationObservationRefused KindIntentMissing)
        prepareNewKindDockerWorker bootstrap operation
          `shouldReturn` KindOperationCallbackReturned KindDockerWorkerPrepared
        doesDirectoryExist scratch `shouldReturn` True
        (PosixFiles.isNamedPipe <$> PosixFiles.getFileStatus (bridge </> "request")) `shouldReturn` True
        (PosixFiles.isNamedPipe <$> PosixFiles.getFileStatus (bridge </> "reply")) `shouldReturn` True
        prepareNewKindDockerWorker bootstrap operation
          `shouldReturn` KindOperationRefused (KindOperationIntentRefused KindIntentAlreadyExists)
        leaseCallback <- withRecoveredKindOperation bootstrap operation $ \_ ->
          ioError (userError "nonsecret lease callback failure")
        case leaseCallback of
          KindOperationUnconfirmed (KindLeaseScopeCallbackFailed _ []) -> pure ()
          other ->
            expectationFailure
              ("lease callback failure was not preserved: " ++ show (other :: KindOperationOutcome ()))
        withRecoveredKindDockerWorkerRoots bootstrap operation (\_ stable -> stable)
          `shouldReturn` KindOperationCallbackReturned (KindDockerEndpointObserved True)
        cleanupFailure <- withRecoveredKindDockerWorkerRoots bootstrap operation $ \roots _ -> do
          Posix.closeFd (workerScratch roots)
          pure ("completed" :: String)
        case cleanupFailure of
          KindOperationCallbackReturned
            (KindDockerEndpointRootIoFailedAfter "completed" [KindDockerRootDescriptorCloseIo _]) -> pure ()
          other -> expectationFailure ("returned value or close failure was lost: " ++ show other)
        primaryAndCleanup <- withRecoveredKindDockerWorkerRoots bootstrap operation $ \roots _ -> do
          Posix.closeFd (workerScratch roots)
          ioError (userError "nonsecret fixture failure")
        case primaryAndCleanup of
          KindOperationCallbackReturned
            (KindDockerEndpointRootIoFailed [KindDockerRootCallbackIo _, KindDockerRootDescriptorCloseIo _]) -> pure ()
          other ->
            expectationFailure
              ( "primary or close failure was lost: "
                  ++ show (other :: KindOperationOutcome (KindDockerEndpointResult ()))
              )
        withRecoveredKindDockerWorkerRoots bootstrap operation (\_ stable -> stable)
          `shouldReturn` KindOperationCallbackReturned (KindDockerEndpointObserved True)
        let sourcePath = directory </> "client-fixture"
            contents = BS8.pack "client-fixture"
            digest = "sha256:" ++ BS8.unpack (hexSha256 contents)
        BS.writeFile sourcePath contents
        runtime <-
          either
            (fail . show)
            pure
            (Capacity.runtimeMemoryPlanForProfile Capacity.defaultCapacitySection (Text.pack "gateway"))
        budget <- either (fail . show) pure (planSealedToolBudget runtime 1024 (2 * 1024 * 1024))
        bracket (Posix.openFd sourcePath Posix.ReadOnly Posix.defaultFileFlags) Posix.closeFd $ \source -> do
          let unused = error "refused inventory evaluated an unused capability"
              runInventory imageId readRoots =
                observeConfinedKindInventoryOnHost
                  unused
                  unused
                  unused
                  bootstrap
                  operation
                  imageId
                  readRoots
                  source
                  source
                  source
                  unused
                  "daemon-a"
                  (pure True)
          withDockerDaemonFixture (directory </> "docker.sock") False $ \requests -> do
            beforeMissing <- readMVar requests
            missing <-
              observeRecordedConfinedKindInventoryOnHost
                5000000
                unused
                unused
                unused
                bootstrap
                operation
                "unused"
                1
                "unused"
                []
                source
            case missing of
              ConfinedImageRecordRefused NodeImageIntentMissing -> pure ()
              other -> expectationFailure ("missing image intent was not refused: " ++ show other)
            readMVar requests `shouldReturn` beforeMissing
            socketIdentity <-
              observeDockerSocketIdentity (directory </> "docker.sock")
                >>= maybe (fail "missing fixture socket") pure
            let expected = DockerDaemonObserved "daemon-a" socketIdentity
                connect daemon recheck =
                  observeConnectedConfinedKindInventoryOnHost
                    5000000
                    unused
                    unused
                    unused
                    bootstrap
                    operation
                    "unused"
                    1
                    "unused"
                    []
                    source
                    daemon
                    recheck
            mismatched <- connect (DockerDaemonObserved "foreign" socketIdentity) (pure True)
            case mismatched of
              DockerPeerCompleted (DockerConnectedInfoCompleted (ConfinedDockerIdentityMismatch actual)) -> actual `shouldBe` expected
              other -> expectationFailure ("foreign Docker identity was not refused: " ++ show other)
            unavailable <- connect expected (pure False)
            case unavailable of
              DockerPeerCompleted (DockerConnectedInfoCompleted ConfinedDockerBindingUnavailable) -> pure ()
              other -> expectationFailure ("unavailable Docker binding was not refused: " ++ show other)
            intent <-
              maybe (fail "invalid image intent") pure $
                mkNodeImageIntent
                  operation
                  ("sha256:" ++ replicate 64 'c')
                  ("sha256:" ++ replicate 64 'd')
                  ("sha256:" ++ replicate 64 'e')
                  4096
            foreignIntent <-
              maybe (fail "invalid foreign identity") pure $
                bindNodeImageIntent intent (DockerDaemonObserved "foreign" socketIdentity)
            withRecoveredKindOperation bootstrap operation (recordNodeImageIntent bootstrap foreignIntent)
              `shouldReturn` KindOperationCallbackReturned NodeImageIntentRecorded
            firstIdentity <- observeRecordedNodeImageIdentity bootstrap operation
            firstDaemon <- observeRecordedNodeImageIntent bootstrap operation
            let recordPath = root </> "node-image-intent.json"
                originalDigest = BS8.pack ("sha256:" ++ replicate 64 'c')
                replacementDigest = BS8.pack ("sha256:" ++ replicate 64 'b')
            originalRecord <- BS.readFile recordPath
            let (prefix, suffix) = BS8.breakSubstring originalDigest originalRecord
            BS.null suffix `shouldBe` False
            BS.writeFile recordPath (prefix <> replacementDigest <> BS.drop (BS.length originalDigest) suffix)
            secondIdentity <- observeRecordedNodeImageIdentity bootstrap operation
            secondDaemon <- observeRecordedNodeImageIntent bootstrap operation
            case (firstIdentity, secondIdentity) of
              (NodeImageIdentityObserved _ _, NodeImageIdentityObserved _ _) -> firstIdentity `shouldNotBe` secondIdentity
              other -> expectationFailure ("image identity became unobservable: " ++ show other)
            firstDaemon `shouldBe` NodeImageIntentBound (DockerDaemonObserved "foreign" socketIdentity)
            firstDaemon `shouldBe` secondDaemon
            beforeMismatch <- readMVar requests
            configMismatch <-
              observeRecordedConfinedKindInventoryOnHost
                5000000
                unused
                unused
                unused
                bootstrap
                operation
                "unused"
                1
                ("sha256:" ++ replicate 64 'f')
                []
                source
            case configMismatch of
              ConfinedImageRecordConfigMismatch -> pure ()
              other -> expectationFailure ("foreign image identity was not refused: " ++ show other)
            readMVar requests `shouldReturn` beforeMismatch
            recordedMismatch <-
              observeRecordedConfinedKindInventoryOnHost
                5000000
                unused
                unused
                unused
                bootstrap
                operation
                "unused"
                1
                ("sha256:" ++ replicate 64 'd')
                []
                source
            case recordedMismatch of
              ConfinedImageRecordObserved
                (DockerPeerCompleted (DockerConnectedInfoCompleted (ConfinedDockerIdentityMismatch actual))) ->
                  actual `shouldBe` expected
              other -> expectationFailure ("recorded Docker mismatch was not refused: " ++ show other)
          invalidSandbox <- runInventory ("sha256:" ++ replicate 64 'a') [source]
          case invalidSandbox of
            KindOperationCallbackReturned (KindDockerEndpointObserved ConfinedKindInventoryInvalidSandbox) -> pure ()
            other -> expectationFailure ("invalid sandbox was not refused: " ++ show other)
          invalidGate <- runInventory "invalid-image" []
          case invalidGate of
            KindOperationCallbackReturned (KindDockerEndpointObserved ConfinedKindInventoryInvalidGate) -> pure ()
            other -> expectationFailure ("invalid gate was not refused: " ++ show other)
          invalidDescriptors <- runInventory ("sha256:" ++ replicate 64 'a') []
          case invalidDescriptors of
            KindOperationCallbackReturned (KindDockerEndpointObserved ConfinedKindInventoryInvalidDescriptors) -> pure ()
            other -> expectationFailure ("invalid descriptors were not refused: " ++ show other)
          (sort <$> listDirectory bridge) `shouldReturn` ["lock", "reply", "request"]
          unsealed <- withRecoveredKindDockerWorkerRoots bootstrap operation $ \roots stable ->
            prepareKindDockerClientLink roots source stable
          unsealed
            `shouldBe` KindOperationCallbackReturned (KindDockerEndpointObserved KindDockerClientLinkRefused)
          sealed <- withSealedTool budget source digest 1024 $ \client -> do
            rejectedKind <-
              observeConfinedKindInventoryOnHost
                unused
                unused
                unused
                bootstrap
                operation
                ("sha256:" ++ replicate 64 'a')
                []
                source
                source
                client
                unused
                "daemon-a"
                (pure True)
            case rejectedKind of
              KindOperationCallbackReturned (KindDockerEndpointObserved ConfinedKindInventoryInvalidDescriptors) -> pure ()
              other -> expectationFailure ("unsealed kind snapshot was not refused: " ++ show other)
            (sort <$> listDirectory bridge) `shouldReturn` ["lock", "reply", "request"]
            refused <- withRecoveredKindDockerWorkerRoots bootstrap operation $ \roots _ ->
              prepareKindDockerClientLink roots client (pure False)
            refused
              `shouldBe` KindOperationCallbackReturned (KindDockerEndpointObserved KindDockerClientLinkRefused)
            prepared <- withRecoveredKindDockerWorkerRoots bootstrap operation $ \roots stable ->
              prepareKindDockerClientLink roots client stable
            prepared
              `shouldBe` KindOperationCallbackReturned (KindDockerEndpointObserved KindDockerClientLinkPrepared)
            PosixFiles.readSymbolicLink (bridge </> "docker") `shouldReturn` ("/proc/self/fd/" ++ show client)
            duplicate <- withRecoveredKindDockerWorkerRoots bootstrap operation $ \roots stable ->
              prepareKindDockerClientLink roots client stable
            duplicate
              `shouldBe` KindOperationCallbackReturned (KindDockerEndpointObserved KindDockerClientLinkAlreadyExists)
            notReady <- withRecoveredKindDockerWorkerRoots bootstrap operation $ \roots _ ->
              removeKindDockerClientLink roots client (pure False)
            notReady
              `shouldBe` KindOperationCallbackReturned (KindDockerEndpointObserved KindDockerClientLinkRemovalRefused)
            removed <- withRecoveredKindDockerWorkerRoots bootstrap operation $ \roots stable ->
              removeKindDockerClientLink roots client stable
            removed
              `shouldBe` KindOperationCallbackReturned (KindDockerEndpointObserved KindDockerClientLinkRemoved)
            (sort <$> listDirectory bridge) `shouldReturn` ["lock", "reply", "request"]
            absent <- withRecoveredKindDockerWorkerRoots bootstrap operation $ \roots stable ->
              removeKindDockerClientLink roots client stable
            absent
              `shouldBe` KindOperationCallbackReturned (KindDockerEndpointObserved KindDockerClientLinkAbsent)
            createSymbolicLink "/foreign" (bridge </> "docker")
            foreignLink <- withRecoveredKindDockerWorkerRoots bootstrap operation $ \roots stable ->
              removeKindDockerClientLink roots client stable
            foreignLink
              `shouldBe` KindOperationCallbackReturned (KindDockerEndpointObserved KindDockerClientLinkRemovalRefused)
            PosixFiles.readSymbolicLink (bridge </> "docker") `shouldReturn` "/foreign"
          sealed `shouldBe` Right ()
        withRecoveredKindDockerWorkerRoots bootstrap otherOperation (\_ _ -> pure ())
          `shouldReturn` KindOperationRefused (KindOperationObservationRefused (KindIntentMatches operation))
        let generationPath = root </> "scope-generation.json"
        originalGeneration <- BS.readFile generationPath
        changed <- withRecoveredKindDockerWorkerRoots bootstrap operation $ \_ stable -> do
          BS.writeFile generationPath (BS8.pack "incomplete")
          stable `shouldReturn` False
          pure ("receipt" :: String)
        changed `shouldBe` KindOperationRootChanged (Right (KindDockerEndpointChanged "receipt"))
        BS.writeFile generationPath originalGeneration

    it "retains partial worker preparation and refuses an existing directory" $
      forM_ [False, True] $ \collision ->
        withSystemTempDirectory "prodbox-kind-worker-incomplete" $ \directory -> do
          let selected = directory </> "selected.dhall"
              generation = replicate 32 'a'
              operation = replicate 32 'b'
              document =
                "{ bootstrap = { schema_version = 2, project_anchor = \""
                  ++ directory
                  ++ "\", runtime_socket = \""
                  ++ (directory </> "docker.sock")
                  ++ "\", environment = \"test\", deployment_id = \"run\", root_generation = \""
                  ++ generation
                  ++ "\", api_port = 26443, node_image = \"kindest/node@sha256:"
                  ++ replicate 64 'a'
                  ++ "\", http_host_port = 28080, http_node_port = 30080, https_host_port = 28443, https_node_port = 30443, "
                  ++ "node_artifact = { path = \"artifacts/node.tar\", digest = \"sha256:"
                  ++ replicate 64 'a'
                  ++ "\", maximum_bytes = 4096 }, listen_address = \"127.0.0.1\" } }"
          writeFile selected document
          bootstrap <- readBootstrapProjection selected >>= either (fail . show) pure
          prepareFreshScope (bootstrapScope bootstrap) generation `shouldReturn` FreshScopePrepared
          let worker = scopeRoot (bootstrapScope bootstrap) </> ("kind-worker-" ++ operation)
          if collision
            then do
              createDirectoryIfMissing True worker
              BS.writeFile (worker </> "sentinel") (BS8.pack "untouched")
              prepareNewKindDockerWorker bootstrap operation
                `shouldReturn` KindOperationCallbackReturned KindDockerWorkerAlreadyExists
              BS.readFile (worker </> "sentinel") `shouldReturn` BS8.pack "untouched"
            else do
              result <- withNewKindOperation bootstrap operation $ \stable -> do
                calls <- newIORef (0 :: Int)
                let stopAfterCreate = do
                      ready <- stable
                      count <- atomicModifyIORef' calls (\value -> (value + 1, value))
                      pure (ready && count == 0)
                prepareKindDockerWorkerPaths bootstrap operation stopAfterCreate
              result `shouldBe` KindOperationCallbackReturned KindDockerWorkerPreparationIncomplete
              doesDirectoryExist worker `shouldReturn` True
              doesDirectoryExist (worker </> "scratch") `shouldReturn` False
              withRecoveredKindDockerWorkerRoots bootstrap operation (\_ _ -> pure ())
                `shouldReturn` KindOperationCallbackReturned KindDockerEndpointRefused

    it "bounds an image error response before returning" $
      withSystemTempDirectory "prodbox-session-image-large" $ \directory ->
        withDockerDaemonFixture (directory </> "docker.sock") False $ \_ -> do
          result <- withConnectedDockerInfo 5000000 (directory </> "docker.sock") $ \session _ _ ->
            inspectDockerSessionImage session ("sha256:" ++ replicate 64 'e')
          result
            `shouldBe` DockerPeerCompleted (DockerConnectedInfoCompleted (Left DockerConnectedInfoTooLarge))

    it "sends one bounded image archive and preserves a lost reply as unconfirmed" $
      withSystemTempDirectory "prodbox-session-load" $ \directory -> do
        let bytes = BS8.pack "synthetic archive bytes"
            archive = directory </> "archive.tar"
            socketPath = directory </> "docker.sock"
        BS8.writeFile archive bytes
        forM_ [True, False] $ \reply -> do
          let path = socketPath ++ show reply
          withDockerLoadFixture path bytes reply $ \received -> do
            result <- withConnectedDockerInfo 5000000 path $ \session _ stable ->
              bracket (Posix.openFd archive Posix.ReadOnly Posix.defaultFileFlags) Posix.closeFd $ \fd -> do
                loadDockerSessionImage session fd 0 stable `shouldReturn` DockerImageLoadNotStarted
                loadDockerSessionImage session fd (toInteger (BS8.length bytes) + 1) stable
                  `shouldReturn` DockerImageLoadNotStarted
                loadDockerSessionImage session fd (toInteger (BS8.length bytes)) (pure False)
                  `shouldReturn` DockerImageLoadNotStarted
                loadDockerSessionImage session fd (toInteger (BS8.length bytes)) stable
            result
              `shouldBe` DockerPeerCompleted
                ( DockerConnectedInfoCompleted $
                    if reply
                      then DockerImageLoadReply 200 (DockerImageLoadMessages 1)
                      else DockerImageLoadUnconfirmed
                )
            readMVar received `shouldReturn` bytes

    it "distinguishes Docker progress, embedded errors and ambiguous image-load responses" $ do
      let cases =
            [ ("{\"stream\":\"loaded\"}\n{\"status\":\"done\"}\n", DockerImageLoadMessages 2)
            , ("{\"stream\":\"partial\"}\n{\"error\":\"failed\"}\n", DockerImageLoadErrorMessage)
            , ("{\"errorDetail\":{\"message\":\"failed\"}}\n", DockerImageLoadErrorMessage)
            , ("{\"stream\":\"ok\",\"error\":null,\"errorDetail\":null}\n", DockerImageLoadMessages 1)
            , ("", DockerImageLoadInvalidStream)
            , ("{\"stream\":\"ok\",\"stream\":\"other\"}\n", DockerImageLoadInvalidStream)
            , ("{\"stream\":\"ok\"}\n{bad}\n", DockerImageLoadInvalidStream)
            , ("{\"aux\":{}}\n", DockerImageLoadInvalidStream)
            ]
      forM_ cases $ \(input, expected) ->
        classifyDockerImageLoadStream (BS8.pack input) `shouldReturn` expected
      classifyDockerImageLoadStream (BS8.replicate 65537 'x') `shouldReturn` DockerImageLoadInvalidStream
      classifyDockerImageLoadStream (BS8.concat (replicate 1025 (BS8.pack "{\"status\":\"x\"}\n")))
        `shouldReturn` DockerImageLoadInvalidStream

    it "retains a lost load reply and a failed image read as separate observations" $
      withSystemTempDirectory "prodbox-session-load-lost" $ \directory -> do
        let bytes = BS8.pack "synthetic archive bytes"
            archive = directory </> "archive.tar"
            socketPath = directory </> "docker.sock"
        BS8.writeFile archive bytes
        withDockerLoadFixture socketPath bytes False $ \received -> do
          result <- withConnectedDockerInfo 5000000 socketPath $ \session _ stable ->
            bracket (Posix.openFd archive Posix.ReadOnly Posix.defaultFileFlags) Posix.closeFd $ \fd -> do
              loadAndObserveDockerSessionImage session fd (toInteger (BS8.length bytes)) "invalid" stable
                `shouldReturn` DockerImageSubmissionObservation DockerImageLoadNotStarted DockerImageReadbackSkipped
              loadAndObserveDockerSessionImage
                session
                fd
                (toInteger (BS8.length bytes))
                ("sha256:" ++ replicate 64 'a')
                stable
          result
            `shouldBe` DockerPeerCompleted
              ( DockerConnectedInfoCompleted $
                  DockerImageSubmissionObservation
                    DockerImageLoadUnconfirmed
                    (DockerImageReadbackStable (Left DockerConnectedInfoTransport))
              )
          readMVar received `shouldReturn` bytes

    it "retains an image response as changed when the scope changes during read-back" $
      withSystemTempDirectory "prodbox-session-load-changed" $ \directory -> do
        let bytes = BS8.pack "synthetic archive bytes"
            archive = directory </> "archive.tar"
            socketPath = directory </> "docker.sock"
            identifier = "sha256:" ++ replicate 64 'a'
        BS8.writeFile archive bytes
        unchanged <- newIORef True
        let hook request = when ("GET /images/sha256:" `isPrefixOf` request) (writeIORef unchanged False)
        withDockerDaemonFixtureHook socketPath False hook $ \_ -> do
          result <- withConnectedDockerInfo 5000000 socketPath $ \session _ _ ->
            bracket (Posix.openFd archive Posix.ReadOnly Posix.defaultFileFlags) Posix.closeFd $ \fd ->
              loadAndObserveDockerSessionImage
                session
                fd
                (toInteger (BS8.length bytes))
                identifier
                (readIORef unchanged)
          result
            `shouldBe` DockerPeerCompleted
              ( DockerConnectedInfoCompleted $
                  DockerImageSubmissionObservation
                    (DockerImageLoadReply 200 (DockerImageLoadMessages 1))
                    (DockerImageReadbackChanged (Right (ImageIdObserved "linux" "amd64" 0)))
              )

    it "checks the held connection against the durable image record before invoking its callback"
      $ forM_
        [ (True, False, False, False)
        , (False, False, False, False)
        , (True, True, False, False)
        , (True, False, True, False)
        , (True, False, False, True)
        ]
      $ \(matches, changeAfter, alreadyOther, timeoutAfterWrite) ->
        withDockerInfoFixture (BS8.pack "{\"ID\":\"daemon-a\"}") False $ \path -> do
          let anchor = takeDirectory path
              selected = anchor </> "selected.dhall"
              generation = replicate 32 'a'
              operation = replicate 32 'b'
              digest character = "sha256:" ++ replicate 64 character
              document =
                "{ bootstrap = { schema_version = 2, project_anchor = \""
                  ++ anchor
                  ++ "\", runtime_socket = \""
                  ++ path
                  ++ "\", environment = \"test\", deployment_id = \"run\", root_generation = \""
                  ++ generation
                  ++ "\", api_port = 26443, node_image = \"kindest/node@"
                  ++ digest 'a'
                  ++ "\", http_host_port = 28080, http_node_port = 30080, https_host_port = 28443, https_node_port = 30443, "
                  ++ "node_artifact = { path = \"artifacts/node.tar\", digest = \""
                  ++ digest 'a'
                  ++ "\", maximum_bytes = 4096 }, listen_address = \"127.0.0.1\" } }"
          writeFile selected document
          bootstrap <- readBootstrapProjection selected >>= either (fail . show) pure
          prepareFreshScope (bootstrapScope bootstrap) generation `shouldReturn` FreshScopePrepared
          socketIdentity <- observeDockerSocketIdentity path >>= maybe (fail "missing fixture socket") pure
          intent <-
            maybe (fail "invalid image intent") pure $
              mkNodeImageIntent operation (digest 'c') (digest 'd') (digest 'e') 4096
          bound <-
            maybe (fail "invalid bound image intent") pure $
              bindNodeImageIntent
                intent
                (DockerDaemonObserved (if matches then "daemon-a" else "daemon-b") socketIdentity)
          otherBound <-
            maybe (fail "invalid other binding") pure $
              bindNodeImageIntent intent (DockerDaemonObserved "daemon-b" socketIdentity)
          called <- newIORef False
          result <- withNewKindOperation bootstrap operation $ \stable -> do
            recordNodeImageIntent bootstrap bound stable `shouldReturn` NodeImageIntentRecorded
            when (matches && not changeAfter && not alreadyOther && not timeoutAfterWrite) $ do
              forM_ ["not-an-ip", "2001:db8::/64", "fc00:c1c8:9c54:6b75::1/64", "fc00::/32", "fc00:::/64"] $ \invalid ->
                mkKindNetworkIntent operation invalid (Just 1500) (DockerDaemonObserved "daemon-a" socketIdentity)
                  `shouldBe` Nothing
              networkIntent <-
                maybe (fail "invalid network intent") pure $
                  mkKindNetworkIntent
                    operation
                    "fc00:c1c8:9c54:6b75::/64"
                    (Just 1500)
                    (DockerDaemonObserved "daemon-a" socketIdentity)
              differentNetwork <-
                maybe (fail "invalid alternate network intent") pure $
                  mkKindNetworkIntent
                    operation
                    "fc00:c1c8:9c54:6b76::/64"
                    (Just 1500)
                    (DockerDaemonObserved "daemon-a" socketIdentity)
              observeKindNetworkIntent bootstrap networkIntent stable `shouldReturn` NetworkIntentMissing
              observeKindNetworkAttempt bootstrap networkIntent stable `shouldReturn` NetworkAttemptUnobservable
              recordKindNetworkAttempt bootstrap networkIntent stable `shouldReturn` NetworkAttemptRefused
              observeRecordedKindNetworkIntent bootstrap operation stable `shouldReturn` NetworkRecoveryMissing
              observeRecordedKindNetworkIntent bootstrap (replicate 32 'c') stable
                `shouldReturn` NetworkRecoveryUnobservable
              recordKindNetworkIntent bootstrap networkIntent (pure False) `shouldReturn` NetworkIntentRefused
              recordKindNetworkIntent bootstrap networkIntent stable `shouldReturn` NetworkIntentRecorded
              observeKindNetworkIntent bootstrap networkIntent stable `shouldReturn` NetworkIntentMatches
              observeRecordedKindNetworkIntent bootstrap operation stable
                `shouldReturn` NetworkRecoveryRecorded networkIntent
              observeKindNetworkIntent bootstrap differentNetwork stable `shouldReturn` NetworkIntentConflict
              recordKindNetworkIntent bootstrap differentNetwork stable `shouldReturn` NetworkIntentAlreadyExists
              observeKindNetworkAttempt bootstrap networkIntent stable `shouldReturn` NetworkAttemptMissing
              recordKindNetworkRemoval bootstrap networkIntent (replicate 64 'c') stable
                `shouldReturn` NetworkRemovalRefused
              recordKindNetworkAttempt bootstrap networkIntent (pure False) `shouldReturn` NetworkAttemptRefused
              recordKindNetworkAttempt bootstrap networkIntent stable `shouldReturn` NetworkAttemptRecorded
              observeKindNetworkAttempt bootstrap networkIntent stable `shouldReturn` NetworkAttemptMatches
              observeRecordedKindNetworkAttempt bootstrap operation stable `shouldReturn` NetworkAttemptMatches
              recordKindNetworkAttempt bootstrap networkIntent stable `shouldReturn` NetworkAttemptAlreadyExists
              observeKindNetworkAttempt bootstrap differentNetwork stable
                `shouldReturn` NetworkAttemptUnobservable
              observeKindNetworkRemoval bootstrap networkIntent (replicate 64 'c') stable
                `shouldReturn` NetworkRemovalMissing
              observeRecordedKindNetworkRemoval bootstrap operation stable
                `shouldReturn` NetworkRemovalRecoveryMissing
              recordKindNetworkRemoval bootstrap networkIntent "../invalid" stable
                `shouldReturn` NetworkRemovalRefused
              recordKindNetworkRemoval bootstrap networkIntent (replicate 64 'c') (pure False)
                `shouldReturn` NetworkRemovalRefused
              recordKindNetworkRemoval bootstrap networkIntent (replicate 64 'c') stable
                `shouldReturn` NetworkRemovalRecorded
              observeKindNetworkRemoval bootstrap networkIntent (replicate 64 'c') stable
                `shouldReturn` NetworkRemovalMatches
              observeRecordedKindNetworkRemoval bootstrap operation stable
                `shouldReturn` NetworkRemovalRecoveryRecorded (replicate 64 'c')
              observeKindNetworkRemoval bootstrap networkIntent (replicate 64 'd') stable
                `shouldReturn` NetworkRemovalConflict
              recordKindNetworkRemoval bootstrap networkIntent (replicate 64 'd') stable
                `shouldReturn` NetworkRemovalAlreadyExists
              let networkRemoval = scopeRoot (bootstrapScope bootstrap) </> "kind-network-removal.json"
                  removalBackup = anchor </> "network-removal-backup"
              removalBytes <- BS8.readFile networkRemoval
              BS8.writeFile networkRemoval (BS8.pack "{")
              observeKindNetworkRemoval bootstrap networkIntent (replicate 64 'c') stable
                `shouldReturn` NetworkRemovalInvalid
              observeRecordedKindNetworkRemoval bootstrap operation stable
                `shouldReturn` NetworkRemovalRecoveryInvalid
              BS8.writeFile networkRemoval removalBytes
              renameFile networkRemoval removalBackup
              createSymbolicLink removalBackup networkRemoval
              observeKindNetworkRemoval bootstrap networkIntent (replicate 64 'c') stable
                `shouldReturn` NetworkRemovalUnobservable
              observeRecordedKindNetworkRemoval bootstrap operation stable
                `shouldReturn` NetworkRemovalRecoveryUnobservable
              BS8.readFile removalBackup `shouldReturn` removalBytes
              removeFile networkRemoval
              renameFile removalBackup networkRemoval
              let networkAttempt = scopeRoot (bootstrapScope bootstrap) </> "kind-network-attempt.json"
                  attemptBackup = anchor </> "network-attempt-backup"
              attemptBytes <- BS8.readFile networkAttempt
              BS8.writeFile networkAttempt (BS8.pack "{")
              observeKindNetworkAttempt bootstrap networkIntent stable `shouldReturn` NetworkAttemptInvalid
              observeKindNetworkRemoval bootstrap networkIntent (replicate 64 'c') stable
                `shouldReturn` NetworkRemovalUnobservable
              observeRecordedKindNetworkRemoval bootstrap operation stable
                `shouldReturn` NetworkRemovalRecoveryUnobservable
              BS8.writeFile networkAttempt (BS8.pack "{}")
              observeKindNetworkAttempt bootstrap networkIntent stable `shouldReturn` NetworkAttemptConflict
              BS8.writeFile networkAttempt attemptBytes
              renameFile networkAttempt attemptBackup
              createSymbolicLink attemptBackup networkAttempt
              observeKindNetworkAttempt bootstrap networkIntent stable `shouldReturn` NetworkAttemptUnobservable
              BS8.readFile attemptBackup `shouldReturn` attemptBytes
              removeFile networkAttempt
              renameFile attemptBackup networkAttempt
              let networkPath = scopeRoot (bootstrapScope bootstrap) </> "kind-network-intent.json"
                  networkBackup = anchor </> "network-intent-backup"
              networkBytes <- BS8.readFile networkPath
              BS8.writeFile networkPath (BS8.pack "{")
              observeKindNetworkIntent bootstrap networkIntent stable `shouldReturn` NetworkIntentInvalid
              observeRecordedKindNetworkIntent bootstrap operation stable `shouldReturn` NetworkRecoveryInvalid
              observeKindNetworkAttempt bootstrap networkIntent stable `shouldReturn` NetworkAttemptUnobservable
              observeRecordedKindNetworkAttempt bootstrap operation stable
                `shouldReturn` NetworkAttemptUnobservable
              BS8.writeFile networkPath networkBytes
              renameFile networkPath networkBackup
              createSymbolicLink networkBackup networkPath
              observeKindNetworkIntent bootstrap networkIntent stable `shouldReturn` NetworkIntentUnobservable
              observeRecordedKindNetworkIntent bootstrap operation stable
                `shouldReturn` NetworkRecoveryUnobservable
              BS8.readFile networkBackup `shouldReturn` networkBytes
              removeFile networkPath
              renameFile networkBackup networkPath
              observeNodeImageAttempt bootstrap intent stable `shouldReturn` NodeImageAttemptUnobservable
              recordNodeImageAttempt bootstrap intent stable `shouldReturn` NodeImageAttemptRefused
              recordNodeImageAttempt bootstrap bound (pure False) `shouldReturn` NodeImageAttemptRefused
              observeNodeImageAttempt bootstrap bound stable `shouldReturn` NodeImageAttemptMissing
              checks <- newIORef (0 :: Int)
              let changesDuringIntentRead = do
                    count <- atomicModifyIORef' checks (\value -> (value + 1, value))
                    if count == 0 then stable else pure False
              recordNodeImageAttempt bootstrap bound changesDuringIntentRead
                `shouldReturn` NodeImageAttemptRefused
              observeNodeImageAttempt bootstrap bound stable `shouldReturn` NodeImageAttemptMissing
              observeRecordedNodeImageAttempt bootstrap operation `shouldReturn` NodeImageAttemptMissing
              let slowStable = threadDelay 450000 >> stable
              recordNodeImageAttempt bootstrap bound slowStable `shouldReturn` NodeImageAttemptRecorded
              observeNodeImageAttempt bootstrap bound stable `shouldReturn` NodeImageAttemptMatches
              observeRecordedNodeImageAttempt bootstrap operation `shouldReturn` NodeImageAttemptMatches
              recordNodeImageAttempt bootstrap bound stable `shouldReturn` NodeImageAttemptAlreadyExists
              observeNodeImageAttempt bootstrap otherBound stable `shouldReturn` NodeImageAttemptUnobservable
              let attemptPath = scopeRoot (bootstrapScope bootstrap) </> "node-image-attempt.json"
                  backupPath = anchor </> "attempt-backup"
              original <- BS8.readFile attemptPath
              BS8.writeFile attemptPath (BS8.pack "invalid")
              observeNodeImageAttempt bootstrap bound stable `shouldReturn` NodeImageAttemptInvalid
              observeRecordedNodeImageAttempt bootstrap operation `shouldReturn` NodeImageAttemptInvalid
              BS8.writeFile attemptPath (BS8.pack "{}")
              observeNodeImageAttempt bootstrap bound stable `shouldReturn` NodeImageAttemptConflict
              observeRecordedNodeImageAttempt bootstrap operation `shouldReturn` NodeImageAttemptConflict
              BS8.writeFile attemptPath original
              renameFile attemptPath backupPath
              createSymbolicLink backupPath attemptPath
              observeNodeImageAttempt bootstrap bound stable `shouldReturn` NodeImageAttemptUnobservable
              observeRecordedNodeImageAttempt bootstrap operation `shouldReturn` NodeImageAttemptUnobservable
              BS8.readFile backupPath `shouldReturn` original
              removeFile attemptPath
              renameFile backupPath attemptPath
            when (matches && changeAfter && not alreadyOther) $ do
              let attemptPath = scopeRoot (bootstrapScope bootstrap) </> "node-image-attempt.json"
                  stableUntilAttempt = do
                    ready <- stable
                    exists <- doesFileExist attemptPath
                    pure (ready && not exists)
              observeNodeImageAttempt bootstrap bound stable `shouldReturn` NodeImageAttemptMissing
              recordNodeImageAttempt bootstrap bound stableUntilAttempt `shouldReturn` NodeImageAttemptIncomplete
              observeNodeImageAttempt bootstrap bound stable `shouldReturn` NodeImageAttemptMatches
            when timeoutAfterWrite $ do
              let attemptPath = scopeRoot (bootstrapScope bootstrap) </> "node-image-attempt.json"
                  delayedAfterAttempt = do
                    ready <- stable
                    exists <- doesFileExist attemptPath
                    when exists (threadDelay 12000000)
                    pure ready
              recordNodeImageAttempt bootstrap bound delayedAfterAttempt `shouldReturn` NodeImageAttemptIncomplete
              observeNodeImageAttempt bootstrap bound stable `shouldReturn` NodeImageAttemptMatches
            withConnectedNodeImageRecord bootstrap (if alreadyOther then otherBound else intent) stable $ \_ recordStable -> do
              recordStable `shouldReturn` True
              writeIORef called True
              when changeAfter $ do
                writeFile (scopeRoot (bootstrapScope bootstrap) </> "node-image-intent.json") "incomplete"
                recordStable `shouldReturn` False
              pure ("receipt" :: String)
          let expected
                | alreadyOther = NodeImageConnectionInvalid
                | matches && changeAfter = NodeImageConnectionChangedAfter "receipt"
                | matches = NodeImageConnectionReady "receipt"
                | otherwise = NodeImageConnectionRecordRefused NodeImageIntentConflict
          result
            `shouldBe` KindOperationCallbackReturned (DockerPeerCompleted (DockerConnectedInfoCompleted expected))
          readIORef called `shouldReturn` (matches && not alreadyOther)
          when (matches && not changeAfter && not alreadyOther) $ do
            recovered <-
              withRecoveredKindOperation bootstrap operation (observeNodeImageAttempt bootstrap bound)
            recovered `shouldBe` KindOperationCallbackReturned NodeImageAttemptMatches
          when (matches && not changeAfter && not alreadyOther && not timeoutAfterWrite) $ do
            networkIntent <-
              maybe (fail "invalid recovered intent") pure $
                mkKindNetworkIntent
                  operation
                  "fc00:c1c8:9c54:6b75::/64"
                  (Just 1500)
                  (DockerDaemonObserved "daemon-a" socketIdentity)
            recovered <-
              withRecoveredKindOperation
                bootstrap
                operation
                (observeRecordedKindNetworkIntent bootstrap operation)
            recovered `shouldBe` KindOperationCallbackReturned (NetworkRecoveryRecorded networkIntent)
            attempt <-
              withRecoveredKindOperation
                bootstrap
                operation
                (observeRecordedKindNetworkAttempt bootstrap operation)
            attempt `shouldBe` KindOperationCallbackReturned NetworkAttemptMatches
            removal <-
              withRecoveredKindOperation
                bootstrap
                operation
                (observeRecordedKindNetworkRemoval bootstrap operation)
            removal `shouldBe` KindOperationCallbackReturned (NetworkRemovalRecoveryRecorded (replicate 64 'c'))
          when (matches && changeAfter && not alreadyOther) $ do
            doesFileExist (scopeRoot (bootstrapScope bootstrap) </> "node-image-attempt.json")
              `shouldReturn` True
            observeRecordedNodeImageAttempt bootstrap operation `shouldReturn` NodeImageAttemptUnobservable

  describe "public node image attempt status" $
    it "reports retained marker states without claiming daemon settlement" $
      withSystemTempDirectory "prodbox-attempt-status" $ \directory -> do
        binary <- resolveBinaryPath >>= \path -> installOperatorBinaryInDir path directory
        let socketPath = directory </> "docker.sock"
            selected = directory </> ".test-data" </> "run" </> "config" </> "prodbox.dhall"
            operation = replicate 32 'b'
            digest character = "sha256:" ++ replicate 64 character
            values =
              unlines
                [ directory
                , socketPath
                , "test"
                , "run"
                , replicate 32 'a'
                , "26443"
                , "kindest/node@" ++ digest 'a'
                , "28080"
                , "30080"
                , "28443"
                , "30443"
                , "127.0.0.1"
                , "artifacts/node.tar"
                , digest 'a'
                , "4096"
                , "artifacts/kind"
                , digest 'c'
                , "100000"
                , "yes"
                ]
            run arguments input = readCreateProcessWithExitCode (proc binary arguments) {cwd = Just directory} input
            status expected = do
              (code, output, errors) <- run ["--config", selected, "control", "status"] ""
              (code, errors) `shouldBe` (ExitSuccess, "")
              output `shouldContain` ("Node image attempt: " ++ expected)
            networkStatus expected = do
              (code, output, errors) <- run ["--config", selected, "control", "status"] ""
              (code, errors) `shouldBe` (ExitSuccess, "")
              output `shouldContain` ("Kind network recovery: " ++ expected)
        withDockerDaemonFixture socketPath False $ \_ -> do
          (setup, _, errors) <- run ["--config", selected, "config", "setup"] values
          (setup, errors) `shouldBe` (ExitSuccess, "")
          status "not observed"
          networkStatus "not observed"
          bootstrap <- readBootstrapProjection selected >>= either (fail . show) pure
          socketIdentity <-
            observeDockerSocketIdentity socketPath >>= maybe (fail "missing fixture socket") pure
          intent <-
            maybe (fail "invalid image intent") pure $
              mkNodeImageIntent operation (digest 'c') (digest 'd') (digest 'e') 4096
          bound <-
            maybe (fail "invalid bound image intent") pure $
              bindNodeImageIntent intent (DockerDaemonObserved "daemon-a" socketIdentity)
          withNewKindOperation bootstrap operation (recordNodeImageIntent bootstrap bound)
            `shouldReturn` KindOperationCallbackReturned NodeImageIntentRecorded
          (volumeCode, volumeOutput, volumeErrors) <- run ["--config", selected, "control", "status"] ""
          (volumeCode, volumeErrors) `shouldBe` (ExitSuccess, "")
          volumeOutput
            `shouldContain` "Candidate node /var volume: daemon returned 404; absence, ownership and worker settlement unverified"
          networkStatus "proposal not found locally; network absence and worker settlement unverified"
          networkIntent <-
            maybe (fail "invalid network intent") pure $
              mkKindNetworkIntent
                operation
                "fc00:c1c8:9c54:6b75::/64"
                (Just 1500)
                (DockerDaemonObserved "daemon-a" socketIdentity)
          withRecoveredKindOperation bootstrap operation (recordKindNetworkIntent bootstrap networkIntent)
            `shouldReturn` KindOperationCallbackReturned NetworkIntentRecorded
          networkStatus "attempt missing locally, inventory no matches observed"
          withRecoveredKindOperation bootstrap operation (recordKindNetworkAttempt bootstrap networkIntent)
            `shouldReturn` KindOperationCallbackReturned NetworkAttemptRecorded
          networkStatus "attempt recorded, inventory no matches observed"
          let networkAttemptPath = scopeRoot (bootstrapScope bootstrap) </> "kind-network-attempt.json"
          originalNetworkAttempt <- BS8.readFile networkAttemptPath
          BS8.writeFile networkAttemptPath (BS8.pack "{")
          networkStatus "attempt invalid, inventory no matches observed"
          BS8.writeFile networkAttemptPath originalNetworkAttempt
          withRecoveredKindOperation
            bootstrap
            operation
            (recordKindNetworkRemoval bootstrap networkIntent (replicate 64 'c'))
            `shouldReturn` KindOperationCallbackReturned NetworkRemovalRecorded
          withRecoveredKindOperation
            bootstrap
            operation
            ( recordNetworkReceipt
                bootstrap
                networkIntent
                NetworkCreateReceipt
                (NetworkCreateTransport DockerNetworkCreateUnconfirmed)
            )
            `shouldReturn` KindOperationCallbackReturned NetworkReceiptRecorded
          withRecoveredKindOperation
            bootstrap
            operation
            ( recordNetworkReceipt
                bootstrap
                networkIntent
                (NetworkRemovalReceipt (replicate 64 'c'))
                (NetworkRemovalTransport (DockerNetworkRemoveReply 204))
            )
            `shouldReturn` KindOperationCallbackReturned NetworkReceiptRecorded
          (networkCode, networkOutput, networkErrors) <- run ["--config", selected, "control", "status"] ""
          (networkCode, networkErrors) `shouldBe` (ExitSuccess, "")
          networkOutput
            `shouldContain` ("removal recorded for " ++ replicate 64 'c' ++ ", removal after recorded for " ++ replicate 64 'c')
          networkOutput `shouldContain` "removal ID not returned by ID query"
          networkOutput `shouldContain` "separate removal ID not returned by ID query"
          networkOutput `shouldContain` "create receipt create unconfirmed, removal receipt removal reply 204"
          status "not found locally; daemon effect and worker settlement unverified"
          withRecoveredKindOperation bootstrap operation (recordNodeImageAttempt bootstrap bound)
            `shouldReturn` KindOperationCallbackReturned NodeImageAttemptRecorded
          status "matching local marker; daemon effect and worker settlement unverified"
          let attemptPath = scopeRoot (bootstrapScope bootstrap) </> "node-image-attempt.json"
              intentPath = scopeRoot (bootstrapScope bootstrap) </> "node-image-intent.json"
              backupPath = directory </> "attempt-backup"
          original <- BS8.readFile attemptPath
          BS8.writeFile attemptPath (BS8.pack "incomplete")
          status "marker is invalid or incomplete"
          BS8.writeFile attemptPath (BS8.pack "{}")
          status "marker conflicts with the recorded image intent"
          BS8.writeFile attemptPath original
          renameFile attemptPath backupPath
          createSymbolicLink backupPath attemptPath
          status "marker or parent intent could not be safely observed"
          BS8.readFile backupPath `shouldReturn` original
          removeFile attemptPath
          renameFile backupPath attemptPath
          BS8.writeFile intentPath (BS8.pack "invalid")
          status "marker or parent intent could not be safely observed"

  describe "selected node archive inspection" $
    it "binds the configured OCI digest and platform to retained blob contents" $
      withSystemTempDirectory "prodbox-node-archive" $ \tmpDir -> do
        classifyArchiveInterruption
          (ArchiveCallbackNotStarted :: ArchiveCallbackProgress String)
          NodeArchiveTimedOut
          `shouldBe` InspectedArchiveRefused NodeArchiveTimedOut
        classifyArchiveInterruption
          (ArchiveCallbackStarted :: ArchiveCallbackProgress String)
          NodeArchiveTimedOut
          `shouldBe` InspectedArchiveUnconfirmed NodeArchiveTimedOut
        classifyArchiveInterruption (ArchiveCallbackReturned "receipt") NodeArchiveTimedOut
          `shouldBe` InspectedArchiveUnconfirmedAfter "receipt" NodeArchiveTimedOut
        binary <- resolveBinaryPath >>= \path -> installOperatorBinaryInDir path tmpDir
        let architecture = case SystemInfo.arch of
              "x86_64" -> "amd64"
              "aarch64" -> "arm64"
              other -> other
            layer = BS8.pack "synthetic non-secret layer"
            digest bytes = "sha256:" ++ BS8.unpack (hexSha256 bytes)
            config =
              BS8.pack
                ( "{\"os\":\"linux\",\"architecture\":\""
                    ++ architecture
                    ++ "\",\"rootfs\":{\"type\":\"layers\",\"diff_ids\":[\""
                    ++ digest layer
                    ++ "\"]}}"
                )
            descriptor media bytes =
              "{\"mediaType\":\""
                ++ media
                ++ "\",\"digest\":\""
                ++ digest bytes
                ++ "\",\"size\":"
                ++ show (BS8.length bytes)
                ++ "}"
            makeManifest configMedia layerMedia =
              BS8.pack $
                "{\"schemaVersion\":2,\"config\":"
                  ++ descriptor configMedia config
                  ++ ",\"layers\":["
                  ++ descriptor layerMedia layer
                  ++ "]}"
            run args input = readCreateProcessWithExitCode (proc binary args) {cwd = Just tmpDir} input
        forM_
          [ "match"
          , "connected"
          , "connected-conflict"
          , "connected-stale"
          , "connected-changed"
          , "connected-old-result"
          , "index"
          , "foreignindex"
          , "wrongdigest"
          , "missing"
          , "duplicate"
          , "docker"
          , "dockerindex"
          , "dockermixed"
          , "named"
          , "extra"
          , "badannotations"
          ]
          $ \caseName -> do
            let anchor = tmpDir </> caseName
                layout = anchor </> "layout"
                blobs = layout </> "blobs" </> "sha256"
                archive = anchor </> "node.tar"
                selected = anchor </> ".test-data" </> caseName </> "config" </> "prodbox.dhall"
                dockerCase = caseName `elem` ["docker", "dockerindex", "dockermixed"]
                configMedia =
                  if dockerCase
                    then "application/vnd.docker.container.image.v1+json"
                    else "application/vnd.oci.image.config.v1+json"
                layerMedia =
                  if dockerCase && caseName /= "dockermixed"
                    then "application/vnd.docker.image.rootfs.diff.tar.gzip"
                    else "application/vnd.oci.image.layer.v1.tar"
                manifest = makeManifest configMedia layerMedia
                platform = if caseName == "foreignindex" then "foreign" else architecture
                manifestMedia =
                  if dockerCase
                    then "application/vnd.docker.distribution.manifest.v2+json"
                    else "application/vnd.oci.image.manifest.v1+json"
                indexMedia =
                  if dockerCase
                    then "application/vnd.docker.distribution.manifest.list.v2+json"
                    else "application/vnd.oci.image.index.v1+json"
                manifestDescriptor = descriptor manifestMedia manifest
                nested =
                  BS8.pack $
                    "{\"schemaVersion\":2,\"manifests\":["
                      ++ take (length manifestDescriptor - 1) manifestDescriptor
                      ++ ",\"platform\":{\"os\":\"linux\",\"architecture\":\""
                      ++ platform
                      ++ "\"}}]}"
                nestedCase = caseName `elem` ["index", "foreignindex", "dockerindex"]
                rootDescriptor = if nestedCase then descriptor indexMedia nested else manifestDescriptor
                withAnnotations value annotation =
                  take (length value - 1) value ++ ",\"annotations\":{" ++ annotation ++ "}}"
                namedDescriptor = withAnnotations rootDescriptor "\"io.containerd.image.name\":\"sensitive-marker\""
                invalidDescriptor = withAnnotations rootDescriptor "\"org.opencontainers.image.ref.name\":false"
                extraDescriptor =
                  withAnnotations
                    (descriptor "application/vnd.oci.image.config.v1+json" config)
                    "\"org.opencontainers.image.ref.name\":\"foreign-marker\""
                index =
                  BS8.pack $
                    "{\"schemaVersion\":2,\"manifests\":["
                      ++ ( case caseName of
                             "named" -> namedDescriptor
                             "badannotations" -> invalidDescriptor
                             _ -> rootDescriptor
                         )
                      ++ (if caseName == "extra" then "," ++ extraDescriptor else "")
                      ++ "]}"
                imageDigest =
                  if caseName == "wrongdigest"
                    then "sha256:" ++ replicate 64 'b'
                    else digest (if nestedCase then nested else manifest)
                values archiveDigest archiveSize =
                  unlines
                    [ anchor
                    , if "connected" `isPrefixOf` caseName
                        then anchor </> "docker.sock"
                        else anchor </> "unavailable-docker.sock"
                    , "test"
                    , caseName
                    , replicate 32 'a'
                    , "26443"
                    , "kindest/node@" ++ imageDigest
                    , "28080"
                    , "30080"
                    , "28443"
                    , "30443"
                    , "127.0.0.1"
                    , "artifacts/node.tar"
                    , archiveDigest
                    , show (archiveSize + 1)
                    , "artifacts/kind"
                    , "sha256:" ++ replicate 64 'c'
                    , "100000"
                    , "yes"
                    ]
            createDirectoryIfMissing True blobs
            BS8.writeFile (layout </> "oci-layout") (BS8.pack "{\"imageLayoutVersion\":\"1.0.0\"}")
            BS8.writeFile (layout </> "index.json") index
            forM_ [config, manifest] $ \bytes -> BS8.writeFile (blobs </> drop 7 (digest bytes)) bytes
            when nestedCase $ BS8.writeFile (blobs </> drop 7 (digest nested)) nested
            when (caseName /= "missing") $ BS8.writeFile (blobs </> drop 7 (digest layer)) layer
            entries <- Tar.pack layout ["oci-layout", "index.json", "blobs"]
            let tarBytes = Tar.write (entries ++ if caseName == "duplicate" then take 1 entries else [])
            LazyBS8.writeFile archive tarBytes
            setFileMode archive 0o600
            let strict = LazyBS8.toStrict tarBytes
            (setupExit, _, _) <-
              run ["--config", selected, "config", "setup"] (values (digest strict) (BS8.length strict))
            setupExit `shouldBe` ExitSuccess
            (importExit, _, _) <-
              run ["--config", selected, "control", "import-artifact", "node-archive", archive] ""
            importExit `shouldBe` ExitSuccess
            (inspectExit, inspectOutput, _) <- run ["--config", selected, "control", "inspect-node-archive"] ""
            if caseName
              `elem` [ "match"
                     , "connected"
                     , "connected-conflict"
                     , "connected-stale"
                     , "connected-changed"
                     , "connected-old-result"
                     , "index"
                     , "docker"
                     , "dockerindex"
                     , "named"
                     , "extra"
                     ]
              && architecture `elem` ["amd64", "arm64"]
              then do
                inspectExit `shouldBe` ExitSuccess
                inspectOutput `shouldContain` digest manifest
                inspectOutput `shouldContain` ("Config digest: " ++ digest config)
                inspectOutput
                  `shouldContain` ("Archive top-level entries: " ++ if caseName == "extra" then "2" else "1")
                inspectOutput
                  `shouldContain` ( "entries with recognized image-name metadata: "
                                      ++ if caseName `elem` ["named", "extra"] then "1" else "0"
                                  )
                inspectOutput `shouldNotContain` "sensitive-marker"
                inspectOutput `shouldNotContain` "foreign-marker"
                inspectOutput
                  `shouldContain` "Local kind image configuration: matches the selected archive config ID."
                inspectOutput `shouldContain` "Daemon image metadata:"
                inspectOutput `shouldContain` "Config image ID: unobservable."
                inspectOutput `shouldContain` "Manifest image ID: unobservable."
                inspectOutput `shouldContain` "observations are not atomic"
                when ("connected" `isPrefixOf` caseName) $ do
                  projection <- readBootstrapProjection selected >>= either (fail . show) pure
                  let conflict = caseName == "connected-conflict"
                      stale = caseName == "connected-stale"
                      changedMarker = caseName == "connected-changed"
                      oldResult = caseName == "connected-old-result"
                      attemptPath = scopeRoot (bootstrapScope projection) </> "node-image-attempt.json"
                  when stale (BS8.writeFile attemptPath (BS8.pack "prior attempt"))
                  when oldResult $ do
                    let path = scopeRoot (bootstrapScope projection) </> "node-image-result.json"
                    BS8.writeFile path (BS8.pack "prior result")
                    setFileMode path 0o600
                  changeDuringRead <- newIORef False
                  changeOnCliRead <- newIORef False
                  changedDaemon <- newIORef False
                  let imageHook request = when ("/images/" `isInfixOf` request) $ do
                        change <- atomicModifyIORef' changeDuringRead (False,)
                        when change (BS8.writeFile attemptPath (BS8.pack "incomplete"))
                        when ("GET /v" `isPrefixOf` request) $ do
                          swap <- atomicModifyIORef' changeOnCliRead (False,)
                          when swap (writeIORef changedDaemon True)
                  withDockerDaemonFixtureHookMode
                    (anchor </> "docker.sock")
                    conflict
                    imageHook
                    (readIORef changedDaemon)
                    $ \requests -> do
                      called <- newIORef False
                      socketIdentity <-
                        observeDockerSocketIdentity (anchor </> "docker.sock")
                          >>= maybe (fail "missing fixture socket") pure
                      prepared <- withNewConnectedNodeImageRecordedAttempt projection (replicate 32 'b') $ \verified expected size heldFd session stable -> do
                        writeIORef called True
                        stable `shouldReturn` True
                        bytes <- PosixBytes.fdRead heldFd (fromInteger size)
                        digest bytes `shouldBe` expected
                        inspectDockerSessionImage session (nodeConfigDigest verified)
                          `shouldReturn` Right (ImageIdObserved "linux" "amd64" 0)
                        intent <-
                          maybe (fail "invalid staged intent") pure $
                            mkNodeImageIntent
                              (replicate 32 'b')
                              (nodeManifestDigest verified)
                              (nodeConfigDigest verified)
                              expected
                              size
                        bound <-
                          maybe (fail "invalid daemon binding") pure $
                            bindNodeImageIntent intent (DockerDaemonObserved "daemon-a" socketIdentity)
                        observeNodeImageAttempt projection bound stable `shouldReturn` NodeImageAttemptMatches
                        recordNodeImageAttempt projection bound stable `shouldReturn` NodeImageAttemptAlreadyExists
                        submission <-
                          loadAndObserveDockerSessionImage session heldFd size (nodeConfigDigest verified) stable
                        submission
                          `shouldBe` DockerImageSubmissionObservation
                            (DockerImageLoadReply 200 (DockerImageLoadMessages 1))
                            (DockerImageReadbackStable (Right (ImageIdObserved "linux" "amd64" 0)))
                        recordNodeImageResult projection bound (DockerImageLoadReply 0 (DockerImageLoadMessages 1)) stable
                          `shouldReturn` NodeImageResultRefused
                        pingDockerSession session `shouldReturn` Right ()
                        when changedMarker (BS8.writeFile attemptPath (BS8.pack "changed after callback"))
                        pure submission
                      let expectedSubmission =
                            NodeImageRecordedSubmission
                              ( DockerImageSubmissionObservation
                                  (DockerImageLoadReply 200 (DockerImageLoadMessages 1))
                                  (DockerImageReadbackStable (Right (ImageIdObserved "linux" "amd64" 0)))
                              )
                              (if changedMarker then NodeImageResultRefused else NodeImageResultRecorded)
                      prepared
                        `shouldBe` KindOperationCallbackReturned
                          ( InspectedArchiveCompleted
                              ( StagedNodeCompleted
                                  ( NodeImagePreparationCompleted
                                      ( NodeImageConnectedObserved
                                          ( DockerPeerCompleted
                                              ( DockerConnectedInfoCompleted
                                                  ( if conflict
                                                      then NodeImageConnectionRecordRefused NodeImageIntentConflict
                                                      else
                                                        NodeImageConnectionReady $
                                                          if stale
                                                            then NodeImageAttemptActionRefused NodeImageAttemptAlreadyExists
                                                            else
                                                              if oldResult
                                                                then NodeImageAttemptActionResultRefused NodeImageResultInvalid
                                                                else
                                                                  if changedMarker
                                                                    then NodeImageAttemptActionChangedAfter expectedSubmission
                                                                    else NodeImageAttemptActionReturned expectedSubmission
                                                  )
                                              )
                                          )
                                      )
                                  )
                              )
                          )
                      readIORef called `shouldReturn` not (conflict || stale || oldResult)
                      when (caseName == "connected") $ do
                        let unused = error "refused archive inventory evaluated an unused capability"
                            inspectArchive =
                              observeArchiveBoundConfinedKindInventoryOnHost
                                5000000
                                unused
                                unused
                                unused
                                projection
                                (replicate 32 'b')
                                "unused"
                                1
                                []
                                (Fd (-1))
                            intentPath = scopeRoot (bootstrapScope projection) </> "node-image-intent.json"
                            runNode =
                              runArchiveBoundConfinedKindNodeOnHost
                                5000000
                                unused
                                unused
                                unused
                                projection
                                (replicate 32 'b')
                                "unused"
                                1
                                []
                                (Fd (-1))
                                unused
                                unused
                        beforeNode <- readMVar requests
                        noNode <- runNode
                        case noNode of
                          InspectedArchiveCompleted (ConfinedNodeProposalUnavailable NodeCreateRecoveryMissing) -> pure ()
                          other -> expectationFailure ("missing node proposal was not refused: " ++ show other)
                        readMVar requests `shouldReturn` beforeNode
                        matching <- inspectArchive
                        case matching of
                          InspectedArchiveCompleted
                            ( ConfinedArchiveInventoryObserved
                                ( ConfinedImageRecordObserved
                                    ( DockerPeerCompleted
                                        ( DockerConnectedInfoCompleted
                                            (ConfinedDockerBindingObserved (ConfinedKindArtifactRefused _))
                                          )
                                      )
                                  )
                              ) -> pure ()
                          other -> expectationFailure ("matching archive did not reach artifact check: " ++ show other)
                        original <- BS8.readFile intentPath
                        decoded <- maybe (fail "invalid fixture image intent") pure (Aeson.decodeStrict' original)
                        changed <- case decoded of
                          Aeson.Object object ->
                            pure $
                              LazyBS8.toStrict $
                                Aeson.encode $
                                  Aeson.Object
                                    ( AesonKeyMap.insert
                                        (AesonKey.fromString "manifest_digest")
                                        (Aeson.String (Text.pack ("sha256:" ++ replicate 64 'f')))
                                        object
                                    )
                          _ -> fail "unexpected fixture image intent"
                        ( do
                            BS8.writeFile intentPath changed
                            before <- readMVar requests
                            mismatch <- inspectArchive
                            case mismatch of
                              InspectedArchiveCompleted ConfinedArchiveRecordMismatch -> pure ()
                              other -> expectationFailure ("archive mismatch was not refused: " ++ show other)
                            nodeMismatch <- runNode
                            case nodeMismatch of
                              InspectedArchiveCompleted ConfinedNodeImageRecordMismatch -> pure ()
                              other -> expectationFailure ("node archive mismatch was not refused: " ++ show other)
                            readMVar requests `shouldReturn` before
                          )
                          `finally` BS8.writeFile intentPath original
                      unless (conflict || stale || oldResult || changedMarker) $ do
                        observeRecordedNodeImageResult projection (replicate 32 'b')
                          `shouldReturn` NodeImageResultObserved (DockerImageLoadReply 200 (DockerImageLoadMessages 1))
                        let resultPath = scopeRoot (bootstrapScope projection) </> "node-image-result.json"
                            resultBackup = anchor </> "image-result-backup"
                        originalResult <- BS8.readFile resultPath
                        when (architecture == "amd64") $ do
                          imageCheck <- withRecoveredKindOperation projection (replicate 32 'b') $ \operationStable ->
                            withInspectedNodeArchive projection $ \verified _ artifactStable ->
                              withConnectedDockerInfo 5000000 (anchor </> "docker.sock") $ \session _ peerStable -> do
                                let stable = (&&) <$> operationStable <*> ((&&) <$> artifactStable <*> peerStable)
                                    sample candidateArchive = observeConfinedNodeImage projection (replicate 32 'b') candidateArchive session stable
                                sample verified `shouldReturn` ConfinedNodeImageReady
                                sample (verified {nodeArchitecture = "wrong"})
                                  `shouldReturn` ConfinedNodeImageMetadataRefused (Right (ImageIdObserved "linux" "amd64" 0))
                                beforeRefusals <- readMVar requests
                                originalAttempt <- BS8.readFile attemptPath
                                ( do
                                    BS8.writeFile attemptPath (BS8.pack "incomplete")
                                    sample verified `shouldReturn` ConfinedNodeImageAttemptRefused NodeImageAttemptInvalid
                                  )
                                  `finally` BS8.writeFile attemptPath originalAttempt
                                ( do
                                    BS8.writeFile resultPath (BS8.pack "incomplete")
                                    sample verified `shouldReturn` ConfinedNodeImageResultRefused NodeImageResultInvalid
                                  )
                                  `finally` BS8.writeFile resultPath originalResult
                                readMVar requests `shouldReturn` beforeRefusals
                          imageCheck
                            `shouldBe` KindOperationCallbackReturned
                              (InspectedArchiveCompleted (DockerPeerCompleted (DockerConnectedInfoCompleted ())))
                        renameFile resultPath resultBackup
                        observeRecordedNodeImageResult projection (replicate 32 'b') `shouldReturn` NodeImageResultMissing
                        createSymbolicLink resultBackup resultPath
                        observeRecordedNodeImageResult projection (replicate 32 'b')
                          `shouldReturn` NodeImageResultUnobservable
                        removeFile resultPath
                        renameFile resultBackup resultPath
                        BS8.writeFile resultPath (BS8.pack "incomplete")
                        observeRecordedNodeImageResult projection (replicate 32 'b') `shouldReturn` NodeImageResultInvalid
                        BS8.writeFile resultPath (BS8.pack "{\"result\":{\"state\":\"unconfirmed\"}}")
                        observeRecordedNodeImageResult projection (replicate 32 'b') `shouldReturn` NodeImageResultConflict
                        BS8.writeFile resultPath originalResult
                        retried <- newIORef False
                        duplicate <- withNewConnectedNodeImageAttempt projection (replicate 32 'b') $ \_ _ _ _ _ _ ->
                          writeIORef retried True
                        duplicate `shouldBe` KindOperationRefused (KindOperationIntentRefused KindIntentAlreadyExists)
                        readIORef retried `shouldReturn` False
                        sent <- readMVar requests
                        length (filter (isPrefixOf "POST /images/load?quiet=1 ") sent) `shouldBe` 1
                        let expectedRecovery before after =
                              KindOperationCallbackReturned $
                                InspectedArchiveCompleted $
                                  StagedNodeCompleted $
                                    NodeImageConnectedObserved $
                                      DockerPeerCompleted $
                                        DockerConnectedInfoCompleted $
                                          NodeImageConnectionReady $
                                            NodeImageRecoveryPoint
                                              (digest config)
                                              before
                                              ( if before == NodeImageAttemptMatches
                                                  then NodeImageResultObserved (DockerImageLoadReply 200 (DockerImageLoadMessages 1))
                                                  else NodeImageResultUnobservable
                                              )
                                              (Right (ImageIdObserved "linux" "amd64" 0))
                                              (NodeImageIndependentObserved (ImageIdObserved "linux" "amd64" 0))
                                              after
                        recovered <- observeRecoveredConnectedNodeImage projection (replicate 32 'b')
                        recovered `shouldBe` expectedRecovery NodeImageAttemptMatches NodeImageAttemptMatches
                        writeIORef changeOnCliRead True
                        changedDaemonSample <- observeRecoveredConnectedNodeImage projection (replicate 32 'b')
                        case changedDaemonSample of
                          KindOperationCallbackReturned
                            ( InspectedArchiveCompleted
                                ( StagedNodeCompleted
                                    ( NodeImageConnectedObserved
                                        ( DockerPeerCompleted
                                            (DockerConnectedInfoCompleted (NodeImageConnectionReady point))
                                          )
                                      )
                                  )
                              ) ->
                              recoveryIndependentImage point
                                `shouldBe` NodeImageIndependentChanged (ImageIdObserved "linux" "amd64" 0)
                          other -> expectationFailure ("unexpected changed-daemon observation: " ++ show other)
                        writeIORef changedDaemon False
                        (diagnosticExit, diagnosticOutput, diagnosticError) <-
                          run ["--config", selected, "control", "inspect-image-attempt", replicate 32 'b'] ""
                        (diagnosticExit, diagnosticError) `shouldBe` (ExitSuccess, "")
                        diagnosticOutput `shouldContain` ("Exact image ID: " ++ digest config)
                        diagnosticOutput `shouldContain` "Attempt before image query: matching local marker"
                        diagnosticOutput `shouldContain` "Recorded transport observation: HTTP 200; 1 progress message"
                        diagnosticOutput `shouldContain` "Attempt after image query: matching local marker"
                        diagnosticOutput `shouldContain` "Image metadata: observed linux/amd64 with 0 daemon tags"
                        diagnosticOutput
                          `shouldContain` "Separate Docker CLI observation: observed linux/amd64 with 0 daemon tags"
                        diagnosticOutput `shouldContain` "worker settlement are unverified"
                        requestCount <- length <$> readMVar requests
                        (invalidIdExit, _, _) <- run ["--config", selected, "control", "inspect-image-attempt", "../bad"] ""
                        invalidIdExit `shouldBe` ExitFailure 1
                        (length <$> readMVar requests) `shouldReturn` requestCount
                        originalAttempt <- BS8.readFile attemptPath
                        writeIORef changeDuringRead True
                        changed <- observeRecoveredConnectedNodeImage projection (replicate 32 'b')
                        changed `shouldBe` expectedRecovery NodeImageAttemptMatches NodeImageAttemptInvalid
                        BS8.writeFile attemptPath originalAttempt
                        writeIORef changeDuringRead True
                        (changedExit, changedOutput, _) <-
                          run ["--config", selected, "control", "inspect-image-attempt", replicate 32 'b'] ""
                        changedExit `shouldBe` ExitSuccess
                        changedOutput `shouldContain` "Attempt before image query: matching local marker"
                        changedOutput `shouldContain` "Attempt after image query: invalid or incomplete local marker"
                        BS8.writeFile attemptPath originalAttempt
                        let backupPath = anchor </> "recovery-attempt-backup"
                        renameFile attemptPath backupPath
                        missing <- observeRecoveredConnectedNodeImage projection (replicate 32 'b')
                        missing `shouldBe` expectedRecovery NodeImageAttemptMissing NodeImageAttemptMissing
                        renameFile backupPath attemptPath
                        BS8.writeFile attemptPath (BS8.pack "incomplete")
                        invalid <- observeRecoveredConnectedNodeImage projection (replicate 32 'b')
                        invalid `shouldBe` expectedRecovery NodeImageAttemptInvalid NodeImageAttemptInvalid
                        (invalidExit, invalidOutput, _) <-
                          run ["--config", selected, "control", "inspect-image-attempt", replicate 32 'b'] ""
                        invalidExit `shouldBe` ExitSuccess
                        invalidOutput `shouldContain` "Attempt before image query: invalid or incomplete local marker"
                        invalidOutput `shouldContain` "Attempt after image query: invalid or incomplete local marker"
                      when conflict $ do
                        recovered <- observeRecoveredConnectedNodeImage projection (replicate 32 'b')
                        recovered
                          `shouldBe` KindOperationCallbackReturned
                            ( InspectedArchiveCompleted
                                ( StagedNodeCompleted
                                    ( NodeImageConnectedObserved
                                        ( DockerPeerCompleted
                                            (DockerConnectedInfoCompleted (NodeImageConnectionRecordRefused NodeImageIntentConflict))
                                        )
                                    )
                                )
                            )
                        (refused, _, _) <-
                          run ["--config", selected, "control", "inspect-image-attempt", replicate 32 'b'] ""
                        refused `shouldBe` ExitFailure 1
                      observedRequests <- readMVar requests
                      observedRequests `shouldSatisfy` (not . null)
                      when conflict $ observedRequests `shouldSatisfy` all (not . isInfixOf "/images/")
                      when stale $ observedRequests `shouldSatisfy` all (not . isPrefixOf "POST /images/load")
                      when oldResult $ observedRequests `shouldSatisfy` all (not . isPrefixOf "POST /images/load")
                      observedRequests `shouldSatisfy` all allowedDockerFixtureRequest
                when (caseName `elem` ["match", "index", "docker", "dockerindex"]) $ do
                  projection <- readBootstrapProjection selected >>= either (fail . show) pure
                  projected <- withInspectedNodeArchive projection $ \verified _ _ -> do
                    nodeSelectedDigest verified `shouldBe` imageDigest
                    nodeManifestDigest verified `shouldBe` digest manifest
                    nodeConfigDigest verified `shouldBe` digest config
                    renderKindConfigForArchive
                      (bootstrapKindPlan projection)
                      verified {nodeSelectedDigest = "sha256:" ++ replicate 64 'f'}
                      `shouldBe` Nothing
                    renderKindConfigForArchive
                      (bootstrapKindPlan projection)
                      verified {nodeConfigDigest = "invalid"}
                      `shouldBe` Nothing
                    pure (renderKindConfigForArchive (bootstrapKindPlan projection) verified)
                  case projected of
                    InspectedArchiveCompleted (Just configBytes) -> do
                      let configText = LazyBS8.unpack configBytes
                      configText `shouldContain` digest config
                      configText `shouldNotContain` imageDigest
                    other -> expectationFailure (show other)
                when (caseName `elem` ["match", "named", "extra"]) $ do
                  projection <- readBootstrapProjection selected >>= either (fail . show) pure
                  let outputPath = anchor </> "untagged.tar"
                  exported <- IO.withBinaryFile outputPath IO.WriteMode $ \output ->
                    withInspectedNodeArchive projection $ \verified heldFd recheck ->
                      writeUntaggedDockerArchive verified heldFd recheck output
                  output <- LazyBS8.readFile outputPath
                  let strictOutput = LazyBS8.toStrict output
                  exported
                    `shouldBe` InspectedArchiveCompleted
                      (DockerArchiveWritten (digest strictOutput) (toInteger (BS8.length strictOutput)))
                  let collect tarEntries = case tarEntries of
                        Tar.Done -> Right []
                        Tar.Fail failure -> Left (show failure)
                        Tar.Next entry rest -> case TarEntry.entryContent entry of
                          TarEntry.NormalFile content _ -> ((TarEntry.entryPath entry, LazyBS8.toStrict content) :) <$> collect rest
                          _ -> Left "unexpected tar entry"
                  extracted <- either fail pure (collect (Tar.read output))
                  let configPath = "blobs/sha256/" ++ drop 7 (digest config)
                      layerPath = "blobs/sha256/" ++ drop 7 (digest layer)
                      expectedManifest =
                        BS8.pack
                          ("[{\"Config\":\"" ++ configPath ++ "\",\"RepoTags\":[],\"Layers\":[\"" ++ layerPath ++ "\"]}]")
                  sort (map fst extracted) `shouldBe` sort ["manifest.json", configPath, layerPath]
                  lookup configPath extracted `shouldBe` Just config
                  lookup layerPath extracted `shouldBe` Just layer
                  case lookup "manifest.json" extracted of
                    Nothing -> expectationFailure "missing Docker archive manifest"
                    Just actual ->
                      (Aeson.eitherDecodeStrict' actual :: Either String [Aeson.Value])
                        `shouldBe` Aeson.eitherDecodeStrict' expectedManifest
                  BS8.unpack strictOutput `shouldNotContain` "sensitive-marker"
                  BS8.unpack strictOutput `shouldNotContain` "foreign-marker"
                when (caseName == "match") $ do
                  projection <- readBootstrapProjection selected >>= either (fail . show) pure
                  bracket (Posix.openFd selected Posix.ReadOnly Posix.defaultFileFlags) Posix.closeFd $ \readOnly -> do
                    reserveStage readOnly 4096 `shouldReturn` False
                    reserveStage readOnly 0 `shouldReturn` False
                    reserveStage readOnly (maximumDockerArchiveBytes + 1) `shouldReturn` False
                  staged <- withStagedNodeArchive projection $ \_ expected size heldFd recheck -> do
                    status <- PosixFiles.getFdStatus heldFd
                    PosixFiles.linkCount status `shouldBe` 0
                    toInteger (PosixFiles.fileSize status) `shouldBe` size
                    recheck `shouldReturn` True
                    bytes <- PosixBytes.fdRead heldFd (fromInteger size)
                    digest bytes `shouldBe` expected
                    pure heldFd
                  case staged of
                    InspectedArchiveCompleted (StagedNodeCompleted closedFd) -> do
                      closed <- try (PosixFiles.getFdStatus closedFd) :: IO (Either SomeException PosixFiles.FileStatus)
                      closed `shouldSatisfy` isLeft
                    other -> expectationFailure ("anonymous staging failed: " ++ show other)
                  changedStage <- withStagedNodeArchive projection $ \_ _ _ heldFd recheck -> do
                    _ <- Posix.fdSeek heldFd IO.AbsoluteSeek 0
                    _ <- PosixBytes.fdWrite heldFd (BS8.pack "x")
                    recheck `shouldReturn` False
                    pure ("receipt" :: String)
                  changedStage `shouldBe` InspectedArchiveCompleted (StagedNodeChanged "receipt")
                  let operation = replicate 32 'b'
                  prepared <- withNewNodeImagePreparation projection operation $ \verified expected size heldFd stable -> do
                    intent <-
                      maybe (fail "invalid staged image intent") pure $
                        mkNodeImageIntent operation (nodeManifestDigest verified) (nodeConfigDigest verified) expected size
                    observeNodeImageIntent projection intent stable `shouldReturn` NodeImageIntentMatches
                    stable `shouldReturn` True
                    bytes <- PosixBytes.fdRead heldFd (fromInteger size)
                    digest bytes `shouldBe` expected
                    pure ("recorded before callback" :: String)
                  prepared
                    `shouldBe` KindOperationCallbackReturned
                      ( InspectedArchiveCompleted
                          (StagedNodeCompleted (NodeImagePreparationCompleted "recorded before callback"))
                      )
                  observeRecordedNodeImageAttempt projection operation `shouldReturn` NodeImageAttemptUnobservable
                  recovered <- observeRecoveredNodeImagePreparation projection operation
                  recovered
                    `shouldBe` KindOperationCallbackReturned
                      (InspectedArchiveCompleted (StagedNodeCompleted (NodeImageRecoveryObserved NodeImageIntentMatches)))
                  let imageIntentPath = anchor </> ".test-data" </> caseName </> "node-image-intent.json"
                  savedIntent <- BS8.readFile imageIntentPath
                  BS8.writeFile imageIntentPath (BS8.pack "incomplete")
                  invalidRecovery <- observeRecoveredNodeImagePreparation projection operation
                  invalidRecovery
                    `shouldBe` KindOperationCallbackReturned
                      (InspectedArchiveCompleted (StagedNodeCompleted (NodeImageRecoveryObserved NodeImageIntentInvalid)))
                  BS8.writeFile imageIntentPath savedIntent
                  let refusedPath = anchor </> "refused.tar"
                  unsupportedExport <- IO.withBinaryFile refusedPath IO.WriteMode $ \output ->
                    withInspectedNodeArchive projection $ \verified heldFd recheck ->
                      writeUntaggedDockerArchive (verified {nodeLoadPlan = Nothing}) heldFd recheck output
                  unsupportedExport
                    `shouldBe` InspectedArchiveCompleted (DockerArchiveNotStarted DockerArchiveUnsupportedConfig)
                  BS8.readFile refusedPath `shouldReturn` BS8.empty
                  forM_ ["media", "diff-id", "config-digest"] $ \invalidCase -> do
                    let invalidPath = anchor </> ("invalid-" ++ invalidCase ++ ".tar")
                        invalidate plan = case invalidCase of
                          "media" -> plan {nodeLoadConfig = (nodeLoadConfig plan) {nodeBlobMediaType = "invalid"}}
                          "diff-id" -> plan {nodeLoadDiffIds = ["sha256:invalid"]}
                          _ -> plan {nodeLoadConfig = (nodeLoadConfig plan) {nodeBlobDigest = "sha256:" ++ replicate 64 'd'}}
                    invalid <- IO.withBinaryFile invalidPath IO.WriteMode $ \output ->
                      withInspectedNodeArchive projection $ \verified heldFd recheck ->
                        writeUntaggedDockerArchive
                          (verified {nodeLoadPlan = invalidate <$> nodeLoadPlan verified})
                          heldFd
                          recheck
                          output
                    invalid `shouldBe` InspectedArchiveCompleted (DockerArchiveNotStarted DockerArchiveInvalidPlan)
                    BS8.readFile invalidPath `shouldReturn` BS8.empty
                  let oversizedPath = anchor </> "oversized.tar"
                      oversized plan =
                        plan
                          { nodeLoadConfig = (nodeLoadConfig plan) {nodeBlobSize = 0}
                          , nodeLoadLayers =
                              map (\blob -> blob {nodeBlobSize = maximumDockerArchiveBytes}) (take 1 (nodeLoadLayers plan))
                          , nodeLoadDiffIds = take 1 (nodeLoadDiffIds plan)
                          }
                  oversizedResult <- IO.withBinaryFile oversizedPath IO.WriteMode $ \output ->
                    withInspectedNodeArchive projection $ \verified heldFd recheck ->
                      writeUntaggedDockerArchive
                        (verified {nodeLoadPlan = oversized <$> nodeLoadPlan verified})
                        heldFd
                        recheck
                        output
                  oversizedResult
                    `shouldBe` InspectedArchiveCompleted (DockerArchiveNotStarted DockerArchiveSizeLimitExceeded)
                  BS8.readFile oversizedPath `shouldReturn` BS8.empty
                  attempts <- newIORef (0 :: Int)
                  let partialPath = anchor </> "partial.tar"
                  partial <- IO.withBinaryFile partialPath IO.WriteMode $ \output ->
                    withInspectedNodeArchive projection $ \verified heldFd recheck ->
                      writeUntaggedDockerArchive
                        verified
                        heldFd
                        ( do
                            count <- atomicModifyIORef' attempts (\n -> (n + 1, n))
                            if count == 0 then recheck else pure False
                        )
                        output
                  partial `shouldBe` InspectedArchiveCompleted (DockerArchiveIncomplete DockerArchiveChanged)
                  partialBytes <- BS8.readFile partialPath
                  BS8.null partialBytes `shouldBe` False
                  let retained = anchor </> ".test-data" </> caseName </> "artifacts" </> "node.tar"
                  unconfirmed <- withInspectedNodeArchive projection $ \_ _ _ -> (ioError (userError "controlled observation failure") :: IO ())
                  unconfirmed `shouldBe` InspectedArchiveUnconfirmed NodeArchiveUnobservable
                  changed <- withInspectedNodeArchive projection $ \_ heldFd recheck -> do
                    Posix.fdSeek heldFd IO.RelativeSeek 0 `shouldReturn` 0
                    recheck `shouldReturn` True
                    BS8.writeFile retained (BS8.pack "changed during observation")
                    recheck `shouldReturn` False
                    pure ("callback-result" :: String)
                  changed `shouldBe` InspectedArchiveChanged "callback-result"
                  BS8.writeFile retained strict
                  setFileMode retained 0o600
                  let generationPath = anchor </> ".test-data" </> caseName </> "scope-generation.json"
                  originalGeneration <- BS8.readFile generationPath
                  generationChanged <- withInspectedNodeArchive projection $ \_ _ _ -> do
                    BS8.writeFile generationPath (BS8.pack "invalid")
                    pure ("generation-result" :: String)
                  generationChanged `shouldBe` InspectedArchiveChanged "generation-result"
                  BS8.writeFile generationPath originalGeneration
                  BS8.writeFile generationPath (BS8.pack "invalid")
                  let callbackMarker = anchor </> "unexpected-callback"
                  refused <- withInspectedNodeArchive projection $ \_ _ _ -> BS8.writeFile callbackMarker (BS8.pack "called")
                  refused `shouldBe` InspectedArchiveRefused NodeArchiveGenerationUnavailable
                  doesFileExist callbackMarker `shouldReturn` False
                writeFile (anchor </> ".test-data" </> caseName </> "scope-generation.json") "invalid"
                (generationExit, _, generationError) <-
                  run ["--config", selected, "control", "inspect-node-archive"] ""
                generationExit `shouldBe` ExitFailure 1
                generationError `shouldContain` "NodeArchiveGenerationUnavailable"
              else inspectExit `shouldBe` ExitFailure 1

  describe "selected configuration validation" $
    it "validates the selected snapshot and refuses unsupported commands and imports" $
      withSystemTempDirectory "prodbox-selected-config" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \path -> installOperatorBinaryInDir path tmpDir
        writeRepoMarkers tmpDir
        let selectedDirectory = tmpDir </> "selected"
            selectedPath = selectedDirectory </> "prodbox.dhall"
            productionPath = tmpDir </> "prodbox.dhall"
            configured = validConfig
        createDirectoryIfMissing True selectedDirectory
        writeTier0Fixture selectedDirectory (tier0FixtureWithParameters configured)
        writeTier0Fixture
          tmpDir
          ( rawTier0Fixture
              (MustNotTypeCheckAgainst "foreign marker is not a Tier-0 document")
              "production marker"
          )
        let run arguments = readCreateProcessWithExitCode (proc binary arguments) {cwd = Just tmpDir} ""
            writeSelected document =
              writeTier0Fixture
                selectedDirectory
                (rawTier0Fixture (MustNotTypeCheckAgainst "legacy Tier-0 bootstrap field") document)
        (schemaExit, schemaOutput, schemaError) <- run ["config", "schema"]
        schemaExit `shouldBe` ExitSuccess
        schemaOutput `shouldContain` "prodbox-bootstrap-types.dhall"
        schemaError `shouldBe` ""
        schema <- readFile (tmpDir </> "prodbox-bootstrap-types.dhall")
        length schema `seq` removeFile (tmpDir </> "prodbox-bootstrap-types.dhall")
        createSymbolicLink productionPath (tmpDir </> "prodbox-bootstrap-types.dhall")
        (schemaLinkExit, _, _) <- run ["config", "schema"]
        case schemaLinkExit of
          ExitSuccess -> expectationFailure "schema writer accepted a symlink"
          ExitFailure _ -> pure ()
        readFile productionPath `shouldReturn` "production marker"
        removeFile (tmpDir </> "prodbox-bootstrap-types.dhall")
        (validExit, _, validError) <- run ["--config", selectedPath, "config", "validate"]
        case validExit of
          ExitSuccess -> pure ()
          ExitFailure _ -> expectationFailure ("selected configuration validation failed: " ++ validError)
        original <- BS8.readFile selectedPath
        let bootstrap = bootstrapAt tmpDir
            bootstrapAt anchor identity generation =
              "{ schema_version = 1, project_anchor = \""
                ++ anchor
                ++ "\", runtime_socket = \"/var/run/docker.sock\", environment = \"test\", deployment_id = \""
                ++ identity
                ++ "\", root_generation = \""
                ++ generation
                ++ "\", api_port = 26443, node_image = \"kindest/node@sha256:"
                ++ replicate 64 'a'
                ++ "\", http_host_port = 28080, http_node_port = 30080, https_host_port = 28443, https_node_port = 30443, listen_address = \"127.0.0.1\" }"
            withBootstrap identity generation = "(\n" ++ BS8.unpack original ++ "\n) // { bootstrap = " ++ bootstrap identity generation ++ " }"
            matchingIdentity = "synthetic-test-cluster"
        writeSelected
          ( "{ bootstrap = ("
              ++ bootstrap matchingIdentity (replicate 32 'a')
              ++ " : ("
              ++ schema
              ++ ").Version1) }"
          )
        (minimalExit, minimalOutput, minimalError) <- run ["--config", selectedPath, "config", "validate"]
        minimalExit `shouldBe` ExitSuccess
        minimalOutput `shouldContain` "Bootstrap configuration validated"
        minimalOutput
          `shouldContain` "application settings, deployment root and runtime state were not checked"
        minimalError `shouldBe` ""
        let foreignRoot = tmpDir </> ".data" </> "production"
        createDirectoryIfMissing True foreignRoot
        writeFile (foreignRoot </> "marker") "production marker"
        writeSelected
          ("{ bootstrap = " ++ bootstrapAt foreignRoot matchingIdentity (replicate 32 'a') ++ " }")
        forM_ [["config", "validate"], ["control", "status"], ["control", "plan"]] $ \command -> do
          (foreignExit, _, foreignError) <- run (["--config", selectedPath] ++ command)
          foreignExit `shouldBe` ExitFailure 1
          foreignError `shouldContain` "InvalidProjectAnchor"
          readFile (foreignRoot </> "marker") `shouldReturn` "production marker"
          doesDirectoryExist (foreignRoot </> ".test-data") `shouldReturn` False
        let artifact name =
              "{ path = \"artifacts/"
                ++ name
                ++ "\", digest = \"sha256:"
                ++ replicate 64 'b'
                ++ "\", maximum_bytes = 1024 }"
            typedBootstrap :: Int -> String -> String
            typedBootstrap version suffix =
              "{ bootstrap = (("
                ++ bootstrap matchingIdentity (replicate 32 'a')
                ++ ") // { schema_version = "
                ++ show version
                ++ suffix
                ++ " } : ("
                ++ schema
                ++ ").Version"
                ++ show version
                ++ ") }"
        forM_
          [ typedBootstrap 2 (", node_artifact = " ++ artifact "node.tar")
          , typedBootstrap
              3
              (", node_artifact = " ++ artifact "node.tar" ++ ", kind_tool = " ++ artifact "kind")
          ]
          $ \selectedDocument -> do
            writeSelected selectedDocument
            (typedExit, _, typedError) <- run ["--config", selectedPath, "config", "validate"]
            case typedExit of
              ExitSuccess -> pure ()
              ExitFailure _ -> expectationFailure ("generated bootstrap schema did not match decoder: " ++ typedError)
        writeSelected ("{ bootstrap = " ++ bootstrap matchingIdentity "bad" ++ " }")
        (minimalBadExit, _, minimalBadError) <- run ["--config", selectedPath, "config", "validate"]
        minimalBadExit `shouldBe` ExitFailure 1
        minimalBadError `shouldContain` "BootstrapInvalidGeneration"
        writeSelected
          ("{ bootstrap = " ++ bootstrap matchingIdentity (replicate 32 'a') ++ ", parameters = True }")
        (partialExit, _, partialError) <- run ["--config", selectedPath, "config", "validate"]
        partialExit `shouldBe` ExitFailure 1
        partialError `shouldContain` "invalid parameters or context"
        doesDirectoryExist (tmpDir </> ".test-data") `shouldReturn` False
        writeSelected (withBootstrap matchingIdentity (replicate 32 'a'))
        (completeExit, _, completeError) <- run ["--config", selectedPath, "config", "validate"]
        case completeExit of
          ExitSuccess -> pure ()
          ExitFailure _ -> expectationFailure ("selected bootstrap validation failed: " ++ completeError)
        writeSelected (withBootstrap matchingIdentity "bad")
        (badExit, _, badError) <- run ["--config", selectedPath, "config", "validate"]
        badExit `shouldBe` ExitFailure 1
        badError `shouldContain` "BootstrapInvalidGeneration"
        (statusExit, _, statusError) <- run ["--config", selectedPath, "control", "status"]
        statusExit `shouldBe` ExitFailure 1
        statusError `shouldContain` "BootstrapInvalidGeneration"
        doesDirectoryExist (tmpDir </> ".test-data") `shouldReturn` False
        writeSelected (withBootstrap "foreign" (replicate 32 'a'))
        (foreignExit, _, foreignError) <- run ["--config", selectedPath, "config", "validate"]
        foreignExit `shouldBe` ExitFailure 1
        foreignError `shouldContain` "BootstrapContextIdentityMismatch"
        (foreignStatusExit, _, foreignStatusError) <- run ["--config", selectedPath, "control", "status"]
        foreignStatusExit `shouldBe` ExitFailure 1
        foreignStatusError `shouldContain` "BootstrapContextIdentityMismatch"
        doesDirectoryExist (tmpDir </> ".test-data") `shouldReturn` False
        (unsupportedExit, _, unsupportedError) <- run ["--config", selectedPath, "config", "generate"]
        unsupportedExit `shouldBe` ExitFailure 1
        unsupportedError `shouldContain` "selected configuration is not supported"
        readFile productionPath `shouldReturn` "production marker"
        let importedPath = selectedDirectory </> "imported.dhall"
            symlinkPath = selectedDirectory </> "linked.dhall"
        writeFile importedPath "env:PRODBOX_SELECTED_CONFIG_MUST_NOT_BE_READ"
        (importExit, _, importError) <- run ["--config", importedPath, "config", "validate"]
        importExit `shouldBe` ExitFailure 1
        importError `shouldContain` "imports are not supported"
        writeSelected ("{ bootstrap = " ++ bootstrap matchingIdentity (replicate 32 'a') ++ " }")
        (linkBaselineExit, _, linkBaselineError) <- run ["--config", selectedPath, "config", "validate"]
        case linkBaselineExit of
          ExitSuccess -> pure ()
          ExitFailure _ -> expectationFailure ("symlink target baseline failed: " ++ linkBaselineError)
        createSymbolicLink selectedPath symlinkPath
        (linkExit, _, _) <- run ["--config", symlinkPath, "config", "validate"]
        linkExit `shouldBe` ExitFailure 1
        let linkedDirectory = tmpDir </> "linked-selected"
        createSymbolicLink selectedDirectory linkedDirectory
        (parentLinkExit, _, _) <-
          run ["--config", linkedDirectory </> "prodbox.dhall", "config", "validate"]
        parentLinkExit `shouldBe` ExitFailure 1
        (statusParentLinkExit, _, _) <-
          run ["--config", linkedDirectory </> "prodbox.dhall", "control", "status"]
        statusParentLinkExit `shouldBe` ExitFailure 1
        readFile productionPath `shouldReturn` "production marker"

  describe "registered local test inventory" $
    it "lists the runnable local names without a repository or configuration" $
      withSystemTempDirectory "prodbox-test-list" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \path -> installOperatorBinaryInDir path tmpDir
        (result, output, errors) <-
          readCreateProcessWithExitCode
            (proc binary ["test", "list"])
              { cwd = Just tmpDir
              , env = Just [("PATH", "/usr/bin:/bin"), ("HOME", tmpDir)]
              }
            ""
        result `shouldBe` ExitSuccess
        errors `shouldBe` ""
        output
          `shouldBe` "Built-in local suites:\n  unit\n  env\n  cli\n  evidence\nLegacy topology-defined suites require a separate test topology and are not listed here.\n"
        doesFileExist (tmpDir </> "prodbox.dhall") `shouldReturn` False
        doesDirectoryExist (tmpDir </> ".test-data") `shouldReturn` False

  describe "test configuration isolation" $
    it "refuses unisolated topology and native suites before creating a sibling config or run root" $
      withSystemTempDirectory "prodbox-test-config-isolation" $ \tmpDir -> do
        sourceRoot <- getCurrentDirectory
        binary <- resolveBinaryPath >>= \path -> installOperatorBinaryInDir path tmpDir
        createDirectoryIfMissing True (tmpDir </> "DEVELOPMENT_PLAN")
        writeFile (tmpDir </> "prodbox.cabal") "name: fixture\n"
        writeFile (tmpDir </> "DEVELOPMENT_PLAN" </> "README.md") "# fixture\n"
        writeFile
          (tmpDir </> "prodbox.test.dhall")
          (renderTestTopologyDhall (sourceRoot </> "dhall" </> "TestTopologySchema.dhall") defaultTestTopology)
        let environment = [("PATH", "/usr/bin:/bin"), ("HOME", tmpDir), ("PRODBOX_TEST_RKE2_PRESENT", "0")]
        forM_ [["test", "run", "all"], ["test", "run", "phase-01"], ["test", "run", "phase-10"]] $ \arguments -> do
          (result, output, errors) <-
            readCreateProcessWithExitCode
              (proc binary arguments) {cwd = Just tmpDir, env = Just environment}
              ""
          result `shouldBe` ExitFailure 1
          (output ++ errors) `shouldContain` "The cumulative scenario runner is not implemented yet"
          doesFileExist (tmpDir </> "prodbox.dhall") `shouldReturn` False
          doesDirectoryExist (tmpDir </> ".test-data") `shouldReturn` False
        forM_ [["test", "integration", "aws-iam"]] $ \arguments -> do
          (result, output, errors) <-
            readCreateProcessWithExitCode
              (proc binary arguments) {cwd = Just tmpDir, env = Just environment}
              ""
          result `shouldBe` ExitFailure 1
          (output ++ errors) `shouldContain` "Cannot run this test until its generated configuration"
          doesFileExist (tmpDir </> "prodbox.dhall") `shouldReturn` False
          doesDirectoryExist (tmpDir </> ".test-data") `shouldReturn` False
        (coverageResult, coverageOutput, coverageErrors) <-
          readCreateProcessWithExitCode
            (proc binary ["test", "run", "unit", "--coverage"]) {cwd = Just tmpDir, env = Just environment}
            ""
        coverageResult `shouldBe` ExitFailure 1
        (coverageOutput ++ coverageErrors)
          `shouldContain` "Coverage is not supported by the named unit runner yet"
        doesFileExist (tmpDir </> "prodbox.dhall") `shouldReturn` False
        doesDirectoryExist (tmpDir </> ".test-data") `shouldReturn` False
        let productionPath = tmpDir </> "prodbox.dhall"
        writeTier0Fixture
          tmpDir
          ( rawTier0Fixture
              (MustNotTypeCheckAgainst "foreign marker is not a Tier-0 document")
              "foreign-production-marker"
          )
        (result, _, _) <-
          readCreateProcessWithExitCode
            (proc binary ["test", "run", "unit"]) {cwd = Just tmpDir, env = Just environment}
            ""
        result `shouldBe` ExitFailure 1
        readFile productionPath `shouldReturn` "foreign-production-marker"
        doesDirectoryExist (tmpDir </> ".test-data") `shouldReturn` False

  describe "named CLI suite host guard" $
    it "treats existing markers and dangling symlinks as present" $
      withSystemTempDirectory "prodbox-cli-host-guard" $ \directory -> do
        let marker = directory </> "marker"
        TestRunner.observeLegacyInstallMarkers [marker] `shouldReturn` Just False
        writeFile marker "fixture"
        TestRunner.observeLegacyInstallMarkers [marker] `shouldReturn` Just True
        removeFile marker
        createSymbolicLink (directory </> "missing-target") marker
        TestRunner.observeLegacyInstallMarkers [marker] `shouldReturn` Just True

  describe "named unit environment isolation" $
    it "runs the named suites without passing ambient credentials or cluster selection" $
      withSystemTempDirectory "prodbox-named-unit-environment" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \path -> installOperatorBinaryInDir path tmpDir
        createDirectoryIfMissing True (tmpDir </> "DEVELOPMENT_PLAN")
        createDirectoryIfMissing True (tmpDir </> "bin")
        createDirectoryIfMissing True (tmpDir </> ".kube")
        writeFile (tmpDir </> ".kube" </> "config") "foreign kubeconfig marker"
        writeFile (tmpDir </> "prodbox.cabal") "name: fixture\n"
        writeFile (tmpDir </> "DEVELOPMENT_PLAN" </> "README.md") "# fixture\n"
        let fakeCabal = tmpDir </> "bin" </> "cabal"
        writeFile fakeCabal $
          unlines
            [ "#!/bin/sh"
            , "[ \"$HOME\" != \"$PWD\" ] || exit 9"
            , "[ ! -e \"$HOME/.kube/config\" ] || exit 10"
            , "[ -z \"${AWS_ACCESS_KEY_ID+x}\" ] || exit 11"
            , "[ -z \"${PRODBOX_GENERATE_FROZEN_V4+x}\" ] || exit 12"
            , "[ \"$AWS_CONFIG_FILE\" = /dev/null ] || exit 13"
            , "[ \"$AWS_SHARED_CREDENTIALS_FILE\" = /dev/null ] || exit 14"
            , "[ \"$AWS_EC2_METADATA_DISABLED\" = true ] || exit 15"
            , "[ \"$KUBECONFIG\" = /dev/null ] || exit 16"
            , "[ \"$DOCKER_HOST\" = unix:///nonexistent/prodbox.sock ] || exit 17"
            , "[ \"$DOCKER_CONFIG\" = /nonexistent ] || exit 18"
            , "case \"$1\" in"
            , "  list-bin) printf '%s\\n' \"$PWD/prodbox\" ;;"
            , "  test)"
            , "    if [ \"$3\" = test:prodbox-integration ] && [ \"$5\" != --test-option=--prodbox-suite=env ]; then exit 20; fi"
            , "    printf '%s\\n' \"$3\" >> .build/unit-calls ;;"
            , "  *) exit 19 ;;"
            , "esac"
            ]
        setFileMode fakeCabal 0o700
        let environment =
              [ ("PATH", tmpDir </> "bin" ++ ":/usr/bin:/bin")
              , ("HOME", tmpDir)
              , ("AWS_ACCESS_KEY_ID", "fixture-not-secret")
              , ("AWS_CONFIG_FILE", "/foreign/aws-config")
              , ("KUBECONFIG", "/foreign/kubeconfig")
              , ("DOCKER_HOST", "unix:///foreign/docker.sock")
              , ("PRODBOX_GENERATE_FROZEN_V4", "/foreign/output")
              ]
        (result, _, errors) <-
          readCreateProcessWithExitCode
            (proc binary ["test", "run", "unit"]) {cwd = Just tmpDir, env = Just environment}
            ""
        (result, errors) `shouldBe` (ExitSuccess, "")
        calls <- lines <$> readFile (tmpDir </> ".build" </> "unit-calls")
        calls
          `shouldBe` [ "test:prodbox-unit"
                     , "test:prodbox-authority-admission-unit"
                     , "test:prodbox-control-plane-authentication-unit"
                     , "test:prodbox-control-plane-authenticated-transport-unit"
                     , "test:prodbox-haskell-style"
                     , "test:prodbox-pulumi"
                     ]
        (envResult, _, envErrors) <-
          readCreateProcessWithExitCode
            (proc binary ["test", "run", "env"]) {cwd = Just tmpDir, env = Just environment}
            ""
        (envResult, envErrors) `shouldBe` (ExitSuccess, "")
        envCalls <- lines <$> readFile (tmpDir </> ".build" </> "unit-calls")
        envCalls `shouldBe` (calls ++ ["test:prodbox-integration"])
        doesFileExist (tmpDir </> "prodbox.dhall") `shouldReturn` False
        doesDirectoryExist (tmpDir </> ".test-data") `shouldReturn` False
        readFile (tmpDir </> ".kube" </> "config") `shouldReturn` "foreign kubeconfig marker"

  describe "authority fixture typed failures" $
    it "returns a reasoned 500 for malformed config and continues serving" $
      withSystemTempDirectory "prodbox-authority-invalid-config" $ \tmpDir -> do
        let configPath = tmpDir </> "prodbox.dhall"
        writeTier0Fixture
          tmpDir
          ( rawTier0Fixture
              (MustNotTypeCheckAgainst "malformed deployment configuration")
              "this is not a valid deployment config"
          )
        withAuthorityFixtureServerForConfig configPath $ \port -> do
          let base = "http://127.0.0.1:" ++ show port
          forM_ ["/v1/authority/config/observe", "/v1/authority/config/propose-cas"] $ \path -> do
            result <- httpGetText (HttpConfig 1000000) (base ++ path)
            case result of
              Left (HttpStatus 500 reason) -> do
                reason `shouldContain` "fixture handler failed:"
                reason `shouldContain` "Failed to decode Tier-0"
                reason `shouldNotContain` "user error ("
              other -> expectationFailure ("expected fixture refusal, received " ++ show other)
          ready <- httpGetText (HttpConfig 1000000) (base ++ "/readyz")
          ready `shouldBe` Right "{}"

  describe "native Haskell config CLI" $ do
    it "reports cluster resources from the authored configuration" $
      withSystemTempDirectory "prodbox-hs-status" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        let section = Settings.capacity validConfig
            plan = Capacity.resource_plan section
            host = Capacity.host_capacity plan
            configured =
              validConfig
                { Settings.storage =
                    Settings.StorageSection {Settings.manual_pv_host_root = Text.pack ".data-status-fixture"}
                , Settings.capacity =
                    section
                      { Capacity.resource_plan =
                          plan {Capacity.host_capacity = host {Capacity.milli_cpu = 12000, Capacity.memory_mib = 24000}}
                      }
                }
        createDirectoryIfMissing True (tmpDir </> ".data-status-fixture")
        writeTier0Fixture tmpDir (tier0FixtureWithParameters configured)
        (exitCode, stdoutText, stderrText) <-
          runInstalledWithFakeAuthority tmpDir binary ["cluster", "status"]
        when (exitCode /= ExitSuccess) (expectationFailure (stdoutText ++ stderrText))
        stdoutText `shouldContain` "RESOURCE_HOST_AUTHORED=cpu=12000m,memory=24000Mi"
        stdoutText `shouldContain` "RESOURCE_HOST_OBSERVED="

    it "does not report default resources as authored when configuration is missing" $
      withSystemTempDirectory "prodbox-hs-status" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        environment <- fakeRke2Environment tmpDir
        (exitCode, stdoutText, _) <-
          readCreateProcessWithExitCode
            (proc binary ["cluster", "status"]) {cwd = Just tmpDir, env = Just environment}
            ""
        exitCode `shouldBe` ExitFailure 1
        stdoutText `shouldContain` "RESOURCE_PLAN=unavailable:configuration"
        stdoutText `shouldNotContain` "RESOURCE_HOST_AUTHORED="

    it "shows masked settings from a repo-root Dhall config" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)

        (exitCode, stdoutText, stderrText) <-
          runInstalledWithFakeAuthority tmpDir binary ["config", "show"]

        when (exitCode /= ExitSuccess) (expectationFailure stderrText)
        exitCode `shouldBe` ExitSuccess
        stderrText `shouldBe` ""
        stdoutText `shouldContain` "aws.access_key_id=Vault:secret/aws/lifecycle-provider#access_key_id"
        stdoutText `shouldContain` ("storage.manual_pv_host_root=" ++ (tmpDir </> ".data"))

    it "validates config without requiring any Python backend" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)

        (exitCode, stdoutText, stderrText) <-
          runInstalledWithFakeAuthority tmpDir binary ["config", "validate"]

        when (exitCode /= ExitSuccess) (expectationFailure (stdoutText ++ stderrText))
        exitCode `shouldBe` ExitSuccess
        stderrText `shouldBe` ""

    it "accepts the generated GHC RTS heap-policy arguments" $ do
      binary <- resolveBinaryPath

      (exitCode, stdoutText, stderrText) <-
        readCreateProcessWithExitCode
          (proc binary ["+RTS", "-M268435456", "-RTS", "--version"])
          ""

      exitCode `shouldBe` ExitSuccess
      stderrText `shouldBe` ""
      stdoutText `shouldContain` "0.1.0"

    it "propagates Ctrl-C from a streamed child without losing its exit observation" $
      withSystemTempDirectory "prodbox-streaming-cancellation" $ \tmpDir -> do
        integrationExecutable <- getExecutablePath
        let markerPath = tmpDir </> "streaming-child-ready"
        (_, maybeStdout, maybeStderr, processHandle) <-
          createProcess
            (proc integrationExecutable ["--fixture-streaming-cancellation", markerPath])
              { cwd = Just tmpDir
              , create_group = True
              , std_out = CreatePipe
              , std_err = CreatePipe
              }
        waitForStreamingCancellationMarker markerPath processHandle
        interruptProcessGroupOf processHandle
        exitCode <- waitForProcess processHandle
        stdoutText <- maybe (pure "") (fmap BS8.unpack . BS8.hGetContents) maybeStdout
        stderrText <- maybe (pure "") (fmap BS8.unpack . BS8.hGetContents) maybeStderr

        exitCode `shouldBe` ExitFailure (-2)
        stdoutText `shouldBe` ""
        stderrText `shouldBe` ""

    it "fails fast with setup guidance when the repo Dhall config is missing" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir

        (exitCode, _, stderrText) <-
          readCreateProcessWithExitCode
            (proc binary ["config", "validate"]) {cwd = Just tmpDir}
            ""

        exitCode `shouldBe` ExitFailure 1
        stderrText `shouldContain` "Missing required repository config"
        stderrText `shouldContain` "./.build/prodbox config setup"

    it "Sprint 1.95: fitted and portable generation remain recognizable unauthored templates" $
      forM_ [[], ["--portable"]] $ \options ->
        withSystemTempDirectory "prodbox-hs-config-generate" $ \tmpDir -> do
          binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
          environment <-
            generationHostEnvironment
              "milli_cpu=8000,memory_mib=15930,ephemeral_storage_mib=100000,durable_storage_mib=180000"

          (exitCode, stdoutText, stderrText) <-
            readCreateProcessWithExitCode
              (proc binary (["config", "generate"] ++ options)) {cwd = Just tmpDir, env = Just environment}
              ""

          exitCode `shouldBe` ExitSuccess
          stderrText `shouldBe` ""
          stdoutText `shouldContain` "Generated a non-secret Tier-0 prodbox.dhall"
          generated <- readFile (tmpDir </> "prodbox.dhall")
          generated `shouldContain` "demo_fqdn = \"\""
          generated `shouldContain` "machine_id = \"\""
          generated `shouldContain` "cluster_id = \"\""
          generated `shouldContain` "vault_address = \"\""
          generated `shouldContain` "minio_endpoint = \"\""
          generated `shouldNotContain` "server ="
          generated `shouldNotContain` "minio_bucket"
          Tier0.isCanonicalUnauthoredProjectConfigDhall (Text.pack generated) `shouldReturn` True
          Tier0.decodeProjectConfigDhall (tmpDir </> "prodbox.dhall") >>= (`shouldSatisfy` isLeft)

    it "Sprint 1.95: fitted generation reaches the harness missing-fixture refusal" $
      withSystemTempDirectory "prodbox-hs-fitted-harness" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        generationEnvironment <-
          generationHostEnvironment
            "milli_cpu=8000,memory_mib=15930,ephemeral_storage_mib=100000,durable_storage_mib=180000"
        (generationExit, _, generationError) <-
          readCreateProcessWithExitCode
            (proc binary ["config", "generate"]) {cwd = Just tmpDir, env = Just generationEnvironment}
            ""
        generationExit `shouldBe` ExitSuccess
        generationError `shouldBe` ""
        environment <- fakeAwsHarnessEnvironment tmpDir binary
        (harnessExit, _, harnessError) <-
          readCreateProcessWithExitCode
            (proc binary ["test", "integration", "cascade-qualification"])
              { cwd = Just tmpDir
              , env = Just environment
              }
            ""
        harnessExit `shouldBe` ExitFailure 1
        harnessError `shouldContain` "harness config regeneration requires test-secrets.dhall (absent)."
        harnessError `shouldNotContain` "machine_id"

    it
      "host fitting refuses a CPU deficit before writing config"
      $ withSystemTempDirectory "prodbox-platform-sizing-refusal"
      $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \built -> installOperatorBinaryInDir built tmpDir
        writeRepoMarkers tmpDir
        environment <-
          generationHostEnvironment
            "milli_cpu=7094,memory_mib=15872,ephemeral_storage_mib=100000,durable_storage_mib=180000"
        (exitCode, _, stderrText) <-
          readCreateProcessWithExitCode
            (proc binary ["config", "generate"]) {cwd = Just tmpDir, env = Just environment}
            ""
        exitCode `shouldBe` ExitFailure 1
        stderrText `shouldContain` "below the plan's required 7095"
        doesFileExist (tmpDir </> "prodbox.dhall") `shouldReturn` False

    it "runs native host info directly from the built Haskell frontend" $ do
      repoRoot <- getCurrentDirectory
      binary <- resolveBinaryPath

      (exitCode, stdoutText, stderrText) <-
        readCreateProcessWithExitCode
          (proc binary ["host", "info"]) {cwd = Just repoRoot}
          ""

      exitCode `shouldBe` ExitSuccess
      stderrText `shouldBe` ""
      stdoutText `shouldContain` "Linux"

    it "proves semantic SES readiness through the built read-only prerequisite frontend" $
      withSystemTempDirectory "prodbox-hs-ses-ready" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfigForNuke)
        seedFakeVaultAwsCredentials
          tmpDir
          lifecycleProviderVaultPath
          "AKIASESREADY"
          "ses-ready-secret"
          Nothing
          (fixtureAwsRegion FixtureUsEast1)
        envVars <- fakeSesReadinessEnvironment tmpDir "ready"

        (exitCode, stdoutText, stderrText) <-
          runInstalledWithFakeAuthorityEnvironment
            tmpDir
            binary
            ["host", "check-ses-readiness"]
            envVars

        (exitCode, stderrText) `shouldBe` (ExitSuccess, "")
        stdoutText `shouldContain` "Retained SES semantic readiness: Ready"
        commands <- readFile (tmpDir </> "fake-ses-readiness-aws.txt")
        commands `shouldBe` "--version\n"
        commands `shouldNotContain` "create-"
        commands `shouldNotContain` "update-"
        commands `shouldNotContain` "put-"
        commands `shouldNotContain` "delete-"

    it "reports an exit-zero semantic SES failure with the registry remedy through the built frontend" $
      withSystemTempDirectory "prodbox-hs-ses-failed" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfigForNuke)
        seedFakeVaultAwsCredentials
          tmpDir
          lifecycleProviderVaultPath
          "AKIASESFAILED"
          "ses-failed-secret"
          Nothing
          (fixtureAwsRegion FixtureUsEast1)
        envVars <- fakeSesReadinessEnvironment tmpDir "identity-failed"

        (exitCode, stdoutText, stderrText) <-
          runInstalledWithFakeAuthorityEnvironment
            tmpDir
            binary
            ["host", "check-ses-readiness"]
            envVars

        exitCode `shouldBe` ExitFailure 1
        stdoutText `shouldBe` ""
        stderrText `shouldContain` "ses_sending_identity_verified"
        stderrText
          `shouldContain` "AWS credential check failed through the authenticated Lifecycle Authority/Provider Worker"
        stderrText `shouldContain` "VerifiedForSendingStatus=False"
        stderrText `shouldContain` "Remedy:"
        stderrText `shouldContain` "prodbox aws setup"
        stderrText `shouldNotContain` "aws stack aws-ses reconcile"
        stderrText `shouldNotContain` "pulumi up"
        stderrText `shouldNotContain` "manually provision"
        commands <- readFile (tmpDir </> "fake-ses-readiness-aws.txt")
        commands `shouldNotContain` "create-"
        commands `shouldNotContain` "update-"
        commands `shouldNotContain` "put-"
        commands `shouldNotContain` "delete-"

    -- Sprint 1.91: `aws policy` now reads the configured `ses.capture_bucket`,
    -- so it runs against an authored Tier-0 fixture rather than in a bare
    -- directory. The printed grant is the copy an operator pastes into IAM, and
    -- the two capture ARNs in it used to be compiled.
    it "renders native aws policy JSON directly from the built Haskell frontend" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfigForNuke)

        (exitCode, stdoutText, stderrText) <-
          readCreateProcessWithExitCode
            (proc binary ["aws", "policy", "--tier", "full"]) {cwd = Just tmpDir}
            ""

        exitCode `shouldBe` ExitSuccess
        stderrText `shouldBe` ""
        stdoutText `shouldContain` "\"Sid\": \"Ec2TestStackLifecycle\""
        stdoutText `shouldContain` "\"Sid\": \"IamEksRoleLifecycle\""
        stdoutText `shouldContain` "\"Sid\": \"EksTestStackLifecycle\""
        stdoutText `shouldContain` "\"Sid\": \"SesCaptureBucketRead\""
        stdoutText `shouldContain` "\"Sid\": \"SesCaptureObjectRead\""
        stdoutText `shouldContain` "\"Sid\": \"SesReadOnly\""
        -- The configured bucket reaches the printed grant; the compiled one is gone.
        stdoutText `shouldContain` "arn:aws:s3:::prodbox-test-ses-capture"
        stdoutText `shouldContain` "arn:aws:s3:::prodbox-test-ses-capture/*"
        stdoutText `shouldNotContain` "arn:aws:s3:::prodbox-ses-capture"

    it "refuses to print an AWS policy naming a capture bucket nobody configured" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)

        (exitCode, stdoutText, stderrText) <-
          readCreateProcessWithExitCode
            (proc binary ["aws", "policy", "--tier", "full"]) {cwd = Just tmpDir}
            ""

        exitCode `shouldBe` ExitFailure 1
        stdoutText `shouldBe` ""
        stderrText `shouldContain` "ses.capture_bucket must be configured"

    it "runs native gateway config-gen through the built frontend" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)
        let outputPath = tmpDir </> "gateway.dhall"

        (exitCode, stdoutText, stderrText) <-
          runInstalledWithFakeAuthority
            tmpDir
            binary
            ["gateway", "config-gen", outputPath, "--node-id", "node-a"]

        exitCode `shouldBe` ExitSuccess
        stderrText `shouldBe` ""
        stdoutText `shouldBe` ""
        rendered <- readFile outputPath
        rendered `shouldContain` "node_id = \"node-a\""
        rendered `shouldContain` "fqdn = \"test.example.test\""
        rendered `shouldContain` "zone_id = \"Z1234567890ABC\""

    it "runs native gateway status against a loopback HTTP server through the native HTTP client" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir ->
        withFakeVaultServer $ \vaultPort ->
          withGatewayStateServer gatewayStateResponseJson $ \port requestRef -> do
            binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
            writeRepoMarkers tmpDir
            let configPath = tmpDir </> "gateway.dhall"
                tokenPath = tmpDir </> "vault-token.jwt"
            writeFakeVaultToken tokenPath
            writeFile configPath (gatewayStatusConfig vaultPort tokenPath)
            writeFile (tmpDir </> "orders.dhall") (gatewayOrdersAt port)

            (exitCode, stdoutText, stderrText) <-
              readCreateProcessWithExitCode
                (proc binary ["gateway", "status", "--config", configPath]) {cwd = Just tmpDir}
                ""

            exitCode `shouldBe` ExitSuccess
            stderrText `shouldBe` ""
            stdoutText `shouldContain` "Gateway status"
            stdoutText `shouldContain` "DNS_WRITE_GATE=test.example.test@Z123 ttl=60"
            stdoutText `shouldContain` "HEARTBEAT_NODE_B=1.5"
            requestLine <- takeMVar requestRef
            requestLine `shouldContain` "GET /v1/state"

    forM_
      [ ("captured response", "CapturedResponse", "harness", ExitSuccess, ["init:1", "unseal:1"])
      ,
        ( "missing response"
        , "MissingResponse"
        , "harness"
        , ExitSuccess
        , ["init:1", "reset:1", "init:2", "unseal:2"]
        )
      , ("lost reset reply", "ResetLostReply", "harness", ExitSuccess, ["reset:1", "init:2", "unseal:2"])
      , ("healthy sealed custody", "AlreadyHealthy", "harness", ExitSuccess, ["unseal:1"])
      ,
        ( "terminal reset observed after restart"
        , "AlreadyReset"
        , "harness"
        , ExitSuccess
        , ["init:2", "unseal:2"]
        )
      ,
        ( "pending reset from a fresh harness"
        , "ResetGenerationGap"
        , "harness"
        , ExitSuccess
        , ["reset:1", "init:2", "unseal:2"]
        )
      ,
        ( "pending reset from a fresh confirmed client"
        , "ResetGenerationGap"
        , "confirmed-reset"
        , ExitSuccess
        , ["reset:1"]
        )
      , ("operator gate during pending reset", "ResetGenerationGap", "operator", ExitFailure 1, [])
      , ("missing pending action", "ResetGenerationGapMissingAction", "harness", ExitFailure 1, [])
      , ("refused reset", "ResetRefused", "harness", ExitFailure 1, ["reset:1"])
      , ("foreign reset lineage", "ResetForeignLineage", "harness", ExitFailure 1, ["reset:1"])
      , ("unobservable reset closing", "ResetUnobservable", "harness", ExitFailure 1, ["reset:1"])
      , ("unresolved continuation", "ResumeUnresolved", "harness", ExitFailure 1, ["init:1"])
      , ("foreign continuation generation", "ResumeForeignGeneration", "harness", ExitFailure 1, ["init:1"])
      ,
        ( "ordinary operator missing-response refusal"
        , "MissingResponse"
        , "operator"
        , ExitFailure 1
        , ["init:1"]
        )
      , ("ordinary operator repair gate", "ResetLostReply", "operator", ExitFailure 1, [])
      ]
      $ \(label, profile, policy, expectedExit, expectedEvents) ->
        it ("HARNESS-RETAINED-INIT-RECOVERY-2026-10-22 composes " ++ label) $
          withSystemTempDirectory "prodbox-harness-init-recovery" $ \tmpDir -> do
            _ <- resolveBinaryPath >>= \binary -> installOperatorBinaryInDir binary tmpDir
            writeRepoMarkers tmpDir
            writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)
            writePrivateTestSecrets tmpDir testSecretsDhall
            fixtureExecutable <- getExecutablePath
            let statePath = tmpDir </> "recovery-state"
            writeFile (statePath ++ ".events") ""
            (exitCode, stdoutText, stderrText) <-
              runInstalledWithFakeAuthorityEnvironment
                tmpDir
                fixtureExecutable
                ["--fixture-vault-bootstrap", policy, tmpDir]
                [ ("PRODBOX_TEST_BROKER_RECOVERY_MODE", profile)
                , ("PRODBOX_TEST_BROKER_RECOVERY_STATE", statePath)
                ]
            when (exitCode /= expectedExit) (expectationFailure (stdoutText ++ stderrText))
            exitCode `shouldBe` expectedExit
            events <- lines <$> readFile (statePath ++ ".events")
            events `shouldBe` expectedEvents

    forM_
      [ ("captured response", "CapturedResponse", ExitSuccess, ["init:1", "unseal:1"], True)
      ,
        ( "missing response"
        , "MissingResponse"
        , ExitSuccess
        , ["init:1", "reset:1", "init:2", "unseal:2"]
        , True
        )
      , ("healthy sealed custody", "AlreadyHealthy", ExitSuccess, ["unseal:1"], True)
      , ("terminal reset", "AlreadyReset", ExitSuccess, ["init:2", "unseal:2"], True)
      , ("pending reset", "ResetGenerationGap", ExitSuccess, ["reset:1", "init:2", "unseal:2"], True)
      , ("unresolved continuation", "ResumeUnresolved", ExitFailure 1, ["init:1"], True)
      , ("unavailable startup admission", "CapturedResponse", ExitFailure 1, [], False)
      ]
      $ \(label, profile, expectedExit, expectedEvents, admitted) ->
        it ("BROKER-HARNESS-COLD-START-FORWARD-REFUSED-2026-10-23 admits " ++ label) $
          withSystemTempDirectory "prodbox-cold-broker-startup" $ \tmpDir -> do
            _ <- resolveBinaryPath >>= \binary -> installOperatorBinaryInDir binary tmpDir
            writeRepoMarkers tmpDir
            writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)
            writePrivateTestSecrets tmpDir testSecretsDhall
            fixtureExecutable <- getExecutablePath
            let statePath = tmpDir </> "recovery-state"
                startup = tmpDir </> "startup-state"
            writeFile (statePath ++ ".events") ""
            (exitCode, stdoutText, stderrText) <-
              withColdBrokerBackend startup $
                runInstalledWithFakeAuthorityEnvironment
                  tmpDir
                  fixtureExecutable
                  ["--fixture-vault-bootstrap", "harness", tmpDir]
                  [ ("PRODBOX_TEST_BROKER_RECOVERY_MODE", profile)
                  , ("PRODBOX_TEST_BROKER_RECOVERY_STATE", statePath)
                  , ("PRODBOX_TEST_BROKER_COLD_START", "1")
                  , ("PRODBOX_TEST_BROKER_STARTUP_STATE", startup)
                  , ("PRODBOX_TEST_BROKER_STARTUP_REFUSED", if admitted then "0" else "1")
                  ]
            when (exitCode /= expectedExit) (expectationFailure (stdoutText ++ stderrText))
            exitCode `shouldBe` expectedExit
            events <- lines <$> readFile (statePath ++ ".events")
            events `shouldBe` expectedEvents
            doesFileExist (startup ++ ".ready") `shouldReturn` admitted
            hasForwards <- doesFileExist (startup ++ ".forwards")
            forwards <- if hasForwards then lines <$> readFile (startup ++ ".forwards") else pure []
            if admitted
              then do
                forwards `shouldSatisfy` (not . null)
                forwards `shouldSatisfy` all (== "backend-ready")
              else forwards `shouldBe` []
            unless admitted $ do
              calls <- readFile (tmpDir </> "fake-rke2-state" </> "kubectl.txt")
              calls `shouldNotContain` "|create|token|"

    it "vault status uses the caller-bound Bootstrap Broker transport" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)

        (exitCode, stdoutText, stderrText) <-
          runInstalledWithFakeAuthority tmpDir binary ["vault", "status"]

        exitCode `shouldBe` ExitSuccess
        stderrText `shouldBe` ""
        stdoutText
          `shouldContain` "Vault status: {\"initialization_ambiguous\":false,\"initialized\":true,\"sealed\":false,\"storage_generation\":\"1\"}"

    it "Bootstrap Broker Vault decode failures do not fall back to direct host Vault" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)
        baseEnv <- getEnvironment

        (exitCode, stdoutText, stderrText) <-
          runInstalledWithFakeAuthorityEnvironment
            tmpDir
            binary
            ["vault", "status"]
            (("PRODBOX_TEST_BROKER_STATUS_MODE", "malformed") : baseEnv)

        exitCode `shouldBe` ExitFailure 1
        stderrText `shouldBe` ""
        stdoutText `shouldContain` "Vault status failed: HTTP response decode error"

    it "Sprint 4.50: removed gateway federation endpoints stay absent" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir ->
        withFakeVaultServer $ \vaultPort -> do
          binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
          writeRepoMarkers tmpDir
          writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)
          (restPort, socketPort) <- allocateTwoLoopbackTcpPorts
          let tokenPath = tmpDir </> "gateway.jwt"
              ordersPath = tmpDir </> "orders.dhall"
              configPath = tmpDir </> "gateway.dhall"
              stdoutPath = tmpDir </> "gateway.stdout"
              stderrPath = tmpDir </> "gateway.stderr"
              certPath = tmpDir </> "node-a.crt"
              keyPath = tmpDir </> "node-a.key"
              caPath = tmpDir </> "ca.crt"
          writeFakeVaultToken tokenPath
          writeFile certPath "fake-cert"
          writeFile keyPath "fake-key"
          writeFile caPath "fake-ca"
          writeFile ordersPath (gatewayOrdersAtPorts restPort socketPort)
          writeFile configPath (gatewayStartConfig vaultPort tokenPath ordersPath certPath keyPath caPath)

          (_, _, _, processHandle) <-
            createProcess
              ( proc
                  "bash"
                  [ "-c"
                  , "exec \"$1\" gateway start --config \"$2\" >\"$3\" 2>\"$4\""
                  , "bash"
                  , binary
                  , configPath
                  , stdoutPath
                  , stderrPath
                  ]
              )
                { cwd = Just tmpDir
                }
          let stopGateway = do
                terminateProcess processHandle
                void (waitForProcess processHandle)

          flip finally stopGateway $ do
            -- Wait for the real listener, then prove neither fixed nor
            -- variable-suffix federation transport survived the cutover.
            waitForGatewayHealthyProcess restPort processHandle stdoutPath stderrPath
            childrenResult <-
              httpGetText
                (HttpConfig 1000000)
                ("http://127.0.0.1:" ++ show restPort ++ "/v1/federation/children")
            childrenResult `shouldBe` Left (HttpStatus 404 "not found\n")
            bootstrapResult <-
              httpGetText
                (HttpConfig 1000000)
                ("http://127.0.0.1:" ++ show restPort ++ "/v1/federation/children/child-a/bootstrap")
            bootstrapResult `shouldBe` Left (HttpStatus 404 "not found\n")

    it "fails fast when gateway start is missing required trust material" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir ->
        withFakeVaultServer $ \vaultPort -> do
          binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
          writeRepoMarkers tmpDir
          writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)
          let ordersPath = tmpDir </> "orders.dhall"
              configPath = tmpDir </> "gateway-start.dhall"
              tokenPath = tmpDir </> "vault-token.jwt"
          writeFile ordersPath gatewayOrders
          writeFakeVaultToken tokenPath
          writeFile
            configPath
            ( gatewayStartConfig
                vaultPort
                tokenPath
                ordersPath
                (tmpDir </> "missing.crt")
                (tmpDir </> "missing.key")
                (tmpDir </> "missing-ca.crt")
            )

          (exitCode, stdoutText, stderrText) <-
            readCreateProcessWithExitCode
              (proc binary ["gateway", "start", "--config", configPath]) {cwd = Just tmpDir}
              ""

          exitCode `shouldBe` ExitFailure 1
          stdoutText `shouldBe` ""
          stderrText `shouldContain` "Failed to validate gateway startup inputs"
          stderrText `shouldContain` "cert_file does not exist"
          stderrText `shouldContain` "key_file does not exist"
          stderrText `shouldContain` "ca_file does not exist"

    it "Sprint 5.33: gateway-partition is no longer an integration node" $ do
      -- Standard C. This case asserted the node's integration output. The
      -- composition is a legitimate in-process property test over the real
      -- GatewayState folds, but it engaged no harness, emitted its verdict
      -- lines as literals, and was cited as numbered `Validation` evidence in
      -- eight `Done` Phase-2 sprints for peer, restart, and partition
      -- properties nothing exercised. It moved to the unit suite; the CLI must
      -- no longer advertise or accept it.
      repoRoot <- getCurrentDirectory
      binary <- resolveBinaryPath

      (exitCode, _, _) <-
        readCreateProcessWithExitCode
          (proc binary ["test", "integration", "gateway-partition"]) {cwd = Just repoRoot}
          ""
      exitCode `shouldNotBe` ExitSuccess

      (helpExit, helpStdout, _) <-
        readCreateProcessWithExitCode
          (proc binary ["test", "integration", "--help"]) {cwd = Just repoRoot}
          ""
      helpExit `shouldBe` ExitSuccess
      helpStdout `shouldNotContain` "gateway-partition"

    it "runs the frozen control-plane counterexample through an installed binary" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        repoRoot <- getCurrentDirectory
        binary <- resolveBinaryPath >>= \path -> installOperatorBinaryInDir path tmpDir

        (exitCode, stdoutText, stderrText) <-
          readCreateProcessWithExitCode
            (proc binary ["test", "integration", "control-plane-counterexample"])
              { cwd = Just repoRoot
              }
            ""

        exitCode `shouldBe` ExitSuccess
        stderrText
          `shouldContain` "[validation=control-plane-counterexample substrate=home-local] body exit=ExitSuccess"
        stdoutText `shouldContain` "COUNTEREXAMPLE=LCPC-2026-07-11"
        stdoutText `shouldContain` "SUPERSEDED_FAILURES=5"
        stdoutText `shouldContain` "REPLACEMENT_CLOSURES=5"
        stdoutText `shouldContain` "NORMALIZED_ENVELOPE_EQUAL=true"
        stdoutText `shouldContain` "INVITE_FAULT_MATRIX=23"
        stdoutText `shouldContain` "INVITE_ASSERTIONS=8"
        stdoutText `shouldContain` "DEPLOYMENT_QUALIFICATION=QualificationPendingLiveEvidence"

    it "runs the exhaustive frozen teardown-recovery oracle without consuming forged residue input" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        repoRoot <- getCurrentDirectory
        binary <- resolveBinaryPath >>= \path -> installOperatorBinaryInDir path tmpDir

        (exitCode, stdoutText, stderrText) <-
          readCreateProcessWithExitCode
            (proc binary ["test", "integration", "teardown-recovery"])
              { cwd = Just repoRoot
              }
            ""

        exitCode `shouldBe` ExitSuccess
        stderrText
          `shouldContain` "[validation=teardown-recovery substrate=home-local] body exit=ExitSuccess"
        stdoutText `shouldContain` "TEARDOWN_COUNTEREXAMPLE=TEARDOWN-2026-08-15"
        stdoutText `shouldContain` "TYPED_FAKE_BOUNDARIES=7"
        stdoutText `shouldContain` "TYPED_FAKE_REQUESTS=11"
        stdoutText `shouldContain` "EXTERNAL_STATE_ROWS=25"
        stdoutText `shouldContain` "DURABLE_TRANSITIONS=8"
        stdoutText `shouldContain` "INTERRUPTION_SCHEDULE_ROWS=80"
        stdoutText `shouldContain` "CAUSAL_PROFILE=teardown-causal-v1"
        stdoutText `shouldContain` "CAUSAL_INDEPENDENTLY_JUSTIFIED=false"
        stdoutText `shouldContain` "PRODUCTION_PROFILE=teardown-production-v1"
        stdoutText `shouldContain` "PRODUCTION_INDEPENDENTLY_JUSTIFIED=true"
        stdoutText `shouldContain` "RETAINED_AUDIT_ARNS=1"
        stdoutText
          `shouldContain` "RETAINED_AUDIT_ARN=arn:aws:s3:::prodbox-retained-state-fixture"
        stdoutText `shouldContain` "EXACT_STACK_UNOBSERVABLES=3"
        mapM_
          ( \stackKey ->
              stdoutText
                `shouldContain` ( "EXACT_STACK="
                                    ++ stackKey
                                    ++ " DISPOSITION=Unobservable FAILURE=exact-stack-authority-not-serving"
                                )
          )
          ["aws-eks", "aws-eks-subzone", "aws-test"]
        stdoutText `shouldContain` "CHECKPOINT_UNOBSERVABLES=3"
        stdoutText `shouldContain` "DRAIN_SELECTION=NoDrainSelected"
        stdoutText `shouldContain` "DESTROY_SELECTION=NoDestroySelected"
        stdoutText
          `shouldContain` "AUTHORITY_CALLER=local-cascade-caller DISPOSITION=Unobservable FAILURE=lifecycle-authority-caller-unobservable"
        stdoutText `shouldContain` "ORIGINAL_FAILURES=1"
        stdoutText `shouldContain` "CLEANUP_FAILURES=1"
        stdoutText
          `shouldContain` "CLEANUP_BOUNDARY=lifecycle-authority DISPOSITION=Unobservable FAILURE=lifecycle-authority-unobservable"
        stdoutText `shouldContain` "CASCADE_RESULT=CascadeIncomplete"

    it "fails against the committed teardown-recovery mutation fixture" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        repoRoot <- getCurrentDirectory
        binary <- resolveBinaryPath >>= \path -> installOperatorBinaryInDir path tmpDir
        parentEnv <- getEnvironment
        let mutatedEnvironment =
              ("PRODBOX_TEST_TEARDOWN_COUNTEREXAMPLE_FIXTURE", "mutated")
                : filter
                  ((/= "PRODBOX_TEST_TEARDOWN_COUNTEREXAMPLE_FIXTURE") . fst)
                  parentEnv

        (exitCode, stdoutText, stderrText) <-
          readCreateProcessWithExitCode
            (proc binary ["test", "integration", "teardown-recovery"])
              { cwd = Just repoRoot
              , env = Just mutatedEnvironment
              }
            ""

        exitCode `shouldBe` ExitFailure 1
        stdoutText `shouldContain` "Validation: teardown-recovery (substrate=home-local)"
        stdoutText `shouldNotContain` "RETAINED_AUDIT_ARNS="
        stderrText
          `shouldContain` "TeardownExternalStateDispositionMismatch ExternalAwsUnobservable"

    it "runs the frozen create-interrupted oracle and closes it in both directions" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        repoRoot <- getCurrentDirectory
        binary <- resolveBinaryPath >>= \path -> installOperatorBinaryInDir path tmpDir

        (exitCode, stdoutText, stderrText) <-
          readCreateProcessWithExitCode
            (proc binary ["test", "integration", "create-interrupted"])
              { cwd = Just repoRoot
              }
            ""

        exitCode `shouldBe` ExitSuccess
        stderrText
          `shouldContain` "[validation=create-interrupted substrate=home-local] body exit=ExitSuccess"
        stdoutText `shouldContain` "CREATE_COUNTEREXAMPLE=CREATE-INTERRUPTED-2026-09-08"
        stdoutText `shouldContain` "DECLARED_COORDINATES=5"
        stdoutText `shouldContain` "OBSERVED_IDENTITIES=5"
        stdoutText `shouldContain` "PROVIDER_TAG_ROWS=2"
        stdoutText `shouldContain` "EXTERNAL_STATE_ROWS=13"
        stdoutText `shouldContain` "INTERRUPTION_SCHEDULE_ROWS=100"
        stdoutText `shouldContain` "SUPERSEDED_RUNS_EFFECT=true"
        stdoutText `shouldContain` "SUPERSEDED_ORPHAN_POINTS=5"
        stdoutText
          `shouldContain` "SUPERSEDED_ORPHAN_AT=sigkill after execute-admitted-create"
        stdoutText `shouldContain` "REPLACEMENT_RUNS_EFFECT=true"
        stdoutText `shouldContain` "REPLACEMENT_ORPHAN_POINTS=0"
        stdoutText `shouldContain` "CREATE_COUNTEREXAMPLE_CLOSED=true"

    it "fails against the committed create-interrupted mutation fixture" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        repoRoot <- getCurrentDirectory
        binary <- resolveBinaryPath >>= \path -> installOperatorBinaryInDir path tmpDir
        parentEnv <- getEnvironment
        let mutatedEnvironment =
              ("PRODBOX_TEST_CREATE_COUNTEREXAMPLE_FIXTURE", "mutated")
                : filter
                  ((/= "PRODBOX_TEST_CREATE_COUNTEREXAMPLE_FIXTURE") . fst)
                  parentEnv

        (exitCode, stdoutText, stderrText) <-
          readCreateProcessWithExitCode
            (proc binary ["test", "integration", "create-interrupted"])
              { cwd = Just repoRoot
              , env = Just mutatedEnvironment
              }
            ""

        exitCode `shouldBe` ExitFailure 1
        stdoutText `shouldContain` "Validation: create-interrupted (substrate=home-local)"
        stdoutText `shouldNotContain` "CREATE_COUNTEREXAMPLE_CLOSED="
        stderrText
          `shouldContain` "CreateInterruptionDispositionMismatch ReplacementCreate ExecuteAdmittedCreate"

    it "exposes the exact create-interrupted integration command in help" $ do
      binary <- resolveBinaryPath
      (exitCode, stdoutText, stderrText) <-
        readCreateProcessWithExitCode
          (proc binary ["test", "integration", "create-interrupted", "--help"])
          ""
      exitCode `shouldBe` ExitSuccess
      stderrText `shouldBe` ""
      stdoutText
        `shouldContain` "Run the frozen interrupted registered-stack create counterexample"

    it "exposes the exact teardown-recovery integration command in help" $ do
      binary <- resolveBinaryPath
      (exitCode, stdoutText, stderrText) <-
        readCreateProcessWithExitCode
          (proc binary ["test", "integration", "teardown-recovery", "--help"])
          ""
      exitCode `shouldBe` ExitSuccess
      stderrText `shouldBe` ""
      stdoutText
        `shouldContain` "Run the frozen exact-keyed teardown recovery counterexample"

    it "Sprint 5.32: the frozen counterexample fails against the committed mutation fixture" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        -- The acceptance criterion. Until Sprint 5.32,
        -- `simulateFrozenCounterexample` discarded its `FrozenCounterexampleTrace`
        -- and regenerated both halves from an in-module composition constant,
        -- so `complete` was True for every input and this command could not
        -- fail. A reproducer that passes both fixtures is not a reproducer.
        repoRoot <- getCurrentDirectory
        binary <- resolveBinaryPath >>= \path -> installOperatorBinaryInDir path tmpDir
        parentEnv <- getEnvironment

        (mutatedExit, _, mutatedStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["test", "integration", "control-plane-counterexample"])
              { cwd = Just repoRoot
              , env =
                  Just (("PRODBOX_TEST_FROZEN_COUNTEREXAMPLE_FIXTURE", "mutated") : parentEnv)
              }
            ""
        mutatedExit `shouldBe` ExitFailure 1
        mutatedStderr `shouldContain` "GatewayDeadlineUnderThrottle"
        mutatedStderr `shouldContain` "not recorded as failing on"

        -- An unrecognised selector refuses rather than falling back to the
        -- canonical (passing) fixture.
        (typoExit, _, typoStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["test", "integration", "control-plane-counterexample"])
              { cwd = Just repoRoot
              , env =
                  Just (("PRODBOX_TEST_FROZEN_COUNTEREXAMPLE_FIXTURE", "canonicaal") : parentEnv)
              }
            ""
        typoExit `shouldBe` ExitFailure 1
        typoStderr `shouldContain` "is not a known frozen fixture"

    it "exposes the certificate-scope serving validation through an installed binary" $ do
      binary <- resolveBinaryPath
      (exitCode, stdoutText, stderrText) <-
        readCreateProcessWithExitCode
          (proc binary ["test", "integration", "certificate-scope", "--help"])
          ""
      exitCode `shouldBe` ExitSuccess
      stderrText `shouldBe` ""
      stdoutText `shouldContain` "Verify live TLS serving and the exact presented SAN scope"

    it "exposes the clean-room handoff validation through an installed binary" $ do
      binary <- resolveBinaryPath
      (exitCode, stdoutText, stderrText) <-
        readCreateProcessWithExitCode
          (proc binary ["test", "integration", "clean-room-handoff", "--help"])
          ""
      exitCode `shouldBe` ExitSuccess
      stderrText `shouldBe` ""
      stdoutText `shouldContain` "Verify clean-room migration, rollback refusal, and legacy absence"

    it "exposes the destructive cascade qualification through an installed binary" $ do
      binary <- resolveBinaryPath
      (exitCode, stdoutText, stderrText) <-
        readCreateProcessWithExitCode
          (proc binary ["test", "integration", "cascade-qualification", "--help"])
          ""
      exitCode `shouldBe` ExitSuccess
      stderrText `shouldBe` ""
      stdoutText
        `shouldContain` "Run one named destructive recover-to-clean cascade qualification cycle"

    it "runs native resource-guardrails validation through fake Kubernetes resource JSON" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfig)
        createDirectoryIfMissing True (tmpDir </> ".build")
        writeTier0Fixture
          (tmpDir </> ".build")
          (tier0FixtureWithParameters validConfig)
        envVars <-
          (("PRODBOX_TEST_HOST_VAULT_TOKEN", "fake-root-token") :) <$> fakeRke2Environment tmpDir
        writeExecutable (tmpDir </> "bin" </> "cabal") (fakeCabalListBinScript binary)

        (exitCode, stdoutText, stderrText) <-
          withFakeGatewayReadinessEnvironment tmpDir envVars $ \gatewayEnvironment ->
            readCreateProcessWithExitCode
              (proc binary ["test", "integration", "resource-guardrails"])
                { cwd = Just tmpDir
                , env = Just gatewayEnvironment
                }
              ""

        let output =
              unlines
                [ "resource-guardrails exit: " <> show exitCode
                , "resource-guardrails stdout:"
                , stdoutText
                , "resource-guardrails stderr:"
                , stderrText
                ]
        when (exitCode /= ExitSuccess) (expectationFailure output)
        exitCode `shouldBe` ExitSuccess
        stderrText
          `shouldContain` "[validation=resource-guardrails substrate=home-local] entering body"
        stderrText
          `shouldContain` "[validation=resource-guardrails substrate=home-local] body exit=ExitSuccess"
        stdoutText `shouldContain` "Validation: resource-guardrails"
        stdoutText `shouldContain` "RESOURCE_GUARDRAILS_VALIDATION"
        stdoutText `shouldContain` "PODS_CHECKED=5"
        stdoutText `shouldContain` "CONTAINERS_CHECKED=5"
        stdoutText `shouldContain` "QUOTA_NAMESPACES=keycloak,vscode,api,websocket,gateway"
        stdoutText `shouldContain` "LIMIT_RANGE_NAMESPACES=keycloak,vscode,api,websocket,gateway"
        stdoutText `shouldContain` "BESTEFFORT_PODS=0"
        stdoutText `shouldContain` "UNCAPPED_CONTAINERS=0"

    it "runs gateway-pods with existing restart counters through the bounded stability oracle" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfig)
        createDirectoryIfMissing True (tmpDir </> ".build")
        writeTier0Fixture
          (tmpDir </> ".build")
          (tier0FixtureWithParameters validConfig)
        envVars <-
          (("PRODBOX_TEST_HOST_VAULT_TOKEN", "fake-root-token") :) <$> fakeRke2Environment tmpDir
        writeExecutable (tmpDir </> "bin" </> "cabal") (fakeCabalListBinScript binary)

        (exitCode, stdoutText, stderrText) <-
          withFakeGatewayReadinessEnvironment tmpDir envVars $ \gatewayEnvironment ->
            readCreateProcessWithExitCode
              (proc binary ["test", "integration", "gateway-pods"])
                { cwd = Just tmpDir
                , env = Just gatewayEnvironment
                }
              ""

        let output =
              unlines
                [ "gateway-pods stdout:"
                , stdoutText
                , "gateway-pods stderr:"
                , stderrText
                ]
        when (exitCode /= ExitSuccess) (expectationFailure output)
        exitCode `shouldBe` ExitSuccess
        stderrText
          `shouldContain` "[validation=gateway-pods substrate=home-local] entering body"
        stderrText
          `shouldContain` "[validation=gateway-pods substrate=home-local] body exit=ExitSuccess"
        stdoutText `shouldContain` "GATEWAY_RUNTIME_STABILITY_VALIDATION"
        stdoutText `shouldContain` "CLASSIFICATION=stable"
        stdoutText `shouldContain` "STABLE_SAMPLES=3"

    it "fails the installed gateway gate on a sampled OOM" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfig)
        createDirectoryIfMissing True (tmpDir </> ".build")
        writeTier0Fixture
          (tmpDir </> ".build")
          (tier0FixtureWithParameters validConfig)
        baseEnv <- (("PRODBOX_TEST_HOST_VAULT_TOKEN", "fake-root-token") :) <$> fakeRke2Environment tmpDir
        let envVars =
              ("PRODBOX_FAKE_GATEWAY_OOM_PODS_SAMPLE", "2")
                : baseEnv
        writeExecutable (tmpDir </> "bin" </> "cabal") (fakeCabalListBinScript binary)

        (exitCode, stdoutText, stderrText) <-
          withFakeGatewayReadinessEnvironment tmpDir envVars $ \gatewayEnvironment ->
            readCreateProcessWithExitCode
              (proc binary ["test", "integration", "gateway-pods"])
                { cwd = Just tmpDir
                , env = Just gatewayEnvironment
                }
              ""

        exitCode `shouldBe` ExitFailure 1
        stderrText `shouldContain` "Gateway runtime is unhealthy"
        stderrText `shouldContain` "oom-killed-residue"
        stderrText `shouldContain` "termination_reason=OOMKilled"
        stdoutText `shouldNotContain` "CLASSIFICATION=stable"

        gatewayPodSampleCount <-
          readFile (tmpDir </> "fake-rke2-state" </> "gateway-pods-sample.count")
        (read gatewayPodSampleCount :: Int) `shouldSatisfy` (>= 2)
        kubectlRecord <- readFile (tmpDir </> "fake-rke2-state" </> "kubectl.txt")
        kubectlRecord
          `shouldContain` "get|pods|--namespace|gateway|-o|json|--request-timeout=5s"

    it "runs native daemon-bootstrap validation and rejects legacy transport traces" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        let fakeBin = tmpDir </> "bin"
        createDirectoryIfMissing True fakeBin
        writeExecutable (fakeBin </> "cabal") (fakeCabalListBinScript binary)
        currentEnvironment <- getEnvironment
        let existingPath = maybe "" id (lookup "PATH" currentEnvironment)
            baseEnvironment =
              ("PATH", fakeBin ++ ":" ++ existingPath)
                : filter
                  ( \entry ->
                      fst entry
                        `notElem` [ "PATH"
                                  , "PRODBOX_TEST_DAEMON_BOOTSTRAP_AUDIT"
                                  ]
                  )
                  currentEnvironment
            envFor fixture =
              ("PRODBOX_TEST_DAEMON_BOOTSTRAP_AUDIT", fixture)
                : baseEnvironment
            -- The unset arm observes a live Broker, so on a host that runs the real
            -- cluster it would be answered by it and exit 0. It is given an empty
            -- home and no exported kubeconfig, so no cluster is reachable from it.
            isolatedFromHostCluster =
              ("HOME", tmpDir)
                : filter (\entry -> fst entry `notElem` ["HOME", "KUBECONFIG"]) baseEnvironment

        (passExitCode, passStdout, passStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["test", "integration", "daemon-bootstrap"])
              { cwd = Just tmpDir
              , env = Just (envFor "pass")
              }
            ""

        let passOutput =
              unlines
                [ "daemon-bootstrap pass stdout:"
                , passStdout
                , "daemon-bootstrap pass stderr:"
                , passStderr
                ]
        when (passExitCode /= ExitSuccess) (expectationFailure passOutput)
        passStdout `shouldContain` "Validation: daemon-bootstrap"
        passStdout `shouldContain` "DAEMON_BOOTSTRAP_VALIDATION"
        passStdout `shouldContain` "LEGACY_TRANSPORTS=0"
        passStdout `shouldContain` "REDACTION=ok"
        passStderr
          `shouldContain` "[validation=daemon-bootstrap substrate=home-local] entering body"
        passStderr
          `shouldContain` "[validation=daemon-bootstrap substrate=home-local] body exit=ExitSuccess"

        (legacyExitCode, legacyStdout, legacyStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["test", "integration", "daemon-bootstrap"])
              { cwd = Just tmpDir
              , env = Just (envFor "legacy-minio-port-forward")
              }
            ""

        legacyExitCode `shouldBe` ExitFailure 1
        legacyStdout `shouldContain` "Validation: daemon-bootstrap"
        legacyStderr `shouldContain` "legacy transport"
        legacyStderr `shouldContain` "port-forward service/minio"

        -- Sprint 5.33 unset-fixture exercise, and it is the acceptance
        -- criterion. With every PRODBOX_TEST_* fixture unset, this arm used to
        -- be byte-identical to the `"pass"` arm above and exited 0 having
        -- measured nothing. It must now refuse, naming what was absent,
        -- because no Bootstrap Broker daemon is serving in this fixture
        -- context.
        (unsetExitCode, _, unsetStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["test", "integration", "daemon-bootstrap"])
              { cwd = Just tmpDir
              , env = Just isolatedFromHostCluster
              }
            ""

        unsetExitCode `shouldBe` ExitFailure 1
        unsetStderr `shouldContain` "measured nothing and refuses"
        unsetStderr `shouldContain` "no Bootstrap Broker daemon answered"

        -- And the fixture arm now says it was a fixture.
        passStdout `shouldContain` "AUDIT_PROVENANCE=fixture:pass"

    it
      "runs native charts list, status, deploy, and delete through the built frontend with fake helm and kubectl"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)
        envVars <- fakeChartEnvironment tmpDir

        (listExitCode, listStdout, listStderr) <-
          runInstalledWithAuthorityEnvironment tmpDir binary ["charts", "list"] envVars

        listExitCode `shouldBe` ExitSuccess
        listStderr `shouldBe` ""
        listStdout `shouldContain` "CHART_LIST"
        listStdout `shouldContain` "NAME=vscode"

        (statusExitCode, statusStdout, statusStderr) <-
          runInstalledWithAuthorityEnvironment tmpDir binary ["charts", "status", "vscode"] envVars

        statusExitCode `shouldBe` ExitSuccess
        statusStderr `shouldBe` ""
        statusStdout `shouldContain` "CHART_STATUS"
        statusStdout `shouldContain` "NAME=vscode"
        statusStdout `shouldContain` "STORAGE_BINDING"

        (deployExitCode, deployStdout, deployStderr) <-
          runInstalledWithAuthorityEnvironment tmpDir binary ["charts", "reconcile", "vscode"] envVars

        when
          (deployExitCode /= ExitSuccess)
          (expectationFailure ("deploy STDOUT:\n" ++ deployStdout ++ "\ndeploy STDERR:\n" ++ deployStderr))
        deployExitCode `shouldBe` ExitSuccess
        deployStderr `shouldBe` ""
        deployStdout `shouldContain` "CHART_DEPLOYMENT"
        deployStdout `shouldContain` "ROOT_CHART=vscode"

        -- Sprint 5.38: the first reconcile drives the fake's explicit empty
        -- inventory through the production Helm-status classifier. Unsupported
        -- status, exit-zero empty output, or a non-canonical JSON body all stop
        -- before upgrade and fail this installed-boundary case.
        firstStatusRecord <- readFile (tmpDir </> "fake-chart-state" </> "helm-status.txt")
        firstStatusRecord
          `shouldContain` "status|keycloak-postgres|--namespace|vscode|--output|json"
        firstStatusRecord `shouldContain` "status|vscode|--namespace|vscode|--output|json"

        -- Sprint 3.19: host-side Secret pre-apply is retired; chart deploy
        -- storage manifests are still asserted by content rather than apply
        -- ordinal.
        appliedManifest <- readAppliedManifestContaining (tmpDir </> "fake-chart-state") "data-vscode-0"
        appliedManifest `shouldContain` "PersistentVolumeClaim"
        patroniManifest <-
          readAppliedManifestContaining
            (tmpDir </> "fake-chart-state")
            "prodbox-vscode-pg-instance1-hh5k-pgdata"
        patroniManifest `shouldContain` "PersistentVolume"
        patroniManifest `shouldNotContain` "PersistentVolumeClaim"
        patroniManifest
          `shouldContain` "\"name\": \"prodbox-retained-vscode-prodbox-vscode-pg-0\""
        patroniManifest
          `shouldContain` "\"name\": \"prodbox-vscode-pg-instance1-hh5k-pgdata\""

        upgradeRecord <- readFile (tmpDir </> "fake-chart-state" </> "helm-upgrade.txt")
        upgradeRecord `shouldContain` "upgrade|--install|--wait|--timeout|30m0s|keycloak"
        upgradeRecord `shouldContain` "upgrade|--install|--wait|--timeout|30m0s|vscode"

        kubectlRecord <- readFile (tmpDir </> "fake-chart-state" </> "kubectl.txt")
        kubectlRecord
          `shouldContain` "get|crd|perconapgclusters.pgv2.percona.com|--ignore-not-found|-o|name"
        -- Sprint 3.24: the one-shot operator gate tolerates absent objects while
        -- converging and opens only on the Deployment's Available=True condition.
        kubectlRecord
          `shouldContain` "get|deployment|postgres-operator|--namespace|postgres-operator|--ignore-not-found|-o|jsonpath={.status.conditions[?(@.type==\"Available\")].status}"
        kubectlRecord
          `shouldContain` "get|pvc|--namespace|vscode|--selector|postgres-operator.crunchydata.com/cluster=prodbox-vscode-pg,postgres-operator.crunchydata.com/data=postgres|-o|json"
        kubectlRecord
          `shouldContain` "get|perconapgclusters.pgv2.percona.com|prodbox-vscode-pg|-n|vscode|-o|jsonpath={.status.state}"
        kubectlRecord
          `shouldContain` "get|perconapgclusters.pgv2.percona.com|prodbox-vscode-pg|-n|vscode|-o|jsonpath={.status.postgres.ready}"

        initialChartStateFiles <- listDirectory (tmpDir </> "fake-chart-state")
        let initialApplyTargetCount =
              length
                [ path
                | path <- initialChartStateFiles
                , take 13 path == "kubectl-apply"
                ]
            -- The second reconcile models the fully-deployed steady state.
            -- Sprint 3.38 deliberately converges all three releases again;
            -- Helm's three-way merge, rather than a presence filter, owns the
            -- idempotent no-change decision.
            alreadyDeployedEnvVars =
              ( "PRODBOX_FAKE_HELM_LIST_JSON"
              , "[{\"name\":\"keycloak-postgres\",\"namespace\":\"vscode\",\"status\":\"deployed\"},"
                  ++ "{\"name\":\"keycloak\",\"namespace\":\"vscode\",\"status\":\"deployed\"},"
                  ++ "{\"name\":\"vscode\",\"namespace\":\"vscode\",\"status\":\"deployed\"}]"
              )
                : filter ((/= "PRODBOX_FAKE_HELM_LIST_JSON") . fst) envVars

        (secondDeployExitCode, secondDeployStdout, secondDeployStderr) <-
          runInstalledWithAuthorityEnvironment
            tmpDir
            binary
            ["charts", "reconcile", "vscode"]
            alreadyDeployedEnvVars

        when
          (secondDeployExitCode /= ExitSuccess)
          ( expectationFailure
              ("secondDeploy STDOUT:\n" ++ secondDeployStdout ++ "\nsecondDeploy STDERR:\n" ++ secondDeployStderr)
          )
        secondDeployExitCode `shouldBe` ExitSuccess
        secondDeployStderr `shouldBe` ""
        secondDeployStdout `shouldContain` "CHART_DEPLOYMENT"
        secondDeployStdout `shouldContain` "ROOT_CHART=vscode"

        -- Changing only the explicit inventory makes the same fake command
        -- emit canonical deployed JSON before production converges each release.
        secondStatusRecord <- readFile (tmpDir </> "fake-chart-state" </> "helm-status.txt")
        countRecordLines
          "status|keycloak-postgres|--namespace|vscode|--output|json"
          secondStatusRecord
          `shouldBe` 2
        countRecordLines
          "status|vscode|--namespace|vscode|--output|json"
          secondStatusRecord
          `shouldBe` 2

        upgradeRecordAfterSecondDeploy <- readFile (tmpDir </> "fake-chart-state" </> "helm-upgrade.txt")
        upgradeRecordAfterSecondDeploy
          `shouldContain` "upgrade|--install|--wait|--timeout|30m0s|keycloak-postgres"
        upgradeRecordAfterSecondDeploy
          `shouldContain` "upgrade|--install|--wait|--timeout|30m0s|vscode"

        chartStateFilesAfterSecondDeploy <- listDirectory (tmpDir </> "fake-chart-state")
        length
          [ path
          | path <- chartStateFilesAfterSecondDeploy
          , take 13 path == "kubectl-apply"
          ]
          `shouldBe` (initialApplyTargetCount + 5)

        (deleteExitCode, deleteStdout, deleteStderr) <-
          runInstalledWithAuthorityEnvironment
            tmpDir
            binary
            ["charts", "delete", "vscode", "--yes"]
            envVars

        when
          (deleteExitCode /= ExitSuccess)
          (expectationFailure ("delete STDOUT:\n" ++ deleteStdout ++ "\ndelete STDERR:\n" ++ deleteStderr))
        deleteExitCode `shouldBe` ExitSuccess
        deleteStderr `shouldBe` ""
        deleteStdout `shouldContain` "CHART_DELETION"
        deleteStdout `shouldContain` "HOST_STORAGE_PRESERVED=true"

        -- A present source namespace must converge the same exact-name
        -- Role/RoleBinding/API-egress capability before selected-Agent retain.
        -- The two deploys have already accounted for five applies each; delete
        -- adds only those three access objects.
        chartStateFilesAfterPresentDelete <- listDirectory (tmpDir </> "fake-chart-state")
        let applyCountAfterPresentDelete =
              length
                [ path
                | path <- chartStateFilesAfterPresentDelete
                , take 13 path == "kubectl-apply"
                ]
        applyCountAfterPresentDelete `shouldBe` (initialApplyTargetCount + 8)

        -- Interrupted cleanup can leave the exact namespace absent. Its
        -- exit-zero/empty --ignore-not-found observation authoritatively proves
        -- that no namespaced Secret or Certificate can exist, so delete emits
        -- the explicit outcome without trying to recreate access in a namespace
        -- it is about to remove.
        let absentNamespaceEnvVars =
              ("PRODBOX_FAKE_PUBLIC_EDGE_NAMESPACE_ABSENT", "true")
                : filter
                  ((/= "PRODBOX_FAKE_PUBLIC_EDGE_NAMESPACE_ABSENT") . fst)
                  envVars
        (absentDeleteExitCode, absentDeleteStdout, absentDeleteStderr) <-
          runInstalledWithAuthorityEnvironment
            tmpDir
            binary
            ["charts", "delete", "vscode", "--yes"]
            absentNamespaceEnvVars
        absentDeleteExitCode `shouldBe` ExitSuccess
        absentDeleteStderr `shouldBe` ""
        absentDeleteStdout `shouldContain` "no Secret and no Certificate"
        chartStateFilesAfterAbsentDelete <- listDirectory (tmpDir </> "fake-chart-state")
        length
          [ path
          | path <- chartStateFilesAfterAbsentDelete
          , take 13 path == "kubectl-apply"
          ]
          `shouldBe` applyCountAfterPresentDelete

        uninstallRecord <- readFile (tmpDir </> "fake-chart-state" </> "helm-uninstall.txt")
        uninstallRecord `shouldContain` "uninstall|vscode|--namespace|vscode"
        uninstallRecord `shouldContain` "uninstall|keycloak|--namespace|vscode"

        deleteRecord <- readFile (tmpDir </> "fake-chart-state" </> "kubectl-delete.txt")
        deleteRecord
          `shouldContain` "delete|pod|--selector|postgres-operator.crunchydata.com/cluster=prodbox-vscode-pg,postgres-operator.crunchydata.com/data=postgres|--namespace|vscode|--ignore-not-found=true|--wait=true"
        deleteRecord
          `shouldContain` "delete|pvc|--selector|postgres-operator.crunchydata.com/cluster=prodbox-vscode-pg,postgres-operator.crunchydata.com/data=postgres|--namespace|vscode|--ignore-not-found=true|--wait=true"
        deleteRecord
          `shouldContain` "delete|pv|prodbox-retained-vscode-prodbox-vscode-pg-0"
        deleteRecord `shouldContain` "delete|pvc|data-vscode-0|--namespace|vscode"
        deleteRecord `shouldContain` "delete|pv|prodbox-retained-vscode-vscode-0"
        deleteRecord `shouldContain` "delete|namespace|vscode"

        -- The RKE2 fake shares the same exact-absence contract for every
        -- non-Harbor release and retains Harbor's present/uninstall/absent
        -- transition. Keep this check in the installed-boundary case so the
        -- suite count stays stable while both fake interpreters are covered.
        let rke2HelmPath = tmpDir </> "fake-rke2-helm"
            rke2HelmState = tmpDir </> "fake-rke2-helm-state"
            rke2HelmEnvironment =
              ("PRODBOX_FAKE_RKE2_RECORD_DIR", rke2HelmState)
                : filter ((/= "PRODBOX_FAKE_RKE2_RECORD_DIR") . fst) envVars
            runRke2Helm arguments =
              readCreateProcessWithExitCode
                (proc rke2HelmPath arguments) {env = Just rke2HelmEnvironment}
                ""
        writeExecutable rke2HelmPath fakeRke2HelmScript

        (nonHarborExit, nonHarborStdout, nonHarborStderr) <-
          runRke2Helm ["status", "bootstrap-broker", "--namespace", "bootstrap-broker", "--output", "json"]
        (nonHarborExit, nonHarborStdout, nonHarborStderr)
          `shouldBe` (ExitFailure 1, "", "Error: release: not found\n")

        (harborPresentExit, harborPresentStdout, harborPresentStderr) <-
          runRke2Helm ["status", "harbor", "--namespace", "harbor", "--output", "json"]
        harborPresentExit `shouldBe` ExitSuccess
        harborPresentStderr `shouldBe` ""
        harborPresentStdout
          `shouldBe` "{\"name\":\"harbor\",\"namespace\":\"harbor\",\"info\":{\"status\":\"deployed\"}}\n"

        (harborUninstallExit, _, harborUninstallStderr) <-
          runRke2Helm ["uninstall", "harbor", "--namespace", "harbor", "--ignore-not-found"]
        (harborUninstallExit, harborUninstallStderr) `shouldBe` (ExitSuccess, "")

        (harborAbsentExit, harborAbsentStdout, harborAbsentStderr) <-
          runRke2Helm ["status", "harbor", "--namespace", "harbor", "--output", "json"]
        (harborAbsentExit, harborAbsentStdout, harborAbsentStderr)
          `shouldBe` (ExitFailure 1, "", "Error: release: not found\n")

    it "stages retained Patroni restore from ordinal-0 host data when no live primary exists" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)
        -- Sprint 4.31: the retained ordinal-0 host data lives at the unified
        -- `.data/<namespace>/<StatefulSet>/<ordinal>` path (no `<release>` /
        -- `<claim>` segment), so the restore-staging detects it here.
        let patroniRoot = tmpDir </> ".data" </> "vscode" </> "prodbox-vscode-pg"
            anchorSentinel = patroniRoot </> "0" </> "anchor-sentinel"
            followerSentinels =
              [ patroniRoot </> "1" </> "follower-sentinel"
              , patroniRoot </> "2" </> "follower-sentinel"
              ]
        mapM_ (createDirectoryIfMissing True . takeDirectory) (anchorSentinel : followerSentinels)
        writeFile anchorSentinel "preserve-anchor"
        mapM_ (`writeFile` "reset-follower") followerSentinels
        baseEnvVars <- fakeChartEnvironment tmpDir
        let envVars = ("PRODBOX_FAKE_PATRONI_STAGED_RESTORE", "true") : baseEnvVars

        (deployExitCode, deployStdout, deployStderr) <-
          runInstalledWithAuthorityEnvironment tmpDir binary ["charts", "reconcile", "vscode"] envVars

        when
          (deployExitCode /= ExitSuccess)
          (expectationFailure ("deploy STDOUT:\n" ++ deployStdout ++ "\ndeploy STDERR:\n" ++ deployStderr))
        deployExitCode `shouldBe` ExitSuccess
        deployStderr `shouldBe` ""
        deployStdout `shouldContain` "CHART_DEPLOYMENT"
        deployStdout `shouldContain` "ROOT_CHART=vscode"

        upgradeRecord <- readFile (tmpDir </> "fake-chart-state" </> "helm-upgrade.txt")
        let upgradeLines = lines upgradeRecord
            keycloakPostgresUpgrades =
              filter ("|keycloak-postgres|" `isInfixOf`) upgradeLines
        length keycloakPostgresUpgrades `shouldBe` 2
        length upgradeLines `shouldBe` 4

        kubectlRecord <- readFile (tmpDir </> "fake-chart-state" </> "kubectl.txt")
        kubectlRecord
          `shouldContain` "get|pods|--namespace|vscode|--selector|postgres-operator.crunchydata.com/cluster=prodbox-vscode-pg,postgres-operator.crunchydata.com/role=primary|-o|json"
        kubectlRecord `shouldNotContain` "targetRef.name"
        doesFileExist anchorSentinel `shouldReturn` True
        mapM_ (\sentinel -> doesFileExist sentinel `shouldReturn` False) followerSentinels

    it
      "HOME-PATRONI-RETAINED-THREE-ORDINAL-RESTORE-NONCONVERGENCE-2026-09-06 preserves active follower roots when an exact live primary exists"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)
        let patroniRoot = tmpDir </> ".data" </> "vscode" </> "prodbox-vscode-pg"
            sentinels =
              [ patroniRoot </> "0" </> "anchor-sentinel"
              , patroniRoot </> "1" </> "follower-sentinel"
              , patroniRoot </> "2" </> "follower-sentinel"
              ]
        mapM_ (createDirectoryIfMissing True . takeDirectory) sentinels
        mapM_ (`writeFile` "live-member") sentinels
        baseEnvVars <- fakeChartEnvironment tmpDir
        let envVars = ("PRODBOX_FAKE_PATRONI_LIVE_ANCHOR", "true") : baseEnvVars

        (deployExitCode, deployStdout, deployStderr) <-
          runInstalledWithAuthorityEnvironment tmpDir binary ["charts", "reconcile", "vscode"] envVars

        when
          (deployExitCode /= ExitSuccess)
          (expectationFailure ("deploy STDOUT:\n" ++ deployStdout ++ "\ndeploy STDERR:\n" ++ deployStderr))
        deployExitCode `shouldBe` ExitSuccess
        deployStderr `shouldBe` ""
        deployStdout `shouldContain` "ROOT_CHART=vscode"
        mapM_ (\sentinel -> doesFileExist sentinel `shouldReturn` True) sentinels
        mapM_
          (\ordinal -> doesDirectoryExist (patroniRoot </> show ordinal) `shouldReturn` True)
          [0 :: Int, 1, 2]

        upgradeRecord <- readFile (tmpDir </> "fake-chart-state" </> "helm-upgrade.txt")
        length (filter ("|keycloak-postgres|" `isInfixOf`) (lines upgradeRecord)) `shouldBe` 1

    it "rejects internal dependency charts on the public charts surface" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)
        envVars <- fakeChartEnvironment tmpDir

        (statusExitCode, _, statusStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["charts", "status", "keycloak-postgres"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        statusExitCode `shouldBe` ExitFailure 1
        statusStderr `shouldContain` "Unsupported public chart 'keycloak-postgres'"
        statusStderr `shouldContain` "Supported root charts: keycloak, vscode, api, websocket, gateway"
        statusStderr `shouldContain` "internal dependency release"

        (deleteExitCode, _, deleteStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["charts", "delete", "redis", "--yes"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        deleteExitCode `shouldBe` ExitFailure 1
        deleteStderr `shouldContain` "Unsupported public chart 'redis'"
        deleteStderr `shouldContain` "Supported root charts: keycloak, vscode, api, websocket, gateway"
        deleteStderr `shouldContain` "internal dependency release"

    it
      "runs native rke2 status, start, and logs through the built frontend with fake systemctl and journalctl"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)
        envVars <- fakeRke2Environment tmpDir

        (statusExitCode, statusStdout, statusStderr) <-
          runInstalledWithAuthorityEnvironment
            tmpDir
            binary
            ["cluster", "status"]
            envVars

        statusExitCode `shouldBe` ExitSuccess
        statusStderr `shouldBe` ""
        statusStdout `shouldContain` "active"
        statusStdout `shouldContain` "Vault: initialized=True, sealed=False"

        (startExitCode, startStdout, startStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["cluster", "start"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        startExitCode `shouldBe` ExitSuccess
        startStdout `shouldBe` ""
        startStderr `shouldBe` ""

        (logsExitCode, logsStdout, logsStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["cluster", "logs", "--lines", "25"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        logsExitCode `shouldBe` ExitSuccess
        logsStderr `shouldBe` ""
        logsStdout `shouldContain` "RKE2_LOG_LINES"

        let fakeDocker = tmpDir </> "bin" </> "docker"
            danglingRuntimeImageId = "sha256:" ++ replicate 64 'd'
            populatedDockerEnvironment =
              ("PRODBOX_FAKE_RKE2_DANGLING_RUNTIME_IMAGE_ID", danglingRuntimeImageId)
                : envVars

        (emptyInventoryExit, emptyInventoryStdout, emptyInventoryStderr) <-
          readCreateProcessWithExitCode
            (proc fakeDocker Rke2.managedRuntimeImageRetentionInventoryArguments)
              { cwd = Just tmpDir
              , env = Just envVars
              }
            ""
        emptyInventoryExit `shouldBe` ExitSuccess
        emptyInventoryStderr `shouldBe` ""
        Rke2.selectManagedDanglingRuntimeImageIds emptyInventoryStdout
          `shouldBe` Right []

        (populatedInventoryExit, populatedInventoryStdout, populatedInventoryStderr) <-
          readCreateProcessWithExitCode
            (proc fakeDocker Rke2.managedRuntimeImageRetentionInventoryArguments)
              { cwd = Just tmpDir
              , env = Just populatedDockerEnvironment
              }
            ""
        populatedInventoryExit `shouldBe` ExitSuccess
        populatedInventoryStderr `shouldBe` ""
        Rke2.selectManagedDanglingRuntimeImageIds populatedInventoryStdout
          `shouldBe` Right [danglingRuntimeImageId]

        (removeImageExit, removeImageStdout, removeImageStderr) <-
          readCreateProcessWithExitCode
            (proc fakeDocker ["image", "rm", danglingRuntimeImageId])
              { cwd = Just tmpDir
              , env = Just populatedDockerEnvironment
              }
            ""
        removeImageExit `shouldBe` ExitSuccess
        removeImageStdout `shouldBe` ""
        removeImageStderr `shouldBe` ""

        (absentReadBackExit, absentReadBackStdout, absentReadBackStderr) <-
          readCreateProcessWithExitCode
            (proc fakeDocker Rke2.managedRuntimeImageRetentionInventoryArguments)
              { cwd = Just tmpDir
              , env = Just populatedDockerEnvironment
              }
            ""
        absentReadBackExit `shouldBe` ExitSuccess
        absentReadBackStderr `shouldBe` ""
        Rke2.selectManagedDanglingRuntimeImageIds absentReadBackStdout
          `shouldBe` Right []

        let runtimeRepository = "127.0.0.1:30080/prodbox/prodbox-runtime"
            runtimeImageRef = runtimeRepository ++ ":prodbox-fixture"
            runtimeConfigDigest =
              "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
            runtimeManifestDigest = fixtureRuntimeManifestDigest

        (configIdentityExit, configIdentityStdout, configIdentityStderr) <-
          readCreateProcessWithExitCode
            (proc fakeDocker ["image", "inspect", "--format", "{{.Id}}", runtimeImageRef])
              { cwd = Just tmpDir
              , env = Just envVars
              }
            ""
        configIdentityExit `shouldBe` ExitSuccess
        configIdentityStdout `shouldBe` (runtimeConfigDigest ++ "\n")
        configIdentityStderr `shouldBe` ""

        (manifestInventoryExit, manifestInventoryStdout, manifestInventoryStderr) <-
          readCreateProcessWithExitCode
            ( proc
                fakeDocker
                [ "image"
                , "inspect"
                , "--format"
                , "{{json .RepoDigests}}"
                , runtimeImageRef
                ]
            )
              { cwd = Just tmpDir
              , env = Just envVars
              }
            ""
        manifestInventoryExit `shouldBe` ExitSuccess
        manifestInventoryStderr `shouldBe` ""
        case Aeson.eitherDecodeStrict' (BS8.pack manifestInventoryStdout) of
          Left detail -> expectationFailure detail
          Right repositoryDigests -> do
            repositoryDigests
              `shouldBe` [runtimeRepository ++ "@" ++ runtimeManifestDigest]
            ChartPlatform.selectRepositoryManifestDigest runtimeRepository repositoryDigests
              `shouldBe` Just runtimeManifestDigest

        let fakeKubectl = tmpDir </> "bin" </> "kubectl"
            desiredSubstrate =
              CredentialProvisionerSubstrate.credentialProvisionerSubstrateManifest
                ChartPlatform.KubernetesApiEgressCoordinate
                  { ChartPlatform.kubernetesApiEgressAddresses = ["192.0.2.10"]
                  , ChartPlatform.kubernetesApiEgressPort = 6443
                  }
            desiredSubstrateJson = LazyBS8.unpack (Aeson.encode desiredSubstrate)
            substrateObservationArguments =
              [ "get"
              , "--filename=-"
              , "--output=json"
              , "--ignore-not-found=true"
              ]
            storedSubstratePath =
              tmpDir
                </> "fake-rke2-state"
                </> "credential-provisioner-substrate.json"

        (absentSubstrateExit, absentSubstrateStdout, absentSubstrateStderr) <-
          readCreateProcessWithExitCode
            (proc fakeKubectl substrateObservationArguments)
              { cwd = Just tmpDir
              , env = Just envVars
              }
            desiredSubstrateJson
        absentSubstrateExit `shouldBe` ExitFailure 1
        absentSubstrateStdout `shouldBe` ""
        absentSubstrateStderr
          `shouldContain` "Credential Provisioner substrate has not been applied"

        (applySubstrateExit, applySubstrateStdout, applySubstrateStderr) <-
          readCreateProcessWithExitCode
            (proc fakeKubectl ["apply", "--filename=-"])
              { cwd = Just tmpDir
              , env = Just envVars
              }
            desiredSubstrateJson
        applySubstrateExit `shouldBe` ExitSuccess
        applySubstrateStdout `shouldBe` ""
        applySubstrateStderr `shouldBe` ""

        (observeSubstrateExit, observeSubstrateStdout, observeSubstrateStderr) <-
          readCreateProcessWithExitCode
            (proc fakeKubectl substrateObservationArguments)
              { cwd = Just tmpDir
              , env = Just envVars
              }
            desiredSubstrateJson
        observeSubstrateExit `shouldBe` ExitSuccess
        observeSubstrateStderr `shouldBe` ""
        case Aeson.eitherDecodeStrict' (BS8.pack observeSubstrateStdout) of
          Left detail -> expectationFailure detail
          Right observedSubstrate ->
            CredentialProvisionerSubstrate.credentialProvisionerSubstrateMatches
              desiredSubstrate
              observedSubstrate
              `shouldBe` True

        writeFile storedSubstratePath "{"
        (malformedSubstrateExit, malformedSubstrateStdout, malformedSubstrateStderr) <-
          readCreateProcessWithExitCode
            (proc fakeKubectl substrateObservationArguments)
              { cwd = Just tmpDir
              , env = Just envVars
              }
            desiredSubstrateJson
        malformedSubstrateExit `shouldBe` ExitSuccess
        malformedSubstrateStderr `shouldBe` ""
        (Aeson.eitherDecodeStrict' (BS8.pack malformedSubstrateStdout) :: Either String Aeson.Value)
          `shouldSatisfy` isLeft

        let obsoleteAuthorityBackupTarget =
              [ "--namespace"
              , "authority-backup"
              , "port-forward"
              , "service/authority-backup"
              , "45124:8600"
              ]
        (obsoleteForwardExit, obsoleteForwardStdout, obsoleteForwardStderr) <-
          readCreateProcessWithExitCode
            (proc fakeKubectl obsoleteAuthorityBackupTarget)
              { cwd = Just tmpDir
              , env = Just envVars
              }
            ""
        obsoleteForwardExit `shouldBe` ExitFailure 1
        obsoleteForwardStdout `shouldBe` ""
        obsoleteForwardStderr
          `shouldContain` "unsupported fake Authority Backup port-forward target"

        authorityBackupForwardPort <- reserveClosedLoopbackPort
        let authorityBackupForwardMapping = show authorityBackupForwardPort ++ ":8600"
            authorityBackupForwardArguments =
              [ "--namespace"
              , "authority-backup"
              , "port-forward"
              , "deployment/authority-backup"
              , authorityBackupForwardMapping
              ]
            stopForward (_, _, _, processHandle) = do
              _ <- try (terminateProcess processHandle) :: IO (Either SomeException ())
              _ <- try (waitForProcess processHandle) :: IO (Either SomeException ExitCode)
              pure ()
            assertForwardStartup (_, maybeStdoutHandle, _, _) =
              case maybeStdoutHandle of
                Nothing -> expectationFailure "fake Authority Backup forward had no stdout pipe"
                Just stdoutHandle -> do
                  startupLine <- IO.hGetLine stdoutHandle
                  LocalClient.classifyAuthorityBackupForwardStartup
                    authorityBackupForwardPort
                    (LocalClient.AuthorityBackupForwardStartupLine startupLine)
                    `shouldBe` Right ()
                  httpGetText
                    (defaultHttpConfig {httpRequestTimeoutMicros = 250000})
                    ("http://127.0.0.1:" ++ show authorityBackupForwardPort ++ "/readyz")
                    `shouldReturn` Right "{}"

        bracket
          ( createProcess
              (proc fakeKubectl authorityBackupForwardArguments)
                { cwd = Just tmpDir
                , env = Just envVars
                , std_out = CreatePipe
                }
          )
          stopForward
          assertForwardStartup
        readFile
          (tmpDir </> "fake-rke2-state" </> "authority-backup-forward-child.state")
          `shouldReturn` "stopped\n"

        systemctlRecord <- readFile (tmpDir </> "fake-rke2-state" </> "systemctl.txt")
        systemctlRecord `shouldContain` "is-active|rke2-server.service"
        systemctlRecord `shouldContain` "start|rke2-server.service"

        sudoRecord <- readFile (tmpDir </> "fake-rke2-state" </> "sudo.txt")
        sudoRecord `shouldContain` "systemctl|start|rke2-server.service"

        journalctlRecord <- readFile (tmpDir </> "fake-rke2-state" </> "journalctl.txt")
        journalctlRecord `shouldContain` "-u|rke2-server.service|-n|25|--no-pager"

    it "freezes the 178-to-30 Registry GC partial-progress stderr overflow" $
      withSystemTempDirectory "prodbox-hs-registry-gc-overflow" $ \tmpDir -> do
        envVars <- fakeRke2Environment tmpDir
        let limits =
              Subprocess.BoundedSubprocessLimits
                { Subprocess.boundedSubprocessMaximumInputBytes = 1
                , Subprocess.boundedSubprocessMaximumStdoutBytes = 16 * 1024 * 1024
                , Subprocess.boundedSubprocessMaximumStderrBytes = 64 * 1024
                , Subprocess.boundedSubprocessTimeoutMicros = 10 * 1000 * 1000
                }
            oldCollector =
              Subprocess.Subprocess
                { Subprocess.subprocessPath = tmpDir </> "bin" </> "kubectl"
                , Subprocess.subprocessArguments =
                    [ "exec"
                    , "--namespace"
                    , "harbor"
                    , "deployment/registry"
                    , "--container"
                    , "registry"
                    , "--"
                    , "/bin/registry"
                    , "garbage-collect"
                    , "--delete-untagged"
                    , "/etc/docker/registry/config.yml"
                    ]
                , Subprocess.subprocessEnvironment = Just envVars
                , Subprocess.subprocessWorkingDirectory = Just tmpDir
                }
        captureResult <- Subprocess.captureSubprocessBounded limits oldCollector
        captureResult `shouldSatisfy` isLeft
        readFile (tmpDir </> "fake-rke2-state" </> "registry-gc-partial-audit.txt")
          `shouldReturn` "178->30\n"

    it "refuses installer effects until an incomplete host cleanup resumes" $ do
      sourceRoot <- getCurrentDirectory
      withSystemTempDirectory "prodbox-hs-cli-predecessor" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)
        envVars <- fakeRke2Environment tmpDir
        completedBytes <- BS8.readFile (sourceRoot </> "test/fixtures/host-cleanup-history/active.cbor")
        completed <-
          either (ioError . userError . show) pure (HostCleanup.decodeHostCleanupIntent completedBytes)
        prepared <-
          either (ioError . userError . show) pure $
            HostCleanup.mkHostCleanupIntent
              (HostCleanup.hostCleanupRunId completed)
              (HostCleanup.hostCleanupGraphDigest completed)
              (HostCleanup.hostCleanupRun completed)
              (HostCleanup.hostCleanupScope completed)
              (HostCleanup.hostCleanupTerminalIdentity completed)
        store <-
          either
            (ioError . userError . show)
            pure
            (HostCleanup.mkHostCleanupIntentStore (tmpDir </> ".data/prodbox"))
        preparedBytes <-
          either (ioError . userError . show) pure (HostCleanup.encodeHostCleanupIntent prepared)
        createDirectoryIfMissing True (takeDirectory (HostCleanup.hostCleanupIntentPath store))
        BS8.writeFile (HostCleanup.hostCleanupIntentPath store) preparedBytes
        setFileMode (HostCleanup.hostCleanupIntentPath store) 0o600
        -- Non-authorizing locator bytes: the journal reader must still
        -- independently reject the incomplete intent before installation.
        LazyBS8.writeFile (tmpDir </> ".data/prodbox/.cluster-established") $
          serialise
            ( Text.pack "prodbox-local-retained-root"
            , 1 :: Word
            , Text.pack tmpDir
            , Text.pack ".data"
            , Text.pack (tmpDir </> ".data")
            )
        (exit, _, stderrText) <-
          runRke2ReconcileWithFakeGateway tmpDir binary ["cluster", "reconcile"] envVars
        exit `shouldBe` ExitFailure 1
        stderrText `shouldContain` "HistoricalHostCleanupNotComplete HostCleanupPrepared"
        stderrText `shouldContain` "PRODBOX_TEST_CASCADE_QUALIFICATION_CYCLE"
        doesFileExist (tmpDir </> "fake-rke2-state/sysctl.txt") `shouldReturn` False
        doesFileExist (tmpDir </> "fake-rke2-state/kubectl-apply.count") `shouldReturn` False
        BS8.readFile (HostCleanup.hostCleanupIntentPath store) `shouldReturn` preparedBytes

    it "fails closed on an exit-zero Registry GC usage rejection and restores read-write mode" $
      withSystemTempDirectory "prodbox-hs-cli-registry-gc-refusal" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfig)
        baseEnvVars <-
          (("PRODBOX_TEST_HOST_VAULT_TOKEN", "fake-root-token") :) <$> fakeRke2Environment tmpDir
        let envVars =
              ("PRODBOX_FAKE_REGISTRY_GC_USAGE_REJECTION", "1") : baseEnvVars

        (installExitCode, installStdout, installStderr) <-
          runRke2ReconcileWithFakeGateway
            tmpDir
            binary
            ["cluster", "reconcile"]
            envVars

        installExitCode `shouldBe` ExitFailure 1
        installStdout `shouldNotContain` "Registry manifest retention: untagged collection completed"
        installStderr
          `shouldContain` "Registry manifest retention collector refused its result: registry collector wrote to stderr"

        let rke2StateDir = tmpDir </> "fake-rke2-state"
        dockerRecord <- readFile (rke2StateDir </> "docker.txt")
        dockerRecord `shouldNotContain` "build|-f|docker/prodbox.Dockerfile"
        registryGcAuditExists <- doesFileExist (rke2StateDir </> "registry-gc-audit.txt")
        registryGcAuditExists `shouldBe` False
        kubectlRecord <- readFile (rke2StateDir </> "kubectl.txt")
        let registryGcDryRunCommand =
              "exec|--namespace|harbor|deployment/registry|--container|registry|--|/usr/bin/env|REGISTRY_LOG_LEVEL=error|/bin/registry|garbage-collect|--dry-run|--delete-untagged|/etc/docker/registry/config.yml"
            registryGcDeleteCommand =
              "exec|--namespace|harbor|deployment/registry|--container|registry|--|/usr/bin/env|REGISTRY_LOG_LEVEL=error|/bin/registry|garbage-collect|--delete-untagged|/etc/docker/registry/config.yml"
        countRecordLines registryGcDryRunCommand kubectlRecord `shouldBe` 1
        countRecordLines registryGcDeleteCommand kubectlRecord `shouldBe` 0

        applyCount <- read <$> readFile (rke2StateDir </> "kubectl-apply.count")
        appliedManifests <-
          mapM
            (\indexValue -> readFile (rke2StateDir </> "kubectl-apply-" ++ show indexValue ++ ".json"))
            [1 .. applyCount :: Int]
        let indexedManifests = zip [0 :: Int ..] appliedManifests
            readOnlyIndex = fst <$> find (isInfixOf "read-only" . snd) indexedManifests
            laterReadWriteExists indexValue =
              any
                ( \(candidateIndex, manifest) ->
                    candidateIndex > indexValue && "read-write" `isInfixOf` manifest
                )
                indexedManifests
        case readOnlyIndex of
          Nothing -> expectationFailure "Registry GC refusal never applied the read-only fence"
          Just indexValue -> laterReadWriteExists indexValue `shouldBe` True

    it
      "HOME-RUNTIME-CRI-REFERENCE-PUBLICATION-2026-10-24 refuses Broker deployment without CRI observation"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \built -> installOperatorBinaryInDir built tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)
        baseEnvironment <- fakeRke2Environment tmpDir
        let environment =
              ("PRODBOX_FAKE_RUNTIME_REFERENCE_MODE", "unavailable")
                : ("PRODBOX_TEST_HOST_VAULT_TOKEN", "fake-root-token")
                : filter ((/= "PRODBOX_FAKE_RUNTIME_REFERENCE_MODE") . fst) baseEnvironment
        (exitCode, stdoutText, stderrText) <-
          runRke2ReconcileWithFakeGateway tmpDir binary ["cluster", "reconcile"] environment
        exitCode `shouldBe` ExitFailure 1
        (stdoutText ++ stderrText) `shouldContain` "RuntimeCRIUnavailable"
        let state = tmpDir </> "fake-rke2-state"
        criRecord <- readFile (state </> "crictl.txt")
        length (lines criRecord) `shouldBe` 3
        ctrRecord <- readFile (state </> "ctr.txt")
        ctrRecord `shouldNotContain` "content fetch"
        helmRecord <- readFile (state </> "helm.txt")
        helmRecord `shouldNotContain` "upgrade|--install|bootstrap-broker"

    it
      "INTERNAL-HELM-FAILED-RELEASE-STARTUP-LOGS-MISSING-2026-10-24 reports only closed startup causes before cleanup"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \built -> installOperatorBinaryInDir built tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)
        baseEnvironment <- fakeRke2Environment tmpDir
        let state = tmpDir </> "fake-rke2-state"
            environment =
              ("PRODBOX_FAKE_AUTHORITY_STARTUP_FAILURE", "1")
                : ("PRODBOX_TEST_HOST_VAULT_TOKEN", "fake-root-token")
                : baseEnvironment
        writeFile (state </> "startup-pod.json") fixtureHelmStartupPod
        writeFile (state </> "startup-pods.json") ("{\"items\":[" ++ fixtureHelmStartupPod ++ "]}")
        (exitCode, stdoutText, stderrText) <-
          runRke2ReconcileWithFakeGateway tmpDir binary ["cluster", "reconcile"] environment
        exitCode `shouldBe` ExitFailure 1
        let output = stdoutText ++ stderrText
        output
          `shouldContain` "startup-evidence/lifecycle-authority/current=config/decode/previous=config/decode"
        output `shouldNotContain` "private-startup-sentinel"
        output `shouldContain` "helm uninstall completed and absence was verified"
        order <- lines <$> readFile (state </> "startup-evidence-order.txt")
        order `shouldBe` ["log-current", "log-previous", "uninstall"]

    it
      "REGISTRY-NODEPORT-READBACK-CONNECTION-REFUSED-AFTER-READY-CLEAN-INSTALL-2026-09-06 retries one transient Registry read-back and completes native reconcile/delete"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfig)
        -- Sprint 1.42 Part B: with the Tier-0 prodbox.dhall floor present, the
        -- post-MinIO settings reload obtains the host Vault root token; supply
        -- the test seam so it does not try to decrypt an unlock bundle (none
        -- exists in this temp repo). The in-force SSoT seed against the real
        -- Vault fail-WARNs and the config read falls back to .parameters.
        baseEnvVars <-
          (("PRODBOX_TEST_HOST_VAULT_TOKEN", "fake-root-token") :) <$> fakeRke2Environment tmpDir
        let danglingRuntimeImageId = "sha256:" ++ replicate 64 'd'
            envVars =
              [ ("PRODBOX_FAKE_RKE2_DANGLING_RUNTIME_IMAGE_ID", danglingRuntimeImageId)
              , ("PRODBOX_FAKE_REGISTRY_READ_BACK_TRANSIENT", "1")
              ]
                ++ baseEnvVars

        (installExitCode, installStdout, installStderr) <-
          runRke2ReconcileWithFakeGateway
            tmpDir
            binary
            ["cluster", "reconcile"]
            envVars

        let installOutput =
              unlines
                [ "install stdout:"
                , installStdout
                , "install stderr:"
                , installStderr
                ]
        when (installExitCode /= ExitSuccess) (expectationFailure installOutput)
        installExitCode `shouldBe` ExitSuccess
        installStdout `shouldContain` "Kubernetes control plane is running"
        installStdout `shouldContain` "RKE2 resource guardrails: host capacity ok"
        installStdout `shouldContain` "RKE2 kubelet resource guardrails: written"
        installStdout `shouldContain` "RKE2 systemd resource guardrails: written"
        -- The first reconcile host-prep step raises the inotify limits so the
        -- systemd manager does not exhaust the per-user instance cap during RKE2
        -- lifecycle operations (see streaming_doctrine.md at 583443f, section 6).
        installStdout `shouldContain` "Host inotify limits:"
        installStderr
          `shouldContain` "Retrying Harbor publication for mirror target 127.0.0.1:30080/prodbox/code-server-mirror:4.98.2"
        installStderr
          `shouldContain` "Retrying Registry reference observation after transient transport failure"

        createDirectoryIfMissing True (tmpDir </> ".kube")
        writeFile (tmpDir </> ".kube" </> "config") "server: https://127.0.0.1:6443\n"

        (deleteExitCode, deleteStdout, deleteStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["cluster", "delete", "--yes"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        let deleteOutput =
              unlines
                [ "delete stdout:"
                , deleteStdout
                , "delete stderr:"
                , deleteStderr
                ]
        when (deleteExitCode /= ExitSuccess) (expectationFailure deleteOutput)
        deleteExitCode `shouldBe` ExitSuccess
        deleteStderr `shouldBe` ""
        deleteStdout `shouldContain` "Uninstalling the local cluster..."
        -- Default `cluster delete` (no --cascade) is a pure local uninstall:
        -- it does not query, gate on, or destroy the per-run AWS Pulumi
        -- backend, so it emits this notice instead of per-stack destroy
        -- traces (per the refactored lifecycle doctrine).
        deleteStdout
          `shouldContain` "Per-run AWS stacks (if any) were NOT destroyed by this local uninstall."
        deleteStdout `shouldContain` "Local RKE2 substrate: cleanup complete"
        deleteStdout `shouldContain` "Managed kubeconfig: removed"
        deleteStdout `shouldContain` "Retained host state:"
        deleteStdout `shouldNotContain` "Logged in to fake-rke2"
        kubeconfigExists <- doesFileExist (tmpDir </> ".kube" </> "config")
        kubeconfigExists `shouldBe` False

        systemctlRecord <- readFile (tmpDir </> "fake-rke2-state" </> "systemctl.txt")
        systemctlRecord `shouldContain` "enable|rke2-server.service"
        systemctlRecord `shouldContain` "restart|rke2-server.service"
        systemctlRecord `shouldContain` "disable|--now|rke2-server.service"

        sudoRecord <- readFile (tmpDir </> "fake-rke2-state" </> "sudo.txt")
        sudoRecord `shouldContain` "env|INSTALL_RKE2_TYPE=server|sh|"
        sudoRecord `shouldContain` "/etc/rancher/rke2/config.yaml.d/90-prodbox-resource-guardrails.yaml"
        sudoRecord
          `shouldContain` "/etc/systemd/system/rke2-server.service.d/90-prodbox-resource-guardrails.conf"
        sudoRecord `shouldContain` "systemctl|daemon-reload"
        sudoRecord `shouldContain` "cp|/etc/rancher/rke2/rke2.yaml|"
        sudoRecord `shouldContain` "ctr|--address|"
        sudoRecord
          `shouldContain` "rm|-rf|/var/lib/rancher/rke2|/var/lib/rancher|/etc/rancher/rke2|/usr/local/bin/rke2|/usr/local/bin/rke2-killall.sh|/usr/local/bin/rke2-uninstall.sh"

        -- The first delete host-prep step persists the inotify sysctl drop-in and
        -- applies it via `sysctl --system` before systemd unwinds the RKE2 units,
        -- so PID 1 never logs `Failed to allocate directory watch: Too many open
        -- files` to the console (see streaming_doctrine.md at 583443f, section 6).
        deleteStdout `shouldContain` "Host inotify limits:"
        sudoRecord `shouldContain` "/etc/sysctl.d/99-prodbox-inotify.conf"
        sudoRecord `shouldContain` "sysctl|--system"
        sysctlRecord <- readFile (tmpDir </> "fake-rke2-state" </> "sysctl.txt")
        sysctlRecord `shouldContain` "--system"

        kubectlRecord <- readFile (tmpDir </> "fake-rke2-state" </> "kubectl.txt")
        kubectlRecord `shouldContain` "cluster-info"
        kubectlRecord `shouldContain` "get|nodes|-o|name"
        kubectlRecord `shouldContain` "wait|--for=condition=Ready|node|--all|--timeout=300s"
        kubectlRecord `shouldContain` "rollout|status|statefulset/vault|--timeout=300s|-n|vault"
        kubectlRecord `shouldContain` "get|storageclass|-o|name"
        kubectlRecord
          `shouldContain` "delete|storageclass|storageclass.storage.k8s.io/local-path|--ignore-not-found=true"
        -- registry:2 is applied as a plain Deployment + NodePort Service (no
        -- Harbor nginx `/readyz` readiness patch); reconcile observes the
        -- exact Deployment rollout, including recovery from an interrupted
        -- read-only retention fence.
        kubectlRecord `shouldNotContain` "harbor-nginx"
        kubectlRecord
          `shouldContain` "rollout|status|deployment/registry|--namespace|harbor|--timeout=300s"
        let registryGcDryRunCommand =
              "exec|--namespace|harbor|deployment/registry|--container|registry|--|/usr/bin/env|REGISTRY_LOG_LEVEL=error|/bin/registry|garbage-collect|--dry-run|--delete-untagged|/etc/docker/registry/config.yml"
            registryGcDeleteCommand =
              "exec|--namespace|harbor|deployment/registry|--container|registry|--|/usr/bin/env|REGISTRY_LOG_LEVEL=error|/bin/registry|garbage-collect|--delete-untagged|/etc/docker/registry/config.yml"
        countRecordLines registryGcDryRunCommand kubectlRecord `shouldBe` 1
        countRecordLines registryGcDeleteCommand kubectlRecord `shouldBe` 1
        runtimeCtrRecord <- readFile (tmpDir </> "fake-rke2-state" </> "ctr.txt")
        runtimeCtrRecord
          `shouldContain` ( "content fetch --plain-http --platform linux/amd64 127.0.0.1:30080/prodbox/prodbox-runtime@"
                              ++ fixtureRuntimeManifestDigest
                          )
        runtimeCriRecord <- readFile (tmpDir </> "fake-rke2-state" </> "crictl.txt")
        length (lines runtimeCriRecord) `shouldBe` 2
        kubectlRecord `shouldContain` "annotate|namespace/prodbox|prodbox.io/id=prodbox-"
        kubectlRecord `shouldContain` "label|namespace/prodbox|prodbox.io/id=prodbox-"
        kubectlRecord
          `shouldContain` "annotate|clusterroles.rbac.authorization.k8s.io|-l|app.kubernetes.io/instance=harbor|prodbox.io/id=prodbox-"
        kubectlRecord
          `shouldContain` "label|clusterroles.rbac.authorization.k8s.io|-l|app.kubernetes.io/instance=harbor|prodbox.io/id=prodbox-"
        kubectlRecord
          `shouldNotContain` "delete|namespace|harbor|--ignore-not-found=true|--wait=true|--timeout=300s"
        kubectlRecord `shouldNotContain` "jsonpath={.metadata.labels.app\\.kubernetes\\.io/name}"
        kubectlRecord
          `shouldNotContain` "delete|namespace|traefik-system|--ignore-not-found=true|--wait=true|--timeout=300s"

        let rke2StateDir = tmpDir </> "fake-rke2-state"

        applyIdentity <- readFile (rke2StateDir </> "kubectl-apply-1.json")
        applyIdentity `shouldContain` "prodbox-identity"
        applyStorage <- readFile (rke2StateDir </> "kubectl-apply-2.json")
        -- Sprint 4.31: retained storage is PV-only — the MinIO and Vault
        -- StatefulSets create their own `data-<sts>-0` PVCs, which these
        -- deterministic claimRef'd PVs bind. No PVC object in the manifest.
        applyStorage `shouldNotContain` "PersistentVolumeClaim"
        applyStorage `shouldContain` "prodbox-retained-prodbox-minio-0"
        applyStorage `shouldContain` "prodbox-retained-vault-vault-0"
        applyStorage `shouldContain` "data-minio-0"
        applyStorage `shouldContain` "data-vault-0"
        applyHarborBootstrap <-
          readAppliedManifestContaining rke2StateDir harborRegistryStorageBootstrapJobName
        applyHarborBootstrap `shouldContain` harborRegistryStorageSecretName
        applyHarborBootstrap `shouldContain` "REGISTRY_STORAGE_S3_ACCESSKEY"
        applyHarborBootstrap `shouldContain` "REGISTRY_STORAGE_S3_SECRETKEY"
        applyHarborBootstrap `shouldContain` "docker.io/prodbox/mc-bootstrap"
        applyHarborBootstrap
          `shouldContain` ("mc mb --ignore-existing local/" ++ harborRegistryStorageBucket)
        applyHarborBootstrap `shouldContain` "s3:AbortMultipartUpload"
        applyHarborBootstrap `shouldContain` "s3:ListMultipartUploadParts"
        applyHarborBootstrap `shouldContain` "s3:ListBucketMultipartUploads"
        applyHarborBootstrap `shouldContain` "mc admin policy rm local prodbox-harbor-registry-policy"
        -- The registry:2 runtime manifest: Deployment pulling registry:2, its
        -- config.yml ConfigMap, and the S3 storage Secret consumed via envFrom.
        applyRegistryRuntime <- readAppliedManifestContaining rke2StateDir "registry:2"
        applyRegistryRuntime `shouldContain` "registry:2"
        applyRegistryRuntime `shouldContain` "config.yml"
        applyRegistryRuntime `shouldContain` harborRegistryStorageSecretName
        applyRegistryRuntime `shouldContain` "nodePort"
        applyRegistryRuntime `shouldContain` "registry-access-mode"
        applyRegistryRuntime `shouldContain` "read-write"
        applyRegistryReadOnly <-
          readAppliedManifestContaining rke2StateDir "read-only"
        applyRegistryReadOnly `shouldContain` "enabled: true"
        registryGcAudit <- readFile (rke2StateDir </> "registry-gc-audit.txt")
        registryGcAudit `shouldBe` "177->1\n"
        registryGcPartialAuditExists <-
          doesFileExist (rke2StateDir </> "registry-gc-partial-audit.txt")
        registryGcPartialAuditExists `shouldBe` False
        -- registry:2 has no web UI, so only the MinIO console admin route remains.
        applyAdminRoutes <- readAppliedManifestContaining rke2StateDir "minio-console"
        applyAdminRoutes `shouldContain` "minio-console"
        applyAdminRoutes `shouldContain` "minio-oidc"
        applyAdminRoutes `shouldNotContain` "harbor-ui"
        applyAdminRoutes `shouldNotContain` "harbor-oidc"
        applyAdminRoutes
          `shouldContain` "https://test.example.test/auth/realms/prodbox/protocol/openid-connect/auth"
        applyAdminRoutes
          `shouldContain` "http://keycloak.vscode.svc.cluster.local:8080/auth/realms/prodbox/protocol/openid-connect/token"

        helmRecord <- readFile (tmpDir </> "fake-rke2-state" </> "helm.txt")
        -- Sprint 4.31: MinIO + Vault are prodbox-owned StatefulSet charts. MinIO
        -- always uses the PUBLIC image (it backs Harbor — never the Harbor
        -- mirror), so there is no bitnami `minio` helm repo and the chart sets no
        -- `mcImage`. Vault installs from `charts/vault`. Sprint 7.25: MinIO is
        -- now brought up BEFORE Vault (it is cluster-only and serves the unlock
        -- bundle pre-unseal), so its helm install precedes Vault's.
        helmRecord `shouldNotContain` "repo|add|minio|https://charts.min.io/"
        helmRecord `shouldNotContain` "upgrade|--install|minio|minio/minio"
        helmRecord `shouldContain` "/charts/minio|--namespace|prodbox|--create-namespace"
        helmRecord `shouldContain` "image.repository=docker.io/prodbox/minio-bootstrap"
        helmRecord `shouldContain` "--set|storage.className=manual"
        helmRecord `shouldNotContain` "image.repository=127.0.0.1:30080/prodbox/minio-mirror"
        helmRecord `shouldNotContain` "mcImage.repository"
        helmRecord `shouldContain` "/charts/vault|--namespace|vault|--create-namespace"
        -- registry:2 replaces the Harbor helm stack: no helm repo/install for the
        -- registry (it is a single kubectl-applied Deployment). The registered
        -- desired-absence program observes a legacy release, uninstalls it, and
        -- positively reads absence back before registry:2 is applied.
        helmRecord `shouldNotContain` "upgrade|--install|harbor|harbor/harbor"
        helmRecord `shouldNotContain` "persistence.imageChartStorage.type=s3"
        helmRecord `shouldContain` "status|harbor|--namespace|harbor|--output|json"
        helmRecord `shouldContain` "uninstall|harbor|--namespace|harbor|--ignore-not-found"
        -- Sprint 5.38: non-Harbor status is explicit absence rather than
        -- successful empty output, so production can admit the upgrade.
        helmRecord
          `shouldContain` "status|bootstrap-broker|--namespace|bootstrap-broker|--output|json"
        helmRecord `shouldContain` "repo|add|metallb|https://metallb.github.io/metallb"
        helmRecord `shouldContain` "upgrade|--install|metallb|metallb/metallb"
        helmRecord `shouldContain` "metallb/metallb|--force-conflicts|--version|0.14.9"
        helmRecord `shouldContain` "upgrade|--install|envoy-gateway|oci://docker.io/envoyproxy/gateway-helm"
        helmRecord `shouldContain` "repo|add|jetstack|https://charts.jetstack.io"
        helmRecord `shouldContain` "upgrade|--install|cert-manager|jetstack/cert-manager"
        helmRecord `shouldContain` "repo|add|percona|https://percona.github.io/percona-helm-charts/"
        helmRecord `shouldContain` "upgrade|--install|postgres-operator|percona/pg-operator"
        helmRecord `shouldNotContain` "uninstall|traefik|--namespace|traefik-system|--wait"
        helmRecord `shouldNotContain` "uninstall|postgres-operator|--namespace|postgres-operator|--wait"
        -- Sprint 7.25: MinIO is installed BEFORE Vault (cluster-only, serves the
        -- unlock bundle before Vault unseal). Both precede the registry:2 runtime
        -- (applied via kubectl, not helm).
        findRecordLineIndex "/charts/minio|--namespace|prodbox" helmRecord
          `shouldSatisfy` (< findRecordLineIndex "/charts/vault|--namespace|vault" helmRecord)

        dockerRecord <- readFile (tmpDir </> "fake-rke2-state" </> "docker.txt")
        -- Sprint 5.39: the populated machine inventory is removed once and
        -- every later observation reads exact empty output. Other RKE2 cases
        -- exercise the default-empty arm.
        dockerRecord
          `shouldContain` "image|ls|--filter|dangling=true|--no-trunc|--format|{{.Repository}}\t{{.ID}}"
        countRecordLines ("image|rm|" ++ danglingRuntimeImageId) dockerRecord `shouldBe` 1
        -- NO `docker login` runs at all — the registry:2 NodePort is anonymous, so
        -- pushes carry no credential; public pulls use the host docker.io login.
        dockerRecord `shouldNotContain` "login|127.0.0.1:30080"
        dockerRecord
          `shouldContain` "image|inspect|--format|{{.Id}}|127.0.0.1:30080/prodbox/prodbox-runtime:prodbox-"
        dockerRecord
          `shouldContain` "image|inspect|--format|{{json .RepoDigests}}|127.0.0.1:30080/prodbox/prodbox-runtime:prodbox-"
        dockerRecord `shouldNotContain` "buildx|imagetools|inspect"
        dockerRecord `shouldNotContain` "docker/bitnami-postgresql-repmgr.Dockerfile"
        dockerRecord `shouldNotContain` "docker/bitnami-pgpool.Dockerfile"
        dockerRecord `shouldContain` "pull|127.0.0.1:30080/prodbox/percona-postgresql-operator-mirror:2.9.0"
        dockerRecord
          `shouldContain` "pull|--platform|linux/amd64|docker.io/percona/percona-postgresql-operator:2.9.0"
        dockerRecord
          `shouldContain` "tag|docker.io/percona/percona-postgresql-operator:2.9.0|127.0.0.1:30080/prodbox/percona-postgresql-operator-mirror:2.9.0"
        dockerRecord
          `shouldContain` "push|--platform|linux/amd64|127.0.0.1:30080/prodbox/percona-postgresql-operator-mirror:2.9.0"
        dockerRecord
          `shouldContain` "tag|ghcr.io/coder/code-server:4.98.2|127.0.0.1:30080/prodbox/code-server-mirror:4.98.2"
        countRecordLines
          "push|--platform|linux/amd64|127.0.0.1:30080/prodbox/code-server-mirror:4.98.2"
          dockerRecord
          `shouldBe` 2
        dockerRecord
          `shouldNotContain` "tag|docker.io/codercom/code-server:4.98.2|127.0.0.1:30080/prodbox/code-server-mirror:4.98.2"
        -- One union runtime image built from the single Dockerfile, consumed by
        -- the gateway daemon + api/websocket workloads (role chosen by chart args).
        dockerRecord
          `shouldContain` "build|-f|docker/prodbox.Dockerfile|-t|127.0.0.1:30080/prodbox/prodbox-runtime:prodbox-"
        dockerRecord `shouldContain` "-t|127.0.0.1:30080/prodbox/prodbox-runtime:latest|."
        dockerRecord
          `shouldContain` "push|--platform|linux/amd64|127.0.0.1:30080/prodbox/prodbox-runtime:latest"
        dockerRecord `shouldNotContain` "docker/gateway.Dockerfile"
        dockerRecord `shouldNotContain` "prodbox-public-edge-workload"
        dockerRecord `shouldNotContain` "docker/nginx-oidc.Dockerfile"
        dockerRecord `shouldContain` "save|-o|"

        -- Sprint 1.47: the build/push/mirror docker calls ran inside an
        -- EPHEMERAL DOCKER_CONFIG (a scrubbed `prodbox-docker-config` temp dir),
        -- never the operator's global ~/.docker, so prodbox cannot pollute the
        -- system Docker Hub login state.
        dockerConfigRecord <- readFile (tmpDir </> "fake-rke2-state" </> "docker-config.txt")
        dockerConfigRecord `shouldContain` "prodbox-docker-config"

        curlRecord <- readFile (tmpDir </> "fake-rke2-state" </> "curl.txt")
        curlRecord `shouldContain` "https://get.rke2.io"
        -- registry:2 readiness is a plain GET /v2/ probe — no Harbor /readyz
        -- nginx endpoint and no /api/v2.0 projects REST reconcile.
        curlRecord `shouldContain` "http://127.0.0.1:30080/v2/"
        curlRecord `shouldContain` "http://127.0.0.1:30080/v2/_catalog?n=1000"
        readFile (rke2StateDir </> "registry-catalog.count") `shouldReturn` "3\n"
        curlRecord
          `shouldContain` "http://127.0.0.1:30080/v2/prodbox/prodbox-runtime/tags/list?n=1000"
        curlRecord
          `shouldContain` "http://127.0.0.1:30080/v2/prodbox/prodbox-runtime/manifests/latest"
        curlRecord `shouldNotContain` "http://127.0.0.1:30080/readyz"
        curlRecord `shouldNotContain` "/api/v2.0/projects"

        pulumiRecordExists <- doesFileExist (tmpDir </> "fake-rke2-state" </> "pulumi.txt")
        pulumiRecordExists `shouldBe` False

        -- Sprint 5.31 closure evidence: exercise both process-facing crossings
        -- in isolated helper processes so the assertion observes the real file
        -- descriptors rather than an injected writer. The RKE2 caller renders
        -- the exact typed refusal to stderr; the runbook wrapper then names a
        -- silent failing child on stderr without contaminating stdout.
        integrationExecutable <- getExecutablePath
        (admissionExitCode, admissionStdout, admissionStderr) <-
          readCreateProcessWithExitCode
            (proc integrationExecutable ["--fixture-rke2-admission-refusal", tmpDir])
            ""
        admissionExitCode `shouldBe` ExitFailure 1
        admissionStdout `shouldBe` ""
        admissionStderr `shouldContain` "mutating `chart_authority_backup` requires an admission"
        admissionStderr `shouldContain` "which was never observed ready in this run"

        let runbookFixtureRoot = tmpDir </> "runbook-diagnostic"
            silentFailingOperator = runbookFixtureRoot </> ".build" </> "prodbox"
        createDirectoryIfMissing True (runbookFixtureRoot </> ".build")
        writeExecutable silentFailingOperator "#!/bin/sh\nexit 23\n"
        (runbookExitCode, runbookStdout, runbookStderr) <-
          readCreateProcessWithExitCode
            (proc integrationExecutable ["--fixture-runbook-failure", runbookFixtureRoot])
            ""
        runbookExitCode `shouldBe` ExitFailure 23
        runbookStdout `shouldBe` ""
        runbookStderr
          `shouldContain` "Integration runbook step failed: prodbox cluster reconcile --with-edge (exit 23)"

    it "falls back to mirror.gcr when Docker Hub rate-limits a supported Percona image" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfig)
        baseEnvVars <- fakeRke2Environment tmpDir
        let envVars =
              ( "PRODBOX_FAKE_DOCKER_PULL_RATE_LIMIT_REF"
              , "docker.io/percona/percona-distribution-postgresql:17.9-1"
              )
                : ("PRODBOX_TEST_HOST_VAULT_TOKEN", "fake-root-token")
                : baseEnvVars

        (installExitCode, installStdout, installStderr) <-
          runRke2ReconcileWithFakeGateway
            tmpDir
            binary
            ["cluster", "reconcile"]
            envVars

        let installOutput =
              unlines
                [ "install stdout:"
                , installStdout
                , "install stderr:"
                , installStderr
                ]
        when (installExitCode /= ExitSuccess) (expectationFailure installOutput)
        installExitCode `shouldBe` ExitSuccess
        installStdout `shouldContain` "Kubernetes control plane is running"

        dockerRecord <- readFile (tmpDir </> "fake-rke2-state" </> "docker.txt")
        dockerRecord
          `shouldContain` "pull|--platform|linux/amd64|docker.io/percona/percona-distribution-postgresql:17.9-1"
        dockerRecord
          `shouldContain` "pull|--platform|linux/amd64|mirror.gcr.io/percona/percona-distribution-postgresql:17.9-1"
        dockerRecord
          `shouldContain` "tag|mirror.gcr.io/percona/percona-distribution-postgresql:17.9-1|127.0.0.1:30080/prodbox/percona-distribution-postgresql-mirror:17.9-1"
        dockerRecord
          `shouldContain` "push|--platform|linux/amd64|127.0.0.1:30080/prodbox/percona-distribution-postgresql-mirror:17.9-1"

    it "summarizes noisy uninstall-script cleanup instead of streaming raw delete traces" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)
        baseEnvVars <- fakeRke2Environment tmpDir
        let envVars = ("PRODBOX_FAKE_RKE2_UNINSTALL_EXISTS", "1") : baseEnvVars

        createDirectoryIfMissing True (tmpDir </> ".kube")
        writeFile (tmpDir </> ".kube" </> "config") "server: https://127.0.0.1:6443\n"

        (deleteExitCode, deleteStdout, deleteStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["cluster", "delete", "--yes"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        let deleteOutput =
              unlines
                [ "delete stdout:"
                , deleteStdout
                , "delete stderr:"
                , deleteStderr
                ]
        when (deleteExitCode /= ExitSuccess) (expectationFailure deleteOutput)
        deleteExitCode `shouldBe` ExitSuccess
        deleteStderr `shouldBe` ""
        deleteStdout `shouldContain` "Uninstalling the local cluster..."
        -- Default `cluster delete` (no --cascade) is a pure local uninstall:
        -- it does not query, gate on, or destroy the per-run AWS Pulumi
        -- backend, so it emits this notice instead of per-stack destroy
        -- traces (per the refactored lifecycle doctrine).
        deleteStdout
          `shouldContain` "Per-run AWS stacks (if any) were NOT destroyed by this local uninstall."
        deleteStdout `shouldContain` "Local RKE2 substrate: cleanup complete"
        deleteStdout `shouldContain` "Managed kubeconfig: removed"
        deleteStdout `shouldContain` "Retained host state:"
        deleteStdout `shouldNotContain` "Logged in to fake-rke2"
        deleteStdout `shouldNotContain` "Cannot find device"
        deleteStdout `shouldNotContain` "semodule: not found"
        -- Capturable-path only: the real inotify warning is out-of-band (see fakeSudoScript NOTE).
        deleteStdout `shouldNotContain` "Failed to allocate directory watch"
        deleteStdout `shouldNotContain` "Too many open files"
        deleteStdout `shouldNotContain` "Cleanup completed successfully"

        kubeconfigExists <- doesFileExist (tmpDir </> ".kube" </> "config")
        kubeconfigExists `shouldBe` False

        sudoRecord <- readFile (tmpDir </> "fake-rke2-state" </> "sudo.txt")
        sudoRecord `shouldContain` "/usr/local/bin/rke2-uninstall.sh"

    it "summarizes actionable uninstall failures while suppressing benign chatter" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)
        baseEnvVars <- fakeRke2Environment tmpDir
        let envVars =
              ("PRODBOX_FAKE_RKE2_UNINSTALL_EXISTS", "1")
                : ("PRODBOX_FAKE_RKE2_UNINSTALL_FAIL", "1")
                : baseEnvVars

        createDirectoryIfMissing True (tmpDir </> ".kube")
        writeFile (tmpDir </> ".kube" </> "config") "server: https://127.0.0.1:6443\n"

        (deleteExitCode, deleteStdout, deleteStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["cluster", "delete", "--yes"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        deleteExitCode `shouldBe` ExitFailure 1
        deleteStdout `shouldContain` "Uninstalling the local cluster..."
        deleteStdout `shouldNotContain` "Local RKE2 substrate: cleanup complete"
        deleteStderr `shouldContain` "failed to clean the local RKE2 substrate"
        deleteStderr `shouldContain` "umount: /var/lib/kubelet/pods/abc: target is busy"
        -- Capturable-path only: the real inotify warning is out-of-band (see fakeSudoScript NOTE).
        deleteStderr `shouldNotContain` "Failed to allocate directory watch"
        deleteStderr `shouldNotContain` "semodule: not found"
        deleteStderr `shouldNotContain` "Cannot find device"

    it "runs native rke2 delete after the IAM harness has cleared operational aws credentials" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfigWithBlankOperationalAwsAndConfiguredAdmin)
        envVars <- fakeRke2Environment tmpDir

        createDirectoryIfMissing True (tmpDir </> ".kube")
        writeFile (tmpDir </> ".kube" </> "config") "server: https://127.0.0.1:6443\n"

        (deleteExitCode, deleteStdout, deleteStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["cluster", "delete", "--yes"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        let deleteOutput =
              unlines
                [ "delete stdout:"
                , deleteStdout
                , "delete stderr:"
                , deleteStderr
                ]
        when (deleteExitCode /= ExitSuccess) (expectationFailure deleteOutput)
        deleteExitCode `shouldBe` ExitSuccess
        deleteStderr `shouldBe` ""
        deleteStdout `shouldContain` "Uninstalling the local cluster..."
        -- Default `cluster delete` (no --cascade) is a pure local uninstall:
        -- it does not query, gate on, or destroy the per-run AWS Pulumi
        -- backend, so it emits this notice instead of per-stack destroy
        -- traces (per the refactored lifecycle doctrine).
        deleteStdout
          `shouldContain` "Per-run AWS stacks (if any) were NOT destroyed by this local uninstall."
        deleteStdout `shouldContain` "Retained host state:"

    it "cluster delete --yes is a pure local uninstall that never refuses on per-run residue" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfigWithBlankOperationalAwsAndConfiguredAdmin)
        baseEnvVars <- fakeRke2Environment tmpDir
        -- Even with the per-run backend forced unreachable, the default
        -- delete never queries, gates on, or destroys it — it is a pure
        -- local cluster uninstall. (All per-run AWS destruction is --cascade.)
        let envVars =
              ("PRODBOX_TEST_RESIDUE_UNREACHABLE", "1")
                : baseEnvVars

        (deleteExitCode, deleteStdout, deleteStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["cluster", "delete", "--yes"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        let deleteOutput = unlines ["delete stdout:", deleteStdout, "delete stderr:", deleteStderr]
            combined = deleteStdout ++ deleteStderr
        when
          (deleteExitCode /= ExitSuccess)
          (expectationFailure ("expected a clean local uninstall, got failure:\n" ++ deleteOutput))
        deleteExitCode `shouldBe` ExitSuccess
        combined `shouldContain` "Uninstalling the local cluster..."
        -- No refusal and no per-run backend interaction.
        combined `shouldNotContain` "per-run Pulumi state backend"
        combined `shouldNotContain` "Refused:"

    it "Sprint 4.25: rke2 delete --yes is a no-op success with no RKE2 install" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfigWithBlankOperationalAwsAndConfiguredAdmin)
        -- Reproduce the real "cluster already gone" host: no RKE2 install AND an
        -- unreachable in-cluster MinIO state backend. The short-circuit must win
        -- over the residue gate's fail-closed refusal.
        envVars <- withNoRke2Install <$> fakeRke2Environment tmpDir

        (deleteExitCode, deleteStdout, deleteStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["cluster", "delete", "--yes"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        let combined = deleteStdout ++ deleteStderr
        deleteExitCode `shouldBe` ExitSuccess
        combined `shouldContain` "No RKE2 cluster to delete."
        -- The residue gate never ran, so neither its refusal nor a teardown
        -- narration may appear.
        combined `shouldNotContain` "per-run Pulumi state backend"
        combined `shouldNotContain` "Uninstalling the local cluster..."

    -- Sprint 4.88: this case pinned the defect. `--cascade` with no RKE2
    -- install exited 0 having reached no phase, which reads as a cascade that
    -- ran — and the only supported narration about the retained root comes
    -- from arms that reached a delete path, so the exit that reached none said
    -- nothing about it and still returned success. Local RKE2 absence is not
    -- per-run AWS absence.
    it "Sprint 4.88: rke2 delete --cascade with no RKE2 install refuses instead of reporting success" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfigWithBlankOperationalAwsAndConfiguredAdmin)
        envVars <- withNoRke2Install <$> fakeRke2Environment tmpDir

        (deleteExitCode, deleteStdout, deleteStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["cluster", "delete", "--yes", "--cascade"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        let combined = deleteStdout ++ deleteStderr
        deleteExitCode `shouldBe` ExitFailure 1
        -- It names the durable cleanup namespace it could not reach and the
        -- disposition it reports.
        combined `shouldContain` "durable cleanup run namespace"
        combined `shouldContain` "RecoveryPlaneNotEstablished"
        -- It makes no AWS-absence claim, and it does not emit the local-only
        -- no-cluster success line.
        combined `shouldContain` "makes no claim about per-run AWS stacks"
        combined `shouldNotContain` "No RKE2 cluster to delete."
        -- The cascade orchestration never started.
        combined `shouldNotContain` "confirm-MinIO"
        -- Sprint 6.6: this fixture authors AWS coordinates (a zone id, the
        -- state backend, a region), so the run now announces that it will ask
        -- AWS and then reports that it could not, because the temp repository
        -- has no `test-secrets.dhall` and stdin is not a TTY. It must still be
        -- a refusal that observed nothing, not a confirmation.
        combined `shouldContain` "will now query AWS read-only"
        combined `shouldContain` "owed and was not run"
        combined `shouldNotContain` "NOT an empty account"

    -- Sprint 6.6: nothing authored means there is no account for residue to be
    -- in. The arm refuses offline: it never announces a query and never asks
    -- for a credential, and it points at the local-only way out.
    it
      "Sprint 6.6: rke2 delete --cascade with no install and no authored AWS coordinate refuses offline"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters syntheticConfigFile)
        baseEnv <- withNoRke2Install <$> fakeRke2Environment tmpDir
        envVars <- fakeCascadeAwsEnvironment tmpDir "clean" baseEnv

        (deleteExitCode, deleteStdout, deleteStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["cluster", "delete", "--yes", "--cascade"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        let combined = deleteStdout ++ deleteStderr
        deleteExitCode `shouldBe` ExitFailure 1
        combined `shouldContain` "No AWS coordinate is authored"
        combined `shouldContain` "prodbox cluster delete --yes"
        combined `shouldContain` "durable cleanup run namespace"
        combined `shouldNotContain` "will now query AWS"
        -- The AWS CLI was never run, so no credential was ever needed.
        awsRan <- doesFileExist (tmpDir </> "fake-cascade-aws.txt")
        awsRan `shouldBe` False

    -- Sprint 6.6: the host-only trace. No RKE2 install, an authored zone, a
    -- credential from the harness fixture, and a fake `aws` that answers the
    -- two read-only calls this arm makes. It is the only way to see the second
    -- exit without leaving a cluster behind.
    it "Sprint 6.6: rke2 delete --cascade with no install confirms only after a read-only AWS query" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfigWithBlankOperationalAwsAndConfiguredAdmin)
        writePrivateTestSecrets
          tmpDir
          ( testSecretsDhallWithAdmin
              "CASCADEFIXTUREKEY"
              "cascade-fixture-secret"
              (fixtureAwsRegion FixtureUsEast1)
              Nothing
          )
        baseEnv <- withNoRke2Install <$> fakeRke2Environment tmpDir
        envVars <- fakeCascadeAwsEnvironment tmpDir "clean" baseEnv

        (deleteExitCode, deleteStdout, deleteStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["cluster", "delete", "--yes", "--cascade"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        let combined = deleteStdout ++ deleteStderr
        deleteExitCode `shouldBe` ExitSuccess
        -- What the zero means, and what it does not.
        combined `shouldContain` "NOT an empty account"
        combined `shouldContain` "route53.zone_id"
        combined `shouldContain` "(visible)"
        combined `shouldContain` "Retained roots surveyed, not read"
        combined `shouldContain` "not a completion receipt"
        combined `shouldContain` "the pulumi_state_backend bucket"
        combined `shouldNotContain` "reached no phase: no local RKE2 install"
        -- Every call it made was one of the two read-only verbs, and it asked
        -- the authored region as well as the global-service region.
        calls <- lines <$> readFile (tmpDir </> "fake-cascade-aws.txt")
        calls `shouldSatisfy` (not . null)
        calls
          `shouldSatisfy` all
            ( \line ->
                any
                  (`isPrefixOf` line)
                  [ "resourcegroupstaggingapi|get-resources|"
                  , "route53|get-hosted-zone|--id|Z1234567890ABC|--output|json"
                  ]
            )
        calls `shouldSatisfy` any (isInfixOf "route53|get-hosted-zone")
        calls `shouldSatisfy` any (isInfixOf ("--region|" ++ fixtureAwsRegion FixtureUsEast1))

    it
      "Sprint 6.6: rke2 delete --cascade with no install refuses when the credential cannot see the authored zone"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfigWithBlankOperationalAwsAndConfiguredAdmin)
        writePrivateTestSecrets
          tmpDir
          ( testSecretsDhallWithAdmin
              "CASCADEFIXTUREKEY"
              "cascade-fixture-secret"
              (fixtureAwsRegion FixtureUsEast1)
              Nothing
          )
        baseEnv <- withNoRke2Install <$> fakeRke2Environment tmpDir
        envVars <- fakeCascadeAwsEnvironment tmpDir "zone-missing" baseEnv

        (deleteExitCode, deleteStdout, deleteStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["cluster", "delete", "--yes", "--cascade"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        let combined = deleteStdout ++ deleteStderr
        deleteExitCode `shouldBe` ExitFailure 1
        combined `shouldContain` "could not be tied to this deployment's account"
        combined `shouldContain` "did NOT confirm absence"
        combined `shouldNotContain` "NOT an empty account"

    it "Sprint 6.6: rke2 delete --cascade with no install refuses and lists residue the sweep finds" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfigWithBlankOperationalAwsAndConfiguredAdmin)
        writePrivateTestSecrets
          tmpDir
          ( testSecretsDhallWithAdmin
              "CASCADEFIXTUREKEY"
              "cascade-fixture-secret"
              (fixtureAwsRegion FixtureUsEast1)
              Nothing
          )
        baseEnv <- withNoRke2Install <$> fakeRke2Environment tmpDir
        envVars <- fakeCascadeAwsEnvironment tmpDir "escaped" baseEnv

        (deleteExitCode, deleteStdout, deleteStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["cluster", "delete", "--yes", "--cascade"]) {cwd = Just tmpDir, env = Just envVars}
            ""

        let combined = deleteStdout ++ deleteStderr
        deleteExitCode `shouldBe` ExitFailure 1
        combined `shouldContain` "vpc/vpc-escaped"
        combined `shouldContain` "this cascade did not destroy"
        combined `shouldNotContain` "NOT an empty account"

    -- The dry-run and pure confirmation decision do not enter the
    -- operator-only decommission ceremony.
    it
      "nuke --dry-run renders the authenticated shared-bucket-terminal protocol"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfigForNuke)

        (exitCode, stdoutText, _) <-
          readCreateProcessWithExitCode
            (proc binary ["nuke", "--dry-run"]) {cwd = Just tmpDir}
            ""

        exitCode `shouldBe` ExitSuccess
        stdoutText `shouldContain` "PRODBOX_NUKE_PLAN"
        stdoutText `shouldContain` "PROTOCOL=signed-external-decommission-v1"
        -- The unique terminal moved from the shared bucket to the terminal
        -- receipt when the decommission node set gained its receipt-convergence
        -- node; this assertion still named the old terminal.
        stdoutText `shouldContain` "NODE=shared-object-bucket"
        stdoutText `shouldContain` "NODE=terminal-receipt (unique terminal)"
        stdoutText `shouldContain` "CONFIRMATION_LITERAL=NUKE EVERYTHING"

    it "classifies operator confirmation without invoking the ceremony" $ do
      Nuke.confirmationAccepted "destroy please" `shouldBe` False
      Nuke.confirmationAccepted "nuke everything" `shouldBe` False
      Nuke.confirmationAccepted Nuke.confirmationLiteral `shouldBe` True
      Nuke.confirmationAccepted (Nuke.confirmationLiteral ++ "  ") `shouldBe` True
      Nuke.confirmationAccepted (" " ++ Nuke.confirmationLiteral) `shouldBe` False

    it
      "Vault status and initialization use the caller-bound Bootstrap Broker state"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture tmpDir (tier0FixtureWithParameters validConfig)
        writePrivateTestSecrets tmpDir testSecretsDhall
        withFakeVaultLifecycleServer $ \vaultPort _stateRef -> do
          baseEnvVars <- fakeVaultLifecycleEnvironment tmpDir vaultPort
          let runVault args =
                runInstalledWithFakeAuthorityEnvironment
                  tmpDir
                  binary
                  ("vault" : args)
                  baseEnvVars

          (initialStatusExit, initialStatusStdout, initialStatusStderr) <- runVault ["status"]
          initialStatusExit `shouldBe` ExitSuccess
          initialStatusStderr `shouldBe` ""
          initialStatusStdout
            `shouldContain` "Vault status: {\"initialization_ambiguous\":false,\"initialized\":true,\"sealed\":false,\"storage_generation\":\"1\"}"

          (initExit, initStdout, initStderr) <- runVault ["init"]
          initExit `shouldBe` ExitSuccess
          initStderr `shouldBe` ""
          initStdout `shouldContain` "Vault already initialized."

    it "Sprint 1.37: aws stack reconcile refuses before Pulumi when Vault is sealed" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfigWithBlankOperationalAwsAndConfiguredAdmin)
        baseEnv <- fakeRke2Environment tmpDir
        withVaultFixtureServerSealStatus True $ \port -> do
          injectFixtureVaultAddress tmpDir port
          let envVars = filter ((/= "PRODBOX_TEST_PULUMI_VAULT_GATE") . fst) baseEnv

          (exitCode, stdoutText, stderrText) <-
            readCreateProcessWithExitCode
              (proc binary ["aws", "stack", "eks", "reconcile"]) {cwd = Just tmpDir, env = Just envVars}
              ""

          exitCode `shouldBe` ExitFailure 1
          stdoutText `shouldBe` ""
          stderrText `shouldContain` "Blocked: Vault is sealed."
          stderrText `shouldContain` "No preview/update/destroy was started."
          stderrText `shouldContain` "Run: prodbox vault unseal"
          pulumiRan <- doesFileExist (tmpDir </> "fake-rke2-state" </> "pulumi.txt")
          pulumiRan `shouldBe` False

    it "Sprint 4.77: aws stack destroy without --yes refuses, and --yes is not inert" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfigWithBlankOperationalAwsAndConfiguredAdmin)
        baseEnv <- fakeRke2Environment tmpDir
        -- Before Sprint 4.77 `--yes` was parsed, renamed `summary`, and then
        -- wildcarded at three of four sinks, so omitting it was byte-identical
        -- to passing it: the flag read as a confirmation and was not one. The
        -- command is intentionally non-interactive (CLAUDE.md), so the fix is
        -- to make the flag load-bearing rather than to add a prompt.
        (unconfirmedExit, unconfirmedStdout, unconfirmedStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["aws", "stack", "eks", "destroy"]) {cwd = Just tmpDir, env = Just baseEnv}
            ""
        unconfirmedExit `shouldBe` ExitFailure 1
        unconfirmedStdout `shouldBe` ""
        unconfirmedStderr `shouldContain` "Refusing to destroy without confirmation"
        unconfirmedStderr `shouldContain` "--yes"
        -- No Pulumi work may have started on the refusal path.
        pulumiRan <- doesFileExist (tmpDir </> "fake-rke2-state" </> "pulumi.txt")
        pulumiRan `shouldBe` False

        -- `--dry-run` still renders a plan without `--yes`: the gate lives
        -- inside the apply closure, not around the plan.
        (dryRunExit, dryRunStdout, _) <-
          readCreateProcessWithExitCode
            (proc binary ["aws", "stack", "eks", "destroy", "--dry-run"])
              { cwd = Just tmpDir
              , env = Just baseEnv
              }
            ""
        dryRunExit `shouldBe` ExitSuccess
        dryRunStdout `shouldContain` "COMMAND=eks-destroy"
        dryRunStdout `shouldContain` "CONFIRMED=false"

        -- And passing `--yes` is observably different: it reaches the Vault
        -- gate that the refusal never got to.
        (confirmedExit, _, confirmedStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["aws", "stack", "eks", "destroy", "--yes"])
              { cwd = Just tmpDir
              , env = Just baseEnv
              }
            ""
        confirmedStderr `shouldNotContain` "Refusing to destroy without confirmation"
        confirmedExit `shouldNotBe` ExitSuccess

    it "cluster federation register refuses the removed reusable-token bootstrap surface" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        withFakeVaultLifecycleServer $ \vaultPort stateRef -> do
          modifyMVar stateRef $ \_ -> pure (FakeVaultLifecycleState True False 3, ())
          writeTier0Fixture
            tmpDir
            ( tier0FixtureWithContext
                (\ctx -> ctx {Tier0.vault_address = Text.pack (fakeVaultAddress vaultPort)})
                validConfig
            )
          baseEnv <- fakeRke2Environment tmpDir
          let envVars =
                ("PRODBOX_TEST_HOST_VAULT_TOKEN", "fake-parent-root-token")
                  : filter ((/= "PRODBOX_TEST_HOST_VAULT_TOKEN") . fst) baseEnv
              childKubeconfig = tmpDir </> "child.kubeconfig"
          writeFile childKubeconfig "apiVersion: v1\nkind: Config\n"

          (exitCode, stdoutText, stderrText) <-
            readCreateProcessWithExitCode
              ( proc
                  binary
                  [ "cluster"
                  , "federation"
                  , "register"
                  , "child-a"
                  , "--child-vault-address"
                  , "http://child-vault.example:8200"
                  , "--child-kubeconfig"
                  , childKubeconfig
                  , "--child-kubeconfig-reference"
                  , "vault:secret/clusters/child-a/kubeconfig"
                  , "--child-account-id"
                  , "123456789012"
                  , "--child-endpoint"
                  , "api=https://api.child-a.example"
                  , "--child-pulumi-stack"
                  , "aws-eks=org/prodbox-child-a/aws-eks"
                  ]
              )
                { cwd = Just tmpDir
                , env = Just envVars
                }
              ""

          exitCode `shouldBe` ExitFailure 1
          stdoutText `shouldBe` ""
          stderrText `shouldContain` "requires the Bootstrap Broker's receipt-bound child-custody workflow"
          stderrText
            `shouldContain` "reusable parent root-token and direct Vault write transport has been removed"

    it
      "selected authority authentication refuses when the caller signer is unavailable"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir ->
        withFakeVaultServer $ \vaultPort ->
          withFakeGatewayDaemonServer
            []
            $ \gatewayPort requestsRef -> do
              sourceBinary <- getExecutablePath
              let fixtureBinary = tmpDir </> "selected-authority-fixture"
              copyFile sourceBinary fixtureBinary
              setFileMode fixtureBinary 0o700
              writeRepoMarkers tmpDir
              writeTier0Fixture
                tmpDir
                ( tier0FixtureWithContext
                    (\ctx -> ctx {Tier0.vault_address = Text.pack (fakeVaultAddress vaultPort)})
                    validConfigForNuke
                )
              createDirectoryIfMissing True (tmpDir </> ".kube")
              writeFile (tmpDir </> ".kube" </> "config") "server: https://127.0.0.1:6443\n"
              envVars <- fakeRke2Environment tmpDir
              let kubectlPath = tmpDir </> "bin" </> "kubectl"
              kubectlScript <- readFile kubectlPath
              length kubectlScript `seq`
                writeFile
                  kubectlPath
                  ( unlines
                      ( take 1 (lines kubectlScript)
                          ++ ["printf '%s\\n' \"$KUBECONFIG\" >> \"$PRODBOX_FAKE_RKE2_RECORD_DIR/kubeconfig-used.txt\""]
                          ++ drop 1 (lines kubectlScript)
                      )
                  )
              let fixtureEnv =
                    ("KUBECONFIG", tmpDir </> "foreign-kubeconfig")
                      : ("PRODBOX_TEST_GATEWAY_NODEPORT", show gatewayPort)
                      : ("PRODBOX_TEST_HOST_VAULT_TOKEN", "fake-root-token")
                      : filter ((/= "KUBECONFIG") . fst) envVars

              (exitCode, stdoutText, stderrText) <-
                readCreateProcessWithExitCode
                  ( proc
                      fixtureBinary
                      [ "--fixture-selected-authority-refusal"
                      , tmpDir
                      , tmpDir </> "fake-rke2-kubeconfig"
                      ]
                  )
                    { cwd = Just tmpDir
                    , env = Just fixtureEnv
                    }
                  ""

              exitCode `shouldBe` ExitFailure 1
              stdoutText `shouldBe` ""
              stderrText `shouldContain` "caller-bound Lifecycle Authority Transit signer"
              used <- lines <$> readFile (tmpDir </> "fake-rke2-state" </> "kubeconfig-used.txt")
              used `shouldSatisfy` (not . null)
              used `shouldSatisfy` all (== tmpDir </> "fake-rke2-kubeconfig")
              requests <- readMVar requestsRef
              requests
                `shouldSatisfy` all (not . ("POST /v1/object-store/pulumi/" `isInfixOf`))

    it "projects ZeroSSL external account binding into the supported ClusterIssuer reconcile" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters zeroSslConfig)
        envVars <- (("PRODBOX_TEST_HOST_VAULT_TOKEN", "fake-root-token") :) <$> fakeRke2Environment tmpDir

        -- The refactor moved the ZeroSSL ACME ClusterIssuer (and the Route 53
        -- DNS bootstrap) behind `--with-edge`; bare `cluster reconcile` stands
        -- up a local-only cluster with no public edge. The EAB projection this
        -- test asserts therefore lives on the `--with-edge` path.
        (upExitCode, upStdout, upStderr) <-
          runRke2ReconcileWithFakeGateway
            tmpDir
            binary
            ["cluster", "reconcile", "--with-edge"]
            envVars

        when
          (upExitCode /= ExitSuccess)
          ( expectationFailure
              ( unlines
                  [ "cluster reconcile stdout:"
                  , upStdout
                  , "cluster reconcile stderr:"
                  , upStderr
                  ]
              )
          )
        upExitCode `shouldBe` ExitSuccess
        upStderr
          `shouldContain` "Retrying Harbor publication for mirror target 127.0.0.1:30080/prodbox/code-server-mirror:4.98.2"
        upStdout `shouldContain` "Kubernetes control plane is running"

        issuerManifest <-
          readAppliedManifestContaining (tmpDir </> "fake-rke2-state") "\"ClusterIssuer\""
        issuerManifest `shouldContain` "\"ClusterIssuer\""
        issuerManifest `shouldNotContain` "\"externalAccountBinding\""
        materializerManifest <-
          readAppliedManifestContaining (tmpDir </> "fake-rke2-state") "acme-eab-secret-materializer"
        materializerManifest `shouldContain` "\"Job\""
        materializerManifest `shouldContain` "\"name\":\"acme-eab-secret-materializer\""
        materializerManifest `shouldContain` "\"namespace\":\"cert-manager\""
        -- The EAB fields are projected inside the Vault-login materializer and
        -- patched into the issuer; neither value is rendered by the host.
        -- materializer + its RBAC are present; the HMAC value never appears.
        materializerManifest `shouldContain` "vault-materialized"
        materializerManifest `shouldContain` "hmac_key"
        materializerManifest `shouldNotContain` "test-eab-hmac-key"
        materializerManifest `shouldNotContain` "\"stringData\":{\"secret\":"

    it "runs native gateway start and fails gracefully with a missing config" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        let configPath = tmpDir </> "nonexistent-gateway.dhall"

        (exitCode, _, stderrText) <-
          readCreateProcessWithExitCode
            (proc binary ["gateway", "start", "--config", configPath]) {cwd = Just tmpDir}
            ""

        exitCode `shouldBe` ExitFailure 1
        stderrText `shouldContain` "gateway daemon Dhall config"

    it "runs native gateway start without requiring repo markers" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        let configPath = tmpDir </> "nonexistent-gateway.dhall"

        (exitCode, _, stderrText) <-
          readCreateProcessWithExitCode
            (proc binary ["gateway", "start", "--config", configPath]) {cwd = Just tmpDir}
            ""

        exitCode `shouldBe` ExitFailure 1
        stderrText `shouldContain` "gateway daemon Dhall config"
        stderrText `shouldNotContain` "Could not locate the repository root"

    forM_ [False, True] $ \markers ->
      it
        ("dispatches the closed controller without schema materialization, repo markers=" ++ show markers)
        $ withSystemTempDirectory "prodbox-rpc-controller-cli"
        $ \tmpDir -> do
          binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
          when markers $ do
            writeFile (tmpDir </> "prodbox.cabal") "controller fixture repository marker\n"
            createDirectoryIfMissing True (tmpDir </> "DEVELOPMENT_PLAN")
            writeFile (tmpDir </> "DEVELOPMENT_PLAN" </> "README.md") "controller fixture repository marker\n"
          let arguments =
                [ "internal-rpc-birth-controller"
                , "--config"
                , tmpDir </> "unopened-settings.cbor"
                , "--request"
                , tmpDir </> "unopened-request.cbor"
                , "--input-fingerprint"
                , replicate 64 'a'
                , "--operation-key"
                , replicate 64 'b'
                , "--outer-ns"
                , "500"
                , "--work-ns"
                , "100"
                , "--hard-ns"
                , "200"
                , "--stop-ns"
                , "300"
                , "--finish-ns"
                , "400"
                ]
          (exitCode, _, stderrText) <-
            readCreateProcessWithExitCode (proc binary arguments) {cwd = Just tmpDir} ""
          exitCode `shouldBe` ExitFailure 1
          stderrText `shouldContain` "RpcBirthControllerInputRefused"
          stderrText `shouldNotContain` "not the repository root"
          doesFileExist (tmpDir </> "prodbox-config-types.dhall") `shouldReturn` False
          doesFileExist (tmpDir </> "test-secrets-types.dhall") `shouldReturn` False

    it "requires an explicit mounted config for native Bootstrap Broker start" $ do
      binary <- resolveBinaryPath

      (exitCode, _, stderrText) <-
        readCreateProcessWithExitCode
          (proc binary ["bootstrap-broker", "start"])
          ""

      exitCode `shouldBe` ExitFailure 1
      stderrText `shouldContain` "--config PATH"

    it "runs native Bootstrap Broker start without requiring repo markers" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        let configPath = tmpDir </> "nonexistent-bootstrap-broker.dhall"

        (exitCode, _, stderrText) <-
          readCreateProcessWithExitCode
            ( proc
                binary
                [ "bootstrap-broker"
                , "start"
                , "--config"
                , configPath
                ]
            )
              { cwd = Just tmpDir
              }
            ""

        exitCode `shouldBe` ExitFailure 1
        stderrText `shouldContain` "bootstrap-broker Dhall config"
        stderrText `shouldNotContain` "Could not locate the repository root"

    it "validates and renders the mounted Bootstrap Broker config in dry-run mode" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        let configPath = tmpDir </> "bootstrap-broker.dhall"
            planPath = tmpDir </> "bootstrap-broker.plan"
        writeFile configPath bootstrapBrokerConfig

        (exitCode, stdoutText, stderrText) <-
          readCreateProcessWithExitCode
            ( proc
                binary
                [ "bootstrap-broker"
                , "start"
                , "--config"
                , configPath
                , "--dry-run"
                , "--plan-file"
                , planPath
                ]
            )
              { cwd = Just tmpDir
              }
            ""

        when
          (exitCode /= ExitSuccess)
          ( expectationFailure
              ("broker dry-run stdout:\n" ++ stdoutText ++ "\nbroker dry-run stderr:\n" ++ stderrText)
          )
        persistedPlan <- readFile planPath
        exitCode `shouldBe` ExitSuccess
        stderrText `shouldBe` ""
        stdoutText `shouldBe` persistedPlan
        stdoutText `shouldContain` "BOOTSTRAP_BROKER_START_PLAN"
        stdoutText `shouldContain` "RUNTIME_ROLE=bootstrap-broker"
        stdoutText `shouldContain` "LISTENER=127.0.0.1:18443"
        stdoutText `shouldContain` "AUTHENTICATOR=kubernetes-tokenreview"
        stdoutText `shouldContain` "MUTATION_ENGINE=production"
        stdoutText `shouldNotContain` "password"
        stdoutText `shouldNotContain` "root_token"

    it "runs native config setup through the built frontend with a fake AWS CLI" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        repoRoot <- getCurrentDirectory
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        copySchema repoRoot tmpDir
        envVars <- fakeAwsEnvironment tmpDir

        let inputText vaultPort =
              unlines
                [ ""
                , "ADMINKEY"
                , "admin-secret"
                , ""
                , -- Sprint 1.91: the admin-region prompt has no pre-fill. It used
                  -- to accept an empty answer because the prompt offered a
                  -- compiled region, so this fixture was exercising the
                  -- invented value rather than an operator's choice.
                  (fixtureAwsRegion FixtureUsEast1)
                , "1"
                , "1"
                , "test.example.test"
                , ""
                , "ops@example.test"
                , "integration-cluster"
                , "integration-machine"
                , fakeVaultAddress vaultPort
                , "http://127.0.0.1:39000"
                , "1"
                , ""
                , ""
                , ""
                , ""
                , ""
                , ""
                , ""
                , ""
                , ""
                ]

        (exitCode, stdoutText, stderrText) <-
          runInstalledWithFakeAuthorityEnvironmentInputForVault
            tmpDir
            binary
            ["config", "setup"]
            envVars
            inputText

        let failureOutput =
              unlines
                [ "config setup stdout:"
                , stdoutText
                , "config setup stderr:"
                , stderrText
                ]
        when (exitCode /= ExitSuccess) (expectationFailure failureOutput)
        exitCode `shouldBe` ExitSuccess
        stderrText `shouldBe` ""
        stdoutText `shouldContain` "ROUTE53_ZONE_ID=Z1234567890ABC"
        stdoutText `shouldContain` "TIER0_ONLY=true"
        stdoutText `shouldNotContain` "AWS_ACCESS_KEY_ID="
        configText <- readFile (tmpDir </> "prodbox.dhall")
        -- Sprint 1.42 Part B: `config setup` now authors the operator config into
        -- prodbox.dhall's `parameters` block, rendered canonically by Dhall.inject
        -- (no `Config.SecretRef.Vault` schema-qualified syntax). The sensitive
        -- AWS access key is a Vault pointer (mount/path/field), never plaintext.
        configText `shouldContain` ">.Vault"
        configText `shouldContain` "path = \"aws/lifecycle-provider\""
        configText `shouldContain` "field = \"access_key_id\""
        configText `shouldNotContain` "AKIAFAKESETUP"
        configText `shouldContain` "zone_id = \"Z1234567890ABC\""
        configText `shouldContain` "demo_fqdn = \"test.example.test\""
        configText `shouldContain` "cluster_id = \"integration-cluster\""
        configText `shouldContain` "machine_id = \"integration-machine\""
        configText `shouldContain` "vault_address = \"http://127.0.0.1:"
        configText `shouldNotContain` "vault_address = \"http://127.0.0.1:31820\""
        configText `shouldContain` "minio_endpoint = \"http://127.0.0.1:39000\""
        configText `shouldContain` ".AdvertiseLayer2"
        configText `shouldNotContain` "public_edge_advertisement_mode = Some \"l2\""
        decodedConfig <- Settings.loadConfigFileAtPath (tmpDir </> "prodbox.dhall")
        case decodedConfig of
          Left err -> expectationFailure ("generated prodbox.dhall did not decode: " <> err)
          Right config ->
            Settings.public_edge_advertisement_mode (Settings.deployment config)
              `shouldBe` Just Settings.AdvertiseLayer2
        -- EAB references are non-secret schema coordinates only. Config setup
        -- neither prompts for nor writes either EAB field.
        configText `shouldContain` "eab_hmac_key = Some"
        configText `shouldContain` "field = \"hmac_key\""
        setupVaultAccessKeyExists <-
          doesFileExist
            (fakeVaultKvDir tmpDir </> "secret" </> lifecycleProviderVaultPath </> "access_key_id")
        setupVaultAccessKeyExists `shouldBe` False
        setupVaultEabKeyIdExists <-
          doesFileExist
            (fakeVaultKvDir tmpDir </> "secret" </> acmeEabVaultPath </> "key_id")
        setupVaultEabKeyIdExists `shouldBe` False
        setupVaultEabHmacKeyExists <-
          doesFileExist
            (fakeVaultKvDir tmpDir </> "secret" </> acmeEabVaultPath </> "hmac_key")
        setupVaultEabHmacKeyExists `shouldBe` False
        jsonExists <- doesFileExist (tmpDir </> "prodbox-config.json")
        jsonExists `shouldBe` False

    it "refuses aws setup when the authenticated Credential Provisioner is unavailable" $
      withSystemTempDirectory "prodbox-hs-cli" $ \tmpDir -> do
        repoRoot <- getCurrentDirectory
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        copySchema repoRoot tmpDir
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfigWithBlankOperationalAwsAndConfiguredAdmin)
        writePrivateTestSecrets
          tmpDir
          ( testSecretsDhallWithAdmin
              "CONFIGADMINKEY"
              "config-admin-secret"
              (fixtureAwsRegion FixtureUsWest2)
              Nothing
          )
        envVars <- fakeAwsEnvironment tmpDir

        let setupInput = unlines ["ADMINKEY", "admin-secret", "", "", "1"]
        (setupExitCode, setupStdout, setupStderr) <-
          runInstalledWithFakeAuthorityEnvironmentInput
            tmpDir
            binary
            ["aws", "setup", "--tier", "full"]
            envVars
            setupInput

        setupExitCode `shouldBe` ExitFailure 1
        setupStdout `shouldContain` "AWS setup creates or refreshes"
        setupStderr
          `shouldContain` "requires the executable authenticated Credential Provisioner"
        setupStderr `shouldContain` "refusing IAM mutation"
        createUserRecord <- doesFileExist (tmpDir </> "fake-aws-state" </> "iam_create_user_access_key_id")
        createUserRecord `shouldBe` False

    it
      "refuses native aws-iam setup before mutation when descriptor-bound cleanup is unavailable"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir -> do
        repoRoot <- getCurrentDirectory
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        copySchema repoRoot tmpDir
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfigWithLeakedOperationalAwsAndConfiguredAdmin)
        writePrivateTestSecrets
          tmpDir
          ( testSecretsDhallWithAdmin
              "CONFIGADMINKEY"
              "config-admin-secret"
              (fixtureAwsRegion FixtureUsWest2)
              Nothing
          )
        seedFakeVaultAwsCredentials
          tmpDir
          lifecycleProviderVaultPath
          "AKIALEAKED"
          "leaked-secret"
          Nothing
          (fixtureAwsRegion FixtureUsWest2)
        seedFakeAwsHarnessState tmpDir
        envVars <- fakeAwsHarnessEnvironment tmpDir binary

        (exitCode, stdoutText, stderrText) <-
          runInstalledWithFakeAuthorityEnvironment
            tmpDir
            binary
            ["test", "integration", "aws-iam"]
            envVars

        exitCode `shouldBe` ExitFailure 1
        stdoutText `shouldContain` "Phase 1/2: validating integration prerequisites"
        stdoutText `shouldNotContain` "Phase 2/2: running test suites"
        stderrText
          `shouldContain` "Lifecycle-owned AWS harness cleanup failed"
        stderrText
          `shouldContain` "descriptor-bound cleanup response/status mismatch"

        configAfterHarness <- readFile (tmpDir </> "prodbox.dhall")
        configAfterHarness `shouldContain` "path = \"aws/lifecycle-provider\""
        configAfterHarness `shouldContain` "field = \"access_key_id\""
        configAfterHarness `shouldNotContain` "AKIALEAKED"
        configAfterHarness `shouldNotContain` "leaked-secret"
        vaultAccessKeyAfterHarness <-
          readFakeVaultField tmpDir "secret" lifecycleProviderVaultPath "access_key_id"
        vaultSecretKeyAfterHarness <-
          readFakeVaultField tmpDir "secret" lifecycleProviderVaultPath "secret_access_key"
        vaultAccessKeyAfterHarness `shouldBe` "AKIALEAKED"
        vaultSecretKeyAfterHarness `shouldBe` "leaked-secret"

        deletedUsers <- doesFileExist (tmpDir </> "fake-aws-state" </> "iam_deleted_users")
        deletedUsers `shouldBe` False
        deletedPolicies <-
          doesFileExist (tmpDir </> "fake-aws-state" </> "iam_deleted_policies")
        deletedPolicies `shouldBe` False
        deletedRoles <-
          doesFileExist (tmpDir </> "fake-aws-state" </> "iam_deleted_roles")
        deletedRoles `shouldBe` False

    it
      "does not bypass external-material ingress while running the IAM-only harness"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir -> do
        repoRoot <- getCurrentDirectory
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        copySchema repoRoot tmpDir
        writeTier0Fixture
          tmpDir
          (tier0FixtureWithParameters validConfigWithLeakedOperationalAwsAndConfiguredAdmin)
        writePrivateTestSecrets
          tmpDir
          ( testSecretsDhallWithAdminAndAcmeEab
              "CONFIGADMINKEY"
              "config-admin-secret"
              (fixtureAwsRegion FixtureUsWest2)
              Nothing
              "test-eab-key-id"
              "test-eab-hmac-key"
          )
        seedFakeVaultAwsCredentials
          tmpDir
          lifecycleProviderVaultPath
          "AKIALEAKED"
          "leaked-secret"
          Nothing
          (fixtureAwsRegion FixtureUsWest2)
        seedFakeAwsHarnessState tmpDir
        envVars <- fakeAwsHarnessEnvironment tmpDir binary

        (exitCode, _stdoutText, _stderrText) <-
          runInstalledWithFakeAuthorityEnvironment
            tmpDir
            binary
            ["test", "integration", "aws-iam"]
            envVars

        exitCode `shouldBe` ExitFailure 1

        -- An IAM-only run has no attested ingress Job and therefore must not
        -- project the fixture through a direct host/Vault fallback.
        eabKeyIdExists <-
          doesFileExist
            (fakeVaultKvDir tmpDir </> "secret" </> acmeEabVaultPath </> "key_id")
        eabHmacKeyExists <-
          doesFileExist
            (fakeVaultKvDir tmpDir </> "secret" </> acmeEabVaultPath </> "hmac_key")
        eabKeyIdExists `shouldBe` False
        eabHmacKeyExists `shouldBe` False

    it
      "runs native aws quota inspection and request flows through the built frontend with a fake AWS CLI"
      $ withSystemTempDirectory "prodbox-hs-cli"
      $ \tmpDir -> do
        binary <- resolveBinaryPath >>= \b -> installOperatorBinaryInDir b tmpDir
        writeRepoMarkers tmpDir
        envVars <- fakeAwsEnvironment tmpDir
        -- Sprint 1.91: the fourth line is the admin region, which the prompt no
        -- longer pre-fills with a compiled value.
        let commandInput = unlines ["ADMINKEY", "admin-secret", "", (fixtureAwsRegion FixtureUsEast1), "1"]

        (checkExitCode, checkStdout, checkStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["aws", "quotas", "check"]) {cwd = Just tmpDir, env = Just envVars}
            commandInput

        checkExitCode `shouldBe` ExitSuccess
        checkStderr `shouldBe` ""
        checkStdout `shouldContain` "Supported AWS Quotas"
        checkStdout `shouldContain` "Running On-Demand Standard vCPU"
        checkStdout `shouldContain` "Elastic IP addresses"

        (requestExitCode, requestStdout, requestStderr) <-
          readCreateProcessWithExitCode
            (proc binary ["aws", "quotas", "request", "--tier", "core"]) {cwd = Just tmpDir, env = Just envVars}
            commandInput

        requestExitCode `shouldBe` ExitSuccess
        requestStderr `shouldBe` ""
        requestStdout `shouldContain` "Requested AWS Quotas"
        requestStdout `shouldContain` "PENDING"
        requestStdout `shouldContain` "Running On-Demand Standard vCPU"

-- | Isolated helper mode for the process-level diagnostic assertion in the
-- RKE2 integration case. A mutation is deliberately selected without carrying
-- any of its declared dependency admissions, so the production caller must
-- render the typed refusal to stderr before returning an exit code.
runRke2AdmissionRefusalFixture :: FilePath -> IO ExitCode
runRke2AdmissionRefusalFixture repoRoot = do
  validated <-
    Settings.validateAndLoadSettingsAtPath
      (repoRoot </> "prodbox.dhall")
      repoRoot
  case validated of
    Left err -> fixtureSetupFailure err
    Right settings ->
      case ComponentGraph.validateComponentGraph
        (Settings.components (Settings.validatedConfig settings)) of
        Left err -> fixtureSetupFailure (show err)
        Right dag ->
          fst
            <$> Rke2.runAnchoredReconcileSteps
              repoRoot
              settings
              dag
              (const (pure ExitSuccess))
              noAdmissions
              [Rke2.StepAuthorityBackupChartReady]
 where
  fixtureSetupFailure detail = do
    BS8.hPutStrLn IO.stderr (BS8.pack ("admission-refusal fixture setup failed: " ++ detail))
    pure (ExitFailure 2)

-- | Isolated helper mode for the runbook diagnostic assertion. The test owns
-- a silent failing fake at the canonical child-binary path; this function runs
-- the production wrapper unchanged so stdout/stderr remain process-observable.
runRunbookFailureFixture :: FilePath -> IO ExitCode
runRunbookFailureFixture repoRoot = do
  environment <- getEnvironment
  TestRunner.runRunbookCommand
    repoRoot
    environment
    ["cluster", "reconcile", "--with-edge"]

-- | Isolated process-group fixture for the streamed-child Ctrl-C regression.
-- The marker proves the child exists before the parent test signals the group;
-- the long sleep makes the child, rather than process startup, own the signal.
runStreamingCancellationFixture :: FilePath -> IO ExitCode
runStreamingCancellationFixture markerPath = do
  result <-
    Subprocess.runStreaming
      Subprocess.Subprocess
        { Subprocess.subprocessPath = "/bin/sh"
        , Subprocess.subprocessArguments =
            [ "-c"
            , "printf 'ready\\n' > \"$1\"; exec sleep 300"
            , "prodbox-streaming-cancellation"
            , markerPath
            ]
        , Subprocess.subprocessEnvironment = Nothing
        , Subprocess.subprocessWorkingDirectory = Nothing
        }
  case result of
    Left err -> do
      BS8.hPutStrLn IO.stderr (BS8.pack (show err))
      pure (ExitFailure 2)
    Right exitCode -> pure exitCode

waitForStreamingCancellationMarker :: FilePath -> ProcessHandle -> IO ()
waitForStreamingCancellationMarker markerPath processHandle = go (500 :: Int)
 where
  go remaining = do
    markerExists <- doesFileExist markerPath
    if markerExists
      then pure ()
      else do
        childExit <- getProcessExitCode processHandle
        case (remaining, childExit) of
          (_, Just exitCode) ->
            expectationFailure
              ("streaming-cancellation fixture exited before its child marker: " ++ show exitCode)
          (0, Nothing) -> do
            terminateProcess processHandle
            void (waitForProcess processHandle)
            expectationFailure "streaming-cancellation fixture did not publish its child marker"
          (_, Nothing) -> threadDelay 10000 >> go (remaining - 1)

resolveBinaryPath :: IO FilePath
resolveBinaryPath = do
  repoRoot <- getCurrentDirectory
  currentEnvironment <- getEnvironment
  buildEnvironment <- addBuildSupportEnvironment repoRoot currentEnvironment
  (buildExitCode, _, buildStderr) <-
    readCreateProcessWithExitCode
      (proc "cabal" ["build", "--builddir=.build", "exe:prodbox"])
        { cwd = Just repoRoot
        , env = Just buildEnvironment
        }
      ""
  case buildExitCode of
    ExitSuccess -> pure ()
    _ -> expectationFailure buildStderr
  syncResult <- syncBuiltOperatorBinary repoRoot buildEnvironment
  case syncResult of
    Left err -> expectationFailure err >> pure ""
    Right binaryPath -> do
      binaryPath `shouldBe` canonicalOperatorBinaryPath repoRoot
      pure binaryPath

generationHostEnvironment :: String -> IO [(String, String)]
generationHostEnvironment capacity = do
  environment <- getEnvironment
  pure
    ( ("PRODBOX_TEST_HOST_CAPACITY", capacity)
        : filter ((/= "PRODBOX_TEST_HOST_CAPACITY") . fst) environment
    )

-- One accepted Unix connection serves both requests when requested. The
-- fixture is local and never contacts the configured Docker daemon.
withDockerInfoFixture :: BS8.ByteString -> Bool -> (FilePath -> IO a) -> IO a
withDockerInfoFixture body secondRequest = withDockerInfoFixtureMode body secondRequest False False BS8.empty

withDockerInfoFixtureWithClose :: BS8.ByteString -> (FilePath -> IO a) -> IO a
withDockerInfoFixtureWithClose body = withDockerInfoFixtureMode body False True False BS8.empty

withDockerInfoFixtureUnframed :: BS8.ByteString -> (FilePath -> IO a) -> IO a
withDockerInfoFixtureUnframed body = withDockerInfoFixtureMode body False False True BS8.empty

withDockerInfoFixtureTrailing :: BS8.ByteString -> (FilePath -> IO a) -> IO a
withDockerInfoFixtureTrailing body = withDockerInfoFixtureMode body True False False (BS8.pack "unexpected-buffered-bytes")

withDockerInfoFixtureMode
  :: BS8.ByteString -> Bool -> Bool -> Bool -> BS8.ByteString -> (FilePath -> IO a) -> IO a
withDockerInfoFixtureMode body secondRequest closeHeader unframed trailing action =
  withSystemTempDirectory "prodbox-connected-info" $ \directory -> do
    let path = directory </> "docker.sock"
    bracket (socket AF_UNIX Stream defaultProtocol) close $ \listener -> do
      bind listener (SockAddrUnix path)
      listen listener 1
      outcome <- newEmptyMVar
      let serve = do
            (connection, _) <- accept listener
            bracket (pure connection) close $ \client -> do
              request <- readHeaders client
              unless (BS8.pack "GET /info HTTP/1.1\r\n" `BS8.isPrefixOf` request) $
                fail "unexpected info request"
              sendAll
                client
                ( BS8.pack "HTTP/1.1 200 OK"
                    <> (if unframed then BS8.empty else BS8.pack ("\r\nContent-Length: " ++ show (BS8.length body)))
                    <> BS8.pack (if closeHeader then "\r\nConnection: keep-alive, ClOsE\r\n\r\n" else "\r\n\r\n")
                    <> body
                    <> trailing
                )
              when secondRequest $ do
                next <- readHeaders client
                unless (BS8.pack "GET /_ping HTTP/1.1\r\n" `BS8.isPrefixOf` next) $
                  fail "unexpected second request"
                let reply = sendAll client (BS8.pack "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK")
                if BS8.null trailing
                  then reply
                  else void (try reply :: IO (Either SomeException ()))
              when (not secondRequest && not closeHeader && not unframed) $ void (recv client 1)
      bracket (forkIO (try serve >>= putMVar outcome)) killThread $ \_ -> do
        result <- action path
        completed <- timeout 3000000 (takeMVar outcome)
        case completed of
          Nothing -> expectationFailure "Docker fixture did not settle"
          Just (Left failure) -> expectationFailure ("Docker fixture failed: " ++ show (failure :: SomeException))
          Just (Right ()) -> pure ()
        pure result
 where
  readHeaders connection = go BS8.empty
   where
    go bytes
      | BS8.pack "\r\n\r\n" `BS8.isInfixOf` bytes = pure bytes
      | BS8.length bytes >= 16384 = fail "fixture request headers too large"
      | otherwise = do
          more <- recv connection 4096
          if BS8.null more then fail "fixture request ended early" else go (bytes <> more)

-- One local connection accepts exactly one bounded load request. It is a
-- protocol fixture, not an actual Docker image load or settlement witness.
withDockerNetworkBindingFixture :: FilePath -> String -> String -> String -> IO Bool -> IO a -> IO a
withDockerNetworkBindingFixture path networkId generation operation changed action =
  bracket (socket AF_UNIX Stream defaultProtocol) close $ \listener -> do
    bind listener (SockAddrUnix path)
    listen listener 1
    let headers connection bytes
          | BS8.pack "\r\n\r\n" `BS8.isInfixOf` bytes = pure bytes
          | BS8.length bytes >= 16384 = fail "fixture headers too large"
          | otherwise = do
              more <- recv connection 4096
              if BS8.null more then fail "fixture request ended early" else headers connection (bytes <> more)
        response body = BS8.pack ("HTTP/1.1 200 OK\r\nContent-Length: " ++ show (BS8.length body) ++ "\r\n\r\n") <> body
        serve = bracket (fst <$> accept listener) close $ \connection ->
          let
            loop = do
              request <- headers connection BS8.empty
              wrong <- changed
              let first = BS8.unpack (BS8.takeWhile (/= '\r') request)
                  body
                    | "GET /info " `isPrefixOf` first = BS8.pack "{\"ID\":\"daemon-a\"}"
                    | "GET /networks?" `isPrefixOf` first =
                        LazyBS8.toStrict $
                          Aeson.encode
                            [ Aeson.object
                                [ AesonKey.fromString "Name" Aeson..= ("prodbox-t-run" :: String)
                                , AesonKey.fromString "Id" Aeson..= networkId
                                ]
                            ]
                    | first == "GET /networks/" ++ networkId ++ " HTTP/1.1" =
                        LazyBS8.toStrict $
                          Aeson.encode $
                            Aeson.object
                              [ AesonKey.fromString "Name" Aeson..= ("prodbox-t-run" :: String)
                              , AesonKey.fromString "Id" Aeson..= networkId
                              , AesonKey.fromString "Driver" Aeson..= ("bridge" :: String)
                              , AesonKey.fromString "EnableIPv6" Aeson..= True
                              , AesonKey.fromString "Options"
                                  Aeson..= Aeson.object
                                    [ AesonKey.fromString "com.docker.network.bridge.enable_ip_masquerade" Aeson..= ("true" :: String)
                                    , AesonKey.fromString "com.docker.network.driver.mtu" Aeson..= ("1500" :: String)
                                    ]
                              , AesonKey.fromString "Labels"
                                  Aeson..= Aeson.object
                                    [ AesonKey.fromString "io.prodbox.deployment" Aeson..= ("prodbox-t-run" :: String)
                                    , AesonKey.fromString "io.prodbox.generation" Aeson..= generation
                                    , AesonKey.fromString "io.prodbox.operation" Aeson..= (if wrong then "foreign" else operation)
                                    ]
                              , AesonKey.fromString "IPAM"
                                  Aeson..= Aeson.object
                                    [ AesonKey.fromString "Config"
                                        Aeson..= [Aeson.object [AesonKey.fromString "Subnet" Aeson..= ("fc00:c1c8:9c54:6b75::/64" :: String)]]
                                    ]
                              ]
                    | otherwise = BS8.empty
              when (BS8.null body) (fail ("unexpected network fixture request: " ++ first))
              sendAll connection (response body)
              loop
           in
            loop
    bracket (forkIO (void (try serve :: IO (Either SomeException ())))) killThread (const action)

withDockerNodeRunFixture :: FilePath -> BS8.ByteString -> (MVar String -> IO a) -> IO a
withDockerNodeRunFixture path nodeBody = withDockerNodeRunFixtureMode path nodeBody False False

withDockerNodeRunFixtureMode
  :: FilePath -> BS8.ByteString -> Bool -> Bool -> (MVar String -> IO a) -> IO a
withDockerNodeRunFixtureMode path nodeBody lostReply wrongReadback action =
  bracket (socket AF_UNIX Stream defaultProtocol) close $ \listener -> do
    bind listener (SockAddrUnix path)
    listen listener 1
    received <- newEmptyMVar
    logReads <- newIORef (0 :: Int)
    configArchive <- newIORef Nothing
    versionPath <- either fail pure (TarEntry.toTarPath False "version")
    configPath <- either fail pure (TarEntry.toTarPath False "kubeadm.conf")
    let versionArchive = LazyBS8.toStrict (Tar.write [TarEntry.fileEntry versionPath (LazyBS8.pack "v1.30.0\n")])
        differentArchive = LazyBS8.toStrict (Tar.write [TarEntry.fileEntry configPath (LazyBS8.pack "different\n")])
    let response status payload =
          BS8.pack
            ("HTTP/1.1 " ++ status ++ "\r\nContent-Length: " ++ show (BS8.length payload) ++ "\r\n\r\n")
            <> payload
        headers connection bytes = case BS8.breakSubstring (BS8.pack "\r\n\r\n") bytes of
          (prefix, rest) | not (BS8.null rest) -> pure (prefix, BS8.drop 4 rest)
          _ | BS8.length bytes >= 16384 -> fail "fixture headers too large"
          _ -> do
            more <- recv connection 4096
            if BS8.null more then fail "fixture request ended early" else headers connection (bytes <> more)
        body connection size bytes
          | BS8.length bytes == size = pure bytes
          | BS8.length bytes > size = fail "fixture request too large"
          | otherwise = do
              more <- recv connection 4096
              if BS8.null more then fail "fixture request truncated" else body connection size (bytes <> more)
        serve = bracket (fst <$> accept listener) close $ \connection -> do
          (info, trailing) <- headers connection BS8.empty
          unless (BS8.pack "GET /info HTTP/1.1" `BS8.isPrefixOf` info && BS8.null trailing) $
            fail "invalid fixture info"
          sendAll connection (response "200 OK" (BS8.pack "{\"ID\":\"daemon-a\"}"))
          (create, initial) <- headers connection BS8.empty
          unless
            (BS8.pack "POST /containers/create?name=prodbox-t-run-control-plane HTTP/1.1" `BS8.isPrefixOf` create)
            $ fail "invalid fixture create"
          let lengths =
                [ BS8.dropWhile (== ' ') (BS8.drop 15 line)
                | line <- BS8.lines create
                , BS8.pack "content-length:" `BS8.isPrefixOf` BS8.map toLower line
                ]
          size <- case lengths of
            [encoded] -> case BS8.readInt encoded of
              Just (count, _) | count > 0 && count <= 8192 -> pure count
              _ -> fail "invalid fixture content length"
            _ -> fail "missing fixture content length"
          void (body connection size initial)
          sendAll connection (response "201 Created" (BS8.pack ("{\"Id\":\"" ++ replicate 64 'c' ++ "\"}")))
          let loop = do
                (request, rest) <- headers connection BS8.empty
                if BS8.pack ("PUT /containers/" ++ replicate 64 'c' ++ "/archive?") `BS8.isPrefixOf` request
                  then do
                    let contentLengths =
                          [ BS8.dropWhile (== ' ') (BS8.drop 15 line)
                          | line <- BS8.lines request
                          , BS8.pack "content-length:" `BS8.isPrefixOf` BS8.map toLower line
                          ]
                    count <- case contentLengths of
                      [encoded] -> case BS8.readInt encoded of
                        Just (number, _) | number > 0 && number <= 73728 -> pure number
                        _ -> fail "invalid config fixture length"
                      _ -> fail "missing config fixture length"
                    archive <- body connection count rest
                    writeIORef configArchive (Just archive)
                    unless lostReply $ do
                      sendAll connection (response "200 OK" BS8.empty)
                      loop
                  else do
                    unless (BS8.null rest) (fail "unexpected fixture request body")
                    respond request
              respond request
                | BS8.pack ("HEAD /containers/" ++ replicate 64 'c' ++ "/archive?") `BS8.isPrefixOf` request = do
                    let stat =
                          Base64.encode
                            ( BS8.pack
                                "{\"name\":\"kind\",\"size\":4096,\"mode\":2147484141,\"mtime\":\"2026-01-01T00:00:00Z\",\"linkTarget\":\"\"}"
                            )
                        answer =
                          if BS8.pack "kubeadm.conf" `BS8.isInfixOf` request
                            then BS8.pack "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
                            else
                              BS8.pack "HTTP/1.1 200 OK\r\nX-Docker-Container-Path-Stat: "
                                <> stat
                                <> BS8.pack "\r\nContent-Length: 0\r\n\r\n"
                    sendAll connection answer
                    loop
                | BS8.pack "GET /info HTTP/1.1" `BS8.isPrefixOf` request =
                    sendAll
                      connection
                      ( response
                          "200 OK"
                          ( BS8.pack
                              "{\"ID\":\"daemon-a\",\"CgroupDriver\":\"systemd\",\"CgroupVersion\":\"2\",\"MemoryLimit\":true,\"PidsLimit\":true,\"CPUShares\":true,\"SecurityOptions\":[]}"
                          )
                      )
                      >> loop
                | BS8.pack ("GET /containers/" ++ replicate 64 'c' ++ "/json HTTP/1.1") `BS8.isPrefixOf` request =
                    sendAll connection (response "200 OK" nodeBody) >> loop
                | BS8.pack ("GET /containers/" ++ replicate 64 'c' ++ "/logs?") `BS8.isPrefixOf` request = do
                    count <- atomicModifyIORef' logReads (\value -> (value + 1, value))
                    let line = if count == 0 then "booting\n" else "systemd: Reached target Multi-User System.\n"
                    sendAll connection (response "200 OK" (BS8.pack line))
                    loop
                | BS8.pack ("GET /containers/" ++ replicate 64 'c' ++ "/archive?") `BS8.isPrefixOf` request = do
                    current <- readIORef configArchive
                    let archive =
                          if BS8.pack "kubeadm.conf" `BS8.isInfixOf` request
                            then if wrongReadback then differentArchive else maybe BS8.empty id current
                            else versionArchive
                    sendAll connection (response "200 OK" archive)
                    loop
                | otherwise = do
                    unless
                      (BS8.pack ("POST /containers/" ++ replicate 64 'c' ++ "/start HTTP/1.1") `BS8.isPrefixOf` request)
                      $ fail "invalid fixture start"
                    putMVar received (takeWhile (/= '\r') (BS8.unpack request))
                    sendAll connection (BS8.pack "HTTP/1.1 204 No Content\r\n\r\n")
                    loop
          loop
    bracket
      (forkIO (void (try serve :: IO (Either SomeException ()))))
      killThread
      (const (action received))

withDockerNodeStartFixture :: FilePath -> IO BS8.ByteString -> (MVar String -> IO a) -> IO a
withDockerNodeStartFixture path nodeBody action =
  bracket (socket AF_UNIX Stream defaultProtocol) close $ \listener -> do
    bind listener (SockAddrUnix path)
    listen listener 1
    received <- newEmptyMVar
    let headers connection bytes
          | BS8.pack "\r\n\r\n" `BS8.isInfixOf` bytes = pure bytes
          | BS8.length bytes >= 16384 = fail "fixture headers too large"
          | otherwise = do
              more <- recv connection 4096
              if BS8.null more then fail "fixture request ended early" else headers connection (bytes <> more)
        response body = BS8.pack ("HTTP/1.1 200 OK\r\nContent-Length: " ++ show (BS8.length body) ++ "\r\n\r\n") <> body
        serve = bracket (fst <$> accept listener) close $ \connection -> do
          info <- headers connection BS8.empty
          unless (BS8.pack "GET /info HTTP/1.1\r\n" `BS8.isPrefixOf` info) $ fail "invalid fixture info"
          sendAll connection (response (BS8.pack "{\"ID\":\"daemon-a\"}"))
          let loop = do
                request <- headers connection BS8.empty
                if BS8.pack ("GET /containers/" ++ replicate 64 'c' ++ "/json HTTP/1.1\r\n") `BS8.isPrefixOf` request
                  then nodeBody >>= sendAll connection . response
                  else do
                    putMVar received (takeWhile (/= '\r') (BS8.unpack request))
                    sendAll connection (BS8.pack "HTTP/1.1 204 No Content\r\n\r\n")
                loop
          loop
    bracket
      (forkIO (void (try serve :: IO (Either SomeException ()))))
      killThread
      (const (action received))

withDockerNetworkRemoveFixture :: FilePath -> Maybe Int -> (MVar String -> IO a) -> IO a
withDockerNetworkRemoveFixture path reply = withDockerNetworkRemoveFixtureMode path reply False

withDockerNetworkRemoveFixtureMode :: FilePath -> Maybe Int -> Bool -> (MVar String -> IO a) -> IO a
withDockerNetworkRemoveFixtureMode path reply inspectFirst action =
  bracket (socket AF_UNIX Stream defaultProtocol) close $ \listener -> do
    bind listener (SockAddrUnix path)
    listen listener 1
    received <- newEmptyMVar
    let headers connection bytes
          | BS8.pack "\r\n\r\n" `BS8.isInfixOf` bytes = pure bytes
          | BS8.length bytes >= 16384 = fail "fixture headers too large"
          | otherwise = do
              more <- recv connection 4096
              if BS8.null more then fail "fixture request ended early" else headers connection (bytes <> more)
        serve = bracket (fst <$> accept listener) close $ \connection -> do
          info <- headers connection BS8.empty
          unless (BS8.pack "GET /info HTTP/1.1\r\n" `BS8.isPrefixOf` info) $
            fail "invalid fixture info request"
          let infoBody = BS8.pack "{\"ID\":\"daemon-a\"}"
          sendAll
            connection
            ( BS8.pack ("HTTP/1.1 200 OK\r\nContent-Length: " ++ show (BS8.length infoBody) ++ "\r\n\r\n")
                <> infoBody
            )
          when inspectFirst $ do
            inspected <- headers connection BS8.empty
            unless
              (BS8.pack ("GET /networks/" ++ replicate 64 'c' ++ " HTTP/1.1\r\n") `BS8.isPrefixOf` inspected)
              $ fail "invalid fixture network inspection"
            let networkBody =
                  BS8.pack $
                    "{\"Name\":\"prodbox-t-run\",\"Id\":\""
                      ++ replicate 64 'c'
                      ++ "\",\"Driver\":\"bridge\",\"EnableIPv6\":true,"
                      ++ "\"Options\":{\"com.docker.network.bridge.enable_ip_masquerade\":\"true\",\"com.docker.network.driver.mtu\":\"1500\"},"
                      ++ "\"Labels\":{\"io.prodbox.deployment\":\"prodbox-t-run\",\"io.prodbox.generation\":\""
                      ++ replicate 32 'a'
                      ++ "\",\"io.prodbox.operation\":\""
                      ++ replicate 32 'b'
                      ++ "\"},\"IPAM\":{\"Config\":[{\"Subnet\":\"fc00:c1c8:9c54:6b75::/64\"}]}}"
            sendAll
              connection
              ( BS8.pack ("HTTP/1.1 200 OK\r\nContent-Length: " ++ show (BS8.length networkBody) ++ "\r\n\r\n")
                  <> networkBody
              )
          request <- headers connection BS8.empty
          putMVar received (takeWhile (/= '\r') (BS8.unpack request))
          case reply of
            Just 204 -> sendAll connection (BS8.pack "HTTP/1.1 204 No Content\r\n\r\n")
            Just 304 -> sendAll connection (BS8.pack "HTTP/1.1 304 Not Modified\r\n\r\n")
            Just 404 -> sendAll connection (BS8.pack "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n")
            _ -> pure ()
    bracket
      (forkIO (void (try serve :: IO (Either SomeException ()))))
      killThread
      (const (action received))

withDockerVolumeRemovalFixture
  :: FilePath -> String -> BS8.ByteString -> (MVar String -> IO a) -> IO a
withDockerVolumeRemovalFixture path name volumeBody action =
  bracket (socket AF_UNIX Stream defaultProtocol) close $ \listener -> do
    bind listener (SockAddrUnix path)
    listen listener 1
    received <- newEmptyMVar
    let headers connection bytes
          | BS8.pack "\r\n\r\n" `BS8.isInfixOf` bytes = pure bytes
          | BS8.length bytes >= 16384 = fail "fixture headers too large"
          | otherwise = do
              more <- recv connection 4096
              if BS8.null more then fail "fixture request ended early" else headers connection (bytes <> more)
        response body = BS8.pack ("HTTP/1.1 200 OK\r\nContent-Length: " ++ show (BS8.length body) ++ "\r\n\r\n") <> body
        serve = bracket (fst <$> accept listener) close $ \connection -> do
          info <- headers connection BS8.empty
          unless (BS8.pack "GET /info HTTP/1.1\r\n" `BS8.isPrefixOf` info) $ fail "invalid fixture info"
          sendAll connection (response (BS8.pack "{\"ID\":\"daemon-a\"}"))
          inspected <- headers connection BS8.empty
          unless (BS8.pack ("GET /volumes/" ++ name ++ " HTTP/1.1\r\n") `BS8.isPrefixOf` inspected) $
            fail "invalid fixture volume read"
          sendAll connection (response volumeBody)
          request <- headers connection BS8.empty
          putMVar received (takeWhile (/= '\r') (BS8.unpack request))
          sendAll connection (BS8.pack "HTTP/1.1 204 No Content\r\n\r\n")
    bracket
      (forkIO (void (try serve :: IO (Either SomeException ()))))
      killThread
      (const (action received))

withDockerNetworkCreateFixture :: FilePath -> Bool -> (MVar BS8.ByteString -> IO a) -> IO a
withDockerNetworkCreateFixture path reply action =
  bracket (socket AF_UNIX Stream defaultProtocol) close $ \listener -> do
    bind listener (SockAddrUnix path)
    listen listener 1
    received <- newEmptyMVar
    let response status payload =
          BS8.pack
            ("HTTP/1.1 " ++ status ++ "\r\nContent-Length: " ++ show (BS8.length payload) ++ "\r\n\r\n")
            <> payload
        headers connection bytes = case BS8.breakSubstring (BS8.pack "\r\n\r\n") bytes of
          (prefix, rest) | not (BS8.null rest) -> pure (prefix, BS8.drop 4 rest)
          _ | BS8.length bytes >= 16384 -> fail "fixture headers too large"
          _ -> do
            more <- recv connection 4096
            if BS8.null more then fail "fixture request ended early" else headers connection (bytes <> more)
        body connection size bytes
          | BS8.length bytes == size = pure bytes
          | BS8.length bytes > size = fail "fixture request too large"
          | otherwise = do
              more <- recv connection 4096
              if BS8.null more then fail "fixture request truncated" else body connection size (bytes <> more)
        serve = bracket (fst <$> accept listener) close $ \connection -> do
          (info, trailing) <- headers connection BS8.empty
          unless (BS8.pack "GET /info HTTP/1.1" `BS8.isPrefixOf` info && BS8.null trailing) $
            fail "invalid fixture info request"
          sendAll connection (response "200 OK" (BS8.pack "{\"ID\":\"daemon-a\"}"))
          (request, initial) <- headers connection BS8.empty
          unless (BS8.pack "POST /networks/create HTTP/1.1" `BS8.isPrefixOf` request) $
            fail "invalid fixture network request"
          let lengths =
                [ BS8.dropWhile (== ' ') (BS8.drop 15 line)
                | line <- BS8.lines request
                , BS8.pack "content-length:" `BS8.isPrefixOf` BS8.map toLower line
                ]
          size <- case lengths of
            [encoded] -> case BS8.readInt encoded of
              Just (count, _) | count > 0 && count <= 8192 -> pure count
              _ -> fail "invalid fixture content length"
            _ -> fail "missing fixture content length"
          payload <- body connection size initial
          putMVar received payload
          when
            reply
            ( sendAll
                connection
                (response "201 Created" (BS8.pack ("{\"Id\":\"" ++ replicate 64 'c' ++ "\",\"Warning\":\"\"}")))
            )
    bracket
      (forkIO (void (try serve :: IO (Either SomeException ()))))
      killThread
      (const (action received))

withDockerNodeInspectFixture
  :: FilePath -> String -> Maybe BS8.ByteString -> (MVar String -> IO a) -> IO a
withDockerNodeInspectFixture path identifier nodeBody action =
  bracket (socket AF_UNIX Stream defaultProtocol) close $ \listener -> do
    bind listener (SockAddrUnix path)
    listen listener 1
    received <- newEmptyMVar
    let headers connection bytes
          | BS8.pack "\r\n\r\n" `BS8.isInfixOf` bytes = pure bytes
          | BS8.length bytes >= 16384 = fail "fixture headers too large"
          | otherwise = do
              more <- recv connection 4096
              if BS8.null more then fail "fixture request ended early" else headers connection (bytes <> more)
        response status body =
          BS8.pack ("HTTP/1.1 " ++ status ++ "\r\nContent-Length: " ++ show (BS8.length body) ++ "\r\n\r\n")
            <> body
        serve = bracket (fst <$> accept listener) close $ \connection -> do
          info <- headers connection BS8.empty
          unless (BS8.pack "GET /info HTTP/1.1\r\n" `BS8.isPrefixOf` info) $ fail "invalid fixture info"
          sendAll connection (response "200 OK" (BS8.pack "{\"ID\":\"daemon-a\"}"))
          request <- headers connection BS8.empty
          unless
            (BS8.pack ("GET /containers/" ++ identifier ++ "/json HTTP/1.1\r\n") `BS8.isPrefixOf` request)
            $ fail "invalid fixture node read"
          putMVar received (takeWhile (/= '\r') (BS8.unpack request))
          case nodeBody of
            Just body -> sendAll connection (response "200 OK" body)
            Nothing -> sendAll connection (response "404 Not Found" BS8.empty)
    bracket
      (forkIO (void (try serve :: IO (Either SomeException ()))))
      killThread
      (const (action received))

withDockerNodeContainerCreateFixture
  :: FilePath -> Maybe BS8.ByteString -> (MVar BS8.ByteString -> IO a) -> IO a
withDockerNodeContainerCreateFixture path reply action =
  bracket (socket AF_UNIX Stream defaultProtocol) close $ \listener -> do
    bind listener (SockAddrUnix path)
    listen listener 1
    received <- newEmptyMVar
    let response status payload =
          BS8.pack
            ("HTTP/1.1 " ++ status ++ "\r\nContent-Length: " ++ show (BS8.length payload) ++ "\r\n\r\n")
            <> payload
        headers connection bytes = case BS8.breakSubstring (BS8.pack "\r\n\r\n") bytes of
          (prefix, rest) | not (BS8.null rest) -> pure (prefix, BS8.drop 4 rest)
          _ | BS8.length bytes >= 16384 -> fail "fixture headers too large"
          _ -> do
            more <- recv connection 4096
            if BS8.null more then fail "fixture request ended early" else headers connection (bytes <> more)
        body connection size bytes
          | BS8.length bytes == size = pure bytes
          | BS8.length bytes > size = fail "fixture request too large"
          | otherwise = do
              more <- recv connection 4096
              if BS8.null more then fail "fixture request truncated" else body connection size (bytes <> more)
        serve = bracket (fst <$> accept listener) close $ \connection -> do
          (info, trailing) <- headers connection BS8.empty
          unless (BS8.pack "GET /info HTTP/1.1" `BS8.isPrefixOf` info && BS8.null trailing) $
            fail "invalid fixture info request"
          sendAll connection (response "200 OK" (BS8.pack "{\"ID\":\"daemon-a\"}"))
          (request, initial) <- headers connection BS8.empty
          unless
            ( BS8.pack "POST /containers/create?name=prodbox-t-run-control-plane HTTP/1.1"
                `BS8.isPrefixOf` request
            )
            $ fail "invalid fixture node request"
          let lengths =
                [ BS8.dropWhile (== ' ') (BS8.drop 15 line)
                | line <- BS8.lines request
                , BS8.pack "content-length:" `BS8.isPrefixOf` BS8.map toLower line
                ]
          size <- case lengths of
            [encoded] -> case BS8.readInt encoded of
              Just (count, _) | count > 0 && count <= 8192 -> pure count
              _ -> fail "invalid fixture content length"
            _ -> fail "missing fixture content length"
          payload <- body connection size initial
          putMVar received payload
          case reply of
            Just responseBody -> sendAll connection (response "201 Created" responseBody)
            Nothing -> pure ()
    bracket
      (forkIO (void (try serve :: IO (Either SomeException ()))))
      killThread
      (const (action received))

withDockerNodeVolumeCreateFixture
  :: FilePath -> Maybe BS8.ByteString -> (MVar BS8.ByteString -> IO a) -> IO a
withDockerNodeVolumeCreateFixture path reply action =
  bracket (socket AF_UNIX Stream defaultProtocol) close $ \listener -> do
    bind listener (SockAddrUnix path)
    listen listener 1
    received <- newEmptyMVar
    let response status payload =
          BS8.pack
            ("HTTP/1.1 " ++ status ++ "\r\nContent-Length: " ++ show (BS8.length payload) ++ "\r\n\r\n")
            <> payload
        headers connection bytes = case BS8.breakSubstring (BS8.pack "\r\n\r\n") bytes of
          (prefix, rest) | not (BS8.null rest) -> pure (prefix, BS8.drop 4 rest)
          _ | BS8.length bytes >= 16384 -> fail "fixture headers too large"
          _ -> do
            more <- recv connection 4096
            if BS8.null more then fail "fixture request ended early" else headers connection (bytes <> more)
        body connection size bytes
          | BS8.length bytes == size = pure bytes
          | BS8.length bytes > size = fail "fixture request too large"
          | otherwise = do
              more <- recv connection 4096
              if BS8.null more then fail "fixture request truncated" else body connection size (bytes <> more)
        serve = bracket (fst <$> accept listener) close $ \connection -> do
          (info, trailing) <- headers connection BS8.empty
          unless (BS8.pack "GET /info HTTP/1.1" `BS8.isPrefixOf` info && BS8.null trailing) $
            fail "invalid fixture info request"
          sendAll connection (response "200 OK" (BS8.pack "{\"ID\":\"daemon-a\"}"))
          (request, initial) <- headers connection BS8.empty
          unless (BS8.pack "POST /volumes/create HTTP/1.1" `BS8.isPrefixOf` request) $
            fail "invalid fixture volume request"
          let lengths =
                [ BS8.dropWhile (== ' ') (BS8.drop 15 line)
                | line <- BS8.lines request
                , BS8.pack "content-length:" `BS8.isPrefixOf` BS8.map toLower line
                ]
          size <- case lengths of
            [encoded] -> case BS8.readInt encoded of
              Just (count, _) | count > 0 && count <= 8192 -> pure count
              _ -> fail "invalid fixture content length"
            _ -> fail "missing fixture content length"
          payload <- body connection size initial
          putMVar received payload
          case reply of
            Just responseBody -> sendAll connection (response "201 Created" responseBody)
            Nothing -> pure ()
    bracket
      (forkIO (void (try serve :: IO (Either SomeException ()))))
      killThread
      (const (action received))

-- Controlled metadata responses only; no Docker daemon is contacted.
withDockerConfigPathFixture :: FilePath -> String -> BS8.ByteString -> IO a -> IO a
withDockerConfigPathFixture path status fields action =
  bracket (socket AF_UNIX Stream defaultProtocol) close $ \listener -> do
    bind listener (SockAddrUnix path)
    listen listener 1
    let headers connection bytes
          | BS8.pack "\r\n\r\n" `BS8.isInfixOf` bytes = pure bytes
          | BS8.length bytes >= 16384 = fail "path fixture headers too large"
          | otherwise = do
              more <- recv connection 4096
              if BS8.null more then fail "path fixture request ended" else headers connection (bytes <> more)
        serve = bracket (fst <$> accept listener) close $ \connection -> do
          info <- headers connection BS8.empty
          unless (BS8.pack "GET /info HTTP/1.1" `BS8.isPrefixOf` info) $ fail "invalid path fixture info"
          let infoBody = BS8.pack "{\"ID\":\"daemon-a\"}"
          sendAll
            connection
            ( BS8.pack ("HTTP/1.1 200 OK\r\nContent-Length: " ++ show (BS8.length infoBody) ++ "\r\n\r\n")
                <> infoBody
            )
          request <- headers connection BS8.empty
          unless
            (BS8.pack ("HEAD /containers/" ++ replicate 64 'c' ++ "/archive?path=") `BS8.isPrefixOf` request)
            $ fail "invalid path fixture request"
          sendAll
            connection
            (BS8.pack ("HTTP/1.1 " ++ status ++ "\r\n") <> fields <> BS8.pack "Content-Length: 0\r\n\r\n")
    bracket (forkIO (void (try serve :: IO (Either SomeException ())))) killThread (const action)

-- Controlled transport only; no Docker daemon or container is contacted.
withDockerConfigFixture
  :: FilePath -> BS8.ByteString -> Bool -> (MVar BS8.ByteString -> IO a) -> IO a
withDockerConfigFixture path expected reply action =
  bracket (socket AF_UNIX Stream defaultProtocol) close $ \listener -> do
    bind listener (SockAddrUnix path)
    listen listener 1
    received <- newEmptyMVar
    let response payload =
          BS8.pack ("HTTP/1.1 200 OK\r\nContent-Length: " ++ show (BS8.length payload) ++ "\r\n\r\n")
            <> payload
        headers connection bytes = case BS8.breakSubstring (BS8.pack "\r\n\r\n") bytes of
          (headBytes, rest) | not (BS8.null rest) -> pure (headBytes, BS8.drop 4 rest)
          _ | BS8.length bytes >= 16384 -> fail "config fixture headers too large"
          _ -> do
            more <- recv connection 4096
            if BS8.null more then fail "config fixture request ended" else headers connection (bytes <> more)
        body connection bytes
          | BS8.length bytes == BS8.length expected = pure bytes
          | BS8.length bytes > BS8.length expected = fail "config fixture body too large"
          | otherwise = do
              more <- recv connection 4096
              if BS8.null more then fail "config fixture body ended" else body connection (bytes <> more)
        serve = bracket (fst <$> accept listener) close $ \connection -> do
          (info, trailing) <- headers connection BS8.empty
          unless (BS8.pack "GET /info HTTP/1.1" `BS8.isPrefixOf` info && BS8.null trailing) $
            fail "invalid config fixture info"
          sendAll connection (response (BS8.pack "{\"ID\":\"daemon-a\"}"))
          (submission, initial) <- headers connection BS8.empty
          unless
            ( BS8.pack ("PUT /containers/" ++ replicate 64 'c' ++ "/archive?") `BS8.isPrefixOf` submission
                && BS8.pack "noOverwriteDirNonDir=true" `BS8.isInfixOf` submission
            )
            $ fail "invalid config fixture submission"
          body connection initial >>= putMVar received
          when reply $ do
            sendAll connection (response BS8.empty)
            (query, queryTrailing) <- headers connection BS8.empty
            unless
              ( BS8.pack ("GET /containers/" ++ replicate 64 'c' ++ "/archive?") `BS8.isPrefixOf` query
                  && BS8.null queryTrailing
              )
              $ fail "invalid config fixture read-back"
            sendAll connection (response expected)
    bracket
      (forkIO (void (try serve :: IO (Either SomeException ()))))
      killThread
      (const (action received))

withDockerLoadFixture :: FilePath -> BS8.ByteString -> Bool -> (MVar BS8.ByteString -> IO a) -> IO a
withDockerLoadFixture path expected reply action =
  bracket (socket AF_UNIX Stream defaultProtocol) close $ \listener -> do
    bind listener (SockAddrUnix path)
    listen listener 1
    received <- newEmptyMVar
    let serve = bracket (fst <$> accept listener) close $ \connection -> do
          (info, trailing) <- readHeaders connection BS8.empty
          unless (BS8.pack "GET /info HTTP/1.1\r\n" `BS8.isPrefixOf` info && BS8.null trailing) $
            fail "invalid fixture info request"
          let infoBody = BS8.pack "{\"ID\":\"daemon-a\"}"
          sendAll connection (response infoBody)
          (headers, initial) <- readHeaders connection BS8.empty
          unless (BS8.pack "POST /images/load?quiet=1 HTTP/1.1\r\n" `BS8.isPrefixOf` headers) $
            fail "invalid fixture image request"
          body <- readBody connection initial
          putMVar received body
          when reply (sendAll connection (response (BS8.pack "{\"stream\":\"loaded\"}\n")))
        response body = BS8.pack ("HTTP/1.1 200 OK\r\nContent-Length: " ++ show (BS8.length body) ++ "\r\n\r\n") <> body
        readBody connection bytes
          | BS8.length bytes == BS8.length expected = pure bytes
          | BS8.length bytes > BS8.length expected = fail "fixture image request too large"
          | otherwise = do
              more <- recv connection 4096
              if BS8.null more
                then fail "fixture image request truncated"
                else readBody connection (bytes <> more)
    bracket
      (forkIO (void (try serve :: IO (Either SomeException ()))))
      killThread
      (const (action received))
 where
  readHeaders connection bytes =
    case BS8.breakSubstring (BS8.pack "\r\n\r\n") bytes of
      (headers, rest) | not (BS8.null rest) -> pure (headers <> BS8.pack "\r\n\r\n", BS8.drop 4 rest)
      _ | BS8.length bytes >= 16384 -> fail "fixture headers too large"
      _ -> do
        more <- recv connection 4096
        if BS8.null more then fail "fixture request ended early" else readHeaders connection (bytes <> more)

-- Serve only the read-only Docker endpoints used by the connected preparation
-- fixture. Each client has its own connection; the selected socket is local.
allowedDockerFixtureRequest :: String -> Bool
allowedDockerFixtureRequest request = case words request of
  ["HEAD", endpoint, _] -> "/_ping" `isSuffixOf` endpoint
  ["GET", endpoint, _] ->
    "/info" `isSuffixOf` endpoint
      || "/_ping" `isSuffixOf` endpoint
      || ("/images/sha256:" `isInfixOf` endpoint && "/json" `isSuffixOf` endpoint)
  ["POST", "/images/load?quiet=1", _] -> True
  _ -> False

withDockerDaemonFixture :: FilePath -> Bool -> (MVar [String] -> IO a) -> IO a
withDockerDaemonFixture path conflict = withDockerDaemonFixtureHook path conflict (const (pure ()))

withDockerDaemonFixtureHook
  :: FilePath -> Bool -> (String -> IO ()) -> (MVar [String] -> IO a) -> IO a
withDockerDaemonFixtureHook path conflict hook = withDockerDaemonFixtureHookMode path conflict hook (pure False)

withDockerDaemonFixtureHookMode
  :: FilePath -> Bool -> (String -> IO ()) -> IO Bool -> (MVar [String] -> IO a) -> IO a
withDockerDaemonFixtureHookMode path conflict hook daemonChanged =
  withDockerDaemonFixtureBody path conflict hook daemonChanged (BS8.pack "[]")

withDockerDaemonFixtureContainers :: FilePath -> BS8.ByteString -> (MVar [String] -> IO a) -> IO a
withDockerDaemonFixtureContainers path = withDockerDaemonFixtureBody path False (const (pure ())) (pure False)

withDockerDaemonFixtureBody
  :: FilePath
  -> Bool
  -> (String -> IO ())
  -> IO Bool
  -> BS8.ByteString
  -> (MVar [String] -> IO a)
  -> IO a
withDockerDaemonFixtureBody path conflict hook daemonChanged containerBody action =
  withDockerDaemonFixtureBodies path conflict hook daemonChanged containerBody (BS8.pack "[]") action

withDockerDaemonFixtureNetworks :: FilePath -> BS8.ByteString -> (MVar [String] -> IO a) -> IO a
withDockerDaemonFixtureNetworks path =
  withDockerDaemonFixtureBodies path False (const (pure ())) (pure False) (BS8.pack "[]")

withDockerDaemonFixtureBodies
  :: FilePath
  -> Bool
  -> (String -> IO ())
  -> IO Bool
  -> BS8.ByteString
  -> BS8.ByteString
  -> (MVar [String] -> IO a)
  -> IO a
withDockerDaemonFixtureBodies path conflict hook daemonChanged containerBody networkBody =
  withDockerDaemonFixtureControl
    path
    conflict
    hook
    daemonChanged
    containerBody
    networkBody
    (pure True)

withDockerDaemonFixtureControl
  :: FilePath
  -> Bool
  -> (String -> IO ())
  -> IO Bool
  -> BS8.ByteString
  -> BS8.ByteString
  -> IO Bool
  -> (MVar [String] -> IO a)
  -> IO a
withDockerDaemonFixtureControl path conflict hook daemonChanged containerBody networkBody controlVisible =
  withDockerDaemonFixtureControlAndVolume
    path
    conflict
    hook
    daemonChanged
    containerBody
    networkBody
    controlVisible
    Nothing

withDockerDaemonFixtureControlAndVolume
  :: FilePath
  -> Bool
  -> (String -> IO ())
  -> IO Bool
  -> BS8.ByteString
  -> BS8.ByteString
  -> IO Bool
  -> Maybe (String, BS8.ByteString)
  -> (MVar [String] -> IO a)
  -> IO a
withDockerDaemonFixtureControlAndVolume path conflict hook daemonChanged containerBody networkBody controlVisible volumeResponse =
  withDockerDaemonFixtureControlVolumeList
    path
    conflict
    hook
    daemonChanged
    containerBody
    networkBody
    controlVisible
    volumeResponse
    (pure (BS8.pack "{\"Volumes\":[],\"Warnings\":[]}"))

withDockerDaemonFixtureControlVolumeList
  :: FilePath
  -> Bool
  -> (String -> IO ())
  -> IO Bool
  -> BS8.ByteString
  -> BS8.ByteString
  -> IO Bool
  -> Maybe (String, BS8.ByteString)
  -> IO BS8.ByteString
  -> (MVar [String] -> IO a)
  -> IO a
withDockerDaemonFixtureControlVolumeList path conflict hook daemonChanged containerBody networkBody controlVisible volumeResponse volumeList =
  withDockerDaemonFixtureControlVolumeAndNode
    path
    conflict
    hook
    daemonChanged
    containerBody
    networkBody
    controlVisible
    volumeResponse
    volumeList
    Nothing

withDockerDaemonFixtureControlVolumeAndNode
  :: FilePath
  -> Bool
  -> (String -> IO ())
  -> IO Bool
  -> BS8.ByteString
  -> BS8.ByteString
  -> IO Bool
  -> Maybe (String, BS8.ByteString)
  -> IO BS8.ByteString
  -> Maybe (String, BS8.ByteString)
  -> (MVar [String] -> IO a)
  -> IO a
withDockerDaemonFixtureControlVolumeAndNode path conflict hook daemonChanged containerBody networkBody controlVisible volumeResponse volumeList nodeResponse action =
  bracket (socket AF_UNIX Stream defaultProtocol) close $ \listener -> do
    bind listener (SockAddrUnix path)
    listen listener 32
    requests <- newMVar []
    workers <- newMVar []
    let serve client = bracket (pure client) close serveRequests
        serveRequests connection = do
          headers <- readHeaders connection BS8.empty
          let request = takeWhile (/= '\r') (BS8.unpack headers)
          modifyMVar_ requests (pure . (request :))
          hook request
          changed <- daemonChanged
          control <- controlVisible
          when ("POST /images/load?quiet=1 " `isPrefixOf` request) $ do
            let (headerBytes, trailing) = BS8.breakSubstring (BS8.pack "\r\n\r\n") headers
                contentLengths =
                  [ BS8.dropWhile (== ' ') (BS8.drop 15 line)
                  | line <- BS8.lines headerBytes
                  , BS8.pack "content-length:" `BS8.isPrefixOf` BS8.map toLower line
                  ]
            case contentLengths of
              [encoded] -> case BS8.readInt encoded of
                Just (count, _) | count > 0 && count <= 1048576 -> consumeBody connection count (BS8.drop 4 trailing)
                _ -> fail "invalid fixture image body length"
              _ -> fail "missing fixture image body length"
          let originalParts = words request
              parts = case originalParts of
                [method, endpoint, version] -> [method, unversion endpoint, version]
                other -> other
          listing <- case parts of
            ["GET", endpoint, _] | endpoint == "/volumes" || "/volumes?" `isPrefixOf` endpoint -> Just <$> volumeList
            _ -> pure Nothing
          let response = case parts of
                ["GET", endpoint, _] | endpoint == "/volumes" || "/volumes?" `isPrefixOf` endpoint -> (True,) <$> listing
                ["POST", "/images/load?quiet=1", _] -> Just (True, BS8.pack "{\"stream\":\"fixture loaded\"}\n")
                ["DELETE", endpoint, _]
                  | Just (nodeId, _) <- nodeResponse
                  , endpoint == "/containers/" ++ nodeId ++ "?force=1&v=1" ->
                      Just (False, BS8.empty)
                ["GET", endpoint, _]
                  | Just (name, body) <- volumeResponse, endpoint == "/volumes/" ++ name -> Just (True, body)
                ["GET", endpoint, _]
                  | Just (nodeId, body) <- nodeResponse
                  , endpoint == "/containers/" ++ nodeId ++ "/json" ->
                      Just (True, body)
                ["HEAD", endpoint, _] | "/_ping" `isSuffixOf` endpoint -> Just (False, BS8.pack "OK")
                ["GET", endpoint, _] | "/_ping" `isSuffixOf` endpoint -> Just (True, BS8.pack "OK")
                ["GET", endpoint, _] | "/containers/json" `isInfixOf` endpoint -> Just (True, containerBody)
                ["GET", endpoint, _]
                  | "/networks?" `isPrefixOf` endpoint ->
                      Just
                        ( True
                        , if replicate 64 'd' `isInfixOf` endpoint
                            then
                              if control
                                then BS8.pack ("[{\"Name\":\"bridge\",\"Id\":\"" ++ replicate 64 'd' ++ "\"}]")
                                else BS8.pack "[]"
                            else networkBody
                        )
                ["GET", "/networks/bridge", _] ->
                  Just
                    ( True
                    , BS8.pack
                        ("{\"Name\":\"bridge\",\"Id\":\"" ++ replicate 64 'd' ++ "\",\"Driver\":\"bridge\",\"Options\":{}}")
                    )
                ["GET", endpoint, _]
                  | endpoint == "/networks/" ++ replicate 64 'b' ->
                      Just
                        ( True
                        , BS8.pack
                            ( "{\"Name\":\"prodbox-t-run\",\"Id\":\""
                                ++ replicate 64 'b'
                                ++ "\",\"Driver\":\"bridge\",\"EnableIPv6\":true,\"Options\":null,\"Labels\":null,"
                                ++ "\"IPAM\":{\"Config\":[{\"Subnet\":\"fc00:c1c8:9c54:6b75::/64\"}]}}"
                            )
                        )
                ["GET", endpoint, _]
                  | "/images/sha256:" `isPrefixOf` endpoint && "/json" `isSuffixOf` endpoint ->
                      if endpoint
                        `elem` ["/images/sha256:" ++ replicate 64 'c' ++ "/json", "/images/sha256:" ++ replicate 64 'e' ++ "/json"]
                        then Nothing
                        else
                          if endpoint == "/images/sha256:" ++ replicate 64 'd' ++ "/json"
                            then
                              Just
                                ( True
                                , BS8.pack
                                    ( "{\"Id\":\"sha256:"
                                        ++ replicate 64 'd'
                                        ++ "\",\"Id\":\"sha256:"
                                        ++ replicate 64 'd'
                                        ++ "\",\"Os\":\"linux\",\"Architecture\":\"amd64\",\"RepoTags\":null}"
                                    )
                                )
                            else
                              let requested = take 71 (drop (length ("/images/" :: String)) endpoint)
                                  returned = if requested == "sha256:" ++ replicate 64 'b' then "sha256:" ++ replicate 64 'a' else requested
                               in Just
                                    ( True
                                    , BS8.pack
                                        ( "{\"Id\":\""
                                            ++ returned
                                            ++ "\",\"Os\":\"linux\",\"Architecture\":\"amd64\",\"RepoTags\":null}"
                                        )
                                    )
                ["GET", endpoint, _]
                  | "/info" `isSuffixOf` endpoint ->
                      let identifier =
                            if changed || (conflict && originalParts == ["GET", "/info", "HTTP/1.1"])
                              then "daemon-b"
                              else "daemon-a"
                       in Just
                            ( True
                            , BS8.pack
                                ( "{\"ID\":\""
                                    ++ identifier
                                    ++ "\",\"CgroupDriver\":\"systemd\",\"CgroupVersion\":\"2\","
                                    ++ "\"MemoryLimit\":true,\"PidsLimit\":true,\"CPUShares\":true,\"SecurityOptions\":[],"
                                    ++ "\"Driver\":\"overlay2\",\"DriverStatus\":[[\"Backing Filesystem\",\"extfs\"]]}"
                                )
                            )
                _ -> Nothing
          case response of
            Nothing -> do
              let body =
                    if ("/images/sha256:" ++ replicate 64 'e' ++ "/json") `isInfixOf` request
                      then BS8.replicate 65537 'x'
                      else BS8.empty
              sendAll
                connection
                ( BS8.pack ("HTTP/1.1 404 Not Found\r\nContent-Length: " ++ show (BS8.length body) ++ "\r\n\r\n")
                    <> body
                )
              serveRequests connection
            Just (includeBody, body) -> do
              let status = if "DELETE /containers/" `isPrefixOf` request then "204 No Content" else "200 OK"
              sendAll connection $
                BS8.pack
                  ( "HTTP/1.1 "
                      ++ status
                      ++ "\r\nAPI-Version: 1.51\r\nContent-Length: "
                      ++ show (BS8.length body)
                      ++ "\r\n\r\n"
                  )
                  <> if includeBody then body else BS8.empty
              serveRequests connection
        acceptLoop = forever $ do
          (client, _) <- accept listener
          worker <- forkIO (void (try (serve client) :: IO (Either SomeException ())))
          modifyMVar_ workers (pure . (worker :))
        stop worker = do
          killThread worker
          readMVar workers >>= mapM_ killThread
    bracket (forkIO acceptLoop) stop (const (action requests))
 where
  unversion endpoint = case stripPrefix "/v" endpoint of
    Just versioned -> case dropWhile isVersionChar versioned of
      '/' : rest -> '/' : rest
      _ -> endpoint
    Nothing -> endpoint
  isVersionChar c = isDigit c || c == '.'
  consumeBody connection count bytes
    | BS8.length bytes == count = pure ()
    | BS8.length bytes > count = fail "oversized fixture image body"
    | otherwise = do
        more <- recv connection (min 4096 (count - BS8.length bytes))
        if BS8.null more
          then fail "truncated fixture image body"
          else consumeBody connection count (bytes <> more)
  readHeaders connection bytes
    | BS8.pack "\r\n\r\n" `BS8.isInfixOf` bytes = pure bytes
    | BS8.length bytes >= 16384 = fail "Docker fixture headers too large"
    | otherwise = do
        more <- recv connection 4096
        if BS8.null more
          then fail "Docker fixture request ended early"
          else readHeaders connection (bytes <> more)

writeRepoMarkers :: FilePath -> IO ()
writeRepoMarkers repoRoot = do
  writeFile (repoRoot </> "prodbox.cabal") "name: temp\n"
  writeRetainedRootLayout repoRoot
  createDirectoryIfMissing True (repoRoot </> "DEVELOPMENT_PLAN")
  writeFile (repoRoot </> "DEVELOPMENT_PLAN/README.md") "# temp\n"
  createDirectoryIfMissing True (repoRoot </> "pulumi" </> "aws-test")
  writeFile (repoRoot </> "pulumi" </> "aws-test" </> "Pulumi.yaml") "name: aws-test\nruntime: yaml\n"
  createDirectoryIfMissing True (repoRoot </> "pulumi" </> "aws-eks")
  writeFile
    (repoRoot </> "pulumi" </> "aws-eks" </> "Pulumi.yaml")
    "name: aws-eks-test\nruntime: yaml\n"

-- | The retained-root layout `Prodbox.Config.LocalRetainedRoot` validates
-- before an Authority-bound root exists: the prodbox control directory, the
-- retained MinIO volume under it, and the retained Vault volume beside it.
--
-- A fixture repository that omits them makes every reconcile refuse with a
-- layout error, which measures the fixture rather than the command under test.
writeRetainedRootLayout :: FilePath -> IO ()
writeRetainedRootLayout repoRoot = do
  createDirectoryIfMissing True (retainedRoot </> "prodbox" </> "minio" </> "0")
  createDirectoryIfMissing True (retainedRoot </> "vault" </> "vault" </> "0")
 where
  retainedRoot = repoRoot </> ".data"

copySchema :: FilePath -> FilePath -> IO ()
copySchema sourceRoot targetRoot =
  copyFile (sourceRoot </> "prodbox-config-types.dhall") (targetRoot </> "prodbox-config-types.dhall")

gatewayStateResponseJson :: String
gatewayStateResponseJson =
  "{\"node_id\":\"node-a\",\"gateway_owner\":\"node-a\",\"has_active_claim\":true,\"mesh_peers\":[\"node-b\"],\"semantic_member_count\":2,\"signed_replay_assertion_count\":5,\"retained_assertion_count\":7,\"retained_assertion_capacity\":20,\"last_public_ip_observed\":\"203.0.113.10\",\"last_dns_write_ip\":\"203.0.113.10\",\"last_dns_write_at_utc\":\"2026-04-06T10:00:00Z\",\"dns_write_gate\":{\"zone_id\":\"Z123\",\"fqdn\":\"test.example.test\",\"ttl\":60},\"heartbeat_age_seconds\":{\"node-a\":0.0,\"node-b\":1.5}}"

-- | Run @action@ against an ephemeral 127.0.0.1 HTTP server that serves
-- @body@ as JSON once. Returns the loopback port and an 'MVar' holding
-- the first line of the request the server received (e.g. @GET /v1/state HTTP/1.1@).
-- Used by the gateway-status integration test to verify the native HTTP client
-- path that replaced curl shell-outs in Sprint 2.17.
withGatewayStateServer
  :: String
  -> (Int -> MVar String -> IO a)
  -> IO a
withGatewayStateServer body action =
  withSocketsDo $
    bracket
      ( do
          sock <- socket AF_INET Stream defaultProtocol
          setSocketOption sock ReuseAddr 1
          bind sock (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
          listen sock 1
          pure sock
      )
      close
      ( \sock -> do
          addr <- getSocketName sock
          port <- case addr of
            SockAddrInet p _ -> pure (fromIntegral p)
            _ -> ioError (userError "expected IPv4 socket address while allocating a test port")
          requestRef <- newEmptyMVar
          let response =
                "HTTP/1.1 200 OK\r\n"
                  ++ "Content-Type: application/json\r\n"
                  ++ "Content-Length: "
                  ++ show (length body)
                  ++ "\r\n"
                  ++ "Connection: close\r\n"
                  ++ "\r\n"
                  ++ body
          void $ forkIO $ do
            acceptResult <- try (accept sock)
            case acceptResult :: Either SomeException (Socket, SockAddr) of
              Left _ -> pure ()
              Right (client, _) -> do
                requestBytes <- recv client 8192
                let requestText = BS8.unpack requestBytes
                    firstLine = takeWhile (/= '\r') requestText
                putMVar requestRef firstLine
                _ <- try (sendAll client (BS8.pack response)) :: IO (Either SomeException ())
                close client
          action port requestRef
      )

withFakeGatewayDaemonServer
  :: [(String, Int, String)]
  -> (Int -> MVar [String] -> IO a)
  -> IO a
withFakeGatewayDaemonServer responses action =
  withSocketsDo $
    bracket
      ( do
          sock <- socket AF_INET Stream defaultProtocol
          setSocketOption sock ReuseAddr 1
          bind sock (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
          listen sock 8
          pure sock
      )
      close
      ( \sock -> do
          addr <- getSocketName sock
          port <- case addr of
            SockAddrInet p _ -> pure (fromIntegral p)
            _ -> ioError (userError "expected IPv4 socket address while allocating a fake daemon port")
          requestsRef <- newMVar []
          void $ forkIO (fakeGatewayDaemonAcceptLoop sock responses requestsRef)
          action port requestsRef
      )

fakeGatewayDaemonAcceptLoop :: Socket -> [(String, Int, String)] -> MVar [String] -> IO ()
fakeGatewayDaemonAcceptLoop sock responses requestsRef = do
  acceptResult <- try (accept sock)
  case acceptResult :: Either SomeException (Socket, SockAddr) of
    Left _ -> pure ()
    Right (client, _) -> do
      requestBytes <- recv client 8192
      let requestText = BS8.unpack requestBytes
          firstLine = takeWhile (/= '\r') requestText
          path = requestPathFromFirstLine firstLine
          (status, body) =
            case find (\(candidate, _, _) -> candidate == path) responses of
              Just (_, responseStatus, responseBody) -> (responseStatus, responseBody)
              Nothing -> (404, "not found")
      modifyMVar requestsRef (\seen -> pure (seen ++ [firstLine], ()))
      _ <-
        try (sendAll client (BS8.pack (renderFakeGatewayResponse status body)))
          :: IO (Either SomeException ())
      close client
      fakeGatewayDaemonAcceptLoop sock responses requestsRef

requestPathFromFirstLine :: String -> String
requestPathFromFirstLine firstLine =
  case words firstLine of
    _method : path : _ -> path
    _ -> "/"

renderFakeGatewayResponse :: Int -> String -> String
renderFakeGatewayResponse status body =
  "HTTP/1.1 "
    ++ show status
    ++ " "
    ++ fakeGatewayReason status
    ++ "\r\n"
    ++ "Content-Type: "
    ++ (if status >= 200 && status < 300 then "application/json" else "text/plain")
    ++ "\r\n"
    ++ "Content-Length: "
    ++ show (length body)
    ++ "\r\n"
    ++ "Connection: close\r\n\r\n"
    ++ body

fakeGatewayReason :: Int -> String
fakeGatewayReason status =
  case status of
    200 -> "OK"
    404 -> "Not Found"
    503 -> "Service Unavailable"
    _ -> "OK"

allocateTwoLoopbackTcpPorts :: IO (Int, Int)
allocateTwoLoopbackTcpPorts =
  withSocketsDo $
    bracket
      ( do
          first <- socket AF_INET Stream defaultProtocol
          setSocketOption first ReuseAddr 1
          bind first (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
          second <- socket AF_INET Stream defaultProtocol
          setSocketOption second ReuseAddr 1
          bind second (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
          pure (first, second)
      )
      (\(first, second) -> close first >> close second)
      ( \(first, second) -> do
          firstAddr <- getSocketName first
          secondAddr <- getSocketName second
          case (firstAddr, secondAddr) of
            (SockAddrInet firstPort _, SockAddrInet secondPort _) ->
              pure (fromIntegral firstPort, fromIntegral secondPort)
            _ -> ioError (userError "expected IPv4 socket addresses while allocating test ports")
      )

waitForGatewayHealthyProcess :: Int -> ProcessHandle -> FilePath -> FilePath -> IO ()
waitForGatewayHealthyProcess port processHandle stdoutPath stderrPath = go (60 :: Int)
 where
  go 0 = failWithGatewayLogs "gateway daemon did not become healthy"
  go attempts = do
    exitStatus <- getProcessExitCode processHandle
    case exitStatus of
      Just code -> failWithGatewayLogs ("gateway daemon exited before readiness: " ++ show code)
      Nothing -> pure ()
    result <-
      httpGetText
        (defaultHttpConfig {httpRequestTimeoutMicros = 250000})
        ("http://127.0.0.1:" ++ show port ++ "/healthz")
    case result of
      Right "ok\n" -> pure ()
      _ -> threadDelay 100000 >> go (attempts - 1)

  failWithGatewayLogs message = do
    stdoutText <- readFile stdoutPath
    stderrText <- readFile stderrPath
    expectationFailure
      ( unlines
          [ message
          , "gateway stdout:"
          , stdoutText
          , "gateway stderr:"
          , stderrText
          ]
      )

withFakeVaultServer :: (Int -> IO a) -> IO a
withFakeVaultServer action =
  withSocketsDo $
    bracket
      ( do
          sock <- socket AF_INET Stream defaultProtocol
          setSocketOption sock ReuseAddr 1
          bind sock (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
          listen sock 16
          pure sock
      )
      close
      ( \sock -> do
          addr <- getSocketName sock
          port <- case addr of
            SockAddrInet p _ -> pure (fromIntegral p)
            _ -> ioError (userError "expected IPv4 socket address while allocating fake Vault port")
          void $ forkIO (fakeVaultAcceptLoop sock)
          action port
      )

fakeVaultAcceptLoop :: Socket -> IO ()
fakeVaultAcceptLoop sock = do
  acceptResult <- try (accept sock)
  case acceptResult :: Either SomeException (Socket, SockAddr) of
    Left _ -> pure ()
    Right (client, _) -> do
      requestBytes <- recv client 8192
      let requestText = BS8.unpack requestBytes
          body = fakeVaultResponseBody requestText
          response =
            "HTTP/1.1 200 OK\r\n"
              ++ "Content-Type: application/json\r\n"
              ++ "Content-Length: "
              ++ show (length body)
              ++ "\r\n"
              ++ "Connection: close\r\n"
              ++ "\r\n"
              ++ body
      _ <- try (sendAll client (BS8.pack response)) :: IO (Either SomeException ())
      close client
      fakeVaultAcceptLoop sock

fakeVaultResponseBody :: String -> String
fakeVaultResponseBody requestText
  | "GET /v1/sys/seal-status" `isInfixOf` requestText =
      "{\"initialized\":true,\"sealed\":false,\"t\":3,\"n\":5,\"progress\":0}"
  | "POST /v1/auth/kubernetes/login" `isInfixOf` requestText =
      "{\"auth\":{\"client_token\":\"fake-vault-token\"}}"
  | "GET /v1/secret/data/clusters/index" `isInfixOf` requestText =
      fakeVaultKvPayload "{\"children\":[\"child-a\"]}"
  | "GET /v1/secret/data/clusters/child-a/metadata" `isInfixOf` requestText =
      fakeVaultKvPayload
        ( "{\"cluster_id\":\"child-a\","
            ++ "\"vault_address\":\"http://child-vault.example:8200\","
            ++ "\"transit_key\":\"prodbox-child-opaque\","
            ++ "\"vault_namespace\":\"ns-opaque\","
            ++ "\"parent_cluster_id\":\"prodbox-home\","
            ++ "\"endpoints\":{\"api\":\"https://api.child-a.example\"},"
            ++ "\"kubeconfig_reference\":\"vault:secret/clusters/child-a/kubeconfig\","
            ++ "\"account_id\":\"123456789012\","
            ++ "\"pulumi_stacks\":{\"aws-eks\":\"org/prodbox-child-a/aws-eks\"}}"
        )
  | "GET /v1/secret/data/clusters/child-a/bootstrap" `isInfixOf` requestText =
      fakeVaultKvPayload
        ( "{\"cluster_id\":\"child-a\","
            ++ "\"parent_vault_address\":\"http://parent-vault.example:8200\","
            ++ "\"transit_key\":\"prodbox-child-opaque\","
            ++ "\"vault_namespace\":\"ns-opaque\","
            ++ "\"token\":\"s.child-transit\"}"
        )
  | "GET /v1/secret/data/" `isInfixOf` requestText =
      "{\"data\":{\"data\":{\"key\":\"validation-key\",\"access_key_id\":\"test-access-key\",\"secret_access_key\":\"test-secret-key\",\"session_token\":\"test-session-token\",\"minio_access_key\":\"minio-access\",\"minio_secret_key\":\"minio-secret\",\"rootUser\":\"minio-root\",\"rootPassword\":\"minio-root-secret\"}}}"
  | otherwise =
      "{}"

fakeVaultKvPayload :: String -> String
fakeVaultKvPayload payload =
  "{\"data\":{\"data\":{\"payload_json\":" ++ show payload ++ "}}}"

data FakeVaultLifecycleState = FakeVaultLifecycleState
  { fakeVaultLifecycleInitialized :: Bool
  , fakeVaultLifecycleSealed :: Bool
  , fakeVaultLifecycleProgress :: Int
  }
  deriving (Eq, Show)

data FakeVaultHttpResponse = FakeVaultHttpResponse
  { fakeVaultHttpStatus :: Int
  , fakeVaultHttpBody :: String
  }

withFakeVaultLifecycleServer :: (Int -> MVar FakeVaultLifecycleState -> IO a) -> IO a
withFakeVaultLifecycleServer action =
  withSocketsDo $
    bracket
      ( do
          sock <- socket AF_INET Stream defaultProtocol
          setSocketOption sock ReuseAddr 1
          bind sock (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
          listen sock 32
          pure sock
      )
      close
      ( \sock -> do
          addr <- getSocketName sock
          port <- case addr of
            SockAddrInet p _ -> pure (fromIntegral p)
            _ -> ioError (userError "expected IPv4 socket address while allocating fake Vault lifecycle port")
          stateRef <- newMVar (FakeVaultLifecycleState False True 0)
          void $ forkIO (fakeVaultLifecycleAcceptLoop sock stateRef)
          action port stateRef
      )

fakeVaultLifecycleAcceptLoop :: Socket -> MVar FakeVaultLifecycleState -> IO ()
fakeVaultLifecycleAcceptLoop sock stateRef = do
  acceptResult <- try (accept sock)
  case acceptResult :: Either SomeException (Socket, SockAddr) of
    Left _ -> pure ()
    Right (client, _) -> do
      requestBytes <- recv client 8192
      response <- fakeVaultLifecycleResponse (BS8.unpack requestBytes) stateRef
      _ <-
        try (sendAll client (BS8.pack (renderFakeVaultResponse response)))
          :: IO (Either SomeException ())
      close client
      fakeVaultLifecycleAcceptLoop sock stateRef

fakeVaultLifecycleResponse
  :: String -> MVar FakeVaultLifecycleState -> IO FakeVaultHttpResponse
fakeVaultLifecycleResponse requestText stateRef
  | "GET /v1/sys/seal-status" `isInfixOf` requestText = do
      state <- readMVar stateRef
      pure (fakeVaultOk (fakeVaultSealStatusJson state))
  | "POST /v1/sys/init" `isInfixOf` requestText =
      modifyMVar stateRef $ \_ -> do
        let initializedState = FakeVaultLifecycleState True True 0
        pure (initializedState, fakeVaultOk fakeVaultInitJson)
  | "POST /v1/sys/unseal" `isInfixOf` requestText =
      modifyMVar stateRef $ \state -> do
        let unsealedState = state {fakeVaultLifecycleSealed = False, fakeVaultLifecycleProgress = 3}
        pure (unsealedState, fakeVaultOk (fakeVaultSealStatusJson unsealedState))
  | "PUT /v1/sys/seal" `isInfixOf` requestText =
      modifyMVar stateRef $ \state -> do
        let sealedState = state {fakeVaultLifecycleSealed = True, fakeVaultLifecycleProgress = 0}
        pure (sealedState, fakeVaultOk "{}")
  | "GET /v1/sys/mounts" `isInfixOf` requestText =
      pure (fakeVaultOk fakeVaultMountsJson)
  | "GET /v1/sys/auth" `isInfixOf` requestText =
      pure (fakeVaultOk fakeVaultAuthJson)
  | "GET /v1/secret/data/federation/hmac" `isInfixOf` requestText =
      pure (fakeVaultOk "{\"data\":{\"data\":{\"key\":\"integration-federation-hmac\"}}}")
  | "GET /v1/transit/keys/" `isInfixOf` requestText =
      pure (fakeVaultOk "{\"data\":{\"type\":\"aes256-gcm96\"}}")
  | "GET /v1/secret/data/" `isInfixOf` requestText =
      pure (FakeVaultHttpResponse 404 "{\"errors\":[\"missing secret\"]}")
  | "POST /v1/auth/token/create" `isInfixOf` requestText =
      pure (fakeVaultOk "{\"auth\":{\"client_token\":\"s.child-transit\"}}")
  | "POST /v1/pki/issue/prodbox-test" `isInfixOf` requestText =
      pure (fakeVaultOk fakeVaultPkiCertificateJson)
  | "POST /v1/" `isInfixOf` requestText =
      pure (fakeVaultOk "{}")
  | otherwise =
      pure (fakeVaultOk "{}")

renderFakeVaultResponse :: FakeVaultHttpResponse -> String
renderFakeVaultResponse response =
  "HTTP/1.1 "
    ++ show (fakeVaultHttpStatus response)
    ++ " "
    ++ fakeVaultReasonPhrase (fakeVaultHttpStatus response)
    ++ "\r\n"
    ++ "Content-Type: application/json\r\n"
    ++ "Content-Length: "
    ++ show (length (fakeVaultHttpBody response))
    ++ "\r\n"
    ++ "Connection: close\r\n"
    ++ "\r\n"
    ++ fakeVaultHttpBody response

fakeVaultOk :: String -> FakeVaultHttpResponse
fakeVaultOk = FakeVaultHttpResponse 200

fakeVaultReasonPhrase :: Int -> String
fakeVaultReasonPhrase statusCode
  | statusCode == 200 = "OK"
  | statusCode == 404 = "Not Found"
  | otherwise = "OK"

fakeVaultSealStatusJson :: FakeVaultLifecycleState -> String
fakeVaultSealStatusJson state =
  "{\"initialized\":"
    ++ fakeJsonBool (fakeVaultLifecycleInitialized state)
    ++ ",\"sealed\":"
    ++ fakeJsonBool (fakeVaultLifecycleSealed state)
    ++ ",\"t\":3,\"n\":5,\"progress\":"
    ++ show (fakeVaultLifecycleProgress state)
    ++ "}"

fakeJsonBool :: Bool -> String
fakeJsonBool value =
  if value then "true" else "false"

fakeVaultInitJson :: String
fakeVaultInitJson =
  "{\"keys_base64\":[\"vault-unseal-key-1\",\"vault-unseal-key-2\",\"vault-unseal-key-3\",\"vault-unseal-key-4\",\"vault-unseal-key-5\"],\"root_token\":\"fake-root-token\"}"

fakeVaultMountsJson :: String
fakeVaultMountsJson =
  "{\"secret/\":{\"type\":\"kv\",\"options\":{\"version\":\"2\"}},\"transit/\":{\"type\":\"transit\",\"options\":{}},\"pki/\":{\"type\":\"pki\",\"options\":{}}}"

fakeVaultAuthJson :: String
fakeVaultAuthJson =
  "{\"kubernetes/\":{\"type\":\"kubernetes\"}}"

fakeVaultPkiCertificateJson :: String
fakeVaultPkiCertificateJson =
  "{\"data\":{\"certificate\":\"-----BEGIN CERTIFICATE-----\\nFAKE\\n-----END CERTIFICATE-----\\n\"}}"

fakeVaultAddress :: Int -> String
fakeVaultAddress port = "http://127.0.0.1:" ++ show port

-- | Give a fake Vault server a typed deployment coordinate. Production no
-- longer reads an environment escape for this value, so integration fixtures
-- cross the same Tier-0 decoder and validated-context boundary as commands.
injectFixtureVaultAddress :: FilePath -> Int -> IO ()
injectFixtureVaultAddress repoRoot port = do
  tier0Paths <-
    filterM
      doesFileExist
      [ repoRoot </> "prodbox.dhall"
      , repoRoot </> ".build" </> "prodbox.dhall"
      ]
  mapM_ injectAt tier0Paths
 where
  injectAt tier0Path = do
    decoded <- Tier0.decodeProjectConfigDhall tier0Path
    case decoded of
      Left err -> ioError (userError ("could not inject fixture Vault address: " ++ err))
      Right projectConfig -> do
        let priorContext = Tier0.context projectConfig
            updatedContext =
              priorContext
                { Tier0.vault_address = Text.pack (fakeVaultAddress port)
                }
            updatedProject = projectConfig {Tier0.context = updatedContext}
        writeResult <- Tier0.writeTier0AtPath tier0Path updatedProject
        case writeResult of
          Left err -> ioError (userError ("could not write fixture Vault address: " ++ err))
          Right () -> pure ()

-- | Reserve a loopback TCP port with NO listener (bind an OS-assigned port, read
-- it, close). A client connect then gets "connection refused". Used to point the
-- gateway-daemon probe (@PRODBOX_TEST_GATEWAY_NODEPORT@) at a definitely-down
-- endpoint so the fake-Vault-lifecycle test deterministically takes the
-- direct-host Vault seam ('UseDirectHostVaultTestSeam') instead of a *real*
-- cluster gateway daemon that may be listening on the default NodePort when this
-- suite runs inside `prodbox test all` (which would resolve
-- 'VaultDaemonReachable' → 'UseDaemonVaultLifecycle' and query the real Vault).
reserveClosedLoopbackPort :: IO Int
reserveClosedLoopbackPort =
  bracket
    (socket AF_INET Stream defaultProtocol)
    close
    ( \sock -> do
        bind sock (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
        addr <- getSocketName sock
        case addr of
          SockAddrInet p _ -> pure (fromIntegral p)
          _ -> ioError (userError "expected IPv4 socket while reserving a closed loopback port")
    )

fakeVaultLifecycleEnvironment :: FilePath -> Int -> IO [(String, String)]
fakeVaultLifecycleEnvironment repoRoot port = do
  injectFixtureVaultAddress repoRoot port
  currentEnvironment <- getEnvironment
  closedGatewayNodePort <- reserveClosedLoopbackPort
  pure
    ( ("PRODBOX_TEST_GATEWAY_NODEPORT", show closedGatewayNodePort)
        : filter
          ( \(key, _) ->
              key /= "PRODBOX_TEST_HOST_VAULT_TOKEN"
                && key /= "PRODBOX_TEST_HOST_VAULT_KV"
                && key /= "PRODBOX_TEST_GATEWAY_NODEPORT"
          )
          currentEnvironment
    )

writeFakeVaultToken :: FilePath -> IO ()
writeFakeVaultToken path = writeFile path "fake-service-account-jwt\n"

-- | Sprint 7.18 / Sprint 1.42 Part B: establish the root sealed-Vault bootstrap
-- floor by writing the Tier-0 @prodbox.dhall@ at the repo root. The floor is
-- projected straight off @prodbox.dhall@'s @context@ (there is no separate
-- @prodbox-basics.json@), so a root context with the supplied Vault address,
-- Shamir seal mode, and no parent ref is the whole floor surface the binary's
-- 'loadUnencryptedBasics' reads. The same file now also carries the operator
-- config under @parameters@ (the retired @prodbox-config.dhall@ payload), so a
-- command that loads the operator config — federation register, nuke — reads it
-- from the one Tier-0 file. @prodbox.dhall@ is self-contained (no imports), so
-- this single record is sufficient.
secretRefTypeDhall :: String
secretRefTypeDhall =
  "< Vault : { mount : Text, path : Text, field : Text }"
    ++ " | TransitKey : Text"
    ++ " | Prompt : { name : Text, purpose : Text }"
    ++ " | TestPlaintext : Text"
    ++ " >"

vaultSecretRefDhall :: String -> String -> String -> String
vaultSecretRefDhall mount path field =
  unlines
    [ secretRefTypeDhall ++ ".Vault"
    , "  { mount = " ++ show mount
    , "  , path = " ++ show path
    , "  , field = " ++ show field
    , "  }"
    ]

lifecycleProviderVaultPath :: String
lifecycleProviderVaultPath = "aws/lifecycle-provider"

-- | The legacy fixture path used only to prove that Tier-0/IAM-only commands
-- do not write ZeroSSL EAB material around the external-ingress protocol.
acmeEabVaultPath :: String
acmeEabVaultPath = "acme/eab"

fakeVaultKvDir :: FilePath -> FilePath
fakeVaultKvDir repoRoot = repoRoot </> "fake-vault-kv"

seedFakeVaultAwsCredentials
  :: FilePath -> String -> String -> String -> Maybe String -> String -> IO ()
seedFakeVaultAwsCredentials repoRoot path accessKeyId secretAccessKey sessionTokenValue regionValue = do
  writeFakeVaultField repoRoot "secret" path "access_key_id" accessKeyId
  writeFakeVaultField repoRoot "secret" path "secret_access_key" secretAccessKey
  writeFakeVaultField repoRoot "secret" path "session_token" (maybe "" id sessionTokenValue)
  writeFakeVaultField repoRoot "secret" path "region" regionValue

writeFakeVaultField :: FilePath -> String -> String -> String -> String -> IO ()
writeFakeVaultField repoRoot mount path field value = do
  let objectDir = fakeVaultKvDir repoRoot </> mount </> path
  createDirectoryIfMissing True objectDir
  writeFile (objectDir </> field) value

readFakeVaultField :: FilePath -> String -> String -> String -> IO String
readFakeVaultField repoRoot mount path field =
  readFile (fakeVaultKvDir repoRoot </> mount </> path </> field)

indentFixture :: Int -> String -> String
indentFixture spaces =
  unlines . map (replicate spaces ' ' ++) . lines

fakeAwsEnvironment :: FilePath -> IO [(String, String)]
fakeAwsEnvironment repoRoot = do
  fakeBin <- writeFakeAwsScript repoRoot
  currentEnvironment <- getEnvironment
  let existingPath = maybe "" id (lookup "PATH" currentEnvironment)
      updatedPath = fakeBin ++ ":" ++ existingPath
      filtered =
        filter
          ( \(k, _) ->
              k /= "PATH"
                && k /= "PRODBOX_ALLOW_NON_TTY_INTERACTIVE"
                && k /= "PRODBOX_TEST_HOST_VAULT_KV_DIR"
                && k /= "PRODBOX_TEST_HOST_CAPACITY"
          )
          currentEnvironment
  pure
    ( ("PATH", updatedPath)
        : ("PRODBOX_ALLOW_NON_TTY_INTERACTIVE", "1")
        : ("PRODBOX_TEST_HOST_VAULT_KV_DIR", fakeVaultKvDir repoRoot)
        : ( "PRODBOX_TEST_HOST_CAPACITY"
          , "milli_cpu=10000,memory_mib=18432,ephemeral_storage_mib=100000,durable_storage_mib=180000"
          )
        : filtered
    )

-- | Sprint 6.6: a fake @aws@ for the no-install cascade. It answers exactly the
-- two read-only calls that arm makes and records every argv with an
-- unambiguous separator, so a test can reject any other verb. The mode selects
-- the answer: a clean sweep, one escaped resource, or a hosted zone the
-- credential cannot see.
fakeCascadeAwsEnvironment :: FilePath -> String -> [(String, String)] -> IO [(String, String)]
fakeCascadeAwsEnvironment repoRoot mode baseEnvVars = do
  let binDir = repoRoot </> "fake-cascade-aws-bin"
  createDirectoryIfMissing True binDir
  -- The mode is written into the script rather than passed in the environment:
  -- the admin AWS environment the command builds does not inherit custom
  -- variables, so a variable would silently read as unset.
  writeExecutable (binDir </> "aws") (fakeCascadeAwsScript repoRoot mode)
  let existingPath = maybe "" id (lookup "PATH" baseEnvVars)
  pure (("PATH", binDir ++ ":" ++ existingPath) : filter ((/= "PATH") . fst) baseEnvVars)

fakeCascadeAwsScript :: FilePath -> String -> String
fakeCascadeAwsScript repoRoot mode =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_file=" ++ show (repoRoot </> "fake-cascade-aws.txt")
    , "mode=" ++ show mode
    , "first=1"
    , "for arg in \"$@\"; do"
    , "  if [[ $first -eq 0 ]]; then printf '|' >> \"$record_file\"; fi"
    , "  first=0"
    , "  printf '%s' \"$arg\" >> \"$record_file\""
    , "done"
    , "printf '\\n' >> \"$record_file\""
    , "case \"$1 $2\" in"
    , "  'resourcegroupstaggingapi get-resources')"
    , "    if [[ $mode == escaped ]]; then"
    , "      printf '%s\\n' " ++ show escapedPage
    , "    else"
    , "      printf '%s\\n' '{\"ResourceTagMappingList\":[],\"PaginationToken\":\"\"}'"
    , "    fi"
    , "    ;;"
    , "  'route53 get-hosted-zone')"
    , "    if [[ $mode == zone-missing ]]; then"
    , "      printf '%s\\n' 'An error occurred (NoSuchHostedZone) when calling the GetHostedZone operation: no such zone' >&2"
    , "      exit 254"
    , "    fi"
    , "    printf '%s\\n' '{\"HostedZone\":{\"Id\":\"/hostedzone/Z1234567890ABC\",\"Name\":\"example.test.\"}}'"
    , "    ;;"
    , "  *)"
    , "    printf 'fake aws: unexpected call: %s\\n' \"$*\" >&2"
    , "    exit 2"
    , "    ;;"
    , "esac"
    ]
 where
  escapedPage =
    "{\"ResourceTagMappingList\":[{\"ResourceARN\":\"arn:aws:ec2:"
      ++ fixtureAwsRegion FixtureUsEast1
      ++ ":123456789012:vpc/vpc-escaped\",\"Tags\":[{\"Key\":\"prodbox.io/managed-by\",\"Value\":\"prodbox\"}]}],\"PaginationToken\":\"\"}"

-- | Sprint 8.10 built-frontend fixture.  Every supported arm is read-only and
-- records its argv with an unambiguous separator so the test can reject
-- mutation verbs as well as assert the exact semantic probes were reached.
fakeSesReadinessEnvironment :: FilePath -> String -> IO [(String, String)]
fakeSesReadinessEnvironment repoRoot mode = do
  let binDir = repoRoot </> "fake-ses-readiness-bin"
      scriptPath = binDir </> "aws"
  createDirectoryIfMissing True binDir
  writeExecutable scriptPath (fakeSesReadinessAwsScript repoRoot)
  currentEnvironment <- getEnvironment
  let existingPath = maybe "" id (lookup "PATH" currentEnvironment)
      updatedPath = binDir ++ ":" ++ existingPath
      filtered =
        filter
          ( \(key, _) ->
              key /= "PATH"
                && key /= "PRODBOX_FAKE_SES_READINESS_MODE"
                && key /= "PRODBOX_TEST_HOST_VAULT_KV_DIR"
          )
          currentEnvironment
  pure
    ( ("PATH", updatedPath)
        : ("PRODBOX_FAKE_SES_READINESS_MODE", mode)
        : ("PRODBOX_TEST_HOST_VAULT_KV_DIR", fakeVaultKvDir repoRoot)
        : filtered
    )

fakeSesReadinessAwsScript :: FilePath -> String
fakeSesReadinessAwsScript repoRoot =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_file=" ++ show (repoRoot </> "fake-ses-readiness-aws.txt")
    , "mode=${PRODBOX_FAKE_SES_READINESS_MODE:?}"
    , "first=1"
    , "for arg in \"$@\"; do"
    , "  if [[ $first -eq 0 ]]; then printf '|' >> \"$record_file\"; fi"
    , "  first=0"
    , "  printf '%s' \"$arg\" >> \"$record_file\""
    , "done"
    , "printf '\\n' >> \"$record_file\""
    , "case \"$*\" in"
    , "  '--version')"
    , "    printf 'aws-cli/2.31.0 Python/3.13 Linux/fixture\\n'"
    , "    ;;"
    , "  'sts get-caller-identity --output json')"
    , "    printf '%s\\n' '{\"Account\":\"123456789012\",\"Arn\":\"arn:aws:iam::123456789012:user/prodbox\",\"UserId\":\"AIDASESREADY\"}'"
    , "    ;;"
    , "  'route53 get-hosted-zone --id Z1234567890ABC --output json')"
    , "    printf '%s\\n' '{\"HostedZone\":{\"Id\":\"/hostedzone/Z1234567890ABC\",\"Name\":\"example.test.\"}}'"
    , "    ;;"
    , "  'sesv2 get-email-identity --email-identity test.example.test --output json')"
    , "    if [[ $mode == identity-failed ]]; then"
    , "      printf '%s\\n' '{\"IdentityType\":\"DOMAIN\",\"VerifiedForSendingStatus\":false,\"VerificationStatus\":\"SUCCESS\",\"DkimAttributes\":{\"SigningEnabled\":true,\"Status\":\"SUCCESS\"}}'"
    , "    else"
    , "      printf '%s\\n' '{\"IdentityType\":\"DOMAIN\",\"VerifiedForSendingStatus\":true,\"VerificationStatus\":\"SUCCESS\",\"DkimAttributes\":{\"SigningEnabled\":true,\"Status\":\"SUCCESS\"}}'"
    , "    fi"
    , "    ;;"
    , "  'route53 list-resource-record-sets --hosted-zone-id Z1234567890ABC --output json')"
    , ( "    printf '%s\\n' '{\"ResourceRecordSets\":[{\"Name\":\"inbox.test.example.test.\",\"Type\":\"MX\",\"TTL\":300,\"ResourceRecords\":[{\"Value\":\"10 inbound-smtp."
          <> (fixtureAwsRegion FixtureUsEast1)
          <> ".amazonaws.com\"}]}]}'"
      )
    , "    ;;"
    , "  'ses describe-active-receipt-rule-set --output json')"
    , "    printf '%s\\n' '{\"Metadata\":{\"Name\":\"prodbox-receive-rule-set\"},\"Rules\":[{\"Name\":\"prodbox-capture-all-mail\",\"Enabled\":true,\"Recipients\":[\"inbox.test.example.test\"],\"Actions\":[{\"S3Action\":{\"BucketName\":\"prodbox-test-ses-capture\",\"ObjectKeyPrefix\":\"inbound/\"}}]}]}'"
    , "    ;;"
    , "  's3api list-objects-v2 --bucket prodbox-test-ses-capture --prefix .prodbox-readiness-capability-probe --max-keys 1 --output json')"
    , "    printf '%s\\n' '{\"KeyCount\":1,\"Contents\":[{\"Key\":\".prodbox-readiness-capability-probe\"}]}'"
    , "    ;;"
    , "  s3api\\ get-object\\ --bucket\\ prodbox-test-ses-capture\\ --key\\ .prodbox-readiness-capability-probe\\ *\\ --output\\ json)"
    , "    printf '%s\\n' '{\"ContentLength\":38,\"ContentType\":\"text/plain\"}'"
    , "    ;;"
    , "  *)"
    , "    printf 'unsupported fake SES-readiness aws command: %s\\n' \"$*\" >&2"
    , "    exit 2"
    , "    ;;"
    , "esac"
    ]

fakeAwsHarnessEnvironment :: FilePath -> FilePath -> IO [(String, String)]
fakeAwsHarnessEnvironment repoRoot binaryPath = do
  fakeBin <- writeFakeAwsScript repoRoot
  writeExecutable (fakeBin </> "cabal") (fakeCabalListBinScript binaryPath)
  currentEnvironment <- getEnvironment
  let existingPath = maybe "" id (lookup "PATH" currentEnvironment)
      updatedPath = fakeBin ++ ":" ++ existingPath
      filtered =
        filter
          ( \(k, _) ->
              k /= "PATH"
                && k /= "PRODBOX_ALLOW_NON_TTY_INTERACTIVE"
                && k /= "PRODBOX_TEST_HOST_VAULT_KV_DIR"
          )
          currentEnvironment
  pure
    ( ("PATH", updatedPath)
        : ("PRODBOX_ALLOW_NON_TTY_INTERACTIVE", "1")
        : ("PRODBOX_TEST_HOST_VAULT_KV_DIR", fakeVaultKvDir repoRoot)
        : filtered
    )

writeFakeAwsScript :: FilePath -> IO FilePath
writeFakeAwsScript repoRoot = do
  let binDir = repoRoot </> "bin"
      stateDir = repoRoot </> "fake-aws-state"
      scriptPath = binDir </> "aws"
  createDirectoryIfMissing True binDir
  createDirectoryIfMissing True stateDir
  writeFile scriptPath (fakeAwsScript stateDir)
  permissions <- getPermissions scriptPath
  setPermissions scriptPath permissions {executable = True}
  pure binDir

fakeChartEnvironment :: FilePath -> IO [(String, String)]
fakeChartEnvironment repoRoot = do
  fakeBin <- writeFakeChartScripts repoRoot
  integrationExecutable <- getExecutablePath
  let kubeconfigPath = repoRoot </> "fake-chart-kubeconfig"
  writeFile kubeconfigPath "apiVersion: v1\nkind: Config\n"
  let recordDir = repoRoot </> "fake-chart-state"
  createDirectoryIfMissing True recordDir
  currentEnvironment <- getEnvironment
  let existingPath = maybe "" id (lookup "PATH" currentEnvironment)
      updatedPath = fakeBin ++ ":" ++ existingPath
      baseEnvironment =
        filter
          ( \(key, _) ->
              key /= "PATH"
                && key /= "PRODBOX_FAKE_CHART_RECORD_DIR"
                && key /= "PRODBOX_FAKE_HELM_LIST_JSON"
                && key /= "PRODBOX_FAKE_PATRONI_STAGED_RESTORE"
                && key /= "PRODBOX_FAKE_PATRONI_LIVE_ANCHOR"
                && key /= "PRODBOX_FAKE_PUBLIC_EDGE_NAMESPACE_ABSENT"
                && key /= "PRODBOX_TEST_HOST_VAULT_KV"
          )
          currentEnvironment
  pure
    ( [ ("PATH", updatedPath)
      , ("PRODBOX_FAKE_CHART_RECORD_DIR", recordDir)
      , ("PRODBOX_FAKE_HELM_LIST_JSON", "[]")
      , ("PRODBOX_TEST_HOST_VAULT_KV", "allow")
      , ("PRODBOX_TEST_INTEGRATION_EXECUTABLE", integrationExecutable)
      , ("PRODBOX_TEST_AUTHORITY_CONFIG_PATH", repoRoot </> "prodbox.dhall")
      , ("KUBECONFIG", kubeconfigPath)
      ]
        ++ baseEnvironment
    )

writeFakeChartScripts :: FilePath -> IO FilePath
writeFakeChartScripts repoRoot = do
  let binDir = repoRoot </> "bin"
  createDirectoryIfMissing True binDir
  writeExecutable (binDir </> "helm") fakeHelmScript
  writeExecutable (binDir </> "kubectl") fakeKubectlScript
  pure binDir

writeExecutable :: FilePath -> String -> IO ()
writeExecutable scriptPath scriptContents = do
  writeFile scriptPath scriptContents
  permissions <- getPermissions scriptPath
  setPermissions scriptPath permissions {executable = True}

fakeHelmScript :: String
fakeHelmScript =
  unlines
    [ "#!/usr/bin/env bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_CHART_RECORD_DIR:?}"
    , "/bin/mkdir -p \"$record_dir\""
    , "append_args() {"
    , "  local target=$1"
    , "  shift"
    , "  local first=1"
    , "  for arg in \"$@\"; do"
    , "    if [[ $first -eq 0 ]]; then"
    , "      printf '|' >> \"$target\""
    , "    fi"
    , "    first=0"
    , "    printf '%s' \"$arg\" >> \"$target\""
    , "  done"
    , "  printf '\\n' >> \"$target\""
    , "}"
    , "case \"${1:-}\" in"
    , "  list)"
    , "    printf '%s\\n' \"${PRODBOX_FAKE_HELM_LIST_JSON:-[]}\""
    , "    ;;"
    , "  status)"
    , "    append_args \"$record_dir/helm-status.txt\" \"$@\""
    , "    release=${2:-}"
    , "    namespace=''"
    , "    shift 2"
    , "    while [[ $# -gt 0 ]]; do"
    , "      if [[ \"${1:-}\" == '--namespace' ]]; then"
    , "        namespace=${2:-}"
    , "        shift 2"
    , "      else"
    , "        shift"
    , "      fi"
    , "    done"
    , "    inventory=${PRODBOX_FAKE_HELM_LIST_JSON:-[]}"
    , "    compact_inventory=${inventory//[[:space:]]/}"
    , "    deployed_entry=\"\\\"name\\\":\\\"$release\\\",\\\"namespace\\\":\\\"$namespace\\\",\\\"status\\\":\\\"deployed\\\"\""
    , "    if [[ \"$compact_inventory\" == *\"$deployed_entry\"* ]]; then"
    , "      printf '{\"name\":\"%s\",\"namespace\":\"%s\",\"info\":{\"status\":\"deployed\"}}\\n' \"$release\" \"$namespace\""
    , "    else"
    , "      printf 'Error: release: not found\\n' >&2"
    , "      exit 1"
    , "    fi"
    , "    ;;"
    , "  upgrade)"
    , "    append_args \"$record_dir/helm-upgrade.txt\" \"$@\""
    , "    ;;"
    , "  uninstall)"
    , "    append_args \"$record_dir/helm-uninstall.txt\" \"$@\""
    , "    ;;"
    , "  *)"
    , "    printf 'unsupported fake helm command: %s\\n' \"$*\" >&2"
    , "    exit 1"
    , "    ;;"
    , "esac"
    ]

fakeKubectlScript :: String
fakeKubectlScript =
  unlines
    [ "#!/usr/bin/env bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_CHART_RECORD_DIR:?}"
    , "/bin/mkdir -p \"$record_dir\""
    , "append_args() {"
    , "  local target=$1"
    , "  shift"
    , "  local first=1"
    , "  for arg in \"$@\"; do"
    , "    if [[ $first -eq 0 ]]; then"
    , "      printf '|' >> \"$target\""
    , "    fi"
    , "    first=0"
    , "    printf '%s' \"$arg\" >> \"$target\""
    , "  done"
    , "  printf '\\n' >> \"$target\""
    , "}"
    , "next_apply_target() {"
    , "  local counter_file=\"$record_dir/kubectl-apply.count\""
    , "  local count=0"
    , "  if [[ -f \"$counter_file\" ]]; then"
    , "    count=$(/bin/cat \"$counter_file\")"
    , "  fi"
    , "  count=$((count + 1))"
    , "  printf '%s' \"$count\" > \"$counter_file\""
    , "  printf '%s/kubectl-apply-%s.json' \"$record_dir\" \"$count\""
    , "}"
    , "next_counter() {"
    , "  local counter_file=$1"
    , "  local count=0"
    , "  if [[ -f \"$counter_file\" ]]; then"
    , "    count=$(/bin/cat \"$counter_file\")"
    , "  fi"
    , "  count=$((count + 1))"
    , "  printf '%s' \"$count\" > \"$counter_file\""
    , "  printf '%s' \"$count\""
    , "}"
    , "append_args \"$record_dir/kubectl.txt\" \"$@\""
    , "requested_namespace=default"
    , "previous_argument="
    , "for argument in \"$@\"; do"
    , "  if [[ \"$previous_argument\" == '--namespace' ]]; then requested_namespace=$argument; break; fi"
    , "  previous_argument=$argument"
    , "done"
    , "if [[ \"${1:-}\" == '--kubeconfig' ]]; then shift 2; fi"
    , "if [[ \"${1:-}\" == '--namespace' ]]; then shift 2; fi"
    , "case \"${1:-} ${2:-}\" in"
    , "  'create token')"
    , "    printf 'fixture-service-account-token'"
    , "    ;;"
    , "  'auth can-i')"
    , "    printf 'yes\n'"
    , "    ;;"
    , "  'get serviceaccount')"
    , "    printf '%s\n%s\nfalse\n' \"$requested_namespace\" \"${3:-}\""
    , "    ;;"
    , "  'get service')"
    , "    if [[ \"${3:-}\" == 'kubernetes' ]]; then printf '10.43.0.1'; else exit 1; fi"
    , "    ;;"
    , "  'get namespace')"
    , "    if [[ \"${PRODBOX_FAKE_PUBLIC_EDGE_NAMESPACE_ABSENT:-}\" == 'true' ]]; then"
    , "      exit 0"
    , "    fi"
    , "    printf '{\"apiVersion\":\"v1\",\"kind\":\"Namespace\",\"metadata\":{\"name\":\"%s\"}}\\n' \"${3:-}\""
    , "    ;;"
    , "  'port-forward service/lifecycle-authority'|'port-forward deployment/authority-backup'|'port-forward service/target-secret-agent'|'port-forward service/tls-retention')"
    , "    mapping=${!#}"
    , "    local_port=${mapping%%:*}"
    , "    exec \"${PRODBOX_TEST_INTEGRATION_EXECUTABLE:?}\" --fixture-authority-server \"$local_port\""
    , "    ;;"
    , "  'get nodes')"
    , "    cat <<'JSON'"
    , "{\"items\":[{\"metadata\":{\"name\":\"bathurst\"}}]}"
    , "JSON"
    , "    ;;"
    , "  'get crd')"
    , "    if [[ \"${3:-}\" == 'perconapgclusters.pgv2.percona.com' ]]; then"
    , "      printf 'customresourcedefinition.apiextensions.k8s.io/perconapgclusters.pgv2.percona.com\\n'"
    , "    else"
    , "      printf 'Error from server (NotFound): customresourcedefinitions \"%s\" not found\\n' \"${3:-crd}\" >&2"
    , "      exit 1"
    , "    fi"
    , "    ;;"
    , "  'get deployment')"
    , "    if [[ \"${3:-}\" == 'postgres-operator' && \"$*\" == *'--namespace postgres-operator'* ]]; then"
    , "      # Sprint 4.43: the operator gate now reads the Available condition"
    , "      # (not -o name). A ready operator reports Available=True."
    , "      if [[ \"$*\" == *'jsonpath={.status.conditions'* ]]; then"
    , "        printf 'True'"
    , "      else"
    , "        printf 'deployment.apps/postgres-operator\\n'"
    , "      fi"
    , "    else"
    , "      printf 'Error from server (NotFound): deployments \"%s\" not found\\n' \"${3:-deployment}\" >&2"
    , "      exit 1"
    , "    fi"
    , "    ;;"
    , "  'get perconapgclusters.pgv2.percona.com')"
    , "    if [[ \"$*\" == *'jsonpath={.status.state}'* ]]; then"
    , "      printf 'ready\\n'"
    , "    elif [[ \"$*\" == *'jsonpath={.status.postgres.ready}'* ]]; then"
    , "      if [[ \"${PRODBOX_FAKE_PATRONI_STAGED_RESTORE:-}\" == 'true' ]]; then"
    , "        ready_count=$(next_counter \"$record_dir/patroni-ready.count\")"
    , "        if [[ \"$ready_count\" -eq 1 ]]; then"
    , "          printf '1\\n'"
    , "        else"
    , "          printf '3\\n'"
    , "        fi"
    , "      else"
    , "        : > \"$record_dir/patroni-ready.count\""
    , "        printf '3\\n'"
    , "      fi"
    , "    else"
    , "      printf 'Error from server (NotFound): perconapgclusters \"%s\" not found\\n' \"${3:-perconapgclusters.pgv2.percona.com}\" >&2"
    , "      exit 1"
    , "    fi"
    , "    ;;"
    , "  'get endpoints')"
    , -- Sprint 3.34 made `endpoints/kubernetes` a live observation on the
      -- chart-reconcile path (the post-DNAT Kubernetes API egress
      -- coordinate). The fake boundary did not serve it, so every fixture
      -- reconcile failed with `endpoints \"kubernetes\" not found`. The
      -- address is RFC 5737 TEST-NET-1, unmistakably synthetic; the port is
      -- the real post-DNAT API port, which is the coordinate under test.
      "    if [[ \"${3:-}\" == 'kubernetes' && \"$*\" == *'jsonpath={.subsets[*].addresses[*].ip}'* ]]; then"
    , "      printf '192.0.2.10|6443'"
    , "    else"
    , "      printf 'Error from server (NotFound): endpoints \"%s\" not found\\n' \"${3:-endpoints}\" >&2"
    , "      exit 1"
    , "    fi"
    , "    ;;"
    , "  'get pods')"
    , "    if [[ \"$*\" == *'postgres-operator.crunchydata.com/cluster=prodbox-vscode-pg,postgres-operator.crunchydata.com/role=primary'* ]]; then"
    , "      if [[ \"${PRODBOX_FAKE_PATRONI_LIVE_ANCHOR:-}\" == 'true' ]] || [[ -f \"$record_dir/patroni-ready.count\" ]]; then"
    , "        cat <<'JSON'"
    , "{\"items\":[{\"metadata\":{\"name\":\"prodbox-vscode-pg-instance1-hh5k-0\"},\"spec\":{\"volumes\":[{\"name\":\"postgres-data\",\"persistentVolumeClaim\":{\"claimName\":\"prodbox-vscode-pg-instance1-hh5k-pgdata\"}}]}}]}"
    , "JSON"
    , "      else"
    , "        printf '{\"items\":[]}\\n'"
    , "      fi"
    , "    else"
    , "      printf 'Error from server (NotFound): pods not found\\n' >&2"
    , "      exit 1"
    , "    fi"
    , "    ;;"
    , "  'get pvc')"
    , "    if [[ \"${3:-}\" == 'prodbox-vscode-pg-instance1-hh5k-pgdata' && \"$*\" == *'jsonpath={.spec.volumeName}'* ]]; then"
    , "      printf 'prodbox-retained-vscode-prodbox-vscode-pg-0\\n'"
    , "    elif [[ \"$*\" == *'postgres-operator.crunchydata.com/cluster=prodbox-vscode-pg,postgres-operator.crunchydata.com/data=postgres'* ]]; then"
    , "      if [[ \"${PRODBOX_FAKE_PATRONI_STAGED_RESTORE:-}\" == 'true' ]]; then"
    , "        claim_list_count=$(next_counter \"$record_dir/patroni-claim-list.count\")"
    , "        if [[ \"$claim_list_count\" -eq 1 ]]; then"
    , "          /bin/cat <<'JSON'"
    , "{\"items\":[{\"metadata\":{\"name\":\"prodbox-vscode-pg-instance1-hh5k-pgdata\"},\"spec\":{\"volumeName\":\"prodbox-retained-vscode-prodbox-vscode-pg-0\"}}]}"
    , "JSON"
    , "          exit 0"
    , "        fi"
    , "      fi"
    , "      cat <<'JSON'"
    , "{\"items\":[{\"metadata\":{\"name\":\"prodbox-vscode-pg-instance1-5krm-pgdata\"}},{\"metadata\":{\"name\":\"prodbox-vscode-pg-instance1-hh5k-pgdata\"},\"spec\":{\"volumeName\":\"prodbox-retained-vscode-prodbox-vscode-pg-0\"}},{\"metadata\":{\"name\":\"prodbox-vscode-pg-instance1-rwr7-pgdata\"}}]}"
    , "JSON"
    , "    else"
    , "      printf 'Error from server (NotFound): persistentvolumeclaims \"%s\" not found\\n' \"${3:-pvc}\" >&2"
    , "      exit 1"
    , "    fi"
    , "    ;;"
    , "  'get secret')"
    , "    if [[ \"$*\" == *'--ignore-not-found=true'* ]]; then"
    , "      # Sprint 8.7 public-edge cert preserve/restore reads the"
    , "      # public-edge-tls Secret with --ignore-not-found=true. Real kubectl"
    , "      # returns exit 0 with empty output for an absent resource; the Secret"
    , "      # is modeled absent in the charts suite, so honor the flag."
    , "      exit 0"
    , "    elif [[ \"$*\" == *'go-template={{index .data \"password\" | base64decode}}'* ]]; then"
    , "      printf 'Error from server (NotFound): secrets \"%s\" not found\\n' \"${3:-secret}\" >&2"
    , "      exit 1"
    , "    else"
    , "      printf 'Error from server (NotFound): secrets \"%s\" not found\\n' \"${3:-secret}\" >&2"
    , "      exit 1"
    , "    fi"
    , "    ;;"
    , "  'get certificate.cert-manager.io')"
    , "    if [[ \"$*\" == *'--ignore-not-found=true'* ]]; then"
    , "      # Sprint 8.7 public-edge cert preserve reads the Certificate with"
    , "      # --ignore-not-found=true; modeled absent, so exit 0 with empty output."
    , "      exit 0"
    , "    fi"
    , "    printf 'Error from server (NotFound): certificates \"%s\" not found\\n' \"${3:-certificate}\" >&2"
    , "    exit 1"
    , "    ;;"
    , "  'get pv')"
    , "    printf 'Error from server (NotFound): persistentvolumes \"%s\" not found\\n' \"${3:-pv}\" >&2"
    , "    exit 1"
    , "    ;;"
    , "  'apply -f')"
    , "    target=$(next_apply_target)"
    , "    if [[ \"${3:-}\" == \"-\" ]]; then"
    , "      # Sprint 2.19: `kubectl apply -f -` (stdin) is the second leg of the"
    , "      # `create namespace --dry-run | apply -f -` and `create secret"
    , "      # generic --dry-run | apply -f -` pipelines used by"
    , "      # ensureGatewayMinioBootstrap. Capture stdin to the apply-target file."
    , "      cat > \"$target\""
    , "    else"
    , "      cp \"${3:?}\" \"$target\""
    , "    fi"
    , "    ;;"
    , "  'create -f')"
    , "    # The chart runtime creates the exact empty TLS restore slot rather"
    , "    # than applying over an existing Secret. Preserve the manifest for"
    , "    # boundary diagnosis and model a successful first create."
    , "    cp \"${3:?}\" \"$record_dir/kubectl-create-manifest.json\""
    , "    ;;"
    , "  'delete pod'|'delete pvc'|'delete pv'|'delete namespace')"
    , "    append_args \"$record_dir/kubectl-delete.txt\" \"$@\""
    , "    ;;"
    , "  'create namespace')"
    , "    # Sprint 2.19: ensureGatewayMinioBootstrap pre-creates the gateway"
    , "    # namespace via `kubectl create namespace ... --dry-run=client -o yaml`"
    , "    # piped to `kubectl apply -f -`. The fake replies with a minimal"
    , "    # namespace manifest so the dry-run leg succeeds; the apply-f-stdin"
    , "    # leg is handled by the existing `apply -f -` arm."
    , "    append_args \"$record_dir/kubectl-create.txt\" \"$@\""
    , "    printf 'apiVersion: v1\\nkind: Namespace\\nmetadata:\\n  name: %s\\n' \"${3:-}\""
    , "    ;;"
    , "  'create secret')"
    , "    # Sprint 2.19: ensureGatewayMinioBootstrap pre-creates the"
    , "    # gateway-minio-creds Secret via `kubectl create secret generic ...`"
    , "    # with --dry-run=client. The fake replies with a minimal Secret"
    , "    # manifest so the dry-run leg succeeds."
    , "    append_args \"$record_dir/kubectl-create.txt\" \"$@\""
    , "    printf 'apiVersion: v1\\nkind: Secret\\nmetadata:\\n  name: %s\\ntype: Opaque\\n' \"${4:-secret}\""
    , "    ;;"
    , "  *)"
    , "    printf 'unsupported fake kubectl command: %s\\n' \"$*\" >&2"
    , "    exit 1"
    , "    ;;"
    , "esac"
    ]

-- | Override a fake RKE2 environment to model the real already-deleted-cluster
-- host: no RKE2 install present, and the in-cluster MinIO residue backend
-- unreachable. Used by the Sprint 4.25 no-op-success delete tests to prove the
-- short-circuit wins over the Sprint 4.19 fail-closed residue gate.
withNoRke2Install :: [(String, String)] -> [(String, String)]
withNoRke2Install baseEnvVars =
  ("PRODBOX_TEST_RKE2_PRESENT", "0")
    : ("PRODBOX_TEST_RESIDUE_UNREACHABLE", "1")
    : filter (not . overridden . fst) baseEnvVars
 where
  overridden key =
    key
      `elem` [ "PRODBOX_TEST_RKE2_PRESENT"
             , "PRODBOX_TEST_RESIDUE_UNREACHABLE"
             ]

withColdBrokerBackend :: FilePath -> IO value -> IO value
withColdBrokerBackend startup action =
  bracket (forkIO awaitStartup) killThread (const action)
 where
  awaitStartup = do
    started <- doesFileExist (startup ++ ".started")
    if started
      then do
        threadDelay 2000000
        writeFile (startup ++ ".backend-ready") "ready\n"
      else threadDelay 10000 >> awaitStartup

fakeRke2Environment :: FilePath -> IO [(String, String)]
fakeRke2Environment repoRoot = do
  fakeBin <- writeFakeRke2Scripts repoRoot
  let recordDir = repoRoot </> "fake-rke2-state"
      socketPath = repoRoot </> "fake-rke2-containerd.sock"
      endpointStatusRoot = repoRoot </> "fake-endpoint-status"
      kubeconfigPath = repoRoot </> "fake-rke2-kubeconfig"
  createDirectoryIfMissing True recordDir
  bootstrapFixtures <- writeBootstrapSourceFixture repoRoot
  writeFile
    (recordDir </> "bootstrap-image-identities")
    ( concatMap
        (\(reference, identity, _) -> Text.unpack reference <> "|" <> Text.unpack identity <> "\n")
        bootstrapFixtures
    )
  writeFile socketPath ""
  writeFile kubeconfigPath "server: https://127.0.0.1:6443\n"
  createDirectoryIfMissing True endpointStatusRoot
  writeFile (endpointStatusRoot </> "rke2-pod.status") ""
  currentEnvironment <- getEnvironment
  integrationExecutable <- getExecutablePath
  let existingPath = maybe "" id (lookup "PATH" currentEnvironment)
      updatedPath = fakeBin ++ ":" ++ existingPath
      baseEnvironment =
        filter
          ( \(key, _) ->
              key
                `notElem` [ "PATH"
                          , "PRODBOX_FAKE_RKE2_RECORD_DIR"
                          , "PRODBOX_FAKE_RKE2_DANGLING_RUNTIME_IMAGE_ID"
                          , "PRODBOX_FAKE_REGISTRY_GC_USAGE_REJECTION"
                          , "PRODBOX_FAKE_REGISTRY_READ_BACK_TRANSIENT"
                          , "PRODBOX_FAKE_RUNTIME_REFERENCE_MODE"
                          , "PRODBOX_FAKE_AUTHORITY_STARTUP_FAILURE"
                          , "PRODBOX_RKE2_CONTAINERD_SOCKET"
                          , "PRODBOX_RKE2_ENDPOINT_STATUS_ROOT"
                          , "PRODBOX_TEST_RESIDUE_UNREACHABLE"
                          , "PRODBOX_TEST_RKE2_PRESENT"
                          , "PRODBOX_TEST_PULUMI_VAULT_GATE"
                          , "PRODBOX_TEST_HOST_VAULT_KV"
                          , "PRODBOX_TEST_ROOT_VAULT_LIFECYCLE"
                          , "PRODBOX_TEST_CLUSTER_VAULT_STATUS"
                          , "PRODBOX_TEST_HOST_CAPACITY"
                          , "PRODBOX_TEST_INTEGRATION_EXECUTABLE"
                          , "PRODBOX_TEST_AUTHORITY_CONFIG_PATH"
                          , "KUBECONFIG"
                          , "HOME"
                          ]
          )
          currentEnvironment
  pure
    ( [ ("PATH", updatedPath)
      , ("PRODBOX_FAKE_RKE2_RECORD_DIR", recordDir)
      , ("PRODBOX_RKE2_CONTAINERD_SOCKET", socketPath)
      , ("PRODBOX_RKE2_ENDPOINT_STATUS_ROOT", endpointStatusRoot)
      , ("KUBECONFIG", kubeconfigPath)
      , -- These reconcile/delete tests model a host with an RKE2 install
        -- present, so the no-cluster short-circuit in 'rke2 delete' must NOT
        -- fire and the gate/cascade paths run as before. Production probes the
        -- real on-disk markers; see 'rke2InstallPresent' in 'Prodbox.CLI.Rke2'.
        ("PRODBOX_TEST_RKE2_PRESENT", "1")
      , ("PRODBOX_TEST_PULUMI_VAULT_GATE", "allow")
      , ("PRODBOX_TEST_HOST_VAULT_KV", "allow")
      , ("PRODBOX_TEST_ROOT_VAULT_LIFECYCLE", "ready")
      , ("PRODBOX_TEST_CLUSTER_VAULT_STATUS", "ready")
      , ("PRODBOX_TEST_INTEGRATION_EXECUTABLE", integrationExecutable)
      , ("PRODBOX_TEST_AUTHORITY_CONFIG_PATH", repoRoot </> "prodbox.dhall")
      ,
        ( "PRODBOX_TEST_HOST_CAPACITY"
        , "milli_cpu=10000,memory_mib=18432,ephemeral_storage_mib=100000,durable_storage_mib=180000"
        )
      , ("HOME", repoRoot)
      ]
        ++ baseEnvironment
    )

-- | Run a graph-consuming reconcile against loopback service fixtures. The
-- Gateway side exposes only its deep @/readyz@ projection; Vault status is
-- supplied by the separately authenticated Bootstrap Broker fixture.
runRke2ReconcileWithFakeGateway
  :: FilePath
  -> FilePath
  -> [String]
  -> [(String, String)]
  -> IO (ExitCode, String, String)
runRke2ReconcileWithFakeGateway repoRoot binary arguments environment =
  withFakeGatewayReadinessEnvironment repoRoot environment $ \gatewayEnvironment ->
    readCreateProcessWithExitCode
      (proc binary arguments)
        { cwd = Just repoRoot
        , env = Just gatewayEnvironment
        }
      ""

runInstalledWithFakeAuthority
  :: FilePath
  -> FilePath
  -> [String]
  -> IO (ExitCode, String, String)
runInstalledWithFakeAuthority repoRoot binary arguments = do
  runInstalledWithFakeAuthorityEnvironment repoRoot binary arguments []

runInstalledWithFakeAuthorityEnvironment
  :: FilePath
  -> FilePath
  -> [String]
  -> [(String, String)]
  -> IO (ExitCode, String, String)
runInstalledWithFakeAuthorityEnvironment repoRoot binary arguments additionalEnvironment = do
  runInstalledWithFakeAuthorityEnvironmentInput repoRoot binary arguments additionalEnvironment ""

runInstalledWithFakeAuthorityEnvironmentInput
  :: FilePath
  -> FilePath
  -> [String]
  -> [(String, String)]
  -> String
  -> IO (ExitCode, String, String)
runInstalledWithFakeAuthorityEnvironmentInput repoRoot binary arguments additionalEnvironment inputText =
  runInstalledWithFakeAuthorityEnvironmentInputForVault
    repoRoot
    binary
    arguments
    additionalEnvironment
    (const inputText)

runInstalledWithFakeAuthorityEnvironmentInputForVault
  :: FilePath
  -> FilePath
  -> [String]
  -> [(String, String)]
  -> (Int -> String)
  -> IO (ExitCode, String, String)
runInstalledWithFakeAuthorityEnvironmentInputForVault
  repoRoot
  binary
  arguments
  additionalEnvironment
  inputForVaultPort = do
    fixtureEnvironment <- fakeRke2Environment repoRoot
    when
      ( lookup "PRODBOX_ALLOW_NON_TTY_INTERACTIVE" additionalEnvironment == Just "1"
          && lookup "PRODBOX_TEST_HOST_VAULT_KV_DIR" additionalEnvironment /= Nothing
      )
      (void (writeFakeAwsScript repoRoot))
    let mergedPath =
          case (lookup "PATH" additionalEnvironment, lookup "PATH" fixtureEnvironment) of
            (Just additionalPath, Just fixturePath)
              | lookup "PRODBOX_FAKE_SES_READINESS_MODE" additionalEnvironment /= Nothing ->
                  takeWhile (/= ':') additionalPath ++ ":" ++ fixturePath
              | lookup "PRODBOX_ALLOW_NON_TTY_INTERACTIVE" additionalEnvironment == Just "1"
                  && lookup "PRODBOX_TEST_HOST_VAULT_KV_DIR" additionalEnvironment /= Nothing ->
                  takeWhile (/= ':') additionalPath ++ ":" ++ fixturePath
              | otherwise -> fixturePath
            (Just additionalPath, Nothing) -> additionalPath
            (Nothing, Just fixturePath) -> fixturePath
            (Nothing, Nothing) -> ""
    withVaultFixtureServer $ \vaultPort -> do
      injectFixtureVaultAddress repoRoot vaultPort
      readCreateProcessWithExitCode
        (proc binary arguments)
          { cwd = Just repoRoot
          , env =
              Just
                ( ("PATH", mergedPath)
                    : filter (not . reservedKey . fst) additionalEnvironment
                    ++ filter (not . reservedKey . fst) fixtureEnvironment
                )
          }
        (inputForVaultPort vaultPort)
   where
    reservedKey key = key == "PATH"

runInstalledWithAuthorityEnvironment
  :: FilePath
  -> FilePath
  -> [String]
  -> [(String, String)]
  -> IO (ExitCode, String, String)
runInstalledWithAuthorityEnvironment repoRoot binary arguments environment =
  withVaultFixtureServer $ \vaultPort -> do
    injectFixtureVaultAddress repoRoot vaultPort
    readCreateProcessWithExitCode
      (proc binary arguments)
        { cwd = Just repoRoot
        , env = Just environment
        }
      ""

withFakeGatewayReadinessEnvironment
  :: FilePath
  -> [(String, String)]
  -> ([(String, String)] -> IO value)
  -> IO value
withFakeGatewayReadinessEnvironment repoRoot environment action = do
  -- Sprint 5.31: the receipt must be recent. `readinessFreshnessWindow` is 300s
  -- and the run is well inside it, so one stamp taken at fixture setup is
  -- honest evidence of a live daemon rather than a window the fixture widens.
  nowMicros <- roundTripLandedAtMicros
  withFakeGatewayDaemonServer (readinessResponses nowMicros) $ \gatewayPort _requestsRef ->
    withVaultFixtureServer $ \vaultPort -> do
      injectFixtureVaultAddress repoRoot vaultPort
      action
        ( ("PRODBOX_TEST_GATEWAY_NODEPORT", show gatewayPort)
            : filter (not . overridden . fst) environment
        )
 where
  overridden key = key == "PRODBOX_TEST_GATEWAY_NODEPORT"
  readinessResponses nowMicros =
    [
      ( "/v1/bootstrap/vault/status"
      , 200
      , "{\"initialized\":true,\"sealed\":false,\"t\":3,\"n\":5,\"progress\":0}"
      )
    , ("/readyz", 200, "ready\n")
    , -- Sprint 5.31: `/v1/state` carries the round-trip receipt the deep probe
      -- reads. Sprint `1.76` stopped treating a constant-time `/readyz` GET as
      -- proof of a backend write and moved the evidence here; this fixture was
      -- never given the new route, so `ProbeBackendRoundTrip ComponentMinio`
      -- observed a 404 and the component could never be admitted. Another
      -- fixture that stopped matching a contract that tightened.

      ( "/v1/state"
      , 200
      , "{\"last_backend_round_trip\":{\"object_version\":\""
          ++ fixtureRoundTripObjectVersion
          ++ "\",\"landed_at_micros\":"
          ++ show nowMicros
          ++ "}}"
      )
    ]

-- | An opaque object-store version string for the fixture's round-trip receipt.
-- It has to satisfy `mkModelBObjectVersion`, so it is a value the production
-- smart constructor accepts rather than arbitrary text.
fixtureRoundTripObjectVersion :: String
fixtureRoundTripObjectVersion = "fixture-round-trip-version"

roundTripLandedAtMicros :: IO Integer
roundTripLandedAtMicros = do
  posix <- getPOSIXTime
  pure (max 0 (floor (nominalDiffTimeToSeconds posix * 1000000)))

writeFakeRke2Scripts :: FilePath -> IO FilePath
writeFakeRke2Scripts repoRoot = do
  let binDir = repoRoot </> "bin"
  createDirectoryIfMissing True binDir
  writeExecutable (binDir </> "systemctl") fakeSystemctlScript
  writeExecutable (binDir </> "journalctl") fakeJournalctlScript
  writeExecutable (binDir </> "sudo") fakeSudoScript
  writeExecutable (binDir </> "test") fakeRke2TestScript
  writeExecutable (binDir </> "curl") fakeRke2CurlScript
  writeExecutable (binDir </> "kubectl") fakeRke2KubectlScript
  writeExecutable (binDir </> "helm") fakeRke2HelmScript
  writeExecutable (binDir </> "docker") fakeRke2DockerScript
  writeExecutable (binDir </> "ctr") fakeRke2CtrScript
  writeExecutable (binDir </> "crictl") fakeRke2CrictlScript
  writeExecutable (binDir </> "mkdir") fakeRke2MkdirScript
  writeExecutable (binDir </> "cp") fakeRke2CpScript
  writeExecutable (binDir </> "chown") fakeRke2ChownScript
  writeExecutable (binDir </> "chmod") fakeRke2ChmodScript
  writeExecutable (binDir </> "rm") fakeRke2RmScript
  writeExecutable (binDir </> "cat") fakeRke2CatScript
  writeExecutable (binDir </> "sysctl") fakeRke2SysctlScript
  writeExecutable (binDir </> "pulumi") fakeRke2PulumiScript
  writeExecutable (binDir </> "aws") fakeRke2AwsScript
  writeExecutable (binDir </> "bash") fakeRke2BashScript
  pure binDir

fakeSystemctlScript :: String
fakeSystemctlScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
    , "/bin/mkdir -p \"$record_dir\""
    , "append_args() {"
    , "  local target=$1"
    , "  shift"
    , "  local first=1"
    , "  for arg in \"$@\"; do"
    , "    if [[ $first -eq 0 ]]; then"
    , "      printf '|' >> \"$target\""
    , "    fi"
    , "    first=0"
    , "    printf '%s' \"$arg\" >> \"$target\""
    , "  done"
    , "  printf '\\n' >> \"$target\""
    , "}"
    , "append_args \"$record_dir/systemctl.txt\" \"$@\""
    , "case \"${1:-}\" in"
    , "  --version)"
    , "    printf 'systemd 255\\n'"
    , "    ;;"
    , "  is-active)"
    , "    printf 'active\\n'"
    , "    ;;"
    , "  show)"
    , "    if [[ \"$*\" == *'LoadState'* ]]; then"
    , "      printf 'loaded\\n'"
    , "    elif [[ \"$*\" == *'ActiveState'* ]]; then"
    , "      printf 'active\\n'"
    , "    else"
    , "      printf 'loaded\\n'"
    , "    fi"
    , "    ;;"
    , "  start|stop|restart|enable|disable|daemon-reload)"
    , "    ;;"
    , "  *)"
    , "    printf 'unsupported fake systemctl command: %s\\n' \"$*\" >&2"
    , "    exit 1"
    , "    ;;"
    , "esac"
    ]

fakeJournalctlScript :: String
fakeJournalctlScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
    , "/bin/mkdir -p \"$record_dir\""
    , "first=1"
    , ": > \"$record_dir/journalctl.txt\""
    , "for arg in \"$@\"; do"
    , "  if [[ $first -eq 0 ]]; then"
    , "    printf '|' >> \"$record_dir/journalctl.txt\""
    , "  fi"
    , "  first=0"
    , "  printf '%s' \"$arg\" >> \"$record_dir/journalctl.txt\""
    , "done"
    , "printf '\\n' >> \"$record_dir/journalctl.txt\""
    , "printf 'RKE2_LOG_LINES\\n'"
    ]

-- NOTE: This fake uninstaller emits `Failed to allocate directory watch: Too many open
-- files` on the child's own stderr (`>&2`), which exercises only the CAPTURABLE path that
-- `captureToolOutput` suppresses on success / `isIgnorableRke2DeleteNoiseLine` filters on
-- failure. The real warning is emitted out-of-band by the systemd manager (PID 1) / journald
-- to the console and is NOT reproduced here, so the `shouldNotContain` assertions below prove
-- only that the quiet path hides the line when it lands on the uninstaller's own streams —
-- not that operators never see the out-of-band emission. See streaming_doctrine.md at 583443f, section 6.
fakeSudoScript :: String
fakeSudoScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
    , "/bin/mkdir -p \"$record_dir\""
    , "first=1"
    , "for arg in \"$@\"; do"
    , "  if [[ $first -eq 0 ]]; then"
    , "    printf '|' >> \"$record_dir/sudo.txt\""
    , "  fi"
    , "  first=0"
    , "  printf '%s' \"$arg\" >> \"$record_dir/sudo.txt\""
    , "done"
    , "printf '\\n' >> \"$record_dir/sudo.txt\""
    , "if [[ \"${1:-}\" == '-n' ]]; then shift; fi"
    , "if [[ \"${1:-}\" == '/var/lib/rancher/rke2/bin/crictl' ]]; then shift; exec crictl \"$@\"; fi"
    , "if [[ \"${1:-}\" == 'mkdir' && \"${!#}\" == *'/vault/vault/0' ]]; then"
    , "  printf '%s' \"${!#}\" > \"$record_dir/vault-host-path\""
    , "fi"
    , "if [[ \"${1:-}\" == 'stat' && \"${!#}\" == *'/vault/vault/0' ]]; then"
    , "  printf '2050:4242:2:41f8\\n'"
    , "  exit 0"
    , "fi"
    , "if [[ \"${1:-}\" == '--version' ]]; then"
    , "  printf 'sudo 1.9.15\\n'"
    , "  exit 0"
    , "fi"
    , "if [[ \"${1:-}\" == '/usr/local/bin/rke2-uninstall.sh' && \"${PRODBOX_FAKE_RKE2_UNINSTALL_EXISTS:-0}\" == '1' ]]; then"
    , "  printf '+ systemctl stop rke2-server.service\\n'"
    , "  printf 'Cannot find device \"cni0\"\\n' >&2"
    , "  printf '/usr/local/bin/rke2-uninstall.sh: 162: semodule: not found\\n' >&2"
    , "  printf 'Failed to allocate directory watch: Too many open files\\n' >&2"
    , "  printf '[2026-04-20 09:17:01] Cleanup completed successfully\\n'"
    , "  if [[ \"${PRODBOX_FAKE_RKE2_UNINSTALL_FAIL:-0}\" == '1' ]]; then"
    , "    printf 'umount: /var/lib/kubelet/pods/abc: target is busy\\n' >&2"
    , "    exit 1"
    , "  fi"
    , "  exit 0"
    , "fi"
    , "exec \"$@\""
    ]

fakeRke2TestScript :: String
fakeRke2TestScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
    , "/bin/mkdir -p \"$record_dir\""
    , "printf '%s\\n' \"$*\" >> \"$record_dir/test.txt\""
    , "case \"$*\" in"
    , "  '-x /usr/local/bin/rke2')"
    , "    exit 1"
    , "    ;;"
    , "  '-x /usr/local/bin/rke2-uninstall.sh')"
    , "    if [[ \"${PRODBOX_FAKE_RKE2_UNINSTALL_EXISTS:-0}\" == '1' ]]; then"
    , "      exit 0"
    , "    fi"
    , "    exit 1"
    , "    ;;"
    , "  *)"
    , "    exec /usr/bin/test \"$@\""
    , "    ;;"
    , "esac"
    ]

fixtureHelmStartupPod :: String
fixtureHelmStartupPod =
  "{\"metadata\":{\"name\":\"lifecycle-authority-0\",\"namespace\":\"lifecycle-authority\",\"uid\":\"11111111-1111-4111-8111-111111111111\",\"labels\":{\"app.kubernetes.io/instance\":\"lifecycle-authority\"}},\"spec\":{\"containers\":[{\"name\":\"lifecycle-authority\"}]},\"status\":{\"containerStatuses\":[{\"name\":\"lifecycle-authority\",\"restartCount\":480,\"containerID\":\"containerd://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}]}}"

fixtureRuntimeManifestBody :: String
fixtureRuntimeManifestBody =
  "{\"schemaVersion\":2,\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"config\":{\"mediaType\":\"application/vnd.oci.image.config.v1+json\",\"digest\":\"sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"},\"layers\":[]}"

fixtureRuntimeManifestDigest :: String
fixtureRuntimeManifestDigest = "sha256:" ++ BS8.unpack (hexSha256 (BS8.pack fixtureRuntimeManifestBody))

runtimeFixtureDigests :: String -> String
runtimeFixtureDigests =
  Text.unpack
    . Text.replace
      (Text.pack ("sha256:" ++ replicate 64 'a'))
      (Text.pack fixtureRuntimeManifestDigest)
    . Text.pack

fakeRke2CurlScript :: String
fakeRke2CurlScript =
  runtimeFixtureDigests $
    unlines
      [ "#!/bin/bash"
      , "set -euo pipefail"
      , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
      , "/bin/mkdir -p \"$record_dir\""
      , "printf '%s\\n' \"$*\" >> \"$record_dir/curl.txt\""
      , "if [[ \"${!#}\" == 'http://127.0.0.1:30080/v2/prodbox/prodbox-runtime/manifests/sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' && \"$*\" == *'--header Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'* ]]; then"
      , "  printf '%s' '" ++ fixtureRuntimeManifestBody ++ "'"
      , "  exit 0"
      , "fi"
      , "if [[ \"$*\" == *'https://get.rke2.io'* ]]; then"
      , "  out=''"
      , "  while [[ $# -gt 0 ]]; do"
      , "    if [[ \"${1:-}\" == '-o' ]]; then"
      , "      out=${2:-}"
      , "      break"
      , "    fi"
      , "    shift"
      , "  done"
      , "  printf '#!/usr/bin/env bash\\nexit 0\\n' > \"$out\""
      , "  exit 0"
      , "fi"
      , "if [[ \"$*\" == *'https://api.ipify.org'* ]]; then"
      , "  printf '198.51.100.24'"
      , "  exit 0"
      , "fi"
      , "if [[ \"$*\" == *'/api/v2.0/projects/'* && \"$*\" == *'-X DELETE'* ]]; then"
      , "  printf '200'"
      , "  exit 0"
      , "fi"
      , "if [[ \"$*\" == *'http://127.0.0.1:30080/readyz'* ]]; then"
      , "  printf '200'"
      , "  exit 0"
      , "fi"
      , "if [[ \"$*\" == *'/blobs/uploads/'* ]]; then"
      , "  # Sprint 4.43 deep registry->MinIO gate: a POST blob-upload session"
      , "  # succeeds (202), modelling a registry that reached its MinIO S3 backend."
      , "  #"
      , "  # Sprint 5.30: Sprint `1.76` made that 202 insufficient on its own — the"
      , "  # probe dumps headers with `-D -` and requires the registry to NAME the"
      , "  # session it allocated, because the identifier is the receipt of the"
      , "  # backend write. A 2xx naming no session is not a round trip. This fake"
      , "  # emitted only the status, so it modelled a registry that cannot have"
      , "  # written; the drift was invisible while the suite could not get here."
      , "  printf 'HTTP/1.1 202 Accepted\\r\\n'"
      , "  printf 'Docker-Upload-UUID: 00000000-0000-4000-8000-00000000fake\\r\\n'"
      , "  printf '\\r\\n'"
      , "  printf '202'"
      , "  exit 0"
      , "fi"
      , "if [[ \"$*\" == *'http://127.0.0.1:30080/v2/_catalog?n=1000'* ]]; then"
      , "  catalog_count_file=$record_dir/registry-catalog.count"
      , "  catalog_count=0"
      , "  if [[ -f \"$catalog_count_file\" ]]; then catalog_count=$(<\"$catalog_count_file\"); fi"
      , "  catalog_count=$((catalog_count + 1))"
      , "  printf '%s\\n' \"$catalog_count\" > \"$catalog_count_file\""
      , "  if [[ \"${PRODBOX_FAKE_REGISTRY_READ_BACK_TRANSIENT:-0}\" == '1' && \"$catalog_count\" == '2' ]]; then"
      , "    printf \"curl: (7) Failed to connect to 127.0.0.1 port 30080 after 0 ms: Couldn't connect to server\\n\" >&2"
      , "    exit 7"
      , "  fi"
      , "  printf '{\"repositories\":[\"prodbox/prodbox-runtime\"]}'"
      , "  exit 0"
      , "fi"
      , "if [[ \"$*\" == *'http://127.0.0.1:30080/v2/prodbox/prodbox-runtime/tags/list?n=1000'* ]]; then"
      , "  printf '{\"name\":\"prodbox/prodbox-runtime\",\"tags\":[\"latest\",\"prodbox-3349a232b3454fb3be77b2f68919904f\"]}'"
      , "  exit 0"
      , "fi"
      , "if [[ \"$*\" == *'http://127.0.0.1:30080/v2/prodbox/prodbox-runtime/manifests/'* ]]; then"
      , "  printf 'HTTP/1.1 200 OK\\r\\n'"
      , "  printf 'Content-Type: application/vnd.docker.distribution.manifest.v2+json\\r\\n'"
      , "  printf 'Docker-Content-Digest: sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\\r\\n'"
      , "  printf '\\r\\n'"
      , "  exit 0"
      , "fi"
      , "if [[ \"$*\" == *'http://127.0.0.1:30080/v2/'* ]]; then"
      , "  printf '401'"
      , "  exit 0"
      , "fi"
      , "if [[ \"$*\" == *'/api/v2.0/projects'* ]]; then"
      , "  printf '201'"
      , "  exit 0"
      , "fi"
      , "printf 'unsupported fake curl command: %s\\n' \"$*\" >&2"
      , "exit 1"
      ]

fakeRke2KubectlScript :: String
fakeRke2KubectlScript =
  runtimeFixtureDigests $
    unlines
      [ "#!/bin/bash"
      , "set -euo pipefail"
      , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:-${HOME:?}/fake-rke2-state}"
      , "/bin/mkdir -p \"$record_dir\""
      , "if [[ \"${PRODBOX_TEST_BROKER_COLD_START:-0}\" == \"1\" ]]; then"
      , "  startup_state=${PRODBOX_TEST_BROKER_STARTUP_STATE:?}"
      , "  if [[ ! -f \"$startup_state.started\" ]]; then printf \"started\\n\" > \"$startup_state.started\"; fi"
      , "fi"
      , "append_args() {"
      , "  local target=$1"
      , "  shift"
      , "  local first=1"
      , "  for arg in \"$@\"; do"
      , "    if [[ $first -eq 0 ]]; then"
      , "      printf '|' >> \"$target\""
      , "    fi"
      , "    first=0"
      , "    printf '%s' \"$arg\" >> \"$target\""
      , "  done"
      , "  printf '\\n' >> \"$target\""
      , "}"
      , "next_apply_target() {"
      , "  local counter_file=\"$record_dir/kubectl-apply.count\""
      , "  local count=0"
      , "  if [[ -f \"$counter_file\" ]]; then"
      , "    count=$(/bin/cat \"$counter_file\")"
      , "  fi"
      , "  count=$((count + 1))"
      , "  printf '%s' \"$count\" > \"$counter_file\""
      , "  printf '%s/kubectl-apply-%s.json' \"$record_dir\" \"$count\""
      , "}"
      , "next_gateway_pods_sample() {"
      , "  local counter_file=\"$record_dir/gateway-pods-sample.count\""
      , "  local count=0"
      , "  if [[ -f \"$counter_file\" ]]; then"
      , "    count=$(/bin/cat \"$counter_file\")"
      , "  fi"
      , "  count=$((count + 1))"
      , "  printf '%s' \"$count\" > \"$counter_file\""
      , "  printf '%s' \"$count\""
      , "}"
      , "append_args \"$record_dir/kubectl.txt\" \"$@\""
      , "requested_namespace=default"
      , "previous_argument="
      , "for argument in \"$@\"; do"
      , "  if [[ \"$previous_argument\" == '--namespace' ]]; then requested_namespace=$argument; break; fi"
      , "  previous_argument=$argument"
      , "done"
      , "if [[ \"${1:-}\" == '--kubeconfig' ]]; then"
      , "  shift 2"
      , "fi"
      , "if [[ \"${1:-}\" == '--namespace' ]]; then"
      , "  shift 2"
      , "fi"
      , "if [[ \"${PRODBOX_FAKE_AUTHORITY_STARTUP_FAILURE:-0}\" == '1' ]]; then"
      , "  if [[ \"$*\" == 'get pods --namespace lifecycle-authority --selector app.kubernetes.io/instance=lifecycle-authority --output json' ]]; then /bin/cat \"$record_dir/startup-pods.json\"; exit 0; fi"
      , "  if [[ \"$*\" == 'get pod lifecycle-authority-0 --namespace lifecycle-authority --output json' ]]; then /bin/cat \"$record_dir/startup-pod.json\"; exit 0; fi"
      , "  if [[ \"${1:-} ${2:-}\" == 'get --raw' && \"${3:-}\" == /api/v1/namespaces/lifecycle-authority/pods/lifecycle-authority-0/log?container=lifecycle-authority* ]]; then"
      , "    if [[ \"${3:-}\" == *previous=true ]]; then printf '%s\\n' log-previous >> \"$record_dir/startup-evidence-order.txt\"; else printf '%s\\n' log-current >> \"$record_dir/startup-evidence-order.txt\"; fi"
      , "    printf '%s\\n' '{\"event\":\"lifecycle_authority_startup_refused\",\"severity\":\"error\",\"field_role\":\"lifecycle-authority\",\"field_cause\":\"config/decode\",\"field_private\":\"private-startup-sentinel\"}'"
      , "    exit 0"
      , "  fi"
      , "fi"
      , "case \"${1:-}\" in"
      , "  cluster-info)"
      , "    printf 'Kubernetes control plane is running\\n'"
      , "    ;;"
      , "  version)"
      , "    if [[ \"$*\" == *'--client=true'* ]]; then"
      , "      printf 'Client Version: v1.33.0\\n'"
      , "    else"
      , "      printf 'unsupported fake kubectl version command: %s\\n' \"$*\" >&2"
      , "      exit 1"
      , "    fi"
      , "    ;;"
      , "  api-resources)"
      , "    if [[ \"$*\" == *'--namespaced=true'* ]]; then"
      , "      printf 'deployments.apps\\nconfigmaps\\n'"
      , "    else"
      , "      printf 'clusterroles.rbac.authorization.k8s.io\\n'"
      , "    fi"
      , "    ;;"
      , "  auth)"
      , "    if [[ \"${2:-}\" == 'can-i' ]]; then"
      , "      printf 'yes\\n'"
      , "    else"
      , "      exit 1"
      , "    fi"
      , "    ;;"
      , "  get)"
      , "    if [[ $# -eq 4 && \"${2:-}\" == '--filename=-' && \"${3:-}\" == '--output=json' && \"${4:-}\" == '--ignore-not-found=true' ]]; then"
      , "      /bin/cat >/dev/null"
      , "      substrate_observation=\"$record_dir/credential-provisioner-substrate.json\""
      , "      if [[ ! -s \"$substrate_observation\" ]]; then"
      , "        printf 'Credential Provisioner substrate has not been applied\n' >&2"
      , "        exit 1"
      , "      fi"
      , "      /bin/cat \"$substrate_observation\""
      , "      exit 0"
      , "    elif [[ \"${2:-}\" == --filename=* ]]; then"
      , "      printf 'unsupported fake kubectl filename observation: %s\n' \"$*\" >&2"
      , "      exit 1"
      , "    fi"
      , "    case \"${2:-}\" in"
      , "      serviceaccount)"
      , "        printf '%s\\n%s\\nfalse\\n' \"$requested_namespace\" \"${3:-}\""
      , "        ;;"
      , "      node)"
      , "        if [[ \"${3:-}\" == 'bathurst' && \" $* \" == *' -o json '* ]]; then"
      , "          /bin/cat <<'JSON'"
      , readyVaultNodeJson
      , "JSON"
      , "        else"
      , "          exit 1"
      , "        fi"
      , "        ;;"
      , "      nodes)"
      , "        if [[ \"$*\" == *'-o|json'* || \"$*\" == *'-o json'* ]]; then"
      , "          /bin/cat <<'JSON'"
      , "{\"items\":[{\"metadata\":{\"name\":\"bathurst\"}}]}"
      , "JSON"
      , "        elif [[ \"$*\" == *'-o|name'* || \"$*\" == *'-o name'* ]]; then"
      , "          printf 'node/bathurst\\n'"
      , "        else"
      , "          printf 'bathurst'"
      , "        fi"
      , "        ;;"
      , "      storageclass)"
      , "        printf 'storageclass.storage.k8s.io/manual\\nstorageclass.storage.k8s.io/local-path\\n'"
      , "        ;;"
      , "      pv)"
      , "        if [[ \"${3:-}\" == 'prodbox-retained-vault-vault-0' && \" $* \" == *' -o json '* ]]; then"
      , "          host_path=$(/bin/cat \"$record_dir/vault-host-path\")"
      , "          \"${PRODBOX_TEST_INTEGRATION_EXECUTABLE:?}\" --fixture-vault-volume \"$host_path\""
      , "        elif [[ \"${3:-}\" == '-o' && \"$*\" == *'jsonpath={range .items'* ]]; then"
      , "          # Empty success for the drain-time Delete-reclaim PV listing."
      , "          exit 0"
      , "        else"
      , "          printf 'Error from server (NotFound): persistentvolumes \"%s\" not found\\n' \"${3:-pv}\" >&2"
      , "          exit 1"
      , "        fi"
      , "        ;;"
      , "      pvc)"
      , "        if [[ \"${3:-}\" == 'data-vault-0' && \" $* \" == *' -o json '* ]]; then"
      , "          /bin/cat <<'JSON'"
      , readyVaultClaimJson
      , "JSON"
      , "        else"
      , "          printf 'Error from server (NotFound): persistentvolumeclaims \"%s\" not found\\n' \"${3:-pvc}\" >&2"
      , "          exit 1"
      , "        fi"
      , "        ;;"
      , "      resourcequota)"
      , "        if [[ \"$*\" == *'-o json'* ]]; then"
      , "          /bin/cat <<'JSON'"
      , renderFakeResourceQuotaItems
      , "JSON"
      , "        fi"
      , "        ;;"
      , "      limitrange)"
      , "        if [[ \"$*\" == *'-o json'* ]]; then"
      , "          /bin/cat <<'JSON'"
      , renderFakeLimitRangeItems
      , "JSON"
      , "        fi"
      , "        ;;"
      , "      configmap)"
      , "        /bin/cat <<'EOF'"
      , "server {"
      , "  location / {"
      , "    proxy_pass http://core;"
      , "  }"
      , "}"
      , "EOF"
      , "        ;;"
      , "      secret|secret/*)"
      , "        if [[ \"$*\" == *'secret/minio-oidc-client'* && \"$*\" == *'metadata.resourceVersion'* ]]; then"
      , "          printf 'fixture-resource-version-1'"
      , "        elif [[ \"$*\" == *'secret/'* && \"$*\" == *'metadata.uid'* ]]; then"
      , "          printf 'fixture-secret-uid:fixture-resource-version-1'"
      , "        elif [[ \"${3:-}\" == 'minio' && \"$*\" == *'rootUser'* ]]; then"
      , "          printf 'minioadmin'"
      , "        elif [[ \"${3:-}\" == 'minio' && \"$*\" == *'rootPassword'* ]]; then"
      , "          printf 'minioadmin123'"
      , "        elif [[ \"${3:-}\" == 'gateway-minio-creds' ]]; then"
      , "          # Sprint 2.19: readGatewayMinioCredsSecret probes for an existing"
      , "          # Secret; absence is the happy path for first reconcile (fresh"
      , "          # credentials get generated)."
      , "          printf 'Error from server (NotFound): secrets \"gateway-minio-creds\" not found\\n' >&2"
      , "          exit 1"
      , "        elif [[ \"${3:-}\" == *'-pguser-keycloak' && \"$*\" == *'--ignore-not-found=true'* ]]; then"
      , "          # The chart platform treats the Percona operator pguser Secret as"
      , "          # optional during a fresh reconcile; absent means the post-readiness"
      , "          # sync is a no-op and will be retried later."
      , "          exit 0"
      , "        else"
      , "          printf 'unsupported fake secret lookup: %s\\n' \"$*\" >&2"
      , "          exit 1"
      , "        fi"
      , "        ;;"
      , -- Sprint 3.34 made `endpoints/kubernetes` a live observation on the
        -- reconcile path (the post-DNAT Kubernetes API egress coordinate).
        -- This inner case's `*)` arm answers an unknown resource with empty
        -- stdout and exit 0, so before this arm existed the observer read
        -- "" and refused with "observation was not in the expected form".
        -- The address is RFC 5737 TEST-NET-1, unmistakably synthetic; the
        -- port is the real post-DNAT API port, which is the coordinate the
        -- chart rule under test is derived from.
        "      endpoints)"
      , "        if [[ \"${3:-}\" == 'kubernetes' ]]; then"
      , "          printf '192.0.2.10|6443'"
      , "        else"
      , "          printf 'Error from server (NotFound): endpoints \"%s\" not found\\n' \"${3:-endpoints}\" >&2"
      , "          exit 1"
      , "        fi"
      , "        ;;"
      , "      deployment)"
      , "        if [[ \"$*\" == *'jsonpath={.metadata.generation}'* ]]; then"
      , "          printf '1:1:1:1'"
      , "        elif [[ \"$*\" == *'jsonpath={.status.conditions'* ]]; then"
      , "          printf 'True'"
      , "        fi"
      , "        ;;"
      , "      statefulset)"
      , "        if [[ \"${3:-}\" == 'minio' && \" $* \" == *' -o json '* ]]; then"
      , "          /bin/cat <<'JSON'"
      , readyMinioControllerJson
      , "JSON"
      , "        elif [[ \"${3:-}\" == 'vault' && \" $* \" == *' -o json '* ]]; then"
      , "          /bin/cat <<'JSON'"
      , readyVaultControllerJson
      , "JSON"
      , "        elif [[ \"$*\" == *'jsonpath={.spec.replicas}'* ]]; then"
      , "          printf '1:1:1'"
      , "        elif [[ \"$*\" == *'-o name'* ]]; then"
      , "          # The gateway namespace holds one StatefulSet per home emitter beside the"
      , "          # unrelated Pulsar broker; the gateway validations wait on the emitters only."
      , "          printf 'statefulset.apps/gateway-node-a\\nstatefulset.apps/gateway-node-b\\nstatefulset.apps/pulsar\\n'"
      , "        fi"
      , "        ;;"
      , "      daemonset)"
      , "        if [[ \"$*\" == *'jsonpath={.status.desiredNumberScheduled}'* ]]; then"
      , "          printf '1:1:1'"
      , "        fi"
      , "        ;;"
      , "      deployments.apps)"
      , "        if [[ \"$*\" == *'-n prodbox'* ]]; then"
      , "          printf 'deployment.apps/prodbox-api\\n'"
      , "        fi"
      , "        ;;"
      , "      configmaps)"
      , "        if [[ \"$*\" == *'-n prodbox'* ]]; then"
      , "          printf 'configmap/existing-config\\n'"
      , "        fi"
      , "        ;;"
      , "      clusterroles.rbac.authorization.k8s.io)"
      , "        if [[ \"$*\" == *'app.kubernetes.io/instance=harbor'* ]]; then"
      , "          printf 'clusterrole.rbac.authorization.k8s.io/harbor-role\\n'"
      , "        fi"
      , "        ;;"
      , "      crd)"
      , "        if [[ \"$*\" == *'jsonpath={.status.conditions'* ]]; then"
      , "          printf 'True'"
      , "        else"
      , "          printf 'customresourcedefinition.apiextensions.k8s.io/gatewayclasses.gateway.networking.k8s.io\\n'"
      , "        fi"
      , "        ;;"
      , "      pod)"
      , "        if [[ \"${3:-}\" == 'minio-0' && \" $* \" == *' -o json '* ]]; then"
      , "          /bin/cat <<'JSON'"
      , readyMinioPodJson
      , "JSON"
      , "        elif [[ \"${3:-}\" == 'vault-0' && \" $* \" == *' -o json '* ]]; then"
      , "          /bin/cat <<'JSON'"
      , readyVaultPodJson
      , "JSON"
      , "        else"
      , "          printf 'unsupported fake Pod observation: %s\\n' \"$*\" >&2"
      , "          exit 1"
      , "        fi"
      , "        ;;"
      , "      pods)"
      , "        if [[ \"$*\" == *'--selector=job-name='* && \"$*\" == *'--output=name'* ]]; then"
      , "          exit 0"
      , "        elif [[ \"$*\" == *'-o json'* ]]; then"
      , "          if [[ \"$*\" == *'--namespace gateway'* ]]; then"
      , "            gateway_pods_sample=$(next_gateway_pods_sample)"
      , "            if [[ \"${PRODBOX_FAKE_GATEWAY_OOM_PODS_SAMPLE:-0}\" == \"$gateway_pods_sample\" ]]; then"
      , "              /bin/cat <<'JSON'"
      , renderFakeGatewayPodItems True
      , "JSON"
      , "            else"
      , "              /bin/cat <<'JSON'"
      , renderFakeGatewayPodItems False
      , "JSON"
      , "            fi"
      , "          else"
      , "            /bin/cat <<'JSON'"
      , "{\"items\":[{\"metadata\":{\"namespace\":\"keycloak\",\"name\":\"keycloak-0\"},\"status\":{\"qosClass\":\"Burstable\"},\"spec\":{\"containers\":[{\"name\":\"keycloak\",\"resources\":{\"requests\":{\"cpu\":\"500m\",\"memory\":\"1024Mi\",\"ephemeral-storage\":\"1024Mi\"},\"limits\":{\"cpu\":\"1000m\",\"memory\":\"2048Mi\",\"ephemeral-storage\":\"2048Mi\"}}}]}},{\"metadata\":{\"namespace\":\"vscode\",\"name\":\"vscode-0\"},\"status\":{\"qosClass\":\"Burstable\"},\"spec\":{\"containers\":[{\"name\":\"vscode\",\"resources\":{\"requests\":{\"cpu\":\"500m\",\"memory\":\"1024Mi\",\"ephemeral-storage\":\"1024Mi\"},\"limits\":{\"cpu\":\"1000m\",\"memory\":\"2048Mi\",\"ephemeral-storage\":\"4096Mi\"}}}]}},{\"metadata\":{\"namespace\":\"api\",\"name\":\"api-0\"},\"status\":{\"qosClass\":\"Burstable\"},\"spec\":{\"containers\":[{\"name\":\"api\",\"resources\":{\"requests\":{\"cpu\":\"250m\",\"memory\":\"256Mi\",\"ephemeral-storage\":\"512Mi\"},\"limits\":{\"cpu\":\"500m\",\"memory\":\"512Mi\",\"ephemeral-storage\":\"1024Mi\"}}}]}},{\"metadata\":{\"namespace\":\"websocket\",\"name\":\"websocket-0\"},\"status\":{\"qosClass\":\"Burstable\"},\"spec\":{\"containers\":[{\"name\":\"websocket\",\"resources\":{\"requests\":{\"cpu\":\"100m\",\"memory\":\"256Mi\",\"ephemeral-storage\":\"512Mi\"},\"limits\":{\"cpu\":\"250m\",\"memory\":\"512Mi\",\"ephemeral-storage\":\"1024Mi\"}}}]}},{\"metadata\":{\"namespace\":\"gateway\",\"name\":\"gateway-0\"},\"status\":{\"qosClass\":\"Burstable\"},\"spec\":{\"containers\":[{\"name\":\"gateway\",\"resources\":{\"requests\":{\"cpu\":\"250m\",\"memory\":\"256Mi\",\"ephemeral-storage\":\"512Mi\"},\"limits\":{\"cpu\":\"500m\",\"memory\":\"512Mi\",\"ephemeral-storage\":\"1024Mi\"}}}]}}]}"
      , "JSON"
      , "          fi"
      , "        else"
      , "          printf 'docker.io/library/busybox:latest\\ngoharbor/harbor-core:v2\\n'"
      , "        fi"
      , "        ;;"
      , "      events)"
      , "        printf '{\"items\":[]}'"
      , "        ;;"
      , "      --raw)"
      , "        /bin/cat <<'JSON'"
      , renderFakeGatewayMetricItems
      , "JSON"
      , "        ;;"
      , "      *)"
      , "        ;;"
      , "    esac"
      , "    ;;"
      , "  exec)"
      , "    if [[ \"$*\" == *'deployment/registry'* && \"$*\" == *'/bin/registry garbage-collect'* && \"$*\" == *'--delete-untagged /etc/docker/registry/config.yml'* ]]; then"
      , "      if [[ \"$*\" != *'/usr/bin/env REGISTRY_LOG_LEVEL=error /bin/registry garbage-collect'* ]]; then"
      , "        printf '178->30\\n' > \"$record_dir/registry-gc-partial-audit.txt\""
      , "        for ((index=1; index<=400; index++)); do"
      , "          printf 'time=\"2026-09-05T00:00:00Z\" level=info msg=\"Deleting blob: /docker/registry/v2/blobs/sha256/aa/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\" service=registry sequence=%04d\\n' \"$index\" >&2"
      , "        done"
      , "        exit 0"
      , "      fi"
      , "      if [[ \"${PRODBOX_FAKE_REGISTRY_GC_USAGE_REJECTION:-0}\" == '1' ]]; then"
      , "        printf '%s\\n' 'Error: unknown flag: --quiet' \"Run 'registry help' for usage.\" >&2"
      , "        exit 0"
      , "      fi"
      , "      history_file=\"$record_dir/registry-manifest-history.count\""
      , "      if [[ ! -f \"$history_file\" ]]; then printf '177' > \"$history_file\"; fi"
      , "      before=$(/bin/cat \"$history_file\")"
      , "      printf 'prodbox/prodbox-runtime\\n'"
      , "      for ((index=1; index<=176; index++)); do"
      , "        printf -v digest '%064d' \"$index\""
      , "        printf 'manifest eligible for deletion: sha256:%s\\n' \"$digest\""
      , "      done"
      , "      printf 'prodbox/prodbox-runtime: marking manifest sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \\n'"
      , "      printf '\\n1 blobs marked, 176 blobs and 176 manifests eligible for deletion\\n'"
      , "      for ((index=1; index<=176; index++)); do"
      , "        printf -v digest '%064d' \"$index\""
      , "        printf 'blob eligible for deletion: sha256:%s\\n' \"$digest\""
      , "      done"
      , "      if [[ \"$*\" != *'--dry-run'* ]]; then"
      , "        printf '%s->1\\n' \"$before\" > \"$record_dir/registry-gc-audit.txt\""
      , "        printf '1' > \"$history_file\""
      , "      fi"
      , "    elif [[ \"$*\" == *'vault-0'* && \"$*\" == *'stat -c'* && \"$*\" == *'/vault/data'* ]]; then"
      , "      printf '2050:4242:2:41f8\\n'"
      , "    elif [[ \"$*\" == *'statefulset/minio'* && \"$*\" == *'/proc/self/mountinfo'* ]]; then"
      , "      printf '14443 14435 8:2 /tmp/prodbox/minio/0 /export rw,relatime - ext4 /dev/sda2 rw\\n'"
      , "    else"
      , "      printf 'unsupported fake kubectl exec command: %s\\n' \"$*\" >&2"
      , "      exit 1"
      , "    fi"
      , "    ;;"
      , "  wait|rollout)"
      , "    if [[ \"${PRODBOX_TEST_BROKER_COLD_START:-0}\" == \"1\" && \"$*\" == *\"rollout status deployment/bootstrap-broker\"* ]]; then"
      , "      startup_state=${PRODBOX_TEST_BROKER_STARTUP_STATE:?}"
      , "      if [[ \"${PRODBOX_TEST_BROKER_STARTUP_REFUSED:-0}\" == \"1\" ]]; then"
      , "        printf \"fixture: Broker Deployment startup admission unavailable\\n\" >&2"
      , "        exit 1"
      , "      fi"
      , "      for _startup_poll in {1..600}; do"
      , "        if [[ -f \"$startup_state.backend-ready\" ]]; then break; fi"
      , "        /bin/sleep 0.1"
      , "      done"
      , "      if [[ ! -f \"$startup_state.backend-ready\" ]]; then"
      , "        printf \"fixture: independent backend startup deadline elapsed\\n\" >&2"
      , "        exit 1"
      , "      fi"
      , "      printf \"ready\\n\" > \"$startup_state.ready\""
      , "    fi"
      , "    ;;"
      , "  logs)"
      , "    printf 'gateway fake workload logs are diagnostic-only\n'"
      , "    ;;"
      , "  port-forward)"
      , "    if [[ \"$*\" == *'service/bootstrap-broker'* ]]; then"
      , "      if [[ \"${PRODBOX_TEST_BROKER_COLD_START:-0}\" == \"1\" ]]; then"
      , "        startup_state=${PRODBOX_TEST_BROKER_STARTUP_STATE:?}"
      , "        if [[ ! -f \"$startup_state.backend-ready\" ]]; then"
      , "          printf \"early-exit\\n\" >> \"$startup_state.forwards\""
      , "          printf \"fixture: cold backend makes kubectl forwarding exit\\n\" >&2"
      , "          exit 1"
      , "        fi"
      , "        printf \"backend-ready\\n\" >> \"$startup_state.forwards\""
      , "      fi"
      , "      mapping=${!#}"
      , "      local_port=${mapping%%:*}"
      , "      exec \"${PRODBOX_TEST_INTEGRATION_EXECUTABLE:?}\" --fixture-broker-server \"$local_port\""
      , "    elif [[ \"$*\" == *'deployment/authority-backup'* ]]; then"
      , "      mapping=${!#}"
      , "      local_port=${mapping%%:*}"
      , "      remote_port=${mapping#*:}"
      , "      child_state_file=\"$record_dir/authority-backup-forward-child.state\""
      , "      \"${PRODBOX_TEST_INTEGRATION_EXECUTABLE:?}\" --fixture-authority-server \"$local_port\" &"
      , "      server_pid=$!"
      , "      cleanup_authority_backup_forward() {"
      , "        local forward_exit=$?"
      , "        trap - TERM INT EXIT"
      , "        if kill -0 \"$server_pid\" 2>/dev/null; then"
      , "          kill \"$server_pid\" 2>/dev/null || true"
      , "        fi"
      , "        wait \"$server_pid\" 2>/dev/null || true"
      , "        printf 'stopped\\n' > \"$child_state_file\""
      , "        return \"$forward_exit\""
      , "      }"
      , "      trap cleanup_authority_backup_forward EXIT"
      , "      trap 'exit 143' TERM"
      , "      trap 'exit 130' INT"
      , "      listener_ready=0"
      , "      for _attempt in {1..100}; do"
      , "        readiness_status="
      , "        if { exec 3<>\"/dev/tcp/127.0.0.1/$local_port\"; } 2>/dev/null; then"
      , "          printf 'GET /readyz HTTP/1.1\\r\\nHost: 127.0.0.1\\r\\nConnection: close\\r\\n\\r\\n' >&3"
      , "          if IFS= read -r -t 1 readiness_status <&3; then"
      , "            /bin/cat <&3 >/dev/null"
      , "          fi"
      , "          exec 3>&-"
      , "          exec 3<&-"
      , "          if [[ \"$readiness_status\" == $'HTTP/1.1 200 OK\\r' ]]; then"
      , "            listener_ready=1"
      , "            break"
      , "          fi"
      , "        fi"
      , "        if ! kill -0 \"$server_pid\" 2>/dev/null; then"
      , "          printf 'fake Authority Backup fixture server exited before listener readiness\\n' >&2"
      , "          exit 1"
      , "        fi"
      , "        /bin/sleep 0.01"
      , "      done"
      , "      if [[ \"$listener_ready\" -ne 1 ]]; then"
      , "        printf 'fake Authority Backup fixture listener did not become ready: 127.0.0.1:%s\\n' \"$local_port\" >&2"
      , "        exit 1"
      , "      fi"
      , "      printf 'Forwarding from 127.0.0.1:%s -> %s\\n' \"$local_port\" \"$remote_port\""
      , "      wait \"$server_pid\""
      , "    elif [[ \"$*\" == *'service/authority-backup'* ]]; then"
      , "      printf 'unsupported fake Authority Backup port-forward target: %s\\n' \"$*\" >&2"
      , "      exit 1"
      , "    elif [[ \"$*\" == *'service/lifecycle-authority'* ]]; then"
      , "      mapping=${!#}"
      , "      local_port=${mapping%%:*}"
      , "      exec \"${PRODBOX_TEST_INTEGRATION_EXECUTABLE:?}\" --fixture-authority-server \"$local_port\""
      , "    else"
      , "      trap 'exit 0' TERM INT"
      , "      while true; do"
      , "        sleep 1"
      , "      done"
      , "    fi"
      , "    ;;"
      , "  apply)"
      , "    target=$(next_apply_target)"
      , "    if [[ $# -eq 2 && \"${2:-}\" == '--filename=-' ]]; then"
      , "      /bin/cat > \"$target\""
      , "      if [[ ! -s \"$target\" ]]; then"
      , "        printf 'Credential Provisioner substrate apply received empty input\n' >&2"
      , "        exit 1"
      , "      fi"
      , "      /bin/cp \"$target\" \"$record_dir/credential-provisioner-substrate.json\""
      , "    elif [[ \"${3:-}\" == \"-\" ]]; then"
      , "      # Sprint 2.19: `kubectl apply -f -` (stdin) is the second leg of the"
      , "      # `create namespace --dry-run | apply -f -` and `create secret"
      , "      # generic --dry-run | apply -f -` pipelines used by"
      , "      # ensureGatewayMinioBootstrap. Capture stdin to the apply-target file."
      , "      /bin/cat > \"$target\""
      , "    else"
      , "      /bin/cp \"${3:?}\" \"$target\""
      , "    fi"
      , "    ;;"
      , "  create)"
      , "    case \"${2:-}\" in"
      , "      token)"
      , "        printf 'fixture-service-account-token\\n'"
      , "        ;;"
      , "      namespace)"
      , "        # Sprint 2.19: ensureGatewayMinioBootstrap pre-creates the gateway"
      , "        # namespace via `kubectl create namespace ... --dry-run=client -o yaml`"
      , "        # piped to `kubectl apply -f -`. The fake replies with a minimal"
      , "        # namespace manifest so the dry-run leg succeeds; the apply-f-stdin"
      , "        # leg is handled by the `apply` arm above."
      , "        append_args \"$record_dir/kubectl-create.txt\" \"$@\""
      , "        printf 'apiVersion: v1\\nkind: Namespace\\nmetadata:\\n  name: %s\\n' \"${3:-}\""
      , "        ;;"
      , "      secret)"
      , "        # Sprint 2.19: ensureGatewayMinioBootstrap pre-creates the"
      , "        # gateway-minio-creds Secret via `kubectl create secret generic ...`"
      , "        # with --dry-run=client. The fake replies with a minimal Secret"
      , "        # manifest so the dry-run leg succeeds."
      , "        append_args \"$record_dir/kubectl-create.txt\" \"$@\""
      , "        printf 'apiVersion: v1\\nkind: Secret\\nmetadata:\\n  name: %s\\ntype: Opaque\\n' \"${4:-secret}\""
      , "        ;;"
      , "      *)"
      , "        printf 'unsupported fake kubectl create command: %s\\n' \"$*\" >&2"
      , "        exit 1"
      , "        ;;"
      , "    esac"
      , "    ;;"
      , "  patch|annotate|label)"
      , "    ;;"
      , "  delete)"
      , "    append_args \"$record_dir/kubectl-delete.txt\" \"$@\""
      , "    ;;"
      , "  *)"
      , "    printf 'unsupported fake kubectl command: %s\\n' \"$*\" >&2"
      , "    exit 1"
      , "    ;;"
      , "esac"
      ]

fakeRke2HelmScript :: String
fakeRke2HelmScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
    , "/bin/mkdir -p \"$record_dir\""
    , "first=1"
    , "for arg in \"$@\"; do"
    , "  if [[ $first -eq 0 ]]; then"
    , "    printf '|' >> \"$record_dir/helm.txt\""
    , "  fi"
    , "  first=0"
    , "  printf '%s' \"$arg\" >> \"$record_dir/helm.txt\""
    , "done"
    , "printf '\\n' >> \"$record_dir/helm.txt\""
    , "case \"${1:-}\" in"
    , "  list)"
    , "    printf '[]\\n'"
    , "    ;;"
    , "  status)"
    , "    if [[ \"${PRODBOX_FAKE_AUTHORITY_STARTUP_FAILURE:-0}\" == '1' && \"${2:-}\" == 'lifecycle-authority' && -f \"$record_dir/authority-startup-failed\" && ! -f \"$record_dir/authority-startup-removed\" ]]; then"
    , "      printf '%s\\n' '{\"name\":\"lifecycle-authority\",\"namespace\":\"lifecycle-authority\",\"info\":{\"status\":\"failed\"}}'"
    , "      exit 0"
    , "    fi"
    , "    if [[ \"${2:-}\" == 'harbor' && ! -f \"$record_dir/harbor-uninstalled\" ]]; then"
    , -- Sprint 5.30: Sprint `3.31` made `helm status --output json` decode
      -- `.info.status` into a closed constructor set and fail closed on an
      -- unrecognised shape. This fake omitted `.info` entirely, so it decoded
      -- before that sprint and refuses after it — the same second-encoder drift
      -- as the Tier-0 fixtures, one artifact over. It never surfaced because the
      -- test could not get this far.
      "      printf '{\"name\":\"harbor\",\"namespace\":\"harbor\",\"info\":{\"status\":\"deployed\"}}\\n'"
    , "    elif [[ \"${2:-}\" == 'harbor' ]]; then"
    , "      printf 'Error: release: not found\\n' >&2"
    , "      exit 1"
    , "    else"
    , "      printf 'Error: release: not found\\n' >&2"
    , "      exit 1"
    , "    fi"
    , "    ;;"
    , "  upgrade)"
    , "    if [[ \"${PRODBOX_FAKE_AUTHORITY_STARTUP_FAILURE:-0}\" == '1' && \"$*\" == *'lifecycle-authority'* ]]; then"
    , "      : > \"$record_dir/authority-startup-failed\""
    , "      printf '%s\\n' 'Error: resource not ready, name: lifecycle-authority, kind: StatefulSet, status: Failed, reason: 1 pods have failed' >&2"
    , "      exit 1"
    , "    fi"
    , "    ;;"
    , "  uninstall)"
    , "    if [[ \"${PRODBOX_FAKE_AUTHORITY_STARTUP_FAILURE:-0}\" == '1' && \"${2:-}\" == 'lifecycle-authority' ]]; then"
    , "      printf '%s\\n' uninstall >> \"$record_dir/startup-evidence-order.txt\""
    , "      : > \"$record_dir/authority-startup-removed\""
    , "    fi"
    , "    if [[ \"${2:-}\" == 'harbor' ]]; then"
    , "      : > \"$record_dir/harbor-uninstalled\""
    , "    fi"
    , "    ;;"
    , "  *)"
    , "    ;;"
    , "esac"
    ]

fakeRke2DockerScript :: String
fakeRke2DockerScript =
  runtimeFixtureDigests $
    unlines
      [ "#!/bin/bash"
      , "set -euo pipefail"
      , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
      , "/bin/mkdir -p \"$record_dir\""
      , -- Harbor login isolation: record the DOCKER_CONFIG every prodbox docker
        -- call runs with, so the suite can prove it is the repo-local `.docker`
        -- (never the operator's global ~/.docker).
        "printf '%s\\n' \"${DOCKER_CONFIG:-UNSET}\" >> \"$record_dir/docker-config.txt\""
      , "target_key() {"
      , "  printf '%s' \"$1\" | tr '/:' '__'"
      , "}"
      , "first=1"
      , "for arg in \"$@\"; do"
      , "  if [[ $first -eq 0 ]]; then"
      , "    printf '|' >> \"$record_dir/docker.txt\""
      , "  fi"
      , "  first=0"
      , "  printf '%s' \"$arg\" >> \"$record_dir/docker.txt\""
      , "done"
      , "printf '\\n' >> \"$record_dir/docker.txt\""
      , "source_image_identity() {"
      , "  while IFS='|' read -r ref identity; do"
      , "    if [[ \"$ref\" == \"$1\" ]]; then printf '%s' \"$identity\"; return 0; fi"
      , "  done < \"$record_dir/bootstrap-image-identities\""
      , "  return 1"
      , "}"
      , "case \"${1:-}\" in"
      , "  image)"
      , "    if [[ \"${2:-}\" == 'load' ]]; then"
      , "      exit 0"
      , "    elif [[ \"${2:-}\" == 'ls' ]]; then"
      , "      dangling_id=${PRODBOX_FAKE_RKE2_DANGLING_RUNTIME_IMAGE_ID:-}"
      , "      if [[ -n \"$dangling_id\" && ! -f \"$record_dir/dangling-runtime-image-removed\" ]]; then"
      , "        printf '127.0.0.1:30080/prodbox/prodbox-runtime\\t%s\\n' \"$dangling_id\""
      , "      fi"
      , "      exit 0"
      , "    elif [[ \"${2:-}\" == 'rm' ]]; then"
      , "      dangling_id=${PRODBOX_FAKE_RKE2_DANGLING_RUNTIME_IMAGE_ID:-}"
      , "      if [[ -n \"$dangling_id\" && \"${3:-}\" == \"$dangling_id\" ]]; then"
      , "        : > \"$record_dir/dangling-runtime-image-removed\""
      , "        exit 0"
      , "      fi"
      , "      exit 1"
      , "    elif [[ \"${2:-}\" == 'inspect' ]]; then"
      , "      if [[ \"${3:-}\" == '--format' && \"${4:-}\" == '{{.Id}}' ]]; then"
      , "        if identity=$(source_image_identity \"${5:-}\"); then printf '%s\\n' \"$identity\"; exit 0; fi"
      , "        printf 'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\\n'"
      , "        exit 0"
      , "      elif [[ \"${3:-}\" == '--format' && \"${4:-}\" == '{{json .RepoDigests}}' ]]; then"
      , "        image_ref=${5:-}"
      , "        if [[ \"$image_ref\" == 127.0.0.1:30080/prodbox/prodbox-runtime:* ]]; then"
      , "          printf '[\"127.0.0.1:30080/prodbox/prodbox-runtime@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"]\\n'"
      , "          exit 0"
      , "        fi"
      , "      elif identity=$(source_image_identity \"${3:-}\"); then"
      , "        printf '[{\"Id\":\"%s\",\"Architecture\":\"amd64\",\"RootFS\":{\"Layers\":[]},\"RepoDigests\":[]}]\\n' \"$identity\""
      , "        exit 0"
      , "      fi"
      , "      exit 1"
      , "    fi"
      , "    exit 1"
      , "    ;;"
      , -- Sprint 3.36: the fake parses flags rather than positions. Production
        -- now publishes host-architecture-scoped (`docker pull --platform \<p\>
        -- \<ref\>`), and a fixture that reads the image reference from `$2`
        -- silently reads `--platform` instead. The `save` arm below already
        -- parsed this way; `pull` and `push` did not, which is why a correct
        -- production change presented as `manifest unknown` in six cases.
        "  pull)"
      , "    shift"
      , "    while [[ \"${1:-}\" == --* ]]; do"
      , "      if [[ \"$1\" == '--platform' ]]; then shift 2; else shift; fi"
      , "    done"
      , "    ref=${1:-}"
      , "    if [[ \"$ref\" == 127.0.0.1:30080/* ]]; then"
      , "      if [[ -f \"$record_dir/pushed-$(target_key \"$ref\")\" ]]; then"
      , "        exit 0"
      , "      fi"
      , "      echo 'manifest unknown' >&2"
      , "      exit 1"
      , "    fi"
      , "    rate_limit_ref=${PRODBOX_FAKE_DOCKER_PULL_RATE_LIMIT_REF:-}"
      , "    if [[ -n \"$rate_limit_ref\" && \"$ref\" == \"$rate_limit_ref\" ]]; then"
      , "      echo 'toomanyrequests: rate limit exceeded' >&2"
      , "      exit 1"
      , "    fi"
      , "    exit 0"
      , "    ;;"
      , "  tag)"
      , "    source_ref=${2:-}"
      , "    target_ref=${3:-}"
      , "    printf '%s' \"$source_ref\" > \"$record_dir/tag-$(target_key \"$target_ref\")\""
      , "    exit 0"
      , "    ;;"
      , "  push)"
      , "    shift"
      , "    while [[ \"${1:-}\" == --* ]]; do"
      , "      if [[ \"$1\" == '--platform' ]]; then shift 2; else shift; fi"
      , "    done"
      , "    target_ref=${1:-}"
      , "    tag_file=\"$record_dir/tag-$(target_key \"$target_ref\")\""
      , "    source_ref=''"
      , "    if [[ -f \"$tag_file\" ]]; then"
      , "      source_ref=$(/bin/cat \"$tag_file\")"
      , "    fi"
      , -- Sprint 5.30: the upstream code-server image is published from a
        -- rate-limited registry, and `pushDockerImageWithRetry` classifies its 429
        -- as RETRYABLE. Model it the way production treats it — transient: one 429,
        -- then success. A fake that returns 429 forever models a permanent limit,
        -- which refutes the very retry the two tests asserting "Retrying Harbor
        -- publication …" plus `ExitSuccess` exist to exercise, and takes down every
        -- other case that merely passes through the runbook on its way elsewhere.
        "    if [[ \"$source_ref\" == ghcr.io/coder/code-server:4.98.2 ]]; then"
      , "      attempt_file=\"$record_dir/push-attempts-$(target_key \"$target_ref\")\""
      , "      attempts=0"
      , "      if [[ -f \"$attempt_file\" ]]; then"
      , "        attempts=$(/bin/cat \"$attempt_file\")"
      , "      fi"
      , "      attempts=$((attempts + 1))"
      , "      printf '%s' \"$attempts\" > \"$attempt_file\""
      , "      if [[ \"$attempts\" -le 1 ]]; then"
      , "        echo '429 Too Many Requests' >&2"
      , "        exit 1"
      , "      fi"
      , "    fi"
      , "    : > \"$record_dir/pushed-$(target_key \"$target_ref\")\""
      , "    exit 0"
      , "    ;;"
      , "  build)"
      , "    ;;"
      , "  save)"
      , "    out=''"
      , "    while [[ $# -gt 0 ]]; do"
      , "      if [[ \"${1:-}\" == '-o' ]]; then"
      , "        out=${2:-}"
      , "        break"
      , "      fi"
      , "      shift"
      , "    done"
      , "    printf 'FAKE IMAGE ARCHIVE\\n' > \"$out\""
      , "    ;;"
      , "  *)"
      , "    ;;"
      , "esac"
      ]

fakeRke2CtrScript :: String
fakeRke2CtrScript =
  runtimeFixtureDigests $
    unlines
      [ "#!/bin/bash"
      , "set -euo pipefail"
      , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
      , "/bin/mkdir -p \"$record_dir\""
      , "printf '%s\\n' \"$*\" >> \"$record_dir/ctr.txt\""
      , "if [[ \"$*\" == *'content fetch '* ]]; then"
      , "  if [[ \"${PRODBOX_FAKE_RUNTIME_REFERENCE_MODE:-delayed}\" == 'fetch-denied' ]]; then exit 1; fi"
      , "  if [[ \"${!#}\" != '127.0.0.1:30080/prodbox/prodbox-runtime@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ]]; then exit 1; fi"
      , "  : > \"$record_dir/runtime-manifest-registered\""
      , "  if [[ \"${PRODBOX_FAKE_RUNTIME_REFERENCE_MODE:-delayed}\" == 'fetch-lost' ]]; then exit 1; fi"
      , "  exit 0"
      , "fi"
      , "if [[ \"$*\" == *'images inspect '* ]]; then"
      , "  requested=${!#}"
      , "  while IFS='|' read -r ref identity; do"
      , "    if [[ \"$ref\" == \"$requested\" ]]; then"
      , "      printf '%s\\n  application/vnd.oci.image.config.v1+json @%s\\n' \"$ref\" \"$identity\""
      , "      exit 0"
      , "    fi"
      , "  done < \"$record_dir/bootstrap-image-identities\""
      , "fi"
      , "exit 0"
      ]

fakeRke2CrictlScript :: String
fakeRke2CrictlScript =
  runtimeFixtureDigests $
    unlines
      [ "#!/bin/bash"
      , "set -euo pipefail"
      , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
      , "printf '%s\\n' \"$*\" >> \"$record_dir/crictl.txt\""
      , "mode=${PRODBOX_FAKE_RUNTIME_REFERENCE_MODE:-delayed}"
      , "if [[ \"$mode\" == 'unavailable' ]]; then exit 1; fi"
      , "identity='sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'"
      , "if [[ \"$mode\" == 'foreign-config' ]]; then identity='sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'; fi"
      , "references='[]'"
      , "if [[ -f \"$record_dir/runtime-manifest-registered\" ]]; then references='[\"127.0.0.1:30080/prodbox/prodbox-runtime@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"]'; fi"
      , "if [[ \"$mode\" == 'foreign-reference' ]]; then references='[\"127.0.0.1:30080/prodbox/prodbox-runtime@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\"]'; fi"
      , "printf '{\"status\":{\"id\":\"%s\",\"repoTags\":[\"%s\"],\"repoDigests\":%s}}\\n' \"$identity\" \"${!#}\" \"$references\""
      ]

fakeRke2MkdirScript :: String
fakeRke2MkdirScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
    , "printf '%s\\n' \"$*\" >> \"$record_dir/mkdir.txt\""
    , "exit 0"
    ]

fakeRke2CpScript :: String
fakeRke2CpScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
    , "printf '%s\\n' \"$*\" >> \"$record_dir/cp.txt\""
    , "exit 0"
    ]

fakeRke2ChownScript :: String
fakeRke2ChownScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
    , "printf '%s\\n' \"$*\" >> \"$record_dir/chown.txt\""
    , "exit 0"
    ]

fakeRke2ChmodScript :: String
fakeRke2ChmodScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
    , "printf '%s\\n' \"$*\" >> \"$record_dir/chmod.txt\""
    , "exit 0"
    ]

fakeRke2RmScript :: String
fakeRke2RmScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
    , "printf '%s\\n' \"$*\" >> \"$record_dir/rm.txt\""
    , "exit 0"
    ]

fakeRke2CatScript :: String
fakeRke2CatScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
    , "printf '%s\\n' \"$*\" >> \"$record_dir/cat.txt\""
    , "if [[ \"${1:-}\" == '/proc/sys/kernel/random/boot_id' ]]; then"
    , "  printf '11111111-2222-4333-8444-555555555555\\n'"
    , "  exit 0"
    , "fi"
    , "printf 'cat: %s: No such file or directory\\n' \"${1:-file}\" >&2"
    , "exit 1"
    ]

fakeRke2SysctlScript :: String
fakeRke2SysctlScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
    , "printf '%s\\n' \"$*\" >> \"$record_dir/sysctl.txt\""
    , "exit 0"
    ]

fakeRke2PulumiScript :: String
fakeRke2PulumiScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${HOME:?}/fake-rke2-state"
    , "/bin/mkdir -p \"$record_dir\""
    , "first=1"
    , "for arg in \"$@\"; do"
    , "  if [[ $first -eq 0 ]]; then"
    , "    printf '|' >> \"$record_dir/pulumi.txt\""
    , "  fi"
    , "  first=0"
    , "  printf '%s' \"$arg\" >> \"$record_dir/pulumi.txt\""
    , "done"
    , "printf '\\n' >> \"$record_dir/pulumi.txt\""
    , "case \"${1:-}\" in"
    , "  login)"
    , "    printf 'Logged in to fake-rke2 as matthewnowak (%s)\\n' \"${2:-}\""
    , "    ;;"
    , "  stack)"
    , "    case \"${2:-}\" in"
    , "      select)"
    , "        if [[ \"$*\" != *'--create'* && ( \"${3:-}\" == 'aws-eks-test' || \"${3:-}\" == 'aws-test' || \"${3:-}\" == 'aws-ses' ) ]]; then"
    , "          printf \"error: no stack named '%s' found\\n\" \"${3:-}\" >&2"
    , "          exit 1"
    , "        fi"
    , "        printf 'STACK_SELECTED=%s\\n' \"${3:-}\""
    , "        ;;"
    , "      rm)"
    , "        ;;"
    , "      *)"
    , "        printf 'unsupported fake pulumi stack command: %s\\n' \"$*\" >&2"
    , "        exit 1"
    , "        ;;"
    , "    esac"
    , "    ;;"
    , "  destroy|refresh)"
    , "    printf 'PULUMI_%s\\n' \"${1^^}\""
    , "    ;;"
    , "  config)"
    , "    ;;"
    , "  *)"
    , "    printf 'unsupported fake pulumi command: %s\\n' \"$*\" >&2"
    , "    exit 1"
    , "    ;;"
    , "esac"
    ]

fakeRke2AwsScript :: String
fakeRke2AwsScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:-/tmp/prodbox-fake-rke2-state}"
    , "/bin/mkdir -p \"$record_dir\""
    , "printf '%s\\n' \"$*\" >> \"$record_dir/aws.txt\""
    , "case \"$*\" in"
    , "  *'s3api head-bucket'*|*'s3api create-bucket'*)"
    , "    exit 0"
    , "    ;;"
    , "  *'s3api get-object'*)"
    , "    printf 'An error occurred (NoSuchKey) when calling the GetObject operation: Not Found\\n' >&2"
    , "    exit 254"
    , "    ;;"
    , "  *'s3api delete-object'*)"
    , "    exit 0"
    , "    ;;"
    , "  # Sprint 8.8: prodbox nuke step 3 (operational IAM teardown) — the"
    , "  # SES lease role and operational `prodbox` user are absent in this"
    , "  # fixture, so the teardown is a no-op after observing both states."
    , "  *'sts get-caller-identity'*)"
    , "    printf '{\"Account\":\"123456789012\",\"UserId\":\"AIDAFAKEADMIN\",\"Arn\":\"arn:aws:iam::123456789012:user/prodbox-admin-temp\"}\\n'"
    , "    exit 0"
    , "    ;;"
    , "  *'iam get-role'*)"
    , "    printf 'An error occurred (NoSuchEntity) when calling the GetRole operation: The role with name prodbox-aws-ses-lease cannot be found.\\n' >&2"
    , "    exit 254"
    , "    ;;"
    , "  *'iam get-user'*)"
    , "    printf 'An error occurred (NoSuchEntity) when calling the GetUser operation: The user with name prodbox cannot be found.\\n' >&2"
    , "    exit 254"
    , "    ;;"
    , "  *'iam list-access-keys'*)"
    , "    printf '{\"AccessKeyMetadata\":[]}\\n'"
    , "    exit 0"
    , "    ;;"
    , "  # Sprint 8.8: prodbox nuke step 4 (postflight tag sweep) — clean."
    , "  *'ec2 describe-volumes'*)"
    , "    printf '{\"Volumes\":[]}\\n'"
    , "    exit 0"
    , "    ;;"
    , "  *'ec2 delete-volume'*)"
    , "    exit 0"
    , "    ;;"
    , "  *'resourcegroupstaggingapi get-resources'*)"
    , "    printf '{\"ResourceTagMappingList\":[]}\\n'"
    , "    exit 0"
    , "    ;;"
    , "  # Sprint 8.8: prodbox nuke step 5 (long-lived state-bucket destroy that"
    , "  # removes the retained public-edge cert)."
    , "  *'s3api list-object-versions'*)"
    , "    printf '{}\\n'"
    , "    exit 0"
    , "    ;;"
    , "  *'s3 rm '*|*'s3api delete-objects'*|*'s3api delete-bucket'*)"
    , "    exit 0"
    , "    ;;"
    , "  *)"
    , "    printf 'unsupported fake aws command: %s\\n' \"$*\" >&2"
    , "    exit 1"
    , "    ;;"
    , "esac"
    ]

fakeRke2BashScript :: String
fakeRke2BashScript =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "record_dir=${PRODBOX_FAKE_RKE2_RECORD_DIR:?}"
    , "/bin/mkdir -p \"$record_dir\""
    , "printf '%s\\n' \"$*\" >> \"$record_dir/bash.txt\""
    , "if [[ \"${1:-}\" == '-c' && \"${2:-}\" == *'/dev/tcp/127.0.0.1/39000'* ]]; then"
    , "  exit 0"
    , "fi"
    , "exec /bin/bash \"$@\""
    ]

fakeAwsScript :: FilePath -> String
fakeAwsScript stateDir =
  unlines
    [ "#!/bin/bash"
    , "set -euo pipefail"
    , "export PATH=/usr/bin:/bin"
    , "STATE_DIR=\"" ++ stateDir ++ "\""
    , "/bin/mkdir -p \"$STATE_DIR\""
    , "user_exists_file() {"
    , "  printf '%s/user-%s-exists' \"$STATE_DIR\" \"$1\""
    , "}"
    , "user_policy_file() {"
    , "  printf '%s/user-%s-policy' \"$STATE_DIR\" \"$1\""
    , "}"
    , "user_key_file() {"
    , "  printf '%s/user-%s-access-key-id' \"$STATE_DIR\" \"$1\""
    , "}"
    , "identity_file() {"
    , "  printf '%s/identity-%s' \"$STATE_DIR\" \"$1\""
    , "}"
    , "append_line() {"
    , "  printf '%s\\n' \"$2\" >> \"$1\""
    , "}"
    , "aws_error() {"
    , "  local code=${1:?}"
    , "  local operation=${2:?}"
    , "  local message=${3:?}"
    , "  printf 'An error occurred (%s) when calling the %s operation: %s\\n' \"$code\" \"$operation\" \"$message\" >&2"
    , "  exit 254"
    , "}"
    , "if [[ \"${1:-}\" == \"--version\" ]]; then"
    , "  printf 'aws-cli/2.17.0 Python/3.12.0 Linux/6.8.0 exe/x86_64\\n'"
    , "  exit 0"
    , "fi"
    , "if [[ $# -ge 2 && \"${@: -2:1}\" == \"--output\" ]]; then"
    , "  set -- \"${@:1:$#-2}\""
    , "fi"
    , "service=${1:-}"
    , "action=${2:-}"
    , "case \"$service $action\" in"
    , "  \"ec2 describe-regions\")"
    , "    cat <<'JSON'"
    , ( "{\"Regions\":[{\"RegionName\":\""
          <> (fixtureAwsRegion FixtureUsEast1)
          <> ( "\",\"OptInStatus\":\"opt-in-not-required\"},{\"RegionName\":\""
                 <> (fixtureAwsRegion FixtureUsWest2)
                 <> "\",\"OptInStatus\":\"opt-in-not-required\"}]}"
             )
      )
    , "JSON"
    , "    ;;"
    , "  \"route53 list-hosted-zones\")"
    , "    cat <<'JSON'"
    , "{\"HostedZones\":[{\"Id\":\"/hostedzone/Z1234567890ABC\",\"Name\":\"example.test\"}]}"
    , "JSON"
    , "    ;;"
    , "  \"route53 get-hosted-zone\")"
    , "    access_key_id=${AWS_ACCESS_KEY_ID:-}"
    , "    if [[ -f \"$(identity_file \"$access_key_id\")\" || \"$access_key_id\" == 'ASIAFAKEFED' || \"$access_key_id\" == 'ADMINKEY' || \"$access_key_id\" == 'CONFIGADMINKEY' ]]; then"
    , "      printf '%s\\n' \"$access_key_id\" > \"$STATE_DIR/route53_get_hosted_zone_access_key_id\""
    , "      cat <<'JSON'"
    , "{\"HostedZone\":{\"Id\":\"/hostedzone/Z1234567890ABC\",\"Name\":\"example.test\"},\"DelegationSet\":{\"NameServers\":[\"ns-1.example.com\"]}}"
    , "JSON"
    , "    else"
    , "      aws_error 'InvalidClientTokenId' 'GetHostedZone' 'The security token included in the request is invalid.'"
    , "    fi"
    , "    ;;"
    , "  \"iam create-user\")"
    , "    user_name=${4:-}"
    , "    if [[ -f \"$(user_exists_file \"$user_name\")\" ]]; then"
    , "      aws_error 'EntityAlreadyExists' 'CreateUser' \"User with name $user_name already exists.\""
    , "    fi"
    , "    printf '%s\\n' \"${AWS_ACCESS_KEY_ID:-}\" > \"$STATE_DIR/iam_create_user_access_key_id\""
    , "    touch \"$(user_exists_file \"$user_name\")\""
    , "    printf '{}\\n'"
    , "    ;;"
    , "  \"iam get-user\")"
    , "    user_name=${4:-}"
    , "    if [[ ! -f \"$(user_exists_file \"$user_name\")\" ]]; then"
    , "      aws_error 'NoSuchEntity' 'GetUser' \"The user with name $user_name cannot be found.\""
    , "    fi"
    , "    printf '{\"User\":{\"UserName\":\"%s\",\"Arn\":\"arn:aws:iam::123456789012:user/%s\"}}\\n' \"$user_name\" \"$user_name\""
    , "    ;;"
    , "  \"iam list-access-keys\")"
    , "    user_name=${4:-}"
    , "    if [[ ! -f \"$(user_exists_file \"$user_name\")\" ]]; then"
    , "      aws_error 'NoSuchEntity' 'ListAccessKeys' \"The user with name $user_name cannot be found.\""
    , "    fi"
    , "    if [[ -f \"$(user_key_file \"$user_name\")\" ]]; then"
    , "      access_key_id=$(cat \"$(user_key_file \"$user_name\")\")"
    , "      printf '{\"AccessKeyMetadata\":[{\"AccessKeyId\":\"%s\"}]}\\n' \"$access_key_id\""
    , "    else"
    , "      printf '{\"AccessKeyMetadata\":[]}\\n'"
    , "    fi"
    , "    ;;"
    , "  \"iam delete-access-key\")"
    , "    user_name=${4:-}"
    , "    access_key_id=${6:-}"
    , "    append_line \"$STATE_DIR/iam_deleted_access_keys\" \"$user_name:$access_key_id\""
    , "    rm -f \"$(user_key_file \"$user_name\")\""
    , "    rm -f \"$(identity_file \"$access_key_id\")\""
    , "    printf '{}\\n'"
    , "    ;;"
    , "  \"iam put-user-policy\")"
    , "    user_name=${4:-}"
    , "    touch \"$(user_policy_file \"$user_name\")\""
    , "    printf '{}\\n'"
    , "    ;;"
    , "  \"iam create-access-key\")"
    , "    user_name=${4:-}"
    , "    printf 'AKIAFAKESETUP' > \"$(user_key_file \"$user_name\")\""
    , "    printf '%s' \"$user_name\" > \"$(identity_file 'AKIAFAKESETUP')\""
    , "    cat <<'JSON'"
    , "{\"AccessKey\":{\"AccessKeyId\":\"AKIAFAKESETUP\",\"SecretAccessKey\":\"fake-secret-access-key\"}}"
    , "JSON"
    , "    ;;"
    , "  \"iam delete-user-policy\")"
    , "    user_name=${4:-}"
    , "    if [[ -f \"$(user_policy_file \"$user_name\")\" ]]; then"
    , "      rm -f \"$(user_policy_file \"$user_name\")\""
    , "      printf '{}\\n'"
    , "    else"
    , "      aws_error 'NoSuchEntity' 'DeleteUserPolicy' \"The policy with name prodbox-inline cannot be found.\""
    , "    fi"
    , "    ;;"
    , "  \"iam delete-user\")"
    , "    user_name=${4:-}"
    , "    if [[ ! -f \"$(user_exists_file \"$user_name\")\" ]]; then"
    , "      aws_error 'NoSuchEntity' 'DeleteUser' \"The user with name $user_name cannot be found.\""
    , "    fi"
    , "    printf '{}\\n'"
    , "    printf '%s\\n' \"${AWS_ACCESS_KEY_ID:-}\" > \"$STATE_DIR/iam_delete_user_access_key_id\""
    , "    append_line \"$STATE_DIR/iam_deleted_users\" \"$user_name\""
    , "    if [[ -f \"$(user_key_file \"$user_name\")\" ]]; then"
    , "      existing_access_key=$(cat \"$(user_key_file \"$user_name\")\")"
    , "      rm -f \"$(identity_file \"$existing_access_key\")\""
    , "    fi"
    , "    rm -f \"$(user_exists_file \"$user_name\")\" \"$(user_policy_file \"$user_name\")\" \"$(user_key_file \"$user_name\")\""
    , "    ;;"
    , "  \"service-quotas get-service-quota\")"
    , "    cat <<'JSON'"
    , "{\"Quota\":{\"Value\":8.0}}"
    , "JSON"
    , "    ;;"
    , "  \"service-quotas get-aws-default-service-quota\")"
    , "    cat <<'JSON'"
    , "{\"Quota\":{\"Value\":8.0}}"
    , "JSON"
    , "    ;;"
    , "  \"service-quotas request-service-quota-increase\")"
    , "    cat <<'JSON'"
    , "{\"RequestedQuota\":{\"Status\":\"PENDING\"}}"
    , "JSON"
    , "    ;;"
    , "  \"sts get-caller-identity\")"
    , "    access_key_id=${AWS_ACCESS_KEY_ID:-}"
    , "    if [[ \"$access_key_id\" == 'ASIAFAKEFED' ]]; then"
    , "      cat <<'JSON'"
    , "{\"Account\":\"123456789012\",\"Arn\":\"arn:aws:sts::123456789012:federated-user/prodbox\",\"UserId\":\"AIDAFederated:prodbox\"}"
    , "JSON"
    , "    elif [[ -f \"$(identity_file \"$access_key_id\")\" ]]; then"
    , "      user_name=$(cat \"$(identity_file \"$access_key_id\")\")"
    , "      printf '{\"Account\":\"123456789012\",\"Arn\":\"arn:aws:iam::123456789012:user/%s\",\"UserId\":\"AIDAFake\"}\\n' \"$user_name\""
    , "    elif [[ \"$access_key_id\" == 'ADMINKEY' || \"$access_key_id\" == 'CONFIGADMINKEY' ]]; then"
    , "      cat <<'JSON'"
    , "{\"Account\":\"123456789012\",\"Arn\":\"arn:aws:iam::123456789012:user/temp-admin\",\"UserId\":\"AIDADmin\"}"
    , "JSON"
    , "    else"
    , "      aws_error 'InvalidClientTokenId' 'GetCallerIdentity' 'The security token included in the request is invalid.'"
    , "    fi"
    , "    ;;"
    , "  \"sts get-federation-token\")"
    , "    cat <<'JSON'"
    , "{\"Credentials\":{\"AccessKeyId\":\"ASIAFAKEFED\",\"SecretAccessKey\":\"fake-federated-secret\",\"SessionToken\":\"fake-federated-session\"}}"
    , "JSON"
    , "    ;;"
    , "  \"ec2 describe-volumes\")"
    , "    cat <<'JSON'"
    , "{\"Volumes\":[]}"
    , "JSON"
    , "    ;;"
    , "  \"ec2 delete-volume\")"
    , "    ;;"
    , "  *)"
    , "    printf 'unsupported fake aws command: %s %s\\n' \"$service\" \"$action\" >&2"
    , "    exit 1"
    , "    ;;"
    , "esac"
    ]

fakeCabalListBinScript :: FilePath -> String
fakeCabalListBinScript binaryPath =
  unlines
    [ "#!/usr/bin/env bash"
    , "set -euo pipefail"
    , "if [[ \"$*\" == 'list-bin --builddir=.build exe:prodbox' ]]; then"
    , "  printf '%s\\n' '" ++ binaryPath ++ "'"
    , "else"
    , "  printf 'unsupported fake cabal command: %s\\n' \"$*\" >&2"
    , "  exit 1"
    , "fi"
    ]

seedFakeAwsHarnessState :: FilePath -> IO ()
seedFakeAwsHarnessState repoRoot = do
  let stateDir = repoRoot </> "fake-aws-state"
  createDirectoryIfMissing True stateDir
  writeFile (stateDir </> "user-prodbox-exists") ""
  writeFile (stateDir </> "user-prodbox-policy") ""
  writeFile (stateDir </> "user-prodbox-access-key-id") "AKIAOLDPRODBOX"
  writeFile (stateDir </> "identity-AKIAOLDPRODBOX") "prodbox"
  writeFile (stateDir </> "user-leaked-user-exists") ""
  writeFile (stateDir </> "user-leaked-user-policy") ""
  writeFile (stateDir </> "user-leaked-user-access-key-id") "AKIALEAKED"
  writeFile (stateDir </> "identity-AKIALEAKED") "leaked-user"

harborRegistryStorageSecretName :: String
harborRegistryStorageSecretName = "harbor-registry-s3"

harborRegistryStorageBucket :: String
harborRegistryStorageBucket = "prodbox-harbor-registry"

harborRegistryStorageBootstrapJobName :: String
harborRegistryStorageBootstrapJobName = "harbor-registry-bucket-init"

readAppliedManifestContaining :: FilePath -> String -> IO String
readAppliedManifestContaining stateDir needle = do
  applyFiles <- sort . filter ("kubectl-apply-" `isInfixOf`) <$> listDirectory stateDir
  manifests <- mapM (\fileName -> readFile (stateDir </> fileName)) applyFiles
  case find (isInfixOf needle) manifests of
    Just manifest -> pure manifest
    Nothing ->
      expectationFailure ("expected applied manifest containing " ++ show needle)
        >> pure ""

findRecordLineIndex :: String -> String -> Int
findRecordLineIndex needle haystack =
  case findIndex (isInfixOf needle) (lines haystack) of
    Just indexValue -> indexValue
    Nothing -> error ("missing record line containing " ++ show needle)

countRecordLines :: String -> String -> Int
countRecordLines expected = length . filter (== expected) . lines

bootstrapBrokerConfig :: String
bootstrapBrokerConfig =
  unlines
    [ "{ schemaVersion = 2"
    , ", cluster_id = \"cluster-a\""
    , ", vault_address = \"http://127.0.0.1:8200\""
    , ", service_identity = \"gateway-service\""
    , ", listener = { listen_host = \"127.0.0.1\", listen_port = 18443 }"
    , ", bootstrap_store ="
    , "    { store_endpoint = \"http://127.0.0.1:9000\""
    , "    , store_bucket = \"bootstrap-state\""
    , "    , vault_storage_generation_key = \"vault-storage-generation\""
    , "    , bootstrap_session_fence_key = \"bootstrap-session-fence\""
    , "    , prepared_init_envelope_key = \"prepared-init-envelope\""
    , "    , encrypted_init_response_key = \"encrypted-init-response\""
    , "    , final_unlock_bundle_key = \"final-unlock-bundle\""
    , "    , child_custody_receipt_key = \"child-custody-receipt\""
    , "    , child_recovery_delivery_key = \"child-recovery-delivery\""
    , "    , root_init_journal_key = \"root-init-journal\""
    , "    , root_session_journal_key = \"root-session-journal\""
    , "    , child_custody_journal_key = \"child-custody-journal\""
    , "    , child_recovery_journal_key = \"child-recovery-journal\""
    , "    , post_unseal_handoff_key = \"post-unseal-handoff\""
    , "    , secret_worker_checkpoint_key = \"secret-worker-checkpoint\""
    , "    }"
    , ", limits ="
    , "    { queue_capacity = 8"
    , "    , max_request_body_bytes = 4096"
    , "    , request_deadline_milliseconds = 30000"
    , "    , drain_deadline_milliseconds = 5000"
    , "    }"
    , ", parent_registration = None { parent_cluster_id : Text, parent_authority_endpoint : Text }"
    , "}"
    ]

gatewayStartConfig :: Int -> FilePath -> FilePath -> FilePath -> FilePath -> FilePath -> String
gatewayStartConfig vaultPort tokenPath ordersPath certPath keyPath caPath =
  unlines
    [ "{ schemaVersion = 1"
    , ", vault ="
    , "    Some"
    , "      { address = " ++ show (fakeVaultAddress vaultPort)
    , "      , auth_path = \"kubernetes\""
    , "      , role = \"gateway-gateway\""
    , "      , service_account_token_file = Some " ++ show tokenPath
    , "      }"
    , ", boot ="
    , "  { node_id = \"node-a\""
    , "  , cert_file = " ++ show certPath
    , "  , key_file = " ++ show keyPath
    , "  , ca_file = " ++ show caPath
    , "  , orders_file = " ++ show ordersPath
    , "  , event_keys ="
    , "    [ { name = \"node-a\""
    , "      , value ="
    , indentFixture 10 (vaultSecretRefDhall "secret" "gateway/gateway/node-a/event-key" "key")
    , "      }"
    , "    ]"
    , "  , dns_write_gate ="
    , "      None { zone_id : Text, fqdn : Text, ttl : Natural, aws_region : Text }"
    , "  , aws_creds ="
    , "      None { access_key_id : "
        ++ secretRefTypeDhall
        ++ ", secret_access_key : "
        ++ secretRefTypeDhall
        ++ ", session_token : Optional "
        ++ secretRefTypeDhall
        ++ ", region : Text }"
    , "  , minio_creds ="
    , "      None { minio_access_key : "
        ++ secretRefTypeDhall
        ++ ", minio_secret_key : "
        ++ secretRefTypeDhall
        ++ " }"
    , "  , lifecycle_authority = None { authority_scope : Text, endpoint : Text }"
    , "  , minio_endpoint_url = None Text"
    , "  }"
    , ", live ="
    , "  { heartbeat_interval_seconds = 1.0"
    , "  , reconnect_interval_seconds = 1.0"
    , "  , sync_interval_seconds = 5.0"
    , "  , max_clock_skew_seconds = 10.0"
    , "  , drain_deadline_seconds = Some 30"
    , "  , log_level = Some \"info\""
    , "  }"
    , "}"
    ]

gatewayStatusConfig :: Int -> FilePath -> String
gatewayStatusConfig vaultPort tokenPath =
  unlines
    [ "{ schemaVersion = 1"
    , ", vault ="
    , "    Some"
    , "      { address = " ++ show (fakeVaultAddress vaultPort)
    , "      , auth_path = \"kubernetes\""
    , "      , role = \"gateway-gateway\""
    , "      , service_account_token_file = Some " ++ show tokenPath
    , "      }"
    , ", boot ="
    , "  { node_id = \"node-a\""
    , "  , cert_file = \"node-a.crt\""
    , "  , key_file = \"node-a.key\""
    , "  , ca_file = \"ca.crt\""
    , "  , orders_file = \"orders.dhall\""
    , "  , event_keys ="
    , "    [ { name = \"node-a\""
    , "      , value ="
    , indentFixture 10 (vaultSecretRefDhall "secret" "gateway/gateway/node-a/event-key" "key")
    , "      }"
    , "    ]"
    , "  , dns_write_gate ="
    , "      Some"
    , "        { zone_id = \"Z123\""
    , "        , fqdn = \"test.example.test\""
    , "        , ttl = 60"
    , ("        , aws_region = \"" <> (fixtureAwsRegion FixtureUsEast1) <> "\"")
    , "        }"
    , "  , aws_creds ="
    , "      None { access_key_id : "
        ++ secretRefTypeDhall
        ++ ", secret_access_key : "
        ++ secretRefTypeDhall
        ++ ", session_token : Optional "
        ++ secretRefTypeDhall
        ++ ", region : Text }"
    , "  , minio_creds ="
    , "      None { minio_access_key : "
        ++ secretRefTypeDhall
        ++ ", minio_secret_key : "
        ++ secretRefTypeDhall
        ++ " }"
    , "  , lifecycle_authority = None { authority_scope : Text, endpoint : Text }"
    , "  , minio_endpoint_url = None Text"
    , "  }"
    , ", live ="
    , "  { heartbeat_interval_seconds = 1.0"
    , "  , reconnect_interval_seconds = 1.0"
    , "  , sync_interval_seconds = 5.0"
    , "  , max_clock_skew_seconds = 10.0"
    , "  , drain_deadline_seconds = Some 30"
    , "  , log_level = Some \"info\""
    , "  }"
    , "}"
    ]

gatewayOrders :: String
gatewayOrders = gatewayOrdersAt 31001

-- | Orders fixture pointing at 127.0.0.1:port. Used by integration tests that
-- spin up a loopback HTTP server to exercise the native HTTP client path.
gatewayOrdersAt :: Int -> String
gatewayOrdersAt port =
  gatewayOrdersAtPorts port 32001

gatewayOrdersAtPorts :: Int -> Int -> String
gatewayOrdersAtPorts restPort socketPort =
  unlines
    [ "{ version_utc = 1"
    , ", nodes ="
    , "  [ { node_id = \"node-a\""
    , "    , stable_dns_name = \"node-a.example.test\""
    , "    , rest_host = \"127.0.0.1\""
    , "    , rest_port = " ++ show restPort
    , "    , socket_host = \"127.0.0.1\""
    , "    , socket_port = " ++ show socketPort
    , "    }"
    , "  ]"
    , ", gateway_rule ="
    , "    { ranked_nodes = [ \"node-a\" ]"
    , "    , heartbeat_timeout_seconds = 3"
    , "    }"
    , "}"
    ]

-- | Sprint 7.16: the test-harness cleartext fixture (@test-secrets.dhall@).
-- Carries the unlock-bundle password plus the EPHEMERAL admin AWS credential
-- the harness feeds into the same interactive admin prompt a real operator
-- would answer. Decoded structurally by @inputFile auto@, so no schema import
-- is required. This base value leaves the admin block empty (the vault
-- lifecycle test only needs the password).
-- | Sprint 5.10 follow-up: the deferred operator-id fields the harness injects
-- from @test-secrets.dhall@ (the Route 53 zone, the SES sending/receive/capture
-- identifiers, and the long-lived Pulumi state backend). A bare Dhall record
-- literal must carry every field the Haskell @TestSecrets@ decoder expects;
-- these CLI flows don't exercise those substrates, so the values are empty.
testSecretsOperatorIdFields :: [String]
testSecretsOperatorIdFields =
  [ ", test_served_fqdn = \"harness.example.test\""
  , ", test_acme_email = \"operator@harness.example.test\""
  , ", legacy_cluster_id = \"integration-test-cluster\""
  , ", legacy_machine_id = \"integration-test-machine\""
  , ", legacy_vault_address = \"http://127.0.0.1:31820\""
  , ", legacy_minio_endpoint = \"http://127.0.0.1:39000\""
  , ", route53_zone_id = \"\""
  , ", ses_sender_domain = \"\""
  , ", ses_receive_subdomain = \"\""
  , ", ses_capture_bucket = \"\""
  , ", pulumi_state_backend_bucket_name = \"\""
  , ", pulumi_state_backend_region = \"\""
  , ", aws_substrate_subzone_name = \"\""
  , ", aws_substrate_profile = None { operator_cidr : Text, eks_node_instance_type : Text, eks_node_disk_size_gib : Natural, eks_node_min_size : Natural, eks_node_max_size : Natural, aws_test_instance_types : List Text, aws_test_root_volume_types : List Text, aws_test_root_volume_sizes_gib : List Natural, static_ebs_volume_type : Text, eks_vpc_cidr : Text, eks_subnet_cidrs : List Text, aws_test_vpc_cidr : Text, aws_test_subnet_cidrs : List Text }"
  , ", aws_eks_node_group_size = 0"
  ]

-- | A @test-secrets.dhall@ with a populated @aws_admin_for_test_simulation@
-- block, so the suite-level IAM harness acquires the ephemeral admin credential
-- non-interactively (the harness simulating the prompt).
testSecretsDhallWithAdmin :: String -> String -> String -> Maybe String -> String
testSecretsDhallWithAdmin accessKeyId secretAccessKey regionValue sessionTokenValue =
  unlines $
    ["{ vault_operator_password = \"test-vault-unlock-password\""]
      ++ testSecretsOperatorIdFields
      ++ [ ", aws_admin_for_test_simulation ="
         , "    { access_key_id = " ++ show accessKeyId
         , "    , secret_access_key = " ++ show secretAccessKey
         , "    , session_token = "
             ++ maybe "None Text" (\token -> "Some " ++ show token) sessionTokenValue
         , "    , region = " ++ show regionValue
         , "    }"
         , -- Sprint 7.18: the optional ACME EAB block. A bare Dhall record literal
           -- must still carry every field the Haskell decoder expects, so the
           -- Optional `acme_eab` is rendered explicitly as `None`. Tests that
           -- exercise EAB seeding use `testSecretsDhallWithAdminAndAcmeEab`.
           ", acme_eab = None { key_id : Text, hmac_key : Text }"
         , "}"
         ]

-- | Sprint 7.18: a @test-secrets.dhall@ that also populates the optional
-- @acme_eab@ block for the separate external-material ingress fixture.
-- Placeholder EAB values only — never real ZeroSSL credentials.
testSecretsDhallWithAdminAndAcmeEab
  :: String -> String -> String -> Maybe String -> String -> String -> String
testSecretsDhallWithAdminAndAcmeEab accessKeyId secretAccessKey regionValue sessionTokenValue eabKeyId eabHmacKey =
  unlines $
    ["{ vault_operator_password = \"test-vault-unlock-password\""]
      ++ testSecretsOperatorIdFields
      ++ [ ", aws_admin_for_test_simulation ="
         , "    { access_key_id = " ++ show accessKeyId
         , "    , secret_access_key = " ++ show secretAccessKey
         , "    , session_token = "
             ++ maybe "None Text" (\token -> "Some " ++ show token) sessionTokenValue
         , "    , region = " ++ show regionValue
         , "    }"
         , ", acme_eab = Some { key_id = " ++ show eabKeyId ++ ", hmac_key = " ++ show eabHmacKey ++ " }"
         , "}"
         ]

testSecretsDhall :: String
testSecretsDhall = testSecretsDhallWithAdmin "" "" "" Nothing

-- | Sprint 5.30: the integration fixtures are 'Settings.ConfigFile' values now,
-- not hand-authored Dhall. They were one of four encoders of a record that has
-- exactly one decoder, and Sprint `1.80`'s type tightening made three of them
-- wrong rather than updating them
-- (chaos_hardening_doctrine.md at revision `583443f`, section 23). Every field not named here is the
-- production default, which also retires a second, silent drift: the fixture
-- capacity plan had diverged from `defaultResourcePlan`.
validConfig :: Settings.ConfigFile
validConfig =
  configWithAwsAndAcme
    lifecycleProviderVaultPath
    (fixtureAwsRegion FixtureUsEast1)
    True

validConfigWithBlankOperationalAwsAndConfiguredAdmin :: Settings.ConfigFile
validConfigWithBlankOperationalAwsAndConfiguredAdmin =
  (fixtureBaseConfig lifecycleProviderVaultPath (fixtureAwsRegion FixtureUsEast1) False)
    { Settings.pulumi_state_backend =
        fixturePulumiBackend "prodbox-fixture-state" (fixtureAwsRegion FixtureUsEast1)
    }

validConfigForNuke :: Settings.ConfigFile
validConfigForNuke =
  (fixtureBaseConfig lifecycleProviderVaultPath (fixtureAwsRegion FixtureUsEast1) False)
    { -- Sprint 5.30: the AWS-tier validator Sprint `1.81` introduced requires a
      -- non-empty subzone, and the SES readiness command validates at that tier.
      -- The pre-migration fixture left it empty; the fixture never decoded, so
      -- no test could observe the refusal. Synthetic values, per the repository
      -- value-hygiene rule.
      Settings.aws_substrate = fixtureAwsSubstrate
    , Settings.ses =
        Settings.SesSection
          { Settings.sender_domain = Text.pack "test.example.test"
          , -- Sprint 5.30: a single DNS label, not an FQDN. The pre-migration fixture
            -- carried "inbox.test.example.test" here, which
            -- `validateOptionalDnsLabelField` rejects — but the fixture never decoded,
            -- so no test could observe it. Surfacing a latent invalid fixture value is
            -- the migration working, not migration damage.
            Settings.receive_subdomain = Text.pack "inbox"
          , Settings.capture_bucket = Text.pack "prodbox-test-ses-capture"
          }
    , Settings.pulumi_state_backend =
        fixturePulumiBackend "prodbox-test-pulumi-long-lived" (fixtureAwsRegion FixtureUsWest2)
    }

validConfigWithLeakedOperationalAwsAndConfiguredAdmin :: Settings.ConfigFile
validConfigWithLeakedOperationalAwsAndConfiguredAdmin =
  (fixtureBaseConfig lifecycleProviderVaultPath (fixtureAwsRegion FixtureUsWest2) False)
    { -- This fixture drives the AWS-tier IAM harness. Keep its substrate
      -- coordinates valid so the named unavailable-Credential-Provisioner
      -- refusal is the first failure, rather than an unrelated config refusal.
      Settings.aws_substrate = fixtureAwsSubstrate
    , Settings.ses =
        Settings.SesSection
          { Settings.sender_domain = Text.pack "mail.example.test"
          , Settings.receive_subdomain = Text.pack "inbox"
          , Settings.capture_bucket = Text.pack "prodbox-test-ses-capture"
          }
    , Settings.pulumi_state_backend =
        fixturePulumiBackend "prodbox-fixture-state" (fixtureAwsRegion FixtureUsWest2)
    }

fixtureAwsSubstrate :: Settings.AwsSubstrateSection
fixtureAwsSubstrate =
  Settings.AwsSubstrateSection
    { Settings.hosted_zone_id = Text.pack "Z0987654321XYZ"
    , Settings.subzone_name = Text.pack "aws.test.example.test"
    , Settings.profile = Nothing
    }

zeroSslConfig :: Settings.ConfigFile
zeroSslConfig = validConfig

configWithAwsAndAcme :: String -> String -> Bool -> Settings.ConfigFile
configWithAwsAndAcme awsVaultPath regionValue includeSessionToken =
  (fixtureBaseConfig awsVaultPath regionValue includeSessionToken)
    { Settings.pulumi_state_backend =
        fixturePulumiBackend "prodbox-fixture-state" (fixtureAwsRegion FixtureUsEast1)
    }

-- | The shared fixture shape: production defaults plus the handful of fields
-- every integration fixture overrides.
fixtureBaseConfig :: String -> String -> Bool -> Settings.ConfigFile
fixtureBaseConfig awsVaultPath regionValue includeSessionToken =
  syntheticConfigFile
    { Settings.aws = fixtureAwsCredentials awsVaultPath regionValue includeSessionToken
    , Settings.route53 = Settings.Route53Section {Settings.zone_id = Text.pack "Z1234567890ABC"}
    , Settings.domain =
        (Settings.domain syntheticConfigFile)
          { Settings.demo_fqdn = Text.pack "test.example.test"
          }
    , Settings.acme = fixtureAcme
    , Settings.pulumi_state_backend =
        fixturePulumiBackend "prodbox-fixture-state" (fixtureAwsRegion FixtureUsEast1)
    }

fixtureAwsCredentials :: String -> String -> Bool -> Settings.AwsCredentialsRef
fixtureAwsCredentials awsVaultPath regionValue includeSessionToken =
  Settings.AwsCredentialsRef
    { Settings.awsCredentialAccessKeyId = fixtureVaultRef vaultPath (Text.pack "access_key_id")
    , Settings.awsCredentialSecretAccessKey = fixtureVaultRef vaultPath (Text.pack "secret_access_key")
    , Settings.awsCredentialSessionToken =
        if includeSessionToken
          then Just (fixtureVaultRef vaultPath (Text.pack "session_token"))
          else Nothing
    , Settings.awsCredentialRegion = Text.pack regionValue
    }
 where
  vaultPath = Text.pack awsVaultPath

fixtureAcme :: Settings.AcmeSection
fixtureAcme =
  (Settings.acme syntheticConfigFile)
    { Settings.email = Text.pack "test@example.test"
    , Settings.eab_key_id = Just (fixtureVaultRef (Text.pack acmeEabVaultPath) (Text.pack "key_id"))
    , Settings.eab_hmac_key = Just (fixtureVaultRef (Text.pack acmeEabVaultPath) (Text.pack "hmac_key"))
    }

fixturePulumiBackend :: String -> String -> Settings.PulumiStateBackendSection
fixturePulumiBackend bucket regionValue =
  Settings.PulumiStateBackendSection
    { Settings.psbBucketName = Text.pack bucket
    , Settings.psbRegion = Text.pack regionValue
    , Settings.psbKeyPrefix = Text.pack "pulumi/"
    }

-- | Sprint 5.30: `Settings.vaultRef` is not exported, so the fixture builds the
-- same shape from the exported constructors.
fixtureVaultRef :: Text -> Text -> SecretRef
fixtureVaultRef path field =
  SecretRefVault
    VaultSecretRef
      { vaultSecretMount = Text.pack "secret"
      , vaultSecretPath = path
      , vaultSecretField = field
      }

-- | Sprint 5.31: the fake cluster's ResourceQuota objects, rendered from the
-- same capacity projection the validator compares against.
--
-- These used to be a hand-written JSON literal restating the numbers — a second
-- encoder of the production plan, and one that had already drifted: it declared
-- the keycloak namespace at @1430m@ where the plan projects @1330m@. Deriving
-- it makes the fixture agree with the plan by construction, so a capacity
-- change is reflected rather than contradicted.
renderFakeResourceQuotaItems :: String
renderFakeResourceQuotaItems =
  "{\"items\":[" ++ intercalate "," (map renderQuotaItem resourceGuardrailFakeNamespaces) ++ "]}"
 where
  renderQuotaItem namespace =
    case TestValidation.namespaceResourceQuotaHardFields SubstrateHomeLocal defaultResourcePlan namespace of
      Left err ->
        error ("fake ResourceQuota fixture cannot project namespace " ++ namespace ++ ": " ++ err)
      Right fields ->
        "{\"metadata\":{\"namespace\":\""
          ++ namespace
          ++ "\",\"name\":\""
          ++ namespace
          ++ "-resource-quota\"},\"spec\":{\"hard\":{"
          ++ intercalate "," [renderField name value | (name, value) <- fields]
          ++ "}}}"
  renderField name value = "\"" ++ name ++ "\":\"" ++ value ++ "\""

resourceGuardrailFakeNamespaces :: [String]
resourceGuardrailFakeNamespaces = ["keycloak", "vscode", "api", "websocket", "gateway"]

defaultResourcePlan :: Capacity.ResourcePlan
defaultResourcePlan = Capacity.resource_plan (Settings.capacity syntheticConfigFile)

-- | The fake cluster's LimitRange objects, rendered from the same projection the
-- validator compares against (Sprint 5.31). This is where the gateway's
-- 250m × 3 versus 750m × 2 drift had been sitting.
renderFakeLimitRangeItems :: String
renderFakeLimitRangeItems =
  "{\"items\":[" ++ intercalate "," (map renderLimitItem resourceGuardrailFakeNamespaces) ++ "]}"
 where
  renderLimitItem namespace =
    case TestValidation.namespaceLimitRangeContainerFields SubstrateHomeLocal defaultResourcePlan namespace of
      Left err ->
        error ("fake LimitRange fixture cannot project namespace " ++ namespace ++ ": " ++ err)
      Right fields ->
        "{\"metadata\":{\"namespace\":\""
          ++ namespace
          ++ "\",\"name\":\""
          ++ namespace
          ++ "-limit-range\"},\"spec\":{\"limits\":[{\"type\":\"Container\","
          ++ intercalate "," (map renderGroup (groupFields fields))
          ++ "}]}}"
  groupFields fields =
    [ (prefix, [(name, value) | (candidate, name, value) <- fields, candidate == prefix])
    | prefix <- [["defaultRequest"], ["default"]]
    ]
  renderGroup (prefix, entries) =
    "\""
      ++ concat prefix
      ++ "\":{"
      ++ intercalate "," ["\"" ++ name ++ "\":\"" ++ value ++ "\"" | (name, value) <- entries]
      ++ "}"

-- | The gateway stability fake represents the same complete replica set the
-- production stability policy expects. Derive its cardinality through that
-- policy's projection so a capacity-plan change cannot leave a second authored
-- replica count behind in the fixture.
gatewayRuntimeFakeReplicaIndices :: [Int]
gatewayRuntimeFakeReplicaIndices =
  [0 .. fromIntegral (TestValidation.gatewayRuntimeExpectedReplicas SubstrateHomeLocal) - 1]

gatewayRuntimeFakeMemoryLimitQuantity :: String
gatewayRuntimeFakeMemoryLimitQuantity =
  case Capacity.runtimeMemoryPlanForProfile Capacity.defaultCapacitySection (Text.pack "gateway") of
    Left err -> error ("fake gateway fixture cannot project memory limit: " ++ err)
    Right runtimePlan ->
      show
        ( RuntimeMemory.positiveBytesValue
            (RuntimeMemory.runtimeMemoryContainerLimitBytes runtimePlan)
        )

renderFakeGatewayPodItems :: Bool -> String
renderFakeGatewayPodItems firstPodOomKilled =
  "{\"items\":[" ++ intercalate "," (map renderPod gatewayRuntimeFakeReplicaIndices) ++ "]}"
 where
  renderPod index =
    "{\"metadata\":{\"namespace\":\"gateway\",\"name\":\""
      ++ podName
      ++ "\",\"uid\":\""
      ++ podUid
      ++ "\"},\"spec\":{\"containers\":[{\"name\":\"gateway\",\"resources\":{\"limits\":{\"memory\":\""
      ++ gatewayRuntimeFakeMemoryLimitQuantity
      ++ "\"}}}]},\"status\":{\"phase\":\"Running\",\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\"}],\"containerStatuses\":[{\"name\":\"gateway\",\"restartCount\":"
      ++ show restartCount
      ++ ",\"lastState\":"
      ++ lastState
      ++ "}]}}"
   where
    podName = "gateway-" ++ show index
    podUid = "gateway-uid-" ++ show index
    isOomKilled = firstPodOomKilled && index == 0
    restartCount = if isOomKilled then (1 :: Int) else 5
    lastState =
      if isOomKilled
        then
          "{\"terminated\":{\"reason\":\"OOMKilled\",\"exitCode\":137,\"finishedAt\":\"2026-07-11T00:00:00Z\"}}"
        else "{}"

renderFakeGatewayMetricItems :: String
renderFakeGatewayMetricItems =
  "{\"items\":[" ++ intercalate "," (map renderMetric gatewayRuntimeFakeReplicaIndices) ++ "]}"
 where
  renderMetric index =
    "{\"metadata\":{\"name\":\"gateway-"
      ++ show index
      ++ "\"},\"containers\":[{\"name\":\"gateway\",\"usage\":{\"memory\":\"128Mi\"}}]}"

writePrivateTestSecrets :: FilePath -> String -> IO ()
writePrivateTestSecrets root contents = do
  let path = root </> "test-secrets.dhall"
  writeFile path ""
  setFileMode path 0o600
  writeFile path contents

-- The selected file belongs to the disposable fixture. This exercises only
-- authentication and never enters the operator decommission ceremony.
runSelectedAuthorityRefusalFixture :: FilePath -> FilePath -> IO ExitCode
runSelectedAuthorityRefusalFixture repoRoot kubeconfig = do
  result <-
    AuthorityAuthentication.withHostLifecycleAuthorityAuthenticationAt
      AuthorityAuthentication.LifecycleAuthorityOperator
      repoRoot
      kubeconfig
      (\_ -> pure ())
  case result of
    Left failure -> do
      IO.hPutStrLn IO.stderr (AuthorityAuthentication.renderLifecycleAuthorityAuthenticationError failure)
      pure (ExitFailure 1)
    Right () -> pure ExitSuccess
