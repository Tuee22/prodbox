-- | Retained replay bytes and the memory needed while decoding and replacing
-- the same projection. These are production ceilings, independently exercised
-- by the authenticated transport schedule proofs.
module Prodbox.Capacity.ControlPlaneReplayBudget
  ( lifecycleAuthorityReplayMaximumEncodedBytes
  , lifecycleAuthorityProductionMemoryMebibytes
  , targetSecretAgentReplayMaximumEncodedBytes
  , targetSecretAgentProductionMemoryMebibytes
  , tlsRetentionAdapterReplayMaximumEncodedBytes
  , tlsRetentionAdapterProductionMemoryMebibytes
  , authorityMetadataResponseMaximumBytes
  , awsAdminResponseMaximumBytes
  , checkpointMetadataResponseMaximumBytes
  ) where

import Numeric.Natural (Natural)

lifecycleAuthorityReplayMaximumEncodedBytes :: Int
lifecycleAuthorityReplayMaximumEncodedBytes = 212 * mebibyte

lifecycleAuthorityProductionMemoryMebibytes :: Natural
lifecycleAuthorityProductionMemoryMebibytes =
  replayMemoryFloor lifecycleAuthorityReplayMaximumEncodedBytes 92

targetSecretAgentReplayMaximumEncodedBytes :: Int
targetSecretAgentReplayMaximumEncodedBytes = 208 * mebibyte

targetSecretAgentProductionMemoryMebibytes :: Natural
targetSecretAgentProductionMemoryMebibytes =
  replayMemoryFloor targetSecretAgentReplayMaximumEncodedBytes 48

tlsRetentionAdapterReplayMaximumEncodedBytes :: Int
tlsRetentionAdapterReplayMaximumEncodedBytes = 78 * mebibyte

tlsRetentionAdapterProductionMemoryMebibytes :: Natural
tlsRetentionAdapterProductionMemoryMebibytes =
  replayMemoryFloor tlsRetentionAdapterReplayMaximumEncodedBytes 48

-- The encoded input, decoded projection and replacement encoding can coexist.
-- Runtime reserves are separate from these three bounded representations.
replayMemoryFloor :: Int -> Natural -> Natural
replayMemoryFloor bytes runtimeReserve =
  3 * fromIntegral ((bytes + mebibyte - 1) `div` mebibyte) + runtimeReserve

authorityMetadataResponseMaximumBytes :: Int
authorityMetadataResponseMaximumBytes = 64 * 1024

awsAdminResponseMaximumBytes :: Int
awsAdminResponseMaximumBytes = 64 * 1024

checkpointMetadataResponseMaximumBytes :: Int
checkpointMetadataResponseMaximumBytes = 4 * 1024

mebibyte :: Int
mebibyte = 1024 * 1024
