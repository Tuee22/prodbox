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
  , targetAuthorityTrustRepositoryWithEpochRows
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
import Prodbox.ControlPlane.TargetAuthorityEpoch
  ( TargetAuthorityEpochTransition (..)
  , advanceOrdinaryTargetAuthority
  , initialTargetAuthorityEpochRecord
  , targetEpochRecordActive
  , targetEpochRecordTransition
  )
import Prodbox.ControlPlane.TargetAuthorityEpochCodec
  ( decodeTargetAuthorityEpochFields
  , targetAuthorityEpochStateField
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
import Prodbox.ControlPlane.TargetAuthorityTrustStore
  ( TargetTrustRowError (..)
  , TargetTrustRowInterpreter (..)
  , TargetTrustRowProgram (..)
  , classifyTargetAuthorityTrustObservationFailure
  , vaultTargetTrustRowInterpreter
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( TargetAgentIdentity
  , acceptedTargetAuthorityMaximumEncodedBytes
  , acceptedTargetId
  , decodeAcceptedTargetAuthority
  , encodeAcceptedTargetAuthority
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Vault.Client (renderVaultCasOutcome)
import Prodbox.Vault.Session (VaultSession)

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
  | TargetAuthorityEpochResponse !ByteString
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
  TargetAuthorityEpochResponse _ -> ReplyOk

responseBody :: (Serialise value) => value -> ByteString
responseBody = LazyByteString.toStrict . encodeControlPlaneResponse

vaultTargetAuthorityTrustRepository
  :: TargetAgentIdentity -> VaultSession -> TargetAuthorityTrustRepository IO
vaultTargetAuthorityTrustRepository localAgentIdentity session =
  targetAuthorityTrustRepositoryWithEpochRows
    localAgentIdentity
    (vaultTargetTrustRowInterpreter session)

targetAuthorityTrustRepositoryWithEpochRows
  :: (Monad m)
  => TargetAgentIdentity -> TargetTrustRowInterpreter m -> TargetAuthorityTrustRepository m
targetAuthorityTrustRepositoryWithEpochRows localAgentIdentity interpreter =
  TargetAuthorityTrustRepository
    { observeTargetAuthorityTrust = observe
    , compareAndSwapTargetAuthorityTrust = compareAndSwap
    }
 where
  observe target = do
    observed <- readRow target
    pure $ case observed of
      Left cause -> TargetAuthorityTrustUnobservable cause
      Right (0, Nothing) -> TargetAuthorityTrustMissing
      Right (version, Just record) -> case targetEpochRecordTransition record of
        TargetEpochPrepared _ -> frozen
        TargetEpochRetired _ -> frozen
        TargetEpochNoTransition -> activeObservation version record
        TargetEpochPromoted _ -> activeObservation version record
      Right _ -> TargetAuthorityTrustUnobservable TargetAuthorityTrustObservationRecordInvalid
   where
    frozen = TargetAuthorityTrustUnobservable TargetAuthorityTrustObservationEpochTransitionFrozen
    activeObservation version record = case targetEpochRecordActive record of
      Nothing -> TargetAuthorityTrustUnobservable TargetAuthorityTrustObservationFieldAbsent
      Just accepted -> classifyTargetAuthorityTrustRecord localAgentIdentity target version accepted

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
        observed <- readRow target
        case observed of
          Left _ -> pure (Left "accepted Authority row is unobservable")
          Right (version, existing)
            | version /= expected -> pure (Left "accepted Authority CAS version mismatch")
            | otherwise -> case prepareRecord target accepted existing of
                Left _ -> pure (Left "accepted Authority epoch transition refuses installation")
                Right record -> do
                  result <- runTargetTrustRowProgram interpreter (CompareAndSwapTargetTrustRow target expected record)
                  pure (either (Left . writeFailure) Right result)

  prepareRecord target accepted existing = do
    record <- case existing of
      Nothing -> either (const (Left ())) Right (initialTargetAuthorityEpochRecord target Nothing)
      Just retained -> Right retained
    either (const (Left ())) Right (advanceOrdinaryTargetAuthority accepted record)

  readRow target = do
    result <- runTargetTrustRowProgram interpreter (ReadTargetTrustRow target)
    pure $ case result of
      Left err -> Left (readFailure err)
      Right Nothing -> Right (0, Nothing)
      Right (Just (version, fields))
        | version == 0 -> Left TargetAuthorityTrustObservationRecordInvalid
        | otherwise -> do
            record <- decodeRow target fields
            pure (version, Just record)

  readFailure err = case err of
    TargetTrustRowObservationFailed cause -> cause
    TargetTrustRowWriteFailed _ -> TargetAuthorityTrustObservationOther
    TargetTrustRowInvalidTarget -> TargetAuthorityTrustObservationTargetMismatch
    TargetTrustRowInvalidRecord _ -> TargetAuthorityTrustObservationRecordInvalid

  writeFailure err = case err of
    TargetTrustRowObservationFailed cause -> renderTargetAuthorityTrustObservationCause cause
    TargetTrustRowWriteFailed outcome -> renderVaultCasOutcome outcome
    TargetTrustRowInvalidTarget -> "target-mismatch"
    TargetTrustRowInvalidRecord _ -> "record-invalid"

  decodeRow target fields
    | Map.member targetAuthorityEpochStateField fields =
        either
          (const (Left TargetAuthorityTrustObservationRecordInvalid))
          Right
          (decodeTargetAuthorityEpochFields target fields)
    | otherwise = do
        accepted <- decodeFields fields
        case classifyTargetAuthorityTrustRecord localAgentIdentity target 1 accepted of
          TargetAuthorityTrustUnobservable cause -> Left cause
          TargetAuthorityTrustObserved _ _ ->
            either
              (const (Left TargetAuthorityTrustObservationRecordInvalid))
              Right
              (initialTargetAuthorityEpochRecord target (Just accepted))
          TargetAuthorityTrustMissing -> Left TargetAuthorityTrustObservationRecordInvalid

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
