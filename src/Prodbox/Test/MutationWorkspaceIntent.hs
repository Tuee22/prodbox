{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Durable non-secret mutation-workspace intent. A matching record does not
-- establish worker settlement, resource ownership or authority to clean up.
module Prodbox.Test.MutationWorkspaceIntent
  ( MutationWorkspaceIntentWrite (..)
  , MutationWorkspaceIntentObservation (..)
  , recordMutationWorkspaceIntent
  , observeMutationWorkspaceIntent
  , recordMutationWorkspaceBirth
  , observeMutationWorkspaceBirth
  , MutationWorkspaceBirthObservation (..)
  , readMutationWorkspaceBirth
  , mutationWorkspaceWorkerKey
  , recordMutationWorkspaceAdmission
  , observeMutationWorkspaceAdmission
  , recordMutationWorkspaceRetirement
  , observeMutationWorkspaceRetirement
  , recordMutationOutputCheckpoint
  , MutationOutputCheckpointObservation (..)
  , readMutationOutputCheckpoint
  ) where

import Control.Exception (IOException, bracket, mask, throwIO, try)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither, (.:))
import Data.Bits ((.&.))
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word64)
import Foreign.C.Error (throwErrnoIfMinus1_)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..), CUInt (..))
import Prodbox.Config.DeploymentScope (validRootGeneration)
import Prodbox.Subprocess.SystemdIdentity
  ( HostExecutionKey
  , hostExecutionKeyFromText
  , hostExecutionKeyText
  )
import Prodbox.Test.MutationOutputInventory (MutationOutputLimits, mutationOutputLimitValues)
import Prodbox.Test.MutationSnapshot
  ( MutationSnapshot
  , SnapshotMutation (..)
  , mutationSnapshotFiles
  , mutationSnapshotMutation
  , mutationSnapshotSource
  )
import Prodbox.Test.MutationSnapshotWrite (MutationSnapshotRootIdentity (..))
import Prodbox.Test.Qualification.Evidence
  ( PublicEvidenceDigest
  , hashPublicEvidence
  , mkPublicEvidenceDigest
  , publicEvidenceDigestText
  )
import Prodbox.Test.Qualification.SourceIdentity
  ( SourceManifestPolicyIdentity (..)
  , gitHeadText
  , sourceGitHead
  , sourceManifestDigest
  , sourceManifestEntryCount
  , sourceManifestPolicyIdentity
  , sourceWorktreeState
  )
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError, isEOFError)
import System.Posix.Files
  ( FileStatus
  , deviceID
  , fileID
  , fileMode
  , fileOwner
  , fileSize
  , getFdStatus
  , isRegularFile
  , linkCount
  , modificationTimeHiRes
  , statusChangeTimeHiRes
  )
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as PosixBytes
import System.Posix.Types (Fd (..), UserID)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

foreign import capi "stdio.h renameat2"
  renameMarkerAt :: CInt -> CString -> CInt -> CString -> CUInt -> IO CInt
foreign import capi "stdio.h value RENAME_NOREPLACE" noReplace :: CUInt

data MutationWorkspaceIntentWrite
  = MutationWorkspaceIntentRecorded
  | MutationWorkspaceIntentExists
  | MutationWorkspaceIntentWriteInvalid
  | MutationWorkspaceIntentWriteIncomplete
  | MutationWorkspaceIntentWriteUnobservable
  | MutationWorkspaceIntentWriteTimedOut
  deriving (Eq, Show)

data MutationWorkspaceIntentObservation
  = MutationWorkspaceIntentMatches
  | MutationWorkspaceIntentMissing
  | MutationWorkspaceIntentConflict
  | MutationWorkspaceIntentObservationInvalid
  | MutationWorkspaceIntentUnobservable
  deriving (Eq, Show)

data MutationWorkspaceBirthObservation
  = MutationWorkspaceBirthFound !MutationSnapshotRootIdentity
  | MutationWorkspaceBirthMissing
  | MutationWorkspaceBirthConflict
  | MutationWorkspaceBirthInvalid
  | MutationWorkspaceBirthUnobservable
  deriving (Eq, Show)

