{-# LANGUAGE DuplicateRecordFields #-}

module Prodbox.CLI.Docs
  ( renderBashCompletion
  , renderCommandHelp
  , renderCommandSurfaceMatrix
  , renderCommandSurfaceTopLevel
  , renderFishCompletion
  , renderGroupManpage
  , renderMarkdownCommandReference
  , renderTopLevelManpage
  , renderZshCompletion
  )
where

import Prodbox.CLI.Spec
  ( ArgumentSpec (..)
  , CommandSpec (..)
  , Example (..)
  , OptionSpec (..)
  )

renderCommandHelp :: [String] -> CommandSpec -> String
renderCommandHelp commandPath spec =
  unlines
    ( [ commandHeader commandPath spec
      , ""
      , commandDescription
      ]
        ++ renderChildren spec
        ++ renderOptions spec
        ++ renderExamples spec
    )
 where
  CommandSpec {description = commandDescription} = spec

commandHeader :: [String] -> CommandSpec -> String
commandHeader commandPath spec =
  unwords ("prodbox" : commandPath) ++ " - " ++ summary spec

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
    , optionMetavar = optionMetavar
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

-- | Render the §2 top-level command table (Command | Kind | Purpose)
-- directly from the registry's immediate children, in registry order. A
-- child with subcommands is a @Group@; a child without is a @Command@.
-- Pure and deterministic: no sorting, timestamps, or environment reads —
-- the row order is the registry's declaration order.
renderCommandSurfaceTopLevel :: CommandSpec -> String
renderCommandSurfaceTopLevel spec =
  unlines
    ( [ "| Command | Kind | Purpose |"
      , "|---------|------|---------|"
      ]
        ++ map renderTopLevelRow (children spec)
    )
 where
  renderTopLevelRow child =
    "| `"
      ++ name child
      ++ "` | "
      ++ topLevelKind child
      ++ " | "
      ++ summary child
      ++ " |"

  topLevelKind child =
    case children child of
      [] -> "Command"
      _ -> "Group"

-- | Render the §3 per-group command matrix directly from the registry. For
-- each top-level child the matrix emits a @### \`prodbox \<name\>\`@ heading
-- followed by a @Command | Arguments | Options@ table whose rows are every
-- leaf command in that subtree (in registry order). The "Arguments" column
-- renders each leaf's typed positional 'ArgumentSpec's; the "Options"
-- column lists each leaf's long flags. Pure and deterministic: no sorting,
-- timestamps, or environment reads.
renderCommandSurfaceMatrix :: CommandSpec -> String
renderCommandSurfaceMatrix spec =
  intercalateBlocks (map renderGroupBlock (children spec))
 where
  renderGroupBlock child =
    unlines
      ( [ "### `prodbox " ++ name child ++ "`"
        , ""
        , "| Command | Arguments | Options |"
        , "|---------|-----------|---------|"
        ]
          ++ map renderMatrixRow (gatherLeaves [name child] child)
      )

  renderMatrixRow (commandPath, node) =
    "| `prodbox "
      ++ unwords commandPath
      ++ "` | "
      ++ renderArgumentsCell (arguments node)
      ++ " | "
      ++ renderOptionsCell (options node)
      ++ " |"

-- | Every (command-path, leaf-spec) pair reachable from a node, in
-- registry order. A node with no children is a leaf and yields a single
-- pair; otherwise the children are gathered with the node's name pushed
-- onto the path prefix.
gatherLeaves :: [String] -> CommandSpec -> [([String], CommandSpec)]
gatherLeaves commandPath node =
  case children node of
    [] -> [(commandPath, node)]
    nested -> concatMap (\child -> gatherLeaves (commandPath ++ [name child]) child) nested

-- | Render the "Arguments" matrix cell. @none@ when the leaf takes no
-- positional arguments; otherwise the space-joined metavars, with @...@
-- appended to a repeatable metavar and @[...]@ wrapping an optional one.
renderArgumentsCell :: [ArgumentSpec] -> String
renderArgumentsCell [] = "none"
renderArgumentsCell argumentSpecs =
  "`" ++ unwords (map renderArgumentMetavar argumentSpecs) ++ "`"

renderArgumentMetavar :: ArgumentSpec -> String
renderArgumentMetavar argumentSpec =
  optionalWrap (argumentMetavar argumentSpec ++ repeatableSuffix)
 where
  repeatableSuffix = if argumentRepeatable argumentSpec then "..." else ""
  optionalWrap text =
    if argumentOptional argumentSpec
      then "[" ++ text ++ "]"
      else text

-- | Render the "Options" matrix cell. @none@ when the leaf takes no
-- options; otherwise the comma-joined long flags in registry order, each
-- as @\`--flag\`@.
renderOptionsCell :: [OptionSpec] -> String
renderOptionsCell [] = "none"
renderOptionsCell optionSpecs =
  intercalateString ", " (map renderOptionFlag optionSpecs)

renderOptionFlag :: OptionSpec -> String
renderOptionFlag optionSpec = "`--" ++ longName optionSpec ++ "`"

-- | Join rendered blocks with a single blank line between them. Each block
-- already ends in a trailing newline (it was built with 'unlines'), so the
-- separator is a lone newline.
intercalateBlocks :: [String] -> String
intercalateBlocks = intercalateString "\n"

intercalateString :: String -> [String] -> String
intercalateString separator =
  go
 where
  go [] = ""
  go [final] = final
  go (current : remaining) = current ++ separator ++ go remaining

renderTopLevelManpage :: CommandSpec -> String
renderTopLevelManpage spec =
  let CommandSpec {description = commandDescription} = spec
   in unlines
        ( [ ".TH PRODBOX 1"
          , ".SH NAME"
          , "prodbox \\- " ++ summary spec
          , ".SH SYNOPSIS"
          , ".B prodbox"
          , "[GLOBAL OPTIONS] COMMAND"
          , ".SH DESCRIPTION"
          , commandDescription
          , ".SH COMMAND GROUPS"
          ]
            ++ renderManpageChildren spec
            ++ [".SH EXAMPLES"]
            ++ renderManpageExamples spec
        )

renderGroupManpage :: CommandSpec -> String
renderGroupManpage spec =
  let CommandSpec {description = commandDescription} = spec
   in unlines
        ( [ ".TH " ++ map normalizeManpageTitle ("PRODBOX-" ++ name spec) ++ " 1"
          , ".SH NAME"
          , "prodbox-" ++ name spec ++ " \\- " ++ summary spec
          , ".SH SYNOPSIS"
          , ".B prodbox " ++ name spec
          , ".SH DESCRIPTION"
          , commandDescription
          ]
            ++ renderManpageOptions spec
            ++ renderManpageChildren spec
            ++ [".SH EXAMPLES"]
            ++ renderManpageExamples spec
        )

renderBashCompletion :: CommandSpec -> String
renderBashCompletion spec =
  unlines $
    [ "# Generated by `prodbox docs generate`."
    , "_prodbox()"
    , "{"
    , "  local cur key words"
    , "  COMPREPLY=()"
    , "  cur=\"${COMP_WORDS[COMP_CWORD]}\""
    , "  if (( COMP_CWORD <= 1 )); then"
    , "    words=\"" ++ unwords (childNames spec) ++ "\""
    , "  else"
    , "    key=\"${COMP_WORDS[@]:1:COMP_CWORD-1}\""
    , "    case \"$key\" in"
    ]
      ++ renderBashCompletionCases spec
      ++ [ "      *) words=\"\" ;;"
         , "    esac"
         , "  fi"
         , "  COMPREPLY=( $(compgen -W \"$words\" -- \"$cur\") )"
         , "}"
         , "complete -F _prodbox prodbox"
         ]

renderZshCompletion :: CommandSpec -> String
renderZshCompletion spec =
  unlines $
    [ "#compdef prodbox"
    , "# Generated by `prodbox docs generate`."
    , "_prodbox() {"
    , "  local -a words"
    , "  case \"$CURRENT\" in"
    , "    2)"
    , "      words=(" ++ zshWordList (childNames spec) ++ ")"
    , "      _describe 'command group' words"
    , "      ;;"
    ]
      ++ renderZshCompletionCases spec
      ++ [ "    *)"
         , "      _describe 'command group' words"
         , "      ;;"
         , "  esac"
         , "}"
         ]

renderFishCompletion :: CommandSpec -> String
renderFishCompletion spec =
  unlines
    ( ["# Generated by `prodbox docs generate`."]
        ++ map renderFishTopLevel (children spec)
        ++ concatMap renderFishChildren (children spec)
    )

renderManpageOptions :: CommandSpec -> [String]
renderManpageOptions spec =
  case options spec of
    [] -> []
    nodeOptions ->
      ".SH OPTIONS" : concatMap renderManpageOption nodeOptions

renderManpageOption :: OptionSpec -> [String]
renderManpageOption optionSpec =
  let OptionSpec {description = optionDescription} = optionSpec
   in [ ".TP"
      , "\\fB--" ++ longName optionSpec ++ "\\fR" ++ shortFragment ++ metavarFragment
      , optionDescription
      ]
 where
  shortFragment =
    case shortName optionSpec of
      Nothing -> ""
      Just shortFlag -> ", \\fB-" ++ [shortFlag] ++ "\\fR"
  metavarFragment =
    case optionMetavar optionSpec of
      Nothing -> ""
      Just value -> " <" ++ value ++ ">"

renderManpageChildren :: CommandSpec -> [String]
renderManpageChildren spec =
  case children spec of
    [] -> []
    nested ->
      ".SH SUBCOMMANDS"
        : concatMap
          ( \child ->
              [ ".TP"
              , "\\fB" ++ name child ++ "\\fR"
              , summary child
              ]
          )
          nested

renderManpageExamples :: CommandSpec -> [String]
renderManpageExamples spec =
  case examples spec of
    [] -> [".TP", "No documented examples."]
    nodeExamples ->
      concatMap
        ( \exampleSpec ->
            [ ".TP"
            , "\\fBprodbox " ++ unwords (exampleCommand exampleSpec) ++ "\\fR"
            , exampleDescription exampleSpec
            ]
        )
        nodeExamples

renderBashCompletionCases :: CommandSpec -> [String]
renderBashCompletionCases = concatMap renderCase . gatherCompletionPrefixes []
 where
  renderCase (prefix, nextWords) =
    [ "      " ++ quoteCase prefix ++ ")"
    , "        words=\"" ++ unwords nextWords ++ "\""
    , "        ;;"
    ]

renderZshCompletionCases :: CommandSpec -> [String]
renderZshCompletionCases = concatMap renderCase . gatherCompletionPrefixes []
 where
  renderCase (prefix, nextWords) =
    [ "    " ++ show (length prefix + 2) ++ ")"
    , "      case \"$words[2," ++ show (length prefix + 1) ++ "]\" in"
    , "        " ++ quoteCase prefix ++ ")"
    , "          words=(" ++ zshWordList nextWords ++ ")"
    , "          _describe 'subcommand' words"
    , "          ;;"
    , "      esac"
    , "      ;;"
    ]

renderFishTopLevel :: CommandSpec -> String
renderFishTopLevel spec =
  "complete -c prodbox -f -n '__fish_use_subcommand' -a "
    ++ fishQuote (name spec)
    ++ " -d "
    ++ fishQuote (summary spec)

renderFishChildren :: CommandSpec -> [String]
renderFishChildren spec =
  map renderChild (children spec)
 where
  renderChild child =
    "complete -c prodbox -f -n '__fish_seen_subcommand_from "
      ++ name spec
      ++ "' -a "
      ++ fishQuote (name child)
      ++ " -d "
      ++ fishQuote (summary child)

gatherCompletionPrefixes :: [String] -> CommandSpec -> [([String], [String])]
gatherCompletionPrefixes prefix spec =
  case children spec of
    [] -> []
    nested ->
      let here =
            [ (nextPrefix, childNames spec)
            | not (null nextPrefix)
            ]
          deeper = concatMap (gatherCompletionPrefixes nextPrefix) nested
       in here ++ deeper
 where
  nextPrefix =
    if name spec == "prodbox"
      then prefix
      else prefix ++ [name spec]

childNames :: CommandSpec -> [String]
childNames = map name . children

quoteCase :: [String] -> String
quoteCase [] = "\"\""
quoteCase segments = "\"" ++ unwords segments ++ "\""

zshWordList :: [String] -> String
zshWordList = unwords . map (\word -> "\"" ++ word ++ "\"")

fishQuote :: String -> String
fishQuote text = "'" ++ text ++ "'"

normalizeManpageTitle :: Char -> Char
normalizeManpageTitle '-' = '_'
normalizeManpageTitle character = character
