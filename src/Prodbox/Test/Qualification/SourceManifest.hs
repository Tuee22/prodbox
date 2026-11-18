{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

-- | Filesystem recorder for the secret-safe Standard-P source identity.
--
-- Git supplies the tracked plus non-ignored-untracked path inventory and the
-- whole-worktree dirty bit. Every candidate is classified against the positive
-- manifest policy before opening it; ignored/configured secret roots and build
-- roots therefore never enter a read or digest operation.
module Prodbox.Test.Qualification.SourceManifest
  ( SourceManifestCaptureError (..)
  , captureSourceIdentity
  , captureSourceIdentityPair
  , captureAwsLifecycleSourceIdentity
  , captureCommittedSourceIdentity
  , captureSourceCandidate
  , captureWorktreeInputs
  , SourceCaptureLimits (..)
  , captureWorktreeInputsBounded
  )
where

import Control.Exception (bracket)
import Data.Bits ((.&.))
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word32)
import Prodbox.Result (Result (..))
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessBounded
  , captureSubprocessResult
  )
import Prodbox.Test.Qualification.SourceIdentity
  ( GitHead
  , ManifestFileType (..)
  , SourceCandidate (..)
  , SourceIdentity
  , SourceIdentityError
  , SourcePathDisposition (..)
  , SourceScope (..)
  , WorktreeState (..)
  , classifySourcePath
  , mkAwsLifecycleSourceIdentity
  , mkGitHead
  , mkScopedSourceIdentity
  , mkSourceIdentity
  )
import System.Directory (makeAbsolute)
import System.Exit (ExitCode (..))
import System.FilePath (normalise, splitDirectories, (</>))
import System.IO.Error (isEOFError, tryIOError)
import System.Posix.Files
  ( FileStatus
  , deviceID
  , fileID
  , fileMode
  , fileOwner
  , fileSize
  , getFdStatus
  , getSymbolicLinkStatus
  , isDirectory
  , isRegularFile
  , isSymbolicLink
  , linkCount
  , modificationTimeHiRes
  , readSymbolicLink
  , statusChangeTimeHiRes
  )
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as PosixBytes
import System.Posix.Types (Fd (..))
import System.Timeout (timeout)

data SourceManifestCaptureError
  = SourceManifestGitFailed !String
  | SourceManifestIdentityRejected !SourceIdentityError
  | SourceManifestExcludedTrackedInput !Text
  | SourceManifestFileReadFailed !FilePath !String
  | SourceManifestUnsupportedFileType !FilePath
  | SourceManifestUnsafeFile !FilePath
  | SourceManifestBudgetExceeded
  | SourceManifestCaptureTimedOut
  | SourceManifestTreeDecodeFailed !String
  | SourceManifestUnsupportedGitEntry !Text !Text !Text
  deriving stock (Eq, Show)

captureSourceIdentity
  :: FilePath
  -> [Text]
  -> IO (Either SourceManifestCaptureError SourceIdentity)
captureSourceIdentity repoRoot configuredSecretRoots = do
  inputs <- captureWorktreeInputs repoRoot configuredSecretRoots
  pure (inputs >>= identityOver FullSurface configuredSecretRoots)

-- | The full-surface and executable-surface identities of one capture: the
-- worktree is read once, so the two describe the same bytes and a file that
-- changes between two reads cannot make them disagree about what they saw.
captureSourceIdentityPair
  :: FilePath
  -> [Text]
  -> IO (Either SourceManifestCaptureError (SourceIdentity, SourceIdentity))
captureSourceIdentityPair repoRoot configuredSecretRoots = do
  inputs <- captureWorktreeInputs repoRoot configuredSecretRoots
  pure $ do
    captured <- inputs
    full <- identityOver FullSurface configuredSecretRoots captured
    executable <- identityOver ExecutableSurface configuredSecretRoots captured
    Right (full, executable)

-- | The AWS stack lifecycle's scoped identity of the current worktree. Every
-- candidate is classified exactly as for the full identity; only the scoped
-- paths are hashed.
captureAwsLifecycleSourceIdentity
  :: FilePath
  -> [Text]
  -> IO (Either SourceManifestCaptureError SourceIdentity)
