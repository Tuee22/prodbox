{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module LongLivedDecommission
  ( longLivedDecommissionSuite
  )
where

import Data.Either (isLeft)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.Maybe (fromJust)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Infra.DedicatedAdapterIam
  ( DedicatedAdapterIamSpec (..)
  , authorityBackupIamPolicyName
  , authorityBackupIamUserName
  , tlsRetentionIamPolicyName
  , tlsRetentionIamUserName
  )
import Prodbox.Infra.LongLivedDecommission
  ( LongLivedDecommissionBoundary (..)
  , LongLivedDecommissionInventory
  , VersionedPrefixInventory (VersionedPrefixInventory)
  , destroyRegisteredIamIdentityWith
  , inventoryBackupIdentity
  , longLivedDecommissionCapabilitiesWith
  , observeSharedBucketWith
  , observeVersionedPrefixWith
  , parseIamAccessKeyInventory
  , parseVersionedPrefixInventory
  , productionBackupAllPrefixesAbsentCapability
  , productionBackupObjectsIdentityCapability
  , productionSharedObjectBucketCapability
  , productionTlsRetainedObjectsCapability
  , productionTlsRetentionIdentityCapability
  , registeredIamUserName
  , validateLongLivedDecommissionInventory
  )
import Prodbox.Lifecycle.Decommission.Frame
  ( FrameAttemptId
  , FrameNodeId
  , mkFrameAttemptId
  )
import Prodbox.Lifecycle.Decommission.Manifest
  ( DecommissionNode (TlsRetainedObjects)
  , decommissionNodeFrameId
  )
import Prodbox.Lifecycle.Decommission.NodeEffect
  ( observeBackupAllPrefixesAbsent
  , runBackupObjectsIdentityCapability
  , runNodeOperation
  , runSharedObjectBucketCapability
  , runTlsRetainedObjectsCapability
  , runTlsRetentionIdentityCapability
  )
import Prodbox.Lifecycle.ResidueStatus
  ( ResidueDetails (ResidueDetails)
  , ResidueStatus (ResidueAbsent, ResiduePresent, ResidueUnreachable)
  )
import Prodbox.Result (Result (Success))
import Prodbox.Settings
  ( PulumiStateBackendSection
      ( PulumiStateBackendSection
      , psbBucketName
      , psbKeyPrefix
      , psbRegion
      )
  )
import Prodbox.Subprocess
  ( ProcessOutput
      ( ProcessOutput
      , processExitCode
      , processStderr
      , processStdout
      )
  , Subprocess (subprocessArguments)
  )
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import TestSupport

longLivedDecommissionSuite :: SuiteBuilder ()
longLivedDecommissionSuite =
  describe "Sprint 4.50 exact long-lived decommission" $ do
    it "accepts only the fixed two-role registry and rejects widened or overlapping ownership" $ do
      validateLongLivedDecommissionInventory backendSection canonicalSpecs
        `shouldSatisfy` either (const False) (const True)
      validateLongLivedDecommissionInventory backendSection (canonicalSpecs ++ [backupSpec])
        `shouldSatisfy` isLeft
      validateLongLivedDecommissionInventory
        backendSection
        [ tlsSpec {dedicatedIamPrefixes = ["authority-backup-store/home"]}
        , backupSpec
        ]
        `shouldSatisfy` isLeft
      validateLongLivedDecommissionInventory
        backendSection
        [ tlsSpec
        , backupSpec {dedicatedIamPolicyName = tlsRetentionIamPolicyName}
        ]
        `shouldSatisfy` isLeft
      validateLongLivedDecommissionInventory
        backendSection {psbKeyPrefix = "public-edge-tls/"}
        canonicalSpecs
        `shouldSatisfy` isLeft

    it "parses current versions and delete markers as independent residue" $ do
      parseVersionedPrefixInventory "{}"
        `shouldBe` Right (VersionedPrefixInventory 0 0)
      parseVersionedPrefixInventory "{\"Versions\":[{}],\"DeleteMarkers\":[{},{}]}"
        `shouldBe` Right (VersionedPrefixInventory 1 2)
      parseVersionedPrefixInventory "{\"Versions\":null,\"DeleteMarkers\":[]}"
        `shouldBe` Right (VersionedPrefixInventory 0 0)
      parseVersionedPrefixInventory "{\"Versions\":{}}" `shouldSatisfy` isLeft

    it "uses list-object-versions and refuses to recode markers, denial, or bad JSON as absence" $ do
      seenRef <- newIORef []
      let run payload spec = do
            modifyIORef' seenRef (++ [subprocessArguments spec])
            pure payload
          observe payload =
            observeVersionedPrefixWith
              (run payload)
              "/repo"
              [("AWS_REGION", (fixtureAwsRegion FixtureUsEast1))]
              "prodbox-long-lived-test"
              "public-edge-tls/home-local/example.com"
      observe (successful "{\"DeleteMarkers\":[{\"Key\":\"x\"}]}")
        `shouldReturn` presentStatus
      observe (successful "{\"Versions\":[],\"DeleteMarkers\":[]}")
        `shouldReturn` ResidueAbsent
      observe noSuchBucket `shouldReturn` ResidueAbsent
      denial <- observe accessDenied
      denial `shouldSatisfy` isUnreachable
      malformed <- observe (successful "not-json")
      malformed `shouldSatisfy` isUnreachable
      commands <- readIORef seenRef
      commands
        `shouldBe` replicate
          5
          [ "s3api"
          , "list-object-versions"
          , "--bucket"
          , "prodbox-long-lived-test"
          , "--prefix"
          , "public-edge-tls/home-local/example.com"
          , "--max-items"
          , "1"
          , "--output"
          , "json"
          ]

    it "deletes only every key, the fixed inline policy, and the fixed IAM user" $ do
      inventory <- canonicalInventory
      seenRef <- newIORef []
      let identity = inventoryBackupIdentity inventory
          runner spec = do
            modifyIORef' seenRef (++ [subprocessArguments spec])
            pure $ case subprocessArguments spec of
              ["iam", "list-access-keys", "--user-name", _, "--output", "json"] ->
                successful
                  "{\"AccessKeyMetadata\":[{\"AccessKeyId\":\"AKIAONE\"},{\"AccessKeyId\":\"AKIATWO\"}]}"
              _ -> successful "{}"
      destroyRegisteredIamIdentityWith runner "/repo" [] identity `shouldReturn` Right ()
      readIORef seenRef
        `shouldReturn` [ ["iam", "list-access-keys", "--user-name", "prodbox-authority-backup-store", "--output", "json"]
                       ,
                         [ "iam"
                         , "delete-access-key"
                         , "--user-name"
                         , "prodbox-authority-backup-store"
                         , "--access-key-id"
                         , "AKIAONE"
                         ]
                       ,
                         [ "iam"
                         , "delete-access-key"
                         , "--user-name"
                         , "prodbox-authority-backup-store"
                         , "--access-key-id"
                         , "AKIATWO"
                         ]
                       ,
                         [ "iam"
                         , "delete-user-policy"
                         , "--user-name"
                         , "prodbox-authority-backup-store"
                         , "--policy-name"
                         , "prodbox-authority-backup-store"
                         ]
                       , ["iam", "delete-user", "--user-name", "prodbox-authority-backup-store"]
                       ]
      registeredIamUserName identity `shouldBe` authorityBackupIamUserName

    it "rejects malformed, duplicated, and over-bound IAM key inventories" $ do
      parseIamAccessKeyInventory "{\"AccessKeyMetadata\":[]}" `shouldBe` Right []
      parseIamAccessKeyInventory
        "{\"AccessKeyMetadata\":[{\"AccessKeyId\":\"A\"},{\"AccessKeyId\":\"A\"}]}"
        `shouldSatisfy` isLeft
      parseIamAccessKeyInventory
        "{\"AccessKeyMetadata\":[{\"AccessKeyId\":\"A\"},{\"AccessKeyId\":\"B\"},{\"AccessKeyId\":\"C\"}]}"
        `shouldSatisfy` isLeft
      parseIamAccessKeyInventory "{}" `shouldSatisfy` isLeft

    it "keeps prefix, identity, proof, and terminal bucket effects disjoint" $ do
      inventory <- canonicalInventory
      eventsRef <- newIORef ([] :: [Text])
      let record event = modifyIORef' eventsRef (++ [event])
          boundary =
            LongLivedDecommissionBoundary
              { boundaryPurgePrefix = \prefix -> record ("purge:" <> prefix) >> pure (Right ())
              , boundaryObservePrefix = \prefix -> record ("observe-prefix:" <> prefix) >> pure ResidueAbsent
              , boundaryDestroyIdentity = \identity ->
                  record ("destroy-identity:" <> registeredIamUserName identity) >> pure (Right ())
              , boundaryObserveIdentity = \identity ->
                  record ("observe-identity:" <> registeredIamUserName identity) >> pure ResidueAbsent
              , boundaryDestroySharedBucket = record "destroy-bucket" >> pure (Right ())
              , boundaryObserveSharedBucket = record "observe-bucket" >> pure ResidueAbsent
              }
          capabilities = longLivedDecommissionCapabilitiesWith inventory boundary
      runNodeOperation
        (runTlsRetainedObjectsCapability (productionTlsRetainedObjectsCapability capabilities))
        nodeId
        attemptId
        `shouldReturn` Right ()
      runNodeOperation
        (runTlsRetentionIdentityCapability (productionTlsRetentionIdentityCapability capabilities))
        nodeId
        attemptId
        `shouldReturn` Right ()
      runNodeOperation
        (runBackupObjectsIdentityCapability (productionBackupObjectsIdentityCapability capabilities))
        nodeId
        attemptId
        `shouldReturn` Right ()
      observeBackupAllPrefixesAbsent
        (productionBackupAllPrefixesAbsentCapability capabilities)
        nodeId
        attemptId
        `shouldReturn` ResidueAbsent
      beforeBucket <- readIORef eventsRef
      beforeBucket `shouldNotContain` ["destroy-bucket"]
      runNodeOperation
        (runSharedObjectBucketCapability (productionSharedObjectBucketCapability capabilities))
        nodeId
        attemptId
        `shouldReturn` Right ()
      events <- readIORef eventsRef
      filter (Text.isPrefixOf "purge:") events
        `shouldBe` fmap ("purge:" <>) (tlsPrefixes ++ backupPrefixes)
      filter (Text.isPrefixOf "destroy-identity:") events
        `shouldBe` [ "destroy-identity:prodbox-tls-retention-store"
                   , "destroy-identity:prodbox-authority-backup-store"
                   ]
      -- TLS objects contribute four events, TLS identity two, and the backup
      -- objects/identity node six; the read-only proof starts at offset 12.
      let proofObservations = drop 12 (take (length beforeBucket) events)
      sort (filter (Text.isPrefixOf "observe-prefix:") proofObservations)
        `shouldBe` sort (fmap ("observe-prefix:" <>) (tlsPrefixes ++ backupPrefixes ++ ["pulumi/"]))
      filter (== "destroy-bucket") events `shouldBe` ["destroy-bucket"]
    it "aggregates independent prefix failures before refusing the node" $ do
      inventory <- canonicalInventory
      let boundary =
            LongLivedDecommissionBoundary
              { boundaryPurgePrefix = \prefix -> pure (Left ("failed:" <> prefix))
              , boundaryObservePrefix = \_ -> pure ResidueAbsent
              , boundaryDestroyIdentity = \_ -> pure (Right ())
              , boundaryObserveIdentity = \_ -> pure ResidueAbsent
              , boundaryDestroySharedBucket = pure (Right ())
              , boundaryObserveSharedBucket = pure ResidueAbsent
              }
          operation =
            runTlsRetainedObjectsCapability
              ( productionTlsRetainedObjectsCapability
                  (longLivedDecommissionCapabilitiesWith inventory boundary)
              )
      result <- runNodeOperation operation nodeId attemptId
      result `shouldSatisfy` leftTextContains "failed:public-edge-tls/home-local/example.com"
      result `shouldSatisfy` leftTextContains "failed:public-edge-tls/aws/aws.example.com"

    it "treats only exact HeadBucket 404 as terminal bucket absence" $ do
      let observe output = observeSharedBucketWith (const (pure output)) "/repo" [] "prodbox-long-lived-test"
      observe (successful "") `shouldReturn` bucketPresentStatus
      observe headBucket404 `shouldReturn` ResidueAbsent
      denied <- observe accessDenied
      denied `shouldSatisfy` isUnreachable

canonicalInventory :: IO LongLivedDecommissionInventory
canonicalInventory =
  case validateLongLivedDecommissionInventory backendSection canonicalSpecs of
    Left detail -> expectationFailure (Text.unpack detail) >> fail "unreachable"
    Right inventory -> pure inventory

backendSection :: PulumiStateBackendSection
backendSection =
  PulumiStateBackendSection
    { psbBucketName = "prodbox-long-lived-test"
    , psbRegion = (fixtureAwsRegion FixtureUsEast1)
    , psbKeyPrefix = "pulumi/"
    }

canonicalSpecs :: [DedicatedAdapterIamSpec]
canonicalSpecs = [backupSpec, tlsSpec]

backupSpec :: DedicatedAdapterIamSpec
backupSpec =
  DedicatedAdapterIamSpec
    { dedicatedIamUserName = authorityBackupIamUserName
    , dedicatedIamPolicyName = authorityBackupIamPolicyName
    , dedicatedIamVaultPath = "aws/authority-backup-store"
    , dedicatedIamPrefixes = backupPrefixes
    }

tlsSpec :: DedicatedAdapterIamSpec
tlsSpec =
  DedicatedAdapterIamSpec
    { dedicatedIamUserName = tlsRetentionIamUserName
    , dedicatedIamPolicyName = tlsRetentionIamPolicyName
    , dedicatedIamVaultPath = "aws/tls-retention-store"
    , dedicatedIamPrefixes = tlsPrefixes
    }

tlsPrefixes :: [Text]
tlsPrefixes =
  [ "public-edge-tls/home-local/example.com"
  , "public-edge-tls/aws/aws.example.com"
  ]

backupPrefixes :: [Text]
backupPrefixes =
  [ "authority-backup-store/home"
  , "authority-backup-store/aws-eks"
  ]

nodeId :: FrameNodeId
nodeId = decommissionNodeFrameId TlsRetainedObjects

attemptId :: FrameAttemptId
attemptId = fromJust (mkFrameAttemptId "long-lived-attempt")

successful :: String -> Result ProcessOutput
successful stdout =
  Success
    ProcessOutput
      { processExitCode = ExitSuccess
      , processStdout = stdout
      , processStderr = ""
      }

noSuchBucket :: Result ProcessOutput
noSuchBucket = failed "An error occurred (NoSuchBucket) when calling the ListObjectVersions operation"

headBucket404 :: Result ProcessOutput
headBucket404 = failed "An error occurred (404) when calling the HeadBucket operation: Not Found"

accessDenied :: Result ProcessOutput
accessDenied = failed "An error occurred (AccessDenied) when calling the operation"

failed :: String -> Result ProcessOutput
failed stderr =
  Success
    ProcessOutput
      { processExitCode = ExitFailure 254
      , processStdout = ""
      , processStderr = stderr
      }

presentStatus :: ResidueStatus
presentStatus =
  ResiduePresent
    ( ResidueDetails
        "prefix public-edge-tls/home-local/example.com has 0 version(s) and 1 delete marker(s) in the bounded read-back"
        "long-lived-s3-prefix"
    )

bucketPresentStatus :: ResidueStatus
bucketPresentStatus =
  ResiduePresent
    (ResidueDetails "AWS S3 HeadBucket confirmed prodbox-long-lived-test" "long-lived-s3-bucket")

isUnreachable :: ResidueStatus -> Bool
isUnreachable ResidueUnreachable {} = True
isUnreachable _ = False

leftTextContains :: Text -> Either Text a -> Bool
leftTextContains needle result = case result of
  Left detail -> needle `Text.isInfixOf` detail
  Right _ -> False
