{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module CapacityNormalForm (capacityNormalFormSuite) where

import Control.Exception (evaluate)
import Control.Monad (forM_)
import Data.Bits (finiteBitSize)
import Data.ByteString qualified as Bytes
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Internal qualified as TextInternal
import Data.Word (Word32, Word64)
import Numeric.Natural (Natural)
import PinnedHeapGraph
  ( observeGraph
  , observeGraphBytes
  , observedDataBytes
  , observedIndirectionBytes
  , observedTotalBytes
  )
import Prodbox.Capacity.BoxedNormalForm
import Prodbox.Capacity.SettingsNormalForm
import Prodbox.Config.Tier0 qualified as Tier0
import Prodbox.ControlPlane.RpcAdmissionBirthConfig (RpcBirthConfig (..), RpcBirthConfigPin (..))
import Prodbox.Settings qualified as Settings
import System.Directory (getCurrentDirectory)
import System.Mem (performGC)
import TestSupport

{-# NOINLINE nextNaturalFixture #-}
nextNaturalFixture :: Natural -> Natural
nextNaturalFixture value = value + 1

{-# NOINLINE staticNaturalFixture #-}
staticNaturalFixture :: Natural
staticNaturalFixture = nextNaturalFixture 0

capacityNormalFormSuite :: SuiteBuilder ()
capacityNormalFormSuite = describe "quiescent boxed storage on the pinned ABI" $ do
  it "keeps primitive representation data separate from live compiler update headers" $ do
    declared <- evaluate (boxedNaturalBytes staticNaturalFixture)
    performGC
    observed <- observeGraph staticNaturalFixture
    observedDataBytes observed `shouldBe` toInteger declared
    observedIndirectionBytes observed `shouldSatisfy` (> 0)
    observedTotalBytes observed `shouldSatisfy` (> toInteger declared)

  it "bounds small and arbitrary-width Natural representation data" $
    forM_ ([0, 1, 2 ^ (64 :: Int), 2 ^ (512 :: Int), 2 ^ (4096 :: Int) + 19] :: [Natural]) $ \value ->
      checkDataGraph boxedNaturalBytes value

  it "funds positive and negative arbitrary-width Integer graphs" $
    forM_ ([0, 1, -1, 2 ^ (64 :: Int), negate (2 ^ (512 :: Int))] :: [Integer]) $ \value ->
      checkGraph boxedIntegerBytes value

  it "funds the pinned scalar constructor layouts" $ do
    checkGraph boxedCharBytes 'λ'
    checkGraph boxedIntBytes (42 :: Int)
    checkGraph boxedWordBytes (42 :: Word)
    checkGraph boxedWord32Bytes (42 :: Word32)
    checkGraph boxedWord64Bytes (42 :: Word64)

  it "charges a text view's actual backing capacity" $ do
    parent <- evaluate (Text.replicate 1048576 "λ")
    -- Construct a valid UTF-8 slice of the actual allocation. Fusion of a
    -- producer with take/drop can otherwise eliminate the large backing.
    view <- evaluate $ case parent of
      TextInternal.Text array offset _ -> TextInternal.Text array (offset + 34) 14
    Text.length view `shouldBe` 7
    declared <- evaluate (boxedTextBytes view)
    payloadOnly <- evaluate (boxedTextBytes (Text.copy view))
    performGC
    (observed, _) <- observeGraphBytes view
    observed `shouldSatisfy` (>= 1048576)
    payloadOnly `shouldSatisfy` ((< observed) . toInteger)
    observed `shouldSatisfy` (<= toInteger declared)

  it "funds the established copied ByteString representation" $
    forM_ [0, 1, 32, 4096] $
      \size -> checkGraph boxedCompactBytes (Bytes.copy (Bytes.replicate size 9))

  it "bounds empty and nested list/optional representation data" $ do
    forM_ [[], [0], [1, 2 ^ (512 :: Int)]] $ \values ->
      checkDataGraph (boxedListBytes boxedNaturalBytes) values
    forM_ [Nothing, Just 0, Just (2 ^ (512 :: Int))] $ \value ->
      checkDataGraph (boxedMaybeBytes boxedNaturalBytes) value

  it "funds the pinned Map node and leaf layout" $
    forM_ [Map.empty, Map.singleton 1 0, Map.fromList [(n, 2 ^ (n + 64)) | n <- [0 .. 12]]] $ \value ->
      checkGraph (boxedMapBytes boxedNaturalBytes boxedNaturalBytes) value

  it "bounds record fields and their child representation data" $
    checkDataGraph
      ( \(text, number, optional) ->
          boxedRecordBytes
            [boxedTextBytes text, boxedNaturalBytes number, boxedMaybeBytes boxedNaturalBytes optional]
      )
      ("record", 2 ^ (512 :: Int), Just 1)

  it "funds all raw and derived fields of captured validated settings" $ do
    root <- getCurrentDirectory
    let context = Tier0.context syntheticProjectConfig
        cluster = Tier0.cluster_id context
        registrations =
          [ RpcBirthConfigLegacy
          , RpcBirthConfigRegistered (RpcBirthConfigPin cluster 1 (Text.replicate 64 "a"))
          , RpcBirthConfigRegistered
              (RpcBirthConfigPin cluster (fromIntegral (maxBound :: Word64)) (Text.replicate 64 "a"))
          ]
    forM_ registrations $ \registration -> do
      let input =
            Settings.DeploymentContextInput
              cluster
              (Tier0.vault_address context)
              (Tier0.minio_endpoint context)
              registration
      decoded <- Settings.validateConfigWithContext root input syntheticConfigFile
      case decoded of
        Left cause -> expectationFailure cause
        Right settings -> checkGraph (settingsNormalFormBytes . settingsNormalForm) settings

checkGraph :: (value -> Natural) -> value -> IO ()
checkGraph projection value = do
  finiteBitSize (0 :: Word) `shouldBe` 64
  declared <- evaluate (projection value)
  performGC
  (observed, _) <- observeGraphBytes value
  observed `shouldSatisfy` (<= toInteger declared)

-- BoxedNormalForm explicitly bounds structural data, excluding compiler
-- closures. Keep that law distinct from the stronger complete-graph checks
-- above; the static-Natural case proves the two observations can disagree.
checkDataGraph :: (value -> Natural) -> value -> IO ()
checkDataGraph projection value = do
  finiteBitSize (0 :: Word) `shouldBe` 64
  declared <- evaluate (projection value)
  performGC
  observed <- observeGraph value
  observedDataBytes observed `shouldSatisfy` (<= toInteger declared)