data MutationOutputCheckpointObservation
  = MutationOutputCheckpointFound !PublicEvidenceDigest
  | MutationOutputCheckpointMissing
  | MutationOutputCheckpointConflict
  | MutationOutputCheckpointInvalid
  | MutationOutputCheckpointUnobservable
  deriving (Eq, Show)

-- | Exclusively write and read back intent before the workspace is created.
-- An incomplete record is retained for recovery; callers must not infer
-- absence or retry it as a new operation.
recordMutationWorkspaceIntent
  :: Fd -> String -> MutationSnapshot -> IO Bool -> IO MutationWorkspaceIntentWrite
recordMutationWorkspaceIntent parent operation snapshot stable
  | not (validRootGeneration operation) = pure MutationWorkspaceIntentWriteInvalid
  | otherwise = recordPayload parent (intentName operation) (intentBytes operation snapshot) stable

observeMutationWorkspaceIntent
  :: Fd -> String -> MutationSnapshot -> IO Bool -> IO MutationWorkspaceIntentObservation
observeMutationWorkspaceIntent parent operation snapshot stable
  | not (validRootGeneration operation) = pure MutationWorkspaceIntentObservationInvalid
  | otherwise = observePayload parent (intentName operation) (intentBytes operation snapshot) stable

-- | Bind the separately recorded intent to the root identity observed by the
-- exclusive creator. A record does not prove settlement or prevent inode reuse.
recordMutationWorkspaceBirth
  :: Fd
  -> String
  -> MutationSnapshot
  -> MutationSnapshotRootIdentity
  -> IO Bool
  -> IO MutationWorkspaceIntentWrite
recordMutationWorkspaceBirth parent operation snapshot rootIdentity stable
  | not (validRootGeneration operation) = pure MutationWorkspaceIntentWriteInvalid
  | otherwise =
      recordPayload parent (birthName operation) (birthBytes operation snapshot rootIdentity) stable

observeMutationWorkspaceBirth
  :: Fd
  -> String
  -> MutationSnapshot
  -> MutationSnapshotRootIdentity
  -> IO Bool
  -> IO MutationWorkspaceIntentObservation
observeMutationWorkspaceBirth parent operation snapshot rootIdentity stable
  | not (validRootGeneration operation) = pure MutationWorkspaceIntentObservationInvalid
  | otherwise =
      observePayload parent (birthName operation) (birthBytes operation snapshot rootIdentity) stable

-- A checkpoint binds non-secret metadata to one output birth and source
-- worker key. It does not authenticate contents or establish settlement.
recordMutationOutputCheckpoint
  :: Fd
  -> String
  -> String
  -> MutationSnapshot
  -> MutationSnapshotRootIdentity
  -> HostExecutionKey
  -> MutationOutputLimits
  -> PublicEvidenceDigest
  -> IO Bool
  -> IO MutationWorkspaceIntentWrite
recordMutationOutputCheckpoint parent operation checkpoint snapshot identity worker limits fingerprint stable
  | not (validRootGeneration operation && validRootGeneration checkpoint) =
      pure MutationWorkspaceIntentWriteInvalid
  | otherwise =
      recordPayload
        parent
        (outputCheckpointName operation checkpoint)
        (outputCheckpointBytes operation checkpoint snapshot identity worker limits fingerprint)
        stable

readMutationOutputCheckpoint
  :: Fd
  -> String
  -> String
  -> MutationSnapshot
  -> MutationSnapshotRootIdentity
  -> HostExecutionKey
  -> MutationOutputLimits
  -> IO Bool
  -> IO MutationOutputCheckpointObservation
readMutationOutputCheckpoint parent operation checkpoint snapshot identity worker limits stable
  | not (validRootGeneration operation && validRootGeneration checkpoint) =
      pure MutationOutputCheckpointInvalid
  | otherwise = do
      owner <- getEffectiveUserID
      result <- timeout 5000000 $ try $ do
        before <- stable
        if not before
          then pure MutationOutputCheckpointUnobservable
          else do
            observed <- readOutputCheckpoint owner parent operation checkpoint snapshot identity worker limits
            after <- stable
            pure (if after then observed else MutationOutputCheckpointUnobservable)
      pure $ case result of
        Nothing -> MutationOutputCheckpointUnobservable
        Just (Left (_ :: IOException)) -> MutationOutputCheckpointUnobservable
        Just (Right value) -> value

