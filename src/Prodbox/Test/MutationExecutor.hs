{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The bounded source-mutation executor (Phase 1, T07). Each case writes a
-- captured, secret-filtered worktree into a private workspace,
-- checks the unmodified build against the designated test (the baseline),
-- applies one reviewed or calibration patch, rebuilds, selects exactly one
-- test and runs it, and classifies the outcome with the reviewed
-- 'classifyMutationAttempt'. Every build and test runs in a container with no
-- network or Docker socket. Qualification also requires exact worker and
-- workspace retirement and a verified case receipt.
-- Real cloud acceptance never uses these mutants.
--
-- Isolation prerequisite: the node image pinned by Phase 1 must be present in
-- the selected Docker daemon (it supplies only a root file system; the host
-- toolchain is mounted over it). Unprivileged namespaces, systemd sandboxing
-- and bubblewrap were each measured on this host and do not provide a
-- boundary, so a container is the isolation mechanism.
module Prodbox.Test.MutationExecutor
  ( runMutationCatalog
  , prepareCampaignRoot
  , withPreparedCampaignRoot
  , recordCampaignIdentity
  , mutationContainerArguments
  , readMutationOutputMember
  , validMutationMounts
  , MutationBindingObservation (..)
  , withBoundMutationDirectories
  , withCampaignMutationDirectories
  , MutationInvocationDiagnostic (..)
  , changedInvocationDiagnostic
  , MutationLaunchIntentResult (..)
  , recordMutationLaunchIntent
  , MutationLaunchInvocation (..)
  , withRecordedMutationLaunch
  , mutationInventoryDiagnostic
  , MutationContainerIdObservation (..)
  , observeMutationContainerId
  , MutationContainerReceiptWrite (..)
  , MutationContainerReceiptObservation (..)
  , recordMutationContainerReceipt
  , observeMutationContainerReceipt
  , inspectMutationCampaign
  , runMutationCampaignStatus
  , runMutationCampaignCleanup
  , mutationIsolationCommand
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, bracket, mask, try)
import Control.Monad (guard, unless, when)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser, parseEither, (.:))
import Data.Bits ((.&.))
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAsciiLower, isAsciiUpper, isDigit, toLower)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (find, isInfixOf, isPrefixOf, stripPrefix)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import Foreign.C.Error (throwErrnoIfMinus1_)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.CLI.Output (writeOutputLine)
import Prodbox.Control.DockerConnectedInfo
  ( DockerConnectedInfo (DockerConnectedInfo)
  , DockerConnectedInfoResult (DockerConnectedInfoCompleted)
  , DockerMutationVolume (..)
  , readDockerSessionContainerNotFound
  , withConnectedDockerInfo
  )
import Prodbox.Control.DockerIdentity
  ( DockerDaemonObservation (DockerDaemonObserved)
  , observeDockerDaemon
  )
import Prodbox.Control.DockerPeer (DockerPeer (DockerPeer), DockerPeerResult (DockerPeerCompleted))
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessWithInputBounded
  )
import Prodbox.Test.MutationDependencies
  ( PreparedMutationDependencies (..)
  , prepareMutationDependencies
  )
import Prodbox.Test.MutationDisk
  ( MutationDisk (..)
  , MutationDiskReceipt (..)
  , mutationDiskVolume
  , retireUnusedMutationDisk
  , withMutationDisk
  )
import Prodbox.Test.MutationOutcome
import Prodbox.Test.MutationOutputInventory
  ( MutationOutputObservation (MutationOutputObserved)
  , mutationOutputInventoryFingerprint
  , mutationOutputLimits
  , mutationWorkspaceSameMount
  , observeMutationOutputInventory
  , removeObservedMutationOutput
  )
import Prodbox.Test.MutationSnapshot
  ( MutationSnapshot
  , captureMutationSnapshot
  , mutationSnapshotSource
  )
import Prodbox.Test.MutationSnapshotWrite
  ( MutationSnapshotWriteResult (MutationSnapshotWritten)
  , writeMutationSnapshot
  )
import Prodbox.Test.Qualification.Evidence
  ( PublicEvidenceDigest
  , hashPublicEvidence
  , publicEvidenceDigestText
  )
import Prodbox.Test.Qualification.SourceIdentity
  ( SourceIdentity
  , SourceManifestPolicyIdentity (..)
  , gitHeadText
  , sourceGitHead
  , sourceManifestDigest
  , sourceManifestEntryCount
  , sourceManifestPolicyIdentity
  , sourceWorktreeState
  )
import Prodbox.Test.ReviewedMutation
  ( ReviewedMutation (..)
  , prepareReviewedMutation
  , preparedMutantBytes
  , reviewedAssertion
  , reviewedPatchDigest
  , reviewedSourcePath
  , reviewedTestPath
  )
import System.Directory
  ( getCurrentDirectory
  , getHomeDirectory
  )
import System.Exit (ExitCode (..))
import System.FilePath (isAbsolute, normalise, splitDirectories, takeDirectory, takeFileName, (</>))
import System.IO (hClose, hFlush, stdout)
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError, isEOFError)
import System.Posix.Directory (closeDirStream, openDirStream, readDirStream)
import System.Posix.Files
  ( FileStatus
  , deviceID
  , fileID
  , fileMode
  , fileOwner
  , fileSize
  , getFdStatus
  , isDirectory
  , isRegularFile
  , linkCount
  , modificationTimeHiRes
  , statusChangeTimeHiRes
  )
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as PosixBytes
import System.Posix.Types (CMode (..), Fd (..))
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveGroupID, getEffectiveUserID)
import System.Timeout (timeout)

-- | The pinned node image supplies only a root file system.
containerImage :: String
containerImage = "sha256:152b34afd8a2de5c8348a264426bc99b71058ee0e1a15eab9b30849605e4752d"

foreign import capi "sys/stat.h mkdirat"
  makeCampaignDirectoryAt :: CInt -> CString -> CMode -> IO CInt

data MutationLaunchIntentResult
  = MutationLaunchIntentRecorded
  | MutationLaunchIntentExists
  | MutationLaunchIntentRefused
  | MutationLaunchIntentIncomplete
  deriving (Eq, Show)

mutationLaunchStem :: String -> String -> String
mutationLaunchStem label stage =
  ".mutation-launch-"
    ++ take 32 (ByteString8.unpack (hexSha256 (ByteString8.pack (label ++ "\NUL" ++ stage))))

validLaunchToken :: String -> Bool
validLaunchToken value =
  not (null value)
    && length value <= 160
    && all (\c -> isAsciiLower c || isAsciiUpper c || (isDigit c && c <= '9') || c == '-') value

validLaunchInput :: String -> String -> String -> Int -> Bool
validLaunchInput label stage command seconds =
  validLaunchToken label
    && stage
      `elem` [ "disk-keeper"
             , "isolation"
             , "baseline-build"
             , "baseline-selection"
             , "baseline-test"
             , "mutant-build"
             , "mutant-selection"
             , "mutant-test"
             ]
    && not (null command)
    && length command <= 8192
    && '\NUL' `notElem` command
    && seconds > 0
    && seconds <= 3600

validContainerId :: String -> Bool
validContainerId value = length value == 64 && all hex value
 where
  hex c = c >= '0' && c <= '9' || c >= 'a' && c <= 'f'

launchIntentValue
  :: String -> String -> String -> Int -> FileStatus -> FileStatus -> FileStatus -> Aeson.Value
launchIntentValue label stage command seconds parent source output =
  retainedLaunchIntentValue
    label
    stage
    digest
    seconds
    containerImage
    mutationDockerSocket
    parent
    source
    output
 where
  digest = ByteString8.unpack (hexSha256 (TextEncoding.encodeUtf8 (Text.pack command)))

retainedLaunchIntentValue
  :: String
  -> String
  -> String
  -> Int
  -> String
  -> FilePath
  -> FileStatus
  -> FileStatus
  -> FileStatus
  -> Aeson.Value
retainedLaunchIntentValue label stage digest seconds image socket parent source output =
  Aeson.object
    [ "schema_version" Aeson..= (1 :: Int)
    , "kind" Aeson..= ("mutation-container-launch" :: String)
    , "label" Aeson..= label
    , "stage" Aeson..= stage
    , "command_sha256" Aeson..= digest
    , "timeout_seconds" Aeson..= seconds
    , "container_id_file" Aeson..= (mutationLaunchStem label stage ++ ".cid")
    , "image" Aeson..= image
    , "socket" Aeson..= socket
    , "parent_device" Aeson..= toInteger (deviceID parent)
    , "parent_inode" Aeson..= toInteger (fileID parent)
    , "source_device" Aeson..= toInteger (deviceID source)
    , "source_inode" Aeson..= toInteger (fileID source)
    , "output_device" Aeson..= toInteger (deviceID output)
    , "output_inode" Aeson..= toInteger (fileID output)
    ]

-- A durable local identity for one Docker request, not proof that Docker
-- received it, that a container exists, or that any worker has settled.
recordMutationLaunchIntent
  :: Fd -> Fd -> Fd -> String -> String -> String -> Int -> IO Bool -> IO MutationLaunchIntentResult
recordMutationLaunchIntent parent source output label stage command seconds stable
  | not (validLaunchInput label stage command seconds) = pure MutationLaunchIntentRefused
  | otherwise = do
      touched <- newIORef False
      outcome <- timeout 10000000 $ try $ do
        ready <- stable
        parentStatus <- getFdStatus parent
        sourceStatus <- getFdStatus source
        outputStatus <- getFdStatus output
        owner <- getEffectiveUserID
        sourceMount <- mutationWorkspaceSameMount parent source
        outputMount <- mutationWorkspaceSameMount parent output
        let safeDirectory status = isDirectory status && fileOwner status == owner && fileMode status .&. 0o7077 == 0
            distinct = deviceID sourceStatus /= deviceID outputStatus || fileID sourceStatus /= fileID outputStatus
        if not
          ( ready
              && all safeDirectory [parentStatus, sourceStatus, outputStatus]
              && sourceMount
              && outputMount
              && distinct
          )
          then pure MutationLaunchIntentRefused
          else mask $ \restore -> do
            let bytes =
                  LazyByteString.toStrict $
                    Aeson.encode $
                      launchIntentValue label stage command seconds parentStatus sourceStatus outputStatus
                name = mutationLaunchStem label stage ++ ".json"
                readFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}
                createFlags = readFlags {Posix.exclusive = True, Posix.creat = Just 0o600}
            opened <- try (Posix.openFdAt (Just parent) name Posix.WriteOnly createFlags)
            case opened of
              Left failure | isAlreadyExistsError failure -> pure MutationLaunchIntentExists
              Left (_ :: IOException) -> pure MutationLaunchIntentRefused
              Right file -> do
                writeIORef touched True
                written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                  writeAll held bytes
                  fileSynchronise held
                  fileSynchronise parent
                  getFdStatus held
                case written of
                  Left (_ :: IOException) -> pure MutationLaunchIntentIncomplete
                  Right created -> restore $ bracket (Posix.openFdAt (Just parent) name Posix.ReadOnly readFlags) Posix.closeFd $ \held -> do
                    before <- getFdStatus held
                    contents <- readBounded held
                    after <- getFdStatus held
                    named <-
                      bracket (Posix.openFdAt (Just parent) name Posix.ReadOnly readFlags) Posix.closeFd getFdStatus
                    still <- stable
                    pure $
                      if still
                        && safeFile owner created
                        && safeFile owner before
                        && sameVersion created before
                        && sameVersion before after
                        && sameVersion after named
                        && contents == bytes
                        then MutationLaunchIntentRecorded
                        else MutationLaunchIntentIncomplete
      changed <- readIORef touched
      pure $ case outcome of
        Just (Right result) | result /= MutationLaunchIntentRefused -> result
        Just (Left (_ :: IOException)) | changed -> MutationLaunchIntentIncomplete
        Just (Left (_ :: IOException)) -> MutationLaunchIntentRefused
        _ | changed -> MutationLaunchIntentIncomplete
        _ -> MutationLaunchIntentRefused
 where
  safeFile owner status =
    isRegularFile status
      && fileOwner status == owner
      && fileMode status .&. 0o7077 == 0
      && linkCount status == 1
      && fileSize status >= 0
      && fileSize status <= 4096
  sameVersion a b =
    deviceID a == deviceID b
      && fileID a == fileID b
      && fileOwner a == fileOwner b
      && fileMode a == fileMode b
      && linkCount a == linkCount b
      && fileSize a == fileSize b
      && modificationTimeHiRes a == modificationTimeHiRes b
      && statusChangeTimeHiRes a == statusChangeTimeHiRes b
  writeAll file bytes
    | ByteString.null bytes = pure ()
    | otherwise = do
        count <- PosixBytes.fdWrite file bytes
        unless (count > 0) (ioError (userError "short mutation launch intent write"))
        writeAll file (ByteString.drop (fromIntegral count) bytes)
  readBounded file = go [] 0
   where
    go chunks count
      | count > 4096 = pure (ByteString.concat (reverse chunks))
      | otherwise = do
          observed <- try (PosixBytes.fdRead file (fromIntegral (4097 - count)))
          case observed of
            Left failure | isEOFError failure -> pure (ByteString.concat (reverse chunks))
            Left (failure :: IOException) -> ioError failure
            Right chunk | ByteString.null chunk -> pure (ByteString.concat (reverse chunks))
            Right chunk -> go (chunk : chunks) (count + ByteString.length chunk)

data MutationContainerIdObservation
  = MutationContainerIdMissing
  | MutationContainerIdObserved !String
  | MutationContainerIdInvalid
  | MutationContainerIdUnobservable
  deriving (Eq, Show)

