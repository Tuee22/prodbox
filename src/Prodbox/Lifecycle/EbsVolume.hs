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
  , EbsDestroyInput (..)
  , TestEbsReaperInput (..)
  , TestEbsReaperPlan (..)
  , TestEbsReaperReport (..)
  , ebsManagedResourceName
  , ebsPersistentVolumeTagKey
  , ebsDescribeVolumesArgs
  , ebsCreateVolumeArgs
  , ebsWaitVolumeAvailableArgs
  , ebsDeleteVolumeArgs
  , ebsRequiredVolumeFromChartStorageBinding
  , parseStorageSizeGiB
  , parseDescribeVolumesPayload
  , parseCreateVolumePayload
  , retainedEbsVolumeBindingsFromDiscovered
  , ebsVolumesResidueStatus
  , ebsDiscoverResultToResidue
  , testScopedEbsVolumeIdsFromTagRows
  , testScopedEbsReaperPlan
  , renderTestScopedEbsReaperReport
  , discoverEbsVolumes
  , ensureRetainedEbsVolumes
  , destroyEbsVolume
  , runTestScopedEbsReaper
  )
where

import Control.Monad (foldM)
import Data.Aeson
  ( Value (..)
  , eitherDecode
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (isDigit)
import Data.List (intercalate, nub)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Prodbox.Lib.Storage
  ( ChartStorageBinding (..)
  , StaticEbsVolumeBinding (..)
  )
import Prodbox.Lifecycle.ResidueStatus
  ( ResidueDetails (..)
  , ResidueStatus (..)
  , ResidueUnreachableReason (..)
  )
import Prodbox.Lifecycle.TagSweep qualified as TagSweep
import Prodbox.Result (Result (..))
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  )
import System.Exit (ExitCode (..))

newtype EbsVolumeId = EbsVolumeId {unEbsVolumeId :: String}
  deriving (Eq, Show)

data EbsVolume = EbsVolume
  { ebsVolumeId :: EbsVolumeId
  , ebsVolumeState :: String
  , ebsVolumeAvailabilityZone :: Maybe String
  , ebsVolumeTags :: [(String, String)]
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
  }
  deriving (Eq, Show)

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

ebsManagedResourceName :: String
ebsManagedResourceName = "aws-ebs-volumes"

ebsPersistentVolumeTagKey :: String
ebsPersistentVolumeTagKey = "prodbox.io/persistent-volume"

ebsDescribeVolumesArgs :: EbsVolumeScope -> [String]
ebsDescribeVolumesArgs scope =
  [ "ec2"
  , "describe-volumes"
  , "--output"
  , "json"
  , "--filters"
  , tagFilter TagSweep.prodboxManagedByTagKey TagSweep.prodboxManagedByTagValue
  , tagFilter TagSweep.ebsLifecycleTagKey lifecycleValue
  ]
    ++ clusterFilter
 where
  (lifecycleValue, clusterFilter) = case scope of
    EbsRetainedProduction -> (TagSweep.ebsRetainedLifecycleValue, [])
    EbsPerRunTest clusterName ->
      ( TagSweep.ebsTestScopedLifecycleValue
      ,
        [ "--filters"
        , tagFilter (TagSweep.ebsClusterOwnedTagKey clusterName) "owned"
        ]
      )

ebsDeleteVolumeArgs :: EbsVolumeId -> [String]
ebsDeleteVolumeArgs volumeId =
  [ "ec2"
  , "delete-volume"
  , "--volume-id"
  , unEbsVolumeId volumeId
  ]

ebsCreateVolumeArgs :: EbsRequiredVolume -> [String]
ebsCreateVolumeArgs required =
  [ "ec2"
  , "create-volume"
  , "--availability-zone"
  , ebsRequiredAvailabilityZone required
  , "--size"
  , show (ebsRequiredSizeGiB required)
  , "--volume-type"
  , "gp3"
  , "--tag-specifications"
  , retainedVolumeTagSpecification required
  , "--output"
  , "json"
  ]

ebsWaitVolumeAvailableArgs :: [EbsVolumeId] -> [String]
ebsWaitVolumeAvailableArgs volumeIds =
  ["ec2", "wait", "volume-available", "--volume-ids"] ++ map unEbsVolumeId volumeIds

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
      else
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

ebsVolumesResidueStatus :: [EbsVolume] -> ResidueStatus
ebsVolumesResidueStatus volumes =
  case volumes of
    [] -> ResidueAbsent
    _ ->
      ResiduePresent
        ResidueDetails
          { residueStackName = ebsManagedResourceName
          , residueEvidence =
              "ec2:describe-volumes matched EBS volume(s): "
                ++ intercalate ", " (map (unEbsVolumeId . ebsVolumeId) volumes)
          }

ebsDiscoverResultToResidue :: Either String [EbsVolume] -> ResidueStatus
ebsDiscoverResultToResidue result =
  case result of
    Left err -> ResidueUnreachable (ResidueQueryFailed err)
    Right volumes -> ebsVolumesResidueStatus volumes

