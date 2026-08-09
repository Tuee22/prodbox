{-# LANGUAGE OverloadedStrings #-}

module DecommissionTargetTombstone (decommissionTargetTombstoneSuite) where

import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
import Data.List (find)
import Data.Text qualified as Text
import Prodbox.ControlPlane.Codec
  ( decodeControlPlaneResponse
  , encodeControlPlaneRequest
  )
import Prodbox.ControlPlane.TrustedTargetSink (mkTrustedTargetSink)
import Prodbox.Lifecycle.CheckpointAuthority
  ( TargetClusterSecretSink
  , mkTargetClusterSecretSink
  )
import Prodbox.Lifecycle.Decommission.Frame (FrameDigest, contentDigest)
import Prodbox.Lifecycle.Decommission.Manifest
import Prodbox.Lifecycle.Decommission.TargetTombstone
import Prodbox.Lifecycle.Decommission.Verifier
import Prodbox.Lifecycle.Lease (mkFencingToken, mkOwnerNonce)
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , TargetSinkObservation (..)
  , TargetSinkRecord (..)
  , TargetSinkVersion
  , mkCredentialGeneration
  , mkTargetValueDigest
  )
import Prodbox.Lifecycle.TargetSinkVersion.Internal
  ( targetSinkVersionFromStoreVersion
  )
import Prodbox.Vault.Reconcile
  ( VaultPolicySpec (..)
  , VaultReconcilePlan (vaultReconcilePolicies)
  , defaultVaultReconcilePlan
  )
import TestSupport