-- This observes only the CLI's retained ID file. It neither authenticates
-- the Docker daemon nor proves the named container's existence or retirement.
observeMutationContainerId :: Fd -> String -> String -> IO Bool -> IO MutationContainerIdObservation
observeMutationContainerId parent label stage stable
  | not (validLaunchToken label && validLaunchToken stage) = pure MutationContainerIdUnobservable
  | otherwise = do
      outcome <- timeout 10000000 $ try $ do
        owner <- getEffectiveUserID
        parentStatus <- getFdStatus parent
        ready <- stable
        if not
          ( ready
              && isDirectory parentStatus
              && fileOwner parentStatus == owner
              && fileMode parentStatus .&. 0o7077 == 0
          )
          then pure MutationContainerIdUnobservable
          else do
            opened <- try (Posix.openFdAt (Just parent) name Posix.ReadOnly flags)
            case opened of
              Left failure | isDoesNotExistError failure -> do
                still <- stable
                pure (if still then MutationContainerIdMissing else MutationContainerIdUnobservable)
              Left (_ :: IOException) -> pure MutationContainerIdUnobservable
              Right file -> bracket (pure file) Posix.closeFd $ \held -> do
                before <- getFdStatus held
                sameMount <- mutationWorkspaceSameMount parent held
                if not (safeFile owner before && sameMount)
                  then pure MutationContainerIdUnobservable
                  else do
                    bytes <- readCid held [] 0
                    after <- getFdStatus held
                    named <- bracket (Posix.openFdAt (Just parent) name Posix.ReadOnly flags) Posix.closeFd getFdStatus
                    still <- stable
                    pure $
                      if not (still && sameVersion before after && sameVersion after named)
                        then MutationContainerIdUnobservable
                        else maybe MutationContainerIdInvalid MutationContainerIdObserved (parseId bytes)
      pure $ case outcome of
        Just (Right value) -> value
        Just (Left (_ :: IOException)) -> MutationContainerIdUnobservable
        _ -> MutationContainerIdUnobservable
 where
  name = mutationLaunchStem label stage ++ ".cid"
  flags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}
  safeFile owner status =
    isRegularFile status
      && fileOwner status == owner
      && fileMode status .&. 0o7022 == 0
      && linkCount status == 1
      && fileSize status >= 0
      && fileSize status <= 65
  sameVersion a b =
    deviceID a == deviceID b
      && fileID a == fileID b
      && fileOwner a == fileOwner b
      && fileMode a == fileMode b
      && linkCount a == linkCount b
      && fileSize a == fileSize b
      && modificationTimeHiRes a == modificationTimeHiRes b
      && statusChangeTimeHiRes a == statusChangeTimeHiRes b
  parseId bytes =
    let text = ByteString8.unpack bytes
        value = if length text == 65 && drop 64 text == "\n" then take 64 text else text
     in if validContainerId value then Just value else Nothing
  readCid file chunks count
    | count > 65 = pure (ByteString.concat (reverse chunks))
    | otherwise = do
        observed <- try (PosixBytes.fdRead file (fromIntegral (66 - count)))
        case observed of
          Left failure | isEOFError failure -> pure (ByteString.concat (reverse chunks))
          Left (failure :: IOException) -> ioError failure
          Right chunk | ByteString.null chunk -> pure (ByteString.concat (reverse chunks))
          Right chunk -> readCid file (chunk : chunks) (count + ByteString.length chunk)

data MutationContainerReceiptWrite
  = MutationContainerReceiptRecorded
  | MutationContainerReceiptExists
  | MutationContainerReceiptRefused
  | MutationContainerReceiptIncomplete
  deriving (Eq, Show)

data MutationContainerReceiptObservation
  = MutationContainerReceiptMissing
  | MutationContainerReceiptObserved !String
  | MutationContainerReceiptConflict
  | MutationContainerReceiptUnobservable
  deriving (Eq, Show)

data PrivateRecordObservation
  = PrivateRecordMissing
  | PrivateRecordBytes !ByteString.ByteString
  | PrivateRecordUnobservable
  deriving (Eq)

privateRecordLimit, caseReceiptLimit :: Int
privateRecordLimit = 4096
caseReceiptLimit = 16 * 1024

-- Read one small local record using a held parent, rejecting replacement,
-- unsafe permissions, hard links and changes during the bounded read.
readPrivateMutationRecord :: Fd -> FilePath -> IO Bool -> IO PrivateRecordObservation
readPrivateMutationRecord = readPrivateMutationRecordWithin privateRecordLimit

readPrivateMutationRecordWithin :: Int -> Fd -> FilePath -> IO Bool -> IO PrivateRecordObservation
readPrivateMutationRecordWithin limit parent name stable = do
  outcome <- timeout 10000000 $ try $ do
    owner <- getEffectiveUserID
    parentStatus <- getFdStatus parent
    ready <- stable
    if not
      ( ready
          && isDirectory parentStatus
          && fileOwner parentStatus == owner
          && fileMode parentStatus .&. 0o7077 == 0
      )
      then pure PrivateRecordUnobservable
      else do
        opened <- try (Posix.openFdAt (Just parent) name Posix.ReadOnly flags)
        case opened of
          Left failure | isDoesNotExistError failure -> do
            still <- stable
            pure (if still then PrivateRecordMissing else PrivateRecordUnobservable)
          Left (_ :: IOException) -> pure PrivateRecordUnobservable
          Right file -> bracket (pure file) Posix.closeFd $ \held -> do
            before <- getFdStatus held
            sameMount <- mutationWorkspaceSameMount parent held
            if not (safeFile owner before && sameMount)
              then pure PrivateRecordUnobservable
              else do
                bytes <- readBytes held [] 0
                after <- getFdStatus held
                named <- bracket (Posix.openFdAt (Just parent) name Posix.ReadOnly flags) Posix.closeFd getFdStatus
                still <- stable
                pure $
                  if still && sameVersion before after && sameVersion after named && ByteString.length bytes <= limit
                    then PrivateRecordBytes bytes
                    else PrivateRecordUnobservable
  pure $ case outcome of
    Just (Right value) -> value
    Just (Left (_ :: IOException)) -> PrivateRecordUnobservable
    _ -> PrivateRecordUnobservable
 where
  flags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}
  safeFile owner status =
    isRegularFile status
      && fileOwner status == owner
      && fileMode status .&. 0o7077 == 0
      && linkCount status == 1
      && fileSize status >= 0
      && fileSize status <= fromIntegral limit
  sameVersion a b =
    deviceID a == deviceID b
      && fileID a == fileID b
      && fileOwner a == fileOwner b
      && fileMode a == fileMode b
      && linkCount a == linkCount b
      && fileSize a == fileSize b
      && modificationTimeHiRes a == modificationTimeHiRes b
      && statusChangeTimeHiRes a == statusChangeTimeHiRes b
  readBytes file chunks count
    | count > limit = pure (ByteString.concat (reverse chunks))
    | otherwise = do
        observed <- try (PosixBytes.fdRead file (fromIntegral (limit + 1 - count)))
        case observed of
          Left failure | isEOFError failure -> pure (ByteString.concat (reverse chunks))
          Left (failure :: IOException) -> ioError failure
          Right chunk | ByteString.null chunk -> pure (ByteString.concat (reverse chunks))
          Right chunk -> readBytes file (chunk : chunks) (count + ByteString.length chunk)

receiptBytes :: Aeson.Value -> String -> ByteString.ByteString
receiptBytes intent identifier =
  LazyByteString.toStrict $
    Aeson.encode $
      Aeson.object
        [ "schema_version" Aeson..= (1 :: Int)
        , "kind" Aeson..= ("mutation-container-id-observed" :: String)
        , "launch" Aeson..= intent
        , "container_id" Aeson..= identifier
        ]

data RetainedMutationLaunch
  = RetainedMutationLaunchMissing
  | RetainedMutationLaunchObserved !String !Int !String !FilePath !Aeson.Value
  | RetainedMutationLaunchConflict
  | RetainedMutationLaunchUnobservable
  deriving (Eq, Show)

-- Read the original non-secret binding rather than reconstructing it from the
-- currently installed command. A self-consistent record is not authentication
-- of historical source, a daemon, a worker, or a cleanup disposition.
observeRetainedMutationLaunch
  :: Fd -> Fd -> Fd -> String -> String -> IO Bool -> IO RetainedMutationLaunch
observeRetainedMutationLaunch parent source output label stage stable
  | not (validLaunchInput label stage "x" 1) = pure RetainedMutationLaunchUnobservable
  | otherwise = do
      outcome <- timeout 10000000 $ try $ do
        before <- stable
        owner <- getEffectiveUserID
        parentStatus <- getFdStatus parent
        sourceStatus <- getFdStatus source
        outputStatus <- getFdStatus output
        sourceMount <- mutationWorkspaceSameMount parent source
        outputMount <- mutationWorkspaceSameMount parent output
        let safeDirectory status = isDirectory status && fileOwner status == owner && fileMode status .&. 0o7077 == 0
            distinct = deviceID sourceStatus /= deviceID outputStatus || fileID sourceStatus /= fileID outputStatus
            scopeSafe =
              all safeDirectory [parentStatus, sourceStatus, outputStatus]
                && sourceMount
                && outputMount
                && distinct
        recorded <- readPrivateMutationRecord parent (mutationLaunchStem label stage ++ ".json") stable
        after <- stable
        pure $ case (before && scopeSafe, after, recorded) of
          (True, True, PrivateRecordMissing) -> RetainedMutationLaunchMissing
          (True, True, PrivateRecordBytes bytes) -> case Aeson.eitherDecodeStrict' bytes of
            Right value -> case parseEither parseFields value of
              Right (digest, seconds, image, socket)
                | validContainerId digest
                    && validLaunchInput label stage "x" seconds
                    && maybe False validContainerId (stripPrefix "sha256:" image)
                    && isAbsolute socket
                    && normalise socket == socket
                    && length socket <= 4096
                    && all (\c -> c >= ' ' && c /= '\DEL') socket ->
                    let expected =
                          retainedLaunchIntentValue
                            label
                            stage
                            digest
                            seconds
                            image
                            socket
                            parentStatus
                            sourceStatus
                            outputStatus
                     in if bytes == LazyByteString.toStrict (Aeson.encode expected)
                          then RetainedMutationLaunchObserved digest seconds image socket expected
                          else RetainedMutationLaunchConflict
              _ -> RetainedMutationLaunchConflict
            Left _ -> RetainedMutationLaunchConflict
          _ -> RetainedMutationLaunchUnobservable
      pure $ case outcome of
        Just (Right value) -> value
        Just (Left (_ :: IOException)) -> RetainedMutationLaunchUnobservable
        _ -> RetainedMutationLaunchUnobservable
 where
  parseFields = Aeson.withObject "mutation launch" $ \value ->
    (,,,)
      <$> value .: "command_sha256"
      <*> value .: "timeout_seconds"
      <*> value .: "image"
      <*> value .: "socket"

observeReceiptForRetainedLaunch
  :: Fd -> String -> String -> Aeson.Value -> IO Bool -> IO MutationContainerReceiptObservation
observeReceiptForRetainedLaunch parent label stage intent stable = do
  observed <-
    readPrivateMutationRecord parent (mutationLaunchStem label stage ++ ".receipt.json") stable
  pure $ case observed of
    PrivateRecordMissing -> MutationContainerReceiptMissing
    PrivateRecordBytes bytes -> case Aeson.eitherDecodeStrict' bytes of
      Right value -> case parseEither (Aeson.withObject "container receipt" (.: "container_id")) value of
        Right identifier
          | validContainerId identifier && bytes == receiptBytes intent identifier ->
              MutationContainerReceiptObserved identifier
        _ -> MutationContainerReceiptConflict
      Left _ -> MutationContainerReceiptConflict
    PrivateRecordUnobservable -> MutationContainerReceiptUnobservable

-- This receipt records an observed ID only. It is not ownership, daemon
-- authentication, an absence observation, or worker-settlement evidence.
observeMutationContainerReceipt
  :: Fd
  -> Fd
  -> Fd
  -> String
  -> String
  -> String
  -> Int
  -> IO Bool
  -> IO MutationContainerReceiptObservation
observeMutationContainerReceipt parent source output label stage command seconds stable
  | not (validLaunchInput label stage command seconds) = pure MutationContainerReceiptUnobservable
  | otherwise = do
      outcome <- timeout 10000000 $ try $ do
        before <- stable
        parentStatus <- getFdStatus parent
        sourceStatus <- getFdStatus source
        outputStatus <- getFdStatus output
        owner <- getEffectiveUserID
        sourceMount <- mutationWorkspaceSameMount parent source
        outputMount <- mutationWorkspaceSameMount parent output
        let intent = launchIntentValue label stage command seconds parentStatus sourceStatus outputStatus
            intentBytes = LazyByteString.toStrict (Aeson.encode intent)
            stem = mutationLaunchStem label stage
            safeDirectory status = isDirectory status && fileOwner status == owner && fileMode status .&. 0o7077 == 0
            distinct = deviceID sourceStatus /= deviceID outputStatus || fileID sourceStatus /= fileID outputStatus
            scopeSafe =
              all safeDirectory [parentStatus, sourceStatus, outputStatus]
                && sourceMount
                && outputMount
                && distinct
        recordedIntent <- readPrivateMutationRecord parent (stem ++ ".json") stable
        recordedReceipt <- readPrivateMutationRecord parent (stem ++ ".receipt.json") stable
        after <- stable
        pure $ case (before && scopeSafe, after, recordedIntent, recordedReceipt) of
          (True, True, PrivateRecordBytes actual, PrivateRecordMissing)
            | actual == intentBytes -> MutationContainerReceiptMissing
          (True, True, PrivateRecordBytes _, PrivateRecordMissing) -> MutationContainerReceiptConflict
          (True, True, PrivateRecordBytes actual, PrivateRecordBytes bytes)
            | actual == intentBytes -> case Aeson.eitherDecodeStrict' bytes of
                Right value -> case parseEither (Aeson.withObject "container receipt" (.: "container_id")) value of
                  Right identifier
                    | validContainerId identifier && bytes == receiptBytes intent identifier ->
                        MutationContainerReceiptObserved identifier
                  _ -> MutationContainerReceiptConflict
                Left _ -> MutationContainerReceiptConflict
          (True, True, PrivateRecordBytes _, PrivateRecordBytes _) -> MutationContainerReceiptConflict
          (True, True, PrivateRecordMissing, _) -> MutationContainerReceiptConflict
          _ -> MutationContainerReceiptUnobservable
      pure $ case outcome of
        Just (Right value) -> value
        Just (Left (_ :: IOException)) -> MutationContainerReceiptUnobservable
        _ -> MutationContainerReceiptUnobservable

recordMutationContainerReceipt
  :: Fd
  -> Fd
  -> Fd
  -> String
  -> String
  -> String
  -> Int
  -> String
  -> IO Bool
  -> IO MutationContainerReceiptWrite
