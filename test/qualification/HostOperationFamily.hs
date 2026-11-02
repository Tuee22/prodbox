{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}

-- | Actual manager/clock/workspace controls for the closed family request.
-- The self-contained fixture controller is not a production Authority caller.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Exception (IOException, SomeException, bracket, catch, fromException, throwIO, try)
import Control.Monad (forM_, unless, void, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (runExceptT)
import Data.Aeson (Value, eitherDecode, encode, object, withObject, (.:), (.=))
import Data.Aeson.Types (parseEither)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as Bytes
import Data.ByteString.Lazy.Char8 qualified as Lazy
import Data.Either (isLeft)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (isSuffixOf)
import Data.Maybe (isJust)
import Data.Text qualified as TextValue
import Data.Text.Encoding qualified as Text
import Data.Word (Word64, Word8)
import Foreign (Ptr, nullPtr)
import Foreign.C.Error (Errno (..), eAGAIN, throwErrnoIfMinus1Retry)
import Foreign.C.Types (CInt (..), CUInt (..), CULong (..))
import GHC.Clock (getMonotonicTimeNSec)
import GHC.IO.Exception (ioe_errno)
import Numeric.Natural (Natural)
import Prodbox.Capacity.Allocation qualified as A
import Prodbox.Capacity.Config qualified as C
import Prodbox.Capacity.HostExecution qualified as H
import Prodbox.Capacity.HostProbe qualified as Probe
import Prodbox.Capacity.ObservedHost qualified as Observed
import Prodbox.Capacity.RuntimeMemory qualified as R
import Prodbox.Subprocess qualified as Supervisor
import Prodbox.Subprocess.HostControllerInputs qualified as Inputs
import Prodbox.Subprocess.HostOperationFamily
import Prodbox.Subprocess.HostOperationRetirement qualified as Retirement
import Prodbox.Subprocess.KernelScope qualified as Kernel
import Prodbox.Subprocess.SystemdBus
import Prodbox.Subprocess.SystemdIdentity qualified as I
import Prodbox.Subprocess.SystemdProvider qualified as Provider
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, makeAbsolute)
import System.Environment (getArgs, setEnv, unsetEnv)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (getFdStatus, isDirectory, readSymbolicLink, setFileMode)
import System.Posix.IO
  ( FdOption (..)
  , OpenFileFlags (..)
  , OpenMode (ReadOnly)
  , closeFd
  , createPipe
  , defaultFileFlags
  , fdWrite
  , openFd
  , openFdAt
  , setFdOption
  )
import System.Posix.IO.ByteString qualified as Posix
import System.Posix.Process (ProcessStatus)
import System.Posix.Process qualified as Process
import System.Posix.Types (Fd (..), ProcessID)
import System.Posix.User (getEffectiveUserID)
import SystemdSubmissionProxy qualified as Proxy
import Text.Read (readMaybe)
import "crypton" Crypto.Random (getRandomBytes)

foreign import capi "sys/pidfd.h pidfd_open" openRolePidfd :: CInt -> CUInt -> IO CInt
foreign import capi "sys/pidfd.h pidfd_send_signal"
  signalRolePidfd :: CInt -> CInt -> Ptr () -> CUInt -> IO CInt
foreign import capi "sys/prctl.h prctl"
  setParentDeathSignal :: CInt -> CULong -> CULong -> CULong -> CULong -> IO CInt
foreign import capi "unistd.h getsid" roleSessionId :: CInt -> IO CInt

right :: (Show error) => Either error value -> IO value
right = either (fail . show) pure

data FixtureCpuProfile = ParentOnlyCpu | ConcurrentRoleCpu

fixtureCpuProfile :: String -> FixtureCpuProfile
fixtureCpuProfile mode
  | mode `elem` (roleModes <> supervisorModes) = ConcurrentRoleCpu
  | otherwise = ParentOnlyCpu

fixturePlan :: String -> IO (H.HostExecutionTransportPlan, Observed.ObservedHostRoot)
fixturePlan mode = do
  unsetEnv "PRODBOX_TEST_HOST_CAPACITY"
  observed <-
    right =<< Probe.observeHostCapacity "/home/matthewnowak/prodbox" "/home/matthewnowak/prodbox"
  plan <- fixturePlanFrom observed 16 100000 (fixtureCpuProfile mode)
  pure (plan, observed)

fixturePlanFrom
  :: Observed.ObservedHostRoot
  -> Natural
  -> Natural
  -> FixtureCpuProfile
  -> IO H.HostExecutionTransportPlan
fixturePlanFrom observed heap transportCpu cpuProfile = do
  let (parentCpu, commandCpu) = case cpuProfile of
        ParentOnlyCpu -> (100000, 400000)
        ConcurrentRoleCpu -> (300000, 200000)
      base = C.defaultResourcePlan
      isolated =
        base
          { C.host_capacity = C.ResourceVector 2000 4096 8192 8192
          , C.rke2_reserved = C.ResourceVector 100 128 256 1
          , C.eviction_floor = C.ResourceVector 100 128 256 1
          , C.platform_scheduler_requests = Just (C.ResourceVector 0 0 0 0)
          , C.workload_profiles = filter ((== "redis") . C.profile_id) (C.workload_profiles base)
          }
      bytes term count = either (error . show) id (R.mkPositiveBytes term (count * 1048576))
  allocated <- right (A.compileResourcePlanUncertified isolated)
  runtime <-
    right $
      R.validateRuntimeMemoryPlan
        R.RuntimeMemoryInputs
          { R.runtimeBoundedApplicationState = bytes R.BoundedApplicationState 2
          , R.runtimeBoundedPendingPersistenceState = bytes R.BoundedPendingPersistenceState 1
          , R.runtimeInHeapTransportDecodeScratch = bytes R.InHeapTransportDecodeScratch 3
          , R.runtimeOtherHeapReserve = bytes R.OtherHeapReserve 2
          , R.runtimeHeapCap = bytes R.HeapCap heap
          , R.runtimeNativeNonHeapReserve = bytes R.NativeNonHeapReserve 32
          , R.runtimeRawChildSchedule = R.BoundedChildSchedule 2 (Just 5000000) [64 * 1048576, 16 * 1048576]
          , R.runtimeKernelCgroupReserve = bytes R.KernelCgroupReserve 8
          , R.runtimeSafetyMargin = bytes R.SafetyMargin 8
          , R.runtimeContainerMemoryLimit = bytes R.ContainerMemoryLimit 256
          }
  right $
    H.compileHostExecutionPlanWithTransport
      observed
      allocated
      runtime
      (H.HostExecutionDemand parentCpu commandCpu 100000 16 24 8 (48 * 1048576) (16 * 1048576) 1 0)
      (H.HostTransportDemand transportCpu 8 (16 * 1048576))

observedValue :: Observed.ObservedHostRoot -> Value
observedValue observed =
  object
    [ "milli_cpu" .= C.milli_cpu vector
    , "memory_mib" .= C.memory_mib vector
    , "ephemeral_storage_mib" .= C.ephemeral_storage_mib vector
    , "durable_storage_mib" .= C.durable_storage_mib vector
    , "ephemeral_device" .= Observed.storageDeviceIdText (Observed.observedEphemeralDevice observed)
    , "durable_device" .= Observed.storageDeviceIdText (Observed.observedDurableDevice observed)
    ]
 where
  vector = Observed.observedHostVector observed

decodeObserved :: Lazy.ByteString -> Either String Observed.ObservedHostRoot
decodeObserved bytes = do
  value <- eitherDecode bytes
  parseEither
    ( withObject "observed native fixture host" $ \payload -> do
        vector <-
          C.ResourceVector
            <$> payload .: "milli_cpu"
            <*> payload .: "memory_mib"
            <*> payload .: "ephemeral_storage_mib"
            <*> payload .: "durable_storage_mib"
        ephemeralText <- payload .: "ephemeral_device"
        durableText <- payload .: "durable_device"
        ephemeral <-
          maybe (fail "invalid ephemeral fixture device") pure (Observed.mkStorageDeviceId ephemeralText)
        durable <-
          maybe (fail "invalid durable fixture device") pure (Observed.mkStorageDeviceId durableText)
        either fail pure (Observed.mkObservedHostRoot vector ephemeral durable)
    )
    value

