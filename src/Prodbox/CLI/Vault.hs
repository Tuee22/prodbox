{-# LANGUAGE OverloadedStrings #-}

-- | Host controller for the closed Bootstrap Broker Vault surface. Every
-- lifecycle request uses a fresh custom-audience ServiceAccount credential and
-- a loopback-only Service port-forward. Operator password/key-name bytes bypass
-- the long-lived Broker and enter only an exact attested one-shot worker.
module Prodbox.CLI.Vault
  ( runVaultCommand
  , lifecycleProviderAwsVaultFields
  , gatewayEndpointFromEnv
  , runVaultBootstrapViaBroker
  , BrokerVaultSealStatus (..)
  , observeBrokerVaultSealStatus
  )
where

import Control.Concurrent.Async (Async, waitEither, withAsync)
import Crypto.Random (getRandomBytes)
import Data.Aeson
  ( Value
  , encode
  , object
  , withObject
  , (.:)
  , (.=)
  )
import Data.Aeson.Types (parseEither)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.ByteString.Lazy.Char8 qualified as LazyByteString8
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Bootstrap.Broker.Client
  ( BrokerActionRequest
  , BrokerCallContext
  , BrokerEndpoint
  , BrokerError
  , brokerRequestDigestForAction
  , initializeVault
  , issueVaultPkiTestCert
  , mkBrokerActionRequest
  , queryVaultPkiStatus
  , queryVaultStatus
  , reconcileVaultBaseline
  , renderBrokerError
  , rotateVaultTransitKey
  , rotateVaultUnlockBundle
  , sealVault
  , unsealVault
  )
import Prodbox.Bootstrap.Broker.HostSecretWorker
  ( HostSecretWorkerConnection (..)
  , HostSecretWorkerExpectation
  , deliverHostSecretWorkerPayloadAfter
  , mkHostSecretWorkerExpectation
  , renderHostSecretWorkerError
  )
import Prodbox.Bootstrap.Broker.PortForward
  ( BrokerHostConnection (..)
  , renderBrokerHostConnectionError
  , withBrokerHostConnection
  )
import Prodbox.Bootstrap.Broker.Program
  ( PkiIssueRequest
  , mkPkiIssueRequest
  )
import Prodbox.Bootstrap.Broker.Request
  ( IdempotencyKey
  , RequestDigest
  , SecretPayload
  , mkIdempotencyKey
  , mkSecretPayload
  , renderRequestDigest
  , requestDigestForBytes
  )
import Prodbox.Bootstrap.Broker.Routes
  ( BrokerRoute (..)
  , brokerRoutePath
  )
import Prodbox.Bootstrap.Broker.SecretWorker
  ( SecretWorkerOperation (..)
  , WorkerPodUid
  , secretWorkerRequestPodUid
  )
import Prodbox.Bootstrap.Broker.Types
  ( ArtifactDigest
  , VaultStorageGeneration
  , mkArtifactDigest
  , mkVaultStorageGeneration
  )
import Prodbox.CLI.Command (VaultCommand (..))
import Prodbox.CLI.Output (writeOutput)
import Prodbox.Gateway.Client qualified as GatewayClient
import Prodbox.Gateway.Types (PeerEndpoint)
import Prodbox.Host (defaultGatewayNodePort)
import Prodbox.Settings qualified as Settings
import Prodbox.Settings.SecretRef
  ( SecretRef (..)
  , VaultSecretRef (..)
  )
import Prodbox.Vault.Host
  ( obtainNewOperatorPassword
  , obtainOperatorPassword
  )
import System.Environment (lookupEnv)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))

gatewayEndpointFromEnv :: IO PeerEndpoint
gatewayEndpointFromEnv = do
  override <- lookupEnv "PRODBOX_TEST_GATEWAY_NODEPORT"
  let port = maybe defaultGatewayNodePort parseGatewayNodePort override
  pure (GatewayClient.hostLoopbackGatewayEndpoint port)

