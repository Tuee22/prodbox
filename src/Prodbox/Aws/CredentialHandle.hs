{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE StandaloneDeriving #-}

-- | Sprint 1.62 deliverable 3 (credential handle): a validated, linear, in-memory
-- AWS credential handle — the ONLY way the native service interpreters obtain
-- credentials.
--
-- Linearity contract: this module holds no module-level mutable reference, no
-- unsafe-IO escape hatch, and defines no @ToJSON@\/@FromJSON@\/@ToDhall@\/
-- @Binary@\/@Serialise@\/@Generic@ instance — the handle cannot be serialized,
-- and its
-- 'Show' redacts every secret, so it cannot round-trip through a log line. The
-- secret bytes exist only as call-stack arguments until 'toSigV4Credentials'
-- feeds the SigV4 signer. There is no exported @CredentialHandle o ->
-- SessionCredentialHandle@ and no @unsafeCoerce@ widening: a base handle becomes
-- a session handle ONLY through a real (or fake) STS round trip
-- (@Prodbox.Aws.Native.Sts@), so base→session is non-convertible by construction.
module Prodbox.Aws.CredentialHandle
  ( CredentialOrigin (..)
  , CredentialHandle
  , BaseCredentialHandle
  , SessionCredentialHandle
  , SecretString (..)
  , unSecret
  , CredentialError (..)
  , mkBaseCredentialHandle
  , mkSessionCredentialHandle
  , baseCredentialHandleFromSettings
  , credentialHandleAccessKeyId
  , credentialHandleRegion
  , credentialHandleSecurityToken
  , toSigV4Credentials
  )
where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BS8
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import Prodbox.Aws.SigV4 (SigV4Credentials (..))
import Prodbox.Settings (Credentials (..))

-- | Nominal tags promoted to a kind (the 'Prodbox.Lifecycle.StoreLifetime'
-- precedent); fully erased at runtime.
data CredentialOrigin = OriginBase | OriginAssumedRole

-- | An abstract validated credential handle indexed by its origin. The data
-- constructor is NOT exported.
newtype CredentialHandle (origin :: CredentialOrigin)
  = UnsafeCredentialHandle ValidatedCredential

type BaseCredentialHandle = CredentialHandle 'OriginBase

type SessionCredentialHandle = CredentialHandle 'OriginAssumedRole

-- | Interior validated fields; NOT exported.
data ValidatedCredential = ValidatedCredential
  { vcAccessKeyId :: !ByteString
  , vcSecretAccessKey :: !SecretString
  , vcSessionToken :: !(Maybe SecretString)
  , vcRegion :: !ByteString
  }
  deriving stock (Eq)

-- | Secret bytes with a redacting 'Show' (the 'Prodbox.Vault.Client.VaultToken'
-- precedent). The constructor is exported so the native STS/IAM decoders can
-- carry a secret without a bespoke type per module; redaction is on display, not
-- on access.
newtype SecretString = SecretString ByteString
  deriving stock (Eq)

instance Show SecretString where
  show _ = "<redacted>"

unSecret :: SecretString -> ByteString
unSecret (SecretString bytes) = bytes

deriving stock instance Eq (CredentialHandle origin)

instance Show (CredentialHandle origin) where
  show (UnsafeCredentialHandle vc) =
    "CredentialHandle {accessKeyId = "
      <> show (vcAccessKeyId vc)
      <> ", secretAccessKey = <redacted>, sessionToken = "
      <> maybe "None" (const "<redacted>") (vcSessionToken vc)
      <> ", region = "
      <> show (vcRegion vc)
      <> "}"

data CredentialError
  = EmptyAccessKeyId
  | EmptySecretAccessKey
  | EmptyRegion
  | BlankSessionToken
  deriving stock (Eq, Show)

-- | Trim leading/trailing whitespace with 'Text.strip' semantics (matching the
-- admin-credentials validator @validateAdminCredentials@).
trimBs :: ByteString -> ByteString
trimBs = encodeUtf8 . Text.strip . decodeUtf8

nonEmpty :: CredentialError -> ByteString -> Either CredentialError ByteString
nonEmpty err bytes
  | BS8.null bytes = Left err
  | otherwise = Right bytes

-- | Build a base handle. Trims and rejects empty access-key-id\/secret\/region;
-- a whitespace-only session token normalizes to 'Nothing'.
mkBaseCredentialHandle
  :: ByteString
  -> ByteString
  -> Maybe ByteString
  -> ByteString
  -> Either CredentialError BaseCredentialHandle
mkBaseCredentialHandle rawAkid rawSecret rawToken rawRegion = do
  akid <- nonEmpty EmptyAccessKeyId (trimBs rawAkid)
  secret <- nonEmpty EmptySecretAccessKey (trimBs rawSecret)
  region <- nonEmpty EmptyRegion (trimBs rawRegion)
  pure
    ( UnsafeCredentialHandle
        ValidatedCredential
          { vcAccessKeyId = akid
          , vcSecretAccessKey = SecretString secret
          , vcSessionToken = normalizedToken
          , vcRegion = region
          }
    )
 where
  normalizedToken = case rawToken of
    Nothing -> Nothing
    Just raw ->
      let trimmed = trimBs raw
       in if BS8.null trimmed then Nothing else Just (SecretString trimmed)

-- | Build a session handle. The ONLY constructor of a session handle; the
-- session token is REQUIRED (non-blank). Callable only from
-- @Prodbox.Aws.Native.Sts@ (a @CheckCode@ owner-allowlist guards this).
mkSessionCredentialHandle
  :: ByteString
  -> ByteString
  -> ByteString
  -> ByteString
  -> Either CredentialError SessionCredentialHandle
mkSessionCredentialHandle rawAkid rawSecret rawToken rawRegion = do
  akid <- nonEmpty EmptyAccessKeyId (trimBs rawAkid)
  secret <- nonEmpty EmptySecretAccessKey (trimBs rawSecret)
  token <- nonEmpty BlankSessionToken (trimBs rawToken)
  region <- nonEmpty EmptyRegion (trimBs rawRegion)
  pure
    ( UnsafeCredentialHandle
        ValidatedCredential
          { vcAccessKeyId = akid
          , vcSecretAccessKey = SecretString secret
          , vcSessionToken = Just (SecretString token)
          , vcRegion = region
          }
    )

baseCredentialHandleFromSettings :: Credentials -> Either CredentialError BaseCredentialHandle
baseCredentialHandleFromSettings creds =
  mkBaseCredentialHandle
    (encodeUtf8 (access_key_id creds))
    (encodeUtf8 (secret_access_key creds))
    (encodeUtf8 <$> session_token creds)
    (encodeUtf8 (region creds))

handleCredential :: CredentialHandle origin -> ValidatedCredential
handleCredential (UnsafeCredentialHandle vc) = vc

credentialHandleAccessKeyId :: CredentialHandle origin -> ByteString
credentialHandleAccessKeyId = vcAccessKeyId . handleCredential

credentialHandleRegion :: CredentialHandle origin -> ByteString
credentialHandleRegion = vcRegion . handleCredential

credentialHandleSecurityToken :: CredentialHandle origin -> Maybe ByteString
credentialHandleSecurityToken = fmap unSecret . vcSessionToken . handleCredential

-- | The SOLE secret egress; consumed only inside @Prodbox.Aws.Native.Wire@'s
-- signer.
toSigV4Credentials :: CredentialHandle origin -> SigV4Credentials
toSigV4Credentials handle =
  SigV4Credentials
    { sigV4AccessKeyId = vcAccessKeyId vc
    , sigV4SecretAccessKey = unSecret (vcSecretAccessKey vc)
    }
 where
  vc = handleCredential handle
