{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated client for the Lifecycle Authority's registered operation
-- front door.  The accepted/duplicate response is canonical CBOR carrying the
-- exact authority-allocated 'OperationId'; no caller infers an identity from a
-- diagnostic string, transport timeout, or local counter.
module Prodbox.ControlPlane.AuthorityOperationClient
  ( AuthorityOperationClient (..)
  , AuthorityOperationAdmission (..)
  , AuthorityOperationClientError (..)
  , lifecycleAuthorityOperationClient
  , lifecycleAuthorityOperationClientAuthenticated
  )
where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientProviders
  , AuthenticatedClientTransport
  , AuthenticatedTransportBounds
  , callAuthenticatedClientTransport
  , callAuthenticatedControlPlane
  )
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityOperationObservePayload (..)
  , AuthorityOperationObserveResponse (..)
  , AuthorityOperationSubmitPayload (..)
  , AuthorityOperationSubmitResponse (..)
  , authorityOperationResponseMaximumBytes
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneClient
  , ControlPlaneResponse (..)
  , ControlPlaneRouteFor
    ( LifecycleOperationObserveRoute
    , LifecycleOperationSubmitRoute
    )
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( ClientSubmissionKey
  , clientSubmissionKeyText
  )
import Prodbox.Lifecycle.Authority.Submission
  ( OperationId
  , RequestDigest
  , SubmissionStatus
  , operationIdDigest
  , requestDigestText
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

data AuthorityOperationClient m = AuthorityOperationClient
  { submitAuthorityOperation
      :: ClientSubmissionKey
      -> RequestDigest
      -> m
           ( Either
               AuthorityOperationClientError
               AuthorityOperationAdmission
           )
  , observeAuthorityOperation
      :: ClientSubmissionKey
      -> m
           ( Either
               AuthorityOperationClientError
               (Maybe SubmissionStatus)
           )
  }

data AuthorityOperationAdmission
  = AuthorityOperationAdmissionAccepted !OperationId
  | AuthorityOperationAdmissionDuplicate !OperationId
  deriving stock (Eq, Show)

data AuthorityOperationClientError
  = AuthorityOperationTransportFailed !AuthenticatedClientError
  | AuthorityOperationResponseInvalid !ControlPlaneResponseCodecError
  | AuthorityOperationResponseStatusMismatch !Int
  | AuthorityOperationResponseDigestMismatch
  | AuthorityOperationRemoteRefused !Int !Text
  | AuthorityOperationResponseShapeMismatch !Int
  deriving stock (Eq, Show)

lifecycleAuthorityOperationClient
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> ControlPlaneClient 'LifecycleAuthorityRuntime
  -> AuthorityOperationClient IO
lifecycleAuthorityOperationClient bounds providers client =
  authorityOperationClientWith
    (callAuthenticatedControlPlane bounds providers client)

-- | Construct the same closed client from an already-complete authenticated
-- transport.  Production host callers use this form so the caller identity,
-- pinned Transit generation, authority scope, epoch, and transport endpoint
-- cannot be split or substituted while a checkpoint transaction is running.
lifecycleAuthorityOperationClientAuthenticated
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> AuthorityOperationClient IO
lifecycleAuthorityOperationClientAuthenticated transport =
  authorityOperationClientWith (callAuthenticatedClientTransport transport)

authorityOperationClientWith
  :: ( ControlPlaneRouteFor 'LifecycleAuthorityRuntime
       -> ByteString
       -> IO (Either AuthenticatedClientError ControlPlaneResponse)
     )
  -> AuthorityOperationClient IO
authorityOperationClientWith callAuthenticated =
  AuthorityOperationClient
    { submitAuthorityOperation = submit
    , observeAuthorityOperation = observe
    }
 where
  submit submissionKey digest = do
    response <-
      call
        LifecycleOperationSubmitRoute
        AuthorityOperationSubmitPayload
          { authorityOperationSubmitKey = clientSubmissionKeyText submissionKey
          , authorityOperationSubmitDigest = requestDigestText digest
          }
    pure $ do
      ControlPlaneResponse status body <- response
      decoded <- decodeResponse body
      case decoded of
        AuthorityOperationAccepted operation
          | status /= 200 -> Left (AuthorityOperationResponseStatusMismatch status)
          | operationIdDigest operation /= digest ->
              Left AuthorityOperationResponseDigestMismatch
          | otherwise -> Right (AuthorityOperationAdmissionAccepted operation)
        AuthorityOperationDuplicate operation
          | status /= 200 -> Left (AuthorityOperationResponseStatusMismatch status)
          | operationIdDigest operation /= digest ->
              Left AuthorityOperationResponseDigestMismatch
          | otherwise -> Right (AuthorityOperationAdmissionDuplicate operation)
        AuthorityOperationSubmitRefused detail ->
          Left (AuthorityOperationRemoteRefused status detail)

  observe submissionKey = do
    response <-
      call
        LifecycleOperationObserveRoute
        AuthorityOperationObservePayload
          { authorityOperationObserveKey = clientSubmissionKeyText submissionKey
          }
    pure $ do
      ControlPlaneResponse status body <- response
      decoded <- decodeResponse body
      case decoded of
        AuthorityOperationObserved operationStatus
          | status == 200 -> Right (Just operationStatus)
          | otherwise -> Left (AuthorityOperationResponseStatusMismatch status)
        AuthorityOperationUnknown
          | status == 404 -> Right Nothing
          | otherwise -> Left (AuthorityOperationResponseStatusMismatch status)
        AuthorityOperationObserveRefused detail ->
          Left (AuthorityOperationRemoteRefused status detail)

  call route payload = do
    attempted <-
      callAuthenticated
        route
        (LazyByteString.toStrict (encodeControlPlaneRequest payload))
    pure (first AuthorityOperationTransportFailed attempted)

  decodeResponse body =
    first
      AuthorityOperationResponseInvalid
      ( decodeControlPlaneResponse
          authorityOperationResponseMaximumBytes
          (LazyByteString.fromStrict body)
      )
