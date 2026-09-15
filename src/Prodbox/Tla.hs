module Prodbox.Tla
  ( TlaExpectation (..)
  , TlaModel (..)
  , runTlaCheck
  , tlaModelDirectory
  , tlaModels
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
  let tlaDir = repoRoot ++ "/" ++ tlaModelDirectory
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
        ( if all modelResultMatchesExpectation results
            then ExitSuccess
            else ExitFailure 1
        )

-- | Sprint 5.48: what TLC is expected to report for a registered
-- configuration.
--
-- A model that is only ever run in the configuration it passes under has been
-- observed to pass, never to refuse. Registering the frozen superseded
-- ordering alongside the repaired one, and refusing when it does /not/ produce
-- a counterexample, is how this surface proves its invariant can fail --
-- the same discipline a counterexample fixture uses against a frozen
-- implementation.
data TlaExpectation
  = ExpectsNoCounterexample
  | ExpectsCounterexample
  deriving (Eq, Show)

data TlaModel = TlaModel
  { tlaModelFile :: FilePath
  , tlaConfigFile :: FilePath
  , tlaExpectation :: TlaExpectation
  }

-- | The governed directory every registered model file lives in.
tlaModelDirectory :: FilePath
tlaModelDirectory = "documents/engineering/tla"

tlaModels :: [TlaModel]
tlaModels =
  [ TlaModel "gateway_orders_rule.tla" "gateway_orders_rule.cfg" ExpectsNoCounterexample
  , TlaModel "gateway_legacy_liveness.tla" "gateway_legacy_liveness.cfg" ExpectsNoCounterexample
  , TlaModel
      "lifecycle_create_ownership.tla"
      "lifecycle_create_ownership.cfg"
      ExpectsNoCounterexample
  , TlaModel
      "lifecycle_create_ownership.tla"
      "lifecycle_create_ownership_superseded.cfg"
      ExpectsCounterexample
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
  , modelResultExpectation :: TlaExpectation
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
        { modelResultName = modelLabel model
        , modelResultExpectation = tlaExpectation model
        , modelResultCommand = command
        , modelResultExitCode = ExitFailure 1
        , modelResultStdout = ""
        , modelResultStderr = err
        }
    Success output ->
      ModelResult
        { modelResultName = modelLabel model
        , modelResultExpectation = tlaExpectation model
        , modelResultCommand = command
        , modelResultExitCode = processExitCode output
        , modelResultStdout = processStdout output
        , modelResultStderr = processStderr output
        }

-- | Sprint 5.48: a registered configuration is satisfied when TLC's
-- disposition is the one the registry declares, not when it is success.
modelResultMatchesExpectation :: ModelResult -> Bool
modelResultMatchesExpectation result =
  case (modelResultExpectation result, modelResultExitCode result) of
    (ExpectsNoCounterexample, ExitSuccess) -> True
    (ExpectsNoCounterexample, ExitFailure _) -> False
    (ExpectsCounterexample, ExitSuccess) -> False
    (ExpectsCounterexample, ExitFailure _) -> True

-- | A registered model is identified by its configuration as well as its
-- module, because one module is checked under two.
modelLabel :: TlaModel -> String
modelLabel model = tlaModelFile model ++ " (" ++ tlaConfigFile model ++ ")"

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
  , -- Sprint 5.48: a registered configuration is expected to produce a
    -- counterexample, so the run leaves trace-expression and state scratch
    -- behind unless it is told not to. Both flags keep a governed directory
    -- free of root-owned output this host cannot delete.
    "-cleanup"
  , "-noGenerateSpecTE"
  , "-config"
  , tlaConfigFile model
  , tlaModelFile model
  ]

renderModelResult :: ModelResult -> String
renderModelResult result =
  unlines
    [ "model: " ++ modelResultName result
    , "expectation: " ++ show (modelResultExpectation result)
    , "satisfied: " ++ show (modelResultMatchesExpectation result)
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
