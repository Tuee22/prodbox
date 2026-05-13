module Prodbox.CheckCode
  ( DoctrineViolation (..)
  , GeneratedSectionRule (..)
  , doctrineViolationsInPaths
  , generatedSectionRules
  , haskellStyleViolations
  , listRepoOwnedPaths
  , renderGeneratedSection
  , renderTrackedGeneratedPath
  , rendererDeterminismViolations
  , rendererSourceViolations
  , runCheckCode
  , runDocsCommand
  , runLintCommand
  , TrackedGeneratedPath (..)
  , trackingGeneratedPaths
  )
where

import Control.Monad (forM)
import Data.Char (isAlphaNum)
import Data.List (intercalate, isInfixOf, isPrefixOf, isSuffixOf, sort, tails)
import Data.Text qualified as Text
import Prodbox.BuildSupport
  ( addBuildSupportEnvironment
  , syncBuiltOperatorBinary
  )
import Prodbox.CLI.Command
  ( DocsCommand (..)
  , LintCommand (..)
  )
import Prodbox.CLI.Docs
  ( renderBashCompletion
  , renderFishCompletion
  , renderGroupManpage
  , renderMarkdownCommandReference
  , renderTopLevelManpage
  , renderZshCompletion
  )
import Prodbox.CLI.Output (writeError)
import Prodbox.CLI.Spec (CommandSpec (..), commandRegistry)
import Prodbox.Error (fatalError)
import Prodbox.Lint
  ( ensureSandboxedStyleTools
  , missingStyleToolViolations
  , styleToolsBinDir
  )
import Prodbox.PublicEdge (renderHelmRouteInventory)
import Prodbox.Result (Result (..))
import Prodbox.Subprocess qualified as Subprocess
import System.Directory
  ( copyFile
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , listDirectory
  )
import System.Environment (getEnvironment)
import System.Exit
  ( ExitCode (..)
  )
import System.FilePath
  ( normalise
  , splitDirectories
  , takeDirectory
  , takeFileName
  , (</>)
  )
import System.IO.Error (tryIOError)

data DoctrineViolation
  = ForbiddenWorkflowDirectory FilePath
  | ForbiddenHookSurface FilePath
  | ForbiddenBuildShim FilePath
  deriving (Eq, Show)

data GeneratedSectionRule = GeneratedSectionRule
  { generatedSectionKey :: String
  , generatedSectionPath :: FilePath
  , generatedSectionStartMarker :: String
  , generatedSectionEndMarker :: String
  , generatedSectionRender :: () -> String
  , generatedSectionRendererSources :: [FilePath]
  }

data TrackedGeneratedPath = TrackedGeneratedPath
  { trackedGeneratedPathKey :: String
  , trackedGeneratedPathPath :: FilePath
  , trackedGeneratedPathRender :: () -> String
  , trackedGeneratedPathRendererSources :: [FilePath]
  }

generatedSectionRules :: [GeneratedSectionRule]
generatedSectionRules =
  [ GeneratedSectionRule
      { generatedSectionKey = "command-registry.markdown"
      , generatedSectionPath = "documents/cli/commands.md"
      , generatedSectionStartMarker = "<!-- prodbox:command-registry.markdown:start -->"
      , generatedSectionEndMarker = "<!-- prodbox:command-registry.markdown:end -->"
      , generatedSectionRender = const (renderMarkdownCommandReference commandRegistry)
      , generatedSectionRendererSources = ["src/Prodbox/CLI/Docs.hs"]
      }
  , GeneratedSectionRule
      { generatedSectionKey = "route-registry.api"
      , generatedSectionPath = "charts/api/templates/http-route.yaml"
      , generatedSectionStartMarker = "{{/* prodbox:route-registry:start */}}"
      , generatedSectionEndMarker = "{{/* prodbox:route-registry:end */}}"
      , generatedSectionRender = const renderHelmRouteInventory
      , generatedSectionRendererSources = ["src/Prodbox/PublicEdge.hs"]
      }
  , GeneratedSectionRule
      { generatedSectionKey = "route-registry.keycloak"
      , generatedSectionPath = "charts/keycloak/templates/gateway.yaml"
      , generatedSectionStartMarker = "{{/* prodbox:route-registry:start */}}"
      , generatedSectionEndMarker = "{{/* prodbox:route-registry:end */}}"
      , generatedSectionRender = const renderHelmRouteInventory
      , generatedSectionRendererSources = ["src/Prodbox/PublicEdge.hs"]
      }
  , GeneratedSectionRule
      { generatedSectionKey = "route-registry.vscode"
      , generatedSectionPath = "charts/vscode/templates/http-route.yaml"
      , generatedSectionStartMarker = "{{/* prodbox:route-registry:start */}}"
      , generatedSectionEndMarker = "{{/* prodbox:route-registry:end */}}"
      , generatedSectionRender = const renderHelmRouteInventory
      , generatedSectionRendererSources = ["src/Prodbox/PublicEdge.hs"]
      }
  , GeneratedSectionRule
      { generatedSectionKey = "route-registry.websocket"
      , generatedSectionPath = "charts/websocket/templates/http-route.yaml"
      , generatedSectionStartMarker = "{{/* prodbox:route-registry:start */}}"
      , generatedSectionEndMarker = "{{/* prodbox:route-registry:end */}}"
      , generatedSectionRender = const renderHelmRouteInventory
      , generatedSectionRendererSources = ["src/Prodbox/PublicEdge.hs"]
      }
  ]

