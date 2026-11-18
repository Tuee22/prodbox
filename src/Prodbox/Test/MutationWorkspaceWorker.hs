-- | Connect one recorded mutation workspace to its managed worker placement.
-- This does not authenticate dependencies, exclude noncooperating writers,
-- settle earlier workers, authorize a mutant, or clean the workspace.
module Prodbox.Test.MutationWorkspaceWorker
  ( MutationWorkspaceWorkerResult (..)
  , runRecoveredMutationWorkspaceWorker
  , MutationOperationWorkerResult (..)
  , runRecoveredMutationOperationWorkerBefore
  , MutationSealedOperationResult (..)
  , runSealedMutationOperationWorkerBefore
  , decodeSealedMutationOperation
  ) where

import Control.Exception (IOException, try)
import Data.List (isPrefixOf)
import Data.Text (Text)
import Data.Word (Word64)
import Prodbox.Capacity.RuntimeMemory qualified as RuntimeMemory
import Prodbox.Control.SealedTool qualified as SealedTool
import Prodbox.Subprocess
  ( HostSubprocessError
  , MutationHostSubprocessPlacement
  , OperationProcessOutput
  , OperationSubprocessError
  , OperationSubprocesses
  , OwnedSubprocessLimits
  , ProcessOutput
  , Subprocess (..)
  , captureMutationOperationCommandBefore
  , captureSealedMutationOperationCommandBefore
  , mutationHostSubprocessExecutionKey
  , mutationHostSubprocessFinishEnd
  , operationProcessExitCode
  , operationProcessStderr
  , operationProcessStdout
  , operationSubprocessExecutionKey
  , operationSubprocessKind
  , operationSubprocessRuntimeMemory
  , operationSubprocessWindow
  , verifyOperationSubprocessesBeforeEffect
  , withPreparedMutationHostSubprocess
  )
import Prodbox.Subprocess.SystemdIdentity
  ( HostControllerKind (MutationController)
  , HostExecutionKey
  , hostExecutionFinishEnd
  , hostExecutionWorkEnd
  )
import Prodbox.Test.MutationOutcome (MutationTest, decodeSingleMutationTest)
import Prodbox.Test.MutationSnapshot (MutationSnapshot)
import Prodbox.Test.MutationSnapshotWrite (mutationSnapshotRootIdentity)
import Prodbox.Test.MutationWorkspace
  ( MutationWorkspaceOutcome (..)
  , withRecoveredMutationWorkspaceBefore
  )
import Prodbox.Test.MutationWorkspaceIntent (mutationWorkspaceWorkerKey)
import System.FilePath.Posix (isAbsolute, normalise, splitDirectories, (</>))
import System.Posix.Files
  ( FileStatus
  , deviceID
  , fileID
  , getFdStatus
  , getSymbolicLinkStatus
  , isDirectory
  )
import System.Posix.Types (Fd (..))

data MutationWorkspaceWorkerResult
  = MutationWorkerBindingRefused
  | MutationWorkerCommandRefused
  | MutationWorkerOutputRefused
  | MutationWorkerAdmissionRefused
  | MutationWorkerWorkspaceChanged
  | MutationWorkerFinished !(Either HostSubprocessError ProcessOutput)
  | MutationWorkerOutputChangedAfter !(Either HostSubprocessError ProcessOutput)
  deriving (Eq, Show)

data MutationOperationWorkerResult
  = MutationOperationBindingRefused
  | MutationOperationCommandRefused
  | MutationOperationOutputRefused
  | MutationOperationAdmissionRefused
  | MutationOperationWorkspaceChanged
  | MutationOperationFinished !(Either OperationSubprocessError OperationProcessOutput)
  | MutationOperationOutputChangedAfter !(Either OperationSubprocessError OperationProcessOutput)

data MutationSealedOperationResult
  = MutationSealedBudgetRefused
  | MutationSealedParentRefused !OperationSubprocessError
  | MutationSealedToolRefused !SealedTool.SealedToolError
  | MutationSealedOperationObserved !(MutationWorkspaceOutcome MutationOperationWorkerResult)

-- | Decode only an unchanged, completed operation. All refusals and
-- changed-after outcomes are returned intact. The caller must still verify the
-- test binary, selection, assertion binding, isolation and cleanup; a process
-- can forge this transport and a decoded value is not a mutation outcome.
decodeSealedMutationOperation
  :: Text -> MutationSealedOperationResult -> Either MutationSealedOperationResult MutationTest
