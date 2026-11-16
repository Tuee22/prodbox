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
  , TargetReplayMigrationStore (..)
  , TargetReplayMigrationResult (..)
  , migrateTargetReplayStagedWith
  , migrateTargetReplayStaged
  , targetReplayVaultReadMaximumBytes
  )
where

import Data.ByteString qualified as ByteString
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
  , requestReplayStagedCodec
  )
import Prodbox.Http.Client (HttpError (..), renderHttpError)
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionAggregate
  , authorityAggregateAuthenticationEpoch
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityEpoch
  , authorityEpochFromValue
  , authorityEpochValue
  )
import Prodbox.Lifecycle.CheckpointAuthority (ModelBCodec (..))
import Prodbox.Runtime.Role (RuntimeRole (TargetSecretAgentRuntime), runtimeRoleName)
import Prodbox.Vault.Client
  ( KvV2Cas (..)
  , KvV2VersionedSecret (..)
  , VaultCasOutcome (..)
  , classifyVaultCasOutcome
  , renderVaultCasOutcome
  , vaultKvCasWriteV2
  , vaultKvCasWriteV2Bounded
  , vaultKvReadVersionedV2
  , vaultKvReadVersionedV2Bounded
  , vaultKvReadVersionedV2WithLimit
  )
import Prodbox.Vault.Session
  ( VaultSession
  , sessionAddress
  , sessionToken
  , withSessionToken
  )

controlPlaneAuthorityEpochPath :: Text
controlPlaneAuthorityEpochPath = "control-plane/authority-epoch"

controlPlaneRequestReplayPath :: RuntimeRole -> Text
controlPlaneRequestReplayPath role =
  "control-plane/request-replay/" <> Text.pack (runtimeRoleName role)

-- | The path is selected by the migration, not by the caller. This boundary
-- permits exercising the same versioned Vault operations without credentials.
data TargetReplayMigrationStore m = TargetReplayMigrationStore
  { targetReplayMigrationRead :: Text -> m (Either HttpError KvV2VersionedSecret)
  , targetReplayMigrationWrite :: Text -> Natural -> Map.Map Text Text -> m VaultCasOutcome
  }

data TargetReplayMigrationResult
  = TargetReplayObservedCurrent !Natural
  | TargetReplayMigrated !Natural
  | TargetReplayRecovered !Natural
  | TargetReplayMissing
  | TargetReplayInvalid !Text
  | TargetReplayConflict
  | TargetReplayWriteRefused
  | TargetReplayUnobservable
  | TargetReplayReadbackChanged
  deriving (Eq, Show)

-- | One exact Vault KV-v2 CAS, with independent readback. This candidate is
-- not installed: the caller must first fence and drain all old writers, and
-- separately bound the supplied transport, execution time and memory. An observed
-- current version is not a fence or completion receipt.
migrateTargetReplayStagedWith
  :: (Monad m)
  => Int
  -> RequestReplayLimits
  -> RequestReplayLimits
  -> TargetReplayMigrationStore m
  -> m TargetReplayMigrationResult
