{-# LANGUAGE BangPatterns #-}
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
  , InspectedRpcBirthSettings
  , inspectRpcBirthControllerSettings
  , inspectRpcBirthControllerSettingsWithin
  , rpcBirthSettingsShapeDataBytes
  , inspectedRpcBirthSettingsUsage
  , inspectedRpcBirthSettingsDataBytes
  , decodeInspectedRpcBirthControllerSettings
  , ExtractedRpcBirthSettings
  , extractRpcBirthSettingsData
  , extractedRpcBirthSettingsNormalFormBytes
  , extractedRpcBirthSettingsConfig
  , rpcBirthSettingsExtractedDataBytes
  , rpcBirthSettingsGenericProductDataBytes
  , rpcBirthSettingsGenericSumDataBytes
  , rpcBirthSettingsMaximumConstructorFields
  , prepareExtractedRpcBirthSettingsEncoding
  , embedExtractedRpcBirthSettingsData
  ) where

import Codec.Serialise (encode)
import Control.Monad (unless, when)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Maybe (maybeToList)
import Data.Proxy (Proxy (..))
import Data.Void (Void)
import Dhall qualified
import Dhall.Core qualified as Core
import Numeric.Natural (Natural)
import Prodbox.Capacity.BoxedNormalForm (boxedRecordBytes)
import Prodbox.Capacity.SettingsExtractedData
  ( settingsExtractedDataBytes
  , settingsExtractedMaximumConstructorFields
  , settingsExtractionGenericProductDataBytes
  , settingsExtractionGenericSumDataBytes
  )
import Prodbox.Capacity.SettingsNormalForm (rpcSettingsEnvelopeRawNormalFormBytes)
import Prodbox.Config.CanonicalDhallDataEncoding
import Prodbox.Config.CanonicalDhallDataSyntax
import Prodbox.Config.CanonicalDhallValueShape
import Prodbox.Config.CheckedCanonicalDhallData
import Prodbox.ControlPlane.Coordinate (AuthorityScope, authorityScopeText)
import Prodbox.ControlPlane.RpcBirthSettingsCodec
import Prodbox.ControlPlane.RpcBirthSettingsEnvelope (SettingsEnvelope (..))
import Prodbox.ControlPlane.RpcBirthSettingsShape (rpcBirthSettingsShapeTemplate)
import Prodbox.Settings qualified as Settings
import Prodbox.Settings.SecretRef (secretRefIsPlaintext)
import System.FilePath (isAbsolute, normalise, splitDirectories)

newtype RpcBirthSettingsBytes = RpcBirthSettingsBytes ByteString

-- The exact source and its checked operand are created together. This has no
-- Show/serialization and supplies no compact-backing or admission capability.
data InspectedRpcBirthSettings = Inspected !ByteString !CheckedCanonicalDhallData

inspectRpcBirthControllerSettings
  :: ByteString -> Either RpcBirthSettingsPayloadError InspectedRpcBirthSettings
inspectRpcBirthControllerSettings bytes = do
  checkSize bytes
  inspectWithShape (materializeStaticShapeTemplate rpcBirthSettingsShapeTemplate) bytes

-- A deny-only constructor-data check, independent of the metadata graph.
-- The input owner still funds inspection, retained roots, GC and native work.
inspectRpcBirthControllerSettingsWithin
  :: Natural -> ByteString -> Either RpcBirthSettingsPayloadError InspectedRpcBirthSettings
inspectRpcBirthControllerSettingsWithin available bytes = do
  checkSize bytes
  shape <-
    first
      preparationError
      (materializeStaticShapeTemplateWithin available rpcBirthSettingsShapeTemplate)
  inspectWithShape shape bytes

rpcBirthSettingsShapeDataBytes :: Natural
rpcBirthSettingsShapeDataBytes = staticShapeTemplateDataBytes rpcBirthSettingsShapeTemplate

preparationError :: StaticShapeTemplateError -> RpcBirthSettingsPayloadError
preparationError cause = case cause of
  StaticShapeDataUnderfunded required available -> RpcBirthSettingsPreparationUnderfunded required available
  StaticShapeSchemaRefused _ -> RpcBirthSettingsShapeInvalid
  StaticShapeDataExceedsAddressSpace -> RpcBirthSettingsShapeInvalid

inspectWithShape
  :: CanonicalDhallValueShape
  -> ByteString
  -> Either RpcBirthSettingsPayloadError InspectedRpcBirthSettings
