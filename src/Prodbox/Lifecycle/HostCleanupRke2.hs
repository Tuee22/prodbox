{-# LANGUAGE OverloadedStrings #-}

-- | The local-Linux RKE2 terminal adapter for 'HostCleanupRunner'.  Install
-- truth comes only from a closed set of host markers.  Kubernetes API or
-- service reachability is deliberately irrelevant: a stopped control plane
-- with any surviving marker is still installed, while absence requires a
-- fresh, successful no-follow observation of every marker.
module Prodbox.Lifecycle.HostCleanupRke2
  ( LocalRke2InstallMarker (..)
  , canonicalLocalRke2InstallMarkers
  , localRke2InstallMarkerPath
  , LocalRke2MarkerObservation (..)
  , LocalRke2MarkerFailure (..)
  , LocalRke2InstallObservation (..)
  , LocalRke2UninstallRefusal (..)
  , LocalRke2UninstallResult (..)
  , LocalRke2TerminalBoundary (..)
  , LocalRke2TerminalAdapter
  , mkLocalRke2TerminalAdapter
  , productionLocalRke2TerminalAdapter
  , observeLocalRke2Install
  , attemptLocalRke2Uninstall
  , localRke2UninstallResultToHostEffect
  , hostCleanupRunLocalRke2Uninstall
  )
where

import Control.Exception (IOException, try)
import Data.Bifunctor (first)
import Data.List (find)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Error (errorMsg)
import Prodbox.Lifecycle.CleanupRun
  ( CleanupOperationId
  , cleanupOperationIdText
  )
import Prodbox.Lifecycle.HostCleanupRunner
  ( HostCleanupEffectOutcome (..)
  , HostCleanupRunnerContext
  , hostCleanupRunnerUninstallOperationId
  )
import Prodbox.Lifecycle.Teardown.Observation (AbsenceEvidence (..))
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessBounded
  )
import System.Exit (ExitCode (..))
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (FileStatus, getSymbolicLinkStatus)

-- | The complete durable marker universe for one local RKE2 server install.
-- A symlink, including a broken symlink, is present because production uses
-- @lstat(2)@ rather than following it.
data LocalRke2InstallMarker
  = LocalRke2ServerBinaryMarker
  | LocalRke2KillAllScriptMarker
  | LocalRke2UninstallScriptMarker
  | LocalRke2DataDirectoryMarker
  | LocalRke2ConfigDirectoryMarker
  | LocalRke2SystemdUnitMarker
  | LocalRke2SystemdDropInDirectoryMarker
  | LocalRke2SystemdWantsLinkMarker
  deriving (Bounded, Enum, Eq, Ord, Show)

canonicalLocalRke2InstallMarkers :: [LocalRke2InstallMarker]
canonicalLocalRke2InstallMarkers = [minBound .. maxBound]

localRke2InstallMarkerPath :: LocalRke2InstallMarker -> FilePath
localRke2InstallMarkerPath marker = case marker of
  LocalRke2ServerBinaryMarker -> "/usr/local/bin/rke2"
  LocalRke2KillAllScriptMarker -> "/usr/local/bin/rke2-killall.sh"
  LocalRke2UninstallScriptMarker -> "/usr/local/bin/rke2-uninstall.sh"
  LocalRke2DataDirectoryMarker -> "/var/lib/rancher/rke2"
  LocalRke2ConfigDirectoryMarker -> "/etc/rancher/rke2"
  LocalRke2SystemdUnitMarker -> "/etc/systemd/system/rke2-server.service"
  LocalRke2SystemdDropInDirectoryMarker ->
    "/etc/systemd/system/rke2-server.service.d"
  LocalRke2SystemdWantsLinkMarker ->
    "/etc/systemd/system/multi-user.target.wants/rke2-server.service"

data LocalRke2MarkerObservation
  = LocalRke2MarkerPresent
  | LocalRke2MarkerAbsent
  | LocalRke2MarkerUnconfirmed !Text
  deriving (Eq, Show)

