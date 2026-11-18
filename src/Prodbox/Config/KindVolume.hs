{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Candidate static retained-volume coordinates for kind. Rendering does not
-- create directories, verify mount generations, or authorize Kubernetes writes.
module Prodbox.Config.KindVolume
  ( KindVolume
  , KindVolumeError (..)
  , KindVolumeObservation (..)
  , KindVolumePreparation (..)
  , kindVolume
  , kindVolumeName
  , kindVolumeNodePath
  , kindVolumeNamespace
  , kindVolumeCapacityMib
  , kindVolumeScope
  , kindVolumeGeneration
  , observeKindVolumeDirectory
  , kindVolumeComponents
  , renderKindVolumeResources
  )
where

import Control.Exception (IOException, bracket, mask, try)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (encode, object, (.=))
import Data.Bits ((.&.))
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAsciiLower)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric (showHex)
import Prodbox.Config.DeploymentScope
  ( DeploymentScope
  , ScopeGenerationObservation (ScopeGenerationMatches)
  , observeScopeGeneration
  , scopeKindName
  , scopeRoot
  , validRootGeneration
  , withScopeRootDescriptor
  )
import System.FilePath ((</>))
import System.IO.Error (isDoesNotExistError)
import System.Posix.Files (deviceID, fileID, fileMode, fileOwner, getFdStatus, isDirectory)
import System.Posix.IO qualified as Posix
import System.Posix.Types (Fd, UserID)
import System.Posix.User (getEffectiveUserID)

data KindVolumeError
  = KindVolumeInvalidGeneration
  | KindVolumeInvalidCoordinate
  | KindVolumeInvalidCapacity
  deriving (Eq, Show)

data KindVolumeObservation
  = KindVolumeDirectoryPresent
  | KindVolumeDirectoryMissing
  | KindVolumeDirectoryUnsafe
  | KindVolumeDirectoryChanged
  | KindVolumeGenerationUnavailable
  | KindVolumeDirectoryUnobservable
  deriving (Eq, Show)

data KindVolumePreparation
  = KindVolumeDirectoryCreated
  | KindVolumeDirectoryAlreadyExists
  | KindVolumePreparationRefused
  | KindVolumePreparationIncomplete
  deriving (Eq, Show)

data KindVolume = KindVolume
  { kindVolumeName :: !String
  , kindVolumeNodePath :: !FilePath
  , volumeNamespace :: !String
  , volumeCapacityMib :: !Int
  , volumeScope :: !DeploymentScope
  , volumeGeneration :: !String
  , volumeComponents :: ![FilePath]
  }
  deriving (Eq, Show)

kindVolumeNamespace :: KindVolume -> String
kindVolumeNamespace = volumeNamespace

kindVolumeCapacityMib :: KindVolume -> Int
kindVolumeCapacityMib = volumeCapacityMib

kindVolumeScope :: KindVolume -> DeploymentScope
kindVolumeScope = volumeScope

kindVolumeGeneration :: KindVolume -> String
kindVolumeGeneration = volumeGeneration

kindVolumeComponents :: KindVolume -> [FilePath]
kindVolumeComponents = volumeComponents

-- | Construct candidate coordinates for one named service volume. A changed
-- generation produces a distinct name and path; a caller must still refuse an
-- unverified or replaced root before creating or attaching anything.
kindVolume
  :: DeploymentScope -> String -> String -> String -> String -> Int -> Either KindVolumeError KindVolume
kindVolume scope generation namespace service volume capacity
  | not (validRootGeneration generation) = Left KindVolumeInvalidGeneration
  | not (all validLabel [namespace, service, volume]) = Left KindVolumeInvalidCoordinate
  | capacity <= 0 || capacity > 1048576 = Left KindVolumeInvalidCapacity
  | otherwise =
      Right
        KindVolume
          { kindVolumeName = "prodbox-" ++ take 40 digest
          , kindVolumeNodePath =
              "/var/lib/prodbox/control/volumes" </> generation </> namespace </> service </> volume
          , volumeNamespace = namespace
          , volumeCapacityMib = capacity
          , volumeScope = scope
          , volumeGeneration = generation
          , volumeComponents = ["control", "volumes", generation, namespace, service, volume]
          }
 where
  material =
    Text.intercalate
      "\NUL"
      ( map
          Text.pack
          [ "prodbox-kind-volume-v1"
          , scopeRoot scope
          , scopeKindName scope
          , generation
          , namespace
          , service
          , volume
          ]
      )
  digest = concatMap hexByte (ByteString.unpack (SHA256.hash (TextEncoding.encodeUtf8 material)))
  hexByte byte = let rendered = showHex byte "" in if length rendered == 1 then '0' : rendered else rendered

