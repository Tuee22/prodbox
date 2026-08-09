{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Authenticated Target Secret Agent endpoints for the closed parent/child
-- bootstrap custody protocol.  Only PGP ciphertext and secret-free evidence
-- cross this standing service boundary; plaintext recovery shares and a usable
-- root token have no constructor in the request or repository algebra.
module Prodbox.ControlPlane.BootstrapCustodyEndpoint
  ( TargetChildCustodyRepository (..)
  , ChildCustodyCommitRequest (..)
  , ChildCustodyCommitResponse (..)
  , ChildRecoveryPrepareRequest (..)
  , ChildRecoveryPrepareResponse (..)
  , ChildRecoveryObserveMode (..)
  , ChildRecoveryObserveRequest (..)
  , ChildRecoveryObserveResponse (..)
  , bootstrapCustodyMaximumBytes
  , bootstrapCustodyAuthenticatedHandler
  , vaultTargetChildCustodyRepository
  , observeTargetChildCustodyDependency
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Monad (void)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import GHC.Generics (Generic)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.Types
  ( ArtifactDigest
  , ChildAttestation
  , ChildCustodyBinding
  , ChildEncryptedReceipt (..)
  , ChildRecoveryConsumptionObservation
  , ChildRecoveryConsumptionStatus (..)
  , ChildRecoveryDelivery
  , DeliveryNonce
  , ParentCustodyAcknowledgement
  , childRecoveryDeliveryAttestation
  , childRecoveryDeliveryBinding
  , childRecoveryDeliveryNonce
  , mkArtifactDigest
  , mkChildRecoveryConsumptionObservation
  , mkChildRecoveryDelivery
  , mkEncryptedChildRecoveryPayload
  , mkParentCustodyAcknowledgement
  )
import Prodbox.Cluster.FederationRegistration
  ( FederationRegistrationIntent (federationRegistrationExport)
  , childCustodyExportReceipt
  , validateFederationRegistrationIntent
  )
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
  ( AuthenticatedRoleHandler (..)
  )
import Prodbox.ControlPlane.Codec
  ( decodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.RoleReadiness
  ( RoleDependencyObservation
  , RoleReadinessSource
  , layerRoleReadinessSource
  , roleDependencyFromOutcome
  )
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute
      ( TargetChildCustodyCommit
      , TargetChildRecoveryObserve
      , TargetChildRecoveryPrepare
      )
  )
import Prodbox.Http.Client (HttpError (HttpStatus), renderHttpError)
import Prodbox.Vault.Client
  ( KvV2Cas (..)
  , KvV2VersionedSecret (..)
  , vaultKvCasWriteV2
  , vaultKvReadVersionedV2
  , vaultTransitHmacSha256
  )
import Prodbox.Vault.Session
  ( VaultSession
  , sessionAddress
  , withSessionToken
  )

data TargetChildCustodyRepository m = TargetChildCustodyRepository
  { commitTargetChildCustody
      :: ChildEncryptedReceipt
      -> m (Either Text ParentCustodyAcknowledgement)
  , prepareTargetChildRecovery
      :: ChildCustodyBinding
      -> DeliveryNonce
      -> ChildAttestation
      -> m (Either Text ChildRecoveryDelivery)
  , observeTargetChildRecovery
      :: ChildRecoveryDelivery
      -> m (Either Text ChildRecoveryConsumptionObservation)
  , commitTargetChildRecoveryConsumption
      :: ChildRecoveryDelivery
      -> m (Either Text ChildRecoveryConsumptionObservation)
  , targetChildCustodyRepositoryReadiness :: !RoleReadinessSource
  }

newtype ChildCustodyCommitRequest = ChildCustodyCommitRequest
  { childCustodyCommitIntent :: FederationRegistrationIntent
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ChildCustodyCommitResponse
  = ChildCustodyCommitted !ParentCustodyAcknowledgement
  | ChildCustodyCommitRefused !Text
  | ChildCustodyCommitUnavailable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ChildRecoveryPrepareRequest = ChildRecoveryPrepareRequest
  { childRecoveryPrepareBinding :: !ChildCustodyBinding
  , childRecoveryPrepareNonce :: !DeliveryNonce
  , childRecoveryPrepareAttestation :: !ChildAttestation
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ChildRecoveryPrepareResponse
  = ChildRecoveryPrepared !ChildRecoveryDelivery
  | ChildRecoveryPrepareRefused !Text
  | ChildRecoveryPrepareUnavailable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ChildRecoveryObserveMode
  = ObserveChildRecoveryConsumption
  | CommitChildRecoveryConsumption
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ChildRecoveryObserveRequest = ChildRecoveryObserveRequest
  { childRecoveryObserveMode :: !ChildRecoveryObserveMode
  , childRecoveryObserveDelivery :: !ChildRecoveryDelivery
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ChildRecoveryObserveResponse
  = ChildRecoveryConsumptionObserved !ChildRecoveryConsumptionObservation
  | ChildRecoveryObserveRefused !Text
  | ChildRecoveryObserveUnavailable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

bootstrapCustodyMaximumBytes :: Int
bootstrapCustodyMaximumBytes = 8 * 1024 * 1024

bootstrapCustodyAuthenticatedHandler
  :: (Monad m)
  => Int
  -> TargetChildCustodyRepository m
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
bootstrapCustodyAuthenticatedHandler maximumBytes repository inner =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness =
        layerRoleReadinessSource
          (targetChildCustodyRepositoryReadiness repository)
          (authenticatedHandlerReadiness inner)
    , authenticatedHandlerHandle = handle
    }
 where
  handle caller route body = case route of
    TargetChildCustodyCommit -> do
      response <- case decodeRequest body of
        Left detail -> pure (ChildCustodyCommitRefused detail)
        Right request -> case validateFederationRegistrationIntent (childCustodyCommitIntent request) of
          Left _ -> pure (ChildCustodyCommitRefused "federation-registration-intent-invalid")
          Right intent -> do
            committed <-
              commitTargetChildCustody
                repository
                (childCustodyExportReceipt (federationRegistrationExport intent))
            pure $ case committed of
              Right acknowledgement -> ChildCustodyCommitted acknowledgement
              Left detail -> ChildCustodyCommitUnavailable detail
      pure (Just (commitStatus response, responseBody response))
    TargetChildRecoveryPrepare -> do
      response <- case decodeRequest body of
        Left detail -> pure (ChildRecoveryPrepareRefused detail)
        Right request -> do
          prepared <-
            prepareTargetChildRecovery
              repository
              (childRecoveryPrepareBinding request)
              (childRecoveryPrepareNonce request)
              (childRecoveryPrepareAttestation request)
          pure $ case prepared of
            Right delivery -> ChildRecoveryPrepared delivery
            Left detail -> ChildRecoveryPrepareUnavailable detail
      pure (Just (prepareStatus response, responseBody response))
    TargetChildRecoveryObserve -> do
      response <- case decodeRequest body of
        Left detail -> pure (ChildRecoveryObserveRefused detail)
        Right request -> do
          let operation = case childRecoveryObserveMode request of
                ObserveChildRecoveryConsumption -> observeTargetChildRecovery
                CommitChildRecoveryConsumption -> commitTargetChildRecoveryConsumption
          observed <- operation repository (childRecoveryObserveDelivery request)
          pure $ case observed of
            Right observation -> ChildRecoveryConsumptionObserved observation
            Left detail -> ChildRecoveryObserveUnavailable detail
      pure (Just (observeStatus response, responseBody response))
    _ -> authenticatedHandlerHandle inner caller route body

  decodeRequest body =
    first
      (const "request-codec-rejected")
      (decodeControlPlaneRequest maximumBytes (LazyByteString.fromStrict body))

commitStatus :: ChildCustodyCommitResponse -> Int
commitStatus response = case response of
  ChildCustodyCommitted {} -> 200
  ChildCustodyCommitRefused {} -> 409
  ChildCustodyCommitUnavailable {} -> 503

prepareStatus :: ChildRecoveryPrepareResponse -> Int
prepareStatus response = case response of
  ChildRecoveryPrepared {} -> 200
  ChildRecoveryPrepareRefused {} -> 409
  ChildRecoveryPrepareUnavailable {} -> 503

observeStatus :: ChildRecoveryObserveResponse -> Int
observeStatus response = case response of
  ChildRecoveryConsumptionObserved {} -> 200
  ChildRecoveryObserveRefused {} -> 409
  ChildRecoveryObserveUnavailable {} -> 503

responseBody :: (Serialise value) => value -> ByteString
responseBody = LazyByteString.toStrict . encodeControlPlaneResponse

data TargetChildCustodyRecord = TargetChildCustodyRecord
  { targetChildRecordReceipt :: !ChildEncryptedReceipt
  , targetChildRecordAcknowledgement :: !ParentCustodyAcknowledgement
  , targetChildRecordDelivery :: !(Maybe ChildRecoveryDelivery)
  , targetChildRecordConsumption :: !(Maybe ChildRecoveryConsumptionObservation)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

vaultTargetChildCustodyRepository
  :: VaultSession -> RoleReadinessSource -> TargetChildCustodyRepository IO
vaultTargetChildCustodyRepository session readiness =
  TargetChildCustodyRepository
    { commitTargetChildCustody = commitReceipt
    , prepareTargetChildRecovery = prepareDelivery
    , observeTargetChildRecovery = observeConsumption
    , commitTargetChildRecoveryConsumption = commitConsumption
    , targetChildCustodyRepositoryReadiness = readiness
    }
 where
  commitReceipt receipt = do
    pathResult <- recordPathForReceipt session receipt
    case pathResult of
      Left detail -> pure (Left detail)
      Right path -> casLoop session 8 path (commitReceiptDecision receipt)

  commitReceiptDecision receipt observed = case observed of
    Nothing ->
      let acknowledgement =
            mkParentCustodyAcknowledgement
              receipt
              (digestValue ("parent-custody-ack-v1" :: Text, receipt))
       in Right
            ( TargetChildCustodyRecord receipt acknowledgement Nothing Nothing
            , acknowledgement
            )
    Just current
      | targetChildRecordReceipt current == receipt ->
          Left (Right (targetChildRecordAcknowledgement current))
      | otherwise -> Left (Left "child custody generation collision")

  prepareDelivery binding nonce attestation = do
    pathResult <- opaqueRecordPath session (LazyByteString.toStrict (serialise binding))
    case pathResult of
      Left detail -> pure (Left detail)
      Right path -> casLoop session 8 path (prepareDeliveryDecision binding nonce attestation)

  prepareDeliveryDecision binding nonce attestation observed = case observed of
    Nothing -> Left (Left "parent custody record is absent")
    Just current
      | childEncryptedReceiptBinding (targetChildRecordReceipt current) /= binding ->
          Left (Left "parent custody binding differs")
      | otherwise -> prepareCurrentDelivery binding nonce attestation current

  prepareCurrentDelivery binding nonce attestation current =
    case targetChildRecordDelivery current of
      Just existing
        | childRecoveryDeliveryBinding existing == binding
            && childRecoveryDeliveryNonce existing == nonce
            && childRecoveryDeliveryAttestation existing == attestation ->
            Left (Right existing)
        | otherwise -> Left (Left "another one-time recovery delivery is active")
      Nothing -> do
        payload <-
          first
            (Left . Text.pack . show)
            ( mkEncryptedChildRecoveryPayload
                (LazyByteString.toStrict (serialise (targetChildRecordReceipt current)))
            )
        let delivery =
              mkChildRecoveryDelivery
                binding
                nonce
                attestation
                payload
                (digestValue ("child-recovery-delivery-v1" :: Text, binding, nonce, attestation, payload))
        Right (current {targetChildRecordDelivery = Just delivery}, delivery)

  observeConsumption delivery = do
    loaded <- readRecordForDelivery session delivery
    pure $ do
      current <- loaded
      case targetChildRecordDelivery current of
        Just exact
          | exact == delivery ->
              Right
                ( case targetChildRecordConsumption current of
                    Just observation -> observation
                    Nothing -> consumptionObservation delivery ChildRecoveryConsumptionNotApplied
                )
        _ -> Left "recovery delivery is absent or differs"

  commitConsumption delivery = do
    pathResult <-
      opaqueRecordPath
        session
        (LazyByteString.toStrict (serialise (childRecoveryDeliveryBinding delivery)))
    case pathResult of
      Left detail -> pure (Left detail)
      Right path -> casLoop session 8 path (commitConsumptionDecision delivery)

  commitConsumptionDecision delivery observed = case observed of
    Nothing -> Left (Left "parent custody record is absent")
    Just current -> commitCurrentConsumption delivery current

  commitCurrentConsumption delivery current = case targetChildRecordDelivery current of
    Just exact
      | exact == delivery -> case targetChildRecordConsumption current of
          Just existing -> Left (Right existing)
          Nothing ->
            let observation = consumptionObservation delivery ChildRecoveryConsumptionApplied
             in Right (current {targetChildRecordConsumption = Just observation}, observation)
    _ -> Left (Left "recovery delivery is absent or differs")

  consumptionObservation delivery status =
    mkChildRecoveryConsumptionObservation
      delivery
      status
      (digestValue ("child-recovery-consumption-v1" :: Text, delivery, status))

-- | CAS helper.  A decision can either request a write or return an exact
-- terminal success/refusal.  Every successful write is confirmed by a fresh
-- read, so a lost Vault response cannot duplicate custody or consumption.
casLoop
  :: (Serialise result)
  => VaultSession
  -> Int
  -> Text
  -> ( Maybe TargetChildCustodyRecord
       -> Either (Either Text result) (TargetChildCustodyRecord, result)
     )
  -> IO (Either Text result)
casLoop session attempts path decide
  | attempts <= 0 = pure (Left "child custody CAS attempts exhausted")
  | otherwise = do
      observed <- readRecord session path
      case observed of
        Left detail -> pure (Left detail)
        Right (version, current) -> case decide current of
          Left terminal -> pure terminal
          Right (next, result) -> do
            written <- writeRecord session path version next
            case written of
              Left "conflict" -> casLoop session (attempts - 1) path decide
              Left detail -> do
                confirmed <- readRecord session path
                pure $ case confirmed of
                  Right (_, Just actual)
                    | actual == next -> Right result
                  _ -> Left detail
              Right () -> do
                confirmed <- readRecord session path
                pure $ case confirmed of
                  Right (_, Just actual)
                    | actual == next -> Right result
                  _ -> Left "child custody CAS read-back mismatch"

readRecordForDelivery
  :: VaultSession
  -> ChildRecoveryDelivery
  -> IO (Either Text TargetChildCustodyRecord)
readRecordForDelivery session delivery = do
  pathResult <-
    opaqueRecordPath
      session
      (LazyByteString.toStrict (serialise (childRecoveryDeliveryBinding delivery)))
  case pathResult of
    Left detail -> pure (Left detail)
    Right path -> do
      observed <- readRecord session path
      pure $ case observed of
        Right (_, Just record) -> Right record
        Right (_, Nothing) -> Left "parent custody record is absent"
        Left detail -> Left detail

recordPathForReceipt
  :: VaultSession -> ChildEncryptedReceipt -> IO (Either Text Text)
recordPathForReceipt session receipt =
  opaqueRecordPath
    session
    (LazyByteString.toStrict (serialise (childEncryptedReceiptBinding receipt)))

opaqueRecordPath :: VaultSession -> ByteString -> IO (Either Text Text)
opaqueRecordPath session bindingBytes = do
  keyed <-
    withSessionToken session $ \token ->
      vaultTransitHmacSha256
        (sessionAddress session)
        token
        "prodbox-retained-material-commitment"
        ("prodbox-child-custody-path-v1\NUL" <> bindingBytes)
  pure $ do
    hmacText <- first (Text.pack . renderHttpError) keyed
    Right ("target-agent/child-custody/" <> lowerHex (SHA256.hash (TextEncoding.encodeUtf8 hmacText)))

readRecord
  :: VaultSession
  -> Text
  -> IO (Either Text (Natural, Maybe TargetChildCustodyRecord))
readRecord session path = do
  observed <-
    withSessionToken session $ \token ->
      vaultKvReadVersionedV2 (sessionAddress session) token "secret" path
  pure $ case observed of
    Left (HttpStatus 404 _) -> Right (0, Nothing)
    Left err -> Left (Text.pack (renderHttpError err))
    Right versioned -> do
      record <- decodeRecord (kvV2VersionedSecretData versioned)
      Right (kvV2VersionedSecretVersion versioned, Just record)

writeRecord
  :: VaultSession
  -> Text
  -> Natural
  -> TargetChildCustodyRecord
  -> IO (Either Text ())
writeRecord session path expected record = do
  written <-
    withSessionToken session $ \token ->
      vaultKvCasWriteV2
        (sessionAddress session)
        token
        "secret"
        path
        (KvV2Cas expected)
        (Map.singleton "record_base64" (encodeRecord record))
  pure $ case written of
    Left (HttpStatus 400 _) -> Left "conflict"
    Left (HttpStatus 409 _) -> Left "conflict"
    Left err -> Left (Text.pack (renderHttpError err))
    Right _ -> Right ()

decodeRecord :: Map.Map Text Text -> Either Text TargetChildCustodyRecord
decodeRecord fields
  | Map.keys fields /= ["record_base64"] = Left "child custody fields are not exact"
  | otherwise = do
      encodedText <-
        maybe (Left "child custody record is absent") Right (Map.lookup "record_base64" fields)
      encoded <-
        first
          (const "child custody record base64 is invalid")
          (Base64.decode (TextEncoding.encodeUtf8 encodedText))
      decoded <-
        first
          (const "child custody record CBOR is invalid")
          (deserialiseOrFail (LazyByteString.fromStrict encoded))
      if LazyByteString.toStrict (serialise decoded) == encoded
        then Right decoded
        else Left "child custody record CBOR is non-canonical"

encodeRecord :: TargetChildCustodyRecord -> Text
encodeRecord =
  TextEncoding.decodeUtf8
    . Base64.encode
    . LazyByteString.toStrict
    . serialise

digestValue :: (Serialise value) => value -> ArtifactDigest
digestValue value =
  case mkArtifactDigest (lowerHex (SHA256.hash (LazyByteString.toStrict (serialise value)))) of
    Right digest -> digest
    Left _ -> error "SHA-256 child custody digest invariant failed"

lowerHex :: ByteString -> Text
lowerHex = Text.pack . concatMap renderByte . ByteString.unpack
 where
  renderByte byte = case showHex byte "" of
    [single] -> ['0', single]
    pair -> pair

readinessBindingBytes :: ByteString
readinessBindingBytes = "bootstrap-custody-readiness-v1"

-- | Sprint 4.55: the custody record-path probe this repository used to run
-- inline on @\/readyz@. It is now one labelled dependency in the Lifecycle
-- Authority's background observation pass — the same observation, off the
-- request path.
observeTargetChildCustodyDependency
  :: VaultSession -> IO (Text, RoleDependencyObservation)
observeTargetChildCustodyDependency session = do
  attempted <- opaqueRecordPath session readinessBindingBytes
  pure
    ( "target-child-custody-record-path"
    , roleDependencyFromOutcome (void attempted)
    )
