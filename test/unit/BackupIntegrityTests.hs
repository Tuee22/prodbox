{-# LANGUAGE OverloadedStrings #-}

module BackupIntegrityTests (backupIntegritySuite) where

import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (isInfixOf)
import Data.Text qualified as Text
import Prodbox.Config.BootstrapProjection
  ( BootstrapDraft (..)
  , bootstrapRootGeneration
  , bootstrapScope
  , decodeOptionalBootstrapSource
  , renderBootstrapDraft
  )
import Prodbox.Config.DeploymentScope (scopeKindName, scopeRoot)
import Prodbox.Control.Backup
  ( backupStepDetail
  , backupStepOk
  , protectedRestoreHistoryMatches
  , restoreServices
  , treeDigest
  )
import Prodbox.Control.BrokerDeploy (localBrokerStoreBucket)
import Prodbox.Minio.ObjectStoreTypes (defaultObjectStoreBucket)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import TestSupport (SuiteBuilder, assertMutationInvariant, describe, it, shouldBe)

backupIntegritySuite :: SuiteBuilder ()
backupIntegritySuite = describe "backup content integrity" $ do
  it "detects a same-size content change for the mutation catalog" $
    withSystemTempDirectory "prodbox-backup-integrity" $ \directory -> do
      let path = directory </> "synthetic-data"
          key = "synthetic-test-key"
      ByteString.writeFile path "AAAA"
      original <- treeDigest key directory
      repeated <- treeDigest key directory
      ByteString.writeFile path "BBBB"
      changed <- treeDigest key directory
      original `shouldBe` repeated
      assertMutationInvariant
        "backup.rejects_same_size_corruption"
        ( case (original, changed) of
            (Right before, Right after) -> before /= after
            _ -> False
        )

  it "retains an unverified format-1 backup and names the recovery input" $
    withSystemTempDirectory "prodbox-backup-legacy" $ \anchor -> do
      let digest = "sha256:" <> Text.replicate 64 "a"
          draft =
            BootstrapDraft
              { draftProjectAnchor = Text.pack anchor
              , draftRuntimeSocket = "/var/run/docker.sock"
              , draftEnvironment = "test"
              , draftDeploymentId = "run"
              , draftRootGeneration = Text.replicate 32 "b"
              , draftApiPort = 26443
              , draftNodeImage = "kindest/node@" <> digest
              , draftHttpHostPort = 28080
              , draftHttpNodePort = 30080
              , draftHttpsHostPort = 28443
              , draftHttpsNodePort = 30443
              , draftListenAddress = "127.0.0.1"
              , draftNodePath = "artifacts/node.tar"
              , draftNodeDigest = digest
              , draftNodeMaximumBytes = 4096
              , draftKindPath = "artifacts/kind"
              , draftKindDigest = digest
              , draftKindMaximumBytes = 1048576
              }
      decoded <- decodeOptionalBootstrapSource (anchor </> "selected.dhall") (renderBootstrapDraft draft)
      projection <- case decoded of
        Right (Just value) -> pure value
        _ -> fail "synthetic bootstrap projection was refused"
      let backup = scopeRoot (bootstrapScope projection) </> "backups" </> "backup-legacy"
          manifest = backup </> "manifest.json"
      createDirectoryIfMissing True backup
      LazyByteString.writeFile manifest $
        Aeson.encode $
          Aeson.object
            [ "schema_version" .= (1 :: Int)
            , "scope" .= scopeKindName (bootstrapScope projection)
            , "root_generation" .= bootstrapRootGeneration projection
            ]
      result <- restoreServices projection "backup-legacy"
      map backupStepOk result `shouldBe` [False]
      any (("independently known-good live source" `isInfixOf`) . backupStepDetail) result
        `shouldBe` True
      doesFileExist manifest >>= (`shouldBe` True)

  it "rejects restoring an older Broker fence while allowing regenerated MinIO temporary files" $
    withSystemTempDirectory "prodbox-restore-history" $ \directory -> do
      let backup = directory </> "backup"
          live = directory </> "live"
          brokerBucket = "minio-data" </> localBrokerStoreBucket
          sys = "minio-data" </> ".minio.sys"
          members = ["vault-data", brokerBucket, "minio-data" </> defaultObjectStoreBucket, sys </> "config"]
          setup root = do
            mapM_ (createDirectoryIfMissing True . (root </>)) members
            ByteString.writeFile (root </> brokerBucket </> "fence") "old-record"
          observe = protectedRestoreHistoryMatches "synthetic-restore-key" backup live
      mapM_ setup [backup, live]
      ByteString.writeFile (live </> sys </> "temporary") "regenerated"
      observe >>= (`shouldBe` True)
      ByteString.writeFile (live </> brokerBucket </> "fence") "new-record"
      observe >>= (`shouldBe` False)
