{-# LANGUAGE OverloadedStrings #-}

module BootstrapBrokerProductionBoundary
  ( bootstrapBrokerProductionBoundarySuite
  )
where

import Control.Monad (forM_)
import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (isLeft, isRight)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), addUTCTime, secondsToDiffTime)
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.Fence
  ( BootstrapLeaseObservation (..)
  , BootstrapSessionFence
  , bootstrapFenceGeneration
  , confirmBootstrapLease
  , reloadBootstrapSessionFence
  )
import Prodbox.Bootstrap.Broker.KubernetesAttestation
  ( RawBootstrapLeaseObservation (..)
  , RawWorkerPodObservation (..)
  , attestWorkerPodObservation
  , observeBootstrapLease
  , workerPodNameForRequest
  )
import Prodbox.Bootstrap.Broker.KubernetesWorker
  ( bootstrapLeaseAnnotationsForFence
  , bootstrapLeaseFromResponse
  , workerAbsenceFromResponse
  , workerAttestationFromResponse
  , workerContainerName
  , workerDeletionFromResponse
  , workerExitFromResponse
  , workerPodAnnotationsForRequest
  , workerPodDeleteOptions
  )
import Prodbox.Bootstrap.Broker.Request
  ( BrokerServiceIdentity
  , mkBrokerServiceIdentity
  , mkRequestDigest
  , mkSecretPayload
  )
import Prodbox.Bootstrap.Broker.SecretIngress
  ( SecretIngressError (..)
  , decodeSecretIngressFrame
  , encodeSecretIngressFrame
  )
import Prodbox.Bootstrap.Broker.SecretWorker
  ( SecretFreeWorkerRequest
  , SecretWorkerCleanupBinding (..)
  , SecretWorkerLifecycleObservation (..)
  , SecretWorkerOperation (..)
  , attestSecretWorker
  , mkSecretFreeWorkerRequest
  , mkWorkerImageDigest
  , mkWorkerPodUid
  , mkWorkerServiceAccount
  , mkWorkerSessionAccessor
  , mkWorkerSessionId
  )
import Prodbox.Bootstrap.Broker.Server
  ( BrokerAuthenticationFailure (..)
  )
import Prodbox.Bootstrap.Broker.TokenReview
  ( BrokerTokenReviewResult (..)
  , BrokerTokenReviewUser (..)
  , brokerTokenReviewAudience
  , decideBrokerTokenReview
  , tokenReviewRequestValue
  )
import Prodbox.Bootstrap.Broker.Types
  ( ArtifactDigest
  , mkArtifactDigest
  , mkVaultStorageGeneration
  , renderArtifactDigest
  )
import Prodbox.ControlPlane.Deadline
  ( deadlineFromInstant
  , monotonicInstantFromMicros
  )
import Prodbox.Lifecycle.Lease (mkOwnerNonce)
import System.Directory (getCurrentDirectory)
import System.FilePath ((</>))
import TestSupport

