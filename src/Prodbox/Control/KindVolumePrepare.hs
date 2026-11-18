{-# LANGUAGE CApiFFI #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

-- | Internal interpreter used only within the volume operation boundary.
module Prodbox.Control.KindVolumePrepare (prepareKindVolumeDirectory) where

import Control.Exception (IOException, bracket, mask, throwIO, try)
import Data.Bits ((.&.))
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text qualified as Text
import Foreign.C.Error (throwErrnoIfMinus1_)
import Foreign.C.String (CString, withCString)
import Foreign.C.Types (CInt (..))
import Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , bootstrapRootGeneration
  , bootstrapScope
  )
import Prodbox.Config.DeploymentScope
  ( ScopeGenerationObservation (ScopeGenerationMatches)
  , observeScopeGeneration
  , withScopeRootDescriptor
  )
import Prodbox.Config.KindVolume
import System.IO.Error (isAlreadyExistsError, isDoesNotExistError)
import System.Posix.Files (deviceID, fileID, fileMode, fileOwner, getFdStatus, isDirectory)
import System.Posix.IO qualified as Posix
import System.Posix.Types (CMode (..), Fd (..), UserID)
import System.Posix.Unistd (fileSynchronise)
import System.Posix.User (getEffectiveUserID)
import System.Timeout (timeout)

foreign import capi "sys/stat.h mkdirat"
  makeVolumeDirectoryAt :: CInt -> CString -> CMode -> IO CInt

-- | Create a previously absent leaf under a held, generation-checked root.
-- The caller must hold the matching operation lease and durable intent and
-- supply its recheck. Existing leaves are never adopted. An incomplete result
-- retains any created directories for explicit recovery; it is not authority
-- to attach storage or proof that a node mounts this path.
prepareKindVolumeDirectory
  :: BootstrapProjection -> KindVolume -> IO Bool -> IO KindVolumePreparation
prepareKindVolumeDirectory bootstrap volume recheck
  | bootstrapScope bootstrap /= scope
      || Text.unpack (bootstrapRootGeneration bootstrap) /= kindVolumeGeneration volume =
      pure KindVolumePreparationRefused
  | otherwise = do
      changed <- newIORef False
      result <- timeout 10000000 $ try @IOException $ withScopeRootDescriptor scope $ \root sameRoot -> do
        owner <- getEffectiveUserID
        let stable = do
              current <- sameRoot
              generation <- observeScopeGeneration scope (kindVolumeGeneration volume)
              permitted <- recheck
              pure (current && generation == Right ScopeGenerationMatches && permitted)
            flags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.directory = True}
            descend parent prefix identities remaining = case remaining of
              [] -> do
                ready <- stable
                observed <- withVolumePath owner root prefix pure
                pure
                  ( if ready && observed == Right identities
                      then KindVolumeDirectoryCreated
                      else KindVolumePreparationRefused
                  )
              component : rest -> do
                ready <- stable
                observed <- withVolumePath owner root prefix pure
                if not ready || observed /= Right identities
                  then pure KindVolumePreparationRefused
                  else mask $ \restore -> do
                    made <- try $ withCString component $ \name ->
                      throwErrnoIfMinus1_ "mkdirat kind volume" (makeVolumeDirectoryAt (fdNumber parent) name 0o700)
                    case made of
                      Left (failure :: IOException)
                        | isAlreadyExistsError failure && null rest -> pure KindVolumeDirectoryAlreadyExists
                        | isAlreadyExistsError failure -> openChild restore parent prefix identities component rest
                        | otherwise -> throwIO failure
                      Right () -> do
                        writeIORef changed True
                        fileSynchronise parent
                        openChild restore parent prefix identities component rest
            openChild restore parent prefix identities component rest =
              bracket (Posix.openFdAt (Just parent) component Posix.ReadOnly flags) Posix.closeFd $ \child -> restore $ do
                status <- getFdStatus child
                if not (isDirectory status && fileOwner status == owner && fileMode status .&. 0o022 == 0)
                  then pure KindVolumePreparationRefused
                  else do
                    fileSynchronise child
                    descend child (prefix ++ [component]) (identities ++ [identity status]) rest
        descend root [] [] (kindVolumeComponents volume)
      touched <- readIORef changed
      pure $ case result of
        Just (Right (Right KindVolumeDirectoryCreated)) -> KindVolumeDirectoryCreated
        _ | touched -> KindVolumePreparationIncomplete
        Just (Right (Right outcome)) -> outcome
        _ -> KindVolumePreparationRefused
 where
  scope = kindVolumeScope volume
  fdNumber (Fd number) = number
  identity status = (toInteger (deviceID status), toInteger (fileID status))

withVolumePath
  :: UserID
  -> Fd
  -> [FilePath]
  -> ([(Integer, Integer)] -> IO value)
  -> IO (Either KindVolumeObservation value)
withVolumePath owner root components use = descend root components []
 where
  flags = Posix.defaultFileFlags {Posix.nofollow = True, Posix.cloexec = True, Posix.directory = True}
  descend _ [] identities = Right <$> use (reverse identities)
  descend parent (component : remaining) identities = mask $ \restore -> do
    opened <- try (Posix.openFdAt (Just parent) component Posix.ReadOnly flags)
    case opened of
      Left (failure :: IOException) ->
        pure $
          Left
            (if isDoesNotExistError failure then KindVolumeDirectoryMissing else KindVolumeDirectoryUnobservable)
      Right descriptor -> bracket (pure descriptor) Posix.closeFd $ \held -> restore $ do
        status <- getFdStatus held
        if not (isDirectory status && fileOwner status == owner && fileMode status .&. 0o022 == 0)
          then pure (Left KindVolumeDirectoryUnsafe)
          else descend held remaining ((toInteger (deviceID status), toInteger (fileID status)) : identities)