captureAwsLifecycleSourceIdentity repoRoot configuredSecretRoots = do
  inputs <- captureWorktreeInputs repoRoot configuredSecretRoots
  pure $ do
    (gitHead, worktree, candidates) <- inputs
    either
      (Left . SourceManifestIdentityRejected)
      Right
      (mkAwsLifecycleSourceIdentity gitHead worktree configuredSecretRoots candidates)

identityOver
  :: SourceScope
  -> [Text]
  -> (GitHead, WorktreeState, [SourceCandidate])
  -> Either SourceManifestCaptureError SourceIdentity
identityOver scope configuredSecretRoots (gitHead, worktree, candidates) =
  either
    (Left . SourceManifestIdentityRejected)
    Right
    (mkScopedSourceIdentity scope gitHead worktree configuredSecretRoots candidates)

-- | The head, the dirty bit and the candidate bytes of the worktree.
captureWorktreeInputs
  :: FilePath
  -> [Text]
  -> IO (Either SourceManifestCaptureError (GitHead, WorktreeState, [SourceCandidate]))
captureWorktreeInputs repoRoot configuredSecretRoots = do
  headResult <- runGit repoRoot ["rev-parse", "--verify", "HEAD"]
  statusResult <- runGit repoRoot ["status", "--porcelain=v1", "--untracked-files=all"]
  pathsResult <- runGit repoRoot ["ls-files", "-z", "--cached", "--others", "--exclude-standard"]
  deletedResult <- runGit repoRoot ["ls-files", "-z", "--deleted"]
  case (headResult, statusResult, pathsResult, deletedResult) of
    (Right rawHead, Right rawStatus, Right rawPaths, Right rawDeletedPaths) ->
      case mkGitHead (Text.pack (trim rawHead)) of
        Left err -> pure (Left (SourceManifestIdentityRejected err))
        Right gitHead -> do
          let deletedPaths = nulSeparated rawDeletedPaths
              presentPaths = filter (`notElem` deletedPaths) (nulSeparated rawPaths)
          candidatesResult <- captureCandidates repoRoot configuredSecretRoots presentPaths
          pure $ do
            candidates <- candidatesResult
            let worktree = if null rawStatus then WorktreeClean else WorktreeDirty
            Right (gitHead, worktree, candidates)
    _ ->
      pure
        ( Left
            ( SourceManifestGitFailed
                (firstGitError headResult statusResult (firstFailure pathsResult deletedResult))
            )
        )

-- | Bounds for the mutation input capture. The timeout covers all Git calls
-- and candidate reads; it does not establish descendant-process settlement.
data SourceCaptureLimits = SourceCaptureLimits
  { sourceCaptureMaximumFiles :: !Int
  , sourceCaptureMaximumBytes :: !Int
  , sourceCaptureMaximumGitBytes :: !Int
  , sourceCaptureTimeoutMicros :: !Int
  }
  deriving stock (Eq, Show)

captureWorktreeInputsBounded
  :: SourceCaptureLimits
  -> FilePath
  -> [Text]
  -> IO (Either SourceManifestCaptureError (GitHead, WorktreeState, [SourceCandidate]))
