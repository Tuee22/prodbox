{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- Actual canonical owner/manager/kernel boundaries, with synthetic inputs.
-- Controller kinds and cross-kind refusals use the native manager profile.
-- No Authority or AWS effect is requested.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, bracket, throwIO, try)
import Control.Monad (unless, when)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (runExceptT)
import Data.Aeson (eitherDecode, encode, object, withObject, (.:), (.=))
import Data.Aeson.Types (parseEither)
import Data.ByteString.Char8 qualified as Chars
import Data.ByteString.Lazy qualified as Lazy
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Text qualified as Text
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import HostOperationRpcBirthFixture
import Prodbox.Control.SealedTool qualified as Sealed
import Prodbox.Subprocess qualified as Subprocess
import Prodbox.Subprocess.HostControllerArguments qualified as Arguments
import Prodbox.Subprocess.HostControllerInputRetirement qualified as Reaper
import Prodbox.Subprocess.HostControllerInputs qualified as Inputs
import Prodbox.Subprocess.HostControllerPublication qualified as Publication
import Prodbox.Subprocess.HostOperationFamily qualified as Family
import Prodbox.Subprocess.HostOperationRetirement qualified as Retirement
import Prodbox.Subprocess.KernelScope qualified as Kernel
import Prodbox.Subprocess.SystemdBus qualified as Bus
import Prodbox.Subprocess.SystemdIdentity qualified as Identity
import Prodbox.Test.MutationOutcome (MutationTest (..), validateMutationSelection)
import Prodbox.Test.MutationOutputInventory
  ( MutationOutputObservation (..)
  , mutationOutputLimits
  , mutationWorkspaceSameMount
  , observeMutationOutputInventory
  )
import Prodbox.Test.MutationSnapshot (MutationSnapshot, makeMutationSnapshot)
import Prodbox.Test.MutationSnapshotObserve
  ( MutationSnapshotObservation (MutationSnapshotDiffers, MutationSnapshotObservationTimedOut)
  )
import Prodbox.Test.MutationSnapshotWrite (mutationSnapshotRootIdentity)
import Prodbox.Test.MutationWorkerSettlement
  ( MutationHostObservationError (..)
  , MutationHostObservationOutcome (..)
  , retireMutationOutputAfterHostSettlement
  , withMutationHostRetirementObservation
  )
import Prodbox.Test.MutationWorkspace
  ( MutationWorkspaceOutcome (..)
  , beginMutationOutputRetirement
  , checkpointMutationWorkspaceOutput
  , withNewMutationWorkspace
  , withRecoveredMutableMutationOutputWorkspace
  , withRecoveredMutationOutputCheckpoint
  , withRecoveredMutationWorkspace
  , withRecoveredMutationWorkspaceBefore
  , withRetiringMutationOutputCheckpoint
  )
import Prodbox.Test.MutationWorkspaceIntent
  ( MutationOutputCheckpointObservation (..)
  , MutationWorkspaceIntentWrite (..)
  , mutationWorkspaceWorkerKey
  )
import Prodbox.Test.MutationWorkspaceWorker
  ( MutationOperationWorkerResult (..)
  , MutationSealedOperationResult (..)
  , decodeSealedMutationOperation
  , runRecoveredMutationOperationWorkerBefore
  , runSealedMutationOperationWorkerBefore
  )
import Prodbox.Test.Qualification.Evidence (mkPublicEvidenceDigest)
import Prodbox.Test.Qualification.SourceIdentity
  ( ManifestFileType (..)
  , SourceCandidate (..)
  , WorktreeState (..)
  , mkGitHead
  )
import Prodbox.Test.ReviewedMutation (ReviewedMutation (M01OverlappingRoots), reviewedTestPath)
import System.Directory (createDirectory, doesFileExist, makeAbsolute)
import System.Environment (getArgs)
import System.Exit (ExitCode (ExitSuccess))
import System.FilePath ((</>))
import System.Posix.Files (fileSize, getFdStatus, getFileStatus, setFileMode)
import System.Posix.IO qualified as Posix
import System.Posix.User (getEffectiveUserID)
import System.Process (readProcessWithExitCode)
import Text.Read (readMaybe)

main :: IO ()
main = do
  arguments <- getArgs
  case arguments of
    "internal-rpc-birth-controller" : flags -> worker Identity.RpcBirthController flags
    "internal-cascade-controller" : flags -> worker Identity.OrdinaryCascadeController flags
    "internal-mutation-controller" : flags -> worker Identity.MutationController flags
    ["birth", directory] -> launch Identity.RpcBirthController Identity.RpcBirthController directory Nothing
    ["cross", directory] -> launch Identity.RpcBirthController Identity.OrdinaryCascadeController directory Nothing
    ["ordinary", directory] -> launch Identity.OrdinaryCascadeController Identity.OrdinaryCascadeController directory Nothing
    ["reverse", directory] -> launch Identity.OrdinaryCascadeController Identity.RpcBirthController directory Nothing
    ["mutation", directory] -> launch Identity.MutationController Identity.MutationController directory Nothing
    ["mutation-cross", directory] -> launch Identity.MutationController Identity.RpcBirthController directory Nothing
    ["mutation-test", directory, binary] -> launch Identity.MutationController Identity.MutationController directory (Just binary)
    ["recover", directory] -> recover directory
    _ -> fail "expected one closed publication-kind fixture"

