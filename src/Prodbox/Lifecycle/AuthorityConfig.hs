{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Decode the retained control-plane authority identity and namespace from
-- the Tier-0 bootstrap floor. Transport is selected independently by the
-- authenticated Lifecycle Authority client or the injected object-store
-- adapter; it is never embedded in this coordinate.
module Prodbox.Lifecycle.AuthorityConfig
  ( longLivedCheckpointAuthorityFromBasics
  , resolveLongLivedCheckpointAuthority
  )
where

import Data.Bifunctor (first)
import Data.Text qualified as Text
import Prodbox.Config.Basics (UnencryptedBasics (..))
import Prodbox.Config.FloorDhall (loadUnencryptedBasics)
import Prodbox.Lifecycle.CheckpointAuthority
  ( AuthorityCoordinateError
  , LongLivedCheckpointAuthority
  , mkLongLivedCheckpointAuthority
  )
import Prodbox.Minio.ObjectStore (defaultObjectStoreBucket)

longLivedCheckpointAuthorityFromBasics
  :: UnencryptedBasics
  -> Either AuthorityCoordinateError LongLivedCheckpointAuthority
longLivedCheckpointAuthorityFromBasics basics =
  mkLongLivedCheckpointAuthority
    (basicsClusterId basics)
    (Text.pack defaultObjectStoreBucket)
    "lifecycle"
    "secret/lifecycle"

resolveLongLivedCheckpointAuthority
  :: FilePath -> IO (Either String LongLivedCheckpointAuthority)
resolveLongLivedCheckpointAuthority repoRoot = do
  basicsResult <- loadUnencryptedBasics repoRoot
  pure $ do
    basics <- basicsResult
    first show (longLivedCheckpointAuthorityFromBasics basics)
