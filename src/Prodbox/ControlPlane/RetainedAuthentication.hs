{-# LANGUAGE OverloadedStrings #-}

-- | Durable authentication projections shared by the five standing roles.
-- The Lifecycle Authority remains the sole post-seed epoch writer; every role
-- owns one exact Vault KV-v2 CAS replay object under its Kubernetes-auth policy.
module Prodbox.ControlPlane.RetainedAuthentication
  ( controlPlaneAuthorityEpochPath
  , controlPlaneRequestReplayPath
  , authorityAuthenticationEpoch
  , readRetainedAuthorityEpoch
  , reconcileRetainedAuthorityEpoch
  , authorityAdmissionWithRetainedEpoch
  , vaultRequestReplayRepository
  )
where

import Data.ByteString.Base64 qualified as Base64
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (..)
  , AuthorityAdmissionSnapshot (..)
  )
import Prodbox.ControlPlane.RequestReplay
  ( RequestReplayCasResult (..)
  , RequestReplayLimits
  , RequestReplayRepository (..)
  , RequestReplayRepositoryFailure (..)
  , RequestReplaySnapshot (..)
  , decodeRequestReplayProjection
  , encodeRequestReplayProjection
  , initialRequestReplayProjection
  )
import Prodbox.Http.Client (HttpError (..), renderHttpError)
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionAggregate
  , authorityAggregateAdmission
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityAdmissionState (..)
  , AuthorityEpoch
  , authorityEpochFromValue
  , authorityEpochGenesis
  , authorityEpochValue
  )
import Prodbox.Runtime.Role (RuntimeRole, runtimeRoleName)
import Prodbox.Vault.Client
  ( KvV2Cas (..)
  , KvV2VersionedSecret (..)
  , VaultCasOutcome (..)
  , classifyVaultCasOutcome
  , renderVaultCasOutcome
  , vaultKvCasWriteV2
  , vaultKvReadVersionedV2
  )
import Prodbox.Vault.Session
  ( VaultSession
  , sessionAddress
  , withSessionToken
  )

controlPlaneAuthorityEpochPath :: Text
controlPlaneAuthorityEpochPath = "control-plane/authority-epoch"

controlPlaneRequestReplayPath :: RuntimeRole -> Text
controlPlaneRequestReplayPath role =
  "control-plane/request-replay/" <> Text.pack (runtimeRoleName role)

authorityEpochField :: Text
authorityEpochField = "epoch"

requestReplayField :: Text
requestReplayField = "projection_base64"

-- | The authentication epoch remains defined while normal admission is frozen:
-- genesis control requests use epoch 1, and repair control requests use the
-- epoch being repaired.  Opening a repair advances this value atomically with
-- the retained Authority aggregate, after which the projection is repaired.
authorityAuthenticationEpoch :: AuthorityAdmissionAggregate -> AuthorityEpoch
authorityAuthenticationEpoch aggregate =
  case authorityAggregateAdmission aggregate of
    GenesisFrozen -> authorityEpochGenesis
    EstablishingBackup _ -> authorityEpochGenesis
    BackupEstablished epoch _ _ -> epoch
    BackupRepairFrozen epoch _ -> epoch

readRetainedAuthorityEpoch
  :: VaultSession -> IO (Either Text AuthorityEpoch)
readRetainedAuthorityEpoch session = do
  result <- readVersioned session controlPlaneAuthorityEpochPath
  pure $ do
    versioned <- mapLeft renderVaultError result
    decodeEpochFields (kvV2VersionedSecretData versioned)

-- | Monotone, read-back-confirmed epoch publication.  An ambiguous CAS response
-- is accepted only when a fresh authoritative read observes the desired epoch;
-- regression is always refused.
reconcileRetainedAuthorityEpoch
  :: VaultSession -> AuthorityEpoch -> IO (Either Text ())
