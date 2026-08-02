{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Host consumer for the Provider-owned EKS client-auth capability. The
-- bearer is opened only after authenticated Authority dispatch and is passed
-- directly to a scoped callback; Provider state and evidence see ciphertext.
module Prodbox.ControlPlane.EksClientAuthClient
  ( EksClientAuthClientError (..)
  , withEksClientAuthProjection
  )
where

import Data.ByteString.Base64 qualified as Base64
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock.POSIX (getPOSIXTime)
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
  , dispatchHostProviderIntentFresh
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
      Just account -> do
        (destination, publicKey) <- prepareEksClientAuthDestination
        case mkEksClientAuthRequest
          account
          requestedRegion
          requestedCluster
          (eksClientAuthPublicKeyBytes publicKey) of
          Left _ -> pure (Left EksClientAuthRequestInvalid)
          Right request -> do
            dispatched <-
              dispatchHostProviderIntentFresh
                caller
                repoRoot
                "eks-client-auth"
                (IssueEksClientAuth request)
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
