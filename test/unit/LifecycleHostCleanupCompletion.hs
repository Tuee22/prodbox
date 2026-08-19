{-# LANGUAGE OverloadedStrings #-}

module LifecycleHostCleanupCompletion
  ( lifecycleHostCleanupCompletionSuite
  )
where

import Data.Text qualified as Text
import Prodbox.Lifecycle.HostCleanupCompletion
import Prodbox.Lifecycle.HostCleanupIntent (hostCleanupIntentStoreDirectoryName)
import Prodbox.Lifecycle.Teardown.RetainedArtifactCustody
  ( retainedArtifactStoreDirectoryName
  )
import System.FilePath ((</>))
import TestSupport

lifecycleHostCleanupCompletionSuite :: SuiteBuilder ()
lifecycleHostCleanupCompletionSuite =
  describe "Sprint 4.86 local completion journal and read-back" $ do
    it "turns an appended entry into the completion read-back" $ do
      regression <- requireRegression
      localCompletionRegressionAppendedBecomesReceipt regression `shouldBe` True

    it "treats a repeated append of the same entry as already present" $ do
      regression <- requireRegression
      localCompletionRegressionAppendIsIdempotent regression `shouldBe` True

    it "refuses to rewrite a durable entry that differs" $ do
      regression <- requireRegression
      localCompletionRegressionConflictRefusesRewrite regression `shouldBe` True

    it "separates a journal with no entry from a journal that said nothing" $ do
      regression <- requireRegression
      localCompletionRegressionMissingIsNotUnobservable regression `shouldBe` True

    it "refuses an unobservable journal rather than reading it as absence" $ do
      regression <- requireRegression
      localCompletionRegressionUnobservableRefused regression `shouldBe` True

    it "carries the decoded entry's identity rather than the running context's" $ do
      regression <- requireRegression
      localCompletionRegressionReadBackCarriesDecodedIdentity regression `shouldBe` True

    it "refuses an entry appended under another run's proofs" $ do
      regression <- requireRegression
      localCompletionRegressionForeignProofsRefused regression `shouldBe` True

    it "does not accept a successful append response as evidence of retention" $ do
      regression <- requireRegression
      localCompletionRegressionAppendResponseNotEvidence regression `shouldBe` True

    it "names each entry by the digest of its reference" $ do
      regression <- requireRegression
      localCompletionRegressionEntryPathIsReferenceKeyed regression `shouldBe` True

    it "keeps the journal inside the one prodbox-owned control directory" $ do
      -- The entry is appended while the Authority may already be gone and
      -- observed again on a later run, so both locations resolve through the
      -- same control directory and the segment naming it is a compiled
      -- constant beside the other two members rather than a literal at each
      -- site.
      hostCleanupCompletionJournalDirectoryName `shouldBe` "host-cleanup-completion"
      hostCleanupCompletionJournalDirectoryName
        `shouldSatisfy` (/= hostCleanupIntentStoreDirectoryName)
      hostCleanupCompletionJournalDirectoryName
        `shouldSatisfy` (/= retainedArtifactStoreDirectoryName)
      case mkHostCleanupCompletionJournal "/srv/prodbox/.data/prodbox" of
        Left err -> expectationFailure (Text.unpack err)
        Right journal ->
          hostCleanupCompletionJournalRoot journal
            `shouldBe` ("/srv/prodbox/.data/prodbox" </> hostCleanupCompletionJournalDirectoryName)

    it "refuses a journal location that is not an absolute non-root path" $ do
      mkHostCleanupCompletionJournal "relative/control" `shouldSatisfy` isRefusal
      mkHostCleanupCompletionJournal "/" `shouldSatisfy` isRefusal

isRefusal :: Either Text.Text HostCleanupCompletionJournal -> Bool
isRefusal = either (const True) (const False)

requireRegression :: IO LocalCompletionRegression
requireRegression = do
  result <- fixedLocalCompletionRegression
  case result of
    Left err -> expectationFailure (Text.unpack err) >> fail "unreachable"
    Right regression -> pure regression
