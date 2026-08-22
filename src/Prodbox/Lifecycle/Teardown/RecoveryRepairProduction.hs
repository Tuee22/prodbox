{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.86: the production side of the recovery repair's host mutations.
--
-- "Prodbox.Lifecycle.Teardown.RecoveryRepairExecution" admits and applies a
-- repair against an injected 'RecoveryRepairBoundary' and deliberately ships no
-- production one; this module is that boundary for four of its five arms.
--
-- Five properties carry the design.
--
--   * __The installer reads exactly the verified bytes, under the names it
--     expects.__  A retained artifact's location is the operator's
--     store-relative path, and the local substrate's offline installer reads
--     one artifact directory under fixed, architecture-specific file names.
--     The install stages a directory of links to the verified retained files
--     rather than copying, renaming, or re-fetching them, so the bytes the
--     installer reads are the bytes the admission hashed.
--
--   * __An incomplete install refuses before anything is staged.__  All four
--     substrate artifacts — the installer, the release tarball, the checksum
--     file it verifies that tarball against, and the system-images archive —
--     must be present in the admitted step, and a missing one is a refusal
--     rather than a partially staged directory that fails inside a root
--     subprocess.  That refusal is measured as no command being issued at all.
--
--   * __The staged directory is discarded on every path.__  It is outside the
--     retained store deliberately: custody measures store membership in both
--     directions, so an install scratch directory placed inside it would be
--     collected as unreferenced.
--
--   * __Availability is read from the one substrate observer.__  Awaiting the
--     API polls "Prodbox.Config.LocalRke2RecoveryState" rather than issuing a
--     second health check of its own, so the repair and the read-back that
--     judges it agree by construction about what healthy means.  Exhausting
--     the bound reports the last observation rather than a bare timeout.
--
--   * __The chart reconcile is supplied, not built here.__  Reconciling a
--     recovery chart is chart delivery, which sits above the lifecycle surface
--     rather than beside it; taking it as an argument states that dependency
--     instead of inverting it.  It is the one arm this module does not own.
--
-- __An honest bound.__  The install, start, and image-import commands are a
-- contract with the local substrate's own tooling — the installer's artifact
-- directory, its systemd unit name, and its bundled container-runtime client.
-- The fault matrix here is exercised through an injected physical boundary,
-- which measures what this module decides; that the external tools accept these
-- exact invocations is a live-infrastructure proof and is not claimed by these
-- regressions.
module Prodbox.Lifecycle.Teardown.RecoveryRepairProduction
  ( -- * What the installer expects
    rke2ArtifactFileName
  , substrateInstallStaging

    -- * The physical boundary
  , RecoveryRepairCommand (..)
  , renderRecoveryRepairCommand
  , RecoveryRepairPhysicalBoundary (..)
  , productionRecoveryRepairPhysicalBoundary

    -- * The repair boundary
  , RecoveryRepairChartReconciler
  , SubstrateApiWait
  , mkSubstrateApiWait
  , substrateApiWaitAttempts
  , substrateApiWaitDelayMicros
  , recoveryRepairBoundaryOver
  , productionRecoveryRepairBoundary

    -- * Regression over the fixed physical closure
  , RecoveryRepairProductionRegression
  , fixedRecoveryRepairProductionRegression
  , repairProductionRegressionStagesTheFourExpectedNames
  , repairProductionRegressionInstallRunsOverTheStagedDirectory
  , repairProductionRegressionIncompleteInstallIssuesNothing
  , repairProductionRegressionStagingDiscardedOnFailure
  , repairProductionRegressionStartEnablesAndStarts
  , repairProductionRegressionAwaitStopsAtHealthy
  , repairProductionRegressionAwaitExhaustsWithLastObservation
  , repairProductionRegressionImageImportAddressesRetainedBytes
  , repairProductionRegressionChartReconcileIsDelegated
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, try)
import Data.Bifunctor (first)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Config.LocalRke2RecoveryState
  ( LocalRke2RecoveryStateView (..)
  , localRke2RecoveryStateView
  , observeLocalRke2RecoveryState
  , renderLocalRke2RecoveryStateError
  )
import Prodbox.Config.OrdinaryTeardownRepair
  ( RetainedArtifactArchitecture (..)
  , RetainedArtifactKind (..)
  , retainedArtifactArchitectureText
  , retainedArtifactKindText
  )
import Prodbox.Error (errorMsg)
import Prodbox.Lifecycle.Teardown.RecoveryRepairExecution
  ( RecoveryRepairBoundary (..)
  , VerifiedRetainedArtifact (..)
  )
import Prodbox.Lifecycle.Teardown.RetainedArtifactCustody
  ( RetainedArtifactStore
  , retainedArtifactStorePath
  )
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessBounded
  )
