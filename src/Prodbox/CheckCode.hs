module Prodbox.CheckCode
  ( DoctrineViolation (..)
  , doctrineViolationsInPaths
  , haskellStyleViolations
  , listRepoOwnedPaths
  , runCheckCode
  , runDocsCommand
  , runLintCommand
  )
where

import Control.Monad (forM)
import Data.List (isInfixOf, isPrefixOf, sort)
import Prodbox.BuildSupport
  ( addBuildSupportEnvironment
  , syncBuiltOperatorBinary
  )
import Prodbox.CLI.Command
  ( DocsCommand (..)
  , LintCommand (..)
  )
import Prodbox.CLI.Docs (renderMarkdownCommandReference)
import Prodbox.CLI.Spec (commandRegistry)
import System.Directory
  ( copyFile
  , createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , findExecutable
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
import System.IO (hPutStrLn, stderr)
import System.IO.Error (tryIOError)
import System.Process
  ( CreateProcess
      ( cwd
      , delegate_ctlc
      , env
      , std_err
      , std_in
      , std_out
      )
  , StdStream (Inherit)
  , createProcess
  , proc
  , waitForProcess
  )

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
  , generatedSectionBody :: String
  }

generatedSectionRules :: [GeneratedSectionRule]
generatedSectionRules =
  [ GeneratedSectionRule
      { generatedSectionKey = "command-registry.markdown"
      , generatedSectionPath = "documents/cli/commands.md"
      , generatedSectionStartMarker = "<!-- prodbox:command-registry.markdown:start -->"
      , generatedSectionEndMarker = "<!-- prodbox:command-registry.markdown:end -->"
      , generatedSectionBody = renderMarkdownCommandReference commandRegistry
      }
  ]

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
    DocsCheck -> runGeneratedSectionLint repoRoot False
    DocsGenerate -> runGeneratedSectionLint repoRoot True

runLintCommand :: FilePath -> LintCommand -> IO ExitCode
runLintCommand repoRoot command = do
  baseEnvironment <- getEnvironment
  environment <- addBuildSupportEnvironment repoRoot baseEnvironment
  case command of
    LintAll -> runLintAll repoRoot environment
    LintFiles _writeEnabled -> runFileLint repoRoot
    LintDocs writeEnabled -> runGeneratedSectionLint repoRoot writeEnabled
    LintHaskell writeEnabled -> runHaskellLint repoRoot environment writeEnabled
    LintChart -> runChartLint repoRoot

runLintAll :: FilePath -> [(String, String)] -> IO ExitCode
runLintAll repoRoot environment = do
  filesExit <- runFileLint repoRoot
  case filesExit of
    ExitFailure _ -> pure filesExit
    ExitSuccess -> do
      docsExit <- runGeneratedSectionLint repoRoot False
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
        Right () -> pure ExitSuccess

runGeneratedSectionLint :: FilePath -> Bool -> IO ExitCode
runGeneratedSectionLint repoRoot writeEnabled = do
  results <-
    forM generatedSectionRules $ \rule -> do
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
  case firstLeft results of
    Just err -> failWith err
    Nothing -> do
      whenWriteRepoFiles results
      pure ExitSuccess

runHaskellLint :: FilePath -> [(String, String)] -> Bool -> IO ExitCode
runHaskellLint repoRoot environment writeEnabled = do
  fourmoluResult <- requireTool "fourmolu"
  case fourmoluResult of
    Left err -> failWith err
    Right () -> do
      hlintResult <- requireTool "hlint"
      case hlintResult of
        Left err -> failWith err
        Right () -> do
          styleViolations <- haskellStyleViolations repoRoot
          case styleViolations of
            [] -> do
              formatExit <-
                runStreaming
                  repoRoot
                  environment
                  "fourmolu"
                  ( ["--mode", if writeEnabled then "inplace" else "check", "app", "src", "test"]
                  )
              case formatExit of
                ExitFailure _ -> pure formatExit
                ExitSuccess -> do
                  lintExit <- runStreaming repoRoot environment "hlint" ["app", "src", "test", "--hint=.hlint.yaml"]
                  case lintExit of
                    ExitFailure _ -> pure lintExit
                    ExitSuccess ->
                      if writeEnabled
                        then rewriteCabalFile repoRoot environment
                        else checkCabalFormat repoRoot environment
            _ ->
              failWith
                (unlines ("Haskell style lint failed:" : map ("- " ++) styleViolations))

runChartLint :: FilePath -> IO ExitCode
runChartLint repoRoot = do
  repoPaths <- listRepoOwnedPaths repoRoot
  let chartFiles =
        [ path
        | path <- repoPaths
        , takeFileName path == "Chart.yaml"
        , "charts" `isPrefixOf` path
        ]
  if null chartFiles
    then failWith "No chart manifests found under `charts/`."
    else pure ExitSuccess

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
  parserModuleViolation <- checkParserModuleImports repoRoot
  daemonRuntimeViolations <- checkDaemonRuntimeImports repoRoot
  testSuiteTypeViolations <- checkTestSuiteInterfaces repoRoot
  pure
    ( either pure (const []) thinMainResult
        ++ maybeToList parserModuleViolation
        ++ daemonRuntimeViolations
        ++ testSuiteTypeViolations
    )

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
          sessionViolations =
            [ path ++ " must not call `setsid`."
            | "setsid" `isInfixOf` contents
            ]
      pure (importViolations ++ forkViolations ++ sessionViolations)

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
                        ++ lines (generatedSectionBody rule)
                        ++ [endMarker]
                        ++ trailingLines
                    )
                )

generatedSectionDriftMessage :: FilePath -> GeneratedSectionRule -> String
generatedSectionDriftMessage targetPath rule =
  unlines
    [ targetPath
    , generatedSectionKey rule
    , "Run `prodbox docs generate` to update."
    ]

missingGeneratedTargetMessage :: GeneratedSectionRule -> String
missingGeneratedTargetMessage rule =
  "Missing generated documentation target `"
    ++ generatedSectionPath rule
    ++ "` for registry key `"
    ++ generatedSectionKey rule
    ++ "`."

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
  (_, _, _, handle) <-
    createProcess
      (proc commandPath arguments)
        { cwd = Just repoRoot
        , env = Just environment
        , std_in = Inherit
        , std_out = Inherit
        , std_err = Inherit
        , delegate_ctlc = True
        }
  waitForProcess handle

requireTool :: String -> IO (Either String ())
requireTool toolName = do
  executable <- findExecutable toolName
  pure $
    case executable of
      Just _ -> Right ()
      Nothing ->
        Left
          ( "Missing required tool `"
              ++ toolName
              ++ "`. Install the Haskell quality tools and rerun `./.build/prodbox check-code`."
          )

failWith :: String -> IO ExitCode
failWith message = do
  hPutStrLn stderr message
  pure (ExitFailure 1)
