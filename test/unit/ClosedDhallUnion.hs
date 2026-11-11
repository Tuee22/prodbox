{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module ClosedDhallUnion (closedDhallUnionSuite) where

import Control.Monad (forM_)
import Data.Either (isLeft)
import Data.Foldable qualified as Foldable
import Data.Text qualified as Text
import Data.Void (Void)
import Dhall qualified
import Dhall.Binary qualified as Binary
import Dhall.Core qualified as Core
import Dhall.Map qualified as Map
import GHC.Generics (Generic)
import Prodbox.Config.ClosedDhallUnion (closedUnionDecoder, sameClosedType)
import Prodbox.Settings.SecretRef qualified as New
import Test.Tasty.HUnit (assertBool, (@?=))
import TestSupport (SuiteBuilder, describe, it)

data Recursive = Recursive Recursive deriving (Generic)
instance Dhall.FromDhall Recursive

-- Preserve the former Generic decoder as an independent SDK reference. Every
-- SecretRef constructor has the same nine-character prefix.
referenceSecretRef :: Dhall.Decoder New.SecretRef
referenceSecretRef =
  Dhall.genericAutoWith
    Dhall.defaultInterpretOptions {Dhall.constructorModifier = Text.copy . Text.drop 9}

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure
oldResult :: Core.Expr Void Void -> Either String String
oldResult expr =
  either
    (Left . show)
    (Right . show)
    (Dhall.toMonadic (Dhall.extract referenceSecretRef (Core.renote expr)))
newResult :: Core.Expr Void Void -> Either String String
newResult expr =
  either
    (Left . show)
    (Right . show)
    (Dhall.toMonadic (Dhall.extract (Dhall.auto @New.SecretRef) (Core.renote expr)))
compareResult :: Core.Expr Void Void -> IO ()
compareResult expr = newResult expr @?= oldResult expr
replaceType :: Text.Text -> Core.Expr Void Void -> Core.Expr Void Void -> IO (Core.Expr Void Void)
replaceType name replacement expression = case expression of
  Core.App (Core.Field (Core.Union fields) selected) body ->
    pure (Core.App (Core.Field (Core.Union (Map.insert name (Just replacement) fields)) selected) body)
  _ -> fail "fixed payload union changed its SDK syntax"
checkValue :: Core.Expr Void Void -> Core.Expr Void Void -> New.SecretRef -> IO ()
checkValue newType oldType value = do
  let expression = Core.denote (Dhall.embed Dhall.inject value)
  current <-
    right (Dhall.toMonadic (Dhall.extract (Dhall.auto @New.SecretRef) (Core.renote expression)))
  previous <-
    right (Dhall.toMonadic (Dhall.extract referenceSecretRef (Core.renote expression)))
  current @?= value
  Binary.encodeExpression expression
    @?= Binary.encodeExpression (Core.denote (Dhall.embed Dhall.inject previous))
  compareResult expression
  case expression of
    Core.App selected@(Core.Field types _) _ -> do
      assertBool "producer did not select the exact structural route" (sameClosedType types newType)
      compareResult (Core.App selected (Core.NaturalLit 0))
      compareResult selected
    _ -> fail "fixed SecretRef producer lost its payload union form"
  assertBool
    "same closed type lost its sufficient equality proof"
    (sameClosedType newType oldType && Core.judgmentallyEqual newType oldType)

checkSchemaOrder :: Core.Expr Void Void -> Core.Expr Void Void -> IO ()
checkSchemaOrder (Core.Union actual) (Core.Union expected) = Map.keys actual @?= Map.keys expected
checkSchemaOrder _ _ = fail "fixed SecretRef schema stopped being a union"

closedDhallUnionSuite :: SuiteBuilder ()
closedDhallUnionSuite = describe "closed Dhall union SDK compatibility" $ do
  it "fixed producer values retain schema bytes, decoded values and structural agreement" $ do
    let samples = ["", "ordinary", "λ😀", Text.replicate 64 "x"]
        values =
          concat
            [ [ New.SecretRefVault (New.VaultSecretRef value (value <> "/path") value)
              , New.SecretRefTransitKey value
              , New.SecretRefPrompt (New.PromptSpec value value)
              , New.SecretRefTestPlaintext value
              ]
            | value <- samples
            ]
    oldType <- case Foldable.toList (Dhall.expected referenceSecretRef) of
      [schema] -> pure (Core.denote schema)
      _ -> fail "frozen expected schema unavailable"
    newType <- case Foldable.toList (Dhall.expected (Dhall.auto @New.SecretRef)) of
      [schema] -> pure (Core.denote schema)
      _ -> fail "candidate expected schema unavailable"
    Binary.encodeExpression newType @?= Binary.encodeExpression oldType
    checkSchemaOrder newType oldType
    putStrLn ("fixed_secret_values=" <> show (length values))
    forM_ values (checkValue newType oldType)
  it "fixed invalid values retain complete SDK error rendering" $ do
    let values =
          [ Core.NaturalLit 0
          , Core.TextLit (Core.Chunks [] "ordinary")
          , Core.RecordLit Map.empty
          , Core.ListLit (Just Core.Natural) mempty
          ]
            :: [Core.Expr Void Void]
    forM_ values compareResult
  it "general type normalization and selected-schema behavior retain SDK fallback results" $ do
    let value = New.SecretRefVault (New.VaultSecretRef "kv" "path" "field")
        expression = Core.denote (Dhall.embed Dhall.inject value)
        alias = Core.Let (Core.makeBinding "T" Core.Text) (Core.Var (Core.V "T" 0))
    aliased <- replaceType "TransitKey" alias expression
    assertBool
      "open form incorrectly classified as exact closed syntax"
      (not (sameClosedType alias Core.Text))
    compareResult aliased
    newResult aliased @?= Right (show value)
    selected <- replaceType "Vault" Core.Natural expression
    compareResult selected
    newResult selected @?= Right (show value)
    mismatched <- replaceType "TransitKey" Core.Natural expression
    compareResult mismatched
    assertBool
      "different unselected schema was accepted"
      (either (const True) (const False) (newResult mismatched))
  it "structural predicate refuses unsupported forms and mismatched closed types" $ do
    let cases =
          [ (Core.Natural, Core.Text)
          , (Core.App Core.List Core.Natural, Core.App Core.List Core.Text)
          , (Core.App Core.Optional Core.Text, Core.Text)
          , (Core.App Core.Text Core.Natural, Core.App Core.Text Core.Natural)
          , (Core.Let (Core.makeBinding "T" Core.Text) (Core.Var (Core.V "T" 0)), Core.Text)
          ]
            :: [(Core.Expr Void Void, Core.Expr Void Void)]
    forM_ cases $ \(actual, expected) -> assertBool "structural mismatch was admitted" (not (sameClosedType actual expected))
  it "closed structural equality agrees with judgmental equality on a fixed type matrix" $ do
    let record fields = Core.Record (Map.fromList [(k, Core.makeRecordField v) | (k, v) <- fields])
        types =
          [ Core.Bool
          , Core.Natural
          , Core.Integer
          , Core.Double
          , Core.Text
          , Core.App Core.List Core.Natural
          , Core.App Core.List Core.Text
          , Core.App Core.Optional Core.Natural
          , Core.App Core.Optional (Core.App Core.List Core.Text)
          , record [("a", Core.Natural), ("b", Core.Text)]
          , record [("b", Core.Text), ("a", Core.Natural)]
          , Core.Union (Map.fromList [("A", Nothing), ("B", Just Core.Text)])
          , Core.Union (Map.fromList [("A", Nothing), ("B", Just Core.Natural)])
          , record []
          , Core.Union Map.empty
          ]
            :: [Core.Expr Void Void]
    forM_ types $ \actual -> forM_ types $ \expected -> sameClosedType actual expected @?= Core.judgmentallyEqual actual expected
    putStrLn ("fixed_closed_type_pairs=" <> show (length types * length types))
  it "duplicate labels and explicit nullary decoders retain SDK union semantics" $ do
    let duplicate = [("Pick", (1 :: Int) <$ Dhall.strictText), ("Pick", 2 <$ Dhall.strictText)]
        nullary =
          Dhall.Decoder
            { Dhall.expected = pure (Core.Record Map.empty)
            , Dhall.extract = const (pure (7 :: Int))
            }
        cases =
          [
            ( duplicate
            , Core.App
                (Core.Field (Core.Union (Map.fromList [("Pick", Just Core.Text)])) (Core.makeFieldSelection "Pick"))
                (Core.TextLit (Core.Chunks [] "ordinary"))
            )
          ,
            ( [("Done", nullary)]
            , Core.Field (Core.Union (Map.fromList [("Done", Nothing)])) (Core.makeFieldSelection "Done")
            )
          ,
            ( [("Done", nullary)]
            , Core.App
                (Core.Field (Core.Union (Map.fromList [("Done", Nothing)])) (Core.makeFieldSelection "Done"))
                (Core.NaturalLit 0)
            )
          ]
            :: [([(Text.Text, Dhall.Decoder Int)], Core.Expr Void Void)]
    forM_ cases $ \(branches, expression) -> do
      let standard = Dhall.union (foldMap (uncurry Dhall.constructor) branches)
          fast = closedUnionDecoder branches
          decode decoder = either (Left . show) Right (Dhall.toMonadic (Dhall.extract decoder (Core.renote expression)))
      decode fast @?= decode standard
  it "selected type annotation is left unevaluated like the SDK" $ do
    let value = New.SecretRefVault (New.VaultSecretRef "kv" "path" "field")
        expression = Core.denote (Dhall.embed Dhall.inject value)
    lazySelected <- replaceType "Vault" (error "selected annotation was forced") expression
    oldResult lazySelected @?= Right (show value)
    newResult lazySelected @?= Right (show value)
    forM_ (selectedAnnotationVariants expression) $ \variant -> do
      oldResult variant @?= Right (show value)
      newResult variant @?= Right (show value)
  it "unknown constructor refuses before unused type annotations" $ do
    let value = New.SecretRefVault (New.VaultSecretRef "kv" "path" "field")
        expression = Core.denote (Dhall.embed Dhall.inject value)
    lazySelected <- replaceType "Vault" (error "unknown constructor forced an annotation") expression
    let absent = renameSelection "Absent" lazySelected
    assertBool "SDK did not refuse unknown constructor" (isLeft (oldResult absent))
    assertBool "candidate did not preserve early constructor refusal" (isLeft (newResult absent))
  it "failed expected schema precedes input evaluation" $ do
    let branches = [("Recursive", const (1 :: Int) <$> Dhall.auto @Recursive)]
        reference = Dhall.union (foldMap (uncurry Dhall.constructor) branches)
        candidate = closedUnionDecoder branches
        expression = Core.renote (error "failed expected schema forced input" :: Core.Expr Void Void)
    assertBool
      "SDK expected schema unexpectedly succeeded"
      (isLeft (Dhall.toMonadic (Dhall.extract reference expression)))
    assertBool
      "candidate forced input before the schema refusal"
      (isLeft (Dhall.toMonadic (Dhall.extract candidate expression)))

renameSelection :: Text.Text -> Core.Expr Void Void -> Core.Expr Void Void
renameSelection name (Core.App (Core.Field types _) payload) = Core.App (Core.Field types (Core.makeFieldSelection name)) payload
renameSelection _ _ = error "fixed payload union changed shape"

selectedAnnotationVariants :: Core.Expr Void Void -> [Core.Expr Void Void]
selectedAnnotationVariants (Core.App (Core.Field (Core.Union fields) selected) payload) =
  [ Core.App (Core.Field (Core.Union variants) selected) payload
  | variants <- [Map.delete "Vault" fields, Map.insert "Vault" Nothing fields]
  ]
selectedAnnotationVariants _ = error "fixed payload union changed shape"
