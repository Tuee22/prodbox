{-# LANGUAGE DerivingStrategies #-}

-- | Private constructor for the exact identity admitted by the durable
-- cleanup runner and the compiled teardown graph.
module Prodbox.Lifecycle.Teardown.ExecutionIdentity.Internal
  ( TeardownExecutionIdentity
  , mkTeardownExecutionIdentity
  , teardownExecutionIdentityRunId
  , teardownExecutionIdentityGraphDigest
  , teardownExecutionIdentityNodeId
  , teardownExecutionIdentityOperationId
  , teardownExecutionIdentityAttemptId
  )
where

import Prodbox.Lifecycle.CleanupRun
  ( CleanupAttemptId
  , CleanupDigest
  , CleanupNodeId
  , CleanupOperationId
  , CleanupRunId
  )

data TeardownExecutionIdentity = TeardownExecutionIdentity
  { teardownExecutionIdentityRunId :: !CleanupRunId
  , teardownExecutionIdentityGraphDigest :: !CleanupDigest
  , teardownExecutionIdentityNodeId :: !CleanupNodeId
  , teardownExecutionIdentityOperationId :: !CleanupOperationId
  , teardownExecutionIdentityAttemptId :: !CleanupAttemptId
  }
  deriving stock (Eq, Show)

mkTeardownExecutionIdentity
  :: CleanupRunId
  -> CleanupDigest
  -> CleanupNodeId
  -> CleanupOperationId
  -> CleanupAttemptId
  -> TeardownExecutionIdentity
mkTeardownExecutionIdentity = TeardownExecutionIdentity
