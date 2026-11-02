{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Closed controller data and local resource preparation. Neither a decoded
-- request nor a freshly compiled plan grants kernel or Authority admission.
module Prodbox.ControlPlane.RpcAdmissionBirthRequest
  ( RpcBirthControllerProfileInput (..)
  , RpcBirthControllerStreamInput (..)
  , RpcBirthControllerRequest
  , RpcBirthControllerRequestBytes
  , rpcBirthControllerRequestBytes
  , rpcBirthControllerRequestMaximumBytes
  , RpcBirthControllerRequestError (..)
  , mkRpcBirthControllerRequest
  , encodeRpcBirthControllerRequest
  , decodeRpcBirthControllerRequest
  , rpcBirthControllerRequestRoot
  , rpcBirthControllerRequestCoordination
  , rpcBirthControllerRequestWindow
  , rpcBirthControllerRequestKey
  , rpcBirthControllerRequestCaller
  , rpcBirthControllerRequestDomain
  , HostManagerDomain
  , hostManagerBootId
  , hostManagerBusId
  , hostManagerUniqueName
  , hostManagerUserId
  , hostManagerProcessId
  , hostManagerStartTicks
  , observeRpcBirthControllerManagerDomain
  , verifyRpcBirthControllerRequestDomain
  , RpcBirthControllerPreparation
  , prepareRpcBirthControllerRequest
  , rpcBirthControllerPreparedRequest
  , rpcBirthControllerPreparedSettings
  , rpcBirthControllerPreparedIntent
  , rpcBirthControllerPreparedPlan
  , rpcBirthControllerCommandLimits
  , rpcBirthControllerTransportLimits
  ) where

import Control.Monad (unless, void, when)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Void (Void)
import Data.Word (Word32, Word64)
import Dhall qualified
import Dhall.Binary qualified as Binary
import Dhall.Core qualified as Core
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Capacity.Config qualified as Capacity
import Prodbox.Capacity.HostExecution qualified as Host
import Prodbox.Capacity.NativeHostProbe qualified as Native
import Prodbox.Capacity.RuntimeMemory qualified as Memory
import Prodbox.ControlPlane.CallerPrincipal (callerPrincipalCode, callerPrincipalFromCode)
import Prodbox.ControlPlane.Coordinate (authorityScopeText, mkAuthorityScope)
import Prodbox.ControlPlane.HomeEndpoint qualified as Home
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller
  , externalCallerFromPrincipal
  , externalCallerPrincipal
  )
import Prodbox.ControlPlane.RpcAdmissionBirthClock qualified as Clock
import Prodbox.ControlPlane.RpcAdmissionBirthCoordinator
import Prodbox.ControlPlane.RpcAdmissionBirthRollout (rpcBirthRolloutExecutionKey)
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros, authorityTimeMicros)
import Prodbox.Settings qualified as Settings
import Prodbox.Subprocess qualified as Subprocess
import Prodbox.Subprocess.HostOperationFamily qualified as Operation
import Prodbox.Subprocess.StartupLine qualified as Startup
import Prodbox.Subprocess.SystemdBus qualified as Bus
import Prodbox.Subprocess.SystemdIdentity
  ( HostManagerDomain
  , hostManagerBootId
  , hostManagerBusId
  , hostManagerProcessId
  , hostManagerStartTicks
  , hostManagerUniqueName
  , hostManagerUserId
  )
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import System.FilePath (isAbsolute, normalise, splitDirectories, (</>))
import System.Posix.User (getEffectiveUserID)

data RpcBirthControllerStreamInput = RpcBirthControllerStreamInput
  { controllerStdoutBytes :: !Natural
  , controllerStderrBytes :: !Natural
  , controllerReaderGraceMicros :: !Natural
  }

data RpcBirthControllerProfileInput = RpcBirthControllerProfileInput
  { controllerRuntimeProfile :: !Capacity.RuntimeMemoryProfile
  , controllerContainerLimitBytes :: !Natural
  , controllerHostDemand :: !Host.HostExecutionDemand
  , controllerTransportDemand :: !Host.HostTransportDemand
  , controllerHelperStartMicros :: !Word64
  , controllerHelperStopMicros :: !Word64
  , controllerCommandStream :: !RpcBirthControllerStreamInput
  , controllerTransportStream :: !RpcBirthControllerStreamInput
  }