bootstrapBrokerProductionBoundarySuite :: SuiteBuilder ()
bootstrapBrokerProductionBoundarySuite = do
  describe "Bootstrap Broker Kubernetes TokenReview" $ do
    it "admits only the exact ServiceAccount identity and audience" $ do
      decideBrokerTokenReview namespace expectedIdentity validReview
        `shouldBe` Right expectedIdentity
      forM_ refusedReviews $ \review ->
        decideBrokerTokenReview namespace expectedIdentity review
          `shouldBe` Left BrokerAuthenticationRejected

    it "rejects malformed bearer bytes before constructing a TokenReview" $ do
      tokenReviewRequestValue ByteString.empty `shouldSatisfy` isLeft
      tokenReviewRequestValue "contains space" `shouldSatisfy` isLeft
      tokenReviewRequestValue (ByteString.pack [0xff]) `shouldSatisfy` isLeft

  describe "Bootstrap Broker exact Kubernetes attestation" $ do
    it "projects a healthy exact Pod into the existing attestation proof" $ do
      attestSecretWorker
        canonicalWorkerRequest
        (attestWorkerPodObservation canonicalWorkerRequest canonicalPodObservation)
        `shouldSatisfy` isRight

    it "refuses wrong name, UID, image, ServiceAccount, binding, and deleting state" $ do
      let cases =
            [ canonicalPodObservation {observedWorkerPodName = "foreign-worker"}
            , canonicalPodObservation {observedWorkerPodUid = "foreign-pod-uid"}
            , canonicalPodObservation {observedWorkerImageDigest = sha256 'b'}
            , canonicalPodObservation {observedWorkerServiceAccount = "foreign-worker"}
            , canonicalPodObservation {observedWorkerRequestDigest = digest 'b'}
            , canonicalPodObservation {observedWorkerDeletionTimestamp = Just "now"}
            ]
      forM_ cases $ \observation ->
        attestSecretWorker
          canonicalWorkerRequest
          (attestWorkerPodObservation canonicalWorkerRequest observation)
          `shouldSatisfy` isLeft

    it "projects an exact Lease and preserves read-back resourceVersion" $ do
      let lease = observeBootstrapLease canonicalLeaseObservation
      confirmBootstrapLease
        (monotonicInstantFromMicros 1)
        canonicalFence
        lease
        `shouldSatisfy` isRight

    it "refuses malformed or stale Lease bindings" $ do
      observeBootstrapLease
        (leaseObservationAt 0)
        `shouldSatisfy` isUnobservableLease
      confirmBootstrapLease
        (monotonicInstantFromMicros 10_000)
        canonicalFence
        (observeBootstrapLease canonicalLeaseObservation)
        `shouldSatisfy` isLeft

  describe "Bootstrap Broker native Kubernetes cleanup boundary" $ do
    it "decodes only the exact named, digest-pinned worker Pod" $ do
      attestSecretWorker
        canonicalWorkerRequest
        ( workerAttestationFromResponse
            namespace
            canonicalWorkerRequest
            200
            (runningWorkerPodBody canonicalWorkerRequest)
        )
        `shouldSatisfy` isRight
      forM_
        [ runningWorkerPodBodyWith
            canonicalWorkerRequest
            "foreign-pod-uid"
            ("registry.invalid/prodbox@" <> sha256 'a')
            (sha256 'a')
            (workerPodAnnotationsForRequest canonicalWorkerRequest)
        , runningWorkerPodBodyWith
            canonicalWorkerRequest
            "worker-pod-uid"
            "registry.invalid/prodbox:mutable"
            (sha256 'a')
            (workerPodAnnotationsForRequest canonicalWorkerRequest)
        , runningWorkerPodBodyWith
            canonicalWorkerRequest
            "worker-pod-uid"
            ("registry.invalid/prodbox@" <> sha256 'a')
            (sha256 'b')
            (workerPodAnnotationsForRequest canonicalWorkerRequest)
        , runningWorkerPodBodyWith
            canonicalWorkerRequest
            "worker-pod-uid"
            ("registry.invalid/prodbox@" <> sha256 'a')
            (sha256 'a')
            ( Map.insert
                "bootstrap.prodbox.dev/request-digest"
                (digest 'b')
                (workerPodAnnotationsForRequest canonicalWorkerRequest)
            )
        ]
        $ \body ->
          attestSecretWorker
            canonicalWorkerRequest
            (workerAttestationFromResponse namespace canonicalWorkerRequest 200 body)
            `shouldSatisfy` isLeft

    it "binds exit to UID, session, request, generation, and termination receipt" $ do
      workerExitFromResponse
        namespace
        canonicalCleanupBinding
        200
        (exitedWorkerPodBody canonicalWorkerRequest (renderArtifactDigest cleanupDigest))
        `shouldBe` SecretWorkerProcessExited canonicalCleanupBinding 0
      workerExitFromResponse
        namespace
        canonicalCleanupBinding
        200
        (exitedWorkerPodBody canonicalWorkerRequest (digest 'e'))
        `shouldSatisfy` isUnobservableLifecycle

    it "deletes with the exact UID precondition and requires positive 404 read-back" $ do
      let deleteBody = LazyByteString.toStrict (encode (workerPodDeleteOptions canonicalCleanupBinding))
      deleteBody
        `shouldSatisfy` ByteString.isInfixOf "\"uid\":\"worker-pod-uid\""
      workerDeletionFromResponse canonicalCleanupBinding 202 ByteString.empty
        `shouldBe` SecretWorkerPodDeleted canonicalCleanupBinding
      workerDeletionFromResponse canonicalCleanupBinding 409 ByteString.empty
        `shouldSatisfy` isUnobservableLifecycle
      workerAbsenceFromResponse namespace canonicalCleanupBinding 404 ByteString.empty
        `shouldBe` SecretWorkerPodAbsent canonicalCleanupBinding
      workerAbsenceFromResponse
        namespace
        canonicalCleanupBinding
        200
        (podIdentityBody "replacement-uid")
        `shouldSatisfy` isUnobservableLifecycle

    it "maps an exact fresh Kubernetes Lease conservatively and refuses a foreign holder" $ do
      let before = monotonicInstantFromMicros 100
          after = monotonicInstantFromMicros 101
          exact =
            bootstrapLeaseFromResponse
              namespace
              before
              wallNow
              after
              200
              (bootstrapLeaseBody canonicalFence "broker-owner" (addUTCTime (-1) wallNow) 10)
          foreignLease =
            bootstrapLeaseFromResponse
              namespace
              before
              wallNow
              after
              200
              (bootstrapLeaseBody canonicalFence "foreign-owner" (addUTCTime (-1) wallNow) 10)
      confirmBootstrapLease after canonicalFence exact `shouldSatisfy` isRight
      foreignLease `shouldSatisfy` isUnobservableLease

  describe "Bootstrap Broker one-shot secret ingress" $ do
    it "round-trips one canonical exact-bound frame without printable plaintext" $ do
      let payload = mustRight (mkSecretPayload 64 "operator-password")
          framed = mustRight (encodeSecretIngressFrame 64 canonicalWorkerRequest payload)
      decodeSecretIngressFrame 64 canonicalWorkerRequest framed
        `shouldBe` Right payload
      show payload `shouldNotContain` "operator-password"

    it "refuses a foreign request binding, truncation, and a smaller payload bound" $ do
      let payload = mustRight (mkSecretPayload 64 "operator-password")
          framed = mustRight (encodeSecretIngressFrame 64 canonicalWorkerRequest payload)
      decodeSecretIngressFrame 64 alternateWorkerRequest framed
        `shouldBe` Left SecretIngressBindingMismatch
      decodeSecretIngressFrame 64 canonicalWorkerRequest (framed <> "x")
        `shouldBe` Left SecretIngressTruncated
      encodeSecretIngressFrame 4 canonicalWorkerRequest payload
        `shouldBe` Left (SecretIngressPayloadTooLarge 4 17)

  describe "Bootstrap Broker rendered authentication boundary" $ do
    it "grants create-only TokenReview and probes the loopback listener in-container" $ do
      repoRoot <- getCurrentDirectory
      let templates = repoRoot </> "charts" </> "bootstrap-broker" </> "templates"
      rbac <- readFile (templates </> "tokenreview-rbac.yaml")
      deployment <- readFile (templates </> "deployment.yaml")
      networkPolicy <- readFile (templates </> "networkpolicy.yaml")
      rbac `shouldContain` "authentication.k8s.io"
      rbac `shouldContain` "tokenreviews"
      rbac `shouldContain` "      - create"
      rbac `shouldNotContain` "      - \"*\""
      rbac `shouldContain` "      - bootstrap-secret-worker"
      rbac `shouldContain` "      - bootstrap-broker-fence"
      rbac `shouldContain` "      - delete"
      rbac `shouldNotContain` "pods/exec"
      deployment `shouldContain` "/usr/bin/curl"
      deployment
        `shouldContain` "http://127.0.0.1:{{ .Values.listener.port }}{{ .Values.probes.liveness }}"
      deployment `shouldNotContain` "httpGet:"
      deployment `shouldNotContain` "env:"
      networkPolicy `shouldContain` "port: 443"

