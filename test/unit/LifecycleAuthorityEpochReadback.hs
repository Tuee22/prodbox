{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleAuthorityEpochReadback (lifecycleAuthorityEpochReadbackSuite) where

import Control.Exception (AsyncException (UserInterrupt), throwIO, try)
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import EpochPromotionFixture
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
import Prodbox.ControlPlane.EpochBindingReadback
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.Authority.Admission
import Prodbox.Lifecycle.Authority.EpochPromotion
import Prodbox.Lifecycle.Authority.EpochTopology
import Prodbox.Lifecycle.Authority.Genesis
import Prodbox.Lifecycle.Authority.Migration
import TestSupport

lifecycleAuthorityEpochReadbackSuite :: SuiteBuilder ()
lifecycleAuthorityEpochReadbackSuite =
  describe "Sprint 6.5 server-owned physical epoch binding readbacks" $ do
    it "rejects the frozen endpoint's echoed digest after an independent physical read" $ do
      fixture <- newFixture prepared (Right authorityEpochGenesis)
      let echoed = fromJust (mkCutoverDigest (Text.replicate 64 "e"))
      serve
        fixture
        (ObservePreparedEpochBinding (EpochBindingReadback RetainedAuthenticationEpochBinding echoed))
        `shouldReturn` Just (ReplyConflict, "epoch-binding-readback/binding-digest-mismatch")
      readIORef (physicalReads fixture) `shouldReturn` 1
      readIORef (casWrites fixture) `shouldReturn` 0
      readIORef (retainedState fixture) `shouldReturn` (1, prepared)

    it "records preparation from the real interpreter without publishing the target epoch" $ do
      fixture <- newFixture prepared (Right authorityEpochGenesis)
      serve fixture (ObservePreparedEpochBinding authenticationReadback)
        `shouldReturn` Just (ReplyOk, "migration-accepted")
      readIORef (physicalReads fixture) `shouldReturn` 1
      readIORef (casWrites fixture) `shouldReturn` 1
      (_, final) <- readIORef (retainedState fixture)
      final `shouldBe` apply prepared (ObservePreparedEpochBinding authenticationReadback)
      authorityAggregateAuthenticationEpoch final `shouldBe` authorityEpochGenesis

    it "requires a fresh physical read even for an exact recorded preparation replay" $ do
      fixture <-
        newFixture
          (apply prepared (ObservePreparedEpochBinding authenticationReadback))
          (Right authorityEpochGenesis)
      serve fixture (ObservePreparedEpochBinding authenticationReadback)
        `shouldReturn` Just (ReplyOk, "migration-already-applied")
      readIORef (physicalReads fixture) `shouldReturn` 1
      readIORef (casWrites fixture) `shouldReturn` 0
      writeIORef (physicalEpoch fixture) (Right epoch2)
      serve fixture (ObservePreparedEpochBinding authenticationReadback)
        `shouldReturn` Just (ReplyConflict, "epoch-binding-readback/retained-epoch-mismatch")
      readIORef (physicalReads fixture) `shouldReturn` 2
      readIORef (casWrites fixture) `shouldReturn` 0

    forM_
      [ ("preparation", prepared, ObservePreparedEpochBinding authenticationReadback)
      , ("promotion", frozen, ObservePromotedEpochBinding authenticationReadback)
      ]
      $ \(label, aggregate, action) -> do
        it ("refuses unobservable " ++ label ++ " without retaining provider text") $ do
          fixture <- newFixture aggregate (Left "private-backend-observation-sentinel")
          serve fixture action
            `shouldReturn` Just (ReplyServiceUnavailable, "epoch-binding-readback/authentication-epoch-unobservable")
          readIORef (casWrites fixture) `shouldReturn` 0
        it ("refuses the wrong physical epoch during " ++ label) $ do
          fixture <- newFixture aggregate (Right epoch3)
          serve fixture action
            `shouldReturn` Just (ReplyConflict, "epoch-binding-readback/retained-epoch-mismatch")
          readIORef (casWrites fixture) `shouldReturn` 0

    it "records promotion only after the frozen CAS and real epoch publication" $ do
      fixture <- newFixture frozen (Right epoch2)
      serve fixture (ObservePromotedEpochBinding authenticationReadback)
        `shouldReturn` Just (ReplyOk, "migration-accepted")
      (_, final) <- readIORef (retainedState fixture)
      final `shouldBe` apply frozen (ObservePromotedEpochBinding authenticationReadback)
      activeAuthorityEpoch final `shouldSatisfy` either (const True) (const False)
      authorityAggregateAuthenticationEpoch final `shouldBe` epoch2

    it "refuses promotion while the target is only prepared" $ do
      fixture <- newFixture prepared (Right authorityEpochGenesis)
      serve fixture (ObservePromotedEpochBinding authenticationReadback)
        `shouldReturn` Just (ReplyConflict, "epoch-binding-readback/wrong-phase")
      readIORef (casWrites fixture) `shouldReturn` 0

    it "distinguishes old mutation admission from the retained control authentication epoch" $ do
      forM_ [(prepared, authorityEpochGenesis), (frozen, epoch2), (opened, epoch2)] $ \(aggregate, actual) -> do
        fixture <- newFixture aggregate (Right actual)
        result <- serve fixture (ObserveOldEpochRejected authenticationReadback 1)
        fmap fst result `shouldBe` Just ReplyOk
        readIORef (physicalReads fixture) `shouldReturn` 1
      fixture <- newFixture prepared (Right authorityEpochGenesis)
      serve fixture (ObserveOldEpochRejected authenticationReadback 2)
        `shouldReturn` Just (ReplyConflict, "epoch-binding-readback/context-mismatch")
      readIORef (casWrites fixture) `shouldReturn` 0

    forM_ (Set.toList (Set.delete RetainedAuthenticationEpochBinding (epochTopologyBindings topology))) $ \binding ->
      it ("keeps the authentication-only interpreter from accepting " ++ show binding) $ do
        fixture <- newFixture prepared (Right authorityEpochGenesis)
        let supplied = EpochBindingReadback binding (fromJust (epochTopologyBindingDigest topology binding))
        serve fixture (ObservePreparedEpochBinding supplied)
          `shouldReturn` Just (ReplyServiceUnavailable, "epoch-binding-readback/unsupported-binding")
        readIORef (physicalReads fixture) `shouldReturn` 0
        readIORef (casWrites fixture) `shouldReturn` 0

    it "refuses a changed target or topology before reading the backend" $ do
      fixture <- newFixture prepared (Right authorityEpochGenesis)
      let command request = LazyByteString.toStrict (encodeMigrationCommand (ApplyPreparedEpochPromotion request))
          action = ObservePreparedEpochBinding authenticationReadback
          requests =
            [ EpochPromotionRequest 3 topologyDigest action
            , EpochPromotionRequest 2 (fromJust (mkCutoverDigest (Text.replicate 64 "f"))) action
            ]
      forM_ requests $ \request ->
        serveEpochBindingReadbackRequest
          4096
          (fixtureBackend fixture)
          (fixtureRepository fixture)
          (command request)
          `shouldReturn` Just (ReplyConflict, "epoch-binding-readback/context-mismatch")
      readIORef (physicalReads fixture) `shouldReturn` 0
      readIORef (casWrites fixture) `shouldReturn` 0

    it "never records an earlier observation against a concurrently committed phase" $ do
      fixture <- newFixture prepared (Right authorityEpochGenesis)
      let backend = EpochAuthenticationBackend $ do
            modifyIORef' (physicalReads fixture) (+ 1)
            writeIORef (retainedState fixture) (2, frozen)
            pure (Right authorityEpochGenesis)
      serveWith fixture backend (ObserveOldEpochRejected authenticationReadback 1)
        `shouldReturn` Just (ReplyConflict, "epoch-binding-readback/concurrent-state")
      readIORef (retainedState fixture) `shouldReturn` (2, frozen)
      readIORef (casWrites fixture) `shouldReturn` 1

    it "confirms an applied CAS whose reply was lost without a second mutation" $ do
      fixture <- newFixture prepared (Right authorityEpochGenesis)
      let repository =
            (fixtureRepository fixture)
              { compareAndSwapAuthorityAdmission = \revision next -> do
                  result <- compareAndSwapAuthorityAdmission (fixtureRepository fixture) revision next
                  pure (Left "lost-write-response" <* result)
              }
      serveEpochBindingReadbackRequest
        4096
        (fixtureBackend fixture)
        repository
        (body (ObservePreparedEpochBinding authenticationReadback))
        `shouldReturn` Just (ReplyOk, "migration-accepted")
      readIORef (casWrites fixture) `shouldReturn` 1
      readIORef (physicalReads fixture) `shouldReturn` 1

    it "does not claim a write when a successful response is not read back" $ do
      fixture <- newFixture prepared (Right authorityEpochGenesis)
      let repository =
            (fixtureRepository fixture)
              { compareAndSwapAuthorityAdmission = \_ _ -> pure (Right ())
              }
      serveEpochBindingReadbackRequest
        4096
        (fixtureBackend fixture)
        repository
        (body (ObservePreparedEpochBinding authenticationReadback))
        `shouldReturn` Just (ReplyConflict, "epoch-binding-readback/concurrent-state")
      readIORef (retainedState fixture) `shouldReturn` (1, prepared)

    it "preserves an unobservable Authority read and never reads the backend" $ do
      fixture <- newFixture prepared (Right authorityEpochGenesis)
      let repository = (fixtureRepository fixture) {readAuthorityAdmission = pure (Left "private-authority-sentinel")}
      serveEpochBindingReadbackRequest
        4096
        (fixtureBackend fixture)
        repository
        (body (ObservePreparedEpochBinding authenticationReadback))
        `shouldReturn` Just (ReplyServiceUnavailable, "epoch-binding-readback/authority-unobservable")
      readIORef (physicalReads fixture) `shouldReturn` 0

    it "reports a successful CAS with an unreadable closing state as unobservable" $ do
      fixture <- newFixture prepared (Right authorityEpochGenesis)
      readCount <- newIORef (0 :: Int)
      let repository =
            (fixtureRepository fixture)
              { readAuthorityAdmission = do
                  count <- atomicModifyIORef' readCount (\value -> (value + 1, value + 1))
                  if count == 1
                    then readAuthorityAdmission (fixtureRepository fixture)
                    else pure (Left "private-closing-read-sentinel")
              }
      serveEpochBindingReadbackRequest
        4096
        (fixtureBackend fixture)
        repository
        (body (ObservePreparedEpochBinding authenticationReadback))
        `shouldReturn` Just (ReplyServiceUnavailable, "epoch-binding-readback/write-unobservable")
      readIORef (casWrites fixture) `shouldReturn` 1

    it "propagates cancellation before recording any readback" $ do
      fixture <- newFixture prepared (Right authorityEpochGenesis)
      let backend = EpochAuthenticationBackend (throwIO UserInterrupt)
      result <-
        try (serveWith fixture backend (ObservePreparedEpochBinding authenticationReadback))
          :: IO (Either AsyncException (Maybe (ReplyStatus, ByteString)))
      result `shouldBe` Left UserInterrupt
      readIORef (casWrites fixture) `shouldReturn` 0

    it "observes non-publication during precommit retirement without restoring the old writer" $ do
      let rollback = apply prepared BeginPreparedEpochRollback
      fixture <- newFixture rollback (Right authorityEpochGenesis)
      serve fixture (ObservePreparedEpochBindingAbsent RetainedAuthenticationEpochBinding)
        `shouldReturn` Just (ReplyOk, "migration-accepted")
      (_, final) <- readIORef (retainedState fixture)
      activeAuthorityEpoch final `shouldSatisfy` either (const True) (const False)
      authorityAggregateAuthenticationEpoch final `shouldBe` authorityEpochGenesis

    it "refuses absence observation before retirement or after epoch publication" $ do
      forM_ [(prepared, authorityEpochGenesis), (frozen, epoch2), (opened, epoch2)] $ \(aggregate, actual) -> do
        fixture <- newFixture aggregate (Right actual)
        serve fixture (ObservePreparedEpochBindingAbsent RetainedAuthenticationEpochBinding)
          `shouldReturn` Just (ReplyConflict, "epoch-binding-readback/wrong-phase")
        readIORef (casWrites fixture) `shouldReturn` 0

    it "delegates only requests outside the physical-readback operation set" $ do
      fixture <- newFixture prepared (Right authorityEpochGenesis)
      forM_
        [CommitFrozenEpoch, OpenEpochAdmission, BeginPreparedEpochRollback, FinishPreparedEpochRollback]
        $ \action ->
          serve fixture action `shouldReturn` Nothing
      serveEpochBindingReadbackRequest
        4096
        (fixtureBackend fixture)
        (fixtureRepository fixture)
        "not-cbor"
        `shouldReturn` Nothing
      readIORef (physicalReads fixture) `shouldReturn` 0
      readIORef (casWrites fixture) `shouldReturn` 0

    it "keeps public metadata target-bound and refuses a zero target" $ do
      authenticationEpochBindingDigest 0 `shouldBe` Nothing
      authenticationEpochBindingDigest 1 `shouldNotBe` authenticationEpochBindingDigest 2

data Fixture = Fixture
  { retainedState :: IORef (Word, AuthorityAdmissionAggregate)
  , physicalEpoch :: IORef (Either Text AuthorityEpoch)
  , physicalReads :: IORef Int
  , casWrites :: IORef Int
  }

newFixture :: AuthorityAdmissionAggregate -> Either Text AuthorityEpoch -> IO Fixture
newFixture aggregate actual = Fixture <$> newIORef (1, aggregate) <*> newIORef actual <*> newIORef 0 <*> newIORef 0

fixtureBackend :: Fixture -> EpochAuthenticationBackend IO
fixtureBackend fixture = EpochAuthenticationBackend $ do
  modifyIORef' (physicalReads fixture) (+ 1)
  readIORef (physicalEpoch fixture)

fixtureRepository :: Fixture -> AuthorityAdmissionRepository IO Word
fixtureRepository fixture =
  AuthorityAdmissionRepository
    { readAuthorityAdmission = do
        (revision, aggregate) <- readIORef (retainedState fixture)
        pure (Right (AuthorityAdmissionSnapshot revision aggregate))
    , compareAndSwapAuthorityAdmission = \expected next -> do
        modifyIORef' (casWrites fixture) (+ 1)
        (revision, _) <- readIORef (retainedState fixture)
        if revision /= expected
          then pure (Left "CAS conflict")
          else writeIORef (retainedState fixture) (revision + 1, next) >> pure (Right ())
    }

serve :: Fixture -> EpochPromotionAction -> IO (Maybe (ReplyStatus, ByteString))
serve fixture = serveWith fixture (fixtureBackend fixture)

serveWith
  :: Fixture
  -> EpochAuthenticationBackend IO
  -> EpochPromotionAction
  -> IO (Maybe (ReplyStatus, ByteString))
serveWith fixture backend = serveEpochBindingReadbackRequest 4096 backend (fixtureRepository fixture) . body

body :: EpochPromotionAction -> ByteString
body action =
  LazyByteString.toStrict
    (encodeMigrationCommand (ApplyPreparedEpochPromotion (EpochPromotionRequest 2 topologyDigest action)))

topology :: EpochTopology
topology = either (error . show) id (mkEpochTopology substrates Set.empty Set.empty rows)
 where
  substrates = Set.fromList [CutoverHome, CutoverAws]
  ordinary = fromJust (mkCutoverDigest (Text.replicate 64 "e"))
  rows =
    Map.insert
      RetainedAuthenticationEpochBinding
      (fromJust (authenticationEpochBindingDigest 2))
      (Map.fromSet (const ordinary) (requiredEpochTopologyBindings substrates Set.empty Set.empty))

topologyDigest :: CutoverDigest
topologyDigest = epochTopologyDigest topology

authenticationReadback :: EpochBindingReadback
authenticationReadback = readback RetainedAuthenticationEpochBinding

readback :: EpochTopologyBinding -> EpochBindingReadback
readback binding = EpochBindingReadback binding (fromJust (epochTopologyBindingDigest topology binding))

apply :: AuthorityAdmissionAggregate -> EpochPromotionAction -> AuthorityAdmissionAggregate
apply aggregate action =
  applyEpochAggregateCommand
    aggregate
    ( ApplyAuthorityMigration
        (ApplyPreparedEpochPromotion (EpochPromotionRequest 2 topologyDigest action))
    )

prepared :: AuthorityAdmissionAggregate
prepared =
  applyEpochAggregateCommand
    importedFrozenEpochAggregate
    ( ApplyAuthorityMigration
        (PrepareReplacementEpoch (epochFixtureEpoch 1) (epochFixtureEpoch 2) topology)
    )

frozen :: AuthorityAdmissionAggregate
frozen =
  foldl
    apply
    prepared
    ( [ ObservePreparedEpochBinding (readback binding)
      | binding <- Set.toList (epochTopologyBindings topology)
      ]
        ++ [ ObserveOldEpochRejected (readback binding) 1
           | binding <- Set.toList (epochTopologyOldWriterBindings topology)
           ]
        ++ [CommitFrozenEpoch]
    )

opened :: AuthorityAdmissionAggregate
opened =
  foldl
    apply
    frozen
    ( [ ObservePromotedEpochBinding (readback binding)
      | binding <- Set.toList (epochTopologyBindings topology)
      ]
        ++ [ ObserveOldEpochRejected (readback binding) 1
           | binding <- Set.toList (epochTopologyOldWriterBindings topology)
           ]
        ++ [OpenEpochAdmission]
    )

epoch2 :: AuthorityEpoch
epoch2 = fromJust (authorityEpochFromValue 2)

epoch3 :: AuthorityEpoch
epoch3 = fromJust (authorityEpochFromValue 3)
