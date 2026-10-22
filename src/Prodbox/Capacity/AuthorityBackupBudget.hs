-- | Coupled retained-replay and container memory bounds for Authority Backup.
module Prodbox.Capacity.AuthorityBackupBudget
  ( authorityBackupAggregateResponseMaximumBytes
  , authorityBackupRetainedCopyResponseMaximumBytes
  , authorityCheckpointClientRetryAttempts
  , authorityCheckpointBackupPerProviderRequestMaximum
  , authorityCheckpointBackupPerOutputReadMaximum
  , authorityCheckpointBackupPerGraphOperationMaximum
  , authorityBackupReplayMaximumEncodedBytes
  , authorityBackupProductionMemoryMebibytes
  )
where

import Numeric.Natural (Natural)

authorityBackupAggregateResponseMaximumBytes :: Int
authorityBackupAggregateResponseMaximumBytes = 40 * 1024

-- Copy replies are metadata-only receipts; observe replies retain the fixed
-- fresh-nonce refusal. Enforce the copy bound at its producer before HTTP 200.
authorityBackupRetainedCopyResponseMaximumBytes :: Int
authorityBackupRetainedCopyResponseMaximumBytes = 4 * 1024

-- This is the actual bounded retry loop used by EncryptedBackend.
authorityCheckpointClientRetryAttempts :: Int
authorityCheckpointClientRetryAttempts = 3

-- A stack mutation can hydrate before, during, and after its apply. Publication
-- copies once and independently reads back twice (replication and confirmation).
-- Bound every Provider RPC by this largest checkpoint-using branch; native
-- observations, audits and the plant have smaller or zero checkpoint traffic.
authorityCheckpointBackupPerProviderRequestMaximum :: Natural
authorityCheckpointBackupPerProviderRequestMaximum =
  fromIntegral authorityCheckpointClientRetryAttempts * (3 + 3)

-- The host output reader hydrates once and can republish its unchanged scratch
-- checkpoint through the same three-call publication boundary.
authorityCheckpointBackupPerOutputReadMaximum :: Natural
authorityCheckpointBackupPerOutputReadMaximum =
  fromIntegral authorityCheckpointClientRetryAttempts * (1 + 3)

-- The typed cleanup checkpoint nodes have no EncryptedBackend retry loop. Their
-- longest recovery path observes the pair, restores, confirms, and re-observes.
authorityCheckpointBackupPerGraphOperationMaximum :: Natural
authorityCheckpointBackupPerGraphOperationMaximum = 4

-- Two complete caller envelopes include compact checkpoint observations and
-- bounded copy receipts. A mixed old-journal/new-compact envelope fits in this
-- production ceiling, including canonical replay metadata.
authorityBackupReplayMaximumEncodedBytes :: Int
authorityBackupReplayMaximumEncodedBytes = 64 * mebibyte

-- Encoded input, decoded retained responses and replacement encoding can
-- coexist. The established 48 MiB native/runtime allowance is unchanged.
authorityBackupProductionMemoryMebibytes :: Natural
authorityBackupProductionMemoryMebibytes =
  3 * fromIntegral (authorityBackupReplayMaximumEncodedBytes `div` mebibyte) + 48

mebibyte :: Int
mebibyte = 1024 * 1024