captureWorktreeInputsBounded limits repoRoot secretRoots
  | sourceCaptureMaximumFiles limits <= 0
      || sourceCaptureMaximumBytes limits <= 0
      || sourceCaptureMaximumGitBytes limits <= 0
      || sourceCaptureTimeoutMicros limits <= 0 =
      pure (Left SourceManifestBudgetExceeded)
  | otherwise = do
      result <- timeout (sourceCaptureTimeoutMicros limits) capture
      pure (maybe (Left SourceManifestCaptureTimedOut) id result)
 where
  capture = do
    headResult <- boundedGit ["rev-parse", "--verify", "HEAD"]
    statusResult <- boundedGit ["status", "--porcelain=v1", "--untracked-files=all"]
    pathsResult <- boundedGit ["ls-files", "-z", "--cached", "--others", "--exclude-standard"]
    deletedResult <- boundedGit ["ls-files", "-z", "--deleted"]
    case (headResult, statusResult, pathsResult, deletedResult) of
      (Right rawHead, Right rawStatus, Right rawPaths, Right rawDeleted) ->
        case mkGitHead (Text.pack (trim rawHead)) of
          Left failure -> pure (Left (SourceManifestIdentityRejected failure))
          Right headId -> do
            let deleted = Set.fromList (nulSeparated rawDeleted)
                present = filter (`Set.notMember` deleted) (nulSeparated rawPaths)
            case selectCandidatePaths secretRoots present of
              Left failure -> pure (Left failure)
              Right selected
                | length selected > sourceCaptureMaximumFiles limits -> pure (Left SourceManifestBudgetExceeded)
                | otherwise -> do
                    candidates <- collect [] 0 selected
                    pure $
                      fmap
                        (headId,if null rawStatus then WorktreeClean else WorktreeDirty,)
                        candidates
      _ -> pure (Left (SourceManifestGitFailed "bounded git observation failed"))
  boundedGit args = do
    result <-
      captureSubprocessBounded
        ( BoundedSubprocessLimits
            1
            (sourceCaptureMaximumGitBytes limits)
            (sourceCaptureMaximumGitBytes limits)
            (sourceCaptureTimeoutMicros limits)
        )
        (Subprocess "git" args Nothing (Just repoRoot))
    pure $ case result of
      Right output | processExitCode output == ExitSuccess -> Right (processStdout output)
      _ -> Left ()
  collect captured used remaining = case remaining of
    [] -> pure (Right (reverse captured))
    path : rest -> do
      candidate <-
        captureSourceCandidateWithLimit (sourceCaptureMaximumBytes limits - used) repoRoot secretRoots path
      case candidate of
        Left failure -> pure (Left failure)
        Right value
          | ByteString.length (sourceCandidateBytes value) > sourceCaptureMaximumBytes limits - used ->
              pure (Left SourceManifestBudgetExceeded)
          | otherwise ->
              collect (value : captured) (used + ByteString.length (sourceCandidateBytes value)) rest

-- | Capture a clean historical tree without checking it out.  Git supplies the
-- exact committed path/type/mode inventory and blob bytes; the same positive
-- policy is applied to every path before any blob is opened.  This is the
-- recorder used for a frozen superseded-composition identity after its
-- production worktree no longer exists.
captureCommittedSourceIdentity
  :: FilePath
  -> String
  -> [Text]
  -> IO (Either SourceManifestCaptureError SourceIdentity)
captureCommittedSourceIdentity repoRoot revision configuredSecretRoots = do
  headResult <- runGit repoRoot ["rev-parse", "--verify", revision ++ "^{commit}"]
  case headResult of
    Left err -> pure (Left (SourceManifestGitFailed err))
    Right rawHead ->
      case mkGitHead (Text.pack (trim rawHead)) of
        Left err -> pure (Left (SourceManifestIdentityRejected err))
        Right gitHead -> do
          treeResult <-
            runGitBytes
              repoRoot
              ["ls-tree", "-rz", "--full-tree", trim rawHead]
          case treeResult of
            Left err -> pure (Left (SourceManifestGitFailed err))
            Right rawTree ->
              case selectCommittedEntries configuredSecretRoots rawTree of
                Left err -> pure (Left err)
                Right entries -> do
                  candidatesResult <- traverse (captureCommittedCandidate repoRoot) entries
                  pure $ do
                    candidates <- sequence candidatesResult
                    either
                      (Left . SourceManifestIdentityRejected)
                      Right
                      (mkSourceIdentity gitHead WorktreeClean configuredSecretRoots candidates)

data CommittedTreeEntry = CommittedTreeEntry
  { committedEntryPath :: !Text
  , committedEntryType :: !Text
  , committedEntryMode :: !Text
  , committedEntryObject :: !Text
  }

selectCommittedEntries
  :: [Text]
  -> ByteString.ByteString
  -> Either SourceManifestCaptureError [CommittedTreeEntry]
selectCommittedEntries configuredSecretRoots rawTree =
  fmap reverse (foldl selectOne (Right []) records)
 where
  records = filter (not . ByteString.null) (ByteString.split 0 rawTree)
  selectOne result rawEntry = do
    selected <- result
    entry <- parseCommittedTreeEntry rawEntry
    case classifySourcePath configuredSecretRoots (committedEntryPath entry) of
      Left err -> Left (SourceManifestIdentityRejected err)
      Right SourcePathExcludedByPolicy ->
        Left (SourceManifestExcludedTrackedInput (committedEntryPath entry))
      Right SourcePathOutsideAllowlist -> Right selected
      Right SourcePathAdmitted
        | hasPrivateDirectory (Text.unpack (committedEntryPath entry)) ->
            Left (SourceManifestUnsafeFile (Text.unpack (committedEntryPath entry)))
        | otherwise -> Right (entry : selected)