parseGatewayNodePort :: String -> Int
parseGatewayNodePort raw =
  case reads raw of
    [(port, "")] | port > 0 -> port
    _ -> defaultGatewayNodePort

runVaultCommand :: FilePath -> VaultCommand -> IO ExitCode
runVaultCommand repoRoot command =
  case command of
    VaultStatus -> runBrokerVaultStatus repoRoot
    VaultInit -> runBrokerVaultInitialize repoRoot
    VaultUnseal -> runBrokerVaultUnseal repoRoot
    VaultReconcile -> runBrokerVaultBaselineReconcile repoRoot
    VaultSeal -> runBrokerVaultSeal repoRoot
    VaultRotateUnlockBundle -> runBrokerVaultRotateUnlockBundle repoRoot
    VaultRotateTransitKey keyName ->
      runBrokerVaultRotateTransitKey repoRoot (Text.pack keyName)
    VaultPkiStatus -> runBrokerVaultPkiStatus repoRoot
    VaultPkiIssueTestCert -> runBrokerVaultPkiIssueTestCert repoRoot

runVaultBootstrapViaBroker :: FilePath -> IO ExitCode
runVaultBootstrapViaBroker repoRoot = do
  initial <- queryObservedBrokerStatus repoRoot
  case initial of
    Left err -> failBrokerCommand "Vault bootstrap" err
    Right status
      | observedInitializationAmbiguous status ->
          failBrokerCommand
            "Vault bootstrap"
            "Broker reports an ambiguous initialization; use the typed reset/recovery workflow before retrying"
      | otherwise -> do
          payloadResult <-
            if not (observedInitialized status)
              then newOperatorPasswordPayload repoRoot
              else
                if observedSealed status
                  then operatorPasswordPayload repoRoot
                  else pure (Right Nothing)
          case payloadResult of
            Left err -> failBrokerCommand "Vault bootstrap" err
            Right maybePayload -> do
              initialized <-
                if observedInitialized status
                  then pure ExitSuccess
                  else case maybePayload of
                    Nothing -> failBrokerCommand "Vault initialize" "operator password was not acquired"
                    Just payload -> runBrokerVaultInitializeWith repoRoot status payload
              case initialized of
                ExitFailure _ -> pure initialized
                ExitSuccess -> do
                  afterInit <- queryObservedBrokerStatus repoRoot
                  case afterInit of
                    Left err -> failBrokerCommand "Vault bootstrap" err
                    Right current -> do
                      unsealed <-
                        if observedSealed current
                          then case maybePayload of
                            Nothing -> failBrokerCommand "Vault unseal" "operator password was not acquired"
                            Just payload -> runBrokerVaultUnsealWith repoRoot current payload
                          else pure ExitSuccess
                      case unsealed of
                        ExitFailure _ -> pure unsealed
                        ExitSuccess -> case maybePayload of
                          Just payload ->
                            runBrokerVaultBaselineReconcileWith repoRoot current payload
                          Nothing -> runBrokerVaultBaselineReconcile repoRoot

runBrokerVaultStatus :: FilePath -> IO ExitCode
runBrokerVaultStatus repoRoot = do
  result <- brokerQuery repoRoot queryVaultStatus
  case result of
    Left err -> failBrokerCommand "Vault status" err
    Right response -> writeBrokerSuccess "Vault status" response

runBrokerVaultInitialize :: FilePath -> IO ExitCode
runBrokerVaultInitialize repoRoot = do
  observed <- queryObservedBrokerStatus repoRoot
  case observed of
    Left err -> failBrokerCommand "Vault initialize" err
    Right status
      | observedInitialized status -> do
          writeOutput "Vault already initialized."
          pure ExitSuccess
      | observedInitializationAmbiguous status ->
          failBrokerCommand "Vault initialize" "Broker reports an ambiguous initialization"
      | otherwise -> do
          payloadResult <- newOperatorPasswordPayload repoRoot
          case payloadResult of
            Left err -> failBrokerCommand "Vault initialize" err
            Right Nothing -> failBrokerCommand "Vault initialize" "operator password was not acquired"
            Right (Just payload) -> runBrokerVaultInitializeWith repoRoot status payload