data RpcBirthControllerRequestError
  = ControllerRequestTooLarge
  | ControllerRequestEncodingInvalid
  | ControllerRequestShapeInvalid
  | ControllerRequestNonCanonical
  | ControllerRequestSchemaUnsupported
  | ControllerRequestProgramUnsupported
  | ControllerRequestCallerInvalid
  | ControllerRequestDomainInvalid
  | ControllerRequestDomainMismatch
  | ControllerRequestDomainUnavailable !Bus.BusError
  | ControllerRequestRootInvalid
  | ControllerRequestOperationInvalid
  | ControllerRequestKeyMismatch
  | ControllerRequestWindowInvalid
  | ControllerRequestWindowMismatch
  | ControllerRequestContextMismatch
  | ControllerRequestProfileInvalid
  | ControllerRequestExpired
  | ControllerRequestAuthorityWindowRefused
  | ControllerRequestHostRefused !Native.NativeHostProbeError
  | ControllerRequestResourcesRefused !Host.HostExecutionError
  | ControllerRequestIntentRefused !Operation.HostOperationError
  deriving (Eq, Show)

data WindowEnvelope = WindowEnvelope
  { outer_ns :: !Natural
  , work_ns :: !Natural
  , hard_ns :: !Natural
  , stop_ns :: !Natural
  , finish_ns :: !Natural
  }
  deriving (Generic)
instance Dhall.FromDhall WindowEnvelope
instance Dhall.ToDhall WindowEnvelope

data DemandEnvelope = DemandEnvelope
  { parent_cpu_usec_per_sec :: !Natural
  , child_cpu_usec_per_sec :: !Natural
  , helper_cpu_usec_per_sec :: !Natural
  , parent_tasks :: !Natural
  , child_tasks :: !Natural
  , helper_tasks :: !Natural
  , child_memory_bytes :: !Natural
  , helper_memory_bytes :: !Natural
  , ephemeral_storage_mib :: !Natural
  , durable_storage_mib :: !Natural
  }
  deriving (Generic)
instance Dhall.FromDhall DemandEnvelope
instance Dhall.ToDhall DemandEnvelope

data TransportEnvelope = TransportEnvelope
  { cpu_usec_per_sec :: !Natural
  , tasks :: !Natural
  , memory_bytes :: !Natural
  }
  deriving (Generic)
instance Dhall.FromDhall TransportEnvelope
instance Dhall.ToDhall TransportEnvelope

data StreamEnvelope = StreamEnvelope
  { stdout_bytes :: !Natural
  , stderr_bytes :: !Natural
  , reader_grace_micros :: !Natural
  }
  deriving (Generic)
instance Dhall.FromDhall StreamEnvelope
instance Dhall.ToDhall StreamEnvelope

data ProfileEnvelope = ProfileEnvelope
  { runtime_memory :: !Capacity.RuntimeMemoryProfile
  , container_limit_bytes :: !Natural
  , host_demand :: !DemandEnvelope
  , transport_demand :: !TransportEnvelope
  , helper_start_micros :: !Natural
  , helper_stop_micros :: !Natural
  , command_stream :: !StreamEnvelope
  , transport_stream :: !StreamEnvelope
  }
  deriving (Generic)
instance Dhall.FromDhall ProfileEnvelope
instance Dhall.ToDhall ProfileEnvelope

data DomainEnvelope = DomainEnvelope
  { kernel_boot_id :: !Text
  , bus_instance_id :: !Text
  , manager_unique_name :: !Text
  , manager_uid :: !Natural
  , manager_pid :: !Natural
  , manager_start_ticks :: !Natural
  }
  deriving (Generic)
instance Dhall.FromDhall DomainEnvelope
instance Dhall.ToDhall DomainEnvelope

data RequestEnvelope = RequestEnvelope
  { schema_version :: !Natural
  , program :: !Natural
  , caller_principal :: !Natural
  , host_domain :: !DomainEnvelope
  , repository_root :: !Text
  , deployment_context :: !Settings.DeploymentContextInput
  , authority_scope :: !Text
  , authority_deadline_micros :: !Natural
  , registration_generation :: !Natural
  , registration_key :: !Text
  , execution_key :: !Text
  , original_window :: !WindowEnvelope
  , host_profile :: !ProfileEnvelope
  }
  deriving (Generic)
