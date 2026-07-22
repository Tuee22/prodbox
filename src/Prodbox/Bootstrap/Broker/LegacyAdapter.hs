{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Standard-P rollback adapter for the bootstrap routes still served by the
-- combined gateway process. Target ownership lives in the Bootstrap Broker;
-- this module contains the complete pre-cutover password/static-store
-- implementation so neither the Gateway route registry, client, daemon
-- exports, nor actor-backed target topology can represent that authority.
-- Sprint 4.50 owns deletion after current-revision qualification.
module Prodbox.Bootstrap.Broker.LegacyAdapter
  ( LegacyGatewayBootstrapRoute (..)
  , allLegacyGatewayBootstrapRoutes
  , legacyGatewayBootstrapPath
  , legacyGatewayBootstrapRouteForPath
  , LegacyGatewayBootstrapResponse (..)
  , runLegacyGatewayBootstrapRequest

    -- * Registered rollback request contract
  , BootstrapVaultRequest (..)
  , BootstrapVaultRotateUnlockBundleRequest (..)
  , BootstrapVaultRotateTransitKeyRequest (..)
  , BootstrapVaultResponse (..)
  , BootstrapVaultRequestError (..)
  , bootstrapVaultPath
  , bootstrapVaultPkiIssueTestCertPath
  , bootstrapVaultPkiStatusPath
  , bootstrapVaultRotateTransitKeyPath
  , bootstrapVaultRotateUnlockBundlePath
  , bootstrapVaultSealPath
  , bootstrapVaultStatusPath
  , bootstrapVaultRequestMaxBytes
  , decodeBootstrapVaultAuthenticatedRequest
  , decodeBootstrapVaultRequest
  , decodeBootstrapVaultRotateTransitKeyRequest
  , decodeBootstrapVaultRotateUnlockBundleRequest
  , renderBootstrapVaultRequestError
  )
where

import Data.Aeson
  ( FromJSON (..)
  , ToJSON (..)
  , Value
  , eitherDecodeStrict'
  , encode
  , object
  , withObject
  , (.!=)
  , (.:)
  , (.:?)
  , (.=)
  )
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isSpace)
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format.ISO8601 (formatShow, iso8601Format)
import Prodbox.Bootstrap.Broker.Routes
  ( BrokerRoute (..)
  , brokerRoutePath
  )
import Prodbox.Gateway.Types
  ( DaemonConfig (..)
  , GatewayVaultAuth (..)
  )
import Prodbox.Http.Client (renderHttpError)
import Prodbox.Minio.ObjectStore (ObjectStoreConfig)
import Prodbox.Vault.BootstrapBundle
  ( bootstrapObjectStoreConfigWithEndpoint
  , getBundleObject
  , putBundleObject
  )
import Prodbox.Vault.Client
  ( BootstrapAction (..)
  , SealStatus
  , VaultAddress (..)
  , VaultToken (..)
  , bootstrapAction
  , defaultInitRequest
  , initResponseToUnlockBundle
  , vaultInit
  , vaultListMounts
  , vaultMountType
  , vaultPkiIssueTestCertificate
  , vaultRotateTransitKey
  , vaultSeal
  , vaultSealStatus
  , vaultSubmitUnseal
  )
import Prodbox.Vault.Orchestration
  ( UnsealOutcome (..)
  , interpretUnsealProgress
  , planUnseal
  , unsealStepKey
  )
import Prodbox.Vault.Reconcile
  ( defaultVaultReconcilePlan
  , renderVaultReconcileError
  , runVaultReconcile
  )
import Prodbox.Vault.UnlockBundle
  ( UnlockBundle (..)
  , decryptUnlockBundle
  , encryptUnlockBundle
  , renderUnlockBundleError
  )

data LegacyGatewayBootstrapRoute
  = LegacyGatewayVaultEnsure
  | LegacyGatewayVaultStatus
  | LegacyGatewayVaultSeal
  | LegacyGatewayVaultRotateUnlockBundle
  | LegacyGatewayVaultRotateTransitKey
  | LegacyGatewayVaultPkiStatus
  | LegacyGatewayVaultPkiIssueTestCertificate
  deriving (Eq, Ord, Show, Enum, Bounded)

allLegacyGatewayBootstrapRoutes :: [LegacyGatewayBootstrapRoute]
allLegacyGatewayBootstrapRoutes = [minBound .. maxBound]

legacyGatewayBootstrapPath :: LegacyGatewayBootstrapRoute -> String
legacyGatewayBootstrapPath route = case route of
  LegacyGatewayVaultEnsure -> "/v1/bootstrap/vault/ensure"
  LegacyGatewayVaultStatus -> brokerRoutePath BrokerVaultStatus
  LegacyGatewayVaultSeal -> brokerRoutePath BrokerVaultSeal
  LegacyGatewayVaultRotateUnlockBundle -> brokerRoutePath BrokerVaultRotateUnlockBundle
  LegacyGatewayVaultRotateTransitKey -> brokerRoutePath BrokerVaultRotateTransitKey
  LegacyGatewayVaultPkiStatus -> brokerRoutePath BrokerVaultPkiStatus
  LegacyGatewayVaultPkiIssueTestCertificate ->
    brokerRoutePath BrokerVaultPkiIssueTestCertificate

