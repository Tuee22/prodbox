{-# LANGUAGE OverloadedStrings #-}

module DecommissionAuthorityExport (decommissionAuthorityExportSuite) where

import Data.ByteString qualified as ByteString
import Data.IORef
import Data.List (find)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (..)
  , AuthorityAdmissionSnapshot (..)
  )
import Prodbox.ControlPlane.Codec (encodeControlPlaneRequest)
import Prodbox.ControlPlane.DecommissionProduction
  ( freezeAuthorityAdmissionWithReadBack
  , readCommittedPlanOrDiscover
  )
import Prodbox.Lifecycle.Authority.Admission
  ( freezeAuthorityForDecommission
  , initialCleanInstallAuthority
  )
import Prodbox.Lifecycle.Decommission.AuthorityExport
import Prodbox.Lifecycle.Decommission.Commit
  ( DecommissionCommitRepository (..)
  )
import Prodbox.Lifecycle.Decommission.Frame (contentDigest)
import Prodbox.Lifecycle.Decommission.Manifest
import Prodbox.Lifecycle.Decommission.Verifier
import Prodbox.Vault.Reconcile
  ( VaultPolicySpec (..)
  , VaultReconcilePlan (vaultReconcilePolicies, vaultReconcileTransitKeys)
  , VaultTransitKeySpec (..)
  , defaultVaultReconcilePlan
  )
import TestSupport

decommissionAuthorityExportSuite :: SuiteBuilder ()
decommissionAuthorityExportSuite =
  describe "Sprint 4.50 Authority decommission export" $ do
    it "freezes admission, signs the Authority-owned plan, and commits only the verified manifest" $ do
      events <- newIORef []
      committed <- newIORef Nothing
      result <-
        runAuthorityDecommissionExport
          (repository events committed (Right ()))
          (signer events 7 7 signatureBytes)
          request
      result `shouldBe` AuthorityDecommissionExported verifiedManifest
      readIORef events
        `shouldReturn` ["freeze", "plan:delete", "public-key", "sign", "commit"]
      readIORef committed `shouldReturn` Just verifiedManifest

    it "refuses a Transit key rotation between public-key read and signing" $ do
      events <- newIORef []
      committed <- newIORef Nothing
      result <-
        runAuthorityDecommissionExport
          (repository events committed (Right ()))
          (signer events 7 8 signatureBytes)
          request
      result
        `shouldBe` AuthorityDecommissionExportRefused
          (AuthorityExportSignerGenerationChanged 7 8)
      readIORef committed `shouldReturn` Nothing

    it "cryptographically refuses a malformed externally-produced signature" $ do
      events <- newIORef []
      committed <- newIORef Nothing
      result <-
        runAuthorityDecommissionExport
          (repository events committed (Right ()))
          (signer events 7 7 (ByteString.replicate 64 0))
          request
      case result of
        AuthorityDecommissionExportRefused (AuthorityExportSignatureInvalid _) -> pure ()
        other -> expectationFailure ("expected invalid-signature refusal, got " <> show other)
      readIORef committed `shouldReturn` Nothing

    it "stops at a failed admission freeze and never reads or signs a plan" $ do
      events <- newIORef []
      committed <- newIORef Nothing
      result <-
        runAuthorityDecommissionExport
          (repository events committed (Left "freeze unavailable"))
          (signer events 7 7 signatureBytes)
          request
      result
        `shouldBe` AuthorityDecommissionExportRefused
          (AuthorityExportFreezeFailed "freeze unavailable")
      readIORef events `shouldReturn` ["freeze"]
      readIORef committed `shouldReturn` Nothing

    it "reuses the committed plan on pinned-runner resume without rediscovering mutated inventory" $ do
      discoveries <- newIORef (0 :: Int)
      let committedRepository =
            DecommissionCommitRepository
              { readCommittedManifest = pure (Right (Just (1 :: Int, verifiedManifest)))
              , initializeCommittedManifest = \_ -> pure (Left "resume must not initialize")
              }
          rediscover _localDataDisposition = do
            modifyIORef' discoveries (+ 1)
            pure (Left "Target generation has already been tombstoned")
      -- Sprint 4.85: the resume supplies the /other/ disposition and still
      -- gets the committed plan back, which is exactly why the runner
      -- separately refuses a signed disposition that is not the requested one:
      -- the operator must learn the decision was already made rather than
      -- believe this run made it.
      readCommittedPlanOrDiscover committedRepository rediscover RetainLocalData
        `shouldReturn` Right plan
      readIORef discoveries `shouldReturn` 0

    it "treats an already-frozen Authority as idempotent preparation without another CAS" $ do
      casCount <- newIORef (0 :: Int)
      let initial = mustRight (initialCleanInstallAuthority 4 8)
          (_, frozen) = freezeAuthorityForDecommission initial
          admission =
            AuthorityAdmissionRepository
              { readAuthorityAdmission =
                  pure (Right (AuthorityAdmissionSnapshot (1 :: Int) frozen))
              , compareAndSwapAuthorityAdmission = \_ _ -> do
                  modifyIORef' casCount (+ 1)
                  pure (Right ())
              }
      freezeAuthorityAdmissionWithReadBack 3 admission `shouldReturn` Right ()
      readIORef casCount `shouldReturn` 0

    it "rejects an oversized endpoint body before acquiring Authority effects" $ do
      events <- newIORef []
      committed <- newIORef Nothing
      result <-
        serveAuthorityDecommissionExportRequest
          1
          (repository events committed (Right ()))
          (signer events 7 7 signatureBytes)
          (encodeControlPlaneRequest request)
      case result of
        AuthorityDecommissionExportRefused (AuthorityExportBadRequest _) -> pure ()
        other -> expectationFailure ("expected bounded-codec refusal, got " <> show other)
      readIORef events `shouldReturn` []

    it "reconciles one Ed25519 signer and grants only Authority read/sign access" $ do
      find
        ((== authorityDecommissionSigningKeyName) . vaultTransitKeySpecName)
        (vaultReconcileTransitKeys defaultVaultReconcilePlan)
        `shouldBe` Just
          (VaultTransitKeySpec authorityDecommissionSigningKeyName "ed25519")
      case policyNamed "prodbox-lifecycle-authority" of
        Nothing -> expectationFailure "missing Lifecycle Authority Vault policy"
        Just policy -> do
          let document = Text.unpack (vaultPolicySpecDocument policy)
          document
            `shouldContain` "path \"transit/keys/prodbox-authority-genesis-signing\""
          document
            `shouldContain` "path \"transit/sign/prodbox-authority-genesis-signing\""
          document
            `shouldContain` "path \"transit/encrypt/prodbox-active-config\""
          document
            `shouldContain` "path \"transit/decrypt/prodbox-active-config\""
          document `shouldNotContain` "exportable"
 where
  policyNamed name =
    find
      ((== name) . vaultPolicySpecName)
      (vaultReconcilePolicies defaultVaultReconcilePlan)

