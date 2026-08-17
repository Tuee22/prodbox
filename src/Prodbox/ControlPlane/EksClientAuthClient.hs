{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Host consumer for the Provider-owned EKS client-auth capability. The
-- bearer is opened only after authenticated Authority dispatch and is passed
-- directly to a scoped callback; Provider state and evidence see ciphertext.
module Prodbox.ControlPlane.EksClientAuthClient
  ( EksClientAuthClientError (..)
  , withEksClientAuthProjection
  , withEksClientAuthProjectionForExecution
  , withEksClientAuthProjectionForTeardownExecution
  , eksClientAuthExecutionSubmissionKey
  , eksClientAuthTeardownExecutionSubmissionKey
  )
where

import Data.ByteString.Base64 qualified as Base64
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock.POSIX (getPOSIXTime)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.ControlPlane.EksClientAuthProjection
  ( EksClientAuthEnvelope
  , EksClientAuthProjection
  , decodeEksClientAuthEnvelope
  , eksClientAuthAccountId
  , eksClientAuthClusterName
  , eksClientAuthExpiresAtEpochSeconds
  , eksClientAuthPublicKeyBytes
  , eksClientAuthRegion
  , openEksClientAuthProjection
  , prepareEksClientAuthDestination
  )
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller
  )
import Prodbox.ControlPlane.ProviderCaller
  ( ProviderCallerError
  , dispatchHostProviderIntent
  , dispatchHostProviderIntentFresh
  )
import Prodbox.Lifecycle.CleanupRun
  ( cleanupAttemptIdText
  , cleanupDigestText
  , cleanupNodeIdText
  , cleanupOperationIdText
  , cleanupRunIdText
  )
import Prodbox.Lifecycle.CleanupRunRunner
  ( CleanupNodeExecutionContext
  , cleanupNodeExecutionAttemptId
  , cleanupNodeExecutionGraphDigest
  , cleanupNodeExecutionNodeId
  , cleanupNodeExecutionRunId
  )
import Prodbox.Lifecycle.Teardown.ExecutionIdentity
  ( TeardownExecutionIdentity
  , teardownExecutionIdentityAttemptId
  , teardownExecutionIdentityGraphDigest
  , teardownExecutionIdentityNodeId
  , teardownExecutionIdentityOperationId
  , teardownExecutionIdentityRunId
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (IssueEksClientAuth, ObserveOperationalIdentity)
  , mkEksClientAuthRequest
  )

data EksClientAuthClientError
  = EksClientAuthIdentityDispatchFailed !ProviderCallerError
  | EksClientAuthIdentityEvidenceInvalid
  | EksClientAuthRequestInvalid
  | EksClientAuthDispatchFailed !ProviderCallerError
  | EksClientAuthEvidenceInvalid
  | EksClientAuthProjectionExpired
  | EksClientAuthProjectionBindingMismatch
  deriving stock (Eq, Show)

withEksClientAuthProjection
  :: ExternalLifecycleAuthorityCaller
  -> FilePath
  -> Text
  -> Text
  -> (EksClientAuthProjection -> IO value)
  -> IO (Either EksClientAuthClientError value)
withEksClientAuthProjection caller repoRoot requestedRegion requestedCluster action = do
  identity <-
    dispatchHostProviderIntentFresh
      caller
      repoRoot
      "eks-client-auth-identity"
      ObserveOperationalIdentity
  case identity of
    Left err -> pure (Left (EksClientAuthIdentityDispatchFailed err))
    Right evidence -> case accountFromIdentityEvidence evidence of
      Nothing -> pure (Left EksClientAuthIdentityEvidenceInvalid)
      Just account ->
        issueProjection
          (dispatchHostProviderIntentFresh caller repoRoot "eks-client-auth")
          account
          requestedRegion
          requestedCluster
          action

-- | Cleanup-only issuance bound to the opaque execution admission minted from
-- the durable run, graph, node, and fenced attempt.  A process-loss recovery
-- receives a new admission, so its new ephemeral X25519 destination cannot
-- collide with another run or the interrupted attempt.  A caller must not
-- retry this function with a different destination under the same admission.
withEksClientAuthProjectionForExecution
  :: ExternalLifecycleAuthorityCaller
  -> FilePath
  -> CleanupNodeExecutionContext
  -> Text
  -> Text
  -> Text
  -> (EksClientAuthProjection -> IO value)
  -> IO (Either EksClientAuthClientError value)
withEksClientAuthProjectionForExecution caller repoRoot execution account requestedRegion requestedCluster action =
  issueProjection
    ( dispatchHostProviderIntent
        caller
        repoRoot
        (eksClientAuthExecutionSubmissionKey execution)
    )
    account
    requestedRegion
    requestedCluster
    action

