{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar, threadDelay)
import Control.Exception (bracket)
import Control.Monad (foldM, replicateM_, unless, when)
import Control.Monad.Trans.Class (lift)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Char8 qualified as Bytes
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (isInfixOf)
import GHC.Clock (getMonotonicTimeNSec)
import Network.Socket qualified as Socket
import Numeric (showHex)
import Prodbox.Config.BootstrapProjection
  ( bootstrapKindPlan
  , bootstrapScope
  , readBootstrapProjection
  )
import Prodbox.Config.DeploymentScope
  ( FreshScopeResult (FreshScopePrepared)
  , prepareFreshScope
  , scopeRoot
  )
import Prodbox.Config.KindPlan (KindNodeCreateInput (..), kindNodeRunArguments)
import Prodbox.Control.DockerConnectedInfo
  ( DockerNodeContainerCreateResult (..)
  , DockerNodeContainerStartResult (..)
  )
import Prodbox.Control.DockerIdentity (DockerDaemonObservation (..), observeDockerSocketIdentity)
import Prodbox.Control.KindController (KindFamilyParentOutcome (KindFamilyParentCompleted))
import Prodbox.Control.KindControllerInput
import Prodbox.Control.KindControllerReceipt
  ( ControllerReceiptWrite (ControllerReceiptRecorded)
  , FamilyLaunchWrite (FamilyLaunchRecorded)
  , recordControllerReceipt
  , recordFamilyLaunch
  , recordFamilyPublicationAttempt
  )
import Prodbox.Control.KindControllerRequest
import Prodbox.Control.KindFamilyDispatcher
  ( KindProbeFamilyDispatchOutcome (..)
  , KindProbeFamilyWorkerOutcome (..)
  , kindProbeFamilyDispatchFailureCode
  )
import Prodbox.Control.KindFamilyLaunch (prepareFreshKindFamilyRequest)
import Prodbox.Control.KindFamilyRecovery
import Prodbox.Control.KindIntent
  ( KindIntentResult (KindIntentRecorded)
  , recordKindFamilyIntent
  , recordKindOwnerFamilyIntent
  )
import Prodbox.Control.KindKubeconfigFile (withKindKubeconfigSnapshotBound)
import Prodbox.Control.KindLease
  ( KindLeaseError (KindLeaseBusy, KindLeaseDeadlineExpired)
  , KindOperationOutcome (..)
  , KindOperationRefusal (KindOperationLeaseRefused)
  , withRecoveredKindOperation
  , withRecoveredKindOperationUntil
  )
import Prodbox.Control.KindNetworkProbeRecord
import Prodbox.Control.KindNodeCreateIntent
import Prodbox.Control.NetworkEnforcement
  ( ProbeAttemptReadbackOutcome (ProbeAttemptReadbackRecorded)
  , confirmAttemptedProbeAbsenceWith
  )
import Prodbox.Control.Status
  ( matchesScopedWorkerNode
  , observeNodeCaBindingUnderLease
  , observeNodeCreateUnderLease
  )
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , Subprocess (..)
  , captureSubprocessWithInputBounded
  , processExitCode
  , processStdout
  )
