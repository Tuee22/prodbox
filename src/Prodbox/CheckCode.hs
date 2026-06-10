module Prodbox.CheckCode
  ( DoctrineViolation (..)
  , GeneratedSectionRule (..)
  , awsCreateProbeVerbs
  , awsCreateSiteViolations
  , awsCreateVerbs
  , checkCreateCallSiteCoverage
  , checkForbidDotProdboxState
  , doctrineViolationsInPaths
  , extractMarkdownLinkTargets
  , extractStringLiterals
  , generatedSectionRules
  , generatedSectionsReconcilerViolations
  , haskellStyleViolations
  , iamCreateSiteViolations
  , iamCreateVerbs
  , isRelativeLinkTarget
  , listRepoOwnedPaths
  , matchesSprintToken
  , parseGeneratedSectionsField
  , planOptionsHonoredViolations
  , destructivePlanOptionsArms
  , prodboxMarkerKeysPresent
  , pulumiCreateSiteOwners
  , pulumiCreateSiteViolations
  , rawMasterSeedReadScopeViolations
  , relativeLinkResolves
  , renderGeneratedSection
  , renderTrackedGeneratedPath
  , rendererDeterminismViolations
  , rendererSourceViolations
  , runCheckCode
  , serviceErrorRetryableLiteralViolations
  , runDocsCommand
  , runLintCommand
  , substrateImagePinningViolations
  , stripFencedCodeBlocks
  , stripInlineCodeSpans
  , TrackedGeneratedPath (..)
  , trackingGeneratedPaths
  )
where

import Control.Monad (forM)
import Data.Char (isAlphaNum, isDigit, toLower)
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
  , renderCommandSurfaceMatrix
  , renderCommandSurfaceTopLevel
  , renderFishCompletion
  , renderGroupManpage
  , renderMarkdownCommandReference
  , renderTopLevelManpage
  , renderZshCompletion
  )
import Prodbox.CLI.Output
  ( writeError
  , writeOutputLine
  )
import Prodbox.CLI.Spec (CommandSpec (..), commandRegistry)
import Prodbox.Error (fatalError)
import Prodbox.Infra.StackDescriptor
  ( renderStackCommandSurfaceMarkdown
  , stackDescriptors
  )
