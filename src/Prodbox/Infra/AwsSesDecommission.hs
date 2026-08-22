{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Exact SES decommission ownership boundary.
--
-- The current @pulumi/aws-ses/Main.yaml@ program owns only non-credential
-- SES/Route53/S3 provider resources. Historical SMTP IAM URNs are migration
-- evidence, never current Provider ownership. The broad destroy primitive is
-- still indexed as 'AwsSesWholePulumiStack', and cannot be supplied to
-- 'awsSesProviderStackCapability', whose argument must be indexed
-- 'AwsSesProviderOnly'.  The provider-only production constructor uses
-- Pulumi's exact target URNs and audits the SMTP URNs before/after; it never
-- lowers or relabels the broad destroy.  This decommission-only split does not
-- migrate steady-state SMTP ownership (Sprint 8.11 remains its sole owner).
--
-- Explicit SMTP IAM teardown is exact: it removes every access key from the
-- fixed user, its fixed inline policy, and then the user.  A separate
-- authoritative @iam get-user@ read-back confirms absence.  Only
-- @NoSuchEntity@ is absence; all other command failures remain unreachable.
module Prodbox.Infra.AwsSesDecommission
  ( AwsSesDecommissionScope (..)
  , AwsSesOwnedFamily (..)
  , AwsSesDecommissionPrimitive
  , awsSesPulumiStackOwnedFamilies
  , awsSesPulumiStackDestroyPrimitive
  , awsSesProviderStackDestroyPrimitive
  , awsSesProviderStackDestroyPrimitiveWith
  , awsSesProviderStackCapability
  , awsSesSmtpIamDestroyPrimitive
  , awsSesSmtpIamDestroyPrimitiveWith
  , applyAwsSesSmtpIamDestroyPrimitive
  , observeAwsSesSmtpIamDestroyPrimitive
  , awsSesSmtpIamEnvironmentForCredentials
  , awsSesSmtpJointAuthorization
  , observeAwsSesSmtpInlinePoliciesWith
  , parseSmtpInlinePolicyNames
  , listInlinePolicyArguments
  , deleteInlinePolicyArguments
  , observeAwsSesSmtpIamWith
  , awsSesSmtpIamCapability
  )
where

import Data.Aeson
  ( Value (Array, Bool, Object, String)
  , eitherDecode
  )
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bifunctor (first)
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.List (isPrefixOf)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Vector qualified as Vector
import Prodbox.Infra.AwsSesSmtpKey
  ( AwsSesSmtpCommandFailure (AwsSesSmtpUserNotFound)
  , classifyAwsSesSmtpCommandResult
  , deleteAwsSesSmtpAccessKeyWith
  , observeAwsSesSmtpKeyInventoryWith
  , renderAwsSesSmtpCommandFailure
  )
import Prodbox.Infra.AwsSesStack
  ( AwsSesPresenceProbe (AwsSesSmtpIamUserProbe)
  , awsSesStackResidueStatus
  , classifyAwsSesPresenceOutput
  , destroyAwsSesProviderResourcesWithCredentials
  , destroyAwsSesStack
  , observeAwsSesProviderResourcesWithCredentials
  )
import Prodbox.Lifecycle.CredentialProvisioner.JointIamDisposition
  ( IamFamilyMember (..)
  , IamMemberObservation (..)
  , JointIamDispositionAuthorization
  , disposeJointIamFamily
  , mkJointIamDispositionAuthorization
  , renderJointIamDispositionRefusal
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass (SesSmtpRetainedCustodyCredential)
  )
import Prodbox.Lifecycle.Decommission.Frame
  ( frameAttemptIdForNode
  , frameNodeIdForContent
  )
import Prodbox.Lifecycle.Decommission.NodeEffect
  ( NodeOperation (NodeOperation, nodeDestroy, nodeReadBack)
  , SesProviderStackCapability (SesProviderStackCapability)
  , SesSmtpIamCapability (SesSmtpIamCapability)
  )
import Prodbox.Lifecycle.ResidueStatus
  ( ObservationFailure (observationFailureDetail, observationFailureOperation)
  , PresenceObservation (PresenceAbsent, PresencePresent, PresenceUnobservable)
  , ResidueDetails (ResidueDetails)
  , ResidueStatus (ResidueAbsent, ResiduePresent, ResidueUnreachable)
  , ResidueUnreachableReason (ResidueQueryFailed)
  )
import Prodbox.Lifecycle.SmtpKeyRepair
  ( SmtpAccessKeyId
  , SmtpKeyInventoryObservation
    ( SmtpKeyInventoryObserved
    , SmtpKeyInventoryOverBound
    , SmtpKeyInventoryPending
    , SmtpKeyInventoryUnobservable
    )
  )
import Prodbox.Result (Result (Failure, Success))
import Prodbox.Settings
  ( Credentials (access_key_id, region, secret_access_key, session_token)
  )
import Prodbox.Subprocess
  ( ProcessOutput
  , Subprocess
    ( Subprocess
    , subprocessArguments
    , subprocessEnvironment
    , subprocessPath
    , subprocessWorkingDirectory
    )
  , captureSubprocessResult
  )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))

