-- | Sprint 6.5: the rule that keeps an unconstructibility claim true.
--
-- Several written claims in this repository say a state cannot be built from
-- outside its module — a dual-writer cutover state, a post-activation rollback,
-- an execute step called without the read-back that authorizes it. Each is true
-- only while the type's constructors stay unexported, and each is untestable in
-- the ordinary way: the test that would notice is the one that cannot be
-- written, because there is nothing to call.
--
-- So the property is checked where it actually lives, in the export list. These
-- cases exercise both directions, because a registry that only reports leaks
-- decays into a list of names nothing checks.
module SealedConstructors
  ( sealedConstructorsSuite
  )
where

import Data.List (isInfixOf)
import Prodbox.CheckCode
  ( FacadeWithholding (..)
  , SealedConstructorOrigin (..)
  , SealedConstructorType (..)
  , checkFacadeWithholdings
  , checkSealedConstructors
  , exportListExposesConstructors
  , exportListNamesType
  , facadeWithholdingRegistry
  , facadeWithholdingViolations
  , moduleExportListIn
  , sealedConstructorRegistry
  , sealedConstructorViolations
  )
import System.Directory (getCurrentDirectory)
import TestSupport

modulePath :: FilePath
modulePath = "src/Prodbox/Synthetic.hs"

registeredRow :: SealedConstructorType
registeredRow =
  SealedConstructorType
    modulePath
    "FixtureProof"
    SealedDeclaredHere
    "the fixture's claim rests on it"

facadePath :: FilePath
facadePath = "src/Prodbox/Synthetic/Facade.hs"

originPath :: FilePath
originPath = "src/Prodbox/Synthetic/Internal.hs"

-- | The repository's usual shape: an internal module declares the type and
-- exports its constructors to its own family; a public facade re-exports it
-- abstractly, and the claim lives in the facade's export list.
reExportedRow :: SealedConstructorType
reExportedRow =
  SealedConstructorType
    facadePath
    "FixtureProof"
    (SealedReExportedFrom originPath)
    "the facade's claim rests on it"

internalModule :: String
internalModule =
  unlines
    [ "module Prodbox.Synthetic.Internal"
    , "  ( FixtureProof (..)"
    , "  )"
    , "where"
    , ""
    , "data FixtureProof = FixtureProof Int"
    ]

facadeModule :: String -> String
facadeModule exportEntry =
  unlines
    [ "module Prodbox.Synthetic.Facade"
    , "  ( " ++ exportEntry
    , "  )"
    , "where"
    , ""
    , "import Prodbox.Synthetic.Internal (FixtureProof (..))"
    ]

sealedModule :: String -> String
sealedModule exportEntry =
  unlines
    [ "module Prodbox.Synthetic"
    , "  ( " ++ exportEntry
    , "  , proveFixture"
    , "  )"
    , "where"
    , ""
    , "data FixtureProof = FixtureProof Int"
    , ""
    , "proveFixture :: Int -> Maybe FixtureProof"
    , "proveFixture value = Just (FixtureProof value)"
    ]

violationsFor :: String -> [String]
violationsFor contents =
  sealedConstructorViolations [(modulePath, contents)] registeredRow

