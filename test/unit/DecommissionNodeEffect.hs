{-# LANGUAGE OverloadedStrings #-}

module DecommissionNodeEffect (decommissionNodeEffectSuite) where

import Data.Either (isLeft, isRight)
import Data.IORef
import Data.Text (Text)
import Prodbox.Lifecycle.Decommission.Graph (reportConverged, reportFailed, runDecommissionGraph)
import Prodbox.Lifecycle.Decommission.Manifest (DecommissionNode (..))
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
    it "confirms a positively observed absence and refuses presence or an unobservable read" $ do
      classifyReadBack ResidueAbsent `shouldSatisfy` isRight
      classifyReadBack (ResiduePresent (ResidueDetails "objects remain" "aws-ses")) `shouldSatisfy` isLeft
      classifyReadBack (ResidueUnreachable (ResidueBackendMinioUnreachable "down")) `shouldSatisfy` isLeft
    it "does not re-observe when the destroy itself failed" $ do
      readBacks <- newIORef (0 :: Int)
      let failedDestroy =
            NodeOperation
              { nodeDestroy = pure (Left "destroy failed")
              , nodeReadBack = modifyIORef' readBacks (+ 1) >> pure ResidueAbsent
              }
      result <- runNodeOperation failedDestroy
      result `shouldBe` Left "destroy failed"
      readIORef readBacks `shouldReturn` 0
    it "requires a confirmed absence after a successful destroy" $ do
      runNodeOperation (operation (Right ()) ResidueAbsent) `shouldReturn` Right ()
      firstFailure <-
        runNodeOperation (operation (Right ()) (ResiduePresent (ResidueDetails "left" "aws-ses")))
      firstFailure `shouldSatisfy` isLeft
      secondFailure <-
        runNodeOperation (operation (Right ()) (ResidueUnreachable (ResidueBackendMinioUnreachable "down")))
      secondFailure `shouldSatisfy` isLeft
    it "dispatches each node through its interpreter and drives the destroy subgraph" $ do
      report <- runDecommissionGraph fullInventory (runDecommissionNode interpreter)
      reportConverged report `shouldBe` False
      reportFailed report `shouldBe` [SesProviderStack]
 where
  operation :: Either Text () -> ResidueStatus -> NodeOperation IO
  operation destroyResult readBack =
    NodeOperation {nodeDestroy = pure destroyResult, nodeReadBack = pure readBack}
  -- Every node destroys cleanly except the SES provider stack, whose read-back
  -- still reports presence — so the graph fails it and blocks its dependents.
  interpreter =
    DecommissionNodeInterpreter $ \node ->
      if node == SesProviderStack
        then operation (Right ()) (ResiduePresent (ResidueDetails "stack still live" "aws-ses"))
        else operation (Right ()) ResidueAbsent
  fullInventory =
    [ SesConsumerQuiescence
    , SesProviderStack
    , SesSmtpIam
    , TargetGeneration "vscode"
    , RetainedCustody
    , TlsRetainedObjects
    , TlsRetentionIdentity
    , BackupPrefixAbsenceProof
    , BackupObjects
    , SharedObjectBucket
    ]
