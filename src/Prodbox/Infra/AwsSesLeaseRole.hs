{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The fixed, bounded IAM role used by one AWS SES lease transaction.
-- Policy construction is pure; AWS observation and reconciliation use an
-- injected subprocess boundary so every IAM result is classified explicitly.
module Prodbox.Infra.AwsSesLeaseRole
  ( AwsSesLeaseRoleCommandFailure (..)
  , AwsSesLeaseRoleDrift (..)
  , AwsSesLeaseRoleError (..)
  , AwsSesLeaseRoleObservation (..)
  , AwsSesLeaseRoleOps (..)
  , AwsSesLeaseRolePolicyScope
  , AwsSesLeaseRoleValueError (..)
  , awsSesLeaseOperationalUserArn
  , awsSesLeaseOperationalUserName
  , awsSesLeaseRoleArn
  , awsSesLeaseRoleAssumeStatement
  , awsSesLeaseRoleInlinePolicy
  , awsSesLeaseRoleInlinePolicyName
  , awsSesLeaseRoleMaxSessionDurationSeconds
  , awsSesLeaseRoleName
  , awsSesLeaseRoleOpsWith
  , awsSesLeaseRoleTrustPolicy
  , classifyAwsSesLeaseRoleCommandResult
  , deleteAwsSesLeaseRole
  , deleteAwsSesLeaseRoleWith
  , ensureAwsSesLeaseRole
  , ensureAwsSesLeaseRoleWith
  , mkAwsSesLeaseRolePolicyScope
  , observeAwsSesLeaseRole
  , observeAwsSesLeaseRoleWith
  , productionAwsSesLeaseRoleOps
  )
where

import Data.Aeson
  ( FromJSON (..)
  , Value
  , eitherDecode
  , encode
  , object
  , withObject
  , (.:)
  , (.=)
  )
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Char (isAsciiLower, isAsciiUpper)
import Data.Maybe (fromMaybe, maybeToList)
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.AwsEnvironment (awsCliSubprocessEnvironment)
import Prodbox.Result (Result (..))
import Prodbox.Settings (Credentials)
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  )
import System.Exit (ExitCode (..))

awsSesLeaseOperationalUserName :: Text
awsSesLeaseOperationalUserName = "prodbox"

awsSesLeaseRoleName :: Text
awsSesLeaseRoleName = "prodbox-ses-lease-session"

awsSesLeaseRoleInlinePolicyName :: Text
awsSesLeaseRoleInlinePolicyName = "prodbox-ses-lease-session-inline"

awsSesLeaseRoleMaxSessionDurationSeconds :: Natural
awsSesLeaseRoleMaxSessionDurationSeconds = 3600

data AwsSesLeaseRoleValueError
  = AwsSesLeaseRoleAccountIdMustBeTwelveDigits !Text
  | AwsSesLeaseRoleHostedZoneIdInvalid !Text
  | AwsSesLeaseRoleCaptureBucketInvalid !Text
  | AwsSesLeaseRoleLegacyStateBucketInvalid !Text
  deriving (Eq, Show)

-- | All identifiers needed to render the resource-bounded role policy.
-- These are public AWS resource identifiers, not credential material.
data AwsSesLeaseRolePolicyScope = AwsSesLeaseRolePolicyScope
  { internalAwsSesLeaseRoleAccountId :: !Text
  , internalAwsSesLeaseRoleHostedZoneId :: !Text
  , internalAwsSesLeaseRoleCaptureBucket :: !Text
  , internalAwsSesLeaseRoleLegacyStateBucket :: !(Maybe Text)
  }
  deriving (Eq, Show)

mkAwsSesLeaseRolePolicyScope
  :: Text
  -> Text
  -> Text
  -> Maybe Text
  -> Either AwsSesLeaseRoleValueError AwsSesLeaseRolePolicyScope
mkAwsSesLeaseRolePolicyScope accountId hostedZoneId captureBucket legacyStateBucket = do
  validatedAccount <- validateAccountId accountId
  validatedZone <- validateHostedZoneId hostedZoneId
  validatedCapture <-
    mapLeft
      (const (AwsSesLeaseRoleCaptureBucketInvalid (Text.strip captureBucket)))
      (validateBucketName captureBucket)
  validatedLegacy <-
    traverse
      ( \bucket ->
          mapLeft
            (const (AwsSesLeaseRoleLegacyStateBucketInvalid (Text.strip bucket)))
            (validateBucketName bucket)
      )
      legacyStateBucket
  pure
    AwsSesLeaseRolePolicyScope
      { internalAwsSesLeaseRoleAccountId = validatedAccount
      , internalAwsSesLeaseRoleHostedZoneId = validatedZone
      , internalAwsSesLeaseRoleCaptureBucket = validatedCapture
      , internalAwsSesLeaseRoleLegacyStateBucket = validatedLegacy
      }