-- | A bounded, collision-resistant Authority submission key over the full
-- cleanup execution identity.  No caller-supplied identity is truncated.
eksClientAuthExecutionSubmissionKey :: CleanupNodeExecutionContext -> Text
eksClientAuthExecutionSubmissionKey execution =
  "eks-auth-execution-"
    <> TextEncoding.decodeUtf8
      (hexSha256 (TextEncoding.encodeUtf8 canonicalExecution))
 where
  canonicalExecution =
    Text.concat
      ( map
          frame
          [ "eks-client-auth-execution/v2"
          , cleanupRunIdText (cleanupNodeExecutionRunId execution)
          , cleanupDigestText (cleanupNodeExecutionGraphDigest execution)
          , cleanupNodeIdText (cleanupNodeExecutionNodeId execution)
          , cleanupAttemptIdText (cleanupNodeExecutionAttemptId execution)
          ]
      )
  frame value = Text.pack (show (Text.length value)) <> ":" <> value

-- | Issue a cleanup projection from the sealed lifecycle interpreter context.
-- The current node and its fenced attempt authorize the Provider request;
-- callers separately bind the resulting session to the future drain effect
-- operation.  This prevents commit-time selection from pretending to be the
-- later mutation node merely to obtain credentials.
withEksClientAuthProjectionForTeardownExecution
  :: ExternalLifecycleAuthorityCaller
  -> FilePath
  -> TeardownExecutionIdentity
  -> Text
  -> Text
  -> Text
  -> (EksClientAuthProjection -> IO value)
  -> IO (Either EksClientAuthClientError value)
withEksClientAuthProjectionForTeardownExecution caller repoRoot execution account requestedRegion requestedCluster action =
  issueProjection
    ( dispatchHostProviderIntent
        caller
        repoRoot
        (eksClientAuthTeardownExecutionSubmissionKey execution)
    )
    account
    requestedRegion
    requestedCluster
    action

-- | Collision-resistant Provider submission identity for a compiled
-- teardown node.  The constructor of 'TeardownExecutionContext' is private,
-- so none of these coordinates can be supplied independently by an effect
-- interpreter.
eksClientAuthTeardownExecutionSubmissionKey
  :: TeardownExecutionIdentity -> Text
eksClientAuthTeardownExecutionSubmissionKey execution =
  "eks-auth-teardown-execution-"
    <> TextEncoding.decodeUtf8
      (hexSha256 (TextEncoding.encodeUtf8 canonicalExecution))
 where
  canonicalExecution =
    Text.concat
      ( map
          frame
          [ "eks-client-auth-teardown-execution/v3"
          , cleanupRunIdText (teardownExecutionIdentityRunId execution)
          , cleanupDigestText (teardownExecutionIdentityGraphDigest execution)
          , cleanupNodeIdText (teardownExecutionIdentityNodeId execution)
          , cleanupOperationIdText (teardownExecutionIdentityOperationId execution)
          , cleanupAttemptIdText (teardownExecutionIdentityAttemptId execution)
          ]
      )
  frame value = Text.pack (show (Text.length value)) <> ":" <> value

issueProjection
  :: (ProviderIntent -> IO (Either ProviderCallerError Text))
  -> Text
  -> Text
  -> Text
  -> (EksClientAuthProjection -> IO value)
  -> IO (Either EksClientAuthClientError value)
issueProjection dispatch account requestedRegion requestedCluster action = do
  (destination, publicKey) <- prepareEksClientAuthDestination
  case mkEksClientAuthRequest
    account
    requestedRegion
    requestedCluster
    (eksClientAuthPublicKeyBytes publicKey) of
    Left _ -> pure (Left EksClientAuthRequestInvalid)
    Right request -> do
      dispatched <- dispatch (IssueEksClientAuth request)
      case dispatched of
        Left err -> pure (Left (EksClientAuthDispatchFailed err))
        Right retainedEvidence -> case decodeEvidence retainedEvidence of
          Left err -> pure (Left err)
          Right envelope -> case openEksClientAuthProjection destination envelope of
            Left _ -> pure (Left EksClientAuthEvidenceInvalid)
            Right projection -> do
              now <- floor <$> getPOSIXTime
              if eksClientAuthExpiresAtEpochSeconds projection <= now
                then pure (Left EksClientAuthProjectionExpired)
                else
                  if eksClientAuthAccountId projection /= account
                    || eksClientAuthRegion projection /= requestedRegion
                    || eksClientAuthClusterName projection /= requestedCluster
                    then pure (Left EksClientAuthProjectionBindingMismatch)
                    else Right <$> action projection

accountFromIdentityEvidence :: Text -> Maybe Text
accountFromIdentityEvidence evidence = do
  arn <- Text.stripPrefix "sts-identity:" evidence
  case Text.splitOn ":" arn of
    _partition : _service : _region : account : _resource
      | Text.length account == 12 && Text.all isAsciiDigit account -> Just account
    _ -> Nothing
 where
  isAsciiDigit character = character >= '0' && character <= '9'

decodeEvidence :: Text -> Either EksClientAuthClientError EksClientAuthEnvelope
decodeEvidence retainedEvidence = do
  encoded <-
    maybe
      (Left EksClientAuthEvidenceInvalid)
      Right
      (Text.stripPrefix "eks-client-auth-envelope:" retainedEvidence)
  bytes <-
    either
      (const (Left EksClientAuthEvidenceInvalid))
      Right
      (Base64.decode (TextEncoding.encodeUtf8 encoded))
  either (const (Left EksClientAuthEvidenceInvalid)) Right (decodeEksClientAuthEnvelope bytes)
