{-# LANGUAGE OverloadedStrings #-}

module DecommissionNodeEffect (decommissionNodeEffectSuite) where

import Data.Either (isLeft, isRight)
import Data.IORef
import Data.Maybe (fromJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.Decommission.Frame
  ( FrameAttemptId
  , FrameNodeId
  , mkFrameAttemptId
  )
import Prodbox.Lifecycle.Decommission.Graph
  ( reportConverged
  , reportFailed
  , runDecommissionGraph
  )
import Prodbox.Lifecycle.Decommission.Manifest
  ( DecommissionNode (..)
  , DecommissionTargetGeneration
  , decommissionNodeFrameId
  , decommissionTargetGenerationValue
  , mkDecommissionTargetGeneration
  )
import Prodbox.Lifecycle.Decommission.NodeEffect
import Prodbox.Lifecycle.ResidueStatus
  ( ResidueDetails (ResidueDetails)
  , ResidueStatus (ResidueAbsent, ResiduePresent, ResidueUnreachable)
  , ResidueUnreachableReason (ResidueBackendMinioUnreachable)
  )
import TestSupport

decommissionNodeEffectSuite :: SuiteBuilder ()
decommissionNodeEffectSuite =
  describe "Sprint 4.50 decommission node effect" $ do
    it "confirms positive absence and preserves present/unavailable observations" $ do
      classifyReadBack ResidueAbsent `shouldSatisfy` isRight
      classifyReadBack (ResiduePresent (ResidueDetails "objects remain" "aws-ses"))
        `shouldSatisfy` isLeft
      classifyReadBack (ResidueUnreachable (ResidueBackendMinioUnreachable "down"))
        `shouldSatisfy` isLeft
      observeNodeOperation
        (operation (Right ()) (ResiduePresent (ResidueDetails "objects remain" "aws-ses")))
        nodeId
        attemptId
        `shouldReturn` NodeObservedPresent "present (aws-ses; evidence: objects remain)"
      observeNodeOperation
        (operation (Right ()) (ResidueUnreachable (ResidueBackendMinioUnreachable "down")))
        nodeId
        attemptId
        `shouldReturn` NodeObservationUnavailable "unreachable (MinIO backend unreachable: down)"

    it "does not re-observe when the destroy itself failed" $ do
      readBacks <- newIORef (0 :: Int)
      let failedDestroy =
            NodeOperation
              { nodeDestroy = \_ _ -> pure (Left "destroy failed")
              , nodeReadBack = \_ _ -> modifyIORef' readBacks (+ 1) >> pure ResidueAbsent
              }
      result <- runNodeOperation failedDestroy nodeId attemptId
      result `shouldBe` Left "destroy failed"
      readIORef readBacks `shouldReturn` 0

    it "supplies the same stable node/attempt IDs to destroy and authoritative read-back" $ do
      seenRef <- newIORef ([] :: [(Text, FrameNodeId, FrameAttemptId)])
      let tracked =
            NodeOperation
              { nodeDestroy = \seenNode seenAttempt -> do
                  modifyIORef' seenRef (("destroy", seenNode, seenAttempt) :)
                  pure (Right ())
              , nodeReadBack = \seenNode seenAttempt -> do
                  modifyIORef' seenRef (("observe", seenNode, seenAttempt) :)
                  pure ResidueAbsent
              }
      runNodeOperation tracked nodeId attemptId `shouldReturn` Right ()
      (reverse <$> readIORef seenRef)
        `shouldReturn` [ ("destroy", nodeId, attemptId)
                       , ("observe", nodeId, attemptId)
                       ]

    it "requires a confirmed absence after a successful destroy" $ do
      runNodeOperation (operation (Right ()) ResidueAbsent) nodeId attemptId
        `shouldReturn` Right ()
      firstFailure <-
        runNodeOperation
          (operation (Right ()) (ResiduePresent (ResidueDetails "left" "aws-ses")))
          nodeId
          attemptId
      firstFailure `shouldSatisfy` isLeft
      secondFailure <-
        runNodeOperation
          (operation (Right ()) (ResidueUnreachable (ResidueBackendMinioUnreachable "down")))
          nodeId
          attemptId
      secondFailure `shouldSatisfy` isLeft

    it "dispatches each node through its identity-aware interpreter" $ do
      report <-
        runDecommissionGraph fullInventory $ \node ->
          runDecommissionNode
            interpreter
            node
            (decommissionNodeFrameId node)
            (attemptIdFor node)
      reportConverged report `shouldBe` False
      reportFailed report `shouldBe` [SesProviderStack]

    it "maps every closed manifest node through the total production registry" $ do
      seen <- newIORef ([] :: [Text])
      let named label =
            NodeOperation
              { nodeDestroy = \_ _ -> modifyIORef' seen (("destroy:" <> label) :) >> pure (Right ())
              , nodeReadBack = \_ _ -> modifyIORef' seen (("observe:" <> label) :) >> pure ResidueAbsent
              }
          registry =
            DecommissionOperationRegistry
              { sesConsumerQuiescenceOperation = named "ses-consumers"
              , sesProviderStackOperation = named "ses-provider"
              , sesSmtpIamOperation = named "ses-smtp-iam"
              , targetGenerationOperation = \target generation ->
                  named (targetLabel target generation)
              , retainedCustodyOperation = named "retained-custody"
              , tlsRetainedObjectsOperation = named "tls-objects"
              , tlsRetentionIdentityOperation = named "tls-identity"
              , backupPrefixAbsenceProofOperation = named "backup-prefix-proof"
              , backupObjectsOperation = named "backup-objects"
              , sharedObjectBucketOperation = named "shared-bucket"
              }
          registeredInterpreter = decommissionInterpreterFromRegistry registry
      mapM_
        ( \node ->
            runDecommissionNode
              registeredInterpreter
              node
              (decommissionNodeFrameId node)
              (attemptIdFor node)
              `shouldReturn` Right ()
        )
        fullInventory
      (reverse <$> readIORef seen)
        `shouldReturn` concatMap expectedCalls fullInventory

    it "lowers every role-separated production capability without an effectful proof destroy" $ do
      seen <- newIORef ([] :: [(Text, FrameNodeId, FrameAttemptId)])
      let named label =
            NodeOperation
              { nodeDestroy = \seenNode seenAttempt -> do
                  modifyIORef' seen (("destroy:" <> label, seenNode, seenAttempt) :)
                  pure (Right ())
              , nodeReadBack = \seenNode seenAttempt -> do
                  modifyIORef' seen (("observe:" <> label, seenNode, seenAttempt) :)
                  pure ResidueAbsent
              }
          allPrefixes =
            BackupAllPrefixesAbsentCapability $ \seenNode seenAttempt -> do
              modifyIORef' seen (("observe:all-prefixes", seenNode, seenAttempt) :)
              pure ResidueAbsent
          capabilities =
            ProductionDecommissionCapabilities
              { productionSesConsumerQuiescence =
                  SesConsumerQuiescenceCapability (named "ses-consumers")
              , productionSesProviderStack =
                  SesProviderStackCapability (named "ses-provider")
              , productionSesSmtpIam =
                  SesSmtpIamCapability (named "ses-smtp-iam")
              , productionTargetGenerationTombstone =
                  TargetGenerationTombstoneCapability $ \target generation ->
                    named (targetLabel target generation)
              , productionRetainedCustodyTombstone =
                  RetainedCustodyTombstoneCapability (named "retained-custody")
              , productionTlsRetainedObjects =
                  TlsRetainedObjectsCapability (named "tls-objects")
              , productionTlsRetentionIdentity =
                  TlsRetentionIdentityCapability (named "tls-identity")
              , productionBackupObjectsIdentity =
                  BackupObjectsIdentityCapability (named "backup-objects-identity")
              , productionBackupAllPrefixesAbsent = allPrefixes
              , productionSharedObjectBucket =
                  SharedObjectBucketCapability (named "shared-bucket")
              }
          productionInterpreter =
            decommissionInterpreterFromRegistry
              (decommissionRegistryFromProductionCapabilities capabilities)
      mapM_
        ( \node ->
            runDecommissionNode
              productionInterpreter
              node
              (decommissionNodeFrameId node)
              (attemptIdFor node)
              `shouldReturn` Right ()
        )
        fullInventory
      (reverse <$> readIORef seen)
        `shouldReturn` concatMap expectedProductionCalls fullInventory
 where
  operation :: Either Text () -> ResidueStatus -> NodeOperation IO
  operation destroyResult readBack =
    NodeOperation
      { nodeDestroy = \_ _ -> pure destroyResult
      , nodeReadBack = \_ _ -> pure readBack
      }

  interpreter =
    DecommissionNodeInterpreter $ \node ->
      if node == SesProviderStack
        then operation (Right ()) (ResiduePresent (ResidueDetails "stack still live" "aws-ses"))
        else operation (Right ()) ResidueAbsent

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

  expectedCalls node =
    let label = case node of
          SesConsumerQuiescence -> "ses-consumers"
          SesProviderStack -> "ses-provider"
          SesSmtpIam -> "ses-smtp-iam"
          TargetGeneration target generation -> targetLabel target generation
          RetainedCustody -> "retained-custody"
          TlsRetainedObjects -> "tls-objects"
          TlsRetentionIdentity -> "tls-identity"
          BackupPrefixAbsenceProof -> "backup-prefix-proof"
          BackupObjects -> "backup-objects"
          SharedObjectBucket -> "shared-bucket"
     in ["destroy:" <> label, "observe:" <> label]

  expectedProductionCalls node =
    let stableNode = decommissionNodeFrameId node
        stableAttempt = attemptIdFor node
        call label = (label, stableNode, stableAttempt)
     in case node of
          BackupPrefixAbsenceProof -> [call "observe:all-prefixes"]
          _ ->
            let label = case node of
                  SesConsumerQuiescence -> "ses-consumers"
                  SesProviderStack -> "ses-provider"
                  SesSmtpIam -> "ses-smtp-iam"
                  TargetGeneration target generation -> targetLabel target generation
                  RetainedCustody -> "retained-custody"
                  TlsRetainedObjects -> "tls-objects"
                  TlsRetentionIdentity -> "tls-identity"
                  BackupObjects -> "backup-objects-identity"
                  SharedObjectBucket -> "shared-bucket"
             in [call ("destroy:" <> label), call ("observe:" <> label)]

  targetNode = TargetGeneration "vscode" targetGeneration

  targetLabel target generation =
    "target:"
      <> target
      <> ":generation-"
      <> Text.pack (show (decommissionTargetGenerationValue generation))

nodeId :: FrameNodeId
nodeId = decommissionNodeFrameId SesProviderStack

attemptId :: FrameAttemptId
attemptId = fromJust (mkFrameAttemptId "stable-attempt")

attemptIdFor :: DecommissionNode -> FrameAttemptId
attemptIdFor node =
  fromJust (mkFrameAttemptId ("attempt-" <> Text.pack (show node)))

targetGeneration :: DecommissionTargetGeneration
targetGeneration = case mkDecommissionTargetGeneration 7 of
  Right generation -> generation
  Left err -> error ("invalid node-effect fixture generation: " <> show err)
