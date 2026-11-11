{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE UnboxedTuples #-}

module OrdinaryMemoryProfileCodec (ordinaryMemoryProfileSuite) where

import Codec.CBOR.Decoding qualified as Decoding
import Codec.CBOR.Read qualified as Cbor
import Codec.CBOR.Term (Term (..))
import Codec.Serialise (deserialiseOrFail, serialise)
import Control.Exception (evaluate)
import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as Bytes
import Data.ByteString.Internal qualified as BytesInternal
import Data.ByteString.Lazy qualified as Lazy
import Data.Either (isLeft)
import Dhall qualified
import Dhall.Binary qualified as Binary
import Dhall.Core qualified as Core
import GHC.Exts (Int (I#), MutableByteArray#, RealWorld, State#, getSizeofMutableByteArray#)
import GHC.Exts.Heap qualified as Heap
import GHC.ForeignPtr (ForeignPtr (..), ForeignPtrContents (..))
import GHC.IO (IO (IO))
import Numeric.Natural (Natural)
import PinnedHeapGraph (observeGraphBytes)
import Prodbox.Capacity.BoxedNormalForm (boxedByteViewBytes, boxedRecordBytes)
import Prodbox.Capacity.Config qualified as C
import Prodbox.Capacity.SettingsNormalForm (runtimeProfileNormalFormBytes)
import Prodbox.Config.OrdinaryMemoryProfile
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

sdk :: C.RuntimeMemoryProfile -> ByteString
sdk = Lazy.toStrict . Binary.encodeExpression . Core.denote . Dhall.embed Dhall.inject

roundtrip :: C.RuntimeMemoryProfile -> IO ()
roundtrip value = do
  direct <- right (encodeOrdinaryMemoryProfile value)
  direct @?= sdk value
  size <- right (ordinaryMemoryProfileWireBytes value)
  size @?= fromIntegral (Bytes.length direct)
  capacity direct >>= (@?= fromIntegral (ordinaryMemoryProfileEncodingBufferBytes size))
  decoded <- right (decodeOrdinaryMemoryProfile direct)
  decoded @?= value
  assertBool
    "strict typed profile exceeds its prospective structural bound"
    ( runtimeProfileNormalFormBytes decoded
        <= ordinaryMemoryProfileNormalFormBound (fromIntegral (Bytes.length direct))
    )

rewrite :: ([(Term, Term)] -> [(Term, Term)]) -> ByteString -> IO ByteString
rewrite change bytes = do
  root <- right (deserialiseOrFail (Lazy.fromStrict bytes))
  case root of
    TList [tag, TMap fields] -> pure (Lazy.toStrict (serialise (TList [tag, TMap (change fields)])))
    _ -> fail "SDK record fixture shape"

replaceFirstValue :: Term -> [(Term, Term)] -> [(Term, Term)]
replaceFirstValue _ [] = []
replaceFirstValue replacement ((name, _) : rest) = (name, replacement) : rest

withOther :: Natural -> C.RuntimeMemoryProfile
withOther value = base {C.other_heap_reserve_bytes = value}

ordinaryMemoryProfileSuite :: SuiteBuilder ()
ordinaryMemoryProfileSuite = describe "strict ordinary profile codec and data storage" $ do
  it "decoded Integer and Natural coexist within one scalar data envelope"
    $ forM_
      [ 0
      , 1
      , 2 ^ (63 :: Int) - 1
      , 2 ^ (63 :: Int)
      , 2 ^ (64 :: Int) - 1
      , 2 ^ (64 :: Int)
      , 2 ^ (8192 :: Int)
      , 2 ^ (8 * 65000 :: Int) - 1
      ]
    $ \value -> do
      let encoded = serialise (toInteger (value :: Natural))
      (_, integerValue) <- right (Cbor.deserialiseFromBytes Decoding.decodeInteger encoded)
      _ <- evaluate integerValue
      naturalValue <- evaluate (fromInteger integerValue :: Natural)
      let pair = (integerValue, naturalValue)
      performGC
      (observed, _) <- observeGraphBytes pair
      let term = ordinaryMemoryProfileScalarValueBytes (fromIntegral (Lazy.length encoded))
      assertBool
        "positive scalar data exceeds the byte-derived envelope"
        (observed <= toInteger (boxedRecordBytes [0, 0] + term))
      naturalValue @?= value
  it "negative bignum values refuse" $ do
    source <-
      rewrite
        (replaceFirstValue (TList [TInt 15, TInteger (negate (2 ^ (8 * 60000 :: Int)))]))
        (sdk base)
    decodeOrdinaryMemoryProfile source @?= Left OrdinaryMemoryProfileMalformed
  it "nonminimal fixed headers retain canonical refusal" $ do
    let source = sdk base
        replace offset count replacement =
          Bytes.take offset source <> Bytes.pack replacement <> Bytes.drop (offset + count) source
    forM_
      [ replace 0 1 [0x98, 2]
      , replace 1 1 [0x18, 8]
      , replace 2 1 [0xb8, 10]
      , replace 3 2 [0x79, 0, fromIntegral (Bytes.index source 4)]
      ]
      $ \bytes -> decodeOrdinaryMemoryProfile bytes @?= Left OrdinaryMemoryProfileNonCanonical
  it "all machine integer and bignum byte boundaries keep exact SDK bytes" $
    forM_ [0 .. 1024 :: Int] $ \bits ->
      forM_ [2 ^ bits - 1, 2 ^ bits, 2 ^ bits + 1 :: Natural] $ \value -> roundtrip (withOther value)
  it "optional deadlines and both peaks keep arbitrary-width values" $
    forM_ [Nothing, Just 0, Just 30000, Just (2 ^ (8192 :: Int))] $ \deadline ->
      forM_ [0, 1, 2 ^ (512 :: Int), 2 ^ (8192 :: Int)] $ \peak ->
        roundtrip
          (base {C.child_process_budget = C.ChildProcessBudgetConfig (Just 2) deadline [peak, peak]})
  it "all ten top-level fields survive independently" $
    forM_ [0 .. 7 :: Natural] $ \offset -> do
      let value =
            C.RuntimeMemoryProfile
              "ordinary-cascade-host"
              (11 + offset)
              (22 + offset)
              (33 + offset)
              (44 + offset)
              (55 + offset)
              (66 + offset)
              (C.ChildProcessBudgetConfig (Just 2) (Just (77 + offset)) [88 + offset, 99 + offset])
              (111 + offset)
              (222 + offset)
      roundtrip value
  it "the exact 64-KiB boundary keeps the original encoded domain" $ do
    let fits bytes = Bytes.length (sdk (withOther (2 ^ (8 * bytes :: Int) - 1))) <= ordinaryMemoryProfileMaximumBytes
        search low high
          | low + 1 >= high = low
          | fits middle = search middle high
          | otherwise = search low middle
         where
          middle = (low + high) `div` 2
        largest = search 1 ordinaryMemoryProfileMaximumBytes
        accepted = withOther (2 ^ (8 * largest :: Int) - 1)
        refused = withOther (2 ^ (8 * (largest + 1) :: Int) - 1)
    Bytes.length (sdk accepted) @?= ordinaryMemoryProfileMaximumBytes
    roundtrip accepted
    encodeOrdinaryMemoryProfile refused @?= Left OrdinaryMemoryProfileTooLarge
    ordinaryMemoryProfileWireBytes refused @?= Left OrdinaryMemoryProfileTooLarge
    decodeOrdinaryMemoryProfile (sdk refused) @?= Left OrdinaryMemoryProfileTooLarge
  it "fixed ordinary semantics preserve the prior final profile domain" $
    forM_ [Nothing, Just 0, Just 1, Just (2 ^ (512 :: Int))] $ \permit -> do
      let value = base {C.child_process_budget = C.ChildProcessBudgetConfig permit (Just 30000) [1, 2]}
      encodeOrdinaryMemoryProfile value @?= Left OrdinaryMemoryProfileInvalid
      assertBool "invalid permit accepted" (isLeft (decodeOrdinaryMemoryProfile (sdk value)))
  it "unrelated profile identities and extra peaks refuse" $ do
    encodeOrdinaryMemoryProfile (base {C.runtime_profile_id = "other"})
      @?= Left OrdinaryMemoryProfileInvalid
    forM_ [[], [1], [1, 2, 3], replicate 4096 1] $ \peaks -> do
      let value = base {C.child_process_budget = C.ChildProcessBudgetConfig (Just 2) (Just 30000) peaks}
      encodeOrdinaryMemoryProfile value @?= Left OrdinaryMemoryProfileInvalid
      assertBool "invalid peak count accepted" (isLeft (decodeOrdinaryMemoryProfile (sdk value)))
  it "trailing, absent, truncated and oversized payloads refuse" $ do
    let bytes = sdk base
    forM_ [Bytes.empty, Bytes.init bytes, bytes <> Bytes.singleton 0, Bytes.replicate 65537 0] $ \bad ->
      assertBool "invalid data framing accepted" (isLeft (decodeOrdinaryMemoryProfile bad))
  it "every proper byte prefix refuses for small and bignum profiles" $
    forM_ [base, withOther (2 ^ (8192 :: Int))] $ \original -> do
      let encoded = sdk original
      forM_ [0 .. Bytes.length encoded - 1] $ \count ->
        assertBool
          "truncated scalar/profile was accepted"
          (isLeft (decodeOrdinaryMemoryProfile (Bytes.take count encoded)))
  it "the final scalar completes in its one held input chunk"
    $ forM_
      [ 0
      , 23
      , 24
      , 255
      , 256
      , 65535
      , 65536
      , 2 ^ (32 :: Int) - 1
      , 2 ^ (32 :: Int)
      , 2 ^ (64 :: Int) - 1
      , 2 ^ (64 :: Int)
      , 2 ^ (8 * 50000 :: Int)
      ]
    $ \value ->
      roundtrip (base {C.safety_margin_bytes = value})
  it "incomplete bignum length headers and unavailable bodies refuse" $ do
    template <- rewrite (replaceFirstValue (TList [TInt 15, TTagged 2 (TBytes Bytes.empty)])) (sdk base)
    let marker = Bytes.pack [0x82, 0x0f, 0xc2, 0x40]
        (prefix, suffix) = Bytes.breakSubstring marker template
    assertBool "fixture lacks the positive bignum marker" (not (Bytes.null suffix))
    forM_
      [ [0x58]
      , [0x59, 0]
      , [0x5a, 0, 0, 0]
      , [0x5b, 0, 0, 0, 0, 0, 0, 0]
      , [0x59, 0xff, 0xff]
      , [0x5a, 0xff, 0xff, 0xff, 0xff]
      , [0x5b, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
      ]
      $ \lengthHeader -> do
        let incomplete = prefix <> Bytes.pack [0x82, 0x0f, 0xc2] <> Bytes.pack lengthHeader
            unavailable = incomplete <> Bytes.drop (Bytes.length marker) suffix
        decodeOrdinaryMemoryProfile incomplete @?= Left OrdinaryMemoryProfileMalformed
        assertBool
          "unavailable or malformed body accepted"
          (isLeft (decodeOrdinaryMemoryProfile unavailable))
  it "complete noncanonical positive bignums retain their classification" $
    forM_ [Bytes.empty, Bytes.singleton 0, Bytes.pack [0, 1], Bytes.replicate 16 0] $ \payload -> do
      source <- rewrite (replaceFirstValue (TList [TInt 15, TTagged 2 (TBytes payload)])) (sdk base)
      decodeOrdinaryMemoryProfile source @?= Left OrdinaryMemoryProfileNonCanonical
  it "field order and unexpected fields cannot become canonical" $ do
    reversed <- rewrite reverse (sdk base)
    assertBool "permuted record accepted" (isLeft (decodeOrdinaryMemoryProfile reversed))
    missing <- rewrite (drop 1) (sdk base)
    assertBool "missing field accepted" (isLeft (decodeOrdinaryMemoryProfile missing))
  it "decoder returns strict typed state without an expression graph" $ do
    let original = withOther (2 ^ (8192 :: Int))
    value <- right (decodeOrdinaryMemoryProfile (sdk original))
    performGC
    (observed, nodes) <- observeGraphBytes value
    let expected = runtimeProfileNormalFormBytes value
    putStrLn
      ("strict_profile_bytes=" <> show observed <> " nodes=" <> show nodes <> " declared=" <> show expected)
    assertBool "typed profile escaped with extra retained state" (observed <= toInteger expected)
  it "simultaneous wide fields fit the typed structural bound" $
    forM_ [1, 8, 64, 1024, 5000 :: Int] $ \payload -> do
      let wide = 2 ^ (8 * payload) - 1
          original =
            C.RuntimeMemoryProfile
              ordinaryMemoryProfileIdentity
              wide
              wide
              wide
              wide
              wide
              wide
              (C.ChildProcessBudgetConfig (Just 2) (Just wide) [wide, wide])
              wide
              wide
      roundtrip original
      value <- right (decodeOrdinaryMemoryProfile (sdk original))
      performGC
      (observed, _) <- observeGraphBytes value
      assertBool
        "wide typed graph exceeds its independently derived bound"
        ( observed
            <= toInteger (ordinaryMemoryProfileNormalFormBound (fromIntegral (Bytes.length (sdk original))))
        )
  it "owned canonical output fits one measured buffer across writer chunk boundaries"
    $ forM_
      [0, 1, 255, 256, 511, 512, 1023, 2048, 4070, 4080, 4096, 8192, 16000, 32000, 50000, 65000 :: Int]
    $ \payload -> do
      let value = withOther (2 ^ (8 * payload) - 1)
      encoded <- right (encodeOrdinaryMemoryProfile value)
      let wanted = ordinaryMemoryProfileEncodingBufferBytes (fromIntegral (Bytes.length encoded))
      capacity encoded >>= (@?= fromIntegral wanted)
      performGC
      (observed, _) <- observeGraphBytes encoded
      assertBool
        "output retained state beyond its one-buffer term"
        (observed <= toInteger (boxedByteViewBytes wanted encoded))
  it "successful preflight returns only bounded evaluated program data" $
    forM_ [Nothing, Just 0, Just (2 ^ (8192 :: Int))] $ \deadline ->
      forM_ [0, 1, 64, 1024, 5000 :: Int] $ \payload -> do
        let wide = 2 ^ (8 * payload) - 1
            value =
              (withOther wide)
                { C.child_process_budget = C.ChildProcessBudgetConfig (Just 2) deadline [wide, wide]
                }
        plan <- right (prepareOrdinaryMemoryProfileEncoding value)
        -- Observe before invoking either sizer; neither can hide an
        -- escaped append, selector or decoder environment by forcing it.
        performGC
        (observed, _) <- observeGraphBytes plan
        let structural = ordinaryMemoryProfileEncodingPlanNormalFormBytes plan
            prospective = ordinaryMemoryProfileEncodingPlanBound (fromIntegral (Bytes.length (sdk value)))
        assertBool "encoding plan retained hidden compiler/data state" (observed <= toInteger structural)
        assertBool "encoding plan exceeds its prospective term" (structural <= prospective)
  it "prospective program term covers simultaneous wide scalar fields" $ do
    let wide = 2 ^ (8 * 5000 :: Int) - 1
        value =
          C.RuntimeMemoryProfile
            ordinaryMemoryProfileIdentity
            wide
            wide
            wide
            wide
            wide
            wide
            (C.ChildProcessBudgetConfig (Just 2) (Just wide) [wide, wide])
            wide
            wide
    plan <- right (prepareOrdinaryMemoryProfileEncoding value)
    performGC
    (observed, _) <- observeGraphBytes plan
    let maximumBytes = ordinaryMemoryProfileEncodingPlanBound 65536
        current = ordinaryMemoryProfileEncodingPlanNormalFormBytes plan
    putStrLn
      ( "encoding_plan_graph_bytes="
          <> show observed
          <> " term="
          <> show current
          <> " maximum="
          <> show maximumBytes
      )
    assertBool "wide plan graph exceeds its data term" (observed <= toInteger current)
    assertBool
      "wide plan data exceeds its prospective term"
      (current <= ordinaryMemoryProfileEncodingPlanBound (fromIntegral (Bytes.length (sdk value))))
  it "distinct wide scalar allocations exercise the program bound without shared backing" $ do
    let wide = 2 ^ (8 * 5000 :: Int) - 1
        value =
          C.RuntimeMemoryProfile
            ordinaryMemoryProfileIdentity
            (wide + 1)
            (wide + 2)
            (wide + 3)
            (wide + 4)
            (wide + 5)
            (wide + 6)
            (C.ChildProcessBudgetConfig (Just 2) (Just (wide + 7)) [wide + 8, wide + 9])
            (wide + 10)
            (wide + 11)
    roundtrip value
    plan <- right (prepareOrdinaryMemoryProfileEncoding value)
    performGC
    (observed, _) <- observeGraphBytes plan
    let structural = ordinaryMemoryProfileEncodingPlanNormalFormBytes plan
        bound = ordinaryMemoryProfileEncodingPlanBound (fromIntegral (Bytes.length (sdk value)))
    putStrLn
      ( "distinct_encoding_plan_graph_bytes="
          <> show observed
          <> " term="
          <> show structural
          <> " bound="
          <> show bound
      )
    assertBool "wide scalar arrays still share the fixture's allocation" (observed > 11 * 5000)
    assertBool "distinct program graph exceeds its structural term" (observed <= toInteger structural)
    assertBool "distinct program data exceeds its prospective bound" (structural <= bound)
  it "native token and Integer roots fit the independently declared token term"
    $ forM_
      [2 ^ (63 :: Int) - 1, 2 ^ (63 :: Int), 2 ^ (64 :: Int) - 1, 2 ^ (64 :: Int), 2 ^ (8192 :: Int)]
    $ \wide ->
      forM_ [Nothing, Just wide] $ \deadline -> do
        let value =
              (withOther wide)
                { C.child_process_budget = C.ChildProcessBudgetConfig (Just 2) deadline [wide + 1, wide + 2]
                }
        roundtrip value
        plan <- right (prepareOrdinaryMemoryProfileEncoding value)
        performGC
        outer <- Heap.getBoxedClosureData (Heap.asBox plan)
        case outer of
          Heap.ConstrClosure
            _
            [_, _, Heap.Box tokens]
            []
            _
            "Prodbox.Config.OrdinaryMemoryProfile"
            "EncodingPlan" -> do
              (observed, nodes) <- observeGraphBytes tokens
              let term = ordinaryMemoryProfileEncodingPlanTokenNormalFormBytes plan
              assertBool "no native tokens were observed" (observed > 0 && nodes > 0)
              assertBool "token/Integer data escaped its structural reservation" (observed <= toInteger term)
          other -> assertFailure ("unexpected prepared-token ABI: " <> take 250 (show other))
  it "huge producer values fail the existing wire-size preflight" $ do
    huge <- evaluate (2 ^ (8 * 8 * 1048576 :: Int) :: Natural)
    let value = withOther huge
    ordinaryMemoryProfileWireBytes value @?= Left OrdinaryMemoryProfileTooLarge
    encodeOrdinaryMemoryProfile value @?= Left OrdinaryMemoryProfileTooLarge

capacity :: Bytes.ByteString -> IO Int
capacity bytes = case BytesInternal.toForeignPtr bytes of
  (ForeignPtr _ (PlainPtr array), _, _) -> IO (arrayCapacity array)
  _ -> fail "single-writer-buffer control requires pinned PlainPtr backing"

arrayCapacity :: MutableByteArray# RealWorld -> State# RealWorld -> (# State# RealWorld, Int #)
arrayCapacity array state = case getSizeofMutableByteArray# array state of
  (# next, size #) -> (# next, I# size #)