runBrokerVaultInitializeWith
  :: FilePath -> ObservedBrokerStatus -> SecretPayload -> IO ExitCode
runBrokerVaultInitializeWith repoRoot status payload =
  runSecretBrokerMutation
    repoRoot
    BrokerVaultInitialize
    (observedStorageGeneration status)
    "initialize"
    [ SecretWorkerPrepareInitialization
    , SecretWorkerResumeInitialization
    , SecretWorkerInitialize
    , SecretWorkerFinalizeInitialization
    ]
    payload
    initializeVault

runBrokerVaultUnseal :: FilePath -> IO ExitCode
runBrokerVaultUnseal repoRoot = do
  observed <- queryObservedBrokerStatus repoRoot
  case observed of
    Left err -> failBrokerCommand "Vault unseal" err
    Right status
      | not (observedInitialized status) ->
          failBrokerCommand "Vault unseal" "Vault is not initialized"
      | not (observedSealed status) -> do
          writeOutput "Vault already unsealed."
          pure ExitSuccess
      | otherwise -> do
          payloadResult <- operatorPasswordPayload repoRoot
          case payloadResult of
            Left err -> failBrokerCommand "Vault unseal" err
            Right Nothing -> failBrokerCommand "Vault unseal" "operator password was not acquired"
            Right (Just payload) -> runBrokerVaultUnsealWith repoRoot status payload

runBrokerVaultUnsealWith
  :: FilePath -> ObservedBrokerStatus -> SecretPayload -> IO ExitCode
runBrokerVaultUnsealWith repoRoot status payload =
  runSecretBrokerMutation
    repoRoot
    BrokerVaultUnseal
    (observedStorageGeneration status)
    "unseal"
    [SecretWorkerUnseal]
    payload
    unsealVault

runBrokerVaultBaselineReconcile :: FilePath -> IO ExitCode
runBrokerVaultBaselineReconcile repoRoot = do
  observed <- queryObservedBrokerStatus repoRoot
  case observed of
    Left err -> failBrokerCommand "Vault baseline reconcile" err
    Right status -> do
      payloadResult <- operatorPasswordPayload repoRoot
      case payloadResult of
        Left err -> failBrokerCommand "Vault baseline reconcile" err
        Right Nothing ->
          failBrokerCommand
            "Vault baseline reconcile"
            "operator password was not acquired"
        Right (Just payload) ->
          runBrokerVaultBaselineReconcileWith repoRoot status payload

runBrokerVaultBaselineReconcileWith
  :: FilePath -> ObservedBrokerStatus -> SecretPayload -> IO ExitCode
runBrokerVaultBaselineReconcileWith repoRoot status payload =
  runSecretBrokerMutation
    repoRoot
    BrokerVaultBaselineReconcile
    (observedStorageGeneration status)
    "baseline-reconcile"
    [SecretWorkerCompleteGeneratedRoot]
    payload
    reconcileVaultBaseline

runBrokerVaultSeal :: FilePath -> IO ExitCode
runBrokerVaultSeal repoRoot =
  runObservedBrokerMutation
    repoRoot
    "Vault seal"
    BrokerVaultSeal
    "seal"
    sealVault

runBrokerVaultRotateUnlockBundle :: FilePath -> IO ExitCode
runBrokerVaultRotateUnlockBundle repoRoot = do
  observed <- queryObservedBrokerStatus repoRoot
  case observed of
    Left err -> failBrokerCommand "Vault unlock-bundle rotation" err
    Right status -> do
      current <- obtainOperatorPassword repoRoot
      replacement <- obtainNewOperatorPassword repoRoot
      case (current, replacement) of
        (Left err, _) -> failBrokerCommand "Vault unlock-bundle rotation" err
        (_, Left err) -> failBrokerCommand "Vault unlock-bundle rotation" err
        (Right currentPassword, Right newPassword) ->
          case secretPayloadFromBytes
            ( LazyByteString.toStrict
                ( encode
                    ( object
                        [ "schema_version" .= (1 :: Int)
                        , "current_password" .= currentPassword
                        , "new_password" .= newPassword
                        ]
                    )
                )
            ) of
            Left err -> failBrokerCommand "Vault unlock-bundle rotation" err
            Right payload ->
              runSecretBrokerMutation
                repoRoot
                BrokerVaultRotateUnlockBundle
                (observedStorageGeneration status)
                "rotate-unlock-bundle"
                [SecretWorkerRotateUnlockBundle]
                payload
                rotateVaultUnlockBundle

