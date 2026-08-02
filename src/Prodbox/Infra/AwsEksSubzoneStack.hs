{-# LANGUAGE OverloadedStrings #-}

-- | Typed Provider-client surface and retained-output decoder for the AWS EKS
-- delegated subzone stack.  No host Pulumi or AWS mutation remains here.
module Prodbox.Infra.AwsEksSubzoneStack
  ( AwsEksSubzoneStackSnapshot (..)
  , awsEksSubzoneStackName
  , ensureAwsEksSubzoneStackResources
  , ensureAwsEksSubzoneStackResourcesWithAuthentication
  , destroyAwsEksSubzoneStack
  , destroyAwsEksSubzoneStackWithAuthentication
  , awsEksSubzoneStackResidueStatus
  , assertNoAwsEksSubzoneStackResidue
  , renderAwsEksSubzoneStackReport
  , parseAwsEksSubzoneStackFromOutputs
  )
where

import Data.Aeson (Value (Array, String), eitherDecode)
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Prodbox.CLI.Output (writeError, writeOutputLine)
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller (LifecycleAuthorityOperator)
  , LifecycleAuthorityAuthentication
  , renderLifecycleAuthorityAuthenticationError
  , withHostLifecycleAuthorityAuthentication
  )
import Prodbox.ControlPlane.ProviderCaller
  ( dispatchAuthenticatedProviderIntentFresh
  , renderProviderCallerError
  )
import Prodbox.Error (fatalError)
import Prodbox.Lifecycle.LiveResidue qualified as LiveResidue
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (DestroyRegisteredStack, ReconcileRegisteredStack)
  , mkAwsEksSubzoneProviderStackConfig
  , mkProviderRevision
  , mkProviderStackRef
  )
import Prodbox.Lifecycle.ResidueStatus qualified as ResidueStatus
import Prodbox.Settings
  ( AwsSubstrateSection (subzone_name)
  , Route53Section (zone_id)
  , ValidatedSettings (validatedConfig)
  , aws_substrate
  , route53
  , validateAndLoadSettings
  )
import System.Exit (ExitCode (ExitFailure, ExitSuccess))

awsEksSubzoneStackName :: String
awsEksSubzoneStackName = "aws-eks-subzone"

awsEksSubzoneStackResidueStatus :: FilePath -> IO ResidueStatus.ResidueStatus
awsEksSubzoneStackResidueStatus repoRoot =
  LiveResidue.perRunAwsEksSubzone <$> LiveResidue.queryPerRunResidueStatuses repoRoot

data AwsEksSubzoneStackSnapshot = AwsEksSubzoneStackSnapshot
  { subzoneSnapshotStackName :: String
  , subzoneSnapshotBackendBucket :: String
  , subzoneSnapshotSubzoneId :: String
  , subzoneSnapshotSubzoneName :: String
  , subzoneSnapshotSubzoneNameServers :: [String]
  , subzoneSnapshotParentZoneId :: String
  , subzoneSnapshotParentNsRecordFqdn :: String
  }
  deriving (Eq, Show)

data AwsEksSubzoneStackConfig = AwsEksSubzoneStackConfig
  { subzoneStackParentZoneId :: Text.Text
  , subzoneStackSubzoneName :: Text.Text
  }

ensureAwsEksSubzoneStackResources :: FilePath -> IO ExitCode
ensureAwsEksSubzoneStackResources repoRoot =
  withOperatorLifecycleAuthority repoRoot $ \authentication ->
    ensureAwsEksSubzoneStackResourcesWithAuthentication authentication repoRoot

ensureAwsEksSubzoneStackResourcesWithAuthentication
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> IO ExitCode
ensureAwsEksSubzoneStackResourcesWithAuthentication authentication repoRoot = do
  config <- resolveAwsEksSubzoneStackConfig repoRoot
  dispatchConfigured authentication "operator-reconcile-aws-eks-subzone" True config

destroyAwsEksSubzoneStack :: FilePath -> Bool -> IO ExitCode
destroyAwsEksSubzoneStack repoRoot summary =
  withOperatorLifecycleAuthority repoRoot $ \authentication ->
    destroyAwsEksSubzoneStackWithAuthentication authentication repoRoot summary

destroyAwsEksSubzoneStackWithAuthentication
  :: LifecycleAuthorityAuthentication
  -> FilePath
  -> Bool
  -> IO ExitCode
destroyAwsEksSubzoneStackWithAuthentication authentication repoRoot _summary = do
  config <- resolveAwsEksSubzoneStackConfig repoRoot
  dispatchConfigured authentication "operator-destroy-aws-eks-subzone" False config

dispatchConfigured
  :: LifecycleAuthorityAuthentication
  -> Text.Text
  -> Bool
  -> Either String AwsEksSubzoneStackConfig
  -> IO ExitCode
