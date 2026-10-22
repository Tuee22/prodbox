{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Public bootstrap build inputs and their fixed compiler invocation.
-- The interpreter owns acquisition, private cache read-back and bounded Docker
-- containers; a recipe is data and grants no provider or lifecycle authority.
module Prodbox.Infra.BootstrapImageSource
  ( BootstrapSourceDownload (..)
  , BootstrapSourceRecipe
  , bootstrapSourceRecipe
  , bootstrapSourceRecipeIdentity
  , bootstrapSourceRecipeComponent
  , bootstrapSourceRecipeArchitecture
  , bootstrapSourceRecipeDownloads
  , bootstrapSourceRecipeSdkDirectory
  , bootstrapSourceCompileArguments
  , bootstrapSourceCompileEnvironment
  , bootstrapSourceCompilerMemoryBytes
  , bootstrapSourceCompilerCpuPeriod
  , bootstrapSourceCompilerCpuQuota
  , bootstrapSourceCompilerPidMaximum
  , bootstrapSourceCompilerTimeoutSeconds
  , bootstrapSourceRuntimeBase
  , bootstrapSourceCertificateImage
  , bootstrapSourceInputManifest
  )
where

import Crypto.Hash (Digest, SHA256, hashlazy)
import Data.Aeson (Value, encode, object, (.=))
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Infra.BootstrapImageArchive
  ( BootstrapImageArchitecture (..)
  , BootstrapImageComponent (..)
  , bootstrapImageComponentCommit
  , bootstrapImageComponentName
  , bootstrapImageComponentRelease
  )

-- | Immutable public input. A local file is accepted only after its exact
-- digest and finite length have been observed; the URL is never caller input.
data BootstrapSourceDownload = BootstrapSourceDownload
  { bootstrapDownloadName :: Text
  , bootstrapDownloadUrl :: Text
  , bootstrapDownloadSha256 :: Text
  , bootstrapDownloadMaximumBytes :: Integer
  }
  deriving (Eq, Show)

data BootstrapSourceRecipe = BootstrapSourceRecipe
  { bootstrapSourceRecipeComponent :: BootstrapImageComponent
  , bootstrapSourceRecipeArchitecture :: BootstrapImageArchitecture
  , bootstrapSourceRecipeDownloads :: [BootstrapSourceDownload]
  }
  deriving (Eq, Show)

bootstrapSourceRecipe
  :: BootstrapImageComponent -> BootstrapImageArchitecture -> BootstrapSourceRecipe
bootstrapSourceRecipe component architecture =
  BootstrapSourceRecipe component architecture [sourceDownload component, sdkDownload architecture]

bootstrapSourceRecipeIdentity :: BootstrapSourceRecipe -> Text
bootstrapSourceRecipeIdentity recipe =
  digest
    ( encode
        ( object
            [ "schema" .= (1 :: Int)
            , "component" .= bootstrapImageComponentName (bootstrapSourceRecipeComponent recipe)
            , "architecture" .= architectureName (bootstrapSourceRecipeArchitecture recipe)
            , "source_commit" .= bootstrapImageComponentCommit (bootstrapSourceRecipeComponent recipe)
            , "downloads" .= map downloadMetadata (bootstrapSourceRecipeDownloads recipe)
            , "arguments" .= bootstrapSourceCompileArguments recipe
            , "environment" .= bootstrapSourceCompileEnvironment recipe
            , "runtime_base" .= bootstrapSourceRuntimeBase
            , "certificate_image" .= bootstrapSourceCertificateImage
            , "memory_bytes" .= bootstrapSourceCompilerMemoryBytes
            , "cpu_period" .= bootstrapSourceCompilerCpuPeriod
            , "cpu_quota" .= bootstrapSourceCompilerCpuQuota
            , "pid_maximum" .= bootstrapSourceCompilerPidMaximum
            , "timeout_seconds" .= bootstrapSourceCompilerTimeoutSeconds
            ]
        )
    )

sourceDownload :: BootstrapImageComponent -> BootstrapSourceDownload
sourceDownload component =
  BootstrapSourceDownload
    { bootstrapDownloadName =
        bootstrapImageComponentName component
          <> "-"
          <> bootstrapImageComponentRelease component
          <> ".tar.gz"
    , bootstrapDownloadUrl =
        "https://codeload.github.com/minio/"
          <> bootstrapImageComponentName component
          <> "/tar.gz/refs/tags/"
          <> bootstrapImageComponentRelease component
    , bootstrapDownloadSha256 = sourceArchiveDigest component
    , bootstrapDownloadMaximumBytes = 32 * 1024 * 1024
    }

sourceArchiveDigest :: BootstrapImageComponent -> Text
sourceArchiveDigest component = case component of
  BootstrapMinioServer -> "d7d044f11a343389b1952c48a3e15feef6efa63c67b9f025c212a04016f05037"
  BootstrapMinioClient -> "dbfb5eff8a9d1a8b3b02c30596377d44478040cd19563314656f4cd009de8922"

sdkDownload :: BootstrapImageArchitecture -> BootstrapSourceDownload
sdkDownload architecture =
  BootstrapSourceDownload
    { bootstrapDownloadName = "go1.23.4.linux-" <> architectureName architecture <> ".tar.gz"
    , bootstrapDownloadUrl =
        "https://go.dev/dl/go1.23.4.linux-" <> architectureName architecture <> ".tar.gz"
    , bootstrapDownloadSha256 = sdkDigest architecture
    , bootstrapDownloadMaximumBytes = 96 * 1024 * 1024
    }

sdkDigest :: BootstrapImageArchitecture -> Text
sdkDigest architecture = case architecture of
  BootstrapImageAmd64 -> "6924efde5de86fe277676e929dc9917d466efa02fb934197bc2eba35d5680971"
  BootstrapImageArm64 -> "16e5017863a7f6071363782b1b8042eb12c6ca4f4cd71528b2123f0a1275b13e"

architectureName :: BootstrapImageArchitecture -> Text
architectureName architecture = case architecture of
  BootstrapImageAmd64 -> "amd64"
  BootstrapImageArm64 -> "arm64"

bootstrapSourceRecipeSdkDirectory :: Text
bootstrapSourceRecipeSdkDirectory = "go1.23.4"

-- Paths are container-local and fixed. Host bind paths are separately resolved
-- beneath the owned build cache before the interpreter constructs Docker args.
bootstrapSourceCompileArguments :: BootstrapSourceRecipe -> [Text]
bootstrapSourceCompileArguments recipe =
  [ "/bin/timeout"
  , "-s"
  , "TERM"
  , "-k"
  , "5"
  , Text.pack (show bootstrapSourceCompilerTimeoutSeconds)
  , "/toolchain/bin/go"
  , "build"
  , "-p"
  , "2"
  , "-mod=readonly"
  , "-buildvcs=false"
  , "-trimpath"
  , "-tags"
  , "kqueue"
  , "-ldflags"
  , Text.unwords linkerArguments
  , "-o"
  , "/out/" <> name
  , "."
  ]
 where
  component = bootstrapSourceRecipeComponent recipe
  name = bootstrapImageComponentName component
  package = "github.com/minio/" <> name <> "/cmd."
  linkerArguments =
    ["-s", "-w", "-buildid="]
      <> concatMap
        linkerVariable
        ( [ ("Version", versionDate component)
          , ("ReleaseTag", bootstrapImageComponentRelease component)
          , ("CopyrightYear", "2024")
          , ("CommitID", bootstrapImageComponentCommit component)
          , ("ShortCommitID", Text.take 12 (bootstrapImageComponentCommit component))
          ]
            <> compilerMetadata component
        )
  linkerVariable (key, value) = ["-X", package <> key <> "=" <> value]

versionDate :: BootstrapImageComponent -> Text
versionDate component = case component of
  BootstrapMinioServer -> "2024-12-18T13:15:44Z"
  BootstrapMinioClient -> "2024-11-21T17:21:54Z"

compilerMetadata :: BootstrapImageComponent -> [(Text, Text)]
compilerMetadata component = case component of
  BootstrapMinioServer -> [("GOPATH", "/go"), ("GOROOT", "/go-toolchain")]
  BootstrapMinioClient -> []

bootstrapSourceCompileEnvironment :: BootstrapSourceRecipe -> [(Text, Text)]
bootstrapSourceCompileEnvironment recipe =
  [ ("PATH", "/toolchain/bin:/usr/bin:/bin")
  , ("HOME", "/work")
  , ("GOENV", "off")
  , ("GOTOOLCHAIN", "local")
  , ("GOROOT", "/toolchain")
  , ("GOOS", "linux")
  , ("GOARCH", architectureName (bootstrapSourceRecipeArchitecture recipe))
  , ("GOAMD64", "v1")
  , ("CGO_ENABLED", "0")
  , ("GOPATH", "/go")
  , ("GOMODCACHE", "/modules")
  , ("GOCACHE", "/go-cache")
  , ("GOTMPDIR", "/work")
  , ("GOMAXPROCS", "2")
  , ("GOMEMLIMIT", "1GiB")
  , ("GOPROXY", "https://proxy.golang.org")
  , ("GOSUMDB", "sum.golang.org")
  , ("GOVCS", "*:off")
  ]

bootstrapSourceCompilerMemoryBytes :: Integer
bootstrapSourceCompilerMemoryBytes = 2 * 1024 * 1024 * 1024

bootstrapSourceCompilerCpuPeriod :: Integer
bootstrapSourceCompilerCpuPeriod = 100000

bootstrapSourceCompilerCpuQuota :: Integer
bootstrapSourceCompilerCpuQuota = 200000

bootstrapSourceCompilerPidMaximum :: Integer
bootstrapSourceCompilerPidMaximum = 256

bootstrapSourceCompilerTimeoutSeconds :: Integer
bootstrapSourceCompilerTimeoutSeconds = 900

bootstrapSourceRuntimeBase :: Text
bootstrapSourceRuntimeBase =
  "docker.io/library/busybox:1.36.1-musl@sha256:3c6ae8008e2c2eedd141725c30b20d9c36b026eb796688f88205845ef17aa213"

bootstrapSourceCertificateImage :: Text
bootstrapSourceCertificateImage =
  "docker.io/library/golang:1.23.4-alpine3.20@sha256:6a84ccdb73e005d0ee7bfff6066f230612ca9dff3e88e31bfc752523c3a271f8"

bootstrapSourceInputManifest :: BootstrapSourceRecipe -> Text -> Text -> Text -> Value
bootstrapSourceInputManifest recipe binaryDigest baseLayerDigest certificateDigest =
  object
    [ "schema" .= (1 :: Int)
    , "recipe_sha256" .= bootstrapSourceRecipeIdentity recipe
    , "component" .= bootstrapImageComponentName component
    , "release" .= bootstrapImageComponentRelease component
    , "commit" .= bootstrapImageComponentCommit component
    , "architecture" .= architectureName (bootstrapSourceRecipeArchitecture recipe)
    , "inputs" .= map downloadMetadata (bootstrapSourceRecipeDownloads recipe)
    , "binary_sha256" .= binaryDigest
    , "base_image" .= bootstrapSourceRuntimeBase
    , "base_filesystem_sha256" .= baseLayerDigest
    , "certificate_image" .= bootstrapSourceCertificateImage
    , "certificate_sha256" .= certificateDigest
    ]
 where
  component = bootstrapSourceRecipeComponent recipe

downloadMetadata :: BootstrapSourceDownload -> Value
downloadMetadata input =
  object
    [ "name" .= bootstrapDownloadName input
    , "url" .= bootstrapDownloadUrl input
    , "sha256" .= bootstrapDownloadSha256 input
    , "maximum_bytes" .= bootstrapDownloadMaximumBytes input
    ]

digest :: LazyByteString.ByteString -> Text
digest bytes = TextEncoding.decodeUtf8 (convertToBase Base16 (hashlazy bytes :: Digest SHA256))
