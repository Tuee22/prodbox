-- | Sprint 4.50: the destroy-and-read-back seam that binds a decommission
-- 'DecommissionNode' to a real destructive operation.
--
-- Every node the destroy subgraph runs performs the same shape: attempt the
-- destroy, then re-observe the external authority and require a positively
-- observed absence before reporting success. The observation soundness rule of
-- 'Prodbox.Lifecycle.ResidueStatus' is load-bearing here: a read-back that comes
-- back @ResiduePresent@ (still there) or @ResidueUnreachable@ (could not be read)
-- both FAIL — "cannot observe" is never silently treated as "gone", so a torn or
-- degraded read can never authorize the run to advance to the shared bucket.
--
-- The classification and the per-node dispatch are pure over an injected
-- 'NodeOperation', so a fake interpreter exercises every arm without touching a
-- live cluster, Vault, object store, or AWS account. Supplying the production
-- 'NodeOperation's — the real @destroyAwsSesStack@, live-Target-Agent tombstones,
-- @destroyRetainedPublicEdgeTls@, and @destroyLongLivedPulumiStateBucket@ calls
-- with their re-observations — is the live-coupled boundary this seam isolates.
module Prodbox.Lifecycle.Decommission.NodeEffect
  ( NodeOperation (..)
  , classifyReadBack
  , runNodeOperation
  , DecommissionNodeInterpreter (..)
  , runDecommissionNode
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.Decommission.Manifest (DecommissionNode)
import Prodbox.Lifecycle.ResidueStatus
  ( ResidueStatus
  , isResidueAbsent
  , renderResidueStatus
  )

-- | One node's destructive operation: the destroy attempt and the re-observation
-- that must confirm absence afterwards.
data NodeOperation m = NodeOperation
  { nodeDestroy :: m (Either Text ())
  , nodeReadBack :: m ResidueStatus
  }

-- | Classify a read-back. Only a positively observed absence confirms the destroy;
-- @ResiduePresent@ and @ResidueUnreachable@ both fail, so an unobservable read is a
-- refusal, never an assumed success.
classifyReadBack :: ResidueStatus -> Either Text ()
classifyReadBack status
  | isResidueAbsent status = Right ()
  | otherwise =
      Left (Text.pack ("read-back did not confirm absence: " ++ renderResidueStatus status))

-- | Run one node operation: attempt the destroy, and only if it reported success
-- re-observe and require a confirmed absence.
runNodeOperation :: (Monad m) => NodeOperation m -> m (Either Text ())
runNodeOperation operation = do
  destroyed <- nodeDestroy operation
  case destroyed of
    Left detail -> pure (Left detail)
    Right () -> classifyReadBack <$> nodeReadBack operation

-- | The per-node dispatch: the total mapping from a manifest node to its
-- destructive operation. The production interpreter binds each node to its real
-- destroy + re-observe; a fake interpreter binds in-memory operations.
newtype DecommissionNodeInterpreter m = DecommissionNodeInterpreter
  { nodeOperationFor :: DecommissionNode -> NodeOperation m
  }

-- | The node effect the destroy subgraph executor consumes:
-- @runDecommissionGraph nodes (runDecommissionNode interpreter)@.
runDecommissionNode
  :: (Monad m) => DecommissionNodeInterpreter m -> DecommissionNode -> m (Either Text ())
runDecommissionNode interpreter = runNodeOperation . nodeOperationFor interpreter
