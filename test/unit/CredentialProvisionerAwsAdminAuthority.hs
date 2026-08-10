{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module CredentialProvisionerAwsAdminAuthority
  ( credentialProvisionerAwsAdminAuthoritySuite
  )
where

import Control.Exception (AsyncException (ThreadKilled), throwIO, try)
import Crypto.Error (CryptoFailable (CryptoFailed, CryptoPassed))
import Crypto.PubKey.Ed25519 qualified as Ed25519
import Data.Aeson qualified as Aeson
import Data.ByteArray qualified as ByteArray
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
  ( AuthenticatedRoleHandler (..)
  )
import Prodbox.ControlPlane.AwsAdminPreparedTargetProduction
  ( AwsAdminPreparedTargetLifecycle (..)
  , FirstReconcileContinuation (..)
  )
import Prodbox.ControlPlane.AwsAdminProvisionerClient
  ( AwsAdminPreparedProvisioning (..)
  , AwsAdminProvisionerClient
  , AwsAdminProvisionerClientError (AwsAdminProvisionerClientUnexpectedResponse)
  , mkAwsAdminProvisionerClient
  , observeAwsAdminFirstReconcile
  )
import Prodbox.ControlPlane.AwsAdminProvisionerEndpoint
  ( AwsAdminFirstReconcileProjection (..)
  , AwsAdminProvisionerChallenge (..)
  , AwsAdminProvisionerObservation (..)
  , AwsAdminProvisionerPhase (AwsAdminProvisionerPrepared)
  , AwsAdminProvisionerRequest (..)
  , AwsAdminProvisionerResponse (..)
  , awsAdminProvisionerAuthenticatedHandler
  , awsAdminProvisionerResponseMaximumBytes
  )
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (CallerCredentialProvisioner, CallerOperatorCli)
  )
