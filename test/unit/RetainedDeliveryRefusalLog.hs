{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 2.139: a retained-material delivery that is refused says which stage
-- refused it.
--
-- The 2026-10-12 @keycloak-invite@ run reached the retained delivery of the SMTP
-- source and ended @execution-failed/target-observation-unobservable/retained/
-- delivery-failed@. That class is closed on purpose: the Provisioner worker's
-- terminal line may carry no Authority text. But the Authority built the text, the
-- Target Agent built the one under it, and both were dropped, so no log anywhere
-- named the stage. These cases pin the closed token that now stands for a refusal
-- text and the two recorders that write it.
module RetainedDeliveryRefusalLog (retainedDeliveryRefusalLogSuite) where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.ClosedRefusalToken (closedRefusalToken)
import Prodbox.ControlPlane.RetainedMaterialDeliveryCoordinator
  ( RetainedMaterialDeliveryRequest (..)
  )
import Prodbox.ControlPlane.RetainedMaterialDeliveryEndpoint
  ( RetainedMaterialDeliveryBoundary (..)
  , withRetainedDeliveryRefusalLog
  )
import Prodbox.ControlPlane.TargetMaterialRegistry (TargetSecretId (TargetSesSmtp))
import Prodbox.ControlPlane.TargetRetainedMaterialRewrapEndpoint
  ( TargetRetainedMaterialRewrapBoundary (..)
  , TargetRetainedMaterialRewrapRequest (..)
  , TargetRetainedMaterialRewrapResponse (..)
  , withTargetRetainedRewrapRefusalLog
  )
import Prodbox.Lifecycle.Authority.RetainedMaterial
  ( SRetainedMaterialSchema (SRetainedSesSmtpMaterial)
  , mkRetainedMaterialRef
  , mkRetainedMaterialSource
  , mkRetainedMaterialTarget
  )
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros)
import Prodbox.Lifecycle.TargetCommitIntent
  ( mkCredentialGeneration
  , mkTargetValueDigest
  )
import TestSupport