main :: IO ()
main = do
  args <- getArgs
  case args of
    "internal-rpc-birth-controller" : flags -> worker I.RpcBirthController flags
    "internal-cascade-controller" : flags -> worker I.OrdinaryCascadeController flags
    ["cascade-parent", directory] -> launch I.OrdinaryCascadeController "parent" directory
    ["cascade-roles", directory] -> launch I.OrdinaryCascadeController "roles" directory
    ["cascade-kind-mismatch", directory] -> launch I.OrdinaryCascadeController "kind-mismatch" directory
    [mode, directory] | mode `elem` supervisorModes -> launch I.RpcBirthController mode directory
    [mode, directory]
      | mode
          `elem` [ "expiry"
                 , "late-effect"
                 , "early-exit"
                 , "foreign-field"
                 , "expired-submit"
                 , "invalid-window"
                 , "oversized-helper"
                 , "expired-observation"
                 , "input-program-escape"
                 , "input-submit-changed"
                 , "submission-partial"
                 , "submission-existing"
                 , "queued-submission"
                 , "queued-sender-close"
                 , "lost-submission-reply"
                 , "parent"
                 , "parent-escape"
                 , "parent-wrong-key"
                 , "parent-wrong-window"
                 , "parent-wrong-resources"
                 , "parent-wrong-heap"
                 , "roles"
                 , "roles-busy"
                 , "roles-escape"
                 , "roles-expiry"
                 , "roles-parent-death"
                 , "roles-repeat"
                 , "roles-unsettled"
                 , "roles-wrong-child"
                 ] ->
          launch I.RpcBirthController mode directory
    _ -> fail "expected one operation-family control and a private directory"

worker :: I.HostControllerKind -> [String] -> IO ()
worker kind flags = workerRun kind flags `catch` failed
 where
  configuration [] = Nothing
  configuration ("--config" : path : _) = Just path
  configuration (_ : rest) = configuration rest
  failed :: IOException -> IO ()
  failed cause = do
    case configuration flags of
      Nothing -> pure ()
      Just path -> writeFile (takeDirectory path </> "worker-error") (show cause)
    ioError cause

workerRun :: I.HostControllerKind -> [String] -> IO ()
workerRun kind flags = do
  let pairs [] = []
      pairs (label : value : rest) = (label, value) : pairs rest
      pairs _ = error "malformed closed controller arguments"
      arguments = pairs flags
      required label = maybe (fail ("missing closed argument " <> label)) pure (lookup label arguments)
  configuration <- required "--config"
  request <- required "--request"
  key <- required "--operation-key"
  inputWorkText <- required "--work-ns"
  inputWork <- maybe (fail "original input work end") pure (readMaybe inputWorkText)
  fingerprintText <- required "--input-fingerprint"
  fingerprint <-
    maybe (fail "input fingerprint") pure (parseHostControllerInputFingerprint fingerprintText)
  right
    =<< withPinnedHostControllerProgram
      kind
      inputWork
      fingerprint
      configuration
      request
      ( \program -> do
          inputBytes <- right =<< readHostControllerProgramInputs program
          submissionKey <- maybe (fail "submission key") pure (I.hostExecutionKeyFromText key)
          submission <- right =<< Inputs.readHostControllerSubmission inputWork request submissionKey
          unless
            ( Inputs.hostControllerSubmissionKind submission == kind
                && Inputs.hostControllerSubmissionFingerprint submission
                  == hostControllerProgramInputFingerprint program
                && I.hostExecutionWorkEnd (Inputs.hostControllerSubmissionWindow submission) == inputWork
            )
            (fail "controller started without the original read-back submission record")
          writeFile (takeDirectory configuration </> "submission-before-controller") "confirmed"
          let mode = Bytes.unpack (hostControllerRequestBytes inputBytes)
          when (mode `elem` (parentModes <> roleModes <> supervisorModes)) $ do
            setEnv "PATH" "/prodbox-native-fixture-no-tools"
            observed <- right (decodeObserved (Lazy.fromStrict (hostControllerConfigurationBytes inputBytes)))
            plan <-
              fixturePlanFrom
                observed
                (if mode == "parent-wrong-heap" then 8 else 16)
                (if mode == "parent-wrong-resources" then 110000 else 100000)
                (fixtureCpuProfile mode)
            let readClock label = required label >>= maybe (fail "invalid fixture original clock") pure . readMaybe
            outer <- readClock "--outer-ns"
            work <- readClock "--work-ns"
            hard <- readClock "--hard-ns"
            stop <- readClock "--stop-ns"
            finish <- readClock "--finish-ns"
            let expectedKey =
                  if mode == "parent-wrong-key" then (if take 1 key == "a" then "b" else "a") <> drop 1 key else key
            coordinate <-
              maybe (fail "invalid parent fixture key") pure (I.hostExecutionKeyFromText expectedKey)
            window <-
              maybe
                (fail "invalid parent fixture window")
                pure
                ( I.hostExecutionWindow
                    outer
                    (work - if mode == "parent-wrong-window" then 1000000 else 0)
                    hard
                    stop
                    finish
                )
            helper <- maybe (fail "fixture parent helper") pure (hostOperationHelperBounds 20000 20000)
            intent <- right =<< newHostOperationIntent kind plan helper coordinate window
            entered <- newIORef False
            escaped <- newIORef Nothing
            uid <- getEffectiveUserID
            observation <- withSystemdBus outer ("/run/user/" <> show uid <> "/bus") $ \connection -> lift $
              Kernel.withObservedOperationParent connection intent program $ \parent -> do
                writeIORef entered True
                writeIORef escaped (Just parent)
                before <- Kernel.verifyOperationParentBeforeEffect parent
                case before of
                  Left cause -> pure (Left cause)
                  Right () -> do
                    writeFile
                      (takeDirectory configuration </> "parent-declarations")
                      (show (Kernel.operationParentChildDeclarations parent))
                    writeFile
                      (takeDirectory configuration </> "guarded-effect")
                      (Kernel.operationParentRuntimeDirectory parent)
                    if mode `elem` supervisorModes
                      then exerciseOperationSupervisor mode (takeDirectory configuration) window parent
                      else
                        if mode `elem` roleModes
                          then exerciseOperationRoles mode (takeDirectory configuration) window parent
                          else pure (Right ())
            result <- right observation
            let expected = case mode of
                  "parent" -> Right ()
                  "parent-escape" -> Right ()
                  "roles-unsettled" -> Left (Kernel.KernelHostRoleUnsettled OperationCommandProcess)
                  other | other `elem` (roleModes <> supervisorModes) -> Right ()
                  "parent-wrong-key" -> Left Kernel.KernelHostParentRefused
                  "parent-wrong-window" -> Left (Kernel.KernelHostOperationRefused HostOperationInvalidWindow)
                  "parent-wrong-resources" -> Left Kernel.KernelScopeResourceMismatch
                  "parent-wrong-heap" -> Left Kernel.KernelHostParentRefused
                  _ -> error "unreachable parent fixture mode"
            writeFile (takeDirectory configuration </> "parent-result") (show result)
            unless (result == expected) (fail ("parent observation mismatch: " <> show result))
            didEnter <- readIORef entered
            unless
              (didEnter == (expected == Right () || mode == "roles-unsettled"))
              (fail "refused parent entered its effect callback")
            when (mode == "parent-escape") $ do
              retained <- readIORef escaped >>= maybe (fail "missing escaped parent") pure
              refusal <- Kernel.verifyOperationParentBeforeEffect retained
              unless
                (refusal == Left Kernel.KernelHostPlacementClosed)
                (fail "escaped parent lease remained usable")
          uid <- getEffectiveUserID
          let directory = takeDirectory configuration
              runtime = "/run/user/" <> show uid <> "/" <> I.hostControllerKindPrefix kind <> key
          exists <- doesDirectoryExist runtime
          unless exists (fail "manager did not create the operation runtime directory")
          createDirectoryIfMissing True (runtime </> "tools")
          writeFile (runtime </> "tools" </> "cache") "synthetic fixture cache"
          writeFile (directory </> "started") runtime
          case mode of
            "early-exit" -> do
              hardText <- required "--hard-ns"
              hard <- maybe (fail "invalid original hard end") pure (readMaybe hardText)
              waitFile hard (directory </> "held")
            "late-effect" -> threadDelay 2300000 >> writeFile (directory </> "late-effect") "must not run"
            "expiry" -> threadDelay 10000000
            "foreign-field" -> threadDelay 10000000
            "queued-submission" -> threadDelay 10000000
            "queued-sender-close" -> threadDelay 10000000
            "lost-submission-reply" -> threadDelay 10000000
            other | other `elem` (parentModes <> roleModes <> supervisorModes) -> threadDelay 10000000
            _ -> fail "unsupported fixture controller mode"
      )

