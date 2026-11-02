{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- Canonical authenticated framing, replay processing and endpoint handlers over
-- test repositories. This fixture grants no production caller/Authority
-- admission and does not stand in for the captured network/Vault interpreter.
module CredentialTailWireFixture
  ( CredentialAgentFault (..)
  , CredentialWireFixture
  , newCredentialWireFixture
  , credentialWireAuthority
  , credentialWireAgent
  , credentialWireFrameCount
  , credentialWireAgentReadCount
  , credentialFixtureManifestKey
  , credentialWireHandleCompletion
  , credentialFixtureWorkerClient
  ) where

import Crypto.Error (CryptoFailable (..))
import Crypto.PubKey.Ed25519 qualified as Ed25519
import Data.ByteArray qualified as ByteArray
import Data.ByteString qualified as BS
import Data.IORef
import Data.List (isSuffixOf)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
import Prodbox.ControlPlane.AuthenticatedTransport
import Prodbox.ControlPlane.AwsAdminPreparedTargetProduction
import Prodbox.ControlPlane.AwsAdminProvisionerEndpoint
import Prodbox.ControlPlane.CallerPrincipal
import Prodbox.ControlPlane.Client qualified as Client
import Prodbox.ControlPlane.Coordinate (AuthorityScope, mkAuthorityScope)
import Prodbox.ControlPlane.RequestAuthentication
import Prodbox.ControlPlane.RequestReplay
import Prodbox.ControlPlane.RoleReadiness (noRoleReadinessContribution)
import Prodbox.ControlPlane.Route
import Prodbox.ControlPlane.Server qualified as Server
import Prodbox.ControlPlane.TargetMaterialEndpoint qualified as Target
import Prodbox.Http.ReplyStatus (replyStatusCode)
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch
  ( ProviderCredentialRecoveryView (ProviderCredentialRecoveryIdle)
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminAuthority
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( awsAdminPermitIntentPreparedTarget
  )
import Prodbox.Lifecycle.Decommission.AuthorityExport (AuthorityManifestSigner (..))
import Prodbox.Lifecycle.Decommission.Manifest (ManifestPublicKey, mkManifestPublicKey)
import Prodbox.Lifecycle.Lease
import Prodbox.Runtime.Role
import System.Directory (doesFileExist)
import System.FilePath ((</>))

data CredentialAgentFault = CredentialAgentHealthy | CredentialAgentStale
  deriving (Eq, Show)

data CredentialWireFixture
  = CredentialWireFixture
      !(AuthenticatedClientTransport 'LifecycleAuthorityRuntime)
      !(AuthenticatedClientTransport 'TargetSecretAgentRuntime)
      !(IORef Int)
      !(IORef Int)
      !Client.ControlPlaneTransport

credentialWireAuthority
  :: CredentialWireFixture -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
credentialWireAuthority (CredentialWireFixture value _ _ _ _) = value

credentialWireAgent
  :: CredentialWireFixture -> AuthenticatedClientTransport 'TargetSecretAgentRuntime
credentialWireAgent (CredentialWireFixture _ value _ _ _) = value

credentialWireFrameCount :: CredentialWireFixture -> IO Int
credentialWireFrameCount (CredentialWireFixture _ _ count _ _) = readIORef count

credentialWireAgentReadCount :: CredentialWireFixture -> IO Int
credentialWireAgentReadCount (CredentialWireFixture _ _ _ count _) = readIORef count

credentialWireHandleCompletion :: CredentialWireFixture -> BS.ByteString -> IO (Int, BS.ByteString)
credentialWireHandleCompletion (CredentialWireFixture _ _ _ _ wire) frame = do
  response <-
    wire
      "POST"
      []
      ("http://fixture.invalid" <> controlPlaneRoutePath LifecycleAwsAdminProvisioner)
      frame
  either (fail . show) pure response

credentialFixtureWorkerClient
  :: AuthorityTime
  -> Client.ControlPlaneTransport
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
credentialFixtureWorkerClient deadline wire =
  mkAuthenticatedClientTransport bounds providers client
 where
  providers =
    AuthenticatedClientProviders
      (pure (Right (localRequestSigningCapability completionSigner)))
      (pure (Right scope))
      (pure (Right authorityEpochGenesis))
      (pure (Right deadline))
      (pure (Right (must (mkRequestNonce (BS.replicate 16 241)))))
  client =
    must
      ( Client.controlPlaneClientWithTransport
          65536
          (must (Client.mkLifecycleAuthorityEndpoint "http://fixture.invalid"))
          wire
      )

newCredentialWireFixture
  :: AuthorityTime
  -> FilePath
  -> Target.TargetMaterialObservation
  -> CredentialAgentFault
  -> IO CredentialWireFixture
newCredentialWireFixture originalDeadline directory metadata fault = do
  outbox <- newIORef Map.empty
  nonce <- newIORef (0 :: Int)
  frames <- newIORef (0 :: Int)
  agentReads <- newIORef (0 :: Int)
  let resolve operation = Right (authorityRepository outbox operation)
      fallback = AuthenticatedRoleHandler noRoleReadinessContribution (\_ _ _ -> pure Nothing)
      authority =
        awsAdminProvisionerAuthenticatedHandler
          65536
          noRoleReadinessContribution
          (Right <$> currentTime)
          resolve
          preparedLifecycle
          providerLifecycle
          manifestSigner
          fallback
      agent =
        Target.targetMaterialObservationAuthenticatedHandler
          65536
          Target.TargetMaterialRepository
            { Target.observeTargetMaterial = \_ -> do
                modifyIORef' agentReads (+ 1)
                present <- doesFileExist (directory </> "target-present")
                pure (Right (if present || fault == CredentialAgentStale then Just metadata else Nothing))
            , Target.targetMaterialRepositoryReadiness = noRoleReadinessContribution
            }
      providers =
        AuthenticatedClientProviders
          (pure (Right (localRequestSigningCapability requestSigner)))
          (pure (Right scope))
          (pure (Right authorityEpochGenesis))
          (pure (Right originalDeadline))
          ( do
              number <- atomicModifyIORef' nonce (\value -> (value + 1, value + 1))
              pure $
                if number > 128
                  then Left "fixture nonce allowance exhausted"
                  else Right (must (mkRequestNonce (BS.replicate 16 (fromIntegral number))))
          )
  authorityWire <- roleWire frames LifecycleAuthorityRuntime authority
  agentWire <- roleWire frames TargetSecretAgentRuntime agent
  let authorityClient =
        must
          ( Client.controlPlaneClientWithTransport
              65536
              (must (Client.mkLifecycleAuthorityEndpoint "http://fixture.invalid"))
              authorityWire
          )
      agentClient =
        must
          ( Client.controlPlaneClientWithTransport
              65536
              (must (Client.mkTargetSecretAgentEndpoint "http://fixture.invalid"))
              agentWire
          )
  pure
    ( CredentialWireFixture
        (mkAuthenticatedClientTransport bounds providers authorityClient)
        (mkAuthenticatedClientTransport bounds providers agentClient)
        frames
        agentReads
        authorityWire
    )

roleWire
  :: IORef Int -> RuntimeRole -> AuthenticatedRoleHandler IO -> IO Client.ControlPlaneTransport
roleWire frames role handler = do
  projection <- newIORef (0 :: Int, initialRequestReplayProjection replayLimits)
  attempts <- newIORef (0 :: Int)
  let repository =
        RequestReplayRepository
          { readRequestReplayProjection = do
              (revision, value) <- readIORef projection
              pure (Right (RequestReplaySnapshot revision value))
          , compareAndSwapRequestReplayProjection = \expected value ->
              atomicModifyIORef' projection $ \old@(revision, _) ->
                if revision == expected
                  then ((revision + 1, value), RequestReplayCasApplied)
                  else (old, RequestReplayCasConflict)
          }
      server =
        AuthenticatedServerProviders
          (pure (Right scope))
          (pure (Right authorityEpochGenesis))
          (Right <$> currentTime)
          ( pure
              ( Right
                  ( must
                      ( mkRouteTrustRegistry
                          role
                          2
                          [ (route, trustedRequestKeyFromSigner signer)
                          | route <- routesForRole role
                          , signer <- [requestSigner, completionSigner]
                          ]
                      )
                  )
              )
          )
      nextAttempt = do
        number <- atomicModifyIORef' attempts (\value -> (value + 1, value + 1))
        pure
          (either (Left . Text.pack . show) Right (mkReplayAttemptId (BS.replicate 16 (fromIntegral number))))
      interpreter =
        authenticatedRoleInterpreter
          bounds
          lifetime
          (AuthenticatedRoleProviders server nextAttempt)
          role
          (must (mkReplayCasAttempts 4))
          replayLimits
          repository
          handler
  pure $ \_ _ url body -> do
    let matching = filter ((`isSuffixOf` url) . controlPlaneRoutePath) (routesForRole role)
    route <- case matching of
      [value] -> pure value
      _ -> fail "fixture URL does not select exactly one role route"
    modifyIORef' frames (+ 1)
    response <- Server.interpreterHandle interpreter route body
    case response of
      Nothing -> fail "fixture role handler did not handle its route"
      Just (status, bytes) -> pure (Right (replyStatusCode status, bytes))

authorityRepository
  :: IORef (Map.Map Text.Text (Int, AwsAdminAuthorityState))
  -> Text.Text
  -> AwsAdminAuthorityRepository IO Int
authorityRepository state operation =
  AwsAdminAuthorityRepository
    { readAwsAdminAuthority = do
        (revision, value) <-
          Map.findWithDefault (0 :: Int, initialAwsAdminAuthorityState) operation <$> readIORef state
        pure (Right (AwsAdminAuthoritySnapshot revision value))
    , compareAndSwapAwsAdminAuthority = \expected value -> atomicModifyIORef' state $ \stored ->
        let (revision, _) = Map.findWithDefault (0, initialAwsAdminAuthorityState) operation stored
         in if revision == expected
              then (Map.insert operation (revision + 1, value) stored, Right ())
              else (stored, Left "fixture Authority CAS conflict")
    }

preparedLifecycle :: AwsAdminPreparedTargetLifecycle IO
preparedLifecycle =
  AwsAdminPreparedTargetLifecycle
    { recordAwsAdminPrepareAuthorityPhase = const (pure ())
    , proveAwsAdminAuthorizedAttemptRecovery = \_ _ -> pure (Left AwsAdminAuthorizedRecoveryNotAuthorized)
    , observeAwsAdminCompletedWorkerReceipt = const (pure (Right Nothing))
    , proveAwsAdminAttestedAttemptRecovery = \_ _ _ -> pure (Left AwsAdminAuthorizedRecoveryNotAttested)
    , prepareAndReadBackAwsAdminPreparedTarget = \_ -> pure . Right
    , reobserveRetainedAwsAdminPreparedTarget = pure . Right . awsAdminPermitIntentPreparedTarget
    , commitAwsAdminFirstReconcileReceipt = \_ _ -> pure (Right ())
    , observeAwsAdminFirstReconcileContinuation = pure (Right Nothing)
    , observeAwsAdminFirstReconcileRecoveryPending = pure (Right False)
    , settleAwsAdminFirstReconcileRecovery = pure (Right ())
    }

providerLifecycle :: AwsAdminProviderCredentialBoundary IO
providerLifecycle =
  AwsAdminProviderCredentialBoundary
    (const (pure (Right ())))
    (const (pure (Right ())))
    (const (pure (Right ())))
    (pure (Right Nothing))
    (pure (Right ProviderCredentialRecoveryIdle))
    (pure (Right ()))

manifestSigner :: AuthorityManifestSigner IO
manifestSigner =
  AuthorityManifestSigner
    (pure (Right (7, credentialFixtureManifestKey)))
    ( \payload ->
        pure
          (Right (7, ByteArray.convert (Ed25519.sign signingSecret (Ed25519.toPublic signingSecret) payload)))
    )

credentialFixtureManifestKey :: ManifestPublicKey
credentialFixtureManifestKey = must (mkManifestPublicKey (ByteArray.convert (Ed25519.toPublic signingSecret)))

signingSecret :: Ed25519.SecretKey
signingSecret = case Ed25519.secretKey (BS.pack [0 .. 31]) of
  CryptoPassed key -> key
  CryptoFailed failure -> error (show failure)

requestSigner :: RequestSigner
requestSigner = must (mkRequestSigner CallerTestHarness (must (mkSigningKeyGeneration 1)) (BS.pack [32 .. 63]))

completionSigner :: RequestSigner
completionSigner =
  must
    ( mkRequestSigner
        CallerCredentialProvisionerCompletion
        (must (mkSigningKeyGeneration 1))
        (BS.pack [64 .. 95])
    )

scope :: AuthorityScope
scope = must (mkAuthorityScope "home")

bounds :: AuthenticatedTransportBounds
bounds = must (mkAuthenticatedTransportBounds 65536 1024 64000)

lifetime :: AuthorityDuration
lifetime = must (authorityDurationFromMicros 60000000)

replayLimits :: RequestReplayLimits
replayLimits = must (mkRequestReplayLimits 128 65536 (must (authorityDurationFromMicros 1000000)))

currentTime :: IO AuthorityTime
currentTime = authorityTimeFromMicros . fromInteger . floor . (* 1000000) <$> getPOSIXTime

must :: (Show failure) => Either failure value -> value
must = either (error . show) id
