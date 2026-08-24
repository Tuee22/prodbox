{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Validation-specific composition over the lifecycle-owned cleanup kernel.
--
-- This module selects registered targets, but it does not build a graph,
-- allocate node operation identities, accept mutation callbacks, or interpret
-- cleanup node states.  The canonical program compiler, descriptor-bound
-- runner, closed production dispatcher, and lifecycle result decision own
-- those responsibilities.
module Prodbox.Test.LifecycleCleanupClient
  ( LifecycleTestHarnessCleanupInputs (..)
  , LifecycleTestHarnessCleanupOutcome
  , lifecycleTestHarnessCleanupLifecycleResult
  , lifecycleTestHarnessCleanupAllowsCredentialTeardown
  , lifecycleTestHarnessCleanupExitCode
  , LifecycleTestHarnessCleanupError (..)
  , renderLifecycleTestHarnessCleanupError
  , runLifecycleTestHarnessCleanup
  )
where

import Control.Exception
  ( AsyncException
  , SomeException
  , displayException
  , fromException
  , mask
  , throwIO
  , try
  )
import Data.Char (isAlphaNum)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Numeric.Natural (Natural)
import Prodbox.Aws (awsHarnessAdminScope)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientTransport
  )
import Prodbox.ControlPlane.CleanupRunClient
  ( CleanupRunClientError
  , DescriptorBoundCleanupRun
  , DescriptorBoundCleanupRunClient
  , descriptorBoundCleanupRunClient
  , descriptorBoundCleanupRunId
  , descriptorBoundCleanupRunPrimaryOutcome
  , scanDescriptorBoundCleanupRuns
  , withDescriptorBoundCleanupProgram
  )
import Prodbox.ControlPlane.DescriptorBoundLifecycleRuntime.Internal
  ( descriptorBoundOrdinaryLifecycleNodeActionInternal
  )
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller (LifecycleAuthorityTestHarness)
  , LifecycleAuthorityAuthenticationError
  , renderLifecycleAuthorityAuthenticationError
  , withHostLifecycleAuthorityAuthentication
  , withLifecycleAuthorityAuthenticatedTransport
  )
import Prodbox.ControlPlane.RegisteredStackCreationSubmitter
  ( homeLinuxRke2FoundationId
  )