launch :: I.HostControllerKind -> String -> FilePath -> IO ()
launch kind mode relative = do
  directory <- makeAbsolute relative
  createDirectoryIfMissing True directory
  setFileMode directory 0o700
  let configuration = directory </> "config.dhall"
      request = directory </> "request"
  writeFile configuration "fixture inputs are not production daemon config"
  writeFile request mode
  mapM_ (`setFileMode` 0o600) [configuration, request]
  (plan, observed) <- fixturePlan mode
  Lazy.writeFile configuration (encode (observedValue observed))
  helper <- maybe (fail "fixture helper bounds") pure (hostOperationHelperBounds 20000 20000)
  nonce <- getRandomBytes 32
  key <-
    maybe (fail "fixture key") pure (I.hostExecutionKeyFromText (concatMap hex (BS.unpack nonce)))
  uid <- getEffectiveUserID
  started <- getMonotonicTimeNSec
  let outer = started + 5000000000
      work = started + if mode == "expired-submit" then 30000000 else 2000000000
      hard = started + 2150000000
      stop = started + 2500000000
      finish = started + 3000000000
  window <- maybe (fail "fixture window") pure (I.hostExecutionWindow outer work hard stop finish)
  intent <- right =<< newHostOperationIntent kind plan helper key window
  let programKind = if mode == "kind-mismatch" then I.RpcBirthController else kind
  right
    =<< withCurrentHostControllerProgram
      programKind
      work
      configuration
      request
      ( \program -> do
          let runtime = "/run/user/" <> show uid <> "/" <> hostOperationRuntimeDirectory intent
              group =
                "/sys/fs/cgroup/user.slice/user-"
                  <> show uid
                  <> ".slice/user@"
                  <> show uid
                  <> ".service/"
                  <> hostOperationUnitName intent OperationSlice
              flags = defaultFileFlags {nofollow = True, cloexec = True}
          Lazy.writeFile (directory </> "field.json") $
            encode $
              object
                [ "key" .= I.hostExecutionKeyText key
                , "kind" .= show kind
                , "roles" .= map (hostOperationUnitName intent) [minBound .. maxBound]
                , "outer_ns" .= outer
                , "work_ns" .= work
                , "hard_ns" .= hard
                , "stop_ns" .= stop
                , "finish_ns" .= finish
                ]
          let realSocket = "/run/user/" <> show uid <> "/bus"
              withConnection action = case mode of
                "queued-submission" -> proxyConnection Proxy.QueueBeforeManager
                "queued-sender-close" -> proxyConnection Proxy.QueueThenCloseSender
                "lost-submission-reply" -> proxyConnection Proxy.WithholdManagerReply
                _ -> withSystemdBus outer realSocket action
              proxyConnection fault =
                Proxy.withSubmissionProxy
                  finish
                  ( "/run/user/"
                      <> show uid
                      <> "/prodbox-submission-"
                      <> take 16 (I.hostExecutionKeyText key)
                      <> ".sock"
                  )
                  fault
                  ( \proxy socket -> exerciseSubmissionFault mode directory socket intent program proxy >> pure (Right ())
                  )
          result <- withConnection $ \connection ->
            lift $
              do
                if mode
                  `elem` [ "expired-submit"
                         , "invalid-window"
                         , "oversized-helper"
                         , "expired-observation"
                         , "input-program-escape"
                         , "input-submit-changed"
                         , "submission-partial"
                         , "submission-existing"
                         , "kind-mismatch"
                         ]
                  then do
                    case mode of
                      "kind-mismatch" -> do
                        refused <- submitHostOperationFamily connection intent program
                        unless
                          (refused == Left HostOperationProgramMismatch)
                          (fail "a registration program entered an ordinary family")
                        exists <- doesFileExist (Inputs.hostControllerSubmissionPath request key)
                        unless (not exists) (fail "kind mismatch published a submission record")
                      "expired-submit" -> do
                        threadDelay 40000
                        refused <- submitHostOperationFamily connection intent program
                        unless
                          (refused == Left HostOperationExpired)
                          (fail ("expired submission mismatch: " <> show refused))
                      "invalid-window" -> do
                        widened <-
                          maybe
                            (fail "widened fixture window")
                            pure
                            (I.hostExecutionWindow (outer + 1000000000) work hard stop finish)
                        refused <- newHostOperationIntent kind plan helper key widened
                        case refused of
                          Left HostOperationInvalidWindow -> pure ()
                          _ -> fail "operation exceeded its admitted child deadline"
                      "oversized-helper" -> do
                        enlarged <- maybe (fail "enlarged helper window") pure (hostOperationHelperBounds 200000 200000)
                        refused <- newHostOperationIntent kind plan enlarged key window
                        case refused of
                          Left HostOperationInvalidWindow -> pure ()
                          _ -> fail "helper activation and stop exceeded the original reserve"
                      "expired-observation" -> do
                        unobservable <- right =<< runBus (observeHostOperationFamily (systemdBusWithin 0 connection) intent)
                        when (hostOperationAbsent unobservable) (fail "unobservable field became absence")
                        mapM_ (verifyExpiredOperationPresence unobservable) [minBound .. maxBound]
                      "input-program-escape" -> do
                        escapedProgram <- right =<< withCurrentHostControllerProgram kind work configuration request pure
                        checked <- verifyHostControllerProgram intent escapedProgram
                        let expected = Left (HostOperationInputsRefused Inputs.ControllerInputsClosed)
                        unless (checked == expected) (fail "escaped controller program remained valid")
                        refused <- submitHostOperationFamily connection intent escapedProgram
                        unless (refused == expected) (fail "escaped controller program submitted a family")
                      "input-submit-changed" -> do
                        writeFile request "changed before submission"
                        refused <- submitHostOperationFamily connection intent program
                        unless
                          ( refused
                              == Left (HostOperationInputsRefused (Inputs.ControllerInputChanged Inputs.ControllerRequest))
                          )
                          (fail "changed request submitted a family")
                      "submission-partial" -> do
                        let path = Inputs.hostControllerSubmissionPath request key
                        BS.writeFile path BS.empty
                        setFileMode path 0o400
                        refused <- submitHostOperationFamily connection intent program
                        unless
                          (refused == Left (HostOperationInputsRefused Inputs.ControllerSubmissionExists))
                          (fail "partial provenance admitted a native family")
                        bytes <- BS.readFile path
                        unless (BS.null bytes) (fail "partial provenance was overwritten")
                      "submission-existing" -> do
                        domain <- right =<< runBus (observeManagerDomain connection)
                        sender <- right =<< runBus (observeBusSender connection)
                        recorded <-
                          right
                            =<< Inputs.withHostControllerInputs
                              work
                              configuration
                              request
                              ( \inputs -> do
                                  qualified <- Provider.withQualifiedProvider connection $ \provider ->
                                    Inputs.registerHostControllerSubmission kind inputs key window domain sender provider
                                  either (fail . show) pure qualified
                              )
                        _ <- right recorded
                        refused <- submitHostOperationFamily connection intent program
                        unless
                          (refused == Left (HostOperationInputsRefused Inputs.ControllerSubmissionExists))
                          (fail "existing provenance admitted a second native submission")
                      _ -> fail "unreachable rejection control"
                    inventory <- right =<< runBus (observeHostOperationFamily connection intent)
                    unless (hostOperationAbsent inventory) (fail "refused request created units")
                  else do
                    right =<< submitHostOperationFamily connection intent program
                    repeated <- submitHostOperationFamily connection intent program
                    unless (repeated == Left HostOperationAlreadyAttempted) (fail "one intent submitted twice")
                    waitFile work (directory </> "started")
                    when
                      ( mode
                          `elem` ( parentModes
                                     <> filter (`notElem` ["roles-expiry", "roles-parent-death"]) roleModes
                                     <> supervisorModes
                                 )
                      )
                      $ do
                        waitFile work (directory </> "parent-result")
                        effect <- doesFileExist (directory </> "guarded-effect")
                        unless
                          (effect == (mode `elem` (["parent", "parent-escape"] <> roleModes <> supervisorModes)))
                          (fail "parent refusal effect disposition mismatch")
                    expiry <- timerExpiry connection intent
                    unless (expiry == hard `div` 1000) (fail "timer renewed the original absolute expiry")
                    verifyWireLimits connection intent plan
                    when (mode == "foreign-field") $ do
                      otherKey <- maybe (fail "foreign key") pure (I.hostExecutionKeyFromText (replicate 64 'a'))
                      other <- right =<< newHostOperationIntent kind plan helper otherKey window
                      refused <- submitHostOperationFamily connection other program
                      case refused of
                        Left (HostOperationFieldNotAbsent inventory) ->
                          unless
                            (hostOperationPresence inventory OperationController == HostOperationAbsent)
                            (fail "foreign controller was created")
                        otherResult -> fail ("foreign field was not refused: " <> show otherResult)
                      unchanged <- timerExpiry connection intent
                      unless (unchanged == expiry) (fail "foreign refusal changed the original timer")
                    bracket (openFd group ReadOnly flags) closeFd $ \held -> do
                      status <- getFdStatus held
                      unless (isDirectory status) (fail "held group is not a directory")
                      when (mode == "roles-parent-death")
                        $ bracket
                          (openFdAt (Just held) (hostOperationUnitName intent OperationCommand) ReadOnly flags)
                          closeFd
                        $ \commandRoot ->
                          bracket
                            (openFdAt (Just held) (hostOperationUnitName intent OperationTransport) ReadOnly flags)
                            closeFd
                            $ \transportRoot -> do
                              writeFile (directory </> "held") "independent root and both role descriptors held"
                              mapM_ (waitForRetiredGroup work flags) [commandRoot, transportRoot]
                              waitUntil work $ not <$> doesDirectoryExist runtime
                              inventory <- right =<< runBus (observeHostOperationFamily connection intent)
                              case (hostOperationPresence inventory OperationTimer, hostOperationPresence inventory OperationSlice) of
                                (HostOperationPresent (InvocationPresent _), HostOperationPresent _) -> pure ()
                                other -> fail ("parent death did not retain original armed slot: " <> show other)
                              preserved <- timerExpiry connection intent
                              unless (preserved == expiry) (fail "parent death renewed original expiry")
                      when (mode == "early-exit") $ do
                        writeFile (directory </> "held") "independent root descriptor held"
                        waitUntil work $ not <$> doesDirectoryExist runtime
                        inventory <- right =<< runBus (observeHostOperationFamily connection intent)
                        case hostOperationPresence inventory OperationTimer of
                          HostOperationPresent (InvocationPresent _) -> pure ()
                          other -> fail ("early controller exit lost observable alarm: " <> show other)
                        case hostOperationPresence inventory OperationSlice of
                          HostOperationPresent _ -> pure ()
                          other -> fail ("armed alarm released the physical slot: " <> show other)
                        preserved <- timerExpiry connection intent
                        unless (preserved == expiry) (fail "early controller exit changed the original expiry")
                      waitUntil finish $
                        hostOperationAbsent <$> (right =<< runBus (observeHostOperationFamily connection intent))
                      waitUntil finish $ do
                        target <- readSymbolicLink ("/proc/self/fd/" <> show held)
                        gone <-
                          try (bracket (openFdAt (Just held) "cgroup.events" ReadOnly flags) closeFd (const (pure ())))
                            :: IO (Either IOException ())
                        pure (" (deleted)" `isSuffixOf` target && either isDoesNotExistError (const False) gone)
                    late <- doesFileExist (directory </> "late-effect")
                    retained <- doesDirectoryExist runtime
                    unless (not late && not retained) (fail "original expiry left an effect or a runtime workspace")
                pure ()
          right result
          ended <- getMonotonicTimeNSec
          unless (ended < finish) (fail "fixture exceeded the original settlement end")
          Lazy.putStrLn $
            encode $
              object
                [ "mode" .= mode
                , "kind" .= show kind
                , "elapsed_us" .= ((ended - started) `div` 1000)
                , "original_hard_ns" .= hard
                , "complete_six_role_absence" .= True
                , "profile" .= ("five seconds / 256 MiB / 700m / 56 tasks; native controller only" :: String)
                ]
      )

