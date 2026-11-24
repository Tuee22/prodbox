{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Production launcher and controller entry for one managed kind node
-- attempt. The launcher submits a transient user-manager unit named for the
-- kind placement profile; the same executable re-enters through
-- 'runKindControllerEntry' inside that unit and runs the archive-bound
-- confined worker against the retained proposal. Admission here is narrow and
-- local: only a /test/ identity is admitted, because Authority admission does
-- not exist yet. The resource envelope below is DECLARED, not measured; it
-- does not satisfy the capacity-discovery task. The result file is evidence of
-- a bounded attempt, not of node readiness.
module Prodbox.Control.KindController
  ( launchKindController
  , runKindControllerEntry
  , kindControllerEnvelope
  , kindFamilyControllerEnvelope
  , compileKindFamilyControllerPlan
  , KindFamilyPreparation
  , KindFamilyPreparationError (..)
  , prepareKindFamilyController
  , prepareKindFamilyControllerFromObserved
  , prepareKindProbeRecoveryController
  , prepareKindProbeRecoveryControllerFromObserved
  , prepareKindProbeVerifierController
  , prepareKindProbeVerifierControllerFromObserved
  , prepareKindProbeSuccessorController
  , prepareKindProbeSuccessorControllerFromObserved
  , kindFamilyIntent
  , kindFamilySnapshots
  , kindFamilyCommandStreams
  , kindFamilyTransportStreams
  , KindFamilyParentError (..)
  , KindFamilyParentOutcome (..)
  , withKindFamilyProcesses
  , KindFamilyWorkOutcome (..)
  , KindFamilyPostAction (..)
  , runKindFamilyWorker
  , kindHostCapacityRefusal
  , waitForUnitAbsenceWith
  , classifyControllerUnitAbsence
  , afterControllerSettlement
  , observeControllerUnderLease
  , validControllerResultPath
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, bracket, try)
import Control.Monad (unless)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (runExceptT)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word64)
import Foreign.C.Error (throwErrnoIfMinus1)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Capacity.Allocation qualified as Allocation
import Prodbox.Capacity.Config qualified as Capacity
import Prodbox.Capacity.HostExecution qualified as Host
import Prodbox.Capacity.NativeHostProbe (observeNativeHostCapacityBefore)
import Prodbox.Capacity.ObservedHost (ObservedHostRoot)
import Prodbox.Capacity.RuntimeMemory qualified as Runtime
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , BootstrapProjectionError
  , decodeOptionalBootstrapSource
  , bootstrapRootGeneration
  , bootstrapScope
  , readBootstrapProjection
  )
import Prodbox.Config.DeploymentScope
  ( DeploymentEnvironment (Test)
  , ScopeGenerationObservation (ScopeGenerationMatches)
  , observeScopeGeneration
  , scopeEnvironment
  , scopeRoot
  , validRootGeneration
  , withScopeRootDescriptor
  )
import Prodbox.Control.KubernetesReadiness (ReadinessObservation (..))
import Prodbox.Control.NetworkEnforcement (EnforcementOutcome, observeNetworkEnforcementUnderFamily)
import Prodbox.Control.Status (observeNodeCaBindingUnderLease)
import Prodbox.Control.Reconcile (ReconcileOutcome (..), reconcileFamilyPrerequisites)
import Prodbox.Control.KindIntent (KindIntentObservation (KindIntentMatches), observeKindOwnerFamilyIntent, observeKindExternalFamilyIntent)
import Prodbox.Control.KindControllerRequest
  ( KindControllerRequest
  , ProbeRecoveryRequest
  , ProbeAttemptVerifierRequest
  , ProbeSuccessorRequest
  , probeVerifierRecoveryRequest
  , probeVerifierIsIsolated
  , encodeProbeAttemptVerifierRequest
  , decodeProbeAttemptVerifierRequest
  , probeSuccessorVerifier
  , encodeProbeSuccessorRequest
  , decodeProbeSuccessorRequest
  , kindControllerOperationKey
  , kindProbeRecoveryKey
  , probeRecoveryControllerRequest
  , probeRecoveryId
  , kindRequestOperation
  , kindRequestWindow
  , kindRequestManagerDomain
  , kindRequestExecutableDigest
  , encodeKindControllerRequest
  , decodeKindControllerRequest
  , encodeProbeRecoveryRequest
  , decodeProbeRecoveryRequest
  )
import Prodbox.Control.KindControllerReceipt
  ( controllerUnitName
  , ControllerReceiptWrite (..)
  , withControllerSubmissionIntent
  , ControllerJobWrite (ControllerJobRecorded)
  , recordControllerJob
  , ControllerDomainWrite (ControllerDomainRecorded)
  , recordControllerDomain
  , ControllerProviderWrite (ControllerProviderRecorded)
  , recordControllerProvider
  , ControllerProviderMaterialWrite (ControllerProviderMaterialRecorded)
  , recordControllerProviderMaterial
  , ControllerSenderWrite (ControllerSenderRecorded)
  , recordControllerSender
  , recordControllerReceipt
  , matchesRetainedFamilyRequest
  , FamilyLaunchObservation (FamilyLaunchObserved, FamilyLaunchMissing)
  , observeFamilyPublicationAttempt
  , observeFamilyPrePublicationCancellation
  )
import Prodbox.Control.KindKubeconfigInstall
  ( KindKubeconfigInstall (..)
  , installKindKubeconfig
  )
import Prodbox.Control.KindLease
  ( KindOperationOutcome (..)
  , KindLeaseHandoff (..)
  , awaitKindLeaseHandoff
  , withRecoveredKindOperation
  )
import Prodbox.Control.KindTool
  ( ArchiveBoundConfinedKindNode
  , confirmedKindWorkerNode
  , runArchiveBoundConfinedKindNodeOnOperation
  , runArchiveBoundConfinedKindNodeOnHost
  )
import Prodbox.Control.NodeArchive (InspectedArchiveResult)
import Prodbox.Control.SealedTool
  ( KindWorkerSnapshots
  , kindWorkerKindBudget
  , planKindWorkerSnapshots
  , sealedToolRuntimePlan
  )
import Prodbox.Subprocess qualified as Subprocess
import Prodbox.Subprocess.SystemdBus
import Prodbox.Subprocess.SystemdProvider qualified as Provider
import Prodbox.Subprocess.HostOperationFamily qualified as Family
import Prodbox.Subprocess.KernelScope qualified as Kernel
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import System.Directory (canonicalizePath, doesFileExist)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Error (IOErrorType, ioeGetErrorType)
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as PosixBytes
import System.Posix.Types (Fd (..))
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)
import Text.Read (readMaybe)