import Prodbox.Lifecycle.AuthorityConfig
  ( resolveLongLivedCheckpointAuthority
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( checkpointAuthorityClusterId
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupOwnerId
  , CleanupPrimaryOutcome (..)
  , CleanupRunError
  , CleanupRunId
  , cleanupGraphDigest
  , cleanupRunIdText
  , mkCleanupOwnerId
  , mkCleanupRunId
  , newCleanupRun
  )
import Prodbox.Lifecycle.CleanupRunEntry
  ( CleanupHostPreparation (NoHostPreparation)
  , LifecycleCleanupClientError
  , LifecycleCleanupDescriptor
  , LifecycleCleanupDescriptorError
  , LifecycleCleanupResult
  , RegisteredLifecycleCleanup
  , adoptExplicitPerRunLifecycleCleanup
  , attachLifecycleCleanupPrimaryOutcome
  , claimLifecycleCleanupRun
  , lifecycleCleanupNodesSucceeded
  , mkOrdinaryCleanupDescriptor
  , observeLifecycleCleanupResult
  , registerLifecycleCleanupRun
  , registeredLifecycleCleanupBoundRun
  )
import Prodbox.Lifecycle.CleanupRunRunner
  ( CleanupRunDriverError
  , resumeDescriptorBoundDurableCleanupWithContext
  )
import Prodbox.Lifecycle.DnsRecord (HostedZoneId, mkHostedZoneId)
import Prodbox.Lifecycle.Teardown.CloudRuntime (CloudRuntime)
import Prodbox.Lifecycle.Teardown.CloudRuntimeProduction
  ( ProductionCloudRuntimeError
  , ProductionCloudRuntimeInputs (..)
  , mkEksDrainLeaseSeconds
  , productionCloudRuntime
  , renderProductionCloudRuntimeError
  )
import Prodbox.Lifecycle.Teardown.Graph
  ( CompiledDesiredAbsenceProgram
  , DesiredAbsenceGraphError
  , compileDesiredAbsenceGraphForRegisteredKeys
  , compiledDesiredAbsenceGraph
  )
import Prodbox.Lifecycle.Teardown.Model
  ( AwsScope
  , CleanupSurface (ExplicitPerRun)
  , CleanupSurfaceWitness (ExplicitPerRunSurface)
  , RegisteredResourceKey
  )
import Prodbox.Runtime.Role
  ( RuntimeRole (LifecycleAuthorityRuntime)
  )
import Prodbox.Settings
  ( ValidatedCoordinates (coordinateAwsSubstrateZoneId)
  , loadConfigFile
  , validatedCoordinatesFor
  )
import Prodbox.Settings.Coordinate (route53ZoneIdText)
import System.Exit (ExitCode (..))

data LifecycleTestHarnessCleanupInputs = LifecycleTestHarnessCleanupInputs
  { lifecycleTestHarnessRepositoryRoot :: !FilePath
  , lifecycleTestHarnessSuiteId :: !Text
  , lifecycleTestHarnessSelectedTargets :: ![RegisteredResourceKey]
  , lifecycleTestHarnessKubectlEnvironment :: ![(String, String)]
  }

data LifecycleTestHarnessCleanupOutcome = LifecycleTestHarnessCleanupOutcome
  { internalLifecycleTestHarnessPrimaryExit :: !(Maybe ExitCode)
  , internalLifecycleTestHarnessResult :: !LifecycleCleanupResult
  }

lifecycleTestHarnessCleanupLifecycleResult
  :: LifecycleTestHarnessCleanupOutcome -> LifecycleCleanupResult
lifecycleTestHarnessCleanupLifecycleResult = internalLifecycleTestHarnessResult

lifecycleTestHarnessCleanupAllowsCredentialTeardown
  :: LifecycleTestHarnessCleanupOutcome -> Bool
lifecycleTestHarnessCleanupAllowsCredentialTeardown =
  lifecycleCleanupNodesSucceeded . internalLifecycleTestHarnessResult

lifecycleTestHarnessCleanupExitCode
  :: LifecycleTestHarnessCleanupOutcome -> ExitCode
lifecycleTestHarnessCleanupExitCode outcome
  | not (lifecycleCleanupNodesSucceeded (internalLifecycleTestHarnessResult outcome)) =
      ExitFailure 1
  | otherwise = case internalLifecycleTestHarnessPrimaryExit outcome of
      Just exitCode -> exitCode
      Nothing -> ExitFailure 1

data LifecycleTestHarnessCleanupError
  = LifecycleTestHarnessPreparationFailed !Text
  | LifecycleTestHarnessRunIdInvalid !Text
  | LifecycleTestHarnessOwnerInvalid !Text
  | LifecycleTestHarnessProgramInvalid !DesiredAbsenceGraphError
  | LifecycleTestHarnessInitialRunInvalid !CleanupRunError
  | LifecycleTestHarnessDescriptorInvalid !LifecycleCleanupDescriptorError
  | LifecycleTestHarnessAuthenticationFailed
      !LifecycleAuthorityAuthenticationError
  | LifecycleTestHarnessScanFailed !CleanupRunClientError
  | LifecycleTestHarnessMultipleRuns ![CleanupRunId]
  | LifecycleTestHarnessAdoptionFailed !LifecycleCleanupClientError
  | LifecycleTestHarnessRegistrationFailed !LifecycleCleanupClientError
  | LifecycleTestHarnessClaimFailed !LifecycleCleanupClientError
  | LifecycleTestHarnessPrimaryFailed !LifecycleCleanupClientError
  | LifecycleTestHarnessCloudRuntimeInvalid !ProductionCloudRuntimeError
  | LifecycleTestHarnessDriveFailed !CleanupRunDriverError
  deriving stock (Eq, Show)

renderLifecycleTestHarnessCleanupError
  :: LifecycleTestHarnessCleanupError -> String
renderLifecycleTestHarnessCleanupError = \case
  LifecycleTestHarnessPreparationFailed detail -> Text.unpack detail
  LifecycleTestHarnessRunIdInvalid detail -> Text.unpack detail
  LifecycleTestHarnessOwnerInvalid detail -> Text.unpack detail
  LifecycleTestHarnessProgramInvalid err ->
    "compile the lifecycle-owned harness cleanup program: " ++ show err
  LifecycleTestHarnessInitialRunInvalid err ->
    "construct the initial lifecycle cleanup run: " ++ show err
  LifecycleTestHarnessDescriptorInvalid err ->
    "capture the lifecycle cleanup descriptor: " ++ show err
  LifecycleTestHarnessAuthenticationFailed err ->
    renderLifecycleAuthorityAuthenticationError err
  LifecycleTestHarnessScanFailed err ->
    "scan descriptor-bound lifecycle cleanup runs: " ++ show err
  LifecycleTestHarnessMultipleRuns runIds ->
    "more than one nonterminal cleanup run exists for this test suite: "
      ++ show runIds
  LifecycleTestHarnessAdoptionFailed err ->
    "adopt the existing lifecycle cleanup run: " ++ show err
  LifecycleTestHarnessRegistrationFailed err ->
    "register the lifecycle cleanup run: " ++ show err
  LifecycleTestHarnessClaimFailed err ->
    "claim the lifecycle cleanup run: " ++ show err
  LifecycleTestHarnessPrimaryFailed err ->
    "record the validation outcome: " ++ show err
  LifecycleTestHarnessCloudRuntimeInvalid err ->
    renderProductionCloudRuntimeError err
  LifecycleTestHarnessDriveFailed err ->
    "drive the lifecycle cleanup run: " ++ show err

runLifecycleTestHarnessCleanup
  :: LifecycleTestHarnessCleanupInputs
  -> IO ExitCode
  -> IO
       ( Either
           LifecycleTestHarnessCleanupError
           LifecycleTestHarnessCleanupOutcome
       )
runLifecycleTestHarnessCleanup inputs body = do
  prepared <- try (prepareInputs inputs) :: IO (Either SomeException PreparedInputs)
  case prepared of
    Left err ->
      pure
        ( Left
            ( LifecycleTestHarnessPreparationFailed
                (Text.pack (displayException err))
            )
        )
    Right ready -> authenticate ready
 where
  authenticate ready = do
    authenticated <-
      withHostLifecycleAuthorityAuthentication
        LifecycleAuthorityTestHarness
        (lifecycleTestHarnessRepositoryRoot inputs)
        ( \authentication ->
            withLifecycleAuthorityAuthenticatedTransport authentication $ \transport ->
              driveWithTransport ready transport
        )
    pure $ case authenticated of
      Left err -> Left (LifecycleTestHarnessAuthenticationFailed err)
      Right (Left err) -> Left (LifecycleTestHarnessAuthenticationFailed err)
      Right (Right result) -> result

  driveWithTransport ready transport = do
    let client = descriptorBoundCleanupRunClient transport
    scanned <- scanDescriptorBoundCleanupRuns client
    case scanned of
      Left err -> pure (Left (LifecycleTestHarnessScanFailed err))
      Right allRuns -> case matchingRuns ready allRuns of
        [] -> startFresh ready client transport
        [existing] -> resumeExisting ready client transport existing
        duplicates ->
          pure
            ( Left
                ( LifecycleTestHarnessMultipleRuns
                    (descriptorBoundCleanupRunId <$> duplicates)
                )
            )

  startFresh ready client transport = do
    now <- currentMicros
    case newPlan inputs ready now of
      Left err -> pure (Left err)
      Right (owner, descriptor, compiled) -> do
        registered <-
          registerLifecycleCleanupRun NoHostPreparation client descriptor
        case registered of
          Left err -> pure (Left (LifecycleTestHarnessRegistrationFailed err))
          Right admitted ->
            claimAndDrive
              ready
              client
              transport
              owner
              True
              compiled
              admitted

  resumeExisting ready client transport existing =
    case adoptExplicitPerRunLifecycleCleanup existing of
      Left err -> pure (Left (LifecycleTestHarnessAdoptionFailed err))
      Right registered ->
        case compiledFromRegistered registered of
          Left err -> pure (Left err)
          Right compiled -> do
            now <- currentMicros
            case mkOwner now of
              Left err -> pure (Left err)
              Right owner ->
                claimAndDrive
                  ready
                  client
                  transport
                  owner
                  False
                  compiled
                  registered

  claimAndDrive ready client transport owner runPrimary compiled registered = do
    now <- currentMicros
    claimed <-
      claimLifecycleCleanupRun
        client
        owner
        now
        (now + leaseMicros)
        registered
    case claimed of
      Left err -> pure (Left (LifecycleTestHarnessClaimFailed err))
      Right held ->
        case cloudRuntimeFor inputs ready transport held compiled of
          Left err -> pure (Left err)
          Right cloudRuntime ->
            mask $ \restore -> do
              primaryResult <-
                capturePrimaryResult runPrimary (try (restore body))
              attached <- attachPrimary client held primaryResult
              case attached of
                Left err -> rethrowCancellation primaryResult (Left err)
                Right (primaryExit, cleanupReady) -> do
                  driven <-
                    resumeDescriptorBoundDurableCleanupWithContext
                      client
                      owner
                      ( descriptorBoundOrdinaryLifecycleNodeActionInternal
                          cloudRuntime
                          transport
                      )
                      (registeredLifecycleCleanupBoundRun cleanupReady)
                  case driven of
                    Left err ->
                      rethrowCancellation
                        primaryResult
                        (Left (LifecycleTestHarnessDriveFailed err))
                    Right _ -> do
                      terminalNow <- currentMicros
                      result <-
                        observeLifecycleCleanupResult
                          client
                          terminalNow
                          reportRetentionMicros
                          cleanupReady
                      rethrowCancellation
                        primaryResult
                        ( Right
                            LifecycleTestHarnessCleanupOutcome
                              { internalLifecycleTestHarnessPrimaryExit =
                                  primaryExit
                              , internalLifecycleTestHarnessResult = result
                              }
                        )

data PreparedInputs = PreparedInputs
  { preparedFoundation :: !Text
  , preparedAwsScope :: !AwsScope
  , preparedAwsDnsZone :: !(Maybe HostedZoneId)
  , preparedRunPrefix :: !Text
  }

prepareInputs :: LifecycleTestHarnessCleanupInputs -> IO PreparedInputs
prepareInputs inputs = do
  authority <-
    resolveLongLivedCheckpointAuthority
      (lifecycleTestHarnessRepositoryRoot inputs)
      >>= either fail pure
  awsScope <- awsHarnessAdminScope (lifecycleTestHarnessRepositoryRoot inputs)
  config <-
    loadConfigFile (lifecycleTestHarnessRepositoryRoot inputs)
      >>= either fail pure
  coordinates <- either fail pure (validatedCoordinatesFor config)
  awsDnsZone <-
    traverse
      (either (fail . show) pure . mkHostedZoneId . route53ZoneIdText)
      (coordinateAwsSubstrateZoneId coordinates)
  pure
    PreparedInputs
      { preparedFoundation = checkpointAuthorityClusterId authority
      , preparedAwsScope = awsScope
      , preparedAwsDnsZone = awsDnsZone
      , preparedRunPrefix =
          "test-harness-"
            <> sanitizeId (lifecycleTestHarnessSuiteId inputs)
            <> "-"
      }

newPlan
  :: LifecycleTestHarnessCleanupInputs
  -> PreparedInputs
  -> Natural
  -> Either
       LifecycleTestHarnessCleanupError
       ( CleanupOwnerId
       , LifecycleCleanupDescriptor 'ExplicitPerRun
       , CompiledDesiredAbsenceProgram 'ExplicitPerRun
       )
newPlan inputs prepared now = do
  runId <-
    firstText
      LifecycleTestHarnessRunIdInvalid
      (mkCleanupRunId (preparedRunPrefix prepared <> Text.pack (show now)))
  owner <- mkOwner now
  compiled <-
    firstValue
      LifecycleTestHarnessProgramInvalid
      ( compileDesiredAbsenceGraphForRegisteredKeys
          runId
          (homeLinuxRke2FoundationId (preparedFoundation prepared))
          (Just (preparedAwsScope prepared))
          (preparedAwsDnsZone prepared)
          ExplicitPerRunSurface
          (lifecycleTestHarnessSelectedTargets inputs)
      )
  initial <-
    firstValue
      LifecycleTestHarnessInitialRunInvalid
      ( newCleanupRun
          runId
          (compiledDesiredAbsenceGraph compiled)
          owner
          now
          (now + leaseMicros)
      )
  descriptor <-
    firstValue
      LifecycleTestHarnessDescriptorInvalid
      (mkOrdinaryCleanupDescriptor runId compiled initial)
  Right (owner, descriptor, compiled)

compiledFromRegistered
  :: RegisteredLifecycleCleanup 'ExplicitPerRun
  -> Either
       LifecycleTestHarnessCleanupError
       (CompiledDesiredAbsenceProgram 'ExplicitPerRun)
compiledFromRegistered registered =
  case withDescriptorBoundCleanupProgram
    (registeredLifecycleCleanupBoundRun registered)
    selectExplicitPerRunCompiled of
    Left err -> Left (LifecycleTestHarnessScanFailed err)
    Right result -> result

selectExplicitPerRunCompiled
  :: CleanupSurfaceWitness surface
  -> CompiledDesiredAbsenceProgram surface
  -> DescriptorBoundCleanupRun
  -> Either
       LifecycleTestHarnessCleanupError
       (CompiledDesiredAbsenceProgram 'ExplicitPerRun)
selectExplicitPerRunCompiled witness compiled _ = case witness of
  ExplicitPerRunSurface -> Right compiled
  _ ->
    Left
      ( LifecycleTestHarnessPreparationFailed
          "cleanup surface changed during adoption"
      )

cloudRuntimeFor
  :: LifecycleTestHarnessCleanupInputs
  -> PreparedInputs
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> RegisteredLifecycleCleanup 'ExplicitPerRun
  -> CompiledDesiredAbsenceProgram 'ExplicitPerRun
  -> Either
       LifecycleTestHarnessCleanupError
       (CloudRuntime IO)
cloudRuntimeFor inputs _ transport registered compiled = do
  lease <- firstValue LifecycleTestHarnessCloudRuntimeInvalid (mkEksDrainLeaseSeconds 300)
  firstValue
    LifecycleTestHarnessCloudRuntimeInvalid
    ( productionCloudRuntime
        ProductionCloudRuntimeInputs
          { productionCloudRepositoryRoot = lifecycleTestHarnessRepositoryRoot inputs
          , productionCloudCaller = LifecycleAuthorityTestHarness
          , productionCloudKubectlPath = "kubectl"
          , productionCloudKubectlEnvironment =
              lifecycleTestHarnessKubectlEnvironment inputs
          , productionCloudKubectlWorkingDirectory =
              Just (lifecycleTestHarnessRepositoryRoot inputs)
          , productionCloudDrainLease = lease
          }
        transport
        (descriptorBoundCleanupRunId (registeredLifecycleCleanupBoundRun registered))
        (cleanupGraphDigest (compiledDesiredAbsenceGraph compiled))
    )

attachPrimary
  :: DescriptorBoundCleanupRunClient IO
  -> RegisteredLifecycleCleanup 'ExplicitPerRun
  -> Maybe (Either SomeException ExitCode)
  -> IO
       ( Either
           LifecycleTestHarnessCleanupError
           ( Maybe ExitCode
           , RegisteredLifecycleCleanup 'ExplicitPerRun
           )
       )
attachPrimary client registered primaryResult = case primaryResult of
  Nothing ->
    pure
      ( Right
          ( primaryExitCode
              ( descriptorBoundCleanupRunPrimaryOutcome
                  (registeredLifecycleCleanupBoundRun registered)
              )
          , registered
          )
      )
  Just result -> do
    let (exitCode, outcome) = primaryObservation result
    attached <- attachLifecycleCleanupPrimaryOutcome client outcome registered
    pure $ case attached of
      Left err -> Left (LifecycleTestHarnessPrimaryFailed err)
      Right ready -> Right (exitCode, ready)

primaryObservation
  :: Either SomeException ExitCode -> (Maybe ExitCode, CleanupPrimaryOutcome)
primaryObservation result = case result of
  Right ExitSuccess -> (Just ExitSuccess, CleanupPrimarySucceeded)
  Right failure@(ExitFailure code) ->
    (Just failure, CleanupPrimaryExitFailure code)
  Left err
    | isAsync err -> (Nothing, CleanupPrimaryCancelled)
    | otherwise ->
        (Nothing, CleanupPrimaryFailed (Text.pack (displayException err)))

primaryExitCode :: Maybe CleanupPrimaryOutcome -> Maybe ExitCode
primaryExitCode outcome = case outcome of
  Just CleanupPrimarySucceeded -> Just ExitSuccess
  Just (CleanupPrimaryExitFailure code) -> Just (ExitFailure code)
  _ -> Nothing

matchingRuns :: PreparedInputs -> [DescriptorBoundCleanupRun] -> [DescriptorBoundCleanupRun]
matchingRuns prepared =
  filter
    ( \run ->
        preparedRunPrefix prepared
          `Text.isPrefixOf` cleanupRunIdText (descriptorBoundCleanupRunId run)
    )

mkOwner :: Natural -> Either LifecycleTestHarnessCleanupError CleanupOwnerId
mkOwner now =
  firstText
    LifecycleTestHarnessOwnerInvalid
    (mkCleanupOwnerId ("test-harness-owner-" <> Text.pack (show now)))

sanitizeId :: Text -> Text
sanitizeId = Text.map (\character -> if isAlphaNum character then character else '-')

rethrowCancellation
  :: Maybe (Either SomeException ExitCode)
  -> Either LifecycleTestHarnessCleanupError value
  -> IO (Either LifecycleTestHarnessCleanupError value)
rethrowCancellation primaryResult result = case primaryResult of
  Just (Left err) | isAsync err -> throwIO err
  _ -> pure result

isAsync :: SomeException -> Bool
isAsync exception = case fromException exception :: Maybe AsyncException of
  Just _ -> True
  Nothing -> False

currentMicros :: IO Natural
currentMicros = round . (* 1_000_000) <$> getPOSIXTime

leaseMicros :: Natural
leaseMicros = 30 * 60 * 1_000_000

reportRetentionMicros :: Natural
reportRetentionMicros = 0

capturePrimaryResult :: Bool -> IO value -> IO (Maybe value)
capturePrimaryResult shouldRun action = case shouldRun of
  True -> Just <$> action
  False -> pure Nothing

firstText
  :: (Text -> error)
  -> Either Text value
  -> Either error value
firstText constructor = either (Left . constructor) Right

firstValue
  :: (sourceError -> error)
  -> Either sourceError value
  -> Either error value
firstValue constructor = either (Left . constructor) Right
