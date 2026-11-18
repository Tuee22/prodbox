{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Bind snapshot preparation to an explicit project and held workspace root.
-- This is not process isolation, an execution permit or a cleanup operation.
module Prodbox.Test.MutationWorkspace
  ( MutationWorkspaceOutcome (..)
  , withNewMutationWorkspace
  , withRecoveredMutationWorkspace
  , withRecoveredMutationWorkspaceBefore
  , withRecoveredMutableMutationOutputWorkspace
  , withRecoveredMutationOutputWorkspace
  , checkpointMutationWorkspaceOutput
  , withRecoveredMutationOutputCheckpoint
  , withRetiringMutationWorkspace
  , withRetiringMutationOutputCheckpoint
  , beginMutationOutputRetirement
  , beginMutationWorkspaceRetirement
  ) where

import Control.Exception (IOException, bracket, finally, mask, throwIO, try)
import Control.Monad (void)
import Data.Bits ((.&.), (.|.))
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Word (Word64)
import Foreign.C.Error (eAGAIN, eWOULDBLOCK, getErrno, throwErrnoIfMinus1_)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import Prodbox.Config.DeploymentScope (validRootGeneration)
import Prodbox.Subprocess.SystemdIdentity (HostExecutionKey)
import Prodbox.Test.MutationOutputInventory
  ( MutationOutputInventory
  , MutationOutputLimits
  , MutationOutputObservation (..)
  , mutationOutputInventoryFingerprint
  , mutationWorkspaceSameMount
  , observeMutationOutputInventory
  )
import Prodbox.Test.MutationSnapshot (MutationSnapshot)
import Prodbox.Test.MutationSnapshotObserve
  ( MutationSnapshotObservation (..)
  , observeMutationSnapshot
  , observeMutationSnapshotBefore
  )
import Prodbox.Test.MutationSnapshotWrite
  ( MutationSnapshotRootIdentity
  , MutationSnapshotWriteResult (..)
  , mutationSnapshotRootIdentity
  , writeMutationSnapshot
  )
import Prodbox.Test.MutationWorkspaceIntent
  ( MutationOutputCheckpointObservation (..)
  , MutationWorkspaceBirthObservation (..)
  , MutationWorkspaceIntentObservation (..)
  , MutationWorkspaceIntentWrite (..)
  , observeMutationWorkspaceAdmission
  , observeMutationWorkspaceBirth
  , observeMutationWorkspaceIntent
  , observeMutationWorkspaceRetirement
  , readMutationOutputCheckpoint
  , readMutationWorkspaceBirth
  , recordMutationOutputCheckpoint
  , recordMutationWorkspaceAdmission
  , recordMutationWorkspaceBirth
  , recordMutationWorkspaceIntent
  , recordMutationWorkspaceRetirement
  )
import System.FilePath.Posix (isAbsolute, normalise, splitDirectories)
import System.IO.Error (isAlreadyExistsError)
import System.Posix.Files
  ( FileStatus
  , deviceID
  , fileID
  , fileMode
  , fileOwner
  , getFdStatus
  , isDirectory
  )
import System.Posix.IO qualified as Posix
import System.Posix.Types (CMode (..), Fd (..), UserID)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)

foreign import capi "sys/stat.h mkdirat"
  makeWorkspaceDirectoryAt :: CInt -> CString -> CMode -> IO CInt

foreign import capi "sys/file.h flock" lockWorkspace :: CInt -> CInt -> IO CInt
foreign import capi "sys/file.h value LOCK_EX" exclusiveLock :: CInt
foreign import capi "sys/file.h value LOCK_NB" nonBlockingLock :: CInt
foreign import capi "sys/file.h value LOCK_UN" releaseLock :: CInt