foreign import capi "fcntl.h value O_PATH" kindControllerPathOnly :: CInt
foreign import capi "fcntl.h value O_NOFOLLOW" kindControllerNoFollow :: CInt
foreign import capi "fcntl.h value O_CLOEXEC" kindControllerCloseOnExec :: CInt
foreign import capi "fcntl.h open" kindControllerOpenPath :: CString -> CInt -> IO CInt

unitName :: String
unitName = controllerUnitName

sliceName :: String
sliceName = "prodboxkind.slice"

runtimeDirectoryName :: String
runtimeDirectoryName = "prodbox-kind"

-- | The declared envelope for the controller process and the kind worker
-- snapshots. These are explicit constants chosen to fit this host class; the
-- host observation is real but the funding decision is not measured usage.
kindControllerEnvelope
  :: FilePath -> IO (Either String (Host.HostExecutionPlan, KindWorkerSnapshots))
kindControllerEnvelope retainedRoot = do
  now <- getMonotonicTimeNSec
  observed <- observeNativeHostCapacityBefore (now + 2000000000) retainedRoot
  pure $ either (Left . show) compileKindSerialControllerPlan observed

-- The family owns a second bounded role even when the current kind worker
-- does not start a transport. This is declared capacity, not measured usage.
kindFamilyControllerEnvelope
  :: FilePath -> IO (Either String (Host.HostExecutionTransportPlan, KindWorkerSnapshots))
kindFamilyControllerEnvelope retainedRoot = do
  now <- getMonotonicTimeNSec
  observed <- observeNativeHostCapacityBefore (now + 2000000000) retainedRoot
  pure $ either (Left . show) compileKindFamilyControllerPlan observed

compileKindSerialControllerPlan
  :: ObservedHostRoot -> Either String (Host.HostExecutionPlan, KindWorkerSnapshots)
compileKindSerialControllerPlan host = do
  (allocated, budgets) <- kindControllerPlanInputs False
  plan <- either (Left . show) Right $
    Host.compileHostExecutionPlan host allocated (sealedToolRuntimePlan (kindWorkerKindBudget budgets)) kindControllerDemand
  pure (plan, budgets)

compileKindFamilyControllerPlan
  :: ObservedHostRoot -> Either String (Host.HostExecutionTransportPlan, KindWorkerSnapshots)
compileKindFamilyControllerPlan host = do
  (allocated, budgets) <- kindControllerPlanInputs True
  plan <- either (Left . show) Right $
    Host.compileHostExecutionPlanWithTransport host allocated (sealedToolRuntimePlan (kindWorkerKindBudget budgets))
      kindControllerDemand (Host.HostTransportDemand 100000 8 (16 * 1048576))
  pure (plan, budgets)

kindControllerDemand :: Host.HostExecutionDemand
kindControllerDemand = Host.HostExecutionDemand 1000000 500000 100000 64 16 8 (64 * 1048576) (16 * 1048576) 1 0

kindControllerPlanInputs :: Bool -> Either String (Allocation.SomeAllocatedPlan, KindWorkerSnapshots)
kindControllerPlanInputs family = do
  let mib = 1048576
      base = Capacity.defaultResourcePlan
      source =
        base
          { Capacity.host_capacity = Capacity.ResourceVector 2000 4096 8192 8192
          , Capacity.rke2_reserved = Capacity.ResourceVector 100 128 256 1
          , Capacity.eviction_floor = Capacity.ResourceVector 100 128 256 1
          , Capacity.platform_scheduler_requests = Just (Capacity.ResourceVector 0 0 0 0)
          , Capacity.workload_profiles =
              filter ((== Text.pack "redis") . Capacity.profile_id) (Capacity.workload_profiles base)
          }
      bytes term count = Runtime.mkPositiveBytes term (count * mib)
  allocated <- either (Left . show) Right (Allocation.compileResourcePlanUncertified source)
  runtime <- do
    appState <- either (Left . show) Right (bytes Runtime.BoundedApplicationState 1)
    pending <- either (Left . show) Right (bytes Runtime.BoundedPendingPersistenceState 1)
    decode <- either (Left . show) Right (bytes Runtime.InHeapTransportDecodeScratch 2)
    otherHeap <- either (Left . show) Right (bytes Runtime.OtherHeapReserve 2)
    heapCap <- either (Left . show) Right (bytes Runtime.HeapCap 64)
    native <- either (Left . show) Right (bytes Runtime.NativeNonHeapReserve 4)
    kernel <- either (Left . show) Right (bytes Runtime.KernelCgroupReserve 4)
    margin <- either (Left . show) Right (bytes Runtime.SafetyMargin 4)
    container <- either (Left . show) Right (bytes Runtime.ContainerMemoryLimit 768)
    either (Left . show) Right $
      Runtime.validateRuntimeMemoryPlan
        Runtime.RuntimeMemoryInputs
          { Runtime.runtimeBoundedApplicationState = appState
          , Runtime.runtimeBoundedPendingPersistenceState = pending
          , Runtime.runtimeInHeapTransportDecodeScratch = decode
          , Runtime.runtimeOtherHeapReserve = otherHeap
          , Runtime.runtimeHeapCap = heapCap
          , Runtime.runtimeNativeNonHeapReserve = native
          , Runtime.runtimeRawChildSchedule = if family
              then Runtime.BoundedChildSchedule 2 (Just 600000000) [80 * mib, 16 * mib]
              else Runtime.BoundedChildSchedule 1 (Just 600000000) [80 * mib]
          , Runtime.runtimeKernelCgroupReserve = kernel
          , Runtime.runtimeSafetyMargin = margin
          , Runtime.runtimeContainerMemoryLimit = container
          }
  budgets <-
    either
      (Left . show)
      Right
      ( planKindWorkerSnapshots
          runtime
          (128 * 1024 * 1024)
          (2 * 1024 * 1024)
          (256 * 1024 * 1024)
          (2 * 1024 * 1024)
          65536
          65536
      )
  pure (allocated, budgets)

-- Preparing a declaration establishes no current manager, physical parent or
-- lifecycle admission. The resulting intent keeps the original work window.
data KindFamilyPreparation = KindFamilyPreparation
  { kindFamilyBootstrap :: !BootstrapProjection
  , kindFamilyRequest :: !KindControllerRequest
  , kindFamilyProgramRequest :: !ByteString.ByteString
  , kindFamilyIntent :: !Family.HostOperationIntent
  , kindFamilySnapshots :: !KindWorkerSnapshots
  , kindFamilyCommandStreams :: !Subprocess.OperationStreamLimits
  , kindFamilyTransportStreams :: !Subprocess.OperationStreamLimits
  }