-- Recover the exact published inputs for one retained fixture operation.
-- The host observer and input reaper supply the actual settlement checks.
recover :: FilePath -> IO ()
recover directory = do
  encoded <- Lazy.readFile (directory </> "field.json")
  value <- right (eitherDecode encoded)
  (keyText, request) <-
    right
      (parseEither (withObject "fixture recovery" $ \o -> (,) <$> o .: "key" <*> o .: "request") value)
  key <- maybe (fail "invalid retained fixture key") pure (Identity.hostExecutionKeyFromText keyText)
  ending <- (+ 10000000000) <$> getMonotonicTimeNSec
  record <- right =<< Inputs.readHostControllerSubmission ending request key
  uid <- getEffectiveUserID
  result <- Bus.withSystemdBus ending (socket uid) $ \connection -> lift $
    Retirement.withHostOperationRetirement connection record $ \owner -> do
      receipt <- right =<< Reaper.retireHostControllerInputs ending owner record
      unless (Reaper.hostInputRetirementReceiptMatches receipt record) (fail "recovery receipt mismatch")
  _ <- right =<< right result
  writeFile (directory </> "recovery-result") "inputs-retired"

worker :: Identity.HostControllerKind -> [String] -> IO ()
worker kind flags = do
  arguments <- right (Arguments.parseHostControllerArguments flags)
  let window = Arguments.controllerOriginalWindow arguments
      work = Identity.hostExecutionWorkEnd window
      key = Arguments.controllerOperationKey arguments
      configuration = Arguments.controllerConfigurationPath arguments
      request = Arguments.controllerRequestPath arguments
  right
    =<< Family.withPinnedHostControllerProgram
      kind
      work
      (Arguments.controllerInputFingerprint arguments)
      configuration
      request
      ( \program -> do
          bytes <- right =<< Family.readHostControllerProgramInputs program
          observed <- right (decodeObserved (Lazy.fromStrict (Family.hostControllerConfigurationBytes bytes)))
          (directory, digest, toolPath, toolSize, realTest) <- case lines (Chars.unpack (Family.hostControllerRequestBytes bytes)) of
            [root, hash, tool, sizeText, mode] -> case readMaybe sizeText of
              Just size | size > 0 && mode `elem` ["synthetic", "test"] -> pure (root, hash, tool, size, mode == "test")
              _ -> fail "invalid fixture request size or mode"
            _ -> fail "invalid fixture request"
          (plan, budget) <-
            if kind == Identity.MutationController
              then do
                (funded, value) <-
                  if realTest then fixtureMutationTestPlanFrom toolSize observed else fixtureMutationPlanFrom observed
                pure (funded, Just value)
              else do unfunded <- fixturePlanFrom observed; pure (unfunded, Nothing)
          helper <- maybe (fail "helper bounds") pure (Family.hostOperationHelperBounds 20000 20000)
          intent <- right =<< Family.newHostOperationIntent kind plan helper key window
          uid <- getEffectiveUserID
          entered <- Bus.withSystemdBus (Identity.hostExecutionOuterEnd window) (socket uid) $ \connection -> lift $
            Kernel.withObservedOperationParent connection intent program $ \owner -> do
              checked <- Kernel.verifyOperationParentBeforeEffect owner
              case checked of
                Left cause -> pure (Left cause)
                Right () -> do
                  exercised <-
                    try
                      ( if realTest
                          then exerciseRealTest directory digest toolPath toolSize budget work owner
                          else exerciseMutation kind directory digest budget work owner
                      )
                  case exercised of
                    Left failure -> do
                      writeFile (directory </> "controller-failure") (show (failure :: SomeException))
                      throwIO failure
                    Right () -> pure ()
                  writeFile (directory </> "controller-kind-observed") (show kind)
                  pure (Right ())
          right =<< right entered
      )

launch
  :: Identity.HostControllerKind -> Identity.HostControllerKind -> FilePath -> Maybe FilePath -> IO ()