data MutationWorkspaceOutcome value
  = MutationWorkspaceInvalid
  | MutationWorkspaceUnobservable
  | MutationWorkspaceBusy
  | MutationWorkspaceChanged
  | MutationWorkspaceIntentWriteRefused !MutationWorkspaceIntentWrite
  | MutationWorkspaceIntentObservationRefused !MutationWorkspaceIntentObservation
  | MutationWorkspaceWriteRefused !MutationSnapshotWriteResult
  | MutationWorkspaceBirthWriteRefused !MutationWorkspaceIntentWrite
  | MutationWorkspaceBirthReadRefused !MutationWorkspaceBirthObservation
  | MutationWorkspaceBirthObservationRefused !MutationWorkspaceIntentObservation
  | MutationWorkspaceObservationRefused !MutationSnapshotObservation
  | MutationWorkspaceOutputChanged
  | MutationWorkspaceOutputObservationRefused !MutationOutputObservation
  | MutationWorkspaceOutputCheckpointRefused !MutationOutputCheckpointObservation
  | MutationWorkspaceAdmissionRefused !MutationWorkspaceIntentObservation
  | MutationWorkspaceAdmissionWriteRefused !MutationWorkspaceIntentWrite
  | MutationWorkspaceRetirementRefused !MutationWorkspaceIntentObservation
  | MutationWorkspaceRetirementWriteRefused !MutationWorkspaceIntentWrite
  | MutationWorkspaceRetirementRecorded
  | MutationWorkspaceRetirementAlreadyRecorded
  | MutationWorkspaceCallbackReturned !value
  | MutationWorkspaceChangedAfter !value
  deriving (Eq, Show)

-- | Create only a fresh operation root under .build/mutation-workspaces, then
-- observe its complete expected inventory before invoking the callback. The
-- callback receives the held root and a path-identity check; the caller must
-- still establish same-user isolation, authenticate build dependencies, bound
-- and settle processes, and independently clean up. This function does not
-- authorize mutant execution and leaves a created root on all outcomes.
withNewMutationWorkspace
  :: FilePath
  -> String
  -> MutationSnapshot
  -> (Fd -> IO Bool -> IO value)
  -> IO (MutationWorkspaceOutcome value)
withNewMutationWorkspace project operation snapshot action
  | not (validProject project && validRootGeneration operation) = pure MutationWorkspaceInvalid
  | otherwise = do
      owner <- getEffectiveUserID
      returned <- newIORef Nothing
      attempted <- try $ walkParent owner True project $ \parent identities -> withWorkspaceLease parent $ do
        let parentStable = do
              fresh <- try (walkParent owner False project $ \_ current -> pure current)
              held <- try (getFdStatus parent)
              pure $ case (fresh, held) of
                (Right current, Right status) -> current == identities && safePrivate owner status
                (_ :: Either IOException [(Integer, Integer)], _ :: Either IOException FileStatus) -> False
        before <- parentStable
        if not before
          then pure MutationWorkspaceChanged
          else do
            recorded <- recordMutationWorkspaceIntent parent operation snapshot parentStable
            case recorded of
              MutationWorkspaceIntentRecorded -> do
                observedIntent <- observeMutationWorkspaceIntent parent operation snapshot parentStable
                case observedIntent of
                  MutationWorkspaceIntentMatches -> do
                    let intentStable =
                          (== MutationWorkspaceIntentMatches)
                            <$> observeMutationWorkspaceIntent parent operation snapshot parentStable
                    readyForWrite <- intentStable
                    if not readyForWrite
                      then pure MutationWorkspaceChanged
                      else do
                        written <- writeMutationSnapshot parent operation snapshot
                        case written of
                          MutationSnapshotWritten createdRoot -> do
                            observed <- observeMutationSnapshot parent operation snapshot
                            case observed of
                              MutationSnapshotMatches -> bracket (openDirectory parent operation) Posix.closeFd $ \root -> do
                                initial <- getFdStatus root
                                let rootStable = do
                                      pathStable <- intentStable
                                      current <- try (getFdStatus root)
                                      named <- try (bracket (openDirectory parent operation) Posix.closeFd getFdStatus)
                                      pure $ case (current, named) of
                                        (Right held, Right namedStatus) ->
                                          pathStable
                                            && safePrivate owner held
                                            && sameIdentity initial held
                                            && sameIdentity held namedStatus
                                            && mutationSnapshotRootIdentity held == createdRoot
                                        (_ :: Either IOException FileStatus, _ :: Either IOException FileStatus) -> False
                                ready <- rootStable
                                if not ready
                                  then pure MutationWorkspaceChanged
                                  else do
                                    birth <- recordMutationWorkspaceBirth parent operation snapshot createdRoot rootStable
                                    case birth of
                                      MutationWorkspaceIntentRecorded -> do
                                        birthObserved <- observeMutationWorkspaceBirth parent operation snapshot createdRoot rootStable
                                        case birthObserved of
                                          MutationWorkspaceIntentMatches -> do
                                            let birthStable =
                                                  (== MutationWorkspaceIntentMatches)
                                                    <$> observeMutationWorkspaceBirth parent operation snapshot createdRoot rootStable
                                            admission <- recordMutationWorkspaceAdmission parent operation snapshot createdRoot birthStable
                                            case admission of
                                              MutationWorkspaceIntentRecorded -> withUnretired parent operation snapshot createdRoot birthStable $ \stable -> do
                                                result <- mask $ \restore -> do
                                                  value <- restore (action root stable)
                                                  writeIORef returned (Just value)
                                                  pure value
                                                after <- stable
                                                pure
                                                  (if after then MutationWorkspaceCallbackReturned result else MutationWorkspaceChangedAfter result)
                                              other -> pure (MutationWorkspaceAdmissionWriteRefused other)
                                          other -> pure (MutationWorkspaceBirthObservationRefused other)
                                      other -> pure (MutationWorkspaceBirthWriteRefused other)
                              other -> pure (MutationWorkspaceObservationRefused other)
                          other -> pure (MutationWorkspaceWriteRefused other)
                  other -> pure (MutationWorkspaceIntentObservationRefused other)
              other -> pure (MutationWorkspaceIntentWriteRefused other)
      case attempted of
        Right result -> pure result
        Left (_ :: IOException) -> do
          result <- readIORef returned
          pure (maybe MutationWorkspaceUnobservable MutationWorkspaceChangedAfter result)