data KindFamilyPreparationError
  = KindFamilyPreparationBindingRefused
  | KindFamilyPreparationCapacityRefused !String
  | KindFamilyPreparationIntentRefused !Family.HostOperationError
  | KindFamilyPreparationStreamsRefused !Subprocess.OwnedSubprocessError
  deriving (Eq, Show)

prepareKindFamilyController
  :: BootstrapProjection -> KindControllerRequest -> IO (Either KindFamilyPreparationError KindFamilyPreparation)
prepareKindFamilyController bootstrap request = do
  now <- getMonotonicTimeNSec
  observed <- observeNativeHostCapacityBefore (now + 2000000000) (scopeRoot (bootstrapScope bootstrap))
  case observed of
    Left failure -> pure (Left (KindFamilyPreparationCapacityRefused (show failure)))
    Right host -> prepareKindFamilyControllerFromObserved host bootstrap request

-- This pure-observation input supports deterministic plan validation. It is not
-- the public admission path and cannot create or observe a process owner.
prepareKindFamilyControllerFromObserved
  :: ObservedHostRoot -> BootstrapProjection -> KindControllerRequest
  -> IO (Either KindFamilyPreparationError KindFamilyPreparation)
prepareKindFamilyControllerFromObserved host bootstrap request = case kindControllerOperationKey (kindRequestOperation request) of
  Nothing -> pure (Left KindFamilyPreparationBindingRefused)
  Just key -> case decodeKindControllerRequest bootstrap key window (kindRequestManagerDomain request)
      (kindRequestExecutableDigest request) (encodeKindControllerRequest request) of
    Left _ -> pure (Left KindFamilyPreparationBindingRefused)
    Right _ -> prepareKindFamilyFromBound Identity.KindController host bootstrap request key (encodeKindControllerRequest request)
 where
  window = kindRequestWindow request

-- Recovery is a separate family, with a distinct key and its own original
-- window. It shares the bounded process envelope, not the node work action.
prepareKindProbeRecoveryController
  :: BootstrapProjection -> ProbeRecoveryRequest -> IO (Either KindFamilyPreparationError KindFamilyPreparation)
prepareKindProbeRecoveryController bootstrap request = do
  now <- getMonotonicTimeNSec
  observed <- observeNativeHostCapacityBefore (now + 2000000000) (scopeRoot (bootstrapScope bootstrap))
  case observed of
    Left failure -> pure (Left (KindFamilyPreparationCapacityRefused (show failure)))
    Right host -> prepareKindProbeRecoveryControllerFromObserved host bootstrap request

prepareKindProbeRecoveryControllerFromObserved
  :: ObservedHostRoot -> BootstrapProjection -> ProbeRecoveryRequest
  -> IO (Either KindFamilyPreparationError KindFamilyPreparation)
prepareKindProbeRecoveryControllerFromObserved host bootstrap recovery =
  case (kindProbeRecoveryKey operation (probeRecoveryId recovery), decodeProbeRecoveryRequest bootstrap operation encoded) of
    (Just key, Right decoded) | decoded == recovery -> prepareKindFamilyFromBound Identity.KindController host bootstrap request key encoded
    _ -> pure (Left KindFamilyPreparationBindingRefused)
 where
  request = probeRecoveryControllerRequest recovery
  operation = kindRequestOperation request
  encoded = encodeProbeRecoveryRequest recovery

prepareKindProbeVerifierController
  :: BootstrapProjection -> ProbeAttemptVerifierRequest -> IO (Either KindFamilyPreparationError KindFamilyPreparation)
prepareKindProbeVerifierController bootstrap request = do
  now <- getMonotonicTimeNSec
  observed <- observeNativeHostCapacityBefore (now + 2000000000) (scopeRoot (bootstrapScope bootstrap))
  case observed of
    Left failure -> pure (Left (KindFamilyPreparationCapacityRefused (show failure)))
    Right host -> prepareKindProbeVerifierControllerFromObserved host bootstrap request

prepareKindProbeVerifierControllerFromObserved
  :: ObservedHostRoot -> BootstrapProjection -> ProbeAttemptVerifierRequest
  -> IO (Either KindFamilyPreparationError KindFamilyPreparation)
prepareKindProbeVerifierControllerFromObserved host bootstrap verifier =
  case (kindProbeRecoveryKey operation (probeRecoveryId coordinates), decodeProbeAttemptVerifierRequest bootstrap operation encoded) of
    (Just key, Right decoded) | decoded == verifier -> prepareKindFamilyFromBound kind host bootstrap request key encoded
    _ -> pure (Left KindFamilyPreparationBindingRefused)
 where
  coordinates = probeVerifierRecoveryRequest verifier
  request = probeRecoveryControllerRequest coordinates
  operation = kindRequestOperation request
  encoded = encodeProbeAttemptVerifierRequest verifier
  kind = if probeVerifierIsIsolated verifier then Identity.KindProbeVerifierController else Identity.KindController

prepareKindProbeSuccessorController
  :: BootstrapProjection -> ProbeSuccessorRequest -> IO (Either KindFamilyPreparationError KindFamilyPreparation)
prepareKindProbeSuccessorController bootstrap request = do
  now <- getMonotonicTimeNSec
  observed <- observeNativeHostCapacityBefore (now + 2000000000) (scopeRoot (bootstrapScope bootstrap))
  case observed of
    Left failure -> pure (Left (KindFamilyPreparationCapacityRefused (show failure)))
    Right host -> prepareKindProbeSuccessorControllerFromObserved host bootstrap request

prepareKindProbeSuccessorControllerFromObserved
  :: ObservedHostRoot -> BootstrapProjection -> ProbeSuccessorRequest
  -> IO (Either KindFamilyPreparationError KindFamilyPreparation)
prepareKindProbeSuccessorControllerFromObserved host bootstrap successor =
  case (kindProbeRecoveryKey operation (probeRecoveryId coordinates), decodeProbeSuccessorRequest bootstrap operation encoded) of
    (Just key, Right decoded) | decoded == successor -> prepareKindFamilyFromBound Identity.KindProbeSuccessorController host bootstrap request key encoded
    _ -> pure (Left KindFamilyPreparationBindingRefused)
 where
  coordinates = probeVerifierRecoveryRequest (probeSuccessorVerifier successor)
  request = probeRecoveryControllerRequest coordinates
  operation = kindRequestOperation request
  encoded = encodeProbeSuccessorRequest successor

prepareKindFamilyFromBound
  :: Identity.HostControllerKind -> ObservedHostRoot -> BootstrapProjection -> KindControllerRequest -> Identity.HostExecutionKey
  -> ByteString.ByteString -> IO (Either KindFamilyPreparationError KindFamilyPreparation)