legacyGatewayBootstrapRouteForPath :: String -> Maybe LegacyGatewayBootstrapRoute
legacyGatewayBootstrapRouteForPath path =
  find ((== path) . legacyGatewayBootstrapPath) allLegacyGatewayBootstrapRoutes

-- | A fully rendered rollback response. The Gateway daemon owns only the
-- socket write; all request decoding and bootstrap authority stay here.
data LegacyGatewayBootstrapResponse = LegacyGatewayBootstrapResponse
  { legacyGatewayBootstrapStatus :: !Int
  , legacyGatewayBootstrapContentType :: !String
  , legacyGatewayBootstrapBody :: !LazyByteString.ByteString
  }
  deriving (Eq, Show)

-- | Interpret one registered rollback route. The rank-2 child runner preserves
-- the historical bounded subprocess boundary without exposing the Gateway
-- environment or allowing this module to depend on the daemon.
runLegacyGatewayBootstrapRequest
  :: DaemonConfig
  -> (forall value. Text -> IO (Either String value) -> IO (Either String value))
  -> LegacyGatewayBootstrapRoute
  -> ByteString
  -> IO LegacyGatewayBootstrapResponse
runLegacyGatewayBootstrapRequest config runChild route rawRequest =
  case route of
    LegacyGatewayVaultEnsure ->
      handleBootstrapVaultEnsure config runChild rawRequest
    LegacyGatewayVaultStatus ->
      handleBootstrapVaultStatus config rawRequest
    LegacyGatewayVaultSeal ->
      handleBootstrapVaultPasswordAction rawRequest $ \request -> do
        result <- sealBootstrapVault config runChild request
        pure (encodeBootstrapActionResult result)
    LegacyGatewayVaultRotateUnlockBundle ->
      handleBootstrapVaultRotateUnlockBundle config runChild rawRequest
    LegacyGatewayVaultRotateTransitKey ->
      handleBootstrapVaultRotateTransitKey config runChild rawRequest
    LegacyGatewayVaultPkiStatus ->
      handleBootstrapVaultPasswordAction rawRequest $ \request -> do
        result <- bootstrapVaultPkiStatus config runChild request
        pure (encodeBootstrapActionResult result)
    LegacyGatewayVaultPkiIssueTestCertificate ->
      handleBootstrapVaultPasswordAction rawRequest $ \request -> do
        result <- bootstrapVaultPkiIssueTestCert config runChild request
        pure (encodeBootstrapActionResult result)

bootstrapVaultPath :: String
bootstrapVaultPath = legacyGatewayBootstrapPath LegacyGatewayVaultEnsure

bootstrapVaultStatusPath :: String
bootstrapVaultStatusPath = legacyGatewayBootstrapPath LegacyGatewayVaultStatus

bootstrapVaultSealPath :: String
bootstrapVaultSealPath = legacyGatewayBootstrapPath LegacyGatewayVaultSeal

bootstrapVaultRotateUnlockBundlePath :: String
bootstrapVaultRotateUnlockBundlePath =
  legacyGatewayBootstrapPath LegacyGatewayVaultRotateUnlockBundle

bootstrapVaultRotateTransitKeyPath :: String
bootstrapVaultRotateTransitKeyPath =
  legacyGatewayBootstrapPath LegacyGatewayVaultRotateTransitKey

bootstrapVaultPkiStatusPath :: String
bootstrapVaultPkiStatusPath = legacyGatewayBootstrapPath LegacyGatewayVaultPkiStatus

bootstrapVaultPkiIssueTestCertPath :: String
bootstrapVaultPkiIssueTestCertPath =
  legacyGatewayBootstrapPath LegacyGatewayVaultPkiIssueTestCertificate

bootstrapVaultRequestMaxBytes :: Int
bootstrapVaultRequestMaxBytes = 64 * 1024

data BootstrapVaultRequest = BootstrapVaultRequest
  { bootstrapVaultUnlockPassword :: Text
  , bootstrapVaultLoopbackNodePortVerified :: Bool
  }
  deriving (Eq)

instance Show BootstrapVaultRequest where
  show request =
    "BootstrapVaultRequest {bootstrapVaultUnlockPassword=<redacted>, bootstrapVaultLoopbackNodePortVerified="
      ++ show (bootstrapVaultLoopbackNodePortVerified request)
      ++ "}"

instance FromJSON BootstrapVaultRequest where
  parseJSON =
    withObject "BootstrapVaultRequest" $ \o ->
      BootstrapVaultRequest
        <$> o .: "unlock_password"
        <*> o .:? "loopback_nodeport_verified" .!= False

