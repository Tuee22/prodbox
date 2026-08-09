{-# LANGUAGE DerivingStrategies #-}

-- | Exact Helm-release desired-absence reconciliation.
--
-- A failed @helm status@ is not generally absence: only Helm's exact
-- release-not-found diagnostic is. Once uninstall is attempted the release is
-- always re-observed, and success requires a positive absence observation.
module Prodbox.Lifecycle.HelmRelease
  ( HelmReleaseCoordinate
  , HelmReleaseCoordinateError (..)
  , HelmReleaseStatus (..)
  , helmReleaseStatusText
  , parseHelmReleaseStatus
  , helmReleaseStatusPermitsWrite
  , HelmWritePermit
  , helmWritePermitCoordinate
  , HelmWriteRefusal (..)
  , renderHelmWriteRefusal
  , helmWritePermit
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

import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (isAsciiLower, isDigit, isSpace, toLower)
import Data.List (isInfixOf)
import Data.Text qualified as Text
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

-- | Sprint 3.31: every status Helm reports in @.info.status@.
--
-- The superseded observation derived presence from @helm status@'s __exit
-- code__, so @deployed@, @failed@, @pending-install@, @pending-upgrade@,
-- @pending-rollback@, @uninstalling@, and @superseded@ collapsed into one
-- constructor — while @--output json@ was already being requested and
-- @.info.status@ discarded. That is the *Provenance* class of
-- [chaos_hardening_doctrine.md § 21](../../../documents/engineering/chaos_hardening_doctrine.md):
-- a value whose legality depends on where it came from, decoded from the weakest
-- available signal.
data HelmReleaseStatus
  = HelmStatusDeployed
  | HelmStatusFailed
  | HelmStatusPendingInstall
  | HelmStatusPendingUpgrade
  | HelmStatusPendingRollback
  | HelmStatusUninstalling
  | HelmStatusUninstalled
  | HelmStatusSuperseded
  deriving stock (Bounded, Enum, Eq, Show)

helmReleaseStatusText :: HelmReleaseStatus -> String
helmReleaseStatusText status = case status of
  HelmStatusDeployed -> "deployed"
  HelmStatusFailed -> "failed"
  HelmStatusPendingInstall -> "pending-install"
  HelmStatusPendingUpgrade -> "pending-upgrade"
  HelmStatusPendingRollback -> "pending-rollback"
  HelmStatusUninstalling -> "uninstalling"
  HelmStatusUninstalled -> "uninstalled"
  HelmStatusSuperseded -> "superseded"

-- | Decode a reported status. 'Nothing' for anything unrecognised, which the
-- observation turns into 'HelmReleaseUnobservable' rather than defaulting to
-- present or absent — a status nobody has seen before says nothing about
-- whether the release is there.
parseHelmReleaseStatus :: String -> Maybe HelmReleaseStatus
parseHelmReleaseStatus raw =
  lookup
    (map toLower (trim raw))
    [(helmReleaseStatusText status, status) | status <- [minBound .. maxBound]]
 where
  trim = dropWhile isSpace . reverse . dropWhile isSpace . reverse

-- | Whether a release in this status may be mutated by this process.
--
-- The four pending/uninstalling states mean another writer holds the release.
-- Answering that with a destroy is the defect: Helm's
-- @"another operation (install\/upgrade\/rollback) is in progress"@ is the
-- __concurrency__ error, so an unconditional uninstall deletes the release the
-- other writer is mid-install on.
helmReleaseStatusPermitsWrite :: HelmReleaseStatus -> Bool
helmReleaseStatusPermitsWrite status = case status of
  HelmStatusDeployed -> True
  HelmStatusFailed -> True
  HelmStatusSuperseded -> True
  HelmStatusUninstalled -> True
  HelmStatusPendingInstall -> False
  HelmStatusPendingUpgrade -> False
  HelmStatusPendingRollback -> False
  HelmStatusUninstalling -> False

-- | Sprint 3.31: permission to mutate one release.
--
-- The constructor is hidden and 'helmWritePermit' is the only producer, so a
-- mutating helper cannot be called without an observation that said the release
-- is not being written by somebody else. A concurrency refusal therefore
-- resolves to a typed value that __cannot__ be answered by a destroy, because a
-- destroy needs the permit it was refused.
newtype HelmWritePermit = HelmWritePermit HelmReleaseCoordinate
  deriving stock (Eq, Show)

helmWritePermitCoordinate :: HelmWritePermit -> HelmReleaseCoordinate
helmWritePermitCoordinate (HelmWritePermit coordinate) = coordinate

data HelmWriteRefusal
  = -- | Another writer holds the release.
    HelmWriteConcurrentOperation !HelmReleaseStatus
  | -- | The release could not be observed, so nothing may be assumed.
    HelmWriteUnobservable !String
  deriving stock (Eq, Show)

renderHelmWriteRefusal :: HelmReleaseCoordinate -> HelmWriteRefusal -> String
renderHelmWriteRefusal coordinate refusal = case refusal of
  HelmWriteConcurrentOperation status ->
    "refusing to mutate helm release `"
      ++ helmReleaseName coordinate
      ++ "` in namespace `"
      ++ helmReleaseNamespace coordinate
      ++ "`: it is "
      ++ helmReleaseStatusText status
      ++ ", which means another install/upgrade/rollback holds it. Wait for that "
      ++ "operation or roll it back; deleting the release would destroy the one "
      ++ "the other writer is mid-operation on."
  HelmWriteUnobservable detail ->
    "refusing to mutate helm release `"
      ++ helmReleaseName coordinate
      ++ "` in namespace `"
      ++ helmReleaseNamespace coordinate
      ++ "`: it cannot be observed ("
      ++ detail
      ++ "), and an unobservable release is never assumed safe to write."

-- | The sole permit producer.
helmWritePermit
  :: HelmReleaseCoordinate
  -> HelmReleaseObservation
  -> Either HelmWriteRefusal HelmWritePermit
helmWritePermit coordinate observation = case observation of
  HelmReleaseAbsent -> Right (HelmWritePermit coordinate)
  HelmReleaseUnobservable detail -> Left (HelmWriteUnobservable detail)
  HelmReleasePresent status
    | helmReleaseStatusPermitsWrite status -> Right (HelmWritePermit coordinate)
    | otherwise -> Left (HelmWriteConcurrentOperation status)

data HelmReleaseObservation
  = HelmReleaseAbsent
  | HelmReleasePresent !HelmReleaseStatus
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
  | -- | Sprint 3.31: another writer holds the release; a destroy is not the
    -- answer to a concurrency error.
    HelmReleaseWriteRefused !HelmWriteRefusal
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

-- | Sprint 3.31: presence is decoded from @.info.status@, which @--output json@
-- was already requesting and this classifier was already discarding. An exit
-- code cannot distinguish @deployed@ from @pending-upgrade@, and that
-- distinction is the difference between a release this process may write and one
-- another writer holds.
classifyHelmReleaseStatus :: ProcessOutput -> HelmReleaseObservation
classifyHelmReleaseStatus output =
  case processExitCode output of
    ExitSuccess ->
      case decodeReportedStatus (processStdout output) of
        Nothing ->
          HelmReleaseUnobservable
            ( "helm status reported no recognisable .info.status: "
                ++ processStdout output
            )
        Just status -> HelmReleasePresent status
    ExitFailure _
      | any (`isInfixOf` rendered) exactAbsentFragments -> HelmReleaseAbsent
      | otherwise -> HelmReleaseUnobservable (processStderr output ++ processStdout output)
 where
  rendered = map toLower (processStderr output ++ processStdout output)
  exactAbsentFragments =
    [ "release: not found"
    , "release not found"
    ]

-- | Pull @.info.status@ out of @helm status --output json@.
decodeReportedStatus :: String -> Maybe HelmReleaseStatus
decodeReportedStatus payload = do
  value <- Aeson.decode (BL8.pack payload)
  root <- asObject value
  info <- KeyMap.lookup (Key.fromString "info") root >>= asObject
  raw <- KeyMap.lookup (Key.fromString "status") info >>= asString
  parseHelmReleaseStatus raw
 where
  asObject value = case value of
    Aeson.Object object -> Just object
    _ -> Nothing
  asString value = case value of
    Aeson.String text -> Just (Text.unpack text)
    _ -> Nothing

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
    HelmReleasePresent status
      -- Sprint 3.31: a release another writer holds is refused here rather than
      -- uninstalled. The reconciler re-observes before acting, and this is the
      -- observation that says acting is not this process's to do.
      | not (helmReleaseStatusPermitsWrite status) ->
          pure (Left (HelmReleaseWriteRefused (HelmWriteConcurrentOperation status)))
      | otherwise -> do
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