instance Dhall.FromDhall RequestEnvelope
instance Dhall.ToDhall RequestEnvelope

-- Constructors and Show instances stay private: callers cannot alter a bound
-- request or accidentally render its complete settings/context carrier.
data RpcBirthControllerRequest = RpcBirthControllerRequest
  { storedRequestEnvelope :: !RequestEnvelope
  , storedRequestCoordination :: !RpcBirthCoordinationRequest
  , storedRequestWindow :: !Identity.HostExecutionWindow
  , storedRequestKey :: !Identity.HostExecutionKey
  , storedRequestMemory :: !Memory.RuntimeMemoryPlan
  , storedRequestDemand :: !Host.HostExecutionDemand
  , storedRequestTransport :: !Host.HostTransportDemand
  , storedRequestHelper :: !Operation.HostOperationHelperBounds
  , storedRequestCommandLimits :: !Subprocess.OperationStreamLimits
  , storedRequestTransportLimits :: !Subprocess.OperationStreamLimits
  , storedRequestCaller :: !ExternalLifecycleAuthorityCaller
  , storedRequestDomain :: !HostManagerDomain
  }

newtype RpcBirthControllerRequestBytes = RpcBirthControllerRequestBytes ByteString

rpcBirthControllerRequestBytes :: RpcBirthControllerRequestBytes -> ByteString
rpcBirthControllerRequestBytes (RpcBirthControllerRequestBytes bytes) = bytes

rpcBirthControllerRequestMaximumBytes :: Int
rpcBirthControllerRequestMaximumBytes = 1048576

rpcBirthControllerRequestRoot :: RpcBirthControllerRequest -> FilePath
rpcBirthControllerRequestRoot = Text.unpack . repository_root . storedRequestEnvelope

rpcBirthControllerRequestCoordination :: RpcBirthControllerRequest -> RpcBirthCoordinationRequest
rpcBirthControllerRequestCoordination = storedRequestCoordination

rpcBirthControllerRequestWindow :: RpcBirthControllerRequest -> Identity.HostExecutionWindow
rpcBirthControllerRequestWindow = storedRequestWindow

rpcBirthControllerRequestKey :: RpcBirthControllerRequest -> Identity.HostExecutionKey
rpcBirthControllerRequestKey = storedRequestKey

rpcBirthControllerRequestCaller :: RpcBirthControllerRequest -> ExternalLifecycleAuthorityCaller
rpcBirthControllerRequestCaller = storedRequestCaller

rpcBirthControllerRequestDomain :: RpcBirthControllerRequest -> HostManagerDomain
rpcBirthControllerRequestDomain = storedRequestDomain

mkRpcBirthControllerRequest
  :: ExternalLifecycleAuthorityCaller
  -> HostManagerDomain
  -> FilePath
  -> Settings.ValidatedSettings
  -> RpcBirthCoordinationRequest
  -> Identity.HostExecutionWindow
  -> RpcBirthControllerProfileInput
  -> Either RpcBirthControllerRequestError RpcBirthControllerRequest
mkRpcBirthControllerRequest caller domain root settings request window profile = do
  key <- first (const ControllerRequestOperationInvalid) (rpcBirthRolloutExecutionKey request)
  validateEnvelope $
    RequestEnvelope
      2
      1 -- The sole program is home Authority RPC registration.
      (fromIntegral (callerPrincipalCode (externalCallerPrincipal caller)))
      (domainEnvelope domain)
      (Text.pack root)
      (settingsContext settings)
      (authorityScopeText (rpcBirthCoordinationScope request))
      (authorityTimeMicros (rpcBirthCoordinationDeadline request))
      (rpcBirthCoordinationGeneration request)
      (rpcBirthCoordinationKey request)
      (Text.pack (Identity.hostExecutionKeyText key))
      (windowEnvelope window)
      (profileEnvelope profile)

encodeRpcBirthControllerRequest
  :: RpcBirthControllerRequest -> Either RpcBirthControllerRequestError RpcBirthControllerRequestBytes