instance ToJSON BootstrapVaultRequest where
  toJSON request =
    object
      [ "unlock_password" .= bootstrapVaultUnlockPassword request
      , "loopback_nodeport_verified" .= bootstrapVaultLoopbackNodePortVerified request
      ]

data BootstrapVaultRotateUnlockBundleRequest = BootstrapVaultRotateUnlockBundleRequest
  { bootstrapVaultRotateCurrentPassword :: Text
  , bootstrapVaultRotateNewPassword :: Text
  , bootstrapVaultRotateLoopbackNodePortVerified :: Bool
  }
  deriving (Eq)

instance Show BootstrapVaultRotateUnlockBundleRequest where
  show request =
    "BootstrapVaultRotateUnlockBundleRequest {bootstrapVaultRotateCurrentPassword=<redacted>, bootstrapVaultRotateNewPassword=<redacted>, bootstrapVaultRotateLoopbackNodePortVerified="
      ++ show (bootstrapVaultRotateLoopbackNodePortVerified request)
      ++ "}"

instance FromJSON BootstrapVaultRotateUnlockBundleRequest where
  parseJSON =
    withObject "BootstrapVaultRotateUnlockBundleRequest" $ \o ->
      BootstrapVaultRotateUnlockBundleRequest
        <$> o .: "unlock_password"
        <*> o .: "new_unlock_password"
        <*> o .:? "loopback_nodeport_verified" .!= False

instance ToJSON BootstrapVaultRotateUnlockBundleRequest where
  toJSON request =
    object
      [ "unlock_password" .= bootstrapVaultRotateCurrentPassword request
      , "new_unlock_password" .= bootstrapVaultRotateNewPassword request
      , "loopback_nodeport_verified" .= bootstrapVaultRotateLoopbackNodePortVerified request
      ]

data BootstrapVaultRotateTransitKeyRequest = BootstrapVaultRotateTransitKeyRequest
  { bootstrapVaultRotateTransitPassword :: Text
  , bootstrapVaultRotateTransitKeyName :: Text
  , bootstrapVaultRotateTransitLoopbackNodePortVerified :: Bool
  }
  deriving (Eq)

instance Show BootstrapVaultRotateTransitKeyRequest where
  show request =
    "BootstrapVaultRotateTransitKeyRequest {bootstrapVaultRotateTransitPassword=<redacted>, bootstrapVaultRotateTransitKeyName="
      ++ show (bootstrapVaultRotateTransitKeyName request)
      ++ ", bootstrapVaultRotateTransitLoopbackNodePortVerified="
      ++ show (bootstrapVaultRotateTransitLoopbackNodePortVerified request)
      ++ "}"

instance FromJSON BootstrapVaultRotateTransitKeyRequest where
  parseJSON =
    withObject "BootstrapVaultRotateTransitKeyRequest" $ \o ->
      BootstrapVaultRotateTransitKeyRequest
        <$> o .: "unlock_password"
        <*> o .: "key_name"
        <*> o .:? "loopback_nodeport_verified" .!= False

instance ToJSON BootstrapVaultRotateTransitKeyRequest where
  toJSON request =
    object
      [ "unlock_password" .= bootstrapVaultRotateTransitPassword request
      , "key_name" .= bootstrapVaultRotateTransitKeyName request
      , "loopback_nodeport_verified" .= bootstrapVaultRotateTransitLoopbackNodePortVerified request
      ]

data BootstrapVaultResponse = BootstrapVaultResponse
  { bootstrapVaultResponseStatus :: Text
  , bootstrapVaultResponseAction :: Text
  , bootstrapVaultResponseReconcileStepCount :: Int
  }
  deriving (Eq, Show)

instance FromJSON BootstrapVaultResponse where
  parseJSON =
    withObject "BootstrapVaultResponse" $ \o ->
      BootstrapVaultResponse
        <$> o .: "status"
        <*> o .: "action"
        <*> o .: "reconcile_step_count"

instance ToJSON BootstrapVaultResponse where
  toJSON response =
    object
      [ "status" .= bootstrapVaultResponseStatus response
      , "action" .= bootstrapVaultResponseAction response
      , "reconcile_step_count" .= bootstrapVaultResponseReconcileStepCount response
      ]

data BootstrapVaultRequestError
  = BootstrapVaultMethodNotAllowed String
  | BootstrapVaultRequestTooLarge Int
  | BootstrapVaultRequestEmpty
  | BootstrapVaultRequestMalformed String
  | BootstrapVaultPasswordEmpty
  | BootstrapVaultLoopbackUnverified
  deriving (Eq, Show)

decodeBootstrapVaultRequest
  :: ByteString -> Either BootstrapVaultRequestError BootstrapVaultRequest