readOutputCheckpoint
  :: UserID
  -> Fd
  -> String
  -> String
  -> MutationSnapshot
  -> MutationSnapshotRootIdentity
  -> HostExecutionKey
  -> MutationOutputLimits
  -> IO MutationOutputCheckpointObservation
readOutputCheckpoint owner parent operation checkpoint snapshot identity worker limits = do
  let name = outputCheckpointName operation checkpoint
  opened <- try (Posix.openFdAt (Just parent) name Posix.ReadOnly readFlags)
  case opened of
    Left (failure :: IOException)
      | isDoesNotExistError failure -> pure MutationOutputCheckpointMissing
      | otherwise -> pure MutationOutputCheckpointUnobservable
    Right descriptor -> bracket (pure descriptor) Posix.closeFd $ \file -> do
      before <- getFdStatus file
      if not (safeFile owner before)
        then pure MutationOutputCheckpointInvalid
        else do
          bytes <- readBounded file [] 0
          after <- getFdStatus file
          named <-
            bracket (Posix.openFdAt (Just parent) name Posix.ReadOnly readFlags) Posix.closeFd getFdStatus
          if not (safeFile owner after && sameVersion before after && sameVersion after named)
            then pure MutationOutputCheckpointUnobservable
            else pure (decodeOutputCheckpoint operation checkpoint snapshot identity worker limits bytes)

decodeOutputCheckpoint
  :: String
  -> String
  -> MutationSnapshot
  -> MutationSnapshotRootIdentity
  -> HostExecutionKey
  -> MutationOutputLimits
  -> ByteString.ByteString
  -> MutationOutputCheckpointObservation
decodeOutputCheckpoint operation checkpoint snapshot identity worker limits bytes =
  case Aeson.eitherDecodeStrict' bytes
    >>= parseEither (Aeson.withObject "output checkpoint" (.: "metadata")) of
    Left _ -> MutationOutputCheckpointInvalid
    Right raw -> case mkPublicEvidenceDigest raw of
      Nothing -> MutationOutputCheckpointInvalid
      Just fingerprint
        | bytes == outputCheckpointBytes operation checkpoint snapshot identity worker limits fingerprint ->
            MutationOutputCheckpointFound fingerprint
        | otherwise -> MutationOutputCheckpointConflict

-- | Create the explicit active marker only after the intent and birth have
-- been checked. Its absence never grants admission to a recovered operation.
recordMutationWorkspaceAdmission
  :: Fd
  -> String
  -> MutationSnapshot
  -> MutationSnapshotRootIdentity
  -> IO Bool
  -> IO MutationWorkspaceIntentWrite
recordMutationWorkspaceAdmission parent operation snapshot rootIdentity stable
  | not (validRootGeneration operation) = pure MutationWorkspaceIntentWriteInvalid
  | otherwise =
      recordPayload
        parent
        (admissionName operation)
        (retirementBytes operation snapshot rootIdentity)
        stable

observeMutationWorkspaceAdmission
  :: Fd
  -> String
  -> MutationSnapshot
  -> MutationSnapshotRootIdentity
  -> IO Bool
  -> IO MutationWorkspaceIntentObservation
observeMutationWorkspaceAdmission parent operation snapshot rootIdentity stable
  | not (validRootGeneration operation) = pure MutationWorkspaceIntentObservationInvalid
  | otherwise =
      observePayload
        parent
        (admissionName operation)
        (retirementBytes operation snapshot rootIdentity)
        stable

-- | Atomically move the exact active marker to its retirement name without
-- replacement. Incomplete transitions are retained and must be recovered.
recordMutationWorkspaceRetirement
  :: Fd
  -> String
  -> MutationSnapshot
  -> MutationSnapshotRootIdentity
  -> IO Bool
  -> IO MutationWorkspaceIntentWrite
