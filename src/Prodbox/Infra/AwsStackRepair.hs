{-# LANGUAGE OverloadedStrings #-}

-- | Operator repair clients. Provider effects remain Authority submissions.
module Prodbox.Infra.AwsStackRepair
  ( runAwsStackDiff
  , runStackDiffVia
  , loadStackRepairConfig
  , runAwsNetworkPurge
  , runNetworkPurgeVia
  )
where

import Data.Bifunctor (first)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.CLI.Output (writeDiagnosticLine, writeOutputLine)
import Prodbox.ControlPlane.LifecycleAuthorityAuthentication
  ( ExternalLifecycleAuthorityCaller (LifecycleAuthorityOperator)
  , renderLifecycleAuthorityAuthenticationError
  , withHostLifecycleAuthorityAuthentication
  )
import Prodbox.ControlPlane.ProviderCaller
  ( dispatchAuthenticatedProviderIntentFresh
  , dispatchHostProviderIntentExecutedOwnedBy
  , freshProviderSubmissionKey
  , renderProviderCallerError
  )
import Prodbox.Infra.AwsEksSubzoneStack (loadAwsEksSubzoneProviderConfig)
import Prodbox.Infra.AwsEksTestStack (loadAwsEksProviderConfig)
import Prodbox.Infra.AwsTestStack (loadAwsTestProviderConfig)
import Prodbox.Lifecycle.Authority.Admission
  ( ProviderOperationCleanupOwner (ProviderOperationUnownedByCleanupRun)
  )
import Prodbox.Lifecycle.AwsAudit
  ( AuditClass (..)
  , AuditVerdict (..)
  , auditExitCode
  , auditVerdictLabel
  )
import Prodbox.Lifecycle.AwsNetworkPurge
import Prodbox.Lifecycle.AwsRemedy
import Prodbox.Lifecycle.AwsStackDiff
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (..)
  , ProviderNetworkPurgeMode (..)
  , ProviderStackConfig
  , mkAwsSesPreviewStackConfig
  , mkProviderNetworkPurgeRef
  , mkProviderStackRef
  , validateProviderStackConfig
  )
import Prodbox.Lifecycle.Teardown.ProviderAwsScopeAdapter (decodeProviderAwsScopeResponse)
import Prodbox.Settings
  ( ValidatedCoordinates (..)
  , ValidatedSettings (validatedCoordinates)
  , validateAndLoadSettings
  )
import Prodbox.Settings.Coordinate (dnsLabelText, s3BucketNameText)
import Prodbox.Tls.CertScope (fqdnText)
import System.Exit (ExitCode (..))

-- | Scope observation is supplied separately so its authenticated execution
-- kind and coordinate can be checked before any repair request is constructed.
runNetworkPurgeVia
  :: (Monad m)
  => (ProviderIntent -> m (Either Text Text))
  -> Text
  -> Text
  -> ProviderStackConfig
  -> ProviderNetworkPurgeMode
  -> m (Either Text (Maybe AuditVerdict, [Text]))
runNetworkPurgeVia dispatch account region config mode =
  case ( mkProviderNetworkPurgeRef account region mode
       , mkProviderNetworkPurgeRef account region NetworkPurgePlan
       ) of
    (Right selected, Right observer) -> do
      initial <- dispatch (ObserveNativeStackFamily observer config)
      case initial >>= decodeNetworkPurgeReport account region of
        Left detail -> pure (Left detail)
        Right planned -> case mode of
          NetworkPurgePlan -> pure (Right (Nothing, renderNetworkPurgeReport planned))
          NetworkPurgeApply digest
            | digest /= purgeReportDigest planned ->
                pure (Left "network purge plan changed; render and confirm a new plan digest")
            | otherwise -> do
                applied <- dispatch (ReapNativeStackFamily selected config [])
                -- A failed mutation still gets a fresh closing observation.
                observed <- dispatch (ObserveNativeStackFamily observer config)
                pure $ do
                  evidence <- observed
                  report <- decodeNetworkPurgeReport account region evidence
                  if purgeReportVpc report == purgeReportVpc planned
                    then Right ()
                    else Left "network purge VPC changed before the independent read-back"
                  let counts = purgeReportCounts report
                      verdict =
                        if all ((== 0) . snd) counts
                          then AuditClean
                          else
                            AuditResidue
                              (Map.fromList [(classFor family, fromIntegral count) | (family, count) <- counts, count > 0])
                  case applied of
                    Left _
                      | verdict == AuditClean ->
                          Left "network purge apply was refused; the independent network-family read-back is Clean"
                    _ -> Right ()
                  let status =
                        [ "AWS_NETWORK_PURGE_VERDICT="
                            <> auditVerdictLabel verdict
                            <> " field=registered-eks-network-families"
                        ]
                      failure =
                        either
                          (const ["network purge apply did not complete; the closing verdict is independent"])
                          (const [])
                          applied
                  Right (Just verdict, renderNetworkPurgeReport report ++ failure ++ status)
    _ -> pure (Left "network purge scope or plan digest is invalid")
 where
  classFor "aws-eks-vpc-cni-interfaces" = AuditNetworkInterface
  classFor _ = AuditSecurityGroup

