{-# LANGUAGE OverloadedStrings #-}

-- | The pure bridge from the Authority's real submission ledger to the
-- admission verdict. The ledger is the retained record of every operation a
-- caller submitted: in-flight records are unresolved durable intents, settled
-- records are terminal tombstones, and a client whose compaction floor is above
-- zero proves history existed even when every record below the floor has been
-- compacted away. Only a ledger with no client at all, and so no floor and no
-- record, has no history; everything else is admitted history. Reading is a
-- projection of what the ledger holds; it never invents absence.
module Prodbox.Lifecycle.AdmissionLedgerProjection
  ( ledgerJournalObservation
  ) where

import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.AdmissionHistory (JournalObservation (..), OperationState (..))
import Prodbox.Lifecycle.Authority.Submission
  ( ClientId (..)
  , ClientSequence (..)
  , ClientSubmissions (..)
  , SubmissionLedger (..)
  , SubmissionRecord (..)
  )

ledgerJournalObservation :: SubmissionLedger -> JournalObservation
ledgerJournalObservation ledger =
  JournalRead (concatMap clientOperations (Map.toList (submissionClients ledger)))

clientOperations :: (ClientId, ClientSubmissions) -> [(Text, OperationState)]
clientOperations (ClientId client, ClientSubmissions floorSequence records) =
  compacted
    ++ [ (label sequenceNumber, stateOf record)
       | (ClientSequence sequenceNumber, record) <- Map.toAscList records
       ]
 where
  ClientSequence floorValue = floorSequence
  -- Records at or below the floor were settled and compacted away; the floor
  -- itself is the surviving proof that they existed.
  compacted
    | floorValue > 0 = [(client <> ":compacted-through-" <> naturalText floorValue, OperationSettled)]
    | otherwise = []
  label sequenceNumber = client <> ":" <> naturalText sequenceNumber
  stateOf record = case record of
    SubmissionInFlight _ -> OperationUnresolved
    SubmissionSettled _ _ -> OperationSettled

naturalText :: Natural -> Text
naturalText = Text.pack . show