validLabel :: String -> Bool
validLabel [] = False
validLabel name@(first : rest) =
  length name <= 63
    && alphaNumeric first
    && alphaNumeric (foldl (\_ character -> character) first rest)
    && all (\character -> alphaNumeric character || character == '-') name
 where
  alphaNumeric character = isAsciiLower character || (character >= '0' && character <= '9')

-- | Observe an existing volume directory twice while its first descriptor walk
-- remains held. This does not create storage, prove a node mount or grant an
-- attachment; bind mounts, concurrent writers and later changes need separate
-- admission and read-back checks.
observeKindVolumeDirectory :: KindVolume -> IO KindVolumeObservation
observeKindVolumeDirectory volume = do
  attempted <- try $ withScopeRootDescriptor scope $ \root sameRoot -> do
    owner <- getEffectiveUserID
    generation <- observeScopeGeneration scope (volumeGeneration volume)
    if generation /= Right ScopeGenerationMatches
      then pure KindVolumeGenerationUnavailable
      else do
        first <- withVolumePath owner root (volumeComponents volume) $ \identities -> do
          second <- withVolumePath owner root (volumeComponents volume) pure
          stable <- sameRoot
          finalGeneration <- observeScopeGeneration scope (volumeGeneration volume)
          pure $
            if not stable || finalGeneration /= Right ScopeGenerationMatches
              then KindVolumeDirectoryChanged
              else case second of
                Right other | other == identities -> KindVolumeDirectoryPresent
                Right _ -> KindVolumeDirectoryChanged
                Left KindVolumeDirectoryMissing -> KindVolumeDirectoryChanged
                Left _ -> KindVolumeDirectoryUnobservable
        stable <- sameRoot
        finalGeneration <- observeScopeGeneration scope (volumeGeneration volume)
        pure $
          if stable && finalGeneration == Right ScopeGenerationMatches
            then volumeObservation first
            else KindVolumeDirectoryChanged
  pure $ case attempted of
    Left (_ :: IOException) -> KindVolumeDirectoryUnobservable
    Right (Left _) -> KindVolumeDirectoryUnobservable
    Right (Right observed) -> observed
 where
  scope = volumeScope volume

volumeObservation :: Either KindVolumeObservation KindVolumeObservation -> KindVolumeObservation
volumeObservation (Left observation) = observation
volumeObservation (Right observation) = observation

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

-- | Render a statically prebound PV and PVC. The hostPath is required to exist;
-- neither rendering nor Kubernetes Retain is a local data-purge policy.
renderKindVolumeResources :: KindVolume -> LazyByteString.ByteString
renderKindVolumeResources volume =
  encode $
    object
      [ "apiVersion" .= ("v1" :: Text.Text)
      , "kind" .= ("List" :: Text.Text)
      , "items" .= [persistentVolume, persistentVolumeClaim]
      ]
 where
  name = kindVolumeName volume
  namespace = volumeNamespace volume
  size = show (volumeCapacityMib volume) ++ "Mi"
  metadata = object ["name" .= name]
  modes = ["ReadWriteOnce" :: Text.Text]
  persistentVolume =
    object
      [ "apiVersion" .= ("v1" :: Text.Text)
      , "kind" .= ("PersistentVolume" :: Text.Text)
      , "metadata" .= metadata
      , "spec"
          .= object
            [ "capacity" .= object ["storage" .= size]
            , "accessModes" .= modes
            , "volumeMode" .= ("Filesystem" :: Text.Text)
            , "persistentVolumeReclaimPolicy" .= ("Retain" :: Text.Text)
            , "storageClassName" .= ("" :: Text.Text)
            , "claimRef" .= object ["namespace" .= namespace, "name" .= name]
            , "hostPath" .= object ["path" .= kindVolumeNodePath volume, "type" .= ("Directory" :: Text.Text)]
            ]
      ]
  persistentVolumeClaim =
    object
      [ "apiVersion" .= ("v1" :: Text.Text)
      , "kind" .= ("PersistentVolumeClaim" :: Text.Text)
      , "metadata" .= object ["name" .= name, "namespace" .= namespace]
      , "spec"
          .= object
            [ "accessModes" .= modes
            , "volumeMode" .= ("Filesystem" :: Text.Text)
            , "storageClassName" .= ("" :: Text.Text)
            , "volumeName" .= name
            , "resources" .= object ["requests" .= object ["storage" .= size]]
            ]
      ]