repository
  :: IORef [Text.Text]
  -> IORef (Maybe VerifiedDecommissionManifest)
  -> Either Text.Text ()
  -> AuthorityDecommissionExportRepository IO
repository events committed freezeResult =
  AuthorityDecommissionExportRepository
    { freezeAuthorityAdmission = record "freeze" >> pure freezeResult
    , readAuthorityDecommissionPlan = \localDataDisposition -> do
        record ("plan:" <> decommissionLocalDataDispositionText localDataDisposition)
        pure (Right plan)
    , commitAuthorityDecommissionManifest = \verified -> do
        record "commit"
        writeIORef committed (Just verified)
        pure (Right ())
    }
 where
  record event = modifyIORef' events (<> [event])

signer
  :: IORef [Text.Text]
  -> Natural
  -> Natural
  -> ByteString.ByteString
  -> AuthorityManifestSigner IO
signer events publicGeneration signatureGeneration signature =
  AuthorityManifestSigner
    { readAuthorityManifestPublicKey = do
        record "public-key"
        pure (Right (publicGeneration, publicKey))
    , signAuthorityManifestPayload = \payload -> do
        record "sign"
        if payload == manifestSigningPayload plan verifier publicKey
          then pure (Right (signatureGeneration, signature))
          else pure (Left "Authority signed bytes other than the canonical manifest payload")
    }
 where
  record event = modifyIORef' events (<> [event])

-- Sprint 4.85: the request carries the operator's closed retain-or-delete
-- decision, and the repository records which one it was asked to plan for.
request :: AuthorityDecommissionExportRequest
request = AuthorityDecommissionExportRequest verifier DeleteLocalData

plan :: DecommissionManifest
plan = mustRight (mkDecommissionManifest "home" [SesConsumerQuiescence, SesProviderStack])

signingKey :: ManifestSigningKey
signingKey = mustRight (mkManifestSigningKey (ByteString.pack [0 .. 31]))

publicKey :: ManifestPublicKey
publicKey = manifestSigningPublicKey signingKey

signedManifest :: SignedDecommissionManifest
signedManifest = signDecommissionManifest signingKey plan verifier

signatureBytes :: ByteString.ByteString
signatureBytes = manifestSignatureBytes (signedManifestSignature signedManifest)

verifiedManifest :: VerifiedDecommissionManifest
verifiedManifest =
  mustRight
    (verifySignedDecommissionManifest (manifestPublicKeyDigest publicKey) signedManifest)

verifier :: VerifierBinding
verifier = verifierBindingOf artifactPath artifact

artifactPath :: ExternalArtifactPath
artifactPath = mustRight (mkExternalArtifactPath "/tmp/prodbox-export/decommission-runner")

artifact :: VerifierArtifact
artifact = mustRight (mkVerifierArtifact "runner-build-v1" "dependency-v1" metadata)

metadata :: VerifierMetadata
metadata =
  mustRight
    ( mkVerifierMetadata
        (contentDigest "dependency-v1")
        1
        (contentDigest "manifest-schema-v1")
        1
        (contentDigest "interpreter-registry-v1")
    )

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error ("invalid decommission Authority export fixture: " <> show err)
