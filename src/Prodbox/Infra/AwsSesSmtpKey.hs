{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Exact AWS IAM adapter for the fenced SES SMTP access-key repair fold.
-- Pulumi owns the fixed IAM user and policy; this module is the sole supported
-- access-key list/delete/create boundary.
module Prodbox.Infra.AwsSesSmtpKey
  ( AwsSesSmtpCommandFailure (..)
  , awsSesSmtpCommitCoordinate
  , classifyAwsSesSmtpCommandResult
  , classifyAwsSesSmtpKeyCreateResult
  , classifyAwsSesSmtpKeyDeleteResult
  , classifyAwsSesSmtpKeyInventoryResult
  , createAwsSesSmtpAccessKey
  , createAwsSesSmtpAccessKeyWith
  , deleteAwsSesSmtpAccessKey
  , deleteAwsSesSmtpAccessKeyWith
  , observeAwsSesSmtpKeyInventory
  , observeAwsSesSmtpKeyInventoryWith
  , smtpKeyMaterialDigest
  )
where

import Data.Aeson
  ( FromJSON (..)
  , eitherDecode
  , withObject
  , (.:)
  )
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.CheckpointAuthority
  ( AuthorityCoordinateError
  , LongLivedCheckpointAuthority
  , ModelBObjectCoordinate
  , StoreLifetime (ClusterRetained)
  , mkClusterRetainedCoordinate
  )
import Prodbox.Lifecycle.Lease
  ( LeaseKey
  , leaseKeyAccount
  , leaseKeyRegion
  , leaseKeyResource
  )
import Prodbox.Lifecycle.SmtpKeyRepair
  ( SmtpAccessKeyId
  , SmtpKeyCleanupResult (..)
  , SmtpKeyInventoryObservation (..)
  , mkSmtpAccessKeyId
  , smtpAccessKeyIdText
  )
import Prodbox.Lifecycle.TargetCommitIntent
  ( TargetValueDigest
  , sha256TargetValueDigest
  )
import Prodbox.Result (Result (..))
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  )
import System.Exit (ExitCode (..))

data AwsSesSmtpCommandFailure
  = AwsSesSmtpUserNotFound !Text
  | AwsSesSmtpAccessDenied !Text
  | AwsSesSmtpNetworkFailure !Text
  | AwsSesSmtpProcessStartFailure !Text
  | AwsSesSmtpOtherCommandFailure !Text
  deriving (Eq, Show)

sesSmtpUserName :: String
sesSmtpUserName = "prodbox-ses-smtp"