recordMutationContainerReceipt parent source output label stage command seconds identifier stable
  | not (validLaunchInput label stage command seconds && validContainerId identifier) =
      pure MutationContainerReceiptRefused
  | otherwise = do
      touched <- newIORef False
      outcome <- timeout 10000000 $ try $ do
        existing <- observeMutationContainerReceipt parent source output label stage command seconds stable
        cid <- observeMutationContainerId parent label stage stable
        case (existing, cid) of
          (MutationContainerReceiptMissing, MutationContainerIdObserved current) | current == identifier -> mask $ \restore -> do
            parentStatus <- getFdStatus parent
            sourceStatus <- getFdStatus source
            outputStatus <- getFdStatus output
            let intent = launchIntentValue label stage command seconds parentStatus sourceStatus outputStatus
                bytes = receiptBytes intent identifier
                name = mutationLaunchStem label stage ++ ".receipt.json"
                flags =
                  Posix.defaultFileFlags
                    { Posix.nofollow = True
                    , Posix.cloexec = True
                    , Posix.nonBlock = True
                    , Posix.exclusive = True
                    , Posix.creat = Just 0o600
                    }
            ready <- stable
            if not ready
              then pure MutationContainerReceiptRefused
              else do
                opened <- try (Posix.openFdAt (Just parent) name Posix.WriteOnly flags)
                case opened of
                  Left failure | isAlreadyExistsError failure -> pure MutationContainerReceiptExists
                  Left (_ :: IOException) -> pure MutationContainerReceiptRefused
                  Right file -> do
                    writeIORef touched True
                    written <- try $ bracket (pure file) Posix.closeFd $ \held -> restore $ do
                      writeAll held bytes
                      fileSynchronise held
                      fileSynchronise parent
                    case written of
                      Left (_ :: IOException) -> pure MutationContainerReceiptIncomplete
                      Right () -> restore $ do
                        confirmed <- observeMutationContainerReceipt parent source output label stage command seconds stable
                        cidAfter <- observeMutationContainerId parent label stage stable
                        pure $
                          if confirmed == MutationContainerReceiptObserved identifier
                            && cidAfter == MutationContainerIdObserved identifier
                            then MutationContainerReceiptRecorded
                            else MutationContainerReceiptIncomplete
          (MutationContainerReceiptObserved _, _) -> pure MutationContainerReceiptExists
          _ -> pure MutationContainerReceiptRefused
      changed <- readIORef touched
      pure $ case outcome of
        Just (Right value) | value /= MutationContainerReceiptRefused -> value
        Just (Left (_ :: IOException)) | changed -> MutationContainerReceiptIncomplete
        Just (Left (_ :: IOException)) -> MutationContainerReceiptRefused
        _ | changed -> MutationContainerReceiptIncomplete
        _ -> MutationContainerReceiptRefused
 where
  writeAll file bytes
    | ByteString.null bytes = pure ()
    | otherwise = do
        count <- PosixBytes.fdWrite file bytes
        unless (count > 0) (ioError (userError "short mutation container receipt write"))
        writeAll file (ByteString.drop (fromIntegral count) bytes)

data Patch
  = Reviewed ReviewedMutation
  | Calibration String FilePath Text Text

data Case = Case
  { caseName :: String
  , casePatch :: Patch
  , caseTestPath :: Text
  , caseAssertion :: Text
  , caseTestArguments :: [String]
  , caseExpected :: MutationOutcome
  }

catalog :: [Case]
catalog =
  [ Case
      "M01"
      (Reviewed M01OverlappingRoots)
      (reviewedTestPath M01OverlappingRoots)
      (reviewedAssertion M01OverlappingRoots)
      []
      MutationKilled
  , Case
      "M00-future-dependency"
      (Reviewed M00FutureDependency)
      (reviewedTestPath M00FutureDependency)
      (reviewedAssertion M00FutureDependency)
      []
      MutationKilled
  , Case
      "M00-invalid-remover"
      (Reviewed M00InvalidRemover)
      (reviewedTestPath M00InvalidRemover)
      (reviewedAssertion M00InvalidRemover)
      []
      MutationKilled
  , Case
      "M00-missing-evidence"
      (Reviewed M00MissingEvidence)
      (reviewedTestPath M00MissingEvidence)
      (reviewedAssertion M00MissingEvidence)
      []
      MutationKilled
  , Case
      "M00-foreign-evidence"
      (Reviewed M00ForeignEvidence)
      (reviewedTestPath M00ForeignEvidence)
      (reviewedAssertion M00ForeignEvidence)
      []
      MutationKilled
  , Case
      "M00-missing-current-source"
      (Reviewed M00MissingCurrentSource)
      (reviewedTestPath M00MissingCurrentSource)
      (reviewedAssertion M00MissingCurrentSource)
      []
      MutationKilled
  , Case
      "M01-artifact"
      (Reviewed M01ArtifactBytes)
      (reviewedTestPath M01ArtifactBytes)
      (reviewedAssertion M01ArtifactBytes)
      []
      MutationKilled
  , Case
      "M01-unconfirmed-node"
      (Reviewed M01UnconfirmedNode)
      (reviewedTestPath M01UnconfirmedNode)
      (reviewedAssertion M01UnconfirmedNode)
      []
      MutationKilled
  , Case
      "M01-unknown-recreate"
      (Reviewed M01UnknownRecreate)
      (reviewedTestPath M01UnknownRecreate)
      (reviewedAssertion M01UnknownRecreate)
      []
      MutationKilled
  , Case
      "M01-external-family"
      (Reviewed M01ExternalFamily)
      (reviewedTestPath M01ExternalFamily)
      (reviewedAssertion M01ExternalFamily)
      []
      MutationKilled
  , Case
      "M01-failed-removal"
      (Reviewed M01FailedRemoval)
      (reviewedTestPath M01FailedRemoval)
      (reviewedAssertion M01FailedRemoval)
      []
      MutationKilled
  , Case
      "M01-foreign-control"
      (Reviewed M01ForeignControl)
      (reviewedTestPath M01ForeignControl)
      (reviewedAssertion M01ForeignControl)
      []
      MutationKilled
  , Case
      "M01-unbound-receipt"
      (Reviewed M01UnboundReceipt)
      (reviewedTestPath M01UnboundReceipt)
      (reviewedAssertion M01UnboundReceipt)
      []
      MutationKilled
  , Case
      "M01-foreign-controller-receipt"
      (Reviewed M01ForeignControllerReceipt)
      (reviewedTestPath M01ForeignControllerReceipt)
      (reviewedAssertion M01ForeignControllerReceipt)
      []
      MutationKilled
  , Case
      "M01-wrong-controller-node"
      (Reviewed M01WrongControllerNode)
      (reviewedTestPath M01WrongControllerNode)
      (reviewedAssertion M01WrongControllerNode)
      []
      MutationKilled
  , Case
      "M01-foreign-namespace-cleanup"
      (Reviewed M01ForeignNamespaceCleanup)
      (reviewedTestPath M01ForeignNamespaceCleanup)
      (reviewedAssertion M01ForeignNamespaceCleanup)
      []
      MutationKilled
  , Case
      "M01-replaced-namespace"
      (Reviewed M01ReplacedNamespace)
      (reviewedTestPath M01ReplacedNamespace)
      (reviewedAssertion M01ReplacedNamespace)
      []
      MutationKilled
  , Case
      "M01-foreign-scope"
      (Reviewed M01ForeignScope)
      (reviewedTestPath M01ForeignScope)
      (reviewedAssertion M01ForeignScope)
      []
      MutationKilled
  , Case
      "M01-foreign-network"
      (Reviewed M01ForeignNetwork)
      (reviewedTestPath M01ForeignNetwork)
      (reviewedAssertion M01ForeignNetwork)
      []
      MutationKilled
  , Case
      "M01-unowned-pull"
      (Reviewed M01UnownedPull)
      (reviewedTestPath M01UnownedPull)
      (reviewedAssertion M01UnownedPull)
      []
      MutationKilled
  , Case
      "M01-authority-unobservable"
      (Reviewed M01AuthorityUnobservable)
      (reviewedTestPath M01AuthorityUnobservable)
      (reviewedAssertion M01AuthorityUnobservable)
      []
      MutationKilled
  , Case
      "M01-authority-fence"
      (Reviewed M01AuthorityFence)
      (reviewedTestPath M01AuthorityFence)
      (reviewedAssertion M01AuthorityFence)
      []
      MutationKilled
  , Case
      "M01-receipt-only-removal"
      (Reviewed M01ReceiptOnlyRemoval)
      (reviewedTestPath M01ReceiptOnlyRemoval)
      (reviewedAssertion M01ReceiptOnlyRemoval)
      []
      MutationKilled
  , Case
      "M02"
      (Reviewed M02MissingReport)
      (reviewedTestPath M02MissingReport)
      (reviewedAssertion M02MissingReport)
      []
      MutationKilled
  , Case
      "M02-stale-source"
      (Reviewed M02StaleSource)
      (reviewedTestPath M02StaleSource)
      (reviewedAssertion M02StaleSource)
      []
      MutationKilled
  , Case
      "M02-wrong-scope"
      (Reviewed M02WrongScope)
      (reviewedTestPath M02WrongScope)
      (reviewedAssertion M02WrongScope)
      []
      MutationKilled
  , Case
      "M02-fabricated-success"
      (Reviewed M02FabricatedSuccess)
      (reviewedTestPath M02FabricatedSuccess)
      (reviewedAssertion M02FabricatedSuccess)
      []
      MutationKilled
  , Case
      "M03a"
      (Reviewed M03ProductionUnlock)
      (reviewedTestPath M03ProductionUnlock)
      (reviewedAssertion M03ProductionUnlock)
      []
      MutationKilled
  , Case
      "M03b"
      (Reviewed M03VaultIncarnation)
      (reviewedTestPath M03VaultIncarnation)
      (reviewedAssertion M03VaultIncarnation)
      []
      MutationKilled
  , Case
      "M03c"
      (Reviewed M03BackupContent)
      (reviewedTestPath M03BackupContent)
      (reviewedAssertion M03BackupContent)
      []
      MutationKilled
  , Case
      "M04a"
      (Reviewed M04UnknownAsFresh)
      (reviewedTestPath M04UnknownAsFresh)
      (reviewedAssertion M04UnknownAsFresh)
      []
      MutationKilled
  , Case
      "M04b"
      (Reviewed M04MissingAsFresh)
      (reviewedTestPath M04MissingAsFresh)
      (reviewedAssertion M04MissingAsFresh)
      []
      MutationKilled
  , Case
      "M05"
      (Reviewed M05PendingNoChange)
      (reviewedTestPath M05PendingNoChange)
      (reviewedAssertion M05PendingNoChange)
      []
      MutationKilled
  , Case
      "M04c"
      (Reviewed M04MirrorGenesisAsFresh)
      (reviewedTestPath M04MirrorGenesisAsFresh)
      (reviewedAssertion M04MirrorGenesisAsFresh)
      []
      MutationKilled
  , Case
      "M04d"
      (Reviewed M04IgnoreMirrorCommitment)
      (reviewedTestPath M04IgnoreMirrorCommitment)
      (reviewedAssertion M04IgnoreMirrorCommitment)
      []
      MutationKilled
  , -- Calibration: a compiled change the designated test cannot see survives.
    Case
      "calibration-survivor"
      ( Calibration
          "report-size-bound"
          "src/Prodbox/Test/ScenarioEvidence.hs"
          "maximumReportBytes = 65536"
          "maximumReportBytes = 65537"
      )
      (reviewedTestPath M02MissingReport)
      (reviewedAssertion M02MissingReport)
      []
      MutationSurvived
  , -- Calibration: a source that does not compile is invalid, not a kill.
    Case
      "calibration-invalid"
      ( Calibration
          "syntax-error"
          "src/Prodbox/Test/ScenarioEvidence.hs"
          "maximumReportBytes = 65536"
          "maximumReportBytes = = 65536"
      )
      (reviewedTestPath M02MissingReport)
      (reviewedAssertion M02MissingReport)
      []
      MutationInvalid
  , -- Calibration: Tasty reports an expired test deadline for a zero timeout.
    Case
      "calibration-timeout"
      ( Calibration
          "report-size-bound"
          "src/Prodbox/Test/ScenarioEvidence.hs"
          "maximumReportBytes = 65536"
          "maximumReportBytes = 65537"
      )
      (reviewedTestPath M02MissingReport)
      (reviewedAssertion M02MissingReport)
      ["--timeout", "0ms"]
      MutationInconclusive
  ]

-- Later-phase declarations remain readable for existing campaign records.
-- Phase 1 runs its own mutations and all executor calibrations.
phaseOneCatalog :: [Case]
phaseOneCatalog = filter phaseOneCase catalog
 where
  phaseOneCase mutationCase = case casePatch mutationCase of
    Calibration {} -> True
    Reviewed mutation ->
      mutation
        `elem` [ M01OverlappingRoots
               , M00FutureDependency
               , M00InvalidRemover
               , M00MissingEvidence
               , M00ForeignEvidence
               , M00MissingCurrentSource
               , M01ArtifactBytes
               , M01UnconfirmedNode
               , M01UnknownRecreate
               , M01ExternalFamily
               , M01FailedRemoval
               , M01ForeignControl
               , M01UnboundReceipt
               , M01ForeignControllerReceipt
               , M01WrongControllerNode
               , M01ForeignNamespaceCleanup
               , M01ReplacedNamespace
               , M01ForeignScope
               , M01ForeignNetwork
               , M01UnownedPull
               , M01AuthorityUnobservable
               , M01AuthorityFence
               , M01ReceiptOnlyRemoval
               , M02MissingReport
               , M02StaleSource
               , M02WrongScope
               , M02FabricatedSuccess
               ]

phaseTwoCatalog :: [Case]
phaseTwoCatalog = filter phaseTwoCase catalog
 where
  phaseTwoCase mutationCase = case casePatch mutationCase of
    Calibration {} -> False
    Reviewed mutation -> mutation `elem` [M03ProductionUnlock, M03VaultIncarnation, M03BackupContent]

phaseThreeCatalog :: [Case]
phaseThreeCatalog = filter phaseThreeCase catalog
 where
  phaseThreeCase mutationCase = case casePatch mutationCase of
    Calibration {} -> False
    Reviewed mutation ->
      mutation
        `elem` [ M04UnknownAsFresh
               , M04MissingAsFresh
               , M04MirrorGenesisAsFresh
               , M04IgnoreMirrorCommitment
               , M05PendingNoChange
               ]

runnableCatalog :: [Case]
runnableCatalog = phaseOneCatalog ++ phaseTwoCatalog ++ phaseThreeCatalog

limits :: Int -> BoundedSubprocessLimits
limits seconds = BoundedSubprocessLimits 1 (1024 * 1024) (256 * 1024) (seconds * 1000000)

run
  :: Int -> FilePath -> [String] -> IO (Maybe (ExitCode, ByteString.ByteString, ByteString.ByteString))