awsSesLeaseRoleArn :: Text -> Either AwsSesLeaseRoleValueError Text
awsSesLeaseRoleArn accountId = roleArnFor <$> validateAccountId accountId

awsSesLeaseOperationalUserArn
  :: Text -> Either AwsSesLeaseRoleValueError Text
awsSesLeaseOperationalUserArn accountId =
  operationalUserArnFor <$> validateAccountId accountId

-- | Exact same-account trust. No account root, wildcard principal, service
-- principal, or alternate operational user is accepted.
awsSesLeaseRoleTrustPolicy
  :: Text -> Either AwsSesLeaseRoleValueError Value
awsSesLeaseRoleTrustPolicy accountId =
  trustPolicyFor <$> validateAccountId accountId

-- | Statement installed on the operational user by its owning harness. It can
-- assume only this account's fixed SES lease role.
awsSesLeaseRoleAssumeStatement
  :: Text -> Either AwsSesLeaseRoleValueError Value
awsSesLeaseRoleAssumeStatement accountId = do
  roleArn <- awsSesLeaseRoleArn accountId
  pure
    ( object
        [ "Sid" .= ("AssumeAwsSesLeaseRole" :: Text)
        , "Effect" .= ("Allow" :: Text)
        , "Action" .= (["sts:AssumeRole"] :: [Text])
        , "Resource" .= roleArn
        ]
    )

-- | Resource-bounded permissions for the SES stack, its exact SMTP IAM user,
-- its one hosted zone, and its configured S3 buckets. SES identity and receipt
-- rule APIs have no useful resource-level authorization and therefore use
-- explicit actions on @"*"@; no service-wide action wildcard is granted.
awsSesLeaseRoleInlinePolicy :: AwsSesLeaseRolePolicyScope -> Value
awsSesLeaseRoleInlinePolicy scope =
  object
    [ "Version" .= ("2012-10-17" :: Text)
    , "Statement"
        .= ( [ allow "StsIdentity" ["sts:GetCallerIdentity"] "*"
             , allow
                 "Route53RecordLifecycle"
                 [ "route53:ChangeResourceRecordSets"
                 , "route53:GetHostedZone"
                 , "route53:ListResourceRecordSets"
                 ]
                 hostedZoneArn
             , allow
                 "Route53ChangePolling"
                 ["route53:GetChange"]
                 "arn:aws:route53:::change/*"
             , allow "SesLifecycle" sesLifecycleActions "*"
             ]
               ++ bucketPolicyStatements "Capture" captureBucket
               ++ concatMap
                 (bucketPolicyStatements "LegacyState")
                 (maybeToList legacyStateBucket)
               ++ [ allow
                      "SmtpIamUserLifecycle"
                      smtpIamUserLifecycleActions
                      smtpUserArn
                  ]
           )
    ]
 where
  accountId = internalAwsSesLeaseRoleAccountId scope
  captureBucket = internalAwsSesLeaseRoleCaptureBucket scope
  legacyStateBucket = internalAwsSesLeaseRoleLegacyStateBucket scope
  hostedZoneArn =
    "arn:aws:route53:::hostedzone/"
      <> internalAwsSesLeaseRoleHostedZoneId scope
  smtpUserArn = "arn:aws:iam::" <> accountId <> ":user/prodbox-ses-smtp"

data AwsSesLeaseRoleCommandFailure
  = AwsSesLeaseRoleNotFound !Text
  | AwsSesLeaseRoleAlreadyExists !Text
  | AwsSesLeaseRoleAccessDenied !Text
  | AwsSesLeaseRoleNetworkFailure !Text
  | AwsSesLeaseRoleProcessStartFailure !Text
  | AwsSesLeaseRoleOtherCommandFailure !Text
  deriving (Eq, Show)

data AwsSesLeaseRoleDrift
  = AwsSesLeaseRoleTrustPolicyDrift
  | AwsSesLeaseRoleMaxSessionDurationDrift !Natural
  | AwsSesLeaseRoleInlinePolicyMissing
  | AwsSesLeaseRoleInlinePolicyDrift
  deriving (Eq, Show)

data AwsSesLeaseRoleError
  = AwsSesLeaseRoleCommandError !AwsSesLeaseRoleCommandFailure
  | AwsSesLeaseRoleMalformedResponse !Text
  | AwsSesLeaseRoleUnexpectedResponse !Text
  | AwsSesLeaseRolePostconditionFailed !Text
  deriving (Eq, Show)

