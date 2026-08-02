{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneTargetSecretWorker
  ( controlPlaneTargetSecretWorkerSuite
  )
where

import Control.Concurrent (forkIO, throwTo)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), throwIO, try)
import Control.Monad (forM_)
import Crypto.Error (CryptoFailable (CryptoFailed, CryptoPassed))
import Crypto.PubKey.Ed25519 qualified as Ed25519
import Data.Aeson qualified as Aeson
import Data.Bits (xor)
import Data.ByteArray qualified as ByteArray
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticationRegistry (targetSecretWorkerVaultRole)
import Prodbox.ControlPlane.ClosedSession (finishClosedSession)
import Prodbox.ControlPlane.Coordinate (AuthorityEpoch (..))
import Prodbox.ControlPlane.ServiceSessionJournal
  ( ServiceSessionBinding
  , ServiceSessionJournal
  , ServiceSessionJournalRepository (..)
  , ServiceSessionJournalSnapshot (..)
  , ServiceSessionPhase (..)
  , mkInitialServiceSessionJournal
  , mkServiceSessionBinding
  , serviceSessionBindingFence
  , serviceSessionJournalPhase
  )
import Prodbox.ControlPlane.TargetIntentAuthorityClient
  ( TargetIntentAuthorityClient
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( AwsCredentialIdentity (AwsLifecycleProvider)
  , TargetSecretId (TargetAwsCredential, TargetPublicEdgeTls)
  , TargetSecretPayload (..)
  , compiledTargetSecretSink
  , targetSecretIdToken
  , targetSecretPayloadId
  , targetSecretPayloadToVaultFields
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
import Prodbox.ControlPlane.TargetSecretWorker
import Prodbox.ControlPlane.TargetSecretWorkerCoordinator
import Prodbox.ControlPlane.TargetSecretWorkerKubernetes
import Prodbox.ControlPlane.TargetSecretWorkerProduction
  ( classifyTargetWorkerServiceAccountObservation
  , parseTargetAgentRolloutObservation
  , parseTargetWorkerServiceAccountObservation
  , recoverTargetWorkerCreateWith
  , targetWorkerActiveAccessorSubject
  , targetWorkerRetainedExecutionBoundary
  , targetWorkerRoleWideAccessorSubject
  )
import Prodbox.ControlPlane.TargetSecretWorkerProtocol
import Prodbox.ControlPlane.TargetSecretWorkerRuntime
  ( TargetWorkerAuditorRecoveryBoundary (..)
  , acquireTargetWorkerAuditorWith
  , targetWorkerServiceLoginAccepted
  )
import Prodbox.ControlPlane.TargetWorkerExecutionPermit
  ( TargetWorkerExecutionPermitError (..)
  , VerifiedTargetWorkerExecutionPermit
  , decodeTargetWorkerExecutionPermit
  , encodeTargetWorkerExecutionPermit
  , issueTargetWorkerExecutionPermit
  , targetWorkerExecutionPermitMatchesObservation
  , targetWorkerSessionAttemptId
  , targetWorkerSessionOperationId
  , verifyTargetWorkerExecutionPermit
  )
import Prodbox.ControlPlane.TlsDekExchange
  ( TlsDekTransitBoundary (..)
  , prepareTlsDekExchange
  )
import Prodbox.ControlPlane.VaultAccessorAudit
  ( VaultAccessorAuditOps (..)
  , VaultAccessorSubject (..)
  , isBoundedBatchAuditorLogin
  )
import Prodbox.Lifecycle.CheckpointAuthority (TargetClusterSecretSink)
import Prodbox.Lifecycle.Decommission.AuthorityExport
  ( AuthorityManifestSigner (..)
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeFromMicros
  , fencingTokenValue
  , mkFencingToken
  , mkOwnerNonce
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , mkCredentialGeneration
  , sha256TargetValueDigest
  , targetValueDigestText
  )
import Prodbox.Subprocess (ProcessOutput (..))
import Prodbox.Vault.Client
  ( TokenAccessorInfo (..)
  , VaultKubernetesLoginResult (..)
  , VaultToken (..)
  )
import System.Exit (ExitCode (ExitFailure))
import TestSupport

data AuditorFixtureLogin
  = AuditorFixtureInvalid
  | AuditorFixtureValid
  deriving stock (Eq, Show)

controlPlaneTargetSecretWorkerSuite :: SuiteBuilder ()
controlPlaneTargetSecretWorkerSuite =
  describe "Sprint 4.50 attested one-shot Target materializer" $ do
    it "binds the signed intent to exact target/schema/image/SA/request/Pod UID" $ do
      let intent = workerIntent
      targetWorkerIntentTarget intent `shouldBe` workerTarget
      targetWorkerIntentSchema intent `shouldBe` TargetWorkerDirectAws
      targetWorkerIntentJobName intent `shouldSatisfy` ("target-secret-" `prefixOf`)
      let attestation = workerAttestation intent
      targetWorkerAttestedPodUid attestation `shouldBe` workerPodUid
      case attestTargetWorkerPod
        admissionTime
        intent
        (rawWorkerObservation intent) {observedTargetWorkerImageDigest = otherImageDigestText} of
        Left TargetWorkerAttestationImageMismatch -> pure ()
        _ -> expectationFailure "expected immutable-image attestation refusal"

    it "requires a fully observed exact Agent rollout on both Deployment surfaces" $ do
      parseTargetAgentRolloutObservation
        (agentDeploymentObservation workerAgentIdentity 1 1 (targetAgentRolloutDigest workerAgentIdentity))
        `shouldBe` Right workerAgentRollout
      parseTargetAgentRolloutObservation
        (agentDeploymentObservation workerAgentIdentity 2 1 (targetAgentRolloutDigest workerAgentIdentity))
        `shouldSatisfy` isLeftValue
      parseTargetAgentRolloutObservation
        (agentDeploymentObservationWithTemplateDigest workerAgentIdentity 1 1 otherImageDigestText)
        `shouldSatisfy` isLeftValue
      let substitutedIdentity =
            mustRight
              (mkTargetAgentIdentity ("home@sha256:" <> Text.replicate 64 "b"))
      parseTargetAgentRolloutObservation
        ( agentDeploymentObservation
            substitutedIdentity
            1
            1
            (targetAgentRolloutDigest substitutedIdentity)
        )
        `shouldSatisfy` either
          (const False)
          ((/= workerAgentIdentity) . targetAgentRolloutEvidenceIdentity)

    it "admits only an exact named ServiceAccount GET with an API-assigned UID" $ do
      let expectedUid =
            mustRight
              ( mkTargetWorkerServiceAccountUid
                  "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
              )
          valid =
            serviceAccountObservation
              (targetWorkerIntentServiceAccount workerIntent)
              "target-secret-agent"
              "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
      parseTargetWorkerServiceAccountObservation workerIntent valid
        `shouldBe` Right expectedUid
      forM_
        [ serviceAccountObservation
            "foreign-service-account"
            "target-secret-agent"
            "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        , serviceAccountObservation
            (targetWorkerIntentServiceAccount workerIntent)
            "foreign-namespace"
            "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        , serviceAccountObservation
            (targetWorkerIntentServiceAccount workerIntent)
            "target-secret-agent"
            "invalid uid"
        , LazyByteString.toStrict
            ( Aeson.encode
                ( Aeson.object
                    [ "items"
                        Aeson..= [ Aeson.object []
                                 , Aeson.object []
                                 ]
                    ]
                )
            )
        , LazyByteString.toStrict
            ( Aeson.encode
                ( Aeson.object
                    [ "metadata"
                        Aeson..= Aeson.object
                          [ "name"
                              Aeson..= targetWorkerIntentServiceAccount workerIntent
                          , "namespace" Aeson..= ("target-secret-agent" :: Text)
                          ]
                    ]
                )
            )
        ]
        $ \substituted ->
          parseTargetWorkerServiceAccountObservation workerIntent substituted
            `shouldSatisfy` isLeftValue
      classifyTargetWorkerServiceAccountObservation
        workerIntent
        (Left "ServiceAccount GET transport unavailable")
        `shouldSatisfy` isLeftValue
      classifyTargetWorkerServiceAccountObservation
        workerIntent
        (Right (ProcessOutput (ExitFailure 1) "" "NotFound"))
        `shouldSatisfy` isLeftValue

    it "rejects static ServiceAccount and immutable-image substitution before permit issuance" $ do
      let intent = workerIntent
          cases =
            [
              ( (rawWorkerObservation intent)
                  { observedTargetWorkerServiceAccount = "substituted-worker"
                  }
              , TargetWorkerAttestationServiceAccountMismatch
              )
            ,
              ( (rawWorkerObservation intent)
                  { observedTargetWorkerImageDigest = otherImageDigestText
                  }
              , TargetWorkerAttestationImageMismatch
              )
            ]
          assertRefused (observation, expected) =
            case attestTargetWorkerPod admissionTime intent observation of
              Left actual -> actual `shouldBe` expected
              Right _ -> expectationFailure "expected Target worker attestation refusal"
      forM_ cases assertRefused

    it "binds signed permits to exact rollout, Job, Pod, SA UID, image, and an independent fence" $ do
      let originalAttestation = workerAttestation workerIntent
          originalBinding = workerSessionBinding originalAttestation
          substitutedObservations =
            [ (rawWorkerObservation workerIntent)
                { observedTargetWorkerJobUid = "job-uid-substituted"
                }
            , (rawWorkerObservation workerIntent)
                { observedTargetWorkerPodName = "target-secret-worker-pod-substituted"
                }
            , (rawWorkerObservation workerIntent)
                { observedTargetWorkerPodUid = "pod-uid-substituted"
                }
            , (rawWorkerObservation workerIntent)
                { observedTargetWorkerServiceAccountUid = "service-account-uid-substituted"
                }
            ]
      serviceSessionBindingFence originalBinding
        `shouldNotBe` fencingTokenValue (targetWorkerIntentFencingToken workerIntent)
      forM_ substitutedObservations $ \observation -> do
        let substitutedAttestation =
              mustAttestation
                (attestTargetWorkerPod admissionTime workerIntent observation)
            substitutedBinding = workerSessionBinding substitutedAttestation
        targetWorkerSessionAttemptId workerAgentRollout substitutedAttestation
          `shouldNotBe` targetWorkerSessionAttemptId workerAgentRollout originalAttestation
        signed <-
          issueTargetWorkerExecutionPermit
            permitSigner
            acceptedAuthority
            workerAgentRollout
            substitutedAttestation
            substitutedBinding
        let verified =
              mustRight
                ( verifyTargetWorkerExecutionPermit
                    acceptedAuthority
                    admissionTime
                    workerIntent
                    (mustRight signed)
                )
        targetWorkerExecutionPermitMatchesObservation
          workerAgentRollout
          originalAttestation
          originalBinding
          verified
          `shouldBe` False
      let wrongIdentity =
            mustRight
              (mkTargetAgentIdentity ("home@sha256:" <> Text.replicate 64 "b"))
          wrongRollout =
            mustRight
              ( mkTargetAgentRolloutEvidence
                  wrongIdentity
                  "deployment-uid-substituted"
                  1
                  1
                  (targetAgentRolloutDigest wrongIdentity)
              )
          wrongBinding =
            mustRight
              ( mkServiceSessionBinding
                  targetSecretWorkerVaultRole
                  (targetWorkerSessionOperationId workerIntent)
                  (targetWorkerSessionAttemptId wrongRollout originalAttestation)
                  1
              )
      issueTargetWorkerExecutionPermit
        permitSigner
        acceptedAuthority
        wrongRollout
        originalAttestation
        wrongBinding
        `shouldReturn` Left TargetWorkerExecutionPermitTrustMismatch

    it "rejects a canonical execution-permit frame after signature mutation" $ do
      let attestation = workerAttestation workerIntent
      signed <-
        issueTargetWorkerExecutionPermit
          permitSigner
          acceptedAuthority
          workerAgentRollout
          attestation
          (workerSessionBinding attestation)
      let encoded = encodeTargetWorkerExecutionPermit (mustRight signed)
          mutated =
            ByteString.init encoded
              <> ByteString.singleton (ByteString.last encoded `xor` 1)
      case decodeTargetWorkerExecutionPermit mutated of
        Left err -> expectationFailure ("mutated permit did not remain canonical: " <> show err)
        Right decoded ->
          case verifyTargetWorkerExecutionPermit
            acceptedAuthority
            admissionTime
            workerIntent
            decoded of
            Left TargetWorkerExecutionPermitSignatureInvalid -> pure ()
            other -> expectationFailure ("expected signature refusal, got " <> showPermitResult other)

    it "round-trips only a bounded direct-stdin frame and rejects schema substitution" $ do
      let attestation = workerAttestation workerIntent
      permit <- workerExecutionPermit attestation
      let encoded =
            mustRight
              (encodeDirectTargetWorkerIngress permit attestation workerPayload)
      ByteString.isInfixOf "target-secret-value" encoded `shouldBe` True
      withTargetWorkerIngress
        encoded
        ( \binding payload ->
            ( targetWorkerFramePodUid binding
            , targetWorkerFrameTarget binding
            , targetWorkerFrameSchema binding
            , targetSecretPayloadId payload
            )
        )
        (\_ _ -> error "direct frame selected rewrapped callback")
        `shouldBe` Right
          (workerPodUid, workerTarget, TargetWorkerDirectAws, workerTarget)
      encodeRewrappedTargetWorkerIngress permit attestation "rewrapped"
        `shouldBe` Left TargetWorkerIngressSchemaMismatch

    it "selects one exact TLS arm and rejects a different arm before its continuation" $ do
      let attestation = tlsWorkerAttestation tlsWorkerIntent
      permit <- tlsWorkerExecutionPermit attestation
      let operation = TargetWorkerTlsPrepareInput
          encoded =
            mustRight
              (encodeTargetWorkerOperationIngress permit attestation operation)
      withTargetWorkerOperationIngress
        encoded
        (\binding selected -> (targetWorkerFrameSchema binding, selected))
        `shouldBe` Right (TargetWorkerTlsPrepare, operation)
      encodeTargetWorkerOperationIngress
        permit
        attestation
        (TargetWorkerDirectMaterialInput workerPayload)
        `shouldBe` Left TargetWorkerIngressSchemaMismatch
      targetWorkerOperationRequestDigest operation
        `shouldNotBe` targetWorkerOperationRequestDigest
          (TargetWorkerDirectMaterialInput workerPayload)

    it "requires the signed TLS operation commitment to match the exact stdin arm" $ do
      let attestation = tlsWorkerAttestation tlsWrongDigestIntent
      permit <- tlsWorkerExecutionPermit attestation
      encodeTargetWorkerOperationIngress
        permit
        attestation
        TargetWorkerTlsPrepareInput
        `shouldBe` Left TargetWorkerIngressIntentInvalid

    it "round-trips a typed TLS provisional result and rejects result-arm substitution" $ do
      prepared <-
        prepareTlsDekExchange
          TlsDekTransitBoundary
            { tlsDekTransitEncrypt = const (pure (Right "vault:v1:opaque-prepared"))
            , tlsDekTransitDecrypt = const (pure (Left "unused"))
            }
      let result = TargetWorkerTlsPreparedResult (mustRight prepared)
          completion =
            mustRight
              ( successfulTargetWorkerOperationProvisionalCompletion
                  "worker-accessor"
                  result
              )
      decodeTargetWorkerProvisionalCompletion
        (encodeTargetWorkerProvisionalCompletion completion)
        `shouldBe` Right completion
      targetWorkerOperationResultMatchesSchema TargetWorkerTlsPrepare result
        `shouldBe` True
      targetWorkerOperationResultMatchesSchema TargetWorkerTlsVerify result
        `shouldBe` False

    it "performs one generation CAS, exact data/metadata readback, and idempotent replay" $ do
      fixture <- freshVaultFixture TargetWorkerDataMissing TargetWorkerMetadataMissing
      firstRun <- runMaterialization fixture
      firstRun `shouldSatisfy` isApplied
      readIORef (vaultCasWrites fixture) `shouldReturn` 1
      readIORef (vaultMetadataWrites fixture) `shouldReturn` 1
      secondRun <- runMaterialization fixture
      secondRun `shouldSatisfy` isAlreadyApplied
      readIORef (vaultCasWrites fixture) `shouldReturn` 1
      readIORef (vaultMetadataWrites fixture) `shouldReturn` 1

    it "repairs metadata after a crash between data CAS and custom-metadata publish" $ do
      let fields = mustRight (targetSecretPayloadToVaultFields workerPayload)
      fixture <-
        freshVaultFixture
          (TargetWorkerDataPresent 7 fields)
          TargetWorkerMetadataMissing
      result <- runMaterialization fixture
      result `shouldSatisfy` isRecovered
      readIORef (vaultCasWrites fixture) `shouldReturn` 0
      readIORef (vaultMetadataWrites fixture) `shouldReturn` 1

    it "recovers a CAS response loss through authoritative readback without retry" $ do
      fixture <- freshVaultFixture TargetWorkerDataMissing TargetWorkerMetadataMissing
      writeIORef (vaultLoseCasResponse fixture) True
      result <- runMaterialization fixture
      result `shouldSatisfy` isRecovered
      readIORef (vaultCasWrites fixture) `shouldReturn` 1

    it "refuses same-generation commitment collision before any data write" $ do
      let fields = mustRight (targetSecretPayloadToVaultFields workerPayload)
          conflicting =
            Map.fromList
              [ ("prodbox_generation", "1")
              , ("prodbox_commitment", "vault:v1:different")
              ]
      fixture <-
        freshVaultFixture
          (TargetWorkerDataPresent 4 fields)
          (TargetWorkerMetadataPresent 4 conflicting)
      runMaterialization fixture
        `shouldReturn` Left (TargetWorkerExecutionGenerationCollision 1)
      readIORef (vaultCasWrites fixture) `shouldReturn` 0

    it "revokes the worker session and lets exact absence close a lost revoke response" $ do
      revocations <- newIORef (0 :: Int)
      let revoke = modifyIORef' revocations (+ 1) >> pure (Right ())
      finishTargetWorkerSession
        (pure (Left TargetWorkerExecutionDeadlineReached :: Either TargetWorkerExecutionError ()))
        revoke
        (pure (Right True))
        `shouldReturn` Left TargetWorkerExecutionDeadlineReached
      readIORef revocations `shouldReturn` 1
      finishTargetWorkerSession
        (pure (Right ()))
        (pure (Left TargetWorkerExecutionSessionRevocationFailed))
        (pure (Right True))
        `shouldReturn` Right ()

    it "runs revoke and exact-absence cleanup after thrown worker effects" $ do
      revocations <- newIORef (0 :: Int)
      observations <- newIORef (0 :: Int)
      finishClosedSession
        TargetWorkerExecutionDeadlineReached
        TargetWorkerExecutionSessionRevocationFailed
        (throwIO (userError "worker crashed"))
        (modifyIORef' revocations (+ 1) >> pure (Right ()))
        (modifyIORef' observations (+ 1) >> pure (Right True))
        `shouldReturn` (Left TargetWorkerExecutionDeadlineReached :: Either TargetWorkerExecutionError ())
      readIORef revocations `shouldReturn` 1
      readIORef observations `shouldReturn` 1

    it "accepts only an accessor-free bounded batch auditor" $ do
      let valid =
            VaultKubernetesLoginResult
              { vaultLoginToken = VaultToken "opaque-test-token"
              , vaultLoginAccessor = ""
              , vaultLoginLeaseSeconds = 120
              , vaultLoginRenewable = False
              , vaultLoginTokenType = "batch"
              }
      isBoundedBatchAuditorLogin 300 valid `shouldBe` True
      isBoundedBatchAuditorLogin 300 valid {vaultLoginTokenType = "service"}
        `shouldBe` False
      isBoundedBatchAuditorLogin 300 valid {vaultLoginAccessor = "unexpected-accessor"}
        `shouldBe` False

    it "accepts renewable accessor-bearing service evidence only within the hard cap" $ do
      let valid =
            VaultKubernetesLoginResult
              { vaultLoginToken = VaultToken "opaque-test-token"
              , vaultLoginAccessor = "accessor-1"
              , vaultLoginLeaseSeconds = 600
              , vaultLoginRenewable = True
              , vaultLoginTokenType = "service"
              }
      targetWorkerServiceLoginAccepted valid `shouldBe` True
      targetWorkerServiceLoginAccepted valid {vaultLoginLeaseSeconds = 0}
        `shouldBe` False
      targetWorkerServiceLoginAccepted valid {vaultLoginLeaseSeconds = 601}
        `shouldBe` False
      targetWorkerServiceLoginAccepted valid {vaultLoginAccessor = ""}
        `shouldBe` False
      targetWorkerServiceLoginAccepted valid {vaultLoginTokenType = "batch"}
        `shouldBe` False

    it "revokes and stably proves an invalid accessor-bearing auditor login absent before reuse" $ do
      logins <- newIORef [AuditorFixtureInvalid, AuditorFixtureValid]
      observations <- newIORef [False, True, True]
      events <- newIORef ([] :: [Text])
      let auditorAccessor login = case login of
            AuditorFixtureInvalid -> "drifted-auditor-accessor"
            AuditorFixtureValid -> ""
          boundary =
            TargetWorkerAuditorRecoveryBoundary
              { acquireTargetWorkerAuditorLogin = do
                  modifyIORef' events (++ ["login"])
                  remaining <- readIORef logins
                  case remaining of
                    [] -> pure (Left "fixture login exhausted")
                    login : rest -> writeIORef logins rest >> pure (Right login)
              , targetWorkerAuditorLoginAccepted = (== AuditorFixtureValid)
              , targetWorkerAuditorLoginMayHaveAccessor =
                  (== AuditorFixtureInvalid)
              , targetWorkerAuditorLoginAccessor = auditorAccessor
              , revokeTargetWorkerAuditorLogin = \_ ->
                  modifyIORef' events (++ ["revoke-login"]) >> pure (Left "response lost")
              , revokeTargetWorkerAuditorAccessor = \_ _ ->
                  modifyIORef' events (++ ["revoke-accessor"]) >> pure (Left "response lost")
              , observeTargetWorkerAuditorAccessorAbsent = \_ _ -> do
                  modifyIORef' events (++ ["observe-absence"])
                  remaining <- readIORef observations
                  case remaining of
                    [] -> pure (Left "fixture observation exhausted")
                    observed : rest ->
                      writeIORef observations rest >> pure (Right observed)
              , waitTargetWorkerAuditorVisibility =
                  modifyIORef' events (++ ["visibility-grace"])
              }
      acquireTargetWorkerAuditorWith 3 5 boundary
        `shouldReturn` Right AuditorFixtureValid
      readIORef events
        `shouldReturn` [ "login"
                       , "revoke-login"
                       , "login"
                       , "revoke-accessor"
                       , "observe-absence"
                       , "visibility-grace"
                       , "observe-absence"
                       , "visibility-grace"
                       , "observe-absence"
                       ]

    it "runs revoke and exact-absence cleanup after worker cancellation" $ do
      blocked <- newEmptyMVar :: IO (MVar ())
      started <- newEmptyMVar :: IO (MVar ())
      result <- newEmptyMVar
      revocations <- newIORef (0 :: Int)
      observations <- newIORef (0 :: Int)
      workerThread <-
        forkIO $ do
          outcome <-
            try
              ( finishClosedSession
                  TargetWorkerExecutionDeadlineReached
                  TargetWorkerExecutionSessionRevocationFailed
                  (putMVar started () >> takeMVar blocked >> pure (Right ()))
                  (modifyIORef' revocations (+ 1) >> pure (Right ()))
                  (modifyIORef' observations (+ 1) >> pure (Right True))
              )
          putMVar result outcome
      takeMVar started
      throwTo workerThread ThreadKilled
      takeMVar result
        `shouldReturn` (Left ThreadKilled :: Either AsyncException (Either TargetWorkerExecutionError ()))
      readIORef revocations `shouldReturn` 1
      readIORef observations `shouldReturn` 1

    it "always deletes and positively observes absence after an attach refusal" $ do
      deleted <- newIORef (0 :: Int)
      absent <- newIORef (0 :: Int)
      let boundary =
            TargetWorkerKubernetesBoundary
              { observeSelectedTargetAgentRollout = pure (Right workerAgentRollout)
              , createTargetWorkerIntent = const (pure (Right workerJobUid))
              , recoverTargetWorkerIntent =
                  const (pure (Right (TargetWorkerCreateRecovered workerJobUid)))
              , observeTargetWorkerIntent =
                  \intent -> pure (Right (Just (rawWorkerObservation intent)))
              , attachTargetWorkerIngress =
                  \_ _ _ ->
                    pure
                      (Left (TargetWorkerCoordinatorAttachFailed "attach refused"))
              , deleteTargetWorkerIntent = \_ _ _ ->
                  modifyIORef' deleted (+ 1) >> pure (Right ())
              , observeTargetWorkerIntentAbsent = \_ _ _ ->
                  modifyIORef' absent (+ 1) >> pure (Right True)
              }
      result <-
        coordinateDirectTargetMaterialization
          boundary
          workerExecutionBoundary
          acceptedAuthority
          admissionTime
          workerAgentIdentity
          workerTarget
          TargetWorkerDirectAws
          workerImageDigest
          signedIntentBytes
          workerPayload
      result `shouldBe` Left (TargetWorkerCoordinatorAttachFailed "attach refused")
      readIORef deleted `shouldReturn` 1
      readIORef absent `shouldReturn` 1

    it "durably activates the exact server accessor before authorizing worker cleanup" $ do
      store <- newTargetSessionStore
      events <- newIORef ([] :: [Text])
      let execution =
            targetWorkerRetainedExecutionBoundary
              (targetSessionRepository store events)
              (orderedTargetAuditOps events)
              unusedTargetIntentAuthorityClient
          attestation = workerAttestation workerIntent
      prepared <-
        prepareTargetWorkerSessionAttempt
          execution
          workerAgentRollout
          attestation
      binding <- case prepared of
        Left detail -> expectationFailure (Text.unpack detail) >> pure (workerSessionBinding attestation)
        Right value -> pure value
      readIORef events
        `shouldReturn` [ "journal:acquiring"
                       , "audit:inventory"
                       , "audit:inventory"
                       , "audit:grace"
                       , "audit:inventory"
                       , "journal:precleaned"
                       , "journal:login-attempt-committed"
                       ]
      activateTargetWorkerSessionAttempt
        execution
        attestation
        binding
        "worker-accessor"
        `shouldReturn` Right ()
      readIORef events
        `shouldReturn` [ "journal:acquiring"
                       , "audit:inventory"
                       , "audit:inventory"
                       , "audit:grace"
                       , "audit:inventory"
                       , "journal:precleaned"
                       , "journal:login-attempt-committed"
                       , "audit:lookup"
                       , "journal:active"
                       ]
      closeTargetWorkerSessionAttempt execution binding `shouldReturn` Right ()
      readIORef events
        `shouldReturn` [ "journal:acquiring"
                       , "audit:inventory"
                       , "audit:inventory"
                       , "audit:grace"
                       , "audit:inventory"
                       , "journal:precleaned"
                       , "journal:login-attempt-committed"
                       , "audit:lookup"
                       , "journal:active"
                       , "journal:cleanup-required"
                       , "audit:inventory"
                       , "audit:known-absence"
                       , "audit:inventory"
                       , "audit:grace"
                       , "audit:known-absence"
                       , "audit:inventory"
                       , "journal:cleanup-proven"
                       , "journal:vacant"
                       ]
      Map.member
        "service_account_uid"
        (vaultAccessorSubjectMetadata targetWorkerRoleWideAccessorSubject)
        `shouldBe` False
      Map.lookup
        "service_account_uid"
        ( vaultAccessorSubjectMetadata
            (targetWorkerActiveAccessorSubject attestation)
        )
        `shouldBe` Just (targetWorkerServiceAccountUidText workerServiceAccountUid)

    it "holds worker cleanup until the provisional accessor is Active, then closes the retained lane" $ do
      vaultFixture <-
        freshVaultFixture TargetWorkerDataMissing TargetWorkerMetadataMissing
      materialized <- runMaterialization vaultFixture
      receipt <- case materialized of
        Right (TargetWorkerMaterializationApplied value) -> pure value
        Right (TargetWorkerMaterializationAlreadyApplied value) -> pure value
        Right (TargetWorkerMaterializationRecovered value) -> pure value
        Left err -> expectationFailure (show err) >> fail "materialization fixture failed"
      store <- newTargetSessionStore
      events <- newIORef ([] :: [Text])
      let retainedExecution =
            targetWorkerRetainedExecutionBoundary
              (targetSessionRepository store events)
              (orderedTargetAuditOps events)
              unusedTargetIntentAuthorityClient
          execution =
            retainedExecution
              { authorizeTargetWorkerExecution =
                  authorizeTargetWorkerExecution workerExecutionBoundary
              }
          completion =
            mustRight
              (successfulTargetWorkerProvisionalCompletion "worker-accessor" receipt)
          boundary =
            standardWorkerBoundary
              { attachTargetWorkerIngress = \_ _ decide -> do
                  modifyIORef' events (++ ["worker:provisional"])
                  decided <- decide (encodeTargetWorkerProvisionalCompletion completion)
                  case decided of
                    Left err -> pure (Left err)
                    Right outcome -> do
                      modifyIORef'
                        events
                        (++ ["worker:cleanup-authorized", "worker:cleanup-complete"])
                      pure (Right outcome)
              }
      coordinateWithBoundary boundary execution `shouldReturn` Right receipt
      readIORef events
        `shouldReturn` [ "journal:acquiring"
                       , "audit:inventory"
                       , "audit:inventory"
                       , "audit:grace"
                       , "audit:inventory"
                       , "journal:precleaned"
                       , "journal:login-attempt-committed"
                       , "worker:provisional"
                       , "audit:lookup"
                       , "journal:active"
                       , "worker:cleanup-authorized"
                       , "worker:cleanup-complete"
                       , "journal:cleanup-required"
                       , "audit:inventory"
                       , "audit:known-absence"
                       , "audit:inventory"
                       , "audit:grace"
                       , "audit:known-absence"
                       , "audit:inventory"
                       , "journal:cleanup-proven"
                       , "journal:vacant"
                       ]

    it "refuses an accessor classified to a substituted ServiceAccount UID before cleanup authorization" $ do
      vaultFixture <-
        freshVaultFixture TargetWorkerDataMissing TargetWorkerMetadataMissing
      materialized <- runMaterialization vaultFixture
      receipt <- case materialized of
        Right (TargetWorkerMaterializationApplied value) -> pure value
        Right (TargetWorkerMaterializationAlreadyApplied value) -> pure value
        Right (TargetWorkerMaterializationRecovered value) -> pure value
        Left err -> expectationFailure (show err) >> fail "materialization fixture failed"
      store <- newTargetSessionStore
      events <- newIORef ([] :: [Text])
      let wrongUidAudit =
            (orderedTargetAuditOps events)
              { auditLookupAccessor = \_ ->
                  pure
                    ( Right
                        TokenAccessorInfo
                          { tokenAccessorInfoPolicies = ["default", targetSecretWorkerVaultRole]
                          , tokenAccessorInfoMetadata =
                              Map.insert
                                "service_account_uid"
                                "substituted-service-account-uid"
                                ( vaultAccessorSubjectMetadata
                                    ( targetWorkerActiveAccessorSubject
                                        (workerAttestation workerIntent)
                                    )
                                )
                          , tokenAccessorInfoCreationPath = "auth/kubernetes/login"
                          , tokenAccessorInfoDisplayName = "kubernetes-target-secret-worker"
                          }
                    )
              }
          retainedExecution =
            targetWorkerRetainedExecutionBoundary
              (targetSessionRepository store events)
              wrongUidAudit
              unusedTargetIntentAuthorityClient
          execution =
            retainedExecution
              { authorizeTargetWorkerExecution =
                  authorizeTargetWorkerExecution workerExecutionBoundary
              }
          completion =
            mustRight
              (successfulTargetWorkerProvisionalCompletion "worker-accessor" receipt)
          boundary =
            standardWorkerBoundary
              { attachTargetWorkerIngress = \_ _ decide ->
                  decide (encodeTargetWorkerProvisionalCompletion completion)
              }
      coordinateWithBoundary boundary execution
        `shouldReturn` Left
          ( TargetWorkerCoordinatorSessionActivateFailed
              "ServiceSessionLifecycleAccessorIdentityMismatch"
          )
      fmap (filter (== "journal:active")) (readIORef events) `shouldReturn` []

    it "recovers an applied-but-response-lost Job create and still performs exact terminal cleanup" $ do
      recovered <- newIORef (0 :: Int)
      deleted <- newIORef ([] :: [Maybe (Text, TargetWorkerPodUid)])
      absent <- newIORef (0 :: Int)
      let boundary =
            standardWorkerBoundary
              { createTargetWorkerIntent = const (pure (Left "create response lost"))
              , recoverTargetWorkerIntent = \_ -> do
                  modifyIORef' recovered (+ 1)
                  pure (Right (TargetWorkerCreateRecovered workerJobUid))
              , attachTargetWorkerIngress =
                  \_ _ _ ->
                    pure
                      (Left (TargetWorkerCoordinatorAttachFailed "attach refused"))
              , deleteTargetWorkerIntent = \_ _ maybePod -> do
                  modifyIORef' deleted (++ [maybePod])
                  pure (Right ())
              , observeTargetWorkerIntentAbsent = \_ _ _ -> do
                  modifyIORef' absent (+ 1)
                  pure (Right True)
              }
      result <- coordinateWithBoundary boundary workerExecutionBoundary
      result `shouldBe` Left (TargetWorkerCoordinatorAttachFailed "attach refused")
      readIORef recovered `shouldReturn` 1
      readIORef deleted
        `shouldReturn` [Just ("target-secret-worker-pod", workerPodUid)]
      readIORef absent `shouldReturn` 1

    it "waits across the create visibility grace before recovering a delayed Job UID" $ do
      observations <-
        newIORef
          [ Right Nothing
          , Right (Just workerJobUid)
          ]
      graces <- newIORef (0 :: Int)
      retries <- newIORef (0 :: Int)
      recovered <-
        recoverTargetWorkerCreateWith
          4
          (modifyIORef' graces (+ 1))
          (modifyIORef' retries (+ 1))
          (nextCreateObservation observations)
      recovered `shouldBe` Right (TargetWorkerCreateRecovered workerJobUid)
      readIORef graces `shouldReturn` 1
      readIORef retries `shouldReturn` 0

    it "classifies create absence only after two observations across the visibility grace" $ do
      observations <-
        newIORef
          [ Right Nothing
          , Right Nothing
          ]
      graces <- newIORef (0 :: Int)
      recovered <-
        recoverTargetWorkerCreateWith
          4
          (modifyIORef' graces (+ 1))
          (pure ())
          (nextCreateObservation observations)
      recovered `shouldBe` Right TargetWorkerCreateStablyAbsent
      readIORef graces `shouldReturn` 1

    it "cleans the known Job when Pod observation fails or returns a foreign Job UID" $ do
      forM_
        [
          ( pure (Left "observation failed")
          , TargetWorkerCoordinatorObservationFailed "observation failed"
          )
        ,
          ( pure
              ( Right
                  ( Just
                      ( (rawWorkerObservation workerIntent)
                          { observedTargetWorkerJobUid = "foreign-job-uid"
                          }
                      )
                  )
              )
          , TargetWorkerCoordinatorCleanupBindingInvalid
          )
        ]
        $ \(observation, expected) -> do
          deleted <- newIORef ([] :: [Maybe (Text, TargetWorkerPodUid)])
          let boundary =
                standardWorkerBoundary
                  { observeTargetWorkerIntent = const observation
                  , deleteTargetWorkerIntent = \_ _ maybePod -> do
                      modifyIORef' deleted (++ [maybePod])
                      pure (Right ())
                  }
          coordinateWithBoundary boundary workerExecutionBoundary
            `shouldReturn` Left expected
          readIORef deleted `shouldReturn` [Nothing]

    it "binds Pod cleanup before attestation so an attestation refusal cannot strand it" $ do
      deleted <- newIORef ([] :: [Maybe (Text, TargetWorkerPodUid)])
      let invalidObservation =
            (rawWorkerObservation workerIntent)
              { observedTargetWorkerImageDigest = otherImageDigestText
              }
          boundary =
            standardWorkerBoundary
              { observeTargetWorkerIntent =
                  const (pure (Right (Just invalidObservation)))
              , deleteTargetWorkerIntent = \_ _ maybePod -> do
                  modifyIORef' deleted (++ [maybePod])
                  pure (Right ())
              }
      coordinateWithBoundary boundary workerExecutionBoundary
        `shouldReturn` Left
          ( TargetWorkerCoordinatorAttestationFailed
              TargetWorkerAttestationImageMismatch
          )
      readIORef deleted
        `shouldReturn` [Just ("target-secret-worker-pod", workerPodUid)]

    it "closes the retained session and deletes the exact Job/Pod after attach cancellation" $ do
      attachStarted <- newEmptyMVar :: IO (MVar ())
      attachBlocked <- newEmptyMVar :: IO (MVar ())
      result <-
        newEmptyMVar
          :: IO
               ( MVar
                   ( Either
                       AsyncException
                       (Either TargetWorkerCoordinatorError TargetWorkerReceipt)
                   )
               )
      closed <- newIORef (0 :: Int)
      deleted <- newIORef (0 :: Int)
      absent <- newIORef (0 :: Int)
      let boundary =
            standardWorkerBoundary
              { attachTargetWorkerIngress = \_ _ _ -> do
                  putMVar attachStarted ()
                  takeMVar attachBlocked
                  pure
                    ( Left
                        (TargetWorkerCoordinatorAttachFailed "unreachable")
                    )
              , deleteTargetWorkerIntent = \_ _ _ -> do
                  modifyIORef' deleted (+ 1)
                  pure (Right ())
              , observeTargetWorkerIntentAbsent = \_ _ _ -> do
                  modifyIORef' absent (+ 1)
                  pure (Right True)
              }
          execution =
            workerExecutionBoundary
              { closeTargetWorkerSessionAttempt = \_ -> do
                  modifyIORef' closed (+ 1)
                  pure (Right ())
              }
      workerThread <-
        forkIO $ try (coordinateWithBoundary boundary execution) >>= putMVar result
      takeMVar attachStarted
      throwTo workerThread ThreadKilled
      takeMVar result `shouldReturn` Left ThreadKilled
      readIORef closed `shouldReturn` 1
      readIORef deleted `shouldReturn` 1
      readIORef absent `shouldReturn` 1

    it "renders a secret-free, immutable, Guaranteed-QoS one-shot Job" $ do
      let rendered =
            LazyByteString.toStrict
              (Aeson.encode (mustRight (renderTargetSecretWorkerJob "registry/prodbox" 300 workerIntent)))
      ByteString.isInfixOf "target-secret-value" rendered `shouldBe` False
      ByteString.isInfixOf "prodbox-target-secret-worker" rendered `shouldBe` True
      ByteString.isInfixOf "sha256:" rendered `shouldBe` True
      ByteString.isInfixOf "automountServiceAccountToken\":false" rendered `shouldBe` True
      ByteString.isInfixOf "Memory" rendered `shouldBe` True
      ByteString.isInfixOf "stdinOnce\":true" rendered `shouldBe` True

agentDeploymentObservation
  :: TargetAgentIdentity -> Natural -> Natural -> Text -> ByteString.ByteString
agentDeploymentObservation identity generation observedGeneration rollout =
  agentDeploymentObservationWithTemplateDigest
    identity
    generation
    observedGeneration
    rollout

agentDeploymentObservationWithTemplateDigest
  :: TargetAgentIdentity -> Natural -> Natural -> Text -> ByteString.ByteString
agentDeploymentObservationWithTemplateDigest identity generation observedGeneration templateRollout =
  LazyByteString.toStrict
    ( Aeson.encode
        ( Aeson.object
            [ "metadata"
                Aeson..= Aeson.object
                  [ "name" Aeson..= ("target-secret-agent" :: Text)
                  , "uid" Aeson..= ("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" :: Text)
                  , "generation" Aeson..= generation
                  , "annotations"
                      Aeson..= Aeson.object
                        [ "prodbox.io/target-agent-identity"
                            Aeson..= targetAgentIdentityText identity
                        , "prodbox.io/target-agent-rollout-digest"
                            Aeson..= targetAgentRolloutDigest identity
                        ]
                  ]
            , "spec"
                Aeson..= Aeson.object
                  [ "template"
                      Aeson..= Aeson.object
                        [ "metadata"
                            Aeson..= Aeson.object
                              [ "annotations"
                                  Aeson..= Aeson.object
                                    [ "prodbox.io/target-agent-identity"
                                        Aeson..= targetAgentIdentityText identity
                                    , "prodbox.io/target-agent-rollout-digest"
                                        Aeson..= templateRollout
                                    ]
                              ]
                        ]
                  ]
            , "status"
                Aeson..= Aeson.object
                  ["observedGeneration" Aeson..= observedGeneration]
            ]
        )
    )

serviceAccountObservation :: Text -> Text -> Text -> ByteString.ByteString
serviceAccountObservation name namespace uid =
  LazyByteString.toStrict
    ( Aeson.encode
        ( Aeson.object
            [ "metadata"
                Aeson..= Aeson.object
                  [ "name" Aeson..= name
                  , "namespace" Aeson..= namespace
                  , "uid" Aeson..= uid
                  ]
            ]
        )
    )

nextCreateObservation
  :: IORef [Either Text (Maybe TargetWorkerJobUid)]
  -> IO (Either Text (Maybe TargetWorkerJobUid))
nextCreateObservation observations = do
  remaining <- readIORef observations
  case remaining of
    [] -> pure (Left "fixture observation exhausted")
    next : rest -> writeIORef observations rest >> pure next

standardWorkerBoundary :: TargetWorkerKubernetesBoundary IO
standardWorkerBoundary =
  TargetWorkerKubernetesBoundary
    { observeSelectedTargetAgentRollout = pure (Right workerAgentRollout)
    , createTargetWorkerIntent = const (pure (Right workerJobUid))
    , recoverTargetWorkerIntent =
        const (pure (Right (TargetWorkerCreateRecovered workerJobUid)))
    , observeTargetWorkerIntent =
        \intent -> pure (Right (Just (rawWorkerObservation intent)))
    , attachTargetWorkerIngress =
        \_ _ _ -> pure (Left (TargetWorkerCoordinatorAttachFailed "attach refused"))
    , deleteTargetWorkerIntent = \_ _ _ -> pure (Right ())
    , observeTargetWorkerIntentAbsent = \_ _ _ -> pure (Right True)
    }

coordinateWithBoundary
  :: TargetWorkerKubernetesBoundary IO
  -> TargetWorkerExecutionBoundary IO
  -> IO (Either TargetWorkerCoordinatorError TargetWorkerReceipt)
coordinateWithBoundary boundary execution =
  coordinateDirectTargetMaterialization
    boundary
    execution
    acceptedAuthority
    admissionTime
    workerAgentIdentity
    workerTarget
    TargetWorkerDirectAws
    workerImageDigest
    signedIntentBytes
    workerPayload

type TargetSessionStore = IORef (Int, ServiceSessionJournal)

newTargetSessionStore :: IO TargetSessionStore
newTargetSessionStore =
  newIORef
    ( 0
    , mustRight (mkInitialServiceSessionJournal targetSecretWorkerVaultRole)
    )

targetSessionRepository
  :: TargetSessionStore
  -> IORef [Text]
  -> ServiceSessionJournalRepository IO Int
targetSessionRepository store events =
  ServiceSessionJournalRepository
    { readServiceSessionJournal = do
        (revision, journal) <- readIORef store
        pure
          ( Right
              ServiceSessionJournalSnapshot
                { serviceSessionJournalRevision = revision
                , serviceSessionJournalObserved = journal
                }
          )
    , compareAndSwapServiceSessionJournal = \expected next -> do
        (revision, _) <- readIORef store
        if revision /= expected
          then pure (Left "fixture CAS conflict")
          else do
            writeIORef store (revision + 1, next)
            modifyIORef'
              events
              (++ ["journal:" <> targetSessionPhaseToken (serviceSessionJournalPhase next)])
            pure (Right ())
    }

targetSessionPhaseToken :: ServiceSessionPhase -> Text
targetSessionPhaseToken phase = case phase of
  ServiceSessionVacant _ -> "vacant"
  ServiceSessionAcquiring _ -> "acquiring"
  ServiceSessionPrecleaned _ -> "precleaned"
  ServiceSessionLoginAttemptCommitted _ -> "login-attempt-committed"
  ServiceSessionActive _ _ -> "active"
  ServiceSessionCleanupRequired _ _ -> "cleanup-required"
  ServiceSessionCleanupProven _ -> "cleanup-proven"

orderedTargetAuditOps :: IORef [Text] -> VaultAccessorAuditOps IO
orderedTargetAuditOps events =
  VaultAccessorAuditOps
    { auditListAccessors = do
        modifyIORef' events (++ ["audit:inventory"])
        pure (Right [])
    , auditLookupAccessor = \_ -> do
        modifyIORef' events (++ ["audit:lookup"])
        pure
          ( Right
              TokenAccessorInfo
                { tokenAccessorInfoPolicies = ["default", targetSecretWorkerVaultRole]
                , tokenAccessorInfoMetadata =
                    vaultAccessorSubjectMetadata
                      (targetWorkerActiveAccessorSubject (workerAttestation workerIntent))
                , tokenAccessorInfoCreationPath = "auth/kubernetes/login"
                , tokenAccessorInfoDisplayName = "kubernetes-target-secret-worker"
                }
          )
    , auditRevokeAccessor = const (pure (Right ()))
    , auditObserveAccessorAbsent = \_ -> do
        modifyIORef' events (++ ["audit:known-absence"])
        pure (Right True)
    , auditWaitVisibilityGrace = do
        modifyIORef' events (++ ["audit:grace"])
        pure (Right ())
    }

unusedTargetIntentAuthorityClient :: TargetIntentAuthorityClient IO
unusedTargetIntentAuthorityClient =
  error "Target intent Authority client must not be evaluated by journal-only test"

showPermitResult
  :: Either TargetWorkerExecutionPermitError VerifiedTargetWorkerExecutionPermit
  -> String
showPermitResult result = case result of
  Left err -> show err
  Right _ -> "Right VerifiedTargetWorkerExecutionPermit"

isLeftValue :: Either left right -> Bool
isLeftValue value = case value of
  Left _ -> True
  Right _ -> False

data VaultFixture = VaultFixture
  { vaultData :: !(IORef TargetWorkerDataObservation)
  , vaultMetadata :: !(IORef TargetWorkerMetadataObservation)
  , vaultCasWrites :: !(IORef Int)
  , vaultMetadataWrites :: !(IORef Int)
  , vaultLoseCasResponse :: !(IORef Bool)
  }

freshVaultFixture
  :: TargetWorkerDataObservation
  -> TargetWorkerMetadataObservation
  -> IO VaultFixture
freshVaultFixture initialData initialMetadata =
  VaultFixture
    <$> newIORef initialData
    <*> newIORef initialMetadata
    <*> newIORef 0
    <*> newIORef 0
    <*> newIORef False

runMaterialization
  :: VaultFixture
  -> IO (Either TargetWorkerExecutionError TargetWorkerMaterializationResult)
runMaterialization fixture =
  executeTargetWorkerMaterialization
    admissionTime
    (fixtureBoundary fixture)
    (workerAttestation workerIntent)
    workerPayload

fixtureBoundary :: VaultFixture -> TargetWorkerVaultBoundary IO
fixtureBoundary fixture =
  TargetWorkerVaultBoundary
    { targetWorkerReadData = const (Right <$> readIORef (vaultData fixture))
    , targetWorkerReadMetadata = const (Right <$> readIORef (vaultMetadata fixture))
    , targetWorkerCommitmentHmac = const (pure (Right workerCommitment))
    , targetWorkerCompareAndSwap = \_ expected fields -> do
        modifyIORef' (vaultCasWrites fixture) (+ 1)
        let version = expected + 1
        writeIORef (vaultData fixture) (TargetWorkerDataPresent version fields)
        lose <- readIORef (vaultLoseCasResponse fixture)
        pure $ if lose then Left "response lost" else Right version
    , targetWorkerWriteMetadata = \_ fields -> do
        modifyIORef' (vaultMetadataWrites fixture) (+ 1)
        observed <- readIORef (vaultData fixture)
        case observed of
          TargetWorkerDataMissing -> pure (Left "data missing")
          TargetWorkerDataPresent version _ -> do
            writeIORef
              (vaultMetadata fixture)
              (TargetWorkerMetadataPresent version fields)
            pure (Right ())
    }

workerIntent :: TargetWorkerIntent
workerIntent =
  mustRight
    ( prepareTargetWorkerIntent
        acceptedAuthority
        admissionTime
        workerAgentIdentity
        workerTarget
        TargetWorkerDirectAws
        workerImageDigest
        signedIntentBytes
    )

workerAttestation :: TargetWorkerIntent -> TargetWorkerAttestation
workerAttestation intent =
  mustAttestation (attestTargetWorkerPod admissionTime intent (rawWorkerObservation intent))

workerSessionBinding
  :: TargetWorkerAttestation -> ServiceSessionBinding
workerSessionBinding attestation =
  mustRight
    ( mkServiceSessionBinding
        targetSecretWorkerVaultRole
        (targetWorkerSessionOperationId (targetWorkerAttestedIntent attestation))
        (targetWorkerSessionAttemptId workerAgentRollout attestation)
        1
    )

workerExecutionPermit
  :: TargetWorkerAttestation -> IO VerifiedTargetWorkerExecutionPermit
workerExecutionPermit attestation = do
  signed <-
    issueTargetWorkerExecutionPermit
      permitSigner
      acceptedAuthority
      workerAgentRollout
      attestation
      (workerSessionBinding attestation)
  pure
    ( mustRight
        ( verifyTargetWorkerExecutionPermit
            acceptedAuthority
            admissionTime
            (targetWorkerAttestedIntent attestation)
            (mustRight signed)
        )
    )

workerExecutionBoundary :: TargetWorkerExecutionBoundary IO
workerExecutionBoundary =
  TargetWorkerExecutionBoundary
    { prepareTargetWorkerSessionAttempt =
        \_ attestation -> pure (Right (workerSessionBinding attestation))
    , authorizeTargetWorkerExecution =
        \accepted rollout attestation binding ->
          fmap
            (either (Left . Text.pack . show) Right)
            ( issueTargetWorkerExecutionPermit
                permitSigner
                accepted
                rollout
                attestation
                binding
            )
    , activateTargetWorkerSessionAttempt = \_ _ _ -> pure (Right ())
    , closeTargetWorkerSessionAttempt = const (pure (Right ()))
    }

permitSigner :: AuthorityManifestSigner IO
permitSigner =
  AuthorityManifestSigner
    { readAuthorityManifestPublicKey = pure (Left "unused in permit test")
    , signAuthorityManifestPayload = \payload ->
        pure $ do
          private <- case Ed25519.secretKey (ByteString.pack [0 .. 31]) of
            CryptoFailed _ -> Left "test signing key invalid"
            CryptoPassed key -> Right key
          let public = Ed25519.toPublic private
              signature = Ed25519.sign private public payload
          Right (1, ByteArray.convert signature)
    }

rawWorkerObservation :: TargetWorkerIntent -> RawTargetWorkerPodObservation
rawWorkerObservation intent =
  RawTargetWorkerPodObservation
    { observedTargetWorkerJobName = targetWorkerIntentJobName intent
    , observedTargetWorkerJobUid = "job-uid-123"
    , observedTargetWorkerPodName = "target-secret-worker-pod"
    , observedTargetWorkerPodUid = targetWorkerPodUidText workerPodUid
    , observedTargetWorkerImageDigest = targetWorkerImageDigestText workerImageDigest
    , observedTargetWorkerServiceAccount = targetWorkerIntentServiceAccount intent
    , observedTargetWorkerServiceAccountUid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    , observedTargetWorkerTarget =
        targetSecretIdToken (targetWorkerIntentTarget intent)
    , observedTargetWorkerAgentIdentity = targetAgentIdentityText workerAgentIdentity
    , observedTargetWorkerSchema =
        targetWorkerSchemaToken (targetWorkerIntentSchema intent)
    , observedTargetWorkerRequestDigest =
        targetValueDigestText (targetWorkerIntentRequestDigest intent)
    , observedTargetWorkerDeadlineMicros = 1000
    , observedTargetWorkerPhase = "Running"
    , observedTargetWorkerReady = True
    , observedTargetWorkerRestartCount = 0
    , observedTargetWorkerDeletionTimestamp = Nothing
    }

workerPayload :: TargetSecretPayload
workerPayload =
  AwsCredentialMaterial
    { awsCredentialMaterialIdentity = AwsLifecycleProvider
    , awsCredentialMaterialAccessKeyId = "AKIAEXAMPLE"
    , awsCredentialMaterialSecretAccessKey = "target-secret-value"
    , awsCredentialMaterialSessionToken = ""
    , awsCredentialMaterialRegion = "ca-central-1"
    }

workerTarget :: TargetSecretId
workerTarget = TargetAwsCredential AwsLifecycleProvider

tlsWorkerTarget :: TargetSecretId
tlsWorkerTarget = TargetPublicEdgeTls

workerSink :: TargetClusterSecretSink
workerSink = mustRight (compiledTargetSecretSink workerTarget)

tlsWorkerSink :: TargetClusterSecretSink
tlsWorkerSink = mustRight (compiledTargetSecretSink tlsWorkerTarget)

workerSpec :: TargetCommittedIntentSpec
workerSpec =
  TargetCommittedIntentSpec
    { targetIntentIssuerGeneration = issuerGeneration
    , targetIntentIssuerIdentity = "lifecycle-authority"
    , targetIntentAuthorityEpoch = AuthorityEpoch 3
    , targetIntentOperationId = "target-operation"
    , targetIntentActionIndex = 0
    , targetIntentCommitReceiptDigest = sha256TargetValueDigest "provisioner-receipt"
    , targetIntentOwnerNonce = mustRight (mkOwnerNonce "authority-owner")
    , targetIntentFencingToken = mustRight (mkFencingToken 6)
    , targetIntentAgentIdentity = workerAgentIdentity
    , targetIntentSink = workerSink
    , targetIntentGeneration = workerGeneration
    , targetIntentDeadline = authorityTimeFromMicros 1000
    , targetIntentIdempotencyKey = "target-operation-generation-1"
    }

tlsWorkerSpec :: TargetCommittedIntentSpec
tlsWorkerSpec =
  workerSpec
    { targetIntentOperationId = "target-tls-prepare-operation"
    , targetIntentCommitReceiptDigest =
        targetWorkerOperationRequestDigest TargetWorkerTlsPrepareInput
    , targetIntentSink = tlsWorkerSink
    , targetIntentIdempotencyKey = "target-tls-prepare-generation-1"
    }

tlsWrongDigestSpec :: TargetCommittedIntentSpec
tlsWrongDigestSpec =
  tlsWorkerSpec
    { targetIntentCommitReceiptDigest =
        sha256TargetValueDigest "different-authorized-operation"
    }

acceptedAuthority :: AcceptedTargetAuthority
acceptedAuthority =
  mustRight
    ( mkAcceptedTargetAuthority
        issuerGeneration
        "lifecycle-authority"
        (targetIntentSigningPublicKey signingKey)
        (AuthorityEpoch 3)
        (mustRight (mkFencingToken 5))
        workerAgentIdentity
        workerSink
    )

tlsAcceptedAuthority :: AcceptedTargetAuthority
tlsAcceptedAuthority =
  mustRight
    ( mkAcceptedTargetAuthority
        issuerGeneration
        "lifecycle-authority"
        (targetIntentSigningPublicKey signingKey)
        (AuthorityEpoch 3)
        (mustRight (mkFencingToken 5))
        workerAgentIdentity
        tlsWorkerSink
    )

signedIntentBytes :: ByteString.ByteString
signedIntentBytes =
  encodeSignedTargetCommittedIntent
    ( signTargetCommittedIntent
        signingKey
        (mustRight (mkUnsignedTargetCommittedIntent workerSpec))
    )

tlsSignedIntentBytes :: ByteString.ByteString
tlsSignedIntentBytes =
  encodeSignedTargetCommittedIntent
    ( signTargetCommittedIntent
        signingKey
        (mustRight (mkUnsignedTargetCommittedIntent tlsWorkerSpec))
    )

tlsWorkerIntent :: TargetWorkerIntent
tlsWorkerIntent =
  mustRight
    ( prepareTargetWorkerIntent
        tlsAcceptedAuthority
        admissionTime
        workerAgentIdentity
        tlsWorkerTarget
        TargetWorkerTlsPrepare
        workerImageDigest
        tlsSignedIntentBytes
    )

tlsWrongDigestIntent :: TargetWorkerIntent
tlsWrongDigestIntent =
  mustRight
    ( prepareTargetWorkerIntent
        tlsAcceptedAuthority
        admissionTime
        workerAgentIdentity
        tlsWorkerTarget
        TargetWorkerTlsPrepare
        workerImageDigest
        ( encodeSignedTargetCommittedIntent
            ( signTargetCommittedIntent
                signingKey
                (mustRight (mkUnsignedTargetCommittedIntent tlsWrongDigestSpec))
            )
        )
    )

tlsWorkerAttestation :: TargetWorkerIntent -> TargetWorkerAttestation
tlsWorkerAttestation intent =
  mustAttestation (attestTargetWorkerPod admissionTime intent (rawWorkerObservation intent))

tlsWorkerExecutionPermit
  :: TargetWorkerAttestation -> IO VerifiedTargetWorkerExecutionPermit
tlsWorkerExecutionPermit attestation = do
  signed <-
    issueTargetWorkerExecutionPermit
      permitSigner
      tlsAcceptedAuthority
      workerAgentRollout
      attestation
      (workerSessionBinding attestation)
  pure
    ( mustRight
        ( verifyTargetWorkerExecutionPermit
            tlsAcceptedAuthority
            admissionTime
            (targetWorkerAttestedIntent attestation)
            (mustRight signed)
        )
    )

signingKey :: TargetIntentSigningKey
signingKey = mustRight (mkTargetIntentSigningKey (ByteString.pack [0 .. 31]))

issuerGeneration :: TargetIssuerKeyGeneration
issuerGeneration = mustRight (mkTargetIssuerKeyGeneration 1)

workerGeneration :: CredentialGeneration
workerGeneration = mustRight (mkCredentialGeneration 1)

workerAgentIdentity :: TargetAgentIdentity
workerAgentIdentity =
  mustRight
    (mkTargetAgentIdentity ("home@sha256:" <> Text.replicate 64 "a"))

workerAgentRollout :: TargetAgentRolloutEvidence
workerAgentRollout =
  mustRight
    ( mkTargetAgentRolloutEvidence
        workerAgentIdentity
        "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        1
        1
        (targetAgentRolloutDigest workerAgentIdentity)
    )

workerImageDigest :: TargetWorkerImageDigest
workerImageDigest = mustRight (mkTargetWorkerImageDigest ("sha256:" <> Text.replicate 64 "a"))

otherImageDigestText :: Text
otherImageDigestText = "sha256:" <> Text.replicate 64 "b"

workerPodUid :: TargetWorkerPodUid
workerPodUid = mustRight (mkTargetWorkerPodUid "11111111-2222-3333-4444-555555555555")

workerServiceAccountUid :: TargetWorkerServiceAccountUid
workerServiceAccountUid =
  mustRight
    (mkTargetWorkerServiceAccountUid "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")

workerJobUid :: TargetWorkerJobUid
workerJobUid = mustRight (mkTargetWorkerJobUid "job-uid-123")

workerCommitment :: Text
workerCommitment = "vault:v1:opaque-worker-commitment"

admissionTime :: AuthorityTime
admissionTime = authorityTimeFromMicros 100

mustAttestation
  :: Either TargetWorkerAttestationError TargetWorkerAttestation
  -> TargetWorkerAttestation
mustAttestation value = case value of
  Left err -> error (show err)
  Right result -> result

isApplied
  :: Either TargetWorkerExecutionError TargetWorkerMaterializationResult
  -> Bool
isApplied value = case value of
  Right TargetWorkerMaterializationApplied {} -> True
  _ -> False

isAlreadyApplied
  :: Either TargetWorkerExecutionError TargetWorkerMaterializationResult
  -> Bool
isAlreadyApplied value = case value of
  Right TargetWorkerMaterializationAlreadyApplied {} -> True
  _ -> False

isRecovered
  :: Either TargetWorkerExecutionError TargetWorkerMaterializationResult
  -> Bool
isRecovered value = case value of
  Right TargetWorkerMaterializationRecovered {} -> True
  _ -> False

prefixOf :: Text -> Text -> Bool
prefixOf = Text.isPrefixOf

mustRight :: (Show errorValue) => Either errorValue value -> value
mustRight value = case value of
  Left err -> error (show err)
  Right result -> result