runBrokerVaultRotateTransitKey :: FilePath -> Text -> IO ExitCode
runBrokerVaultRotateTransitKey repoRoot keyName = do
  observed <- queryObservedBrokerStatus repoRoot
  case observed of
    Left err -> failBrokerCommand label err
    Right status ->
      case secretPayloadFromBytes (TextEncoding.encodeUtf8 keyName) of
        Left err -> failBrokerCommand label err
        Right payload ->
          runSecretBrokerMutation
            repoRoot
            BrokerVaultRotateTransitKey
            (observedStorageGeneration status)
            ("rotate-transit-key:" <> keyName)
            [SecretWorkerRotateTransitKey]
            payload
            rotateVaultTransitKey
 where
  label = "Vault Transit-key rotation"

runBrokerVaultPkiStatus :: FilePath -> IO ExitCode
runBrokerVaultPkiStatus repoRoot = do
  result <- brokerQuery repoRoot queryVaultPkiStatus
  case result of
    Left err -> failBrokerCommand "Vault PKI status" err
    Right response -> writeBrokerSuccess "Vault PKI status" response

runBrokerVaultPkiIssueTestCert :: FilePath -> IO ExitCode
runBrokerVaultPkiIssueTestCert repoRoot = do
  observed <- queryObservedBrokerStatus repoRoot
  case observed of
    Left err -> failBrokerCommand "Vault PKI test-certificate issue" err
    Right status ->
      case mkPkiIssueRequest "prodbox-vault-test.internal" 60 of
        Left err -> failBrokerCommand "Vault PKI test-certificate issue" err
        Right pkiRequest ->
          runPkiBrokerMutation repoRoot status pkiRequest

data ObservedBrokerStatus = ObservedBrokerStatus
  { observedStorageGeneration :: !VaultStorageGeneration
  , observedInitialized :: !Bool
  , observedSealed :: !Bool
  , observedInitializationAmbiguous :: !Bool
  }

-- | Secret-free status projection used by lifecycle readiness gates. Storage
-- generation stays internal to lifecycle mutations; readiness only needs the
-- exact initialized/sealed/ambiguity classification returned by the Broker.
data BrokerVaultSealStatus = BrokerVaultSealStatus
  { brokerVaultStatusInitialized :: !Bool
  , brokerVaultStatusSealed :: !Bool
  , brokerVaultStatusInitializationAmbiguous :: !Bool
  }
  deriving (Eq, Show)

decodeObservedBrokerStatus :: Value -> Either String ObservedBrokerStatus
decodeObservedBrokerStatus =
  parseEither $ withObject "Bootstrap Broker Vault status" $ \fields -> do
    rawGeneration <- fields .: "storage_generation"
    generation <- either fail pure (firstShow (mkVaultStorageGeneration rawGeneration))
    ObservedBrokerStatus generation
      <$> fields .: "initialized"
      <*> fields .: "sealed"
      <*> fields .: "initialization_ambiguous"

queryObservedBrokerStatus :: FilePath -> IO (Either String ObservedBrokerStatus)
queryObservedBrokerStatus repoRoot = do
  result <- brokerQuery repoRoot queryVaultStatus
  pure (result >>= decodeObservedBrokerStatus)