-- | Reopen an unchanged recorded workspace without creating or replacing any
-- part of it. A match does not establish that an earlier worker has settled,
-- prevent inode reuse, or authorize mutation or cleanup.
withRecoveredMutationWorkspace
  :: FilePath
  -> String
  -> MutationSnapshot
  -> (Fd -> IO Bool -> IO value)
  -> IO (MutationWorkspaceOutcome value)
withRecoveredMutationWorkspace project operation snapshot action =
  withRecordedMutationWorkspace
    False
    ExactSnapshot
    project
    operation
    snapshot
    (\_ root stable -> action root stable)

-- | Reopen an unchanged source with each inventory observation bounded by
-- the original absolute monotonic deadline. This does not bound other caller
-- callbacks or establish worker settlement and cleanup.
withRecoveredMutationWorkspaceBefore
  :: Word64
  -> FilePath
  -> String
  -> MutationSnapshot
  -> (Fd -> IO Bool -> IO value)
  -> IO (MutationWorkspaceOutcome value)
withRecoveredMutationWorkspaceBefore ending project operation snapshot action =
  withRecordedMutationWorkspace
    False
    (ExactSnapshotBefore ending)
    project
    operation
    snapshot
    (\_ root stable -> action root stable)

-- | Open an initially unchanged workspace for mutable output. Stability
-- covers its identity and admission markers, not its changing contents. The
-- caller must bind and settle all writers, inventory the result, exclude
-- aliases, and establish cleanup before using that output.
withRecoveredMutableMutationOutputWorkspace
  :: FilePath
  -> String
  -> MutationSnapshot
  -> (Fd -> IO Bool -> IO value)
  -> IO (MutationWorkspaceOutcome value)
withRecoveredMutableMutationOutputWorkspace project operation snapshot action =
  withRecordedMutationWorkspace
    False
    MutableOutput
    project
    operation
    snapshot
    (\_ root stable -> action root stable)

-- | Reopen a recorded active output root only if its bounded metadata still
-- matches the caller's independently retained observation. This does not
-- authenticate file contents, prove writer settlement or authorize reuse.
withRecoveredMutationOutputWorkspace
  :: MutationOutputLimits
  -> MutationOutputInventory
  -> FilePath
  -> String
  -> MutationSnapshot
  -> (Fd -> IO Bool -> IO value)
  -> IO (MutationWorkspaceOutcome value)
withRecoveredMutationOutputWorkspace limits expected project operation snapshot action =
  withRecordedMutationWorkspace
    False
    (ExpectedOutput limits expected)
    project
    operation
    snapshot
    (\_ root stable -> action root stable)

-- | Exclusively persist a non-secret metadata fingerprint after the caller
-- has independently settled writers and validated output names. The record
-- does not authenticate contents or establish those caller obligations.
checkpointMutationWorkspaceOutput
  :: MutationOutputLimits
  -> MutationOutputInventory
  -> HostExecutionKey
  -> String
  -> FilePath
  -> String
  -> MutationSnapshot
  -> IO (MutationWorkspaceOutcome MutationWorkspaceIntentWrite)