trackingGeneratedPaths :: [TrackedGeneratedPath]
trackingGeneratedPaths =
  TrackedGeneratedPath
    { trackedGeneratedPathKey = "command-registry.manpage.prodbox"
    , trackedGeneratedPathPath = "share/man/man1/prodbox.1"
    , trackedGeneratedPathRender = const (renderTopLevelManpage commandRegistry)
    , trackedGeneratedPathRendererSources = ["src/Prodbox/CLI/Docs.hs"]
    }
    : map commandGroupManpageRule (children commandRegistry)
    ++ [ TrackedGeneratedPath
           { trackedGeneratedPathKey = "command-registry.completion.bash"
           , trackedGeneratedPathPath = "share/completion/bash/prodbox"
           , trackedGeneratedPathRender = const (renderBashCompletion commandRegistry)
           , trackedGeneratedPathRendererSources = ["src/Prodbox/CLI/Docs.hs"]
           }
       , TrackedGeneratedPath
           { trackedGeneratedPathKey = "command-registry.completion.zsh"
           , trackedGeneratedPathPath = "share/completion/zsh/_prodbox"
           , trackedGeneratedPathRender = const (renderZshCompletion commandRegistry)
           , trackedGeneratedPathRendererSources = ["src/Prodbox/CLI/Docs.hs"]
           }
       , TrackedGeneratedPath
           { trackedGeneratedPathKey = "command-registry.completion.fish"
           , trackedGeneratedPathPath = "share/completion/fish/prodbox.fish"
           , trackedGeneratedPathRender = const (renderFishCompletion commandRegistry)
           , trackedGeneratedPathRendererSources = ["src/Prodbox/CLI/Docs.hs"]
           }
       ]
 where
  commandGroupManpageRule commandGroup =
    TrackedGeneratedPath
      { trackedGeneratedPathKey = "command-registry.manpage." ++ name commandGroup
      , trackedGeneratedPathPath = "share/man/man1/prodbox-" ++ name commandGroup ++ ".1"
      , trackedGeneratedPathRender = const (renderGroupManpage commandGroup)
      , trackedGeneratedPathRendererSources = ["src/Prodbox/CLI/Docs.hs"]
      }

renderGeneratedSection :: GeneratedSectionRule -> String
renderGeneratedSection rule = generatedSectionRender rule ()

renderTrackedGeneratedPath :: TrackedGeneratedPath -> String
renderTrackedGeneratedPath rule = trackedGeneratedPathRender rule ()

doctrineViolationsInPaths :: [FilePath] -> [DoctrineViolation]
doctrineViolationsInPaths =
  concatMap (pathViolations . normalise)
 where
  pathViolations relativePath
    | takeFileName relativePath == ".github" =
        [ForbiddenWorkflowDirectory relativePath]
    | takeFileName relativePath `elem` forbiddenHookDirectories =
        [ForbiddenHookSurface relativePath]
    | takeFileName relativePath `elem` forbiddenHookConfigs =
        [ForbiddenHookSurface relativePath]
    | isRepoRootPath relativePath && takeFileName relativePath `elem` forbiddenBuildShims =
        [ForbiddenBuildShim relativePath]
    | takeFileName relativePath `elem` forbiddenHookScripts
        && (isRepoRootPath relativePath || "hooks" `elem` splitDirectories relativePath) =
        [ForbiddenHookSurface relativePath]
    | otherwise = []

  forbiddenHookDirectories = [".githooks", ".husky"]
  forbiddenHookConfigs = [".pre-commit-config.yaml", ".pre-commit-hooks.yaml", "lefthook.yml"]
  forbiddenHookScripts = ["pre-commit", "pre-push", "post-commit", "pre-merge-commit"]
  forbiddenBuildShims = ["Makefile", "justfile", "Taskfile.yml"]
  isRepoRootPath relativePath = takeDirectory relativePath `elem` [".", ""]

runCheckCode :: FilePath -> IO ExitCode
runCheckCode repoRoot = do
  baseEnvironment <- getEnvironment
  environment <- addBuildSupportEnvironment repoRoot baseEnvironment
  putStrLn "Running prodbox check-code (policy + formatter + linter + warning-clean build)"
  lintExit <- runLintAll repoRoot environment
  case lintExit of
    ExitFailure _ -> pure lintExit
    ExitSuccess -> do
      buildExit <-
        runStreaming
          repoRoot
          environment
          "cabal"
          ["build", "--builddir=.build", "all", "--ghc-options=-Werror"]
      case buildExit of
        ExitFailure _ -> pure buildExit
        ExitSuccess -> do
          syncResult <- syncBuiltOperatorBinary repoRoot environment
          case syncResult of
            Left err -> failWith err
            Right _ -> pure ExitSuccess

