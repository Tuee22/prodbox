-- | Opaque recovery-plane execution facade. Construction, raw component
-- observations, repository mutation, and observer injection remain
-- Authority-local in the hidden implementation module.
module Prodbox.Lifecycle.Teardown.RecoveryPlaneInterpreter
  ( RecoveryPlaneInterpreter
  , RecoveryPlaneInterpreterError (..)
  , executeRecoveryPlaneOperation
  , RecoveryPlaneReadBackPhase (..)
  , executeRecoveryPlaneDescriptorBoundPhase
  , recoveryPlaneDescriptorBoundNodeAction
  , RecoveryPlaneInterpreterRegression
  , fixedRecoveryPlaneInterpreterRegression
  , recoveryPlaneInterpreterEstablishExact
  , recoveryPlaneInterpreterInitialReadBackExact
  , recoveryPlaneInterpreterFinalReadBackExact
  , recoveryPlaneInterpreterRawExecutionRefused
  , recoveryPlaneInterpreterWrongPredecessorRefused
  , recoveryPlaneInterpreterTwoSurfaceRestartDispatch
  , recoveryPlaneInterpreterCompleteObservationSet
  , recoveryPlaneInterpreterOpacityClosed
  )
where

import Prodbox.Lifecycle.Teardown.RecoveryPlaneInterpreter.Internal
