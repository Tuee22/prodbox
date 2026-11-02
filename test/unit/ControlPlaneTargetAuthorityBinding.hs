{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneTargetAuthorityBinding (controlPlaneTargetAuthorityBindingSuite) where

import Control.Exception (AsyncException (UserInterrupt), throwIO, try)
import Control.Monad (forM_, void, when)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.Either (isLeft)
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Set qualified as Set
import Data.Text qualified as Text
import EpochPromotionFixture
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedTransport qualified as Transport
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
import Prodbox.ControlPlane.Client qualified as Client
import Prodbox.ControlPlane.Coordinate qualified as Coordinate
import Prodbox.ControlPlane.EpochBindingReadback
import Prodbox.ControlPlane.RequestAuthentication qualified as Authentication
import Prodbox.ControlPlane.Route
import Prodbox.ControlPlane.TargetAuthorityEpoch
import Prodbox.ControlPlane.TargetAuthorityEpochBinding
import Prodbox.ControlPlane.TargetMaterialRegistry
import Prodbox.ControlPlane.TargetSecretAgentExecution
import Prodbox.Http.ReplyStatus (ReplyStatus (ReplyConflict, ReplyOk))
import Prodbox.Lifecycle.Authority.Admission
import Prodbox.Lifecycle.Authority.EpochPromotion
import Prodbox.Lifecycle.Authority.EpochTopology
import Prodbox.Lifecycle.Authority.Genesis qualified as Genesis
import Prodbox.Lifecycle.Authority.Migration
import Prodbox.Lifecycle.Lease
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime, TargetSecretAgentRuntime))
import TestSupport

