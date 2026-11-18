{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- A local manager fixture, not a lifecycle admission or cluster acceptance.
-- It preserves its scratch root on every incomplete observation.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (AsyncCancelled, cancel, waitCatch, withAsync)
import Control.Exception
  ( IOException
  , SomeException
  , bracket
  , catch
  , finally
  , fromException
  , throwIO
  , try
  )
import Control.Monad (unless, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (runExceptT)
import Data.Bits ((.|.))
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Chars
import Data.ByteString.Lazy qualified as LazyBytes
import Data.Either (isLeft)
import Data.List (isInfixOf, isPrefixOf, stripPrefix)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
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
import Prodbox.Capacity.ObservedHost qualified as Observed
import Prodbox.Capacity.RuntimeMemory qualified as Runtime
import Prodbox.Config.BootstrapProjection
  ( ArtifactDeclaration (artifactDigest)
  , bootstrapKindPlan
  , bootstrapKindTool
  , readBootstrapProjection
  )
import Prodbox.Config.DeploymentScope
  ( DeploymentEnvironment (Test)
  , FreshScopeResult (FreshScopePrepared)
  , deploymentScope
  , prepareFreshScope
  , scopeRoot
  )
import Prodbox.Config.KindPlan (renderKindConfig)
import Prodbox.Control.KindIntent (KindIntentObservation (..), observeKindIntent)
import Prodbox.Control.KindLease
import Prodbox.Control.KindTool
import Prodbox.Control.SealedTool
import Prodbox.Subprocess qualified as Subprocess
import Prodbox.Subprocess.SystemdBus
import System.Directory
  ( canonicalizePath
  , copyFile
  , createDirectory
  , doesFileExist
  , findExecutable
  , removePathForcibly
  )
import System.Environment (getArgs, getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Error (isDoesNotExistError, tryIOError)
import System.IO.Temp (createTempDirectory)
import System.Posix.Files
  ( createNamedPipe
  , fileSize
  , getFdStatus
  , getSymbolicLinkStatus
  , setFileMode
  )
import System.Posix.IO qualified as Posix
import System.Posix.Types (Fd (..))
import System.Posix.User (getEffectiveUserID)
import System.Process (readProcessWithExitCode)
import Text.Read (readMaybe)

foreign import capi "fcntl.h value O_PATH" fixturePathOnly :: CInt
foreign import capi "fcntl.h value O_NOFOLLOW" fixtureNoFollow :: CInt
foreign import capi "fcntl.h value O_CLOEXEC" fixtureCloseOnExec :: CInt
foreign import capi "fcntl.h open" fixtureOpenPath :: CString -> CInt -> IO CInt

right :: (Show failure) => Either failure value -> IO value
right = either (fail . show) pure

main :: IO ()
main = do
  args <- getArgs
  case args of
    [] -> launch ".build/prodbox"
    ["--operator", path] -> launch path
    ["controller", root, selected, version, clientPath, clientDigest, outer, work, hard, stop, finish] -> do
      values <-
        mapM (maybe (fail "invalid fixture clock") pure . readMaybe) [outer, work, hard, stop, finish]
      case values of
        [a, b, c, d, e] -> do
          outcome <- try (controller root selected version clientPath clientDigest a b c d e)
          case outcome of
            Left (failure :: SomeException) -> do
              existing <- doesFileExist (root </> "result")
              unless existing (writeFile (root </> "result") ("FAIL: " <> show failure <> "\n"))
              fail "fixture controller failed; result retained"
            Right () -> pure ()
        _ -> fail "invalid fixture clock count"
    _ -> fail "invalid kind placement fixture arguments"

fixture :: FilePath -> IO (Host.HostExecutionPlan, KindWorkerSnapshots, Observed.ObservedHostRoot)
fixture retainedRoot = do
  let mib = 1048576
      base = Capacity.defaultResourcePlan
      source =
        base
          { Capacity.host_capacity = Capacity.ResourceVector 2000 4096 8192 8192
          , Capacity.rke2_reserved = Capacity.ResourceVector 100 128 256 1
          , Capacity.eviction_floor = Capacity.ResourceVector 100 128 256 1
          , Capacity.platform_scheduler_requests = Just (Capacity.ResourceVector 0 0 0 0)
          , Capacity.workload_profiles =
              filter ((== "redis") . Capacity.profile_id) (Capacity.workload_profiles base)
          }
      bytes term count = either (error . show) id (Runtime.mkPositiveBytes term (count * mib))
  allocated <- right (Allocation.compileResourcePlanUncertified source)
  now <- getMonotonicTimeNSec
  observed <- right =<< observeNativeHostCapacityBefore (now + 2000000000) retainedRoot
  runtime <-
    right $
      Runtime.validateRuntimeMemoryPlan
        Runtime.RuntimeMemoryInputs
          { Runtime.runtimeBoundedApplicationState = bytes Runtime.BoundedApplicationState 1
          , Runtime.runtimeBoundedPendingPersistenceState = bytes Runtime.BoundedPendingPersistenceState 1
          , Runtime.runtimeInHeapTransportDecodeScratch = bytes Runtime.InHeapTransportDecodeScratch 2
          , Runtime.runtimeOtherHeapReserve = bytes Runtime.OtherHeapReserve 2
          , Runtime.runtimeHeapCap = bytes Runtime.HeapCap 16
          , Runtime.runtimeNativeNonHeapReserve = bytes Runtime.NativeNonHeapReserve 4
          , Runtime.runtimeRawChildSchedule = Runtime.BoundedChildSchedule 1 (Just 30000000) [80 * mib]
          , Runtime.runtimeKernelCgroupReserve = bytes Runtime.KernelCgroupReserve 4
          , Runtime.runtimeSafetyMargin = bytes Runtime.SafetyMargin 4
          , Runtime.runtimeContainerMemoryLimit = bytes Runtime.ContainerMemoryLimit 512
          }
  budgets <-
    right
      ( planKindWorkerSnapshots
          runtime
          (128 * 1024 * 1024)
          (2 * 1024 * 1024)
          (256 * 1024 * 1024)
          (2 * 1024 * 1024)
          65536
          65536
      )
  let budget = kindWorkerKindBudget budgets
  plan <-
    right $
      Host.compileHostExecutionPlan
        observed
        allocated
        (sealedToolRuntimePlan budget)
        (Host.HostExecutionDemand 100000 500000 100000 16 16 8 (64 * mib) (16 * mib) 1 0)
  let observedVector = Observed.observedHostVector observed
  tooSmall <-
    right $
      Observed.mkObservedHostRoot
        (observedVector {Capacity.memory_mib = 4095})
        (Observed.observedEphemeralDevice observed)
        (Observed.observedDurableDevice observed)
  let demand = Host.HostExecutionDemand 100000 500000 100000 16 16 8 (64 * mib) (16 * mib) 1 0
  unless
    (isLeft (Host.compileHostExecutionPlan tooSmall allocated (sealedToolRuntimePlan budget) demand))
    $ fail "insufficient observed host capacity was accepted"
  pure (plan, budgets, observed)

key :: Subprocess.HostExecutionKey
key = maybe (error "invalid fixture key") id (Subprocess.hostExecutionKeyFromText (replicate 64 'c'))

launch :: FilePath -> IO ()
launch operator = do
  clientPath <- canonicalizePath operator
  (hashExit, hashOutput, _) <- readProcessWithExitCode "/usr/bin/sha256sum" [clientPath] ""
  let hash = take 64 hashOutput
      hex character = character `elem` ("0123456789abcdef" :: String)
  unless
    (hashExit == ExitSuccess && length hash == 64 && all hex hash && take 2 (drop 64 hashOutput) == "  ")
    $ fail "operator digest unavailable"
  let clientDigest = "sha256:" <> hash
  installed <- findExecutable "kind" >>= maybe (fail "kind prerequisite unavailable") pure
  (exit, output, _) <- readProcessWithExitCode installed ["version"] ""
  version <- case (exit, lines output) of
    (ExitSuccess, [line]) -> pure line
    _ -> fail "kind version unavailable"
  root <- createTempDirectory "/tmp" "prodbox-kind-host-placement-"
  putStrLn ("Fixture root: " <> root)
  setFileMode root 0o700
  createDirectory (root </> ".test-data")
  scope <- right (deploymentScope root Test "placement" 26443)
  prepared <- prepareFreshScope scope (replicate 32 'a')
  unless (prepared == FreshScopePrepared) (fail ("fixture root preparation: " <> show prepared))
  createDirectory (scopeRoot scope </> "artifacts")
  let target = scopeRoot scope </> "artifacts" </> "kind"
      selected = root </> "selected.dhall"
  copyFile installed target
  setFileMode target 0o700
  digest <- Chars.unpack . hexSha256 <$> Bytes.readFile target
  writeFile selected $
    "{ bootstrap = { schema_version = 3, project_anchor = "
      <> show root
      <> ", runtime_socket = \"/var/run/docker.sock\", environment = \"test\", deployment_id = \"placement\", root_generation = \""
      <> replicate 32 'a'
      <> "\", api_port = 26443, node_image = \"kindest/node@sha256:"
      <> replicate 64 '0'
      <> "\", node_artifact = { path = \"artifacts/node.tar\", digest = \"sha256:"
      <> replicate 64 '0'
      <> "\", maximum_bytes = 4096 }, kind_tool = { path = \"artifacts/kind\", digest = \"sha256:"
      <> digest
      <> "\", maximum_bytes = 134217728 }, http_host_port = 28080, http_node_port = 30080, https_host_port = 28443, https_node_port = 30443, listen_address = \"127.0.0.1\" } }"
  (plan, _, observed) <- fixture (scopeRoot scope)
  writeFile (root </> "host-observation") (show observed)
  putStrLn ("Host geometry: " <> show observed)
  uid <- getEffectiveUserID
  start <- getMonotonicTimeNSec
  let outer = start + 45000000000
      work = start + 20000000000
      hard = start + 22000000000
      stop = start + 25000000000
      finish = start + 28000000000
      socket = "/run/user/" <> show uid <> "/bus"
      runtimeDirectory = "/run/user/" <> show uid <> "/prodbox-kind"
      cgroup =
        "/sys/fs/cgroup/user.slice/user-"
          <> show uid
          <> ".slice/user@"
          <> show uid
          <> ".service/prodboxkind.slice"
      field = "prodbox-owned-" <> replicate 64 'c'
      names =
        [ "prodbox-kind-controller.service"
        , "prodboxkind.slice"
        , field <> ".scope"
        , field <> "-expiry.timer"
        , field <> "-expiry.service"
        ]
  window <-
    maybe
      (fail "invalid fixture window")
      pure
      (Subprocess.hostExecutionWindow outer work hard stop finish)
  clearPaths <- mapM pathAbsent [runtimeDirectory, cgroup]
  unless (and clearPaths) (fail "fixture runtime directory or cgroup is present or unobservable")
  executable <- getExecutablePath
  result <- withSystemdBus outer socket $ \connection -> lift $ do
    before <- mapM (unitAbsent connection) names
    unless (and before) (fail "fixture manager field is present or unobservable")
    submitted <-
      runExceptT $
        callManager
          connection
          StartTransientUnit
          ( request
              plan
              window
              executable
              [ "controller"
              , root
              , selected
              , version
              , clientPath
              , clientDigest
              , show outer
              , show work
              , show hard
              , show stop
              , show finish
              ]
          )
          (`readString` 'o')
    case submitted of
      Left failure -> putStrLn ("Manager submission failed: " <> show failure)
      Right _ -> putStrLn "Manager accepted fixture controller"
    absent <- waitForAbsence outer connection names [runtimeDirectory, cgroup]
    unless absent (fail "fixture cleanup incomplete; manager field or runtime directory remains")
    case submitted of
      Left failure -> fail ("fixture submission failed: " <> show failure)
      Right _ -> pure ()
  right result
  let report = root </> "result"
  exists <- doesFileExist report
  unless exists (fail "controller did not publish a result")
  contents <- readFile report
  workerPid <- case words contents of
    ["PASS", raw] -> maybe (fail "invalid settled child identity") pure (readMaybe raw :: Maybe Int)
    _ -> fail ("controller result: " <> contents)
  processGone <- pathAbsent ("/proc/" <> show workerPid)
  unless processGone (fail "interrupted child PID remains present or unobservable")
  putStrLn
    ( "PASS: interrupted child "
        <> show workerPid
        <> " absent; kind version matched; exact manager fields and runtime directory absent; fixture SHA-256 "
        <> digest
    )
  measurement <- readFile (root </> "snapshot-memory")
  putStrLn ("snapshot cgroup memory before/held: " <> measurement)
  removePathForcibly root

unitAbsent :: BusConnection -> String -> IO Bool
unitAbsent connection name = do
  result <-
    runExceptT
      (callManager connection GetUnit (\message -> appendString message name) (`readString` 'o'))
  pure $ case result of
    Left (BusMethodRefused 2) -> True
    _ -> False

pathAbsent :: FilePath -> IO Bool
pathAbsent path = do
  result <- tryIOError (getSymbolicLinkStatus path)
  pure $ case result of
    Left failure -> isDoesNotExistError failure
    Right _ -> False

withFixturePaths :: [FilePath] -> ([Fd] -> IO value) -> IO value
withFixturePaths paths action = case paths of
  [] -> action []
  path : remaining ->
    bracket
      ( withCString path $ \encoded ->
          Fd <$> throwErrnoIfMinus1 "open fixture path" (fixtureOpenPath encoded flags)
      )
      Posix.closeFd
      (\descriptor -> withFixturePaths remaining (action . (descriptor :)))
 where
  flags = fixturePathOnly .|. fixtureNoFollow .|. fixtureCloseOnExec

runConfinedKindFixture
  :: Subprocess.KindHostSubprocessPlacement
  -> KindWorkerSnapshots
  -> Fd
  -> Fd
  -> Subprocess.OwnedSubprocessLimits
  -> FilePath
  -> String
  -> IO ()
runConfinedKindFixture placement budgets kind client limits root expected = do
  let worker = root </> ".test-data" </> "placement" </> "confined-worker"
      scratch = worker </> "scratch"
      bridge = worker </> "bridge"
      lock = bridge </> "lock"
      requestPath = bridge </> "request"
      replyPath = bridge </> "reply"
  createDirectory worker
  createDirectory scratch
  createDirectory bridge
  mapM_ (`setFileMode` 0o700) [worker, scratch, bridge]
  writeFile lock ""
  setFileMode lock 0o600
  createNamedPipe requestPath 0o600
  createNamedPipe replyPath 0o600
  withFixturePaths
    [scratch, bridge, "/usr", "/etc/ld.so.cache", lock, requestPath, replyPath, "/dev/null"]
    (runWithPaths scratch bridge)
 where
  runWithPaths scratch bridge paths = case paths of
    [scratchFd, bridgeFd, usrFd, cacheFd, lockFd, requestFd, replyFd, nullFd] -> do
      sandbox <-
        maybe (fail "invalid fixture sandbox") pure $
          Subprocess.mkKindWorkerSandbox scratchFd [bridgeFd, usrFd, cacheFd] lockFd requestFd replyFd nullFd
      let environment =
            [ ("PATH", bridge <> ":/usr/bin:/bin")
            , ("HOME", scratch)
            , ("TMPDIR", scratch)
            , ("DOCKER_CONFIG", scratch)
            , ("KUBECONFIG", scratch </> "kubeconfig")
            , ("KIND_EXPERIMENTAL_PROVIDER", "docker")
            , ("PRODBOX_KIND_BRIDGE", bridge)
            ]
          command =
            Subprocess.Subprocess
              ("/proc/self/fd/" <> show kind)
              ["version"]
              (Just environment)
              (Just scratch)
          unsafeCommand = command {Subprocess.subprocessEnvironment = Just (("AWS_PROFILE", "forbidden") : environment)}
          escapedEnvironment =
            [ if envKey == "KUBECONFIG" then (envKey, scratch </> ".." </> "foreign") else (envKey, value)
            | (envKey, value) <- environment
            ]
          escapedCommand = command {Subprocess.subprocessEnvironment = Just escapedEnvironment}
          oversizedCommand = command {Subprocess.subprocessArguments = replicate 65 "x"}
      result <- Subprocess.withPreparedConfinedKindHostSubprocess placement budgets sandbox kind client limits $ \run -> do
        denied <- run Bytes.empty unsafeCommand
        unless
          (denied == Left Subprocess.OwnedSubprocessInvalidLimits)
          (fail "ambient AWS input was accepted")
        escaped <- run Bytes.empty escapedCommand
        unless
          (escaped == Left Subprocess.OwnedSubprocessInvalidLimits)
          (fail "escaping kubeconfig was accepted")
        oversized <- run Bytes.empty oversizedCommand
        unless
          (oversized == Left Subprocess.OwnedSubprocessInvalidLimits)
          (fail "oversized argv was accepted")
        run Bytes.empty command
      case result of
        Right output
          | Subprocess.processExitCode output == ExitSuccess
              && lines (Subprocess.processStdout output) == [expected] ->
              pure ()
        other -> fail ("confined kind version failed: " <> show other)
    _ -> fail "invalid fixture descriptor count"

withFixtureFailure :: FilePath -> IO value -> IO value
withFixtureFailure root action =
  action `catch` \(failure :: IOException) -> do
    recorded <-
      try (writeFile (root </> "fixture-failure") (show failure <> "\n")) :: IO (Either IOException ())
    case recorded of
      Right () -> throwIO failure
      Left recordFailure ->
        ioError
          (userError ("fixture failure: " <> show failure <> "; failure record: " <> show recordFailure))

waitForAbsence :: Word64 -> BusConnection -> [String] -> [FilePath] -> IO Bool
waitForAbsence deadline connection names paths = do
  now <- getMonotonicTimeNSec
  if now >= deadline
    then pure False
    else do
      units <- mapM (unitAbsent connection) names
      absentPaths <- mapM pathAbsent paths
      if and units && and absentPaths
        then pure True
        else threadDelay 100000 >> waitForAbsence deadline connection names paths

controller
  :: FilePath
  -> FilePath
  -> String
  -> FilePath
  -> String
  -> Word64
  -> Word64
  -> Word64
  -> Word64
  -> Word64
  -> IO ()
controller root selected expected clientPath clientDigest outer work hard stop finish = do
  (plan, budgets, observed) <- fixture (root </> ".test-data" </> "placement")
  let budget = kindWorkerKindBudget budgets
      clientBudget = kindWorkerClientBudget budgets
  previous <- readFile (root </> "host-observation")
  unless (previous == show observed) (fail "host observation changed between launcher and controller")
  bootstrap <- right =<< readBootstrapProjection selected
  source <- TextIO.readFile selected
  let invalidSelected = root </> "invalid-socket.dhall"
  TextIO.writeFile
    invalidSelected
    (Text.replace "/var/run/docker.sock" "/nonexistent/prodbox.sock" source)
  invalidBootstrap <- right =<< readBootstrapProjection invalidSelected
  window <-
    maybe
      (fail "invalid controller window")
      pure
      (Subprocess.hostExecutionWindow outer work hard stop finish)
  resources <-
    right
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
    right (Subprocess.mkOwnedSubprocessLimits resources 30000000 100000 300000 100000 4096 4096)
  wrongProfile <- Subprocess.withHostSubprocessPlacement plan key window $ \_ -> pure (Right ())
  unless (isLeft wrongProfile && "KernelHostParentRefused" `isInfixOf` show wrongProfile) $
    fail ("kind controller was not refused as RPC-birth: " <> show wrongProfile)
  let operationId = replicate 32 'b'
      marker = root </> "worker-started"
      child =
        Subprocess.Subprocess
          "/bin/sh"
          [ "-c"
          , "printf '%s\\n' \"$$\" > \"$1.tmp\"; mv \"$1.tmp\" \"$1\"; exec /usr/bin/sleep 60"
          , "fixture"
          , marker
          ]
          (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")])
          Nothing
  workerPid <- withAsync
    ( withNewKindOperation bootstrap operationId $ \recheck -> do
        stable <- recheck
        unless stable (fail "intent changed before child")
        Subprocess.withKindHostSubprocessPlacement plan key window $ \placement ->
          Subprocess.withPreparedKindHostSubprocess placement (sealedToolRuntimePlan budget) limits ($ child)
    )
    $ \worker -> do
      waitForMarker work marker
      rawPid <- readFile marker
      pid <- maybe (fail "invalid child PID") pure (readMaybe rawPid :: Maybe Int)
      when (pid <= 0) (fail "invalid child PID")
      present <- tryIOError (getSymbolicLinkStatus ("/proc/" <> show pid))
      case present of
        Left _ -> fail "started child PID is absent or unobservable before interruption"
        Right _ -> pure ()
      observedIntent <- observeKindIntent bootstrap
      unless
        (observedIntent == KindIntentMatches operationId)
        (fail "intent was not durable before child")
      cancel worker
      outcome <- waitCatch worker
      case outcome of
        Left failure | Just (_ :: AsyncCancelled) <- fromException failure -> pure pid
        _ -> fail ("interruption did not settle cleanly: " <> show outcome)
  uid <- getEffectiveUserID
  let field = "prodbox-owned-" <> replicate 64 'c'
      childUnits = [field <> ".scope", field <> "-expiry.timer", field <> "-expiry.service"]
      socket = "/run/user/" <> show uid <> "/bus"
  childAbsent <- withSystemdBus finish socket $ \connection -> lift (mapM (unitAbsent connection) childUnits)
  absent <- right childAbsent
  unless (and absent) (fail "previous child family is present or unobservable")
  processGone <- pathAbsent ("/proc/" <> show workerPid)
  unless processGone (fail "previous child PID remains present or unobservable")
  retained <- observeKindIntent bootstrap
  unless (retained == KindIntentMatches operationId) (fail "interrupted operation identity was lost")
  wrongPlan <- right (Runtime.reserveRuntimeMemory 0 1 (sealedToolRuntimePlan budget))
  unfunded <- right (planSealedToolBudget (sealedToolRuntimePlan budget) 1024 (2 * 1024 * 1024))
  differentBudget <-
    right
      (planSealedToolBudgetWithInput (sealedToolRuntimePlan budget) 1024 (2 * 1024 * 1024) 1024 4096)
  result <- Subprocess.withKindHostSubprocessPlacement plan key window $ \placement -> withFixtureFailure root $ do
    rejected <- Subprocess.withPreparedKindHostSubprocess placement wrongPlan limits $ \_ ->
      pure (Right ())
    unless (rejected == Left Subprocess.HostSubprocessRuntimePlanMismatch) $
      fail ("mismatched plan was not refused: " <> show rejected)
    missingInputBudget <- Subprocess.withPreparedKindHostSubprocessWithInput placement unfunded limits $ \_ ->
      pure (Right ())
    unless
      ( missingInputBudget
          == Left (Subprocess.HostSubprocessCommandRefused Subprocess.OwnedSubprocessInvalidLimits)
      )
      $ fail ("unfunded input was not refused: " <> show missingInputBudget)
    mismatchInputBudget <- Subprocess.withPreparedKindHostSubprocessWithInput placement differentBudget limits $ \_ ->
      pure (Right ())
    unless (mismatchInputBudget == Left Subprocess.HostSubprocessRuntimePlanMismatch) $
      fail ("different input budget was not refused: " <> show mismatchInputBudget)
    inputResult <- Subprocess.withPreparedKindHostSubprocessWithInput
      placement
      budget
      limits
      $ \run -> do
        let cat =
              Subprocess.Subprocess
                "/bin/cat"
                []
                (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")])
                Nothing
            payload = Bytes.pack [65, 0, 66, 10]
        oversized <- run (Bytes.replicate 65537 65) cat
        unless (oversized == Left Subprocess.OwnedSubprocessInvalidLimits) $
          fail ("oversized input was not refused: " <> show oversized)
        delivered <- run payload cat
        case delivered of
          Right output
            | Subprocess.processExitCode output == ExitSuccess
                && Chars.pack (Subprocess.processStdout output) == payload ->
                pure ()
          other -> fail ("input delivery failed: " <> show other)
        repeated <- run payload cat
        unless (repeated == Left Subprocess.OwnedSubprocessInvalidLimits) $
          fail ("second child was not refused: " <> show repeated)
        pure (Right ())
    unless (inputResult == Right ()) (fail ("prepared input placement failed: " <> show inputResult))
    kindDeclaration <- maybe (fail "kind declaration missing") pure (bootstrapKindTool bootstrap)
    let kindPath = root </> ".test-data" </> "placement" </> "artifacts" </> "kind"
    cgroup <- readFile "/proc/self/cgroup"
    cgroupPath <- case [ p
                       | line <- lines cgroup
                       , Just p <- [stripPrefix "0::" line]
                       , "/" `isPrefixOf` p
                       , not (".." `isInfixOf` p)
                       ] of
      [p] -> pure p
      _ -> fail "unobservable current cgroup"
    let current = "/sys/fs/cgroup" <> cgroupPath <> "/memory.current"
        sample = readFile current >>= maybe (fail "invalid memory.current") pure . readMaybe
    before <- sample :: IO Integer
    simultaneous <- bracket (Posix.openFd kindPath Posix.ReadOnly Posix.defaultFileFlags) Posix.closeFd $ \kindFd ->
      bracket (Posix.openFd clientPath Posix.ReadOnly Posix.defaultFileFlags) Posix.closeFd $ \clientFd -> do
        clientSize <- toInteger . fileSize <$> getFdStatus clientFd
        unless (clientSize > 0) (fail "empty client executable")
        let minimumCharge = min (128 * 1024 * 1024) (max 1 (clientSize `div` 2))
        invalid <- Subprocess.withPreparedKindHostSubprocessWithSealedClient placement budgets clientFd limits $ \_ ->
          pure (Right ())
        unless
          (invalid == Left (Subprocess.HostSubprocessCommandRefused Subprocess.OwnedSubprocessInvalidLimits))
          $ fail ("unsealed descriptor was accepted: " <> show invalid)
        withSealedTool budget kindFd (artifactDigest kindDeclaration) (128 * 1024 * 1024) $ \sealedKind ->
          withSealedTool clientBudget clientFd clientDigest (256 * 1024 * 1024) $ \sealedClient -> do
            parentBefore <- Posix.queryFdOption sealedClient Posix.CloseOnExec
            unless parentBefore (fail "parent descriptor was inheritable")
            Posix.setFdOption sealedClient Posix.CloseOnExec False
            unsafeResult <-
              Subprocess.withPreparedKindHostSubprocessWithSealedClient
                placement
                budgets
                sealedClient
                limits
                (\_ -> pure (Right ()))
                `finally` Posix.setFdOption sealedClient Posix.CloseOnExec True
            unless
              ( unsafeResult
                  == Left (Subprocess.HostSubprocessCommandRefused Subprocess.OwnedSubprocessInvalidLimits)
              )
              $ fail ("inheritable parent descriptor was accepted: " <> show unsafeResult)
            let command =
                  Subprocess.Subprocess
                    "/bin/sh"
                    [ "-c"
                    , "/usr/bin/head -c 4 \"/proc/self/fd/$1\" && exec /bin/cat"
                    , "sealed-client-fixture"
                    , show sealedClient
                    ]
                    (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")])
                    Nothing
            childResult <- Subprocess.withPreparedKindHostSubprocessWithSealedClient placement budgets sealedClient limits $ \run -> do
              oversized <- run (Bytes.replicate 65537 65) command
              unless (oversized == Left Subprocess.OwnedSubprocessInvalidLimits) (fail "oversized input accepted")
              run (Bytes.pack [65, 0, 66, 10]) command
            parentAfter <- Posix.queryFdOption sealedClient Posix.CloseOnExec
            unless parentAfter (fail "parent close-on-exec flag changed")
            case childResult of
              Right output
                | Subprocess.processExitCode output == ExitSuccess
                    && Subprocess.processStdout output == ['\DEL', 'E', 'L', 'F', 'A', '\NUL', 'B', '\n'] ->
                    pure ()
              _ -> fail ("sealed descriptor did not reach child: " <> show childResult)
            runConfinedKindFixture placement budgets sealedKind sealedClient limits root expected
            after <- sample
            unless (after >= before + minimumCharge) (fail "combined memory charge unconfirmed")
            writeFile (root </> "snapshot-memory") (show before <> " " <> show after <> "\n")
    case simultaneous of
      Right (Right ()) -> pure ()
      _ -> fail ("combined snapshots failed: " <> show simultaneous)
    let configBytes = LazyBytes.toStrict (renderKindConfig (bootstrapKindPlan bootstrap))
        configReader =
          Subprocess.Subprocess
            "/bin/cat"
            []
            (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")])
            Nothing
    configResult <-
      Subprocess.withPreparedKindHostSubprocessWithInput
        placement
        budget
        limits
        $ \run ->
          run configBytes configReader
    case configResult of
      Right output
        | Subprocess.processExitCode output == ExitSuccess
            && Chars.pack (Subprocess.processStdout output) == configBytes ->
            pure ()
      other -> fail ("kind configuration input mismatch: " <> show other)
    let filePath = root </> "bounded-input"
        fileBytes = Bytes.replicate 200000 65
        digestCommand =
          Subprocess.Subprocess
            "/usr/bin/sha256sum"
            []
            (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")])
            Nothing
    Bytes.writeFile filePath fileBytes
    fileResult <- bracket (Posix.openFd filePath Posix.ReadOnly Posix.defaultFileFlags) Posix.closeFd $ \descriptor ->
      Subprocess.withPreparedKindHostSubprocessWithFileInput
        placement
        (sealedToolRuntimePlan budget)
        limits
        $ \run -> do
          resultValue <- run 200000 descriptor digestCommand
          pure (Right resultValue)
    let expectedOutput = Chars.unpack (hexSha256 fileBytes) <> "  -\n"
    unless
      ( fileResult
          == Right
            ( Subprocess.OwnedFileInputObserved
                (Right (Subprocess.ProcessOutput ExitSuccess expectedOutput ""))
                Subprocess.OwnedFileInputStable
            )
      )
      $ fail ("held file placement failed: " <> show fileResult)
    clusterInventory <- observeKindToolClusterOnHost placement limits budget bootstrap
    unless (clusterInventory == Right (KindToolAttempted (KindToolClusterListed False) True)) $
      fail ("selected kind inventory was not an empty observation: " <> show clusterInventory)
    badInventory <- observeKindToolClusterOnHost placement limits budget invalidBootstrap
    case badInventory of
      Right (KindToolAttempted (KindToolExitFailure _) True) -> pure ()
      other -> fail ("unavailable Docker socket was not a failed observation: " <> show other)
    recovered <- withRecoveredKindOperation bootstrap operationId $ \recheck -> do
      stable <- recheck
      unless stable (fail "intent changed before recovery")
      observeKindToolVersionOnHost placement limits budget bootstrap
    pure (Right recovered)
  let accepted =
        result
          == Right (KindOperationCallbackReturned (Right (KindToolAttempted (KindToolVersion expected) True)))
  writeFile
    (root </> "result")
    (if accepted then "PASS " <> show workerPid <> "\n" else "FAIL: " <> show result <> "\n")
  when (isLeft result) (fail ("kind managed observation refused: " <> show result))
  unless accepted (fail "kind managed observation mismatched")

waitForMarker :: Word64 -> FilePath -> IO ()
waitForMarker deadline marker = do
  now <- getMonotonicTimeNSec
  when (now >= deadline) (fail "child did not start within original work deadline")
  exists <- doesFileExist marker
  unless exists (threadDelay 10000 >> waitForMarker deadline marker)

request
  :: Host.HostExecutionPlan
  -> Subprocess.HostExecutionWindow
  -> FilePath
  -> [String]
  -> BusMessage
  -> BusAction ()
request plan window executable args message = do
  appendString message "prodbox-kind-controller.service"
  appendString message "fail"
  withContainer message 'a' "(sv)" $ do
    string "Description" (Subprocess.kindHostSubprocessDescription plan key window)
    string "CollectMode" "inactive-or-failed"
    string "Type" "exec"
    string "Slice" "prodboxkind.slice"
    strings "RuntimeDirectory" ["prodbox-kind"]
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
    number "RuntimeMaxUSec" 35000000
    number "RuntimeRandomizedExtraUSec" 0
    number "TimeoutStartUSec" 10000000
    number "TimeoutStopUSec" 2000000
    string "StandardInput" "null"
    string "StandardOutput" "null"
    string "StandardError" "null"
    exec (executable : args <> ["+RTS", "-N1", "-M16777216", "-RTS"])
  withContainer message 'a' "(sa(sv))" $
    withContainer message 'r' "sa(sv)" $ do
      appendString message "prodboxkind.slice"
      withContainer message 'a' "(sv)" $ do
        string "Description" "prodbox kind placement fixture slice"
        string "CollectMode" "inactive-or-failed"
        number "MemoryMax" (Host.hostExecutionSliceMemoryBytes plan)
        number "MemorySwapMax" 0
        number "TasksMax" (Host.hostExecutionSliceTasks plan)
        number "CPUQuotaPerSecUSec" (Host.hostExecutionSliceCpuUsecPerSec plan)
        boolean "StopWhenUnneeded" True
 where
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