encodeRpcBirthControllerRequest request = do
  let envelope = storedRequestEnvelope request
  let bytes =
        Lazy.toStrict
          (Lazy.take (fromIntegral rpcBirthControllerRequestMaximumBytes + 1) (canonicalValue envelope))
  checkSize bytes
  pure (RpcBirthControllerRequestBytes bytes)

decodeRpcBirthControllerRequest
  :: Identity.HostExecutionKey
  -> Identity.HostExecutionWindow
  -> ByteString
  -> Either RpcBirthControllerRequestError RpcBirthControllerRequest
decodeRpcBirthControllerRequest expectedKey expectedWindow bytes = do
  checkSize bytes
  expression <-
    first
      (const ControllerRequestEncodingInvalid)
      ( Binary.decodeExpression (Lazy.fromStrict bytes)
          :: Either Binary.DecodingFailure (Core.Expr Void Void)
      )
  envelope <-
    first
      (const ControllerRequestShapeInvalid)
      (Dhall.toMonadic (Dhall.extract (Dhall.auto @RequestEnvelope) (Core.denote expression)))
  request <- validateEnvelope envelope
  -- Normalize the typed value only; never evaluate untrusted imports or terms.
  unless (canonicalValue envelope == Lazy.fromStrict bytes) (Left ControllerRequestNonCanonical)
  unless (rpcBirthControllerRequestKey request == expectedKey) (Left ControllerRequestKeyMismatch)
  unless
    (rpcBirthControllerRequestWindow request == expectedWindow)
    (Left ControllerRequestWindowMismatch)
  pure request

canonicalValue :: RequestEnvelope -> Lazy.ByteString
canonicalValue = Binary.encodeExpression . Core.normalize . Core.denote . Dhall.embed Dhall.inject

checkSize :: ByteString -> Either RpcBirthControllerRequestError ()
checkSize bytes = do
  when (BS.length bytes > rpcBirthControllerRequestMaximumBytes) (Left ControllerRequestTooLarge)
  when (BS.null bytes) (Left ControllerRequestEncodingInvalid)

validateEnvelope
  :: RequestEnvelope -> Either RpcBirthControllerRequestError RpcBirthControllerRequest
validateEnvelope envelope = do
  unless (schema_version envelope == 2) (Left ControllerRequestSchemaUnsupported)
  unless (program envelope == 1) (Left ControllerRequestProgramUnsupported)
  caller <-
    maybe
      (Left ControllerRequestCallerInvalid)
      Right
      ( if caller_principal envelope <= fromIntegral (maxBound :: Word)
          then
            callerPrincipalFromCode (fromIntegral (caller_principal envelope)) >>= externalCallerFromPrincipal
          else Nothing
      )
  domain <- decodeDomain (host_domain envelope)
  let root = Text.unpack (repository_root envelope)
  unless (safeRoot root) (Left ControllerRequestRootInvalid)
  scope <-
    first (const ControllerRequestOperationInvalid) (mkAuthorityScope (authority_scope envelope))
  unless
    (Settings.contextInputClusterId (deployment_context envelope) == authorityScopeText scope)
    (Left ControllerRequestContextMismatch)
  unless (finite (authority_deadline_micros envelope)) (Left ControllerRequestOperationInvalid)
  request <-
    first
      (const ControllerRequestOperationInvalid)
      ( mkRpcBirthCoordinationRequest
          scope
          (authorityTimeFromMicros (authority_deadline_micros envelope))
          (registration_generation envelope)
          (registration_key envelope)
      )
  key <- first (const ControllerRequestOperationInvalid) (rpcBirthRolloutExecutionKey request)
  unless
    (execution_key envelope == Text.pack (Identity.hostExecutionKeyText key))
    (Left ControllerRequestKeyMismatch)
  window <- decodeWindow (original_window envelope)
  let profile = host_profile envelope
      runtime = runtime_memory profile
      child = Capacity.child_process_budget runtime
  unless
    ( Capacity.runtime_profile_id runtime == "rpc-birth-host"
        && Capacity.permit_capacity child == Just 2
        && length (take 3 (Capacity.simultaneous_peak_bytes child)) == 2
        && finite (container_limit_bytes profile)
    )
    (Left ControllerRequestProfileInvalid)
  memory <-
    first
      (const ControllerRequestProfileInvalid)
      (Capacity.runtimeMemoryPlanForLimit (container_limit_bytes profile) runtime)
  helperStart <- word ControllerRequestProfileInvalid (helper_start_micros profile)
  helperStop <- word ControllerRequestProfileInvalid (helper_stop_micros profile)
  helper <-
    maybe
      (Left ControllerRequestProfileInvalid)
      Right
      (Operation.hostOperationHelperBounds helperStart helperStop)
  command <- decodeStream (command_stream profile)
  transport <- decodeStream (transport_stream profile)
  mapM_
    ( first (const ControllerRequestProfileInvalid)
        . Subprocess.validateOperationStreamLimits memory window
    )
    [command, transport]
  pure
    ( RpcBirthControllerRequest
        envelope
        request
        window
        key
        memory
        (decodeDemand (host_demand profile))
        (decodeTransport (transport_demand profile))
        helper
        command
        transport
        caller
        domain
    )

