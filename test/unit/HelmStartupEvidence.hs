{-# LANGUAGE OverloadedStrings #-}

module HelmStartupEvidence (helmStartupEvidenceSuite) where

import Control.Exception (AsyncException (UserInterrupt), throwIO, try)
import Control.Monad (forM_)
import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BL
import Data.IORef
import Data.List (isInfixOf)
import Data.Text qualified
import Prodbox.ControlPlane.Runtime
  ( LifecycleAuthorityStartupCause (..)
  , allLifecycleAuthorityStartupCauses
  , allTargetSecretAgentStartupCauses
  , allTlsRetentionStartupCauses
  , renderLifecycleAuthorityStartupCause
  , renderTargetSecretAgentStartupCause
  , renderTlsRetentionStartupCause
  )
import Prodbox.Infra.HelmStartupEvidence
import TestSupport

helmStartupEvidenceSuite :: SuiteBuilder ()
helmStartupEvidenceSuite = describe "INTERNAL-HELM-FAILED-RELEASE-STARTUP-LOGS-MISSING-2026-10-24" $ do
  it "preserves current and previous closed startup causes without private fields" $ withTarget $ \target -> do
    (report, metadataReads, logs) <-
      scenario target (Right (inventory [pod])) (replicate 4 (Right (body pod))) (Right refusal)
    report `shouldBe` StartupEvidence target captured captured
    metadataReads `shouldBe` 4
    logs `shouldBe` [CurrentStartupLog, PreviousStartupLog]
    renderStartupEvidence report `shouldSatisfy` (not . isInfixOf private)
    renderStartupEvidence report `shouldSatisfy` isInfixOf "config/decode"

  forM_
    [ ("absent", inventory [], StartupPodMissing)
    , ("multiple", inventory [pod, pod], StartupPodsAmbiguous)
    , ("malformed", "private-body", StartupPodMalformed)
    , ("oversized", BS.replicate (128 * 1024 + 1) 120, StartupPodMalformed)
    , ("foreign namespace", inventory [pod {namespace = "other"}], StartupPodForeign)
    , ("foreign release", inventory [pod {release = "other"}], StartupPodForeign)
    , ("missing label", inventory [pod {release = ""}], StartupPodForeign)
    , ("invalid Pod name", inventory [pod {name = "private/path"}], StartupPodMalformed)
    , ("non-ASCII Pod name", inventory [pod {name = "pod\x0661"}], StartupPodMalformed)
    , ("invalid UID", inventory [pod {uid = "private-value"}], StartupPodMalformed)
    , ("foreign container", inventory [pod {containers = ["other"]}], StartupContainerNotSole)
    ,
      ( "sidecar"
      , inventory [pod {containers = ["lifecycle-authority", "sidecar"]}]
      , StartupContainerNotSole
      )
    , ("unresolved container", inventory [pod {containerId = ""}], StartupContainerNotStarted)
    , ("negative restart count", inventory [pod {restarts = (-1)}], StartupContainerNotStarted)
    ]
    $ \(label, bytes, cause) -> it ("refuses " ++ label ++ " inventory before log metadataReads") $ withTarget $ \target -> do
      (report, metadataReads, logs) <- scenario target (Right bytes) [] (Right refusal)
      report `shouldBe` StartupInventoryRefused cause
      metadataReads `shouldBe` 0
      logs `shouldBe` []
      renderStartupEvidence report `shouldSatisfy` (not . isInfixOf private)

  forM_ [StartupReadUnavailable, StartupReadDeadlineElapsed] $ \cause ->
    it ("reports inventory " ++ show cause ++ " without later metadataReads") $ withTarget $ \target -> do
      (report, metadataReads, logs) <- scenario target (Left cause) [] (Right refusal)
      report `shouldBe` StartupInventoryUnavailable cause
      metadataReads `shouldBe` 0
      logs `shouldBe` []

  it "skips previous logs without a previous restart" $ withTarget $ \target -> do
    let fresh = pod {restarts = 0}
    (report, metadataReads, logs) <-
      scenario target (Right (inventory [fresh])) (replicate 2 (Right (body fresh))) (Right refusal)
    report `shouldBe` StartupEvidence target captured StartupPreviousNotApplicable
    metadataReads `shouldBe` 2
    logs `shouldBe` [CurrentStartupLog]

  forM_
    [ ("UID", pod {uid = "22222222-2222-4222-8222-222222222222", restarts = 0})
    , ("container", pod {containerId = "containerd://" ++ replicate 64 'b', restarts = 0})
    , ("restart", pod {restarts = 1})
    , ("namespace", pod {namespace = "other", restarts = 0})
    ]
    $ \(field, changed) -> it ("discards a cause when closing " ++ field ++ " changes") $ withTarget $ \target -> do
      let fresh = pod {restarts = 0}
      (report, _, logs) <-
        scenario
          target
          (Right (inventory [fresh]))
          [Right (body fresh), Right (body changed)]
          (Right refusal)
      report `shouldBe` StartupEvidence target StartupAttributionChanged StartupPreviousNotApplicable
      logs `shouldBe` [CurrentStartupLog]
      renderStartupEvidence report `shouldSatisfy` (not . isInfixOf "config/decode")

  it "refuses a replacement before opening its log" $ withTarget $ \target -> do
    let fresh = pod {restarts = 0}; replacement = fresh {uid = "22222222-2222-4222-8222-222222222222"}
    (report, metadataReads, logs) <-
      scenario target (Right (inventory [fresh])) [Right (body replacement)] (Right refusal)
    report `shouldBe` StartupEvidence target StartupAttributionChanged StartupPreviousNotApplicable
    metadataReads `shouldBe` 1
    logs `shouldBe` []

  it "reports an unavailable closing read without publishing the captured cause" $ withTarget $ \target -> do
    let fresh = pod {restarts = 0}
    (report, _, _) <-
      scenario
        target
        (Right (inventory [fresh]))
        [Right (body fresh), Left StartupReadUnavailable]
        (Right refusal)
    report
      `shouldBe` StartupEvidence
        target
        (StartupCaptureUnavailable StartupReadUnavailable)
        StartupPreviousNotApplicable

  it "never substitutes an acknowledgement for missing log output" $ withTarget $ \target -> do
    let fresh = pod {restarts = 0}
    (report, metadataReads, _) <-
      scenario target (Right (inventory [fresh])) [Right (body fresh)] (Left StartupReadUnavailable)
    report
      `shouldBe` StartupEvidence
        target
        (StartupCaptureUnavailable StartupReadUnavailable)
        StartupPreviousNotApplicable
    metadataReads `shouldBe` 1

  forM_ ["before", "log"] $ \stage -> it ("stops after deadline at " ++ stage) $ withTarget $ \target -> do
    let metadata = if stage == "before" then [Left StartupReadDeadlineElapsed] else [Right (body pod)]
    (report, metadataReads, logs) <-
      scenario target (Right (inventory [pod])) metadata (Left StartupReadDeadlineElapsed)
    report
      `shouldBe` StartupEvidence
        target
        (StartupCaptureUnavailable StartupReadDeadlineElapsed)
        (StartupCaptureUnavailable StartupReadDeadlineElapsed)
    metadataReads `shouldBe` 1
    logs `shouldBe` [CurrentStartupLog | stage /= "before"]

  forM_
    [
      ( "wrong severity"
      , event "lifecycle_authority_startup_refused" "warn" "lifecycle-authority" "config/decode"
      )
    ,
      ( "wrong role"
      , event "lifecycle_authority_startup_refused" "error" "provider-worker" "config/decode"
      )
    , ("wrong event", event "private_event" "error" "lifecycle-authority" "config/decode")
    ,
      ( "unknown cause"
      , event "lifecycle_authority_startup_refused" "error" "lifecycle-authority" "private-value"
      )
    , ("unstructured", BS8.pack private)
    , ("empty", BS.empty)
    , ("oversized", BS.replicate (64 * 1024 + 1) 120)
    ]
    $ \(label, bytes) -> it ("keeps " ++ label ++ " output unclassified and private") $ withTarget $ \target -> do
      decodeStartupCauses target bytes `shouldBe` []

  it "deduplicates recognized events while discarding unrelated private records" $ withTarget $ \target -> do
    decodeStartupCauses target (BS8.intercalate "\n" [refusal, BS8.pack private, refusal])
      `shouldBe` [AuthorityStartupCause LifecycleAuthorityStartupConfigDecode]

  it "propagates cancellation without converting it to evidence" $ withTarget $ \target -> do
    let effects =
          StartupEvidenceEffects
            (\_ -> pure (Right (inventory [pod])))
            (\_ -> pure (Right (body pod)))
            (\_ _ -> throwIO UserInterrupt)
    result <- try (observeStartupEvidence effects target) :: IO (Either AsyncException StartupEvidence)
    result `shouldBe` Left UserInterrupt

  forM_ allLifecycleAuthorityStartupCauses $ \cause ->
    it ("accepts the producer Authority cause " ++ show cause) $ withTarget $ \target ->
      decodeStartupCauses
        target
        ( event
            "lifecycle_authority_startup_refused"
            "error"
            "lifecycle-authority"
            (renderLifecycleAuthorityStartupCause cause)
        )
        `shouldBe` [AuthorityStartupCause cause]
  forM_ allTargetSecretAgentStartupCauses $ \cause ->
    it ("accepts the producer Agent cause " ++ show cause) $ withSelected "target-secret-agent" $ \target ->
      decodeStartupCauses
        target
        ( event
            "target_secret_agent_startup_refused"
            "error"
            "target-secret-agent"
            (renderTargetSecretAgentStartupCause cause)
        )
        `shouldBe` [TargetAgentStartupCause cause]
  forM_ allTlsRetentionStartupCauses $ \cause ->
    it ("accepts the producer Retention cause " ++ show cause) $ withSelected "tls-retention" $ \target ->
      decodeStartupCauses
        target
        (event "tls_retention_startup_refused" "error" "tls-retention" (renderTlsRetentionStartupCause cause))
        `shouldBe` [RetentionStartupCause cause]

withTarget :: (StartupTarget -> IO ()) -> IO ()
withTarget = withSelected "lifecycle-authority"
withSelected :: String -> (StartupTarget -> IO ()) -> IO ()
withSelected selected action = case startupTarget selected selected of
  Nothing -> expectationFailure "fixed internal role must be registered"
  Just target -> action target

scenario
  :: StartupTarget
  -> Either StartupReadFailure ByteString
  -> [Either StartupReadFailure ByteString]
  -> Either StartupReadFailure ByteString
  -> IO (StartupEvidence, Int, [StartupLogKind])
scenario target inventoryReply metadataReplies logReply = do
  metadata <- newIORef metadataReplies
  count <- newIORef (0 :: Int)
  logs <- newIORef []
  let effects =
        StartupEvidenceEffects
          (\_ -> pure inventoryReply)
          ( \_ -> do
              modifyIORef' count (+ 1)
              queue <- readIORef metadata
              case queue of
                [] -> fail "unexpected metadata effect"
                first : rest -> writeIORef metadata rest >> pure first
          )
          (\_ kind -> modifyIORef' logs (++ [kind]) >> pure logReply)
  report <- observeStartupEvidence effects target
  metadataReads <- readIORef count
  requested <- readIORef logs
  pure (report, metadataReads, requested)

data PodFixture = PodFixture
  { name :: String
  , namespace :: String
  , uid :: String
  , release :: String
  , containers :: [String]
  , restarts :: Int
  , containerId :: String
  }
pod :: PodFixture
pod =
  PodFixture
    "lifecycle-authority-0"
    "lifecycle-authority"
    "11111111-1111-4111-8111-111111111111"
    "lifecycle-authority"
    ["lifecycle-authority"]
    480
    ("containerd://" ++ replicate 64 'a')
body :: PodFixture -> ByteString
body = BL.toStrict . encode . podValue
inventory :: [PodFixture] -> ByteString
inventory values = BL.toStrict (encode (object ["items" .= map podValue values]))
podValue :: PodFixture -> Value
podValue f =
  object
    [ "metadata"
        .= object
          [ "name" .= name f
          , "namespace" .= namespace f
          , "uid" .= uid f
          , "labels" .= object ["app.kubernetes.io/instance" .= release f]
          , "annotations" .= object ["private" .= private]
          ]
    , "spec" .= object ["containers" .= map (\value -> object ["name" .= value]) (containers f)]
    , "status"
        .= object
          [ "containerStatuses"
              .= [ object
                     [ "name" .= ("lifecycle-authority" :: String)
                     , "restartCount" .= restarts f
                     , "containerID" .= containerId f
                     ]
                 ]
          ]
    ]
private :: String
private = "private-startup-sentinel"
refusal :: ByteString
refusal = event "lifecycle_authority_startup_refused" "error" "lifecycle-authority" "config/decode"
captured :: StartupCapture
captured = StartupCaptured [AuthorityStartupCause LifecycleAuthorityStartupConfigDecode]
event :: Data.Text.Text -> Data.Text.Text -> Data.Text.Text -> Data.Text.Text -> ByteString
event nameValue severity role cause =
  BL.toStrict
    ( encode
        ( object
            [ "event" .= nameValue
            , "severity" .= severity
            , "field_role" .= role
            , "field_cause" .= cause
            , "field_private" .= private
            ]
        )
    )
