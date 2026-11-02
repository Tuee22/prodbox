{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module ControlPlaneRpcAdmissionBirth
  ( rpcAdmissionBirthSuite
  , rpcBirthChartDescriptorFixture
  , withRpcBirthCoordinatorNativeFixture
  , withRpcBirthCoordinatorWireFixture
  , withRpcBirthPreparedCoordinatorWireFixture
  , withRpcBirthPreparedCoordinatorWireFixtureForKey
  , withRpcBirthPreparedCoordinatorRegistryWireFixture
  , RpcBirthCallerVaultFault (..)
  , withRpcBirthCallerVaultFixture
  , rpcBirthHomeRegistryFixture
  ) where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (link, withAsync)
import Control.Concurrent.MVar (newEmptyMVar, takeMVar)
import Control.Exception (AsyncException (ThreadKilled), bracket, finally, throwIO, try)
import Control.Monad (foldM, forM_, forever, unless, void, when)
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as B64
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as Lazy
import Data.Char (toLower)
import Data.Either (isLeft)
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Dhall qualified
import GHC.Generics (Generic)
import Network.Socket
import Network.Socket.ByteString (recv, sendAll)
import Numeric.Natural (Natural)
import Prodbox.Capacity.ControlPlaneReplayBudget qualified as ReplayBudget
import Prodbox.Config.Tier0 qualified as Tier0
import Prodbox.ControlPlane.AuthenticatedTransport qualified as Transport
import Prodbox.ControlPlane.AuthenticationRegistry
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
import Prodbox.ControlPlane.AuthorityPeerContext
import Prodbox.ControlPlane.AuthorityPeerContextEndpoint
import Prodbox.ControlPlane.Client qualified as Client
import Prodbox.ControlPlane.Codec (encodeControlPlaneResponse)
import Prodbox.ControlPlane.Coordinate qualified as Coordinate
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication (ExternalLifecycleAuthorityCaller (..))
import Prodbox.ControlPlane.RegisteredRpcSigning (RpcKeyRegistryObserver (..))
import Prodbox.ControlPlane.RequestAuthentication
import Prodbox.ControlPlane.Route
import Prodbox.ControlPlane.RpcAdmissionBirth
import Prodbox.ControlPlane.RpcAdmissionBirthBackup
import Prodbox.ControlPlane.RpcAdmissionBirthConfig
import Prodbox.ControlPlane.RpcAdmissionBirthCoordinator qualified as Coordinator
import Prodbox.ControlPlane.RpcAdmissionBirthEndpoint
import Prodbox.ControlPlane.RpcAdmissionBirthExecution
import Prodbox.ControlPlane.RpcAdmissionBirthNative
import Prodbox.ControlPlane.RpcAdmissionBirthPublication (tier0RpcBirthPublicationAtPath)
import Prodbox.ControlPlane.RpcAdmissionBirthRuntime
import Prodbox.ControlPlane.RpcKeyRegistry
import Prodbox.ControlPlane.RpcOwnBindingHint
import Prodbox.ControlPlane.Server qualified as Server
import Prodbox.ControlPlane.TargetSecretAgentExecution
  ( mkTargetIntentPublicKey
  , mkTargetIssuerKeyGeneration
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..), replyStatusCode)
import Prodbox.Lifecycle.Authority.Admission
import Prodbox.Lifecycle.Authority.ClientRegistry
import Prodbox.Lifecycle.Authority.Genesis
import Prodbox.Lifecycle.Authority.Migration
import Prodbox.Lifecycle.CheckpointAuthority
import Prodbox.Lifecycle.Lease
import Prodbox.Runtime.Role (RuntimeRole (..))
import Prodbox.Vault.Client (VaultAddress (..), VaultToken (..))
import Prodbox.Vault.Session
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import TestSupport

