{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Focused conformance for the typed Sprint 2.33 execution seam.
module BootstrapBrokerEngine
  ( bootstrapBrokerEngineSuite
  )
where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Bootstrap.Broker.Engine
import Prodbox.Bootstrap.Broker.Fence
  ( BootstrapFenceStoreObservation (..)
  , BootstrapLeaseObservation (..)
  , reloadBootstrapSessionFence
  )
import Prodbox.Bootstrap.Broker.Program
  ( BrokerCapabilityRefs
  , mkBrokerCapabilityRefs
  , mkPkiIssueRequest
  )
import Prodbox.Bootstrap.Broker.Protocol
  ( BrokerActionRequest
  , brokerActionDigest
  , brokerActionStorageGeneration
  , encodeBrokerControllerRequest
  , mkBrokerActionRequest
  , mkBrokerControllerRequest
  , mkBrokerPkiControllerRequest
  )
import Prodbox.Bootstrap.Broker.Routes
  ( BrokerBodyRequirement (..)
  , BrokerHttpMethod (..)
  , BrokerRoute (..)
  , allBrokerRoutes
  , brokerRouteBodyRequirement
  , brokerRouteCapabilityOp
  , brokerRouteMethod
  , brokerRoutePath
  )
import Prodbox.Bootstrap.Broker.StoreBoundary
  ( BootstrapStoreBoundary (..)
  , unavailableBootstrapStoreBoundary
  )
import Prodbox.Bootstrap.Broker.Types
import Prodbox.ControlPlane.AuthorityClock
  ( AuthorityClockObservation (..)
  , clockUncertaintyFromMicros
  )
import Prodbox.ControlPlane.CapabilityRef (refCoordinateDigest)
import Prodbox.ControlPlane.Coordinate
  ( CapabilityCoordinate
  , CoordinateDigest
  , mkAuthorityScope
  , mkCapabilityEndpoint
  , mkCoordinate
  , mkLogicalName
  , mkServiceIdentity
  )
import Prodbox.ControlPlane.Deadline
  ( RemainingDuration (..)
  , deadlineAtOffset
  , monotonicInstantFromMicros
  )
import Prodbox.Lifecycle.Lease
  ( authorityTimeFromMicros
  , mkOwnerNonce
  )
import Prodbox.Lifecycle.TargetCommitIntent (mkCredentialGeneration)
import TestSupport

bootstrapBrokerEngineSuite :: SuiteBuilder ()
bootstrapBrokerEngineSuite =
  describe "Sprint 2.33 typed Bootstrap Broker engine" $ do
    it "strictly decodes every registered method/path into its route" $
      withFixture $ \fixture ->
        forM_ allBrokerRoutes $ \route -> do
          let decoded =
                expectRight
                  ( decodeBrokerCall
                      (brokerRouteMethod route)
                      (brokerRoutePath route)
                      (requestBody fixture route)
                  )
          decodedBrokerRoute decoded `shouldBe` route
    it "refuses wrong methods and exact-body-contract violations" $
      withFixture $ \fixture -> do
        decodeBrokerCall BrokerGet (brokerRoutePath BrokerVaultSeal) (requestBody fixture BrokerVaultSeal)
          `shouldSatisfy` (isWrongMethod BrokerVaultSeal)
        decodeBrokerCall BrokerGet (brokerRoutePath BrokerHealth) "{}"
          `shouldSatisfy` (isBodyForbidden BrokerHealth)
        decodeBrokerCall BrokerPost (brokerRoutePath BrokerVaultSeal) ByteString.empty
          `shouldSatisfy` (isBodyRequired BrokerVaultSeal)
    it "prepares all fifteen actual programs under their exact capability" $
      withFixture $ \fixture -> do
        admissionLog <- newIORef []
        engine <- fixtureEngine fixture admissionLog failClosedExecutionBoundary
        forM_ allBrokerRoutes $ \route -> do
          decoded <- decodeFixture fixture route
          prepared <- prepareFixture engine decoded
          preparedBrokerRoute prepared `shouldBe` route
          preparedBrokerCapabilityOp prepared `shouldBe` brokerRouteCapabilityOp route
          admitted <- admitFixture engine prepared
          admittedBrokerRoute admitted `shouldBe` route
          admittedBrokerCapabilityOp admitted `shouldBe` brokerRouteCapabilityOp route
          admittedBrokerCapabilityDigest admitted
            `shouldBe` preparedBrokerCapabilityDigest prepared
        admittedDigests <- readIORef admissionLog
        length admittedDigests `shouldBe` length allBrokerRoutes
    it "refuses a Vault mutation before the physical boundary when the Lease is missing" $
      withFixture $ \fixture -> do
        physicalCalls <- newIORef (0 :: Int)
        admissionLog <- newIORef []
        engine <-
          fixtureEngine
            fixture
            admissionLog
            (missingLeaseExecutionBoundary fixture physicalCalls)
        decoded <- decodeFixture fixture BrokerVaultSeal
        prepared <- prepareFixture engine decoded
        admitted <- admitFixture engine prepared
        let context =
              mkEngineExecutionContext
                (deadlineAtOffset (monotonicInstantFromMicros 0) (RemainingDuration 10_000))
        outcome <- executeBrokerCall engine context admitted
        outcome `shouldSatisfy` isFenceRefusal
        readIORef physicalCalls `shouldReturn` 0

isFenceRefusal :: Either BrokerEngineError SomeBrokerResponse -> Bool
isFenceRefusal outcome = case outcome of
  Left (EngineFenceUseRefused _) -> True
  _ -> False

isWrongMethod :: BrokerRoute -> Either BrokerEngineError value -> Bool
isWrongMethod expected outcome = case outcome of
  Left (EngineWrongMethod actual) -> actual == expected
  _ -> False

isBodyForbidden :: BrokerRoute -> Either BrokerEngineError value -> Bool
isBodyForbidden expected outcome = case outcome of
  Left (EngineBodyForbidden actual) -> actual == expected
  _ -> False

isBodyRequired :: BrokerRoute -> Either BrokerEngineError value -> Bool
isBodyRequired expected outcome = case outcome of
  Left (EngineBodyRequired actual) -> actual == expected
  _ -> False

data Fixture = Fixture
  { fixtureAction :: !BrokerActionRequest
  , fixturePristine :: !PristineStorageProof
  , fixtureRecovery :: !RecoveryCustodyReceipt
  , fixtureAmbiguity :: !InitAmbiguity
  , fixtureResetProof :: !PristineResetProof
  , fixtureSessionId :: !RootSessionId
  , fixtureChildBinding :: !ChildCustodyBinding
  , fixtureNonce :: !DeliveryNonce
  , fixtureAttestation :: !ChildAttestation
  , fixtureCapabilityRefs :: !BrokerCapabilityRefs
  }

withFixture :: (Fixture -> Expectation) -> Expectation
withFixture assertion =
  either (expectationFailure . ("invalid engine fixture: " ++)) assertion buildFixture

buildFixture :: Either String Fixture
buildFixture = do
  transaction <- bootstrap (mkBootstrapTransactionId "engine-root")
  replacementTransaction <- bootstrap (mkBootstrapTransactionId "engine-root-next")
  generation <- bootstrap (mkVaultStorageGeneration "engine-storage")
  replacementGeneration <- bootstrap (mkVaultStorageGeneration "engine-storage-next")
  schema <- bootstrap (mkBootstrapSchemaVersion 1)
  actionDigest <- digest 'a'
  preparedDigest <- digest 'b'
  responseDigest <- digest 'c'
  bundleDigest <- digest 'd'
  acknowledgementDigest <- digest 'e'
  burnKeyDigest <- digest 'f'
  recoveryFingerprint <-
    bootstrap (mkRecoveryRecipientFingerprint (Text.replicate 64 "a"))
  burnFingerprint <-
    bootstrap (mkBurnRecipientFingerprint (Text.replicate 40 "b"))
  sealedPrivateKey <-
    bootstrap (mkSealedRecoveryRecipientPrivateKey "sealed-private-key")
  commitment <-
    bootstrap
      ( mkInitRecipientCommitment
          1
          1
          ["cmVjb3ZlcnktcHVibGljLWtleQ=="]
          recoveryFingerprint
          burnFingerprint
          burnKeyDigest
      )
  encryptedShare <- bootstrap (mkPgpEncryptedShare "encrypted-share")
  burnCiphertext <- bootstrap (mkBurnTokenCiphertext "burn-token")
  recoveredShare <- bootstrap (mkRecoveredUnsealShare "recovered-share")
  bundleCiphertext <- bootstrap (mkPasswordAeadCiphertext "bundle-ciphertext")
  let binding = RootInitBinding transaction generation
      pristine = mkPristineStorageProof binding actionDigest
      prepared =
        mkPreparedInitEnvelope
          pristine
          schema
          sealedPrivateKey
          commitment
          preparedDigest
  encryptedResponse <-
    bootstrap
      ( mkEncryptedInitResponseReceipt
          prepared
          [encryptedShare]
          burnCiphertext
          responseDigest
      )
  payload <-
    bootstrap (mkFinalUnlockBundlePayload encryptedResponse [recoveredShare])
  let bundle = mkFinalUnlockBundle payload bundleCiphertext bundleDigest
      recovery = mkRecoveryCustodyReceipt bundle acknowledgementDigest
      ambiguity = mkInitAmbiguity prepared
      replacementBinding = RootInitBinding replacementTransaction replacementGeneration
      replacementPristine = mkPristineStorageProof replacementBinding actionDigest
      establishedAbsence = mkEstablishedStateAbsence binding actionDigest
      responseAbsence = mkDurableInitResponseAbsence binding responseDigest
      baselineAbsence = mkBaselineStateAbsence binding bundleDigest
  resetProof <-
    bootstrap
      ( mkPristineResetProof
          ambiguity
          replacementPristine
          establishedAbsence
          responseAbsence
          baselineAbsence
      )
  sessionId <- bootstrap (mkRootSessionId "engine-session")
  childId <- bootstrap (mkChildId "engine-child")
  custodyGeneration <- bootstrap (mkCustodyGeneration 1)
  nonce <- bootstrap (mkDeliveryNonce "engine-delivery")
  let attestation = mkChildAttestation actionDigest
  let childBinding =
        ChildCustodyBinding
          { childCustodyChildId = childId
          , childCustodyStorageGeneration = generation
          , childCustodyGeneration = custodyGeneration
          , childCustodyTransactionId = transaction
          }
      action = mkBrokerActionRequest generation actionDigest
  pure
    Fixture
      { fixtureAction = action
      , fixturePristine = pristine
      , fixtureRecovery = recovery
      , fixtureAmbiguity = ambiguity
      , fixtureResetProof = resetProof
      , fixtureSessionId = sessionId
      , fixtureChildBinding = childBinding
      , fixtureNonce = nonce
      , fixtureAttestation = attestation
      , fixtureCapabilityRefs = capabilityRefs
      }

capabilityRefs :: BrokerCapabilityRefs
capabilityRefs =
  mkBrokerCapabilityRefs
    (coordinate "observe")
    (coordinate "mutate")
    (coordinate "baseline")
    (coordinate "pki")

coordinate :: Text -> CapabilityCoordinate
coordinate name =
  mkCoordinate
    (expectRight (mkServiceIdentity "bootstrap-broker"))
    (expectRight (mkAuthorityScope "home/prodbox"))
    (expectRight (mkCapabilityEndpoint "127.0.0.1:30444"))
    (expectRight (mkLogicalName name))
    (expectRight (mkCredentialGeneration 1))

requestBody :: Fixture -> BrokerRoute -> ByteString
requestBody fixture route = case brokerRouteBodyRequirement route of
  BrokerBodyForbidden -> ByteString.empty
  BrokerBodyRequired
    | route == BrokerVaultPkiIssueTestCertificate ->
        encodeBrokerControllerRequest
          ( mkBrokerPkiControllerRequest
              (fixtureAction fixture)
              (expectRight (mkPkiIssueRequest "engine.test" 300))
          )
    | otherwise ->
        encodeBrokerControllerRequest
          (expectRight (mkBrokerControllerRequest route (fixtureAction fixture)))

decodeFixture :: Fixture -> BrokerRoute -> IO SomeDecodedBrokerCall
decodeFixture fixture route =
  pure
    ( expectRight
        ( decodeBrokerCall
            (brokerRouteMethod route)
            (brokerRoutePath route)
            (requestBody fixture route)
        )
    )

prepareFixture
  :: BrokerEngine IO
  -> SomeDecodedBrokerCall
  -> IO SomePreparedBrokerCall
prepareFixture engine decoded = do
  outcome <- prepareBrokerCall engine decoded
  pure (expectRight outcome)

admitFixture
  :: BrokerEngine IO
  -> SomePreparedBrokerCall
  -> IO SomeAdmittedBrokerCall
admitFixture engine prepared = do
  outcome <- admitBrokerCall engine prepared
  pure (expectRight outcome)

fixtureEngine
  :: Fixture
  -> IORef [CoordinateDigest]
  -> BrokerEngineBoundary IO
  -> IO (BrokerEngine IO)
fixtureEngine fixture admissionLog executionBoundary =
  pure
    ( expectRight
        ( mkBrokerEngine
            (fixtureCapabilityRefs fixture)
            64
            executionBoundary
              { engineEvidenceBoundary = evidenceBoundary fixture
              , engineAdmitCapability = \reference _ -> do
                  modifyIORef' admissionLog (refCoordinateDigest reference :)
                  pure (Right ())
              }
        )
    )

evidenceBoundary :: Fixture -> BrokerProgramEvidenceBoundary IO
evidenceBoundary fixture =
  BrokerProgramEvidenceBoundary
    { resolvePristineStorageProof = \_ -> pure (Right (fixturePristine fixture))
    , resolveUnsealRecoveryCustody = \_ -> pure (Right (fixtureRecovery fixture))
    , resolveUnlockRotationCustody = \_ -> pure (Right (fixtureRecovery fixture))
    , resolveBaselineCustodyAndSession =
        \_ -> pure (Right (fixtureRecovery fixture, fixtureSessionId fixture))
    , resolveAmbiguousResetEvidence =
        \_ -> pure (Right (fixtureAmbiguity fixture, fixtureResetProof fixture))
    , resolveChildCustodyBinding = \_ -> pure (Right (fixtureChildBinding fixture))
    , resolveChildRecoveryDeliveryEvidence =
        \_ ->
          pure
            ( Right
                ( fixtureChildBinding fixture
                , fixtureNonce fixture
                , fixtureAttestation fixture
                )
            )
    , resolveChildRecoveryObservation =
        \_ -> pure (Right (fixtureChildBinding fixture, fixtureNonce fixture))
    }

failClosedExecutionBoundary :: BrokerEngineBoundary IO
failClosedExecutionBoundary =
  BrokerEngineBoundary
    { engineEvidenceBoundary = error "test replaces evidence boundary"
    , engineResolveRootInitCryptoParameters =
        \_ -> pure (Left (EngineBoundaryRefused "not executing"))
    , engineAdmitCapability = \_ _ -> pure (Right ())
    , engineBeginCapabilityExecution = \_ _ -> pure (Right ())
    , engineAcquireMutationFence =
        \_ _ _ _ _ -> pure (Left (EngineBoundaryRefused "not executing"))
    , engineObserveFenceUse =
        \_ -> pure (Left (EngineBoundaryRefused "not executing"))
    , engineReleaseMutationFence =
        \_ _ -> pure (Left (EngineBoundaryRefused "not executing"))
    , engineRunPhysicalCall =
        \_ -> pure (Left (EngineBoundaryRefused "not executing"))
    , engineRunLocalCall =
        \_ -> pure (Left (EngineBoundaryRefused "not executing"))
    , engineSecretWorkerBoundary = Nothing
    , enginePgpBoundary = Nothing
    , engineInMemoryBoundary = Nothing
    , engineStoreBoundary = unusedStoreBoundary
    }

missingLeaseExecutionBoundary
  :: Fixture -> IORef Int -> BrokerEngineBoundary IO
missingLeaseExecutionBoundary fixture physicalCalls =
  failClosedExecutionBoundary
    { engineAcquireMutationFence = \_ _ action requestDigest _ ->
        pure
          ( bootstrapError
              ( reloadBootstrapSessionFence
                  1
                  (expectRight (mkOwnerNonce "engine-owner"))
                  (brokerActionDigest action)
                  requestDigest
                  (brokerActionStorageGeneration action)
                  1_000_000
              )
          )
    , engineObserveFenceUse = \fence ->
        pure
          ( Right
              EngineFenceUseObservation
                { engineFenceMonotonicNow = monotonicInstantFromMicros 0
                , engineFenceAuthorityClock =
                    AuthorityTimeTrusted
                      (authorityTimeFromMicros 10)
                      (clockUncertaintyFromMicros 0)
                , engineFenceStoreObservation = BootstrapFenceStoreHeld fence
                , engineFenceLeaseObservation = BootstrapLeaseMissing
                }
          )
    , engineRunPhysicalCall = \_ -> do
        modifyIORef' physicalCalls (+ 1)
        pure (Left (EngineBoundaryRefused "unexpected physical call"))
    , engineEvidenceBoundary = evidenceBoundary fixture
    , engineStoreBoundary =
        unavailableBootstrapStoreBoundary
          { observeVaultStorageGeneration =
              pure (Right (pristineStorageBinding (fixturePristine fixture)))
          }
    }

unusedStoreBoundary :: BootstrapStoreBoundary IO
unusedStoreBoundary = unavailableBootstrapStoreBoundary

digest :: Char -> Either String ArtifactDigest
digest character = bootstrap (mkArtifactDigest (Text.replicate 64 (Text.singleton character)))

bootstrap :: (Show error) => Either error value -> Either String value
bootstrap = either (Left . show) Right

bootstrapError :: (Show error) => Either error value -> Either EngineBoundaryError value
bootstrapError = either (Left . EngineBoundaryRefused . Text.pack . show) Right

expectRight :: (Show error) => Either error value -> value
expectRight = either (error . show) id
