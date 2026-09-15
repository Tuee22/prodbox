{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The artifact shape every frozen counterexample family shares.
--
-- A family is five committed files: a trace, a canonical disposition matrix, a
-- mutation of that matrix, and two resource profiles.  The two profiles have
-- the same Dhall schema in every family, and the rule they carry is the same
-- rule: the superseded composition and the replacement composition must cost
-- the same topology-normalized total, so a counterexample cannot be closed by
-- spending more.  Sprint @5.35@ wrote that schema for the teardown family and
-- Sprint @7.41@ needed it again for the create family; this module is where it
-- lives so the second family is the same artifact rather than a second dialect
-- of one.
--
-- It also owns the artifact digest, for the same reason: two families that
-- computed their digests differently would be two formats with one name.
module Prodbox.Test.Qualification.CounterexampleProfile
  ( ProfileEnvelope (..)
  , ProfileBackgroundLoad (..)
  , ProfileEnvelopeMapping (..)
  , CounterexampleResourceProfile (..)
  , ResourceTotals (..)
  , profileTotals
  , topologyNormalizedBudgetHolds
  , counterexampleArtifactDigestText
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Dhall qualified
import GHC.Generics (Generic)
import Numeric (showHex)
import Numeric.Natural (Natural)

data ProfileEnvelope = ProfileEnvelope
  { component :: !Text
  , cpu_millis :: !Natural
  , memory_mib :: !Natural
  , ephemeral_mib :: !Natural
  , persistence_mib :: !Natural
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Dhall.FromDhall)

data ProfileBackgroundLoad = ProfileBackgroundLoad
  { request_rate_per_second :: !Natural
  , concurrent_clients :: !Natural
  , payload_bytes :: !Natural
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Dhall.FromDhall)

data ProfileEnvelopeMapping = ProfileEnvelopeMapping
  { superseded_component :: !Text
  , replacement_components :: ![Text]
  }
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Dhall.FromDhall)

data CounterexampleResourceProfile = CounterexampleResourceProfile
  { format_version :: !Natural
  , fixture_id :: !Text
  , profile_id :: !Text
  , profile_kind :: !Text
  , background_load :: !ProfileBackgroundLoad
  , fault_schedule :: ![Text]
  , fault_schedule_digest :: !Text
  , independently_justified :: !Bool
  , superseded_envelopes :: ![ProfileEnvelope]
  , replacement_envelopes :: ![ProfileEnvelope]
  , envelope_mapping :: ![ProfileEnvelopeMapping]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Dhall.FromDhall)

data ResourceTotals = ResourceTotals
  { totalCpuMillis :: !Natural
  , totalMemoryMib :: !Natural
  , totalEphemeralMib :: !Natural
  , totalPersistenceMib :: !Natural
  }
  deriving stock (Eq, Ord, Show)

profileTotals :: [ProfileEnvelope] -> ResourceTotals
profileTotals = foldr addEnvelope (ResourceTotals 0 0 0 0)
 where
  addEnvelope profileEnvelope accumulatedTotals =
    ResourceTotals
      { totalCpuMillis = cpu_millis profileEnvelope + totalCpuMillis accumulatedTotals
      , totalMemoryMib = memory_mib profileEnvelope + totalMemoryMib accumulatedTotals
      , totalEphemeralMib = ephemeral_mib profileEnvelope + totalEphemeralMib accumulatedTotals
      , totalPersistenceMib =
          persistence_mib profileEnvelope + totalPersistenceMib accumulatedTotals
      }

-- | The constant the profiles exist to hold: the replacement composition costs
-- what the superseded one cost, summed across the topology.
--
-- Without it a counterexample could be closed by giving the replacement more
-- of everything, which proves the defect is reachable at the old budget and
-- nothing else.
topologyNormalizedBudgetHolds :: CounterexampleResourceProfile -> Bool
topologyNormalizedBudgetHolds profile =
  profileTotals (superseded_envelopes profile)
    == profileTotals (replacement_envelopes profile)

-- | The lowercase hex SHA-256 of the artifact texts, NUL-separated in the order
-- given.  Both the separator and the order are part of the digest: without the
-- separator two artifacts could trade a trailing line for a leading one and
-- hash the same, and the same files in another order are a different set.
counterexampleArtifactDigestText :: [Text] -> Text
counterexampleArtifactDigestText contents =
  Text.pack
    ( concatMap
        renderHexByte
        ( ByteString.unpack
            ( SHA256.hash
                ( ByteString.intercalate
                    (ByteString.singleton 0)
                    (map TextEncoding.encodeUtf8 contents)
                )
            )
        )
    )
 where
  renderHexByte byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits
