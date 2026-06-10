module Prodbox.CLI.Parser
  ( Options (..)
  , parserInfo
  , validateCommandArgv
  )
where

import Data.Version (showVersion)
import Options.Applicative
  ( Parser
  , ParserInfo
  , fullDesc
  , help
  , helper
  , info
  , infoOption
  , long
  , progDesc
  , short
  , switch
  , (<**>)
  )
import Paths_prodbox (version)
import Prodbox.CLI.Command
  ( CommandRequest
  )
import Prodbox.CLI.Spec
  ( commandRequestParser
  )

data Options = Options
  { optVerbose :: Bool
  , optRequest :: CommandRequest
  }
  deriving (Eq, Show)

parserInfo :: ParserInfo Options
parserInfo =
  info
    (optionsParser <**> helper <**> versionOption)
    ( fullDesc
        <> progDesc
          "prodbox - Haskell CLI frontend for the current repository command surface"
    )

validateCommandArgv :: [String] -> Either String ()
validateCommandArgv argv =
  case forbiddenArgvMessage argv of
    Just message -> Left message
    Nothing -> Right ()

optionsParser :: Parser Options
optionsParser =
  Options
    <$> switch
      ( long "verbose"
          <> short 'v'
          <> help "Enable verbose output"
      )
    <*> commandRequestParser

versionOption :: Parser (a -> a)
versionOption =
  infoOption
    (showVersion version)
    ( long "version"
        <> help "Show version"
    )

forbiddenArgvMessage :: [String] -> Maybe String
forbiddenArgvMessage argv
  | isRke2ForbiddenFlag argv =
      Just
        "Forbidden lifecycle flags: use `prodbox cluster reconcile` as the idempotent reconciler; `--force` and `--reinstall` are not supported."
  | isRke2ForbiddenSister argv =
      Just
        "Forbidden lifecycle command: use `prodbox cluster reconcile`; `install`, `upgrade`, `repair`, and `force-install` are not supported."
  | isChartsForbiddenFlag argv =
      Just
        "Forbidden chart reconciler flags: use `prodbox charts reconcile` or `prodbox charts delete`; `--force` and `--reinstall` are not supported."
  | isChartsForbiddenSister argv =
      Just
        "Forbidden chart command: use `prodbox charts reconcile` or `prodbox charts delete`; `install`, `upgrade`, `repair`, and `force-install` are not supported."
  | otherwise = Nothing

isRke2ForbiddenFlag :: [String] -> Bool
isRke2ForbiddenFlag argv =
  case argv of
    "cluster" : commandName : remaining ->
      commandName == "reconcile" && any (`elem` remaining) ["--force", "--reinstall"]
    _ -> False

isRke2ForbiddenSister :: [String] -> Bool
isRke2ForbiddenSister argv =
  case argv of
    "cluster" : commandName : _ -> commandName `elem` ["install", "upgrade", "repair", "force-install"]
    _ -> False

isChartsForbiddenFlag :: [String] -> Bool
isChartsForbiddenFlag argv =
  case argv of
    "charts" : commandName : remaining ->
      commandName `elem` ["reconcile", "delete"] && any (`elem` remaining) ["--force", "--reinstall"]
    _ -> False

isChartsForbiddenSister :: [String] -> Bool
isChartsForbiddenSister argv =
  case argv of
    "charts" : commandName : _ -> commandName `elem` ["install", "upgrade", "repair", "force-install"]
    _ -> False