import System.Directory
  ( createDirectoryIfMissing
  , createFileLink
  , getTemporaryDirectory
  , removePathForcibly
  )
import System.Exit (ExitCode (..))
import System.FilePath ((</>))

-- ---------------------------------------------------------------------------
-- What the installer expects
-- ---------------------------------------------------------------------------

-- | The file name the local substrate's offline installer reads a retained
-- artifact under, for the architecture the inventory declared.
--
-- The image kinds have no name here because they are not part of the install
-- directory at all: they are loaded into the running node's content store after
-- the substrate is up, which is a different step with a different failure.
rke2ArtifactFileName
  :: RetainedArtifactArchitecture -> RetainedArtifactKind -> Maybe FilePath
rke2ArtifactFileName architecture = \case
  RetainedSubstrateInstaller -> Just "install.sh"
  RetainedSubstrateReleaseTarball -> Just ("rke2.linux-" ++ arch ++ ".tar.gz")
  RetainedSubstrateChecksum -> Just ("sha256sum-" ++ arch ++ ".txt")
  RetainedSubstrateSystemImages ->
    Just ("rke2-images.linux-" ++ arch ++ ".tar.zst")
  RetainedObjectStoreImage -> Nothing
  RetainedSecretStoreImage -> Nothing
  RetainedProdboxRuntimeImage -> Nothing
 where
  arch = retainedArtifactArchitectureText architecture

-- | The four substrate kinds an offline install needs, in the order the
-- installer directory is described.
substrateInstallKinds :: [RetainedArtifactKind]
substrateInstallKinds =
  [ RetainedSubstrateInstaller
  , RetainedSubstrateReleaseTarball
  , RetainedSubstrateChecksum
  , RetainedSubstrateSystemImages
  ]

-- | Resolve an admitted install step into the links the artifact directory is
-- made of: the absolute retained path, and the name the installer reads it
-- under.
--
-- Refuses rather than staging a partial directory, because a missing artifact
-- surfaces inside a root subprocess otherwise, where the run can no longer say
-- which byte source was absent.
substrateInstallStaging
  :: RetainedArtifactArchitecture
  -> FilePath
  -- ^ The retained store's resolved path.
  -> NonEmpty VerifiedRetainedArtifact
  -> Either Text [(FilePath, FilePath)]
substrateInstallStaging architecture storeRoot artifacts =
  traverse resolve substrateInstallKinds
 where
  supplied = NonEmpty.toList artifacts

  resolve kind = case filter ((== kind) . verifiedRetainedArtifactKind) supplied of
    [artifact] -> case rke2ArtifactFileName architecture kind of
      Nothing ->
        Left
          ( "the retained artifact `"
              <> Text.pack (retainedArtifactKindText kind)
              <> "` has no place in a substrate install directory"
          )
      Just name ->
        Right
          ( storeRoot </> verifiedRetainedArtifactRelativePath artifact
          , name
          )
    [] ->
      Left
        ( "the admitted substrate install does not name the retained `"
            <> Text.pack (retainedArtifactKindText kind)
            <> "`"
        )
    _ ->
      Left
        ( "the admitted substrate install names the retained `"
            <> Text.pack (retainedArtifactKindText kind)
            <> "` more than once"
        )