migrateTargetReplayStagedWith maximumBytes previousLimits nextLimits store =
  case requestReplayStagedCodec maximumBytes previousLimits nextLimits of
    Left failure -> pure (TargetReplayInvalid (Text.pack (show failure)))
    Right codec -> do
      observed <- targetReplayMigrationRead store path
      case observed of
        Left (HttpStatus 404 _) -> pure TargetReplayMissing
        Left _ -> pure TargetReplayUnobservable
        Right secret -> case successor codec secret of
          Left failure -> pure (TargetReplayInvalid failure)
          Right fields
            | fields == kvV2VersionedSecretData secret ->
                pure (TargetReplayObservedCurrent (kvV2VersionedSecretVersion secret))
            | otherwise -> do
                let previous = kvV2VersionedSecretVersion secret
                attempted <- targetReplayMigrationWrite store path previous fields
                case attempted of
                  VaultCasConflict _ -> pure TargetReplayConflict
                  VaultCasRefused _ _ -> pure TargetReplayWriteRefused
                  VaultCasApplied version
                    | version /= previous + 1 -> pure TargetReplayReadbackChanged
                    | otherwise -> confirm (TargetReplayMigrated version) version fields
                  VaultCasUnobservable _ ->
                    confirm (TargetReplayRecovered (previous + 1)) (previous + 1) fields
 where
  path = controlPlaneRequestReplayPath TargetSecretAgentRuntime
  successor codec secret = do
    let fields = kvV2VersionedSecretData secret
    if kvV2VersionedSecretVersion secret == 0 || Map.keys fields /= [requestReplayField]
      then Left "invalid retained replay version or fields"
      else pure ()
    encoded <- maybe (Left "missing retained replay field") Right (Map.lookup requestReplayField fields)
    if maximumBytes < 0 || toInteger (Text.length encoded) > 4 * ((toInteger maximumBytes + 2) `div` 3)
      then Left "retained replay exceeds byte budget"
      else pure ()
    let encodedBytes = TextEncoding.encodeUtf8 encoded
    decoded <- either (const (Left "invalid retained replay base64")) Right (Base64.decode encodedBytes)
    if Base64.encode decoded /= encodedBytes || ByteString.length decoded > maximumBytes
      then Left "noncanonical or oversized retained replay"
      else pure ()
    projection <- either (Left . Text.pack) Right (decodeModelBValue codec decoded)
    next <- either (Left . Text.pack) Right (encodeModelBValue codec projection)
    pure (Map.singleton requestReplayField (TextEncoding.decodeUtf8 (Base64.encode next)))
  confirm success version fields = do
    observed <- targetReplayMigrationRead store path
    pure $ case observed of
      Right secret
        | kvV2VersionedSecretVersion secret == version
            && kvV2VersionedSecretData secret == fields ->
            success
        | otherwise -> TargetReplayReadbackChanged
      Left _ -> TargetReplayUnobservable

-- | Bind the candidate to the same authenticated Vault session and exact
-- KV-v2 mount as the installed Target replay repository. This alone supplies
-- neither the old-writer fence nor the separately required memory and time bounds.
-- The wire ceiling admits the canonical base64 payload plus a bounded JSON
-- envelope; additional escaping or metadata may be refused as unobservable.
targetReplayVaultReadMaximumBytes :: Int -> Maybe Int
targetReplayVaultReadMaximumBytes maximumBytes
  | maximumBytes < 0 || ceilingBytes > toInteger (maxBound :: Int) = Nothing
  | otherwise = Just (fromInteger ceilingBytes)
 where
  ceilingBytes = 4 * ((toInteger maximumBytes + 2) `div` 3) + 128 * 1024

migrateTargetReplayStaged
  :: VaultSession
  -> Int
  -> RequestReplayLimits
  -> RequestReplayLimits
  -> IO TargetReplayMigrationResult
migrateTargetReplayStaged session maximumBytes previousLimits nextLimits =
  case targetReplayVaultReadMaximumBytes maximumBytes of
    Nothing -> pure (TargetReplayInvalid "invalid Vault replay read bound")
    Just wireMaximum ->
      migrateTargetReplayStagedWith maximumBytes previousLimits nextLimits $
        TargetReplayMigrationStore
          { targetReplayMigrationRead = \path -> withSessionToken session $ \token ->
              vaultKvReadVersionedV2WithLimit wireMaximum (sessionAddress session) token "secret" path
          , targetReplayMigrationWrite = \path version fields -> do
              acquired <- sessionToken session
              case acquired of
                Left _ -> pure (VaultCasUnobservable "Vault session acquisition failed")
                Right token ->
                  classifyVaultCasOutcome
                    <$> vaultKvCasWriteV2Bounded (sessionAddress session) token "secret" path (KvV2Cas version) fields
          }

authorityEpochField :: Text
authorityEpochField = "epoch"

requestReplayField :: Text
requestReplayField = "projection_base64"

-- | The authentication epoch remains defined while normal admission is frozen:
-- genesis control requests use epoch 1, and repair control requests use the
-- epoch being repaired.  Opening a repair advances this value atomically with
-- the retained Authority aggregate, after which the projection is repaired.
authorityAuthenticationEpoch :: AuthorityAdmissionAggregate -> AuthorityEpoch
authorityAuthenticationEpoch = authorityAggregateAuthenticationEpoch

readRetainedAuthorityEpoch
  :: VaultSession -> IO (Either Text AuthorityEpoch)
readRetainedAuthorityEpoch session = do
  result <- withSessionToken session $ \token ->
    vaultKvReadVersionedV2Bounded
      (sessionAddress session)
      token
      "secret"
      controlPlaneAuthorityEpochPath
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
