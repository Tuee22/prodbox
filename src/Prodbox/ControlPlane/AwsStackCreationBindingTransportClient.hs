{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated host-side AWS stack-creation binding client.  The commit
-- response never mints a durable proof; only the independent identity
-- read-back reconstructs 'CommittedAwsStackCreationBinding'.
module Prodbox.ControlPlane.AwsStackCreationBindingTransportClient
  ( lifecycleAuthorityAwsStackCreationBindingAuthenticatedClient
  )
where

import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.AwsStackCreationBindingEndpoint
  ( AwsStackCreationEndpointResponseError (..)
  , AwsStackCreationWireRefusal (..)
  , AwsStackCreationWireUnavailable (..)
  , awsStackCreationCommitWireRequest
  , awsStackCreationReadBackWireRequest
  , awsStackCreationWireRequestPayload
  , awsStackCreationWireResponseStatus
  , confirmAwsStackCreationCommitResponse
  , confirmAwsStackCreationReadBackResponse
  , decodeAwsStackCreationEndpointResponse
  )
import Prodbox.ControlPlane.AwsStackCreationBindingRepository
  ( AwsStackCreationBindingClient (..)
  , AwsStackCreationBindingError (..)
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (LifecycleAwsStackCreationBindingRoute)
  )
import Prodbox.ControlPlane.Codec (encodeControlPlaneRequest)
import Prodbox.Http.ReplyStatus (replyStatusCode)
import Prodbox.Lifecycle.Teardown.Model (ObservationFailure (..))
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

lifecycleAuthorityAwsStackCreationBindingAuthenticatedClient
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> AwsStackCreationBindingClient IO
lifecycleAuthorityAwsStackCreationBindingAuthenticatedClient transport =
  AwsStackCreationBindingClient
    { attemptAwsStackCreationBindingCommit = \operationId revision scope -> do
        let request =
              awsStackCreationCommitWireRequest operationId revision scope
        attempted <- callWire request
        pure $ do
          response <- attempted
          first
            endpointResponseError
            ( confirmAwsStackCreationCommitResponse
                (awsStackCreationWireRequestPayload request)
                response
            )
    , readBackAwsStackCreationBindingByIdentity = \identity -> do
        attempted <- callWire (awsStackCreationReadBackWireRequest identity)
        pure $ do
          response <- attempted
          first
            endpointResponseError
            (confirmAwsStackCreationReadBackResponse identity response)
    }
 where
  callWire request = do
    attempted <-
      callAuthenticatedClientTransport
        transport
        LifecycleAwsStackCreationBindingRoute
        (LazyByteString.toStrict (encodeControlPlaneRequest request))
    pure $ do
      ControlPlaneResponse status body <-
        first
          (remoteUnobservable . Text.pack . show)
          attempted
      response <-
        first
          (remoteUnobservable . Text.pack . show)
          (decodeAwsStackCreationEndpointResponse body)
      let expectedStatus =
            replyStatusCode (awsStackCreationWireResponseStatus response)
      if status == expectedStatus
        then Right response
        else
          Left
            ( remoteUnobservable
                ( "HTTP status mismatch: expected "
                    <> Text.pack (show expectedStatus)
                    <> ", observed "
                    <> Text.pack (show status)
                )
            )

endpointResponseError
  :: AwsStackCreationEndpointResponseError
  -> AwsStackCreationBindingError
endpointResponseError err = case err of
  AwsStackCreationEndpointResponseIdentityMismatch expected actual ->
    AwsStackCreationIdentityMismatch expected actual
  AwsStackCreationEndpointResponseIdentityInvalid detail -> detail
  AwsStackCreationEndpointResponseReadBackInvalid detail -> detail
  AwsStackCreationEndpointResponseRefused refusal -> case refusal of
    AwsStackCreationWireReadBackMissing -> AwsStackCreationConfirmationMissing
    AwsStackCreationWireReadBackCorrupt detail ->
      AwsStackCreationConfirmationCorrupt detail
    AwsStackCreationWireReadBackUnbounded actual maximumBytes ->
      AwsStackCreationConfirmationUnbounded actual maximumBytes
    AwsStackCreationWireReadBackIdentityMismatch actualBytes ->
      AwsStackCreationFieldInvalid
        ( "Authority returned a mismatched encoded identity ("
            <> Text.pack (show (Text.length (Text.pack (show actualBytes))))
            <> " rendered characters)"
        )
    other -> AwsStackCreationFieldInvalid (bounded (Text.pack (show other)))
  AwsStackCreationEndpointResponseUnavailable reason -> case reason of
    AwsStackCreationWireAdmissionUnavailable detail ->
      AwsStackCreationAdmissionUnavailable detail
    AwsStackCreationWireReadBackUnobservable detail ->
      AwsStackCreationConfirmationUnobservable (ObservationFailure detail)
    AwsStackCreationWireEndpointUnavailable detail -> remoteUnobservable detail
  AwsStackCreationEndpointResponseVersionMismatch {} -> invalidResponse
  AwsStackCreationEndpointResponseKindMismatch -> invalidResponse
  AwsStackCreationEndpointResponseRequestMismatch {} -> invalidResponse
 where
  invalidResponse = AwsStackCreationFieldInvalid (bounded (Text.pack (show err)))

remoteUnobservable :: Text -> AwsStackCreationBindingError
remoteUnobservable =
  AwsStackCreationConfirmationUnobservable . ObservationFailure . bounded

bounded :: Text -> Text
bounded = Text.take 1024