-- | Type-level ownership scope.  The broad Pulumi scope and each exact family
-- are intentionally distinct indices.
data AwsSesDecommissionScope
  = AwsSesWholePulumiStack
  | AwsSesProviderOnly
  | AwsSesSmtpIamOnly

-- | Coarse closed ownership audit. The SMTP constructor identifies the
-- separately administered family and is never returned for the Pulumi program.
data AwsSesOwnedFamily
  = AwsSesProviderFamily
  | AwsSesSmtpIamFamily
  deriving (Eq, Ord, Show)

-- | An operation tagged with the exact ownership scope that its constructor
-- controls.  The constructor is private, so a broad stack operation cannot be
-- relabelled as provider-only by a caller.
newtype AwsSesDecommissionPrimitive (scope :: AwsSesDecommissionScope) m
  = AwsSesDecommissionPrimitive (NodeOperation m)

-- | The current authoritative ownership audit of @pulumi/aws-ses/Main.yaml@.
-- @smtpUser@ and @smtpUserPolicy@ make this a two-family destroy.
awsSesPulumiStackOwnedFamilies :: [AwsSesOwnedFamily]
awsSesPulumiStackOwnedFamilies =
  [AwsSesProviderFamily]

-- | The existing harness-owned broad Pulumi destroy.  Its phantom index makes
-- it impossible to bind this value as either family-specific capability.
awsSesPulumiStackDestroyPrimitive
  :: FilePath
  -> Bool
  -> AwsSesDecommissionPrimitive 'AwsSesWholePulumiStack IO
awsSesPulumiStackDestroyPrimitive repoRoot summary =
  AwsSesDecommissionPrimitive
    NodeOperation
      { nodeDestroy = \_ _ -> do
          exitCode <- destroyAwsSesStack repoRoot summary
          pure $ case exitCode of
            ExitSuccess -> Right ()
            ExitFailure code ->
              Left
                ( "broad aws-ses Pulumi destroy exited with code "
                    <> Text.pack (show code)
                )
      , nodeReadBack = \_ _ -> awsSesStackResidueStatus repoRoot
      }

-- | Production provider-only primitive.  Its destructive and observational
-- halves both use the exact target-state boundary; the independently supplied
-- credential is the same ephemeral nuke credential and is never persisted.
awsSesProviderStackDestroyPrimitive
  :: FilePath
  -> Credentials
  -> AwsSesDecommissionPrimitive 'AwsSesProviderOnly IO
awsSesProviderStackDestroyPrimitive repoRoot credentials =
  awsSesProviderStackDestroyPrimitiveWith
    (first Text.pack <$> destroyAwsSesProviderResourcesWithCredentials repoRoot credentials)
    (observeAwsSesProviderResourcesWithCredentials repoRoot credentials)

-- | Injectable provider-only primitive used by response-loss/read-back tests.
-- Keeping the two effects separate ensures receipt recovery can observe
-- without accidentally acquiring another destroy.
awsSesProviderStackDestroyPrimitiveWith
  :: (Monad m)
  => m (Either Text ())
  -> m ResidueStatus
  -> AwsSesDecommissionPrimitive 'AwsSesProviderOnly m
