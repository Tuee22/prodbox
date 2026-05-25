{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Workload-Pod Dhall settings module per
--   [config_doctrine.md §4](../../documents/engineering/config_doctrine.md#4-decoding).
--
-- The workload Pod binary reads its full configuration from
-- @--config /etc/workload/config.dhall@, decoded in-process via the native
-- Haskell @dhall@ library. The Dhall schema covers the @workload.mode@
-- selector (@Api | Websocket@), optional log level, optional listener port,
-- optional Redis endpoint (required when mode is Websocket), and optional
-- OIDC bootstrap config (required when mode is Websocket).
--
-- During the Sprint 3.14 transition the @--config@ flag is optional: when
-- absent the workload falls back to the legacy @PRODBOX_WORKLOAD_MODE@ +
-- sister-env-var ladder for backward compatibility with the chart templates
-- that still emit env vars. When the chart-side migration completes the
-- env-var fallback path is removed and the @--config@ flag becomes the sole
-- source.
module Prodbox.Workload.Settings
  ( WorkloadConfigDhall (..)
  , WorkloadModeDhall (..)
  , RedisConfigDhall (..)
  , OidcConfigDhall (..)
  , decodeWorkloadConfigDhall
  , loadWorkloadConfig
  )
where

import Control.Exception (SomeException, displayException, try)
import Data.Text (Text)
import Dhall (FromDhall, auto, input, inputFile)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)

-- | Workload mode selector. Mirrors @Prodbox.Workload.WorkloadMode@ but is
-- a Dhall-derivable enum (uses Generic + FromDhall through Dhall's tagged
-- union representation).
data WorkloadModeDhall = Api | Websocket
  deriving (Eq, Show, Generic, FromDhall)

data RedisConfigDhall = RedisConfigDhall
  { host :: Text
  , port :: Text
  }
  deriving (Eq, Show, Generic, FromDhall)

data OidcConfigDhall = OidcConfigDhall
  { issuer :: Text
  , client_id :: Text
  , client_secret :: Text
  , public_base_url :: Text
  , token_endpoint :: Text
  }
  deriving (Eq, Show, Generic, FromDhall)

-- | Workload-Pod Dhall config.
--
-- The schema is @{ schemaVersion : Natural, mode : < Api | Websocket >,
-- log_level : Optional Text, port : Optional Natural, redis : Optional R,
-- oidc : Optional O }@ where R and O are 'RedisConfigDhall' and
-- 'OidcConfigDhall' respectively. The decoder caller validates the mode +
-- optional-field consistency (Websocket requires both redis and oidc).
data WorkloadConfigDhall = WorkloadConfigDhall
  { schemaVersion :: Natural
  , mode :: WorkloadModeDhall
  , log_level :: Maybe Text
  , workload_port :: Maybe Natural
  , redis :: Maybe RedisConfigDhall
  , oidc :: Maybe OidcConfigDhall
  }
  deriving (Eq, Show, Generic, FromDhall)

supportedWorkloadConfigSchemaVersion :: Natural
supportedWorkloadConfigSchemaVersion = 1

-- | Decode a Dhall text expression into 'WorkloadConfigDhall'. Exposed for
-- tests that supply Dhall source as a string rather than a file path.
decodeWorkloadConfigDhall :: Text -> IO (Either String WorkloadConfigDhall)
decodeWorkloadConfigDhall src = do
  result <- try (input auto src) :: IO (Either SomeException WorkloadConfigDhall)
  case result of
    Left e -> pure (Left ("failed to decode workload Dhall config: " ++ displayException e))
    Right dto -> pure (validateSchemaVersion dto)

-- | Canonical entrypoint: load the workload config from the file at the path
-- passed via @--config <path>@.
loadWorkloadConfig :: FilePath -> IO (Either String WorkloadConfigDhall)
loadWorkloadConfig path = do
  result <- try (inputFile auto path) :: IO (Either SomeException WorkloadConfigDhall)
  case result of
    Left e ->
      pure
        ( Left
            ( "failed to decode workload Dhall config `"
                ++ path
                ++ "`: "
                ++ displayException e
            )
        )
    Right dto -> pure (validateSchemaVersion dto)

validateSchemaVersion :: WorkloadConfigDhall -> Either String WorkloadConfigDhall
validateSchemaVersion dto =
  if schemaVersion dto == supportedWorkloadConfigSchemaVersion
    then Right dto
    else
      Left
        ( "config_schema_mismatch: expected schemaVersion "
            ++ show supportedWorkloadConfigSchemaVersion
            ++ ", got "
            ++ show (schemaVersion dto)
        )