decodeBootstrapVaultRequest rawRequest
  | method /= "POST" = Left (BootstrapVaultMethodNotAllowed method)
  | ByteString.length body > bootstrapVaultRequestMaxBytes =
      Left (BootstrapVaultRequestTooLarge (ByteString.length body))
  | ByteString.null (ByteString8.dropWhile isSpace body) = Left BootstrapVaultRequestEmpty
  | otherwise =
      case eitherDecodeStrict' body of
        Left err -> Left (BootstrapVaultRequestMalformed err)
        Right request
          | Text.null (Text.strip (bootstrapVaultUnlockPassword request)) ->
              Left BootstrapVaultPasswordEmpty
          | not (bootstrapVaultLoopbackNodePortVerified request) ->
              Left BootstrapVaultLoopbackUnverified
          | otherwise -> Right request
 where
  method = legacyRequestMethod rawRequest
  body = legacyRequestBody rawRequest

decodeBootstrapVaultAuthenticatedRequest
  :: ByteString -> Either BootstrapVaultRequestError BootstrapVaultRequest
decodeBootstrapVaultAuthenticatedRequest = decodeBootstrapVaultRequest

decodeBootstrapVaultRotateUnlockBundleRequest
  :: ByteString
  -> Either BootstrapVaultRequestError BootstrapVaultRotateUnlockBundleRequest
decodeBootstrapVaultRotateUnlockBundleRequest rawRequest
  | method /= "POST" = Left (BootstrapVaultMethodNotAllowed method)
  | ByteString.length body > bootstrapVaultRequestMaxBytes =
      Left (BootstrapVaultRequestTooLarge (ByteString.length body))
  | ByteString.null (ByteString8.dropWhile isSpace body) = Left BootstrapVaultRequestEmpty
  | otherwise =
      case eitherDecodeStrict' body of
        Left err -> Left (BootstrapVaultRequestMalformed err)
        Right request
          | Text.null (Text.strip (bootstrapVaultRotateCurrentPassword request)) ->
              Left BootstrapVaultPasswordEmpty
          | Text.null (Text.strip (bootstrapVaultRotateNewPassword request)) ->
              Left BootstrapVaultPasswordEmpty
          | not (bootstrapVaultRotateLoopbackNodePortVerified request) ->
              Left BootstrapVaultLoopbackUnverified
          | otherwise -> Right request
 where
  method = legacyRequestMethod rawRequest
  body = legacyRequestBody rawRequest

decodeBootstrapVaultRotateTransitKeyRequest
  :: ByteString
  -> Either BootstrapVaultRequestError BootstrapVaultRotateTransitKeyRequest
decodeBootstrapVaultRotateTransitKeyRequest rawRequest
  | method /= "POST" = Left (BootstrapVaultMethodNotAllowed method)
  | ByteString.length body > bootstrapVaultRequestMaxBytes =
      Left (BootstrapVaultRequestTooLarge (ByteString.length body))
  | ByteString.null (ByteString8.dropWhile isSpace body) = Left BootstrapVaultRequestEmpty
  | otherwise =
      case eitherDecodeStrict' body of
        Left err -> Left (BootstrapVaultRequestMalformed err)
        Right request
          | Text.null (Text.strip (bootstrapVaultRotateTransitPassword request)) ->
              Left BootstrapVaultPasswordEmpty
          | Text.null (Text.strip (bootstrapVaultRotateTransitKeyName request)) ->
              Left (BootstrapVaultRequestMalformed "key_name must not be empty")
          | not (bootstrapVaultRotateTransitLoopbackNodePortVerified request) ->
              Left BootstrapVaultLoopbackUnverified
          | otherwise -> Right request
 where
  method = legacyRequestMethod rawRequest
  body = legacyRequestBody rawRequest

renderBootstrapVaultRequestError :: BootstrapVaultRequestError -> String
renderBootstrapVaultRequestError err = case err of
  BootstrapVaultMethodNotAllowed method ->
    "method " ++ method ++ " is not supported for " ++ bootstrapVaultPath
  BootstrapVaultRequestTooLarge size ->
    "bootstrap request body is too large: "
      ++ show size
      ++ " bytes; maximum is "
      ++ show bootstrapVaultRequestMaxBytes
  BootstrapVaultRequestEmpty ->
    "empty request body; expected JSON object with unlock_password and loopback_nodeport_verified"
  BootstrapVaultRequestMalformed detail ->
    "invalid bootstrap JSON body: " ++ detail
  BootstrapVaultPasswordEmpty ->
    "unlock_password must not be empty"
  BootstrapVaultLoopbackUnverified ->
    "loopback NodePort restriction is not verified; refusing password-bearing bootstrap route"

data BootstrapVaultEnsureError
  = BootstrapVaultEnsureVaultUnavailable String
  | BootstrapVaultEnsureBundleUnavailable String
  | BootstrapVaultEnsureUnsealFailed String
  | BootstrapVaultEnsureReconcileFailed String
  deriving (Eq, Show)

handleBootstrapVaultEnsure
  :: DaemonConfig
  -> (forall value. Text -> IO (Either String value) -> IO (Either String value))
  -> ByteString
  -> IO LegacyGatewayBootstrapResponse
