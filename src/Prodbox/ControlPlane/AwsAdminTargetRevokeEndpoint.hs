{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | One metadata-only operational credential lane. The Agent verifies the
-- Authority permit locally before acquiring its fixed Vault boundary. Neither
-- a request-selected Vault path nor secret material is representable here.
module Prodbox.ControlPlane.AwsAdminTargetRevokeEndpoint
  ( AwsAdminTargetRevokeRequest (..)
  , AwsAdminTargetRevokeResponse (..)
  , AwsAdminTargetRevokeRefusal (..)
  , AwsAdminTargetRevokeVerification (..)
  , AwsAdminTargetRevokeBoundary
  , mkAwsAdminTargetRevokeBoundary
  , vaultAwsAdminTargetRevokeBoundary
  , awsAdminTargetRevokeRequest
  , awsAdminTargetRevokeAuthenticatedHandler
  , awsAdminTargetRevokeResponseStatus
  , awsAdminTargetRevokeMaximumBytes
  )
where

import Codec.Serialise (Serialise)
import Control.Monad (unless, void)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter (AuthenticatedRoleHandler (..))
import Prodbox.ControlPlane.CallerPrincipal (CallerPrincipal (CallerCredentialProvisioner))
import Prodbox.ControlPlane.Codec (decodeControlPlaneRequest, encodeControlPlaneResponse)
import Prodbox.ControlPlane.RequestAuthentication (verifiedCallerSlotPrincipal)
import Prodbox.ControlPlane.RoleReadiness (noRoleReadinessContribution)
import Prodbox.ControlPlane.Route (ControlPlaneRoute (TargetAwsAdminCredentialRevoke))
import Prodbox.ControlPlane.TargetMaterialEndpoint
  ( TargetMaterialObservation (targetMaterialObservedGeneration)
  , TargetMaterialRepository (observeTargetMaterial)
  , vaultTargetMaterialRepository
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( AwsCredentialIdentity (AwsLifecycleProvider)
  , TargetSecretId (TargetAwsCredential)
  , compiledTargetSecretSink
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution (TargetAgentIdentity)
import Prodbox.Http.Client (renderHttpError)
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.CheckpointAuthority (targetSecretSinkKvPath, targetSecretSinkVaultMount)
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( SignedAwsAdminPermit
  , awsAdminJobPodName
  , awsAdminJobPodUid
  , awsAdminPermitIntentAction
  , awsAdminPermitIntentCredentialClass
  , awsAdminPermitIntentGeneration
  , awsAdminPermitIntentOperationId
  , awsAdminPermitIntentPermitId
  , awsAdminPermitIntentPreparedTarget
  , decodeSignedAwsAdminPermit
  , encodeSignedAwsAdminPermit
  , signedAwsAdminPermitBinding
  , signedAwsAdminPermitIntent
  , verifySignedAwsAdminPermit
  , withSomeSignedAwsAdminPermit
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass (LifecycleProviderCredential)
  , OperatorMaterialAction (RevokeOperatorMaterial)
  , operatorMaterialOperationIdText
  , operatorMaterialPermitIdText
  )
import Prodbox.Lifecycle.CredentialProvisioner.PreparedTarget
  ( preparedCredentialTargetId
  , preparedCredentialTargetSelectedAgent
  )
import Prodbox.Lifecycle.Decommission.Manifest (ManifestPublicKey, manifestPublicKeyBytes)
import Prodbox.Lifecycle.Lease (AuthorityTime)
import Prodbox.Lifecycle.TargetCommitIntent (credentialGenerationValue)
import Prodbox.Vault.Client (vaultKvDeleteMetadataV2)
import Prodbox.Vault.Session (VaultSession, sessionAddress, withSessionToken)

data AwsAdminTargetRevokeRequest = AwsAdminTargetRevokeRequest
  { awsAdminTargetRevokePermit :: !ByteString
  , awsAdminTargetRevokeTarget :: !TargetSecretId
  , awsAdminTargetRevokeGeneration :: !Natural
  , awsAdminTargetRevokeOperation :: !Text
  , awsAdminTargetRevokePodName :: !Text
  , awsAdminTargetRevokePodUid :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AwsAdminTargetRevokeRefusal
  = AwsAdminTargetRevokeCallerRefused
  | AwsAdminTargetRevokeCodecRefused
  | AwsAdminTargetRevokePermitRefused
  | AwsAdminTargetRevokeClassRefused
  | AwsAdminTargetRevokeActionRefused
  | AwsAdminTargetRevokeTargetRefused
  | AwsAdminTargetRevokeAgentRefused
  | AwsAdminTargetRevokeGenerationRefused
  | AwsAdminTargetRevokePodRefused
  | AwsAdminTargetRevokeOperationRefused
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AwsAdminTargetRevokeResponse
  = AwsAdminTargetGenerationAbsent !Natural !Text
  | AwsAdminTargetRevokeRefused !AwsAdminTargetRevokeRefusal
  | AwsAdminTargetRevokeUnavailable
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | Trusted startup key, independent of request fields. A signer rollover
-- refuses old trust until the Agent is restarted with the new public key.
data AwsAdminTargetRevokeVerification m = AwsAdminTargetRevokeVerification
  { awsAdminTargetRevokeSignerGeneration :: !Natural
  , awsAdminTargetRevokePublicKey :: !ManifestPublicKey
  , awsAdminTargetRevokeCurrentTime :: !(m (Either Text AuthorityTime))
  , awsAdminTargetRevokeLocalAgent :: !TargetAgentIdentity
  }

data AwsAdminTargetRevokeBoundary m = AwsAdminTargetRevokeBoundary
  { observeRevocationGeneration :: !(m (Either Text (Maybe Natural)))
  , destroyRevocationMetadata :: !(m (Either Text ()))
  }

mkAwsAdminTargetRevokeBoundary
  :: m (Either Text (Maybe Natural))
  -> m (Either Text ())
  -> AwsAdminTargetRevokeBoundary m
mkAwsAdminTargetRevokeBoundary = AwsAdminTargetRevokeBoundary

vaultAwsAdminTargetRevokeBoundary :: VaultSession -> AwsAdminTargetRevokeBoundary IO
vaultAwsAdminTargetRevokeBoundary session =
  mkAwsAdminTargetRevokeBoundary observe destroy
 where
  repository = vaultTargetMaterialRepository session noRoleReadinessContribution
  observe =
    fmap
      (fmap (fmap targetMaterialObservedGeneration))
      (observeTargetMaterial repository operationalTarget)
  destroy = case compiledTargetSecretSink operationalTarget of
    Left detail -> pure (Left detail)
    Right sink -> do
      result <- withSessionToken session $ \token ->
        vaultKvDeleteMetadataV2
          (sessionAddress session)
          token
          (targetSecretSinkVaultMount sink)
          (targetSecretSinkKvPath sink)
      pure (first (Text.pack . renderHttpError) result)

operationalTarget :: TargetSecretId
operationalTarget = TargetAwsCredential AwsLifecycleProvider

awsAdminTargetRevokeMaximumBytes :: Int
awsAdminTargetRevokeMaximumBytes = 64 * 1024

awsAdminTargetRevokeRequest :: SignedAwsAdminPermit -> AwsAdminTargetRevokeRequest
awsAdminTargetRevokeRequest permit =
  AwsAdminTargetRevokeRequest
    { awsAdminTargetRevokePermit = encodeSignedAwsAdminPermit permit
    , awsAdminTargetRevokeTarget = preparedCredentialTargetId (awsAdminPermitIntentPreparedTarget intent)
    , awsAdminTargetRevokeGeneration = credentialGenerationValue (awsAdminPermitIntentGeneration intent)
    , awsAdminTargetRevokeOperation =
        operatorMaterialOperationIdText (awsAdminPermitIntentOperationId intent)
    , awsAdminTargetRevokePodName = awsAdminJobPodName binding
    , awsAdminTargetRevokePodUid = awsAdminJobPodUid binding
    }
 where
  intent = signedAwsAdminPermitIntent permit
  binding = signedAwsAdminPermitBinding permit

awsAdminTargetRevokeAuthenticatedHandler
  :: (Monad m)
  => AwsAdminTargetRevokeVerification m
  -> AwsAdminTargetRevokeBoundary m
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
awsAdminTargetRevokeAuthenticatedHandler verification boundary inner =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness = authenticatedHandlerReadiness inner
    , authenticatedHandlerHandle = handle
    }
 where
  handle caller route body
    | route /= TargetAwsAdminCredentialRevoke = authenticatedHandlerHandle inner caller route body
    | verifiedCallerSlotPrincipal caller /= CallerCredentialProvisioner =
        pure (reply (AwsAdminTargetRevokeRefused AwsAdminTargetRevokeCallerRefused))
    | otherwise = do
        response <- case decodeControlPlaneRequest awsAdminTargetRevokeMaximumBytes (LazyByteString.fromStrict body) of
          Left _ -> pure (AwsAdminTargetRevokeRefused AwsAdminTargetRevokeCodecRefused)
          Right request -> runRevoke verification boundary request
        pure (reply response)
  reply response =
    let encoded = LazyByteString.toStrict (encodeControlPlaneResponse response)
     in Just
          ( if ByteString.length encoded <= awsAdminTargetRevokeMaximumBytes
              then (awsAdminTargetRevokeResponseStatus response, encoded)
              else
                ( ReplyServiceUnavailable
                , LazyByteString.toStrict (encodeControlPlaneResponse AwsAdminTargetRevokeUnavailable)
                )
          )

runRevoke
  :: (Monad m)
  => AwsAdminTargetRevokeVerification m
  -> AwsAdminTargetRevokeBoundary m
  -> AwsAdminTargetRevokeRequest
  -> m AwsAdminTargetRevokeResponse
runRevoke verification boundary request = do
  nowResult <- awsAdminTargetRevokeCurrentTime verification
  case nowResult of
    Left _ -> pure AwsAdminTargetRevokeUnavailable
    Right now -> case verifyRequest verification now request of
      Left cause -> pure (AwsAdminTargetRevokeRefused cause)
      Right permit -> do
        before <- observeRevocationGeneration boundary
        case before of
          Left _ -> pure AwsAdminTargetRevokeUnavailable
          Right Nothing -> pure (absent permit)
          Right (Just generation)
            | generation /= awsAdminTargetRevokeGeneration request ->
                pure (AwsAdminTargetRevokeRefused AwsAdminTargetRevokeGenerationRefused)
            | otherwise -> do
                -- Observation may have consumed the remainder of the permit.
                freshTime <- awsAdminTargetRevokeCurrentTime verification
                case freshTime of
                  Left _ -> pure AwsAdminTargetRevokeUnavailable
                  Right fresh -> case verifyRequest verification fresh request of
                    Left cause -> pure (AwsAdminTargetRevokeRefused cause)
                    Right _ -> do
                      void (destroyRevocationMetadata boundary)
                      after <- observeRevocationGeneration boundary
                      pure $ case after of
                        Right Nothing -> absent permit
                        _ -> AwsAdminTargetRevokeUnavailable
 where
  absent permit =
    AwsAdminTargetGenerationAbsent
      (awsAdminTargetRevokeGeneration request)
      (operatorMaterialPermitIdText (awsAdminPermitIntentPermitId (signedAwsAdminPermitIntent permit)))

verifyRequest
  :: AwsAdminTargetRevokeVerification m
  -> AuthorityTime
  -> AwsAdminTargetRevokeRequest
  -> Either AwsAdminTargetRevokeRefusal SignedAwsAdminPermit
verifyRequest verification now request = do
  somePermit <-
    first
      (const AwsAdminTargetRevokePermitRefused)
      (decodeSignedAwsAdminPermit (awsAdminTargetRevokePermit request))
  let permit = withSomeSignedAwsAdminPermit somePermit id
  first (const AwsAdminTargetRevokePermitRefused) $
    verifySignedAwsAdminPermit
      (manifestPublicKeyBytes (awsAdminTargetRevokePublicKey verification))
      (awsAdminTargetRevokeSignerGeneration verification)
      now
      permit
  let intent = signedAwsAdminPermitIntent permit
      binding = signedAwsAdminPermitBinding permit
      prepared = awsAdminPermitIntentPreparedTarget intent
  unless
    (awsAdminPermitIntentCredentialClass intent == LifecycleProviderCredential)
    (Left AwsAdminTargetRevokeClassRefused)
  unless
    (awsAdminPermitIntentAction intent == RevokeOperatorMaterial)
    (Left AwsAdminTargetRevokeActionRefused)
  unless
    ( awsAdminTargetRevokeTarget request == operationalTarget
        && preparedCredentialTargetId prepared == operationalTarget
    )
    (Left AwsAdminTargetRevokeTargetRefused)
  unless
    (preparedCredentialTargetSelectedAgent prepared == awsAdminTargetRevokeLocalAgent verification)
    (Left AwsAdminTargetRevokeAgentRefused)
  unless
    ( awsAdminTargetRevokeGeneration request
        == credentialGenerationValue (awsAdminPermitIntentGeneration intent)
    )
    (Left AwsAdminTargetRevokeGenerationRefused)
  unless
    ( awsAdminTargetRevokeOperation request
        == operatorMaterialOperationIdText (awsAdminPermitIntentOperationId intent)
    )
    (Left AwsAdminTargetRevokeOperationRefused)
  unless
    ( awsAdminTargetRevokePodName request == awsAdminJobPodName binding
        && awsAdminTargetRevokePodUid request == awsAdminJobPodUid binding
    )
    (Left AwsAdminTargetRevokePodRefused)
  pure permit

awsAdminTargetRevokeResponseStatus :: AwsAdminTargetRevokeResponse -> ReplyStatus
awsAdminTargetRevokeResponseStatus response = case response of
  AwsAdminTargetGenerationAbsent _ _ -> ReplyOk
  AwsAdminTargetRevokeRefused _ -> ReplyForbidden
  AwsAdminTargetRevokeUnavailable -> ReplyServiceUnavailable
