{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneRpcBirthController (rpcBirthControllerSuite) where

import Control.Monad (forM_)
import Data.Either (isLeft)
import Options.Applicative (ParserResult (..), defaultPrefs, execParserPure, renderFailure)
import Prodbox.App (canRunWithoutRepoRoot)
import Prodbox.CLI.Command (CommandRequest (..), NativeCommand (..))
import Prodbox.CLI.Parser (Options (..), parserInfo, validateCommandArgv)
import Prodbox.CLI.Spec (CommandSpec (options), OptionSpec (longName, required), findCommandSpec)
import Prodbox.ControlPlane.RpcAdmissionBirthController (runRpcBirthController)
import Prodbox.ControlPlane.RpcAdmissionBirthControllerInputs (parseRpcBirthControllerArguments)
import Prodbox.Native (commandPrerequisites)
import TestSupport

rpcBirthControllerSuite :: SuiteBuilder ()
rpcBirthControllerSuite = describe "closed RPC birth controller CLI" $ do
  it "parses the shared canonical envelope into the registered native command" $ do
    let expected = must (parseRpcBirthControllerArguments arguments)
        command = NativeRpcBirthController expected
    parseCommand True (token : arguments) `shouldBe` Right (RunNative command)
    canRunWithoutRepoRoot command `shouldBe` True
    commandPrerequisites command `shouldBe` []

  it "registers all nine required options for normal help and introspection" $ do
    case findCommandSpec [token] of
      Nothing -> expectationFailure "controller leaf missing from the canonical registry"
      Just spec -> do
        map longName (options spec)
          `shouldBe` [ "config"
                     , "request"
                     , "input-fingerprint"
                     , "operation-key"
                     , "outer-ns"
                     , "work-ns"
                     , "hard-ns"
                     , "stop-ns"
                     , "finish-ns"
                     ]
        map required (options spec) `shouldBe` replicate 9 True

  forM_
    [ ("missing pair", take 16 arguments)
    , ("duplicate pair", take 2 arguments ++ arguments)
    , ("reordered pair", take 2 (drop 2 arguments) ++ take 2 arguments ++ drop 4 arguments)
    , ("unknown tail", arguments ++ ["--source", "/unowned/config"])
    , ("relative path", replace 1 "relative.cbor")
    , ("noncanonical path", replace 3 "/tmp/a/../request.cbor")
    , ("invalid fingerprint", replace 5 (replicate 64 'A'))
    , ("invalid key", replace 7 "unowned")
    , ("leading-zero clock", replace 11 "0100")
    , ("inverted clock", replace 17 "600")
    , ("overflow clock", replace 9 "18446744073709551616")
    ]
    $ \(label, rejected) ->
      it ("rejects " <> label <> " through the ordinary argv validator") $
        parseCommand True (token : rejected) `shouldSatisfy` isLeft

  it "also validates the complete envelope inside the registered parser binding" $
    parseCommand False (token : replace 17 "600") `shouldSatisfy` isLeft

  forM_ ["--help", "-h"] $ \flag ->
    it ("permits normal " <> flag <> " without opening an input") $ do
      validateCommandArgv [token, flag] `shouldBe` Right ()
      case execParserPure defaultPrefs parserInfo [token, flag] of
        Failure failure -> do
          let (message, _) = renderFailure failure "prodbox"
          message `shouldContain` "--input-fingerprint"
          message `shouldContain` "--finish-ns"
        _ -> expectationFailure "controller help did not use the canonical parser"

  it "refuses an expired data envelope without admitting a controller" $ do
    result <- runRpcBirthController (must (parseRpcBirthControllerArguments arguments))
    result `shouldSatisfy` isLeft
 where
  replace position value = take position arguments ++ [value] ++ drop (position + 1) arguments

token :: String
token = "internal-rpc-birth-controller"

arguments :: [String]
arguments =
  [ "--config"
  , "/tmp/rpc-birth-controller-settings.cbor"
  , "--request"
  , "/tmp/rpc-birth-controller-request.cbor"
  , "--input-fingerprint"
  , replicate 64 'a'
  , "--operation-key"
  , replicate 64 'b'
  , "--outer-ns"
  , "500"
  , "--work-ns"
  , "100"
  , "--hard-ns"
  , "200"
  , "--stop-ns"
  , "300"
  , "--finish-ns"
  , "400"
  ]

parseCommand :: Bool -> [String] -> Either String CommandRequest
parseCommand validate argv = do
  if validate then validateCommandArgv argv else Right ()
  case execParserPure defaultPrefs parserInfo argv of
    Success parsed -> Right (optRequest parsed)
    Failure failure -> Left (fst (renderFailure failure "prodbox"))
    CompletionInvoked _ -> Left "completion requested"

must :: (Show errorValue) => Either errorValue value -> value
must = either (error . show) id