launch publisherKind kind supplied testBinary = do
  directory <- makeAbsolute supplied
  setFileMode directory 0o700
  createDirectory (directory </> "output-project")
  setFileMode (directory </> "output-project") 0o700
  (basePlan, observed) <- fixturePlan
  toolPath <- maybe (pure "/usr/bin/python3") makeAbsolute testBinary
  toolSize <- toInteger . fileSize <$> getFileStatus toolPath
  plan <-
    if kind == Identity.MutationController
      then
        fst
          <$> maybe
            (fixtureMutationPlanFrom observed)
            (const (fixtureMutationTestPlanFrom toolSize observed))
            testBinary
      else pure basePlan
  (hashExit, hashText, _) <- readProcessWithExitCode "/usr/bin/sha256sum" [toolPath] ""
  let digest = "sha256:" <> take 64 hashText
  unless (hashExit == ExitSuccess && length hashText >= 66) (fail "fixture tool digest unavailable")
  snapshot <- fixtureSnapshot
  outputPrepared <-
    withNewMutationWorkspace
      (directory </> "output-project")
      fixtureOperation
      snapshot
      ( \root stable -> do
          ready <- stable
          same <- mutationWorkspaceSameMount root root
          other <-
            bracket
              (Posix.openFd "/proc" Posix.ReadOnly Posix.defaultFileFlags {Posix.directory = True})
              Posix.closeFd
              $ mutationWorkspaceSameMount root
          pure (ready && same && not other)
      )
  unless
    (outputPrepared == MutationWorkspaceCallbackReturned True)
    (fail "output workspace preparation refused")
  prepared <- withNewMutationWorkspace directory fixtureOperation snapshot $ \root stable -> do
    ready <- stable
    identity <- mutationSnapshotRootIdentity <$> getFdStatus root
    pure (if ready then mutationWorkspaceWorkerKey fixtureOperation snapshot identity else Nothing)
  key <- case prepared of
    MutationWorkspaceCallbackReturned (Just value) -> pure value
    other -> fail ("mutation workspace preparation refused: " <> show other)
  otherPrepared <-
    withNewMutationWorkspace directory (replicate 32 'b') snapshot (\_ stable -> stable)
  unless
    (otherPrepared == MutationWorkspaceCallbackReturned True)
    (fail "foreign source workspace preparation refused")
  started <- getMonotonicTimeNSec
  let extra = maybe 0 (const 40000000000) testBinary
      outer = started + 20000000000 + extra
      work = started + 15000000000 + extra
      hard = started + 16000000000 + extra
      stop = started + 17000000000 + extra
      finish = started + 18000000000 + extra
  window <-
    maybe (fail "fixture window") pure (Identity.hostExecutionWindow outer work hard stop finish)
  helper <- maybe (fail "helper bounds") pure (Family.hostOperationHelperBounds 20000 20000)
  intent <- right =<< Family.newHostOperationIntent kind plan helper key window
  uid <- getEffectiveUserID
  result <-
    right
      =<< Publication.withPublishedHostControllerOwner
        publisherKind
        work
        key
        (Lazy.toStrict (encode (observedValue observed)))
        ( Chars.pack
            (unlines [directory, digest, toolPath, show toolSize, maybe "synthetic" (const "test") testBinary])
        )
        ( \publication -> do
            let (configuration, request) = Publication.hostPublicationPaths publication
            Lazy.writeFile (directory </> "field.json") $
              encode $
                object
                  [ "kind" .= show kind
                  , "key" .= Identity.hostExecutionKeyText key
                  , "tool_digest" .= digest
                  , "tool_size" .= toolSize
                  , "tool_path" .= toolPath
                  , "configuration" .= configuration
                  , "request" .= request
                  , "units" .= map (Family.hostOperationUnitName intent) [minBound .. maxBound]
                  , "outer_ns" .= outer
                  , "work_ns" .= work
                  , "hard_ns" .= hard
                  , "stop_ns" .= stop
                  , "finish_ns" .= finish
                  ]
            right
              =<< Publication.withHostPublicationSubmission
                publication
                ( \permit ->
                    right
                      =<< Family.withCurrentHostControllerProgram
                        kind
                        work
                        configuration
                        request
                        ( \program -> do
                            submitted <- Bus.withSystemdBus outer (socket uid) $ \connection -> lift $ do
                              sent <- Family.submitPublishedHostOperationFamily permit connection intent program
                              writeFile (directory </> "submission-result") (show sent)
                              case sent of
                                Left cause -> pure (Left cause)
                                Right () -> do
                                  waitUntil work (doesFileExist (directory </> "controller-kind-observed"))
                                  seen <- readFile (directory </> "controller-kind-observed")
                                  unless (seen == show kind) (fail "controller kind differed from the selected program")
                                  waitUntil finish $
                                    Family.hostOperationAbsent
                                      <$> (right =<< runExceptT (Family.observeHostOperationFamily connection intent))
                                  pure (Right ())
                            right submitted
                        )
                )
        )
        ( \disposition -> do
            ending <- (+ 10000000000) <$> getMonotonicTimeNSec
            case disposition of
              Publication.PublicationNeverSent proof -> do
                _ <- right =<< Reaper.retireNeverSentHostControllerInputs ending proof
                pure ("never-sent" :: String)
              Publication.PublicationPossiblySent -> do
                let published = Publication.hostControllerPublishedDirectory publisherKind uid key
                    request = published </> Publication.hostControllerRequestName
                closed <- Bus.withSystemdBus ending (socket uid) $ \connection -> lift $ do
                  record <- right =<< Inputs.readHostControllerSubmission ending request key
                  writeFile (directory </> "retirement-kind") (show (Inputs.hostControllerSubmissionKind record))
                  Retirement.withHostOperationRetirement connection record $ \owner -> do
                    settlement <- withRecoveredMutationWorkspace directory fixtureOperation snapshot $ \root stable -> do
                      ready <- stable
                      identity <- mutationSnapshotRootIdentity <$> getFdStatus root
                      if not ready
                        then fail "mutation workspace changed before settlement observation"
                        else withMutationHostRetirementObservation ending owner record fixtureOperation snapshot identity $ \borrowed ->
                          Retirement.verifyHostOperationRetirementBefore ending borrowed
                    let expected =
                          if kind == Identity.MutationController
                            then MutationHostObservationConfirmed (Right ())
                            else MutationHostObservationRefused MutationHostObservationRecordMismatch
                    unless (settlement == MutationWorkspaceCallbackReturned expected) $
                      fail ("mutation retirement observation classification changed: " <> show settlement)
                    when (kind == Identity.MutationController) $ do
                      limits <- maybe (fail "invalid output limits") pure (mutationOutputLimits 128 1048576 8 5000000)
                      outputRetired <- withRecoveredMutationWorkspace directory fixtureOperation snapshot $ \root stable -> do
                        ready <- stable
                        unless ready (fail "source changed before output retirement")
                        identity <- mutationSnapshotRootIdentity <$> getFdStatus root
                        let project = directory </> "output-project"
                        refused <-
                          beginMutationOutputRetirement
                            limits
                            key
                            fixtureCheckpoint
                            (pure False)
                            project
                            fixtureOperation
                            snapshot
                        unless (refused == MutationWorkspaceChanged) (fail "unsettled output retirement accepted")
                        missing <-
                          beginMutationOutputRetirement
                            limits
                            key
                            (replicate 32 'd')
                            (pure True)
                            project
                            fixtureOperation
                            snapshot
                        unless (missing == MutationWorkspaceOutputCheckpointRefused MutationOutputCheckpointMissing) $
                          fail "missing checkpoint retirement accepted"
                        foreignKey <-
                          maybe (fail "invalid foreign key") pure (Identity.hostExecutionKeyFromText (replicate 64 'e'))
                        wrongKey <-
                          beginMutationOutputRetirement
                            limits
                            foreignKey
                            fixtureCheckpoint
                            (pure True)
                            project
                            fixtureOperation
                            snapshot
                        unless (wrongKey == MutationWorkspaceOutputCheckpointRefused MutationOutputCheckpointConflict) $
                          fail "foreign worker retirement accepted"
                        retireMutationOutputAfterHostSettlement
                          ending
                          owner
                          record
                          fixtureOperation
                          snapshot
                          identity
                          limits
                          fixtureCheckpoint
                          project
                          fixtureOperation
                          snapshot
                      unless
                        ( outputRetired
                            == MutationWorkspaceCallbackReturned
                              (MutationHostObservationConfirmed MutationWorkspaceRetirementRecorded)
                        )
                        $ fail ("output retirement refused: " <> show outputRetired)
                      let project = directory </> "output-project"
                      active <-
                        withRecoveredMutationOutputCheckpoint
                          limits
                          key
                          fixtureCheckpoint
                          project
                          fixtureOperation
                          snapshot
                          (\_ stable -> stable)
                      case active of
                        MutationWorkspaceCallbackReturned _ -> fail "retired output reopened as active"
                        _ -> pure ()
                      retired <-
                        withRetiringMutationOutputCheckpoint
                          limits
                          key
                          fixtureCheckpoint
                          project
                          fixtureOperation
                          snapshot
                          (\_ stable -> stable)
                      unless
                        (retired == MutationWorkspaceCallbackReturned True)
                        (fail "retired checkpoint did not reopen")
                    receipt <- right =<< Reaper.retireHostControllerInputs ending owner record
                    unless
                      (Reaper.hostInputRetirementReceiptMatches receipt record)
                      (fail "input retirement changed the original record")
                _ <- right =<< right closed
                pure "submitted"
        )
  writeFile (directory </> "closing-result") (show result)
  when (kind == Identity.MutationController && publisherKind == kind) $ do
    case testBinary of
      Nothing -> do
        output <-
          readFile
            ( directory
                </> "output-project"
                </> ".build"
                </> "mutation-workspaces"
                </> fixtureOperation
                </> "worker-result"
            )
        unless (output == "restricted") (fail "mutation worker output did not survive settlement")
      Just _ -> do
        baseline <- readFile (directory </> "baseline-result")
        unless (baseline == "selected-and-passed") (fail "real test result not retained")
    let project = directory </> "interrupted-output-project"
    createDirectory project
    setFileMode project 0o700
    limits <- maybe (fail "invalid output limits") pure (mutationOutputLimits 128 1048576 8 5000000)
    initial <- withNewMutationWorkspace project fixtureOperation snapshot $ \root _ ->
      observeMutationOutputInventory limits root
    inventory <- case initial of
      MutationWorkspaceCallbackReturned (MutationOutputObserved value) -> pure value
      _ -> fail "interrupted output inventory refused"
    checkpointed <-
      checkpointMutationWorkspaceOutput
        limits
        inventory
        key
        fixtureCheckpoint
        project
        fixtureOperation
        snapshot
    unless
      (checkpointed == MutationWorkspaceCallbackReturned MutationWorkspaceIntentRecorded)
      (fail "interrupted output checkpoint refused")
    let outputRoot = project </> ".build" </> "mutation-workspaces" </> fixtureOperation
    changedDuringCallback <-
      withRecoveredMutationOutputCheckpoint limits key fixtureCheckpoint project fixtureOperation snapshot $ \_ stable -> do
        writeFile (outputRoot </> "changed") "changed"
        setFileMode (outputRoot </> "changed") 0o600
        stable
    unless (changedDuringCallback == MutationWorkspaceChangedAfter False) $
      fail ("output change during callback was not retained: " <> show changedDuringCallback)
    changed <-
      beginMutationOutputRetirement
        limits
        key
        fixtureCheckpoint
        (pure True)
        project
        fixtureOperation
        snapshot
    unless (changed == MutationWorkspaceOutputChanged) (fail "changed output retirement accepted")
    current <-
      withRecoveredMutationOutputCheckpoint
        limits
        key
        fixtureCheckpoint
        project
        fixtureOperation
        snapshot
        (\_ stable -> stable)
    unless
      (current == MutationWorkspaceOutputChanged)
      (fail "changed output reopened against its old checkpoint")
    nextInventory <-
      bracket
        ( Posix.openFd
            outputRoot
            Posix.ReadOnly
            Posix.defaultFileFlags {Posix.nofollow = True, Posix.directory = True}
        )
        Posix.closeFd
        $ observeMutationOutputInventory limits
    latest <- case nextInventory of
      MutationOutputObserved value -> pure value
      _ -> fail "changed output inventory refused"
    let nextCheckpoint = replicate 32 'b'
    nextRecorded <-
      checkpointMutationWorkspaceOutput limits latest key nextCheckpoint project fixtureOperation snapshot
    unless
      (nextRecorded == MutationWorkspaceCallbackReturned MutationWorkspaceIntentRecorded)
      (fail "changed output checkpoint refused")
    checks <- newIORef (0 :: Int)
    let interrupted = atomicModifyIORef' checks $ \count -> (count + 1, count < 3)
    interruptedResult <-
      beginMutationOutputRetirement
        limits
        key
        nextCheckpoint
        interrupted
        project
        fixtureOperation
        snapshot
    unless
      (interruptedResult == MutationWorkspaceRetirementWriteRefused MutationWorkspaceIntentWriteIncomplete)
      $ fail ("post-transition settlement failure was not retained: " <> show interruptedResult)
    recovered <-
      beginMutationOutputRetirement
        limits
        key
        nextCheckpoint
        (pure True)
        project
        fixtureOperation
        snapshot
    unless (recovered == MutationWorkspaceRetirementAlreadyRecorded) $
      fail ("interrupted output retirement was not recoverable: " <> show recovered)
    let changedProject = directory </> "changed-source-project"
        changedSource = changedProject </> ".build" </> "mutation-workspaces" </> fixtureOperation </> "src" </> "X.hs"
    createDirectory changedProject
    setFileMode changedProject 0o700
    sourcePrepared <-
      withNewMutationWorkspace changedProject fixtureOperation snapshot (\_ stable -> stable)
    unless
      (sourcePrepared == MutationWorkspaceCallbackReturned True)
      (fail "source change fixture refused")
    expired <- withRecoveredMutationWorkspaceBefore 1 changedProject fixtureOperation snapshot $ \_ _ ->
      fail "expired source observation invoked callback"
    unless (expired == MutationWorkspaceObservationRefused MutationSnapshotObservationTimedOut) $
      fail
        ("expired source observation was not refused: " <> show (expired :: MutationWorkspaceOutcome ()))
    sourceChanged <- withRecoveredMutationWorkspace changedProject fixtureOperation snapshot $ \_ stable -> do
      writeFile changedSource "changed"
      stable
    unless (sourceChanged == MutationWorkspaceChangedAfter False) $
      fail ("source change during callback was not retained: " <> show sourceChanged)
    sourceReopened <-
      withRecoveredMutationWorkspace changedProject fixtureOperation snapshot (\_ stable -> stable)
    unless (sourceReopened == MutationWorkspaceObservationRefused MutationSnapshotDiffers) $
      fail ("changed source reopened: " <> show sourceReopened)
  when (kind /= Identity.MutationController && publisherKind == kind) $ do
    present <-
      doesFileExist
        ( directory
            </> "output-project"
            </> ".build"
            </> "mutation-workspaces"
            </> fixtureOperation
            </> "worker-result"
        )
    when present (fail "non-mutation controller ran the restricted worker")