data LocalRke2MarkerFailure = LocalRke2MarkerFailure
  { localRke2MarkerFailureMarker :: !LocalRke2InstallMarker
  , localRke2MarkerFailureDetail :: !Text
  }
  deriving (Eq, Show)

-- | Presence wins over an unrelated observation failure because one positive
-- marker is enough to refute absence.  The failures remain attached for
-- diagnostics.  Only the all-observed-absent arm carries absence evidence.
data LocalRke2InstallObservation
  = LocalRke2InstallPresent
      !(NonEmpty LocalRke2InstallMarker)
      ![LocalRke2MarkerFailure]
  | LocalRke2InstallAbsent !AbsenceEvidence
  | LocalRke2InstallUnconfirmed !(NonEmpty LocalRke2MarkerFailure)
  deriving (Eq, Show)

data LocalRke2UninstallRefusal
  = LocalRke2UninstallObservationUnconfirmed
      !(NonEmpty LocalRke2MarkerFailure)
  | LocalRke2UninstallInstalledDamaged
      !(NonEmpty LocalRke2InstallMarker)
  | LocalRke2UninstallCommandFailed !ExitCode !Text
  deriving (Eq, Show)

-- | The stable operation ID is preserved on every arm.  A process-boundary
-- failure is response loss, not proof the uninstaller did not run; the caller
-- must resolve it through a fresh marker read-back.
data LocalRke2UninstallResult
  = LocalRke2UninstallAlreadyAbsent
      !CleanupOperationId
      !AbsenceEvidence
  | LocalRke2UninstallApplied !CleanupOperationId
  | LocalRke2UninstallResponseLost !CleanupOperationId !Text
  | LocalRke2UninstallRefused
      !CleanupOperationId
      !LocalRke2UninstallRefusal
  deriving (Eq, Show)

-- | Injected physical boundary.  Tests can interrupt after applying the
-- command or make individual marker observations unavailable without
-- changing the adapter's target, command, or classification logic.
data LocalRke2TerminalBoundary m = LocalRke2TerminalBoundary
  { localRke2ObserveInstallMarker
      :: LocalRke2InstallMarker -> m LocalRke2MarkerObservation
  , localRke2ExecuteUninstallCommand
      :: CleanupOperationId
      -> Subprocess
      -> m (Either Text ProcessOutput)
  }

data LocalRke2TerminalAdapter m = LocalRke2TerminalAdapter
  { internalLocalRke2WorkingDirectory :: !FilePath
  , internalLocalRke2Boundary :: !(LocalRke2TerminalBoundary m)
  }

mkLocalRke2TerminalAdapter
  :: FilePath
  -> LocalRke2TerminalBoundary m
  -> LocalRke2TerminalAdapter m
mkLocalRke2TerminalAdapter workingDirectory boundary =
  LocalRke2TerminalAdapter
    { internalLocalRke2WorkingDirectory = workingDirectory
    , internalLocalRke2Boundary = boundary
    }

-- | Production uses no Kubernetes command and never reads service state.
-- Marker inspection is no-follow and distinguishes exact ENOENT from every
-- other I/O failure.  The destructive subprocess is physically bounded;
-- any boundary failure remains response loss until markers are re-observed.
productionLocalRke2TerminalAdapter
  :: FilePath -> LocalRke2TerminalAdapter IO
productionLocalRke2TerminalAdapter workingDirectory =
  mkLocalRke2TerminalAdapter
    workingDirectory
    LocalRke2TerminalBoundary
      { localRke2ObserveInstallMarker = observeProductionMarker
      , localRke2ExecuteUninstallCommand = \_operationId spec ->
          first errorMsg <$> captureSubprocessBounded uninstallLimits spec
      }

observeProductionMarker
  :: LocalRke2InstallMarker -> IO LocalRke2MarkerObservation
observeProductionMarker marker = do
  observed <-
    try (getSymbolicLinkStatus (localRke2InstallMarkerPath marker))
      :: IO (Either IOException FileStatus)
  pure $ case observed of
    Right _ -> LocalRke2MarkerPresent
    Left err
      | isDoesNotExistError err -> LocalRke2MarkerAbsent
      | otherwise ->
          LocalRke2MarkerUnconfirmed
            (boundedDetail (Text.pack (show err)))