prepareKindFamilyFromBound kind host bootstrap request key encoded = case compileKindFamilyControllerPlan host of
      Left failure -> pure (Left (KindFamilyPreparationCapacityRefused failure))
      Right (plan, snapshots) -> case (Family.hostOperationHelperBounds 1000000 5000000, Subprocess.mkOperationStreamLimits 65536 65536 30000) of
        (Just helper, Right streams) -> case Subprocess.validateOperationStreamLimits (Host.hostExecutionRuntimeMemory plan) window streams of
          Left failure -> pure (Left (KindFamilyPreparationStreamsRefused failure))
          Right () -> do
            intent <- Family.newHostOperationIntent kind plan helper key window
            pure $ case intent of
              Left failure -> Left (KindFamilyPreparationIntentRefused failure)
              Right value -> Right (KindFamilyPreparation bootstrap request encoded value snapshots streams streams)
        (_, Left failure) -> pure (Left (KindFamilyPreparationStreamsRefused failure))
        (Nothing, _) -> pure (Left KindFamilyPreparationBindingRefused)
 where
  window = kindRequestWindow request

data KindFamilyParentError
  = KindFamilyParentBusRefused !BusError
  | KindFamilyParentProviderRefused !Provider.ProviderError
  | KindFamilyParentDomainMismatch
  | KindFamilyParentProgramRefused !Family.HostOperationError
  | KindFamilyParentInputEncodingRefused
  | KindFamilyParentProjectionRefused !BootstrapProjectionError
  | KindFamilyParentInputMismatch
  | KindFamilyParentKernelRefused !Kernel.KernelScopeError
  | KindFamilyParentStreamsRefused !Subprocess.OwnedSubprocessError
  | KindFamilyParentCombined !KindFamilyParentError !KindFamilyParentError
  deriving (Eq, Show)

data KindFamilyParentOutcome value
  = KindFamilyParentRefused !KindFamilyParentError
  | KindFamilyParentCompleted !value
  | KindFamilyParentUnconfirmedAfter !value !KindFamilyParentError
  deriving (Eq, Show)

-- The manager and program remain held through the physically observed parent.
-- This supplies bounded process ownership, not lifecycle admission.
withKindFamilyProcesses
  :: KindFamilyPreparation -> Family.HostControllerProgram -> Identity.HostManagerDomain
  -> (Subprocess.OperationSubprocesses -> IO value)
  -> IO (KindFamilyParentOutcome value)
withKindFamilyProcesses preparation program domain action = do
  uid <- getEffectiveUserID
  primary <- newIORef Nothing
  let intent = kindFamilyIntent preparation
      outer = Identity.hostExecutionOuterEnd (Family.hostOperationWindow intent)
      socket = "/run/user/" ++ show uid ++ "/bus"
  bound <- verifyKindFamilyProgram preparation program domain
  observed <- case bound of
    Left failure -> pure (Right (Left failure))
    Right () -> withSystemdBus outer socket $ \connection -> lift $ do
      qualified <- Provider.withQualifiedProvider connection $ \provider -> do
        if Provider.qualifiedProviderDomain provider /= domain
          then pure (Left KindFamilyParentDomainMismatch)
          else do
            initial <- Provider.verifyQualifiedProvider provider
            case initial of
              Left failure -> pure (Left (KindFamilyParentProviderRefused failure))
              Right () -> do
                checked <- verifyKindFamilyProgram preparation program domain
                case checked of
                  Left failure -> pure (Left failure)
                  Right () -> do
                    result <- Kernel.withObservedOperationParent connection intent program $ \parent ->
                      case Subprocess.operationSubprocesses parent (kindFamilyCommandStreams preparation) (kindFamilyTransportStreams preparation) of
                        Left failure -> pure (Right (Left (KindFamilyParentStreamsRefused failure)))
                        Right processes -> do
                          value <- action processes
                          writeIORef primary (Just value)
                          pure (Right (Right value))
                    closing <- Provider.verifyQualifiedProvider provider
                    pure $ case (result, closing) of
                      (Left failure, Left providerFailure) -> Left (KindFamilyParentCombined (KindFamilyParentKernelRefused failure) (KindFamilyParentProviderRefused providerFailure))
                      (Right (Left failure), Left providerFailure) -> Left (KindFamilyParentCombined failure (KindFamilyParentProviderRefused providerFailure))
                      (Left failure, _) -> Left (KindFamilyParentKernelRefused failure)
                      (Right _, Left failure) -> Left (KindFamilyParentProviderRefused failure)
                      (Right value, Right ()) -> value
      pure (either (Left . KindFamilyParentProviderRefused) id qualified)
  case either (Left . KindFamilyParentBusRefused) id observed of
    Right value -> pure (KindFamilyParentCompleted value)
    Left failure -> do
      result <- readIORef primary
      pure (maybe (KindFamilyParentRefused failure) (`KindFamilyParentUnconfirmedAfter` failure) result)

verifyKindFamilyProgram
  :: KindFamilyPreparation -> Family.HostControllerProgram -> Identity.HostManagerDomain
  -> IO (Either KindFamilyParentError ())
verifyKindFamilyProgram preparation program domain = do
  let request = kindFamilyRequest preparation
      intent = kindFamilyIntent preparation
      failProgram result = either (Left . KindFamilyParentProgramRefused) Right result
  if domain /= kindRequestManagerDomain request then pure (Left KindFamilyParentDomainMismatch) else do
    checked <- Family.verifyHostControllerProgram intent program
    digest <- Family.hashHostControllerProgramExecutable program
    inputs <- Family.readHostControllerProgramInputs program
    case (failProgram checked, failProgram digest, failProgram inputs) of
      (Left failure, _, _) -> pure (Left failure)
      (_, Left failure, _) -> pure (Left failure)
      (_, _, Left failure) -> pure (Left failure)
      (Right (), Right actual, Right bytes)
        | actual /= kindRequestExecutableDigest request -> pure (Left KindFamilyParentInputMismatch)
        | Family.hostControllerRequestBytes bytes /= kindFamilyProgramRequest preparation -> pure (Left KindFamilyParentInputMismatch)
        | otherwise -> case TextEncoding.decodeUtf8' (Family.hostControllerConfigurationBytes bytes) of
            Left _ -> pure (Left KindFamilyParentInputEncodingRefused)
            Right source -> do
              decoded <- decodeOptionalBootstrapSource (Family.hostControllerProgramConfigurationPath program) source
              pure $ case decoded of
                Left failure -> Left (KindFamilyParentProjectionRefused failure)
                Right (Just projection) | projection == kindFamilyBootstrap preparation -> Right ()
                _ -> Left KindFamilyParentInputMismatch