-- This fixture validates only the real unmodified test transport under the
-- managed sealed operation. It does not bind the executable to this synthetic
-- source snapshot or establish a baseline for mutation classification.
exerciseRealTest
  :: FilePath
  -> String
  -> FilePath
  -> Integer
  -> Maybe Sealed.SealedToolBudget
  -> Word64
  -> Kernel.OperationParent
  -> IO ()
exerciseRealTest directory digest toolPath toolSize budget work parent = do
  funded <- maybe (fail "real test budget unavailable") pure budget
  snapshot <- fixtureSnapshot
  commandLimits <- right (Subprocess.mkOperationStreamLimits 4096 4096 10000)
  transportLimits <- right (Subprocess.mkOperationStreamLimits 4096 4096 10000)
  processes <- right (Subprocess.operationSubprocesses parent commandLimits transportLimits)
  limits <- maybe (fail "invalid output limits") pure (mutationOutputLimits 128 1048576 8 5000000)
  binaryDigest <-
    maybe (fail "invalid test binary digest") pure (mkPublicEvidenceDigest (Text.pack (drop 7 digest)))
  let source = directory </> ".build" </> "mutation-workspaces" </> fixtureOperation
      outputProject = directory </> "output-project"
      output = outputProject </> ".build" </> "mutation-workspaces" </> fixtureOperation
      patternText = "rejects overlapping roots for the mutation catalog"
      template =
        Subprocess.Subprocess
          toolPath
          []
          (Just [("PATH", "/usr/bin"), ("HOME", output), ("TMPDIR", output)])
          (Just source)
      flags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.directory = True}
      select = template {Subprocess.subprocessArguments = ["--list-tests", "--pattern", patternText]}
      execute =
        template
          { Subprocess.subprocessArguments =
              ["--pattern", patternText, "--mutation-assertion", "context.rejects_root_alias"]
          }
  result <- withRecoveredMutableMutationOutputWorkspace outputProject fixtureOperation snapshot $ \outputFd outputStable ->
    bracket (Posix.openFd "/usr" Posix.ReadOnly flags) Posix.closeFd $ \usrFd ->
      bracket
        (Posix.openFd toolPath Posix.ReadOnly Posix.defaultFileFlags {Posix.nofollow = True})
        Posix.closeFd
        $ \tool -> do
          let run command =
                runSealedMutationOperationWorkerBefore
                  work
                  funded
                  tool
                  digest
                  toolSize
                  directory
                  fixtureOperation
                  snapshot
                  processes
                  output
                  outputFd
                  outputStable
                  [usrFd]
                  (\_ _ -> pure True)
                  command
          selection <- run select
          case selection of
            MutationSealedOperationObserved
              (MutationWorkspaceCallbackReturned (MutationOperationFinished (Right observed))) -> do
                retainProcessOutput directory "selection" observed
                case validateMutationSelection
                  (reviewedTestPath M01OverlappingRoots)
                  binaryDigest
                  (Subprocess.operationProcessExitCode observed)
                  (Subprocess.operationProcessStdout observed)
                  (Subprocess.operationProcessStderr observed) of
                  Right _ -> pure ()
                  Left failure -> fail ("real test selection refused: " <> show failure)
            _ -> fail "real test selection operation incomplete"
          tested <- run execute
          case tested of
            MutationSealedOperationObserved
              (MutationWorkspaceCallbackReturned (MutationOperationFinished (Right observed))) ->
                retainProcessOutput directory "test" observed
            _ -> pure ()
          case decodeSealedMutationOperation "context.rejects_root_alias" tested of
            Right (TestPassed 1) -> pure ()
            _ -> fail "real test reporter did not pass"
          observed <- observeMutationOutputInventory limits outputFd
          case observed of
            MutationOutputObserved inventory -> pure inventory
            other -> fail ("real test output inventory refused: " <> show other)
  inventory <- case result of
    MutationWorkspaceCallbackReturned value -> pure value
    _ -> fail "real test output workspace changed"
  checkpointed <-
    checkpointMutationWorkspaceOutput
      limits
      inventory
      (Kernel.operationParentKey parent)
      fixtureCheckpoint
      outputProject
      fixtureOperation
      snapshot
  unless
    (checkpointed == MutationWorkspaceCallbackReturned MutationWorkspaceIntentRecorded)
    (fail "real test output checkpoint refused")
  writeFile (directory </> "baseline-result") "selected-and-passed"