runDocsCommand :: FilePath -> DocsCommand -> IO ExitCode
runDocsCommand repoRoot command =
  case command of
    DocsCheck -> runGeneratedArtifactLint repoRoot False
    DocsGenerate -> runGeneratedArtifactLint repoRoot True

runLintCommand :: FilePath -> LintCommand -> IO ExitCode
runLintCommand repoRoot command = do
  baseEnvironment <- getEnvironment
  environment <- addBuildSupportEnvironment repoRoot baseEnvironment
  case command of
    LintAll -> runLintAll repoRoot environment
    LintFiles _writeEnabled -> runFileLint repoRoot
    LintDocs writeEnabled -> runGeneratedArtifactLint repoRoot writeEnabled
    LintHaskell writeEnabled -> runHaskellLint repoRoot environment writeEnabled
    LintChart -> runChartLint repoRoot

runLintAll :: FilePath -> [(String, String)] -> IO ExitCode
runLintAll repoRoot environment = do
  filesExit <- runFileLint repoRoot
  case filesExit of
    ExitFailure _ -> pure filesExit
    ExitSuccess -> do
      docsExit <- runGeneratedArtifactLint repoRoot False
      case docsExit of
        ExitFailure _ -> pure docsExit
        ExitSuccess -> do
          haskellExit <- runHaskellLint repoRoot environment False
          case haskellExit of
            ExitFailure _ -> pure haskellExit
            ExitSuccess -> runChartLint repoRoot

runFileLint :: FilePath -> IO ExitCode
runFileLint repoRoot = do
  doctrineExit <- runDoctrineAlignmentCheck repoRoot
  case doctrineExit of
    ExitFailure _ -> pure doctrineExit
    ExitSuccess -> do
      thinMainResult <- verifyThinMainEntrypoint repoRoot
      case thinMainResult of
        Left err -> failWith err
        Right () -> do
          dhallViolations <- checkFrozenDhallImports repoRoot
          case dhallViolations of
            [] -> runTrackedGeneratedPathLint repoRoot
            _ ->
              failWith
                (unlines ("Dhall freeze lint failed:" : map ("- " ++) dhallViolations))

runGeneratedArtifactLint :: FilePath -> Bool -> IO ExitCode
runGeneratedArtifactLint repoRoot writeEnabled = do
  results <- processGeneratedArtifacts repoRoot writeEnabled
  case firstLeft results of
    Just err -> failWith err
    Nothing -> do
      whenWriteRepoFiles results
      pure ExitSuccess

runTrackedGeneratedPathLint :: FilePath -> IO ExitCode
runTrackedGeneratedPathLint repoRoot = do
  results <- processGeneratedArtifacts repoRoot False
  case firstLeft results of
    Just err -> failWith err
    Nothing -> pure ExitSuccess

runHaskellLint :: FilePath -> [(String, String)] -> Bool -> IO ExitCode
runHaskellLint repoRoot environment writeEnabled = do
  bootstrapResult <- ensureSandboxedStyleTools repoRoot environment
  case bootstrapResult of
    Right () -> do
      sandboxViolations <- missingStyleToolViolations (styleToolsBinDir repoRoot)
      case sandboxViolations of
        [] -> do
          styleViolations <- haskellStyleViolations repoRoot
          case styleViolations of
            [] -> do
              formatExit <-
                runStreaming
                  repoRoot
                  environment
                  (styleToolsBinDir repoRoot </> "fourmolu")
                  (["--mode", if writeEnabled then "inplace" else "check", "app", "src", "test"])
              case formatExit of
                ExitFailure _ -> pure formatExit
                ExitSuccess -> do
                  lintExit <-
                    runStreaming
                      repoRoot
                      environment
                      (styleToolsBinDir repoRoot </> "hlint")
                      ["app", "src", "test", "--hint=.hlint.yaml", "--with-group=default", "--with-group=extra"]
                  case lintExit of
                    ExitFailure _ -> pure lintExit
                    ExitSuccess ->
                      if writeEnabled
                        then rewriteCabalFile repoRoot environment
                        else checkCabalFormat repoRoot environment
            _ ->
              failWith
                (unlines ("Haskell style lint failed:" : map ("- " ++) styleViolations))
        _ ->
          failWith
            (unlines ("Haskell style lint failed:" : map ("- " ++) sandboxViolations))
    Left err ->
      failWith
        (unlines ["Haskell style lint failed:", "- " ++ err])

runChartLint :: FilePath -> IO ExitCode
runChartLint repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  let chartFiles =
        sort
          [ path
          | path <- repoPaths
          , takeFileName path == "Chart.yaml"
          , "charts" `isPrefixOf` path
          ]
  if null chartFiles
    then failWith "No chart manifests found under `charts/`."
    else do
      chartViolations <- fmap concat (forM chartFiles (chartViolationsFor repoRoot))
      generatedResults <- processChartGeneratedArtifacts repoRoot
      case chartViolations ++ leftMessages generatedResults of
        [] -> pure ExitSuccess
        violations ->
          failWith (unlines ("Chart lint failed:" : map ("- " ++) violations))

