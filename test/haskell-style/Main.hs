module Main (main) where

import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.List (isPrefixOf)
import Prodbox.BuildSupport (addBuildSupportEnvironment)
import Prodbox.CLI.Docs
  ( renderBashCompletion
  , renderGroupManpage
  , renderTopLevelManpage
  )
import Prodbox.CLI.Spec (CommandSpec (..), commandRegistry)
import Prodbox.CheckCode
  ( GeneratedSectionRule
  , TrackedGeneratedPath
  , generatedSectionRules
  , haskellStyleViolations
  , renderGeneratedSection
  , renderTrackedGeneratedPath
  , rendererDeterminismViolations
  , rendererSourceViolations
  , trackingGeneratedPaths
  )
import Prodbox.Lint (ensureSandboxedStyleTools, formatterToolGhcVersion, styleToolsBinDir)
import Prodbox.PublicEdge (renderHelmRouteInventory)
import System.Directory (doesFileExist, getCurrentDirectory)
import System.FilePath ((</>))
import TestSupport

main :: IO ()
main = mainWithSuite "prodbox-haskell-style" $ do
  describe "repo style invariants" $ do
    it "has no repository-specific Haskell style violations" $ do
      repoRoot <- getCurrentDirectory
      violations <- haskellStyleViolations repoRoot
      violations `shouldBe` []

    it "pins the doctrine-required fourmolu settings" $ do
      repoRoot <- getCurrentDirectory
      fourmoluContents <- readFile (repoRoot </> "fourmolu.yaml")
      mapM_
        (fourmoluContents `shouldContain`)
        [ "indentation: 2"
        , "column-limit: 100"
        , "function-arrows: leading"
        , "comma-style: leading"
        , "import-export-style: leading"
        , "indent-wheres: false"
        , "record-brace-space: true"
        , "newlines-between-decls: 1"
        , "haddock-style: single-line"
        , "let-style: auto"
        , "in-style: right-align"
        , "unicode: never"
        , "respectful: true"
        ]

    it "bootstraps sandboxed Haskell style tools under .build/prodbox-style-tools/bin" $ do
      repoRoot <- getCurrentDirectory
      environment <- addBuildSupportEnvironment repoRoot []
      bootstrapResult <- ensureSandboxedStyleTools repoRoot environment
      bootstrapResult `shouldBe` Right ()
      let sandboxDir = styleToolsBinDir repoRoot
      fourmoluExists <- doesFileExist (sandboxDir </> "fourmolu")
      hlintExists <- doesFileExist (sandboxDir </> "hlint")
      fourmoluExists `shouldBe` True
      hlintExists `shouldBe` True

    it "declares the isolated formatter-tool GHC version in source" $
      formatterToolGhcVersion `shouldBe` "9.12.4"

    it "uses typed-process at the library subprocess boundary" $ do
      repoRoot <- getCurrentDirectory
      cabalContents <- readFile (repoRoot </> "prodbox.cabal")
      subprocessSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "Subprocess.hs")
      let libraryStanza = takeWhile (/= "executable prodbox") (lines cabalContents)
      unlines libraryStanza `shouldContain` "typed-process"
      filter (isPrefixOf "        process ") libraryStanza `shouldBe` []
      subprocessSource `shouldContain` "System.Process.Typed"

    it "uses co-log at the daemon structured logging boundary" $ do
      repoRoot <- getCurrentDirectory
      cabalContents <- readFile (repoRoot </> "prodbox.cabal")
      loggingSource <- readFile (repoRoot </> "src" </> "Prodbox" </> "Gateway" </> "Logging.hs")
      let libraryStanza = takeWhile (/= "executable prodbox") (lines cabalContents)
      unlines libraryStanza `shouldContain` "co-log"
      unlines libraryStanza `shouldContain` "co-log-core"
      loggingSource `shouldContain` "Colog.Actions"
      loggingSource `shouldContain` "Colog.Core"

    it "records the doctrine-owned hlint markers" $ do
      repoRoot <- getCurrentDirectory
      hintContents <- readFile (repoRoot </> ".hlint.yaml")
      mapM_
        (hintContents `shouldContain`)
        [ "Refactor nested case"
        , "Avoid case inside lambda body"
        , "forkIO"
        , "unsafePerformIO"
        , "module-level IORef"
        , "callProcess"
        , "readCreateProcess"
        , "createProcess"
        , "proc"
        , "shell"
        , "putStr"
        , "Text.IO.putStrLn"
        , "hPutStrLn stderr"
        , "Aeson.object"
        , "Aeson.fromList"
        , "sd_notify"
        , "READY=1"
        , "System.FSNotify"
        , "newIORef"
        , "newMVar"
        , "withAsync"
        , "race"
        , "concurrently"
        , "replicateConcurrently"
        ]

    it "keeps the generated command registry target marker-delimited" $ do
      repoRoot <- getCurrentDirectory
      commandDoc <- readFile (repoRoot </> "documents" </> "cli" </> "commands.md")
      commandDoc `shouldContain` "<!-- prodbox:command-registry.markdown:start -->"
      commandDoc `shouldContain` "<!-- prodbox:command-registry.markdown:end -->"

    it "keeps daemon paths free of self-daemonization primitives" $ do
      repoRoot <- getCurrentDirectory
      mapM_
        (assertNoSelfDaemonization repoRoot)
        [ "src/Prodbox/Gateway/Daemon.hs"
        , "src/Prodbox/Workload.hs"
        ]

    it "keeps daemon lifecycle tests off timing and raw shutdown primitives" $ do
      repoRoot <- getCurrentDirectory
      lifecycleTest <- readFile (repoRoot </> "test" </> "daemon-lifecycle" </> "Main.hs")
      lifecycleTest `shouldNotContain` "threadDelay"
      lifecycleTest `shouldNotContain` "terminateProcess"

    propertyTest "generated renderers stay byte-stable across repeated evaluation" $
      all generatedSectionStable generatedSectionRules
        && all trackedGeneratedPathStable trackingGeneratedPaths

    it "keeps generated renderer modules free of forbidden nondeterministic inputs" $ do
      repoRoot <- getCurrentDirectory
      violations <- rendererDeterminismViolations repoRoot
      violations `shouldBe` []

    it "flags forbidden renderer input classes in synthetic examples" $
      mapM_ assertSyntheticDeterminismViolation syntheticRendererExamples

    goldenTest
      "keeps the generated top-level manpage byte-stable"
      "share/man/man1/prodbox.1"
      (pure (BL8.pack (renderTopLevelManpage commandRegistry)))

    goldenTest
      "keeps the generated charts manpage byte-stable"
      "share/man/man1/prodbox-charts.1"
      (pure (BL8.pack (renderGroupManpage chartsSpec)))

    goldenTest
      "keeps the generated bash completion byte-stable"
      "share/completion/bash/prodbox"
      (pure (BL8.pack (renderBashCompletion commandRegistry)))

    it "keeps the generated route inventory marker-delimited in chart manifests" $ do
      repoRoot <- getCurrentDirectory
      apiRouteTemplate <- readFile (repoRoot </> "charts" </> "api" </> "templates" </> "http-route.yaml")
      apiRouteTemplate `shouldContain` "{{/* prodbox:route-registry:start */}}"
      apiRouteTemplate `shouldContain` "{{/* prodbox:route-registry:end */}}"
      apiRouteTemplate `shouldContain` renderHelmRouteInventory
 where
  chartsSpec =
    case filter ((== "charts") . name) (children commandRegistry) of
      chartGroup : _ -> chartGroup
      [] -> commandRegistry

