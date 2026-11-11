{-# LANGUAGE OverloadedStrings #-}

-- | Brackets one AWS lifecycle drill with its ledger records (Sprint 6.7).
--
-- @Begun@ is appended before the drill runs and @Closed@ after, so a drill that
-- is killed leaves a @Begun@ with no @Closed@: an interrupted attempt, which
-- ends the counted run. The ledger cannot be skipped: if it is unreadable or
-- the scoped source identity cannot be captured, the drill is refused before it
-- mutates anything. A drill is recorded clean only when it exits zero, its
-- scoped source digest is unchanged at the end, and the operator declared no
-- hand action; the hand-action declaration is the operator's, because nothing
-- can observe a manual deletion.
module Prodbox.Test.AwsLifecycleDrillRecorder
  ( DestroyMinutes
  , DrillKind (..)
  , newDestroyMinutes
  , noteDestroyElapsed
  , recordAwsLifecycleDrill
  , handActionVariable
  , observeProviderImageDigest
  , classifyDrill
  )
where

import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Calendar (toModifiedJulianDay)
import Data.Time.Clock (getCurrentTime, utctDay)
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Result (Result (..))
import Prodbox.Subprocess (ProcessOutput (..), Subprocess (..), captureSubprocessResult)
import Prodbox.Test.Qualification.AwsLifecycleDrillLedger
import Prodbox.Test.Qualification.AwsLifecycleDrillLedgerStore
import Prodbox.Test.Qualification.SourceIdentity (sourceManifestDigest)
import Prodbox.Test.Qualification.SourceManifest (captureAwsLifecycleSourceIdentity)
import System.Exit (ExitCode (..))

-- | The longest EKS destroy a drill performed, in whole minutes rounded up.
newtype DestroyMinutes = DestroyMinutes (IORef (Maybe Int))

newDestroyMinutes :: IO DestroyMinutes
newDestroyMinutes = DestroyMinutes <$> newIORef Nothing

-- | Run an action and note how long it took as a destroy time.
noteDestroyElapsed :: DestroyMinutes -> IO a -> IO a
noteDestroyElapsed (DestroyMinutes ref) action = do
  started <- getMonotonicTimeNSec
  result <- action
  finished <- getMonotonicTimeNSec
  let minutes = fromIntegral ((finished - started) `div` 60000000000) + 1 :: Int
  atomicModifyIORef' ref (\current -> (Just (maybe minutes (max minutes) current), ()))
  pure result

-- | Set to @1@ by an operator who had to act by hand during the drill.
handActionVariable :: String
handActionVariable = "PRODBOX_TEST_AWS_LIFECYCLE_HAND_ACTION"

-- | How a finished drill is recorded.
classifyDrill :: Bool -> Bool -> ExitCode -> DrillOutcome
classifyDrill handAction sourceUnchanged exitCode
  | handAction = DrillNeededHandAction
  | exitCode == ExitSuccess && sourceUnchanged = DrillClean
  | otherwise = DrillFailed

-- | The Provider worker's running image digest, or @unobserved@. A failure to
-- observe never fails the drill: the digest is reported, not gating.
observeProviderImageDigest :: FilePath -> [(String, String)] -> IO Text
observeProviderImageDigest repoRoot environment = do
  observed <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "kubectl"
        , subprocessArguments =
            [ "get"
            , "pods"
            , "--all-namespaces"
            , "-o"
            , "jsonpath={range .items[*]}{range .status.containerStatuses[?(@.name==\"provider-worker\")]}{.imageID}{\"\\n\"}{end}{end}"
            ]
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just repoRoot
        }
  pure $ case observed of
    Success output
      | processExitCode output == ExitSuccess ->
          case nub (sort (concatMap digestOf (Text.lines (Text.pack (processStdout output))))) of
            [single] -> single
            _ -> "unobserved"
    _ -> "unobserved"
 where
  digestOf line =
    let (_, suffix) = Text.breakOnEnd "sha256:" line
        digest = Text.take 64 suffix
     in [ "sha256:" <> digest
        | Text.length digest == 64
        , Text.all (\c -> c >= '0' && c <= '9' || c >= 'a' && c <= 'f') digest
        ]

-- | Record @Begun@, run the drill, record @Closed@. The drill receives the
-- destroy-time collector. Returns the drill's own exit code, or a refusal
-- (before the drill runs) when the ledger or scoped identity cannot be used.
recordAwsLifecycleDrill
  :: FilePath
  -> [(String, String)]
  -> DrillKind
  -> (DestroyMinutes -> IO ExitCode)
  -> IO (Either String ExitCode)
recordAwsLifecycleDrill repoRoot environment kind drill = do
  let path = drillLedgerPath repoRoot
  ledgerResult <- readDrillLedger path
  identityResult <- captureAwsLifecycleSourceIdentity repoRoot []
  case (ledgerResult, identityResult) of
    (Left err, _) -> pure (Left (renderDrillStoreError err))
    (_, Left err) -> pure (Left ("the scoped source identity could not be captured: " <> show err))
    (Right ledger, Right identity) -> do
      image <- observeProviderImageDigest repoRoot environment
      day <- fromIntegral . toModifiedJulianDay . utctDay <$> getCurrentTime
      let identifier = length (resolveDrillAttempts ledger) + 1
          scoped = sourceManifestDigest identity
          begun = RecordBegun (DrillBegun identifier kind scoped image day)
      begunResult <- appendDrillRecordAtTip path (drillLedgerTip ledger) begun
      case begunResult of
        Left err -> pure (Left (renderDrillStoreError err))
        Right afterBegun -> do
          minutes@(DestroyMinutes minutesRef) <- newDestroyMinutes
          exitCode <- drill minutes
          destroyMinutes <- readIORef minutesRef
          after <- captureAwsLifecycleSourceIdentity repoRoot []
          let unchanged = either (const False) ((== scoped) . sourceManifestDigest) after
              handAction = lookup handActionVariable environment == Just "1"
              outcome = classifyDrill handAction unchanged exitCode
              closed =
                RecordClosed
                  DrillClosed
                    { closedId = identifier
                    , closedOutcome = outcome
                    , closedDestroyMinutes = destroyMinutes
                    , closedScopedDiffEmpty = outcome == DrillClean
                    , closedAfterUnchangedScopeMerge = False
                    }
          closedResult <- appendDrillRecordAtTip path (drillLedgerTip afterBegun) closed
          pure $ case closedResult of
            Left err -> Left ("the drill ran but its Closed record was not written: " <> renderDrillStoreError err)
            Right _ -> Right exitCode
