{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Closed, target-keyed KV effects shared by active installation and staged
-- epoch control. The production interpreter owns the existing Agent path.
module Prodbox.ControlPlane.TargetAuthorityTrustStore
  ( TargetTrustRowProgram (..)
  , TargetTrustRowInterpreter (..)
  , TargetTrustRowError (..)
  , vaultTargetTrustRowInterpreter
  , classifyTargetAuthorityTrustObservationFailure
  )
where

import Data.Map.Strict (Map)
import Data.Text (Text)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.TargetAuthorityEpoch
  ( TargetAuthorityEpochRecord
  , targetEpochRecordTarget
  )
import Prodbox.ControlPlane.TargetAuthorityEpochCodec
  ( TargetAuthorityEpochCodecError
  , encodeTargetAuthorityEpochFields
  )
import Prodbox.ControlPlane.TargetAuthorityTrust (TargetAuthorityTrustObservationCause (..))
import Prodbox.ControlPlane.TargetMaterialRegistry (TargetSecretId)
import Prodbox.ControlPlane.TargetSecretWorkerRuntime (targetSecretWorkerTrustPath)
import Prodbox.Http.Client (HttpError (..))
import Prodbox.Vault.Client
  ( KvV2Cas (KvV2Cas)
  , KvV2VersionedSecret (..)
  , VaultCasOutcome (..)
  , classifyVaultCasOutcome
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

data TargetTrustRowProgram result where
  ReadTargetTrustRow
    :: TargetSecretId
    -> TargetTrustRowProgram (Maybe (Natural, Map Text Text))
  CompareAndSwapTargetTrustRow
    :: TargetSecretId
    -> Natural
    -> TargetAuthorityEpochRecord
    -> TargetTrustRowProgram ()

data TargetTrustRowError
  = TargetTrustRowObservationFailed !TargetAuthorityTrustObservationCause
  | TargetTrustRowWriteFailed !VaultCasOutcome
  | TargetTrustRowInvalidTarget
  | TargetTrustRowInvalidRecord !TargetAuthorityEpochCodecError
  deriving stock (Eq, Show)

newtype TargetTrustRowInterpreter m = TargetTrustRowInterpreter
  { runTargetTrustRowProgram
      :: forall result. TargetTrustRowProgram result -> m (Either TargetTrustRowError result)
  }

vaultTargetTrustRowInterpreter :: VaultSession -> TargetTrustRowInterpreter IO
vaultTargetTrustRowInterpreter session = TargetTrustRowInterpreter interpret
 where
  interpret :: TargetTrustRowProgram result -> IO (Either TargetTrustRowError result)
  interpret program = case program of
    ReadTargetTrustRow target -> do
      result <-
        withSessionTokenDetailed session $ \token ->
          vaultKvReadVersionedV2 (sessionAddress session) token "secret" (targetSecretWorkerTrustPath target)
      pure $ case result of
        Left (VaultSessionRequestFailed (HttpStatus 404 _)) -> Right Nothing
        Left err -> Left (TargetTrustRowObservationFailed (classifyTargetAuthorityTrustObservationFailure err))
        Right versioned
          | kvV2VersionedSecretVersion versioned == 0 ->
              Left (TargetTrustRowObservationFailed TargetAuthorityTrustObservationRecordInvalid)
          | otherwise ->
              Right (Just (kvV2VersionedSecretVersion versioned, kvV2VersionedSecretData versioned))
    CompareAndSwapTargetTrustRow target expected record
      | targetEpochRecordTarget record /= target -> pure (Left TargetTrustRowInvalidTarget)
      | otherwise -> case encodeTargetAuthorityEpochFields record of
          Left err -> pure (Left (TargetTrustRowInvalidRecord err))
          Right fields -> do
            result <-
              withSessionToken session $ \token ->
                vaultKvCasWriteV2
                  (sessionAddress session)
                  token
                  "secret"
                  (targetSecretWorkerTrustPath target)
                  (KvV2Cas expected)
                  fields
            pure $ case classifyVaultCasOutcome result of
              VaultCasApplied _ -> Right ()
              failed@(VaultCasConflict _) -> Left (TargetTrustRowWriteFailed failed)
              failed@(VaultCasRefused _ _) -> Left (TargetTrustRowWriteFailed failed)
              failed@(VaultCasUnobservable _) -> Left (TargetTrustRowWriteFailed failed)

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
      | status >= 400 && status < 500 -> TargetAuthorityTrustObservationRequestClientFailure
      | status >= 500 && status < 600 -> TargetAuthorityTrustObservationRequestServerFailure
      | otherwise -> TargetAuthorityTrustObservationRequestUnexpectedStatus
    HttpConnectionFailure _ -> TargetAuthorityTrustObservationRequestConnectionFailure
    HttpTimeout _ -> TargetAuthorityTrustObservationRequestTimeout
    HttpDecode _ -> TargetAuthorityTrustObservationRequestDecodeFailure