domainEnvelope :: HostManagerDomain -> DomainEnvelope
domainEnvelope domain =
  DomainEnvelope
    (Text.pack (Identity.hostManagerBootId domain))
    (Text.pack (Identity.hostManagerBusId domain))
    (Text.pack (Identity.hostManagerUniqueName domain))
    (fromIntegral (Identity.hostManagerUserId domain))
    (fromIntegral (Identity.hostManagerProcessId domain))
    (fromIntegral (Identity.hostManagerStartTicks domain))

decodeDomain :: DomainEnvelope -> Either RpcBirthControllerRequestError HostManagerDomain
decodeDomain envelope = do
  unless
    (all (<= fromIntegral (maxBound :: Word32)) [manager_uid envelope, manager_pid envelope])
    (Left ControllerRequestDomainInvalid)
  started <- word ControllerRequestDomainInvalid (manager_start_ticks envelope)
  maybe (Left ControllerRequestDomainInvalid) Right $
    Identity.hostManagerDomain
      (Text.unpack (kernel_boot_id envelope))
      (Text.unpack (bus_instance_id envelope))
      (Text.unpack (manager_unique_name envelope))
      (fromIntegral (manager_uid envelope))
      (fromIntegral (manager_pid envelope))
      started

finite :: Natural -> Bool
finite value = value > 0 && value < fromIntegral (maxBound :: Word64)

word :: RpcBirthControllerRequestError -> Natural -> Either RpcBirthControllerRequestError Word64
word cause value = if finite value then Right (fromIntegral value) else Left cause

safeRoot :: FilePath -> Bool
safeRoot root =
  length (take 4097 root) <= 4096
    && '\0' `notElem` root
    && isAbsolute root
    && normalise root == root
    && ".." `notElem` splitDirectories root

settingsContext :: Settings.ValidatedSettings -> Settings.DeploymentContextInput
settingsContext settings =
  let selected = Settings.validatedDeploymentContext settings
   in Settings.DeploymentContextInput
        (Settings.deploymentClusterId selected)
        (Settings.deploymentVaultAddress selected)
        (Settings.deploymentMinioEndpoint selected)
        (Settings.deploymentRpcRegistration selected)

windowEnvelope :: Identity.HostExecutionWindow -> WindowEnvelope
windowEnvelope window =
  WindowEnvelope
    (fromIntegral (Identity.hostExecutionOuterEnd window))
    (fromIntegral (Identity.hostExecutionWorkEnd window))
    (fromIntegral (Identity.hostExecutionHardEnd window))
    (fromIntegral (Identity.hostExecutionStopEnd window))
    (fromIntegral (Identity.hostExecutionFinishEnd window))

decodeWindow :: WindowEnvelope -> Either RpcBirthControllerRequestError Identity.HostExecutionWindow
decodeWindow envelope = do
  outer <- clock outer_ns
  work <- clock work_ns
  hard <- clock hard_ns
  stop <- clock stop_ns
  finish <- clock finish_ns
  maybe
    (Left ControllerRequestWindowInvalid)
    Right
    (Identity.hostExecutionWindow outer work hard stop finish)
 where
  clock field = word ControllerRequestWindowInvalid (field envelope)