exerciseSubmissionFault
  :: String
  -> FilePath
  -> FilePath
  -> HostOperationIntent
  -> HostControllerProgram
  -> Proxy.SubmissionProxy
  -> IO ()
exerciseSubmissionFault mode directory socket intent program proxy = do
  uid <- getEffectiveUserID
  let window = hostOperationWindow intent
      outer = I.hostExecutionOuterEnd window
      work = I.hostExecutionWorkEnd window
      finish = I.hostExecutionFinishEnd window
      key = hostOperationKey intent
      request = directory </> "request"
      group =
        "/sys/fs/cgroup/user.slice/user-"
          <> show uid
          <> ".slice/user@"
          <> show uid
          <> ".service/"
          <> hostOperationUnitName intent OperationSlice
      flags = defaultFileFlags {directory = True, nofollow = True, cloexec = True}
      submit =
        right
          =<< withSystemdBus
            outer
            socket
            (\connection -> lift (right =<< submitHostOperationFamily connection intent program))
  observed <-
    right
      =<< withSystemdBus
        finish
        ("/run/user/" <> show uid <> "/bus")
        ( \observer -> lift $ try $ do
            Async.withAsync submit $ \pending -> do
              serial <- Proxy.awaitSubmissionRequest proxy
              record <- right =<< Inputs.readHostControllerSubmission finish request key
              current <- right =<< runBus (observeManagerDomain observer)
              unless
                (current == Inputs.hostControllerSubmissionDomain record)
                (fail "fault observer changed native domain")
              let sender = Inputs.hostControllerSubmissionSender record
              live <- right =<< runBus (observeBusNamePresence observer sender)
              before <- right =<< runBus (observeHostOperationFamily observer intent)
              unless (live == BusNamePresent) (fail "original sender was not live at the fault boundary")
              refused <- observeHostSubmissionCausalClosure observer record
              unless
                (case refused of Left HostSubmissionSenderPresent -> True; _ -> False)
                (fail "live sender acquired a processing witness")
              physicalRefused <- Retirement.withHostOperationRetirement observer record pure
              unless
                ( case physicalRefused of
                    Left (Retirement.RetirementProcessingRefused HostSubmissionSenderPresent) -> True
                    _ -> False
                )
                (fail "live sender acquired a physical retirement owner")
              when (mode /= "lost-submission-reply") $
                unless (hostOperationAbsent before) (fail "held request reached the native manager")
              when (mode == "lost-submission-reply") (Proxy.awaitSubmissionReply proxy)
              premature <- Async.poll pending
              unless
                (case premature of Nothing -> True; Just _ -> False)
                (fail "withheld native request/reply already returned")
              Async.cancel pending
              cancelled <- Async.waitCatch pending
              unless (isLeft cancelled) (fail "awaiting native caller did not propagate cancellation")
              afterCancel <- right =<< runBus (observeBusNamePresence observer sender)
              when (mode /= "lost-submission-reply") $ do
                unless
                  (afterCancel == BusNamePresent)
                  (fail "held upstream sender disappeared before the queued frame was released")
                Proxy.releaseSubmissionRequest proxy
              Proxy.awaitSubmissionProxyClosed proxy
              waitUntil finish $
                (== BusNameAbsent) <$> (right =<< runBus (observeBusNamePresence observer sender))
              -- Processing is distinct from the independently observed terminal
              -- kernel/alarm/workspace field; this witness cannot retire inputs.
              after <- right =<< runBus (observeHostOperationFamily observer intent)
              processed <- right =<< observeHostSubmissionCausalClosure observer record
              unless
                (hostSubmissionCausalMatches processed record)
                (fail "processing witness did not bind the original record")
              forM_ [minBound .. maxBound] (verifyPostSenderPresence after)
              let materialized = not (hostOperationAbsent after)
              if materialized
                then do
                  present <- Retirement.withHostOperationRetirement observer record pure
                  unless
                    (case present of Left (Retirement.RetirementRolePresent _) -> True; _ -> False)
                    (fail "present family acquired a physical retirement owner")
                  waitFile work (directory </> "started")
                  bracket (openFd group ReadOnly flags) closeFd $ \held -> do
                    waitUntil finish $
                      hostOperationAbsent <$> (right =<< runBus (observeHostOperationFamily observer intent))
                    waitUntil finish $ do
                      target <- readSymbolicLink ("/proc/self/fd/" <> show held)
                      gone <-
                        try (bracket (openFdAt (Just held) "cgroup.events" ReadOnly flags) closeFd (const (pure ())))
                          :: IO (Either IOException ())
                      pure (" (deleted)" `isSuffixOf` target && either isDoesNotExistError (const False) gone)
                else do
                  unless
                    (mode == "queued-sender-close")
                    (fail "positive-effect fault did not materialize a native family")
                  waitUntil finish $ (>= I.hostExecutionHardEnd window + 50000000) <$> getMonotonicTimeNSec
                  field <- right =<< runBus (observeHostOperationFamily observer intent)
                  unless (hostOperationAbsent field) (fail "blind sender-close field was not absent at settlement")
              groupRead <- try (openFd group ReadOnly flags) :: IO (Either IOException Fd)
              case groupRead of
                Left cause | isDoesNotExistError cause -> pure ()
                Left cause -> ioError cause
                Right fd -> closeFd fd >> fail "closing kernel path was still present"
              didStart <- doesFileExist (directory </> "started")
              retained <-
                doesDirectoryExist ("/run/user/" <> show uid <> "/" <> hostOperationRuntimeDirectory intent)
              unless (not retained) (fail "fault family retained its runtime workspace")
              closing <- right =<< Inputs.readHostControllerSubmission finish request key
              unless (closing == record) (fail "fault recovery changed submission provenance")
              retired <-
                right
                  =<< Retirement.withHostOperationRetirement
                    observer
                    record
                    ( \owner -> do
                        right =<< Retirement.verifyHostOperationRetirement owner
                        unless
                          (Retirement.hostOperationRetirementMatches owner record)
                          (fail "retirement changed original submission")
                        pure owner
                    )
              escaped <- Retirement.verifyHostOperationRetirement retired
              unless
                (escaped == Left Retirement.RetirementClosed)
                (fail "retirement owner escaped its descriptor scope")
              Lazy.writeFile (directory </> "submission-fault.json") $
                encode $
                  object
                    [ "mode" .= mode
                    , "request_serial" .= serial
                    , "original_sender" .= I.hostBusUniqueNameText sender
                    , "before_manager_absent" .= hostOperationAbsent before
                    , "before_sender_present" .= True
                    , "caller_cancelled" .= True
                    , "sender_still_present_after_cancellation" .= (afterCancel == BusNamePresent)
                    , "exact_sender_absent_before_manager_frontier" .= True
                    , "frontier_observed_materialized_family" .= materialized
                    , "controller_started" .= didStart
                    , "complete_six_role_and_held_cgroup_absence" .= materialized
                    , "closing_six_role_absence" .= True
                    , "fixed_kernel_path_absent" .= True
                    , "blind_close_without_reply_wait" .= (mode == "queued-sender-close")
                    , "blind_close_does_not_prove_no_go" .= (mode == "queued-sender-close")
                    , "closure_waited_for_manager_reply" .= (mode /= "queued-sender-close")
                    , "workspace_absent" .= True
                    , "provenance_retained_exactly" .= True
                    , "qualified_method_processing_witness" .= True
                    , "qualified_physical_retirement_observation" .= True
                    , "production_causal_closure_capability" .= False
                    ]
        )
  either throwIO pure (observed :: Either SomeException ())

