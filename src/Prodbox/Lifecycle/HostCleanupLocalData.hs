{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.85: the retained-local-data terminal adapter.
--
-- @nuke@ has always named the manual PV host root as the first entry of its own
-- deletion-root inventory — that is why the external receipt and the pinned
-- runner are required to live outside it — and nothing ever disposed of it. A
-- total decommission destroyed every AWS resource class, uninstalled the home
-- substrate, and left the retained data tree on disk with no record of whether
-- that was what the operator wanted.
--
-- This adapter is the physical half of the
-- 'Prodbox.Lifecycle.Decommission.Manifest.LocalDataDisposition' node. It is
-- indexed by the operator's signed decision, and the two decisions are not
-- symmetric: @delete@ mutates and then requires observed absence, while
-- @retain@ issues no effect at all and requires observed presence. Neither can
-- be closed by an unobservable root, because an absence nobody observed is not
-- a disposition anybody honoured.
module Prodbox.Lifecycle.HostCleanupLocalData
  ( LocalDataRootPath
  , LocalDataRootPathError (..)
  , mkLocalDataRootPath
  , localDataRootPath
  , LocalDataRootObservation (..)
  , LocalDataDispositionOutcome (..)
  , LocalDataDispositionRefusal (..)
  , LocalDataDispositionResult (..)
  , LocalDataTerminalBoundary (..)
  , LocalDataTerminalAdapter
  , mkLocalDataTerminalAdapter
  , productionLocalDataTerminalAdapter
  , observeLocalDataRoot
  , attemptLocalDataDisposition
  , classifyLocalDataDisposition
  , localDataDispositionResidue
  , renderLocalDataDispositionRefusal
  )
where

import Control.Exception (IOException, try)
import Data.Bifunctor (first)
import Data.Char (isControl)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Error (errorMsg)
import Prodbox.Lifecycle.CleanupRun
  ( CleanupOperationId
  , cleanupOperationIdText
  )
import Prodbox.Lifecycle.Decommission.Manifest
  ( DecommissionLocalDataDisposition (DeleteLocalData, RetainLocalData)
  , decommissionLocalDataDispositionText
  )
import Prodbox.Lifecycle.ResidueStatus
  ( ResidueDetails (..)
  , ResidueStatus (ResidueAbsent, ResiduePresent, ResidueUnreachable)
  , ResidueUnreachableReason (ResidueQueryFailed)
  )
import Prodbox.Lifecycle.Teardown.Observation (AbsenceEvidence (..))
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessBounded
  )
import System.Exit (ExitCode (..))
import System.FilePath (normalise, splitDirectories)
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (FileStatus, getSymbolicLinkStatus)

-- | One exact retained local data root.
--
-- The constructor is the guard between a configured string and a recursive
-- removal. It is deliberately stricter than
-- 'Prodbox.Lifecycle.Decommission.Verifier.DeletionRootPath': a deletion root
-- only has to be comparable against a durable file path, while this value is
-- the argument of the removal itself, so a shallow root is refused outright
-- rather than merely reported.
newtype LocalDataRootPath = LocalDataRootPath FilePath
  deriving stock (Eq, Ord, Show)

data LocalDataRootPathError
  = LocalDataRootNotAbsolute
  | LocalDataRootNotCanonical
  | LocalDataRootTooShallow
  | LocalDataRootInvalid
  deriving stock (Eq, Show)

