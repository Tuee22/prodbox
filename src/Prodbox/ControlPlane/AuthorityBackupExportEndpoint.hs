{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Narrow Lifecycle Authority export of the exact retained aggregate for
-- genesis/repair backup. The request is purpose-bound to the retained
-- admission state; callers cannot select an object coordinate or arbitrary
-- primary-store value.
module Prodbox.ControlPlane.AuthorityBackupExportEndpoint
  ( AuthorityBackupExportPurpose (..)
  , AuthorityBackupExportRequest (..)
  , AuthorityBackupExportResponse (..)
  , AuthorityBackupExportResult (..)
  , authorityBackupExportMaximumResponseBytes
  , serveAuthorityBackupExportRequest
  , authorityBackupExportHttpStatus
  , authorityBackupExportResponseBody
  )
where

import Codec.Serialise (Serialise)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Numeric (showHex)
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (readAuthorityAdmission)
  , AuthorityAdmissionSnapshot (authorityAdmissionSnapshotState)
  )
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError
  , decodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionAggregate
  , authorityAggregateAdmission
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityAdmissionState (..)
  , BackupRepairPermit (backupRepairPermitDigest)
  , BackupRepairProgress (backupRepairPermit)
  , GenesisPlan (genesisPlanDigest)
  , GenesisProgress (genesisProgressPlan)
  )

data AuthorityBackupExportPurpose
  = ExportGenesisAggregate !Text
  | ExportRepairAggregate !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

newtype AuthorityBackupExportRequest = AuthorityBackupExportRequest
  { authorityBackupExportPurpose :: AuthorityBackupExportPurpose
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AuthorityBackupExportResponse = AuthorityBackupExportResponse
  { authorityBackupExportEnvelope :: !ByteString
  , authorityBackupExportDigest :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data AuthorityBackupExportResult
  = AuthorityBackupExported !AuthorityBackupExportResponse
  | AuthorityBackupExportReadFailed !Text
  | AuthorityBackupExportEncodeFailed !Text
  | AuthorityBackupExportPurposeMismatch
  | AuthorityBackupExportBadRequest !ControlPlaneRequestCodecError
  deriving stock (Eq, Show)

authorityBackupExportMaximumResponseBytes :: Int
authorityBackupExportMaximumResponseBytes = 1024 * 1024

serveAuthorityBackupExportRequest
  :: (Monad m)
  => Int
  -> (AuthorityAdmissionAggregate -> Either Text ByteString)
  -> AuthorityAdmissionRepository m revision
  -> ByteString
  -> m AuthorityBackupExportResult
serveAuthorityBackupExportRequest maximumRequestBytes encodeAggregate repository body =
  case decodeControlPlaneRequest maximumRequestBytes (LazyByteString.fromStrict body) of
    Left err -> pure (AuthorityBackupExportBadRequest err)
    Right request -> do
      observed <- readAuthorityAdmission repository
      pure $ case observed of
        Left detail -> AuthorityBackupExportReadFailed detail
        Right snapshot ->
          let aggregate = authorityAdmissionSnapshotState snapshot
           in if purposeMatches
                (authorityBackupExportPurpose request)
                (authorityAggregateAdmission aggregate)
                then case encodeAggregate aggregate of
                  Left detail -> AuthorityBackupExportEncodeFailed detail
                  Right envelope
                    | ByteString.null envelope
                        || ByteString.length envelope
                          > authorityBackupExportMaximumResponseBytes ->
                        AuthorityBackupExportEncodeFailed "aggregate envelope size is invalid"
                    | otherwise ->
                        AuthorityBackupExported
                          AuthorityBackupExportResponse
                            { authorityBackupExportEnvelope = envelope
                            , authorityBackupExportDigest = digestBytes envelope
                            }
                else AuthorityBackupExportPurposeMismatch

purposeMatches :: AuthorityBackupExportPurpose -> AuthorityAdmissionState -> Bool
purposeMatches purpose state = case (purpose, state) of
  (ExportGenesisAggregate expected, EstablishingBackup progress) ->
    expected == genesisPlanDigest (genesisProgressPlan progress)
  (ExportRepairAggregate expected, BackupRepairFrozen _ progress) ->
    maybe False ((== expected) . backupRepairPermitDigest) (backupRepairPermit progress)
  _ -> False

authorityBackupExportHttpStatus :: AuthorityBackupExportResult -> ReplyStatus
authorityBackupExportHttpStatus result = case result of
  AuthorityBackupExported _ -> ReplyOk
  AuthorityBackupExportPurposeMismatch -> ReplyConflict
  AuthorityBackupExportBadRequest _ -> ReplyBadRequest
  AuthorityBackupExportReadFailed _ -> ReplyServiceUnavailable
  AuthorityBackupExportEncodeFailed _ -> ReplyInternalError

authorityBackupExportResponseBody :: AuthorityBackupExportResult -> ByteString
authorityBackupExportResponseBody result =
  LazyByteString.toStrict
    ( encodeControlPlaneResponse $ case result of
        AuthorityBackupExported response -> Right response
        AuthorityBackupExportPurposeMismatch -> Left ("purpose-mismatch" :: Text)
        AuthorityBackupExportBadRequest _ -> Left ("bad-request" :: Text)
        AuthorityBackupExportReadFailed _ -> Left ("read-failed" :: Text)
        AuthorityBackupExportEncodeFailed _ -> Left ("encode-failed" :: Text)
    )

digestBytes :: ByteString -> Text
digestBytes = Text.pack . concatMap byteHex . ByteString.unpack . SHA256.hash
 where
  byteHex byte =
    let rendered = showHex byte ""
     in if length rendered == 1 then '0' : rendered else rendered
