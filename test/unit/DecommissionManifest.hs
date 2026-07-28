{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module DecommissionManifest (decommissionManifestSuite) where

import Codec.Serialise (Serialise)
import Data.Maybe (fromJust)
import Data.Text (Text)
import GHC.Generics (Generic)
import Prodbox.Lifecycle.Decommission.Frame (appendPayload, mkFrameAttemptId, mkFrameNodeId)
import Prodbox.Lifecycle.Decommission.Journal
  ( JournalRecoveryError (JournalChainDrift)
  , ReceiptRecovery (recoveryOutcome)
  , RecoveryOutcome (RecoveryComplete, RecoveryRefused)
  , encodeJournal
  , recoverReceipt
  )
import Prodbox.Lifecycle.Decommission.Manifest
import TestSupport

newtype ReceiptPayload = ReceiptPayload Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

decommissionManifestSuite :: SuiteBuilder ()
decommissionManifestSuite =
  describe "Sprint 4.50 decommission manifest" $ do
    it "builds a validated manifest and exposes its inventory" $ do
      manifestVersion validManifest `shouldBe` currentManifestVersion
      manifestClusterId validManifest `shouldBe` "home"
      manifestNodes validManifest `shouldBe` nodes
    it "rejects an empty, duplicated, or malformed inventory" $ do
      mkDecommissionManifest "home" [] `shouldBe` Left ManifestNodesEmpty
      mkDecommissionManifest "home" [SharedObjectBucket, SharedObjectBucket]
        `shouldBe` Left ManifestNodesDuplicated
      mkDecommissionManifest "" nodes `shouldBe` Left ManifestClusterIdInvalid
      mkDecommissionManifest "home" [TargetGeneration ""]
        `shouldBe` Left ManifestTargetRefInvalid
    it "digests deterministically and distinctly per plan" $ do
      decommissionManifestDigest validManifest
        `shouldBe` decommissionManifestDigest validManifest
      decommissionManifestDigest validManifest
        `shouldNotBe` decommissionManifestDigest otherManifest
    it "changes the digest when the cluster identity or node order changes" $ do
      let renamed = mustRight (mkDecommissionManifest "aws" nodes)
          reordered = mustRight (mkDecommissionManifest "home" (reverse nodes))
      decommissionManifestDigest validManifest
        `shouldNotBe` decommissionManifestDigest renamed
      decommissionManifestDigest validManifest
        `shouldNotBe` decommissionManifestDigest reordered
    it "binds a receipt to exactly its manifest digest" $ do
      recoveryOutcome (recover (decommissionManifestDigest validManifest))
        `shouldBe` RecoveryComplete
      recoveryOutcome (recover (decommissionManifestDigest otherManifest))
        `shouldBe` RecoveryRefused (JournalChainDrift 0)
 where
  nodes =
    [ SesConsumerQuiescence
    , SesProviderStack
    , SesSmtpIam
    , TargetGeneration "vscode"
    , RetainedCustody
    , TlsRetainedObjects
    , TlsRetentionIdentity
    , BackupPrefixAbsenceProof
    , BackupObjects
    , SharedObjectBucket
    ]
  validManifest = mustRight (mkDecommissionManifest "home" nodes)
  otherManifest = mustRight (mkDecommissionManifest "aws" [SesProviderStack, SharedObjectBucket])
  nodeId = fromJust (mkFrameNodeId "ses-provider")
  attemptId = fromJust (mkFrameAttemptId "attempt-1")
  journal manifestDigest =
    let frame0 = appendPayload manifestDigest Nothing nodeId attemptId (ReceiptPayload "intent")
        frame1 = appendPayload manifestDigest (Just frame0) nodeId attemptId (ReceiptPayload "result")
     in encodeJournal [frame0, frame1]
  boundJournal = journal (decommissionManifestDigest validManifest)
  recover expectedDigest = recoverReceipt 8192 expectedDigest boundJournal :: ReceiptRecovery ReceiptPayload

mustRight :: (Show err) => Either err value -> value
mustRight = either (error . show) id
