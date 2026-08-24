{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Sprint 5.30: a Tier-0 test fixture is a rendered value, not authored Dhall.
--
-- The load-bearing half of this sprint is not testable from here, deliberately:
-- "a change to 'Settings.ConfigFile' cannot reach a fixture as a runtime decode
-- failure" is a claim about the build, and its proof is a mutation — recorded
-- under Sprint @5.30@ in
-- [phase-5-canonical-test-suite.md](../../DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md)
-- — not an assertion that could live in this file. What these cases cover is
-- the part that could still rot silently: that the rendered fixture is a
-- document the production loader accepts, and that the escape hatch cannot
-- decay into "text I did not want to migrate".
module Tier0FixtureSuite (tier0FixtureSuite) where

import Control.Exception (SomeException, evaluate, try)
import Data.Either (isLeft)
import Data.List (isInfixOf)
import Prodbox.Capacity.Config (CapacitySection (..), ResourcePlan (..), ResourceVector (..))
import Prodbox.CheckCode (tier0EncoderViolations)
import Prodbox.Config.FloorDhall (loadUnencryptedBasicsAtPath)
import Prodbox.Config.Tier0
  ( ProdboxContext (..)
  , ProdboxParameters (..)
  , ProdboxProjectConfig (..)
  , defaultProjectConfig
  )
import Prodbox.Settings (loadConfigFileAtPath)
import System.Directory (doesFileExist)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import TestSupport
import Tier0Fixture

tier0FixtureSuite :: SuiteBuilder ()
tier0FixtureSuite =
  describe "Sprint 5.30 derived Tier-0 fixtures" $ do
    it "round-trips: a rendered fixture decodes back to the value it came from" $
      -- The whole point of the sprint in one assertion: the fixture and the
      -- decoder are the same record, so they cannot drift apart without the
      -- build saying so.
      withSystemTempDirectory "prodbox-tier0-fixture" $ \tmpDir -> do
        writeTier0Fixture tmpDir (tier0FixtureWithParameters syntheticConfigFile)
        loadConfigFileAtPath (tier0FixturePath tmpDir) `shouldReturn` Right syntheticConfigFile

    it "writes at the binary-sibling filename, which is named in exactly one place" $
      withSystemTempDirectory "prodbox-tier0-fixture" $ \tmpDir -> do
        writeTier0Fixture tmpDir (tier0Fixture defaultProjectConfig)
        doesFileExist (tmpDir </> "prodbox.dhall") `shouldReturn` True

    it "carries an adjusted context through to the floor the host CLI reads" $
      -- This replaces `writeRootBasics`, the fourth hand-written encoder, whose
      -- only variation from the shared envelope was the Vault address.
      withSystemTempDirectory "prodbox-tier0-fixture" $ \tmpDir -> do
        let adjusted context = context {vault_address = "http://10.0.0.99:8200"}
        writeTier0Fixture tmpDir (tier0FixtureWithContext adjusted syntheticConfigFile)
        basics <- loadUnencryptedBasicsAtPath (tier0FixturePath tmpDir)
        case basics of
          Left err -> expectationFailure ("floor read failed: " ++ err)
          Right _ -> pure ()

    it "renders an over-committed plan that still loads, and is refused by Haskell" $
      -- The division of labour Sprint `1.72` established, exercised from the
      -- fixture side: `renderProjectConfigDhall` drops the Ring-1 `assert` for a
      -- plan that cannot compile, so the document is well-formed Dhall and the
      -- refusal is the Haskell validator's — a fixture cannot accidentally
      -- assert its own invalidity at the wrong ring.
      withSystemTempDirectory "prodbox-tier0-fixture" $ \tmpDir -> do
        writeTier0Fixture tmpDir (tier0Fixture overCommittedProjectConfig)
        rendered <- readFile (tier0FixturePath tmpDir)
        rendered `shouldSatisfy` (not . isInfixOf "assert")
        result <- loadConfigFileAtPath (tier0FixturePath tmpDir)
        case result of
          Left err -> expectationFailure ("over-committed fixture failed to load: " ++ err)
          Right _ -> pure ()

    it "refuses a schema-import escape that does not import the generated schema" $ do
      -- Without this the escape decays into "text I did not want to migrate",
      -- which is the defect wearing the label of its own fix.
      honest <-
        try
          ( evaluate
              (length (tier0FixtureText (rawTier0Parameters ExercisesGeneratedSchemaImport schemaImportBody)))
          )
          :: IO (Either SomeException Int)
      honest `shouldSatisfy` (not . isLeft)
      dishonest <-
        try
          ( evaluate
              (length (tier0FixtureText (rawTier0Fixture ExercisesGeneratedSchemaImport "{ parameters = 1 }")))
          )
          :: IO (Either SomeException Int)
      dishonest `shouldSatisfy` isLeft

    it "refuses a must-not-type-check escape that does not say what it violates" $ do
      named <-
        try
          ( evaluate
              (length (tier0FixtureText (rawTier0Fixture (MustNotTypeCheckAgainst "domain.demo_ttl") "{ x = 1 }")))
          )
          :: IO (Either SomeException Int)
      named `shouldSatisfy` (not . isLeft)
      unnamed <-
        try
          (evaluate (length (tier0FixtureText (rawTier0Fixture (MustNotTypeCheckAgainst "") "{ x = 1 }"))))
          :: IO (Either SomeException Int)
      unnamed `shouldSatisfy` isLeft

    it "derives the envelope even around a raw parameters expression" $ do
      -- The hand-written wrapper this replaces spelled out the whole context
      -- record as text, including the parent-reference Optional's full type
      -- annotation. Here only the caller's own expression is text.
      let rendered = tier0FixtureText (rawTier0Parameters ExercisesGeneratedSchemaImport schemaImportBody)
      rendered `shouldSatisfy` isInfixOf "HostOrchestrator"
      rendered `shouldSatisfy` isInfixOf schemaImportBody

    it "refuses a test that writes hand-authored text at the Tier-0 filename" $ do
      -- The `dev check` rule, exercised as a pure function. Its bound is stated
      -- rather than implied: it is line-local, and a mention is not a write.
      let fixtureModule = "renderProjectConfigDhall rawTier0Fixture"
          governed extra =
            [ ("test/support/Tier0Fixture.hs", Just fixtureModule)
            , ("test/unit/Main.hs", Just extra)
            ]
      tier0EncoderViolations (governed "writeTier0Fixture tmpDir (tier0Fixture value)\n") `shouldBe` []
      tier0EncoderViolations (governed ("-- " <> sibling <> " is the binary sibling\n")) `shouldBe` []
      tier0EncoderViolations (governed ("loadConfigFileAtPath (tmpDir </> \"" <> sibling <> "\")\n"))
        `shouldBe` []
      length (tier0EncoderViolations (governed ("writeFile (tmpDir </> \"" <> sibling <> "\") body\n")))
        `shouldBe` 1

    it "refuses a fixture module that stops being what the gate protects" $ do
      let user = "writeTier0Fixture tmpDir fixture\n"
          pair fixtureModule =
            [("test/support/Tier0Fixture.hs", fixtureModule), ("test/unit/Main.hs", Just user)]
      length (tier0EncoderViolations (pair (Just "rawTier0Fixture"))) `shouldBe` 1
      length (tier0EncoderViolations (pair (Just "renderProjectConfigDhall"))) `shouldBe` 1
      length (tier0EncoderViolations (pair Nothing)) `shouldBe` 1

-- | The binary-sibling filename, assembled rather than written.
--
-- The gate's own negative case must contain the exact shape the gate refuses,
-- so spelling the filename here would make this module its own first violation.
-- Assembling it keeps the rule carve-out-free: there is no "except the suite
-- that tests it" clause, which is the clause that later grows.
sibling :: String
sibling = "prodbox" <> "." <> "dhall"

-- | A @parameters@ expression that can only be text: the assertion is /about/
-- the generated schema's operator-facing affordances, and a rendered value
-- imports nothing.
schemaImportBody :: String
schemaImportBody = "let Config = ./prodbox-config-types.dhall\nin  Config.default\n"

-- | A plan whose workloads cannot fit the host, so the Ring-1 @assert@ is
-- dropped and the refusal falls to Haskell.
overCommittedProjectConfig :: ProdboxProjectConfig
overCommittedProjectConfig =
  syntheticProjectConfig
    { parameters =
        (parameters syntheticProjectConfig)
          { capacity =
              (capacity (parameters syntheticProjectConfig))
                { resource_plan =
                    (resource_plan (capacity (parameters syntheticProjectConfig)))
                      { rke2_reserved = ResourceVector 64000 131072 1000000 1000000
                      }
                }
          }
    }
