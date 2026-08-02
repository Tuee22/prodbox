{-# LANGUAGE OverloadedStrings #-}

-- | Production AWS boundary for the one-shot Credential Provisioner.
--
-- Programs are constructed only through one constructor per registered
-- credential class.  There is no arbitrary principal, policy document, AWS
-- action, or resource constructor.  Admin credentials remain inside an
-- opaque native-client session and are never converted to a subprocess
-- environment.
module Prodbox.Lifecycle.CredentialProvisioner.ProductionIam
  ( CredentialIamProgram
  , credentialIamProgramClass
  , credentialIamProgramRegion
  , credentialIamProgramPrincipal
  , credentialIamProgramPolicyName
  , credentialIamProgramPolicyDocument
  , credentialIamProgramRoleName
  , credentialIamProgramRoleTrustPolicy
  , credentialIamProgramRolePolicyDocument
  , mkLifecycleProviderIamProgram
  , mkAuthorityBackupIamProgram
  , mkTlsRetentionIamProgram
  , mkGatewayDnsIamProgram
  , mkHomeDns01IamProgram
  , mkAwsRunDns01IamProgram
  , mkSesSmtpIamProgram
  , ProductionIamSession
  , ProductionIamError (..)
  , openProductionIamSession
  , openProductionIamSessionWithSender
  , ensureProductionIamPrerequisites
  , observeProductionAccessKeyInventory
  , deleteProductionAccessKey
  , createProductionAccessKey
  , destroyProductionIamIdentity
  , observeProductionIamIdentityAbsent
  , waitProductionIamVisibilityGrace
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (unless)
import Data.Aeson
  ( Value
  , eitherDecodeStrict'
  , encode
  , object
  , (.=)
  )
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8, decodeUtf8', encodeUtf8)
import Prodbox.Aws.CredentialHandle
  ( CredentialError
  , baseCredentialHandleFromSettings
  , unSecret
  )
import Prodbox.Aws.Native.Iam
  ( AccessKeyMetadata (accessKeyMetadataId)
  , CreateAccessKeyResult (..)
  , CreateUserResult (createUserName)
  , IamClient (..)
  , IamRoleObservation (..)
  , IamRolePolicyObservation (..)
  , IamTag (..)
  , IamUserObservation (..)
  , IamUserPolicyObservation (..)
  , newIamClient
  )
import Prodbox.Aws.Native.S3
  ( S3BucketObservation (..)
  , S3Client (..)
  , expectedLongLivedBucketHardening
  , newS3Client
  )
import Prodbox.Aws.Native.Wire
  ( AwsClientError (..)
  , AwsServiceFault (awsFaultCode)
  , NativeAwsSender
  , httpSend
  )
import Prodbox.Infra.DedicatedAdapterIam
  ( validateDedicatedBucket
  , validateDedicatedPrefix
  )
import Prodbox.Lifecycle.CredentialProvisioner.Execution
  ( AccessKeyInventoryObservation (..)
  , AwsAccessKeyCreateResult (..)
  , ProvisionedAccessKeyId
  , mkProvisionedAccessKeyId
  , observedAccessKeyInventory
  , provisionedAccessKeyIdText
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass (..)
  , AwsCredentialDescriptor (..)
  , awsCredentialDescriptor
  )
import Prodbox.Lifecycle.CredentialProvisioner.TargetMaterial
  ( CreatedAwsAccessKey
  , TargetMaterialValueError
  , mkCreatedAwsAccessKey
  )
import Prodbox.Settings (Credentials (region))

data CredentialIamProgram = CredentialIamProgram
  { internalCredentialIamDescriptor :: !AwsCredentialDescriptor
  , internalCredentialIamRegion :: !Text
  , internalCredentialIamPolicyDocument :: !Text
  , internalCredentialIamBucket :: !(Maybe ProgramBucket)
  , internalCredentialIamRole :: !(Maybe ProgramRole)
  }
  deriving (Eq, Show)

data ProgramBucket
  = CreateAndHardenBucket !Text
  | RequireHardenedBucket !Text
  deriving (Eq, Show)

data ProgramRole = ProgramRole
  { programRoleName :: !Text
  , programRoleArn :: !Text
  , programRolePolicyName :: !Text
  , programRoleTrustPolicy :: !Text
  , programRolePermissionsPolicy :: !Text
  }
  deriving (Eq, Show)

credentialIamProgramClass :: CredentialIamProgram -> AwsCredentialClass
credentialIamProgramClass =
  awsCredentialDescriptorClass . internalCredentialIamDescriptor

credentialIamProgramRegion :: CredentialIamProgram -> Text
credentialIamProgramRegion = internalCredentialIamRegion

credentialIamProgramPrincipal :: CredentialIamProgram -> Text
credentialIamProgramPrincipal =
  awsCredentialDescriptorPrincipal . internalCredentialIamDescriptor

credentialIamProgramPolicyName :: CredentialIamProgram -> Text
credentialIamProgramPolicyName =
  awsCredentialDescriptorPolicy . internalCredentialIamDescriptor

credentialIamProgramPolicyDocument :: CredentialIamProgram -> Text
credentialIamProgramPolicyDocument = internalCredentialIamPolicyDocument

credentialIamProgramRoleName :: CredentialIamProgram -> Maybe Text
credentialIamProgramRoleName = fmap programRoleName . internalCredentialIamRole

credentialIamProgramRoleTrustPolicy :: CredentialIamProgram -> Maybe Text
credentialIamProgramRoleTrustPolicy = fmap programRoleTrustPolicy . internalCredentialIamRole

credentialIamProgramRolePolicyDocument :: CredentialIamProgram -> Maybe Text
credentialIamProgramRolePolicyDocument = fmap programRolePermissionsPolicy . internalCredentialIamRole

mkLifecycleProviderIamProgram
  :: Text -> Text -> Text -> Either ProductionIamError CredentialIamProgram
mkLifecycleProviderIamProgram rawRegion rawAccountId rawRoleName = do
  regionValue <- validateRegion rawRegion
  accountId <- validateAccountId rawAccountId
  roleName <- validateIamName "provider role" rawRoleName
  iamProgram <-
    program
      LifecycleProviderCredential
      regionValue
      ( statementPolicy
          [ statement
              "AssumeRegisteredProviderRole"
              ["sts:AssumeRole"]
              ["arn:aws:iam::" <> accountId <> ":role/" <> roleName]
          ]
      )
      Nothing
  let principal = credentialIamProgramPrincipal iamProgram
      trustPolicy =
        statementPolicy
          [ object
              [ "Sid" .= ("TrustLifecycleProviderIdentity" :: Text)
              , "Effect" .= ("Allow" :: Text)
              , "Principal"
                  .= object
                    [ "AWS"
                        .= ("arn:aws:iam::" <> accountId <> ":user/" <> principal)
                    ]
              , "Action" .= (["sts:AssumeRole"] :: [Text])
              ]
          ]
  pure
    iamProgram
      { internalCredentialIamRole =
          Just
            ProgramRole
              { programRoleName = roleName
              , programRoleArn = "arn:aws:iam::" <> accountId <> ":role/" <> roleName
              , programRolePolicyName = "prodbox-lifecycle-provider-runtime"
              , programRoleTrustPolicy = renderPolicy trustPolicy
              , programRolePermissionsPolicy = renderPolicy lifecycleProviderRolePolicy
              }
      }

mkAuthorityBackupIamProgram
  :: Text -> Text -> [Text] -> Either ProductionIamError CredentialIamProgram
mkAuthorityBackupIamProgram rawRegion rawBucket rawPrefixes = do
  regionValue <- validateRegion rawRegion
  bucket <- validateBucket rawBucket
  prefixes <- validatePrefixes "authority-backup-store/" rawPrefixes
  program
    AuthorityBackupStoreCredential
    regionValue
    (s3AdapterPolicy bucket prefixes)
    (Just (CreateAndHardenBucket bucket))

mkTlsRetentionIamProgram
  :: Text -> Text -> [Text] -> Either ProductionIamError CredentialIamProgram
mkTlsRetentionIamProgram rawRegion rawBucket rawPrefixes = do
  regionValue <- validateRegion rawRegion
  bucket <- validateBucket rawBucket
  prefixes <- validatePrefixes "public-edge-tls/" rawPrefixes
  program
    TlsRetentionStoreCredential
    regionValue
    (s3AdapterPolicy bucket prefixes)
    (Just (RequireHardenedBucket bucket))

mkGatewayDnsIamProgram
  :: Text -> Text -> Either ProductionIamError CredentialIamProgram
mkGatewayDnsIamProgram rawRegion rawZoneId = do
  regionValue <- validateRegion rawRegion
  zoneId <- validateHostedZoneId rawZoneId
  program
    GatewayDnsCredential
    regionValue
    (route53Policy "ChangeRegisteredGatewayRecord" zoneId)
    Nothing

mkHomeDns01IamProgram
  :: Text -> Text -> Either ProductionIamError CredentialIamProgram
mkHomeDns01IamProgram rawRegion rawZoneId = do
  regionValue <- validateRegion rawRegion
  zoneId <- validateHostedZoneId rawZoneId
  program
    HomeCertManagerDns01Credential
    regionValue
    (route53Policy "ChangeHomeDns01TxtRecords" zoneId)
    Nothing

mkAwsRunDns01IamProgram
  :: Text -> Text -> Either ProductionIamError CredentialIamProgram
mkAwsRunDns01IamProgram rawRegion rawZoneId = do
  regionValue <- validateRegion rawRegion
  zoneId <- validateHostedZoneId rawZoneId
  program
    AwsRunCertManagerDns01Credential
    regionValue
    (route53Policy "ChangeAwsRunDns01TxtRecords" zoneId)
    Nothing

mkSesSmtpIamProgram
  :: Text -> Text -> Text -> Either ProductionIamError CredentialIamProgram
mkSesSmtpIamProgram rawRegion rawAccountId rawIdentity = do
  regionValue <- validateRegion rawRegion
  accountId <- validateAccountId rawAccountId
  identity <- validateSesIdentity rawIdentity
  program
    SesSmtpRetainedCustodyCredential
    regionValue
    ( statementPolicy
        [ statement
            "SendFromRegisteredSesIdentity"
            ["ses:SendEmail", "ses:SendRawEmail"]
            [ "arn:aws:ses:"
                <> regionValue
                <> ":"
                <> accountId
                <> ":identity/"
                <> identity
            ]
        ]
    )
    Nothing

program
  :: AwsCredentialClass
  -> Text
  -> Value
  -> Maybe ProgramBucket
  -> Either ProductionIamError CredentialIamProgram
program credentialClass regionValue policy bucket =
  Right
    CredentialIamProgram
      { internalCredentialIamDescriptor = awsCredentialDescriptor credentialClass
      , internalCredentialIamRegion = regionValue
      , internalCredentialIamPolicyDocument = renderPolicy policy
      , internalCredentialIamBucket = bucket
      , internalCredentialIamRole = Nothing
      }

data ProductionIamSession = ProductionIamSession
  { productionIamProgram :: !CredentialIamProgram
  , productionIamClient :: !IamClient
  , productionS3Client :: !S3Client
  }

data ProductionIamError
  = ProductionIamFieldInvalid !Text
  | ProductionIamCredentialInvalid !CredentialError
  | ProductionIamCredentialRegionMismatch !Text !Text
  | ProductionIamAwsFailed !Text !AwsClientError
  | ProductionIamUserReadBackMismatch !Text
  | ProductionIamPolicyReadBackMismatch
  | ProductionIamTagReadBackMismatch ![IamTag]
  | ProductionIamBucketReadBackMismatch
  | ProductionIamRoleReadBackMismatch !Text
  | ProductionIamRolePolicyReadBackMismatch
  | ProductionIamAccessKeyInvalid !Text
  | ProductionIamMaterialInvalid !TargetMaterialValueError
  deriving (Eq, Show)

openProductionIamSession
  :: CredentialIamProgram
  -> Credentials
  -> Either ProductionIamError ProductionIamSession
openProductionIamSession iamProgram credentials =
  openProductionIamSessionWithSender iamProgram credentials httpSend

-- | Injected native sender seam used by deterministic protocol tests.  The
-- production constructor above always selects the process-wide native TLS
-- sender.
openProductionIamSessionWithSender
  :: CredentialIamProgram
  -> Credentials
  -> NativeAwsSender
  -> Either ProductionIamError ProductionIamSession
openProductionIamSessionWithSender iamProgram credentials sender = do
  let actualRegion = Text.strip (region credentials)
      expectedRegion = credentialIamProgramRegion iamProgram
  unless
    (actualRegion == expectedRegion)
    (Left (ProductionIamCredentialRegionMismatch expectedRegion actualRegion))
  handle <-
    either
      (Left . ProductionIamCredentialInvalid)
      Right
      (baseCredentialHandleFromSettings credentials)
  Right
    ProductionIamSession
      { productionIamProgram = iamProgram
      , productionIamClient = newIamClient handle sender
      , productionS3Client = newS3Client handle sender
      }

ensureProductionIamPrerequisites
  :: ProductionIamSession -> IO (Either ProductionIamError ())
ensureProductionIamPrerequisites session = do
  bucketResult <- ensureProgramBucket session
  case bucketResult of
    Left err -> pure (Left err)
    Right () -> do
      userResult <- ensureUserPolicyAndTags session
      case userResult of
        Left err -> pure (Left err)
        Right () -> ensureProgramRole session

ensureProgramRole :: ProductionIamSession -> IO (Either ProductionIamError ())
ensureProgramRole session = case internalCredentialIamRole (productionIamProgram session) of
  Nothing -> pure (Right ())
  Just role -> do
    roleResult <- ensureRole role
    case roleResult of
      Left err -> pure (Left err)
      Right () -> ensureRolePolicy role
 where
  client = productionIamClient session
  ensureRole role = do
    observed <- observeRole client (programRoleName role)
    case observed of
      Left err -> pure (Left (awsFailure "observe Lifecycle-provider role" err))
      Right IamRoleAbsent -> do
        created <-
          createRole client (programRoleName role) (programRoleTrustPolicy role)
        case created of
          Left err
            | not (isEntityAlreadyExists err) ->
                pure (Left (awsFailure "create Lifecycle-provider role" err))
          _ -> reconcileTrust role
      Right IamRolePresent {} -> reconcileTrust role
  reconcileTrust role = do
    updated <-
      updateAssumeRolePolicy
        client
        (programRoleName role)
        (programRoleTrustPolicy role)
    case updated of
      Left err -> pure (Left (awsFailure "update Lifecycle-provider trust policy" err))
      Right () -> do
        observed <- observeRole client (programRoleName role)
        pure $ case observed of
          Left err -> Left (awsFailure "read back Lifecycle-provider role" err)
          Right IamRoleAbsent ->
            Left (ProductionIamRoleReadBackMismatch "role remained absent")
          Right present@IamRolePresent {}
            | iamRoleName present /= programRoleName role ->
                Left (ProductionIamRoleReadBackMismatch "role name mismatched")
            | iamRoleArn present /= programRoleArn role ->
                Left (ProductionIamRoleReadBackMismatch "role ARN mismatched")
            | not
                ( policiesEqual
                    (iamRoleAssumePolicyDocument present)
                    (programRoleTrustPolicy role)
                ) ->
                Left (ProductionIamRoleReadBackMismatch "trust policy mismatched")
            | otherwise -> Right ()
  ensureRolePolicy role = do
    installed <-
      putRoleInlinePolicy
        client
        (programRoleName role)
        (programRolePolicyName role)
        (programRolePermissionsPolicy role)
    case installed of
      Left err -> pure (Left (awsFailure "install Lifecycle-provider role policy" err))
      Right () -> do
        observed <-
          observeRoleInlinePolicy
            client
            (programRoleName role)
            (programRolePolicyName role)
        pure $ case observed of
          Left err -> Left (awsFailure "read back Lifecycle-provider role policy" err)
          Right IamRolePolicyAbsent -> Left ProductionIamRolePolicyReadBackMismatch
          Right (IamRolePolicyPresent actual)
            | policiesEqual actual (programRolePermissionsPolicy role) -> Right ()
            | otherwise -> Left ProductionIamRolePolicyReadBackMismatch

observeProductionAccessKeyInventory
  :: ProductionIamSession -> IO AccessKeyInventoryObservation
observeProductionAccessKeyInventory session = do
  result <-
    listAccessKeys
      (productionIamClient session)
      (credentialIamProgramPrincipal (productionIamProgram session))
  pure $ case result of
    Left err -> AccessKeyInventoryUnobservable (renderAwsError err)
    Right metadata ->
      case traverse toProvisionedKey metadata of
        Left detail -> AccessKeyInventoryUnobservable detail
        Right keys -> observedAccessKeyInventory keys
 where
  toProvisionedKey metadata =
    either
      (const (Left "IAM returned an invalid access-key identifier"))
      Right
      (mkProvisionedAccessKeyId (accessKeyMetadataId metadata))

deleteProductionAccessKey
  :: ProductionIamSession
  -> ProvisionedAccessKeyId
  -> IO (Either Text ())
deleteProductionAccessKey session keyId = do
  result <-
    deleteAccessKey
      (productionIamClient session)
      (credentialIamProgramPrincipal (productionIamProgram session))
      (provisionedAccessKeyIdText keyId)
  pure (either (Left . renderAwsError) Right result)

createProductionAccessKey
  :: ProductionIamSession -> IO AwsAccessKeyCreateResult
createProductionAccessKey session = do
  result <-
    createAccessKey
      (productionIamClient session)
      (credentialIamProgramPrincipal (productionIamProgram session))
  pure $ case result of
    Left (AwsAmbiguousOutcome _) -> AwsAccessKeyCreateResponseLost
    Left err -> AwsAccessKeyCreateFailed (renderAwsError err)
    Right created
      | createdAccessKeyUser created
          /= credentialIamProgramPrincipal (productionIamProgram session) ->
          AwsAccessKeyCreateFailed "IAM create-access-key user read-back mismatched the program"
      | otherwise ->
          case createdMaterial created of
            Left detail -> AwsAccessKeyCreateFailed detail
            Right material -> case mkProvisionedAccessKeyId (createdAccessKeyId created) of
              Left _ -> AwsAccessKeyCreateFailed "IAM returned an invalid access-key identifier"
              Right keyId -> AwsAccessKeyCreated keyId material

destroyProductionIamIdentity
  :: ProductionIamSession -> IO (Either ProductionIamError ())
destroyProductionIamIdentity session = do
  inventory <- listAccessKeys client principal
  case inventory of
    Left err -> pure (Left (awsFailure "list access keys for revoke" err))
    Right keys -> do
      deleted <- deleteKeys keys
      case deleted of
        Left err -> pure (Left err)
        Right () -> do
          policyDeleted <- deleteUserInlinePolicy client principal policyName
          case policyDeleted of
            Left err -> pure (Left (awsFailure "delete inline policy" err))
            Right () -> do
              userDeleted <- deleteUser client principal
              case userDeleted of
                Left err -> pure (Left (awsFailure "delete IAM user" err))
                Right () -> do
                  roleDeleted <- destroyProgramRole session
                  case roleDeleted of
                    Left err -> pure (Left err)
                    Right () -> observeProductionIamIdentityAbsent session
 where
  iamProgram = productionIamProgram session
  client = productionIamClient session
  principal = credentialIamProgramPrincipal iamProgram
  policyName = credentialIamProgramPolicyName iamProgram
  deleteKeys keys = sequenceDeletes keys
  sequenceDeletes remaining = case remaining of
    [] -> pure (Right ())
    key : rest -> do
      result <- deleteAccessKey client principal (accessKeyMetadataId key)
      case result of
        Left err -> pure (Left (awsFailure "delete access key" err))
        Right () -> sequenceDeletes rest

observeProductionIamIdentityAbsent
  :: ProductionIamSession -> IO (Either ProductionIamError ())
observeProductionIamIdentityAbsent session = do
  observed <- observeUser client principal
  case observed of
    Left err -> pure (Left (awsFailure "observe IAM user absence" err))
    Right (IamUserPresent _) ->
      pure (Left (ProductionIamUserReadBackMismatch "IAM user remained present"))
    Right IamUserAbsent -> observeProgramRoleAbsent session
 where
  client = productionIamClient session
  principal = credentialIamProgramPrincipal (productionIamProgram session)

destroyProgramRole :: ProductionIamSession -> IO (Either ProductionIamError ())
destroyProgramRole session = case internalCredentialIamRole (productionIamProgram session) of
  Nothing -> pure (Right ())
  Just role -> do
    policyDeleted <-
      deleteRoleInlinePolicy
        client
        (programRoleName role)
        (programRolePolicyName role)
    case policyDeleted of
      Left err -> pure (Left (awsFailure "delete Lifecycle-provider role policy" err))
      Right () -> do
        deleted <- deleteRole client (programRoleName role)
        case deleted of
          Left err -> pure (Left (awsFailure "delete Lifecycle-provider role" err))
          Right () -> observeProgramRoleAbsent session
 where
  client = productionIamClient session

observeProgramRoleAbsent :: ProductionIamSession -> IO (Either ProductionIamError ())
observeProgramRoleAbsent session = case internalCredentialIamRole (productionIamProgram session) of
  Nothing -> pure (Right ())
  Just role -> do
    observed <- observeRole (productionIamClient session) (programRoleName role)
    pure $ case observed of
      Left err -> Left (awsFailure "observe Lifecycle-provider role absence" err)
      Right IamRoleAbsent -> Right ()
      Right IamRolePresent {} ->
        Left (ProductionIamRoleReadBackMismatch "role remained present")

waitProductionIamVisibilityGrace :: IO (Either Text ())
waitProductionIamVisibilityGrace = do
  threadDelay productionIamVisibilityGraceMicros
  pure (Right ())

productionIamVisibilityGraceMicros :: Int
productionIamVisibilityGraceMicros = 2 * 1000000

ensureProgramBucket
  :: ProductionIamSession -> IO (Either ProductionIamError ())
ensureProgramBucket session = case internalCredentialIamBucket iamProgram of
  Nothing -> pure (Right ())
  Just (RequireHardenedBucket bucket) -> do
    observed <- observeBucket s3 bucket
    case observed of
      Left err -> pure (Left (awsFailure "observe required long-lived bucket" err))
      Right S3BucketAbsent -> pure (Left ProductionIamBucketReadBackMismatch)
      Right S3BucketPresent -> observeExactHardening bucket
  Just (CreateAndHardenBucket bucket) -> do
    observed <- observeBucket s3 bucket
    present <- case observed of
      Left err -> pure (Left (awsFailure "observe long-lived bucket" err))
      Right S3BucketPresent -> pure (Right ())
      Right S3BucketAbsent -> do
        created <- createBucket s3 bucket
        case created of
          Left err -> pure (Left (awsFailure "create long-lived bucket" err))
          Right () -> do
            readBack <- observeBucket s3 bucket
            pure $ case readBack of
              Left err -> Left (awsFailure "read back created long-lived bucket" err)
              Right S3BucketPresent -> Right ()
              Right S3BucketAbsent -> Left ProductionIamBucketReadBackMismatch
    case present of
      Left err -> pure (Left err)
      Right () -> do
        hardened <- putBucketHardening s3 bucket
        case hardened of
          Left err -> pure (Left (awsFailure "harden long-lived bucket" err))
          Right () -> do
            observeExactHardening bucket
 where
  iamProgram = productionIamProgram session
  s3 = productionS3Client session
  observeExactHardening bucket = do
    readBack <- observeBucketHardening s3 bucket
    pure $ case readBack of
      Left err -> Left (awsFailure "read back long-lived bucket hardening" err)
      Right actual
        | actual == expectedLongLivedBucketHardening -> Right ()
        | otherwise -> Left ProductionIamBucketReadBackMismatch

ensureUserPolicyAndTags
  :: ProductionIamSession -> IO (Either ProductionIamError ())
ensureUserPolicyAndTags session = do
  userResult <- ensureUser
  case userResult of
    Left err -> pure (Left err)
    Right () -> do
      tagged <- tagUser client principal expectedTags
      case tagged of
        Left err -> pure (Left (awsFailure "tag IAM user" err))
        Right () -> do
          tags <- listUserTags client principal
          case tags of
            Left err -> pure (Left (awsFailure "read back IAM user tags" err))
            Right actual
              | sort actual /= sort expectedTags ->
                  pure (Left (ProductionIamTagReadBackMismatch actual))
              | otherwise -> ensurePolicy
 where
  iamProgram = productionIamProgram session
  client = productionIamClient session
  principal = credentialIamProgramPrincipal iamProgram
  policyName = credentialIamProgramPolicyName iamProgram
  expectedTags = programTags iamProgram

  ensureUser = do
    observed <- observeUser client principal
    case observed of
      Left err -> pure (Left (awsFailure "observe IAM user" err))
      Right (IamUserPresent user) -> pure (validateUser user)
      Right IamUserAbsent -> do
        created <- createUser client principal
        case created of
          Right user -> pure (validateUser user)
          Left err
            | isEntityAlreadyExists err -> do
                raced <- observeUser client principal
                pure $ case raced of
                  Right (IamUserPresent user) -> validateUser user
                  Left observeErr -> Left (awsFailure "observe raced IAM user" observeErr)
                  Right IamUserAbsent -> Left (awsFailure "create IAM user" err)
            | otherwise -> pure (Left (awsFailure "create IAM user" err))

  validateUser user
    | createUserName user == principal = Right ()
    | otherwise =
        Left
          ( ProductionIamUserReadBackMismatch
              ("expected " <> principal <> ", observed " <> createUserName user)
          )

  ensurePolicy = do
    installed <-
      putUserInlinePolicy
        client
        principal
        policyName
        (credentialIamProgramPolicyDocument iamProgram)
    case installed of
      Left err -> pure (Left (awsFailure "install IAM inline policy" err))
      Right () -> do
        observed <- observeUserInlinePolicy client principal policyName
        pure $ case observed of
          Left err -> Left (awsFailure "read back IAM inline policy" err)
          Right IamUserPolicyAbsent -> Left ProductionIamPolicyReadBackMismatch
          Right (IamUserPolicyPresent actual)
            | policiesEqual actual (credentialIamProgramPolicyDocument iamProgram) -> Right ()
            | otherwise -> Left ProductionIamPolicyReadBackMismatch

programTags :: CredentialIamProgram -> [IamTag]
programTags iamProgram =
  [ IamTag "prodbox.io/managed-by" "prodbox"
  , IamTag
      "prodbox.io/credential-class"
      (credentialClassTag (credentialIamProgramClass iamProgram))
  ]

credentialClassTag :: AwsCredentialClass -> Text
credentialClassTag credentialClass = case credentialClass of
  LifecycleProviderCredential -> "lifecycle-provider"
  AuthorityBackupStoreCredential -> "authority-backup-store"
  TlsRetentionStoreCredential -> "tls-retention-store"
  GatewayDnsCredential -> "gateway-dns"
  HomeCertManagerDns01Credential -> "home-cert-manager-dns01"
  AwsRunCertManagerDns01Credential -> "aws-run-cert-manager-dns01"
  SesSmtpRetainedCustodyCredential -> "ses-smtp-retained-custody"

createdMaterial
  :: CreateAccessKeyResult
  -> Either Text CreatedAwsAccessKey
createdMaterial created = do
  secret <-
    either
      (const (Left "IAM returned a non-UTF8 secret access key"))
      Right
      (decodeUtf8' (unSecret (createdSecretAccessKey created)))
  either
    (Left . Text.pack . show)
    Right
    (mkCreatedAwsAccessKey (createdAccessKeyId created) secret)

policiesEqual :: Text -> Text -> Bool
policiesEqual left right =
  case (decodePolicy left, decodePolicy right) of
    (Right leftValue, Right rightValue) -> leftValue == rightValue
    _ -> False

decodePolicy :: Text -> Either String Value
decodePolicy = eitherDecodeStrict' . encodeUtf8

renderPolicy :: Value -> Text
renderPolicy = decodeUtf8 . LazyByteString.toStrict . encode

statementPolicy :: [Value] -> Value
statementPolicy statements =
  object
    [ "Version" .= ("2012-10-17" :: Text)
    , "Statement" .= statements
    ]

statement :: Text -> [Text] -> [Text] -> Value
statement sid actions resources =
  object
    [ "Sid" .= sid
    , "Effect" .= ("Allow" :: Text)
    , "Action" .= actions
    , "Resource" .= resources
    ]

s3AdapterPolicy :: Text -> [Text] -> Value
s3AdapterPolicy bucket prefixes =
  statementPolicy
    [ object
        [ "Sid" .= ("ObserveRegisteredPrefixes" :: Text)
        , "Effect" .= ("Allow" :: Text)
        , "Action" .= (["s3:GetBucketLocation", "s3:ListBucket"] :: [Text])
        , "Resource" .= bucketArn
        , "Condition"
            .= object
              [ "StringLike"
                  .= object
                    [ "s3:prefix"
                        .= concatMap (\prefix -> [prefix <> "/", prefix <> "/*"]) prefixes
                    ]
              ]
        ]
    , statement
        "ReadWriteRegisteredObjects"
        ["s3:GetObject", "s3:GetObjectVersion", "s3:PutObject"]
        [bucketArn <> "/" <> prefix <> "/*" | prefix <- prefixes]
    ]
 where
  bucketArn = "arn:aws:s3:::" <> bucket

route53Policy :: Text -> Text -> Value
route53Policy sid zoneId =
  statementPolicy
    [ statement
        sid
        ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"]
        ["arn:aws:route53:::hostedzone/" <> zoneId]
    , statement
        "ObserveRegisteredRoute53Change"
        ["route53:GetChange"]
        ["*"]
    ]

-- | Permissions for the fenced non-credential Provider interpreter. IAM is
-- limited to role, policy, instance-profile, and OIDC-provider lifecycle; no
-- user or access-key action is present.
lifecycleProviderRolePolicy :: Value
lifecycleProviderRolePolicy =
  statementPolicy
    [ statement
        "RegisteredComputeAndClusterEffects"
        ["ec2:*", "eks:*", "autoscaling:*", "elasticloadbalancing:*"]
        ["*"]
    , statement
        "RegisteredDnsSesAndObjectStoreEffects"
        ( [ "route53:ChangeResourceRecordSets"
          , "route53:GetChange"
          , "route53:GetHostedZone"
          , "route53:ListResourceRecordSets"
          , "s3:CreateBucket"
          , "s3:DeleteBucket"
          , "s3:GetBucketLocation"
          , "s3:GetBucketPolicy"
          , "s3:GetBucketVersioning"
          , "s3:ListBucket"
          , "s3:ListBucketVersions"
          , "s3:PutBucketPolicy"
          , "s3:PutBucketVersioning"
          , "s3:GetObject"
          , "s3:GetObjectVersion"
          , "s3:PutObject"
          , "s3:DeleteObject"
          , "s3:DeleteObjectVersion"
          ]
            <> fmap
              ("ses:" <>)
              [ "GetIdentityVerificationAttributes"
              , "VerifyDomainIdentity"
              , "VerifyDomainDkim"
              , "SetIdentityNotificationTopic"
              , "SetIdentityMailFromDomain"
              , "CreateReceiptRuleSet"
              , "CreateReceiptRule"
              , "DescribeReceiptRuleSet"
              , "SetActiveReceiptRuleSet"
              , "DeleteReceiptRule"
              , "DeleteReceiptRuleSet"
              , "DeleteIdentity"
              ]
        )
        ["*"]
    , statement
        "RegisteredIamRoleEffects"
        ( fmap
            ("iam:" <>)
            [ "AddRoleToInstanceProfile"
            , "AttachRolePolicy"
            , "CreateInstanceProfile"
            , "CreateOpenIDConnectProvider"
            , "CreatePolicy"
            , "CreatePolicyVersion"
            , "CreateRole"
            , "DeleteInstanceProfile"
            , "DeleteOpenIDConnectProvider"
            , "DeletePolicy"
            , "DeletePolicyVersion"
            , "DeleteRole"
            , "DeleteRolePolicy"
            , "DetachRolePolicy"
            , "GetInstanceProfile"
            , "GetOpenIDConnectProvider"
            , "GetPolicy"
            , "GetPolicyVersion"
            , "GetRole"
            , "GetRolePolicy"
            , "ListAttachedRolePolicies"
            , "ListInstanceProfilesForRole"
            , "ListPolicyVersions"
            , "ListRolePolicies"
            , "PassRole"
            , "PutRolePolicy"
            , "RemoveRoleFromInstanceProfile"
            , "TagOpenIDConnectProvider"
            , "TagPolicy"
            , "TagRole"
            , "UntagOpenIDConnectProvider"
            , "UntagPolicy"
            , "UntagRole"
            , "UpdateAssumeRolePolicy"
            ]
        )
        ["*"]
    ]

validateRegion :: Text -> Either ProductionIamError Text
validateRegion = validateField "AWS region" 64 valid
 where
  valid character = isAsciiLower character || isDigit character || character == '-'

validateAccountId :: Text -> Either ProductionIamError Text
validateAccountId raw = do
  value <- validateField "AWS account ID" 12 isDigit raw
  if Text.length value == 12
    then Right value
    else Left (ProductionIamFieldInvalid "AWS account ID must contain exactly 12 digits")

validateIamName :: Text -> Text -> Either ProductionIamError Text
validateIamName label = validateField label 64 valid
 where
  valid character =
    isAsciiLower character
      || isAsciiUpper character
      || isDigit character
      || character `elem` ['+', '=', ',', '.', '@', '_', '-']

validateHostedZoneId :: Text -> Either ProductionIamError Text
validateHostedZoneId raw =
  validateField "Route 53 hosted-zone ID" 64 valid normalized
 where
  normalized =
    Text.dropWhile
      (== '/')
      (maybe (Text.strip raw) id (Text.stripPrefix "/hostedzone/" (Text.strip raw)))
  valid character = isAsciiUpper character || isDigit character

validateSesIdentity :: Text -> Either ProductionIamError Text
validateSesIdentity = validateField "SES identity" 253 valid
 where
  valid character =
    isAsciiLower character || isDigit character || character `elem` ['-', '.']

validateBucket :: Text -> Either ProductionIamError Text
validateBucket raw =
  either
    (Left . ProductionIamFieldInvalid . Text.pack)
    Right
    (validateDedicatedBucket raw)

validatePrefixes :: Text -> [Text] -> Either ProductionIamError [Text]
validatePrefixes expectedPrefix rawPrefixes = do
  unless
    (not (null rawPrefixes))
    (Left (ProductionIamFieldInvalid "registered S3 prefix inventory is empty"))
  prefixes <-
    traverse
      ( either
          (Left . ProductionIamFieldInvalid . Text.pack)
          Right
          . validateDedicatedPrefix
      )
      rawPrefixes
  unless
    (all (expectedPrefix `Text.isPrefixOf`) prefixes)
    (Left (ProductionIamFieldInvalid "registered S3 prefix belongs to another credential class"))
  Right (sort prefixes)

validateField
  :: Text
  -> Int
  -> (Char -> Bool)
  -> Text
  -> Either ProductionIamError Text
validateField label maximumLength validCharacter raw =
  let value = Text.strip raw
   in if Text.null value
        || Text.length value > maximumLength
        || Text.any (not . validCharacter) value
        then Left (ProductionIamFieldInvalid (label <> " is invalid"))
        else Right value

isEntityAlreadyExists :: AwsClientError -> Bool
isEntityAlreadyExists err = case err of
  AwsServiceError fault -> awsFaultCode fault == "EntityAlreadyExists"
  _ -> False

awsFailure :: Text -> AwsClientError -> ProductionIamError
awsFailure = ProductionIamAwsFailed

renderAwsError :: AwsClientError -> Text
renderAwsError = Text.pack . show
