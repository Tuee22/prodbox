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
  , awsSesSmtpIamCapability
  )
where

import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (ExceptT), runExceptT)
import Data.Bifunctor (first)
import Data.List (isPrefixOf)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
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
  , SmtpKeyCleanupResult (SmtpKeyDeleteFailed, SmtpKeyDeleted)
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

destroyAwsSesSmtpIamWith
  :: (Monad m)
  => (Subprocess -> m (Result ProcessOutput))
  -> FilePath
  -> [(String, String)]
  -> m (Either Text ())
destroyAwsSesSmtpIamWith runProcess workingDirectory environment =
  runExceptT $ do
    observation <-
      lift
        ( observeAwsSesSmtpKeyInventoryWith
            runProcess
            workingDirectory
            environment
        )
    case smtpKeysForDestroy observation of
      Left detail -> ExceptT (pure (Left detail))
      Right Nothing -> pure ()
      Right (Just keyIds) -> do
        mapM_ deleteKey keyIds
        deleteFixedIamResource deleteInlinePolicyArguments
        deleteFixedIamResource deleteUserArguments
 where
  deleteKey keyId =
    ExceptT $ do
      cleanup <-
        deleteAwsSesSmtpAccessKeyWith
          runProcess
          workingDirectory
          environment
          keyId
      pure (classifyKeyCleanup cleanup)
  deleteFixedIamResource arguments =
    ExceptT
      ( classifyIdempotentDelete
          <$> runProcess (awsCommand workingDirectory environment arguments)
      )

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

classifyKeyCleanup :: SmtpKeyCleanupResult -> Either Text ()
classifyKeyCleanup cleanup = case cleanup of
  SmtpKeyDeleted _ -> Right ()
  SmtpKeyDeleteFailed _ detail -> Left detail

classifyIdempotentDelete :: Result ProcessOutput -> Either Text ()
classifyIdempotentDelete result =
  case classifyAwsSesSmtpCommandResult result of
    Right _ -> Right ()
    Left (AwsSesSmtpUserNotFound _) -> Right ()
    Left failure -> Left (renderAwsSesSmtpCommandFailure failure)

observeAwsSesSmtpIamWith
  :: (Monad m)
  => (Subprocess -> m (Result ProcessOutput))
  -> FilePath
  -> [(String, String)]
  -> m ResidueStatus
observeAwsSesSmtpIamWith runProcess workingDirectory environment = do
  result <-
    runProcess
      (awsCommand workingDirectory environment observeUserArguments)
  pure $ case result of
    Failure detail ->
      ResidueUnreachable
        (ResidueQueryFailed ("aws iam get-user: failed to start aws: " ++ detail))
    Success output -> presenceObservationToResidue (classifyAwsSesPresenceOutput AwsSesSmtpIamUserProbe output)

presenceObservationToResidue :: PresenceObservation () -> ResidueStatus
presenceObservationToResidue observation = case observation of
  PresenceAbsent -> ResidueAbsent
  PresencePresent () ->
    ResiduePresent
      (ResidueDetails "AWS IAM get-user confirmed prodbox-ses-smtp" "aws-ses-smtp-iam")
  PresenceUnobservable failure ->
    ResidueUnreachable
      ( ResidueQueryFailed
          ( observationFailureOperation failure
              ++ ": "
              ++ observationFailureDetail failure
          )
      )

awsCommand :: FilePath -> [(String, String)] -> [String] -> Subprocess
awsCommand workingDirectory environment arguments =
  Subprocess
    { subprocessPath = "aws"
    , subprocessArguments = arguments
    , subprocessEnvironment = Just environment
    , subprocessWorkingDirectory = Just workingDirectory
    }

deleteInlinePolicyArguments :: [String]
deleteInlinePolicyArguments =
  [ "iam"
  , "delete-user-policy"
  , "--user-name"
  , "prodbox-ses-smtp"
  , "--policy-name"
  , "prodbox-ses-smtp-policy"
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