controlPlaneTargetAuthorityBindingSuite :: SuiteBuilder ()
controlPlaneTargetAuthorityBindingSuite = describe "Sprint 6.5 complete physical Target bindings" $ do
  it "shares exactly nine unique worker authorization coordinates" $ do
    Set.fromList targetWorkerAuthorizationIds
      `shouldBe` Set.fromList
        [ TargetSesSmtp
        , TargetAcmeEab
        , TargetPublicEdgeTls
        , TargetFederationCustody
        , TargetAwsCredential AwsLifecycleProvider
        , TargetAwsCredential AwsAuthorityBackupStore
        , TargetAwsCredential AwsTlsRetentionStore
        , TargetAwsCredential AwsGatewayDns
        , TargetAwsCredential AwsHomeCertManagerDns01
        ]
    length targetWorkerAuthorizationIds `shouldBe` 9
    length targetWorkerTargetIds `shouldBe` 7

  forM_ [CutoverHome, CutoverAws] $ \substrate ->
    it ("observes every exact Target twice for " ++ show substrate) $ do
      fixture <- newFixture preparedAggregate RowsPrepared
      query fixture substrate ReadPreparedTargetBinding `shouldReturn` Right (bindingDigest substrate)
      trace <- readIORef (targetReads fixture)
      map (\(_, target, _) -> target) trace
        `shouldBe` (targetWorkerAuthorizationIds <> targetWorkerAuthorizationIds)
      map (\(selected, _, _) -> selected) trace `shouldSatisfy` all (== substrate)
      map (\(_, _, deadline) -> deadline) (drop 1 trace) `shouldSatisfy` all (== preparationDeadline)

  it "makes the binding digest independent of order and enclosing topology, but binds its deadline" $ do
    let original = preparations CutoverHome (digest 'a') preparationDeadline
        changedTopology = preparations CutoverHome (digest 'b') preparationDeadline
        changedDeadline = preparations CutoverHome (digest 'a') requestDeadline
    targetEpochBindingDigest CutoverHome original
      `shouldBe` targetEpochBindingDigest CutoverHome (reverse original)
    targetEpochBindingDigest CutoverHome original
      `shouldBe` targetEpochBindingDigest CutoverHome changedTopology
    targetEpochBindingDigest CutoverHome original
      `shouldNotBe` targetEpochBindingDigest CutoverHome changedDeadline
    targetEpochBindingDigest CutoverHome original
      `shouldNotBe` targetEpochBindingDigest CutoverAws original

  it "refuses an incomplete or duplicated digest inventory" $ do
    let values = preparations CutoverHome (digest 'a') preparationDeadline
    targetEpochBindingDigest CutoverHome (drop 1 values) `shouldBe` Left TargetBindingInventoryMismatch
    targetEpochBindingDigest CutoverHome (values <> values)
      `shouldBe` Left TargetBindingInventoryMismatch

  forM_ targetWorkerAuthorizationIds $ \target ->
    it ("does not round missing " ++ show target ++ " up to a complete binding") $ do
      fixture <- newFixture preparedAggregate RowsPrepared
      modifyIORef' (rows fixture) (Map.delete (CutoverHome, target))
      query fixture CutoverHome ReadPreparedTargetBinding
        `shouldReturn` Left (TargetBindingRowMissing target)

  it "distinguishes an unavailable row from absence" $ do
    fixture <- newFixture preparedAggregate RowsPrepared
    writeIORef (readFailure fixture) (Just (TargetBindingRowUnavailable TargetAcmeEab))
    query fixture CutoverHome ReadPreparedTargetBinding
      `shouldReturn` Left (TargetBindingRowUnavailable TargetAcmeEab)

  it "refuses an unregistered AWS Agent instead of querying home" $ do
    fixture <- newFixture preparedAggregate RowsPrepared
    modifyIORef' (agents fixture) (Map.delete CutoverAws)
    query fixture CutoverAws ReadPreparedTargetBinding
      `shouldReturn` Left TargetBindingAgentUnregistered
    readIORef (targetReads fixture) `shouldReturn` []

  it "refuses rows from a different registered Agent rollout" $ do
    fixture <- newFixture preparedAggregate RowsPrepared
    let foreignAgent = mustRight (mkTargetAgentRolloutIdentity "home" ("sha256:" <> Text.replicate 64 "f"))
    modifyIORef' (agents fixture) (Map.insert CutoverHome foreignAgent)
    query fixture CutoverHome ReadPreparedTargetBinding `shouldReturn` Left TargetBindingAgentMismatch

  it "refuses zero KV versions" $ do
    fixture <- newFixture preparedAggregate RowsPrepared
    modifyIORef' (rows fixture) (Map.adjust (\(_, record) -> (0, record)) (CutoverHome, TargetAcmeEab))
    query fixture CutoverHome ReadPreparedTargetBinding
      `shouldReturn` Left TargetBindingRowVersionInvalid

  it "refuses a different immutable context within the bundle" $ do
    fixture <- newFixture preparedAggregate RowsPrepared
    let altered = recordAt RowsPrepared CutoverHome TargetAcmeEab (digest 'f') preparationDeadline
    modifyIORef' (rows fixture) (Map.insert (CutoverHome, TargetAcmeEab) (2, altered))
    query fixture CutoverHome ReadPreparedTargetBinding `shouldReturn` Left TargetBindingContextMismatch

  it "detects a row version change between complete snapshots" $ do
    fixture <- newFixture preparedAggregate RowsPrepared
    writeIORef (readHook fixture) $ \count ->
      when (count == 10) $
        modifyIORef'
          (rows fixture)
          (Map.adjust (\(version, record) -> (version + 1, record)) (CutoverHome, TargetSesSmtp))
    query fixture CutoverHome ReadPreparedTargetBinding
      `shouldReturn` Left TargetBindingObservationChanged

  it "refuses a changed epoch or issuer at the closing barrier" $ do
    forM_ [False, True] $ \changeIssuer -> do
      fixture <- newFixture preparedAggregate RowsPrepared
      writeIORef (readHook fixture) $ \count ->
        when (count == 18) $
          if changeIssuer
            then writeIORef (issuer fixture) (Right (mustRight (mkTargetIssuerKeyGeneration 2), publicKey))
            else writeIORef (published fixture) (Right (Coordinate.AuthorityEpoch 2))
      query fixture CutoverHome ReadPreparedTargetBinding
        `shouldReturn` Left TargetBindingObservationChanged

  it "refuses a row bundle whose issuer differs from independent public-key observation" $ do
    fixture <- newFixture preparedAggregate RowsPrepared
    writeIORef (issuer fixture) (Right (mustRight (mkTargetIssuerKeyGeneration 2), publicKey))
    query fixture CutoverHome ReadPreparedTargetBinding `shouldReturn` Left TargetBindingIssuerMismatch

  it "does not renew expired preparation or parent deadlines" $ do
    fixture <- newFixture preparedAggregate RowsPrepared
    writeIORef (clock fixture) preparationDeadline
    query fixture CutoverHome ReadPreparedTargetBinding `shouldReturn` Left TargetBindingDeadlineReached
    writeIORef (clock fixture) requestDeadline
    query fixture CutoverHome ReadPreparedTargetBinding `shouldReturn` Left TargetBindingDeadlineReached

  it "does not record a bundle that expires while being read" $ do
    fixture <- newFixture preparedAggregate RowsPrepared
    writeIORef (readHook fixture) $ \count -> when (count == 18) (writeIORef (clock fixture) preparationDeadline)
    query fixture CutoverHome ReadPreparedTargetBinding `shouldReturn` Left TargetBindingDeadlineReached

  it "permits partial promotion only after the public epoch is committed" $ do
    fixture <- newFixture frozenAggregate RowsPrepared
    let promoted = recordAt RowsPromoted CutoverHome TargetAcmeEab topologyDigest preparationDeadline
    modifyIORef' (rows fixture) (Map.insert (CutoverHome, TargetAcmeEab) (2, promoted))
    query fixture CutoverHome ReadPreparedTargetBinding `shouldReturn` Right (bindingDigest CutoverHome)
    query fixture CutoverHome ReadPromotedTargetBinding `shouldReturn` Left TargetBindingPhaseMismatch

  it "reads complete promotion and old-writer rejection without opening normal admission" $ do
    fixture <- newFixture frozenAggregate RowsPromoted
    query fixture CutoverHome ReadPromotedTargetBinding `shouldReturn` Right (bindingDigest CutoverHome)
    query fixture CutoverHome (ReadRejectedTargetWriter 1)
      `shouldReturn` Right (bindingDigest CutoverHome)
    query fixture CutoverHome (ReadRejectedTargetWriter 2)
      `shouldReturn` Left TargetBindingContextMismatch
    activeAuthorityEpoch frozenAggregate `shouldSatisfy` isLeft

  it "requires promoted rows once aggregate admission is open" $ do
    fixture <- newFixture openedAggregate RowsPrepared
    query fixture CutoverHome ReadPreparedTargetBinding `shouldReturn` Left TargetBindingPhaseMismatch

  it "can observe historical promotion after its preparation deadline without renewing a request" $ do
    fixture <- newFixture openedAggregate RowsPromoted
    writeIORef (clock fixture) (authorityTimeFromMicros 1500000)
    query fixture CutoverHome ReadPromotedTargetBinding `shouldReturn` Right (bindingDigest CutoverHome)

  it "requires exact retired fences for every Target after expiry or issuer rotation" $ do
    fixture <- newFixture rollbackAggregate RowsRetired
    writeIORef (clock fixture) (authorityTimeFromMicros 1500000)
    writeIORef (issuer fixture) (Left TargetBindingIssuerUnavailable)
    query fixture CutoverHome ReadRetiredTargetBinding `shouldReturn` Right ()
    modifyIORef' (rows fixture) (Map.delete (CutoverHome, TargetAcmeEab))
    query fixture CutoverHome ReadRetiredTargetBinding
      `shouldReturn` Left (TargetBindingRowMissing TargetAcmeEab)

  it "does not confuse preparation, promotion and retirement observations" $ do
    fixture <- newFixture preparedAggregate RowsPrepared
    query fixture CutoverHome ReadPromotedTargetBinding `shouldReturn` Left TargetBindingPhaseMismatch
    query fixture CutoverHome ReadRetiredTargetBinding `shouldReturn` Left TargetBindingPhaseMismatch

  describe "verified aggregate readback" verifiedReadbackSuite
  describe "registered Agent selection" agentRegistrySuite

