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
  , ProductionIamAwsOperationCause (..)
  , ProductionIamAwsClientCause (..)
  , ProductionIamRoleReadBackCause (..)
  , ProductionIamTrustPolicyMismatchCause (..)
  , ProductionIamErrorCause (..)
  , allProductionIamErrorCauses
  , allProductionIamRoleReadBackCauses
  , classifyProductionIamTrustPolicyMismatch
  , trustPoliciesEqual
  , classifyProductionIamError
  , renderProductionIamAwsOperationCause
  , renderProductionIamAwsClientCause
  , renderProductionIamRoleReadBackCause
  , renderProductionIamTrustPolicyMismatchCause
  , renderProductionIamErrorCause
  , openProductionIamSession
  , openProductionIamSessionWithSender
  , ensureProductionIamPrerequisites
  , observeProductionAccessKeyInventory
  , deleteProductionAccessKey
  , createProductionAccessKey
  , destroyProductionIamIdentity
  , observeProductionIamFamilyAbsent
  , productionIamJointAuthorization
  , waitProductionIamVisibilityGrace
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (unless, void)
import Data.Aeson
  ( Value (Array, Object, String)
  , eitherDecodeStrict'
  , encode
  , object
  , (.=)
  )
import Data.Aeson.KeyMap qualified as AesonKeyMap
import Data.Bifunctor (first)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8, decodeUtf8', encodeUtf8)
import Data.Vector qualified as Vector
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
  ( AmbiguityCause (..)
  , AwsClientError (..)
  , AwsServiceFault (awsFaultCode, awsFaultHttpStatus)
  , NativeAwsSender
  , httpSend
  )
import Prodbox.Infra.DedicatedAdapterIam
  ( validateDedicatedBucket
  , validateDedicatedPrefix
  )
import Prodbox.Lifecycle.CredentialProvisioner.Execution
  ( AccessKeyInventoryObservation (..)
  , AwsAccessKeyCreateAmbiguityCause (..)
  , AwsAccessKeyCreateResult (..)
  , ProvisionedAccessKeyId
  , mkProvisionedAccessKeyId
  , observedAccessKeyInventory
  , provisionedAccessKeyIdText
  )