profileEnvelope :: RpcBirthControllerProfileInput -> ProfileEnvelope
profileEnvelope profile =
  ProfileEnvelope
    (controllerRuntimeProfile profile)
    (controllerContainerLimitBytes profile)
    ( let demand = controllerHostDemand profile
       in DemandEnvelope
            (Host.parentCpuUsecPerSec demand)
            (Host.childCpuUsecPerSec demand)
            (Host.helperCpuUsecPerSec demand)
            (Host.parentTasks demand)
            (Host.childTasks demand)
            (Host.helperTasks demand)
            (Host.childMemoryBytes demand)
            (Host.helperMemoryBytes demand)
            (Host.ephemeralStorageMib demand)
            (Host.durableStorageMib demand)
    )
    ( let demand = controllerTransportDemand profile
       in TransportEnvelope
            (Host.transportCpuUsecPerSec demand)
            (Host.transportTasks demand)
            (Host.transportMemoryBytes demand)
    )
    (fromIntegral (controllerHelperStartMicros profile))
    (fromIntegral (controllerHelperStopMicros profile))
    (streamEnvelope (controllerCommandStream profile))
    (streamEnvelope (controllerTransportStream profile))

streamEnvelope :: RpcBirthControllerStreamInput -> StreamEnvelope
streamEnvelope (RpcBirthControllerStreamInput out err grace) = StreamEnvelope out err grace

decodeStream
  :: StreamEnvelope -> Either RpcBirthControllerRequestError Subprocess.OperationStreamLimits
decodeStream envelope = do
  let out = stdout_bytes envelope
      err = stderr_bytes envelope
  unless
    (out > 0 && out < fromIntegral (maxBound :: Int) && err > 0 && err < fromIntegral (maxBound :: Int))
    (Left ControllerRequestProfileInvalid)
  grace <- word ControllerRequestProfileInvalid (reader_grace_micros envelope)
  first
    (const ControllerRequestProfileInvalid)
    (Subprocess.mkOperationStreamLimits (fromIntegral out) (fromIntegral err) grace)

decodeDemand :: DemandEnvelope -> Host.HostExecutionDemand
decodeDemand value =
  Host.HostExecutionDemand
    (parent_cpu_usec_per_sec value)
    (child_cpu_usec_per_sec value)
    (helper_cpu_usec_per_sec value)
    (parent_tasks value)
    (child_tasks value)
    (helper_tasks value)
    (child_memory_bytes value)
    (helper_memory_bytes value)
    (ephemeral_storage_mib value)
    (durable_storage_mib value)

decodeTransport :: TransportEnvelope -> Host.HostTransportDemand
decodeTransport value = Host.HostTransportDemand (cpu_usec_per_sec value) (tasks value) (memory_bytes value)

data RpcBirthControllerPreparation
  = RpcBirthControllerPreparation
      !RpcBirthControllerRequest
      !Settings.ValidatedSettings
      !Operation.HostOperationIntent

rpcBirthControllerPreparedRequest :: RpcBirthControllerPreparation -> RpcBirthControllerRequest
rpcBirthControllerPreparedRequest (RpcBirthControllerPreparation value _ _) = value

rpcBirthControllerPreparedSettings :: RpcBirthControllerPreparation -> Settings.ValidatedSettings
rpcBirthControllerPreparedSettings (RpcBirthControllerPreparation _ value _) = value

rpcBirthControllerPreparedIntent :: RpcBirthControllerPreparation -> Operation.HostOperationIntent
rpcBirthControllerPreparedIntent (RpcBirthControllerPreparation _ _ value) = value

rpcBirthControllerPreparedPlan :: RpcBirthControllerPreparation -> Host.HostExecutionTransportPlan
rpcBirthControllerPreparedPlan = Operation.hostOperationPlan . rpcBirthControllerPreparedIntent

rpcBirthControllerCommandLimits
  , rpcBirthControllerTransportLimits
    :: RpcBirthControllerPreparation -> Subprocess.OperationStreamLimits
rpcBirthControllerCommandLimits = storedRequestCommandLimits . rpcBirthControllerPreparedRequest
rpcBirthControllerTransportLimits = storedRequestTransportLimits . rpcBirthControllerPreparedRequest