parseCommittedTreeEntry
  :: ByteString.ByteString
  -> Either SourceManifestCaptureError CommittedTreeEntry
parseCommittedTreeEntry rawEntry =
  case ByteString.break (== 9) rawEntry of
    (metadata, pathWithSeparator)
      | ByteString.null pathWithSeparator -> invalid
      | otherwise ->
          case ByteString8.words metadata of
            [rawMode, rawType, rawObject] -> do
              path <- decodeTreeText (ByteString.drop 1 pathWithSeparator)
              entryType <- decodeTreeText rawType
              mode <- decodeTreeText rawMode
              objectId <- decodeTreeText rawObject
              Right
                CommittedTreeEntry
                  { committedEntryPath = path
                  , committedEntryType = entryType
                  , committedEntryMode = mode
                  , committedEntryObject = objectId
                  }
            _ -> invalid
 where
  invalid = Left (SourceManifestTreeDecodeFailed "malformed git ls-tree entry")

decodeTreeText
  :: ByteString.ByteString
  -> Either SourceManifestCaptureError Text
decodeTreeText rawValue =
  case TextEncoding.decodeUtf8' rawValue of
    Left _ -> Left (SourceManifestTreeDecodeFailed "git tree contains non-UTF-8 metadata")
    Right value -> Right value

captureCommittedCandidate
  :: FilePath
  -> CommittedTreeEntry
  -> IO (Either SourceManifestCaptureError SourceCandidate)
captureCommittedCandidate repoRoot entry =
  case committedEntryShape entry of
    Left err -> pure (Left err)
    Right (fileType, mode) -> do
      bytesResult <-
        runGitBytes
          repoRoot
          ["cat-file", "blob", Text.unpack (committedEntryObject entry)]
      pure $ case bytesResult of
        Left err -> Left (SourceManifestGitFailed err)
        Right bytes ->
          Right
            SourceCandidate
              { sourceCandidatePath = committedEntryPath entry
              , sourceCandidateType = fileType
              , sourceCandidateMode = mode
              , sourceCandidateBytes = bytes
              }

committedEntryShape
  :: CommittedTreeEntry
  -> Either SourceManifestCaptureError (ManifestFileType, Word32)
committedEntryShape entry =
  case (committedEntryType entry, committedEntryMode entry) of
    ("blob", "100644") -> Right (ManifestRegularFile, 0o644)
    ("blob", "100755") -> Right (ManifestRegularFile, 0o755)
    ("blob", "120000") -> Right (ManifestSymbolicLink, 0o777)
    _ ->
      Left
        ( SourceManifestUnsupportedGitEntry
            (committedEntryPath entry)
            (committedEntryType entry)
            (committedEntryMode entry)
        )

captureCandidates
  :: FilePath
  -> [Text]
  -> [FilePath]
  -> IO (Either SourceManifestCaptureError [SourceCandidate])
captureCandidates repoRoot configuredSecretRoots rawPaths =
  case selectCandidatePaths configuredSecretRoots rawPaths of
    Left err -> pure (Left err)
    Right selectedPaths -> go [] selectedPaths
 where
  go captured remaining = case remaining of
    [] -> pure (Right (reverse captured))
    relativePath : rest ->
      do
        candidateResult <- captureSourceCandidate repoRoot configuredSecretRoots relativePath
        case candidateResult of
          Left err -> pure (Left err)
          Right candidate -> go (candidate : captured) rest

selectCandidatePaths
  :: [Text]
  -> [FilePath]
  -> Either SourceManifestCaptureError [FilePath]
selectCandidatePaths configuredSecretRoots = fmap reverse . foldl selectOne (Right [])
 where
  selectOne result relativePath = do
    selected <- result
    case classifySourcePath configuredSecretRoots (Text.pack relativePath) of
      Left err -> Left (SourceManifestIdentityRejected err)
      Right SourcePathExcludedByPolicy ->
        Left (SourceManifestExcludedTrackedInput (Text.pack relativePath))
      Right SourcePathOutsideAllowlist -> Right selected
      Right SourcePathAdmitted -> Right (relativePath : selected)