checkpointMutationWorkspaceOutput limits expected worker checkpoint project operation snapshot
  | not (validRootGeneration checkpoint) = pure MutationWorkspaceInvalid
  | otherwise =
      withRecordedMutationWorkspace False (ExpectedOutput limits expected) project operation snapshot $ \parent root stable -> do
        rootIdentity <- mutationSnapshotRootIdentity <$> getFdStatus root
        let inventoryStable = do
              before <- stable
              current <-
                if before then observeMutationOutputInventory limits root else pure MutationOutputUnobservable
              after <- stable
              pure (before && after && current == MutationOutputObserved expected)
        recordMutationOutputCheckpoint
          parent
          operation
          checkpoint
          snapshot
          rootIdentity
          worker
          limits
          (mutationOutputInventoryFingerprint expected)
          inventoryStable

-- | Reopen only when a fresh observation matches the retained checkpoint for
-- this output birth and source worker key. Caller-owned provenance, content
-- checks and complete worker settlement remain necessary before any action.
withRecoveredMutationOutputCheckpoint
  :: MutationOutputLimits
  -> HostExecutionKey
  -> String
  -> FilePath
  -> String
  -> MutationSnapshot
  -> (Fd -> IO Bool -> IO value)
  -> IO (MutationWorkspaceOutcome value)
withRecoveredMutationOutputCheckpoint limits worker checkpoint project operation snapshot action
  | not (validRootGeneration checkpoint) = pure MutationWorkspaceInvalid
  | otherwise =
      withRecordedMutationWorkspace
        False
        (CheckpointOutput limits worker checkpoint)
        project
        operation
        snapshot
        (\_ root stable -> action root stable)

-- | Reopen the retired output after checking its retained checkpoint. The
-- caller still owns worker settlement and exclusion of external aliases.
withRetiringMutationOutputCheckpoint
  :: MutationOutputLimits
  -> HostExecutionKey
  -> String
  -> FilePath
  -> String
  -> MutationSnapshot
  -> (Fd -> IO Bool -> IO value)
  -> IO (MutationWorkspaceOutcome value)
withRetiringMutationOutputCheckpoint limits worker checkpoint project operation snapshot action
  | not (validRootGeneration checkpoint) = pure MutationWorkspaceInvalid
  | otherwise =
      withRecordedMutationWorkspace
        True
        (CheckpointOutput limits worker checkpoint)
        project
        operation
        snapshot
        (\_ root stable -> action root stable)

-- | Retire only the matching checkpointed output. The caller holds a settlement
-- fence and excludes other writers. This records a transition; it removes nothing.
beginMutationOutputRetirement
  :: MutationOutputLimits
  -> HostExecutionKey
  -> String
  -> IO Bool
  -> FilePath
  -> String
  -> MutationSnapshot
  -> IO (MutationWorkspaceOutcome ())
beginMutationOutputRetirement limits worker checkpoint settlement project operation snapshot
  | not (validRootGeneration checkpoint) = pure MutationWorkspaceInvalid
  | otherwise =
      beginRecordedMutationRetirement
        (CheckpointOutput limits worker checkpoint)
        settlement
        project
        operation
        snapshot

-- | Reopen the exact unchanged retired workspace for recovery observation.
-- This does not establish worker settlement or authorize removal.
withRetiringMutationWorkspace
  :: FilePath
  -> String
  -> MutationSnapshot
  -> (Fd -> IO Bool -> IO value)
  -> IO (MutationWorkspaceOutcome value)
withRetiringMutationWorkspace project operation snapshot action =
  withRecordedMutationWorkspace
    True
    ExactSnapshot
    project
    operation
    snapshot
    (\_ root stable -> action root stable)

data RecordedInventory
  = ExactSnapshot
  | ExactSnapshotBefore !Word64
  | MutableOutput
  | ExpectedOutput !MutationOutputLimits !MutationOutputInventory
  | CheckpointOutput !MutationOutputLimits !HostExecutionKey !String

observeRecordedInventory
  :: RecordedInventory
  -> Fd
  -> Fd
  -> String
  -> MutationSnapshot
  -> MutationSnapshotRootIdentity
  -> IO Bool
  -> IO (Either (MutationWorkspaceOutcome value) ())
