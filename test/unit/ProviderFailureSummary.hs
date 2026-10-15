{-# LANGUAGE OverloadedStrings #-}

-- | The reading of a failed provider command, and the three layers it crosses
-- on its way to the operator.
--
-- A destroy that retries one AWS dependency error and then ends on a
-- credential-expiry error used to be reported as the first 4096 characters of
-- its transcript: the retried error's noise, with the final error cut off. The
-- cases below run that shape through the new summary, and keep the old
-- truncation and the old @show@-based rendering as negative controls so the
-- two defects stay demonstrated.
module ProviderFailureSummary
  ( providerFailureSummarySuite
  )
where

import Control.Monad (forM_)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.AuthorityProviderEndpoint
  ( AuthorityProviderClientError (..)
  , renderAuthorityProviderClientError
  )
import Prodbox.ControlPlane.ProviderFailureSummary
import Prodbox.ControlPlane.ProviderWorkerClient
  ( ProviderWorkerClientError (..)
  , renderProviderWorkerClientError
  )
import Prodbox.ControlPlane.ProviderWorkerExecution
  ( ProviderIntentExecutionError (..)
  , renderProviderIntentExecutionError
  )
import TestSupport

subnetId :: Text
subnetId = "subnet-0123456789abcdef0"

dependencyLine :: Text
dependencyLine =
  "error: deleting EC2 Subnet ("
    <> subnetId
    <> "): operation error EC2: DeleteSubnet, https response error StatusCode: 400, "
    <> "RequestID: 11111111-2222-3333-4444-555555555555, api error DependencyViolation: "
    <> "The subnet '"
    <> subnetId
    <> "' has dependencies and cannot be deleted."

expiredLine :: Text
expiredLine =
  "error: deleting EC2 Subnet ("
    <> subnetId
    <> "): operation error EC2: DeleteSubnet, https response error StatusCode: 400, "
    <> "RequestID: 66666666-7777-8888-9999-000000000000, api error RequestExpired: "
    <> "Request has expired."

-- | The shape of the 2026-09-29 incident: one dependency error reported over
-- and over, then a credential-expiry error that ends the run.
retriedThenExpired :: Text
retriedThenExpired =
  Text.unlines (replicate 400 dependencyLine <> [expiredLine])

-- | The pre-fix display text, verbatim. It is kept only as a negative control.
legacyCommandDetail :: Text -> Text -> Text
legacyCommandDetail standardError standardOutput =
  Text.take 4096 (standardError <> " " <> standardOutput)

providerFailureSummarySuite :: SuiteBuilder ()
providerFailureSummarySuite =
  describe "provider failure summary" $ do
    it "names the first AWS error as the cause and the last differing one as the consequence" $
      summarizeFailure retriedThenExpired
        `shouldBe` FailureSummary
          { summaryCause = Just (FailureFinding "DependencyViolation" (Just subnetId))
          , summaryCauseOccurrences = 400
          , summaryConsequence = Just (FailureFinding "RequestExpired" (Just subnetId))
          }

    it "renders cause then consequence ahead of a bounded head and tail" $ do
      let rendered = renderCommandFailure retriedThenExpired ""
      Text.length rendered `shouldSatisfy` (<= failureDetailBound)
      rendered
        `shouldSatisfy` Text.isPrefixOf
          ( "cause: DependencyViolation on "
              <> subnetId
              <> " (reported 400 times); consequence: RequestExpired on "
              <> subnetId
          )
      -- The final error is the tail, which the head-only truncation dropped.
      rendered `shouldSatisfy` Text.isInfixOf "api error RequestExpired: Request has expired."
      rendered `shouldSatisfy` Text.isInfixOf "error: deleting EC2 Subnet"
      rendered `shouldSatisfy` Text.isInfixOf "characters omitted"

    it "negative control: the pre-fix truncation dropped the final error" $
      legacyCommandDetail retriedThenExpired ""
        `shouldSatisfy` (not . Text.isInfixOf "RequestExpired")

    it "keeps a transcript within the bound whole, with no header when no AWS error is named" $
      renderCommandFailure "error: stack not found" "stdout text"
        `shouldBe` "error: stack not found stdout text"

    it "reports a single error without a consequence or a repeat count" $
      renderCommandFailure
        "operation error IAM: DeleteRole, api error AccessDenied: not authorized"
        ""
        `shouldSatisfy` Text.isPrefixOf "cause: AccessDenied | transcript: "

    it "reports a destroy that ran out of time as the consequence of what it had already reported" $ do
      let timedOut =
            dependencyLine
              <> "\n"
              <> childTimeoutMarker
              <> " pulumi was stopped after 1680 seconds"
      summarizeFailure timedOut
        `shouldBe` FailureSummary
          { summaryCause = Just (FailureFinding "DependencyViolation" (Just subnetId))
          , summaryCauseOccurrences = 1
          , summaryConsequence = Just (FailureFinding childTimedOutCode Nothing)
          }
      renderCommandFailure timedOut ""
        `shouldSatisfy` Text.isPrefixOf
          ( "cause: DependencyViolation on "
              <> subnetId
              <> "; consequence: ChildTimedOut"
          )

    it "names a child timeout as the cause when nothing else was reported" $
      renderCommandFailure "" (childTimeoutMarker <> " pulumi was stopped after 1680 seconds")
        `shouldSatisfy` Text.isPrefixOf "cause: ChildTimedOut | transcript: "

    it "stays within the bound for every transcript size" $
      forM_ [0, 1, 100, 4000, 4096, 5000, 100000] $ \size ->
        Text.length (renderCommandFailure (Text.replicate size "x") (Text.replicate size "y"))
          `shouldSatisfy` (<= failureDetailBound)

    it "classifies on the whole transcript and not on the first 4096 characters" $ do
      let longPreview =
            Text.replicate 5000 "x"
              <> " error: no changes were expected but changes were proposed"
          longMissing = Text.replicate 5000 "x" <> " error: no stack named 'aws-eks'"
      transcriptReportsPreviewChanges longPreview `shouldBe` True
      transcriptReportsMissingStack longMissing `shouldBe` True
      -- Negative control: what the same predicate saw when it read the
      -- truncated display text.
      transcriptReportsPreviewChanges (legacyCommandDetail longPreview "") `shouldBe` False
      transcriptReportsMissingStack (legacyCommandDetail longMissing "") `shouldBe` False

    it "matches the stack predicates case-insensitively" $ do
      transcriptReportsMissingStack "Error: No Stack Named foo" `shouldBe` True
      transcriptReportsPreviewChanges "ERROR: NO CHANGES WERE EXPECTED" `shouldBe` True
      transcriptReportsMissingStack "stack exists" `shouldBe` False

    it "carries a failure detail through the three layers without re-escaping it" $ do
      let detail =
            "cause: DependencyViolation on "
              <> subnetId
              <> " | transcript: line one\nline \"two\""
          executed =
            renderProviderIntentExecutionError
              (ProviderIntentExecutionMutationNotConfirmed detail)
          remote = renderProviderWorkerClientError (ProviderWorkerRemoteRefused 503 executed)
          relayed = renderAuthorityProviderClientError (AuthorityProviderRemoteRefused 503 remote)
      forM_ [executed, remote, relayed] $ \rendered -> do
        rendered `shouldSatisfy` Text.isInfixOf detail
        rendered `shouldSatisfy` (not . Text.isInfixOf "\\\"")

    it "negative control: rendering the same error with show escapes it" $ do
      let detail = "line one\nline \"two\""
      Text.pack (show (ProviderIntentExecutionMutationNotConfirmed detail))
        `shouldSatisfy` (not . Text.isInfixOf detail)
