-- | One family header plus bounded exact DNS01 record rows. Full DNS names
-- fit a 300-character row while the complete family stays below 4096 chars.
module Prodbox.Capacity.Dns01CleanupBudget
  ( dns01CleanupEvidenceMaximumRows
  , dns01CleanupEvidenceMaximumRowCharacters
  , dns01CleanupMaximumRecordNames
  )
where

dns01CleanupEvidenceMaximumRows :: Int
dns01CleanupEvidenceMaximumRows = 12

dns01CleanupEvidenceMaximumRowCharacters :: Int
dns01CleanupEvidenceMaximumRowCharacters = 300

dns01CleanupMaximumRecordNames :: Int
dns01CleanupMaximumRecordNames = dns01CleanupEvidenceMaximumRows - 1
