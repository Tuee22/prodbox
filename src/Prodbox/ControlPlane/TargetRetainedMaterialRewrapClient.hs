{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Closed Lifecycle-Authority client for the retained-home Target Agent's
-- destination-rewrap route.
module Prodbox.ControlPlane.TargetRetainedMaterialRewrapClient
  ( TargetRetainedMaterialRewrapClient
  , TargetRetainedMaterialRewrapClientError (..)
  , targetRetainedMaterialRewrapClient
  , targetRetainedMaterialRewrapClientWith
  , requestTargetRetainedMaterialRewrap
  )
where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (TargetRetainedMaterialRewrapRoute)
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.TargetRetainedMaterialRewrapEndpoint
  ( TargetRetainedMaterialRewrapRequest
  , TargetRetainedMaterialRewrapResponse (..)
  , targetRetainedMaterialRewrapResponseMaximumBytes
  )
import Prodbox.Runtime.Role (RuntimeRole (TargetSecretAgentRuntime))

newtype TargetRetainedMaterialRewrapClient m
  = TargetRetainedMaterialRewrapClient
  { callTargetRetainedMaterialRewrap
      :: TargetRetainedMaterialRewrapRequest
      -> m
           ( Either
               TargetRetainedMaterialRewrapClientError
               (ByteString, Text, Text)
           )
  }

data TargetRetainedMaterialRewrapClientError
  = TargetRetainedMaterialRewrapClientTransportFailed !AuthenticatedClientError
  | TargetRetainedMaterialRewrapClientResponseInvalid !ControlPlaneResponseCodecError
  | TargetRetainedMaterialRewrapClientHttpStatus !Int
  | TargetRetainedMaterialRewrapClientRefused !Text
  | TargetRetainedMaterialRewrapClientUnavailable !Text
  deriving stock (Eq, Show)

targetRetainedMaterialRewrapClient
  :: AuthenticatedClientTransport 'TargetSecretAgentRuntime
  -> TargetRetainedMaterialRewrapClient IO
targetRetainedMaterialRewrapClient transport =
  TargetRetainedMaterialRewrapClient $ \request -> do
    attempted <-
      callAuthenticatedClientTransport
        transport
        TargetRetainedMaterialRewrapRoute
        (LazyByteString.toStrict (encodeControlPlaneRequest request))
    pure $ do
      ControlPlaneResponse status body <-
        first TargetRetainedMaterialRewrapClientTransportFailed attempted
      response <-
        first
          TargetRetainedMaterialRewrapClientResponseInvalid
          ( decodeControlPlaneResponse
              targetRetainedMaterialRewrapResponseMaximumBytes
              (LazyByteString.fromStrict body)
          )
      case response of
        TargetRetainedMaterialRewrapped envelope receipt digest
          | status == 200 -> Right (envelope, receipt, digest)
          | otherwise -> Left (TargetRetainedMaterialRewrapClientHttpStatus status)
        TargetRetainedMaterialRewrapRefused detail ->
          Left (TargetRetainedMaterialRewrapClientRefused detail)
        TargetRetainedMaterialRewrapUnavailable detail ->
          Left (TargetRetainedMaterialRewrapClientUnavailable detail)

targetRetainedMaterialRewrapClientWith
  :: ( TargetRetainedMaterialRewrapRequest
       -> m
            ( Either
                TargetRetainedMaterialRewrapClientError
                (ByteString, Text, Text)
            )
     )
  -> TargetRetainedMaterialRewrapClient m
targetRetainedMaterialRewrapClientWith = TargetRetainedMaterialRewrapClient

requestTargetRetainedMaterialRewrap
  :: (Monad m)
  => TargetRetainedMaterialRewrapClient m
  -> TargetRetainedMaterialRewrapRequest
  -> m
       ( Either
           TargetRetainedMaterialRewrapClientError
           (ByteString, Text, Text)
       )
requestTargetRetainedMaterialRewrap = callTargetRetainedMaterialRewrap