data AwsSesLeaseRoleObservation
  = AwsSesLeaseRoleAbsent
  | AwsSesLeaseRolePresent
  | AwsSesLeaseRoleDrifted ![AwsSesLeaseRoleDrift]
  | AwsSesLeaseRoleUnobservable !AwsSesLeaseRoleError
  deriving (Eq, Show)

data AwsSesLeaseRoleOps m = AwsSesLeaseRoleOps
  { awsSesLeaseRoleObserveOp :: !(m AwsSesLeaseRoleObservation)
  , awsSesLeaseRoleEnsureOp :: !(m (Either AwsSesLeaseRoleError ()))
  , awsSesLeaseRoleDeleteOp :: !(m (Either AwsSesLeaseRoleError ()))
  }

awsSesLeaseRoleOpsWith
  :: (Monad m)
  => (Subprocess -> m (Result ProcessOutput))
  -> FilePath
  -> [(String, String)]
  -> AwsSesLeaseRolePolicyScope
  -> AwsSesLeaseRoleOps m
awsSesLeaseRoleOpsWith runProcess workingDirectory environment scope =
  AwsSesLeaseRoleOps
    { awsSesLeaseRoleObserveOp =
        observeAwsSesLeaseRoleWith
          runProcess
          workingDirectory
          environment
          scope
    , awsSesLeaseRoleEnsureOp =
        ensureAwsSesLeaseRoleWith
          runProcess
          workingDirectory
          environment
          scope
    , awsSesLeaseRoleDeleteOp =
        deleteAwsSesLeaseRoleWith
          runProcess
          workingDirectory
          environment
          scope
    }

productionAwsSesLeaseRoleOps
  :: FilePath
  -> Credentials
  -> AwsSesLeaseRolePolicyScope
  -> AwsSesLeaseRoleOps IO
productionAwsSesLeaseRoleOps workingDirectory credentials scope =
  AwsSesLeaseRoleOps
    { awsSesLeaseRoleObserveOp =
        observeAwsSesLeaseRole workingDirectory credentials scope
    , awsSesLeaseRoleEnsureOp =
        ensureAwsSesLeaseRole workingDirectory credentials scope
    , awsSesLeaseRoleDeleteOp =
        deleteAwsSesLeaseRole workingDirectory credentials scope
    }

observeAwsSesLeaseRoleWith
  :: (Monad m)
  => (Subprocess -> m (Result ProcessOutput))
  -> FilePath
  -> [(String, String)]
  -> AwsSesLeaseRolePolicyScope
  -> m AwsSesLeaseRoleObservation
observeAwsSesLeaseRoleWith runProcess workingDirectory environment scope = do
  roleResult <-
    runProcess
      (awsCommand workingDirectory environment getRoleArguments)
  case classifyAwsSesLeaseRoleCommandResult roleResult of
    Left (AwsSesLeaseRoleNotFound _) -> pure AwsSesLeaseRoleAbsent
    Left failure ->
      pure
        ( AwsSesLeaseRoleUnobservable
            (AwsSesLeaseRoleCommandError failure)
        )
    Right roleOutput ->
      case classifyRolePayload scope roleOutput of
        Left err -> pure (AwsSesLeaseRoleUnobservable err)
        Right roleDrift -> do
          policyResult <-
            runProcess
              (awsCommand workingDirectory environment getRolePolicyArguments)
          pure
            (classifyPolicyPayload scope roleDrift policyResult)

ensureAwsSesLeaseRoleWith
  :: (Monad m)
  => (Subprocess -> m (Result ProcessOutput))
  -> FilePath
  -> [(String, String)]
  -> AwsSesLeaseRolePolicyScope
  -> m (Either AwsSesLeaseRoleError ())
