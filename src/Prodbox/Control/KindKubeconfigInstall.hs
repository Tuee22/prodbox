{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Move the cluster credential kind wrote in a worker's private scratch into
-- the retained root's @control/kubeconfig@. The source is read through
-- no-follow descriptors under the generation-checked root, must be a private
-- regular file owned by the operator, and must validate against the selected
-- scope before anything is written. The destination is created exclusively
-- with mode 0600 inside a 0700 directory and then read back through the
-- ordinary reader. An existing destination is never replaced. The credential
-- bytes are never rendered, logged or placed in an error.
module Prodbox.Control.KindKubeconfigInstall
  ( KindKubeconfigInstall (..)
  , installKindKubeconfig
  ) where

import Control.Exception (IOException, bracket, try)
import Control.Monad (unless)
import Data.Bits ((.&.))
import Data.ByteString qualified as ByteString
import Foreign.C.Error (throwErrnoIfMinus1_)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope
  ( withScopeRootDescriptor
  )
import Prodbox.Control.KindKubeconfigFile (readKindKubeconfig)
import Prodbox.Control.KindKubeconfigYaml (decodeKindKubeconfig)
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError, isEOFError)
import System.Posix.Files qualified as Files
import System.Posix.IO qualified as Posix
import System.Posix.IO.ByteString qualified as PosixBytes
import System.Posix.Types (CMode (..), Fd (..), UserID)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

data KindKubeconfigInstall
  = KindKubeconfigInstalled
  | KindKubeconfigSourceMissing
  | KindKubeconfigSourceUnsafe
  | KindKubeconfigSourceInvalid
  | KindKubeconfigDestinationExists
  | KindKubeconfigWriteFailed
  | KindKubeconfigReadbackFailed
  deriving (Eq, Show)

foreign import capi "sys/stat.h mkdirat" makeDirectoryAt :: CInt -> CString -> CMode -> IO CInt

directoryFlags, readFlags, createFlags :: Posix.OpenFileFlags
directoryFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.directory = True}
readFlags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.nonBlock = True}
createFlags = readFlags {Posix.exclusive = True, Posix.creat = Just 0o600}

-- | The operation names the worker directory. Nothing is installed unless the
-- source validates; the source file is left where kind wrote it.
installKindKubeconfig :: BootstrapProjection -> String -> IO KindKubeconfigInstall
installKindKubeconfig bootstrap operation = do
  outcome <- timeout 20000000 $ withScopeRootDescriptor (bootstrapScope bootstrap) $ \root _ -> do
    owner <- getEffectiveUserID
    source <- readSource root owner
    case source of
      Left failure -> pure failure
      Right bytes -> do
        decoded <- decodeKindKubeconfig (bootstrapScope bootstrap) bytes
        case decoded of
          Left _ -> pure KindKubeconfigSourceInvalid
          Right _ -> writeDestination root owner bytes
  case outcome of
    Just (Right KindKubeconfigInstalled) -> do
      readback <- readKindKubeconfig bootstrap
      pure (either (const KindKubeconfigReadbackFailed) (const KindKubeconfigInstalled) readback)
    Just (Right other) -> pure other
    _ -> pure KindKubeconfigWriteFailed
 where
  workerName = "kind-worker-" ++ operation
  readSource root owner = do
    result <- try $ bracket (Posix.openFdAt (Just root) workerName Posix.ReadOnly directoryFlags) Posix.closeFd $ \worker ->
      bracket (Posix.openFdAt (Just worker) "scratch" Posix.ReadOnly directoryFlags) Posix.closeFd $ \scratch ->
        bracket (Posix.openFdAt (Just scratch) "kubeconfig" Posix.ReadOnly readFlags) Posix.closeFd $ \file -> do
          status <- Files.getFdStatus file
          if not (privateFile owner status) || Files.fileSize status > 524288
            then pure (Left KindKubeconfigSourceUnsafe)
            else Right <$> readAll file
    pure $ case result of
      Right value -> value
      Left (failure :: IOException)
        | isDoesNotExistError failure -> Left KindKubeconfigSourceMissing
        | otherwise -> Left KindKubeconfigSourceUnsafe
  writeDestination root owner bytes = do
    prepared <- try (ensureControlDirectory root owner)
    case prepared of
      Left (_ :: IOException) -> pure KindKubeconfigWriteFailed
      Right False -> pure KindKubeconfigWriteFailed
      Right True -> do
        written <- try $ bracket (Posix.openFdAt (Just root) "control" Posix.ReadOnly directoryFlags) Posix.closeFd $ \control -> do
          created <- try (Posix.openFdAt (Just control) "kubeconfig" Posix.WriteOnly createFlags)
          case created of
            Left (failure :: IOException)
              | isAlreadyExistsError failure -> pure KindKubeconfigDestinationExists
              | otherwise -> pure KindKubeconfigWriteFailed
            Right file -> bracket (pure file) Posix.closeFd $ \held -> do
              count <- PosixBytes.fdWrite held bytes
              unless (fromIntegral count == ByteString.length bytes) (ioError (userError "short write"))
              fileSynchronise held
              fileSynchronise control
              pure KindKubeconfigInstalled
        pure (either (\(_ :: IOException) -> KindKubeconfigWriteFailed) id written)
  ensureControlDirectory root owner = do
    created <-
      try
        ( withCString "control" $ \name -> throwErrnoIfMinus1_ "create control directory" (makeDirectoryAt (fdNumber root) name 0o700)
        )
    case created of
      Right () -> verify root owner
      Left (failure :: IOException)
        | isAlreadyExistsError failure -> verify root owner
        | otherwise -> pure False
  verify root owner =
    bracket (Posix.openFdAt (Just root) "control" Posix.ReadOnly directoryFlags) Posix.closeFd $ \control -> do
      status <- Files.getFdStatus control
      pure
        (Files.isDirectory status && Files.fileOwner status == owner && Files.fileMode status .&. 0o077 == 0)

privateFile :: UserID -> Files.FileStatus -> Bool
privateFile owner status =
  Files.isRegularFile status
    && Files.fileOwner status == owner
    && Files.fileMode status .&. 0o077 == 0
    && Files.linkCount status == 1

readAll :: Fd -> IO ByteString.ByteString
readAll file = ByteString.concat . reverse <$> go [] (0 :: Int)
 where
  go chunks count = do
    result <- try (PosixBytes.fdRead file (fromIntegral (min 65536 (524289 - count))))
    case result of
      Left (failure :: IOException)
        | isEOFError failure -> pure chunks
        | otherwise -> ioError failure
      Right bytes
        | ByteString.null bytes -> pure chunks
        | count + ByteString.length bytes > 524288 -> ioError (userError "oversized")
        | otherwise -> go (bytes : chunks) (count + ByteString.length bytes)

fdNumber :: Fd -> CInt
fdNumber (Fd descriptor) = descriptor