recordMutationWorkspaceRetirement parent@(Fd descriptor) operation snapshot rootIdentity stable
  | not (validRootGeneration operation) = pure MutationWorkspaceIntentWriteInvalid
  | otherwise = do
      owner <- getEffectiveUserID
      started <- newIORef False
      attempted <- timeout 5000000 $ try $ do
        ready <- stable
        (source, sourceStatus) <- readPayload owner parent (admissionName operation) payload
        (destination, _) <- readPayload owner parent (retirementName operation) payload
        if not ready
          || source /= MutationWorkspaceIntentMatches
          || destination /= MutationWorkspaceIntentMissing
          then pure MutationWorkspaceIntentWriteUnobservable
          else mask $ \restore -> do
            withCString (admissionName operation) $ \from -> withCString (retirementName operation) $ \to ->
              throwErrnoIfMinus1_
                "retire mutation workspace"
                (renameMarkerAt descriptor from descriptor to noReplace)
            writeIORef started True
            restore $ do
              fileSynchronise parent
              (retired, retiredStatus) <- readPayload owner parent (retirementName operation) payload
              (active, _) <- readPayload owner parent (admissionName operation) payload
              final <- stable
              pure $
                if final
                  && retired == MutationWorkspaceIntentMatches
                  && active == MutationWorkspaceIntentMissing
                  && maybe False (\old -> maybe False (sameRecordIdentity old) retiredStatus) sourceStatus
                  then MutationWorkspaceIntentRecorded
                  else MutationWorkspaceIntentWriteIncomplete
      didStart <- readIORef started
      pure $ case attempted of
        Nothing ->
          if didStart then MutationWorkspaceIntentWriteIncomplete else MutationWorkspaceIntentWriteTimedOut
        Just (Left (_ :: IOException)) ->
          if didStart
            then MutationWorkspaceIntentWriteIncomplete
            else MutationWorkspaceIntentWriteUnobservable
        Just (Right value) -> value
 where
  payload = retirementBytes operation snapshot rootIdentity

observeMutationWorkspaceRetirement
  :: Fd
  -> String
  -> MutationSnapshot
  -> MutationSnapshotRootIdentity
  -> IO Bool
  -> IO MutationWorkspaceIntentObservation
observeMutationWorkspaceRetirement parent operation snapshot rootIdentity stable
  | not (validRootGeneration operation) = pure MutationWorkspaceIntentObservationInvalid
  | otherwise =
      observePayload
        parent
        (retirementName operation)
        (retirementBytes operation snapshot rootIdentity)
        stable

-- | Recover the recorded identity without opening the workspace root. This
-- observes one retained record, not the presence or absence of a resource.
readMutationWorkspaceBirth
  :: Fd -> String -> MutationSnapshot -> IO Bool -> IO MutationWorkspaceBirthObservation
readMutationWorkspaceBirth parent operation snapshot stable
  | not (validRootGeneration operation) = pure MutationWorkspaceBirthInvalid
  | otherwise = do
      owner <- getEffectiveUserID
      result <- timeout 5000000 $ try $ do
        before <- stable
        if not before
          then pure MutationWorkspaceBirthUnobservable
          else do
            observed <- readBirth owner parent operation snapshot
            after <- stable
            pure (if after then observed else MutationWorkspaceBirthUnobservable)
      pure $ case result of
        Nothing -> MutationWorkspaceBirthUnobservable
        Just (Left (_ :: IOException)) -> MutationWorkspaceBirthUnobservable
        Just (Right value) -> value