prepareRpcBirthControllerRequest
  :: RpcBirthControllerRequest
  -> Settings.ValidatedSettings
  -> IO (Either RpcBirthControllerRequestError RpcBirthControllerPreparation)
prepareRpcBirthControllerRequest request settings = runExceptT $ do
  let envelope = storedRequestEnvelope request
      coordination = storedRequestCoordination request
      window = storedRequestWindow request
  unless
    (deployment_context envelope == settingsContext settings)
    (throwE ControllerRequestContextMismatch)
  let expectedRoot =
        rpcBirthControllerRequestRoot request
          </> Text.unpack (Settings.manual_pv_host_root (Settings.storage (Settings.validatedConfig settings)))
      retainedRoot = Settings.resolvedManualPvHostRoot settings
  unless (normalise expectedRoot == normalise retainedRoot) (throwE ControllerRequestRootInvalid)
  ExceptT (checkOriginalWindow coordination window)
  -- Historical requests remain decodable for observation/retirement. Current
  -- startup protocol funding is an effect-preparation requirement instead.
  startup <-
    either (const (throwE ControllerRequestProfileInvalid)) pure $
      Startup.mkStartupLineExpectation
        (map Bytes.pack (Home.homeControlPlaneForwardStartupLines Home.HomeLifecycleAuthority 65535))
  either (const (throwE ControllerRequestProfileInvalid)) pure $
    Subprocess.validateOperationTransportStartupLimits
      (storedRequestMemory request)
      window
      (storedRequestTransportLimits request)
      startup
  ExceptT (verifyRpcBirthControllerRequestDomain request)
  observed <-
    ExceptT
      ( first ControllerRequestHostRefused
          <$> Native.observeNativeHostCapacityBefore (Identity.hostExecutionWorkEnd window) retainedRoot
      )
  plan <-
    either
      (throwE . ControllerRequestResourcesRefused)
      pure
      ( Host.compileHostExecutionPlanWithTransport
          observed
          (Settings.validatedAllocatedPlan settings)
          (storedRequestMemory request)
          (storedRequestDemand request)
          (storedRequestTransport request)
      )
  intent <-
    ExceptT
      ( first ControllerRequestIntentRefused
          <$> Operation.newHostOperationIntent
            Identity.RpcBirthController
            plan
            (storedRequestHelper request)
            (storedRequestKey request)
            window
      )
  ExceptT (verifyRpcBirthControllerRequestDomain request)
  ExceptT (checkOriginalWindow coordination window)
  pure (RpcBirthControllerPreparation request settings intent)

observeRpcBirthControllerManagerDomain
  :: Word64 -> IO (Either RpcBirthControllerRequestError HostManagerDomain)
observeRpcBirthControllerManagerDomain ending = do
  uid <- getEffectiveUserID
  first ControllerRequestDomainUnavailable
    <$> Bus.withSystemdBus ending ("/run/user/" <> show uid <> "/bus") Bus.observeManagerDomain

verifyRpcBirthControllerRequestDomain
  :: RpcBirthControllerRequest -> IO (Either RpcBirthControllerRequestError ())
verifyRpcBirthControllerRequestDomain request = do
  current <-
    observeRpcBirthControllerManagerDomain (Identity.hostExecutionWorkEnd (storedRequestWindow request))
  pure $ do
    domain <- current
    unless (domain == storedRequestDomain request) (Left ControllerRequestDomainMismatch)

checkOriginalWindow
  :: RpcBirthCoordinationRequest
  -> Identity.HostExecutionWindow
  -> IO (Either RpcBirthControllerRequestError ())
checkOriginalWindow coordination window = do
  observed <-
    Clock.observeRpcBirthHostWindow
      (Identity.hostExecutionWorkEnd window, Identity.hostExecutionOuterEnd window)
      (rpcBirthCoordinationDeadline coordination)
  pure (first cause (void observed))
 where
  cause errorValue = case errorValue of
    Clock.RpcBirthHostClockExpired -> ControllerRequestExpired
    Clock.RpcBirthHostClockOutsideAuthorityBound -> ControllerRequestAuthorityWindowRefused
    Clock.RpcBirthHostClockSampleInvalid -> ControllerRequestWindowInvalid
    Clock.RpcBirthHostClockRemainingOverflow -> ControllerRequestWindowInvalid
