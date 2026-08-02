{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

-- | The AWS-admin Credential Provisioner's sole secret-bearing transport.
-- The host writes one canonical bounded frame directly to the already
-- attested Pod's stdin.  Secret fields and the wire DTO are continuation-
-- scoped and cannot escape into Authority state or a control-plane request.
module Prodbox.Lifecycle.CredentialProvisioner.AwsAdminWorkerProtocol
  ( AwsAdminWorkerIngressError (..)
  , awsAdminWorkerIngressMaximumBytes
  , encodeAwsAdminWorkerIngress
  , withAwsAdminWorkerIngress
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
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( SignedAwsAdminPermit
  , awsAdminJobPodName
  , awsAdminJobPodUid
  , decodeSignedAwsAdminPermit
  , encodeSignedAwsAdminPermit
  , signedAwsAdminPermitBinding
  , withSomeSignedAwsAdminPermit
  )
import Prodbox.Settings (Credentials (..))

data WireAwsAdminWorkerIngress = WireAwsAdminWorkerIngress
  { wireAwsAdminWorkerVersion :: !Word16
  , wireAwsAdminWorkerPodName :: !Text
  , wireAwsAdminWorkerPodUid :: !Text
  , wireAwsAdminWorkerPermit :: !ByteString
  , wireAwsAdminWorkerAccessKeyId :: !Text
  , wireAwsAdminWorkerSecretAccessKey :: !Text
  , wireAwsAdminWorkerSessionToken :: !(Maybe Text)
  , wireAwsAdminWorkerRegion :: !Text
  }
  deriving stock (Generic)
  deriving anyclass (Serialise)

data AwsAdminWorkerIngressError
  = AwsAdminWorkerIngressTooLarge !Int !Int
  | AwsAdminWorkerIngressDecodeFailed
  | AwsAdminWorkerIngressUnsupportedVersion !Word16
  | AwsAdminWorkerIngressNonCanonical
  | AwsAdminWorkerIngressPermitInvalid
  | AwsAdminWorkerIngressPodBindingMismatch
  | AwsAdminWorkerIngressCredentialsInvalid
  deriving stock (Eq, Show)

awsAdminWorkerIngressMaximumBytes :: Int
awsAdminWorkerIngressMaximumBytes = 64 * 1024

awsAdminWorkerIngressVersion :: Word16
awsAdminWorkerIngressVersion = 1

encodeAwsAdminWorkerIngress
  :: SignedAwsAdminPermit
  -> Credentials
  -> Either AwsAdminWorkerIngressError ByteString
encodeAwsAdminWorkerIngress permit rawCredentials = do
  canonicalPermit <-
    either
      (const (Left AwsAdminWorkerIngressPermitInvalid))
      Right
      (decodeSignedAwsAdminPermit (encodeSignedAwsAdminPermit permit))
  credentials <-
    either
      (const (Left AwsAdminWorkerIngressCredentialsInvalid))
      Right
      (validateAdminCredentials rawCredentials)
  withSomeSignedAwsAdminPermit canonicalPermit $ \validatedPermit ->
    let binding = signedAwsAdminPermitBinding validatedPermit
        encoded =
          LazyByteString.toStrict
            ( serialise
                WireAwsAdminWorkerIngress
                  { wireAwsAdminWorkerVersion = awsAdminWorkerIngressVersion
                  , wireAwsAdminWorkerPodName = awsAdminJobPodName binding
                  , wireAwsAdminWorkerPodUid = awsAdminJobPodUid binding
                  , wireAwsAdminWorkerPermit = encodeSignedAwsAdminPermit validatedPermit
                  , wireAwsAdminWorkerAccessKeyId = access_key_id credentials
                  , wireAwsAdminWorkerSecretAccessKey = secret_access_key credentials
                  , wireAwsAdminWorkerSessionToken = session_token credentials
                  , wireAwsAdminWorkerRegion = region credentials
                  }
            )
     in if ByteString.length encoded > awsAdminWorkerIngressMaximumBytes
          then
            Left
              ( AwsAdminWorkerIngressTooLarge
                  (ByteString.length encoded)
                  awsAdminWorkerIngressMaximumBytes
              )
          else Right encoded

withAwsAdminWorkerIngress
  :: ByteString
  -> (SignedAwsAdminPermit -> Credentials -> result)
  -> Either AwsAdminWorkerIngressError result
withAwsAdminWorkerIngress bytes consume
  | ByteString.length bytes > awsAdminWorkerIngressMaximumBytes =
      Left
        ( AwsAdminWorkerIngressTooLarge
            (ByteString.length bytes)
            awsAdminWorkerIngressMaximumBytes
        )
  | otherwise = do
      wire <- case deserialiseOrFail (LazyByteString.fromStrict bytes) of
        Left _ -> Left AwsAdminWorkerIngressDecodeFailed
        Right value -> Right value
      if wireAwsAdminWorkerVersion wire == awsAdminWorkerIngressVersion
        then Right ()
        else
          Left
            ( AwsAdminWorkerIngressUnsupportedVersion
                (wireAwsAdminWorkerVersion wire)
            )
      if LazyByteString.toStrict (serialise wire) == bytes
        then Right ()
        else Left AwsAdminWorkerIngressNonCanonical
      somePermit <-
        either
          (const (Left AwsAdminWorkerIngressPermitInvalid))
          Right
          (decodeSignedAwsAdminPermit (wireAwsAdminWorkerPermit wire))
      withSomeSignedAwsAdminPermit somePermit $ \permit -> do
        let binding = signedAwsAdminPermitBinding permit
        if wireAwsAdminWorkerPodName wire == awsAdminJobPodName binding
          && wireAwsAdminWorkerPodUid wire == awsAdminJobPodUid binding
          then Right ()
          else Left AwsAdminWorkerIngressPodBindingMismatch
        credentials <-
          either
            (const (Left AwsAdminWorkerIngressCredentialsInvalid))
            Right
            ( validateAdminCredentials
                Credentials
                  { access_key_id = wireAwsAdminWorkerAccessKeyId wire
                  , secret_access_key = wireAwsAdminWorkerSecretAccessKey wire
                  , session_token = wireAwsAdminWorkerSessionToken wire
                  , region = wireAwsAdminWorkerRegion wire
                  }
            )
        pure (consume permit credentials)
