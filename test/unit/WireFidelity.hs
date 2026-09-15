-- | Sprint 5.47: the wire-fidelity rule -- a serialised sum may not lose arms
-- its in-process type distinguishes.
--
-- Every direction is exercised against a synthetic module, including the two
-- shapes the rule must NOT report: a pair of arms whose shared text contains a
-- pattern-bound variable, and a catch-all that delegates to another function.
-- Both were measured false positives in the first draft, and a rule that
-- cannot be shown to stay quiet is not a rule anybody can trust with a
-- registry.
module WireFidelity
  ( wireFidelitySuite
  )
where

import Data.List (isInfixOf)
import Prodbox.CheckCode
  ( RenderingArm (..)
  , checkWireFidelity
  , renderingArmsIn
  , signatureResultType
  , sumTypeIndexIn
  , wireFidelityExemptions
  , wireFidelityStaleExemptions
  , wireFidelityViolations
  )
import System.Directory (getCurrentDirectory)
import TestSupport

modulePath :: FilePath
modulePath = "src/Prodbox/Synthetic.hs"

fixtureSum :: (String, [String])
fixtureSum = ("FixtureCause", ["FixtureRefused", "FixtureUnobservable", "FixtureAbsent"])

renderingModule :: [String] -> String
renderingModule bodyLines =
  unlines
    ( [ "module Prodbox.Synthetic where"
      , ""
      , "renderFixtureCause :: FixtureCause -> Text"
      ]
        ++ bodyLines
    )

violationsFor :: [(FilePath, String, String)] -> [String] -> [String]
violationsFor exemptions bodyLines =
  wireFidelityViolations exemptions [fixtureSum] (modulePath, renderingModule bodyLines)

