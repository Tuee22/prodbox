{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated client for the purpose-bound aggregate backup export.
module Prodbox.ControlPlane.AuthorityBackupExportClient
  ( AuthorityBackupExportClient
  , AuthorityBackupExportClientError (..)
  , AuthorityBackupExportResponseObservation (..)
  , authorityBackupExportClient
  , authorityBackupExportResponseObservationToken
  , classifyAuthorityBackupExportResponse
  , mkAuthorityBackupExportClient
  , exportAuthorityBackupAggregate
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric (showHex)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.AuthorityBackupExportEndpoint
  ( AuthorityBackupExportPurpose
  , AuthorityBackupExportRequest (..)
  , AuthorityBackupExportResponse (..)
  , authorityBackupExportMaximumResponseBytes
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (LifecycleAuthorityBackupExportRoute)
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

newtype AuthorityBackupExportClient m = AuthorityBackupExportClient
  { callAuthorityBackupExport
      :: AuthorityBackupExportPurpose
      -> m (Either AuthorityBackupExportClientError ByteString)
  }

mkAuthorityBackupExportClient
  :: ( AuthorityBackupExportPurpose
       -> m (Either AuthorityBackupExportClientError ByteString)
     )
  -> AuthorityBackupExportClient m
mkAuthorityBackupExportClient = AuthorityBackupExportClient

data AuthorityBackupExportClientError
  = AuthorityBackupExportTransportFailed !AuthenticatedClientError
  | AuthorityBackupExportHttpStatus !Int
  | AuthorityBackupExportResponseInvalid
      !ControlPlaneResponseCodecError
      !AuthorityBackupExportResponseObservation
  | AuthorityBackupExportEnvelopeInvalid
  | AuthorityBackupExportDigestMismatch
  deriving stock (Eq, Show)

-- | Value-free classification of the bounded HTTP-200 response body.  This is
-- diagnostic only: recognizing an endpoint-result envelope does not make the
-- client accept it as the direct response type.
data AuthorityBackupExportResponseObservation
  = AuthorityBackupExportResponseDirect
  | AuthorityBackupExportResponseEndpointSuccess
  | AuthorityBackupExportResponseEndpointFailure
  | AuthorityBackupExportResponseEmpty
  | AuthorityBackupExportResponseOther
  deriving stock (Bounded, Enum, Eq, Show)

authorityBackupExportResponseObservationToken
  :: AuthorityBackupExportResponseObservation -> Text
authorityBackupExportResponseObservationToken observation = case observation of
  AuthorityBackupExportResponseDirect -> "direct"
  AuthorityBackupExportResponseEndpointSuccess -> "endpoint-success"
  AuthorityBackupExportResponseEndpointFailure -> "endpoint-failure"
  AuthorityBackupExportResponseEmpty -> "empty"
  AuthorityBackupExportResponseOther -> "other"

classifyAuthorityBackupExportResponse
  :: ByteString -> AuthorityBackupExportResponseObservation
classifyAuthorityBackupExportResponse body
  | ByteString.null body = AuthorityBackupExportResponseEmpty
  | otherwise =
      case directResponse of
        Right _ -> AuthorityBackupExportResponseDirect
        Left _ -> case endpointResponse of
          Right (Right _) -> AuthorityBackupExportResponseEndpointSuccess
          Right (Left _) -> AuthorityBackupExportResponseEndpointFailure
          Left _ -> AuthorityBackupExportResponseOther
 where
  directResponse =
    decodeControlPlaneResponse
      authorityBackupExportMaximumResponseBytes
      (LazyByteString.fromStrict body)
      :: Either ControlPlaneResponseCodecError AuthorityBackupExportResponse
  endpointResponse =
    decodeControlPlaneResponse
      authorityBackupExportMaximumResponseBytes
      (LazyByteString.fromStrict body)
      :: Either
           ControlPlaneResponseCodecError
           (Either Text AuthorityBackupExportResponse)

authorityBackupExportClient
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> AuthorityBackupExportClient IO
authorityBackupExportClient transport =
  AuthorityBackupExportClient $ \purpose -> do
    attempted <-
      callAuthenticatedClientTransport
        transport
        LifecycleAuthorityBackupExportRoute
        ( LazyByteString.toStrict
            (encodeControlPlaneRequest (AuthorityBackupExportRequest purpose))
        )
    pure $ do
      ControlPlaneResponse status body <- first AuthorityBackupExportTransportFailed attempted
      if status /= 200
        then Left (AuthorityBackupExportHttpStatus status)
        else do
          response <-
            first
              ( \err ->
                  AuthorityBackupExportResponseInvalid
                    err
                    (classifyAuthorityBackupExportResponse body)
              )
              ( decodeControlPlaneResponse
                  authorityBackupExportMaximumResponseBytes
                  (LazyByteString.fromStrict body)
              )
          let envelope = authorityBackupExportEnvelope response
          if ByteString.null envelope
            || ByteString.length envelope > authorityBackupExportMaximumResponseBytes
            then Left AuthorityBackupExportEnvelopeInvalid
            else
              if digestBytes envelope /= authorityBackupExportDigest response
                then Left AuthorityBackupExportDigestMismatch
                else Right envelope

exportAuthorityBackupAggregate
  :: (Monad m)
  => AuthorityBackupExportClient m
  -> AuthorityBackupExportPurpose
  -> m (Either AuthorityBackupExportClientError ByteString)
exportAuthorityBackupAggregate = callAuthorityBackupExport

digestBytes :: ByteString -> Text
digestBytes = Text.pack . concatMap byteHex . ByteString.unpack . SHA256.hash
 where
  byteHex byte =
    let rendered = showHex byte ""
     in if length rendered == 1 then '0' : rendered else rendered
