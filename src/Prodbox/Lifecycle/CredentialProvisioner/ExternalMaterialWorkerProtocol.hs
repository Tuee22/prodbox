{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The only secret-bearing wire format in the external-material flow.
--
-- This frame is written by the host directly to the already attested,
-- one-shot credential-provisioner Pod's stdin.  It is deliberately not a
-- control-plane request and its constructors and secret fields are private.
module Prodbox.Lifecycle.CredentialProvisioner.ExternalMaterialWorkerProtocol
  ( ExternalMaterialWorkerIngressError (..)
  , externalMaterialWorkerIngressMaximumBytes
  , encodeExternalMaterialWorkerIngress
  , withExternalMaterialWorkerIngress
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Word (Word16)
import GHC.Generics (Generic)
import Prodbox.Lifecycle.CredentialProvisioner.Execution
  ( OperatorMaterialIngressFrame
  , withExternalAcmeEabIngressFrame
  )
import Prodbox.Lifecycle.CredentialProvisioner.ExternalIngress
  ( SignedExternalAcmeEabPermit
  , decodeSignedExternalAcmeEabPermit
  )
import Prodbox.Lifecycle.CredentialProvisioner.Kubernetes
  ( CredentialProvisionerPodUid
  , credentialProvisionerPodUidText
  , mkCredentialProvisionerPodUid
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( OperatorMaterialIngressSchema (ExternalAcmeEabIngress)
  )

data WireExternalMaterialWorkerIngress = WireExternalMaterialWorkerIngress
  { wireExternalWorkerVersion :: !Word16
  , wireExternalWorkerPodUid :: !Text
  , wireExternalWorkerPermit :: !ByteString
  , wireExternalWorkerPayload :: !ByteString
  }
  deriving stock (Generic)
  deriving anyclass (Serialise)

data ExternalMaterialWorkerIngressError
  = ExternalMaterialWorkerIngressTooLarge !Int !Int
  | ExternalMaterialWorkerIngressDecodeFailed
  | ExternalMaterialWorkerIngressUnsupportedVersion !Word16
  | ExternalMaterialWorkerIngressNonCanonical
  | ExternalMaterialWorkerIngressPodUidInvalid
  | ExternalMaterialWorkerIngressPermitInvalid
  | ExternalMaterialWorkerIngressPayloadInvalid
  deriving stock (Eq, Show)

externalMaterialWorkerIngressMaximumBytes :: Int
externalMaterialWorkerIngressMaximumBytes = 64 * 1024

externalMaterialWorkerIngressVersion :: Word16
externalMaterialWorkerIngressVersion = 1

encodeExternalMaterialWorkerIngress
  :: CredentialProvisionerPodUid
  -> ByteString
  -> ByteString
  -> Either ExternalMaterialWorkerIngressError ByteString
encodeExternalMaterialWorkerIngress podUid permit payload = do
  -- Validate both nested canonical frames before constructing the one value
  -- Kubernetes is allowed to carry on stdin.
  _ <-
    either
      (const (Left ExternalMaterialWorkerIngressPermitInvalid))
      Right
      (decodeSignedExternalAcmeEabPermit permit)
  _ <-
    either
      (const (Left ExternalMaterialWorkerIngressPayloadInvalid))
      Right
      (withExternalAcmeEabIngressFrame payload (const ()))
  let encoded =
        LazyByteString.toStrict
          ( serialise
              WireExternalMaterialWorkerIngress
                { wireExternalWorkerVersion = externalMaterialWorkerIngressVersion
                , wireExternalWorkerPodUid = credentialProvisionerPodUidText podUid
                , wireExternalWorkerPermit = permit
                , wireExternalWorkerPayload = payload
                }
          )
  if ByteString.length encoded > externalMaterialWorkerIngressMaximumBytes
    then
      Left
        ( ExternalMaterialWorkerIngressTooLarge
            (ByteString.length encoded)
            externalMaterialWorkerIngressMaximumBytes
        )
    else Right encoded

-- | Decode within a continuation so neither the raw secret fields nor their
-- enclosing DTO can escape as a serializable controller request.
withExternalMaterialWorkerIngress
  :: ByteString
  -> ( CredentialProvisionerPodUid
       -> SignedExternalAcmeEabPermit
       -> OperatorMaterialIngressFrame 'ExternalAcmeEabIngress
       -> result
     )
  -> Either ExternalMaterialWorkerIngressError result
withExternalMaterialWorkerIngress bytes consume
  | ByteString.length bytes > externalMaterialWorkerIngressMaximumBytes =
      Left
        ( ExternalMaterialWorkerIngressTooLarge
            (ByteString.length bytes)
            externalMaterialWorkerIngressMaximumBytes
        )
  | otherwise = do
      wire <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
        Left _ -> Left ExternalMaterialWorkerIngressDecodeFailed
        Right decoded -> Right decoded
      if wireExternalWorkerVersion wire == externalMaterialWorkerIngressVersion
        then Right ()
        else
          Left
            ( ExternalMaterialWorkerIngressUnsupportedVersion
                (wireExternalWorkerVersion wire)
            )
      if LazyByteString.toStrict (serialise wire) == bytes
        then Right ()
        else Left ExternalMaterialWorkerIngressNonCanonical
      podUid <-
        either
          (const (Left ExternalMaterialWorkerIngressPodUidInvalid))
          Right
          (mkCredentialProvisionerPodUid (wireExternalWorkerPodUid wire))
      permit <-
        either
          (const (Left ExternalMaterialWorkerIngressPermitInvalid))
          Right
          (decodeSignedExternalAcmeEabPermit (wireExternalWorkerPermit wire))
      either
        (const (Left ExternalMaterialWorkerIngressPayloadInvalid))
        Right
        ( withExternalAcmeEabIngressFrame
            (wireExternalWorkerPayload wire)
            (consume podUid permit)
        )