verifiedReadbackSuite :: SuiteBuilder ()
verifiedReadbackSuite = do
  it "records the independently read Target digest at the observed aggregate revision" $ do
    fixture <- newFixture preparedAggregate RowsPrepared
    serve fixture preparedAction `shouldReturn` Just (ReplyOk, "migration-accepted")
    readIORef (writes fixture) `shouldReturn` 1
    (_, aggregate) <- readIORef (retained fixture)
    aggregate `shouldBe` apply preparedAggregate preparedAction
    authorityAggregateAuthenticationEpoch aggregate `shouldBe` Genesis.authorityEpochGenesis

  it "settles a lost aggregate CAS reply through exact closing observation" $ do
    fixture <- newFixture preparedAggregate RowsPrepared
    writeIORef (loseCasReply fixture) True
    serve fixture preparedAction `shouldReturn` Just (ReplyOk, "migration-accepted")
    readIORef (writes fixture) `shouldReturn` 1

  it "does not accept caller-provided metadata in place of the physical digest" $ do
    fixture <- newFixture preparedAggregate RowsPrepared
    let action =
          ObservePreparedEpochBinding
            (EpochBindingReadback (PendingAcceptedAuthorityBinding CutoverHome) (digest 'f'))
    serve fixture action
      `shouldReturn` Just (ReplyConflict, "epoch-binding-readback/binding-digest-mismatch")
    readIORef (writes fixture) `shouldReturn` 0

  it "refuses a phase race instead of recording an earlier observation in a newer aggregate" $ do
    fixture <- newFixture preparedAggregate RowsPrepared
    writeIORef (readHook fixture) $ \count -> when (count == 18) (writeIORef (retained fixture) (2, frozenAggregate))
    serve fixture preparedAction
      `shouldReturn` Just (ReplyConflict, "epoch-binding-readback/concurrent-state")
    readIORef (writes fixture) `shouldReturn` 0

  it "carries the narrower preparation deadline through CAS and closing observation" $ do
    fixture <- newFixture preparedAggregate RowsPrepared
    writeIORef (afterCas fixture) (writeIORef (clock fixture) preparationDeadline)
    serve fixture preparedAction
      `shouldReturn` Just (ReplyConflict, "epoch-binding-readback/request-deadline-reached")
    readIORef (writes fixture) `shouldReturn` 1

  it "still independently observes an already recorded binding" $ do
    fixture <- newFixture (apply preparedAggregate preparedAction) RowsPrepared
    serve fixture preparedAction `shouldReturn` Just (ReplyOk, "migration-already-applied")
    modifyIORef' (rows fixture) (Map.delete (CutoverHome, TargetAcmeEab))
    serve fixture preparedAction
      `shouldReturn` Just (ReplyConflict, "epoch-binding-readback/target/row-missing/acme-eab")
    readIORef (writes fixture) `shouldReturn` 0

  it "rejects a foreign verified scope before reading Target rows" $ do
    fixture <- newFixture preparedAggregate RowsPrepared
    let request = verifiedFor "foreign" Genesis.authorityEpochGenesis preparedAction
    verifiedHandler fixture request
      `shouldReturn` Just (ReplyConflict, "epoch-binding-readback/request-context-invalid")
    readIORef (targetReads fixture) `shouldReturn` []

  it "matches the verified header epoch to the retained aggregate before physical reads" $ do
    fixture <- newFixture preparedAggregate RowsPrepared
    let request = verifiedFor "home" (fromJust (Genesis.authorityEpochFromValue 2)) preparedAction
    verifiedHandler fixture request
      `shouldReturn` Just (ReplyConflict, "epoch-binding-readback/request-context-invalid")
    readIORef (targetReads fixture) `shouldReturn` []

  it "preserves asynchronous cancellation during physical observation" $ do
    fixture <- newFixture preparedAggregate RowsPrepared
    writeIORef (readHook fixture) (const (throwIO UserInterrupt))
    result <- try (serve fixture preparedAction)
    (result :: Either AsyncException (Maybe (ReplyStatus, BS.ByteString))) `shouldBe` Left UserInterrupt
    readIORef (writes fixture) `shouldReturn` 0

  it "requires a fresh nonce policy for all physical readback forms, preserving transition replay" $ do
    forM_
      [ preparedAction
      , ObservePromotedEpochBinding homeReadback
      , ObserveOldEpochRejected homeReadback 1
      , ObservePreparedEpochBindingAbsent (PendingAcceptedAuthorityBinding CutoverHome)
      ]
      $ \action ->
        isPhysicalEpochReadbackForRole
          65536
          LifecycleAuthorityRuntime
          LifecycleMigrationApply
          (commandBytes action)
          `shouldBe` True
    isPhysicalEpochReadbackForRole
      65536
      LifecycleAuthorityRuntime
      LifecycleMigrationApply
      (commandBytes CommitFrozenEpoch)
      `shouldBe` False
    isPhysicalEpochReadbackForRole
      65536
      TargetSecretAgentRuntime
      LifecycleMigrationApply
      (commandBytes preparedAction)
      `shouldBe` False

