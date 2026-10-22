{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.39: typed lifecycle helpers for pre-created EBS volumes backing
-- EKS static @Retain@ PersistentVolumes. The module owns the EC2
-- @describe-volumes@ / @delete-volume@ subprocess boundary and keeps the
-- lifecycle decisions pure so registry and tag-policy tests do not need live
-- AWS.
module Prodbox.Lifecycle.EbsVolume
  ( EbsVolumeId (..)
  , EbsVolume (..)
  , EbsVolumeScope (..)
  , EbsRequiredVolume (..)
  , EbsDiscoverInput (..)
  , EbsEnsureInput (..)
  , EbsEnsureEffects (..)
  , EbsDestroyInput (..)
  , TestEbsReaperInput (..)
  , TestEbsReaperPlan (..)
  , TestEbsReaperReport (..)
  , TestEbsObservation
  , testEbsObservationVolumeIds
  , testScopedEbsObservation
  , renderTestScopedEbsObservation
  , parseTestScopedEbsObservation
  , RetainedEbsReaperInput (..)
  , RetainedEbsReaperPlan (..)
  , RetainedEbsReaperReport (..)
  , RetainedEbsObservation
  , retainedEbsObservationVolumeIds
  , retainedEbsObservation
  , renderRetainedEbsObservation
  , parseRetainedEbsObservation
  , retainedEbsVolumeIdsFromTagRows
  , retainedEbsReaperPlan
  , renderRetainedEbsReaperReport
  , runRetainedEbsReaper
  , ebsManagedResourceName
  , ebsPerRunTestResourceName
  , ebsProductionRetainedResourceName
  , ebsPersistentVolumeTagKey
  , ebsDescribeVolumesArgs
  , ebsCreateVolumeArgs
  , ebsDescribeVolumesByIdArgs
  , ebsDeleteVolumeArgs
  , ebsRequiredVolumeFromChartStorageBinding
  , parseStorageSizeGiB
  , parseDescribeVolumesPayload
  , parseCreateVolumePayload
  , retainedEbsVolumeBindingsFromDiscovered
  , retainedVolumeSizeProblems
  , missingRequiredVolumes
  , awaitRequiredVolumesVisible
  , retainedEbsVisibilityAttempts
  , retainedEbsVisibilityStableReads
  , ebsVolumesResidueStatus
  , ebsDiscoverResultToResidue
  , testScopedEbsVolumeIdsFromTagRows
  , testScopedEbsReaperPlan
  , ebsVolumeTagRows
  , ebsVolumeResourceCoordinate
  , ebsVolumeIdFromArn
  , renderTestScopedEbsReaperReport
  , AwsCliRun
  , discoverEbsVolumes
  , discoverEbsVolumesVia
  , ensureRetainedEbsVolumes
  , ensureRetainedEbsVolumesVia
  , ensureRetainedEbsVolumesWith
  , createRetainedVolumeVia
  , waitForCreatedVolumesVia
  , destroyEbsVolume
  , destroyEbsVolumeVia
  , runTestScopedEbsReaper
  , runTestScopedEbsReaperVia
  , runRetainedEbsReaperVia
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (foldM)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson
  ( Value (..)
  , eitherDecode
  )
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bifunctor (first)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString.Char8 qualified as ByteString8
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (isDigit, isHexDigit)
import Data.List (intercalate, isInfixOf, nub, sort)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Prodbox.Capacity.ProviderWorkerBudget (providerWorkerIntentLifetimeMicros)
import Prodbox.ControlPlane.OperationBudget (WaitFact (VolumesAvailable))
import Prodbox.Lib.Storage
  ( ChartStorageBinding (..)
  , StaticEbsVolumeBinding (..)
  )
import Prodbox.Lifecycle.AwsWait
  ( AwsWaitEnvironment
  , WaitStep (..)
  , awaitFact
  , renderWaitFailure
  , transientPollFailure
  , wallClockWaitEnvironment
  )
import Prodbox.Lifecycle.ResidueStatus
  ( ResidueDetails (..)
  , ResidueStatus (..)
  , ResidueUnreachableReason (..)
  )
import Prodbox.Lifecycle.TagSweep qualified as TagSweep
import Prodbox.Result (Result (..))
import Prodbox.Settings.AwsSubstrateProfile
  ( AwsEbsVolumeType
  , awsEbsVolumeTypeText
  )
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  )
import System.Exit (ExitCode (..))

newtype EbsVolumeId = EbsVolumeId {unEbsVolumeId :: String}
  deriving (Eq, Ord, Show)

data EbsVolume = EbsVolume
  { ebsVolumeId :: EbsVolumeId
  , ebsVolumeState :: String
  , ebsVolumeAvailabilityZone :: Maybe String
  , ebsVolumeTags :: [(String, String)]
  , ebsVolumeSizeGiB :: Maybe Int
  -- ^ The size EC2 reports, in GiB (Sprint 5.53). Optional in the payload: the
  -- per-run reaper and the residue reports never read it. The retained-volume
  -- binding requires it, because a volume bound under a larger claim is a
  -- silent data-loss waiting for the claim to fill.
  }
  deriving (Eq, Show)

data EbsRequiredVolume = EbsRequiredVolume
  { ebsRequiredPersistentVolumeName :: String
  , ebsRequiredSizeGiB :: Int
  , ebsRequiredAvailabilityZone :: String
  }
  deriving (Eq, Show)

data EbsVolumeScope
  = EbsRetainedProduction
  | EbsPerRunTest String
  deriving (Eq, Show)

data EbsDiscoverInput = EbsDiscoverInput
  { ebsDiscoverEnvironment :: [(String, String)]
  , ebsDiscoverWorkingDirectory :: Maybe FilePath
  , ebsDiscoverScope :: EbsVolumeScope
  }
  deriving (Eq, Show)

data EbsEnsureInput = EbsEnsureInput
  { ebsEnsureEnvironment :: [(String, String)]
  , ebsEnsureWorkingDirectory :: Maybe FilePath
  , ebsEnsureVolumeType :: AwsEbsVolumeType
  }
  deriving (Eq, Show)

-- | What the retained-volume ensure does to the outside world, as a record, so
-- its order, its waits and what it says when it fails are exercised without an
-- AWS account. 'ensureRetainedEbsVolumes' builds the production record from an
-- 'EbsEnsureInput'.
data EbsEnsureEffects m = EbsEnsureEffects
  { ebsEffectDiscover :: m (Either String [EbsVolume])
  -- ^ One listing of the retained volumes.
  , ebsEffectCreate :: EbsRequiredVolume -> m (Either String EbsVolumeId)
  -- ^ Create one volume; the id EC2 answered with.
  , ebsEffectWaitAvailable :: [EbsVolumeId] -> m (Either String ())
  -- ^ Wait until the volumes this call created are available.
  , ebsEffectPause :: m ()
  -- ^ The pause between two listings.
  }

data EbsDestroyInput = EbsDestroyInput
  { ebsDestroyEnvironment :: [(String, String)]
  , ebsDestroyWorkingDirectory :: Maybe FilePath
  }
  deriving (Eq, Show)

data TestEbsReaperInput = TestEbsReaperInput
  { testEbsReaperEnvironment :: [(String, String)]
  , testEbsReaperWorkingDirectory :: Maybe FilePath
  , testEbsReaperClusterName :: String
  }
  deriving (Eq, Show)

data TestEbsReaperPlan = TestEbsReaperPlan
  { testEbsReaperScope :: EbsVolumeScope
  , testEbsReaperVolumeIds :: [EbsVolumeId]
  }
  deriving (Eq, Show)

data TestEbsReaperReport = TestEbsReaperReport
  { testEbsReaperMatchedVolumeIds :: [EbsVolumeId]
  , testEbsReaperDeletedVolumeIds :: [EbsVolumeId]
  }
  deriving (Eq, Show)

-- | Sprint 7.36: the retained family's reaper inputs.  It carries no cluster
-- name, because the retained family is not owned by a cluster — that is the
-- whole reason it survives a cascade.
data RetainedEbsReaperInput = RetainedEbsReaperInput
  { retainedEbsReaperEnvironment :: [(String, String)]
  , retainedEbsReaperWorkingDirectory :: Maybe FilePath
  }
  deriving (Eq, Show)

data RetainedEbsReaperPlan = RetainedEbsReaperPlan
  { retainedEbsReaperVolumeIds :: [EbsVolumeId]
  }
  deriving (Eq, Show)

data RetainedEbsReaperReport = RetainedEbsReaperReport
  { retainedEbsReaperMatchedVolumeIds :: [EbsVolumeId]
  , retainedEbsReaperDeletedVolumeIds :: [EbsVolumeId]
  }
  deriving (Eq, Show)

-- | Canonical, bounded evidence returned by the Provider Worker for the
-- exact test-scoped EBS family.  The constructor is private so a malformed,
-- duplicated, or non-canonical volume set cannot be treated as provider
-- truth by a lifecycle observer.
newtype TestEbsObservation = TestEbsObservation [EbsVolumeId]
  deriving (Eq, Show)

testEbsObservationVolumeIds :: TestEbsObservation -> [EbsVolumeId]
testEbsObservationVolumeIds (TestEbsObservation volumeIds) = volumeIds

-- | Project only the registry-owned per-run family.  This deliberately
-- repeats the client-side tag narrowing used by the reaper; the AWS query
-- filter alone is not authority to classify a returned volume.
testScopedEbsObservation :: String -> [EbsVolume] -> TestEbsObservation
testScopedEbsObservation clusterName volumes =
  TestEbsObservation
    ( sort
        ( nub
            ( testEbsReaperVolumeIds
                (testScopedEbsReaperPlan clusterName volumes)
            )
        )
    )

renderTestScopedEbsObservation :: TestEbsObservation -> Text.Text
renderTestScopedEbsObservation (TestEbsObservation volumeIds) =
  case volumeIds of
    [] -> testEbsObservationPrefix <> "absent"
    _ ->
      testEbsObservationPrefix
        <> "present:"
        <> Text.pack (intercalate "," (map unEbsVolumeId volumeIds))

-- | Decode only the exact canonical wire.  Empty, duplicate, unsorted,
-- over-bounded, or malformed volume identities refuse instead of becoming
-- absence or partial evidence.
parseTestScopedEbsObservation :: Text.Text -> Either String TestEbsObservation
parseTestScopedEbsObservation raw
  | raw == testEbsObservationPrefix <> "absent" =
      Right (TestEbsObservation [])
  | Just encoded <- Text.stripPrefix (testEbsObservationPrefix <> "present:") raw = do
      let renderedIds = Text.splitOn "," encoded
      if null renderedIds || any Text.null renderedIds
        then Left "test-scoped EBS observation has no volume identities"
        else Right ()
      if length renderedIds > maximumTestEbsObservationVolumes
        then Left "test-scoped EBS observation exceeds the volume bound"
        else Right ()
      volumeIds <- traverse parseVolumeId renderedIds
      let canonical = sort (nub volumeIds)
      if volumeIds /= canonical
        then Left "test-scoped EBS observation volume identities are not canonical"
        else Right (TestEbsObservation canonical)
  | otherwise = Left "test-scoped EBS observation has an unsupported encoding"
 where
  parseVolumeId rendered =
    let value = Text.unpack rendered
        suffix = drop 4 value
     in if take 4 value == "vol-"
          && length suffix `elem` [8, 17]
          && all (\character -> isHexDigit character && character `notElem` ['A' .. 'F']) suffix
          then Right (EbsVolumeId value)
          else Left "test-scoped EBS observation contains an invalid volume identity"

testEbsObservationPrefix :: Text.Text
testEbsObservationPrefix = "prodbox-test-ebs-observation/v1:"

-- | Sprint 7.36: the same bounded canonical evidence for the __retained__
-- family.  It is a distinct type, not a reuse of 'TestEbsObservation', because
-- the two families have opposite default dispositions: a per-run volume is
-- meant to go away and a retained volume is meant to survive.  Letting one
-- decode as the other would let a per-run observation answer for the family
-- whose deletion needs an explicit long-lived surface.
newtype RetainedEbsObservation = RetainedEbsObservation [EbsVolumeId]
  deriving (Eq, Show)

retainedEbsObservationVolumeIds :: RetainedEbsObservation -> [EbsVolumeId]
retainedEbsObservationVolumeIds (RetainedEbsObservation volumeIds) = volumeIds

retainedEbsObservationPrefix :: Text.Text
retainedEbsObservationPrefix = "prodbox-retained-ebs-observation/v1:"

-- | Project only the registry-owned retained family, re-filtering client-side
-- on the volumes' own tags exactly as 'testScopedEbsObservation' does.  The
-- query filter narrowed the request; this narrows the answer, and neither is
-- authority on its own.
retainedEbsObservation :: [EbsVolume] -> RetainedEbsObservation
retainedEbsObservation volumes =
  RetainedEbsObservation
    (sort (nub (retainedEbsReaperVolumeIds (retainedEbsReaperPlan volumes))))

renderRetainedEbsObservation :: RetainedEbsObservation -> Text.Text
renderRetainedEbsObservation (RetainedEbsObservation volumeIds) =
  renderEbsObservationBody retainedEbsObservationPrefix volumeIds

parseRetainedEbsObservation :: Text.Text -> Either String RetainedEbsObservation
parseRetainedEbsObservation raw =
  RetainedEbsObservation
    <$> parseEbsObservationBody retainedEbsObservationPrefix "retained" raw

-- | The one canonical wire grammar both EBS families use.  Sharing the writer
-- keeps the two encodings from drifting; the distinct prefixes keep one from
-- decoding as the other.
renderEbsObservationBody :: Text.Text -> [EbsVolumeId] -> Text.Text
renderEbsObservationBody prefix volumeIds =
  case volumeIds of
    [] -> prefix <> "absent"
    _ -> prefix <> "present:" <> Text.pack (intercalate "," (map unEbsVolumeId volumeIds))

parseEbsObservationBody
  :: Text.Text -> String -> Text.Text -> Either String [EbsVolumeId]
parseEbsObservationBody prefix familyName raw
  | raw == prefix <> "absent" = Right []
  | Just encoded <- Text.stripPrefix (prefix <> "present:") raw = do
      let renderedIds = Text.splitOn "," encoded
      if null renderedIds || any Text.null renderedIds
        then Left (familyName ++ " EBS observation has no volume identities")
        else Right ()
      if length renderedIds > maximumTestEbsObservationVolumes
        then Left (familyName ++ " EBS observation exceeds the volume bound")
        else Right ()
      volumeIds <- traverse parseObservedVolumeId renderedIds
      let canonical = sort (nub volumeIds)
      if volumeIds /= canonical
        then Left (familyName ++ " EBS observation volume identities are not canonical")
        else Right canonical
  | otherwise = Left (familyName ++ " EBS observation has an unsupported encoding")
 where
  parseObservedVolumeId rendered =
    let value = Text.unpack rendered
        suffix = drop 4 value
     in if take 4 value == "vol-"
          && length suffix `elem` [8, 17]
          && all (\character -> isHexDigit character && character `notElem` ['A' .. 'F']) suffix
          then Right (EbsVolumeId value)
          else Left (familyName ++ " EBS observation contains an invalid volume identity")

maximumTestEbsObservationVolumes :: Int
maximumTestEbsObservationVolumes = 128

-- | Sprint 4.84: the registered managed-resource identity of one EBS scope.
--
-- This was a single constant, @\"aws-ebs-volumes\"@, so a discovered volume
-- was reported under the same identity whichever scope had discovered it, and
-- the two families' different cleanup policies had to be recovered downstream
-- from the runtime tag set. The scope is already the thing that chose the
-- query, so it is the thing that names the answer: the two names here are the
-- two statically-classed registry identities
-- ('Prodbox.Lifecycle.ResourceClass.resourceLifecycleClasses'), and their
-- agreement with the typed registry keys is enforced by @prodbox dev check@.
ebsManagedResourceName :: EbsVolumeScope -> String
ebsManagedResourceName scope = case scope of
  EbsRetainedProduction -> ebsProductionRetainedResourceName
  EbsPerRunTest _ -> ebsPerRunTestResourceName

-- | The @LongLived@ registered identity. Matches
-- 'Prodbox.Lifecycle.Teardown.Model.AwsEbsProductionRetainedKey'.
ebsProductionRetainedResourceName :: String
ebsProductionRetainedResourceName = "aws-ebs-volumes-production-retained"

-- | The @PerRun@ registered identity. Matches
-- 'Prodbox.Lifecycle.Teardown.Model.AwsEbsPerRunTestKey'.
ebsPerRunTestResourceName :: String
ebsPerRunTestResourceName = "aws-ebs-volumes-per-run-test"

ebsPersistentVolumeTagKey :: String
ebsPersistentVolumeTagKey = "prodbox.io/persistent-volume"

-- | Sprint 4.77: **one** @--filters@ occurrence carrying every filter value.
--
-- The AWS CLI parses list-valued options with @store@, so a repeated option
-- *replaces* the earlier occurrence rather than accumulating. This builder
-- previously emitted @--filters@ twice under 'EbsPerRunTest', so the request
-- AWS actually received carried only @kubernetes.io\/cluster\/\<name\>=owned@ —
-- the ownership and lifecycle filters were dropped on the wire while the
-- source read as though all three were sent. Measured:
--
-- > aws ec2 describe-volumes --filters A B --filters C
-- >   -> body: Filter.1.Name = C          (A and B never sent)
--
-- The defect is invisible to any test that does not assert on the argument
-- list, which is why 'ebsDescribeVolumesArgs' is pinned exactly for both
-- scopes.
ebsDescribeVolumesArgs :: EbsVolumeScope -> [String]
ebsDescribeVolumesArgs scope =
  [ "ec2"
  , "describe-volumes"
  , "--output"
  , "json"
  , "--filters"
  ]
    ++ [ tagFilter TagSweep.prodboxManagedByTagKey TagSweep.prodboxManagedByTagValue
       , tagFilter TagSweep.ebsLifecycleTagKey lifecycleValue
       ]
    ++ clusterFilterValues
 where
  (lifecycleValue, clusterFilterValues) = case scope of
    EbsRetainedProduction -> (TagSweep.ebsRetainedLifecycleValue, [])
    EbsPerRunTest clusterName ->
      ( TagSweep.ebsTestScopedLifecycleValue
      , [tagFilter (TagSweep.ebsClusterOwnedTagKey clusterName) "owned"]
      )

ebsDeleteVolumeArgs :: EbsVolumeId -> [String]
ebsDeleteVolumeArgs volumeId =
  [ "ec2"
  , "delete-volume"
  , "--volume-id"
  , unEbsVolumeId volumeId
  ]

ebsCreateVolumeArgs :: AwsEbsVolumeType -> EbsRequiredVolume -> [String]
ebsCreateVolumeArgs volumeType required =
  [ "ec2"
  , "create-volume"
  , "--client-token"
  , retainedEbsCreateClientToken required
  , "--availability-zone"
  , ebsRequiredAvailabilityZone required
  , "--size"
  , show (ebsRequiredSizeGiB required)
  , "--volume-type"
  , Text.unpack (awsEbsVolumeTypeText volumeType)
  , "--tag-specifications"
  , retainedVolumeTagSpecification required
  , "--output"
  , "json"
  ]

-- | The retained family is account/region-scoped by EC2 and keyed by PV name.
-- Size, type and zone deliberately do not mint a new identity: EC2 must refuse
-- conflicting parameters rather than duplicate a volume behind a lagging read.
-- JSON framing and a domain version keep the 64-byte ASCII token unambiguous.
retainedEbsCreateClientToken :: EbsRequiredVolume -> String
retainedEbsCreateClientToken required =
  ByteString8.unpack
    ( convertToBase
        Base16
        ( SHA256.hash
            ( BL8.toStrict
                ( Aeson.encode
                    [ "prodbox-retained-ebs-create/v1"
                    , ebsRequiredPersistentVolumeName required
                    ]
                )
            )
        )
    )

-- | The exact volumes, by id. Sprint 4.109: the answer a volume wait polls
-- for; the @aws ec2 wait volume-available@ child it replaces polls for minutes
-- inside a child the Provider stops at thirty seconds.
ebsDescribeVolumesByIdArgs :: [EbsVolumeId] -> [String]
ebsDescribeVolumesByIdArgs volumeIds =
  ["ec2", "describe-volumes", "--volume-ids"] ++ map unEbsVolumeId volumeIds ++ ["--output", "json"]

retainedVolumeTagSpecification :: EbsRequiredVolume -> String
retainedVolumeTagSpecification required =
  "ResourceType=volume,Tags=["
    ++ intercalate
      ","
      [ tag "Name" (ebsRequiredPersistentVolumeName required)
      , tag TagSweep.prodboxManagedByTagKey TagSweep.prodboxManagedByTagValue
      , tag TagSweep.ebsLifecycleTagKey TagSweep.ebsRetainedLifecycleValue
      , tag ebsPersistentVolumeTagKey (ebsRequiredPersistentVolumeName required)
      ]
    ++ "]"
 where
  tag key value = "{Key=" ++ key ++ ",Value=" ++ value ++ "}"

ebsRequiredVolumeFromChartStorageBinding
  :: String -> ChartStorageBinding -> Either String EbsRequiredVolume
ebsRequiredVolumeFromChartStorageBinding availabilityZone binding = do
  sizeGiB <- parseStorageSizeGiB (chartStorageBindingStorageSize binding)
  pure
    EbsRequiredVolume
      { ebsRequiredPersistentVolumeName = chartStorageBindingPersistentVolumeName binding
      , ebsRequiredSizeGiB = sizeGiB
      , ebsRequiredAvailabilityZone = availabilityZone
      }

parseStorageSizeGiB :: String -> Either String Int
parseStorageSizeGiB value =
  case span isDigit value of
    ("", _) -> Left ("storage size must start with a positive GiB integer: " ++ value)
    (digits, suffix)
      | suffix `elem` ["Gi", "GiB"] ->
          let size = read digits
           in if size > 0
                then Right size
                else Left ("storage size must be positive: " ++ value)
      | otherwise -> Left ("storage size must use Gi or GiB units: " ++ value)

tagFilter :: String -> String -> String
tagFilter key value = "Name=tag:" ++ key ++ ",Values=" ++ value

parseDescribeVolumesPayload :: String -> Either String [EbsVolume]
parseDescribeVolumesPayload payload = do
  value <- eitherDecode (BL8.pack payload) :: Either String Value
  case value of
    Object obj -> case KeyMap.lookup "Volumes" obj of
      Nothing -> Right []
      Just (Array volumes) -> traverse parseVolumeValue (Vector.toList volumes)
      Just _ -> Left "ec2 describe-volumes payload field `Volumes` is not an array"
    _ -> Left "ec2 describe-volumes payload is not a JSON object"

parseCreateVolumePayload :: String -> Either String EbsVolume
parseCreateVolumePayload payload = do
  value <- eitherDecode (BL8.pack payload) :: Either String Value
  parseVolumeValue value

parseVolumeValue :: Value -> Either String EbsVolume
parseVolumeValue volumeValue = case volumeValue of
  Object obj -> do
    volumeId <- requiredStringField "VolumeId" obj
    state <- requiredStringField "State" obj
    pure
      EbsVolume
        { ebsVolumeId = EbsVolumeId volumeId
        , ebsVolumeState = state
        , ebsVolumeAvailabilityZone = optionalStringField "AvailabilityZone" obj
        , ebsVolumeTags = tagsField obj
        , ebsVolumeSizeGiB = optionalIntField "Size" obj
        }
  _ -> Left "ec2 describe-volumes entry is not a JSON object"

requiredStringField :: String -> KeyMap.KeyMap Value -> Either String String
requiredStringField fieldName obj =
  case KeyMap.lookup (Key.fromString fieldName) obj of
    Just (String textValue) -> Right (Text.unpack textValue)
    Nothing -> Left ("ec2 describe-volumes entry missing `" ++ fieldName ++ "`")
    Just _ -> Left ("ec2 describe-volumes entry field `" ++ fieldName ++ "` is not a string")

optionalStringField :: String -> KeyMap.KeyMap Value -> Maybe String
optionalStringField fieldName obj =
  case KeyMap.lookup (Key.fromString fieldName) obj of
    Just (String textValue) -> Just (Text.unpack textValue)
    _ -> Nothing

-- | A whole number, or nothing: a field that is absent, not a number, or not an
-- integer in range reads as unreported rather than as a parse failure, because
-- only the retained-volume binding needs it and it refuses by name when it is
-- missing.
optionalIntField :: String -> KeyMap.KeyMap Value -> Maybe Int
optionalIntField fieldName obj =
  case KeyMap.lookup (Key.fromString fieldName) obj of
    Just numeric@(Number _) -> case Aeson.fromJSON numeric of
      Aeson.Success whole -> Just whole
      Aeson.Error _ -> Nothing
    _ -> Nothing

tagsField :: KeyMap.KeyMap Value -> [(String, String)]
tagsField obj =
  case KeyMap.lookup "Tags" obj of
    Just (Array tags) -> concatMap tagPair (Vector.toList tags)
    _ -> []
 where
  tagPair value = case value of
    Object tagObj ->
      case (KeyMap.lookup "Key" tagObj, KeyMap.lookup "Value" tagObj) of
        (Just (String key), Just (String tagValue)) -> [(Text.unpack key, Text.unpack tagValue)]
        _ -> []
    _ -> []

retainedEbsVolumeBindingsFromDiscovered
  :: [EbsRequiredVolume] -> [EbsVolume] -> Either String [StaticEbsVolumeBinding]
retainedEbsVolumeBindingsFromDiscovered required volumes =
  mapM bindingFor required
 where
  bindingFor requiredVolume =
    let pvName = ebsRequiredPersistentVolumeName requiredVolume
        matches =
          [ volume
          | volume <- volumes
          , lookup ebsPersistentVolumeTagKey (ebsVolumeTags volume) == Just pvName
          ]
     in case matches of
          [volume] -> staticBinding requiredVolume volume
          [] -> Left ("missing retained EBS volume tagged " ++ ebsPersistentVolumeTagKey ++ "=" ++ pvName)
          _ -> Left ("multiple retained EBS volumes tagged " ++ ebsPersistentVolumeTagKey ++ "=" ++ pvName)

  staticBinding requiredVolume volume = do
    let pvName = ebsRequiredPersistentVolumeName requiredVolume
    availabilityZone <-
      case ebsVolumeAvailabilityZone volume of
        Just zone | not (null zone) -> Right zone
        _ -> Left ("retained EBS volume for " ++ pvName ++ " has no AvailabilityZone")
    if availabilityZone /= ebsRequiredAvailabilityZone requiredVolume
      then
        Left
          ( "retained EBS volume for "
              ++ pvName
              ++ " is in "
              ++ availabilityZone
              ++ " but expected "
              ++ ebsRequiredAvailabilityZone requiredVolume
          )
      else case retainedVolumeSizeProblem requiredVolume volume of
        Just problem -> Left problem
        Nothing ->
          if ebsVolumeState volume `elem` ["available", "in-use"]
            then
              Right
                StaticEbsVolumeBinding
                  { staticEbsVolumeBindingPersistentVolumeName = pvName
                  , staticEbsVolumeBindingVolumeHandle = unEbsVolumeId (ebsVolumeId volume)
                  , staticEbsVolumeBindingAvailabilityZone = availabilityZone
                  }
            else
              Left ("retained EBS volume for " ++ pvName ++ " is not attachable: state=" ++ ebsVolumeState volume)

-- | Sprint 5.53: why a listed retained volume cannot back its claim at the size
-- the plan requires, or nothing when it can. A volume found by its tag is bound
-- under a claim of the plan's size; a smaller one would be written past its end
-- by the claim that believes it larger, and one that reports no size cannot be
-- shown to be large enough. Growing it in place and replacing the retained
-- family are both decisions about data the volume holds, so neither happens
-- here: the refusal names both sizes and stops.
retainedVolumeSizeProblem :: EbsRequiredVolume -> EbsVolume -> Maybe String
retainedVolumeSizeProblem requiredVolume volume = case ebsVolumeSizeGiB volume of
  Nothing ->
    Just
      ( "retained EBS volume "
          ++ unEbsVolumeId (ebsVolumeId volume)
          ++ " for "
          ++ ebsRequiredPersistentVolumeName requiredVolume
          ++ " did not report a size, so it cannot be shown to hold the "
          ++ show (ebsRequiredSizeGiB requiredVolume)
          ++ " GiB the plan requires"
      )
  Just sizeGiB
    | sizeGiB < ebsRequiredSizeGiB requiredVolume ->
        Just
          ( "retained EBS volume "
              ++ unEbsVolumeId (ebsVolumeId volume)
              ++ " for "
              ++ ebsRequiredPersistentVolumeName requiredVolume
              ++ " is "
              ++ show sizeGiB
              ++ " GiB but the plan requires "
              ++ show (ebsRequiredSizeGiB requiredVolume)
              ++ " GiB; it is not bound under a larger claim. A retained volume holds data and cannot be"
              ++ " shrunk, and growing it in place or replacing the retained family is an operator"
              ++ " decision"
          )
    | otherwise -> Nothing

-- | Every required volume that is listed exactly once and cannot back its claim
-- at the planned size. A volume listed twice is the duplicate-tag refusal's, not
-- this one's.
retainedVolumeSizeProblems :: [EbsRequiredVolume] -> [EbsVolume] -> [String]
retainedVolumeSizeProblems required volumes =
  [ problem
  | requiredVolume <- required
  , [volume] <- [taggedFor requiredVolume]
  , Just problem <- [retainedVolumeSizeProblem requiredVolume volume]
  ]
 where
  taggedFor requiredVolume =
    [ volume
    | volume <- volumes
    , lookup ebsPersistentVolumeTagKey (ebsVolumeTags volume)
        == Just (ebsRequiredPersistentVolumeName requiredVolume)
    ]

-- | Sprint 4.84: residue is reported under the identity the observing scope
-- selected, not under one name shared by both EBS families.
ebsVolumesResidueStatus :: EbsVolumeScope -> [EbsVolume] -> ResidueStatus
ebsVolumesResidueStatus scope volumes =
  case volumes of
    [] -> ResidueAbsent
    _ ->
      ResiduePresent
        ResidueDetails
          { residueStackName = ebsManagedResourceName scope
          , residueEvidence =
              "ec2:describe-volumes matched EBS volume(s): "
                ++ intercalate ", " (map (unEbsVolumeId . ebsVolumeId) volumes)
          }

ebsDiscoverResultToResidue :: EbsVolumeScope -> Either String [EbsVolume] -> ResidueStatus
ebsDiscoverResultToResidue scope result =
  case result of
    Left err -> ResidueUnreachable (ResidueQueryFailed err)
    Right volumes -> ebsVolumesResidueStatus scope volumes

-- | Sprint 7.36: the retained family's client-side re-filter.  Unlike the
-- per-run projection it takes no cluster name: 'TagSweep.isRetainedEbsTag' is
-- the whole membership test, and adding a cluster to it would exclude exactly
-- the volume a mis-tagged retained family most needs to report.
retainedEbsVolumeIdsFromTagRows :: [TagSweep.TaggedResource] -> [EbsVolumeId]
retainedEbsVolumeIdsFromTagRows resources =
  nub
    [ volumeId
    | arn <-
        nub
          [TagSweep.taggedResourceArn resource | resource <- resources, TagSweep.isRetainedEbsTag resource]
    , Just volumeId <- [ebsVolumeIdFromArn arn]
    ]

retainedEbsReaperPlan :: [EbsVolume] -> RetainedEbsReaperPlan
retainedEbsReaperPlan volumes =
  RetainedEbsReaperPlan
    { retainedEbsReaperVolumeIds =
        retainedEbsVolumeIdsFromTagRows (concatMap ebsVolumeTagRows volumes)
    }

renderRetainedEbsReaperReport :: RetainedEbsReaperReport -> String
renderRetainedEbsReaperReport report =
  case retainedEbsReaperMatchedVolumeIds report of
    [] -> "Retained EBS reaper: clean (no retained EBS volumes matched)."
    matchedIds ->
      "Retained EBS reaper: deleted "
        ++ show (length (retainedEbsReaperDeletedVolumeIds report))
        ++ " retained EBS volume(s): "
        ++ intercalate ", " (map unEbsVolumeId matchedIds)

testScopedEbsVolumeIdsFromTagRows :: String -> [TagSweep.TaggedResource] -> [EbsVolumeId]
testScopedEbsVolumeIdsFromTagRows clusterName resources =
  nub
    [ volumeId
    | resource <- TagSweep.testScopedEbsTagRows (TagSweep.partitionEbsTagRows clusterName resources)
    , Just volumeId <- [ebsVolumeIdFromArn (TagSweep.taggedResourceArn resource)]
    ]

-- | Sprint 4.77: project a discovered volume's own tags into the tag-row shape
-- 'TagSweep.partitionEbsTagRows' decides over, so the client-side re-filter
-- reuses the already-unit-tested classifier rather than restating it.
--
-- The ARN field carries the @volume\/\<id\>@ resource form rather than a full
-- ARN, because @ec2 describe-volumes@ reports a volume id and not an ARN, and
-- the account and region are not observed here. That form is exactly what
-- 'ebsVolumeIdFromArn' projects back out — a unit case asserts the round trip
-- rather than leaving the coupling implicit.
ebsVolumeTagRows :: EbsVolume -> [TagSweep.TaggedResource]
ebsVolumeTagRows volume =
  [ TagSweep.TaggedResource
      { TagSweep.taggedResourceArn = ebsVolumeResourceCoordinate (ebsVolumeId volume)
      , TagSweep.taggedResourceMatchedTagKey = key
      , TagSweep.taggedResourceMatchedTagValue = value
      }
  | (key, value) <- ebsVolumeTags volume
  ]

ebsVolumeResourceCoordinate :: EbsVolumeId -> String
ebsVolumeResourceCoordinate volumeId = "volume/" ++ unEbsVolumeId volumeId

-- | Sprint 4.77: the reaper's plan is now a **client-side re-filter** over the
-- volumes' own tags, not @map 'ebsVolumeId'@ over whatever @describe-volumes@
-- returned.
--
-- Taking every returned volume was contained only by an accident: the argv
-- defect above meant AWS filtered on the cluster tag alone, and
-- prodbox-created retained volumes happen to be tagged without that tag. One
-- retained volume gaining a cluster tag would have made this delete production
-- EBS. The two guards are now independent — the argv narrows the query, and
-- this fold narrows the result — and neither is sufficient alone.
testScopedEbsReaperPlan :: String -> [EbsVolume] -> TestEbsReaperPlan
testScopedEbsReaperPlan clusterName volumes =
  TestEbsReaperPlan
    { testEbsReaperScope = EbsPerRunTest clusterName
    , testEbsReaperVolumeIds =
        testScopedEbsVolumeIdsFromTagRows clusterName (concatMap ebsVolumeTagRows volumes)
    }

renderTestScopedEbsReaperReport :: TestEbsReaperReport -> String
renderTestScopedEbsReaperReport report =
  case testEbsReaperMatchedVolumeIds report of
    [] -> "Test-scoped EBS reaper: clean (no test-scoped EBS volumes matched)."
    matchedIds ->
      "Test-scoped EBS reaper: deleted "
        ++ show (length (testEbsReaperDeletedVolumeIds report))
        ++ " test-scoped EBS volume(s): "
        ++ intercalate ", " (map unEbsVolumeId matchedIds)

ebsVolumeIdFromArn :: String -> Maybe EbsVolumeId
ebsVolumeIdFromArn arn =
  case break (== '/') (arnResource arn) of
    ("volume", '/' : volumeId)
      | not (null volumeId) -> Just (EbsVolumeId volumeId)
    _ -> Nothing
 where
  arnResource = reverse . takeWhile (/= ':') . reverse

-- | How the module starts the AWS CLI: the arguments in, the finished output or
-- the reason the process could not start out. Host-side callers start it
-- directly ('directAwsCliRun'); the Provider Worker passes its bounded,
-- permit-serialised runner, so its EBS interpreters are held to the same
-- physical limits as every other AWS child it starts (Sprint 5.53).
type AwsCliRun = [String] -> IO (Result ProcessOutput)

-- | Start the CLI directly, in the given environment and working directory.
directAwsCliRun :: [(String, String)] -> Maybe FilePath -> AwsCliRun
directAwsCliRun environment workingDirectory arguments =
  captureSubprocessResult
    Subprocess
      { subprocessPath = "aws"
      , subprocessArguments = arguments
      , subprocessEnvironment = Just environment
      , subprocessWorkingDirectory = workingDirectory
      }

discoverEbsVolumes :: EbsDiscoverInput -> IO (Either String [EbsVolume])
discoverEbsVolumes input =
  discoverEbsVolumesVia
    (directAwsCliRun (ebsDiscoverEnvironment input) (ebsDiscoverWorkingDirectory input))
    (ebsDiscoverScope input)

discoverEbsVolumesVia :: AwsCliRun -> EbsVolumeScope -> IO (Either String [EbsVolume])
discoverEbsVolumesVia run scope = do
  result <- run (ebsDescribeVolumesArgs scope)
  pure $ case result of
    Failure err -> Left ("failed to start `aws ec2 describe-volumes`: " ++ err)
    Success output ->
      case processExitCode output of
        ExitFailure _ ->
          Left
            ( "aws ec2 describe-volumes failed: "
                ++ processStderr output
                ++ processStdout output
            )
        ExitSuccess -> parseDescribeVolumesPayload (processStdout output)

ensureRetainedEbsVolumes
  :: EbsEnsureInput -> [EbsRequiredVolume] -> IO (Either String [StaticEbsVolumeBinding])
ensureRetainedEbsVolumes input =
  ensureRetainedEbsVolumesVia
    (directAwsCliRun (ebsEnsureEnvironment input) (ebsEnsureWorkingDirectory input))
    (wallClockWaitEnvironment providerWorkerIntentLifetimeMicros)
    (ebsEnsureVolumeType input)

ensureRetainedEbsVolumesVia
  :: AwsCliRun
  -> AwsWaitEnvironment IO
  -> AwsEbsVolumeType
  -> [EbsRequiredVolume]
  -> IO (Either String [StaticEbsVolumeBinding])
ensureRetainedEbsVolumesVia run waits volumeType =
  ensureRetainedEbsVolumesWith
    EbsEnsureEffects
      { ebsEffectDiscover = discoverEbsVolumesVia run EbsRetainedProduction
      , ebsEffectCreate = createRetainedVolumeVia run volumeType
      , ebsEffectWaitAvailable = waitForCreatedVolumesVia waits run
      , ebsEffectPause = threadDelay retainedEbsVisibilityDelayMicroseconds
      }

-- | The ensure, over its effects: list, create what is missing, wait for what
-- this call created, then read back until every required volume is listed.
--
-- EC2 describe calls are eventually consistent: a volume created moments ago may
-- not be listed yet, and an apply that failed there would leave a billable
-- volume behind its own refusal. When this call created anything, the read-back
-- waits (bounded) for every required volume to be listed on consecutive reads;
-- when it created nothing, one read is the whole answer.
--
-- The create carries the retained PV's stable client token, so a retry after
-- a lost response recovers the original volume despite lagging tag discovery.
-- Failures still name every returned volume id to support exact recovery.
ensureRetainedEbsVolumesWith
  :: (Monad m)
  => EbsEnsureEffects m
  -> [EbsRequiredVolume]
  -> m (Either String [StaticEbsVolumeBinding])
ensureRetainedEbsVolumesWith effects required = do
  firstDiscover <- ebsEffectDiscover effects
  case firstDiscover of
    Left err -> pure (Left err)
    -- A listed volume that cannot back its claim is refused before anything is
    -- created for the others, so the refusal leaves the account as it found it.
    Right existing | problem : _ <- retainedVolumeSizeProblems required existing -> pure (Left problem)
    Right existing -> do
      let missing = missingRequiredVolumes required existing
      createResult <- foldM createVolumeStep (Right []) missing
      case createResult of
        Left err -> pure (Left err)
        Right createdIds -> do
          waitResult <- waitForCreated createdIds
          case waitResult of
            Left err -> pure (Left (noteCreatedVolumes createdIds err))
            Right () -> do
              discovered <-
                awaitRequiredVolumesVisible
                  (ebsEffectDiscover effects)
                  (ebsEffectPause effects)
                  required
                  (if null missing then 1 else retainedEbsVisibilityAttempts)
                  retainedEbsVisibilityStableReads
              pure
                ( first
                    (noteCreatedVolumes createdIds)
                    (discovered >>= retainedEbsVolumeBindingsFromDiscovered required)
                )
 where
  createVolumeStep (Left err) _ = pure (Left err)
  createVolumeStep (Right createdIds) requiredVolume = do
    created <- ebsEffectCreate effects requiredVolume
    pure $ case created of
      Left err -> Left (noteCreatedVolumes createdIds err)
      Right volumeId -> Right (volumeId : createdIds)
  waitForCreated createdIds
    | null createdIds = pure (Right ())
    | otherwise = ebsEffectWaitAvailable effects createdIds

-- | Say which volumes the failing call had already created. The ids arrive
-- newest first; they are named in creation order. The fact is unconditional; the
-- advice is conditional, because the failure it is appended to can be one where
-- the listing did show the volumes (a duplicate tag, a wrong zone) and waiting
-- cannot help.
noteCreatedVolumes :: [EbsVolumeId] -> String -> String
noteCreatedVolumes createdIds detail = case createdIds of
  [] -> detail
  _ ->
    detail
      ++ "; this call had already created "
      ++ intercalate ", " (map unEbsVolumeId (reverse createdIds))
      ++ " (a tag listing can lag a create: confirm whether they exist before creating them again)"

createRetainedVolumeVia
  :: AwsCliRun -> AwsEbsVolumeType -> EbsRequiredVolume -> IO (Either String EbsVolumeId)
createRetainedVolumeVia run volumeType requiredVolume = do
  result <- run (ebsCreateVolumeArgs volumeType requiredVolume)
  pure $ case result of
    Failure err -> Left ("failed to start `aws ec2 create-volume`: " ++ err)
    Success output ->
      case processExitCode output of
        ExitFailure _ ->
          Left
            ( "aws ec2 create-volume failed for "
                ++ ebsRequiredPersistentVolumeName requiredVolume
                ++ ": "
                ++ processStderr output
                ++ processStdout output
            )
        ExitSuccess -> ebsVolumeId <$> parseCreateVolumePayload (processStdout output)

missingRequiredVolumes :: [EbsRequiredVolume] -> [EbsVolume] -> [EbsRequiredVolume]
missingRequiredVolumes required volumes =
  [ requiredVolume
  | requiredVolume <- required
  , not (hasMatchingVolume requiredVolume)
  ]
 where
  hasMatchingVolume requiredVolume =
    any
      ( \volume ->
          lookup ebsPersistentVolumeTagKey (ebsVolumeTags volume)
            == Just (ebsRequiredPersistentVolumeName requiredVolume)
      )
      volumes

-- | Re-read until every required volume is listed on enough consecutive reads, or
-- the attempts are spent.
--
-- The read is injected, with the pause between reads, so the loop is exercised
-- without an AWS account. It stops at the first read that fails (a failed read is
-- not evidence about visibility) and after the last attempt, returning what that
-- read listed so the caller names what is still missing. With one attempt there
-- is nothing to wait for and one read is the answer. With more, a single
-- complete listing is not taken for the answer: EC2 gives no monotonic-read
-- guarantee, so a listing that answers "complete" can be followed by one served
-- from a replica that has not caught up, and the Provider's own confirming read
-- would then call a successful apply unconfirmed. The lease policy's
-- stable-observation count rests on the same reasoning. A complete read that is
-- followed by an incomplete one starts the count over.
awaitRequiredVolumesVisible
  :: (Monad m)
  => m (Either String [EbsVolume])
  -> m ()
  -> [EbsRequiredVolume]
  -> Int
  -> Int
  -> m (Either String [EbsVolume])
awaitRequiredVolumesVisible discover pause required attempts stableReads = go attempts 0
 where
  go attemptsRemaining completeReads = do
    discovered <- discover
    case discovered of
      Right volumes
        | null (missingRequiredVolumes required volumes) ->
            if attempts <= 1 || completeReads + 1 >= stableReads || attemptsRemaining <= 1
              then pure discovered
              else pause >> go (attemptsRemaining - 1) (completeReads + 1)
        | attemptsRemaining > 1 -> pause >> go (attemptsRemaining - 1) 0
      _ -> pure discovered

-- | How long an apply that created volumes waits for them to be listed: twelve
-- reads, five seconds apart.
retainedEbsVisibilityAttempts :: Int
retainedEbsVisibilityAttempts = 12

-- | How many consecutive complete listings end that wait.
retainedEbsVisibilityStableReads :: Int
retainedEbsVisibilityStableReads = 2

retainedEbsVisibilityDelayMicroseconds :: Int
retainedEbsVisibilityDelayMicroseconds = 5000000

-- | Wait for the volumes this call created to be available.
--
-- Sprint 4.109: a loop of @describe-volumes@ polls under the
-- 'VolumesAvailable' budget, not an @aws ec2 wait volume-available@ child. That
-- child polls for minutes and the Provider stops every AWS child at thirty
-- seconds, so the old shape was rerun up to twelve times to make up the
-- difference and still reported only the waiter's own text. A volume created a
-- moment ago can be answered "not found" before the API has caught up; that
-- is the one refusal worth polling through. A volume that is deleted or in
-- error, a refused call, and a process that cannot start end the wait at once.
waitForCreatedVolumesVia
  :: AwsWaitEnvironment IO -> AwsCliRun -> [EbsVolumeId] -> IO (Either String ())
waitForCreatedVolumesVia _ _ [] = pure (Right ())
waitForCreatedVolumesVia waits run createdIds =
  first (Text.unpack . renderWaitFailure) <$> awaitFact waits VolumesAvailable poll
 where
  poll = do
    result <- run (ebsDescribeVolumesByIdArgs createdIds)
    pure $ case result of
      Failure err ->
        WaitAbort (Text.pack ("failed to start `aws ec2 describe-volumes`: " ++ err))
      Success output -> classify output
  classify output = case processExitCode output of
    ExitFailure _
      | volumeNotYetListed output || transientPollFailure output ->
          WaitMore () (Text.pack (describeFailure output))
      | otherwise -> WaitAbort (Text.pack (describeFailure output))
    ExitSuccess -> case parseDescribeVolumesPayload (processStdout output) of
      Left err -> WaitAbort (Text.pack err)
      Right volumes -> volumeStates volumes
  volumeStates volumes
    | any ((`elem` ["deleted", "deleting", "error"]) . ebsVolumeState) volumes =
        WaitAbort
          ( Text.pack
              ( "a created volume is "
                  ++ intercalate ", " (nub (sort (map ebsVolumeState volumes)))
              )
          )
    | length volumes == length createdIds
    , all ((== "available") . ebsVolumeState) volumes =
        WaitDone
    | otherwise =
        WaitMore
          ()
          ( Text.pack
              ( "volumes are "
                  ++ intercalate ", " (nub (sort (map ebsVolumeState volumes)))
                  ++ " of "
                  ++ show (length createdIds)
                  ++ " expected"
              )
          )
  describeFailure output =
    "aws ec2 describe-volumes failed: " ++ processStderr output ++ processStdout output

-- | Whether the API answers that it does not know a volume created a moment ago.
volumeNotYetListed :: ProcessOutput -> Bool
volumeNotYetListed output = "InvalidVolume.NotFound" `isInfixOf` processStderr output

destroyEbsVolume :: EbsDestroyInput -> EbsVolumeId -> IO (Either String ())
destroyEbsVolume input =
  destroyEbsVolumeVia
    (directAwsCliRun (ebsDestroyEnvironment input) (ebsDestroyWorkingDirectory input))

destroyEbsVolumeVia :: AwsCliRun -> EbsVolumeId -> IO (Either String ())
destroyEbsVolumeVia run volumeId = do
  result <- run (ebsDeleteVolumeArgs volumeId)
  pure $ case result of
    Failure err -> Left ("failed to start `aws ec2 delete-volume`: " ++ err)
    Success output ->
      case processExitCode output of
        ExitFailure _ ->
          Left
            ( "aws ec2 delete-volume failed for "
                ++ unEbsVolumeId volumeId
                ++ ": "
                ++ processStderr output
                ++ processStdout output
            )
        ExitSuccess -> Right ()

runTestScopedEbsReaper :: TestEbsReaperInput -> IO (Either String TestEbsReaperReport)
runTestScopedEbsReaper input =
  runTestScopedEbsReaperVia
    ( directAwsCliRun
        (testEbsReaperEnvironment input)
        (testEbsReaperWorkingDirectory input)
    )
    (testEbsReaperClusterName input)

runTestScopedEbsReaperVia
  :: AwsCliRun -> String -> IO (Either String TestEbsReaperReport)
runTestScopedEbsReaperVia run clusterName = do
  discoverResult <- discoverEbsVolumesVia run (EbsPerRunTest clusterName)
  case discoverResult of
    Left err -> pure (Left err)
    Right volumes -> do
      let plan = testScopedEbsReaperPlan clusterName volumes
      deleteResults <- mapM (destroyEbsVolumeVia run) (testEbsReaperVolumeIds plan)
      pure $
        case [err | Left err <- deleteResults] of
          [] ->
            Right
              TestEbsReaperReport
                { testEbsReaperMatchedVolumeIds = testEbsReaperVolumeIds plan
                , testEbsReaperDeletedVolumeIds = testEbsReaperVolumeIds plan
                }
          errs -> Left (intercalate "; " errs)

-- | Sprint 7.36: the retained family's destructive sweep.
--
-- Deliberately a separate function from 'runTestScopedEbsReaper' rather than a
-- scope parameter on it: the per-run reaper is called on every cascade, and a
-- scope argument would make deleting production-retained storage one wrong
-- value away at a call site that runs constantly.  This one is reachable only
-- from the registered retained target, whose surface an operator has to select
-- explicitly.
runRetainedEbsReaper
  :: RetainedEbsReaperInput -> IO (Either String RetainedEbsReaperReport)
runRetainedEbsReaper input =
  runRetainedEbsReaperVia
    ( directAwsCliRun
        (retainedEbsReaperEnvironment input)
        (retainedEbsReaperWorkingDirectory input)
    )

runRetainedEbsReaperVia :: AwsCliRun -> IO (Either String RetainedEbsReaperReport)
runRetainedEbsReaperVia run = do
  discoverResult <- discoverEbsVolumesVia run EbsRetainedProduction
  case discoverResult of
    Left err -> pure (Left err)
    Right volumes -> do
      let plan = retainedEbsReaperPlan volumes
      deleteResults <- mapM (destroyEbsVolumeVia run) (retainedEbsReaperVolumeIds plan)
      pure $
        case [err | Left err <- deleteResults] of
          [] ->
            Right
              RetainedEbsReaperReport
                { retainedEbsReaperMatchedVolumeIds = retainedEbsReaperVolumeIds plan
                , retainedEbsReaperDeletedVolumeIds = retainedEbsReaperVolumeIds plan
                }
          errs -> Left (intercalate "; " errs)
