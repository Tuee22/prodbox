{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Bounded, append-only custody for non-secret scenario reports. The caller
-- must still obtain independent observations and validate the report against
-- its expected identity; a stored file is not evidence of an effect.
module Prodbox.Test.ScenarioEvidenceStore
  ( ScenarioStoreError (..)
  , ScenarioStoreValidationError (..)
  , writeScenarioReport
  , readScenarioReport
  , validateStoredScenarioReport
  )
where

import Control.Exception (IOException, bracket, mask, throwIO, try)
import Data.Bits ((.&.))
import Data.ByteString qualified as ByteString
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Foreign.C.Error (throwErrnoIfMinus1_)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..), CUInt (..))
import Prodbox.Config.DeploymentScope
  ( deploymentScope
  , scopeApiPort
  , scopeEnvironment
  , scopeIdentifier
  , validRootGeneration
  )
import Prodbox.Test.ScenarioEvidence
  ( EvidenceComparison
  , EvidenceComparisonError
  , IndependentScenarioObservation
  , ScenarioBinding (..)
  , ScenarioReport
  , ScenarioReportCodecError
  , compareScenarioEvidence
  , decodeScenarioReport
  , encodeScenarioReport
  , reportBinding
  )
import System.FilePath (isAbsolute, normalise, splitDirectories)
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError, isEOFError)
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
import System.Posix.Types (CMode (..), Fd (..), UserID)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

foreign import capi "sys/stat.h mkdirat"
  makeStoreDirectoryAt :: CInt -> CString -> CMode -> IO CInt
foreign import capi "stdio.h renameat2"
  publishStoreFileAt :: CInt -> CString -> CInt -> CString -> CUInt -> IO CInt
foreign import capi "stdio.h value RENAME_NOREPLACE" storeNoReplace :: CUInt

data ScenarioStoreError
  = ScenarioStoreUnsafe
  | ScenarioStoreMissing
  | ScenarioStoreExists
  | ScenarioStorePending
  | ScenarioStoreChanged
  | ScenarioStoreIncomplete
  | ScenarioStoreTimedOut
  | ScenarioStoreUnobservable
  | ScenarioStoreCodec !ScenarioReportCodecError
  deriving (Eq, Show)

data ScenarioStoreValidationError
  = ScenarioStoreReadFailure !ScenarioStoreError
  | ScenarioStoreComparisonFailure !EvidenceComparisonError
  deriving (Eq, Show)

-- The supplied action must perform independent observations of the actual
-- scope. The two report reads bracket that action but cannot prove a report
-- was unchanged between samples. This neither authenticates the action nor
-- performs it on behalf of an unfinished public scenario runner.
validateStoredScenarioReport
  :: FilePath
  -> ScenarioBinding
  -> [Text]
  -> IO (Maybe IndependentScenarioObservation)
  -> IO (Either ScenarioStoreValidationError EvidenceComparison)
validateStoredScenarioReport project expected required observe = do
  stored <- readScenarioReport project expected
  case stored of
    Left failure -> pure (Left (ScenarioStoreReadFailure failure))
    Right report -> do
      independent <- observe
      after <- readScenarioReport project expected
      pure $ case after of
        Left failure -> Left (ScenarioStoreReadFailure failure)
        Right later
          | later /= report -> Left (ScenarioStoreReadFailure ScenarioStoreChanged)
          | otherwise ->
              either
                (Left . ScenarioStoreComparisonFailure)
                Right
                (compareScenarioEvidence expected required (Just report) independent)

-- | Exclusively publish one report under the selected run. A failed or
-- interrupted publication leaves its deterministic pending file in place.
writeScenarioReport :: FilePath -> ScenarioReport -> IO (Either ScenarioStoreError ())
writeScenarioReport project report
  | not (scopeMatchesProject project (reportBinding report)) = pure (Left ScenarioStoreUnsafe)
  | otherwise = case encodeScenarioReport report of
      Left failure -> pure (Left (ScenarioStoreCodec failure))
      Right bytes -> do
        started <- newIORef False
        owner <- getEffectiveUserID
        result <- timeout storeTimeoutMicros $ try $ withStore True project binding $ \directory stable -> do
          ready <- stable
          if not ready
            then pure (Left ScenarioStoreChanged)
            else do
              exists <- namedExists directory finalName
              if exists
                then pure (Left ScenarioStoreExists)
                else mask $ \restore -> do
                  created <- try (Posix.openFdAt (Just directory) pendingName Posix.WriteOnly createFlags)
                  case created of
                    Left (failure :: IOException)
                      | isAlreadyExistsError failure -> pure (Left ScenarioStorePending)
                      | otherwise -> throwIO failure
                    Right descriptor -> do
                      writeIORef started True
                      bracket (pure descriptor) Posix.closeFd $ \file -> restore $ do
                        writeAll file bytes
                        fileSynchronise file
                        checked <- getFdStatus file
                        named <-
                          bracket
                            (Posix.openFdAt (Just directory) pendingName Posix.ReadOnly readFlags)
                            Posix.closeFd
                            getFdStatus
                        stableBeforePublish <- stable
                        if not (safeFile owner checked && sameVersion checked named && stableBeforePublish)
                          then pure (Left ScenarioStoreIncomplete)
                          else do
                            withCString pendingName $ \pending -> withCString finalName $ \final ->
                              throwErrnoIfMinus1_
                                "publish scenario report"
                                (publishStoreFileAt (fdNumber directory) pending (fdNumber directory) final storeNoReplace)
                            fileSynchronise directory
                            published <- getFdStatus file
                            readback <- readPublished directory finalName
                            namedFinal <-
                              bracket
                                (Posix.openFdAt (Just directory) finalName Posix.ReadOnly readFlags)
                                Posix.closeFd
                                getFdStatus
                            stableAfterPublish <- stable
                            pure $
                              if stableAfterPublish
                                && identity checked == identity published
                                && sameVersion published namedFinal
                                && readback == Right bytes
                                then Right ()
                                else Left ScenarioStoreIncomplete
        wasStarted <- readIORef started
        pure $ case result of
          Nothing -> Left (if wasStarted then ScenarioStoreIncomplete else ScenarioStoreTimedOut)
          Just (Left (_ :: IOException)) -> Left (if wasStarted then ScenarioStoreIncomplete else ScenarioStoreUnobservable)
          Just (Right value) -> value
 where
  binding = reportBinding report
  finalName = reportName binding
  pendingName = finalName ++ ".pending"

