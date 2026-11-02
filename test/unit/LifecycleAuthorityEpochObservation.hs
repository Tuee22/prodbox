{-# LANGUAGE OverloadedStrings #-}

module LifecycleAuthorityEpochObservation (lifecycleAuthorityEpochObservationSuite) where

import Control.Monad (forM_)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (isLeft)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Set qualified as Set
import Data.Text qualified as Text
import EpochPromotionFixture
import Numeric (showHex)
import Prodbox.Capacity.ControlPlaneReplayBudget qualified as ReplayBudget
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
import Prodbox.ControlPlane.AuthorityControlClient
import Prodbox.ControlPlane.AuthorityControlProtocol (isEpochPromotionObservationRequest)
import Prodbox.ControlPlane.Client (ControlPlaneResponse (..))
import Prodbox.ControlPlane.Codec
import Prodbox.Http.ReplyStatus (ReplyStatus (..), replyStatusCode)
import Prodbox.Lifecycle.Authority.Admission
import Prodbox.Lifecycle.Authority.EpochPromotion
import Prodbox.Lifecycle.Authority.EpochPromotionObservation
import Prodbox.Lifecycle.Authority.EpochTopology
import Prodbox.Lifecycle.Authority.Genesis
import TestSupport

lifecycleAuthorityEpochObservationSuite :: SuiteBuilder ()
lifecycleAuthorityEpochObservationSuite =
  describe "Sprint 6.5 authenticated epoch promotion observation" $ do
    it "reads one complete snapshot through the actual control endpoint without a CAS" $ do
      let states = scanl apply importedFrozenEpochAggregate (epochPromotionCommands 1 2)
      forM_ states $ \aggregate -> do
        readCount <- newIORef (0 :: Int)
        writeCount <- newIORef (0 :: Int)
        let repository = observationRepository readCount writeCount aggregate
        result <- serveAuthorityControlRequest 4096 repository query
        authorityTransitionHttpStatus result `shouldBe` ReplyOk
        observation <-
          either
            (fail . show)
            pure
            ( decodeEpochPromotionObservationResponse
                ( ControlPlaneResponse
                    (replyStatusCode (authorityTransitionHttpStatus result))
                    (LazyByteString.toStrict (authorityTransitionResponseBody result))
                )
            )
        observedRetainedEpoch observation
          `shouldBe` fromIntegral (authorityEpochValue (authorityAggregateAuthenticationEpoch aggregate))
        observedNormalAdmissionEpoch observation
          `shouldBe` either (const Nothing) (Just . fromIntegral . authorityEpochValue) (activeAuthorityEpoch aggregate)
        case observedPreparedEpoch observation of
          Nothing -> aggregate `shouldBe` importedFrozenEpochAggregate
          Just prepared -> do
            observedPreparationTopology prepared `shouldBe` epochTopologyFixture
            observedPreparationTopologyDigest prepared `shouldBe` epochTopologyFixtureDigest
            observedPreparationTarget prepared `shouldBe` 2
        readIORef readCount `shouldReturn` 1
        readIORef writeCount `shouldReturn` 0

    it "preserves unobservable state instead of inventing an empty preparation" $ do
      writeCount <- newIORef (0 :: Int)
      let repository =
            AuthorityAdmissionRepository
              { readAuthorityAdmission = pure (Left "unobservable")
              , compareAndSwapAuthorityAdmission = \_ _ -> modifyIORef' writeCount (+ 1) >> pure (Right ())
              }
              :: AuthorityAdmissionRepository IO Word
      result <- serveAuthorityControlRequest 4096 repository query
      authorityTransitionHttpStatus result `shouldBe` ReplyServiceUnavailable
      readIORef writeCount `shouldReturn` 0

    it "fits the maximum declared inventory inside the existing Authority response ceiling" $ do
      let substrates = Set.fromList [CutoverHome, CutoverAws]
          core = requiredEpochTopologyBindings substrates Set.empty Set.empty
          scopes = Set.fromList [(CutoverHome, fixtureDigest index) | index <- [1 .. 256 - Set.size core]]
          bindings = requiredEpochTopologyBindings substrates scopes Set.empty
          topology =
            mustRight
              (mkEpochTopology substrates scopes Set.empty (Map.fromSet (const (fixtureDigest 1000)) bindings))
          prepared = mustRight (prepareEpochPromotion 1 2 topology)
          observation = mustRight (observeEpochPromotion authorityEpochGenesis Nothing (Just prepared))
          encoded = encodeControlPlaneResponse observation
      Set.size (epochTopologyBindings topology) `shouldBe` 256
      LazyByteString.length encoded
        `shouldSatisfy` (<= fromIntegral ReplayBudget.authorityMetadataResponseMaximumBytes)
      decodeEpochPromotionObservationResponse (ControlPlaneResponse 200 (LazyByteString.toStrict encoded))
        `shouldBe` Right observation

    it "refuses malformed, oversized and legacy-text success envelopes" $ do
      forM_
        [ "not-cbor"
        , "authority-epoch-promotion-observed"
        , ByteString.replicate (ReplayBudget.authorityMetadataResponseMaximumBytes + 1) 97
        ]
        $ \body ->
          decodeEpochPromotionObservationResponse (ControlPlaneResponse 200 body) `shouldSatisfy` isLeft
      decodeEpochPromotionObservationResponse (ControlPlaneResponse 409 "authority-transition-refused")
        `shouldBe` Left (AuthorityControlRefused "authority-transition-refused")

    it "refuses forged epochs, admission and topology identities in a successful envelope" $ do
      let state = mustRight (prepareEpochPromotion 1 2 epochTopologyFixture)
          good = mustRight (observeEpochPromotion authorityEpochGenesis Nothing (Just state))
          prepared = fromJust (observedPreparedEpoch good)
          wrong = fixtureDigest 2000
          bad =
            [ good {observedRetainedEpoch = 0}
            , good {observedNormalAdmissionEpoch = Just 2}
            , good {observedNormalAdmissionEpoch = Just 1}
            , good {observedPreparedEpoch = Just prepared {observedPreparationTopologyDigest = wrong}}
            , good {observedPreparedEpoch = Just prepared {observedPreparationTarget = 1}}
            ]
      forM_ bad $ \observation ->
        decodeEpochPromotionObservationResponse
          (ControlPlaneResponse 200 (LazyByteString.toStrict (encodeControlPlaneResponse observation)))
          `shouldSatisfy` isLeft

    it "refuses an authentication epoch outside the wire bound" $ do
      let tooLarge = fromJust (authorityEpochFromValue (fromIntegral (maxBound :: Word) + 1))
      observeEpochPromotion tooLarge Nothing Nothing `shouldBe` Left EpochObservationEpochOutOfRange

    it "classifies only the canonical observer as a fresh-nonce read" $ do
      isEpochPromotionObservationRequest (LazyByteString.toStrict query) `shouldBe` True
      forM_
        [ encodeControlPlaneRequest AuthorityControlBeginMigration
        , encodeControlPlaneRequest (AuthorityControlBindProviderGeneration 7)
        , encodeControlPlaneRequest AuthorityControlObserveProviderBootstrapPredecessor
        , query <> LazyByteString.singleton 0
        , "not-cbor"
        ]
        $ \body -> isEpochPromotionObservationRequest (LazyByteString.toStrict body) `shouldBe` False

    it "keeps the established nullary control constructor wire indices" $ do
      encodeControlPlaneRequest AuthorityControlBeginMigration
        `shouldBe` LazyByteString.pack [131, 0, 1, 129, 2]
      encodeControlPlaneRequest AuthorityControlObserveProviderBootstrapPredecessor
        `shouldBe` LazyByteString.pack [131, 0, 1, 129, 10]
 where
  query = encodeControlPlaneRequest AuthorityControlObserveEpochPromotion
  apply aggregate command = applyEpochAggregateCommand aggregate (ApplyAuthorityMigration command)

observationRepository
  :: IORef Int -> IORef Int -> AuthorityAdmissionAggregate -> AuthorityAdmissionRepository IO Word
observationRepository readCount writeCount aggregate =
  AuthorityAdmissionRepository
    { readAuthorityAdmission =
        modifyIORef' readCount (+ 1) >> pure (Right (AuthorityAdmissionSnapshot 7 aggregate))
    , compareAndSwapAuthorityAdmission = \_ _ -> modifyIORef' writeCount (+ 1) >> pure (Left "observation must not write")
    }

fixtureDigest :: Int -> CutoverDigest
fixtureDigest index = fromJust (mkCutoverDigest (Text.justifyRight 64 '0' (Text.pack (showHex index ""))))

mustRight :: (Show err) => Either err value -> value
mustRight = either (error . show) id