ensureAwsSesLeaseRoleWith runProcess workingDirectory environment scope = do
  initial <-
    observeAwsSesLeaseRoleWith
      runProcess
      workingDirectory
      environment
      scope
  case initial of
    AwsSesLeaseRoleUnobservable err -> pure (Left err)
    AwsSesLeaseRoleAbsent -> do
      createResult <-
        runMutation
          [AwsSesLeaseRoleAlreadyExists ""]
          (createRoleArguments scope)
      configureAfter createResult
    AwsSesLeaseRolePresent -> configureAfter (Right ())
    AwsSesLeaseRoleDrifted _ -> configureAfter (Right ())
 where
  runMutation tolerated arguments = do
    result <-
      runProcess
        (awsCommand workingDirectory environment arguments)
    pure
      ( mutationResult
          tolerated
          (classifyAwsSesLeaseRoleCommandResult result)
      )

  runMutations [] = pure (Right ())
  runMutations (arguments : remaining) = do
    result <- runMutation [] arguments
    case result of
      Left err -> pure (Left err)
      Right () -> runMutations remaining

  configureAfter createResult = case createResult of
    Left err -> pure (Left err)
    Right () -> do
      configureResult <-
        runMutations
          [ updateTrustArguments scope
          , updateMaxSessionArguments
          , putRolePolicyArguments scope
          ]
      case configureResult of
        Left err -> pure (Left err)
        Right () -> confirmPresent

  confirmPresent = do
    final <-
      observeAwsSesLeaseRoleWith
        runProcess
        workingDirectory
        environment
        scope
    pure $ case final of
      AwsSesLeaseRolePresent -> Right ()
      AwsSesLeaseRoleAbsent ->
        Left
          (AwsSesLeaseRolePostconditionFailed "role is absent after ensure")
      AwsSesLeaseRoleDrifted drift ->
        Left
          ( AwsSesLeaseRolePostconditionFailed
              ("role remains drifted after ensure: " <> Text.pack (show drift))
          )
      AwsSesLeaseRoleUnobservable err -> Left err

deleteAwsSesLeaseRoleWith
  :: (Monad m)
  => (Subprocess -> m (Result ProcessOutput))
  -> FilePath
  -> [(String, String)]
  -> AwsSesLeaseRolePolicyScope
  -> m (Either AwsSesLeaseRoleError ())
deleteAwsSesLeaseRoleWith runProcess workingDirectory environment scope = do
  initial <-
    observeAwsSesLeaseRoleWith
      runProcess
      workingDirectory
      environment
      scope
  case initial of
    AwsSesLeaseRoleAbsent -> pure (Right ())
    AwsSesLeaseRoleUnobservable err -> pure (Left err)
    AwsSesLeaseRolePresent -> deleteAndConfirm
    AwsSesLeaseRoleDrifted _ -> deleteAndConfirm
 where
  deleteAndConfirm = do
    policyResult <- runIdempotentDelete deleteRolePolicyArguments
    case policyResult of
      Left err -> pure (Left err)
      Right () -> do
        roleResult <- runIdempotentDelete deleteRoleArguments
        case roleResult of
          Left err -> pure (Left err)
          Right () -> confirmAbsent

  runIdempotentDelete arguments = do
    result <-
      runProcess
        (awsCommand workingDirectory environment arguments)
    pure
      ( mutationResult
          [AwsSesLeaseRoleNotFound ""]
          (classifyAwsSesLeaseRoleCommandResult result)
      )

  confirmAbsent = do
    final <-
      observeAwsSesLeaseRoleWith
        runProcess
        workingDirectory
        environment
        scope
    pure $ case final of
      AwsSesLeaseRoleAbsent -> Right ()
      AwsSesLeaseRolePresent ->
        Left
          (AwsSesLeaseRolePostconditionFailed "role remains present after delete")
      AwsSesLeaseRoleDrifted _ ->
        Left
          (AwsSesLeaseRolePostconditionFailed "role remains present after delete")
      AwsSesLeaseRoleUnobservable err -> Left err

observeAwsSesLeaseRole
  :: FilePath
  -> Credentials
  -> AwsSesLeaseRolePolicyScope
  -> IO AwsSesLeaseRoleObservation
observeAwsSesLeaseRole workingDirectory credentials scope = do
  environment <- awsCliSubprocessEnvironment credentials
  observeAwsSesLeaseRoleWith
    captureSubprocessResult
    workingDirectory
    environment
    scope

ensureAwsSesLeaseRole
  :: FilePath
  -> Credentials
  -> AwsSesLeaseRolePolicyScope
  -> IO (Either AwsSesLeaseRoleError ())
ensureAwsSesLeaseRole workingDirectory credentials scope = do
  environment <- awsCliSubprocessEnvironment credentials
  ensureAwsSesLeaseRoleWith
    captureSubprocessResult
    workingDirectory
    environment
    scope

deleteAwsSesLeaseRole
  :: FilePath
  -> Credentials
  -> AwsSesLeaseRolePolicyScope
  -> IO (Either AwsSesLeaseRoleError ())
deleteAwsSesLeaseRole workingDirectory credentials scope = do
  environment <- awsCliSubprocessEnvironment credentials
  deleteAwsSesLeaseRoleWith
    captureSubprocessResult
    workingDirectory
    environment
    scope

classifyAwsSesLeaseRoleCommandResult
  :: Result ProcessOutput
  -> Either AwsSesLeaseRoleCommandFailure String
