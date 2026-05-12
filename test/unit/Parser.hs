module Parser
  ( parserSuite
  )
where

import Data.Set qualified as Set
import Options.Applicative
  ( ParserResult (..)
  , defaultPrefs
  , execParserPure
  , renderFailure
  )
import Prodbox.CLI.Parser
  ( Options
  , parserInfo
  , validateCommandArgv
  )
import Prodbox.CLI.Spec
  ( CommandSpec (..)
  , Example (..)
  , commandRegistry
  , leafCommandPaths
  )
import TestSupport

parserSuite :: SuiteBuilder ()
parserSuite =
  describe "CLI parser coverage" $ do
    propertyTest "every leaf command has at least one example" leafExampleCoverageProperty
    mapM_ happyCase (collectLeafExamples commandRegistry)
    mapM_ unhappyCase (collectLeafExamples commandRegistry)
    mapM_ forbiddenCase forbiddenArgvCases

happyCase :: ([String], Example) -> SuiteBuilder ()
happyCase (commandPath, exampleSpec) =
  it ("accepts " ++ unwords ("prodbox" : commandPath)) $
    parseArgs (exampleCommand exampleSpec) `shouldSatisfy` isRight

unhappyCase :: ([String], Example) -> SuiteBuilder ()
unhappyCase (commandPath, exampleSpec) =
  it ("rejects unsupported flag for " ++ unwords ("prodbox" : commandPath)) $
    parseArgs (exampleCommand exampleSpec ++ ["--definitely-unsupported-flag"])
      `shouldSatisfy` isLeft

forbiddenCase :: ([String], String) -> SuiteBuilder ()
forbiddenCase (argv, label) =
  it ("rejects forbidden reconciler surface " ++ label) $
    case parseArgs argv of
      Left message -> message `shouldContain` "Forbidden"
      Right _ -> expectationFailure ("expected parse failure for " ++ unwords ("prodbox" : argv))

forbiddenArgvCases :: [([String], String)]
forbiddenArgvCases =
  [ (["rke2", "reconcile", "--force"], "rke2 reconcile --force")
  , (["rke2", "reconcile", "--reinstall"], "rke2 reconcile --reinstall")
  , (["rke2", "install", "--force"], "rke2 install --force")
  , (["rke2", "install", "--reinstall"], "rke2 install --reinstall")
  , (["rke2", "upgrade"], "rke2 upgrade")
  , (["rke2", "repair"], "rke2 repair")
  , (["rke2", "force-install"], "rke2 force-install")
  , (["charts", "deploy", "vscode", "--force"], "charts deploy --force")
  , (["charts", "deploy", "vscode", "--reinstall"], "charts deploy --reinstall")
  , (["charts", "delete", "vscode", "--force"], "charts delete --force")
  , (["charts", "delete", "vscode", "--reinstall"], "charts delete --reinstall")
  , (["charts", "install", "vscode"], "charts install")
  , (["charts", "upgrade", "vscode"], "charts upgrade")
  , (["charts", "repair", "vscode"], "charts repair")
  , (["charts", "force-install", "vscode"], "charts force-install")
  ]

leafExampleCoverageProperty :: Bool
leafExampleCoverageProperty =
  Set.fromList (map fst (collectLeafExamples commandRegistry)) == Set.fromList leafCommandPaths

collectLeafExamples :: CommandSpec -> [([String], Example)]
collectLeafExamples = go []
 where
  go prefix spec =
    let commandPath =
          if name spec == "prodbox"
            then prefix
            else prefix ++ [name spec]
     in case children spec of
          [] ->
            case examples spec of
              firstExample : _ -> [(commandPath, firstExample)]
              [] -> []
          nested -> concatMap (go commandPath) nested

parseArgs :: [String] -> Either String Options
parseArgs argv =
  case validateCommandArgv argv of
    Left err -> Left err
    Right () ->
      case execParserPure defaultPrefs parserInfo argv of
        Success options -> Right options
        Failure failure -> Left (fst (renderFailure failure "prodbox"))
        CompletionInvoked _ -> Left "shell completion requested"

isLeft :: Either left right -> Bool
isLeft eitherValue =
  case eitherValue of
    Left _ -> True
    Right _ -> False

isRight :: Either left right -> Bool
isRight eitherValue =
  case eitherValue of
    Left _ -> False
    Right _ -> True