observeRecordedInventory inventory parent root operation snapshot rootIdentity rootStable =
  case inventory of
    ExactSnapshot -> do
      result <- observeMutationSnapshot parent operation snapshot
      pure $
        if result == MutationSnapshotMatches
          then Right ()
          else Left (MutationWorkspaceObservationRefused result)
    ExactSnapshotBefore ending -> do
      result <- observeMutationSnapshotBefore ending parent operation snapshot
      pure $
        if result == MutationSnapshotMatches
          then Right ()
          else Left (MutationWorkspaceObservationRefused result)
    MutableOutput -> observeRecordedInventory ExactSnapshot parent root operation snapshot rootIdentity rootStable
    _ -> do
      before <- mutationWorkspaceSameMount parent root
      if not before
        then pure (Left (MutationWorkspaceOutputObservationRefused MutationOutputUnsafe))
        else do
          result <- observeOutput
          after <- mutationWorkspaceSameMount parent root
          pure
            (if after then result else Left (MutationWorkspaceOutputObservationRefused MutationOutputUnsafe))
 where
  observeOutput = case inventory of
    ExactSnapshot -> pure (Left MutationWorkspaceInvalid)
    ExactSnapshotBefore _ -> pure (Left MutationWorkspaceInvalid)
    MutableOutput -> pure (Left MutationWorkspaceInvalid)
    ExpectedOutput limits expected -> do
      result <- observeMutationOutputInventory limits root
      pure $ case result of
        MutationOutputObserved actual | actual == expected -> Right ()
        MutationOutputObserved _ -> Left MutationWorkspaceOutputChanged
        other -> Left (MutationWorkspaceOutputObservationRefused other)
    CheckpointOutput limits worker checkpoint -> do
      result <- observeMutationOutputInventory limits root
      case result of
        MutationOutputObserved actual -> do
          checked <-
            readMutationOutputCheckpoint
              parent
              operation
              checkpoint
              snapshot
              rootIdentity
              worker
              limits
              rootStable
          case checked of
            MutationOutputCheckpointFound fingerprint
              | fingerprint /= mutationOutputInventoryFingerprint actual ->
                  pure (Left MutationWorkspaceOutputChanged)
              | otherwise -> do
                  again <- observeMutationOutputInventory limits root
                  pure $ case again of
                    MutationOutputObserved current | current == actual -> Right ()
                    MutationOutputObserved _ -> Left MutationWorkspaceOutputChanged
                    other -> Left (MutationWorkspaceOutputObservationRefused other)
            other -> pure (Left (MutationWorkspaceOutputCheckpointRefused other))
        other -> pure (Left (MutationWorkspaceOutputObservationRefused other))

withRecordedMutationWorkspace
  :: Bool
  -> RecordedInventory
  -> FilePath
  -> String
  -> MutationSnapshot
  -> (Fd -> Fd -> IO Bool -> IO value)
  -> IO (MutationWorkspaceOutcome value)
