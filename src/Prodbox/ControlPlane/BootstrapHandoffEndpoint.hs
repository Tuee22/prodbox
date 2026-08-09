{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Lifecycle Authority acceptance/read-back for the Bootstrap Broker's
-- post-unseal handoff.  The receipt is written by the consumer and observed by
-- the Broker; the Broker receives no Authority writer capability.
module Prodbox.ControlPlane.BootstrapHandoffEndpoint
  ( BootstrapHandoffRepository (..)
  , BootstrapHandoffRequest (..)
  , BootstrapHandoffResponse (..)
  , bootstrapHandoffMaximumBytes
  , bootstrapHandoffAuthenticatedHandler
  , vaultBootstrapHandoffRepository
  , observeBootstrapHandoffDependency
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
  , PostUnsealConsumer
  , PostUnsealHandoffReceipt
  , RootInitBinding
  , mkArtifactDigest
  , mkPostUnsealHandoffReceipt
  , postUnsealHandoffConsumer
  , postUnsealHandoffGeneration
  , rootInitStorageGeneration
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
      ( LifecycleBootstrapHandoffAccept
      , LifecycleBootstrapHandoffObserve
      )
  )
import Prodbox.Http.Client (HttpError (HttpStatus), renderHttpError)
import Prodbox.Vault.Client
  ( KvV2Cas (..)
  , KvV2VersionedSecret (..)
  , vaultKvCasWriteV2
  , vaultKvReadVersionedV2
  )
import Prodbox.Vault.Session
  ( VaultSession
  , sessionAddress
  , withSessionToken
  )

data BootstrapHandoffRepository m = BootstrapHandoffRepository
  { acceptBootstrapHandoff
      :: RootInitBinding
      -> PostUnsealConsumer
      -> m (Either Text PostUnsealHandoffReceipt)
  , observeBootstrapHandoff
      :: RootInitBinding
      -> PostUnsealConsumer
      -> m (Either Text (Maybe PostUnsealHandoffReceipt))
  , bootstrapHandoffRepositoryReadiness :: !RoleReadinessSource
  }

data BootstrapHandoffRequest = BootstrapHandoffRequest
  { bootstrapHandoffBinding :: !RootInitBinding
  , bootstrapHandoffConsumer :: !PostUnsealConsumer
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data BootstrapHandoffResponse
  = BootstrapHandoffAccepted !PostUnsealHandoffReceipt
  | BootstrapHandoffObserved !(Maybe PostUnsealHandoffReceipt)
  | BootstrapHandoffRefused !Text
  | BootstrapHandoffUnavailable !Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

bootstrapHandoffMaximumBytes :: Int
bootstrapHandoffMaximumBytes = 64 * 1024

bootstrapHandoffAuthenticatedHandler
  :: (Monad m)
  => Int
  -> BootstrapHandoffRepository m
  -> AuthenticatedRoleHandler m
  -> AuthenticatedRoleHandler m
bootstrapHandoffAuthenticatedHandler maximumBytes repository inner =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness =
        layerRoleReadinessSource
          (bootstrapHandoffRepositoryReadiness repository)
          (authenticatedHandlerReadiness inner)
    , authenticatedHandlerHandle = handle
    }
 where
  handle caller route body = case route of
    LifecycleBootstrapHandoffAccept -> do
      response <- case decodeRequest body of
        Left detail -> pure (BootstrapHandoffRefused detail)
        Right request -> do
          accepted <-
            acceptBootstrapHandoff
              repository
              (bootstrapHandoffBinding request)
              (bootstrapHandoffConsumer request)
          pure $ case accepted of
            Right receipt -> BootstrapHandoffAccepted receipt
            Left detail -> BootstrapHandoffUnavailable detail
      pure (Just (responseStatus response, responseBody response))
    LifecycleBootstrapHandoffObserve -> do
      response <- case decodeRequest body of
        Left detail -> pure (BootstrapHandoffRefused detail)
        Right request -> do
          observed <-
            observeBootstrapHandoff
              repository
              (bootstrapHandoffBinding request)
              (bootstrapHandoffConsumer request)
          pure $ case observed of
            Right receipt -> BootstrapHandoffObserved receipt
            Left detail -> BootstrapHandoffUnavailable detail
      pure (Just (responseStatus response, responseBody response))
    _ -> authenticatedHandlerHandle inner caller route body

  decodeRequest body =
    first
      (const "request-codec-rejected")
      (decodeControlPlaneRequest maximumBytes (LazyByteString.fromStrict body))

responseStatus :: BootstrapHandoffResponse -> Int
responseStatus response = case response of
  BootstrapHandoffAccepted {} -> 200
  BootstrapHandoffObserved {} -> 200
  BootstrapHandoffRefused {} -> 409
  BootstrapHandoffUnavailable {} -> 503

responseBody :: BootstrapHandoffResponse -> ByteString
responseBody = LazyByteString.toStrict . encodeControlPlaneResponse

bootstrapHandoffPath :: Text
bootstrapHandoffPath = "control-plane/bootstrap-handoff"

bootstrapHandoffField :: Text
bootstrapHandoffField = "receipt_base64"

vaultBootstrapHandoffRepository
  :: VaultSession -> RoleReadinessSource -> BootstrapHandoffRepository IO
vaultBootstrapHandoffRepository session readiness =
  BootstrapHandoffRepository
    { acceptBootstrapHandoff = accept
    , observeBootstrapHandoff = observe
    , bootstrapHandoffRepositoryReadiness = readiness
    }
 where
  accept binding consumer = go 8
   where
    expected =
      mkPostUnsealHandoffReceipt
        (rootInitStorageGeneration binding)
        consumer
        (digestValue ("post-unseal-authority-handoff-v1" :: Text, binding, consumer))
    go :: Natural -> IO (Either Text PostUnsealHandoffReceipt)
    go attempts
      | attempts <= 0 = pure (Left "bootstrap handoff CAS attempts exhausted")
      | otherwise = do
          observed <- readReceipt session
          case observed of
            Left detail -> pure (Left detail)
            Right (_, Just receipt)
              | receipt == expected -> pure (Right receipt)
              | postUnsealHandoffGeneration receipt
                  == rootInitStorageGeneration binding ->
                  pure (Left "bootstrap handoff generation collision")
              | otherwise -> pure (Left "another bootstrap handoff generation is retained")
            Right (version, Nothing) -> do
              written <- writeReceipt session version expected
              confirmed <- readReceipt session
              case confirmed of
                Right (_, Just receipt)
                  | receipt == expected -> pure (Right receipt)
                _ -> case written of
                  Left "conflict" -> go (attempts - 1)
                  Left detail -> pure (Left detail)
                  Right () -> pure (Left "bootstrap handoff read-back mismatch")

  observe binding consumer = do
    observed <- readReceipt session
    pure $ do
      (_, maybeReceipt) <- observed
      case maybeReceipt of
        Nothing -> Right Nothing
        Just receipt
          | postUnsealHandoffGeneration receipt == rootInitStorageGeneration binding
              && postUnsealHandoffConsumer receipt == consumer ->
              Right (Just receipt)
          | otherwise -> Left "bootstrap handoff receipt differs"

readReceipt
  :: VaultSession
  -> IO (Either Text (Natural, Maybe PostUnsealHandoffReceipt))
readReceipt session = do
  observed <-
    withSessionToken session $ \token ->
      vaultKvReadVersionedV2
        (sessionAddress session)
        token
        "secret"
        bootstrapHandoffPath
  pure $ case observed of
    Left (HttpStatus 404 _) -> Right (0, Nothing)
    Left err -> Left (Text.pack (renderHttpError err))
    Right versioned -> do
      receipt <- decodeReceipt (kvV2VersionedSecretData versioned)
      Right (kvV2VersionedSecretVersion versioned, Just receipt)

writeReceipt
  :: VaultSession
  -> Natural
  -> PostUnsealHandoffReceipt
  -> IO (Either Text ())
writeReceipt session version receipt = do
  written <-
    withSessionToken session $ \token ->
      vaultKvCasWriteV2
        (sessionAddress session)
        token
        "secret"
        bootstrapHandoffPath
        (KvV2Cas version)
        ( Map.singleton
            bootstrapHandoffField
            ( TextEncoding.decodeUtf8
                (Base64.encode (LazyByteString.toStrict (serialise receipt)))
            )
        )
  pure $ case written of
    Left (HttpStatus 400 _) -> Left "conflict"
    Left (HttpStatus 409 _) -> Left "conflict"
    Left err -> Left (Text.pack (renderHttpError err))
    Right _ -> Right ()

decodeReceipt
  :: Map.Map Text Text -> Either Text PostUnsealHandoffReceipt
decodeReceipt fields
  | Map.keys fields /= [bootstrapHandoffField] =
      Left "bootstrap handoff fields are not exact"
  | otherwise = do
      raw <-
        maybe (Left "bootstrap handoff receipt is absent") Right (Map.lookup bootstrapHandoffField fields)
      encoded <-
        first (const "bootstrap handoff base64 is invalid") (Base64.decode (TextEncoding.encodeUtf8 raw))
      receipt <-
        first
          (const "bootstrap handoff CBOR is invalid")
          (deserialiseOrFail (LazyByteString.fromStrict encoded))
      if LazyByteString.toStrict (serialise receipt) == encoded
        then Right receipt
        else Left "bootstrap handoff CBOR is non-canonical"

digestValue :: (Serialise value) => value -> ArtifactDigest
digestValue value =
  case mkArtifactDigest (lowerHex (SHA256.hash (LazyByteString.toStrict (serialise value)))) of
    Right digest -> digest
    Left _ -> error "SHA-256 bootstrap handoff digest invariant failed"

lowerHex :: ByteString -> Text
lowerHex = Text.pack . concatMap renderByte . ByteString.unpack
 where
  renderByte byte = case showHex byte "" of
    [single] -> ['0', single]
    pair -> pair

-- | Sprint 4.55: the handoff-receipt read this repository used to run inline on
-- @\/readyz@, now one labelled dependency in the Lifecycle Authority's
-- background observation pass.
observeBootstrapHandoffDependency
  :: VaultSession -> IO (Text, RoleDependencyObservation)
observeBootstrapHandoffDependency session = do
  observed <- readReceipt session
  pure
    ( "bootstrap-handoff-receipt"
    , roleDependencyFromOutcome (void observed)
    )
