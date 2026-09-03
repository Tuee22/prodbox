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
import Control.Monad (forM_, void)
import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (isLeft, isRight)
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), addUTCTime, picosecondsToDiffTime, secondsToDiffTime)
import GHC.Generics (Generic)
import Network.HTTP.Client
  ( HttpException (..)
  , HttpExceptionContent (..)
  , defaultRequest
  )
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.Fence
  ( BootstrapFenceGeneration
  , BootstrapFenceOwnerWorkerObservation (..)
  , BootstrapLeaseObservation (..)
  , BootstrapSessionFence
  , bootstrapFenceGeneration
  , confirmBootstrapLease
  , reloadBootstrapSessionFence
  )
import Prodbox.Bootstrap.Broker.HostSecretWorker
  ( HostSecretWorkerExpectation
  , firstAttestedRequest
  , mkHostSecretWorkerExpectation
  )
import Prodbox.Bootstrap.Broker.KubernetesAttestation
  ( RawBootstrapLeaseObservation (..)
  , RawWorkerPodObservation (..)
  , attestWorkerPodObservation
  , observeBootstrapLease
  , workerPodNameForRequest
  )
import Prodbox.Bootstrap.Broker.KubernetesWorker
  ( ControllerImageIdentity (..)
  , ControllerImageObservation (..)
  , ControllerSelfObservationScope (..)
  , FenceOwnerWorkerCleanupDecision (..)
  , WorkerPodDecodeReason (..)
  , bootstrapLeaseAnnotationsForFence
  , bootstrapLeaseFromResponse
  , bootstrapLeaseManifestForFence
  , brokerPodsUrl
  , controllerImageFromResponse
  , decodeWorkerPod
  , fenceOwnerWorkerCleanupFromResponse
  , fenceOwnerWorkerFromResponse
  , imageDigestFromRuntimeId
  , imageReferenceRepository
  , kubernetesTransportFailureLabel
  , mkWorkerImagePullReference
  , renderWorkerImagePullReference
  , renderWorkerPodDecodeReason
  , unobservableReason
  , workerAbsenceFromResponse
  , workerAttestationFromResponse
  , workerContainerName
  , workerDeletionFromResponse
  , workerExitFromResponse
  , workerPodAnnotationsForRequest
  , workerPodDeleteOptions
  , workerPodManifestForIntent
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
  , renderWorkerImageDigest
  , secretWorkerCheckpointInvariantViolations
  , secretWorkerRequestIntent
  , unobservableWorkerCheckpoint
  )
import Prodbox.Bootstrap.Broker.Server
  ( BrokerAuthenticationFailure (..)
  )
