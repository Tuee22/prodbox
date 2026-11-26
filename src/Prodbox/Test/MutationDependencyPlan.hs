{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Select the exact installed dependency graph for the mutation test.
module Prodbox.Test.MutationDependencyPlan
  ( MutationDependencyPlan (..)
  , MutationDependency (..)
  , selectMutationDependencyPlan
  ) where

import Control.Monad (guard)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString qualified as ByteString
import Data.Char (isAsciiLower, isAsciiUpper)
import Data.List (isPrefixOf)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set

data MutationDependencyPlan = MutationDependencyPlan
  { dependencyCompilerDirectory :: !String
  , dependencyUnits :: ![MutationDependency]
  }
  deriving (Eq, Show)

data MutationDependency = MutationDependency
  { dependencyUnitId :: !String
  , dependencySourceDigest :: !String
  , dependencyHasRegistration :: !Bool
  }
  deriving (Eq, Show)

data PlanUnit = PlanUnit
  { unitId :: !String
  , unitPackage :: !String
  , unitComponent :: !String
  , unitRequires :: ![String]
  , unitCustody :: !UnitCustody
  }

data UnitCustody
  = LocalUnit
  | CompilerUnit
  | InstalledUnit !String
  | UntrustedUnit
  deriving (Eq)

selectMutationDependencyPlan :: ByteString.ByteString -> Either String MutationDependencyPlan
selectMutationDependencyPlan bytes
  | ByteString.null bytes || ByteString.length bytes > 4 * 1024 * 1024 =
      Left "dependency plan exceeds its byte bound"
  | otherwise = Aeson.eitherDecodeStrict' bytes >>= parseEither parsePlan

parsePlan :: Aeson.Value -> Parser MutationDependencyPlan
parsePlan = Aeson.withObject "Cabal dependency plan" $ \plan -> do
  compiler <- plan Aeson..: "compiler-id"
  abi <- plan Aeson..: "compiler-abi"
  entries <- plan Aeson..: "install-plan"
  guard (compiler == "ghc-9.12.4" && validHex 4 16 abi && length entries <= 4096)
  units <- traverse parseUnit entries
  let byId = Map.fromList [(unitId unit, unit) | unit <- units]
  guard (Map.size byId == length units)
  test <- exactUnit "local unit test component" $ filter isMutationTest units
  setup <- exactUnit "Cabal setup library" $ filter isCabalSetup units
  selected <- closeUnits byId Set.empty [unitId test, unitId setup]
  dependencies <- concat <$> traverse selectUnit selected
  guard (not (null dependencies))
  pure (MutationDependencyPlan (compiler ++ "-" ++ abi) dependencies)
 where
  isMutationTest unit =
    unitCustody unit == LocalUnit
      && unitPackage unit == "prodbox"
      && unitComponent unit == "test:prodbox-unit"
  isCabalSetup unit =
    unitPackage unit == "Cabal" && unitComponent unit == "lib"
  exactUnit _ [unit] = pure unit
  exactUnit name _ = fail (name ++ " missing or ambiguous")
  selectUnit unit = case unitCustody unit of
    LocalUnit -> if unitPackage unit == "prodbox" then pure [] else fail "foreign local dependency"
    CompilerUnit -> pure []
    InstalledUnit source -> pure [MutationDependency (unitId unit) source (not ("exe:" `isPrefixOf` unitComponent unit))]
    UntrustedUnit -> fail "selected dependency is outside the public package index"

parseUnit :: Aeson.Value -> Parser PlanUnit
parseUnit = Aeson.withObject "Cabal plan unit" $ \fields -> do
  identifier <- fields Aeson..: "id"
  package <- fields Aeson..: "pkg-name"
  component <- fromMaybe "" <$> fields Aeson..:? "component-name"
  requires <- fromMaybe [] <$> fields Aeson..:? "depends"
  tools <- fromMaybe [] <$> fields Aeson..:? "exe-depends"
  kind <- fields Aeson..: "type"
  style <- fields Aeson..:? "style"
  source <- fields Aeson..:? "pkg-src"
  digest <- fields Aeson..:? "pkg-src-sha256"
  guard
    (validUnitId identifier && length (requires ++ tools) <= 4096 && all validUnitId (requires ++ tools))
  pure (PlanUnit identifier package component (requires ++ tools) (custody kind style source digest))
 where
  custody :: String -> Maybe String -> Maybe Aeson.Value -> Maybe String -> UnitCustody
  custody kind style source digest = case (kind, style, source, digest) of
    ("pre-existing", Nothing, Nothing, Nothing) -> CompilerUnit
    ("configured", Just "local", _, _) -> LocalUnit
    ("configured", Just "global", Just location, Just expected)
      | validHex 64 64 expected && parseEither publicIndex location == Right () -> InstalledUnit expected
    _ -> UntrustedUnit
  publicIndex = Aeson.withObject "package source" $ \source -> do
    kind <- source Aeson..: "type"
    repo <- source Aeson..: "repo"
    guard ((kind :: String) == "repo-tar")
    Aeson.withObject
      "public package repository"
      ( \fields -> do
          repoKind <- fields Aeson..: "type"
          uri <- fields Aeson..: "uri"
          guard
            ( (repoKind :: String) == "secure-repo"
                && (uri :: String) `elem` ["http://hackage.haskell.org/", "https://hackage.haskell.org/"]
            )
      )
      repo

closeUnits :: Map.Map String PlanUnit -> Set.Set String -> [String] -> Parser [PlanUnit]
closeUnits available seen pending = case pending of
  [] -> pure [unit | (identifier, unit) <- Map.toAscList available, Set.member identifier seen]
  identifier : rest
    | Set.member identifier seen -> closeUnits available seen rest
    | otherwise -> case Map.lookup identifier available of
        Nothing -> fail "dependency reference absent from the plan"
        Just unit -> closeUnits available (Set.insert identifier seen) (unitRequires unit ++ rest)

validUnitId :: String -> Bool
validUnitId [] = False
validUnitId value@(first : _) = length value <= 192 && first /= '.' && all allowed value
 where
  allowed c = isAsciiLower c || isAsciiUpper c || decimal c || c `elem` ("-._+" :: String)

validHex :: Int -> Int -> String -> Bool
validHex minimumLength maximumLength value =
  length value >= minimumLength
    && length value <= maximumLength
    && all (\c -> decimal c || c >= 'a' && c <= 'f') value

decimal :: Char -> Bool
decimal c = c >= '0' && c <= '9'
