{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneEksDrainReadBackReceiptRepository
  ( controlPlaneEksDrainReadBackReceiptRepositorySuite
  )
where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , modifyIORef'
  , newIORef
  , readIORef
  )
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import EksClientAuthProjectionFixture (testEksClientAuthProjection)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientProviders (..)
  , AuthenticatedTransportBounds
  , mkAuthenticatedClientTransport
  , mkAuthenticatedTransportBounds
  )
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (CallerOperatorCli)
  )
import Prodbox.ControlPlane.Client
  ( controlPlaneClientWithTransport
  , mkLifecycleAuthorityEndpoint
  )
import Prodbox.ControlPlane.Codec
  ( encodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.Coordinate
  ( AuthorityScope
  , mkAuthorityScope
  )
import Prodbox.ControlPlane.EksClientAuthProjection (EksClientAuthProjection)
import Prodbox.ControlPlane.EksDrainIntentClient
  ( EksDrainIntentClient (..)
  )
import Prodbox.ControlPlane.EksDrainIntentRepository
  ( eksDrainIntentAuthorityIdentity
  , encodeEksDrainIntentAuthorityIdentity
  )
import Prodbox.ControlPlane.EksDrainReadBackReceiptClient
import Prodbox.ControlPlane.EksDrainReadBackReceiptEndpoint
import Prodbox.ControlPlane.EksDrainReadBackReceiptRepository
import Prodbox.ControlPlane.EksDrainReadBackReceiptTransportClient
  ( lifecycleAuthorityEksDrainReadBackReceiptAuthenticatedClient
  )
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (..)
  )
import Prodbox.ControlPlane.RequestAuthentication
  ( RequestNonce
  , RequestSigner
  , localRequestSigningCapability
  , mkRequestNonce
  , mkRequestSigner
  , mkSigningKeyGeneration
  )
import Prodbox.Http.ReplyStatus
  ( ReplyStatus (..)
  , replyStatusCode
  )
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkLongLivedCheckpointAuthority
  , mkModelBObjectVersion
  , modelBObjectLogicalName
  )
import Prodbox.Lifecycle.CleanupRun
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeFromMicros
  )
import Prodbox.Lifecycle.Teardown.AwsEksAdapter
import Prodbox.Lifecycle.Teardown.EksDrainIntent
import Prodbox.Lifecycle.Teardown.EksDrainSession
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation (AbsenceEvidence (..))
import Prodbox.Lifecycle.Teardown.Registry (lifecycleRegistryRevision)
import TestSupport