retainedDeliveryRefusalLogSuite :: SuiteBuilder ()
retainedDeliveryRefusalLogSuite =
  describe "Sprint 2.139 a refused retained delivery names its stage in the Authority's log" $ do
    it "gives a fixed sentence its own token and nothing else" $ do
      closedRefusalToken "retained source is absent" `shouldBe` "retained-source-is-absent"
      closedRefusalToken "retained delivery target is not the registered Target Agent"
        `shouldBe` "retained-delivery-target-is-not-the-registered-target-agent"
      -- The sentence's own first word is not mistaken for a constructor.
      closedRefusalToken "Target worker controller auditor login unavailable"
        `shouldBe` "target-worker-controller-auditor-login-unavailable"
      closedRefusalToken "request-codec-rejected" `shouldBe` "request-codec-rejected"

    it "names the constructors of a shown error, and the fixed sentence it wraps" $ do
      closedRefusalToken "TargetRetainedMaterialRewrapUnavailable \"retained source is corrupt\""
        `shouldBe` "TargetRetainedMaterialRewrapUnavailable/retained-source-is-corrupt"
      closedRefusalToken
        "TargetMaterializationWorkflowKubernetesFailed (TargetWorkerCoordinatorAttachFailed \"Target worker attach completion frame read failed\")"
        `shouldBe` "TargetMaterializationWorkflowKubernetesFailed/TargetWorkerCoordinatorAttachFailed"

    it "keeps plain prose and the constructor after a fixed prefix, segment by segment" $ do
      closedRefusalToken "retained delivery remains pending until its absolute deadline"
        `shouldBe` "retained-delivery-remains-pending-until-its-absolute-deadline"
      closedRefusalToken "retained delivery refused: RetainedDeliveryAttestationMismatch"
        `shouldBe` "retained-delivery-refused/RetainedDeliveryAttestationMismatch"
      closedRefusalToken
        "retained source correction refused: RetainedLegacySourceReceiptCorrectionMismatch (Foo 12)"
        `shouldBe` "retained-source-correction-refused/RetainedLegacySourceReceiptCorrectionMismatch/Foo"

    it "lets no value through: an argument that is not a constructor ends the chain" $ do
      let hostile =
            "SomeFailure \"hunter2-secret-value\" (Other 42 \"sha256:0123456789abcdef\")"
          token = closedRefusalToken hostile
      token `shouldBe` "SomeFailure"
      Text.unpack token `shouldNotContain` "hunter2"
      Text.unpack token `shouldNotContain` "sha256"
      closedRefusalToken "something went wrong near 10.0.0.7 with /secret/data/x" `shouldBe` "other"
      -- A digit, a dot, a slash, a quote or an underscore keeps a segment out of the prose rule.
      closedRefusalToken "token hvs.CAESIabc123 was refused" `shouldBe` "other"
      closedRefusalToken "path secret/data/keycloak/smtp is missing" `shouldBe` "other"
      closedRefusalToken "operation \"delivery-op-7\" conflicts" `shouldBe` "other"
      closedRefusalToken "" `shouldBe` "other"

    it "bounds the token whatever the text" $ do
      let chain = Text.unwords (replicate 40 (Text.replicate 60 "A" <> "a"))
      (Text.length (closedRefusalToken chain) <= 240) `shouldBe` True

    it "records the schema and token of a refused delivery, and leaves its answer as it was" $ do
      recorded <- newIORef ([] :: [Text])
      let refusing =
            RetainedMaterialDeliveryBoundary
              { deliverRetainedSesSmtp = \_ _ _ -> pure (Left "retained source is absent")
              , deliverRetainedAcmeEab = \_ _ _ -> pure (Left "request-codec-rejected")
              }
          logged =
            withRetainedDeliveryRefusalLog
              (\line -> modifyIORef' recorded (<> [line]))
              refusing
          source =
            mustRight
              ( mkRetainedMaterialSource
                  (mustRight (mkCredentialGeneration 1))
                  (mustRight (mkRetainedMaterialRef "operation"))
                  (mustRight (mkRetainedMaterialRef "receipt"))
                  (mustRight (mkTargetValueDigest (Text.replicate 64 "a")))
                  (mustRight (mkRetainedMaterialRef "commitment"))
                  3
                  (authorityTimeFromMicros 1000)
              )
          request =
            RetainedMaterialDeliveryRequest
              { retainedDeliveryRequestOperationId = mustRight (mkRetainedMaterialRef "delivery-operation")
              , retainedDeliveryRequestTarget =
                  mustRight (mkRetainedMaterialTarget SRetainedSesSmtpMaterial "home")
              , retainedDeliveryRequestGeneration = mustRight (mkCredentialGeneration 1)
              , retainedDeliveryRequestAttestationRef = mustRight (mkRetainedMaterialRef "attestation")
              , retainedDeliveryRequestDeadline = authorityTimeFromMicros 2000
              }
      answer <- deliverRetainedSesSmtp logged (authorityTimeFromMicros 1500) source request
      -- The wire answer is the boundary's own, unchanged.
      answer `shouldSatisfy` isRefusal "retained source is absent"
      readIORef recorded `shouldReturn` ["ses-smtp retained-source-is-absent"]

    it "records the request kind, the answer kind and the token of a Target Agent refusal" $ do
      recorded <- newIORef ([] :: [Text])
      let rewrap =
            TargetRetainedMaterialRewrapRequest
              { targetRetainedRewrapTarget = TargetSesSmtp
              , targetRetainedRewrapOperationId = "operation"
              , targetRetainedRewrapExpectedSourceReceipt = "receipt"
              , targetRetainedRewrapExpectedSourceGeneration = 1
              , targetRetainedRewrapExpectedSourceVaultVersion = 1
              , targetRetainedRewrapExpectedSourceDigest = Text.replicate 64 "a"
              , targetRetainedRewrapTargetGeneration = 1
              , targetRetainedRewrapAttestationRef = "attestation"
              , targetRetainedRewrapDestinationPublicKey = mempty
              , targetRetainedRewrapDeadlineMicros = 2000
              }
          observe =
            ObserveTargetRetainedMaterialSource
              { targetRetainedRewrapTarget = TargetSesSmtp
              , targetRetainedSourceExpectedOperationId = "operation"
              , targetRetainedSourceExpectedGeneration = 1
              , targetRetainedSourceObservationDeadlineMicros = 2000
              }
          boundary =
            TargetRetainedMaterialRewrapBoundary $ \_ request -> pure $ case request of
              TargetRetainedMaterialRewrapRequest {} ->
                TargetRetainedMaterialRewrapUnavailable "retained source is unobservable"
              ObserveTargetRetainedMaterialSource {} ->
                TargetRetainedMaterialRewrapRefused "retained source generation mismatch"
          logged =
            withTargetRetainedRewrapRefusalLog
              (\line -> modifyIORef' recorded (<> [line]))
              boundary
      _ <- runTargetRetainedMaterialRewrap logged (authorityTimeFromMicros 1500) rewrap
      _ <- runTargetRetainedMaterialRewrap logged (authorityTimeFromMicros 1500) observe
      -- An absent source is an answer, not a refusal, and is not recorded.
      silent <- newIORef ([] :: [Text])
      let absent =
            withTargetRetainedRewrapRefusalLog
              (\line -> modifyIORef' silent (<> [line]))
              ( TargetRetainedMaterialRewrapBoundary $ \_ _ -> pure (TargetRetainedMaterialSourceAbsent TargetSesSmtp)
              )
      _ <- runTargetRetainedMaterialRewrap absent (authorityTimeFromMicros 1500) observe
      readIORef recorded
        `shouldReturn` [ "rewrap unavailable retained-source-is-unobservable"
                       , "observe-source refused retained-source-generation-mismatch"
                       ]
      readIORef silent `shouldReturn` []
 where
  mustRight :: (Show err) => Either err value -> value
  mustRight = either (error . show) id
  isRefusal detail answer = case answer of
    Left observed -> observed == detail
    Right _ -> False
