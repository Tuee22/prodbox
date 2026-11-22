{-# LANGUAGE DerivingStrategies #-}

-- | The pure rule that turns what an Authority journal reader observed into a
-- lifecycle admission verdict. Three facts must never be confused: a journal
-- that was read and is empty, a journal that could not be read, and a journal
-- that is missing although history is known to have existed. Only the first
-- of those may be reported as never admitted; the other two require recovery,
-- and a durable operation that has not settled forbids a no-change answer.
-- The rule reads nothing itself; a caller supplies the observation, so a stale
-- projection or a missing read can only ever produce 'RecoveryRequired'.
module Prodbox.Lifecycle.AdmissionHistory
  ( JournalObservation (..)
  , OperationState (..)
  , RecoveryReason (..)
  , AdmissionVerdict (..)
  , classifyAdmission
  , noChangeAllowed
  , mutationAllowed
  , renderVerdict
  ) where

import Data.Text (Text)
import Data.Text qualified as Text

-- | One durable operation as the journal records it.
data OperationState
  = OperationSettled
  | -- | An intent was registered and no terminal record follows it.
    OperationUnresolved
  deriving stock (Eq, Show)

-- | What the journal reader actually observed.
data JournalObservation
  = -- | The read could not be completed (storage, authentication, decoding).
    JournalUnobservable Text
  | -- | The journal location is absent. The flag says whether any record of
    -- earlier history survives elsewhere (a history marker, a retained
    -- projection, a backup manifest).
    JournalMissing Bool
  | -- | The journal was read; these are its operations, oldest first.
    JournalRead [(Text, OperationState)]
  deriving stock (Eq, Show)

data RecoveryReason
  = RecoveryJournalUnobservable Text
  | RecoveryHistoryMissing
  deriving stock (Eq, Show)

data AdmissionVerdict
  = NeverAdmitted
  | AdmittedSettled
  | -- | Operation identities that are still unresolved.
    AdmittedPending [Text]
  | RecoveryRequired RecoveryReason
  deriving stock (Eq, Show)

classifyAdmission :: JournalObservation -> AdmissionVerdict
classifyAdmission observation = case observation of
  JournalUnobservable reason -> RecoveryRequired (RecoveryJournalUnobservable reason)
  JournalMissing True -> RecoveryRequired RecoveryHistoryMissing
  JournalMissing False -> NeverAdmitted
  JournalRead [] -> NeverAdmitted
  JournalRead operations -> case [name | (name, OperationUnresolved) <- operations] of
    [] -> AdmittedSettled
    pending -> AdmittedPending pending

-- | A "nothing to do" answer is licensed only when nothing is unresolved or
-- unknown.
noChangeAllowed :: AdmissionVerdict -> Bool
noChangeAllowed verdict = case verdict of
  NeverAdmitted -> True
  AdmittedSettled -> True
  AdmittedPending _ -> False
  RecoveryRequired _ -> False

-- | A new mutation needs a settled, known history (or none at all).
mutationAllowed :: AdmissionVerdict -> Bool
mutationAllowed = noChangeAllowed

-- | A one-line, value-free rendering for the public read command.
renderVerdict :: AdmissionVerdict -> String
renderVerdict verdict = case verdict of
  NeverAdmitted -> "never-admitted: the journal holds no operation and no history survives; nothing was admitted."
  AdmittedSettled -> "admitted-settled: every recorded operation has settled."
  AdmittedPending names ->
    "admitted-pending: unresolved operations "
      ++ show (map Text.unpack names)
      ++ "; no no-change answer is licensed."
  RecoveryRequired (RecoveryJournalUnobservable reason) ->
    "recovery-required: the journal could not be observed ("
      ++ Text.unpack reason
      ++ "); it is not reported as absent."
  RecoveryRequired RecoveryHistoryMissing ->
    "recovery-required: the journal is missing although history existed; it is not reported as fresh."