withRecordedMutationWorkspace retiring inventory project operation snapshot action
  | not (validProject project && validRootGeneration operation) = pure MutationWorkspaceInvalid
  | otherwise = do
      owner <- getEffectiveUserID
      returned <- newIORef Nothing
      attempted <- try $ walkParent owner False project $ \parent identities -> withWorkspaceLease parent $ do
        let parentStable = do
              fresh <- try (walkParent owner False project $ \_ current -> pure current)
              held <- try (getFdStatus parent)
              pure $ case (fresh, held) of
                (Right current, Right status) -> current == identities && safePrivate owner status
                (_ :: Either IOException [(Integer, Integer)], _ :: Either IOException FileStatus) -> False
            intentStable =
              (== MutationWorkspaceIntentMatches)
                <$> observeMutationWorkspaceIntent parent operation snapshot parentStable
        intent <- observeMutationWorkspaceIntent parent operation snapshot parentStable
        case intent of
          MutationWorkspaceIntentMatches -> do
            recordedBirth <- readMutationWorkspaceBirth parent operation snapshot intentStable
            case recordedBirth of
              MutationWorkspaceBirthFound rootIdentity -> bracket (openDirectory parent operation) Posix.closeFd $ \root -> do
                initial <- getFdStatus root
                let rootStable = do
                      pathStable <- intentStable
                      current <- try (getFdStatus root)
                      named <- try $ bracket (openDirectory parent operation) Posix.closeFd $ \namedRoot -> do
                        status <- getFdStatus namedRoot
                        sameMount <- mutationWorkspaceSameMount parent namedRoot
                        pure (status, sameMount)
                      pure $ case (current, named) of
                        (Right held, Right (namedStatus, sameMount)) ->
                          pathStable
                            && sameMount
                            && safePrivate owner held
                            && sameIdentity initial held
                            && sameIdentity held namedStatus
                            && mutationSnapshotRootIdentity held == rootIdentity
                        (_ :: Either IOException FileStatus, _ :: Either IOException (FileStatus, Bool)) -> False
                birth <-
                  if mutationSnapshotRootIdentity initial /= rootIdentity
                    then pure MutationWorkspaceIntentConflict
                    else observeMutationWorkspaceBirth parent operation snapshot rootIdentity rootStable
                case birth of
                  MutationWorkspaceIntentMatches -> do
                    observed <-
                      observeRecordedInventory inventory parent root operation snapshot rootIdentity rootStable
                    case observed of
                      Right () -> do
                        let birthStable =
                              (== MutationWorkspaceIntentMatches)
                                <$> observeMutationWorkspaceBirth parent operation snapshot rootIdentity rootStable
                        let stateGate = if retiring then withRetired else withUnretired
                        stateGate parent operation snapshot rootIdentity birthStable $ \stable -> do
                          let inventoryStable = case inventory of
                                MutableOutput -> stable
                                _ -> do
                                  before <- stable
                                  if not before
                                    then pure False
                                    else do
                                      current <- observeRecordedInventory inventory parent root operation snapshot rootIdentity rootStable
                                      after <- stable
                                      pure (either (const False) (const after) current)
                          ready <- inventoryStable
                          if not ready
                            then pure MutationWorkspaceChanged
                            else do
                              result <- mask $ \restore -> do
                                value <- restore (action parent root inventoryStable)
                                writeIORef returned (Just value)
                                pure value
                              after <- inventoryStable
                              pure
                                (if after then MutationWorkspaceCallbackReturned result else MutationWorkspaceChangedAfter result)
                      Left refusal -> pure refusal
                  other -> pure (MutationWorkspaceBirthObservationRefused other)
              other -> pure (MutationWorkspaceBirthReadRefused other)
          other -> pure (MutationWorkspaceIntentObservationRefused other)
      case attempted of
        Right result -> pure result
        Left (_ :: IOException) -> do
          result <- readIORef returned
          pure (maybe MutationWorkspaceUnobservable MutationWorkspaceChangedAfter result)

-- | Persist a retirement request for an exact, unchanged recorded workspace.
-- This does not remove files or prove that a worker has settled. The retained
-- request prevents cooperating new/recovery paths from starting more work.
beginMutationWorkspaceRetirement
  :: FilePath -> String -> MutationSnapshot -> IO (MutationWorkspaceOutcome ())
beginMutationWorkspaceRetirement = beginRecordedMutationRetirement ExactSnapshot (pure True)

beginRecordedMutationRetirement
  :: RecordedInventory
  -> IO Bool
  -> FilePath
  -> String
  -> MutationSnapshot
  -> IO (MutationWorkspaceOutcome ())