runDoctrineAlignmentCheck :: FilePath -> IO ExitCode
runDoctrineAlignmentCheck repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  let violations = doctrineViolationsInPaths repoPaths
  case violations of
    [] -> pure ExitSuccess
    _ ->
      failWith
        ( unlines
            ( "Doctrine alignment failed. Remove unsupported workflow or git-hook surfaces:"
                : map (("- " ++) . renderDoctrineViolation) violations
                ++ ["Rerun `./.build/prodbox check-code` after removing the listed paths."]
            )
        )

haskellStyleViolations :: FilePath -> IO [String]
haskellStyleViolations repoRoot = do
  thinMainResult <- verifyThinMainEntrypoint repoRoot
  hlintConfigViolations <- checkHlintDoctrineCoverage repoRoot
  parserModuleViolation <- checkParserModuleImports repoRoot
  nestedCaseViolations <- checkNestedCaseViolations repoRoot
  daemonRuntimeViolations <- checkDaemonRuntimeImports repoRoot
  subprocessViolations <- checkSubprocessBoundaries repoRoot
  errorBoundaryViolations <- checkErrorBoundaryViolations repoRoot
  testSuiteTypeViolations <- checkTestSuiteInterfaces repoRoot
  pure
    ( either pure (const []) thinMainResult
        ++ hlintConfigViolations
        ++ maybeToList parserModuleViolation
        ++ nestedCaseViolations
        ++ daemonRuntimeViolations
        ++ subprocessViolations
        ++ errorBoundaryViolations
        ++ testSuiteTypeViolations
    )

checkHlintDoctrineCoverage :: FilePath -> IO [String]
checkHlintDoctrineCoverage repoRoot = do
  let hintPath = repoRoot </> ".hlint.yaml"
  fileExists <- doesFileExist hintPath
  if not fileExists
    then pure ["Missing `/.hlint.yaml` doctrine configuration file."]
    else do
      contents <- readFile hintPath
      pure
        [ "`.hlint.yaml` must mention `" ++ marker ++ "`."
        | marker <-
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
            ]
        , null (filter (isInfixOf marker) (lines contents))
        ]

verifyThinMainEntrypoint :: FilePath -> IO (Either String ())
verifyThinMainEntrypoint repoRoot = do
  let mainPath = repoRoot </> "app" </> "prodbox" </> "Main.hs"
  fileExists <- doesFileExist mainPath
  if not fileExists
    then pure (Left "Missing `app/prodbox/Main.hs`; the library-first entrypoint gate cannot run.")
    else do
      contents <- readFile mainPath
      let normalizedLines =
            filter
              (not . null)
              (map trimLine (lines contents))
          allowedLines =
            [ "module Main (main) where"
            , "import Prodbox.App qualified as App"
            , "main :: IO ()"
            , "main = App.main"
            ]
      pure $
        if normalizedLines == allowedLines
          then Right ()
          else
            Left
              "library-first lint failed for `app/prodbox/Main.hs`: keep `Main.hs` thin (`main = Prodbox.App.main`) and move all logic into `src/`."

checkParserModuleImports :: FilePath -> IO (Maybe String)
checkParserModuleImports repoRoot = do
  let parserPath = repoRoot </> "test" </> "unit" </> "Parser.hs"
  fileExists <- doesFileExist parserPath
  if not fileExists
    then pure Nothing
    else do
      contents <- readFile parserPath
      pure $
        if "typed-process" `isInfixOf` contents
          then Just "`test/unit/Parser.hs` must not import or mention `typed-process`."
          else Nothing

checkNestedCaseViolations :: FilePath -> IO [String]
checkNestedCaseViolations repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  concat
    <$> forM
      [ path
      | path <- repoPaths
      , isHaskellSourcePath path
      ]
      ( \relativePath -> do
          contents <- readFile (repoRoot </> relativePath)
          pure (lambdaCaseViolations relativePath (lines contents))
      )

lambdaCaseViolations :: FilePath -> [String] -> [String]
lambdaCaseViolations relativePath sourceLines =
  [ relativePath
      ++ " line "
      ++ show lineNumber
      ++ " violates `Avoid case inside lambda body`; extract a named helper to satisfy `Refactor nested case`."
  | (lineNumber, lineText, maybeNextLine) <- withNextLines sourceLines
  , lambdaIntroducesCase lineText maybeNextLine
  ]

lambdaIntroducesCase :: String -> Maybe String -> Bool
lambdaIntroducesCase lineText maybeNextLine =
  ("\\" `isInfixOf` lineText)
    && ( ("-> case" `isInfixOf` lineText)
           || maybe False nextLineStartsLambdaBodyCase maybeNextLine
       )
 where
  currentIndent = leadingWhitespaceCount lineText
  nextLineStartsLambdaBodyCase nextLine =
    "->" `isInfixOf` lineText
      && leadingWhitespaceCount nextLine > currentIndent
      && startsWithCase (trimLeft nextLine)

startsWithCase :: String -> Bool
startsWithCase lineText =
  "case " `isPrefixOf` lineText

withNextLines :: [String] -> [(Int, String, Maybe String)]
withNextLines sourceLines =
  [ (lineNumber, lineText, nextMeaningfulLine remaining)
  | (lineNumber, lineText, remaining) <- zip3 [1 :: Int ..] sourceLines (tails sourceLines)
  ]

