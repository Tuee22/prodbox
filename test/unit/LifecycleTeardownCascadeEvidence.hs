module LifecycleTeardownCascadeEvidence
  ( lifecycleTeardownCascadeEvidenceSuite
  )
where

import Control.Monad (filterM)
import Data.List (isInfixOf, isSuffixOf, sort)
import Prodbox.Lifecycle.Teardown.CascadeEvidence
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath ((</>))
import TestSupport

lifecycleTeardownCascadeEvidenceSuite :: SuiteBuilder ()
lifecycleTeardownCascadeEvidenceSuite =
  describe "Sprint 4.85 cascade uninstall and completion evidence" $ do
    it "keeps the complete proof chain behind one nullary non-authorizing regression" $ do
      regression <- expectRight fixedCascadeEvidenceRegression
      cascadeEvidenceRegressionCompleteChain regression `shouldBe` True
      cascadeEvidenceRegressionAbsenceRefused regression `shouldBe` True
      cascadeEvidenceRegressionCredentialRefused regression `shouldBe` True
      cascadeEvidenceRegressionAuditRefused regression `shouldBe` True
      cascadeEvidenceRegressionPreUninstallRefused regression `shouldBe` True
      cascadeEvidenceRegressionPermitRefused regression `shouldBe` True
      cascadeEvidenceRegressionMixedBindingRefused regression `shouldBe` True
      cascadeEvidenceRegressionLocalAbsenceRefused regression `shouldBe` True
      cascadeEvidenceRegressionCompletionRefused regression `shouldBe` True
      cascadeEvidenceRegressionDurableReadyCanonical regression `shouldBe` True
      cascadeEvidenceRegressionDurableReadyCorruptionRefused regression `shouldBe` True

    it "closes the local-only surface without letting it claim a cascade" $ do
      regression <- expectRight fixedCascadeEvidenceRegression
      -- The local-only chain closes on an observed absence and its own
      -- committed receipt: no report identity, no permit, nothing said about
      -- AWS.  Handing its evidence to `mkCascadeCompleteEvidence` is a type
      -- error rather than a runtime refusal, which is why there is no case for
      -- it: `LocalUninstallEvidence` is indexed by the surface whose compiled
      -- program licensed the uninstall, and no conversion exists in either
      -- direction.
      cascadeEvidenceRegressionLocalOnlyChainCloses regression `shouldBe` True
      -- An explicit AWS target on the local-only surface is the exact
      -- confusion the surface exists to exclude.
      cascadeEvidenceRegressionLocalOnlyAwsScopeUncompilable regression
        `shouldBe` True
      cascadeEvidenceRegressionLocalOnlyReceiptRefused regression `shouldBe` True
      cascadeEvidenceRegressionLocalOnlyAbsenceRefused regression `shouldBe` True

    it "generalises the proof binding without changing an existing proof" $ do
      regression <- expectRight fixedCascadeEvidenceRegression
      -- Sprint 4.89: the binding is indexed by cleanup surface rather than
      -- fixed to the cascade. The cascade instantiation is the value the
      -- cascade-only function produced, field for field — which is what makes
      -- the generalisation provably non-breaking — and the local-only
      -- instantiation is refused by the opposite AWS-scope rule rather than by
      -- a second implementation of the same checks.
      cascadeEvidenceRegressionBindingGeneralisationPreserving regression
        `shouldBe` True

    it "refuses readiness for a run that no longer holds a capability" $ do
      regression <- expectRight fixedCascadeEvidenceRegression
      -- Sprint 4.89 validation item 6: a run holding a lost capability fails
      -- to compose readiness, and the measurement is the composition refusing
      -- rather than a warning beside it. Custody is a component of readiness,
      -- so a lost checkpoint yields no value to hand the constructor and the
      -- refusal is reached before a report identity or a permit exists.
      cascadeEvidenceRegressionCustodyLostRefused regression `shouldBe` True
      -- A corrupt checkpoint is unobservable rather than lost, and readiness
      -- refuses it too: a capability nobody could answer for is not held.
      cascadeEvidenceRegressionCustodyUnobservableRefused regression
        `shouldBe` True
      -- An unanswered capability is not a held one. Answering only some of the
      -- capabilities the compiled run holds refuses on the set, which is what
      -- stops readiness being reached by looking at less than the run holds.
      cascadeEvidenceRegressionCustodyIncompleteRefused regression `shouldBe` True
      -- Custody binds to its run like every other component of the proof.
      cascadeEvidenceRegressionCustodyForeignBindingRefused regression
        `shouldBe` True

    it "exports only opaque proofs and read-only views" $ do
      facade <- readFile "src/Prodbox/Lifecycle/Teardown/CascadeEvidence.hs"
      let header = unlines (takeWhile (/= "where") (lines facade))
      mapM_
        (header `shouldNotContain`)
        [ "mkCascadeReportDigest"
        , "mkLocalCompletionPermitId"
        , "CascadeCredentialDispositionResult"
        , "CascadeCredentialDispositionObservation"
        , "CascadePreUninstallReportObservation"
        , "CascadeCompletionReceiptObservation"
        , "LocalCompletionPermitGrant"
        , "CascadeAbsenceEvidence"
        , "CascadeCredentialDispositionEvidence"
        , "CascadeTerminalAuditEvidence"
        , "CascadePreUninstallReportEvidence"
        , "LocalCompletionPermit (.."
        , "mkCascadeAbsenceEvidence"
        , "mkCascadeCredentialDispositionEvidence"
        , "mkCascadeTerminalAuditEvidence"
        , "mkCascadePreUninstallReportEvidence"
        , "bindLocalCompletionPermit"
        , "mkReadyToUninstallEvidence"
        , "mkLocalUninstallEvidence"
        , "mkCascadeCompleteEvidence"
        , "ReadyToUninstallEvidence (.."
        , "LocalUninstallEvidence (.."
        , "CascadeCompleteEvidence (.."
        ]
      header `shouldContain` "ReadyToUninstallEvidence"
      header `shouldContain` "CascadeCompleteEvidence"
      header `shouldContain` "fixedCascadeEvidenceRegression"

    it "keeps raw restoration and proof construction in one Cabal-hidden ownership set" $ do
      cabal <- readFile "prodbox.cabal"
      let exposedLibrary =
            unlines
              (takeWhile (/= "    hs-source-dirs:   src") (lines cabal))
      cabal
        `shouldContain` "Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal"
      exposedLibrary
        `shouldNotContain` "Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal"
      importers <-
        sourceImporters
          "src"
          "import Prodbox.Lifecycle.Teardown.CascadeEvidence.Internal"
      importers
        `shouldBe` sort
          [ -- Sprint 4.86 Authority readiness namespace.  It is the store the
            -- accepted readiness lives in, so it decodes the durable binding at
            -- the object-store seam in order to classify corrupt bytes as
            -- corrupt; it never restores a proof, which is why the opaque
            -- accepted value crosses its facade without an accessor.
            "src/Prodbox/ControlPlane/HostCleanupReadinessRepository/Internal.hs"
          , -- Sprint 4.86 Authority cascade-report namespace.  It is the store
            -- the committed report identity and the one-shot completion permit
            -- live in, so it decodes those identities at the object-store seam
            -- in order to classify a foreign or corrupt slot as such; it mints
            -- no proof, and the grant it returns is a flat external value the
            -- lifecycle side still has to bind.
            "src/Prodbox/ControlPlane/CascadeReportRepository.hs"
          , -- Sprint 4.86 Authority runner arms.  They are the only surface that
            -- captures the durable readiness binding for acceptance and
            -- restores one back into `ReadyToUninstallEvidence`, which needs the
            -- private restoration for the same reason the durable host intent
            -- does.
            "src/Prodbox/Lifecycle/HostCleanupAuthorityArms.hs"
          , -- Sprint 4.86 credential disposition.  It produces the observation
            -- only `mkCascadeCredentialDispositionEvidence` consumes, and
            -- derives its scope from the compiled run through the same
            -- accessor that constructor checks against.
            "src/Prodbox/Lifecycle/Teardown/CascadeCredentialDisposition.hs"
          , -- Sprint 4.86 terminal audit.  It produces the observation only
            -- `mkCascadeTerminalAuditEvidence` consumes, and derives the audit
            -- scope through the same function that constructor checks against,
            -- so re-deriving it outside would be a second copy that can drift.
            "src/Prodbox/Lifecycle/Teardown/CascadeTerminalAudit.hs"
          , "src/Prodbox/Lifecycle/HostCleanupIntent/Internal.hs"
          , -- Sprint 4.86 terminal node, receipt half.  It is the only
            -- surface that appends the local-completion entry and observes it
            -- back, and minting completion from that observation needs the
            -- private constructor for the same reason the absence join does.
            "src/Prodbox/Lifecycle/HostCleanupCompletion.hs"
          , -- Sprint 4.86 terminal node.  It is the only join between the
            -- marker observer, which is forbidden from naming
            -- `LocalUninstallEvidence`, and the constructor that mints it.
            "src/Prodbox/Lifecycle/HostCleanupLocalAbsence.hs"
          , "src/Prodbox/Lifecycle/HostCleanupRunner.hs"
          , "src/Prodbox/Lifecycle/Teardown/CascadeEvidence.hs"
          , -- Sprint 4.86 Stage C.  It composes readiness out of the private
            -- constructors, which is precisely what this ownership set is for:
            -- the sequence that mints `ReadyToUninstallEvidence` is inside the
            -- boundary, and every consumer of the result is outside it.
            "src/Prodbox/Lifecycle/Teardown/PreUninstallReadiness.hs"
          , -- Sprint 4.86 the rendered report.  It is admitted through the
            -- private convergence-binding check rather than merely rendered,
            -- which is the only thing that can refuse a report describing one
            -- run with another run's proofs.
            "src/Prodbox/Lifecycle/Teardown/PreUninstallReport.hs"
          , -- Sprint 4.86 Stage C independent read-back.  It builds the
            -- observation that `mkCascadePreUninstallReportEvidence` consumes
            -- and calls that constructor in its own regression, which is the
            -- same reason the credential-disposition and terminal-audit
            -- producers are in this set: it produces a value only a private
            -- constructor accepts, and mints no proof of its own.
            "src/Prodbox/Lifecycle/Teardown/PreUninstallReportBackup.hs"
          , -- Sprint 4.86 Stage C Authority commit.  It builds the
            -- `LocalCompletionPermitGrant` that `bindLocalCompletionPermit`
            -- consumes and derives the report identity a commit is checked
            -- against; like the producers above it hands a private constructor
            -- an input and mints nothing itself.
            "src/Prodbox/Lifecycle/Teardown/PreUninstallReportCommit.hs"
          , -- Sprint 4.86 Stage C composition.  It routes the three convergence
            -- evidences from the caller into the renderer and the readiness
            -- composition, and those three types have no public facade, so it
            -- names the internal module in order to mention them.  It calls no
            -- private constructor and mints no proof: every proof it handles
            -- was minted by a member of this set before it was handed one.
            "src/Prodbox/Lifecycle/Teardown/PreUninstallStageC.hs"
          , "src/Prodbox/Lifecycle/TestArtifactCleanup.hs"
          , "src/Prodbox/Lifecycle/TestArtifactIntentJournal.hs"
          ]
      hostRke2 <- readFile "src/Prodbox/Lifecycle/HostCleanupRke2.hs"
      hostRke2 `shouldNotContain` "mkLocalUninstallEvidence"
      hostRke2 `shouldNotContain` "LocalUninstallEvidence"
      -- Sprint 4.86: the completion read-back's constructor is exported so
      -- the journal observation can mint it, and that is still closed at this
      -- boundary rather than at the export list.  The record carries a receipt
      -- observation whose type lives in the hidden module above, so no module
      -- outside this library can name the constructor at all, and the runner's
      -- facade still re-exports neither that observation nor any minter.
      hostRunner <- readFile "src/Prodbox/Lifecycle/HostCleanupRunner.hs"
      hostRunner
        `shouldContain` "hostCompletionReadBackObservation :: !CascadeCompletionReceiptObservation"
      moduleHeader hostRunner
        `shouldNotContain` "CascadeCompletionReceiptObservation"
      moduleHeader hostRunner `shouldNotContain` "mkCascadeCompleteEvidence"

moduleHeader :: String -> String
moduleHeader = unlines . takeWhile (/= "where") . lines

sourceImporters :: FilePath -> String -> IO [FilePath]
sourceImporters root importNeedle = do
  paths <- sourceFiles root
  sort <$> filterM containsImport paths
 where
  containsImport path = do
    contents <- readFile path
    pure (importNeedle `isInfixOf` contents)

sourceFiles :: FilePath -> IO [FilePath]
sourceFiles path = do
  directory <- doesDirectoryExist path
  if directory
    then do
      children <- listDirectory path
      concat <$> mapM (sourceFiles . (path </>)) children
    else pure [path | ".hs" `isSuffixOf` path]

expectRight :: (Show err) => Either err value -> IO value
expectRight result = case result of
  Left err -> expectationFailure (show err) >> error "unreachable"
  Right value -> pure value