observeBrokerVaultSealStatus :: FilePath -> IO (Either String BrokerVaultSealStatus)
observeBrokerVaultSealStatus repoRoot =
  fmap project <$> queryObservedBrokerStatus repoRoot
 where
  project status =
    BrokerVaultSealStatus
      { brokerVaultStatusInitialized = observedInitialized status
      , brokerVaultStatusSealed = observedSealed status
      , brokerVaultStatusInitializationAmbiguous =
          observedInitializationAmbiguous status
      }

type BrokerQuery =
  BrokerEndpoint
  -> BrokerCallContext
  -> IO (Either BrokerError Value)

type BrokerMutation =
  BrokerEndpoint
  -> BrokerCallContext
  -> BrokerActionRequest
  -> IO (Either BrokerError Value)

brokerQuery :: FilePath -> BrokerQuery -> IO (Either String Value)
brokerQuery repoRoot query = do
  keyResult <- freshVaultIdempotencyKey
  case keyResult of
    Left err -> pure (Left err)
    Right key -> do
      connected <-
        withBrokerHostConnection
          (brokerHostConnection repoRoot)
          key
          (\endpoint context -> query endpoint context)
      pure $ case connected of
        Left err -> Left (renderBrokerHostConnectionError err)
        Right result -> either (Left . renderBrokerError) Right result

runObservedBrokerMutation
  :: FilePath
  -> String
  -> BrokerRoute
  -> Text
  -> BrokerMutation
  -> IO ExitCode
runObservedBrokerMutation repoRoot label route actionBinding mutation = do
  observed <- queryObservedBrokerStatus repoRoot
  case observed of
    Left err -> failBrokerCommand label err
    Right status ->
      runBrokerMutation
        repoRoot
        label
        route
        (observedStorageGeneration status)
        actionBinding
        mutation

runBrokerMutation
  :: FilePath
  -> String
  -> BrokerRoute
  -> VaultStorageGeneration
  -> Text
  -> BrokerMutation
  -> IO ExitCode
runBrokerMutation repoRoot label route generation actionBinding mutation =
  case prepareBrokerAction route generation actionBinding of
    Left err -> failBrokerCommand label err
    Right (action, _, _) -> do
      keyResult <- freshVaultIdempotencyKey
      case keyResult of
        Left err -> failBrokerCommand label err
        Right key -> do
          connected <-
            withBrokerHostConnection
              (brokerHostConnection repoRoot)
              key
              (\endpoint context -> mutation endpoint context action)
          case connected of
            Left err -> failBrokerCommand label (renderBrokerHostConnectionError err)
            Right (Left err) -> failBrokerCommand label (renderBrokerError err)
            Right (Right response) -> writeBrokerSuccess label response

runSecretBrokerMutation
  :: FilePath
  -> BrokerRoute
  -> VaultStorageGeneration
  -> Text
  -> [SecretWorkerOperation]
  -> SecretPayload
  -> BrokerMutation
  -> IO ExitCode
runSecretBrokerMutation repoRoot route generation actionBinding operations payload mutation =
  case prepareBrokerAction route generation actionBinding of
    Left err -> failBrokerCommand label err
    Right (action, actionDigest, requestDigest) -> do
      keyResult <- freshVaultIdempotencyKey
      case keyResult of
        Left err -> failBrokerCommand label err
        Right key -> do
          let expectations =
                map
                  ( \operation ->
                      mkHostSecretWorkerExpectation
                        operation
                        actionDigest
                        requestDigest
                        generation
                  )
                  operations
          connected <-
            withBrokerHostConnection
              (brokerHostConnection repoRoot)
              key
              ( \endpoint context ->
                  withAsync (mutation endpoint context action) $ \pending ->
                    awaitSecretMutation
                      (hostSecretWorkerConnection repoRoot)
                      expectations
                      payload
                      pending
                      Nothing
                      0
              )
          case connected of
            Left err -> failBrokerCommand label (renderBrokerHostConnectionError err)
            Right (Left err) -> failBrokerCommand label err
            Right (Right response) -> writeBrokerSuccess label response
 where
  label = "Vault " ++ Text.unpack actionBinding

