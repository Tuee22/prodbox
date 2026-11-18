{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Interpret Kubernetes PV/PVC objects as one observation. Callers must
-- separately bracket provider reads and verify the actual host and Pod mounts.
module Prodbox.Control.KindVolumeReadback
  ( KindVolumeBindingObservation (..)
  , KindVolumeReadError (..)
  , KindVolumeReadStage (..)
  , KindVolumeBracketObservation (..)
  , classifyKindVolumeBinding
  , observeKindVolumeBinding
  )
where

import Control.Exception (IOException, try)
import Control.Monad (unless)
import Data.Aeson (Value, withObject, (.:), (.:?))
import Data.Aeson.Types (Parser, parseEither)
import Prodbox.Config.KindVolume
  ( KindVolume
  , kindVolumeCapacityMib
  , kindVolumeName
  , kindVolumeNamespace
  , kindVolumeNodePath
  )

data KindVolumeBindingObservation
  = KindVolumeBindingObserved !String !String !String !String
  | KindVolumeBindingNotBound
  | KindVolumeBindingMismatch
  deriving (Eq, Show)

data KindVolumeReadError
  = KindVolumeReadUnavailable
  | KindVolumeReadDenied
  | KindVolumeReadNotFound
  | KindVolumeReadInvalid
  deriving (Eq, Show)

data KindVolumeReadStage = FirstVolume | FirstClaim | FirstPair | SecondVolume | SecondClaim | SecondPair
  deriving (Eq, Show)

data KindVolumeBracketObservation
  = KindVolumeStableBinding !KindVolumeBindingObservation
  | KindVolumeBindingUnconfirmed !KindVolumeBindingObservation
  | KindVolumeBindingChanged !KindVolumeBindingObservation
  | KindVolumeReadFailed !KindVolumeReadStage !KindVolumeReadError
  | KindVolumeReadbackInvalid !KindVolumeReadStage
  deriving (Eq, Show)

-- | Compare two independently supplied reads of each named object. Reader
-- failures remain staged failures, and only matching bound identities and
-- resource versions yield a stable observation. The supplied readers must
-- already be bound to the intended authenticated cluster and bounded by their
-- caller; this helper does not provide that binding or prove a Pod mount.
observeKindVolumeBinding
  :: KindVolume
  -> IO (Either KindVolumeReadError Value)
  -> IO (Either KindVolumeReadError Value)
  -> IO KindVolumeBracketObservation
observeKindVolumeBinding expected readVolume readClaim = do
  firstPv <- readAt FirstVolume readVolume
  case firstPv of
    Left failure -> pure failure
    Right pv | Left _ <- parseEither parseVolume pv -> pure (KindVolumeReadbackInvalid FirstVolume)
    Right pv -> do
      firstClaim <- readAt FirstClaim readClaim
      case firstClaim of
        Left failure -> pure failure
        Right claim | Left _ <- parseEither parseClaim claim -> pure (KindVolumeReadbackInvalid FirstClaim)
        Right claim -> case classifyKindVolumeBinding expected pv claim of
          Left _ -> pure (KindVolumeReadbackInvalid FirstPair)
          Right first@KindVolumeBindingObserved {} -> do
            secondPv <- readAt SecondVolume readVolume
            case secondPv of
              Left failure -> pure failure
              Right finalPv | Left _ <- parseEither parseVolume finalPv -> pure (KindVolumeReadbackInvalid SecondVolume)
              Right finalPv -> do
                secondClaim <- readAt SecondClaim readClaim
                case secondClaim of
                  Left failure -> pure failure
                  Right finalClaim | Left _ <- parseEither parseClaim finalClaim -> pure (KindVolumeReadbackInvalid SecondClaim)
                  Right finalClaim -> case classifyKindVolumeBinding expected finalPv finalClaim of
                    Left _ -> pure (KindVolumeReadbackInvalid SecondPair)
                    Right final
                      | final == first -> pure (KindVolumeStableBinding first)
                      | otherwise -> pure (KindVolumeBindingChanged first)
          Right other -> pure (KindVolumeBindingUnconfirmed other)
 where
  readAt stage action = do
    attempted <- try action
    pure $ case attempted of
      Left (_ :: IOException) -> Left (KindVolumeReadFailed stage KindVolumeReadUnavailable)
      Right (Left failure) -> Left (KindVolumeReadFailed stage failure)
      Right (Right value) -> Right value

data VolumeReadback = VolumeReadback
  { pvName :: !String
  , pvUid :: !String
  , pvVersion :: !String
  , pvDeleting :: !Bool
  , pvPhase :: !String
  , pvCapacity :: !String
  , pvAccess :: ![String]
  , pvMode :: !String
  , pvReclaim :: !String
  , pvClass :: !String
  , pvPath :: !String
  , pvPathType :: !String
  , pvClaim :: !(Maybe (String, String, Maybe String))
  }

data ClaimReadback = ClaimReadback
  { claimName :: !String
  , claimNamespace :: !String
  , claimUid :: !String
  , claimVersion :: !String
  , claimDeleting :: !Bool
  , claimPhase :: !String
  , claimVolume :: !String
  , claimCapacity :: !String
  , claimAccess :: ![String]
  , claimMode :: !String
  , claimClass :: !String
  }

-- | Classify two decoded API objects. A matching Bound pair records object
-- identities and versions, but is not a Pod mount or a durable ownership
-- proof. Missing or malformed fields return an error rather than absence.
classifyKindVolumeBinding
  :: KindVolume -> Value -> Value -> Either String KindVolumeBindingObservation
classifyKindVolumeBinding expected pvValue claimValue = do
  pv <- parseEither parseVolume pvValue
  claim <- parseEither parseClaim claimValue
  if not
    ( validIdentity (pvUid pv)
        && validIdentity (claimUid claim)
        && validVersion (pvVersion pv)
        && validVersion (claimVersion claim)
    )
    then Left "invalid object identity or resource version"
    else
      if not (matches pv claim)
        then Right KindVolumeBindingMismatch
        else
          if pvDeleting pv || claimDeleting claim || pvPhase pv /= "Bound" || claimPhase claim /= "Bound"
            then Right KindVolumeBindingNotBound
            else case pvClaim pv of
              Just (referenceNamespace, referenceName, Just uid)
                | referenceNamespace == kindVolumeNamespace expected
                    && referenceName == kindVolumeName expected
                    && uid == claimUid claim ->
                    Right (KindVolumeBindingObserved (pvUid pv) (pvVersion pv) (claimUid claim) (claimVersion claim))
              _ -> Right KindVolumeBindingMismatch
 where
  name = kindVolumeName expected
  namespace = kindVolumeNamespace expected
  size = show (kindVolumeCapacityMib expected) ++ "Mi"
  modes = ["ReadWriteOnce"]
  matches pv claim =
    pvName pv == name
      && claimName claim == name
      && claimNamespace claim == namespace
      && pvCapacity pv == size
      && claimCapacity claim == size
      && pvAccess pv == modes
      && claimAccess claim == modes
      && pvMode pv == "Filesystem"
      && claimMode claim == "Filesystem"
      && pvReclaim pv == "Retain"
      && null (pvClass pv)
      && null (claimClass claim)
      && pvPath pv == kindVolumeNodePath expected
      && pvPathType pv == "Directory"
      && claimVolume claim == name
      && case pvClaim pv of
        Nothing -> True
        Just (claimNs, claimNameValue, _) -> claimNs == namespace && claimNameValue == name
  validIdentity value = not (null value) && length value <= 128 && all (\c -> c >= '!' && c <= '~') value
  validVersion = validIdentity

parseVolume :: Value -> Parser VolumeReadback
parseVolume = withObject "PV" $ \object -> do
  kind <- object .: "kind"
  apiVersion <- object .: "apiVersion"
  unless
    (kind == ("PersistentVolume" :: String) && apiVersion == ("v1" :: String))
    (fail "unexpected PV type")
  metadata <- object .: "metadata"
  spec <- object .: "spec"
  status <- object .: "status"
  capacity <- spec .: "capacity"
  hostPath <- spec .: "hostPath"
  claim <- spec .:? "claimRef" >>= traverse parseReference
  VolumeReadback
    <$> metadata .: "name"
    <*> metadata .: "uid"
    <*> metadata .: "resourceVersion"
    <*> ((/= Nothing) <$> (metadata .:? "deletionTimestamp" :: Parser (Maybe String)))
    <*> status .: "phase"
    <*> capacity .: "storage"
    <*> spec .: "accessModes"
    <*> spec .: "volumeMode"
    <*> spec .: "persistentVolumeReclaimPolicy"
    <*> spec .: "storageClassName"
    <*> hostPath .: "path"
    <*> hostPath .: "type"
    <*> pure claim

parseReference :: Value -> Parser (String, String, Maybe String)
parseReference = withObject "claimRef" $ \reference ->
  (,,) <$> reference .: "namespace" <*> reference .: "name" <*> reference .:? "uid"

parseClaim :: Value -> Parser ClaimReadback
parseClaim = withObject "PVC" $ \object -> do
  kind <- object .: "kind"
  apiVersion <- object .: "apiVersion"
  unless
    (kind == ("PersistentVolumeClaim" :: String) && apiVersion == ("v1" :: String))
    (fail "unexpected PVC type")
  metadata <- object .: "metadata"
  spec <- object .: "spec"
  status <- object .: "status"
  resources <- spec .: "resources"
  requests <- resources .: "requests"
  ClaimReadback
    <$> metadata .: "name"
    <*> metadata .: "namespace"
    <*> metadata .: "uid"
    <*> metadata .: "resourceVersion"
    <*> ((/= Nothing) <$> (metadata .:? "deletionTimestamp" :: Parser (Maybe String)))
    <*> status .: "phase"
    <*> spec .: "volumeName"
    <*> requests .: "storage"
    <*> spec .: "accessModes"
    <*> spec .: "volumeMode"
    <*> spec .: "storageClassName"
