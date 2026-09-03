{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Read-only production evidence for recovering one expired Authorized
-- AWS-admin attempt. The observer can GET only the exact bound Job and Pod and
-- read only the permit-derived execution-journal coordinate. It has no
-- Kubernetes or Vault mutation capability.
module Prodbox.ControlPlane.AwsAdminAuthorizedRecoveryProduction
  ( productionProveAwsAdminAuthorizedRecovery
  , classifyAwsAdminRecoveryJournalObservation
  , classifyAwsAdminAttemptResourceHttpStatus
  )
where

import Control.Exception (try)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.X509.CertificateStore (readCertificateStore)
import Network.Connection (TLSSettings (..))
import Network.HTTP.Client
  ( HttpException
  , Manager
  , Request (..)
  , newManager
  , parseRequest
  , responseStatus
  , responseTimeoutMicro
  , withResponse
  )
import Network.HTTP.Client.TLS (mkManagerSettings)
import Network.HTTP.Types.Status (statusCode)
import Network.TLS
  ( ClientParams (..)
  , Shared (..)
  , defaultParamsClient
  )
import Prodbox.CLI.Output (writeDiagnosticLine)
import Prodbox.Gateway.Emitter.KubernetesLease
  ( projectedTokenSupplierAt
  )
import Prodbox.K8s.InCluster
  ( inClusterCaCertPath
  , inClusterTokenPath
  , secretApiBaseUrl
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminAuthority
  ( AwsAdminAttemptJournalObservation (..)
  , AwsAdminAttemptResourceObservation (..)
  , AwsAdminAuthorityState (AwsAdminAuthorityAuthorized)
  , AwsAdminAuthorizedRecoveryError
  , AwsAdminAuthorizedRecoveryProof
  , AwsAdminRecoveryCleanupPhase (..)
  , proveAwsAdminAuthorizedRecovery
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecutionVault
  ( AwsAdminExecutionJournalPhaseCause (..)
  , AwsAdminExecutionJournalRecoveryFlag (..)
  , AwsAdminExecutionJournalRecoveryObservation (..)
  , observeAwsAdminExecutionJournalRecovery
  , renderAwsAdminExecutionJournalRecoveryObservation
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( SignedAwsAdminPermit
  , awsAdminJobName
  , awsAdminJobPodName
  , signedAwsAdminPermitBinding
  )
import Prodbox.Lifecycle.Lease (AuthorityTime)
import Prodbox.Vault.Session (VaultSession)
import System.Timeout (timeout)

productionProveAwsAdminAuthorizedRecovery
  :: VaultSession
  -> AuthorityTime
  -> SignedAwsAdminPermit
  -> IO
       ( Either
           AwsAdminAuthorizedRecoveryError
           AwsAdminAuthorizedRecoveryProof
       )
productionProveAwsAdminAuthorizedRecovery session now permit = do
  (jobObservation, podObservation) <- observeExactWorkloads permit
  journalObservation <- observeAwsAdminExecutionJournalRecovery session permit
  writeDiagnosticLine
    ( Text.unpack
        ( "aws-admin/recovery journal-observation="
            <> renderAwsAdminExecutionJournalRecoveryObservation journalObservation
        )
    )
  pure
    ( proveAwsAdminAuthorizedRecovery
        now
        (AwsAdminAuthorityAuthorized permit)
        jobObservation
        podObservation
        (classifyAwsAdminRecoveryJournalObservation journalObservation)
    )

classifyAwsAdminRecoveryJournalObservation
  :: AwsAdminExecutionJournalRecoveryObservation
  -> AwsAdminAttemptJournalObservation
classifyAwsAdminRecoveryJournalObservation observation = case observation of
  AwsAdminExecutionJournalRecoveryAbsent -> AwsAdminAttemptJournalAbsent
  AwsAdminExecutionJournalRecoveryPresent
    (AwsAdminExecutionJournalIntentCommitted AwsAdminExecutionInitialAttempt) ->
      AwsAdminAttemptJournalInitialIntentCommitted
  AwsAdminExecutionJournalRecoveryPresent
    (AwsAdminExecutionJournalIntentCommitted AwsAdminExecutionRemintUsed) ->
      cleanup AwsAdminRecoveryIntentCommittedRemintUsed
  AwsAdminExecutionJournalRecoveryPresent
    (AwsAdminExecutionJournalCreateAttemptPrepared AwsAdminExecutionInitialAttempt) ->
      cleanup AwsAdminRecoveryCreateAttemptPreparedInitial
  AwsAdminExecutionJournalRecoveryPresent
    (AwsAdminExecutionJournalCreateAttemptPrepared AwsAdminExecutionRemintUsed) ->
      cleanup AwsAdminRecoveryCreateAttemptPreparedRemintUsed
  AwsAdminExecutionJournalRecoveryPresent
    (AwsAdminExecutionJournalKeyCreated AwsAdminExecutionInitialAttempt) ->
      cleanup AwsAdminRecoveryKeyCreatedInitial
  AwsAdminExecutionJournalRecoveryPresent
    (AwsAdminExecutionJournalKeyCreated AwsAdminExecutionRemintUsed) ->
      cleanup AwsAdminRecoveryKeyCreatedRemintUsed
  AwsAdminExecutionJournalRecoveryPresent
    (AwsAdminExecutionJournalCleanupRequired AwsAdminExecutionInitialAttempt) ->
      cleanup AwsAdminRecoveryCleanupRequiredInitial
  AwsAdminExecutionJournalRecoveryPresent
    (AwsAdminExecutionJournalCleanupRequired AwsAdminExecutionRemintUsed) ->
      cleanup AwsAdminRecoveryCleanupRequiredRemintUsed
  AwsAdminExecutionJournalRecoveryPresent
    (AwsAdminExecutionJournalCleanupProven AwsAdminExecutionInitialAttempt) ->
      cleanup AwsAdminRecoveryCleanupProvenInitial
  AwsAdminExecutionJournalRecoveryPresent
    (AwsAdminExecutionJournalCleanupProven AwsAdminExecutionRemintUsed) ->
      cleanup AwsAdminRecoveryCleanupProvenRemintUsed
  AwsAdminExecutionJournalRecoveryPresent _ -> AwsAdminAttemptJournalPresent
  AwsAdminExecutionJournalRecoveryPermitMismatch -> AwsAdminAttemptJournalPresent
  AwsAdminExecutionJournalRecoveryInvalid -> AwsAdminAttemptJournalPresent
  AwsAdminExecutionJournalRecoveryUnobservable _ -> AwsAdminAttemptJournalUnobservable
 where
  cleanup = AwsAdminAttemptJournalCleanupContinuation

observeExactWorkloads
  :: SignedAwsAdminPermit
  -> IO
       ( AwsAdminAttemptResourceObservation
       , AwsAdminAttemptResourceObservation
       )
observeExactWorkloads permit = do
  managerResult <- kubernetesManager
  case managerResult of
    Nothing ->
      pure
        ( AwsAdminAttemptResourceUnobservable
        , AwsAdminAttemptResourceUnobservable
        )
    Just manager -> do
      let binding = signedAwsAdminPermitBinding permit
          tokenSupplier = projectedTokenSupplierAt inClusterTokenPath
      job <-
        observeNamedObject
          manager
          tokenSupplier
          ( "/apis/batch/v1/namespaces/credential-provisioner/jobs/"
              <> Text.unpack (awsAdminJobName binding)
          )
      pod <-
        observeNamedObject
          manager
          tokenSupplier
          ( "/api/v1/namespaces/credential-provisioner/pods/"
              <> Text.unpack (awsAdminJobPodName binding)
          )
      pure (job, pod)

kubernetesManager :: IO (Maybe Manager)
kubernetesManager = do
  storeResult <- try (readCertificateStore inClusterCaCertPath)
  case storeResult of
    Left (_ :: IOError) -> pure Nothing
    Right Nothing -> pure Nothing
    Right (Just store) -> do
      let host = "kubernetes.default.svc.cluster.local"
          baseParams = defaultParamsClient host ""
          clientParams =
            baseParams
              { clientShared =
                  (clientShared baseParams) {sharedCAStore = store}
              }
      managerResult <-
        try
          (newManager (mkManagerSettings (TLSSettings clientParams) Nothing))
      pure $ case managerResult of
        Left (_ :: IOError) -> Nothing
        Right manager -> Just manager

observeNamedObject
  :: Manager
  -> IO (Either Text Text)
  -> String
  -> IO AwsAdminAttemptResourceObservation
observeNamedObject manager tokenSupplier path = do
  tokenResult <- tokenSupplier
  case tokenResult of
    Left _ -> pure AwsAdminAttemptResourceUnobservable
    Right token -> do
      parsed <- try (parseRequest (secretApiBaseUrl <> path))
      case parsed of
        Left (_ :: HttpException) -> pure AwsAdminAttemptResourceUnobservable
        Right baseRequest -> do
          let request =
                baseRequest
                  { method = "GET"
                  , requestHeaders =
                      [ ("Accept", "application/json")
                      ,
                        ( "Authorization"
                        , TextEncoding.encodeUtf8 ("Bearer " <> token)
                        )
                      ]
                  , responseTimeout =
                      responseTimeoutMicro kubernetesObservationTimeoutMicros
                  }
          completed <-
            timeout
              kubernetesObservationTimeoutMicros
              ( try
                  (withResponse request manager (pure . statusCode . responseStatus))
                  :: IO (Either HttpException Int)
              )
          pure $ case completed of
            Just (Right code) -> classifyAwsAdminAttemptResourceHttpStatus code
            _ -> AwsAdminAttemptResourceUnobservable

classifyAwsAdminAttemptResourceHttpStatus
  :: Int -> AwsAdminAttemptResourceObservation
classifyAwsAdminAttemptResourceHttpStatus code = case code of
  200 -> AwsAdminAttemptResourcePresent
  404 -> AwsAdminAttemptResourceAbsent
  _ -> AwsAdminAttemptResourceUnobservable

kubernetesObservationTimeoutMicros :: Int
kubernetesObservationTimeoutMicros = 5 * 1000 * 1000