controlPlaneEksDrainReadBackReceiptRepositorySuite :: SuiteBuilder ()
controlPlaneEksDrainReadBackReceiptRepositorySuite =
  describe "Sprint 7.36 Authority EKS drain read-back receipt" $ do
    it "binds the stable identity, actual attempt, and canonical safe evidence" $ do
      let request = fixtureRequest
          identity = eksDrainReadBackReceiptCommitRequestIdentity request
          bytes = eksDrainReadBackReceiptCommitRequestBytes request
      eksDrainReadBackReceiptIdentityRunId identity `shouldBe` fixtureRunId
      eksDrainReadBackReceiptIdentityGraphDigest identity `shouldBe` fixtureGraphDigest
      eksDrainReadBackReceiptIdentityScope identity `shouldBe` fixtureScope
      eksDrainReadBackReceiptIdentityResourceKey identity `shouldBe` AwsEksKey
      eksDrainReadBackReceiptIdentityCoordinateDigest identity
        `shouldBe` eksDrainIntentCoordinateDigest fixtureIntent
      eksDrainReadBackReceiptIdentityCommitOperationId identity
        `shouldBe` commitOperation
      eksDrainReadBackReceiptIdentityIntentReadBackOperationId identity
        `shouldBe` intentReadBackOperation
      eksDrainReadBackReceiptIdentityEffectOperationId identity
        `shouldBe` effectOperation
      eksDrainReadBackReceiptIdentityDrainReadBackOperationId identity
        `shouldBe` drainReadBackOperation
      eksDrainReadBackReceiptCommitRequestAttemptId request `shouldBe` attemptA
      Text.length
        ( eksDrainReadBackEvidenceDigestText
            (eksDrainReadBackReceiptCommitRequestEvidenceDigest request)
        )
        `shouldBe` 64
      Text.length
        ( eksDrainReadBackReceiptDigestText
            (eksDrainReadBackReceiptCommitRequestReceiptDigest request)
        )
        `shouldBe` 64
      ByteString.length bytes
        `shouldSatisfy` (<= eksDrainReadBackReceiptMaximumBytes)
      encodeModelBValue eksDrainReadBackReceiptModelBCodec bytes `shouldBe` Right bytes
      decodeModelBValue eksDrainReadBackReceiptModelBCodec bytes `shouldBe` Right bytes
      forM_
        [ fixtureEndpoint
        , fixtureCertificateAuthority
        , fixtureBearer
        , "KUBECONFIG"
        , "apiVersion: v1"
        ]
        ( \forbidden ->
            bytes
              `shouldSatisfy` (not . ByteString.isInfixOf (TextEncoding.encodeUtf8 forbidden))
        )

    it "creates, independently reads, and exactly replays one durable receipt" $ do
      fake <- newFakeRepository CommitNormally Nothing
      first <- commitFixture (fakeReceiptRepository fake) fixtureAttempt fixtureObservation
      first `shouldSatisfy` isReceiptFor attemptA
      second <- commitFixture (fakeReceiptRepository fake) fixtureAttempt fixtureObservation
      second `shouldSatisfy` isReceiptFor attemptA
      recovered <-
        readBackCommittedEksDrainTargetsAbsentReceipt
          (fakeReceiptRepository fake)
          fixtureCommitted
      recovered `shouldSatisfy` isReceiptFor attemptA
      readIORef (fakeReceiptWrites fake) `shouldReturn` 2
      readIORef (fakeReceiptReads fake) `shouldReturn` 3
      stored <- readIORef (fakeReceiptValues fake)
      Map.lookup fixtureSubmissionKey stored
        `shouldBe` Just (eksDrainReadBackReceiptCommitRequestBytes fixtureRequest)

    it "keeps a different actual attempt in the same stable slot as a conflict" $ do
      fake <- newFakeRepository CommitNormally Nothing
      created <- commitFixture (fakeReceiptRepository fake) fixtureAttempt fixtureObservation
      created `shouldSatisfy` isReceiptFor attemptA
      let alternateAttempt = attemptEvidenceFor attemptB
          alternateObservation = readBackObservationFor alternateAttempt fixtureUid
      conflicting <-
        commitFixture
          (fakeReceiptRepository fake)
          alternateAttempt
          alternateObservation
      conflicting
        `shouldBe` Left
          ( EksDrainReadBackReceiptCommitNotConfirmed
              EksDrainReadBackReceiptCommitConflict
          )
      stored <- readIORef (fakeReceiptValues fake)
      Map.lookup fixtureSubmissionKey stored
        `shouldBe` Just (eksDrainReadBackReceiptCommitRequestBytes fixtureRequest)

    it "recovers an applied write after response loss" $ do
      fake <- newFakeRepository CommitAppliesThenLosesResponse Nothing
      recovered <- commitFixture (fakeReceiptRepository fake) fixtureAttempt fixtureObservation
      recovered `shouldSatisfy` isReceiptFor attemptA
      readIORef (fakeReceiptWrites fake) `shouldReturn` 1
      readIORef (fakeReceiptReads fake) `shouldReturn` 1

    it "survives Runtime restart through the retained Model-B object" $ do
      durable <- newDurableModelB True
      let firstRepository =
            modelBEksDrainReadBackReceiptRepository
              fixtureAuthority
              (durableModelBAdapter durable)
      created <- commitFixture firstRepository fixtureAttempt fixtureObservation
      created `shouldSatisfy` isReceiptFor attemptA

      let restartedRepository =
            modelBEksDrainReadBackReceiptRepository
              fixtureAuthority
              (durableModelBAdapter durable)
      recovered <-
        readBackCommittedEksDrainTargetsAbsentReceipt
          restartedRepository
          fixtureCommitted
      recovered `shouldSatisfy` isReceiptFor attemptA
      replayed <- commitFixture restartedRepository fixtureAttempt fixtureObservation
      replayed `shouldSatisfy` isReceiptFor attemptA
      readIORef (durableModelBWrites durable) `shouldReturn` 1

    it "recovers from the retained intent identity without an attempt side map" $ do
      durable <- newDurableModelB False
      let repository =
            modelBEksDrainReadBackReceiptRepository
              fixtureAuthority
              (durableModelBAdapter durable)
          client =
            lifecycleAuthorityEksDrainReadBackReceiptClient
              fixtureIntentClient
              repository
      created <-
        commitAndReadBackEksDrainReceipt
          client
          fixtureCommitted
          fixtureAttempt
          fixtureObservation
      created `shouldSatisfy` isClientReceiptFor attemptA
      recovered <-
        recoverEksDrainReceiptFromIntentIdentity
          client
          (eksDrainIntentAuthorityIdentity fixtureIntent)
      recovered `shouldSatisfy` isClientReceiptFor attemptA

    it "keeps identity-only missing typed across local and authenticated clients" $ do
      missingRepository <-
        newFakeRepository
          CommitCancelled
          (Just EksDrainReadBackReceiptMissing)
      let localClient =
            lifecycleAuthorityEksDrainReadBackReceiptClient
              fixtureIntentClient
              (fakeReceiptRepository missingRepository)
          identity = eksDrainIntentAuthorityIdentity fixtureIntent
      recoverEksDrainReceiptFromIntentIdentity localClient identity
        `shouldReturn` Left EksDrainReadBackReceiptClientRecoveryMissing

      missingTransportClient <-
        authenticatedReceiptClientFor
          ( EksDrainReadBackReceiptWireRefused
              eksDrainReadBackReceiptEndpointFormatVersion
              EksDrainReadBackReceiptWireReceiptMissing
          )
      recoverEksDrainReceiptFromIntentIdentity missingTransportClient identity
        `shouldReturn` Left EksDrainReadBackReceiptClientRecoveryMissing

      unavailableTransportClient <-
        authenticatedReceiptClientFor
          ( EksDrainReadBackReceiptWireEndpointUnavailable
              eksDrainReadBackReceiptEndpointFormatVersion
              EksDrainReadBackReceiptWireReadBackUnavailable
          )
      unavailable <-
        recoverEksDrainReceiptFromIntentIdentity
          unavailableTransportClient
          identity
      unavailable `shouldSatisfy` isRemoteUnavailable

    it "serves commit and restart recovery only after Authority read-back" $ do
      durable <- newDurableModelB False
      let authorityClient =
            lifecycleAuthorityEksDrainReadBackReceiptClient
              fixtureIntentClient
              ( modelBEksDrainReadBackReceiptRepository
                  fixtureAuthority
                  (durableModelBAdapter durable)
              )
      committedResult <-
        serveEksDrainReadBackReceiptEndpointRequest
          authorityClient
          ( encodeControlPlaneRequest
              ( mustRight
                  ( eksDrainReadBackReceiptCommitWireRequest
                      fixtureCommitted
                      fixtureAttempt
                      fixtureObservation
                  )
              )
          )
      eksDrainReadBackReceiptEndpointStatus committedResult `shouldBe` ReplyOk
      committedResponse <-
        mustRightIO
          ( decodeEksDrainReadBackReceiptEndpointResponse
              (eksDrainReadBackReceiptEndpointBody committedResult)
          )
      confirmEksDrainReadBackReceiptEndpointResponse
        EksDrainReadBackReceiptCommitConfirmed
        fixtureCommitted
        committedResponse
        `shouldSatisfy` isEndpointReceiptFor attemptA

      let restartedClient =
            lifecycleAuthorityEksDrainReadBackReceiptClient
              fixtureIntentClient
              ( modelBEksDrainReadBackReceiptRepository
                  fixtureAuthority
                  (durableModelBAdapter durable)
              )
          identity = eksDrainIntentAuthorityIdentity fixtureIntent
      recoveredResult <-
        serveEksDrainReadBackReceiptEndpointRequest
          restartedClient
          ( encodeControlPlaneRequest
              (eksDrainReadBackReceiptRecoveryWireRequest identity)
          )
      eksDrainReadBackReceiptEndpointStatus recoveredResult `shouldBe` ReplyOk
      recoveredResponse <-
        mustRightIO
          ( decodeEksDrainReadBackReceiptEndpointResponse
              (eksDrainReadBackReceiptEndpointBody recoveredResult)
          )
      confirmEksDrainReadBackReceiptRecoveryResponse identity recoveredResponse
        `shouldSatisfy` isEndpointReceiptFor attemptA
      readIORef (durableModelBWrites durable) `shouldReturn` 1

    it "rejects malformed, unbounded, wrong-version, and invalid-shape wire input before storage" $ do
      durable <- newDurableModelB False
      let client =
            lifecycleAuthorityEksDrainReadBackReceiptClient
              fixtureIntentClient
              ( modelBEksDrainReadBackReceiptRepository
                  fixtureAuthority
                  (durableModelBAdapter durable)
              )
          identityBytes =
            encodeEksDrainIntentAuthorityIdentity
              (eksDrainIntentAuthorityIdentity fixtureIntent)
          wire action payload =
            EksDrainReadBackReceiptWireRequest
              { eksDrainReadBackReceiptWireRequestVersion =
                  eksDrainReadBackReceiptEndpointFormatVersion
              , eksDrainReadBackReceiptWireRequestAction = action
              , eksDrainReadBackReceiptWireRequestIntentIdentityBytes = identityBytes
              , eksDrainReadBackReceiptWireRequestCanonicalReceiptBytes = payload
              }
          cases =
            [
              ( LazyByteString.replicate
                  (fromIntegral eksDrainReadBackReceiptEndpointMaximumBytes + 1)
                  0
              , EksDrainReadBackReceiptWireRequestTooLarge
              )
            , ("not-cbor", EksDrainReadBackReceiptWireRequestInvalid)
            ,
              ( encodeControlPlaneRequest
                  ( (wire EksDrainReadBackReceiptWireRecover ByteString.empty)
                      { eksDrainReadBackReceiptWireRequestVersion =
                          eksDrainReadBackReceiptEndpointFormatVersion - 1
                      }
                  )
              , EksDrainReadBackReceiptWireRequestUnsupportedVersion
              )
            ,
              ( encodeControlPlaneRequest
                  ( (wire EksDrainReadBackReceiptWireRecover ByteString.empty)
                      { eksDrainReadBackReceiptWireRequestIntentIdentityBytes =
                          "not-an-identity"
                      }
                  )
              , EksDrainReadBackReceiptWireIdentityInvalid
              )
            ,
              ( encodeControlPlaneRequest
                  (wire EksDrainReadBackReceiptWireCommit ByteString.empty)
              , EksDrainReadBackReceiptWireCommitPayloadMissing
              )
            ,
              ( encodeControlPlaneRequest
                  (wire EksDrainReadBackReceiptWireReadBack "unexpected")
              , EksDrainReadBackReceiptWireUnexpectedPayload
              )
            ,
              ( encodeControlPlaneRequest
                  (wire EksDrainReadBackReceiptWireCommit "not-a-receipt")
              , EksDrainReadBackReceiptWireReceiptInvalid
              )
            ]
      forM_ cases $ \(request, expectedRefusal) -> do
        result <- serveEksDrainReadBackReceiptEndpointRequest client request
        eksDrainReadBackReceiptEndpointStatus result `shouldBe` ReplyBadRequest
        decodeEksDrainReadBackReceiptEndpointResponse
          (eksDrainReadBackReceiptEndpointBody result)
          `shouldBe` Right
            ( EksDrainReadBackReceiptWireRefused
                eksDrainReadBackReceiptEndpointFormatVersion
                expectedRefusal
            )
      readIORef (durableModelBWrites durable) `shouldReturn` 0

    it "refuses to remint proof when an authenticated response digest is tampered" $ do
      fake <- newFakeRepository CommitNormally Nothing
      let client =
            lifecycleAuthorityEksDrainReadBackReceiptClient
              fixtureIntentClient
              (fakeReceiptRepository fake)
      result <-
        serveEksDrainReadBackReceiptEndpointRequest
          client
          ( encodeControlPlaneRequest
              ( mustRight
                  ( eksDrainReadBackReceiptCommitWireRequest
                      fixtureCommitted
                      fixtureAttempt
                      fixtureObservation
                  )
              )
          )
      response <-
        mustRightIO
          ( decodeEksDrainReadBackReceiptEndpointResponse
              (eksDrainReadBackReceiptEndpointBody result)
          )
      let tampered = case response of
            EksDrainReadBackReceiptWireConfirmed version kind intent receipt _ evidenceDigest ->
              EksDrainReadBackReceiptWireConfirmed
                version
                kind
                intent
                receipt
                (Text.replicate 64 "f")
                evidenceDigest
            other -> other
      confirmEksDrainReadBackReceiptEndpointResponse
        EksDrainReadBackReceiptCommitConfirmed
        fixtureCommitted
        tampered
        `shouldSatisfy` isEndpointDigestMismatch

    it "rejects wrong run, graph, scope, and every drain operation" $ do
      let bytes = eksDrainReadBackReceiptCommitRequestBytes fixtureRequest
          identityMismatches =
            [
              ( "run"
              , replaceSameLength
                  (cleanupRunIdText fixtureRunId)
                  (cleanupRunIdText otherRunId)
                  bytes
              , isRunMismatch
              )
            ,
              ( "graph"
              , replaceSameLength
                  (cleanupDigestText fixtureGraphDigest)
                  (cleanupDigestText otherGraphDigest)
                  bytes
              , isGraphMismatch
              )
            ,
              ( "scope"
              , replaceSameLength fixtureFoundation otherFoundation bytes
              , isScopeMismatch
              )
            ]
              <> zipWith
                ( \(expected, alternate) predicate ->
                    ( "operation"
                    , replaceSameLength
                        (cleanupOperationIdText expected)
                        (cleanupOperationIdText alternate)
                        bytes
                    , predicate
                    )
                )
                (zip fixtureOperations otherOperations)
                operationMismatchPredicates
      forM_ identityMismatches $ \(label, wrongBytes, predicate) -> do
        result <- readForced wrongBytes fixtureCommitted
        result
          `shouldSatisfy` predicate
        case result of
          Left _ -> pure ()
          Right _ -> expectationFailure (Text.unpack label <> " unexpectedly reconstructed")

    it "rejects wrong key, coordinate, stale UID, and evidence-digest tampering" $ do
      let bytes = eksDrainReadBackReceiptCommitRequestBytes fixtureRequest
          wrongKey = replaceSameLength "aws-eks" "aws-bad" bytes
          coordinate =
            managedResourceCoordinateDigestText
              (eksDrainIntentCoordinateDigest fixtureIntent)
          wrongCoordinate = replaceSameLength coordinate (Text.replicate 64 "f") bytes
          staleUidBytes = replaceSameLength fixtureUid staleUid bytes
      readForced wrongKey fixtureCommitted `shouldReturnSatisfying` isKeyInvalid
      readForced wrongCoordinate fixtureCommitted `shouldReturnSatisfying` isCoordinateMismatch
      readForced staleUidBytes fixtureCommitted
        `shouldReturnSatisfying` isEvidenceDigestMismatch

      let staleObservation = readBackObservationFor fixtureAttempt staleUid
      case prepareEksDrainReadBackReceiptCommitRequest
        fixtureCommitted
        fixtureAttempt
        staleObservation of
        Left (EksDrainReadBackReceiptProofInvalid EksDrainReadBackIdentityMismatch) ->
          pure ()
        other -> expectationFailure ("stale UID produced unexpected result: " <> showResult other)

    it "locates by stable identity and validates the payload attempt afterward" $ do
      let alternateAttempt = attemptEvidenceFor attemptB
          alternateObservation = readBackObservationFor alternateAttempt fixtureUid
          alternateRequest =
            mustRight
              ( prepareEksDrainReadBackReceiptCommitRequest
                  fixtureCommitted
                  alternateAttempt
                  alternateObservation
              )
          alternateBytes = eksDrainReadBackReceiptCommitRequestBytes alternateRequest
      forced <- newFakeRepository CommitExactReplay (Just (EksDrainReadBackReceiptPresent alternateBytes))
      conflicting <-
        commitFixture (fakeReceiptRepository forced) fixtureAttempt fixtureObservation
      conflicting `shouldBe` Left EksDrainReadBackReceiptCommitReadBackConflict

      recovered <-
        readBackCommittedEksDrainTargetsAbsentReceipt
          (fakeReceiptRepository forced)
          fixtureCommitted
      recovered `shouldSatisfy` isReceiptFor attemptB
      eksDrainReadBackReceiptIdentitySubmissionKey
        (eksDrainReadBackReceiptCommitRequestIdentity fixtureRequest)
        `shouldBe` eksDrainReadBackReceiptIdentitySubmissionKey
          (eksDrainReadBackReceiptCommitRequestIdentity alternateRequest)

    it "supports the explicit already-absent no-Kubernetes-target arm" $ do
      fake <- newFakeRepository CommitNormally Nothing
      result <-
        commitAndReadBackEksDrainTargetsAbsentReceipt
          (fakeReceiptRepository fake)
          noTargetCommitted
          noTargetAttempt
          noTargetObservation
      result `shouldSatisfy` isReceiptFor attemptA
      case result of
        Right receipt ->
          eksDrainTargetsAbsentDisposition
            (committedEksDrainTargetsAbsentEvidence receipt)
            `shouldBe` NoKubernetesDrainTargetRequired
        Left err -> expectationFailure ("no-target receipt refused: " <> show err)

    it "cannot mint from present, unobservable, missing, or unbounded read-back" $ do
      let presentReadBack = case eksDrainTargetReadBackResult fixtureObservation of
            EksDrainObservedKubernetesTarget readBack ->
              fixtureObservation
                { eksDrainTargetReadBackResult =
                    EksDrainObservedKubernetesTarget
                      readBack
                        { eksDrainReadBackLoadBalancerServiceClass =
                            LoadBalancerServiceClassReadBack
                              ( EksDrainResourceClassPresent
                                  (mustNonEmpty [mustRight (mkEksNamespacedName "default" "lb")])
                              )
                        }
                }
            _ -> error "expected Kubernetes fixture"
          unobservable =
            fixtureObservation
              { eksDrainTargetReadBackResult =
                  EksDrainTargetReadBackUnobservable
                    (mustNonEmpty [ObservationFailure "read failed"])
              }
      prepareEksDrainReadBackReceiptCommitRequest fixtureCommitted fixtureAttempt presentReadBack
        `shouldSatisfy` isLeftProof
      prepareEksDrainReadBackReceiptCommitRequest fixtureCommitted fixtureAttempt unobservable
        `shouldSatisfy` isLeftProof

      let cases =
            [ (EksDrainReadBackReceiptMissing, isMissing)
            ,
              ( EksDrainReadBackReceiptUnobservable (ObservationFailure "Authority unavailable")
              , isUnobservable
              )
            , (EksDrainReadBackReceiptUnbounded 2 1, isTooLarge)
            ]
      forM_ cases $ \(observation, predicate) -> do
        fake <- newFakeRepository CommitCancelled (Just observation)
        result <-
          readBackCommittedEksDrainTargetsAbsentReceipt
            (fakeReceiptRepository fake)
            fixtureCommitted
        result `shouldSatisfy` predicate

    it "keeps receipt/proof constructors and credential-bearing types out of the boundary" $ do
      repositorySource <-
        readFile "src/Prodbox/ControlPlane/EksDrainReadBackReceiptRepository.hs"
      boundarySources <-
        traverse
          readFile
          [ "src/Prodbox/ControlPlane/EksDrainReadBackReceiptRepository.hs"
          , "src/Prodbox/ControlPlane/EksDrainReadBackReceiptClient.hs"
          , "src/Prodbox/ControlPlane/EksDrainReadBackReceiptEndpoint.hs"
          , "src/Prodbox/ControlPlane/EksDrainReadBackReceiptTransportClient.hs"
          ]
      let moduleHeader = takeWhile (/= "where") (lines repositorySource)
      unlines moduleHeader `shouldNotContain` "CommittedEksDrainReadBackReceipt (.."
      unlines moduleHeader `shouldNotContain` "EksDrainReadBackReceiptIdentity (.."
      unlines moduleHeader `shouldNotContain` "EksDrainReadBackReceiptCommitRequest (.."
      forM_ boundarySources $ \source ->
        forM_
          [ "EksClientAuthProjection"
          , "eksClientAuthBearerToken"
          , "withEksDrainClientProjection"
          , "internalEksDrainSessionProjection"
          ]
          (\forbidden -> source `shouldNotContain` forbidden)

