{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneRetainedMaterialWorker
  ( controlPlaneRetainedMaterialWorkerSuite
  )
where

import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.RetainedMaterialEnvelope
  ( RetainedDestinationKeyPair
  , encodeRetainedDestinationOpening
  , generateRetainedDestinationKeyPair
  , openRetainedDestinationOpeningForGeneration
  , retainedDestinationPublicKey
  , retainedDestinationPublicKeyDigest
  )
import Prodbox.ControlPlane.RetainedMaterialWorker
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetSecretId (TargetAcmeEab)
  , TargetSecretPayload (AcmeEabMaterial, SesSmtpMaterial)
  , targetSecretPayloadId
  )
import Prodbox.Lifecycle.Authority.RetainedMaterial
  ( RetainedDeliveryIntent
  , RetainedMaterialRef
  , RetainedMaterialSchema (RetainedAcmeEabMaterial)
  , RetainedMaterialSource
  , RetainedMaterialTarget
  , RetainedSealIntent
  , SRetainedMaterialSchema (SRetainedAcmeEabMaterial)
  , mkRetainedDeliveryIntent
  , mkRetainedMaterialRef
  , mkRetainedMaterialTarget
  , mkRetainedSealIntent
  , retainedSourceReceiptRef
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityTime
  , authorityTimeFromMicros
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , TargetValueDigest
  , mkCredentialGeneration
  , mkTargetValueDigest
  )
import TestSupport

controlPlaneRetainedMaterialWorkerSuite :: SuiteBuilder ()
controlPlaneRetainedMaterialWorkerSuite =
  describe "Sprint 4.50 retained-home custody worker" $ do
    it "seals one generation and re-observes randomized-Transit replay without another CAS" $ do
      fixture <- freshFixture
      firstResult <- seal fixture eabPayload
      source <- expectSealed firstResult
      readIORef (fixtureCasWrites fixture) `shouldReturn` 1
      secondResult <- seal fixture eabPayload
      expectAlreadySealed source secondResult
      readIORef (fixtureEncryptCalls fixture) `shouldReturn` 2
      readIORef (fixtureCasWrites fixture) `shouldReturn` 1

    it "repairs a CAS-to-metadata crash despite a fresh Transit ciphertext on retry" $ do
      fixture <- freshFixture
      writeIORef (fixtureFailMetadataOnce fixture) True
      seal fixture eabPayload
        `shouldReturn` Left RetainedCustodyMetadataWriteFailed
      readIORef (fixtureCasWrites fixture) `shouldReturn` 1
      recovered <- seal fixture eabPayload
      _ <- expectRecovered recovered
      readIORef (fixtureEncryptCalls fixture) `shouldReturn` 2
      readIORef (fixtureCasWrites fixture) `shouldReturn` 1

    it "refuses cross-schema plaintext before Transit or KV access" $ do
      fixture <- freshFixture
      seal fixture smtpPayload
        `shouldReturn` Left RetainedCustodyPayloadSchemaMismatch
      readIORef (fixtureEncryptCalls fixture) `shouldReturn` 0
      readIORef (fixtureCasWrites fixture) `shouldReturn` 0

    it "rewraps only to the intent-bound X25519 key and target generation" $ do
      fixture <- freshFixture
      source <- seal fixture eabPayload >>= expectSealed
      destination <- generateRetainedDestinationKeyPair
      let delivery = deliveryIntent destination source
      rewrapped <-
        rewrapRetainedCustody
          SRetainedAcmeEabMaterial
          (fixtureBoundary fixture)
          source
          delivery
          (retainedDestinationPublicKey destination)
      case rewrapped of
        Left err -> expectationFailure ("rewrap unexpectedly failed: " <> show err)
        Right result -> do
          let opening =
                mustRight
                  ( encodeRetainedDestinationOpening
                      SRetainedAcmeEabMaterial
                      destination
                      (retainedCustodyDestinationEnvelope result)
                  )
          let opened =
                openRetainedDestinationOpeningForGeneration
                  SRetainedAcmeEabMaterial
                  generation1
                  opening
          fmap targetSecretPayloadId opened `shouldBe` Right TargetAcmeEab
          openRetainedDestinationOpeningForGeneration
            SRetainedAcmeEabMaterial
            generation2
            opening
            `shouldSatisfy` isLeft
      otherDestination <- generateRetainedDestinationKeyPair
      mismatched <-
        rewrapRetainedCustody
          SRetainedAcmeEabMaterial
          (fixtureBoundary fixture)
          source
          delivery
          (retainedDestinationPublicKey otherDestination)
      case mismatched of
        Left RetainedCustodyDestinationKeyMismatch -> pure ()
        other -> expectationFailure ("expected destination-key mismatch, got " <> show other)

    it "commits retirement only after exact physical-version absence" $ do
      fixture <- freshFixture
      source <- seal fixture eabPayload >>= expectSealed
      writeIORef (fixtureDestroyIsPhysical fixture) False
      retireRetainedCustody
        SRetainedAcmeEabMaterial
        (fixtureBoundary fixture)
        source
        `shouldReturn` Left RetainedCustodyStillPresent
      writeIORef (fixtureDestroyIsPhysical fixture) True
      retired <-
        retireRetainedCustody
          SRetainedAcmeEabMaterial
          (fixtureBoundary fixture)
          source
      retired `shouldSatisfy` isRetired