namespace :: Text.Text
namespace = "prodbox"

expectedIdentity :: BrokerServiceIdentity
expectedIdentity = mustRight (mkBrokerServiceIdentity "prodbox-lifecycle-authority")

validReview :: BrokerTokenReviewResult
validReview =
  BrokerTokenReviewResult
    { tokenReviewAuthenticated = True
    , tokenReviewAudiences = [brokerTokenReviewAudience]
    , tokenReviewUser =
        Just
          BrokerTokenReviewUser
            { tokenReviewUsername =
                "system:serviceaccount:prodbox:prodbox-lifecycle-authority"
            , tokenReviewUid = "service-account-uid"
            , tokenReviewGroups =
                [ "system:authenticated"
                , "system:serviceaccounts"
                , "system:serviceaccounts:prodbox"
                ]
            }
    , tokenReviewError = Nothing
    }

refusedReviews :: [BrokerTokenReviewResult]
refusedReviews =
  [ validReview {tokenReviewAuthenticated = False}
  , validReview {tokenReviewAudiences = []}
  , validReview {tokenReviewAudiences = [brokerTokenReviewAudience, brokerTokenReviewAudience]}
  , validReview {tokenReviewUser = Nothing}
  , validReview
      { tokenReviewUser =
          fmap (\user -> user {tokenReviewUsername = "foreign"}) (tokenReviewUser validReview)
      }
  , validReview
      { tokenReviewUser = fmap (\user -> user {tokenReviewUid = ""}) (tokenReviewUser validReview)
      }
  , validReview
      { tokenReviewUser = fmap (\user -> user {tokenReviewGroups = []}) (tokenReviewUser validReview)
      }
  , validReview {tokenReviewError = Just "review refused"}
  ]