import Prodbox.Lifecycle.CredentialProvisioner.JointIamDisposition
  ( IamFamilyMember (..)
  , IamMemberObservation (..)
  , JointIamDispositionAuthorization
  , JointIamDispositionComplete
  , JointIamDispositionRefusal
  , disposeJointIamFamily
  , jointIamDispositionOrder
  , jointIamDispositionPrincipal
  , jointIamDispositionRole
  , mkJointIamDispositionAuthorization
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
  | ProductionIamRoleReadBackMismatch !ProductionIamRoleReadBackCause
  | ProductionIamRolePolicyReadBackMismatch
  | ProductionIamAccessKeyInvalid !Text
  | ProductionIamMaterialInvalid !TargetMaterialValueError
  | -- | Sprint 7.36: the family survived the destroy, could not be observed, or
    -- was observed incompletely. It names every surviving member rather than
    -- the first, because that set is what a retry resumes from.
    ProductionIamJointDispositionRefused !JointIamDispositionRefusal
  | -- | The authorization does not name the family this session's program owns.
    ProductionIamJointAuthorizationMismatch !Text
  deriving (Eq, Show)

-- | Closed, payload-free diagnostic stage for a native AWS prerequisite
-- request. The production error retains its bounded private label; only this
-- finite projection may reach the worker's terminal line.
data ProductionIamAwsOperationCause
  = ProductionIamObserveLifecycleRole
  | ProductionIamCreateLifecycleRole
  | ProductionIamUpdateLifecycleRoleTrust
  | ProductionIamReadBackLifecycleRole
  | ProductionIamInstallLifecycleRolePolicy
  | ProductionIamReadBackLifecycleRolePolicy
  | ProductionIamObserveRequiredBucket
  | ProductionIamObserveBucket
  | ProductionIamCreateBucket
  | ProductionIamReadBackCreatedBucket
  | ProductionIamHardenBucket
  | ProductionIamReadBackBucketHardening
  | ProductionIamTagUser
  | ProductionIamReadBackUserTags
  | ProductionIamObserveUser
  | ProductionIamObserveRacedUser
  | ProductionIamCreateUser
  | ProductionIamInstallUserPolicy
  | ProductionIamReadBackUserPolicy
  | ProductionIamAwsOperationUnknown
  deriving (Bounded, Enum, Eq, Show)

data ProductionIamAwsClientCause
  = ProductionIamAwsSigningFailure
  | ProductionIamAwsTransportFailure
  | ProductionIamAwsServiceAccessDenied
  | ProductionIamAwsServiceInvalidClientToken
  | ProductionIamAwsServiceSignatureMismatch
  | ProductionIamAwsServiceExpiredToken
  | ProductionIamAwsServiceInvalidToken
  | ProductionIamAwsServiceNoSuchEntity
  | ProductionIamAwsServiceEntityAlreadyExists
  | ProductionIamAwsServiceConcurrentModification
  | ProductionIamAwsServiceInvalidInput
  | ProductionIamAwsServiceLimitExceeded
  | ProductionIamAwsServiceMalformedPolicyDocument
  | ProductionIamAwsServiceThrottled
  | ProductionIamAwsServiceOtherClient
  | ProductionIamAwsServiceServer
  | ProductionIamAwsServiceUnexpectedStatus
  | ProductionIamAwsResponseParseFailure
  | ProductionIamAwsAmbiguousDispatch
  | ProductionIamAwsAmbiguousLostResult
  deriving (Bounded, Enum, Eq, Show)

data ProductionIamRoleReadBackCause
  = ProductionIamRoleReadBackAbsent
  | ProductionIamRoleReadBackNameMismatch
  | ProductionIamRoleReadBackArnMismatch
  | ProductionIamRoleReadBackTrustPolicyMismatch !ProductionIamTrustPolicyMismatchCause
  deriving (Eq, Show)

data ProductionIamTrustPolicyMismatchCause
  = ProductionIamTrustPolicyInvalid
  | ProductionIamTrustPolicyIamSingletonEquivalent
  | ProductionIamTrustPolicyOther
  deriving (Bounded, Enum, Eq, Show)

allProductionIamRoleReadBackCauses :: [ProductionIamRoleReadBackCause]
allProductionIamRoleReadBackCauses =
  [ ProductionIamRoleReadBackAbsent
  , ProductionIamRoleReadBackNameMismatch
  , ProductionIamRoleReadBackArnMismatch
  ]
    <> ( ProductionIamRoleReadBackTrustPolicyMismatch
           <$> ([minBound .. maxBound] :: [ProductionIamTrustPolicyMismatchCause])
       )

data ProductionIamErrorCause
  = ProductionIamErrorUnclassified
  | ProductionIamErrorFieldInvalid
  | ProductionIamErrorCredentialInvalid
  | ProductionIamErrorCredentialRegionMismatch
  | ProductionIamErrorAwsFailed
      !ProductionIamAwsOperationCause
      !ProductionIamAwsClientCause
  | ProductionIamErrorUserReadBackMismatch
  | ProductionIamErrorPolicyReadBackMismatch
  | ProductionIamErrorTagReadBackMismatch
  | ProductionIamErrorBucketReadBackMismatch
  | ProductionIamErrorRoleReadBackMismatch !ProductionIamRoleReadBackCause
  | ProductionIamErrorRolePolicyReadBackMismatch
  | ProductionIamErrorAccessKeyInvalid
  | ProductionIamErrorMaterialInvalid
  | ProductionIamErrorJointDispositionRefused
  | ProductionIamErrorJointAuthorizationMismatch
  deriving (Eq, Show)

allProductionIamErrorCauses :: [ProductionIamErrorCause]
allProductionIamErrorCauses =
  [ ProductionIamErrorUnclassified
  , ProductionIamErrorFieldInvalid
  , ProductionIamErrorCredentialInvalid
  , ProductionIamErrorCredentialRegionMismatch
  ]
    <> [ ProductionIamErrorAwsFailed operation client
       | operation <- [minBound .. maxBound]
       , client <- [minBound .. maxBound]
       ]
    <> [ ProductionIamErrorUserReadBackMismatch
       , ProductionIamErrorPolicyReadBackMismatch
       , ProductionIamErrorTagReadBackMismatch
       , ProductionIamErrorBucketReadBackMismatch
       ]
    <> fmap
      ProductionIamErrorRoleReadBackMismatch
      allProductionIamRoleReadBackCauses
    <> [ ProductionIamErrorRolePolicyReadBackMismatch
       , ProductionIamErrorAccessKeyInvalid
       , ProductionIamErrorMaterialInvalid
       , ProductionIamErrorJointDispositionRefused
       , ProductionIamErrorJointAuthorizationMismatch
       ]

classifyProductionIamError :: ProductionIamError -> ProductionIamErrorCause
classifyProductionIamError productionError = case productionError of
  ProductionIamFieldInvalid _ -> ProductionIamErrorFieldInvalid
  ProductionIamCredentialInvalid _ -> ProductionIamErrorCredentialInvalid
  ProductionIamCredentialRegionMismatch _ _ -> ProductionIamErrorCredentialRegionMismatch
  ProductionIamAwsFailed operation clientError ->
    ProductionIamErrorAwsFailed
      (classifyProductionIamAwsOperation operation)
      (classifyProductionIamAwsClientError clientError)
  ProductionIamUserReadBackMismatch _ -> ProductionIamErrorUserReadBackMismatch
  ProductionIamPolicyReadBackMismatch -> ProductionIamErrorPolicyReadBackMismatch
  ProductionIamTagReadBackMismatch _ -> ProductionIamErrorTagReadBackMismatch
  ProductionIamBucketReadBackMismatch -> ProductionIamErrorBucketReadBackMismatch
  ProductionIamRoleReadBackMismatch cause -> ProductionIamErrorRoleReadBackMismatch cause
  ProductionIamRolePolicyReadBackMismatch -> ProductionIamErrorRolePolicyReadBackMismatch
  ProductionIamAccessKeyInvalid _ -> ProductionIamErrorAccessKeyInvalid
  ProductionIamMaterialInvalid _ -> ProductionIamErrorMaterialInvalid
  ProductionIamJointDispositionRefused _ -> ProductionIamErrorJointDispositionRefused
  ProductionIamJointAuthorizationMismatch _ -> ProductionIamErrorJointAuthorizationMismatch

classifyProductionIamAwsOperation :: Text -> ProductionIamAwsOperationCause
classifyProductionIamAwsOperation operation = case operation of
  "observe Lifecycle-provider role" -> ProductionIamObserveLifecycleRole
  "create Lifecycle-provider role" -> ProductionIamCreateLifecycleRole
  "update Lifecycle-provider trust policy" -> ProductionIamUpdateLifecycleRoleTrust
  "read back Lifecycle-provider role" -> ProductionIamReadBackLifecycleRole
  "install Lifecycle-provider role policy" -> ProductionIamInstallLifecycleRolePolicy
  "read back Lifecycle-provider role policy" -> ProductionIamReadBackLifecycleRolePolicy
  "observe required long-lived bucket" -> ProductionIamObserveRequiredBucket
  "observe long-lived bucket" -> ProductionIamObserveBucket
  "create long-lived bucket" -> ProductionIamCreateBucket
  "read back created long-lived bucket" -> ProductionIamReadBackCreatedBucket
  "harden long-lived bucket" -> ProductionIamHardenBucket
  "read back long-lived bucket hardening" -> ProductionIamReadBackBucketHardening
  "tag IAM user" -> ProductionIamTagUser
  "read back IAM user tags" -> ProductionIamReadBackUserTags
  "observe IAM user" -> ProductionIamObserveUser
  "observe raced IAM user" -> ProductionIamObserveRacedUser
  "create IAM user" -> ProductionIamCreateUser
  "install IAM inline policy" -> ProductionIamInstallUserPolicy
  "read back IAM inline policy" -> ProductionIamReadBackUserPolicy
  _ -> ProductionIamAwsOperationUnknown

classifyProductionIamAwsClientError :: AwsClientError -> ProductionIamAwsClientCause
classifyProductionIamAwsClientError clientError = case clientError of
  AwsSigningError _ -> ProductionIamAwsSigningFailure
  AwsTransportError _ -> ProductionIamAwsTransportFailure
  AwsServiceError fault -> classifyProductionIamAwsServiceFault fault
  AwsResponseParseFailure _ -> ProductionIamAwsResponseParseFailure
  AwsAmbiguousOutcome ambiguity -> case ambiguity of
    AmbiguousDispatchFailure {} -> ProductionIamAwsAmbiguousDispatch
    AmbiguousLostResult {} -> ProductionIamAwsAmbiguousLostResult

classifyProductionIamAwsServiceFault :: AwsServiceFault -> ProductionIamAwsClientCause
classifyProductionIamAwsServiceFault fault = case awsFaultCode fault of
  "AccessDenied" -> ProductionIamAwsServiceAccessDenied
  "AccessDeniedException" -> ProductionIamAwsServiceAccessDenied
  "InvalidClientTokenId" -> ProductionIamAwsServiceInvalidClientToken
  "SignatureDoesNotMatch" -> ProductionIamAwsServiceSignatureMismatch
  "ExpiredToken" -> ProductionIamAwsServiceExpiredToken
  "ExpiredTokenException" -> ProductionIamAwsServiceExpiredToken
  "InvalidToken" -> ProductionIamAwsServiceInvalidToken
  "NoSuchEntity" -> ProductionIamAwsServiceNoSuchEntity
  "EntityAlreadyExists" -> ProductionIamAwsServiceEntityAlreadyExists
  "ConcurrentModification" -> ProductionIamAwsServiceConcurrentModification
  "InvalidInput" -> ProductionIamAwsServiceInvalidInput
  "LimitExceeded" -> ProductionIamAwsServiceLimitExceeded
  "MalformedPolicyDocument" -> ProductionIamAwsServiceMalformedPolicyDocument
  "Throttling" -> ProductionIamAwsServiceThrottled
  "ThrottlingException" -> ProductionIamAwsServiceThrottled
  "TooManyRequestsException" -> ProductionIamAwsServiceThrottled
  _
    | awsFaultHttpStatus fault >= 400 && awsFaultHttpStatus fault < 500 ->
        ProductionIamAwsServiceOtherClient
    | awsFaultHttpStatus fault >= 500 && awsFaultHttpStatus fault < 600 ->
        ProductionIamAwsServiceServer
    | otherwise -> ProductionIamAwsServiceUnexpectedStatus

renderProductionIamErrorCause :: ProductionIamErrorCause -> Text
renderProductionIamErrorCause cause = case cause of
  ProductionIamErrorUnclassified -> "unclassified"
  ProductionIamErrorFieldInvalid -> "field-invalid"
  ProductionIamErrorCredentialInvalid -> "credential-invalid"
  ProductionIamErrorCredentialRegionMismatch -> "credential-region-mismatch"
  ProductionIamErrorAwsFailed operation client ->
    "aws/"
      <> renderProductionIamAwsOperationCause operation
      <> "/"
      <> renderProductionIamAwsClientCause client
  ProductionIamErrorUserReadBackMismatch -> "user-read-back-mismatch"
  ProductionIamErrorPolicyReadBackMismatch -> "policy-read-back-mismatch"
  ProductionIamErrorTagReadBackMismatch -> "tag-read-back-mismatch"
  ProductionIamErrorBucketReadBackMismatch -> "bucket-read-back-mismatch"
  ProductionIamErrorRoleReadBackMismatch mismatch ->
    "role-read-back-mismatch/" <> renderProductionIamRoleReadBackCause mismatch
  ProductionIamErrorRolePolicyReadBackMismatch -> "role-policy-read-back-mismatch"
  ProductionIamErrorAccessKeyInvalid -> "access-key-invalid"
  ProductionIamErrorMaterialInvalid -> "material-invalid"
  ProductionIamErrorJointDispositionRefused -> "joint-disposition-refused"
  ProductionIamErrorJointAuthorizationMismatch -> "joint-authorization-mismatch"

renderProductionIamAwsOperationCause :: ProductionIamAwsOperationCause -> Text
renderProductionIamAwsOperationCause operation = case operation of
  ProductionIamObserveLifecycleRole -> "observe-lifecycle-role"
  ProductionIamCreateLifecycleRole -> "create-lifecycle-role"
  ProductionIamUpdateLifecycleRoleTrust -> "update-lifecycle-role-trust"
  ProductionIamReadBackLifecycleRole -> "read-back-lifecycle-role"
  ProductionIamInstallLifecycleRolePolicy -> "install-lifecycle-role-policy"
  ProductionIamReadBackLifecycleRolePolicy -> "read-back-lifecycle-role-policy"
  ProductionIamObserveRequiredBucket -> "observe-required-bucket"
  ProductionIamObserveBucket -> "observe-bucket"
  ProductionIamCreateBucket -> "create-long-lived-bucket"
  ProductionIamReadBackCreatedBucket -> "read-back-created-bucket"
  ProductionIamHardenBucket -> "harden-bucket"
  ProductionIamReadBackBucketHardening -> "read-back-bucket-hardening"
  ProductionIamTagUser -> "tag-user"
  ProductionIamReadBackUserTags -> "read-back-user-tags"
  ProductionIamObserveUser -> "observe-user"
  ProductionIamObserveRacedUser -> "observe-raced-user"
  ProductionIamCreateUser -> "create-iam-user"
  ProductionIamInstallUserPolicy -> "install-user-policy"
  ProductionIamReadBackUserPolicy -> "read-back-user-policy"
  ProductionIamAwsOperationUnknown -> "unknown"

renderProductionIamAwsClientCause :: ProductionIamAwsClientCause -> Text
renderProductionIamAwsClientCause cause = case cause of
  ProductionIamAwsSigningFailure -> "signing-failure"
  ProductionIamAwsTransportFailure -> "transport-failure"
  ProductionIamAwsServiceAccessDenied -> "service/access-denied"
  ProductionIamAwsServiceInvalidClientToken -> "service/invalid-client-token"
  ProductionIamAwsServiceSignatureMismatch -> "service/signature-mismatch"
  ProductionIamAwsServiceExpiredToken -> "service/expired-token"
  ProductionIamAwsServiceInvalidToken -> "service/invalid-token"
  ProductionIamAwsServiceNoSuchEntity -> "service/no-such-entity"
  ProductionIamAwsServiceEntityAlreadyExists -> "service/entity-already-exists"
  ProductionIamAwsServiceConcurrentModification -> "service/concurrent-modification"
  ProductionIamAwsServiceInvalidInput -> "service/invalid-input"
  ProductionIamAwsServiceLimitExceeded -> "service/limit-exceeded"
  ProductionIamAwsServiceMalformedPolicyDocument -> "service/malformed-policy-document"
  ProductionIamAwsServiceThrottled -> "service/throttled"
  ProductionIamAwsServiceOtherClient -> "service/other-client"
  ProductionIamAwsServiceServer -> "service/server"
  ProductionIamAwsServiceUnexpectedStatus -> "service/unexpected-status"
  ProductionIamAwsResponseParseFailure -> "response-parse-failure"
  ProductionIamAwsAmbiguousDispatch -> "ambiguous/dispatch"
  ProductionIamAwsAmbiguousLostResult -> "ambiguous/lost-result"

renderProductionIamRoleReadBackCause :: ProductionIamRoleReadBackCause -> Text
renderProductionIamRoleReadBackCause cause = case cause of
  ProductionIamRoleReadBackAbsent -> "absent"
  ProductionIamRoleReadBackNameMismatch -> "name-mismatch"
  ProductionIamRoleReadBackArnMismatch -> "arn-mismatch"
  ProductionIamRoleReadBackTrustPolicyMismatch mismatch ->
    "trust-policy-mismatch/" <> renderProductionIamTrustPolicyMismatchCause mismatch

renderProductionIamTrustPolicyMismatchCause :: ProductionIamTrustPolicyMismatchCause -> Text
renderProductionIamTrustPolicyMismatchCause cause = case cause of
  ProductionIamTrustPolicyInvalid -> "invalid"
  ProductionIamTrustPolicyIamSingletonEquivalent -> "iam-singleton-equivalent"
  ProductionIamTrustPolicyOther -> "other"

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
            Left (ProductionIamRoleReadBackMismatch ProductionIamRoleReadBackAbsent)
          Right present@IamRolePresent {}
            | iamRoleName present /= programRoleName role ->
                Left (ProductionIamRoleReadBackMismatch ProductionIamRoleReadBackNameMismatch)
            | iamRoleArn present /= programRoleArn role ->
                Left (ProductionIamRoleReadBackMismatch ProductionIamRoleReadBackArnMismatch)
            | not
                ( trustPoliciesEqual
                    (iamRoleAssumePolicyDocument present)
                    (programRoleTrustPolicy role)
                ) ->
                Left
                  ( ProductionIamRoleReadBackMismatch
                      ( ProductionIamRoleReadBackTrustPolicyMismatch
                          ( classifyProductionIamTrustPolicyMismatch
                              (iamRoleAssumePolicyDocument present)
                              (programRoleTrustPolicy role)
                          )
                      )
                  )
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
    Left (AwsAmbiguousOutcome ambiguity) ->
      AwsAccessKeyCreateResponseLost $ case ambiguity of
        AmbiguousDispatchFailure {} -> AwsAccessKeyCreateDispatchAmbiguous
        AmbiguousLostResult {} -> AwsAccessKeyCreateLostResult
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

-- | Sprint 7.36: destroy the whole IAM family as one disposition.
--
-- Two properties replace the sequence this used to be. Every member is
-- /attempted/, so a failure part-way through no longer abandons the remainder
-- and leaves a partially destroyed principal; and the inline policies are
-- /enumerated/ rather than addressed by one authored name, so a creator that
-- wrote a different policy name no longer strands a policy that IAM then cites
-- forever when refusing to delete the principal. Completion is minted only from
-- the separate read-back below, in which every member is independently absent.
destroyProductionIamIdentity
  :: JointIamDispositionAuthorization
  -> ProductionIamSession
  -> IO (Either ProductionIamError JointIamDispositionComplete)
destroyProductionIamIdentity authorization session =
  case validateJointAuthorization authorization session of
    Left err -> pure (Left err)
    Right () -> do
      mapM_ (attemptMember session) (jointIamDispositionOrder authorization)
      observeProductionIamFamilyAbsent authorization session

-- | Attempt one member's removal, never failing the disposition.
--
-- A member that cannot be removed here is not an error: the read-back is what
-- decides, and it will name this member as surviving. Returning early instead
-- is exactly the abandonment this sprint removes.
attemptMember :: ProductionIamSession -> IamFamilyMember -> IO ()
attemptMember session member = case member of
  IamAccessKeyFamily -> do
    inventory <- listAccessKeys client principal
    case inventory of
      Left _ -> pure ()
      Right keys ->
        mapM_
          (\key -> void (deleteAccessKey client principal (accessKeyMetadataId key)))
          keys
  IamInlinePolicyFamily -> do
    policies <- listUserInlinePolicies client principal
    case policies of
      Left _ -> pure ()
      Right names ->
        mapM_ (\name -> void (deleteUserInlinePolicy client principal name)) names
  IamPrincipal -> void (deleteUser client principal)
  IamAssumedRoleInlinePolicy -> case programRole of
    Nothing -> pure ()
    Just role ->
      void
        ( deleteRoleInlinePolicy
            client
            (programRoleName role)
            (programRolePolicyName role)
        )
  IamAssumedRole -> case programRole of
    Nothing -> pure ()
    Just role -> void (deleteRole client (programRoleName role))
 where
  client = productionIamClient session
  principal = credentialIamProgramPrincipal (productionIamProgram session)
  programRole = internalCredentialIamRole (productionIamProgram session)

-- | The exact-coordinate read-back over the whole family.
--
-- Total over the family, so a member nothing answered for refuses rather than
-- passing; and an unobservable member refuses distinctly from a surviving one,
-- because they license different next steps.
observeProductionIamFamilyAbsent
  :: JointIamDispositionAuthorization
  -> ProductionIamSession
  -> IO (Either ProductionIamError JointIamDispositionComplete)
observeProductionIamFamilyAbsent authorization session =
  case validateJointAuthorization authorization session of
    Left err -> pure (Left err)
    Right () -> do
      observations <-
        traverse
          (\member -> (,) member <$> observeMember session member)
          (jointIamDispositionOrder authorization)
      pure
        ( first
            ProductionIamJointDispositionRefused
            (disposeJointIamFamily authorization observations)
        )

observeMember
  :: ProductionIamSession -> IamFamilyMember -> IO IamMemberObservation
observeMember session member = case member of
  IamAccessKeyFamily -> do
    observed <- listAccessKeys client principal
    pure $ case observed of
      Left err -> IamMemberUnobservable (boundedDetail err)
      Right [] -> IamMemberAbsent
      Right _ -> IamMemberPresent
  IamInlinePolicyFamily -> do
    observed <- listUserInlinePolicies client principal
    pure $ case observed of
      Left err -> IamMemberUnobservable (boundedDetail err)
      Right [] -> IamMemberAbsent
      Right _ -> IamMemberPresent
  IamPrincipal -> do
    observed <- observeUser client principal
    pure $ case observed of
      Left err -> IamMemberUnobservable (boundedDetail err)
      Right IamUserAbsent -> IamMemberAbsent
      Right (IamUserPresent _) -> IamMemberPresent
  IamAssumedRoleInlinePolicy -> case programRole of
    Nothing -> pure IamMemberAbsent
    Just role -> do
      observed <-
        observeRoleInlinePolicy
          client
          (programRoleName role)
          (programRolePolicyName role)
      pure $ case observed of
        Left err -> IamMemberUnobservable (boundedDetail err)
        Right IamRolePolicyAbsent -> IamMemberAbsent
        Right (IamRolePolicyPresent _) -> IamMemberPresent
  IamAssumedRole -> case programRole of
    Nothing -> pure IamMemberAbsent
    Just role -> do
      observed <- observeRole client (programRoleName role)
      pure $ case observed of
        Left err -> IamMemberUnobservable (boundedDetail err)
        Right IamRoleAbsent -> IamMemberAbsent
        Right IamRolePresent {} -> IamMemberPresent
 where
  client = productionIamClient session
  principal = credentialIamProgramPrincipal (productionIamProgram session)
  programRole = internalCredentialIamRole (productionIamProgram session)
  boundedDetail = Text.take 200 . Text.pack . show

-- | The authorization this session's own program licenses.
--
-- Derived from the program rather than accepted beside it, so the caller
-- constructing an authorization and the session executing it cannot name two
-- different families.
productionIamJointAuthorization
  :: ProductionIamSession
  -> Either ProductionIamError JointIamDispositionAuthorization
productionIamJointAuthorization session =
  first
    (ProductionIamJointAuthorizationMismatch . Text.take 200 . Text.pack . show)
    ( mkJointIamDispositionAuthorization
        ( awsCredentialDescriptorClass
            (internalCredentialIamDescriptor (productionIamProgram session))
        )
        (programRoleName <$> internalCredentialIamRole (productionIamProgram session))
    )

validateJointAuthorization
  :: JointIamDispositionAuthorization
  -> ProductionIamSession
  -> Either ProductionIamError ()
validateJointAuthorization authorization session = do
  expected <- productionIamJointAuthorization session
  if jointIamDispositionPrincipal authorization
    == jointIamDispositionPrincipal expected
    && jointIamDispositionRole authorization == jointIamDispositionRole expected
    then Right ()
    else
      Left
        ( ProductionIamJointAuthorizationMismatch
            ( "authorization names "
                <> jointIamDispositionPrincipal authorization
                <> " but this session's program owns "
                <> jointIamDispositionPrincipal expected
            )
        )

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

trustPoliciesEqual :: Text -> Text -> Bool
trustPoliciesEqual observed authored =
  policiesEqual observed authored
    || classifyProductionIamTrustPolicyMismatch observed authored
      == ProductionIamTrustPolicyIamSingletonEquivalent

classifyProductionIamTrustPolicyMismatch
  :: Text -> Text -> ProductionIamTrustPolicyMismatchCause
classifyProductionIamTrustPolicyMismatch observed authored =
  case (decodePolicy observed, decodePolicy authored) of
    (Right observedValue, Right authoredValue)
      | normalizeIamPolicySingletons observedValue
          == normalizeIamPolicySingletons authoredValue ->
          ProductionIamTrustPolicyIamSingletonEquivalent
      | otherwise -> ProductionIamTrustPolicyOther
    _ -> ProductionIamTrustPolicyInvalid

normalizeIamPolicySingletons :: Value -> Value
normalizeIamPolicySingletons value = case value of
  Object policy ->
    Object
      ( adjustKey
          normalizeStatements
          "Statement"
          policy
      )
  other -> other
 where
  normalizeStatements statements =
    Array (normalizeStatement <$> asArray statements)
  normalizeStatement statementValue = case statementValue of
    Object statementObject ->
      Object
        ( adjustKey
            normalizePrincipal
            "Principal"
            (adjustKey normalizeStringSet "Action" statementObject)
        )
    other -> other
  normalizePrincipal principalValue = case principalValue of
    Object principalObject ->
      Object (adjustKey normalizeStringSet "AWS" principalObject)
    other -> other
  normalizeStringSet stringSet = case stringSet of
    String item -> Array (Vector.singleton (String item))
    other -> other
  asArray singleton = case singleton of
    Array entries -> entries
    other -> Vector.singleton other
  adjustKey transform key keyMap = case AesonKeyMap.lookup key keyMap of
    Nothing -> keyMap
    Just current -> AesonKeyMap.insert key (transform current) keyMap

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