classifyAwsSesLeaseRoleCommandResult result = case result of
  Failure detail ->
    Left (AwsSesLeaseRoleProcessStartFailure (Text.pack detail))
  Success output -> case processExitCode output of
    ExitSuccess -> Right (processStdout output)
    ExitFailure _ -> Left (classifyCommandFailure (renderProcessDetail output))

classifyRolePayload
  :: AwsSesLeaseRolePolicyScope
  -> String
  -> Either AwsSesLeaseRoleError [AwsSesLeaseRoleDrift]
classifyRolePayload scope output = do
  response <-
    mapLeft
      ( AwsSesLeaseRoleMalformedResponse
          . Text.pack
          . ("invalid iam get-role response: " ++)
      )
      (eitherDecode (BL8.pack output))
  let expectedArn = roleArnFor (internalAwsSesLeaseRoleAccountId scope)
  if getRoleResponseName response /= awsSesLeaseRoleName
    then
      Left
        ( AwsSesLeaseRoleUnexpectedResponse
            ( "iam get-role returned unexpected role name "
                <> getRoleResponseName response
            )
        )
    else
      if getRoleResponseArn response /= expectedArn
        then
          Left
            ( AwsSesLeaseRoleUnexpectedResponse
                ( "iam get-role returned unexpected role ARN "
                    <> getRoleResponseArn response
                )
            )
        else
          Right
            ( [ AwsSesLeaseRoleTrustPolicyDrift
              | getRoleResponseTrustPolicy response
                  /= trustPolicyFor (internalAwsSesLeaseRoleAccountId scope)
              ]
                ++ [ AwsSesLeaseRoleMaxSessionDurationDrift
                       (getRoleResponseMaxSessionDuration response)
                   | getRoleResponseMaxSessionDuration response
                       /= awsSesLeaseRoleMaxSessionDurationSeconds
                   ]
            )

classifyPolicyPayload
  :: AwsSesLeaseRolePolicyScope
  -> [AwsSesLeaseRoleDrift]
  -> Result ProcessOutput
  -> AwsSesLeaseRoleObservation
classifyPolicyPayload scope roleDrift result =
  case classifyAwsSesLeaseRoleCommandResult result of
    Left (AwsSesLeaseRoleNotFound _) ->
      driftObservation
        (roleDrift ++ [AwsSesLeaseRoleInlinePolicyMissing])
    Left failure ->
      AwsSesLeaseRoleUnobservable (AwsSesLeaseRoleCommandError failure)
    Right output ->
      case eitherDecode (BL8.pack output) of
        Left err ->
          AwsSesLeaseRoleUnobservable
            ( AwsSesLeaseRoleMalformedResponse
                (Text.pack ("invalid iam get-role-policy response: " ++ err))
            )
        Right response
          | getRolePolicyResponseRoleName response /= awsSesLeaseRoleName ->
              AwsSesLeaseRoleUnobservable
                ( AwsSesLeaseRoleUnexpectedResponse
                    ( "iam get-role-policy returned unexpected role name "
                        <> getRolePolicyResponseRoleName response
                    )
                )
          | getRolePolicyResponsePolicyName response
              /= awsSesLeaseRoleInlinePolicyName ->
              AwsSesLeaseRoleUnobservable
                ( AwsSesLeaseRoleUnexpectedResponse
                    ( "iam get-role-policy returned unexpected policy name "
                        <> getRolePolicyResponsePolicyName response
                    )
                )
          | otherwise ->
              driftObservation
                ( roleDrift
                    ++ [ AwsSesLeaseRoleInlinePolicyDrift
                       | getRolePolicyResponseDocument response
                           /= awsSesLeaseRoleInlinePolicy scope
                       ]
                )

mutationResult
  :: [AwsSesLeaseRoleCommandFailure]
  -> Either AwsSesLeaseRoleCommandFailure String
  -> Either AwsSesLeaseRoleError ()
mutationResult tolerated result = case result of
  Right _ -> Right ()
  Left failure
    | any (sameFailureClass failure) tolerated -> Right ()
    | otherwise -> Left (AwsSesLeaseRoleCommandError failure)

sameFailureClass
  :: AwsSesLeaseRoleCommandFailure
  -> AwsSesLeaseRoleCommandFailure
  -> Bool
sameFailureClass left right = case (left, right) of
  (AwsSesLeaseRoleNotFound _, AwsSesLeaseRoleNotFound _) -> True
  (AwsSesLeaseRoleAlreadyExists _, AwsSesLeaseRoleAlreadyExists _) -> True
  _ -> False