decodeSealedMutationOperation assertion observed = case observed of
  MutationSealedOperationObserved
    (MutationWorkspaceCallbackReturned (MutationOperationFinished (Right output))) ->
      Right $
        decodeSingleMutationTest
          assertion
          (operationProcessExitCode output)
          (operationProcessStdout output)
          (operationProcessStderr output)
  _ -> Left observed

-- | Reopen an active, unchanged snapshot and bind its birth-derived key to
-- the already observed controller. The callback must establish independent
-- admission, output and tool custody, prior settlement and cleanup. The
-- source is read-only to the child and the supplied output is writable. The
-- pathname and inode checks do not rule out mount or other filesystem aliases.
-- The workspace lease excludes only cooperating users; a positive callback or
-- stable pathname does not exclude other writers. The caller must use a bound
-- thread and independently reconcile any interrupted or changed result.
runRecoveredMutationWorkspaceWorker
  :: FilePath
  -> String
  -> MutationSnapshot
  -> MutationHostSubprocessPlacement
  -> RuntimeMemory.RuntimeMemoryPlan
  -> FilePath
  -> Fd
  -> IO Bool
  -> [Fd]
  -> OwnedSubprocessLimits
  -> (Fd -> IO Bool -> IO Bool)
  -> Subprocess
  -> IO (MutationWorkspaceOutcome MutationWorkspaceWorkerResult)
runRecoveredMutationWorkspaceWorker project operation snapshot placement runtime outputPath output outputStable roots limits admit command =
  withRecoveredMutationWorkspaceBefore
    (mutationHostSubprocessFinishEnd placement)
    project
    operation
    snapshot
    $ \workspace stable -> do
      sourceStatus <- getFdStatus workspace
      outputStatus <- getFdStatus output
      namedOutput <- getSymbolicLinkStatus outputPath
      case workspaceBinding
        (mutationHostSubprocessExecutionKey placement)
        project
        operation
        snapshot
        outputPath
        sourceStatus
        outputStatus
        namedOutput
        command of
        Just BindingKey -> pure MutationWorkerBindingRefused
        Just BindingOutput -> pure MutationWorkerOutputRefused
        Just BindingCommand -> pure MutationWorkerCommandRefused
        Nothing -> do
          before <- (&&) <$> stable <*> outputStable
          permitted <- if before then admit workspace stable else pure False
          ready <- (&&) <$> stable <*> outputStable
          if not (before && ready)
            then pure MutationWorkerWorkspaceChanged
            else
              if not permitted
                then pure MutationWorkerAdmissionRefused
                else do
                  result <-
                    withPreparedMutationHostSubprocess placement runtime output (workspace : roots) limits ($ command)
                  after <- try outputStable :: IO (Either IOException Bool)
                  pure $ case after of
                    Right True -> MutationWorkerFinished result
                    _ -> MutationWorkerOutputChangedAfter result

-- | Run one restricted command on an observed mutation operation parent while
-- the exact source workspace remains held. The caller independently owns the
-- output lease, tool custody, admission, earlier worker settlement, alias
-- exclusion and cleanup; this function is not permission to execute mutants.
runRecoveredMutationOperationWorkerBefore
  :: Word64
  -> FilePath
  -> String
  -> MutationSnapshot
  -> OperationSubprocesses
  -> FilePath
  -> Fd
  -> IO Bool
  -> [Fd]
  -> (Fd -> IO Bool -> IO Bool)
  -> Subprocess
  -> IO (MutationWorkspaceOutcome MutationOperationWorkerResult)
runRecoveredMutationOperationWorkerBefore requested project operation snapshot processes outputPath output outputStable roots admit command =
  runRecoveredMutationOperationWorkerUsing
    Nothing
    requested
    project
    operation
    snapshot
    processes
    outputPath
    output
    outputStable
    roots
    admit
    command

runRecoveredMutationOperationWorkerUsing
  :: Maybe Fd
  -> Word64
  -> FilePath
  -> String
  -> MutationSnapshot
  -> OperationSubprocesses
  -> FilePath
  -> Fd
  -> IO Bool
  -> [Fd]
  -> (Fd -> IO Bool -> IO Bool)
  -> Subprocess
  -> IO (MutationWorkspaceOutcome MutationOperationWorkerResult)
