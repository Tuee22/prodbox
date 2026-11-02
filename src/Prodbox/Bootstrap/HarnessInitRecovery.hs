-- | The finite harness recovery prefix. A refused mutation never grants reset
-- permission: only the Broker's separately observed ambiguity selects its
-- registered audited repair, followed by an exact new-generation readback.
module Prodbox.Bootstrap.HarnessInitRecovery
  ( HarnessInitObservation (..)
  , HarnessInitDecision (..)
  , HarnessInitRecoveryCause (..)
  , decideHarnessInitRecovery
  , decideHarnessInitAfterResume
  , decideHarnessInitAfterReset
  , harnessBootstrapBudgetMicros
  , harnessBrokerCallBudgetMicros
  , harnessBrokerCallFits
  , harnessResetRequestGeneration
  ) where

import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.Client (brokerMutationTransportTimeoutMicros)
import Prodbox.Bootstrap.Broker.InitializationEvidence
  ( RootInitJournalPhase (..)
  , rootInitializationPending
  )
import Prodbox.Bootstrap.Broker.ResetEvidence (rootResetRequestGeneration)
import Prodbox.Bootstrap.Broker.Settings (maximumBrokerRequestDeadlineMilliseconds)
import Prodbox.Bootstrap.Broker.Types (VaultStorageGeneration)
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , DeadlineObservation (..)
  , MonotonicInstant
  , RemainingDuration (..)
  , deadlineObservation
  )

data HarnessInitObservation = HarnessInitObservation
  { harnessInitGeneration :: !VaultStorageGeneration
  , harnessInitInitialized :: !Bool
  , harnessInitSealed :: !Bool
  , harnessInitAmbiguous :: !Bool
  , harnessInitPhase :: !(Maybe RootInitJournalPhase)
  , harnessInitResetFrom :: !(Maybe VaultStorageGeneration)
  }
  deriving (Eq, Show)

data HarnessInitDecision
  = HarnessContinueBootstrap
  | HarnessResumeInitialization
  | HarnessResetAmbiguousInitialization
  | HarnessInitializationRefused !HarnessInitRecoveryCause
  deriving (Eq, Show)

data HarnessInitRecoveryCause
  = HarnessInitObservationInconsistent
  | HarnessInitResumeGenerationChanged
  | HarnessInitResumeUnresolved
  | HarnessInitResetGenerationUnchanged
  | HarnessInitResetLineageMismatch
  | HarnessInitResetNotPristine
  deriving (Eq, Show)

decideHarnessInitRecovery :: HarnessInitObservation -> HarnessInitDecision
decideHarnessInitRecovery observed
  | inconsistent observed = HarnessInitializationRefused HarnessInitObservationInconsistent
  | harnessInitAmbiguous observed =
      either
        HarnessInitializationRefused
        (const HarnessResetAmbiguousInitialization)
        (harnessResetRequestGeneration observed)
  | maybe False rootInitializationPending (harnessInitPhase observed) = HarnessResumeInitialization
  | otherwise = HarnessContinueBootstrap

decideHarnessInitAfterResume
  :: HarnessInitObservation -> HarnessInitObservation -> HarnessInitDecision
decideHarnessInitAfterResume original observed
  | harnessInitGeneration observed /= harnessInitGeneration original =
      HarnessInitializationRefused HarnessInitResumeGenerationChanged
  | inconsistent observed = HarnessInitializationRefused HarnessInitObservationInconsistent
  | harnessInitAmbiguous observed = HarnessResetAmbiguousInitialization
  | harnessInitInitialized observed && harnessInitPhase observed == Just InitCustodyDurable =
      HarnessContinueBootstrap
  | otherwise = HarnessInitializationRefused HarnessInitResumeUnresolved

decideHarnessInitAfterReset
  :: HarnessInitObservation -> HarnessInitObservation -> HarnessInitDecision
decideHarnessInitAfterReset original observed =
  either HarnessInitializationRefused close (harnessResetRequestGeneration original)
 where
  close requested
    | harnessInitGeneration observed == requested =
        HarnessInitializationRefused HarnessInitResetGenerationUnchanged
    | harnessInitResetFrom observed /= Just requested =
        HarnessInitializationRefused HarnessInitResetLineageMismatch
    | not (harnessInitInitialized observed)
        && harnessInitSealed observed
        && not (harnessInitAmbiguous observed)
        && harnessInitPhase observed == Just InitResetPristine =
        HarnessContinueBootstrap
    | otherwise = HarnessInitializationRefused HarnessInitResetNotPristine

harnessResetRequestGeneration
  :: HarnessInitObservation -> Either HarnessInitRecoveryCause VaultStorageGeneration
harnessResetRequestGeneration observed =
  either
    (const (Left HarnessInitResetLineageMismatch))
    Right
    ( rootResetRequestGeneration
        (harnessInitGeneration observed)
        (harnessInitPhase observed)
        (harnessInitResetFrom observed)
    )

inconsistent :: HarnessInitObservation -> Bool
inconsistent observed = case harnessInitPhase observed of
  Nothing -> False
  Just InitAmbiguous -> not (harnessInitAmbiguous observed)
  Just InitResetInFlight -> not (harnessInitAmbiguous observed)
  Just InitCustodyDurable -> not (harnessInitInitialized observed) || harnessInitAmbiguous observed
  Just _ -> harnessInitAmbiguous observed

-- The normal host bootstrap has three mutating requests (init, unseal,
-- baseline). Recovery shares that total, never a fresh budget per branch.
harnessBootstrapBudgetMicros :: Natural
harnessBootstrapBudgetMicros = 3 * fromIntegral brokerMutationTransportTimeoutMicros

-- Reserve both the existing HTTP transport maximum and a full server request
-- lifetime. Even a request delivered at the end of its transport window must
-- fit inside the parent. This deliberately conservative admission does not
-- change any child timeout or claim that cancellation proves remote absence.
harnessBrokerCallBudgetMicros :: Natural
harnessBrokerCallBudgetMicros =
  fromIntegral brokerMutationTransportTimeoutMicros
    + 1000 * maximumBrokerRequestDeadlineMilliseconds

harnessBrokerCallFits :: MonotonicInstant -> Deadline -> Bool
harnessBrokerCallFits now deadline = case deadlineObservation now deadline of
  DeadlineExpired -> False
  DeadlineOpen (RemainingDuration remaining) -> remaining >= harnessBrokerCallBudgetMicros