nextMeaningfulLine :: [String] -> Maybe String
nextMeaningfulLine [] = Nothing
nextMeaningfulLine (_current : remaining) =
  case dropWhile (null . trimLeft) remaining of
    nextLine : _ -> Just nextLine
    [] -> Nothing

leadingWhitespaceCount :: String -> Int
leadingWhitespaceCount = length . takeWhile (== ' ')

isHaskellSourcePath :: FilePath -> Bool
isHaskellSourcePath path =
  (".hs" `isSuffixOf` path)
    && any (`isPrefixOf` path) ["app/", "src/", "test/"]

checkDaemonRuntimeImports :: FilePath -> IO [String]
checkDaemonRuntimeImports repoRoot = do
  let daemonPaths =
        [ repoRoot </> "src" </> "Prodbox" </> "Gateway" </> "Daemon.hs"
        , repoRoot </> "src" </> "Prodbox" </> "Workload.hs"
        ]
  fmap concat $
    forM daemonPaths $ \path -> do
      contents <- readFile path
      let importViolations =
            [ path ++ " must not import `System.Posix.Process`."
            | "System.Posix.Process" `isInfixOf` contents
            ]
          forkViolations =
            [ path ++ " must not call `forkProcess`."
            | "forkProcess" `isInfixOf` contents
            ]
          rawThreadViolations =
            [ path ++ " must not call `forkIO`."
            | "forkIO" `isInfixOf` contents
            ]
          unsafeViolations =
            [ path ++ " must not call `unsafePerformIO`."
            | "unsafePerformIO" `isInfixOf` contents
            ]
          moduleLevelIoRefViolations =
            [ path ++ " must not define a module-level `IORef`."
            | "unsafePerformIO" `isInfixOf` contents
                && "IORef" `isInfixOf` contents
            ]
          sessionViolations =
            [ path ++ " must not call `setsid`."
            | "setsid" `isInfixOf` contents
            ]
      pure
        ( importViolations
            ++ forkViolations
            ++ rawThreadViolations
            ++ unsafeViolations
            ++ moduleLevelIoRefViolations
            ++ sessionViolations
        )

checkSubprocessBoundaries :: FilePath -> IO [String]
checkSubprocessBoundaries repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  concat
    <$> forM
      [ path
      | path <- repoPaths
      , "src/Prodbox/" `isPrefixOf` path
      , ".hs" `isSuffixOf` path
      , path /= "src/Prodbox/Subprocess.hs"
      , path /= "src/Prodbox/CheckCode.hs"
      ]
      ( \relativePath -> do
          contents <- readFile (repoRoot </> relativePath)
          let tokens = tokenizeSource contents
              hasSystemProcessImport = "import System.Process" `isInfixOf` contents
              forbiddenTokens =
                [ token
                | token <-
                    [ "callProcess"
                    , "readCreateProcess"
                    , "readCreateProcessWithExitCode"
                    , "createProcess"
                    , "shell"
                    ]
                , token `elem` tokens
                ]
          pure $
            [ relativePath ++ " must route subprocess creation through `src/Prodbox/Subprocess.hs`."
            | hasSystemProcessImport || not (null forbiddenTokens)
            ]
      )

checkErrorBoundaryViolations :: FilePath -> IO [String]
checkErrorBoundaryViolations repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  concat
    <$> forM
      [ path
      | path <- repoPaths
      , "src/Prodbox/" `isPrefixOf` path
      , ".hs" `isSuffixOf` path
      , path /= "src/Prodbox/CLI/Output.hs"
      , path /= "src/Prodbox/CheckCode.hs"
      ]
      ( \relativePath -> do
          contents <- readFile (repoRoot </> relativePath)
          let tokens = tokenizeSource contents
          pure $
            [ relativePath ++ " must route error rendering through `src/Prodbox/CLI/Output.hs`."
            | any (`elem` tokens) ["print", "exitFailure"]
            ]
      )

checkTestSuiteInterfaces :: FilePath -> IO [String]
checkTestSuiteInterfaces repoRoot = do
  let cabalPath = repoRoot </> "prodbox.cabal"
  contents <- readFile cabalPath
  pure (go [] Nothing (lines contents))
 where
  go violations _ [] = reverse violations
  go violations currentSuite (lineText : remaining) =
    let trimmedLine = trimLeft lineText
     in if "test-suite " `isPrefixOf` trimmedLine
          then
            let suiteName = drop (length ("test-suite " :: String)) trimmedLine
             in go violations (Just (trimLine suiteName, False)) remaining
          else
            if "type:" `isPrefixOf` trimmedLine
              then case currentSuite of
                Just (suiteName, False) ->
                  let hasExpectedType = "exitcode-stdio-1.0" `isInfixOf` lineText
                      nextViolations =
                        if hasExpectedType
                          then violations
                          else ("Test suite `" ++ suiteName ++ "` must declare `type: exitcode-stdio-1.0`.") : violations
                   in go nextViolations (Just (suiteName, True)) remaining
                _ -> go violations currentSuite remaining
              else go violations currentSuite remaining