runRecoveredMutationOperationWorkerUsing sealedTool requested project operation snapshot processes outputPath output outputStable roots admit command =
  withRecoveredMutationWorkspaceBefore
    (hostExecutionFinishEnd (operationSubprocessWindow processes))
    project
    operation
    snapshot
    $ \workspace stable -> do
      sourceStatus <- getFdStatus workspace
      outputStatus <- getFdStatus output
      namedOutput <- getSymbolicLinkStatus outputPath
      case workspaceBinding
        (operationSubprocessExecutionKey processes)
        project
        operation
        snapshot
        outputPath
        sourceStatus
        outputStatus
        namedOutput
        command of
        Just BindingKey -> pure MutationOperationBindingRefused
        Just BindingOutput -> pure MutationOperationOutputRefused
        Just BindingCommand -> pure MutationOperationCommandRefused
        Nothing -> do
          before <- (&&) <$> stable <*> outputStable
          permitted <- if before then admit workspace stable else pure False
          ready <- (&&) <$> stable <*> outputStable
          if not (before && ready)
            then pure MutationOperationWorkspaceChanged
            else
              if not permitted
                then pure MutationOperationAdmissionRefused
                else do
                  result <- case sealedTool of
                    Nothing -> captureMutationOperationCommandBefore requested processes output (workspace : roots) command
                    Just tool ->
                      captureSealedMutationOperationCommandBefore
                        requested
                        processes
                        output
                        (workspace : roots)
                        tool
                        command
                  after <- try outputStable :: IO (Either IOException Bool)
                  pure $ case after of
                    Right True -> MutationOperationFinished result
                    _ -> MutationOperationOutputChangedAfter result

-- | Snapshot the selected executable, verify its declared digest and run the
-- sealed descriptor in the mutation family. The exact funded runtime must
-- match the held parent. This does not authenticate the caller's declaration,
-- dependencies, input/output custody, prior workers, aliases or cleanup.
runSealedMutationOperationWorkerBefore
  :: Word64
  -> SealedTool.SealedToolBudget
  -> Fd
  -> String
  -> Integer
  -> FilePath
  -> String
  -> MutationSnapshot
  -> OperationSubprocesses
  -> FilePath
  -> Fd
  -> IO Bool
  -> [Fd]
  -> (Fd -> IO Bool -> IO Bool)
  -> Subprocess
  -> IO MutationSealedOperationResult
runSealedMutationOperationWorkerBefore requested budget source digest maximumBytes project operation snapshot processes outputPath output outputStable roots admit command
  | operationSubprocessKind processes /= MutationController
      || operationSubprocessRuntimeMemory processes /= SealedTool.sealedToolRuntimePlan budget =
      pure MutationSealedBudgetRefused
  | otherwise = do
      parent <- verifyOperationSubprocessesBeforeEffect processes
      case parent of
        Left failure -> pure (MutationSealedParentRefused failure)
        Right () -> do
          let ending = min requested (hostExecutionWorkEnd (operationSubprocessWindow processes))
          sealed <- SealedTool.withSealedToolBefore ending budget source digest maximumBytes $ \tool@(Fd descriptor) -> do
            let selected = command {subprocessPath = "/proc/self/fd/" ++ show descriptor}
            runRecoveredMutationOperationWorkerUsing
              (Just tool)
              requested
              project
              operation
              snapshot
              processes
              outputPath
              output
              outputStable
              roots
              admit
              selected
          pure $ case sealed of
            Left failure -> MutationSealedToolRefused failure
            Right result -> MutationSealedOperationObserved result

data WorkspaceBindingFailure = BindingKey | BindingOutput | BindingCommand

workspaceBinding
  :: HostExecutionKey
  -> FilePath
  -> String
  -> MutationSnapshot
  -> FilePath
  -> FileStatus
  -> FileStatus
  -> FileStatus
  -> Subprocess
  -> Maybe WorkspaceBindingFailure
workspaceBinding key project operation snapshot outputPath sourceStatus outputStatus namedOutput command
  | mutationWorkspaceWorkerKey operation snapshot (mutationSnapshotRootIdentity sourceStatus)
      /= Just key =
      Just BindingKey
  | not disjoint = Just BindingOutput
  | not commandMatches = Just BindingCommand
  | otherwise = Nothing
 where
  directory = project </> ".build" </> "mutation-workspaces" </> operation
  environment = maybe [] id (subprocessEnvironment command)
  disjoint =
    isAbsolute outputPath
      && normalise outputPath == outputPath
      && not (splitDirectories directory `isPrefixOf` splitDirectories outputPath)
      && not (splitDirectories outputPath `isPrefixOf` splitDirectories directory)
      && (deviceID sourceStatus, fileID sourceStatus) /= (deviceID outputStatus, fileID outputStatus)
      && isDirectory outputStatus
      && isDirectory namedOutput
      && (deviceID outputStatus, fileID outputStatus) == (deviceID namedOutput, fileID namedOutput)
  commandMatches =
    subprocessWorkingDirectory command == Just directory
      && lookup "HOME" environment == Just outputPath
      && lookup "TMPDIR" environment == Just outputPath
