{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated host-side ownership-manifest client.  The Authority's raw
-- read-back algebra crosses the wire intact; only after authentication,
-- version/identity validation, and canonical payload confirmation can Missing
-- become observation-only Absent.
module Prodbox.ControlPlane.OwnershipManifestTransportClient
  ( lifecycleAuthorityOwnershipManifestAuthenticatedClient
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
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (LifecycleOwnershipManifestRoute)
  )
import Prodbox.ControlPlane.Codec (encodeControlPlaneRequest)
import Prodbox.ControlPlane.OwnershipManifestEndpoint
  ( OwnershipManifestEndpointResponseError (..)
  , OwnershipManifestWireRefusal
  , OwnershipManifestWireUnavailable (..)
  , confirmOwnershipManifestCommitResponse
  , confirmOwnershipManifestReadBackResponse
  , decodeOwnershipManifestEndpointResponse
  , ownershipManifestCommitWireRequest
  , ownershipManifestReadBackWireRequest
  , ownershipManifestWireResponseStatus
  )
import Prodbox.ControlPlane.OwnershipManifestRepository
  ( OwnershipManifestClient (..)
  , OwnershipManifestRepositoryError (..)
  , authorityOwnershipManifestWriteIdentity
  , confirmOwnershipManifestDecisionReadBack
  , prepareAuthorityOwnershipManifestWrite
  )
import Prodbox.Http.ReplyStatus (replyStatusCode)
import Prodbox.Lifecycle.Teardown.Model (ObservationFailure (..))
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

lifecycleAuthorityOwnershipManifestAuthenticatedClient
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> OwnershipManifestClient IO
lifecycleAuthorityOwnershipManifestAuthenticatedClient transport =
  OwnershipManifestClient
    { attemptOwnershipManifestWriteAheadCommit = attemptWriteAheadCommit
    , readBackOwnershipManifestDecisionByIdentity = \target identity -> do
        attempted <- callWire (ownershipManifestReadBackWireRequest identity)
        pure $ do
          response <- attempted
          observed <-
            first
              endpointResponseError
              (confirmOwnershipManifestReadBackResponse identity response)
          confirmOwnershipManifestDecisionReadBack target identity observed
    }
 where
  attemptWriteAheadCommit write =
    case prepareAuthorityOwnershipManifestWrite write of
      Left err -> pure (Left err)
      Right prepared -> do
        attempted <- callWire (ownershipManifestCommitWireRequest prepared)
        pure $ do
          response <- attempted
          first
            endpointResponseError
            ( confirmOwnershipManifestCommitResponse
                (authorityOwnershipManifestWriteIdentity prepared)
                response
            )

  callWire request = do
    attempted <-
      callAuthenticatedClientTransport
        transport
        LifecycleOwnershipManifestRoute
        (LazyByteString.toStrict (encodeControlPlaneRequest request))
    pure $ do
      ControlPlaneResponse status body <-
        first
          (remoteUnobservable . Text.pack . show)
          attempted
      response <-
        first
          (remoteUnobservable . Text.pack . show)
          (decodeOwnershipManifestEndpointResponse body)
      let expectedStatus =
            replyStatusCode (ownershipManifestWireResponseStatus response)
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
  :: OwnershipManifestEndpointResponseError
  -> OwnershipManifestRepositoryError
endpointResponseError err = case err of
  OwnershipManifestEndpointResponseIdentityInvalid detail -> detail
  OwnershipManifestEndpointResponseIdentityMismatch expected actual ->
    OwnershipManifestRepositoryIdentityMismatch expected actual
  OwnershipManifestEndpointResponseRefused refusal ->
    remoteUnobservable (renderRefusal refusal)
  OwnershipManifestEndpointResponseUnavailable
    (OwnershipManifestWireEndpointUnavailable detail) ->
      remoteUnobservable detail
  OwnershipManifestEndpointResponseVersionMismatch {} -> invalidResponse
  OwnershipManifestEndpointResponseKindMismatch -> invalidResponse
  OwnershipManifestEndpointResponseObjectVersionInvalid {} -> invalidResponse
  OwnershipManifestEndpointResponsePartialEmpty -> invalidResponse
 where
  invalidResponse = remoteUnobservable (Text.pack (show err))

renderRefusal :: OwnershipManifestWireRefusal -> Text
renderRefusal = bounded . Text.pack . show

remoteUnobservable :: Text -> OwnershipManifestRepositoryError
remoteUnobservable =
  OwnershipManifestRepositoryUnobservable . ObservationFailure . bounded

bounded :: Text -> Text
bounded = Text.take 1024