reconcileRetainedAuthorityEpoch session desired = go (8 :: Natural)
 where
  go attempts
    | attempts == 0 = pure (Left "retained authority epoch CAS attempts exhausted")
    | otherwise = do
        observed <- readVersioned session controlPlaneAuthorityEpochPath
        case observed of
          Left (HttpStatus 404 _) -> writeAndConfirm attempts 0
          Left err -> pure (Left (renderVaultError err))
          Right versioned -> case decodeEpochFields (kvV2VersionedSecretData versioned) of
            Left detail -> pure (Left detail)
            Right current
              | current == desired -> pure (Right ())
              | current > desired ->
                  pure (Left "retained authority epoch regression refused")
              | otherwise ->
                  writeAndConfirm attempts (kvV2VersionedSecretVersion versioned)

  writeAndConfirm attempts expectedVersion = do
    attempted <-
      withSessionToken session $ \token ->
        vaultKvCasWriteV2
          (sessionAddress session)
          token
          "secret"
          controlPlaneAuthorityEpochPath
          (KvV2Cas expectedVersion)
          (Map.singleton authorityEpochField (renderEpoch desired))
    confirmed <- readRetainedAuthorityEpoch session
    case confirmed of
      Right actual
        | actual == desired -> pure (Right ())
        | actual > desired ->
            pure (Left "retained authority epoch regression observed after CAS")
      -- Sprint 4.74: only a real version mismatch consumes a retry. The
      -- superseded body retried on every `400` and on `409`, which Vault does
      -- not answer a KV CAS with at all — so a malformed or forbidden request
      -- spent the retry budget and then reported as a lost race. A refusal
      -- cannot be fixed by retrying, and an unobservable attempt may already
      -- have applied.
      _ -> case classifyVaultCasOutcome attempted of
        VaultCasConflict _ -> go (attempts - 1)
        VaultCasRefused status detail ->
          pure
            ( Left
                ( renderVaultCasOutcome (VaultCasRefused status detail)
                    <> " writing the retained authority epoch"
                )
            )
        VaultCasUnobservable detail ->
          pure
            ( Left
                ( renderVaultCasOutcome (VaultCasUnobservable detail)
                    <> " writing the retained authority epoch"
                )
            )
        VaultCasApplied _ ->
          pure (Left "retained authority epoch CAS was not confirmed by readback")

authorityAdmissionWithRetainedEpoch
  :: VaultSession
  -> AuthorityAdmissionRepository IO revision
  -> AuthorityAdmissionRepository IO revision
authorityAdmissionWithRetainedEpoch session underlying =
  AuthorityAdmissionRepository
    { readAuthorityAdmission = do
        observed <- readAuthorityAdmission underlying
        case observed of
          Left detail -> pure (Left detail)
          Right snapshot -> do
            synchronized <-
              reconcileRetainedAuthorityEpoch
                session
                ( authorityAuthenticationEpoch
                    (authorityAdmissionSnapshotState snapshot)
                )
            pure (snapshot <$ synchronized)
    , compareAndSwapAuthorityAdmission = \expected next -> do
        attempted <- compareAndSwapAuthorityAdmission underlying expected next
        observed <- readAuthorityAdmission underlying
        case observed of
          Left detail -> pure (Left detail)
          Right snapshot -> do
            synchronized <-
              reconcileRetainedAuthorityEpoch
                session
                ( authorityAuthenticationEpoch
                    (authorityAdmissionSnapshotState snapshot)
                )
            pure $ do
              _ <- synchronized
              if authorityAdmissionSnapshotState snapshot == next
                then Right ()
                else attempted
    }

vaultRequestReplayRepository
  :: VaultSession
  -> RuntimeRole
  -> Int
  -> RequestReplayLimits
  -> RequestReplayRepository IO (Maybe Natural)
