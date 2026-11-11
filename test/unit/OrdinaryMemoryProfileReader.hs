{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

module OrdinaryMemoryProfileReader (ordinaryMemoryProfileReaderSuite) where

import Control.Exception (evaluate)
import Data.ByteString qualified as Bytes
import Data.Proxy (Proxy (..))
import GHC.Exts.Heap qualified as Heap
import GHC.Exts.Heap.Closures (closureSize)
import Numeric.Natural (Natural)
import PinnedHeapGraph (observeGraphBytes)
import Prodbox.Capacity.Config qualified as C
import Prodbox.Config.OrdinaryMemoryProfile qualified as Profile
import Prodbox.Config.OrdinaryMemoryProfile.Reader qualified as Reader
import System.Mem (performGC)
import Test.Tasty.HUnit
import TestSupport (SuiteBuilder, describe, it)

right :: (Show err) => Either err value -> IO value
right = either (fail . show) pure

base :: C.RuntimeMemoryProfile
base =
  C.RuntimeMemoryProfile
    "ordinary-cascade-host"
    2
    1
    16
    24
    128
    32
    (C.ChildProcessBudgetConfig (Just 2) (Just 30000) [64, 16])
    8
    8

ordinaryMemoryProfileReaderSuite :: SuiteBuilder ()
ordinaryMemoryProfileReaderSuite = describe "strict ordinary profile reader states" $ do
  mapM_
    ( \(name, value) -> it name $ do
        wire <- right (Profile.encodeOrdinaryMemoryProfile value)
        let source = Bytes.concat [Bytes.replicate 65536 0, wire]
            input = Bytes.drop 65536 source
        firstStep <- evaluate (Reader.beginProfile input)
        checkProfileStates source (fromIntegral (Bytes.length wire)) 0 firstStep value
    )
    profileMachineValues
  mapM_
    ( \(name, transform) -> it name $ do
        wire <- right (Profile.encodeOrdinaryMemoryProfile base)
        let input = transform wire
        refused <- terminal 0 (Reader.beginProfile input)
        case refused of
          Reader.ProfileRefused cause -> do
            cause @?= Profile.OrdinaryMemoryProfileMalformed
            case Reader.stepProfile refused of
              Reader.ProfileRefused repeated -> repeated @?= cause
              _ -> assertFailure "refused reader resumed"
            Profile.decodeOrdinaryMemoryProfile input @?= Left cause
          _ -> assertFailure "malformed profile reached a decoded state"
    )
    [ ("empty input refuses permanently", const Bytes.empty)
    , ("wrong outer tag refuses permanently", \wire -> Bytes.singleton 0 <> Bytes.tail wire)
    , ("missing final scalar refuses permanently", Bytes.init)
    , ("truncated fixed label refuses permanently", Bytes.take 12)
    ]

terminal :: Int -> Reader.ProfileStep -> IO Reader.ProfileStep
terminal count step = do
  assertBool "reader exceeded its finite phase set" (count <= 14)
  case step of
    Reader.ProfileProgress {} -> evaluate (Reader.stepProfile step) >>= terminal (count + 1)
    _ -> pure step

profileMachineValues :: [(String, C.RuntimeMemoryProfile)]
profileMachineValues =
  [ ("baseline", base)
  ,
    ( "no deadline"
    , base
        { C.child_process_budget = (C.child_process_budget base) {C.action_deadline_milliseconds = Nothing}
        }
    )
  ,
    ( "wide values"
    , base
        { C.bounded_application_state_bytes = 2 ^ (32768 :: Int)
        , C.safety_margin_bytes = 2 ^ (8192 :: Int)
        , C.child_process_budget =
            (C.child_process_budget base)
              { C.action_deadline_milliseconds = Just (2 ^ (2048 :: Int))
              , C.simultaneous_peak_bytes = [2 ^ (4096 :: Int), 2 ^ (4097 :: Int)]
              }
        }
    )
  ,
    ( "zero values"
    , C.RuntimeMemoryProfile
        "ordinary-cascade-host"
        0
        0
        0
        0
        0
        0
        (C.ChildProcessBudgetConfig (Just 2) Nothing [0, 0])
        0
        0
    )
  ]

checkProfileStates
  :: Bytes.ByteString -> Natural -> Int -> Reader.ProfileStep -> C.RuntimeMemoryProfile -> IO ()
checkProfileStates source wireBytes count current expected = do
  assertBool "fixed reader did not terminate in its finite phase set" (count <= 16)
  next <- evaluate (Reader.stepProfile current)
  checkProfileHeaders current
  checkProfileHeaders next
  let !roots = (source, current, next)
  performGC
  (sourceBytes, _) <- observeGraphBytes source
  (allBytes, _) <- observeGraphBytes roots
  let allowed =
        Profile.ordinaryMemoryProfileNormalFormBound wireBytes
          + Profile.ordinaryMemoryProfileReaderStepDataBytes
  assertBool
    "current/next reader states exceeded their data term"
    (allBytes - sourceBytes - 32 <= toInteger allowed)
  case next of
    Reader.ProfileRefused cause -> fail (show cause)
    Reader.ProfileProgress {} -> checkProfileStates source wireBytes (count + 1) next expected
    Reader.ProfileDecoded (Reader.ProfileCursor bytes consumed) value -> do
      consumed @?= Bytes.length bytes
      value @?= expected
      count + 1 @?= 14
      case Reader.stepProfile next of
        Reader.ProfileDecoded (Reader.ProfileCursor sameBytes sameConsumed) sameValue -> do
          sameBytes @?= bytes
          sameConsumed @?= consumed
          sameValue @?= value
        _ -> assertFailure "decoded reader resumed"

checkProfileHeaders :: Reader.ProfileStep -> IO ()
checkProfileHeaders step = do
  assertHeaderBound "step" (Reader.constructorHeader (Proxy @Reader.ProfileStep)) step
  case step of
    Reader.ProfileProgress cursor phase -> do
      assertHeaderBound "cursor" (Reader.constructorHeader (Proxy @Reader.ProfileCursor)) cursor
      assertHeaderBound "phase" (Reader.constructorHeader (Proxy @Reader.ProfileState)) phase
    Reader.ProfileDecoded cursor _ -> assertHeaderBound "cursor" (Reader.constructorHeader (Proxy @Reader.ProfileCursor)) cursor
    Reader.ProfileRefused {} -> pure ()

assertHeaderBound :: String -> Natural -> value -> IO ()
assertHeaderBound name bound value = inspect 0 (Heap.asBox value)
 where
  inspect :: Int -> Heap.Box -> IO ()
  inspect depth box = do
    assertBool "unexpected header indirection chain" (depth < 8)
    closure <- Heap.getBoxedClosureData box
    case closure of
      Heap.ConstrClosure {} ->
        assertBool
          (name <> " header exceeds its independently observed size")
          (toInteger (closureSize box) * 8 <= toInteger bound)
      Heap.IndClosure {} -> case Heap.allClosures closure of
        [next] -> inspect (depth + 1) next
        _ -> fail "unexpected indirection fields"
      _ -> fail "reader state header is not a data constructor"