data Fixture = Fixture
  { fixtureCurrent :: !(IORef (Maybe (Natural, Map Text Text)))
  , fixtureVersions :: !(IORef (Map Natural (Map Text Text)))
  , fixtureMetadata :: !(IORef RetainedCustodyMetadataObservation)
  , fixturePlaintexts :: !(IORef (Map Text ByteString))
  , fixtureDestroyed :: !(IORef (Set Natural))
  , fixtureEncryptCalls :: !(IORef Natural)
  , fixtureCasWrites :: !(IORef Natural)
  , fixtureFailMetadataOnce :: !(IORef Bool)
  , fixtureDestroyIsPhysical :: !(IORef Bool)
  }

freshFixture :: IO Fixture
freshFixture =
  Fixture
    <$> newIORef Nothing
    <*> newIORef Map.empty
    <*> newIORef RetainedCustodyMetadataMissing
    <*> newIORef Map.empty
    <*> newIORef Set.empty
    <*> newIORef 0
    <*> newIORef 0
    <*> newIORef False
    <*> newIORef True

fixtureBoundary
  :: Fixture
  -> RetainedCustodyVaultBoundary 'RetainedAcmeEabMaterial IO
fixtureBoundary fixture =
  RetainedCustodyVaultBoundary
    { retainedCustodyReadCurrentData = do
        current <- readIORef (fixtureCurrent fixture)
        pure
          ( Right
              ( maybe
                  RetainedCustodyDataMissing
                  (uncurry RetainedCustodyDataPresent)
                  current
              )
          )
    , retainedCustodyReadMetadata = Right <$> readIORef (fixtureMetadata fixture)
    , retainedCustodyReadVersion = \version -> do
        destroyed <- Set.member version <$> readIORef (fixtureDestroyed fixture)
        versions <- readIORef (fixtureVersions fixture)
        pure
          ( Right
              ( if destroyed
                  then RetainedCustodyVersionMissing
                  else
                    maybe
                      RetainedCustodyVersionMissing
                      RetainedCustodyVersionPresent
                      (Map.lookup version versions)
              )
          )
    , retainedCustodyTransitEncrypt = \plaintext -> do
        call <- atomicNext (fixtureEncryptCalls fixture)
        let ciphertext = "vault:v1:cipher-" <> naturalText call
        modifyIORef' (fixturePlaintexts fixture) (Map.insert ciphertext plaintext)
        pure (Right ciphertext)
    , retainedCustodyTransitDecrypt = \ciphertext -> do
        plaintexts <- readIORef (fixturePlaintexts fixture)
        pure (maybe (Left "unknown ciphertext") Right (Map.lookup ciphertext plaintexts))
    , retainedCustodyHmac = \input ->
        pure
          ( Right
              ( "vault:v1:test-hmac-"
                  <> naturalText (fromIntegral (ByteString.length input))
                  <> "-"
                  <> naturalText (ByteString.foldl' (\total byte -> total + fromIntegral byte) (0 :: Natural) input)
              )
          )
    , retainedCustodyCompareAndSwap = \expected fields -> do
        current <- readIORef (fixtureCurrent fixture)
        let currentVersion = maybe 0 fst current
        if currentVersion /= expected
          then pure (Left "CAS mismatch")
          else do
            let version = currentVersion + 1
            modifyIORef' (fixtureCasWrites fixture) (+ 1)
            writeIORef (fixtureCurrent fixture) (Just (version, fields))
            modifyIORef' (fixtureVersions fixture) (Map.insert version fields)
            pure (Right version)
    , retainedCustodyWriteMetadata = \fields -> do
        failOnce <- readIORef (fixtureFailMetadataOnce fixture)
        if failOnce
          then do
            writeIORef (fixtureFailMetadataOnce fixture) False
            pure (Left "simulated metadata response loss")
          else do
            current <- readIORef (fixtureCurrent fixture)
            case current of
              Nothing -> pure (Left "data missing")
              Just (version, _) -> do
                writeIORef
                  (fixtureMetadata fixture)
                  (RetainedCustodyMetadataPresent version fields)
                pure (Right ())
    , retainedCustodyTombstoneVersion = \version -> do
        physical <- readIORef (fixtureDestroyIsPhysical fixture)
        if physical
          then modifyIORef' (fixtureDestroyed fixture) (Set.insert version)
          else pure ()
        pure (Right ())
    , retainedCustodyObserveVersionAbsent = \version ->
        Right . Set.member version <$> readIORef (fixtureDestroyed fixture)
    }

seal
  :: Fixture
  -> TargetSecretPayload
  -> IO
       ( Either
           RetainedCustodyWorkerError
           (RetainedCustodySealResult 'RetainedAcmeEabMaterial)
       )
seal fixture =
  sealRetainedCustody
    SRetainedAcmeEabMaterial
    now
    (fixtureBoundary fixture)
    sealIntent

deliveryIntent
  :: RetainedDestinationKeyPair 'RetainedAcmeEabMaterial
  -> RetainedMaterialSource 'RetainedAcmeEabMaterial
  -> RetainedDeliveryIntent 'RetainedAcmeEabMaterial
deliveryIntent destination source =
  mkRetainedDeliveryIntent
    deliveryOperation
    (retainedSourceReceiptRef source)
    target
    generation1
    attestation
    (retainedDestinationPublicKeyDigest (retainedDestinationPublicKey destination))
    deadline

expectSealed
  :: Either RetainedCustodyWorkerError (RetainedCustodySealResult schema)
  -> IO (RetainedMaterialSource schema)
expectSealed result = case result of
  Right (RetainedCustodySealed source) -> pure source
  other ->
    expectationFailure ("expected newly sealed custody, got " <> show other)
      >> fail "unreachable"

expectRecovered
  :: Either RetainedCustodyWorkerError (RetainedCustodySealResult schema)
  -> IO (RetainedMaterialSource schema)
expectRecovered result = case result of
  Right (RetainedCustodySealRecovered source) -> pure source
  other ->
    expectationFailure ("expected recovered custody, got " <> show other)
      >> fail "unreachable"

expectAlreadySealed
  :: RetainedMaterialSource schema
  -> Either RetainedCustodyWorkerError (RetainedCustodySealResult schema)
  -> IO ()
expectAlreadySealed expected result = case result of
  Right (RetainedCustodyAlreadySealed source) -> source `shouldBe` expected
  other -> expectationFailure ("expected idempotent custody replay, got " <> show other)

isRetired :: Either RetainedCustodyWorkerError RetainedCustodyRetirementResult -> Bool
isRetired result = case result of
  Right (RetainedCustodyRetired _) -> True
  _ -> False

isLeft :: Either left right -> Bool
isLeft value = case value of
  Left _ -> True
  Right _ -> False

atomicNext :: IORef Natural -> IO Natural
atomicNext counterRef = do
  modifyIORef' counterRef (+ 1)
  readIORef counterRef

sealIntent
  :: RetainedSealIntent 'RetainedAcmeEabMaterial
sealIntent =
  mustRight
    ( mkRetainedSealIntent
        sealOperation
        generation1
        permit
        bindingDigest
        deadline
        grace
    )

eabPayload, smtpPayload :: TargetSecretPayload
eabPayload = AcmeEabMaterial "eab-key-id" "eab-hmac-secret"
smtpPayload =
  SesSmtpMaterial
    ("email-smtp." <> (fixtureAwsRegion FixtureUsEast1) <> ".amazonaws.com")
    "587"
    "sender@example.test"
    "Prodbox"
    "reply@example.test"
    "smtp-user"
    "smtp-password"

generation1, generation2 :: CredentialGeneration
generation1 = mustRight (mkCredentialGeneration 1)
generation2 = mustRight (mkCredentialGeneration 2)

bindingDigest :: TargetValueDigest
bindingDigest = mustRight (mkTargetValueDigest (hexDigest 'a'))

sealOperation, deliveryOperation, permit, attestation :: RetainedMaterialRef
sealOperation = ref "seal-operation-1"
deliveryOperation = ref "delivery-operation-1"
permit = ref "permit-1"
attestation = ref "attestation-1"

target :: RetainedMaterialTarget 'RetainedAcmeEabMaterial
target = mustRight (mkRetainedMaterialTarget SRetainedAcmeEabMaterial "aws-run")

now, deadline, grace :: AuthorityTime
now = authorityTimeFromMicros 100
deadline = authorityTimeFromMicros 200
grace = authorityTimeFromMicros 300

ref :: Text -> RetainedMaterialRef
ref = mustRight . mkRetainedMaterialRef

hexDigest :: Char -> Text
hexDigest character = Text.replicate 64 (Text.singleton character)

naturalText :: Natural -> Text
naturalText = Text.pack . show

mustRight :: (Show err) => Either err value -> value
mustRight value = case value of
  Left err -> error (show err)
  Right result -> result
