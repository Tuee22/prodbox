{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated host-side implementation of the split AWS stack-reader
-- client.  Commit returns only its durable write disposition.  The opaque
-- committed bundle is reconstructed exclusively after a separate Authority
-- identity read-back and exact canonical-byte validation.
module Prodbox.ControlPlane.AwsStackReaderTransportClient
  ( lifecycleAuthorityAwsStackReaderAuthenticatedClient
  )
where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.AwsStackReaderEndpoint
  ( AwsStackReaderEndpointResponseError (..)
  , AwsStackReaderWireRefusal (..)
  , AwsStackReaderWireResponse (..)
  , AwsStackReaderWireUnavailable (..)
  , awsStackReaderCommitWireRequest
  , awsStackReaderEndpointFormatVersion
  , awsStackReaderReadBackWireRequest
  , awsStackReaderWireResponseStatus
  , confirmAwsStackReaderCommitResponse
  , decodeAwsStackReaderEndpointResponse
  )
import Prodbox.ControlPlane.AwsStackReaderRepository.Internal
  ( AwsStackReaderAuthorityIdentity
  , AwsStackReaderBundle
  , AwsStackReaderClient (..)
  , AwsStackReaderClientError (..)
  , AwsStackReaderError (..)
  , AwsStackReaderReadBackObservation (..)
  , CommittedAwsStackReaderBundle
  , awsStackReaderAuthorityIdentity
  , awsStackReaderBundleBytes
  , awsStackReaderBundleIdentity
  , committedAwsStackReaderBytes
  , committedAwsStackReaderDecisionInputs
  , committedAwsStackReaderProviderBinding
  , confirmCommittedAwsStackReaderBytes
  , decodeAwsStackReaderAuthorityIdentity
  , prepareAwsStackReaderBundle
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (LifecycleAwsStackReaderRoute)
  )
import Prodbox.ControlPlane.Codec (encodeControlPlaneRequest)
import Prodbox.Http.ReplyStatus (replyStatusCode)
import Prodbox.Lifecycle.CleanupRun
  ( CleanupDigest
  , CleanupRunId
  )
import Prodbox.Lifecycle.Teardown.Model
  ( ObservationFailure (..)
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

lifecycleAuthorityAwsStackReaderAuthenticatedClient
  :: CleanupRunId
  -> CleanupDigest
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> AwsStackReaderClient IO
lifecycleAuthorityAwsStackReaderAuthenticatedClient runId graphDigest transport = client
 where
  client =
    AwsStackReaderClient
      { internalCommitAwsStackReaderBundleAttempt = commitAttempt
      , internalIndependentlyReadBackCommittedAwsStackReaderBundle = readExact
      , internalCommitAndReadBackAwsStackReaderBundle = commitAndReadBack
      , internalReadBackAwsStackDecisionInputs = \operationId key scope ->
          fmap
            ( first renderClientError
                . fmap committedAwsStackReaderDecisionInputs
            )
            (readExact operationId key scope)
      , internalReadBackAwsStackProviderBinding = \operationId key scope ->
          fmap
            ( first renderClientError
                . fmap committedAwsStackReaderProviderBinding
            )
            (readExact operationId key scope)
      }

  commitAttempt inputs binding =
    case prepareAwsStackReaderBundle runId graphDigest inputs binding of
      Left err -> pure (Left (AwsStackReaderClientRequestInvalid err))
      Right bundle ->
        callCommit
          (awsStackReaderAuthorityIdentityForBundle bundle)
          (awsStackReaderCommitWireRequest bundle)

  readExact operationId key scope =
    case awsStackReaderAuthorityIdentity runId graphDigest operationId key scope of
      Left err -> pure (Left (AwsStackReaderClientRequestInvalid err))
      Right identity ->
        callReadBack identity (awsStackReaderReadBackWireRequest identity)

  commitAndReadBack inputs binding =
    case prepareAwsStackReaderBundle runId graphDigest inputs binding of
      Left err -> pure (Left (AwsStackReaderClientRequestInvalid err))
      Right candidate -> do
        let identity = awsStackReaderAuthorityIdentityForBundle candidate
        committed <- callCommit identity (awsStackReaderCommitWireRequest candidate)
        case committed of
          Left err -> pure (Left err)
          Right disposition -> do
            observed <-
              callReadBack identity (awsStackReaderReadBackWireRequest identity)
            pure $ case observed of
              Left err ->
                Left
                  ( AwsStackReaderClientCommitUnconfirmed
                      disposition
                      (clientErrorObservation err)
                  )
              Right exact
                | committedAwsStackReaderBytes exact
                    == committedAwsStackReaderBytesFromCandidate candidate ->
                    Right exact
                | otherwise ->
                    Left
                      ( AwsStackReaderClientCommitUnconfirmed
                          disposition
                          ( AwsStackReaderReadBackPresent
                              (committedAwsStackReaderBytes exact)
                          )
                      )

  callCommit identity request = do
    response <- callWire request
    pure $ do
      wire <- response
      first
        (endpointResponseError identity)
        (confirmAwsStackReaderCommitResponse identity wire)

  callReadBack identity request = do
    response <- callWire request
    pure $ do
      wire <- response
      first
        (endpointResponseError identity)
        (confirmAwsStackReaderReadBackResponse identity wire)

  callWire request = do
    attempted <-
      callAuthenticatedClientTransport
        transport
        LifecycleAwsStackReaderRoute
        (LazyByteString.toStrict (encodeControlPlaneRequest request))
    pure $ do
      ControlPlaneResponse status body <-
        first
          (AwsStackReaderClientTransportFailed . bounded . Text.pack . show)
          attempted
      response <-
        first
          (AwsStackReaderClientResponseInvalid . bounded . Text.pack . show)
          (decodeAwsStackReaderEndpointResponse body)
      let expectedStatus = replyStatusCode (awsStackReaderWireResponseStatus response)
      if status == expectedStatus
        then Right response
        else Left (AwsStackReaderClientHttpStatusMismatch expectedStatus status)

awsStackReaderAuthorityIdentityForBundle
  :: AwsStackReaderBundle
  -> AwsStackReaderAuthorityIdentity
awsStackReaderAuthorityIdentityForBundle = awsStackReaderBundleIdentity

confirmAwsStackReaderReadBackResponse
  :: AwsStackReaderAuthorityIdentity
  -> AwsStackReaderWireResponse
  -> Either
       AwsStackReaderEndpointResponseError
       CommittedAwsStackReaderBundle
confirmAwsStackReaderReadBackResponse expected response = case response of
  AwsStackReaderWireReadBackPresent version identityBytes bundleBytes -> do
    if version == awsStackReaderEndpointFormatVersion
      then Right ()
      else
        Left
          ( AwsStackReaderEndpointResponseVersionMismatch
              awsStackReaderEndpointFormatVersion
              version
          )
    actual <-
      first
        AwsStackReaderEndpointResponseIdentityInvalid
        (decodeAwsStackReaderAuthorityIdentity identityBytes)
    if actual == expected
      then Right ()
      else
        Left
          ( AwsStackReaderEndpointResponseIdentityMismatch
              expected
              actual
          )
    first
      AwsStackReaderEndpointResponseReadBackInvalid
      (confirmCommittedAwsStackReaderBytes expected bundleBytes)
  AwsStackReaderWireRefused version refusal
    | version == awsStackReaderEndpointFormatVersion ->
        Left (AwsStackReaderEndpointResponseRefused refusal)
    | otherwise ->
        Left
          ( AwsStackReaderEndpointResponseVersionMismatch
              awsStackReaderEndpointFormatVersion
              version
          )
  AwsStackReaderWireUnavailable version reason
    | version == awsStackReaderEndpointFormatVersion ->
        Left (AwsStackReaderEndpointResponseUnavailable reason)
    | otherwise ->
        Left
          ( AwsStackReaderEndpointResponseVersionMismatch
              awsStackReaderEndpointFormatVersion
              version
          )
  AwsStackReaderWireCommitResult {} ->
    Left AwsStackReaderEndpointResponseKindMismatch

committedAwsStackReaderBytesFromCandidate
  :: AwsStackReaderBundle
  -> ByteString
committedAwsStackReaderBytesFromCandidate = awsStackReaderBundleBytes

endpointResponseError
  :: AwsStackReaderAuthorityIdentity
  -> AwsStackReaderEndpointResponseError
  -> AwsStackReaderClientError
endpointResponseError expected err = case err of
  AwsStackReaderEndpointResponseIdentityInvalid detail ->
    AwsStackReaderClientReadBackInvalid detail
  AwsStackReaderEndpointResponseIdentityMismatch expectedIdentity actual ->
    AwsStackReaderClientReadBackInvalid
      (AwsStackReaderIdentityMismatch expectedIdentity actual)
  AwsStackReaderEndpointResponseReadBackInvalid detail -> detail
  AwsStackReaderEndpointResponseRefused refusal -> case refusal of
    AwsStackReaderWireReadBackMissing -> AwsStackReaderClientMissing
    AwsStackReaderWireReadBackCorrupt detail -> AwsStackReaderClientCorrupt detail
    AwsStackReaderWireReadBackUnbounded actual maximumBytes ->
      AwsStackReaderClientUnbounded actual maximumBytes
    AwsStackReaderWireReadBackIdentityMismatch actualBytes ->
      case decodeAwsStackReaderAuthorityIdentity actualBytes of
        Left detail -> AwsStackReaderClientReadBackInvalid detail
        Right actual ->
          AwsStackReaderClientReadBackInvalid
            (AwsStackReaderIdentityMismatch expected actual)
    AwsStackReaderWireReadBackInvalid detail ->
      AwsStackReaderClientReadBackInvalid (AwsStackReaderFieldInvalid detail)
    other -> AwsStackReaderClientRemoteRefused (bounded (Text.pack (show other)))
  AwsStackReaderEndpointResponseUnavailable reason -> case reason of
    AwsStackReaderWireReadBackUnobservable detail ->
      AwsStackReaderClientUnobservable (ObservationFailure detail)
    AwsStackReaderWireEndpointUnavailable detail ->
      AwsStackReaderClientRemoteUnavailable detail
  AwsStackReaderEndpointResponseVersionMismatch {} -> invalidResponse
  AwsStackReaderEndpointResponseKindMismatch -> invalidResponse
 where
  invalidResponse = AwsStackReaderClientResponseInvalid (bounded (Text.pack (show err)))

clientErrorObservation
  :: AwsStackReaderClientError -> AwsStackReaderReadBackObservation
clientErrorObservation err = case err of
  AwsStackReaderClientMissing -> AwsStackReaderReadBackMissing
  AwsStackReaderClientCorrupt detail -> AwsStackReaderReadBackCorrupt detail
  AwsStackReaderClientUnobservable failure ->
    AwsStackReaderReadBackUnobservable failure
  AwsStackReaderClientUnbounded actual maximumBytes ->
    AwsStackReaderReadBackUnbounded actual maximumBytes
  _ ->
    AwsStackReaderReadBackUnobservable
      (ObservationFailure (renderClientError err))

renderClientError :: AwsStackReaderClientError -> Text
renderClientError = bounded . Text.pack . show

bounded :: Text -> Text
bounded = Text.take 1024
