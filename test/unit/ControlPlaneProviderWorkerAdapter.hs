{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneProviderWorkerAdapter (controlPlaneProviderWorkerAdapterSuite) where

import Data.Either (isLeft)
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.ProviderWorkerAdapter
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObjectCoordinate
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkClusterRetainedCoordinate
  , mkLongLivedCheckpointAuthority
  , mkModelBObjectVersion
  )
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
import TestSupport

controlPlaneProviderWorkerAdapterSuite :: SuiteBuilder ()
controlPlaneProviderWorkerAdapterSuite =
  describe "Sprint 4.50 Provider Worker compatibility adapter" $ do
    it "round-trips the bounded canonical retained envelope" $ do
      let codec = providerWorkStateCodec providerWorkMaximumEncodedBytes
          encoded = encodeModelBValue codec initialProviderWorkDurableState
      (encoded >>= decodeModelBValue codec) `shouldBe` Right initialProviderWorkDurableState
      decodeModelBValue codec "not-canonical-cbor" `shouldSatisfy` isLeft

    it "binds missing and observed state to an exact ClusterRetained Model-B CAS" $ do
      observationRef <- newIORef ModelBMissing
      requestsRef <- newIORef []
      let repository =
            modelBProviderWorkRetainedRepository
              (retainedAdapter observationRef requestsRef)
              retainedProviderWorkCoordinate
      initial <- readProviderWorkRetainedState repository
      fmap providerWorkRetainedState initial `shouldBe` Right initialProviderWorkDurableState
      compareAndSwapProviderWorkRetainedState repository Nothing initialProviderWorkDurableState
        `shouldReturn` Right ()
      requests <- reverse <$> readIORef requestsRef
      length requests `shouldBe` 1
      case requests of
        [ModelBInitialize _ state] -> state `shouldBe` initialProviderWorkDurableState
        _ -> expectationFailure "expected one exact Model-B initialize"

    it "dispatches every closed intent through its exact scoped capability and read-back" $ do
      fixture <- freshFixture
      mapM_ (runFresh fixture) allIntents
      calls <- reverse <$> readIORef (fixtureCalls fixture)
      calls `shouldBe` concatMap expectedCalls allIntents
      durable <- readDurable fixture
      providerWorkDurableState durable `shouldBe` ProviderIdle
      providerWorkDurableLastCompletion durable
        `shouldBe` Just
          ProviderWorkCompletion
            { providerWorkCompletedIntent = last allIntents
            , providerWorkCompletionEvidence = evidenceFor (last allIntents)
            }

    it "confirms an applied-but-response-lost effect on recovery without a second mutation" $ do
      fixture <- freshFixture
      let intent = ReconcileSesSendingIdentity (sesIdentityRef "mail")
          coordinate = providerIntentCoordinate intent
      writeIORef (fixtureLoseEffectResponse fixture) [coordinate]
      admit fixture intent `shouldReturn` Right ()
      first <- executeProviderIntent (fixtureAdapter fixture) intent
      first `shouldSatisfy` isLeft
      afterLoss <- readDurable fixture
      providerWorkDurableState afterLoss `shouldBe` ProviderRecovering coordinate
      resumed <- resumeProviderWorker (fixtureAdapter fixture)
      resumed
        `shouldBe` Right
          ( ProviderWorkerResumed
              ProviderWorkCompletion
                { providerWorkCompletedIntent = intent
                , providerWorkCompletionEvidence = evidenceFor intent
                }
          )
      calls <- reverse <$> readIORef (fixtureCalls fixture)
      length (filter (== ("apply:" <> labelFor intent, coordinate)) calls) `shouldBe` 1
      final <- readDurable fixture
      providerWorkDurableState final `shouldBe` ProviderIdle

    it "keeps an unobservable effect recovering and never mutates it" $ do
      fixture <- freshFixture
      let intent = ReconcileSesDkim (sesIdentityRef "mail")
          coordinate = providerIntentCoordinate intent
      writeIORef (fixtureUnobservable fixture) [coordinate]
      admit fixture intent `shouldReturn` Right ()
      executeProviderIntent (fixtureAdapter fixture) intent `shouldSatisfyReturn` isLeft
      resumed <- resumeProviderWorker (fixtureAdapter fixture)
      case resumed of
        Right (ProviderWorkerStillRecovering observedCoordinate _) ->
          observedCoordinate `shouldBe` coordinate
        other -> expectationFailure ("expected recovering result, got " <> show other)
      calls <- reverse <$> readIORef (fixtureCalls fixture)
      filter (== ("apply:" <> labelFor intent, coordinate)) calls `shouldBe` []

    it "refuses an expired session before acquisition or provider I/O and fences recovery" $ do
      fixture <- freshFixture
      let intent = BoundedScratchCheckpoint (checkpointRef "scratch")
          coordinate = providerIntentCoordinate intent
          expiredAdapter =
            (fixtureAdapter fixture)
              { providerWorkerAuthorityNow = pure (Right (authorityTimeFromMicros 5000))
              }
      admitWith expiredAdapter intent `shouldReturn` Right ()
      executeProviderIntent expiredAdapter intent `shouldSatisfyReturn` isLeft
      readIORef (fixtureCalls fixture) `shouldReturn` []
      durable <- readDurable fixture
      providerWorkDurableState durable `shouldBe` ProviderRecovering coordinate

    it "confirms lost retained CAS responses by exact read-back at admission and completion" $ do
      fixture <- freshFixture
      let intent = ReconcileSesCaptureBucket (sesBucketRef "capture")
      writeIORef (fixtureLoseCasResponse fixture) True
      admit fixture intent `shouldReturn` Right ()
      writeIORef (fixtureLoseCasResponse fixture) True
      executeProviderIntent (fixtureAdapter fixture) intent
        `shouldReturn` Right
          ProviderWorkCompletion
            { providerWorkCompletedIntent = intent
            , providerWorkCompletionEvidence = evidenceFor intent
            }
      durable <- readDurable fixture
      providerWorkDurableState durable `shouldBe` ProviderIdle

    it "refuses a stale competing admission without replacing the exact active intent" $ do
      fixture <- freshFixture
      let firstIntent = ReconcileSesSendingIdentity (sesIdentityRef "mail")
          competingIntent = ReconcileSesDkim (sesIdentityRef "mail")
      admit fixture firstIntent `shouldReturn` Right ()
      admit fixture competingIntent `shouldSatisfyReturn` isLeft
      durable <- readDurable fixture
      providerWorkDurableState durable
        `shouldBe` ProviderInFlight (providerIntentCoordinate firstIntent)
      providerWorkDurableActiveIntent durable `shouldBe` Just firstIntent

    it "requires both external readiness and an authoritative retained read" $ do
      fixture <- freshFixture
      providerWorkerAdapterReady (fixtureAdapter fixture) `shouldReturn` True
      let externallyDown = (fixtureAdapter fixture) {providerWorkerExternalReady = pure False}
      providerWorkerAdapterReady externallyDown `shouldReturn` False