assertNoSelfDaemonization :: FilePath -> FilePath -> IO ()
assertNoSelfDaemonization repoRoot relativePath = do
  contents <- readFile (repoRoot </> relativePath)
  contents `shouldNotContain` "System.Posix.Process"
  contents `shouldNotContain` "forkProcess"
  contents `shouldNotContain` "setsid"

generatedSectionStable :: GeneratedSectionRule -> Bool
generatedSectionStable rule =
  let firstRender = renderGeneratedSection rule
      secondRender = renderGeneratedSection rule
   in firstRender == secondRender

trackedGeneratedPathStable :: TrackedGeneratedPath -> Bool
trackedGeneratedPathStable rule =
  let firstRender = renderTrackedGeneratedPath rule
      secondRender = renderTrackedGeneratedPath rule
   in firstRender == secondRender

assertSyntheticDeterminismViolation :: (String, String, String, String) -> IO ()
assertSyntheticDeterminismViolation (label, sourceText, expectedClass, expectedInput) = do
  let violations = rendererSourceViolations ("synthetic-" ++ label) sourceText
      violationText = unlines violations
  violationText `shouldContain` expectedClass
  violationText `shouldContain` expectedInput

syntheticRendererExamples :: [(String, String, String, String)]
syntheticRendererExamples =
  [ ("timestamp", "render = getCurrentTime", "timestamps", "getCurrentTime")
  , ("random", "render = randomIO", "random-ids", "randomIO")
  , ("locale", "render values = sort values", "locale-dependent-ordering", "sort")
  ,
    ( "terminal"
    , "render = System.Console.Terminal.Size.size"
    , "terminal-width-dependent-wrapping"
    , "System.Console.Terminal.Size"
    )
  ,
    ( "environment"
    , "render = getCurrentDirectory"
    , "environment-dependent-paths"
    , "getCurrentDirectory"
    )
  ]