awaitSecretMutation
  :: HostSecretWorkerConnection
  -> [HostSecretWorkerExpectation]
  -> SecretPayload
  -> Async (Either BrokerError Value)
  -> Maybe WorkerPodUid
  -> Int
  -> IO (Either String Value)
awaitSecretMutation connection expectations payload pending priorUid deliveryCount
  | deliveryCount >= maximumSecretWorkerDeliveries =
      pure (Left "Bootstrap Broker exceeded the bounded one-shot worker sequence")
  | otherwise =
      withAsync
        (deliverHostSecretWorkerPayloadAfter connection priorUid expectations payload)
        ( \delivery -> do
            completed <- waitEither pending delivery
            case completed of
              Left result -> pure (either (Left . renderBrokerError) Right result)
              Right (Left err) -> pure (Left (renderHostSecretWorkerError err))
              Right (Right request) ->
                awaitSecretMutation
                  connection
                  expectations
                  payload
                  pending
                  (Just (secretWorkerRequestPodUid request))
                  (deliveryCount + 1)
        )

maximumSecretWorkerDeliveries :: Int
maximumSecretWorkerDeliveries = 8

runPkiBrokerMutation
  :: FilePath -> ObservedBrokerStatus -> PkiIssueRequest -> IO ExitCode
runPkiBrokerMutation repoRoot status pkiRequest = do
  let route = BrokerVaultPkiIssueTestCertificate
      generation = observedStorageGeneration status
  case actionDigestFor route "pki-issue:prodbox-vault-test.internal:60" of
    Left err -> failBrokerCommand label err
    Right actionDigest -> do
      let action = mkBrokerActionRequest generation actionDigest
      keyResult <- freshVaultIdempotencyKey
      case keyResult of
        Left err -> failBrokerCommand label err
        Right key -> do
          connected <-
            withBrokerHostConnection
              (brokerHostConnection repoRoot)
              key
              ( \endpoint context ->
                  issueVaultPkiTestCert endpoint context action pkiRequest
              )
          case connected of
            Left err -> failBrokerCommand label (renderBrokerHostConnectionError err)
            Right (Left err) -> failBrokerCommand label (renderBrokerError err)
            Right (Right response) -> writeBrokerSuccess label response
 where
  label = "Vault PKI test-certificate issue"

prepareBrokerAction
  :: BrokerRoute
  -> VaultStorageGeneration
  -> Text
  -> Either String (BrokerActionRequest, ArtifactDigest, RequestDigest)
prepareBrokerAction route generation actionBinding = do
  digest <- actionDigestFor route actionBinding
  let action = mkBrokerActionRequest generation digest
  requestDigest <- firstShow (brokerRequestDigestForAction route action)
  Right (action, digest, requestDigest)

actionDigestFor :: BrokerRoute -> Text -> Either String ArtifactDigest
actionDigestFor route binding =
  firstShow
    ( mkArtifactDigest
        ( renderRequestDigest
            ( requestDigestForBytes
                ( TextEncoding.encodeUtf8
                    ( "prodbox-bootstrap-broker-host-action-v1:"
                        <> Text.pack (brokerRoutePath route)
                        <> ":"
                        <> binding
                    )
                )
            )
        )
    )

freshVaultIdempotencyKey :: IO (Either String IdempotencyKey)
freshVaultIdempotencyKey = do
  randomBytes <- getRandomBytes 32 :: IO ByteString
  pure
    ( mkIdempotencyKey
        ("vault-" <> renderRequestDigest (requestDigestForBytes randomBytes))
    )

operatorPasswordPayload :: FilePath -> IO (Either String (Maybe SecretPayload))
operatorPasswordPayload repoRoot = do
  passwordResult <- obtainOperatorPassword repoRoot
  pure $ do
    password <- passwordResult
    Just <$> secretPayloadFromBytes (TextEncoding.encodeUtf8 password)