-- ---------------------------------------------------------------------------
-- The physical boundary
-- ---------------------------------------------------------------------------

-- | Which host mutation a subprocess is.
--
-- Carried beside the specification so a physical boundary can refuse, delay,
-- or record one arm without matching on argument shape.
data RecoveryRepairCommand
  = RecoveryInstallSubstrate
  | RecoveryStartSubstrateService
  | RecoveryImportRetainedImage
  deriving (Eq, Show)

renderRecoveryRepairCommand :: RecoveryRepairCommand -> Text
renderRecoveryRepairCommand = \case
  RecoveryInstallSubstrate -> "install the local substrate from retained bytes"
  RecoveryStartSubstrateService -> "start the local substrate service"
  RecoveryImportRetainedImage -> "import a retained image into the node"

-- | The physical acts this module composes.
--
-- Injected so the fault matrix — a staging failure, a refused install, a
-- service that starts and whose API never arrives, an import that fails — is
-- exercised without a host.
data RecoveryRepairPhysicalBoundary m = RecoveryRepairPhysicalBoundary
  { recoveryStageInstallDirectory
      :: [(FilePath, FilePath)] -> m (Either Text FilePath)
  , recoveryDiscardInstallDirectory :: FilePath -> m ()
  , recoveryRunCommand
      :: RecoveryRepairCommand -> Subprocess -> m (Either Text ProcessOutput)
  , recoveryObserveSubstrate :: m (Either Text LocalRke2RecoveryStateView)
  , recoveryPauseMicros :: Int -> m ()
  }

-- | The host implementation.
productionRecoveryRepairPhysicalBoundary :: RecoveryRepairPhysicalBoundary IO
productionRecoveryRepairPhysicalBoundary =
  RecoveryRepairPhysicalBoundary
    { recoveryStageInstallDirectory = stageProductionInstallDirectory
    , recoveryDiscardInstallDirectory = removePathForcibly
    , recoveryRunCommand = \_command spec ->
        first errorMsg <$> captureSubprocessBounded recoveryCommandLimits spec
    , recoveryObserveSubstrate =
        either
          (Left . renderLocalRke2RecoveryStateError)
          (Right . localRke2RecoveryStateView)
          <$> observeLocalRke2RecoveryState
    , recoveryPauseMicros = threadDelay
    }

-- | Link the verified retained files into a fresh directory outside the store.
--
-- Links rather than copies: a release tarball and a system-images archive are
-- hundreds of megabytes each, and a copy would also make the bytes the
-- installer reads a second object from the ones custody verified.
stageProductionInstallDirectory :: [(FilePath, FilePath)] -> IO (Either Text FilePath)
stageProductionInstallDirectory links = do
  temporary <- getTemporaryDirectory
  let directory = temporary </> "prodbox-substrate-install"
  removePathForcibly directory
  createDirectoryIfMissing True directory
  linked <- traverse (link directory) links
  pure (fmap (const directory) (sequence_ linked))
 where
  link directory (source, name) = do
    attempted <-
      try (createFileLink source (directory </> name)) :: IO (Either IOException ())
    pure
      ( first
          (\err -> "the substrate install directory could not be staged: " <> Text.pack (show err))
          attempted
      )

recoveryCommandLimits :: BoundedSubprocessLimits
recoveryCommandLimits =
  BoundedSubprocessLimits
    { boundedSubprocessMaximumInputBytes = 1
    , boundedSubprocessMaximumStdoutBytes = 1024 * 1024
    , boundedSubprocessMaximumStderrBytes = 1024 * 1024
    , boundedSubprocessTimeoutMicros = 30 * 60 * 1_000_000
    }

-- ---------------------------------------------------------------------------
-- The repair boundary
-- ---------------------------------------------------------------------------

-- | How long the run waits for the substrate API after starting the service.
data SubstrateApiWait = SubstrateApiWait
  { internalSubstrateApiAttempts :: !Int
  , internalSubstrateApiDelayMicros :: !Int
  }
  deriving (Eq, Show)

