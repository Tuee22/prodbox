{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Closed, payload-free progress observations for one Provider Worker request.
-- The observer deliberately has no field through which an intent, credential,
-- Vault/AWS detail, response body, or exception can escape.
module Prodbox.ControlPlane.ProviderWorkerDiagnostic
  ( ProviderWorkerRequestStage (..)
  , allProviderWorkerRequestStages
  , renderProviderWorkerRequestStage
  , ProviderWorkerRequestCause (..)
  , allProviderWorkerRequestCauses
  , renderProviderWorkerRequestCause
  , ProviderWorkerRequestObserver
  , mkProviderWorkerRequestObserver
  , silentProviderWorkerRequestObserver
  , observeProviderWorkerRequest
  )
where

import Control.Exception
  ( SomeAsyncException
  , SomeException
  , fromException
  , throwIO
  , try
  )
import Data.Text (Text)
import GHC.Generics (Generic)

data ProviderWorkerRequestStage
  = ProviderWorkerSocketIngress
  | ProviderWorkerAuthenticatedIngress
  | ProviderWorkerIntentAdmission
  | ProviderWorkerTrustRevalidation
  | ProviderWorkerClockRevalidation
  | ProviderWorkerNarrowSession
  | ProviderWorkerCredentialBinding
  | ProviderWorkerCapabilityExecution
  | ProviderWorkerAuthorityProjection
  | ProviderWorkerResponseEncoding
  | ProviderWorkerSocketCompletion
  deriving (Bounded, Enum, Eq, Generic, Show)

allProviderWorkerRequestStages :: [ProviderWorkerRequestStage]
allProviderWorkerRequestStages = [minBound .. maxBound]

renderProviderWorkerRequestStage :: ProviderWorkerRequestStage -> Text
renderProviderWorkerRequestStage stage = case stage of
  ProviderWorkerSocketIngress -> "socket-ingress"
  ProviderWorkerAuthenticatedIngress -> "authenticated-ingress"
  ProviderWorkerIntentAdmission -> "intent-admission"
  ProviderWorkerTrustRevalidation -> "trust-revalidation"
  ProviderWorkerClockRevalidation -> "clock-revalidation"
  ProviderWorkerNarrowSession -> "narrow-session"
  ProviderWorkerCredentialBinding -> "credential-binding"
  ProviderWorkerCapabilityExecution -> "capability-execution"
  ProviderWorkerAuthorityProjection -> "authority-projection"
  ProviderWorkerResponseEncoding -> "response-encoding"
  ProviderWorkerSocketCompletion -> "socket-completion"

data ProviderWorkerRequestCause
  = ProviderWorkerStageStarted
  | ProviderWorkerStageCompleted
  | ProviderWorkerStageRefused
  deriving (Bounded, Enum, Eq, Generic, Show)

allProviderWorkerRequestCauses :: [ProviderWorkerRequestCause]
allProviderWorkerRequestCauses = [minBound .. maxBound]

renderProviderWorkerRequestCause :: ProviderWorkerRequestCause -> Text
renderProviderWorkerRequestCause cause = case cause of
  ProviderWorkerStageStarted -> "started"
  ProviderWorkerStageCompleted -> "completed"
  ProviderWorkerStageRefused -> "refused"

newtype ProviderWorkerRequestObserver = ProviderWorkerRequestObserver
  { runProviderWorkerRequestObserver
      :: ProviderWorkerRequestStage
      -> ProviderWorkerRequestCause
      -> IO ()
  }

mkProviderWorkerRequestObserver
  :: (ProviderWorkerRequestStage -> ProviderWorkerRequestCause -> IO ())
  -> ProviderWorkerRequestObserver
mkProviderWorkerRequestObserver = ProviderWorkerRequestObserver

silentProviderWorkerRequestObserver :: ProviderWorkerRequestObserver
silentProviderWorkerRequestObserver = ProviderWorkerRequestObserver (\_ _ -> pure ())

-- | A diagnostic failure cannot change an ordinary request outcome. Async
-- cancellation remains cancellation and is rethrown unchanged.
observeProviderWorkerRequest
  :: ProviderWorkerRequestObserver
  -> ProviderWorkerRequestStage
  -> ProviderWorkerRequestCause
  -> IO ()
observeProviderWorkerRequest observer stage cause = do
  observed <-
    try (runProviderWorkerRequestObserver observer stage cause)
      :: IO (Either SomeException ())
  case observed of
    Right () -> pure ()
    Left exception -> case fromException exception :: Maybe SomeAsyncException of
      Just _ -> throwIO exception
      Nothing -> pure ()