driftObservation :: [AwsSesLeaseRoleDrift] -> AwsSesLeaseRoleObservation
driftObservation drift = case drift of
  [] -> AwsSesLeaseRolePresent
  _ -> AwsSesLeaseRoleDrifted drift

data GetRoleResponse = GetRoleResponse
  { getRoleResponseName :: !Text
  , getRoleResponseArn :: !Text
  , getRoleResponseTrustPolicy :: !Value
  , getRoleResponseMaxSessionDuration :: !Natural
  }

instance FromJSON GetRoleResponse where
  parseJSON =
    withObject "GetRoleResponse" $ \root -> do
      role <- root .: "Role"
      withObject
        "Role"
        ( \entry ->
            GetRoleResponse
              <$> entry .: "RoleName"
              <*> entry .: "Arn"
              <*> entry .: "AssumeRolePolicyDocument"
              <*> entry .: "MaxSessionDuration"
        )
        role

data GetRolePolicyResponse = GetRolePolicyResponse
  { getRolePolicyResponseRoleName :: !Text
  , getRolePolicyResponsePolicyName :: !Text
  , getRolePolicyResponseDocument :: !Value
  }

instance FromJSON GetRolePolicyResponse where
  parseJSON =
    withObject "GetRolePolicyResponse" $ \root ->
      GetRolePolicyResponse
        <$> root .: "RoleName"
        <*> root .: "PolicyName"
        <*> root .: "PolicyDocument"

trustPolicyFor :: Text -> Value
trustPolicyFor accountId =
  object
    [ "Version" .= ("2012-10-17" :: Text)
    , "Statement"
        .= [ object
               [ "Sid" .= ("OperationalUserTrust" :: Text)
               , "Effect" .= ("Allow" :: Text)
               , "Principal"
                   .= object
                     [ "AWS" .= operationalUserArnFor accountId
                     ]
               , "Action" .= ("sts:AssumeRole" :: Text)
               ]
           ]
    ]

roleArnFor :: Text -> Text
roleArnFor accountId =
  "arn:aws:iam::" <> accountId <> ":role/" <> awsSesLeaseRoleName

operationalUserArnFor :: Text -> Text
operationalUserArnFor accountId =
  "arn:aws:iam::"
    <> accountId
    <> ":user/"
    <> awsSesLeaseOperationalUserName

allow :: Text -> [Text] -> Text -> Value
allow sid actions resource =
  object
    [ "Sid" .= sid
    , "Effect" .= ("Allow" :: Text)
    , "Action" .= actions
    , "Resource" .= resource
    ]

bucketPolicyStatements :: Text -> Text -> [Value]
bucketPolicyStatements label bucket =
  [ allow
      (label <> "BucketLifecycle")
      s3BucketLifecycleActions
      bucketArn
  , allow
      (label <> "ObjectLifecycle")
      s3ObjectLifecycleActions
      (bucketArn <> "/*")
  ]
 where
  bucketArn = "arn:aws:s3:::" <> bucket

sesLifecycleActions :: [Text]
sesLifecycleActions =
  [ "ses:CreateReceiptRule"
  , "ses:CreateReceiptRuleSet"
  , "ses:DeleteIdentity"
  , "ses:DeleteReceiptRule"
  , "ses:DeleteReceiptRuleSet"
  , "ses:DescribeActiveReceiptRuleSet"
  , "ses:DescribeReceiptRule"
  , "ses:DescribeReceiptRuleSet"
  , "ses:GetEmailIdentity"
  , "ses:GetIdentityDkimAttributes"
  , "ses:GetIdentityVerificationAttributes"
  , "ses:ListIdentities"
  , "ses:ListReceiptRuleSets"
  , "ses:SetActiveReceiptRuleSet"
  , "ses:SetIdentityDkimEnabled"
  , "ses:UpdateReceiptRule"
  , "ses:VerifyDomainDkim"
  , "ses:VerifyDomainIdentity"
  ]

smtpIamUserLifecycleActions :: [Text]
smtpIamUserLifecycleActions =
  [ "iam:CreateAccessKey"
  , "iam:CreateUser"
  , "iam:DeleteAccessKey"
  , "iam:DeleteUser"
  , "iam:DeleteUserPolicy"
  , "iam:GetUser"
  , "iam:GetUserPolicy"
  , "iam:ListAccessKeys"
  , "iam:ListUserPolicies"
  , "iam:ListUserTags"
  , "iam:PutUserPolicy"
  , "iam:TagUser"
  , "iam:UntagUser"
  , "iam:UpdateAccessKey"
  , "iam:UpdateUser"
  ]

