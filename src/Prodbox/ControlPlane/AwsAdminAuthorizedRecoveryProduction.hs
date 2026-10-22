{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Read-only production evidence for recovering one expired Authorized
-- AWS-admin attempt. The observer can GET only the exact bound Job and Pod and
-- read only the permit-derived execution-journal coordinate. It has no
-- Kubernetes or Vault mutation capability.
module Prodbox.ControlPlane.AwsAdminAuthorizedRecoveryProduction
  ( productionProveAwsAdminAuthorizedRecovery
  , productionProveAwsAdminAttestedRecovery
  , productionObserveExpiredAwsAdminAttemptAbsence
  , productionObserveCredentialWorkerQuiescence
  , fixedAwsAdminCredentialQuiescenceRegression
  , fixedAwsAdminAttestedRecoveryRegression
  , classifyAwsAdminRecoveryJournalObservation
  , classifyAwsAdminAttemptResourceHttpStatus
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (try)
import Data.Aeson (FromJSON (..), Value, eitherDecodeStrict', withObject, (.!=), (.:), (.:?))
import Data.Bifunctor (first)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (isLeft, isRight)
import Data.Functor.Identity (Identity (..))
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.X509.CertificateStore (readCertificateStore)
import Network.Connection (TLSSettings (..))
import Network.HTTP.Client
  ( BodyReader
  , HttpException
  , Manager
  , Request (..)
  , brReadSome
  , newManager
  , parseRequest
  , responseBody
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
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminAttestedRecovery.Internal
  ( AwsAdminAttestedRecoveryProof (..)
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminAuthority
  ( AwsAdminAttemptJournalObservation (..)
  , AwsAdminAttemptResourceObservation (..)
  , AwsAdminAuthorityState
    ( AwsAdminAuthorityAttested
    , AwsAdminAuthorityAuthorized
    , AwsAdminAuthorityPrepared
    )
  , AwsAdminAuthorizedRecoveryError
  , AwsAdminAuthorizedRecoveryProof
  , AwsAdminRecoveryCleanupPhase (..)
  , commitAwsAdminPreparedAttestedRecovery
  , proveAwsAdminAuthorizedRecovery
  , validateAwsAdminAttestedRecovery
  , validateAwsAdminExpiredAttemptAbsence
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminExecutionVault
  ( AwsAdminExecutionJournalPhaseCause (..)
  , AwsAdminExecutionJournalRecoveryFlag (..)
  , AwsAdminExecutionJournalRecoveryObservation (..)
  , observeAwsAdminExecutionJournalRecovery
  , renderAwsAdminExecutionJournalRecoveryObservation
  )
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( AwsAdminJobBinding
  , AwsAdminPermitIntent
  , SignedAwsAdminPermit
  , awsAdminJobName
  , awsAdminJobPodName
  , awsAdminPermitIntentDeadline
  , signedAwsAdminPermitBinding
  )
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeFromMicros, authorityTimeMicros)
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
observeExactWorkloads permit = observeBoundWorkloads (signedAwsAdminPermitBinding permit)

productionObserveExpiredAwsAdminAttemptAbsence
  :: AuthorityTime -> SignedAwsAdminPermit -> IO (Either Text ())
productionObserveExpiredAwsAdminAttemptAbsence now permit = do
  (job, pod) <- observeExactWorkloads permit
  pure (first (Text.pack . show) (validateAwsAdminExpiredAttemptAbsence now permit job pod))

data CredentialWorkloadKind = CredentialJobList | CredentialPodList
  deriving (Eq, Show)

data CredentialWorkloadList = CredentialWorkloadList !Text !Text !Text !Text ![Value]

instance FromJSON CredentialWorkloadList where
  parseJSON = withObject "credential workload list" $ \object -> do
    api <- object .: "apiVersion"
    kind <- object .: "kind"
    metadata <- object .: "metadata"
    (revision, continuation) <-
      withObject
        "credential workload list metadata"
        (\fields -> (,) <$> fields .: "resourceVersion" <*> (fields .:? "continue" .!= ""))
        metadata
    CredentialWorkloadList api kind revision continuation <$> object .: "items"

productionObserveCredentialWorkerQuiescence :: IO (Either Text ())
productionObserveCredentialWorkerQuiescence =
  withinCredentialInventoryBudget kubernetesObservationTimeoutMicros $ do
    observedManager <- kubernetesManager
    case observedManager of
      Nothing -> pure (Left "provider-credential/legacy-workloads-unobservable")
      Just manager -> do
        jobs <- observeCredentialWorkloadList manager CredentialJobList
        pods <- observeCredentialWorkloadList manager CredentialPodList
        pure $ case (jobs, pods) of
          (AwsAdminAttemptResourceAbsent, AwsAdminAttemptResourceAbsent) -> Right ()
          (AwsAdminAttemptResourcePresent, _) -> Left "provider-credential/legacy-workloads-present"
          (_, AwsAdminAttemptResourcePresent) -> Left "provider-credential/legacy-workloads-present"
          _ -> Left "provider-credential/legacy-workloads-unobservable"

-- Manager setup, token reads and both inventories share one outer deadline.
-- The individual HTTP bounds cannot grant a second inventory fresh time.
withinCredentialInventoryBudget :: Int -> IO (Either Text ()) -> IO (Either Text ())
withinCredentialInventoryBudget budget observe = do
  completed <- timeout budget observe
  pure $ case completed of
    Just result -> result
    Nothing -> Left "provider-credential/legacy-workloads-unobservable"

credentialWorkloadCoordinates :: CredentialWorkloadKind -> (Text, Text, String)
credentialWorkloadCoordinates kind = case kind of
  CredentialJobList -> ("batch/v1", "JobList", "/apis/batch/v1/namespaces/credential-provisioner/jobs?limit=1")
  CredentialPodList -> ("v1", "PodList", "/api/v1/namespaces/credential-provisioner/pods?limit=1")

classifyCredentialWorkloadList
  :: CredentialWorkloadKind -> Int -> ByteString.ByteString -> AwsAdminAttemptResourceObservation
classifyCredentialWorkloadList expected status bytes
  | status /= 200 || ByteString.length bytes > 65536 = AwsAdminAttemptResourceUnobservable
  | otherwise = case eitherDecodeStrict' bytes of
      Left _ -> AwsAdminAttemptResourceUnobservable
      Right (CredentialWorkloadList api kind revision continuation items)
        | api /= expectedApi || kind /= expectedKind || revision == "" ->
            AwsAdminAttemptResourceUnobservable
        | not (null items) -> AwsAdminAttemptResourcePresent
        | continuation /= "" -> AwsAdminAttemptResourceUnobservable
        | otherwise -> AwsAdminAttemptResourceAbsent
 where
  (expectedApi, expectedKind, _) = credentialWorkloadCoordinates expected

observeCredentialWorkloadList
  :: Manager -> CredentialWorkloadKind -> IO AwsAdminAttemptResourceObservation
observeCredentialWorkloadList manager kind = do
  tokenResult <- projectedTokenSupplierAt inClusterTokenPath
  case tokenResult of
    Left _ -> pure AwsAdminAttemptResourceUnobservable
    Right token -> do
      let (_, _, path) = credentialWorkloadCoordinates kind
      parsed <- try (parseRequest (secretApiBaseUrl <> path))
      case parsed of
        Left (_ :: HttpException) -> pure AwsAdminAttemptResourceUnobservable
        Right base -> do
          let request =
                base
                  { method = "GET"
                  , requestHeaders =
                      [("Accept", "application/json"), ("Authorization", TextEncoding.encodeUtf8 ("Bearer " <> token))]
                  , responseTimeout = responseTimeoutMicro kubernetesObservationTimeoutMicros
                  }
          completed <-
            timeout
              kubernetesObservationTimeoutMicros
              ( try
                  ( withResponse request manager $ \response -> do
                      body <- collectCredentialWorkloadBody (responseBody response)
                      pure (statusCode (responseStatus response), body)
                  )
                  :: IO (Either HttpException (Int, Maybe ByteString.ByteString))
              )
          pure $ case completed of
            Just (Right (status, Just body)) -> classifyCredentialWorkloadList kind status body
            _ -> AwsAdminAttemptResourceUnobservable

collectCredentialWorkloadBody :: BodyReader -> IO (Maybe ByteString.ByteString)
collectCredentialWorkloadBody reader = collect 0 []
 where
  collect total reversed = do
    chunk <- brReadSome reader (65537 - total)
    if LazyByteString.null chunk
      then pure (Just (LazyByteString.toStrict (LazyByteString.concat (reverse reversed))))
      else do
        let after = total + fromIntegral (LazyByteString.length chunk)
        if after > 65536 then pure Nothing else collect after (chunk : reversed)

fixedAwsAdminCredentialQuiescenceRegression :: IO [(Text, Bool)]
fixedAwsAdminCredentialQuiescenceRegression = do
  fragmented <- observeChunks (map ByteString.singleton (ByteString.unpack emptyJobs))
  oversized <- observeChunks [ByteString.replicate 32768 32, ByteString.replicate 32769 32]
  exact <- observeChunks [ByteString.replicate 65536 32]
  empty <- observeChunks []
  secondStarted <- newIORef False
  expired <- withinCredentialInventoryBudget 10000 $ do
    writeIORef secondStarted True
    threadDelay 1000000
    pure (Right ())
  reachedSecond <- readIORef secondStarted
  complete <- withinCredentialInventoryBudget 1000000 (pure (Right ()))
  pure
    ( facts
        ++ [ ("fragmented body is read through EOF", fragmented == Just emptyJobs)
           , ("collector rejects its first overflow byte", oversized == Nothing)
           , ("collector accepts its exact bound", exact == Just (ByteString.replicate 65536 32))
           , ("empty body remains empty rather than an absence claim", empty == Just ByteString.empty)
           ,
             ( "shared inventory deadline cancels an unfinished second read"
             , reachedSecond && expired == Left "provider-credential/legacy-workloads-unobservable"
             )
           , ("shared inventory deadline preserves a completed proof", complete == Right ())
           ]
    )
 where
  observeChunks chunks = do
    remaining <- newIORef chunks
    collectCredentialWorkloadBody
      (atomicModifyIORef' remaining popChunk)
  popChunk pending = case pending of
    [] -> ([], ByteString.empty)
    chunk : rest -> (rest, chunk)
  facts =
    [ (label, classifyCredentialWorkloadList CredentialJobList status body == expected)
    | (label, status, body, expected) <-
        [ ("empty complete Job list is absence", 200, emptyJobs, AwsAdminAttemptResourceAbsent)
        , ("empty Pod list cannot stand for Jobs", 200, emptyPods, AwsAdminAttemptResourceUnobservable)
        ,
          ( "one workload is present"
          , 200
          , "{\"apiVersion\":\"batch/v1\",\"kind\":\"JobList\",\"metadata\":{\"resourceVersion\":\"1\"},\"items\":[{}]}"
          , AwsAdminAttemptResourcePresent
          )
        ,
          ( "continued empty page is unobservable"
          , 200
          , "{\"apiVersion\":\"batch/v1\",\"kind\":\"JobList\",\"metadata\":{\"resourceVersion\":\"1\",\"continue\":\"more\"},\"items\":[]}"
          , AwsAdminAttemptResourceUnobservable
          )
        , ("missing namespace is unobservable", 404, emptyJobs, AwsAdminAttemptResourceUnobservable)
        , ("RBAC denial is unobservable", 403, emptyJobs, AwsAdminAttemptResourceUnobservable)
        , ("partial JSON is unobservable", 200, "{\"items\":[]", AwsAdminAttemptResourceUnobservable)
        ,
          ( "missing metadata is unobservable"
          , 200
          , "{\"apiVersion\":\"batch/v1\",\"kind\":\"JobList\",\"items\":[]}"
          , AwsAdminAttemptResourceUnobservable
          )
        ,
          ( "oversized list is unobservable"
          , 200
          , ByteString.replicate 65537 32
          , AwsAdminAttemptResourceUnobservable
          )
        ]
    ]
      ++ [
           ( "empty complete Pod list is absence"
           , classifyCredentialWorkloadList CredentialPodList 200 emptyPods == AwsAdminAttemptResourceAbsent
           )
         ]
  emptyJobs =
    "{\"apiVersion\":\"batch/v1\",\"kind\":\"JobList\",\"metadata\":{\"resourceVersion\":\"1\"},\"items\":[]}"
  emptyPods =
    "{\"apiVersion\":\"v1\",\"kind\":\"PodList\",\"metadata\":{\"resourceVersion\":\"1\"},\"items\":[]}"

productionProveAwsAdminAttestedRecovery
  :: AuthorityTime
  -> AwsAdminPermitIntent
  -> AwsAdminJobBinding
  -> IO (Either AwsAdminAuthorizedRecoveryError AwsAdminAttestedRecoveryProof)
productionProveAwsAdminAttestedRecovery now intent binding =
  proveAttestedWithObservations (observeBoundWorkloads binding) now intent binding

proveAttestedWithObservations
  :: (Monad m)
  => m (AwsAdminAttemptResourceObservation, AwsAdminAttemptResourceObservation)
  -> AuthorityTime
  -> AwsAdminPermitIntent
  -> AwsAdminJobBinding
  -> m (Either AwsAdminAuthorizedRecoveryError AwsAdminAttestedRecoveryProof)
proveAttestedWithObservations observe now intent binding = do
  (jobObservation, podObservation) <- observe
  pure $ do
    validateAwsAdminAttestedRecovery
      now
      (AwsAdminAuthorityAttested intent binding)
      jobObservation
      podObservation
    Right (AwsAdminAttestedRecoveryProof now intent binding)

observeBoundWorkloads
  :: AwsAdminJobBinding
  -> IO (AwsAdminAttemptResourceObservation, AwsAdminAttemptResourceObservation)
observeBoundWorkloads binding = do
  managerResult <- kubernetesManager
  case managerResult of
    Nothing ->
      pure
        ( AwsAdminAttemptResourceUnobservable
        , AwsAdminAttemptResourceUnobservable
        )
    Just manager -> do
      let tokenSupplier = projectedTokenSupplierAt inClusterTokenPath
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

-- | Fixed diagnostics over ordinary intent/binding metadata. The controlled
-- observer and all proof values stay inside this owner; callers receive facts.
fixedAwsAdminAttestedRecoveryRegression
  :: AuthorityTime
  -> AwsAdminPermitIntent
  -> AwsAdminJobBinding
  -> AwsAdminPermitIntent
  -> Either Text [(Text, Bool)]
fixedAwsAdminAttestedRecoveryRegression now retained binding replacement = do
  proof <- firstShow (produce AwsAdminAttemptResourceAbsent AwsAdminAttemptResourceAbsent)
  renewed <- firstShow (commitAwsAdminPreparedAttestedRecovery proof replacement attested)
  let deadline = authorityTimeMicros (awsAdminPermitIntentDeadline retained)
  if deadline == 0 then Left "attested recovery fixture deadline invalid" else Right ()
  let before = authorityTimeFromMicros (deadline - 1)
      observations =
        [AwsAdminAttemptResourceAbsent, AwsAdminAttemptResourcePresent, AwsAdminAttemptResourceUnobservable]
      absenceCases =
        [ ( Text.pack (show job <> "/" <> show pod)
          , isRight (produce job pod)
              == (job == AwsAdminAttemptResourceAbsent && pod == AwsAdminAttemptResourceAbsent)
          )
        | job <- observations
        , pod <- observations
        ]
  Right
    ( absenceCases
        ++ [ ("exact expired attestation renews", renewed == AwsAdminAuthorityPrepared replacement)
           ,
             ( "attested renewal exact replay"
             , commitAwsAdminPreparedAttestedRecovery proof replacement renewed == Right renewed
             )
           ,
             ( "attested renewal refuses another retained intent"
             , isLeft
                 ( commitAwsAdminPreparedAttestedRecovery
                     proof
                     replacement
                     (AwsAdminAuthorityAttested replacement binding)
                 )
             )
           ,
             ( "attested renewal refuses a different prepared operation"
             , isLeft
                 (commitAwsAdminPreparedAttestedRecovery proof replacement (AwsAdminAuthorityPrepared retained))
             )
           ,
             ( "attested renewal refuses an active deadline"
             , isLeft
                 ( validateAwsAdminAttestedRecovery
                     before
                     attested
                     AwsAdminAttemptResourceAbsent
                     AwsAdminAttemptResourceAbsent
                 )
             )
           ,
             ( "absence metadata cannot recover a prepared-only attempt"
             , isLeft
                 ( validateAwsAdminAttestedRecovery
                     now
                     (AwsAdminAuthorityPrepared retained)
                     AwsAdminAttemptResourceAbsent
                     AwsAdminAttemptResourceAbsent
                 )
             )
           ,
             ( "attested renewal refuses an unchanged deadline"
             , isLeft (commitAwsAdminPreparedAttestedRecovery proof retained attested)
             )
           ]
    )
 where
  attested = AwsAdminAuthorityAttested retained binding
  produce job pod = runIdentity (proveAttestedWithObservations (Identity (job, pod)) now retained binding)
  firstShow :: (Show cause) => Either cause value -> Either Text value
  firstShow = first (Text.pack . show)