canonicalFence :: BootstrapSessionFence
canonicalFence =
  mustRight
    ( reloadBootstrapSessionFence
        7
        (mustRight (mkOwnerNonce "broker-owner"))
        (mustRight (mkArtifactDigest (digest 'a')))
        (mustRight (mkRequestDigest (digest 'c')))
        (mustRight (mkVaultStorageGeneration "vault-pv-generation-a"))
        5_000
    )

alternateFence :: BootstrapSessionFence
alternateFence =
  mustRight
    ( reloadBootstrapSessionFence
        7
        (mustRight (mkOwnerNonce "broker-owner"))
        (mustRight (mkArtifactDigest (digest 'a')))
        (mustRight (mkRequestDigest (digest 'b')))
        (mustRight (mkVaultStorageGeneration "vault-pv-generation-a"))
        5_000
    )

canonicalWorkerRequest :: SecretFreeWorkerRequest
canonicalWorkerRequest = workerRequestFor canonicalFence

alternateWorkerRequest :: SecretFreeWorkerRequest
alternateWorkerRequest = workerRequestFor alternateFence

workerRequestFor :: BootstrapSessionFence -> SecretFreeWorkerRequest
workerRequestFor =
  mkSecretFreeWorkerRequest
    SecretWorkerInitialize
    (mustRight (mkWorkerPodUid "worker-pod-uid"))
    (mustRight (mkWorkerImageDigest (sha256 'a')))
    (mustRight (mkWorkerServiceAccount "bootstrap-init-worker"))
    (mustRight (mkWorkerSessionId "worker-session"))
    (mustRight (mkWorkerSessionAccessor "worker-accessor"))