dispatchConfigured authentication prefix desiredPresent configResult =
  case configResult of
    Left err -> failWith err
    Right stackConfig ->
      case ( mkProviderStackRef "aws-eks-subzone"
           , mkProviderRevision 1
           , mkAwsEksSubzoneProviderStackConfig
               (subzoneStackParentZoneId stackConfig)
               (subzoneStackSubzoneName stackConfig)
           ) of
        (Right ref, Right revision, Right config) -> do
          let intent =
                if desiredPresent
                  then ReconcileRegisteredStack ref revision config
                  else DestroyRegisteredStack ref revision config
          result <- dispatchAuthenticatedProviderIntentFresh authentication prefix intent
          case result of
            Left err -> failWith (renderProviderCallerError err)
            Right evidence -> do
              writeOutputLine
                ( ( if desiredPresent
                      then "AWS EKS subzone Provider receipt: "
                      else "AWS EKS subzone Provider destroy receipt: "
                  )
                    ++ Text.unpack evidence
                )
              pure ExitSuccess
        (refResult, revisionResult, providerConfig) ->
          failWith
            ( "build typed AWS EKS subzone Provider intent: "
                ++ show (refResult, revisionResult, providerConfig)
            )

resolveAwsEksSubzoneStackConfig
  :: FilePath -> IO (Either String AwsEksSubzoneStackConfig)
resolveAwsEksSubzoneStackConfig repoRoot = do
  settings <- validateAndLoadSettings repoRoot
  pure $ do
    validated <- settings
    let config = validatedConfig validated
        parentZone = Text.strip (zone_id (route53 config))
        subzone = Text.strip (subzone_name (aws_substrate config))
    if Text.null parentZone || Text.null subzone
      then Left "route53.zone_id and aws_substrate.subzone_name must be configured"
      else Right (AwsEksSubzoneStackConfig parentZone subzone)

withOperatorLifecycleAuthority
  :: FilePath
  -> (LifecycleAuthorityAuthentication -> IO ExitCode)
  -> IO ExitCode
withOperatorLifecycleAuthority repoRoot action = do
  authenticated <-
    withHostLifecycleAuthorityAuthentication LifecycleAuthorityOperator repoRoot action
  case authenticated of
    Left err -> failWith (renderLifecycleAuthorityAuthenticationError err)
    Right exitCode -> pure exitCode

parseAwsEksSubzoneStackFromOutputs
  :: Map.Map Text.Text Text.Text -> Either String AwsEksSubzoneStackSnapshot
parseAwsEksSubzoneStackFromOutputs outputs =
  AwsEksSubzoneStackSnapshot awsEksSubzoneStackName
    <$> requireString outputs "backend_bucket"
    <*> requireString outputs "subzone_id"
    <*> requireString outputs "subzone_name"
    <*> requireStringList outputs "subzone_name_servers"
    <*> requireString outputs "parent_zone_id"
    <*> requireString outputs "parent_ns_record_fqdn"

requireString :: Map.Map Text.Text Text.Text -> Text.Text -> Either String String
requireString outputs key = case Map.lookup key outputs of
  Just value | not (Text.null value) -> Right (Text.unpack value)
  _ -> Left ("aws-eks-subzone outputs missing non-empty field '" ++ Text.unpack key ++ "'")

requireStringList
  :: Map.Map Text.Text Text.Text -> Text.Text -> Either String [String]
requireStringList outputs key = do
  raw <- requireString outputs key
  case eitherDecode (BL8.pack raw) of
    Left err -> Left ("aws-eks-subzone field '" ++ Text.unpack key ++ "' is invalid JSON: " ++ err)
    Right (Array values) -> traverse entry (Vector.toList values)
    Right _ -> Left ("aws-eks-subzone field '" ++ Text.unpack key ++ "' must be an array")
 where
  entry (String value) | not (Text.null value) = Right (Text.unpack value)
  entry _ = Left ("aws-eks-subzone field '" ++ Text.unpack key ++ "' must contain strings")

renderAwsEksSubzoneStackReport :: AwsEksSubzoneStackSnapshot -> Int -> String
renderAwsEksSubzoneStackReport snapshot objectCount =
  unlines
    [ "STACK=" ++ subzoneSnapshotStackName snapshot
    , "BACKEND_BUCKET=" ++ subzoneSnapshotBackendBucket snapshot
    , "BACKEND_OBJECT_COUNT=" ++ show objectCount
    , "SUBZONE_ID=" ++ subzoneSnapshotSubzoneId snapshot
    , "SUBZONE_NAME=" ++ subzoneSnapshotSubzoneName snapshot
    , "SUBZONE_NAME_SERVERS=" ++ joinComma (subzoneSnapshotSubzoneNameServers snapshot)
    , "PARENT_ZONE_ID=" ++ subzoneSnapshotParentZoneId snapshot
    , "PARENT_NS_RECORD_FQDN=" ++ subzoneSnapshotParentNsRecordFqdn snapshot
    ]

assertNoAwsEksSubzoneStackResidue :: FilePath -> IO (Either String ())
assertNoAwsEksSubzoneStackResidue repoRoot = do
  status <- awsEksSubzoneStackResidueStatus repoRoot
  pure $ case status of
    ResidueStatus.ResidueAbsent -> Right ()
    ResidueStatus.ResiduePresent detail -> Left (ResidueStatus.renderResidueDetails detail)
    ResidueStatus.ResidueUnreachable detail ->
      Left (ResidueStatus.renderResidueUnreachableReason detail)

joinComma :: [String] -> String
joinComma = foldr (\value rest -> value ++ if null rest then "" else "," ++ rest) ""

failWith :: String -> IO ExitCode
failWith detail = do
  writeError (fatalError (Text.pack detail))
  pure (ExitFailure 1)