import Prodbox.Lifecycle.ResourceClass
  ( LifecycleClass (..)
  , renderRegisteredResourcesMarkdown
  , resourceLifecycleClasses
  , resourceNamesOfClass
  )
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
  , -- Sprint 4.22: the managed-resource registry's lifecycle-class facts
    -- are rendered into substrates.md so `prodbox docs check` fails the
    -- build if the doc drifts from the registry SSoT.
    GeneratedSectionRule
      { generatedSectionKey = "resource-lifecycle-classes"
      , generatedSectionPath = "DEVELOPMENT_PLAN/substrates.md"
      , generatedSectionStartMarker = "<!-- prodbox:resource-lifecycle-classes:start -->"
      , generatedSectionEndMarker = "<!-- prodbox:resource-lifecycle-classes:end -->"
      , generatedSectionRender = const (renderRegisteredResourcesMarkdown resourceLifecycleClasses)
      , generatedSectionRendererSources = ["src/Prodbox/Lifecycle/ResourceClass.hs"]
      }
  , -- Sprint 4.27: the registry-name↔CLI-command table is rendered from
    -- the `StackDescriptor` SSoT into substrates.md so `prodbox docs
    -- check` fails the build if the doc drifts from the typed source.
    -- This is the typed source Sprint 0.10 consumes for the
    -- registry-name↔CLI-verb list and Sprint 5.6 consumes for
    -- registry-generated golden coverage.
    GeneratedSectionRule
      { generatedSectionKey = "stack-command-surface"
      , generatedSectionPath = "DEVELOPMENT_PLAN/substrates.md"
      , generatedSectionStartMarker = "<!-- prodbox:stack-command-surface:start -->"
      , generatedSectionEndMarker = "<!-- prodbox:stack-command-surface:end -->"
      , generatedSectionRender = const (renderStackCommandSurfaceMarkdown stackDescriptors)
      , generatedSectionRendererSources = ["src/Prodbox/Infra/StackDescriptor.hs"]
      }
  , -- Sprint 1.29: the §2 top-level command table and the §3 per-group
    -- command matrix in cli_command_surface.md are rendered directly from
    -- the typed `commandRegistry`, so `prodbox docs check` fails the build
    -- if the operator command matrix drifts from the parser SSoT. The §2
    -- table and §3 matrix are non-contiguous (substantial prose lives
    -- between them and after the matrix), so they are two separate
    -- generated sections.
    GeneratedSectionRule
      { generatedSectionKey = "command-surface-toplevel"
      , generatedSectionPath = "documents/engineering/cli_command_surface.md"
      , generatedSectionStartMarker = "<!-- prodbox:command-surface-toplevel:start -->"
      , generatedSectionEndMarker = "<!-- prodbox:command-surface-toplevel:end -->"
      , generatedSectionRender = const (renderCommandSurfaceTopLevel commandRegistry)
      , generatedSectionRendererSources = ["src/Prodbox/CLI/Spec.hs", "src/Prodbox/CLI/Docs.hs"]
      }
  , GeneratedSectionRule
      { generatedSectionKey = "command-surface-matrix"
      , generatedSectionPath = "documents/engineering/cli_command_surface.md"
      , generatedSectionStartMarker = "<!-- prodbox:command-surface-matrix:start -->"
      , generatedSectionEndMarker = "<!-- prodbox:command-surface-matrix:end -->"
      , generatedSectionRender = const (renderCommandSurfaceMatrix commandRegistry)
      , generatedSectionRendererSources = ["src/Prodbox/CLI/Spec.hs", "src/Prodbox/CLI/Docs.hs"]
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
  writeOutputLine "Running prodbox check-code (policy + formatter + linter + warning-clean build)"
  lintExit <- runLintAll repoRoot environment
  case lintExit of
    ExitFailure _ -> pure lintExit
    ExitSuccess -> do
      buildExit <-
        runSubprocessStreaming
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
        Right () -> runTrackedGeneratedPathLint repoRoot

runGeneratedArtifactLint :: FilePath -> Bool -> IO ExitCode
runGeneratedArtifactLint repoRoot writeEnabled = do
  results <- processGeneratedArtifacts repoRoot writeEnabled
  case firstLeft results of
    Just err -> failWith err
    Nothing -> do
      -- The marker-content splice always runs first so `docs generate` /
      -- `--write` still regenerates the registered sections. The two
      -- Sprint 0.9 governed-document checks (header ↔ markers ↔ registry
      -- reconciler + relative-link resolution) then gate the exit code;
      -- they have no auto-fix counterpart, so they only ever fail the
      -- command, never block the writes above.
      whenWriteRepoFiles results
      governedDocViolations <- runGovernedDocChecks repoRoot
      case governedDocViolations of
        [] -> pure ExitSuccess
        violations ->
          failWith
            (unlines ("Governed-document harmony lint failed:" : map ("- " ++) violations))

-- | Sprint 0.9: aggregate the governed-document harmony checks wired into
-- @prodbox lint docs@ / @prodbox docs check@ (and reached by
-- @prodbox check-code@ through @runLintAll@): the @**Generated
-- sections**@ header ↔ markers ↔ registry reconciler and the
-- relative-link resolution check.
runGovernedDocChecks :: FilePath -> IO [String]
runGovernedDocChecks repoRoot = do
  harmonyViolations <- checkGeneratedSectionsHarmony repoRoot
  linkViolations <- checkGovernedDocRelativeLinks repoRoot
  pure (harmonyViolations ++ linkViolations)

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
                runSubprocessStreaming
                  repoRoot
                  environment
                  (styleToolsBinDir repoRoot </> "fourmolu")
                  (["--mode", if writeEnabled then "inplace" else "check", "app", "src", "test"])
              case formatExit of
                ExitFailure _ -> pure formatExit
                ExitSuccess -> do
                  lintExit <-
                    runSubprocessStreaming
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
  let surfaceViolations =
        map (("- " ++) . renderDoctrineViolation) (doctrineViolationsInPaths repoPaths)
  serviceErrorViolations <- checkServiceErrorRetryableLiteral repoRoot
  rawMasterSeedViolations <- checkRawMasterSeedReadScope repoRoot
  planOptionsHonoredViolations' <- checkPlanOptionsHonored repoRoot
  -- Sprint 4.27: the create-site coverage lint (the §3.1 totality gate
  -- over every `aws`/`pulumi` create call site, now generalized from
  -- IAM-only to every AWS-resource create verb via
  -- 'awsCreateSiteViolations') is a doctrine-alignment check, so it is
  -- wired here rather than alongside the Haskell-style lints.
  createCallSiteViolations <- checkCreateCallSiteCoverage repoRoot
  -- Sprint 7.12: substrate equivalence is a structural invariant — a shared
  -- platform component's chart version / image must come from the single
  -- 'Prodbox.ContainerImage' pin, never be re-pinned on a per-substrate
  -- branch. This is a doctrine-alignment check, so it is wired here.
  substrateImagePinningViolations' <- checkSubstrateImagePinning repoRoot
  case surfaceViolations
    ++ map ("- " ++) serviceErrorViolations
    ++ map ("- " ++) rawMasterSeedViolations
    ++ map ("- " ++) planOptionsHonoredViolations'
    ++ map ("- " ++) createCallSiteViolations
    ++ map ("- " ++) substrateImagePinningViolations' of
    [] -> pure ExitSuccess
    violations ->
      failWith
        ( unlines
            ( ( "Doctrine alignment failed. Remove unsupported workflow or git-hook surfaces, "
                  ++ "hand-set ServiceError retryable literals, host-side raw master-seed reads, "
                  ++ "destructive dispatch arms that discard their --dry-run / --plan-file "
                  ++ "options, and AWS/Pulumi create call sites with no registered managed "
                  ++ "resource:"
              )
                : violations
                ++ ["Rerun `./.build/prodbox check-code` after addressing the listed items."]
            )
        )

haskellStyleViolations :: FilePath -> IO [String]
haskellStyleViolations repoRoot = do
  thinMainResult <- verifyThinMainEntrypoint repoRoot
  hlintConfigViolations <- checkHlintDoctrineCoverage repoRoot
  parserModuleViolation <- checkParserModuleImports repoRoot
  nestedCaseViolations <- checkNestedCaseViolations repoRoot
  daemonRuntimeViolations <- checkDaemonRuntimeImports repoRoot
  daemonHookViolations <- checkDaemonHookContract repoRoot
  daemonLifecycleTestViolations <- checkDaemonLifecycleTestBoundaries repoRoot
  subprocessViolations <- checkSubprocessBoundaries repoRoot
  errorBoundaryViolations <- checkErrorBoundaryViolations repoRoot
  operatorVocabularyViolations <- checkOperatorVocabulary repoRoot
  envVarConfigViolations <- checkEnvVarConfigReads repoRoot
  testSuiteTypeViolations <- checkTestSuiteInterfaces repoRoot
  forbidDotProdboxStateViolations <- checkForbidDotProdboxState repoRoot
  pure
    ( either pure (const []) thinMainResult
        ++ hlintConfigViolations
        ++ maybeToList parserModuleViolation
        ++ nestedCaseViolations
        ++ daemonRuntimeViolations
        ++ daemonHookViolations
        ++ daemonLifecycleTestViolations
        ++ subprocessViolations
        ++ errorBoundaryViolations
        ++ operatorVocabularyViolations
        ++ envVarConfigViolations
        ++ testSuiteTypeViolations
        ++ forbidDotProdboxStateViolations
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
            , "readCreateProcessWithExitCode"
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
          readinessSignalViolations =
            [ path
                ++ " must use HTTP `/readyz` as the only readiness signal; filesystem readiness markers and `sd_notify` are forbidden."
            | any
                (`isInfixOf` contents)
                [ "sd_notify"
                , "READY=1"
                , "readiness_marker"
                , "readinessMarker"
                , "ready_file"
                , "readyFile"
                ]
            ]
          mutableMetricsViolations =
            [ path
                ++ " must keep daemon metrics behind `envMetrics`; module-local `IORef`/`MVar` counters are forbidden."
            | "metrics" `isInfixOf` contents || "MetricsRegistry" `isInfixOf` contents
            , any (`elem` tokenizeSource contents) ["newIORef", "newMVar"]
            ]
          asyncPrimitiveViolations =
            [ path
                ++ " must use only the daemon structured-concurrency primitive set: `withAsync`, `race`, `concurrently`, and `replicateConcurrently`."
            | any
                (`elem` tokenizeSource contents)
                [ "async"
                , "wait"
                , "waitAny"
                , "waitEither"
                , "mapConcurrently"
                , "mapConcurrently_"
                ]
            ]
          inlineLogObjectViolations =
            [ path
                ++ " must route structured log fields through `field`; inline `Aeson.object` / `Aeson.fromList` log payloads are forbidden."
            | any daemonLogLineBuildsInlineObject (lines contents)
            ]
      pure
        ( importViolations
            ++ forkViolations
            ++ rawThreadViolations
            ++ unsafeViolations
            ++ moduleLevelIoRefViolations
            ++ sessionViolations
            ++ readinessSignalViolations
            ++ mutableMetricsViolations
            ++ asyncPrimitiveViolations
            ++ inlineLogObjectViolations
        )

daemonLogLineBuildsInlineObject :: String -> Bool
daemonLogLineBuildsInlineObject lineText =
  any (`isInfixOf` lineText) ["logDebug", "logInfo", "logWarn", "logError", "logStructured"]
    && any (`isInfixOf` lineText) ["Aeson.object", "Aeson.fromList", "object ["]

checkDaemonHookContract :: FilePath -> IO [String]
checkDaemonHookContract repoRoot = do
  let path = repoRoot </> "src" </> "Prodbox" </> "Gateway" </> "Daemon.hs"
  contents <- readFile path
  pure
    ( missingHookSurfaceViolations path contents
        ++ [ path
               ++ " must construct the production daemon `Env` with literal `noopDaemonHooks`."
           | not (any ("envHooks = noopDaemonHooks" `isInfixOf`) (lines contents))
           ]
        ++ [ path
               ++ " must read daemon hook fields only through the injected `envHooks env` value."
           | any daemonHookReadBypassesEnv (lines contents)
           ]
    )

missingHookSurfaceViolations :: FilePath -> String -> [String]
missingHookSurfaceViolations path contents =
  [ path ++ " must define daemon hook field `" ++ hookName ++ "`."
  | hookName <-
      [ "envAfterPeerEventCommit"
      , "envBeforeOrdersAdoption"
      , "envOnPeerConnectionEstablished"
      ]
  , hookName `notElem` tokenizeSource contents
  ]

daemonHookReadBypassesEnv :: String -> Bool
daemonHookReadBypassesEnv lineText =
  let trimmedLine = trimLine lineText
   in any (`isInfixOf` trimmedLine) daemonHookNames
        && not (any (`isInfixOf` trimmedLine) allowedHookContexts)
 where
  daemonHookNames =
    [ "envAfterPeerEventCommit"
    , "envBeforeOrdersAdoption"
    , "envOnPeerConnectionEstablished"
    ]
  allowedHookContexts =
    [ "envAfterPeerEventCommit ::"
    , "envBeforeOrdersAdoption ::"
    , "envOnPeerConnectionEstablished ::"
    , "envAfterPeerEventCommit ="
    , "envBeforeOrdersAdoption ="
    , "envOnPeerConnectionEstablished ="
    , "envAfterPeerEventCommit (envHooks env)"
    , "envBeforeOrdersAdoption (envHooks env)"
    , "envOnPeerConnectionEstablished (envHooks env)"
    ]

checkDaemonLifecycleTestBoundaries :: FilePath -> IO [String]
checkDaemonLifecycleTestBoundaries repoRoot = do
  let path = repoRoot </> "test" </> "daemon-lifecycle" </> "Main.hs"
  fileExists <- doesFileExist path
  if not fileExists
    then pure []
    else do
      contents <- readFile path
      pure
        ( [ path
              ++ " must not use raw `threadDelay`; readiness waits must route through shared retry or hooks."
          | "threadDelay" `elem` tokenizeSource contents
          ]
            ++ [ path
                   ++ " must not call raw `terminateProcess`; tests must send the daemon's graceful shutdown signal first."
               | "terminateProcess" `elem` tokenizeSource contents
               ]
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
          let tokens = tokenizeSource (stripStringLiterals contents)
              hasSystemProcessImport = "import System.Process" `isInfixOf` contents
              forbiddenTokens =
                [ token
                | token <-
                    [ "callProcess"
                    , "readCreateProcess"
                    , "readCreateProcessWithExitCode"
                    , "createProcess"
                    , "proc"
                    , "shell"
                    ]
                , token `elem` tokens
                ]
          pure $
            [ relativePath ++ " must route subprocess creation through `src/Prodbox/Subprocess.hs`."
            | hasSystemProcessImport || not (null forbiddenTokens)
            ]
      )

stripStringLiterals :: String -> String
stripStringLiterals = go False False
 where
  go _ _ [] = []
  go inString escaped (character : remaining)
    | inString && escaped = ' ' : go True False remaining
    | inString && character == '\\' = ' ' : go True True remaining
    | inString && character == '"' = ' ' : go False False remaining
    | inString = ' ' : go True False remaining
    | character == '"' = ' ' : go True False remaining
    | otherwise = character : go False False remaining

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
      , path /= "src/Prodbox/Gateway/Logging.hs"
      , path /= "src/Prodbox/CheckCode.hs"
      ]
      ( \relativePath -> do
          contents <- readFile (repoRoot </> relativePath)
          let tokens = tokenizeSource contents
              directStderrWrites =
                [ "hPutStr stderr"
                , "hPutStrLn stderr"
                , "TextIO.hPutStrLn stderr"
                , "Text.IO.hPutStrLn stderr"
                ]
          pure $
            [ relativePath
                ++ " must route terminal output and error rendering through `src/Prodbox/CLI/Output.hs`."
            | any (`elem` tokens) ["print", "exitFailure", "putStr", "putStrLn"]
                || any (`isInfixOf` contents) directStderrWrites
            ]
      )

-- | Sprint 1.28: refuse `lookupEnv` / `getEnv` / `getEnvironment` reads on
-- supported config-loading paths, per
-- @documents/engineering/config_doctrine.md § 10. Forbidden surfaces@. The
-- Dhall file passed via `--config <path>` is the sole source for binary
-- configuration; no `PRODBOX_*` env-var precedence rule survives. Scope is
-- the modules called out in Phase 1 Sprint 1.28 deliverables plus
-- `src/Prodbox/Workload.hs`, whose `PRODBOX_*` env-var ladder was deleted in
-- Sprint 3.15, and `src/Prodbox/PublicEdge.hs` (Sprint 7.13), whose
-- `PRODBOX_AWS_SUBSTRATE_HOSTED_ZONE_ID` read was deleted and which now
-- fails this lint on any reintroduced config read.
checkEnvVarConfigReads :: FilePath -> IO [String]
checkEnvVarConfigReads repoRoot =
  concat
    <$> forM
      scopedPaths
      ( \relativePath -> do
          let fullPath = repoRoot </> relativePath
          fileExists <- doesFileExist fullPath
          if not fileExists
            then pure []
            else do
              contents <- readFile fullPath
              let tokens = tokenizeSource (stripStringLiterals contents)
                  forbiddenTokens =
                    [ token
                    | token <- ["lookupEnv", "getEnv", "getEnvironment"]
                    , token `elem` tokens
                    ]
              pure $
                [ relativePath
                    ++ " must not read configuration from environment variables. "
                    ++ "See `documents/engineering/config_doctrine.md` § 10."
                | not (null forbiddenTokens)
                ]
      )
 where
  scopedPaths =
    [ "src/Prodbox/Settings.hs"
    , "src/Prodbox/Gateway/Settings.hs"
    , "src/Prodbox/Gateway.hs"
    , "src/Prodbox/Workload.hs"
    , -- Sprint 7.13: the public-edge config / route-catalog module. Its
      -- AWS-substrate hosted-zone id is sourced from settings
      -- (@aws_substrate.hosted_zone_id@) and the live aws-eks-subzone
      -- Pulumi output, never from a @PRODBOX_AWS_SUBSTRATE_HOSTED_ZONE_ID@
      -- env read. Scoping it here keeps that env read from reappearing.
      "src/Prodbox/PublicEdge.hs"
    ]

-- | Sprint 3.16: confine the raw master-seed read to the in-cluster
-- gateway daemon. The raw 32-byte seed is the entropy source for every
-- data-bound secret; per @secret_derivation_doctrine.md §2/§5@ it must
-- never leave the cluster as plaintext, and the host consumes only
-- *derived* values over the gateway RPC. The seed is read in exactly one
-- module — 'Prodbox.Secret.MasterSeed' (@ensureMasterSeed@ against MinIO)
-- — and that reader may be imported only by the in-cluster daemon module
-- set. Any host-side command, validation flow, or chart helper that
-- imports the raw-seed reader (or calls @ensureMasterSeed@) re-exports the
-- boundary the way Sprint 3.13's tail did, so this lint refuses it.
--
-- Mirrors the 'checkEnvVarConfigReads' shape: scan every owned
-- @src/Prodbox/**.hs@ source, strip string literals (so a comment or a
-- diagnostic message that merely names the reader is allowed), tokenize,
-- and fail any out-of-scope file that references the forbidden tokens. The
-- allowed set is the in-cluster daemon path plus the reader's own
-- definition site.
checkRawMasterSeedReadScope :: FilePath -> IO [String]
checkRawMasterSeedReadScope repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  concat
    <$> forM
      [ path
      | path <- repoPaths
      , "src/Prodbox/" `isPrefixOf` path
      , ".hs" `isSuffixOf` path
      , path /= "src/Prodbox/CheckCode.hs"
      ]
      ( \relativePath -> do
          contents <- readFile (repoRoot </> relativePath)
          pure (rawMasterSeedReadScopeViolations relativePath contents)
      )

-- | The in-cluster daemon module set permitted to read the raw seed, plus
-- the reader's own definition site. 'Prodbox.Secret.EnsureNamespace' is
-- the in-cluster materializer; it takes a 'MasterSeed' value today but is
-- named here so it may import the reader without regressing the lint.
allowedRawSeedReaderPaths :: [FilePath]
allowedRawSeedReaderPaths =
  [ "src/Prodbox/Gateway/Daemon.hs"
  , "src/Prodbox/Secret/EnsureNamespace.hs"
  , "src/Prodbox/Secret/MasterSeed.hs"
  ]

-- | Sprint 3.16 (pure). Emit a violation when @relativePath@ — outside the
-- 'allowedRawSeedReaderPaths' in-cluster daemon set — references the
-- raw-seed reader: an @import ... Prodbox.Secret.MasterSeed@ line, or a
-- call to @ensureMasterSeed@. Line comments (@--@) and string literals are
-- stripped first so a Haddock comment or a diagnostic message that merely
-- names the reader is allowed (e.g. 'Prodbox.Secret.Derive' references the
-- module only in a comment). Pure so the unit suite can pin the
-- fires-on-offending-input contract.
rawMasterSeedReadScopeViolations :: FilePath -> String -> [String]
rawMasterSeedReadScopeViolations relativePath contents
  | relativePath `elem` allowedRawSeedReaderPaths = []
  | importsReader || callsReader =
      [ relativePath
          ++ " must not read the raw master seed. The raw-seed reader "
          ++ "(`Prodbox.Secret.MasterSeed` / `ensureMasterSeed`) is confined to "
          ++ "the in-cluster gateway daemon module set; host-side code consumes "
          ++ "*derived* values via `Prodbox.Gateway.Client`. See "
          ++ "`documents/engineering/secret_derivation_doctrine.md` § 2/§ 5."
      ]
  | otherwise = []
 where
  -- Strip string literals, then each line's `--` comment tail.
  codeLines = map dropLineComment (lines (stripStringLiterals contents))
  importsReader =
    any
      (\line -> "import" `elem` words line && "Prodbox.Secret.MasterSeed" `isInfixOf` line)
      codeLines
  callsReader = "ensureMasterSeed" `elem` tokenizeSource (unlines codeLines)
  dropLineComment line =
    case findInfixIndex "--" line of
      Just idx -> take idx line
      Nothing -> line

-- | First index at which @needle@ occurs in @haystack@, or 'Nothing'.
findInfixIndex :: String -> String -> Maybe Int
findInfixIndex needle haystack =
  go 0 (tails haystack)
 where
  go _ [] = Nothing
  go idx (candidate : rest)
    | needle `isPrefixOf` candidate = Just idx
    | otherwise = go (idx + 1) rest

-- | Sprint 7.12: substrate equivalence as a structural invariant. The home
-- substrate and the AWS substrate stand up the same SHARED platform
-- components (Envoy Gateway, cert-manager, Harbor, MinIO, the Percona
-- PostgreSQL operator); each such component's chart version and container
-- image must be pinned ONCE, in 'Prodbox.ContainerImage', and consumed by
-- both installers. Re-pinning a shared component's chart version / image on a
-- per-substrate branch (e.g. a literal @"v1.4.4"@ in the AWS installer that
-- can drift from the home installer's @"v1.7.2"@ — audit C79) is forbidden.
--
-- The genuinely substrate-specific LOWER layer is legitimately per-substrate
-- and is NOT flagged: the AWS Load Balancer Controller image / chart on AWS,
-- MetalLB + FRR on home, and the EKS node-local registry proxy
-- (containerd-mirror) all pin their own versions because there is no
-- home/AWS counterpart to keep in lockstep.
checkSubstrateImagePinning :: FilePath -> IO [String]
checkSubstrateImagePinning repoRoot =
  concat
    <$> forM
      substrateInstallerPaths
      ( \relativePath -> do
          let fullPath = repoRoot </> relativePath
          fileExists <- doesFileExist fullPath
          if not fileExists
            then pure []
            else do
              contents <- readFile fullPath
              pure (substrateImagePinningViolations relativePath contents)
      )

-- | The installer modules scanned by 'checkSubstrateImagePinning'. The
-- substrate-specific platform install paths plus the shared chart-platform
-- module — the only places a chart version / image pin could be re-bound on a
-- per-substrate branch.
substrateInstallerPaths :: [FilePath]
substrateInstallerPaths =
  [ "src/Prodbox/Lib/AwsSubstratePlatform.hs"
  , "src/Prodbox/CLI/Rke2.hs"
  , "src/Prodbox/Lib/ChartPlatform.hs"
  ]

-- | The SHARED platform components whose chart version / image must be pinned
-- once in 'Prodbox.ContainerImage'. Matched (case-insensitively) against a
-- binding's identifier; a binding whose name contains one of these tokens and
-- @ChartVersion@ (or an image tag) but whose right-hand side is a literal
-- version string rather than a @ContainerImage.@ reference is a violation.
sharedComponentNameTokens :: [String]
sharedComponentNameTokens =
  [ "envoygateway"
  , "envoyproxy"
  , "certmanager"
  , "harbor"
  , "minio"
  , "postgresoperator"
  , "percona"
  ]

-- | The LOWER-layer (legitimately per-substrate) component name tokens. A
-- binding whose identifier contains one of these is exempt even if it carries
-- a literal version — these have no cross-substrate counterpart to keep in
-- lockstep.
lowerLayerNameTokens :: [String]
lowerLayerNameTokens =
  [ "loadbalancercontroller"
  , "metallb"
  , "frr"
  , "containerd"
  , "mirror"
  ]

-- | Sprint 7.12 (pure). Emit a violation for each shared-component
-- chart-version / image binding in @contents@ whose right-hand side is a
-- literal version string instead of a 'Prodbox.ContainerImage' reference.
-- Pure so the unit suite can pin the fires-on-offending-input contract (a
-- reintroduced per-substrate Envoy pin) and the passes-on-current-tree
-- contract.
--
-- Detection is per definition line of the form @ident = rhs@: the binding is
-- in scope when its identifier contains a 'sharedComponentNameTokens' token,
-- @ChartVersion@ (or an image-tag pin), and NOT a 'lowerLayerNameTokens'
-- token; it is a violation when the right-hand side carries a version-like
-- string literal and does not reference @ContainerImage.@.
substrateImagePinningViolations :: FilePath -> String -> [String]
substrateImagePinningViolations relativePath contents =
  [ relativePath
      ++ ": shared platform component `"
      ++ bindingName
      ++ "` re-pins a chart version / image with the literal `"
      ++ offendingLiteral
      ++ "`. Source it from the single `Prodbox.ContainerImage` pin "
      ++ "(e.g. `ContainerImage.envoyGatewayChartVersion` / "
      ++ "`ContainerImage.certManagerChartVersion`) instead of re-pinning "
      ++ "per substrate. See `DEVELOPMENT_PLAN/substrates.md` (substrate "
      ++ "equivalence) and `documents/engineering/helm_chart_platform_doctrine.md`."
  | rawLine <- lines contents
  , let codeLine = dropLineCommentTail rawLine
  , Just (bindingName, rhs) <- [splitDefinitionLine codeLine]
  , isSharedComponentBinding bindingName
  , not ("ContainerImage." `isInfixOf` rhs)
  , offendingLiteral <- take 1 (filter looksLikeVersionLiteral (extractStringLiterals rhs))
  ]
 where
  dropLineCommentTail line =
    case findInfixIndex "--" line of
      Just idx -> take idx line
      Nothing -> line

-- | Split a top-level definition line @ident = rhs@ into its binding name and
-- right-hand side. Only fires on a binding whose name starts in column 0
-- (a top-level definition) so indented record fields / @where@ helpers are
-- not misread as bindings.
splitDefinitionLine :: String -> Maybe (String, String)
splitDefinitionLine line =
  case line of
    [] -> Nothing
    (c : _)
      | c == ' ' || c == '\t' -> Nothing
      | otherwise ->
          case break (== '=') line of
            (lhs, '=' : rhs) ->
              case words lhs of
                [identifier] -> Just (identifier, rhs)
                _ -> Nothing
            _ -> Nothing

-- | A binding identifier names a SHARED platform component's chart version or
-- image pin (and is not a lower-layer, legitimately per-substrate binding).
isSharedComponentBinding :: String -> Bool
isSharedComponentBinding identifier =
  any (`isInfixOf` lowered) sharedComponentNameTokens
    && ("chartversion" `isInfixOf` lowered || "image" `isInfixOf` lowered || "tag" `isInfixOf` lowered)
    && not (any (`isInfixOf` lowered) lowerLayerNameTokens)
 where
  lowered = map toLower identifier

-- | A string literal that looks like a pinned image / chart version: a
-- leading @v@ followed by a digit (@v1.7.2@), a leading digit (@5.4.0@,
-- @2.9.0@), or an Envoy-style @distroless-v...@ tag. Plain words ("jetstack",
-- "cert-manager") are not flagged.
looksLikeVersionLiteral :: String -> Bool
looksLikeVersionLiteral literal =
  case literal of
    ('v' : d : _) -> isDigit d
    (d : _) | isDigit d -> True
    _ -> "distroless-v" `isInfixOf` literal

-- | Sprint 1.30: refuse hand-built `ServiceError` values that pin a literal
-- `True` / `False` retryable Bool at a call site. Per
-- @documents/engineering/haskell_code_guide.md@ → "Target shape:
-- `ServiceError` classified by constructor", retryability is a total
-- function of the classified constructor, decided once at the single
-- subprocess boundary (`classifyServiceError` in
-- `src/Prodbox/Service.hs`), never asserted by the caller. The
-- post-Sprint-1.30 `ServiceError` sum no longer carries a `retryable`
-- field, so any `serviceErrorRetryable = True/False` field assignment or
-- positional `ServiceError <…> True/False` construction is by definition
-- a regression that re-introduces a hand-set retryable Bool.
--
-- The scan is intentionally narrow:
--
--   * Only Haskell `.hs` files under `src/` and `app/`.
--   * String literals are stripped (a comment or message that merely
--     mentions the pattern is allowed).
--   * `src/Prodbox/Service.hs` is excluded — it is the classifier
--     boundary that legitimately owns `ServiceError` construction.
--   * `src/Prodbox/CheckCode.hs` is excluded — its own diagnostic text
--     names the very tokens it scans for.
--   * `test/` is excluded so the unit tests can pin the lint's
--     fires-on-offending-input contract with synthetic offenders.
-- | Sprint 4.26: the destructive command-dispatch constructors that carry
-- a @PlanOptions@ / @NukeOptions@ argument, paired with the 1-based
-- argument position of that options field. A destructive arm that binds
-- this field to a @_@ wildcard silently drops @--dry-run@ / @--plan-file@
-- (the historical @rke2 delete --dry-run@ SILENTLY MUTATES bug, where
-- @Rke2Delete flags _planOptions@ discarded the options). Exposed for
-- unit tests; consumed by 'planOptionsHonoredViolations'.
--
-- @Rke2Delete@ is @Rke2Delete Rke2DeleteFlags PlanOptions@ → the options
-- field is the 2nd argument. @NativeNuke@ is @NativeNuke NukeOptions@ →
-- 1st argument. Both must be threaded into 'runPlanWithOptions' (or read,
-- for @NukeOptions@), never wildcarded away.
destructivePlanOptionsArms :: [(String, Int)]
destructivePlanOptionsArms =
  [ ("Rke2Delete", 2)
  , ("NativeNuke", 1)
  ]

-- | Sprint 4.26 (pure): given a scanned file's relative path and its
-- contents, emit a violation for any destructive dispatch arm
-- ('destructivePlanOptionsArms') that binds its @PlanOptions@ /
-- @NukeOptions@ field to a @_@-prefixed wildcard, so a future destructive
-- command cannot silently drop @--dry-run@ / @--plan-file@.
--
-- Detection is tokenization-based: the arm appears in the source as the
-- constructor token followed by its binder tokens (e.g.
-- @Rke2Delete flags _planOptions@ tokenizes to
-- @["Rke2Delete", "flags", "_planOptions"]@). A wildcard binder is a token
-- that is exactly @_@ or begins with @_@. The check fires when the binder
-- at the constructor's options-argument position is such a wildcard. The
-- lint's own occurrences are excluded by the path filter in
-- 'checkPlanOptionsHonored'.
planOptionsHonoredViolations :: FilePath -> String -> [String]
planOptionsHonoredViolations relativePath contents =
  [ relativePath
      ++ " destructive dispatch arm `"
      ++ constructorName
      ++ "` binds its PlanOptions/NukeOptions field to a `_` wildcard ("
      ++ wildcardBinder
      ++ "), silently dropping --dry-run / --plan-file. Thread the options "
      ++ "into runPlanWithOptions (or read NukeOptions) instead. See "
      ++ "lifecycle_reconciliation_doctrine.md § 3.1."
  | (constructorName, optionsPosition) <- destructivePlanOptionsArms
  , wildcardBinder <- wildcardBindersAt constructorName optionsPosition
  ]
 where
  tokens = tokenizeSource (stripStringLiterals contents)
  -- For each occurrence of @constructorName@ in the token stream, the
  -- binder at @optionsPosition@ (1-based, relative to the constructor)
  -- is @drop optionsPosition@ of the tail starting at the constructor.
  wildcardBindersAt constructorName optionsPosition =
    [ binder
    | suffix <- tails tokens
    , (constructorToken : argTokens) <- [suffix]
    , constructorToken == constructorName
    , binder <- take 1 (drop (optionsPosition - 1) argTokens)
    , isWildcardBinder binder
    ]
  isWildcardBinder binder = case binder of
    "" -> False
    ('_' : _) -> True
    _ -> False

-- | Sprint 4.26: scan the destructive command-dispatch modules and fail
-- when a destructive arm wildcards its @PlanOptions@ / @NukeOptions@ field
-- (per 'planOptionsHonoredViolations'). The scope is the dispatch modules
-- that pattern-match the destructive constructors; @CheckCode.hs@ is
-- excluded so its own constructor-name literals do not self-trigger.
checkPlanOptionsHonored :: FilePath -> IO [String]
checkPlanOptionsHonored repoRoot =
  concat
    <$> forM
      scopedPaths
      ( \relativePath -> do
          let fullPath = repoRoot </> relativePath
          fileExists <- doesFileExist fullPath
          if not fileExists
            then pure []
            else do
              contents <- readFile fullPath
              pure (planOptionsHonoredViolations relativePath contents)
      )
 where
  scopedPaths =
    [ "src/Prodbox/CLI/Rke2.hs"
    , "src/Prodbox/CLI/Nuke.hs"
    , "src/Prodbox/Native.hs"
    ]

checkServiceErrorRetryableLiteral :: FilePath -> IO [String]
checkServiceErrorRetryableLiteral repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  let scanPath path =
        (".hs" `isSuffixOf` path)
          && any (`isPrefixOf` path) ["src/", "app/"]
          && path /= "src/Prodbox/Service.hs"
          && path /= forbidLintSelfPath
  fmap concat $
    forM
      [path | path <- repoPaths, scanPath path]
      ( \relativePath -> do
          let absolutePath = repoRoot </> relativePath
          isFile <- doesFileExist absolutePath
          if not isFile
            then pure []
            else do
              contents <- readFile absolutePath
              pure (serviceErrorRetryableLiteralViolations relativePath contents)
      )

-- | Pure half of 'checkServiceErrorRetryableLiteral'. Detect a hand-set
-- retryable Bool on a `ServiceError`: either the record-field form
-- (`serviceErrorRetryable` token immediately followed by a `True`/`False`
-- literal) or the positional form (`ServiceError` token followed by a
-- bare `True`/`False` literal within a short token window, after string
-- literals are stripped). Exposed for unit tests.
serviceErrorRetryableLiteralViolations :: FilePath -> String -> [String]
serviceErrorRetryableLiteralViolations relativePath contents =
  [ relativePath
      ++ " constructs a `ServiceError` with a literal retryable Bool; "
      ++ "retryability is derived from the classified constructor at the "
      ++ "single subprocess boundary (`classifyServiceError`), never pinned "
      ++ "by a caller (haskell_code_guide.md → ServiceError classification)."
  | serviceErrorRetryableLiteralPresent (tokenizeSource (stripStringLiterals contents))
  ]

-- | True when the token stream pins a literal retryable Bool onto a
-- `ServiceError`. After 'tokenizeSource' collapses `=` to whitespace, the
-- record-field form `serviceErrorRetryable = True` becomes the adjacent
-- pair @["serviceErrorRetryable", "True"]@, and the positional form
-- `ServiceError "msg" True` (string literal stripped) becomes
-- @["ServiceError", "True"]@.
serviceErrorRetryableLiteralPresent :: [String] -> Bool
serviceErrorRetryableLiteralPresent tokens =
  fieldFormPresent || positionalFormPresent
 where
  boolLiteral token = token == "True" || token == "False"
  fieldFormPresent =
    any
      (\(token, next) -> token == "serviceErrorRetryable" && boolLiteral next)
      (zip tokens (drop 1 tokens))
  -- The positional ServiceError <…> True/False form: a `ServiceError`
  -- token with a bare Bool literal within the next few tokens and no
  -- intervening constructor that would re-open a fresh value.
  positionalFormPresent = go tokens
  go [] = False
  go ("ServiceError" : rest) = boolWithinWindow (take serviceErrorWindow rest) || go rest
  go (_ : rest) = go rest
  boolWithinWindow window =
    any boolLiteral (takeWhile (not . opensNestedValue) window)
  opensNestedValue token =
    token `elem` ["ServiceError", "MinIOError", "RedisError", "PgError"]

serviceErrorWindow :: Int
serviceErrorWindow = 4

-- | Sprint 4.22 follow-on: the create-call-site coverage scan that
-- enforces the managed-resource registry totality invariant
-- (@documents/engineering/lifecycle_reconciliation_doctrine.md § 3.1@,
-- invariant 1: "No prodbox code path may create an AWS or cluster
-- resource that is not in the registry"). Registry ↔ doc parity is
-- already machine-enforced via the @resource-lifecycle-classes@
-- generated section; this scan covers the *other* half — the create
-- call sites themselves — across the two deliberately narrow surfaces
-- where prodbox actually originates new AWS/cluster resources:
--
--   1. Pulumi stack creation: the @Pulumi<Word>Resources@ constructors
--      of the @PulumiCommand@ ADT in @src/Prodbox/CLI/Command.hs@. Each
--      must map (via 'pulumiCreateSiteOwners') to a registered stack
--      name.
--   2. Operational IAM user creation: the AWS CLI verbs in
--      'iamCreateVerbs', which may appear only in the
--      @operational-iam-user@ owner module @src/Prodbox/Aws.hs@.
--
-- Broader generic-@create*@ / @change-resource-record-sets@ /
-- @create-bucket@ / @mc mb@ scanning is *deliberately out of scope*:
-- those resources are Pulumi-managed (covered transitively by the
-- stack scan) or specially-handled bootstrap operations, and scanning
-- them by raw substring would false-positive on legitimate code. The
-- scan stays narrow on purpose.
-- | Sprint 4.18: refuse new @`.prodbox-state/`@ string literals anywhere
-- in the production Haskell source tree (@src/@ + @app/@). Sprint 3.13
-- chunks 8–16 erased every supported path that writes to the
-- @.prodbox-state/@ host-side directory:
--
--   * chunks 8–14 — chart-secret cache (@.prodbox-state/<ns>/.secrets.json@):
--     data-bound chart secrets now flow through k8s @Secret@s materialized
--     by the gateway daemon's @ensure-namespace@ handler; chart templates
--     read them via Helm @lookup@.
--   * chunk 16 — gateway per-node event-key cache
--     (@.prodbox-state/<ns>/.gateway-event-keys.json@): gateway event keys
--     derive from the master seed and the daemon self-bootstraps its own
--     @gateway-event-keys@ Secret at startup; the chart reads them via
--     Helm @lookup@.
--
-- With both caches gone, any new @`.prodbox-state/`@ literal in
-- production source is by definition a regression of the closed cache
-- surface.
--
-- The scan is intentionally narrow:
--
--   * Only Haskell @.hs@ files under @src/@ and @app/@.
--   * Only string literals (via 'extractStringLiterals') — comments and
--     docstrings that *mention* @`.prodbox-state/`@ for historical
--     context are allowed.
--   * @test/@ is excluded so the unit tests can pin the lint's
--     fires-on-offending-literal contract with synthetic offenders.
--   * The lint module itself is excluded — its own pattern string and
--     diagnostic text contain the very substring it scans for.
checkForbidDotProdboxState :: FilePath -> IO [String]
checkForbidDotProdboxState repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  let
    -- The needle pattern is built at runtime so this lint module's own
    -- string literals (its scan pattern + diagnostic text) don't
    -- accidentally trip the scan when it sweeps over @src/@.
    needle = "." ++ "prodbox-state" ++ "/"
    -- Production-only scope: only @src/@ and @app/@ Haskell files. Test
    -- modules legitimately mention the closed cache prefix for
    -- regression coverage (see the Sprint 4.18 unit tests in
    -- @test/unit/Main.hs@), so excluding @test/@ here keeps the lint
    -- narrowly focused on production regressions. The lint module
    -- itself is also excluded — its own pattern string and diagnostic
    -- text contain the very substring it scans for.
    scanPath path =
      (".hs" `isSuffixOf` path)
        && any (`isPrefixOf` path) ["src/", "app/"]
        && path /= forbidLintSelfPath
  fmap concat $
    forM
      [path | path <- repoPaths, scanPath path]
      ( \relativePath -> do
          let absolutePath = repoRoot </> relativePath
          isFile <- doesFileExist absolutePath
          if not isFile
            then pure []
            else do
              contents <- readFile absolutePath
              let offenders =
                    filter (needle `isInfixOf`) (extractStringLiterals contents)
              pure
                [ relativePath
                    ++ " string literal contains the closed prodbox-state "
                    ++ "prefix (Sprint 3.13 chunks 8\8211\&16 eradicated "
                    ++ "every host-side cache under it; any new reference "
                    ++ "is a regression): "
                    ++ shortenSprintLeak offender
                | offender <- offenders
                ]
      )

-- | The self-exclusion path for 'checkForbidDotProdboxState'. The lint
-- module's own pattern string and diagnostic text contain the very
-- substring it scans for, so this module is allowlisted by relative
-- path.
forbidLintSelfPath :: FilePath
forbidLintSelfPath = "src/Prodbox/CheckCode.hs"

-- | Sprint 0.9: the set of repo-relative governed-documentation paths
-- subject to the documentation-harmony reconciler and the relative-link
-- check. "Governed docs" are every @*.md@ under @documents/@ and
-- @DEVELOPMENT_PLAN/@ plus the repo-root ALL-CAPS exceptions
-- (@README.md@, @CLAUDE.md@, @AGENTS.md@) named by
-- @documents/documentation_standards.md § 2@.
isGovernedDocPath :: FilePath -> Bool
isGovernedDocPath path =
  (".md" `isSuffixOf` path)
    && ( any (`isPrefixOf` path) ["documents/", "DEVELOPMENT_PLAN/"]
           || path `elem` ["README.md", "CLAUDE.md", "AGENTS.md"]
       )

-- | Drop every line that lives inside a fenced code block (a region
-- opened and closed by a line whose first non-whitespace content is a
-- triple-backtick fence). The fence lines themselves are dropped too.
-- Used to strip the EXAMPLE prodbox markers that
-- @documents/documentation_standards.md@ carries inside a @```markdown@
-- block (which legitimately declares @none@), so the marker scan does
-- not false-positive on teaching examples. Exposed for unit tests.
stripFencedCodeBlocks :: [String] -> [String]
stripFencedCodeBlocks = go False
 where
  go _ [] = []
  go inFence (lineText : remaining)
    | isFenceLine lineText = go (not inFence) remaining
    | inFence = go inFence remaining
    | otherwise = lineText : go inFence remaining
  isFenceLine lineText = "```" `isPrefixOf` trimLeft lineText

-- | Blank out backtick-delimited inline-code spans within a single line,
-- replacing each span (and its delimiting backticks) with spaces. Used so
-- that markers and links quoted inline for documentation purposes — e.g.
-- ``the `<!-- prodbox:<key>:start -->` marker`` or ``the
-- `[text](path#anchor)` form`` — are not treated as real markers or
-- links. Unterminated spans (a lone backtick) blank out the remainder of
-- the line, which is the conservative choice. Exposed for unit tests.
stripInlineCodeSpans :: String -> String
stripInlineCodeSpans = goOutside
 where
  goOutside [] = []
  goOutside ('`' : rest) = ' ' : goInside rest
  goOutside (character : rest) = character : goOutside rest

  goInside [] = []
  goInside ('`' : rest) = ' ' : goOutside rest
  goInside (_ : rest) = ' ' : goInside rest

-- | The set of prodbox generated-section marker keys PHYSICALLY present
-- in a governed document, scanning only content OUTSIDE fenced code
-- blocks and OUTSIDE inline-code spans. A key counts as present when a
-- start or end marker for it appears in the cleaned content, in any of
-- the host-syntax forms enumerated by
-- @documents/documentation_standards.md § 11@ (Markdown @<!-- ... -->@,
-- Helm/Go templates @{{\/* ... *\/}}@, YAML @# ...@, and the
-- Haskell/PureScript/TypeScript @-- ...@ comment form). Returns the keys
-- sorted and de-duplicated. Exposed for unit tests.
prodboxMarkerKeysPresent :: String -> [String]
prodboxMarkerKeysPresent contents =
  dedupeSorted
    [ key
    | cleanedLine <- map stripInlineCodeSpans (stripFencedCodeBlocks (lines contents))
    , key <- markerKeysInLine cleanedLine
    ]

-- | Extract every prodbox marker key declared on a single (already
-- code-stripped) line. A line may carry more than one marker (the
-- documentation-standards table puts start+end markers on one row, though
-- those rows are inline-code and thus blanked before this runs).
markerKeysInLine :: String -> [String]
markerKeysInLine cleanedLine =
  [ key
  | (openToken, closeTokens) <- markerSyntaxes
  , key <- markerKeysForSyntax openToken closeTokens cleanedLine
  ]

-- | The open/close delimiter forms for each host syntax. The body between
-- the @prodbox:@ prefix and the @:start@/@:end@ suffix is the key.
markerSyntaxes :: [(String, [String])]
markerSyntaxes =
  [ ("<!-- prodbox:", ["-->"])
  , ("{{/* prodbox:", ["*/}}"])
  , ("# prodbox:", [""])
  , ("-- prodbox:", [""])
  , ("// prodbox:", [""])
  ]

