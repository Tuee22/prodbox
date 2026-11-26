{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- Synthetic held-input controls; no controller or infrastructure is started.
import Control.Monad (unless)
import Control.Monad.Trans.Class (lift)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (isInfixOf)
import Data.Text qualified as Text
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Capacity.Config qualified as Capacity
import Prodbox.Capacity.ObservedHost qualified as Observed
import Prodbox.Config.BootstrapProjection
  ( bootstrapScope
  , decodeOptionalBootstrapSource
  , readBootstrapProjection
  )
import Prodbox.Config.DeploymentScope
  ( FreshScopeResult (FreshScopePrepared)
  , prepareFreshScope
  , scopeRoot
  )
import Prodbox.Control.Delete (DeleteStep (..), deleteNewTestIdentity)
import Prodbox.Control.KindController
  ( KindFamilyParentError (..)
  , KindFamilyParentOutcome (..)
  , KindFamilyPostAction (..)
  , KindFamilyPreparationError (..)
  , KindFamilyWorkOutcome (..)
  , prepareKindFamilyControllerFromObserved
  , prepareKindProbeRecoveryControllerFromObserved
  , prepareKindProbeVerifierControllerFromObserved
  , withKindFamilyProcesses
  )
import Prodbox.Control.KindControllerInput
import Prodbox.Control.KindControllerReceipt
  ( ControllerReceiptWrite (ControllerReceiptRecorded)
  , ControllerSubmissionWrite (ControllerSubmissionRecorded, ControllerSubmissionRefused)
  , FamilyInputClosing (..)
  , FamilyLaunchObservation (FamilyLaunchMissing, FamilyLaunchObserved)
  , FamilyLaunchWrite (FamilyLaunchAlreadyExists, FamilyLaunchRecorded, FamilyLaunchRefused)
  , FamilyParentClosing (..)
  , FamilyPostClosing (..)
  , FamilyPostDisposition (..)
  , FamilyPrimary (..)
  , FamilyResult (..)
  , FamilyResultWrite (FamilyResultRecorded)
  , FamilyWorkerClosing (..)
  , observeFamilyLaunch
  , observeFamilyPrePublicationCancellation
  , observeFamilyPublicationAttempt
  , recordControllerSubmissionIntent
  , recordFamilyLaunch
  , recordFamilyPrePublicationCancellation
  , recordFamilyPublicationAttempt
  , recordFamilyResult
  )
import Prodbox.Control.KindControllerRequest
import Prodbox.Control.KindFamilyDispatcher
import Prodbox.Control.KindFamilyLaunch
import Prodbox.Control.KindFamilyRecovery
import Prodbox.Control.KindIntent
  ( KindIntentResult (KindIntentRecorded)
  , recordKindFamilyIntent
  , recordKindIntent
  , recordKindOwnerFamilyIntent
  )
import Prodbox.Control.KindKubeconfigInstall (KindKubeconfigInstall (KindKubeconfigInstalled))
import Prodbox.Control.KindLease
  ( KindLeaseHandoff (KindLeaseHandoffExpired)
  , KindOperationOutcome (KindOperationCallbackReturned, KindOperationRootChanged)
  , withRecoveredKindOperation
  )
import Prodbox.Control.KindNetworkProbeRecord
  ( ProbeRecord (..)
  , ProbeRecordObservation (ProbeMatches)
  , ProbeRecordWrite (ProbeAlreadyExists, ProbeRecorded, ProbeRefused)
  , ProbeRecoveryLaunchObservation (ProbeRecoveryLaunchMissing)
  , ProbeSuccessorObservation (..)
  , ProbeVerifierDiagnostic (..)
  , observeProbeRecord
  , observeProbeRecoveryLaunch
  , observeProbeSuccessorChain
  , recordProbeRecord
  )
import Prodbox.Control.KubernetesReadiness (ReadinessObservation (..))
import Prodbox.Control.NetworkEnforcement
  ( EnforcementCleanup (..)
  , EnforcementObservation (..)
  , EnforcementOutcome (..)
  , ProbeJournalObservation (..)
  , ProbeRecoveryOutcome (..)
  , observeProbeJournal
  )
import Prodbox.Control.NodeArchive
  ( InspectedArchiveResult (InspectedArchiveRefused)
  , NodeArchiveObservation (NodeArchiveNotDeclared)
  )
import Prodbox.Control.Reconcile
  ( ReconcileOutcome (ReconcileFamilyAdmissionRefused)
  , reconcileFamilyPrerequisites
  )
import Prodbox.Subprocess.HostControllerArguments qualified as Arguments
import Prodbox.Subprocess.HostControllerInputs qualified as Inputs
import Prodbox.Subprocess.HostControllerPublication qualified as Publication
import Prodbox.Subprocess.HostOperationFamily qualified as Family
import Prodbox.Subprocess.HostOperationRetirement qualified as Retirement
import Prodbox.Subprocess.SystemdBus qualified as Bus
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import Prodbox.Subprocess.SystemdProvider qualified as Provider
import System.Directory (doesFileExist, removeFile)
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.FilePath ((</>))
import System.IO.Error (ioeGetErrorType)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import System.Posix.Process (getProcessID)
import System.Posix.User (getEffectiveUserID)
import System.Process (CreateProcess (env), proc, readCreateProcessWithExitCode, readProcess)
import Text.Printf (printf)

require :: String -> Bool -> IO ()
require label condition = unless condition (fail label)

main :: IO ()
main = withSystemTempDirectory "prodbox-kind-input" $ \anchor -> do
  nonce <- getMonotonicTimeNSec
  process <- getProcessID
  let archiveObserved = InspectedArchiveRefused NodeArchiveNotDeclared
      failure = ioeGetErrorType (userError "fixture")
      changedInput =
        KindInputChangedAfter
          ( Right
              ( KindFamilyParentUnconfirmedAfter
                  (KindFamilyWorkIoUnconfirmedAfter archiveObserved failure)
                  KindFamilyParentDomainMismatch
              )
          )
          Family.HostOperationProgramUnavailable
      changedLease =
        KindInputCompleted
          ( Right
              ( KindFamilyParentCompleted
                  ( KindFamilyWorkObserved
                      archiveObserved
                      ( Just
                          ( KindOperationRootChanged
                              (Right (KindFamilyPostReceipt KindKubeconfigInstalled ControllerReceiptRecorded True))
                          )
                      )
                  )
              )
          )
      refusedParent = KindInputCompleted (Right (KindFamilyParentRefused KindFamilyParentDomainMismatch))
      refusedHandoff =
        KindInputCompleted
          (Right (KindFamilyParentCompleted (KindFamilyWorkHandoffRefused KindLeaseHandoffExpired)))
      refusedAdmission = KindInputCompleted (Right (KindFamilyParentCompleted KindFamilyWorkAdmissionRefused))
  require
    "worker and closing failures collapsed"
    ( summarizeFamilyResult changedInput
        == FamilyResult
          FamilyWorkerUnconfirmed
          FamilyWorkerIoUnconfirmed
          FamilyParentUnconfirmed
          FamilyInputUnconfirmed
          FamilyPostNotAttempted
          FamilyPostNotStarted
    )
  require
    "post receipt and lease closure collapsed"
    ( summarizeFamilyResult changedLease
        == FamilyResult
          FamilyWorkerUnconfirmed
          FamilyWorkerComplete
          FamilyParentComplete
          FamilyInputComplete
          FamilyPostReceiptComplete
          FamilyPostLeaseUnconfirmed
    )
  require
    "parent refusal inferred worker absence"
    ( summarizeFamilyResult refusedParent
        == FamilyResult
          FamilyParentRefused
          FamilyWorkerUnobserved
          FamilyParentUnconfirmed
          FamilyInputComplete
          FamilyPostNotAttempted
          FamilyPostNotStarted
    )
  require
    "handoff refusal was reported as started work"
    ( summarizeFamilyResult refusedHandoff
        == FamilyResult
          FamilyWorkerNotObserved
          FamilyWorkerNotStarted
          FamilyParentComplete
          FamilyInputComplete
          FamilyPostNotAttempted
          FamilyPostNotStarted
    )
  require
    "admission refusal was reported as started work"
    ( summarizeFamilyResult refusedAdmission
        == FamilyResult
          FamilyWorkerNotObserved
          FamilyWorkerNotStarted
          FamilyParentComplete
          FamilyInputComplete
          FamilyPostNotAttempted
          FamilyPostNotStarted
    )
  let ready = ReadinessObserved True 1 1 2 2
      proven =
        EnforcementOutcome
          (Just (EnforcementObservation True True True False True))
          Nothing
          EnforcementCleanupConfirmed
      failedCleanup = proven {enforcementCleanup = EnforcementCleanupUnconfirmed "unconfirmed"}
      observed probe =
        observeKindFamilyReadinessWith
          (pure True)
          (pure (Just "node"))
          (const (pure True))
          (pure ready)
          (const (pure probe))
      post probe =
        KindInputCompleted
          ( Right
              ( KindFamilyParentCompleted
                  ( KindFamilyWorkObserved
                      archiveObserved
                      (Just (KindOperationCallbackReturned (KindFamilyPostProbe probe True)))
                  )
              )
          )
  require
    "completed probe was not recorded distinctly"
    ( summarizeFamilyResult (post proven)
        == FamilyResult
          FamilyWorkerUnconfirmed
          FamilyWorkerComplete
          FamilyParentComplete
          FamilyInputComplete
          FamilyPostProbeComplete
          FamilyPostLeaseComplete
    )
  require
    "unconfirmed probe cleanup was recorded as complete"
    ( summarizeFamilyResult (post failedCleanup)
        == FamilyResult
          FamilyWorkerUnconfirmed
          FamilyWorkerComplete
          FamilyParentComplete
          FamilyInputComplete
          FamilyPostProbeFailed
          FamilyPostLeaseComplete
    )
  successful <- observed proven
  require "complete readiness was not recognized" (kindFamilyReadinessComplete successful)
  incomplete <- observed failedCleanup
  require "unconfirmed probe cleanup was accepted" (not (kindFamilyReadinessComplete incomplete))
  calledProbe <- newIORef False
  absent <-
    observeKindFamilyReadinessWith
      (pure True)
      (pure Nothing)
      (const (pure True))
      (pure ready)
      (\_ -> writeIORef calledProbe True >> pure proven)
  require "missing node was accepted" (not (kindFamilyReadinessComplete absent))
  readIORef calledProbe >>= require "probe ran without a bound node" . not
  ownership <- newIORef True
  changed <-
    observeKindFamilyReadinessWith
      (readIORef ownership)
      (pure (Just "node"))
      (const (pure True))
      (pure ready)
      (\_ -> writeIORef ownership False >> pure proven)
  require "changed ownership was accepted" (not (kindFamilyReadinessComplete changed))
  checks <- newIORef (0 :: Int)
  changedNode <-
    observeKindFamilyReadinessWith
      (pure True)
      (pure (Just "node"))
      (\_ -> atomicModifyIORef' checks (\count -> (count + 1, count < 2)))
      (pure ready)
      (const (pure proven))
  require
    "node change after the final readiness read was accepted"
    (not (kindFamilyReadinessComplete changedNode))
  let configuration = anchor </> "settings.dhall"
      requestPath = anchor </> "request.json"
      alteredPath = anchor </> "altered-request.json"
      recoveryPath = anchor </> "recovery-request.json"
      verifierPath = anchor </> "verifier-request.json"
      operation = printf "%016x%016x" (fromIntegral process :: Integer) nonce
      legacyConfig =
        "{ bootstrap = { schema_version = 1, project_anchor = \""
          ++ anchor
          ++ "\", runtime_socket = \""
          ++ anchor
          ++ "/missing.sock\", environment = \"test\", deployment_id = \"fixture\", root_generation = \""
          ++ replicate 32 'b'
          ++ "\", api_port = 26443, node_image = \"kindest/node@sha256:"
          ++ replicate 64 'a'
          ++ "\", http_host_port = 28080, http_node_port = 30080, https_host_port = 28443, https_node_port = 30443, listen_address = \"127.0.0.1\" } }"
      declarations =
        ", node_artifact = { path = \"artifacts/node.tar\", digest = \"sha256:"
          ++ replicate 64 'c'
          ++ "\", maximum_bytes = 1048576 }, kind_tool = { path = \"artifacts/kind\", digest = \"sha256:"
          ++ replicate 64 'd'
          ++ "\", maximum_bytes = 1048576 } } }"
      config =
        Text.unpack
          ( Text.replace
              "schema_version = 1"
              "schema_version = 3"
              (Text.replace " } }" (Text.pack (" " ++ declarations)) (Text.pack legacyConfig))
          )
  executable <- getExecutablePath
  observedDigest <- words <$> readProcess "sha256sum" [executable] ""
  executableDigest <- case observedDigest of
    [value, _] -> pure ("sha256:" ++ value)
    _ -> fail "independent executable hash unavailable"
  writeFile configuration config
  projection <- readBootstrapProjection configuration >>= either (fail . show) pure
  now <- getMonotonicTimeNSec
  let second = 1000000000
  uid <- getEffectiveUserID
  domain <-
    Bus.withSystemdBus
      (now + 500 * second)
      ("/run/user/" ++ show uid ++ "/bus")
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
  key <- maybe (fail "key") pure (kindControllerOperationKey operation)
  request <-
    either
      (fail . show)
      pure
      (mkKindControllerRequest projection operation executableDigest domain window)
  fresh <- prepareFreshKindFamilyRequest projection operation >>= either (fail . show) pure
  require
    "fresh request did not bind the executable and manager"
    ( kindRequestExecutableDigest (fst fresh) == executableDigest
        && kindRequestManagerDomain (fst fresh) == domain
        && kindRequestOperation (fst fresh) == operation
        && snd fresh == Identity.hostExecutionOuterEnd (kindRequestWindow (fst fresh))
    )
  let bus = Identity.hostManagerBusId domain
      foreignBus = (if take 1 bus == "a" then "b" else "a") ++ drop 1 bus
  foreignDomain <-
    maybe
      (fail "foreign domain")
      pure
      ( Identity.hostManagerDomain
          (Identity.hostManagerBootId domain)
          foreignBus
          (Identity.hostManagerUniqueName domain)
          (Identity.hostManagerUserId domain)
          (Identity.hostManagerProcessId domain)
          (Identity.hostManagerStartTicks domain)
      )
  device <- maybe (fail "device") pure (Observed.mkStorageDeviceId "fixture")
  observed <-
    either
      fail
      pure
      (Observed.mkObservedHostRoot (Capacity.ResourceVector 4000 8192 16384 16384) device device)
  preparation <-
    prepareKindFamilyControllerFromObserved observed projection request >>= either (fail . show) pure
  alteredRequest <-
    either
      (fail . show)
      pure
      (mkKindControllerRequest projection operation ("sha256:" ++ replicate 64 'b') domain window)
  require
    "family publication classification accepted conflicting records"
    ( classifyKindFamilyPublication
        (FamilyLaunchObserved request)
        (FamilyLaunchObserved alteredRequest)
        FamilyLaunchMissing
        == KindFamilyPublicationUnconfirmed
        && classifyKindFamilyPublication FamilyLaunchMissing FamilyLaunchMissing (FamilyLaunchObserved request)
          == KindFamilyPublicationUnconfirmed
        && classifyKindFamilyPublication
          (FamilyLaunchObserved request)
          FamilyLaunchMissing
          (FamilyLaunchObserved request)
          == KindFamilyPublicationCancelled
    )
  let recoveryId = if operation == replicate 32 'e' then replicate 32 'f' else replicate 32 'e'
  recovery <-
    either
      (fail . show)
      pure
      (mkProbeRecoveryRequest request recoveryId "12345678-1234-1234-1234-123456789abc")
  recoveryKey <- maybe (fail "recovery key") pure (kindProbeRecoveryKey operation recoveryId)
  recoveryPreparation <-
    prepareKindProbeRecoveryControllerFromObserved observed projection recovery
      >>= either (fail . show) pure
  let verifierId =
        if operation == replicate 32 'f' || recoveryId == replicate 32 'f'
          then replicate 32 'a'
          else replicate 32 'f'
  verifierCoordinates <-
    either
      (fail . show)
      pure
      (mkProbeRecoveryRequest request verifierId "12345678-1234-1234-1234-123456789abc")
  verifier <- either (fail . show) pure (mkProbeAttemptVerifierRequest verifierCoordinates recoveryId)
  verifierKey <- maybe (fail "verifier key") pure (kindProbeRecoveryKey operation verifierId)
  verifierPreparation <-
    prepareKindProbeVerifierControllerFromObserved observed projection verifier
      >>= either (fail . show) pure
  BS.writeFile verifierPath (encodeProbeAttemptVerifierRequest verifier)
  setFileMode verifierPath 0o400
  BS.writeFile recoveryPath (encodeProbeRecoveryRequest recovery)
  setFileMode recoveryPath 0o400
  alteredPreparation <-
    prepareKindFamilyControllerFromObserved observed projection alteredRequest
      >>= either (fail . show) pure
  BS.writeFile requestPath (encodeKindControllerRequest request)
  BS.writeFile alteredPath (encodeKindControllerRequest alteredRequest)
  setFileMode configuration 0o400
  setFileMode requestPath 0o400
  setFileMode alteredPath 0o400
  recoveryResult <- Inputs.withHostControllerInputs (now + 500 * second) configuration recoveryPath $ \owner -> do
    let recoveryArguments =
          Arguments.HostControllerArguments
            configuration
            recoveryPath
            (Inputs.hostControllerInputFingerprint owner)
            recoveryKey
            window
        wrongKeyArguments =
          Arguments.HostControllerArguments
            configuration
            recoveryPath
            (Inputs.hostControllerInputFingerprint owner)
            key
            window
    require "recovery key was routed as node work" (isKindProbeRecoveryArguments recoveryArguments)
    require "node key was routed as recovery" (not (isKindProbeRecoveryArguments wrongKeyArguments))
    let recovered =
          KindProbeRecoveryDispatchInput
            ( KindInputCompleted
                ( Right
                    ( KindFamilyParentCompleted
                        ( KindProbeRecoveryWorkerObserved
                            (KindFamilyRetirementReturned (KindOperationCallbackReturned ProbeRecoveryCompleted) (Right ()) True)
                        )
                    )
                )
            )
        unconfirmed =
          KindProbeRecoveryDispatchInput
            ( KindInputCompleted
                ( Right
                    ( KindFamilyParentCompleted
                        ( KindProbeRecoveryWorkerObserved
                            ( KindFamilyRetirementReturned
                                (KindOperationCallbackReturned ProbeRecoveryDeleteUnconfirmed)
                                (Right ())
                                True
                            )
                        )
                    )
                )
            )
    require
      "cleanup worker completion projection changed"
      (kindProbeRecoveryDispatchCompleted recovered && not (kindProbeRecoveryDispatchCompleted unconfirmed))
    (publicExit, publicOut, publicErr) <-
      readCreateProcessWithExitCode
        ( ( proc
              "./.build/prodbox"
              ("internal-kind-family-controller" : Arguments.renderHostControllerArguments recoveryArguments)
          )
            { env = Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")]
            }
        )
        ""
    require
      "public internal entry did not route and refuse the foreign executable"
      (publicExit == ExitFailure 1 && "Kind probe recovery incomplete" `isInfixOf` (publicOut ++ publicErr))
    accepted <- withPinnedKindProbeRecoveryInput recoveryArguments domain $ \loaded decoded program stable -> do
      held <- stable
      called <- newIORef False
      parent <- withKindFamilyProcesses recoveryPreparation program domain (\_ -> writeIORef called True)
      ran <- readIORef called
      let unmanaged = case parent of KindFamilyParentRefused (KindFamilyParentKernelRefused _) -> True; _ -> False
      pure (loaded == projection && decoded == recovery && held == Right () && not ran && unmanaged)
    case accepted of KindInputCompleted True -> pure (); _ -> fail "valid recovery input refused"
    selected <- withPinnedKindProbeFamilyInput recoveryArguments domain $ \_ decoded _ _ -> pure (decoded == KindProbeCleanupRequest recovery)
    case selected of
      KindInputCompleted True -> pure ()
      _ -> fail "family dispatcher did not select cleanup from pinned bytes"
    wrongKey <- withPinnedKindProbeRecoveryInput wrongKeyArguments domain $ \_ _ _ _ -> pure ()
    wrongManager <- withPinnedKindProbeRecoveryInput recoveryArguments foreignDomain $ \_ _ _ _ -> pure ()
    case (wrongKey, wrongManager) of
      ( KindInputRefused (KindInputRequestRefused KindRequestBindingMismatch)
        , KindInputRefused (KindInputRequestRefused KindRequestBindingMismatch)
        ) -> pure ()
      _ -> fail "foreign recovery key or manager accepted"
  either (fail . show) pure recoveryResult
  verifierResult <- Inputs.withHostControllerInputs (now + 500 * second) configuration verifierPath $ \owner -> do
    let verifierArguments =
          Arguments.HostControllerArguments
            configuration
            verifierPath
            (Inputs.hostControllerInputFingerprint owner)
            verifierKey
            window
        priorArguments =
          Arguments.HostControllerArguments
            configuration
            verifierPath
            (Inputs.hostControllerInputFingerprint owner)
            recoveryKey
            window
    accepted <- withPinnedKindProbeVerifierInput verifierArguments domain $ \loaded decoded program stable -> do
      held <- stable
      called <- newIORef False
      parent <- withKindFamilyProcesses verifierPreparation program domain (\_ -> writeIORef called True)
      ran <- readIORef called
      let unmanaged = case parent of KindFamilyParentRefused (KindFamilyParentKernelRefused _) -> True; _ -> False
      pure (loaded == projection && decoded == verifier && held == Right () && not ran && unmanaged)
    case accepted of KindInputCompleted True -> pure (); _ -> fail "valid verifier input refused"
    selected <- withPinnedKindProbeFamilyInput verifierArguments domain $ \_ decoded _ _ -> pure (decoded == KindProbeVerifierRequest verifier)
    case selected of
      KindInputCompleted True -> pure ()
      _ -> fail "family dispatcher did not select verifier from pinned bytes"
    (publicExit, publicOut, publicErr) <-
      readCreateProcessWithExitCode
        ( ( proc
              "./.build/prodbox"
              ("internal-kind-family-controller" : Arguments.renderHostControllerArguments verifierArguments)
          )
            { env = Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")]
            }
        )
        ""
    require
      "public verifier entry did not refuse the foreign executable"
      (publicExit == ExitFailure 1 && "Kind probe recovery incomplete" `isInfixOf` (publicOut ++ publicErr))
    wrongKey <- withPinnedKindProbeVerifierInput priorArguments domain $ \_ _ _ _ -> pure ()
    wrongManager <- withPinnedKindProbeVerifierInput verifierArguments foreignDomain $ \_ _ _ _ -> pure ()
    wrongKind <- withPinnedKindProbeRecoveryInput verifierArguments domain $ \_ _ _ _ -> pure ()
    case (wrongKey, wrongManager, wrongKind) of
      ( KindInputRefused (KindInputRequestRefused KindRequestBindingMismatch)
        , KindInputRefused (KindInputRequestRefused KindRequestBindingMismatch)
        , KindInputRefused (KindInputRequestRefused _)
        ) -> pure ()
      _ -> fail "foreign verifier key, manager or request kind accepted"
  either (fail . show) pure verifierResult
  result <- Inputs.withHostControllerInputs (now + 500 * second) configuration requestPath $ \owner -> do
    let arguments =
          Arguments.HostControllerArguments
            configuration
            requestPath
            (Inputs.hostControllerInputFingerprint owner)
            key
            window
    good <- withPinnedKindControllerInput arguments domain $ \loaded decoded program stable -> do
      require "projection changed" (loaded == projection)
      require "request changed" (decoded == request)
      valid <- stable
      require "held inputs unavailable" (valid == Right ())
      called <- newIORef False
      deniedDomain <-
        withKindFamilyProcesses preparation program foreignDomain (\_ -> writeIORef called True)
      deniedInput <-
        withKindFamilyProcesses alteredPreparation program domain (\_ -> writeIORef called True)
      deniedParent <- withKindFamilyProcesses preparation program domain (\_ -> writeIORef called True)
      ran <- readIORef called
      require
        "foreign domain or executable entered parent"
        ( not ran
            && deniedDomain == KindFamilyParentRefused KindFamilyParentDomainMismatch
            && deniedInput == KindFamilyParentRefused KindFamilyParentInputMismatch
        )
      case deniedParent of
        KindFamilyParentRefused (KindFamilyParentKernelRefused _) -> pure ()
        other -> fail ("unmanaged process was not refused by kernel owner: " ++ show other)
      pure True
    require "valid inputs refused" (good == KindInputCompleted True)
    dispatch <- dispatchKindFamilyController arguments
    case dispatch of
      KindFamilyDispatchInput (KindInputCompleted (Left (KindFamilyPreparationCapacityRefused _))) _ -> pure ()
      other -> fail ("missing retained root did not refuse dispatch: " ++ show other)
    preparedRoot <- prepareFreshScope (bootstrapScope projection) (replicate 32 'b')
    require "test root preparation failed" (preparedRoot == FreshScopePrepared)
    intent <- recordKindFamilyIntent projection operation
    require "test operation intent failed" (intent == KindIntentRecorded)
    prerequisiteEnd <- (+ 5000000000) <$> getMonotonicTimeNSec
    refusedPrerequisites <-
      reconcileFamilyPrerequisites prerequisiteEnd projection operation (const (pure False))
    require
      "family prerequisite worker accepted lost admission"
      (refusedPrerequisites == ReconcileFamilyAdmissionRefused)
    refusedExternal <- reconcileFamilyPrerequisites prerequisiteEnd projection operation id
    require
      "family prerequisite worker accepted the older externally prepared protocol"
      (refusedExternal == ReconcileFamilyAdmissionRefused)
    imageIntentExists <-
      doesFileExist (scopeRoot (bootstrapScope projection) </> "node-image-intent.json")
    require "refused prerequisite worker recorded an image intent" (not imageIntentExists)
    missingVerifier <-
      withKindProbeVerifierRetirement
        (now + 560 * second)
        projection
        operation
        (\_ -> fail "missing verifier entered retirement callback" :: IO ())
    case missingVerifier of
      KindFamilyRetirementRefused KindFamilyRecoveryRequestMissing -> pure ()
      other -> fail ("missing verifier inferred retired: " ++ show other)
    absentFamily <- recoverNeverSentKindFamilyInputs (now + 560 * second) projection operation
    require
      "missing family request inferred never sent"
      (absentFamily == KindOperationCallbackReturned KindFamilyNeverSentIdentityUnconfirmed)
    wrongManagerRequest <-
      either
        (fail . show)
        pure
        (mkKindControllerRequest projection operation executableDigest foreignDomain window)
    wrongManager <- launchKindFamily (now + 560 * second) projection wrongManagerRequest
    case wrongManager of
      KindFamilyLaunchLease (KindOperationCallbackReturned (Left KindFamilyLaunchManagerMismatch)) -> pure ()
      other -> fail ("foreign manager was not refused before publication: " ++ show other)
    legacyProjection <-
      decodeOptionalBootstrapSource configuration (Text.pack legacyConfig)
        >>= either (fail . show) (maybe (fail "legacy projection missing") pure)
    wrongConfiguration <- launchKindFamily (now + 560 * second) legacyProjection request
    case wrongConfiguration of
      KindFamilyLaunchRefused KindFamilyLaunchConfigurationRefused -> pure ()
      other -> fail ("foreign configuration was not refused: " ++ show other)
    unsendableRequest <-
      either
        (fail . show)
        pure
        (mkKindControllerRequest projection operation ("sha256:" ++ replicate 64 'b') domain window)
    withRecoveredKindOperation projection operation (recordFamilyLaunch projection unsendableRequest) >>= \observed ->
      require
        "interrupted family locator was not recorded"
        (observed == KindOperationCallbackReturned FamilyLaunchRecorded)
    prePublication <- recoverNeverSentKindFamilyInputs (now + 560 * second) projection operation
    require
      "interrupted family locator did not remain pre-publication"
      (prePublication == KindOperationCallbackReturned (KindFamilyNeverSentBeforePublication True))
    foreignRequest <-
      either
        (fail . show)
        pure
        (mkKindControllerRequest projection operation ("sha256:" ++ replicate 64 'c') domain window)
    foreignResume <- launchKindFamily (now + 560 * second) projection foreignRequest
    case foreignResume of
      KindFamilyLaunchLease
        (KindOperationCallbackReturned (Left (KindFamilyLaunchRecordRefused FamilyLaunchAlreadyExists))) -> pure ()
      other -> fail ("foreign request reused a retained family locator: " ++ show other)
    launch <- launchKindFamily (now + 560 * second) projection unsendableRequest
    case launch of
      KindFamilyLaunchLease
        ( KindOperationCallbackReturned
            (Right (Left KindFamilyLaunchInputMismatch, KindFamilyLaunchUnsentRetired))
          ) -> pure ()
      other -> fail ("foreign executable did not refuse and retire unsent inputs: " ++ show other)
    repeated <- launchKindFamily (now + 560 * second) projection unsendableRequest
    case repeated of
      KindFamilyLaunchLease
        (KindOperationCallbackReturned (Left (KindFamilyLaunchRecordRefused FamilyLaunchAlreadyExists))) -> pure ()
      other -> fail ("family publication was retried after its attempt marker: " ++ show other)
    neverSentFamily <- recoverNeverSentKindFamilyInputs (now + 560 * second) projection operation
    require
      "never-sent original family inputs did not resume retirement"
      (neverSentFamily == KindOperationCallbackReturned (KindFamilyNeverSentInputs (Right ()) True))
    borrowedNeverSent <- withNeverSentKindFamily (now + 560 * second) projection operation $ \admitted -> do
      allowed <- withRecoveredKindOperation projection operation admitted
      refused <- withRecoveredKindOperation projection operation (\_ -> admitted (pure False))
      require
        "borrowed never-sent admission did not track the operation lease"
        (allowed == KindOperationCallbackReturned True && refused == KindOperationCallbackReturned False)
      pure admitted
    case borrowedNeverSent of
      KindFamilyNeverSentScopeReturned expired (Right ()) True -> do
        closed <- withRecoveredKindOperation projection operation expired
        require "escaped never-sent owner remained live" (closed == KindOperationCallbackReturned False)
      KindFamilyNeverSentScopeRefused failure -> fail ("never-sent owner refused: " ++ failure)
      KindFamilyNeverSentScopeReturned _ closing scope -> fail ("never-sent closing unconfirmed: " ++ show (closing, scope))
    let firstProbeNamespace = "prodbox-netcheck-" ++ take 12 operation
    withRecoveredKindOperation
      projection
      operation
      ( \stable ->
          recordProbeRecord projection operation firstProbeNamespace ProbeIntent stable
      )
      >>= \observed ->
        require
          "uncertain probe fixture was not recorded"
          (observed == KindOperationCallbackReturned ProbeRecorded)
    blockedProbe <- deleteNewTestIdentity projection
    case blockedProbe of
      [DeleteStep "family settlement" True _, DeleteStep "probe cleanup" False _] -> pure ()
      other -> fail ("never-sent delete accepted an uncertain probe: " ++ show other)
    removeFile
      ( scopeRoot (bootstrapScope projection)
          </> ("kind-network-probe-" ++ firstProbeNamespace ++ "-intent.json")
      )
    (familyDeleteExit, familyDeleteOut, familyDeleteErr) <-
      readCreateProcessWithExitCode
        ( (proc "./.build/prodbox" ["--config", configuration, "control", "delete", "--yes"])
            { env = Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")]
            }
        )
        ""
    require
      "public delete did not retain the never-sent family disposition as incomplete"
      ( familyDeleteExit == ExitFailure 1
          && "never-sent publication confirmed" `isInfixOf` (familyDeleteOut ++ familyDeleteErr)
          && "network: NOT completed" `isInfixOf` (familyDeleteOut ++ familyDeleteErr)
      )
    provenance <- observeKindFamilySubmission (now + 560 * second) projection operation
    case provenance of
      KindOperationCallbackReturned (Left (KindFamilyRecoverySubmissionUnobservable _)) -> pure ()
      other -> fail ("missing submission was inferred to be settled: " ++ show other)
    recoveryLaunch <- launchKindProbeRecovery (now + 560 * second) projection recovery
    case recoveryLaunch of
      KindProbeRecoveryLaunchRetirement
        (KindFamilyRetirementRefused (KindFamilyRecoverySubmissionUnobservable _)) -> pure ()
      other -> fail ("cleanup launch accepted an unretired original family: " ++ show other)
    noRecoveryRecord <-
      withRecoveredKindOperation projection operation $
        observeProbeRecoveryLaunch projection operation ("prodbox-netcheck-" ++ take 12 operation)
    require
      "refused cleanup launch wrote a recovery locator"
      (noRecoveryRecord == KindOperationCallbackReturned ProbeRecoveryLaunchMissing)
    retirement <- retireKindFamilyInputs (now + 560 * second) projection operation
    case retirement of
      KindOperationCallbackReturned (Left (KindFamilyRecoverySubmissionUnobservable _)) -> pure ()
      other -> fail ("missing submission authorized retirement: " ++ show other)
    retainedDispatch <- dispatchKindFamilyController arguments
    case retainedDispatch of
      KindFamilyDispatchInput
        (KindInputCompleted _)
        (KindFamilyResultLease (KindOperationCallbackReturned FamilyResultRecorded)) ->
          require
            "unmanaged dispatch reported completion"
            (not (kindFamilyDispatchCompleted retainedDispatch))
      other -> fail ("incomplete dispatch did not retain its result: " ++ show other)
    (_, statusOut, statusErr) <-
      readCreateProcessWithExitCode
        ( (proc "./.build/prodbox" ["--config", configuration, "control", "status"])
            { env = Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")]
            }
        )
        ""
    require
      "public status omitted retained family result"
      ( "FamilyResultObserved" `isInfixOf` (statusOut ++ statusErr)
          && "retirement not observed" `isInfixOf` (statusOut ++ statusErr)
      )
    require
      "public status omitted unconfirmed family provenance"
      ( "Kind family submission" `isInfixOf` (statusOut ++ statusErr)
          && "send and retirement not established" `isInfixOf` (statusOut ++ statusErr)
      )
    entered <- newIORef False
    wrong <- Inputs.withHostControllerInputs (now + 500 * second) configuration alteredPath $ \alteredOwner -> do
      let alteredArguments =
            Arguments.HostControllerArguments
              configuration
              alteredPath
              (Inputs.hostControllerInputFingerprint alteredOwner)
              key
              window
      refused <- dispatchKindFamilyController alteredArguments
      case refused of
        KindFamilyDispatchInput
          (KindInputRefused (KindInputRequestRefused KindRequestBindingMismatch))
          KindFamilyResultNoContext -> pure ()
        other -> fail ("wrong executable digest did not refuse dispatch: " ++ show other)
      withPinnedKindControllerInput alteredArguments domain $ \_ _ _ _ -> writeIORef entered True
    invoked <- readIORef entered
    require
      "wrong digest entered callback"
      ( not invoked
          && wrong == Right (KindInputRefused (KindInputRequestRefused KindRequestBindingMismatch))
      )
    changed <- withPinnedKindControllerInput arguments domain $ \_ _ _ _ -> do
      setFileMode requestPath 0o600
      BS.writeFile requestPath "changed"
      pure True
    case changed of
      KindInputChangedAfter True _ -> pure ()
      other -> fail ("input change omitted callback result: " ++ show other)
  either (fail . show) pure result
  missingRecovery <-
    withKindProbeFamilyRetirement
      (now + 500 * second)
      projection
      operation
      (\_ -> fail "missing recovery entered callback" :: IO ())
  case missingRecovery of
    KindFamilyRetirementRefused KindFamilyRecoveryRequestMissing -> pure ()
    other -> fail ("missing recovery locator authorized retirement: " ++ show other)
  let probeNamespace = "prodbox-netcheck-" ++ take 12 operation
      probeUid = "12345678-1234-1234-1234-123456789abc"
      recoveryLocator =
        scopeRoot (bootstrapScope projection)
          </> ("kind-network-probe-" ++ probeNamespace ++ "-recovery-launch.json")
  withRecoveredKindOperation
    projection
    operation
    ( \stable -> do
        mapM_
          ( \stage ->
              recordProbeRecord projection operation probeNamespace stage stable >>= \written ->
                require "cleanup retirement fixture record failed" (written == ProbeRecorded)
          )
          [ProbeIntent, ProbeCreated probeUid, ProbeRecoveryLaunch recovery, ProbePublicationAttempt recovery]
    )
    >>= \observed ->
      require "cleanup retirement fixture lease failed" (observed == KindOperationCallbackReturned ())
  missingSubmission <-
    withKindProbeFamilyRetirement
      (now + 500 * second)
      projection
      operation
      (\_ -> fail "missing submission entered callback" :: IO ())
  case missingSubmission of
    KindFamilyRetirementRefused (KindFamilyRecoverySubmissionUnobservable _) -> pure ()
    other -> fail ("missing cleanup submission authorized retirement: " ++ show other)
  recoveryPublished <-
    Publication.withPublishedHostControllerOwner
      Identity.KindController
      (now + 500 * second)
      recoveryKey
      (BS8.pack config)
      (encodeProbeRecoveryRequest recovery)
      ( \owner -> do
          let (configFile, requestFile) = Publication.hostPublicationPaths owner
          held <- Inputs.withHostControllerInputs (now + 500 * second) configFile requestFile $ \inputs -> do
            connected <- Bus.withSystemdBus (now + 500 * second) ("/run/user/" ++ show uid ++ "/bus") $ \connection -> do
              actualDomain <- Bus.observeManagerDomain connection
              sender <- Bus.observeBusSender connection
              lift $ do
                require "manager changed during cleanup registration" (actualDomain == domain)
                qualified <- Provider.withQualifiedProvider connection $ \provider -> do
                  registered <-
                    Inputs.registerHostControllerSubmission
                      Identity.KindController
                      inputs
                      recoveryKey
                      window
                      domain
                      sender
                      provider
                  _ <- either (fail . show) pure registered
                  active <-
                    withKindProbeFamilyRetirement
                      (now + 500 * second)
                      projection
                      operation
                      (\_ -> fail "active sender entered callback" :: IO ())
                  case active of
                    KindFamilyRetirementRefused
                      ( KindFamilyRecoveryRetirementRefused
                          (Retirement.RetirementProcessingRefused Family.HostSubmissionSenderPresent)
                        ) -> pure ()
                    other -> fail ("live cleanup sender authorized retirement: " ++ show other)
                either (fail . show) pure qualified
            either (fail . show) pure connected
          either (fail . show) pure held
          retired <- withKindProbeFamilyRetirement (now + 500 * second) projection operation $ \retirementOwner -> do
            checked <-
              withRecoveredKindOperation projection operation (verifyKindProbeFamilyRetirement retirementOwner)
            require
              "cleanup retirement owner did not verify"
              (checked == KindOperationCallbackReturned (Right ()))
            original <- BS.readFile recoveryLocator
            BS.writeFile recoveryLocator "{}"
            changed <-
              withRecoveredKindOperation projection operation (verifyKindProbeFamilyRetirement retirementOwner)
            require
              "changed cleanup locator authorized retirement"
              (changed == KindOperationCallbackReturned (Left KindFamilyRecoveryRequestConflict))
            BS.writeFile recoveryLocator original
            removed <-
              withRecoveredKindOperation
                projection
                operation
                (retireKindProbeFamilyPublishedInputs (now + 500 * second) retirementOwner)
            require
              "cleanup inputs not retired"
              (removed == KindOperationCallbackReturned (KindFamilyInputRetirement (Right ()) (Right ()) True))
            present <- (||) <$> doesFileExist configFile <*> doesFileExist requestFile
            require "cleanup retirement left published inputs" (not present)
            pure retirementOwner
          case retired of
            KindFamilyRetirementReturned expired (Right ()) True -> do
              checked <- withRecoveredKindOperation projection operation (verifyKindProbeFamilyRetirement expired)
              case checked of
                KindOperationCallbackReturned
                  (Left (KindFamilyRecoveryRetirementRefused Retirement.RetirementClosed)) -> pure ()
                other -> fail ("escaped cleanup retirement owner remained live: " ++ show other)
            KindFamilyRetirementRefused failure -> fail ("cleanup retirement refused: " ++ show failure)
            KindFamilyRetirementLeaseUnconfirmed -> fail "cleanup retirement lease unconfirmed"
            KindFamilyRetirementReturned _ closing scope -> fail ("cleanup retirement closing unconfirmed: " ++ show (closing, scope))
      )
      (requireNeverSent "synthetic cleanup registration unexpectedly sent")
  either (fail . show) (const (pure ())) recoveryPublished
  let config2 =
        Text.unpack
          (Text.replace "deployment_id = \"fixture\"" "deployment_id = \"fixture2\"" (Text.pack config))
      configPath2 = anchor </> "settings2.dhall"
      operation2 = init operation ++ (if last operation == 'f' then "e" else "f")
  writeFile configPath2 config2
  projection2 <- readBootstrapProjection configPath2 >>= either (fail . show) pure
  prepared2 <- prepareFreshScope (bootstrapScope projection2) (replicate 32 'b')
  require "second test root preparation failed" (prepared2 == FreshScopePrepared)
  recordKindFamilyIntent projection2 operation2 >>= \observed -> require "second intent failed" (observed == KindIntentRecorded)
  request2 <-
    either
      (fail . show)
      pure
      (mkKindControllerRequest projection2 operation2 executableDigest domain window)
  key2 <- maybe (fail "second key") pure (kindControllerOperationKey operation2)
  withRecoveredKindOperation projection2 operation2 (recordFamilyLaunch projection2 request2) >>= \observed ->
    require
      "second launch locator failed"
      (observed == KindOperationCallbackReturned FamilyLaunchRecorded)
  beforeFamilyPublication <-
    recoverNeverSentKindFamilyInputs (now + 500 * second) projection2 operation2
  require
    "family pre-publication boundary not recognized"
    (beforeFamilyPublication == KindOperationCallbackReturned (KindFamilyNeverSentBeforePublication True))
  withRecoveredKindOperation
    projection2
    operation2
    (recordFamilyPublicationAttempt projection2 request2)
    >>= \observed ->
      require
        "family publication attempt marker failed"
        (observed == KindOperationCallbackReturned FamilyLaunchRecorded)
  withRecoveredKindOperation
    projection2
    operation2
    (recordFamilyPrePublicationCancellation projection2 request2)
    >>= \observed ->
      require
        "cancellation accepted after publication attempt"
        (observed == KindOperationCallbackReturned FamilyLaunchRefused)
  missingFamilyPublication <-
    recoverNeverSentKindFamilyInputs (now + 500 * second) projection2 operation2
  case missingFamilyPublication of
    KindOperationCallbackReturned (KindFamilyNeverSentInputs (Left _) True) -> pure ()
    other -> fail ("missing attempted family publication inferred never sent: " ++ show other)
  oldAfterFamily <-
    withRecoveredKindOperation projection2 operation2 $
      recordControllerSubmissionIntent projection2 operation2 (replicate 64 'e')
  require
    "family launch did not fence legacy submission"
    (oldAfterFamily == KindOperationCallbackReturned ControllerSubmissionRefused)
  published <-
    Publication.withPublishedHostControllerOwner
      Identity.KindController
      (now + 500 * second)
      key2
      (BS.pack (map (fromIntegral . fromEnum) config2))
      (encodeKindControllerRequest request2)
      ( \owner -> do
          let (configFile, requestFile) = Publication.hostPublicationPaths owner
          held <- Inputs.withHostControllerInputs (now + 500 * second) configFile requestFile $ \inputs -> do
            connected <- Bus.withSystemdBus (now + 500 * second) ("/run/user/" ++ show uid ++ "/bus") $ \connection -> do
              actualDomain <- Bus.observeManagerDomain connection
              sender <- Bus.observeBusSender connection
              lift $ do
                require "manager changed during synthetic registration" (actualDomain == domain)
                qualified <- Provider.withQualifiedProvider connection $ \provider -> do
                  registered <-
                    Inputs.registerHostControllerSubmission
                      Identity.KindController
                      inputs
                      key2
                      window
                      domain
                      sender
                      provider
                  _ <- either (fail . show) pure registered
                  observed <- observeKindFamilySubmission (now + 500 * second) projection2 operation2
                  require
                    "exact synthetic provenance was not recovered"
                    (observed == KindOperationCallbackReturned (Right KindFamilySubmissionRecorded))
                  retirement <- retireKindFamilyInputs (now + 500 * second) projection2 operation2
                  case retirement of
                    KindOperationCallbackReturned
                      ( Left
                          ( KindFamilyRecoveryRetirementRefused
                              (Retirement.RetirementProcessingRefused Family.HostSubmissionSenderPresent)
                            )
                        ) -> pure ()
                    other -> fail ("live sender authorized retirement: " ++ show other)
                  neverSentActive <- recoverNeverSentKindFamilyInputs (now + 500 * second) projection2 operation2
                  case neverSentActive of
                    KindOperationCallbackReturned (KindFamilyNeverSentInputs (Left _) True) -> pure ()
                    other -> fail ("live publication was treated as never sent: " ++ show other)
                  borrowedActive <-
                    withNeverSentKindFamily
                      (now + 500 * second)
                      projection2
                      operation2
                      (\_ -> fail "live publisher entered callback" :: IO ())
                  case borrowedActive of
                    KindFamilyNeverSentScopeRefused _ -> pure ()
                    other -> fail ("live publisher granted a never-sent owner: " ++ show other)
                either (fail . show) pure qualified
            either (fail . show) pure connected
          either (fail . show) pure held
          called <- newIORef False
          missingResult <- withKindFamilyCompletion (now + 500 * second) projection2 operation2 $ \_ -> writeIORef called True
          case missingResult of
            KindFamilyRetirementReturned
              (KindOperationCallbackReturned KindFamilyCompletionRefused)
              (Right ())
              True -> pure ()
            other -> fail ("missing worker result admitted completion: " ++ show other)
          readIORef called >>= require "completion callback ran without a result" . not
          let completeResult =
                FamilyResult
                  FamilyWorkerConfirmed
                  FamilyWorkerComplete
                  FamilyParentComplete
                  FamilyInputComplete
                  FamilyPostProbeComplete
                  FamilyPostLeaseComplete
              resultDigest = BS8.unpack (hexSha256 (encodeKindControllerRequest request2))
          withRecoveredKindOperation
            projection2
            operation2
            (recordFamilyResult projection2 operation2 resultDigest completeResult)
            >>= \observed ->
              require
                "family result fixture failed"
                (observed == KindOperationCallbackReturned FamilyResultRecorded)
          missingJournal <- withKindFamilyCompletion (now + 500 * second) projection2 operation2 $ \_ -> writeIORef called True
          case missingJournal of
            KindFamilyRetirementReturned
              (KindOperationCallbackReturned KindFamilyCompletionRefused)
              (Right ())
              True -> pure ()
            other -> fail ("missing probe journal admitted completion: " ++ show other)
          readIORef called >>= require "completion callback ran without cleanup records" . not
          let namespace2 = "prodbox-netcheck-" ++ take 12 operation2
              namespaceUid = "12345678-1234-1234-1234-123456789abc"
              recoveryId2 = if operation2 == replicate 32 'e' then replicate 32 'f' else replicate 32 'e'
          recovery2 <- either (fail . show) pure (mkProbeRecoveryRequest request2 recoveryId2 namespaceUid)
          recoveryKey2 <-
            maybe (fail "second recovery key") pure (kindProbeRecoveryKey operation2 recoveryId2)
          withRecoveredKindOperation
            projection2
            operation2
            ( \stable -> do
                mapM_
                  ( \stage ->
                      recordProbeRecord projection2 operation2 namespace2 stage stable >>= \written ->
                        require "probe journal fixture failed" (written == ProbeRecorded)
                  )
                  [ProbeIntent, ProbeCreated namespaceUid]
            )
            >>= \observed ->
              require "probe journal lease failed" (observed == KindOperationCallbackReturned ())
          let scratchRecoveryId = if operation2 == replicate 32 '1' then replicate 32 '2' else replicate 32 '1'
              scratchPrefix = scopeRoot (bootstrapScope projection2) </> ("kind-network-probe-" ++ namespace2)
          scratchController <-
            either
              (fail . show)
              pure
              (mkKindControllerRequest projection2 operation2 ("sha256:" ++ replicate 64 'b') domain window)
          scratchRecovery <-
            either (fail . show) pure (mkProbeRecoveryRequest scratchController scratchRecoveryId namespaceUid)
          withRecoveredKindOperation
            projection2
            operation2
            ( \stable ->
                recordProbeRecord projection2 operation2 namespace2 (ProbeRecoveryLaunch scratchRecovery) stable
            )
            >>= \observed ->
              require
                "cleanup resume locator fixture failed"
                (observed == KindOperationCallbackReturned ProbeRecorded)
          foreignCleanupRequest <-
            either
              (fail . show)
              pure
              (mkKindControllerRequest projection2 operation2 executableDigest foreignDomain window)
          foreignCleanup <-
            either
              (fail . show)
              pure
              (mkProbeRecoveryRequest foreignCleanupRequest scratchRecoveryId namespaceUid)
          refusedCleanup <- launchKindProbeRecovery (now + 500 * second) projection2 foreignCleanup
          case refusedCleanup of
            KindProbeRecoveryLaunchRetirement
              ( KindFamilyRetirementReturned
                  (KindOperationCallbackReturned (Left (KindFamilyLaunchProbeRecordRefused ProbeAlreadyExists)))
                  (Right ())
                  True
                ) -> pure ()
            other -> fail ("cleanup resumed a changed retained request: " ++ show other)
          resumedCleanup <- launchKindProbeRecovery (now + 500 * second) projection2 scratchRecovery
          case resumedCleanup of
            KindProbeRecoveryLaunchRetirement
              ( KindFamilyRetirementReturned
                  ( KindOperationCallbackReturned
                      (Right (Left KindFamilyLaunchInputMismatch, KindFamilyLaunchUnsentRetired))
                    )
                  (Right ())
                  True
                ) -> pure ()
            other -> fail ("cleanup did not resume its pre-publication request: " ++ show other)
          duplicateCleanup <- launchKindProbeRecovery (now + 500 * second) projection2 scratchRecovery
          case duplicateCleanup of
            KindProbeRecoveryLaunchRetirement
              ( KindFamilyRetirementReturned
                  (KindOperationCallbackReturned (Left (KindFamilyLaunchProbeRecordRefused ProbeAlreadyExists)))
                  (Right ())
                  True
                ) -> pure ()
            other -> fail ("cleanup retried after a publication attempt: " ++ show other)
          mapM_ (removeFile . (scratchPrefix ++)) ["-recovery-launch.json", "-publication-attempt.json"]
          withRecoveredKindOperation
            projection2
            operation2
            ( \stable ->
                recordProbeRecord projection2 operation2 namespace2 (ProbeRecoveryLaunch recovery2) stable
            )
            >>= \observed ->
              require
                "probe recovery locator fixture failed"
                (observed == KindOperationCallbackReturned ProbeRecorded)
          neverSent <- withKindFamilyRetirement (now + 500 * second) projection2 operation2 $ \originalOwner -> do
            beforePublication <-
              withRecoveredKindOperation
                projection2
                operation2
                (retireNeverSentKindProbeInputs (now + 500 * second) originalOwner projection2 operation2)
            case beforePublication of
              KindOperationCallbackReturned (KindProbeNeverSentBeforePublication (Right ()) True) -> pure ()
              other -> fail ("pre-publication barrier not observed: " ++ show other)
            withRecoveredKindOperation
              projection2
              operation2
              ( \stable ->
                  recordProbeRecord projection2 operation2 namespace2 (ProbePublicationAttempt recovery2) stable
              )
              >>= \observed ->
                require
                  "publication attempt marker failed"
                  (observed == KindOperationCallbackReturned ProbeRecorded)
            (_, probeStatusOut, probeStatusErr) <-
              readCreateProcessWithExitCode
                ( (proc "./.build/prodbox" ["--config", configPath2, "control", "status"])
                    { env = Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")]
                    }
                )
                ""
            require
              "public status omitted the cleanup publication attempt"
              ( ("cleanup recovery " ++ recoveryId2 ++ " has a publication-attempt record; send not established")
                  `isInfixOf` (probeStatusOut ++ probeStatusErr)
              )
            missingPublication <-
              withRecoveredKindOperation
                projection2
                operation2
                (retireNeverSentKindProbeInputs (now + 500 * second) originalOwner projection2 operation2)
            case missingPublication of
              KindOperationCallbackReturned (KindProbeNeverSentInputs (Left _) (Right ()) True) -> pure ()
              other -> fail ("missing attempted publication inferred never sent: " ++ show other)
            publishedRecovery <-
              Publication.withPublishedHostControllerOwner
                Identity.KindController
                (now + 500 * second)
                recoveryKey2
                (BS8.pack config2)
                (encodeProbeRecoveryRequest recovery2)
                (\_ -> pure (Right ()))
                (requireNeverSent "synthetic cleanup publication sent")
            either (fail . show) (const (pure ())) publishedRecovery
            retired <-
              withRecoveredKindOperation
                projection2
                operation2
                (retireNeverSentKindProbeInputs (now + 500 * second) originalOwner projection2 operation2)
            require
              "never-sent cleanup inputs were not retired"
              (retired == KindOperationCallbackReturned (KindProbeNeverSentInputs (Right ()) (Right ()) True))
          case neverSent of
            KindFamilyRetirementReturned () (Right ()) True -> pure ()
            other -> fail ("never-sent cleanup retirement unconfirmed: " ++ show other)
          (reconcileExit, reconcileOut, reconcileErr) <-
            readCreateProcessWithExitCode
              ( (proc "./.build/prodbox" ["--config", configPath2, "control", "reconcile"])
                  { env = Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")]
                  }
              )
              ""
          require
            "public reconcile did not retain incomplete never-sent cleanup recovery"
            ( reconcileExit == ExitFailure 1
                && "KindProbeNeverSentInputs (Right ()) (Right ()) True" `isInfixOf` (reconcileOut ++ reconcileErr)
            )
          deleteSteps <- deleteNewTestIdentity projection2
          case deleteSteps of
            [DeleteStep "probe cleanup" False detail] ->
              require
                ("delete did not retain incomplete probe cleanup and the never-sent result: " ++ detail)
                ( "namespace removal remains unconfirmed" `isInfixOf` detail
                    && "KindProbeNeverSentInputs (Right ()) (Right ()) True" `isInfixOf` detail
                )
            other -> fail ("delete did not stop after never-sent recovery: " ++ show other)
          resumed <- recoverNeverSentKindProbeInputs (now + 500 * second) projection2 operation2
          case resumed of
            KindFamilyRetirementReturned
              (KindOperationCallbackReturned (KindProbeNeverSentInputs (Right ()) (Right ()) True))
              (Right ())
              True -> pure ()
            other -> fail ("never-sent cleanup retirement did not resume: " ++ show other)
          withRecoveredKindOperation
            projection2
            operation2
            ( \stable ->
                recordProbeRecord projection2 operation2 namespace2 (ProbeRemoved namespaceUid) stable
            )
            >>= \observed ->
              require "probe removal fixture failed" (observed == KindOperationCallbackReturned ProbeRecorded)
          conflicted <- withKindFamilyCompletion (now + 500 * second) projection2 operation2 $ \_ ->
            fail "cleanup launch entered original completion" :: IO ()
          case conflicted of
            KindFamilyRetirementReturned
              (KindOperationCallbackReturned KindFamilyCompletionRefused)
              (Right ())
              True -> pure ()
            other -> fail ("cleanup launch admitted original completion: " ++ show other)
          -- Reset this synthetic locator to exercise the separate original-only
          -- completion control below; no live cleanup worker was submitted.
          removeFile
            ( scopeRoot (bootstrapScope projection2)
                </> ("kind-network-probe-" ++ namespace2 ++ "-recovery-launch.json")
            )
          orphaned <- withKindFamilyCompletion (now + 500 * second) projection2 operation2 $ \_ ->
            fail "orphan publication marker entered original completion" :: IO ()
          case orphaned of
            KindFamilyRetirementReturned
              (KindOperationCallbackReturned KindFamilyCompletionRefused)
              (Right ())
              True -> pure ()
            other -> fail ("orphan marker admitted original completion: " ++ show other)
          orphanDelete <- deleteNewTestIdentity projection2
          case orphanDelete of
            [DeleteStep "probe cleanup" False _] -> pure ()
            other -> fail ("orphan marker admitted node removal: " ++ show other)
          removeFile
            ( scopeRoot (bootstrapScope projection2)
                </> ("kind-network-probe-" ++ namespace2 ++ "-publication-attempt.json")
            )
          completed <- withKindFamilyCompletion (now + 500 * second) projection2 operation2 $ \stable -> do
            unchanged <- stable
            writeIORef called True
            pure unchanged
          case completed of
            KindFamilyRetirementReturned
              (KindOperationCallbackReturned (KindFamilyCompletionReturned True))
              (Right ())
              True -> pure ()
            other -> fail ("bound family completion refused: " ++ show other)
          readIORef called >>= require "bound completion callback did not run"
          let resultPath2 = scopeRoot (bootstrapScope projection2) </> "kind-family-dispatch-result.json"
          resultBytes <- BS.readFile resultPath2
          changedResult <- withKindFamilyCompletion (now + 500 * second) projection2 operation2 $ \_ -> do
            BS.writeFile resultPath2 "{}"
            pure (42 :: Int)
          case changedResult of
            KindFamilyRetirementReturned
              (KindOperationCallbackReturned (KindFamilyCompletionChangedAfter 42))
              (Right ())
              True -> pure ()
            other -> fail ("changed result lost the callback outcome: " ++ show other)
          BS.writeFile resultPath2 resultBytes
          borrowed <- withKindFamilyRetirement (now + 500 * second) projection2 operation2 $ \retirementOwner -> do
            checked <-
              withRecoveredKindOperation projection2 operation2 (verifyKindFamilyRetirement retirementOwner)
            require
              "live retirement owner did not verify with the operation lease"
              (checked == KindOperationCallbackReturned (Right ()))
            changedOwner <-
              withRecoveredKindOperation
                projection2
                operation2
                (\_ -> verifyKindFamilyRetirement retirementOwner (pure False))
            require
              "changed lease authorized retirement"
              (changedOwner == KindOperationCallbackReturned (Left KindFamilyRecoveryLeaseChanged))
            let locator = scopeRoot (bootstrapScope projection2) </> "kind-family-launch-request.json"
            originalLocator <- BS.readFile locator
            BS.writeFile locator "{}"
            changedRecord <-
              withRecoveredKindOperation projection2 operation2 (verifyKindFamilyRetirement retirementOwner)
            require
              "changed launch record authorized retirement"
              (changedRecord == KindOperationCallbackReturned (Left KindFamilyRecoveryRequestConflict))
            BS.writeFile locator originalLocator
            removed <-
              withRecoveredKindOperation
                projection2
                operation2
                (retireKindFamilyPublishedInputs (now + 500 * second) retirementOwner)
            require
              "borrowed owner did not retire exact inputs"
              (removed == KindOperationCallbackReturned (KindFamilyInputRetirement (Right ()) (Right ()) True))
            configPresent <- doesFileExist configFile
            requestPresent <- doesFileExist requestFile
            require "retirement left a published input" (not configPresent && not requestPresent)
            pure retirementOwner
          case borrowed of
            KindFamilyRetirementReturned expired (Right ()) True -> do
              checked <- withRecoveredKindOperation projection2 operation2 (verifyKindFamilyRetirement expired)
              case checked of
                KindOperationCallbackReturned
                  (Left (KindFamilyRecoveryRetirementRefused Retirement.RetirementClosed)) -> pure ()
                other -> fail ("escaped retirement owner remained live: " ++ show other)
            KindFamilyRetirementRefused failure -> fail ("retirement owner refused synthetic record: " ++ show failure)
            KindFamilyRetirementLeaseUnconfirmed -> fail "retirement owner lease unconfirmed"
            KindFamilyRetirementReturned _ closing scope -> fail ("retirement closing unconfirmed: " ++ show (closing, scope))
          -- Reset the isolated receipt to model a separate interrupted probe.
          removeFile
            (scopeRoot (bootstrapScope projection2) </> ("kind-network-probe-" ++ namespace2 ++ "-removed.json"))
          let deleteRecoveryId = if operation2 == replicate 32 'c' then replicate 32 'd' else replicate 32 'c'
          deleteRecovery <-
            either (fail . show) pure (mkProbeRecoveryRequest request2 deleteRecoveryId namespaceUid)
          deleteRecoveryKey <-
            maybe (fail "delete recovery key") pure (kindProbeRecoveryKey operation2 deleteRecoveryId)
          withRecoveredKindOperation
            projection2
            operation2
            ( \stable -> do
                mapM_
                  ( \stage ->
                      recordProbeRecord projection2 operation2 namespace2 stage stable >>= \written ->
                        require "delete recovery fixture record failed" (written == ProbeRecorded)
                  )
                  [ ProbeRecoveryLaunch deleteRecovery
                  , ProbePublicationAttempt deleteRecovery
                  , ProbeRemovalAttempt namespaceUid deleteRecoveryId
                  , ProbeRemovalFailure namespaceUid deleteRecoveryId 7
                  , ProbeRemoved namespaceUid
                  ]
            )
            >>= \observed ->
              require "delete recovery fixture lease failed" (observed == KindOperationCallbackReturned ())
          let attemptPath =
                scopeRoot (bootstrapScope projection2)
                  </> ("kind-network-probe-" ++ namespace2 ++ "-removal-attempt.json")
              foreignRecoveryId = if deleteRecoveryId == replicate 32 'b' then replicate 32 'a' else replicate 32 'b'
          originalAttempt <- BS.readFile attemptPath
          BS8.writeFile
            attemptPath
            ( BS8.pack
                ( Text.unpack
                    ( Text.replace
                        (Text.pack deleteRecoveryId)
                        (Text.pack foreignRecoveryId)
                        (Text.pack (BS8.unpack originalAttempt))
                    )
                )
            )
          wrongAttempt <- deleteNewTestIdentity projection2
          case wrongAttempt of
            [DeleteStep "probe cleanup" False _] -> pure ()
            other -> fail ("delete accepted a foreign cleanup attempt: " ++ show other)
          BS.writeFile attemptPath originalAttempt
          beforeSubmission <- deleteNewTestIdentity projection2
          case beforeSubmission of
            [DeleteStep "probe family settlement" False _] -> pure ()
            other -> fail ("delete accepted missing cleanup submission: " ++ show other)
          deletePublished <-
            Publication.withPublishedHostControllerOwner
              Identity.KindController
              (now + 500 * second)
              deleteRecoveryKey
              (BS8.pack config2)
              (encodeProbeRecoveryRequest deleteRecovery)
              ( \cleanupOwner -> do
                  let (cleanupConfig, cleanupRequest) = Publication.hostPublicationPaths cleanupOwner
                  cleanupInputs <- Inputs.withHostControllerInputs (now + 500 * second) cleanupConfig cleanupRequest $ \inputs -> do
                    connected <- Bus.withSystemdBus (now + 500 * second) ("/run/user/" ++ show uid ++ "/bus") $ \connection -> do
                      actualDomain <- Bus.observeManagerDomain connection
                      sender <- Bus.observeBusSender connection
                      lift $ do
                        require "manager changed during delete cleanup registration" (actualDomain == domain)
                        qualified <- Provider.withQualifiedProvider connection $ \provider -> do
                          registered <-
                            Inputs.registerHostControllerSubmission
                              Identity.KindController
                              inputs
                              deleteRecoveryKey
                              window
                              domain
                              sender
                              provider
                          _ <- either (fail . show) pure registered
                          let verifyId =
                                if operation2 == replicate 32 'b' || deleteRecoveryId == replicate 32 'b'
                                  then replicate 32 'a'
                                  else replicate 32 'b'
                          verifyCoordinates <-
                            either (fail . show) pure (mkProbeRecoveryRequest request2 verifyId namespaceUid)
                          verifyRequest <-
                            either (fail . show) pure (mkProbeAttemptVerifierRequest verifyCoordinates deleteRecoveryId)
                          refusedVerifier <- launchKindProbeVerifier (now + 500 * second) projection2 verifyRequest
                          case refusedVerifier of
                            KindProbeVerifierLaunchRetirement
                              (KindFamilyRetirementReturned (KindFamilyRetirementRefused _) (Right ()) True) -> pure ()
                            other -> fail ("verifier accepted a live cleanup sender: " ++ show other)
                          isolatedVerifier <-
                            either (fail . show) pure (mkIsolatedProbeVerifierRequest verifyCoordinates deleteRecoveryId)
                          refusedIsolated <- launchKindProbeVerifier (now + 500 * second) projection2 isolatedVerifier
                          case refusedIsolated of
                            KindProbeVerifierLaunchRetirement
                              (KindFamilyRetirementReturned (KindFamilyRetirementRefused _) (Right ()) True) -> pure ()
                            other -> fail ("isolated verifier accepted a live cleanup sender: " ++ show other)
                          refusedRecovery <-
                            recoverNeverSentKindProbeVerifierInputs (now + 500 * second) projection2 operation2
                          case refusedRecovery of
                            KindFamilyRetirementReturned (KindFamilyRetirementRefused _) (Right ()) True -> pure ()
                            other -> fail ("verifier recovery accepted a live cleanup sender: " ++ show other)
                          active <- deleteNewTestIdentity projection2
                          case active of
                            [DeleteStep "probe family settlement" False _] -> pure ()
                            other -> fail ("delete accepted a live cleanup sender: " ++ show other)
                        either (fail . show) pure qualified
                    either (fail . show) pure connected
                  either (fail . show) pure cleanupInputs
                  completedDelete <- deleteNewTestIdentity projection2
                  case completedDelete of
                    [DeleteStep "node" True _, DeleteStep "volume" True _, DeleteStep "network" False _] -> pure ()
                    other -> fail ("delete did not advance with both synthetic families retired: " ++ show other)
                  (deleteExit, deleteOut, deleteErr) <-
                    readCreateProcessWithExitCode
                      ( (proc "./.build/prodbox" ["--config", configPath2, "control", "delete", "--yes"])
                          { env = Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")]
                          }
                      )
                      ""
                  let publicDelete = deleteOut ++ deleteErr
                  require
                    "public delete did not retain the incomplete synthetic network result"
                    ( deleteExit == ExitFailure 1
                        && "node: completed" `isInfixOf` publicDelete
                        && "volume: completed" `isInfixOf` publicDelete
                        && "network: NOT completed" `isInfixOf` publicDelete
                    )
                  cleanupPresent <- (||) <$> doesFileExist cleanupConfig <*> doesFileExist cleanupRequest
                  require "delete left cleanup publication payloads" (not cleanupPresent)
                  -- Switch the isolated journal to an uncertain attempt for the
                  -- independent verifier-retirement exercise.
                  let probePrefix = scopeRoot (bootstrapScope projection2) </> ("kind-network-probe-" ++ namespace2)
                      verifyId =
                        if operation2 == replicate 32 'b' || deleteRecoveryId == replicate 32 'b'
                          then replicate 32 'a'
                          else replicate 32 'b'
                  removeFile (probePrefix ++ "-removed.json")
                  removeFile (probePrefix ++ "-removal-failure.json")
                  let attemptPath = probePrefix ++ "-removal-attempt.json"
                  savedAttempt <- BS.readFile attemptPath
                  removeFile attemptPath
                  isolatedCoordinates <-
                    either (fail . show) pure (mkProbeRecoveryRequest request2 verifyId namespaceUid)
                  isolatedRequest <-
                    either (fail . show) pure (mkIsolatedProbeVerifierRequest isolatedCoordinates deleteRecoveryId)
                  withRecoveredKindOperation
                    projection2
                    operation2
                    ( \stable -> do
                        legacy <-
                          either (fail . show) pure (mkProbeAttemptVerifierRequest isolatedCoordinates deleteRecoveryId)
                        refused <- recordProbeRecord projection2 operation2 namespace2 (ProbeVerifierLaunch legacy) stable
                        require "legacy verifier accepted missing attempt" (refused == ProbeRefused)
                        recorded <-
                          recordProbeRecord projection2 operation2 namespace2 (ProbeVerifierLaunch isolatedRequest) stable
                        require "isolated verifier locator refused" (recorded == ProbeRecorded)
                        earlyDiagnostic <-
                          recordProbeRecord
                            projection2
                            operation2
                            namespace2
                            (ProbeVerifierDiagnosticRecord isolatedRequest VerifierJournalRefused)
                            stable
                        require "unpublished verifier diagnostic accepted" (earlyDiagnostic == ProbeRefused)
                        marker <-
                          recordProbeRecord
                            projection2
                            operation2
                            namespace2
                            (ProbeVerifierPublicationAttempt isolatedRequest)
                            stable
                        require "isolated verifier marker refused" (marker == ProbeRecorded)
                        successorId <- case filter (`notElem` [operation2, deleteRecoveryId, verifyId]) (map (replicate 32) "abcdef") of
                          identity : _ -> pure identity
                          [] -> fail "successor identity unavailable"
                        successorCoordinates <-
                          either (fail . show) pure (mkProbeRecoveryRequest request2 successorId namespaceUid)
                        successorVerifier <-
                          either (fail . show) pure (mkIsolatedProbeVerifierRequest successorCoordinates deleteRecoveryId)
                        successor <- either (fail . show) pure (mkProbeSuccessorRequest successorVerifier verifyId)
                        successorLaunch <-
                          recordProbeRecord projection2 operation2 namespace2 (ProbeSuccessorLaunch successor) stable
                        require "successor locator refused" (successorLaunch == ProbeRecorded)
                        incompleteChain <-
                          observeProbeSuccessorChain projection2 operation2 namespace2 isolatedRequest stable
                        require "unpublished successor inferred settled" (incompleteChain == Left ProbeSuccessorMissing)
                        earlyReadback <-
                          recordProbeRecord projection2 operation2 namespace2 (ProbeSuccessorReadback successor) stable
                        require "unpublished successor readback accepted" (earlyReadback == ProbeRefused)
                        successorMarker <-
                          recordProbeRecord projection2 operation2 namespace2 (ProbeSuccessorPublication successor) stable
                        require "successor marker refused" (successorMarker == ProbeRecorded)
                        completeChain <- observeProbeSuccessorChain projection2 operation2 namespace2 isolatedRequest stable
                        require "successor chain changed" (completeChain == Right [successor])
                        successorReadback <-
                          recordProbeRecord projection2 operation2 namespace2 (ProbeSuccessorReadback successor) stable
                        require "successor readback fixture refused" (successorReadback == ProbeRecorded)
                        removeFile (probePrefix ++ "-successor-of-" ++ verifyId ++ ".json")
                        removeFile (probePrefix ++ "-successor-published-" ++ successorId ++ ".json")
                        removeFile (probePrefix ++ "-successor-readback-" ++ successorId ++ ".json")
                        diagnostic <-
                          recordProbeRecord
                            projection2
                            operation2
                            namespace2
                            (ProbeVerifierDiagnosticRecord isolatedRequest VerifierJournalRefused)
                            stable
                        require "verifier diagnostic refused" (diagnostic == ProbeRecorded)
                        diagnosticRead <-
                          observeProbeRecord
                            projection2
                            operation2
                            namespace2
                            (ProbeVerifierDiagnosticRecord isolatedRequest VerifierJournalRefused)
                            stable
                        require "verifier diagnostic changed" (diagnosticRead == ProbeMatches)
                        pending <- observeProbeJournal projection2 operation2 namespace2 stable
                        require
                          "isolated missing-attempt state changed"
                          (pending == ProbeJournalVerifierPending namespaceUid deleteRecoveryId verifyId True)
                        readback <-
                          recordProbeRecord
                            projection2
                            operation2
                            namespace2
                            (ProbeAttemptReadback namespaceUid deleteRecoveryId verifyId)
                            stable
                        require "isolated readback refused" (readback == ProbeRecorded)
                        final <- observeProbeJournal projection2 operation2 namespace2 stable
                        require
                          "isolated readback state changed"
                          (final == ProbeJournalAttemptReadbackRecorded namespaceUid deleteRecoveryId verifyId)
                    )
                    >>= requireReturnedOperation
                  mapM_
                    (removeFile . (probePrefix ++))
                    ["-verifier-launch.json", "-verifier-publication-attempt.json", "-attempt-readback.json"]
                  BS.writeFile attemptPath savedAttempt
                  setFileMode attemptPath 0o400
                  let resumeId =
                        if operation2 == replicate 32 'a' || deleteRecoveryId == replicate 32 'a'
                          then replicate 32 'f'
                          else replicate 32 'a'
                  resumeController <-
                    either
                      (fail . show)
                      pure
                      (mkKindControllerRequest projection2 operation2 ("sha256:" ++ replicate 64 'b') domain window)
                  resumeCoordinates <-
                    either (fail . show) pure (mkProbeRecoveryRequest resumeController resumeId namespaceUid)
                  resumeRequest <-
                    either (fail . show) pure (mkProbeAttemptVerifierRequest resumeCoordinates deleteRecoveryId)
                  withRecoveredKindOperation
                    projection2
                    operation2
                    ( \stable ->
                        recordProbeRecord projection2 operation2 namespace2 (ProbeVerifierLaunch resumeRequest) stable
                    )
                    >>= \observed ->
                      require
                        ("resume verifier locator fixture failed: " ++ show observed)
                        (observed == KindOperationCallbackReturned ProbeRecorded)
                  foreignRequest <-
                    either
                      (fail . show)
                      pure
                      (mkKindControllerRequest projection2 operation2 executableDigest foreignDomain window)
                  foreignCoordinates <-
                    either (fail . show) pure (mkProbeRecoveryRequest foreignRequest resumeId namespaceUid)
                  foreignVerifier <-
                    either (fail . show) pure (mkProbeAttemptVerifierRequest foreignCoordinates deleteRecoveryId)
                  refusedResume <- launchKindProbeVerifier (now + 500 * second) projection2 foreignVerifier
                  case refusedResume of
                    KindProbeVerifierLaunchRetirement
                      ( KindFamilyRetirementReturned
                          ( KindFamilyRetirementReturned
                              (KindOperationCallbackReturned (Left (KindFamilyLaunchProbeRecordRefused ProbeRefused)))
                              (Right ())
                              True
                            )
                          (Right ())
                          True
                        ) -> pure ()
                    other -> fail ("verifier resumed a changed retained request: " ++ show other)
                  resumed <- launchKindProbeVerifier (now + 500 * second) projection2 resumeRequest
                  case resumed of
                    KindProbeVerifierLaunchRetirement
                      ( KindFamilyRetirementReturned
                          ( KindFamilyRetirementReturned
                              ( KindOperationCallbackReturned
                                  (Right (Left KindFamilyLaunchInputMismatch, KindFamilyLaunchUnsentRetired))
                                )
                              (Right ())
                              True
                            )
                          (Right ())
                          True
                        ) -> pure ()
                    other -> fail ("verifier did not resume its pre-publication request: " ++ show other)
                  duplicate <- launchKindProbeVerifier (now + 500 * second) projection2 resumeRequest
                  case duplicate of
                    KindProbeVerifierLaunchRetirement
                      ( KindFamilyRetirementReturned
                          ( KindFamilyRetirementReturned
                              (KindOperationCallbackReturned (Left (KindFamilyLaunchProbeRecordRefused ProbeRefused)))
                              (Right ())
                              True
                            )
                          (Right ())
                          True
                        ) -> pure ()
                    other -> fail ("verifier retried after a publication attempt: " ++ show other)
                  mapM_
                    (removeFile . (probePrefix ++))
                    ["-verifier-launch.json", "-verifier-publication-attempt.json"]
                  verifyCoordinates <-
                    either (fail . show) pure (mkProbeRecoveryRequest request2 verifyId namespaceUid)
                  verifyRequest <-
                    either (fail . show) pure (mkIsolatedProbeVerifierRequest verifyCoordinates deleteRecoveryId)
                  verifyKey <- maybe (fail "verifier key") pure (kindProbeRecoveryKey operation2 verifyId)
                  withRecoveredKindOperation
                    projection2
                    operation2
                    ( \stable ->
                        recordProbeRecord projection2 operation2 namespace2 (ProbeVerifierLaunch verifyRequest) stable
                    )
                    >>= \observed ->
                      require "verifier locator fixture failed" (observed == KindOperationCallbackReturned ProbeRecorded)
                  beforePublish <- recoverNeverSentKindProbeVerifierInputs (now + 500 * second) projection2 operation2
                  case beforePublish of
                    KindFamilyRetirementReturned
                      ( KindFamilyRetirementReturned
                          ( KindOperationCallbackReturned
                              (KindProbeVerifierNeverSentBeforePublication (Right ()) (Right ()) True)
                            )
                          (Right ())
                          True
                        )
                      (Right ())
                      True -> pure ()
                    other -> fail ("verifier pre-publication observation failed: " ++ show other)
                  (reconcileExit, reconcileOut, reconcileErr) <-
                    readCreateProcessWithExitCode
                      ( (proc "./.build/prodbox" ["--config", configPath2, "control", "reconcile"])
                          { env = Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")]
                          }
                      )
                      ""
                  require
                    ("public reconcile omitted verifier never-sent observation: " ++ reconcileOut ++ reconcileErr)
                    ( reconcileExit == ExitFailure 1
                        && "KindProbeVerifierNeverSentBeforePublication (Right ()) (Right ()) True"
                          `isInfixOf` (reconcileOut ++ reconcileErr)
                    )
                  withRecoveredKindOperation
                    projection2
                    operation2
                    ( \stable ->
                        recordProbeRecord
                          projection2
                          operation2
                          namespace2
                          (ProbeVerifierPublicationAttempt verifyRequest)
                          stable
                    )
                    >>= \observed ->
                      require
                        "verifier publication fixture failed"
                        (observed == KindOperationCallbackReturned ProbeRecorded)
                  missingPublication <-
                    recoverNeverSentKindProbeVerifierInputs (now + 500 * second) projection2 operation2
                  case missingPublication of
                    KindFamilyRetirementReturned
                      ( KindFamilyRetirementReturned
                          (KindOperationCallbackReturned (KindProbeVerifierNeverSentInputs (Left _) (Right ()) (Right ()) True))
                          (Right ())
                          True
                        )
                      (Right ())
                      True -> pure ()
                    other -> fail ("missing verifier publication inferred never sent: " ++ show other)
                  removeFile attemptPath
                  withRecoveredKindOperation
                    projection2
                    operation2
                    ( \stable ->
                        recordProbeRecord
                          projection2
                          operation2
                          namespace2
                          (ProbeAttemptReadback namespaceUid deleteRecoveryId verifyId)
                          stable
                    )
                    >>= \observed ->
                      require "verifier readback fixture failed" (observed == KindOperationCallbackReturned ProbeRecorded)
                  unregistered <- deleteNewTestIdentity projection2
                  case unregistered of
                    [DeleteStep "probe verifier settlement" False _] -> pure ()
                    other -> fail ("delete accepted verifier readback without its submission: " ++ show other)
                  verifierPublished <-
                    Publication.withPublishedHostControllerOwner
                      Identity.KindProbeVerifierController
                      (now + 500 * second)
                      verifyKey
                      (BS8.pack config2)
                      (encodeProbeAttemptVerifierRequest verifyRequest)
                      ( \verifierOwner -> do
                          let (verifyConfig, verifyPath) = Publication.hostPublicationPaths verifierOwner
                          verifierInputs <- Inputs.withHostControllerInputs (now + 500 * second) verifyConfig verifyPath $ \inputs -> do
                            connected <- Bus.withSystemdBus (now + 500 * second) ("/run/user/" ++ show uid ++ "/bus") $ \connection -> do
                              actualDomain <- Bus.observeManagerDomain connection
                              sender <- Bus.observeBusSender connection
                              lift $ do
                                require "manager changed during verifier registration" (actualDomain == domain)
                                qualified <- Provider.withQualifiedProvider connection $ \provider -> do
                                  registered <-
                                    Inputs.registerHostControllerSubmission
                                      Identity.KindProbeVerifierController
                                      inputs
                                      verifyKey
                                      window
                                      domain
                                      sender
                                      provider
                                  _ <- either (fail . show) pure registered
                                  live <-
                                    withKindProbeVerifierRetirement
                                      (now + 500 * second)
                                      projection2
                                      operation2
                                      (\_ -> fail "live verifier entered retirement callback" :: IO ())
                                  case live of
                                    KindFamilyRetirementRefused (KindFamilyRecoveryRetirementRefused _) -> pure ()
                                    other -> fail ("live verifier was accepted as retired: " ++ show other)
                                  activeDelete <- deleteNewTestIdentity projection2
                                  case activeDelete of
                                    [DeleteStep "probe verifier settlement" False _] -> pure ()
                                    other -> fail ("delete accepted a live verifier: " ++ show other)
                                either (fail . show) pure qualified
                            either (fail . show) pure connected
                          either (fail . show) pure verifierInputs
                          retired <- withKindProbeVerifierRetirement (now + 500 * second) projection2 operation2 $ \owner ->
                            withRecoveredKindOperation projection2 operation2 $ \stable -> do
                              verified <- verifyKindProbeVerifierRetirement owner stable
                              require "retired verifier did not verify" (verified == Right ())
                              removed <- retireKindProbeVerifierPublishedInputs (now + 500 * second) owner stable
                              require
                                "verifier inputs were not retired"
                                (removed == KindFamilyInputRetirement (Right ()) (Right ()) True)
                          case retired of
                            KindFamilyRetirementReturned (KindOperationCallbackReturned ()) (Right ()) True -> pure ()
                            other -> fail ("retired verifier boundary failed: " ++ show other)
                          afterReadback <- deleteNewTestIdentity projection2
                          case afterReadback of
                            [DeleteStep "node" True _, DeleteStep "volume" True _, DeleteStep "network" False _] -> pure ()
                            other -> fail ("delete did not require and settle the verifier: " ++ show other)
                      )
                      (requireNeverSent "synthetic verifier registration unexpectedly sent")
                  either (fail . show) (const (pure ())) verifierPublished
                  removeFile (probePrefix ++ "-attempt-readback.json")
                  successorId <- case filter (`notElem` [operation2, deleteRecoveryId, verifyId]) (map (replicate 32) "abcdef") of
                    identity : _ -> pure identity
                    [] -> fail "successor delete identity unavailable"
                  scratchId <- case filter
                    (`notElem` [operation2, deleteRecoveryId, verifyId, successorId])
                    (map (replicate 32) "abcdef") of
                    identity : _ -> pure identity
                    [] -> fail "scratch successor identity unavailable"
                  scratchController <-
                    either
                      (fail . show)
                      pure
                      (mkKindControllerRequest projection2 operation2 ("sha256:" ++ replicate 64 '0') domain window)
                  scratchCoordinates <-
                    either (fail . show) pure (mkProbeRecoveryRequest scratchController scratchId namespaceUid)
                  scratchVerifier <-
                    either (fail . show) pure (mkIsolatedProbeVerifierRequest scratchCoordinates deleteRecoveryId)
                  scratchSuccessor <- either (fail . show) pure (mkProbeSuccessorRequest scratchVerifier verifyId)
                  scratchLaunch <-
                    launchKindProbeSuccessor (now + 500 * second) projection2 verifyRequest [] scratchSuccessor
                  case scratchLaunch of
                    KindProbeSuccessorLaunchRetirement
                      ( KindFamilyRetirementReturned
                          ( KindFamilyRetirementReturned
                              ( KindFamilyRetirementReturned
                                  ( KindProbeSuccessorChainReturned
                                      ( KindOperationCallbackReturned
                                          (Right (Left KindFamilyLaunchInputMismatch, KindFamilyLaunchUnsentRetired))
                                        )
                                      True
                                    )
                                  (Right ())
                                  True
                                )
                              (Right ())
                              True
                            )
                          (Right ())
                          True
                        ) -> pure ()
                    other -> fail ("successor wrong-digest publication was not safely retired: " ++ show other)
                  cancelledId <- case filter
                    (`notElem` [operation2, deleteRecoveryId, verifyId, successorId, scratchId])
                    (map (replicate 32) "abcdef") of
                    identity : _ -> pure identity
                    [] -> fail "cancelled successor identity unavailable"
                  cancelledCoordinates <-
                    either (fail . show) pure (mkProbeRecoveryRequest request2 cancelledId namespaceUid)
                  cancelledVerifier <-
                    either (fail . show) pure (mkIsolatedProbeVerifierRequest cancelledCoordinates deleteRecoveryId)
                  cancelledSuccessor <-
                    either (fail . show) pure (mkProbeSuccessorRequest cancelledVerifier scratchId)
                  cancellationStage <-
                    withRecoveredKindOperation
                      projection2
                      operation2
                      ( \stable ->
                          recordProbeRecord projection2 operation2 namespace2 (ProbeSuccessorLaunch cancelledSuccessor) stable
                      )
                  require
                    "cancelled successor locator refused"
                    (cancellationStage == KindOperationCallbackReturned ProbeRecorded)
                  cancellation <-
                    cancelKindProbeSuccessorBeforePublication
                      (now + 500 * second)
                      projection2
                      verifyRequest
                      [scratchSuccessor]
                      cancelledSuccessor
                  case cancellation of
                    KindProbeSuccessorCancellationRetirement
                      ( KindFamilyRetirementReturned
                          ( KindFamilyRetirementReturned
                              ( KindFamilyRetirementReturned
                                  (KindProbeSuccessorChainReturned (KindOperationCallbackReturned ProbeRecorded) True)
                                  (Right ())
                                  True
                                )
                              (Right ())
                              True
                            )
                          (Right ())
                          True
                        ) -> pure ()
                    other -> fail ("staged successor cancellation unconfirmed: " ++ show other)
                  successorCoordinates <-
                    either (fail . show) pure (mkProbeRecoveryRequest request2 successorId namespaceUid)
                  successorVerifier <-
                    either (fail . show) pure (mkIsolatedProbeVerifierRequest successorCoordinates deleteRecoveryId)
                  successor <- either (fail . show) pure (mkProbeSuccessorRequest successorVerifier cancelledId)
                  successorKey <-
                    maybe (fail "successor delete key") pure (kindProbeRecoveryKey operation2 successorId)
                  withRecoveredKindOperation
                    projection2
                    operation2
                    ( \stable ->
                        mapM_
                          ( \stage ->
                              recordProbeRecord projection2 operation2 namespace2 stage stable >>= \written ->
                                require "successor delete record refused" (written == ProbeRecorded)
                          )
                          [ ProbeSuccessorLaunch successor
                          , ProbeSuccessorPublication successor
                          , ProbeSuccessorReadback successor
                          ]
                    )
                    >>= \observed ->
                      require "successor delete lease refused" (observed == KindOperationCallbackReturned ())
                  successorPublished <-
                    Publication.withPublishedHostControllerOwner
                      Identity.KindProbeSuccessorController
                      (now + 500 * second)
                      successorKey
                      (BS8.pack config2)
                      (encodeProbeSuccessorRequest successor)
                      ( \successorOwner -> do
                          let (successorConfig, successorPath) = Publication.hostPublicationPaths successorOwner
                          successorInputs <- Inputs.withHostControllerInputs (now + 500 * second) successorConfig successorPath $ \inputs -> do
                            connected <- Bus.withSystemdBus (now + 500 * second) ("/run/user/" ++ show uid ++ "/bus") $ \connection -> do
                              sender <- Bus.observeBusSender connection
                              lift $ do
                                qualified <- Provider.withQualifiedProvider connection $ \provider -> do
                                  registered <-
                                    Inputs.registerHostControllerSubmission
                                      Identity.KindProbeSuccessorController
                                      inputs
                                      successorKey
                                      window
                                      domain
                                      sender
                                      provider
                                  _ <- either (fail . show) pure registered
                                  activeDelete <- deleteNewTestIdentity projection2
                                  case activeDelete of
                                    [DeleteStep "probe successor settlement" False _] -> pure ()
                                    other -> fail ("delete accepted a live successor: " ++ show other)
                                either (fail . show) pure qualified
                            either (fail . show) pure connected
                          either (fail . show) pure successorInputs
                          successorDelete <- deleteNewTestIdentity projection2
                          case successorDelete of
                            [DeleteStep "node" True _, DeleteStep "volume" True _, DeleteStep "network" False _] -> pure ()
                            other -> fail ("delete did not settle successor readback: " ++ show other)
                          (successorExit, successorOut, successorErr) <-
                            readCreateProcessWithExitCode
                              ( (proc "./.build/prodbox" ["--config", configPath2, "control", "delete", "--yes"])
                                  { env = Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")]
                                  }
                              )
                              ""
                          require
                            "public delete omitted successor retirement result"
                            ( successorExit == ExitFailure 1
                                && "node: completed" `isInfixOf` (successorOut ++ successorErr)
                                && "network: NOT completed" `isInfixOf` (successorOut ++ successorErr)
                            )
                      )
                      (requireNeverSent "synthetic successor registration unexpectedly sent")
                  either (fail . show) (const (pure ())) successorPublished
                  mapM_
                    (removeFile . (probePrefix ++))
                    [ "-successor-of-" ++ verifyId ++ ".json"
                    , "-successor-published-" ++ scratchId ++ ".json"
                    , "-successor-of-" ++ scratchId ++ ".json"
                    , "-successor-cancelled-" ++ cancelledId ++ ".json"
                    , "-successor-of-" ++ cancelledId ++ ".json"
                    , "-successor-published-" ++ successorId ++ ".json"
                    , "-successor-readback-" ++ successorId ++ ".json"
                    ]
                  BS.writeFile attemptPath savedAttempt
                  setFileMode attemptPath 0o400
                  -- Reuse only the isolated fixture journal for a separate never-sent
                  -- verifier; its distinct publication key has no submission record.
                  mapM_
                    (removeFile . (probePrefix ++))
                    ["-verifier-launch.json", "-verifier-publication-attempt.json"]
                  let unsentId =
                        if operation2 == replicate 32 'd' || deleteRecoveryId == replicate 32 'd'
                          then replicate 32 'a'
                          else replicate 32 'd'
                  unsentCoordinates <-
                    either (fail . show) pure (mkProbeRecoveryRequest request2 unsentId namespaceUid)
                  unsentRequest <-
                    either (fail . show) pure (mkIsolatedProbeVerifierRequest unsentCoordinates deleteRecoveryId)
                  unsentKey <- maybe (fail "unsent verifier key") pure (kindProbeRecoveryKey operation2 unsentId)
                  withRecoveredKindOperation
                    projection2
                    operation2
                    ( \stable -> do
                        mapM_
                          ( \stage ->
                              recordProbeRecord projection2 operation2 namespace2 stage stable >>= \written ->
                                require "never-sent verifier fixture record failed" (written == ProbeRecorded)
                          )
                          [ProbeVerifierLaunch unsentRequest, ProbeVerifierPublicationAttempt unsentRequest]
                    )
                    >>= \observed ->
                      require "never-sent verifier fixture lease failed" (observed == KindOperationCallbackReturned ())
                  unsentPublished <-
                    Publication.withPublishedHostControllerOwner
                      Identity.KindProbeVerifierController
                      (now + 500 * second)
                      unsentKey
                      (BS8.pack config2)
                      (encodeProbeAttemptVerifierRequest unsentRequest)
                      (\_ -> pure ())
                      (requireNeverSent "synthetic never-sent verifier unexpectedly sent")
                  either (fail . show) (const (pure ())) unsentPublished
                  unsent <- recoverNeverSentKindProbeVerifierInputs (now + 500 * second) projection2 operation2
                  case unsent of
                    KindFamilyRetirementReturned
                      ( KindFamilyRetirementReturned
                          ( KindOperationCallbackReturned
                              (KindProbeVerifierNeverSentInputs (Right ()) (Right ()) (Right ()) True)
                            )
                          (Right ())
                          True
                        )
                      (Right ())
                      True -> pure ()
                    other -> fail ("never-sent verifier input retirement failed: " ++ show other)
                  resumedUnsent <- recoverNeverSentKindProbeVerifierInputs (now + 500 * second) projection2 operation2
                  case resumedUnsent of
                    KindFamilyRetirementReturned
                      ( KindFamilyRetirementReturned
                          ( KindOperationCallbackReturned
                              (KindProbeVerifierNeverSentInputs (Right ()) (Right ()) (Right ()) True)
                            )
                          (Right ())
                          True
                        )
                      (Right ())
                      True -> pure ()
                    other -> fail ("never-sent verifier input retirement did not resume: " ++ show other)
              )
              (requireNeverSent "synthetic delete registration unexpectedly sent")
          either (fail . show) (const (pure ())) deletePublished
      )
      (requireNeverSent "synthetic registration unexpectedly sent")
  either (fail . show) (const (pure ())) published
  let config3 =
        Text.unpack
          (Text.replace "deployment_id = \"fixture\"" "deployment_id = \"fixture3\"" (Text.pack config))
      configPath3 = anchor </> "settings3.dhall"
      operation3 = init operation ++ (if last operation == 'a' then "b" else "a")
  writeFile configPath3 config3
  projection3 <- readBootstrapProjection configPath3 >>= either (fail . show) pure
  prepareFreshScope (bootstrapScope projection3) (replicate 32 'b') >>= \result3 ->
    require "legacy test root preparation failed" (result3 == FreshScopePrepared)
  recordKindIntent projection3 operation3 >>= \observed -> require "legacy operation intent failed" (observed == KindIntentRecorded)
  prerequisiteEnd <- (+ 5000000000) <$> getMonotonicTimeNSec
  wrongProtocol <- reconcileFamilyPrerequisites prerequisiteEnd projection3 operation3 id
  require
    "family prerequisite worker accepted a legacy operation"
    (wrongProtocol == ReconcileFamilyAdmissionRefused)
  legacy <-
    withRecoveredKindOperation projection3 operation3 $
      recordControllerSubmissionIntent projection3 operation3 (replicate 64 'e')
  require
    "legacy submission marker was not recorded"
    (legacy == KindOperationCallbackReturned ControllerSubmissionRecorded)
  request3 <-
    either
      (fail . show)
      pure
      (mkKindControllerRequest projection3 operation3 executableDigest domain window)
  refusedLegacy <- launchKindFamily (now + 560 * second) projection3 request3
  case refusedLegacy of
    KindFamilyLaunchLease
      (KindOperationCallbackReturned (Left KindFamilyLaunchLegacySubmissionUnconfirmed)) -> pure ()
    other -> fail ("legacy submission did not refuse a family launch: " ++ show other)
  let config4 =
        Text.unpack
          (Text.replace "deployment_id = \"fixture\"" "deployment_id = \"fixture4\"" (Text.pack config))
      configPath4 = anchor </> "settings4.dhall"
      operation4 = init operation ++ (if last operation == '9' then "8" else "9")
  writeFile configPath4 config4
  projection4 <- readBootstrapProjection configPath4 >>= either (fail . show) pure
  prepareFreshScope (bootstrapScope projection4) (replicate 32 'b') >>= \observed ->
    require "pre-publication test root preparation failed" (observed == FreshScopePrepared)
  recordKindFamilyIntent projection4 operation4 >>= \observed -> require "pre-publication family intent failed" (observed == KindIntentRecorded)
  request4 <-
    either
      (fail . show)
      pure
      (mkKindControllerRequest projection4 operation4 executableDigest domain window)
  withRecoveredKindOperation projection4 operation4 (recordFamilyLaunch projection4 request4) >>= \observed ->
    require
      "pre-publication locator failed"
      (observed == KindOperationCallbackReturned FamilyLaunchRecorded)
  (preDeleteExit, preDeleteOut, preDeleteErr) <-
    readCreateProcessWithExitCode
      ( (proc "./.build/prodbox" ["--config", configPath4, "control", "delete", "--yes"])
          { env = Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")]
          }
      )
      ""
  require
    "public delete did not cancel before publication and retain incomplete network"
    ( preDeleteExit == ExitFailure 1
        && "pre-publication family cancelled" `isInfixOf` (preDeleteOut ++ preDeleteErr)
        && "network: NOT completed" `isInfixOf` (preDeleteOut ++ preDeleteErr)
    )
  (_, cancelledStatusOut, cancelledStatusErr) <-
    readCreateProcessWithExitCode
      ( (proc "./.build/prodbox" ["--config", configPath4, "control", "status"])
          { env = Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")]
          }
      )
      ""
  require
    "public status omitted the pre-publication cancellation"
    ("KindFamilyPublicationCancelled" `isInfixOf` (cancelledStatusOut ++ cancelledStatusErr))
  withRecoveredKindOperation
    projection4
    operation4
    (recordFamilyPublicationAttempt projection4 request4)
    >>= \observed ->
      require
        "publication marker accepted after cancellation"
        (observed == KindOperationCallbackReturned FamilyLaunchRefused)
  cancelledLaunch <- launchKindFamily (now + 560 * second) projection4 request4
  case cancelledLaunch of
    KindFamilyLaunchLease
      (KindOperationCallbackReturned (Left (KindFamilyLaunchRecordRefused FamilyLaunchAlreadyExists))) -> pure ()
    other -> fail ("cancelled family was allowed to publish: " ++ show other)
  let config5 =
        Text.unpack
          (Text.replace "deployment_id = \"fixture\"" "deployment_id = \"fixture5\"" (Text.pack config))
      configPath5 = anchor </> "settings5.dhall"
      operation5 = init operation ++ (if last operation == '8' then "7" else "8")
  writeFile configPath5 config5
  projection5 <- readBootstrapProjection configPath5 >>= either (fail . show) pure
  prepareFreshScope (bootstrapScope projection5) (replicate 32 'b') >>= \observed ->
    require "unlaunched test root preparation failed" (observed == FreshScopePrepared)
  recordKindFamilyIntent projection5 operation5 >>= \observed -> require "unlaunched family intent failed" (observed == KindIntentRecorded)
  (unlaunchedExit, unlaunchedOut, unlaunchedErr) <-
    readCreateProcessWithExitCode
      ( (proc "./.build/prodbox" ["--config", configPath5, "control", "delete", "--yes"])
          { env = Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")]
          }
      )
      ""
  require
    "public delete accepted a missing family locator"
    ( unlaunchedExit == ExitFailure 1
        && "family settlement: NOT completed" `isInfixOf` (unlaunchedOut ++ unlaunchedErr)
    )
  absentLaunch <-
    withRecoveredKindOperation projection5 operation5 (observeFamilyLaunch projection5 operation5)
  require
    "delete manufactured a locator for an unsettled prerequisite creator"
    (absentLaunch == KindOperationCallbackReturned FamilyLaunchMissing)
  let config6 =
        Text.unpack
          (Text.replace "deployment_id = \"fixture\"" "deployment_id = \"fixture6\"" (Text.pack config))
      configPath6 = anchor </> "settings6.dhall"
      operation6 = init operation ++ (if last operation == '7' then "6" else "7")
  writeFile configPath6 config6
  projection6 <- readBootstrapProjection configPath6 >>= either (fail . show) pure
  prepareFreshScope (bootstrapScope projection6) (replicate 32 'b') >>= \observed ->
    require "unlaunched owner-family root preparation failed" (observed == FreshScopePrepared)
  recordKindOwnerFamilyIntent projection6 operation6 >>= \observed ->
    require "unlaunched owner-family intent failed" (observed == KindIntentRecorded)
  (ownerExit, ownerOut, ownerErr) <-
    readCreateProcessWithExitCode
      ( (proc "./.build/prodbox" ["--config", configPath6, "control", "delete", "--yes"])
          { env = Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")]
          }
      )
      ""
  require
    "public delete did not fence the owner-first operation"
    ( ownerExit == ExitSuccess
        && "unlaunched owner-family fenced before cleanup" `isInfixOf` (ownerOut ++ ownerErr)
        && "no owner-family network intent or attempt was recorded" `isInfixOf` (ownerOut ++ ownerErr)
    )
  ownerRecord <- withRecoveredKindOperation projection6 operation6 $ \stable -> do
    retained <- observeFamilyLaunch projection6 operation6 stable
    cancelled <- observeFamilyPrePublicationCancellation projection6 operation6 stable
    marker <- observeFamilyPublicationAttempt projection6 operation6 stable
    pure (retained, cancelled, marker)
  case ownerRecord of
    KindOperationCallbackReturned
      (FamilyLaunchObserved retained, FamilyLaunchObserved cancelled, FamilyLaunchMissing)
        | retained == cancelled -> do
            refused <- launchKindFamily (now + 560 * second) projection6 retained
            case refused of
              KindFamilyLaunchLease
                (KindOperationCallbackReturned (Left (KindFamilyLaunchRecordRefused FamilyLaunchAlreadyExists))) -> pure ()
              other -> fail ("fenced owner-first operation was allowed to publish: " ++ show other)
    other -> fail ("unlaunched owner-family cancellation did not bind the locator: " ++ show other)
  let config7 =
        Text.unpack
          (Text.replace "deployment_id = \"fixture\"" "deployment_id = \"fixture7\"" (Text.pack config))
      configPath7 = anchor </> "settings7.dhall"
      operation7 = init operation ++ (if last operation == '6' then "5" else "6")
  writeFile configPath7 config7
  projection7 <- readBootstrapProjection configPath7 >>= either (fail . show) pure
  prepareFreshScope (bootstrapScope projection7) (replicate 32 'b') >>= \observed ->
    require "owner-family partial root preparation failed" (observed == FreshScopePrepared)
  recordKindOwnerFamilyIntent projection7 operation7 >>= \observed ->
    require "owner-family partial intent failed" (observed == KindIntentRecorded)
  now7 <- getMonotonicTimeNSec
  window7 <-
    maybe
      (fail "partial family window")
      pure
      ( Identity.hostExecutionWindow
          (now7 + 180 * second)
          (now7 + 120 * second)
          (now7 + 130 * second)
          (now7 + 160 * second)
          (now7 + 170 * second)
      )
  request7 <-
    either
      (fail . show)
      pure
      (mkKindControllerRequest projection7 operation7 executableDigest domain window7)
  key7 <- maybe (fail "owner-family key") pure (kindControllerOperationKey operation7)
  withRecoveredKindOperation
    projection7
    operation7
    ( \stable -> do
        recordFamilyLaunch projection7 request7 stable >>= \written -> require "partial locator failed" (written == FamilyLaunchRecorded)
        recordFamilyPublicationAttempt projection7 request7 stable >>= \written -> require "partial marker failed" (written == FamilyLaunchRecorded)
    )
    >>= \observed ->
      require "partial family lease failed" (observed == KindOperationCallbackReturned ())
  partialPublished <-
    Publication.withPublishedHostControllerOwner
      Identity.KindController
      (now7 + 120 * second)
      key7
      (BS8.pack config7)
      (encodeKindControllerRequest request7)
      ( \owner -> do
          let (settings, requestPath7) = Publication.hostPublicationPaths owner
          registered <- Inputs.withHostControllerInputs (now7 + 120 * second) settings requestPath7 $ \inputs -> do
            connected <- Bus.withSystemdBus (now7 + 120 * second) ("/run/user/" ++ show uid ++ "/bus") $ \connection -> do
              sender <- Bus.observeBusSender connection
              lift $ do
                qualified <- Provider.withQualifiedProvider connection $ \provider -> do
                  registeredRecord <-
                    Inputs.registerHostControllerSubmission
                      Identity.KindController
                      inputs
                      key7
                      window7
                      domain
                      sender
                      provider
                  _ <- either (fail . show) pure registeredRecord
                  active <- deleteNewTestIdentity projection7
                  case active of
                    [DeleteStep "family settlement" False _] -> pure ()
                    other -> fail ("partial cleanup accepted a live owner-family sender: " ++ show other)
                either (fail . show) pure qualified
            either (fail . show) pure connected
          either (fail . show) pure registered
          settled <- deleteNewTestIdentity projection7
          case settled of
            [DeleteStep "node" True _, DeleteStep "volume" True _, DeleteStep "network" True detail]
              | "no owner-family network intent or attempt was recorded" `isInfixOf` detail -> pure ()
            other ->
              fail ("settled owner-family without a probe did not establish the no-intent state: " ++ show other)
      )
      (requireNeverSent "synthetic partial-family registration unexpectedly sent")
  either (fail . show) (const (pure ())) partialPublished
  let config8 =
        Text.unpack
          (Text.replace "deployment_id = \"fixture\"" "deployment_id = \"fixture8\"" (Text.pack config))
      configPath8 = anchor </> "settings8.dhall"
      operation8 = init operation ++ (if last operation == '5' then "4" else "5")
  writeFile configPath8 config8
  projection8 <- readBootstrapProjection configPath8 >>= either (fail . show) pure
  prepareFreshScope (bootstrapScope projection8) (replicate 32 'b') >>= \observed ->
    require "changed-protocol test root preparation failed" (observed == FreshScopePrepared)
  recordKindOwnerFamilyIntent projection8 operation8 >>= \observed ->
    require "changed-protocol owner intent failed" (observed == KindIntentRecorded)
  request8 <-
    either
      (fail . show)
      pure
      (mkKindControllerRequest projection8 operation8 executableDigest domain window7)
  changedProtocol <- withCancelledUnlaunchedOwnerFamily projection8 request8 $ \admission -> do
    before <- withRecoveredKindOperation projection8 operation8 admission
    require
      "owner-family cancellation did not admit its original protocol"
      (before == KindOperationCallbackReturned True)
    let path = scopeRoot (bootstrapScope projection8) </> "kind-intent.json"
    stored <- BS.readFile path
    external <- case Aeson.decodeStrict' stored of
      Just (Aeson.Object fields) ->
        pure $
          Aeson.Object $
            KeyMap.insert "schema_version" (Aeson.toJSON (3 :: Int)) $
              KeyMap.insert "controller_protocol" (Aeson.toJSON ("family-v1" :: String)) fields
      _ -> fail "owner-family intent was not an object"
    BL.writeFile path (Aeson.encode external)
    after <- withRecoveredKindOperation projection8 operation8 admission
    require
      "changed owner-family protocol retained cleanup admission"
      (after == KindOperationCallbackReturned False)
  case changedProtocol of
    KindFamilyPrePublicationReturned () False -> pure ()
    other -> fail ("changed cancellation protocol was not unconfirmed: " ++ show other)
  putStrLn
    "PASS dispatcher input and missing-root refusal, unmanaged parent refusal, and post-callback change"

requireNeverSent :: String -> Publication.HostPublicationDisposition -> IO ()
requireNeverSent message disposition = case disposition of
  Publication.PublicationNeverSent _ -> pure ()
  Publication.PublicationPossiblySent -> fail message

requireReturnedOperation :: KindOperationOutcome () -> IO ()
requireReturnedOperation outcome = case outcome of
  KindOperationCallbackReturned () -> pure ()
  other -> fail (show other)
