{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module BootstrapImageSource (bootstrapImageSourceSuite) where

import Data.List (nub)
import Data.Text qualified as Text
import Prodbox.Infra.BootstrapImageArchive
import Prodbox.Infra.BootstrapImageSource
import TestSupport

bootstrapImageSourceSuite :: SuiteBuilder ()
bootstrapImageSourceSuite = describe "Sprint 6.5 pinned bootstrap source recipes" $ do
  it "binds both components and target architectures to distinct immutable source and SDK recipes" $ do
    let recipes =
          [ bootstrapSourceRecipe component architecture
          | component <- [BootstrapMinioServer, BootstrapMinioClient]
          , architecture <- [BootstrapImageAmd64, BootstrapImageArm64]
          ]
    length (nub (map bootstrapSourceRecipeIdentity recipes)) `shouldBe` 4
    mapM_
      ( \recipe -> do
          length (bootstrapSourceRecipeDownloads recipe) `shouldBe` 2
          mapM_
            ( \input -> do
                Text.length (bootstrapDownloadSha256 input) `shouldBe` 64
                Text.isPrefixOf "https://" (bootstrapDownloadUrl input) `shouldBe` True
                bootstrapDownloadMaximumBytes input `shouldSatisfy` (> 0)
            )
            (bootstrapSourceRecipeDownloads recipe)
      )
      recipes

  it
    "BOOTSTRAP-SOURCE-COMPILER-TMPFS-EXHAUSTION-2026-10-20 uses the existing work mount for Go scratch"
    $ do
      -- Recording: acquisition-native-cold-2.log; the fixed 64 MiB /tmp failed
      -- with ENOSPC. The same CPU/memory/mount budget passes with GOTMPDIR=/work.
      let recipe = bootstrapSourceRecipe BootstrapMinioServer BootstrapImageAmd64
      lookup "GOTMPDIR" (bootstrapSourceCompileEnvironment recipe) `shouldBe` Just "/work"
      take 8 (bootstrapSourceCompileArguments recipe)
        `shouldBe` ["/bin/timeout", "-s", "TERM", "-k", "5", "900", "/toolchain/bin/go", "build"]

  it "uses an explicit public module-verification environment with finite compiler containment" $ do
    let environment =
          bootstrapSourceCompileEnvironment (bootstrapSourceRecipe BootstrapMinioClient BootstrapImageAmd64)
    mapM_
      (\(key, value) -> lookup key environment `shouldBe` Just value)
      [ ("GOENV", "off")
      , ("GOTOOLCHAIN", "local")
      , ("CGO_ENABLED", "0")
      , ("GOPROXY", "https://proxy.golang.org")
      , ("GOSUMDB", "sum.golang.org")
      , ("GOVCS", "*:off")
      ]
    all (\(key, _) -> not (any (`Text.isPrefixOf` key) ["AWS_", "PRODBOX_", "MINIO_"])) environment
      `shouldBe` True
    bootstrapSourceCompilerMemoryBytes `shouldBe` (2 * 1024 * 1024 * 1024)
    bootstrapSourceCompilerCpuQuota `shouldBe` (2 * bootstrapSourceCompilerCpuPeriod)
    bootstrapSourceCompilerPidMaximum `shouldBe` 256
