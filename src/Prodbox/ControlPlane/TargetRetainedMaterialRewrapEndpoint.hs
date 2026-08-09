{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authority-only Target Agent endpoint for destination sealing retained
-- SES SMTP or ACME EAB custody to one already-attested selected worker.
-- Requests contain only exact source metadata and an ephemeral public key;
-- responses contain only a destination ciphertext envelope and opaque
-- receipts.  No source plaintext, arbitrary Vault path, or generic decrypt
-- operation is representable.
module Prodbox.ControlPlane.TargetRetainedMaterialRewrapEndpoint
  ( TargetRetainedMaterialRewrapRequest (..)
  , TargetRetainedMaterialRewrapResponse (..)
  , TargetRetainedMaterialRewrapBoundary (..)
  , targetRetainedMaterialRewrapMaximumBytes
  , targetRetainedMaterialRewrapResponseMaximumBytes
  , targetRetainedMaterialRewrapAuthenticatedHandler
  )
where

import Codec.Serialise (Serialise)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
  ( AuthenticatedRoleHandler (..)
  )
import Prodbox.ControlPlane.Codec
  ( decodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (TargetRetainedMaterialRewrap)
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetSecretId
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  )

data TargetRetainedMaterialRewrapRequest = TargetRetainedMaterialRewrapRequest
  { targetRetainedRewrapTarget :: !TargetSecretId
  , targetRetainedRewrapOperationId :: !Text
  , targetRetainedRewrapExpectedSourceReceipt :: !Text
  , targetRetainedRewrapExpectedSourceGeneration :: !Natural
  , targetRetainedRewrapExpectedSourceVaultVersion :: !Natural
  , targetRetainedRewrapExpectedSourceDigest :: !Text
  , targetRetainedRewrapTargetGeneration :: !Natural
  , targetRetainedRewrapAttestationRef :: !Text
  , targetRetainedRewrapDestinationPublicKey :: !ByteString
  , targetRetainedRewrapDeadlineMicros :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TargetRetainedMaterialRewrapResponse
  = TargetRetainedMaterialRewrapped
      { targetRetainedRewrapEnvelope :: !ByteString
      , targetRetainedRewrapReceiptRef :: !Text
      , targetRetainedRewrapEnvelopeDigest :: !Text
      }
  | TargetRetainedMaterialRewrapRefused !Text
  | TargetRetainedMaterialRewrapUnavailable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

newtype TargetRetainedMaterialRewrapBoundary m
  = TargetRetainedMaterialRewrapBoundary
  { runTargetRetainedMaterialRewrap
      :: AuthorityTime
      -> TargetRetainedMaterialRewrapRequest
      -> m TargetRetainedMaterialRewrapResponse
  }

targetRetainedMaterialRewrapMaximumBytes :: Int
targetRetainedMaterialRewrapMaximumBytes = 32 * 1024

targetRetainedMaterialRewrapResponseMaximumBytes :: Int
targetRetainedMaterialRewrapResponseMaximumBytes = 96 * 1024

targetRetainedMaterialRewrapAuthenticatedHandler
  :: (Monad m)
  => Int
  -> m (Either Text AuthorityTime)
  -> TargetRetainedMaterialRewrapBoundary m
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
targetRetainedMaterialRewrapAuthenticatedHandler maximumBytes observeNow boundary inner =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness = authenticatedHandlerReadiness inner
    , authenticatedHandlerHandle = handle
    }
 where
  handle caller route body = case route of
    TargetRetainedMaterialRewrap -> do
      response <- case decodeControlPlaneRequest maximumBytes (LazyByteString.fromStrict body) of
        Left _ -> pure (refused "request-codec-rejected")
        Right request -> do
          nowResult <- observeNow
          case nowResult of
            Left _ -> pure (unavailable "authority-clock-unavailable")
            Right now -> runTargetRetainedMaterialRewrap boundary now request
      pure (Just (responseStatus response, responseBody response))
    _ -> authenticatedHandlerHandle inner caller route body

responseStatus :: TargetRetainedMaterialRewrapResponse -> Int
responseStatus response = case response of
  TargetRetainedMaterialRewrapped {} -> 200
  TargetRetainedMaterialRewrapRefused _ -> 409
  TargetRetainedMaterialRewrapUnavailable _ -> 503

responseBody :: (Serialise value) => value -> ByteString
responseBody = LazyByteString.toStrict . encodeControlPlaneResponse

refused :: Text -> TargetRetainedMaterialRewrapResponse
refused = TargetRetainedMaterialRewrapRefused

unavailable :: Text -> TargetRetainedMaterialRewrapResponse
unavailable = TargetRetainedMaterialRewrapUnavailable