checkFrozenDhallImports :: FilePath -> IO [String]
checkFrozenDhallImports repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  concat
    <$> forM
      [ path
      | path <- repoPaths
      , ".dhall" `isSuffixOf` path
      ]
      ( \relativePath -> do
          contents <- readFile (repoRoot </> relativePath)
          pure (unfrozenDhallImportViolations relativePath contents)
      )

unfrozenDhallImportViolations :: FilePath -> String -> [String]
unfrozenDhallImportViolations relativePath contents =
  let fileLines = lines contents
   in [ relativePath
          ++ " contains an unfrozen Dhall import on line "
          ++ show lineNumber
          ++ ". Run `dhall freeze --all --inplace "
          ++ relativePath
          ++ "`."
      | (lineNumber, lineText) <- zip [1 :: Int ..] fileLines
      , let trimmedLine = trimLeft lineText
      , not ("--" `isPrefixOf` trimmedLine)
      , containsLocalDhallImport lineText
      , not (dhallImportIsFrozen fileLines lineNumber)
      ]

containsLocalDhallImport :: String -> Bool
containsLocalDhallImport =
  any isLocalImportToken . words
 where
  isLocalImportToken token =
    "./" `isPrefixOf` token || "../" `isPrefixOf` token || "~/" `isPrefixOf` token

dhallImportIsFrozen :: [String] -> Int -> Bool
dhallImportIsFrozen fileLines lineNumber =
  any ("sha256:" `isInfixOf`) (take 3 (drop (lineNumber - 1) fileLines))

rendererDeterminismViolations :: FilePath -> IO [String]
rendererDeterminismViolations repoRoot =
  fmap concat $
    forM uniqueRendererSources $ \relativePath -> do
      contents <- readFile (repoRoot </> relativePath)
      pure (rendererSourceViolations relativePath contents)
 where
  uniqueRendererSources =
    dedupeSorted
      ( concatMap generatedSectionRendererSources generatedSectionRules
          ++ concatMap trackedGeneratedPathRendererSources trackingGeneratedPaths
      )

rendererSourceViolations :: FilePath -> String -> [String]
rendererSourceViolations sourceLabel sourceText =
  concatMap violationsFor forbiddenRendererInputs
 where
  sourceTokens = tokenizeSource sourceText
  violationsFor (inputClass, tokens, substrings) =
    let matchedTokens = filter (`elem` sourceTokens) tokens
        matchedSubstrings = filter (`isInfixOf` sourceText) substrings
        matchedInputs = matchedTokens ++ matchedSubstrings
     in [ sourceLabel
            ++ " uses forbidden renderer input class `"
            ++ inputClass
            ++ "` via "
            ++ commaSeparated matchedInputs
            ++ "."
        | not (null matchedInputs)
        ]
  forbiddenRendererInputs =
    [ ("timestamps", ["getCurrentTime", "getZonedTime", "getPOSIXTime"], [])
    , ("random-ids", ["randomIO", "randomRIO"], ["UUID"])
    , ("locale-dependent-ordering", ["sort"], [])
    ,
      ( "terminal-width-dependent-wrapping"
      , ["getTerminalSize"]
      , ["System.Console.Terminal.Size", "COLUMNS"]
      )
    , ("environment-dependent-paths", ["getCurrentDirectory", "getHomeDirectory", "getEnv"], [])
    ]

tokenizeSource :: String -> [String]
tokenizeSource =
  words . map normalizeCharacter
 where
  normalizeCharacter character
    | isAlphaNum character || character == '_' = character
    | otherwise = ' '

commaSeparated :: [String] -> String
commaSeparated = intercalate ", " . sort

dedupeSorted :: [String] -> [String]
dedupeSorted = go . sort
 where
  go [] = []
  go (value : remaining) =
    value : go (dropWhile (== value) remaining)

rewriteCabalFile :: FilePath -> [(String, String)] -> IO ExitCode
rewriteCabalFile repoRoot environment = do
  cabalTextResult <- renderFormattedCabal repoRoot environment
  case cabalTextResult of
    Left err -> failWith err
    Right renderedCabal -> do
      writeFile (repoRoot </> "prodbox.cabal") renderedCabal
      pure ExitSuccess

checkCabalFormat :: FilePath -> [(String, String)] -> IO ExitCode
checkCabalFormat repoRoot environment = do
  currentContents <- readFile (repoRoot </> "prodbox.cabal")
  cabalTextResult <- renderFormattedCabal repoRoot environment
  case cabalTextResult of
    Left err -> failWith err
    Right renderedCabal ->
      if currentContents == renderedCabal
        then pure ExitSuccess
        else
          failWith
            "cabal format drift detected in `prodbox.cabal`. Run `prodbox lint haskell --write` to rewrite the file."

renderFormattedCabal :: FilePath -> [(String, String)] -> IO (Either String String)
renderFormattedCabal repoRoot environment = do
  createDirectoryIfMissing True (repoRoot </> ".build")
  let tempCabalPath = repoRoot </> ".build" </> "prodbox.cabal.format"
      cabalPath = repoRoot </> "prodbox.cabal"
  copyFile cabalPath tempCabalPath
  formatExit <- runStreaming repoRoot environment "cabal" ["format", tempCabalPath]
  case formatExit of
    ExitFailure _ ->
      pure (Left "Failed to format `prodbox.cabal` via `cabal format`.")
    ExitSuccess -> Right <$> readFile tempCabalPath