mkSubstrateApiWait :: Int -> Int -> Either Text SubstrateApiWait
mkSubstrateApiWait attempts delayMicros
  | attempts <= 0 = Left "a substrate API wait must make at least one attempt"
  | delayMicros <= 0 = Left "a substrate API wait must have a positive delay"
  | otherwise =
      Right
        SubstrateApiWait
          { internalSubstrateApiAttempts = attempts
          , internalSubstrateApiDelayMicros = delayMicros
          }

substrateApiWaitAttempts :: SubstrateApiWait -> Int
substrateApiWaitAttempts = internalSubstrateApiAttempts

substrateApiWaitDelayMicros :: SubstrateApiWait -> Int
substrateApiWaitDelayMicros = internalSubstrateApiDelayMicros

-- | What reconciles one recovery chart.
--
-- Chart delivery sits above the lifecycle surface, so this is an argument
-- rather than a dependency: the composition that owns both supplies it.
type RecoveryRepairChartReconciler m = String -> m (Either Text ())

-- | Compose the five repair arms over one physical boundary.
recoveryRepairBoundaryOver
  :: (Monad m)
  => RecoveryRepairPhysicalBoundary m
  -> RetainedArtifactArchitecture
  -> FilePath
  -- ^ The retained store's resolved path.  A 'RetainedArtifactStore' is the
  -- production caller's argument; the composition only reads bytes under it,
  -- and reading is what a bootstrap-located root is for.
  -> SubstrateApiWait
  -> RecoveryRepairChartReconciler m
  -> RecoveryRepairBoundary m
recoveryRepairBoundaryOver physical architecture storeRoot wait reconcileChart =
  RecoveryRepairBoundary
    { repairInstallSubstrate = installSubstrate
    , repairStartSubstrateService =
        issue RecoveryStartSubstrateService substrateStartSubprocess
    , repairAwaitSubstrateApi = awaitApi (substrateApiWaitAttempts wait)
    , repairLoadRetainedImage = \artifact ->
        issue
          RecoveryImportRetainedImage
          ( retainedImageImportSubprocess
              (storeRoot </> verifiedRetainedArtifactRelativePath artifact)
          )
    , repairReconcileRecoveryChart = reconcileChart
    }
 where
  installSubstrate artifacts =
    case substrateInstallStaging architecture storeRoot artifacts of
      Left detail -> pure (Left detail)
      Right links -> do
        staged <- recoveryStageInstallDirectory physical links
        case staged of
          Left detail -> pure (Left detail)
          Right directory -> do
            ran <- issue RecoveryInstallSubstrate (substrateInstallSubprocess directory)
            recoveryDiscardInstallDirectory physical directory
            pure ran

  issue command spec = do
    ran <- recoveryRunCommand physical command spec
    pure $ case ran of
      Left detail ->
        Left (renderRecoveryRepairCommand command <> " could not be issued: " <> detail)
      Right output -> case processExitCode output of
        ExitSuccess -> Right ()
        ExitFailure code ->
          Left
            ( renderRecoveryRepairCommand command
                <> " exited "
                <> Text.pack (show code)
                <> ": "
                <> commandFailureDetail output
            )

  -- Availability is the one observer's answer, polled.  A substrate that is
  -- not yet healthy has not failed, and a substrate that cannot be observed
  -- has said nothing; both are waited on, and the bound decides.
  awaitApi remaining = do
    observed <- recoveryObserveSubstrate physical
    case observed of
      Right LocalRke2RecoveryHealthy -> pure (Right ())
      _
        | remaining <= 1 -> pure (Left (exhausted observed))
        | otherwise -> do
            recoveryPauseMicros physical (substrateApiWaitDelayMicros wait)
            awaitApi (remaining - 1)

  exhausted observed =
    "the local substrate API did not become available within "
      <> Text.pack (show (substrateApiWaitAttempts wait))
      <> " observations; the last one was "
      <> case observed of
        Left detail -> "unobservable: " <> detail
        Right state -> Text.pack (show state)

