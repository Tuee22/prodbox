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
  , dispatchHostProviderIntentOwnedBy
  , dispatchHostProviderIntentFresh
  , dispatchAuthenticatedProviderIntent
  , dispatchAuthenticatedProviderIntentFresh
  , dispatchAuthenticatedProviderIntentFreshWithOperation
  , freshProviderSubmissionKey
  , admitAuthenticatedProviderIntentAt
  , executeAdmittedProviderIntentAt
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Prodbox.ControlPlane.AuthorityProviderEndpoint
  ( AuthorityProviderClientError
  , admitAuthorityProviderIntentOwnedBy
  , dispatchAuthorityProviderIntent
  , dispatchAuthorityProviderIntentOwnedBy
  , dispatchAuthorityProviderIntentWithOperation
  )
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller
  , LifecycleAuthorityAuthentication
  , LifecycleAuthorityAuthenticationError
  , renderLifecycleAuthorityAuthenticationError
  , withHostLifecycleAuthorityAuthentication
  , withLifecycleAuthorityAuthenticatedTransport
  )
import Prodbox.Lifecycle.Authority.Admission
  ( ProviderOperationCleanupOwner (ProviderOperationUnownedByCleanupRun)
  )
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( ClientSubmissionKeyError
  , mkClientSubmissionKey
  )
import Prodbox.Lifecycle.Authority.Submission (OperationId)
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
  dispatchHostProviderIntentOwnedBy
    caller
    repoRoot
    rawSubmissionKey
    intent
    ProviderOperationUnownedByCleanupRun

-- | Sprint 4.85: dispatch and name the cleanup operation that authorized it.
--
-- Desired-present provisioning work keeps the unowned form above and says so
-- explicitly; a teardown dispatch names its cleanup operation, so the retained
-- Provider record can be attributed to the run that authorized it.
dispatchHostProviderIntentOwnedBy
  :: ExternalLifecycleAuthorityCaller
  -> FilePath
  -> Text
  -> ProviderIntent
  -> ProviderOperationCleanupOwner
  -> IO (Either ProviderCallerError Text)
dispatchHostProviderIntentOwnedBy caller repoRoot rawSubmissionKey intent owner =
  case mkClientSubmissionKey rawSubmissionKey of
    Left err -> pure (Left (ProviderCallerSubmissionKeyInvalid err))
    Right submissionKey -> do
      authenticated <-
        withHostLifecycleAuthorityAuthentication caller repoRoot $ \authentication ->
          withLifecycleAuthorityAuthenticatedTransport authentication $ \transport ->
            fmap snd
              <$> dispatchAuthorityProviderIntentOwnedBy
                transport
                submissionKey
                intent
                owner
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
dispatchAuthenticatedProviderIntentFresh authentication prefix intent =
  fmap
    (fmap snd)
    (dispatchAuthenticatedProviderIntentFreshWithOperation authentication prefix intent)

-- | Sprint 4.84: dispatch and keep the operation the Authority admitted.
--
-- A caller that must later /name/ what it submitted — the registered-stack
-- creation lane is the first — needs the 'OperationId', and it cannot derive
-- one: the epoch and client sequence are assigned at admission. This is the
-- form that carries it out.
dispatchAuthenticatedProviderIntentFreshWithOperation
  :: LifecycleAuthorityAuthentication
  -> Text
  -> ProviderIntent
  -> IO (Either ProviderCallerError (OperationId, Text))
dispatchAuthenticatedProviderIntentFreshWithOperation authentication prefix intent = do
  submissionKey <- freshProviderSubmissionKey prefix
  case mkClientSubmissionKey submissionKey of
    Left err -> pure (Left (ProviderCallerSubmissionKeyInvalid err))
    Right validated -> do
      dispatched <-
        withLifecycleAuthorityAuthenticatedTransport authentication $ \transport ->
          dispatchAuthorityProviderIntentWithOperation transport validated intent
      pure $ case dispatched of
        Left err -> Left (ProviderCallerAuthenticationFailed err)
        Right (Left err) -> Left (ProviderCallerDispatchFailed err)
        Right (Right settled) -> Right settled

-- | Sprint 7.36: admit one Provider submission at an exact submission key and
-- stop, without executing it.
--
-- The key is the exact one, not a prefix: the whole point of the two-step lane
-- is that the /same/ key names the same operation in both calls, so allocating a
-- fresh one here would admit an operation the execute step could never reach.
-- Use 'freshProviderSubmissionKey' once and hold the result across both.
admitAuthenticatedProviderIntentAt
  :: LifecycleAuthorityAuthentication
  -> Text
  -> ProviderIntent
  -> IO (Either ProviderCallerError OperationId)
admitAuthenticatedProviderIntentAt authentication rawSubmissionKey intent =
  case mkClientSubmissionKey rawSubmissionKey of
    Left err -> pure (Left (ProviderCallerSubmissionKeyInvalid err))
    Right submissionKey -> do
      admitted <-
        withLifecycleAuthorityAuthenticatedTransport authentication $ \transport ->
          admitAuthorityProviderIntentOwnedBy
            transport
            submissionKey
            intent
            ProviderOperationUnownedByCleanupRun
      pure $ case admitted of
        Left err -> Left (ProviderCallerAuthenticationFailed err)
        Right (Left err) -> Left (ProviderCallerDispatchFailed err)
        Right (Right operation) -> Right operation

-- | Sprint 7.36: execute the operation an earlier
-- 'admitAuthenticatedProviderIntentAt' admitted at this exact submission key.
--
-- The intent must be the one that was admitted; the Authority refuses a
-- divergent replay of a retained submission rather than executing it.
executeAdmittedProviderIntentAt
  :: LifecycleAuthorityAuthentication
  -> Text
  -> ProviderIntent
  -> IO (Either ProviderCallerError (OperationId, Text))
executeAdmittedProviderIntentAt authentication rawSubmissionKey intent =
  case mkClientSubmissionKey rawSubmissionKey of
    Left err -> pure (Left (ProviderCallerSubmissionKeyInvalid err))
    Right submissionKey -> do
      dispatched <-
        withLifecycleAuthorityAuthenticatedTransport authentication $ \transport ->
          dispatchAuthorityProviderIntentWithOperation transport submissionKey intent
      pure $ case dispatched of
        Left err -> Left (ProviderCallerAuthenticationFailed err)
        Right (Left err) -> Left (ProviderCallerDispatchFailed err)
        Right (Right settled) -> Right settled

freshProviderSubmissionKey :: Text -> IO Text
freshProviderSubmissionKey prefix = do
  now <- getPOSIXTime
  let micros = floor (now * 1000000) :: Integer
      boundedPrefix = Text.take 88 prefix
  pure (boundedPrefix <> "-" <> Text.pack (show micros))