data Fixture = Fixture
  { fixtureAdapter :: !(ProviderWorkerAdapter IO Text)
  , fixtureCalls :: !(IORef [(Text, ProviderIntentCoordinate)])
  , fixtureLoseEffectResponse :: !(IORef [ProviderIntentCoordinate])
  , fixtureUnobservable :: !(IORef [ProviderIntentCoordinate])
  , fixtureLoseCasResponse :: !(IORef Bool)
  }

freshFixture :: IO Fixture
freshFixture = do
  retainedStateRef <- newIORef (1, initialProviderWorkDurableState)
  loseCasResponse <- newIORef False
  calls <- newIORef []
  applied <- newIORef []
  loseEffectResponse <- newIORef []
  unobservable <- newIORef []
  let repository = inMemoryRetainedRepository retainedStateRef loseCasResponse
      capabilities = fixtureCapabilities calls applied loseEffectResponse unobservable
      sessionRunner =
        ProviderNarrowSessionRunner $ \intent _deadline action -> do
          let coordinate = providerIntentCoordinate intent
          modifyIORef' calls (("session-open", coordinate) :)
          result <- action "narrow-session"
          modifyIORef' calls (("session-close", coordinate) :)
          pure result
      adapter =
        ProviderWorkerAdapter
          { providerWorkerRetainedRepository = repository
          , providerWorkerAuthorityNow = pure (Right (authorityTimeFromMicros 1000))
          , providerWorkerSessionDeadline = pure (Right (authorityTimeFromMicros 5000))
          , providerWorkerNarrowSession = sessionRunner
          , providerWorkerIntentCapabilities = capabilities
          , providerWorkerExternalReady = pure True
          }
  pure
    Fixture
      { fixtureAdapter = adapter
      , fixtureCalls = calls
      , fixtureLoseEffectResponse = loseEffectResponse
      , fixtureUnobservable = unobservable
      , fixtureLoseCasResponse = loseCasResponse
      }