-- | Read only a policy-admitted source candidate. Parent directories and the
-- final file are opened without following links, and identity is rechecked
-- after reading. A hard link is refused because it can alias private data.
captureSourceCandidate
  :: FilePath -> [Text] -> FilePath -> IO (Either SourceManifestCaptureError SourceCandidate)
captureSourceCandidate = captureSourceCandidateWithLimit maximumSourceBytes

captureSourceCandidateWithLimit
  :: Int -> FilePath -> [Text] -> FilePath -> IO (Either SourceManifestCaptureError SourceCandidate)
captureSourceCandidateWithLimit maximumBytes repoRoot secretRoots relativePath
  | maximumBytes < 0 = pure (Left SourceManifestBudgetExceeded)
  | hasPrivateDirectory relativePath =
      pure (Left (SourceManifestUnsafeFile relativePath))
  | otherwise =
      case selectCandidatePaths secretRoots [relativePath] of
        Left failure -> pure (Left failure)
        Right [selected] -> do
          absoluteRoot <- makeAbsolute repoRoot
          captured <- tryIo relativePath $ withCandidateParent absoluteRoot selected $ \parent identities leaf -> do
            let anchored = "/proc/self/fd/" ++ showFd parent </> leaf
            before <- getSymbolicLinkStatus anchored
            if linkCount before /= 1 || fileSize before < 0 || fileSize before > maximumSourceBytes
              then pure (Left (SourceManifestUnsafeFile selected))
              else
                if fileSize before > fromIntegral maximumBytes
                  then pure (Left SourceManifestBudgetExceeded)
                  else do
                    observed <-
                      if isSymbolicLink before
                        then do
                          target <- readSymbolicLink anchored
                          after <- getSymbolicLinkStatus anchored
                          pure
                            ( if sameSourceVersion before after
                                then Just (ManifestSymbolicLink, TextEncoding.encodeUtf8 (Text.pack target))
                                else Nothing
                            )
                        else
                          if isRegularFile before
                            then bracket (Posix.openFdAt (Just parent) leaf Posix.ReadOnly sourceFileFlags) Posix.closeFd $ \file -> do
                              opened <- getFdStatus file
                              if not (isRegularFile opened && sameSourceVersion before opened)
                                then pure Nothing
                                else do
                                  bytes <- readSourceBytes maximumBytes file
                                  after <- getFdStatus file
                                  named <- getSymbolicLinkStatus anchored
                                  pure $
                                    if sameSourceVersion opened after
                                      && sameSourceVersion after named
                                      && fromIntegral (ByteString.length bytes) == fileSize after
                                      then Just (ManifestRegularFile, bytes)
                                      else Nothing
                            else pure Nothing
                    current <- withCandidateParent absoluteRoot selected $ \_ fresh _ -> pure fresh
                    pure $ case observed of
                      Just (kind, bytes)
                        | current == identities ->
                            Right (SourceCandidate (Text.pack selected) kind (canonicalFileMode before) bytes)
                      _ -> Left (SourceManifestUnsafeFile selected)
          pure (captured >>= id)
        Right _ -> pure (Left (SourceManifestUnsafeFile relativePath))

privateDirectoryNames :: [FilePath]
privateDirectoryNames = [".build", ".data", ".git", ".prodbox-state", ".secrets", ".test-data", "dist-newstyle"]

hasPrivateDirectory :: FilePath -> Bool
hasPrivateDirectory = any (`elem` privateDirectoryNames) . splitDirectories

maximumSourceBytes :: (Integral value) => value
maximumSourceBytes = 128 * 1024 * 1024

sourceDirectoryFlags :: Posix.OpenFileFlags
sourceDirectoryFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.directory = True}

sourceFileFlags :: Posix.OpenFileFlags
sourceFileFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}

withCandidateParent
  :: FilePath -> FilePath -> (Fd -> [(Integer, Integer)] -> FilePath -> IO value) -> IO value