decommissionTargetTombstoneSuite :: SuiteBuilder ()
decommissionTargetTombstoneSuite =
  describe "Sprint 4.50 Target Agent generation tombstone" $ do
    it "binds a signed reference to exactly the same target identity" $ do
      case mkTargetGenerationTombstoneBinding "aws" boundaryFixture of
        Left (TargetTombstoneReferenceIdentityMismatch "aws" "home") -> pure ()
        other -> expectationFailure ("expected identity mismatch, got " <> showBindingResult other)

    it "rejects empty and duplicate registries before dispatch" $ do
      mkTargetGenerationTombstoneRegistry ([] :: [TargetGenerationTombstoneBinding IO Text.Text])
        `shouldSatisfy` isRegistryEmpty
      case mkTargetGenerationTombstoneRegistry [bindingFixture, bindingFixture] of
        Left (TargetTombstoneRegistryDuplicateReference "home") -> pure ()
        _ -> expectationFailure "expected duplicate target-reference refusal"

    it "treats an already physically absent generation as idempotent success" $ do
      deletes <- newIORef (0 :: Int)
      result <- runWithObservations deletes [TargetSinkMissing]
      result `shouldBe` TargetGenerationAlreadyAbsent
      readIORef deletes `shouldReturn` 0

    it "observes an authorized present generation without acquiring delete" $ do
      observations <- newIORef (0 :: Int)
      deletes <- newIORef (0 :: Int)
      registry <-
        registryWith
          observations
          deletes
          [TargetSinkObserved targetVersion targetRecord]
          (Right ())
      result <-
        runTargetGenerationTombstone
          verifiedManifest
          registry
          ObserveTargetGenerationAbsence
          (command "home")
      result `shouldBe` TargetGenerationPresent
      readIORef deletes `shouldReturn` 0

    it "accepts a lost delete response only when authoritative read-back is absent" $ do
      deletes <- newIORef (0 :: Int)
      result <-
        runWith
          deletes
          [TargetSinkObserved targetVersion targetRecord, TargetSinkMissing]
          (Left "response lost")
      result `shouldBe` TargetGenerationDestroyedAndReadBack
      readIORef deletes `shouldReturn` 1

    it "refuses a different live generation without invoking delete" $ do
      deletes <- newIORef (0 :: Int)
      result <- runWithObservations deletes [TargetSinkObserved targetVersion otherRecord]
      result
        `shouldBe` TargetGenerationTombstoneRefused
          (TargetTombstoneGenerationMismatch manifestGeneration otherGeneration)
      readIORef deletes `shouldReturn` 0

    it "refuses success when the generation remains after deletion" $ do
      deletes <- newIORef (0 :: Int)
      result <-
        runWithObservations
          deletes
          [TargetSinkObserved targetVersion targetRecord, TargetSinkObserved targetVersion targetRecord]
      case result of
        TargetGenerationTombstoneRefused (TargetTombstoneDeleteNotConfirmed _) -> pure ()
        other -> expectationFailure ("expected read-back refusal, got " <> show other)
      readIORef deletes `shouldReturn` 1

    it "checks signed node authorization before target observation" $ do
      observations <- newIORef (0 :: Int)
      deletes <- newIORef (0 :: Int)
      registry <- registryWith observations deletes [TargetSinkMissing] (Right ())
      result <-
        runTargetGenerationTombstone
          verifiedManifest
          registry
          DestroyTargetGeneration
          (command "aws")
      result
        `shouldBe` TargetGenerationTombstoneRefused
          (TargetTombstoneNodeNotAuthorized "aws")
      readIORef observations `shouldReturn` 0

    it "binds the command to the exact positive generation in the signed manifest" $ do
      observations <- newIORef (0 :: Int)
      deletes <- newIORef (0 :: Int)
      registry <- registryWith observations deletes [TargetSinkMissing] (Right ())
      result <-
        runTargetGenerationTombstone
          verifiedManifest
          registry
          DestroyTargetGeneration
          (TargetGenerationTombstoneCommand "home" otherManifestGeneration)
      result
        `shouldBe` TargetGenerationTombstoneRefused
          (TargetTombstoneNodeNotAuthorized "home")
      readIORef observations `shouldReturn` 0
      readIORef deletes `shouldReturn` 0

    it "verifies the signed manifest before acquiring Target Agent effects" $ do
      observations <- newIORef (0 :: Int)
      deletes <- newIORef (0 :: Int)
      registry <- registryWith observations deletes [TargetSinkMissing] (Right ())
      result <-
        serveTargetGenerationTombstoneRequest
          65536
          signerDigest
          registry
          ( encodeControlPlaneRequest
              ( TargetGenerationTombstoneRequest
                  otherSignedManifest
                  (command "home")
                  DestroyTargetGeneration
              )
          )
      case result of
        TargetGenerationTombstoneRefused (TargetTombstoneManifestInvalid _) -> pure ()
        other -> expectationFailure ("expected signer-pinning refusal, got " <> show other)
      readIORef observations `shouldReturn` 0
      readIORef deletes `shouldReturn` 0

    it "round-trips the bounded canonical endpoint response" $ do
      decoded <-
        pure
          ( decodeControlPlaneResponse
              65536
              ( LazyByteString.fromStrict
                  (targetGenerationTombstoneResponseBody TargetGenerationPresent)
              )
          )
      decoded `shouldBe` Right TargetTombstoneResponsePresent

    it "rejects an oversized endpoint body before target observation" $ do
      observations <- newIORef (0 :: Int)
      deletes <- newIORef (0 :: Int)
      registry <- registryWith observations deletes [TargetSinkMissing] (Right ())
      result <-
        serveTargetGenerationTombstoneRequest
          1
          signerDigest
          registry
          ( encodeControlPlaneRequest
              ( TargetGenerationTombstoneRequest
                  signedManifest
                  (command "home")
                  DestroyTargetGeneration
              )
          )
      case result of
        TargetGenerationTombstoneRefused (TargetTombstoneBadRequest _) -> pure ()
        other -> expectationFailure ("expected bounded-codec refusal, got " <> show other)
      readIORef observations `shouldReturn` 0

    it "grants metadata deletion only to the Agent's registered target and retained-custody paths" $ do
      case policyNamed "prodbox-target-secret-agent" of
        Nothing -> expectationFailure "missing Target Secret Agent Vault policy"
        Just policy -> do
          let document = Text.unpack (vaultPolicySpecDocument policy)
          document `shouldContain` "path \"secret/metadata/keycloak/smtp\""
          document `shouldContain` "path \"secret/metadata/acme/eab\""
          document
            `shouldContain` "path \"secret/metadata/target-agent/retained-home/ses-smtp-source\""
          document
            `shouldContain` "path \"secret/metadata/target-agent/retained-home/acme-eab-source\""
          document `shouldContain` "capabilities = [\"read\", \"delete\"]"
          document `shouldNotContain` "secret/metadata/*"
 where
  policyNamed name =
    find
      ((== name) . vaultPolicySpecName)
      (vaultReconcilePolicies defaultVaultReconcilePlan)

runWithObservations
  :: IORef Int
  -> [TargetSinkObservation Text.Text]
  -> IO TargetGenerationTombstoneResult
runWithObservations deletes observations =
  runWith deletes observations (Right ())

runWith
  :: IORef Int
  -> [TargetSinkObservation Text.Text]
  -> Either Text.Text ()
  -> IO TargetGenerationTombstoneResult
runWith deletes observations deleteResult = do
  observationCount <- newIORef (0 :: Int)
  registry <- registryWith observationCount deletes observations deleteResult
  runTargetGenerationTombstone
    verifiedManifest
    registry
    DestroyTargetGeneration
    (command "home")

