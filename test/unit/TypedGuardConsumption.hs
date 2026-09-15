-- | Sprint 5.47: the declared-but-unconsumed cleanup-authority guard gate.
--
-- Every direction is exercised against a synthetic violation, because a gate
-- that can only be run against the tree it already passes on has been observed
-- to pass and never to refuse. The last case runs the real gate over the real
-- worktree, so the committed registry is proven to describe this revision.
module TypedGuardConsumption
  ( typedGuardConsumptionSuite
  )
where

import Data.List (isInfixOf)
import Prodbox.CheckCode
  ( UnconsumedTypedGuard (..)
  , checkTypedGuardConsumption
  , namesCleanupAuthority
  , typedGuardConsumptionFindings
  , typedGuardConsumptionsIn
  , typedGuardDeclarationsIn
  , unconsumedTypedGuardRegistry
  )
import System.Directory (getCurrentDirectory)
import TestSupport

ownerPath :: FilePath
ownerPath = "src/Prodbox/Owned.hs"

otherPath :: FilePath
otherPath = "src/Prodbox/Other.hs"

registeredGuard :: UnconsumedTypedGuard
registeredGuard =
  UnconsumedTypedGuard
    { unconsumedGuardSymbol = "confirmFixtureAbsence"
    , unconsumedGuardOwner = ownerPath
    , unconsumedGuardLedgerRow = "a fixture ledger row"
    , unconsumedGuardConsumptionCondition = "the fixture sprint wires it"
    }

findingsFor
  :: [UnconsumedTypedGuard]
  -> [FilePath]
  -> [(FilePath, [String])]
  -> [(FilePath, [String])]
  -> [(FilePath, [String])]
  -> [String]
findingsFor = typedGuardConsumptionFindings