runBus :: BusAction value -> IO (Either BusError value)
runBus = runExceptT

timerExpiry :: BusConnection -> HostOperationIntent -> IO Word64
timerExpiry connection intent =
  right
    =<< runBus
      ( do
          path <-
            callManager
              connection
              GetUnit
              (\message -> appendString message (hostOperationUnitName intent OperationTimer))
              (`readString` 'o')
          callManager
            connection
            (ReadUnitProperty path)
            ( \message ->
                appendString message "org.freedesktop.systemd1.Timer"
                  >> appendString message "NextElapseUSecMonotonic"
            )
            readVariantWord64
      )

verifyWireLimits :: BusConnection -> HostOperationIntent -> H.HostExecutionTransportPlan -> IO ()
verifyWireLimits connection intent plan =
  right
    =<< runBus
      ( do
          mapM_
            verify
            [
              ( OperationController
              , "Service"
              , H.hostExecutionParentMemoryBytes plan
              , H.hostExecutionParentTasks plan
              , H.hostExecutionParentCpuUsecPerSec plan
              )
            ,
              ( OperationSlice
              , "Slice"
              , H.hostExecutionSliceMemoryBytes plan
              , H.hostExecutionSliceTasks plan
              , H.hostExecutionSliceCpuUsecPerSec plan
              )
            ,
              ( OperationExpiry
              , "Service"
              , H.hostExecutionHelperMemoryBytes plan
              , H.hostExecutionHelperTasks plan
              , H.hostExecutionHelperCpuUsecPerSec plan
              )
            ]
          helper <- unit OperationExpiry
          property helper "Service" "ExecStart" readVariantDormantNoOp
          property helper "Service" "ExecStop" readVariantNoExecStop
          property helper "Service" "ExecStopPost" readVariantNoExecStop
          mapM_
            ( \name -> do
                actual <- property helper "Service" name readVariantWord64
                unless (actual == 20000) (fail "helper activation/stop bound changed")
            )
            ["TimeoutStartUSec", "TimeoutStopUSec"]
          controller <- unit OperationController
          directory <- property controller "Service" "RuntimeDirectory" readVariantSingleString
          mode <- property controller "Service" "RuntimeDirectoryMode" readVariantWord32
          preserve <- property controller "Service" "RuntimeDirectoryPreserve" readVariantString
          unless
            (directory == hostOperationRuntimeDirectory intent && mode == 0o700 && preserve == "no")
            (fail "operation workspace ownership changed")
      )
 where
  unit role =
    callManager
      connection
      GetUnit
      (\message -> appendString message (hostOperationUnitName intent role))
      (`readString` 'o')
  property path interface name = callManager connection (ReadUnitProperty path) $ \message -> do
    appendString message ("org.freedesktop.systemd1." <> interface)
    appendString message name
  verify (role, interface, memory, tasks, cpu) = do
    path <- unit role
    mapM_
      ( \(name, expected) -> do
          actual <- property path interface name readVariantWord64
          unless (actual == expected) (fail ("kernel wire resource mismatch: " <> name))
      )
      [("MemoryMax", memory), ("MemorySwapMax", 0), ("TasksMax", tasks), ("CPUQuotaPerSecUSec", cpu)]

waitUntil :: Word64 -> IO Bool -> IO ()
waitUntil ending observation = do
  now <- getMonotonicTimeNSec
  unless (now < ending) (fail "original native observation bound expired")
  ready <- observation
  unless ready (threadDelay 1000 >> waitUntil ending observation)

waitFile :: Word64 -> FilePath -> IO ()
waitFile ending path = waitUntil ending (doesFileExist path)

hex :: Word8 -> String
hex byte =
  [ "0123456789abcdef" !! fromIntegral (byte `div` 16)
  , "0123456789abcdef" !! fromIntegral (byte `mod` 16)
  ]

