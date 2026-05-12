{-# LANGUAGE DuplicateRecordFields #-}

module Prodbox.CLI.Docs
  ( renderCommandHelp
  , renderMarkdownCommandReference
  )
where

import Prodbox.CLI.Spec
  ( CommandSpec (..)
  , Example (..)
  , OptionSpec (..)
  )

renderCommandHelp :: CommandSpec -> String
renderCommandHelp spec =
  unlines
    ( [ commandHeader spec
      , ""
      , commandDescription
      ]
        ++ renderChildren spec
        ++ renderOptions spec
        ++ renderExamples spec
    )
 where
  CommandSpec {description = commandDescription} = spec

commandHeader :: CommandSpec -> String
commandHeader spec =
  unwords (pathToNode spec) ++ " - " ++ summary spec

pathToNode :: CommandSpec -> [String]
pathToNode spec = [name spec]

renderChildren :: CommandSpec -> [String]
renderChildren spec =
  case children spec of
    [] -> []
    nested ->
      "Subcommands:"
        : map (\child -> "- " ++ name child ++ " - " ++ summary child) nested
        ++ [""]

renderOptions :: CommandSpec -> [String]
renderOptions spec =
  case options spec of
    [] -> []
    nodeOptions ->
      "Options:"
        : map renderOption nodeOptions
        ++ [""]

renderOption :: OptionSpec -> String
renderOption optionSpec =
  "- --"
    ++ optionLongName
    ++ shortFragment
    ++ metavarFragment
    ++ " - "
    ++ optionDescription
 where
  OptionSpec
    { longName = optionLongName
    , shortName = optionShortName
    , metavar = optionMetavar
    , description = optionDescription
    } = optionSpec

  shortFragment =
    case optionShortName of
      Nothing -> ""
      Just shortFlag -> ", -" ++ [shortFlag]
  metavarFragment =
    case optionMetavar of
      Nothing -> ""
      Just value -> " <" ++ value ++ ">"

renderExamples :: CommandSpec -> [String]
renderExamples spec =
  case examples spec of
    [] -> []
    nodeExamples ->
      "Examples:"
        : map renderExample nodeExamples

renderExample :: Example -> String
renderExample exampleSpec =
  "- prodbox "
    ++ unwords (exampleCommand exampleSpec)
    ++ "  # "
    ++ exampleDescription exampleSpec

renderMarkdownCommandReference :: CommandSpec -> String
renderMarkdownCommandReference spec =
  unlines
    ( [ "| Command | Summary |"
      , "|---------|---------|"
      ]
        ++ map renderRow (gatherRows ["prodbox"] spec)
    )
 where
  gatherRows prefix node =
    let commandPath = prefix ++ [name node | name node /= "prodbox"]
        currentRow =
          [(unwords commandPath, summary node) | null (children node)]
        nextPrefix =
          if name node == "prodbox"
            then prefix
            else commandPath
     in currentRow ++ concatMap (gatherRows nextPrefix) (children node)

  renderRow (commandPath, commandSummary) =
    "| `" ++ commandPath ++ "` | " ++ commandSummary ++ " |"