handleBootstrapVaultEnsure config runChild rawRequest =
  case decodeBootstrapVaultRequest rawRequest of
    Left (BootstrapVaultMethodNotAllowed _) ->
      pure
        ( plainResponse
            405
            ( renderBootstrapVaultRequestError
                (BootstrapVaultMethodNotAllowed (legacyRequestMethod rawRequest))
            )
        )
    Left err -> pure (plainResponse 400 (renderBootstrapVaultRequestError err))
    Right request -> do
      result <- ensureBootstrapVault config runChild request
      pure $ case result of
        Left err -> bootstrapActionErrorResponse err
        Right response -> jsonResponse 200 (encode response)

handleBootstrapVaultStatus
  :: DaemonConfig -> ByteString -> IO LegacyGatewayBootstrapResponse
handleBootstrapVaultStatus config rawRequest =
  case legacyRequestMethod rawRequest of
    "GET" -> do
      result <- vaultSealStatus (bootstrapVaultAddress config)
      pure $ case result of
        Left err ->
          plainResponse 503 ("Vault status unavailable: " ++ renderHttpError err)
        Right status -> jsonResponse 200 (encode status)
    method ->
      pure
        ( plainResponse
            405
            ("method " ++ method ++ " is not supported for " ++ bootstrapVaultStatusPath)
        )

handleBootstrapVaultRotateUnlockBundle
  :: DaemonConfig
  -> (forall value. Text -> IO (Either String value) -> IO (Either String value))
  -> ByteString
  -> IO LegacyGatewayBootstrapResponse
handleBootstrapVaultRotateUnlockBundle config runChild rawRequest =
  case decodeBootstrapVaultRotateUnlockBundleRequest rawRequest of
    Left (BootstrapVaultMethodNotAllowed _) ->
      pure
        ( bootstrapRequestErrorResponse
            405
            (BootstrapVaultMethodNotAllowed (legacyRequestMethod rawRequest))
        )
    Left err -> pure (bootstrapRequestErrorResponse 400 err)
    Right request -> do
      result <- rotateBootstrapUnlockBundle config runChild request
      pure (bootstrapResultResponse result)

handleBootstrapVaultRotateTransitKey
  :: DaemonConfig
  -> (forall value. Text -> IO (Either String value) -> IO (Either String value))
  -> ByteString
  -> IO LegacyGatewayBootstrapResponse
handleBootstrapVaultRotateTransitKey config runChild rawRequest =
  case decodeBootstrapVaultRotateTransitKeyRequest rawRequest of
    Left (BootstrapVaultMethodNotAllowed _) ->
      pure
        ( bootstrapRequestErrorResponse
            405
            (BootstrapVaultMethodNotAllowed (legacyRequestMethod rawRequest))
        )
    Left err -> pure (bootstrapRequestErrorResponse 400 err)
    Right request -> do
      result <- rotateBootstrapTransitKey config runChild request
      pure (bootstrapResultResponse result)

handleBootstrapVaultPasswordAction
  :: ByteString
  -> (BootstrapVaultRequest -> IO (Either BootstrapVaultEnsureError LazyByteString.ByteString))
  -> IO LegacyGatewayBootstrapResponse
handleBootstrapVaultPasswordAction rawRequest action =
  case decodeBootstrapVaultAuthenticatedRequest rawRequest of
    Left (BootstrapVaultMethodNotAllowed _) ->
      pure
        ( bootstrapRequestErrorResponse
            405
            (BootstrapVaultMethodNotAllowed (legacyRequestMethod rawRequest))
        )
    Left err -> pure (bootstrapRequestErrorResponse 400 err)
    Right request -> bootstrapResultResponse <$> action request

bootstrapRequestErrorResponse
  :: Int -> BootstrapVaultRequestError -> LegacyGatewayBootstrapResponse
bootstrapRequestErrorResponse status =
  plainResponse status . renderBootstrapVaultRequestError

bootstrapResultResponse
  :: Either BootstrapVaultEnsureError LazyByteString.ByteString
  -> LegacyGatewayBootstrapResponse
bootstrapResultResponse result = case result of
  Left err -> bootstrapActionErrorResponse err
  Right body -> jsonResponse 200 body

bootstrapActionErrorResponse
  :: BootstrapVaultEnsureError -> LegacyGatewayBootstrapResponse
bootstrapActionErrorResponse err =
  let (status, message) = renderBootstrapVaultEnsureError err
   in plainResponse status message

renderBootstrapVaultEnsureError :: BootstrapVaultEnsureError -> (Int, String)
renderBootstrapVaultEnsureError err = case err of
  BootstrapVaultEnsureVaultUnavailable detail ->
    (503, "Vault bootstrap unavailable: " ++ detail)
  BootstrapVaultEnsureBundleUnavailable detail ->
    (503, "Vault bootstrap bundle unavailable: " ++ detail)
  BootstrapVaultEnsureUnsealFailed detail ->
    (502, "Vault unseal failed: " ++ detail)
  BootstrapVaultEnsureReconcileFailed detail ->
    (502, "Vault reconcile failed: " ++ detail)