parentModes :: [String]
parentModes =
  [ "parent"
  , "parent-escape"
  , "parent-wrong-key"
  , "parent-wrong-window"
  , "parent-wrong-resources"
  , "parent-wrong-heap"
  ]

roleModes :: [String]
roleModes =
  [ "roles"
  , "roles-busy"
  , "roles-escape"
  , "roles-expiry"
  , "roles-parent-death"
  , "roles-repeat"
  , "roles-unsettled"
  , "roles-wrong-child"
  ]

-- These children run an actual bounded pre-exec gate and fixed sleep command.
-- They model the two physical roles, not an authenticated network transport.
data RoleChild = RoleChild !ProcessID !Fd !Fd !(IORef (Maybe ProcessStatus))

roleChildFd :: RoleChild -> Fd
roleChildFd (RoleChild _ descriptor _ _) = descriptor

withRoleChild :: String -> I.HostExecutionWindow -> (RoleChild -> IO value) -> IO value
withRoleChild mode window = bracket acquire release
 where
  acquire = do
    owner <- Process.getProcessID
    (reader, writer) <- createPipe
    mapM_ (\fd -> setFdOption fd CloseOnExec True) [reader, writer]
    setFdOption reader NonBlockingRead True
    pid <- Process.forkProcess $ do
      closeFd writer
      configured <- setParentDeathSignal 1 9 0 0 0
      actual <- Process.getParentProcessID
      unless (configured == 0 && actual == owner) (Process.exitImmediately (ExitFailure 125))
      let gate = do
            now <- getMonotonicTimeNSec
            unless (now < I.hostExecutionWorkEnd window) (Process.exitImmediately (ExitFailure 125))
            readResult <- try (Posix.fdRead reader 1)
            case readResult of
              Right "G" -> pure ()
              Left cause | fmap Errno (ioe_errno cause) == Just eAGAIN -> threadDelay 1000 >> gate
              _ -> Process.exitImmediately (ExitFailure 125)
      gate
      closeFd reader
      beforeExec <- getMonotonicTimeNSec
      unless (beforeExec < I.hostExecutionWorkEnd window) (Process.exitImmediately (ExitFailure 125))
      if mode `elem` ["roles-expiry", "roles-parent-death"]
        then Process.executeFile "/bin/sh" False ["-c", "/usr/bin/setsid /bin/sleep 10 & wait"] (Just [])
        else Process.executeFile "/bin/sleep" False ["10"] (Just [])
    closeFd reader
    descriptor <- throwErrnoIfMinus1Retry "fixture role pidfd" (openRolePidfd (fromIntegral pid) 0)
    status <- newIORef Nothing
    pure (RoleChild pid (Fd descriptor) writer status)
  release child@(RoleChild _ (Fd descriptor) writer _) = do
    void (signalRolePidfd descriptor 9 nullPtr 0)
    awaitRoleChild (I.hostExecutionStopEnd window) child
    closeFd writer
    closeFd (Fd descriptor)

awaitRoleChild :: Word64 -> RoleChild -> IO ()
awaitRoleChild ending child@(RoleChild pid _ _ state) = do
  known <- readIORef state
  case known of
    Just _ -> pure ()
    Nothing -> do
      observed <- Process.getProcessStatus False False pid
      case observed of
        Just status -> writeIORef state (Just status)
        Nothing -> do
          now <- getMonotonicTimeNSec
          unless (now < ending) (fail "role leader did not retire before original stop end")
          threadDelay 1000
          awaitRoleChild ending child

startRoleChild :: String -> I.HostExecutionWindow -> RoleChild -> IO ()
startRoleChild mode window (RoleChild pid _ writer _) = do
  count <- fdWrite writer "G"
  unless (count == 1) (fail "role fixture Go write failed")
  waitUntil (I.hostExecutionWorkEnd window) $
    (== (if mode `elem` ["roles-expiry", "roles-parent-death"] then "sh\n" else "sleep\n"))
      <$> readFile ("/proc/" <> show pid <> "/comm")

stopRoleScope
  :: I.HostExecutionWindow -> RoleChild -> Kernel.KernelScope -> IO (Either Kernel.KernelScopeError ())
stopRoleScope window child scope = do
  killed <- Kernel.killKernelScope scope
  case killed of
    Left cause -> pure (Left cause)
    Right () -> do
      awaitRoleChild (I.hostExecutionStopEnd window) child
      empty <- Kernel.observeKernelScopeEmptyBefore (I.hostExecutionStopEnd window) scope
      pure $ case empty of
        Right True -> Right ()
        Right False -> Left Kernel.KernelHostFamilyPresent
        Left cause -> Left cause

withFixtureRole
  :: String
  -> FilePath
  -> I.HostExecutionWindow
  -> Kernel.OperationParent
  -> HostOperationProcessRole
  -> ( Kernel.OperationProcessUse
       -> RoleChild
       -> Kernel.KernelScope
       -> IO (Either Kernel.KernelScopeError value)
     )
  -> IO (Either Kernel.KernelScopeError value)
withFixtureRole mode directory window parent role action = do
  traceRole directory (show role <> " slot")
  result <- Kernel.withOperationProcessSlot parent role $ \token ->
    withRoleChild mode window $ \child -> do
      traceRole directory (show role <> " admission")
      Kernel.withOperationProcessScope token (roleChildFd child) $ \scope -> do
        traceRole directory (show role <> " admitted")
        guarded <- Kernel.verifyOperationProcessBeforeEffect token scope
        case guarded of
          Left cause -> pure (Left cause)
          Right () -> do
            startRoleChild mode window child
            when (mode `elem` ["roles-expiry", "roles-parent-death"]) $
              observeEscapedRoleDescendant directory window role child scope
            traceRole directory (show role <> " exec-observed")
            action token child scope
  traceRole directory (show role <> " result " <> show (either Just (const Nothing) result))
  pure result

traceRole :: FilePath -> String -> IO ()
traceRole directory message = do
  now <- getMonotonicTimeNSec
  appendFile (directory </> "role-stages") (show now <> " " <> message <> "\n")

exerciseOperationRoles
  :: String
  -> FilePath
  -> I.HostExecutionWindow
  -> Kernel.OperationParent
  -> IO (Either Kernel.KernelScopeError ())
