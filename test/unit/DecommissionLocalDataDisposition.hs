{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.85: the operator's retained-local-data decision, from the closed
-- type through the plan cardinality that makes it mandatory to the physical
-- adapter that honours it.
module DecommissionLocalDataDisposition
  ( decommissionLocalDataDispositionSuite
  )
where

import Data.ByteString qualified as ByteString
import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Prodbox.CLI.Nuke (validateProductionManifest)
import Prodbox.Lifecycle.CleanupRun (CleanupOperationId, mkCleanupOperationId)
import Prodbox.Lifecycle.Decommission.Frame (contentDigest)
import Prodbox.Lifecycle.Decommission.Graph
  ( decommissionTerminalPhaseBijection
  , decommissionTerminalPhaseOrder
  , productionDecommissionPlanNodes
  , terminalPhaseRunsLastInOrder
  )
import Prodbox.Lifecycle.Decommission.Manifest
  ( DecommissionChoiceFamily (LocalDataDispositionFamily)
  , DecommissionLocalDataDisposition (DeleteLocalData, RetainLocalData)
  , DecommissionNode (..)
  , DecommissionNodeFamily (..)
  , DecommissionPlanCardinalityError (..)
  , DecommissionSingletonNode (SingletonSharedObjectBucket)
  , ManifestPublicKey
  , ManifestSigningKey
  , VerifiedDecommissionManifest
  , decommissionChoiceFamilyBijection
  , decommissionChoiceFamilyRepresentative
  , decommissionLocalDataDispositionText
  , decommissionNodeFamily
  , decommissionNodeFrameId
  , decommissionNodeSingleton
  , mandatoryDecommissionChoiceNodes
  , manifestPublicKeyDigest
  , manifestSigningPublicKey
  , mkDecommissionManifest
  , mkManifestSigningKey
  , signDecommissionManifest
  , validateDecommissionPlanCardinality
  , verifySignedDecommissionManifest
  )
import Prodbox.Lifecycle.Decommission.Verifier
  ( ExternalArtifactPath
  , VerifierArtifact
  , VerifierBinding
  , VerifierMetadata
  , mkExternalArtifactPath
  , mkVerifierArtifact
  , mkVerifierMetadata
  , verifierBindingOf
  )
import Prodbox.Lifecycle.HostCleanupLocalData
  ( LocalDataDispositionOutcome (..)
  , LocalDataDispositionRefusal (..)
  , LocalDataDispositionResult (..)
  , LocalDataRootObservation (..)
  , LocalDataRootPath
  , LocalDataRootPathError (..)
  , LocalDataTerminalBoundary (..)
  , attemptLocalDataDisposition
  , classifyLocalDataDisposition
  , localDataDispositionResidue
  , localDataRootPath
  , mkLocalDataRootPath
  , mkLocalDataTerminalAdapter
  )
import Prodbox.Lifecycle.ResidueStatus
  ( ResidueStatus (ResidueAbsent, ResiduePresent, ResidueUnreachable)
  )
import Prodbox.Lifecycle.Teardown.Observation (AbsenceEvidence (AbsenceEvidence))
import Prodbox.Subprocess (ProcessOutput (..), Subprocess (..))
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import TestSupport

decommissionLocalDataDispositionSuite :: SuiteBuilder ()
decommissionLocalDataDispositionSuite =
  describe "Sprint 4.85 retained-local-data disposition" $ do
    it "admits only an absolute, canonical, non-shallow removal target" $ do
      -- The constructor is the guard between a configured string and a
      -- recursive removal. The depth rule refuses every shallow system
      -- directory by a property of the value rather than by a denylist a new
      -- mount point escapes.
      fmap localDataRootPath (mkLocalDataRootPath "/home/operator/prodbox/.data")
        `shouldBe` Right "/home/operator/prodbox/.data"
      fmap localDataRootPath (mkLocalDataRootPath "/srv/prodbox/.data")
        `shouldBe` Right "/srv/prodbox/.data"
      mkLocalDataRootPath ".data" `shouldBe` Left LocalDataRootNotAbsolute
      mkLocalDataRootPath "/" `shouldBe` Left LocalDataRootTooShallow
      mkLocalDataRootPath "/home" `shouldBe` Left LocalDataRootTooShallow
      mkLocalDataRootPath "/var/lib" `shouldBe` Left LocalDataRootTooShallow
      mkLocalDataRootPath "/usr/local" `shouldBe` Left LocalDataRootTooShallow
      mkLocalDataRootPath "/srv/prodbox/../.data"
        `shouldBe` Left LocalDataRootNotCanonical
      mkLocalDataRootPath "/srv/prodbox/./data"
        `shouldBe` Left LocalDataRootNotCanonical
      mkLocalDataRootPath "/srv/prodbox/\1000data\NUL"
        `shouldBe` Left LocalDataRootInvalid

    it "classifies every mandatory node exactly once, singleton or choice" $ do
      -- One classifier. `decommissionNodeSingleton` is its projection, so the
      -- required-singleton list and the mandatory-choice list cannot disagree
      -- about a node.
      decommissionNodeFamily SharedObjectBucket
        `shouldBe` MandatorySingletonFamily SingletonSharedObjectBucket
      decommissionNodeFamily (LocalDataDisposition RetainLocalData)
        `shouldBe` MandatoryChoiceFamily LocalDataDispositionFamily
      decommissionNodeFamily (LocalDataDisposition DeleteLocalData)
        `shouldBe` MandatoryChoiceFamily LocalDataDispositionFamily
      decommissionNodeSingleton (LocalDataDisposition DeleteLocalData)
        `shouldBe` Nothing
      decommissionChoiceFamilyBijection `shouldBe` True
      decommissionTerminalPhaseBijection `shouldBe` True
      decommissionChoiceFamilyRepresentative LocalDataDispositionFamily
        `shouldBe` LocalDataDisposition RetainLocalData
      mandatoryDecommissionChoiceNodes DeleteLocalData
        `shouldBe` [LocalDataDisposition DeleteLocalData]

    it "refuses a plan that omits, or doubles, the operator's decision" $ do
      let complete = productionDecommissionPlanNodes DeleteLocalData []
      validateDecommissionPlanCardinality complete `shouldBe` Right ()
      -- A plan with no disposition node has silently decided to retain: the
      -- run would converge without ever saying what became of the data.
      validateDecommissionPlanCardinality
        (filter (/= LocalDataDisposition DeleteLocalData) complete)
        `shouldBe` Left [DecommissionPlanChoiceMissing LocalDataDispositionFamily]
      -- Two disposition nodes are two competing decisions for one operation.
      validateDecommissionPlanCardinality
        (complete ++ [LocalDataDisposition RetainLocalData])
        `shouldBe` Left
          [ DecommissionPlanChoiceAmbiguous
              LocalDataDispositionFamily
              [ LocalDataDisposition DeleteLocalData
              , LocalDataDisposition RetainLocalData
              ]
          ]
      -- The singleton half is unchanged and still measured by the same
      -- function.
      validateDecommissionPlanCardinality
        (filter (/= SharedObjectBucket) complete)
        `shouldBe` Left
          [DecommissionPlanSingletonMissing SingletonSharedObjectBucket]

    it "makes the decision part of the receipt identity, not a runtime flag" $ do
      -- The decision is a node parameter, so it enters the frame node id and
      -- therefore the manifest digest. A receipt opened for a `retain` run
      -- cannot be resumed as a `delete` run.
      decommissionNodeFrameId (LocalDataDisposition RetainLocalData)
        `shouldNotBe` decommissionNodeFrameId (LocalDataDisposition DeleteLocalData)
      decommissionLocalDataDispositionText RetainLocalData `shouldBe` "retain"
      decommissionLocalDataDispositionText DeleteLocalData `shouldBe` "delete"

    it "runs after the home uninstall, in the order the graph derives" $ do
      let plan = productionDecommissionPlanNodes DeleteLocalData []
      terminalPhaseRunsLastInOrder plan `shouldBe` True
      drop (length plan - 4) plan
        `shouldBe` [ FinalNoRetentionAudit
                   , HomeSubstrateUninstall
                   , LocalDataDisposition DeleteLocalData
                   , DecommissionTerminalReceipt
                   ]
      -- The enumeration's representative is not the node the plan contains,
      -- which is why the last-in-order property compares phase ranks.
      decommissionTerminalPhaseOrder
        `shouldBe` [ FinalNoRetentionAudit
                   , HomeSubstrateUninstall
                   , LocalDataDisposition RetainLocalData
                   , DecommissionTerminalReceipt
                   ]

    it "retain issues no removal at all" $ do
      removals <- newIORef ([] :: [Subprocess])
      result <-
        attemptLocalDataDisposition
          (adapter removals (pure LocalDataRootPresent))
          RetainLocalData
          operationId
      localDataDispositionOutcome result `shouldBe` LocalDataRetained
      classifyLocalDataDisposition result `shouldBe` Right ()
      -- The deleting arm is selected by the decision the manifest carries, so
      -- a capability built on a host cannot delete under a `retain` plan.
      readIORef removals `shouldReturn` []

    it "delete removes the exact root under the stable operation identity" $ do
      removals <- newIORef ([] :: [Subprocess])
      result <-
        attemptLocalDataDisposition
          (adapter removals (pure LocalDataRootPresent))
          DeleteLocalData
          operationId
      localDataDispositionOutcome result `shouldBe` LocalDataRemovalApplied
      classifyLocalDataDisposition result `shouldBe` Right ()
      issued <- readIORef removals
      map subprocessPath issued `shouldBe` ["/usr/bin/sudo"]
      concatMap subprocessArguments issued
        `shouldContain` ["PRODBOX_CLEANUP_OPERATION_ID=stable-attempt"]
      concatMap subprocessArguments issued
        `shouldContain` ["/srv/prodbox/.data"]

    it "delete over an already-absent root issues no removal" $ do
      removals <- newIORef ([] :: [Subprocess])
      result <-
        attemptLocalDataDisposition
          (adapter removals (pure (LocalDataRootAbsent (AbsenceEvidence "gone"))))
          DeleteLocalData
          operationId
      localDataDispositionOutcome result
        `shouldBe` LocalDataAlreadyAbsent (AbsenceEvidence "gone")
      classifyLocalDataDisposition result `shouldBe` Right ()
      readIORef removals `shouldReturn` []

    it "keeps response loss, refusal, and an unobservable root distinct" $ do
      removals <- newIORef ([] :: [Subprocess])
      -- A lost response is not evidence the removal did not run, so it is a
      -- failure of this attempt rather than a refusal: the runner resumes by
      -- re-observing the root under the same operation.
      lost <-
        attemptLocalDataDisposition
          (adapterWith removals (pure LocalDataRootPresent) (const (pure (Left "pipe closed"))))
          DeleteLocalData
          operationId
      localDataDispositionOutcome lost
        `shouldBe` LocalDataRemovalResponseLost "pipe closed"
      classifyLocalDataDisposition lost `shouldSatisfy` isLeft
      failed <-
        attemptLocalDataDisposition
          ( adapterWith
              removals
              (pure LocalDataRootPresent)
              (const (pure (Right (output (ExitFailure 1) "" "permission denied"))))
          )
          DeleteLocalData
          operationId
      localDataDispositionOutcome failed
        `shouldBe` LocalDataDispositionRefused
          (LocalDataDispositionRemovalFailed (ExitFailure 1) "permission denied")
      -- An unobservable root refuses before any removal: the adapter will not
      -- remove a tree it could not first observe.
      unobservable <-
        attemptLocalDataDisposition
          (adapter removals (pure (LocalDataRootUnobservable "EACCES")))
          DeleteLocalData
          operationId
      localDataDispositionOutcome unobservable
        `shouldBe` LocalDataDispositionRefused
          (LocalDataDispositionObservationUnconfirmed "EACCES")

    it "refuses a signed disposition the operator did not request" $ do
      -- The cardinality check proves exactly one disposition node is present.
      -- This proves it carries the decision the operator actually typed:
      -- without it a defective or compromised Authority could sign `retain`
      -- over an operator's `delete` and the run would converge reporting
      -- success.
      validateProductionManifest verifier DeleteLocalData (verifiedPlan DeleteLocalData)
        `shouldBe` Right ()
      validateProductionManifest verifier RetainLocalData (verifiedPlan RetainLocalData)
        `shouldBe` Right ()
      validateProductionManifest verifier DeleteLocalData (verifiedPlan RetainLocalData)
        `shouldSatisfy` isLeft
      validateProductionManifest verifier RetainLocalData (verifiedPlan DeleteLocalData)
        `shouldSatisfy` isLeft
      -- And an incomplete plan is refused by the derived cardinality rather
      -- than by an authored missing-node list.
      validateProductionManifest
        verifier
        DeleteLocalData
        (verifiedNodes (filter (/= SharedObjectBucket) (planNodes DeleteLocalData)))
        `shouldSatisfy` isLeft

    it "reads the disposition back in both directions" $ do
      -- ResidueAbsent means the decision was honoured, which is the only
      -- reading the node classifier accepts. The residue a `retain` run
      -- reports is therefore a MISSING root.
      residue DeleteLocalData (LocalDataRootAbsent (AbsenceEvidence "gone"))
        `shouldBe` ResidueAbsent
      residue RetainLocalData LocalDataRootPresent `shouldBe` ResidueAbsent
      residue DeleteLocalData LocalDataRootPresent `shouldSatisfy` isResiduePresent
      residue RetainLocalData (LocalDataRootAbsent (AbsenceEvidence "gone"))
        `shouldSatisfy` isResiduePresent
      -- An absence nobody observed is not a disposition anybody honoured.
      residue DeleteLocalData (LocalDataRootUnobservable "EACCES")
        `shouldSatisfy` isResidueUnreachable
      residue RetainLocalData (LocalDataRootUnobservable "EACCES")
        `shouldSatisfy` isResidueUnreachable
 where
  residue disposition observed =
    localDataDispositionResidue testRoot disposition observed

  isResiduePresent status = case status of
    ResiduePresent _ -> True
    _ -> False

  isResidueUnreachable status = case status of
    ResidueUnreachable _ -> True
    _ -> False

  adapter removals observe =
    adapterWith removals observe (const (pure (Right (output ExitSuccess "" ""))))

  adapterWith removals observe execute =
    mkLocalDataTerminalAdapter
      testRoot
      "/srv/prodbox"
      LocalDataTerminalBoundary
        { localDataObserveRoot = observe
        , localDataExecuteRemoval = \_operation spec -> do
            modifyIORef' removals (<> [spec])
            execute spec
        }

output :: ExitCode -> String -> String -> ProcessOutput
output exitCode out err =
  ProcessOutput
    { processExitCode = exitCode
    , processStdout = out
    , processStderr = err
    }

testRoot :: LocalDataRootPath
testRoot = mustRoot "/srv/prodbox/.data"

operationId :: CleanupOperationId
operationId = case mkCleanupOperationId "stable-attempt" of
  Right value -> value
  Left detail -> error ("invalid fixture operation id: " <> show (detail :: Text))

mustRoot :: FilePath -> LocalDataRootPath
mustRoot path = case mkLocalDataRootPath path of
  Right root -> root
  Left err -> error ("invalid fixture local data root: " <> show err)

planNodes :: DecommissionLocalDataDisposition -> [DecommissionNode]
planNodes disposition = productionDecommissionPlanNodes disposition []

verifiedPlan :: DecommissionLocalDataDisposition -> VerifiedDecommissionManifest
verifiedPlan = verifiedNodes . planNodes

verifiedNodes :: [DecommissionNode] -> VerifiedDecommissionManifest
verifiedNodes nodes =
  mustFixture
    ( verifySignedDecommissionManifest
        (manifestPublicKeyDigest publicKey)
        (signDecommissionManifest signingKey plan verifier)
    )
 where
  plan = mustFixture (mkDecommissionManifest "home" nodes)

signingKey :: ManifestSigningKey
signingKey = mustFixture (mkManifestSigningKey (ByteString.pack [0 .. 31]))

publicKey :: ManifestPublicKey
publicKey = manifestSigningPublicKey signingKey

verifier :: VerifierBinding
verifier = verifierBindingOf artifactPath artifact

artifactPath :: ExternalArtifactPath
artifactPath =
  mustFixture (mkExternalArtifactPath "/tmp/prodbox-export/decommission-runner")

artifact :: VerifierArtifact
artifact = mustFixture (mkVerifierArtifact "runner-build-v1" "dependency-v1" metadata)

metadata :: VerifierMetadata
metadata =
  mustFixture
    ( mkVerifierMetadata
        (contentDigest "dependency-v1")
        1
        (contentDigest "manifest-schema-v1")
        1
        (contentDigest "interpreter-registry-v1")
    )

mustFixture :: (Show err) => Either err value -> value
mustFixture result = case result of
  Right value -> value
  Left err -> error ("invalid local-data disposition fixture: " <> show err)