typedGuardConsumptionSuite :: SuiteBuilder ()
typedGuardConsumptionSuite =
  describe "Sprint 5.47 cleanup-authority guard consumption" $ do
    describe "the bijection refuses in every direction" $ do
      it "fails an unconsumed authority guard that no registry row names" $
        findingsFor
          []
          [ownerPath, otherPath]
          [(ownerPath, ["confirmFixtureAbsence"])]
          [(ownerPath, []), (otherPath, [])]
          [(ownerPath, ["confirmFixtureAbsence"])]
          `shouldSatisfy` any ("no module under `src/` reads it" `isInfixOf`)

      it "admits an unconsumed authority guard its registry names" $
        findingsFor
          [registeredGuard]
          [ownerPath, otherPath]
          [(ownerPath, ["confirmFixtureAbsence"])]
          [(ownerPath, []), (otherPath, [])]
          [(ownerPath, ["confirmFixtureAbsence"])]
          `shouldBe` []

      it "admits an authority guard a production module reads" $
        findingsFor
          []
          [ownerPath, otherPath]
          [(ownerPath, ["confirmFixtureAbsence"])]
          [(ownerPath, []), (otherPath, ["confirmFixtureAbsence"])]
          [(ownerPath, ["confirmFixtureAbsence"])]
          `shouldBe` []

      it "fails a registry row whose symbol its owner no longer names" $
        findingsFor
          [registeredGuard]
          [ownerPath, otherPath]
          [(ownerPath, [])]
          [(ownerPath, []), (otherPath, [])]
          [(ownerPath, ["somethingElse"])]
          `shouldSatisfy` any ("which no longer names it" `isInfixOf`)

      it "fails a registry row whose symbol has gained a production consumer" $
        findingsFor
          [registeredGuard]
          [ownerPath, otherPath]
          [(ownerPath, ["confirmFixtureAbsence"])]
          [(ownerPath, []), (otherPath, ["confirmFixtureAbsence"])]
          [(ownerPath, ["confirmFixtureAbsence"])]
          `shouldSatisfy` any ("it is consumed now" `isInfixOf`)

      it "names the ledger row a consumed entry must close" $
        findingsFor
          [registeredGuard]
          [ownerPath, otherPath]
          [(ownerPath, ["confirmFixtureAbsence"])]
          [(ownerPath, []), (otherPath, ["confirmFixtureAbsence"])]
          [(ownerPath, ["confirmFixtureAbsence"])]
          `shouldSatisfy` any ("a fixture ledger row" `isInfixOf`)

      it "fails when a declared owner is not in the scanned set at all" $
        -- A rename must not silently empty the gate's region.
        findingsFor
          [registeredGuard]
          [otherPath]
          [(otherPath, [])]
          [(otherPath, [])]
          [(otherPath, [])]
          `shouldSatisfy` any ("is scoped to" `isInfixOf`)

    describe "what counts as a declaration" $ do
      it "reads the leading-arrow signature spelling" $
        typedGuardDeclarationsIn
          ( unlines
              [ "module Prodbox.Owned"
              , "  ( confirmFixtureAbsence"
              , "  )"
              , "where"
              , ""
              , "confirmFixtureAbsence"
              , "  :: FixtureRequest"
              , "  -> Either FixtureError (AbsenceEvidence 'ProviderApi)"
              , "confirmFixtureAbsence request = Left (fixtureError request)"
              ]
          )
          `shouldBe` ["confirmFixtureAbsence"]

      it "reads a record field of a declaration that derives nothing" $
        typedGuardDeclarationsIn
          ( unlines
              [ "module Prodbox.Owned where"
              , ""
              , "data FixtureRecord = FixtureRecord"
              , "  { fixtureAction :: FilePath -> IO ()"
              , "  , fixtureAbsence :: !(AbsenceEvidence 'HostLocal)"
              , "  }"
              ]
          )
          `shouldBe` ["fixtureAbsence"]

      it "does not read a record field whose declaration derives" $
        -- A derived instance observes every field, so the field is consumed
        -- whether or not a selector is ever called.
        typedGuardDeclarationsIn
          ( unlines
              [ "module Prodbox.Owned where"
              , ""
              , "data FixtureRecord = FixtureRecord"
              , "  { fixtureAbsence :: !(AbsenceEvidence 'HostLocal)"
              , "  }"
              , "  deriving (Eq, Show)"
              ]
          )
          `shouldBe` []

      it "matches an authority type name as a whole identifier" $ do
        namesCleanupAuthority "Either Text (AbsenceEvidence 'HostLocal)" `shouldBe` True
        namesCleanupAuthority "Either Text CascadeAbsenceEvidence" `shouldBe` False

      it "requires a promoted index the registry names" $ do
        namesCleanupAuthority "Either String (CapabilityRef 'ManagedDestroy)" `shouldBe` True
        namesCleanupAuthority "Either String (CapabilityRef 'ManagedObserve)" `shouldBe` False

    describe "what counts as a consumption" $ do
      it "counts an ordinary call" $
        typedGuardConsumptionsIn
          ["confirmFixtureAbsence"]
          ( unlines
              [ "module Prodbox.Other where"
              , ""
              , "reconcile request ="
              , "  case confirmFixtureAbsence request of"
              , "    Left err -> Left err"
              , "    Right evidence -> Right evidence"
              ]
          )
          `shouldBe` ["confirmFixtureAbsence"]

      it "does not count an export list, an import, or a signature" $
        typedGuardConsumptionsIn
          ["confirmFixtureAbsence"]
          ( unlines
              [ "module Prodbox.Owned"
              , "  ( confirmFixtureAbsence"
              , "  )"
              , "where"
              , ""
              , "import Prodbox.Elsewhere"
              , "  ( confirmFixtureAbsence"
              , "  )"
              , ""
              , "confirmFixtureAbsence"
              , "  :: FixtureRequest"
              , "  -> Either FixtureError (AbsenceEvidence 'ProviderApi)"
              , "confirmFixtureAbsence request = Left (fixtureError request)"
              ]
          )
          `shouldBe` []

      it "does not count a field written into a record literal" $
        typedGuardConsumptionsIn
          ["fixtureAbsence"]
          ( unlines
              [ "module Prodbox.Other where"
              , ""
              , "assemble evidence ="
              , "  FixtureRecord"
              , "    { fixtureAbsence = evidence"
              , "    }"
              ]
          )
          `shouldBe` []

      it "counts a field read through its selector" $
        typedGuardConsumptionsIn
          ["fixtureAbsence"]
          ( unlines
              [ "module Prodbox.Other where"
              , ""
              , "report record ="
              , "  renderAbsence (fixtureAbsence record)"
              ]
          )
          `shouldBe` ["fixtureAbsence"]

      it "does not count a frozen-regression self-test, even across a comment" $
        -- The strongest absence rule in the tree was asserted by exactly such a
        -- boolean and reached no decision, which is the distinction this rule
        -- exists to make. The comment matters: comments are blanked before the
        -- scan, so a body that ends at one would leak the rest of the body in.
        typedGuardConsumptionsIn
          ["confirmFixtureAbsence"]
          ( unlines
              [ "module Prodbox.Other where"
              , ""
              , "fixedFixtureAbsenceRegression :: Bool"
              , "fixedFixtureAbsenceRegression ="
              , "  isRight (confirmFixtureAbsence absentRequest)"
              , "    -- the refusal arm is the half that matters"
              , "    && isLeft (confirmFixtureAbsence presentRequest)"
              ]
          )
          `shouldBe` []

      it "counts a production caller in the same module as a self-test" $
        -- The skipped shape is the binder, not the module.
        typedGuardConsumptionsIn
          ["confirmFixtureAbsence"]
          ( unlines
              [ "module Prodbox.Other where"
              , ""
              , "fixedFixtureAbsenceRegression :: Bool"
              , "fixedFixtureAbsenceRegression ="
              , "  isRight (confirmFixtureAbsence absentRequest)"
              , ""
              , "reconcile request ="
              , "  confirmFixtureAbsence request"
              ]
          )
          `shouldBe` ["confirmFixtureAbsence"]

    describe "the committed registry describes this worktree" $ do
      it "matches the real repository" $ do
        repoRoot <- getCurrentDirectory
        violations <- checkTypedGuardConsumption repoRoot
        violations `shouldBe` []

      it "registers every row against a named deletion-ledger row" $
        filter (null . unconsumedGuardLedgerRow) unconsumedTypedGuardRegistry
          `shouldBe` []

      it "registers every row with a stated consumption condition" $
        filter (null . unconsumedGuardConsumptionCondition) unconsumedTypedGuardRegistry
          `shouldBe` []