encodeBootstrapActionResult
  :: Either BootstrapVaultEnsureError Value
  -> Either BootstrapVaultEnsureError LazyByteString.ByteString
encodeBootstrapActionResult = fmap encode

ensureBootstrapVault
  :: DaemonConfig
  -> (forall value. Text -> IO (Either String value) -> IO (Either String value))
  -> BootstrapVaultRequest
  -> IO (Either BootstrapVaultEnsureError BootstrapVaultResponse)
ensureBootstrapVault config runChild request = do
  statusResult <- vaultSealStatus address
  case statusResult of
    Left err ->
      pure (Left (BootstrapVaultEnsureVaultUnavailable (renderHttpError err)))
    Right status ->
      case bootstrapAction status of
        BootstrapInitialize -> initializeUnsealAndReconcile
        BootstrapUnseal -> unsealExistingAndReconcile status
        BootstrapReady -> reconcileReadyVault
 where
  address = bootstrapVaultAddress config
  minioConfig = bootstrapVaultObjectStoreConfig config
  password = bootstrapVaultUnlockPassword request

  initializeUnsealAndReconcile = do
    initResult <- vaultInit address defaultInitRequest
    case initResult of
      Left err ->
        pure (Left (BootstrapVaultEnsureVaultUnavailable (renderHttpError err)))
      Right initResponse -> do
        now <- getCurrentTime
        let bundle =
              initResponseToUnlockBundle
                (Text.pack (daemonNodeId config))
                address
                (Text.pack (formatShow iso8601Format now))
                initResponse
        encrypted <- encryptUnlockBundle password bundle
        case encrypted of
          Left err ->
            pure
              ( Left
                  ( BootstrapVaultEnsureBundleUnavailable
                      ("unlock bundle encryption failed: " ++ renderUnlockBundleError err)
                  )
              )
          Right envelopeBytes -> do
            writeResult <-
              runChild
                "vault-bootstrap-bundle-write"
                (putAndVerifyBootstrapBundle minioConfig password envelopeBytes)
            case writeResult of
              Left err -> pure (Left (BootstrapVaultEnsureBundleUnavailable err))
              Right () -> do
                currentStatus <- vaultSealStatus address
                case currentStatus of
                  Left err ->
                    pure
                      (Left (BootstrapVaultEnsureVaultUnavailable (renderHttpError err)))
                  Right sealedStatus -> do
                    unsealResult <- submitBootstrapUnsealSteps address sealedStatus bundle
                    case unsealResult of
                      Left err -> pure (Left (BootstrapVaultEnsureUnsealFailed err))
                      Right () ->
                        reconcileWithRootToken
                          "initialized-unsealed-reconciled"
                          (VaultToken (unlockBundleInitialRootToken bundle))

  unsealExistingAndReconcile status = do
    bundleResult <-
      runChild
        "vault-bootstrap-bundle-read"
        (readBootstrapBundle minioConfig password)
    case bundleResult of
      Left err -> pure (Left (BootstrapVaultEnsureBundleUnavailable err))
      Right bundle -> do
        unsealResult <- submitBootstrapUnsealSteps address status bundle
        case unsealResult of
          Left err -> pure (Left (BootstrapVaultEnsureUnsealFailed err))
          Right () ->
            reconcileWithRootToken
              "unsealed-reconciled"
              (VaultToken (unlockBundleInitialRootToken bundle))

  reconcileReadyVault = do
    bundleResult <-
      runChild
        "vault-bootstrap-bundle-read"
        (readBootstrapBundle minioConfig password)
    case bundleResult of
      Left err -> pure (Left (BootstrapVaultEnsureBundleUnavailable err))
      Right bundle ->
        reconcileWithRootToken
          "reconciled"
          (VaultToken (unlockBundleInitialRootToken bundle))

  reconcileWithRootToken actionName token = do
    reconcileResult <- runVaultReconcile address token defaultVaultReconcilePlan
    pure $ case reconcileResult of
      Left err ->
        Left (BootstrapVaultEnsureReconcileFailed (renderVaultReconcileError err))
      Right steps ->
        Right
          BootstrapVaultResponse
            { bootstrapVaultResponseStatus = "ready"
            , bootstrapVaultResponseAction = actionName
            , bootstrapVaultResponseReconcileStepCount = length steps
            }

sealBootstrapVault
  :: DaemonConfig
  -> (forall value. Text -> IO (Either String value) -> IO (Either String value))
  -> BootstrapVaultRequest
  -> IO (Either BootstrapVaultEnsureError Value)
sealBootstrapVault config runChild request = do
  tokenResult <-
    bootstrapRootToken config runChild (bootstrapVaultUnlockPassword request)
  case tokenResult of
    Left err -> pure (Left err)
    Right token -> do
      result <- vaultSeal (bootstrapVaultAddress config) token
      pure $ case result of
        Left err -> Left (BootstrapVaultEnsureVaultUnavailable (renderHttpError err))
        Right () ->
          Right
            ( object
                [ "status" .= ("sealed" :: Text)
                , "action" .= ("sealed" :: Text)
                ]
            )