fixtureCapabilities
  :: IORef [(Text, ProviderIntentCoordinate)]
  -> IORef [ProviderIntentCoordinate]
  -> IORef [ProviderIntentCoordinate]
  -> IORef [ProviderIntentCoordinate]
  -> ProviderIntentCapabilities IO Text
fixtureCapabilities calls applied loseResponse unobservable =
  ProviderIntentCapabilities
    { reconcileRegisteredStackCapability = \ref requestedRevision _config ->
        mutation
          ("stack-reconcile:" <> providerStackRefText ref <> "@" <> revisionText requestedRevision)
    , destroyRegisteredStackCapability = \ref requestedRevision _config ->
        mutation
          ("stack-destroy:" <> providerStackRefText ref <> "@" <> revisionText requestedRevision)
    , observeRegisteredStackCapability = \ref -> readOnly ("stack-observe:" <> providerStackRefText ref)
    , readBackRegisteredStackCapability = \ref -> readOnly ("stack-readback:" <> providerStackRefText ref)
    , boundedScratchCheckpointCapability = \ref ->
        mutation ("checkpoint:" <> providerCheckpointRefText ref)
    , reconcileSesSendingIdentityCapability = \ref ->
        mutation ("ses-identity:" <> sesIdentityRefText ref)
    , reconcileSesDkimCapability = \ref -> mutation ("ses-dkim:" <> sesIdentityRefText ref)
    , reconcileSesReceiptRulesCapability = \ref ->
        mutation ("ses-rules:" <> sesRuleSetRefText ref)
    , reconcileSesCaptureBucketCapability = \ref ->
        mutation ("ses-bucket:" <> sesBucketRefText ref)
    , reconcileSesDnsCapability = \ref ->
        mutation ("ses-dns:" <> sesDnsHostedZoneId ref)
    , observePublicARecordCapability = const (readOnly "public-a-observe")
    , reconcilePublicARecordCapability = const (mutation "public-a-reconcile")
    , reapTestEbsVolumesCapability = \clusterName ->
        mutation ("ebs-reap:" <> clusterName)
    , observeTestEbsVolumesCapability = \clusterName ->
        readOnly ("ebs-observe:" <> clusterName)
    , observeSpotPriceCapability = \query ->
        readOnly
          ( "spot-price:"
              <> providerSpotPriceInstanceType query
              <> ":"
              <> providerSpotPriceProductDescription query
          )
    , observeOperationalIdentityCapability = readOnly "operational-identity"
    , observeProviderAwsScopeCapability = readOnly "provider-aws-scope"
    , observeProviderReadinessCapability = readOnly . readinessLabel
    , issueEksClientAuthCapability = const (readOnly "eks-client-auth")
    , observeEksClusterIdentityCapability = const (readOnly "eks-cluster-identity")
    }
 where
  mutation label =
    ProviderMutation
      { observeProviderMutation = \_session coordinate -> do
          modifyIORef' calls (("observe:" <> label, coordinate) :)
          blocked <- elem coordinate <$> readIORef unobservable
          alreadyApplied <- elem coordinate <$> readIORef applied
          pure $
            if blocked
              then ProviderEffectUnobservable "injected observation outage"
              else
                if alreadyApplied
                  then ProviderEffectSatisfied ("evidence:" <> label)
                  else ProviderEffectNeedsApply ("missing:" <> label)
      , applyProviderMutation = \_session coordinate -> do
          modifyIORef' calls (("apply:" <> label, coordinate) :)
          modifyIORef' applied (insertUnique coordinate)
          lost <- elem coordinate <$> readIORef loseResponse
          if lost
            then do
              modifyIORef' loseResponse (filter (/= coordinate))
              pure (Left "injected response loss after apply")
            else pure (Right ())
      }
  readOnly label =
    ProviderReadOnly $ \_session coordinate -> do
      modifyIORef' calls (("read:" <> label, coordinate) :)
      pure (Right ("evidence:" <> label))

