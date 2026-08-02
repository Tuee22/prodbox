{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Metadata-only authenticated Target Secret Agent client. Secret payloads
-- are accepted only by attested one-shot workers and are not representable on
-- this standing-role transport.
module Prodbox.ControlPlane.TargetMaterialClient
  ( TargetMaterialClient (..)
  , TargetMaterialClientError (..)
  , targetMaterialClient
  , targetWorkerReceiptFromMaterialObservation
  )
where

import Codec.Serialise (Serialise)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientError
  , AuthenticatedClientTransport
  , callAuthenticatedClientTransport
  )
import Prodbox.ControlPlane.Client
  ( ControlPlaneResponse (..)
  , ControlPlaneRouteFor (TargetMaterialObserveRoute)
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneResponseCodecError
  , decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.TargetMaterialEndpoint
  ( TargetMaterialObservation (..)
  , TargetMaterialObserveRequest (..)
  , TargetMaterialObserveResponse (..)
  , targetMaterialResponseMaximumBytes
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetSecretId
  )
import Prodbox.ControlPlane.TargetSecretWorker
  ( TargetWorkerReceipt
  , mkTargetWorkerReceiptProjection
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( mkCredentialGeneration
  , mkTargetValueDigest
  )
import Prodbox.Runtime.Role (RuntimeRole (TargetSecretAgentRuntime))

newtype TargetMaterialClient m = TargetMaterialClient
  { observeRegisteredTargetMaterial
      :: TargetSecretId
      -> m
           ( Either
               TargetMaterialClientError
               (Maybe TargetMaterialObservation)
           )
  }

data TargetMaterialClientError
  = TargetMaterialClientTransportFailed !AuthenticatedClientError
  | TargetMaterialClientResponseInvalid !ControlPlaneResponseCodecError
  | TargetMaterialClientHttpStatus !Int
  | TargetMaterialClientRemoteRefused !Text
  deriving stock (Eq, Show)

targetMaterialClient
  :: AuthenticatedClientTransport 'TargetSecretAgentRuntime
  -> TargetMaterialClient IO
targetMaterialClient transport = TargetMaterialClient observe
 where
  observe target = do
    attempted <-
      callAuthenticatedClientTransport
        transport
        TargetMaterialObserveRoute
        ( requestBody
            TargetMaterialObserveRequest
              { targetMaterialObserveTarget = target
              }
        )
    pure $ do
      ControlPlaneResponse status body <- first TargetMaterialClientTransportFailed attempted
      response <- decodeResponse body
      case response of
        TargetMaterialMissing
          | status == 404 -> Right Nothing
          | otherwise -> Left (TargetMaterialClientHttpStatus status)
        TargetMaterialObserved metadata
          | status == 200 -> Right (Just metadata)
          | otherwise -> Left (TargetMaterialClientHttpStatus status)
        TargetMaterialObserveRefused detail ->
          Left (TargetMaterialClientRemoteRefused detail)

  decodeResponse
    :: (Serialise value)
    => ByteString
    -> Either TargetMaterialClientError value
  decodeResponse =
    first TargetMaterialClientResponseInvalid
      . decodeControlPlaneResponse targetMaterialResponseMaximumBytes
      . LazyByteString.fromStrict

  requestBody :: (Serialise value) => value -> ByteString
  requestBody = LazyByteString.toStrict . encodeControlPlaneRequest

targetWorkerReceiptFromMaterialObservation
  :: TargetSecretId
  -> TargetMaterialObservation
  -> Either Text TargetWorkerReceipt
targetWorkerReceiptFromMaterialObservation target observation = do
  generation <-
    first (Text.pack . show) (mkCredentialGeneration (targetMaterialObservedGeneration observation))
  requestDigest <-
    first (Text.pack . show) (mkTargetValueDigest (targetMaterialObservedRequestDigest observation))
  actionDigest <-
    first (Text.pack . show) (mkTargetValueDigest (targetMaterialObservedActionDigest observation))
  first
    (Text.pack . show)
    ( mkTargetWorkerReceiptProjection
        target
        generation
        (targetMaterialObservedVaultVersion observation)
        (targetMaterialObservedCommitment observation)
        requestDigest
        actionDigest
        (targetMaterialObservedPodUid observation)
        (targetMaterialObservedImageDigest observation)
    )
