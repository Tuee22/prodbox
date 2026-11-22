{-# LANGUAGE OverloadedStrings #-}

module AdmissionHistoryTests (admissionHistorySuite) where

import Control.Exception (bracket)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Prodbox.Bootstrap.Broker.TokenReview
  ( BrokerTokenReviewResult (..)
  , BrokerTokenReviewUser (..)
  )
import Prodbox.ControlPlane.AdmissionJournalMirror
  ( initialiseJournalMirror
  , mirrorAdmissionRepository
  , observeJournalMirror
  )
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (..)
  , AuthorityAdmissionSnapshot (..)
  )
import Prodbox.ControlPlane.AuthorityJournalReadServer
  ( bearerTokenOf
  , decideJournalReadAccess
  , journalReadAudience
  , verdictCode
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..))
import Prodbox.Lifecycle.AdmissionHistory
import Prodbox.Lifecycle.AdmissionLedgerProjection (ledgerJournalObservation)
import Prodbox.Lifecycle.Authority.Admission (initialCleanInstallAuthority)
import Prodbox.Lifecycle.Authority.Submission
  ( ClientId (..)
  , ClientSequence (..)
  , ClientSubmissions (..)
  , RequestDigest (..)
  , SubmissionLedger (..)
  , SubmissionRecord (..)
  , TerminalOutcome (..)
  , emptySubmissionLedger
  )
import System.Directory
  ( createDirectory
  , doesFileExist
  , getTemporaryDirectory
  , removeDirectoryRecursive
  )
import System.FilePath ((</>))
import System.Posix.Process (getProcessID)
import TestSupport (SuiteBuilder, assertMutationInvariant, describe, it, shouldBe)