sealedConstructorsSuite :: SuiteBuilder ()
sealedConstructorsSuite =
  describe "Sprint 6.5 sealed constructors" $ do
    describe "the rule refuses a leaked constructor" $ do
      it "refuses an export list that names the constructors with (..)" $
        violationsFor (sealedModule "FixtureProof (..)")
          `shouldSatisfy` any ("exports `FixtureProof` with its constructors" `isInfixOf`)

      it "refuses an export list that names one constructor explicitly" $
        -- Exporting one is the same defect as exporting all of them: the value
        -- becomes constructible from outside either way.
        violationsFor (sealedModule "FixtureProof (FixtureProof)")
          `shouldSatisfy` any ("exports `FixtureProof` with its constructors" `isInfixOf`)

      it "refuses whatever spacing the export is written with" $
        violationsFor (sealedModule "FixtureProof  ( .. )")
          `shouldSatisfy` any ("exports `FixtureProof` with its constructors" `isInfixOf`)

      it "carries the reason the seal is load-bearing into the refusal" $
        violationsFor (sealedModule "FixtureProof (..)")
          `shouldSatisfy` any ("the fixture's claim rests on it" `isInfixOf`)

    describe "the rule stays quiet where it must" $ do
      it "admits an abstract export" $
        violationsFor (sealedModule "FixtureProof") `shouldBe` []

      it "does not read a longer type name as this one" $
        -- `FixtureProofBundle (..)` is a different type, and reading it as this
        -- one would refuse a module that is correct.
        sealedConstructorViolations
          [
            ( modulePath
            , unlines
                [ "module Prodbox.Synthetic"
                , "  ( FixtureProof"
                , "  , FixtureProofBundle (..)"
                , "  )"
                , "where"
                , ""
                , "data FixtureProof = FixtureProof Int"
                , "data FixtureProofBundle = FixtureProofBundle Int"
                ]
            )
          ]
          registeredRow
          `shouldBe` []

      it "reads only the module header, never a later occurrence" $
        -- A comment or a string elsewhere in the file that happens to read
        -- `FixtureProof (..)` is not an export list.
        sealedConstructorViolations
          [
            ( modulePath
            , unlines
                [ "module Prodbox.Synthetic"
                , "  ( FixtureProof"
                , "  )"
                , "where"
                , ""
                , "data FixtureProof = FixtureProof Int"
                , ""
                , "-- Do not export FixtureProof (..) from here."
                ]
            )
          ]
          registeredRow
          `shouldBe` []

    describe "the registry cannot rot" $ do
      it "refuses a row whose module is not in the scanned set" $
        sealedConstructorViolations [] registeredRow
          `shouldSatisfy` any (modulePath `isInfixOf`)

      it "refuses a row whose module no longer declares the type" $
        violationsFor
          ( unlines
              [ "module Prodbox.Synthetic"
              , "  ( FixtureProof"
              , "  )"
              , "where"
              , ""
              , "import Prodbox.Elsewhere (FixtureProof)"
              ]
          )
          `shouldSatisfy` any ("no longer declares it" `isInfixOf`)

      it "refuses a row whose module no longer exports the type" $
        -- A type nobody outside can name needs no seal, and a row still
        -- claiming one is a claim about a module that moved on.
        violationsFor
          ( unlines
              [ "module Prodbox.Synthetic"
              , "  ( proveFixture"
              , "  )"
              , "where"
              , ""
              , "data FixtureProof = FixtureProof Int"
              ]
          )
          `shouldSatisfy` any ("no longer exports it" `isInfixOf`)

      it "refuses a module with no export list at all, which exports everything" $
        violationsFor
          ( unlines
              [ "module Prodbox.Synthetic where"
              , ""
              , "data FixtureProof = FixtureProof Int"
              ]
          )
          `shouldSatisfy` any ("exports everything it defines" `isInfixOf`)

      it "states a reason on every registered row" $
        map
          sealedConstructorTypeName
          (filter (null . sealedConstructorReason) sealedConstructorRegistry)
          `shouldBe` []

    describe "a facade seals what its internal module declares" $ do
      it "admits a facade that re-exports the type abstractly" $
        sealedConstructorViolations
          [(originPath, internalModule), (facadePath, facadeModule "FixtureProof")]
          reExportedRow
          `shouldBe` []

      it "refuses a facade that re-exports the constructors" $
        -- The internal module exporting them is the point of an internal
        -- module; the facade doing it is the defect.
        sealedConstructorViolations
          [(originPath, internalModule), (facadePath, facadeModule "FixtureProof (..)")]
          reExportedRow
          `shouldSatisfy` any ("exports `FixtureProof` with its constructors" `isInfixOf`)

      it "refuses a row whose named origin no longer declares the type" $
        -- A facade can go on re-exporting a name long after the declaration it
        -- was sealing moved, and the seal would still read as held.
        sealedConstructorViolations
          [
            ( originPath
            , unlines
                [ "module Prodbox.Synthetic.Internal"
                , "  ( FixtureProof"
                , "  )"
                , "where"
                , ""
                , "import Prodbox.Elsewhere (FixtureProof)"
                ]
            )
          , (facadePath, facadeModule "FixtureProof")
          ]
          reExportedRow
          `shouldSatisfy` any ("no longer declares it" `isInfixOf`)

      it "names the origin, not the facade, when the declaration is gone" $
        sealedConstructorViolations
          [(facadePath, facadeModule "FixtureProof")]
          reExportedRow
          `shouldSatisfy` any (originPath `isInfixOf`)

    describe "the parsers the rule is built on" $ do
      it "reads the header span and stops at its where" $
        moduleExportListIn (sealedModule "FixtureProof")
          `shouldSatisfy` maybe False (not . isInfixOf "proveFixture value")

      it "drops the module's own name, which can end with the type's" $ do
        -- Sprint 7.42. The header is joined with spaces, so a module named
        -- `…Teardown.FixtureProof` put `FixtureProof (` into the scanned text --
        -- the export list's own opening parenthesis -- and the dot before the
        -- name is not an identifier character, so the boundary check admitted
        -- it. The rule then reported a sealed type as exporting its
        -- constructors while its export list said the opposite.
        let selfNamedModule =
              unlines
                [ "module Prodbox.Synthetic.FixtureProof"
                , "  ( FixtureProof"
                , "  , proveFixture"
                , "  )"
                , "where"
                ]
        moduleExportListIn selfNamedModule
          `shouldSatisfy` maybe False (not . isInfixOf "module")
        maybe
          True
          (exportListExposesConstructors "FixtureProof")
          (moduleExportListIn selfNamedModule)
          `shouldBe` False

      it "separates naming a type from exposing its constructors" $ do
        exportListNamesType "FixtureProof" "( FixtureProof , other )" `shouldBe` True
        exportListNamesType "FixtureProof" "( FixtureProofBundle )" `shouldBe` False
        exportListExposesConstructors "FixtureProof" "( FixtureProof )" `shouldBe` False
        exportListExposesConstructors "FixtureProof" "( FixtureProof (..) )" `shouldBe` True

    describe "a facade withholds a name, not only a constructor" $ do
      -- The sibling rule. Two facades here say in their own Haddock what they
      -- keep back -- "the drive itself remains package-private ... cannot start
      -- a cascade" -- and that sentence is false the moment the name is
      -- re-exported, with nothing else changing.
      let withholdingRow =
            FacadeWithholding
              facadePath
              originPath
              ["runFixtureDrive"]
              "the facade's claim rests on it"
          originWithDrive =
            unlines
              [ "module Prodbox.Synthetic.Internal"
              , "  ( runFixtureDrive"
              , "  , fixtureDiagnostic"
              , "  )"
              , "where"
              ]
          facadeWith exports =
            unlines
              ( ["module Prodbox.Synthetic.Facade"]
                  ++ zipWith
                    (\lead entry -> lead ++ entry)
                    ("  ( " : repeat "  , ")
                    exports
                  ++ ["  )", "where"]
              )

      it "admits a facade that exports only its diagnostics" $
        facadeWithholdingViolations
          [(originPath, originWithDrive), (facadePath, facadeWith ["fixtureDiagnostic"])]
          withholdingRow
          `shouldBe` []

      it "refuses a facade that re-exports the withheld name" $
        facadeWithholdingViolations
          [ (originPath, originWithDrive)
          , (facadePath, facadeWith ["fixtureDiagnostic", "runFixtureDrive"])
          ]
          withholdingRow
          `shouldSatisfy` any ("which it is written to withhold" `isInfixOf`)

      it "carries the claim the withholding protects into the refusal" $
        facadeWithholdingViolations
          [ (originPath, originWithDrive)
          , (facadePath, facadeWith ["runFixtureDrive"])
          ]
          withholdingRow
          `shouldSatisfy` any ("the facade's claim rests on it" `isInfixOf`)

      it "refuses a row whose origin no longer exports the withheld name" $
        -- A row guarding a name nothing produces any more is guarding nothing.
        facadeWithholdingViolations
          [
            ( originPath
            , unlines
                ["module Prodbox.Synthetic.Internal", "  ( fixtureDiagnostic", "  )", "where"]
            )
          , (facadePath, facadeWith ["fixtureDiagnostic"])
          ]
          withholdingRow
          `shouldSatisfy` any ("no longer exports it" `isInfixOf`)

      it "refuses a facade with no export list, which withholds nothing" $
        facadeWithholdingViolations
          [ (originPath, originWithDrive)
          , (facadePath, "module Prodbox.Synthetic.Facade where\n")
          ]
          withholdingRow
          `shouldSatisfy` any ("withholds nothing" `isInfixOf`)

      it "does not read a longer name as the withheld one" $
        facadeWithholdingViolations
          [ (originPath, originWithDrive)
          , (facadePath, facadeWith ["runFixtureDriveSummary"])
          ]
          withholdingRow
          `shouldBe` []

      it "states a reason and at least one name on every registered row" $ do
        map
          facadeWithholdingFacadePath
          (filter (null . facadeWithholdingReason) facadeWithholdingRegistry)
          `shouldBe` []
        map
          facadeWithholdingFacadePath
          (filter (null . facadeWithholdingNames) facadeWithholdingRegistry)
          `shouldBe` []

    describe "the committed registry describes this worktree" $ do
      it "matches the real repository" $ do
        repoRoot <- getCurrentDirectory
        findings <- checkSealedConstructors repoRoot
        findings `shouldBe` []

      it "holds every facade withholding the real repository claims" $ do
        repoRoot <- getCurrentDirectory
        findings <- checkFacadeWithholdings repoRoot
        findings `shouldBe` []
