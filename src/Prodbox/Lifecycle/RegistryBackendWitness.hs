{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 1.76: the one place a registry storage-backend round trip becomes a
-- 'RoundTripWitness'.
--
-- The registry deep probe opens a blob-upload session against the registry's
-- @\/v2\/\<repo\>\/blobs\/uploads\/@ endpoint. The registry can only create that
-- session by writing through to its MinIO storage backend, and the session
-- identifier it returns is the receipt of that write — so this module, which
-- decodes that receipt, is a legitimate minter under the
-- "Prodbox.ControlPlane.Observation.Internal" allowlist.
--
-- It is deliberately a module of its own rather than a helper inside the
-- lifecycle CLI. The allowlist is only meaningful while its entries are small
-- enough to read: admitting a ten-thousand-line module would make the boundary
-- a formality.
module Prodbox.Lifecycle.RegistryBackendWitness
  ( registryBackendWitness
  )
where

import Data.Text (Text)
import Prodbox.ControlPlane.Observation (RoundTripWitness)
import Prodbox.ControlPlane.Observation.Internal (mintRoundTripWitness)
import Prodbox.Lifecycle.CheckpointAuthority (mkModelBObjectVersion)
import Prodbox.Lifecycle.Lease (AuthorityTime)

-- | Mint a witness from the upload-session identifier the registry returned and
-- the instant the probe observed the registry accept it.
--
-- 'Nothing' when the registry named no session: a 2xx that creates no
-- storage-backend session is not a round trip, and admitting it would restore
-- exactly the "an affirmative status proves a write" reasoning this sprint
-- removes. 'mkModelBObjectVersion' supplies the rejection — it refuses an
-- empty, control-bearing, or over-long identifier.
registryBackendWitness :: Text -> AuthorityTime -> Maybe RoundTripWitness
registryBackendWitness sessionIdentifier landedAt =
  case mkModelBObjectVersion sessionIdentifier of
    Left _ -> Nothing
    Right version -> Just (mintRoundTripWitness version landedAt)
