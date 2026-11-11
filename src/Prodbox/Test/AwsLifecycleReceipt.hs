{-# LANGUAGE OverloadedStrings #-}

-- | The read-only receipt for the AWS stack lifecycle's scoped claim (Sprint
-- 6.7). It reads the drill ledger and the current tree's scoped source
-- identity, mutates nothing and needs no cluster or AWS credential.
--
-- It says what it recomputed (the hash chain, the consecutive-run fold, the
-- scoped digest of the tree now) and what it could only compare (the digests
-- each drill recorded). The newest drill's scoped digest must equal the tree's
-- digest now: a source change inside the scope since the last drill means the
-- counted drills ran on a different identity.
module Prodbox.Test.AwsLifecycleReceipt
  ( AwsReceiptReport (..)
  , runAwsLifecycleReceipt
  , renderAwsReceiptLines
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Test.Qualification.AwsLifecycleDrillLedger
import Prodbox.Test.Qualification.AwsLifecycleDrillLedgerStore
  ( drillLedgerPath
  , readDrillLedger
  , renderDrillStoreError
  )
import Prodbox.Test.Qualification.SourceIdentity (sourceManifestDigest)
import Prodbox.Test.Qualification.SourceManifest (captureAwsLifecycleSourceIdentity)

data AwsReceiptReport = AwsReceiptReport
  { awsReceiptQualified :: !Bool
  , awsReceiptLines :: ![Text]
  }

runAwsLifecycleReceipt :: FilePath -> IO AwsReceiptReport
runAwsLifecycleReceipt repoRoot = do
  ledgerResult <- readDrillLedger (drillLedgerPath repoRoot)
  case ledgerResult of
    Left err -> pure (refused (Text.pack (renderDrillStoreError err)))
    Right ledger -> do
      treeResult <- captureAwsLifecycleSourceIdentity repoRoot []
      pure $ case treeResult of
        Left err ->
          refused ("the scoped source identity of the tree could not be captured: " <> Text.pack (show err))
        Right identity ->
          let receipt = judgeReceipt ledger
              attempts = resolveDrillAttempts ledger
              run = currentRun attempts
              runDigest = case reverse run of
                newest : _ -> Just (begunScopedDigest (attemptBegun newest))
                [] -> Nothing
              treeDigest = sourceManifestDigest identity
              onTree = runDigest == Just treeDigest
           in AwsReceiptReport
                { awsReceiptQualified = receiptVerdict receipt == Qualified && onTree
                , awsReceiptLines = renderAwsReceiptLines receipt (length attempts) runDigest treeDigest onTree
                }
 where
  refused reason =
    AwsReceiptReport False ["AWS_LIFECYCLE_QUALIFIED=false", "REFUSED=" <> reason]

renderAwsReceiptLines :: RunReceipt -> Int -> Maybe Text -> Text -> Bool -> [Text]
renderAwsReceiptLines receipt attempts runDigest treeDigest onTree =
  [ "AWS_LIFECYCLE_QUALIFIED=" <> boolText (receiptVerdict receipt == Qualified && onTree)
  , "ATTEMPTS=" <> Text.pack (show attempts)
  , "CURRENT_RUN_LENGTH=" <> Text.pack (show (receiptRunLength receipt))
  , "CHAIN_INTACT=" <> boolText (receiptChainIntact receipt)
  , "SCOPED_DIGEST_TREE_NOW=" <> treeDigest
  , "SCOPED_DIGEST_OF_RUN=" <> maybe "none" id runDigest
  , "RUN_ON_CURRENT_TREE=" <> boolText onTree
  , "PROVIDER_IMAGE_DIGEST_CHANGES=" <> Text.pack (show (receiptImageDigestChanges receipt))
  , "FAILURE_RATE_BOUND_95_PERCENT=" <> Text.pack (show (receiptBoundPercent receipt))
  , "RECOMPUTED=" <> receiptRecomputed receipt
  , "COMPARED_ONLY=" <> receiptCompared receipt
  , "UNCOVERED=" <> receiptUncovered receipt
  ]
    ++ case receiptVerdict receipt of
      Qualified -> []
      NotQualified missing -> ["UNMET=" <> criterionName c | c <- missing]
 where
  boolText value = if value then "true" else "false"
