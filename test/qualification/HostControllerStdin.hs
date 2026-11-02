{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Native anonymous-carrier controls over the canonical published family.
-- The standalone 128/256-MiB fixture is not an Authority or business program.
module Main (main) where

import Control.Concurrent (newEmptyMVar, putMVar, readMVar, threadDelay)
import Control.Concurrent.Async qualified as Async
import Control.Exception (IOException, finally, throwIO, try)
import Control.Monad (forM_, unless, void)
import Control.Monad.Trans.Class (lift)
import Crypto.Random (getRandomBytes)
import Data.Aeson (FromJSON, ToJSON, eitherDecodeStrict, encode)
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import GHC.Generics (Generic)
import HostOperationRpcBirthFixture qualified as Fixture
import Prodbox.Lifecycle.Teardown.EphemeralKubectl qualified as Kubectl
import Prodbox.Subprocess qualified as Process
import Prodbox.Subprocess.HostControllerArguments qualified as Arguments
import Prodbox.Subprocess.HostControllerInputRetirement qualified as InputRetirement
import Prodbox.Subprocess.HostControllerInputs qualified as Inputs
import Prodbox.Subprocess.HostControllerPublication qualified as Publication
import Prodbox.Subprocess.HostControllerStdin qualified as Stdin
import Prodbox.Subprocess.HostOperationFamily qualified as Family
import Prodbox.Subprocess.HostOperationRetirement qualified as Retirement
import Prodbox.Subprocess.KernelScope qualified as Kernel
import Prodbox.Subprocess.ProcessEnvironment qualified as Environment
import Prodbox.Subprocess.StartupLine qualified as Startup
import Prodbox.Subprocess.SystemdBus qualified as Bus
import Prodbox.Subprocess.SystemdIdentity
import System.Directory (createDirectoryIfMissing, doesFileExist, makeAbsolute)
import System.Environment (getArgs, setEnv)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.IO.Temp (withTempDirectory)
import System.Posix.Files (setFileMode)
import System.Posix.User (getEffectiveUserID)
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

data FixtureRequest = FixtureRequest !FilePath !String
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

right :: (Show errorValue) => Either errorValue value -> IO value
right = either (assertFailure . show) pure

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    "internal-cascade-controller" : rest -> controller rest
    _ ->
      defaultMain $
        testGroup
          "canonical controller stdin"
          [ testCase "empty and excessive frames refuse before callback" sizeRefusals
          , testCase "an expired original window refuses before callback" expiredRefusal
          , testCase "unoffered and escaped owners cannot deliver" scopeRefusals
          , testCase "the caller exception survives descriptor cleanup" exceptionScope
          , testCase "the entire 64-KiB binary frame crosses the real family" (nativeFamily "raw")
          , testCase "the existing null-input route supplies no fallback" (nativeFamily "none")
          , testCase
              "native byte environments cross the original command and transport roles"
              (nativeFamily "native-env")
          , testCase "a blocked original writer expires without renewing work" (nativeFamily "expire")
          , testCase "cancellation joins delivery and retains uncertain launch inputs" (nativeFamily "cancel")
          ]

fixtureKey :: IO HostExecutionKey
fixtureKey = do
  bytes <- getRandomBytes 32
  let hex byte =
        [ "0123456789abcdef" !! fromIntegral (byte `div` 16)
        , "0123456789abcdef" !! fromIntegral (byte `mod` 16)
        ]
  maybe
    (assertFailure "invalid fixture key")
    pure
    (hostExecutionKeyFromText (concatMap hex (Bytes.unpack bytes)))

fixtureWindow :: IO HostExecutionWindow
fixtureWindow = do
  now <- getMonotonicTimeNSec
  maybe
    (assertFailure "invalid fixture window")
    pure
    ( hostExecutionWindow
        (now + 20000000000)
        (now + 15000000000)
        (now + 16000000000)
        (now + 17000000000)
        (now + 18000000000)
    )

sizeRefusals :: IO ()
sizeRefusals = do
  key <- fixtureKey
  window <- fixtureWindow
  mapM_
    ( \(bytes, expected) -> do
        result <-
          Stdin.withHostControllerStdin
            key
            window
            bytes
            (const (assertFailure "invalid frame entered callback"))
        case result of Left actual -> actual @?= expected; Right _ -> assertFailure "invalid frame accepted"
    )
    [ (Bytes.empty, Stdin.ControllerStdinEmpty)
    , (Bytes.replicate (Stdin.hostControllerStdinMaximumBytes + 1) 0, Stdin.ControllerStdinTooLarge)
    ]

expiredRefusal :: IO ()
expiredRefusal = do
  key <- fixtureKey
  window <- maybe (assertFailure "invalid expired window") pure (hostExecutionWindow 5 1 2 3 4)
  result <-
    Stdin.withHostControllerStdin
      key
      window
      "fixture"
      (const (assertFailure "expired frame entered callback"))
  case result of
    Left actual -> actual @?= Stdin.ControllerStdinExpired
    Right _ -> assertFailure "expired input accepted"

scopeRefusals :: IO ()
scopeRefusals = do
  key <- fixtureKey
  other <- fixtureKey
  window <- fixtureWindow
  escaped <-
    right
      =<< Stdin.withHostControllerStdin
        key
        window
        "fixture"
        ( \owner -> do
            Stdin.verifyHostControllerStdin other window owner
              >>= (@?= Left Stdin.ControllerStdinBindingMismatch)
            Stdin.deliverHostControllerStdin owner >>= (@?= Left Stdin.ControllerStdinNotOffered)
            pure owner
        )
  Stdin.verifyHostControllerStdin key window escaped >>= (@?= Left Stdin.ControllerStdinClosed)
  Stdin.deliverHostControllerStdin escaped >>= (@?= Left Stdin.ControllerStdinClosed)

exceptionScope :: IO ()
exceptionScope = do
  key <- fixtureKey
  window <- fixtureWindow
  result <-
    try
      (Stdin.withHostControllerStdin key window "fixture" (\_ -> throwIO (userError "caller-primary")))
      :: IO (Either IOException (Either Stdin.HostControllerStdinError ()))
  case result of
    Left cause -> assertBool "caller exception was replaced" (show cause == "user error (caller-primary)")
    Right _ -> assertFailure "caller exception was swallowed"

payload :: Bytes.ByteString
payload = Bytes.pack (take Stdin.hostControllerStdinMaximumBytes (cycle [0 .. 255]))

nativeFamily :: String -> IO ()
nativeFamily mode = withTempDirectory ".build/sprint-6.5/host-controller-stdin-20261030" "carrier-" $ \relative -> do
  root <- makeAbsolute relative
  (plan, observed) <- Fixture.fixturePlan
  key <- fixtureKey
  window <- fixtureWindow
  helper <-
    maybe (assertFailure "invalid helper bounds") pure (Family.hostOperationHelperBounds 20000 20000)
  intent <- right =<< Family.newHostOperationIntent OrdinaryCascadeController plan helper key window
  uid <- getEffectiveUserID
  let directory = Publication.hostControllerPublishedDirectory OrdinaryCascadeController uid key
      path = directory </> Publication.hostControllerRequestName
      ending = hostExecutionWorkEnd window
      clean = do
        waitUntil (hostExecutionOuterEnd window + 10000000)
        end <- (+ 5000000000) <$> getMonotonicTimeNSec
        record <- Inputs.readHostControllerSubmission end path key
        case record of
          Left _ -> do
            retired <-
              Publication.withRecoveredHostPublicationNeverSent
                OrdinaryCascadeController
                end
                key
                (InputRetirement.retireNeverSentHostControllerInputs end)
            first <- right retired
            void (right first)
          Right saved -> do
            opened <- Bus.withSystemdBus end ("/run/user/" <> show uid <> "/bus") $ \bus ->
              lift $
                Retirement.withHostOperationRetirement
                  bus
                  saved
                  (\owner -> InputRetirement.retireHostControllerInputs end owner saved)
            first <- right opened
            second <- right first
            void (right second)
        mapM_
          ( \name ->
              doesFileExist (directory </> name)
                >>= assertBool "published payload remained after native retirement" . not
          )
          [Publication.hostControllerConfigurationName, Publication.hostControllerRequestName]
        putStrLn ("STDIN_NATIVE_FIELD_RETIRED " <> hostExecutionKeyText key <> " " <> mode)
  flip finally clean $ do
    publication <-
      Publication.withPublishedHostControllerOwner
        OrdinaryCascadeController
        ending
        key
        (Lazy.toStrict (encode (Fixture.observedValue observed)))
        (Lazy.toStrict (encode (FixtureRequest root mode)))
        ( \owner -> do
            let (config, request) = Publication.hostPublicationPaths owner
            selected <- Family.withCurrentHostControllerProgram OrdinaryCascadeController ending config request $ \program -> do
              let submit input = do
                    offered <- Publication.withHostPublicationSubmission owner $ \permit -> do
                      response <-
                        Bus.withSystemdBus
                          (hostExecutionOuterEnd window)
                          ("/run/user/" <> show uid <> "/bus")
                          (submitFamily permit input)
                      right response
                    right offered
                  submitFamily permit input bus = lift $
                    case input of
                      Nothing -> Family.submitPublishedHostOperationFamily permit bus intent program
                      Just bytes -> Family.submitPublishedHostOperationFamilyWithStdin permit bytes bus intent program
              if mode `elem` ["none", "native-env"]
                then do
                  right =<< submit Nothing
                  waitFor (root </> "read") ending
                else
                  if mode == "cancel"
                    then do
                      held <- newEmptyMVar
                      Async.withAsync
                        ( Stdin.withHostControllerStdin
                            key
                            window
                            payload
                            (\input -> putMVar held input >> submit (Just input))
                        )
                        $ \worker -> do
                          input <- readMVar held
                          waitFor (root </> "held") ending
                          waitForAttempt input key window ending
                          Async.cancel worker
                          cancelled <- Async.waitCatch worker
                          case cancelled of Left _ -> pure (); Right _ -> assertFailure "blocked writer was not cancelled"
                    else do
                      delivered <- Stdin.withHostControllerStdin key window payload (\input -> submit (Just input))
                      case (mode, delivered) of
                        ("expire", Left Stdin.ControllerStdinExpired) -> waitFor (root </> "held") (hostExecutionOuterEnd window)
                        ("raw", Right completed) -> right completed >> waitFor (root </> "read") ending
                        _ -> assertFailure "unexpected native delivery disposition"
            right selected
        )
        (const (pure ()))
    void (right publication)
    waitUntil (hostExecutionOuterEnd window + 10000000)
    end <- (+ 5000000000) <$> getMonotonicTimeNSec
    field <-
      right
        =<< Bus.withSystemdBus
          end
          ("/run/user/" <> show uid <> "/bus")
          ( \bus -> Family.observeHostOperationField bus (Family.hostOperationField OrdinaryCascadeController key)
          )
    assertBool "original six-role field remains" (Family.hostOperationAbsent field)
    putStrLn ("STDIN_NATIVE_FIELD_ABSENT " <> hostExecutionKeyText key <> " " <> mode)

controller :: [String] -> IO ()
controller raw = do
  arguments <- right (Arguments.parseHostControllerArguments raw)
  let window = Arguments.controllerOriginalWindow arguments
      ending = hostExecutionWorkEnd window
      key = Arguments.controllerOperationKey arguments
  selected <- Family.withPinnedHostControllerProgram
    OrdinaryCascadeController
    ending
    (Arguments.controllerInputFingerprint arguments)
    (Arguments.controllerConfigurationPath arguments)
    (Arguments.controllerRequestPath arguments)
    $ \program -> do
      bytes <- right =<< Family.readHostControllerProgramInputs program
      observed <-
        right (Fixture.decodeObserved (Lazy.fromStrict (Family.hostControllerConfigurationBytes bytes)))
      FixtureRequest root mode <- right (eitherDecodeStrict (Family.hostControllerRequestBytes bytes))
      plan <- Fixture.fixturePlanFrom observed
      helper <- maybe (assertFailure "invalid helper") pure (Family.hostOperationHelperBounds 20000 20000)
      intent <- right =<< Family.newHostOperationIntent OrdinaryCascadeController plan helper key window
      uid <- getEffectiveUserID
      opened <- Bus.withSystemdBus (hostExecutionOuterEnd window) ("/run/user/" <> show uid <> "/bus") $ \bus -> lift $
        Kernel.withObservedOperationParent bus intent program $ \parent -> do
          streams <- right (Process.mkOperationStreamLimits 4096 4096 500000)
          processes <- right (Process.operationSubprocesses parent streams streams)
          right =<< Process.verifyOperationSubprocessesBeforeEffect processes
          if mode `elem` ["expire", "cancel"]
            then Bytes.writeFile (root </> "held") "held" >> waitUntil ending
            else do
              if mode == "native-env"
                then exerciseNativeEnvironment parent processes window
                else do
                  received <- Stdin.readHostControllerStdin ending
                  case (mode, received) of
                    ("raw", Right actual) -> actual @?= payload
                    ("none", Left Stdin.ControllerStdinDescriptorChanged) -> pure ()
                    _ -> assertFailure "unexpected original controller input result"
              right =<< Process.verifyOperationSubprocessesBeforeEffect processes
              Bytes.writeFile (root </> "read") "read"
          pure (Right ())
      -- The held arms observe entry only; closing after expiry grants no success.
      case mode of
        "expire" -> void (pure opened)
        "cancel" -> void (pure opened)
        _ -> void (right opened >>= right)
  void (right selected)

waitUntil :: Word64 -> IO ()
waitUntil ending = do
  now <- getMonotonicTimeNSec
  unless
    (now >= ending)
    (threadDelay (fromIntegral (min 50000 ((ending - now) `div` 1000 + 1))) >> waitUntil ending)

waitFor :: FilePath -> Word64 -> IO ()
waitFor path ending = do
  exists <- doesFileExist path
  unless exists $ do
    now <- getMonotonicTimeNSec
    if now >= ending
      then assertFailure "bounded fixture marker absent"
      else threadDelay 1000 >> waitFor path ending

waitForAttempt
  :: Stdin.HostControllerStdin -> HostExecutionKey -> HostExecutionWindow -> Word64 -> IO ()
waitForAttempt owner key window ending = do
  state <- Stdin.verifyHostControllerStdin key window owner
  case state of
    Left Stdin.ControllerStdinAlreadyAttempted -> pure ()
    Left _ -> assertFailure "carrier closed before cancellation control"
    Right () -> do
      now <- getMonotonicTimeNSec
      if now >= ending
        then assertFailure "writer did not claim the original attempt"
        else threadDelay 1000 >> waitForAttempt owner key window ending

exerciseNativeEnvironment
  :: Kernel.OperationParent -> Process.OperationSubprocesses -> HostExecutionWindow -> IO ()
exerciseNativeEnvironment parent owned window = do
  let check condition label = assertBool label condition
      expectSuccess label = either (assertFailure . (label <>) . show) pure
      expectOwned label expected result =
        assertBool label (either (hasPrimaryOwned expected) (const False) result)
      successOutput output bytes = do
        Process.operationProcessExitCode output @?= ExitSuccess
        Process.operationProcessStdout output @?= bytes
      clean = Kernel.verifyOperationParentBeforeEffect parent >>= (@?= Right ())
  let helperDirectory = Kernel.operationParentRuntimeDirectory parent </> "native-bin"
      helperPath = helperDirectory </> "prodbox-native-env-helper"
  createDirectoryIfMissing True helperDirectory
  writeFile
    helperPath
    "#!/bin/sh\n[ -z \"${PRODBOX_NATIVE_REMOVE+x}\" ] || exit 9\nprintf '%s|%s' \"$PRODBOX_NATIVE_MARKER\" \"$PRODBOX_NATIVE_INHERITED\"\n"
  setFileMode helperPath 0o700
  -- Complete synthetic payload, present before capture; all values remain
  -- private to this fixture process and are never logged or hashed.
  setEnv "PATH" helperDirectory
  setEnv "PRODBOX_NATIVE_INHERITED" "retained-fixture"
  setEnv "PRODBOX_NATIVE_REMOVE" "remove-fixture"
  mapM_
    (`setEnv` "synthetic-only")
    [ "KUBECONFIG"
    , "AWS_ACCESS_KEY_ID"
    , "AWS_SECRET_ACCESS_KEY"
    , "AWS_SESSION_TOKEN"
    , "AWS_PROFILE"
    , "AWS_DEFAULT_PROFILE"
    , "AWS_SHARED_CREDENTIALS_FILE"
    , "AWS_CONFIG_FILE"
    ]
  forM_ [1 :: Int .. 56] $ \ordinal ->
    setEnv ("PRODBOX_NATIVE_PAYLOAD_" <> show ordinal) (replicate 32768 'x')
  inherited <- right =<< Environment.captureProcessEnvironmentBefore (hostExecutionWorkEnd window)
  let filtered = Environment.filterProcessEnvironment (/= "PRODBOX_NATIVE_REMOVE") inherited
  environment <-
    right
      =<< Environment.overlayProcessEnvironment [("PRODBOX_NATIVE_MARKER", "synthetic-marker")] filtered
  -- A fresh ambient read would now lose the helper path and source value.
  setEnv "PATH" "/prodbox-not-the-captured-path"
  setEnv "PRODBOX_NATIVE_INHERITED" "changed-after-capture"
  let native path arguments =
        Process.NativeSubprocess
          path
          arguments
          environment
          (Just (Kernel.operationParentRuntimeDirectory parent))
      helper = native "/bin/sh" ["-c", "prodbox-native-env-helper"]
      sleeping = native "/bin/sleep" ["10"]
      ready = native "/bin/sh" ["-c", "printf 'READY_NATIVE\\n'; exec /bin/sleep 10"]
      kubectlPath = helperDirectory </> "native-kubectl-stub"
      homeBytes =
        "{\"current-context\":\"fixture\",\"clusters\":[{\"name\":\"fixture\",\"cluster\":{\"server\":\"https://127.0.0.1:6443\",\"certificate-authority-data\":\"synthetic-ca\"}}],\"contexts\":[{\"name\":\"fixture\",\"context\":{\"cluster\":\"fixture\",\"user\":\"fixture\"}}],\"users\":[{\"name\":\"fixture\",\"user\":{\"client-certificate-data\":\"synthetic-cert\",\"client-key-data\":\"synthetic-key\"}}]}"
      binaryLimits =
        Process.BoundedSubprocessLimits
          { Process.boundedSubprocessMaximumInputBytes = 4096
          , Process.boundedSubprocessMaximumStdoutBytes = 4096
          , Process.boundedSubprocessMaximumStderrBytes = 4096
          , Process.boundedSubprocessTimeoutMicros = 1000000
          }
  writeFile
    kubectlPath
    "#!/bin/sh\n[ -z \"${KUBECONFIG+x}${AWS_ACCESS_KEY_ID+x}${AWS_SECRET_ACCESS_KEY+x}${AWS_SESSION_TOKEN+x}${AWS_PROFILE+x}${AWS_DEFAULT_PROFILE+x}${AWS_SHARED_CREDENTIALS_FILE+x}${AWS_CONFIG_FILE+x}\" ] || exit 13\n[ \"$1\" = --kubeconfig ] && [ -r \"$2\" ] || exit 14\nshift 2\nif [ \"$1\" = binary ]; then exec /bin/cat; else printf synthetic-sdk; fi\n"
  setFileMode kubectlPath 0o700
  projection <- right (Kubectl.prepareEmbeddedHomeKubeconfig homeBytes)
  patternValue <- right (Startup.mkStartupLineExpectation ["READY_NATIVE"])
  escaped <- newIORef Nothing
  result <- Process.withOperationNativeTransportStartup owned ready patternValue $ \lease -> do
    waitNativeStartup (hostExecutionWorkEnd window) lease
    writeIORef escaped (Just lease)
    first <-
      Process.captureOperationNativeCommand owned helper >>= expectSuccess "native-captured-helper"
    successOutput first "synthetic-marker|retained-fixture"
    let nativeInput = Bytes.pack (take 4096 (cycle [0 .. 255]))
    piped <-
      Process.captureOperationNativeCommandWithInputBefore
        4096
        4096
        4096
        (hostExecutionWorkEnd window)
        owned
        nativeInput
        (native "/bin/cat" [])
        >>= expectSuccess "native-binary-input"
    successOutput piped nativeInput
    Kubectl.withNativeHomeCleanupKubectlInOperation
      owned
      kubectlPath
      environment
      Nothing
      projection
      $ \selected -> do
        client <- right selected
        observed <- Kubectl.runEphemeralKubectl client ["probe"]
        observed @?= Right "synthetic-sdk"
    home <- Kubectl.withNativeOperationHomeKubectl
      owned
      kubectlPath
      environment
      Nothing
      projection
      $ \selected -> do
        client <- right selected
        assertBool
          "native home client changed original binding"
          (Kubectl.operationHomeKubectlMatches owned client)
        observed <-
          right =<< Kubectl.runOperationHomeKubectlWithInput client binaryLimits nativeInput ["binary"]
        Process.processExitCode observed @?= ExitSuccess
        Bytes.pack (map (fromIntegral . fromEnum) (Process.processStdout observed)) @?= nativeInput
        raw <-
          right =<< Kubectl.runOperationHomeKubectlBytesWithInput client binaryLimits nativeInput ["binary"]
        Process.operationProcessExitCode raw @?= ExitSuccess
        Process.operationProcessStdout raw @?= nativeInput
        Process.operationProcessStderr raw @?= Bytes.empty
        pure client
    stale <- Kubectl.runOperationHomeKubectlWithInput home binaryLimits nativeInput ["binary"]
    assertBool "native home client escaped its file/use scope" (either (const True) (const False) stale)
    rawStale <- Kubectl.runOperationHomeKubectlBytesWithInput home binaryLimits nativeInput ["binary"]
    assertBool
      "native byte-output client escaped its file/use scope"
      (either (const True) (const False) rawStale)
    putStrLn "NATIVE_HOME_BYTE_OUTPUT_CHECKED"
    overflow <-
      Process.captureOperationNativeCommandWithCeilingsBefore
        3
        3
        (hostExecutionWorkEnd window)
        owned
        (native "/bin/printf" ["four"])
    expectOwned "native-output-ceiling" Process.OwnedSubprocessStdoutExceeded overflow
    rejected <-
      Process.captureOperationNativeCommand owned (native "/bin/printf" ["bad\NULargument"])
    expectOwned "native-NUL-refusal" Process.OwnedSubprocessStartFailed rejected
    now <- getMonotonicTimeNSec
    expired <- Process.captureOperationNativeCommandBefore now owned helper
    expectOwned "native-original-work-refusal" Process.OwnedSubprocessDeadlineReached expired
    clean
  _ <- expectSuccess "native-startup-transport" result
  lease <- readIORef escaped >>= maybe (fail "native transport did not enter") pure
  refused <- Process.verifyOperationTransportBeforeEffect lease
  check
    (refused == Left (Process.OperationScopeRefused Kernel.KernelHostPlacementClosed))
    "native transport escaped its owner"
  second <- Process.withOperationNativeTransport owned sleeping $ \transport -> do
    guard <- Process.verifyOperationTransportBeforeEffect transport
    check (guard == Right ()) "native transport was not active"
    lastOutput <-
      Process.captureOperationNativeCommandWithCeilingsBefore
        4096
        4096
        (hostExecutionWorkEnd window)
        owned
        helper
        >>= expectSuccess "native-reuse-after-refusal"
    successOutput lastOutput "synthetic-marker|retained-fixture"
  _ <- expectSuccess "native-plain-transport" second
  clean

waitNativeStartup :: Word64 -> Process.OperationTransport -> IO ()
waitNativeStartup ending lease = do
  now <- getMonotonicTimeNSec
  unless (now < ending) (fail "native startup exceeded original work end")
  status <- right =<< Process.observeOperationTransportStartup lease
  case status of
    Startup.StartupLineAccepted -> pure ()
    Startup.StartupLinePending -> threadDelay 1000 >> waitNativeStartup ending lease
    _ -> fail "native transport startup refused"

hasPrimaryOwned :: Process.OwnedSubprocessError -> Process.OperationSubprocessError -> Bool
hasPrimaryOwned expected cause = case cause of
  Process.OperationProcessRefused value -> value == expected
  Process.OperationPrimaryAndCleanupRefused primary _ -> hasPrimaryOwned expected primary
  Process.OperationScopeRefused _ -> False
  Process.OperationTransportExited _ -> False
