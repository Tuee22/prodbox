{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- Versioned import-free settings/context values for the closed controller.
module Prodbox.ControlPlane.RpcAdmissionBirthPayload
  ( RpcBirthSettingsBytes
  , rpcBirthSettingsBytes
  , RpcBirthSettingsPayloadError (..)
  , rpcBirthSettingsMaximumBytes
  , encodeRpcBirthControllerSettings
  , decodeRpcBirthControllerSettings
  ) where

import Control.Monad (unless, when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.Maybe (maybeToList)
import Data.Void (Void)
import Dhall qualified
import Dhall.Binary qualified as Binary
import Dhall.Core qualified as Core
import Dhall.Marshal.Encode (declared)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Config.CanonicalDhallValueShape
import Prodbox.ControlPlane.Coordinate (AuthorityScope, authorityScopeText)
import Prodbox.Settings qualified as Settings
import Prodbox.Settings.SecretRef (secretRefIsPlaintext)
import System.FilePath (isAbsolute, normalise, splitDirectories)

newtype RpcBirthSettingsBytes = RpcBirthSettingsBytes ByteString

rpcBirthSettingsBytes :: RpcBirthSettingsBytes -> ByteString
rpcBirthSettingsBytes (RpcBirthSettingsBytes bytes) = bytes

data RpcBirthSettingsPayloadError
  = RpcBirthSettingsInputTooLarge
  | RpcBirthSettingsEncodingInvalid
  | RpcBirthSettingsShapeInvalid
  | RpcBirthSettingsSchemaUnsupported
  | RpcBirthSettingsNonCanonical
  | RpcBirthSettingsPlaintextRef
  | RpcBirthSettingsScopeMismatch
  | RpcBirthSettingsRootInvalid
  | RpcBirthSettingsValidationRefused
  deriving (Eq, Show)

data SettingsEnvelope = SettingsEnvelope
  { schema_version :: Natural
  , context :: Settings.DeploymentContextInput
  , parameters :: Settings.ConfigFile
  }
  deriving (Generic)
instance Dhall.FromDhall SettingsEnvelope
instance Dhall.ToDhall SettingsEnvelope

rpcBirthSettingsMaximumBytes :: Int
rpcBirthSettingsMaximumBytes = 1048576

encodeRpcBirthControllerSettings
  :: Settings.ValidatedSettings -> Either RpcBirthSettingsPayloadError RpcBirthSettingsBytes
encodeRpcBirthControllerSettings settings = do
  let config = Settings.validatedConfig settings
      selected = Settings.validatedDeploymentContext settings
      input =
        Settings.DeploymentContextInput
          (Settings.deploymentClusterId selected)
          (Settings.deploymentVaultAddress selected)
          (Settings.deploymentMinioEndpoint selected)
          (Settings.deploymentRpcRegistration selected)
  refusePlaintext config
  let bytes =
        Lazy.toStrict
          ( Lazy.take
              (fromIntegral rpcBirthSettingsMaximumBytes + 1)
              (canonicalValue (SettingsEnvelope 1 input config))
          )
  checkSize bytes
  pure (RpcBirthSettingsBytes bytes)

decodeRpcBirthControllerSettings
  :: AuthorityScope
  -> FilePath
  -> ByteString
  -> IO (Either RpcBirthSettingsPayloadError Settings.ValidatedSettings)
decodeRpcBirthControllerSettings scope root bytes = case decode of
  Left cause -> pure (Left cause)
  Right envelope ->
    first (const RpcBirthSettingsValidationRefused)
      <$> Settings.validateConfigWithContext root (context envelope) (parameters envelope)
 where
  decode = do
    checkSize bytes
    unless (safeRoot root) (Left RpcBirthSettingsRootInvalid)
    shape <-
      first
        (const RpcBirthSettingsShapeInvalid)
        (compileCanonicalDhallValueShape (declared (Dhall.inject @SettingsEnvelope)))
    first shapeError (checkCanonicalDhallValueShape shape bytes)
    expression <-
      first
        (const RpcBirthSettingsEncodingInvalid)
        ( Binary.decodeExpression (Lazy.fromStrict bytes)
            :: Either Binary.DecodingFailure (Core.Expr Void Void)
        )
    envelope <-
      first
        (const RpcBirthSettingsShapeInvalid)
        (Dhall.toMonadic (Dhall.extract (Dhall.auto @SettingsEnvelope) (Core.denote expression)))
    unless (schema_version envelope == 1) (Left RpcBirthSettingsSchemaUnsupported)
    refusePlaintext (parameters envelope)
    -- Typed re-encoding rejects ignored fields and legacy shape adaptations.
    -- The untrusted expression itself is never normalized or import-resolved.
    unless (canonicalValue envelope == Lazy.fromStrict bytes) (Left RpcBirthSettingsNonCanonical)
    unless
      (Settings.contextInputClusterId (context envelope) == authorityScopeText scope)
      (Left RpcBirthSettingsScopeMismatch)
    pure envelope

  shapeError cause = case cause of
    CanonicalDhallValueSchemaUnsupported -> RpcBirthSettingsShapeInvalid
    CanonicalDhallValueShapeMismatch -> RpcBirthSettingsShapeInvalid
    CanonicalDhallValueEncodingInvalid -> RpcBirthSettingsEncodingInvalid

canonicalValue :: SettingsEnvelope -> Lazy.ByteString
canonicalValue = Binary.encodeExpression . Core.normalize . Core.denote . Dhall.embed Dhall.inject

checkSize :: ByteString -> Either RpcBirthSettingsPayloadError ()
checkSize bytes = do
  when (BS.length bytes > rpcBirthSettingsMaximumBytes) (Left RpcBirthSettingsInputTooLarge)
  when (BS.null bytes) (Left RpcBirthSettingsEncodingInvalid)

safeRoot :: FilePath -> Bool
safeRoot root =
  length (take 4097 root) <= 4096
    && '\0' `notElem` root
    && isAbsolute root
    && normalise root == root
    && ".." `notElem` splitDirectories root

refusePlaintext :: Settings.ConfigFile -> Either RpcBirthSettingsPayloadError ()
refusePlaintext config =
  if any secretRefIsPlaintext refs then Left RpcBirthSettingsPlaintextRef else Right ()
 where
  aws = Settings.aws config
  acme = Settings.acme config
  refs =
    [Settings.awsCredentialAccessKeyId aws, Settings.awsCredentialSecretAccessKey aws]
      ++ maybeToList (Settings.awsCredentialSessionToken aws)
      ++ maybeToList (Settings.eab_key_id acme)
      ++ maybeToList (Settings.eab_hmac_key acme)
