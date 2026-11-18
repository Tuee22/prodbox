{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- A local mutation-worker fixture, not mutation admission or phase acceptance.
-- It preserves its scratch root on every incomplete observation.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (AsyncCancelled, cancel, waitCatch, withAsync, withAsyncBound)
import Control.Exception
  ( SomeException
  , bracket
  , fromException
  , try
  )
import Control.Monad (unless, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (runExceptT)
import Data.Bits ((.|.))
import Data.Either (isLeft)
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Text qualified as Text
import Data.Word (Word64)
import Foreign.C.Error (throwErrnoIfMinus1)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Capacity.Allocation qualified as Allocation
import Prodbox.Capacity.Config qualified as Capacity
import Prodbox.Capacity.HostExecution qualified as Host
import Prodbox.Capacity.NativeHostProbe (observeNativeHostCapacityBefore)
import Prodbox.Capacity.ObservedHost qualified as Observed
import Prodbox.Capacity.RuntimeMemory qualified as Runtime
import Prodbox.Control.SealedTool
import Prodbox.Subprocess qualified as Subprocess
import Prodbox.Subprocess.SystemdBus
import Prodbox.Subprocess.SystemdIdentity (hostExecutionKeyText)
import Prodbox.Test.MutationOutputInventory
  ( MutationOutputObservation (..)
  , mutationOutputLimits
  , observeMutationOutputInventory
  )
import Prodbox.Test.MutationSnapshot (MutationSnapshot, makeMutationSnapshot)
import Prodbox.Test.MutationSnapshotObserve (MutationSnapshotObservation (..))
import Prodbox.Test.MutationSnapshotWrite (mutationSnapshotRootIdentity)
import Prodbox.Test.MutationWorkspace
  ( MutationWorkspaceOutcome (..)
  , checkpointMutationWorkspaceOutput
  , withNewMutationWorkspace
  , withRecoveredMutableMutationOutputWorkspace
  , withRecoveredMutationOutputCheckpoint
  , withRecoveredMutationOutputWorkspace
  , withRecoveredMutationWorkspace
  )
import Prodbox.Test.MutationWorkspaceIntent
  ( MutationOutputCheckpointObservation (..)
  , MutationWorkspaceIntentWrite (..)
  , mutationWorkspaceWorkerKey
  )
import Prodbox.Test.MutationWorkspaceWorker
  ( MutationWorkspaceWorkerResult (..)
  , runRecoveredMutationWorkspaceWorker
  )
import Prodbox.Test.Qualification.SourceIdentity
  ( ManifestFileType (..)
  , SourceCandidate (..)
  , WorktreeState (..)
  , mkGitHead
  )
import System.Directory
  ( canonicalizePath
  , createDirectory
  , doesFileExist
  , removePathForcibly
  )
import System.Environment (getArgs, getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Error (isDoesNotExistError, tryIOError)
import System.IO.Temp (createTempDirectory)
import System.Posix.Files
  ( createLink
  , createSymbolicLink
  , getFdStatus
  , getSymbolicLinkStatus
  , setFileMode
  )
import System.Posix.Files qualified as PosixFiles
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
    ["controller", root, keyText, outer, work, hard, stop, finish] -> do
      values <-
        mapM (maybe (fail "invalid fixture clock") pure . readMaybe) [outer, work, hard, stop, finish]
      case values of
        [a, b, c, d, e] -> do
          outcome <- try (controller root keyText a b c d e)
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

operation :: String
operation = replicate 32 'a'

otherOperation :: String
otherOperation = replicate 32 'b'

fixtureSnapshot :: IO MutationSnapshot
fixtureSnapshot = do
  headId <- right (mkGitHead (Text.replicate 40 "a"))
  right
    ( makeMutationSnapshot
        headId
        WorktreeDirty
        []
        [SourceCandidate "src/X.hs" ManifestRegularFile 0o644 "fixture"]
    )

firstCheckpoint, finalCheckpoint :: String
firstCheckpoint = replicate 32 'c'
finalCheckpoint = replicate 32 'd'

launch :: FilePath -> IO ()
launch operator = do
  clientPath <- canonicalizePath operator
  (hashExit, hashOutput, _) <- readProcessWithExitCode "/usr/bin/sha256sum" [clientPath] ""
  let hash = take 64 hashOutput
      hex character = character `elem` ("0123456789abcdef" :: String)
  unless
    (hashExit == ExitSuccess && length hash == 64 && all hex hash && take 2 (drop 64 hashOutput) == "  ")
    $ fail "operator digest unavailable"
  root <- createTempDirectory "/tmp" "prodbox-mutation-host-placement-"
  putStrLn ("Fixture root: " <> root)
  setFileMode root 0o700
  snapshot <- fixtureSnapshot
  outputLimits <-
    maybe (fail "invalid output fixture limits") pure (mutationOutputLimits 128 1048576 8 5000000)
  prepared <- withNewMutationWorkspace root operation snapshot $ \workspace stable -> do
    ready <- stable
    identity <- mutationSnapshotRootIdentity <$> getFdStatus workspace
    pure (if ready then mutationWorkspaceWorkerKey operation snapshot identity else Nothing)
  key <- case prepared of
    MutationWorkspaceCallbackReturned (Just value) -> pure value
    other -> fail ("fixture workspace preparation refused: " <> show other)
  otherPrepared <- withNewMutationWorkspace root otherOperation snapshot (\_ stable -> stable)
  unless (otherPrepared == MutationWorkspaceCallbackReturned True) $
    fail ("second fixture workspace preparation refused: " <> show otherPrepared)
  let outputProject = root </> "output-project"
  createDirectory outputProject
  outputPrepared <- withNewMutationWorkspace outputProject operation snapshot (\_ stable -> stable)
  unless (outputPrepared == MutationWorkspaceCallbackReturned True) $
    fail ("output fixture workspace preparation refused: " <> show outputPrepared)
  writeFile (root </> "foreign-marker") "unchanged"
  let digest = hash
  (plan, _, observed) <- fixture root
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
      runtimeDirectory = "/run/user/" <> show uid <> "/prodbox-mutation"
      cgroup =
        "/sys/fs/cgroup/user.slice/user-"
          <> show uid
          <> ".slice/user@"
          <> show uid
          <> ".service/prodboxmutation.slice"
      field = "prodbox-owned-" <> hostExecutionKeyText key
      names =
        [ "prodbox-mutation-controller.service"
        , "prodboxmutation.slice"
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
              key
              window
              executable
              [ "controller"
              , root
              , hostExecutionKeyText key
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
  (workerPid, secondPid, thirdPid, interruptedPid) <- case words contents of
    ["PASS", raw, second, third, interrupted] -> do
      worker <- maybe (fail "invalid settled child identity") pure (readMaybe raw :: Maybe Int)
      next <- maybe (fail "invalid second child identity") pure (readMaybe second :: Maybe Int)
      final <- maybe (fail "invalid third child identity") pure (readMaybe third :: Maybe Int)
      previous <-
        maybe (fail "invalid interrupted child identity") pure (readMaybe interrupted :: Maybe Int)
      pure (worker, next, final, previous)
    _ -> fail ("controller result: " <> contents)
  processGone <-
    mapM (pathAbsent . ("/proc/" <>) . show) [workerPid, secondPid, thirdPid, interruptedPid]
  unless (and processGone) (fail "child PID remains present or unobservable")
  first <- withRecoveredMutationWorkspace root operation snapshot (\_ stable -> stable)
  second <- withRecoveredMutationWorkspace root otherOperation snapshot (\_ stable -> stable)
  checkpointRecovery <-
    withRecoveredMutationOutputCheckpoint
      outputLimits
      key
      finalCheckpoint
      outputProject
      operation
      snapshot
      (\_ stable -> stable)
  changedOutput <-
    withRecoveredMutationWorkspace outputProject operation snapshot (\_ stable -> stable)
  marker <- readFile (root </> "foreign-marker")
  artifact <-
    readFile (outputProject </> ".build" </> "mutation-workspaces" </> operation </> "build-result")
  unless
    ( first == MutationWorkspaceCallbackReturned True
        && second == MutationWorkspaceCallbackReturned True
        && checkpointRecovery == MutationWorkspaceCallbackReturned True
        && changedOutput == MutationWorkspaceObservationRefused MutationSnapshotDiffers
        && marker == "unchanged"
        && artifact == "built"
    )
    (fail "workspace inventory or outside marker changed")
  putStrLn
    ( "PASS: staged and interrupted children "
        <> show workerPid
        <> ", "
        <> show secondPid
        <> ", "
        <> show thirdPid
        <> ", "
        <> show interruptedPid
        <> " absent; exact manager fields and runtime directory absent; fixture tool SHA-256 "
        <> digest
    )
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
  -> String
  -> Word64
  -> Word64
  -> Word64
  -> Word64
  -> Word64
  -> IO ()
controller root keyText outer work hard stop finish = do
  key <- maybe (fail "invalid fixture key") pure (Subprocess.hostExecutionKeyFromText keyText)
  snapshot <- fixtureSnapshot
  outputLimits <-
    maybe (fail "invalid output fixture limits") pure (mutationOutputLimits 128 1048576 8 5000000)
  (plan, budgets, _) <- fixture root
  let budget = kindWorkerKindBudget budgets
      workspace = root </> "mutation-work"
      recordedWorkspace = root </> ".build" </> "mutation-workspaces" </> operation
      outputProject = root </> "output-project"
      outputDirectory = outputProject </> ".build" </> "mutation-workspaces" </> operation
  createDirectory workspace
  setFileMode workspace 0o700
  writeFile (workspace </> "inside") "fixture"
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
  traceStep root "wrong-kind-start"
  wrongKind <- Subprocess.withKindHostSubprocessPlacement plan key window $ \_ -> pure (Right ())
  traceStep root "wrong-kind-end"
  wrongRpc <- Subprocess.withHostSubprocessPlacement plan key window $ \_ -> pure (Right ())
  unless
    (isLeft wrongKind && isLeft wrongRpc)
    (fail "mutation controller accepted another host profile")
  let openPath path = withCString path $ \raw ->
        Fd
          <$> throwErrnoIfMinus1
            "fixture open"
            (fixtureOpenPath raw (fixturePathOnly .|. fixtureNoFollow .|. fixtureCloseOnExec))
      closePath = Posix.closeFd
  bracket (openPath workspace) closePath $ \workFd ->
    bracket (openPath "/usr") closePath $ \usrFd ->
      bracket (Posix.openFd "/etc/passwd" Posix.ReadOnly Posix.defaultFileFlags) closePath $ \(Fd outsideFd) -> do
        let script =
              unlines
                [ "import os, socket, sys"
                , "assert open('src/X.hs').read() == 'fixture'"
                , "try: open('src/X.hs','w').write('changed'); raise AssertionError('source write allowed')"
                , "except PermissionError: pass"
                , "try: open('/etc/passwd').read(); raise AssertionError('outside read allowed')"
                , "except PermissionError: pass"
                , "try: open(sys.argv[2]).read(); raise AssertionError('foreign marker read allowed')"
                , "except PermissionError: pass"
                , "try: socket.socket(); raise AssertionError('socket allowed')"
                , "except PermissionError: pass"
                , "try: os.read(int(sys.argv[1]), 1); raise AssertionError('inherited fd allowed')"
                , "except OSError as e: assert e.errno == 9"
                , "open(os.path.join(os.environ['TMPDIR'], 'build-result'),'w').write('built')"
                , "print(os.getpid())"
                ]
            child =
              Subprocess.Subprocess
                "/usr/bin/python3"
                ["-c", script, show outsideFd, root </> "foreign-marker"]
                ( Just
                    [ ("PATH", "/usr/bin")
                    , ("HOME", outputDirectory)
                    , ("TMPDIR", outputDirectory)
                    , ("LANG", "C.UTF-8")
                    ]
                )
                (Just recordedWorkspace)
        interrupted <- Subprocess.withMutationHostSubprocessPlacement plan key window $ \placement -> do
          let waiting =
                child
                  { Subprocess.subprocessArguments =
                      [ "-c"
                      , "import os,time; open('child-pid','w').write(str(os.getpid())); time.sleep(60)"
                      ]
                  , Subprocess.subprocessEnvironment =
                      Just [("PATH", "/usr/bin"), ("HOME", workspace), ("TMPDIR", workspace)]
                  , Subprocess.subprocessWorkingDirectory = Just workspace
                  }
          traceStep root "cancel-worker-start"
          pid <- withAsyncBound
            ( Subprocess.withPreparedMutationHostSubprocess
                placement
                (sealedToolRuntimePlan budget)
                workFd
                [usrFd]
                limits
                ( \run -> do
                    let contaminated =
                          waiting
                            { Subprocess.subprocessEnvironment =
                                Just
                                  [ ("PATH", "/usr/bin")
                                  , ("HOME", workspace)
                                  , ("TMPDIR", workspace)
                                  , ("AWS_ACCESS_KEY_ID", "synthetic-fixture")
                                  ]
                            }
                    rejected <- run contaminated
                    unless
                      (rejected == Left Subprocess.OwnedSubprocessInvalidLimits)
                      (fail "credential-like environment accepted")
                    run waiting
                )
            )
            $ \worker -> do
              waitForMarker work (workspace </> "child-pid")
              raw <- readFile (workspace </> "child-pid")
              pid <- maybe (fail "invalid interrupted child identity") pure (readMaybe raw :: Maybe Int)
              when (pid <= 0) (fail "invalid interrupted child identity")
              traceStep root "cancel-request"
              cancelStarted <- getMonotonicTimeNSec
              cancel worker
              cancelFinished <- getMonotonicTimeNSec
              unless (cancelFinished >= cancelStarted && cancelFinished - cancelStarted < 5000000000) $
                fail "mutation worker cancellation exceeded its fixture budget"
              traceStep root "cancel-returned"
              stopped <- waitCatch worker
              case stopped of
                Left failure | Just (_ :: AsyncCancelled) <- fromException failure -> pure ()
                _ -> fail "interrupted mutation worker did not settle"
              gone <- pathAbsent ("/proc/" <> show pid)
              unless gone (fail "interrupted mutation worker remains present or unobservable")
              pure pid
          pure (Right pid)
        interruptedPid <- right interrupted
        traceStep root "normal-worker-start"
        outputOutcome <- withRecoveredMutableMutationOutputWorkspace outputProject operation snapshot $ \outputFd outputStable -> do
          result <- Subprocess.withMutationHostSubprocessPlacement plan key window $ \placement -> do
            withAsync
              ( Subprocess.withPreparedMutationHostSubprocess
                  placement
                  (sealedToolRuntimePlan budget)
                  workFd
                  [usrFd]
                  limits
                  ($ child)
              )
              $ \worker -> do
                unbound <- waitCatch worker
                case unbound of
                  Right (Left (Subprocess.HostSubprocessCommandRefused Subprocess.OwnedSubprocessRuntimeUnsupported)) -> pure ()
                  _ -> fail "unbound mutation worker was not refused"
            foreignKey <-
              runRecoveredMutationWorkspaceWorker
                root
                otherOperation
                snapshot
                placement
                (sealedToolRuntimePlan budget)
                outputDirectory
                outputFd
                outputStable
                [usrFd]
                limits
                (\_ stable -> stable)
                child
            unless (foreignKey == MutationWorkspaceCallbackReturned MutationWorkerBindingRefused) $
              fail ("foreign workspace key was accepted: " <> show foreignKey)
            wrongOutput <-
              runRecoveredMutationWorkspaceWorker
                root
                operation
                snapshot
                placement
                (sealedToolRuntimePlan budget)
                recordedWorkspace
                outputFd
                outputStable
                [usrFd]
                limits
                (\_ stable -> stable)
                child
            unless (wrongOutput == MutationWorkspaceCallbackReturned MutationWorkerOutputRefused) $
              fail ("source output alias was accepted: " <> show wrongOutput)
            unstableOutput <-
              runRecoveredMutationWorkspaceWorker
                root
                operation
                snapshot
                placement
                (sealedToolRuntimePlan budget)
                outputDirectory
                outputFd
                (pure False)
                [usrFd]
                limits
                (\_ stable -> stable)
                child
            unless (unstableOutput == MutationWorkspaceCallbackReturned MutationWorkerWorkspaceChanged) $
              fail ("unstable output was accepted: " <> show unstableOutput)
            refused <-
              runRecoveredMutationWorkspaceWorker
                root
                operation
                snapshot
                placement
                (sealedToolRuntimePlan budget)
                outputDirectory
                outputFd
                outputStable
                [usrFd]
                limits
                (\_ _ -> pure False)
                child
            unless (refused == MutationWorkspaceCallbackReturned MutationWorkerAdmissionRefused) $
              fail ("workspace admission refusal changed: " <> show refused)
            wrongCommand <-
              runRecoveredMutationWorkspaceWorker
                root
                operation
                snapshot
                placement
                (sealedToolRuntimePlan budget)
                outputDirectory
                outputFd
                outputStable
                [usrFd]
                limits
                (\_ stable -> stable)
                child {Subprocess.subprocessWorkingDirectory = Just workspace}
            unless (wrongCommand == MutationWorkspaceCallbackReturned MutationWorkerCommandRefused) $
              fail ("foreign working directory was accepted: " <> show wrongCommand)
            observed <-
              runRecoveredMutationWorkspaceWorker
                root
                operation
                snapshot
                placement
                (sealedToolRuntimePlan budget)
                outputDirectory
                outputFd
                outputStable
                [usrFd]
                limits
                (\_ stable -> stable)
                child
            case observed of
              MutationWorkspaceCallbackReturned (MutationWorkerFinished outcome) -> pure outcome
              other -> fail ("workspace worker refused: " <> show other)
          firstPid <- case result of
            Right (Subprocess.ProcessOutput ExitSuccess output _) -> case words output of
              [pid] -> pure pid
              _ -> fail "first worker returned an invalid process identity"
            other -> fail ("first workspace worker failed: " <> show other)
          let second =
                child
                  { Subprocess.subprocessArguments =
                      [ "-c"
                      , "import os; assert open(os.path.join(os.environ['TMPDIR'],'build-result')).read() == 'built'; print(os.getpid())"
                      ]
                  }
          next <- Subprocess.withMutationHostSubprocessPlacement plan key window $ \placement ->
            Right
              <$> runRecoveredMutationWorkspaceWorker
                root
                operation
                snapshot
                placement
                (sealedToolRuntimePlan budget)
                outputDirectory
                outputFd
                outputStable
                [usrFd]
                limits
                (\_ stable -> stable)
                second
          secondPid <- case next of
            Right
              ( MutationWorkspaceCallbackReturned
                  (MutationWorkerFinished (Right (Subprocess.ProcessOutput ExitSuccess output _)))
                ) -> case words output of
                [pid] -> pure pid
                _ -> fail "second worker returned an invalid process identity"
            other -> fail ("second workspace worker failed: " <> show other)
          observations <- newIORef (0 :: Int)
          let failsAfter = do
                count <- atomicModifyIORef' observations (\prior -> (prior + 1, prior))
                if count < 2 then outputStable else ioError (userError "synthetic output observation failure")
          final <- Subprocess.withMutationHostSubprocessPlacement plan key window $ \placement ->
            Right
              <$> runRecoveredMutationWorkspaceWorker
                root
                operation
                snapshot
                placement
                (sealedToolRuntimePlan budget)
                outputDirectory
                outputFd
                failsAfter
                [usrFd]
                limits
                (\_ stable -> stable)
                second
          thirdPid <- case final of
            Right
              ( MutationWorkspaceCallbackReturned
                  (MutationWorkerOutputChangedAfter (Right (Subprocess.ProcessOutput ExitSuccess output _)))
                ) -> case words output of
                [pid] -> pure pid
                _ -> fail "third worker returned an invalid process identity"
            other -> fail ("output observation failure lost worker result: " <> show other)
          tinyLimits <-
            maybe (fail "invalid tiny output limit") pure (mutationOutputLimits 1 1048576 8 5000000)
          oversized <- observeMutationOutputInventory tinyLimits outputFd
          unless
            (oversized == MutationOutputUnsafe)
            (fail ("output entry limit was not enforced: " <> show oversized))
          shallowLimits <-
            maybe (fail "invalid shallow output limit") pure (mutationOutputLimits 128 1048576 1 5000000)
          tooDeep <- observeMutationOutputInventory shallowLimits outputFd
          unless
            (tooDeep == MutationOutputUnsafe)
            (fail ("output depth limit was not enforced: " <> show tooDeep))
          inventory <- observeMutationOutputInventory outputLimits outputFd
          case inventory of
            MutationOutputObserved value -> pure (firstPid, secondPid, thirdPid, value)
            other -> fail ("output inventory refused: " <> show other)
        traceStep root "placement-returned"
        case outputOutcome of
          MutationWorkspaceCallbackReturned (firstPid, secondPid, thirdPid, inventory) -> do
            checkpointed <-
              checkpointMutationWorkspaceOutput
                outputLimits
                inventory
                key
                firstCheckpoint
                outputProject
                operation
                snapshot
            unless (checkpointed == MutationWorkspaceCallbackReturned MutationWorkspaceIntentRecorded) $
              fail ("output checkpoint refused: " <> show checkpointed)
            duplicate <-
              checkpointMutationWorkspaceOutput
                outputLimits
                inventory
                key
                firstCheckpoint
                outputProject
                operation
                snapshot
            unless (duplicate == MutationWorkspaceCallbackReturned MutationWorkspaceIntentExists) $
              fail ("output checkpoint overwrite was accepted: " <> show duplicate)
            checkpointRecovery <-
              withRecoveredMutationOutputCheckpoint
                outputLimits
                key
                firstCheckpoint
                outputProject
                operation
                snapshot
                (\_ stable -> stable)
            unless (checkpointRecovery == MutationWorkspaceCallbackReturned True) $
              fail ("checkpointed output did not reopen: " <> show checkpointRecovery)
            foreignKey <-
              maybe (fail "invalid foreign key") pure (Subprocess.hostExecutionKeyFromText (replicate 64 'e'))
            wrongKey <-
              withRecoveredMutationOutputCheckpoint
                outputLimits
                foreignKey
                firstCheckpoint
                outputProject
                operation
                snapshot
                (\_ stable -> stable)
            unless (wrongKey == MutationWorkspaceOutputCheckpointRefused MutationOutputCheckpointConflict) $
              fail ("checkpoint accepted a foreign worker key: " <> show wrongKey)
            changedLimits <-
              maybe (fail "invalid changed output limits") pure (mutationOutputLimits 129 1048576 8 5000000)
            wrongLimits <-
              withRecoveredMutationOutputCheckpoint
                changedLimits
                key
                firstCheckpoint
                outputProject
                operation
                snapshot
                (\_ stable -> stable)
            unless (wrongLimits == MutationWorkspaceOutputCheckpointRefused MutationOutputCheckpointConflict) $
              fail ("checkpoint accepted different output limits: " <> show wrongLimits)
            missing <-
              withRecoveredMutationOutputCheckpoint
                outputLimits
                key
                finalCheckpoint
                outputProject
                operation
                snapshot
                (\_ stable -> stable)
            unless (missing == MutationWorkspaceOutputCheckpointRefused MutationOutputCheckpointMissing) $
              fail ("missing output checkpoint was accepted: " <> show missing)
            let malformedId = replicate 32 'f'
                malformedPath = outputProject </> ".build" </> "mutation-workspaces" </> (operation <> ".output." <> malformedId)
            writeFile malformedPath "invalid-fixture"
            malformed <-
              withRecoveredMutationOutputCheckpoint
                outputLimits
                key
                malformedId
                outputProject
                operation
                snapshot
                (\_ stable -> stable)
            unless (malformed == MutationWorkspaceOutputCheckpointRefused MutationOutputCheckpointInvalid) $
              fail ("malformed output checkpoint was accepted: " <> show malformed)
            recovered <-
              withRecoveredMutationOutputWorkspace
                outputLimits
                inventory
                outputProject
                operation
                snapshot
                (\_ stable -> stable)
            unless (recovered == MutationWorkspaceCallbackReturned True) $
              fail ("recorded output did not reopen: " <> show recovered)
            let artifact = outputDirectory </> "build-result"
                link = outputDirectory </> "foreign-link"
                hardlink = outputDirectory </> "hard-link"
            writeFile artifact "tampered-output"
            changed <-
              withRecoveredMutationOutputWorkspace
                outputLimits
                inventory
                outputProject
                operation
                snapshot
                (\_ stable -> stable)
            unless (changed == MutationWorkspaceOutputChanged) $
              fail ("changed output was accepted: " <> show changed)
            changedCheckpoint <-
              withRecoveredMutationOutputCheckpoint
                outputLimits
                key
                firstCheckpoint
                outputProject
                operation
                snapshot
                (\_ stable -> stable)
            unless
              (changedCheckpoint == MutationWorkspaceOutputChanged)
              $ fail ("checkpoint accepted changed output: " <> show changedCheckpoint)
            writeFile artifact "built"
            createSymbolicLink "/etc/passwd" link
            linked <-
              withRecoveredMutationOutputWorkspace
                outputLimits
                inventory
                outputProject
                operation
                snapshot
                (\_ stable -> stable)
            unless (linked == MutationWorkspaceOutputObservationRefused MutationOutputUnsafe) $
              fail ("output symlink was accepted: " <> show linked)
            linkedCheckpoint <-
              withRecoveredMutationOutputCheckpoint
                outputLimits
                key
                firstCheckpoint
                outputProject
                operation
                snapshot
                (\_ stable -> stable)
            unless (linkedCheckpoint == MutationWorkspaceOutputObservationRefused MutationOutputUnsafe) $
              fail ("checkpoint accepted an output symlink: " <> show linkedCheckpoint)
            PosixFiles.removeLink link
            createLink artifact hardlink
            aliased <-
              withRecoveredMutationOutputWorkspace
                outputLimits
                inventory
                outputProject
                operation
                snapshot
                (\_ stable -> stable)
            unless (aliased == MutationWorkspaceOutputObservationRefused MutationOutputUnsafe) $
              fail ("output hard link was accepted: " <> show aliased)
            aliasedCheckpoint <-
              withRecoveredMutationOutputCheckpoint
                outputLimits
                key
                firstCheckpoint
                outputProject
                operation
                snapshot
                (\_ stable -> stable)
            unless (aliasedCheckpoint == MutationWorkspaceOutputObservationRefused MutationOutputUnsafe) $
              fail ("checkpoint accepted an output hard link: " <> show aliasedCheckpoint)
            PosixFiles.removeLink hardlink
            latest <- bracket (openPath outputDirectory) closePath (observeMutationOutputInventory outputLimits)
            latestInventory <- case latest of
              MutationOutputObserved value -> pure value
              other -> fail ("final output inventory refused: " <> show other)
            finalRecord <-
              checkpointMutationWorkspaceOutput
                outputLimits
                latestInventory
                key
                finalCheckpoint
                outputProject
                operation
                snapshot
            unless (finalRecord == MutationWorkspaceCallbackReturned MutationWorkspaceIntentRecorded) $
              fail ("final output checkpoint refused: " <> show finalRecord)
            writeFile
              (root </> "result")
              ("PASS " <> firstPid <> " " <> secondPid <> " " <> thirdPid <> " " <> show interruptedPid <> "\n")
          other -> fail ("output workspace changed: " <> show other)

traceStep :: FilePath -> String -> IO ()
traceStep root label = do
  now <- getMonotonicTimeNSec
  appendFile (root </> "trace") (label <> " " <> show now <> "\n")

waitForMarker :: Word64 -> FilePath -> IO ()
waitForMarker deadline marker = do
  now <- getMonotonicTimeNSec
  when (now >= deadline) (fail "child did not start within work deadline")
  exists <- doesFileExist marker
  unless exists (threadDelay 10000 >> waitForMarker deadline marker)

request
  :: Host.HostExecutionPlan
  -> Subprocess.HostExecutionKey
  -> Subprocess.HostExecutionWindow
  -> FilePath
  -> [String]
  -> BusMessage
  -> BusAction ()
request plan key window executable args message = do
  appendString message "prodbox-mutation-controller.service"
  appendString message "fail"
  withContainer message 'a' "(sv)" $ do
    string "Description" (Subprocess.mutationHostSubprocessDescription plan key window)
    string "CollectMode" "inactive-or-failed"
    string "Type" "exec"
    string "Slice" "prodboxmutation.slice"
    strings "RuntimeDirectory" ["prodbox-mutation"]
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
    string "StandardError" "journal"
    exec (executable : args <> ["+RTS", "-N1", "-M16777216", "-RTS"])
  withContainer message 'a' "(sa(sv))" $
    withContainer message 'r' "sa(sv)" $ do
      appendString message "prodboxmutation.slice"
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