import Prodbox.ControlPlane.Codec
  ( decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (LifecycleAwsAdminProvisioner)
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( AwsCredentialIdentity (AwsLifecycleProvider)
  , TargetSecretId (TargetAwsCredential)
  )
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( TargetAgentIdentity
  , mkTargetAgentIdentity
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminAuthority
  ( AwsAdminAuthorityAuthorizationError (..)
  , AwsAdminAuthorityRepository (..)
  , AwsAdminAuthorityRepositoryError (..)
  , AwsAdminAuthoritySnapshot (..)
  , AwsAdminAuthorityState (..)
  , AwsAdminAuthorityStateError (..)
  , AwsAdminPreparedTargetBoundary (..)
  , attestAwsAdminAuthority
  , authorizeAwsAdminAttestation
  , commitAwsAdminAttested
  , commitAwsAdminPrepared
  , decodeAwsAdminAuthorityState
  , encodeAwsAdminAuthorityState
  , initialAwsAdminAuthorityState
  , prepareAwsAdminAuthority
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminCoordinator
  ( AwsAdminCoordinatorError (..)
  , AwsAdminKubernetesBoundary (..)
  , coordinateAwsAdminProvisioning
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecution
  ( AwsAdminWorkerReceipt
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminKubernetes
  ( mkAwsAdminJobResources
  , renderAwsAdminJob
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( AwsAdminJobBinding
  , AwsAdminPermitError (AwsAdminPermitJobBindingMismatch)
  , AwsAdminPermitIntent
  , CredentialIamParameters
  , awsAdminJobNameForPermit
  , awsAdminPermitIntentAuthorityEndpoint
  , awsAdminPermitIntentAuthorityScope
  , awsAdminPermitIntentDeadline
  , awsAdminPermitIntentGeneration
  , awsAdminPermitIntentImageDigest
  , awsAdminPermitIntentOperationId
  , awsAdminPermitIntentPermitId
  , awsAdminPermitIntentRequestDigest
  , awsAdminPermitIntentTarget
  , awsAdminWorkerServiceAccount
  , encodeAwsAdminPermitIntent
  , mkAwsAdminJobBinding
  , mkLifecycleProviderIamParameters
  , mkNormalAwsAdminPermitIntent
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass (LifecycleProviderCredential)
  , OperatorMaterialAction (InstallOperatorMaterial)
  , OperatorMaterialIngressSchema (AwsAdminProvisioningIngress)
  , OperatorMaterialPermit
  , OperatorMaterialRequest
  , mkAwsOperatorMaterialRequest
  , mkOperatorMaterialOperationId
  , mkOperatorMaterialPermit
  , mkOperatorMaterialPermitId
  , operatorMaterialOperationIdText
  , operatorMaterialPermitIdText
  , operatorMaterialRequestDigest
  )
import Prodbox.Lifecycle.CredentialProvisioner.PreparedTarget
  ( PreparedCredentialTargetObservation
  , mkPreparedCredentialTargetObservation
  )
import Prodbox.Lifecycle.Decommission.AuthorityExport
  ( AuthorityManifestSigner (..)
  )
import Prodbox.Lifecycle.Decommission.Manifest
  ( ManifestPublicKey
  , mkManifestPublicKey
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeFromMicros
  , authorityTimeMicros
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , TargetValueDigest
  , credentialGenerationValue
  , mkCredentialGeneration
  , mkTargetValueDigest
  , targetValueDigestText
  )
import Prodbox.Settings (Credentials (..))
import TestSupport

credentialProvisionerAwsAdminAuthoritySuite :: SuiteBuilder ()
credentialProvisionerAwsAdminAuthoritySuite =
  describe "AWS-admin Credential Provisioner Authority" $ do
    it "round-trips each durable pre-authorization state canonically" $ do
      let preparedState =
            must (commitAwsAdminPrepared permitIntent initialAwsAdminAuthorityState)
          attestedState = must (commitAwsAdminAttested jobBinding preparedState)
      decodeAwsAdminAuthorityState (encodeAwsAdminAuthorityState preparedState)
        `shouldBe` Right preparedState
      decodeAwsAdminAuthorityState (encodeAwsAdminAuthorityState attestedState)
        `shouldBe` Right attestedState

    it "binds immutable worker image identity into both intent and attestation" $ do
      mkAwsAdminJobBinding
        permitIntent
        (awsAdminJobNameForPermit (awsAdminPermitIntentPermitId permitIntent))
        "job-uid-1"
        "credential-provisioner-pod-1"
        "pod-uid-1"
        otherImageDigest
        awsAdminWorkerServiceAccount
        "service-account-uid-1"
        heartbeat
        `shouldBe` Left AwsAdminPermitJobBindingMismatch

    it "refuses preparation unless the retained Target outbox is re-observed exactly" $ do
      (repository, stateRef) <- freshRepository False
      let boundary =
            AwsAdminPreparedTargetBoundary
              (const (pure (Right mismatchedPreparedTarget)))
      prepareAwsAdminAuthority repository boundary permitIntent
        `shouldReturn` Left AwsAdminAuthorityPreparedTargetMismatch
      (snd <$> readIORef stateRef) `shouldReturn` initialAwsAdminAuthorityState

    it "accepts a lost CAS response only after exact retained readback" $ do
      (repository, stateRef) <- freshRepository True
      prepareAwsAdminAuthority repository exactPreparedBoundary permitIntent
        `shouldReturn` Right (AwsAdminAuthorityPrepared permitIntent)
      (snd <$> readIORef stateRef)
        `shouldReturn` AwsAdminAuthorityPrepared permitIntent

    it "rejects divergent attestation replay" $ do
      (repository, _) <- freshRepository False
      _ <- prepareAwsAdminAuthority repository exactPreparedBoundary permitIntent
      attestAwsAdminAuthority repository jobBinding
        `shouldReturn` Right (AwsAdminAuthorityAttested permitIntent jobBinding)
      attestAwsAdminAuthority repository divergentJobBinding
        `shouldReturn` Left
          ( AwsAdminAuthorityRepositoryStateRejected
              AwsAdminAuthorityTransitionConflict
          )

    it "requires a fresh heartbeat and a generation-stable Transit signature" $ do
      let attested = AwsAdminAuthorityAttested permitIntent jobBinding
      authorizeAwsAdminAttestation authoritySigner (authorityTimeFromMicros 31000002) attested
        `shouldReturn` Left AwsAdminAuthorityAuthorizationAttestationStale
      authorizeAwsAdminAttestation generationDriftSigner signingTime attested
        `shouldReturn` Left
          (AwsAdminAuthorityAuthorizationSignerGenerationChanged 7 8)
      authorized <- authorizeAwsAdminAttestation authoritySigner signingTime attested
      authorized `shouldSatisfy` either (const False) (const True)

    it "keeps worker completion authority distinct from operator preparation authority" $ do
      (repository, _) <- freshRepository False
      let handler =
            awsAdminProvisionerAuthenticatedHandler
              (256 * 1024)
              fixtureReadyRoleReadinessSource
              (pure (Right signingTime))
              (const (Right repository))
              exactPreparedLifecycle
              authoritySigner
              emptyHandler
          worker = verifiedCallerSlotFixture CallerCredentialProvisioner 1
          operator = verifiedCallerSlotFixture CallerOperatorCli 1
          prepareBody =
            LazyByteString.toStrict
              ( encodeControlPlaneRequest
                  ( PrepareAwsAdminProvisioning
                      (encodePermitIntent permitIntent)
                  )
              )
          completeBody =
            LazyByteString.toStrict
              (encodeControlPlaneRequest (CompleteAwsAdminProvisioning operationId "bad" "bad"))
      workerResult <-
        authenticatedHandlerHandle
          handler
          worker
          LifecycleAwsAdminProvisioner
          prepareBody
      fmap fst workerResult `shouldBe` Just ReplyForbidden
      operatorResult <-
        authenticatedHandlerHandle
          handler
          operator
          LifecycleAwsAdminProvisioner
          completeBody
      fmap fst operatorResult `shouldBe` Just ReplyForbidden

    it "projects the exact retained next member through the closed client" $ do
      let projection =
            AwsAdminFirstReconcileProjection
              { awsAdminFirstReconcileClass = LifecycleProviderCredential
              , awsAdminFirstReconcileMemberIndex = 1
              , awsAdminFirstReconcileMemberDigest = Text.replicate 64 "e"
              , awsAdminFirstReconcileDeadlineMicros = authorityTimeMicros deadline
              }
          client = mkAwsAdminProvisionerClient $ \request -> pure $ case request of
            ObserveAwsAdminFirstReconcile ->
              Right (AwsAdminFirstReconcileObserved (Just projection))
            _ -> Right (AwsAdminProvisioningRefused "unexpected request")
      observeAwsAdminFirstReconcile client `shouldReturn` Right (Just projection)

    it "serves the retained continuation only through the authenticated endpoint" $ do
      let continuation =
            FirstReconcileContinuation
              { firstReconcileContinuationClass = LifecycleProviderCredential
              , firstReconcileContinuationMemberIndex = 1
              , firstReconcileContinuationMemberDigest = Text.replicate 64 "e"
              , firstReconcileContinuationDeadline = deadline
              }
          lifecycle =
            exactPreparedLifecycle
              { observeAwsAdminFirstReconcileContinuation =
                  pure (Right (Just continuation))
              }
          handler =
            awsAdminProvisionerAuthenticatedHandler
              (256 * 1024)
              fixtureReadyRoleReadinessSource
              (pure (Right signingTime))
              (const (Left "repository must not be selected for continuation observation"))
              lifecycle
              authoritySigner
              emptyHandler
          requestBody =
            LazyByteString.toStrict
              (encodeControlPlaneRequest ObserveAwsAdminFirstReconcile)
          expected =
            AwsAdminFirstReconcileObserved
              ( Just
                  AwsAdminFirstReconcileProjection
                    { awsAdminFirstReconcileClass = LifecycleProviderCredential
                    , awsAdminFirstReconcileMemberIndex = 1
                    , awsAdminFirstReconcileMemberDigest = Text.replicate 64 "e"
                    , awsAdminFirstReconcileDeadlineMicros = authorityTimeMicros deadline
                    }
              )
      response <-
        authenticatedHandlerHandle
          handler
          (verifiedCallerSlotFixture CallerOperatorCli 1)
          LifecycleAwsAdminProvisioner
          requestBody
      case response of
        Just (ReplyOk, body) ->
          decodeControlPlaneResponse
            awsAdminProvisionerResponseMaximumBytes
            (LazyByteString.fromStrict body)
            `shouldBe` Right expected
        other -> expectationFailure ("expected continuation response, got " ++ show other)

    it "always cleans a prepared Job when creation throws synchronously" $ do
      events <- newIORef ([] :: [Text])
      outcome <-
        coordinateAwsAdminProvisioning
          preparedOnlyClient
          (throwingCoordinatorKubernetes events (throwIO (userError "create failed")))
          adminCredentials
          permitIntent
      outcome `shouldBe` Left AwsAdminCoordinatorUnhandledException
      readIORef events `shouldReturn` ["delete", "absence"]

    it "cleans a prepared Job and rethrows cancellation during creation" $ do
      events <- newIORef ([] :: [Text])
      outcome <-
        try
          ( coordinateAwsAdminProvisioning
              preparedOnlyClient
              (throwingCoordinatorKubernetes events (throwIO ThreadKilled))
              adminCredentials
              permitIntent
          )
          :: IO
               ( Either
                   AsyncException
                   (Either AwsAdminCoordinatorError AwsAdminWorkerReceipt)
               )
      outcome `shouldBe` Left ThreadKilled
      readIORef events `shouldReturn` ["delete", "absence"]

    it "accepts a lost delete response only after positive absence" $ do
      events <- newIORef ([] :: [Text])
      let base =
            throwingCoordinatorKubernetes
              events
              (throwIO (userError "create failed"))
          responseLost =
            base
              { deleteAwsAdminJob = \_ _ ->
                  writeIORef events ["delete"] >> pure (Left "response lost")
              }
      outcome <-
        coordinateAwsAdminProvisioning
          preparedOnlyClient
          responseLost
          adminCredentials
          permitIntent
      outcome `shouldBe` Left AwsAdminCoordinatorUnhandledException
      readIORef events `shouldReturn` ["delete", "absence"]

    it "renders an immutable Guaranteed-QoS Job with no administrator material" $ do
      let resources = must (mkAwsAdminJobResources "250m" "256Mi")
          prepared = AwsAdminPreparedProvisioning permitIntent coordinatorChallenge
          rendered =
            LazyByteString.toStrict
              . Aeson.encode
              <$> renderAwsAdminJob
                "127.0.0.1:30080/prodbox/prodbox-runtime"
                resources
                1000000
                prepared
      rendered `shouldSatisfy` either (const False) (ByteString.isInfixOf "\"--mode\",\"normal\"")
      rendered
        `shouldSatisfy` either (const False) (ByteString.isInfixOf (TextEncoding.encodeUtf8 imageDigest))
      -- Leak canary (vault_doctrine.md §20.4): assert the absence of the fixture's
      -- own values, not of a vendor prefix. A prefix assertion weakens silently as
      -- fixtures stop imitating credentials; this one fails whatever the fixture is.
      rendered
        `shouldSatisfy` either
          (const False)
          (not . ByteString.isInfixOf (TextEncoding.encodeUtf8 (access_key_id adminCredentials)))
      rendered
        `shouldSatisfy` either
          (const False)
          (not . ByteString.isInfixOf (TextEncoding.encodeUtf8 (secret_access_key adminCredentials)))
      rendered `shouldSatisfy` either (const False) (not . ByteString.isInfixOf "secret_access_key")

exactPreparedLifecycle :: AwsAdminPreparedTargetLifecycle IO
exactPreparedLifecycle =
  AwsAdminPreparedTargetLifecycle
    { prepareAndReadBackAwsAdminPreparedTarget = pure . Right
    , reobserveRetainedAwsAdminPreparedTarget =
        const (pure (Right preparedTarget))
    , commitAwsAdminFirstReconcileReceipt = \_ _ -> pure (Right ())
    , observeAwsAdminFirstReconcileContinuation = pure (Right Nothing)
    }

freshRepository
  :: Bool
  -> IO
       ( AwsAdminAuthorityRepository IO Int
       , IORef (Int, AwsAdminAuthorityState)
       )
freshRepository loseWriteResponse = do
  stateRef <- newIORef (0, initialAwsAdminAuthorityState)
  let repository =
        AwsAdminAuthorityRepository
          { readAwsAdminAuthority = do
              (revision, state) <- readIORef stateRef
              pure
                ( Right
                    AwsAdminAuthoritySnapshot
                      { awsAdminAuthorityRevision = revision
                      , awsAdminAuthoritySnapshotState = state
                      }
                )
          , compareAndSwapAwsAdminAuthority = \expected next -> do
              (revision, _) <- readIORef stateRef
              if revision /= expected
                then pure (Left "fixture CAS conflict")
                else do
                  writeIORef stateRef (revision + 1, next)
                  pure
                    ( if loseWriteResponse
                        then Left "fixture response lost after commit"
                        else Right ()
                    )
          }
  pure (repository, stateRef)

exactPreparedBoundary :: AwsAdminPreparedTargetBoundary IO
exactPreparedBoundary =
  AwsAdminPreparedTargetBoundary (const (pure (Right preparedTarget)))

emptyHandler :: AuthenticatedRoleHandler IO
emptyHandler =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadiness = fixtureReadyRoleReadinessSource
    , authenticatedHandlerHandle = \_ _ _ -> pure Nothing
    }

permitIntent :: AwsAdminPermitIntent
permitIntent =
  must
    ( mkNormalAwsAdminPermitIntent
        operatorPermit
        iamParameters
        imageDigest
        "home"
        "http://lifecycle-authority.lifecycle-authority.svc:8600"
        preparedTarget
    )

operatorPermit :: OperatorMaterialPermit 'AwsAdminProvisioningIngress
operatorPermit =
  must
    ( mkOperatorMaterialPermit
        (must (mkOperatorMaterialPermitId "permit-authority-test"))
        operatorRequest
        deadline
        Nothing
        "operator-signature"
    )

operatorRequest :: OperatorMaterialRequest 'AwsAdminProvisioningIngress
operatorRequest =
  must
    ( mkAwsOperatorMaterialRequest
        LifecycleProviderCredential
        InstallOperatorMaterial
        (must (mkOperatorMaterialOperationId operationId))
        generation
    )

preparedTarget :: PreparedCredentialTargetObservation
preparedTarget = preparedTargetFor "owner-nonce-1"

mismatchedPreparedTarget :: PreparedCredentialTargetObservation
mismatchedPreparedTarget = preparedTargetFor "owner-nonce-2"

preparedTargetFor :: Text -> PreparedCredentialTargetObservation
preparedTargetFor ownerNonce =
  must
    ( mkPreparedCredentialTargetObservation
        ownerNonce
        1
        targetAgent
        (TargetAwsCredential AwsLifecycleProvider)
        generation
        (operatorMaterialRequestDigest operatorRequest)
        receiptDigest
        Nothing
        deadline
    )

jobBinding :: AwsAdminJobBinding
jobBinding = bindingFor "pod-uid-1"

divergentJobBinding :: AwsAdminJobBinding
divergentJobBinding = bindingFor "pod-uid-2"

bindingFor :: Text -> AwsAdminJobBinding
bindingFor podUid =
  must
    ( mkAwsAdminJobBinding
        permitIntent
        (awsAdminJobNameForPermit (awsAdminPermitIntentPermitId permitIntent))
        "job-uid-1"
        "credential-provisioner-pod-1"
        podUid
        imageDigest
        awsAdminWorkerServiceAccount
        "service-account-uid-1"
        heartbeat
    )

authoritySigner :: AuthorityManifestSigner IO
authoritySigner =
  AuthorityManifestSigner
    { readAuthorityManifestPublicKey = pure (Right (7, manifestPublicKey))
    , signAuthorityManifestPayload = \payload ->
        pure
          ( Right
              ( 7
              , ByteArray.convert
                  (Ed25519.sign signingSecret signingPublic payload)
              )
          )
    }

generationDriftSigner :: AuthorityManifestSigner IO
generationDriftSigner =
  authoritySigner
    { signAuthorityManifestPayload = \payload ->
        pure
          ( Right
              ( 8
              , ByteArray.convert
                  ( Ed25519.sign
                      signingSecret
                      signingPublic
                      payload
                  )
              )
          )
    }

signingSecret :: Ed25519.SecretKey
signingSecret = case Ed25519.secretKey (ByteString.pack [0 .. 31]) of
  CryptoPassed key -> key
  CryptoFailed err -> error (show err)

signingPublic :: Ed25519.PublicKey
signingPublic = Ed25519.toPublic signingSecret

manifestPublicKey :: ManifestPublicKey
manifestPublicKey =
  must (mkManifestPublicKey (ByteArray.convert signingPublic))

iamParameters :: CredentialIamParameters
iamParameters =
  must
    ( mkLifecycleProviderIamParameters
        "us-west-2"
        "123456789012"
        "prodbox-provider-role"
    )

targetAgent :: TargetAgentIdentity
targetAgent =
  must
    ( mkTargetAgentIdentity
        ("home@sha256:" <> Text.replicate 64 "a")
    )

generation :: CredentialGeneration
generation = must (mkCredentialGeneration 1)

receiptDigest :: TargetValueDigest
receiptDigest = must (mkTargetValueDigest (Text.replicate 64 "b"))

operationId :: Text
operationId = "aws-admin-authority-operation"

imageDigest, otherImageDigest :: Text
imageDigest = "sha256:" <> Text.replicate 64 "c"
otherImageDigest = "sha256:" <> Text.replicate 64 "d"

heartbeat, signingTime, deadline :: AuthorityTime
heartbeat = authorityTimeFromMicros 1000000
signingTime = authorityTimeFromMicros 1000001
deadline = authorityTimeFromMicros 60000000

preparedOnlyClient :: AwsAdminProvisionerClient IO
preparedOnlyClient =
  mkAwsAdminProvisionerClient $ \request -> pure $ case request of
    PrepareAwsAdminProvisioning _ -> Right (AwsAdminProvisioningPrepared coordinatorChallenge)
    ObserveAwsAdminProvisioning _ ->
      Right
        ( AwsAdminProvisioningObserved
            AwsAdminProvisionerObservation
              { awsAdminObservedChallenge = coordinatorChallenge
              , awsAdminObservedPhase = AwsAdminProvisionerPrepared
              , awsAdminObservedPermit = Nothing
              , awsAdminObservedReceipt = Nothing
              }
        )
    _ -> Left AwsAdminProvisionerClientUnexpectedResponse

coordinatorChallenge :: AwsAdminProvisionerChallenge
coordinatorChallenge =
  AwsAdminProvisionerChallenge
    { awsAdminChallengeOperationId =
        operatorMaterialOperationIdText (awsAdminPermitIntentOperationId permitIntent)
    , awsAdminChallengePermitId =
        operatorMaterialPermitIdText (awsAdminPermitIntentPermitId permitIntent)
    , awsAdminChallengeRequestDigest =
        targetValueDigestText (awsAdminPermitIntentRequestDigest permitIntent)
    , awsAdminChallengeGeneration =
        credentialGenerationValue (awsAdminPermitIntentGeneration permitIntent)
    , awsAdminChallengeTarget = awsAdminPermitIntentTarget permitIntent
    , awsAdminChallengeJobName = awsAdminJobNameForPermit (awsAdminPermitIntentPermitId permitIntent)
    , awsAdminChallengeImageDigest = awsAdminPermitIntentImageDigest permitIntent
    , awsAdminChallengeServiceAccount = awsAdminWorkerServiceAccount
    , awsAdminChallengeAuthorityScope = awsAdminPermitIntentAuthorityScope permitIntent
    , awsAdminChallengeAuthorityEndpoint = awsAdminPermitIntentAuthorityEndpoint permitIntent
    , awsAdminChallengeDeadlineMicros = authorityTimeMicros (awsAdminPermitIntentDeadline permitIntent)
    , awsAdminChallengeCanonicalIntent = encodeAwsAdminPermitIntent permitIntent
    }

throwingCoordinatorKubernetes
  :: IORef [Text]
  -> IO (Either Text ())
  -> AwsAdminKubernetesBoundary IO
throwingCoordinatorKubernetes events createEffect =
  AwsAdminKubernetesBoundary
    { createAwsAdminJob = const createEffect
    , observeAwsAdminJob = const (pure (Right Nothing))
    , attachAwsAdminWorker = \_ _ -> pure (Left "must not attach")
    , deleteAwsAdminJob = \_ _ -> writeIORef events ["delete"] >> pure (Right ())
    , observeAwsAdminJobAbsent = \_ _ -> writeIORef events ["delete", "absence"] >> pure (Right True)
    }

-- | Opaque fixture credential (vault_doctrine.md §20.1). Nothing here validates
-- shape — 'validateAdminCredentials' checks only non-emptiness — so both halves
-- are descriptive slugs rather than imitations of production values. The leak
-- canary above asserts their absence from the rendered Job.
adminCredentials :: Credentials
adminCredentials =
  Credentials
    { access_key_id = "fixture-admin-access-key-1"
    , secret_access_key = "fixture-admin-secret-access-key-1"
    , session_token = Nothing
    , region = "us-west-2"
    }

encodePermitIntent :: AwsAdminPermitIntent -> ByteString.ByteString
encodePermitIntent = encodeAwsAdminPermitIntent

must :: (Show errorValue) => Either errorValue value -> value
must = either (error . show) id
