{-# LANGUAGE OverloadedStrings #-}

module DecommissionRunner (decommissionRunnerSuite) where

import Control.Monad (forM_)
import Data.ByteString qualified as ByteString
import Data.IORef
import Data.List (elemIndex, mapAccumL)
import Data.Maybe (fromJust, listToMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.Decommission.Frame
  ( DecommissionFrame
  , FrameAttemptId
  , FrameDigest (FrameDigest)
  , appendPayload
  , contentDigest
  , frameAttemptId
  , frameNodeId
  , mkFrameAttemptId
  )
import Prodbox.Lifecycle.Decommission.Graph
  ( decommissionTopologicalOrder
  , reportBlocked
  , reportConverged
  )
import Prodbox.Lifecycle.Decommission.Manifest
  ( DecommissionNode (..)
  , DecommissionTargetGeneration
  , VerifiedDecommissionManifest
  , decommissionManifestDigest
  , decommissionNodeFrameId
  , manifestPublicKeyDigest
  , manifestSigningPublicKey
  , mkDecommissionManifest
  , mkDecommissionTargetGeneration
  , mkManifestSigningKey
  , signDecommissionManifest
  , verifySignedDecommissionManifest
  )
import Prodbox.Lifecycle.Decommission.NodeEffect
  ( DecommissionNodeInterpreter (DecommissionNodeInterpreter)
  , NodeObservation
    ( NodeObservationUnavailable
    , NodeObservedAbsent
    , NodeObservedPresent
    )
  , NodeOperation (..)
  )
import Prodbox.Lifecycle.Decommission.Receipt
  ( AcknowledgedExternalReceipt
  , BoundReceiptReopen (boundReopenFrames)
  , ReceiptReopen (reopenFrames)
  , acknowledgeExternalReceipt
  , appendReceiptFrame
  , prepareExternalReceiptAcknowledgement
  , receiptAcknowledgementLiteral
  , reopenBoundReceipt
  , reopenReceipt
  )
import Prodbox.Lifecycle.Decommission.Runner
import Prodbox.Lifecycle.Decommission.Verifier
  ( ExternalArtifactPath
  , VerifierBinding
  , VerifierMetadata
  , VerifierPreflightRefusal (VerifierArtifactAbsent)
  , boundArtifactPath
  , exportVerifierArtifact
  , externalArtifactPath
  , externalReceiptPath
  , mkDeletionRootPath
  , mkExternalArtifactPath
  , mkExternalReceiptPath
  , mkVerifierArtifact
  , mkVerifierMetadata
  , validateExternalDurablePathsOnHost
  , verifierBindingOf
  )
import Prodbox.Lifecycle.ResidueStatus (ResidueStatus (ResidueAbsent))
import System.Directory (removeFile)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import TestSupport

decommissionRunnerSuite :: SuiteBuilder ()
decommissionRunnerSuite =
  describe "Sprint 4.50 decommission run orchestration" $ do
    it "journals intent, authoritative observation, and result under stable per-node attempts" $ do
      recordedRef <- newIORef []
      outcome <-
        runDecommission
          fullInventory
          emptyDecommissionResume
          freshAttemptId
          (recordTo recordedRef)
          (const (pure NodeObservedAbsent))
          (const (pure (Right ())))
      report <- expectRunRight outcome
      reportConverged report `shouldBe` True
      recorded <- reverse <$> readIORef recordedRef
      fmap snd recorded
        `shouldBe` concatMap
          ( \node ->
              [ DecommissionIntent node
              , DecommissionObservation node NodeObservedAbsent
              , DecommissionNodeResult node NodeDestroyed
              ]
          )
          (decommissionTopologicalOrder fullInventory)
      mapM_ assertStableIdentity recorded

    it "skips semantically completed nodes without re-running or re-journaling them" $ do
      let completed = [SesConsumerQuiescence, SesProviderStack, SesSmtpIam]
          frames = receiptFrames (concatMap successfulEvents completed)
          resume = mustRight (validateReceiptSemantics frames)
      recordedRef <- newIORef []
      calledRef <- newIORef []
      outcome <-
        runDecommission
          fullInventory
          resume
          retryAttemptId
          (recordTo recordedRef)
          (const (pure NodeObservedAbsent))
          (trackSucceed calledRef)
      report <- expectRunRight outcome
      reportConverged report `shouldBe` True
      called <- readIORef calledRef
      recorded <- readIORef recordedRef
      all (`notElem` fmap decommissionAttemptNode called) completed `shouldBe` True
      all (\(_, entry) -> entryNode entry `notElem` completed) recorded `shouldBe` True

    it "journals a definitive failed result and blocks its dependants" $ do
      recordedRef <- newIORef []
      outcome <-
        runDecommission
          fullInventory
          emptyDecommissionResume
          freshAttemptId
          (recordTo recordedRef)
          (const (pure NodeObservedAbsent))
          (failAttempt SesProviderStack)
      report <- expectRunRight outcome
      reportConverged report `shouldBe` False
      recorded <- reverse <$> readIORef recordedRef
      any
        ( \(_, entry) ->
            entry == DecommissionNodeResult SesProviderStack (NodeDestroyFailed "injected")
        )
        recorded
        `shouldBe` True
      any ((== RetainedCustody) . entryNode . snd) recorded `shouldBe` False
      (RetainedCustody `elem` reportBlocked report) `shouldBe` True

    it "re-observes a recovered intent and closes observed absence without a duplicate destroy" $
      withSystemTempDirectory "prodbox-decommission-intent-recovery" $ \dir -> do
        let path = dir </> "receipt.log"
            node = SesProviderStack
            manifest = mustRight (mkDecommissionManifest "home" [node])
            digest = decommissionManifestDigest manifest
            attempt = mkAttempt node "stable-attempt"
        lastRef <- newIORef Nothing
        appendEntry digest path lastRef attempt (DecommissionIntent node)

        reopened <- reopenReceipt 65536 digest path :: IO (ReceiptReopen DecommissionEntry)
        let resume = mustRight (validateReceiptSemantics (reopenFrames reopened))
        pendingAttempt resume node `shouldBe` Just attempt
        resumeLastRef <- newIORef (listToMaybe (reverse (reopenFrames reopened)))
        observationsRef <- newIORef []
        destroysRef <- newIORef []
        outcome <-
          runDecommission
            [node]
            resume
            (const (error "pending recovery must reuse its recorded attempt id"))
            (appendEntry digest path resumeLastRef)
            (trackObservation observationsRef NodeObservedAbsent)
            (trackSucceed destroysRef)
        report <- expectRunRight outcome
        reportConverged report `shouldBe` True
        readIORef observationsRef `shouldReturn` [attempt]
        readIORef destroysRef `shouldReturn` []

        completedReopen <- reopenReceipt 65536 digest path :: IO (ReceiptReopen DecommissionEntry)
        let completed = mustRight (validateReceiptSemantics (reopenFrames completedReopen))
        completedNodes completed `shouldBe` [node]
        all (sameIdentity attempt) (reopenFrames completedReopen) `shouldBe` True

    it "re-observes presence before retrying the same stable attempt, then read-backs absence" $ do
      let node = SesProviderStack
          attempt = mkAttempt node "stable-attempt"
          resume = mustRight (validateReceiptSemantics (receiptFrames [(attempt, DecommissionIntent node)]))
      callsRef <- newIORef []
      observationCountRef <- newIORef (0 :: Int)
      recordedRef <- newIORef []
      outcome <-
        runDecommission
          [node]
          resume
          (const (error "pending recovery must not mint an attempt id"))
          (recordTo recordedRef)
          (observePresentThenAbsent callsRef observationCountRef)
          (trackDestroyCall callsRef)
      report <- expectRunRight outcome
      reportConverged report `shouldBe` True
      (reverse <$> readIORef callsRef)
        `shouldReturn` [ ("observe", attempt)
                       , ("destroy", attempt)
                       , ("observe", attempt)
                       ]
      recorded <- reverse <$> readIORef recordedRef
      fmap snd recorded
        `shouldBe` [ DecommissionObservation node (NodeObservedPresent "still present")
                   , DecommissionObservation node NodeObservedAbsent
                   , DecommissionNodeResult node NodeDestroyed
                   ]
      all ((== attempt) . fst) recorded `shouldBe` True

    it "leaves an unavailable recovery observation pending and never mutates" $ do
      let node = SesProviderStack
          attempt = mkAttempt node "stable-attempt"
          resume = mustRight (validateReceiptSemantics (receiptFrames [(attempt, DecommissionIntent node)]))
      destroysRef <- newIORef []
      recordedRef <- newIORef []
      outcome <-
        runDecommission
          [node]
          resume
          (const (error "pending recovery must not mint an attempt id"))
          (recordTo recordedRef)
          (const (pure (NodeObservationUnavailable "authority unavailable")))
          (trackSucceed destroysRef)
      report <- expectRunRight outcome
      reportConverged report `shouldBe` False
      readIORef destroysRef `shouldReturn` []
      recorded <- reverse <$> readIORef recordedRef
      fmap snd recorded
        `shouldBe` [DecommissionObservation node (NodeObservationUnavailable "authority unavailable")]
      let resumedAgain =
            mustRight
              (validateReceiptSemantics (receiptFrames ((attempt, DecommissionIntent node) : recorded)))
      pendingAttempt resumedAgain node `shouldBe` Just attempt

    it "refuses reused fresh attempt IDs before journaling or external effects" $ do
      recordedRef <- newIORef []
      effectsRef <- newIORef []
      let reused = mustFrameAttemptId "reused-attempt"
      outcome <-
        runDecommission
          [SesConsumerQuiescence, SesProviderStack]
          emptyDecommissionResume
          (const reused)
          (recordTo recordedRef)
          (trackObservation effectsRef NodeObservedAbsent)
          (trackSucceed effectsRef)
      outcome
        `shouldBe` Left (RunAttemptIdReused reused SesConsumerQuiescence SesProviderStack)
      readIORef recordedRef `shouldReturn` []
      readIORef effectsRef `shouldReturn` []

    it "never mutates when the durable intent append is refused" $ do
      effectsRef <- newIORef []
      let node = SesProviderStack
          attempt = mkAttempt node "durability-attempt"
      outcome <-
        runDecommissionDurable
          [node]
          emptyDecommissionResume
          (const (decommissionAttemptId attempt))
          (\_ _ -> pure (Left "receipt fsync failed"))
          (trackObservation effectsRef NodeObservedAbsent)
          (trackSucceed effectsRef)
      outcome
        `shouldBe` Left
          ( RunReceiptAppendFailed
              node
              (decommissionAttemptId attempt)
              "receipt fsync failed"
          )
      readIORef effectsRef `shouldReturn` []

    it "stops after a post-effect receipt failure and leaves the durable intent recoverable" $ do
      let node = SesProviderStack
          attempt = mkAttempt node "post-effect-failure"
      recordedRef <- newIORef []
      destroysRef <- newIORef []
      outcome <-
        runDecommissionDurable
          [node]
          emptyDecommissionResume
          (const (decommissionAttemptId attempt))
          (recordIntentThenRefuseObservation recordedRef)
          (const (pure NodeObservedAbsent))
          (trackSucceed destroysRef)
      outcome
        `shouldBe` Left
          ( RunReceiptAppendFailed
              node
              (decommissionAttemptId attempt)
              "observation append failed"
          )
      readIORef destroysRef `shouldReturn` [attempt]
      recorded <- reverse <$> readIORef recordedRef
      recorded `shouldBe` [(attempt, DecommissionIntent node)]
      pendingAttempt
        (mustRight (validateReceiptSemantics (receiptFrames recorded)))
        node
        `shouldBe` Just attempt

    it "recovers every closed node after an effect-response crash without duplicate mutation" $ do
      forM_ fullInventory $ \node -> do
        let attempt = mkAttempt node ("crash-recovery-" <> Text.pack (show node))
            resume =
              mustRight
                (validateReceiptSemantics (receiptFrames [(attempt, DecommissionIntent node)]))
        recordedRef <- newIORef []
        destroysRef <- newIORef []
        outcome <-
          runDecommission
            [node]
            resume
            (const (error "recovery must reuse the durable attempt"))
            (recordTo recordedRef)
            (const (pure NodeObservedAbsent))
            (trackSucceed destroysRef)
        report <- expectRunRight outcome
        reportConverged report `shouldBe` True
        readIORef destroysRef `shouldReturn` []
        recorded <- reverse <$> readIORef recordedRef
        recorded
          `shouldBe` [ (attempt, DecommissionObservation node NodeObservedAbsent)
                     , (attempt, DecommissionNodeResult node NodeDestroyed)
                     ]

    it "runs and idempotently resumes only through fresh artifact and bound-receipt validation" $
      withBoundFixture $ \fixture -> do
        effectsRef <- newIORef ([] :: [Text])
        let interpreter = DecommissionNodeInterpreter (const (trackedAbsentOperation effectsRef))
        first <-
          runBoundDecommission
            65536
            (boundFixtureVerified fixture)
            (boundFixtureBinding fixture)
            (boundFixtureAcknowledgedReceipt fixture)
            (const (mustFrameAttemptId "bound-attempt"))
            interpreter
        (reportConverged <$> first) `shouldBe` Right True
        reopened <-
          reopenBoundReceipt
            65536
            (boundFixtureVerified fixture)
            (boundFixtureReceiptPath fixture)
        case reopened of
          Left refusal -> expectationFailure ("expected bound receipt, got " <> show refusal)
          Right receipt -> do
            length (boundReopenFrames receipt) `shouldBe` 3
            completedNodes
              (mustRight (validateReceiptSemantics (boundReopenFrames receipt)))
              `shouldBe` [SesProviderStack]
        effectsAfterFirst <- readIORef effectsRef
        second <-
          runBoundDecommission
            65536
            (boundFixtureVerified fixture)
            (boundFixtureBinding fixture)
            (boundFixtureAcknowledgedReceipt fixture)
            (const (error "completed resume must not mint an attempt"))
            interpreter
        (reportConverged <$> second) `shouldBe` Right True
        readIORef effectsRef `shouldReturn` effectsAfterFirst

    it "refuses a missing pinned artifact or a different running build before effects" $
      withBoundFixture $ \fixture -> do
        effectsRef <- newIORef ([] :: [Text])
        let interpreter = DecommissionNodeInterpreter (const (trackedAbsentOperation effectsRef))
            newBuild =
              mustRight
                ( mkVerifierArtifact
                    "new-current-build"
                    boundDependencyBytes
                    boundMetadata
                )
            newIdentity = verifierBindingOf (boundArtifactPath (boundFixtureBinding fixture)) newBuild
        newBuildResult <-
          runBoundDecommission
            65536
            (boundFixtureVerified fixture)
            newIdentity
            (boundFixtureAcknowledgedReceipt fixture)
            (const (mustFrameAttemptId "never-used"))
            interpreter
        case newBuildResult of
          Left (BoundRunPreflightRefused _) -> pure ()
          other -> expectationFailure ("expected self-execution refusal, got " <> show other)
        removeFile (externalArtifactPath (boundFixtureArtifactPath fixture))
        missingResult <-
          runBoundDecommission
            65536
            (boundFixtureVerified fixture)
            (boundFixtureBinding fixture)
            (boundFixtureAcknowledgedReceipt fixture)
            (const (mustFrameAttemptId "never-used"))
            interpreter
        missingResult `shouldBe` Left (BoundRunVerifierRefused VerifierArtifactAbsent)
        readIORef effectsRef `shouldReturn` []

    it "refuses an acknowledgement issued for another signed artifact/receipt before effects" $
      withBoundFixture $ \fixture ->
        withBoundFixture $ \otherFixture -> do
          effectsRef <- newIORef ([] :: [Text])
          let interpreter = DecommissionNodeInterpreter (const (trackedAbsentOperation effectsRef))
          outcome <-
            runBoundDecommission
              65536
              (boundFixtureVerified fixture)
              (boundFixtureBinding fixture)
              (boundFixtureAcknowledgedReceipt otherFixture)
              (const (mustFrameAttemptId "never-used"))
              interpreter
          outcome `shouldBe` Left BoundRunReceiptAcknowledgementDrift
          readIORef effectsRef `shouldReturn` []

    it "rejects conflicting/reused IDs and contradictory complete frame sequences" $ do
      let first = mkAttempt SesProviderStack "same-attempt"
          conflicting = mkAttempt SesSmtpIam "same-attempt"
          next = mkAttempt SesProviderStack "next-attempt"
          wrongNodeIdAttempt =
            first {decommissionAttemptNodeId = decommissionNodeFrameId SesSmtpIam}
          validSuccess = successfulEvents SesProviderStack
      validateReceiptSemantics (receiptFrames [(wrongNodeIdAttempt, DecommissionIntent SesProviderStack)])
        `shouldBe` Left
          ( ReceiptNodeIdMismatch
              0
              (decommissionNodeFrameId SesProviderStack)
              (decommissionNodeFrameId SesSmtpIam)
          )
      validateReceiptSemantics
        ( receiptFrames
            [ (first, DecommissionIntent SesProviderStack)
            , (conflicting, DecommissionIntent SesSmtpIam)
            ]
        )
        `shouldBe` Left (ReceiptAttemptIdConflict 1 (decommissionAttemptId first) SesProviderStack SesSmtpIam)
      validateReceiptSemantics
        ( receiptFrames
            [ (first, DecommissionIntent SesProviderStack)
            , (first, DecommissionIntent SesProviderStack)
            ]
        )
        `shouldBe` Left (ReceiptAttemptIdReused 1 (decommissionAttemptId first))
      validateReceiptSemantics
        (receiptFrames [(first, DecommissionNodeResult SesProviderStack NodeDestroyed)])
        `shouldBe` Left (ReceiptEntryWithoutIntent 0 (decommissionAttemptId first))
      validateReceiptSemantics
        ( receiptFrames
            [ (first, DecommissionIntent SesProviderStack)
            , (first, DecommissionNodeResult SesProviderStack NodeDestroyed)
            ]
        )
        `shouldBe` Left (ReceiptSuccessWithoutAbsentObservation 1 (decommissionAttemptId first))
      validateReceiptSemantics
        ( receiptFrames
            ( validSuccess
                ++ [(next, DecommissionIntent SesProviderStack)]
            )
        )
        `shouldBe` Left (ReceiptAttemptAfterSuccess 3 SesProviderStack)
 where
  fullInventory =
    [ SesConsumerQuiescence
    , SesProviderStack
    , SesSmtpIam
    , targetNode
    , RetainedCustody
    , TlsRetainedObjects
    , TlsRetentionIdentity
    , BackupPrefixAbsenceProof
    , BackupObjects
    , SharedObjectBucket
    ]

  freshAttemptId node =
    mustFrameAttemptId ("attempt-" <> Text.pack (show (fromJust (elemIndex node fullInventory))))

  retryAttemptId node =
    mustFrameAttemptId ("retry-" <> Text.pack (show (fromJust (elemIndex node fullInventory))))

  successfulEvents node =
    let attempt = mkAttempt node ("completed-" <> Text.pack (show node))
     in [ (attempt, DecommissionIntent node)
        , (attempt, DecommissionObservation node NodeObservedAbsent)
        , (attempt, DecommissionNodeResult node NodeDestroyed)
        ]

recordTo
  :: IORef [(DecommissionAttempt, DecommissionEntry)]
  -> DecommissionAttempt
  -> DecommissionEntry
  -> IO ()
recordTo ref attempt entry = modifyIORef' ref ((attempt, entry) :)

recordIntentThenRefuseObservation
  :: IORef [(DecommissionAttempt, DecommissionEntry)]
  -> DecommissionAttempt
  -> DecommissionEntry
  -> IO (Either Text ())
recordIntentThenRefuseObservation ref attempt entry = case entry of
  DecommissionIntent _ -> do
    modifyIORef' ref ((attempt, entry) :)
    pure (Right ())
  _ -> pure (Left "observation append failed")

trackSucceed
  :: IORef [DecommissionAttempt]
  -> DecommissionAttempt
  -> IO (Either Text ())
trackSucceed ref attempt = modifyIORef' ref (attempt :) >> pure (Right ())

failAttempt
  :: DecommissionNode
  -> DecommissionAttempt
  -> IO (Either Text ())
failAttempt target attempt =
  pure (if decommissionAttemptNode attempt == target then Left "injected" else Right ())

trackObservation
  :: IORef [DecommissionAttempt]
  -> NodeObservation
  -> DecommissionAttempt
  -> IO NodeObservation
trackObservation ref observation attempt =
  modifyIORef' ref (attempt :) >> pure observation

observePresentThenAbsent
  :: IORef [(Text, DecommissionAttempt)]
  -> IORef Int
  -> DecommissionAttempt
  -> IO NodeObservation
observePresentThenAbsent callsRef countRef attempt = do
  modifyIORef' callsRef (("observe", attempt) :)
  count <- readIORef countRef
  writeIORef countRef (count + 1)
  pure (if count == 0 then NodeObservedPresent "still present" else NodeObservedAbsent)

trackDestroyCall
  :: IORef [(Text, DecommissionAttempt)]
  -> DecommissionAttempt
  -> IO (Either Text ())
trackDestroyCall ref attempt =
  modifyIORef' ref (("destroy", attempt) :) >> pure (Right ())

appendEntry
  :: FrameDigest
  -> FilePath
  -> IORef (Maybe (DecommissionFrame DecommissionEntry))
  -> DecommissionAttempt
  -> DecommissionEntry
  -> IO ()
appendEntry digest path lastRef attempt entry = do
  previous <- readIORef lastRef
  let frame =
        appendPayload
          digest
          previous
          (decommissionAttemptNodeId attempt)
          (decommissionAttemptId attempt)
          entry
  appendReceiptFrame path frame
  writeIORef lastRef (Just frame)

receiptFrames
  :: [(DecommissionAttempt, DecommissionEntry)]
  -> [DecommissionFrame DecommissionEntry]
receiptFrames events = snd (mapAccumL append Nothing events)
 where
  append previous (attempt, entry) =
    let frame =
          appendPayload
            semanticManifest
            previous
            (decommissionAttemptNodeId attempt)
            (decommissionAttemptId attempt)
            entry
     in (Just frame, frame)

semanticManifest :: FrameDigest
semanticManifest = FrameDigest "semantic-manifest"

mkAttempt :: DecommissionNode -> Text -> DecommissionAttempt
mkAttempt node attemptId =
  DecommissionAttempt
    { decommissionAttemptNode = node
    , decommissionAttemptNodeId = decommissionNodeFrameId node
    , decommissionAttemptId = mustFrameAttemptId attemptId
    }

mustFrameAttemptId :: Text -> FrameAttemptId
mustFrameAttemptId = fromJust . mkFrameAttemptId

assertStableIdentity :: (DecommissionAttempt, DecommissionEntry) -> Expectation
assertStableIdentity (attempt, entry) = do
  decommissionAttemptNodeId attempt `shouldBe` decommissionNodeFrameId (entryNode entry)
  decommissionAttemptId attempt `shouldBe` freshAttemptIdForEntry entry
 where
  freshAttemptIdForEntry current =
    let node = entryNode current
        inventory =
          [ SesConsumerQuiescence
          , SesProviderStack
          , SesSmtpIam
          , targetNode
          , RetainedCustody
          , TlsRetainedObjects
          , TlsRetentionIdentity
          , BackupPrefixAbsenceProof
          , BackupObjects
          , SharedObjectBucket
          ]
     in mustFrameAttemptId
          ("attempt-" <> Text.pack (show (fromJust (elemIndex node inventory))))

targetNode :: DecommissionNode
targetNode = TargetGeneration "vscode" targetGeneration

targetGeneration :: DecommissionTargetGeneration
targetGeneration = case mkDecommissionTargetGeneration 7 of
  Right generation -> generation
  Left err -> error ("invalid runner fixture generation: " <> show err)

sameIdentity
  :: DecommissionAttempt
  -> DecommissionFrame DecommissionEntry
  -> Bool
sameIdentity attempt frame =
  frameNodeId frame == decommissionAttemptNodeId attempt
    && frameAttemptId frame == decommissionAttemptId attempt

entryNode :: DecommissionEntry -> DecommissionNode
entryNode entry = case entry of
  DecommissionIntent node -> node
  DecommissionObservation node _ -> node
  DecommissionNodeResult node _ -> node

expectRunRight
  :: Either DecommissionRunError value
  -> IO value
expectRunRight outcome = case outcome of
  Right value -> pure value
  Left err -> expectationFailure ("expected run plan, got " <> show err) >> fail "unreachable"

mustRight :: (Show err) => Either err value -> value
mustRight = either (error . show) id

data BoundFixture = BoundFixture
  { boundFixtureVerified :: !VerifiedDecommissionManifest
  , boundFixtureBinding :: !VerifierBinding
  , boundFixtureArtifactPath :: !ExternalArtifactPath
  , boundFixtureReceiptPath :: !FilePath
  , boundFixtureAcknowledgedReceipt :: !AcknowledgedExternalReceipt
  }

withBoundFixture :: (BoundFixture -> IO value) -> IO value
withBoundFixture action =
  withSystemTempDirectory "prodbox-bound-runner" $ \dir -> do
    let artifactPath = mustRight (mkExternalArtifactPath (dir </> "pinned-runner"))
        receipt = mustRight (mkExternalReceiptPath (dir </> "receipt.log"))
        receiptPath = externalReceiptPath receipt
        artifact =
          mustRight
            ( mkVerifierArtifact
                "pinned-runner-build"
                boundDependencyBytes
                boundMetadata
            )
    binding <- mustRight <$> exportVerifierArtifact artifactPath artifact
    let plan = mustRight (mkDecommissionManifest "home" [SesProviderStack])
        signingKey = mustRight (mkManifestSigningKey (ByteString.replicate 32 0x52))
        signerDigest = manifestPublicKeyDigest (manifestSigningPublicKey signingKey)
        verified =
          mustRight
            ( verifySignedDecommissionManifest
                signerDigest
                (signDecommissionManifest signingKey plan binding)
            )
    let deletionRoot = mustRight (mkDeletionRootPath (dir </> "deleted-cluster-root"))
    durablePaths <-
      mustRight <$> validateExternalDurablePathsOnHost [deletionRoot] artifactPath receipt
    pending <- mustRight <$> prepareExternalReceiptAcknowledgement durablePaths verified
    let acknowledged =
          mustRight
            (acknowledgeExternalReceipt (receiptAcknowledgementLiteral pending) pending)
    action
      BoundFixture
        { boundFixtureVerified = verified
        , boundFixtureBinding = binding
        , boundFixtureArtifactPath = artifactPath
        , boundFixtureReceiptPath = receiptPath
        , boundFixtureAcknowledgedReceipt = acknowledged
        }

boundDependencyBytes :: ByteString.ByteString
boundDependencyBytes = "bound-runner-dependencies"

boundMetadata :: VerifierMetadata
boundMetadata =
  mustRight
    ( mkVerifierMetadata
        (contentDigest boundDependencyBytes)
        1
        (contentDigest "manifest-schema-v1")
        1
        (contentDigest "interpreter-registry-v1")
    )

trackedAbsentOperation :: IORef [Text] -> NodeOperation IO
trackedAbsentOperation ref =
  NodeOperation
    { nodeDestroy = \_ _ -> modifyIORef' ref ("destroy" :) >> pure (Right ())
    , nodeReadBack = \_ _ -> modifyIORef' ref ("observe" :) >> pure ResidueAbsent
    }