admissionHistorySuite :: SuiteBuilder ()
admissionHistorySuite = describe "admission history" $ do
  it "reports an empty, successfully read journal as never admitted" $ do
    classifyAdmission (JournalRead []) `shouldBe` NeverAdmitted
    classifyAdmission (JournalMissing False) `shouldBe` NeverAdmitted
    noChangeAllowed NeverAdmitted `shouldBe` True

  it "never recodes an unobservable journal as absence or never admitted" $ do
    classifyAdmission (JournalUnobservable "storage refused the read")
      `shouldBe` RecoveryRequired (RecoveryJournalUnobservable "storage refused the read")
    noChangeAllowed (classifyAdmission (JournalUnobservable "x")) `shouldBe` False
    mutationAllowed (classifyAdmission (JournalUnobservable "x")) `shouldBe` False

  it "never relabels missing existing history as fresh" $ do
    classifyAdmission (JournalMissing True) `shouldBe` RecoveryRequired RecoveryHistoryMissing
    noChangeAllowed (classifyAdmission (JournalMissing True)) `shouldBe` False

  it "blocks a no-change answer while a durable operation is unresolved" $ do
    let observed = JournalRead [("op-1", OperationSettled), ("op-2", OperationUnresolved)]
    classifyAdmission observed `shouldBe` AdmittedPending ["op-2"]
    noChangeAllowed (classifyAdmission observed) `shouldBe` False
    mutationAllowed (classifyAdmission observed) `shouldBe` False

  it "allows no-change once every recorded operation has settled" $ do
    let observed = JournalRead [("op-1", OperationSettled)]
    classifyAdmission observed `shouldBe` AdmittedSettled
    noChangeAllowed (classifyAdmission observed) `shouldBe` True

  it "never recodes an unobservable journal as never admitted for the mutation catalog" $
    assertMutationInvariant
      "lifecycle.unknown_requires_recovery"
      ( classifyAdmission (JournalUnobservable "storage refused the read")
          == RecoveryRequired (RecoveryJournalUnobservable "storage refused the read")
          && not (noChangeAllowed (classifyAdmission (JournalUnobservable "x")))
      )

  it "never relabels missing existing history as never admitted for the mutation catalog" $
    assertMutationInvariant
      "lifecycle.missing_history_is_not_fresh"
      ( classifyAdmission (JournalMissing True) == RecoveryRequired RecoveryHistoryMissing
          && classifyAdmission (JournalMissing False) == NeverAdmitted
      )

  it "blocks a no-change answer while an intent is unresolved for the mutation catalog" $
    assertMutationInvariant
      "lifecycle.pending_intent_blocks_noop"
      ( not (noChangeAllowed (classifyAdmission (JournalRead [("op-1", OperationUnresolved)])))
          && noChangeAllowed (classifyAdmission (JournalRead [("op-1", OperationSettled)]))
      )

  it "projects the Authority's real submission ledger into the admission verdict" $ do
    let digest = RequestDigest "d"
        ledgerOf clients = (emptySubmissionLedger 8) {submissionClients = Map.fromList clients}
        client name floorValue records =
          ( ClientId name
          , ClientSubmissions
              (ClientSequence floorValue)
              (Map.fromList [(ClientSequence n, r) | (n, r) <- records])
          )
        verdict = classifyAdmission . ledgerJournalObservation
    -- no client at all: positive empty history
    verdict (emptySubmissionLedger 8) `shouldBe` NeverAdmitted
    -- an in-flight submission is an unresolved intent
    verdict (ledgerOf [client "op" 0 [(1, SubmissionInFlight digest)]])
      `shouldBe` AdmittedPending ["op:1"]
    -- a settled tombstone is settled history, never fresh
    verdict (ledgerOf [client "op" 0 [(1, SubmissionSettled digest OperationCompletedOutcome)]])
      `shouldBe` AdmittedSettled
    -- a compaction floor above zero proves history even with no record left
    verdict (ledgerOf [client "op" 3 []]) `shouldBe` AdmittedSettled
    -- one unresolved record among settled ones blocks a no-change answer
    noChangeAllowed
      ( verdict
          ( ledgerOf
              [ client "a" 0 [(1, SubmissionSettled digest OperationCompletedOutcome)]
              , client "b" 0 [(1, SubmissionInFlight digest)]
              ]
          )
      )
      `shouldBe` False

  it
    "writes the journal mirror before the commit and refuses the commit when the mirror cannot be written"
    $ do
      aggregate <- either (fail . show) pure (initialCleanInstallAuthority 4 8)
      temporary <- getTemporaryDirectory
      processId <- getProcessID
      let directory = temporary </> ("admission-mirror-" ++ show processId)
          missing = directory </> "no-such-directory"
      bracket (createDirectory directory) (const (removeDirectoryRecursive directory)) $ \() -> do
        calls <- newIORef ([] :: [String])
        let base =
              AuthorityAdmissionRepository
                { readAuthorityAdmission = pure (Right (AuthorityAdmissionSnapshot () aggregate))
                , compareAndSwapAuthorityAdmission = \() _ -> do
                    mirrorPresent <- doesFileExist (directory </> "admission.json")
                    modifyIORef' calls (++ [if mirrorPresent then "commit-after-mirror" else "commit-without-mirror"])
                    pure (Right ())
                }
        committed <-
          compareAndSwapAuthorityAdmission (mirrorAdmissionRepository directory base) () aggregate
        committed `shouldBe` Right ()
        readIORef calls >>= (`shouldBe` ["commit-after-mirror"])
        refused <- compareAndSwapAuthorityAdmission (mirrorAdmissionRepository missing base) () aggregate
        either (const True) (const False) refused `shouldBe` True
        readIORef calls >>= (`shouldBe` ["commit-after-mirror"])

  it "never reads an uninitialized or inconsistent journal mirror as never admitted" $ do
    aggregate <- either (fail . show) pure (initialCleanInstallAuthority 4 8)
    temporary <- getTemporaryDirectory
    processId <- getProcessID
    let directory = temporary </> ("admission-mirror-read-" ++ show processId)
        base =
          AuthorityAdmissionRepository
            { readAuthorityAdmission = pure (Right (AuthorityAdmissionSnapshot () aggregate))
            , compareAndSwapAuthorityAdmission = \() _ -> pure (Right ())
            }
    bracket (createDirectory directory) (const (removeDirectoryRecursive directory)) $ \() -> do
      -- no genesis: the journal was never initialized, which is not "nothing admitted"
      before <- observeJournalMirror directory
      classifyAdmission before
        `shouldBe` RecoveryRequired (RecoveryJournalUnobservable "the journal was never initialized by this Authority")
      -- initialized over an empty committed ledger: positive empty history
      initialised <- initialiseJournalMirror directory base
      initialised `shouldBe` Right ()
      after <- observeJournalMirror directory
      classifyAdmission after `shouldBe` NeverAdmitted
      -- a corrupt mirror is unobservable, never empty
      writeFile (directory </> "admission.json") "not json"
      corrupt <- observeJournalMirror directory
      noChangeAllowed (classifyAdmission corrupt) `shouldBe` False

  it "admits only the reader ServiceAccount of this namespace for this audience to the journal read" $ do
    let userOf name =
          Just (BrokerTokenReviewUser ("system:serviceaccount:lifecycle-authority:" <> name) "uid-1" [])
        reviewed authenticated audiences user =
          BrokerTokenReviewResult authenticated audiences user Nothing
        decide = decideJournalReadAccess "lifecycle-authority"
    decide (reviewed True [journalReadAudience] (userOf "prodbox-authority-reader")) `shouldBe` Right ()
    -- an unauthenticated token is unauthorized
    decide (reviewed False [] Nothing) `shouldBe` Left ReplyUnauthorized
    -- another ServiceAccount, even for the right audience, is forbidden
    decide (reviewed True [journalReadAudience] (userOf "default")) `shouldBe` Left ReplyForbidden
    decide (reviewed True [journalReadAudience] (userOf "prodbox-lifecycle-authority"))
      `shouldBe` Left ReplyForbidden
    -- the Broker's audience (or any other) is not this capability's
    decide (reviewed True ["prodbox-bootstrap-broker"] (userOf "prodbox-authority-reader"))
      `shouldBe` Left ReplyForbidden
    -- the reader of another namespace is forbidden
    decideJournalReadAccess
      "other"
      (reviewed True [journalReadAudience] (userOf "prodbox-authority-reader"))
      `shouldBe` Left ReplyForbidden
    -- one bearer token, case-insensitive header, and none or two means none
    bearerTokenOf "GET / HTTP/1.0\r\nAuthorization: Bearer abc\r\n\r\n" `shouldBe` Just "abc"
    bearerTokenOf "GET / HTTP/1.0\r\nauthorization: bearer abc\r\n\r\n" `shouldBe` Just "abc"
    bearerTokenOf "GET / HTTP/1.0\r\n\r\n" `shouldBe` Nothing
    bearerTokenOf "GET / HTTP/1.0\r\nAuthorization: Bearer a\r\nAuthorization: Bearer b\r\n\r\n"
      `shouldBe` Nothing
    verdictCode (RecoveryRequired RecoveryHistoryMissing) `shouldBe` "recovery-required"

  it
    "never reads a journal mirror without its genesis record as never admitted for the mutation catalog" $ do
    temporary <- getTemporaryDirectory
    processId <- getProcessID
    let directory = temporary </> ("admission-mirror-genesis-" ++ show processId)
    bracket (createDirectory directory) (const (removeDirectoryRecursive directory)) $ \() -> do
      observed <- observeJournalMirror directory
      assertMutationInvariant
        "lifecycle.uninitialized_mirror_is_not_fresh"
        ( classifyAdmission observed /= NeverAdmitted
            && not (noChangeAllowed (classifyAdmission observed))
        )