exerciseOperationRoles mode directory window parent
  | mode == "roles-wrong-child" = do
      pid <- Process.getProcessID
      descriptor <- throwErrnoIfMinus1Retry "fixture self pidfd" (openRolePidfd (fromIntegral pid) 0)
      bracket (pure (Fd descriptor)) closeFd $ \self ->
        Kernel.withOperationProcessSlot parent OperationCommandProcess $ \token -> do
          refused <-
            Kernel.withOperationProcessScope
              token
              self
              (const (unexpectedRoleCallback "self PIDFD entered role callback"))
          unless
            (refused == Left Kernel.KernelScopeChildRefused)
            (fail ("self PIDFD admission mismatch: " <> show refused))
          repeated <-
            Kernel.withOperationProcessScope
              token
              self
              (const (unexpectedRoleCallback "repeated admission entered callback"))
          unless
            (repeated == Left Kernel.KernelHostRoleAlreadyAttempted)
            (fail "failed borrow admitted another create")
          pure (Right ())
  | mode == "roles-unsettled" = do
      result <-
        withFixtureRole mode directory window parent OperationCommandProcess (\_ _ _ -> pure (Right ()))
      unless
        (result == Left (Kernel.KernelHostRoleUnsettled OperationCommandProcess))
        (fail ("live role settlement mismatch: " <> show result))
      refused <-
        Kernel.withOperationProcessSlot
          parent
          OperationCommandProcess
          (const (unexpectedRoleCallback "unsettled role was reused"))
      unless
        (refused == Left (Kernel.KernelHostRoleUnsettled OperationCommandProcess))
        (fail ("unsettled borrow mismatch: " <> show refused))
      writeFile (directory </> "unsettled-role-refused") (show result)
      pure (Right ())
  | otherwise = do
      escapedUse <- newIORef Nothing
      escapedScope <- newIORef Nothing
      result <- withFixtureRole mode directory window parent OperationTransportProcess $ \transport transportChild transportScope -> do
        when (mode == "roles-busy") (assertBusy OperationTransportProcess)
        let command = withFixtureRole mode directory window parent OperationCommandProcess $ \token child scope -> do
              writeIORef escapedUse (Just token)
              writeIORef escapedScope (Just scope)
              both <- Kernel.verifyOperationProcessBeforeEffect transport transportScope
              case both of
                Left cause -> pure (Left cause)
                Right () -> do
                  when (mode == "roles-busy") (assertBusy OperationCommandProcess)
                  when (mode == "roles-repeat") $ do
                    refused <-
                      Kernel.withOperationProcessScope
                        token
                        (roleChildFd child)
                        (const (unexpectedRoleCallback "repeated create entered callback"))
                    unless (refused == Left Kernel.KernelHostRoleAlreadyAttempted) (fail "one borrow created twice")
                  when (mode `elem` ["roles-expiry", "roles-parent-death"]) $ do
                    writeFile
                      (directory </> "roles-overlap")
                      "both role scopes have exec'd leaders and session-escaped descendants"
                    writeFile (directory </> "started") (Kernel.operationParentRuntimeDirectory parent)
                    if mode == "roles-parent-death"
                      then
                        waitFile (I.hostExecutionWorkEnd window) (directory </> "held")
                          >> Process.exitImmediately (ExitFailure 77)
                      else threadDelay 10000000
                  stopped <- stopRoleScope window child scope
                  traceRole directory ("command-terminal " <> show stopped)
                  pure stopped
        first <- command
        case first of
          Left cause -> pure (Left cause)
          Right () -> do
            second <- command
            case second of
              Left cause -> pure (Left cause)
              Right () -> do
                writeFile (directory </> "roles-overlap") "two serial commands while transport remains admitted"
                stopRoleScope window transportChild transportScope
      when (mode == "roles-escape") $ do
        token <- readIORef escapedUse >>= maybe (fail "missing escaped role use") pure
        scope <- readIORef escapedScope >>= maybe (fail "missing escaped role scope") pure
        refused <- Kernel.withOperationProcessScope token (Fd (-1)) (const (pure (Right ())))
        unless (refused == Left Kernel.KernelHostPlacementClosed) (fail "escaped role use remained open")
        closed <- Kernel.kernelScopeEmpty scope
        unless
          (closed == Left Kernel.KernelScopeHandleClosed)
          (fail "escaped kernel role scope remained open")
      pure result
 where
  assertBusy role = do
    refused <- Kernel.withOperationProcessSlot parent role (const (pure (Right ())))
    unless (refused == Left Kernel.KernelHostPlacementBusy) (fail "overlapping role borrow admitted")

waitForRetiredGroup :: Word64 -> OpenFileFlags -> Fd -> IO ()
waitForRetiredGroup ending flags held = waitUntil ending $ do
  target <- readSymbolicLink ("/proc/self/fd/" <> show held)
  gone <-
    try (bracket (openFdAt (Just held) "cgroup.events" ReadOnly flags) closeFd (const (pure ())))
      :: IO (Either IOException ())
  pure (" (deleted)" `isSuffixOf` target && either isDoesNotExistError (const False) gone)

unexpectedRoleCallback :: String -> IO (Either Kernel.KernelScopeError ())
unexpectedRoleCallback = fail

observeEscapedRoleDescendant
  :: FilePath
  -> I.HostExecutionWindow
  -> HostOperationProcessRole
  -> RoleChild
  -> Kernel.KernelScope
  -> IO ()
observeEscapedRoleDescendant directory window role (RoleChild leader _ _ _) scope =
  waitUntil (I.hostExecutionWorkEnd window) $ do
    let group = Kernel.kernelScopeControlGroup scope
    members <- words <$> readFile ("/sys/fs/cgroup" <> group <> "/cgroup.procs")
    pids <- maybe (fail "malformed role cgroup PID") pure (traverse readMaybe members :: Maybe [CInt])
    escaped <- mapM (observe group) (filter (/= fromIntegral leader) pids)
    case [value | Just value <- escaped] of
      [] -> pure False
      (pid, sid) : _ -> do
        Lazy.appendFile
          (directory </> "role-session-observations.jsonl")
          ( encode
              ( object
                  [ "role" .= show role
                  , "leader_pid" .= toInteger leader
                  , "descendant_pid" .= toInteger pid
                  , "session_id" .= toInteger sid
                  , "control_group" .= group
                  ]
              )
              <> "\n"
          )
        pure True
 where
  observe group pid = do
    sid <- roleSessionId pid
    if sid /= pid || pid <= 0
      then pure Nothing
      else do
        membership <- readFile ("/proc/" <> show pid <> "/cgroup")
        closing <- roleSessionId pid
        pure (if membership == "0::" <> group <> "\n" && closing == sid then Just (pid, sid) else Nothing)

supervisorModes :: [String]
supervisorModes =
  [ "supervisor-capture"
  , "supervisor-stdout"
  , "supervisor-stderr"
  , "supervisor-exec"
  , "supervisor-nul"
  , "supervisor-environment"
  , "supervisor-transport-exit"
  , "supervisor-transport-overflow"
  , "supervisor-cancel"
  , "supervisor-deadline"
  , "supervisor-budgets"
  , "supervisor-escape"
  , "supervisor-descendants"
  , "supervisor-fragmented"
  ]

exerciseOperationSupervisor
  :: String
  -> FilePath
  -> I.HostExecutionWindow
  -> Kernel.OperationParent
  -> IO (Either Kernel.KernelScopeError ())