inspectWithShape shape bytes = do
  checked <- first shapeError (inspectCanonicalDhallData shape bytes)
  pure (Inspected bytes checked)

inspectedRpcBirthSettingsUsage :: InspectedRpcBirthSettings -> CanonicalDhallValueUsage
inspectedRpcBirthSettingsUsage (Inspected _ checked) = checkedCanonicalDhallDataUsage checked

-- Both wrappers reference the same captured source. Its buffer is charged by
-- the input owner; these data terms include the checked usage graph once.
inspectedRpcBirthSettingsDataBytes :: InspectedRpcBirthSettings -> Natural
inspectedRpcBirthSettingsDataBytes inspected =
  boxedRecordBytes
    [ 0
    , boxedRecordBytes [0, canonicalDhallUsageNormalFormBytes (inspectedRpcBirthSettingsUsage inspected)]
    ]

rpcBirthSettingsBytes :: RpcBirthSettingsBytes -> ByteString
rpcBirthSettingsBytes (RpcBirthSettingsBytes bytes) = bytes

data RpcBirthSettingsPayloadError
  = RpcBirthSettingsInputTooLarge
  | RpcBirthSettingsEncodingInvalid
  | RpcBirthSettingsShapeInvalid
  | RpcBirthSettingsPreparationUnderfunded !Natural !Natural
  | RpcBirthSettingsSchemaUnsupported
  | RpcBirthSettingsNonCanonical
  | RpcBirthSettingsPlaintextRef
  | RpcBirthSettingsScopeMismatch
  | RpcBirthSettingsRootInvalid
  | RpcBirthSettingsValidationRefused
  deriving (Eq, Show)

rpcBirthSettingsExtractedDataBytes :: CanonicalDhallValueUsage -> Natural
rpcBirthSettingsExtractedDataBytes = settingsExtractedDataBytes (Proxy @SettingsEnvelope)

rpcBirthSettingsGenericProductDataBytes :: CanonicalDhallValueUsage -> Natural
rpcBirthSettingsGenericProductDataBytes = settingsExtractionGenericProductDataBytes (Proxy @SettingsEnvelope)

rpcBirthSettingsGenericSumDataBytes :: CanonicalDhallValueUsage -> Natural
rpcBirthSettingsGenericSumDataBytes = settingsExtractionGenericSumDataBytes (Proxy @SettingsEnvelope)

rpcBirthSettingsMaximumConstructorFields :: Natural
rpcBirthSettingsMaximumConstructorFields = settingsExtractedMaximumConstructorFields (Proxy @SettingsEnvelope)

-- No Show or serialization: this raw data may contain future credential
-- references. The strict structural projection completes evaluation before
-- readback, so extractor selectors cannot escape into semantic validation.
data ExtractedRpcBirthSettings = Extracted !SettingsEnvelope !Natural

extractRpcBirthSettingsData
  :: Core.Expr Void Void -> Either RpcBirthSettingsPayloadError ExtractedRpcBirthSettings
extractRpcBirthSettingsData expression = do
  envelope <-
    first
      (const RpcBirthSettingsShapeInvalid)
      (Dhall.toMonadic (Dhall.extract rpcBirthSettingsDecoder (Core.renote expression)))
  let !bytes =
        rpcSettingsEnvelopeRawNormalFormBytes
          (schema_version envelope)
          (context envelope)
          (parameters envelope)
  pure $! Extracted envelope bytes

extractedRpcBirthSettingsNormalFormBytes :: ExtractedRpcBirthSettings -> Natural
extractedRpcBirthSettingsNormalFormBytes (Extracted _ bytes) = 40 + bytes

extractedRpcBirthSettingsConfig :: ExtractedRpcBirthSettings -> Settings.ConfigFile
extractedRpcBirthSettingsConfig (Extracted envelope _) = parameters envelope

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
  plan <-
    first
      producerEncodingError
      ( prepareSettingsValueEncoding
          (fromIntegral rpcBirthSettingsMaximumBytes)
          (SettingsEnvelope 1 input config)
      )
  bytes <- first producerEncodingError (encodePreparedCanonicalDhallData plan)
  checkSize bytes
  pure (RpcBirthSettingsBytes bytes)

decodeRpcBirthControllerSettings
  :: AuthorityScope
  -> FilePath
  -> ByteString
  -> IO (Either RpcBirthSettingsPayloadError Settings.ValidatedSettings)
decodeRpcBirthControllerSettings scope root bytes =
  case checkSize bytes >> checkRoot root >> inspectRpcBirthControllerSettings bytes of
    Left cause -> pure (Left cause)
    Right inspected -> decodeInspectedRpcBirthControllerSettings scope root inspected