-- | The host boundary with the production physical acts under it.
productionRecoveryRepairBoundary
  :: RetainedArtifactArchitecture
  -> RetainedArtifactStore authority
  -> SubstrateApiWait
  -> RecoveryRepairChartReconciler IO
  -> RecoveryRepairBoundary IO
productionRecoveryRepairBoundary architecture store =
  recoveryRepairBoundaryOver
    productionRecoveryRepairPhysicalBoundary
    architecture
    (retainedArtifactStorePath store)

-- ---------------------------------------------------------------------------
-- The commands, as values
-- ---------------------------------------------------------------------------

-- | Run the retained installer over the staged artifact directory.
substrateInstallSubprocess :: FilePath -> Subprocess
substrateInstallSubprocess directory =
  elevated
    [ "INSTALL_RKE2_TYPE=server"
    , "INSTALL_RKE2_ARTIFACT_PATH=" ++ directory
    , "/bin/sh"
    , directory </> "install.sh"
    ]

-- | Enable and start the substrate unit in one act, so a repair that is
-- resumed does not leave a started-but-not-enabled node behind.
substrateStartSubprocess :: Subprocess
substrateStartSubprocess =
  elevated ["/usr/bin/systemctl", "enable", "--now", "rke2-server.service"]

-- | Import one retained image archive into the running node's content store.
retainedImageImportSubprocess :: FilePath -> Subprocess
retainedImageImportSubprocess archive =
  elevated
    [ "/var/lib/rancher/rke2/bin/ctr"
    , "--address"
    , "/run/k3s/containerd/containerd.sock"
    , "--namespace"
    , "k8s.io"
    , "images"
    , "import"
    , archive
    ]

-- | One elevated command shape, with an emptied environment.
elevated :: [String] -> Subprocess
elevated arguments =
  Subprocess
    { subprocessPath = "/usr/bin/sudo"
    , subprocessArguments =
        ["--", "/usr/bin/env", "-i", "PATH=" ++ recoveryPath, "LC_ALL=C"]
          ++ arguments
    , subprocessEnvironment = Just [("PATH", recoveryPath), ("LC_ALL", "C")]
    , subprocessWorkingDirectory = Just "/"
    }

recoveryPath :: String
recoveryPath = "/usr/sbin:/usr/bin:/sbin:/bin"

commandFailureDetail :: ProcessOutput -> Text
commandFailureDetail output =
  Text.take 1024 (Text.strip (Text.pack (processStderr output <> " " <> processStdout output)))

-- ---------------------------------------------------------------------------
-- Regression over the fixed physical closure
-- ---------------------------------------------------------------------------

-- | Booleans a dependent test can read without a host.
data RecoveryRepairProductionRegression = RecoveryRepairProductionRegression
  { repairProductionRegressionStagesTheFourExpectedNames :: !Bool
  , repairProductionRegressionInstallRunsOverTheStagedDirectory :: !Bool
  , repairProductionRegressionIncompleteInstallIssuesNothing :: !Bool
  , repairProductionRegressionStagingDiscardedOnFailure :: !Bool
  , repairProductionRegressionStartEnablesAndStarts :: !Bool
  , repairProductionRegressionAwaitStopsAtHealthy :: !Bool
  , repairProductionRegressionAwaitExhaustsWithLastObservation :: !Bool
  , repairProductionRegressionImageImportAddressesRetainedBytes :: !Bool
  , repairProductionRegressionChartReconcileIsDelegated :: !Bool
  }

fixedRecoveryRepairProductionRegression
  :: IO (Either Text RecoveryRepairProductionRegression)
fixedRecoveryRepairProductionRegression = case mkSubstrateApiWait 3 1 of
  Left detail -> pure (Left detail)
  Right wait -> Right <$> runFixedRepairProduction wait

