{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module BootstrapBrokerProductionBoundary
  ( bootstrapBrokerProductionBoundarySuite
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Exception (toException)
import Control.Monad (forM_)
import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (isLeft, isRight)
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), addUTCTime, secondsToDiffTime)
import GHC.Generics (Generic)
import Network.HTTP.Client
  ( HttpException (..)
  , HttpExceptionContent (..)
  , defaultRequest
  )
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
  ( ControllerImageObservation (..)
  , ControllerSelfObservationScope (..)
  , bootstrapLeaseAnnotationsForFence
  , bootstrapLeaseFromResponse
  , brokerPodsUrl
  , controllerImageDigestFromResponse
  , imageReferenceRepository
  , kubernetesTransportFailureLabel
  , unobservableReason
  , workerAbsenceFromResponse
  , workerAttestationFromResponse
  , workerContainerName
  , workerDeletionFromResponse
  , workerExitFromResponse
  , workerPodAnnotationsForRequest
  , workerPodDeleteOptions
  )
import Prodbox.Bootstrap.Broker.ProductionStore
  ( validArtifactDigest
  , validChildEncryptedReceipt
  , validRootInitBinding
  , validUnlockShareThreshold
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
  , secretWorkerCheckpointInvariantViolations
  , unobservableWorkerCheckpoint
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
  , ChildCustodyBinding (..)
  , ChildEncryptedReceipt (..)
  , RootInitBinding (..)
  , mkArtifactDigest
  , mkBootstrapTransactionId
  , mkBurnTokenCiphertext
  , mkChildId
  , mkCustodyGeneration
  , mkPgpEncryptedShare
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
      -- Sprint 3.34: the Kubernetes API egress coordinate is a binding, not a
      -- literal. These are the positive anchors the sprint requires: deleting
      -- the values binding from the template, or reverting it to the Service
      -- port, is a test failure rather than a silent pass.
      networkPolicy `shouldContain` "{{ .Values.kubernetesApiEgress.port }}"
      networkPolicy `shouldContain` "range .Values.kubernetesApiEgress.addresses"
      networkPolicy `shouldNotContain` "port: 443"

  describe "Sprint 2.43 Bootstrap Broker self-observation" $ do
    -- Validation 1: the selector is asserted against the chart's rendered
    -- label, not against a second copy of the string. A restatement is what
    -- the defect was.
    it "selects the label the chart actually renders" $ do
      repoRoot <- getCurrentDirectory
      helpers <-
        readFile
          (repoRoot </> "charts" </> "bootstrap-broker" </> "templates" </> "_helpers.tpl")
      let renderedNames =
            map
              ( Text.unpack
                  . Text.strip
                  . Text.drop (Text.length "app.kubernetes.io/name:")
              )
              . filter (Text.isPrefixOf "app.kubernetes.io/name:")
              . map Text.strip
              . Text.lines
              $ Text.pack helpers
      renderedName <- case renderedNames of
        (sole : _) -> pure sole
        [] -> fail "bootstrap-broker _helpers.tpl renders no app.kubernetes.io/name label"
      renderedName `shouldBe` "prodbox-bootstrap-broker"
      brokerPodsUrl "bootstrap-broker"
        `shouldContain` ("app.kubernetes.io%2Fname%3D" ++ renderedName)

    -- Validation 2: Kubernetes omits apiVersion/kind on PodList items, so the
    -- observation must succeed without them. This is the exact payload shape a
    -- live cluster returns for the broker's own self-observation.
    it "observes a PodList whose item omits apiVersion and kind" $
      controllerImageDigestFromResponse
        ControllerObservedForOwnReadiness
        brokerNamespace
        200
        (controllerPodListBody controllerRuntimeImage)
        `shouldSatisfy` isObservedControllerImage

    it "refuses a PodList that does not contain exactly one controller" $
      controllerImageDigestFromResponse
        ControllerObservedForOwnReadiness
        brokerNamespace
        200
        emptyControllerPodListBody
        `shouldSatisfy` (not . isObservedControllerImage)

    -- Validation 3: both substrate tags validate against the compiled owner;
    -- a foreign repository still fails.
    it "observes the machine-id and AWS-substrate tags the harness renders" $ do
      forM_
        [ "127.0.0.1:30080/prodbox/prodbox-runtime:prodbox-b6883210cc5a4317ab618e6d539263c3"
        , "127.0.0.1:30080/prodbox/prodbox-runtime:prodbox-aws-substrate"
        , "127.0.0.1:30080/prodbox/prodbox-runtime:latest"
        ]
        $ \image ->
          controllerImageDigestFromResponse
            ControllerObservedForOwnReadiness
            brokerNamespace
            200
            (controllerPodListBody image)
            `shouldSatisfy` isObservedControllerImage

    it "still refuses a foreign controller image repository" $
      controllerImageDigestFromResponse
        ControllerObservedForOwnReadiness
        brokerNamespace
        200
        (controllerPodListBody "registry.invalid/elsewhere/prodbox-runtime:latest")
        `shouldSatisfy` (not . isObservedControllerImage)
    it "reads the tag the harness renders on either substrate" $ do
      imageReferenceRepository "127.0.0.1:30080/prodbox/prodbox-runtime:prodbox-b6883210cc5a"
        `shouldBe` Just "127.0.0.1:30080/prodbox/prodbox-runtime"
      imageReferenceRepository "127.0.0.1:30080/prodbox/prodbox-runtime:prodbox-aws-substrate"
        `shouldBe` Just "127.0.0.1:30080/prodbox/prodbox-runtime"
      imageReferenceRepository "127.0.0.1:30080/prodbox/prodbox-runtime:latest"
        `shouldBe` Just "127.0.0.1:30080/prodbox/prodbox-runtime"

    it "keeps a registry-host port out of the tag split, and rejects nothing real" $ do
      imageReferenceRepository "quay.io/jetstack/cert-manager-controller:v1.16.2"
        `shouldBe` Just "quay.io/jetstack/cert-manager-controller"
      imageReferenceRepository "127.0.0.1:30080/prodbox/prodbox-runtime@sha256:abc"
        `shouldBe` Just "127.0.0.1:30080/prodbox/prodbox-runtime"
      imageReferenceRepository "" `shouldBe` Nothing

  describe "Sprint 2.42 Bootstrap Broker transport failure classification" $ do
    -- Validation 1: each constructor produces a distinct reason, by exact
    -- string. The classifier has no wildcard arm, so a new upstream
    -- constructor is a compile error rather than a silent collapse.
    forM_ classifiedTransportFailures $ \(label, exception, expected) ->
      it ("classifies " ++ label ++ " as its own reason") $
        kubernetesTransportFailureLabel exception `shouldBe` expected

    it "gives every classified transport failure a distinct reason" $ do
      let reasons = map (\(_, exception, _) -> kubernetesTransportFailureLabel exception) classifiedTransportFailures
      length (nub reasons) `shouldBe` length reasons

    it "never renders an empty reason" $
      filter
        (Text.null . (\(_, exception, _) -> kubernetesTransportFailureLabel exception))
        classifiedTransportFailures
        `shouldSatisfy` null

    -- Validation 2: the bare site phrase can no longer reach an operator. Every
    -- classified failure composes into a reason strictly longer than the phrase
    -- alone, so `dependency-unavailable: bootstrap-lease: Kubernetes Lease
    -- observation unavailable` with nothing after it is unrepresentable.
    it "never produces the bare site phrase with no detail appended" $ do
      let sitePhrase = "Kubernetes Lease observation unavailable"
          composed =
            map
              (\(_, exception, _) -> unobservableReason sitePhrase (kubernetesTransportFailureLabel exception))
              classifiedTransportFailures
      filter (== sitePhrase) composed `shouldSatisfy` null
      filter (Text.isPrefixOf (sitePhrase <> ": ")) composed `shouldBe` composed

    -- Validation 3: the readiness body is operator-visible, and every request
    -- this boundary issues carries an `Authorization: Bearer` header. A
    -- classifier that rendered its argument would publish it.
    it "leaks neither the bearer token nor the header name into the reason" $ do
      let bearerToken = "eyJhbGciOiJSUzI1NiJ9.super-secret-projected-token"
          leakingHeader = "Authorization: Bearer " <> bearerToken
          credentialCarrying =
            [ HttpExceptionRequest defaultRequest (InvalidRequestHeader (TextEncoding.encodeUtf8 leakingHeader))
            , HttpExceptionRequest defaultRequest (InvalidHeader (TextEncoding.encodeUtf8 leakingHeader))
            , HttpExceptionRequest defaultRequest (InvalidProxySettings leakingHeader)
            , HttpExceptionRequest defaultRequest (InvalidProxyEnvironmentVariable "https_proxy" leakingHeader)
            ]
      forM_ credentialCarrying $ \exception -> do
        let reason =
              unobservableReason
                "Kubernetes Lease observation unavailable"
                (kubernetesTransportFailureLabel exception)
        Text.unpack reason `shouldNotContain` Text.unpack bearerToken
        Text.unpack reason `shouldNotContain` "Authorization"
        Text.unpack reason `shouldNotContain` "Bearer"

  describe "Sprint 2.45 durable-value validity at the broker store boundary" $ do
    -- Before this sprint the predicate applied to every read and CAS of these
    -- payloads was `validValue _ = True`, so `BootstrapStoreCorrupt` was
    -- unreachable for them and any structurally-decodable record was acted on.
    --
    -- The cases below are written against the seam that actually produces an
    -- invalid value in production. These types are built through smart
    -- constructors, so an invalid one cannot be *constructed* — which is
    -- precisely why a predicate over constructed values would be unfalsifiable
    -- and would repeat the defect. They are persisted and read back through
    -- `Serialise`, which reconstructs each field positionally and bypasses
    -- those constructors. Round-tripping a crafted `Text` through the newtype's
    -- own CBOR instance is that bypass, exercised directly.

    it "reproduces the smart-constructor bypass CBOR decoding performs" $ do
      -- The premise the whole sprint rests on, asserted rather than assumed:
      -- `mkArtifactDigest` refuses a non-SHA-256 value, and the CBOR decode
      -- produces one anyway.
      mkArtifactDigest "not-a-sha256-digest" `shouldSatisfy` isLeft
      let bypassed = cborRoundTripText "not-a-sha256-digest" :: ArtifactDigest
      renderArtifactDigest bypassed `shouldBe` "not-a-sha256-digest"
      validArtifactDigest bypassed `shouldBe` False
      validArtifactDigest (mustRight (mkArtifactDigest (digest 'a'))) `shouldBe` True

    it "refuses a root-init binding whose identifiers decode past their constructors" $ do
      validRootInitBinding validRootBinding `shouldBe` True
      validRootInitBinding
        validRootBinding {rootInitTransactionId = cborRoundTripText ""}
        `shouldBe` False
      validRootInitBinding
        validRootBinding {rootInitStorageGeneration = cborRoundTripText ""}
        `shouldBe` False

    it "refuses a child custody receipt carrying no encrypted share" $ do
      -- Not a constructor bypass: the share list is a plain field, and a
      -- receipt with no shares is the applied-but-unrecoverable state. The
      -- custody receipt exists to carry the shares.
      validChildEncryptedReceipt validReceipt `shouldBe` True
      validChildEncryptedReceipt validReceipt {childEncryptedReceiptShares = []}
        `shouldBe` False
      validChildEncryptedReceipt
        validReceipt {childEncryptedReceiptDigest = cborRoundTripText "short"}
        `shouldBe` False

    it "refuses an unlock-bundle threshold its share count cannot meet" $ do
      -- The one payload carrying arithmetic the type does not state: a
      -- threshold above the share count describes a bundle that can never be
      -- reassembled, and a zero threshold one needing no share at all.
      -- `mkInitRecipientCommitment` already refuses both, so a violating bundle
      -- is unconstructible through the smart constructors and only the CBOR
      -- decode can produce one. The decision is therefore asserted over its two
      -- inputs -- the falsifiable form -- rather than over a value no test can
      -- build, which is the bound `validUnlockShareThreshold`'s own Haddock
      -- states.
      validUnlockShareThreshold 3 5 `shouldBe` True
      validUnlockShareThreshold 5 5 `shouldBe` True
      validUnlockShareThreshold 6 5 `shouldBe` False
      validUnlockShareThreshold 0 5 `shouldBe` False
      validUnlockShareThreshold 0 0 `shouldBe` False

    it "refuses a durably-recorded unobservable checkpoint that records no reason" $ do
      -- A persisted "cannot observe" that says nothing is indistinguishable
      -- from one whose reason was lost, which is the distinguishability class
      -- chaos_hardening_doctrine.md section 23 names -- here written to the
      -- store rather than to a log.
      secretWorkerCheckpointInvariantViolations
        (unobservableWorkerCheckpoint "Kubernetes API request failed: connection timed out")
        `shouldBe` []
      secretWorkerCheckpointInvariantViolations (unobservableWorkerCheckpoint "")
        `shouldSatisfy` ((== 1) . length)
      secretWorkerCheckpointInvariantViolations (unobservableWorkerCheckpoint "   \n\t ")
        `shouldSatisfy` ((== 1) . length)

-- | The CBOR bypass, isolated.
--
-- Every smart-constructed newtype exercised here wraps a single `Text` and gets
-- its `Serialise` instance by @deriving anyclass@, i.e. from `Generic`. So the
-- wire shape is the generic one for a single-constructor single-field type, not
-- a bare `Text` -- `TextWrapper` reproduces exactly that shape, which is why
-- encoding it and decoding at the newtype is byte-for-byte what the object
-- store does when it reads a persisted record.
--
-- This is the whole premise of Sprint 2.45 made executable: the value that
-- comes back out of the store never went through the constructor that would
-- have refused it.
newtype TextWrapper = TextWrapper Text.Text
  deriving stock (Generic)
  deriving anyclass (Serialise)

cborRoundTripText :: (Serialise value) => Text.Text -> value
cborRoundTripText raw =
  either (error . show) id (deserialiseOrFail (serialise (TextWrapper raw)))

validRootBinding :: RootInitBinding
validRootBinding =
  RootInitBinding
    { rootInitTransactionId = mustRight (mkBootstrapTransactionId "bootstrap-2045")
    , rootInitStorageGeneration = mustRight (mkVaultStorageGeneration "vault-2045")
    }

validCustodyBinding :: ChildCustodyBinding
validCustodyBinding =
  ChildCustodyBinding
    { childCustodyChildId = mustRight (mkChildId "child-2045")
    , childCustodyStorageGeneration = mustRight (mkVaultStorageGeneration "vault-2045")
    , childCustodyGeneration = mustRight (mkCustodyGeneration 1)
    , childCustodyTransactionId = mustRight (mkBootstrapTransactionId "bootstrap-2045")
    }

validReceipt :: ChildEncryptedReceipt
validReceipt =
  ChildEncryptedReceipt
    { childEncryptedReceiptBinding = validCustodyBinding
    , childEncryptedReceiptShares =
        [mustRight (mkPgpEncryptedShare (TextEncoding.encodeUtf8 "share-a"))]
    , childEncryptedReceiptBurnToken =
        mustRight (mkBurnTokenCiphertext (TextEncoding.encodeUtf8 "burn"))
    , childEncryptedReceiptDigest = mustRight (mkArtifactDigest (digest 'b'))
    }

-- | Sprint 2.43: the namespace the broker chart deploys into.
brokerNamespace :: Text.Text
brokerNamespace = "bootstrap-broker"

controllerRuntimeImage :: Text.Text
controllerRuntimeImage =
  "127.0.0.1:30080/prodbox/prodbox-runtime:prodbox-b6883210cc5a4317ab618e6d539263c3"

-- | A @PodList@ shaped exactly as the Kubernetes API returns one: @apiVersion@
-- and @kind@ on the list, and __absent__ on the item. That absence is the
-- Sprint 2.43 defect.
controllerPodListBody :: Text.Text -> ByteString.ByteString
controllerPodListBody image =
  LazyByteString.toStrict . encode $
    object
      [ "apiVersion" .= ("v1" :: Text.Text)
      , "kind" .= ("PodList" :: Text.Text)
      , "items"
          .= [ object
                 [ "metadata"
                     .= object
                       [ "name" .= ("bootstrap-broker-57b8f8784f-lwdkt" :: Text.Text)
                       , "namespace" .= brokerNamespace
                       , "uid" .= ("controller-pod-uid" :: Text.Text)
                       , "annotations" .= object []
                       ]
                 , "spec"
                     .= object
                       [ "serviceAccountName" .= ("prodbox-bootstrap-broker" :: Text.Text)
                       , "containers"
                           .= [ object
                                  [ "name" .= ("bootstrap-broker" :: Text.Text)
                                  , "image" .= image
                                  ]
                              ]
                       ]
                 , "status"
                     .= object
                       [ "phase" .= ("Running" :: Text.Text)
                       , "containerStatuses"
                           .= [ object
                                  [ "name" .= ("bootstrap-broker" :: Text.Text)
                                  , "imageID" .= sha256 'a'
                                  , "ready" .= True
                                  , "state" .= object ["running" .= object []]
                                  ]
                              ]
                       ]
                 ]
             ]
      ]

emptyControllerPodListBody :: ByteString.ByteString
emptyControllerPodListBody =
  LazyByteString.toStrict . encode $
    object
      [ "apiVersion" .= ("v1" :: Text.Text)
      , "kind" .= ("PodList" :: Text.Text)
      , "items" .= ([] :: [Value])
      ]

isObservedControllerImage :: ControllerImageObservation -> Bool
isObservedControllerImage observation = case observation of
  ControllerImageObserved _ -> True
  _ -> False

-- | The transport failures a live cluster can actually produce at this
-- boundary, each paired with the exact reason it must render as. Constructors
-- whose payloads are unconstructible through the public @http-client@ API
-- (@StatusCodeException@ needs a @Response@; @HttpZlibException@ needs a
-- @ZlibException@) are covered by the classifier's exhaustive match rather than
-- by a fixture.
classifiedTransportFailures :: [(String, HttpException, Text.Text)]
classifiedTransportFailures =
  [
    ( "a dropped packet"
    , HttpExceptionRequest defaultRequest ConnectionTimeout
    , "connecting to the Kubernetes API timed out (no route, or a network policy dropped the packet)"
    )
  ,
    ( "a refused connection"
    , HttpExceptionRequest defaultRequest (ConnectionFailure (toException (userError "refused")))
    , "connecting to the Kubernetes API failed"
    )
  ,
    ( "a slow server"
    , HttpExceptionRequest defaultRequest ResponseTimeout
    , "the Kubernetes API accepted the connection and did not answer in time"
    )
  ,
    ( "a silent close"
    , HttpExceptionRequest defaultRequest NoResponseDataReceived
    , "the Kubernetes API closed the connection without answering"
    )
  ,
    ( "a mid-request close"
    , HttpExceptionRequest defaultRequest ConnectionClosed
    , "the connection to the Kubernetes API was closed mid-request"
    )
  ,
    ( "a socket or TLS failure"
    , HttpExceptionRequest defaultRequest (InternalException (toException (userError "tls")))
    , "an underlying socket or TLS layer failed"
    )
  ,
    ( "a plaintext endpoint"
    , HttpExceptionRequest defaultRequest TlsNotSupported
    , "the Kubernetes API endpoint does not support TLS"
    )
  ,
    ( "an invalid URL"
    , InvalidUrlException "http://%" "bad"
    , "the request URL is invalid"
    )
  ,
    ( "a non-compliant request header"
    , HttpExceptionRequest defaultRequest (InvalidRequestHeader "Authorization: Bearer leaked")
    , "the request carried a non-compliant header"
    )
  ,
    ( "an unparseable response header"
    , HttpExceptionRequest defaultRequest (InvalidHeader "Authorization: Bearer leaked")
    , "the Kubernetes API returned an unparseable header"
    )
  ,
    ( "an unparseable status line"
    , HttpExceptionRequest defaultRequest (InvalidStatusLine "garbage")
    , "the Kubernetes API returned an unparseable status line"
    )
  ,
    ( "overlong headers"
    , HttpExceptionRequest defaultRequest OverlongHeaders
    , "the Kubernetes API returned overlong headers"
    )
  ,
    ( "too many header fields"
    , HttpExceptionRequest defaultRequest TooManyHeaderFields
    , "the Kubernetes API returned too many header fields"
    )
  ,
    ( "too many redirects"
    , HttpExceptionRequest defaultRequest (TooManyRedirects [])
    , "the Kubernetes API redirected too many times"
    )
  ,
    ( "incomplete headers"
    , HttpExceptionRequest defaultRequest IncompleteHeaders
    , "the Kubernetes API returned incomplete headers"
    )
  ,
    ( "invalid chunk headers"
    , HttpExceptionRequest defaultRequest InvalidChunkHeaders
    , "the Kubernetes API returned invalid chunk headers"
    )
  ,
    ( "a short response body"
    , HttpExceptionRequest defaultRequest (ResponseBodyTooShort 10 4)
    , "the Kubernetes API response body was shorter than declared"
    )
  ,
    ( "a mismatched request body stream"
    , HttpExceptionRequest defaultRequest (WrongRequestBodyStreamSize 10 4)
    , "the request body stream size did not match its declaration"
    )
  ,
    ( "an invalid destination host"
    , HttpExceptionRequest defaultRequest (InvalidDestinationHost "::")
    , "the Kubernetes API destination host is invalid"
    )
  ,
    ( "invalid proxy settings"
    , HttpExceptionRequest defaultRequest (InvalidProxySettings "bad")
    , "the proxy settings are invalid"
    )
  ,
    ( "an invalid proxy environment variable"
    , HttpExceptionRequest defaultRequest (InvalidProxyEnvironmentVariable "https_proxy" "bad")
    , "the proxy environment variable is invalid"
    )
  ]

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
