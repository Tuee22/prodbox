{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module CanonicalDhallStorage (canonicalDhallStorageSuite) where

import Control.Exception (evaluate)
import Control.Monad (forM_)
import Data.Bifunctor (first)
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.Either (isLeft)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Void (Void)
import Dhall qualified
import Dhall.Binary qualified as Binary
import Dhall.Core qualified as Core
import Dhall.Map qualified as DhallMap
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import PinnedHeapGraph (observeGraph, observeGraphBytes, observedDataBytes)
import Prodbox.Capacity.CanonicalDhallNormalForm
import Prodbox.Capacity.Config qualified as Capacity
import Prodbox.Config.CanonicalDhallValueShape
import Prodbox.Config.CheckedCanonicalDhallData
import Prodbox.Settings qualified as Settings
import System.Mem (performGC)
import Test.Tasty.HUnit
import TestSupport (SuiteBuilder, describe, it, syntheticConfigFile)

data Detail = Detail {description :: Text, values :: [Maybe Natural]} deriving (Generic)
instance Dhall.ToDhall Detail

data Choice = EmptyChoice | TextChoice Text | DetailChoice Detail deriving (Generic)
instance Dhall.ToDhall Choice

data Complete = Complete {enabled :: Bool, selected :: Choice, nested :: Maybe [Maybe Natural]}
  deriving (Generic)
instance Dhall.ToDhall Complete

data SettingsEnvelope = SettingsEnvelope
  { schema_version :: Natural
  , context :: Settings.DeploymentContextInput
  , parameters :: Settings.ConfigFile
  }
  deriving (Generic)
instance Dhall.ToDhall SettingsEnvelope

right :: (Show err) => Either err value -> IO value
right = either (fail . show) pure

probe :: forall value. (Dhall.ToDhall value) => String -> [value] -> SuiteBuilder ()
probe label samples = it label $ forM_ (zip [1 :: Int ..] samples) $ \(ordinal, value) -> do
  schema <- right (compileCanonicalDhallValueShape (Dhall.declared (Dhall.inject @value)))
  let canonical = Binary.encodeExpression (Core.normalize (Core.denote (Dhall.embed (Dhall.inject @value) value)))
      bytes = Lazy.toStrict canonical
  let direct = Binary.encodeExpression (Core.denote (Dhall.embed (Dhall.inject @value) value))
  assertBool (label <> " direct producer differs from normalized bytes") (direct == canonical)
  closed <- right (compileClosedDhallValueShape (Dhall.declared (Dhall.inject @value)))
  measureCanonicalDhallValueShape closed bytes @?= measureCanonicalDhallValueShape schema bytes
  usage <- right (measureCanonicalDhallValueShape schema bytes)
  declared <- evaluate (canonicalDhallNormalFormBytes (canonicalDhallNormalForm usage))
  checked <- right (inspectCanonicalDhallData schema bytes)
  checkedCanonicalDhallDataUsage checked @?= usage
  legacy <-
    right
      ( Binary.decodeExpression (Lazy.fromStrict bytes)
          :: Either Binary.DecodingFailure (Core.Expr Void Void)
      )
  decoded <- right (decodeCheckedCanonicalDhallData checked)
  expression <- evaluate decoded
  performGC
  (observed, nodes) <- observeGraphBytes expression
  putStrLn
    ( label
        <> "#"
        <> show ordinal
        <> ": observed="
        <> show observed
        <> " nodes="
        <> show nodes
        <> " declared="
        <> show declared
    )
  assertBool (label <> " exceeds closed-data expression storage") (observed <= toInteger declared)

  assertBool
    "direct and legacy checked decoders disagree"
    (Binary.encodeExpression legacy == Binary.encodeExpression decoded)
  forM_ (mutations bytes) $ \input -> do
    let previous =
          measureCanonicalDhallValueShape schema input
            >> first
              (const CanonicalDhallValueEncodingInvalid)
              ( Binary.decodeExpression (Lazy.fromStrict input)
                  :: Either Binary.DecodingFailure (Core.Expr Void Void)
              )
        replacement = inspectCanonicalDhallData schema input >>= decodeCheckedCanonicalDhallData
    assertBool "refusal domains disagree" (isLeft previous == isLeft replacement)

-- The old comparison includes its existing closed-shape guard. These controls
-- make no claim about the broader unguarded decoder's version-wrapper domain.
mutations :: Bytes.ByteString -> [Bytes.ByteString]
mutations bytes =
  [ Bytes.empty
  , bytes <> Bytes.singleton 0
  , Bytes.take (max 0 (Bytes.length bytes - 1)) bytes
  , Bytes.singleton 0 <> bytes
  , Bytes.pack [0xd9, 0xd9, 0xf7] <> bytes
  , Bytes.pack [0x82, 0x63, 0x31, 0x2e, 0x30] <> bytes
  ]

fixedCompilerSchemas :: [(String, Core.Expr Void Void)]
fixedCompilerSchemas =
  [ ("record", compilerRecordType [("a", Core.App Core.List Core.Text), ("z", Core.Natural)])
  ,
    ( "union"
    , Core.Union
        (DhallMap.fromList [("a", Nothing), ("z", Just (compilerRecordType [("text", Core.Text)]))])
    )
  , ("complete settings envelope", Core.denote (Dhall.declared (Dhall.inject @SettingsEnvelope)))
  ]

observeReturnedCompilerGraph :: (String, Core.Expr Void Void) -> IO ()
observeReturnedCompilerGraph (label, schema) = do
  current <- either (fail . show) pure (compileClosedDhallValueShape schema)
  newRoot <- evaluate current
  -- Observe before any sizer walks the returned fields.
  after <- observeGraph newRoot
  bytes <- evaluate (canonicalDhallValueShapeDataBytes newRoot)
  assertBool
    (label <> ": returned graph exceeds structural data")
    (observedDataBytes after <= toInteger bytes)
  print ("compiler_returned_graph" :: String, label, observedDataBytes after, bytes)

checkCompilerRefusalOrder :: IO ()
checkCompilerRefusalOrder = do
  let schema :: Core.Expr Void Void
      schema =
        Core.Union
          ( DhallMap.fromList
              [("a", Just (Core.App Core.Text Core.Natural)), ("z", Just (error "later type field was forced"))]
          )
  either Just (const Nothing) (compileClosedDhallValueShape schema)
    @?= Just CanonicalDhallValueSchemaUnsupported

checkCompilerConstructorData :: IO ()
checkCompilerConstructorData = do
  let primitives = [Core.Bool, Core.Natural, Core.Integer, Core.Double, Core.Text]
      table =
        [(schema, 16) | schema <- primitives]
          <> [ (Core.App Core.List Core.Bool, 32)
             , (Core.App Core.Optional Core.Bool, 32)
             , (compilerRecordType [], 80)
             , (Core.Union DhallMap.empty, 80)
             , (compilerRecordType [("a", Core.Bool)], 160)
             , (compilerRecordType [("a", Core.Bool), ("b", Core.Text)], 240)
             , (Core.Union (DhallMap.fromList [("a", Nothing)]), 160)
             , (Core.Union (DhallMap.fromList [("a", Just Core.Bool)]), 176)
             ]
          :: [(Core.Expr Void Void, Natural)]
  forM_ table checkCompilerConstructorRow
  forM_ fixedCompilerSchemas (checkCompilerResultGraph . snd)

checkCompilerConstructorRow :: (Core.Expr Void Void, Natural) -> IO ()
checkCompilerConstructorRow (schema, expectedResultData) = do
  shape <- either (fail . show) pure (compileClosedDhallValueShape schema)
  canonicalDhallValueShapeCompilationDataBytes shape
    - canonicalDhallValueShapeDataBytes shape
    @?= expectedResultData
  checkCompilerResultGraph schema

checkCompilerResultGraph :: Core.Expr Void Void -> IO ()
checkCompilerResultGraph schema = do
  compiledResult <- evaluate (compileClosedDhallValueShape schema)
  -- The returned Either is observed without evaluating its payload with a sizer.
  graph <- observeGraph compiledResult
  shape <- either (fail . show) pure compiledResult
  bound <- evaluate (canonicalDhallValueShapeCompilationDataBytes shape)
  assertBool
    "compiler constructor-data term omitted returned Either graph"
    (observedDataBytes graph <= toInteger bound)
  print ("compiler_result_data" :: String, observedDataBytes graph, bound)

compilerRecordType :: [(Text, Core.Expr Void Void)] -> Core.Expr Void Void
compilerRecordType fields =
  Core.Record (DhallMap.fromList [(key, Core.makeRecordField value) | (key, value) <- fields])

canonicalDhallStorageSuite :: SuiteBuilder ()
canonicalDhallStorageSuite = describe "checked canonical Dhall storage and compatibility" $ do
  it "compiler returns quiescent record/union/envelope graphs before sizing" $
    forM_ fixedCompilerSchemas observeReturnedCompilerGraph
  it "strict compiler preserves unsupported-field refusal order" checkCompilerRefusalOrder
  it
    "compiler constructor-data term covers returned results and finite source-path table"
    checkCompilerConstructorData

  it "compiled shape maps preserve key orderings and unsupported nested-type refusals" $ do
    let names = ["a", "b", "c"]
        orders = [names, reverse names, ["b", "c", "a"]]
        recordType fields =
          Core.Record
            (DhallMap.fromList [(key, Core.makeRecordField fieldValue) | (key, fieldValue) <- fields])
        recordValue fields =
          Core.RecordLit
            (DhallMap.fromList [(key, Core.makeRecordField fieldValue) | (key, fieldValue) <- fields])
        value :: Core.Expr Void Void
        value = recordValue [(key, Core.NaturalLit 7) | key <- names]
        bytes = Lazy.toStrict (Binary.encodeExpression value)
    reference <- right (compileClosedDhallValueShape (recordType [(key, Core.Natural) | key <- names]))
    expected <- right (measureCanonicalDhallValueShape reference bytes)
    let unionType order = Core.Union (DhallMap.fromList [(key, Nothing) | key <- order])
        unionValue :: Core.Expr Void Void
        unionValue = Core.Field (unionType names) (Core.makeFieldSelection "b")
        unionBytes = Lazy.toStrict (Binary.encodeExpression unionValue)
    unionReference <- right (compileClosedDhallValueShape (unionType names))
    unionExpected <- right (measureCanonicalDhallValueShape unionReference unionBytes)
    forM_ orders $ \order -> do
      shape <- right (compileClosedDhallValueShape (recordType [(key, Core.Natural) | key <- order]))
      measureCanonicalDhallValueShape shape bytes @?= Right expected
      unionShape <- right (compileClosedDhallValueShape (unionType order))
      measureCanonicalDhallValueShape unionShape unionBytes @?= Right unionExpected
      let unsupported :: [Core.Expr Void Void]
          unsupported =
            [ recordType [("nested", Core.App Core.Text Core.Natural)]
            , Core.Union
                (DhallMap.fromList [("empty", Nothing), ("bad", Just (Core.TextLit (Core.Chunks [] "unsupported")))])
            ]
      forM_ unsupported assertUnsupportedSchema

  it "compiled shape data covers every constructor and complete trusted schemas" $ do
    let declared :: Dhall.Encoder value -> Core.Expr Void Void
        declared = Core.denote . Dhall.declared
        recordType fields =
          Core.Record (DhallMap.fromList [(key, Core.makeRecordField value) | (key, value) <- fields])
        schemas =
          [ Core.Bool
          , Core.Natural
          , Core.Integer
          , Core.Double
          , Core.Text
          , recordType []
          , Core.Union mempty
          , Core.App Core.List Core.Natural
          , Core.App Core.Optional (Core.App Core.List Core.Text)
          , Core.Union (DhallMap.fromList [("a", Nothing), ("b", Just Core.Text)])
          , declared (Dhall.inject @Settings.ConfigFile)
          , declared (Dhall.inject @Capacity.RuntimeMemoryProfile)
          , declared (Dhall.inject @SettingsEnvelope)
          ]
        compile = compileClosedDhallValueShape
        special =
          [ compile Core.Text >>= requireCanonicalDhallValue [] (RequireText "ordinary")
          , compile (Core.App Core.List Core.Natural) >>= requireCanonicalDhallValue [] (RequireListElements 2)
          , compile (Core.App Core.Optional Core.Natural)
              >>= requireCanonicalDhallValue [] (RequirePresentNatural (2 ^ (4096 :: Int)))
          , compile Core.Text >>= markCanonicalDhallPathText []
          , compile (recordType [("field", Core.Natural)]) >>= markCanonicalDhallAwsProfile []
          , compile (declared (Dhall.inject @SettingsEnvelope))
              >>= markCanonicalDhallPathText ["parameters", "storage", "manual_pv_host_root"]
              >>= markCanonicalDhallAwsProfile ["parameters", "aws_substrate", "profile"]
          ]
    forM_ (map compile schemas <> special) $ \prepared -> do
      shape <- right prepared
      required <- evaluate (canonicalDhallValueShapeDataBytes shape)
      performGC
      observed <- observeGraph shape
      assertBool
        "compiled shape data omitted reachable fields"
        (observedDataBytes observed <= toInteger required)

  it "exact text requirements charge their complete originating backing arrays" $ do
    let view = Text.take 2 (Text.drop 6 "prefixλ😀suffix")
        compact = Text.copy view
    ordinary <- right (compileClosedDhallValueShape Core.Text)
    original <- right (requireCanonicalDhallValue [] (RequireText view) ordinary)
    copied <- right (requireCanonicalDhallValue [] (RequireText compact) ordinary)
    originalBytes <- evaluate (canonicalDhallValueShapeDataBytes original)
    copiedBytes <- evaluate (canonicalDhallValueShapeDataBytes copied)
    performGC
    originalGraph <- observeGraph original
    copiedGraph <- observeGraph copied
    assertBool "visible Text length hid the retained backing" (originalBytes > copiedBytes)
    assertBool
      "fixed backing fixture lost the retained array distinction"
      (observedDataBytes originalGraph > observedDataBytes copiedGraph)
    forM_ [(originalBytes, originalGraph), (copiedBytes, copiedGraph)] $ \(required, actual) ->
      assertBool "exact Text shape exceeds its data term" (observedDataBytes actual <= toInteger required)

  probe @Bool "booleans" [False, True]
  probe @Natural "naturals" [0, 1, 2 ^ (64 :: Int), 2 ^ (512 :: Int), 2 ^ (4096 :: Int)]
  probe @Integer "integers" [0, 1, -1, 2 ^ (64 :: Int), negate (2 ^ (512 :: Int))]
  probe @Double "float representations" [0, -0, 1.5, 1 / 3, 1e100, 1 / 0, -(1 / 0), 0 / 0]
  probe @Text "text backings" ["", "ascii", "λ", "😀", "a\NULb", Text.replicate 65536 "λ"]
  probe @[Natural] "list sequences" [[], [0], [1, 2 ^ (128 :: Int)], [0 .. 4096]]
  probe @(Maybe Natural) "optional scalars" [Nothing, Just 0, Just (2 ^ (128 :: Int))]
  probe @(Maybe [Maybe Natural])
    "nested empty annotations"
    [Nothing, Just [], Just [Nothing], Just [Just 0, Nothing, Just (2 ^ (128 :: Int))]]
  probe @Choice
    "union alternatives"
    [EmptyChoice, TextChoice "", TextChoice "payload", DetailChoice (Detail "nested" [Nothing, Just 7])]
  probe @Complete
    "records and nested alternatives"
    [ Complete False EmptyChoice Nothing
    , Complete True (TextChoice "payload") (Just [])
    , Complete True (DetailChoice (Detail "" [Just (2 ^ (512 :: Int))])) (Just [Nothing])
    ]
  probe @Capacity.RuntimeMemoryProfile
    "runtime profiles preserve optional and wide fields"
    [ Capacity.RuntimeMemoryProfile
        "direct-profile"
        1
        2
        3
        4
        heap
        6
        (Capacity.ChildProcessBudgetConfig permits deadline peaks)
        8
        9
    | (heap, permits, deadline, peaks) <-
        [ (128, Just 2, Just 30000, [64, 16])
        , (2 ^ (4096 :: Int), Just (2 ^ (512 :: Int)), Nothing, [0, 2 ^ (1024 :: Int)])
        , (0, Nothing, Just 0, [])
        ]
    ]
  it "the general schema entrypoint keeps its normalization domain" $ do
    let aliased =
          Core.Let (Core.makeBinding "Selected" Core.Natural) (Core.Var (Core.V "Selected" 0))
            :: Core.Expr Void Void
        bytes = Lazy.toStrict (Binary.encodeExpression (Core.NaturalLit 7 :: Core.Expr Void Void))
    ordinary <- right (compileCanonicalDhallValueShape aliased)
    direct <- right (compileClosedDhallValueShape Core.Natural)
    measureCanonicalDhallValueShape ordinary bytes @?= measureCanonicalDhallValueShape direct bytes
    case compileClosedDhallValueShape aliased of
      Left CanonicalDhallValueSchemaUnsupported -> pure ()
      _ -> assertFailure "structural schema compiler evaluated an arbitrary let"
  probe "complete synthetic config" [syntheticConfigFile]

assertUnsupportedSchema :: Core.Expr Void Void -> IO ()
assertUnsupportedSchema schema = case compileClosedDhallValueShape schema of
  Left CanonicalDhallValueSchemaUnsupported -> pure ()
  _ -> assertFailure "structural shape compiler evaluated an unsupported nested type"