commitFixture
  :: EksDrainReadBackReceiptRepository IO
  -> EksDrainAttemptEvidence
  -> EksDrainTargetReadBackObservation
  -> IO (Either EksDrainReadBackReceiptError CommittedEksDrainReadBackReceipt)
commitFixture repository =
  commitAndReadBackEksDrainTargetsAbsentReceipt repository fixtureCommitted

fixtureRequest :: EksDrainReadBackReceiptCommitRequest
fixtureRequest =
  mustRight
    ( prepareEksDrainReadBackReceiptCommitRequest
        fixtureCommitted
        fixtureAttempt
        fixtureObservation
    )

fixtureSubmissionKey :: EksDrainReadBackReceiptSubmissionKey
fixtureSubmissionKey =
  eksDrainReadBackReceiptIdentitySubmissionKey
    (eksDrainReadBackReceiptCommitRequestIdentity fixtureRequest)

fixtureIntentClient :: EksDrainIntentClient IO
fixtureIntentClient =
  EksDrainIntentClient
    { commitAndReadBackEksDrainIntent = \_ -> pure (Right fixtureCommitted)
    , readBackCommittedEksDrainIntent = \_ -> pure (Right fixtureCommitted)
    , recoverCommittedEksDrainIntent = \identity ->
        if identity == eksDrainIntentAuthorityIdentity fixtureIntent
          then pure (Right fixtureCommitted)
          else error "unexpected EKS drain intent recovery identity"
    }

