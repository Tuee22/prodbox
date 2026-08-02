{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Exact, post-control-plane teardown for the shared long-lived S3 store.
--
-- Production coordinates come only from the same Config/identity registry that
-- creates the two dedicated adapter users.  The operations deliberately split
-- TLS objects, TLS IAM, Authority-backup objects/IAM, the read-only all-prefix
-- proof, and the terminal bucket delete into distinct capabilities.  S3
-- read-back uses @list-object-versions@, so a non-current version or delete
-- marker can never be mistaken for absence.
module Prodbox.Infra.LongLivedDecommission
  ( LongLivedDecommissionInventory
  , validateLongLivedDecommissionInventory
  , inventoryTlsIdentity
  , inventoryBackupIdentity
  , inventoryProofPrefixes
  , RegisteredIamIdentity
  , registeredIamUserName
  , registeredIamPolicyName
  , registeredIamPrefixes
  , LongLivedDecommissionBoundary (..)
  , ProductionLongLivedDecommissionCapabilities
  , productionTlsRetainedObjectsCapability
  , productionTlsRetentionIdentityCapability
  , productionBackupObjectsIdentityCapability
  , productionBackupAllPrefixesAbsentCapability
  , productionSharedObjectBucketCapability
  , longLivedDecommissionCapabilitiesWith
  , loadProductionLongLivedDecommissionCapabilities
  , VersionedPrefixInventory (..)
  , parseVersionedPrefixInventory
  , parseIamAccessKeyInventory
  , observeVersionedPrefixWith
  , destroyRegisteredIamIdentityWith
  , observeRegisteredIamIdentityWith
  , observeSharedBucketWith
  )
where

import Control.Exception (SomeException, displayException, try)
import Control.Monad (forM, unless, when)
import Data.Aeson (Value (Array, Null, Object, String), eitherDecode)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bifunctor (first)
import Data.ByteString.Lazy.Char8 qualified as LazyChar8
import Data.Foldable (traverse_)
import Data.List (intercalate, nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Prodbox.AwsEnvironment (awsCliSubprocessEnvironment)
import Prodbox.Infra.DedicatedAdapterIam
  ( DedicatedAdapterIamSpec (..)
  , authorityBackupIamPolicyName
  , authorityBackupIamUserName
  , dedicatedAdapterIamSpecs
  , tlsRetentionIamPolicyName
  , tlsRetentionIamUserName
  , validateDedicatedBucket
  , validateDedicatedPrefix
  )
import Prodbox.Infra.LongLivedPulumiBackend
  ( adminCredentialsConfigured
  , destroyLongLivedPulumiStateBucket
  , longLivedBackendErrorMessage
  , longLivedPulumiBackendUrlEither
  , purgeLongLivedObjectsUnderPrefix
  )
import Prodbox.Lifecycle.Decommission.NodeEffect
  ( BackupAllPrefixesAbsentCapability (BackupAllPrefixesAbsentCapability)
  , BackupObjectsIdentityCapability (BackupObjectsIdentityCapability)
  , NodeOperation (NodeOperation, nodeDestroy, nodeReadBack)
  , SharedObjectBucketCapability (SharedObjectBucketCapability)
  , TlsRetainedObjectsCapability (TlsRetainedObjectsCapability)
  , TlsRetentionIdentityCapability (TlsRetentionIdentityCapability)
  )
import Prodbox.Lifecycle.ResidueStatus
  ( ResidueDetails (ResidueDetails)
  , ResidueStatus (ResidueAbsent, ResiduePresent, ResidueUnreachable)
  , ResidueUnreachableReason (ResidueQueryFailed)
  , renderResidueStatus
  )
import Prodbox.Result (Result (Failure, Success))
import Prodbox.Settings
  ( ConfigFile (pulumi_state_backend)
  , Credentials
  , PulumiStateBackendSection (psbBucketName, psbKeyPrefix)
  , loadConfigFile
  )
import Prodbox.Subprocess
  ( ProcessOutput
      ( processExitCode
      , processStderr
      , processStdout
      )
  , Subprocess
    ( Subprocess
    , subprocessArguments
    , subprocessEnvironment
    , subprocessPath
    , subprocessWorkingDirectory
    )
  , captureSubprocessResult
  )
import System.Exit (ExitCode (ExitFailure, ExitSuccess))

-- | One exact IAM identity from the dedicated-adapter registry.  The
-- constructor stays private; production values are selected from
-- 'dedicatedAdapterIamSpecs' and checked against the fixed user/policy/path.
data RegisteredIamIdentity = RegisteredIamIdentity
  { registeredIamUserName :: !Text
  , registeredIamPolicyName :: !Text
  , registeredIamVaultPath :: !Text
  , registeredIamPrefixes :: ![Text]
  }
  deriving (Eq, Show)

-- | Closed coordinates for the long-lived decommission family.
data LongLivedDecommissionInventory = LongLivedDecommissionInventory
  { inventoryBackend :: !PulumiStateBackendSection
  , inventoryTlsIdentity :: !RegisteredIamIdentity
  , inventoryBackupIdentity :: !RegisteredIamIdentity
  , inventoryProofPrefixes :: ![Text]
  }
  deriving (Eq, Show)

-- | Effect boundary used by the typed capability composition.  Tests inject
-- this record; production builds it from the repository AWS CLI and S3 helpers.
data LongLivedDecommissionBoundary m = LongLivedDecommissionBoundary
  { boundaryPurgePrefix :: Text -> m (Either Text ())
  , boundaryObservePrefix :: Text -> m ResidueStatus
  , boundaryDestroyIdentity :: RegisteredIamIdentity -> m (Either Text ())
  , boundaryObserveIdentity :: RegisteredIamIdentity -> m ResidueStatus
  , boundaryDestroySharedBucket :: m (Either Text ())
  , boundaryObserveSharedBucket :: m ResidueStatus
  }

-- | The five production capability wrappers this family can honestly supply.
-- The constructor is private, preventing field substitution at a caller.
data ProductionLongLivedDecommissionCapabilities m
  = ProductionLongLivedDecommissionCapabilities
      !(TlsRetainedObjectsCapability m)
      !(TlsRetentionIdentityCapability m)
      !(BackupObjectsIdentityCapability m)
      !(BackupAllPrefixesAbsentCapability m)
      !(SharedObjectBucketCapability m)

productionTlsRetainedObjectsCapability
  :: ProductionLongLivedDecommissionCapabilities m
  -> TlsRetainedObjectsCapability m
productionTlsRetainedObjectsCapability
  (ProductionLongLivedDecommissionCapabilities capability _ _ _ _) = capability

productionTlsRetentionIdentityCapability
  :: ProductionLongLivedDecommissionCapabilities m
  -> TlsRetentionIdentityCapability m
productionTlsRetentionIdentityCapability
  (ProductionLongLivedDecommissionCapabilities _ capability _ _ _) = capability

productionBackupObjectsIdentityCapability
  :: ProductionLongLivedDecommissionCapabilities m
  -> BackupObjectsIdentityCapability m
productionBackupObjectsIdentityCapability
  (ProductionLongLivedDecommissionCapabilities _ _ capability _ _) = capability

productionBackupAllPrefixesAbsentCapability
  :: ProductionLongLivedDecommissionCapabilities m
  -> BackupAllPrefixesAbsentCapability m
productionBackupAllPrefixesAbsentCapability
  (ProductionLongLivedDecommissionCapabilities _ _ _ capability _) = capability

productionSharedObjectBucketCapability
  :: ProductionLongLivedDecommissionCapabilities m
  -> SharedObjectBucketCapability m
productionSharedObjectBucketCapability
  (ProductionLongLivedDecommissionCapabilities _ _ _ _ capability) = capability

-- | Validate a candidate registry snapshot.  Production calls this only with
-- the live Config plus 'dedicatedAdapterIamSpecs'.  Keeping validation pure
-- lets fixtures pin that duplicate, widened, missing, or swapped ownership is
-- rejected before any AWS command can run.
validateLongLivedDecommissionInventory
  :: PulumiStateBackendSection
  -> [DedicatedAdapterIamSpec]
  -> Either Text LongLivedDecommissionInventory
validateLongLivedDecommissionInventory backend specs = do
  _ <- first (Text.pack . longLivedBackendErrorMessage) (longLivedPulumiBackendUrlEither backend)
  unless (length specs == 2) $
    Left "long-lived decommission requires exactly two dedicated IAM registry entries"
  tlsSpec <- selectExactSpec tlsRetentionIamUserName specs
  backupSpec <- selectExactSpec authorityBackupIamUserName specs
  tlsIdentity <-
    validateIdentity
      (Text.strip (psbBucketName backend))
      tlsRetentionIamUserName
      tlsRetentionIamPolicyName
      "aws/tls-retention-store"
      "public-edge-tls/"
      tlsSpec
  backupIdentity <-
    validateIdentity
      (Text.strip (psbBucketName backend))
      authorityBackupIamUserName
      authorityBackupIamPolicyName
      "aws/authority-backup-store"
      "authority-backup-store/"
      backupSpec
  let destructivePrefixes = registeredIamPrefixes tlsIdentity ++ registeredIamPrefixes backupIdentity
  unless (destructivePrefixes == nub destructivePrefixes) $
    Left "long-lived decommission registry contains duplicate destructive prefixes"
  unless (prefixesPairwiseDisjoint destructivePrefixes) $
    Left "long-lived decommission destructive prefixes overlap"
  let backendPrefix = Text.strip (psbKeyPrefix backend)
      proofPrefixes = nub (destructivePrefixes ++ [backendPrefix])
  unless (Text.null backendPrefix || prefixesPairwiseDisjoint (backendPrefix : destructivePrefixes)) $
    Left "long-lived Pulumi backend prefix overlaps a destructive adapter prefix"
  pure
    LongLivedDecommissionInventory
      { inventoryBackend = backend
      , inventoryTlsIdentity = tlsIdentity
      , inventoryBackupIdentity = backupIdentity
      , inventoryProofPrefixes = proofPrefixes
      }

selectExactSpec :: Text -> [DedicatedAdapterIamSpec] -> Either Text DedicatedAdapterIamSpec
selectExactSpec expectedUser specs =
  case filter ((== expectedUser) . Text.strip . dedicatedIamUserName) specs of
    [spec] -> Right spec
    [] -> Left ("missing dedicated IAM registry entry for " <> expectedUser)
    _ -> Left ("duplicate dedicated IAM registry entries for " <> expectedUser)

validateIdentity
  :: Text
  -> Text
  -> Text
  -> Text
  -> Text
  -> DedicatedAdapterIamSpec
  -> Either Text RegisteredIamIdentity
validateIdentity bucket expectedUser expectedPolicy expectedVaultPath expectedPrefix spec = do
  let user = Text.strip (dedicatedIamUserName spec)
      policy = Text.strip (dedicatedIamPolicyName spec)
      vaultPath = Text.strip (dedicatedIamVaultPath spec)
      prefixes = fmap Text.strip (dedicatedIamPrefixes spec)
  unless (user == expectedUser) $ Left ("dedicated IAM user mismatch for " <> expectedUser)
  unless (policy == expectedPolicy) $
    Left ("dedicated IAM inline policy mismatch for " <> expectedUser)
  unless (vaultPath == expectedVaultPath) $
    Left ("dedicated IAM Vault path mismatch for " <> expectedUser)
  unless (not (null prefixes) && prefixes == nub prefixes) $
    Left ("dedicated IAM prefix inventory is empty or duplicated for " <> expectedUser)
  unless (all (expectedPrefix `Text.isPrefixOf`) prefixes) $
    Left ("dedicated IAM prefix family mismatch for " <> expectedUser)
  _ <- first Text.pack (validateDedicatedBucket bucket)
  traverse_ (first Text.pack . validateDedicatedPrefix) prefixes
  pure
    RegisteredIamIdentity
      { registeredIamUserName = user
      , registeredIamPolicyName = policy
      , registeredIamVaultPath = vaultPath
      , registeredIamPrefixes = prefixes
      }

prefixesPairwiseDisjoint :: [Text] -> Bool
prefixesPairwiseDisjoint prefixes =
  and
    [ not (left `Text.isPrefixOf` right || right `Text.isPrefixOf` left)
    | (leftIndex, left) <- zip [(0 :: Int) ..] prefixes
    , (rightIndex, right) <- zip [(0 :: Int) ..] prefixes
    , leftIndex < rightIndex
    ]

-- | Lower the exact inventory into five non-interchangeable node capabilities.
-- Every composite destroy attempts all independent registered coordinates and
-- aggregates their failures; every read-back observes all coordinates and
-- treats any unobservable fact as unreachable.
longLivedDecommissionCapabilitiesWith
  :: (Monad m)
  => LongLivedDecommissionInventory
  -> LongLivedDecommissionBoundary m
  -> ProductionLongLivedDecommissionCapabilities m
longLivedDecommissionCapabilitiesWith inventory boundary =
  ProductionLongLivedDecommissionCapabilities
    (TlsRetainedObjectsCapability tlsObjectsOperation)
    (TlsRetentionIdentityCapability tlsIdentityOperation)
    (BackupObjectsIdentityCapability backupOperation)
    (BackupAllPrefixesAbsentCapability observeEveryRegisteredPrefix)
    (SharedObjectBucketCapability sharedBucketOperation)
 where
  tlsIdentity = inventoryTlsIdentity inventory
  backupIdentity = inventoryBackupIdentity inventory
  tlsPrefixes = registeredIamPrefixes tlsIdentity
  backupPrefixes = registeredIamPrefixes backupIdentity

  tlsObjectsOperation =
    NodeOperation
      { nodeDestroy = \_ _ -> destroyPrefixes "TLS retained objects" tlsPrefixes
      , nodeReadBack = \_ _ -> observePrefixes "TLS retained objects" tlsPrefixes
      }
  tlsIdentityOperation =
    NodeOperation
      { nodeDestroy = \_ _ -> boundaryDestroyIdentity boundary tlsIdentity
      , nodeReadBack = \_ _ -> boundaryObserveIdentity boundary tlsIdentity
      }
  backupOperation =
    NodeOperation
      { nodeDestroy = \_ _ -> do
          prefixResult <- destroyPrefixes "Authority backup objects" backupPrefixes
          identityResult <- boundaryDestroyIdentity boundary backupIdentity
          pure (aggregateDestroyResults "Authority backup objects/identity" [prefixResult, identityResult])
      , nodeReadBack = \_ _ -> do
          prefixStatuses <- observePrefixStatuses backupPrefixes
          identityStatus <- boundaryObserveIdentity boundary backupIdentity
          pure
            ( aggregateResidueStatuses
                "Authority backup objects/identity"
                (prefixStatuses ++ [("iam:" <> registeredIamUserName backupIdentity, identityStatus)])
            )
      }
  sharedBucketOperation =
    NodeOperation
      { nodeDestroy = \_ _ -> boundaryDestroySharedBucket boundary
      , nodeReadBack = \_ _ -> boundaryObserveSharedBucket boundary
      }

  destroyPrefixes label prefixes = do
    results <- mapM (boundaryPurgePrefix boundary) prefixes
    pure (aggregateDestroyResults label results)
  observePrefixes label prefixes =
    aggregateResidueStatuses label <$> observePrefixStatuses prefixes
  observePrefixStatuses prefixes =
    forM prefixes $ \prefix -> do
      status <- boundaryObservePrefix boundary prefix
      pure ("s3:" <> prefix, status)
  observeEveryRegisteredPrefix _ _ =
    observePrefixes "all registered long-lived prefixes" (inventoryProofPrefixes inventory)

aggregateDestroyResults :: Text -> [Either Text ()] -> Either Text ()
aggregateDestroyResults label results =
  case [detail | Left detail <- results] of
    [] -> Right ()
    failures -> Left (label <> " destroy failures: " <> Text.intercalate "; " failures)

aggregateResidueStatuses :: Text -> [(Text, ResidueStatus)] -> ResidueStatus
aggregateResidueStatuses label observations =
  case unreachableStatuses of
    (_ : _) -> ResidueUnreachable (ResidueQueryFailed (rendered "unreachable" unreachableStatuses))
    [] -> case present of
      (_ : _) -> ResiduePresent (ResidueDetails (rendered "present" present) (Text.unpack label))
      [] -> ResidueAbsent
 where
  unreachableStatuses = [(coordinate, status) | (coordinate, status@ResidueUnreachable {}) <- observations]
  present = [(coordinate, status) | (coordinate, status@ResiduePresent {}) <- observations]
  rendered classification statuses =
    Text.unpack label
      ++ " "
      ++ classification
      ++ ": "
      ++ intercalate
        "; "
        [Text.unpack coordinate ++ "=" ++ renderResidueStatus status | (coordinate, status) <- statuses]

-- | Resolve canonical production coordinates and bind the repository-owned AWS
-- operations.  The ephemeral credential is supplied by the nuke prompt and is
-- projected through the single sealed AWS CLI environment builder.
loadProductionLongLivedDecommissionCapabilities
  :: FilePath
  -> Credentials
  -> IO (Either Text (ProductionLongLivedDecommissionCapabilities IO))
loadProductionLongLivedDecommissionCapabilities repoRoot credentials
  | not (adminCredentialsConfigured credentials) =
      pure (Left "long-lived decommission requires a complete ephemeral admin AWS credential")
  | otherwise = do
      configResult <- loadConfigFile repoRoot
      case configResult of
        Left detail -> pure (Left ("cannot load production decommission Config: " <> Text.pack detail))
        Right config -> do
          specsResult <- try (dedicatedAdapterIamSpecs repoRoot config)
          case specsResult of
            Left err ->
              pure
                ( Left
                    ( "cannot resolve the dedicated adapter decommission registry: "
                        <> Text.pack (displayException (err :: SomeException))
                    )
                )
            Right specs -> case validateLongLivedDecommissionInventory (pulumi_state_backend config) specs of
              Left detail -> pure (Left detail)
              Right inventory -> do
                environment <- awsCliSubprocessEnvironment credentials
                let backend = inventoryBackend inventory
                    runner = captureSubprocessResult
                    boundary =
                      LongLivedDecommissionBoundary
                        { boundaryPurgePrefix = \prefix ->
                            first Text.pack
                              <$> purgeLongLivedObjectsUnderPrefix
                                repoRoot
                                environment
                                backend
                                (Text.unpack prefix)
                        , boundaryObservePrefix =
                            observeVersionedPrefixWith runner repoRoot environment (Text.strip (psbBucketName backend))
                        , boundaryDestroyIdentity =
                            destroyRegisteredIamIdentityWith runner repoRoot environment
                        , boundaryObserveIdentity =
                            observeRegisteredIamIdentityWith runner repoRoot environment
                        , boundaryDestroySharedBucket =
                            first (Text.pack . longLivedBackendErrorMessage)
                              <$> destroyLongLivedPulumiStateBucket repoRoot environment backend
                        , boundaryObserveSharedBucket =
                            observeSharedBucketWith runner repoRoot environment (Text.strip (psbBucketName backend))
                        }
                pure (Right (longLivedDecommissionCapabilitiesWith inventory boundary))

-- | Bounded evidence from one @list-object-versions --max-items 1@ response.
data VersionedPrefixInventory = VersionedPrefixInventory
  { versionedObjectCount :: !Int
  , deleteMarkerCount :: !Int
  }
  deriving (Eq, Show)

parseVersionedPrefixInventory :: String -> Either String VersionedPrefixInventory
parseVersionedPrefixInventory payload = do
  value <-
    first ("failed to decode list-object-versions payload: " ++) (eitherDecode (LazyChar8.pack payload))
  objectValue <- case value of
    Object fields -> Right fields
    _ -> Left "list-object-versions payload must be a JSON object"
  versions <- arrayCount "Versions" objectValue
  deleteMarkers <- arrayCount "DeleteMarkers" objectValue
  pure
    VersionedPrefixInventory
      { versionedObjectCount = versions
      , deleteMarkerCount = deleteMarkers
      }
 where
  arrayCount field fields = case KeyMap.lookup (Key.fromString field) fields of
    Nothing -> Right 0
    Just Null -> Right 0
    Just (Array values) -> Right (Vector.length values)
    Just _ -> Left ("list-object-versions field " ++ field ++ " must be an array or null")

-- | Observe all current/non-current versions and delete markers under one
-- exact prefix.  A missing bucket is absence; access/transport/decode failures
-- are unreachable.
observeVersionedPrefixWith
  :: (Monad m)
  => (Subprocess -> m (Result ProcessOutput))
  -> FilePath
  -> [(String, String)]
  -> Text
  -> Text
  -> m ResidueStatus
observeVersionedPrefixWith runProcess workingDirectory environment bucket prefix = do
  result <-
    runProcess
      ( awsCommand
          workingDirectory
          environment
          [ "s3api"
          , "list-object-versions"
          , "--bucket"
          , Text.unpack bucket
          , "--prefix"
          , Text.unpack prefix
          , "--max-items"
          , "1"
          , "--output"
          , "json"
          ]
      )
  pure $ case result of
    Failure detail -> unreachable "list-object-versions failed to start" detail
    Success output -> case processExitCode output of
      ExitFailure _
        | isExactNoSuchBucketFailure output -> ResidueAbsent
        | otherwise -> unreachable "list-object-versions failed" (commandFailureDetail output)
      ExitSuccess -> case parseVersionedPrefixInventory (processStdout output) of
        Left detail -> unreachable "list-object-versions decode failed" detail
        Right inventory
          | versionedObjectCount inventory == 0 && deleteMarkerCount inventory == 0 -> ResidueAbsent
          | otherwise ->
              ResiduePresent
                ( ResidueDetails
                    ( "prefix "
                        ++ Text.unpack prefix
                        ++ " has "
                        ++ show (versionedObjectCount inventory)
                        ++ " version(s) and "
                        ++ show (deleteMarkerCount inventory)
                        ++ " delete marker(s) in the bounded read-back"
                    )
                    "long-lived-s3-prefix"
                )

parseIamAccessKeyInventory :: String -> Either String [Text]
parseIamAccessKeyInventory payload = do
  value <-
    first ("failed to decode IAM access-key inventory: " ++) (eitherDecode (LazyChar8.pack payload))
  fields <- case value of
    Object objectValue -> Right objectValue
    _ -> Left "IAM access-key inventory must be a JSON object"
  entries <- case KeyMap.lookup (Key.fromString "AccessKeyMetadata") fields of
    Just (Array values) -> Right (Vector.toList values)
    _ -> Left "IAM access-key inventory requires an AccessKeyMetadata array"
  keys <- traverse decodeKey entries
  when (length keys > 2) (Left "IAM access-key inventory exceeds the AWS two-key bound")
  unless (keys == nub keys) (Left "IAM access-key inventory contains duplicate access-key IDs")
  pure keys
 where
  decodeKey value = case value of
    Object fields -> case KeyMap.lookup (Key.fromString "AccessKeyId") fields of
      Just (String keyId)
        | not (Text.null (Text.strip keyId)) -> Right (Text.strip keyId)
      _ -> Left "IAM access-key inventory entry requires a non-empty AccessKeyId"
    _ -> Left "IAM access-key inventory entry must be a JSON object"

-- | Delete every key, then the one fixed inline policy and exact user.
destroyRegisteredIamIdentityWith
  :: (Monad m)
  => (Subprocess -> m (Result ProcessOutput))
  -> FilePath
  -> [(String, String)]
  -> RegisteredIamIdentity
  -> m (Either Text ())
destroyRegisteredIamIdentityWith runProcess workingDirectory environment identity = do
  inventoryResult <-
    runProcess
      ( awsCommand
          workingDirectory
          environment
          [ "iam"
          , "list-access-keys"
          , "--user-name"
          , Text.unpack (registeredIamUserName identity)
          , "--output"
          , "json"
          ]
      )
  case classifyIamInventory inventoryResult of
    Left detail -> pure (Left detail)
    Right Nothing -> pure (Right ())
    Right (Just keyIds) -> do
      keyResults <-
        forM keyIds $ \keyId ->
          classifyIdempotentIamDelete
            <$> runProcess
              ( awsCommand
                  workingDirectory
                  environment
                  [ "iam"
                  , "delete-access-key"
                  , "--user-name"
                  , Text.unpack (registeredIamUserName identity)
                  , "--access-key-id"
                  , Text.unpack keyId
                  ]
              )
      policyResult <-
        classifyIdempotentIamDelete
          <$> runProcess
            ( awsCommand
                workingDirectory
                environment
                [ "iam"
                , "delete-user-policy"
                , "--user-name"
                , Text.unpack (registeredIamUserName identity)
                , "--policy-name"
                , Text.unpack (registeredIamPolicyName identity)
                ]
            )
      userResult <-
        classifyIdempotentIamDelete
          <$> runProcess
            ( awsCommand
                workingDirectory
                environment
                [ "iam"
                , "delete-user"
                , "--user-name"
                , Text.unpack (registeredIamUserName identity)
                ]
            )
      pure
        ( aggregateDestroyResults
            ("IAM identity " <> registeredIamUserName identity)
            (keyResults ++ [policyResult, userResult])
        )

classifyIamInventory :: Result ProcessOutput -> Either Text (Maybe [Text])
classifyIamInventory result = case result of
  Failure detail -> Left ("IAM list-access-keys failed to start: " <> Text.pack detail)
  Success output -> case processExitCode output of
    ExitSuccess -> Just <$> first Text.pack (parseIamAccessKeyInventory (processStdout output))
    ExitFailure _
      | isExactNoSuchEntityFailure output -> Right Nothing
      | otherwise -> Left ("IAM list-access-keys failed: " <> Text.pack (commandFailureDetail output))

classifyIdempotentIamDelete :: Result ProcessOutput -> Either Text ()
classifyIdempotentIamDelete result = case result of
  Failure detail -> Left ("IAM delete failed to start: " <> Text.pack detail)
  Success output -> case processExitCode output of
    ExitSuccess -> Right ()
    ExitFailure _
      | isExactNoSuchEntityFailure output -> Right ()
      | otherwise -> Left ("IAM delete failed: " <> Text.pack (commandFailureDetail output))

observeRegisteredIamIdentityWith
  :: (Monad m)
  => (Subprocess -> m (Result ProcessOutput))
  -> FilePath
  -> [(String, String)]
  -> RegisteredIamIdentity
  -> m ResidueStatus
observeRegisteredIamIdentityWith runProcess workingDirectory environment identity = do
  result <-
    runProcess
      ( awsCommand
          workingDirectory
          environment
          [ "iam"
          , "get-user"
          , "--user-name"
          , Text.unpack (registeredIamUserName identity)
          , "--output"
          , "json"
          ]
      )
  pure $ case result of
    Failure detail -> unreachable "iam get-user failed to start" detail
    Success output -> case processExitCode output of
      ExitSuccess ->
        ResiduePresent
          ( ResidueDetails
              ("AWS IAM get-user confirmed " ++ Text.unpack (registeredIamUserName identity))
              (Text.unpack (registeredIamUserName identity))
          )
      ExitFailure _
        | isExactNoSuchEntityFailure output -> ResidueAbsent
        | otherwise -> unreachable "iam get-user failed" (commandFailureDetail output)

-- | Authoritative terminal bucket read-back.  Only the exact HeadBucket 404
-- shape is absence; 403 and every other failure remain unreachable.
observeSharedBucketWith
  :: (Monad m)
  => (Subprocess -> m (Result ProcessOutput))
  -> FilePath
  -> [(String, String)]
  -> Text
  -> m ResidueStatus
observeSharedBucketWith runProcess workingDirectory environment bucket = do
  result <-
    runProcess
      ( awsCommand
          workingDirectory
          environment
          ["s3api", "head-bucket", "--bucket", Text.unpack bucket]
      )
  pure $ case result of
    Failure detail -> unreachable "head-bucket failed to start" detail
    Success output -> case processExitCode output of
      ExitSuccess ->
        ResiduePresent
          (ResidueDetails ("AWS S3 HeadBucket confirmed " ++ Text.unpack bucket) "long-lived-s3-bucket")
      ExitFailure _
        | isExactHeadBucketNotFound output -> ResidueAbsent
        | otherwise -> unreachable "head-bucket failed" (commandFailureDetail output)

isExactNoSuchEntityFailure :: ProcessOutput -> Bool
isExactNoSuchEntityFailure output =
  "(nosuchentity)" `Text.isInfixOf` normalizedFailure output

isExactNoSuchBucketFailure :: ProcessOutput -> Bool
isExactNoSuchBucketFailure output =
  "(nosuchbucket)" `Text.isInfixOf` normalizedFailure output

isExactHeadBucketNotFound :: ProcessOutput -> Bool
isExactHeadBucketNotFound output =
  "headbucket" `Text.isInfixOf` detail
    && ("(404)" `Text.isInfixOf` detail || "status code: 404" `Text.isInfixOf` detail)
 where
  detail = normalizedFailure output

normalizedFailure :: ProcessOutput -> Text
normalizedFailure output =
  Text.toLower (Text.pack (processStderr output ++ processStdout output))

commandFailureDetail :: ProcessOutput -> String
commandFailureDetail output =
  "exit "
    ++ exitCodeText (processExitCode output)
    ++ ": "
    ++ processStderr output
    ++ processStdout output

exitCodeText :: ExitCode -> String
exitCodeText code = case code of
  ExitSuccess -> "0"
  ExitFailure value -> show value

unreachable :: String -> String -> ResidueStatus
unreachable operation detail =
  ResidueUnreachable (ResidueQueryFailed (operation ++ ": " ++ detail))

awsCommand :: FilePath -> [(String, String)] -> [String] -> Subprocess
awsCommand workingDirectory environment arguments =
  Subprocess
    { subprocessPath = "aws"
    , subprocessArguments = arguments
    , subprocessEnvironment = Just environment
    , subprocessWorkingDirectory = Just workingDirectory
    }