run seconds program arguments = do
  result <-
    captureSubprocessWithInputBounded
      (limits seconds)
      ByteString.empty
      ( Subprocess
          program
          arguments
          (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent"), ("DOCKER_CONFIG", "/nonexistent")])
          Nothing
      )
  pure $ case result of
    Right output ->
      Just
        ( processExitCode output
        , ByteString8.pack (processStdout output)
        , ByteString8.pack (processStderr output)
        )
    Left _ -> Nothing

digestOf :: ByteString.ByteString -> PublicEvidenceDigest
digestOf = hashPublicEvidence . TextEncoding.decodeUtf8With (\_ _ -> Just '?') . hexSha256

data MutationLaunchInvocation a
  = MutationLaunchDenied !MutationLaunchIntentResult
  | MutationLaunchBindingUnstable
  | MutationLaunchReturned !a
  deriving (Eq, Show)

withRecordedMutationLaunch
  :: Fd
  -> Fd
  -> Fd
  -> String
  -> String
  -> String
  -> Int
  -> IO Bool
  -> IO a
  -> IO (MutationLaunchInvocation a)
withRecordedMutationLaunch parent source output label stage command seconds stable action = do
  intent <- recordMutationLaunchIntent parent source output label stage command seconds stable
  case intent of
    MutationLaunchIntentRecorded -> do
      ready <- stable
      cid <-
        if ready
          then observeMutationContainerId parent label stage stable
          else pure MutationContainerIdUnobservable
      if ready && cid == MutationContainerIdMissing
        then MutationLaunchReturned <$> action
        else pure MutationLaunchBindingUnstable
    other -> pure (MutationLaunchDenied other)

-- | Run one command using the campaign's privately prepared dependencies.
inContainer
  :: Fd
  -> IO Bool
  -> PreparedMutationDependencies
  -> MutationDisk
  -> IORef [MutationInvocationDiagnostic]
  -> String
  -> Maybe Text
  -> Int
  -> FilePath
  -> FilePath
  -> String
  -> String
  -> IO (Maybe (ExitCode, ByteString.ByteString, ByteString.ByteString))
inContainer campaignFd campaignStable dependencies disk diagnostics stage assertion seconds workspace output label command = do
  home <- getHomeDirectory
  uid <- getEffectiveUserID
  gid <- getEffectiveGroupID
  daemon <- observeDockerDaemon mutationDockerSocket
  case daemon of
    DockerDaemonObserved {} | validMutationMounts home workspace output -> do
      let held = (&&) <$> campaignStable <*> mutationDiskStable disk
      binding <- withCampaignMutationDirectories campaignFd held workspace output $ \parent source destination stable -> do
        withRecordedMutationLaunch parent source destination label stage command seconds stable $
          do
            let cidFile = takeDirectory workspace </> (mutationLaunchStem label stage ++ ".cid")
            result <-
              run
                seconds
                "/usr/bin/docker"
                ( mutationContainerArguments
                    dependencies
                    (mutationDiskName disk)
                    home
                    (show uid ++ ":" ++ show gid)
                    workspace
                    output
                    cidFile
                    label
                    command
                )
            containerId <- observeMutationContainerId parent label stage stable
            receipt <- case containerId of
              MutationContainerIdObserved identifier ->
                Just
                  <$> recordMutationContainerReceipt
                    parent
                    source
                    destination
                    label
                    stage
                    command
                    seconds
                    identifier
                    stable
              _ -> pure Nothing
            retired <- case (result, containerId, receipt) of
              (Just _, MutationContainerIdObserved identifier, Just MutationContainerReceiptRecorded) ->
                observeRetiredMutationContainer daemon identifier stable
              _ -> pure False
            pure (result, containerId, receipt, retired)
      case binding of
        MutationBindingsStable (MutationLaunchReturned (result, containerId, receipt, retired)) -> do
          when retired $
            modifyIORef' diagnostics (++ [MutationRetirementObserved stage])
          modifyIORef' diagnostics (++ [MutationInvocationContainerId stage containerId])
          modifyIORef' diagnostics (++ [MutationInvocationContainerReceipt stage receipt])
          case result of
            Just (code@(ExitFailure _), out, err) ->
              modifyIORef'
                diagnostics
                ( ++
                    [ MutationInvocationExited
                        stage
                        code
                        ((\expected -> decodeSingleMutationTest expected code out err) <$> assertion)
                        (ByteString.length out)
                        (ByteString.length err)
                    ]
                )
            Nothing -> modifyIORef' diagnostics (++ [MutationInvocationUnobservable stage])
            _ -> pure ()
          pure $ case (containerId, receipt) of
            (MutationContainerIdObserved _, Just MutationContainerReceiptRecorded) -> result
            _ -> Nothing
        MutationBindingsChanged (MutationLaunchReturned (result, containerId, receipt, _)) -> do
          modifyIORef' diagnostics (++ [MutationInvocationContainerId stage containerId])
          modifyIORef' diagnostics (++ [MutationInvocationContainerReceipt stage receipt])
          modifyIORef' diagnostics (++ [changedInvocationDiagnostic stage assertion result])
          pure Nothing
        MutationBindingsStable (MutationLaunchDenied reason) -> do
          modifyIORef' diagnostics (++ [MutationInvocationIntent stage reason])
          pure Nothing
        MutationBindingsChanged (MutationLaunchDenied reason) -> do
          modifyIORef'
            diagnostics
            (++ [MutationInvocationIntent stage reason, MutationInvocationUnobservable stage])
          pure Nothing
        MutationBindingsStable MutationLaunchBindingUnstable -> do
          modifyIORef' diagnostics (++ [MutationInvocationUnobservable stage])
          pure Nothing
        MutationBindingsChanged MutationLaunchBindingUnstable -> do
          modifyIORef' diagnostics (++ [MutationInvocationUnobservable stage])
          pure Nothing
        MutationBindingsRefused -> do
          modifyIORef' diagnostics (++ [MutationInvocationRefused stage])
          pure Nothing
        MutationBindingsUnconfirmed -> do
          modifyIORef' diagnostics (++ [MutationInvocationUnobservable stage])
          pure Nothing
    _ -> do
      modifyIORef' diagnostics (++ [MutationInvocationRefused stage])
      pure Nothing

mutationDockerSocket :: FilePath
mutationDockerSocket = "/run/docker.sock"

mutationKeeperCommand :: String
mutationKeeperCommand = "/usr/bin/sleep 9600"

launchMutationKeeper
  :: Fd -> IO Bool -> FilePath -> FilePath -> String -> String -> String -> IO (Maybe String)
launchMutationKeeper campaign stable workspace output label user volume = do
  let stage = "disk-keeper"
      seconds = 120
      cidFile = takeDirectory workspace </> (mutationLaunchStem label stage ++ ".cid")
  launched <- withCampaignMutationDirectories campaign stable workspace output $ \parent source destination held ->
    withRecordedMutationLaunch parent source destination label stage mutationKeeperCommand seconds held $ do
      started <-
        run
          seconds
          "/usr/bin/docker"
          [ "--host"
          , "unix://" ++ mutationDockerSocket
          , "run"
          , "--detach"
          , "--rm"
          , "--pull=never"
          , "--cidfile"
          , cidFile
          , "--network"
          , "none"
          , "--read-only"
          , "--user"
          , user
          , "--memory"
          , "64m"
          , "--memory-swap"
          , "64m"
          , "--pids-limit"
          , "32"
          , "--log-driver"
          , "none"
          , "--mount"
          , "type=volume,source=" ++ volume ++ ",target=/quota,readonly,volume-nocopy"
          , "--entrypoint"
          , "/usr/bin/sleep"
          , containerImage
          , "9600"
          ]
      observed <- observeMutationContainerId parent label stage held
      case observed of
        MutationContainerIdObserved identifier -> do
          stored <-
            recordMutationContainerReceipt
              parent
              source
              destination
              label
              stage
              mutationKeeperCommand
              seconds
              identifier
              held
          pure $ case started of
            Just (ExitSuccess, bytes, _)
              | ByteString8.lines bytes == [ByteString8.pack identifier]
                  && stored == MutationContainerReceiptRecorded ->
                  Just identifier
            _ -> Nothing
        _ -> pure Nothing
  pure $ case launched of
    MutationBindingsStable (MutationLaunchReturned keeper) -> keeper
    _ -> Nothing

-- Only a finished child with a durably recorded full container ID reaches
-- this observer. Compare the connected daemon with the pre-launch identity
-- and require an independently framed Docker not-found response for that ID.
observeRetiredMutationContainer :: DockerDaemonObservation -> String -> IO Bool -> IO Bool
observeRetiredMutationContainer daemon identifier stable = do
  observed <- withConnectedDockerInfo 15000000 mutationDockerSocket $ \session (DockerConnectedInfo current (DockerPeer _ _ _ peer)) peerStable -> do
    before <- stable
    if before && DockerDaemonObserved current peer == daemon
      then waitForRemoval session peerStable (40 :: Int)
      else pure False
  pure (observed == DockerPeerCompleted (DockerConnectedInfoCompleted True))
 where
  waitForRemoval session peerStable remaining = do
    absent <- readDockerSessionContainerNotFound session identifier
    held <- (&&) <$> stable <*> peerStable
    if not held || absent || remaining <= 0
      then pure (absent && held)
      else threadDelay 100000 >> waitForRemoval session peerStable (remaining - 1)

-- Preserve non-secret primary outcome information when a post-run binding
-- check fails. Arbitrary subprocess text is never copied into diagnostics.
data MutationInvocationDiagnostic
  = MutationInvocationRefused !String
  | MutationInvocationIntent !String !MutationLaunchIntentResult
  | MutationInvocationUnobservable !String
  | MutationInvocationExited !String !ExitCode !(Maybe MutationTest) !Int !Int
  | MutationInvocationChanged !String !(Maybe ExitCode) !(Maybe MutationTest) !Int !Int
  | MutationInvocationContainerId !String !MutationContainerIdObservation
  | MutationInvocationContainerReceipt !String !(Maybe MutationContainerReceiptWrite)
  | MutationInventoryUnobservable !String
  | MutationInventoryFailed !String !ExitCode
  | MutationInventoryNonempty !String !Int
  | MutationRetirementUnconfirmed !String
  | MutationRetirementObserved !String
  deriving (Eq, Show)

changedInvocationDiagnostic
  :: String
  -> Maybe Text
  -> Maybe (ExitCode, ByteString.ByteString, ByteString.ByteString)
  -> MutationInvocationDiagnostic
changedInvocationDiagnostic stage assertion observed = case observed of
  Nothing -> MutationInvocationChanged stage Nothing Nothing 0 0
  Just (code, out, err) ->
    MutationInvocationChanged
      stage
      (Just code)
      ((\expected -> decodeSingleMutationTest expected code out err) <$> assertion)
      (ByteString.length out)
      (ByteString.length err)

-- A label inventory is useful diagnostic evidence only. Even a successful
-- empty result cannot establish that the recorded worker has retired.
mutationInventoryDiagnostic
  :: String
  -> Maybe (ExitCode, ByteString.ByteString, ByteString.ByteString)
  -> MutationInvocationDiagnostic
mutationInventoryDiagnostic stage listing = case listing of
  Just (ExitSuccess, out, _) -> case words (ByteString8.unpack out) of
    [] -> MutationRetirementUnconfirmed stage
    identifiers -> MutationInventoryNonempty stage (length identifiers)
  Just (code, _, _) -> MutationInventoryFailed stage code
  Nothing -> MutationInventoryUnobservable stage

-- These checks reject ambiguous Docker bind syntax and obvious lexical
-- overlap. They do not prove filesystem identity or exclude mount aliases.
validMutationMounts :: FilePath -> FilePath -> FilePath -> Bool
validMutationMounts home workspace output =
  all valid [home, workspace, output]
    && disjoint workspace output
    && disjoint workspace (home </> ".ghcup")
    && disjoint output (home </> ".ghcup")
    && all (disjoint workspace) reserved
    && all (disjoint output) reserved
 where
  reserved = ["/usr", "/lib", "/lib64", "/etc/alternatives"]
  valid path = isAbsolute path && normalise path == path && all (\c -> c /= ':' && c >= ' ' && c /= '\DEL') path
  disjoint a b = not (within a b || within b a)
  within a b = a == "/" || a == b || (a ++ "/") `isPrefixOf` b

data MutationBindingObservation a
  = MutationBindingsRefused
  | MutationBindingsUnconfirmed
  | MutationBindingsStable !a
  | MutationBindingsChanged !a
  deriving (Eq, Show)

-- Hold both roots and their parent while the caller runs. Reopening each name
-- after the callback catches replacement but is not an atomic Docker bind or a
-- proof that no other writer or mount alias existed during the callback.
withBoundMutationDirectories :: FilePath -> FilePath -> IO a -> IO (MutationBindingObservation a)
withBoundMutationDirectories workspace output action =
  withBoundMutationDirectoryHandles workspace output (\_ _ _ _ -> action)

withBoundMutationDirectoryHandles
  :: FilePath -> FilePath -> (Fd -> Fd -> Fd -> IO Bool -> IO a) -> IO (MutationBindingObservation a)
withBoundMutationDirectoryHandles workspace output action
  | not (isAbsolute workspace && isAbsolute output)
      || normalise workspace /= workspace
      || normalise output /= output
      || takeDirectory workspace /= takeDirectory output
      || workspace == output =
      pure MutationBindingsRefused
  | otherwise = do
      returned <- newIORef Nothing
      started <- newIORef False
      attempted <- try $ bracket (Posix.openFd parentPath Posix.ReadOnly flags) Posix.closeFd $ \parent ->
        bracket (openChild parent (takeFileName workspace)) Posix.closeFd $ \source ->
          bracket (openChild parent (takeFileName output)) Posix.closeFd $ \destination -> do
            owner <- getEffectiveUserID
            parentStatus <- getFdStatus parent
            sourceStatus <- getFdStatus source
            outputStatus <- getFdStatus destination
            let ready = do
                  heldParent <- getFdStatus parent
                  heldSource <- getFdStatus source
                  heldOutput <- getFdStatus destination
                  namedParent <- bracket (Posix.openFd parentPath Posix.ReadOnly flags) Posix.closeFd getFdStatus
                  namedSource <- bracket (openChild parent (takeFileName workspace)) Posix.closeFd getFdStatus
                  namedOutput <- bracket (openChild parent (takeFileName output)) Posix.closeFd getFdStatus
                  sameSourceMount <- mutationWorkspaceSameMount parent source
                  sameOutputMount <- mutationWorkspaceSameMount parent destination
                  pure $
                    all (safeDirectory owner) [heldParent, heldSource, heldOutput]
                      && sameIdentity parentStatus heldParent
                      && sameIdentity heldParent namedParent
                      && sameIdentity sourceStatus heldSource
                      && sameIdentity heldSource namedSource
                      && sameIdentity outputStatus heldOutput
                      && sameIdentity heldOutput namedOutput
                      && not (sameIdentity heldSource heldOutput)
                      && sameSourceMount
                      && sameOutputMount
            before <- ready
            if not before
              then pure MutationBindingsRefused
              else mask $ \restore -> do
                writeIORef started True
                result <- restore (action parent source destination ready)
                writeIORef returned (Just result)
                after <- restore ready
                pure (if after then MutationBindingsStable result else MutationBindingsChanged result)
      case attempted of
        Right result -> pure result
        Left (_ :: IOException) -> do
          result <- readIORef returned
          began <- readIORef started
          pure $ case result of
            Just value -> MutationBindingsChanged value
            Nothing | began -> MutationBindingsUnconfirmed
            Nothing -> MutationBindingsRefused
 where
  parentPath = takeDirectory workspace
  flags = Posix.defaultFileFlags {Posix.directory = True, Posix.nofollow = True, Posix.cloexec = True}
  openChild parent name = Posix.openFdAt (Just parent) name Posix.ReadOnly flags
  safeDirectory owner status = isDirectory status && fileOwner status == owner && fileMode status .&. 0o7077 == 0
  sameIdentity :: FileStatus -> FileStatus -> Bool
  sameIdentity a b = deviceID a == deviceID b && fileID a == fileID b

-- Bind a launch's independently opened parent to the original held campaign.
-- A change after the callback preserves its result but prevents a stable claim.
-- This is not an atomic Docker mount or exclusion of external writers.
withCampaignMutationDirectories
  :: Fd
  -> IO Bool
  -> FilePath
  -> FilePath
  -> (Fd -> Fd -> Fd -> IO Bool -> IO a)
  -> IO (MutationBindingObservation a)
withCampaignMutationDirectories campaign campaignStable workspace output action = do
  observed <- withBoundMutationDirectoryHandles workspace output $ \parent source destination rootsStable -> do
    let stable = do
          campaignOkay <- campaignStable
          rootsOkay <- rootsStable
          campaignStatus <- getFdStatus campaign
          parentStatus <- getFdStatus parent
          pure
            ( campaignOkay
                && rootsOkay
                && deviceID campaignStatus == deviceID parentStatus
                && fileID campaignStatus == fileID parentStatus
            )
    before <- stable
    if not before
      then pure Nothing
      else do
        value <- action parent source destination stable
        after <- try stable
        pure (Just (value, either (const False) id (after :: Either IOException Bool)))
  pure $ case observed of
    MutationBindingsRefused -> MutationBindingsRefused
    MutationBindingsUnconfirmed -> MutationBindingsUnconfirmed
    MutationBindingsStable Nothing -> MutationBindingsRefused
    MutationBindingsChanged Nothing -> MutationBindingsRefused
    MutationBindingsStable (Just (value, True)) -> MutationBindingsStable value
    MutationBindingsStable (Just (value, False)) -> MutationBindingsChanged value
    MutationBindingsChanged (Just (value, _)) -> MutationBindingsChanged value

-- Source is read-only to the container; output, home and Cabal state are
-- confined to the separate private output root.
mutationContainerArguments
  :: PreparedMutationDependencies
  -> String
  -> FilePath
  -> String
  -> FilePath
  -> FilePath
  -> FilePath
  -> String
  -> String
  -> [String]
mutationContainerArguments dependencies volume home identity workspace output cidFile label command =
  [ "--host"
  , "unix://" ++ mutationDockerSocket
  , "run"
  , "--rm"
  , "--pull=never"
  , "--cidfile"
  , cidFile
  , "--network"
  , "none"
  , "--label"
  , "io.prodbox.mutant=" ++ label
  , "--entrypoint"
  , "/usr/bin/env"
  , "--user"
  , identity
  , "--read-only"
  , "--tmpfs"
  , "/tmp:rw,nosuid,nodev,size=536870912,mode=1777"
  , "--log-driver"
  , "local"
  , "--log-opt"
  , "max-size=8m"
  , "--log-opt"
  , "max-file=2"
  , "--memory"
  , "8g"
  , "--memory-swap"
  , "8g"
  , "--pids-limit"
  , "4096"
  , "--cpus"
  , "4"
  , "-v"
  , "/usr:/usr:ro"
  , "-v"
  , "/lib:/lib:ro"
  , "-v"
  , "/lib64:/lib64:ro"
  , "-v"
  , "/etc/alternatives:/etc/alternatives:ro"
  , "-v"
  , home </> ".ghcup/bin" ++ ":" ++ home </> ".ghcup/bin" ++ ":ro"
  , "-v"
  , home </> ".ghcup/ghc/9.12.4" ++ ":" ++ home </> ".ghcup/ghc/9.12.4" ++ ":ro"
  , "-v"
  , workspace ++ ":" ++ workspace ++ ":ro"
  , "--mount"
  , "type=volume,source=" ++ volume ++ ",target=" ++ output ++ ",volume-nocopy"
  , "-v"
  , dependencyHostStorePath dependencies ++ ":" ++ dependencyContainerStorePath dependencies ++ ":ro"
  , "-v"
  , let packages = dependencyRootPath dependencies </> "packages"
     in packages ++ ":" ++ packages ++ ":ro"
  , "-v"
  , let config = dependencyConfigPath dependencies in config ++ ":" ++ config ++ ":ro"
  , "-w"
  , workspace
  , containerImage
  , "-i"
  , "HOME=" ++ output </> ".isolated-home"
  , "CABAL_DIR=" ++ output </> ".isolated-cabal"
  , "CABAL_CONFIG=" ++ dependencyConfigPath dependencies
  , "MUTATION_OUTPUT=" ++ output
  , "PATH=" ++ home </> ".ghcup" </> "bin" ++ ":/usr/bin:/bin"
  , "/usr/bin/sh"
  , "-c"
  , "umask 077; " ++ command
  ]

buildCommand :: String
buildCommand =
  "mkdir -p -m 700 \"$MUTATION_OUTPUT/compiler-tmp\" && TMPDIR=\"$MUTATION_OUTPUT/compiler-tmp\" "
    ++ "cabal build --offline --builddir=\"$MUTATION_OUTPUT/build\" test:prodbox-unit --enable-tests --ghc-options=-Werror > \"$MUTATION_OUTPUT/build.log\" 2>&1; "
    ++ "status=$?; tail -5 \"$MUTATION_OUTPUT/build.log\"; exit $status"

mutationIsolationCommand :: String
mutationIsolationCommand =
  "echo \"net=$(cat /proc/net/dev | tail -n +3 | cut -d: -f1 | tr -d ' ' | tr '\\n' ',')\"; test -e /var/run/docker.sock && echo SOCKET; test -e /run/docker.sock && echo SOCKET; ls /home 2>/dev/null | tr '\\n' ',' ; ls /root 2>&1 | head -1; test -e test-secrets.dhall && echo SECRETS; echo probe-done"

mutationSelection :: Case -> String
mutationSelection mutationCase = "$0 == \"" ++ Text.unpack (caseTestPath mutationCase) ++ "\""

mutationSelectionCommand :: String -> String
mutationSelectionCommand selection =
  "\"$MUTATION_OUTPUT/build/build/x86_64-linux/ghc-9.12.4/prodbox-0.1.0/t/prodbox-unit/build/prodbox-unit/prodbox-unit\" --list-tests -p '"
    ++ selection
    ++ "'"

mutationTestCommand :: String -> Text -> [String] -> String
mutationTestCommand selection assertion extra =
  "\"$MUTATION_OUTPUT/build/build/x86_64-linux/ghc-9.12.4/prodbox-0.1.0/t/prodbox-unit/build/prodbox-unit/prodbox-unit\" --mutation-assertion "
    ++ Text.unpack assertion
    ++ " "
    ++ unwords extra
    ++ " -p '"
    ++ selection
    ++ "'"

mutationStageSpecs :: Case -> [(String, String, Int)]
mutationStageSpecs mutationCase =
  [ ("disk-keeper", mutationKeeperCommand, 120)
  , ("isolation", mutationIsolationCommand, 120)
  , ("baseline-build", buildCommand, 3600)
  , ("baseline-selection", mutationSelectionCommand selection, 300)
  , ("baseline-test", mutationTestCommand selection assertion [], 600)
  , ("mutant-build", buildCommand, 3600)
  , ("mutant-selection", mutationSelectionCommand selection, 300)
  , ("mutant-test", mutationTestCommand selection assertion (caseTestArguments mutationCase), 600)
  ]
 where
  selection = mutationSelection mutationCase
  assertion = caseAssertion mutationCase

-- Read only the explicitly selected campaign. Retained records are local
-- evidence; this does not inspect Docker or authorize a cleanup operation.
inspectMutationCampaign :: FilePath -> String -> IO (Either String [String])
inspectMutationCampaign project runId =
  withRetainedMutationCampaign 30000000 project runId $ \campaignFd stable -> do
    let root = project </> ".build" </> "mutants" </> runId
    directoryBefore <- getFdStatus campaignFd
    namesResult <- listNames campaignFd
    case namesResult of
      Nothing -> pure (Left "campaign inventory exceeds its bound")
      Just names -> do
        let expected =
              [ (mutationCase, stage, command, seconds, mutationLaunchStem label stage)
              | mutationCase <- catalog
              , let label = "prodbox-mutant-" ++ runId ++ "-" ++ caseName mutationCase
              , (stage, command, seconds) <- mutationStageSpecs mutationCase
              ]
            artifacts = filter (isPrefixOf ".mutation-launch-") names
            expectedNames = [stem ++ suffix | (_, _, _, _, stem) <- expected, suffix <- [".json", ".cid", ".receipt.json"]]
            unknown = filter (`notElem` expectedNames) artifacts
            active =
              [ entry
              | entry@(_, _, _, _, stem) <- expected
              , any (`elem` names) [stem ++ ".json", stem ++ ".cid", stem ++ ".receipt.json"]
              ]
        marker <- readPrivateMutationRecord campaignFd ".mutation-campaign.json" stable
        rootStatus <- getFdStatus campaignFd
        let creation = case marker of
              PrivateRecordBytes bytes ->
                Aeson.eitherDecodeStrict' bytes >>= parseEither (parseCampaignIdentity runId rootStatus)
              _ -> Left "campaign creation record unavailable"
            markerLine = case marker of
              PrivateRecordMissing -> "Campaign creation record missing; prior activity is unknown."
              PrivateRecordUnobservable -> "Campaign creation record unobservable."
              PrivateRecordBytes _ -> case creation of
                Right digest -> "Campaign creation record: source manifest " ++ digest ++ " (local, unauthenticated)."
                Left _ -> "Campaign creation record invalid or bound to another root."
        entries <- traverse (inspectStage root campaignFd stable) active
        outcomes <-
          traverse (inspectCase campaignFd stable rootStatus creation) $
            filter (\item -> mutationCaseRecordName (caseName item) `elem` names) runnableCatalog
        after <- stable
        directoryAfter <- getFdStatus campaignFd
        pure $
          if not after || not (sameDirectoryVersion directoryBefore directoryAfter)
            then Left "campaign identity or inventory changed while reading records"
            else
              Right
                ( markerLine
                    : entries
                    ++ outcomes
                    ++ ["Unrecognized launch records: " ++ show (length unknown) | not (null unknown)]
                )
 where
  inspectCase campaign stable rootStatus creation mutationCase = do
    let name = caseName mutationCase
    record <-
      readPrivateMutationRecordWithin caseReceiptLimit campaign (mutationCaseRecordName name) stable
    pure $ case (record, creation) of
      (PrivateRecordBytes bytes, Right digest) ->
        case decodeCaseReceipt runId rootStatus digest mutationCase bytes of
          Right (outcome, qualified) ->
            name ++ " local case result " ++ outcome ++ ", qualified at execution " ++ show qualified
          Left _ -> name ++ " local case record invalid or bound to another campaign"
      _ -> name ++ " local case record unobservable"
  listNames (Fd raw) = bracket (openDirStream ("/proc/self/fd/" ++ show raw)) closeDirStream (go [] 0)
   where
    go names count stream = do
      name <- readDirStream stream
      if null name
        then pure (Just names)
        else
          if name == "." || name == ".."
            then go names count stream
            else
              if count >= (4096 :: Int)
                then pure Nothing
                else go (name : names) (count + 1) stream
  sameIdentity a b = deviceID a == deviceID b && fileID a == fileID b
  sameDirectoryVersion a b =
    sameIdentity a b
      && modificationTimeHiRes a == modificationTimeHiRes b
      && statusChangeTimeHiRes a == statusChangeTimeHiRes b
  inspectStage root campaignFd campaignStable (mutationCase, stage, command, seconds, _) = do
    let name = caseName mutationCase
        label = "prodbox-mutant-" ++ runId ++ "-" ++ name
        workspace = root </> take 32 (ByteString8.unpack (hexSha256 (ByteString8.pack name)))
        output = workspace ++ "-output"
    result <- withBoundMutationDirectoryHandles workspace output $ \parent source destination rootsStable -> do
      held <- getFdStatus campaignFd
      actual <- getFdStatus parent
      let stable = do
            a <- campaignStable
            b <- rootsStable
            pure (a && b && sameIdentity held actual)
      cid <- observeMutationContainerId parent label stage stable
      launch <- observeRetainedMutationLaunch parent source destination label stage stable
      detail <- case launch of
        RetainedMutationLaunchObserved digest recordedSeconds image socket intent -> do
          receipt <- observeReceiptForRetainedLaunch parent label stage intent stable
          again <- observeRetainedMutationLaunch parent source destination label stage stable
          let currentDigest = ByteString8.unpack (hexSha256 (TextEncoding.encodeUtf8 (Text.pack command)))
              matchesCurrent =
                digest == currentDigest
                  && recordedSeconds == seconds
                  && image == containerImage
                  && socket == mutationDockerSocket
          pure $
            if again == launch
              then
                "receipt " ++ show receipt ++ "; binding matches current implementation " ++ show matchesCurrent
              else "launch record changed while reading receipt"
        other -> pure ("launch " ++ show other ++ "; receipt not validated")
      pure (cid, detail)
    pure $
      name ++ " " ++ stage ++ ": " ++ case result of
        MutationBindingsStable (cid, detail) -> "ID file " ++ show cid ++ "; " ++ detail
        MutationBindingsChanged (cid, detail) -> "bindings changed; unconfirmed ID file " ++ show cid ++ "; " ++ detail
        _ -> "record bindings unobservable or changed"

withRetainedMutationCampaign
  :: Int -> FilePath -> String -> (Fd -> IO Bool -> IO (Either String a)) -> IO (Either String a)
withRetainedMutationCampaign micros project runId action
  | not (isAbsolute project && normalise project == project && validRunId runId) =
      pure (Left "invalid mutation campaign identity")
  | otherwise = do
      observed <- timeout micros $
        try $
          bracket (Posix.openFd project Posix.ReadOnly flags) Posix.closeFd $ \projectFd ->
            bracket (openChild projectFd ".build") Posix.closeFd $ \buildFd ->
              bracket (openChild buildFd "mutants") Posix.closeFd $ \mutantsFd ->
                bracket (openChild mutantsFd runId) Posix.closeFd $ \campaignFd -> do
                  owner <- getEffectiveUserID
                  initial <- traverse getFdStatus [projectFd, buildFd, mutantsFd, campaignFd]
                  let stable = do
                        held <- traverse getFdStatus [projectFd, buildFd, mutantsFd, campaignFd]
                        named <- bracket (Posix.openFd project Posix.ReadOnly flags) Posix.closeFd $ \p ->
                          bracket (openChild p ".build") Posix.closeFd $ \b ->
                            bracket (openChild b "mutants") Posix.closeFd $ \m ->
                              bracket (openChild m runId) Posix.closeFd $ \c -> traverse getFdStatus [p, b, m, c]
                        mounts <-
                          and
                            <$> sequence
                              [ mutationWorkspaceSameMount projectFd buildFd
                              , mutationWorkspaceSameMount buildFd mutantsFd
                              , mutationWorkspaceSameMount mutantsFd campaignFd
                              ]
                        pure
                          ( safeChain owner held
                              && and (zipWith sameIdentity initial held)
                              && and (zipWith sameIdentity held named)
                              && mounts
                          )
                  before <- stable
                  if not before
                    then pure (Left "campaign identity is unobservable")
                    else action campaignFd stable
      pure $ case observed of
        Just (Right result) -> result
        Just (Left (_ :: IOException)) -> Left "campaign records are unavailable"
        _ -> Left "campaign observation timed out"
 where
  flags = Posix.defaultFileFlags {Posix.directory = True, Posix.nofollow = True, Posix.cloexec = True}
  openChild parent name = Posix.openFdAt (Just parent) name Posix.ReadOnly flags
  validRunId value = not (null value) && length value <= 20 && all (\c -> c >= '0' && c <= '9') value
  sameIdentity a b = deviceID a == deviceID b && fileID a == fileID b
  safeChain owner statuses = case statuses of
    [projectStatus, buildStatus, parentStatus, rootStatus] ->
      all
        (\s -> isDirectory s && fileOwner s == owner && fileMode s .&. 0o7022 == 0)
        [projectStatus, buildStatus]
        && all
          (\s -> isDirectory s && fileOwner s == owner && fileMode s .&. 0o7077 == 0)
          [parentStatus, rootStatus]
    _ -> False

decodeCaseReceipt
  :: String -> FileStatus -> String -> Case -> ByteString.ByteString -> Either String (String, Bool)
decodeCaseReceipt runId rootStatus digest mutationCase bytes =
  Aeson.eitherDecodeStrict' bytes
    >>= parseEither (Aeson.withObject "mutation case result" parseFields)
 where
  parseFields fields = do
    version <- fields .: "schema_version"
    kind <- fields .: "kind"
    caseLabel <- fields .: "case"
    campaignRun <- fields .: "run_id"
    rootDevice <- fields .: "root_device"
    rootInode <- fields .: "root_inode"
    manifest <- fields .: "source_manifest"
    plan <- fields .: "dependency_plan"
    content <- fields .: "dependency_content"
    outcome <- fields .: "outcome"
    expected <- fields .: "expected"
    qualified <- fields .: "qualified"
    when (version == (2 :: Int)) $ do
      detail <- fields .: "detail"
      guard (not (null (detail :: String)))
    guard
      ( validVersion (version :: Int)
          && (kind :: String) == "mutation-case-outcome"
          && caseLabel == caseName mutationCase
          && campaignRun == runId
          && rootDevice == show (deviceID rootStatus)
          && rootInode == show (fileID rootStatus)
          && manifest == digest
          && validContainerId plan
          && validContainerId content
          && expected == show (caseExpected mutationCase)
          && outcome == (if qualified then expected else show MutationInconclusive)
      )
    pure (outcome, qualified)
  validVersion 1 = ByteString.length bytes <= privateRecordLimit
  validVersion 2 = ByteString.length bytes <= caseReceiptLimit
  validVersion _ = False

parseCampaignIdentity :: String -> FileStatus -> Aeson.Value -> Parser String
parseCampaignIdentity runId status = Aeson.withObject "campaign identity" $ \object -> do
  version <- object .: "schema_version"
  kind <- object .: "kind"
  recordedRun <- object .: "run_id"
  device <- object .: "root_device"
  inode <- object .: "root_inode"
  digest <- object .: "manifest_sha256"
  headId <- object .: "git_head"
  worktree <- object .: "worktree"
  entries <- object .: "manifest_entries"
  policyId <- object .: "policy_id"
  policyVersion <- object .: "policy_version"
  policyDigest <- object .: "policy_sha256"
  let validHead =
        (length (headId :: String) == 40 || length headId == 64)
          && all (\c -> c >= '0' && c <= '9' || c >= 'a' && c <= 'f') headId
  if (version :: Int) == 1
    && (kind :: String) == "mutation-campaign-created"
    && recordedRun == runId
    && device == show (deviceID status)
    && inode == show (fileID status)
    && validContainerId digest
    && validHead
    && worktree `elem` (["WorktreeClean", "WorktreeDirty"] :: [String])
    && (entries :: Int) > 0
    && not (null (policyId :: String))
    && (policyVersion :: Int) > 0
    && validContainerId policyDigest
    then pure digest
    else fail "invalid campaign identity"

runMutationCampaignStatus :: String -> IO ExitCode
runMutationCampaignStatus runId = do
  project <- getCurrentDirectory
  result <- inspectMutationCampaign project runId
  case result of
    Left failure -> writeOutputLine ("Mutation campaign status unavailable: " ++ failure) >> pure (ExitFailure 2)
    Right entries -> do
      writeOutputLine ("Mutation campaign " ++ runId ++ ": retained local records only.")
      if null entries
        then writeOutputLine "No launch records observed; this does not prove worker absence."
        else mapM_ writeOutputLine entries
      writeOutputLine "Worker settlement, Docker state and workspace cleanup were not observed."
      pure (ExitFailure 1)

runMutationCampaignCleanup :: String -> IO ExitCode
runMutationCampaignCleanup runId = do
  project <- getCurrentDirectory
  result <- withRetainedMutationCampaign 120000000 project runId $ \root stable -> do
    campaign <- getFdStatus root
    creation <- readPrivateMutationRecord root ".mutation-campaign.json" stable
    case decodeRetained creation (parseCampaignIdentity runId campaign) of
      Nothing -> pure (Left "campaign creation record is unavailable or foreign")
      Just source -> do
        daemon <- observeDockerDaemon mutationDockerSocket
        Right <$> traverse (recoverUnusedDisk root stable campaign source daemon) runnableCatalog
  case result of
    Right cases | not (null [name | (name, Just True) <- cases]) && all ((/= Just False) . snd) cases -> do
      mapM_
        (\(name, _) -> writeOutputLine (name ++ ": unused mutation volume absence confirmed."))
        [item | item@(_, Just True) <- cases]
      pure ExitSuccess
    Right cases -> do
      mapM_
        (\(name, _) -> writeOutputLine (name ++ ": retained mutation storage cleanup unconfirmed."))
        [item | item@(_, Just False) <- cases]
      pure (ExitFailure 1)
    Left failure -> writeOutputLine ("Mutation cleanup refused: " ++ failure) >> pure (ExitFailure 2)
 where
  recoverUnusedDisk root stable campaign source daemon mutationCase = do
    let name = caseName mutationCase
        key = take 32 (ByteString8.unpack (hexSha256 (ByteString8.pack name)))
        volumeName = "prodbox-mutdisk-" ++ runId ++ "-" ++ key
        prefix = ".mutation-disk-" ++ key ++ "-"
        label = "prodbox-mutant-" ++ runId ++ "-" ++ name
        local file = readPrivateMutationRecord root file stable
        stageRecords =
          [ mutationLaunchStem label stage ++ suffix
          | (stage, _, _) <- mutationStageSpecs mutationCase
          , suffix <- [".json", ".cid", ".receipt.json"]
          ]
    volume <- mutationDiskVolume volumeName key
    created <- local (prefix ++ "created.json")
    case created of
      PrivateRecordMissing -> pure (name, Nothing)
      _ -> do
        let fields stage = Aeson.withObject "mutation disk binding" $ \object -> do
              version <- object .: "schema_version"
              kind <- object .: "kind"
              caseKey <- object .: "case_key"
              diskName <- object .: "volume"
              observedDaemon <- object .: "daemon"
              device <- object .: "root_device"
              inode <- object .: "root_inode"
              guard
                ( (version :: Int) == 1
                    && kind == "mutation-disk-" ++ stage
                    && caseKey == key
                    && diskName == volumeName
                    && observedDaemon == show daemon
                    && device == show (deviceID campaign)
                    && inode == show (fileID campaign)
                )
              pure object
            timestamp = decodeRetained created $ \value -> do
              object <- fields "created" value
              date <- object .: "created_at"
              guard (not (null date) && length date <= 64)
              pure date
            proven at = do
              stillCreated <- local (prefix ++ "created.json")
              intent <- local (prefix ++ "intent.json")
              final <- readPrivateMutationRecordWithin caseReceiptLimit root (mutationCaseRecordName name) stable
              launches <- traverse local stageRecords
              held <- stable
              let matched = decodeRetained intent $ \value -> do
                    object <- fields "intent" value
                    owner <- object .: "owner"
                    options <- object .: "options"
                    pure (owner == key && options == dockerMutationVolumeOptions volume)
              pure
                ( held
                    && stillCreated == created
                    && timestamp == Just at
                    && matched == Just True
                    && terminalIncomplete final
                    && all (== PrivateRecordMissing) launches
                )
            terminalIncomplete final = case final of
              PrivateRecordBytes bytes ->
                decodeCaseReceipt runId campaign source mutationCase bytes
                  == Right (show MutationInconclusive, False)
              _ -> False
            remember stage at = do
              let file = prefix ++ stage ++ ".json"
                  value =
                    Aeson.object
                      [ "schema_version" Aeson..= (1 :: Int)
                      , "kind" Aeson..= ("mutation-disk-" ++ stage)
                      , "case_key" Aeson..= key
                      , "volume" Aeson..= volumeName
                      , "daemon" Aeson..= show daemon
                      , "root_device" Aeson..= show (deviceID campaign)
                      , "root_inode" Aeson..= show (fileID campaign)
                      , "created_at" Aeson..= at
                      ]
              prior <- local file
              case prior of
                PrivateRecordMissing -> recordPrivateCampaignValue root file (proven at) (pure value)
                _ -> pure (decodeRetained prior pure == Just value)
        cleaned <- case timestamp of
          Nothing -> pure False
          Just at -> do
            admitted <- remember "unused-removal-intent" at
            retired <-
              if admitted
                then retireUnusedMutationDisk mutationDockerSocket daemon volume at (proven at)
                else pure False
            if retired then remember "unused-removed" at else pure False
        pure (name, Just cleaned)

decodeRetained :: PrivateRecordObservation -> (Aeson.Value -> Parser a) -> Maybe a
decodeRetained record parser = case record of
  PrivateRecordBytes bytes -> either (const Nothing) Just (Aeson.eitherDecodeStrict' bytes >>= parseEither parser)
  _ -> Nothing

binaryPath :: FilePath
binaryPath =
  "build/build/x86_64-linux/ghc-9.12.4/prodbox-0.1.0/t/prodbox-unit/build/prodbox-unit/prodbox-unit"

data CaseResult = CaseResult
  { resultName :: String
  , resultOutcome :: MutationOutcome
  , resultExpected :: MutationOutcome
  , resultDetail :: String
  , resultQualified :: Bool
  }

-- | Run a selected catalog. A case passes only when its classified outcome
-- matches the expected one. Other outcomes retain their evidence.
runMutationCatalog :: Maybe String -> IO ExitCode
runMutationCatalog selected = case selected of
  Nothing -> runMutationCases phaseOneCatalog
  Just "phase-02" -> runMutationCases phaseTwoCatalog
  Just "phase-03" -> runMutationCases phaseThreeCatalog
  Just name -> case find ((== name) . caseName) runnableCatalog of
    Just mutationCase -> runMutationCases [mutationCase]
    Nothing -> writeOutputLine "Unknown active mutation case." >> pure (ExitFailure 2)

runMutationCases :: [Case] -> IO ExitCode
runMutationCases requested = do
  repoRoot <- getCurrentDirectory
  present <-
    run
      20
      "/usr/bin/docker"
      [ "--host"
      , "unix://" ++ mutationDockerSocket
      , "image"
      , "inspect"
      , "--format"
      , "{{.Id}}"
      , containerImage
      ]
  sourceResult <- captureMutationSnapshot repoRoot []
  case (present, sourceResult) of
    (Just (ExitSuccess, _, _), Right original) -> do
      stamp <- getMonotonicTimeNSec
      let source = mutationSnapshotSource original
          root = repoRoot </> ".build" </> "mutants" </> show stamp
      result <- withPreparedCampaignRoot root $ \rootFd stable -> do
        writeOutputLine ("Mutation campaign recovery directory: " ++ root)
        hFlush stdout
        recorded <- recordCampaignIdentity rootFd (takeFileName root) source stable
        if not recorded
          then
            writeOutputLine "Campaign identity could not be confirmed; no mutation work was started."
              >> pure (ExitFailure 2)
          else do
            home <- getHomeDirectory
            prepared <- prepareMutationDependencies repoRoot root rootFd stable home
            case prepared of
              Left failure ->
                writeOutputLine ("Mutation dependency preparation incomplete: " ++ failure) >> pure (ExitFailure 2)
              Right dependencies -> do
                writeOutputLine
                  ( "Mutation dependency plan "
                      ++ show (dependencyPlanFingerprint dependencies)
                      ++ ", input content "
                      ++ show (dependencyContentFingerprint dependencies)
                  )
                results <- runCasesUntilIncomplete original rootFd stable root dependencies requested
                let qualified = length results == length requested && all resultQualified results
                writeOutputLine $
                  if qualified
                    then "Mutation campaign completed; retained receipts and prepared inputs: " ++ root
                    else "Mutation campaign incomplete; retained evidence and workspace state: " ++ root
                pure (if qualified then ExitSuccess else ExitFailure 1)
      case result of
        Nothing ->
          writeOutputLine ("Mutation campaign root could not be confirmed; inspect retained path: " ++ root)
            >> pure (ExitFailure 2)
        Just outcome -> pure outcome
    (Just (ExitSuccess, _, _), Left failure) -> writeOutputLine ("source identity refused: " ++ show failure) >> pure (ExitFailure 2)
    _ ->
      writeOutputLine
        "the pinned node image is not present in the selected Docker daemon; import it first"
        >> pure (ExitFailure 2)

-- The private parent may be reused only if it is already owned and private;
-- a pre-existing campaign directory is never adopted or chmodded.
prepareCampaignRoot :: FilePath -> IO Bool
prepareCampaignRoot root = do
  result <- withPreparedCampaignRoot root (\_ stable -> stable)
  pure (result == Just True)

-- Keep the originally created root and its ancestors open across campaign work.
withPreparedCampaignRoot :: forall a. FilePath -> (Fd -> IO Bool -> IO a) -> IO (Maybe a)
withPreparedCampaignRoot root action = do
  let parent = takeDirectory root
      base = takeDirectory parent
      flags = Posix.defaultFileFlags {Posix.directory = True, Posix.nofollow = True, Posix.cloexec = True}
      mkdir (Fd fd) name = withCString name $ \raw -> throwErrnoIfMinus1_ "mkdirat" (makeCampaignDirectoryAt fd raw 0o700)
      sameIdentity a b = deviceID a == deviceID b && fileID a == fileID b
  attempted <- try $ bracket (Posix.openFd base Posix.ReadOnly flags) Posix.closeFd $ \baseFd -> do
    owner <- getEffectiveUserID
    baseStatus <- getFdStatus baseFd
    if not (isDirectory baseStatus && fileOwner baseStatus == owner && fileMode baseStatus .&. 0o022 == 0)
      then pure Nothing
      else do
        created <- try (mkdir baseFd (takeFileName parent))
        case created of
          Right () -> fileSynchronise baseFd
          Left failure | isAlreadyExistsError failure -> pure ()
          Left failure -> ioError failure
        bracket (Posix.openFdAt (Just baseFd) (takeFileName parent) Posix.ReadOnly flags) Posix.closeFd $ \parentFd -> do
          parentStatus <- getFdStatus parentFd
          if not
            (isDirectory parentStatus && fileOwner parentStatus == owner && fileMode parentStatus .&. 0o077 == 0)
            then pure Nothing
            else do
              mkdir parentFd (takeFileName root)
              fileSynchronise parentFd
              bracket (Posix.openFdAt (Just parentFd) (takeFileName root) Posix.ReadOnly flags) Posix.closeFd $ \rootFd -> do
                rootStatus <- getFdStatus rootFd
                let stable = do
                      heldBase <- getFdStatus baseFd
                      heldParent <- getFdStatus parentFd
                      heldRoot <- getFdStatus rootFd
                      currentBase <- bracket (Posix.openFd base Posix.ReadOnly flags) Posix.closeFd getFdStatus
                      namedParent <-
                        bracket
                          (Posix.openFdAt (Just baseFd) (takeFileName parent) Posix.ReadOnly flags)
                          Posix.closeFd
                          getFdStatus
                      namedRoot <-
                        bracket
                          (Posix.openFdAt (Just parentFd) (takeFileName root) Posix.ReadOnly flags)
                          Posix.closeFd
                          getFdStatus
                      parentMount <- mutationWorkspaceSameMount baseFd parentFd
                      rootMount <- mutationWorkspaceSameMount parentFd rootFd
                      let private status = isDirectory status && fileOwner status == owner && fileMode status .&. 0o7077 == 0
                      pure
                        ( private heldParent
                            && private heldRoot
                            && isDirectory heldBase
                            && fileOwner heldBase == owner
                            && fileMode heldBase .&. 0o7022 == 0
                            && sameIdentity baseStatus heldBase
                            && sameIdentity parentStatus heldParent
                            && sameIdentity rootStatus heldRoot
                            && sameIdentity heldBase currentBase
                            && sameIdentity heldParent namedParent
                            && sameIdentity heldRoot namedRoot
                            && parentMount
                            && rootMount
                        )
                ready <- stable
                traverse (const (action rootFd stable)) (guard ready)
  pure (either (const Nothing) id (attempted :: Either IOException (Maybe a)))

-- An exclusive, synced creation record identifies the source and the held root.
-- It is local evidence only; it cannot establish worker or resource absence.
recordCampaignIdentity :: Fd -> String -> SourceIdentity -> IO Bool -> IO Bool
recordCampaignIdentity rootFd runId source stable =
  recordPrivateCampaignValue rootFd ".mutation-campaign.json" stable $ do
    status <- getFdStatus rootFd
    let policy = sourceManifestPolicyIdentity source
        value =
          Aeson.object
            [ "schema_version" Aeson..= (1 :: Int)
            , "kind" Aeson..= ("mutation-campaign-created" :: String)
            , "run_id" Aeson..= runId
            , "root_device" Aeson..= show (deviceID status)
            , "root_inode" Aeson..= show (fileID status)
            , "git_head" Aeson..= gitHeadText (sourceGitHead source)
            , "worktree" Aeson..= show (sourceWorktreeState source)
            , "manifest_sha256" Aeson..= sourceManifestDigest source
            , "manifest_entries" Aeson..= sourceManifestEntryCount source
            , "policy_id" Aeson..= sourcePolicyIdentifier policy
            , "policy_version" Aeson..= sourcePolicyVersion policy
            , "policy_sha256" Aeson..= sourcePolicyDigest policy
            ]
    pure value

recordPrivateCampaignValue :: Fd -> FilePath -> IO Bool -> IO Aeson.Value -> IO Bool
recordPrivateCampaignValue = recordPrivateCampaignValueWithin privateRecordLimit

recordPrivateCampaignValueWithin :: Int -> Fd -> FilePath -> IO Bool -> IO Aeson.Value -> IO Bool
recordPrivateCampaignValueWithin limit rootFd recordName stable makeValue = do
  observed <- timeout 10000000 $ try $ do
    ready <- stable
    value <- makeValue
    let bytes = LazyByteString.toStrict (Aeson.encode value)
        flags =
          Posix.defaultFileFlags
            { Posix.nofollow = True
            , Posix.cloexec = True
            , Posix.exclusive = True
            , Posix.creat = Just 0o600
            }
        writeAll file remaining
          | ByteString.null remaining = pure ()
          | otherwise = do
              count <- PosixBytes.fdWrite file remaining
              unless (count > 0) (ioError (userError "short campaign record write"))
              writeAll file (ByteString.drop (fromIntegral count) remaining)
    if not ready || ByteString.length bytes > limit
      then pure False
      else do
        bracket (Posix.openFdAt (Just rootFd) recordName Posix.WriteOnly flags) Posix.closeFd $ \file -> do
          writeAll file bytes
          fileSynchronise file
        fileSynchronise rootFd
        result <- readPrivateMutationRecordWithin limit rootFd recordName stable
        pure (case result of PrivateRecordBytes actual -> actual == bytes; _ -> False)
  pure $ case observed of
    Just (Right result) -> result
    Just (Left (_ :: IOException)) -> False
    Nothing -> False

runCasesUntilIncomplete
  :: MutationSnapshot
  -> Fd
  -> IO Bool
  -> FilePath
  -> PreparedMutationDependencies
  -> [Case]
  -> IO [CaseResult]
runCasesUntilIncomplete _ _ _ _ _ [] = pure []
runCasesUntilIncomplete original campaignFd campaignStable root dependencies (mutationCase : remaining) = do
  completed <- runCase original campaignFd campaignStable root dependencies mutationCase
  recorded <-
    recordCaseOutcome
      campaignFd
      campaignStable
      (takeFileName root)
      (mutationSnapshotSource original)
      dependencies
      completed
  let result =
        if recorded
          then completed
          else
            completed
              { resultOutcome = MutationInconclusive
              , resultQualified = False
              , resultDetail = resultDetail completed ++ "; case receipt unconfirmed"
              }
  writeOutputLine
    ( resultName result
        ++ ": outcome="
        ++ show (resultOutcome result)
        ++ " expected="
        ++ show (resultExpected result)
        ++ "; "
        ++ resultDetail result
    )
  if not (resultQualified result)
    then pure [result]
    else
      (result :)
        <$> runCasesUntilIncomplete original campaignFd campaignStable root dependencies remaining

recordCaseOutcome
  :: Fd -> IO Bool -> String -> SourceIdentity -> PreparedMutationDependencies -> CaseResult -> IO Bool
recordCaseOutcome campaign stable runId source dependencies result =
  recordPrivateCampaignValueWithin
    caseReceiptLimit
    campaign
    (mutationCaseRecordName (resultName result))
    stable
    (payload <$> getFdStatus campaign)
 where
  payload status =
    Aeson.object
      [ "schema_version" Aeson..= (2 :: Int)
      , "kind" Aeson..= ("mutation-case-outcome" :: String)
      , "case" Aeson..= resultName result
      , "run_id" Aeson..= runId
      , "root_device" Aeson..= show (deviceID status)
      , "root_inode" Aeson..= show (fileID status)
      , "source_manifest" Aeson..= sourceManifestDigest source
      , "dependency_plan" Aeson..= publicEvidenceDigestText (dependencyPlanFingerprint dependencies)
      , "dependency_content" Aeson..= publicEvidenceDigestText (dependencyContentFingerprint dependencies)
      , "outcome" Aeson..= show (resultOutcome result)
      , "expected" Aeson..= show (resultExpected result)
      , "qualified" Aeson..= resultQualified result
      , "detail" Aeson..= resultDetail result
      ]

mutationCaseRecordName :: String -> FilePath
mutationCaseRecordName label =
  ".mutation-case-" ++ take 32 (ByteString8.unpack (hexSha256 (ByteString8.pack label))) ++ ".json"

recordCaseDisk
  :: Fd -> IO Bool -> String -> String -> DockerDaemonObservation -> MutationDiskReceipt -> IO Bool
recordCaseDisk campaign stable caseKey volume daemon receipt =
  recordPrivateCampaignValue campaign (".mutation-disk-" ++ caseKey ++ "-" ++ stage ++ ".json") stable $ do
    scope <- getFdStatus campaign
    pure $
      Aeson.object $
        [ "schema_version" Aeson..= (1 :: Int)
        , "kind" Aeson..= ("mutation-disk-" ++ stage)
        , "case_key" Aeson..= caseKey
        , "volume" Aeson..= volume
        , "daemon" Aeson..= show daemon
        , "root_device" Aeson..= show (deviceID scope)
        , "root_inode" Aeson..= show (fileID scope)
        ]
          ++ fields
 where
  (stage, fields) = case receipt of
    MutationDiskIntent spec ->
      ( "intent"
      ,
        [ "options" Aeson..= dockerMutationVolumeOptions spec
        , "owner" Aeson..= dockerMutationVolumeOwner spec
        ]
      )
    MutationDiskCreated at -> ("created", ["created_at" Aeson..= at])
    MutationDiskKeeper container pid -> ("keeper", ["container_id" Aeson..= container, "pid" Aeson..= pid])
    MutationDiskRemovalIntent at container -> ("removal-intent", binding at container)
    MutationDiskRemoved at container -> ("removed", binding at container)
  binding at container = ["created_at" Aeson..= at, "container_id" Aeson..= container]

runCase
  :: MutationSnapshot
  -> Fd
  -> IO Bool
  -> FilePath
  -> PreparedMutationDependencies
  -> Case
  -> IO CaseResult
runCase original campaignFd campaignStable root dependencies mutationCase = do
  diagnostics <- newIORef []
  started <- getMonotonicTimeNSec
  let name = caseName mutationCase
      workspace = root </> take 32 (ByteString8.unpack (hexSha256 (ByteString8.pack name)))
      output = workspace ++ "-output"
      expectedPath = caseTestPath mutationCase
      assertion = caseAssertion mutationCase
      selection = mutationSelection mutationCase
      label = "prodbox-mutant-" ++ takeFileName root ++ "-" ++ name
      finish outcome detail calibrated diskRetired = do
        observed <- readIORef diagnostics
        finished <- getMonotonicTimeNSec
        cleanup <-
          if outcome == caseExpected mutationCase && calibrated && diskRetired
            then retireCaseWorkspace campaignFd campaignStable workspace output
            else pure Nothing
        let qualified = cleanup /= Nothing
        pure
          ( CaseResult
              name
              (if qualified then outcome else MutationInconclusive)
              (caseExpected mutationCase)
              ( "classified "
                  ++ show outcome
                  ++ "; "
                  ++ detail
                  ++ "; diagnostics="
                  ++ show observed
                  ++ "; attempt time (ns)="
                  ++ show (finished - started)
                  ++ "; disk retired="
                  ++ show diskRetired
                  ++ "; workspace retirement="
                  ++ show cleanup
              )
              qualified
          )
  copied <- materializeCaseSnapshot original campaignFd campaignStable workspace output
  if not copied
    then finish MutationInconclusive "workspace snapshot failed" False False
    else do
      uid <- getEffectiveUserID
      gid <- getEffectiveGroupID
      daemon <- observeDockerDaemon mutationDockerSocket
      let user = show uid ++ ":" ++ show gid
          caseKey = takeFileName workspace
          volumeName = "prodbox-mutdisk-" ++ takeFileName root ++ "-" ++ caseKey
          record = recordCaseDisk campaignFd campaignStable caseKey volumeName daemon
      volume <- mutationDiskVolume volumeName caseKey
      executed <-
        withMutationDisk
          mutationDockerSocket
          daemon
          containerImage
          user
          volume
          campaignStable
          record
          (launchMutationKeeper campaignFd campaignStable workspace output label user volumeName)
          $ \disk ->
            runWithDisk disk diagnostics workspace output label expectedPath assertion selection
      case executed of
        Left failure -> finish MutationInconclusive (show failure) False False
        Right ((outcome, detail, calibrated), diskRetired) -> finish outcome detail calibrated diskRetired
 where
  runWithDisk disk diagnostics workspace output label expectedPath assertion selection = do
    let inContainerBound = inContainer campaignFd campaignStable dependencies disk
        readCaseFile = readMutationOutputFile campaignFd campaignStable disk
        readDigest source destination =
          fmap digestOf <$> readCaseFile source destination binaryPath (512 * 1024 * 1024)
        finish outcome detail = do
          observed <- readIORef diagnostics
          calibrated <-
            verifyCalibration
              mutationCase
              (readCaseFile workspace output "build.log" (16 * 1024 * 1024))
              observed
          pure (outcome, detail, calibrated)
    -- Isolation: probe the same container the build will use.
    probe <-
      inContainerBound
        diagnostics
        "isolation"
        Nothing
        120
        workspace
        output
        label
        mutationIsolationCommand
    let isolated = case probe of
          Just (ExitSuccess, out, _) ->
            let text = ByteString8.unpack out
             in "net=lo," `isInfixOf` text
                  && not ("SOCKET" `isInfixOf` text)
                  && not ("SECRETS" `isInfixOf` text)
                  && "probe-done" `isInfixOf` text
          _ -> False
    settled <- cleanupObserved diagnostics "isolation" label
    if not (isolated && settled)
      then finish MutationInconclusive "isolation or probe settlement unconfirmed"
      else do
        -- Never run a selected test after a failed or unsettled build.
        baselineBuild <-
          inContainerBound diagnostics "baseline-build" Nothing 3600 workspace output label buildCommand
        buildSettled <- cleanupObserved diagnostics "baseline-build" label
        case baselineBuild of
          Just (ExitSuccess, _, _) | buildSettled -> do
            baselineBinary <- readDigest workspace output
            baselineSelection <-
              selectionObservation
                inContainerBound
                diagnostics
                "baseline-selection"
                workspace
                output
                label
                selection
                expectedPath
                baselineBinary
            selectionSettled <- cleanupObserved diagnostics "baseline-selection" label
            case (baselineSelection, selectionSettled) of
              (Just _, True) -> do
                baselineRun <-
                  testObservation
                    inContainerBound
                    diagnostics
                    "baseline-test"
                    workspace
                    output
                    label
                    selection
                    assertion
                    []
                baselineSettled <- cleanupObserved diagnostics "baseline-test" label
                case (baselineRun, baselineSettled) of
                  (TestPassed count, True) -> do
                    let baseline = BaselinePassed count
                        binding =
                          MutationBinding
                            (mutationSnapshotSource original)
                            (maybe (digestOf "missing") id baselineBinary)
                            (patchDigest (casePatch mutationCase))
                            (digestOf (ByteString8.pack selection))
                            expectedPath
                            assertion
                    patched <- applyPatch workspace (casePatch mutationCase)
                    case patched of
                      Nothing ->
                        finish
                          ( classifyMutationAttempt
                              binding
                              ( MutationAttempt
                                  binding
                                  (boundary isolated)
                                  BoundaryConfirmed
                                  baseline
                                  baselineSelection
                                  PatchPreconditionFailed
                                  BuildNotRun
                                  Nothing
                                  TestNotRun
                              )
                          )
                          "patch precondition failed"
                      Just () -> do
                        mutantBuild <-
                          inContainerBound diagnostics "mutant-build" Nothing 3600 workspace output label buildCommand
                        mutantBuildSettled <- cleanupObserved diagnostics "mutant-build" label
                        case (mutantBuild, mutantBuildSettled) of
                          (Just (ExitSuccess, _, _), True) -> do
                            mutantBinary <- readDigest workspace output
                            mutantSelection <-
                              selectionObservation
                                inContainerBound
                                diagnostics
                                "mutant-selection"
                                workspace
                                output
                                label
                                selection
                                expectedPath
                                mutantBinary
                            mutantSelectionSettled <- cleanupObserved diagnostics "mutant-selection" label
                            case (mutantSelection, mutantSelectionSettled) of
                              (Just _, True) -> do
                                testResult <-
                                  testObservation
                                    inContainerBound
                                    diagnostics
                                    "mutant-test"
                                    workspace
                                    output
                                    label
                                    selection
                                    assertion
                                    (caseTestArguments mutationCase)
                                cleaned <- cleanupObserved diagnostics "mutant-test" label
                                let attempt =
                                      MutationAttempt
                                        binding
                                        (boundary isolated)
                                        (boundary cleaned)
                                        baseline
                                        baselineSelection
                                        PatchApplied
                                        (maybe BuildUnobservable BuildSucceeded mutantBinary)
                                        mutantSelection
                                        testResult
                                finish
                                  (classifyMutationAttempt binding attempt)
                                  ( "build ok, test="
                                      ++ show testResult
                                      ++ ", isolation="
                                      ++ show isolated
                                      ++ ", cleanup="
                                      ++ show cleaned
                                      ++ ", mutation binding="
                                      ++ show binding
                                      ++ ", mutant binary="
                                      ++ show mutantBinary
                                  )
                              _ -> finish MutationInconclusive "mutant selection or settlement unconfirmed"
                          (Just (_, _, _), True) -> do
                            finish
                              ( classifyMutationAttempt
                                  binding
                                  ( MutationAttempt
                                      binding
                                      (boundary isolated)
                                      BoundaryConfirmed
                                      baseline
                                      baselineSelection
                                      PatchApplied
                                      BuildRejected
                                      Nothing
                                      TestNotRun
                                  )
                              )
                              ("build rejected, isolation=" ++ show isolated ++ ", mutation binding=" ++ show binding)
                          _ -> finish MutationInconclusive "mutant build failed or settlement unconfirmed"
                  _ -> finish MutationInconclusive "baseline test failed or settlement unconfirmed"
              _ -> finish MutationInconclusive "baseline selection or settlement unconfirmed"
          Just (ExitFailure code, stdoutBytes, stderrBytes) | buildSettled -> do
            contents <- readCaseFile workspace output "build.log" (16 * 1024 * 1024)
            let (origin, bytes) = case contents of
                  Nothing -> ("worker process", stdoutBytes <> stderrBytes)
                  Just logBytes -> ("build log", logBytes)
            stored <- recordBaselineDiagnostic code workspace origin bytes
            finish
              MutationInconclusive
              ("baseline build rejected; private compiler diagnostic recorded=" ++ show stored)
          _ -> finish MutationInconclusive "baseline build or settlement unconfirmed"
  recordBaselineDiagnostic code workspace (origin :: String) bytes =
    recordPrivateCampaignValue
      campaignFd
      (".mutation-baseline-failure-" ++ takeFileName workspace ++ ".json")
      campaignStable
      $ pure (recordWithinLimit (ByteString.take 3072 excerpt))
   where
    excerpt = case filter relevant (ByteString8.lines bytes) of
      [] -> ByteString.drop (max 0 (ByteString.length bytes - 3072)) bytes
      linesWithErrors -> ByteString8.unlines (take 12 linesWithErrors)
    relevant line =
      any
        (`ByteString8.isInfixOf` ByteString8.map toLower line)
        [ "error:"
        , "fatal"
        , "no space left"
        , "killed"
        , "out of memory"
        , "permission denied"
        , "ghc.linker.loader"
        , "failed to map segment"
        ]
    recordWithinLimit sample =
      let value =
            Aeson.object
              [ "schema_version" Aeson..= (1 :: Int)
              , "kind" Aeson..= ("mutation-baseline-build-rejected" :: String)
              , "source_manifest" Aeson..= sourceManifestDigest (mutationSnapshotSource original)
              , "exit_code" Aeson..= code
              , "log_origin" Aeson..= origin
              , "log_bytes" Aeson..= ByteString.length bytes
              , "log_excerpt" Aeson..= TextEncoding.decodeUtf8With lenientDecode sample
              ]
       in if LazyByteString.length (Aeson.encode value) <= fromIntegral privateRecordLimit
            then value
            else recordWithinLimit (ByteString.take (ByteString.length sample `div` 2) sample)
  boundary True = BoundaryConfirmed
  boundary False = BoundaryFailed
  selectionObservation inContainerBound diagnostics stage workspace output label selection expectedPath binary = do
    listed <-
      inContainerBound
        diagnostics
        stage
        Nothing
        300
        workspace
        output
        label
        (mutationSelectionCommand selection)
    pure $ case (listed, binary) of
      (Just (code, out, err), Just digest) -> either (const Nothing) Just (validateMutationSelection expectedPath digest code out err)
      _ -> Nothing
  testObservation inContainerBound diagnostics stage workspace output label selection assertion extra = do
    ran <-
      inContainerBound
        diagnostics
        stage
        (Just assertion)
        600
        workspace
        output
        label
        (mutationTestCommand selection assertion extra)
    pure $ case ran of
      Just (code, out, err) -> decodeSingleMutationTest assertion code out err
      Nothing -> TestUnobservable
  cleanupObserved diagnostics stage label = do
    observed <- readIORef diagnostics
    if MutationRetirementObserved stage `elem` observed
      then pure True
      else collectUnconfirmedInventory diagnostics stage label
  collectUnconfirmedInventory diagnostics stage label = do
    listing <-
      run
        60
        "/usr/bin/docker"
        [ "--host"
        , "unix://" ++ mutationDockerSocket
        , "ps"
        , "-a"
        , "-q"
        , "--filter"
        , "label=io.prodbox.mutant=" ++ label
        ]
    modifyIORef' diagnostics (++ [mutationInventoryDiagnostic stage listing])
    pure False

verifyCalibration
  :: Case -> IO (Maybe ByteString.ByteString) -> [MutationInvocationDiagnostic] -> IO Bool
verifyCalibration mutationCase readBuildLog observed = case caseName mutationCase of
  "calibration-invalid" -> do
    result <- readBuildLog
    pure $ case result of
      Just bytes ->
        "src/Prodbox/Test/ScenarioEvidence.hs:" `ByteString.isInfixOf` bytes
          && "parse error on input" `ByteString.isInfixOf` bytes
      Nothing -> False
  "calibration-timeout" -> pure (any timedOut observed)
  _ -> pure True
 where
  timedOut diagnostic = case diagnostic of
    MutationInvocationExited "mutant-test" (ExitFailure _) (Just TestTimedOut) _ _ -> True
    _ -> False

-- An isolated child may leave links in its writable output. Read only the
-- selected regular file through held, no-follow descriptors on the same mount.
readMutationOutputFile
  :: Fd
  -> IO Bool
  -> MutationDisk
  -> FilePath
  -> FilePath
  -> FilePath
  -> Int
  -> IO (Maybe ByteString.ByteString)
readMutationOutputFile campaign stable disk workspace output relative limit = do
  let active = (&&) <$> stable <*> mutationDiskStable disk
  result <-
    timeout 90000000 $
      withCampaignMutationDirectories campaign active workspace output $ \_ _ _ held ->
        readMutationOutputMember (mutationDiskRoot disk) held relative limit
  pure $ case result of
    Just (MutationBindingsStable bytes) -> bytes
    _ -> Nothing

-- Cabal can explicitly create 0755 intermediate directories. The private
-- quota root protects traversal and the leaf still requires private mode.
readMutationOutputMember :: Fd -> IO Bool -> FilePath -> Int -> IO (Maybe ByteString.ByteString)
readMutationOutputMember root held relative limit = do
  owner <- getEffectiveUserID
  let names = splitDirectories relative
      safe name = name `notElem` ["", ".", "..", "/"] && notElem '/' name
  result <- try $ do
    status <- getFdStatus root
    before <- held
    if before
      && not (null names)
      && all safe names
      && limit > 0
      && isDirectory status
      && fileOwner status == owner
      && fileMode status .&. 0o7077 == 0
      then readSelected owner root names
      else pure Nothing
  pure (either (const Nothing) id (result :: Either IOException (Maybe ByteString.ByteString)))
 where
  flags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}
  readSelected owner parent names = case names of
    [] -> pure Nothing
    [name] ->
      bracket (Posix.openFdAt (Just parent) name Posix.ReadOnly flags) Posix.closeFd $ \file -> do
        before <- getFdStatus file
        exact <- mutationWorkspaceSameMount parent file
        if not
          ( exact
              && isRegularFile before
              && fileOwner before == owner
              && fileMode before .&. 0o7077 == 0
              && linkCount before == 1
              && fileSize before >= 0
              && toInteger (fileSize before) <= toInteger limit
          )
          then pure Nothing
          else do
            bytes <- bracket (Posix.dup file >>= Posix.fdToHandle) hClose $ \handle ->
              ByteString.hGet handle (fromIntegral (fileSize before) + 1)
            after <- getFdStatus file
            named <- bracket (Posix.openFdAt (Just parent) name Posix.ReadOnly flags) Posix.closeFd getFdStatus
            unchanged <- held
            pure $
              if unchanged
                && sameFile before after
                && sameFile after named
                && toInteger (ByteString.length bytes) == toInteger (fileSize after)
                then Just bytes
                else Nothing
    name : remaining ->
      bracket
        (Posix.openFdAt (Just parent) name Posix.ReadOnly (flags {Posix.directory = True}))
        Posix.closeFd
        $ \directory -> do
          status <- getFdStatus directory
          sameMount <- mutationWorkspaceSameMount parent directory
          if sameMount && isDirectory status && fileOwner status == owner && fileMode status .&. 0o7022 == 0
            then readSelected owner directory remaining
            else pure Nothing
  sameFile left right =
    deviceID left == deviceID right
      && fileID left == fileID right
      && fileOwner left == fileOwner right
      && fileMode left == fileMode right
      && fileSize left == fileSize right
      && linkCount left == linkCount right
      && modificationTimeHiRes left == modificationTimeHiRes right
      && statusChangeTimeHiRes left == statusChangeTimeHiRes right

-- Take and recheck both inventories after the last attempted container has
-- retired. The campaign records and prepared dependencies remain available.
retireCaseWorkspace
  :: Fd -> IO Bool -> FilePath -> FilePath -> IO (Maybe (PublicEvidenceDigest, PublicEvidenceDigest))
retireCaseWorkspace campaign stable workspace output =
  case mutationOutputLimits 50000 17179869184 40 90000000 of
    Nothing -> pure Nothing
    Just inventoryLimits -> do
      inventories <- withCampaignMutationDirectories campaign stable workspace output $ \_ source destination _ ->
        (,)
          <$> observeMutationOutputInventory inventoryLimits source
          <*> observeMutationOutputInventory inventoryLimits destination
      case inventories of
        MutationBindingsStable (MutationOutputObserved source, MutationOutputObserved destination) -> do
          removedOutput <-
            removeObservedMutationOutput inventoryLimits campaign (takeFileName output) destination stable
          removedSource <-
            if removedOutput
              then removeObservedMutationOutput inventoryLimits campaign (takeFileName workspace) source stable
              else pure False
          pure $
            if removedSource
              then
                Just (mutationOutputInventoryFingerprint source, mutationOutputInventoryFingerprint destination)
              else Nothing
        _ -> pure Nothing

patchDigest :: Patch -> PublicEvidenceDigest
patchDigest (Reviewed mutation) = reviewedPatchDigest mutation
patchDigest (Calibration label path old new) =
  hashPublicEvidence
    ( Text.intercalate
        "\NUL"
        ["prodbox-calibration-mutation-v1", Text.pack label, Text.pack path, old, new]
    )

applyPatch :: FilePath -> Patch -> IO (Maybe ())
applyPatch workspace patch = case patch of
  Reviewed mutation -> do
    let path = workspace </> reviewedSourcePath mutation
    bytes <- ByteString.readFile path
    case prepareReviewedMutation mutation bytes of
      Left _ -> pure Nothing
      Right prepared -> ByteString.writeFile path (preparedMutantBytes prepared) >> pure (Just ())
  Calibration _ relative old new -> do
    let path = workspace </> relative
    bytes <- ByteString.readFile path
    let text = TextEncoding.decodeUtf8 bytes
    case Text.splitOn old text of
      [prefix, suffix] -> ByteString.writeFile path (TextEncoding.encodeUtf8 (prefix <> new <> suffix)) >> pure (Just ())
      _ -> pure Nothing

-- Each case starts with the campaign's immutable admitted source bytes in a
-- fresh private directory. The reviewed change stays in that case's copy.
materializeCaseSnapshot :: MutationSnapshot -> Fd -> IO Bool -> FilePath -> FilePath -> IO Bool
materializeCaseSnapshot original parent stable workspace output = do
  written <- try $ do
    before <- stable
    if not before
      then pure False
      else do
        result <- writeMutationSnapshot parent (takeFileName workspace) original
        case result of
          MutationSnapshotWritten _ -> do
            still <- stable
            if not still
              then pure False
              else do
                let Fd raw = parent
                withCString (takeFileName output) $ \name ->
                  throwErrnoIfMinus1_ "mkdirat" (makeCampaignDirectoryAt raw name 0o700)
                fileSynchronise parent
                stable
          _ -> pure False
  pure (either (const False) id (written :: Either IOException Bool))