-- | Read and independently synchronize one exact published report. A missing
-- or changed directory never becomes a successful empty observation.
readScenarioReport :: FilePath -> ScenarioBinding -> IO (Either ScenarioStoreError ScenarioReport)
readScenarioReport project binding
  | not (scopeMatchesProject project binding) = pure (Left ScenarioStoreUnsafe)
  | otherwise = do
      result <- timeout storeTimeoutMicros $ try $ withStore False project binding $ \directory stable -> do
        ready <- stable
        if not ready
          then pure (Left ScenarioStoreChanged)
          else do
            bytes <- readPublished directory (reportName binding)
            final <- stable
            pure $ do
              if final then Right () else Left ScenarioStoreChanged
              content <- bytes
              either (Left . ScenarioStoreCodec) Right (decodeScenarioReport binding content)
      pure $ case result of
        Nothing -> Left ScenarioStoreTimedOut
        Just (Left (_ :: IOException)) -> Left ScenarioStoreUnobservable
        Just (Right value) -> value

-- A report may only be stored under the project anchor from which its exact
-- deployment coordinates were derived. This is a coordinate check; the
-- caller must still observe the scope root and authenticate execution.
scopeMatchesProject :: FilePath -> ScenarioBinding -> Bool
scopeMatchesProject project binding =
  deploymentScope project (scopeEnvironment scope) (scopeIdentifier scope) (scopeApiPort scope)
    == Right scope
 where
  scope = scenarioScope binding

storeTimeoutMicros :: Int
storeTimeoutMicros = 5000000

directoryFlags :: Posix.OpenFileFlags
directoryFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.directory = True}

readFlags :: Posix.OpenFileFlags
readFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}

createFlags :: Posix.OpenFileFlags
createFlags = readFlags {Posix.exclusive = True, Posix.creat = Just 0o600}

reportName :: ScenarioBinding -> FilePath
reportName binding =
  "phase-"
    ++ show (scenarioPhase binding)
    ++ "-case-"
    ++ show (scenarioCase binding)
    ++ "-operation-"
    ++ scenarioOperationId binding
    ++ ".json"

withStore
  :: Bool -> FilePath -> ScenarioBinding -> (Fd -> IO Bool -> IO value) -> IO value
withStore create project binding action = do
  if not (isAbsolute project)
    || project == "/"
    || normalise project /= project
    || any (`elem` ("." : ".." : privateComponents)) (splitDirectories project)
    || not
      (validRootGeneration (scenarioRunId binding) && validRootGeneration (scenarioOperationId binding))
    then ioError (userError "unsafe scenario store location")
    else do
      owner <- getEffectiveUserID
      walk owner create project (scenarioRunId binding) $ \held identities ->
        action held $ do
          fresh <- try (walk owner False project (scenarioRunId binding) $ \_ current -> pure current)
          status <- try (getFdStatus held)
          pure $ case (fresh, status) of
            (Right current, Right heldStatus) -> current == identities && safeDirectory owner heldStatus
            (_ :: Either IOException [(Integer, Integer)], _ :: Either IOException FileStatus) -> False

privateComponents :: [FilePath]
privateComponents = [".build", ".data", ".test-data", ".git", ".secrets", ".prodbox-state"]

walk
  :: UserID -> Bool -> FilePath -> String -> (Fd -> [(Integer, Integer)] -> IO value) -> IO value
