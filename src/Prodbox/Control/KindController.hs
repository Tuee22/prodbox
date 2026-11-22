{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
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
  , kindHostCapacityRefusal
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, bracket, try)
import Control.Monad (unless)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (runExceptT)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.Text qualified as Text
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
import Prodbox.Capacity.RuntimeMemory qualified as Runtime
import Prodbox.Config.BootstrapProjection
  ( bootstrapScope
  , readBootstrapProjection
  )
import Prodbox.Config.DeploymentScope
  ( DeploymentEnvironment (Test)
  , scopeEnvironment
  , scopeRoot
  )
import Prodbox.Control.KindKubeconfigInstall (installKindKubeconfig)
import Prodbox.Control.KindTool
  ( ArchiveBoundConfinedKindNode
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
import System.Directory (canonicalizePath, doesFileExist)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (..))
import System.Posix.IO qualified as Posix
import System.Posix.Types (Fd (..))
import System.Posix.User (getEffectiveUserID)
import Text.Read (readMaybe)

foreign import capi "fcntl.h value O_PATH" kindControllerPathOnly :: CInt
foreign import capi "fcntl.h value O_NOFOLLOW" kindControllerNoFollow :: CInt
foreign import capi "fcntl.h value O_CLOEXEC" kindControllerCloseOnExec :: CInt
foreign import capi "fcntl.h open" kindControllerOpenPath :: CString -> CInt -> IO CInt

unitName :: String
unitName = "prodbox-kind-controller.service"

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
  now <- getMonotonicTimeNSec
  observed <- observeNativeHostCapacityBefore (now + 2000000000) retainedRoot
  pure $ do
    allocated <- either (Left . show) Right (Allocation.compileResourcePlanUncertified source)
    host <- either (Left . show) Right observed
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
            , Runtime.runtimeRawChildSchedule = Runtime.BoundedChildSchedule 1 (Just 600000000) [80 * mib]
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
    plan <-
      either (Left . show) Right $
        Host.compileHostExecutionPlan
          host
          allocated
          (sealedToolRuntimePlan (kindWorkerKindBudget budgets))
          (Host.HostExecutionDemand 1000000 500000 100000 64 16 8 (64 * mib) (16 * mib) 1 0)
    pure (plan, budgets)

-- | Refuse with the compiled envelope's own reason when the observed host
-- cannot fund the declared controller and worker envelope.
kindHostCapacityRefusal :: FilePath -> IO (Maybe String)
kindHostCapacityRefusal retainedRoot = do
  envelope <- kindControllerEnvelope retainedRoot
  pure (either Just (const Nothing) envelope)

controllerKey :: String -> Maybe Subprocess.HostExecutionKey
controllerKey operation = Subprocess.hostExecutionKeyFromText (take 64 (operation <> operation <> operation))

-- | Submit the controller unit and wait for its terminal absence. The
-- result path must name a not-yet-existing file inside a private directory
-- the caller owns; the controller writes exactly one result line there.
launchKindController
  :: FilePath -> String -> FilePath -> IO (Either String String)
launchKindController selected operation resultPath = do
  bootstrap <- readBootstrapProjection selected
  case bootstrap of
    Left failure -> pure (Left ("bootstrap: " <> show failure))
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
          submitted <- withSystemdBus outer socket $ \connection -> lift $ do
            result <-
              runExceptT $
                callManager
                  connection
                  StartTransientUnit
                  (kindControllerRequest plan key window executable arguments)
                  (`readString` 'o')
            case result of
              Left failure -> pure (Left ("manager refused: " <> show failure))
              Right _ -> Right <$> waitForUnitAbsence finish connection
          pure $ case submitted of
            Left failure -> Left ("bus: " <> show failure)
            Right (Left failure) -> Left failure
            Right (Right ()) -> Right "controller unit absent after run"
        (Left failure, _, _) -> pure (Left ("envelope: " <> failure))
        (_, Nothing, _) -> pure (Left "controller key invalid")
        (_, _, Nothing) -> pure (Left "controller window invalid")

waitForUnitAbsence :: Word64 -> BusConnection -> IO ()
waitForUnitAbsence deadline connection = do
  now <- getMonotonicTimeNSec
  unless (now >= deadline) $ do
    result <-
      runExceptT
        (callManager connection GetUnit (\message -> appendString message unitName) (`readString` 'o'))
    case result of
      Left (BusMethodRefused 2) -> pure ()
      _ -> threadDelay 250000 >> waitForUnitAbsence deadline connection

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

-- | Entry inside the managed unit. Always attempts to write one result line.
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
          outcome <- try (controller selected operation clientPath clientDigest outer work hard stop finish)
          let line = case outcome of
                Left (failure :: SomeException) -> "FAIL: " <> show failure <> "\n"
                Right value -> "RESULT: " <> value <> "\n"
          written <- try (ByteString.writeFile resultPath (ByteString8.pack line))
          case written of
            Left (_ :: SomeException) -> pure (ExitFailure 2)
            Right () -> pure ExitSuccess
  _ -> pure (ExitFailure 64)

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
  -> IO String
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
  pure (renderResult result <> "; kubeconfig: " <> show installed)
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
  renderResult
    :: Either Subprocess.HostSubprocessError (InspectedArchiveResult ArchiveBoundConfinedKindNode)
    -> String
  renderResult = either (("placement refused: " <>) . show) show

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