spliceGeneratedSection :: String -> GeneratedSectionRule -> Either String String
spliceGeneratedSection contents rule = do
  let fileLines = lines contents
      startMarker = generatedSectionStartMarker rule
      endMarker = generatedSectionEndMarker rule
      beforeMarker = takeWhile (/= startMarker) fileLines
      afterStart = dropWhile (/= startMarker) fileLines
  case afterStart of
    [] ->
      Left ("Missing start marker `" ++ startMarker ++ "` in `" ++ generatedSectionPath rule ++ "`.")
    (_ : remainingAfterStart) ->
      let afterMarker = dropWhile (/= endMarker) remainingAfterStart
       in case afterMarker of
            [] ->
              Left ("Missing end marker `" ++ endMarker ++ "` in `" ++ generatedSectionPath rule ++ "`.")
            (_ : trailingLines) ->
              Right
                ( unlines
                    ( beforeMarker
                        ++ [startMarker]
                        ++ lines (renderGeneratedSection rule)
                        ++ [endMarker]
                        ++ trailingLines
                    )
                )

generatedSectionDriftMessage :: FilePath -> GeneratedSectionRule -> String
generatedSectionDriftMessage targetPath rule =
  generatedAssetDriftMessage targetPath (generatedSectionKey rule)

generatedAssetDriftMessage :: FilePath -> String -> String
generatedAssetDriftMessage targetPath registryKey =
  unlines
    [ targetPath
    , registryKey
    , "Run `prodbox docs generate` to update."
    ]

missingGeneratedTargetMessage :: GeneratedSectionRule -> String
missingGeneratedTargetMessage rule =
  missingGeneratedFileMessage (generatedSectionPath rule) (generatedSectionKey rule)

missingGeneratedFileMessage :: FilePath -> String -> String
missingGeneratedFileMessage path registryKey =
  "Missing generated documentation target `"
    ++ path
    ++ "` for registry key `"
    ++ registryKey
    ++ "`."

processGeneratedArtifacts :: FilePath -> Bool -> IO [Either String (FilePath, String, Bool)]
processGeneratedArtifacts repoRoot writeEnabled = do
  sectionResults <- forM generatedSectionRules (processGeneratedSection repoRoot writeEnabled)
  fileResults <- forM trackingGeneratedPaths (processTrackedGeneratedPath repoRoot writeEnabled)
  pure (sectionResults ++ fileResults)

processGeneratedSection
  :: FilePath -> Bool -> GeneratedSectionRule -> IO (Either String (FilePath, String, Bool))
processGeneratedSection repoRoot writeEnabled rule = do
  let targetPath = repoRoot </> generatedSectionPath rule
  fileExists <- doesFileExist targetPath
  if not fileExists
    then pure (Left (missingGeneratedTargetMessage rule))
    else do
      contents <- readFile targetPath
      let forcedContents = length contents `seq` contents
      pure $
        case spliceGeneratedSection forcedContents rule of
          Left err -> Left err
          Right expectedContents ->
            if writeEnabled
              then Right (targetPath, expectedContents, forcedContents /= expectedContents)
              else
                if forcedContents == expectedContents
                  then Right (targetPath, expectedContents, False)
                  else Left (generatedSectionDriftMessage targetPath rule)

processTrackedGeneratedPath
  :: FilePath -> Bool -> TrackedGeneratedPath -> IO (Either String (FilePath, String, Bool))
processTrackedGeneratedPath repoRoot writeEnabled rule = do
  let targetPath = repoRoot </> trackedGeneratedPathPath rule
      expectedContents = renderTrackedGeneratedPath rule
  fileExists <- doesFileExist targetPath
  case (fileExists, writeEnabled) of
    (False, False) ->
      pure
        ( Left
            ( missingGeneratedFileMessage
                (trackedGeneratedPathPath rule)
                (trackedGeneratedPathKey rule)
            )
        )
    (False, True) -> pure (Right (targetPath, expectedContents, True))
    (True, _) -> do
      currentContents <- readFile targetPath
      let forcedContents = length currentContents `seq` currentContents
          hasDrift = forcedContents /= expectedContents
      pure $
        if writeEnabled || not hasDrift
          then Right (targetPath, expectedContents, hasDrift)
          else Left (generatedAssetDriftMessage targetPath (trackedGeneratedPathKey rule))

processChartGeneratedArtifacts :: FilePath -> IO [Either String (FilePath, String, Bool)]
processChartGeneratedArtifacts repoRoot =
  forM
    [ rule
    | rule <- generatedSectionRules
    , "charts/" `isPrefixOf` generatedSectionPath rule
    ]
    (processGeneratedSection repoRoot False)

