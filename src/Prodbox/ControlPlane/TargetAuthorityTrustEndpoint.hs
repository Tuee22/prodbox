{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated Target Agent endpoint for installing and reading back the
-- public Authority trust record required by one-shot materializers.
module Prodbox.ControlPlane.TargetAuthorityTrustEndpoint
  ( TargetAuthorityTrustRequest (..)
  , TargetAuthorityTrustResponse (..)
  , targetAuthorityTrustResponseMaximumBytes
  , targetAuthorityTrustAuthenticatedHandler
  , classifyTargetAuthorityTrustObservationFailure
  , vaultTargetAuthorityTrustRepository
  )
where

import Codec.Serialise (Serialise)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import GHC.Generics (Generic)
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
  ( AuthenticatedRoleHandler (..)
  )
import Prodbox.ControlPlane.Codec
  ( decodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (TargetSecretTrustInstall)
  )
import Prodbox.ControlPlane.TargetAuthorityTrust
  ( TargetAuthorityTrustInstallError (..)
  , TargetAuthorityTrustInstallResult (..)
  , TargetAuthorityTrustObservation (..)
  , TargetAuthorityTrustObservationCause (..)
  , TargetAuthorityTrustRepository (..)
  , classifyTargetAuthorityTrustRecord
  , installTargetAuthorityTrust
  , renderTargetAuthorityTrustObservationCause
  , targetAuthorityTrustDesiredMatchesLocal
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( TargetAgentIdentity
  , acceptedTargetAuthorityMaximumEncodedBytes
  , acceptedTargetId
  , decodeAcceptedTargetAuthority
  , encodeAcceptedTargetAuthority
  )
import Prodbox.ControlPlane.TargetSecretWorkerRuntime
  ( targetSecretWorkerTrustPath
  )
import Prodbox.Http.Client (HttpError (..))
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Vault.Client
  ( KvV2Cas (KvV2Cas)
  , KvV2VersionedSecret (..)
  , VaultCasOutcome (..)
  , classifyVaultCasOutcome
  , renderVaultCasOutcome
  , vaultKvCasWriteV2
  , vaultKvReadVersionedV2
  )
import Prodbox.Vault.Session
  ( VaultSession
  , VaultSessionError (..)
  , VaultSessionOperationError (..)
  , sessionAddress
  , withSessionToken
  , withSessionTokenDetailed
  )

newtype TargetAuthorityTrustRequest = TargetAuthorityTrustRequest
  { targetAuthorityTrustAcceptedBytes :: ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TargetAuthorityTrustResponse
  = TargetAuthorityTrustInstalledResponse !ByteString
  | TargetAuthorityTrustAlreadyInstalledResponse !ByteString
  | TargetAuthorityTrustRecoveredResponse !ByteString
  | TargetAuthorityTrustRefusedResponse !Text
  | TargetAuthorityTrustUnavailableResponse !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

targetAuthorityTrustResponseMaximumBytes :: Int
targetAuthorityTrustResponseMaximumBytes = 16 * 1024

targetAuthorityTrustAuthenticatedHandler
  :: (Monad m)
  => Int
  -> TargetAuthorityTrustRepository m
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
targetAuthorityTrustAuthenticatedHandler maximumBytes repository inner =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness = authenticatedHandlerReadiness inner
    , authenticatedHandlerHandle = handle
    }
 where
  handle caller route body = case route of
    TargetSecretTrustInstall -> do
      response <- case decodeControlPlaneRequest maximumBytes (LazyByteString.fromStrict body) of
        Left _ -> pure (TargetAuthorityTrustRefusedResponse "request-codec-rejected")
        Right request -> case decodeAcceptedTargetAuthority
          acceptedTargetAuthorityMaximumEncodedBytes
          (targetAuthorityTrustAcceptedBytes request) of
          Left _ -> pure (TargetAuthorityTrustRefusedResponse "accepted-authority-invalid")
          Right accepted ->
            responseFromInstall
              <$> installTargetAuthorityTrust repository accepted
      pure (Just (responseStatus response, responseBody response))
    _ -> authenticatedHandlerHandle inner caller route body

responseFromInstall
  :: Either TargetAuthorityTrustInstallError TargetAuthorityTrustInstallResult
  -> TargetAuthorityTrustResponse
responseFromInstall result = case result of
  Right installed -> case installed of
    TargetAuthorityTrustInstalled accepted ->
      TargetAuthorityTrustInstalledResponse (encodeAcceptedTargetAuthority accepted)
    TargetAuthorityTrustAlreadyInstalled accepted ->
      TargetAuthorityTrustAlreadyInstalledResponse (encodeAcceptedTargetAuthority accepted)
    TargetAuthorityTrustRecovered accepted ->
      TargetAuthorityTrustRecoveredResponse (encodeAcceptedTargetAuthority accepted)
  Left err -> case err of
    TargetAuthorityTrustObservationUnavailable cause ->
      TargetAuthorityTrustUnavailableResponse
        ( "trust-observation-unavailable/"
            <> renderTargetAuthorityTrustObservationCause cause
        )
    TargetAuthorityTrustCasFailed _ ->
      TargetAuthorityTrustUnavailableResponse "trust-cas-unavailable"
    TargetAuthorityTrustTargetMismatch -> refused "trust-target-mismatch"
    TargetAuthorityTrustAgentIdentityChanged -> refused "trust-agent-identity-changed"
    TargetAuthorityTrustIssuerIdentityChanged -> refused "trust-issuer-identity-changed"
    TargetAuthorityTrustIssuerGenerationRegressed -> refused "trust-issuer-generation-regressed"
    TargetAuthorityTrustIssuerKeyConflict -> refused "trust-issuer-key-conflict"
    TargetAuthorityTrustEpochRegressed -> refused "trust-epoch-regressed"
    TargetAuthorityTrustFenceRegressed -> refused "trust-fence-regressed"
    TargetAuthorityTrustReadBackMismatch -> refused "trust-readback-mismatch"
 where
  refused = TargetAuthorityTrustRefusedResponse

responseStatus :: TargetAuthorityTrustResponse -> ReplyStatus
responseStatus response = case response of
  TargetAuthorityTrustInstalledResponse _ -> ReplyOk
  TargetAuthorityTrustAlreadyInstalledResponse _ -> ReplyOk
  TargetAuthorityTrustRecoveredResponse _ -> ReplyOk
  TargetAuthorityTrustRefusedResponse _ -> ReplyConflict
  TargetAuthorityTrustUnavailableResponse _ -> ReplyServiceUnavailable

responseBody :: (Serialise value) => value -> ByteString
responseBody = LazyByteString.toStrict . encodeControlPlaneResponse

vaultTargetAuthorityTrustRepository
  :: TargetAgentIdentity -> VaultSession -> TargetAuthorityTrustRepository IO
vaultTargetAuthorityTrustRepository localAgentIdentity session =
  TargetAuthorityTrustRepository
    { observeTargetAuthorityTrust = observe
    , compareAndSwapTargetAuthorityTrust = compareAndSwap
    }
 where
  observe target = do
    result <-
      withSessionTokenDetailed session $ \token ->
        vaultKvReadVersionedV2
          (sessionAddress session)
          token
          "secret"
          (targetSecretWorkerTrustPath target)
    pure $ case result of
      Left (VaultSessionRequestFailed (HttpStatus 404 _)) -> TargetAuthorityTrustMissing
      Left err ->
        TargetAuthorityTrustUnobservable
          (classifyTargetAuthorityTrustObservationFailure err)
      Right versioned ->
        case decodeFields (kvV2VersionedSecretData versioned) of
          Left cause -> TargetAuthorityTrustUnobservable cause
          Right accepted ->
            classifyTargetAuthorityTrustRecord
              localAgentIdentity
              target
              (kvV2VersionedSecretVersion versioned)
              accepted

  compareAndSwap target expected accepted
    | acceptedTargetId accepted /= target =
        pure (Left "accepted Authority target mismatch")
    | not
        ( targetAuthorityTrustDesiredMatchesLocal
            localAgentIdentity
            target
            accepted
        ) =
        pure (Left "accepted Authority Agent identity mismatch")
    | otherwise = do
        result <-
          withSessionToken session $ \token ->
            vaultKvCasWriteV2
              (sessionAddress session)
              token
              "secret"
              (targetSecretWorkerTrustPath target)
              (KvV2Cas expected)
              (Map.singleton "accepted_authority" (encodeTrustText accepted))
        -- Sprint 4.74: an accepted-Authority trust rotation that lost a race
        -- must not read the same as one Vault never answered.
        pure $ case classifyVaultCasOutcome result of
          VaultCasApplied _ -> Right ()
          failed -> Left (renderVaultCasOutcome failed)

  decodeFields fields = do
    encodedText <-
      maybe
        (Left TargetAuthorityTrustObservationFieldAbsent)
        Right
        (Map.lookup "accepted_authority" fields)
    encoded <-
      first
        (const TargetAuthorityTrustObservationFieldBase64Invalid)
        (Base64.decode (TextEncoding.encodeUtf8 encodedText))
    first
      (const TargetAuthorityTrustObservationRecordInvalid)
      (decodeAcceptedTargetAuthority acceptedTargetAuthorityMaximumEncodedBytes encoded)

  encodeTrustText =
    TextEncoding.decodeUtf8 . Base64.encode . encodeAcceptedTargetAuthority

classifyTargetAuthorityTrustObservationFailure
  :: VaultSessionOperationError -> TargetAuthorityTrustObservationCause
classifyTargetAuthorityTrustObservationFailure operationError = case operationError of
  VaultSessionAcquisitionFailed sessionError -> case sessionError of
    VaultSessionSealed _ -> TargetAuthorityTrustObservationSessionAcquisitionSealed
    VaultSessionForbidden _ -> TargetAuthorityTrustObservationSessionAcquisitionForbidden
    VaultSessionUnavailable _ -> TargetAuthorityTrustObservationSessionAcquisitionUnavailable
  VaultSessionReloginFailed sessionError -> case sessionError of
    VaultSessionSealed _ -> TargetAuthorityTrustObservationSessionReloginSealed
    VaultSessionForbidden _ -> TargetAuthorityTrustObservationSessionReloginForbidden
    VaultSessionUnavailable _ -> TargetAuthorityTrustObservationSessionReloginUnavailable
  VaultSessionRequestFailed httpError -> case httpError of
    HttpStatus 401 _ -> TargetAuthorityTrustObservationRequestUnauthorized
    HttpStatus 403 _ -> TargetAuthorityTrustObservationRequestForbidden
    HttpStatus status _
      | status >= 400 && status < 500 ->
          TargetAuthorityTrustObservationRequestClientFailure
      | status >= 500 && status < 600 ->
          TargetAuthorityTrustObservationRequestServerFailure
      | otherwise -> TargetAuthorityTrustObservationRequestUnexpectedStatus
    HttpConnectionFailure _ -> TargetAuthorityTrustObservationRequestConnectionFailure
    HttpTimeout _ -> TargetAuthorityTrustObservationRequestTimeout
    HttpDecode _ -> TargetAuthorityTrustObservationRequestDecodeFailure