readBirth :: UserID -> Fd -> String -> MutationSnapshot -> IO MutationWorkspaceBirthObservation
readBirth owner parent operation snapshot = do
  opened <- try (Posix.openFdAt (Just parent) (birthName operation) Posix.ReadOnly readFlags)
  case opened of
    Left (failure :: IOException)
      | isDoesNotExistError failure -> pure MutationWorkspaceBirthMissing
      | otherwise -> pure MutationWorkspaceBirthUnobservable
    Right descriptor -> bracket (pure descriptor) Posix.closeFd $ \file -> do
      before <- getFdStatus file
      if not (safeFile owner before)
        then pure MutationWorkspaceBirthInvalid
        else do
          bytes <- readBounded file [] 0
          after <- getFdStatus file
          named <-
            bracket
              (Posix.openFdAt (Just parent) (birthName operation) Posix.ReadOnly readFlags)
              Posix.closeFd
              getFdStatus
          if not (safeFile owner after && sameVersion before after && sameVersion after named)
            then pure MutationWorkspaceBirthUnobservable
            else pure (decodeBirth operation snapshot bytes)

decodeBirth
  :: String -> MutationSnapshot -> ByteString.ByteString -> MutationWorkspaceBirthObservation
decodeBirth operation snapshot bytes =
  case Aeson.eitherDecodeStrict' bytes >>= parseEither parseIdentity of
    Left _ -> MutationWorkspaceBirthInvalid
    Right rootIdentity@(MutationSnapshotRootIdentity device inode)
      | device < 0 || inode <= 0 || device > limit || inode > limit -> MutationWorkspaceBirthInvalid
      | bytes /= birthBytes operation snapshot rootIdentity -> MutationWorkspaceBirthConflict
      | otherwise -> MutationWorkspaceBirthFound rootIdentity
 where
  limit = toInteger (maxBound :: Word64)
  parseIdentity = Aeson.withObject "mutation workspace birth" $ \value ->
    MutationSnapshotRootIdentity <$> value .: "device" <*> value .: "inode"

recordPayload
  :: Fd -> FilePath -> ByteString.ByteString -> IO Bool -> IO MutationWorkspaceIntentWrite
recordPayload parent name payload stable = do
  owner <- getEffectiveUserID
  started <- newIORef False
  attempted <- timeout 5000000 $ try $ do
    ready <- stable
    if not ready
      then pure MutationWorkspaceIntentWriteUnobservable
      else mask $ \restore -> do
        created <- try (Posix.openFdAt (Just parent) name Posix.WriteOnly createFlags)
        case created of
          Left (failure :: IOException)
            | isAlreadyExistsError failure -> pure MutationWorkspaceIntentExists
            | otherwise -> throwIO failure
          Right descriptor -> do
            writeIORef started True
            bracket (pure descriptor) Posix.closeFd $ \file -> restore $ do
              writeAll file payload
              fileSynchronise file
              fileSynchronise parent
              held <- getFdStatus file
              (observation, named) <- readPayload owner parent name payload
              final <- stable
              pure $
                if final && observation == MutationWorkspaceIntentMatches && maybe False (sameVersion held) named
                  then MutationWorkspaceIntentRecorded
                  else MutationWorkspaceIntentWriteIncomplete
  wasStarted <- readIORef started
  pure $ case attempted of
    Nothing ->
      if wasStarted then MutationWorkspaceIntentWriteIncomplete else MutationWorkspaceIntentWriteTimedOut
    Just (Left (_ :: IOException)) ->
      if wasStarted
        then MutationWorkspaceIntentWriteIncomplete
        else MutationWorkspaceIntentWriteUnobservable
    Just (Right value) -> value

observePayload
  :: Fd -> FilePath -> ByteString.ByteString -> IO Bool -> IO MutationWorkspaceIntentObservation
observePayload parent name payload stable = do
  owner <- getEffectiveUserID
  result <- timeout 5000000 $ try $ do
    before <- stable
    if not before
      then pure MutationWorkspaceIntentUnobservable
      else do
        (observation, _) <- readPayload owner parent name payload
        after <- stable
        pure (if after then observation else MutationWorkspaceIntentUnobservable)
  pure $ case result of
    Nothing -> MutationWorkspaceIntentUnobservable
    Just (Left (_ :: IOException)) -> MutationWorkspaceIntentUnobservable
    Just (Right value) -> value

readPayload
  :: UserID
  -> Fd
  -> FilePath
  -> ByteString.ByteString
  -> IO (MutationWorkspaceIntentObservation, Maybe FileStatus)
