{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sealed startup registration for the legacy projection importer.
--
-- The AWS account and target coordinates are secret operational metadata, so
-- they do not belong in the standing-role ConfigMap.  A trusted bootstrap
-- actor records this bounded canonical value at the fixed retained coordinate
-- exported below after observing STS and the authority-owned target registry.
-- The Lifecycle Authority can then construct the production importer without
-- holding provider credentials or accepting caller-supplied coordinates on the
-- import route.
module Prodbox.ControlPlane.ProjectionImportRegistration
  ( ProjectionImportTargetRegistrationWire (..)
  , ProjectionImportRegistrationWire (..)
  , ProjectionImportRegistration
  , ProjectionImportRegistrationError (..)
  , projectionImportRegistrationMaximumBytes
  , mkProjectionImportRegistration
  , encodeProjectionImportRegistration
  , decodeProjectionImportRegistration
  , projectionImportRegistrationModelBCodec
  , projectionImportRegistrationCoordinate
  , projectionImportRegistrationLeaseKey
  , projectionImportRegistrationTargets
  , productionProjectionImportFromRegistration
  )
where

import Codec.Serialise (Serialise)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAscii, isAsciiLower, isDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Codec
  ( ControlPlaneRequestCodecError
  , decodeControlPlaneRequest
  , encodeControlPlaneRequest
  )
import Prodbox.Lifecycle.Authority.ProjectionImport
  ( ProductionProjectionImport
  , mkProductionProjectionImport
  , productionCheckpointProjectionMaximumBytes
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( AuthorityCoordinateError
  , LongLivedCheckpointAuthority
  , ModelBCodec (..)
  , ModelBObjectCoordinate
  , StoreLifetime (ClusterRetained)
  , TargetClusterSecretSink
  , checkpointAuthorityClusterId
  , mkClusterRetainedCoordinate
  , mkTargetClusterSecretSink
  , targetSecretSinkIdentity
  , targetSecretSinkKvPath
  , targetSecretSinkVaultMount
  )
import Prodbox.Lifecycle.Lease
  ( LeaseKey
  , LeasePolicy
  , leaseKeyAccount
  , leaseKeyRegion
  , mkLeaseKey
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( RegisteredTargetSet
  , mkRegisteredTargetSet
  , registeredTargetByIdentity
  )

data ProjectionImportTargetRegistrationWire = ProjectionImportTargetRegistrationWire
  { projectionImportTargetIdentity :: !Text
  , projectionImportTargetVaultMount :: !Text
  , projectionImportTargetKvPath :: !Text
  }
  deriving stock (Eq, Generic)
  deriving anyclass (Serialise)

instance Show ProjectionImportTargetRegistrationWire where
  show _ = "ProjectionImportTargetRegistrationWire <redacted>"

data ProjectionImportRegistrationWire = ProjectionImportRegistrationWire
  { projectionImportAwsAccountId :: !Text
  , projectionImportAwsRegion :: !Text
  , projectionImportTargetCapacity :: !Natural
  , projectionImportTargets :: ![ProjectionImportTargetRegistrationWire]
  }
  deriving stock (Eq, Generic)
  deriving anyclass (Serialise)

instance Show ProjectionImportRegistrationWire where
  show wire =
    "ProjectionImportRegistrationWire {targetCount = "
      ++ show (length (projectionImportTargets wire))
      ++ "}"

data ProjectionImportRegistration = ProjectionImportRegistration
  { internalProjectionImportRegistrationScope :: !Text
  , internalProjectionImportRegistrationWire :: !ProjectionImportRegistrationWire
  , internalProjectionImportRegistrationLeaseKey :: !LeaseKey
  , internalProjectionImportRegistrationTargets :: !RegisteredTargetSet
  }
  deriving stock (Eq)

instance Show ProjectionImportRegistration where
  show registration =
    "ProjectionImportRegistration {targetCount = "
      ++ show
        ( length
            ( projectionImportTargets
                (internalProjectionImportRegistrationWire registration)
            )
        )
      ++ "}"

data ProjectionImportRegistrationError
  = ProjectionImportRegistrationCodecInvalid !ControlPlaneRequestCodecError
  | ProjectionImportRegistrationAccountInvalid
  | ProjectionImportRegistrationRegionInvalid
  | ProjectionImportRegistrationCapacityMismatch !Natural !Natural
  | ProjectionImportRegistrationTargetInvalid !Int
  | ProjectionImportRegistrationTargetLaneInvalid !Int
  | ProjectionImportRegistrationTargetsInvalid
  | ProjectionImportRegistrationLocalTargetMissing
  | ProjectionImportRegistrationLeaseInvalid
  | ProjectionImportRegistrationCoordinateInvalid !AuthorityCoordinateError
  | ProjectionImportRegistrationAuthorityScopeMismatch
  | ProjectionImportRegistrationPlanInvalid
  deriving stock (Eq, Show)

projectionImportRegistrationMaximumBytes :: Int
projectionImportRegistrationMaximumBytes = 64 * 1024

mkProjectionImportRegistration
  :: Text
  -> ProjectionImportRegistrationWire
  -> Either ProjectionImportRegistrationError ProjectionImportRegistration
mkProjectionImportRegistration expectedScope wire = do
  let account = projectionImportAwsAccountId wire
      region = projectionImportAwsRegion wire
      targetWires = projectionImportTargets wire
      actualTargetCount = fromIntegral (length targetWires)
  if validAwsAccountId account
    then Right ()
    else Left ProjectionImportRegistrationAccountInvalid
  if validAwsRegion region
    then Right ()
    else Left ProjectionImportRegistrationRegionInvalid
  if projectionImportTargetCapacity wire == actualTargetCount
    then Right ()
    else
      Left
        ( ProjectionImportRegistrationCapacityMismatch
            (projectionImportTargetCapacity wire)
            actualTargetCount
        )
  targets <- traverse (uncurry validateTarget) (zip [0 ..] targetWires)
  registered <-
    mapLeft
      (const ProjectionImportRegistrationTargetsInvalid)
      (mkRegisteredTargetSet actualTargetCount targets)
  case registeredTargetByIdentity registered expectedScope of
    Nothing -> Left ProjectionImportRegistrationLocalTargetMissing
    Just _ -> Right ()
  leaseKey <-
    mapLeft
      (const ProjectionImportRegistrationLeaseInvalid)
      (mkLeaseKey account region "aws-ses")
  let normalizedWire =
        ProjectionImportRegistrationWire
          { projectionImportAwsAccountId = leaseKeyAccount leaseKey
          , projectionImportAwsRegion = leaseKeyRegion leaseKey
          , projectionImportTargetCapacity = actualTargetCount
          , projectionImportTargets = fmap targetWireFromValidated targets
          }
  Right
    ProjectionImportRegistration
      { internalProjectionImportRegistrationScope = expectedScope
      , internalProjectionImportRegistrationWire = normalizedWire
      , internalProjectionImportRegistrationLeaseKey = leaseKey
      , internalProjectionImportRegistrationTargets = registered
      }
 where
  validateTarget index targetWire = do
    if projectionImportTargetVaultMount targetWire == "secret"
      && projectionImportTargetKvPath targetWire == "keycloak/smtp"
      then Right ()
      else Left (ProjectionImportRegistrationTargetLaneInvalid index)
    mapLeft
      (const (ProjectionImportRegistrationTargetInvalid index))
      ( mkTargetClusterSecretSink
          (projectionImportTargetIdentity targetWire)
          (projectionImportTargetVaultMount targetWire)
          (projectionImportTargetKvPath targetWire)
      )

encodeProjectionImportRegistration
  :: ProjectionImportRegistration
  -> LazyByteString.ByteString
encodeProjectionImportRegistration =
  encodeControlPlaneRequest . internalProjectionImportRegistrationWire

decodeProjectionImportRegistration
  :: Text
  -> LazyByteString.ByteString
  -> Either ProjectionImportRegistrationError ProjectionImportRegistration
decodeProjectionImportRegistration expectedScope bytes = do
  wire <-
    mapLeft
      ProjectionImportRegistrationCodecInvalid
      ( decodeControlPlaneRequest
          projectionImportRegistrationMaximumBytes
          bytes
      )
  mkProjectionImportRegistration expectedScope wire

projectionImportRegistrationModelBCodec
  :: Text
  -> ModelBCodec ProjectionImportRegistration
projectionImportRegistrationModelBCodec expectedScope =
  ModelBCodec
    { encodeModelBValue =
        Right . LazyByteString.toStrict . encodeProjectionImportRegistration
    , decodeModelBValue =
        mapLeft show
          . decodeProjectionImportRegistration expectedScope
          . LazyByteString.fromStrict
    }

projectionImportRegistrationCoordinate
  :: LongLivedCheckpointAuthority
  -> Either
       ProjectionImportRegistrationError
       (ModelBObjectCoordinate 'ClusterRetained)
projectionImportRegistrationCoordinate authority =
  mapLeft
    ProjectionImportRegistrationCoordinateInvalid
    ( mkClusterRetainedCoordinate
        authority
        "authority/projection-import-registration"
    )

projectionImportRegistrationLeaseKey
  :: ProjectionImportRegistration
  -> LeaseKey
projectionImportRegistrationLeaseKey =
  internalProjectionImportRegistrationLeaseKey

projectionImportRegistrationTargets
  :: ProjectionImportRegistration
  -> RegisteredTargetSet
projectionImportRegistrationTargets =
  internalProjectionImportRegistrationTargets

productionProjectionImportFromRegistration
  :: LongLivedCheckpointAuthority
  -> LongLivedCheckpointAuthority
  -> LeasePolicy
  -> ProjectionImportRegistration
  -> Either ProjectionImportRegistrationError ProductionProjectionImport
productionProjectionImportFromRegistration
  legacyAuthority
  replacementAuthority
  leasePolicy
  registration
    | checkpointAuthorityClusterId legacyAuthority /= registeredScope =
        Left ProjectionImportRegistrationAuthorityScopeMismatch
    | checkpointAuthorityClusterId replacementAuthority /= registeredScope =
        Left ProjectionImportRegistrationAuthorityScopeMismatch
    | otherwise =
        mapLeft
          (const ProjectionImportRegistrationPlanInvalid)
          ( mkProductionProjectionImport
              legacyAuthority
              replacementAuthority
              (projectionImportRegistrationLeaseKey registration)
              leasePolicy
              (projectionImportRegistrationTargets registration)
              productionCheckpointProjectionMaximumBytes
          )
   where
    registeredScope = internalProjectionImportRegistrationScope registration

targetWireFromValidated
  :: TargetClusterSecretSink
  -> ProjectionImportTargetRegistrationWire
targetWireFromValidated target =
  ProjectionImportTargetRegistrationWire
    { projectionImportTargetIdentity = targetSecretSinkIdentity target
    , projectionImportTargetVaultMount = targetSecretSinkVaultMount target
    , projectionImportTargetKvPath = targetSecretSinkKvPath target
    }

validAwsAccountId :: Text -> Bool
validAwsAccountId value =
  Text.length value == 12
    && Text.all (\character -> isAscii character && isDigit character) value

validAwsRegion :: Text -> Bool
validAwsRegion value =
  case (Text.uncons value, Text.unsnoc value) of
    (Just (first, _), Just (_, lastCharacter)) ->
      Text.length value <= 63
        && Text.all validCharacter value
        && first /= '-'
        && lastCharacter /= '-'
    _ -> False
 where
  validCharacter character =
    isAscii character
      && (isAsciiLower character || isDigit character || character == '-')

mapLeft :: (left -> other) -> Either left right -> Either other right
mapLeft convert result = case result of
  Left err -> Left (convert err)
  Right value -> Right value