retainProcessOutput :: FilePath -> String -> Subprocess.OperationProcessOutput -> IO ()
retainProcessOutput directory label observed = do
  Chars.writeFile (directory </> (label <> ".stdout")) (Subprocess.operationProcessStdout observed)
  Chars.writeFile (directory </> (label <> ".stderr")) (Subprocess.operationProcessStderr observed)
  writeFile (directory </> (label <> ".exit")) (show (Subprocess.operationProcessExitCode observed))

exerciseMutation
  :: Identity.HostControllerKind
  -> FilePath
  -> String
  -> Maybe Sealed.SealedToolBudget
  -> Word64
  -> Kernel.OperationParent
  -> IO ()
exerciseMutation kind directory digest budget work parent = do
  snapshot <- fixtureSnapshot
  commandLimits <- right (Subprocess.mkOperationStreamLimits 4096 4096 10000)
  transportLimits <- right (Subprocess.mkOperationStreamLimits 4096 4096 10000)
  processes <- right (Subprocess.operationSubprocesses parent commandLimits transportLimits)
  let source = directory </> ".build" </> "mutation-workspaces" </> fixtureOperation
      outputProject = directory </> "output-project"
      output = outputProject </> ".build" </> "mutation-workspaces" </> fixtureOperation
      flags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.directory = True}
      script =
        unlines
          [ "import os,socket"
          , "assert open('src/X.hs').read() == 'fixture'"
          , "try: open('src/X.hs','w').write('changed'); raise AssertionError('source write allowed')"
          , "except PermissionError: pass"
          , "try: socket.socket(); raise AssertionError('socket allowed')"
          , "except PermissionError: pass"
          , "open(os.path.join(os.environ['TMPDIR'],'worker-result'),'w').write('restricted')"
          ]
      command =
        Subprocess.Subprocess
          "/usr/bin/python3"
          ["-c", script]
          (Just [("PATH", "/usr/bin"), ("HOME", output), ("TMPDIR", output)])
          (Just source)
  limits <- maybe (fail "invalid output limits") pure (mutationOutputLimits 128 1048576 8 5000000)
  observed <- withRecoveredMutableMutationOutputWorkspace outputProject fixtureOperation snapshot $ \outputFd outputStable -> do
    outputReady <- outputStable
    unless outputReady (fail "mutation output changed before launch")
    result <- bracket (Posix.openFd "/usr" Posix.ReadOnly flags) Posix.closeFd $ \usrFd -> do
      foreignResult <-
        runRecoveredMutationOperationWorkerBefore
          work
          directory
          (replicate 32 'b')
          snapshot
          processes
          output
          outputFd
          outputStable
          [usrFd]
          (\_ _ -> pure True)
          command
      case foreignResult of
        MutationWorkspaceCallbackReturned MutationOperationBindingRefused -> pure ()
        _ -> fail "foreign source workspace bound to operation"
      denied <-
        runRecoveredMutationOperationWorkerBefore
          work
          directory
          fixtureOperation
          snapshot
          processes
          output
          outputFd
          outputStable
          [usrFd]
          (\_ _ -> pure False)
          command
      case denied of
        MutationWorkspaceCallbackReturned MutationOperationAdmissionRefused -> pure ()
        _ -> fail "unadmitted mutation operation ran"
      premature <- doesFileExist (output </> "worker-result")
      when premature (fail "refused operation produced worker output")
      case budget of
        Nothing -> do
          result <-
            runRecoveredMutationOperationWorkerBefore
              work
              directory
              fixtureOperation
              snapshot
              processes
              output
              outputFd
              outputStable
              [usrFd]
              (\_ _ -> pure True)
              command
          pure (MutationSealedOperationObserved result)
        Just funded -> bracket (Posix.openFd "/usr/bin/python3" Posix.ReadOnly Posix.defaultFileFlags) Posix.closeFd $ \tool -> do
          mismatched <- right (Sealed.planSealedToolBudget (Sealed.sealedToolRuntimePlan funded) 1 1)
          refusedBudget <-
            runSealedMutationOperationWorkerBefore
              work
              mismatched
              tool
              digest
              1
              directory
              fixtureOperation
              snapshot
              processes
              output
              outputFd
              outputStable
              [usrFd]
              (\_ _ -> pure True)
              command
          case refusedBudget of
            MutationSealedBudgetRefused -> pure ()
            _ -> fail "unfunded tool snapshot was accepted"
          expired <-
            runSealedMutationOperationWorkerBefore
              1
              funded
              tool
              digest
              (16 * 1048576)
              directory
              fixtureOperation
              snapshot
              processes
              output
              outputFd
              outputStable
              [usrFd]
              (\_ _ -> pure True)
              command
          case expired of
            MutationSealedToolRefused Sealed.SealedToolTimedOut -> pure ()
            _ -> fail "expired tool snapshot was accepted"
          wrong <-
            runSealedMutationOperationWorkerBefore
              work
              funded
              tool
              ("sha256:" <> replicate 64 '0')
              (16 * 1048576)
              directory
              fixtureOperation
              snapshot
              processes
              output
              outputFd
              outputStable
              [usrFd]
              (\_ _ -> pure True)
              command
          case wrong of
            MutationSealedToolRefused Sealed.SealedToolDigestMismatch -> pure ()
            _ -> fail "wrong tool digest was accepted"
          case decodeSealedMutationOperation "context.rejects_root_alias" wrong of
            Left (MutationSealedToolRefused Sealed.SealedToolDigestMismatch) -> pure ()
            _ -> fail "decoder discarded the tool refusal"
          let forged =
                command
                  { Subprocess.subprocessArguments =
                      ["-c", "import sys; sys.stderr.write('prodbox-mutation-test-v1:assertion-failed\\n'); sys.exit(1)"]
                  }
          forgedResult <-
            runSealedMutationOperationWorkerBefore
              work
              funded
              tool
              digest
              (16 * 1048576)
              directory
              fixtureOperation
              snapshot
              processes
              output
              outputFd
              outputStable
              [usrFd]
              (\_ _ -> pure True)
              forged
          case decodeSealedMutationOperation "context.rejects_root_alias" forgedResult of
            Right (TestAssertionFailures 1 ["context.rejects_root_alias"]) -> pure ()
            _ -> fail "synthetic reporter transport differed"
          case forgedResult of
            MutationSealedOperationObserved
              (MutationWorkspaceCallbackReturned (MutationOperationFinished (Right observedOutput))) -> do
                let changedSource =
                      MutationSealedOperationObserved
                        (MutationWorkspaceChangedAfter (MutationOperationFinished (Right observedOutput)))
                    changedOutput =
                      MutationSealedOperationObserved
                        (MutationWorkspaceCallbackReturned (MutationOperationOutputChangedAfter (Right observedOutput)))
                case decodeSealedMutationOperation "context.rejects_root_alias" changedSource of
                  Left (MutationSealedOperationObserved (MutationWorkspaceChangedAfter _)) -> pure ()
                  _ -> fail "decoder accepted changed source"
                case decodeSealedMutationOperation "context.rejects_root_alias" changedOutput of
                  Left
                    ( MutationSealedOperationObserved
                        (MutationWorkspaceCallbackReturned (MutationOperationOutputChangedAfter _))
                      ) -> pure ()
                  _ -> fail "decoder accepted changed output"
            _ -> fail "synthetic reporter did not yield a completed process"
          runSealedMutationOperationWorkerBefore
            work
            funded
            tool
            digest
            (16 * 1048576)
            directory
            fixtureOperation
            snapshot
            processes
            output
            outputFd
            outputStable
            [usrFd]
            (\_ _ -> pure True)
            command
    inventory <- observeMutationOutputInventory limits outputFd
    pure (result, inventory)
  case observed of
    MutationWorkspaceCallbackReturned
      ( MutationSealedOperationObserved
          (MutationWorkspaceCallbackReturned (MutationOperationFinished (Right result)))
        , MutationOutputObserved inventory
        )
        | kind == Identity.MutationController
            && Subprocess.operationProcessExitCode result == ExitSuccess -> do
            checkpointed <-
              checkpointMutationWorkspaceOutput
                limits
                inventory
                (Kernel.operationParentKey parent)
                fixtureCheckpoint
                outputProject
                fixtureOperation
                snapshot
            unless (checkpointed == MutationWorkspaceCallbackReturned MutationWorkspaceIntentRecorded) $
              fail ("mutation output checkpoint refused: " <> show checkpointed)
    MutationWorkspaceCallbackReturned
      ( MutationSealedOperationObserved
          ( MutationWorkspaceCallbackReturned
              ( MutationOperationFinished
                  (Left (Subprocess.OperationProcessRefused Subprocess.OwnedSubprocessRuntimeUnsupported))
                )
            )
        , _
        )
        | kind /= Identity.MutationController -> pure ()
    MutationWorkspaceCallbackReturned (MutationSealedToolRefused failure, _) ->
      fail ("sealed tool refused: " <> show failure)
    MutationWorkspaceCallbackReturned
      ( MutationSealedOperationObserved
          (MutationWorkspaceCallbackReturned (MutationOperationFinished (Left failure)))
        , _
        ) ->
        fail ("sealed operation refused: " <> show failure)
    MutationWorkspaceCallbackReturned
      ( MutationSealedOperationObserved
          (MutationWorkspaceCallbackReturned (MutationOperationFinished (Right result)))
        , _
        ) ->
        fail ("sealed operation exit: " <> show (Subprocess.operationProcessExitCode result))
    _ -> fail "restricted mutation child or output checkpoint did not complete successfully"

fixtureCheckpoint :: String
fixtureCheckpoint = replicate 32 'c'

fixtureOperation :: String
fixtureOperation = replicate 32 'a'

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

socket :: (Show uid) => uid -> FilePath
socket uid = "/run/user/" <> show uid <> "/bus"

waitUntil :: (Integral clock) => clock -> IO Bool -> IO ()
waitUntil ending test = do
  done <- test
  unless done $ do
    now <- getMonotonicTimeNSec
    if toInteger now >= toInteger ending
      then fail "original fixture observation deadline reached"
      else threadDelay 1000 >> waitUntil ending test