awsSesProviderStackDestroyPrimitiveWith destroyProvider observeProvider =
  AwsSesDecommissionPrimitive
    NodeOperation
      { nodeDestroy = \_ _ -> destroyProvider
      , nodeReadBack = \_ _ -> observeProvider
      }

-- | The only lowering from a provider-only SES primitive.  The constructor
-- above is disjoint from the broad whole-stack primitive by its phantom index.
awsSesProviderStackCapability
  :: AwsSesDecommissionPrimitive 'AwsSesProviderOnly m
  -> SesProviderStackCapability m
awsSesProviderStackCapability (AwsSesDecommissionPrimitive operation) =
  SesProviderStackCapability operation

-- | Production exact SMTP-IAM primitive using the repository subprocess
-- boundary.  It overlays only the explicitly supplied, ephemeral credential
-- onto the process environment; ambient AWS credential discovery is removed.
awsSesSmtpIamDestroyPrimitive
  :: FilePath
  -> Credentials
  -> IO (AwsSesDecommissionPrimitive 'AwsSesSmtpIamOnly IO)
awsSesSmtpIamDestroyPrimitive workingDirectory credentials = do
  baseEnvironment <- getEnvironment
  pure
    ( awsSesSmtpIamDestroyPrimitiveWith
        captureSubprocessResult
        workingDirectory
        (awsSesSmtpIamEnvironmentForCredentials baseEnvironment credentials)
    )

-- | Build the exact AWS CLI environment from the credential acquired by the
-- nuke preparation boundary.  Every ambient @AWS_*@ value is removed before
-- the explicit non-interactive values are installed.
awsSesSmtpIamEnvironmentForCredentials
  :: [(String, String)]
  -> Credentials
  -> [(String, String)]
awsSesSmtpIamEnvironmentForCredentials baseEnvironment credentials =
  explicitCredentialEnvironment
    ++ filter (not . isPrefixOf "AWS_" . fst) baseEnvironment
 where
  explicitCredentialEnvironment =
    [ ("AWS_ACCESS_KEY_ID", Text.unpack (access_key_id credentials))
    , ("AWS_SECRET_ACCESS_KEY", Text.unpack (secret_access_key credentials))
    , ("AWS_REGION", Text.unpack (region credentials))
    , ("AWS_DEFAULT_REGION", Text.unpack (region credentials))
    , ("AWS_EC2_METADATA_DISABLED", "true")
    , ("AWS_PAGER", "")
    , ("AWS_CLI_AUTO_PROMPT", "off")
    ]
      ++ case session_token credentials of
        Nothing -> []
        Just token -> [("AWS_SESSION_TOKEN", Text.unpack token)]

-- | Injectable exact SMTP-IAM primitive for deterministic tests.
awsSesSmtpIamDestroyPrimitiveWith
  :: (Monad m)
  => (Subprocess -> m (Result ProcessOutput))
  -> FilePath
  -> [(String, String)]
  -> AwsSesDecommissionPrimitive 'AwsSesSmtpIamOnly m
awsSesSmtpIamDestroyPrimitiveWith runProcess workingDirectory environment =
  AwsSesDecommissionPrimitive
    NodeOperation
      { nodeDestroy = \_ _ ->
          destroyAwsSesSmtpIamWith runProcess workingDirectory environment
      , nodeReadBack = \_ _ ->
          observeAwsSesSmtpIamWith runProcess workingDirectory environment
      }

-- | Lower only an exact SMTP-IAM primitive into the closed decommission
-- capability vocabulary.
awsSesSmtpIamCapability
  :: AwsSesDecommissionPrimitive 'AwsSesSmtpIamOnly m
  -> SesSmtpIamCapability m
awsSesSmtpIamCapability (AwsSesDecommissionPrimitive operation) =
  SesSmtpIamCapability operation

-- | Execute only the mutation half of an exact SMTP-IAM primitive under a
-- stable Admin Action operation identity.  The phantom scope prevents the
-- broad Pulumi or provider family from reaching this entrypoint.
applyAwsSesSmtpIamDestroyPrimitive
  :: (Monad m)
  => AwsSesDecommissionPrimitive 'AwsSesSmtpIamOnly m
  -> Text
  -> m (Either Text ())
applyAwsSesSmtpIamDestroyPrimitive (AwsSesDecommissionPrimitive operation) operationId =
  nodeDestroy operation nodeId attemptId
 where
  nodeId = frameNodeIdForContent (TextEncoding.encodeUtf8 ("admin-ses-smtp-iam:" <> operationId))
  attemptId = frameAttemptIdForNode nodeId

-- | Authoritatively observe the exact SMTP-IAM family under the same stable
-- identity used by 'applyAwsSesSmtpIamDestroyPrimitive'.
observeAwsSesSmtpIamDestroyPrimitive
  :: (Monad m)
  => AwsSesDecommissionPrimitive 'AwsSesSmtpIamOnly m
  -> Text
  -> m ResidueStatus
observeAwsSesSmtpIamDestroyPrimitive (AwsSesDecommissionPrimitive operation) operationId =
  nodeReadBack operation nodeId attemptId
 where
  nodeId = frameNodeIdForContent (TextEncoding.encodeUtf8 ("admin-ses-smtp-iam:" <> operationId))
  attemptId = frameAttemptIdForNode nodeId

-- | Sprint 7.36: destroy the SMTP principal, its inline policies, and its key
-- family as one disposition.
--
-- Two defects produced the observed live residue — a retained SMTP principal
-- present with zero access keys and an inline policy still attached — and both
-- are closed here.
--
--   * The sequence abandoned its remainder on the first failure, so a partial
--     destroy reported failure without saying what survived.
--   * The inline policy was addressed by an authored name that the registered
--     credential descriptor does not declare, so the delete removed nothing and
--     IAM then refused every subsequent principal delete for as long as the
--     real policy stayed attached.
--
-- Every member is now attempted, the inline policies are enumerated from IAM
-- rather than named, and success is minted only from the joint read-back in
-- which every member is independently absent.
destroyAwsSesSmtpIamWith
  :: (Monad m)
  => (Subprocess -> m (Result ProcessOutput))
  -> FilePath
  -> [(String, String)]
  -> m (Either Text ())
destroyAwsSesSmtpIamWith runProcess workingDirectory environment = do
  keyObservation <-
    observeAwsSesSmtpKeyInventoryWith runProcess workingDirectory environment
  case smtpKeysForDestroy keyObservation of
    Left _ -> pure ()
    Right Nothing -> pure ()
    Right (Just keyIds) -> mapM_ attemptKeyDelete keyIds
  policies <-
    observeAwsSesSmtpInlinePoliciesWith runProcess workingDirectory environment
  case policies of
    Left _ -> pure ()
    Right Nothing -> pure ()
    Right (Just names) -> mapM_ attemptPolicyDelete names
  _ <- runProcess (awsCommand workingDirectory environment deleteUserArguments)
  residue <- observeAwsSesSmtpIamWith runProcess workingDirectory environment
  pure $ case residue of
    ResidueAbsent -> Right ()
    ResiduePresent details ->
      Left
        ( "SES SMTP IAM family read-back did not confirm absence: "
            <> Text.pack (show details)
        )
    ResidueUnreachable reason ->
      Left
        ( "SES SMTP IAM family read-back did not confirm absence; it is \
          \unobservable: "
            <> Text.pack (show reason)
        )
 where
  attemptKeyDelete keyId = do
    _ <-
      deleteAwsSesSmtpAccessKeyWith
        runProcess
        workingDirectory
        environment
        keyId
    pure ()
  attemptPolicyDelete name = do
    _ <-
      runProcess
        ( awsCommand
            workingDirectory
            environment
            (deleteInlinePolicyArguments (Text.unpack name))
        )
    pure ()

-- | The SMTP principal's actual inline policies.
--
-- @Right Nothing@ means the principal itself is not there, so it owns no
-- policy; @Right (Just names)@ is the enumerated family. A truncated listing is
-- a failure rather than a short list, because a short list read as \"no policies
-- left\" is precisely the residue this path exists to remove.
observeAwsSesSmtpInlinePoliciesWith
  :: (Monad m)
  => (Subprocess -> m (Result ProcessOutput))
  -> FilePath
  -> [(String, String)]
  -> m (Either Text (Maybe [Text]))
observeAwsSesSmtpInlinePoliciesWith runProcess workingDirectory environment = do
  result <-
    runProcess (awsCommand workingDirectory environment listInlinePolicyArguments)
  pure $ case classifyAwsSesSmtpCommandResult result of
    Left (AwsSesSmtpUserNotFound _) -> Right Nothing
    Left failure -> Left (renderAwsSesSmtpCommandFailure failure)
    Right output -> Just <$> parseSmtpInlinePolicyNames output

parseSmtpInlinePolicyNames :: String -> Either Text [Text]
parseSmtpInlinePolicyNames payload =
  case eitherDecode (BL8.pack payload) of
    Left err ->
      Left (Text.pack ("invalid IAM inline-policy listing JSON: " ++ err))
    Right value -> case value of
      Object obj -> do
        truncatedFlag <- case KeyMap.lookup "IsTruncated" obj of
          Nothing -> Right False
          Just (Bool flag) -> Right flag
          Just _ -> Left "IAM inline-policy listing `IsTruncated` is not a boolean"
        if truncatedFlag
          then Left "IAM inline-policy listing was truncated"
          else case KeyMap.lookup "PolicyNames" obj of
            Just (Array names) ->
              traverse smtpInlinePolicyName (Vector.toList names)
            Just _ -> Left "IAM inline-policy listing `PolicyNames` is not an array"
            Nothing -> Left "IAM inline-policy listing has no `PolicyNames` key"
      _ -> Left "IAM inline-policy listing is not a JSON object"

smtpInlinePolicyName :: Value -> Either Text Text
smtpInlinePolicyName value = case value of
  String name -> Right name
  _ -> Left "IAM inline-policy listing contains a non-string name"

-- | The joint authorization for the retained SMTP custody credential.
--
-- It owns no assumed role, so the family is the key set, the inline-policy set,
-- and the principal.
awsSesSmtpJointAuthorization :: Either Text JointIamDispositionAuthorization
awsSesSmtpJointAuthorization =
  first
    (Text.pack . show)
    (mkJointIamDispositionAuthorization SesSmtpRetainedCustodyCredential Nothing)

smtpKeysForDestroy
  :: SmtpKeyInventoryObservation
  -> Either Text (Maybe [SmtpAccessKeyId])
smtpKeysForDestroy observation = case observation of
  SmtpKeyInventoryObserved keyIds -> Right (Just keyIds)
  -- This constructor is produced by the exact adapter only when AWS returns
  -- NoSuchEntity for the fixed user.  For desired-present reconciliation that
  -- means "pending"; for desired-absent reconciliation it is final absence.
  SmtpKeyInventoryPending _ -> Right Nothing
  SmtpKeyInventoryUnobservable detail ->
    Left ("cannot observe SES SMTP IAM access keys: " <> detail)
  SmtpKeyInventoryOverBound actual maximumAllowed ->
    Left
      ( "SES SMTP IAM access-key inventory exceeded the AWS bound: observed "
          <> Text.pack (show actual)
          <> ", maximum "
          <> Text.pack (show maximumAllowed)
      )

-- | Sprint 7.36: the read-back is total over the SMTP IAM family.
--
-- It used to ask only whether the principal was there. A principal that IAM
-- refuses to delete because an inline policy survives is present, so that
-- narrower question happened to catch this residue; a principal deleted while
-- its keys or policies were somehow orphaned would not have been caught at all.
-- Absence is now minted only when every member of the family is independently
-- absent.
observeAwsSesSmtpIamWith
  :: (Monad m)
  => (Subprocess -> m (Result ProcessOutput))
  -> FilePath
  -> [(String, String)]
  -> m ResidueStatus
observeAwsSesSmtpIamWith runProcess workingDirectory environment = do
  userResult <-
    runProcess (awsCommand workingDirectory environment observeUserArguments)
  keyObservation <-
    observeAwsSesSmtpKeyInventoryWith runProcess workingDirectory environment
  policies <-
    observeAwsSesSmtpInlinePoliciesWith runProcess workingDirectory environment
  pure $ case awsSesSmtpJointAuthorization of
    Left detail -> ResidueUnreachable (ResidueQueryFailed (Text.unpack detail))
    Right authorization ->
      case disposeJointIamFamily
        authorization
        [ (IamPrincipal, principalObservation userResult)
        , (IamAccessKeyFamily, keyFamilyObservation keyObservation)
        , (IamInlinePolicyFamily, policyFamilyObservation policies)
        ] of
        Right _ -> ResidueAbsent
        Left refusal ->
          case ( principalObservation userResult
               , keyFamilyObservation keyObservation
               , policyFamilyObservation policies
               ) of
            (IamMemberPresent, _, _) -> presentResidue refusal
            (_, IamMemberPresent, _) -> presentResidue refusal
            (_, _, IamMemberPresent) -> presentResidue refusal
            _ ->
              ResidueUnreachable
                (ResidueQueryFailed (Text.unpack (renderJointIamDispositionRefusal refusal)))
 where
  presentResidue refusal =
    ResiduePresent
      ( ResidueDetails
          (Text.unpack (renderJointIamDispositionRefusal refusal))
          "aws-ses-smtp-iam"
      )
  principalObservation result = case result of
    Failure detail ->
      IamMemberUnobservable
        (Text.pack ("aws iam get-user: failed to start aws: " ++ detail))
    Success output ->
      case classifyAwsSesPresenceOutput AwsSesSmtpIamUserProbe output of
        PresenceAbsent -> IamMemberAbsent
        PresencePresent () -> IamMemberPresent
        PresenceUnobservable failure ->
          IamMemberUnobservable
            ( Text.pack
                ( observationFailureOperation failure
                    ++ ": "
                    ++ observationFailureDetail failure
                )
            )
  keyFamilyObservation observation = case observation of
    SmtpKeyInventoryObserved [] -> IamMemberAbsent
    SmtpKeyInventoryObserved _ -> IamMemberPresent
    SmtpKeyInventoryPending _ -> IamMemberAbsent
    SmtpKeyInventoryUnobservable detail -> IamMemberUnobservable detail
    SmtpKeyInventoryOverBound actual maximumAllowed ->
      IamMemberUnobservable
        ( "SES SMTP IAM access-key inventory exceeded the AWS bound: observed "
            <> Text.pack (show actual)
            <> ", maximum "
            <> Text.pack (show maximumAllowed)
        )
  policyFamilyObservation observed = case observed of
    Left detail -> IamMemberUnobservable detail
    Right Nothing -> IamMemberAbsent
    Right (Just []) -> IamMemberAbsent
    Right (Just _) -> IamMemberPresent

awsCommand :: FilePath -> [(String, String)] -> [String] -> Subprocess
awsCommand workingDirectory environment arguments =
  Subprocess
    { subprocessPath = "aws"
    , subprocessArguments = arguments
    , subprocessEnvironment = Just environment
    , subprocessWorkingDirectory = Just workingDirectory
    }

-- | Sprint 7.36: the policy name is the enumerated one, never an authored
-- constant. The authored constant this replaced named a policy the creator does
-- not write, so the delete removed nothing.
deleteInlinePolicyArguments :: String -> [String]
deleteInlinePolicyArguments policyName =
  [ "iam"
  , "delete-user-policy"
  , "--user-name"
  , "prodbox-ses-smtp"
  , "--policy-name"
  , policyName
  ]

listInlinePolicyArguments :: [String]
listInlinePolicyArguments =
  [ "iam"
  , "list-user-policies"
  , "--user-name"
  , "prodbox-ses-smtp"
  , "--output"
  , "json"
  ]

deleteUserArguments :: [String]
deleteUserArguments =
  [ "iam"
  , "delete-user"
  , "--user-name"
  , "prodbox-ses-smtp"
  ]

observeUserArguments :: [String]
observeUserArguments =
  [ "iam"
  , "get-user"
  , "--user-name"
  , "prodbox-ses-smtp"
  , "--output"
  , "json"
  ]