testScopedEbsVolumeIdsFromTagRows :: String -> [TagSweep.TaggedResource] -> [EbsVolumeId]
testScopedEbsVolumeIdsFromTagRows clusterName resources =
  nub
    [ volumeId
    | resource <- TagSweep.testScopedEbsTagRows (TagSweep.partitionEbsTagRows clusterName resources)
    , Just volumeId <- [ebsVolumeIdFromArn (TagSweep.taggedResourceArn resource)]
    ]

testScopedEbsReaperPlan :: String -> [EbsVolume] -> TestEbsReaperPlan
testScopedEbsReaperPlan clusterName volumes =
  TestEbsReaperPlan
    { testEbsReaperScope = EbsPerRunTest clusterName
    , testEbsReaperVolumeIds = map ebsVolumeId volumes
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

discoverEbsVolumes :: EbsDiscoverInput -> IO (Either String [EbsVolume])
discoverEbsVolumes input = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "aws"
        , subprocessArguments = ebsDescribeVolumesArgs (ebsDiscoverScope input)
        , subprocessEnvironment = Just (ebsDiscoverEnvironment input)
        , subprocessWorkingDirectory = ebsDiscoverWorkingDirectory input
        }
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
ensureRetainedEbsVolumes input required = do
  firstDiscover <-
    discoverEbsVolumes
      EbsDiscoverInput
        { ebsDiscoverEnvironment = ebsEnsureEnvironment input
        , ebsDiscoverWorkingDirectory = ebsEnsureWorkingDirectory input
        , ebsDiscoverScope = EbsRetainedProduction
        }
  case firstDiscover of
    Left err -> pure (Left err)
    Right existing -> do
      let missing = missingRequiredVolumes required existing
      createResult <- foldM createVolumeStep (Right []) missing
      case createResult of
        Left err -> pure (Left err)
        Right createdIds -> do
          waitResult <- waitForCreatedVolumes input createdIds
          case waitResult of
            Left err -> pure (Left err)
            Right () -> do
              secondDiscover <-
                discoverEbsVolumes
                  EbsDiscoverInput
                    { ebsDiscoverEnvironment = ebsEnsureEnvironment input
                    , ebsDiscoverWorkingDirectory = ebsEnsureWorkingDirectory input
                    , ebsDiscoverScope = EbsRetainedProduction
                    }
              pure (secondDiscover >>= retainedEbsVolumeBindingsFromDiscovered required)
 where
  createVolumeStep (Left err) _ = pure (Left err)
  createVolumeStep (Right createdIds) requiredVolume = do
    result <-
      captureSubprocessResult
        Subprocess
          { subprocessPath = "aws"
          , subprocessArguments = ebsCreateVolumeArgs requiredVolume
          , subprocessEnvironment = Just (ebsEnsureEnvironment input)
          , subprocessWorkingDirectory = ebsEnsureWorkingDirectory input
          }
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
          ExitSuccess ->
            (: createdIds) . ebsVolumeId <$> parseCreateVolumePayload (processStdout output)

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

waitForCreatedVolumes :: EbsEnsureInput -> [EbsVolumeId] -> IO (Either String ())
waitForCreatedVolumes _ [] = pure (Right ())
waitForCreatedVolumes input createdIds = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "aws"
        , subprocessArguments = ebsWaitVolumeAvailableArgs createdIds
        , subprocessEnvironment = Just (ebsEnsureEnvironment input)
        , subprocessWorkingDirectory = ebsEnsureWorkingDirectory input
        }
  pure $ case result of
    Failure err -> Left ("failed to start `aws ec2 wait volume-available`: " ++ err)
    Success output ->
      case processExitCode output of
        ExitFailure _ ->
          Left
            ( "aws ec2 wait volume-available failed: "
                ++ processStderr output
                ++ processStdout output
            )
        ExitSuccess -> Right ()

destroyEbsVolume :: EbsDestroyInput -> EbsVolumeId -> IO (Either String ())
destroyEbsVolume input volumeId = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "aws"
        , subprocessArguments = ebsDeleteVolumeArgs volumeId
        , subprocessEnvironment = Just (ebsDestroyEnvironment input)
        , subprocessWorkingDirectory = ebsDestroyWorkingDirectory input
        }
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
runTestScopedEbsReaper input = do
  discoverResult <-
    discoverEbsVolumes
      EbsDiscoverInput
        { ebsDiscoverEnvironment = testEbsReaperEnvironment input
        , ebsDiscoverWorkingDirectory = testEbsReaperWorkingDirectory input
        , ebsDiscoverScope = EbsPerRunTest (testEbsReaperClusterName input)
        }
  case discoverResult of
    Left err -> pure (Left err)
    Right volumes -> do
      let plan = testScopedEbsReaperPlan (testEbsReaperClusterName input) volumes
          destroyInput =
            EbsDestroyInput
              { ebsDestroyEnvironment = testEbsReaperEnvironment input
              , ebsDestroyWorkingDirectory = testEbsReaperWorkingDirectory input
              }
      deleteResults <- mapM (destroyEbsVolume destroyInput) (testEbsReaperVolumeIds plan)
      pure $
        case [err | Left err <- deleteResults] of
          [] ->
            Right
              TestEbsReaperReport
                { testEbsReaperMatchedVolumeIds = testEbsReaperVolumeIds plan
                , testEbsReaperDeletedVolumeIds = testEbsReaperVolumeIds plan
                }
          errs -> Left (intercalate "; " errs)