-- | Admit only an absolute, canonical, non-shallow path.
--
-- \"Non-shallow\" means at least __three__ components below @\/@. It is a depth
-- rule rather than a denylist on purpose: a denylist of system directories is
-- open-ended and a new mount point escapes it, while the depth of a
-- prodbox-owned PV root is a property of what the value /is/. The configured
-- root is normally relative to the repository and therefore deep by
-- construction; an absolute configured value is the case this guard exists
-- for, and it refuses @\/@, @\/home@, @\/var\/lib@, and @\/usr\/local@ alike.
mkLocalDataRootPath :: FilePath -> Either LocalDataRootPathError LocalDataRootPath
mkLocalDataRootPath path
  | take 1 path /= "/" = Left LocalDataRootNotAbsolute
  | normalise path /= path || any isDotComponent components =
      Left LocalDataRootNotCanonical
  | length components < 4 = Left LocalDataRootTooShallow
  | length path > 4096 || any isControl path = Left LocalDataRootInvalid
  | otherwise = Right (LocalDataRootPath path)
 where
  components = splitDirectories path
  isDotComponent component = component == "." || component == ".."

localDataRootPath :: LocalDataRootPath -> FilePath
localDataRootPath (LocalDataRootPath path) = path

-- | The three facts a no-follow observation of the root can establish. A
-- symlink, including a broken one, is present: production uses @lstat(2)@.
data LocalDataRootObservation
  = LocalDataRootPresent
  | LocalDataRootAbsent !AbsenceEvidence
  | LocalDataRootUnobservable !Text
  deriving stock (Eq, Show)

-- | Why a disposition attempt could not be applied.
data LocalDataDispositionRefusal
  = LocalDataDispositionObservationUnconfirmed !Text
  | LocalDataDispositionRemovalFailed !ExitCode !Text
  deriving stock (Eq, Show)

-- | What the attempt did. The stable operation ID is preserved on every arm,
-- so a lost response resumes through the same identity rather than minting a
-- second removal.
data LocalDataDispositionOutcome
  = -- | @retain@: no effect was issued at all.
    LocalDataRetained
  | -- | @delete@: the root was already absent, so no removal ran.
    LocalDataAlreadyAbsent !AbsenceEvidence
  | -- | @delete@: the removal exited zero.
    LocalDataRemovalApplied
  | -- | @delete@: the removal's response was lost, which is not evidence it
    -- did not run.
    LocalDataRemovalResponseLost !Text
  | LocalDataDispositionRefused !LocalDataDispositionRefusal
  deriving stock (Eq, Show)

data LocalDataDispositionResult = LocalDataDispositionResult
  { localDataDispositionOperationId :: !CleanupOperationId
  , localDataDispositionDecision :: !DecommissionLocalDataDisposition
  , localDataDispositionOutcome :: !LocalDataDispositionOutcome
  }
  deriving stock (Eq, Show)

-- | Injected physical boundary. Tests interrupt after the removal is applied,
-- or make the root unobservable, without changing the adapter's target,
-- command, or classification.
data LocalDataTerminalBoundary m = LocalDataTerminalBoundary
  { localDataObserveRoot :: m LocalDataRootObservation
  , localDataExecuteRemoval
      :: CleanupOperationId
      -> Subprocess
      -> m (Either Text ProcessOutput)
  }

data LocalDataTerminalAdapter m = LocalDataTerminalAdapter
  { internalLocalDataRoot :: !LocalDataRootPath
  , internalLocalDataWorkingDirectory :: !FilePath
  , internalLocalDataBoundary :: !(LocalDataTerminalBoundary m)
  }

mkLocalDataTerminalAdapter
  :: LocalDataRootPath
  -> FilePath
  -> LocalDataTerminalBoundary m
  -> LocalDataTerminalAdapter m
mkLocalDataTerminalAdapter root workingDirectory boundary =
  LocalDataTerminalAdapter
    { internalLocalDataRoot = root
    , internalLocalDataWorkingDirectory = workingDirectory
    , internalLocalDataBoundary = boundary
    }

productionLocalDataTerminalAdapter
  :: LocalDataRootPath -> FilePath -> LocalDataTerminalAdapter IO
productionLocalDataTerminalAdapter root workingDirectory =
  mkLocalDataTerminalAdapter
    root
    workingDirectory
    LocalDataTerminalBoundary
      { localDataObserveRoot = observeProductionRoot root
      , localDataExecuteRemoval = \_operationId spec ->
          first errorMsg <$> captureSubprocessBounded removalLimits spec
      }

