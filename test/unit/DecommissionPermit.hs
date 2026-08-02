{-# LANGUAGE OverloadedStrings #-}

module DecommissionPermit (decommissionPermitSuite) where

import Data.ByteString qualified as ByteString
import Prodbox.Lifecycle.Authority.AdminAction
  ( PermitFreshness (PermitExpired, PermitFresh)
  , RunnerRole (AdminActionRunner, DecommissionRunner)
  )
import Prodbox.Lifecycle.Decommission.Frame (FrameDigest, contentDigest)
import Prodbox.Lifecycle.Decommission.Manifest
import Prodbox.Lifecycle.Decommission.Permit
import Prodbox.Lifecycle.Decommission.Verifier
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import TestSupport

decommissionPermitSuite :: SuiteBuilder ()
decommissionPermitSuite =
  describe "Sprint 4.50 decommission runner permit" $ do
    it "accepts only opaque preflight evidence bound to the authenticated complete manifest" $
      withPermitFixture $ \fixture -> do
        decide
          fixture
          AdmissionFrozen
          (Just (fixtureReady fixture))
          PermitFresh
          DecommissionAwaitingPermit
          (permit fixture)
          `shouldBe` DecommissionPermitAccepted "nonce-1"
        stepDecommissionPermit
          (fixtureVerified fixture)
          AdmissionFrozen
          (Just (fixtureReady fixture))
          PermitFresh
          DecommissionAwaitingPermit
          (permit fixture)
          `shouldBe` (DecommissionPermitAccepted "nonce-1", DecommissionPermitConsumed "nonce-1")

    it "refuses a cross-role or cross-manifest permit regardless of readiness" $
      withPermitFixture $ \fixture -> do
        let crossRole = (permit fixture) {decommissionPermitAudience = AdminActionRunner}
            crossManifest =
              (permit fixture)
                { decommissionPermitManifestDigest = contentDigest "other-complete-manifest"
                }
        decide
          fixture
          AdmissionFrozen
          (Just (fixtureReady fixture))
          PermitFresh
          DecommissionAwaitingPermit
          crossRole
          `shouldBe` DecommissionPermitRefused DecommissionWrongAudience
        decide
          fixture
          AdmissionFrozen
          (Just (fixtureReady fixture))
          PermitFresh
          DecommissionAwaitingPermit
          crossManifest
          `shouldBe` DecommissionPermitRefused DecommissionWrongManifest

    it "refuses open admission, missing preflight, and permit expiry" $
      withPermitFixture $ \fixture -> do
        decide
          fixture
          AdmissionOpen
          (Just (fixtureReady fixture))
          PermitFresh
          DecommissionAwaitingPermit
          (permit fixture)
          `shouldBe` DecommissionPermitRefused DecommissionAdmissionNotFrozen
        decide fixture AdmissionFrozen Nothing PermitFresh DecommissionAwaitingPermit (permit fixture)
          `shouldBe` DecommissionPermitRefused DecommissionVerifierNotReady
        decide
          fixture
          AdmissionFrozen
          (Just (fixtureReady fixture))
          PermitExpired
          DecommissionAwaitingPermit
          (permit fixture)
          `shouldBe` DecommissionPermitRefused DecommissionPermitExpired

    it "requires current preflight evidence even for idempotent replay" $
      withPermitFixture $ \fixture -> do
        decide
          fixture
          AdmissionFrozen
          Nothing
          PermitExpired
          (DecommissionPermitConsumed "nonce-1")
          (permit fixture)
          `shouldBe` DecommissionPermitRefused DecommissionVerifierNotReady
        decide
          fixture
          AdmissionFrozen
          (Just (fixtureReady fixture))
          PermitExpired
          (DecommissionPermitConsumed "nonce-1")
          (permit fixture)
          `shouldBe` DecommissionPermitAlreadyConsumed "nonce-1"
        decide
          fixture
          AdmissionFrozen
          (Just (fixtureReady fixture))
          PermitFresh
          (DecommissionPermitConsumed "nonce-1")
          ((permit fixture) {decommissionPermitNonce = "nonce-2"})
          `shouldBe` DecommissionPermitRefused DecommissionNonceConflict

    it "rejects otherwise-valid readiness evidence from another signed manifest" $
      withPermitFixture $ \fixture -> do
        otherPlan <- pure (mustRight (mkDecommissionManifest "cluster-b" [SesConsumerQuiescence]))
        let otherSigned =
              signDecommissionManifest
                (fixtureSigningKey fixture)
                otherPlan
                (fixtureBinding fixture)
            otherVerified =
              mustRight
                ( verifySignedDecommissionManifest
                    (fixtureSignerDigest fixture)
                    otherSigned
                )
            otherReady =
              mustRight
                ( bindDecommissionPreflight
                    otherVerified
                    (fixturePreflighted fixture)
                    (fixtureExecution fixture)
                )
        decide
          fixture
          AdmissionFrozen
          (Just otherReady)
          PermitFresh
          DecommissionAwaitingPermit
          (permit fixture)
          `shouldBe` DecommissionPermitRefused DecommissionVerifierBoundToDifferentManifest

    it "will not join a signed manifest to preflight evidence for another artifact" $
      withPermitFixture $ \fixture -> do
        let otherPath = mustRight (mkExternalArtifactPath (fixtureDirectory fixture </> "other-runner"))
        otherBinding <- mustRight <$> exportVerifierArtifact otherPath fixtureArtifact
        otherPreflighted <- runVerifierPreflight otherBinding >>= expectReady
        let otherExecution = decidePinnedArtifactExecution otherPreflighted otherBinding
        bindDecommissionPreflight
          (fixtureVerified fixture)
          otherPreflighted
          otherExecution
          `shouldBe` Left DecommissionPreflightVerifierBindingMismatch
        bindDecommissionPreflight
          (fixtureVerified fixture)
          (fixturePreflighted fixture)
          otherExecution
          `shouldBe` Left DecommissionPreflightExecutionBindingMismatch

    it "refuses the current new build and requires self-execution of the exact pinned path" $
      withPermitFixture $ \fixture -> do
        let newBuild =
              mustRight
                ( mkVerifierArtifact
                    "different-current-runner-build"
                    dependencyBytes
                    (fixtureMetadata fixture)
                )
            newBuildIdentity = verifierBindingOf (fixturePath fixture) newBuild
            execution =
              decidePinnedArtifactExecution
                (fixturePreflighted fixture)
                newBuildIdentity
        bindDecommissionPreflight
          (fixtureVerified fixture)
          (fixturePreflighted fixture)
          execution
          `shouldBe` Left (DecommissionPreflightPinnedSelfExecutionRequired (fixturePath fixture))
 where
  decide fixture = decideDecommissionPermit (fixtureVerified fixture)
  permit fixture =
    DecommissionPermit
      { decommissionPermitAudience = DecommissionRunner
      , decommissionPermitManifestDigest = verifiedManifestDigest (fixtureVerified fixture)
      , decommissionPermitNonce = "nonce-1"
      }

data PermitFixture = PermitFixture
  { fixtureDirectory :: !FilePath
  , fixturePath :: !ExternalArtifactPath
  , fixtureBinding :: !VerifierBinding
  , fixtureMetadata :: !VerifierMetadata
  , fixtureSigningKey :: !ManifestSigningKey
  , fixtureSignerDigest :: !FrameDigest
  , fixtureVerified :: !VerifiedDecommissionManifest
  , fixturePreflighted :: !PreflightedVerifierArtifact
  , fixtureExecution :: !PinnedExecutionDecision
  , fixtureReady :: !DecommissionPreflight
  }

withPermitFixture :: (PermitFixture -> IO value) -> IO value
withPermitFixture action =
  withSystemTempDirectory "prodbox-decommission-permit" $ \directory -> do
    let path = mustRight (mkExternalArtifactPath (directory </> "pinned-runner"))
        bindingExpected = verifierBindingOf path fixtureArtifact
    binding <- mustRight <$> exportVerifierArtifact path fixtureArtifact
    binding `shouldBe` bindingExpected
    preflighted <- runVerifierPreflight binding >>= expectReady
    let plan = mustRight (mkDecommissionManifest "cluster-a" [SesConsumerQuiescence])
        signed = signDecommissionManifest signingKeyFixture plan binding
        verified = mustRight (verifySignedDecommissionManifest signerDigestFixture signed)
        execution = decidePinnedArtifactExecution preflighted binding
        ready = mustRight (bindDecommissionPreflight verified preflighted execution)
    action
      PermitFixture
        { fixtureDirectory = directory
        , fixturePath = path
        , fixtureBinding = binding
        , fixtureMetadata = metadata
        , fixtureSigningKey = signingKeyFixture
        , fixtureSignerDigest = signerDigestFixture
        , fixtureVerified = verified
        , fixturePreflighted = preflighted
        , fixtureExecution = execution
        , fixtureReady = ready
        }

dependencyBytes :: ByteString.ByteString
dependencyBytes = "canonical dependency closure: crypton-1.0.6; serialise-0.2.6.1"

metadata :: VerifierMetadata
metadata =
  mustRight
    ( mkVerifierMetadata
        (contentDigest dependencyBytes)
        1
        (contentDigest "decommission-manifest-schema-v1")
        1
        (contentDigest "decommission-interpreter-registry-v1")
    )

fixtureArtifact :: VerifierArtifact
fixtureArtifact =
  mustRight
    (mkVerifierArtifact "pinned-decommission-runner-build-bytes" dependencyBytes metadata)

signingKeyFixture :: ManifestSigningKey
signingKeyFixture =
  mustRight (mkManifestSigningKey (ByteString.replicate 32 0x41))

signerDigestFixture :: FrameDigest
signerDigestFixture = manifestPublicKeyDigest (manifestSigningPublicKey signingKeyFixture)

expectReady :: VerifierPreflightResult -> IO PreflightedVerifierArtifact
expectReady result = case result of
  VerifierReady preflighted -> pure preflighted
  other -> expectationFailure ("expected ready preflight, got " <> show other) >> fail "unreachable"

mustRight :: (Show err) => Either err value -> value
mustRight = either (error . show) id