withCandidateParent root relativePath action =
  case reverse (splitDirectories relativePath) of
    [] -> ioError (userError "empty source path")
    leaf : reversedParents ->
      bracket (Posix.openFd "/" Posix.ReadOnly sourceDirectoryFlags) Posix.closeFd $ \descriptor ->
        descend
          descriptor
          (filter (/= "/") (splitDirectories (normalise root)) ++ reverse reversedParents)
          []
          leaf
 where
  descend descriptor remaining identities leaf = do
    status <- getFdStatus descriptor
    if not (isDirectory status)
      then ioError (userError "source parent is not a directory")
      else do
        let nextIdentities = (toInteger (deviceID status), toInteger (fileID status)) : identities
        case remaining of
          [] -> action descriptor (reverse nextIdentities) leaf
          part : rest ->
            bracket (Posix.openFdAt (Just descriptor) part Posix.ReadOnly sourceDirectoryFlags) Posix.closeFd $ \next ->
              descend next rest nextIdentities leaf

showFd :: Fd -> String
showFd (Fd value) = show value

sameSourceVersion :: FileStatus -> FileStatus -> Bool
sameSourceVersion left right =
  deviceID left == deviceID right
    && fileID left == fileID right
    && fileSize left == fileSize right
    && fileMode left == fileMode right
    && fileOwner left == fileOwner right
    && linkCount left == linkCount right
    && modificationTimeHiRes left == modificationTimeHiRes right
    && statusChangeTimeHiRes left == statusChangeTimeHiRes right

readSourceBytes :: Int -> Fd -> IO ByteString.ByteString
readSourceBytes maximumBytes descriptor = go [] 0
 where
  go chunks count
    | count > maximumBytes = ioError (userError "source candidate exceeds size bound")
    | otherwise = do
        result <-
          tryIOError (PosixBytes.fdRead descriptor (fromIntegral (min 65535 (maximumBytes - count) + 1)))
        case result of
          Left failure | isEOFError failure -> pure (ByteString.concat (reverse chunks))
          Left failure -> ioError failure
          Right bytes
            | ByteString.null bytes -> pure (ByteString.concat (reverse chunks))
            | otherwise -> go (bytes : chunks) (count + ByteString.length bytes)

canonicalFileMode :: FileStatus -> Word32
canonicalFileMode status
  | isSymbolicLink status = 0o777
  | fileMode status .&. 0o111 == 0 = 0o644
  | otherwise = 0o755

tryIo :: FilePath -> IO value -> IO (Either SourceManifestCaptureError value)
tryIo path action = do
  result <- tryIOError action
  pure $ case result of
    Left err -> Left (SourceManifestFileReadFailed path (show err))
    Right value -> Right value

runGit :: FilePath -> [String] -> IO (Either String String)
runGit repoRoot arguments = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "git"
        , subprocessArguments = arguments
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
  pure $ case result of
    Failure err -> Left ("failed to start git: " ++ err)
    Success output -> case processExitCode output of
      ExitSuccess -> Right (processStdout output)
      ExitFailure _ -> Left (processStderr output ++ processStdout output)

runGitBytes
  :: FilePath
  -> [String]
  -> IO (Either String ByteString.ByteString)
runGitBytes repoRoot arguments = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "git"
        , subprocessArguments = arguments
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
  pure $ case result of
    Failure err -> Left ("failed to start git: " ++ err)
    Success output -> case processExitCode output of
      ExitSuccess -> Right (ByteString8.pack (processStdout output))
      ExitFailure exitCode ->
        Left
          ( "git exited "
              ++ show exitCode
              ++ ": "
              ++ processStderr output
              ++ processStdout output
          )

nulSeparated :: String -> [String]
nulSeparated input = filter (not . null) (split input)
 where
  split remaining =
    case break (== '\NUL') remaining of
      (value, []) -> [value]
      (value, _ : rest) -> value : split rest

firstGitError
  :: Either String a
  -> Either String b
  -> Either String c
  -> String
firstGitError first second third = case first of
  Left err -> err
  Right _ -> case second of
    Left err -> err
    Right _ -> case third of
      Left err -> err
      Right _ -> "unknown git capture failure"

firstFailure :: Either String a -> Either String b -> Either String ()
firstFailure first second = case first of
  Left err -> Left err
  Right _ -> case second of
    Left err -> Left err
    Right _ -> Right ()

trim :: String -> String
trim =
  reverse
    . dropWhile (`elem` [' ', '\t', '\r', '\n'])
    . reverse
    . dropWhile (`elem` [' ', '\t', '\r', '\n'])