vaultRequestReplayRepository session role maximumEncodedBytes limits =
  RequestReplayRepository
    { readRequestReplayProjection = do
        observed <- readVersioned session path
        pure $ case observed of
          Left (HttpStatus 404 _) ->
            Right
              RequestReplaySnapshot
                { requestReplayRevision = Nothing
                , requestReplaySnapshotProjection = initialRequestReplayProjection limits
                }
          Left err ->
            Left
              ( RequestReplayRepositoryUnobservable
                  (Text.pack (renderHttpError err))
              )
          Right versioned -> do
            projection <- decodeProjection (kvV2VersionedSecretData versioned)
            Right
              RequestReplaySnapshot
                { requestReplayRevision = Just (kvV2VersionedSecretVersion versioned)
                , requestReplaySnapshotProjection = projection
                }
    , compareAndSwapRequestReplayProjection = compareAndSwapProjection
    }
 where
  path = controlPlaneRequestReplayPath role
  compareAndSwapProjection expected projection =
    case encodeRequestReplayProjection maximumEncodedBytes limits projection of
      Left err ->
        pure
          ( RequestReplayCasUnobservable
              (RequestReplayRepositoryCorrupt (Text.pack (show err)))
          )
      Right encoded -> do
        attempted <-
          withSessionToken session $ \token ->
            vaultKvCasWriteV2
              (sessionAddress session)
              token
              "secret"
              path
              (KvV2Cas (maybe 0 id expected))
              ( Map.singleton
                  requestReplayField
                  (TextEncoding.decodeUtf8 (Base64.encode encoded))
              )
        -- Sprint 4.74: a request Vault refused is not a replay. The superseded
        -- body answered `RequestReplayCasConflict` for every `400`, so a
        -- malformed or forbidden write was reported as "another writer already
        -- claimed this request id" — a replay-protection decision made on a
        -- premise that never happened.
        pure $ case classifyVaultCasOutcome attempted of
          VaultCasApplied _ -> RequestReplayCasApplied
          VaultCasConflict _ -> RequestReplayCasConflict
          VaultCasRefused status detail ->
            RequestReplayCasUnobservable
              ( RequestReplayRepositoryUnobservable
                  (renderVaultCasOutcome (VaultCasRefused status detail))
              )
          VaultCasUnobservable detail ->
            RequestReplayCasUnobservable
              ( RequestReplayRepositoryUnobservable
                  (renderVaultCasOutcome (VaultCasUnobservable detail))
              )
  decodeProjection fields
    | Map.keys fields /= [requestReplayField] =
        Left (RequestReplayRepositoryCorrupt "retained replay fields are not exact")
    | otherwise = do
        encodedText <-
          maybe
            (Left (RequestReplayRepositoryCorrupt "retained replay field is missing"))
            Right
            (Map.lookup requestReplayField fields)
        let encoded = TextEncoding.encodeUtf8 encodedText
        decoded <-
          either
            (const (Left (RequestReplayRepositoryCorrupt "retained replay base64 is invalid")))
            Right
            (Base64.decode encoded)
        if Base64.encode decoded == encoded
          then pure ()
          else Left (RequestReplayRepositoryCorrupt "retained replay base64 is non-canonical")
        mapLeft
          (RequestReplayRepositoryCorrupt . Text.pack . show)
          (decodeRequestReplayProjection maximumEncodedBytes limits decoded)

readVersioned
  :: VaultSession
  -> Text
  -> IO (Either HttpError KvV2VersionedSecret)
readVersioned session path =
  withSessionToken session $ \token ->
    vaultKvReadVersionedV2
      (sessionAddress session)
      token
      "secret"
      path

decodeEpochFields :: Map.Map Text Text -> Either Text AuthorityEpoch
decodeEpochFields fields
  | Map.keys fields /= [authorityEpochField] =
      Left "retained authority epoch fields are not exact"
  | otherwise = do
      raw <-
        maybe
          (Left "retained authority epoch field is missing")
          Right
          (Map.lookup authorityEpochField fields)
      value <- case reads (Text.unpack raw) of
        [(parsed, "")] -> Right parsed
        _ -> Left "retained authority epoch is not canonical Natural text"
      epoch <-
        maybe
          (Left "retained authority epoch must be positive")
          Right
          (authorityEpochFromValue value)
      if renderEpoch epoch == raw
        then Right epoch
        else Left "retained authority epoch is non-canonical"

renderEpoch :: AuthorityEpoch -> Text
renderEpoch = Text.pack . show . authorityEpochValue

renderVaultError :: HttpError -> Text
renderVaultError = Text.pack . renderHttpError

mapLeft :: (left -> other) -> Either left right -> Either other right
mapLeft convert value = case value of
  Left err -> Left (convert err)
  Right result -> Right result
