{-# LANGUAGE OverloadedStrings #-}

module AdmissionHistoryTests (admissionHistorySuite) where

import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (bracket)
import Data.Aeson ((.=))
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Prodbox.Bootstrap.Broker.TokenReview
  ( BrokerTokenReviewResult (..)
  , BrokerTokenReviewUser (..)
  )
import Prodbox.Config.BootstrapProjection
  ( BootstrapDraft (..)
  , BootstrapProjection
  , bootstrapScope
  , decodeOptionalBootstrapSource
  , renderBootstrapDraft
  )
import Prodbox.Config.DeploymentScope
  ( DeploymentEnvironment (Test)
  , FreshScopeResult (FreshScopePrepared)
  , deploymentScope
  , prepareFreshScope
  , scopeRoot
  )
import Prodbox.Control.AuthorityDeploy
  ( RetainedAuthorityJournal (RetainedAuthorityJournalBound)
  , observeRetainedAuthorityJournal
  )
import Prodbox.Control.AuthorityJournalClient
  ( AdmissionSource (..)
  , currentAdmission
  , decodeAuthorityAdmission
  )
import Prodbox.ControlPlane.AdmissionJournalMirror
  ( JournalInitialization (..)
  , JournalRemovalFence (..)
  , initialiseJournalMirror
  , initialiseRetainedJournalMirror
  , mirrorAdmissionRepository
  , mirrorRetainedAdmissionRepository
  , observeJournalInitialization
  , observeJournalMirror
  , observeJournalRemovalFence
  , observeRetainedJournalMirror
  , recordJournalRemovalFence
  , renderMirror
  , withJournalCustodyLease
  )
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (..)
  , AuthorityAdmissionSnapshot (..)
  )
import Prodbox.ControlPlane.AuthorityJournalReadServer
  ( bearerTokenOf
  , decideJournalReadAccess
  , journalReadAudience
  , renderVerdictAnswer
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
  , removeDirectory
  , removeDirectoryRecursive
  , removeFile
  , renameFile
  )
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (createSymbolicLink, deviceID, fileID, getSymbolicLinkStatus, setFileMode)
import System.Posix.Process (getProcessID)
import TestSupport (SuiteBuilder, assertMutationInvariant, describe, it, shouldBe)