beginRecordedMutationRetirement inventory settlement project operation snapshot
  | not (validProject project && validRootGeneration operation) = pure MutationWorkspaceInvalid
  | otherwise = do
      owner <- getEffectiveUserID
      attempted <- try $ walkParent owner False project $ \parent identities -> withWorkspaceLease parent $ do
        let parentStable = do
              fresh <- try (walkParent owner False project $ \_ current -> pure current)
              held <- try (getFdStatus parent)
              pure $ case (fresh, held) of
                (Right current, Right status) -> current == identities && safePrivate owner status
                (_ :: Either IOException [(Integer, Integer)], _ :: Either IOException FileStatus) -> False
            intentStable =
              (== MutationWorkspaceIntentMatches)
                <$> observeMutationWorkspaceIntent parent operation snapshot parentStable
        intent <- observeMutationWorkspaceIntent parent operation snapshot parentStable
        case intent of
          MutationWorkspaceIntentMatches -> do
            birth <- readMutationWorkspaceBirth parent operation snapshot intentStable
            case birth of
              MutationWorkspaceBirthFound rootIdentity -> bracket (openDirectory parent operation) Posix.closeFd $ \root -> do
                initial <- getFdStatus root
                let rootStable = do
                      pathStable <- intentStable
                      current <- try (getFdStatus root)
                      named <- try $ bracket (openDirectory parent operation) Posix.closeFd $ \namedRoot -> do
                        status <- getFdStatus namedRoot
                        sameMount <- mutationWorkspaceSameMount parent namedRoot
                        pure (status, sameMount)
                      pure $ case (current, named) of
                        (Right held, Right (namedStatus, sameMount)) ->
                          pathStable
                            && sameMount
                            && safePrivate owner held
                            && sameIdentity initial held
                            && sameIdentity held namedStatus
                            && mutationSnapshotRootIdentity held == rootIdentity
                        (_ :: Either IOException FileStatus, _ :: Either IOException (FileStatus, Bool)) -> False
                    birthStable =
                      (== MutationWorkspaceIntentMatches)
                        <$> observeMutationWorkspaceBirth parent operation snapshot rootIdentity rootStable
                ready <- (&&) <$> birthStable <*> settlement
                if not ready
                  then pure MutationWorkspaceChanged
                  else do
                    observed <-
                      observeRecordedInventory inventory parent root operation snapshot rootIdentity rootStable
                    case observed of
                      Right () -> do
                        existing <- observeMutationWorkspaceRetirement parent operation snapshot rootIdentity birthStable
                        active <- observeMutationWorkspaceAdmission parent operation snapshot rootIdentity birthStable
                        let fence = case inventory of
                              ExactSnapshot -> birthStable
                              _ -> do
                                before <- (&&) <$> birthStable <*> settlement
                                if not before
                                  then pure False
                                  else do
                                    current <- observeRecordedInventory inventory parent root operation snapshot rootIdentity rootStable
                                    after <- (&&) <$> birthStable <*> settlement
                                    pure (either (const False) (const after) current)
                        case (existing, active) of
                          (MutationWorkspaceIntentMatches, MutationWorkspaceIntentMissing) -> do
                            stable <- fence
                            pure (if stable then MutationWorkspaceRetirementAlreadyRecorded else MutationWorkspaceChanged)
                          (MutationWorkspaceIntentMissing, MutationWorkspaceIntentMatches) -> do
                            recorded <- recordMutationWorkspaceRetirement parent operation snapshot rootIdentity fence
                            pure $ case recorded of
                              MutationWorkspaceIntentRecorded -> MutationWorkspaceRetirementRecorded
                              other -> MutationWorkspaceRetirementWriteRefused other
                          (MutationWorkspaceIntentMissing, other) -> pure (MutationWorkspaceAdmissionRefused other)
                          (other, _) -> pure (MutationWorkspaceRetirementRefused other)
                      Left refusal -> pure refusal
              other -> pure (MutationWorkspaceBirthReadRefused other)
          other -> pure (MutationWorkspaceIntentObservationRefused other)
      pure $ case attempted of
        Right result -> result
        Left (_ :: IOException) -> MutationWorkspaceUnobservable

-- A retired or unobservable operation must not enter either callback. This
-- only excludes cooperating callers holding this parent lease.
withUnretired
  :: Fd
  -> String
  -> MutationSnapshot
  -> MutationSnapshotRootIdentity
  -> IO Bool
  -> (IO Bool -> IO (MutationWorkspaceOutcome value))
  -> IO (MutationWorkspaceOutcome value)
withUnretired parent operation snapshot rootIdentity birthStable action = do
  retired <- observeMutationWorkspaceRetirement parent operation snapshot rootIdentity birthStable
  case retired of
    MutationWorkspaceIntentMissing -> do
      active <- observeMutationWorkspaceAdmission parent operation snapshot rootIdentity birthStable
      case active of
        MutationWorkspaceIntentMatches -> do
          let stable = do
                current <- observeMutationWorkspaceAdmission parent operation snapshot rootIdentity birthStable
                retirement <- observeMutationWorkspaceRetirement parent operation snapshot rootIdentity birthStable
                pure (current == MutationWorkspaceIntentMatches && retirement == MutationWorkspaceIntentMissing)
          ready <- stable
          if ready then action stable else pure MutationWorkspaceChanged
        other -> pure (MutationWorkspaceAdmissionRefused other)
    other -> pure (MutationWorkspaceRetirementRefused other)

-- Only an exact retirement marker with no active marker allows this read-side
-- recovery callback. This is not a process-settlement or deletion permit.
withRetired
  :: Fd
  -> String
  -> MutationSnapshot
  -> MutationSnapshotRootIdentity
  -> IO Bool
  -> (IO Bool -> IO (MutationWorkspaceOutcome value))
  -> IO (MutationWorkspaceOutcome value)