runFresh :: Fixture -> ProviderIntent -> IO ()
runFresh fixture intent = do
  admit fixture intent `shouldReturn` Right ()
  executeProviderIntent (fixtureAdapter fixture) intent
    `shouldReturn` Right
      ProviderWorkCompletion
        { providerWorkCompletedIntent = intent
        , providerWorkCompletionEvidence = evidenceFor intent
        }

admit :: Fixture -> ProviderIntent -> IO (Either Text ())
admit fixture = admitWith (fixtureAdapter fixture)

admitWith :: ProviderWorkerAdapter IO session -> ProviderIntent -> IO (Either Text ())
admitWith adapter intent =
  commitProviderWorkTransition
    adapter
    ProviderIdle
    (SubmitProviderIntent intent)
    (ProviderInFlight (providerIntentCoordinate intent))

readDurable :: Fixture -> IO ProviderWorkDurableState
readDurable fixture = do
  observed <-
    readProviderWorkRetainedState
      (providerWorkerRetainedRepository (fixtureAdapter fixture))
  case observed of
    Left detail -> fail (Text.unpack detail)
    Right snapshot -> pure (providerWorkRetainedState snapshot)

inMemoryRetainedRepository
  :: IORef (Natural, ProviderWorkDurableState)
  -> IORef Bool
  -> ProviderWorkRetainedRepository IO
inMemoryRetainedRepository stateRef loseResponseRef =
  ProviderWorkRetainedRepository
    { readProviderWorkRetainedState = do
        (revisionNumber, state) <- readIORef stateRef
        pure
          ( Right
              ProviderWorkRetainedSnapshot
                { providerWorkRetainedRevision = Just (version revisionNumber)
                , providerWorkRetainedState = state
                }
          )
    , compareAndSwapProviderWorkRetainedState = \expected state -> do
        (revisionNumber, _) <- readIORef stateRef
        if expected /= Just (version revisionNumber)
          then pure (Left "injected exact-revision conflict")
          else do
            writeIORef stateRef (revisionNumber + 1, state)
            loseResponse <- readIORef loseResponseRef
            if loseResponse
              then writeIORef loseResponseRef False >> pure (Left "injected CAS response loss")
              else pure (Right ())
    }

