{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

-- | The Admin Action Runner's only secret-bearing wire format.
--
-- The coordinator writes this canonical frame directly to the stdin of the
-- already attested, one-shot runner Pod.  The constructor and credential
-- fields stay private, and decoding is continuation-scoped so the transport
-- DTO itself cannot escape into a control-plane request or retained state.
module Prodbox.Lifecycle.AdminAction.WorkerProtocol
  ( AdminActionWorkerIngressError (..)
  , adminActionWorkerIngressMaximumBytes
  , encodeAdminActionWorkerIngress
  , withAdminActionWorkerIngress
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Word (Word16)
import GHC.Generics (Generic)
import Prodbox.Aws.AdminCredentials (validateAdminCredentials)
import Prodbox.Lifecycle.AdminAction.Protocol
  ( SignedAdminActionPermit
  , adminActionJobPodName
  , adminActionJobPodUid
  , decodeSignedAdminActionPermit
  , encodeSignedAdminActionPermit
  , signedAdminActionPermitBinding
  )
import Prodbox.Settings (Credentials (..))

data WireAdminActionWorkerIngress = WireAdminActionWorkerIngress
  { wireAdminActionWorkerVersion :: !Word16
  , wireAdminActionWorkerPodName :: !Text
  , wireAdminActionWorkerPodUid :: !Text
  , wireAdminActionWorkerPermit :: !ByteString
  , wireAdminActionWorkerAccessKeyId :: !Text
  , wireAdminActionWorkerSecretAccessKey :: !Text
  , wireAdminActionWorkerSessionToken :: !(Maybe Text)
  , wireAdminActionWorkerRegion :: !Text
  }
  deriving stock (Generic)
  deriving anyclass (Serialise)

data AdminActionWorkerIngressError
  = AdminActionWorkerIngressTooLarge !Int !Int
  | AdminActionWorkerIngressDecodeFailed
  | AdminActionWorkerIngressUnsupportedVersion !Word16
  | AdminActionWorkerIngressNonCanonical
  | AdminActionWorkerIngressPermitInvalid
  | AdminActionWorkerIngressPodBindingMismatch
  | AdminActionWorkerIngressCredentialsInvalid
  deriving stock (Eq, Show)

adminActionWorkerIngressMaximumBytes :: Int
adminActionWorkerIngressMaximumBytes = 64 * 1024

adminActionWorkerIngressVersion :: Word16
adminActionWorkerIngressVersion = 1

encodeAdminActionWorkerIngress
  :: SignedAdminActionPermit
  -> Credentials
  -> Either AdminActionWorkerIngressError ByteString
encodeAdminActionWorkerIngress permit rawCredentials = do
  -- Round-trip through the public canonical decoder before admitting a nested
  -- permit.  This prevents a locally constructed, invalid value from crossing
  -- the one secret-bearing transport boundary.
  canonicalPermit <-
    either
      (const (Left AdminActionWorkerIngressPermitInvalid))
      Right
      (decodeSignedAdminActionPermit (encodeSignedAdminActionPermit permit))
  credentials <-
    either
      (const (Left AdminActionWorkerIngressCredentialsInvalid))
      Right
      (validateAdminCredentials rawCredentials)
  let binding = signedAdminActionPermitBinding canonicalPermit
      encoded =
        LazyByteString.toStrict
          ( serialise
              WireAdminActionWorkerIngress
                { wireAdminActionWorkerVersion = adminActionWorkerIngressVersion
                , wireAdminActionWorkerPodName = adminActionJobPodName binding
                , wireAdminActionWorkerPodUid = adminActionJobPodUid binding
                , wireAdminActionWorkerPermit = encodeSignedAdminActionPermit canonicalPermit
                , wireAdminActionWorkerAccessKeyId = access_key_id credentials
                , wireAdminActionWorkerSecretAccessKey = secret_access_key credentials
                , wireAdminActionWorkerSessionToken = session_token credentials
                , wireAdminActionWorkerRegion = region credentials
                }
          )
  if ByteString.length encoded > adminActionWorkerIngressMaximumBytes
    then
      Left
        ( AdminActionWorkerIngressTooLarge
            (ByteString.length encoded)
            adminActionWorkerIngressMaximumBytes
        )
    else Right encoded

-- | Decode an ingress frame within a continuation.  Only the validated signed
-- permit and normalized credential are exposed; the serializable secret DTO is
-- never returned.
withAdminActionWorkerIngress
  :: ByteString
  -> (SignedAdminActionPermit -> Credentials -> result)
  -> Either AdminActionWorkerIngressError result
withAdminActionWorkerIngress bytes consume
  | ByteString.length bytes > adminActionWorkerIngressMaximumBytes =
      Left
        ( AdminActionWorkerIngressTooLarge
            (ByteString.length bytes)
            adminActionWorkerIngressMaximumBytes
        )
  | otherwise = do
      wire <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
        Left _ -> Left AdminActionWorkerIngressDecodeFailed
        Right decoded -> Right decoded
      if wireAdminActionWorkerVersion wire == adminActionWorkerIngressVersion
        then Right ()
        else
          Left
            ( AdminActionWorkerIngressUnsupportedVersion
                (wireAdminActionWorkerVersion wire)
            )
      if LazyByteString.toStrict (serialise wire) == bytes
        then Right ()
        else Left AdminActionWorkerIngressNonCanonical
      permit <-
        either
          (const (Left AdminActionWorkerIngressPermitInvalid))
          Right
          (decodeSignedAdminActionPermit (wireAdminActionWorkerPermit wire))
      let binding = signedAdminActionPermitBinding permit
      if wireAdminActionWorkerPodName wire == adminActionJobPodName binding
        && wireAdminActionWorkerPodUid wire == adminActionJobPodUid binding
        then Right ()
        else Left AdminActionWorkerIngressPodBindingMismatch
      credentials <-
        either
          (const (Left AdminActionWorkerIngressCredentialsInvalid))
          Right
          ( validateAdminCredentials
              Credentials
                { access_key_id = wireAdminActionWorkerAccessKeyId wire
                , secret_access_key = wireAdminActionWorkerSecretAccessKey wire
                , session_token = wireAdminActionWorkerSessionToken wire
                , region = wireAdminActionWorkerRegion wire
                }
          )
      pure (consume permit credentials)
