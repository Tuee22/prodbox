{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneFederationBootstrap
  ( controlPlaneFederationBootstrapSuite
  )
where

import Data.ByteString qualified as ByteString
import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker.Request (requestDigestForBytes)
import Prodbox.Bootstrap.Broker.Types
  ( ArtifactDigest
  , mkArtifactDigest
  )
import Prodbox.Cluster.FederationRegistration
import Prodbox.ControlPlane.FederationBootstrapCoordinator
import Prodbox.ControlPlane.FederationBootstrapCrypto
import Prodbox.ControlPlane.TargetSecretAgentExecution (mkTargetAgentIdentity)
import TestSupport

controlPlaneFederationBootstrapSuite :: SuiteBuilder ()
controlPlaneFederationBootstrapSuite =
  describe "federation two-worker bootstrap coordinator" $ do
    it "checkpoints ciphertext before cleanup and closes the complete aggregate" $ do
      fixture <- federationFixture
      state <- newIORef (initialState fixture)
      checkpoint <- newIORef Nothing
      calls <- newIORef []

      result <-
        coordinateFederationBootstrap
          (authorityBoundary fixture calls state)
          (childBoundary fixture calls 10)
          (checkpointBoundary calls checkpoint)
          (fixtureIntent fixture)

      result `shouldBe` Right (fixtureCustody fixture)
      readIORef checkpoint `shouldReturn` Nothing
      (reverse <$> readIORef calls)
        `shouldReturn` [ "prepare"
                       , "time"
                       , "observe"
                       , "create-recipient"
                       , "time"
                       , "record-recipient"
                       , "observe-checkpoint"
                       , "time"
                       , "continue-delivery"
                       , "create-checkpoint"
                       , "cleanup-child"
                       , "record-delivery"
                       , "observe-checkpoint"
                       , "delete-checkpoint"
                       , "checkpoint-absent"
                       ]

    it "resumes from a ciphertext-only checkpoint without recreating either key" $ do
      fixture <- federationFixture
      state <- newIORef (stateThroughEnvelope fixture)
      checkpoint <- newIORef (Just (fixtureCheckpoint fixture))
      calls <- newIORef []

      result <-
        coordinateFederationBootstrap
          (authorityBoundary fixture calls state)
          (childBoundary fixture calls 10)
          (checkpointBoundary calls checkpoint)
          (fixtureIntent fixture)

      result `shouldBe` Right (fixtureCustody fixture)
      observedCalls <- readIORef calls
      observedCalls `shouldNotContain` ["create-recipient"]
      observedCalls `shouldNotContain` ["continue-delivery"]
      readIORef checkpoint `shouldReturn` Nothing

    it "refuses a divergent checkpoint instead of deleting unrelated ciphertext" $ do
      fixture <- federationFixture
      divergent <- divergentCheckpoint fixture
      state <- newIORef (stateThroughCustody fixture)
      checkpoint <- newIORef (Just divergent)
      calls <- newIORef []

      result <-
        coordinateFederationBootstrap
          (authorityBoundary fixture calls state)
          (childBoundary fixture calls 10)
          (checkpointBoundary calls checkpoint)
          (fixtureIntent fixture)

      result `shouldBe` Left FederationBootstrapCoordinatorCheckpointConflict
      readIORef checkpoint `shouldReturn` Just divergent
      readIORef calls `shouldReturn` ["observe-checkpoint", "observe", "time", "prepare"]

    it "refuses an elapsed absolute deadline before creating a child Job" $ do
      fixture <- federationFixture
      state <- newIORef (initialState fixture)
      checkpoint <- newIORef Nothing
      calls <- newIORef []

      result <-
        coordinateFederationBootstrap
          (authorityBoundary fixture calls state)
          (childBoundary fixture calls 100)
          (checkpointBoundary calls checkpoint)
          (fixtureIntent fixture)

      result `shouldBe` Left FederationBootstrapCoordinatorDeadlineElapsed
      readIORef calls `shouldReturn` ["time", "prepare"]

    it "accepts only exact 32-byte X25519 public keys" $ do
      fixture <- federationFixture
      mkChildBootstrapRecipientAttestation
        (fixtureIntent fixture)
        (fixtureChildWorker fixture)
        (ByteString.replicate 33 0x11)
        `shouldBe` Left FederationRegistrationPublicKeyInvalid

    it "keeps both plaintext payloads inside the two worker continuations" $ do
      fixture <- federationFixture
      (childSession, recipient) <-
        accepted
          =<< prepareFederationChildRecipient
            (fixtureIntent fixture)
            (fixtureChildWorker fixture)
      credential <-
        accepted
          ( mkScopedTransitCredential
              (fixtureIntent fixture)
              (digest 'e')
              "s.scoped-transit-token"
          )
      (parentSession, envelope) <-
        accepted
          =<< prepareFederationParentEnvelope
            recipient
            (fixtureParentWorker fixture)
            credential
      returnMaterial <-
        accepted
          ( mkFederationChildReturnMaterial
              "encrypted-parent-metadata-input"
              "encrypted-parent-kubeconfig-input"
          )
      childCheckpoint <-
        accepted
          =<< completeFederationChildDelivery
            childSession
            envelope
            (applyScopedCredential fixture returnMaterial)
      delivery <-
        accepted
          ( mkChildBootstrapDeliveryReceipt
              envelope
              (fixtureChildWorker fixture)
              (childBootstrapDeliveryChildKubernetesUid (fixtureIntent fixture))
              "7"
              (digest '7')
              (federationCheckpointParentCiphertext childCheckpoint)
              (fixtureChildCleanup fixture)
          )
      parentCheckpoint <-
        accepted
          =<< completeFederationParentCustody
            parentSession
            delivery
            commitChildReturnMaterial
      custody <-
        accepted
          ( finalizeFederationParentCustody
              parentCheckpoint
              (fixtureParentCleanup fixture)
          )

      parentBootstrapCustodyChildDelivery custody `shouldBe` delivery
      federationParentCheckpointWorker parentCheckpoint
        `shouldBe` fixtureParentWorker fixture

data FederationFixture = FederationFixture
  { fixtureIntent :: !ChildBootstrapDeliveryIntent
  , fixtureChildWorker :: !FederationWorkerBinding
  , fixtureParentWorker :: !FederationWorkerBinding
  , fixtureRecipient :: !ChildBootstrapRecipientAttestation
  , fixtureEnvelope :: !ParentBootstrapEnvelope
  , fixtureCheckpoint :: !FederationChildDeliveryCheckpoint
  , fixtureChildCleanup :: !FederationWorkerCleanup
  , fixtureParentCleanup :: !FederationWorkerCleanup
  , fixtureDelivery :: !ChildBootstrapDeliveryReceipt
  , fixtureCustody :: !ParentBootstrapCustodyReceipt
  }

federationFixture :: IO FederationFixture
federationFixture = do
  childUid <- accepted (mkChildKubernetesUid "child-kubernetes-uid")
  targetAgent <-
    accepted
      (mkTargetAgentIdentity ("parent@sha256:" <> Text.replicate 64 "a"))
  intent <-
    accepted
      ( mkChildBootstrapDeliveryIntent
          "parent"
          "child"
          childUid
          targetAgent
          "https://authority.parent.example"
          "https://vault.parent.example"
          "prodbox-child-seal-child"
          (digest 'a')
          (digest 'b')
          "prodbox-federation-parent-worker"
          "prodbox-federation-child-worker"
          1
          1
          100
          (requestDigestForBytes "federation-bootstrap-request")
          (digest 'c')
          (digest 'd')
      )
  childWorker <-
    accepted
      ( mkFederationWorkerBinding
          "child"
          (digest 'b')
          "child-job-uid"
          "child-pod-uid"
          "prodbox-federation-child-worker"
          "child-service-account-uid"
      )
  parentWorker <-
    accepted
      ( mkFederationWorkerBinding
          "parent"
          (digest 'a')
          "parent-job-uid"
          "parent-pod-uid"
          "prodbox-federation-parent-worker"
          "parent-service-account-uid"
      )
  recipient <-
    accepted
      ( mkChildBootstrapRecipientAttestation
          intent
          childWorker
          (ByteString.replicate 32 0x11)
      )
  envelope <-
    accepted
      ( mkParentBootstrapEnvelope
          recipient
          parentWorker
          (ByteString.replicate 32 0x22)
          "child-key-encrypted-transit-credential"
          (digest 'e')
      )
  let childCleanup =
        mkFederationWorkerCleanup
          childWorker
          (digest '1')
          (digest '2')
          (digest '3')
      parentCleanup =
        mkFederationWorkerCleanup
          parentWorker
          (digest '4')
          (digest '5')
          (digest '6')
  checkpoint <-
    accepted
      ( mkFederationChildDeliveryCheckpoint
          envelope
          childWorker
          childUid
          "7"
          (digest '7')
          "parent-key-encrypted-child-metadata"
      )
  delivery <-
    accepted
      ( mkChildBootstrapDeliveryReceipt
          envelope
          childWorker
          childUid
          "7"
          (digest '7')
          "parent-key-encrypted-child-metadata"
          childCleanup
      )
  custody <-
    accepted
      ( mkParentBootstrapCustodyReceipt
          delivery
          (digest '8')
          (digest '9')
          (digest 'a')
          parentCleanup
      )
  pure
    FederationFixture
      { fixtureIntent = intent
      , fixtureChildWorker = childWorker
      , fixtureParentWorker = parentWorker
      , fixtureRecipient = recipient
      , fixtureEnvelope = envelope
      , fixtureCheckpoint = checkpoint
      , fixtureChildCleanup = childCleanup
      , fixtureParentCleanup = parentCleanup
      , fixtureDelivery = delivery
      , fixtureCustody = custody
      }

divergentCheckpoint
  :: FederationFixture -> IO FederationChildDeliveryCheckpoint
divergentCheckpoint fixture = do
  let current = fixtureEnvelope fixture
  envelope <-
    accepted
      ( mkParentBootstrapEnvelope
          (parentBootstrapEnvelopeChildRecipient current)
          (parentBootstrapEnvelopeWorker current)
          (ByteString.replicate 32 0x33)
          "different-child-key-encrypted-transit-credential"
          (digest 'f')
      )
  accepted
    ( mkFederationChildDeliveryCheckpoint
        envelope
        (fixtureChildWorker fixture)
        (childBootstrapDeliveryChildKubernetesUid (fixtureIntent fixture))
        "7"
        (digest '7')
        "parent-key-encrypted-child-metadata"
    )

authorityBoundary
  :: FederationFixture
  -> IORef [Text]
  -> IORef FederationRegistrationState
  -> FederationBootstrapAuthorityBoundary IO
authorityBoundary fixture calls state =
  FederationBootstrapAuthorityBoundary
    { authorityPrepareFederationBootstrap = \intent -> do
        called calls "prepare"
        pure (Right intent)
    , authorityObserveFederationBootstrap = \_ -> do
        called calls "observe"
        Right <$> readIORef state
    , authorityRecordFederationChildRecipient = \recipient -> do
        called calls "record-recipient"
        writeIORef state (stateThroughEnvelope fixture)
        if recipient == fixtureRecipient fixture
          then pure (Right (fixtureEnvelope fixture))
          else pure (Left "recipient mismatch")
    , authorityRecordFederationChildDelivery = \delivery -> do
        called calls "record-delivery"
        writeIORef state (stateThroughCustody fixture)
        if delivery == fixtureDelivery fixture
          then pure (Right (fixtureCustody fixture))
          else pure (Left "delivery mismatch")
    }

childBoundary
  :: FederationFixture
  -> IORef [Text]
  -> Natural
  -> FederationBootstrapChildBoundary IO
childBoundary fixture calls now =
  FederationBootstrapChildBoundary
    { observeFederationBootstrapTimeMicros =
        called calls "time" >> pure (Right now)
    , createOrRecoverFederationChildRecipient = \_ -> do
        called calls "create-recipient"
        pure (Right (fixtureRecipient fixture))
    , continueFederationChildDelivery = \_ -> do
        called calls "continue-delivery"
        pure (Right (fixtureCheckpoint fixture))
    , cleanupFederationChildWorker = \_ -> do
        called calls "cleanup-child"
        pure (Right (fixtureChildCleanup fixture))
    }

checkpointBoundary
  :: IORef [Text]
  -> IORef (Maybe FederationChildDeliveryCheckpoint)
  -> FederationBootstrapCheckpointBoundary IO
checkpointBoundary calls checkpoint =
  FederationBootstrapCheckpointBoundary
    { observeFederationChildDeliveryCheckpoint = \_ -> do
        called calls "observe-checkpoint"
        Right <$> readIORef checkpoint
    , createFederationChildDeliveryCheckpoint = \_ value -> do
        called calls "create-checkpoint"
        writeIORef checkpoint (Just value)
        pure (Right value)
    , deleteFederationChildDeliveryCheckpoint = \_ value -> do
        called calls "delete-checkpoint"
        observed <- readIORef checkpoint
        if observed == Just value
          then writeIORef checkpoint Nothing >> pure (Right ())
          else pure (Left "checkpoint mismatch")
    , observeFederationChildDeliveryCheckpointAbsent = \_ -> do
        called calls "checkpoint-absent"
        (Right . (== Nothing)) <$> readIORef checkpoint
    }

initialState :: FederationFixture -> FederationRegistrationState
initialState fixture =
  must (newFederationRegistrationState (fixtureIntent fixture))

stateThroughEnvelope :: FederationFixture -> FederationRegistrationState
stateThroughEnvelope fixture =
  must $ do
    recipient <-
      applyFederationRegistrationCommand
        (initialState fixture)
        (RecordFederationChildRecipient (fixtureRecipient fixture))
    applyFederationRegistrationCommand
      recipient
      (RecordFederationParentEnvelope (fixtureEnvelope fixture))

stateThroughCustody :: FederationFixture -> FederationRegistrationState
stateThroughCustody fixture =
  must $ do
    delivery <-
      applyFederationRegistrationCommand
        (stateThroughEnvelope fixture)
        (RecordFederationChildDelivery (fixtureDelivery fixture))
    applyFederationRegistrationCommand
      delivery
      (CompleteFederationBootstrapCustody (fixtureCustody fixture))

called :: IORef [Text] -> Text -> IO ()
called calls name = modifyIORef' calls (name :)

applyScopedCredential
  :: FederationFixture
  -> FederationChildReturnMaterial
  -> ScopedTransitCredential
  -> IO (Either Text FederationChildApplied)
applyScopedCredential fixture returnMaterial credential =
  withScopedTransitCredential credential $ \address key token ->
    if address == childBootstrapDeliveryParentVaultAddress (fixtureIntent fixture)
      && key == childBootstrapDeliveryTransitKey (fixtureIntent fixture)
      && token == "s.scoped-transit-token"
      then
        pure
          ( firstText
              ( mkFederationChildApplied
                  (childBootstrapDeliveryChildKubernetesUid (fixtureIntent fixture))
                  "7"
                  (digest '7')
                  returnMaterial
              )
          )
      else pure (Left "scoped Transit credential binding mismatch")

commitChildReturnMaterial
  :: FederationChildReturnMaterial
  -> IO (Either Text (ArtifactDigest, ArtifactDigest, ArtifactDigest))
commitChildReturnMaterial material =
  withFederationChildReturnMaterial material $ \metadata kubeconfig ->
    if metadata == "encrypted-parent-metadata-input"
      && kubeconfig == "encrypted-parent-kubeconfig-input"
      then pure (Right (digest '8', digest '9', digest 'a'))
      else pure (Left "child return material mismatch")

firstText :: (Show error) => Either error value -> Either Text value
firstText value = case value of
  Left failure -> Left (Text.pack (show failure))
  Right result -> Right result

digest :: Char -> ArtifactDigest
digest character = must (mkArtifactDigest (Text.replicate 64 (Text.singleton character)))

must :: (Show error) => Either error value -> value
must value = case value of
  Left failure -> error (show failure)
  Right result -> result

accepted :: (Show error) => Either error value -> IO value
accepted = pure . must