wireFidelitySuite :: SuiteBuilder ()
wireFidelitySuite =
  describe "Sprint 5.47 wire fidelity" $ do
    describe "the rule refuses a lost arm" $ do
      it "refuses two constructors rendered to one literal" $
        violationsFor
          []
          [ "renderFixtureCause cause = case cause of"
          , "  FixtureRefused -> \"refused\""
          , "  FixtureUnobservable -> \"refused\""
          , "  FixtureAbsent -> \"absent\""
          ]
          `shouldSatisfy` any ("to the same wire value \"refused\"" `isInfixOf`)

      it "names every arm sharing the value once, not every pair" $
        -- A three-valued classifier over fourteen constructors has ninety-one
        -- pairs and one decision to make about it.
        violationsFor
          []
          [ "renderFixtureCause cause = case cause of"
          , "  FixtureRefused -> \"refused\""
          , "  FixtureUnobservable -> \"refused\""
          , "  FixtureAbsent -> \"refused\""
          ]
          `shouldSatisfy` ((== 1) . length)

      it "refuses a catch-all to a literal over an incompletely written type" $
        violationsFor
          []
          [ "renderFixtureCause cause = case cause of"
          , "  FixtureAbsent -> \"absent\""
          , "  _ -> \"something-went-wrong\""
          ]
          `shouldSatisfy` any ("collapsing 2 of `FixtureCause`'s 3 constructors" `isInfixOf`)

      it "refuses a catch-all to the empty string, where absence is implied" $
        violationsFor
          []
          [ "renderFixtureCause cause = case cause of"
          , "  FixtureAbsent -> \"absent\""
          , "  _ -> \"\""
          ]
          `shouldSatisfy` any ("with a catch-all to \"\"" `isInfixOf`)

    describe "the rule stays quiet where it must" $ do
      it "admits distinct literals" $
        violationsFor
          []
          [ "renderFixtureCause cause = case cause of"
          , "  FixtureRefused -> \"refused\""
          , "  FixtureUnobservable -> \"unobservable\""
          , "  FixtureAbsent -> \"absent\""
          ]
          `shouldBe` []

      it "admits arms whose shared text carries a pattern-bound variable" $
        -- `detail` is bound by each arm's own pattern, so the rendered bytes
        -- differ. Reading a shared literal prefix as a shared value reported a
        -- third of its findings falsely.
        violationsFor
          []
          [ "renderFixtureCause cause = case cause of"
          , "  FixtureRefused detail -> \" (\" <> detail <> \")\""
          , "  FixtureUnobservable detail -> \" (\" <> detail <> \")\""
          , "  FixtureAbsent -> \"absent\""
          ]
          `shouldBe` []

      it "admits a catch-all that delegates to another function" $
        -- The delegate is frequently total over the same sum. Suppressing this
        -- is a stated false negative, not a claim that the shape is safe.
        violationsFor
          []
          [ "renderFixtureCause cause = case cause of"
          , "  FixtureAbsent -> \"absent\""
          , "  _ -> classifyFixtureCause cause"
          ]
          `shouldBe` []

      it "admits a function whose result is not a wire scalar" $
        wireFidelityViolations
          []
          [fixtureSum]
          ( modulePath
          , unlines
              [ "module Prodbox.Synthetic where"
              , ""
              , "classifyFixtureCause :: FixtureCause -> FixtureClass"
              , "classifyFixtureCause cause = case cause of"
              , "  FixtureRefused -> FixtureBad"
              , "  FixtureUnobservable -> FixtureBad"
              , "  FixtureAbsent -> FixtureGood"
              ]
          )
          `shouldBe` []

    describe "the exemption registry" $ do
      it "suppresses a registered site" $
        violationsFor
          [(modulePath, "renderFixtureCause", "the collapse is the contract")]
          [ "renderFixtureCause cause = case cause of"
          , "  FixtureRefused -> \"refused\""
          , "  FixtureUnobservable -> \"refused\""
          , "  FixtureAbsent -> \"absent\""
          ]
          `shouldBe` []

      it "refuses an exemption the rule no longer reports" $
        wireFidelityStaleExemptions
          [(modulePath, "renderFixtureCause", "the collapse is the contract")]
          []
          `shouldSatisfy` any ("Delete the stale exemption" `isInfixOf`)

      it "admits an exemption the rule still reports" $
        wireFidelityStaleExemptions
          [(modulePath, "renderFixtureCause", "the collapse is the contract")]
          (violationsFor [] renderedCollapse)
          `shouldBe` []

      it "states a reason on every registered site" $
        filter (\(_, _, reason) -> null reason) wireFidelityExemptions `shouldBe` []

    describe "the parser the rule is built on" $ do
      it "reads the result component of a signature at arrow depth zero" $ do
        signatureResultType " FixtureCause -> Text" `shouldBe` "Text"
        signatureResultType " (FixtureCause -> Text) -> FixtureClass" `shouldBe` "FixtureClass"

      it "reads a catch-all head, which shares its span with a constructor" $
        renderingArmsIn ["  _ -> \"collapsed\""]
          `shouldBe` [RenderingArm "_" "\"collapsed\""]

      it "drops a type name two modules both declare" $
        -- Without a typechecker there is no sound way to say which one an arm
        -- is matching, and refusing to judge is the honest answer.
        sumTypeIndexIn
          [ ("src/Prodbox/One.hs", "data FixtureCause = FixtureRefused | FixtureAbsent\n")
          , ("src/Prodbox/Two.hs", "data FixtureCause = FixtureOther | FixtureAbsent\n")
          ]
          `shouldBe` []

      it "indexes a type exactly one module declares" $
        sumTypeIndexIn
          [
            ( "src/Prodbox/One.hs"
            , "data FixtureCause\n  = FixtureRefused\n  | FixtureAbsent\n  deriving (Eq, Show)\n"
            )
          ]
          `shouldBe` [("FixtureCause", ["FixtureRefused", "FixtureAbsent"])]

    describe "the committed registry describes this worktree" $
      it "matches the real repository" $ do
        repoRoot <- getCurrentDirectory
        violations <- checkWireFidelity repoRoot
        violations `shouldBe` []
 where
  renderedCollapse =
    [ "renderFixtureCause cause = case cause of"
    , "  FixtureRefused -> \"refused\""
    , "  FixtureUnobservable -> \"refused\""
    , "  FixtureAbsent -> \"absent\""
    ]