s3BucketLifecycleActions :: [Text]
s3BucketLifecycleActions =
  [ "s3:CreateBucket"
  , "s3:DeleteBucket"
  , "s3:DeleteBucketPolicy"
  , "s3:DeleteBucketWebsite"
  , "s3:GetAccelerateConfiguration"
  , "s3:GetBucketAcl"
  , "s3:GetBucketCORS"
  , "s3:GetBucketLocation"
  , "s3:GetBucketLogging"
  , "s3:GetBucketObjectLockConfiguration"
  , "s3:GetBucketOwnershipControls"
  , "s3:GetBucketPolicy"
  , "s3:GetBucketPublicAccessBlock"
  , "s3:GetBucketRequestPayment"
  , "s3:GetBucketTagging"
  , "s3:GetBucketVersioning"
  , "s3:GetBucketWebsite"
  , "s3:GetEncryptionConfiguration"
  , "s3:GetLifecycleConfiguration"
  , "s3:GetReplicationConfiguration"
  , "s3:ListBucket"
  , "s3:ListBucketMultipartUploads"
  , "s3:ListBucketVersions"
  , "s3:PutAccelerateConfiguration"
  , "s3:PutBucketAcl"
  , "s3:PutBucketCORS"
  , "s3:PutBucketLogging"
  , "s3:PutBucketObjectLockConfiguration"
  , "s3:PutBucketOwnershipControls"
  , "s3:PutBucketPolicy"
  , "s3:PutBucketPublicAccessBlock"
  , "s3:PutBucketRequestPayment"
  , "s3:PutBucketTagging"
  , "s3:PutBucketVersioning"
  , "s3:PutBucketWebsite"
  , "s3:PutEncryptionConfiguration"
  , "s3:PutLifecycleConfiguration"
  , "s3:PutReplicationConfiguration"
  ]

s3ObjectLifecycleActions :: [Text]
s3ObjectLifecycleActions =
  [ "s3:AbortMultipartUpload"
  , "s3:DeleteObject"
  , "s3:DeleteObjectVersion"
  , "s3:GetObject"
  , "s3:GetObjectVersion"
  , "s3:ListMultipartUploadParts"
  , "s3:PutObject"
  ]

awsCommand
  :: FilePath -> [(String, String)] -> [String] -> Subprocess
awsCommand workingDirectory environment arguments =
  Subprocess
    { subprocessPath = "aws"
    , subprocessArguments = arguments
    , subprocessEnvironment = Just environment
    , subprocessWorkingDirectory = Just workingDirectory
    }

getRoleArguments :: [String]
getRoleArguments =
  [ "iam"
  , "get-role"
  , "--role-name"
  , Text.unpack awsSesLeaseRoleName
  , "--output"
  , "json"
  ]

getRolePolicyArguments :: [String]
getRolePolicyArguments =
  [ "iam"
  , "get-role-policy"
  , "--role-name"
  , Text.unpack awsSesLeaseRoleName
  , "--policy-name"
  , Text.unpack awsSesLeaseRoleInlinePolicyName
  , "--output"
  , "json"
  ]

createRoleArguments :: AwsSesLeaseRolePolicyScope -> [String]
createRoleArguments scope =
  [ "iam"
  , "create-role"
  , "--role-name"
  , Text.unpack awsSesLeaseRoleName
  , "--assume-role-policy-document"
  , renderJson (trustPolicyFor (internalAwsSesLeaseRoleAccountId scope))
  , "--max-session-duration"
  , show awsSesLeaseRoleMaxSessionDurationSeconds
  , "--output"
  , "json"
  ]

updateTrustArguments :: AwsSesLeaseRolePolicyScope -> [String]
updateTrustArguments scope =
  [ "iam"
  , "update-assume-role-policy"
  , "--role-name"
  , Text.unpack awsSesLeaseRoleName
  , "--policy-document"
  , renderJson (trustPolicyFor (internalAwsSesLeaseRoleAccountId scope))
  ]

updateMaxSessionArguments :: [String]
updateMaxSessionArguments =
  [ "iam"
  , "update-role"
  , "--role-name"
  , Text.unpack awsSesLeaseRoleName
  , "--max-session-duration"
  , show awsSesLeaseRoleMaxSessionDurationSeconds
  ]

putRolePolicyArguments :: AwsSesLeaseRolePolicyScope -> [String]
putRolePolicyArguments scope =
  [ "iam"
  , "put-role-policy"
  , "--role-name"
  , Text.unpack awsSesLeaseRoleName
  , "--policy-name"
  , Text.unpack awsSesLeaseRoleInlinePolicyName
  , "--policy-document"
  , renderJson (awsSesLeaseRoleInlinePolicy scope)
  ]