exerciseOperationSupervisor mode directory window parent = do
  let limits out err = right (Supervisor.mkOperationStreamLimits out err 10000)
      child path args = Supervisor.Subprocess path args (Just []) (Just (Kernel.operationParentRuntimeDirectory parent))
      shell code = child "/bin/sh" ["-c", code]
      sleep = child "/bin/sleep" ["10"]
      logResult label result = do
        traceRole directory (label <> " " <> either show (const "Right") result)
        writeFile (directory </> "supervisor-result") (label <> " " <> either show (const "Right") result)
      check condition label = unless condition $ do
        writeFile (directory </> "supervisor-assertion") label
        fail label
      expectSuccess label result = do
        logResult label result
        either (fail . (label <>) . show) pure result
      expectOwned label expected result = do
        logResult label result
        check
          (either (hasPrimaryOwned expected) (const False) result)
          (label <> " missing expected primary refusal")
      capture owned spec = Supervisor.captureOperationCommand owned spec
      clean = do
        result <- Kernel.verifyOperationParentBeforeEffect parent
        check (result == Right ()) ("parent did not re-admit after cleanup: " <> show result)
      successOutput output bytes = do
        check
          (Supervisor.operationProcessExitCode output == ExitSuccess)
          "capture did not exit successfully"
        check (Supervisor.operationProcessStdout output == bytes) "capture bytes mismatch"
  commandLimits <-
    limits
      (if mode == "supervisor-stdout" then 32 else 4096)
      (if mode == "supervisor-stderr" then 32 else 4096)
  transportLimits <- limits 4096 (if mode == "supervisor-transport-overflow" then 32 else 4096)
  owned <- right (Supervisor.operationSubprocesses parent commandLimits transportLimits)
  case mode of
    "supervisor-capture" -> do
      result <- Supervisor.withOperationTransport owned sleep $ \transport -> do
        guard <- Supervisor.verifyOperationTransportBeforeEffect transport
        check (guard == Right ()) ("active transport verification failed: " <> show guard)
        first <-
          capture
            owned
            ( Supervisor.Subprocess
                "/bin/sh"
                ["-c", "printf '%s' \"$FIXTURE_VALUE\"; printf 'err' >&2; exit 7"]
                (Just [("FIXTURE_VALUE", "héllo"), ("LANG", "C.UTF-8")])
                (Just (Kernel.operationParentRuntimeDirectory parent))
            )
            >>= expectSuccess "capture-UTF8"
        check (Supervisor.operationProcessExitCode first == ExitFailure 7) "nonzero command exit changed"
        check (Supervisor.operationProcessStdout first == Text.encodeUtf8 "héllo") "UTF8 bytes changed"
        check (Supervisor.operationProcessStderr first == "err") "stderr bytes changed"
        second <- capture owned (child "/bin/printf" ["%s", "λ"]) >>= expectSuccess "second-command"
        successOutput second (Text.encodeUtf8 "λ")
        currentDirectory <- capture owned (child "/bin/pwd" []) >>= expectSuccess "working-directory"
        successOutput
          currentDirectory
          (Text.encodeUtf8 (TextValue.pack (Kernel.operationParentRuntimeDirectory parent <> "\n")))
      _ <- expectSuccess "transport-callback" result
      clean
    "supervisor-stdout" -> do
      result <- capture owned (shell "while :; do printf 0123456789; done")
      expectOwned "stdout-overflow" Supervisor.OwnedSubprocessStdoutExceeded result
      clean
      next <- capture owned (child "/bin/true" []) >>= expectSuccess "reuse-after-stdout"
      successOutput next ""
    "supervisor-stderr" -> do
      result <- capture owned (shell "while :; do printf 0123456789 >&2; done")
      expectOwned "stderr-overflow" Supervisor.OwnedSubprocessStderrExceeded result
      clean
    "supervisor-exec" -> do
      result <- capture owned (child "/prodbox-fixture-missing-executable" [])
      expectOwned "exec-refusal" Supervisor.OwnedSubprocessStartFailed result
      clean
    "supervisor-nul" -> do
      result <- capture owned (child "/bin/printf" ["bad\0argument"])
      expectOwned "NUL-refusal" Supervisor.OwnedSubprocessStartFailed result
      clean
    "supervisor-environment" -> do
      result <- capture owned (Supervisor.Subprocess "/bin/true" [] Nothing Nothing)
      expectOwned "ambient-environment-refusal" Supervisor.OwnedSubprocessStartFailed result
      clean
    "supervisor-transport-exit" -> do
      result <- Supervisor.withOperationTransport owned (child "/bin/true" []) $ \_ ->
        threadDelay 1000000 >> writeFile (directory </> "late-transport-effect") "must not run"
      logResult "transport-exit" result
      check
        (result == Left (Supervisor.OperationTransportExited ExitSuccess))
        "early transport exit was not preserved"
      late <- doesFileExist (directory </> "late-transport-effect")
      check (not late) "callback survived exited transport"
      clean
    "supervisor-transport-overflow" -> do
      result <- Supervisor.withOperationTransport owned (shell "while :; do printf 0123456789 >&2; done") $ \_ ->
        threadDelay 1000000 >> writeFile (directory </> "late-transport-effect") "must not run"
      expectOwned "transport-stderr-overflow" Supervisor.OwnedSubprocessStderrExceeded result
      late <- doesFileExist (directory </> "late-transport-effect")
      check (not late) "callback survived transport overflow"
      clean
    "supervisor-cancel" -> do
      let marker = directory </> "cancel-command-started"
          blocking =
            Supervisor.Subprocess
              "/bin/sh"
              ["-c", "printf started > \"$FIXTURE_CANCEL\"; exec /bin/sleep 10"]
              (Just [("FIXTURE_CANCEL", marker)])
              Nothing
      Async.withAsync (Supervisor.withOperationTransport owned sleep (\_ -> capture owned blocking)) $ \job -> do
        waitFile (I.hostExecutionWorkEnd window) marker
        traceRole directory "cancel-both-roles"
        Async.cancel job
        stopped <- Async.waitCatch job
        check
          ( either
              (isJust . (fromException :: SomeException -> Maybe Async.AsyncCancelled))
              (const False)
              stopped
          )
          "cancellation was not rethrown after cleanup"
      clean
      next <- capture owned (child "/bin/true" []) >>= expectSuccess "reuse-after-cancel"
      successOutput next ""
    "supervisor-deadline" -> do
      now <- getMonotonicTimeNSec
      result <- Supervisor.captureOperationCommandBefore (now + 350000000) owned sleep
      expectOwned "tightened-work-deadline" Supervisor.OwnedSubprocessDeadlineReached result
      clean
      next <- capture owned (child "/bin/true" []) >>= expectSuccess "reuse-after-tight-deadline"
      successOutput next ""
    "supervisor-budgets" -> do
      huge <- limits 1048576 1048576
      excessiveGrace <- right (Supervisor.mkOperationStreamLimits 32 32 1000000)
      check
        ( case Supervisor.operationSubprocesses parent huge transportLimits of
            Left Supervisor.OwnedSubprocessInvalidLimits -> True
            _ -> False
        )
        "buffer reserve was over-admitted"
      check
        ( case Supervisor.operationSubprocesses parent excessiveGrace transportLimits of
            Left Supervisor.OwnedSubprocessInvalidLimits -> True
            _ -> False
        )
        "original grace reserve was over-admitted"
      exact <- limits 32 32
      bounded <- right (Supervisor.operationSubprocesses parent exact transportLimits)
      result <-
        capture bounded (child "/bin/printf" ["%s", replicate 32 'x'])
          >>= expectSuccess "exact-output-bound"
      successOutput result (BS.replicate 32 120)
      overflow <- capture bounded (child "/bin/printf" ["%s", replicate 33 'x'])
      expectOwned "one-byte-over-bound" Supervisor.OwnedSubprocessStdoutExceeded overflow
      clean
    "supervisor-escape" -> do
      held <- newIORef Nothing
      result <- Supervisor.withOperationTransport owned sleep $ \lease -> do
        writeIORef held (Just lease)
        check
          (Supervisor.operationTransportWorkEnd lease == I.hostExecutionWorkEnd window)
          "transport renewed original work end"
        before <- Supervisor.verifyOperationTransportBeforeEffect lease
        check (before == Right ()) "active lease refused"
      _ <- expectSuccess "escape-transport" result
      lease <- readIORef held >>= maybe (fail "missing escaped transport") pure
      refused <- Supervisor.verifyOperationTransportBeforeEffect lease
      check
        (refused == Left (Supervisor.OperationScopeRefused Kernel.KernelHostPlacementClosed))
        "escaped transport lease stayed usable"
      clean
    "supervisor-fragmented" -> do
      exact <- limits 2 1
      bounded <- right (Supervisor.operationSubprocesses parent exact transportLimits)
      result <-
        capture bounded (shell "printf '\\303'; /bin/sleep 0.05; printf '\\251'")
          >>= expectSuccess "fragmented-UTF8"
      successOutput result (Text.encodeUtf8 "é")
      clean
    "supervisor-descendants" -> do
      let marker = directory </> "descendant-started"
          script =
            "/usr/bin/setsid /bin/sh -c 'printf started > \"$FIXTURE_MARKER\"; exec /bin/sleep 10' & while [ ! -s \"$FIXTURE_MARKER\" ]; do :; done; printf done; exit 0"
          spec = Supervisor.Subprocess "/bin/sh" ["-c", script] (Just [("FIXTURE_MARKER", marker)]) Nothing
      result <- capture owned spec >>= expectSuccess "descendant-and-held-writers"
      successOutput result "done"
      clean
    _ -> fail "unreachable supervisor fixture mode"
  writeFile (directory </> "supervisor-validated") mode
  pure (Right ())

hasPrimaryOwned :: Supervisor.OwnedSubprocessError -> Supervisor.OperationSubprocessError -> Bool
hasPrimaryOwned expected cause = case cause of
  Supervisor.OperationProcessRefused value -> value == expected
  Supervisor.OperationPrimaryAndCleanupRefused primary _ -> hasPrimaryOwned expected primary
  Supervisor.OperationScopeRefused _ -> False
  Supervisor.OperationTransportExited _ -> False

verifyExpiredOperationPresence :: HostOperationInventory -> HostOperationRole -> IO ()
verifyExpiredOperationPresence unobservable role = case hostOperationPresence unobservable role of
  HostOperationUnobservable (BusDeadlineReached _) -> pure ()
  other -> fail ("expired observation lost its cause: " <> show other)

verifyPostSenderPresence :: HostOperationInventory -> HostOperationRole -> IO ()
verifyPostSenderPresence inventory role = case hostOperationPresence inventory role of
  HostOperationUnobservable _ -> fail "post-sender field was unobservable"
  HostOperationAbsent -> pure ()
  HostOperationPresent _ -> pure ()