import Prodbox.Subprocess.HostControllerArguments qualified as Arguments
import Prodbox.Subprocess.HostControllerInputRetirement qualified as InputRetirement
import Prodbox.Subprocess.HostControllerInputs qualified as Inputs
import Prodbox.Subprocess.HostControllerPublication qualified as Publication
import Prodbox.Subprocess.SystemdBus qualified as Bus
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import Prodbox.Subprocess.SystemdProvider qualified as Provider
import System.Directory (createDirectory)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitSuccess)
import System.FilePath ((</>))
import System.IO (IOMode (ReadMode), hPutStrLn, stderr, withBinaryFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import System.Posix.User (getEffectiveUserID)
import System.Process
  ( CreateProcess (..)
  , StdStream (NoStream)
  , proc
  , readCreateProcessWithExitCode
  , readProcessWithExitCode
  , withCreateProcess
  )

main :: IO ()
main = withSystemTempDirectory "prodbox-probe-verifier-budget" $ \anchor -> do
  arguments <- getArgs
  let managed = arguments == ["--managed-scale"]
      scale = managed || arguments == ["--scale"]
  unless (null arguments || scale) (fail "unexpected fixture arguments")
  unless
    ( kindProbeFamilyDispatchFailureCode
        (KindProbeFamilyDispatchInput (KindInputRefused KindInputInvalidUtf8))
        == 12
        && kindProbeFamilyDispatchFailureCode
          (KindProbeFamilyDispatchInput (KindInputRefused (KindInputRequestRefused KindRequestBindingMismatch)))
          == 15
    )
    (fail "successor failure categories changed")
  let code outcome =
        kindProbeFamilyDispatchFailureCode
          ( KindProbeFamilyDispatchInput
              ( KindInputCompleted
                  ( Right
                      (KindFamilyParentCompleted (KindProbeFamilySuccessor (KindProbeSuccessorWorkerObserved outcome)))
                  )
              )
          )
      closed value = KindFamilyRetirementReturned value (Right ()) True
  unless
    ( code KindFamilyRetirementLeaseUnconfirmed == 37
        && code (closed KindFamilyRetirementLeaseUnconfirmed) == 38
        && code (closed (closed KindFamilyRetirementLeaseUnconfirmed)) == 39
        && code (closed (closed (closed KindProbeSuccessorChainUnconfirmed))) == 40
        && code
          ( closed
              ( closed
                  ( closed
                      ( KindProbeSuccessorChainReturned
                          (KindOperationRefused (KindOperationLeaseRefused KindLeaseBusy))
                          True
                      )
                  )
              )
          )
          == 41
    )
    (fail "successor lease-stage categories changed")
  random <- withBinaryFile "/dev/urandom" ReadMode (\handle -> BS.hGet handle 12)
  unless (BS.length random == 12) (fail "fixture identity unavailable")
  let hex byte = let digits = showHex byte "" in replicate (2 - length digits) '0' ++ digits
      suffix = concatMap hex (BS.unpack random)
      identity digit = replicate 8 digit ++ suffix
  port <- Socket.withSocketsDo $ bracket (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol) Socket.close $ \sock -> do
    Socket.bind sock (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
    address <- Socket.getSocketName sock
    case address of
      Socket.SockAddrInet chosen _ -> pure (fromIntegral chosen :: Int)
      _ -> fail "fixture port unavailable"
  let selected = anchor </> "selected.dhall"
      operation = identity 'b'
      cleanupId = identity 'c'
      verifierId = identity 'd'
      successorId = identity 'e'
      unsentId = identity 'f'
      cancelledId = identity '9'
      cancelledBirthId = identity '8'
      generation = replicate 32 'a'
      namespace = "prodbox-netcheck-" ++ take 12 operation
      uid = "12345678-1234-1234-1234-123456789abc"
      tool = "sha256:50030de23cf40a18505f20426f6a8506bedf13c6e509244bd1fa9463721b0f54"
      document =
        "{ bootstrap = { schema_version = 3, project_anchor = \""
          ++ anchor
          ++ "\", runtime_socket = \""
          ++ anchor
          ++ "/docker.sock\", environment = \"test\", deployment_id = \"run\", root_generation = \""
          ++ generation
          ++ "\", api_port = "
          ++ show port
          ++ ", node_image = \"kindest/node@sha256:"
          ++ replicate 64 'a'
          ++ "\", http_host_port = 28080, http_node_port = 30080, https_host_port = 28443, https_node_port = 30443, listen_address = \"127.0.0.1\", node_artifact = { path = \"artifacts/node.tar\", digest = \"sha256:"
          ++ replicate 64 'c'
          ++ "\", maximum_bytes = 1048576 }, kind_tool = { path = \"artifacts/kind\", digest = \""
          ++ tool
          ++ "\", maximum_bytes = 1048576 } } }"
  writeFile selected document
  bootstrap <- readBootstrapProjection selected >>= either (fail . show) pure
  prepared <- prepareFreshScope (bootstrapScope bootstrap) generation
  unless (prepared == FreshScopePrepared) (fail "fixture root refused")
  hPutStrLn stderr ("Fixture operation " ++ operation)
  intent <-
    if managed
      then recordKindOwnerFamilyIntent bootstrap operation
      else recordKindFamilyIntent bootstrap operation
  unless (intent == KindIntentRecorded) (fail "family intent refused")
  locked <- newEmptyMVar
  release <- newEmptyMVar
  done <- newEmptyMVar
  _ <- forkIO $ do
    outcome <- withRecoveredKindOperation bootstrap operation $ \_ -> putMVar locked () >> takeMVar release
    putMVar done outcome
  takeMVar locked
  busy <- withRecoveredKindOperation bootstrap operation (\_ -> pure ())
  putMVar release ()
  holder <- takeMVar done
  unless
    ( busy == KindOperationRefused (KindOperationLeaseRefused KindLeaseBusy)
        && holder == KindOperationCallbackReturned ()
    )
    (fail ("lease contention baseline changed: " ++ show busy ++ "; holder: " ++ show holder))
  lockedAgain <- newEmptyMVar
  releaseAgain <- newEmptyMVar
  doneAgain <- newEmptyMVar
  _ <- forkIO $ do
    outcome <- withRecoveredKindOperation bootstrap operation $ \_ -> putMVar lockedAgain () >> takeMVar releaseAgain
    putMVar doneAgain outcome
  takeMVar lockedAgain
  _ <- forkIO (threadDelay 250000 >> putMVar releaseAgain ())
  calls <- newIORef (0 :: Int)
  retryStart <- getMonotonicTimeNSec
  retried <- withRecoveredKindOperationUntil (retryStart + 5000000000) bootstrap operation $ \_ ->
    atomicModifyIORef' calls (\count -> (count + 1, ()))
  holderAgain <- takeMVar doneAgain
  count <- readIORef calls
  expired <-
    withRecoveredKindOperationUntil
      retryStart
      bootstrap
      operation
      (\_ -> fail "expired lease entered callback" :: IO ())
  unless
    ( retried == KindOperationCallbackReturned ()
        && holderAgain == KindOperationCallbackReturned ()
        && count == 1
        && expired == KindOperationRefused (KindOperationLeaseRefused KindLeaseDeadlineExpired)
    )
    ( fail
        ( "bounded lease wait changed: "
            ++ show retried
            ++ "; holder: "
            ++ show holderAgain
            ++ "; callback count: "
            ++ show count
            ++ "; expired: "
            ++ show expired
        )
    )
  lockedDeadline <- newEmptyMVar
  releaseDeadline <- newEmptyMVar
  doneDeadline <- newEmptyMVar
  _ <- forkIO $ do
    outcome <- withRecoveredKindOperation bootstrap operation $ \_ -> putMVar lockedDeadline () >> takeMVar releaseDeadline
    putMVar doneDeadline outcome
  takeMVar lockedDeadline
  deadlineStart <- getMonotonicTimeNSec
  busyExpired <-
    withRecoveredKindOperationUntil
      (deadlineStart + 250000000)
      bootstrap
      operation
      (\_ -> fail "busy deadline entered callback" :: IO ())
  putMVar releaseDeadline ()
  deadlineHolder <- takeMVar doneDeadline
  unless
    ( busyExpired == KindOperationRefused (KindOperationLeaseRefused KindLeaseDeadlineExpired)
        && deadlineHolder == KindOperationCallbackReturned ()
    )
    (fail ("busy lease deadline changed: " ++ show busyExpired ++ "; holder: " ++ show deadlineHolder))
  returnedCalls <- newIORef (0 :: Int)
  returnedStart <- getMonotonicTimeNSec
  returned <- withRecoveredKindOperationUntil (returnedStart + 5000000000) bootstrap operation $ \_ ->
    atomicModifyIORef' returnedCalls (\count -> (count + 1, False))
  returnedCount <- readIORef returnedCalls
  unless
    (returned == KindOperationCallbackReturned False && returnedCount == 1)
    (fail "completed callback was retried")
  now <- getMonotonicTimeNSec
  let second = 1000000000
  operator <- getEffectiveUserID
  domain <-
    Bus.withSystemdBus
      (now + 590 * second)
      ("/run/user/" ++ show operator ++ "/bus")
      Bus.observeManagerDomain
      >>= either (fail . show) pure
  window <-
    maybe
      (fail "window")
      pure
      ( Identity.hostExecutionWindow
          (now + 590 * second)
          (now + 500 * second)
          (now + 510 * second)
          (now + 540 * second)
          (now + 560 * second)
      )
  request <-
    either
      (fail . show)
      pure
      (mkKindControllerRequest bootstrap operation ("sha256:" ++ replicate 64 'a') domain window)
  familyKey <- maybe (fail "family key") pure (kindControllerOperationKey operation)
  familyRecords <- withRecoveredKindOperation bootstrap operation $ \stable -> do
    launch <- recordFamilyLaunch bootstrap request stable
    marker <- recordFamilyPublicationAttempt bootstrap request stable
    pure (launch, marker)
  unless
    (familyRecords == KindOperationCallbackReturned (FamilyLaunchRecorded, FamilyLaunchRecorded))
    (fail "family fixture records refused")
  familyPublished <-
    Publication.withPublishedHostControllerOwner
      Identity.KindController
      (now + 500 * second)
      familyKey
      (Bytes.pack document)
      (encodeKindControllerRequest request)
      ( \owner -> do
          let (configuration, input) = Publication.hostPublicationPaths owner
          held <- Inputs.withHostControllerInputs (now + 500 * second) configuration input $ \inputs -> do
            connected <- Bus.withSystemdBus (now + 500 * second) ("/run/user/" ++ show operator ++ "/bus") $ \connection -> do
              sender <- Bus.observeBusSender connection
              lift $ do
                qualified <- Provider.withQualifiedProvider connection $ \provider -> do
                  registered <-
                    Inputs.registerHostControllerSubmission
                      Identity.KindController
                      inputs
                      familyKey
                      window
                      domain
                      sender
                      provider
                  _ <- either (fail . show) pure registered
                  pure ()
                either (fail . show) pure qualified
            either (fail . show) pure connected
          either (fail . show) pure held
          retirementLocked <- newEmptyMVar
          retirementRelease <- newEmptyMVar
          retirementDone <- newEmptyMVar
          _ <- forkIO $ do
            outcome <- withRecoveredKindOperation bootstrap operation $ \_ -> putMVar retirementLocked () >> takeMVar retirementRelease
            putMVar retirementDone outcome
          takeMVar retirementLocked
          _ <- forkIO (threadDelay 250000 >> putMVar retirementRelease ())
          observed <- withKindFamilyRetirement (now + 500 * second) bootstrap operation $ \retiredOwner ->
            withRecoveredKindOperation
              bootstrap
              operation
              (retireKindFamilyPublishedInputs (now + 500 * second) retiredOwner)
          heldResult <- takeMVar retirementDone
          case observed of
            KindFamilyRetirementReturned
              (KindOperationCallbackReturned (KindFamilyInputRetirement (Right ()) (Right ()) True))
              (Right ())
              True
                | heldResult == KindOperationCallbackReturned () -> pure ()
            other -> fail ("family retirement did not wait for the busy lease: " ++ show other)
      )
      (requireNeverSent "family fixture unexpectedly sent")
  either (fail . show) (const (pure ())) familyPublished
  recovery <- either (fail . show) pure (mkProbeRecoveryRequest request cleanupId uid)
  coordinates <- either (fail . show) pure (mkProbeRecoveryRequest request verifierId uid)
  verifier <- either (fail . show) pure (mkIsolatedProbeVerifierRequest coordinates cleanupId)
  result <- withRecoveredKindOperation bootstrap operation $ \stable -> do
    mapM_
      ( \record -> do
          written <- recordProbeRecord bootstrap operation namespace record stable
          unless (written == ProbeRecorded) (fail ("fixture record refused: " ++ show written))
      )
      [ProbeIntent, ProbeCreated uid, ProbeRecoveryLaunch recovery, ProbePublicationAttempt recovery]
    written <-
      recordProbeRecord
        bootstrap
        operation
        namespace
        (ProbeVerifierLaunch verifier)
        (threadDelay 250000 >> stable)
    observed <- observeProbeRecord bootstrap operation namespace (ProbeVerifierLaunch verifier) stable
    refused <-
      recordProbeRecord bootstrap operation namespace (ProbeVerifierLaunch verifier) (pure False)
    checks <- newIORef (0 :: Int)
    let changing = do
          allowed <- atomicModifyIORef' checks (\count -> (count + 1, count == 0))
          if allowed then stable else pure False
    changed <-
      recordProbeRecord bootstrap operation namespace (ProbeVerifierPublicationAttempt verifier) changing
    marker <- observeProbeVerifierPublicationAttempt bootstrap operation namespace stable
    pure (written, observed, refused, changed, marker)
  unless
    ( result
        == KindOperationCallbackReturned
          (ProbeRecorded, ProbeMatches, ProbeRefused, ProbeRefused, ProbeVerifierLaunchMissing)
    )
    (fail ("slow or changing admission did not preserve verifier identity: " ++ show result))
  successorCoordinates <- either (fail . show) pure (mkProbeRecoveryRequest request successorId uid)
  successorVerifier <-
    either (fail . show) pure (mkIsolatedProbeVerifierRequest successorCoordinates cleanupId)
  successor <- either (fail . show) pure (mkProbeSuccessorRequest successorVerifier verifierId)
  staged <- withRecoveredKindOperation bootstrap operation $ \stable -> do
    mapM_
      ( \record ->
          recordProbeRecord bootstrap operation namespace record stable >>= \written ->
            unless (written == ProbeRecorded) (fail ("successor fixture refused: " ++ show written))
      )
      [ProbeVerifierPublicationAttempt verifier, ProbeSuccessorLaunch successor]
  unless (staged == KindOperationCallbackReturned ()) (fail "successor fixture lease refused")
  stagedChain <-
    withKindProbeSuccessorRetirementStaged
      (now + 500 * second)
      bootstrap
      operation
      verifier
      []
      successor
      (pure True)
      (\owners -> pure (null owners))
  case stagedChain of
    KindProbeSuccessorChainReturned True True -> pure ()
    other -> fail ("staged successor not recoverable: " ++ show other)
  wrongTransition <-
    withKindProbeSuccessorRetirementTransition
      (now + 500 * second)
      bootstrap
      operation
      verifier
      []
      successor
      (pure True)
      (\_ -> fail "staged successor treated as fresh" :: IO ())
  case wrongTransition of
    KindProbeSuccessorChainUnconfirmed -> pure ()
    other -> fail ("staged successor accepted as fresh: " ++ show other)
  markerResult <- withRecoveredKindOperation bootstrap operation $ \stable ->
    recordProbeRecord bootstrap operation namespace (ProbeSuccessorPublication successor) stable
  unless
    (markerResult == KindOperationCallbackReturned ProbeRecorded)
    (fail "successor publication marker refused")
  key <- maybe (fail "successor key") pure (kindProbeRecoveryKey operation successorId)
  published <-
    Publication.withPublishedHostControllerOwner
      Identity.KindProbeSuccessorController
      (now + 500 * second)
      key
      (Bytes.pack document)
      (encodeProbeSuccessorRequest successor)
      ( \owner -> do
          let (configuration, input) = Publication.hostPublicationPaths owner
          held <- Inputs.withHostControllerInputs (now + 500 * second) configuration input $ \inputs -> do
            connected <- Bus.withSystemdBus (now + 500 * second) ("/run/user/" ++ show operator ++ "/bus") $ \connection -> do
              sender <- Bus.observeBusSender connection
              lift $ do
                qualified <- Provider.withQualifiedProvider connection $ \provider -> do
                  registered <-
                    Inputs.registerHostControllerSubmission
                      Identity.KindProbeSuccessorController
                      inputs
                      key
                      window
                      domain
                      sender
                      provider
                  _ <- either (fail . show) pure registered
                  active <-
                    withKindProbeSuccessorRetirement
                      (now + 500 * second)
                      bootstrap
                      operation
                      successor
                      (\_ -> fail "active successor retired" :: IO ())
                  case active of
                    KindFamilyRetirementRefused _ -> pure ()
                    other -> fail ("active successor accepted: " ++ show other)
                  activeChain <-
                    withKindProbeSuccessorRetirementChain
                      (now + 500 * second)
                      bootstrap
                      operation
                      verifier
                      [successor]
                      (pure True)
                      (\_ -> fail "active chain entered callback" :: IO ())
                  case activeChain of
                    KindProbeSuccessorChainRefused _ True -> pure ()
                    other -> fail ("active chain accepted: " ++ show other)
                either (fail . show) pure qualified
            either (fail . show) pure connected
          either (fail . show) pure held
          retired <- withKindProbeSuccessorRetirement (now + 500 * second) bootstrap operation successor $ \owner' ->
            withRecoveredKindOperation bootstrap operation $ \stable -> do
              verified <- verifyKindProbeSuccessorRetirement owner' stable
              unless (verified == Right ()) (fail "successor retirement unconfirmed")
              removed <- retireKindProbeSuccessorPublishedInputs (now + 500 * second) owner' stable
              unless
                (removed == KindFamilyInputRetirement (Right ()) (Right ()) True)
                (fail ("successor input retirement failed: " ++ show removed))
          case retired of
            KindFamilyRetirementReturned (KindOperationCallbackReturned ()) (Right ()) True -> pure ()
            other -> fail ("successor retirement failed: " ++ show other)
          chain <- withKindProbeSuccessorRetirementChain
            (now + 500 * second)
            bootstrap
            operation
            verifier
            [successor]
            (pure True)
            $ \owners ->
              withRecoveredKindOperation bootstrap operation $ \stable -> do
                slow <-
                  verifyKindProbeSuccessorRetirementChain
                    bootstrap
                    operation
                    verifier
                    [successor]
                    owners
                    (threadDelay 250000 >> stable)
                checks <- newIORef (0 :: Int)
                let changing = do
                      allowed <- atomicModifyIORef' checks (\count -> (count + 1, count < 1))
                      if allowed then stable else pure False
                changed <-
                  verifyKindProbeSuccessorRetirementChain bootstrap operation verifier [successor] owners changing
                pure (slow, changed)
          case chain of
            KindProbeSuccessorChainReturned (KindOperationCallbackReturned (True, False)) True -> pure ()
            other -> fail ("successor chain failed: " ++ show other)
      )
      (requireNeverSent "fixture unexpectedly sent")
  either (fail . show) (const (pure ())) published
  unsentCoordinates <- either (fail . show) pure (mkProbeRecoveryRequest request unsentId uid)
  unsentVerifier <-
    either (fail . show) pure (mkIsolatedProbeVerifierRequest unsentCoordinates cleanupId)
  unsent <- either (fail . show) pure (mkProbeSuccessorRequest unsentVerifier successorId)
  unsentKey <- maybe (fail "never-sent successor key") pure (kindProbeRecoveryKey operation unsentId)
  unsentStaged <- withRecoveredKindOperation bootstrap operation $ \stable ->
    mapM_
      ( \record ->
          recordProbeRecord bootstrap operation namespace record stable >>= \written ->
            unless (written == ProbeRecorded) (fail ("never-sent successor fixture refused: " ++ show written))
      )
      [ProbeSuccessorLaunch unsent, ProbeSuccessorPublication unsent]
  unless
    (unsentStaged == KindOperationCallbackReturned ())
    (fail "never-sent successor lease refused")
  unsentPublication <-
    Publication.withPublishedHostControllerOwner
      Identity.KindProbeSuccessorController
      (now + 500 * second)
      unsentKey
      (Bytes.pack document)
      (encodeProbeSuccessorRequest unsent)
      (\_ -> pure ())
      (requireNeverSent "never-sent fixture sent")
  either (fail . show) (const (pure ())) unsentPublication
  let retireMixedOwners owners = case owners of
        [_, neverSentOwner] -> withRecoveredKindOperation bootstrap operation $ \stable -> do
          removed <- retireKindProbeSuccessorPublishedInputs (now + 500 * second) neverSentOwner stable
          verified <-
            verifyKindProbeSuccessorRetirementChain
              bootstrap
              operation
              verifier
              [successor, unsent]
              owners
              stable
          pure (removed, verified)
        _ -> fail "mixed successor owners missing"
  mixed <-
    withKindProbeSuccessorRetirementChain
      (now + 500 * second)
      bootstrap
      operation
      verifier
      [successor, unsent]
      (pure True)
      retireMixedOwners
  case mixed of
    KindProbeSuccessorChainReturned
      (KindOperationCallbackReturned (KindFamilyInputRetirement (Right ()) (Right ()) True, True))
      True -> pure ()
    other -> fail ("never-sent successor chain failed: " ++ show other)
  cancelledCoordinates <- either (fail . show) pure (mkProbeRecoveryRequest request cancelledId uid)
  cancelledVerifier <-
    either (fail . show) pure (mkIsolatedProbeVerifierRequest cancelledCoordinates cleanupId)
  cancelled <- either (fail . show) pure (mkProbeSuccessorRequest cancelledVerifier unsentId)
  cancelledStaged <- withRecoveredKindOperation bootstrap operation $ \stable -> do
    launch <- recordProbeRecord bootstrap operation namespace (ProbeSuccessorLaunch cancelled) stable
    cancellation <-
      recordProbeRecord bootstrap operation namespace (ProbeSuccessorCancellation cancelled) stable
    publication <-
      recordProbeRecord bootstrap operation namespace (ProbeSuccessorPublication cancelled) stable
    pure (launch, cancellation, publication)
  unless
    (cancelledStaged == KindOperationCallbackReturned (ProbeRecorded, ProbeRecorded, ProbeRefused))
    (fail "pre-publication cancellation did not fence publication")
  cancelledChain <- withKindProbeSuccessorRetirementChain
    (now + 500 * second)
    bootstrap
    operation
    verifier
    [successor, unsent, cancelled]
    (pure True)
    $ \owners ->
      withRecoveredKindOperation bootstrap operation $ \stable ->
        verifyKindProbeSuccessorRetirementChain
          bootstrap
          operation
          verifier
          [successor, unsent, cancelled]
          owners
          stable
  case cancelledChain of
    KindProbeSuccessorChainReturned (KindOperationCallbackReturned True) True -> pure ()
    other -> fail ("cancelled successor chain failed: " ++ show other)
  cancelledBirthCoordinates <-
    either (fail . show) pure (mkProbeRecoveryRequest request cancelledBirthId uid)
  cancelledBirthVerifier <-
    either (fail . show) pure (mkIsolatedProbeVerifierRequest cancelledBirthCoordinates cleanupId)
  cancelledBirth <-
    either (fail . show) pure (mkProbeSuccessorRequest cancelledBirthVerifier cancelledId)
  cancelledBirthKey <-
    maybe (fail "cancelled publication key") pure (kindProbeRecoveryKey operation cancelledBirthId)
  launchBirth <- withRecoveredKindOperation bootstrap operation $ \stable -> recordProbeRecord bootstrap operation namespace (ProbeSuccessorLaunch cancelledBirth) stable
  unless
    (launchBirth == KindOperationCallbackReturned ProbeRecorded)
    (fail "cancelled publication locator refused")
  dormant <-
    Publication.withPublishedHostControllerOwner
      Identity.KindProbeSuccessorController
      (now + 500 * second)
      cancelledBirthKey
      (Bytes.pack document)
      (encodeProbeSuccessorRequest cancelledBirth)
      (\_ -> pure ())
      (requireNeverSent "cancelled birth unexpectedly sent")
  either (fail . show) (const (pure ())) dormant
  cancelBirth <- withRecoveredKindOperation bootstrap operation $ \stable ->
    recordProbeRecord bootstrap operation namespace (ProbeSuccessorCancellation cancelledBirth) stable
  unless
    (cancelBirth == KindOperationCallbackReturned ProbeRecorded)
    (fail "cancelled publication fence refused")
  let complete = [successor, unsent, cancelled, cancelledBirth]
  let retireCancelledOwner owners = case reverse owners of
        owner : _ -> withRecoveredKindOperation bootstrap operation $ \stable -> do
          removed <- retireKindProbeSuccessorPublishedInputs (now + 500 * second) owner stable
          verified <-
            verifyKindProbeSuccessorRetirementChain bootstrap operation verifier complete owners stable
          pure (removed, verified)
        [] -> fail "cancelled publication owner missing"
  cancelledBirthChain <-
    withKindProbeSuccessorRetirementChain
      (now + 500 * second)
      bootstrap
      operation
      verifier
      complete
      (pure True)
      retireCancelledOwner
  case cancelledBirthChain of
    KindProbeSuccessorChainReturned
      (KindOperationCallbackReturned (KindFamilyInputRetirement (Right ()) (Right ()) True, True))
      True -> pure ()
    other -> fail ("cancelled publication chain failed: " ++ show other)
  when scale $ do
    (lastIdentity, expanded) <-
      foldM
        ( \(predecessor, entries) digit -> do
            let nextId = identity digit
            nextCoordinates <- either (fail . show) pure (mkProbeRecoveryRequest request nextId uid)
            nextVerifier <- either (fail . show) pure (mkIsolatedProbeVerifierRequest nextCoordinates cleanupId)
            next <- either (fail . show) pure (mkProbeSuccessorRequest nextVerifier predecessor)
            let submitted = digit /= 'a'
            added <- withRecoveredKindOperation bootstrap operation $ \stable -> do
              mapM_
                ( \record ->
                    recordProbeRecord bootstrap operation namespace record stable >>= \written ->
                      unless (written == ProbeRecorded) (fail ("scale chain record refused: " ++ show written))
                )
                [ ProbeSuccessorLaunch next
                , if submitted then ProbeSuccessorPublication next else ProbeSuccessorCancellation next
                ]
            unless (added == KindOperationCallbackReturned ()) (fail "scale chain lease refused")
            when submitted $ do
              nextKey <- maybe (fail "scale successor key") pure (kindProbeRecoveryKey operation nextId)
              stagedPublication <-
                Publication.withPublishedHostControllerOwner
                  Identity.KindProbeSuccessorController
                  (now + 500 * second)
                  nextKey
                  (Bytes.pack document)
                  (encodeProbeSuccessorRequest next)
                  ( \owner -> do
                      let (configuration, input) = Publication.hostPublicationPaths owner
                      held <- Inputs.withHostControllerInputs (now + 500 * second) configuration input $ \inputs -> do
                        connected <- Bus.withSystemdBus (now + 500 * second) ("/run/user/" ++ show operator ++ "/bus") $ \connection -> do
                          sender <- Bus.observeBusSender connection
                          lift $ do
                            qualified <- Provider.withQualifiedProvider connection $ \provider -> do
                              registered <-
                                Inputs.registerHostControllerSubmission
                                  Identity.KindProbeSuccessorController
                                  inputs
                                  nextKey
                                  window
                                  domain
                                  sender
                                  provider
                              either (fail . show) (const (pure ())) registered
                            either (fail . show) pure qualified
                        either (fail . show) pure connected
                      either (fail . show) pure held
                  )
                  (requireNeverSent "scale fixture unexpectedly sent")
              either (fail . show) (const (pure ())) stagedPublication
            pure (nextId, entries ++ [next])
        )
        (cancelledBirthId, complete)
        ("012345a" :: String)
    scaleCoordinates <- either (fail . show) pure (mkProbeRecoveryRequest request (identity '6') uid)
    scaleVerifier <-
      either (fail . show) pure (mkIsolatedProbeVerifierRequest scaleCoordinates cleanupId)
    scaleCandidate <- either (fail . show) pure (mkProbeSuccessorRequest scaleVerifier lastIdentity)
    unless managed $ do
      scaleStaged <- withRecoveredKindOperation bootstrap operation $ \stable ->
        mapM_
          ( \record ->
              recordProbeRecord bootstrap operation namespace record stable >>= \written ->
                unless (written == ProbeRecorded) (fail ("scale candidate refused: " ++ show written))
          )
          [ProbeSuccessorLaunch scaleCandidate, ProbeSuccessorPublication scaleCandidate]
      unless (scaleStaged == KindOperationCallbackReturned ()) (fail "scale candidate lease refused")
    let registerRetired kind recoveryId encoded = do
          executionKey <- maybe (fail "scale parent key") pure (kindProbeRecoveryKey operation recoveryId)
          publication <-
            Publication.withPublishedHostControllerOwner
              kind
              (now + 500 * second)
              executionKey
              (Bytes.pack document)
              encoded
              ( \owner -> do
                  let (configuration, input) = Publication.hostPublicationPaths owner
                  held <- Inputs.withHostControllerInputs (now + 500 * second) configuration input $ \inputs -> do
                    connected <- Bus.withSystemdBus (now + 500 * second) ("/run/user/" ++ show operator ++ "/bus") $ \connection -> do
                      sender <- Bus.observeBusSender connection
                      lift $ do
                        qualified <- Provider.withQualifiedProvider connection $ \provider -> do
                          registered <-
                            Inputs.registerHostControllerSubmission kind inputs executionKey window domain sender provider
                          either (fail . show) (const (pure ())) registered
                        either (fail . show) pure qualified
                    either (fail . show) pure connected
                  either (fail . show) pure held
              )
              (requireNeverSent "scale parent unexpectedly sent")
          either (fail . show) (const (pure ())) publication
    registerRetired Identity.KindController cleanupId (encodeProbeRecoveryRequest recovery)
    registerRetired
      Identity.KindProbeVerifierController
      verifierId
      (encodeProbeAttemptVerifierRequest verifier)
    let cert = anchor </> "server.crt"
        keyFile = anchor </> "server.key"
        control = scopeRoot (bootstrapScope bootstrap) </> "control"
        kubeconfig = control </> "kubeconfig"
        endpoint = "https://127.0.0.1:" ++ show port
    (certCode, _, _) <-
      readProcessWithExitCode
        "/usr/bin/openssl"
        [ "req"
        , "-x509"
        , "-newkey"
        , "rsa:2048"
        , "-nodes"
        , "-days"
        , "1"
        , "-subj"
        , "/CN=fixture"
        , "-addext"
        , "subjectAltName=IP:127.0.0.1"
        , "-keyout"
        , keyFile
        , "-out"
        , cert
        ]
        ""
    unless (certCode == ExitSuccess) (fail "fixture TLS generation failed")
    ca <- BS.readFile cert
    clientKey <- BS.readFile keyFile
    let b64 = Bytes.unpack . Base64.encode
        context = "kind-prodbox-t-run"
        kubeDocument =
          unlines
            [ "apiVersion: v1"
            , "kind: Config"
            , "current-context: " ++ context
            , "clusters:"
            , "- name: " ++ context
            , "  cluster:"
            , "    server: " ++ endpoint
            , "    certificate-authority-data: " ++ b64 ca
            , "contexts:"
            , "- name: " ++ context
            , "  context:"
            , "    cluster: " ++ context
            , "    user: " ++ context
            , "users:"
            , "- name: " ++ context
            , "  user:"
            , "    client-certificate-data: " ++ b64 ca
            , "    client-key-data: " ++ b64 clientKey
            ]
        dockerScript = anchor </> "docker.py"
        dockerSocket = anchor </> "docker.sock"
        node = replicate 64 'c'
        image = "sha256:" ++ replicate 64 'a'
        network = replicate 64 'c'
        nodeInput =
          KindNodeCreateInput
            tool
            image
            network
            generation
            operation
            (kindNodeRunArguments (bootstrapKindPlan bootstrap) image)
        dockerServer =
          ( proc
              "/usr/bin/python3"
              [ dockerScript
              , dockerSocket
              , cert
              , scopeRoot (bootstrapScope bootstrap)
              , generation
              , operation
              , show port
              ]
          )
            { std_in = NoStream
            , std_out = NoStream
            , std_err = NoStream
            }
        docker =
          unlines
            [ "import http.server, io, json, socketserver, sys, tarfile, urllib.parse"
            , "socket_path, cert, root, generation, operation, port = sys.argv[1:]"
            , "node = 'c'*64; name = 'prodbox-t-run-control-plane'; network = 'c'*64"
            , "volume = 'prodbox-t-run-var-' + generation + '-' + operation"
            , "def binding(port): return [{'HostIp':'127.0.0.1','HostPort':str(port)}]"
            , "def mount(kind, name, source, target, rw): return {'Type':kind,'Name':name,'Source':source,'Destination':target,'RW':rw}"
            , "data = {'Id':node,'Name':'/'+name,'Image':'sha256:'+'a'*64,'Config':{'Hostname':name,'Tty':True,'ExposedPorts':{'30080/tcp':{},'30443/tcp':{},'6443/tcp':{}},'Labels':{'io.x-k8s.kind.cluster':'prodbox-t-run','io.x-k8s.kind.role':'control-plane','io.prodbox.generation':generation,'io.prodbox.operation':operation}},'HostConfig':{'PublishAllPorts':False,'Privileged':True,'CgroupnsMode':'private','NetworkMode':network,'RestartPolicy':{'Name':'on-failure','MaximumRetryCount':1},'SecurityOpt':['seccomp=unconfined','apparmor=unconfined'],'Tmpfs':{'/tmp':'','/run':''},'Init':False,'PortBindings':{'30080/tcp':binding(28080),'30443/tcp':binding(28443),'6443/tcp':binding(port)}},'State':{'Running':True,'Paused':False,'Restarting':False,'Dead':False,'Status':'running'},'Mounts':[mount('volume',volume,'/var/lib/docker/volumes/'+volume+'/_data','/var',True),mount('bind',None,root,'/var/lib/prodbox',True),mount('bind',None,'/lib/modules','/lib/modules',False)],'NetworkSettings':{'Networks':{'prodbox-t-run':{'NetworkID':network,'IPAddress':'172.18.0.2','GlobalIPv6Address':'fd00::2'}}}}"
            , "class Handler(http.server.BaseHTTPRequestHandler):"
            , " protocol_version = 'HTTP/1.1'"
            , " def log_message(self,*args): pass"
            , " def do_GET(self):"
            , "  path=urllib.parse.urlsplit(self.path).path"
            , "  if path == '/info': body=json.dumps({'ID':'daemon-a'}).encode()"
            , "  elif path == '/containers/'+node+'/json': body=json.dumps(data).encode()"
            , "  elif path == '/containers/'+node+'/archive':"
            , "   raw=open(cert,'rb').read(); buf=io.BytesIO()"
            , "   with tarfile.open(fileobj=buf,mode='w') as tar: item=tarfile.TarInfo('ca.crt'); item.size=len(raw); tar.addfile(item,io.BytesIO(raw))"
            , "   body=buf.getvalue()"
            , "  else: self.send_error(404); return"
            , "  self.send_response(200); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)"
            , "class Server(socketserver.ThreadingMixIn,socketserver.UnixStreamServer): daemon_threads=True"
            , "Server(socket_path,Handler).serve_forever()"
            ]
        apiScript = anchor </> "api.py"
        server =
          (proc "/usr/bin/python3" [apiScript, show port, cert, keyFile, namespace])
            { std_in = NoStream
            , std_out = NoStream
            , std_err = NoStream
            }
        api =
          unlines
            [ "import http.server, json, ssl, sys, urllib.parse"
            , "class Handler(http.server.BaseHTTPRequestHandler):"
            , " def log_message(self, *args): pass"
            , " def do_GET(self):"
            , "  request = urllib.parse.urlsplit(self.path); path = request.path"
            , "  if path == '/api': value = {'kind':'APIVersions','apiVersion':'v1','versions':['v1'],'serverAddressByClientCIDRs':[]}"
            , "  elif path == '/apis': value = {'kind':'APIGroupList','apiVersion':'v1','groups':[]}"
            , "  elif path == '/api/v1': value = {'kind':'APIResourceList','apiVersion':'v1','groupVersion':'v1','resources':[{'name':'namespaces','singularName':'namespace','namespaced':False,'kind':'Namespace','verbs':['get','list']}, {'name':'services','singularName':'service','namespaced':True,'kind':'Service','verbs':['get','list']}] }"
            , "  elif path == '/api/v1/namespaces/kube-system': value = {'kind':'Namespace','apiVersion':'v1','metadata':{'name':'kube-system','uid':'12345678-1234-1234-1234-123456789abc'}}"
            , "  elif path == '/api/v1/namespaces' and urllib.parse.parse_qs(request.query).get('fieldSelector') == ['metadata.name='+sys.argv[4]]: value = {'kind':'List','apiVersion':'v1','metadata':{},'items':[]}"
            , "  elif path == '/api/v1/namespaces/lifecycle-authority/services/lifecycle-authority':"
            , "   self.respond(404, {'kind':'Status','apiVersion':'v1','status':'Failure','reason':'NotFound','code':404}); return"
            , "  elif path == '/api/v1/namespaces/lifecycle-authority/services' and urllib.parse.parse_qs(request.query).get('fieldSelector') == ['metadata.name=lifecycle-authority']: value = {'kind':'ServiceList','apiVersion':'v1','metadata':{},'items':[]}"
            , "  else: self.send_error(404); return"
            , "  self.respond(200, value)"
            , " def respond(self, status, value):"
            , "  body = json.dumps(value).encode(); self.send_response(status); self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)"
            , "server = http.server.HTTPServer(('127.0.0.1',int(sys.argv[1])), Handler)"
            , "context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(sys.argv[2],sys.argv[3]); server.socket = context.wrap_socket(server.socket,server_side=True); server.serve_forever()"
            ]
    writeFile apiScript api
    writeFile dockerScript docker
    createDirectory control
    setFileMode control 0o700
    writeFile kubeconfig kubeDocument
    setFileMode kubeconfig 0o600
    scaled <- withCreateProcess dockerServer $ \_ _ _ _ -> withCreateProcess server $ \_ _ _ _ -> do
      threadDelay 500000
      socketIdentity <-
        observeDockerSocketIdentity dockerSocket >>= maybe (fail "fixture docker socket unavailable") pure
      intent <-
        maybe
          (fail "fixture node intent refused")
          pure
          (mkKindNodeCreateIntent bootstrap nodeInput (DockerDaemonObserved "daemon-a" socketIdentity))
      nodeRecorded <- withRecoveredKindOperation bootstrap operation $ \stable -> do
        created <- recordKindNodeCreateIntent bootstrap intent stable
        attempted <- recordKindNodeCreateAttempt bootstrap intent stable
        result <-
          recordKindNodeCreateResult bootstrap intent (DockerNodeContainerCreateReply 201 (Just node)) stable
        start <- recordKindNodeStartAttempt bootstrap intent node stable
        started <-
          recordKindNodeStartResult bootstrap intent node (DockerNodeContainerStartReply 204) stable
        pure (created, attempted, result, start, started)
      unless
        ( nodeRecorded
            == KindOperationCallbackReturned
              ( NodeCreateIntentRecorded
              , NodeCreateAttemptRecorded
              , NodeCreateResultRecorded
              , NodeStartAttemptRecorded
              , NodeStartResultRecorded
              )
        )
        (fail ("fixture node records refused: " ++ show nodeRecorded))
      preflight <-
        withRecoveredKindOperation bootstrap operation (observeNodeCreateUnderLease bootstrap operation)
      case preflight of
        KindOperationCallbackReturned observation | matchesScopedWorkerNode node observation -> pure ()
        other -> fail ("fixture node observation refused: " ++ show other)
      binding <- withKindKubeconfigSnapshotBound bootstrap $ \config _ ->
        withRecoveredKindOperation
          bootstrap
          operation
          (observeNodeCaBindingUnderLease bootstrap operation node config)
      unless
        (binding == Right (KindOperationCallbackReturned True))
        (fail ("fixture node CA binding refused: " ++ show binding))
      when managed $ do
        receipt <-
          withRecoveredKindOperation bootstrap operation (recordControllerReceipt bootstrap operation node)
        unless
          (receipt == KindOperationCallbackReturned ControllerReceiptRecorded)
          (fail ("fixture controller receipt refused: " ++ show receipt))
        (_, out, err) <-
          readCreateProcessWithExitCode
            ( (proc "./.build/prodbox" ["--config", selected, "control", "delete", "--yes"])
                { env = Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")]
                }
            )
            ""
        observed <- withRecoveredKindOperation bootstrap operation $ \stable -> do
          chain <- observeProbeSuccessorChain bootstrap operation namespace verifier stable
          case chain of
            Right entries
              | take (length expanded) entries == expanded
              , [latest] <- drop (length expanded) entries -> do
                  let latestId = probeRecoveryId (probeVerifierRecoveryRequest (probeSuccessorVerifier latest))
                  readback <- observeProbeRecord bootstrap operation namespace (ProbeSuccessorReadback latest) stable
                  pure (Just (latestId, readback))
            _ -> pure Nothing
        case observed of
          KindOperationCallbackReturned (Just (_, ProbeMatches)) -> putStrLn "PASS managed successor readback"
          _ -> fail ("managed successor readback unconfirmed: " ++ show observed ++ "\n" ++ out ++ err)
        exitSuccess
      withKindFamilyRetirement (now + 500 * second) bootstrap operation $ \originalOwner ->
        withKindProbeFamilyRetirement (now + 500 * second) bootstrap operation $ \cleanupOwner ->
          withKindProbeVerifierRetirement (now + 500 * second) bootstrap operation $ \verifierOwner -> do
            let parents = do
                  original <- verifyKindFamilyRetirement originalOwner (pure True)
                  cleanup <- verifyKindProbeFamilyRetirement cleanupOwner (pure True)
                  first <- verifyKindProbeVerifierRetirement verifierOwner (pure True)
                  pure (original == Right () && cleanup == Right () && first == Right ())
            withKindProbeSuccessorRetirementPrefix
              (now + 500 * second)
              bootstrap
              operation
              verifier
              expanded
              scaleCandidate
              parents
              $ \owners ->
                withRecoveredKindOperation bootstrap operation $ \stable -> do
                  let base = (&&) <$> stable <*> parents
                      admitted =
                        verifyKindProbeSuccessorRetirementPrefix
                          bootstrap
                          operation
                          verifier
                          expanded
                          scaleCandidate
                          owners
                          base
                  hPutStrLn stderr "Checking the selected namespace through the bound node and CA"
                  tls <- withKindKubeconfigSnapshotBound bootstrap $ \config snapshot -> do
                    let admission = do
                          before <- admitted
                          bound <-
                            if before
                              then observeNodeCaBindingUnderLease bootstrap operation node config admitted
                              else pure False
                          after <- admitted
                          pure (before && bound && after)
                        execute args input = do
                          output <-
                            captureSubprocessWithInputBounded
                              (BoundedSubprocessLimits 1 65536 8192 15000000)
                              input
                              ( Subprocess
                                  "/usr/bin/kubectl"
                                  (["--kubeconfig", snapshot, "--request-timeout=4s"] ++ args)
                                  (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")])
                                  Nothing
                              )
                          pure $ case output of
                            Left failure -> Left (show failure)
                            Right result ->
                              Right
                                (case processExitCode result of ExitSuccess -> 0; ExitFailure code -> code, processStdout result)
                    confirmAttemptedProbeAbsenceWith
                      operation
                      namespace
                      uid
                      cleanupId
                      (identity '6')
                      admission
                      execute
                      ( \_ _ _ -> do
                          hPutStrLn stderr "Recording the independently observed namespace absence"
                          recordProbeRecord bootstrap operation namespace (ProbeSuccessorReadback scaleCandidate) admission
                      )
                  unless
                    (tls == Right ProbeAttemptReadbackRecorded)
                    (fail ("bounded namespace observation refused: " ++ show tls))
                  hPutStrLn stderr "Rechecking predecessor retirement and retiring inputs"
                  replicateM_ 3 $ do
                    confirmed <- admitted
                    unless confirmed (fail "scale chain recheck refused")
                  mapM_
                    ( \owner -> do
                        retired <- retireKindProbeSuccessorPublishedInputs (now + 500 * second) owner stable
                        unless
                          (retired == KindFamilyInputRetirement (Right ()) (Right ()) True)
                          (fail ("scale input retirement unconfirmed: " ++ show retired))
                    )
                    owners
                  cleanupRetired <- retireKindProbeFamilyPublishedInputs (now + 500 * second) cleanupOwner stable
                  verifierRetired <- retireKindProbeVerifierPublishedInputs (now + 500 * second) verifierOwner stable
                  unless
                    ( cleanupRetired == KindFamilyInputRetirement (Right ()) (Right ()) True
                        && verifierRetired == KindFamilyInputRetirement (Right ()) (Right ()) True
                    )
                    (fail "scale parent input retirement unconfirmed")
    case scaled of
      KindFamilyRetirementReturned
        ( KindFamilyRetirementReturned
            ( KindFamilyRetirementReturned
                (KindProbeSuccessorChainReturned (KindOperationCallbackReturned ()) True)
                (Right ())
                True
              )
            (Right ())
            True
          )
        (Right ())
        True -> pure ()
      other -> fail ("scale chain retirement failed: " ++ show other)
    -- This optional scale case owns the remaining fixture, since its terminal
    -- predecessor is now different from the ordinary readback case below.
    putStrLn "PASS 11-link retained successor chain"
  when scale exitSuccess
  readbackCoordinates <- either (fail . show) pure (mkProbeRecoveryRequest request (identity '6') uid)
  readbackVerifier <-
    either (fail . show) pure (mkIsolatedProbeVerifierRequest readbackCoordinates cleanupId)
  readbackSuccessor <-
    either (fail . show) pure (mkProbeSuccessorRequest readbackVerifier cancelledBirthId)
  readbackStage <- withRecoveredKindOperation bootstrap operation $ \stable -> do
    mapM_
      ( \record ->
          recordProbeRecord bootstrap operation namespace record stable >>= \written ->
            unless (written == ProbeRecorded) (fail ("readback fixture refused: " ++ show written))
      )
      [ProbeSuccessorLaunch readbackSuccessor, ProbeSuccessorPublication readbackSuccessor]
    written <-
      recordProbeRecord
        bootstrap
        operation
        namespace
        (ProbeSuccessorReadback readbackSuccessor)
        (threadDelay 2000000 >> stable)
    observed <-
      observeProbeRecord bootstrap operation namespace (ProbeSuccessorReadback readbackSuccessor) stable
    let diagnostic = ProbeSuccessorDiagnosticRecord readbackSuccessor VerifierRecordIncomplete
        changingAfterWrite = do
          recorded <- observeProbeRecord bootstrap operation namespace diagnostic (pure True)
          if recorded == ProbeMissing then stable else pure False
    incomplete <- recordProbeRecord bootstrap operation namespace diagnostic changingAfterWrite
    diagnosticObserved <- observeProbeRecord bootstrap operation namespace diagnostic stable
    pure (written, observed, incomplete, diagnosticObserved)
  unless
    ( readbackStage
        == KindOperationCallbackReturned (ProbeRecorded, ProbeMatches, ProbeIncomplete, ProbeMatches)
    )
    (fail ("slow or changed readback admission was not preserved: " ++ show readbackStage))
  (freshController, freshEnd) <-
    prepareFreshKindFamilyRequest bootstrap operation >>= either (fail . show) pure
  inputCoordinates <-
    either (fail . show) pure (mkProbeRecoveryRequest freshController (identity '7') uid)
  inputVerifier <-
    either (fail . show) pure (mkIsolatedProbeVerifierRequest inputCoordinates cleanupId)
  inputSuccessor <- either (fail . show) pure (mkProbeSuccessorRequest inputVerifier cancelledBirthId)
  inputKey <- maybe (fail "successor input key") pure (kindProbeRecoveryKey operation (identity '7'))
  let retireInput disposition = case disposition of
        Publication.PublicationNeverSent proof ->
          InputRetirement.retireNeverSentHostControllerInputs freshEnd proof
            >>= either (fail . show) (const (pure ()))
        Publication.PublicationPossiblySent -> fail "successor input fixture sent"
  pinned <-
    Publication.withPublishedHostControllerOwner
      Identity.KindProbeSuccessorController
      freshEnd
      inputKey
      (Bytes.pack document)
      (encodeProbeSuccessorRequest inputSuccessor)
      ( \owner -> do
          let (configuration, input) = Publication.hostPublicationPaths owner
          held <- Inputs.withHostControllerInputs freshEnd configuration input $ \inputs -> do
            let arguments =
                  Arguments.HostControllerArguments
                    configuration
                    input
                    (Inputs.hostControllerInputFingerprint inputs)
                    inputKey
                    (kindRequestWindow freshController)
            identified <- isKindProbeSuccessorArguments arguments
            unless identified (fail "successor publication identity not recognized")
            accepted <- withPinnedKindProbeSuccessorInput arguments (kindRequestManagerDomain freshController) $ \loaded decoded _ stable -> do
              unchanged <- stable
              pure (loaded == bootstrap && decoded == inputSuccessor && unchanged == Right ())
            case accepted of
              KindInputCompleted True -> pure ()
              other -> fail ("successor input refused: " ++ show other)
            wrongKind <-
              withPinnedKindProbeVerifierInput
                arguments
                (kindRequestManagerDomain freshController)
                (\_ _ _ _ -> pure ())
            case wrongKind of
              KindInputRefused _ -> pure ()
              other -> fail ("successor accepted as verifier: " ++ show other)
            (exit, output, errors) <-
              readCreateProcessWithExitCode
                ( ( proc
                      "./.build/prodbox"
                      ("internal-kind-family-controller" : Arguments.renderHostControllerArguments arguments)
                  )
                    { env = Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")]
                    }
                )
                ""
            unless (exit == ExitFailure 11 && "Kind probe recovery incomplete" `isInfixOf` (output ++ errors)) $
              fail ("successor public refusal category changed: " ++ show exit ++ " " ++ output ++ errors)
          either (fail . show) pure held
      )
      retireInput
  either (fail . show) (const (pure ())) pinned
  putStrLn
    "PASS bounded lease waits, slow readback, changed admission, successor retirement and input recovery"

requireNeverSent :: String -> Publication.HostPublicationDisposition -> IO ()
requireNeverSent message disposition = case disposition of
  Publication.PublicationNeverSent _ -> pure ()
  Publication.PublicationPossiblySent -> fail message
