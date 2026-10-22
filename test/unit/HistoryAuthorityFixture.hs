{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module HistoryAuthorityFixture (HistoryFault (..), HistoryAuthority (..), newHistoryAuthority, newHistoryAuthorityWithPredecessor) where

import Control.Monad (unless)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
import Data.List (isSuffixOf)
import Data.Text qualified as Text
import HistoryAuthorityAuthenticationFixture
  ( fakeClientProviders
  , fakeMaximumLifetime
  , fakeServerProviders
  , fakeTransportBounds
  )
import Prodbox.ControlPlane.AuthenticatedTransport
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
import Prodbox.ControlPlane.CleanupRunClient
import Prodbox.ControlPlane.CleanupRunEndpoint
import Prodbox.ControlPlane.Client
import Prodbox.ControlPlane.Codec (decodeControlPlaneRequest)
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (LifecycleAuthorityControl, LifecycleCleanupRun)
  )
import Prodbox.Http.ReplyStatus (replyStatusCode)
import Prodbox.Lifecycle.Authority.Admission
import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch
import Prodbox.Lifecycle.CleanupRun
import Prodbox.Lifecycle.Teardown.CleanupProgramDescriptor
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))

-- Every opaque bound run is decoded by the real authenticated client. The
-- simulated server persists actual kernel transitions and can lose their reply.
data HistoryFault
  = LoseHistoryClaim
  | LoseHistoryBegin CleanupNodeId
  | LoseHistoryComplete CleanupNodeId
  | RefuseHistoryFinalRead
  | CompactHistory
  | CompactHistoryOnClosingRead
  | RefuseCompactedHistoryReport
  | RefuseCompactedHistoryClosingReport
  | ChangedCompactedHistoryReport
  | ForeignCompactedHistoryDescriptor
  deriving (Eq, Show)
data HistoryAuthority = HistoryAuthority
  { historyAuthorityClient :: DescriptorBoundCleanupRunClient IO
  , historyAuthorityRun :: IORef CleanupRun
  , historyAuthorityCommands :: IORef [CleanupRunDescriptorCommand]
  , historyAuthorityTransport :: AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  }
newHistoryAuthority
  :: CleanupProgramDescriptor -> CleanupRun -> Maybe HistoryFault -> IO HistoryAuthority
newHistoryAuthority descriptor initial fault = newHistoryAuthorityWithPredecessor descriptor initial fault Nothing

newHistoryAuthorityWithPredecessor
  :: CleanupProgramDescriptor
  -> CleanupRun
  -> Maybe HistoryFault
  -> Maybe (CascadeAuditFreezeBinding, ProviderBootstrapPredecessorPhase)
  -> IO HistoryAuthority