rpcAdmissionBirthSuite :: SuiteBuilder ()
rpcAdmissionBirthSuite = describe "Sprint 6.5 explicit RPC registration birth" $ do
  it "preserves exact legacy admission bytes while selecting a new reader" $ do
    let old = must (encodeModelBValue legacyCodec legacy)
    encodeModelBValue codec legacyRecord `shouldBe` Right old
    decodeModelBValue codec old `shouldBe` Right legacyRecord

  it "rejects bare registered data without a birth descriptor" $ do
    let bare = must (seedAuthorityRpcKeyRegistry scope seeded legacy)
        bytes =
          must (encodeModelBValue (authorityAdmissionStateCodecWithRegisteredRpc 524288 4 8 scope 7 4) bare)
    decodeModelBValue codec bytes `shouldSatisfy` isLeft

  it "prepares a write-ahead fence without creating the marker or changing old IDs" $ do
    fixture <- newFixture
    run fixture legacyRpcBirthServingMode (PrepareRpcBirth 1 keyA)
      >>= (\result -> rpcBirthStatusPhase (must result) `shouldBe` BirthPrepared)
    (_, record) <- current fixture
    readIORef (anchor fixture) `shouldReturn` ModelBMissing
    rpcBirthAdmission record `shouldBe` legacy
    records <- pair fixture
    uncurry (rpcBirthNormalAdmission legacyRpcBirthServingMode) records
      `shouldBe` Left RpcBirthWrongPhase

  it "arms before requiring an independently configured publication pin" $ do
    fixture <- preparedFixture
    run fixture legacyRpcBirthServingMode (CompleteRpcBirth 1 keyA)
      `shouldReturn` Left RpcBirthPublicationRequired
    (_, record) <- current fixture
    rpcBirthPhase record `shouldBe` BirthArmed
    readIORef (writes fixture) `shouldReturn` 3

  it "commits only matching primary, marker and configured pin" $ do
    fixture <- preparedFixture
    mode <- pin fixture
    status <- must <$> run fixture mode (CompleteRpcBirth 1 keyA)
    rpcBirthStatusPhase status `shouldBe` BirthCommitted
    rpcBirthStatusCommitted status `shouldBe` True
    selected <- uncurry (rpcBirthNormalAdmission mode) <$> pair fixture
    fmap (fmap (authorityAggregateRpcKeyRegistry . snd)) selected `shouldBe` Right (Just (Just seeded))
    records <- pair fixture
    uncurry (rpcBirthNormalAdmission legacyRpcBirthServingMode) records
      `shouldBe` Left RpcBirthWrongPhase
    run fixture mode (AbortRpcBirth 1 keyA) `shouldReturn` Left RpcBirthAlreadyCommitted

  it "does not create a source object or seed on absence" $ do
    fixture <- newFixture
    writeIORef (primary fixture) ModelBMissing
    run fixture legacyRpcBirthServingMode (PrepareRpcBirth 1 keyA)
      `shouldReturn` Left RpcBirthAdmissionMissing
    readIORef (sourceReads fixture) `shouldReturn` 0
    readIORef (writes fixture) `shouldReturn` 0

  it "retains the serving pin when both admitted objects disappear" $ do
    fixture <- preparedFixture
    mode <- pin fixture
    writeIORef (primary fixture) ModelBMissing
    writeIORef (anchor fixture) ModelBMissing
    run fixture mode ObserveRpcBirth `shouldReturn` Left RpcBirthAdmissionMissing
    rpcBirthNormalAdmission mode ModelBMissing ModelBMissing
      `shouldBe` Left RpcBirthAdmissionMissing

  it "refuses a lost primary with an observed marker" $ do
    fixture <- preparedFixture
    mode <- pin fixture
    _ <- run fixture mode (CompleteRpcBirth 1 keyA)
    writeIORef (primary fixture) ModelBMissing
    records <- pair fixture
    uncurry (rpcBirthNormalAdmission mode) records `shouldBe` Left RpcBirthAdmissionMissing

  it "refuses a lost committed marker rather than rebuilding native counters" $ do
    fixture <- preparedFixture
    mode <- pin fixture
    _ <- run fixture mode (CompleteRpcBirth 1 keyA)
    writeIORef (anchor fixture) ModelBMissing
    run fixture mode ObserveRpcBirth `shouldReturn` Left RpcBirthMarkerMissing

  it "does not observe native keys before predecessor quiescence" $ do
    fixture <- newFixture
    let active = openAdmission initial
    writeIORef (primary fixture) (ModelBObserved (version 1) (must (rpcBirthLegacy active)))
    run fixture legacyRpcBirthServingMode (PrepareRpcBirth 1 keyA)
      `shouldReturn` Left RpcBirthLegacyStateRequired
    readIORef (sourceReads fixture) `shouldReturn` 0

  it "binds the command to the signed body, including observation" $ do
    fixture <- newFixture
    run fixture legacyRpcBirthServingMode ObserveRpcBirth
      >>= (\result -> rpcBirthStatusPhase (must result) `shouldBe` BirthLegacy)
    readIORef (writes fixture) `shouldReturn` 0
    mkRpcBirthContext
      scope
      legacyRpcBirthServingMode
      (signed CallerCredentialProvisioner "foreign" 1000 2000000)
      `shouldSatisfy` isLeft

  it "rejects unowned callers and malformed owned payloads before effects" $ do
    mkRpcBirthContext
      scope
      legacyRpcBirthServingMode
      (signed (CallerService ProviderWorkerRuntime) (encodeRpcBirthCommand ObserveRpcBirth) 1000 2000000)
      `shouldSatisfy` isLeft
    mkRpcBirthContext
      scope
      legacyRpcBirthServingMode
      (signed CallerOperatorCli "malformed" 1000 2000000)
      `shouldSatisfy` isLeft
    decodeRpcBirthCommand (encodeRpcBirthCommand (PrepareRpcBirth 0 keyA))
      `shouldBe` Left RpcBirthRequestInvalid
    decodeRpcBirthCommand (encodeRpcBirthCommand (PrepareRpcBirth 1 "noncanonical"))
      `shouldBe` Left RpcBirthRequestInvalid
    decodeRpcBirthCommand (encodeRpcBirthCommand ObserveRpcBirth <> "trailing")
      `shouldBe` Left RpcBirthRequestInvalid

  forM_ [1 .. 5] $ \cut ->
    it ("resumes the durable prefix after interrupted CAS number " <> show cut) $ do
      fixture <- newFixture
      writeIORef (stopAt fixture) (Just cut)
      _ <- run fixture legacyRpcBirthServingMode (PrepareRpcBirth 1 keyA)
      writeIORef (stopAt fixture) Nothing
      mode <- pin fixture
      -- Cuts after preparation are planted again during the continuation.
      if cut > 1 then writeIORef (stopAt fixture) (Just cut) else pure ()
      _ <- run fixture mode (CompleteRpcBirth 1 keyA)
      writeIORef (stopAt fixture) Nothing
      result <- must <$> run fixture mode (CompleteRpcBirth 1 keyA)
      rpcBirthStatusCommitted result `shouldBe` True
      readIORef (writes fixture) `shouldReturn` 5

  it "confirms a lost CAS reply by exact independent readback" $ do
    fixture <- newFixture
    writeIORef (loseReply fixture) True
    run fixture legacyRpcBirthServingMode (PrepareRpcBirth 1 keyA)
      >>= (\result -> rpcBirthStatusPhase (must result) `shouldBe` BirthPrepared)
    mode <- pin fixture
    run fixture mode (CompleteRpcBirth 1 keyA)
      >>= (\result -> rpcBirthStatusCommitted (must result) `shouldBe` True)

  it "retires an unarmed prefix and advances the retained generation" $ do
    fixture <- preparedFixture
    run fixture legacyRpcBirthServingMode (AbortRpcBirth 1 keyA)
      >>= (\result -> rpcBirthStatusPhase (must result) `shouldBe` BirthRetired)
    selected <- uncurry (rpcBirthNormalAdmission legacyRpcBirthServingMode) <$> pair fixture
    fmap (fmap snd) selected `shouldBe` Right (Just legacy)
    run fixture legacyRpcBirthServingMode (PrepareRpcBirth 1 keyA)
      `shouldReturn` Left RpcBirthGenerationMismatch
    run fixture legacyRpcBirthServingMode (PrepareRpcBirth 2 keyB)
      >>= (\result -> rpcBirthStatusPhase (must result) `shouldBe` BirthPrepared)
    run fixture legacyRpcBirthServingMode (AbortRpcBirth 2 keyB)
      >>= (\result -> rpcBirthStatusGeneration (must result) `shouldBe` 2)

  it "retires an armed prefix with a fresh cleanup deadline after expiry" $ do
    fixture <- preparedFixture
    _ <- run fixture legacyRpcBirthServingMode (CompleteRpcBirth 1 keyA)
    writeIORef (clock fixture) 3000000
    let cleanup = context legacyRpcBirthServingMode (AbortRpcBirth 1 keyA) 3000000 5000000
    executeRpcBirth (interpreter fixture) cleanup
      >>= (\result -> rpcBirthStatusPhase (must result) `shouldBe` BirthRetired)

  it "does not renew the preparation deadline on a fresh completion request" $ do
    fixture <- preparedFixture
    mode <- pin fixture
    writeIORef (clock fixture) 3000000
    executeRpcBirth (interpreter fixture) (context mode (CompleteRpcBirth 1 keyA) 3000000 5000000)
      `shouldReturn` Left RpcBirthDeadlineReached

  it "confirms an irreversible commit under a fresh request after preparation expiry" $ do
    fixture <- preparedFixture
    mode <- pin fixture
    writeIORef (stopAt fixture) (Just 4)
    run fixture mode (CompleteRpcBirth 1 keyA) `shouldReturn` Left RpcBirthEffectTimedOut
    (_, committed) <- current fixture
    rpcBirthPhase committed `shouldBe` BirthCommitted
    writeIORef (stopAt fixture) Nothing
    writeIORef (clock fixture) 3000000
    result <-
      executeRpcBirth
        (interpreter fixture)
        (context mode (CompleteRpcBirth 1 keyA) 3000000 5000000)
    rpcBirthStatusCommitted (must result) `shouldBe` True
    readIORef (sourceReads fixture) `shouldReturn` 2
    readIORef (writes fixture) `shouldReturn` 5

  it "authenticates retirement observation before the configured pin is removed" $ do
    fixture <- preparedFixture
    mode <- pin fixture
    _ <- must <$> run fixture mode (AbortRpcBirth 1 keyA)
    records <- pair fixture
    uncurry (rpcBirthAuthenticationAdmission mode) records `shouldBe` Right (Just legacy)
    uncurry (rpcBirthNormalAdmission mode) records `shouldBe` Left RpcBirthWrongPhase
    run fixture mode ObserveRpcBirth
      >>= (\result -> rpcBirthStatusPhase (must result) `shouldBe` BirthRetired)

  it "detects source changes before committing an armed registry" $ do
    fixture <- preparedFixture
    mode <- pin fixture
    writeIORef (source fixture) (Left RpcBirthNativeSourceChanged)
    run fixture mode (CompleteRpcBirth 1 keyA) `shouldReturn` Left RpcBirthNativeSourceChanged
    (_, record) <- current fixture
    rpcBirthPhase record `shouldBe` BirthArmed
    authorityAggregateRpcKeyRegistry (rpcBirthAdmission record) `shouldBe` Nothing

  it "round-trips every retained prefix under the same authored byte/capacity bounds" $ do
    fixture <- preparedFixture
    mode <- pin fixture
    _ <- run fixture mode (CompleteRpcBirth 1 keyA)
    snapshots <- readIORef (history fixture)
    forM_ snapshots $ \record -> do
      let bytes = must (encodeModelBValue codec record)
      decodeModelBValue codec bytes `shouldBe` Right record
      registeredClientTableCapacity (authorityAggregateRegisteredClients (rpcBirthAdmission record))
        `shouldBe` 7
      decodeModelBValue (rpcBirthRecordCodec 8 4 8 scope clients) bytes `shouldSatisfy` isLeft

  it "redacts all inner legacy payloads from the record's Show instance" $
    show legacyRecord `shouldBe` "RpcBirthRecord {phase = BirthLegacy}"

  it "propagates cancellation at the interpreter boundary" $ do
    let cancelled = RpcBirthInterpreter (\_ _ -> throwIO ThreadKilled)
    result <-
      try (executeRpcBirth cancelled (context legacyRpcBirthServingMode ObserveRpcBirth 1000 2000000))
    (result :: Either AsyncException (Either RpcBirthError RpcBirthStatus)) `shouldBe` Left ThreadKilled

  it "physically bounds a blocked native source operation" $ do
    fixture <- newFixture
    let backend = nativeBackend fixture (threadDelay 300000 >> pure (Right seeded))
    now <- rpcBirthSystemTime
    let nowMicros = authorityTimeMicros now
        request = context legacyRpcBirthServingMode (PrepareRpcBirth 1 keyA) nowMicros (nowMicros + 50000)
    result <- executeRpcBirth (rpcBirthNativeInterpreter backend) request
    result
      `shouldSatisfy` (\value -> value == Left RpcBirthEffectTimedOut || value == Left RpcBirthDeadlineReached)
    readIORef (writes fixture) `shouldReturn` 0

  forM_ nativeSnapshotCases $ \(beforeName, before, expectedRow) ->
    forM_ (zip nativeSnapshotInputs expectedRow) $ \((afterName, after), expected) ->
      it ("preserves recovery evidence across native reads " <> beforeName <> " -> " <> afterName) $ do
        fixture <- newFixture
        let backend = nativeSnapshotBackend fixture after
            reset = writeIORef (primary fixture) before
            expectedAuthentication =
              either (Left . Text.pack . show) Right $
                rpcBirthAuthenticationAdmission legacyRpcBirthServingMode expected ModelBMissing
            expectedAdmission =
              either (Left . Text.pack . show) (Right . fmap snd) $
                rpcBirthNormalAdmission legacyRpcBirthServingMode expected ModelBMissing
        reset
        observeRpcBirthNativeRecords backend `shouldReturn` (expected, ModelBMissing)
        reset
        rpcBirthNativeAuthenticationAdmission backend legacyRpcBirthServingMode
          `shouldReturn` expectedAuthentication
        reset
        let repository = rpcBirthNativeAdmissionRepository backend legacyRpcBirthServingMode legacy
        observed <- readAuthorityAdmission repository
        fmap (Just . authorityAdmissionSnapshotState) observed
          `shouldBe` fmap (Just . maybe legacy id) expectedAdmission
        case expectedAdmission of
          Left cause -> do
            reset
            compareAndSwapAuthorityAdmission repository Nothing legacy `shouldReturn` Left cause
          Right _ -> pure ()
        let expectedStatus = fst <$> observeRpcBirthPair expected ModelBMissing
            runtime = rpcBirthNativeInterpreter backend
        now <- rpcBirthSystemTime
        let request body =
              signed CallerOperatorCli body (authorityTimeMicros now) (authorityTimeMicros now + 5000000)
        reset
        executeRpcBirth
          runtime
          ( must
              (mkRpcBirthContext scope legacyRpcBirthServingMode (request (encodeRpcBirthCommand ObserveRpcBirth)))
          )
          `shouldReturn` expectedStatus
        reset
        descriptorResult <-
          executeRpcBirthDescriptorObservation
            (rpcBirthReadInterpreter runtime)
            ( must
                (mkRpcBirthDescriptorContext scope legacyRpcBirthServingMode (request rpcBirthDescriptorRequest))
            )
        fmap rpcBirthObservationStatus descriptorResult `shouldBe` expectedStatus
        readIORef (writes fixture) `shouldReturn` 0
        readIORef (sourceReads fixture) `shouldReturn` 0

  forM_
    [ ("corrupt", ModelBCorrupt "marker-corruption", "RpcBirthStateInvalid")
    , ("unready", ModelBEndpointUnready "marker-endpoint", "RpcBirthObservationUnavailable")
    , ("unobservable", ModelBUnobservable "marker-read", "RpcBirthObservationUnavailable")
    ]
    $ \(name, markerFailure, expected) ->
      it ("preserves a " <> name <> " marker through native recovery and admission") $ do
        fixture <- newFixture
        writeIORef (anchor fixture) markerFailure
        let backend = nativeBackend fixture (fail "marker failure read native keys")
        rpcBirthNativeAuthenticationAdmission backend legacyRpcBirthServingMode
          `shouldReturn` Left expected
        let repository = rpcBirthNativeAdmissionRepository backend legacyRpcBirthServingMode legacy
        (void <$> readAuthorityAdmission repository) `shouldReturn` Left expected
        compareAndSwapAuthorityAdmission repository Nothing legacy `shouldReturn` Left expected
        readIORef (writes fixture) `shouldReturn` 0

  it "round-trips the explicit mounted union and rejects foreign or unsupported pins" $ do
    fixture <- preparedFixture
    (_, record) <- current fixture
    let descriptor = maybe (error "descriptor") id (rpcBirthDescriptor record)
        wire = RpcBirthConfigRegistered (RpcBirthConfigPin "home" 1 (rpcBirthDescriptorDigest descriptor))
    decoded <- Dhall.input Dhall.auto (Text.pack (renderRpcBirthConfigDhall wire))
    decoded `shouldBe` wire
    validateRpcBirthConfig LifecycleAuthorityRuntime scope wire `shouldBe` Right (mustPin descriptor)
    validateRpcBirthConfig ProviderWorkerRuntime scope wire
      `shouldBe` Left RpcBirthConfigRoleUnsupported
    validateRpcBirthConfig
      LifecycleAuthorityRuntime
      scope
      (RpcBirthConfigRegistered (RpcBirthConfigPin "foreign" 1 (rpcBirthDescriptorDigest descriptor)))
      `shouldBe` Left RpcBirthConfigScopeMismatch
    validateRpcBirthConfig
      LifecycleAuthorityRuntime
      scope
      (RpcBirthConfigRegistered (RpcBirthConfigPin "home" 0 (rpcBirthDescriptorDigest descriptor)))
      `shouldBe` Left RpcBirthConfigPinInvalid

  it "quotes public pin fields as Dhall text instead of evaluating interpolation" $ do
    let wire = RpcBirthConfigRegistered (RpcBirthConfigPin "${missing/import}" 1 "\"\n${missing/import}")
    decoded <- Dhall.input Dhall.auto (Text.pack (renderRpcBirthConfigDhall wire))
    decoded `shouldBe` wire
    legacyMode <- Dhall.input Dhall.auto (Text.pack (renderRpcBirthConfigDhall RpcBirthConfigLegacy))
    legacyMode `shouldBe` RpcBirthConfigLegacy

  it "selects pending recovery trust while ordinary admission remains fenced" $ do
    fixture <- preparedFixture
    mode <- pin fixture
    records <- pair fixture
    uncurry (rpcBirthRuntimeRegistry mode) records `shouldBe` Right (Just seeded)
    fmap trustView (uncurry (rpcBirthRuntimeTrust mode legacyTrust) records)
      `shouldBe` Right (trustView legacyTrust)
    uncurry (rpcBirthNormalAdmission mode) records `shouldBe` Left RpcBirthWrongPhase
    let backend = nativeBackend fixture (pure (Right seeded))
    rpcBirthNativeAuthenticationAdmission backend mode `shouldReturn` Right (Just legacy)
    readAuthorityAdmission (rpcBirthNativeAdmissionRepository backend mode legacy)
      >>= (`shouldSatisfy` isLeft)

  it "refuses committed trust under legacy startup mode and missing state under a pin" $ do
    fixture <- preparedFixture
    mode <- pin fixture
    _ <- must <$> run fixture mode (CompleteRpcBirth 1 keyA)
    records <- pair fixture
    void (uncurry (rpcBirthRuntimeTrust legacyRpcBirthServingMode legacyTrust) records)
      `shouldBe` Left RpcBirthPublicationRequired
    void (rpcBirthRuntimeTrust mode legacyTrust ModelBMissing ModelBMissing)
      `shouldBe` Left RpcBirthAdmissionMissing
    compareAndSwapAuthorityAdmission
      ( rpcBirthNativeAdmissionRepository
          (nativeBackend fixture (pure (Right seeded)))
          legacyRpcBirthServingMode
          legacy
      )
      Nothing
      legacy
      >>= (`shouldSatisfy` isLeft)

  it "preserves exact pre-birth backup bytes" $ do
    let bytes = must (encodeRpcBirthBackup legacyRpcBirthServingMode codec markerCodec legacyRecord Nothing)
    bytes `shouldBe` must (encodeModelBValue legacyCodec legacy)
    decodeRpcBirthBackup legacyRpcBirthServingMode codec markerCodec bytes
      `shouldBe` Right (legacyRecord, Nothing)

  forM_ [False, True] $ \retired ->
    it
      ( "backs up both retained fences and independently validates the restore pin, retired="
          <> show retired
      )
      $ do
        fixture <- preparedFixture
        configured <- pin fixture
        _ <-
          must <$> run fixture configured (if retired then AbortRpcBirth 1 keyA else CompleteRpcBirth 1 keyA)
        let mode = if retired then legacyRpcBirthServingMode else configured
        (_, record) <- current fixture
        marker <- readIORef (anchor fixture)
        let anchorValue = case marker of ModelBObserved _ value -> Just value; _ -> Nothing
            bytes = must (encodeRpcBirthBackup mode codec markerCodec record anchorValue)
        decodeRpcBirthBackup mode codec markerCodec bytes `shouldBe` Right (record, anchorValue)
        decodeRpcBirthBackup mode codec markerCodec (bytes <> "trailing") `shouldSatisfy` isLeft
        encodeRpcBirthBackup mode codec markerCodec record Nothing `shouldSatisfy` isLeft
        rpcBirthNativeBackupEnvelope
          codec
          markerCodec
          (nativeBackend fixture (pure (Right seeded)))
          mode
          (rpcBirthAdmission record)
          `shouldReturn` Right bytes
        rpcBirthNativeBackupEnvelope
          codec
          markerCodec
          (nativeBackend fixture (pure (Right seeded)))
          mode
          initial
          >>= (`shouldSatisfy` isLeft)
        if retired
          then pure ()
          else
            decodeRpcBirthBackup legacyRpcBirthServingMode codec markerCodec bytes `shouldSatisfy` isLeft

  it "observes the complete compatible home seed through actual native Vault HTTP" $
    withHomeVault HomeHealthy $ \session requests -> do
      observeCompatibleHomeRpcSeed scope session legacyTrust `shouldReturn` Right seeded
      observed <- readIORef requests
      length observed `shouldBe` 26
      length (filter (== "/v1/sys/health") observed) `shouldBe` 2

  forM_
    [ (HomeSealed, RpcBirthNativeSourceUnavailable)
    , (HomeDrift, RpcBirthNativeSourceChanged)
    , (HomeWrongPublic, RpcBirthNativeCompatibilityMismatch)
    , (HomeOversized, RpcBirthNativeSourceUnavailable)
    ]
    $ \(fault, expected) ->
      it ("refuses native home source fault " <> show fault) $
        withHomeVault fault $ \session _ ->
          observeCompatibleHomeRpcSeed scope session legacyTrust `shouldReturn` Left expected

  it "fences an existing legacy signing capability when preparation becomes durable" $
    withHomeVault HomeHealthy $ \session _ -> do
      fixture <- newFixture
      let backend = nativeBackend fixture (pure (Right seeded))
      capability <-
        must
          <$> resolveRpcBirthRuntimeSigner
            backend
            legacyRpcBirthServingMode
            scope
            session
            (localRequestSigningCapability (signer (CallerService LifecycleAuthorityRuntime)))
      signCanonicalBytesWithRequestCapability capability "before"
        >>= (`shouldSatisfy` either (const False) (const True))
      _ <- must <$> run fixture legacyRpcBirthServingMode (PrepareRpcBirth 1 keyA)
      signCanonicalBytesWithRequestCapability capability "after" >>= (`shouldSatisfy` isLeft)

  it "signs through the retained runtime mapping and refuses later marker loss" $
    withHomeVault HomeHealthy $ \session _ -> do
      fixture <- preparedFixture
      mode <- pin fixture
      _ <- must <$> run fixture mode (CompleteRpcBirth 1 keyA)
      let backend = nativeBackend fixture (pure (Right seeded))
      capability <-
        must
          <$> resolveRpcBirthRuntimeSigner
            backend
            mode
            scope
            session
            (localRequestSigningCapability (signer (CallerService LifecycleAuthorityRuntime)))
      signature <- signCanonicalBytesWithRequestCapability capability "registered"
      expected <-
        signCanonicalBytesWithRequestCapability
          (localRequestSigningCapability (signer (CallerService LifecycleAuthorityRuntime)))
          "registered"
      signature `shouldBe` expected
      writeIORef (anchor fixture) ModelBMissing
      signCanonicalBytesWithRequestCapability capability "after-loss" >>= (`shouldSatisfy` isLeft)

  it "selects logical generation three while signing native version two after a cold runtime start" $
    withHomeVault HomeRootRotated $ \session _ -> do
      fixture <- preparedFixture
      mode <- pin fixture
      _ <- must <$> run fixture mode (CompleteRpcBirth 1 keyA)
      (revision, record) <- current fixture
      let principal = CallerService LifecycleAuthorityRuntime
          ref = controlPlaneSigningKeyRefFor principal
          otherScope = must (Coordinate.mkAuthorityScope "other")
          vault = must (mkRpcVaultIncarnation "11111111-1111-1111-1111-111111111111")
          foreignVault = must (mkRpcVaultIncarnation "22222222-2222-2222-2222-222222222222")
          observed origin native seedByte =
            must
              ( mkRpcObservedKey
                  origin
                  native
                  ( requestSignerPublicKeyBytes
                      (must (mkRequestSigner principal (must (mkSigningKeyGeneration 1)) (BS.replicate 32 seedByte)))
                  )
              )
          foreignKey = observed (mkRpcKeyOrigin otherScope foreignVault ref) 1 251
          homeKey = observed (mkRpcKeyOrigin scope vault ref) 2 250
          registered =
            must
              ( enrollAuthorityRpcKey
                  homeKey
                  (must (enrollAuthorityRpcKey foreignKey (rpcBirthAdmission record)))
              )
          retired =
            must
              ( retireAuthorityRpcKey
                  principal
                  (must (mkSigningKeyGeneration 2))
                  (must (retireAuthorityRpcKey principal (must (mkSigningKeyGeneration 1)) registered))
              )
          next = must (replaceRpcBirthAdmission record retired)
      writeIORef (primary fixture) (ModelBObserved revision next)
      capability <-
        must
          <$> resolveRpcBirthRuntimeSigner
            (nativeBackend fixture (pure (Right seeded)))
            mode
            scope
            session
            (localRequestSigningCapability (signer principal))
      signingKeyGenerationValue (requestSigningCapabilityGeneration capability) `shouldBe` 3
      signature <- signCanonicalBytesWithRequestCapability capability "mapped-runtime"
      expected <-
        signCanonicalBytesWithRequestCapability
          ( localRequestSigningCapability
              (must (mkRequestSigner principal (must (mkSigningKeyGeneration 2)) (BS.replicate 32 250)))
          )
          "mapped-runtime"
      signature `shouldBe` expected
      registeredClientTableCapacity (authorityAggregateRegisteredClients retired) `shouldBe` 7

  it
    "refreshes peer context then drives native birth through actual signed client and verified handler"
    $ withHomeVault HomeHealthy
    $ \session _ -> do
      fixture <- newFixture
      modeRef <- newIORef legacyRpcBirthServingMode
      epochReads <- newIORef (0 :: Int)
      deadlineReads <- newIORef (0 :: Int)
      requestDeadlines <- newIORef []
      responseOverride <- newIORef Nothing
      nonceCount <- newIORef (0 :: Int)
      routes <- newIORef []
      now <- rpcBirthSystemTime
      let deadline = authorityTimeFromMicros (authorityTimeMicros now + 5000000)
          bounds = must (Transport.mkAuthenticatedTransportBounds 65536 1024 65000)
          lifetime = must (authorityDurationFromMicros 6000000)
          backend = nativeWritableBackend fixture (observeCompatibleHomeRpcSeed scope session legacyTrust)
          peerRead :: AuthorityPeerContextProgram value -> IO (Either AuthorityPeerContextError value)
          peerRead program = case program of
            ReadPeerContextTime -> Right <$> rpcBirthSystemTime
            ReadPeerContextEpoch _ -> pure (Right authorityEpochGenesis)
            ReadPeerContextIssuer _ ->
              pure
                ( Right
                    ( must (mkTargetIssuerKeyGeneration 1)
                    , must
                        ( mkTargetIntentPublicKey
                            (requestSignerPublicKeyBytes (signer (CallerService LifecycleAuthorityRuntime)))
                        )
                    )
                )
          transport _ _ url frame = do
            modifyIORef' routes (<> [url])
            mode <- readIORef modeRef
            let route =
                  if "/peer/observe" `Text.isSuffixOf` Text.pack url
                    then LifecycleAuthorityPeerObserve
                    else LifecycleMigrationApply
                serverProviders =
                  Transport.AuthenticatedServerProviders
                    (pure (Right scope))
                    (pure (Right authorityEpochGenesis))
                    (Right <$> rpcBirthSystemTime)
                    (pure (Right legacyTrust))
            authenticated <-
              Transport.authenticateControlPlaneFrame
                bounds
                lifetime
                serverProviders
                LifecycleAuthorityRuntime
                route
                (Lazy.fromStrict frame)
            let request = Transport.authenticatedServerVerifiedRequest (must authenticated)
            modifyIORef' requestDeadlines (<> [verifiedRequestDeadline request])
            response <-
              if route == LifecycleAuthorityPeerObserve
                then authorityPeerContextVerifiedHandler scope (AuthorityPeerContextInterpreter peerRead) request
                else rpcBirthVerifiedHandler scope mode backend request
            override <- readIORef responseOverride
            pure $ case response of
              Nothing -> error "birth fixture handler did not match"
              Just (status, body)
                | verifiedRequestBody request == rpcBirthDescriptorRequest
                , Just change <- override ->
                    Right (change (replyStatusCode status, body))
                | otherwise -> Right (replyStatusCode status, body)
          providers =
            Transport.AuthenticatedClientProviders
              (pure (Right (localRequestSigningCapability (signer CallerOperatorCli))))
              (pure (Right scope))
              (modifyIORef' epochReads (+ 1) >> pure (Left "ordinary admission is frozen"))
              (modifyIORef' deadlineReads (+ 1) >> pure (Right deadline))
              ( do
                  number <- atomicModifyIORef' nonceCount (\value -> (value + 1, value + 1))
                  pure (Right (must (mkRequestNonce (BS.replicate 16 (fromIntegral number)))))
              )
          client =
            must
              ( Client.controlPlaneClientWithTransport
                  65536
                  (must (Client.mkLifecycleAuthorityEndpoint "http://home.test"))
                  transport
              )
          authenticatedClient = Transport.mkAuthenticatedClientTransport bounds providers client
          sendBirth command = requestRpcBirthWithin (Right <$> rpcBirthSystemTime) deadline scope authenticatedClient command
      prepared <- must <$> sendBirth (PrepareRpcBirth 1 keyA)
      rpcBirthStatusPhase prepared `shouldBe` BirthPrepared
      observed <-
        must
          <$> requestRpcBirthDescriptorWithin (Right <$> rpcBirthSystemTime) deadline scope authenticatedClient
      original <- maybe (fail "original descriptor missing") pure (rpcBirthObservationDescriptor observed)
      rpcBirthDescriptorDeadline original `shouldBe` deadline
      rpcBirthDescriptorKey original `shouldBe` keyA
      rpcBirthObservationRequiresRegistration observed `shouldBe` False
      configured <- pin fixture
      writeIORef modeRef configured
      completed <- must <$> sendBirth (CompleteRpcBirth 1 keyA)
      rpcBirthStatusCommitted completed `shouldBe` True
      committed <-
        must
          <$> requestRpcBirthDescriptorWithin (Right <$> rpcBirthSystemTime) deadline scope authenticatedClient
      rpcBirthObservationRequiresRegistration committed `shouldBe` True
      rpcBirthObservationDescriptor committed `shouldBe` Just original
      readIORef epochReads `shouldReturn` 0
      readIORef routes
        `shouldReturn` [ "http://home.test/v1/authority/peer/observe"
                       , "http://home.test/v1/migration/apply"
                       , "http://home.test/v1/authority/peer/observe"
                       , "http://home.test/v1/migration/apply"
                       , "http://home.test/v1/authority/peer/observe"
                       , "http://home.test/v1/migration/apply"
                       , "http://home.test/v1/authority/peer/observe"
                       , "http://home.test/v1/migration/apply"
                       ]
      writeIORef deadlineReads 0
      (fixed, bounded) <-
        must <$> Transport.resolveAuthenticatedClientTransportDeadline deadline authenticatedClient
      _ <- must <$> requestRpcBirthDescriptorWithin (Right <$> rpcBirthSystemTime) fixed scope bounded
      _ <- must <$> requestRpcBirthDescriptorWithin (Right <$> rpcBirthSystemTime) fixed scope bounded
      readIORef deadlineReads `shouldReturn` 1
      readIORef requestDeadlines >>= (`shouldSatisfy` all (== deadline))
      forM_
        [ (const (200, "malformed"), RpcBirthClientResponseInvalid)
        , (\(_, body) -> (503, body), RpcBirthClientHttpStatus 503)
        ,
          ( const
              ( 409
              , Lazy.toStrict
                  (encodeControlPlaneResponse (Left RpcBirthStateInvalid :: Either RpcBirthError BS.ByteString))
              )
          , RpcBirthClientRejected RpcBirthStateInvalid
          )
        ]
        $ \(change, expected) -> do
          writeIORef responseOverride (Just change)
          requestRpcBirthDescriptorWithin (Right <$> rpcBirthSystemTime) deadline scope authenticatedClient
            `shouldReturn` Left expected
      writeIORef responseOverride Nothing
      before <- readIORef routes
      requestRpcBirthDescriptorWithin (pure (Left "clock unavailable")) deadline scope authenticatedClient
        `shouldReturn` Left RpcBirthClientClockUnavailable
      requestRpcBirthDescriptorWithin (pure (Right deadline)) deadline scope authenticatedClient
        `shouldReturn` Left RpcBirthClientDeadlineReached
      readIORef routes `shouldReturn` before
      let slowProviders =
            providers
              { Transport.provideAuthenticatedClientDeadline = threadDelay 100000 >> pure (Right deadline)
              }
          slow = Transport.mkAuthenticatedClientTransport bounds slowProviders client
      start <- rpcBirthSystemTime
      requestRpcBirthDescriptorWithin
        (pure (Right start))
        (authorityTimeFromMicros (authorityTimeMicros start + 20000))
        scope
        slow
        `shouldReturn` Left RpcBirthClientTimedOut
      readIORef routes `shouldReturn` before
      let cancelledProviders = providers {Transport.provideAuthenticatedClientDeadline = throwIO ThreadKilled}
          cancelled = Transport.mkAuthenticatedClientTransport bounds cancelledProviders client
      interrupted <-
        try (requestRpcBirthDescriptorWithin (Right <$> rpcBirthSystemTime) deadline scope cancelled)
      (interrupted :: Either AsyncException (Either RpcBirthClientError RpcBirthDescriptorObservation))
        `shouldBe` Left ThreadKilled
      readAuthorityAdmission (rpcBirthNativeAdmissionRepository backend configured legacy)
        >>= ( \result ->
                fmap (authorityAggregateRpcKeyRegistry . authorityAdmissionSnapshotState) result
                  `shouldBe` Right (Just seeded)
            )

  registeredColdRecoveryCases
  descriptorObservationCases
  registryObservationCases
  ownBindingHintCases
  coordinatorCases
  coordinatorClientCases

coordinatorCases :: SuiteBuilder ()
coordinatorCases = describe "registration coordinator" $ do
  forM_
    [ (0, keyA)
    , (1, "")
    , (1, Text.replicate 32 "A")
    , (1, Text.replicate 31 "a")
    , (1, Text.replicate 32 "g")
    ]
    $ \(generation, key) ->
      it ("rejects an invalid stable request " <> show (generation, key)) $
        isLeft
          (Coordinator.mkRpcBirthCoordinationRequest scope (authorityTimeFromMicros 2000000) generation key)
          `shouldBe` True

  forM_ [CoordHealthy, CoordLosePrepareReply, CoordLoseCompleteReply] $ \fault ->
    it ("commits only observed matching source/runtime and tolerates " <> show fault) $ do
      fixture <- newFixture >>= newCoordinationFixture
      result <- must <$> runCoordinationFixture fixture fault 2000000 1 keyA
      rpcBirthStatusCommitted (Coordinator.coordinatedRpcBirthStatus result) `shouldBe` True
      rpcBirthDescriptorDeadline (Coordinator.coordinatedRpcBirthDescriptor result)
        `shouldBe` authorityTimeFromMicros 2000000
      readIORef (coordCalls fixture)
        `shouldReturn` [ CoordSubmit (PrepareRpcBirth 1 keyA) 2000000
                       , CoordPublish 2000000
                       , CoordRollout 2000000
                       , CoordSubmit (CompleteRpcBirth 1 keyA) 2000000
                       ]
      (_, record) <- current (coordBase fixture)
      rpcBirthPhase record `shouldBe` BirthCommitted
      validateRpcBirthPredecessor (rpcBirthAdmission record) `shouldBe` Left RpcBirthLegacyStateRequired
      authorityAggregateMigration (rpcBirthAdmission record)
        `shouldSatisfy` migrationWritersRemainQuiesced

  forM_ [BirthPrepared, BirthArmed] $ \phase ->
    it ("resumes " <> show phase <> " with its original bound and no new prepare") $ do
      fixture <- coldFixture phase >>= newCoordinationFixture
      result <- must <$> runCoordinationFixture fixture CoordHealthy 4000000 1 keyA
      rpcBirthDescriptorDeadline (Coordinator.coordinatedRpcBirthDescriptor result)
        `shouldBe` authorityTimeFromMicros 2000000
      readIORef (coordCalls fixture)
        `shouldReturn` [CoordPublish 2000000, CoordRollout 2000000, CoordSubmit (CompleteRpcBirth 1 keyA) 2000000]

  forM_ [CoordPublishAckOnly, CoordRolloutAckOnly, CoordRolloutFailed, CoordSourceChanges] $ \fault ->
    it ("does not complete after an unconfirmed physical boundary " <> show fault) $ do
      fixture <- newFixture >>= newCoordinationFixture
      runCoordinationFixture fixture fault 2000000 1 keyA >>= (`shouldSatisfy` isLeft)
      calls <- readIORef (coordCalls fixture)
      calls
        `shouldBe` ( [CoordSubmit (PrepareRpcBirth 1 keyA) 2000000, CoordPublish 2000000]
                       <> [CoordRollout 2000000 | fault /= CoordPublishAckOnly]
                   )
      (_, record) <- current (coordBase fixture)
      rpcBirthPhase record `shouldBe` BirthPrepared

  it "reconfirms idempotent source durability after a lost publication reply" $ do
    fixture <- newFixture >>= newCoordinationFixture
    runCoordinationFixture fixture CoordLosePublishReply 2000000 1 keyA >>= (`shouldSatisfy` isLeft)
    readIORef (coordSource fixture) >>= (`shouldSatisfy` (/= RpcBirthConfigLegacy))
    writeIORef (coordCalls fixture) []
    _ <- must <$> runCoordinationFixture fixture CoordHealthy 2000000 1 keyA
    readIORef (coordCalls fixture)
      `shouldReturn` [CoordPublish 2000000, CoordRollout 2000000, CoordSubmit (CompleteRpcBirth 1 keyA) 2000000]

  it "refuses a foreign source before preparation" $ do
    fixture <- newFixture >>= newCoordinationFixture
    writeIORef
      (coordSource fixture)
      (RpcBirthConfigRegistered (RpcBirthConfigPin "home" 1 (Text.replicate 64 "f")))
    runCoordinationFixture fixture CoordHealthy 2000000 1 keyA
      `shouldReturn` Left Coordinator.RpcBirthCoordinationSourceConflict
    readIORef (coordCalls fixture) `shouldReturn` []

  it "does not renew expired preparation under a new parent" $ do
    fixture <- preparedFixture >>= newCoordinationFixture
    writeIORef (clock (coordBase fixture)) 3000000
    (_, record) <- current (coordBase fixture)
    let descriptor = maybe (error "prepared descriptor") id (rpcBirthDescriptor record)
    runCoordinationFixture fixture CoordHealthy 4000000 1 keyA
      `shouldReturn` Left (Coordinator.RpcBirthCoordinationPreparationExpired descriptor)
    readIORef (coordCalls fixture) `shouldReturn` []

  it "rejects late rollout and preserves its published fence" $ do
    fixture <- newFixture >>= newCoordinationFixture
    runCoordinationFixture fixture CoordLateRollout 2000000 1 keyA
      `shouldReturn` Left (Coordinator.RpcBirthCoordinationDeadlineReached Coordinator.CoordinationReconcileRuntime)
    readIORef (coordCalls fixture)
      `shouldReturn` [CoordSubmit (PrepareRpcBirth 1 keyA) 2000000, CoordPublish 2000000, CoordRollout 2000000]
    readIORef (coordSource fixture) >>= (`shouldSatisfy` (/= RpcBirthConfigLegacy))

  it "propagates cancellation without aborting or clearing the pin" $ do
    fixture <- newFixture >>= newCoordinationFixture
    interrupted <- try (runCoordinationFixture fixture CoordCancelRollout 2000000 1 keyA)
    ( interrupted
        :: Either
             AsyncException
             (Either Coordinator.RpcBirthCoordinationError Coordinator.RpcBirthCoordinationResult)
      )
      `shouldBe` Left ThreadKilled
    readIORef (coordCalls fixture)
      `shouldReturn` [CoordSubmit (PrepareRpcBirth 1 keyA) 2000000, CoordPublish 2000000, CoordRollout 2000000]
    readIORef (coordSource fixture) >>= (`shouldSatisfy` (/= RpcBirthConfigLegacy))

  it "reads back an existing commitment after its preparation deadline without replaying deployment" $ do
    fixture <- coldFixture BirthCommitted >>= newCoordinationFixture
    mode <- pin (coordBase fixture)
    writeIORef (coordServing fixture) mode
    (_, record) <- current (coordBase fixture)
    let descriptor = maybe (error "committed descriptor") id (rpcBirthDescriptor record)
    writeIORef (coordSource fixture) (coordPin descriptor)
    writeIORef (clock (coordBase fixture)) 3000000
    result <- must <$> runCoordinationFixture fixture CoordHealthy 4000000 1 keyA
    Coordinator.coordinatedRpcBirthDescriptor result `shouldBe` descriptor
    readIORef (coordCalls fixture) `shouldReturn` [CoordPublish 4000000]

  it "requires explicit retirement recovery before new preparation" $ do
    fixture <- coldFixture BirthRetiring >>= newCoordinationFixture
    runCoordinationFixture fixture CoordHealthy 2000000 1 keyA >>= (`shouldSatisfy` isLeft)
    readIORef (coordCalls fixture) `shouldReturn` []

  it "does not turn a successful completion acknowledgement into a commitment" $ do
    fixture <- newFixture >>= newCoordinationFixture
    runCoordinationFixture fixture CoordCompleteAckOnly 2000000 1 keyA
      `shouldReturn` Left (Coordinator.RpcBirthCoordinationObservationInvalid Coordinator.CoordinationObserveCompleted)
    (_, record) <- current (coordBase fixture)
    rpcBirthPhase record `shouldBe` BirthPrepared

  it "recovers a committed operation after its late reply using a fresh observation bound" $ do
    fixture <- newFixture >>= newCoordinationFixture
    runCoordinationFixture fixture CoordLateComplete 2000000 1 keyA
      `shouldReturn` Left (Coordinator.RpcBirthCoordinationDeadlineReached Coordinator.CoordinationComplete)
    (_, record) <- current (coordBase fixture)
    rpcBirthPhase record `shouldBe` BirthCommitted
    writeIORef (coordCalls fixture) []
    result <- must <$> runCoordinationFixture fixture CoordHealthy 4000000 1 keyA
    rpcBirthDescriptorDeadline (Coordinator.coordinatedRpcBirthDescriptor result)
      `shouldBe` authorityTimeFromMicros 2000000
    readIORef (coordCalls fixture) `shouldReturn` [CoordPublish 4000000]

coordinatorClientCases :: SuiteBuilder ()
coordinatorClientCases = describe "coordinator signed client and native source composition" $ do
  forM_ [(20000000, 40000000), (40000000, 20000000)] $ \(providerOffset, parentOffset) ->
    it
      ( "resolves one original bound and commits through native source CAS "
          <> show (providerOffset, parentOffset)
      )
      $ withHomeVault HomeHealthy
      $ \session _ ->
        withSystemTempDirectory "prodbox-coordinator-client" $ \directory -> do
          fixture <- newFixture >>= newCoordinationFixture
          let path = directory </> "prodbox.dhall"
              project =
                syntheticProjectConfig
                  { Tier0.context = (Tier0.context syntheticProjectConfig) {Tier0.cluster_id = "home"}
                  }
          Tier0.writeTier0AtPath path project `shouldReturn` Right ()
          now <- rpcBirthSystemTime
          let providerBound = authorityTimeFromMicros (authorityTimeMicros now + providerOffset)
              parent = authorityTimeFromMicros (authorityTimeMicros now + parentOffset)
              expected = min parent providerBound
          deadlineReads <- newIORef (0 :: Int)
          frames <- newIORef []
          transport <-
            coordinatorFixtureTransport
              fixture
              session
              ( do
                  count <- atomicModifyIORef' deadlineReads (\count -> (count + 1, count + 1))
                  pure (if count == 1 then Right providerBound else Left "deadline provider resolved more than once")
              )
              frames
          let rollout =
                Coordinator.coordinationReconcileRuntime
                  (Coordinator.coordinationPublication (coordinationFixtureEffects fixture CoordHealthy 1 keyA))
              publication = tier0RpcBirthPublicationAtPath scope path rollout
          result <-
            must
              <$> Coordinator.coordinateRpcBirthWithTransport
                (Right <$> rpcBirthSystemTime)
                scope
                parent
                1
                keyA
                transport
                publication
          let descriptor = Coordinator.coordinatedRpcBirthDescriptor result
          rpcBirthDescriptorDeadline descriptor `shouldBe` expected
          rpcBirthStatusCommitted (Coordinator.coordinatedRpcBirthStatus result) `shouldBe` True
          readIORef deadlineReads `shouldReturn` 1
          observedFrames <- readIORef frames
          length observedFrames `shouldSatisfy` (>= 8)
          observedFrames `shouldSatisfy` all (== expected)
          Tier0.observeTier0RpcRegistrationAtPath path `shouldReturn` Right (scope, coordPin descriptor)
          readIORef (coordCalls fixture) `shouldReturn` [CoordRollout (authorityTimeMicros expected)]

  it "bounds a deadline provider that never returns before touching source or RPC" $
    withHomeVault HomeHealthy $ \session _ -> do
      fixture <- newFixture >>= newCoordinationFixture
      gate <- newEmptyMVar
      frames <- newIORef []
      transport <- coordinatorFixtureTransport fixture session (takeMVar gate) frames
      now <- rpcBirthSystemTime
      let parent = authorityTimeFromMicros (authorityTimeMicros now + 20000)
          publication = Coordinator.coordinationPublication (coordinationFixtureEffects fixture CoordHealthy 1 keyA)
      Coordinator.coordinateRpcBirthWithTransport
        (Right <$> rpcBirthSystemTime)
        scope
        parent
        1
        keyA
        transport
        publication
        `shouldReturn` Left (Coordinator.RpcBirthCoordinationDeadlineReached Coordinator.CoordinationResolveTransport)
      readIORef frames `shouldReturn` []
      readIORef (coordCalls fixture) `shouldReturn` []

  it "rejects invalid caller input before resolving a blocked provider" $
    withHomeVault HomeHealthy $ \session _ -> do
      fixture <- newFixture >>= newCoordinationFixture
      gate <- newEmptyMVar
      deadlineAttempts <- newIORef (0 :: Int)
      frames <- newIORef []
      transport <-
        coordinatorFixtureTransport
          fixture
          session
          (modifyIORef' deadlineAttempts (+ 1) >> takeMVar gate)
          frames
      now <- rpcBirthSystemTime
      let parent = authorityTimeFromMicros (authorityTimeMicros now + 20000)
          publication = Coordinator.coordinationPublication (coordinationFixtureEffects fixture CoordHealthy 1 keyA)
      Coordinator.coordinateRpcBirthWithTransport
        (Right <$> rpcBirthSystemTime)
        scope
        parent
        1
        "bad"
        transport
        publication
        `shouldReturn` Left Coordinator.RpcBirthCoordinationRequestInvalid
      readIORef deadlineAttempts `shouldReturn` 0
      readIORef frames `shouldReturn` []

  it "propagates asynchronous cancellation from deadline resolution" $
    withHomeVault HomeHealthy $ \session _ -> do
      fixture <- newFixture >>= newCoordinationFixture
      frames <- newIORef []
      transport <- coordinatorFixtureTransport fixture session (throwIO ThreadKilled) frames
      now <- rpcBirthSystemTime
      let parent = authorityTimeFromMicros (authorityTimeMicros now + 1000000)
          publication = Coordinator.coordinationPublication (coordinationFixtureEffects fixture CoordHealthy 1 keyA)
      interrupted <-
        try
          ( Coordinator.coordinateRpcBirthWithTransport
              (Right <$> rpcBirthSystemTime)
              scope
              parent
              1
              keyA
              transport
              publication
          )
      ( interrupted
          :: Either
               AsyncException
               (Either Coordinator.RpcBirthCoordinationError Coordinator.RpcBirthCoordinationResult)
        )
        `shouldBe` Left ThreadKilled
      readIORef frames `shouldReturn` []

coordinatorFixtureTransport
  :: CoordinationFixture
  -> VaultSession
  -> IO (Either Text AuthorityTime)
  -> IORef [AuthorityTime]
  -> IO (Transport.AuthenticatedClientTransport 'LifecycleAuthorityRuntime)
coordinatorFixtureTransport fixture session deadlineProvider frames = do
  coordinatorFixtureTransportWithServing fixture session deadlineProvider frames (pure Nothing)

-- The native host fixture executes the real command/ownership interpreter while
-- its synthetic protocol boundary independently reads the applied role config.
withRpcBirthCoordinatorNativeFixture
  :: AuthorityTime
  -> IO (Maybe RpcBirthServingMode)
  -> ( Transport.AuthenticatedClientTransport 'LifecycleAuthorityRuntime
       -> IO (RpcBirthPhase, [AuthorityTime])
       -> IO value
     )
  -> IO value
withRpcBirthCoordinatorNativeFixture deadline observeServing action =
  withRpcBirthCoordinatorWireFixture deadline observeServing $ \bounds providers wire probe -> do
    let client =
          must
            ( Client.controlPlaneClientWithTransport
                65536
                (must (Client.mkLifecycleAuthorityEndpoint "http://home.test"))
                wire
            )
    action (Transport.mkAuthenticatedClientTransport bounds providers client) probe

-- The owned transport fixture supplies a real listener and forwarding process;
-- this boundary retains the independently authenticated protocol and Vault state.
withRpcBirthCoordinatorWireFixture
  :: AuthorityTime
  -> IO (Maybe RpcBirthServingMode)
  -> ( Transport.AuthenticatedTransportBounds
       -> Transport.AuthenticatedClientProviders IO
       -> Client.ControlPlaneTransport
       -> IO (RpcBirthPhase, [AuthorityTime])
       -> IO value
     )
  -> IO value
withRpcBirthCoordinatorWireFixture deadline observeServing action =
  withRpcBirthCoordinatorWireFixtureStarting [] Nothing deadline observeServing $ \_ _ -> action

withRpcBirthPreparedCoordinatorWireFixture
  :: AuthorityTime
  -> IO (Maybe RpcBirthServingMode)
  -> ( RpcBirthConfig
       -> RpcKeyRegistryObserver IO
       -> Transport.AuthenticatedTransportBounds
       -> Transport.AuthenticatedClientProviders IO
       -> Client.ControlPlaneTransport
       -> IO (RpcBirthPhase, [AuthorityTime])
       -> IO value
     )
  -> IO value
withRpcBirthPreparedCoordinatorWireFixture =
  withRpcBirthPreparedCoordinatorRegistryWireFixture []

withRpcBirthPreparedCoordinatorWireFixtureForKey
  :: Text
  -> AuthorityTime
  -> IO (Maybe RpcBirthServingMode)
  -> ( RpcBirthConfig
       -> RpcKeyRegistryObserver IO
       -> Transport.AuthenticatedTransportBounds
       -> Transport.AuthenticatedClientProviders IO
       -> Client.ControlPlaneTransport
       -> IO (RpcBirthPhase, [AuthorityTime])
       -> IO value
     )
  -> IO value
withRpcBirthPreparedCoordinatorWireFixtureForKey key =
  withRpcBirthCoordinatorWireFixtureStarting [] (Just (1, key))

withRpcBirthPreparedCoordinatorRegistryWireFixture
  :: [RpcObservedKey]
  -> AuthorityTime
  -> IO (Maybe RpcBirthServingMode)
  -> ( RpcBirthConfig
       -> RpcKeyRegistryObserver IO
       -> Transport.AuthenticatedTransportBounds
       -> Transport.AuthenticatedClientProviders IO
       -> Client.ControlPlaneTransport
       -> IO (RpcBirthPhase, [AuthorityTime])
       -> IO value
     )
  -> IO value
withRpcBirthPreparedCoordinatorRegistryWireFixture keys =
  withRpcBirthCoordinatorWireFixtureStarting keys (Just (1, keyA))

withRpcBirthCoordinatorWireFixtureStarting
  :: [RpcObservedKey]
  -> Maybe (Natural, Text)
  -> AuthorityTime
  -> IO (Maybe RpcBirthServingMode)
  -> ( RpcBirthConfig
       -> RpcKeyRegistryObserver IO
       -> Transport.AuthenticatedTransportBounds
       -> Transport.AuthenticatedClientProviders IO
       -> Client.ControlPlaneTransport
       -> IO (RpcBirthPhase, [AuthorityTime])
       -> IO value
     )
  -> IO value
withRpcBirthCoordinatorWireFixtureStarting keys preparation deadline observeServing action =
  withHomeVault HomeHealthy $ \session _ -> do
    base <- newFixture
    let table =
          must
            ( mkRegisteredClientTable
                (registeredClientTableCapacity clients + fromIntegral (length keys))
                (registeredClientTableSpecifications clients)
            )
    unless (null keys) $
      writeIORef
        (primary base)
        (ModelBObserved (version 1) (must (rpcBirthLegacy (legacyWithClients table))))
    fixture <- newCoordinationFixture base
    let backend =
          nativeWritableBackendWithClients
            table
            (coordBase fixture)
            (observeCompatibleHomeRpcSeed scope session legacyTrust)
    registration <- case preparation of
      Nothing -> pure RpcBirthConfigLegacy
      Just (generation, key) -> do
        now <- rpcBirthSystemTime
        let request =
              signedWithLifetime
                60000000
                CallerOperatorCli
                (encodeRpcBirthCommand (PrepareRpcBirth generation key))
                (authorityTimeMicros now)
                (authorityTimeMicros deadline)
            prepared = must (mkRpcBirthContext scope legacyRpcBirthServingMode request)
        _ <- must <$> executeRpcBirth (rpcBirthNativeInterpreter backend) prepared
        (_, record) <- current (coordBase fixture)
        descriptor <- maybe (fail "prepared fixture descriptor missing") pure (rpcBirthDescriptor record)
        unless (null keys) $ do
          let completion =
                signedWithLifetime
                  60000000
                  CallerOperatorCli
                  (encodeRpcBirthCommand (CompleteRpcBirth generation key))
                  (authorityTimeMicros now)
                  (authorityTimeMicros deadline)
          _ <-
            must
              <$> executeRpcBirth
                (rpcBirthNativeInterpreter backend)
                (must (mkRpcBirthContext scope (mustPin descriptor) completion))
          (revision, committed) <- current (coordBase fixture)
          let aggregate = must (foldM (flip enrollAuthorityRpcKey) (rpcBirthAdmission committed) keys)
              registered = must (replaceRpcBirthAdmission committed aggregate)
          writeIORef (primary (coordBase fixture)) (ModelBObserved revision registered)
        writeIORef (coordServing fixture) (mustPin descriptor)
        pure (coordPin descriptor)
    frames <- newIORef []
    let wireTrust =
          must
            ( registeredRpcRouteTrust
                LifecycleAuthorityRuntime
                (Transport.routeTrustRegistryMaximumKeys legacyTrust + fromIntegral (length keys))
                seeded
            )
    (bounds, providers, wire) <-
      coordinatorFixtureComponentsWithTrust
        wireTrust
        fixture
        session
        (pure (Right deadline))
        frames
        observeServing
    let observer = RpcKeyRegistryObserver $ do
          mode <- readIORef (coordServing fixture)
          observed <- observeRpcBirthRuntimeRegistry backend mode
          pure $ case observed of
            Right (Just registry) -> Right registry
            _ -> Left RpcKeyBindingMissing
    action registration observer bounds providers wire $ do
      (_, record) <- current (coordBase fixture)
      observedFrames <- readIORef frames
      pure (rpcBirthPhase record, observedFrames)

coordinatorFixtureTransportWithServing
  :: CoordinationFixture
  -> VaultSession
  -> IO (Either Text AuthorityTime)
  -> IORef [AuthorityTime]
  -> IO (Maybe RpcBirthServingMode)
  -> IO (Transport.AuthenticatedClientTransport 'LifecycleAuthorityRuntime)
coordinatorFixtureTransportWithServing fixture session deadlineProvider frames observeServing = do
  (bounds, providers, wire) <-
    coordinatorFixtureComponents fixture session deadlineProvider frames observeServing
  let client =
        must
          ( Client.controlPlaneClientWithTransport
              65536
              (must (Client.mkLifecycleAuthorityEndpoint "http://home.test"))
              wire
          )
  pure (Transport.mkAuthenticatedClientTransport bounds providers client)

coordinatorFixtureComponents
  :: CoordinationFixture
  -> VaultSession
  -> IO (Either Text AuthorityTime)
  -> IORef [AuthorityTime]
  -> IO (Maybe RpcBirthServingMode)
  -> IO
       ( Transport.AuthenticatedTransportBounds
       , Transport.AuthenticatedClientProviders IO
       , Client.ControlPlaneTransport
       )
coordinatorFixtureComponents = coordinatorFixtureComponentsWithTrust legacyTrust

coordinatorFixtureComponentsWithTrust
  :: Transport.RouteTrustRegistry
  -> CoordinationFixture
  -> VaultSession
  -> IO (Either Text AuthorityTime)
  -> IORef [AuthorityTime]
  -> IO (Maybe RpcBirthServingMode)
  -> IO
       ( Transport.AuthenticatedTransportBounds
       , Transport.AuthenticatedClientProviders IO
       , Client.ControlPlaneTransport
       )
coordinatorFixtureComponentsWithTrust configuredTrust fixture session deadlineProvider frames observeServing = do
  nonces <- newIORef (0 :: Int)
  let bounds = must (Transport.mkAuthenticatedTransportBounds 65536 1024 65000)
      lifetime = must (authorityDurationFromMicros 60000000)
      backend =
        nativeWritableBackend (coordBase fixture) (observeCompatibleHomeRpcSeed scope session legacyTrust)
      peerRead :: AuthorityPeerContextProgram value -> IO (Either AuthorityPeerContextError value)
      peerRead program = case program of
        ReadPeerContextTime -> Right <$> rpcBirthSystemTime
        ReadPeerContextEpoch _ -> pure (Right authorityEpochGenesis)
        ReadPeerContextIssuer _ ->
          pure
            ( Right
                ( must (mkTargetIssuerKeyGeneration 1)
                , must
                    ( mkTargetIntentPublicKey
                        (requestSignerPublicKeyBytes (signer (CallerService LifecycleAuthorityRuntime)))
                    )
                )
            )
      wire _ _ url frame = do
        independentlyServing <- observeServing
        maybe (pure ()) (writeIORef (coordServing fixture)) independentlyServing
        mode <- readIORef (coordServing fixture)
        let route =
              if "/peer/observe" `Text.isSuffixOf` Text.pack url
                then LifecycleAuthorityPeerObserve
                else LifecycleMigrationApply
            serverProviders =
              Transport.AuthenticatedServerProviders
                (pure (Right scope))
                (pure (Right authorityEpochGenesis))
                (Right <$> rpcBirthSystemTime)
                ( do
                    (record, marker) <- observeRpcBirthNativeRecords backend
                    pure (first (Text.pack . show) (rpcBirthRuntimeTrust mode configuredTrust record marker))
                )
        authenticated <-
          Transport.authenticateControlPlaneFrame
            bounds
            lifetime
            serverProviders
            LifecycleAuthorityRuntime
            route
            (Lazy.fromStrict frame)
        case authenticated of
          Left (Transport.AuthenticatedServerRequestAuthenticationFailed _) ->
            pure (Right (401, "fixture-authentication-refused"))
          Left cause -> fail (show cause)
          Right verified -> do
            let request = Transport.authenticatedServerVerifiedRequest verified
            modifyIORef' frames (<> [verifiedRequestDeadline request])
            response <-
              if route == LifecycleAuthorityPeerObserve
                then authorityPeerContextVerifiedHandler scope (AuthorityPeerContextInterpreter peerRead) request
                else rpcBirthVerifiedHandler scope mode backend request
            case response of
              Nothing -> fail "coordinator fixture did not match its fixed route"
              Just (status, body) -> pure (Right (replyStatusCode status, body))
      clientProviders =
        Transport.AuthenticatedClientProviders
          (pure (Right (localRequestSigningCapability (signer CallerOperatorCli))))
          (pure (Right scope))
          (pure (Left "ordinary admission is frozen"))
          deadlineProvider
          ( do
              count <- atomicModifyIORef' nonces (\count -> (count + 1, count + 1))
              pure (Right (must (mkRequestNonce (BS.replicate 16 (fromIntegral count)))))
          )
  pure (bounds, clientProviders, wire)

data CoordinationFault
  = CoordHealthy
  | CoordLosePrepareReply
  | CoordLoseCompleteReply
  | CoordLosePublishReply
  | CoordPublishAckOnly
  | CoordRolloutAckOnly
  | CoordRolloutFailed
  | CoordSourceChanges
  | CoordLateRollout
  | CoordCancelRollout
  | CoordCompleteAckOnly
  | CoordLateComplete
  deriving (Eq, Show)

data CoordinationCall = CoordSubmit RpcBirthCommand Natural | CoordPublish Natural | CoordRollout Natural
  deriving (Eq, Show)

data CoordinationFixture = CoordinationFixture
  { coordBase :: Fixture
  , coordSource :: IORef RpcBirthConfig
  , coordServing :: IORef RpcBirthServingMode
  , coordCalls :: IORef [CoordinationCall]
  }

newCoordinationFixture :: Fixture -> IO CoordinationFixture
newCoordinationFixture base =
  CoordinationFixture base
    <$> newIORef RpcBirthConfigLegacy
    <*> newIORef legacyRpcBirthServingMode
    <*> newIORef []

runCoordinationFixture
  :: CoordinationFixture
  -> CoordinationFault
  -> Natural
  -> Natural
  -> Text
  -> IO (Either Coordinator.RpcBirthCoordinationError Coordinator.RpcBirthCoordinationResult)
runCoordinationFixture fixture fault deadline generation key =
  Coordinator.coordinateRpcBirth
    (coordinationFixtureEffects fixture fault generation key)
    ( must
        (Coordinator.mkRpcBirthCoordinationRequest scope (authorityTimeFromMicros deadline) generation key)
    )

coordinationFixtureEffects
  :: CoordinationFixture
  -> CoordinationFault
  -> Natural
  -> Text
  -> Coordinator.RpcBirthCoordinationEffects IO
coordinationFixtureEffects fixture fault generation key = effects
 where
  base = coordBase fixture
  note call = modifyIORef' (coordCalls fixture) (<> [call])
  effects =
    Coordinator.RpcBirthCoordinationEffects
      (Right . authorityTimeFromMicros <$> readIORef (clock base))
      ( \bound -> do
          mode <- readIORef (coordServing fixture)
          now <- readIORef (clock base)
          either (Left . RpcBirthClientRejected) Right
            <$> observeDescriptor base mode now (authorityTimeMicros bound)
      )
      ( \bound command -> do
          note (CoordSubmit command (authorityTimeMicros bound))
          mode <- readIORef (coordServing fixture)
          now <- readIORef (clock base)
          result <-
            if fault == CoordCompleteAckOnly && command == CompleteRpcBirth generation key
              then do
                (_, record) <- current base
                pure
                  ( Right
                      ( RpcBirthStatus
                          BirthCommitted
                          generation
                          True
                          (rpcBirthDescriptorDigest <$> rpcBirthDescriptor record)
                      )
                  )
              else executeRpcBirth (interpreter base) (context mode command now (authorityTimeMicros bound))
          if fault == CoordLateComplete && command == CompleteRpcBirth generation key
            then writeIORef (clock base) 3000000
            else pure ()
          pure $
            if (fault == CoordLosePrepareReply && command == PrepareRpcBirth generation key)
              || (fault == CoordLoseCompleteReply && command == CompleteRpcBirth generation key)
              then Left RpcBirthClientTimedOut
              else either (Left . RpcBirthClientRejected) Right result
      )
      ( Coordinator.RpcBirthPublicationEffects
          (\_ -> Right <$> readIORef (coordSource fixture))
          ( \bound expected desired -> do
              note (CoordPublish (authorityTimeMicros bound))
              actual <- readIORef (coordSource fixture)
              if expected /= RpcBirthConfigLegacy || actual `notElem` [expected, desired]
                then pure (Left "source CAS conflict")
                else do
                  if fault == CoordPublishAckOnly then pure () else writeIORef (coordSource fixture) desired
                  pure (if fault == CoordLosePublishReply then Left "publication reply lost" else Right ())
          )
          ( \bound descriptor -> do
              note (CoordRollout (authorityTimeMicros bound))
              case fault of
                CoordRolloutFailed -> pure (Left "rollout failed")
                CoordCancelRollout -> throwIO ThreadKilled
                CoordRolloutAckOnly -> pure (Right ())
                _ -> do
                  writeIORef (coordServing fixture) (mustPin descriptor)
                  if fault == CoordSourceChanges
                    then
                      writeIORef
                        (coordSource fixture)
                        (RpcBirthConfigRegistered (RpcBirthConfigPin "home" 1 (Text.replicate 64 "f")))
                    else pure ()
                  if fault == CoordLateRollout then writeIORef (clock base) 3000000 else pure ()
                  pure (Right ())
          )
      )

coordPin :: RpcBirthDescriptor -> RpcBirthConfig
coordPin descriptor =
  RpcBirthConfigRegistered
    ( RpcBirthConfigPin
        "home"
        (rpcBirthDescriptorGeneration descriptor)
        (rpcBirthDescriptorDigest descriptor)
    )

registeredColdRecoveryCases :: SuiteBuilder ()
registeredColdRecoveryCases = describe "registered cold recovery" $ do
  forM_ [BirthPrepared, BirthArmed, BirthCommitted, BirthRetiring, BirthRetired] $ \phase ->
    it ("selects retained clients without changing existing bytes for " <> show phase) $ do
      fixture <- coldFixture phase
      mode <- pin fixture
      (_, record) <- current fixture
      let pinned = must (rpcBirthPinnedRecordCodec 524288 4 8 scope mode)
          bytes = must (encodeModelBValue codec record)
      encodeModelBValue pinned record `shouldBe` Right bytes
      decodeModelBValue pinned bytes `shouldBe` Right record
      decodeModelBValue pinned (bytes <> "trailing") `shouldSatisfy` isLeft
      let wrong = must (registeredRpcBirthServingMode scope 2 (Text.replicate 64 "a"))
      decodeModelBValue (must (rpcBirthPinnedRecordCodec 524288 4 8 scope wrong)) bytes
        `shouldSatisfy` isLeft

  forM_ [BirthPrepared, BirthArmed, BirthCommitted, BirthRetiring, BirthRetired] $ \phase ->
    it ("round-trips the immutable historical schema-one bytes for " <> show phase) $ do
      (record, bytes) <- historicalRecord phase
      rpcBirthRecordFormat record `shouldBe` Just RpcBirthHistoricalV1
      encodeModelBValue codec record `shouldBe` Right bytes
      let descriptor = maybe (error "historical descriptor") id (rpcBirthDescriptor record)
          mode = mustPin descriptor
      encodeModelBValue (must (rpcBirthPinnedRecordCodec 524288 4 8 scope mode)) record
        `shouldBe` Right bytes
      fixture <- coldFixture phase
      (_, currentRecord) <- current fixture
      rpcBirthRecordFormat currentRecord `shouldBe` Just RpcBirthDurableV2
      rpcBirthDescriptor currentRecord `shouldBe` rpcBirthDescriptor record
      rpcBirthAdmission currentRecord `shouldBe` rpcBirthAdmission record

  it "keeps durable retired provenance independently of pending-candidate and inner quiescence" $ do
    fixture <- coldFixture BirthRetired
    (_, record) <- current fixture
    rpcBirthCandidate record `shouldBe` Nothing
    rpcBirthPublicSeed record `shouldBe` Just seeded
    let replaced = must (replaceRpcBirthAdmission record initial)
    rpcBirthPublicSeed replaced `shouldBe` Just seeded
    rpcBirthAdmission replaced `shouldBe` initial
    decodeModelBValue codec (must (encodeModelBValue codec replaced)) `shouldBe` Right replaced

  forM_ [BirthPrepared, BirthArmed] $ \phase ->
    it ("upgrades source-known historical retirement while preserving identities for " <> show phase) $ do
      fixture <- historicalFixture phase
      mode <- pin fixture
      (_, old) <- current fixture
      _ <- must <$> run fixture mode (AbortRpcBirth 1 keyA)
      (_, retired) <- current fixture
      rpcBirthRecordFormat retired `shouldBe` Just RpcBirthDurableV2
      rpcBirthPublicSeed retired `shouldBe` Just seeded
      rpcBirthDescriptor retired `shouldBe` rpcBirthDescriptor old
      rpcBirthAdmission retired `shouldBe` rpcBirthAdmission old

  forM_ [BirthRetiring, BirthRetired] $ \phase ->
    it ("retains provenance within the already admitted preparation footprint for " <> show phase) $ do
      prepared <- coldFixture BirthPrepared
      (_, before) <- current prepared
      fixture <- coldFixture phase
      (_, after) <- current fixture
      BS.length (must (encodeModelBValue codec after))
        `shouldBe` BS.length (must (encodeModelBValue codec before))

  forM_
    [
      ( "unknown schema"
      , \(UncheckedRetainedBirth _ phase descriptor candidate inner) ->
          UncheckedRetainedBirth 3 phase descriptor candidate inner
      )
    ,
      ( "missing durable seed"
      , \(UncheckedRetainedBirth schema phase descriptor _ inner) ->
          UncheckedRetainedBirth schema phase descriptor Nothing inner
      )
    ,
      ( "public seed on historical retirement"
      , \(UncheckedRetainedBirth _ phase descriptor candidate inner) ->
          UncheckedRetainedBirth 1 phase descriptor candidate inner
      )
    ,
      ( "malformed durable seed"
      , \(UncheckedRetainedBirth schema phase descriptor _ inner) ->
          UncheckedRetainedBirth schema phase descriptor (Just "invalid") inner
      )
    ]
    $ \(name, corrupt) ->
      it ("refuses retired record " <> name) $ do
        fixture <- coldFixture BirthRetired
        (_, record) <- current fixture
        let prefix = "prodbox-rpc-birth/v1\NUL"
            bytes = must (encodeModelBValue codec record)
            raw = maybe (error "fixture prefix") id (BS.stripPrefix prefix bytes)
            wire = must (deserialiseOrFail (Lazy.fromStrict raw))
            bad = prefix <> Lazy.toStrict (serialise (corrupt wire))
        decodeModelBValue codec bad `shouldSatisfy` isLeft

  it "finishes a seedless historical retirement without inventing provenance" $ do
    fixture <- historicalFixture BirthRetiring
    mode <- pin fixture
    _ <- must <$> run fixture mode (AbortRpcBirth 1 keyA)
    (_, retired) <- current fixture
    rpcBirthRecordFormat retired `shouldBe` Just RpcBirthHistoricalV1
    rpcBirthPublicSeed retired `shouldBe` Nothing
    rpcBirthPhase retired `shouldBe` BirthRetired

  it "refuses a legacy reader, bare inner bytes and foreign scope under the pin" $ do
    fixture <- preparedFixture
    mode <- pin fixture
    let pinned = must (rpcBirthPinnedRecordCodec 524288 4 8 scope mode)
        otherScope = must (Coordinate.mkAuthorityScope "foreign")
    rpcBirthPinnedRecordCodec 524288 4 8 scope legacyRpcBirthServingMode `shouldSatisfy` isLeft
    encodeModelBValue pinned legacyRecord `shouldSatisfy` isLeft
    decodeModelBValue pinned (must (encodeModelBValue legacyCodec legacy)) `shouldSatisfy` isLeft
    (_, record) <- current fixture
    decodeModelBValue
      (must (rpcBirthPinnedRecordCodec 524288 4 8 otherScope mode))
      (must (encodeModelBValue codec record))
      `shouldSatisfy` isLeft

  it "rejects a valid inner table whose reservation bound differs from the pinned descriptor" $ do
    fixture <- preparedFixture
    mode <- pin fixture
    (_, record) <- current fixture
    let bytes = must (encodeModelBValue codec record)
        raw = maybe (error "missing fixture prefix") id (BS.stripPrefix "prodbox-rpc-birth/v1\NUL" bytes)
        UncheckedRetainedBirth wireVersion phase descriptor candidate _ =
          must (deserialiseOrFail (Lazy.fromStrict raw))
        otherClients =
          must
            ( mkRegisteredClientTable
                7
                [ must
                    ( mkRegisteredClientSpec
                        (clientPrincipalForCaller caller)
                        (must (mkRegisteredClientSlot (fromIntegral (callerPrincipalCode caller))))
                        (must (mkRegisteredClientGeneration 1))
                        5
                    )
                | caller <- trustedCallersForRoute LifecycleOperationSubmit
                ]
            )
        inner =
          must
            ( encodeModelBValue
                (authorityAdmissionStateCodec 524288 4 8)
                (legacyWithClients otherClients)
            )
        forged =
          "prodbox-rpc-birth/v1\NUL"
            <> Lazy.toStrict
              (serialise (UncheckedRetainedBirth wireVersion phase descriptor candidate inner))
        pinned = must (rpcBirthPinnedRecordCodec 524288 4 8 scope mode)
    decodeModelBValue pinned forged `shouldBe` Left "RpcBirthProfileMismatch"

  it "cold-resolves logical generation three to native version two without legacy capabilities" $
    withHomeVault HomeOwnKeyOnly $ \session _ -> do
      fixture <- coldFixture BirthCommitted
      mode <- pin fixture
      (revision, record) <- current fixture
      let principal = CallerService LifecycleAuthorityRuntime
          ref = controlPlaneSigningKeyRefFor principal
          otherScope = must (Coordinate.mkAuthorityScope "other")
          vault = must (mkRpcVaultIncarnation "11111111-1111-1111-1111-111111111111")
          remoteVault = must (mkRpcVaultIncarnation "22222222-2222-2222-2222-222222222222")
          observed origin native seedByte =
            must
              ( mkRpcObservedKey
                  origin
                  native
                  ( requestSignerPublicKeyBytes
                      ( must
                          ( mkRequestSigner
                              principal
                              (must (mkSigningKeyGeneration 1))
                              (BS.replicate 32 seedByte)
                          )
                      )
                  )
              )
          remoteKey = observed (mkRpcKeyOrigin otherScope remoteVault ref) 1 251
          homeKey = observed (mkRpcKeyOrigin scope vault ref) 2 250
          enrolled =
            must
              ( enrollAuthorityRpcKey
                  homeKey
                  (must (enrollAuthorityRpcKey remoteKey (rpcBirthAdmission record)))
              )
          selected =
            must
              ( retireAuthorityRpcKey
                  principal
                  (must (mkSigningKeyGeneration 2))
                  (must (retireAuthorityRpcKey principal (must (mkSigningKeyGeneration 1)) enrolled))
              )
          next = must (replaceRpcBirthAdmission record selected)
      writeIORef (primary fixture) (ModelBObserved revision next)
      let backend = nativeBackend fixture (fail "committed source read")
      recovery <- must <$> resolveRpcBirthRecoveryAuthentication backend mode scope session
      capability <- must <$> resolveRpcBirthRecoverySigner backend mode scope session recovery
      signingKeyGenerationValue (requestSigningCapabilityGeneration capability) `shouldBe` 3
      signature <- signCanonicalBytesWithRequestCapability capability "cold-mapped-three"
      expected <-
        signCanonicalBytesWithRequestCapability
          ( localRequestSigningCapability
              ( must
                  ( mkRequestSigner
                      principal
                      (must (mkSigningKeyGeneration 2))
                      (BS.replicate 32 250)
                  )
              )
          )
          "cold-mapped-three"
      signature `shouldBe` expected
      registeredClientTableCapacity
        (authorityAggregateRegisteredClients (rpcBirthRecoveryAggregate recovery))
        `shouldBe` 7

  forM_ [BirthPrepared, BirthArmed, BirthCommitted, BirthRetiring, BirthRetired] $ \phase ->
    it ("cold-resolves exact old signing version with unrelated keys unavailable for " <> show phase) $
      withHomeVault HomeOwnKeyOnly $ \session requests -> do
        fixture <- coldFixture phase
        mode <- pin fixture
        writeIORef (writes fixture) 0
        writeIORef (sourceReads fixture) 0
        let backend = nativeBackend fixture (fail "cold recovery read preparation source")
        recovery <- must <$> resolveRpcBirthRecoveryAuthentication backend mode scope session
        (_, record) <- current fixture
        rpcBirthRecoveryAggregate recovery `shouldBe` rpcBirthAdmission record
        let own = CallerService LifecycleAuthorityRuntime
            refresh = resolveRpcBirthRecoverySigner backend mode scope session recovery
        capability <- must <$> refresh
        requestSigningCapabilityGeneration capability `shouldBe` must (mkSigningKeyGeneration 1)
        actual <- must <$> signCanonicalBytesWithRequestCapability capability "cold-retained-native-one"
        expected <-
          must
            <$> signCanonicalBytesWithRequestCapability
              (localRequestSigningCapability (signer own))
              "cold-retained-native-one"
        actual `shouldBe` expected
        trust <- must <$> observeRpcBirthRecoveryTrust backend mode 9 recovery
        trustView trust `shouldBe` trustView legacyTrust
        paths <- readIORef requests
        let keyPaths = filter (Text.isPrefixOf "/v1/transit/keys/" . Text.pack) paths
            expectedPath =
              "/v1/transit/keys/" <> Text.unpack (controlPlaneSigningKeyName (controlPlaneSigningKeyRefFor own))
        keyPaths `shouldSatisfy` (not . null)
        keyPaths `shouldSatisfy` all (== expectedPath)
        readIORef (writes fixture) `shouldReturn` 0
        readIORef (sourceReads fixture) `shouldReturn` 0
        writeIORef (anchor fixture) (ModelBCorrupt "lost retained marker")
        observeRpcBirthRecoveryTrust backend mode 9 recovery >>= (`shouldSatisfy` isLeft)
        signCanonicalBytesWithRequestCapability capability "after-marker-loss" >>= (`shouldSatisfy` isLeft)

  it "keeps live retirement authentication tied to the original observed preparation" $
    withHomeVault HomeOwnKeyOnly $ \session _ -> do
      fixture <- preparedFixture
      mode <- pin fixture
      let backend = nativeBackend fixture (pure (Right seeded))
      recovery <- must <$> resolveRpcBirthRecoveryAuthentication backend mode scope session
      _ <- must <$> run fixture mode (AbortRpcBirth 1 keyA)
      observeRpcBirthRecoveryTrust backend mode 9 recovery
        >>= (`shouldSatisfy` either (const False) (const True))
      capability <- must <$> resolveRpcBirthRecoverySigner backend mode scope session recovery
      signCanonicalBytesWithRequestCapability capability "retired-response"
        >>= (`shouldSatisfy` either (const False) (const True))
      writeIORef (primary fixture) ModelBMissing
      resolveRpcBirthRecoverySigner backend mode scope session recovery >>= (`shouldSatisfy` isLeft)

  forM_ [BirthRetiring, BirthRetired] $ \phase ->
    it ("preserves the limited historical seedless recovery meaning for " <> show phase) $ do
      fixture <- historicalFixture phase
      mode <- pin fixture
      let backend = nativeBackend fixture (fail "retired recovery read preparation source")
      withHomeVault HomeHealthy $ \session _ -> do
        recovered <- must <$> resolveRpcBirthRecoveryAuthentication backend mode scope session
        (_, record) <- current fixture
        rpcBirthRecoveryAggregate recovered `shouldBe` rpcBirthAdmission record
      withHomeVault HomeRootRotated $ \session _ ->
        resolveRpcBirthRecoveryAuthentication backend mode scope session >>= (`shouldSatisfy` isLeft)

  forM_
    [ ModelBMissing
    , ModelBCorrupt "corrupt"
    , ModelBEndpointUnready "unready"
    , ModelBUnobservable "unobservable"
    ]
    $ \observed ->
      it ("does not initialize missing or unobservable retained state: " <> show observed) $
        withHomeVault HomeHealthy $ \session requests -> do
          fixture <- preparedFixture
          mode <- pin fixture
          writeIORef (primary fixture) observed
          writeIORef (writes fixture) 0
          let backend = nativeBackend fixture (fail "missing state read source")
          resolveRpcBirthRecoveryAuthentication backend mode scope session >>= (`shouldSatisfy` isLeft)
          readIORef requests `shouldReturn` []
          readIORef (writes fixture) `shouldReturn` 0

  it "propagates cancellation while observing the registered pair" $
    withHomeVault HomeHealthy $ \session _ -> do
      fixture <- preparedFixture
      mode <- pin fixture
      let authority = must (mkLongLivedCheckpointAuthority "home" "bucket" "authority" "kv")
          coordinate name = must (mkClusterRetainedCoordinate authority name)
          cancelled =
            modelBRpcBirthBackend
              (ModelBCasAdapter (\_ -> throwIO ThreadKilled) (\_ -> fail "unexpected CAS"))
              (coordinate "authority/admission")
              (ModelBCasAdapter (\_ -> pure ModelBMissing) (\_ -> fail "unexpected CAS"))
              (coordinate "authority/rpc-registration-birth")
              (fail "unexpected source")
      result <- try (resolveRpcBirthRecoveryAuthentication cancelled mode scope session)
      (result :: Either AsyncException (Either RpcBirthError RpcBirthRecoveryAuthentication))
        `shouldSatisfy` either (== ThreadKilled) (const False)

-- Untrusted outer wire preserves a well-formed inner aggregate while changing
-- its authored reservation profile. Production data use the opaque codec.
data UncheckedRetainedBirth
  = UncheckedRetainedBirth
      Word
      RpcBirthPhase
      UncheckedRetainedDescriptor
      (Maybe BS.ByteString)
      BS.ByteString
  deriving (Generic, Serialise)
data UncheckedRetainedDescriptor
  = UncheckedRetainedDescriptor
      Text
      Natural
      Text
      Natural
      Natural
      Text
      Text
      Natural
      Natural
  deriving (Generic, Serialise)

historicalRecord :: RpcBirthPhase -> IO (RpcBirthRecord, BS.ByteString)
historicalRecord phase = do
  bytes <- BS.readFile "test/qualification/RPC-BIRTH-SCHEMA-ONE-HISTORICAL-2026-10-25.json"
  value <- either fail pure (eitherDecodeStrict' bytes)
  records <- case value of
    Object fields -> case KeyMap.lookup "records" fields of
      Just (Array entries) -> pure (foldr (:) [] entries)
      _ -> fail "historical fixture has no records"
    _ -> fail "historical fixture is not an object"
  encoded <- case [ encoded
                  | Object fields <- records
                  , KeyMap.lookup "phase" fields == Just (String (Text.pack (show phase)))
                  , Just (String encoded) <- [KeyMap.lookup "base64" fields]
                  ] of
    [text] -> pure text
    _ -> fail "historical phase is not uniquely recorded"
  raw <- either fail pure (B64.decode (TextEncoding.encodeUtf8 encoded))
  decoded <- either fail pure (decodeModelBValue codec raw)
  pure (decoded, raw)

historicalFixture :: RpcBirthPhase -> IO Fixture
historicalFixture phase = do
  (record, _) <- historicalRecord phase
  fixture <- newFixture
  let descriptor = maybe (error "historical descriptor missing") id (rpcBirthDescriptor record)
      markerPhase = case phase of
        BirthArmed -> Just BirthMarkerPrepared
        BirthCommitted -> Just BirthMarkerCommitted
        BirthRetired -> Just BirthMarkerRetired
        _ -> Nothing
  writeIORef (primary fixture) (ModelBObserved (version 1) record)
  writeIORef
    (anchor fixture)
    ( maybe
        ModelBMissing
        (ModelBObserved (version 1) . (`rpcBirthMarkerFor` descriptor))
        markerPhase
    )
  pure fixture

coldFixture :: RpcBirthPhase -> IO Fixture
coldFixture phase = do
  fixture <- preparedFixture
  mode <- pin fixture
  case phase of
    BirthLegacy -> fail "cold fixture requires a descriptor"
    BirthPrepared -> pure ()
    BirthArmed -> do
      run fixture legacyRpcBirthServingMode (CompleteRpcBirth 1 keyA)
        `shouldReturn` Left RpcBirthPublicationRequired
    BirthCommitted -> do
      _ <- must <$> run fixture mode (CompleteRpcBirth 1 keyA)
      pure ()
    BirthRetiring -> do
      (revision, record) <- current fixture
      prepared <- maybe (fail "missing prepared stage") pure (rpcBirthStage PreparedBirth record)
      let retiring = rpcBirthStageRecord (must (advanceRpcBirth RetirePreparedRpcBirth prepared Nothing))
      writeIORef (primary fixture) (ModelBObserved revision retiring)
    BirthRetired -> do
      _ <- must <$> run fixture mode (AbortRpcBirth 1 keyA)
      pure ()
  pure fixture

descriptorObservationCases :: SuiteBuilder ()
descriptorObservationCases = describe "original public preparation observation" $ do
  it "preserves every original command wire value" $ do
    let commands = [ObserveRpcBirth, PrepareRpcBirth 1 keyA, CompleteRpcBirth 1 keyA, AbortRpcBirth 1 keyA]
        frozen =
          [ "cHJvZGJveC1ycGMtYmlydGgtcmVxdWVzdC92MQCDAAGBAA=="
          , "cHJvZGJveC1ycGMtYmlydGgtcmVxdWVzdC92MQCDAAGDAQF4IGFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFh"
          , "cHJvZGJveC1ycGMtYmlydGgtcmVxdWVzdC92MQCDAAGDAgF4IGFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFh"
          , "cHJvZGJveC1ycGMtYmlydGgtcmVxdWVzdC92MQCDAAGDAwF4IGFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFh"
          ]
    map encodeRpcBirthCommand commands `shouldBe` map (must . B64.decode) frozen

  it "preserves original successful status response bytes" $ do
    let digest = Text.replicate 64 "b"
        statuses =
          [ RpcBirthStatus BirthLegacy 0 False Nothing
          , RpcBirthStatus BirthPrepared 1 False (Just digest)
          , RpcBirthStatus BirthCommitted 1 True (Just digest)
          ]
        frozen =
          [ "gwABggGFAIEAAPSA"
          , "gwABggGFAIEBAfSBeEBiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJi"
          , "gwABggGFAIEDAfWBeEBiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJi"
          ]
        encodeStatus status = Lazy.toStrict (encodeControlPlaneResponse (Right status :: Either RpcBirthError RpcBirthStatus))
    map encodeStatus statuses `shouldBe` map (must . B64.decode) frozen

  it "returns the original expired key, epoch and deadline without writes or seed reads" $ do
    fixture <- preparedFixture
    writeIORef (clock fixture) 3000000
    writeIORef (writes fixture) 0
    writeIORef (sourceReads fixture) 0
    observed <- must <$> observeDescriptor fixture legacyRpcBirthServingMode 3000000 4000000
    descriptor <-
      maybe (fail "prepared descriptor missing") pure (rpcBirthObservationDescriptor observed)
    rpcBirthDescriptorKey descriptor `shouldBe` keyA
    rpcBirthDescriptorEpoch descriptor `shouldBe` authorityEpochGenesis
    rpcBirthDescriptorDeadline descriptor `shouldBe` authorityTimeFromMicros 2000000
    rpcBirthDescriptorCapacity descriptor `shouldBe` 7
    rpcBirthDescriptorReservations descriptor `shouldBe` 4
    rpcBirthObservationRequiresRegistration observed `shouldBe` False
    rpcBirthStatusPhase (rpcBirthObservationStatus observed) `shouldBe` BirthPrepared
    encoded <- pure (must (encodeRpcBirthDescriptorObservation observed))
    decodeRpcBirthDescriptorObservation scope encoded `shouldBe` Right observed
    BS.length encoded `shouldSatisfy` (<= rpcBirthObservationMaximumBytes)
    readIORef (writes fixture) `shouldReturn` 0
    readIORef (sourceReads fixture) `shouldReturn` 0
    observedPair <- pair fixture
    uncurry (rpcBirthNormalAdmission legacyRpcBirthServingMode) observedPair
      `shouldBe` Left RpcBirthWrongPhase

  it "reports the independently configured serving pin without granting admission" $ do
    fixture <- preparedFixture
    mode <- pin fixture
    observed <- must <$> observeDescriptor fixture mode 1000 2000000
    rpcBirthObservationRequiresRegistration observed `shouldBe` True
    rpcBirthStatusCommitted (rpcBirthObservationStatus observed) `shouldBe` False
    let foreignPin = must (registeredRpcBirthServingMode scope 2 (Text.replicate 64 "a"))
    observeDescriptor fixture foreignPin 1000 2000000 `shouldReturn` Left RpcBirthMarkerMismatch

  it "distinguishes unprepared legacy from required missing registration" $ do
    fixture <- newFixture
    observed <- must <$> observeDescriptor fixture legacyRpcBirthServingMode 1000 2000000
    rpcBirthObservationDescriptor observed `shouldBe` Nothing
    rpcBirthObservationStatus observed `shouldBe` RpcBirthStatus BirthLegacy 0 False Nothing
    writeIORef (primary fixture) ModelBMissing
    let mode = must (registeredRpcBirthServingMode scope 1 (Text.replicate 64 "a"))
    observeDescriptor fixture mode 1000 2000000 `shouldReturn` Left RpcBirthAdmissionMissing
    readIORef (writes fixture) `shouldReturn` 0

  it "binds the exact read request to its scope, role, caller and payload" $ do
    let request = signed CallerOperatorCli rpcBirthDescriptorRequest 1000 2000000
        otherScope = must (Coordinate.mkAuthorityScope "foreign")
    mkRpcBirthDescriptorContext otherScope legacyRpcBirthServingMode request
      `shouldSatisfy` isLeft
    mkRpcBirthDescriptorContext
      scope
      legacyRpcBirthServingMode
      (signed (CallerService ProviderWorkerRuntime) rpcBirthDescriptorRequest 1000 2000000)
      `shouldSatisfy` isLeft
    mkRpcBirthDescriptorContext
      scope
      legacyRpcBirthServingMode
      (signed CallerOperatorCli (rpcBirthDescriptorRequest <> "trailing") 1000 2000000)
      `shouldSatisfy` isLeft
    isRpcBirthObservationForRole
      LifecycleAuthorityRuntime
      LifecycleMigrationApply
      rpcBirthDescriptorRequest
      `shouldBe` True
    isRpcBirthObservationForRole ProviderWorkerRuntime LifecycleMigrationApply rpcBirthDescriptorRequest
      `shouldBe` False
    isRpcBirthObservationForRole
      LifecycleAuthorityRuntime
      LifecycleAuthorityPeerObserve
      rpcBirthDescriptorRequest
      `shouldBe` False
    isRpcBirthObservationForRole
      LifecycleAuthorityRuntime
      LifecycleMigrationApply
      (rpcBirthDescriptorRequest <> "trailing")
      `shouldBe` False

  it "bounds the read by the new request deadline without altering preparation" $ do
    fixture <- preparedFixture
    writeIORef (clock fixture) 4000000
    observeDescriptor fixture legacyRpcBirthServingMode 3999999 4000000
      `shouldReturn` Left RpcBirthDeadlineReached
    (_, record) <- current fixture
    fmap rpcBirthDescriptorDeadline (rpcBirthDescriptor record)
      `shouldBe` Just (authorityTimeFromMicros 2000000)

  it "propagates cancellation from the read-only interpreter" $ do
    let cancelled = RpcBirthReadInterpreter (\_ _ -> throwIO ThreadKilled)
        ctx =
          must
            ( mkRpcBirthDescriptorContext
                scope
                legacyRpcBirthServingMode
                (signed CallerOperatorCli rpcBirthDescriptorRequest 1000 2000000)
            )
    result <- try (executeRpcBirthDescriptorObservation cancelled ctx)
    (result :: Either AsyncException (Either RpcBirthError RpcBirthDescriptorObservation))
      `shouldBe` Left ThreadKilled

  forM_
    [ ("wrong wire version", \status raw -> uncheckedObservation 2 status (Just raw) False)
    , ("missing descriptor", \status _ -> uncheckedObservation 1 status Nothing False)
    ,
      ( "wrong status generation"
      , \status raw -> uncheckedObservation 1 status {rpcBirthStatusGeneration = 2} (Just raw) False
      )
    ,
      ( "wrong status digest"
      , \status raw ->
          uncheckedObservation
            1
            status {rpcBirthStatusDescriptorDigest = Just (Text.replicate 64 "0")}
            (Just raw)
            False
      )
    ,
      ( "false committed phase"
      , \status raw -> uncheckedObservation 1 status {rpcBirthStatusCommitted = True} (Just raw) False
      )
    ,
      ( "legacy status over descriptor"
      , \_ raw -> uncheckedObservation 1 (RpcBirthStatus BirthLegacy 0 False Nothing) (Just raw) False
      )
    , ("trailing bytes", \status raw -> uncheckedObservation 1 status (Just raw) False <> "trailing")
    , ("oversized payload", \_ _ -> BS.replicate (rpcBirthObservationMaximumBytes + 1) 0)
    ]
    $ \(name, corrupt) ->
      it ("rejects public observation " <> name) $ do
        fixture <- preparedFixture
        observed <- must <$> observeDescriptor fixture legacyRpcBirthServingMode 1000 2000000
        descriptor <- maybe (fail "descriptor missing") pure (rpcBirthObservationDescriptor observed)
        let raw = must (encodeRpcBirthDescriptor descriptor)
        decodeRpcBirthDescriptorObservation scope (corrupt (rpcBirthObservationStatus observed) raw)
          `shouldSatisfy` isLeft

  it "rejects a pinned legacy-empty observation and a foreign descriptor scope" $ do
    let emptyStatus = RpcBirthStatus BirthLegacy 0 False Nothing
    decodeRpcBirthDescriptorObservation scope (uncheckedObservation 1 emptyStatus Nothing True)
      `shouldSatisfy` isLeft
    fixture <- preparedFixture
    observed <- must <$> observeDescriptor fixture legacyRpcBirthServingMode 1000 2000000
    let otherScope = must (Coordinate.mkAuthorityScope "foreign")
    decodeRpcBirthDescriptorObservation otherScope (must (encodeRpcBirthDescriptorObservation observed))
      `shouldBe` Left RpcBirthScopeMismatch

  it "rejects malformed and oversized standalone public descriptors" $ do
    fixture <- preparedFixture
    (_, record) <- current fixture
    descriptor <- maybe (fail "descriptor missing") pure (rpcBirthDescriptor record)
    let bytes = must (encodeRpcBirthDescriptor descriptor)
    decodeRpcBirthDescriptor scope bytes `shouldBe` Right descriptor
    decodeRpcBirthDescriptor scope (bytes <> "trailing") `shouldSatisfy` isLeft
    decodeRpcBirthDescriptor scope (BS.replicate (rpcBirthDescriptorMaximumBytes + 1) 0)
      `shouldBe` Left RpcBirthStateTooLarge

ownBindingHintCases :: SuiteBuilder ()
ownBindingHintCases = describe "bounded public own-binding discovery" $ do
  let origin =
        mkRpcKeyOrigin
          scope
          (must (mkRpcVaultIncarnation "11111111-1111-1111-1111-111111111111"))
          (controlPlaneSigningKeyRefFor CallerOperatorCli)
      query = must (mkRpcOwnBindingQuery scope origin)
      expectedHint = must (selectRpcOwnBindingHint query seeded)
      observe fixture mode deadline selected =
        executeRpcBirthOwnBindingHint
          (rpcBirthReadInterpreter (interpreter fixture))
          scope
          mode
          (authorityTimeFromMicros deadline)
          selected

  forM_ [BirthPrepared, BirthArmed, BirthCommitted, BirthRetiring, BirthRetired] $ \phase ->
    it ("reads one exact public binding after original preparation expiry in " <> show phase) $ do
      fixture <- coldFixture phase
      mode <- pin fixture
      writeIORef (clock fixture) 3000000
      writeIORef (writes fixture) 0
      writeIORef (sourceReads fixture) 0
      writeIORef (source fixture) (Left RpcBirthNativeSourceUnavailable)
      observe fixture mode 4000000 query `shouldReturn` Right expectedHint
      readIORef (writes fixture) `shouldReturn` 0
      readIORef (sourceReads fixture) `shouldReturn` 0

  it "refuses legacy mode before any retained or native source read" $ do
    effects <- newIORef (0 :: Int)
    let refuse :: AuthorityTime -> RpcBirthReadProgram result -> IO (Either RpcBirthError result)
        refuse _ _ = modifyIORef' effects (+ 1) >> pure (Left RpcBirthObservationUnavailable)
    executeRpcBirthOwnBindingHint
      (RpcBirthReadInterpreter refuse)
      scope
      legacyRpcBirthServingMode
      (authorityTimeFromMicros 2000000)
      query
      `shouldReturn` Left RpcBirthRegisteredStateUnbound
    readIORef effects `shouldReturn` 0

  it "refuses a foreign Authority before any retained read" $ do
    fixture <- preparedFixture
    mode <- pin fixture
    effects <- newIORef (0 :: Int)
    let refuse :: AuthorityTime -> RpcBirthReadProgram result -> IO (Either RpcBirthError result)
        refuse _ _ = modifyIORef' effects (+ 1) >> pure (Left RpcBirthObservationUnavailable)
        foreignQuery = must (mkRpcOwnBindingQuery (must (Coordinate.mkAuthorityScope "foreign")) origin)
    executeRpcBirthOwnBindingHint
      (RpcBirthReadInterpreter refuse)
      scope
      mode
      (authorityTimeFromMicros 2000000)
      foreignQuery
      `shouldReturn` Left RpcBirthScopeMismatch
    readIORef effects `shouldReturn` 0

  it "does not renew an expired request window" $ do
    fixture <- preparedFixture
    mode <- pin fixture
    writeIORef (clock fixture) 3000000
    observe fixture mode 3000000 query `shouldReturn` Left RpcBirthDeadlineReached

  it "refuses another native origin instead of returning an unrelated active binding" $ do
    fixture <- preparedFixture
    mode <- pin fixture
    let foreignOrigin =
          mkRpcKeyOrigin
            scope
            (must (mkRpcVaultIncarnation "22222222-2222-2222-2222-222222222222"))
            (controlPlaneSigningKeyRefFor CallerOperatorCli)
    observe fixture mode 2000000 (must (mkRpcOwnBindingQuery scope foreignOrigin))
      `shouldReturn` Left RpcBirthRequestContextInvalid

  forM_
    [ ("corrupt", ModelBCorrupt "corrupt", RpcBirthStateInvalid)
    , ("endpoint unready", ModelBEndpointUnready "unready", RpcBirthObservationUnavailable)
    , ("unobservable", ModelBUnobservable "unobservable", RpcBirthObservationUnavailable)
    , ("disappeared", ModelBMissing, RpcBirthObservationUnavailable)
    ]
    $ \(label, closing, expected) ->
      it ("preserves closing primary " <> label <> " instead of returning a stale hint") $ do
        fixture <- preparedFixture
        mode <- pin fixture
        primaryReadCount <- newIORef (0 :: Int)
        let normal = rpcBirthReadInterpreter (interpreter fixture)
            readClosing :: AuthorityTime -> RpcBirthReadProgram result -> IO (Either RpcBirthError result)
            readClosing deadline program = case program of
              ReadBirthObservationRecord -> do
                count <- atomicModifyIORef' primaryReadCount (\n -> (n + 1, n + 1))
                if count == 2 then pure (Right closing) else runRpcBirthReadProgram normal deadline program
              _ -> runRpcBirthReadProgram normal deadline program
        executeRpcBirthOwnBindingHint
          (RpcBirthReadInterpreter readClosing)
          scope
          mode
          (authorityTimeFromMicros 2000000)
          query
          `shouldReturn` Left expected
        readIORef primaryReadCount `shouldReturn` 2

  it "does not initialize missing retained provenance or read a native seed" $ do
    fixture <- preparedFixture
    mode <- pin fixture
    writeIORef (primary fixture) ModelBMissing
    writeIORef (anchor fixture) ModelBMissing
    writeIORef (writes fixture) 0
    writeIORef (sourceReads fixture) 0
    observe fixture mode 2000000 query `shouldReturn` Left RpcBirthAdmissionMissing
    readIORef (writes fixture) `shouldReturn` 0
    readIORef (sourceReads fixture) `shouldReturn` 0

  it "requires the independent configured birth pin" $ do
    fixture <- preparedFixture
    let foreignPin = must (registeredRpcBirthServingMode scope 2 (Text.replicate 64 "a"))
    observe fixture foreignPin 2000000 query `shouldReturn` Left RpcBirthMarkerMismatch

  it "propagates cancellation without converting it into hint data" $ do
    fixture <- preparedFixture
    mode <- pin fixture
    let cancelled = RpcBirthReadInterpreter (\_ _ -> throwIO ThreadKilled)
    result <-
      try (executeRpcBirthOwnBindingHint cancelled scope mode (authorityTimeFromMicros 2000000) query)
    (result :: Either AsyncException (Either RpcBirthError RpcOwnBindingHint))
      `shouldBe` Left ThreadKilled

  forM_ [CallerOperatorCli, CallerTestHarness] $ \caller ->
    it ("serves only the fixed hint payload through the actual role wrapper for " <> show caller) $ do
      fixture <- preparedFixture
      mode <- pin fixture
      now <- rpcBirthSystemTime
      writeIORef (clock fixture) (authorityTimeMicros now)
      let ownOrigin =
            mkRpcKeyOrigin scope (rpcKeyOriginVault origin) (controlPlaneSigningKeyRefFor caller)
          ownQuery = must (mkRpcOwnBindingQuery scope ownOrigin)
          wrapped =
            rpcBirthOwnBindingInterpreter
              scope
              mode
              (rpcBirthReadInterpreter (interpreter fixture))
              Server.failClosedInterpreter
      response <-
        Server.interpreterHandle wrapped LifecycleMigrationApply (encodeRpcOwnBindingQuery ownQuery)
      case response of
        Just (ReplyOk, bytes) -> do
          decodeRpcOwnBindingHint ownQuery bytes `shouldBe` selectRpcOwnBindingHint ownQuery seeded
          BS.length bytes `shouldSatisfy` (<= rpcOwnBindingHintMaximumBytes)
        other -> expectationFailure (show other)

  it "delegates every ordinary frame and wrong-route hint unchanged to authentication" $ do
    fixture <- preparedFixture
    mode <- pin fixture
    delegated <- newIORef []
    effects <- newIORef (0 :: Int)
    let refused :: AuthorityTime -> RpcBirthReadProgram result -> IO (Either RpcBirthError result)
        refused _ _ = modifyIORef' effects (+ 1) >> pure (Left RpcBirthObservationUnavailable)
        inner =
          (Server.failClosedInterpreter :: Server.RoleInterpreter IO)
            { Server.interpreterHandle = \route body -> do
                modifyIORef' delegated (<> [(route, body)])
                pure (Just (ReplyUnauthorized, "ordinary-authentication-refused"))
            }
        wrapped = rpcBirthOwnBindingInterpreter scope mode (RpcBirthReadInterpreter refused) inner
        requests =
          [ (LifecycleMigrationApply, encodeRpcBirthCommand (PrepareRpcBirth 1 keyA))
          , (LifecycleMigrationApply, encodeRpcBirthCommand (CompleteRpcBirth 1 keyA))
          , (LifecycleMigrationApply, encodeRpcBirthCommand (AbortRpcBirth 1 keyA))
          , (LifecycleMigrationApply, rpcBirthRegistryRequest)
          , (LifecycleMigrationApply, rpcBirthDescriptorRequest)
          , (LifecycleMigrationApply, "ordinary-authenticated-frame")
          , (LifecycleAuthorityControl, encodeRpcOwnBindingQuery query)
          , (LifecycleAuthorityPeerObserve, encodeRpcOwnBindingQuery query)
          ]
    forM_ requests $ \(route, body) ->
      Server.interpreterHandle wrapped route body
        `shouldReturn` Just (ReplyUnauthorized, "ordinary-authentication-refused")
    readIORef delegated `shouldReturn` requests
    readIORef effects `shouldReturn` 0

  it "refuses malformed, oversized and command-appended hint requests before retained reads" $ do
    fixture <- preparedFixture
    mode <- pin fixture
    effects <- newIORef (0 :: Int)
    let refused :: AuthorityTime -> RpcBirthReadProgram result -> IO (Either RpcBirthError result)
        refused _ _ = modifyIORef' effects (+ 1) >> pure (Left RpcBirthObservationUnavailable)
        wrapped =
          rpcBirthOwnBindingInterpreter
            scope
            mode
            (RpcBirthReadInterpreter refused)
            Server.failClosedInterpreter
        bytes = encodeRpcOwnBindingQuery query
    forM_
      [ BS.init bytes
      , bytes <> encodeRpcBirthCommand (PrepareRpcBirth 1 keyA)
      , bytes <> BS.replicate rpcOwnBindingQueryMaximumBytes 0
      ]
      $ \body ->
        Server.interpreterHandle wrapped LifecycleMigrationApply body
          `shouldReturn` Just (ReplyBadRequest, "rpc-own-binding-query-refused\n")
    readIORef effects `shouldReturn` 0

  it "joins a timed-out retained read within the fixed server window" $ do
    fixture <- preparedFixture
    mode <- pin fixture
    now <- rpcBirthSystemTime
    writeIORef (clock fixture) (authorityTimeMicros now)
    joined <- newIORef False
    let normal = rpcBirthReadInterpreter (interpreter fixture)
        delayed :: AuthorityTime -> RpcBirthReadProgram result -> IO (Either RpcBirthError result)
        delayed deadline program = case program of
          ReadBirthObservationRecord ->
            (threadDelay 3000000 >> runRpcBirthReadProgram normal deadline program)
              `finally` writeIORef joined True
          _ -> runRpcBirthReadProgram normal deadline program
        wrapped =
          rpcBirthOwnBindingInterpreter
            scope
            mode
            (RpcBirthReadInterpreter delayed)
            Server.failClosedInterpreter
    Server.interpreterHandle wrapped LifecycleMigrationApply (encodeRpcOwnBindingQuery query)
      `shouldReturn` Just (ReplyServiceUnavailable, "rpc-own-binding-unavailable\n")
    readIORef joined `shouldReturn` True

registryObservationCases :: SuiteBuilder ()
registryObservationCases = describe "authenticated retained registry observation" $ do
  forM_ [BirthPrepared, BirthArmed, BirthCommitted, BirthRetiring, BirthRetired] $ \phase ->
    it ("reads exact retained public metadata after the old deadline in " <> show phase) $ do
      fixture <- coldFixture phase
      mode <- pin fixture
      writeIORef (clock fixture) 3000000
      writeIORef (writes fixture) 0
      writeIORef (sourceReads fixture) 0
      writeIORef (source fixture) (Left RpcBirthNativeSourceUnavailable)
      observed <- must <$> observeRegistry fixture mode 3000000 4000000
      rpcBirthObservedRegistry observed `shouldBe` seeded
      let birth = rpcBirthRegistryBirth observed
      rpcBirthStatusPhase (rpcBirthObservationStatus birth) `shouldBe` phase
      fmap rpcBirthDescriptorDeadline (rpcBirthObservationDescriptor birth)
        `shouldBe` Just (authorityTimeFromMicros 2000000)
      rpcBirthObservationRequiresRegistration birth `shouldBe` True
      let encoded = must (encodeRpcBirthRegistryObservation observed)
      decodeRpcBirthRegistryObservation scope encoded `shouldBe` Right observed
      BS.length encoded `shouldSatisfy` (<= rpcBirthRegistryObservationMaximumBytes)
      readIORef (writes fixture) `shouldReturn` 0
      readIORef (sourceReads fixture) `shouldReturn` 0

  it "returns current registration and retirement history rather than reconstructing the seed" $ do
    fixture <- coldFixture BirthCommitted
    mode <- pin fixture
    (revision, record) <- current fixture
    let principal = CallerService LifecycleAuthorityRuntime
        origin =
          mkRpcKeyOrigin
            scope
            (must (mkRpcVaultIncarnation "11111111-1111-1111-1111-111111111111"))
            (controlPlaneSigningKeyRefFor principal)
        public =
          requestSignerPublicKeyBytes
            (must (mkRequestSigner principal (must (mkSigningKeyGeneration 2)) (BS.replicate 32 249)))
        key = must (mkRpcObservedKey origin 2 public)
        registered = must (enrollAuthorityRpcKey key (rpcBirthAdmission record))
        retired = must (retireAuthorityRpcKey principal (must (mkSigningKeyGeneration 1)) registered)
        next = must (replaceRpcBirthAdmission record retired)
        expected = maybe (error "registered history missing") id (authorityAggregateRpcKeyRegistry retired)
    writeIORef (primary fixture) (ModelBObserved revision next)
    observed <- must <$> observeRegistry fixture mode 1000 2000000
    rpcBirthObservedRegistry observed `shouldBe` expected
    rpcBirthObservedRegistry observed `shouldSatisfy` (/= seeded)
    rpcBirthOriginalHomeSeed (rpcBirthObservedRegistry observed) `shouldBe` Right seeded

  it "refuses absence, unprepared legacy and seedless historical records without source reads" $ do
    fixture <- newFixture
    observeRegistry fixture legacyRpcBirthServingMode 1000 2000000
      `shouldReturn` Left RpcBirthAdmissionMissing
    writeIORef (primary fixture) ModelBMissing
    observeRegistry fixture legacyRpcBirthServingMode 1000 2000000
      `shouldReturn` Left RpcBirthAdmissionMissing
    historical <- historicalFixture BirthRetired
    mode <- pin historical
    observeRegistry historical mode 1000 2000000 `shouldReturn` Left RpcBirthAdmissionMissing
    readIORef (sourceReads fixture) `shouldReturn` 0
    readIORef (sourceReads historical) `shouldReturn` 0

  it "refuses a foreign independent pin and legacy mode over committed state" $ do
    fixture <- coldFixture BirthCommitted
    let foreignPin = must (registeredRpcBirthServingMode scope 2 (Text.replicate 64 "a"))
    observeRegistry fixture foreignPin 1000 2000000 `shouldReturn` Left RpcBirthMarkerMismatch
    observeRegistry fixture legacyRpcBirthServingMode 1000 2000000
      `shouldReturn` Left RpcBirthPublicationRequired

  forM_
    [ ("corrupt", ModelBCorrupt "corrupt", RpcBirthStateInvalid)
    , ("endpoint unready", ModelBEndpointUnready "unready", RpcBirthObservationUnavailable)
    , ("unobservable", ModelBUnobservable "unobservable", RpcBirthObservationUnavailable)
    , ("disappeared", ModelBMissing, RpcBirthObservationUnavailable)
    ]
    $ \(label, closing, expected) ->
      it ("preserves closing primary " <> label <> " instead of returning stale membership") $ do
        fixture <- preparedFixture
        mode <- pin fixture
        registryReadCount <- newIORef (0 :: Int)
        let normal = rpcBirthReadInterpreter (interpreter fixture)
            readClosing :: AuthorityTime -> RpcBirthReadProgram value -> IO (Either RpcBirthError value)
            readClosing deadline program = case program of
              ReadBirthObservationRecord -> do
                count <- atomicModifyIORef' registryReadCount (\n -> (n + 1, n + 1))
                if count == 2 then pure (Right closing) else runRpcBirthReadProgram normal deadline program
              _ -> runRpcBirthReadProgram normal deadline program
            registryContext =
              must
                (mkRpcBirthRegistryContext scope mode (signed CallerOperatorCli rpcBirthRegistryRequest 1000 2000000))
        executeRpcBirthRegistryObservation (RpcBirthReadInterpreter readClosing) registryContext
          `shouldReturn` Left expected
        readIORef registryReadCount `shouldReturn` 2

  it "binds the exact registry request to both existing callers and the fixed route" $ do
    forM_ [CallerOperatorCli, CallerTestHarness] $ \caller -> do
      mkRpcBirthRegistryContext
        scope
        legacyRpcBirthServingMode
        (signed caller rpcBirthRegistryRequest 1000 2000000)
        `shouldSatisfy` either (const False) (const True)
    forM_ [rpcBirthRegistryRequest <> "trailing", rpcBirthDescriptorRequest] $ \body ->
      mkRpcBirthRegistryContext
        scope
        legacyRpcBirthServingMode
        (signed CallerOperatorCli body 1000 2000000)
        `shouldSatisfy` isLeft
    mkRpcBirthRegistryContext
      scope
      legacyRpcBirthServingMode
      (signed (CallerService ProviderWorkerRuntime) rpcBirthRegistryRequest 1000 2000000)
      `shouldSatisfy` isLeft
    forM_
      [ (LifecycleAuthorityRuntime, LifecycleMigrationApply, rpcBirthRegistryRequest, True)
      , (ProviderWorkerRuntime, LifecycleMigrationApply, rpcBirthRegistryRequest, False)
      , (LifecycleAuthorityRuntime, LifecycleAuthorityPeerObserve, rpcBirthRegistryRequest, False)
      , (LifecycleAuthorityRuntime, LifecycleMigrationApply, rpcBirthRegistryRequest <> "trailing", False)
      ]
      $ \(role, route, body, expected) ->
        isRpcBirthObservationForRole role route body `shouldBe` expected

  it "refuses an expired fresh read and propagates asynchronous cancellation" $ do
    fixture <- preparedFixture
    mode <- pin fixture
    writeIORef (clock fixture) 2000000
    observeRegistry fixture mode 1999999 2000000 `shouldReturn` Left RpcBirthDeadlineReached
    let registryContext =
          must
            (mkRpcBirthRegistryContext scope mode (signed CallerOperatorCli rpcBirthRegistryRequest 1000 2000000))
        cancelled = RpcBirthReadInterpreter (\_ _ -> throwIO ThreadKilled)
    result <- try (executeRpcBirthRegistryObservation cancelled registryContext)
    (result :: Either AsyncException (Either RpcBirthError RpcBirthRegistryObservation))
      `shouldBe` Left ThreadKilled

  forM_
    [ ("wire version", \birth registry -> uncheckedRegistryObservation 2 birth registry)
    , ("invalid registry", \birth _ -> uncheckedRegistryObservation 1 birth "invalid")
    , ("invalid birth", \_ registry -> uncheckedRegistryObservation 1 "invalid" registry)
    , ("trailing bytes", \birth registry -> uncheckedRegistryObservation 1 birth registry <> "trailing")
    , ("oversized payload", \_ _ -> BS.replicate (rpcBirthRegistryObservationMaximumBytes + 1) 0)
    ,
      ( "foreign scope"
      , \birth _ ->
          uncheckedRegistryObservation
            1
            birth
            (must (encodeRpcKeyRegistry (seededFor (must (Coordinate.mkAuthorityScope "foreign")))))
      )
    ]
    $ \(label, corrupt) ->
      it ("rejects an untrusted registry observation with " <> label) $ do
        fixture <- preparedFixture
        mode <- pin fixture
        observed <- must <$> observeRegistry fixture mode 1000 2000000
        let birth = must (encodeRpcBirthDescriptorObservation (rpcBirthRegistryBirth observed))
            registry = must (encodeRpcKeyRegistry (rpcBirthObservedRegistry observed))
        decodeRpcBirthRegistryObservation scope (corrupt birth registry) `shouldSatisfy` isLeft

  forM_ [CallerOperatorCli, CallerTestHarness] $ \caller ->
    it ("uses the actual authenticated peer/registry composition for " <> show caller) $ do
      now <- rpcBirthSystemTime
      let deadline = authorityTimeFromMicros (authorityTimeMicros now + 10000000)
      withRpcBirthPreparedCoordinatorWireFixture deadline (pure Nothing) $ \_ _ bounds providers wire probe -> do
        let client =
              must
                ( Client.controlPlaneClientWithTransport
                    rpcBirthRegistryResponseMaximumBytes
                    (must (Client.mkLifecycleAuthorityEndpoint "http://home.test"))
                    wire
                )
            owned =
              providers
                { Transport.provideAuthenticatedClientSigner =
                    pure (Right (localRequestSigningCapability (signer caller)))
                }
            transport = Transport.mkAuthenticatedClientTransport bounds owned client
        observed <-
          must <$> requestRpcBirthRegistryWithin (Right <$> rpcBirthSystemTime) deadline scope transport
        rpcBirthObservedRegistry observed `shouldBe` seeded
        rpcBirthObservationRequiresRegistration (rpcBirthRegistryBirth observed) `shouldBe` True
        probe `shouldReturn` (BirthPrepared, [deadline, deadline])

  it "bounds a blocked registry deadline provider before any RPC" $ do
    now <- rpcBirthSystemTime
    let deadline = authorityTimeFromMicros (authorityTimeMicros now + 10000000)
    withRpcBirthPreparedCoordinatorWireFixture deadline (pure Nothing) $ \_ _ bounds providers wire probe -> do
      gate <- newEmptyMVar
      attempts <- newIORef (0 :: Int)
      started <- rpcBirthSystemTime
      let parent = authorityTimeFromMicros (authorityTimeMicros started + 20000)
      let client =
            must
              ( Client.controlPlaneClientWithTransport
                  rpcBirthRegistryResponseMaximumBytes
                  (must (Client.mkLifecycleAuthorityEndpoint "http://home.test"))
                  wire
              )
          blocked =
            providers
              { Transport.provideAuthenticatedClientDeadline = modifyIORef' attempts (+ 1) >> takeMVar gate
              }
          transport = Transport.mkAuthenticatedClientTransport bounds blocked client
      requestRpcBirthRegistryWithin (Right <$> rpcBirthSystemTime) parent scope transport
        `shouldReturn` Left RpcBirthClientDeadlineReached
      readIORef attempts `shouldReturn` 1
      probe `shouldReturn` (BirthPrepared, [])

  it "reads a valid registry above the ordinary metadata ceiling while retaining that ceiling" $
    withHomeVault HomeHealthy $ \session _ -> do
      base <- coldFixture BirthCommitted
      mode <- pin base
      (revision, record) <- current base
      let principal = CallerService LifecycleAuthorityRuntime
          origin =
            mkRpcKeyOrigin
              (must (Coordinate.mkAuthorityScope (Text.replicate 2048 "卷")))
              (must (mkRpcVaultIncarnation "22222222-2222-2222-2222-222222222222"))
              (controlPlaneSigningKeyRefFor principal)
          keys =
            [ must
                ( mkRpcObservedKey
                    origin
                    native
                    ( requestSignerPublicKeyBytes
                        ( must
                            ( mkRequestSigner
                                principal
                                (must (mkSigningKeyGeneration 1))
                                (BS.pack (250 : fromIntegral native : replicate 30 249))
                            )
                        )
                    )
                )
            | native <- [1 .. 12]
            ]
          enrolled = must (foldM (flip enrollAuthorityRpcKey) (rpcBirthAdmission record) keys)
          enrolledRegistry = maybe (error "bulk registry missing") id (authorityAggregateRpcKeyRegistry enrolled)
          generations =
            [ rpcKeyBindingGeneration binding
            | binding <- rpcKeyRegistryBindings enrolledRegistry
            , rpcObservedOrigin (rpcKeyBindingObserved binding) == origin
            ]
          retained =
            must
              ( foldM
                  (\aggregate generation -> retireAuthorityRpcKey principal generation aggregate)
                  enrolled
                  generations
              )
          next = must (replaceRpcBirthAdmission record retained)
      writeIORef (primary base) (ModelBObserved revision next)
      fixture <- newCoordinationFixture base
      writeIORef (coordServing fixture) mode
      frames <- newIORef []
      now <- rpcBirthSystemTime
      let deadline = authorityTimeFromMicros (authorityTimeMicros now + 10000000)
      (bounds, providers, wire) <-
        coordinatorFixtureComponents fixture session (pure (Right deadline)) frames (pure Nothing)
      let client maximumBytes =
            must
              ( Client.controlPlaneClientWithTransport
                  maximumBytes
                  (must (Client.mkLifecycleAuthorityEndpoint "http://home.test"))
                  wire
              )
          transport maximumBytes = Transport.mkAuthenticatedClientTransport bounds providers (client maximumBytes)
      observed <-
        must
          <$> requestRpcBirthRegistryWithin
            (Right <$> rpcBirthSystemTime)
            deadline
            scope
            (transport rpcBirthRegistryResponseMaximumBytes)
      let encoded = must (encodeRpcBirthRegistryObservation observed)
          body = Lazy.toStrict (encodeControlPlaneResponse (Right encoded :: Either RpcBirthError BS.ByteString))
      BS.length encoded `shouldSatisfy` (> ReplayBudget.authorityMetadataResponseMaximumBytes)
      BS.length body `shouldSatisfy` (<= rpcBirthRegistryResponseMaximumBytes)
      authorityAggregateRpcKeyRegistry retained `shouldBe` Just (rpcBirthObservedRegistry observed)
      requestRpcBirthRegistryWithin
        (Right <$> rpcBirthSystemTime)
        deadline
        scope
        (transport ReplayBudget.authorityMetadataResponseMaximumBytes)
        `shouldReturn` Left
          ( RpcBirthClientTransport
              ( Transport.AuthenticatedClientTransportFailed
                  ( Client.ControlPlaneResponseTooLarge
                      (fromIntegral (BS.length body))
                      ReplayBudget.authorityMetadataResponseMaximumBytes
                  )
              )
          )

  it "refuses an otherwise valid registry from a different original home incarnation" $ do
    fixture <- preparedFixture
    mode <- pin fixture
    observed <- must <$> observeRegistry fixture mode 1000 2000000
    let other =
          must
            ( seedLegacyRpcKeyRegistry
                scope
                [ must
                    ( mkRpcObservedKey
                        ( mkRpcKeyOrigin
                            scope
                            (must (mkRpcVaultIncarnation "22222222-2222-2222-2222-222222222222"))
                            (controlPlaneSigningKeyRefFor caller)
                        )
                        1
                        (requestSignerPublicKeyBytes (signer caller))
                    )
                | caller <- allCallerPrincipals
                ]
            )
        birth = must (encodeRpcBirthDescriptorObservation (rpcBirthRegistryBirth observed))
        forged = uncheckedRegistryObservation 1 birth (must (encodeRpcKeyRegistry other))
    decodeRpcBirthRegistryObservation scope forged `shouldBe` Left RpcBirthSeedChanged

  it "refuses a registry relabeled as a valid unprepared legacy observation" $ do
    fixture <- newFixture
    birth <- must <$> observeDescriptor fixture legacyRpcBirthServingMode 1000 2000000
    let forged =
          uncheckedRegistryObservation
            1
            (must (encodeRpcBirthDescriptorObservation birth))
            (must (encodeRpcKeyRegistry seeded))
    decodeRpcBirthRegistryObservation scope forged `shouldBe` Left RpcBirthDescriptorInvalid

  forM_
    [
      ( "wrong payload"
      , 200
      , Just
          ( Lazy.toStrict
              ( encodeControlPlaneResponse
                  (Right ("invalid" :: BS.ByteString) :: Either RpcBirthError BS.ByteString)
              )
          )
      )
    , ("wrong status", 500, Nothing)
    , ("oversized HTTP body", 200, Just (BS.replicate (rpcBirthRegistryResponseMaximumBytes + 1) 0))
    ]
    $ \(label, status, replacement) ->
      it ("refuses authenticated registry " <> label) $ do
        now <- rpcBirthSystemTime
        let deadline = authorityTimeFromMicros (authorityTimeMicros now + 10000000)
        withRpcBirthPreparedCoordinatorWireFixture deadline (pure Nothing) $ \_ _ bounds providers wire probe -> do
          let altered method headers url frame = do
                response <- wire method headers url frame
                pure $ case response of
                  Right (_, body)
                    | not ("/peer/observe" `Text.isSuffixOf` Text.pack url) ->
                        Right (status, maybe body id replacement)
                  _ -> response
              client =
                must
                  ( Client.controlPlaneClientWithTransport
                      rpcBirthRegistryResponseMaximumBytes
                      (must (Client.mkLifecycleAuthorityEndpoint "http://home.test"))
                      altered
                  )
              transport = Transport.mkAuthenticatedClientTransport bounds providers client
              expected = case replacement of
                Just bytes
                  | BS.length bytes > rpcBirthRegistryResponseMaximumBytes ->
                      Left
                        ( RpcBirthClientTransport
                            ( Transport.AuthenticatedClientTransportFailed
                                ( Client.ControlPlaneResponseTooLarge
                                    (fromIntegral rpcBirthRegistryResponseMaximumBytes + 1)
                                    rpcBirthRegistryResponseMaximumBytes
                                )
                            )
                        )
                _ | status == 500 -> Left (RpcBirthClientHttpStatus 500)
                _ -> Left RpcBirthClientResponseInvalid
          requestRpcBirthRegistryWithin (Right <$> rpcBirthSystemTime) deadline scope transport
            `shouldReturn` expected
          probe `shouldReturn` (BirthPrepared, [deadline, deadline])

data UncheckedRegistryObservation = UncheckedRegistryObservation Word BS.ByteString BS.ByteString
  deriving (Generic, Serialise)

uncheckedRegistryObservation :: Word -> BS.ByteString -> BS.ByteString -> BS.ByteString
uncheckedRegistryObservation wireVersion birth registry =
  "prodbox-rpc-birth-registry-response/v1\NUL"
    <> Lazy.toStrict (serialise (UncheckedRegistryObservation wireVersion birth registry))

observeRegistry
  :: Fixture
  -> RpcBirthServingMode
  -> Natural
  -> Natural
  -> IO (Either RpcBirthError RpcBirthRegistryObservation)
observeRegistry fixture mode now deadline =
  executeRpcBirthRegistryObservation
    (rpcBirthReadInterpreter (interpreter fixture))
    ( must
        (mkRpcBirthRegistryContext scope mode (signed CallerOperatorCli rpcBirthRegistryRequest now deadline))
    )

-- These are deliberately untrusted wire fixtures. Valid cases above always
-- use the production codec; only refusal cases forge an inconsistent payload.
data UncheckedBirthObservation = UncheckedBirthObservation Word RpcBirthStatus (Maybe BS.ByteString) Bool
  deriving (Generic, Serialise)

uncheckedObservation :: Word -> RpcBirthStatus -> Maybe BS.ByteString -> Bool -> BS.ByteString
uncheckedObservation wireVersion status descriptor pinned =
  "prodbox-rpc-birth-descriptor-response/v1\NUL"
    <> Lazy.toStrict (serialise (UncheckedBirthObservation wireVersion status descriptor pinned))

observeDescriptor
  :: Fixture
  -> RpcBirthServingMode
  -> Natural
  -> Natural
  -> IO (Either RpcBirthError RpcBirthDescriptorObservation)
observeDescriptor fixture mode now deadline =
  executeRpcBirthDescriptorObservation
    (rpcBirthReadInterpreter (interpreter fixture))
    ( must
        ( mkRpcBirthDescriptorContext
            scope
            mode
            (signed CallerOperatorCli rpcBirthDescriptorRequest now deadline)
        )
    )

must :: (Show err) => Either err value -> value
must = either (error . show) id
scope :: Coordinate.AuthorityScope
scope = must (Coordinate.mkAuthorityScope "home")
keyA, keyB :: Text
keyA = Text.replicate 32 "a"
keyB = Text.replicate 32 "b"
version :: Natural -> ModelBObjectVersion
version value = must (mkModelBObjectVersion ("opaque-v" <> Text.pack (show value)))
seeded :: RpcKeyRegistry
seeded = seededFor scope

seededFor :: Coordinate.AuthorityScope -> RpcKeyRegistry
seededFor targetScope =
  must
    ( seedLegacyRpcKeyRegistry
        targetScope
        [ must
            ( mkRpcObservedKey
                (mkRpcKeyOrigin targetScope vault (controlPlaneSigningKeyRefFor caller))
                1
                (requestSignerPublicKeyBytes (signer caller))
            )
        | caller <- allCallerPrincipals
        ]
    )
 where
  vault = must (mkRpcVaultIncarnation "11111111-1111-1111-1111-111111111111")

rpcBirthChartDescriptorFixture :: Coordinate.AuthorityScope -> Natural -> RpcBirthDescriptor
rpcBirthChartDescriptorFixture targetScope generation =
  must
    ( mkRpcBirthDescriptor
        targetScope
        generation
        keyA
        authorityEpochGenesis
        (authorityTimeFromMicros 2000000)
        (version 1)
        (seededFor targetScope)
        clients
    )
signer :: CallerPrincipal -> RequestSigner
signer caller =
  must
    ( mkRequestSigner
        caller
        (must (mkSigningKeyGeneration 1))
        (BS.replicate 32 (fromIntegral (callerPrincipalCode caller + 31)))
    )
clients :: RegisteredClientTable
clients =
  must
    ( mkRegisteredClientTable
        7
        [ must
            ( mkRegisteredClientSpec
                (clientPrincipalForCaller caller)
                (must (mkRegisteredClientSlot (fromIntegral (callerPrincipalCode caller))))
                (must (mkRegisteredClientGeneration 1))
                4
            )
        | caller <- trustedCallersForRoute LifecycleOperationSubmit
        ]
    )
initial, legacy :: AuthorityAdmissionAggregate
initial = must (initialCleanInstallAuthorityWithRegisteredClients 4 8 clients)
legacy = legacyWithClients clients
legacyWithClients :: RegisteredClientTable -> AuthorityAdmissionAggregate
legacyWithClients table =
  foldl
    (\state command -> snd (stepAuthorityAdmission state command))
    (openAdmission (must (initialCleanInstallAuthorityWithRegisteredClients 4 8 table)))
    ( [BeginAuthorityMigration]
        <> [ ApplyAuthorityMigrationImport (RecordProjectionImport projection ProjectionMissing)
           | projection <- [minBound .. maxBound]
           ]
        <> [ ApplyAuthorityMigrationImport CompleteProjectionImports
           , ApplyAuthorityMigration (VerifyShadow stamp)
           , ApplyAuthorityMigration (FreezeLegacy stamp)
           ]
    )
 where
  stamp = maybe (error "fixture stamp") id (mkMigrationDigest "birth-migration")
openAdmission :: AuthorityAdmissionAggregate -> AuthorityAdmissionAggregate
openAdmission =
  flip
    (foldl (\state command -> snd (stepAuthorityAdmission state (ApplyAuthorityGenesis command))))
    [ BeginGenesisEstablishment (GenesisPlan "birth-genesis" "backup/birth")
    , ObserveTargetAgentGeneration (TargetAgentGenerationReceipt "birth-target")
    , ObserveBackupReceipt (BackupReceipt "birth-backup")
    ]
legacyRecord :: RpcBirthRecord
legacyRecord = must (rpcBirthLegacy legacy)
legacyCodec :: ModelBCodec AuthorityAdmissionAggregate
legacyCodec = authorityAdmissionStateCodecWithRegisteredClients 524288 4 8 clients
codec :: ModelBCodec RpcBirthRecord
codec = rpcBirthRecordCodec 524288 4 8 scope clients
context :: RpcBirthServingMode -> RpcBirthCommand -> Natural -> Natural -> RpcBirthContext
context mode command now deadline =
  must
    (mkRpcBirthContext scope mode (signed CallerOperatorCli (encodeRpcBirthCommand command) now deadline))
signed :: CallerPrincipal -> BS.ByteString -> Natural -> Natural -> VerifiedControlPlaneRequest
signed = signedWithLifetime 20000000

signedWithLifetime
  :: Natural -> CallerPrincipal -> BS.ByteString -> Natural -> Natural -> VerifiedControlPlaneRequest
signedWithLifetime lifetime caller body now deadline =
  must
    (decodeAndVerifyControlPlaneRequest 65536 verification (encodeSignedControlPlaneRequest envelope))
 where
  nonce = must (mkRequestNonce (BS.replicate 16 1))
  deadlineTime = authorityTimeFromMicros deadline
  envelope =
    must
      ( signControlPlaneRequest
          (signer caller)
          LifecycleMigrationApply
          LifecycleAuthorityRuntime
          scope
          authorityEpochGenesis
          deadlineTime
          nonce
          body
      )
  verification =
    must
      ( mkRequestVerificationContext
          (trustedRequestKeyFromSigner (signer caller))
          LifecycleMigrationApply
          LifecycleAuthorityRuntime
          scope
          authorityEpochGenesis
          deadlineTime
          nonce
          (authorityTimeFromMicros now)
          (must (authorityDurationFromMicros lifetime))
      )

data Fixture = Fixture
  { primary :: IORef (ModelBObservation RpcBirthRecord)
  , anchor :: IORef (ModelBObservation RpcBirthMarker)
  , source :: IORef (Either RpcBirthError RpcKeyRegistry)
  , clock :: IORef Natural
  , writes :: IORef Int
  , sourceReads :: IORef Int
  , stopAt :: IORef (Maybe Int)
  , loseReply :: IORef Bool
  , history :: IORef [RpcBirthRecord]
  }
newFixture :: IO Fixture
newFixture =
  Fixture
    <$> newIORef (ModelBObserved (version 1) legacyRecord)
    <*> newIORef ModelBMissing
    <*> newIORef (Right seeded)
    <*> newIORef 1000
    <*> newIORef 0
    <*> newIORef 0
    <*> newIORef Nothing
    <*> newIORef False
    <*> newIORef []
preparedFixture :: IO Fixture
preparedFixture = do
  fixture <- newFixture
  _ <- must <$> run fixture legacyRpcBirthServingMode (PrepareRpcBirth 1 keyA)
  pure fixture
current :: Fixture -> IO (ModelBObjectVersion, RpcBirthRecord)
current fixture = do
  observed <- readIORef (primary fixture)
  case observed of
    ModelBObserved revision record -> pure (revision, record)
    other -> error (show other)
pair :: Fixture -> IO (ModelBObservation RpcBirthRecord, ModelBObservation RpcBirthMarker)
pair fixture = (,) <$> readIORef (primary fixture) <*> readIORef (anchor fixture)
pin :: Fixture -> IO RpcBirthServingMode
pin fixture = do
  (_, record) <- current fixture
  let descriptor = maybe (error "fixture descriptor") id (rpcBirthDescriptor record)
  pure
    ( must
        ( registeredRpcBirthServingMode
            scope
            (rpcBirthDescriptorGeneration descriptor)
            (rpcBirthDescriptorDigest descriptor)
        )
    )
run :: Fixture -> RpcBirthServingMode -> RpcBirthCommand -> IO (Either RpcBirthError RpcBirthStatus)
run fixture mode command = executeRpcBirth (interpreter fixture) (context mode command 1000 2000000)
interpreter :: Fixture -> RpcBirthInterpreter IO
interpreter = interpreterWithClients clients

interpreterWithClients :: RegisteredClientTable -> Fixture -> RpcBirthInterpreter IO
interpreterWithClients configuredClients fixture = RpcBirthInterpreter dispatch
 where
  recordCodec = rpcBirthRecordCodec 524288 4 8 scope configuredClients
  dispatch :: AuthorityTime -> RpcBirthProgram result -> IO (Either RpcBirthError result)
  dispatch _ program = case program of
    ReadRpcBirthTime -> Right . authorityTimeFromMicros <$> readIORef (clock fixture)
    ReadRpcBirthRecord -> Right <$> readIORef (primary fixture)
    ReadRpcBirthMarker -> Right <$> readIORef (anchor fixture)
    ReadRpcBirthHomeSeed -> modifyIORef' (sourceReads fixture) (+ 1) >> readIORef (source fixture)
    CasRpcBirthRecord expected record -> do
      actual <- readIORef (primary fixture)
      if observedVersion actual /= Just expected
        then pure (Right (ModelBCasConflict actual))
        else do
          let canonical = must (decodeModelBValue recordCodec (must (encodeModelBValue recordCodec record)))
          modifyIORef' (history fixture) (<> [canonical])
          cas (primary fixture) canonical
    CasRpcBirthMarker expected marker -> do
      actual <- readIORef (anchor fixture)
      if observedVersion actual /= expected
        then pure (Right (ModelBCasConflict actual))
        else do
          let codecForMarker = rpcBirthMarkerCodec scope
              canonical = must (decodeModelBValue codecForMarker (must (encodeModelBValue codecForMarker marker)))
          cas (anchor fixture) canonical
  cas :: IORef (ModelBObservation value) -> value -> IO (Either RpcBirthError (ModelBCasResult value))
  cas ref value = do
    number <- atomicModifyIORef' (writes fixture) (\count -> (count + 1, count + 1))
    let revision = version (fromIntegral number + 1)
    writeIORef ref (ModelBObserved revision value)
    stop <- readIORef (stopAt fixture)
    lost <- readIORef (loseReply fixture)
    pure
      ( if stop == Just number
          then Left RpcBirthEffectTimedOut
          else Right (if lost then ModelBCasUnobservable "lost" else ModelBCasApplied revision value)
      )
observedVersion :: ModelBObservation value -> Maybe ModelBObjectVersion
observedVersion observed = case observed of ModelBObserved revision _ -> Just revision; _ -> Nothing
nativeBackend :: Fixture -> IO (Either RpcBirthError RpcKeyRegistry) -> RpcBirthNativeBackend
nativeBackend fixture seed =
  modelBRpcBirthBackend
    ( ModelBCasAdapter
        (\_ -> readIORef (primary fixture))
        (\_ -> fail "native timeout must not write primary")
    )
    primaryCoordinate
    ( ModelBCasAdapter
        (\_ -> readIORef (anchor fixture))
        (\_ -> fail "native timeout must not write marker")
    )
    markerCoordinate
    seed
 where
  authority = must (mkLongLivedCheckpointAuthority "home" "bucket" "authority" "kv")
  primaryCoordinate = must (mkClusterRetainedCoordinate authority "authority/admission")
  markerCoordinate = must (mkClusterRetainedCoordinate authority "authority/rpc-registration-birth")

-- Authored observation matrix: columns are missing, v1, v2, corrupt,
-- endpoint-unready and unobservable. Only confirmed revisions/absence may
-- serve; every closing failure retains its original recovery classification.
nativeSnapshotInputs :: [(String, ModelBObservation RpcBirthRecord)]
nativeSnapshotInputs =
  [ ("missing", ModelBMissing)
  , ("v1", ModelBObserved (version 1) legacyRecord)
  , ("v2", ModelBObserved (version 2) legacyRecord)
  , ("corrupt", ModelBCorrupt "known-corruption")
  , ("unready", ModelBEndpointUnready "endpoint-unready")
  , ("unobservable", ModelBUnobservable "read-unobservable")
  ]

nativeSnapshotCases
  :: [(String, ModelBObservation RpcBirthRecord, [ModelBObservation RpcBirthRecord])]
nativeSnapshotCases =
  zipWith (\(name, input) expected -> (name, input, expected)) nativeSnapshotInputs expectedRows
 where
  missing = ModelBMissing
  v1 = ModelBObserved (version 1) legacyRecord
  v2 = ModelBObserved (version 2) legacyRecord
  corrupt = ModelBCorrupt "known-corruption"
  unready = ModelBEndpointUnready "endpoint-unready"
  unobservable = ModelBUnobservable "read-unobservable"
  changed = ModelBUnobservable "RpcBirthSnapshotChanged"
  expectedRows =
    [ [missing, changed, changed, corrupt, unready, unobservable]
    , [changed, v1, changed, corrupt, unready, unobservable]
    , [changed, changed, v2, corrupt, unready, unobservable]
    , [changed, changed, changed, corrupt, unready, unobservable]
    , [changed, changed, changed, corrupt, unready, unobservable]
    , [changed, changed, changed, corrupt, unready, unobservable]
    ]

nativeSnapshotBackend :: Fixture -> ModelBObservation RpcBirthRecord -> RpcBirthNativeBackend
nativeSnapshotBackend fixture closing =
  modelBRpcBirthBackend
    ( ModelBCasAdapter
        (\_ -> readIORef (primary fixture))
        (\_ -> fail "snapshot observation wrote primary")
    )
    primaryCoordinate
    (ModelBCasAdapter markerRead (\_ -> fail "snapshot observation wrote marker"))
    markerCoordinate
    (modifyIORef' (sourceReads fixture) (+ 1) >> readIORef (source fixture))
 where
  authority = must (mkLongLivedCheckpointAuthority "home" "bucket" "authority" "kv")
  primaryCoordinate = must (mkClusterRetainedCoordinate authority "authority/admission")
  markerCoordinate = must (mkClusterRetainedCoordinate authority "authority/rpc-registration-birth")
  markerRead _ = do
    writeIORef (primary fixture) closing
    readIORef (anchor fixture)

markerCodec :: ModelBCodec RpcBirthMarker
markerCodec = rpcBirthMarkerCodec scope

legacyTrust :: Transport.RouteTrustRegistry
legacyTrust =
  must
    ( registeredRpcRouteTrust
        LifecycleAuthorityRuntime
        ( fromIntegral
            (maximum (1 : map (length . trustedCallersForRoute) (routesForRole LifecycleAuthorityRuntime)))
        )
        seeded
    )

trustView
  :: Transport.RouteTrustRegistry
  -> [(ControlPlaneRoute, CallerPrincipal, SigningKeyGeneration, BS.ByteString)]
trustView registry =
  [ ( route
    , trustedRequestCallerPrincipal key
    , trustedRequestGeneration key
    , trustedRequestPublicKeyBytes key
    )
  | route <- routesForRole LifecycleAuthorityRuntime
  , key <- Transport.routeTrustRegistryKeysFor route registry
  ]

mustPin :: RpcBirthDescriptor -> RpcBirthServingMode
mustPin descriptor =
  must
    ( registeredRpcBirthServingMode
        scope
        (rpcBirthDescriptorGeneration descriptor)
        (rpcBirthDescriptorDigest descriptor)
    )

nativeWritableBackend
  :: Fixture -> IO (Either RpcBirthError RpcKeyRegistry) -> RpcBirthNativeBackend
nativeWritableBackend = nativeWritableBackendWithClients clients

nativeWritableBackendWithClients
  :: RegisteredClientTable
  -> Fixture
  -> IO (Either RpcBirthError RpcKeyRegistry)
  -> RpcBirthNativeBackend
nativeWritableBackendWithClients configuredClients fixture seed = modelBRpcBirthBackend primaryAdapter primaryCoordinate markerAdapter markerCoordinate seed
 where
  authority = must (mkLongLivedCheckpointAuthority "home" "bucket" "authority" "kv")
  primaryCoordinate = must (mkClusterRetainedCoordinate authority "authority/admission")
  markerCoordinate = must (mkClusterRetainedCoordinate authority "authority/rpc-registration-birth")
  execute :: RpcBirthProgram (ModelBCasResult value) -> IO (ModelBCasResult value)
  execute program =
    result
      <$> runRpcBirthProgram
        (interpreterWithClients configuredClients fixture)
        (authorityTimeFromMicros 0)
        program
  result :: Either RpcBirthError (ModelBCasResult value) -> ModelBCasResult value
  result = either (ModelBCasUnobservable . Text.pack . show) id
  primaryAdapter = ModelBCasAdapter (\_ -> readIORef (primary fixture)) primaryCas
  primaryCas request = case request of
    ModelBReplace _ expected value -> execute (CasRpcBirthRecord expected value)
    _ -> pure (ModelBCasRefusedCorrupt "fixture primary write shape")
  markerAdapter = ModelBCasAdapter (\_ -> readIORef (anchor fixture)) markerCas
  markerCas request = case request of
    ModelBReplace _ expected value -> execute (CasRpcBirthMarker (Just expected) value)
    ModelBInitialize _ value -> execute (CasRpcBirthMarker Nothing value)
    _ -> pure (ModelBCasRefusedCorrupt "fixture marker write shape")

data HomeFault
  = HomeHealthy
  | HomeSealed
  | HomeDrift
  | HomeWrongPublic
  | HomeOversized
  | HomeRootRotated
  | HomeOwnKeyOnly
  | HomeCaller !ExternalLifecycleAuthorityCaller !RpcBirthCallerVaultFault
  deriving (Eq, Show)

data RpcBirthCallerVaultFault
  = CallerVaultHealthy
  | CallerVaultForbidden
  | CallerVaultUnavailable
  | CallerVaultShortLease
  | CallerVaultCancelOnce
  deriving (Eq, Show)

withRpcBirthCallerVaultFixture
  :: ExternalLifecycleAuthorityCaller
  -> RpcBirthCallerVaultFault
  -> (VaultAddress -> IORef [String] -> IO value)
  -> IO value
withRpcBirthCallerVaultFixture caller fault action =
  withHomeVault (HomeCaller caller fault) $ \session paths -> action (sessionAddress session) paths

rpcBirthHomeRegistryFixture :: RpcKeyRegistry
rpcBirthHomeRegistryFixture = seeded

withHomeVault :: HomeFault -> (VaultSession -> IORef [String] -> IO value) -> IO value
withHomeVault fault action = withSocketsDo $ bracket open close $ \listener -> do
  paths <- newIORef []
  address <- getSocketName listener
  case address of
    SockAddrInet port _ -> withAsync (forever (serve listener paths)) $ \worker -> do
      link worker
      session <-
        newVaultSession
          (VaultAddress ("http://127.0.0.1:" <> Text.pack (show port)))
          (SessionClock (pure 0))
          (pure (Right (LoginLease (VaultToken "fixture-role-token") 60 False)))
      action session paths
    _ -> fail "home Vault fixture listener is not IPv4"
 where
  open = do
    listener <- socket AF_INET Stream defaultProtocol
    setSocketOption listener ReuseAddr 1
    bind listener (SockAddrInet 0 (tupleToHostAddress (127, 0, 0, 1)))
    listen listener 8
    pure listener
  serve listener paths = bracket (accept listener) (close . fst) $ \(connection, _) -> do
    raw <- receive connection BS.empty
    request <- maybe (fail "invalid fixture framing") pure (Server.parseControlPlaneRequest raw)
    let path = Server.parsedRequestPath request
    modifyIORef' paths (<> [path])
    seen <- readIORef paths
    case fault of
      HomeCaller _ _
        | path /= "/v1/auth/kubernetes/login" ->
            unless
              ("x-vault-token: fixture-role-token" `BS.isInfixOf` BS8.map toLower raw)
              (fail "caller Vault request omitted its cached role token")
      _ -> pure ()
    body <- case path of
      "/v1/auth/kubernetes/login" -> case fault of
        HomeCaller caller selected -> do
          value <- either fail pure (eitherDecodeStrict' (Server.parsedRequestBody request))
          let role = case caller of
                LifecycleAuthorityOperator -> "prodbox-control-plane-operator"
                LifecycleAuthorityTestHarness -> "prodbox-control-plane-test-harness"
          case value of
            Object fields ->
              unless
                ( KeyMap.lookup "role" fields == Just (String role)
                    && KeyMap.lookup "jwt" fields == Just (String "synthetic-token")
                )
                (fail "caller Vault login changed its explicit role or held caller token")
            _ -> fail "caller Vault login body is not an object"
          when (selected == CallerVaultCancelOnce && length (filter (== path) seen) == 1) $ do
            closed <- timeout 5000000 (recv connection 1)
            unless (closed == Just BS.empty) (fail "cancelled caller login did not close its HTTP connection")
          pure $
            json
              [ "auth"
                  .= object
                    [ "client_token" .= ("fixture-role-token" :: Text)
                    , "accessor" .= ("fixture-role-accessor" :: Text)
                    , "lease_duration" .= (if selected == CallerVaultShortLease then (1 :: Int) else 60)
                    , "renewable" .= False
                    , "token_type" .= ("service" :: Text)
                    ]
              ]
        _ -> fail "unexpected login in the fixed-session Vault fixture"
      "/v1/sys/health" ->
        pure $
          json
            [ "initialized" .= True
            , "sealed" .= (fault == HomeSealed)
            , "cluster_id"
                .= ( if fault == HomeDrift && length (filter (== path) seen) >= 2
                       then ("22222222-2222-2222-2222-222222222222" :: Text)
                       else "11111111-1111-1111-1111-111111111111"
                   )
            ]
      _ -> case Text.stripPrefix "/v1/transit/keys/" (Text.pack path)
        >>= controlPlaneSigningKeyRefFromName of
        Just ref -> do
          let caller = controlPlaneSigningKeyPrincipal ref
              public =
                if fault == HomeWrongPublic && caller == CallerOperatorCli
                  then
                    requestSignerPublicKeyBytes
                      ( must
                          ( mkRequestSigner
                              caller
                              (must (mkSigningKeyGeneration 1))
                              (BS.replicate 32 250)
                          )
                      )
                  else requestSignerPublicKeyBytes (signer caller)
          checkCallerRef caller
          pure $
            json $
              [ "data"
                  .= object
                    [ "type" .= ("ed25519" :: Text)
                    , "latest_version" .= nativeVersion caller
                    , "keys"
                        .= object
                          ( ["1" .= object ["public_key" .= TextEncoding.decodeUtf8 (B64.encode public)]]
                              <> [ "2"
                                     .= object
                                       [ "public_key"
                                           .= TextEncoding.decodeUtf8
                                             (B64.encode (requestSignerPublicKeyBytes (signerAt caller 2)))
                                       ]
                                 | nativeVersion caller == 2
                                 ]
                          )
                    ]
              ]
                <> ["padding" .= Text.replicate 131072 "x" | fault == HomeOversized]
        Nothing -> case Text.stripPrefix "/v1/transit/sign/" (Text.pack path)
          >>= controlPlaneSigningKeyRefFromName of
          Just ref -> do
            checkCallerRef (controlPlaneSigningKeyPrincipal ref)
            value <- either fail pure (eitherDecodeStrict' (Server.parsedRequestBody request))
            case value of
              Object fields -> do
                let caller = controlPlaneSigningKeyPrincipal ref
                selectedVersion <- case KeyMap.lookup "key_version" fields of
                  Nothing -> pure (nativeVersion caller)
                  Just (Number 1) -> pure 1
                  Just (Number 2) | nativeVersion caller == 2 -> pure 2
                  _ -> fail "fixture signing version is not retained"
                bytes <- case KeyMap.lookup "input" fields of
                  Just (String encoded) -> either fail pure (B64.decode (TextEncoding.encodeUtf8 encoded))
                  _ -> fail "missing fixture signature input"
                signature <-
                  must
                    <$> signCanonicalBytesWithRequestCapability
                      (localRequestSigningCapability (signerAt caller selectedVersion))
                      bytes
                pure $
                  json
                    [ "data"
                        .= object
                          [ "signature"
                              .= ( "vault:v"
                                     <> Text.pack (show selectedVersion)
                                     <> ":"
                                     <> TextEncoding.decodeUtf8 (B64.encode signature)
                                 )
                          ]
                    ]
              _ -> fail "invalid fixture signing body"
          Nothing -> fail "unknown home Vault fixture path"
    let unrelated =
          fault == HomeOwnKeyOnly
            && case Text.stripPrefix "/v1/transit/keys/" (Text.pack path)
              >>= controlPlaneSigningKeyRefFromName of
              Just ref -> controlPlaneSigningKeyPrincipal ref /= CallerService LifecycleAuthorityRuntime
              Nothing -> False
        denied =
          path == "/v1/auth/kubernetes/login" && case fault of
            HomeCaller _ CallerVaultForbidden -> True
            _ -> False
        unavailable =
          path == "/v1/auth/kubernetes/login" && case fault of
            HomeCaller _ CallerVaultUnavailable -> True
            _ -> False
        status
          | denied = ReplyForbidden
          | unrelated = ReplyNotFound
          | otherwise = ReplyOk
        payload
          | denied = json ["errors" .= ["permission denied" :: Text]]
          | unrelated = json ["errors" .= ["unrelated key unavailable" :: Text]]
          | otherwise = body
    let cancelled =
          path == "/v1/auth/kubernetes/login" && case fault of
            HomeCaller _ CallerVaultCancelOnce -> length (filter (== path) seen) == 1
            _ -> False
    unless (unavailable || cancelled) (sendAll connection (Server.renderHttpResponse status payload))
  checkCallerRef actual = case fault of
    HomeCaller caller _ -> do
      let expected = case caller of
            LifecycleAuthorityOperator -> CallerOperatorCli
            LifecycleAuthorityTestHarness -> CallerTestHarness
      unless (actual == expected) (fail "caller Vault requested a different principal's key")
    _ -> pure ()
  receive connection accumulated = case Server.inspectControlPlaneRequestFraming accumulated of
    Left cause -> fail (show cause)
    Right (Server.ControlPlaneFramingComplete raw) -> pure raw
    Right Server.ControlPlaneFramingIncomplete -> do
      chunk <- recv connection 4096
      if BS.null chunk then fail "home Vault fixture EOF" else receive connection (accumulated <> chunk)
  nativeVersion :: CallerPrincipal -> Natural
  nativeVersion caller =
    if fault `elem` [HomeRootRotated, HomeOwnKeyOnly] && caller == CallerService LifecycleAuthorityRuntime
      then 2
      else 1
  signerAt :: CallerPrincipal -> Natural -> RequestSigner
  signerAt caller native =
    if native == 2
      then must (mkRequestSigner caller (must (mkSigningKeyGeneration 2)) (BS.replicate 32 250))
      else signer caller
  json = Lazy.toStrict . encode . object

migrationWritersRemainQuiesced :: AuthorityMigrationMode -> Bool
migrationWritersRemainQuiesced mode = case mode of
  AuthorityMigrationControlled state -> migrationAuthorityStatus state == MigrationWritersQuiesced
  AuthorityCleanInstall -> False