-- | One recorded run of the physical boundary.
data FixedPhysicalJournal = FixedPhysicalJournal
  { journalStaged :: ![[(FilePath, FilePath)]]
  , journalDiscarded :: ![FilePath]
  , journalCommands :: ![(RecoveryRepairCommand, [String])]
  , journalObservations :: !Int
  , journalPauses :: !Int
  }

emptyJournal :: FixedPhysicalJournal
emptyJournal =
  FixedPhysicalJournal
    { journalStaged = []
    , journalDiscarded = []
    , journalCommands = []
    , journalObservations = 0
    , journalPauses = 0
    }

runFixedRepairProduction
  :: SubstrateApiWait -> IO RecoveryRepairProductionRegression
runFixedRepairProduction wait = do
  (install, installJournal) <-
    withFixture (Right ExitSuccess) healthyImmediately $ \boundary ->
      repairInstallSubstrate boundary fixedSubstrateArtifacts

  (_incomplete, incompleteJournal) <-
    withFixture (Right ExitSuccess) healthyImmediately $ \boundary ->
      repairInstallSubstrate boundary (NonEmpty.fromList [fixedArtifact RetainedSubstrateInstaller])

  (_failed, failedJournal) <-
    withFixture (Right (ExitFailure 2)) healthyImmediately $ \boundary ->
      repairInstallSubstrate boundary fixedSubstrateArtifacts

  (_started, startJournal) <-
    withFixture (Right ExitSuccess) healthyImmediately repairStartSubstrateService

  (healthy, healthyJournal) <-
    withFixture (Right ExitSuccess) healthyImmediately repairAwaitSubstrateApi

  (never, neverJournal) <-
    withFixture (Right ExitSuccess) neverHealthy repairAwaitSubstrateApi

  (_imported, importJournal) <-
    withFixture (Right ExitSuccess) healthyImmediately $ \boundary ->
      repairLoadRetainedImage boundary (fixedArtifact RetainedObjectStoreImage)

  (charted, chartJournal) <-
    withFixture (Right ExitSuccess) healthyImmediately $ \boundary ->
      repairReconcileRecoveryChart boundary "bootstrap-broker"

  pure
    RecoveryRepairProductionRegression
      { repairProductionRegressionStagesTheFourExpectedNames =
          fmap (map snd) (journalStaged installJournal)
            == [
                 [ "install.sh"
                 , "rke2.linux-amd64.tar.gz"
                 , "sha256sum-amd64.txt"
                 , "rke2-images.linux-amd64.tar.zst"
                 ]
               ]
            && map fst (concat (journalStaged installJournal))
              == [ fixedStoreRoot </> ("retained/" ++ retainedArtifactKindText kind)
                 | kind <- substrateInstallKinds
                 ]
      , repairProductionRegressionInstallRunsOverTheStagedDirectory =
          install
            == Right ()
            && [ arguments
               | (RecoveryInstallSubstrate, arguments) <- journalCommands installJournal
               ]
              == [subprocessArguments (substrateInstallSubprocess fixedStagedDirectory)]
            && journalDiscarded installJournal == [fixedStagedDirectory]
      , -- An install missing one of the four refuses before anything is
        -- staged, so the run says which byte source was absent instead of a
        -- root subprocess saying so.
        repairProductionRegressionIncompleteInstallIssuesNothing =
          null (journalStaged incompleteJournal)
            && null (journalCommands incompleteJournal)
      , repairProductionRegressionStagingDiscardedOnFailure =
          journalDiscarded failedJournal == [fixedStagedDirectory]
      , repairProductionRegressionStartEnablesAndStarts =
          [ arguments
          | (RecoveryStartSubstrateService, arguments) <- journalCommands startJournal
          ]
            == [subprocessArguments substrateStartSubprocess]
      , -- The wait stops at the first healthy observation and pauses no more.
        repairProductionRegressionAwaitStopsAtHealthy =
          healthy
            == Right ()
            && journalObservations healthyJournal
              == 1
            && journalPauses healthyJournal
              == 0
      , -- Exhaustion reports the last observation rather than a bare timeout,
        -- and it observes exactly the bound.
        repairProductionRegressionAwaitExhaustsWithLastObservation =
          either
            (Text.isInfixOf "LocalRke2RecoveryStopped")
            (const False)
            never
            && journalObservations neverJournal == substrateApiWaitAttempts wait
      , repairProductionRegressionImageImportAddressesRetainedBytes =
          [ arguments
          | (RecoveryImportRetainedImage, arguments) <- journalCommands importJournal
          ]
            == [ subprocessArguments
                   ( retainedImageImportSubprocess
                       ( fixedStoreRoot
                           </> ("retained/" ++ retainedArtifactKindText RetainedObjectStoreImage)
                       )
                   )
               ]
      , -- The chart arm is the supplied one: this module issues no command for
        -- it and stages nothing.
        repairProductionRegressionChartReconcileIsDelegated =
          charted
            == Right ()
            && null (journalCommands chartJournal)
            && null (journalStaged chartJournal)
      }
 where
  withFixture exit observations use = do
    journal <- newIORef emptyJournal
    remaining <- newIORef observations
    let boundary =
          recoveryRepairBoundaryOver
            (fixedPhysical journal remaining exit)
            fixedArchitecture
            fixedStoreRoot
            wait
            (\_ -> pure (Right ()))
    result <- use boundary
    recorded <- readIORef journal
    pure (result, recorded)

  healthyImmediately = repeat (Right LocalRke2RecoveryHealthy)
  neverHealthy = repeat (Right LocalRke2RecoveryStopped)