newOperatorPasswordPayload :: FilePath -> IO (Either String (Maybe SecretPayload))
newOperatorPasswordPayload repoRoot = do
  passwordResult <- obtainNewOperatorPassword repoRoot
  pure $ do
    password <- passwordResult
    Just <$> secretPayloadFromBytes (TextEncoding.encodeUtf8 password)

secretPayloadFromBytes :: ByteString -> Either String SecretPayload
secretPayloadFromBytes = mkSecretPayload (64 * 1024)

brokerHostConnection :: FilePath -> BrokerHostConnection
brokerHostConnection repoRoot =
  BrokerHostConnection
    { brokerHostEnvironment = Nothing
    , brokerHostWorkingDirectory = repoRoot
    }

hostSecretWorkerConnection :: FilePath -> HostSecretWorkerConnection
hostSecretWorkerConnection repoRoot =
  HostSecretWorkerConnection
    { hostSecretWorkerEnvironment = Nothing
    , hostSecretWorkerWorkingDirectory = repoRoot
    }

writeBrokerSuccess :: String -> Value -> IO ExitCode
writeBrokerSuccess label response = do
  writeOutput (label ++ ": " ++ LazyByteString8.unpack (encode response))
  pure ExitSuccess

failBrokerCommand :: String -> String -> IO ExitCode
failBrokerCommand label detail = do
  writeOutput (label ++ " failed: " ++ detail)
  pure (ExitFailure 1)

firstShow :: (Show err) => Either err value -> Either String value
firstShow = either (Left . show) Right

-- | LEGACY-ESCAPE[lifecycle-provider-vault-field-projection]: the
-- operator-facing Vault surface still projects the Lifecycle-provider
-- credential's fields by name.  Registered in "Prodbox.Legacy.EscapeRegistry";
-- deleted with the Tier-0 aggregate it describes (Sprint @4.50@).
lifecycleProviderAwsVaultFields :: Settings.AwsCredentialsRef -> Either String ()
lifecycleProviderAwsVaultFields refs =
  case ( validateLifecycleProviderAwsVaultRef
           "aws.access_key_id"
           "access_key_id"
           (Settings.awsCredentialAccessKeyId refs)
       , validateLifecycleProviderAwsVaultRef
           "aws.secret_access_key"
           "secret_access_key"
           (Settings.awsCredentialSecretAccessKey refs)
       , validateLifecycleProviderAwsSessionTokenRef refs
       , validateLifecycleProviderAwsRegion refs
       ) of
    (Right (), Right (), Right (), Right ()) -> Right ()
    (Left err, _, _, _) -> Left err
    (_, Left err, _, _) -> Left err
    (_, _, Left err, _) -> Left err
    (_, _, _, Left err) -> Left err

validateLifecycleProviderAwsVaultRef :: String -> Text -> SecretRef -> Either String ()
validateLifecycleProviderAwsVaultRef fieldName expectedField ref =
  case ref of
    SecretRefVault vaultRef
      | vaultSecretMount vaultRef == "secret"
          && vaultSecretPath vaultRef == "aws/lifecycle-provider"
          && vaultSecretField vaultRef == expectedField ->
          Right ()
      | otherwise ->
          Left
            ( fieldName
                ++ " must reference SecretRef.Vault secret/aws/lifecycle-provider#"
                ++ Text.unpack expectedField
            )
    _ -> Left (fieldName ++ " must be a SecretRef.Vault reference")

validateLifecycleProviderAwsSessionTokenRef :: Settings.AwsCredentialsRef -> Either String ()
validateLifecycleProviderAwsSessionTokenRef refs =
  case Settings.awsCredentialSessionToken refs of
    Nothing -> Right ()
    Just ref -> validateLifecycleProviderAwsVaultRef "aws.session_token" "session_token" ref

validateLifecycleProviderAwsRegion :: Settings.AwsCredentialsRef -> Either String ()
validateLifecycleProviderAwsRegion refs =
  if Text.null (Text.strip (Settings.awsCredentialRegion refs))
    then Left "aws.region must not be empty"
    else Right ()