data KindFamilyPostAction
  = KindFamilyPostPreconditionUnconfirmed
  | KindFamilyPostInstallUnconfirmed !KindKubeconfigInstall !Bool
  | KindFamilyPostReceipt !KindKubeconfigInstall !ControllerReceiptWrite !Bool
  | KindFamilyPostProbe !EnforcementOutcome !Bool
  deriving (Eq, Show)

data KindFamilyWorkOutcome
  = KindFamilyWorkHandoffRefused !KindLeaseHandoff
  | KindFamilyWorkAdmissionRefused
  | KindFamilyWorkPrerequisitesUnconfirmed !ReconcileOutcome
  | KindFamilyWorkIoUnconfirmed !IOErrorType
  | KindFamilyWorkIoUnconfirmedAfter !(InspectedArchiveResult ArchiveBoundConfinedKindNode) !IOErrorType
  | KindFamilyWorkDescriptorShapeRefused
  | KindFamilyWorkObserved
      !(InspectedArchiveResult ArchiveBoundConfinedKindNode)
      !(Maybe (KindOperationOutcome KindFamilyPostAction))
  deriving (Show)

-- The held family parent, pinned input recheck and retained operation lease
-- must all remain valid for broker effects and the post-worker writes. A
-- returned worker result is not itself controller or resource retirement.
runKindFamilyWorker
  :: KindFamilyPreparation -> Subprocess.OperationSubprocesses
  -> IO (Either Family.HostOperationError ()) -> IO KindFamilyWorkOutcome
runKindFamilyWorker preparation processes inputStable = do
  primary <- newIORef Nothing
  let bootstrap = kindFamilyBootstrap preparation
      request = kindFamilyRequest preparation
      operation = kindRequestOperation request
      parentStable = do
        held <- inputStable
        parent <- Subprocess.verifyOperationSubprocessesBeforeEffect processes
        pure (held == Right () && parent == Right ())
      admission stable = do
        matching <- matchesRetainedFamilyRequest bootstrap request stable
        marker <- observeFamilyPublicationAttempt bootstrap operation stable
        cancelled <- observeFamilyPrePublicationCancellation bootstrap operation stable
        parent <- parentStable
        pure (matching && marker == FamilyLaunchObserved request && cancelled == FamilyLaunchMissing && parent)
      protocolAdmission observe stable = do
        before <- admission stable
        protocol <- observe bootstrap
        after <- admission stable
        pure (before && protocol == KindIntentMatches operation && after)
      attempt admitted descriptors = case descriptors of
        [usr, cache, nullDevice] -> do
          observed <- runArchiveBoundConfinedKindNodeOnOperation
            180000000 processes (kindFamilySnapshots preparation) bootstrap operation
            (kindRequestExecutableDigest request) (256 * 1024 * 1024)
            [usr, cache] nullDevice (\_ _ stable -> admitted stable) (\_ _ _ stable -> admitted stable)
          writeIORef primary (Just observed)
          pure (Just observed)
        _ -> pure Nothing
  handoff <- awaitKindLeaseHandoff (Identity.hostExecutionWorkEnd (kindRequestWindow request)) bootstrap operation parentStable
  case handoff of
    KindLeaseHandoffReady -> do
      selected <- withRecoveredKindOperation bootstrap operation admission
      if selected /= KindOperationCallbackReturned True then pure KindFamilyWorkAdmissionRefused else do
        protocol <- withRecoveredKindOperation bootstrap operation $ \stable -> do
          before <- admission stable
          owner <- observeKindOwnerFamilyIntent bootstrap
          external <- observeKindExternalFamilyIntent bootstrap
          after <- admission stable
          pure (before, owner, external, after)
        case protocol of
          KindOperationCallbackReturned (True, KindIntentMatches owner, _, True) | owner == operation -> do
            let ownedAdmission = protocolAdmission observeKindOwnerFamilyIntent
            -- The prerequisite coordinator itself brackets every effect
            -- with the owner-first protocol check. Pass the base family
            -- admission so that the same proof is not recursively repeated.
            prerequisites <- reconcileFamilyPrerequisites bootstrap operation admission
            case prerequisites of
              ReconcileNodeReady ready | ready == operation -> runNode primary (attempt ownedAdmission) bootstrap operation ownedAdmission
              other -> pure (KindFamilyWorkPrerequisitesUnconfirmed other)
          KindOperationCallbackReturned (True, _, KindIntentMatches external, True) | external == operation ->
            let externalAdmission = protocolAdmission observeKindExternalFamilyIntent
             in runNode primary (attempt externalAdmission) bootstrap operation externalAdmission
          _ -> pure KindFamilyWorkAdmissionRefused
    failure -> pure (KindFamilyWorkHandoffRefused failure)
 where
  runNode primary attempt bootstrap operation admission = do
        result <- try (withPaths ["/usr", "/etc/ld.so.cache", "/dev/null"] attempt)
        case result of
          Left (failure :: IOException) -> do
            prior <- readIORef primary
            pure $ case prior of
              Nothing -> KindFamilyWorkIoUnconfirmed (ioeGetErrorType failure)
              Just observed -> KindFamilyWorkIoUnconfirmedAfter observed (ioeGetErrorType failure)
          Right Nothing -> pure KindFamilyWorkDescriptorShapeRefused
          Right (Just observed) -> case confirmedKindWorkerNode observed of
            Nothing -> pure (KindFamilyWorkObserved observed Nothing)
            Just node -> do
              post <- withRecoveredKindOperation bootstrap operation $ \stable -> do
                before <- admission stable
                if not before then pure KindFamilyPostPreconditionUnconfirmed else do
                  installed <- installKindKubeconfig bootstrap operation
                  afterInstall <- admission stable
                  if installed /= KindKubeconfigInstalled || not afterInstall
                    then pure (KindFamilyPostInstallUnconfirmed installed afterInstall)
                    else do
                      receipt <- recordControllerReceipt bootstrap operation node stable
                      afterReceipt <- admission stable
                      if receipt /= ControllerReceiptRecorded || not afterReceipt
                        then pure (KindFamilyPostReceipt installed receipt afterReceipt)
                        else do
                          probe <- observeNetworkEnforcementUnderFamily processes bootstrap operation
                            ("prodbox-netcheck-" ++ take 12 operation) (admission stable)
                            (\config -> observeNodeCaBindingUnderLease bootstrap operation node config (admission stable))
                          afterProbe <- admission stable
                          pure (KindFamilyPostProbe probe afterProbe)
              pure (KindFamilyWorkObserved observed (Just post))