runAwsNetworkPurge :: FilePath -> ProviderNetworkPurgeMode -> IO ExitCode
runAwsNetworkPurge repoRoot mode = do
  config <- loadStackRepairConfig repoRoot AwsEksTarget
  case config of
    Left detail -> refused detail
    Right validated -> do
      key <- freshProviderSubmissionKey "operator-network-purge-scope"
      scope <-
        dispatchHostProviderIntentExecutedOwnedBy
          LifecycleAuthorityOperator
          repoRoot
          key
          ObserveProviderAwsScope
          ProviderOperationUnownedByCleanupRun
      case first (Text.pack . renderProviderCallerError) scope >>= decodeProviderAwsScopeResponse of
        Left detail -> refused detail
        Right (account, region) -> do
          authenticated <- withHostLifecycleAuthorityAuthentication LifecycleAuthorityOperator repoRoot $ \authentication -> do
            result <-
              runNetworkPurgeVia
                ( \intent ->
                    first (Text.pack . renderProviderCallerError)
                      <$> dispatchAuthenticatedProviderIntentFresh authentication "operator-network-purge" intent
                )
                account
                region
                validated
                mode
            case result of
              Left detail -> refused detail
              Right (verdict, report) -> do
                mapM_ (writeOutputLine . Text.unpack) report
                pure (maybe ExitSuccess auditExitCode verdict)
          either (refused . Text.pack . renderLifecycleAuthorityAuthenticationError) pure authenticated
 where
  refused detail = writeDiagnosticLine (Text.unpack detail) >> pure (ExitFailure 5)

loadStackRepairConfig :: FilePath -> AwsStackTarget -> IO (Either Text ProviderStackConfig)
loadStackRepairConfig repoRoot target = case target of
  AwsEksTarget -> first Text.pack <$> loadAwsEksProviderConfig repoRoot
  AwsTestTarget -> first Text.pack <$> loadAwsTestProviderConfig repoRoot
  AwsSubzoneTarget -> first Text.pack <$> loadAwsEksSubzoneProviderConfig repoRoot
  AwsSesTarget -> do
    loaded <- validateAndLoadSettings repoRoot
    pure $ do
      settings <- first Text.pack loaded
      let coordinates = validatedCoordinates settings
      sender <- required "ses.sender_domain" (fqdnText <$> coordinateSesSenderDomain coordinates)
      label <-
        required "ses.receive_subdomain" (dnsLabelText <$> coordinateSesReceiveSubdomain coordinates)
      bucket <-
        required "ses.capture_bucket" (s3BucketNameText <$> coordinateSesCaptureBucket coordinates)
      first (Text.pack . show) (mkAwsSesPreviewStackConfig sender (label <> "." <> sender) bucket)
 where
  required name = maybe (Left (name <> " must be authored for stack diff")) Right

runStackDiffVia
  :: (Monad m)
  => (ProviderIntent -> m (Either Text Text))
  -> AwsStackTarget
  -> ProviderStackConfig
  -> m (Either Text [Text])
runStackDiffVia dispatch target config =
  case mkProviderStackRef (awsStackRegistryName target) of
    Left _ -> pure (Left "stack diff reference is invalid")
    Right ref -> case validateProviderStackConfig ref config of
      Left _ -> pure (Left "stack diff configuration differs from the selected stack")
      Right () -> do
        observed <- dispatch (PreviewRegisteredStack ref config)
        pure $ do
          evidence <- observed
          preview <- decodeStackPreviewEvidence (awsStackRegistryName target) evidence
          Right (renderStackPreview (awsStackRegistryName target) preview)

runAwsStackDiff :: FilePath -> AwsStackTarget -> IO ExitCode
runAwsStackDiff repoRoot target = do
  config <- loadStackRepairConfig repoRoot target
  case config of
    Left detail -> refused detail
    Right validated -> do
      authenticated <-
        withHostLifecycleAuthorityAuthentication LifecycleAuthorityOperator repoRoot $ \authentication -> do
          result <-
            runStackDiffVia
              ( \intent ->
                  first (Text.pack . renderProviderCallerError)
                    <$> dispatchAuthenticatedProviderIntentFresh authentication "operator-stack-diff" intent
              )
              target
              validated
          case result of
            Left detail -> refused detail
            Right report -> mapM_ (writeOutputLine . Text.unpack) report >> pure ExitSuccess
      either (refused . Text.pack . renderLifecycleAuthorityAuthenticationError) pure authenticated
 where
  refused detail = do
    writeDiagnosticLine (Text.unpack detail)
    pure (ExitFailure 5)