deleteRolePolicyArguments :: [String]
deleteRolePolicyArguments =
  [ "iam"
  , "delete-role-policy"
  , "--role-name"
  , Text.unpack awsSesLeaseRoleName
  , "--policy-name"
  , Text.unpack awsSesLeaseRoleInlinePolicyName
  ]

deleteRoleArguments :: [String]
deleteRoleArguments =
  [ "iam"
  , "delete-role"
  , "--role-name"
  , Text.unpack awsSesLeaseRoleName
  ]

renderJson :: Value -> String
renderJson = BL8.unpack . encode

classifyCommandFailure :: String -> AwsSesLeaseRoleCommandFailure
classifyCommandFailure detail
  | awsErrorCodeIs "nosuchentity" normalized = AwsSesLeaseRoleNotFound rendered
  | awsErrorCodeIs "entityalreadyexists" normalized =
      AwsSesLeaseRoleAlreadyExists rendered
  | awsErrorCodeIs "accessdenied" normalized
      || awsErrorCodeIs "accessdeniedexception" normalized
      || awsErrorCodeIs "unauthorizedoperation" normalized =
      AwsSesLeaseRoleAccessDenied rendered
  | any (`Text.isInfixOf` normalized) networkMarkers =
      AwsSesLeaseRoleNetworkFailure rendered
  | otherwise = AwsSesLeaseRoleOtherCommandFailure rendered
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

renderProcessDetail :: ProcessOutput -> String
renderProcessDetail output =
  case filter (not . null) [trim (processStderr output), trim (processStdout output)] of
    [] -> "subprocess exited without output"
    messages -> foldr1 (\left right -> left ++ " | " ++ right) messages

trim :: String -> String
trim = reverse . dropWhile (`elem` ['\n', '\r', ' ']) . reverse

validateAccountId :: Text -> Either AwsSesLeaseRoleValueError Text
validateAccountId raw
  | Text.length value == 12 && Text.all isAsciiDigit value = Right value
  | otherwise = Left (AwsSesLeaseRoleAccountIdMustBeTwelveDigits value)
 where
  value = Text.strip raw

validateHostedZoneId :: Text -> Either AwsSesLeaseRoleValueError Text
validateHostedZoneId raw
  | Text.null value || Text.any (not . safe) value =
      Left (AwsSesLeaseRoleHostedZoneIdInvalid value)
  | otherwise = Right value
 where
  stripped = Text.strip raw
  value = fromMaybe stripped (Text.stripPrefix "/hostedzone/" stripped)
  safe character =
    isAsciiUpper character
      || isAsciiLower character
      || isAsciiDigit character

validateBucketName :: Text -> Either () Text
validateBucketName raw
  | Text.length value < 3 || Text.length value > 63 = Left ()
  | Text.any (not . safe) value = Left ()
  | not (validEdges value) = Left ()
  | any (`Text.isInfixOf` value) ["..", ".-", "-."] = Left ()
  | looksLikeIpv4Address value = Left ()
  | otherwise = Right value
 where
  value = Text.strip raw
  safe character =
    isAsciiLower character
      || isAsciiDigit character
      || character == '.'
      || character == '-'

validEdges :: Text -> Bool
validEdges value = case (Text.uncons value, Text.unsnoc value) of
  (Just (firstCharacter, _), Just (_, lastCharacter)) ->
    (isAsciiLower firstCharacter || isAsciiDigit firstCharacter)
      && (isAsciiLower lastCharacter || isAsciiDigit lastCharacter)
  _ -> False

looksLikeIpv4Address :: Text -> Bool
looksLikeIpv4Address value = case traverse parseOctet (Text.splitOn "." value) of
  Just [_, _, _, _] -> True
  _ -> False

parseOctet :: Text -> Maybe Natural
parseOctet value
  | Text.null value || Text.length value > 3 = Nothing
  | Text.any (not . isAsciiDigit) value = Nothing
  | otherwise =
      let parsed =
            Text.foldl'
              (\accumulator character -> accumulator * 10 + digitValue character)
              0
              value
       in if parsed <= 255 then Just parsed else Nothing

isAsciiDigit :: Char -> Bool
isAsciiDigit character = character >= '0' && character <= '9'

digitValue :: Char -> Natural
digitValue character = case character of
  '0' -> 0
  '1' -> 1
  '2' -> 2
  '3' -> 3
  '4' -> 4
  '5' -> 5
  '6' -> 6
  '7' -> 7
  '8' -> 8
  '9' -> 9
  _ -> 0

mapLeft :: (left -> mapped) -> Either left right -> Either mapped right
mapLeft transform result = case result of
  Left err -> Left (transform err)
  Right value -> Right value
