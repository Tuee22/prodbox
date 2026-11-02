-- | One exact, shared decision for whether the retained root-initialization
-- journal still proves that initialization may be prepared. Both the
-- fresh controller branch and independently attested worker use this kernel.
-- Advanced journals require separate continuation evidence, never this proof.
module Prodbox.Bootstrap.Broker.PristineJournal
  ( PristineJournalRefusal (..)
  , RootInitJournalObservation (..)
  , classifyPristineJournal
  , rootInitJournalObservation
  )
where

import Prodbox.Bootstrap.Broker.Custody (RootInitState)
import Prodbox.Bootstrap.Broker.InitializationEvidence
  ( PristineJournalRefusal (..)
  , RootInitJournalObservation (..)
  , classifyPristineJournalAgainst
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
  )

classifyPristineJournal
  :: RootInitBinding
  -> StoreReadBack RootInitState
  -> Either PristineJournalRefusal PristineStorageProof
classifyPristineJournal binding observation =
  classifyPristineJournalAgainst
    (productionPristineStorageProof binding)
    (rootInitJournalObservation observation)

rootInitJournalObservation :: StoreReadBack RootInitState -> RootInitJournalObservation
rootInitJournalObservation observation = case observation of
  StoreObjectAbsent -> RootInitJournalAbsent
  StoreObjectPresent version _ state -> RootInitJournalPresent version state