-- | Refuse with the compiled envelope's own reason when the observed host
-- cannot fund the declared controller and worker envelope.
kindHostCapacityRefusal :: FilePath -> IO (Maybe String)
kindHostCapacityRefusal retainedRoot = do
  envelope <- kindControllerEnvelope retainedRoot
  pure (either Just (const Nothing) envelope)

controllerKey :: String -> Maybe Subprocess.HostExecutionKey
controllerKey = kindControllerOperationKey

-- | Submit the controller unit and observe its absence. Absence alone does
-- not establish physical retirement, so this operation remains unconfirmed. The
-- result path must name a not-yet-existing file inside a private directory
-- the caller owns; the controller writes exactly one result line there.
launchKindController
  :: FilePath -> String -> FilePath -> IO (Either String String)
launchKindController selected operation resultPath = do
  bootstrap <- readBootstrapProjection selected
  case bootstrap of
    Left failure -> pure (Left ("bootstrap: " <> show failure))
    Right projection | not (validControllerResultPath projection operation resultPath) ->
      pure (Left "controller result path refused")
    Right projection -> do
      let root = scopeRoot (bootstrapScope projection)
      envelope <- kindControllerEnvelope root
      executable <- getExecutablePath >>= canonicalizePath
      digest <- ByteString8.unpack . hexSha256 <$> ByteString.readFile executable
      uid <- getEffectiveUserID
      start <- getMonotonicTimeNSec
      let second = 1000000000 :: Word64
          outer = start + 590 * second
          work = start + 500 * second
          hard = start + 510 * second
          stop = start + 540 * second
          finish = start + 560 * second
          socket = "/run/user/" <> show uid <> "/bus"
      case (envelope, controllerKey operation, Subprocess.hostExecutionWindow outer work hard stop finish) of
        (Right (plan, _), Just key, Just window) -> do
          let arguments =
                [ "internal-kind-controller"
                , selected
                , operation
                , executable
                , "sha256:" <> digest
                , resultPath
                , show outer
                , show work
                , show hard
                , show stop
                , show finish
                ]
          let requestBytes = LazyByteString.toStrict $ Aeson.encode $ Aeson.object
                [ "schema_version" Aeson..= (1 :: Int)
                , "unit" Aeson..= unitName
                , "slice" Aeson..= sliceName
                , "runtime_directory" Aeson..= runtimeDirectoryName
                , "socket" Aeson..= socket
                , "executable_sha256" Aeson..= digest
                , "executable" Aeson..= executable
                , "arguments" Aeson..= arguments
                , "description" Aeson..= Subprocess.kindHostSubprocessDescription plan key window
                , "plan" Aeson..= show plan
                ]
              requestDigest = ByteString8.unpack (hexSha256 requestBytes)
          submitted <- withSystemdBus outer socket $ \connection -> lift $ do
            qualified <- Provider.withQualifiedProvider connection $ \provider -> do
              let domain = Provider.qualifiedProviderDomain provider
                  binding = Provider.qualifiedProviderBinding provider
                  providerDigest = ByteString8.unpack (hexSha256 (Provider.encodeProviderBinding binding))
                  submitQualified sender stable = do
                    before <- runExceptT (observeManagerDomain connection)
                    beforeSender <- runExceptT (observeBusSender connection)
                    providerBefore <- Provider.verifyQualifiedProvider provider
                    operationStillBound <- stable
                    if before /= Right domain || beforeSender /= Right sender || providerBefore /= Right () || not operationStillBound
                      then pure (Left "manager, provider or operation changed before submission")
                      else do
                        sent <- runExceptT $
                          callManager
                            connection
                            StartTransientUnit
                            (kindControllerRequest plan key window executable arguments)
                            (`readString` 'o')
                        case sent of
                          Left failure -> pure (Left ("manager submission unconfirmed: " ++ show failure))
                          Right job -> do
                            recorded <- recordControllerJob projection operation requestDigest job stable
                            after <- runExceptT (observeManagerDomain connection)
                            afterSender <- runExceptT (observeBusSender connection)
                            providerAfter <- Provider.verifyQualifiedProvider provider
                            pure $ if recorded == ControllerJobRecorded && after == Right domain && afterSender == Right sender && providerAfter == Right ()
                              then Right job
                              else Left ("manager returned job " ++ take 128 job ++ "; receipt/domain/provider unconfirmed: " ++ show recorded)
              senderResult <- runExceptT (observeBusSender connection)
              leased <- withRecoveredKindOperation projection operation $ \stable -> do
                admitted <- withControllerSubmissionIntent projection operation requestDigest stable $ do
                  recordedDomain <- recordControllerDomain projection operation requestDigest domain window stable
                  if recordedDomain /= ControllerDomainRecorded
                    then pure (Left ("manager domain record unconfirmed: " ++ show recordedDomain))
                    else do
                      recordedProvider <- recordControllerProvider projection operation requestDigest providerDigest stable
                      if recordedProvider /= ControllerProviderRecorded
                        then pure (Left ("manager provider record unconfirmed: " ++ show recordedProvider))
                        else do
                          material <- recordControllerProviderMaterial projection operation requestDigest binding stable
                          if material /= ControllerProviderMaterialRecorded
                            then pure (Left ("manager provider material unconfirmed: " ++ show material))
                            else case senderResult of
                              Left failure -> pure (Left ("manager sender unobservable: " ++ show failure))
                              Right sender -> do
                                recordedSender <- recordControllerSender projection operation requestDigest sender stable
                                if recordedSender /= ControllerSenderRecorded
                                  then pure (Left ("manager sender record unconfirmed: " ++ show recordedSender))
                                  else submitQualified sender stable
                pure $ case admitted of
                  Left failure -> Left ("controller submission intent not admitted: " ++ show failure)
                  Right result -> result
              case leased of
                KindOperationCallbackReturned (Right _) -> Right <$> waitForUnitAbsence finish connection
                KindOperationCallbackReturned (Left failure) -> pure (Left failure)
                other -> pure (Left ("controller submission lease unconfirmed; inspect retained operation: " ++ take 1000 (show other)))
            pure $ either (Left . ("manager provider unconfirmed: " ++) . show) id qualified
          pure $ case submitted of
            Left failure -> Left ("bus: " <> show failure)
            Right (Left failure) -> Left failure
            Right (Right observedAbsent) -> classifyControllerUnitAbsence observedAbsent
        (Left failure, _, _) -> pure (Left ("envelope: " <> failure))
        (_, Nothing, _) -> pure (Left "controller key invalid")
        (_, _, Nothing) -> pure (Left "controller window invalid")