fixedPhysical
  :: IORef FixedPhysicalJournal
  -> IORef [Either Text LocalRke2RecoveryStateView]
  -> Either Text ExitCode
  -> RecoveryRepairPhysicalBoundary IO
fixedPhysical journal observations exit =
  RecoveryRepairPhysicalBoundary
    { recoveryStageInstallDirectory = \links -> do
        modifyIORef' journal (\entry -> entry {journalStaged = journalStaged entry ++ [links]})
        pure (Right fixedStagedDirectory)
    , recoveryDiscardInstallDirectory = \directory ->
        modifyIORef'
          journal
          (\entry -> entry {journalDiscarded = journalDiscarded entry ++ [directory]})
    , recoveryRunCommand = \command spec -> do
        modifyIORef'
          journal
          ( \entry ->
              entry
                { journalCommands =
                    journalCommands entry ++ [(command, subprocessArguments spec)]
                }
          )
        pure
          ( fmap
              (\code -> ProcessOutput code "" "the fixed physical boundary refused")
              exit
          )
    , recoveryObserveSubstrate = do
        modifyIORef'
          journal
          (\entry -> entry {journalObservations = journalObservations entry + 1})
        pending <- readIORef observations
        case pending of
          [] -> pure (Left "the fixed physical boundary has no observation left")
          (next : rest) -> do
            writeIORef observations rest
            pure next
    , recoveryPauseMicros = \_ ->
        modifyIORef' journal (\entry -> entry {journalPauses = journalPauses entry + 1})
    }

fixedArchitecture :: RetainedArtifactArchitecture
fixedArchitecture = RetainedArtifactAmd64

fixedStoreRoot :: FilePath
fixedStoreRoot = "/fixed/retained/prodbox/artifacts"

fixedStagedDirectory :: FilePath
fixedStagedDirectory = "/fixed/staging/prodbox-substrate-install"

fixedArtifact :: RetainedArtifactKind -> VerifiedRetainedArtifact
fixedArtifact kind =
  VerifiedRetainedArtifact
    { verifiedRetainedArtifactKind = kind
    , verifiedRetainedArtifactRelativePath =
        "retained/" ++ retainedArtifactKindText kind
    , verifiedRetainedArtifactDigest =
        "sha256:" <> Text.replicate 64 "a"
    }

fixedSubstrateArtifacts :: NonEmpty VerifiedRetainedArtifact
fixedSubstrateArtifacts = NonEmpty.fromList (map fixedArtifact substrateInstallKinds)