-- | Given one open delimiter, the acceptable close delimiters, and a
-- cleaned line, return the marker keys for every well-formed marker the
-- line carries. A marker body has the shape @<key>:start@ or @<key>:end@;
-- the key is everything before the final @:start@ / @:end@ suffix.
markerKeysForSyntax :: String -> [String] -> String -> [String]
markerKeysForSyntax openToken closeTokens cleanedLine =
  [ key
  | afterOpen <- segmentsAfter openToken cleanedLine
  , body <- bodyBeforeClose afterOpen
  , key <- keyFromBody body
  ]
 where
  bodyBeforeClose afterOpen =
    case closeTokens of
      [""] -> [trimLine (takeWhile (/= ' ') (trimLeft afterOpen))]
      _ -> [trimLine (takeBeforeAny closeTokens afterOpen) | endsWithAny closeTokens afterOpen]

-- | Split a string into the suffixes that follow each (non-overlapping)
-- occurrence of @needle@. Total; returns @[]@ when @needle@ is absent.
segmentsAfter :: String -> String -> [String]
segmentsAfter needle = go
 where
  go haystack =
    case stripFirstInfix needle haystack of
      Nothing -> []
      Just rest -> rest : go rest

-- | The portion of @haystack@ after the first occurrence of @needle@, if
-- present.
stripFirstInfix :: String -> String -> Maybe String
stripFirstInfix needle haystack =
  case haystack of
    [] -> Nothing
    (_ : rest) ->
      case stripExactPrefix needle haystack of
        Just suffix -> Just suffix
        Nothing -> stripFirstInfix needle rest