rotateBootstrapUnlockBundle
  :: DaemonConfig
  -> (forall value. Text -> IO (Either String value) -> IO (Either String value))
  -> BootstrapVaultRotateUnlockBundleRequest
  -> IO (Either BootstrapVaultEnsureError LazyByteString.ByteString)
rotateBootstrapUnlockBundle config runChild request = do
  bundleResult <-
    runChild
      "vault-bootstrap-bundle-read"
      (readBootstrapBundle minioConfig (bootstrapVaultRotateCurrentPassword request))
  case bundleResult of
    Left err -> pure (Left (BootstrapVaultEnsureBundleUnavailable err))
    Right bundle -> do
      encrypted <- encryptUnlockBundle (bootstrapVaultRotateNewPassword request) bundle
      case encrypted of
        Left err ->
          pure
            ( Left
                ( BootstrapVaultEnsureBundleUnavailable
                    ("unlock bundle encryption failed: " ++ renderUnlockBundleError err)
                )
            )
        Right envelopeBytes -> do
          writeResult <-
            runChild "vault-bootstrap-bundle-write" $
              putAndVerifyBootstrapBundle
                minioConfig
                (bootstrapVaultRotateNewPassword request)
                envelopeBytes
          pure $ case writeResult of
            Left err -> Left (BootstrapVaultEnsureBundleUnavailable err)
            Right () ->
              Right
                ( encode
                    ( object
                        [ "status" .= ("ready" :: Text)
                        , "action" .= ("unlock-bundle-rotated" :: Text)
                        ]
                    )
                )
 where
  minioConfig = bootstrapVaultObjectStoreConfig config

rotateBootstrapTransitKey
  :: DaemonConfig
  -> (forall value. Text -> IO (Either String value) -> IO (Either String value))
  -> BootstrapVaultRotateTransitKeyRequest
  -> IO (Either BootstrapVaultEnsureError LazyByteString.ByteString)
rotateBootstrapTransitKey config runChild request = do
  tokenResult <-
    bootstrapRootToken config runChild (bootstrapVaultRotateTransitPassword request)
  case tokenResult of
    Left err -> pure (Left err)
    Right token -> do
      result <-
        vaultRotateTransitKey
          (bootstrapVaultAddress config)
          token
          (bootstrapVaultRotateTransitKeyName request)
      pure $ case result of
        Left err -> Left (BootstrapVaultEnsureVaultUnavailable (renderHttpError err))
        Right () ->
          Right
            ( encode
                ( object
                    [ "status" .= ("ready" :: Text)
                    , "action" .= ("transit-key-rotated" :: Text)
                    , "key_name" .= bootstrapVaultRotateTransitKeyName request
                    ]
                )
            )

bootstrapVaultPkiStatus
  :: DaemonConfig
  -> (forall value. Text -> IO (Either String value) -> IO (Either String value))
  -> BootstrapVaultRequest
  -> IO (Either BootstrapVaultEnsureError Value)
bootstrapVaultPkiStatus config runChild request = do
  tokenResult <-
    bootstrapRootToken config runChild (bootstrapVaultUnlockPassword request)
  case tokenResult of
    Left err -> pure (Left err)
    Right token -> do
      mountsResult <- vaultListMounts (bootstrapVaultAddress config) token
      pure $ case mountsResult of
        Left err -> Left (BootstrapVaultEnsureVaultUnavailable (renderHttpError err))
        Right mounts ->
          case Map.lookup "pki" mounts of
            Nothing ->
              Right
                ( object
                    [ "status" .= ("missing" :: Text)
                    , "mount" .= ("pki" :: Text)
                    ]
                )
            Just mount ->
              Right
                ( object
                    [ "status" .= ("present" :: Text)
                    , "mount" .= ("pki" :: Text)
                    , "type" .= vaultMountType mount
                    ]
                )

bootstrapVaultPkiIssueTestCert
  :: DaemonConfig
  -> (forall value. Text -> IO (Either String value) -> IO (Either String value))
  -> BootstrapVaultRequest
  -> IO (Either BootstrapVaultEnsureError Value)
bootstrapVaultPkiIssueTestCert config runChild request = do
  tokenResult <-
    bootstrapRootToken config runChild (bootstrapVaultUnlockPassword request)
  case tokenResult of
    Left err -> pure (Left err)
    Right token -> do
      result <-
        vaultPkiIssueTestCertificate
          (bootstrapVaultAddress config)
          token
          "prodbox-test"
          "prodbox-vault-test.internal"
          "1m"
      pure $ case result of
        Left err -> Left (BootstrapVaultEnsureVaultUnavailable (renderHttpError err))
        Right certPem ->
          Right
            ( object
                [ "status" .= ("issued" :: Text)
                , "certificate" .= certPem
                ]
            )

