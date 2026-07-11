{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Decode the retained control-plane authority from the Tier-0 bootstrap
-- floor.  The authority endpoint is the canonical loopback-restricted home
-- gateway; it is not selected from the active substrate or kube context.
module Prodbox.Lifecycle.AuthorityConfig
  ( checkpointGatewayNodePort
  , longLivedCheckpointAuthorityFromBasics
  , resolveLongLivedCheckpointAuthority
  )
where

import Data.Bifunctor (first)
import Data.Text qualified as Text
import Prodbox.Config.Basics (UnencryptedBasics (..))
import Prodbox.Config.FloorDhall (loadUnencryptedBasics)
import Prodbox.Gateway.Client qualified as GatewayClient
import Prodbox.Gateway.Types (peerRestUrl)
import Prodbox.Lifecycle.CheckpointAuthority
  ( AuthorityCoordinateError
  , LongLivedCheckpointAuthority
  , mkLongLivedCheckpointAuthority
  )
import Prodbox.Minio.ObjectStore (defaultObjectStoreBucket)

checkpointGatewayNodePort :: Int
checkpointGatewayNodePort = 30443

longLivedCheckpointAuthorityFromBasics
  :: UnencryptedBasics
  -> Either AuthorityCoordinateError LongLivedCheckpointAuthority
longLivedCheckpointAuthorityFromBasics basics =
  mkLongLivedCheckpointAuthority
    (basicsClusterId basics)
    ( Text.pack
        ( peerRestUrl
            (GatewayClient.hostLoopbackGatewayEndpoint checkpointGatewayNodePort)
        )
    )
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