-- A manager reply is only one observation. It cannot establish that the
-- submitted job and its physical worker family have settled.
classifyControllerUnitAbsence :: Bool -> Either String String
classifyControllerUnitAbsence observedAbsent = Left $
  if observedAbsent
    then "controller unit absent; submitted job and physical worker settlement unconfirmed"
    else "controller unit absence was not confirmed before the deadline"

waitForUnitAbsence :: Word64 -> BusConnection -> IO Bool
waitForUnitAbsence deadline connection =
  waitForUnitAbsenceWith getMonotonicTimeNSec observe (threadDelay 250000) deadline
 where
  observe = do
    result <-
      runExceptT
        (callManager connection GetUnit (\message -> appendString message unitName) (`readString` 'o'))
    pure $ case result of
      Left (BusMethodRefused 2) -> True
      _ -> False

-- An expired clock or an unobservable unit is never evidence of absence.
-- Check the clock again after the read, which may itself consume the budget.
waitForUnitAbsenceWith :: IO Word64 -> IO Bool -> IO () -> Word64 -> IO Bool
waitForUnitAbsenceWith clock observe pause deadline = loop
 where
  loop = do
    before <- clock
    if before >= deadline
      then pure False
      else do
        absent <- observe
        after <- clock
        if after >= deadline
          then pure False
          else if absent then pure True else pause >> loop

-- A read-only unit inventory that failed or expired cannot authorize follow-up
-- operations, including probes which create temporary Kubernetes resources.
afterControllerSettlement :: Either String String -> IO a -> IO (Maybe a)
afterControllerSettlement settled action = case settled of
  Left _ -> pure Nothing
  Right _ -> Just <$> action

-- The caller holds the recovered operation lease for the entire observation.
-- Each callback is independently observed; this is not worker settlement or
-- authentication of the Kubernetes peer. A result after change is retained as
-- a diagnostic, never upgraded to a successful observation.
observeControllerUnderLease
  :: IO Bool -> IO (Maybe String) -> (String -> IO Bool)
  -> IO ReadinessObservation -> IO String
  -> IO (Maybe String, ReadinessObservation, String)
observeControllerUnderLease stable readReceipt nodeMatches readReadiness probe = do
  initial <- stable
  node <- if initial then readReceipt else pure Nothing
  nodeReady <- case node of
    Just identifier -> nodeMatches identifier
    Nothing -> pure False
  held <- stable
  readiness <- if initial && nodeReady && held then readReadiness
    else pure (ReadinessUnobservable "bound running node not confirmed")
  readyToProbe <- stable
  network <- case (node, readiness) of
    (Just _, ReadinessObserved True 1 1 _ _) | readyToProbe -> probe
    _ -> pure "Network policy enforcement: not observed (worker receipt or readiness unconfirmed)."
  finalStable <- stable
  finalNode <- if finalStable then readReceipt else pure Nothing
  finalMatches <- case (node, finalNode) of
    (Just first, Just lastNode) | first == lastNode -> nodeMatches first
    _ -> pure False
  finalReady <- if finalMatches then readReadiness else pure (ReadinessUnobservable "final node identity unconfirmed")
  after <- stable
  let stillReady = case finalReady of ReadinessObserved True 1 1 _ _ -> True; _ -> False
  if finalStable && finalMatches && stillReady && after
    then pure (node, readiness, network)
    else pure (Nothing, ReadinessUnobservable "operation or final node readiness unconfirmed", "Network policy enforcement: final binding unconfirmed; prior result: " ++ network)

kindControllerRequest
  :: Host.HostExecutionPlan
  -> Subprocess.HostExecutionKey
  -> Subprocess.HostExecutionWindow
  -> FilePath
  -> [String]
  -> BusMessage
  -> BusAction ()
kindControllerRequest plan key window executable args message = do
  appendString message unitName
  appendString message "fail"
  withContainer message 'a' "(sv)" $ do
    string "Description" (Subprocess.kindHostSubprocessDescription plan key window)
    string "CollectMode" "inactive-or-failed"
    string "Type" "exec"
    string "Slice" sliceName
    strings "RuntimeDirectory" [runtimeDirectoryName]
    word32 "UMask" 0o077
    word32 "RuntimeDirectoryMode" 0o700
    string "RuntimeDirectoryPreserve" "no"
    string "Restart" "no"
    string "KillMode" "control-group"
    int32 "KillSignal" 9
    int32 "FinalKillSignal" 9
    boolean "SendSIGKILL" True
    number "MemoryMax" (Host.hostExecutionParentMemoryBytes plan)
    number "MemorySwapMax" 0
    number "TasksMax" (Host.hostExecutionParentTasks plan)
    number "CPUQuotaPerSecUSec" (Host.hostExecutionParentCpuUsecPerSec plan)
    number "RuntimeMaxUSec" 580000000
    number "RuntimeRandomizedExtraUSec" 0
    number "TimeoutStartUSec" 10000000
    number "TimeoutStopUSec" 5000000
    string "StandardInput" "null"
    string "StandardOutput" "null"
    string "StandardError" "null"
    exec (executable : args <> ["+RTS", "-N1", "-M" <> show heapCapBytes, "-RTS"])
  withContainer message 'a' "(sa(sv))" $
    withContainer message 'r' "sa(sv)" $ do
      appendString message sliceName
      withContainer message 'a' "(sv)" $ do
        string "Description" "prodbox kind controller slice"
        string "CollectMode" "inactive-or-failed"
        number "MemoryMax" (Host.hostExecutionSliceMemoryBytes plan)
        number "MemorySwapMax" 0
        number "TasksMax" (Host.hostExecutionSliceTasks plan)
        number "CPUQuotaPerSecUSec" (Host.hostExecutionSliceCpuUsecPerSec plan)
        boolean "StopWhenUnneeded" True
 where
  heapCapBytes =
    Runtime.positiveBytesValue
      (Runtime.runtimeMemoryHeapCapBytes (Host.hostExecutionRuntimeMemory plan))
  property label signature body =
    withContainer
      message
      'r'
      "sv"
      (appendString message label >> withContainer message 'v' signature body)
  string label value = property label "s" (appendString message value)
  number label value = property label "t" (appendWord64 message value)
  word32 label value = property label "u" (appendWord32 message value)
  int32 label value = property label "i" (appendInt32 message value)
  boolean label value = property label "b" (appendBoolean message value)
  strings label values = property label "as" (withContainer message 'a' "s" (mapM_ (appendString message) values))
  exec command = property "ExecStart" "a(sasb)" $ withContainer message 'a' "(sasb)" $ withContainer message 'r' "sasb" $ do
    appendString message executable
    withContainer message 'a' "s" (mapM_ (appendString message) command)
    appendBoolean message False

