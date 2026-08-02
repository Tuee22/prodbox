{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Host-side entrypoint for normal provider work.  Every supported caller
-- authenticates as an explicitly selected Lifecycle Authority client and asks
-- that Authority to journal, sign, dispatch, and settle the closed intent.
-- There is deliberately no host-to-Provider-Worker transport in this module.
module Prodbox.ControlPlane.ProviderCaller
  ( ProviderCallerError (..)
  , renderProviderCallerError
  , dispatchHostProviderIntent
  , dispatchHostProviderIntentFresh
  , dispatchAuthenticatedProviderIntent
  , dispatchAuthenticatedProviderIntentFresh
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Prodbox.ControlPlane.AuthorityProviderEndpoint
  ( AuthorityProviderClientError
  , dispatchAuthorityProviderIntent
  )
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller
  , LifecycleAuthorityAuthentication
  , LifecycleAuthorityAuthenticationError
  , renderLifecycleAuthorityAuthenticationError
  , withHostLifecycleAuthorityAuthentication
  , withLifecycleAuthorityAuthenticatedTransport
  )
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( ClientSubmissionKeyError
  , mkClientSubmissionKey
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork (ProviderIntent)

data ProviderCallerError
  = ProviderCallerSubmissionKeyInvalid !ClientSubmissionKeyError
  | ProviderCallerAuthenticationFailed !LifecycleAuthorityAuthenticationError
  | ProviderCallerDispatchFailed !AuthorityProviderClientError
  deriving stock (Eq, Show)

renderProviderCallerError :: ProviderCallerError -> String
renderProviderCallerError err = case err of
  ProviderCallerSubmissionKeyInvalid detail ->
    "validate Provider submission key: " ++ show detail
  ProviderCallerAuthenticationFailed detail ->
    renderLifecycleAuthorityAuthenticationError detail
  ProviderCallerDispatchFailed detail ->
    "Lifecycle Authority Provider dispatch failed: " ++ show detail

dispatchHostProviderIntent
  :: ExternalLifecycleAuthorityCaller
  -> FilePath
  -> Text
  -> ProviderIntent
  -> IO (Either ProviderCallerError Text)
dispatchHostProviderIntent caller repoRoot rawSubmissionKey intent =
  case mkClientSubmissionKey rawSubmissionKey of
    Left err -> pure (Left (ProviderCallerSubmissionKeyInvalid err))
    Right submissionKey -> do
      authenticated <-
        withHostLifecycleAuthorityAuthentication caller repoRoot $ \authentication ->
          withLifecycleAuthorityAuthenticatedTransport authentication $ \transport ->
            dispatchAuthorityProviderIntent transport submissionKey intent
      pure $ case authenticated of
        Left err -> Left (ProviderCallerAuthenticationFailed err)
        Right (Left err) -> Left (ProviderCallerAuthenticationFailed err)
        Right (Right (Left err)) -> Left (ProviderCallerDispatchFailed err)
        Right (Right (Right evidence)) -> Right evidence

dispatchAuthenticatedProviderIntent
  :: LifecycleAuthorityAuthentication
  -> Text
  -> ProviderIntent
  -> IO (Either ProviderCallerError Text)
dispatchAuthenticatedProviderIntent authentication rawSubmissionKey intent =
  case mkClientSubmissionKey rawSubmissionKey of
    Left err -> pure (Left (ProviderCallerSubmissionKeyInvalid err))
    Right submissionKey -> do
      dispatched <-
        withLifecycleAuthorityAuthenticatedTransport authentication $ \transport ->
          dispatchAuthorityProviderIntent transport submissionKey intent
      pure $ case dispatched of
        Left err -> Left (ProviderCallerAuthenticationFailed err)
        Right (Left err) -> Left (ProviderCallerDispatchFailed err)
        Right (Right evidence) -> Right evidence

-- | Allocate one bounded invocation key for an intrinsically idempotent
-- provider effect.  Public commands currently have no operation-id flag; the
-- microsecond suffix prevents an old completed observation/reconcile from
-- suppressing a later invocation while the Provider read-back still makes a
-- lost-response retry safe at the external resource boundary.
dispatchHostProviderIntentFresh
  :: ExternalLifecycleAuthorityCaller
  -> FilePath
  -> Text
  -> ProviderIntent
  -> IO (Either ProviderCallerError Text)
dispatchHostProviderIntentFresh caller repoRoot prefix intent = do
  submissionKey <- freshProviderSubmissionKey prefix
  dispatchHostProviderIntent caller repoRoot submissionKey intent

dispatchAuthenticatedProviderIntentFresh
  :: LifecycleAuthorityAuthentication
  -> Text
  -> ProviderIntent
  -> IO (Either ProviderCallerError Text)
dispatchAuthenticatedProviderIntentFresh authentication prefix intent = do
  submissionKey <- freshProviderSubmissionKey prefix
  dispatchAuthenticatedProviderIntent authentication submissionKey intent

freshProviderSubmissionKey :: Text -> IO Text
freshProviderSubmissionKey prefix = do
  now <- getPOSIXTime
  let micros = floor (now * 1000000) :: Integer
      boundedPrefix = Text.take 88 prefix
  pure (boundedPrefix <> "-" <> Text.pack (show micros))