uninstallLimits :: BoundedSubprocessLimits
uninstallLimits =
  BoundedSubprocessLimits
    { boundedSubprocessMaximumInputBytes = 1
    , boundedSubprocessMaximumStdoutBytes = 1024 * 1024
    , boundedSubprocessMaximumStderrBytes = 1024 * 1024
    , boundedSubprocessTimeoutMicros = 30 * 60 * 1_000_000
    }

observeLocalRke2Install
  :: (Monad m)
  => LocalRke2TerminalAdapter m
  -> m LocalRke2InstallObservation
observeLocalRke2Install adapter = do
  observations <-
    mapM observeMarker canonicalLocalRke2InstallMarkers
  let present =
        [ marker
        | (marker, LocalRke2MarkerPresent) <- observations
        ]
      failures =
        [ LocalRke2MarkerFailure marker (boundedDetail detail)
        | (marker, LocalRke2MarkerUnconfirmed detail) <- observations
        ]
  pure $ case NonEmpty.nonEmpty present of
    Just markers -> LocalRke2InstallPresent markers failures
    Nothing -> case NonEmpty.nonEmpty failures of
      Just unresolved -> LocalRke2InstallUnconfirmed unresolved
      Nothing -> LocalRke2InstallAbsent exactLocalRke2Absence
 where
  boundary = internalLocalRke2Boundary adapter
  observeMarker marker = do
    observed <- localRke2ObserveInstallMarker boundary marker
    pure (marker, observed)

exactLocalRke2Absence :: AbsenceEvidence
exactLocalRke2Absence =
  AbsenceEvidence
    "local-rke2-install/v1: every canonical no-follow install marker was observed absent"

attemptLocalRke2Uninstall
  :: (Monad m)
  => LocalRke2TerminalAdapter m
  -> CleanupOperationId
  -> m LocalRke2UninstallResult
attemptLocalRke2Uninstall adapter operationId = do
  installed <- observeLocalRke2Install adapter
  case installed of
    LocalRke2InstallAbsent evidence ->
      pure (LocalRke2UninstallAlreadyAbsent operationId evidence)
    LocalRke2InstallUnconfirmed failures ->
      pure
        ( LocalRke2UninstallRefused
            operationId
            (LocalRke2UninstallObservationUnconfirmed failures)
        )
    LocalRke2InstallPresent present failures ->
      case uninstallScriptDisposition present failures of
        Left refusal ->
          pure (LocalRke2UninstallRefused operationId refusal)
        Right () -> do
          attempted <-
            localRke2ExecuteUninstallCommand
              (internalLocalRke2Boundary adapter)
              operationId
              (localRke2UninstallSubprocess adapter operationId)
          pure $ case attempted of
            Left detail ->
              LocalRke2UninstallResponseLost
                operationId
                (boundedDetail detail)
            Right output -> case processExitCode output of
              ExitSuccess -> LocalRke2UninstallApplied operationId
              exitCode@(ExitFailure _) ->
                LocalRke2UninstallRefused
                  operationId
                  ( LocalRke2UninstallCommandFailed
                      exitCode
                      (processFailureDetail output)
                  )

uninstallScriptDisposition
  :: NonEmpty LocalRke2InstallMarker
  -> [LocalRke2MarkerFailure]
  -> Either LocalRke2UninstallRefusal ()
uninstallScriptDisposition present failures
  | LocalRke2UninstallScriptMarker `elem` NonEmpty.toList present = Right ()
  | Just scriptFailure <- find isUninstallScriptFailure failures =
      Left
        ( LocalRke2UninstallObservationUnconfirmed
            (scriptFailure NonEmpty.:| filter (/= scriptFailure) failures)
        )
  | otherwise = Left (LocalRke2UninstallInstalledDamaged present)
 where
  isUninstallScriptFailure failure =
    localRke2MarkerFailureMarker failure == LocalRke2UninstallScriptMarker

