-- | Irreversible preparation for a disposable mutation worker. This does not
-- authenticate the workspace, standard streams or dependencies, verify an
-- alias-free snapshot, settle descendants, or authorize mutant execution.
module Prodbox.Subprocess.MutationWorker
  ( MutationWorkerError (..)
  , prepareMutationWorker
  ) where

import Control.Concurrent (isCurrentThreadBound)
import Prodbox.Subprocess.ExecDescriptors
  ( MutationDescriptorError
  , prepareMutationExecDescriptors
  )
import Prodbox.Subprocess.MutationFilesystem
  ( MutationFilesystemError
  , installMutationFilesystemRules
  )
import Prodbox.Subprocess.NetworkFilter
  ( MutationNetworkFilterError
  , installMutationMetadataFilter
  , installMutationNetworkFilter
  )
import System.Posix.Types (Fd)

data MutationWorkerError
  = MutationWorkerThreadUnbound
  | MutationWorkerNetwork !MutationNetworkFilterError
  | MutationWorkerMetadata !MutationNetworkFilterError
  | MutationWorkerFilesystem !MutationFilesystemError
  | MutationWorkerDescriptors !MutationDescriptorError
  deriving (Eq, Show)

-- | Apply the tested filter sequence in a dedicated disposable process on a
-- bound OS thread. The caller must establish all descriptor and root custody,
-- then immediately exec on the same thread or terminate after any result.
-- A successful result is not a complete sandbox or permission to run mutants.
prepareMutationWorker :: Fd -> [Fd] -> IO (Either MutationWorkerError ())
prepareMutationWorker workspace roots = do
  bound <- isCurrentThreadBound
  if not bound then pure (Left MutationWorkerThreadUnbound) else prepareBound workspace roots

prepareBound :: Fd -> [Fd] -> IO (Either MutationWorkerError ())
prepareBound workspace roots = do
  network <- installMutationNetworkFilter
  case network of
    Left failure -> pure (Left (MutationWorkerNetwork failure))
    Right () -> do
      metadata <- installMutationMetadataFilter
      case metadata of
        Left failure -> pure (Left (MutationWorkerMetadata failure))
        Right () -> do
          filesystem <- installMutationFilesystemRules workspace roots
          case filesystem of
            Left failure -> pure (Left (MutationWorkerFilesystem failure))
            Right () -> do
              descriptors <- prepareMutationExecDescriptors
              pure (either (Left . MutationWorkerDescriptors) Right descriptors)