awsSesSmtpCommitCoordinate
  :: LongLivedCheckpointAuthority
  -> LeaseKey
  -> Either AuthorityCoordinateError (ModelBObjectCoordinate 'ClusterRetained)
awsSesSmtpCommitCoordinate authority key =
  mkClusterRetainedCoordinate
    authority
    ( Text.intercalate
        "/"
        [ "smtp-commit"
        , leaseKeyAccount key
        , leaseKeyRegion key
        , leaseKeyResource key
        ]
    )

newtype AccessKeyListResponse = AccessKeyListResponse
  { accessKeyListMetadata :: [AccessKeyMetadata]
  }

instance FromJSON AccessKeyListResponse where
  parseJSON =
    withObject "AccessKeyListResponse" $ \root ->
      AccessKeyListResponse <$> root .: "AccessKeyMetadata"

data AccessKeyMetadata = AccessKeyMetadata
  { accessKeyMetadataUserName :: !Text
  , accessKeyMetadataId :: !Text
  }

instance FromJSON AccessKeyMetadata where
  parseJSON =
    withObject "AccessKeyMetadata" $ \entry ->
      AccessKeyMetadata
        <$> entry .: "UserName"
        <*> entry .: "AccessKeyId"

newtype CreateAccessKeyResponse = CreateAccessKeyResponse
  { createAccessKeyPayload :: CreatedAccessKey
  }

instance FromJSON CreateAccessKeyResponse where
  parseJSON =
    withObject "CreateAccessKeyResponse" $ \root ->
      CreateAccessKeyResponse <$> root .: "AccessKey"

data CreatedAccessKey = CreatedAccessKey
  { createdAccessKeyUserName :: !Text
  , createdAccessKeyId :: !Text
  , createdSecretAccessKey :: !Text
  }

instance FromJSON CreatedAccessKey where
  parseJSON =
    withObject "CreatedAccessKey" $ \entry ->
      CreatedAccessKey
        <$> entry .: "UserName"
        <*> entry .: "AccessKeyId"
        <*> entry .: "SecretAccessKey"

observeAwsSesSmtpKeyInventory
  :: FilePath
  -> [(String, String)]
  -> IO SmtpKeyInventoryObservation
observeAwsSesSmtpKeyInventory =
  observeAwsSesSmtpKeyInventoryWith captureSubprocessResult

observeAwsSesSmtpKeyInventoryWith
  :: (Monad m)
  => (Subprocess -> m (Result ProcessOutput))
  -> FilePath
  -> [(String, String)]
  -> m SmtpKeyInventoryObservation
observeAwsSesSmtpKeyInventoryWith runProcess workingDirectory environment =
  classifyAwsSesSmtpKeyInventoryResult
    <$> runProcess
      (awsCommand workingDirectory environment listAccessKeyArguments)

classifyAwsSesSmtpKeyInventoryResult
  :: Result ProcessOutput -> SmtpKeyInventoryObservation
classifyAwsSesSmtpKeyInventoryResult result =
  case classifyAwsSesSmtpCommandResult result of
    Left (AwsSesSmtpUserNotFound _) ->
      SmtpKeyInventoryPending "SMTP IAM user is not yet visible"
    Left failure ->
      SmtpKeyInventoryUnobservable (renderAwsSesSmtpCommandFailure failure)
    Right output ->
      case eitherDecode (BL8.pack output) of
        Left err ->
          SmtpKeyInventoryUnobservable
            (Text.pack ("invalid IAM access-key inventory JSON: " ++ err))
        Right response -> classifyAccessKeyMetadata (accessKeyListMetadata response)

classifyAccessKeyMetadata :: [AccessKeyMetadata] -> SmtpKeyInventoryObservation
classifyAccessKeyMetadata metadata
  | actual > iamAccessKeyMaximum =
      SmtpKeyInventoryOverBound actual iamAccessKeyMaximum
  | otherwise =
      case traverse validateEntry metadata of
        Left detail -> SmtpKeyInventoryUnobservable detail
        Right keyIds -> SmtpKeyInventoryObserved keyIds
 where
  actual = fromIntegral (length metadata)
  iamAccessKeyMaximum = 2 :: Natural
  validateEntry entry
    | accessKeyMetadataUserName entry /= Text.pack sesSmtpUserName =
        Left
          ( "IAM returned an access key for unexpected user "
              <> accessKeyMetadataUserName entry
          )
    | otherwise =
        first (Text.pack . show) (mkSmtpAccessKeyId (accessKeyMetadataId entry))

deleteAwsSesSmtpAccessKey
  :: FilePath
  -> [(String, String)]
  -> SmtpAccessKeyId
  -> IO SmtpKeyCleanupResult
deleteAwsSesSmtpAccessKey =
  deleteAwsSesSmtpAccessKeyWith captureSubprocessResult

deleteAwsSesSmtpAccessKeyWith
  :: (Monad m)
  => (Subprocess -> m (Result ProcessOutput))
  -> FilePath
  -> [(String, String)]
  -> SmtpAccessKeyId
  -> m SmtpKeyCleanupResult
deleteAwsSesSmtpAccessKeyWith runProcess workingDirectory environment keyId =
  classifyAwsSesSmtpKeyDeleteResult keyId
    <$> runProcess
      ( awsCommand
          workingDirectory
          environment
          (deleteAccessKeyArguments keyId)
      )

classifyAwsSesSmtpKeyDeleteResult
  :: SmtpAccessKeyId -> Result ProcessOutput -> SmtpKeyCleanupResult
classifyAwsSesSmtpKeyDeleteResult keyId result =
  case classifyAwsSesSmtpCommandResult result of
    Right _ -> SmtpKeyDeleted keyId
    Left (AwsSesSmtpUserNotFound _) -> SmtpKeyDeleted keyId
    Left failure ->
      SmtpKeyDeleteFailed keyId (renderAwsSesSmtpCommandFailure failure)

createAwsSesSmtpAccessKey
  :: FilePath
  -> [(String, String)]
  -> IO (Either Text (SmtpAccessKeyId, ByteString))
createAwsSesSmtpAccessKey =
  createAwsSesSmtpAccessKeyWith captureSubprocessResult

createAwsSesSmtpAccessKeyWith
  :: (Monad m)
  => (Subprocess -> m (Result ProcessOutput))
  -> FilePath
  -> [(String, String)]
  -> m (Either Text (SmtpAccessKeyId, ByteString))
createAwsSesSmtpAccessKeyWith runProcess workingDirectory environment =
  classifyAwsSesSmtpKeyCreateResult
    <$> runProcess
      (awsCommand workingDirectory environment createAccessKeyArguments)

classifyAwsSesSmtpKeyCreateResult
  :: Result ProcessOutput -> Either Text (SmtpAccessKeyId, ByteString)
classifyAwsSesSmtpKeyCreateResult result = do
  output <- first renderAwsSesSmtpCommandFailure (classifyAwsSesSmtpCommandResult result)
  response <-
    first
      (Text.pack . ("invalid IAM create-access-key JSON: " ++))
      (eitherDecode (BL8.pack output))
  let created = createAccessKeyPayload response
  if createdAccessKeyUserName created /= Text.pack sesSmtpUserName
    then
      Left
        ( "IAM created an access key for unexpected user "
            <> createdAccessKeyUserName created
        )
    else do
      keyId <- first (Text.pack . show) (mkSmtpAccessKeyId (createdAccessKeyId created))
      let material = TextEncoding.encodeUtf8 (createdSecretAccessKey created)
      if BS.null material
        then Left "IAM create-access-key returned empty secret material"
        else Right (keyId, material)

smtpKeyMaterialDigest :: ByteString -> TargetValueDigest
smtpKeyMaterialDigest = sha256TargetValueDigest

classifyAwsSesSmtpCommandResult
  :: Result ProcessOutput -> Either AwsSesSmtpCommandFailure String
classifyAwsSesSmtpCommandResult result = case result of
  Failure detail ->
    Left (AwsSesSmtpProcessStartFailure (Text.pack detail))
  Success output -> case processExitCode output of
    ExitSuccess -> Right (processStdout output)
    ExitFailure _ -> Left (classifyCommandFailure (renderProcessDetail output))

classifyCommandFailure :: String -> AwsSesSmtpCommandFailure
classifyCommandFailure detail
  | awsErrorCodeIs "nosuchentity" normalized = AwsSesSmtpUserNotFound rendered
  | awsErrorCodeIs "accessdenied" normalized
      || awsErrorCodeIs "accessdeniedexception" normalized =
      AwsSesSmtpAccessDenied rendered
  | any (`Text.isInfixOf` normalized) networkMarkers =
      AwsSesSmtpNetworkFailure rendered
  | otherwise = AwsSesSmtpOtherCommandFailure rendered
 where
  rendered = Text.pack detail
  normalized = Text.toLower rendered
  networkMarkers =
    [ "could not connect to the endpoint url"
    , "connection timed out"
    , "connection reset"
    , "name or service not known"
    , "temporary failure in name resolution"
    , "network is unreachable"
    ]

awsErrorCodeIs :: Text -> Text -> Bool
awsErrorCodeIs expected detail =
  ("(" <> Text.toLower expected <> ")") `Text.isInfixOf` detail

renderAwsSesSmtpCommandFailure :: AwsSesSmtpCommandFailure -> Text
renderAwsSesSmtpCommandFailure failure = case failure of
  AwsSesSmtpUserNotFound detail -> "AWS IAM SMTP user not found: " <> detail
  AwsSesSmtpAccessDenied detail -> "AWS IAM access denied: " <> detail
  AwsSesSmtpNetworkFailure detail -> "AWS IAM network failure: " <> detail
  AwsSesSmtpProcessStartFailure detail -> "failed to start aws: " <> detail
  AwsSesSmtpOtherCommandFailure detail -> "AWS IAM command failed: " <> detail

awsCommand
  :: FilePath -> [(String, String)] -> [String] -> Subprocess
awsCommand workingDirectory environment arguments =
  Subprocess
    { subprocessPath = "aws"
    , subprocessArguments = arguments
    , subprocessEnvironment = Just environment
    , subprocessWorkingDirectory = Just workingDirectory
    }

listAccessKeyArguments :: [String]
listAccessKeyArguments =
  [ "iam"
  , "list-access-keys"
  , "--user-name"
  , sesSmtpUserName
  , "--output"
  , "json"
  ]

deleteAccessKeyArguments :: SmtpAccessKeyId -> [String]
deleteAccessKeyArguments keyId =
  [ "iam"
  , "delete-access-key"
  , "--user-name"
  , sesSmtpUserName
  , "--access-key-id"
  , Text.unpack (smtpAccessKeyIdText keyId)
  ]

createAccessKeyArguments :: [String]
createAccessKeyArguments =
  [ "iam"
  , "create-access-key"
  , "--user-name"
  , sesSmtpUserName
  , "--output"
  , "json"
  ]

renderProcessDetail :: ProcessOutput -> String
renderProcessDetail output =
  case filter (not . null) [trim (processStderr output), trim (processStdout output)] of
    [] -> "subprocess exited without output"
    messages -> foldr1 (\left right -> left ++ " | " ++ right) messages

trim :: String -> String
trim = reverse . dropWhile (`elem` ['\n', '\r', ' ']) . reverse