agentRegistrySuite :: SuiteBuilder ()
agentRegistrySuite = do
  it "requires a home registration and rejects duplicate substrates or aliased clusters" $ do
    void (mkTargetEpochAgentRegistry [(CutoverAws, agentAt CutoverAws, dummyTransport)])
      `shouldBe` Left TargetEpochRegistryHomeMissing
    void
      ( mkTargetEpochAgentRegistry
          [ (CutoverHome, agentAt CutoverHome, dummyTransport)
          , (CutoverHome, agentAt CutoverAws, dummyTransport)
          ]
      )
      `shouldBe` Left TargetEpochRegistryDuplicateSubstrate
    void
      ( mkTargetEpochAgentRegistry
          [ (CutoverHome, agentAt CutoverHome, dummyTransport)
          , (CutoverAws, agentAt CutoverHome, dummyTransport)
          ]
      )
      `shouldBe` Left TargetEpochRegistryAliasedCluster
    void
      ( mkTargetEpochAgentRegistry
          [ (CutoverHome, agentAt CutoverHome, dummyTransport)
          , (CutoverAws, agentAt CutoverAws, dummyTransport)
          ]
      )
      `shouldBe` Right ()

  forM_ [(500000, 1000000), (2000000, 1000000)] $ \(original, cap) ->
    it "signs the earlier provider/parent deadline into both authenticated frame projections" $ do
      captured <- newIORef Nothing
      let providers = clientProviders (authorityTimeFromMicros original)
          raw = mustRight $ Client.controlPlaneClientWithTransport 16384 endpoint $ \_ _ _ frame -> do
            writeIORef captured (Just frame)
            pure (Right (200, "observed"))
          transport =
            Transport.authenticatedClientTransportWithin
              (authorityTimeFromMicros cap)
              (Transport.mkAuthenticatedClientTransport bounds providers raw)
      _ <-
        Transport.callAuthenticatedClientTransport transport Client.TargetSecretTrustInstallRoute "probe"
      frame <- readIORef captured
      encoded <- case frame of
        Just bytes -> pure bytes
        Nothing -> expectationFailure "missing authenticated frame" >> pure BS.empty
      authenticated <-
        Transport.authenticateControlPlaneFrame
          bounds
          lifetime
          serverProviders
          TargetSecretAgentRuntime
          TargetSecretTrustInstall
          (Lazy.fromStrict encoded)
      Authentication.verifiedRequestDeadline
        (Transport.authenticatedServerVerifiedRequest (mustRight authenticated))
        `shouldBe` authorityTimeFromMicros (min original cap)

