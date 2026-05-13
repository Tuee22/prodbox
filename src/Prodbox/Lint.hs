module Prodbox.Lint
  ( ensureSandboxedStyleTools
  , formatterToolCabalVersion
  , formatterToolGhcVersion
  , fourmoluVersion
  , hlintVersion
  , missingStyleToolViolations
  , styleToolsBinDir
  )
where

import Control.Monad (forM)
import Prodbox.Result (Result (..))
import Prodbox.Subprocess
  ( CommandSpec (..)
  , runStreamingCommand
  )
import System.Directory
  ( createDirectoryIfMissing
  , doesFileExist
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))

formatterToolGhcVersion :: String
formatterToolGhcVersion = "9.12.4"

formatterToolCabalVersion :: String
formatterToolCabalVersion = "3.16.1.0"

fourmoluVersion :: String
fourmoluVersion = "0.19.0.1"

hlintVersion :: String
hlintVersion = "3.10"

styleToolsBinDir :: FilePath -> FilePath
styleToolsBinDir repoRoot = repoRoot </> ".build" </> "prodbox-style-tools" </> "bin"

ensureSandboxedStyleTools :: FilePath -> [(String, String)] -> IO (Either String ())
ensureSandboxedStyleTools repoRoot environment = do
  let binDir = styleToolsBinDir repoRoot
  createDirectoryIfMissing True binDir
  initialViolations <- missingStyleToolViolations binDir
  case initialViolations of
    [] -> pure (Right ())
    _ -> do
      installResult <-
        runStreamingCommand
          CommandSpec
            { commandPath = "ghcup"
            , commandArguments = toolBootstrapArguments binDir
            , commandEnvironment = Just environment
            , commandWorkingDirectory = Just repoRoot
            }
      case installResult of
        Failure err ->
          pure
            ( Left
                ( "Failed to bootstrap sandboxed Haskell style tools through `ghcup run`: "
                    ++ err
                )
            )
        Success ExitSuccess -> do
          finalViolations <- missingStyleToolViolations binDir
          pure $
            case finalViolations of
              [] -> Right ()
              _ -> Left (unlines finalViolations)
        Success failure@(ExitFailure _) ->
          pure
            ( Left
                ( "Sandboxed Haskell style tool bootstrap failed with "
                    ++ show failure
                    ++ ". Rerun `prodbox lint haskell` after installing `ghcup` or fixing the toolchain."
                )
            )

missingStyleToolViolations :: FilePath -> IO [String]
missingStyleToolViolations sandboxDir =
  fmap concat $
    forM
      ["fourmolu", "hlint"]
      ( \toolName -> do
          let toolPath = sandboxDir </> toolName
          toolExists <- doesFileExist toolPath
          pure
            [ "Missing sandboxed style tool `"
                ++ toolName
                ++ "` at `"
                ++ toolPath
                ++ "`."
            | not toolExists
            ]
      )

toolBootstrapArguments :: FilePath -> [String]
toolBootstrapArguments binDir =
  [ "run"
  , "--install"
  , "--ghc"
  , formatterToolGhcVersion
  , "--cabal"
  , formatterToolCabalVersion
  , "--"
  , "cabal"
  , "install"
  , "--ignore-project"
  , "fourmolu-" ++ fourmoluVersion
  , "hlint-" ++ hlintVersion
  , "--installdir=" ++ binDir
  , "--overwrite-policy=always"
  , "--install-method=copy"
  , "--with-compiler=ghc-" ++ formatterToolGhcVersion
  ]
