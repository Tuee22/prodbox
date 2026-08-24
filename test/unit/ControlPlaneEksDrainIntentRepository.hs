{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneEksDrainIntentRepository
  ( controlPlaneEksDrainIntentRepositorySuite
  )
where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (isLeft)
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , newIORef
  , readIORef
  )
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word16, Word64)
import EksClientAuthProjectionFixture (testEksClientAuthProjection)
import Prodbox.ControlPlane.Codec (encodeControlPlaneRequest)
import Prodbox.ControlPlane.EksClientAuthProjection
  ( EksClientAuthProjection
  )
import Prodbox.ControlPlane.EksDrainIntentClient
import Prodbox.ControlPlane.EksDrainIntentEndpoint
import Prodbox.ControlPlane.EksDrainIntentRepository
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionResult (..)
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
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
import Prodbox.Lifecycle.Teardown.AwsEksAdapter
import Prodbox.Lifecycle.Teardown.EksDrainIntent
import Prodbox.Lifecycle.Teardown.EksDrainSession
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Registry
import TestSupport

controlPlaneEksDrainIntentRepositorySuite :: SuiteBuilder ()
controlPlaneEksDrainIntentRepositorySuite =
  describe "Sprint 7.36 Authority EKS drain-intent repository" $ do
    it "projects one stable slot over the exact run, graph, scope, key, coordinate, and four operations" $ do
      let identity = eksDrainIntentAuthorityIdentity fixtureIntent
          alternateIdentity = eksDrainIntentAuthorityIdentity alternateTargetIntent
      eksDrainIntentAuthorityRunId identity `shouldBe` fixtureRunId
      eksDrainIntentAuthorityGraphDigest identity `shouldBe` fixtureGraphDigest
      eksDrainIntentAuthorityScope identity `shouldBe` fixtureScope
      eksDrainIntentAuthorityResourceKey identity `shouldBe` AwsEksKey
      eksDrainIntentAuthorityCoordinateDigest identity
        `shouldBe` eksDrainIntentCoordinateDigest fixtureIntent
      eksDrainIntentAuthorityCommitOperationId identity `shouldBe` commitOperation
      eksDrainIntentAuthorityReadBackOperationId identity `shouldBe` intentReadBackOperation
      eksDrainIntentAuthorityEffectOperationId identity `shouldBe` effectOperation
      eksDrainIntentAuthorityDrainReadBackOperationId identity
        `shouldBe` drainReadBackOperation
      eksDrainIntentAuthoritySubmissionKey alternateIdentity
        `shouldBe` eksDrainIntentAuthoritySubmissionKey identity
      let rendered =
            eksDrainIntentSubmissionKeyText
              (eksDrainIntentAuthoritySubmissionKey identity)
      rendered `shouldSatisfy` Text.isPrefixOf "eks-drain-intent-v1-"
      Text.length rendered `shouldBe` 84

    it "round-trips only a canonical identity reconstructed from the validated four-operation binding" $ do
      let identity =
            eksDrainIntentAuthorityRecoveryIdentity
              (bindingFor fixtureRunId fixtureGraphDigest fixtureScope fixtureOperations)
          bytes = encodeEksDrainIntentAuthorityIdentity identity
      identity `shouldBe` eksDrainIntentAuthorityIdentity fixtureIntent
      ByteString.length bytes
        `shouldSatisfy` (<= maximumEksDrainIntentAuthorityIdentityBytes)
      decodeEksDrainIntentAuthorityIdentity bytes `shouldBe` Right identity
      forM_
        [ fixtureBearer
        , fixtureEndpoint
        , fixtureCertificateAuthority
        , "kube-system"
        ]
        ( \forbidden ->
            bytes
              `shouldSatisfy` (not . ByteString.isInfixOf (TextEncoding.encodeUtf8 forbidden))
        )
      decodeEksDrainIntentAuthorityIdentity (rewriteRegisteredKey bytes)
        `shouldBe` Left
          (EksDrainIntentAuthorityIdentityResourceKeyMismatch "aws-test")
      let coordinate =
            managedResourceCoordinateDigestText
              (eksDrainIntentAuthorityCoordinateDigest identity)
          wrongCoordinate = Text.replicate (Text.length coordinate) "f"
      decodeEksDrainIntentAuthorityIdentity
        (rewriteSameLengthText coordinate wrongCoordinate bytes)
        `shouldBe` Left
          ( EksDrainIntentAuthorityIdentityCoordinateMismatch
              coordinate
              wrongCoordinate
          )
      let submission =
            eksDrainIntentSubmissionKeyText
              (eksDrainIntentAuthoritySubmissionKey identity)
          wrongSubmission = Text.replicate (Text.length submission) "x"
      decodeEksDrainIntentAuthorityIdentity
        (rewriteSameLengthText submission wrongSubmission bytes)
        `shouldBe` Left
          ( EksDrainIntentAuthorityIdentitySubmissionKeyMismatch
              submission
              wrongSubmission
          )
      decodeEksDrainIntentAuthorityIdentity ByteString.empty
        `shouldBe` Left EksDrainIntentAuthorityIdentityEmpty

    it "prepares only the bounded canonical secret-free intent bytes" $ do
      request <- mustRightIO (prepareEksDrainIntentCommitRequest fixturePresentIntent)
      let bytes = eksDrainIntentCommitRequestBytes request
      bytes `shouldBe` encodeEksDrainIntent fixturePresentIntent
      eksDrainIntentCommitRequestDigest request
        `shouldBe` eksDrainIntentDigest fixturePresentIntent
      ByteString.length bytes `shouldSatisfy` (<= maximumEksDrainIntentBytes)
      decodeEksDrainIntent bytes `shouldBe` Right fixturePresentIntent
      encodeModelBValue eksDrainIntentModelBCodec bytes `shouldBe` Right bytes
      decodeModelBValue eksDrainIntentModelBCodec bytes `shouldBe` Right bytes
      decodeModelBValue eksDrainIntentModelBCodec (rewriteRegisteredKey bytes)
        `shouldSatisfy` isLeft
      forM_
        [ fixtureBearer
        , fixtureEndpoint
        , fixtureCertificateAuthority
        , "KUBECONFIG"
        , "apiVersion: v1"
        ]
        ( \forbidden ->
            bytes
              `shouldSatisfy` ( \candidate ->
                                  not
                                    ( ByteString.isInfixOf
                                        (TextEncoding.encodeUtf8 forbidden)
                                        candidate
                                    )
                              )
        )

    it "creates, independently reads back, and exactly replays one durable intent" $ do
      fake <- newFakeRepository CommitNormally Nothing
      let client = lifecycleAuthorityEksDrainIntentClient (fakeRepository fake)
      first <- commitAndReadBackEksDrainIntent client fixtureIntent
      first `shouldSatisfy` isCommitted fixtureIntent
      second <- commitAndReadBackEksDrainIntent client fixtureIntent
      second `shouldSatisfy` isCommitted fixtureIntent
      recovered <- readBackCommittedEksDrainIntent client fixtureIntent
      recovered `shouldSatisfy` isCommitted fixtureIntent
      readIORef (fakeCreateCount fake) `shouldReturn` 2
      readIORef (fakeReadCount fake) `shouldReturn` 3
      stored <- readIORef (fakeStoredIntents fake)
      Map.lookup fixtureSubmissionKey stored
        `shouldBe` Just (encodeEksDrainIntent fixtureIntent)

    it "refuses a divergent payload in the same logical operation slot without replacing it" $ do
      fake <- newFakeRepository CommitNormally Nothing
      let client = lifecycleAuthorityEksDrainIntentClient (fakeRepository fake)
      committed <- commitAndReadBackEksDrainIntent client fixtureIntent
      committed `shouldSatisfy` isCommitted fixtureIntent
      divergent <- commitAndReadBackEksDrainIntent client alternateTargetIntent
      divergent
        `shouldBe` Left
          ( EksDrainIntentClientCommitUnconfirmed
              EksDrainIntentCommitConflict
              EksDrainIntentReadBackMismatch
          )
      stored <- readIORef (fakeStoredIntents fake)
      Map.lookup fixtureSubmissionKey stored
        `shouldBe` Just (encodeEksDrainIntent fixtureIntent)

    it "rejects read-back from another run, graph, scope, or any of the four operations" $ do
      forM_ wrongBindingIntents $ \(label, wrongIntent) -> do
        fake <-
          newFakeRepository
            CommitCancelledBeforeWrite
            ( Just
                ( EksDrainIntentAuthorityReadBackPresent
                    (encodeEksDrainIntent wrongIntent)
                )
            )
        let client = lifecycleAuthorityEksDrainIntentClient (fakeRepository fake)
        result <- readBackCommittedEksDrainIntent client fixtureIntent
        case result of
          Left (EksDrainIntentClientReadBackInvalid EksDrainIntentReadBackMismatch) ->
            pure ()
          other ->
            expectationFailure
              (Text.unpack label <> " produced unexpected result: " <> show other)

    it "rejects a read-back whose canonical payload names another registered key" $ do
      let wrongKeyBytes = rewriteRegisteredKey (encodeEksDrainIntent fixtureIntent)
      decodeEksDrainIntent wrongKeyBytes
        `shouldBe` Left (EksDrainIntentCodecResourceKeyInvalid "aws-test")
      fake <-
        newFakeRepository
          CommitCancelledBeforeWrite
          (Just (EksDrainIntentAuthorityReadBackPresent wrongKeyBytes))
      result <-
        readBackCommittedEksDrainIntent
          (lifecycleAuthorityEksDrainIntentClient (fakeRepository fake))
          fixtureIntent
      result
        `shouldBe` Left
          ( EksDrainIntentClientReadBackInvalid
              (EksDrainIntentCodecResourceKeyInvalid "aws-test")
          )

    it "fails closed on missing, unobservable, and unbounded independent read-back" $ do
      let cases =
            [
              ( EksDrainIntentAuthorityReadBackMissing
              , EksDrainIntentReadBackMissingRefusal
              )
            ,
              ( EksDrainIntentAuthorityReadBackUnobservable
                  (ObservationFailure "Authority read failed")
              , EksDrainIntentReadBackUnobservableRefusal
                  (ObservationFailure "Authority read failed")
              )
            ,
              ( EksDrainIntentAuthorityReadBackUnbounded 2 1
              , EksDrainIntentReadBackUnboundedRefusal 2 1
              )
            ]
      forM_ cases $ \(observation, expected) -> do
        fake <-
          newFakeRepository CommitCancelledBeforeWrite (Just observation)
        result <-
          readBackCommittedEksDrainIntent
            (lifecycleAuthorityEksDrainIntentClient (fakeRepository fake))
            fixtureIntent
        result
          `shouldBe` Left (EksDrainIntentClientReadBackInvalid expected)

    it "recovers an applied write after response loss but not a cancelled absent write" $ do
      lost <- newFakeRepository CommitAppliesThenLosesResponse Nothing
      recovered <-
        commitAndReadBackEksDrainIntent
          (lifecycleAuthorityEksDrainIntentClient (fakeRepository lost))
          fixtureIntent
      recovered `shouldSatisfy` isCommitted fixtureIntent
      readIORef (fakeCreateCount lost) `shouldReturn` 1
      readIORef (fakeReadCount lost) `shouldReturn` 1

      cancelled <- newFakeRepository CommitCancelledBeforeWrite Nothing
      refused <-
        commitAndReadBackEksDrainIntent
          (lifecycleAuthorityEksDrainIntentClient (fakeRepository cancelled))
          fixtureIntent
      refused
        `shouldBe` Left
          ( EksDrainIntentClientCommitUnconfirmed
              EksDrainIntentCommitCancelled
              EksDrainIntentReadBackMissingRefusal
          )
      readIORef (fakeStoredIntents cancelled) `shouldReturn` Map.empty

    it "persists create-if-absent through a fresh client over the same retained Model-B object" $ do
      durable <- newDurableModelB False
      let firstRepository =
            modelBEksDrainIntentRepository fixtureAuthority (durableModelBAdapter durable)
          firstClient = lifecycleAuthorityEksDrainIntentClient firstRepository
      created <- commitAndReadBackEksDrainIntent firstClient fixtureIntent
      created `shouldSatisfy` isCommitted fixtureIntent

      -- Model a Runtime restart: discard both repository and client values,
      -- retain only the Authority Model-B object, and construct fresh wrappers.
      let restartedRepository =
            modelBEksDrainIntentRepository fixtureAuthority (durableModelBAdapter durable)
          restartedClient = lifecycleAuthorityEksDrainIntentClient restartedRepository
      observed <- readBackCommittedEksDrainIntent restartedClient fixtureIntent
      observed `shouldSatisfy` isCommitted fixtureIntent
      replayed <- commitAndReadBackEksDrainIntent restartedClient fixtureIntent
      replayed `shouldSatisfy` isCommitted fixtureIntent
      readIORef (durableModelBWrites durable) `shouldReturn` 1
      stored <- readIORef (durableModelBValues durable)
      Map.lookup
        (eksDrainIntentAuthorityLogicalName (eksDrainIntentAuthorityIdentity fixtureIntent))
        stored
        `shouldSatisfy` storesIntent fixtureIntent

    it "recovers the exact selected target after a fresh process using identity only" $ do
      durable <- newDurableModelB False
      let firstClient =
            lifecycleAuthorityEksDrainIntentClient
              ( modelBEksDrainIntentRepository
                  fixtureAuthority
                  (durableModelBAdapter durable)
              )
      committed <- commitAndReadBackEksDrainIntent firstClient fixturePresentIntent
      committed `shouldSatisfy` isCommitted fixturePresentIntent

      -- The restarted process reconstructs only the validated operation
      -- binding.  It has no retained intent value or target-selection cache.
      let recoveryIdentity =
            eksDrainIntentAuthorityRecoveryIdentity
              (bindingFor fixtureRunId fixtureGraphDigest fixtureScope fixtureOperations)
          restartedClient =
            lifecycleAuthorityEksDrainIntentClient
              ( modelBEksDrainIntentRepository
                  fixtureAuthority
                  (durableModelBAdapter durable)
              )
      recovered <- recoverCommittedEksDrainIntent restartedClient recoveryIdentity
      recovered `shouldSatisfy` isCommitted fixturePresentIntent
      readIORef (durableModelBWrites durable) `shouldReturn` 1

      endpointResult <-
        serveEksDrainIntentEndpointRequest
          restartedClient
          ( encodeControlPlaneRequest
              (eksDrainIntentRecoveryWireRequest recoveryIdentity)
          )
      eksDrainIntentEndpointStatus endpointResult `shouldBe` ReplyOk
      endpointResponse <-
        mustRightIO
          ( decodeEksDrainIntentEndpointResponse
              (eksDrainIntentEndpointBody endpointResult)
          )
      confirmEksDrainIntentRecoveryResponse recoveryIdentity endpointResponse
        `shouldSatisfy` isCommitted fixturePresentIntent
      forM_
        [ eksDrainIntentEndpointFormatVersion - 1
        , eksDrainIntentEndpointFormatVersion + 1
        ]
        ( \wrongVersion ->
            confirmEksDrainIntentRecoveryResponse
              recoveryIdentity
              (rewriteResponseVersion wrongVersion endpointResponse)
              `shouldBe` Left
                ( EksDrainIntentEndpointResponseVersionMismatch
                    eksDrainIntentEndpointFormatVersion
                    wrongVersion
                )
        )

    it "keeps recovery missing, unobservable, unbounded, corrupt, and wrong identity distinct" $ do
      let expectedIdentity = eksDrainIntentAuthorityIdentity fixtureIntent
          cases =
            [
              ( EksDrainIntentAuthorityReadBackMissing
              , EksDrainIntentClientRecoveryMissing
              )
            ,
              ( EksDrainIntentAuthorityReadBackUnobservable (ObservationFailure "read failed")
              , EksDrainIntentClientRecoveryUnobservable
                  (ObservationFailure "read failed")
              )
            ,
              ( EksDrainIntentAuthorityReadBackUnbounded 8 4
              , EksDrainIntentClientRecoveryUnbounded 8 4
              )
            ,
              ( EksDrainIntentAuthorityReadBackPresent ByteString.empty
              , EksDrainIntentClientRecoveryCorrupt EksDrainIntentCodecEmpty
              )
            ,
              ( EksDrainIntentAuthorityReadBackCorrupt "retained codec rejected bytes"
              , EksDrainIntentClientRecoveryStoreCorrupt
                  "retained codec rejected bytes"
              )
            ]
      forM_ cases $ \(observation, expected) -> do
        fake <-
          newFakeRepository CommitCancelledBeforeWrite (Just observation)
        recovered <-
          recoverCommittedEksDrainIntent
            (lifecycleAuthorityEksDrainIntentClient (fakeRepository fake))
            expectedIdentity
        recovered `shouldBe` Left expected
      forM_ wrongBindingIntents $ \(_, wrongIntent) -> do
        fake <-
          newFakeRepository
            CommitCancelledBeforeWrite
            ( Just
                ( EksDrainIntentAuthorityReadBackPresent
                    (encodeEksDrainIntent wrongIntent)
                )
            )
        recovered <-
          recoverCommittedEksDrainIntent
            (lifecycleAuthorityEksDrainIntentClient (fakeRepository fake))
            expectedIdentity
        recovered
          `shouldBe` Left
            ( EksDrainIntentClientRecoveryIdentityMismatch
                expectedIdentity
                (eksDrainIntentAuthorityIdentity wrongIntent)
            )

    it "recovers a Model-B CAS response loss and keeps divergent bytes in conflict" $ do
      durable <- newDurableModelB True
      let repository =
            modelBEksDrainIntentRepository fixtureAuthority (durableModelBAdapter durable)
          client = lifecycleAuthorityEksDrainIntentClient repository
      recovered <- commitAndReadBackEksDrainIntent client fixtureIntent
      recovered `shouldSatisfy` isCommitted fixtureIntent
      divergent <- commitAndReadBackEksDrainIntent client alternateTargetIntent
      divergent
        `shouldBe` Left
          ( EksDrainIntentClientCommitUnconfirmed
              EksDrainIntentCommitConflict
              EksDrainIntentReadBackMismatch
          )
      readIORef (durableModelBWrites durable) `shouldReturn` 1

    it "serves bounded canonical commit and restart read-back responses over the endpoint algebra" $ do
      durable <- newDurableModelB False
      let endpointClient =
            lifecycleAuthorityEksDrainIntentClient
              ( modelBEksDrainIntentRepository
                  fixtureAuthority
                  (durableModelBAdapter durable)
              )
          encoded request = encodeControlPlaneRequest request
      committedResult <-
        serveEksDrainIntentEndpointRequest
          endpointClient
          (encoded (eksDrainIntentCommitWireRequest fixtureIntent))
      eksDrainIntentEndpointStatus committedResult `shouldBe` ReplyOk
      committedResponse <-
        mustRightIO
          (decodeEksDrainIntentEndpointResponse (eksDrainIntentEndpointBody committedResult))
      committedResponse
        `shouldSatisfy` isConfirmedWire
          EksDrainIntentCommitConfirmed
          fixtureIntent
      confirmEksDrainIntentEndpointResponse
        EksDrainIntentCommitConfirmed
        fixtureIntent
        committedResponse
        `shouldSatisfy` isCommitted fixtureIntent

      let restartedClient =
            lifecycleAuthorityEksDrainIntentClient
              ( modelBEksDrainIntentRepository
                  fixtureAuthority
                  (durableModelBAdapter durable)
              )
      readBackResult <-
        serveEksDrainIntentEndpointRequest
          restartedClient
          (encoded (eksDrainIntentReadBackWireRequest fixtureIntent))
      eksDrainIntentEndpointStatus readBackResult `shouldBe` ReplyOk
      readBackResponse <-
        mustRightIO
          (decodeEksDrainIntentEndpointResponse (eksDrainIntentEndpointBody readBackResult))
      readBackResponse
        `shouldSatisfy` isConfirmedWire
          EksDrainIntentReadBackConfirmed
          fixtureIntent
      confirmEksDrainIntentEndpointResponse
        EksDrainIntentReadBackConfirmed
        fixtureIntent
        readBackResponse
        `shouldSatisfy` isCommitted fixtureIntent

      let wrongDigestResponse = case readBackResponse of
            EksDrainIntentWireConfirmed version kind bytes _ ->
              EksDrainIntentWireConfirmed version kind bytes (Text.replicate 64 "f")
            other -> other
      confirmEksDrainIntentEndpointResponse
        EksDrainIntentReadBackConfirmed
        fixtureIntent
        wrongDigestResponse
        `shouldBe` Left
          ( EksDrainIntentEndpointResponseDigestMismatch
              (eksDrainIntentDigestText (eksDrainIntentDigest fixtureIntent))
              (Text.replicate 64 "f")
          )

      conflictResult <-
        serveEksDrainIntentEndpointRequest
          restartedClient
          (encoded (eksDrainIntentCommitWireRequest alternateTargetIntent))
      eksDrainIntentEndpointStatus conflictResult `shouldBe` ReplyConflict
      decodeEksDrainIntentEndpointResponse (eksDrainIntentEndpointBody conflictResult)
        `shouldBe` Right
          ( EksDrainIntentWireRefused
              eksDrainIntentEndpointFormatVersion
              EksDrainIntentWireCommitConflict
          )

    it
      "rejects oversized, malformed, wrong-version, and invalid-intent endpoint requests before storage"
      $ do
        durable <- newDurableModelB False
        let client =
              lifecycleAuthorityEksDrainIntentClient
                ( modelBEksDrainIntentRepository
                    fixtureAuthority
                    (durableModelBAdapter durable)
                )
            cases =
              [
                ( LazyByteString.replicate
                    (fromIntegral eksDrainIntentEndpointMaximumBytes + 1)
                    0
                , EksDrainIntentWireRequestTooLarge
                )
              , ("not-cbor", EksDrainIntentWireRequestInvalid)
              ,
                ( encodeControlPlaneRequest
                    ( (eksDrainIntentCommitWireRequest fixtureIntent)
                        { eksDrainIntentWireRequestVersion =
                            eksDrainIntentEndpointFormatVersion - 1
                        }
                    )
                , EksDrainIntentWireRequestUnsupportedVersion
                )
              ,
                ( encodeControlPlaneRequest
                    ( (eksDrainIntentCommitWireRequest fixtureIntent)
                        { eksDrainIntentWireRequestVersion =
                            eksDrainIntentEndpointFormatVersion + 1
                        }
                    )
                , EksDrainIntentWireRequestUnsupportedVersion
                )
              ,
                ( encodeControlPlaneRequest
                    EksDrainIntentWireRequest
                      { eksDrainIntentWireRequestVersion =
                          eksDrainIntentEndpointFormatVersion
                      , eksDrainIntentWireRequestAction = EksDrainIntentWireCommit
                      , eksDrainIntentWireRequestCanonicalBytes = "not-an-intent"
                      }
                , EksDrainIntentWireIntentInvalid
                )
              ,
                ( encodeControlPlaneRequest
                    EksDrainIntentWireRequest
                      { eksDrainIntentWireRequestVersion =
                          eksDrainIntentEndpointFormatVersion
                      , eksDrainIntentWireRequestAction = EksDrainIntentWireRecover
                      , eksDrainIntentWireRequestCanonicalBytes =
                          rewriteRegisteredKey
                            ( encodeEksDrainIntentAuthorityIdentity
                                (eksDrainIntentAuthorityIdentity fixtureIntent)
                            )
                      }
                , EksDrainIntentWireRecoveryIdentityInvalid
                )
              ]
        forM_ cases $ \(request, expectedRefusal) -> do
          result <- serveEksDrainIntentEndpointRequest client request
          eksDrainIntentEndpointStatus result `shouldBe` ReplyBadRequest
          decodeEksDrainIntentEndpointResponse (eksDrainIntentEndpointBody result)
            `shouldBe` Right
              ( EksDrainIntentWireRefused
                  eksDrainIntentEndpointFormatVersion
                  expectedRefusal
              )
        readIORef (durableModelBWrites durable) `shouldReturn` 0

