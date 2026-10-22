-- | One complete registered mail cleanup fits the existing Provider deadline.
module Prodbox.Capacity.SesCaptureCleanupBudget
  ( maximumCleanupMailVersions
  , maximumCleanupMailListingPages
  , maximumCleanupMailListedRows
  , maximumCleanupMailMessageBytes
  , maximumCleanupMailAwsChildCalls
  )
where

maximumCleanupMailVersions :: Int
maximumCleanupMailVersions = 8

maximumCleanupMailListingPages :: Int
maximumCleanupMailListingPages = 6

maximumCleanupMailListedRows :: Int
maximumCleanupMailListedRows = maximumCleanupMailListingPages * 1000

maximumCleanupMailMessageBytes :: Int
maximumCleanupMailMessageBytes = 1024 * 1024

-- Observe, apply's re-observation, independent read-back; one tag guard for
-- each scan, plus exact version deletes. A scan reads every selected data
-- version, including versions that belong to other recipients.
maximumCleanupMailAwsChildCalls :: Int
maximumCleanupMailAwsChildCalls =
  3 * (maximumCleanupMailListingPages + maximumCleanupMailVersions)
    + maximumCleanupMailVersions
    + 3