dummyTransport :: Transport.AuthenticatedClientTransport 'TargetSecretAgentRuntime
dummyTransport =
  Transport.mkAuthenticatedClientTransport
    bounds
    (clientProviders requestDeadline)
    ( mustRight
        (Client.controlPlaneClientWithTransport 16384 endpoint (\_ _ _ _ -> pure (Right (503, "unused"))))
    )

endpoint :: Client.ControlPlaneEndpoint 'TargetSecretAgentRuntime
endpoint = mustRight (Client.mkTargetSecretAgentEndpoint "http://target-agent.test")

bounds :: Transport.AuthenticatedTransportBounds
bounds = mustRight (Transport.mkAuthenticatedTransportBounds 65536 1024 64512)

lifetime :: AuthorityDuration
lifetime = mustRight (authorityDurationFromMicros 3000000)

signer :: Authentication.RequestSigner
signer =
  mustRight
    ( Authentication.mkRequestSigner
        Authentication.CallerTestHarness
        (mustRight (Authentication.mkSigningKeyGeneration 1))
        (BS.pack [0 .. 31])
    )

targetSigner :: Authentication.RequestSigner
targetSigner =
  mustRight
    ( Authentication.mkRequestSigner
        (Authentication.CallerService LifecycleAuthorityRuntime)
        (mustRight (Authentication.mkSigningKeyGeneration 1))
        (BS.pack [0 .. 31])
    )

clientProviders :: AuthorityTime -> Transport.AuthenticatedClientProviders IO
clientProviders deadline =
  Transport.AuthenticatedClientProviders
    { Transport.provideAuthenticatedClientSigner =
        pure (Right (Authentication.localRequestSigningCapability targetSigner))
    , Transport.provideAuthenticatedClientScope = pure (Right scope)
    , Transport.provideAuthenticatedClientEpoch = pure (Right Genesis.authorityEpochGenesis)
    , Transport.provideAuthenticatedClientDeadline = pure (Right deadline)
    , Transport.provideAuthenticatedClientNonce = pure (Right nonce)
    }

serverProviders :: Transport.AuthenticatedServerProviders IO
serverProviders =
  Transport.AuthenticatedServerProviders
    { Transport.provideAuthenticatedServerScope = pure (Right scope)
    , Transport.provideAuthenticatedServerEpoch = pure (Right Genesis.authorityEpochGenesis)
    , Transport.provideAuthenticatedServerTime = pure (Right now)
    , Transport.provideAuthenticatedServerTrustRegistry =
        pure
          ( Right
              ( mustRight
                  ( Transport.mkRouteTrustRegistry
                      TargetSecretAgentRuntime
                      1
                      [ (route, Authentication.trustedRequestKeyFromSigner targetSigner)
                      | route <- routesForRole TargetSecretAgentRuntime
                      ]
                  )
              )
          )
    }

