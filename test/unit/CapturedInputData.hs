{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module CapturedInputData (capturedInputDataSuite) where

import Codec.CBOR.Encoding qualified as Encoding
import Codec.CBOR.Write qualified as Write
import Codec.Serialise (Serialise, serialise)
import Control.DeepSeq (force)
import Control.Exception (IOException, evaluate, try)
import Control.Monad (forM_, when)
import Data.ByteString qualified as Bytes
import Data.ByteString.Lazy qualified as Lazy
import Data.Char (chr)
import Data.Either (isLeft)
import Data.Foldable qualified as Foldable
import Data.IORef (newIORef)
import Data.List (scanl')
import Data.Map.Internal qualified as MapInternal
import Data.Map.Internal.Debug qualified as MapDebug
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing)
import Data.Proxy (Proxy (..))
import Data.Set qualified as Set
import Data.Set.Internal qualified as SetInternal
import Data.Text qualified as Text
import Data.Text.Array qualified as TextArray
import Data.Text.Encoding qualified as TextEncoding
import Data.Text.Internal qualified as TextInternal
import Data.Void (Void)
import Data.Word (Word64)
import Dhall qualified
import Dhall.Binary qualified as Binary
import Dhall.Core qualified as Core
import Dhall.Map qualified as DhallMap
import FrozenPinnedHeapGraph qualified as FrozenHeap
import GHC.Exts (Int (I#), sizeofByteArray#)
import GHC.Exts.Heap qualified as Heap
import GHC.Exts.Heap.Closures (closureSize)
import GHC.Generics (Generic (..), K1 (..), M1 (..), U1 (..), (:*:) (..), (:+:) (..))
import Numeric.Natural (Natural)
import PinnedHeapGraph
  ( observeCellGraphBytes
  , observeGraph
  , observeGraphBytes
  , observedDataBytes
  , observedIndirectionBytes
  , observedNodeCount
  , observedTotalBytes
  )
import Prodbox.Capacity.CanonicalDhallNormalForm
import Prodbox.Capacity.Config qualified as Capacity
import Prodbox.Capacity.OrdinaryCapturedInputBudget
import Prodbox.Capacity.SettingsExtractedData
  ( RawData
  , settingsExtractedMaximumSumDepth
  , settingsExtractionAwsCaseArrayDataBytes
  , settingsExtractionGenericProductDataBytes
  , settingsExtractionGenericSumDataBytes
  , settingsExtractionSequenceDataBytes
  , settingsExtractionTypeMapDataBytes
  , settingsExtractionTypeTreeDataBytes
  )
import Prodbox.Capacity.SettingsNormalForm (settingsNormalForm, settingsNormalFormBytes)
import Prodbox.Config.CanonicalDhallDataEncoding
import Prodbox.Config.CanonicalDhallDataSyntax
import Prodbox.Config.CanonicalDhallValueShape
import Prodbox.Config.ComponentGraph qualified as Component
import Prodbox.Config.FieldNameTables (fieldNameTablesDataBytes)
import Prodbox.Config.OrdinaryMemoryProfile.DeclaredShape (ordinaryMemoryProfileShapeDataBytes)
import Prodbox.Config.SerialiseString
import Prodbox.Config.Tier0 qualified as Tier0
import Prodbox.ControlPlane.OrdinaryWireProfile
import Prodbox.ControlPlane.RpcAdmissionBirthConfig qualified as Registration
import Prodbox.ControlPlane.RpcAdmissionBirthPayload
import Prodbox.Settings qualified as Settings
import Prodbox.Settings.AwsSubstrateProfile qualified as Aws
import Prodbox.Settings.SecretRef qualified as Secret
import Prodbox.Substrate qualified as Substrate
import System.Mem (performGC)
import System.Mem.StableName (eqStableName, makeStableName)
import Test.Tasty.HUnit
import TestSupport
  ( SuiteBuilder
  , describe
  , it
  , syntheticAwsSubstrateProfileInput
  , syntheticConfigFile
  , syntheticProjectConfig
  )

right :: (Show err) => Either err value -> IO value
right = either (fail . show) pure

-- Opaque calls keep these fixed pure schemas as actual evaluated CAFs on the
-- pinned compiler, rather than preconstructed constructor literals.
{-# NOINLINE normalizeGraphFixture #-}
normalizeGraphFixture :: Core.Expr Void Void -> Core.Expr Void Void
normalizeGraphFixture = Core.normalize

{-# NOINLINE staticListSchema #-}
staticListSchema :: Core.Expr Void Void
staticListSchema = normalizeGraphFixture (Core.App Core.List Core.Natural)

{-# NOINLINE staticSettingsSchema #-}
staticSettingsSchema :: Core.Expr Void Void
staticSettingsSchema = normalizeGraphFixture (Core.denote (Dhall.declared (Dhall.inject @Settings.ConfigFile)))

fixture :: IO (Settings.ValidatedSettings, Bytes.ByteString, InspectedRpcBirthSettings)
fixture = do
  let context = Tier0.context syntheticProjectConfig
      input =
        Settings.DeploymentContextInput
          (Tier0.cluster_id context)
          (Tier0.vault_address context)
          (Tier0.minio_endpoint context)
          (Tier0.rpc_registration context)
  settings <-
    right =<< Settings.validateConfigWithContext "/synthetic/prodbox" input syntheticConfigFile
  bytes <- rpcBirthSettingsBytes <$> right (encodeRpcBirthControllerSettings settings)
  inspected <- right (inspectRpcBirthControllerSettings bytes)
  pure (settings, bytes, inspected)

rawSettings :: Bytes.ByteString -> IO ExtractedRpcBirthSettings
rawSettings bytes = do
  expression <-
    right
      ( Binary.decodeExpression (Lazy.fromStrict bytes)
          :: Either Binary.DecodingFailure (Core.Expr Void Void)
      )
  right (extractRpcBirthSettingsData expression)

profileUsage :: IO CanonicalDhallValueUsage
profileUsage = do
  shape <-
    right (compileClosedDhallValueShape (Dhall.declared (Dhall.inject @Capacity.RuntimeMemoryProfile)))
  let value =
        Capacity.RuntimeMemoryProfile
          "ordinary-cascade-host"
          1
          2
          3
          4
          128
          6
          (Capacity.ChildProcessBudgetConfig (Just 2) (Just 30000) [64, 16])
          8
          9
      bytes = Lazy.toStrict (Binary.encodeExpression (Core.denote (Dhall.embed Dhall.inject value)))
  right (measureCanonicalDhallValueShape shape bytes)

mapUsage :: Int -> IO CanonicalDhallValueUsage
mapUsage count = do
  let keys = [Text.pack ("field" <> show index) | index <- [0 .. count - 1]]
      declared = Core.Record (DhallMap.fromList [(key, Core.makeRecordField Core.Natural) | key <- keys])
      value :: Core.Expr Void Void
      value =
        Core.RecordLit (DhallMap.fromList [(key, Core.makeRecordField (Core.NaturalLit 0)) | key <- keys])
  shape <- right (compileClosedDhallValueShape declared)
  right (measureCanonicalDhallValueShape shape (Lazy.toStrict (Binary.encodeExpression value)))

mapHeight :: Map.Map key item -> Natural
mapHeight tree = case tree of
  MapInternal.Tip -> 0
  MapInternal.Bin _ _ _ lowerTree higherTree -> 1 + max (mapHeight lowerTree) (mapHeight higherTree)

setHeight :: Set.Set item -> Natural
setHeight tree = case tree of
  SetInternal.Tip -> 0
  SetInternal.Bin _ _ lowerTree higherTree -> 1 + max (setHeight lowerTree) (setHeight higherTree)

data WireContainer = WireContainer !Word64 !Bytes.ByteString !SerialiseString
  deriving stock (Generic)
  deriving anyclass (Serialise)
data WireRequest = WireRequest !Text.Text !WireContainer !Word64
  deriving stock (Generic)
  deriving anyclass (Serialise)

data TestSettingsEnvelope = TestSettingsEnvelope
  { schema_version :: Natural
  , context :: Settings.DeploymentContextInput
  , parameters :: Settings.ConfigFile
  }
  deriving stock (Generic)
  deriving anyclass (Dhall.FromDhall, Dhall.ToDhall)

data TypeAccountingFixture = TypeAccountingFixture
  { storedTypeAccountingOptional :: Maybe Secret.SecretRef
  , storedTypeAccountingText :: Text.Text
  }
  deriving stock (Generic)
  deriving anyclass (Dhall.FromDhall, Dhall.ToDhall)

expectedSchema :: Dhall.Decoder value -> IO (Core.Expr Void Void)
expectedSchema decoder = case Foldable.toList (Dhall.expected decoder) of
  [schema] -> pure (Core.denote schema)
  _ -> fail "fixed expected schema is unavailable"

typeKeys :: Core.Expr Void Void -> IO [Text.Text]
typeKeys schema = case schema of
  Core.Bool -> pure []
  Core.Natural -> pure []
  Core.Integer -> pure []
  Core.Double -> pure []
  Core.Text -> pure []
  Core.App Core.List child -> typeKeys child
  Core.App Core.Optional child -> typeKeys child
  Core.Record fields ->
    concat
      <$> traverse
        (\(name, field) -> (name :) <$> typeKeys (Core.recordFieldValue field))
        (DhallMap.toList fields)
  Core.Union alternatives ->
    concat
      <$> traverse
        (\(name, child) -> (name :) <$> maybe (pure []) typeKeys child)
        (DhallMap.toList alternatives)
  _ -> fail "expected schema left the closed data grammar"

textOrigin :: Text.Text -> (Int, Int)
textOrigin (TextInternal.Text (TextArray.ByteArray array) offset _) = (offset, I# (sizeofByteArray# array))

typeCounts :: CanonicalDhallValueUsage -> [Natural]
typeCounts usage =
  [ canonicalDhallTypeVisits usage
  , canonicalDhallTypeRecordFields usage
  , canonicalDhallTypeUnionAlternatives usage
  , canonicalDhallTypeTextTokens usage
  , canonicalDhallTypeTextTokenBytes usage
  ]

data EmptySettingsMarker = EmptySettingsMarker
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Dhall.FromDhall, Dhall.ToDhall)

instance RawData EmptySettingsMarker

class ForceProducts representation where
  forceProducts :: representation value -> ()
instance ForceProducts U1 where
  forceProducts U1 = ()
instance ForceProducts (K1 index field) where
  forceProducts (K1 field) = field `seq` ()
instance (ForceProducts child) => ForceProducts (M1 index metadata child) where
  forceProducts (M1 child) = forceProducts child
instance (ForceProducts left, ForceProducts right) => ForceProducts (left :*: right) where
  forceProducts (leftValue :*: rightValue) = forceProducts leftValue `seq` forceProducts rightValue
instance (ForceProducts left, ForceProducts right) => ForceProducts (left :+: right) where
  forceProducts choice = case choice of
    L1 leftValue -> forceProducts leftValue
    R1 rightValue -> forceProducts rightValue

profileFixture
  :: Bool -> IO (Settings.ValidatedSettings, Bytes.ByteString, InspectedRpcBirthSettings)
profileFixture present = do
  profile <- right (Aws.mkAwsSubstrateProfile syntheticAwsSubstrateProfileInput)
  let config =
        syntheticConfigFile
          { Settings.aws_substrate =
              (Settings.aws_substrate syntheticConfigFile)
                { Settings.profile = if present then Just profile else Nothing
                }
          }
      selected = Tier0.context syntheticProjectConfig
      input =
        Settings.DeploymentContextInput
          (Tier0.cluster_id selected)
          (Tier0.vault_address selected)
          (Tier0.minio_endpoint selected)
          (Tier0.rpc_registration selected)
  settings <- right =<< Settings.validateConfigWithContext "/synthetic/prodbox" input config
  bytes <- rpcBirthSettingsBytes <$> right (encodeRpcBirthControllerSettings settings)
  inspected <- right (inspectRpcBirthControllerSettings bytes)
  pure (settings, bytes, inspected)

checkGenericSumSpines
  :: forall value
   . ( Generic value
     , ForceProducts (Rep value)
     , RawData value
     , Eq value
     , Show value
     , Dhall.FromDhall value
     , Dhall.ToDhall value
     )
  => Proxy value
  -> [value]
  -> IO ()
checkGenericSumSpines shape values = forM_ values $ \value -> do
  let expression :: Core.Expr Void Void
      expression = Core.denote (Dhall.embed (Dhall.inject @value) value)
  _ <- evaluate (force expression)
  declared <- right (compileClosedDhallValueShape (Dhall.declared (Dhall.inject @value)))
  usage <-
    right
      (measureCanonicalDhallValueShape declared (Lazy.toStrict (Binary.encodeExpression expression)))
  decoded <- right (Dhall.toMonadic (Dhall.extract (Dhall.auto @value) (Core.renote expression)))
  decoded @?= value
  let representation = from value
  _ <- evaluate (forceProducts representation)
  to representation @?= value
  let !roots = (representation, value)
  performGC
  (combined, _) <- observeGraphBytes roots
  (rawData, _) <- observeGraphBytes value
  let extra = combined - rawData - 24
  assertBool "selected union has no observed Generic spine" (extra > 0)
  assertBool
    ( "Generic branch data exceeds the closed reservation: "
        <> show (value, extra, settingsExtractionGenericSumDataBytes shape usage)
    )
    (extra <= toInteger (settingsExtractionGenericSumDataBytes shape usage))

checkPrefixSchemaOrigins
  :: Text.Text -> (Core.Expr Void Void, Core.Expr Void Void) -> IO ()
checkPrefixSchemaOrigins prefix (Core.Union before, Core.Union after) = do
  DhallMap.keys before @?= DhallMap.keys after
  forM_ (DhallMap.keys before) $ \name -> do
    let visible = Bytes.length (TextEncoding.encodeUtf8 name)
        prefixBytes = Bytes.length (TextEncoding.encodeUtf8 prefix)
    textOrigin name @?= (prefixBytes, prefixBytes + visible)
  forM_ (DhallMap.keys after) $ \name ->
    textOrigin name @?= (0, Bytes.length (TextEncoding.encodeUtf8 name))
checkPrefixSchemaOrigins _ _ = assertFailure "fixed prefix schema stopped being a union"

checkTypeMapGraph :: Int -> Bool -> IO ()
checkTypeMapGraph count sorted = do
  let names = [Text.pack ("key" <> show n) | n <- [1 .. count]]
      order = if sorted then DhallMap.sort else id
      left :: DhallMap.Map Text.Text (Maybe (Core.Expr Void Void))
      left = order (DhallMap.fromList [(name, Nothing) | name <- names])
      rightMap :: DhallMap.Map Text.Text (Maybe (Core.Expr Void Void))
      rightMap = order (DhallMap.fromList [(name, Nothing) | name <- reverse names])
      declared = Core.Union rightMap
  shape <- right (compileClosedDhallValueShape declared)
  forM_ [Text.pack ("key" <> show n) | n <- [1, 1 + count `div` 2, count]] $ \selected -> do
    let value = Core.Field (Core.Union left) (Core.makeFieldSelection selected)
        deletedLeft = DhallMap.delete selected left
        deletedRight = DhallMap.delete selected rightMap
        leftPairs = DhallMap.toAscList deletedLeft
        rightPairs = DhallMap.toAscList deletedRight
        originals = (left, rightMap)
        roots = (left, rightMap, deletedLeft, deletedRight, leftPairs, rightPairs)
    usage <-
      right (measureCanonicalDhallValueShape shape (Lazy.toStrict (Binary.encodeExpression value)))
    _ <- evaluate (force roots)
    performGC
    before <- observeGraph originals
    after <- observeGraph roots
    let additional = observedDataBytes after - observedDataBytes before - 32
        required = settingsExtractionTypeMapDataBytes usage
    DhallMap.keys deletedLeft @?= filter (/= selected) (DhallMap.keys left)
    DhallMap.keys deletedRight @?= filter (/= selected) (DhallMap.keys rightMap)
    assertBool
      "actual deletion/list data exceeds its prospective term"
      (additional <= toInteger required)
    when (count == 31) $
      assertBool "fixed map fixture did not retain additional data" (additional > 0)

capturedInputDataSuite :: SuiteBuilder ()
capturedInputDataSuite = describe "captured input data stages" $ do
  it "counts selected union deletion work independently of type-only declarations" $ do
    shape <- right (compileClosedDhallValueShape (Dhall.declared (Dhall.inject @TypeAccountingFixture)))
    forM_
      [ (Nothing, [0, 0, 0])
      , (Just (Secret.SecretRefTransitKey "key"), [1, 4, 3])
      , (Just (Secret.SecretRefPrompt (Secret.PromptSpec "name" "purpose")), [1, 4, 3])
      ]
      $ \(selected, expected) -> do
        let value = TypeAccountingFixture selected "ordinary"
        usage <-
          right
            ( measureCanonicalDhallValueShape
                shape
                (Lazy.toStrict (Binary.encodeExpression (Core.denote (Dhall.embed Dhall.inject value))))
            )
        [ canonicalDhallUnionValues usage
          , canonicalDhallSelectedUnionEntries usage
          , canonicalDhallSelectedUnionHeightSum usage
          ]
          @?= expected
        assertBool "type-only alternatives disappeared" (canonicalDhallTypeUnionAlternatives usage >= 4)

  it "funds both actual union-map deletions and ascending comparison lists" $
    forM_ [1, 2, 3, 7, 16, 31] $ \count ->
      forM_ [False, True] (checkTypeMapGraph count)

  it "retains selected type-map data through the later input branches" $ do
    (_, _, inspected) <- fixture
    profile <- profileUsage
    let usage = inspectedRpcBirthSettingsUsage inspected
        budget = ordinaryCapturedInputBudget 0 usage profile
        required = ordinaryCapturedMinimumScratchBytes budget
        maps = settingsExtractionTypeMapDataBytes usage
        earlier = required - maps
    ordinaryCapturedSettingsTypeMapDataBytes budget @?= maps
    assertBool "complete fixture has no selected map work" (maps > 0)
    checkOrdinaryCapturedInputScratch required budget @?= Right ()
    checkOrdinaryCapturedInputScratch earlier budget
      @?= Left (OrdinaryCapturedInputScratchUnderfunded required earlier)

  it "keeps every complete expected and declared settings type key compact" $ do
    expected <- expectedSchema (Dhall.auto @TestSettingsEnvelope)
    let declared = Core.denote (Dhall.declared (Dhall.inject @TestSettingsEnvelope))
    assertBool "expected/declared schema meaning differs" (Core.judgmentallyEqual expected declared)
    forM_ [expected, declared] $ \schema -> do
      names <- typeKeys schema
      assertBool "empty settings schema key audit" (not (null names))
      forM_ names $ \name ->
        textOrigin name @?= (0, Bytes.length (TextEncoding.encodeUtf8 name))

  it "preserves frozen prefix-modifier schema bytes while releasing stripped backing prefixes" $ do
    let options prefix =
          Dhall.defaultInterpretOptions
            { Dhall.constructorModifier = \name -> fromMaybe name (Text.stripPrefix prefix name)
            }
        fixtures =
          [
            ( "SecretRef"
            , expectedSchema (Dhall.genericAutoWith (options "SecretRef") :: Dhall.Decoder Secret.SecretRef)
            , expectedSchema (Dhall.auto @Secret.SecretRef)
            , Core.denote
                (Dhall.declared (Dhall.genericToDhallWith (options "SecretRef") :: Dhall.Encoder Secret.SecretRef))
            , Core.denote (Dhall.declared (Dhall.inject @Secret.SecretRef))
            )
          ,
            ( "ScalingPolicy"
            , expectedSchema
                (Dhall.genericAutoWith (options "ScalingPolicy") :: Dhall.Decoder Substrate.ScalingPolicy)
            , expectedSchema (Dhall.auto @Substrate.ScalingPolicy)
            , Core.denote
                ( Dhall.declared
                    (Dhall.genericToDhallWith (options "ScalingPolicy") :: Dhall.Encoder Substrate.ScalingPolicy)
                )
            , Core.denote (Dhall.declared (Dhall.inject @Substrate.ScalingPolicy))
            )
          ,
            ( "RpcBirthConfig"
            , expectedSchema
                (Dhall.genericAutoWith (options "RpcBirthConfig") :: Dhall.Decoder Registration.RpcBirthConfig)
            , expectedSchema (Dhall.auto @Registration.RpcBirthConfig)
            , Core.denote
                ( Dhall.declared
                    (Dhall.genericToDhallWith (options "RpcBirthConfig") :: Dhall.Encoder Registration.RpcBirthConfig)
                )
            , Core.denote (Dhall.declared (Dhall.inject @Registration.RpcBirthConfig))
            )
          ]
    forM_ fixtures $ \(prefix, oldExpectedAction, currentExpectedAction, oldDeclared, currentDeclared) -> do
      oldExpected <- oldExpectedAction
      currentExpected <- currentExpectedAction
      Binary.encodeExpression currentExpected @?= Binary.encodeExpression oldExpected
      Binary.encodeExpression currentDeclared @?= Binary.encodeExpression oldDeclared
      forM_
        [(oldExpected, currentExpected), (oldDeclared, currentDeclared)]
        (checkPrefixSchemaOrigins prefix)

  it "separates exact type-only counters from value keys and payloads" $ do
    shape <- right (compileClosedDhallValueShape (Dhall.declared (Dhall.inject @TypeAccountingFixture)))
    usages <-
      traverse
        ( \payloadText ->
            let value = TypeAccountingFixture Nothing payloadText
                expression = Core.denote (Dhall.embed Dhall.inject value)
             in right (measureCanonicalDhallValueShape shape (Lazy.toStrict (Binary.encodeExpression expression)))
        )
        ["", "ordinary", Text.replicate 64 "λ😀"]
    forM_ usages $ \usage -> typeCounts usage @?= [10, 5, 4, 16, 103]
    case usages of
      [emptyUsage, ordinaryUsage, unicodeUsage] -> do
        assertBool
          "value payload controls did not change the global measurement"
          ( canonicalDhallTextTokenBytes emptyUsage < canonicalDhallTextTokenBytes ordinaryUsage
              && canonicalDhallTextTokenBytes ordinaryUsage < canonicalDhallTextTokenBytes unicodeUsage
          )
        canonicalDhallTypeNormalForm emptyUsage @?= canonicalDhallTypeNormalForm ordinaryUsage
        canonicalDhallTypeNormalForm ordinaryUsage @?= canonicalDhallTypeNormalForm unicodeUsage
      _ -> assertFailure "fixed type-only matrix changed"
    scalarShape <- right (compileClosedDhallValueShape Core.Text)
    let scalarExpression :: Core.Expr Void Void
        scalarExpression = Core.TextLit (Core.Chunks [] "ordinary")
    scalarUsage <-
      right
        ( measureCanonicalDhallValueShape
            scalarShape
            (Lazy.toStrict (Binary.encodeExpression scalarExpression))
        )
    typeCounts scalarUsage @?= [0, 0, 0, 0, 0]
    settingsExtractionTypeTreeDataBytes scalarUsage @?= 0

  it "funds selected type trees before settings extraction without value-payload inflation" $ do
    expected <- expectedSchema (Dhall.auto @TestSettingsEnvelope)
    let declared :: Core.Expr Void Void
        declared = Core.denote (Dhall.declared (Dhall.inject @TestSettingsEnvelope))
        expectedNormalized :: Core.Expr Void Void
        expectedNormalized = Core.normalize expected
        declaredNormalized :: Core.Expr Void Void
        declaredNormalized = Core.normalize declared
        absence :: Core.Expr Void Void
        absence = Core.denote (Dhall.embed Dhall.inject (Nothing :: Maybe TestSettingsEnvelope))
    shape <-
      right (compileClosedDhallValueShape (Dhall.declared (Dhall.inject @(Maybe TestSettingsEnvelope))))
    usage <-
      right (measureCanonicalDhallValueShape shape (Lazy.toStrict (Binary.encodeExpression absence)))
    canonicalDhallTypeRecordFields usage @?= canonicalDhallRecordFields usage
    canonicalDhallTypeUnionAlternatives usage @?= canonicalDhallUnionAlternatives usage
    canonicalDhallTypeTextTokens usage + 1 @?= canonicalDhallTextTokens usage
    canonicalDhallTypeTextTokenBytes usage + 5 @?= canonicalDhallTextTokenBytes usage
    let single = canonicalDhallNormalFormBytes (canonicalDhallTypeNormalForm usage)
        reserve = settingsExtractionTypeTreeDataBytes usage
    reserve @?= 5 * single
    _ <- evaluate (force (expected, declared, expectedNormalized, declaredNormalized))
    let !roots = (expected, declared, expectedNormalized, declaredNormalized)
    performGC
    forM_ [expected, declared, expectedNormalized, declaredNormalized] $ \tree -> do
      observation <- observeGraph tree
      assertBool
        "closed type syntax exceeds the prospective data term"
        (observedDataBytes observation <= toInteger single)
    observation <- observeGraph roots
    assertBool
      "held type syntax exceeds the selected type-tree data term"
      (observedDataBytes observation <= toInteger reserve)
    profile <- profileUsage
    let budget = ordinaryCapturedInputBudget 0 usage profile
        retainedProfileStage =
          ordinaryCapturedSourceBytes budget
            + ordinaryCapturedInitialProfileDataBytes budget
            + ordinaryCapturedProfileReaderStepDataBytes budget
            + ordinaryCapturedProfileNormalFormBytes budget
            + ordinaryCapturedRequestPayloadCopyBytes budget
            + max
              ( ordinaryCapturedProfileScalarImportBytes budget
                  + ordinaryCapturedProfileScalarHandoffDataBytes budget
              )
              ( ordinaryCapturedProfileEncodingBufferBytes budget
                  + ordinaryCapturedProfileEncodingProgramBytes budget
              )
    ordinaryCapturedSettingsTypeTreeDataBytes budget @?= reserve
    assertBool
      "type-tree reservation omitted from scratch"
      (reserve <= ordinaryCapturedMinimumScratchBytes budget)
    assertBool
      "later profile phase retired potentially retained SDK type trees"
      (retainedProfileStage + reserve <= ordinaryCapturedMinimumScratchBytes budget)

  it "counts a static indirection and its referent where the frozen observer loses the referent" $
    forM_ [staticListSchema, staticSettingsSchema] $ \schema -> do
      _ <- evaluate (force schema)
      performGC
      let box = Heap.asBox schema
      closure <- Heap.getBoxedClosureData box
      case closure of
        Heap.IndClosure {Heap.indirectee = Heap.Box child} -> do
          headerName <- makeStableName schema
          referentName <- makeStableName child
          assertBool
            "fixture no longer reproduces stable-name aliasing"
            (eqStableName headerName referentName)
          let header = toInteger (closureSize box) * 8
          FrozenHeap.observeGraphBytes schema >>= (@?= (header, 1))
          observed <- observeGraph schema
          assertBool
            "indirection header disappeared from the graph"
            (observedIndirectionBytes observed >= header)
          assertBool "referent data disappeared from the graph" (observedDataBytes observed > header)
          assertBool
            "corrected observer agrees with the frozen undercount"
            (observedTotalBytes observed > header)
          assertBool "referent contributes no graph nodes" (observedNodeCount observed > 1)
        _ -> assertFailure "fixed schema no longer exposes the pinned static-indirection counterexample"

  it "counts a shared static header and referent once across duplicate roots" $ do
    _ <- evaluate (force staticListSchema)
    let !roots = (staticListSchema, staticListSchema)
    performGC
    one <- observeGraph staticListSchema
    both <- observeGraph roots
    observedDataBytes both @?= observedDataBytes one + 24
    observedIndirectionBytes both @?= observedIndirectionBytes one
    observedNodeCount both @?= observedNodeCount one + 1

  it "keeps mutable-cell admission explicit and counts a shared cell once" $ do
    cell <- newIORef False
    refused <- try (observeGraphBytes cell) :: IO (Either IOException (Integer, Int))
    assertBool "immutable observer accepted a mutable cell" (isLeft refused)
    let !roots = (cell, cell)
    performGC
    (one, oneNodes) <- observeCellGraphBytes cell
    (both, bothNodes) <- observeCellGraphBytes roots
    both @?= one + 24
    bothNodes @?= oneNodes + 1

  it "funds Generic union spines and nullary leaves through closed raw fields" $ do
    checkGenericSumSpines (Proxy @EmptySettingsMarker) [EmptySettingsMarker]
    checkGenericSumSpines (Proxy @Component.ComponentId) [minBound .. maxBound]
    checkGenericSumSpines (Proxy @Component.EdgeKind) [minBound .. maxBound]
    checkGenericSumSpines
      (Proxy @Component.ReadinessProbe)
      ( [ Component.ProbeResourceExists
        , Component.ProbeFrontDoorHttp
        , Component.ProbeServiceActive
        , Component.ProbeRolloutComplete
        , Component.ProbeOperatorAvailable
        , Component.ProbeVaultUnsealed
        ]
          <> map Component.ProbeBackendRoundTrip [minBound .. maxBound]
      )
    settingsExtractedMaximumSumDepth (Proxy @Bool) @?= 0
    settingsExtractedMaximumSumDepth (Proxy @Text.Text) @?= 0
    settingsExtractedMaximumSumDepth (Proxy @Natural) @?= 0
    settingsExtractedMaximumSumDepth (Proxy @EmptySettingsMarker) @?= 0
    settingsExtractedMaximumSumDepth (Proxy @Component.ComponentId) @?= 5
    settingsExtractedMaximumSumDepth (Proxy @Component.ReadinessProbe) @?= 8
    settingsExtractedMaximumSumDepth (Proxy @(Maybe [Component.ReadinessProbe])) @?= 8
    settingsExtractedMaximumSumDepth (Proxy @Settings.ConfigFile) @?= 8
    declared <-
      right
        (compileClosedDhallValueShape (Dhall.declared (Dhall.inject @(Maybe Component.ReadinessProbe))))
    let absent = Core.denote (Dhall.embed Dhall.inject (Nothing :: Maybe Component.ReadinessProbe))
    usage <-
      right (measureCanonicalDhallValueShape declared (Lazy.toStrict (Binary.encodeExpression absent)))
    canonicalDhallUnionValues usage @?= 0
    settingsExtractionGenericSumDataBytes (Proxy @(Maybe Component.ReadinessProbe)) usage @?= 0

  it "counts only present marked AWS records while preserving the accepted wire shape" $
    forM_ [False, True] $ \present -> do
      (settings, bytes, inspected) <- profileFixture present
      plain <- right (compileClosedDhallValueShape (Dhall.declared (Dhall.inject @TestSettingsEnvelope)))
      marked <- right (markCanonicalDhallAwsProfile ["parameters", "aws_substrate", "profile"] plain)
      repeated <- right (markCanonicalDhallAwsProfile ["parameters", "aws_substrate", "profile"] marked)
      before <- right (measureCanonicalDhallValueShape plain bytes)
      after <- right (measureCanonicalDhallValueShape marked bytes)
      again <- right (measureCanonicalDhallValueShape repeated bytes)
      canonicalDhallAwsProfileValues before @?= 0
      canonicalDhallAwsProfileValues after @?= if present then 1 else 0
      canonicalDhallAwsProfileValues (inspectedRpcBirthSettingsUsage inspected)
        @?= if present then 1 else 0
      again @?= after
      canonicalDhallNormalForm before @?= canonicalDhallNormalForm after
      boundCanonicalDhallValueShape plain @?= boundCanonicalDhallValueShape marked
      raw <- rawSettings bytes
      extractedRpcBirthSettingsConfig raw @?= Settings.validatedConfig settings
      case markCanonicalDhallAwsProfile ["parameters", "domain", "demo_fqdn"] plain of
        Left CanonicalDhallValueSchemaUnsupported -> pure ()
        _ -> assertFailure "non-record coordinate accepted a narrowing marker"

  it "funds actual Generic product spines beside the shared raw settings fields" $
    forM_ [False, True] $ \present -> do
      (settings, _, inspected) <- profileFixture present
      _ <- evaluate (settingsNormalFormBytes (settingsNormalForm settings))
      let raw = Settings.validatedConfig settings
          representation = from raw
      _ <- evaluate (forceProducts representation)
      to representation @?= raw
      let !roots = (representation, raw)
      performGC
      combined <- observeGraph roots
      rawData <- observeGraph raw
      let extra = observedDataBytes combined - observedDataBytes rawData - 24
          completeExtra = observedTotalBytes combined - observedTotalBytes rawData - 24
          usage = inspectedRpcBirthSettingsUsage inspected
      extra @?= 288
      assertBool
        "Generic products exceed the separate prospective spine term"
        (extra <= toInteger (settingsExtractionGenericProductDataBytes (Proxy @Settings.ConfigFile) usage))
      assertBool
        "complete additional graph exceeds the prospective product term"
        ( completeExtra
            <= toInteger (settingsExtractionGenericProductDataBytes (Proxy @Settings.ConfigFile) usage)
        )

  it
    "reserves conditional case arrays and Generic products and sums in the pre-decode extraction stage"
    $ forM_ [False, True]
    $ \present -> do
      (_, _, inspected) <- profileFixture present
      profile <- profileUsage
      let usage = inspectedRpcBirthSettingsUsage inspected
          budget = ordinaryCapturedInputBudget 0 usage profile
          extraction =
            ordinaryCapturedSourceBytes budget
              + ordinaryCapturedInitialProfileDataBytes budget
              + ordinaryCapturedSettingsNormalFormBytes budget
              + ordinaryCapturedSettingsExtractedDataBytes budget
              + ordinaryCapturedSettingsExtractionSequenceDataBytes budget
              + ordinaryCapturedSettingsGenericProductDataBytes budget
              + ordinaryCapturedSettingsGenericSumDataBytes budget
              + ordinaryCapturedSettingsTypeTreeDataBytes budget
              + ordinaryCapturedSettingsAwsCaseArrayDataBytes budget
      settingsExtractionAwsCaseArrayDataBytes usage @?= if present then 285056 else 0
      ordinaryCapturedSettingsAwsCaseArrayDataBytes budget
        @?= settingsExtractionAwsCaseArrayDataBytes usage
      ordinaryCapturedSettingsGenericProductDataBytes budget
        @?= rpcBirthSettingsGenericProductDataBytes usage
      ordinaryCapturedSettingsGenericSumDataBytes budget
        @?= rpcBirthSettingsGenericSumDataBytes usage
      assertBool
        "selected settings unions reserve no Generic spines"
        (ordinaryCapturedSettingsGenericSumDataBytes budget > 0)
      assertBool
        "extraction data is absent from scratch"
        (extraction <= ordinaryCapturedMinimumScratchBytes budget)
      case checkOrdinaryCapturedInputScratch (ordinaryCapturedMinimumScratchBytes budget - 1) budget of
        Left OrdinaryCapturedInputScratchUnderfunded {} -> pure ()
        _ -> assertFailure "one-byte underfunded extraction accepted"

  it "funds the SDK list decoder's actual intermediate sequence graphs" $
    forM_ [0, 1, 2, 3, 4, 31, 128, 1024, 4096] $ \count -> do
      let values = take count (cycle [0, 1, 2 ^ (512 :: Int)]) :: [Natural]
          expression = Core.denote (Dhall.embed (Dhall.inject @[Natural]) values)
          bytes = Lazy.toStrict (Binary.encodeExpression expression)
      shape <- right (compileClosedDhallValueShape (Dhall.declared (Dhall.inject @[Natural])))
      usage <- right (measureCanonicalDhallValueShape shape bytes)
      intermediate <-
        right (Dhall.toMonadic (Dhall.extract (Dhall.sequence Dhall.natural) (Core.renote expression)))
      selected <- evaluate (force intermediate)
      returned <- evaluate (force (Foldable.toList selected))
      right (Dhall.toMonadic (Dhall.extract (Dhall.list Dhall.natural) (Core.renote expression)))
        >>= (@?= returned)
      returned @?= values
      canonicalDhallListValues usage @?= 1
      canonicalDhallListElements usage @?= fromIntegral count
      let !roots = (selected, returned)
      performGC
      (combined, _) <- observeGraphBytes roots
      (returnedData, _) <- observeGraphBytes returned
      assertBool
        "SDK intermediate sequence exceeds its separate spine term"
        (combined <= returnedData + 24 + toInteger (settingsExtractionSequenceDataBytes usage))
      when (count > 0) $
        assertBool
          "fixture no longer distinguishes the intermediate sequence from returned list data"
          (combined > returnedData + 24)

  it "counts nested value lists and funds their intermediate sequence spines" $
    forM_ [[], [[]], [[], [0, 1, 2 ^ (512 :: Int)], [2]], [replicate 64 0, replicate 128 1]] $ \values -> do
      let expression = Core.denote (Dhall.embed (Dhall.inject @[[Natural]]) values)
          bytes = Lazy.toStrict (Binary.encodeExpression expression)
      shape <- right (compileClosedDhallValueShape (Dhall.declared (Dhall.inject @[[Natural]])))
      usage <- right (measureCanonicalDhallValueShape shape bytes)
      selected <-
        right
          ( Dhall.toMonadic
              (Dhall.extract (Dhall.sequence (Dhall.sequence Dhall.natural)) (Core.renote expression))
          )
          >>= evaluate . force
      returned <- evaluate (force (map Foldable.toList (Foldable.toList selected)))
      returned @?= values
      right
        (Dhall.toMonadic (Dhall.extract (Dhall.list (Dhall.list Dhall.natural)) (Core.renote expression)))
        >>= (@?= returned)
      canonicalDhallListValues usage @?= fromIntegral (1 + length values)
      canonicalDhallListElements usage @?= fromIntegral (length values + sum (map length values))
      let !roots = (selected, returned)
      performGC
      (combined, _) <- observeGraphBytes roots
      (returnedData, _) <- observeGraphBytes returned
      assertBool
        "nested intermediate sequences exceed their separate spine term"
        (combined <= returnedData + 24 + toInteger (settingsExtractionSequenceDataBytes usage))

  it "keeps the extraction sequence stage inside the serial settings reservation" $ do
    (_, _, inspected) <- fixture
    profile <- profileUsage
    let usage = inspectedRpcBirthSettingsUsage inspected
        budget = ordinaryCapturedInputBudget 0 usage profile
        extractionStage =
          ordinaryCapturedSourceBytes budget
            + ordinaryCapturedInitialProfileDataBytes budget
            + ordinaryCapturedSettingsNormalFormBytes budget
            + ordinaryCapturedSettingsExtractedDataBytes budget
            + ordinaryCapturedSettingsExtractionSequenceDataBytes budget
    ordinaryCapturedSettingsExtractionSequenceDataBytes budget
      @?= settingsExtractionSequenceDataBytes usage
    assertBool
      "settings extraction Seq stage is missing from scratch"
      (extractionStage <= ordinaryCapturedMinimumScratchBytes budget)
    assertBool "fixture contains no settings list" (canonicalDhallListValues usage > 0)

  it "strict Map construction funds actual maps and retained insertion histories" $
    forM_ [0, 1, 2, 3, 7, 31, 128, 256] $ \count -> do
      let keys = [0 .. count - 1] :: [Int]
          orders =
            [ keys
            , reverse keys
            , filter even keys <> filter odd keys
            , drop (count `div` 2) keys <> take (count `div` 2) keys
            , concatMap (replicate 2) keys
            ]
      forM_ (zip [0 :: Int ..] orders) $ \(orderIndex, selected) -> do
        let pairs = [(key, 3 * key) | key <- selected]
            insertPair prior (key, item) = Map.insert key item prior
        usage <- mapUsage (length selected)
        histories <- evaluate (scanl' insertPair Map.empty pairs)
        actual <- evaluate (Map.fromList pairs)
        -- Validity traverses every child; Strict.Map already forces these Int payloads.
        assertBool "actual insertion history contains an invalid tree" (all MapDebug.valid histories)
        assertBool "actual fromList contains an invalid tree" (MapDebug.valid actual)
        Map.toAscList actual @?= Map.toAscList (last histories)
        performGC
        (observedResult, _) <- observeGraphBytes actual
        (observedHistory, _) <- observeGraphBytes histories
        let operations = fromIntegral (length selected)
            -- Boxed keys/values and the shared Tip are separate from construction.
            payloadData = 32 * operations + 16
            historyListData = 16 + 24 * (operations + 1)
            constructed = ordinaryCapturedMapConstructionDataBytes usage
            height = if operations == 0 then 0 else canonicalDhallMapEntryHeightSum usage `div` operations
        assertBool
          "actual map depth exceeds the source-derived height"
          (all ((<= height) . mapHeight) histories)
        assertBool
          "actual Map.fromList result exceeds its constructor-data term"
          (observedResult <= toInteger (constructed + payloadData))
        assertBool
          "Map insertion history exceeds its prospective construction-data term"
          (observedHistory <= toInteger (constructed + payloadData + historyListData))
        when (count == 128 && orderIndex == 1) $
          assertBool
            "fixture no longer distinguishes insertion history from one settled Map"
            (observedHistory > toInteger (48 * operations + payloadData + historyListData))

  it "seen-Set construction funds actual retained insertion histories" $
    forM_ [0, 1, 2, 3, 7, 31, 128, 256] $ \count -> do
      let keys = [0 .. count - 1] :: [Int]
          orders =
            [ keys
            , reverse keys
            , filter even keys <> filter odd keys
            , drop (count `div` 2) keys <> take (count `div` 2) keys
            , concatMap (replicate 2) keys
            ]
      forM_ (zip [0 :: Int ..] orders) $ \(orderIndex, selected) -> do
        usage <- mapUsage (length selected)
        histories <- evaluate (scanl' (flip Set.insert) Set.empty selected)
        -- valid traverses every child and size; strict Int keys need no payload traversal.
        assertBool "actual insertion produced an invalid balanced tree" (all SetInternal.valid histories)
        performGC
        (observed, _) <- observeGraphBytes histories
        let operations = fromIntegral (length selected)
            -- List/Nil, boxed Int keys and shared Set Tip are not Bin allocations.
            otherData = 16 + 24 * (operations + 1) + 16 * operations + 16
            allocatedBins = ordinaryCapturedMapSeenSetAllocationBytes usage
            height = if operations == 0 then 0 else canonicalDhallMapEntryHeightSum usage `div` operations
        assertBool
          "actual Set depth exceeds the source-derived height"
          (all ((<= height) . setHeight) histories)
        assertBool
          "Set insertion history exceeds the prospective Bin construction term"
          (observed <= toInteger (allocatedBins + otherData))
        when (count == 128 && orderIndex == 0) $
          assertBool
            "fixture no longer distinguishes allocation history from a settled Set"
            (observed > toInteger (ordinaryCapturedMapSeenSetBytes usage + otherData))

  it "record and union maps retain their separate construction counts" $ do
    let recordType fields =
          Core.Record
            (DhallMap.fromList [(key, Core.makeRecordField fieldValue) | (key, fieldValue) <- fields])
        recordValue fields =
          Core.RecordLit
            (DhallMap.fromList [(key, Core.makeRecordField fieldValue) | (key, fieldValue) <- fields])
        alternatives = Core.Union (DhallMap.fromList [("A", Just Core.Natural), ("B", Nothing), ("C", Just Core.Text)])
        keys = ["a", "b", "c", "d"]
        declared = recordType [("nested", recordType [(key, Core.Natural) | key <- keys]), ("choice", alternatives)]
        value :: Core.Expr Void Void
        value =
          recordValue
            [ ("nested", recordValue [(key, Core.NaturalLit 0) | key <- keys])
            , ("choice", Core.Field alternatives (Core.makeFieldSelection "B"))
            ]
    shape <- right (compileClosedDhallValueShape declared)
    usage <-
      right (measureCanonicalDhallValueShape shape (Lazy.toStrict (Binary.encodeExpression value)))
    canonicalDhallRecordFields usage @?= 6
    canonicalDhallUnionAlternatives usage @?= 3
    -- The three maps have 2, 4 and 3 entries; their height bounds are 2, 3 and 2.
    canonicalDhallMapEntryHeightSum usage @?= 22
    flat <- mapUsage 9
    assertBool
      "separate small maps were charged as one combined Set"
      (ordinaryCapturedMapSeenSetAllocationBytes usage < ordinaryCapturedMapSeenSetAllocationBytes flat)

  it "authored shape requirements preserve wide fields and refuse only mismatched declarations" $ do
    ordinary <-
      right (compileClosedDhallValueShape (Dhall.declared (Dhall.inject @Capacity.RuntimeMemoryProfile)))
    required <- right (fixedProfileShape ordinary)
    bound <-
      maybe
        (fail "required fixed profile has no structural bound")
        pure
        (boundCanonicalDhallValueShape required)
    let normal =
          Capacity.RuntimeMemoryProfile
            "ordinary-cascade-host"
            1
            2
            3
            4
            128
            6
            (Capacity.ChildProcessBudgetConfig (Just 2) (Just 30000) [64, 16])
            8
            9
        child = Capacity.child_process_budget normal
        wide =
          normal
            { Capacity.child_process_budget = child {Capacity.simultaneous_peak_bytes = [0, 2 ^ (4096 :: Int)]}
            }
        invalid =
          [ normal {Capacity.runtime_profile_id = "foreign"}
          , normal {Capacity.child_process_budget = child {Capacity.permit_capacity = Nothing}}
          , normal {Capacity.child_process_budget = child {Capacity.permit_capacity = Just 3}}
          , normal {Capacity.child_process_budget = child {Capacity.simultaneous_peak_bytes = [64]}}
          ]
    forM_ [normal, wide] $ \profile -> do
      let bytes = profileBytes profile
      usage <- right (measureCanonicalDhallValueShape required bytes)
      plain <- right (measureCanonicalDhallValueShape ordinary bytes)
      usage @?= plain
      assertBool
        "fixed profile bound undercounts accepted structure"
        ( canonicalDhallNormalFormBytes (canonicalDhallNormalForm usage)
            <= canonicalDhallNormalFormBytes
              (canonicalDhallBoundNormalForm (fromIntegral (Bytes.length bytes)) bound)
        )
    forM_ invalid $ \profile -> do
      _ <- right (measureCanonicalDhallValueShape ordinary (profileBytes profile))
      case measureCanonicalDhallValueShape required (profileBytes profile) of
        Left CanonicalDhallValueRequirementMismatch -> pure ()
        _ -> assertFailure "mismatched authored requirement was accepted"

  it "unbounded lists have no finite value bound while a required empty list does" $ do
    ordinary <- right (compileClosedDhallValueShape (Dhall.declared (Dhall.inject @[[Natural]])))
    assertBool
      "unbounded list was assigned a finite value bound"
      (isNothing (boundCanonicalDhallValueShape ordinary))
    required <- right (requireCanonicalDhallValue [] (RequireListElements 0) ordinary)
    bound <-
      maybe
        (fail "required empty list has no structural bound")
        pure
        (boundCanonicalDhallValueShape required)
    let encodeValues value =
          Lazy.toStrict
            (Binary.encodeExpression (Core.denote (Dhall.embed (Dhall.inject @[[Natural]]) value)))
        bytes = encodeValues []
    usage <- right (measureCanonicalDhallValueShape required bytes)
    assertBool
      "empty-list type data escapes its finite bound"
      ( canonicalDhallNormalFormBytes (canonicalDhallNormalForm usage)
          <= canonicalDhallNormalFormBytes
            (canonicalDhallBoundNormalForm (fromIntegral (Bytes.length bytes)) bound)
      )
    case measureCanonicalDhallValueShape required (encodeValues [[]]) of
      Left CanonicalDhallValueRequirementMismatch -> pure ()
      _ -> assertFailure "required empty list accepted an element"

  it "raw settings extraction preserves typed data and its observed graph" $ do
    (settings, bytes, inspected) <- fixture
    raw <- rawSettings bytes
    extractedRpcBirthSettingsConfig raw @?= Settings.validatedConfig settings
    required <- evaluate (extractedRpcBirthSettingsNormalFormBytes raw)
    let prospective = rpcBirthSettingsExtractedDataBytes (inspectedRpcBirthSettingsUsage inspected)
    assertBool "prospective raw data misses evaluated fields" (required <= prospective)
    performGC
    (observed, _) <- observeGraphBytes raw
    assertBool "raw data model omits reachable state" (observed <= toInteger required)

  it "explicit syntax stages preserve SDK bytes and charge both evaluated graphs" $ do
    (_, bytes, inspected) <- fixture
    raw <- rawSettings bytes
    embedded <- evaluate (embedExtractedRpcBirthSettingsData raw)
    syntax <- evaluate (eraseCanonicalDhallDataSource embedded)
    Lazy.toStrict (Binary.encodeExpression (canonicalDhallDataSyntaxExpression syntax)) @?= bytes
    let !roots = (embedded, syntax)
    performGC
    (observed, _) <- observeGraphBytes roots
    let required = canonicalDhallProducerSyntaxDataBytes (inspectedRpcBirthSettingsUsage inspected)
    assertBool "syntax data term omits a retained stage" (observed <= toInteger required + 24)

  it "prepared settings program retains canonical output and observed token data" $ do
    (_, bytes, inspected) <- fixture
    raw <- rawSettings bytes
    plan <- right (prepareExtractedRpcBirthSettingsEncoding (fromIntegral (Bytes.length bytes)) raw)
    canonicalDhallEncodingWireBytes plan @?= fromIntegral (Bytes.length bytes)
    actual <- right (encodePreparedCanonicalDhallData plan)
    actual @?= bytes
    required <- evaluate (canonicalDhallEncodingNormalFormBytes plan)
    assertBool
      "prospective program term misses returned tokens"
      (required <= settingsCanonicalProgramBytes (inspectedRpcBirthSettingsUsage inspected))
    performGC
    (observed, _) <- observeGraphBytes plan
    assertBool "prepared token data model omits retained state" (observed <= toInteger required)

  it "encoding ceiling is checked before a later producer suffix" $ do
    let encoding =
          Encoding.encodeListLen 2
            <> Encoding.encodeString "normal"
            <> error "unfunded producer suffix evaluated"
        limit = fromIntegral (Bytes.length (Write.toStrictByteString (Encoding.encodeListLen 2)))
    case prepareCanonicalDhallDataEncoding limit encoding of
      Left CanonicalDhallEncodingTooLarge -> pure ()
      _ -> assertFailure "oversized prefix did not refuse"

  it "unsupported token constructors return typed refusal" $
    forM_
      [ Encoding.encodeInt (-1)
      , Encoding.encodeBytes "bytes"
      , Encoding.encodeListLenIndef
      , Encoding.encodeDouble 1.5
      ]
      assertUnsupportedToken

  it "fixed syntax bounds preserve arbitrary-width Natural data" $ do
    shape <- right (compileClosedDhallValueShape Core.Natural)
    bound <-
      maybe
        (fail "fixed Natural shape has no finite syntax bound")
        pure
        (boundCanonicalDhallValueShape shape)
    forM_ ([0, 1, 2 ^ (64 :: Int), 2 ^ (512 :: Int), 2 ^ (4096 :: Int)] :: [Natural]) $ \number -> do
      let expression = Core.NaturalLit number :: Core.Expr Void Void
          bytes = Lazy.toStrict (Binary.encodeExpression expression)
          required =
            canonicalDhallNormalFormBytes
              (canonicalDhallBoundNormalForm (fromIntegral (Bytes.length bytes)) bound)
      usage <- right (measureCanonicalDhallValueShape shape bytes)
      assertBool
        "fixed bound lost a supported scalar"
        (canonicalDhallNormalFormBytes (canonicalDhallNormalForm usage) <= required)

  it "Generic field selection agrees with SDK framing for both selected kinds" $
    forM_ [[], "normal", ['λ', chr 0x10000, chr 0xd800]] $ \directory -> do
      let memory = Bytes.pack [1, 2, 3, 4]
          encoded =
            Lazy.toStrict
              (serialise (WireRequest "prefix" (WireContainer 7 memory (SerialiseString directory)) 9))
      selected <-
        right
          ( locateOrdinaryWireProfile
              (ordinaryWireProfileLayout (Proxy @WireRequest) (Proxy @WireContainer))
              4
              encoded
          )
      selected @?= memory
      selectedString <-
        right
          ( locateOrdinaryWireString
              (ordinaryWireFieldLayout (Proxy @WireRequest) (Proxy @WireContainer) (Proxy @SerialiseString))
              4096
              encoded
          )
      generalisedUtf8ScalarCount selectedString @?= Just (fromIntegral (length directory))
      assertBool
        "selection ignores its field ceiling"
        ( isLeft
            ( locateOrdinaryWireProfile
                (ordinaryWireProfileLayout (Proxy @WireRequest) (Proxy @WireContainer))
                3
                encoded
            )
        )

  it "retains both inspection templates and all shared field-table data before either input branch" $ do
    total <- evaluate ordinaryCapturedFixedMetadataDataBytes
    total
      @?= rpcBirthSettingsShapeDataBytes
        + ordinaryMemoryProfileShapeDataBytes
        + fieldNameTablesDataBytes
        + 128
    graph <- observeGraph total
    observedDataBytes graph @?= 16
    print ("fixed_input_metadata_data" :: String, total, fieldNameTablesDataBytes)

  it "compact source and budget metadata terms bound observed owned data" $ do
    (_, bytes, inspected) <- fixture
    usage <- profileUsage
    forM_ [0 .. 7] $ \padding -> do
      command <- evaluate (Bytes.copy (Bytes.replicate (17 + padding) 7))
      settings <- evaluate (Bytes.copy bytes)
      let budget =
            ordinaryCapturedInputBudget
              (fromIntegral (Bytes.length command))
              (inspectedRpcBirthSettingsUsage inspected)
              usage
      metadata <- evaluate (ordinaryCapturedInputBudgetNormalFormBytes budget)
      let !roots = (command, settings)
      performGC
      (sourceObserved, _) <- observeGraphBytes roots
      (metadataObserved, _) <- observeGraphBytes budget
      assertBool
        "source term omits compact backing data"
        (sourceObserved <= toInteger (ordinaryCapturedSourceBytes budget) + 24)
      assertBool "budget metadata term omits fields" (metadataObserved <= toInteger metadata)
      case checkOrdinaryCapturedInputScratch (ordinaryCapturedMinimumScratchBytes budget - 1) budget of
        Left OrdinaryCapturedInputScratchUnderfunded {} -> pure ()
        _ -> assertFailure "scratch underfunding did not refuse"

profileBytes :: Capacity.RuntimeMemoryProfile -> Bytes.ByteString
profileBytes = Lazy.toStrict . Binary.encodeExpression . Core.denote . Dhall.embed Dhall.inject

assertUnsupportedToken :: Encoding.Encoding -> IO ()
assertUnsupportedToken encoding = case prepareCanonicalDhallDataEncoding 4096 encoding of
  Left CanonicalDhallEncodingUnsupportedToken -> pure ()
  _ -> assertFailure "unsupported closed-data token accepted"

fixedProfileShape
  :: CanonicalDhallValueShape -> Either CanonicalDhallValueShapeError CanonicalDhallValueShape
fixedProfileShape original =
  requireCanonicalDhallValue ["runtime_profile_id"] (RequireText "ordinary-cascade-host") original
    >>= requireCanonicalDhallValue ["child_process_budget", "permit_capacity"] (RequirePresentNatural 2)
    >>= requireCanonicalDhallValue
      ["child_process_budget", "simultaneous_peak_bytes"]
      (RequireListElements 2)
