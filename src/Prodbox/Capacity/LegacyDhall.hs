{-# LANGUAGE OverloadedStrings #-}

module Prodbox.Capacity.LegacyDhall
  ( PlatformPlanLocation (..)
  , DhallFileProjection (..)
  , decodeDhallWithLegacyPlatformDemand
  , decodeDhallFileWithLegacyPlatformDemand
  , decodeDhallSourceWithLegacyPlatformDemand
  , decodeProjectParametersFileWithLegacyPlatformDemand
  , decodeDhallFileProjection
  , decodeDhallSourceProjection
  )
where

import Control.Exception (SomeAsyncException, SomeException, fromException, tryJust)
import Data.Functor.Identity (Identity (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Dhall qualified
import Prodbox.Capacity.Config (ResourceVector, WorkloadResourceProfile)
import System.Directory (makeAbsolute)
import System.FilePath (takeDirectory)

data PlatformPlanLocation = ProjectParameters | StandaloneParameters
  deriving (Eq, Show)

data DhallFileProjection
  = CompleteDocument
  | ParametersFromProject
  | ContextCoordinates
  | ContextFromProject
  deriving (Eq, Show)

data LegacyResourcePlan
  = LegacyResourcePlan
      !ResourceVector
      !ResourceVector
      !ResourceVector
      ![WorkloadResourceProfile]

legacyResourcePlanDecoder :: Dhall.Decoder LegacyResourcePlan
legacyResourcePlanDecoder =
  Dhall.record
    ( LegacyResourcePlan
        <$> Dhall.field "host_capacity" Dhall.auto
        <*> Dhall.field "rke2_reserved" Dhall.auto
        <*> Dhall.field "eviction_floor" Dhall.auto
        <*> Dhall.field "workload_profiles" Dhall.auto
    )

-- A legacy omission gains an explicit non-authorizing Nothing in memory.
-- Exact old-record decoding prevents this path from replacing a present bad
-- declaration. Neither decode changes the file or mints a capacity proof.
decodeDhallWithLegacyPlatformDemand
  :: Dhall.Decoder value
  -> PlatformPlanLocation
  -> Text
  -> IO (Either SomeException value)
decodeDhallWithLegacyPlatformDemand = decodeWithSettings Dhall.defaultInputSettings

decodeWithSettings
  :: Dhall.InputSettings
  -> Dhall.Decoder value
  -> PlatformPlanLocation
  -> Text
  -> IO (Either SomeException value)
decodeWithSettings settings decoder location expression = do
  current <- trySynchronous (Dhall.inputWithSettings settings decoder expression)
  case current of
    Right value -> pure (Right value)
    Left originalError -> do
      legacy <-
        trySynchronous
          (Dhall.inputWithSettings settings legacyResourcePlanDecoder (legacyProjection location expression))
      case legacy of
        Left _ -> pure (Left originalError)
        Right _ -> do
          migrated <-
            trySynchronous (Dhall.inputWithSettings settings decoder (withExplicitMissing location expression))
          pure $ case migrated of
            Left _ -> Left originalError
            Right value -> Right value

decodeDhallFileWithLegacyPlatformDemand
  :: Dhall.Decoder value
  -> PlatformPlanLocation
  -> FilePath
  -> IO (Either SomeException value)
decodeDhallFileWithLegacyPlatformDemand decoder location path =
  withFileInput path $ \settings source -> decodeWithSettings settings decoder location source

-- Host publication decodes the exact descriptor-opened source snapshot rather
-- than reopening a path that may have changed. Relative imports keep their
-- original directory and diagnostic source name.
decodeDhallSourceWithLegacyPlatformDemand
  :: Dhall.Decoder value
  -> PlatformPlanLocation
  -> FilePath
  -> Text
  -> IO (Either SomeException value)
decodeDhallSourceWithLegacyPlatformDemand decoder location path source = do
  absolute <- trySynchronous (makeAbsolute path)
  case absolute of
    Left failure -> pure (Left failure)
    Right absolutePath -> decodeWithSettings (fileInputSettings absolutePath) decoder location source

decodeProjectParametersFileWithLegacyPlatformDemand
  :: Dhall.Decoder value -> FilePath -> IO (Either SomeException value)
decodeProjectParametersFileWithLegacyPlatformDemand decoder path =
  withFileInput path $ \settings source ->
    decodeWithSettings
      settings
      decoder
      StandaloneParameters
      (projectSource ParametersFromProject source)

decodeDhallFileProjection
  :: Dhall.Decoder value -> DhallFileProjection -> FilePath -> IO (Either SomeException value)
decodeDhallFileProjection decoder projection path =
  withFileInput path $ \settings source ->
    trySynchronous (Dhall.inputWithSettings settings decoder (projectSource projection source))

decodeDhallSourceProjection
  :: Dhall.Decoder value -> DhallFileProjection -> FilePath -> Text -> IO (Either SomeException value)
decodeDhallSourceProjection decoder projection path source = do
  absolute <- trySynchronous (makeAbsolute path)
  case absolute of
    Left failure -> pure (Left failure)
    Right absolutePath ->
      trySynchronous
        (Dhall.inputWithSettings (fileInputSettings absolutePath) decoder (projectSource projection source))

-- Paths remain filesystem values. Parsing retains the file's source name and
-- relative-import directory, including spaces and quoted path components.
withFileInput
  :: FilePath
  -> (Dhall.InputSettings -> Text -> IO (Either SomeException value))
  -> IO (Either SomeException value)
withFileInput path action = do
  loaded <- trySynchronous $ do
    absolutePath <- makeAbsolute path
    source <- TextIO.readFile absolutePath
    pure (absolutePath, source)
  case loaded of
    Left failure -> pure (Left failure)
    Right (absolutePath, source) -> do
      action (fileInputSettings absolutePath) source

fileInputSettings :: FilePath -> Dhall.InputSettings
fileInputSettings absolutePath =
  let directorySettings =
        runIdentity
          (Dhall.rootDirectory (const (Identity (takeDirectory absolutePath))) Dhall.defaultInputSettings)
   in runIdentity (Dhall.sourceName (const (Identity absolutePath)) directorySettings)

projectSource :: DhallFileProjection -> Text -> Text
projectSource projection source = case projection of
  CompleteDocument -> source
  ParametersFromProject -> parenthesize source <> ".parameters"
  ContextFromProject -> parenthesize source <> ".context"
  ContextCoordinates ->
    "let context = "
      <> parenthesize source
      <> ".context in context.{ cluster_id, vault_address, minio_endpoint, rpc_registration }"

parenthesize :: Text -> Text
parenthesize source = "(\n" <> source <> "\n)"

trySynchronous :: IO value -> IO (Either SomeException value)
trySynchronous = tryJust synchronous
 where
  synchronous failure = case fromException failure :: Maybe SomeAsyncException of
    Just _ -> Nothing
    Nothing -> Just failure

legacyProjection :: PlatformPlanLocation -> Text -> Text
legacyProjection location expression =
  parenthesize expression <> "." <> case location of
    ProjectParameters -> "parameters.capacity.resource_plan"
    StandaloneParameters -> "capacity.resource_plan"

withExplicitMissing :: PlatformPlanLocation -> Text -> Text
withExplicitMissing location expression =
  Text.unlines
    ( [ "let legacy = " <> expression
      , "let RV = { milli_cpu : Natural, memory_mib : Natural, ephemeral_storage_mib : Natural, durable_storage_mib : Natural }"
      ]
        ++ case location of
          ProjectParameters ->
            [ "in legacy // { parameters = legacy.parameters // { capacity = legacy.parameters.capacity // { resource_plan = legacy.parameters.capacity.resource_plan // { platform_scheduler_requests = None RV } } } }"
            ]
          StandaloneParameters ->
            [ "in legacy // { capacity = legacy.capacity // { resource_plan = legacy.capacity.resource_plan // { platform_scheduler_requests = None RV } } }"
            ]
    )