scope :: Coordinate.AuthorityScope
scope = mustRight (Coordinate.mkAuthorityScope "home")

nonce :: Authentication.RequestNonce
nonce = mustRight (Authentication.mkRequestNonce (BS.replicate 16 1))

homeReadback :: EpochBindingReadback
homeReadback = readback (PendingAcceptedAuthorityBinding CutoverHome)

preparedAction :: EpochPromotionAction
preparedAction = ObservePreparedEpochBinding homeReadback

commandBytes :: EpochPromotionAction -> BS.ByteString
commandBytes action =
  Lazy.toStrict
    (encodeMigrationCommand (ApplyPreparedEpochPromotion (EpochPromotionRequest 2 topologyDigest action)))

verifiedFor
  :: Text.Text
  -> Genesis.AuthorityEpoch
  -> EpochPromotionAction
  -> Authentication.VerifiedControlPlaneRequest
verifiedFor selectedScope epoch action =
  mustRight
    ( Authentication.decodeAndVerifyControlPlaneRequest
        65536
        context
        (Authentication.encodeSignedControlPlaneRequest signed)
    )
 where
  requestScope = mustRight (Coordinate.mkAuthorityScope selectedScope)
  signed =
    mustRight
      ( Authentication.signControlPlaneRequest
          signer
          LifecycleMigrationApply
          LifecycleAuthorityRuntime
          requestScope
          epoch
          requestDeadline
          nonce
          (commandBytes action)
      )
  context =
    mustRight
      ( Authentication.mkRequestVerificationContext
          (Authentication.trustedRequestKeyFromSigner signer)
          LifecycleMigrationApply
          LifecycleAuthorityRuntime
          requestScope
          epoch
          requestDeadline
          nonce
          now
          lifetime
      )

serve :: Fixture -> EpochPromotionAction -> IO (Maybe (ReplyStatus, BS.ByteString))
serve fixture action = do
  (_, aggregate) <- readIORef (retained fixture)
  verifiedHandler
    fixture
    (verifiedFor "home" (authorityAggregateAuthenticationEpoch aggregate) action)

verifiedHandler
  :: Fixture -> Authentication.VerifiedControlPlaneRequest -> IO (Maybe (ReplyStatus, BS.ByteString))
verifiedHandler fixture =
  epochBindingReadbackVerifiedHandler
    65536
    scope
    (Right <$> readIORef (clock fixture))
    (EpochAuthenticationBackend (pure (Right Genesis.authorityEpochGenesis)))
    (interpreter fixture)
    (repository fixture)

repository :: Fixture -> AuthorityAdmissionRepository IO Int
repository fixture =
  AuthorityAdmissionRepository
    { readAuthorityAdmission = do
        (version, aggregate) <- readIORef (retained fixture)
        pure (Right (AuthorityAdmissionSnapshot version aggregate))
    , compareAndSwapAuthorityAdmission = \expected aggregate -> do
        observed <- readIORef (retained fixture)
        if fst observed /= expected
          then pure (Left "fixture aggregate changed")
          else do
            modifyIORef' (writes fixture) (+ 1)
            writeIORef (retained fixture) (expected + 1, aggregate)
            action <- readIORef (afterCas fixture)
            action
            lost <- readIORef (loseCasReply fixture)
            pure (if lost then Left "fixture CAS reply lost" else Right ())
    }

data RowMode = RowsPrepared | RowsPromoted | RowsRetired

data Fixture = Fixture
  { rows :: IORef (Map.Map (CutoverSubstrate, TargetSecretId) (Natural, TargetAuthorityEpochRecord))
  , agents :: IORef (Map.Map CutoverSubstrate TargetAgentIdentity)
  , clock :: IORef AuthorityTime
  , published :: IORef (Either TargetEpochBindingFailure Coordinate.AuthorityEpoch)
  , issuer
      :: IORef (Either TargetEpochBindingFailure (TargetIssuerKeyGeneration, TargetIntentPublicKey))
  , targetReads :: IORef [(CutoverSubstrate, TargetSecretId, AuthorityTime)]
  , readHook :: IORef (Int -> IO ())
  , readFailure :: IORef (Maybe TargetEpochBindingFailure)
  , retained :: IORef (Int, AuthorityAdmissionAggregate)
  , writes :: IORef Int
  , loseCasReply :: IORef Bool
  , afterCas :: IORef (IO ())
  , interpreter :: TargetEpochBindingInterpreter IO
  }