chartViolationsFor :: FilePath -> FilePath -> IO [String]
chartViolationsFor repoRoot relativeChartPath = do
  let absoluteChartPath = repoRoot </> relativeChartPath
      chartDir = takeDirectory absoluteChartPath
      helperPath = chartDir </> "templates" </> "_helpers.tpl"
  chartContents <- readFile absoluteChartPath
  helperExists <- doesFileExist helperPath
  helperViolations <-
    if helperExists
      then do
        helperContents <- readFile helperPath
        pure (labelViolations helperPath helperContents)
      else pure [helperPath ++ " is missing the shared label helper."]
  pure (manifestViolations relativeChartPath chartContents ++ helperViolations)
 where
  manifestViolations path contents =
    missingPrefixedFields path contents ["apiVersion: v2", "name:", "version:", "appVersion:"]

labelViolations :: FilePath -> String -> [String]
labelViolations helperPath contents =
  missingPrefixedFields
    helperPath
    contents
    [ "app.kubernetes.io/name:"
    , "app.kubernetes.io/managed-by: prodbox"
    , "prodbox.io/chart-root:"
    ]

missingPrefixedFields :: FilePath -> String -> [String] -> [String]
missingPrefixedFields path contents =
  map missingFieldMessage . filter (not . containsField)
 where
  normalizedLines = map trimLine (lines contents)
  containsField expectedPrefix =
    any (expectedPrefix `isPrefixOf`) normalizedLines
  missingFieldMessage expectedPrefix =
    path ++ " is missing required chart field `" ++ expectedPrefix ++ "`."

leftMessages :: [Either String right] -> [String]
leftMessages [] = []
leftMessages (value : remaining) =
  case value of
    Left err -> err : leftMessages remaining
    Right _ -> leftMessages remaining

whenWriteRepoFiles :: [Either String (FilePath, String, Bool)] -> IO ()
whenWriteRepoFiles results =
  mapM_ writeUpdatedFile (rightsOnly results)
 where
  writeUpdatedFile (targetPath, expectedContents, hasDrift) =
    if hasDrift
      then do
        createDirectoryIfMissing True (takeDirectory targetPath)
        writeFile targetPath expectedContents
      else pure ()

firstLeft :: [Either left right] -> Maybe left
firstLeft [] = Nothing
firstLeft (value : remaining) =
  case value of
    Left err -> Just err
    Right _ -> firstLeft remaining

rightsOnly :: [Either left right] -> [right]
rightsOnly [] = []
rightsOnly (value : remaining) =
  case value of
    Left _ -> rightsOnly remaining
    Right success -> success : rightsOnly remaining

maybeToList :: Maybe a -> [a]
maybeToList Nothing = []
maybeToList (Just value) = [value]

trimLeft :: String -> String
trimLeft = dropWhile (`elem` [' ', '\t'])

trimLine :: String -> String
trimLine = reverse . dropWhile (`elem` [' ', '\t']) . reverse . trimLeft

listRepoOwnedPaths :: FilePath -> IO [FilePath]
listRepoOwnedPaths repoRoot = scanDirectory ""
 where
  scanDirectory :: FilePath -> IO [FilePath]
  scanDirectory relativeRoot = do
    let directoryPath =
          if null relativeRoot
            then repoRoot
            else repoRoot </> relativeRoot
    entriesResult <- tryIOError (sort <$> listDirectory directoryPath)
    case entriesResult of
      Left _ -> pure []
      Right entries ->
        fmap concat $
          forM entries $ \entry -> do
            let relativePath =
                  if null relativeRoot
                    then entry
                    else relativeRoot </> entry
                absolutePath = repoRoot </> relativePath
            isDirectory <- doesDirectoryExist absolutePath
            if not isDirectory
              then pure [relativePath]
              else
                if entry `elem` excludedDirectories
                  then pure []
                  else
                    if entry `elem` forbiddenDirectories
                      then pure [relativePath]
                      else do
                        descendants <- scanDirectory relativePath
                        pure (relativePath : descendants)

  excludedDirectories = [".git", ".build", "dist-newstyle", ".prodbox-state", ".data"]
  forbiddenDirectories = [".github", ".githooks", ".husky"]

renderDoctrineViolation :: DoctrineViolation -> String
renderDoctrineViolation violation =
  case violation of
    ForbiddenWorkflowDirectory relativePath ->
      relativePath ++ " is forbidden because repository-owned CI workflow automation is not supported."
    ForbiddenHookSurface relativePath ->
      relativePath
        ++ " is forbidden because repository-owned git-hook and pre-commit style tooling is not supported."
    ForbiddenBuildShim relativePath ->
      relativePath
        ++ " is forbidden because root build-shim automation must not duplicate the `prodbox` CLI surface."

runStreaming :: FilePath -> [(String, String)] -> FilePath -> [String] -> IO ExitCode
runStreaming repoRoot environment commandPath arguments = do
  runResult <-
    Subprocess.runStreamingCommand
      Subprocess.CommandSpec
        { Subprocess.commandPath = commandPath
        , Subprocess.commandArguments = arguments
        , Subprocess.commandEnvironment = Just environment
        , Subprocess.commandWorkingDirectory = Just repoRoot
        }
  case runResult of
    Failure err -> do
      writeError (fatalError (Text.pack err))
      pure (ExitFailure 1)
    Success exitCode -> pure exitCode

failWith :: String -> IO ExitCode
failWith message = do
  writeError (fatalError (Text.pack message))
  pure (ExitFailure 1)
