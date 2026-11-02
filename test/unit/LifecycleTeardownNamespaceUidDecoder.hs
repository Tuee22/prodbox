{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleTeardownNamespaceUidDecoder (namespaceUidDecoderSuite) where

import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import NamespaceUidProbeFixture qualified as Fixture
import Prodbox.Lifecycle.Teardown.EksDrainInterpreter (parseKubernetesNamespaceUid)
import Prodbox.Lifecycle.Teardown.Model (ObservationFailure (..))
import TestSupport

namespaceUidDecoderSuite :: SuiteBuilder ()
namespaceUidDecoderSuite = describe "namespace UID projection compatibility" $ do
  forM_ (zip [0 :: Int ..] corpus) $ \(ordinal, body) ->
    it ("matches the pinned value decoder for document " <> show ordinal) $
      parseKubernetesNamespaceUid body `shouldBe` reference body
  forM_
    [ ("dense numbers", Fixture.DenseNumbers)
    , ("singleton arrays", Fixture.SingletonArrays)
    , ("empty objects", Fixture.EmptyObjects)
    , ("deep array", Fixture.DeepArray)
    ]
    $ \(label, shape) ->
      it ("keeps the full two-MiB domain with ignored " <> label) $
        parseKubernetesNamespaceUid (Encoding.decodeUtf8 (Fixture.input shape))
          `shouldBe` Right "fixture-uid"

-- Frozen semantic oracle from the superseded consumer. It deliberately uses
-- the complete Value decoder, including its first-duplicate-key behavior.
reference :: Text -> Either ObservationFailure Text
reference raw =
  case Aeson.eitherDecodeStrict (Encoding.encodeUtf8 raw) of
    Left detail -> Left (ObservationFailure ("Kubernetes namespace document did not parse: " <> Text.pack detail))
    Right value -> case value of
      Aeson.Object document -> case KeyMap.lookup "metadata" document of
        Just (Aeson.Object metadata) -> case KeyMap.lookup "uid" metadata of
          Just (Aeson.String uid) | not (Text.null uid) -> Right uid
          _ -> Left (ObservationFailure "Kubernetes namespace document carried no UID")
        _ -> Left (ObservationFailure "Kubernetes namespace document carried no metadata")
      _ -> Left (ObservationFailure "Kubernetes namespace document was not an object")

corpus :: [Text]
corpus = Set.toAscList (Set.fromList (valid <> truncations <> malformed <> trailing))
 where
  atoms =
    [ "null"
    , "true"
    , "false"
    , "0"
    , "-1"
    , "1.25"
    , "1e1024"
    , "\"\""
    , "\"first\""
    , "\"λ🌐\""
    , "[]"
    , "{}"
    , "[null,1]"
    , "{\"uid\":\"fixture\"}"
    ]
  metadata = ["{\"metadata\":" <> value <> "}" | value <- atoms]
  uids = ["{\"metadata\":{\"uid\":" <> value <> "}}" | value <- atoms]
  duplicateMetadata =
    [ "{\"metadata\":" <> first <> ",\"metadata\":" <> second <> "}"
    | first <- atoms
    , second <- atoms
    ]
  duplicateUid =
    [ "{\"metadata\":{\"uid\":" <> first <> ",\"uid\":" <> second <> "}}"
    | first <- atoms
    , second <- atoms
    ]
  ignored =
    concat
      [ [ "{\"padding\":" <> value <> ",\"metadata\":{\"uid\":\"fixture\"}}"
        , "{\"metadata\":{\"padding\":" <> value <> ",\"uid\":\"fixture\"}}"
        , "{\"metadata\":{\"uid\":\"fixture\",\"padding\":" <> value <> "}}"
        , "{\"metadata\":{\"uid\":\"fixture\"},\"padding\":" <> value <> "}"
        ]
      | value <- atoms
      ]
  escaped =
    [ "{\"\\u006detadata\":{\"\\u0075id\":\"escaped\"}}"
    , "{\"Metadata\":{\"uid\":\"foreign\"}}"
    , "{\"metadata\":{\"UID\":\"foreign\"}}"
    , "{\"padding\":{\"metadata\":{\"uid\":\"foreign\"}}}"
    , "{\"metadata\":{\"uid\":\" \\t\\n\"}}"
    , "{\"metadata\":{\"uid\":\"\\ud83c\\udf10\"}}"
    , "{\"metadata\":{\"uid\":\"\\ud800\"}}"
    , "{\"metadata\":{\"uid\":\"\\u0000\"}}"
    ]
  nested =
    [ "{\"padding\":"
        <> Text.replicate depth "["
        <> "0"
        <> Text.replicate depth "]"
        <> ",\"metadata\":{\"uid\":\"nested\"}}"
    | depth <- [1, 2, 16, 128, 1024]
    ]
  valid = atoms <> metadata <> uids <> duplicateMetadata <> duplicateUid <> ignored <> escaped <> nested
  truncations = [Text.take count body | body <- take 20 (uids <> ignored), count <- [0 .. Text.length body - 1]]
  malformed =
    [ ""
    , " "
    , "["
    , "{"
    , "{\"metadata\":}"
    , "{\"metadata\":{\"uid\":\"found\"},\"ignored\":[1,]}"
    , "{\"metadata\":{\"uid\":\"found\"},\"ignored\":{\"x\":}}"
    , "{\"metadata\":{\"uid\":\"found\"},\"ignored\":\"\\q\"}"
    , "{\"metadata\":{\"uid\":\"found\"},\"ignored\":\"\\ud800\\u0020\"}"
    , "{\"metadata\":{\"uid\":\"found\"},\"ignored\":01}"
    ]
  trailing = [body <> suffix | body <- take 12 uids, suffix <- ["x", "]", "false", " {}", "\NUL", "\xfeff"]]
