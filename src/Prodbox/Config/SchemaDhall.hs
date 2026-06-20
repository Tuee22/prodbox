{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

-- | Sprint 7.17: generate the Dhall config schema files from the Haskell
-- source of truth.
--
-- The Haskell types ('ConfigFile' / 'defaultConfigFile' and the 'SecretRef'
-- union, plus the test-harness 'TestSecrets' fixture) are the single source of
-- truth for the config schema. This module emits the two generated schema
-- files — @prodbox-config-types.dhall@ and @test-secrets-types.dhall@ — directly
-- from those types so the hand-maintained Dhall↔Haskell duplication can be
-- retired.
--
-- Mechanism (pure, no I/O):
--
--   * The schema __Type__ is @'Dhall.expected' ('Dhall.auto' \@ConfigFile)@ —
--     the exact Dhall record type the binary decodes, so the emitted Type
--     cannot drift from the decoder.
--   * The schema __default__ is @'Dhall.embed' ('Dhall.inject' \@ConfigFile)
--     'defaultConfigFile'@ — the 'ToDhall' instances mirror the 'FromDhall'
--     decoders field-for-field, so the rendered default round-trips through the
--     same decoder.
--   * The 'SecretRef' union is hoisted into a top-level @let SecretRef = …@
--     binding and every structurally-equal occurrence inside the Type and the
--     default is replaced by a reference to it, so operators can write
--     @Config.SecretRef.Vault {…}@ and the file reads like the hand-written
--     original.
--
-- The result is the record @{ SecretRef = <union>, Type = <record type>,
-- default = <record value> }@, exposed through the @Config::{ overrides }@
-- completion operator.
module Prodbox.Config.SchemaDhall
  ( -- * Pure renderers (Haskell source of truth → Dhall schema text)
    renderConfigTypesDhall
  , renderTestSecretsTypesDhall

    -- * IO: materialize the generated schema files at the repository root
  , configTypesSchemaPath
  , testSecretsTypesSchemaPath
  , writeSchemaFiles
  , materializeSchemaFilesIfStale
  )
where

import Control.Exception (SomeException, try)
import Data.Either.Validation (Validation (..))
import Data.Functor.Identity (Identity (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Void (Void)
import Dhall qualified
import Dhall.Core (Expr)
import Dhall.Core qualified as Core
import Dhall.Map qualified as DhallMap
import Dhall.Src (Src)
import Prodbox.Settings (ConfigFile, defaultConfigFile)
import Prodbox.Settings.SecretRef (SecretRef)
import Prodbox.Vault.Host (TestSecrets, defaultTestSecrets)
import System.Directory (doesFileExist)
import System.FilePath ((</>))

-- We work on @Expr Src Void@; 'Dhall.Core.pretty' renders it back to Dhall
-- source text. The empty annotation type is the one used by the Dhall AST.
type DhallExpr = Expr Src Void

-- | The committed @prodbox-config-types.dhall@ text, generated from the Haskell
-- 'ConfigFile' / 'defaultConfigFile' types and the 'SecretRef' union.
renderConfigTypesDhall :: Text
renderConfigTypesDhall =
  configTypesHeader
    <> Core.pretty configTypesExpr
    <> "\n"

-- | The generated @test-secrets-types.dhall@ text, generated from the Haskell
-- 'TestSecrets' / 'TestSecretsAdminCredentials' types.
renderTestSecretsTypesDhall :: Text
renderTestSecretsTypesDhall =
  testSecretsTypesHeader
    <> Core.pretty testSecretsTypesExpr
    <> "\n"

-- | @let SecretRef = <union> in { SecretRef = SecretRef, Type = …, default = … }@.
configTypesExpr :: DhallExpr
configTypesExpr =
  Core.Let
    (Core.makeBinding secretRefName secretRefUnion)
    ( recordLit
        [ (secretRefName, secretRefVar)
        , ("Type", hoistSecretRef configType)
        , ("default", hoistSecretRef configDefault)
        ]
    )

-- | @{ Type = …, default = … }@ for the test-harness secrets fixture. It
-- carries no 'SecretRef' union, so it needs no hoisting.
testSecretsTypesExpr :: DhallExpr
testSecretsTypesExpr =
  recordLit
    [ ("Type", testSecretsType)
    , ("default", testSecretsDefault)
    ]

-- | The Dhall name used both for the @let@ binding and the @SecretRef@ record
-- field, so operators reference it as @Config.SecretRef@.
secretRefName :: Text
secretRefName = "SecretRef"

secretRefVar :: DhallExpr
secretRefVar = Core.Var (Core.V secretRefName 0)

-- | The 'SecretRef' union Dhall type.
secretRefUnion :: DhallExpr
secretRefUnion = expectedType (Dhall.auto @SecretRef)

-- | The 'ConfigFile' record Dhall type (with 'SecretRef' inlined; hoisted
-- separately).
configType :: DhallExpr
configType = expectedType (Dhall.auto @ConfigFile)

-- | The 'defaultConfigFile' value rendered as a Dhall record literal.
configDefault :: DhallExpr
configDefault = injectedValue (Dhall.inject @ConfigFile) defaultConfigFile

testSecretsType :: DhallExpr
testSecretsType = expectedType (Dhall.auto @TestSecrets)

testSecretsDefault :: DhallExpr
testSecretsDefault = injectedValue (Dhall.inject @TestSecrets) defaultTestSecrets

-- | Replace every sub-expression structurally equal to 'secretRefUnion' with a
-- reference to the hoisted @SecretRef@ binding. The traversal is bottom-up over
-- the Dhall AST via 'Core.subExpressions'.
hoistSecretRef :: DhallExpr -> DhallExpr
hoistSecretRef = transform replace
 where
  replace expr
    | expr == secretRefUnion = secretRefVar
    | otherwise = expr

-- | A bottom-up rewrite: rewrite each child first, then apply @f@ to the
-- resulting node. Built on the 'Core.subExpressions' traversal so it visits
-- every immediate sub-expression exactly once.
transform :: (DhallExpr -> DhallExpr) -> DhallExpr -> DhallExpr
transform f = go
 where
  go expr = f (runIdentity (Core.subExpressions (Identity . go) expr))

-- | Extract the Dhall type a decoder expects. The 'Decoder's here are built
-- from total 'Dhall.auto' instances whose expected type never fails to
-- compute; the 'Failure' arm renders a self-describing error type so the
-- function stays total.
expectedType :: Dhall.Decoder a -> DhallExpr
expectedType decoder =
  case Dhall.expected decoder of
    Success expr -> Core.denote expr
    Failure _ -> Core.Text

-- | Render an injected (encoded) Haskell value as a Dhall 'Expr'.
injectedValue :: Dhall.Encoder a -> a -> DhallExpr
injectedValue encoder value = Core.denote (Dhall.embed encoder value)

recordLit :: [(Text, DhallExpr)] -> DhallExpr
recordLit fields =
  Core.RecordLit
    (DhallMap.fromList [(name, Core.makeRecordField expr) | (name, expr) <- fields])

configTypesHeader :: Text
configTypesHeader =
  Text.unlines
    [ "-- prodbox-config-types.dhall"
    , "-- GENERATED from the Haskell source of truth (Prodbox.Settings /"
    , "-- Prodbox.Settings.SecretRef) by `prodbox config schema`. Do not edit by"
    , "-- hand; edit the Haskell `ConfigFile` / `defaultConfigFile` types and the"
    , "-- `SecretRef` union, then regenerate. (Sprint 7.17.)"
    , "--"
    , "-- User config (`prodbox-config.dhall`) imports this and overrides required"
    , "-- fields:"
    , "--"
    , "--   let Config = ./prodbox-config-types.dhall"
    , "--   in  Config::{ aws = Config.default.aws // { region = \"us-west-2\" }, ... }"
    , ""
    ]

testSecretsTypesHeader :: Text
testSecretsTypesHeader =
  Text.unlines
    [ "-- test-secrets-types.dhall"
    , "-- GENERATED from the Haskell source of truth (Prodbox.Vault.Host's"
    , "-- `TestSecrets` / `TestSecretsAdminCredentials`) by `prodbox config schema`."
    , "-- Do not edit by hand; edit the Haskell types, then regenerate."
    , "-- (Sprint 1.43.)"
    , "--"
    , "-- Generated schema for the TEST-HARNESS-ONLY secrets fixture. The file"
    , "-- that imports it (`test-secrets.dhall`) is git-ignored and is supplied"
    , "-- only by the test harness or an operator-driven automation run. It is"
    , "-- the ONLY durable-secret fixture file (operator decision 2026-06-19)."
    , "--"
    , "-- Usage:"
    , "--   let TestSecrets = ./test-secrets-types.dhall"
    , "--   in  TestSecrets::{ vault_operator_password = \"...\" }"
    , ""
    ]

-- | The repository-root path of the generated @prodbox-config-types.dhall@
-- schema. (Mirrors 'Prodbox.Repo.configSchemaPath' without importing that
-- module here, keeping this renderer a leaf dependency.)
configTypesSchemaPath :: FilePath -> FilePath
configTypesSchemaPath repoRoot = repoRoot </> "prodbox-config-types.dhall"

-- | The repository-root path of the generated @test-secrets-types.dhall@ schema.
testSecretsTypesSchemaPath :: FilePath -> FilePath
testSecretsTypesSchemaPath repoRoot = repoRoot </> "test-secrets-types.dhall"

-- | Write both generated schema files to the repository root, overwriting any
-- stale on-disk copy. This is the @prodbox config schema@ action.
writeSchemaFiles :: FilePath -> IO ()
writeSchemaFiles repoRoot = do
  TextIO.writeFile (configTypesSchemaPath repoRoot) renderConfigTypesDhall
  TextIO.writeFile (testSecretsTypesSchemaPath repoRoot) renderTestSecretsTypesDhall

-- | Materialize the schema files whenever they are absent or differ from the
-- current renderer output, so an operator's @import ./prodbox-config-types.dhall@
-- always resolves to the in-sync schema. Used by @config setup@ / @config
-- validate@ before they touch @prodbox.dhall@. Read failures fall back
-- to a rewrite (treat as stale).
materializeSchemaFilesIfStale :: FilePath -> IO ()
materializeSchemaFilesIfStale repoRoot = do
  ensureFresh (configTypesSchemaPath repoRoot) renderConfigTypesDhall
  ensureFresh (testSecretsTypesSchemaPath repoRoot) renderTestSecretsTypesDhall
 where
  ensureFresh path expected' = do
    present <- doesFileExist path
    stale <-
      if not present
        then pure True
        else do
          readResult <- try (TextIO.readFile path) :: IO (Either SomeException Text)
          pure $ case readResult of
            Left _ -> True
            Right onDisk -> onDisk /= expected'
    if stale
      then TextIO.writeFile path expected'
      else pure ()