-- | Total prefix strip: @Just suffix@ when @needle@ is a prefix of the
-- string, otherwise @Nothing@.
stripExactPrefix :: String -> String -> Maybe String
stripExactPrefix [] suffix = Just suffix
stripExactPrefix _ [] = Nothing
stripExactPrefix (n : ns) (c : cs)
  | n == c = stripExactPrefix ns cs
  | otherwise = Nothing

-- | The portion of @haystack@ before the first occurrence of any token in
-- @tokens@. Total; returns the whole string when no token matches.
takeBeforeAny :: [String] -> String -> String
takeBeforeAny tokens = go
 where
  go [] = []
  go haystack@(c : cs)
    | any (`isPrefixOfString` haystack) tokens = []
    | otherwise = c : go cs
  isPrefixOfString token str =
    case stripExactPrefix token str of
      Just _ -> True
      Nothing -> False

-- | Does the string contain any of the close tokens?
endsWithAny :: [String] -> String -> Bool
endsWithAny tokens str = any (`isInfixOf` str) tokens

-- | Parse a marker body of the form @<key>:start@ or @<key>:end@ into its
-- key. Returns @[]@ when the body does not end in a recognized suffix, or
-- when the key would be empty or the placeholder @<key>@ token (the
-- documentation table uses a literal @<key>@ placeholder).
keyFromBody :: String -> [String]
keyFromBody body =
  [ key
  | suffix <- [":start", ":end"]
  , suffix `isSuffixOf` body
  , let key = take (length body - length suffix) body
  , not (null key)
  , key /= "<key>"
  ]

