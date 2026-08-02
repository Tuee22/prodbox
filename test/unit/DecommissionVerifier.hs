{-# LANGUAGE OverloadedStrings #-}

module DecommissionVerifier (decommissionVerifierSuite) where

import Data.Bits (xor)
import Data.ByteString qualified as ByteString
import Data.IORef (modifyIORef', newIORef, readIORef)
import Prodbox.Lifecycle.Decommission.Frame (FrameDigest (FrameDigest), contentDigest)
import Prodbox.Lifecycle.Decommission.Verifier
import System.Directory (createDirectory, removeFile)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files
  ( createSymbolicLink
  , ownerExecuteMode
  , ownerReadMode
  , ownerWriteMode
  , setFileMode
  , unionFileModes
  )
import TestSupport

decommissionVerifierSuite :: SuiteBuilder ()
decommissionVerifierSuite =
  describe "Sprint 4.50 decommission verifier artifact preflight" $ do
    it "constructs only canonical absolute paths and digest-consistent public artifacts" $ do
      mkExternalArtifactPath "relative/runner" `shouldBe` Left ArtifactPathNotAbsolute
      mkExternalArtifactPath "/tmp/../tmp/runner" `shouldBe` Left ArtifactPathNotCanonical
      mkVerifierMetadata (FrameDigest "short") 1 schemaDigest 1 registryDigest
        `shouldBe` Left VerifierMetadataDigestInvalid
      mkVerifierMetadata dependencyDigest 0 schemaDigest 1 registryDigest
        `shouldBe` Left VerifierMetadataVersionInvalid
      mkVerifierArtifact "" dependencyBytes metadata `shouldBe` Left VerifierArtifactEmpty
      mkVerifierArtifact "runner" "wrong-dependencies" metadata
        `shouldBe` Left VerifierDependencyMetadataDigestMismatch

    it "proves every durable file is distinct and outside exact deletion roots" $
      withSystemTempDirectory "prodbox-verifier-external-paths" $ \dir -> do
        let deleted = mustRight (mkDeletionRootPath (dir </> "deleted"))
            artifactPath = mustRight (mkExternalArtifactPath (dir </> "external" </> "runner"))
            receiptPath = mustRight (mkExternalReceiptPath (dir </> "external" </> "receipt.log"))
            insideArtifact = mustRight (mkExternalArtifactPath (dir </> "deleted" </> "runner"))
            siblingArtifact = mustRight (mkExternalArtifactPath (dir </> "deleted-other" </> "runner"))
        mkExternalDurablePaths [] artifactPath receiptPath
          `shouldBe` Left ExternalDeletionRootInventoryEmpty
        mkExternalDurablePaths [deleted] artifactPath receiptPath
          `shouldBe` Right (mustRight (mkExternalDurablePaths [deleted] artifactPath receiptPath))
        mkExternalDurablePaths [deleted] insideArtifact receiptPath
          `shouldBe` Left
            ( ExternalDurableFileInsideDeletionRoot
                (externalArtifactPath insideArtifact)
                deleted
            )
        mkExternalDurablePaths [deleted] siblingArtifact receiptPath
          `shouldBe` Right (mustRight (mkExternalDurablePaths [deleted] siblingArtifact receiptPath))
        let collidingReceipt =
              mustRight (mkExternalReceiptPath (externalArtifactPath artifactPath))
        mkExternalDurablePaths [deleted] artifactPath collidingReceipt
          `shouldBe` Left (ExternalDurableFileCollision (externalArtifactPath artifactPath))

    it "rejects a lexically external path whose parent resolves through a symlink" $
      withSystemTempDirectory "prodbox-verifier-external-realpath" $ \dir -> do
        let actualDirectory = dir </> "actual-external"
            aliasDirectory = dir </> "external-alias"
            deletedDirectory = dir </> "deleted"
        createDirectory actualDirectory
        createDirectory deletedDirectory
        createSymbolicLink actualDirectory aliasDirectory
        let deleted = mustRight (mkDeletionRootPath deletedDirectory)
            artifactPath = mustRight (mkExternalArtifactPath (aliasDirectory </> "runner"))
            receiptPath = mustRight (mkExternalReceiptPath (aliasDirectory </> "receipt.log"))
        result <- validateExternalDurablePathsOnHost [deleted] artifactPath receiptPath
        case result of
          Left (ExternalDurablePathNotResolvedCanonical supplied resolved) -> do
            supplied `shouldBe` externalArtifactPath artifactPath
            resolved `shouldBe` (actualDirectory </> "runner")
          other -> expectationFailure ("expected realpath refusal, got " <> show other)

    it "round-trips the bounded canonical metadata envelope" $ do
      decodeVerifierMetadata 65536 (encodeVerifierMetadata metadata) `shouldBe` Right metadata
      decodeVerifierMetadata 1 (encodeVerifierMetadata metadata) `shouldBe` Left VerifierMetadataTooLarge
      decodeVerifierMetadata 65536 "not-metadata" `shouldBe` Left VerifierMetadataInvalid

    it "exports artifact, dependency metadata, and canonical metadata then preflights exactly" $
      withExternalPath $ \path -> do
        exported <- exportVerifierArtifact path artifact
        exported `shouldBe` Right (verifierBindingOf path artifact)
        result <- runVerifierPreflight (verifierBindingOf path artifact)
        case result of
          VerifierReady preflighted ->
            preflightedVerifierBinding preflighted `shouldBe` verifierBindingOf path artifact
          other -> expectationFailure ("expected ready preflight, got " <> show other)

    it "exports the exact running executable bytes through the same durable boundary" $
      withSystemTempDirectory "prodbox-running-verifier-export" $ \dir -> do
        let source = dir </> "running-prodbox"
            exportedPath = mustRight (mkExternalArtifactPath (dir </> "external-runner"))
            executableMode =
              ownerReadMode `unionFileModes` ownerWriteMode `unionFileModes` ownerExecuteMode
        ByteString.writeFile source "exact-running-executable"
        setFileMode source executableMode
        exported <-
          exportVerifierArtifactFromExecutable source exportedPath dependencyBytes metadata
        case exported of
          Left err -> expectationFailure ("expected running export, got " <> show err)
          Right binding -> do
            boundArtifactDigest binding `shouldBe` contentDigest "exact-running-executable"
            preflight <- runVerifierPreflight binding
            preflight `shouldSatisfy` verifierPreflightReady
        setFileMode source (ownerReadMode `unionFileModes` ownerWriteMode)
        exportVerifierArtifactFromExecutable source exportedPath dependencyBytes metadata
          `shouldReturn` Left RunningVerifierSourceNotExecutable

    it "refuses each missing member of the exact three-file export" $ do
      withExternalPath $ \path -> do
        runVerifierPreflight (verifierBindingOf path artifact)
          `shouldReturn` VerifierRefused VerifierArtifactAbsent
      withExported $ \path binding -> do
        removeFile (verifierDependencyPath path)
        runVerifierPreflight binding
          `shouldReturn` VerifierRefused VerifierDependencyMetadataAbsent
      withExported $ \path binding -> do
        removeFile (verifierMetadataPath path)
        runVerifierPreflight binding
          `shouldReturn` VerifierRefused VerifierMetadataAbsent

    it "refuses tampered runner or dependency bytes" $ do
      withExported $ \path binding -> do
        flipFirstByte (externalArtifactPath path)
        runVerifierPreflight binding
          `shouldReturn` VerifierRefused VerifierArtifactDigestMismatch
      withExported $ \path binding -> do
        flipFirstByte (verifierDependencyPath path)
        runVerifierPreflight binding
          `shouldReturn` VerifierRefused VerifierDependencyDigestMismatch

    it "requires an executable regular artifact and refuses symlink substitution" $ do
      withExported $ \path binding -> do
        setFileMode
          (externalArtifactPath path)
          (ownerReadMode `unionFileModes` ownerWriteMode)
        runVerifierPreflight binding
          `shouldReturn` VerifierRefused VerifierArtifactNotExecutable
      withExported $ \path binding -> do
        let artifactFile = externalArtifactPath path
            substitute = artifactFile <> ".substitute"
        ByteString.writeFile substitute (verifierArtifactBytes artifact)
        removeFile artifactFile
        createSymbolicLink substitute artifactFile
        result <- runVerifierPreflight binding
        case result of
          VerifierRefused (VerifierArtifactUnreadable _) -> pure ()
          other -> expectationFailure ("expected no-follow refusal, got " <> show other)

    it "refuses schema, interpreter-registry, dependency, and metadata-codec drift" $ do
      withExported $ \path binding -> do
        ByteString.writeFile
          (verifierMetadataPath path)
          (encodeVerifierMetadata (metadataWith 2 schemaDigest 1 registryDigest dependencyDigest))
        runVerifierPreflight binding
          `shouldReturn` VerifierRefused VerifierManifestSchemaDrift
      withExported $ \path binding -> do
        ByteString.writeFile
          (verifierMetadataPath path)
          (encodeVerifierMetadata (metadataWith 1 schemaDigest 9 registryDigest dependencyDigest))
        runVerifierPreflight binding
          `shouldReturn` VerifierRefused VerifierInterpreterRegistryDrift
      withExported $ \path binding -> do
        ByteString.writeFile
          (verifierMetadataPath path)
          (encodeVerifierMetadata (metadataWith 1 schemaDigest 1 registryDigest (contentDigest "deps-v2")))
        runVerifierPreflight binding
          `shouldReturn` VerifierRefused VerifierDependencyDigestMismatch
      withExported $ \path binding -> do
        ByteString.writeFile (verifierMetadataPath path) "not-decodable-metadata"
        result <- runVerifierPreflight binding
        case result of
          VerifierRefused (VerifierMetadataInvalidOnDisk _) -> pure ()
          other -> expectationFailure ("expected metadata-codec refusal, got " <> show other)

    it "binds the exact external path rather than accepting a same-content substitute" $
      withSystemTempDirectory "prodbox-verifier-path-binding" $ \dir -> do
        let expectedPath = mustRight (mkExternalArtifactPath (dir </> "expected-runner"))
            substitutePath = mustRight (mkExternalArtifactPath (dir </> "substitute-runner"))
        _ <- exportVerifierArtifact substitutePath artifact
        runVerifierPreflight (verifierBindingOf expectedPath artifact)
          `shouldReturn` VerifierRefused VerifierArtifactAbsent

    it "refuses a current new build and requires self-execution of the preflighted pinned path" $
      withExported $ \path binding -> do
        result <- runVerifierPreflight binding
        preflighted <- expectReady result
        let exactDecision = decidePinnedArtifactExecution preflighted binding
        pinnedExecutionIsCurrent exactDecision `shouldBe` True
        pinnedExecutionBinding exactDecision `shouldBe` binding
        pinnedSelfExecutionPath exactDecision `shouldBe` Nothing
        let newBuild =
              mustRight
                (mkVerifierArtifact "new-runner-build" dependencyBytes metadata)
            newBuildIdentity = verifierBindingOf path newBuild
        let newBuildDecision = decidePinnedArtifactExecution preflighted newBuildIdentity
        pinnedExecutionIsCurrent newBuildDecision `shouldBe` False
        pinnedExecutionBinding newBuildDecision `shouldBe` binding
        pinnedSelfExecutionPath newBuildDecision `shouldBe` Just path

    it "invokes process replacement only with the exact preflighted pinned path and arguments" $
      withExported $ \path binding -> do
        preflighted <- runVerifierPreflight binding >>= expectReady
        callsRef <- newIORef []
        let replacement target replacementArguments =
              modifyIORef' callsRef ((target, replacementArguments) :)
            exactDecision = decidePinnedArtifactExecution preflighted binding
            newBuild = mustRight (mkVerifierArtifact "new-running-build" dependencyBytes metadata)
            replaceDecision = decidePinnedArtifactExecution preflighted (verifierBindingOf path newBuild)
            arguments = ["nuke", "--receipt", "/external/receipt"]
        applyPinnedExecutionDecisionWith replacement arguments exactDecision
          `shouldReturn` PinnedProcessAlreadyCurrent
        readIORef callsRef `shouldReturn` []
        applyPinnedExecutionDecisionWith replacement arguments replaceDecision
          `shouldReturn` PinnedProcessReplacementInvoked path
        readIORef callsRef
          `shouldReturn` [(externalArtifactPath path, arguments)]
 where
  dependencyBytes = "canonical dependency closure: crypton-1.0.6; serialise-0.2.6.1"
  dependencyDigest = contentDigest dependencyBytes
  schemaDigest = contentDigest "decommission-manifest-schema-v1"
  registryDigest = contentDigest "decommission-interpreter-registry-v1"
  metadata = metadataWith 1 schemaDigest 1 registryDigest dependencyDigest
  metadataWith schemaVersion schemaIdentity registryVersion registryIdentity dependencies =
    mustRight
      ( mkVerifierMetadata
          dependencies
          schemaVersion
          schemaIdentity
          registryVersion
          registryIdentity
      )
  artifact =
    mustRight
      ( mkVerifierArtifact
          "pinned-decommission-runner-build-bytes"
          dependencyBytes
          metadata
      )

withExternalPath :: (ExternalArtifactPath -> IO value) -> IO value
withExternalPath action =
  withSystemTempDirectory "prodbox-verifier" $ \dir ->
    action (mustRight (mkExternalArtifactPath (dir </> "verifier-artifact")))

withExported
  :: (ExternalArtifactPath -> VerifierBinding -> IO value)
  -> IO value
withExported action =
  withExternalPath $ \path -> do
    exported <- exportVerifierArtifact path fixtureArtifact
    action path (mustRight exported)
 where
  dependencyBytes = "canonical dependency closure: crypton-1.0.6; serialise-0.2.6.1"
  metadata =
    mustRight
      ( mkVerifierMetadata
          (contentDigest dependencyBytes)
          1
          (contentDigest "decommission-manifest-schema-v1")
          1
          (contentDigest "decommission-interpreter-registry-v1")
      )
  fixtureArtifact =
    mustRight
      (mkVerifierArtifact "pinned-decommission-runner-build-bytes" dependencyBytes metadata)

expectReady :: VerifierPreflightResult -> IO PreflightedVerifierArtifact
expectReady result = case result of
  VerifierReady preflighted -> pure preflighted
  other -> expectationFailure ("expected ready preflight, got " <> show other) >> fail "unreachable"

flipFirstByte :: FilePath -> IO ()
flipFirstByte path = do
  bytes <- ByteString.readFile path
  ByteString.writeFile
    path
    (ByteString.cons (ByteString.head bytes `xor` 0xFF) (ByteString.tail bytes))

mustRight :: (Show err) => Either err value -> value
mustRight = either (error . show) id
