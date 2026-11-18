{-# LANGUAGE OverloadedStrings #-}

-- | Derive regular-file snapshot inputs from one captured source inventory.
-- This module does not write a workspace or authenticate the inventory.
module Prodbox.Test.MutationSnapshot
  ( MutationSnapshot
  , MutationSnapshotFile (..)
  , MutationSnapshotError (..)
  , SnapshotMutation (..)
  , applyReviewedMutationToSnapshot
  , mutationSnapshotMutation
  , makeMutationSnapshot
  , captureMutationSnapshot
  , mutationSnapshotSource
  , mutationSnapshotFiles
  ) where

import Control.Monad (foldM)
import Data.ByteString qualified as ByteString
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word32)
import Prodbox.Test.Qualification.Evidence (PublicEvidenceDigest)
import Prodbox.Test.Qualification.SourceIdentity
  ( GitHead
  , ManifestFileType (..)
  , SourceCandidate (..)
  , SourceIdentity
  , SourceIdentityError
  , WorktreeState
  , mkSourceIdentity
  )
import Prodbox.Test.Qualification.SourceManifest
  ( SourceCaptureLimits (..)
  , SourceManifestCaptureError
  , captureWorktreeInputsBounded
  )
import Prodbox.Test.ReviewedMutation
  ( ReviewedMutation
  , ReviewedMutationError
  , prepareReviewedMutation
  , preparedMutantBytes
  , preparedMutantDigest
  , reviewedPatchDigest
  , reviewedSourcePath
  )
import System.FilePath.Posix (isAbsolute, takeDirectory)

data MutationSnapshotFile = MutationSnapshotFile
  { snapshotFilePath :: !Text
  , snapshotFileMode :: !Word32
  , snapshotFileBytes :: !ByteString.ByteString
  }
  deriving (Eq, Show)

data SnapshotMutation = SnapshotMutation
  { snapshotReviewedMutation :: !ReviewedMutation
  , snapshotMutationPatch :: !PublicEvidenceDigest
  , snapshotMutantDigest :: !PublicEvidenceDigest
  }
  deriving (Eq, Show)

data MutationSnapshot
  = MutationSnapshot
      !SourceIdentity
      ![MutationSnapshotFile]
      !(Map.Map Text Text)
      !(Maybe SnapshotMutation)
  deriving (Eq, Show)

data MutationSnapshotError
  = MutationSnapshotCaptureFailed !SourceManifestCaptureError
  | MutationSnapshotSourceInvalid !SourceIdentityError
  | MutationSnapshotTooManyFiles
  | MutationSnapshotPathCollision !Text
  | MutationSnapshotTooLarge
  | MutationSnapshotInvalidLink !Text
  | MutationSnapshotMissingLinkTarget !Text
  | MutationSnapshotNonRegularLinkTarget !Text
  | MutationSnapshotAlreadyMutated
  | MutationSnapshotMutationTargetMissing
  | MutationSnapshotMutationTargetIsLink
  | MutationSnapshotMutationTargetAliased
  | MutationSnapshotMutationRejected !ReviewedMutationError
  deriving (Eq, Show)

mutationSnapshotSource :: MutationSnapshot -> SourceIdentity
mutationSnapshotSource (MutationSnapshot source _ _ _) = source

mutationSnapshotFiles :: MutationSnapshot -> [MutationSnapshotFile]
mutationSnapshotFiles (MutationSnapshot _ files _ _) = files

mutationSnapshotMutation :: MutationSnapshot -> Maybe SnapshotMutation
mutationSnapshotMutation (MutationSnapshot _ _ _ mutation) = mutation

-- | Transform exactly one reviewed regular source file while preserving the
-- original source identity, every other file and the selected test bytes.
-- A source alias is refused because materialized links are independent copies.
-- This does not write files, establish isolation or execute a mutant.
applyReviewedMutationToSnapshot
  :: ReviewedMutation -> MutationSnapshot -> Either MutationSnapshotError MutationSnapshot
applyReviewedMutationToSnapshot selected (MutationSnapshot source files aliases existing) = do
  case existing of
    Just _ -> Left MutationSnapshotAlreadyMutated
    Nothing -> pure ()
  let target = Text.pack (reviewedSourcePath selected)
  if Map.member target aliases then Left MutationSnapshotMutationTargetIsLink else pure ()
  if target `elem` Map.elems aliases then Left MutationSnapshotMutationTargetAliased else pure ()
  original <- case filter ((== target) . snapshotFilePath) files of
    [entry] -> Right entry
    _ -> Left MutationSnapshotMutationTargetMissing
  patch <-
    either
      (Left . MutationSnapshotMutationRejected)
      Right
      (prepareReviewedMutation selected (snapshotFileBytes original))
  let changed =
        [ if snapshotFilePath entry == target
            then entry {snapshotFileBytes = preparedMutantBytes patch}
            else entry
        | entry <- files
        ]
      binding = SnapshotMutation selected (reviewedPatchDigest selected) (preparedMutantDigest patch)
  if sum (map (toInteger . ByteString.length . snapshotFileBytes) changed) > 512 * 1024 * 1024
    then Left MutationSnapshotTooLarge
    else Right (MutationSnapshot source changed aliases (Just binding))