-- | Sprint 0.9 (pure). The @**Generated sections**@ header ↔ markers ↔
-- registry reconciler decision for ONE governed document. Inputs:
--
--   * @path@ — the document's repo-relative path (for diagnostics);
--   * @declaredKeys@ — the keys parsed from the document's
--     @**Generated sections**:@ metadata field (empty for @none@);
--   * @markerKeys@ — the marker keys physically present in the file
--     (outside fences / inline code), from 'prodboxMarkerKeysPresent';
--   * @registryKeysForFile@ — the registry keys that target this file;
--   * @allRegistryKeys@ — every key in the @GeneratedSectionRule@
--     registry (across all files).
--
-- Three leg agreement is enforced (documentation_standards.md § 3 / § 11):
--
--   1. Every registry key for this file must be declared in metadata AND
--      have its markers physically present.
--   2. Every declared (non-@none@) key must be registered (in
--      @allRegistryKeys@).
--   3. Every marker key physically present must be declared in metadata.
generatedSectionsReconcilerViolations
  :: FilePath -> [String] -> [String] -> [String] -> [String] -> [String]
generatedSectionsReconcilerViolations
  path
  declaredKeys
  markerKeys
  registryKeysForFile
  allRegistryKeys =
    registryUndeclaredViolations
      ++ registryMissingMarkerViolations
      ++ declaredUnregisteredViolations
      ++ markerUndeclaredViolations
   where
    registryUndeclaredViolations =
      [ path
          ++ " is registered for generated-section key `"
          ++ key
          ++ "` but does not declare it in its `**Generated sections**:` "
          ++ "metadata field (documentation_standards.md § 3)."
      | key <- registryKeysForFile
      , key `notElem` declaredKeys
      ]
    registryMissingMarkerViolations =
      [ path
          ++ " is registered for generated-section key `"
          ++ key
          ++ "` but its `prodbox:"
          ++ key
          ++ ":start`/`:end` markers are not present in the file "
          ++ "(documentation_standards.md § 11)."
      | key <- registryKeysForFile
      , key `notElem` markerKeys
      ]
    declaredUnregisteredViolations =
      [ path
          ++ " declares generated-section key `"
          ++ key
          ++ "` in its `**Generated sections**:` metadata field, but no "
          ++ "`GeneratedSectionRule` registers it (documentation_standards.md § 11)."
      | key <- declaredKeys
      , key `notElem` allRegistryKeys
      ]
    markerUndeclaredViolations =
      [ path
          ++ " carries `prodbox:"
          ++ key
          ++ ":start`/`:end` markers but does not declare `"
          ++ key
          ++ "` in its `**Generated sections**:` metadata field "
          ++ "(documentation_standards.md § 3)."
      | key <- markerKeys
      , key `notElem` declaredKeys
      ]

