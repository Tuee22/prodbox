{-# LANGUAGE OverloadedStrings #-}

module DecommissionProductionBoundaries
  ( decommissionProductionBoundariesSuite
  )
where

import Data.ByteString qualified as ByteString
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.TrustedTargetSink (mkTrustedTargetSink)
import Prodbox.Infra.SesConsumerQuiescence
import Prodbox.Lifecycle.CheckpointAuthority
  ( TargetClusterSecretSink
  , mkTargetClusterSecretSink
  )
import Prodbox.Lifecycle.Decommission.Frame
  ( FrameAttemptId
  , FrameDigest
  , FrameNodeId
  , contentDigest
  , mkFrameAttemptId
  )
import Prodbox.Lifecycle.Decommission.Manifest
import Prodbox.Lifecycle.Decommission.NodeEffect
  ( NodeOperation (..)
  , runSesConsumerQuiescenceCapability
  )
import Prodbox.Lifecycle.Decommission.RetainedCustodyTombstone
import Prodbox.Lifecycle.Decommission.TargetInventory
import Prodbox.Lifecycle.Decommission.Verifier
import Prodbox.Lifecycle.Lease (mkFencingToken, mkOwnerNonce)
import Prodbox.Lifecycle.ResidueStatus (ResidueStatus (ResidueAbsent))
import Prodbox.Lifecycle.TargetCommitIntent
  ( TargetSinkObservation (..)
  , TargetSinkRecord
  , mkCredentialGeneration
  , mkTargetValueDigest
  , targetSinkRecordFromStore
  )
import Prodbox.Lifecycle.TargetSinkVersion.Internal
  ( targetSinkVersionFromStoreVersion
  )
import TestSupport

decommissionProductionBoundariesSuite :: SuiteBuilder ()
decommissionProductionBoundariesSuite =
  describe "Sprint 4.50 production decommission boundaries" $ do
    it "projects only the registered Target identity and current generation" $ do
      let trusted =
            mkTrustedTargetSink
              targetSink
              ( pure
                  ( TargetSinkObserved
                      (mustJust (targetSinkVersionFromStoreVersion 17))
                      targetRecord
                  )
              )
      observed <-
        observeTargetDecommissionInventory
          (targetDecommissionInventoryBoundary trusted)
      observed
        `shouldBe` TargetDecommissionInventoryObserved
          TargetDecommissionInventory
            { targetDecommissionInventoryReference = "home"
            , targetDecommissionInventoryGeneration =
                Just (mustRight (mkDecommissionTargetGeneration 17))
            }

    it "keeps retained-home custody to the exact SMTP and EAB source schemas" $ do
      map retainedCustodyCoordinateKind retainedHomeCustodyCoordinates
        `shouldBe` [RetainedHomeSesSmtpSource, RetainedHomeAcmeEabSource]
      map retainedCustodyCoordinateMount retainedHomeCustodyCoordinates
        `shouldBe` ["secret", "secret"]
      map retainedCustodyCoordinatePath retainedHomeCustodyCoordinates
        `shouldBe` [ "target-agent/retained-home/ses-smtp-source"
                   , "target-agent/retained-home/acme-eab-source"
                   ]

    it "accepts lost custody-delete responses only after every metadata read-back is absent" $ do
      smtpPresent <- newIORef True
      eabPresent <- newIORef True
      deletes <- newIORef ([] :: [RetainedCustodyKind])
      let boundary =
            mustRight
              ( mkRetainedCustodyBoundary
                  [ responseLostEntry RetainedHomeSesSmtpSource smtpPresent deletes
                  , responseLostEntry RetainedHomeAcmeEabSource eabPresent deletes
                  ]
              )
      result <-
        runRetainedCustodyTombstone
          retainedCustodyManifest
          boundary
          DestroyRetainedCustody
      result `shouldBe` RetainedCustodyDestroyedAndReadBack
      readIORef deletes
        `shouldReturn` [RetainedHomeSesSmtpSource, RetainedHomeAcmeEabSource]

    it "checks retained-custody manifest authorization before observing metadata" $ do
      observations <- newIORef (0 :: Int)
      let entry kind =
            retainedCustodyEntryBoundary
              kind
              (modifyIORef' observations (+ 1) >> pure RetainedCustodyAbsent)
              (pure (Right ()))
          boundary =
            mustRight
              ( mkRetainedCustodyBoundary
                  [ entry RetainedHomeSesSmtpSource
                  , entry RetainedHomeAcmeEabSource
                  ]
              )
      result <-
        runRetainedCustodyTombstone
          manifestWithoutCustody
          boundary
          DestroyRetainedCustody
      result
        `shouldBe` RetainedCustodyTombstoneRefused
          RetainedCustodyTombstoneNodeNotAuthorized
      readIORef observations `shouldReturn` 0

    it "converges SES consumer quiescence after an applied-but-lost scale response" $ do
      running <- newIORef True
      stopCount <- newIORef (0 :: Int)
      let boundary =
            mkSesConsumerQuiescenceBoundary
              ( do
                  modifyIORef' stopCount (+ 1)
                  writeIORef running False
                  pure (Left "scale response lost")
              )
              ( do
                  stillRunning <- readIORef running
                  pure
                    ( if stillRunning
                        then SesConsumersRunning 1 1 1
                        else SesConsumersQuiescent
                    )
              )
          operation =
            runSesConsumerQuiescenceCapability
              (sesConsumerQuiescenceCapability boundary)
      nodeDestroy operation nodeId attemptId `shouldReturn` Right ()
      nodeReadBack operation nodeId attemptId `shouldReturn` ResidueAbsent
      readIORef stopCount `shouldReturn` 1

responseLostEntry
  :: RetainedCustodyKind
  -> IORef Bool
  -> IORef [RetainedCustodyKind]
  -> RetainedCustodyEntryBoundary IO
responseLostEntry kind present deletes =
  retainedCustodyEntryBoundary
    kind
    ( do
        observed <- readIORef present
        pure (if observed then RetainedCustodyPresent else RetainedCustodyAbsent)
    )
    ( do
        modifyIORef' deletes (<> [kind])
        writeIORef present False
        pure (Left "delete response lost")
    )

targetSink :: TargetClusterSecretSink
targetSink =
  mustRight
    ( mkTargetClusterSecretSink
        "home"
        "secret"
        "keycloak/smtp"
    )

targetRecord :: TargetSinkRecord Text
targetRecord =
  targetSinkRecordFromStore
    (mustRight (mkOwnerNonce "owner-17"))
    (mustRight (mkFencingToken 17))
    (mustRight (mkCredentialGeneration 17))
    (mustRight (mkTargetValueDigest (Text.replicate 64 "a")))
    "opaque-fixture"

retainedCustodyManifest :: VerifiedDecommissionManifest
retainedCustodyManifest = verifiedFor [RetainedCustody]

manifestWithoutCustody :: VerifiedDecommissionManifest
manifestWithoutCustody = verifiedFor [SesProviderStack]

verifiedFor :: [DecommissionNode] -> VerifiedDecommissionManifest
verifiedFor nodes =
  mustRight
    ( verifySignedDecommissionManifest
        signerDigest
        (signDecommissionManifest signingKey plan verifier)
    )
 where
  plan = mustRight (mkDecommissionManifest "home" nodes)

signingKey :: ManifestSigningKey
signingKey = mustRight (mkManifestSigningKey (ByteString.pack [0 .. 31]))

signerDigest :: FrameDigest
signerDigest = manifestPublicKeyDigest (manifestSigningPublicKey signingKey)

verifier :: VerifierBinding
verifier = verifierBindingOf artifactPath artifact

artifactPath :: ExternalArtifactPath
artifactPath =
  mustRight (mkExternalArtifactPath "/tmp/prodbox-export/decommission-runner")

artifact :: VerifierArtifact
artifact = mustRight (mkVerifierArtifact "runner-v1" "deps-v1" metadata)

metadata :: VerifierMetadata
metadata =
  mustRight
    ( mkVerifierMetadata
        (contentDigest "deps-v1")
        1
        (contentDigest "manifest-v1")
        1
        (contentDigest "registry-v1")
    )

nodeId :: FrameNodeId
nodeId = decommissionNodeFrameId SesConsumerQuiescence

attemptId :: FrameAttemptId
attemptId = mustJust (mkFrameAttemptId "attempt-1")

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value

mustJust :: Maybe value -> value
mustJust result = case result of
  Nothing -> error "invalid production-boundary fixture"
  Just value -> value
