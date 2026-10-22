{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module BootstrapSourceFixture (writeBootstrapSourceFixture) where

import Crypto.Hash (Digest, SHA256, hashlazy)
import Data.Aeson (encode, object, (.=))
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Infra.BootstrapImageArchive
import Prodbox.Infra.BootstrapImageSource
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.Posix.Files (setFileMode)

-- Public synthetic build bytes exercise cache verification and the subprocess
-- boundary. This metadata is never an Authority handle or secret receipt.
writeBootstrapSourceFixture :: FilePath -> IO [(Text, Text, FilePath)]
writeBootstrapSourceFixture root = mapM writeOne [BootstrapMinioServer, BootstrapMinioClient]
 where
  writeOne component = do
    let recipe = bootstrapSourceRecipe component BootstrapImageAmd64
        location =
          root </> ".build" </> "bootstrap-images-v1" </> Text.unpack (bootstrapSourceRecipeIdentity recipe)
        binary = "synthetic public bootstrap executable"
        base = "synthetic base filesystem"
        ca = "synthetic public certificate bundle"
        license = "synthetic licence"
        history = object ["created_by" .= ("synthetic pinned base" :: Text)]
        historyBytes = encode history
        manifest = bootstrapSourceInputManifest recipe (digest binary) (digest base) (digest ca)
        inputs =
          BootstrapImageInputs
            base
            history
            binary
            (LazyByteString.toStrict license)
            (LazyByteString.toStrict ca)
            manifest
        receipt =
          encode $
            object
              [ "schema" .= (1 :: Int)
              , "recipe_sha256" .= bootstrapSourceRecipeIdentity recipe
              , "binary_sha256" .= digest binary
              , "base_sha256" .= digest base
              , "ca_sha256" .= digest ca
              , "license_sha256" .= digest license
              , "history_sha256" .= digest historyBytes
              ]
    createDirectoryIfMissing True location
    setFileMode location 0o700
    mapM_
      ( \(name, bytes) -> LazyByteString.writeFile (location </> name) bytes >> setFileMode (location </> name) 0o600
      )
      [ ("binary", binary)
      , ("base.tar", base)
      , ("ca.pem", ca)
      , ("LICENSE", license)
      , ("history.json", historyBytes)
      , ("inputs.json", receipt)
      ]
    case assembleBootstrapImageArchive component BootstrapImageAmd64 inputs of
      Left cause -> ioError (userError (show cause))
      Right archive -> do
        let reference = bootstrapImageArchiveReference archive
            identity = bootstrapImageArchiveIdentity archive
        ByteString.writeFile (location </> "fixture-image-id") (TextEncoding.encodeUtf8 identity)
        pure (reference, identity, location)

digest :: LazyByteString.ByteString -> Text
digest bytes = TextEncoding.decodeUtf8 (convertToBase Base16 (hashlazy bytes :: Digest SHA256))