-- | Sprint 0.9 (pure). Parse the value of a governed document's
-- @**Generated sections**:@ metadata field from its full contents into
-- the declared key list. Returns @Nothing@ when no metadata line is
-- present (a separate violation surface), @Just []@ for @none@, and
-- @Just keys@ otherwise.
--
-- The value is tolerant of documentation prose: it reads only the first
-- comma-separated list of tokens, stops at the first parenthesis (some
-- docs annotate @none (… scheduled …)@), strips surrounding backticks
-- (some docs quote keys as @`command-registry.markdown`@), and treats a
-- bare @none@ token as the empty declared set. Exposed for unit tests.
parseGeneratedSectionsField :: String -> Maybe [String]
parseGeneratedSectionsField contents =
  case metadataValues of
    [] -> Nothing
    (value : _) -> Just (parseValue value)
 where
  fieldPrefix = "**Generated sections**:"
  metadataValues =
    [ trimLine (drop (length fieldPrefix) lineText)
    | lineText <- lines contents
    , fieldPrefix `isPrefixOf` lineText
    ]
  parseValue rawValue =
    let beforeParen = takeWhile (/= '(') rawValue
        tokens =
          [ token
          | rawToken <- splitOnComma beforeParen
          , let token = stripBackticks (trimLine rawToken)
          , not (null token)
          ]
     in case tokens of
          ["none"] -> []
          _ -> filter (/= "none") tokens
  stripBackticks = filter (/= '`')

-- | Split a string on commas. Total.
splitOnComma :: String -> [String]
splitOnComma value =
  case break (== ',') value of
    (before, []) -> [before]
    (before, _ : after) -> before : splitOnComma after

-- | Sprint 0.9 (pure). Every markdown link TARGET @target@ from an
-- inline link of the form @[text](target)@ found in the supplied
-- governed-document contents, scanning only content OUTSIDE fenced code
-- blocks and OUTSIDE inline-code spans (so example links quoted for
-- documentation purposes — e.g. ``the `[text](path#anchor)` form`` — are
-- not surfaced). Reference-style links and autolinks are out of scope.
-- Exposed for unit tests.
extractMarkdownLinkTargets :: String -> [String]
extractMarkdownLinkTargets contents =
  concatMap
    (linkTargetsInLine . stripInlineCodeSpans)
    (stripFencedCodeBlocks (lines contents))

-- | The link targets on one already-code-stripped line. A target is the
-- text between @](@ and the matching @)@.
linkTargetsInLine :: String -> [String]
linkTargetsInLine = go
 where
  go lineText =
    case stripFirstInfix "](" lineText of
      Nothing -> []
      Just afterOpen ->
        let target = takeWhile (/= ')') afterOpen
            rest = drop (length target) afterOpen
         in target : go rest