newFixture :: AuthorityAdmissionAggregate -> RowMode -> IO Fixture
newFixture aggregate mode = do
  targetRows <-
    newIORef
      ( Map.fromList
          [ ((substrate, target), (1, recordAt mode substrate target topologyDigest preparationDeadline))
          | substrate <- [CutoverHome, CutoverAws]
          , target <- targetWorkerAuthorizationIds
          ]
      )
  selectedAgents <-
    newIORef (Map.fromList [(substrate, agentAt substrate) | substrate <- [CutoverHome, CutoverAws]])
  time <- newIORef now
  epoch <-
    newIORef
      ( Right
          ( Coordinate.AuthorityEpoch
              (Genesis.authorityEpochValue (authorityAggregateAuthenticationEpoch aggregate))
          )
      )
  currentIssuer <- newIORef (Right (mustRight (mkTargetIssuerKeyGeneration 1), publicKey))
  trace <- newIORef []
  hook <- newIORef (const (pure ()))
  unavailable <- newIORef Nothing
  aggregateState <- newIORef (1, aggregate)
  casCount <- newIORef 0
  lost <- newIORef False
  casHook <- newIORef (pure ())
  let interpret :: TargetEpochBindingEffect value -> IO (Either TargetEpochBindingFailure value)
      interpret effect = case effect of
        ReadTargetBindingTime -> Right <$> readIORef time
        ReadTargetBindingEpoch _ -> readIORef epoch
        ReadTargetBindingIssuer _ -> readIORef currentIssuer
        ReadTargetBindingAgent substrate ->
          maybe (Left TargetBindingAgentUnregistered) Right . Map.lookup substrate
            <$> readIORef selectedAgents
        ReadTargetBindingRow deadline substrate target -> do
          modifyIORef' trace (<> [(substrate, target, deadline)])
          count <- length <$> readIORef trace
          action <- readIORef hook
          action count
          failure <- readIORef unavailable
          case failure of
            Just cause -> pure (Left cause)
            Nothing -> Right . Map.lookup (substrate, target) <$> readIORef targetRows
  pure
    ( Fixture
        targetRows
        selectedAgents
        time
        epoch
        currentIssuer
        trace
        hook
        unavailable
        aggregateState
        casCount
        lost
        casHook
        (TargetEpochBindingInterpreter interpret)
    )

query
  :: Fixture
  -> CutoverSubstrate
  -> TargetEpochBindingQuery result
  -> IO (Either TargetEpochBindingFailure result)
query fixture substrate operation = do
  (_, aggregate) <- readIORef (retained fixture)
  runTargetEpochBindingQuery
    requestDeadline
    (interpreter fixture)
    (promotionOf aggregate)
    substrate
    operation

promotionOf :: AuthorityAdmissionAggregate -> EpochPromotionState
promotionOf aggregate = case authorityAggregateMigration aggregate of
  AuthorityMigrationControlled value -> fromJust (migrationEpochPromotion value)
  AuthorityCleanInstall -> error "fixture requires migration"

preparations
  :: CutoverSubstrate -> CutoverDigest -> AuthorityTime -> [TargetAuthorityEpochPreparation]
preparations substrate wholeTopology deadline = [preparationAt substrate target wholeTopology deadline | target <- targetWorkerAuthorizationIds]

preparationAt
  :: CutoverSubstrate
  -> TargetSecretId
  -> CutoverDigest
  -> AuthorityTime
  -> TargetAuthorityEpochPreparation
preparationAt substrate target wholeTopology deadline =
  mustRight
    ( mkTargetAuthorityEpochPreparation
        (mustRight (mkTargetAuthorityEpochContext 1 2 wholeTopology deadline))
        (authorityAt substrate target 2)
    )

recordAt
  :: RowMode
  -> CutoverSubstrate
  -> TargetSecretId
  -> CutoverDigest
  -> AuthorityTime
  -> TargetAuthorityEpochRecord
recordAt mode substrate target wholeTopology deadline = case mode of
  RowsPrepared -> prepared
  RowsPromoted ->
    mustRight
      ( stepTargetAuthorityEpoch
          (Coordinate.AuthorityEpoch 2)
          now
          (PromoteTargetAuthorityEpoch preparation)
          prepared
      )
  RowsRetired ->
    mustRight
      ( stepTargetAuthorityEpoch
          (Coordinate.AuthorityEpoch 1)
          now
          (RetireTargetAuthorityEpoch preparation)
          prepared
      )
 where
  preparation = preparationAt substrate target wholeTopology deadline
  initial = mustRight (initialTargetAuthorityEpochRecord target (Just (authorityAt substrate target 1)))
  prepared =
    mustRight
      ( stepTargetAuthorityEpoch
          (Coordinate.AuthorityEpoch 1)
          now
          (PrepareTargetAuthorityEpoch preparation)
          initial
      )

