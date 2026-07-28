{-# LANGUAGE OverloadedStrings #-}

module DecommissionVerifier (decommissionVerifierSuite) where

import Data.Bits (xor)
import Data.ByteString qualified as ByteString
import Prodbox.Lifecycle.Decommission.Frame (FrameDigest (FrameDigest))
import Prodbox.Lifecycle.Decommission.Verifier
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import TestSupport

decommissionVerifierSuite :: SuiteBuilder ()
decommissionVerifierSuite =
  describe "Sprint 4.50 decommission verifier artifact preflight" $ do
    it "exports the artifact durably and its preflight then passes" $
      withArtifact $ \path -> do
        exported <- exportVerifierArtifact path artifact
        exported `shouldBe` Right binding
        result <- runVerifierPreflight path binding
        result `shouldBe` VerifierReady
    it "refuses when the exported artifact is absent" $
      withSystemTempDirectory "prodbox-verifier-absent" $ \dir -> do
        result <- runVerifierPreflight (dir </> "missing") binding
        result `shouldBe` VerifierRefused VerifierArtifactAbsent
    it "refuses a tampered artifact as a digest mismatch" $
      withArtifact $ \path -> do
        _ <- exportVerifierArtifact path artifact
        flipFirstByte path
        result <- runVerifierPreflight path binding
        result `shouldBe` VerifierRefused VerifierArtifactDigestMismatch
    it "refuses a drifted manifest schema, interpreter registry, or dependency closure" $
      withArtifact $ \path -> do
        _ <- exportVerifierArtifact path artifact
        runVerifierPreflight path (rebind metadata {verifierManifestSchemaVersion = 2})
          `shouldReturn` VerifierRefused VerifierManifestSchemaDrift
        runVerifierPreflight path (rebind metadata {verifierInterpreterRegistryVersion = 9})
          `shouldReturn` VerifierRefused VerifierInterpreterRegistryDrift
        runVerifierPreflight path (rebind metadata {verifierDependencyDigest = FrameDigest "deps-v2"})
          `shouldReturn` VerifierRefused VerifierDependencyDigestMismatch
    it "refuses corrupt metadata" $
      withArtifact $ \path -> do
        _ <- exportVerifierArtifact path artifact
        ByteString.writeFile (path ++ ".meta") "not-decodable-metadata"
        result <- runVerifierPreflight path binding
        case result of
          VerifierRefused (VerifierArtifactUnreadable _) -> pure ()
          other -> expectationFailure ("expected unreadable metadata refusal, got " <> show other)
 where
  withArtifact action =
    withSystemTempDirectory "prodbox-verifier" $ \dir -> action (dir </> "verifier-artifact")
  metadata =
    VerifierMetadata
      { verifierDependencyDigest = FrameDigest "deps-v1"
      , verifierManifestSchemaVersion = 1
      , verifierManifestSchemaDigest = FrameDigest "schema-v1"
      , verifierInterpreterRegistryVersion = 1
      , verifierInterpreterRegistryDigest = FrameDigest "registry-v1"
      }
  artifact =
    VerifierArtifact
      { verifierArtifactBytes = "pinned-decommission-runner-build-bytes"
      , verifierArtifactMetadata = metadata
      }
  binding = verifierBindingOf artifact
  -- The artifact digest still matches (bytes unchanged); only the expected metadata
  -- differs, so the preflight exercises a pure drift refusal.
  rebind driftedMetadata = binding {boundMetadata = driftedMetadata}

flipFirstByte :: FilePath -> IO ()
flipFirstByte path = do
  bytes <- ByteString.readFile path
  ByteString.writeFile
    path
    (ByteString.cons (ByteString.head bytes `xor` 0xFF) (ByteString.tail bytes))