-- | Sprint 0.9 (pure). Is a markdown link target a RELATIVE in-repo path
-- worth resolving? Skips absolute URLs (@http://@, @https://@,
-- @mailto:@), pure-anchor links (@#section@), protocol-relative URLs
-- (@//host@), and empty targets. Exposed for unit tests.
isRelativeLinkTarget :: String -> Bool
isRelativeLinkTarget target =
  let trimmed = trimLine target
   in not (null trimmed)
        && not (any (`isPrefixOf` trimmed) ["http://", "https://", "mailto:", "#", "//"])

-- | Sprint 0.9 (pure). Resolve a relative link target against the
-- directory of the document that contains it, returning the repo-relative
-- target path to test for existence. The trailing @#anchor@ (if any) is
-- stripped before resolution. Returns @Nothing@ when the target is not a
-- relative in-repo path (per 'isRelativeLinkTarget') or when, after
-- stripping the anchor, only an anchor remained. Exposed for unit tests.
relativeLinkResolves :: FilePath -> String -> Maybe FilePath
relativeLinkResolves docPath target
  | not (isRelativeLinkTarget target) = Nothing
  | null pathPart = Nothing
  | otherwise = Just (collapseRelativePath (takeDirectory docPath </> pathPart))
 where
  pathPart = takeWhile (/= '#') (trimLine target)

-- | Syntactically collapse @.@ and @..@ segments of a relative path into a
-- canonical repo-relative form. @System.FilePath.normalise@ deliberately
-- keeps @..@ segments, so this folds them: a @..@ pops the previous
-- ordinary segment, or is preserved verbatim when there is nothing to pop
-- (the path escapes its base — a genuine broken-link signal). Total; no
-- partial functions.
collapseRelativePath :: FilePath -> FilePath
collapseRelativePath path =
  -- The accumulator is kept REVERSED (most-recent segment at the head) so
  -- a @..@ pops the immediately-preceding segment in O(1); it is reversed
  -- back to forward order before joining.
  case reverse (foldl step [] (splitDirectories (normalise path))) of
    [] -> "."
    collapsed -> joinSegments collapsed
 where
  step reversedAcc segment =
    case segment of
      "." -> reversedAcc
      ".." ->
        case reversedAcc of
          (previous : rest)
            | previous /= ".." -> rest
          _ -> ".." : reversedAcc
      _ -> segment : reversedAcc
  joinSegments segments =
    case segments of
      [] -> "."
      (first : rest) -> foldl (</>) first rest

-- | Sprint 0.9 (IO wrapper). The @**Generated sections**@ header ↔
-- markers ↔ registry reconciler over every governed document, mirroring
-- the @checkEnvVarConfigReads@ pattern: a thin IO shell over the pure
-- 'generatedSectionsReconcilerViolations' decision and
-- 'prodboxMarkerKeysPresent' / 'parseGeneratedSectionsField' parsers.
checkGeneratedSectionsHarmony :: FilePath -> IO [String]
checkGeneratedSectionsHarmony repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  let governedPaths = [path | path <- repoPaths, isGovernedDocPath path]
      allRegistryKeys = dedupeSorted (map generatedSectionKey generatedSectionRules)
      registryKeysForFile path =
        dedupeSorted
          [ generatedSectionKey rule
          | rule <- generatedSectionRules
          , normalise (generatedSectionPath rule) == normalise path
          ]
  fmap concat $
    forM governedPaths $ \relativePath -> do
      contents <- readFile (repoRoot </> relativePath)
      let markerKeys = prodboxMarkerKeysPresent contents
          forFile = registryKeysForFile relativePath
      pure $
        case parseGeneratedSectionsField contents of
          Nothing ->
            [ relativePath
                ++ " is missing the mandatory `**Generated sections**:` "
                ++ "metadata field (documentation_standards.md § 3)."
            ]
          Just declaredKeys ->
            generatedSectionsReconcilerViolations
              relativePath
              declaredKeys
              markerKeys
              forFile
              allRegistryKeys

-- | Sprint 0.9 (IO wrapper). The relative-link check over every governed
-- document: extract inline link targets (outside fences / inline code),
-- resolve each relative target against the document's directory, and
-- report any that do not resolve to an existing on-disk file. Mirrors the
-- @checkEnvVarConfigReads@ pattern.
checkGovernedDocRelativeLinks :: FilePath -> IO [String]
checkGovernedDocRelativeLinks repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  let governedPaths = [path | path <- repoPaths, isGovernedDocPath path]
  fmap concat $
    forM governedPaths $ \relativePath -> do
      contents <- readFile (repoRoot </> relativePath)
      let resolvedTargets =
            [ (target, resolved)
            | target <- extractMarkdownLinkTargets contents
            , Just resolved <- [relativeLinkResolves relativePath target]
            ]
      fmap concat $
        forM resolvedTargets $ \(target, resolved) -> do
          targetExists <- doesFileExist (repoRoot </> resolved)
          dirExists <- doesDirectoryExist (repoRoot </> resolved)
          pure
            [ relativePath
                ++ " has a broken relative link `"
                ++ target
                ++ "`; resolved target `"
                ++ resolved
                ++ "` does not exist (documentation_standards.md § 4)."
            | not targetExists && not dirExists
            ]

checkCreateCallSiteCoverage :: FilePath -> IO [String]
checkCreateCallSiteCoverage repoRoot = do
  let registeredNames =
        resourceNamesOfClass PerRun ++ resourceNamesOfClass LongLived
  commandContents <- readFile (repoRoot </> "src" </> "Prodbox" </> "CLI" </> "Command.hs")
  let pulumiViolations = pulumiCreateSiteViolations registeredNames commandContents
  repoPaths <- listRepoOwnedPaths repoRoot
  awsViolations <-
    concat
      <$> forM
        [ path
        | path <- repoPaths
        , "src/Prodbox/" `isPrefixOf` path
        , ".hs" `isSuffixOf` path
        , path /= "src/Prodbox/CheckCode.hs"
        ]
        ( \relativePath -> do
            contents <- readFile (repoRoot </> relativePath)
            pure (awsCreateSiteViolations relativePath contents)
        )
  pure (pulumiViolations ++ awsViolations)

-- | The explicit map from a Pulumi stack-creation constructor name to
-- the registered stack name it provisions. Every entry's value must be
-- present in 'resourceLifecycleClasses' (enforced by
-- 'pulumiCreateSiteViolations'). Adding a new @Pulumi<Word>Resources@
-- constructor without a matching entry here fails the lint. Exposed for
-- unit tests; consumed by 'pulumiCreateSiteViolations'.
pulumiCreateSiteOwners :: [(String, String)]
pulumiCreateSiteOwners =
  [ ("PulumiEksResources", "aws-eks")
  , ("PulumiTestResources", "aws-test")
  , ("PulumiAwsSubzoneResources", "aws-eks-subzone")
  , ("PulumiAwsSesResources", "aws-ses")
  ]

-- | Sprint 4.22 follow-on (pure). Given the registered resource names
-- (from the registry) and the contents of @CLI/Command.hs@, emit a
-- violation for any Pulumi stack-creation constructor that is not
-- covered by the registry.
--
-- A stack-creation site is any token of the shape @Pulumi<Word>Resources@
-- (starts with @"Pulumi"@, ends with @"Resources"@). Two failure modes:
--
--   * a creation constructor with no entry in 'pulumiCreateSiteOwners'
--     (an unregistered create site), and
--   * a mapped constructor whose stack name is absent from the supplied
--     registered names (the registry lost the entry).
pulumiCreateSiteViolations :: [String] -> String -> [String]
pulumiCreateSiteViolations registeredNames commandContents =
  unregisteredConstructorViolations ++ missingRegistryViolations
 where
  creationConstructors =
    dedupeSorted
      [ token
      | token <- tokenizeSource commandContents
      , "Pulumi" `isPrefixOf` token
      , "Resources" `isSuffixOf` token
      ]
  unregisteredConstructorViolations =
    [ constructorName
        ++ " is a Pulumi stack-creation site with no registered managed resource; "
        ++ "add its stack to resourceLifecycleClasses and pulumiCreateSiteOwners "
        ++ "(lifecycle_reconciliation_doctrine.md §3.1 totality)."
    | constructorName <- creationConstructors
    , constructorName `notElem` map fst pulumiCreateSiteOwners
    ]
  missingRegistryViolations =
    [ constructorName
        ++ " maps to Pulumi stack `"
        ++ stackName
        ++ "`, which is not in the managed-resource registry; add `"
        ++ stackName
        ++ "` to resourceLifecycleClasses (lifecycle_reconciliation_doctrine.md §3.1 totality)."
    | (constructorName, stackName) <- pulumiCreateSiteOwners
    , constructorName `elem` creationConstructors
    , stackName `notElem` registeredNames
    ]

-- | Sprint 4.27: the AWS-resource creation verbs the create-site lint
-- covers, each paired with the owner module(s) where the create call
-- site is sanctioned (because the created resource is a registered
-- managed resource). Generalizes the Sprint 4.22 IAM-only
-- @iamCreateVerbs@ to every AWS-resource create call site:
--
--   * @create-user@ \/ @create-access-key@ \/ @put-user-policy@ — the
--     @operational-iam-user@ owner module @src/Prodbox/Aws.hs@.
--   * @create-bucket@ — the long-lived @pulumi_state_backend@ bucket
--     owner @src/Prodbox/Infra/LongLivedPulumiBackend.hs@ and the
--     in-cluster MinIO backend bucket owner
--     @src/Prodbox/Infra/MinioBackend.hs@.
--
-- @create-hosted-zone@ is deliberately NOT in this list — see
-- 'awsCreateProbeVerbs'. The verbs are matched as raw substrings because
-- they are subprocess string-literal arguments (e.g. @aws iam
-- create-user@). Exposed for unit tests; consumed by
-- 'awsCreateSiteViolations'.
awsCreateVerbs :: [(String, [FilePath])]
awsCreateVerbs =
  [ ("create-user", ["src/Prodbox/Aws.hs"])
  , ("create-access-key", ["src/Prodbox/Aws.hs"])
  , ("put-user-policy", ["src/Prodbox/Aws.hs"])
  ,
    ( "create-bucket"
    ,
      [ "src/Prodbox/Infra/LongLivedPulumiBackend.hs"
      , "src/Prodbox/Infra/MinioBackend.hs"
      ]
    )
  ]

-- | Sprint 4.27: AWS-resource creation verbs that are deliberately
-- carved out of the create-site coverage lint because they are
-- transient capability\/validation probes with NO steady state to
-- discover or reconcile — the throwaway record is created and
-- immediately deleted in the same flow, so it is correctly NOT a
-- registered 'ManagedResource' (per
-- @lifecycle_reconciliation_doctrine.md § 3.1@). @create-hosted-zone@
-- is the Route 53 lifecycle capability proof in
-- @src/Prodbox/EffectInterpreter.hs::requireRoute53LifecycleCapability@
-- (wrapped in @bracketOnError@ so the proof zone is always deleted, even
-- on a mid-probe failure) and the @public-dns@ validation's throwaway
-- zone in @src/Prodbox/TestValidation.hs@. Exposed for unit tests;
-- consumed by 'awsCreateSiteViolations'.
awsCreateProbeVerbs :: [String]
awsCreateProbeVerbs = ["create-hosted-zone"]

-- | The operational-IAM creation verbs. Retained for unit-test
-- back-compatibility; the IAM verbs are the @src/Prodbox/Aws.hs@-owned
-- entries of 'awsCreateVerbs'. Exposed for unit tests.
iamCreateVerbs :: [String]
iamCreateVerbs = [verb | (verb, owners) <- awsCreateVerbs, owners == ["src/Prodbox/Aws.hs"]]

-- | Sprint 4.27 (pure). Given a scanned file's relative path and its raw
-- contents, emit a violation for any 'awsCreateVerbs' verb that appears
-- in a file other than its sanctioned owner module(s). Generalizes the
-- Sprint 4.22 IAM-only @iamCreateSiteViolations@ to every AWS-resource
-- create call site so the create-site coverage lint cannot be bypassed
-- by reaching for a non-IAM @aws … create-*@ verb in an unowned module.
-- The 'awsCreateProbeVerbs' carve-out (the Route 53 capability probe) is
-- never flagged: those verbs are not in 'awsCreateVerbs' at all.
-- @CheckCode.hs@ is excluded from the scan by the path filter in
-- 'checkCreateCallSiteCoverage', so its own occurrences of these verb
-- literals do not self-trigger.
awsCreateSiteViolations :: FilePath -> String -> [String]
awsCreateSiteViolations relativePath contents =
  [ relativePath
      ++ " shells out an AWS-resource creation verb ("
      ++ verb
      ++ ") outside its owner module(s) "
      ++ intercalate ", " owners
      ++ "; register the created resource or move it into the owner."
  | (verb, owners) <- awsCreateVerbs
  , relativePath `notElem` owners
  , -- Match the quoted subprocess-argument form (@"create-bucket"@), not
  -- the bare substring, so Haddock prose describing a verb
  -- (@\@create-bucket\@@) in a non-owner module is not a false positive.
  ('"' : verb ++ "\"") `isInfixOf` contents
  ]

-- | Sprint 4.22 alias retained for back-compatibility (Sprint 4.27
-- generalized the lint to 'awsCreateSiteViolations'). Exposed for unit
-- tests; the live lint uses 'awsCreateSiteViolations'.
iamCreateSiteViolations :: FilePath -> String -> [String]
iamCreateSiteViolations = awsCreateSiteViolations

-- | Sprint 4.14: enforce the operator vocabulary contract defined in
-- @documents/engineering/cli_command_surface.md § 2A@. Sprint
-- identifiers (`Sprint <number>`, `Sprints <list>`) must not appear
-- in any operator-facing surface. This check scans:
--
--   * `src/Prodbox/CLI/Spec.hs` (string literals only — comments are
--     exempt because they are developer documentation, not operator
--     output)
--   * Every file under `share/man/`, `share/completion/`,
--     `documents/cli/`, and `test/golden/cli/`
--
-- A match anywhere in these paths fails the gate. The check is
-- conservative: it does not parse Haskell, it just extracts string
-- literals out of source files and greps the token sequence for an
-- adjacent `Sprint`/`Sprints` + digit. The non-source paths are
-- searched whole because they have no comment syntax that needs
-- stripping.
checkOperatorVocabulary :: FilePath -> IO [String]
checkOperatorVocabulary repoRoot = do
  specViolations <- scanSpecHsStringLiterals
  artifactViolations <- scanGeneratedArtifacts
  pure (specViolations ++ artifactViolations)
 where
  scanSpecHsStringLiterals :: IO [String]
  scanSpecHsStringLiterals = do
    let specPath = repoRoot </> "src" </> "Prodbox" </> "CLI" </> "Spec.hs"
    contents <- readFile specPath
    let literals = extractStringLiterals contents
        offenders =
          [ "src/Prodbox/CLI/Spec.hs string literal contains sprint identifier: "
              ++ shortenSprintLeak lit
          | lit <- literals
          , matchesSprintToken lit
          ]
    pure offenders

  scanGeneratedArtifacts :: IO [String]
  scanGeneratedArtifacts = do
    repoPaths <- listRepoOwnedPaths repoRoot
    let targetPaths =
          [ path
          | path <- repoPaths
          , any
              (`isPrefixOf` path)
              [ "share/man/"
              , "share/completion/"
              , "documents/cli/"
              , "test/golden/cli/"
              ]
          ]
    concat
      <$> forM
        targetPaths
        ( \relativePath -> do
            let absolutePath = repoRoot </> relativePath
            isFile <- doesFileExist absolutePath
            if not isFile
              then pure []
              else do
                contents <- readFile absolutePath
                pure $
                  [ relativePath
                      ++ " contains sprint identifier in operator-facing "
                      ++ "artifact (see "
                      ++ "documents/engineering/cli_command_surface.md § 2A)."
                  | any matchesSprintToken (lines contents)
                  ]
        )

-- | Sprint 4.14: does a single line contain the forbidden adjacent
-- `Sprint <digit>` or `Sprints <digit>` token pair? Exposed for unit
-- tests; consumed by 'checkOperatorVocabulary'.
--
-- Tokens are normalized by stripping leading and trailing
-- non-alphanumeric characters so the check fires on
-- @"(Sprint 4.11)"@ as well as @"Sprint 4.11:"@.
matchesSprintToken :: String -> Bool
matchesSprintToken line =
  let tokens = map stripPunct (words line)
      adjacentDigit (token : nextToken : rest)
        | token == "Sprint" || token == "Sprints"
        , firstChar : _ <- nextToken
        , firstChar `elem` ['0' .. '9'] =
            True
        | otherwise = adjacentDigit (nextToken : rest)
      adjacentDigit _ = False
   in adjacentDigit tokens
 where
  stripPunct :: String -> String
  stripPunct = dropWhileEnd (not . isAlphaNum) . dropWhile (not . isAlphaNum)

  dropWhileEnd :: (a -> Bool) -> [a] -> [a]
  dropWhileEnd p = foldr (\c acc -> if null acc && p c then [] else c : acc) []

shortenSprintLeak :: String -> String
shortenSprintLeak lit
  | length lit <= 80 = lit
  | otherwise = take 77 lit ++ "..."

-- | Walk a Haskell source string and emit the contents of every
-- @"..."@ string literal (in source order). Escaped quotes inside
-- literals are preserved as part of the body. Line- and block-
-- comments are ignored. Conservative: when in doubt, errs on the
-- side of treating data as outside a literal. Exposed for unit
-- tests; consumed by 'checkOperatorVocabulary'.
extractStringLiterals :: String -> [String]
extractStringLiterals = goOutside []
 where
  goOutside :: String -> String -> [String]
  goOutside _ [] = []
  goOutside acc ('-' : '-' : rest) =
    let _ = acc
     in goOutside [] (dropWhile (/= '\n') rest)
  goOutside acc ('{' : '-' : rest) =
    let _ = acc
     in goOutside [] (skipBlockComment rest)
  goOutside _ ('"' : rest) = goInside [] rest
  goOutside acc (_ : rest) = goOutside acc rest

  goInside :: String -> String -> [String]
  goInside acc [] = [reverse acc]
  goInside acc ('\\' : c : rest) = goInside (c : '\\' : acc) rest
  goInside acc ('"' : rest) = reverse acc : goOutside [] rest
  goInside acc (c : rest) = goInside (c : acc) rest

  skipBlockComment :: String -> String
  skipBlockComment [] = []
  skipBlockComment ('-' : '}' : rest) = rest
  skipBlockComment (_ : rest) = skipBlockComment rest

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
  formatExit <- runSubprocessStreaming repoRoot environment "cabal" ["format", tempCabalPath]
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

runSubprocessStreaming :: FilePath -> [(String, String)] -> FilePath -> [String] -> IO ExitCode
runSubprocessStreaming repoRoot environment subprocessPath arguments = do
  runResult <-
    Subprocess.runSubprocessStreaming
      Subprocess.Subprocess
        { Subprocess.subprocessPath = subprocessPath
        , Subprocess.subprocessArguments = arguments
        , Subprocess.subprocessEnvironment = Just environment
        , Subprocess.subprocessWorkingDirectory = Just repoRoot
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