authorityAt :: CutoverSubstrate -> TargetSecretId -> Natural -> AcceptedTargetAuthority
authorityAt substrate target epoch =
  mustRight
    ( mkAcceptedTargetAuthority
        (mustRight (mkTargetIssuerKeyGeneration 1))
        "lifecycle-authority"
        publicKey
        (Coordinate.AuthorityEpoch epoch)
        (mustRight (mkFencingToken 1))
        (agentAt substrate)
        (mustRight (compiledTargetSecretSink target))
    )

agentAt :: CutoverSubstrate -> TargetAgentIdentity
agentAt substrate = mustRight (mkTargetAgentRolloutIdentity cluster ("sha256:" <> Text.replicate 64 character))
 where
  (cluster, character) = case substrate of
    CutoverHome -> ("home", "a")
    CutoverAws -> ("aws", "b")

publicKey :: TargetIntentPublicKey
publicKey = targetIntentSigningPublicKey (mustRight (mkTargetIntentSigningKey (BS.pack [0 .. 31])))

bindingDigest :: CutoverSubstrate -> CutoverDigest
bindingDigest substrate =
  mustRight
    (targetEpochBindingDigest substrate (preparations substrate (digest '0') preparationDeadline))

topology :: EpochTopology
topology = mustRight (mkEpochTopology (Set.fromList [CutoverHome, CutoverAws]) scopes dns metadata)
 where
  scopes = Set.fromList [(CutoverHome, digest 'a'), (CutoverAws, digest 'b')]
  dns = Set.fromList [(CutoverHome, digest 'c'), (CutoverAws, digest 'd')]
  base =
    Map.fromSet
      (const (digest 'e'))
      (requiredEpochTopologyBindings (Set.fromList [CutoverHome, CutoverAws]) scopes dns)
  metadata =
    Map.insert
      RetainedAuthenticationEpochBinding
      (fromJust (authenticationEpochBindingDigest 2))
      ( foldr
          (\substrate -> Map.insert (PendingAcceptedAuthorityBinding substrate) (bindingDigest substrate))
          base
          [CutoverHome, CutoverAws]
      )

topologyDigest :: CutoverDigest
topologyDigest = epochTopologyDigest topology

preparedAggregate
  , frozenAggregate
  , openedAggregate
  , rollbackAggregate
    :: AuthorityAdmissionAggregate
preparedAggregate =
  applyEpochAggregateCommand
    importedFrozenEpochAggregate
    ( ApplyAuthorityMigration
        (PrepareReplacementEpoch (epochFixtureEpoch 1) (epochFixtureEpoch 2) topology)
    )
frozenAggregate =
  foldl
    apply
    preparedAggregate
    ( [ObservePreparedEpochBinding (readback binding) | binding <- bindings]
        <> [ ObserveOldEpochRejected (readback binding) 1
           | binding <- Set.toList (epochTopologyOldWriterBindings topology)
           ]
        <> [CommitFrozenEpoch]
    )
openedAggregate =
  foldl
    apply
    frozenAggregate
    ( [ObservePromotedEpochBinding (readback binding) | binding <- bindings]
        <> [ ObserveOldEpochRejected (readback binding) 1
           | binding <- Set.toList (epochTopologyOldWriterBindings topology)
           ]
        <> [OpenEpochAdmission]
    )
rollbackAggregate = apply preparedAggregate BeginPreparedEpochRollback

bindings :: [EpochTopologyBinding]
bindings = Set.toList (epochTopologyBindings topology)

readback :: EpochTopologyBinding -> EpochBindingReadback
readback binding = EpochBindingReadback binding (fromJust (epochTopologyBindingDigest topology binding))

apply :: AuthorityAdmissionAggregate -> EpochPromotionAction -> AuthorityAdmissionAggregate
apply aggregate action =
  applyEpochAggregateCommand
    aggregate
    ( ApplyAuthorityMigration
        (ApplyPreparedEpochPromotion (EpochPromotionRequest 2 topologyDigest action))
    )

now, preparationDeadline, requestDeadline :: AuthorityTime
now = authorityTimeFromMicros 100
preparationDeadline = authorityTimeFromMicros 1000000
requestDeadline = authorityTimeFromMicros 2000000

digest :: Char -> CutoverDigest
digest character = fromJust (mkCutoverDigest (Text.replicate 64 (Text.singleton character)))

mustRight :: (Show failure) => Either failure value -> value
mustRight = either (error . show) id
