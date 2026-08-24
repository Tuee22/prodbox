{-# LANGUAGE DerivingStrategies #-}

-- | One exact, shared decision for whether the retained root-initialization
-- journal still proves that initialization may be prepared. Both the
-- controller and the independently attested worker consume this classifier;
-- neither may reinterpret a present journal on its own.
module Prodbox.Bootstrap.Broker.PristineJournal
  ( PristineJournalRefusal (..)
  , classifyPristineJournal
  )
where

import Prodbox.Bootstrap.Broker.Custody
  ( RootInitPhase (..)
  , RootInitState (..)
  )
import Prodbox.Bootstrap.Broker.ProductionCryptoParameters
  ( productionPristineStorageProof
  )
import Prodbox.Bootstrap.Broker.StoreBoundary
  ( StoreReadBack (..)
  )
import Prodbox.Bootstrap.Broker.Types
  ( PristineStorageProof
  , RootInitBinding
  , resetReplacementPristine
  )

data PristineJournalRefusal
  = PristineJournalBindingMismatch
  | PristineJournalProofMismatch
  | PristineJournalPhaseAdvanced
  deriving stock (Eq, Show)

classifyPristineJournal
  :: RootInitBinding
  -> StoreReadBack RootInitState
  -> Either PristineJournalRefusal PristineStorageProof
classifyPristineJournal binding observation =
  case observation of
    StoreObjectAbsent -> Right expected
    StoreObjectPresent _ _ state
      | rootInitStateBinding state /= binding ->
          Left PristineJournalBindingMismatch
      | otherwise ->
          case rootInitStatePhase state of
            RootInitPristine proof
              | proof == expected -> Right proof
              | otherwise -> Left PristineJournalProofMismatch
            RootResetPristine resetProof
              | replacement == expected -> Right replacement
              | otherwise -> Left PristineJournalProofMismatch
             where
              replacement = resetReplacementPristine resetProof
            _ -> Left PristineJournalPhaseAdvanced
 where
  expected = productionPristineStorageProof binding
