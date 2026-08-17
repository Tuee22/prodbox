{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Host-side composition of the retained CleanupRun protocol. Authentication,
-- authority-scope recovery, complete-plan compilation, and create-before-primary
-- ordering live here so command runners cannot accidentally reorder them.
module Prodbox.Test.DurableCleanupComposition
  ( DurableCleanupCompositionError (..)
  , runDurableCleanupComposition
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.CleanupRunClient (cleanupRunClient)
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller (LifecycleAuthorityTestHarness)
  , renderLifecycleAuthorityAuthenticationError
  , withHostLifecycleAuthorityAuthentication
  , withLifecycleAuthorityAuthenticatedTransport
  )
import Prodbox.Lifecycle.CleanupRun
  ( CleanupNodeOutcome
  , CleanupNodePlan
  , CleanupOwnerId
  , CleanupRunId
  , mkCleanupOwnerId
  , mkCleanupRunId
  , newCleanupRun
  )
import Prodbox.Lifecycle.CleanupRunRunner
  ( CleanupRunDriverError
  , CleanupRunDriverResult
  , recoverNonterminalCleanupRuns
  , runWithDurableCleanupOutcome
  )
import Prodbox.Test.ManagedCleanupPlan
  ( CapabilityBoundCleanupAction
  , ManagedCleanupEdge
  , ManagedCleanupPlan
  , ManagedCleanupPlanError
  , compileCapabilityBoundCleanupPlan
  , managedCleanupGraph
  , runManagedCleanupNode
  )

data DurableCleanupCompositionError
  = DurableCleanupIdentityInvalid !Text
  | DurableCleanupPlanInvalid !ManagedCleanupPlanError
  | DurableCleanupRunInvalid !Text
  | DurableCleanupAuthenticationFailed !Text
  | DurableCleanupRecoveryFailed ![CleanupRunDriverError]
  | DurableCleanupDriverFailed !CleanupRunDriverError
  deriving stock (Eq, Show)

runDurableCleanupComposition
  :: FilePath
  -> [CapabilityBoundCleanupAction]
  -> [CapabilityBoundCleanupAction]
  -> [ManagedCleanupEdge]
  -> IO (Either Text value)
  -> IO (Either DurableCleanupCompositionError (CleanupRunDriverResult value))
runDurableCleanupComposition repoRoot recoveryActions actions edges primary = do
  now <- currentMicros
  case identities now of
    Left err -> pure (Left err)
    Right (runId, owner) -> case ( compileCapabilityBoundCleanupPlan runId recoveryActions []
                                 , compileCapabilityBoundCleanupPlan runId actions edges
                                 ) of
      (Left err, _) -> pure (Left (DurableCleanupPlanInvalid err))
      (_, Left err) -> pure (Left (DurableCleanupPlanInvalid err))
      (Right recoveryPlan, Right plan) -> case newCleanupRun runId (managedCleanupGraph plan) owner now (now + leaseMicros) of
        Left err -> pure (Left (DurableCleanupRunInvalid (Text.pack (show err))))
        Right run -> authenticate $ \client -> do
          recovered <-
            recoverNonterminalCleanupRuns
              client
              owner
              now
              (now + leaseMicros)
              (runNode recoveryPlan)
          case recovered of
            Left failures -> pure (Left (DurableCleanupRecoveryFailed failures))
            Right _ -> do
              driven <-
                runWithDurableCleanupOutcome
                  maximumBytes
                  client
                  run
                  owner
                  shieldMicros
                  primary
                  (runNode plan)
              pure (either (Left . DurableCleanupDriverFailed) Right driven)
 where
  runNode :: ManagedCleanupPlan -> CleanupNodePlan -> IO CleanupNodeOutcome
  runNode = runManagedCleanupNode repoRoot

  authenticate action = do
    authenticated <-
      withHostLifecycleAuthorityAuthentication LifecycleAuthorityTestHarness repoRoot $ \authentication ->
        withLifecycleAuthorityAuthenticatedTransport authentication (action . cleanupRunClient)
    pure $ case authenticated of
      Left err -> Left (authError err)
      Right (Left err) -> Left (authError err)
      Right (Right value) -> value

  authError =
    DurableCleanupAuthenticationFailed
      . Text.pack
      . renderLifecycleAuthorityAuthenticationError

identities
  :: Natural
  -> Either DurableCleanupCompositionError (CleanupRunId, CleanupOwnerId)
identities now = do
  runId <- firstIdentity (mkCleanupRunId ("test-run-" <> rendered))
  owner <- firstIdentity (mkCleanupOwnerId ("test-runner-" <> rendered))
  pure (runId, owner)
 where
  rendered = Text.pack (show now)
  firstIdentity = either (Left . DurableCleanupIdentityInvalid) Right

currentMicros :: IO Natural
currentMicros = round . (* 1000000) <$> getPOSIXTime

leaseMicros :: Natural
leaseMicros = 30 * 60 * 1000000

shieldMicros :: Int
shieldMicros = 30 * 60 * 1000000

maximumBytes :: Int
maximumBytes = 1024 * 1024
