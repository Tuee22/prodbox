module Prodbox.Tla
  ( runTlaCheck
  )
where

import Prodbox.Result (Result (..))
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  )
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Exit
  ( ExitCode (..)
  )
import System.FilePath (takeDirectory)

runTlaCheck :: FilePath -> IO ExitCode
runTlaCheck repoRoot = do
  let tlaDir = repoRoot ++ "/documents/engineering/tla"
      resultPath = tlaDir ++ "/tlc_last_run.txt"
  availability <- traverse (observeModelFiles tlaDir) tlaModels
  case concatMap missingModelFiles availability of
    missing@(_ : _) -> do
      writeResult resultPath (unlines missing)
      pure (ExitFailure 1)
    [] -> do
      results <- traverse (runModel repoRoot tlaDir) tlaModels
      writeResult resultPath (concatMap renderModelResult results)
      pure
        ( if all ((== ExitSuccess) . modelResultExitCode) results
            then ExitSuccess
            else ExitFailure 1
        )

data TlaModel = TlaModel
  { tlaModelFile :: FilePath
  , tlaConfigFile :: FilePath
  }

tlaModels :: [TlaModel]
tlaModels =
  [ TlaModel "gateway_orders_rule.tla" "gateway_orders_rule.cfg"
  , TlaModel "gateway_legacy_liveness.tla" "gateway_legacy_liveness.cfg"
  ]

data ModelAvailability = ModelAvailability
  { availabilityModel :: TlaModel
  , availabilityModelExists :: Bool
  , availabilityConfigExists :: Bool
  }

observeModelFiles :: FilePath -> TlaModel -> IO ModelAvailability
observeModelFiles tlaDir model = do
  modelExists <- doesFileExist (tlaDir ++ "/" ++ tlaModelFile model)
  configExists <- doesFileExist (tlaDir ++ "/" ++ tlaConfigFile model)
  pure
    ModelAvailability
      { availabilityModel = model
      , availabilityModelExists = modelExists
      , availabilityConfigExists = configExists
      }

missingModelFiles :: ModelAvailability -> [String]
missingModelFiles availability =
  [ "Model file not found: " ++ tlaModelFile model
  | not (availabilityModelExists availability)
  ]
    ++ [ "Config file not found: " ++ tlaConfigFile model
       | not (availabilityConfigExists availability)
       ]
 where
  model = availabilityModel availability

data ModelResult = ModelResult
  { modelResultName :: FilePath
  , modelResultCommand :: [String]
  , modelResultExitCode :: ExitCode
  , modelResultStdout :: String
  , modelResultStderr :: String
  }

runModel :: FilePath -> FilePath -> TlaModel -> IO ModelResult
runModel repoRoot tlaDir model = do
  let command = dockerCommand tlaDir model
  outputResult <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "docker"
        , subprocessArguments = drop 1 command
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
  pure $ case outputResult of
    Failure err ->
      ModelResult
        { modelResultName = tlaModelFile model
        , modelResultCommand = command
        , modelResultExitCode = ExitFailure 1
        , modelResultStdout = ""
        , modelResultStderr = err
        }
    Success output ->
      ModelResult
        { modelResultName = tlaModelFile model
        , modelResultCommand = command
        , modelResultExitCode = processExitCode output
        , modelResultStdout = processStdout output
        , modelResultStderr = processStderr output
        }

dockerCommand :: FilePath -> TlaModel -> [String]
dockerCommand tlaDir model =
  [ "docker"
  , "run"
  , "--rm"
  , "--entrypoint"
  , ""
  , "--volume"
  , tlaDir ++ ":/workspace"
  , "--workdir"
  , "/workspace"
  , "maxdiefenbach/tlaplus"
  , "java"
  , "-XX:+UseParallelGC"
  , "-cp"
  , "/opt/TLA+Toolbox/tla2tools.jar"
  , "tlc2.TLC"
  , "-workers"
  , "8"
  , "-config"
  , tlaConfigFile model
  , tlaModelFile model
  ]

renderModelResult :: ModelResult -> String
renderModelResult result =
  unlines
    [ "model: " ++ modelResultName result
    , "command: " ++ unwords (modelResultCommand result)
    , "returncode: " ++ show (exitCodeInt (modelResultExitCode result))
    , "stdout:"
    , modelResultStdout result
    , "stderr:"
    , modelResultStderr result
    ]

writeResult :: FilePath -> String -> IO ()
writeResult resultPath content = do
  createDirectoryIfMissing True (takeDirectory resultPath)
  writeFile resultPath content

exitCodeInt :: ExitCode -> Int
exitCodeInt ExitSuccess = 0
exitCodeInt (ExitFailure code) = code