retainedAdapter
  :: IORef (ModelBObservation ProviderWorkDurableState)
  -> IORef [ModelBCasRequest 'ClusterRetained ProviderWorkDurableState]
  -> ModelBCasAdapter 'ClusterRetained IO ProviderWorkDurableState
retainedAdapter observationRef requestsRef =
  ModelBCasAdapter
    { modelBObserve = \_ -> readIORef observationRef
    , modelBCompareAndSwap = \request -> do
        modifyIORef' requestsRef (request :)
        let state = requestState request
            observedVersion = version 1
        writeIORef observationRef (ModelBObserved observedVersion state)
        pure (ModelBCasApplied observedVersion state)
    }

requestState :: ModelBCasRequest lifetime ProviderWorkDurableState -> ProviderWorkDurableState
requestState request = case request of
  ModelBInitialize _ state -> state
  ModelBReplace _ _ state -> state
  ModelBInitializeGuarded _ _ state -> state
  ModelBReplaceGuarded _ _ _ state -> state

retainedProviderWorkCoordinate :: ModelBObjectCoordinate 'ClusterRetained
retainedProviderWorkCoordinate =
  mustRight
    (mkClusterRetainedCoordinate retainedAuthority "provider-worker/work-state")

retainedAuthority :: LongLivedCheckpointAuthority
retainedAuthority =
  mustRight
    ( mkLongLivedCheckpointAuthority
        "home"
        "prodbox-state"
        "authority"
        "secret/lifecycle"
    )

version :: Natural -> ModelBObjectVersion
version number = mustRight (mkModelBObjectVersion ("provider-v" <> Text.pack (show number)))

allIntents :: [ProviderIntent]
allIntents =
  [ ReconcileRegisteredStack (stackRef "aws-eks") (revision 3) awsEksConfig
  , DestroyRegisteredStack (stackRef "aws-eks") (revision 3) awsEksConfig
  , ObserveRegisteredStack (stackRef "aws-eks")
  , ReadBackRegisteredStack (stackRef "aws-eks")
  , BoundedScratchCheckpoint (checkpointRef "scratch")
  , ReconcileSesSendingIdentity (sesIdentityRef "mail")
  , ReconcileSesDkim (sesIdentityRef "mail")
  , ReconcileSesReceiptRules (sesRuleSetRef "inbound")
  , ReconcileSesCaptureBucket (sesBucketRef "capture")
  , ReconcileSesDns sesDnsRef
  , ReapTestEbsVolumes "prodbox-test"
  , ObserveTestEbsVolumes "prodbox-test"
  , ObserveSpotPrice spotPriceQuery
  , ObserveOperationalIdentity
  , ObserveProviderAwsScope
  , ObserveProviderReadiness ProviderReadinessStsIdentity
  , ObserveEksClusterIdentity
      ( mustRight
          ( mkEksClusterIdentityRequest
              (stackRef "aws-eks")
              "123456789012"
              "ca-central-1"
              "aws-eks-test-cluster"
          )
      )
  ]

expectedCalls :: ProviderIntent -> [(Text, ProviderIntentCoordinate)]
expectedCalls intent =
  let coordinate = providerIntentCoordinate intent
      call callLabel = (callLabel, coordinate)
      intentLabel = labelFor intent
   in case intent of
        ObserveRegisteredStack _ ->
          [call "session-open", call ("read:" <> intentLabel), call "session-close"]
        ReadBackRegisteredStack _ ->
          [call "session-open", call ("read:" <> intentLabel), call "session-close"]
        ObserveSpotPrice _ ->
          [call "session-open", call ("read:" <> intentLabel), call "session-close"]
        ObserveOperationalIdentity ->
          [call "session-open", call ("read:" <> intentLabel), call "session-close"]
        ObserveProviderAwsScope ->
          [call "session-open", call ("read:" <> intentLabel), call "session-close"]
        ObserveProviderReadiness _ ->
          [call "session-open", call ("read:" <> intentLabel), call "session-close"]
        ObserveTestEbsVolumes _ ->
          [call "session-open", call ("read:" <> intentLabel), call "session-close"]
        ObserveEksClusterIdentity _ ->
          [call "session-open", call ("read:" <> intentLabel), call "session-close"]
        _ ->
          [ call "session-open"
          , call ("observe:" <> intentLabel)
          , call ("apply:" <> intentLabel)
          , call ("observe:" <> intentLabel)
          , call "session-close"
          ]

labelFor :: ProviderIntent -> Text
labelFor intent = case intent of
  ReconcileRegisteredStack ref requested _config ->
    "stack-reconcile:" <> providerStackRefText ref <> "@" <> revisionText requested
  DestroyRegisteredStack ref requested _config ->
    "stack-destroy:" <> providerStackRefText ref <> "@" <> revisionText requested
  ObserveRegisteredStack ref -> "stack-observe:" <> providerStackRefText ref
  ReadBackRegisteredStack ref -> "stack-readback:" <> providerStackRefText ref
  BoundedScratchCheckpoint ref -> "checkpoint:" <> providerCheckpointRefText ref
  ReconcileSesSendingIdentity ref -> "ses-identity:" <> sesIdentityRefText ref
  ReconcileSesDkim ref -> "ses-dkim:" <> sesIdentityRefText ref
  ReconcileSesReceiptRules ref -> "ses-rules:" <> sesRuleSetRefText ref
  ReconcileSesCaptureBucket ref -> "ses-bucket:" <> sesBucketRefText ref
  ReconcileSesDns ref -> "ses-dns:" <> sesDnsHostedZoneId ref
  ObservePublicARecord _ -> "public-a-observe"
  ReconcilePublicARecord _ -> "public-a-reconcile"
  ReapTestEbsVolumes clusterName -> "ebs-reap:" <> clusterName
  ObserveSpotPrice query ->
    "spot-price:"
      <> providerSpotPriceInstanceType query
      <> ":"
      <> providerSpotPriceProductDescription query
  ObserveOperationalIdentity -> "operational-identity"
  ObserveProviderAwsScope -> "provider-aws-scope"
  ObserveProviderReadiness probe -> readinessLabel probe
  IssueEksClientAuth _ -> "eks-client-auth"
  ObserveTestEbsVolumes clusterName -> "ebs-observe:" <> clusterName
  ObserveEksClusterIdentity _ -> "eks-cluster-identity"

readinessLabel :: ProviderReadinessProbe -> Text
readinessLabel probe = case probe of
  ProviderReadinessStsIdentity -> "readiness:sts"
  ProviderReadinessRoute53Zone zoneId -> "readiness:route53:" <> zoneId

evidenceFor :: ProviderIntent -> Text
evidenceFor = ("evidence:" <>) . labelFor

revisionText :: ProviderRevision -> Text
revisionText = Text.pack . show . providerRevisionNatural

insertUnique :: (Eq value) => value -> [value] -> [value]
insertUnique value values
  | value `elem` values = values
  | otherwise = value : values

stackRef :: Text -> ProviderStackRef
stackRef = mustRight . mkProviderStackRef

checkpointRef :: Text -> ProviderCheckpointRef
checkpointRef = mustRight . mkProviderCheckpointRef

sesIdentityRef :: Text -> SesIdentityRef
sesIdentityRef = mustRight . mkSesIdentityRef

sesRuleSetRef :: Text -> SesRuleSetRef
sesRuleSetRef name = mustRight (mkSesRuleSetRef name "inbox.example.test" "capture")

sesBucketRef :: Text -> SesBucketRef
sesBucketRef = mustRight . mkSesBucketRef

sesDnsRef :: SesDnsRef
sesDnsRef = mustRight (mkSesDnsRef "Z123EXAMPLE" "example.test" "inbox.example.test")

revision :: Natural -> ProviderRevision
revision = mustRight . mkProviderRevision

awsEksConfig :: ProviderStackConfig
awsEksConfig = mustRight (mkAwsEksProviderStackConfig "127.0.0.1/32")

spotPriceQuery :: ProviderSpotPriceQuery
spotPriceQuery = mustRight (mkProviderSpotPriceQuery "t3.small" "Linux/UNIX")

mustRight :: (Show errorValue) => Either errorValue value -> value
mustRight = either (error . show) id

shouldSatisfyReturn :: (Show value) => IO value -> (value -> Bool) -> Expectation
shouldSatisfyReturn action predicate = do
  value <- action
  value `shouldSatisfy` predicate