decodeInspectedRpcBirthControllerSettings
  :: AuthorityScope
  -> FilePath
  -> InspectedRpcBirthSettings
  -> IO (Either RpcBirthSettingsPayloadError Settings.ValidatedSettings)
decodeInspectedRpcBirthControllerSettings scope root (Inspected bytes checked) = case decodeEnvelope of
  Left cause -> pure (Left cause)
  Right envelope ->
    first (const RpcBirthSettingsValidationRefused)
      <$> Settings.validateConfigWithContext root (context envelope) (parameters envelope)
 where
  decodeEnvelope = do
    checkRoot root
    expression <-
      first (const RpcBirthSettingsEncodingInvalid) (decodeCheckedCanonicalDhallData checked)
    raw@(Extracted envelope _) <- extractRpcBirthSettingsData expression
    unless (schema_version envelope == 1) (Left RpcBirthSettingsSchemaUnsupported)
    refusePlaintext (parameters envelope)
    -- Re-encode only the extracted typed value. Untrusted syntax is never
    -- normalized or import-resolved.
    plan <-
      first
        (const RpcBirthSettingsNonCanonical)
        (prepareExtractedRpcBirthSettingsEncoding (fromIntegral (BS.length bytes)) raw)
    canonical <- first (const RpcBirthSettingsEncodingInvalid) (encodePreparedCanonicalDhallData plan)
    unless (canonical == bytes) (Left RpcBirthSettingsNonCanonical)
    unless
      (Settings.contextInputClusterId (context envelope) == authorityScopeText scope)
      (Left RpcBirthSettingsScopeMismatch)
    pure envelope

checkRoot :: FilePath -> Either RpcBirthSettingsPayloadError ()
checkRoot root = unless (safeRoot root) (Left RpcBirthSettingsRootInvalid)

shapeError :: CanonicalDhallValueShapeError -> RpcBirthSettingsPayloadError
shapeError cause = case cause of
  CanonicalDhallValueSchemaUnsupported -> RpcBirthSettingsShapeInvalid
  CanonicalDhallValueShapeMismatch -> RpcBirthSettingsShapeInvalid
  CanonicalDhallValueEncodingInvalid -> RpcBirthSettingsEncodingInvalid
  CanonicalDhallValueRequirementMismatch -> RpcBirthSettingsShapeInvalid

prepareExtractedRpcBirthSettingsEncoding
  :: Natural
  -> ExtractedRpcBirthSettings
  -> Either CanonicalDhallDataEncodingError CanonicalDhallDataEncoding
prepareExtractedRpcBirthSettingsEncoding limit raw =
  let embedded = embedExtractedRpcBirthSettingsData raw
      syntax = eraseCanonicalDhallDataSource embedded
   in prepareCanonicalDhallDataEncoding limit (encode (canonicalDhallDataSyntaxExpression syntax))

embedExtractedRpcBirthSettingsData :: ExtractedRpcBirthSettings -> EmbeddedCanonicalDhallData
embedExtractedRpcBirthSettingsData (Extracted envelope _) =
  embedCanonicalDhallDataWith rpcBirthSettingsEncoder envelope

prepareSettingsValueEncoding
  :: Natural -> SettingsEnvelope -> Either CanonicalDhallDataEncodingError CanonicalDhallDataEncoding
-- The general producer keeps its lazy size preflight. Only checked settings
-- readback takes the separately evaluated stages above; arbitrary typed input
-- must still be able to refuse before an oversized producer suffix.
-- Keep the SDK's total source erasure: Encoder returns Expr Src Void, whereas
-- the supported binary instance consumes Expr Void Void. No unsafe cast is
-- introduced, and evaluator/quotation remain absent from this producer.
prepareSettingsValueEncoding limit envelope =
  let expression :: Core.Expr Void Void
      expression = Core.denote (Dhall.embed rpcBirthSettingsEncoder envelope)
   in prepareCanonicalDhallDataEncoding limit (encode expression)

producerEncodingError :: CanonicalDhallDataEncodingError -> RpcBirthSettingsPayloadError
producerEncodingError cause = case cause of
  CanonicalDhallEncodingTooLarge -> RpcBirthSettingsInputTooLarge
  CanonicalDhallEncodingUnsupportedToken -> RpcBirthSettingsEncodingInvalid
  CanonicalDhallEncodingWriterDisagreement -> RpcBirthSettingsEncodingInvalid

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
