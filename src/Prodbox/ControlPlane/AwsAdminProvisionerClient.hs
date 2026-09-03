{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Closed authenticated client for the AWS-admin Credential Provisioner
-- Authority outbox. Elevated credentials are deliberately absent.
module Prodbox.ControlPlane.AwsAdminProvisionerClient
  ( AwsAdminProvisionerClient
  , AwsAdminProvisionerClientError (..)
  , AwsAdminPreparedProvisioning (..)
  , mkAwsAdminProvisionerClient
  , awsAdminProvisionerClient
  , classifyAwsAdminProvisionerHttpResponse
  , prepareAwsAdminProvisioning
  , attestAwsAdminProvisioning
  , authorizeAwsAdminProvisioning
  , completeAwsAdminProvisioning
  , observeAwsAdminProvisioning
  , observeAwsAdminFirstReconcile
  )
where

import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.AwsAdminProvisionerEndpoint
  ( AwsAdminFirstReconcileProjection
  , AwsAdminPodObservation
  , AwsAdminProvisionerChallenge (..)
  , AwsAdminProvisionerObservation
  , AwsAdminProvisionerRequest (..)
  , AwsAdminProvisionerResponse (..)
  , awsAdminProvisionerResponseMaximumBytes
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (LifecycleAwsAdminProvisionerRoute)
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecution
  ( AwsAdminWorkerReceipt
  , decodeAwsAdminWorkerReceipt
  , encodeAwsAdminWorkerReceipt
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( AwsAdminJobBinding
  , AwsAdminPermitIntent
  , SignedAwsAdminPermit
  , awsAdminPermitIntentAction
  , awsAdminPermitIntentAuthorityEndpoint
  , awsAdminPermitIntentAuthorityScope
  , awsAdminPermitIntentCredentialClass
  , awsAdminPermitIntentGeneration
  , awsAdminPermitIntentIamParameters
  , awsAdminPermitIntentImageDigest
  , awsAdminPermitIntentOperationId
  , awsAdminPermitIntentPermitId
  , awsAdminPermitIntentRequestDigest
  , awsAdminPermitIntentTarget
  , decodeAwsAdminJobBinding
  , decodeAwsAdminPermitIntent
  , decodeSignedAwsAdminPermit
  , encodeAwsAdminPermitIntent
  , encodeSignedAwsAdminPermit
  , withSomeSignedAwsAdminPermit
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( operatorMaterialOperationIdText
  , operatorMaterialPermitIdText
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( credentialGenerationValue
  , targetValueDigestText
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

newtype AwsAdminProvisionerClient m = AwsAdminProvisionerClient
  { callAwsAdminProvisioner
      :: AwsAdminProvisionerRequest
      -> m
           ( Either
               AwsAdminProvisionerClientError
               AwsAdminProvisionerResponse
           )
  }

mkAwsAdminProvisionerClient
  :: ( AwsAdminProvisionerRequest
       -> m
            ( Either
                AwsAdminProvisionerClientError
                AwsAdminProvisionerResponse
            )
     )
  -> AwsAdminProvisionerClient m
mkAwsAdminProvisionerClient = AwsAdminProvisionerClient

data AwsAdminProvisionerClientError
  = AwsAdminProvisionerClientTransportFailed !AuthenticatedClientError
  | AwsAdminProvisionerClientResponseInvalid !ControlPlaneResponseCodecError
  | AwsAdminProvisionerClientHttpStatus !Int
  | AwsAdminProvisionerClientRefused !Text
  | AwsAdminProvisionerClientUnavailable !Text
  | AwsAdminProvisionerClientBindingInvalid
  | AwsAdminProvisionerClientPermitInvalid
  | AwsAdminProvisionerClientReceiptInvalid
  | AwsAdminProvisionerClientIntentInvalid
  | AwsAdminProvisionerClientChallengeMismatch
  | AwsAdminProvisionerClientUnexpectedResponse
  deriving stock (Eq, Show)

data AwsAdminPreparedProvisioning = AwsAdminPreparedProvisioning
  { awsAdminPreparedCanonicalIntent :: !AwsAdminPermitIntent
  , awsAdminPreparedChallenge :: !AwsAdminProvisionerChallenge
  }
  deriving stock (Eq, Show)

awsAdminProvisionerClient
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> AwsAdminProvisionerClient IO
awsAdminProvisionerClient transport = AwsAdminProvisionerClient $ \request -> do
  attempted <-
    callAuthenticatedClientTransport
      transport
      LifecycleAwsAdminProvisionerRoute
      (LazyByteString.toStrict (encodeControlPlaneRequest request))
  pure $ do
    raw <- first AwsAdminProvisionerClientTransportFailed attempted
    classifyAwsAdminProvisionerHttpResponse raw

classifyAwsAdminProvisionerHttpResponse
  :: ControlPlaneResponse
  -> Either AwsAdminProvisionerClientError AwsAdminProvisionerResponse
classifyAwsAdminProvisionerHttpResponse (ControlPlaneResponse status body) =
  case decodeControlPlaneResponse
    awsAdminProvisionerResponseMaximumBytes
    (LazyByteString.fromStrict body) of
    Left err
      | status == 200 -> Left (AwsAdminProvisionerClientResponseInvalid err)
      | otherwise -> Left (AwsAdminProvisionerClientHttpStatus status)
    Right response -> case response of
      AwsAdminProvisioningRefused detail ->
        Left (AwsAdminProvisionerClientRefused detail)
      AwsAdminProvisioningUnavailable detail ->
        Left (AwsAdminProvisionerClientUnavailable detail)
      _
        | status == 200 -> Right response
        | otherwise -> Left (AwsAdminProvisionerClientHttpStatus status)

prepareAwsAdminProvisioning
  :: (Monad m)
  => AwsAdminProvisionerClient m
  -> AwsAdminPermitIntent
  -> m
       ( Either
           AwsAdminProvisionerClientError
           AwsAdminPreparedProvisioning
       )
prepareAwsAdminProvisioning client intent = do
  response <-
    callAwsAdminProvisioner
      client
      (PrepareAwsAdminProvisioning (encodeAwsAdminPermitIntent intent))
  pure $ do
    value <- response
    case value of
      AwsAdminProvisioningPrepared challenge -> do
        canonical <-
          first
            (const AwsAdminProvisionerClientIntentInvalid)
            (decodeAwsAdminPermitIntent (awsAdminChallengeCanonicalIntent challenge))
        if sameCallerRequest intent canonical && challengeMatches canonical challenge
          then
            Right
              AwsAdminPreparedProvisioning
                { awsAdminPreparedCanonicalIntent = canonical
                , awsAdminPreparedChallenge = challenge
                }
          else Left AwsAdminProvisionerClientChallengeMismatch
      _ -> Left AwsAdminProvisionerClientUnexpectedResponse

sameCallerRequest :: AwsAdminPermitIntent -> AwsAdminPermitIntent -> Bool
sameCallerRequest requested canonical =
  awsAdminPermitIntentPermitId requested == awsAdminPermitIntentPermitId canonical
    && awsAdminPermitIntentCredentialClass requested
      == awsAdminPermitIntentCredentialClass canonical
    && awsAdminPermitIntentAction requested == awsAdminPermitIntentAction canonical
    && awsAdminPermitIntentOperationId requested
      == awsAdminPermitIntentOperationId canonical
    && awsAdminPermitIntentGeneration requested
      == awsAdminPermitIntentGeneration canonical
    && awsAdminPermitIntentRequestDigest requested
      == awsAdminPermitIntentRequestDigest canonical
    && awsAdminPermitIntentIamParameters requested
      == awsAdminPermitIntentIamParameters canonical
    && awsAdminPermitIntentImageDigest requested
      == awsAdminPermitIntentImageDigest canonical
    && awsAdminPermitIntentAuthorityScope requested
      == awsAdminPermitIntentAuthorityScope canonical
    && awsAdminPermitIntentAuthorityEndpoint requested
      == awsAdminPermitIntentAuthorityEndpoint canonical

challengeMatches
  :: AwsAdminPermitIntent -> AwsAdminProvisionerChallenge -> Bool
challengeMatches intent challenge =
  awsAdminChallengeOperationId challenge
    == operatorMaterialOperationIdText (awsAdminPermitIntentOperationId intent)
    && awsAdminChallengePermitId challenge
      == operatorMaterialPermitIdText (awsAdminPermitIntentPermitId intent)
    && awsAdminChallengeRequestDigest challenge
      == targetValueDigestText (awsAdminPermitIntentRequestDigest intent)
    && awsAdminChallengeGeneration challenge
      == credentialGenerationValue (awsAdminPermitIntentGeneration intent)
    && awsAdminChallengeTarget challenge == awsAdminPermitIntentTarget intent
    && awsAdminChallengeImageDigest challenge
      == awsAdminPermitIntentImageDigest intent
    && awsAdminChallengeAuthorityScope challenge
      == awsAdminPermitIntentAuthorityScope intent
    && awsAdminChallengeAuthorityEndpoint challenge
      == awsAdminPermitIntentAuthorityEndpoint intent
    && awsAdminChallengeCanonicalIntent challenge
      == encodeAwsAdminPermitIntent intent

attestAwsAdminProvisioning
  :: (Monad m)
  => AwsAdminProvisionerClient m
  -> AwsAdminPermitIntent
  -> Text
  -> AwsAdminPodObservation
  -> m (Either AwsAdminProvisionerClientError AwsAdminJobBinding)
attestAwsAdminProvisioning client intent operationId observation = do
  response <-
    callAwsAdminProvisioner
      client
      (AttestAwsAdminProvisioning operationId observation)
  pure $ do
    value <- response
    case value of
      AwsAdminProvisioningAttested bindingBytes ->
        first
          (const AwsAdminProvisionerClientBindingInvalid)
          (decodeAwsAdminJobBinding intent bindingBytes)
      _ -> Left AwsAdminProvisionerClientUnexpectedResponse

authorizeAwsAdminProvisioning
  :: (Monad m)
  => AwsAdminProvisionerClient m
  -> Text
  -> m (Either AwsAdminProvisionerClientError SignedAwsAdminPermit)
authorizeAwsAdminProvisioning client operationId = do
  response <-
    callAwsAdminProvisioner
      client
      (AuthorizeAwsAdminProvisioning operationId)
  pure $ do
    value <- response
    case value of
      AwsAdminProvisioningAuthorized permitBytes -> do
        somePermit <-
          first
            (const AwsAdminProvisionerClientPermitInvalid)
            (decodeSignedAwsAdminPermit permitBytes)
        withSomeSignedAwsAdminPermit somePermit Right
      _ -> Left AwsAdminProvisionerClientUnexpectedResponse

completeAwsAdminProvisioning
  :: (Monad m)
  => AwsAdminProvisionerClient m
  -> Text
  -> SignedAwsAdminPermit
  -> AwsAdminWorkerReceipt
  -> m (Either AwsAdminProvisionerClientError AwsAdminWorkerReceipt)
completeAwsAdminProvisioning client operationId permit receipt = do
  response <-
    callAwsAdminProvisioner
      client
      ( CompleteAwsAdminProvisioning
          operationId
          (encodeSignedAwsAdminPermit permit)
          (encodeAwsAdminWorkerReceipt receipt)
      )
  pure $ do
    value <- response
    case value of
      AwsAdminProvisioningCompleted receiptBytes ->
        first
          (const AwsAdminProvisionerClientReceiptInvalid)
          (decodeAwsAdminWorkerReceipt receiptBytes)
      _ -> Left AwsAdminProvisionerClientUnexpectedResponse

observeAwsAdminProvisioning
  :: (Monad m)
  => AwsAdminProvisionerClient m
  -> Text
  -> m
       ( Either
           AwsAdminProvisionerClientError
           AwsAdminProvisionerObservation
       )
observeAwsAdminProvisioning client operationId = do
  response <-
    callAwsAdminProvisioner client (ObserveAwsAdminProvisioning operationId)
  pure $ do
    value <- response
    case value of
      AwsAdminProvisioningObserved observation -> Right observation
      _ -> Left AwsAdminProvisionerClientUnexpectedResponse

observeAwsAdminFirstReconcile
  :: (Monad m)
  => AwsAdminProvisionerClient m
  -> m
       ( Either
           AwsAdminProvisionerClientError
           (Maybe AwsAdminFirstReconcileProjection)
       )
observeAwsAdminFirstReconcile client = do
  response <- callAwsAdminProvisioner client ObserveAwsAdminFirstReconcile
  pure $ do
    value <- response
    case value of
      AwsAdminFirstReconcileObserved continuation -> Right continuation
      _ -> Left AwsAdminProvisionerClientUnexpectedResponse
