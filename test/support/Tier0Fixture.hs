{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 5.30: a Tier-0 test fixture is a rendered Haskell value, not
-- authored Dhall text.
--
-- Before this, four modules hand-authored the Tier-0 document — a record with
-- exactly one decoder and four encoders. Sprint @1.80@ retyped one field into a
-- closed union, updated one encoder, and the other three silently became wrong
-- rather than being updated; twenty integration cases then failed to decode.
-- That is the /Conversion/ class of
-- [chaos_hardening_doctrine.md § 23](../../documents/engineering/chaos_hardening_doctrine.md):
-- a typed value crossing out of a region must be reconstructed by exactly one
-- derived encoder, or the region's proofs end at the crossing.
--
-- The encoder here is 'renderProjectConfigDhall' — the same function
-- @prodbox config generate@ writes the operator's file with, and the one
-- @src\/Prodbox\/CheckCode.hs@ already calls "the one canonical generator … the
-- sole writer". A fixture is therefore a @ProdboxProjectConfig@ value, and a
-- schema change reaches it one of two ways, neither of them a runtime decode
-- failure:
--
--   * A field __retyped or removed__ is a compile error at the fixture
--     definition. This is the Sprint @1.80@ case.
--   * A field __added__ is rendered automatically, because the encoder is
--     derived from the record rather than restating it. (It is additionally a
--     compile error at any fixture that constructs the record explicitly rather
--     than updating a default — which is a stricter outcome, not a weaker one.)
--
-- Both were exercised as mutations before this module was accepted; see Sprint
-- @5.30@ in
-- [phase-5-canonical-test-suite.md](../../DEVELOPMENT_PLAN/phase-5-canonical-test-suite.md).
--
-- Note the pairing this depends on: a compile error only gates if something
-- compiles the module. `prodbox dev check`'s build is scoped @all@, which
-- resolves to the library and the executable and no test suite, so Sprint
-- @5.30@ also adds @--enable-tests@. Neither half alone would have caught
-- Sprint @1.80@ — see "The region of Ring 2" in
-- [resource_scaling_doctrine.md § 2C](../../documents/engineering/resource_scaling_doctrine.md).
module Tier0Fixture
  ( Tier0Fixture
  , tier0Fixture
  , tier0FixtureWithParameters
  , tier0FixtureWithContext
  , RawTier0Reason (..)
  , rawTier0Fixture
  , rawTier0Parameters
  , tier0FixtureText
  , tier0FixturePath
  , writeTier0Fixture
  )
where

import Data.List (isInfixOf)
import Data.Text qualified as Text
import Prodbox.Config.Tier0
  ( ProdboxContext (..)
  , ProdboxProjectConfig (..)
  , configFileToTier0Parameters
  , defaultProdboxContext
  , renderProdboxContextDhall
  , renderProjectConfigDhall
  )
import Prodbox.Settings qualified as Settings
import System.FilePath ((</>))

-- | The text of a Tier-0 @prodbox.dhall@ fixture.
--
-- Opaque: the constructor is not exported, so there are exactly two ways to
-- obtain one — 'tier0Fixture', which renders a typed value through the
-- canonical generator, and 'rawTier0Fixture', which takes hand-authored text
-- together with the reason it cannot be a typed value.
newtype Tier0Fixture = Tier0Fixture String
  deriving stock (Eq, Show)

tier0FixtureText :: Tier0Fixture -> String
tier0FixtureText (Tier0Fixture text) = text

-- | The derived path.
--
-- __Standard-C correction (Sprint 5.34, 2026-08-13).__ This said the
-- binary-sibling filename "appears exactly once in the test tree, here, so a
-- `dev check` rule can hold \"one encoder\" by refusing the literal anywhere
-- else". Measured, it appears in six test files and 107 times in total — 90 of
-- them in @test\/unit\/Main.hs@ — so no rule refusing the literal elsewhere was
-- ever possible, and the sentence described an intention rather than the tree.
--
-- What the gate actually holds is narrower and is stated where it lives
-- ('Prodbox.CheckCode.tier0WriteSiteLines'): a @writeFile@ of hand-authored
-- text to this path, reached directly or through one binding, is refused.
tier0FixturePath :: FilePath -> FilePath
tier0FixturePath directory = directory </> "prodbox.dhall"

writeTier0Fixture :: FilePath -> Tier0Fixture -> IO ()
writeTier0Fixture directory fixture =
  writeFile (tier0FixturePath directory) (tier0FixtureText fixture)

-- | Render a complete Tier-0 document through the canonical generator.
tier0Fixture :: ProdboxProjectConfig -> Tier0Fixture
tier0Fixture = Tier0Fixture . Text.unpack . renderProjectConfigDhall

-- | The common case, replacing the hand-written @wrapTier0@ envelope: operator
-- parameters projected from a 'Settings.ConfigFile', with an explicitly
-- synthetic test context and an empty witness.
--
-- Production 'defaultProdboxContext' is intentionally unauthored; using it as a
-- fixture would make unrelated decoder tests fail on deployment identity.
tier0FixtureWithParameters :: Settings.ConfigFile -> Tier0Fixture
tier0FixtureWithParameters = tier0FixtureWithContext id

-- | The same, with the context adjusted — replacing @writeRootBasics@, whose
-- only variation from the shared envelope was @context.vault_address@.
tier0FixtureWithContext
  :: (ProdboxContext -> ProdboxContext) -> Settings.ConfigFile -> Tier0Fixture
tier0FixtureWithContext adjustContext configFile =
  tier0Fixture
    ProdboxProjectConfig
      { parameters = configFileToTier0Parameters configFile
      , context = adjustContext fixtureProdboxContext
      , witness = []
      }

-- | Explicitly synthetic, valid deployment context for tests whose subject is
-- the parameter payload rather than first-run authoring. Production defaults
-- remain empty and fail closed.
fixtureProdboxContext :: ProdboxContext
fixtureProdboxContext =
  defaultProdboxContext
    { cluster_id = "synthetic-test-cluster"
    , vault_address = "http://127.0.0.1:31820"
    , minio_endpoint = "http://127.0.0.1:39000"
    }

-- | Why a fixture is hand-authored Dhall rather than a rendered value.
--
-- A closed set, and every arm names a property no well-typed
-- 'ProdboxProjectConfig' can have — so each arm is a claim that can be checked
-- rather than a note. There is deliberately no @NotYetMigrated@ arm: "not
-- migrated yet" is the stale-fixture defect itself, and this type exists to
-- make it unnameable.
data RawTier0Reason
  = -- | The fixture must literally @let Config = ./prodbox-config-types.dhall@
    -- and use @Config::{ … }@, because the assertion is /about/ the generated
    -- schema's operator-facing affordances — record completion,
    -- @Config.default.<section>@, @Config.SecretRef.Vault@. A rendered value
    -- imports nothing, so by construction it cannot exercise them.
    ExercisesGeneratedSchemaImport
  | -- | The fixture must FAIL to type-check against the Tier-0 record; the
    -- payload names the field and how it is violated. That is precisely what a
    -- well-typed Haskell value cannot express.
    MustNotTypeCheckAgainst String
  | -- | Sprint 5.34: the assertion is about the file's EXISTENCE, not its
    -- content — the test-mode preflight gate refuses when a production
    -- binary-sibling config is present and never decodes it. Rendering a
    -- complete valid config here would assert more than the gate reads and
    -- would couple this case to every future schema change, which is the
    -- coupling `tier0Fixture` exists to create where content /is/ read and to
    -- avoid where it is not. The payload names what is under test.
    ExistenceIsWhatIsUnderTest String
  deriving stock (Eq, Show)

-- | Admit hand-authored text, with its reason.
--
-- The reason is checked rather than recorded: an 'ExercisesGeneratedSchemaImport'
-- fixture that does not actually import the generated schema is refused, so the
-- escape cannot decay into "text I did not want to migrate".
rawTier0Fixture :: RawTier0Reason -> String -> Tier0Fixture
rawTier0Fixture reason text = case reason of
  ExercisesGeneratedSchemaImport
    | generatedSchemaPath `isInfixOf` text -> Tier0Fixture text
    | otherwise ->
        error
          ( "rawTier0Fixture ExercisesGeneratedSchemaImport does not import "
              <> generatedSchemaPath
              <> "; render it through tier0Fixture instead"
          )
  MustNotTypeCheckAgainst violated
    | null violated ->
        error "rawTier0Fixture MustNotTypeCheckAgainst must name the field it violates"
    | otherwise -> Tier0Fixture text
  ExistenceIsWhatIsUnderTest underTest
    | null underTest ->
        error
          "rawTier0Fixture ExistenceIsWhatIsUnderTest must name what is under test"
    | otherwise -> Tier0Fixture text

generatedSchemaPath :: String
generatedSchemaPath = "prodbox-config-types.dhall"

-- | A fixture whose @parameters@ must be raw text, with the envelope around it
-- still derived.
--
-- This is the partial case, and it is the one that matters: the hand-written
-- wrapper this replaces spelled out the entire @context@ record as text — seal
-- mode, capabilities, the parent-reference Optional's full type annotation —
-- so a change to 'ProdboxContext' broke it exactly the way a change to
-- 'Settings.ConfigFile' broke the four whole-document encoders. Here the
-- context is rendered by the same generic encoder 'renderProjectConfigDhall'
-- uses, so only the caller's own @parameters@ expression is text, and only
-- because that expression is the subject of the assertion.
rawTier0Parameters :: RawTier0Reason -> String -> Tier0Fixture
rawTier0Parameters reason parametersExpression =
  rawTier0Fixture reason $
    unlines
      [ "{ parameters = (" <> parametersExpression <> ")"
      , ", context = " <> renderedDefaultContext
      , ", witness = [] : List Text"
      , "}"
      ]

renderedDefaultContext :: String
renderedDefaultContext = Text.unpack (renderProdboxContextDhall fixtureProdboxContext)
