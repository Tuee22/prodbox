module Prodbox.CLI.Pulumi
  ( EphemeralPulumiStack (..)
  , EphemeralPulumiOutputs (..)
  , readEphemeralPulumiOutputs
  , renderPulumiPlan
  , runPulumiCommand
  , withEphemeralPulumiStack
  , writeEphemeralPulumiOutputs
  )
where

import Control.Exception (bracketOnError, finally)
import Data.Aeson
  ( Value (..)
  , eitherDecode
  , encode
  , object
  , (.=)
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Prodbox.CLI.Command
  ( Plan
  , PulumiCommand (..)
  , buildPlan
  , runPlanWithOptions
  )
import Prodbox.Infra.AwsEksSubzoneStack qualified as SubzoneStack
import Prodbox.Infra.AwsEksTestStack qualified as EksStack
import Prodbox.Infra.AwsSesStack qualified as SesStack
import Prodbox.Infra.AwsTestStack qualified as TestStack
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , removeFile
  , removePathForcibly
  )
import System.Exit (ExitCode)
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)

data EphemeralPulumiStack = EphemeralPulumiStack
  { ephemeralPulumiStackName :: String
  , ephemeralPulumiStackRoot :: FilePath
  , ephemeralPulumiOutputsPath :: FilePath
  }
  deriving (Eq, Show)

data EphemeralPulumiOutputs = EphemeralPulumiOutputs
  { ephemeralOutputsStackName :: String
  , ephemeralOutputsValues :: Map String String
  }
  deriving (Eq, Show)

runPulumiCommand :: FilePath -> PulumiCommand -> IO ExitCode
runPulumiCommand repoRoot command =
  case command of
    PulumiEksResources planOptions ->
      runPlanWithOptions
        planOptions
        (buildPulumiExecutionPlan "eks-resources" False)
        (\_ -> EksStack.ensureAwsEksTestStackResources repoRoot)
    PulumiEksDestroy summary planOptions ->
      runPlanWithOptions
        planOptions
        (buildPulumiExecutionPlan "eks-destroy" summary)
        (\_ -> EksStack.destroyAwsEksTestStack repoRoot summary)
    PulumiTestResources planOptions ->
      runPlanWithOptions
        planOptions
        (buildPulumiExecutionPlan "test-resources" False)
        (\_ -> TestStack.ensureAwsTestStackResources repoRoot)
    PulumiTestDestroy summary planOptions ->
      runPlanWithOptions
        planOptions
        (buildPulumiExecutionPlan "test-destroy" summary)
        (\_ -> TestStack.destroyAwsTestStack repoRoot summary)
    PulumiAwsSubzoneResources planOptions ->
      runPlanWithOptions
        planOptions
        (buildPulumiExecutionPlan "aws-subzone-resources" False)
        (\_ -> SubzoneStack.ensureAwsEksSubzoneStackResources repoRoot)
    PulumiAwsSubzoneDestroy summary planOptions ->
      runPlanWithOptions
        planOptions
        (buildPulumiExecutionPlan "aws-subzone-destroy" summary)
        (\_ -> SubzoneStack.destroyAwsEksSubzoneStack repoRoot summary)
    PulumiAwsSesResources planOptions ->
      runPlanWithOptions
        planOptions
        (buildPulumiExecutionPlan "aws-ses-resources" False)
        (\_ -> SesStack.ensureAwsSesStackResources repoRoot)
    PulumiAwsSesDestroy summary planOptions ->
      runPlanWithOptions
        planOptions
        (buildPulumiExecutionPlan "aws-ses-destroy" summary)
        (\_ -> SesStack.destroyAwsSesStack repoRoot summary)
    PulumiAwsSesMigrateBackend planOptions ->
      runPlanWithOptions
        planOptions
        (buildPulumiExecutionPlan "aws-ses-migrate-backend" False)
        (\_ -> SesStack.migrateAwsSesStackBackend repoRoot)

buildPulumiExecutionPlan :: String -> Bool -> Plan String
buildPulumiExecutionPlan commandName confirmed =
  buildPlan id (renderPulumiPlan commandName confirmed)

