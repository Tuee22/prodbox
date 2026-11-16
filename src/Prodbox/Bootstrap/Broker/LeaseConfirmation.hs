-- | Classify a caller-supplied Lease observation around a deadline. This
-- boundary owns no store or release capability; a late or unobservable
-- response cannot establish that a remote write had no effect.
module Prodbox.Bootstrap.Broker.LeaseConfirmation
  ( LeaseConfirmationFailure (..)
  , confirmLeaseEffect
  ) where

import Prodbox.Bootstrap.Broker.Fence
  ( BootstrapLeaseObservation
  , BootstrapLeaseRefusal
  , BootstrapSessionFence
  , confirmBootstrapLease
  )
import Prodbox.ControlPlane.Deadline (Deadline, MonotonicInstant)
import Prodbox.ControlPlane.Interpreter (DeadlineEffectResult (..), observeDeadlineEffect)

data LeaseConfirmationFailure
  = LeaseConfirmationNotStarted
  | LeaseConfirmationLate
  | LeaseConfirmationRefused BootstrapLeaseRefusal
  deriving (Eq, Show)

confirmLeaseEffect
  :: (Monad m)
  => m MonotonicInstant
  -> Deadline
  -> BootstrapSessionFence
  -> m BootstrapLeaseObservation
  -> m (Either LeaseConfirmationFailure ())
confirmLeaseEffect now deadline fence action = do
  observed <- observeDeadlineEffect now deadline action
  pure $ case observed of
    DeadlineEffectNotStarted -> Left LeaseConfirmationNotStarted
    DeadlineEffectCompletedLate _ -> Left LeaseConfirmationLate
    DeadlineEffectCompleted sampled lease ->
      case confirmBootstrapLease sampled fence lease of
        Left refusal -> Left (LeaseConfirmationRefused refusal)
        Right _ -> Right ()