-- | Capture the selected non-secret worktree inventory once and derive snapshot
-- inputs from those same bytes. This is not a process isolation boundary.
captureMutationSnapshot :: FilePath -> [Text] -> IO (Either MutationSnapshotError MutationSnapshot)
captureMutationSnapshot root secretRoots = do
  observed <-
    captureWorktreeInputsBounded
      (SourceCaptureLimits 100000 (512 * 1024 * 1024) (16 * 1024 * 1024) 120000000)
      root
      secretRoots
  pure $ case observed of
    Left failure -> Left (MutationSnapshotCaptureFailed failure)
    Right (headId, state, candidates) -> makeMutationSnapshot headId state secretRoots candidates

-- | Validate a full source inventory and resolve each relative source symlink
-- to one regular file in that inventory. Output entries contain bytes only;
-- callers must create fresh, single-link files under a verified private root
-- and independently bind and recheck them before any worker may run.
makeMutationSnapshot
  :: GitHead
  -> WorktreeState
  -> [Text]
  -> [SourceCandidate]
  -> Either MutationSnapshotError MutationSnapshot
makeMutationSnapshot headId state secretRoots candidates = do
  source <-
    either
      (Left . MutationSnapshotSourceInvalid)
      Right
      (mkSourceIdentity headId state secretRoots candidates)
  if length candidates > 100000 then Left MutationSnapshotTooManyFiles else pure ()
  let entries = Map.fromList [(sourceCandidatePath candidate, candidate) | candidate <- candidates]
  case filter (hasFileAncestor entries . sourceCandidatePath) candidates of
    candidate : _ -> Left (MutationSnapshotPathCollision (sourceCandidatePath candidate))
    [] -> pure ()
  materialized <- traverse (materialize entries) candidates
  let files = map fst materialized
      aliases = Map.fromList [(snapshotFilePath file, target) | (file, Just target) <- materialized]
  if sum (map (toInteger . ByteString.length . snapshotFileBytes) files) > 512 * 1024 * 1024
    then Left MutationSnapshotTooLarge
    else Right (MutationSnapshot source files aliases Nothing)
 where
  materialize entries candidate = case sourceCandidateType candidate of
    ManifestRegularFile -> pure (asFile (sourceCandidatePath candidate) candidate, Nothing)
    ManifestSymbolicLink -> do
      target <-
        either
          (const (Left (MutationSnapshotInvalidLink path)))
          Right
          (TextEncoding.decodeUtf8' (sourceCandidateBytes candidate))
      let targetPath = Text.unpack target
      resolved <-
        if Text.null target || Text.any (== '\0') target || isAbsolute targetPath
          then Left (MutationSnapshotInvalidLink path)
          else maybe (Left (MutationSnapshotInvalidLink path)) Right (resolveTarget path target)
      case Map.lookup resolved entries of
        Nothing -> Left (MutationSnapshotMissingLinkTarget path)
        Just selected -> case sourceCandidateType selected of
          ManifestRegularFile -> Right (asFile path selected, Just resolved)
          ManifestSymbolicLink -> Left (MutationSnapshotNonRegularLinkTarget path)
   where
    path = sourceCandidatePath candidate
  asFile path candidate = MutationSnapshotFile path (sourceCandidateMode candidate) (sourceCandidateBytes candidate)

-- Collapse relative link components without allowing a step above the source root.
resolveTarget :: Text -> Text -> Maybe Text
resolveTarget path target = do
  let parent = Text.pack (takeDirectory (Text.unpack path))
      components = Text.splitOn "/" (parent <> "/" <> target)
  result <- foldM step [] components
  if null result then Nothing else Just (Text.intercalate "/" (reverse result))
 where
  step parts component
    | Text.null component || component == "." = Just parts
    | component == ".." = case parts of
        [] -> Nothing
        _ : remaining -> Just remaining
    | otherwise = Just (component : parts)

hasFileAncestor :: Map.Map Text SourceCandidate -> Text -> Bool
hasFileAncestor entries path = go (takeDirectory (Text.unpack path))
 where
  go parent
    | parent == "." || parent == "/" = False
    | Map.member (Text.pack parent) entries = True
    | otherwise = go (takeDirectory parent)