readPayload owner parent name payload = do
  opened <- try (Posix.openFdAt (Just parent) name Posix.ReadOnly readFlags)
  case opened of
    Left (failure :: IOException)
      | isDoesNotExistError failure -> pure (MutationWorkspaceIntentMissing, Nothing)
      | otherwise -> pure (MutationWorkspaceIntentUnobservable, Nothing)
    Right descriptor -> bracket (pure descriptor) Posix.closeFd $ \file -> do
      before <- getFdStatus file
      if not (safeFile owner before)
        then pure (MutationWorkspaceIntentObservationInvalid, Nothing)
        else do
          bytes <- readBounded file [] 0
          after <- getFdStatus file
          named <-
            bracket (Posix.openFdAt (Just parent) name Posix.ReadOnly readFlags) Posix.closeFd getFdStatus
          if not (safeFile owner after && sameVersion before after && sameVersion after named)
            then pure (MutationWorkspaceIntentUnobservable, Nothing)
            else
              pure
                ( if bytes == payload then MutationWorkspaceIntentMatches else MutationWorkspaceIntentConflict
                , Just after
                )

intentBytes :: String -> MutationSnapshot -> ByteString.ByteString
intentBytes operation snapshot =
  LazyByteString.toStrict $
    Aeson.encode $
      Aeson.object
        [ "kind" Aeson..= ("mutation-workspace-intent-v1" :: Text.Text)
        , "operation" Aeson..= operation
        , "source_head" Aeson..= gitHeadText (sourceGitHead source)
        , "source_state" Aeson..= show (sourceWorktreeState source)
        , "source_digest" Aeson..= sourceManifestDigest source
        , "source_count" Aeson..= sourceManifestEntryCount source
        , "source_policy" Aeson..= sourcePolicyIdentifier policy
        , "source_policy_version" Aeson..= sourcePolicyVersion policy
        , "source_policy_digest" Aeson..= sourcePolicyDigest policy
        , "snapshot_file_count" Aeson..= length (mutationSnapshotFiles snapshot)
        , "mutation" Aeson..= fmap mutationObject (mutationSnapshotMutation snapshot)
        ]
 where
  source = mutationSnapshotSource snapshot
  policy = sourceManifestPolicyIdentity source
  mutationObject mutation =
    Aeson.object
      [ "reviewed" Aeson..= show (snapshotReviewedMutation mutation)
      , "patch_digest" Aeson..= publicEvidenceDigestText (snapshotMutationPatch mutation)
      , "mutant_digest" Aeson..= publicEvidenceDigestText (snapshotMutantDigest mutation)
      ]

-- | A deterministic public-metadata key for a future managed worker family.
-- It does not record a launch or establish that all workers use this key.
mutationWorkspaceWorkerKey
  :: String -> MutationSnapshot -> MutationSnapshotRootIdentity -> Maybe HostExecutionKey
mutationWorkspaceWorkerKey operation snapshot identity@(MutationSnapshotRootIdentity device inode)
  | not (validRootGeneration operation) || device < 0 || inode <= 0 = Nothing
  | device > limit || inode > limit = Nothing
  | otherwise =
      hostExecutionKeyFromText $
        Text.unpack $
          publicEvidenceDigestText $
            hashPublicEvidence $
              "prodbox-mutation-workspace-worker-v1\NUL"
                <> TextEncoding.decodeUtf8 (birthBytes operation snapshot identity)
 where
  limit = toInteger (maxBound :: Word64)

birthBytes :: String -> MutationSnapshot -> MutationSnapshotRootIdentity -> ByteString.ByteString
birthBytes operation snapshot (MutationSnapshotRootIdentity device inode) =
  LazyByteString.toStrict $
    Aeson.encode $
      Aeson.object
        [ "kind" Aeson..= ("mutation-workspace-birth-v1" :: Text.Text)
        , "intent" Aeson..= TextEncoding.decodeUtf8 (intentBytes operation snapshot)
        , "device" Aeson..= device
        , "inode" Aeson..= inode
        ]