observeProductionRoot :: LocalDataRootPath -> IO LocalDataRootObservation
observeProductionRoot root = do
  observed <-
    try (getSymbolicLinkStatus (localDataRootPath root))
      :: IO (Either IOException FileStatus)
  pure $ case observed of
    Right _ -> LocalDataRootPresent
    Left err
      | isDoesNotExistError err -> LocalDataRootAbsent (exactLocalDataAbsence root)
      | otherwise -> LocalDataRootUnobservable (boundedDetail (Text.pack (show err)))

exactLocalDataAbsence :: LocalDataRootPath -> AbsenceEvidence
exactLocalDataAbsence root =
  AbsenceEvidence
    ( "local-data-root/v1: "
        <> Text.pack (localDataRootPath root)
        <> " was observed absent by a no-follow lookup"
    )

removalLimits :: BoundedSubprocessLimits
removalLimits =
  BoundedSubprocessLimits
    { boundedSubprocessMaximumInputBytes = 1
    , boundedSubprocessMaximumStdoutBytes = 1024 * 1024
    , boundedSubprocessMaximumStderrBytes = 1024 * 1024
    , boundedSubprocessTimeoutMicros = 30 * 60 * 1_000_000
    }

observeLocalDataRoot
  :: LocalDataTerminalAdapter m -> m LocalDataRootObservation
observeLocalDataRoot = localDataObserveRoot . internalLocalDataBoundary

-- | Apply the signed decision under the stable operation identity.
--
-- @retain@ never reaches the boundary's removal callback, which is the whole
-- point: the composition cannot delete under a plan that said retain, because
-- the deleting arm is selected by the decision the manifest carries.
attemptLocalDataDisposition
  :: (Monad m)
  => LocalDataTerminalAdapter m
  -> DecommissionLocalDataDisposition
  -> CleanupOperationId
  -> m LocalDataDispositionResult
attemptLocalDataDisposition adapter disposition operationId = do
  outcome <- case disposition of
    RetainLocalData -> pure LocalDataRetained
    DeleteLocalData -> deleteRoot
  pure
    LocalDataDispositionResult
      { localDataDispositionOperationId = operationId
      , localDataDispositionDecision = disposition
      , localDataDispositionOutcome = outcome
      }
 where
  boundary = internalLocalDataBoundary adapter
  deleteRoot = do
    observed <- localDataObserveRoot boundary
    case observed of
      LocalDataRootAbsent evidence -> pure (LocalDataAlreadyAbsent evidence)
      LocalDataRootUnobservable detail ->
        pure
          ( LocalDataDispositionRefused
              (LocalDataDispositionObservationUnconfirmed detail)
          )
      LocalDataRootPresent -> do
        attempted <-
          localDataExecuteRemoval
            boundary
            operationId
            (localDataRemovalSubprocess adapter operationId)
        pure $ case attempted of
          Left detail -> LocalDataRemovalResponseLost (boundedDetail detail)
          Right output -> case processExitCode output of
            ExitSuccess -> LocalDataRemovalApplied
            exitCode@(ExitFailure _) ->
              LocalDataDispositionRefused
                ( LocalDataDispositionRemovalFailed
                    exitCode
                    (processFailureDetail output)
                )

-- | Turn an attempt outcome into the destroy half's verdict.
--
-- A lost response is a failure of /this attempt/, not a refusal: the runner
-- resumes by re-observing the root under the same operation. Both remain
-- distinct so the receipt records which happened.
classifyLocalDataDisposition :: LocalDataDispositionResult -> Either Text ()
classifyLocalDataDisposition result = case localDataDispositionOutcome result of
  LocalDataRetained -> Right ()
  LocalDataAlreadyAbsent _ -> Right ()
  LocalDataRemovalApplied -> Right ()
  LocalDataRemovalResponseLost detail ->
    Left (prefix <> "removal response lost: " <> detail)
  LocalDataDispositionRefused refusal ->
    Left (prefix <> renderLocalDataDispositionRefusal refusal)
 where
  prefix =
    "retained local data disposition ("
      <> decommissionLocalDataDispositionText
        (localDataDispositionDecision result)
      <> ") "

