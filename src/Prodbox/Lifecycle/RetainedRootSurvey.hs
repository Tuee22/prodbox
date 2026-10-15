-- | A read-only look at every retained root in the worktree.
--
-- The cascade that finds no local install used to know about exactly one
-- retained root, the one the configuration resolves. A host whose
-- configuration was changed later keeps the old root on disk, and a test run
-- keeps its own, so \"the retained root\" is a set. This module looks at each
-- member of that set and reports what it found.
--
-- __It only reads.__ It tests existence, lists one directory level, and resolves
-- symbolic links. It writes nothing, creates nothing, and never recurses, and
-- its result is a value the pure decision in "Prodbox.Lifecycle.CascadeNoInstall"
-- reads: an observation cannot be refined into a deletable path.
--
-- Every filesystem failure becomes an unexaminable finding rather than an
-- exception, because a root that could not be looked at is a root that was not
-- examined.
module Prodbox.Lifecycle.RetainedRootSurvey
  ( observeRetainedRoot
  , surveyRetainedRoots
  )
where

import Control.Exception (IOException, displayException, try)
import Data.List (isPrefixOf, sort)
import Prodbox.Lifecycle.CascadeNoInstall
  ( RetainedRootFinding (..)
  , RetainedRootKind (..)
  , RetainedRootObservation (..)
  , retainedRootCandidates
  , retainedRootSignatures
  )
import System.Directory
  ( Permissions
  , canonicalizePath
  , doesDirectoryExist
  , doesPathExist
  , getPermissions
  , getSymbolicLinkTarget
  , listDirectory
  )
import System.FilePath (splitDirectories, (</>))
import System.IO.Error (isDoesNotExistError, isPermissionError)

-- | Look at one root. A symbolic link is followed only when it resolves inside
-- the worktree; one that leaves it is unexaminable, because following it would
-- report on a directory the worktree does not contain.
observeRetainedRoot :: FilePath -> RetainedRootKind -> FilePath -> IO RetainedRootFinding
observeRetainedRoot canonicalRepoRoot kind path = do
  observation <- either (RootUnexaminable . displayException) id <$> attempt
  pure
    RetainedRootFinding
      { rootFindingKind = kind
      , rootFindingPath = path
      , rootFindingObservation = observation
      }
 where
  attempt :: IO (Either IOException RetainedRootObservation)
  attempt = try inspect

  inspect = do
    link <- try (getSymbolicLinkTarget path) :: IO (Either IOException FilePath)
    case link of
      Left _ -> examineDirectory path
      Right _ -> do
        resolved <- canonicalizePath path
        if splitDirectories canonicalRepoRoot `isPrefixOf` splitDirectories resolved
          then do
            exists <- doesPathExist resolved
            if exists
              then examineDirectory resolved
              else pure (RootUnexaminable "symbolic link whose target does not exist")
          else pure (RootUnexaminable "symbolic link resolving outside the worktree")

  -- The existence predicates in the directory package answer @False@ for any
  -- failure, permission denied included, which would report a root that exists
  -- but cannot be searched as absent. Only a definite \"does not exist\" is
  -- absent; every other failure leaves the root unexaminable.
  examineDirectory directory = do
    probe <- try (getPermissions directory) :: IO (Either IOException Permissions)
    case probe of
      Left err
        | isDoesNotExistError err -> pure RootAbsent
        | otherwise -> pure (RootUnexaminable (displayException err))
      Right _ -> do
        isDirectory <- doesDirectoryExist directory
        if isDirectory
          then RootPresent . length <$> listDirectory directory
          else pure (RootUnexaminable "not a directory")

-- | Look at every candidate root, then at the immediate children of the
-- repository root for one that carries a retained-root signature but is not a
-- candidate (a root left behind by an earlier configuration). The scan is
-- non-recursive: a child is a retained root only if a signature path exists
-- directly beneath it.
surveyRetainedRoots :: FilePath -> FilePath -> IO [RetainedRootFinding]
surveyRetainedRoots repoRoot configuredRoot = do
  canonicalRepoRoot <- canonicalizePath repoRoot
  let candidates = retainedRootCandidates repoRoot configuredRoot
  candidateFindings <-
    traverse (\(kind, path) -> observeRetainedRoot canonicalRepoRoot kind path) candidates
  children <- try (listDirectory repoRoot) :: IO (Either IOException [FilePath])
  case children of
    Left err ->
      pure
        ( candidateFindings
            ++ [ RetainedRootFinding
                   { rootFindingKind = RootDiscovered
                   , rootFindingPath = repoRoot
                   , rootFindingObservation = RootUnexaminable (displayException err)
                   }
               ]
        )
    Right names -> do
      let candidatePaths = map snd candidates
          others = [repoRoot </> name | name <- sort names, repoRoot </> name `notElem` candidatePaths]
      states <- traverse (\child -> (,) child <$> carriesSignature child) others
      discovered <-
        traverse
          (discoveredFinding canonicalRepoRoot)
          [(child, state) | (child, state) <- states, state /= SignatureAbsent]
      pure (candidateFindings ++ discovered)
 where
  carriesSignature child = firstPresent <$> traverse (signatureState child) retainedRootSignatures
  firstPresent states
    | SignaturePresent `elem` states = SignaturePresent
    | otherwise = case [state | state@(SignatureUnreadable _) <- states] of
        unreadable : _ -> unreadable
        [] -> SignatureAbsent

-- | Whether a child of the repository root carries a retained-root signature.
data SignatureState
  = SignatureAbsent
  | SignaturePresent
  | -- | The child could not be searched far enough to say. That is not
    -- \"absent\": a root left behind in a directory this user cannot read is
    -- exactly the root the survey exists to find.
    SignatureUnreadable String
  deriving (Eq, Show)

-- | Walk the signature one directory level at a time, so a missing component
-- and a component that cannot be listed are told apart.
signatureState :: FilePath -> FilePath -> IO SignatureState
signatureState child signature = walk child (splitDirectories signature)
 where
  walk _ [] = pure SignaturePresent
  walk directory (component : rest) = do
    listed <- try (listDirectory directory) :: IO (Either IOException [FilePath])
    case listed of
      Left err
        | isPermissionError err -> pure (SignatureUnreadable (displayException err))
        | otherwise -> pure SignatureAbsent
      Right names
        | component `elem` names -> walk (directory </> component) rest
        | otherwise -> pure SignatureAbsent

discoveredFinding :: FilePath -> (FilePath, SignatureState) -> IO RetainedRootFinding
discoveredFinding canonicalRepoRoot (child, state) = case state of
  SignaturePresent -> observeRetainedRoot canonicalRepoRoot RootDiscovered child
  SignatureUnreadable detail ->
    pure
      RetainedRootFinding
        { rootFindingKind = RootDiscovered
        , rootFindingPath = child
        , rootFindingObservation = RootUnexaminable detail
        }
  SignatureAbsent ->
    pure
      RetainedRootFinding
        { rootFindingKind = RootDiscovered
        , rootFindingPath = child
        , rootFindingObservation = RootAbsent
        }