fixtureAttempt :: EksDrainAttemptEvidence
fixtureAttempt = attemptEvidenceFor attemptA

attemptEvidenceFor :: CleanupAttemptId -> EksDrainAttemptEvidence
attemptEvidenceFor attemptId =
  mustRight
    ( recordEksDrainAttempt
        attempt
        (eksDrainAttemptObservationFor attempt EksDrainMutationApplied)
    )
 where
  attempt = beginEksDrainAttempt fixtureCommitted attemptId

fixtureObservation :: EksDrainTargetReadBackObservation
fixtureObservation = readBackObservationFor fixtureAttempt fixtureUid

readBackObservationFor
  :: EksDrainAttemptEvidence
  -> Text
  -> EksDrainTargetReadBackObservation
readBackObservationFor attempt uid =
  eksDrainTargetReadBackObservationFor
    attempt
    ( EksDrainObservedKubernetesTarget
        EksDrainKubernetesTargetReadBack
          { eksDrainReadBackProviderArn = fixtureArn
          , eksDrainReadBackKubernetesUid = uid
          , eksDrainReadBackEndpointDigest = eksDrainSessionEndpointDigest fixtureSession
          , eksDrainReadBackCertificateAuthorityDigest =
              eksDrainSessionCertificateAuthorityDigest fixtureSession
          , eksDrainReadBackLoadBalancerServiceClass =
              LoadBalancerServiceClassReadBack
                (EksDrainResourceClassAbsent (AbsenceEvidence "no LoadBalancer Services"))
          , eksDrainReadBackIngressClass =
              IngressClassReadBack
                (EksDrainResourceClassAbsent (AbsenceEvidence "no Ingresses"))
          , eksDrainReadBackControllerOwnerClass =
              ControllerOwnerClassReadBack
                (EksDrainResourceClassAbsent (AbsenceEvidence "controller owner absent"))
          , eksDrainReadBackDeletePolicyPvcs =
              [ EksDrainPvcReadBack
                  fixturePvc
                  (EksDrainPvcAbsent (AbsenceEvidence "PVC absent"))
              ]
          }
    )