newHistoryAuthorityWithPredecessor descriptor initial fault predecessor = do
  initialAdmission <- either (ioError . userError . show) pure (initialCleanInstallAuthority 1 1)
  let admission = maybe initialAdmission (buildAdmission initialAdmission) predecessor
      buildAdmission initialState (binding, phase) =
        let audit =
              mustRight
                ( mkCascadeTerminalAuditReceipt
                    (cascadeAuditFreezeBindingScopeDigest binding)
                    (Text.replicate 64 "1")
                    (Text.replicate 64 "2")
                    CascadeTerminalAuditReceiptClean
                )
            revoked =
              mustRight
                ( mkProviderCredentialRevocationReceipt
                    (mustRight (mkCleanupDigest (Text.replicate 64 "3")))
                    (mustRight (mkCleanupDigest (Text.replicate 64 "4")))
                )
            frozenCommand = FreezeProviderAdmissionAtGeneration 7 binding
            recordedCommand = RecordCascadeTerminalAuditReceipt binding audit
            revokedCommand = RevokeCascadeProviderCredential binding revoked
            plan = case phase of
              ProviderBootstrapFrozen -> [frozenCommand]
              ProviderBootstrapRecorded -> [frozenCommand, recordedCommand]
              ProviderBootstrapRevoked -> [frozenCommand, recordedCommand, revokedCommand]
         in foldl (\state command -> snd (stepAuthorityAdmission state command)) initialState plan
  current <- newIORef initial
  commands <- newIORef []
  pendingFault <- newIORef fault
  terminalReads <- newIORef (0 :: Int)
  reportReads <- newIORef (0 :: Int)
  compacted <- newIORef False
  let runText = cleanupRunIdText (cleanupRunId initial)
      descriptorText = cleanupDigestText (cleanupProgramDescriptorDigest descriptor)
      refused detail = CleanupRunDescriptorRefused (CleanupRunDescriptorBindingMismatch detail)
      present run = case encodeCleanupRun cleanupRunMaximumBytes run of
        Left cause -> refused (Text.pack (show cause))
        Right bytes -> CleanupRunDescriptorPresent runText descriptorText bytes
      lose selected =
        atomicModifyIORef'
          pendingFault
          (\active -> if active == Just selected then (Nothing, True) else (active, False))
      transition selected change = do
        old <- readIORef current
        case change old of
          Left cause -> pure (CleanupRunDescriptorRefused (CleanupRunDescriptorTransitionRefused cause), False)
          Right changed -> do
            writeIORef current changed
            lost <- maybe (pure False) lose selected
            pure (present changed, lost)
      withIdentity rawRun rawDigest action =
        if rawRun == runText && rawDigest == descriptorText
          then action
          else pure (refused "foreign history identity", False)
      execute command = do
        modifyIORef' commands (++ [command])
        case command of
          CleanupRunDescriptorObserve rawRun | rawRun == runText -> do
            run <- readIORef current
            count <-
              if cleanupRunTerminal run then atomicModifyIORef' terminalReads (\n -> (n + 1, n + 1)) else pure 0
            failRead <- if count >= 2 then lose RefuseHistoryFinalRead else pure False
            if count >= 2 && fault == Just CompactHistoryOnClosingRead
              then writeIORef compacted True
              else pure ()
            archived <- readIORef compacted
            let body = mustRight (encodeCleanupRunReport cleanupRunMaximumBytes (mustRight (compactCleanupRun run)))
            pure
              ( if failRead
                  then CleanupRunDescriptorRefused (CleanupRunDescriptorUnavailable "injected final read refusal")
                  else
                    if archived
                      then CleanupRunDescriptorTombstoned descriptorText (cleanupDigestText (cleanupDigestOfBytes body))
                      else present run
              , False
              )
          CleanupRunDescriptorObserveCompletion rawRun rawDigest -> withIdentity rawRun rawDigest $ do
            run <- readIORef current
            count <- atomicModifyIORef' reportReads (\n -> (n + 1, n + 1))
            let original = mustRight (compactCleanupRun run)
                report =
                  if fault == Just ChangedCompactedHistoryReport
                    then original {cleanupReportPrimaryOutcome = CleanupPrimaryFailed "substituted historical primary"}
                    else original
                digest = if fault == Just ForeignCompactedHistoryDescriptor then Text.replicate 64 "f" else descriptorText
                response
                  | fault == Just RefuseCompactedHistoryReport
                      || (fault == Just RefuseCompactedHistoryClosingReport && count >= 2) =
                      CleanupRunDescriptorRefused (CleanupRunDescriptorUnavailable "injected report refusal")
                  | otherwise =
                      CleanupRunDescriptorCompacted
                        digest
                        (mustRight (encodeCleanupRunReport cleanupRunMaximumBytes report))
            pure (response, False)
          CleanupRunDescriptorReadBackProgram rawRun
            | rawRun == runText ->
                pure
                  ( CleanupRunDescriptorProgramPresent runText descriptorText (cleanupProgramDescriptorBytes descriptor)
                  , False
                  )
          CleanupRunDescriptorClaim rawRun rawDigest rawOwner now expires -> withIdentity rawRun rawDigest $
            case mkCleanupOwnerId rawOwner of
              Left detail -> pure (refused detail, False)
              Right owner -> transition (Just LoseHistoryClaim) (claimCleanupRun owner now expires)
          CleanupRunDescriptorBeginNode rawRun rawDigest rawOwner fence rawNode rawAttempt -> withIdentity rawRun rawDigest $
            case (mkCleanupOwnerId rawOwner, mkCleanupNodeId rawNode, mkCleanupAttemptId rawAttempt) of
              (Right owner, Right node, Right attempt) -> transition (Just (LoseHistoryBegin node)) (beginCleanupNode owner fence node attempt)
              _ -> pure (refused "invalid begin identity", False)
          CleanupRunDescriptorCompleteNode rawRun rawDigest rawOwner fence rawNode rawAttempt outcome -> withIdentity rawRun rawDigest $
            case (mkCleanupOwnerId rawOwner, mkCleanupNodeId rawNode, mkCleanupAttemptId rawAttempt) of
              (Right owner, Right node, Right attempt) ->
                transition (Just (LoseHistoryComplete node)) (completeCleanupNode owner fence node attempt outcome)
              _ -> pure (refused "invalid complete identity", False)
          _ -> pure (refused "unexpected history command", False)
      transport _ _ url body = do
        let route =
              if "/v1/authority/control" `isSuffixOf` url then LifecycleAuthorityControl else LifecycleCleanupRun
        authenticated <-
          authenticateControlPlaneFrame
            fakeTransportBounds
            fakeMaximumLifetime
            fakeServerProviders
            LifecycleAuthorityRuntime
            route
            (LazyByteString.fromStrict body)
        case authenticated of
          Left cause -> ioError (userError (show cause))
          Right request | route == LifecycleAuthorityControl ->
            case decodeControlPlaneRequest
              cleanupRunMaximumBytes
              (LazyByteString.fromStrict (authenticatedServerInnerBody request)) of
              Right AuthorityControlObserveProviderBootstrapPredecessor ->
                let result =
                      AuthorityTransitionDecided
                        (fst (stepAuthorityAdmission admission ObserveProviderBootstrapPredecessor))
                 in pure
                      ( Right
                          ( replyStatusCode (authorityTransitionHttpStatus result)
                          , LazyByteString.toStrict (authorityTransitionResponseBody result)
                          )
                      )
              _ -> ioError (userError "unexpected history control request")
          Right request -> case decodeControlPlaneRequest
            cleanupRunMaximumBytes
            (LazyByteString.fromStrict (authenticatedServerInnerBody request)) of
            Right (CleanupRunDescriptorBound command) -> do
              (response, lost) <- execute command
              let result = CleanupRunEndpointDescriptorBound response
              pure
                ( Right
                    ( if lost then 599 else replyStatusCode (cleanupRunEndpointStatus result)
                    , cleanupRunEndpointBody result
                    )
                )
            _ -> ioError (userError "unexpected raw history request")
  endpoint <-
    either
      (ioError . userError . show)
      pure
      (mkLifecycleAuthorityEndpoint "http://lifecycle-authority:8600")
  raw <-
    either
      (ioError . userError . show)
      pure
      (controlPlaneClientWithTransport (16 * 1024 * 1024) endpoint transport)
  let authenticatedTransport = mkAuthenticatedClientTransport fakeTransportBounds fakeClientProviders raw
      client = descriptorBoundCleanupRunClient authenticatedTransport
  observed <- observeDescriptorBoundCleanupRun client (cleanupRunId initial)
  unless
    (either (const False) ((== cleanupRunId initial) . descriptorBoundCleanupRunId) observed)
    (ioError (userError "fixture did not establish its authenticated descriptor binding"))
  writeIORef terminalReads 0
  writeIORef
    compacted
    ( fault
        `elem` map
          Just
          [ CompactHistory
          , RefuseCompactedHistoryReport
          , RefuseCompactedHistoryClosingReport
          , ChangedCompactedHistoryReport
          , ForeignCompactedHistoryDescriptor
          ]
    )
  pure (HistoryAuthority client current commands authenticatedTransport)

mustRight :: (Show cause) => Either cause value -> value
mustRight = either (error . show) id
