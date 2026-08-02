{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Closed client capability for one registered Pulumi checkpoint.
--
-- Construction fixes the registry identity.  Calls can therefore transport
-- checkpoint bytes and an already-admitted operation reference, but cannot
-- select an arbitrary project, stack, object key, bucket, or endpoint.
module Prodbox.ControlPlane.PulumiCheckpointClient
  ( PulumiCheckpointAuthority (..)
  , PulumiCheckpointClientError (..)
  , lifecycleAuthorityPulumiCheckpoint
  , lifecycleAuthorityPulumiCheckpointAuthenticated
  )
where

import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Set qualified as Set
import Data.Text (Text)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientProviders
  , AuthenticatedClientTransport
  , AuthenticatedTransportBounds
  , callAuthenticatedClientTransport
  , callAuthenticatedControlPlane
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneClient
  , ControlPlaneResponse (..)
  , ControlPlaneRouteFor (LifecyclePulumiCheckpointRoute)
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.PulumiCheckpointEndpoint
  ( PulumiCheckpointMutationTicket (..)
  , PulumiCheckpointObservation (..)
  , PulumiCheckpointPublicationResult (..)
  , PulumiCheckpointRequest (..)
  , PulumiCheckpointResponse (..)
  , PulumiCheckpointRetirementResult (..)
  , PulumiCheckpointWireObservation (..)
  , PulumiCheckpointWirePublication (..)
  , PulumiCheckpointWireRetirement (..)
  , pulumiCheckpointResponseHttpStatus
  , pulumiCheckpointResponseMaximumBytes
  )
import Prodbox.Lifecycle.Authority.Submission (OperationId)
import Prodbox.Lifecycle.PulumiCheckpoint
  ( CanonicalPulumiCheckpoint
  , PulumiCheckpointCodecError
  , PulumiCheckpointDigest
  , PulumiCheckpointPayloadKind (PulumiFileBackendCheckpoint)
  , RegisteredPulumiCheckpoint
  , canonicalPulumiCheckpointBytes
  , canonicalPulumiCheckpointDigest
  , decodeCanonicalPulumiCheckpoint
  , pulumiCheckpointMaximumBytes
  , registeredPulumiCheckpointName
  )
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

data PulumiCheckpointAuthority m = PulumiCheckpointAuthority
  { observePulumiCheckpoint
      :: !(m (Either PulumiCheckpointClientError PulumiCheckpointObservation))
  , publishPulumiCheckpoint
      :: !( OperationId
            -> Maybe PulumiCheckpointDigest
            -> CanonicalPulumiCheckpoint
            -> m
                 ( Either
                     PulumiCheckpointClientError
                     PulumiCheckpointPublicationResult
                 )
          )
  , retirePulumiCheckpoint
      :: !( OperationId
            -> Maybe PulumiCheckpointDigest
            -> m
                 ( Either
                     PulumiCheckpointClientError
                     PulumiCheckpointRetirementResult
                 )
          )
  }

data PulumiCheckpointClientError
  = PulumiCheckpointTransportFailed !AuthenticatedClientError
  | PulumiCheckpointResponseDecodeFailed !ControlPlaneResponseCodecError
  | PulumiCheckpointHttpStatusMismatch !Int !Int
  | PulumiCheckpointRegistrationMismatch !Text !Text
  | PulumiCheckpointResponseShapeMismatch !Text
  | PulumiCheckpointRemoteRefused !Text
  | PulumiCheckpointObservedPayloadInvalid !PulumiCheckpointCodecError
  | PulumiCheckpointObservedDigestMismatch
  deriving stock (Eq, Show)

lifecycleAuthorityPulumiCheckpoint
  :: AuthenticatedTransportBounds
  -> AuthenticatedClientProviders IO
  -> RegisteredPulumiCheckpoint
  -> ControlPlaneClient 'LifecycleAuthorityRuntime
  -> PulumiCheckpointAuthority IO
lifecycleAuthorityPulumiCheckpoint bounds providers registered client =
  pulumiCheckpointClientWith
    (callAuthenticatedControlPlane bounds providers client)
    registered

-- | Bind one exact registered checkpoint to an already-complete authenticated
-- Lifecycle Authority transport.  This is the production construction path;
-- it leaves no raw endpoint beside the caller-bound transport for a checkpoint
-- caller to fall back to.
lifecycleAuthorityPulumiCheckpointAuthenticated
  :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> RegisteredPulumiCheckpoint
  -> PulumiCheckpointAuthority IO
lifecycleAuthorityPulumiCheckpointAuthenticated transport =
  pulumiCheckpointClientWith (callAuthenticatedClientTransport transport)

pulumiCheckpointClientWith
  :: ( ControlPlaneRouteFor 'LifecycleAuthorityRuntime
       -> ByteString
       -> IO (Either AuthenticatedClientError ControlPlaneResponse)
     )
  -> RegisteredPulumiCheckpoint
  -> PulumiCheckpointAuthority IO
pulumiCheckpointClientWith callAuthenticated registered =
  PulumiCheckpointAuthority
    { observePulumiCheckpoint = do
        response <- call (ObservePulumiCheckpoint registeredName)
        pure $ do
          decoded <- response
          case decoded of
            PulumiCheckpointObserved echoed observation -> do
              validateRegistration echoed
              decodeObservation observation
            other -> Left (unexpected other)
    , publishPulumiCheckpoint = \operation expected checkpoint -> do
        response <-
          call
            ( PublishPulumiCheckpoint
                registeredName
                PulumiCheckpointMutationTicket
                  { pulumiCheckpointTicketOperation = operation
                  , pulumiCheckpointTicketExpectedDigest = expected
                  }
                (canonicalPulumiCheckpointBytes checkpoint)
            )
        pure $ do
          decoded <- response
          case decoded of
            PulumiCheckpointPublication echoed publication -> do
              validateRegistration echoed
              decodePublication publication
            other -> Left (unexpected other)
    , retirePulumiCheckpoint = \operation expected -> do
        response <-
          call
            ( RetirePulumiCheckpoint
                registeredName
                PulumiCheckpointMutationTicket
                  { pulumiCheckpointTicketOperation = operation
                  , pulumiCheckpointTicketExpectedDigest = expected
                  }
            )
        pure $ do
          decoded <- response
          case decoded of
            PulumiCheckpointRetirement echoed retirement -> do
              validateRegistration echoed
              decodeRetirement retirement
            other -> Left (unexpected other)
    }
 where
  registeredName = registeredPulumiCheckpointName registered

  validateRegistration echoed
    | echoed == registeredName = Right ()
    | otherwise =
        Left
          ( PulumiCheckpointRegistrationMismatch
              registeredName
              echoed
          )

  call request = do
    attempted <-
      callAuthenticated
        LifecyclePulumiCheckpointRoute
        (LazyByteString.toStrict (encodeControlPlaneRequest request))
    pure $ do
      ControlPlaneResponse status body <-
        mapLeft PulumiCheckpointTransportFailed attempted
      decoded <-
        mapLeft
          PulumiCheckpointResponseDecodeFailed
          ( decodeControlPlaneResponse
              pulumiCheckpointResponseMaximumBytes
              (LazyByteString.fromStrict body)
          )
      let expectedStatus = pulumiCheckpointResponseHttpStatus decoded
      if status == expectedStatus
        then Right decoded
        else Left (PulumiCheckpointHttpStatusMismatch expectedStatus status)

  unexpected response = case response of
    PulumiCheckpointBadRequest detail -> PulumiCheckpointRemoteRefused detail
    PulumiCheckpointRegistrationRefused detail ->
      PulumiCheckpointRemoteRefused detail
    PulumiCheckpointOperationRefRefused _ detail ->
      PulumiCheckpointRemoteRefused detail
    PulumiCheckpointPayloadRefused _ detail ->
      PulumiCheckpointRemoteRefused detail
    _ -> PulumiCheckpointResponseShapeMismatch (responseToken response)

decodeObservation
  :: PulumiCheckpointWireObservation
  -> Either PulumiCheckpointClientError PulumiCheckpointObservation
decodeObservation observation = case observation of
  PulumiCheckpointWireMissing -> Right PulumiCheckpointMissing
  PulumiCheckpointWireObserved expectedDigest bytes -> do
    checkpoint <-
      mapLeft
        PulumiCheckpointObservedPayloadInvalid
        ( decodeCanonicalPulumiCheckpoint
            (Set.singleton PulumiFileBackendCheckpoint)
            pulumiCheckpointMaximumBytes
            bytes
        )
    if canonicalPulumiCheckpointDigest checkpoint == expectedDigest
      then Right (PulumiCheckpointCurrent checkpoint)
      else Left PulumiCheckpointObservedDigestMismatch
  PulumiCheckpointWireCorrupt detail ->
    Right (PulumiCheckpointCorrupt detail)
  PulumiCheckpointWireCorruptAt digest detail ->
    Right (PulumiCheckpointCorruptAt digest detail)
  PulumiCheckpointWireEndpointUnready detail ->
    Right (PulumiCheckpointEndpointUnready detail)
  PulumiCheckpointWireUnobservable detail ->
    Right (PulumiCheckpointUnobservable detail)

decodePublication
  :: PulumiCheckpointWirePublication
  -> Either PulumiCheckpointClientError PulumiCheckpointPublicationResult
decodePublication publication = case publication of
  PulumiCheckpointWirePublished digest ->
    Right (PulumiCheckpointPublished digest)
  PulumiCheckpointWireAlreadyCurrent digest ->
    Right (PulumiCheckpointAlreadyCurrent digest)
  PulumiCheckpointWirePublicationConflict observation ->
    PulumiCheckpointPublicationConflict <$> decodeObservation observation
  PulumiCheckpointWirePublicationRefused detail ->
    Right (PulumiCheckpointPublicationRefused detail)
  PulumiCheckpointWirePublicationUnavailable detail ->
    Right (PulumiCheckpointPublicationUnavailable detail)

decodeRetirement
  :: PulumiCheckpointWireRetirement
  -> Either PulumiCheckpointClientError PulumiCheckpointRetirementResult
decodeRetirement retirement = case retirement of
  PulumiCheckpointWireAlreadyAbsent -> Right PulumiCheckpointAlreadyAbsent
  PulumiCheckpointWireRetiredAndReadBack ->
    Right PulumiCheckpointRetiredAndReadBack
  PulumiCheckpointWireRetirementRefused observation ->
    PulumiCheckpointRetirementRefused <$> decodeObservation observation
  PulumiCheckpointWireRetirementUnavailable detail ->
    Right (PulumiCheckpointRetirementUnavailable detail)

responseToken :: PulumiCheckpointResponse -> Text
responseToken response = case response of
  PulumiCheckpointObserved {} -> "observation"
  PulumiCheckpointPublication {} -> "publication"
  PulumiCheckpointRetirement {} -> "retirement"
  PulumiCheckpointBadRequest detail -> "bad-request:" <> detail
  PulumiCheckpointRegistrationRefused detail -> "registration-refused:" <> detail
  PulumiCheckpointOperationRefRefused _ detail -> "operation-ref-refused:" <> detail
  PulumiCheckpointPayloadRefused _ detail -> "payload-refused:" <> detail

mapLeft :: (left -> other) -> Either left right -> Either other right
mapLeft convert result = case result of
  Left err -> Left (convert err)
  Right value -> Right value
