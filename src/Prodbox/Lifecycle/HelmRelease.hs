{-# LANGUAGE DerivingStrategies #-}

-- | Exact Helm-release desired-absence reconciliation.
--
-- A failed @helm status@ is not generally absence: only Helm's exact
-- release-not-found diagnostic is. Once uninstall is attempted the release is
-- always re-observed, and success requires a positive absence observation.
module Prodbox.Lifecycle.HelmRelease
  ( HelmReleaseCoordinate
  , HelmReleaseCoordinateError (..)
  , HelmReleaseObservation (..)
  , HelmReleaseHooks (..)
  , HelmReleaseAbsenceRun (..)
  , HelmReleaseAbsenceFailure (..)
  , mkHelmReleaseCoordinate
  , observeHelmRelease
  , classifyHelmReleaseStatus
  , reconcileHelmReleaseAbsentWith
  , reconcileHelmReleaseAbsent
  )
where

import Data.Char (isAsciiLower, isDigit, toLower)
import Data.List (isInfixOf)
import Prodbox.Result (Result (..))
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  )
import System.Exit (ExitCode (..))

data HelmReleaseCoordinate = HelmReleaseCoordinate
  { helmReleaseName :: !String
  , helmReleaseNamespace :: !String
  }
  deriving stock (Eq, Show)

data HelmReleaseCoordinateError
  = HelmReleaseNameInvalid !String
  | HelmReleaseNamespaceInvalid !String
  deriving stock (Eq, Show)

data HelmReleaseObservation
  = HelmReleaseAbsent
  | HelmReleasePresent
  | HelmReleaseUnobservable !String
  deriving stock (Eq, Show)

data HelmReleaseHooks m = HelmReleaseHooks
  { helmObserve :: m HelmReleaseObservation
  , helmUninstall :: m (Either String ())
  }

data HelmReleaseAbsenceRun
  = HelmReleaseAlreadyAbsent
  | HelmReleaseRemovedAndVerified
  deriving stock (Eq, Show)

data HelmReleaseAbsenceFailure
  = HelmReleaseInitialObservationFailed !String
  | HelmReleaseUninstallFailed !String !HelmReleaseObservation
  | HelmReleaseAbsencePostconditionFailed !HelmReleaseObservation
  deriving stock (Eq, Show)

mkHelmReleaseCoordinate
  :: String
  -> String
  -> Either HelmReleaseCoordinateError HelmReleaseCoordinate
mkHelmReleaseCoordinate releaseName namespace
  | not (validDnsLabel releaseName) = Left (HelmReleaseNameInvalid releaseName)
  | not (validDnsLabel namespace) = Left (HelmReleaseNamespaceInvalid namespace)
  | otherwise = Right (HelmReleaseCoordinate releaseName namespace)

validDnsLabel :: String -> Bool
validDnsLabel value =
  case (value, reverse value) of
    (first : _, final : _) ->
      length value <= 63
        && validEdge first
        && validEdge final
        && all validCharacter value
    _ -> False
 where
  validCharacter character = validEdge character || character == '-'
  validEdge character = isAsciiLower character || isDigit character

observeHelmRelease :: FilePath -> HelmReleaseCoordinate -> IO HelmReleaseObservation
observeHelmRelease repoRoot coordinate = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "helm"
        , subprocessArguments =
            [ "status"
            , helmReleaseName coordinate
            , "--namespace"
            , helmReleaseNamespace coordinate
            , "--output"
            , "json"
            ]
        , subprocessEnvironment = Nothing
        , subprocessWorkingDirectory = Just repoRoot
        }
  pure $ case result of
    Failure detail -> HelmReleaseUnobservable ("failed to start helm: " ++ detail)
    Success output -> classifyHelmReleaseStatus output

classifyHelmReleaseStatus :: ProcessOutput -> HelmReleaseObservation
classifyHelmReleaseStatus output =
  case processExitCode output of
    ExitSuccess -> HelmReleasePresent
    ExitFailure _
      | any (`isInfixOf` rendered) exactAbsentFragments -> HelmReleaseAbsent
      | otherwise -> HelmReleaseUnobservable (processStderr output ++ processStdout output)
 where
  rendered = map toLower (processStderr output ++ processStdout output)
  exactAbsentFragments =
    [ "release: not found"
    , "release not found"
    ]

reconcileHelmReleaseAbsentWith
  :: (Monad m)
  => HelmReleaseHooks m
  -> m (Either HelmReleaseAbsenceFailure HelmReleaseAbsenceRun)
reconcileHelmReleaseAbsentWith hooks = do
  initial <- helmObserve hooks
  case initial of
    HelmReleaseAbsent -> pure (Right HelmReleaseAlreadyAbsent)
    HelmReleaseUnobservable detail ->
      pure (Left (HelmReleaseInitialObservationFailed detail))
    HelmReleasePresent -> do
      uninstallResult <- helmUninstall hooks
      final <- helmObserve hooks
      pure $ case uninstallResult of
        Left detail -> Left (HelmReleaseUninstallFailed detail final)
        Right () -> case final of
          HelmReleaseAbsent -> Right HelmReleaseRemovedAndVerified
          _ -> Left (HelmReleaseAbsencePostconditionFailed final)

reconcileHelmReleaseAbsent
  :: FilePath
  -> HelmReleaseCoordinate
  -> IO (Either HelmReleaseAbsenceFailure HelmReleaseAbsenceRun)
reconcileHelmReleaseAbsent repoRoot coordinate =
  reconcileHelmReleaseAbsentWith
    HelmReleaseHooks
      { helmObserve = observeHelmRelease repoRoot coordinate
      , helmUninstall = uninstall
      }
 where
  uninstall = do
    result <-
      captureSubprocessResult
        Subprocess
          { subprocessPath = "helm"
          , subprocessArguments =
              [ "uninstall"
              , helmReleaseName coordinate
              , "--namespace"
              , helmReleaseNamespace coordinate
              , "--ignore-not-found"
              ]
          , subprocessEnvironment = Nothing
          , subprocessWorkingDirectory = Just repoRoot
          }
    pure $ case result of
      Failure detail -> Left ("failed to start helm: " ++ detail)
      Success output -> case processExitCode output of
        ExitSuccess -> Right ()
        ExitFailure _ -> Left (processStderr output ++ processStdout output)