-- | The disposition-indexed read-back.
--
-- @ResidueAbsent@ here means \"the decision was honoured\", which is the only
-- reading 'Prodbox.Lifecycle.Decommission.NodeEffect.classifyNodeObservation'
-- accepts. The residue a @retain@ run reports is therefore a /missing/ root:
-- the operator asked for the data to survive the decommission and it did not,
-- which is a fact the receipt must record rather than round up to success.
localDataDispositionResidue
  :: LocalDataRootPath
  -> DecommissionLocalDataDisposition
  -> LocalDataRootObservation
  -> ResidueStatus
localDataDispositionResidue root disposition observed =
  case (disposition, observed) of
    (DeleteLocalData, LocalDataRootAbsent _) -> ResidueAbsent
    (DeleteLocalData, LocalDataRootPresent) ->
      undisposed "the retained local data root survives a delete disposition"
    (RetainLocalData, LocalDataRootPresent) -> ResidueAbsent
    (RetainLocalData, LocalDataRootAbsent _) ->
      undisposed "the retained local data root is absent under a retain disposition"
    (_, LocalDataRootUnobservable detail) ->
      ResidueUnreachable
        ( ResidueQueryFailed
            ( "the retained local data root could not be observed: "
                ++ Text.unpack detail
            )
        )
 where
  undisposed evidence =
    ResiduePresent
      ResidueDetails
        { residueEvidence = evidence ++ ": " ++ localDataRootPath root
        , residueStackName = "local-data-disposition"
        }

localDataRemovalSubprocess
  :: LocalDataTerminalAdapter m
  -> CleanupOperationId
  -> Subprocess
localDataRemovalSubprocess adapter operationId =
  Subprocess
    { subprocessPath = "/usr/bin/sudo"
    , subprocessArguments =
        [ "--"
        , "/usr/bin/env"
        , "-i"
        , "PATH=/usr/sbin:/usr/bin:/sbin:/bin"
        , "LC_ALL=C"
        , "PRODBOX_CLEANUP_OPERATION_ID="
            ++ Text.unpack (cleanupOperationIdText operationId)
        , "/usr/bin/rm"
        , "-rf"
        , "--"
        , localDataRootPath (internalLocalDataRoot adapter)
        ]
    , subprocessEnvironment =
        Just
          [ ("PATH", "/usr/sbin:/usr/bin:/sbin:/bin")
          , ("LC_ALL", "C")
          ]
    , subprocessWorkingDirectory =
        Just (internalLocalDataWorkingDirectory adapter)
    }

renderLocalDataDispositionRefusal :: LocalDataDispositionRefusal -> Text
renderLocalDataDispositionRefusal refusal = case refusal of
  LocalDataDispositionObservationUnconfirmed detail ->
    "refused: the root could not be observed before removal: " <> detail
  LocalDataDispositionRemovalFailed exitCode detail ->
    "refused: removal failed ("
      <> Text.pack (show exitCode)
      <> "): "
      <> detail

processFailureDetail :: ProcessOutput -> Text
processFailureDetail output =
  let combined =
        Text.unwords
          ( Text.words
              (Text.pack (processStderr output <> "\n" <> processStdout output))
          )
   in if Text.null combined
        then "removal returned no diagnostic output"
        else boundedDetail combined

boundedDetail :: Text -> Text
boundedDetail detail
  | Text.length detail <= maximumDetailCharacters = detail
  | otherwise = Text.take maximumDetailCharacters detail <> "..."

maximumDetailCharacters :: Int
maximumDetailCharacters = 2048