registryWith
  :: IORef Int
  -> IORef Int
  -> [TargetSinkObservation Text.Text]
  -> Either Text.Text ()
  -> IO (TargetGenerationTombstoneRegistry IO Text.Text)
registryWith observations deletes initial deleteResult = do
  remaining <- newIORef initial
  let observe = do
        modifyIORef' observations (+ 1)
        values <- readIORef remaining
        case values of
          [] -> pure (TargetSinkUnobservable "fixture observation exhausted")
          value : rest -> writeIORef remaining rest >> pure value
      trusted = mkTrustedTargetSink targetSink observe
      boundary =
        mkTargetGenerationTombstoneBoundary trusted $ do
          modifyIORef' deletes (+ 1)
          pure deleteResult
      binding = mustRight (mkTargetGenerationTombstoneBinding "home" boundary)
  pure (mustRight (mkTargetGenerationTombstoneRegistry [binding]))

boundaryFixture :: TargetGenerationTombstoneBoundary IO Text.Text
boundaryFixture =
  mkTargetGenerationTombstoneBoundary
    (mkTrustedTargetSink targetSink (pure TargetSinkMissing))
    (pure (Right ()))

bindingFixture :: TargetGenerationTombstoneBinding IO Text.Text
bindingFixture = mustRight (mkTargetGenerationTombstoneBinding "home" boundaryFixture)

targetSink :: TargetClusterSecretSink
targetSink =
  mustRight
    (mkTargetClusterSecretSink "home" "secret" "keycloak/smtp")

generation :: CredentialGeneration
generation = mustRight (mkCredentialGeneration 7)

otherGeneration :: CredentialGeneration
otherGeneration = mustRight (mkCredentialGeneration 8)

targetVersion :: TargetSinkVersion
targetVersion = mustJust (targetSinkVersionFromStoreVersion 7)

targetRecord :: TargetSinkRecord Text.Text
targetRecord = recordFor generation

otherRecord :: TargetSinkRecord Text.Text
otherRecord = recordFor otherGeneration

recordFor :: CredentialGeneration -> TargetSinkRecord Text.Text
recordFor candidateGeneration =
  TargetSinkRecord
    { targetSinkRecordOwnerNonce = mustRight (mkOwnerNonce "owner-1")
    , targetSinkRecordFencingToken = mustRight (mkFencingToken 1)
    , targetSinkRecordGeneration = candidateGeneration
    , targetSinkRecordDigest = mustRight (mkTargetValueDigest (Text.replicate 64 "a"))
    , targetSinkRecordPayload = "payload"
    }

verifiedManifest :: VerifiedDecommissionManifest
verifiedManifest =
  mustRight
    (verifySignedDecommissionManifest signerDigest signedManifest)

signedManifest :: SignedDecommissionManifest
signedManifest = signDecommissionManifest signingKey plan verifier

plan :: DecommissionManifest
plan = mustRight (mkDecommissionManifest "home" [TargetGeneration "home" manifestGeneration])

manifestGeneration :: DecommissionTargetGeneration
manifestGeneration = mustRight (mkDecommissionTargetGeneration 7)

otherManifestGeneration :: DecommissionTargetGeneration
otherManifestGeneration = mustRight (mkDecommissionTargetGeneration 8)

signingKey :: ManifestSigningKey
signingKey = mustRight (mkManifestSigningKey (ByteString.pack [0 .. 31]))

signerDigest :: FrameDigest
signerDigest = manifestPublicKeyDigest (manifestSigningPublicKey signingKey)

otherSignedManifest :: SignedDecommissionManifest
otherSignedManifest = signDecommissionManifest otherSigningKey plan verifier

otherSigningKey :: ManifestSigningKey
otherSigningKey = mustRight (mkManifestSigningKey (ByteString.pack [32 .. 63]))

command :: Text.Text -> TargetGenerationTombstoneCommand
command reference = TargetGenerationTombstoneCommand reference manifestGeneration

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

isRegistryEmpty
  :: Either TargetGenerationTombstoneRegistryError (TargetGenerationTombstoneRegistry IO Text.Text)
  -> Bool
isRegistryEmpty result = case result of
  Left TargetTombstoneRegistryEmpty -> True
  _ -> False

showBindingResult
  :: Either TargetGenerationTombstoneBindingError (TargetGenerationTombstoneBinding IO Text.Text)
  -> String
showBindingResult result = case result of
  Left err -> show err
  Right _ -> "Right <binding>"

mustJust :: Maybe value -> value
mustJust result = case result of
  Just value -> value
  Nothing -> error "invalid target tombstone fixture"

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error ("invalid target tombstone fixture: " <> show err)
