{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Host-durable storage for the exact disposable-artifact intent set of one
-- cleanup run.  This store is deliberately independent of Kubernetes and the
-- Lifecycle Authority: it is committed before the caller may create either
-- artifact and remains on the retained host until exact terminal evidence and
-- two positive local absence read-backs authorize retirement.
module Prodbox.Lifecycle.TestArtifactIntentJournal
  ( TestArtifactIntentJournalStore
  , mkTestArtifactIntentJournalStore
  , testArtifactIntentJournalRetainedRoot
  , testArtifactIntentJournalDirectory
  , testArtifactIntentJournalPath
  , testArtifactIntentJournalTemporaryPath
  , testArtifactIntentJournalRetiredPath
  , testArtifactIntentJournalFormatVersion
  , maximumTestArtifactIntentJournalBytes
  , TestArtifactPathSetDigest
  , testArtifactPathSetDigestText
  , testArtifactIntentPathSetDigest
  , encodeTestArtifactIntentPlan
  , decodeTestArtifactIntentPlan
  , testArtifactIntentJournalAdapter
  , commitTestArtifactIntentPlan
  , observeTestArtifactIntentPlan
  , TestArtifactIntentRetirement
  , retiredTestArtifactIntentRunId
  , retiredTestArtifactIntentGraphDigest
  , retiredTestArtifactIntentPathSetDigest
  , retiredTestArtifactIntentContentDigest
  , retiredTestArtifactIntentArchivePath
  , retireTestArtifactIntentPlan
  , TestArtifactIntentJournalRegression
  , fixedTestArtifactIntentJournalRegression
  , testArtifactIntentJournalRegressionWrongRunRefused
  , testArtifactIntentJournalRegressionWrongGraphRefused
  , testArtifactIntentJournalRegressionPresentRefused
  , testArtifactIntentJournalRegressionDurableRetirement
  , testArtifactIntentJournalRegressionExactReplay
  , TestArtifactIntentJournalError (..)
  , renderTestArtifactIntentJournalError
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Concurrent.MVar (MVar, modifyMVar, modifyMVar_, newMVar)
import Control.Exception
  ( IOException
  , bracket
  , finally
  , mask
  , mask_
  , onException
  , throwIO
  , try
  )
import Control.Monad (unless)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List.NonEmpty qualified as NonEmpty
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word16)
import GHC.Generics (Generic)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Lifecycle.CleanupRun
  ( CleanupDigest
  , CleanupRunId
  )
import Prodbox.Lifecycle.Teardown.CascadeEvidence
  ( CascadeCompleteEvidence
  , cascadeCompleteGraphDigest
  , cascadeCompleteRunId
  )
import Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal
  ( withCascadeEvidenceFixtureForRunInternal
  , withFixedCascadeEvidenceFixtureInternal
  )
import Prodbox.Lifecycle.TestArtifactCleanup
  ( TestArtifactCleanupPlan
  , TestArtifactCleanupPlanError
  , TestArtifactIntent
  , TestArtifactIntentJournal (..)
  , TestArtifactKind (..)
  , mkTestArtifactCleanupPlan
  , testArtifactCleanupPlanGraphDigest
  , testArtifactCleanupPlanIntents
  , testArtifactCleanupPlanRepoRoot
  , testArtifactCleanupPlanRunId
  , testArtifactIntentKind
  , testArtifactIntentPath
  )
import System.Directory
  ( canonicalizePath
  , createDirectoryIfMissing
  , doesFileExist
  , removeFile
  , renameFile
  )
import System.FilePath (isAbsolute, normalise, takeDirectory, (</>))
import System.IO (SeekMode (AbsoluteSeek))
import System.IO.Error (isDoesNotExistError, isEOFError)
import System.IO.Temp (withSystemTempDirectory)
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.Files
  ( FileStatus
  , accessModes
  , createLink
  , fileMode
  , fileSize
  , getFdStatus
  , getSymbolicLinkStatus
  , intersectFileModes
  , isDirectory
  , isRegularFile
  , isSymbolicLink
  , ownerModes
  , ownerReadMode
  , ownerWriteMode
  , removeLink
  , setFdMode
  , setFileMode
  , unionFileModes
  )
import System.Posix.IO
  ( LockRequest (Unlock, WriteLock)
  , OpenFileFlags (..)
  , OpenMode (ReadOnly, ReadWrite, WriteOnly)
  , closeFd
  , defaultFileFlags
  , openFd
  , setLock
  )
import System.Posix.IO.ByteString qualified as PosixByteString
import System.Posix.Types (Fd, FileMode)
import System.Posix.Unistd (fileSynchronise)

newtype TestArtifactIntentJournalStore = TestArtifactIntentJournalStore
  { internalTestArtifactIntentRetainedRoot :: FilePath
  }
  deriving stock (Eq, Show)

mkTestArtifactIntentJournalStore
  :: FilePath
  -> Either TestArtifactIntentJournalError TestArtifactIntentJournalStore
mkTestArtifactIntentJournalStore retainedRoot
  | not (isAbsolute retainedRoot) =
      Left
        ( TestArtifactIntentJournalStoreInvalid
            "retained root must be absolute"
        )
  | normalise retainedRoot == "/" =
      Left
        ( TestArtifactIntentJournalStoreInvalid
            "retained root must not be the filesystem root"
        )
  | otherwise =
      Right (TestArtifactIntentJournalStore (normalise retainedRoot))

testArtifactIntentJournalRetainedRoot
  :: TestArtifactIntentJournalStore -> FilePath
testArtifactIntentJournalRetainedRoot =
  internalTestArtifactIntentRetainedRoot

testArtifactIntentJournalDirectory
  :: TestArtifactIntentJournalStore -> FilePath
testArtifactIntentJournalDirectory store =
  testArtifactIntentJournalRetainedRoot store
    </> "test-artifact-intents-v1"

data TestArtifactIntentJournalCoordinate = TestArtifactIntentJournalCoordinate
  { coordinateVersion :: !Word16
  , coordinateRunId :: !CleanupRunId
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

runCoordinateDigest :: CleanupRunId -> String
runCoordinateDigest runId =
  ByteString8.unpack
    ( hexSha256
        ( LazyByteString.toStrict
            ( serialise
                TestArtifactIntentJournalCoordinate
                  { coordinateVersion = testArtifactIntentJournalFormatVersion
                  , coordinateRunId = runId
                  }
            )
        )
    )

testArtifactIntentJournalPath
  :: TestArtifactIntentJournalStore -> CleanupRunId -> FilePath
testArtifactIntentJournalPath store runId =
  testArtifactIntentJournalDirectory store
    </> ("active-" ++ runCoordinateDigest runId ++ ".cbor")

testArtifactIntentJournalTemporaryPath
  :: TestArtifactIntentJournalStore -> CleanupRunId -> FilePath
testArtifactIntentJournalTemporaryPath store runId =
  testArtifactIntentJournalDirectory store
    </> (".active-" ++ runCoordinateDigest runId ++ ".cbor.tmp")

journalLockPath :: TestArtifactIntentJournalStore -> FilePath
journalLockPath store =
  testArtifactIntentJournalDirectory store
    </> ".test-artifact-intents.lock"

testArtifactIntentJournalFormatVersion :: Word16
testArtifactIntentJournalFormatVersion = 1

maximumTestArtifactIntentJournalBytes :: Int
maximumTestArtifactIntentJournalBytes = 64 * 1024

data TestArtifactIntentEnvelope = TestArtifactIntentEnvelope
  { envelopeVersion :: !Word16
  , envelopeRunId :: !CleanupRunId
  , envelopeGraphDigest :: !CleanupDigest
  , envelopePathSetDigest :: !Text
  , envelopeRepoRoot :: !FilePath
  , envelopeGeneratedConfigPath :: !FilePath
  , envelopeThisRunDataPath :: !FilePath
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

newtype TestArtifactPathSetDigest = TestArtifactPathSetDigest
  { testArtifactPathSetDigestText :: Text
  }
  deriving stock (Eq, Ord, Show)

data TestArtifactPathSetCoordinate = TestArtifactPathSetCoordinate
  { pathSetCoordinateVersion :: !Word16
  , pathSetCoordinateRepoRoot :: !FilePath
  , pathSetCoordinateGeneratedConfig :: !FilePath
  , pathSetCoordinateThisRunData :: !FilePath
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

testArtifactIntentPathSetDigest
  :: TestArtifactCleanupPlan
  -> Either TestArtifactIntentJournalError TestArtifactPathSetDigest
testArtifactIntentPathSetDigest plan = do
  (generatedConfigPath, thisRunDataPath) <- exactPlanPaths plan
  let coordinate =
        TestArtifactPathSetCoordinate
          { pathSetCoordinateVersion = testArtifactIntentJournalFormatVersion
          , pathSetCoordinateRepoRoot = testArtifactCleanupPlanRepoRoot plan
          , pathSetCoordinateGeneratedConfig = generatedConfigPath
          , pathSetCoordinateThisRunData = thisRunDataPath
          }
  Right
    ( TestArtifactPathSetDigest
        ( TextEncoding.decodeUtf8
            ( hexSha256
                (LazyByteString.toStrict (serialise coordinate))
            )
        )
    )

encodeTestArtifactIntentPlan
  :: TestArtifactCleanupPlan
  -> Either TestArtifactIntentJournalError ByteString
encodeTestArtifactIntentPlan plan = do
  (generatedConfigPath, thisRunDataPath) <- exactPlanPaths plan
  pathSetDigest <- testArtifactIntentPathSetDigest plan
  let encoded =
        LazyByteString.toStrict
          ( serialise
              TestArtifactIntentEnvelope
                { envelopeVersion = testArtifactIntentJournalFormatVersion
                , envelopeRunId = testArtifactCleanupPlanRunId plan
                , envelopeGraphDigest = testArtifactCleanupPlanGraphDigest plan
                , envelopePathSetDigest =
                    testArtifactPathSetDigestText pathSetDigest
                , envelopeRepoRoot = testArtifactCleanupPlanRepoRoot plan
                , envelopeGeneratedConfigPath = generatedConfigPath
                , envelopeThisRunDataPath = thisRunDataPath
                }
          )
  if ByteString.length encoded > maximumTestArtifactIntentJournalBytes
    then
      Left
        ( TestArtifactIntentJournalEncodedTooLarge
            (ByteString.length encoded)
            maximumTestArtifactIntentJournalBytes
        )
    else Right encoded

decodeTestArtifactIntentPlan
  :: ByteString
  -> Either TestArtifactIntentJournalError TestArtifactCleanupPlan
decodeTestArtifactIntentPlan bytes
  | ByteString.length bytes > maximumTestArtifactIntentJournalBytes =
      Left
        ( TestArtifactIntentJournalEncodedTooLarge
            (ByteString.length bytes)
            maximumTestArtifactIntentJournalBytes
        )
  | otherwise = case deserialiseOrFail (LazyByteString.fromStrict bytes) of
      Left _ ->
        Left
          ( TestArtifactIntentJournalDecodeInvalid
              "invalid artifact intent envelope"
          )
      Right envelope
        | envelopeVersion envelope /= testArtifactIntentJournalFormatVersion ->
            Left
              ( TestArtifactIntentJournalUnsupportedVersion
                  (envelopeVersion envelope)
              )
        | LazyByteString.toStrict (serialise envelope) /= bytes ->
            Left TestArtifactIntentJournalNonCanonical
        | otherwise -> do
            plan <-
              either
                (Left . TestArtifactIntentJournalPlanInvalid)
                Right
                ( mkTestArtifactCleanupPlan
                    (envelopeRepoRoot envelope)
                    (envelopeRunId envelope)
                    (envelopeGraphDigest envelope)
                    (envelopeGeneratedConfigPath envelope)
                    (envelopeThisRunDataPath envelope)
                )
            (generatedConfigPath, thisRunDataPath) <- exactPlanPaths plan
            pathSetDigest <- testArtifactIntentPathSetDigest plan
            if testArtifactPathSetDigestText pathSetDigest
              /= envelopePathSetDigest envelope
              then
                Left
                  ( TestArtifactIntentJournalPathDigestMismatch
                      (testArtifactPathSetDigestText pathSetDigest)
                      (envelopePathSetDigest envelope)
                  )
              else
                if testArtifactCleanupPlanRepoRoot plan
                  == envelopeRepoRoot envelope
                  && generatedConfigPath
                    == envelopeGeneratedConfigPath envelope
                  && thisRunDataPath
                    == envelopeThisRunDataPath envelope
                  then Right plan
                  else Left TestArtifactIntentJournalNonCanonical

exactPlanPaths
  :: TestArtifactCleanupPlan
  -> Either TestArtifactIntentJournalError (FilePath, FilePath)
exactPlanPaths plan =
  case NonEmpty.toList (testArtifactCleanupPlanIntents plan) of
    [generated, thisRunData]
      | testArtifactIntentKind generated == TestArtifactGeneratedRunConfig
      , testArtifactIntentKind thisRunData == TestArtifactThisRunData ->
          Right
            ( testArtifactIntentPath generated
            , testArtifactIntentPath thisRunData
            )
    _ -> Left TestArtifactIntentJournalPlanShapeInvalid

testArtifactIntentJournalRetiredPath
  :: TestArtifactIntentJournalStore
  -> TestArtifactCleanupPlan
  -> Either TestArtifactIntentJournalError FilePath
testArtifactIntentJournalRetiredPath store plan = do
  encoded <- encodeTestArtifactIntentPlan plan
  Right
    ( testArtifactIntentJournalDirectory store
        </> ( "retired-"
                ++ ByteString8.unpack (hexSha256 encoded)
                ++ ".cbor"
            )
    )

data TestArtifactIntentRetirement = TestArtifactIntentRetirement
  { internalRetiredTestArtifactIntentRunId :: !CleanupRunId
  , internalRetiredTestArtifactIntentGraphDigest :: !CleanupDigest
  , internalRetiredTestArtifactIntentPathSetDigest :: !TestArtifactPathSetDigest
  , internalRetiredTestArtifactIntentContentDigest :: !Text
  , internalRetiredTestArtifactIntentArchivePath :: !FilePath
  }
  deriving stock (Eq, Show)

retiredTestArtifactIntentRunId
  :: TestArtifactIntentRetirement -> CleanupRunId
retiredTestArtifactIntentRunId = internalRetiredTestArtifactIntentRunId

retiredTestArtifactIntentGraphDigest
  :: TestArtifactIntentRetirement -> CleanupDigest
retiredTestArtifactIntentGraphDigest =
  internalRetiredTestArtifactIntentGraphDigest

retiredTestArtifactIntentPathSetDigest
  :: TestArtifactIntentRetirement -> TestArtifactPathSetDigest
retiredTestArtifactIntentPathSetDigest =
  internalRetiredTestArtifactIntentPathSetDigest

retiredTestArtifactIntentContentDigest
  :: TestArtifactIntentRetirement -> Text
retiredTestArtifactIntentContentDigest =
  internalRetiredTestArtifactIntentContentDigest

retiredTestArtifactIntentArchivePath
  :: TestArtifactIntentRetirement -> FilePath
retiredTestArtifactIntentArchivePath =
  internalRetiredTestArtifactIntentArchivePath

data TestArtifactIntentJournalError
  = TestArtifactIntentJournalStoreInvalid !Text
  | TestArtifactIntentJournalPlanInvalid !TestArtifactCleanupPlanError
  | TestArtifactIntentJournalPlanShapeInvalid
  | TestArtifactIntentJournalEncodedTooLarge !Int !Int
  | TestArtifactIntentJournalDecodeInvalid !Text
  | TestArtifactIntentJournalUnsupportedVersion !Word16
  | TestArtifactIntentJournalNonCanonical
  | TestArtifactIntentJournalPathDigestMismatch !Text !Text
  | TestArtifactIntentJournalFileNotRegular !FilePath
  | TestArtifactIntentJournalFileModeInvalid !FilePath
  | TestArtifactIntentJournalDirectoryModeInvalid !FilePath
  | TestArtifactIntentJournalAlreadyLocked
  | TestArtifactIntentJournalTemporaryConflict
  | TestArtifactIntentJournalActiveConflict
  | TestArtifactIntentJournalReadBackMismatch
  | TestArtifactIntentJournalMissing
  | TestArtifactIntentJournalRunCoordinateMismatch !CleanupRunId !CleanupRunId
  | TestArtifactIntentJournalProofRunMismatch !CleanupRunId !CleanupRunId
  | TestArtifactIntentJournalProofGraphMismatch !CleanupDigest !CleanupDigest
  | TestArtifactIntentJournalArtifactStillPresent
      !TestArtifactKind
      !FilePath
  | TestArtifactIntentJournalArtifactUnobservable
      !TestArtifactKind
      !FilePath
      !String
  | TestArtifactIntentJournalRetirementArchiveConflict
  | TestArtifactIntentJournalIoFailure !String
  deriving stock (Eq, Show)

renderTestArtifactIntentJournalError
  :: TestArtifactIntentJournalError -> Text
renderTestArtifactIntentJournalError = Text.pack . show

testArtifactIntentJournalAdapter
  :: TestArtifactIntentJournalStore -> TestArtifactIntentJournal IO
testArtifactIntentJournalAdapter store =
  TestArtifactIntentJournal
    { commitTestArtifactIntents = \plan ->
        mapLeft renderTestArtifactIntentJournalError
          <$> commitTestArtifactIntentPlan store plan
    , observeTestArtifactIntents = \runId ->
        mapLeft renderTestArtifactIntentJournalError
          <$> observeTestArtifactIntentPlan store runId
    }

mapLeft :: (left -> other) -> Either left right -> Either other right
mapLeft transform result = case result of
  Left err -> Left (transform err)
  Right value -> Right value

data StoredArtifactIntent
  = StoredArtifactIntentMissing
  | StoredArtifactIntentPresent !ByteString !TestArtifactCleanupPlan

commitTestArtifactIntentPlan
  :: TestArtifactIntentJournalStore
  -> TestArtifactCleanupPlan
  -> IO (Either TestArtifactIntentJournalError ())
commitTestArtifactIntentPlan store expected =
  case encodeTestArtifactIntentPlan expected of
    Left err -> pure (Left err)
    Right expectedBytes ->
      withTestArtifactIntentJournalLock store $ \preparedStore -> do
        let activePath =
              testArtifactIntentJournalPath
                preparedStore
                (testArtifactCleanupPlanRunId expected)
        observed <- readStoredArtifactIntent activePath
        case observed of
          Left err -> pure (Left err)
          Right StoredArtifactIntentMissing ->
            atomicPersistAndReadBack
              preparedStore
              expectedBytes
              expected
          Right stored
            | exactStoredArtifactIntent expectedBytes expected stored ->
                durabilityReadBack
                  preparedStore
                  activePath
                  expectedBytes
                  expected
            | otherwise ->
                pure (Left TestArtifactIntentJournalActiveConflict)

observeTestArtifactIntentPlan
  :: TestArtifactIntentJournalStore
  -> CleanupRunId
  -> IO
       ( Either
           TestArtifactIntentJournalError
           (Maybe TestArtifactCleanupPlan)
       )
observeTestArtifactIntentPlan store runId =
  withTestArtifactIntentJournalLock store $ \preparedStore -> do
    observed <-
      readStoredArtifactIntent
        (testArtifactIntentJournalPath preparedStore runId)
    pure $ case observed of
      Left err -> Left err
      Right StoredArtifactIntentMissing -> Right Nothing
      Right (StoredArtifactIntentPresent _ plan)
        | testArtifactCleanupPlanRunId plan == runId -> Right (Just plan)
        | otherwise ->
            Left
              ( TestArtifactIntentJournalRunCoordinateMismatch
                  runId
                  (testArtifactCleanupPlanRunId plan)
              )

exactStoredArtifactIntent
  :: ByteString
  -> TestArtifactCleanupPlan
  -> StoredArtifactIntent
  -> Bool
exactStoredArtifactIntent expectedBytes expected stored = case stored of
  StoredArtifactIntentMissing -> False
  StoredArtifactIntentPresent actualBytes actual ->
    actualBytes == expectedBytes && actual == expected

data HeldTestArtifactIntentJournalLock = HeldTestArtifactIntentJournalLock
  { heldTestArtifactIntentJournalLockPath :: !FilePath
  , heldTestArtifactIntentJournalLockFd :: !Fd
  }

{-# NOINLINE processTestArtifactIntentJournalLocks #-}
processTestArtifactIntentJournalLocks :: MVar (Set FilePath)
processTestArtifactIntentJournalLocks = unsafePerformIO (newMVar Set.empty)

ownerFileMode :: FileMode
ownerFileMode = ownerReadMode `unionFileModes` ownerWriteMode

withTestArtifactIntentJournalLock
  :: TestArtifactIntentJournalStore
  -> ( TestArtifactIntentJournalStore
       -> IO (Either TestArtifactIntentJournalError value)
     )
  -> IO (Either TestArtifactIntentJournalError value)
withTestArtifactIntentJournalLock store action = do
  prepared <- prepareTestArtifactIntentJournalRoot store
  case prepared of
    Left err -> pure (Left err)
    Right preparedStore ->
      mask $ \restore -> do
        acquired <- acquireTestArtifactIntentJournalLock preparedStore
        case acquired of
          Left err -> pure (Left err)
          Right held ->
            restore (action preparedStore)
              `finally` releaseTestArtifactIntentJournalLock held

prepareTestArtifactIntentJournalRoot
  :: TestArtifactIntentJournalStore
  -> IO
       ( Either
           TestArtifactIntentJournalError
           TestArtifactIntentJournalStore
       )
prepareTestArtifactIntentJournalRoot store = do
  canonicalResult <-
    try
      ( canonicalizePath
          (testArtifactIntentJournalRetainedRoot store)
      )
  case canonicalResult of
    Left (err :: IOException) ->
      pure (Left (TestArtifactIntentJournalIoFailure (show err)))
    Right canonicalRoot
      | normalise canonicalRoot == "/" ->
          pure
            ( Left
                ( TestArtifactIntentJournalStoreInvalid
                    "retained root resolves to the filesystem root"
                )
            )
      | otherwise -> do
          let preparedStore =
                TestArtifactIntentJournalStore (normalise canonicalRoot)
              journalDirectory =
                testArtifactIntentJournalDirectory preparedStore
          created <-
            try (createDirectoryIfMissing False journalDirectory)
          case created of
            Left (err :: IOException) ->
              pure (Left (TestArtifactIntentJournalIoFailure (show err)))
            Right () -> secureTestArtifactIntentJournalDirectory preparedStore

secureTestArtifactIntentJournalDirectory
  :: TestArtifactIntentJournalStore
  -> IO
       ( Either
           TestArtifactIntentJournalError
           TestArtifactIntentJournalStore
       )
secureTestArtifactIntentJournalDirectory store = do
  let path = testArtifactIntentJournalDirectory store
  statusResult <- try (getSymbolicLinkStatus path)
  case statusResult of
    Left (err :: IOException) ->
      pure (Left (TestArtifactIntentJournalIoFailure (show err)))
    Right status
      | isSymbolicLink status || not (isDirectory status) ->
          pure
            ( Left
                ( TestArtifactIntentJournalStoreInvalid
                    "artifact intent journal directory must be a real directory"
                )
            )
      | otherwise -> do
          canonicalResult <- try (canonicalizePath path)
          case canonicalResult of
            Left (err :: IOException) ->
              pure (Left (TestArtifactIntentJournalIoFailure (show err)))
            Right canonicalDirectory
              | normalise canonicalDirectory /= normalise path ->
                  pure
                    ( Left
                        ( TestArtifactIntentJournalStoreInvalid
                            "artifact intent journal directory escapes the retained root"
                        )
                    )
              | otherwise -> do
                  secured <- try (setFileMode canonicalDirectory ownerModes)
                  case secured of
                    Left (err :: IOException) ->
                      pure (Left (TestArtifactIntentJournalIoFailure (show err)))
                    Right () -> do
                      finalStatus <- try (getSymbolicLinkStatus canonicalDirectory)
                      pure $ case finalStatus of
                        Left (err :: IOException) ->
                          Left (TestArtifactIntentJournalIoFailure (show err))
                        Right finalDirectoryStatus
                          | exactMode ownerModes finalDirectoryStatus -> Right store
                          | otherwise ->
                              Left
                                ( TestArtifactIntentJournalDirectoryModeInvalid
                                    canonicalDirectory
                                )

acquireTestArtifactIntentJournalLock
  :: TestArtifactIntentJournalStore
  -> IO
       ( Either
           TestArtifactIntentJournalError
           HeldTestArtifactIntentJournalLock
       )
acquireTestArtifactIntentJournalLock store = do
  let path = journalLockPath store
  locallyAcquired <-
    modifyMVar processTestArtifactIntentJournalLocks $ \held ->
      if Set.member path held
        then pure (held, False)
        else pure (Set.insert path held, True)
  if not locallyAcquired
    then pure (Left TestArtifactIntentJournalAlreadyLocked)
    else do
      opened <-
        try
          ( ( openFd
                path
                ReadWrite
                defaultFileFlags
                  { creat = Just ownerFileMode
                  , nofollow = True
                  , cloexec = True
                  }
            )
              `onException` releaseProcessTestArtifactIntentJournalLock path
          )
      case opened of
        Left (err :: IOException) ->
          pure (Left (TestArtifactIntentJournalIoFailure (show err)))
        Right fd ->
          secureAndLock path fd
            `onException` cleanupTestArtifactIntentJournalLockAcquisition path fd
 where
  secureAndLock path fd = do
    statusResult <- try (getFdStatus fd)
    case statusResult of
      Left (err :: IOException) ->
        cleanupAndReturn
          path
          fd
          (TestArtifactIntentJournalIoFailure (show err))
      Right status
        | not (isRegularFile status) ->
            cleanupAndReturn
              path
              fd
              (TestArtifactIntentJournalFileNotRegular path)
        | otherwise -> do
            secured <- try (setFdMode fd ownerFileMode)
            case secured of
              Left (err :: IOException) ->
                cleanupAndReturn
                  path
                  fd
                  (TestArtifactIntentJournalIoFailure (show err))
              Right () -> do
                securedStatus <- try (getFdStatus fd)
                case securedStatus of
                  Left (err :: IOException) ->
                    cleanupAndReturn
                      path
                      fd
                      (TestArtifactIntentJournalIoFailure (show err))
                  Right finalStatus
                    | not (exactMode ownerFileMode finalStatus) ->
                        cleanupAndReturn
                          path
                          fd
                          (TestArtifactIntentJournalFileModeInvalid path)
                    | otherwise -> do
                        locked <-
                          try (setLock fd (WriteLock, AbsoluteSeek, 0, 0))
                        case locked of
                          Left (_ :: IOException) ->
                            cleanupAndReturn
                              path
                              fd
                              TestArtifactIntentJournalAlreadyLocked
                          Right () ->
                            pure
                              ( Right
                                  HeldTestArtifactIntentJournalLock
                                    { heldTestArtifactIntentJournalLockPath = path
                                    , heldTestArtifactIntentJournalLockFd = fd
                                    }
                              )
  cleanupAndReturn path fd err = do
    cleanupTestArtifactIntentJournalLockAcquisition path fd
    pure (Left err)

releaseTestArtifactIntentJournalLock
  :: HeldTestArtifactIntentJournalLock -> IO ()
releaseTestArtifactIntentJournalLock held =
  ( do
      _ <-
        try
          ( setLock
              (heldTestArtifactIntentJournalLockFd held)
              (Unlock, AbsoluteSeek, 0, 0)
          )
          :: IO (Either IOException ())
      pure ()
  )
    `finally` ( safeCloseFd (heldTestArtifactIntentJournalLockFd held)
                  `finally` releaseProcessTestArtifactIntentJournalLock
                    (heldTestArtifactIntentJournalLockPath held)
              )

cleanupTestArtifactIntentJournalLockAcquisition
  :: FilePath -> Fd -> IO ()
cleanupTestArtifactIntentJournalLockAcquisition path fd =
  safeCloseFd fd
    `finally` releaseProcessTestArtifactIntentJournalLock path

releaseProcessTestArtifactIntentJournalLock :: FilePath -> IO ()
releaseProcessTestArtifactIntentJournalLock path =
  modifyMVar_ processTestArtifactIntentJournalLocks (pure . Set.delete path)

safeCloseFd :: Fd -> IO ()
safeCloseFd fd = do
  _ <- try (closeFd fd) :: IO (Either IOException ())
  pure ()

readStoredArtifactIntent
  :: FilePath
  -> IO (Either TestArtifactIntentJournalError StoredArtifactIntent)
readStoredArtifactIntent path = do
  result <-
    try
      ( bracket
          ( openFd
              path
              ReadOnly
              defaultFileFlags
                { nofollow = True
                , cloexec = True
                }
          )
          safeCloseFd
          (readOpenArtifactIntent path)
      )
  pure $ case result of
    Left (err :: IOException)
      | isDoesNotExistError err -> Right StoredArtifactIntentMissing
      | otherwise -> Left (TestArtifactIntentJournalIoFailure (show err))
    Right value -> value

readOpenArtifactIntent
  :: FilePath
  -> Fd
  -> IO (Either TestArtifactIntentJournalError StoredArtifactIntent)
readOpenArtifactIntent path fd = do
  status <- getFdStatus fd
  if not (isRegularFile status)
    then pure (Left (TestArtifactIntentJournalFileNotRegular path))
    else
      if not (exactMode ownerFileMode status)
        then pure (Left (TestArtifactIntentJournalFileModeInvalid path))
        else case boundedFileSize status of
          Left err -> pure (Left err)
          Right () -> do
            bytes <-
              readFdBounded fd (maximumTestArtifactIntentJournalBytes + 1)
            pure $ do
              if ByteString.length bytes > maximumTestArtifactIntentJournalBytes
                then
                  Left
                    ( TestArtifactIntentJournalEncodedTooLarge
                        (ByteString.length bytes)
                        maximumTestArtifactIntentJournalBytes
                    )
                else Right ()
              plan <- decodeTestArtifactIntentPlan bytes
              Right (StoredArtifactIntentPresent bytes plan)

exactMode :: FileMode -> FileStatus -> Bool
exactMode expected status =
  fileMode status `intersectFileModes` accessModes == expected

boundedFileSize
  :: FileStatus -> Either TestArtifactIntentJournalError ()
boundedFileSize status
  | toInteger (fileSize status) < 0 =
      Left
        ( TestArtifactIntentJournalDecodeInvalid
            "artifact intent file reported a negative size"
        )
  | toInteger (fileSize status)
      > toInteger maximumTestArtifactIntentJournalBytes =
      Left
        ( TestArtifactIntentJournalEncodedTooLarge
            (fromInteger (toInteger (fileSize status)))
            maximumTestArtifactIntentJournalBytes
        )
  | otherwise = Right ()

readFdBounded :: Fd -> Int -> IO ByteString
readFdBounded fd maximumBytes = go maximumBytes []
 where
  go remaining chunks
    | remaining <= 0 = pure (ByteString.concat (reverse chunks))
    | otherwise = do
        readResult <-
          try
            ( PosixByteString.fdRead
                fd
                (fromIntegral (min remaining (64 * 1024)))
            )
        case readResult of
          Left (err :: IOException)
            | isEOFError err ->
                pure (ByteString.concat (reverse chunks))
            | otherwise -> throwIO err
          Right chunk
            | ByteString.null chunk ->
                pure (ByteString.concat (reverse chunks))
            | otherwise ->
                go
                  (remaining - ByteString.length chunk)
                  (chunk : chunks)

atomicPersistAndReadBack
  :: TestArtifactIntentJournalStore
  -> ByteString
  -> TestArtifactCleanupPlan
  -> IO (Either TestArtifactIntentJournalError ())
atomicPersistAndReadBack store expectedBytes expected = do
  persisted <- atomicPersist store expectedBytes expected
  case persisted of
    Left err -> pure (Left err)
    Right () ->
      durabilityReadBack
        store
        ( testArtifactIntentJournalPath
            store
            (testArtifactCleanupPlanRunId expected)
        )
        expectedBytes
        expected

atomicPersist
  :: TestArtifactIntentJournalStore
  -> ByteString
  -> TestArtifactCleanupPlan
  -> IO (Either TestArtifactIntentJournalError ())
atomicPersist store expectedBytes expected = do
  let runId = testArtifactCleanupPlanRunId expected
      temporaryPath = testArtifactIntentJournalTemporaryPath store runId
      activePath = testArtifactIntentJournalPath store runId
  temporary <- readStoredArtifactIntent temporaryPath
  prepared <- case temporary of
    Left err -> pure (Left err)
    Right StoredArtifactIntentMissing ->
      writeArtifactIntentTemporary temporaryPath expectedBytes
    Right stored
      | exactStoredArtifactIntent expectedBytes expected stored ->
          syncArtifactIntentFile temporaryPath
      | otherwise -> pure (Left TestArtifactIntentJournalTemporaryConflict)
  case prepared of
    Left err -> pure (Left err)
    Right () -> do
      active <- readStoredArtifactIntent activePath
      case active of
        Left err -> pure (Left err)
        Right StoredArtifactIntentMissing -> do
          published <-
            try . mask_ $ do
              renameFile temporaryPath activePath
              syncTestArtifactIntentJournalDirectory store
          pure $ case published of
            Left (err :: IOException) ->
              Left (TestArtifactIntentJournalIoFailure (show err))
            Right () -> Right ()
        Right stored
          | exactStoredArtifactIntent expectedBytes expected stored ->
              pure (Right ())
          | otherwise ->
              pure (Left TestArtifactIntentJournalActiveConflict)

writeArtifactIntentTemporary
  :: FilePath
  -> ByteString
  -> IO (Either TestArtifactIntentJournalError ())
writeArtifactIntentTemporary path bytes = do
  written <-
    try . mask_ $
      bracket
        ( openFd
            path
            WriteOnly
            defaultFileFlags
              { exclusive = True
              , creat = Just ownerFileMode
              , nofollow = True
              , cloexec = True
              }
        )
        safeCloseFd
        ( \fd -> do
            setFdMode fd ownerFileMode
            status <- getFdStatus fd
            unless (isRegularFile status) $ do
              ioError
                ( userError
                    "artifact intent temporary path is not a regular file"
                )
            unless (exactMode ownerFileMode status) $ do
              ioError
                ( userError
                    "artifact intent temporary path mode is not 0600"
                )
            writeAll fd bytes
            fileSynchronise fd
        )
  pure $ case written of
    Left (err :: IOException) ->
      Left (TestArtifactIntentJournalIoFailure (show err))
    Right () -> Right ()

writeAll :: Fd -> ByteString -> IO ()
writeAll _ bytes | ByteString.null bytes = pure ()
writeAll fd bytes = do
  written <- PosixByteString.fdWrite fd bytes
  let count = fromIntegral written
  if count <= 0
    then ioError (userError "artifact intent write made no progress")
    else writeAll fd (ByteString.drop count bytes)

syncArtifactIntentFile
  :: FilePath -> IO (Either TestArtifactIntentJournalError ())
syncArtifactIntentFile path = do
  synced <-
    try
      ( bracket
          ( openFd
              path
              ReadOnly
              defaultFileFlags
                { nofollow = True
                , cloexec = True
                }
          )
          safeCloseFd
          ( \fd -> do
              status <- getFdStatus fd
              unless (isRegularFile status) $ do
                ioError (userError "artifact intent path is not a regular file")
              unless (exactMode ownerFileMode status) $ do
                ioError (userError "artifact intent path mode is not 0600")
              fileSynchronise fd
          )
      )
  pure $ case synced of
    Left (err :: IOException) ->
      Left (TestArtifactIntentJournalIoFailure (show err))
    Right () -> Right ()

durabilityReadBack
  :: TestArtifactIntentJournalStore
  -> FilePath
  -> ByteString
  -> TestArtifactCleanupPlan
  -> IO (Either TestArtifactIntentJournalError ())
durabilityReadBack store path expectedBytes expected = do
  synced <- syncArtifactIntentFile path
  case synced of
    Left err -> pure (Left err)
    Right () -> do
      directorySynced <-
        try (syncTestArtifactIntentJournalDirectory store)
      case directorySynced of
        Left (err :: IOException) ->
          pure (Left (TestArtifactIntentJournalIoFailure (show err)))
        Right () -> do
          observed <- readStoredArtifactIntent path
          pure $ case observed of
            Right stored
              | exactStoredArtifactIntent expectedBytes expected stored ->
                  Right ()
            Left err -> Left err
            _ -> Left TestArtifactIntentJournalReadBackMismatch

syncTestArtifactIntentJournalDirectory
  :: TestArtifactIntentJournalStore -> IO ()
syncTestArtifactIntentJournalDirectory store =
  bracket
    ( openFd
        (testArtifactIntentJournalDirectory store)
        ReadOnly
        defaultFileFlags
          { directory = True
          , nofollow = True
          , cloexec = True
          }
    )
    safeCloseFd
    fileSynchronise

-- | Retire only the exact stored plan bound to opaque cascade completion
-- evidence.  The adapter performs its own nofollow lstat read-back of both
-- artifact paths immediately before the durable move and again before
-- returning success; no phase flag or caller-supplied boolean participates.
retireTestArtifactIntentPlan
  :: TestArtifactIntentJournalStore
  -> TestArtifactCleanupPlan
  -> CascadeCompleteEvidence
  -> IO
       ( Either
           TestArtifactIntentJournalError
           TestArtifactIntentRetirement
       )
retireTestArtifactIntentPlan store expected completion
  | cascadeCompleteRunId completion /= expectedRunId =
      pure
        ( Left
            ( TestArtifactIntentJournalProofRunMismatch
                expectedRunId
                (cascadeCompleteRunId completion)
            )
        )
  | cascadeCompleteGraphDigest completion /= expectedGraphDigest =
      pure
        ( Left
            ( TestArtifactIntentJournalProofGraphMismatch
                expectedGraphDigest
                (cascadeCompleteGraphDigest completion)
            )
        )
  | otherwise = case encodeTestArtifactIntentPlan expected of
      Left err -> pure (Left err)
      Right expectedBytes ->
        withTestArtifactIntentJournalLock store $ \preparedStore -> do
          absentBefore <- observeEveryArtifactAbsent expected
          case absentBefore of
            Left err -> pure (Left err)
            Right () ->
              retireExactStoredPlan
                preparedStore
                expectedBytes
                expected
 where
  expectedRunId = testArtifactCleanupPlanRunId expected
  expectedGraphDigest = testArtifactCleanupPlanGraphDigest expected

-- | Fixed package-owned retirement regression.  Its constructor is private,
-- and the function returns only booleans, so no completion proof or raw
-- cascade fixture crosses the public package boundary.
data TestArtifactIntentJournalRegression = TestArtifactIntentJournalRegression
  { testArtifactIntentJournalRegressionWrongRunRefused :: !Bool
  , testArtifactIntentJournalRegressionWrongGraphRefused :: !Bool
  , testArtifactIntentJournalRegressionPresentRefused :: !Bool
  , testArtifactIntentJournalRegressionDurableRetirement :: !Bool
  , testArtifactIntentJournalRegressionExactReplay :: !Bool
  }

fixedTestArtifactIntentJournalRegression
  :: IO (Either Text TestArtifactIntentJournalRegression)
fixedTestArtifactIntentJournalRegression =
  case withFixedCascadeEvidenceFixtureInternal
    ( \_ _ _ _ completion ->
        withCascadeEvidenceFixtureForRunInternal
          "cleanup-run/test-artifact-journal-other"
          ( \_ _ _ _ otherCompletion ->
              runFixedTestArtifactIntentJournalRegression
                completion
                otherCompletion
          )
    ) of
    Left err -> pure (Left err)
    Right (Left err) -> pure (Left err)
    Right (Right action) -> action

runFixedTestArtifactIntentJournalRegression
  :: CascadeCompleteEvidence
  -> CascadeCompleteEvidence
  -> IO (Either Text TestArtifactIntentJournalRegression)
runFixedTestArtifactIntentJournalRegression completion otherCompletion =
  withSystemTempDirectory "prodbox-artifact-journal-fixed" $ \root ->
    case fixedInputs root of
      Left err -> pure (Left err)
      Right (store, plan, wrongGraphPlan) -> do
        committed <- commitTestArtifactIntentPlan store plan
        case committed of
          Left err -> pure (Left (renderTestArtifactIntentJournalError err))
          Right () -> do
            wrongRun <- retireTestArtifactIntentPlan store plan otherCompletion
            wrongGraph <-
              retireTestArtifactIntentPlan store wrongGraphPlan completion
            let configPath =
                  testArtifactIntentPath
                    (NonEmpty.head (testArtifactCleanupPlanIntents plan))
            createDirectoryIfMissing True (takeDirectory configPath)
            ByteString.writeFile configPath "still-present"
            present <- retireTestArtifactIntentPlan store plan completion
            removeFile configPath
            retired <- retireTestArtifactIntentPlan store plan completion
            replayed <- retireTestArtifactIntentPlan store plan completion
            let activePath =
                  testArtifactIntentJournalPath
                    store
                    (testArtifactCleanupPlanRunId plan)
            activeExists <- doesFileExist activePath
            archiveExists <- case retired of
              Left _ -> pure False
              Right retirement ->
                doesFileExist (retiredTestArtifactIntentArchivePath retirement)
            pure
              ( Right
                  TestArtifactIntentJournalRegression
                    { testArtifactIntentJournalRegressionWrongRunRefused =
                        isWrongRunRefusal wrongRun
                    , testArtifactIntentJournalRegressionWrongGraphRefused =
                        isWrongGraphRefusal wrongGraph
                    , testArtifactIntentJournalRegressionPresentRefused =
                        isPresentRefusal configPath present
                    , testArtifactIntentJournalRegressionDurableRetirement =
                        not activeExists && archiveExists && isRetired retired
                    , testArtifactIntentJournalRegressionExactReplay =
                        replayed == retired && isRetired replayed
                    }
              )
 where
  fixedInputs root = do
    store <-
      mapFixedLeft
        renderTestArtifactIntentJournalError
        (mkTestArtifactIntentJournalStore root)
    plan <- fixedJournalPlan (root </> "repo") completion
    wrongGraphPlan <-
      mapFixedLeft
        (Text.pack . show)
        ( mkTestArtifactCleanupPlan
            (root </> "wrong-graph-repo")
            (cascadeCompleteRunId completion)
            (cascadeCompleteGraphDigest otherCompletion)
            (root </> "wrong-graph-repo" </> ".build" </> "prodbox.dhall")
            ( root
                </> "wrong-graph-repo"
                </> ".test-data"
                </> "suite"
                </> "case"
            )
        )
    Right (store, plan, wrongGraphPlan)

fixedJournalPlan
  :: FilePath
  -> CascadeCompleteEvidence
  -> Either Text TestArtifactCleanupPlan
fixedJournalPlan root completion =
  mapFixedLeft
    (Text.pack . show)
    ( mkTestArtifactCleanupPlan
        root
        (cascadeCompleteRunId completion)
        (cascadeCompleteGraphDigest completion)
        (root </> ".build" </> "prodbox.dhall")
        (root </> ".test-data" </> "suite" </> "case")
    )

mapFixedLeft :: (left -> other) -> Either left value -> Either other value
mapFixedLeft transform result = case result of
  Left err -> Left (transform err)
  Right value -> Right value

isWrongRunRefusal
  :: Either TestArtifactIntentJournalError value -> Bool
isWrongRunRefusal result = case result of
  Left TestArtifactIntentJournalProofRunMismatch {} -> True
  _ -> False

isWrongGraphRefusal
  :: Either TestArtifactIntentJournalError value -> Bool
isWrongGraphRefusal result = case result of
  Left TestArtifactIntentJournalProofGraphMismatch {} -> True
  _ -> False

isPresentRefusal
  :: FilePath
  -> Either TestArtifactIntentJournalError value
  -> Bool
isPresentRefusal expectedPath result = case result of
  Left
    ( TestArtifactIntentJournalArtifactStillPresent
        TestArtifactGeneratedRunConfig
        actualPath
      ) -> actualPath == expectedPath
  _ -> False

isRetired :: Either TestArtifactIntentJournalError value -> Bool
isRetired result = case result of
  Right _ -> True
  Left _ -> False

retireExactStoredPlan
  :: TestArtifactIntentJournalStore
  -> ByteString
  -> TestArtifactCleanupPlan
  -> IO
       ( Either
           TestArtifactIntentJournalError
           TestArtifactIntentRetirement
       )
retireExactStoredPlan store expectedBytes expected =
  case testArtifactIntentJournalRetiredPath store expected of
    Left err -> pure (Left err)
    Right archivePath -> do
      let activePath =
            testArtifactIntentJournalPath
              store
              (testArtifactCleanupPlanRunId expected)
      active <- readStoredArtifactIntent activePath
      archived <- readStoredArtifactIntent archivePath
      case (active, archived) of
        (Left err, _) -> pure (Left err)
        (_, Left err) -> pure (Left err)
        ( Right StoredArtifactIntentMissing
          , Right StoredArtifactIntentMissing
          ) -> pure (Left TestArtifactIntentJournalMissing)
        (Right StoredArtifactIntentMissing, Right archive)
          | exactStoredArtifactIntent expectedBytes expected archive ->
              finishTestArtifactIntentRetirement
                store
                activePath
                archivePath
                expectedBytes
                expected
          | otherwise ->
              pure
                (Left TestArtifactIntentJournalRetirementArchiveConflict)
        (Right activeIntent, Right archive)
          | not
              ( exactStoredArtifactIntent
                  expectedBytes
                  expected
                  activeIntent
              ) ->
              pure (Left TestArtifactIntentJournalActiveConflict)
          | otherwise -> case archive of
              StoredArtifactIntentPresent archiveBytes archiveIntent
                | archiveBytes /= expectedBytes
                    || archiveIntent /= expected ->
                    pure
                      ( Left
                          TestArtifactIntentJournalRetirementArchiveConflict
                      )
              _ -> do
                moved <-
                  durableRetireTestArtifactIntent
                    store
                    activePath
                    archivePath
                    ( case archive of
                        StoredArtifactIntentMissing ->
                          PublishRetirementArchive
                        StoredArtifactIntentPresent {} ->
                          ReuseExactRetirementArchive
                    )
                case moved of
                  Left err -> pure (Left err)
                  Right () ->
                    finishTestArtifactIntentRetirement
                      store
                      activePath
                      archivePath
                      expectedBytes
                      expected

finishTestArtifactIntentRetirement
  :: TestArtifactIntentJournalStore
  -> FilePath
  -> FilePath
  -> ByteString
  -> TestArtifactCleanupPlan
  -> IO
       ( Either
           TestArtifactIntentJournalError
           TestArtifactIntentRetirement
       )
finishTestArtifactIntentRetirement
  store
  activePath
  archivePath
  expectedBytes
  expected = do
    synced <- try (syncTestArtifactIntentJournalDirectory store)
    case synced of
      Left (err :: IOException) ->
        pure (Left (TestArtifactIntentJournalIoFailure (show err)))
      Right () -> do
        active <- readStoredArtifactIntent activePath
        archive <- readStoredArtifactIntent archivePath
        case (active, archive) of
          (Right StoredArtifactIntentMissing, Right storedArchive)
            | exactStoredArtifactIntent
                expectedBytes
                expected
                storedArchive -> do
                absentAfter <- observeEveryArtifactAbsent expected
                pure $ do
                  absentAfter
                  pathSetDigest <- testArtifactIntentPathSetDigest expected
                  Right
                    TestArtifactIntentRetirement
                      { internalRetiredTestArtifactIntentRunId =
                          testArtifactCleanupPlanRunId expected
                      , internalRetiredTestArtifactIntentGraphDigest =
                          testArtifactCleanupPlanGraphDigest expected
                      , internalRetiredTestArtifactIntentPathSetDigest =
                          pathSetDigest
                      , internalRetiredTestArtifactIntentContentDigest =
                          TextEncoding.decodeUtf8 (hexSha256 expectedBytes)
                      , internalRetiredTestArtifactIntentArchivePath =
                          archivePath
                      }
          (Left err, _) -> pure (Left err)
          (_, Left err) -> pure (Left err)
          (_, Right StoredArtifactIntentMissing) ->
            pure
              ( Left
                  ( TestArtifactIntentJournalIoFailure
                      ( "retirement archive missing after durable move: "
                          ++ archivePath
                      )
                  )
              )
          _ ->
            pure
              (Left TestArtifactIntentJournalRetirementArchiveConflict)

durableRetireTestArtifactIntent
  :: TestArtifactIntentJournalStore
  -> FilePath
  -> FilePath
  -> RetirementArchiveDisposition
  -> IO (Either TestArtifactIntentJournalError ())
durableRetireTestArtifactIntent store activePath archivePath disposition = do
  result <- try . mask_ $ do
    case disposition of
      PublishRetirementArchive -> do
        createLink activePath archivePath
        syncTestArtifactIntentJournalDirectory store
      ReuseExactRetirementArchive -> pure ()
    removeLink activePath
    syncTestArtifactIntentJournalDirectory store
  pure $ case result of
    Left (err :: IOException) ->
      Left (TestArtifactIntentJournalIoFailure (show err))
    Right () -> Right ()

data RetirementArchiveDisposition
  = PublishRetirementArchive
  | ReuseExactRetirementArchive

observeEveryArtifactAbsent
  :: TestArtifactCleanupPlan
  -> IO (Either TestArtifactIntentJournalError ())
observeEveryArtifactAbsent plan =
  observeAll (NonEmpty.toList (testArtifactCleanupPlanIntents plan))
 where
  observeAll [] = pure (Right ())
  observeAll (intent : remaining) = do
    observed <- observeArtifactAbsent intent
    case observed of
      Left err -> pure (Left err)
      Right () -> observeAll remaining

observeArtifactAbsent
  :: TestArtifactIntent
  -> IO (Either TestArtifactIntentJournalError ())
observeArtifactAbsent intent = do
  let kind = testArtifactIntentKind intent
      path = testArtifactIntentPath intent
  observed <- try (getSymbolicLinkStatus path)
  pure $ case observed of
    Left (err :: IOException)
      | isDoesNotExistError err -> Right ()
      | otherwise ->
          Left
            ( TestArtifactIntentJournalArtifactUnobservable
                kind
                path
                (show err)
            )
    Right _ ->
      Left
        ( TestArtifactIntentJournalArtifactStillPresent
            kind
            path
        )