fixtureCommitted :: CommittedEksDrainIntent
fixtureCommitted =
  mustRight
    ( confirmEksDrainIntentCommitted
        fixtureIntent
        (EksDrainIntentReadBackPresent (encodeEksDrainIntent fixtureIntent))
    )

fixtureIntent :: EksDrainIntent
fixtureIntent =
  mustRight
    ( prepareEksKubernetesDrainIntent
        fixtureBinding
        fixtureSession
        ( eksDrainTargetSelectionObservationFor
            fixtureSession
            (ObservationRevision 23)
            (EksDrainTargetSelectionComplete [fixturePvc])
        )
    )

fixtureBinding :: EksDrainOperationBinding
fixtureBinding =
  mustRight
    ( mkEksDrainOperationBinding
        fixtureScope
        fixtureRunId
        fixtureGraphDigest
        commitOperation
        intentReadBackOperation
        effectOperation
        drainReadBackOperation
    )

fixtureSession :: EksDrainSession
fixtureSession =
  mustRight
    ( mkEksDrainSession
        1_000
        1_500
        effectOperation
        fixtureScope
        fixtureVerifiedPresent
        fixtureKubernetesIdentity
        fixtureProjection
    )

fixtureVerifiedPresent :: VerifiedAwsEksObservation 'ObserveEksForDecision
fixtureVerifiedPresent = verifiedPresent fixtureScope fixtureArn

fixtureKubernetesIdentity :: EksKubernetesIdentityObservation
fixtureKubernetesIdentity =
  eksKubernetesIdentityObservationFor
    fixtureScope
    (ObservationRevision 22)
    fixtureArn
    (EksKubernetesIdentityPresent fixtureUid)
    fixtureProjection

fixtureProjection :: EksClientAuthProjection
fixtureProjection =
  mustRight
    ( testEksClientAuthProjection
        "123456789012"
        (fixtureAwsRegion FixtureUsEast1)
        "aws-eks-test-cluster"
        fixtureArn
        fixtureEndpoint
        fixtureCertificateAuthority
        fixtureBearer
        1_800
    )

noTargetCommitted :: CommittedEksDrainIntent
noTargetCommitted =
  mustRight
    ( confirmEksDrainIntentCommitted
        noTargetIntent
        (EksDrainIntentReadBackPresent (encodeEksDrainIntent noTargetIntent))
    )

noTargetIntent :: EksDrainIntent
noTargetIntent =
  mustRight
    (prepareEksNoKubernetesTargetIntent fixtureBinding (verifiedAbsent fixtureScope))

noTargetAttempt :: EksDrainAttemptEvidence
noTargetAttempt =
  mustRight
    ( recordEksDrainAttempt
        attempt
        (eksDrainAttemptObservationFor attempt EksDrainSkippedNoKubernetesTarget)
    )
 where
  attempt = beginEksDrainAttempt noTargetCommitted attemptA

noTargetObservation :: EksDrainTargetReadBackObservation
noTargetObservation =
  eksDrainTargetReadBackObservationFor
    noTargetAttempt
    EksDrainObservedNoKubernetesTarget

verifiedPresent
  :: ObservationEvidenceScope
  -> Text
  -> VerifiedAwsEksObservation 'ObserveEksForDecision