outputCheckpointBytes
  :: String
  -> String
  -> MutationSnapshot
  -> MutationSnapshotRootIdentity
  -> HostExecutionKey
  -> MutationOutputLimits
  -> PublicEvidenceDigest
  -> ByteString.ByteString
outputCheckpointBytes operation checkpoint snapshot identity worker limits fingerprint =
  LazyByteString.toStrict $
    Aeson.encode $
      Aeson.object
        [ "kind" Aeson..= ("mutation-output-checkpoint-v1" :: Text.Text)
        , "birth" Aeson..= TextEncoding.decodeUtf8 (birthBytes operation snapshot identity)
        , "checkpoint" Aeson..= checkpoint
        , "worker_key" Aeson..= hostExecutionKeyText worker
        , "limits" Aeson..= mutationOutputLimitValues limits
        , "metadata" Aeson..= publicEvidenceDigestText fingerprint
        ]

outputCheckpointName :: String -> String -> FilePath
outputCheckpointName operation checkpoint = operation ++ ".output." ++ checkpoint

retirementBytes
  :: String -> MutationSnapshot -> MutationSnapshotRootIdentity -> ByteString.ByteString
retirementBytes operation snapshot rootIdentity =
  LazyByteString.toStrict $
    Aeson.encode $
      Aeson.object
        [ "kind" Aeson..= ("mutation-workspace-admission-v1" :: Text.Text)
        , "birth" Aeson..= TextEncoding.decodeUtf8 (birthBytes operation snapshot rootIdentity)
        ]

admissionName :: String -> FilePath
admissionName operation = operation ++ ".active"

retirementName :: String -> FilePath
retirementName operation = operation ++ ".retire"

birthName :: String -> FilePath
birthName operation = operation ++ ".birth"

intentName :: String -> FilePath
intentName operation = operation ++ ".intent"

readFlags :: Posix.OpenFileFlags
readFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}

createFlags :: Posix.OpenFileFlags
createFlags = readFlags {Posix.creat = Just 0o600, Posix.exclusive = True}

safeFile :: UserID -> FileStatus -> Bool
safeFile owner status =
  isRegularFile status
    && fileOwner status == owner
    && fileMode status .&. 0o077 == 0
    && linkCount status == 1
    && fileSize status >= 0
    && fileSize status <= 4096

sameRecordIdentity :: FileStatus -> FileStatus -> Bool
sameRecordIdentity left right =
  deviceID left == deviceID right
    && fileID left == fileID right
    && fileOwner left == fileOwner right
    && fileMode left == fileMode right
    && linkCount left == linkCount right
    && fileSize left == fileSize right

sameVersion :: FileStatus -> FileStatus -> Bool
sameVersion left right =
  deviceID left == deviceID right
    && fileID left == fileID right
    && fileMode left == fileMode right
    && fileOwner left == fileOwner right
    && linkCount left == linkCount right
    && fileSize left == fileSize right
    && modificationTimeHiRes left == modificationTimeHiRes right
    && statusChangeTimeHiRes left == statusChangeTimeHiRes right

writeAll :: Fd -> ByteString.ByteString -> IO ()
writeAll file bytes
  | ByteString.null bytes = pure ()
  | otherwise = do
      written <- PosixBytes.fdWrite file bytes
      if written <= 0
        then ioError (userError "short mutation intent write")
        else writeAll file (ByteString.drop (fromIntegral written) bytes)

readBounded :: Fd -> [ByteString.ByteString] -> Int -> IO ByteString.ByteString
readBounded file chunks count
  | count > 4096 = ioError (userError "mutation intent too large")
  | otherwise = do
      result <- try (PosixBytes.fdRead file (fromIntegral (min 4095 (4096 - count) + 1)))
      case result of
        Left (failure :: IOException) | isEOFError failure -> pure (ByteString.concat (reverse chunks))
        Left failure -> throwIO failure
        Right bytes | ByteString.null bytes -> pure (ByteString.concat (reverse chunks))
        Right bytes -> readBounded file (bytes : chunks) (count + ByteString.length bytes)