walk owner create project runId action =
  bracket (Posix.openFd "/" Posix.ReadOnly directoryFlags) Posix.closeFd $ \root ->
    descend root (filter (/= "/") (splitDirectories project)) []
 where
  descend current components identities = do
    status <- getFdStatus current
    if not (isDirectory status)
      then ioError (userError "invalid scenario store ancestor")
      else case components of
        [] -> do
          if not (safeDirectory owner status) then ioError (userError "unsafe project root") else pure ()
          storeChildren current [".build", "scenario-evidence", runId] (identity status : identities)
        name : rest ->
          bracket (Posix.openFdAt (Just current) name Posix.ReadOnly directoryFlags) Posix.closeFd $ \next ->
            descend next rest (identity status : identities)
  storeChildren current components identities = case components of
    [] -> action current (reverse identities)
    name : rest -> do
      if create && name /= ".build" then ensureDirectory current name else pure ()
      bracket (Posix.openFdAt (Just current) name Posix.ReadOnly directoryFlags) Posix.closeFd $ \next -> do
        status <- getFdStatus next
        if safeDirectory owner status
          then do
            fileSynchronise current
            storeChildren next rest (identity status : identities)
          else ioError (userError "unsafe scenario store directory")

ensureDirectory :: Fd -> FilePath -> IO ()
ensureDirectory parent name = do
  created <- try $ withCString name $ \component ->
    throwErrnoIfMinus1_
      "create scenario store directory"
      (makeStoreDirectoryAt (fdNumber parent) component 0o700)
  case created of
    Right () -> fileSynchronise parent
    Left (failure :: IOException)
      | isAlreadyExistsError failure -> pure ()
      | otherwise -> throwIO failure

namedExists :: Fd -> FilePath -> IO Bool
namedExists parent name = do
  attempted <-
    try
      (bracket (Posix.openFdAt (Just parent) name Posix.ReadOnly readFlags) Posix.closeFd (const (pure ())))
  case attempted of
    Right () -> pure True
    Left (failure :: IOException)
      | isDoesNotExistError failure -> pure False
      | otherwise -> throwIO failure

readPublished :: Fd -> FilePath -> IO (Either ScenarioStoreError ByteString.ByteString)
readPublished parent name = do
  owner <- getEffectiveUserID
  result <- try $ bracket (Posix.openFdAt (Just parent) name Posix.ReadOnly readFlags) Posix.closeFd $ \file -> do
    before <- getFdStatus file
    if not (safeFile owner before)
      then pure (Left ScenarioStoreUnsafe)
      else do
        bytes <- readBounded file [] 0
        fileSynchronise file
        fileSynchronise parent
        after <- getFdStatus file
        named <-
          bracket (Posix.openFdAt (Just parent) name Posix.ReadOnly readFlags) Posix.closeFd getFdStatus
        pure $
          if sameVersion before after
            && sameVersion after named
            && fromIntegral (ByteString.length bytes) == fileSize after
            then Right bytes
            else Left ScenarioStoreChanged
  pure $ case result of
    Left (failure :: IOException)
      | isDoesNotExistError failure -> Left ScenarioStoreMissing
      | otherwise -> Left ScenarioStoreUnobservable
    Right value -> value

safeDirectory :: UserID -> FileStatus -> Bool
safeDirectory owner status = isDirectory status && fileOwner status == owner && fileMode status .&. 0o022 == 0

safeFile :: UserID -> FileStatus -> Bool
safeFile owner status =
  isRegularFile status
    && owner == fileOwner status
    && fileMode status .&. 0o077 == 0
    && linkCount status == 1
    && fileSize status >= 0
    && fileSize status <= 65536

identity :: FileStatus -> (Integer, Integer)
identity status = (toInteger (deviceID status), toInteger (fileID status))

sameVersion :: FileStatus -> FileStatus -> Bool
sameVersion left right =
  identity left == identity right
    && fileSize left == fileSize right
    && fileMode left == fileMode right
    && fileOwner left == fileOwner right
    && linkCount left == linkCount right
    && modificationTimeHiRes left == modificationTimeHiRes right
    && statusChangeTimeHiRes left == statusChangeTimeHiRes right

fdNumber :: Fd -> CInt
fdNumber (Fd value) = value

writeAll :: Fd -> ByteString.ByteString -> IO ()
writeAll descriptor bytes
  | ByteString.null bytes = pure ()
  | otherwise = do
      count <- PosixBytes.fdWrite descriptor bytes
      if count <= 0
        then ioError (userError "short scenario report write")
        else writeAll descriptor (ByteString.drop (fromIntegral count) bytes)

readBounded :: Fd -> [ByteString.ByteString] -> Int -> IO ByteString.ByteString
readBounded descriptor chunks count
  | count > 65536 = ioError (userError "scenario report exceeds size limit")
  | otherwise = do
      result <- try (PosixBytes.fdRead descriptor (fromIntegral (65537 - count)))
      case result of
        Left (failure :: IOException) | isEOFError failure -> pure (ByteString.concat (reverse chunks))
        Left failure -> throwIO failure
        Right bytes
          | ByteString.null bytes -> pure (ByteString.concat (reverse chunks))
          | otherwise -> readBounded descriptor (bytes : chunks) (count + ByteString.length bytes)