canonicalPodObservation :: RawWorkerPodObservation
canonicalPodObservation =
  RawWorkerPodObservation
    { observedWorkerPodName = workerPodNameForRequest canonicalWorkerRequest
    , observedWorkerPodUid = "worker-pod-uid"
    , observedWorkerImageDigest = sha256 'a'
    , observedWorkerServiceAccount = "bootstrap-init-worker"
    , observedWorkerSessionId = "worker-session"
    , observedWorkerSessionAccessor = "worker-accessor"
    , observedWorkerOperation = SecretWorkerInitialize
    , observedWorkerFenceGeneration = 7
    , observedWorkerOwnerNonce = "broker-owner"
    , observedWorkerActionDigest = digest 'a'
    , observedWorkerRequestDigest = digest 'c'
    , observedWorkerStorageGeneration = "vault-pv-generation-a"
    , observedWorkerOperationDeadlineMicros = 5_000
    , observedWorkerPhase = "Running"
    , observedWorkerContainerReady = True
    , observedWorkerDeletionTimestamp = Nothing
    }

canonicalLeaseObservation :: RawBootstrapLeaseObservation
canonicalLeaseObservation = leaseObservationAt 7

cleanupDigest :: ArtifactDigest
cleanupDigest = mustRight (mkArtifactDigest (digest 'd'))

canonicalCleanupBinding :: SecretWorkerCleanupBinding
canonicalCleanupBinding =
  SecretWorkerCleanupBinding
    { cleanupWorkerPodUid = mustRight (mkWorkerPodUid "worker-pod-uid")
    , cleanupWorkerSessionId = mustRight (mkWorkerSessionId "worker-session")
    , cleanupWorkerSessionAccessor = mustRight (mkWorkerSessionAccessor "worker-accessor")
    , cleanupWorkerRequestDigest = mustRight (mkRequestDigest (digest 'c'))
    , cleanupWorkerStorageGeneration =
        mustRight (mkVaultStorageGeneration "vault-pv-generation-a")
    , cleanupWorkerFenceGeneration = bootstrapFenceGeneration canonicalFence
    , cleanupWorkerReceiptDigest = cleanupDigest
    }

runningWorkerPodBody :: SecretFreeWorkerRequest -> ByteString.ByteString
runningWorkerPodBody request =
  runningWorkerPodBodyWith
    request
    "worker-pod-uid"
    ("registry.invalid/prodbox@" <> sha256 'a')
    (sha256 'a')
    (workerPodAnnotationsForRequest request)

runningWorkerPodBodyWith
  :: SecretFreeWorkerRequest
  -> Text.Text
  -> Text.Text
  -> Text.Text
  -> Map.Map Text.Text Text.Text
  -> ByteString.ByteString
runningWorkerPodBodyWith request podUid declaredImage runtimeDigest annotations =
  workerPodBody
    request
    podUid
    declaredImage
    runtimeDigest
    annotations
    "Running"
    True
    (object ["running" .= object []])

exitedWorkerPodBody
  :: SecretFreeWorkerRequest -> Text.Text -> ByteString.ByteString
exitedWorkerPodBody request receiptDigest =
  workerPodBody
    request
    "worker-pod-uid"
    ("registry.invalid/prodbox@" <> sha256 'a')
    (sha256 'a')
    (workerPodAnnotationsForRequest request)
    "Succeeded"
    False
    ( object
        [ "terminated"
            .= object
              [ "exitCode" .= (0 :: Int)
              , "message" .= receiptDigest
              ]
        ]
    )

workerPodBody
  :: SecretFreeWorkerRequest
  -> Text.Text
  -> Text.Text
  -> Text.Text
  -> Map.Map Text.Text Text.Text
  -> Text.Text
  -> Bool
  -> Value
  -> ByteString.ByteString
