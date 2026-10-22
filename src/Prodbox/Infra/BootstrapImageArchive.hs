{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Deterministic Docker archives over already acquired public build inputs.
-- Input acquisition/provenance and Docker/containerd observations belong to the
-- interpreter; these bytes cannot authorize a lifecycle operation.
module Prodbox.Infra.BootstrapImageArchive
  ( BootstrapImageComponent (..)
  , BootstrapImageArchitecture (..)
  , BootstrapImageInputs (..)
  , BootstrapImageInputField (..)
  , BootstrapImageArchiveError (..)
  , BootstrapImageArchive
  , bootstrapImageArchiveBytes
  , bootstrapImageArchiveIdentity
  , bootstrapImageArchiveReference
  , bootstrapImageArchiveDigest
  , bootstrapImageComponentName
  , bootstrapImageComponentRelease
  , bootstrapImageComponentCommit
  , bootstrapImageRepository
  , bootstrapImageTag
  , assembleBootstrapImageArchive
  )
where

import Control.Monad (unless, when)
import Crypto.Hash (Digest, SHA256, hashlazy)
import Data.Aeson (Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as Char8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAscii, isControl)
import Data.Foldable (toList)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric (showOct)

-- These are target image architectures, independently checked against the
-- acquired compiler/base images by the interpreter.
data BootstrapImageComponent = BootstrapMinioServer | BootstrapMinioClient
  deriving (Eq, Show)

data BootstrapImageArchitecture = BootstrapImageAmd64 | BootstrapImageArm64
  deriving (Eq, Show)

data BootstrapImageInputs = BootstrapImageInputs
  { bootstrapInputBaseLayer :: LazyByteString.ByteString
  , bootstrapInputBaseHistory :: Value
  , bootstrapInputBinary :: LazyByteString.ByteString
  , bootstrapInputLicense :: ByteString.ByteString
  , bootstrapInputCertificateBundle :: ByteString.ByteString
  , bootstrapInputSourceManifest :: Value
  }

data BootstrapImageInputField
  = BootstrapBaseLayer
  | BootstrapBaseHistory
  | BootstrapBinary
  | BootstrapLicense
  | BootstrapCertificateBundle
  | BootstrapSourceManifest
  deriving (Eq, Show)

data BootstrapImageArchiveError
  = BootstrapImageInputTooLarge BootstrapImageInputField Integer Integer
  | BootstrapImageInputEmpty BootstrapImageInputField
  | BootstrapImageMetadataInvalid BootstrapImageInputField
  | BootstrapTarPathInvalid Text
  | BootstrapTarNumberTooLarge Int Integer
  deriving (Eq, Show)

data BootstrapImageArchive = BootstrapImageArchive
  { bootstrapImageArchiveBytes :: LazyByteString.ByteString
  , bootstrapImageArchiveIdentity :: Text
  , bootstrapImageArchiveReference :: Text
  , bootstrapImageArchiveDigest :: Text
  }

bootstrapImageComponentName :: BootstrapImageComponent -> Text
bootstrapImageComponentName component = case component of
  BootstrapMinioServer -> "minio"
  BootstrapMinioClient -> "mc"

bootstrapImageComponentRelease :: BootstrapImageComponent -> Text
bootstrapImageComponentRelease component = case component of
  BootstrapMinioServer -> "RELEASE.2024-12-18T13-15-44Z"
  BootstrapMinioClient -> "RELEASE.2024-11-21T17-21-54Z"

bootstrapImageComponentCommit :: BootstrapImageComponent -> Text
bootstrapImageComponentCommit component = case component of
  BootstrapMinioServer -> "16f8cf1c52f0a77eeb8f7565aaf7f7df12454583"
  BootstrapMinioClient -> "1681e4497c09d7438a34e846f76dbde972ab7daf"

bootstrapImageRepository :: BootstrapImageComponent -> Text
bootstrapImageRepository component = "prodbox/" <> bootstrapImageComponentName component <> "-bootstrap"

bootstrapImageTag :: BootstrapImageComponent -> Text
bootstrapImageTag component = bootstrapImageComponentRelease component <> "-source-v1"

assembleBootstrapImageArchive
  :: BootstrapImageComponent
  -> BootstrapImageArchitecture
  -> BootstrapImageInputs
  -> Either BootstrapImageArchiveError BootstrapImageArchive
assembleBootstrapImageArchive component architecture inputs = do
  checkObject BootstrapBaseHistory (bootstrapInputBaseHistory inputs)
  checkObject BootstrapSourceManifest (bootstrapInputSourceManifest inputs)
  checkInput BootstrapBaseLayer (16 * mib) base
  checkInput BootstrapBinary (128 * mib) (bootstrapInputBinary inputs)
  checkInput BootstrapLicense (128 * 1024) (strict (bootstrapInputLicense inputs))
  checkInput BootstrapCertificateBundle (512 * 1024) (strict (bootstrapInputCertificateBundle inputs))
  checkInput
    BootstrapBaseHistory
    (64 * 1024)
    (strict (canonicalJson (bootstrapInputBaseHistory inputs)))
  checkInput BootstrapSourceManifest (64 * 1024) (strict sourceManifest)
  overlay <- tarArchive (serviceDirectories component) payloadFiles
  let baseDigest = sha256 base
      overlayDigest = sha256 overlay
      config = canonicalJson (imageConfig component architecture inputs baseDigest overlayDigest)
      configDigest = sha256 (strict config)
      baseName = baseDigest <> "/layer.tar"
      overlayName = overlayDigest <> "/layer.tar"
      configName = configDigest <> ".json"
      reference = "docker.io/" <> bootstrapImageRepository component <> ":" <> bootstrapImageTag component
      manifest =
        canonicalJson
          ( Aeson.toJSON
              [object ["Config" .= configName, "RepoTags" .= [reference], "Layers" .= [baseName, overlayName]]]
          )
  bytes <-
    tarArchive
      Map.empty
      ( Map.fromList
          [ (baseName, regular base)
          , (overlayName, regular overlay)
          , (configName, regular (strict config))
          , ("manifest.json", regular (strict manifest))
          ]
      )
  Right
    BootstrapImageArchive
      { bootstrapImageArchiveBytes = bytes
      , bootstrapImageArchiveIdentity = "sha256:" <> configDigest
      , bootstrapImageArchiveReference = reference
      , bootstrapImageArchiveDigest = sha256 bytes
      }
 where
  mib = 1024 * 1024
  base = bootstrapInputBaseLayer inputs
  sourceManifest = canonicalJson (bootstrapInputSourceManifest inputs)
  name = bootstrapImageComponentName component
  payloadFiles =
    Map.fromList
      ( [ ("usr/bin/" <> name, TarFile 0o755 (bootstrapInputBinary inputs))
        , ("etc/ssl/certs/ca-certificates.crt", regular (strict (bootstrapInputCertificateBundle inputs)))
        , ("licenses/" <> name <> ".LICENSE", regular (strict (bootstrapInputLicense inputs)))
        , ("usr/share/prodbox-bootstrap/source-inputs.json", regular (strict sourceManifest))
        ]
          <> serviceAccountFiles component
      )

imageConfig
  :: BootstrapImageComponent
  -> BootstrapImageArchitecture
  -> BootstrapImageInputs
  -> Text
  -> Text
  -> Value
imageConfig component architecture inputs baseDigest overlayDigest =
  object
    [ "created" .= imageCreated
    , "architecture" .= architectureName architecture
    , "os" .= ("linux" :: Text)
    , "config"
        .= object
          [ "Env"
              .= [ "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
                 , "HOME=" <> serviceHome component
                 ]
          , "Entrypoint" .= ["/usr/bin/" <> bootstrapImageComponentName component]
          , "Cmd" .= ([] :: [Text])
          , "User" .= serviceUser component
          , "WorkingDir" .= serviceHome component
          , "Labels"
              .= object
                [ "org.opencontainers.image.vendor" .= ("prodbox" :: Text)
                , "org.opencontainers.image.version" .= bootstrapImageTag component
                , "org.opencontainers.image.revision" .= bootstrapImageComponentCommit component
                , "org.opencontainers.image.licenses" .= ("AGPL-3.0-or-later AND GPL-2.0-only" :: Text)
                ]
          ]
    , "rootfs"
        .= object
          ["type" .= ("layers" :: Text), "diff_ids" .= ["sha256:" <> baseDigest, "sha256:" <> overlayDigest]]
    , "history"
        .= [ bootstrapInputBaseHistory inputs
           , object ["created" .= imageCreated, "created_by" .= ("prodbox source bootstrap archive v1" :: Text)]
           ]
    ]

architectureName :: BootstrapImageArchitecture -> Text
architectureName architecture = case architecture of
  BootstrapImageAmd64 -> "amd64"
  BootstrapImageArm64 -> "arm64"

serviceUser :: BootstrapImageComponent -> Text
serviceUser component = case component of
  BootstrapMinioServer -> "1000:1000"
  BootstrapMinioClient -> "0:0"

serviceHome :: BootstrapImageComponent -> Text
serviceHome component = case component of
  BootstrapMinioServer -> "/home/minio"
  BootstrapMinioClient -> "/root"

serviceDirectories :: BootstrapImageComponent -> Map.Map Text (Integer, Integer)
serviceDirectories component = case component of
  BootstrapMinioServer -> Map.fromList [("home", (0, 0)), ("home/minio", (1000, 1000))]
  BootstrapMinioClient -> Map.empty

serviceAccountFiles :: BootstrapImageComponent -> [(Text, TarFile)]
serviceAccountFiles component = case component of
  BootstrapMinioServer ->
    [
      ( "etc/passwd"
      , regular "root:x:0:0:root:/root:/bin/sh\nminio:x:1000:1000:MinIO:/home/minio:/bin/sh\n"
      )
    , ("etc/group", regular "root:x:0:\nminio:x:1000:\n")
    ]
  BootstrapMinioClient -> []

imageCreated :: Text
imageCreated = "2024-12-18T13:15:44Z"

imageEpoch :: Integer
imageEpoch = 1734527744

strict :: ByteString.ByteString -> LazyByteString.ByteString
strict = LazyByteString.fromStrict

sha256 :: LazyByteString.ByteString -> Text
sha256 bytes = TextEncoding.decodeUtf8 (convertToBase Base16 (hashlazy bytes :: Digest SHA256))

checkInput
  :: BootstrapImageInputField
  -> Integer
  -> LazyByteString.ByteString
  -> Either BootstrapImageArchiveError ()
checkInput field maximumBytes bytes = do
  let size = toInteger (LazyByteString.length (LazyByteString.take (fromInteger maximumBytes + 1) bytes))
  when (size == 0) (Left (BootstrapImageInputEmpty field))
  when (size > maximumBytes) (Left (BootstrapImageInputTooLarge field size maximumBytes))

checkObject :: BootstrapImageInputField -> Value -> Either BootstrapImageArchiveError ()
checkObject field value = case value of
  Object _ -> Right ()
  Array _ -> invalid
  String _ -> invalid
  Number _ -> invalid
  Bool _ -> invalid
  Null -> invalid
 where
  invalid = Left (BootstrapImageMetadataInvalid field)

canonicalJson :: Value -> ByteString.ByteString
canonicalJson value = LazyByteString.toStrict (render value <> "\n")
 where
  render item = case item of
    Object fields ->
      "{"
        <> LazyByteString.intercalate
          ","
          [ Aeson.encode (Key.toText key) <> ":" <> render body
          | (key, body) <- sortOn fst (KeyMap.toList fields)
          ]
        <> "}"
    Array values -> "[" <> LazyByteString.intercalate "," (map render (toList values)) <> "]"
    String _ -> Aeson.encode item
    Number _ -> Aeson.encode item
    Bool _ -> Aeson.encode item
    Null -> "null"

data TarFile = TarFile Integer LazyByteString.ByteString

regular :: LazyByteString.ByteString -> TarFile
regular = TarFile 0o644

tarArchive
  :: Map.Map Text (Integer, Integer)
  -> Map.Map Text TarFile
  -> Either BootstrapImageArchiveError LazyByteString.ByteString
tarArchive ownedDirectories files = do
  directoryHeaders <- mapM directoryHeader (Map.toAscList directories)
  filePayloads <- mapM filePayload (Map.toAscList files)
  let body = foldMap strict directoryHeaders <> mconcat filePayloads <> LazyByteString.replicate 1024 0
      padding = (10240 - LazyByteString.length body `mod` 10240) `mod` 10240
  Right (body <> LazyByteString.replicate padding 0)
 where
  directories =
    Map.union
      ownedDirectories
      (Map.fromSet (const (0, 0)) (Set.insert "." (Set.fromList (concatMap parents (Map.keys files)))))
  parents name = case Text.breakOnEnd "/" name of
    ("", _) -> []
    (prefix, _) -> let parent = Text.dropEnd 1 prefix in parent : parents parent
  directoryHeader (name, (uid, gid)) = tarHeader (name <> "/") 0o755 uid gid 0 53
  filePayload (name, TarFile mode bytes) = do
    header <- tarHeader name mode 0 0 (toInteger (LazyByteString.length bytes)) 48
    let padding = (512 - LazyByteString.length bytes `mod` 512) `mod` 512
    Right (strict header <> bytes <> LazyByteString.replicate padding 0)

tarHeader
  :: Text
  -> Integer
  -> Integer
  -> Integer
  -> Integer
  -> Word
  -> Either BootstrapImageArchiveError ByteString.ByteString
tarHeader name mode uid gid size kind = do
  let encodedName = TextEncoding.encodeUtf8 name
  unless
    ( not (Text.null name)
        && ByteString.length encodedName <= 100
        && Text.all (\c -> isAscii c && not (isControl c) && c /= '\\') name
        && not (Text.isPrefixOf "/" name)
        && ".." `notElem` Text.splitOn "/" name
    )
    (Left (BootstrapTarPathInvalid name))
  modeField <- octal 8 mode
  uidField <- octal 8 uid
  gidField <- octal 8 gid
  sizeField <- octal 12 size
  timeField <- octal 12 imageEpoch
  let header =
        encodedName
          <> zeros (100 - ByteString.length encodedName)
          <> modeField
          <> uidField
          <> gidField
          <> sizeField
          <> timeField
          <> ByteString.replicate 8 32
          <> ByteString.singleton (fromIntegral kind)
          <> zeros 100
          <> "ustar\0"
          <> "00"
          <> zeros 32
          <> zeros 32
          <> zeros 8
          <> zeros 8
          <> zeros 155
          <> zeros 12
      checksum = ByteString.foldl' (\total byte -> total + fromIntegral byte) (0 :: Integer) header
  sumField <- octal 7 checksum
  Right (ByteString.take 148 header <> sumField <> " " <> ByteString.drop 156 header)
 where
  zeros count = ByteString.replicate count 0

octal :: Int -> Integer -> Either BootstrapImageArchiveError ByteString.ByteString
octal width value
  | value < 0 || value >= 8 ^ (width - 1) = Left (BootstrapTarNumberTooLarge width value)
  | otherwise =
      let digits = Char8.pack (showOct value "")
       in Right (ByteString.replicate (width - 1 - ByteString.length digits) 48 <> digits <> "\0")