data DurableModelB = DurableModelB
  { durableModelBAdapter :: ModelBCasAdapter 'ClusterRetained IO ByteString
  , durableModelBValues
      :: IORef (Map Text (ModelBObjectVersion, ByteString))
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
              pure
                ( ModelBCasConflict
                    (ModelBObserved version current)
                )
            Nothing -> do
              atomicModifyIORef'
                valuesRef
                (\values -> (Map.insert logicalName (fixtureModelBVersion, bytes) values, ()))
              atomicModifyIORef' writesRef (\count -> (count + 1, ()))
              lose <-
                atomicModifyIORef'
                  loseResponseRef
                  ( \shouldLose ->
                      if shouldLose
                        then (False, True)
                        else (False, False)
                  )
              pure $
                if lose
                  then ModelBCasUnobservable "CAS response lost"
                  else ModelBCasApplied fixtureModelBVersion bytes
        ModelBReplace {} ->
          pure (ModelBCasUnobservable "unexpected replace in create-only repository")
        ModelBInitializeGuarded {} ->
          pure (ModelBCasUnobservable "unexpected guarded initialize")
        ModelBReplaceGuarded {} ->
          pure (ModelBCasUnobservable "unexpected guarded replace")
      adapter =
        ModelBCasAdapter
          { modelBObserve = \coordinate -> do
              values <- readIORef valuesRef
              pure $ case Map.lookup (modelBObjectLogicalName coordinate) values of
                Nothing -> ModelBMissing
                Just (version, bytes) -> ModelBObserved version bytes
          , modelBCompareAndSwap = compareAndSwap
          }
  pure
    DurableModelB
      { durableModelBAdapter = adapter
      , durableModelBValues = valuesRef
      , durableModelBWrites = writesRef
      }

storesIntent
  :: EksDrainIntent
  -> Maybe (ModelBObjectVersion, ByteString)
  -> Bool
storesIntent expected stored = case stored of
  Just (_, bytes) -> bytes == encodeEksDrainIntent expected
  Nothing -> False

isConfirmedWire
  :: EksDrainIntentConfirmationKind
  -> EksDrainIntent
  -> EksDrainIntentWireResponse
  -> Bool
isConfirmedWire expectedKind expectedIntent response = case response of
  EksDrainIntentWireConfirmed version kind bytes digest ->
    version == eksDrainIntentEndpointFormatVersion
      && kind == expectedKind
      && bytes == encodeEksDrainIntent expectedIntent
      && digest == eksDrainIntentDigestText (eksDrainIntentDigest expectedIntent)
  EksDrainIntentWireRefused {} -> False
  EksDrainIntentWireEndpointUnavailable {} -> False

rewriteResponseVersion
  :: Word16
  -> EksDrainIntentWireResponse
  -> EksDrainIntentWireResponse
rewriteResponseVersion version response = case response of
  EksDrainIntentWireConfirmed _ kind bytes digest ->
    EksDrainIntentWireConfirmed version kind bytes digest
  EksDrainIntentWireRefused _ refusal ->
    EksDrainIntentWireRefused version refusal
  EksDrainIntentWireEndpointUnavailable _ unavailable ->
    EksDrainIntentWireEndpointUnavailable version unavailable

data FakeCommitBehavior
  = CommitNormally
  | CommitAppliesThenLosesResponse
  | CommitCancelledBeforeWrite

data FakeRepository = FakeRepository
  { fakeRepository :: EksDrainIntentRepository IO
  , fakeStoredIntents
      :: IORef (Map EksDrainIntentSubmissionKey ByteString)
  , fakeCreateCount :: IORef Int
  , fakeReadCount :: IORef Int
  }

newFakeRepository
  :: FakeCommitBehavior
  -> Maybe EksDrainIntentAuthorityReadBackObservation
  -> IO FakeRepository
newFakeRepository behavior forcedReadBack = do
  stored <- newIORef Map.empty
  creates <- newIORef 0
  repositoryReadCountRef <- newIORef 0
  let repository =
        EksDrainIntentRepository
          { createOrReplayAuthorityEksDrainIntent = \request -> do
              atomicModifyIORef' creates (\count -> (count + 1, ()))
              case behavior of
                CommitCancelledBeforeWrite ->
                  pure EksDrainIntentCommitCancelled
                CommitNormally -> storeRequest stored request
                CommitAppliesThenLosesResponse -> do
                  _ <- storeRequest stored request
                  pure
                    ( EksDrainIntentCommitResponseLost
                        (ObservationFailure "commit response lost")
                    )
          , independentlyReadBackAuthorityEksDrainIntent = \identity -> do
              atomicModifyIORef' repositoryReadCountRef (\count -> (count + 1, ()))
              case forcedReadBack of
                Just observation -> pure observation
                Nothing -> do
                  values <- readIORef stored
                  pure $ case Map.lookup
                    (eksDrainIntentAuthoritySubmissionKey identity)
                    values of
                    Nothing -> EksDrainIntentAuthorityReadBackMissing
                    Just bytes -> EksDrainIntentAuthorityReadBackPresent bytes
          }
  pure
    FakeRepository
      { fakeRepository = repository
      , fakeStoredIntents = stored
      , fakeCreateCount = creates
      , fakeReadCount = repositoryReadCountRef
      }

storeRequest
  :: IORef (Map EksDrainIntentSubmissionKey ByteString)
  -> EksDrainIntentCommitRequest
  -> IO EksDrainIntentCommitResult
storeRequest stored request =
  atomicModifyIORef' stored $ \values ->
    let key =
          eksDrainIntentAuthoritySubmissionKey
            (eksDrainIntentCommitRequestIdentity request)
        bytes = eksDrainIntentCommitRequestBytes request
     in case Map.lookup key values of
          Nothing ->
            (Map.insert key bytes values, EksDrainIntentCommitCreated)
          Just existing
            | existing == bytes ->
                (values, EksDrainIntentCommitExactReplay)
            | otherwise -> (values, EksDrainIntentCommitConflict)

isCommitted
  :: EksDrainIntent
  -> Either error CommittedEksDrainIntent
  -> Bool
isCommitted expected result = case result of
  Right committed -> committedEksDrainIntent committed == expected
  Left _ -> False

fixtureSubmissionKey :: EksDrainIntentSubmissionKey
fixtureSubmissionKey =
  eksDrainIntentAuthoritySubmissionKey
    (eksDrainIntentAuthorityIdentity fixtureIntent)

fixtureIntent :: EksDrainIntent
fixtureIntent = noTargetIntent fixtureRunId fixtureGraphDigest fixtureScope fixtureOperations 13

-- Same logical Authority slot, different target observation.  The repository
-- must expose this as a conflict, never as a second submission identity.
alternateTargetIntent :: EksDrainIntent
alternateTargetIntent =
  noTargetIntent fixtureRunId fixtureGraphDigest fixtureScope fixtureOperations 14

fixturePresentIntent :: EksDrainIntent
fixturePresentIntent =
  mustRight
    ( prepareEksKubernetesDrainIntent
        (bindingFor fixtureRunId fixtureGraphDigest fixtureScope fixtureOperations)
        fixtureSession
        ( eksDrainTargetSelectionObservationFor
            fixtureSession
            (ObservationRevision 21)
            (EksDrainTargetSelectionComplete [])
        )
    )

wrongBindingIntents :: [(Text, EksDrainIntent)]
wrongBindingIntents =
  [
    ( "wrong run"
    , noTargetIntent
        otherRunId
        fixtureGraphDigest
        otherRunScope
        fixtureOperations
        13
    )
  ,
    ( "wrong graph"
    , noTargetIntent
        fixtureRunId
        otherGraphDigest
        fixtureScope
        fixtureOperations
        13
    )
  ,
    ( "wrong scope"
    , noTargetIntent
        fixtureRunId
        fixtureGraphDigest
        totalDecommissionScope
        fixtureOperations
        13
    )
  ]
    <> zipWith
      ( \label operations ->
          ( label
          , noTargetIntent
              fixtureRunId
              fixtureGraphDigest
              fixtureScope
              operations
              13
          )
      )
      [ "wrong commit operation"
      , "wrong intent read-back operation"
      , "wrong effect operation"
      , "wrong drain read-back operation"
      ]
      wrongOperationSets

data FixtureOperations = FixtureOperations
  { fixtureCommitOperation :: CleanupOperationId
  , fixtureIntentReadBackOperation :: CleanupOperationId
  , fixtureEffectOperation :: CleanupOperationId
  , fixtureDrainReadBackOperation :: CleanupOperationId
  }

fixtureOperations :: FixtureOperations
fixtureOperations =
  FixtureOperations
    commitOperation
    intentReadBackOperation
    effectOperation
    drainReadBackOperation

wrongOperationSets :: [FixtureOperations]
wrongOperationSets =
  [ fixtureOperations {fixtureCommitOperation = otherCommitOperation}
  , fixtureOperations {fixtureIntentReadBackOperation = otherIntentReadBackOperation}
  , fixtureOperations {fixtureEffectOperation = otherEffectOperation}
  , fixtureOperations {fixtureDrainReadBackOperation = otherDrainReadBackOperation}
  ]

bindingFor
  :: CleanupRunId
  -> CleanupDigest
  -> ObservationEvidenceScope
  -> FixtureOperations
  -> EksDrainOperationBinding
bindingFor runId graphDigest scope operations =
  mustRight
    ( mkEksDrainOperationBinding
        scope
        runId
        graphDigest
        (fixtureCommitOperation operations)
        (fixtureIntentReadBackOperation operations)
        (fixtureEffectOperation operations)
        (fixtureDrainReadBackOperation operations)
    )

noTargetIntent
  :: CleanupRunId
  -> CleanupDigest
  -> ObservationEvidenceScope
  -> FixtureOperations
  -> Word64
  -> EksDrainIntent
noTargetIntent runId graphDigest scope operations revision =
  mustRight
    ( prepareEksNoKubernetesTargetIntent
        (bindingFor runId graphDigest scope operations)
        (verifiedAbsent scope revision)
    )

verifiedAbsent
  :: ObservationEvidenceScope
  -> Word64
  -> VerifiedAwsEksObservation 'ObserveEksForDecision
verifiedAbsent scope revision =
  let request =
        mustRight
          (mkAwsEksDecisionObservationRequest (ObservationRevision revision) scope)
   in case decodeAwsEksObservation
        request
        ( Right
            ( ProviderIntentExecutionObserved
                (awsEksObservationRequestProviderCoordinate request)
                "registered EKS cluster is absent"
            )
        ) of
        AwsEksObservationDecoded verified -> verified
        AwsEksObservationRejected err _ ->
          error ("absent EKS fixture rejected: " <> show err)

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

fixtureVerifiedPresent
  :: VerifiedAwsEksObservation 'ObserveEksForDecision
fixtureVerifiedPresent =
  let request =
        mustRight
          (mkAwsEksDecisionObservationRequest (ObservationRevision 18) fixtureScope)
   in case decodeAwsEksObservation
        request
        ( Right
            ( ProviderIntentExecutionObserved
                (awsEksObservationRequestProviderCoordinate request)
                ("eks-cluster-arn:" <> fixtureArn)
            )
        ) of
        AwsEksObservationDecoded verified -> verified
        AwsEksObservationRejected err _ ->
          error ("present EKS fixture rejected: " <> show err)

fixtureKubernetesIdentity :: EksKubernetesIdentityObservation
fixtureKubernetesIdentity =
  eksKubernetesIdentityObservationFor
    fixtureScope
    (ObservationRevision 19)
    fixtureArn
    (EksKubernetesIdentityPresent "eks-kube-system-uid-7")
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

fixtureRunId, otherRunId :: CleanupRunId
fixtureRunId = mustRight (mkCleanupRunId "cleanup-run/eks-drain-repository")
otherRunId = mustRight (mkCleanupRunId "cleanup-run/eks-drain-other")

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
commitOperation = mustRight (mkCleanupOperationId "operation/eks-intent-commit")
intentReadBackOperation = mustRight (mkCleanupOperationId "operation/eks-intent-readback")
effectOperation = mustRight (mkCleanupOperationId "operation/eks-drain-effect")
drainReadBackOperation = mustRight (mkCleanupOperationId "operation/eks-drain-readback")
otherCommitOperation = mustRight (mkCleanupOperationId "operation/other-intent-commit")
otherIntentReadBackOperation = mustRight (mkCleanupOperationId "operation/other-intent-readback")
otherEffectOperation = mustRight (mkCleanupOperationId "operation/other-drain-effect")
otherDrainReadBackOperation = mustRight (mkCleanupOperationId "operation/other-drain-readback")

fixtureScope, otherRunScope, totalDecommissionScope :: ObservationEvidenceScope
fixtureScope = scopeFor Cascade fixtureRunId
otherRunScope = scopeFor Cascade otherRunId
totalDecommissionScope = scopeFor TotalDecommission fixtureRunId

scopeFor :: CleanupSurface -> CleanupRunId -> ObservationEvidenceScope
scopeFor surface runId =
  mkObservationEvidenceScope
    surface
    lifecycleRegistryRevision
    (DurableObservationRunScope (cleanupRunIdText runId))
    (LinuxRke2FoundationId "home-linux-rke2")
    (Just (AwsScope (AwsAccountId "123456789012") (AwsRegion (fixtureAwsRegion FixtureUsEast1))))
    ReconcileDesiredAbsent

fixtureArn, fixtureEndpoint, fixtureCertificateAuthority, fixtureBearer :: Text
fixtureArn =
  ("arn:aws:eks:" <> (fixtureAwsRegion FixtureUsEast1) <> ":123456789012:cluster/aws-eks-test-cluster")
fixtureEndpoint = "https://sensitive.eks.amazonaws.com"
fixtureCertificateAuthority = "sensitive-ca-plaintext"
fixtureBearer = "sensitive-bearer-plaintext"

fixtureAuthority :: LongLivedCheckpointAuthority
fixtureAuthority =
  mustRight
    ( mkLongLivedCheckpointAuthority
        "home-linux-rke2"
        "prodbox-authority"
        "authority"
        "secret/lifecycle"
    )

fixtureModelBVersion :: ModelBObjectVersion
fixtureModelBVersion = mustRight (mkModelBObjectVersion "eks-drain-version-1")

rewriteRegisteredKey :: ByteString -> ByteString
rewriteRegisteredKey bytes =
  let old = ByteString.cons 0x67 "aws-eks"
      new = ByteString.cons 0x68 "aws-test"
      (prefix, suffix) = ByteString.breakSubstring old bytes
   in if ByteString.null suffix
        then error "canonical EKS intent did not contain its resource key"
        else prefix <> new <> ByteString.drop (ByteString.length old) suffix

rewriteSameLengthText :: Text -> Text -> ByteString -> ByteString
rewriteSameLengthText oldText newText bytes
  | Text.length oldText /= Text.length newText =
      error "same-length EKS identity rewrite changed the CBOR field length"
  | otherwise =
      let old = TextEncoding.encodeUtf8 oldText
          new = TextEncoding.encodeUtf8 newText
          (prefix, suffix) = ByteString.breakSubstring old bytes
       in if ByteString.null suffix
            then error "canonical EKS identity did not contain expected field"
            else prefix <> new <> ByteString.drop (ByteString.length old) suffix

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error ("invalid EKS drain repository fixture: " <> show err)
  Right value -> value

mustRightIO :: (Show err) => Either err value -> IO value
mustRightIO = pure . mustRight