bootstrapRootToken
  :: DaemonConfig
  -> (forall value. Text -> IO (Either String value) -> IO (Either String value))
  -> Text
  -> IO (Either BootstrapVaultEnsureError VaultToken)
bootstrapRootToken config runChild password = do
  bundleResult <-
    runChild
      "vault-bootstrap-bundle-read"
      (readBootstrapBundle (bootstrapVaultObjectStoreConfig config) password)
  pure $ case bundleResult of
    Left err -> Left (BootstrapVaultEnsureBundleUnavailable err)
    Right bundle -> Right (VaultToken (unlockBundleInitialRootToken bundle))

bootstrapVaultAddress :: DaemonConfig -> VaultAddress
bootstrapVaultAddress config =
  case daemonVaultAuth config of
    Just auth -> VaultAddress (Text.pack (gatewayVaultAddress auth))
    Nothing -> VaultAddress "http://vault.vault.svc.cluster.local:8200"

bootstrapVaultObjectStoreConfig :: DaemonConfig -> ObjectStoreConfig
bootstrapVaultObjectStoreConfig config =
  bootstrapObjectStoreConfigWithEndpoint
    (maybe "http://minio.prodbox.svc.cluster.local:9000" id (daemonMinioEndpointUrl config))

putAndVerifyBootstrapBundle
  :: ObjectStoreConfig
  -> Text
  -> ByteString
  -> IO (Either String ())
putAndVerifyBootstrapBundle config password envelopeBytes = do
  putResult <- putBundleObject config envelopeBytes
  case putResult of
    Left err -> pure (Left ("write failed: " ++ err))
    Right () -> do
      readResult <- getBundleObject config
      pure $ case readResult of
        Left err -> Left ("read-back failed: " ++ err)
        Right Nothing -> Left "read-back returned no bootstrap unlock bundle"
        Right (Just bytes) ->
          case decryptUnlockBundle password bytes of
            Right _ -> Right ()
            Left err ->
              Left ("read-back did not decrypt: " ++ renderUnlockBundleError err)

readBootstrapBundle
  :: ObjectStoreConfig
  -> Text
  -> IO (Either String UnlockBundle)
readBootstrapBundle config password = do
  result <- getBundleObject config
  pure $ case result of
    Left err -> Left ("read failed: " ++ err)
    Right Nothing -> Left "bootstrap unlock bundle is absent"
    Right (Just bytes) ->
      case decryptUnlockBundle password bytes of
        Left err -> Left ("unlock bundle did not decrypt: " ++ renderUnlockBundleError err)
        Right bundle -> Right bundle

submitBootstrapUnsealSteps
  :: VaultAddress
  -> SealStatus
  -> UnlockBundle
  -> IO (Either String ())
submitBootstrapUnsealSteps address status bundle =
  case planUnseal status (unlockBundleUnsealKeys bundle) of
    Left err -> pure (Left ("unseal plan failed: " ++ err))
    Right steps -> go steps
 where
  go [] =
    pure (Left "unseal consumed every key share but Vault is still sealed")
  go (step : rest) = do
    result <- vaultSubmitUnseal address (unsealStepKey step)
    case result of
      Left err -> pure (Left ("unseal submission failed: " ++ renderHttpError err))
      Right newStatus ->
        case interpretUnsealProgress newStatus step of
          UnsealCompleted -> pure (Right ())
          UnsealAdvanced _ -> go rest
          UnsealStalled ->
            pure (Left "unseal stalled; a key share did not advance progress")

legacyRequestMethod :: ByteString -> String
legacyRequestMethod rawRequest =
  case words (takeWhile (/= '\r') (takeWhile (/= '\n') (ByteString8.unpack rawRequest))) of
    method : _ -> method
    _ -> "GET"

legacyRequestBody :: ByteString -> ByteString
legacyRequestBody rawRequest =
  case ByteString.breakSubstring crlfCrlf rawRequest of
    (_, rest)
      | ByteString.null rest -> ByteString.empty
      | otherwise -> ByteString.drop (ByteString.length crlfCrlf) rest
 where
  crlfCrlf = ByteString8.pack "\r\n\r\n"

plainResponse :: Int -> String -> LegacyGatewayBootstrapResponse
plainResponse status message =
  LegacyGatewayBootstrapResponse
    { legacyGatewayBootstrapStatus = status
    , legacyGatewayBootstrapContentType = "text/plain"
    , legacyGatewayBootstrapBody = LazyByteString.fromStrict (ByteString8.pack (message ++ "\n"))
    }

jsonResponse
  :: Int -> LazyByteString.ByteString -> LegacyGatewayBootstrapResponse
jsonResponse status body =
  LegacyGatewayBootstrapResponse
    { legacyGatewayBootstrapStatus = status
    , legacyGatewayBootstrapContentType = "application/json"
    , legacyGatewayBootstrapBody = body
    }
