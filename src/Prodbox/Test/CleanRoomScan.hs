-- | The production sources the clean-room scans read.
--
-- The installed clean-room validation and the cutover recorder both ask the
-- same question of the same files: which registered legacy sites does the tree
-- still contain. Reading them in one place is what keeps the two answers equal.
module Prodbox.Test.CleanRoomScan
  ( productionSources
  )
where

import Control.Monad (filterM, forM)
import Data.ByteString qualified as ByteString
import Data.List (isPrefixOf)
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.Encoding.Error (lenientDecode)
import Prodbox.CheckCode (listRepoOwnedPaths)
import System.Directory (doesFileExist)
import System.FilePath ((</>))

-- | Every repository-owned path, and the text of the production sources among
-- them. The registry that names the legacy sites and the rule that enforces it
-- are excluded, because they mention what they scan for.
productionSources :: FilePath -> IO ([FilePath], [(FilePath, Text)])
productionSources repoRoot = do
  paths <- listRepoOwnedPaths repoRoot
  sourcePaths <-
    filterM
      (doesFileExist . (repoRoot </>))
      (filter isProductionPath paths)
  sources <-
    forM
      sourcePaths
      ( \path -> do
          bytes <- ByteString.readFile (repoRoot </> path)
          pure (path, TextEncoding.decodeUtf8With lenientDecode bytes)
      )
  pure (paths, sources)
 where
  isProductionPath path =
    any (`isPrefixOf` path) ["app/", "src/", "charts/"]
      && path /= "src/Prodbox/CheckCode.hs"
      && path /= "src/Prodbox/Test/CleanRoomHandoff.hs"