validControllerResultPath :: BootstrapProjection -> String -> FilePath -> Bool
validControllerResultPath bootstrap operation resultPath =
  scopeEnvironment (bootstrapScope bootstrap) == Test
    && validRootGeneration operation
    && resultPath == scopeRoot (bootstrapScope bootstrap) </> ("kind-controller-result-" ++ operation)

-- | Entry inside the managed unit. A receipt is recorded only after the typed
-- worker result and the selected kubeconfig installation both succeed.
runKindControllerEntry :: [String] -> IO ExitCode
runKindControllerEntry arguments = case arguments of
  [ selected
    , operation
    , clientPath
    , clientDigest
    , resultPath
    , outerText
    , workText
    , hardText
    , stopText
    , finishText
    ]
      | Just [outer, work, hard, stop, finish] <-
          traverse readMaybe [outerText, workText, hardText, stopText, finishText] -> do
          selectedBootstrap <- readBootstrapProjection selected
          case selectedBootstrap of
            Right bootstrap | validControllerResultPath bootstrap operation resultPath -> do
              outcome <- try (controller selected operation clientPath clientDigest outer work hard stop finish)
              let (line, completed) = case outcome of
                    Left (_ :: IOException) -> ("FAIL: controller attempt did not complete\n", False)
                    Right result -> result
              written <- writeControllerDiagnostic bootstrap operation line
              pure $ if written && completed then ExitSuccess else ExitFailure 2
            _ -> pure (ExitFailure 64)
  _ -> pure (ExitFailure 64)

-- The diagnostic is not authority. It still uses the selected held root and
-- exclusive no-follow creation so internal arguments cannot overwrite files.
writeControllerDiagnostic :: BootstrapProjection -> String -> String -> IO Bool
writeControllerDiagnostic bootstrap operation line = do
  outcome <- withScopeRootDescriptor (bootstrapScope bootstrap) $ \root sameRoot -> do
    before <-
      observeScopeGeneration (bootstrapScope bootstrap) (Text.unpack (bootstrapRootGeneration bootstrap))
    stable <- sameRoot
    if not stable || before /= Right ScopeGenerationMatches
      then pure False
      else do
        let name = "kind-controller-result-" ++ operation
            flags =
              Posix.defaultFileFlags
                { Posix.nofollow = True
                , Posix.cloexec = True
                , Posix.exclusive = True
                , Posix.creat = Just 0o600
                }
        written <- try $ bracket (Posix.openFdAt (Just root) name Posix.WriteOnly flags) Posix.closeFd $ \file -> do
          let bytes = ByteString8.pack line
          count <- PosixBytes.fdWrite file bytes
          unless
            (fromIntegral count == ByteString.length bytes)
            (ioError (userError "short controller diagnostic write"))
          fileSynchronise file
          fileSynchronise root
        after <-
          observeScopeGeneration (bootstrapScope bootstrap) (Text.unpack (bootstrapRootGeneration bootstrap))
        still <- sameRoot
        pure $ either (const False) (const (still && after == before)) (written :: Either IOException ())
  pure (either (const False) id outcome)

controller
  :: FilePath
  -> String
  -> FilePath
  -> String
  -> Word64
  -> Word64
  -> Word64
  -> Word64
  -> Word64
  -> IO (String, Bool)
controller selected operation clientPath clientDigest outer work hard stop finish = do
  present <- doesFileExist clientPath
  unless present (fail "client executable absent")
  bootstrap <- readBootstrapProjection selected >>= either (fail . show) pure
  unless
    (scopeEnvironment (bootstrapScope bootstrap) == Test)
    (fail "only a test identity is admitted")
  (plan, budgets) <-
    kindControllerEnvelope (scopeRoot (bootstrapScope bootstrap)) >>= either fail pure
  key <- maybe (fail "controller key invalid") pure (controllerKey operation)
  window <-
    maybe
      (fail "controller window invalid")
      pure
      (Subprocess.hostExecutionWindow outer work hard stop finish)
  resources <-
    either
      (fail . show)
      pure
      ( Subprocess.mkOwnedSubprocessResourceBounds
          (64 * 1048576)
          16
          500000
          (16 * 1048576)
          8
          100000
          30000
          30000
      )
  limits <-
    either
      (fail . show)
      pure
      (Subprocess.mkOwnedSubprocessLimits resources 600000000 100000 300000 100000 65536 65536)
  result <-
    Subprocess.withKindHostSubprocessPlacement plan key window $ \placement ->
      withPaths ["/usr", "/etc/ld.so.cache", "/dev/null"] (attempt placement budgets limits bootstrap)
  -- The credential kind wrote in the worker scratch is installed only when it
  -- validates against the selected scope; a missing source is a normal outcome
  -- for an attempt that did not finish.
  installed <- installKindKubeconfig bootstrap operation
  let identifier = either (const Nothing) confirmedKindWorkerNode result
  recorded <- case (identifier, installed) of
    (Just nodeId, KindKubeconfigInstalled) -> do
      receipt <- withRecoveredKindOperation bootstrap operation $ \stable ->
        recordControllerReceipt bootstrap operation nodeId stable
      pure $ case receipt of
        KindOperationCallbackReturned ControllerReceiptRecorded -> True
        _ -> False
    _ -> pure False
  pure
    ( if recorded
        then "RESULT: bound worker receipt recorded\n"
        else "FAIL: worker result or receipt unconfirmed\n"
    , recorded
    )
 where
  attempt placement budgets limits bootstrap descriptors = case descriptors of
    [usr, cache, nullDevice] ->
      Right
        <$> runArchiveBoundConfinedKindNodeOnHost
          180000000
          placement
          budgets
          limits
          bootstrap
          operation
          clientDigest
          (256 * 1024 * 1024)
          [usr, cache]
          nullDevice
          (\_ _ stable -> stable)
          (\_ _ _ stable -> stable)
    _ -> pure (Left Subprocess.HostSubprocessRuntimePlanMismatch)

withPaths :: [FilePath] -> ([Fd] -> IO value) -> IO value
withPaths paths action = case paths of
  [] -> action []
  path : remaining ->
    bracket
      ( withCString path $ \encoded ->
          Fd <$> throwErrnoIfMinus1 "open controller path" (kindControllerOpenPath encoded flags)
      )
      Posix.closeFd
      (\descriptor -> withPaths remaining (action . (descriptor :)))
 where
  flags = kindControllerPathOnly + kindControllerNoFollow + kindControllerCloseOnExec