admissionHistorySuite :: SuiteBuilder ()
admissionHistorySuite = describe "admission history" $ do
  it
    "refuses a local fresh verdict when retained Authority state exists but its service is unavailable"
    $ withAdmissionScope
    $ \bootstrap directory -> do
      createDirectory (directory </> "authority-journal")
      (verdict, source) <- currentAdmission bootstrap
      noChangeAllowed verdict `shouldBe` False
      source `shouldBe` FromAuthority "not read"

  it "does not treat a dangling retained Authority path as fresh" $
    withAdmissionScope $ \bootstrap directory -> do
      createSymbolicLink "missing" (directory </> "authority-journal")
      (verdict, source) <- currentAdmission bootstrap
      noChangeAllowed verdict `shouldBe` False
      source `shouldBe` FromAuthority "not read"

  it "requires recovery after loss of a retained journal directory with a surviving binding" $
    withAdmissionScope $ \bootstrap directory -> do
      let journal = directory </> "authority-journal"
          custody = directory </> "authority-journal-custody"
          intent =
            Aeson.object
              [ "schema_version" .= (2 :: Int)
              , "kind_name" .= ("prodbox-t-admission" :: Text.Text)
              , "root_generation" .= Text.replicate 32 "b"
              ]
          privateRecord name value = do
            let path = directory </> name
            LazyByteString.writeFile path (Aeson.encode value)
            setFileMode path 0o600
          directoryIdentity path = do
            observed <- getSymbolicLinkStatus path
            pure (toInteger (deviceID observed), toInteger (fileID observed))
      mapM_ (\path -> createDirectory path >> setFileMode path 0o700) [journal, custody]
      journalId <- directoryIdentity journal
      custodyId <- directoryIdentity custody
      privateRecord "authority-journal-intent.json" intent
      privateRecord
        "authority-journal-binding.json"
        (Aeson.object ["intent" .= intent, "journal" .= journalId, "custody" .= custodyId])
      observeRetainedAuthorityJournal bootstrap >>= (`shouldBe` RetainedAuthorityJournalBound)
      removeDirectory journal
      (verdict, source) <- currentAdmission bootstrap
      noChangeAllowed verdict `shouldBe` False
      source `shouldBe` FromAuthority "not read"

  it "refuses a local fresh verdict when the control cluster cannot be observed" $
    withAdmissionScope $ \bootstrap directory -> do
      createDirectory (directory </> "control")
      writeFile (directory </> "control" </> "kubeconfig") "invalid kubeconfig"
      (verdict, source) <- currentAdmission bootstrap
      noChangeAllowed verdict `shouldBe` False
      source `shouldBe` FromAuthority "not read"

  it "accepts an admission answer only from the selected cluster" $ do
    let observedAt = "2026-11-25T21:10:00Z"
        reply = renderVerdictAnswer "prodbox-t-first" observedAt NeverAdmitted
    decodeAuthorityAdmission "prodbox-t-first" reply `shouldBe` Right (NeverAdmitted, observedAt)
    decodeAuthorityAdmission "prodbox-t-other" reply
      `shouldBe` Left "the journal answer belongs to a different control cluster"
    decodeAuthorityAdmission
      "prodbox-t-first"
      "{\"verdict\":\"never-admitted\",\"detail\":\"\",\"observed_at\":\"now\"}"
      `shouldBe` Left "the Authority's answer lacks required journal metadata"

  it "requires recovery when the journal disappears after its genesis reservation was used" $
    withSystemTempDirectory "prodbox-journal-custody" $ \root -> do
      aggregate <- either (fail . show) pure (initialCleanInstallAuthority 4 8)
      let directory = root </> "journal"
          custody = root </> "custody"
          repository =
            AuthorityAdmissionRepository
              { readAuthorityAdmission = pure (Right (AuthorityAdmissionSnapshot () aggregate))
              , compareAndSwapAuthorityAdmission = \() _ -> pure (Right ())
              }
      createDirectory directory
      createDirectory custody
      setFileMode custody 0o700
      initialiseRetainedJournalMirror directory custody repository >>= (`shouldBe` Right ())
      initialiseRetainedJournalMirror directory custody repository >>= (`shouldBe` Right ())
      observeRetainedJournalMirror directory custody >>= (`shouldBe` JournalRead [])
      let mirror = directory </> "admission.json"
      original <- ByteString.readFile mirror
      let reversed = "{\"schema_version\":1,\"operations\":[]}"
          substituted = if original == reversed then "{\"operations\":[],\"schema_version\":1}" else reversed
      ByteString.length substituted `shouldBe` ByteString.length original
      ByteString.writeFile mirror substituted
      changed <- observeRetainedJournalMirror directory custody
      assertMutationInvariant
        "lifecycle.modified_mirror_requires_recovery"
        (not (noChangeAllowed (classifyAdmission changed)))
      ByteString.writeFile mirror original
      observeRetainedJournalMirror directory custody >>= (`shouldBe` JournalRead [])
      removeFile (directory </> "genesis.json")
      removeFile (directory </> "admission.json")
      initialiseRetainedJournalMirror directory custody repository
        >>= (`shouldBe` Left "the retained journal genesis reservation is missing or already used")
      required <- observeRetainedJournalMirror directory custody
      noChangeAllowed (classifyAdmission required) `shouldBe` False
      doesFileExist (directory </> "genesis.json") >>= (`shouldBe` False)
      doesFileExist (custody </> "genesis-attempt") >>= (`shouldBe` True)

  it "excludes admission while a control removal is reserved and after its issuer exits" $
    withSystemTempDirectory "prodbox-journal-removal" $ \root -> do
      aggregate <- either (fail . show) pure (initialCleanInstallAuthority 4 8)
      committed <- newIORef (0 :: Int)
      let directory = root </> "journal"
          custody = root </> "custody"
          removal = "selected-generation-and-operation"
          repository =
            AuthorityAdmissionRepository
              { readAuthorityAdmission = pure (Right (AuthorityAdmissionSnapshot () aggregate))
              , compareAndSwapAuthorityAdmission = \() _ -> modifyIORef' committed (+ 1) >> pure (Right ())
              }
          mirrored = mirrorRetainedAdmissionRepository directory custody repository
      createDirectory directory
      createDirectory custody
      setFileMode custody 0o700
      initialiseRetainedJournalMirror directory custody repository >>= (`shouldBe` Right ())
      accepted <- withJournalCustodyLease custody $ \held stable -> do
        stable >>= (`shouldBe` True)
        observeJournalRemovalFence held removal >>= (`shouldBe` JournalRemovalFenceAbsent)
        compareAndSwapAuthorityAdmission mirrored () aggregate
          >>= (`shouldBe` Left "retained-journal-lease-unavailable")
        recordJournalRemovalFence held removal
      accepted `shouldBe` Just True
      compareAndSwapAuthorityAdmission mirrored () aggregate
        >>= (`shouldBe` Left "retained-journal-or-admission-unavailable")
      readIORef committed >>= (`shouldBe` 0)
      reopened <- withJournalCustodyLease custody $ \held _ -> observeJournalRemovalFence held removal
      reopened `shouldBe` Just JournalRemovalFenceMatches
      foreignFence <- withJournalCustodyLease custody $ \held _ -> observeJournalRemovalFence held "different-operation"
      foreignFence `shouldBe` Just JournalRemovalFenceUnconfirmed

  it "settles an interrupted Authority commit only after exact aggregate read-back" $
    withSystemTempDirectory "prodbox-armed-authority-commit" $ \root -> do
      predecessor <- either (fail . show) pure (initialCleanInstallAuthority 4 8)
      candidate <- either (fail . show) pure (initialCleanInstallAuthority 4 9)
      committed <- newIORef (AuthorityAdmissionSnapshot (1 :: Int) predecessor)
      available <- newIORef True
      admissions <- newIORef (0 :: Int)
      let directory = root </> "journal"
          custody = root </> "custody"
          armed = custody </> "admission-commit.cbor"
          repository =
            AuthorityAdmissionRepository
              { readAuthorityAdmission = do
                  readable <- readIORef available
                  if readable then Right <$> readIORef committed else pure (Left "read unavailable")
              , compareAndSwapAuthorityAdmission = \_ _ -> do
                  modifyIORef' admissions (+ 1)
                  writeIORef available False
                  pure (Left "lost commit reply")
              }
          mirrored = mirrorRetainedAdmissionRepository directory custody repository
          restart = initialiseRetainedJournalMirror directory custody repository
      createDirectory directory
      createDirectory custody
      setFileMode custody 0o700
      restart >>= (`shouldBe` Right ())
      compareAndSwapAuthorityAdmission mirrored 1 candidate
        >>= ( `shouldBe`
                Left "lost commit reply; the exact armed Authority commit is unconfirmed; recovery is required"
            )
      during <- observeRetainedJournalMirror directory custody
      noChangeAllowed (classifyAdmission during) `shouldBe` False
      writeIORef available True
      -- These states have the same admission projection. The predecessor
      -- observation cannot acknowledge the possible delayed commit.
      restart
        >>= (`shouldBe` Left "the exact armed Authority commit is unconfirmed; recovery is required")
      doesFileExist armed >>= (`shouldBe` True)
      compareAndSwapAuthorityAdmission mirrored 1 candidate
        >>= (`shouldBe` Left "retained-journal-or-admission-unavailable")
      writeIORef committed (AuthorityAdmissionSnapshot 2 candidate)
      restart >>= (`shouldBe` Right ())
      doesFileExist armed >>= (`shouldBe` False)
      readAuthorityAdmission mirrored >>= (`shouldBe` Right (AuthorityAdmissionSnapshot 2 candidate))
      compareAndSwapAuthorityAdmission mirrored 2 candidate >>= (`shouldBe` Right ())
      readIORef admissions >>= (`shouldBe` 1)

  it "resumes a native journal initialization only at its original mount and Authority state" $
    withSystemTempDirectory "prodbox-armed-journal-initialization" $ \root -> do
      original <- either (fail . show) pure (initialCleanInstallAuthority 4 8)
      substitute <- either (fail . show) pure (initialCleanInstallAuthority 4 9)
      readAttempts <- newIORef (0 :: Int)
      state <- newIORef original
      let directory = root </> "journal"
          custody = root </> "custody"
          otherJournal = root </> "other-journal"
          arm = custody </> "genesis-operation.cbor"
          repository =
            AuthorityAdmissionRepository
              { readAuthorityAdmission = do
                  modifyIORef' readAttempts (+ 1)
                  attempt <- readIORef readAttempts
                  if attempt == 2
                    then pure (Left "process interrupted after arming")
                    else Right . AuthorityAdmissionSnapshot () <$> readIORef state
              , compareAndSwapAuthorityAdmission = \() _ -> pure (Left "genesis must not submit an admission")
              }
          restart = initialiseRetainedJournalMirror directory custody repository
      mapM_ createDirectory [directory, custody, otherJournal]
      setFileMode custody 0o700
      restart
        >>= (`shouldBe` Left "the Authority journal initialization no longer matches its backing admission")
      originalRecord <- ByteString.readFile arm
      observed <- observeJournalInitialization directory custody
      case observed of
        JournalInitializationArmed operation -> do
          observeRetainedJournalMirror directory custody
            >>= (`shouldBe` JournalRead [(operation, OperationUnresolved)])
          observeJournalInitialization otherJournal custody >>= (`shouldBe` JournalInitializationUnconfirmed)
          writeIORef state substitute
          restart
            >>= (`shouldBe` Left "the Authority journal initialization no longer matches its backing admission")
          ByteString.readFile arm >>= (`shouldBe` originalRecord)
          writeIORef state original
          restart >>= (`shouldBe` Right ())
          restart >>= (`shouldBe` Right ())
          ByteString.readFile arm >>= (`shouldBe` originalRecord)
          observeJournalInitialization directory custody
            >>= (`shouldBe` JournalInitializationComplete operation)
          observeRetainedJournalMirror directory custody >>= (`shouldBe` JournalRead [])
        _ -> fail ("expected the original armed journal initialization: " ++ show observed)

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
      let genesis = directory </> "genesis.json"
          retainedGenesis = directory </> "retained-genesis.json"
      renameFile genesis retainedGenesis
      writeFile genesis "corrupt"
      rejected <- observeJournalMirror directory
      noChangeAllowed (classifyAdmission rejected) `shouldBe` False
      initialiseJournalMirror directory base
        >>= (`shouldBe` Left "the retained journal genesis is invalid or unobservable; recovery is required")
      readFile genesis >>= (`shouldBe` "corrupt")
      removeFile genesis
      createSymbolicLink retainedGenesis genesis
      linked <- observeJournalMirror directory
      noChangeAllowed (classifyAdmission linked) `shouldBe` False
      removeFile genesis
      renameFile retainedGenesis genesis
      -- a corrupt mirror is unobservable, never empty
      writeFile (directory </> "admission.json") "not json"
      corrupt <- observeJournalMirror directory
      noChangeAllowed (classifyAdmission corrupt) `shouldBe` False

  it "preserves an interrupted write-ahead intent across initialization" $ do
    aggregate <- either (fail . show) pure (initialCleanInstallAuthority 4 8)
    temporary <- getTemporaryDirectory
    processId <- getProcessID
    let directory = temporary </> ("admission-mirror-restart-" ++ show processId)
        base =
          AuthorityAdmissionRepository
            { readAuthorityAdmission = pure (Right (AuthorityAdmissionSnapshot () aggregate))
            , compareAndSwapAuthorityAdmission = \() _ -> pure (Right ())
            }
        pending = [("client:1", OperationUnresolved)]
    bracket (createDirectory directory) (const (removeDirectoryRecursive directory)) $ \() -> do
      initialiseJournalMirror directory base >>= (`shouldBe` Right ())
      ByteString.writeFile (directory </> "admission.json") (renderMirror pending)
      restarted <- initialiseJournalMirror directory base
      either (const True) (const False) restarted `shouldBe` True
      observeJournalMirror directory >>= (`shouldBe` JournalRead pending)

  it "refuses a competing journal write and a read while a commit is in progress" $ do
    aggregate <- either (fail . show) pure (initialCleanInstallAuthority 4 8)
    temporary <- getTemporaryDirectory
    processId <- getProcessID
    let directory = temporary </> ("admission-mirror-concurrent-" ++ show processId)
    bracket (createDirectory directory) (const (removeDirectoryRecursive directory)) $ \() -> do
      entered <- newEmptyMVar
      release <- newEmptyMVar
      completed <- newEmptyMVar
      let base =
            AuthorityAdmissionRepository
              { readAuthorityAdmission = pure (Right (AuthorityAdmissionSnapshot () aggregate))
              , compareAndSwapAuthorityAdmission = \() _ -> do
                  putMVar entered ()
                  takeMVar release
                  pure (Right ())
              }
          wrapped = mirrorAdmissionRepository directory base
      initialiseJournalMirror directory base >>= (`shouldBe` Right ())
      _ <- forkIO (compareAndSwapAuthorityAdmission wrapped () aggregate >>= putMVar completed)
      takeMVar entered
      competing <- compareAndSwapAuthorityAdmission wrapped () aggregate
      either (const True) (const False) competing `shouldBe` True
      during <- observeJournalMirror directory
      noChangeAllowed (classifyAdmission during) `shouldBe` False
      putMVar release ()
      takeMVar completed >>= (`shouldBe` Right ())
      observeJournalMirror directory >>= (`shouldBe` JournalRead [])

  it "retains the write guard after an ambiguous commit failure and restart" $ do
    aggregate <- either (fail . show) pure (initialCleanInstallAuthority 4 8)
    temporary <- getTemporaryDirectory
    processId <- getProcessID
    let directory = temporary </> ("admission-mirror-ambiguous-" ++ show processId)
        base =
          AuthorityAdmissionRepository
            { readAuthorityAdmission = pure (Right (AuthorityAdmissionSnapshot () aggregate))
            , compareAndSwapAuthorityAdmission = \() _ -> pure (Left "lost reply")
            }
    bracket (createDirectory directory) (const (removeDirectoryRecursive directory)) $ \() -> do
      initialiseJournalMirror directory base >>= (`shouldBe` Right ())
      failed <- compareAndSwapAuthorityAdmission (mirrorAdmissionRepository directory base) () aggregate
      either (const True) (const False) failed `shouldBe` True
      observed <- observeJournalMirror directory
      noChangeAllowed (classifyAdmission observed) `shouldBe` False
      restarted <- initialiseJournalMirror directory base
      either (const True) (const False) restarted `shouldBe` True

  it "does not treat a dangling guard symlink as an absent guard" $ do
    aggregate <- either (fail . show) pure (initialCleanInstallAuthority 4 8)
    temporary <- getTemporaryDirectory
    processId <- getProcessID
    let directory = temporary </> ("admission-mirror-guard-link-" ++ show processId)
        base =
          AuthorityAdmissionRepository
            { readAuthorityAdmission = pure (Right (AuthorityAdmissionSnapshot () aggregate))
            , compareAndSwapAuthorityAdmission = \() _ -> pure (Right ())
            }
    bracket (createDirectory directory) (const (removeDirectoryRecursive directory)) $ \() -> do
      initialiseJournalMirror directory base >>= (`shouldBe` Right ())
      createSymbolicLink "missing" (directory </> "admission-write-in-progress")
      observed <- observeJournalMirror directory
      noChangeAllowed (classifyAdmission observed) `shouldBe` False
      restarted <- initialiseJournalMirror directory base
      either (const True) (const False) restarted `shouldBe` True

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
    "never reads a journal mirror without its genesis record as never admitted for the mutation catalog"
    $ do
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

withAdmissionScope :: (BootstrapProjection -> FilePath -> IO ()) -> IO ()
withAdmissionScope action = withSystemTempDirectory "prodbox-admission-test" $ \anchor -> do
  let draft =
        BootstrapDraft
          { draftProjectAnchor = Text.pack anchor
          , draftRuntimeSocket = "/var/run/docker.sock"
          , draftEnvironment = "test"
          , draftDeploymentId = "admission"
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
          , draftNodeMaximumBytes = 1048576
          , draftKindPath = "artifacts/kind"
          , draftKindDigest = digest
          , draftKindMaximumBytes = 1048576
          }
      digest = "sha256:" <> Text.replicate 64 "a"
  scope <- either (fail . show) pure (deploymentScope anchor Test "admission" 26443)
  prepareFreshScope scope (replicate 32 'b') >>= (`shouldBe` FreshScopePrepared)
  decoded <- decodeOptionalBootstrapSource (anchor </> "selected.dhall") (renderBootstrapDraft draft)
  case decoded of
    Right (Just bootstrap) -> action bootstrap (scopeRoot (bootstrapScope bootstrap))
    other -> fail (show other)
