{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Authenticated Bootstrap Broker client for the parent Target Agent's
-- closed child-custody routes.
module Prodbox.ControlPlane.BootstrapCustodyClient
  ( BootstrapCustodyClient
  , BootstrapCustodyClientError (..)
  , bootstrapCustodyClient
  , commitChildCustody
  , prepareChildRecovery
  , observeChildRecoveryConsumption
  , commitChildRecoveryConsumption
  )
where

import Codec.Serialise (Serialise)
import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Prodbox.Bootstrap.Broker.Types
  ( ChildAttestation
  , ChildCustodyBinding
  , ChildRecoveryConsumptionObservation
  , ChildRecoveryDelivery
  , DeliveryNonce
  , ParentCustodyAcknowledgement
  )
import Prodbox.Cluster.FederationRegistration
  ( FederationRegistrationIntent
  )
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.BootstrapCustodyEndpoint
  ( ChildCustodyCommitRequest (..)
  , ChildCustodyCommitResponse (..)
  , ChildRecoveryObserveMode (..)
  , ChildRecoveryObserveRequest (..)
  , ChildRecoveryObserveResponse (..)
  , ChildRecoveryPrepareRequest (..)
  , ChildRecoveryPrepareResponse (..)
  , bootstrapCustodyMaximumBytes
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor
    ( TargetChildCustodyCommitRoute
    , TargetChildRecoveryObserveRoute
    , TargetChildRecoveryPrepareRoute
    )
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.Runtime.Role (RuntimeRole (TargetSecretAgentRuntime))

newtype BootstrapCustodyClient m = BootstrapCustodyClient
  { callBootstrapCustody
      :: forall value response result
       . (Serialise value, Serialise response)
      => ControlPlaneRouteFor 'TargetSecretAgentRuntime
      -> value
      -> (Int -> response -> Either BootstrapCustodyClientError result)
      -> m (Either BootstrapCustodyClientError result)
  }

data BootstrapCustodyClientError
  = BootstrapCustodyTransportFailed !AuthenticatedClientError
  | BootstrapCustodyResponseInvalid !ControlPlaneResponseCodecError
  | BootstrapCustodyHttpStatus !Int
  | BootstrapCustodyRefused !Text
  | BootstrapCustodyUnavailable !Text
  deriving stock (Eq, Show)

bootstrapCustodyClient
  :: AuthenticatedClientTransport 'TargetSecretAgentRuntime
  -> BootstrapCustodyClient IO
bootstrapCustodyClient transport = BootstrapCustodyClient call
 where
  call route request project = do
    attempted <-
      callAuthenticatedClientTransport
        transport
        route
        (LazyByteString.toStrict (encodeControlPlaneRequest request))
    pure $ do
      ControlPlaneResponse status body <-
        first BootstrapCustodyTransportFailed attempted
      decoded <-
        first
          BootstrapCustodyResponseInvalid
          ( decodeControlPlaneResponse
              bootstrapCustodyMaximumBytes
              (LazyByteString.fromStrict body)
          )
      project status decoded

commitChildCustody
  :: BootstrapCustodyClient IO
  -> FederationRegistrationIntent
  -> IO (Either BootstrapCustodyClientError ParentCustodyAcknowledgement)
commitChildCustody client intent =
  callBootstrapCustody
    client
    TargetChildCustodyCommitRoute
    (ChildCustodyCommitRequest intent)
    project
 where
  project status response = case response of
    ChildCustodyCommitted acknowledgement
      | status == 200 -> Right acknowledgement
      | otherwise -> Left (BootstrapCustodyHttpStatus status)
    ChildCustodyCommitRefused detail -> Left (BootstrapCustodyRefused detail)
    ChildCustodyCommitUnavailable detail -> Left (BootstrapCustodyUnavailable detail)

prepareChildRecovery
  :: BootstrapCustodyClient IO
  -> ChildCustodyBinding
  -> DeliveryNonce
  -> ChildAttestation
  -> IO (Either BootstrapCustodyClientError ChildRecoveryDelivery)
prepareChildRecovery client binding nonce attestation =
  callBootstrapCustody
    client
    TargetChildRecoveryPrepareRoute
    ChildRecoveryPrepareRequest
      { childRecoveryPrepareBinding = binding
      , childRecoveryPrepareNonce = nonce
      , childRecoveryPrepareAttestation = attestation
      }
    project
 where
  project status response = case response of
    ChildRecoveryPrepared delivery
      | status == 200 -> Right delivery
      | otherwise -> Left (BootstrapCustodyHttpStatus status)
    ChildRecoveryPrepareRefused detail -> Left (BootstrapCustodyRefused detail)
    ChildRecoveryPrepareUnavailable detail -> Left (BootstrapCustodyUnavailable detail)

observeChildRecoveryConsumption
  :: BootstrapCustodyClient IO
  -> ChildRecoveryDelivery
  -> IO (Either BootstrapCustodyClientError ChildRecoveryConsumptionObservation)
observeChildRecoveryConsumption client =
  callConsumption client ObserveChildRecoveryConsumption

commitChildRecoveryConsumption
  :: BootstrapCustodyClient IO
  -> ChildRecoveryDelivery
  -> IO (Either BootstrapCustodyClientError ChildRecoveryConsumptionObservation)
commitChildRecoveryConsumption client =
  callConsumption client CommitChildRecoveryConsumption

callConsumption
  :: BootstrapCustodyClient IO
  -> ChildRecoveryObserveMode
  -> ChildRecoveryDelivery
  -> IO (Either BootstrapCustodyClientError ChildRecoveryConsumptionObservation)
callConsumption client mode delivery =
  callBootstrapCustody
    client
    TargetChildRecoveryObserveRoute
    ChildRecoveryObserveRequest
      { childRecoveryObserveMode = mode
      , childRecoveryObserveDelivery = delivery
      }
    project
 where
  project status response = case response of
    ChildRecoveryConsumptionObserved observation
      | status == 200 -> Right observation
      | otherwise -> Left (BootstrapCustodyHttpStatus status)
    ChildRecoveryObserveRefused detail -> Left (BootstrapCustodyRefused detail)
    ChildRecoveryObserveUnavailable detail -> Left (BootstrapCustodyUnavailable detail)