workerPodBody request podUid declaredImage runtimeDigest annotations phase ready state =
  LazyByteString.toStrict . encode $
    object
      [ "apiVersion" .= ("v1" :: Text.Text)
      , "kind" .= ("Pod" :: Text.Text)
      , "metadata"
          .= object
            [ "name" .= workerPodNameForRequest request
            , "namespace" .= namespace
            , "uid" .= podUid
            , "annotations" .= annotations
            ]
      , "spec"
          .= object
            [ "serviceAccountName" .= ("bootstrap-init-worker" :: Text.Text)
            , "containers"
                .= [ object
                       [ "name" .= workerContainerName
                       , "image" .= declaredImage
                       ]
                   ]
            ]
      , "status"
          .= object
            [ "phase" .= phase
            , "containerStatuses"
                .= [ object
                       [ "name" .= workerContainerName
                       , "imageID" .= ("containerd://" <> runtimeDigest)
                       , "ready" .= ready
                       , "state" .= state
                       ]
                   ]
            ]
      ]

podIdentityBody :: Text.Text -> ByteString.ByteString
podIdentityBody podUid =
  LazyByteString.toStrict . encode $
    object
      [ "apiVersion" .= ("v1" :: Text.Text)
      , "kind" .= ("Pod" :: Text.Text)
      , "metadata"
          .= object
            [ "name" .= workerPodNameForRequest canonicalWorkerRequest
            , "namespace" .= namespace
            , "uid" .= podUid
            ]
      ]

bootstrapLeaseBody
  :: BootstrapSessionFence
  -> Text.Text
  -> UTCTime
  -> Natural
  -> ByteString.ByteString
bootstrapLeaseBody fence holder renewTime duration =
  LazyByteString.toStrict . encode $
    object
      [ "apiVersion" .= ("coordination.k8s.io/v1" :: Text.Text)
      , "kind" .= ("Lease" :: Text.Text)
      , "metadata"
          .= object
            [ "name" .= ("bootstrap-broker-fence" :: Text.Text)
            , "namespace" .= namespace
            , "resourceVersion" .= ("lease-resource-version" :: Text.Text)
            , "annotations" .= bootstrapLeaseAnnotationsForFence fence
            ]
      , "spec"
          .= object
            [ "holderIdentity" .= holder
            , "leaseDurationSeconds" .= duration
            , "renewTime" .= renewTime
            ]
      ]

wallNow :: UTCTime
wallNow = UTCTime (fromGregorian 2026 7 31) (secondsToDiffTime 0)

leaseObservationAt :: Natural -> RawBootstrapLeaseObservation
leaseObservationAt generation =
  RawBootstrapLeaseObserved
    { observedLeaseFenceGeneration = generation
    , observedLeaseOwnerNonce = "broker-owner"
    , observedLeaseActionDigest = digest 'a'
    , observedLeaseRequestDigest = digest 'c'
    , observedLeaseStorageGeneration = "vault-pv-generation-a"
    , observedLeaseOperationDeadlineMicros = 5_000
    , observedLeaseLocalDeadline =
        deadlineFromInstant (monotonicInstantFromMicros 5_000)
    , observedLeaseResourceVersion = "lease-resource-version"
    }

isUnobservableLease :: BootstrapLeaseObservation -> Bool
isUnobservableLease observation = case observation of
  BootstrapLeaseUnobservable _ -> True
  _ -> False

isUnobservableLifecycle :: SecretWorkerLifecycleObservation -> Bool
isUnobservableLifecycle observation = case observation of
  SecretWorkerLifecycleUnobservable _ -> True
  _ -> False

sha256 :: Char -> Text.Text
sha256 character = "sha256:" <> digest character

digest :: Char -> Text.Text
digest character = Text.replicate 64 (Text.singleton character)

mustRight :: (Show error) => Either error value -> value
mustRight = either (error . show) id
