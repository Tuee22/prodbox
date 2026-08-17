-- | Opaque identity of one admitted teardown effect attempt.  The value is
-- minted only after the durable CleanupRun runner and compiled graph agree on
-- the run, graph, node, operation, and fence.  Consumers may bind external
-- requests to it but cannot construct or alter it.
module Prodbox.Lifecycle.Teardown.ExecutionIdentity
  ( TeardownExecutionIdentity
  , teardownExecutionIdentityRunId
  , teardownExecutionIdentityGraphDigest
  , teardownExecutionIdentityNodeId
  , teardownExecutionIdentityOperationId
  , teardownExecutionIdentityAttemptId
  )
where

import Prodbox.Lifecycle.Teardown.ExecutionIdentity.Internal