renderPulumiPlan :: String -> Bool -> String
renderPulumiPlan commandName confirmed =
  unlines
    [ "PULUMI_PLAN"
    , "COMMAND=" ++ commandName
    , "CONFIRMED=" ++ if confirmed then "true" else "false"
    ]

withEphemeralPulumiStack :: FilePath -> String -> (EphemeralPulumiStack -> IO value) -> IO value
withEphemeralPulumiStack parentDir stackPrefix action = do
  createDirectoryIfMissing True parentDir
  bracketOnError
    (createEphemeralPulumiStack parentDir stackPrefix)
    cleanupEphemeralPulumiStack
    (\stack -> finally (action stack) (cleanupEphemeralPulumiStack stack))

writeEphemeralPulumiOutputs :: EphemeralPulumiStack -> Map String String -> IO ()
writeEphemeralPulumiOutputs stack outputs =
  BL8.writeFile
    (ephemeralPulumiOutputsPath stack)
    ( encode
        ( object
            [ Key.fromString "stack_name" .= ephemeralPulumiStackName stack
            , Key.fromString "outputs" .= outputs
            ]
        )
    )

readEphemeralPulumiOutputs :: EphemeralPulumiStack -> IO (Either String EphemeralPulumiOutputs)
readEphemeralPulumiOutputs stack = do
  contents <- BL8.readFile (ephemeralPulumiOutputsPath stack)
  pure $
    case eitherDecode contents of
      Left err -> Left ("failed to parse ephemeral Pulumi outputs: " ++ err)
      Right value -> decodeEphemeralPulumiOutputs value

createEphemeralPulumiStack :: FilePath -> String -> IO EphemeralPulumiStack
createEphemeralPulumiStack parentDir stackPrefix = do
  (tempPath, handle) <- openTempFile parentDir (stackPrefix ++ "-stack-")
  hClose handle
  removeFile tempPath
  createDirectoryIfMissing True tempPath
  pure
    EphemeralPulumiStack
      { ephemeralPulumiStackName = takeFileName tempPath
      , ephemeralPulumiStackRoot = tempPath
      , ephemeralPulumiOutputsPath = tempPath </> "stack-outputs.json"
      }
 where
  takeFileName = reverse . takeWhile (/= '/') . reverse

cleanupEphemeralPulumiStack :: EphemeralPulumiStack -> IO ()
cleanupEphemeralPulumiStack stack = do
  exists <- doesDirectoryExist (ephemeralPulumiStackRoot stack)
  if exists
    then removePathForcibly (ephemeralPulumiStackRoot stack)
    else pure ()

decodeEphemeralPulumiOutputs :: Value -> Either String EphemeralPulumiOutputs
decodeEphemeralPulumiOutputs (Object obj) = do
  stackName <- requireStringField obj "stack_name"
  outputsValue <- requireObjectField obj "outputs"
  outputPairs <- traverse toOutputPair (KeyMap.toList outputsValue)
  pure
    EphemeralPulumiOutputs
      { ephemeralOutputsStackName = stackName
      , ephemeralOutputsValues = Map.fromList outputPairs
      }
 where
  toOutputPair (key, String value) = Right (Key.toString key, Text.unpack value)
  toOutputPair (key, _) = Left ("output `" ++ show key ++ "` must be a JSON string")
decodeEphemeralPulumiOutputs _ = Left "ephemeral Pulumi outputs must be a JSON object"

requireStringField :: KeyMap.KeyMap Value -> String -> Either String String
requireStringField obj fieldName =
  case KeyMap.lookup (Key.fromString fieldName) obj of
    Just (String value) -> Right (Text.unpack value)
    _ -> Left ("missing string field `" ++ fieldName ++ "`")

requireObjectField :: KeyMap.KeyMap Value -> String -> Either String (KeyMap.KeyMap Value)
requireObjectField obj fieldName =
  case KeyMap.lookup (Key.fromString fieldName) obj of
    Just (Object value) -> Right value
    _ -> Left ("missing object field `" ++ fieldName ++ "`")