withRetired parent operation snapshot rootIdentity birthStable action = do
  retired <- observeMutationWorkspaceRetirement parent operation snapshot rootIdentity birthStable
  case retired of
    MutationWorkspaceIntentMatches -> do
      active <- observeMutationWorkspaceAdmission parent operation snapshot rootIdentity birthStable
      case active of
        MutationWorkspaceIntentMissing -> do
          let stable = do
                current <- observeMutationWorkspaceAdmission parent operation snapshot rootIdentity birthStable
                retirement <- observeMutationWorkspaceRetirement parent operation snapshot rootIdentity birthStable
                pure (current == MutationWorkspaceIntentMissing && retirement == MutationWorkspaceIntentMatches)
          ready <- stable
          if ready then action stable else pure MutationWorkspaceChanged
        other -> pure (MutationWorkspaceAdmissionRefused other)
    other -> pure (MutationWorkspaceRetirementRefused other)

-- Excludes cooperating users of this same held parent inode only. Detached
-- workers and noncooperating processes remain separate observations.
withWorkspaceLease
  :: Fd -> IO (MutationWorkspaceOutcome value) -> IO (MutationWorkspaceOutcome value)
withWorkspaceLease (Fd descriptor) action = mask $ \restore -> do
  acquired <- lockWorkspace descriptor (exclusiveLock .|. nonBlockingLock)
  if acquired /= 0
    then do
      failure <- getErrno
      pure
        ( if failure == eAGAIN || failure == eWOULDBLOCK
            then MutationWorkspaceBusy
            else MutationWorkspaceUnobservable
        )
    else restore action `finally` void (lockWorkspace descriptor releaseLock)

validProject :: FilePath -> Bool
validProject project =
  isAbsolute project
    && project /= "/"
    && normalise project == project
    && all
      (`notElem` [".", "..", ".build", ".data", ".test-data", ".git", ".secrets", ".prodbox-state"])
      (splitDirectories project)

walkParent :: UserID -> Bool -> FilePath -> (Fd -> [(Integer, Integer)] -> IO value) -> IO value
walkParent owner create project action =
  bracket (Posix.openFd "/" Posix.ReadOnly directoryFlags) Posix.closeFd $ \root ->
    descend root (filter (/= "/") (splitDirectories project)) []
 where
  descend current parts identities = do
    status <- getFdStatus current
    if not (isDirectory status)
      then ioError (userError "invalid workspace ancestor")
      else case parts of
        [] -> do
          if not (safeProject owner status) then ioError (userError "unsafe workspace project") else pure ()
          children current [".build", "mutation-workspaces"] (identity status : identities)
        name : rest -> bracket (openDirectory current name) Posix.closeFd $ \next ->
          descend next rest (identity status : identities)
  children current parts identities = case parts of
    [] -> action current (reverse identities)
    name : rest -> do
      if create then ensureDirectory current name else pure ()
      bracket (openDirectory current name) Posix.closeFd $ \next -> do
        status <- getFdStatus next
        let safe = if name == "mutation-workspaces" then safePrivate owner status else safeProject owner status
        if safe
          then children next rest (identity status : identities)
          else ioError (userError "unsafe workspace parent")

ensureDirectory :: Fd -> FilePath -> IO ()
ensureDirectory parent@(Fd descriptor) name = do
  result <- try $ withCString name $ \component ->
    throwErrnoIfMinus1_
      "create mutation workspace parent"
      (makeWorkspaceDirectoryAt descriptor component 0o700)
  case result of
    Right () -> fileSynchronise parent
    Left (failure :: IOException) | isAlreadyExistsError failure -> pure ()
    Left failure -> throwIO failure

openDirectory :: Fd -> FilePath -> IO Fd
openDirectory parent name = Posix.openFdAt (Just parent) name Posix.ReadOnly directoryFlags

directoryFlags :: Posix.OpenFileFlags
directoryFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.directory = True}

safeProject :: UserID -> FileStatus -> Bool
safeProject owner status = isDirectory status && fileOwner status == owner && fileMode status .&. 0o022 == 0

safePrivate :: UserID -> FileStatus -> Bool
safePrivate owner status = safeProject owner status && fileMode status .&. 0o077 == 0

identity :: FileStatus -> (Integer, Integer)
identity status = (toInteger (deviceID status), toInteger (fileID status))

sameIdentity :: FileStatus -> FileStatus -> Bool
sameIdentity left right = identity left == identity right
