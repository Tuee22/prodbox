{-# LANGUAGE ImportQualifiedPost #-}

module Prodbox.Config.SchemaSourceDependencies (discoverSchemaSourceDependencies, SchemaStageError (..)) where

import Control.Exception (IOException, displayException, try)
import Control.Monad (filterM)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.List (nub, sort)
import System.Directory
  ( doesDirectoryExist
  , doesFileExist
  , listDirectory
  , makeAbsolute
  , pathIsSymbolicLink
  )
import System.FilePath (takeDirectory, takeExtension, takeFileName, (</>))

data SchemaStageError
  = SchemaPackageRootMissing FilePath
  | SchemaSourceSymlink FilePath
  | SchemaSourceUnobservable String
  deriving (Show)

discoverSchemaSourceDependencies :: FilePath -> IO (Either SchemaStageError [FilePath])
discoverSchemaSourceDependencies source = do
  observed <- try (runExceptT (discover source))
  pure (captureFailure observed)

captureFailure
  :: Either IOException (Either SchemaStageError value) -> Either SchemaStageError value
captureFailure observed = case observed of
  Left cause -> Left (SchemaSourceUnobservable (displayException cause))
  Right value -> value

discover :: FilePath -> ExceptT SchemaStageError IO [FilePath]
discover source = do
  absolute <- liftIO (makeAbsolute source)
  root <- findRoot (takeDirectory absolute)
  repository <- sourceTree (root </> "src")
  siblings <- sourceFiles (takeDirectory absolute)
  manifests <-
    liftIO $
      filterM
        doesFileExist
        [root </> "prodbox.cabal", root </> "cabal.project", root </> "cabal.project.freeze"]
  pure (sort (nub (repository <> siblings <> manifests)))

findRoot :: FilePath -> ExceptT SchemaStageError IO FilePath
findRoot candidate = do
  found <- liftIO (doesFileExist (candidate </> "prodbox.cabal"))
  if found
    then pure candidate
    else
      if takeDirectory candidate == candidate
        then throwE (SchemaPackageRootMissing candidate)
        else findRoot (takeDirectory candidate)

sourceTree :: FilePath -> ExceptT SchemaStageError IO [FilePath]
sourceTree directory = do
  exists <- liftIO (doesDirectoryExist directory)
  if exists
    then do
      entries <- liftIO (listDirectory directory)
      concat <$> mapM (sourceEntry . (directory </>)) entries
    else pure []

sourceEntry :: FilePath -> ExceptT SchemaStageError IO [FilePath]
sourceEntry path = do
  symbolic <- liftIO (pathIsSymbolicLink path)
  if symbolic
    then throwE (SchemaSourceSymlink path)
    else do
      directory <- liftIO (doesDirectoryExist path)
      if directory
        then sourceTree path
        else pure [path | takeExtension path == ".hs" && takeFileName path /= "test-secrets.dhall"]

sourceFiles :: FilePath -> ExceptT SchemaStageError IO [FilePath]
sourceFiles directory = do
  names <- liftIO (listDirectory directory)
  concat <$> mapM (sourceSibling . (directory </>)) names

sourceSibling :: FilePath -> ExceptT SchemaStageError IO [FilePath]
sourceSibling path
  | takeExtension path /= ".hs" = pure []
  | otherwise = do
      symbolic <- liftIO (pathIsSymbolicLink path)
      if symbolic then throwE (SchemaSourceSymlink path) else pure [path]
