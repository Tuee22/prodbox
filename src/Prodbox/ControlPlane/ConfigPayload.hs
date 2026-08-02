{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Production config payload validation and least-information projection.
module Prodbox.ControlPlane.ConfigPayload
  ( RuntimeConfigProjection (..)
  , productionConfigPayloadCompiler
  )
where

import Codec.Serialise (Serialise, serialise)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import GHC.Generics (Generic)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.ControlPlane.ConfigEndpoint
  ( ConfigPayloadCompiler (..)
  , ConfigProjectionScope (..)
  )
import Prodbox.Settings (decodeConfigDhallBytes, renderConfigDhall)
import System.Environment (getExecutablePath)
import System.FilePath (takeDirectory)

-- | Standing services receive only a generation-bound public projection here;
-- their exact SecretRef coordinates remain in their dedicated mounted role
-- config.  Operator and harness callers receive canonical ConfigFile bytes so
-- Settings can decode the complete non-secret authoring projection.
data RuntimeConfigProjection = RuntimeConfigProjection
  { runtimeConfigProjectionVersion :: !Word
  , runtimeConfigProjectionScope :: !ConfigProjectionScope
  , runtimeConfigProjectionCanonicalDigest :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

productionConfigPayloadCompiler :: ConfigPayloadCompiler IO
productionConfigPayloadCompiler =
  ConfigPayloadCompiler
    { compileCanonicalConfig = canonicalize
    , compileConfigProjection = project
    }
 where
  canonicalize bytes = do
    executable <- getExecutablePath
    decoded <- decodeConfigDhallBytes (takeDirectory executable) bytes
    pure $ case decoded of
      Left detail -> Left (Text.pack detail)
      Right config ->
        Right
          ( TextEncoding.encodeUtf8
              (Text.pack (renderConfigDhall config))
          )

  project scope canonicalBytes = case scope of
    ConfigProjectionOperator -> pure (Right canonicalBytes)
    ConfigProjectionTestHarness -> pure (Right canonicalBytes)
    _ ->
      pure
        ( Right
            ( LazyByteString.toStrict
                ( serialise
                    RuntimeConfigProjection
                      { runtimeConfigProjectionVersion = 1
                      , runtimeConfigProjectionScope = scope
                      , runtimeConfigProjectionCanonicalDigest =
                          TextEncoding.decodeUtf8 (hexSha256 canonicalBytes)
                      }
                )
            )
        )