verifiedPresent scope arn =
  decodeVerified
    (mustRight (mkAwsEksDecisionObservationRequest (ObservationRevision 20) scope))
    ("eks-cluster-arn:" <> arn)

verifiedAbsent
  :: ObservationEvidenceScope
  -> VerifiedAwsEksObservation 'ObserveEksForDecision
verifiedAbsent scope =
  decodeVerified
    (mustRight (mkAwsEksDecisionObservationRequest (ObservationRevision 24) scope))
    "registered EKS cluster is absent"

decodeVerified
  :: ExactAwsEksObservationRequest purpose
  -> Text
  -> VerifiedAwsEksObservation purpose
decodeVerified request output =
  case decodeAwsEksObservation
    request
    ( Right
        ( ProviderIntentExecutionObserved
            (awsEksObservationRequestProviderCoordinate request)
            output
        )
    ) of
    AwsEksObservationDecoded verified -> verified
    AwsEksObservationRejected err _ ->
      error ("EKS fixture observation rejected: " <> show err)

readForced
  :: ByteString
  -> CommittedEksDrainIntent
  -> IO (Either EksDrainReadBackReceiptError CommittedEksDrainReadBackReceipt)
readForced bytes committed = do
  fake <-
    newFakeRepository
      CommitCancelled
      (Just (EksDrainReadBackReceiptPresent bytes))
  readBackCommittedEksDrainTargetsAbsentReceipt
    (fakeReceiptRepository fake)
    committed

data FakeCommitBehavior
  = CommitNormally
  | CommitAppliesThenLosesResponse
  | CommitExactReplay
  | CommitCancelled

data FakeReceiptRepository = FakeReceiptRepository
  { fakeReceiptRepository :: EksDrainReadBackReceiptRepository IO
  , fakeReceiptValues
      :: IORef (Map EksDrainReadBackReceiptSubmissionKey ByteString)
  , fakeReceiptWrites :: IORef Int
  , fakeReceiptReads :: IORef Int
  }

newFakeRepository
  :: FakeCommitBehavior
  -> Maybe EksDrainReadBackReceiptObservation
  -> IO FakeReceiptRepository
newFakeRepository behavior forcedReadBack = do
  valuesRef <- newIORef Map.empty
  writesRef <- newIORef 0
  readsRef <- newIORef 0
  let repository =
        EksDrainReadBackReceiptRepository
          { createOrReplayAuthorityEksDrainReadBackReceipt = \request -> do
              atomicModifyIORef' writesRef (\count -> (count + 1, ()))
              case behavior of
                CommitNormally -> storeRequest valuesRef request
                CommitAppliesThenLosesResponse -> do
                  _ <- storeRequest valuesRef request
                  pure
                    ( EksDrainReadBackReceiptCommitResponseLost
                        (ObservationFailure "commit response lost")
                    )
                CommitExactReplay -> pure EksDrainReadBackReceiptCommitExactReplay
                CommitCancelled -> pure EksDrainReadBackReceiptCommitCancelled
          , independentlyReadBackAuthorityEksDrainReadBackReceipt = \identity -> do
              atomicModifyIORef' readsRef (\count -> (count + 1, ()))
              case forcedReadBack of
                Just observation -> pure observation
                Nothing -> do
                  values <- readIORef valuesRef
                  pure $ case Map.lookup
                    (eksDrainReadBackReceiptIdentitySubmissionKey identity)
                    values of
                    Nothing -> EksDrainReadBackReceiptMissing
                    Just bytes -> EksDrainReadBackReceiptPresent bytes
          }
  pure
    FakeReceiptRepository
      { fakeReceiptRepository = repository
      , fakeReceiptValues = valuesRef
      , fakeReceiptWrites = writesRef
      , fakeReceiptReads = readsRef
      }

storeRequest
  :: IORef (Map EksDrainReadBackReceiptSubmissionKey ByteString)
  -> EksDrainReadBackReceiptCommitRequest
  -> IO EksDrainReadBackReceiptCommitResult
storeRequest valuesRef request =
  atomicModifyIORef' valuesRef $ \values ->
    let key =
          eksDrainReadBackReceiptIdentitySubmissionKey
            (eksDrainReadBackReceiptCommitRequestIdentity request)
        bytes = eksDrainReadBackReceiptCommitRequestBytes request
     in case Map.lookup key values of
          Nothing ->
            (Map.insert key bytes values, EksDrainReadBackReceiptCommitCreated)
          Just existing
            | existing == bytes ->
                (values, EksDrainReadBackReceiptCommitExactReplay)
            | otherwise -> (values, EksDrainReadBackReceiptCommitConflict)

data DurableModelB = DurableModelB
  { durableModelBAdapter :: ModelBCasAdapter 'ClusterRetained IO ByteString
  , durableModelBWrites :: IORef Int
  }

newDurableModelB :: Bool -> IO DurableModelB
newDurableModelB loseFirstResponse = do
  valuesRef <- newIORef Map.empty
  writesRef <- newIORef 0
  loseResponseRef <- newIORef loseFirstResponse
  let compareAndSwap request = case request of
        ModelBInitialize coordinate bytes -> do
          let logicalName = modelBObjectLogicalName coordinate
          existing <- readIORef valuesRef
          case Map.lookup logicalName existing of
            Just (version, current) ->
              pure (ModelBCasConflict (ModelBObserved version current))
            Nothing -> do
              modifyIORef'
                valuesRef
                (Map.insert logicalName (fixtureModelBVersion, bytes))
              atomicModifyIORef' writesRef (\count -> (count + 1, ()))
              lose <-
                atomicModifyIORef' loseResponseRef clearResponseLoss
              pure $
                if lose
                  then ModelBCasUnobservable "CAS response lost"
                  else ModelBCasApplied fixtureModelBVersion bytes
        ModelBReplace {} -> unexpected
        ModelBInitializeGuarded {} -> unexpected
        ModelBReplaceGuarded {} -> unexpected
      adapter =
        ModelBCasAdapter
          { modelBObserve = \coordinate -> do
              values <- readIORef valuesRef
              pure $ case Map.lookup (modelBObjectLogicalName coordinate) values of
                Nothing -> ModelBMissing
                Just (version, bytes) -> ModelBObserved version bytes
          , modelBCompareAndSwap = compareAndSwap
          }
      unexpected =
        pure (ModelBCasUnobservable "unexpected non-create CAS request")
      clearResponseLoss value = (False, value)
  pure
    DurableModelB
      { durableModelBAdapter = adapter
      , durableModelBWrites = writesRef
      }

