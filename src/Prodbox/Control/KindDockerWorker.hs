{-# LANGUAGE ScopedTypeVariables #-}

-- | Irreversible preparation of a disposable kind worker. This is not
-- admission, executable authentication, endpoint creation, or settlement.
module Prodbox.Control.KindDockerWorker
  ( KindDockerWorkerError (..)
  , prepareKindDockerWorker
  , prepareKindDockerWorkerWithSealedClient
  ) where

import Control.Exception (IOException, try)
import Prodbox.Control.KindDockerFilesystem
  ( KindDockerFilesystemError
  , installKindDockerFilesystemRules
  )
import Prodbox.Control.SealedTool (isSealedToolDescriptor)
import Prodbox.Subprocess.ExecDescriptors
  ( MutationDescriptorError
  , prepareMutationExecDescriptors
  )
import Prodbox.Subprocess.NetworkFilter
  ( MutationNetworkFilterError
  , installMutationMetadataFilter
  , installMutationNetworkFilter
  )
import System.Posix.Files (deviceID, fileID, getFdStatus)
import System.Posix.IO (FdOption (CloseOnExec), queryFdOption, setFdOption)
import System.Posix.Types (Fd (..))

data KindDockerWorkerError
  = KindDockerWorkerFilesystem !KindDockerFilesystemError
  | KindDockerWorkerNetwork !MutationNetworkFilterError
  | KindDockerWorkerMetadata !MutationNetworkFilterError
  | KindDockerWorkerDescriptors !MutationDescriptorError
  | KindDockerWorkerInvalidClientDescriptor
  | KindDockerWorkerClientDescriptorUnconfirmed
  deriving (Eq, Show)

-- | Apply filesystem, network, metadata and exec-descriptor restrictions in
-- that order. The caller must run in a dedicated process on a bound OS thread,
-- establish disjoint roots and descriptor provenance, and exec the verified
-- kind executable on that same thread. Inherited standard streams, endpoint
-- ownership, daemon authentication, deadlines and worker settlement are not
-- established here. Any failure requires terminating the disposable process;
-- earlier restrictions cannot be rolled back.
prepareKindDockerWorker
  :: Fd -> [Fd] -> Fd -> Fd -> Fd -> Fd -> IO (Either KindDockerWorkerError ())
prepareKindDockerWorker scratch roots lock request reply nullDevice = do
  filesystem <- installKindDockerFilesystemRules scratch roots lock request reply nullDevice
  case filesystem of
    Left failure -> pure (Left (KindDockerWorkerFilesystem failure))
    Right () -> do
      network <- installMutationNetworkFilter
      case network of
        Left failure -> pure (Left (KindDockerWorkerNetwork failure))
        Right () -> do
          metadata <- installMutationMetadataFilter
          case metadata of
            Left failure -> pure (Left (KindDockerWorkerMetadata failure))
            Right () -> do
              descriptors <- prepareMutationExecDescriptors
              pure (either (Left . KindDockerWorkerDescriptors) Right descriptors)

-- | Retain exactly one fully sealed executable descriptor across the kind
-- exec. The caller must authenticate its bytes and fund its memory separately;
-- seals prove immutability, not identity or permission. The caller must also
-- guarantee descriptor provenance and exclude concurrent descriptor changes
-- in the dedicated worker process. Any failure requires worker termination.
prepareKindDockerWorkerWithSealedClient
  :: Fd -> [Fd] -> Fd -> Fd -> Fd -> Fd -> Fd -> IO (Either KindDockerWorkerError ())
prepareKindDockerWorkerWithSealedClient scratch roots lock request reply nullDevice client = do
  let boundedRoots = take 33 roots
      Fd rawClient = client
      distinct = client `notElem` (scratch : lock : request : reply : nullDevice : boundedRoots)
  valid <-
    if rawClient >= 3 && distinct
      then do
        sealed <- isSealedToolDescriptor client
        if sealed
          then distinctClientFile client (scratch : lock : request : reply : nullDevice : boundedRoots)
          else pure False
      else pure False
  if not valid
    then pure (Left KindDockerWorkerInvalidClientDescriptor)
    else do
      prepared <- prepareKindDockerWorker scratch boundedRoots lock request reply nullDevice
      case prepared of
        Left failure -> pure (Left failure)
        Right () -> do
          retained <-
            try
              ( do
                  setFdOption client CloseOnExec False
                  closeOnExec <- queryFdOption client CloseOnExec
                  stillSealed <- isSealedToolDescriptor client
                  pure (not closeOnExec && stillSealed)
              )
              :: IO (Either IOException Bool)
          pure $ case retained of
            Right True -> Right ()
            _ -> Left KindDockerWorkerClientDescriptorUnconfirmed

-- Distinct descriptor numbers can still alias the same inode. The worker's
-- client must not alias any filesystem root or bridge endpoint descriptor.
distinctClientFile :: Fd -> [Fd] -> IO Bool
distinctClientFile client others = do
  observed <- try $ do
    initial <- getFdStatus client
    statuses <- traverse getFdStatus others
    let identity status = (deviceID status, fileID status)
    pure (all ((/= identity initial) . identity) statuses)
  pure $ case observed of
    Right distinct -> distinct
    Left (_ :: IOException) -> False