localRke2UninstallSubprocess
  :: LocalRke2TerminalAdapter m
  -> CleanupOperationId
  -> Subprocess
localRke2UninstallSubprocess adapter operationId =
  Subprocess
    { subprocessPath = "/usr/bin/sudo"
    , subprocessArguments =
        [ "--"
        , "/usr/bin/env"
        , "-i"
        , "PATH=/usr/sbin:/usr/bin:/sbin:/bin"
        , "LC_ALL=C"
        , "KUBECONFIG=/etc/rancher/rke2/rke2.yaml"
        , "PRODBOX_CLEANUP_OPERATION_ID="
            ++ Text.unpack (cleanupOperationIdText operationId)
        , localRke2InstallMarkerPath LocalRke2UninstallScriptMarker
        ]
    , subprocessEnvironment =
        Just
          [ ("PATH", "/usr/sbin:/usr/bin:/sbin:/bin")
          , ("LC_ALL", "C")
          ]
    , subprocessWorkingDirectory =
        Just (internalLocalRke2WorkingDirectory adapter)
    }

localRke2UninstallResultToHostEffect
  :: LocalRke2UninstallResult -> HostCleanupEffectOutcome
localRke2UninstallResultToHostEffect result = case result of
  LocalRke2UninstallAlreadyAbsent {} -> HostCleanupEffectApplied
  LocalRke2UninstallApplied {} -> HostCleanupEffectApplied
  LocalRke2UninstallResponseLost _ detail ->
    HostCleanupEffectResponseLost detail
  LocalRke2UninstallRefused _ refusal ->
    HostCleanupEffectRefused (renderUninstallRefusal refusal)

hostCleanupRunLocalRke2Uninstall
  :: LocalRke2TerminalAdapter IO
  -> HostCleanupRunnerContext
  -> IO HostCleanupEffectOutcome
hostCleanupRunLocalRke2Uninstall adapter context =
  localRke2UninstallResultToHostEffect
    <$> attemptLocalRke2Uninstall
      adapter
      (hostCleanupRunnerUninstallOperationId context)

renderUninstallRefusal :: LocalRke2UninstallRefusal -> Text
renderUninstallRefusal refusal = case refusal of
  LocalRke2UninstallObservationUnconfirmed failures ->
    renderMarkerFailures failures
  LocalRke2UninstallInstalledDamaged markers ->
    "local RKE2 is installed or damaged, but its canonical uninstall script is absent; surviving markers: "
      <> renderMarkers markers
  LocalRke2UninstallCommandFailed exitCode detail ->
    "local RKE2 uninstaller failed ("
      <> Text.pack (show exitCode)
      <> "): "
      <> detail

renderMarkerFailures :: NonEmpty LocalRke2MarkerFailure -> Text
renderMarkerFailures failures =
  "local RKE2 install absence is unconfirmed: "
    <> Text.intercalate
      "; "
      [ Text.pack (localRke2InstallMarkerPath marker)
          <> " ("
          <> detail
          <> ")"
      | LocalRke2MarkerFailure marker detail <- NonEmpty.toList failures
      ]

renderMarkers :: NonEmpty LocalRke2InstallMarker -> Text
renderMarkers =
  Text.intercalate ", "
    . map (Text.pack . localRke2InstallMarkerPath)
    . NonEmpty.toList

processFailureDetail :: ProcessOutput -> Text
processFailureDetail output =
  let combined =
        Text.unwords
          ( Text.words
              ( Text.pack
                  (processStderr output <> "\n" <> processStdout output)
              )
          )
   in if Text.null combined
        then "uninstaller returned no diagnostic output"
        else boundedDetail combined

boundedDetail :: Text -> Text
boundedDetail detail
  | Text.length detail <= maximumDetailCharacters = detail
  | otherwise = Text.take maximumDetailCharacters detail <> "..."

maximumDetailCharacters :: Int
maximumDetailCharacters = 2048