isReceiptFor
  :: CleanupAttemptId
  -> Either EksDrainReadBackReceiptError CommittedEksDrainReadBackReceipt
  -> Bool
isReceiptFor expectedAttempt result = case result of
  Right receipt ->
    committedEksDrainReadBackReceiptAttemptId receipt == expectedAttempt
      && eksDrainTargetsAbsentEffectAttemptId
        (committedEksDrainTargetsAbsentEvidence receipt)
        == expectedAttempt
  Left _ -> False

isClientReceiptFor
  :: CleanupAttemptId
  -> Either
       EksDrainReadBackReceiptClientError
       CommittedEksDrainReadBackReceipt
  -> Bool
isClientReceiptFor expectedAttempt result = case result of
  Right receipt ->
    committedEksDrainReadBackReceiptAttemptId receipt == expectedAttempt
  Left _ -> False

isRemoteUnavailable
  :: Either
       EksDrainReadBackReceiptClientError
       CommittedEksDrainReadBackReceipt
  -> Bool
isRemoteUnavailable result = case result of
  Left EksDrainReadBackReceiptClientRemoteUnavailable {} -> True
  _ -> False

isEndpointReceiptFor
  :: CleanupAttemptId
  -> Either
       EksDrainReadBackReceiptEndpointResponseError
       CommittedEksDrainReadBackReceipt
  -> Bool
isEndpointReceiptFor expectedAttempt result = case result of
  Right receipt ->
    committedEksDrainReadBackReceiptAttemptId receipt == expectedAttempt
  Left _ -> False

isEndpointDigestMismatch
  :: Either
       EksDrainReadBackReceiptEndpointResponseError
       CommittedEksDrainReadBackReceipt
  -> Bool
isEndpointDigestMismatch result = case result of
  Left EksDrainReadBackReceiptEndpointResponseReceiptDigestMismatch {} -> True
  _ -> False

isRunMismatch
  , isGraphMismatch
  , isScopeMismatch
  , isKeyInvalid
  , isCoordinateMismatch
  , isEvidenceDigestMismatch
  , isMissing
  , isUnobservable
  , isTooLarge
  , isLeftProof
    :: Either EksDrainReadBackReceiptError value -> Bool
isRunMismatch result = case result of
  Left EksDrainReadBackReceiptRunMismatch {} -> True
  _ -> False
isGraphMismatch result = case result of
  Left EksDrainReadBackReceiptGraphMismatch {} -> True
  _ -> False
isScopeMismatch result = case result of
  Left EksDrainReadBackReceiptScopeMismatch {} -> True
  _ -> False
isKeyInvalid result = case result of
  Left EksDrainReadBackReceiptCodecResourceKeyInvalid {} -> True
  _ -> False
isCoordinateMismatch result = case result of
  Left EksDrainReadBackReceiptCoordinateMismatch {} -> True
  _ -> False
isEvidenceDigestMismatch result = case result of
  Left EksDrainReadBackReceiptEvidenceDigestMismatch {} -> True
  _ -> False
isMissing result = case result of
  Left EksDrainReadBackReceiptReadBackMissing -> True
  _ -> False
isUnobservable result = case result of
  Left EksDrainReadBackReceiptReadBackUnobservable {} -> True
  _ -> False
isTooLarge result = case result of
  Left EksDrainReadBackReceiptCodecTooLarge {} -> True
  _ -> False
isLeftProof result = case result of
  Left (EksDrainReadBackReceiptProofInvalid _) -> True
  Left EksDrainReadBackReceiptPositiveShapeInvalid -> True
  _ -> False

operationMismatchPredicates
  :: [Either EksDrainReadBackReceiptError value -> Bool]
operationMismatchPredicates =
  [ isCommitOperationMismatch
  , isIntentReadBackOperationMismatch
  , isEffectOperationMismatch
  , isDrainReadBackOperationMismatch
  ]

isCommitOperationMismatch :: Either EksDrainReadBackReceiptError value -> Bool
isCommitOperationMismatch result = case result of
  Left EksDrainReadBackReceiptCommitOperationMismatch {} -> True
  _ -> False

isIntentReadBackOperationMismatch
  :: Either EksDrainReadBackReceiptError value -> Bool
isIntentReadBackOperationMismatch result = case result of
  Left EksDrainReadBackReceiptIntentReadBackOperationMismatch {} -> True
  _ -> False

isEffectOperationMismatch :: Either EksDrainReadBackReceiptError value -> Bool
isEffectOperationMismatch result = case result of
  Left EksDrainReadBackReceiptEffectOperationMismatch {} -> True
  _ -> False

isDrainReadBackOperationMismatch
  :: Either EksDrainReadBackReceiptError value -> Bool
isDrainReadBackOperationMismatch result = case result of
  Left EksDrainReadBackReceiptDrainReadBackOperationMismatch {} -> True
  _ -> False

shouldReturnSatisfying :: IO value -> (value -> Bool) -> IO ()
shouldReturnSatisfying action predicate = action >>= (`shouldSatisfy` predicate)

replaceSameLength :: Text -> Text -> ByteString -> ByteString
replaceSameLength old new bytes
  | Text.length old /= Text.length new = error "replacement fixture length differs"
  | ByteString.null suffix = error ("receipt bytes did not contain " <> Text.unpack old)
  | otherwise =
      prefix
        <> TextEncoding.encodeUtf8 new
        <> ByteString.drop (ByteString.length oldBytes) suffix
 where
  oldBytes = TextEncoding.encodeUtf8 old
  (prefix, suffix) = ByteString.breakSubstring oldBytes bytes

mustNonEmpty :: [value] -> NonEmpty.NonEmpty value
mustNonEmpty values = case NonEmpty.nonEmpty values of
  Nothing -> error "expected non-empty fixture"
  Just nonEmptyValues -> nonEmptyValues

fixtureRunId, otherRunId :: CleanupRunId
fixtureRunId = mustRight (mkCleanupRunId "cleanup-run/eks-receipt-a")
otherRunId = mustRight (mkCleanupRunId "cleanup-run/eks-receipt-b")

fixtureGraphDigest, otherGraphDigest :: CleanupDigest
fixtureGraphDigest = mustRight (mkCleanupDigest (Text.replicate 64 "a"))
otherGraphDigest = mustRight (mkCleanupDigest (Text.replicate 64 "b"))

