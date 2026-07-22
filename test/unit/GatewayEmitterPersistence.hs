{-# LANGUAGE OverloadedStrings #-}

module GatewayEmitterPersistence
  ( gatewayEmitterPersistenceSuite
  )
where

import Data.Aeson (encode)
import Data.ByteString.Lazy.Char8 qualified as BL8
import Prodbox.Gateway.Emitter.Lease (leaseNameText)
import Prodbox.Gateway.Emitter.Persistence
import Prodbox.Substrate (Substrate (..))
import TestSupport

gatewayEmitterPersistenceSuite :: SuiteBuilder ()
gatewayEmitterPersistenceSuite =
  describe "Sprint 2.32 emitter persistence render contract" $ do
    it "binds home emitters to stable StatefulSets and node-local retained paths" $ do
      binding <- expectRight (mkEmitterPersistenceBinding SubstrateHomeLocal "node-a")
      persistenceController binding `shouldBe` EmitterStatefulSet
      persistenceJournalMountPath binding `shouldBe` "/var/lib/prodbox/gateway-emitter"
      persistenceJournalAccess binding
        `shouldBe` HomeNodePinnedHostPath "/var/lib/prodbox/gateway-emitter-journals/node-a"
      leaseNameText (persistenceLeaseName binding) `shouldBe` "prodbox-emitter-node-a"

    it "binds AWS emitters to retained manual EBS claims with ReadWriteOncePod" $ do
      binding <- expectRight (mkEmitterPersistenceBinding SubstrateAws "node-b")
      persistenceJournalAccess binding
        `shouldBe` AwsRetainedEbsClaim
          { journalClaimName = "gateway-node-b-emitter-journal"
          , journalStorageClassName = "manual"
          , journalAccessMode = "ReadWriteOncePod"
          , journalRequestedStorage = "1Gi"
          }

    it "rejects unsafe node identities before any path or resource is rendered" $ do
      mkEmitterPersistenceBinding SubstrateHomeLocal "../node-a"
        `shouldSatisfy` isLeft
      mkEmitterPersistenceBinding SubstrateAws "NODE WITH SPACES"
        `shouldSatisfy` isLeft

    it "rejects duplicate node identities after canonical normalization" $ do
      emitterPersistenceValues SubstrateHomeLocal ["node-a", " NODE-A "]
        `shouldSatisfy` isLeft
      emitterPersistenceValues SubstrateAws ["node-b", "node-b"]
        `shouldSatisfy` isLeft

    it "renders the native Lease RBAC and substrate-exact storage kind" $ do
      home <- expectRight (emitterPersistenceValues SubstrateHomeLocal ["node-a"])
      aws <- expectRight (emitterPersistenceValues SubstrateAws ["node-a"])
      let homeJson = BL8.unpack (encode home)
          awsJson = BL8.unpack (encode aws)
      homeJson `shouldContain` "\"controllerKind\":\"StatefulSet\""
      homeJson `shouldContain` "\"kind\":\"nodePinnedHostPath\""
      homeJson `shouldContain` "\"resource\":\"leases\""
      awsJson `shouldContain` "\"kind\":\"retainedEbsClaim\""
      awsJson `shouldContain` "\"accessMode\":\"ReadWriteOncePod\""
      -- Sprint 2.32 supplies only claim-side coordinates. Physical PV/EBS
      -- identity and Retain policy are deliberately owned by Sprint 3.26.
      awsJson `shouldNotContain` "persistentVolume"
      awsJson `shouldNotContain` "reclaimPolicy"
      awsJson `shouldNotContain` "volumeHandle"

expectRight :: (Show err) => Either err value -> IO value
expectRight result = case result of
  Left err -> expectationFailure (show err) >> fail "unreachable"
  Right value -> pure value

isLeft :: Either left right -> Bool
isLeft result = case result of
  Left _ -> True
  Right _ -> False
