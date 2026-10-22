{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module HostCleanupHistoryReconcile (hostCleanupHistoryReconcileSuite) where

import Control.Monad (forM_)
import Data.ByteString qualified as ByteString
import Data.Either (isLeft)
import Data.IORef (modifyIORef', readIORef)
import Data.Map.Strict qualified as Map
import HistoryAuthorityFixture
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthorityControlClient
  ( observeProviderBootstrapPredecessorWithTransport
  )
import Prodbox.ControlPlane.CleanupRunEndpoint (CleanupRunDescriptorCommand (..))
import Prodbox.ControlPlane.CompletedProviderPredecessorRegression
  ( fixedCompletedProviderPredecessorRegression
  )
import Prodbox.Lifecycle.Authority.ClientRegistry (mkClientSubmissionKey)
import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch
import Prodbox.Lifecycle.CleanupRun
import Prodbox.Lifecycle.HostCleanupCompletion
import Prodbox.Lifecycle.HostCleanupCompositionRoot
  ( HostCleanupCompositionError (..)
  , reconcileHostCleanupBootstrapPredecessor
  )
import Prodbox.Lifecycle.HostCleanupHistoryReconcile
import Prodbox.Lifecycle.HostCleanupIntent
import Prodbox.Lifecycle.Teardown.CleanupProgramDescriptor
import Prodbox.Lifecycle.Teardown.Graph
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation (terminalAuditEvidenceScopeDigest)
import Prodbox.Lifecycle.Teardown.ScopeCodec (scopeForCascadeTerminalAudit)
import System.Directory (copyFile, createDirectoryIfMissing, removeFile)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import TestSupport

hostCleanupHistoryReconcileSuite :: SuiteBuilder ()
hostCleanupHistoryReconcileSuite = describe "Sprint 6.5 authenticated next-bootstrap history import" $ do
  it "requires independently observed live or compacted predecessor completion before succession" $
    withHistory $ \store history descriptor prefix -> do
      authority <- newHistoryAuthority descriptor prefix Nothing
      _ <-
        reconcileHistoricalHostCleanup (historyAuthorityClient authority) store (expiredNow prefix) history
          >>= expectRight
      terminal <- readIORef (historyAuthorityRun authority)
      assertions <- fixedCompletedProviderPredecessorRegression descriptor terminal >>= expectRight
      assertions `shouldSatisfy` (not . null)
      forM_ assertions $ \(name, passed) ->
        if passed then pure () else expectationFailure (show name)

  forM_ [CompactHistory, CompactHistoryOnClosingRead] $ \fault ->
    it ("imports independently observed compacted terminal history without mutation: " <> show fault) $
      withHistory $ \store history descriptor prefix -> do
        let terminal = prefix {cleanupRunNodeStates = cleanupReportNodeStates (historicalHostCleanupReport history)}
        authority <- newHistoryAuthority descriptor terminal (Just fault)
        result <-
          reconcileHistoricalHostCleanup (historyAuthorityClient authority) store (expiredNow prefix) history
        fmap reconciledHostCleanupReport result `shouldBe` Right (historicalHostCleanupReport history)
        observeHostCleanupIntent store `shouldReturn` Right Nothing
        commands <- readIORef (historyAuthorityCommands authority)
        [command | command@CleanupRunDescriptorClaim {} <- commands] `shouldBe` []
        [command | command@CleanupRunDescriptorBeginNode {} <- commands] `shouldBe` []
        [command | command@CleanupRunDescriptorCompleteNode {} <- commands] `shouldBe` []
        length [command | command@CleanupRunDescriptorObserveCompletion {} <- commands]
          `shouldBe` if fault == CompactHistory then 2 else 1
  forM_
    [ RefuseCompactedHistoryReport
    , RefuseCompactedHistoryClosingReport
    , ChangedCompactedHistoryReport
    , ForeignCompactedHistoryDescriptor
    ]
    $ \fault ->
      it
        ( "preserves the sealed intent when compacted history cannot be independently confirmed: "
            <> show fault
        )
        $ withHistory
        $ \store history descriptor prefix -> do
          let terminal = prefix {cleanupRunNodeStates = cleanupReportNodeStates (historicalHostCleanupReport history)}
          authority <- newHistoryAuthority descriptor terminal (Just fault)
          result <-
            reconcileHistoricalHostCleanup (historyAuthorityClient authority) store (expiredNow prefix) history
          result `shouldSatisfy` isLeft
          observeHostCleanupIntent store `shouldReturn` Right (Just (historicalHostCleanupIntent history))

  it
    "locates archived history from authenticated predecessor metadata without repeating completed nodes"
    $ withHistory
    $ \store history descriptor prefix -> do
      let intent = historicalHostCleanupIntent history
          scopeDigest =
            terminalAuditEvidenceScopeDigest
              (scopeForCascadeTerminalAudit (hostCleanupObservationEvidenceScope (hostCleanupScope intent)))
      binding <-
        expectRight $
          mkCascadeAuditFreezeBinding
            (hostCleanupRunId intent)
            (cleanupProgramDescriptorDigest descriptor)
            (hostCleanupGraphDigest intent)
            scopeDigest
            (mustRight (mkCleanupNodeId "history/audit"))
            (mustRight (mkCleanupOperationId "history/audit"))
            (mustRight (mkCleanupAttemptId "history/audit"))
            [mustRight (mkClientSubmissionKey "history/audit")]
      forM_ [ProviderBootstrapFrozen, ProviderBootstrapRecorded] $ \phase -> do
        unfinished <- newHistoryAuthorityWithPredecessor descriptor prefix Nothing (Just (binding, phase))
        refused <-
          reconcileHostCleanupBootstrapPredecessor
            "/unavailable-bootstrap-root"
            (historyAuthorityTransport unfinished)
            (expiredNow prefix)
        case refused of
          Left (HostCleanupCompositionPredecessorNeedsRecovery predecessor) ->
            providerBootstrapPredecessorPhase predecessor `shouldBe` phase
          _ -> expectationFailure "unfinished audit attempted historical journals or fresh admission"
        commands <- readIORef (historyAuthorityCommands unfinished)
        [command | command@CleanupRunDescriptorBeginNode {} <- commands] `shouldBe` []
      authority <-
        newHistoryAuthorityWithPredecessor
          descriptor
          prefix
          Nothing
          (Just (binding, ProviderBootstrapRevoked))
      first <-
        reconcileHistoricalHostCleanup (historyAuthorityClient authority) store (expiredNow prefix) history
      fmap reconciledHostCleanupReport first `shouldBe` Right (historicalHostCleanupReport history)
      commandsBefore <- readIORef (historyAuthorityCommands authority)
      metadata <-
        observeProviderBootstrapPredecessorWithTransport (historyAuthorityTransport authority)
          >>= expectRight
      case metadata of
        Nothing -> expectationFailure "the Authority lost its predecessor reservation"
        Just predecessor -> do
          providerBootstrapPredecessorGraphDigest predecessor `shouldBe` hostCleanupGraphDigest intent
          providerBootstrapPredecessorScopeDigest predecessor `shouldBe` scopeDigest
          journal <- expectRight (mkHostCleanupCompletionJournal (hostCleanupIntentRetainedRoot store))
          restored <-
            observeHistoricalHostCleanupCompletionForRun
              store
              journal
              (providerBootstrapPredecessorRunId predecessor)
              >>= expectRight
          historicalHostCleanupIntentRetired restored `shouldBe` True
          second <-
            reconcileHistoricalHostCleanup
              (historyAuthorityClient authority)
              store
              (expiredNow prefix + 1)
              restored
          fmap reconciledHostCleanupReport second `shouldBe` Right (historicalHostCleanupReport history)
          observeHostCleanupIntent store `shouldReturn` Right Nothing
          commandsAfter <- readIORef (historyAuthorityCommands authority)
          let begins commands = [command | command@CleanupRunDescriptorBeginNode {} <- commands]
          begins commandsAfter `shouldBe` begins commandsBefore

  it
    "imports only the local tail, preserves historical attempts across a new fence, then retires the exact intent"
    $ withHistory
    $ \store history descriptor prefix -> do
      authority <- newHistoryAuthority descriptor prefix Nothing
      result <-
        reconcileHistoricalHostCleanup (historyAuthorityClient authority) store (expiredNow prefix) history
      fmap reconciledHostCleanupReport result `shouldBe` Right (historicalHostCleanupReport history)
      observeHostCleanupIntent store `shouldReturn` Right Nothing
      final <- readIORef (historyAuthorityRun authority)
      cleanupLeaseFence (cleanupRunLease final)
        `shouldSatisfy` (> cleanupLeaseFence (cleanupRunLease prefix))
      compactCleanupRun final `shouldBe` Right (historicalHostCleanupReport history)
      commands <- readIORef (historyAuthorityCommands authority)
      length [() | CleanupRunDescriptorBeginNode {} <- commands] `shouldBe` 4
      length [() | CleanupRunDescriptorCompleteNode {} <- commands] `shouldBe` 4

  forM_ losses $ \fault ->
    it ("recovers the independently observed applied transition after " <> show fault) $
      withHistory $ \store history descriptor prefix -> do
        authority <- newHistoryAuthority descriptor prefix (Just fault)
        result <-
          reconcileHistoricalHostCleanup (historyAuthorityClient authority) store (expiredNow prefix) history
        fmap reconciledHostCleanupReport result `shouldBe` Right (historicalHostCleanupReport history)
        observeHostCleanupIntent store `shouldReturn` Right Nothing
        commands <- readIORef (historyAuthorityCommands authority)
        length [() | CleanupRunDescriptorBeginNode {} <- commands] `shouldBe` 4
        length [() | CleanupRunDescriptorCompleteNode {} <- commands] `shouldBe` 4

  it
    "preserves the completed local intent when the final Authority read is refused, and retries without repeating nodes"
    $ withHistory
    $ \store history descriptor prefix -> do
      authority <- newHistoryAuthority descriptor prefix (Just RefuseHistoryFinalRead)
      first <-
        reconcileHistoricalHostCleanup (historyAuthorityClient authority) store (expiredNow prefix) history
      first `shouldSatisfy` isLeft
      observeHostCleanupIntent store `shouldReturn` Right (Just (historicalHostCleanupIntent history))
      commandsBefore <- readIORef (historyAuthorityCommands authority)
      second <-
        reconcileHistoricalHostCleanup
          (historyAuthorityClient authority)
          store
          (expiredNow prefix + 1)
          history
      fmap reconciledHostCleanupReport second `shouldBe` Right (historicalHostCleanupReport history)
      observeHostCleanupIntent store `shouldReturn` Right Nothing
      commandsAfter <- readIORef (historyAuthorityCommands authority)
      let transitions commands =
            [command | command@CleanupRunDescriptorBeginNode {} <- commands]
              <> [command | command@CleanupRunDescriptorCompleteNode {} <- commands]
      transitions commandsAfter `shouldBe` transitions commandsBefore

  it
    "recovers retired history after restart without recreating an active intent or repeating Authority nodes"
    $ withHistory
    $ \store history descriptor prefix -> do
      authority <- newHistoryAuthority descriptor prefix Nothing
      first <-
        reconcileHistoricalHostCleanup (historyAuthorityClient authority) store (expiredNow prefix) history
      fmap reconciledHostCleanupReport first `shouldBe` Right (historicalHostCleanupReport history)
      commandsBefore <- readIORef (historyAuthorityCommands authority)
      journal <- expectRight (mkHostCleanupCompletionJournal (hostCleanupIntentRetainedRoot store))
      restored <-
        observeHistoricalHostCleanupCompletionForRun
          store
          journal
          (hostCleanupRunId (historicalHostCleanupIntent history))
          >>= expectRight
      historicalHostCleanupIntentRetired restored `shouldBe` True
      observeHostCleanupIntent store `shouldReturn` Right Nothing
      second <-
        reconcileHistoricalHostCleanup
          (historyAuthorityClient authority)
          store
          (expiredNow prefix + 1)
          restored
      fmap reconciledHostCleanupReport second `shouldBe` Right (historicalHostCleanupReport history)
      observeHostCleanupIntent store `shouldReturn` Right Nothing
      commandsAfter <- readIORef (historyAuthorityCommands authority)
      let transitions commands =
            [command | command@CleanupRunDescriptorBeginNode {} <- commands]
              <> [command | command@CleanupRunDescriptorCompleteNode {} <- commands]
      transitions commandsAfter `shouldBe` transitions commandsBefore

  forM_ [False, True] $ \corrupt ->
    it ("refuses an unobservable retirement archive after restart: corrupt=" <> show corrupt) $
      withHistory $ \store history descriptor prefix -> do
        authority <- newHistoryAuthority descriptor prefix Nothing
        first <-
          reconcileHistoricalHostCleanup (historyAuthorityClient authority) store (expiredNow prefix) history
        fmap reconciledHostCleanupReport first `shouldBe` Right (historicalHostCleanupReport history)
        archive <- expectRight (hostCleanupIntentRetiredPath store (historicalHostCleanupIntent history))
        if corrupt then ByteString.writeFile archive "corrupt archive" else removeFile archive
        journal <- expectRight (mkHostCleanupCompletionJournal (hostCleanupIntentRetainedRoot store))
        restored <-
          observeHistoricalHostCleanupCompletionForRun
            store
            journal
            (hostCleanupRunId (historicalHostCleanupIntent history))
        case (corrupt, restored) of
          (False, Left HistoricalHostCleanupRetirementMissing) -> pure ()
          (True, Left (HistoricalHostCleanupIntentUnobservable _)) -> pure ()
          _ -> expectationFailure "the archive itself was not the refusal boundary"
        observeHostCleanupIntent store `shouldReturn` Right Nothing

  it "refuses changed remote history before claiming or importing a local node" $
    withHistory $ \store history descriptor prefix -> do
      foreignAttempt <- expectRight (mkCleanupAttemptId "history/foreign-attempt")
      let remotes = [node | (node, CleanupNodeCompleted {}) <- Map.toList (cleanupRunNodeStates prefix)]
      case remotes of
        [] -> expectationFailure "fixture has no remote prefix"
        node : _ -> do
          authority <- newHistoryAuthority descriptor prefix Nothing
          modifyIORef'
            (historyAuthorityRun authority)
            ( \run ->
                run
                  { cleanupRunNodeStates =
                      Map.insert
                        node
                        (CleanupNodeCompleted foreignAttempt CleanupNodeSucceeded)
                        (cleanupRunNodeStates run)
                  }
            )
          result <-
            reconcileHistoricalHostCleanup (historyAuthorityClient authority) store (expiredNow prefix) history
          result `shouldSatisfy` isLeft
          observeHostCleanupIntent store `shouldReturn` Right (Just (historicalHostCleanupIntent history))
          commands <- readIORef (historyAuthorityCommands authority)
          [command | command@CleanupRunDescriptorClaim {} <- commands] `shouldBe` []
 where
  losses =
    LoseHistoryClaim
      : concatMap
        ( \raw ->
            let node = mustRight (mkCleanupNodeId ("lifecycle/cascade/" <> raw))
             in [LoseHistoryBegin node, LoseHistoryComplete node]
        )
        ["uninstall-local", "read-back-local-absence", "commit-completion", "read-back-completion"]

withHistory
  :: ( HostCleanupIntentStore
       -> HistoricalHostCleanupCompletion
       -> CleanupProgramDescriptor
       -> CleanupRun
       -> IO ()
     )
  -> IO ()
withHistory action = withSystemTempDirectory "prodbox-history-import" $ \root -> do
  let fixture = "test/fixtures/host-cleanup-history"
  intent <- ByteString.readFile (fixture </> "active.cbor") >>= expectRight . decodeHostCleanupIntent
  store <- expectRight (mkHostCleanupIntentStore root)
  journal <- expectRight (mkHostCleanupCompletionJournal root)
  completionName <- readFile (fixture </> "completion-filename.txt")
  let targets =
        [ ("active.cbor", hostCleanupIntentPath store)
        , ("handoff.cbor", hostCleanupTerminalHandoffPath store (hostCleanupRunId intent))
        , ("completion.cbor", hostCleanupCompletionJournalRoot journal </> completionName)
        ]
  forM_ targets $ \(name, destination) -> do
    createDirectoryIfMissing True (takeDirectory destination)
    setFileMode (takeDirectory destination) 0o700
    copyFile (fixture </> name) destination
    setFileMode destination 0o600
  observed <- observeHistoricalHostCleanupCompletion store journal >>= expectRight
  case observed of
    Nothing -> expectationFailure "history fixture was not observed"
    Just history -> do
      let scope = hostCleanupObservationEvidenceScope (hostCleanupScope intent)
      compiled <-
        expectRight
          ( compileDesiredAbsenceGraphWithBindings
              (hostCleanupRunId intent)
              (evidenceLinuxRke2Foundation scope)
              (evidenceAwsScope scope)
              (evidenceAwsDnsZone scope)
              (evidenceResourceScopeBindings scope)
              CascadeSurface
          )
      descriptor <- expectRight (captureCleanupProgramDescriptor compiled (hostCleanupRun intent))
      cleanupProgramDescriptorDigest descriptor
        `shouldBe` hostCleanupTerminalHandoffDescriptorDigest (historicalHostCleanupHandoff history)
      action
        store
        history
        descriptor
        (hostCleanupTerminalHandoffPrefix (historicalHostCleanupHandoff history))

expiredNow :: CleanupRun -> Natural
expiredNow prefix = cleanupLeaseExpiresAtMicros (cleanupRunLease prefix) + 1
expectRight :: (Show cause) => Either cause value -> IO value
expectRight result = case result of
  Left cause -> ioError (userError (show cause))
  Right value -> pure value
mustRight :: (Show cause) => Either cause value -> value
mustRight = either (error . show) id
