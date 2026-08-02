{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated client for the Lifecycle Authority federation aggregate.
-- The staged bootstrap calls transport public keys, ciphertext and typed
-- receipts only; no plaintext bootstrap material is representable here.
module Prodbox.ControlPlane.FederationRegistrationClient
  ( FederationRegistrationClientError (..)
  , prepareFederationBootstrap
  , observeFederationBootstrap
  , recordFederationChildRecipient
  , recordFederationChildDelivery
  , registerFederationChild
  )
where

import Control.Monad (void)
import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Cluster.FederationRegistration
  ( ChildBootstrapDeliveryIntent
  , ChildBootstrapDeliveryReceipt
  , ChildBootstrapRecipientAttestation
  , FederationRegistrationCompletion
  , FederationRegistrationIntent
  , FederationRegistrationState
  , ParentBootstrapCustodyReceipt
  , ParentBootstrapEnvelope
  , parentBootstrapCustodyChildDelivery
  , parentBootstrapEnvelopeChildRecipient
  , registrationStateBootstrapCustody
  , registrationStateBootstrapIntent
  , registrationStateChildDelivery
  , registrationStateChildRecipient
  , registrationStateCompletion
  , registrationStateCustodyIntent
  , registrationStateParentEnvelope
  , validateChildBootstrapDeliveryIntent
  , validateChildBootstrapDeliveryReceipt
  , validateChildBootstrapRecipientAttestation
  , validateFederationRegistrationCompletion
  , validateFederationRegistrationIntent
  , validateParentBootstrapCustodyReceipt
  , validateParentBootstrapEnvelope
  )
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (LifecycleFederationRegisterRoute)
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.FederationRegistrationEndpoint
  ( FederationRegistrationRequest (..)
  , FederationRegistrationResponse (..)
  , federationRegistrationResponseMaximumBytes
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

data FederationRegistrationClientError
  = FederationRegistrationTransportFailed !AuthenticatedClientError
  | FederationRegistrationResponseInvalid !ControlPlaneResponseCodecError
  | FederationRegistrationResponseStatusMismatch !Int
  | FederationRegistrationResponseEvidenceInvalid !Text
  | FederationRegistrationRemoteRefused !Text
  | FederationRegistrationRemoteUnavailable !Text
  deriving stock (Eq, Show)

prepareFederationBootstrap
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> ChildBootstrapDeliveryIntent
  -> IO (Either FederationRegistrationClientError ChildBootstrapDeliveryIntent)
prepareFederationBootstrap transport intent = do
  response <- call transport (FederationBootstrapPrepareRequest intent)
  pure $ do
    (status, decoded) <- response
    case decoded of
      FederationBootstrapPrepareSucceeded observed
        | status /= 200 -> Left (FederationRegistrationResponseStatusMismatch status)
        | observed /= intent -> evidence "prepared bootstrap intent differs"
        | otherwise ->
            first
              (FederationRegistrationResponseEvidenceInvalid . Text.pack . show)
              (validateChildBootstrapDeliveryIntent observed)
      other -> unexpected status other

observeFederationBootstrap
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> ChildBootstrapDeliveryIntent
  -> IO (Either FederationRegistrationClientError FederationRegistrationState)
observeFederationBootstrap transport intent = do
  response <- call transport (FederationBootstrapObserveRequest intent)
  pure $ do
    (status, decoded) <- response
    case decoded of
      FederationBootstrapObserved state
        | status /= 200 -> Left (FederationRegistrationResponseStatusMismatch status)
        | registrationStateBootstrapIntent state /= intent ->
            evidence "observed bootstrap aggregate differs"
        | otherwise -> validateObservedState state
      other -> unexpected status other

recordFederationChildRecipient
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> ChildBootstrapRecipientAttestation
  -> IO (Either FederationRegistrationClientError ParentBootstrapEnvelope)
recordFederationChildRecipient transport recipient = do
  response <- call transport (FederationBootstrapChildRecipientRequest recipient)
  pure $ do
    (status, decoded) <- response
    case decoded of
      FederationBootstrapParentEnvelopeReady envelope
        | status /= 200 -> Left (FederationRegistrationResponseStatusMismatch status)
        | parentBootstrapEnvelopeChildRecipient envelope /= recipient ->
            evidence "parent envelope is bound to a different child recipient"
        | otherwise ->
            first
              (FederationRegistrationResponseEvidenceInvalid . Text.pack . show)
              (validateParentBootstrapEnvelope envelope)
      other -> unexpected status other

recordFederationChildDelivery
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> ChildBootstrapDeliveryReceipt
  -> IO (Either FederationRegistrationClientError ParentBootstrapCustodyReceipt)
recordFederationChildDelivery transport delivery = do
  response <- call transport (FederationBootstrapChildDeliveryRequest delivery)
  pure $ do
    (status, decoded) <- response
    case decoded of
      FederationBootstrapCustodySucceeded custody
        | status /= 200 -> Left (FederationRegistrationResponseStatusMismatch status)
        | parentBootstrapCustodyChildDelivery custody /= delivery ->
            evidence "parent bootstrap custody is bound to a different child delivery"
        | otherwise ->
            first
              (FederationRegistrationResponseEvidenceInvalid . Text.pack . show)
              (validateParentBootstrapCustodyReceipt custody)
      other -> unexpected status other

registerFederationChild
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> FederationRegistrationIntent
  -> IO (Either FederationRegistrationClientError FederationRegistrationCompletion)
registerFederationChild transport intent = do
  response <- call transport (FederationCustodyRegistrationRequest intent)
  pure $ do
    (status, decoded) <- response
    case decoded of
      FederationRegistrationSucceeded completion
        | status /= 200 -> Left (FederationRegistrationResponseStatusMismatch status)
        | otherwise ->
            first
              (FederationRegistrationResponseEvidenceInvalid . Text.pack . show)
              (validateFederationRegistrationCompletion completion)
      other -> unexpected status other

call
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> FederationRegistrationRequest
  -> IO
       ( Either
           FederationRegistrationClientError
           (Int, FederationRegistrationResponse)
       )
call transport request = do
  attempted <-
    callAuthenticatedClientTransport
      transport
      LifecycleFederationRegisterRoute
      (LazyByteString.toStrict (encodeControlPlaneRequest request))
  pure $ do
    ControlPlaneResponse status body <-
      first FederationRegistrationTransportFailed attempted
    response <-
      first
        FederationRegistrationResponseInvalid
        ( decodeControlPlaneResponse
            federationRegistrationResponseMaximumBytes
            (LazyByteString.fromStrict body)
        )
    Right (status, response)

unexpected
  :: Int
  -> FederationRegistrationResponse
  -> Either FederationRegistrationClientError value
unexpected status response = case response of
  FederationRegistrationRefused detail ->
    Left (FederationRegistrationRemoteRefused detail)
  FederationRegistrationUnavailable detail ->
    Left (FederationRegistrationRemoteUnavailable detail)
  _ -> Left (FederationRegistrationResponseStatusMismatch status)

validateObservedState
  :: FederationRegistrationState
  -> Either FederationRegistrationClientError FederationRegistrationState
validateObservedState state = do
  validateEvidence (validateChildBootstrapDeliveryIntent (registrationStateBootstrapIntent state))
  maybe
    (Right ())
    (validateEvidence . validateChildBootstrapRecipientAttestation)
    (registrationStateChildRecipient state)
  maybe
    (Right ())
    (validateEvidence . validateParentBootstrapEnvelope)
    (registrationStateParentEnvelope state)
  maybe
    (Right ())
    (validateEvidence . validateChildBootstrapDeliveryReceipt)
    (registrationStateChildDelivery state)
  maybe
    (Right ())
    (validateEvidence . validateParentBootstrapCustodyReceipt)
    (registrationStateBootstrapCustody state)
  maybe
    (Right ())
    (validateEvidence . validateFederationRegistrationIntent)
    (registrationStateCustodyIntent state)
  maybe
    (Right ())
    (validateEvidence . validateFederationRegistrationCompletion)
    (registrationStateCompletion state)
  Right state
 where
  validateEvidence =
    first
      (FederationRegistrationResponseEvidenceInvalid . Text.pack . show)
      . void

evidence :: Text -> Either FederationRegistrationClientError value
evidence = Left . FederationRegistrationResponseEvidenceInvalid