import Prodbox.Bootstrap.Broker.Settings
  ( bootstrapFenceLeaseDurationSeconds
  , maximumBrokerRequestDeadlineMilliseconds
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
import Prodbox.CheckCode
  ( checkWorkerImagePullReferenceOwner
  , workerImagePullReferenceViolations
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
            (workerDigestReference (sha256 'a'))
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
            (workerTagReference "prodbox-machine-id")
            (sha256 'b')
            (workerPodAnnotationsForRequest canonicalWorkerRequest)
        , runningWorkerPodBodyWith
            canonicalWorkerRequest
            "worker-pod-uid"
            (workerDigestReference (sha256 'a'))
            (sha256 'b')
            (workerPodAnnotationsForRequest canonicalWorkerRequest)
        , runningWorkerPodBodyWith
            canonicalWorkerRequest
            "worker-pod-uid"
            (workerDigestReference (sha256 'a'))
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

    it "reads a failed Pod with no termination message without inventing a receipt" $ do
      let failedBody = failedWorkerPodBodyWithoutReceipt canonicalWorkerRequest
      decodeWorkerPodReason failedBody `shouldBe` Right ()
      attestSecretWorker
        canonicalWorkerRequest
        (workerAttestationFromResponse namespace canonicalWorkerRequest 200 failedBody)
        `shouldSatisfy` isLeft
      workerExitFromResponse namespace canonicalCleanupBinding 200 failedBody
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

  describe "Sprint 2.47 expired-fence worker-absence boundary" $ do
    -- The producer that made `decideBootstrapFenceRetire` wirable. It answers
    -- by fence generation because that is one of only three fields a durable
    -- `BootstrapSessionFence` carries out of the seven a
    -- `SecretWorkerCleanupBinding` needs -- the structural reason the retire
    -- decision had no production caller for four sprints.
    it "proves absence from an empty coordinate and from one occupied by another generation" $ do
      let heldGeneration = bootstrapFenceGeneration canonicalFence
          vacant = fenceOwnerWorkerFromResponse namespace heldGeneration 404 ByteString.empty
          occupied =
            fenceOwnerWorkerFromResponse
              namespace
              heldGeneration
              200
              (fenceOwnerPodBody "replacement-uid" (Map.singleton fenceGenerationAnnotation "6"))
      -- The worker Pod is one fixed coordinate granted by exact name in the
      -- Broker's Role, so at most one can exist: a Pod carrying a DIFFERENT
      -- fence generation is itself proof this generation's worker is gone.
      forM_ [vacant, occupied] $ \observation ->
        absenceGeneration observation `shouldBe` Just heldGeneration
      -- The receipt is derived from the read-back rather than constant, so the
      -- two absences do not share a digest.
      absenceReceipt vacant `shouldNotBe` absenceReceipt occupied

    it "reports a worker for this exact generation as present, terminating or not" $ do
      let heldGeneration = bootstrapFenceGeneration canonicalFence
      forM_ ["7", "0007"] $ \annotationValue ->
        fenceOwnerWorkerFromResponse
          namespace
          heldGeneration
          200
          (fenceOwnerPodBody "worker-pod-uid" (Map.singleton fenceGenerationAnnotation annotationValue))
          `shouldBe` BootstrapFenceOwnerWorkerPresent heldGeneration

    -- Absence is the only outcome that can authorize a fence takeover, so it is
    -- the only one that must be positively proven. Everything ambiguous is
    -- unobservable -- never absence.
    it "never reads an ambiguous answer as absence" $ do
      let heldGeneration = bootstrapFenceGeneration canonicalFence
          annotated value = Map.singleton fenceGenerationAnnotation value
      forM_
        [ fenceOwnerWorkerFromResponse namespace heldGeneration 401 ByteString.empty
        , fenceOwnerWorkerFromResponse namespace heldGeneration 403 ByteString.empty
        , fenceOwnerWorkerFromResponse namespace heldGeneration 500 ByteString.empty
        , fenceOwnerWorkerFromResponse namespace heldGeneration 200 ByteString.empty
        , -- no fence-generation annotation at all
          fenceOwnerWorkerFromResponse
            namespace
            heldGeneration
            200
            (fenceOwnerPodBody "worker-pod-uid" Map.empty)
        , -- present but not a canonical natural
          fenceOwnerWorkerFromResponse
            namespace
            heldGeneration
            200
            (fenceOwnerPodBody "worker-pod-uid" (annotated "7x"))
        , -- a Pod from another namespace can answer for no generation here
          fenceOwnerWorkerFromResponse
            "foreign-namespace"
            heldGeneration
            200
            (fenceOwnerPodBody "worker-pod-uid" (annotated "7"))
        ]
        $ \observation -> observation `shouldSatisfy` isUnobservableFenceOwnerWorker

  describe "Sprint 2.56 terminal expired-owner cleanup" $ do
    it "deletes only a terminal worker for the queried fence generation" $ do
      let heldGeneration = bootstrapFenceGeneration canonicalFence
          matching phase =
            fenceOwnerWorkerCleanupFromResponse
              namespace
              heldGeneration
              200
              ( fenceOwnerPodBodyWithPhase
                  "worker-pod-uid"
                  (Map.singleton fenceGenerationAnnotation "7")
                  phase
              )
      forM_ ["Succeeded", "Failed"] $ \phase ->
        matching phase `shouldBe` FenceOwnerWorkerDeleteTerminated "worker-pod-uid"
      forM_ ["Pending", "Running", "Unknown"] $ \phase ->
        matching phase
          `shouldBe` FenceOwnerWorkerObserved
            (BootstrapFenceOwnerWorkerPresent heldGeneration)

    it "never deletes a foreign-generation terminal worker" $ do
      let heldGeneration = bootstrapFenceGeneration canonicalFence
          decision =
            fenceOwnerWorkerCleanupFromResponse
              namespace
              heldGeneration
              200
              ( fenceOwnerPodBodyWithPhase
                  "replacement-uid"
                  (Map.singleton fenceGenerationAnnotation "8")
                  "Failed"
              )
      decision `shouldSatisfy` isObservedFenceOwnerAbsence

    it "keeps missing, malformed, and unavailable terminal state unobservable" $ do
      let heldGeneration = bootstrapFenceGeneration canonicalFence
          annotated = Map.singleton fenceGenerationAnnotation "7"
          cases =
            [ fenceOwnerWorkerCleanupFromResponse
                namespace
                heldGeneration
                200
                (fenceOwnerPodBody "worker-pod-uid" annotated)
            , fenceOwnerWorkerCleanupFromResponse
                namespace
                heldGeneration
                200
                (fenceOwnerPodBodyWithPhase "worker-pod-uid" annotated "Completed")
            , fenceOwnerWorkerCleanupFromResponse
                namespace
                heldGeneration
                403
                ByteString.empty
            ]
      forM_ cases $ \decision ->
        decision `shouldSatisfy` isObservedFenceOwnerUnobservable

  describe "Sprint 2.48 Kubernetes MicroTime encoding" $ do
    -- Root-caused live and proven server-side with `kubectl create
    -- --dry-run=server`: `Lease.spec.renewTime` is a MicroTime, parsed with the
    -- Go layout "2006-01-02T15:04:05.000000Z07:00" -- exactly six fractional
    -- digits, mandatory. 12, 9, and 0 digits are each rejected `BadRequest`;
    -- only 6 is accepted. Aeson's ToJSON UTCTime renders a VARIABLE count, so
    -- the manifest was rejected deterministically and `prodbox vault init`
    -- could never create its fence Lease.
    it "renders renewTime with exactly six fractional digits, whatever the input precision" $ do
      let renderedFor time =
            LazyByteString.toStrict
              (encode (bootstrapLeaseManifestForFence namespace time Nothing canonicalFence))
          fractionDigits body =
            -- the digits between "renewTime":"…S. and the trailing Z"
            let after = snd (ByteString.breakSubstring "\"renewTime\":\"" body)
                stamp = ByteString.take 40 (ByteString.drop 13 after)
                frac = ByteString.takeWhile (/= 90) (ByteString.drop 20 stamp) -- 90 == 'Z'
             in ByteString.length frac
      forM_ picosecondFixtures $ \time ->
        fractionDigits (renderedFor time) `shouldBe` 6

    it "never renders an instant later than the one it was given" $
      -- Truncation toward the past is the safe direction: the `renewTime >
      -- wallNow` guard in the response validator must not be trippable by the
      -- encoding itself.
      forM_ picosecondFixtures $ \time ->
        ByteString.isInfixOf
          (TextEncoding.encodeUtf8 (Text.pack (take 19 (show time))))
          ( LazyByteString.toStrict
              (encode (bootstrapLeaseManifestForFence namespace time Nothing canonicalFence))
          )
          `shouldBe` False

    -- The status code is the one fact that would have named the MicroTime
    -- defect in a single run; the old text said "GET" on a path the ensure
    -- flow reaches with a POST, and dropped the code.
    it "names the status code rather than a hardcoded verb on a non-success response" $ do
      let observed code =
            bootstrapLeaseFromResponse
              namespace
              (monotonicInstantFromMicros 100)
              wallNow
              (monotonicInstantFromMicros 101)
              code
              ByteString.empty
      observed 400 `shouldBe` BootstrapLeaseUnobservable "Bootstrap Lease request returned HTTP 400"
      observed 500 `shouldBe` BootstrapLeaseUnobservable "Bootstrap Lease request returned HTTP 500"
      observed 400 `shouldNotBe` observed 500

  describe "Sprint 2.48 fence Lease TTL derives from the request budget" $ do
    -- Sprint 2.48 recorded this as an undeclared coupling and left the choice
    -- open; this closes it. The Lease TTL was the literal 300 in the manifest builder while
    -- `maximumBrokerRequestDeadlineMilliseconds` was 5 * 60 * 1000 in another
    -- module -- the same 300 seconds by coincidence, with no stated
    -- relationship. `authorizeFenceUse` bounds every effect by
    -- `min attemptDeadline leaseDeadline`, so raising the request budget alone
    -- would have made every long operation fail closed at
    -- `BootstrapLeaseExpired`, looking like a Lease defect rather than a budget
    -- change.
    it "holds the invariant that makes the Lease deadline never the binding one" $
      -- The Lease is stamped renewTime = now AFTER the request was accepted, so
      -- a TTL at least as long as the maximum request budget puts Lease expiry
      -- at or after request expiry, and the `min` never selects it.
      (1000 * bootstrapFenceLeaseDurationSeconds)
        `shouldSatisfy` (>= maximumBrokerRequestDeadlineMilliseconds)

    it "is the tightest duration satisfying that invariant" $
      -- A longer TTL is safe for the `min` but delays the instant a successor
      -- may declare an abandoned predecessor expired -- which is exactly what
      -- Sprint 2.47's retirement path needs. One second shorter must violate
      -- the invariant, or the constant is not tight.
      (1000 * (bootstrapFenceLeaseDurationSeconds - 1))
        `shouldSatisfy` (< maximumBrokerRequestDeadlineMilliseconds)

    it "publishes the derived duration in the Lease body rather than a literal" $ do
      let body =
            LazyByteString.toStrict
              (encode (bootstrapLeaseManifestForFence namespace wallNow Nothing canonicalFence))
      body
        `shouldSatisfy` ByteString.isInfixOf
          ( "\"leaseDurationSeconds\":"
              <> TextEncoding.encodeUtf8
                (Text.pack (show bootstrapFenceLeaseDurationSeconds))
          )

  describe "Sprint 2.49 attestation names which candidate disagreed about what" $ do
    -- This discarded every candidate's reason and reported only that all of
    -- them failed -- a disjunction rendered as a dead end, and the same shape
    -- Sprints 2.46, 2.47, and 2.48 each closed one layer up.
    it "names each expected operation and what it disagreed about" $ do
      let refusal =
            firstAttestedRequest
              [ expectationFor SecretWorkerUnseal
              , expectationFor SecretWorkerRotateTransitKey
              ]
              attestableWorkerPodBody
      case refusal of
        Right _ -> expectationFailure "a foreign operation must not attest"
        Left detail -> do
          -- both candidates named, each with the field it disagreed about
          Text.unpack detail `shouldContain` "unseal -> worker operation mismatch"
          Text.unpack detail `shouldContain` "rotate-transit -> worker operation mismatch"

    it "accepts a matching candidate standing behind a non-matching one" $
      firstAttestedRequest
        [expectationFor SecretWorkerUnseal, expectationFor SecretWorkerInitialize]
        attestableWorkerPodBody
        `shouldSatisfy` isRight

    -- A different fault: nobody expected anything, which is a caller defect
    -- rather than a Pod that matched nothing. Folding the two was the same
    -- collapse in miniature.
    it "distinguishes an empty expectation list from a Pod that matched nothing" $
      firstAttestedRequest [] attestableWorkerPodBody
        `shouldBe` Left "no expected closed worker operation was supplied"

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

  describe "Sprint 2.59 worker fence revalidation RBAC" $
    it "grants exact worker reads without lifecycle mutation or secret access" $ do
      repoRoot <- getCurrentDirectory
      rbac <-
        readFile (repoRoot </> "charts" </> "bootstrap-broker" </> "templates" </> "tokenreview-rbac.yaml")
      let workerRole = yamlDocumentNamed "bootstrap-secret-worker-self-observer" rbac
      workerRole `shouldContain` "      - pods"
      workerRole `shouldContain` "      - bootstrap-secret-worker"
      workerRole `shouldContain` "      - coordination.k8s.io"
      workerRole `shouldContain` "      - leases"
      workerRole `shouldContain` "      - bootstrap-broker-fence"
      workerRole `shouldContain` "      - get"
      workerRole `shouldNotContain` "      - create"
      workerRole `shouldNotContain` "      - update"
      workerRole `shouldNotContain` "      - delete"
      workerRole `shouldNotContain` "      - secrets"
      workerRole `shouldNotContain` "      - tokenreviews"

  describe "Sprint 2.43 Bootstrap Broker self-observation" $ do
    -- Validation 1: the query is asserted against both labels in the chart's
    -- controller selector. The one-shot worker shares the name label but not
    -- the release-instance label.
    it "selects the exact controller labels the chart renders" $ do
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
      helpers `shouldContain` "app.kubernetes.io/instance: {{ .Release.Name }}"
      brokerPodsUrl "bootstrap-broker"
        `shouldContain` ( "?labelSelector=app.kubernetes.io%2Fname%3D"
                            ++ renderedName
                            ++ "%2Capp.kubernetes.io%2Finstance%3Dbootstrap-broker"
                        )

    it "keeps the one-shot worker outside the controller selector" $ do
      let pullReference = mustRight (mkWorkerImagePullReference controllerRuntimeImage)
          rendered =
            TextEncoding.decodeUtf8
              ( LazyByteString.toStrict
                  ( encode
                      ( workerPodManifestForIntent
                          brokerNamespace
                          pullReference
                          (secretWorkerRequestIntent canonicalWorkerRequest)
                      )
                  )
              )
      rendered `shouldSatisfy` Text.isInfixOf "\"app.kubernetes.io/name\""
      rendered `shouldSatisfy` (not . Text.isInfixOf "\"app.kubernetes.io/instance\"")

    -- Validation 2: Kubernetes omits apiVersion/kind on PodList items, so the
    -- observation must succeed without them. This is the exact payload shape a
    -- live cluster returns for the broker's own self-observation.
    it "observes a PodList whose item omits apiVersion and kind" $
      controllerImageFromResponse
        ControllerObservedForOwnReadiness
        brokerNamespace
        200
        (controllerPodListBody controllerRuntimeImage)
        `shouldSatisfy` isObservedControllerImage

    it "refuses a PodList that does not contain exactly one controller" $
      controllerImageFromResponse
        ControllerObservedForOwnReadiness
        brokerNamespace
        200
        emptyControllerPodListBody
        `shouldSatisfy` (not . isObservedControllerImage)

    it "selects one live controller alongside retained terminal history" $
      controllerImageFromResponse
        ControllerObservedForOwnReadiness
        brokerNamespace
        200
        (controllerPodListBodyWithPhases controllerRuntimeImage ["Succeeded", "Running", "Failed"])
        `shouldSatisfy` isObservedControllerImage

    it "still refuses multiple live candidates, no live candidate, or one malformed item" $ do
      forM_
        [ controllerPodListBodyWithPhases controllerRuntimeImage ["Running", "Pending"]
        , controllerPodListBodyWithPhases controllerRuntimeImage ["Succeeded", "Failed"]
        , controllerPodListBodyFromItems
            [controllerPodItemWithDeletion controllerRuntimeImage "Running" (Just "now") 0]
        , controllerPodListBodyFromItems
            [controllerPodItem controllerRuntimeImage "Running" 0, object []]
        ]
        $ \body ->
          controllerImageFromResponse
            ControllerObservedForOwnReadiness
            brokerNamespace
            200
            body
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
          controllerImageFromResponse
            ControllerObservedForOwnReadiness
            brokerNamespace
            200
            (controllerPodListBody image)
            `shouldSatisfy` isObservedControllerImage

    it "still refuses a foreign controller image repository" $
      controllerImageFromResponse
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

  describe "Sprint 2.51 config digest versus manifest digest" $ do
    -- Validation 1: the structural claim. A container runtime's image ID and a
    -- registry-resolvable reference are the same sixty-four hex characters, so
    -- the separation cannot live in the digest. It lives in the constructor:
    -- a runtime identity has no repository component and is refused.
    it "refuses to build a pull reference out of a runtime image identity" $ do
      mkWorkerImagePullReference (sha256 'a') `shouldSatisfy` isLeft
      mkWorkerImagePullReference ("containerd://" <> sha256 'a') `shouldSatisfy` isLeft
      mkWorkerImagePullReference "" `shouldSatisfy` isLeft
      -- ...while the two shapes a registry can actually resolve are admitted.
      fmap renderWorkerImagePullReference (mkWorkerImagePullReference controllerRuntimeImage)
        `shouldBe` Right controllerRuntimeImage
      fmap
        renderWorkerImagePullReference
        (mkWorkerImagePullReference (workerDigestReference (sha256 'a')))
        `shouldBe` Right (workerDigestReference (sha256 'a'))
      -- A foreign repository stays refused on both shapes.
      mkWorkerImagePullReference "registry.invalid/elsewhere/prodbox-runtime:latest"
        `shouldSatisfy` isLeft

    -- Validation 2: the observation now carries BOTH identities, and they are
    -- different objects. This is the defect stated as an assertion: the value
    -- the Broker used to carry forward was the one no registry can resolve.
    it "carries the declared reference alongside the runtime digest" $ do
      case controllerImageFromResponse
        ControllerObservedForWorkerLaunch
        brokerNamespace
        200
        (controllerPodListBody controllerRuntimeImage) of
        ControllerImageObserved identity -> do
          renderWorkerImagePullReference (controllerImagePullReference identity)
            `shouldBe` controllerRuntimeImage
          renderWorkerImageDigest (controllerImageRuntimeDigest identity)
            `shouldBe` sha256 'a'
          renderWorkerImagePullReference (controllerImagePullReference identity)
            `shouldSatisfy` (not . Text.isInfixOf (sha256 'a'))
        other -> expectationFailure ("expected an observed controller image, got " ++ show other)

    -- Validation 3: the Pod the kubelet is asked to run carries the pullable
    -- reference and nothing derived from the runtime digest.
    it "puts the pullable reference in the worker Pod, not the config digest" $ do
      let pullReference = mustRight (mkWorkerImagePullReference controllerRuntimeImage)
          rendered =
            TextEncoding.decodeUtf8
              ( LazyByteString.toStrict
                  ( encode
                      ( workerPodManifestForIntent
                          namespace
                          pullReference
                          (secretWorkerRequestIntent canonicalWorkerRequest)
                      )
                  )
              )
      rendered `shouldSatisfy` Text.isInfixOf ("\"image\":\"" <> controllerRuntimeImage <> "\"")
      rendered `shouldSatisfy` Text.isInfixOf "\"cpu\":\"250m\""
      rendered `shouldSatisfy` Text.isInfixOf "\"memory\":\"256Mi\""
      rendered `shouldSatisfy` Text.isInfixOf "\"ephemeral-storage\":\"256Mi\""
      rendered `shouldSatisfy` (not . Text.isInfixOf (workerDigestReference (sha256 'a')))

    -- Validation 4: THE surrendered check, and the argument that it costs
    -- nothing, as an assertion rather than a paragraph. The decoder no longer
    -- requires the declared reference to pin a digest, so a tag-declared Pod
    -- decodes; but the runtime comparison one layer down still refuses a Pod
    -- that ran different bytes from the ones the intent pinned.
    it "accepts a tag-declared Pod and still refuses one that ran other bytes" $ do
      let tagBody runtimeDigest =
            runningWorkerPodBodyWith
              canonicalWorkerRequest
              "worker-pod-uid"
              (workerTagReference "prodbox-machine-id")
              runtimeDigest
              (workerPodAnnotationsForRequest canonicalWorkerRequest)
      -- Matching runtime identity: attested, even though the spec pinned no digest.
      attestSecretWorker
        canonicalWorkerRequest
        (workerAttestationFromResponse namespace canonicalWorkerRequest 200 (tagBody (sha256 'a')))
        `shouldSatisfy` isRight
      -- Different runtime identity: still refused. The check that was given up
      -- could not have caught anything this one misses.
      attestSecretWorker
        canonicalWorkerRequest
        (workerAttestationFromResponse namespace canonicalWorkerRequest 200 (tagBody (sha256 'b')))
        `shouldSatisfy` isLeft
      -- And a declared reference that DOES pin a digest must still agree.
      attestSecretWorker
        canonicalWorkerRequest
        ( workerAttestationFromResponse
            namespace
            canonicalWorkerRequest
            200
            ( runningWorkerPodBodyWith
                canonicalWorkerRequest
                "worker-pod-uid"
                (workerDigestReference (sha256 'b'))
                (sha256 'a')
                (workerPodAnnotationsForRequest canonicalWorkerRequest)
            )
        )
        `shouldSatisfy` isLeft

    -- Validation 5: the gained check. A worker Pod declaring a foreign
    -- repository is refused for that reason, which is what compensates for the
    -- surrendered digest equality.
    it "refuses a worker Pod declaring a foreign repository" $
      decodeWorkerPodReason
        ( runningWorkerPodBodyWith
            canonicalWorkerRequest
            "worker-pod-uid"
            "registry.invalid/elsewhere/prodbox-runtime:latest"
            (sha256 'a')
            (workerPodAnnotationsForRequest canonicalWorkerRequest)
        )
        `shouldBe` Left WorkerPodDeclaredImageUnusable

  describe "Sprint 2.51 the worker Pod decode reason speaks" $ do
    -- Validation 1: the arm this sprint's defect actually reaches. An
    -- ImagePullBackOff Pod has a container status whose imageID is empty; a Pod
    -- that has not been scheduled has no container status at all. Both used to
    -- read as "worker Pod response is invalid", identically to a malformed
    -- response.
    it "names a not-yet-started Pod and an unresolved image apart" $ do
      decodeWorkerPodReason notStartedWorkerPodBody
        `shouldBe` Left WorkerPodNotStarted
      decodeWorkerPodReason unresolvedImageWorkerPodBody
        `shouldBe` Left WorkerPodImageNotResolved
      decodeWorkerPodReason "{not json"
        `shouldBe` Left WorkerPodResponseUnparsable

    it "gives every decode reason a distinct rendering" $ do
      let reasons =
            [ WorkerPodResponseUnparsable
            , WorkerPodIdentityUnexpected "metadata.name"
            , WorkerPodContainerNotSole
            , WorkerPodNotStarted
            , WorkerPodContainerStatusNotSole
            , WorkerPodImageNotResolved
            , WorkerPodDeclaredImageUnusable
            , WorkerPodRuntimeImageUnusable
            , WorkerPodImageDeclaredRuntimeDisagree
            , WorkerPodAnnotationUnusable "bootstrap.prodbox.dev/session-accessor"
            ]
          rendered = map renderWorkerPodDecodeReason reasons
      length (nub rendered) `shouldBe` length reasons
      filter Text.null rendered `shouldBe` []

    -- Validation 2: the redaction question, answered as a test rather than as a
    -- claim. A worker Pod's annotations carry a Vault session accessor. Every
    -- reason this decoder can produce for a body containing one must not quote
    -- it, and neither must the reason the host-side decoders surface.
    it "never quotes a value out of the body it refused" $ do
      let accessor = "hvs.SUPER-SECRET-ACCESSOR-VALUE"
          poisoned =
            Map.insert
              "bootstrap.prodbox.dev/session-accessor"
              accessor
              (workerPodAnnotationsForRequest canonicalWorkerRequest)
          bodies =
            [ runningWorkerPodBodyWith
                canonicalWorkerRequest
                "worker-pod-uid"
                "registry.invalid/elsewhere/prodbox-runtime:latest"
                (sha256 'a')
                poisoned
            , unresolvedImageWorkerPodBody
            , runningWorkerPodBodyWith
                canonicalWorkerRequest
                "worker-pod-uid"
                (workerTagReference "prodbox-machine-id")
                (sha256 'a')
                (Map.delete "bootstrap.prodbox.dev/owner-nonce" poisoned)
            ]
      forM_ bodies $ \body -> do
        decodeRefusalText body `shouldSatisfy` (not . Text.isInfixOf accessor)
        -- the same guarantee at the boundary an operator actually reads
        show (workerAttestationFromResponse namespace canonicalWorkerRequest 200 body)
          `shouldSatisfy` (not . Text.isInfixOf accessor . Text.pack)

    -- Validation 3: the runtime identity keeps naming its own layer. Both
    -- shapes a container runtime reports are read; neither becomes a reference.
    it "reads a runtime image identity in both reported shapes" $ do
      imageDigestFromRuntimeId (sha256 'a') `shouldBe` Right (sha256 'a')
      imageDigestFromRuntimeId ("containerd://" <> sha256 'a') `shouldBe` Right (sha256 'a')
      imageDigestFromRuntimeId (workerDigestReference (sha256 'a')) `shouldBe` Right (sha256 'a')
      imageDigestFromRuntimeId "" `shouldSatisfy` isLeft
      imageDigestFromRuntimeId (workerTagReference "prodbox-machine-id") `shouldSatisfy` isLeft

  describe "Sprint 2.51 the pull-reference boundary is compiled-checked" $ do
    -- The guard fires on the exact pre-sprint source shape...
    it "fires on a Pod image built by concatenating a digest" $ do
      let offending =
            unlines
              [ "workerImageReference intent ="
              , "  repository"
              , "    <> \"@\""
              , "    <> renderWorkerImageDigest (secretWorkerIntentImageDigest intent)"
              , "  , \"image\" .= workerImageReference intent"
              ]
      length (workerImagePullReferenceViolations ("src/Prodbox/Bootstrap/Broker/X.hs", offending))
        `shouldBe` 1

    -- ...and passes on every Broker module as it stands.
    it "passes on the current Bootstrap Broker tree" $ do
      repoRoot <- getCurrentDirectory
      findings <- checkWorkerImagePullReferenceOwner repoRoot
      findings `shouldBe` []

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

-- | The compiled worker image repository, spelled once here so the fixtures
-- cannot drift from 'ChartStatics.brokerStaticWorkerImageRepository'. Sprint
-- 2.51 made a worker Pod's declared reference repository-checked, so a fixture
-- naming a foreign registry now fails for that reason instead of the reason the
-- case was written to exercise.
workerImageRepository :: Text.Text
workerImageRepository = "127.0.0.1:30080/prodbox/prodbox-runtime"

-- | A digest-pinned declared reference into the compiled worker repository.
workerDigestReference :: Text.Text -> Text.Text
workerDigestReference digestText = workerImageRepository <> "@" <> digestText

-- | A tag declared reference — the shape the harness actually renders, and the
-- shape Sprint 2.51 made the worker Pod carry.
workerTagReference :: Text.Text -> Text.Text
workerTagReference tag = workerImageRepository <> ":" <> tag

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
  controllerPodListBodyWithPhases image ["Running"]

controllerPodListBodyWithPhases
  :: Text.Text -> [Text.Text] -> ByteString.ByteString
controllerPodListBodyWithPhases image phases =
  controllerPodListBodyFromItems
    (zipWith (controllerPodItem image) phases [0 ..])

controllerPodListBodyFromItems :: [Value] -> ByteString.ByteString
controllerPodListBodyFromItems items =
  LazyByteString.toStrict . encode $
    object
      [ "apiVersion" .= ("v1" :: Text.Text)
      , "kind" .= ("PodList" :: Text.Text)
      , "items" .= items
      ]

controllerPodItem :: Text.Text -> Text.Text -> Int -> Value
controllerPodItem image phase suffix =
  controllerPodItemWithDeletion image phase Nothing suffix

controllerPodItemWithDeletion
  :: Text.Text -> Text.Text -> Maybe Text.Text -> Int -> Value
controllerPodItemWithDeletion image phase deletionTimestamp suffix =
  object
    [ "metadata"
        .= object
          ( [ "name"
                .= ( ( "bootstr"
                         <> fixtureAwsRegion FixtureApBroker57
                         <> "b8f8784f-"
                         <> Text.pack (show suffix)
                     )
                       :: Text.Text
                   )
            , "namespace" .= brokerNamespace
            , "uid" .= ("controller-pod-uid-" <> Text.pack (show suffix))
            , "annotations" .= object []
            ]
              ++ maybe [] (\timestamp -> ["deletionTimestamp" .= timestamp]) deletionTimestamp
          )
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
          [ "phase" .= phase
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

yamlDocumentNamed :: String -> String -> String
yamlDocumentNamed name =
  unlines
    . takeWhile (/= "---")
    . dropWhile (/= "  name: " ++ name)
    . lines

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
    (workerDigestReference (sha256 'a'))
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
    (workerDigestReference (sha256 'a'))
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

failedWorkerPodBodyWithoutReceipt
  :: SecretFreeWorkerRequest -> ByteString.ByteString
failedWorkerPodBodyWithoutReceipt request =
  workerPodBody
    request
    "worker-pod-uid"
    (workerDigestReference (sha256 'a'))
    (sha256 'a')
    (workerPodAnnotationsForRequest request)
    "Failed"
    False
    (object ["terminated" .= object ["exitCode" .= (1 :: Int)]])

-- | The rendered refusal for a body, or the empty text when the body decoded.
-- Named rather than inlined so the redaction case has no @case@ inside a lambda.
decodeRefusalText :: ByteString.ByteString -> Text.Text
decodeRefusalText body =
  either renderWorkerPodDecodeReason (const Text.empty) (decodeWorkerPod namespace body)

-- | 'decodeWorkerPod' projected to its refusal, because a 'PodSnapshot' is not
-- an 'Eq' value and the reason is the whole point of these cases.
decodeWorkerPodReason :: ByteString.ByteString -> Either WorkerPodDecodeReason ()
decodeWorkerPodReason body = void (decodeWorkerPod namespace body)

-- | Sprint 2.51: the exact shape Kubernetes returns for a Pod whose container
-- has not been started — @status@ carries a phase and __no__ @containerStatuses@
-- key at all. Requiring that key made this state an unparsable response.
notStartedWorkerPodBody :: ByteString.ByteString
notStartedWorkerPodBody =
  LazyByteString.toStrict . encode $
    object
      [ "apiVersion" .= ("v1" :: Text.Text)
      , "kind" .= ("Pod" :: Text.Text)
      , "metadata"
          .= object
            [ "name" .= workerPodNameForRequest canonicalWorkerRequest
            , "namespace" .= namespace
            , "uid" .= ("worker-pod-uid" :: Text.Text)
            , "annotations" .= workerPodAnnotationsForRequest canonicalWorkerRequest
            ]
      , "spec"
          .= object
            [ "serviceAccountName" .= ("bootstrap-init-worker" :: Text.Text)
            , "containers"
                .= [ object
                       [ "name" .= workerContainerName
                       , "image" .= workerTagReference "prodbox-machine-id"
                       ]
                   ]
            ]
      , "status" .= object ["phase" .= ("Pending" :: Text.Text)]
      ]

-- | Sprint 2.51: the exact shape of the Pod this sprint's defect produced — a
-- container status exists, and its @imageID@ is the empty string because the
-- kubelet never resolved the image. This is the @ImagePullBackOff@ arm.
unresolvedImageWorkerPodBody :: ByteString.ByteString
unresolvedImageWorkerPodBody =
  LazyByteString.toStrict . encode $
    object
      [ "apiVersion" .= ("v1" :: Text.Text)
      , "kind" .= ("Pod" :: Text.Text)
      , "metadata"
          .= object
            [ "name" .= workerPodNameForRequest canonicalWorkerRequest
            , "namespace" .= namespace
            , "uid" .= ("worker-pod-uid" :: Text.Text)
            , "annotations" .= workerPodAnnotationsForRequest canonicalWorkerRequest
            ]
      , "spec"
          .= object
            [ "serviceAccountName" .= ("bootstrap-init-worker" :: Text.Text)
            , "containers"
                .= [ object
                       [ "name" .= workerContainerName
                       , "image" .= workerTagReference "prodbox-machine-id"
                       ]
                   ]
            ]
      , "status"
          .= object
            [ "phase" .= ("Pending" :: Text.Text)
            , "containerStatuses"
                .= [ object
                       [ "name" .= workerContainerName
                       , "imageID" .= ("" :: Text.Text)
                       , "ready" .= False
                       , "state"
                           .= object
                             [ "waiting"
                                 .= object ["reason" .= ("ImagePullBackOff" :: Text.Text)]
                             ]
                       ]
                   ]
            ]
      ]

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

-- | Sprint 2.47. Identity plus annotations only: the fence-owner presence
-- decoder deliberately does not require a container status or a runtime image
-- digest, because a @Pending@ Pod has neither and is still plainly present.
fenceOwnerPodBody
  :: Text.Text -> Map.Map Text.Text Text.Text -> ByteString.ByteString
fenceOwnerPodBody podUid annotations =
  LazyByteString.toStrict . encode $
    object
      [ "apiVersion" .= ("v1" :: Text.Text)
      , "kind" .= ("Pod" :: Text.Text)
      , "metadata"
          .= object
            [ "name" .= workerPodNameForRequest canonicalWorkerRequest
            , "namespace" .= namespace
            , "uid" .= podUid
            , "annotations" .= annotations
            ]
      ]

fenceOwnerPodBodyWithPhase
  :: Text.Text
  -> Map.Map Text.Text Text.Text
  -> Text.Text
  -> ByteString.ByteString
fenceOwnerPodBodyWithPhase podUid annotations phase =
  LazyByteString.toStrict . encode $
    object
      [ "apiVersion" .= ("v1" :: Text.Text)
      , "kind" .= ("Pod" :: Text.Text)
      , "metadata"
          .= object
            [ "name" .= workerPodNameForRequest canonicalWorkerRequest
            , "namespace" .= namespace
            , "uid" .= podUid
            , "annotations" .= annotations
            ]
      , "status" .= object ["phase" .= phase]
      ]

fenceGenerationAnnotation :: Text.Text
fenceGenerationAnnotation = "bootstrap.prodbox.dev/fence-generation"

-- | Sprint 2.49: a worker Pod body that actually satisfies the host-side
-- attestation preconditions, so a refusal is attributable to the operation
-- rather than to the namespace or ServiceAccount. `firstAttestedRequest`
-- hardcodes the `bootstrap-broker` namespace and the matcher requires the
-- compiled worker ServiceAccount; the shared `workerPodBody` fixture uses
-- neither, which is what the first run of these cases measured.
attestableWorkerPodBody :: ByteString.ByteString
attestableWorkerPodBody =
  LazyByteString.toStrict . encode $
    object
      [ "apiVersion" .= ("v1" :: Text.Text)
      , "kind" .= ("Pod" :: Text.Text)
      , "metadata"
          .= object
            [ "name" .= workerPodNameForRequest canonicalWorkerRequest
            , "namespace" .= ("bootstrap-broker" :: Text.Text)
            , "uid" .= ("worker-pod-uid" :: Text.Text)
            , "annotations" .= workerPodAnnotationsForRequest canonicalWorkerRequest
            ]
      , "spec"
          .= object
            [ "serviceAccountName" .= ("prodbox-bootstrap-secret-worker" :: Text.Text)
            , "containers"
                .= [ object
                       [ "name" .= workerContainerName
                       , "image" .= (workerDigestReference (sha256 'a'))
                       ]
                   ]
            ]
      , "status"
          .= object
            [ "phase" .= ("Running" :: Text.Text)
            , "containerStatuses"
                .= [ object
                       [ "name" .= workerContainerName
                       , "imageID" .= ("containerd://" <> sha256 'a')
                       , "ready" .= True
                       , "state" .= object ["running" .= object []]
                       ]
                   ]
            ]
      ]

-- | Sprint 2.49: an expectation bound to the canonical worker request, varying
-- only the operation, so a refusal is attributable to that one field.
expectationFor :: SecretWorkerOperation -> HostSecretWorkerExpectation
expectationFor operation =
  mkHostSecretWorkerExpectation
    operation
    (mustRight (mkArtifactDigest (digest 'a')))
    (mustRight (mkRequestDigest (digest 'c')))
    (mustRight (mkVaultStorageGeneration "vault-pv-generation-a"))

-- | Sprint 2.48: instants whose picosecond remainders render, under Aeson's
-- variable-width @UTCTime@ encoding, as 0, 3, 6, 9, and 12 fractional digits.
-- Only the six-digit case was ever acceptable to the Kubernetes API server.
picosecondFixtures :: [UTCTime]
picosecondFixtures =
  [ UTCTime (fromGregorian 2026 8 14) (picosecondsToDiffTime picos)
  | picos <-
      [ 21 * 3600 * 1000000000000
      , 21 * 3600 * 1000000000000 + 123000000000
      , 21 * 3600 * 1000000000000 + 123456000000
      , 21 * 3600 * 1000000000000 + 123456789000
      , 21 * 3600 * 1000000000000 + 123456789012
      ]
  ]

absenceReceipt :: BootstrapFenceOwnerWorkerObservation -> Maybe ArtifactDigest
absenceReceipt observation = case observation of
  BootstrapFenceOwnerWorkerAbsent _ receipt -> Just receipt
  _ -> Nothing

absenceGeneration
  :: BootstrapFenceOwnerWorkerObservation -> Maybe BootstrapFenceGeneration
absenceGeneration observation = case observation of
  BootstrapFenceOwnerWorkerAbsent observedGeneration _ -> Just observedGeneration
  _ -> Nothing

isUnobservableFenceOwnerWorker :: BootstrapFenceOwnerWorkerObservation -> Bool
isUnobservableFenceOwnerWorker observation = case observation of
  BootstrapFenceOwnerWorkerUnobservable _ -> True
  _ -> False

isObservedFenceOwnerAbsence :: FenceOwnerWorkerCleanupDecision -> Bool
isObservedFenceOwnerAbsence decision = case decision of
  FenceOwnerWorkerObserved BootstrapFenceOwnerWorkerAbsent {} -> True
  _ -> False

isObservedFenceOwnerUnobservable :: FenceOwnerWorkerCleanupDecision -> Bool
isObservedFenceOwnerUnobservable decision = case decision of
  FenceOwnerWorkerObserved BootstrapFenceOwnerWorkerUnobservable {} -> True
  _ -> False

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
