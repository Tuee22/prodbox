{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE UnboxedTuples #-}

module EmbeddedHomeKubeconfigStorage (embeddedHomeKubeconfigStorageSuite) where

import Control.Exception (evaluate)
import Control.Monad (forM_)
import Data.Aeson (encode, object, (.=))
import Data.ByteString qualified as Bytes
import Data.ByteString.Internal qualified as BytesInternal
import Data.ByteString.Lazy qualified as Lazy
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Exts
  ( Int (I#)
  , MutableByteArray#
  , RealWorld
  , State#
  , getSizeofMutableByteArray#
  , isTrue#
  , sameMutableByteArray#
  )
import GHC.Exts.Heap qualified as Heap
import GHC.ForeignPtr (ForeignPtr (..), ForeignPtrContents (..))
import GHC.IO (IO (IO))
import PinnedHeapGraph (observeGraphBytes)
import Prodbox.Lifecycle.Teardown.EphemeralKubectl
import System.Mem (performGC)
import Test.Tasty.HUnit
import TestSupport (SuiteBuilder, describe, it)

embeddedHomeKubeconfigStorageSuite :: SuiteBuilder ()
embeddedHomeKubeconfigStorageSuite = describe "embedded kubeconfig storage" $ do
  it "successful validation finishes the payload copy" $ do
    accepted <- evaluate (prepareEmbeddedHomeKubeconfig (fixture 2000))
    outer <- Heap.getBoxedClosureData (Heap.asBox accepted)
    case outer of
      Heap.ConstrClosure _ [payload] _ _ _ "Right" -> do
        stored <- Heap.getBoxedClosureData payload
        case stored of
          Heap.ConstrClosure _ pointers words_ _ moduleName constructor ->
            (moduleName, constructor, length pointers, length words_)
              @?= ("Data.ByteString.Internal.Type", "BS", 1, 2)
          other -> assertFailure ("successful validation retained unevaluated storage: " <> take 300 (show other))
      other -> assertFailure ("synthetic fixture refused: " <> take 300 (show other))
  it "payload owns exactly its visible capacity across encoder chunk boundaries" $
    forM_ sizes $ \size -> do
      embedded <- right (prepareEmbeddedHomeKubeconfig (fixture size))
      let bytes = embeddedHomeKubeconfigBytes embedded
      capacity bytes >>= (@?= Bytes.length bytes)
  it "nonzero-offset source detaches from a large caller allocation" $ do
    let input = fixture 2000
        backing = Bytes.concat [Bytes.replicate 17 0, input, Bytes.replicate 1048576 0]
        view = Bytes.take (Bytes.length input) (Bytes.drop 17 backing)
    sharesBacking backing view >>= (@?= True)
    embedded <- right (prepareEmbeddedHomeKubeconfig view)
    let stored = embeddedHomeKubeconfigBytes embedded
    sharesBacking backing stored >>= (@?= False)
    capacity stored >>= (@?= Bytes.length stored)
  it "complete quiescent graph fits the compact term" $
    forM_ sizes $ \size -> do
      embedded <- right (prepareEmbeddedHomeKubeconfig (fixture size))
      declared <- evaluate (embeddedHomeKubeconfigNormalFormBytes embedded)
      performGC
      (observed, nodes) <- observeGraphBytes embedded
      assertBool
        ("payload graph=" <> show observed <> " in " <> show nodes <> " closures; declared=" <> show declared)
        (observed <= toInteger declared)
  it "normalization preserves the selected certificate projection" $
    forM_ sizes $ \size -> do
      embedded <- right (prepareEmbeddedHomeKubeconfig (fixture size))
      embeddedHomeKubeconfigBytes embedded @?= fixture size

sizes :: [Int]
sizes = [1, 64, 500, 1000, 1500, 2000, 2500, 3000, 4000, 8000, 16000, 32000]

right :: (Show err) => Either err value -> IO value
right = either (fail . show) pure

fixture :: Int -> Bytes.ByteString
fixture size =
  Lazy.toStrict $
    encode $
      object
        [ "apiVersion" .= ("v1" :: Text)
        , "kind" .= ("Config" :: Text)
        , "current-context" .= ("local" :: Text)
        , "clusters"
            .= [ object
                   [ "name" .= ("local" :: Text)
                   , "cluster"
                       .= object
                         [ "server" .= ("https://127.0.0.1:6443" :: Text)
                         , "certificate-authority-data" .= Text.replicate size "A"
                         ]
                   ]
               ]
        , "contexts"
            .= [ object
                   [ "name" .= ("local" :: Text)
                   , "context" .= object ["cluster" .= ("local" :: Text), "user" .= ("local" :: Text)]
                   ]
               ]
        , "users"
            .= [ object
                   [ "name" .= ("local" :: Text)
                   , "user"
                       .= object ["client-certificate-data" .= ("CERT" :: Text), "client-key-data" .= ("SYNTHETIC" :: Text)]
                   ]
               ]
        ]

origin :: Bytes.ByteString -> ForeignPtrContents
origin bytes = case BytesInternal.toForeignPtr bytes of
  (ForeignPtr _ contents, _, _) -> contents

capacity :: Bytes.ByteString -> IO Int
capacity bytes = case origin bytes of
  PlainPtr array -> IO (arrayCapacity array)
  _ -> fail "pinned PlainPtr origin required"

arrayCapacity :: MutableByteArray# RealWorld -> State# RealWorld -> (# State# RealWorld, Int #)
arrayCapacity array state = case getSizeofMutableByteArray# array state of
  (# next, size #) -> (# next, I# size #)

sharesBacking :: Bytes.ByteString -> Bytes.ByteString -> IO Bool
sharesBacking first second = case (origin first, origin second) of
  (PlainPtr firstArray, PlainPtr secondArray) -> pure (isTrue# (sameMutableByteArray# firstArray secondArray))
  _ -> fail "pinned PlainPtr backings required"
