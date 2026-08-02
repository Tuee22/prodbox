{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Filesystem recorder for the secret-safe Standard-P source identity.
--
-- Git supplies the tracked plus non-ignored-untracked path inventory and the
-- whole-worktree dirty bit. Every candidate is classified against the positive
-- manifest policy before opening it; ignored/configured secret roots and build
-- roots therefore never enter a read or digest operation.
module Prodbox.Test.Qualification.SourceManifest
  ( SourceManifestCaptureError (..)
  , captureSourceIdentity
  , captureCommittedSourceIdentity
  )
where

import Data.Bits ((.&.))
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word32)
import Prodbox.Result (Result (..))
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  )
import Prodbox.Test.Qualification.SourceIdentity
  ( ManifestFileType (..)
  , SourceCandidate (..)
  , SourceIdentity
  , SourceIdentityError
  , SourcePathDisposition (..)
  , WorktreeState (..)
  , classifySourcePath
  , mkGitHead
  , mkSourceIdentity
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Error (tryIOError)
import System.Posix.Files
  ( FileStatus
  , fileMode
  , getSymbolicLinkStatus
  , isRegularFile
  , isSymbolicLink
  , readSymbolicLink
  )

data SourceManifestCaptureError
  = SourceManifestGitFailed !String
  | SourceManifestIdentityRejected !SourceIdentityError
  | SourceManifestExcludedTrackedInput !Text
  | SourceManifestFileReadFailed !FilePath !String
  | SourceManifestUnsupportedFileType !FilePath
  | SourceManifestTreeDecodeFailed !String
  | SourceManifestUnsupportedGitEntry !Text !Text !Text
  deriving stock (Eq, Show)

captureSourceIdentity
  :: FilePath
  -> [Text]
  -> IO (Either SourceManifestCaptureError SourceIdentity)
captureSourceIdentity repoRoot configuredSecretRoots = do
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
            either
              (Left . SourceManifestIdentityRejected)
              Right
              (mkSourceIdentity gitHead worktree configuredSecretRoots candidates)
    _ ->
      pure
        ( Left
            ( SourceManifestGitFailed
                (firstGitError headResult statusResult (firstFailure pathsResult deletedResult))
            )
        )

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
      Right SourcePathAdmitted -> Right (entry : selected)

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
        candidateResult <- captureCandidate (repoRoot </> relativePath) relativePath
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

captureCandidate
  :: FilePath
  -> FilePath
  -> IO (Either SourceManifestCaptureError SourceCandidate)
captureCandidate absolutePath relativePath = do
  statusResult <- tryIo absolutePath (getSymbolicLinkStatus absolutePath)
  case statusResult of
    Left err -> pure (Left err)
    Right status
      | not (isSymbolicLink status || isRegularFile status) ->
          pure (Left (SourceManifestUnsupportedFileType relativePath))
      | otherwise -> do
          bytesResult <-
            if isSymbolicLink status
              then do
                targetResult <- tryIo absolutePath (readSymbolicLink absolutePath)
                pure (TextEncoding.encodeUtf8 . Text.pack <$> targetResult)
              else tryIo absolutePath (ByteString.readFile absolutePath)
          pure $ do
            bytes <- bytesResult
            Right
              SourceCandidate
                { sourceCandidatePath = Text.pack relativePath
                , sourceCandidateType =
                    if isSymbolicLink status then ManifestSymbolicLink else ManifestRegularFile
                , sourceCandidateMode = canonicalFileMode status
                , sourceCandidateBytes = bytes
                }

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