commitOperation
  , intentReadBackOperation
  , effectOperation
  , drainReadBackOperation
  , otherCommitOperation
  , otherIntentReadBackOperation
  , otherEffectOperation
  , otherDrainReadBackOperation
    :: CleanupOperationId
commitOperation = mustRight (mkCleanupOperationId "operation/eks-intent-commit-a")
intentReadBackOperation = mustRight (mkCleanupOperationId "operation/eks-intent-readback-a")
effectOperation = mustRight (mkCleanupOperationId "operation/eks-drain-effect-a")
drainReadBackOperation = mustRight (mkCleanupOperationId "operation/eks-drain-readback-a")
otherCommitOperation = mustRight (mkCleanupOperationId "operation/eks-intent-commit-b")
otherIntentReadBackOperation = mustRight (mkCleanupOperationId "operation/eks-intent-readback-b")
otherEffectOperation = mustRight (mkCleanupOperationId "operation/eks-drain-effect-b")
otherDrainReadBackOperation = mustRight (mkCleanupOperationId "operation/eks-drain-readback-b")

fixtureOperations, otherOperations :: [CleanupOperationId]
fixtureOperations =
  [ commitOperation
  , intentReadBackOperation
  , effectOperation
  , drainReadBackOperation
  ]
otherOperations =
  [ otherCommitOperation
  , otherIntentReadBackOperation
  , otherEffectOperation
  , otherDrainReadBackOperation
  ]

attemptA, attemptB :: CleanupAttemptId
attemptA = mustRight (mkCleanupAttemptId "attempt/eks-drain-a")
attemptB = mustRight (mkCleanupAttemptId "attempt/eks-drain-b")

fixtureScope :: ObservationEvidenceScope
fixtureScope =
  mkObservationEvidenceScope
    Cascade
    lifecycleRegistryRevision
    (DurableObservationRunScope (cleanupRunIdText fixtureRunId))
    (LinuxRke2FoundationId fixtureFoundation)
    (Just (AwsScope (AwsAccountId "123456789012") (AwsRegion (fixtureAwsRegion FixtureUsEast1))))
    ReconcileDesiredAbsent

fixtureFoundation, otherFoundation :: Text
fixtureFoundation = "home-linux-rke2"
otherFoundation = "fake-linux-rke2"

fixtureArn, fixtureUid, staleUid :: Text
fixtureArn =
  ("arn:aws:eks:" <> (fixtureAwsRegion FixtureUsEast1) <> ":123456789012:cluster/aws-eks-test-cluster")
fixtureUid = "eks-kube-system-uid-original"
staleUid = "eks-kube-system-uid-recreate"

fixtureEndpoint, fixtureCertificateAuthority, fixtureBearer :: Text
fixtureEndpoint = "https://sensitive.eks.amazonaws.com"
fixtureCertificateAuthority = "sensitive-ca-plaintext"
fixtureBearer = "sensitive-bearer-plaintext"

fixturePvc :: EksNamespacedName
fixturePvc = mustRight (mkEksNamespacedName "database" "postgres-data")

fixtureAuthority :: LongLivedCheckpointAuthority
fixtureAuthority =
  mustRight
    ( mkLongLivedCheckpointAuthority
        fixtureFoundation
        "prodbox-authority"
        "authority"
        "secret/lifecycle"
    )

authenticatedReceiptClientFor
  :: EksDrainReadBackReceiptWireResponse
  -> IO (EksDrainReadBackReceiptClient IO)
authenticatedReceiptClientFor response = do
  endpoint <-
    mustRightIO
      (mkLifecycleAuthorityEndpoint "http://lifecycle-authority:8600")
  rawClient <-
    mustRightIO
      ( controlPlaneClientWithTransport
          eksDrainReadBackReceiptEndpointResponseMaximumBytes
          endpoint
          ( \method _ url _ -> do
              method `shouldBe` "POST"
              url
                `shouldBe` "http://lifecycle-authority:8600/v1/authority/eks-drain-readback-receipt"
              pure
                ( Right
                    ( replyStatusCode
                        (eksDrainReadBackReceiptWireResponseStatus response)
                    , LazyByteString.toStrict
                        (encodeControlPlaneResponse response)
                    )
                )
          )
      )
  pure
    ( lifecycleAuthorityEksDrainReadBackReceiptAuthenticatedClient
        ( mkAuthenticatedClientTransport
            receiptTransportBounds
            receiptClientProviders
            rawClient
        )
    )

receiptTransportBounds :: AuthenticatedTransportBounds
receiptTransportBounds =
  mustRight (mkAuthenticatedTransportBounds (512 * 1024) 256 (500 * 1024))

receiptClientProviders :: AuthenticatedClientProviders IO
receiptClientProviders =
  AuthenticatedClientProviders
    { provideAuthenticatedClientSigner =
        pure
          (Right (localRequestSigningCapability receiptRequestSigner))
    , provideAuthenticatedClientScope = pure (Right receiptAuthorityScope)
    , provideAuthenticatedClientEpoch = pure (Right authorityEpochGenesis)
    , provideAuthenticatedClientDeadline = pure (Right receiptDeadline)
    , provideAuthenticatedClientNonce = pure (Right receiptRequestNonce)
    }

receiptRequestSigner :: RequestSigner
receiptRequestSigner =
  mustRight
    ( mkRequestSigner
        CallerOperatorCli
        (mustRight (mkSigningKeyGeneration 1))
        (ByteString.pack [0 .. 31])
    )

receiptRequestNonce :: RequestNonce
receiptRequestNonce = mustRight (mkRequestNonce (ByteString.pack [32 .. 47]))

receiptAuthorityScope :: AuthorityScope
receiptAuthorityScope = mustRight (mkAuthorityScope "cluster-a")

receiptDeadline :: AuthorityTime
receiptDeadline = authorityTimeFromMicros 2_000

fixtureModelBVersion :: ModelBObjectVersion
fixtureModelBVersion = mustRight (mkModelBObjectVersion "eks-drain-receipt-version-1")

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error ("invalid EKS drain read-back receipt fixture: " <> show err)
  Right value -> value

mustRightIO :: (Show err) => Either err value -> IO value
mustRightIO = pure . mustRight

showResult :: Either EksDrainReadBackReceiptError value -> String
showResult result = case result of
  Left err -> "Left " <> show err
  Right _ -> "Right <request>"
