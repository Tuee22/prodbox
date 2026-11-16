{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LinearTypes #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

-- | Non-bypass conformance for the physical Bootstrap Broker engine.
module BootstrapBrokerEnginePhysical
  ( enginePhysicalSuite
  , main
  )
where

import Codec.Serialise (deserialiseOrFail, serialise)
import Control.Concurrent
  ( forkIO
  , modifyMVar
  , newEmptyMVar
  , newMVar
  , readMVar
  , threadDelay
  , tryPutMVar
  )
import Control.Concurrent.Async qualified as Async
import Control.Exception
  ( AsyncException (ThreadKilled)
  , IOException
  , SomeException
  , bracket
  , evaluate
  , fromException
  , throwIO
  , try
  )
import Control.Monad (forM_, forever, void, when)
import Data.Aeson (eitherDecodeStrict', withObject, (.:))
import Data.Aeson.Types (parseEither)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Char8 qualified as ByteString8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (toLower)
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.List (find, nub)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock.POSIX (getPOSIXTime)
import Network.Socket
  ( Family (AF_INET)
  , HostAddress
  , PortNumber
  , SockAddr (SockAddrInet)
  , SocketType (Stream)
  , bind
  , close
  , defaultProtocol
  , getSocketName
  , socket
  , tupleToHostAddress
  , withSocketsDo
  )
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as SocketBytes
import Numeric.Natural (Natural)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Bootstrap.Broker.Client qualified as Client
import Prodbox.Bootstrap.Broker.Custody
import Prodbox.Bootstrap.Broker.Engine
import Prodbox.Bootstrap.Broker.EngineAdapter
  ( brokerEngineErrorDiagnostic
  , engineBrokerInterpreter
  , engineErrorReply
  , runEngineBrokerRequest
  )
import Prodbox.Bootstrap.Broker.EngineSecretWorker
import Prodbox.Bootstrap.Broker.Fake qualified as Fake
import Prodbox.Bootstrap.Broker.Fence
import Prodbox.Bootstrap.Broker.InitializationEvidence
  ( RootInitJournalPhase (..)
  , RootInitializationEvidence (..)
  )
import Prodbox.Bootstrap.Broker.InitializationEvidence qualified as InitEvidence
import Prodbox.Bootstrap.Broker.InitializationRecovery qualified as InitRecovery
import Prodbox.Bootstrap.Broker.Model
import Prodbox.Bootstrap.Broker.PgpBoundary qualified as Pgp
import Prodbox.Bootstrap.Broker.PristineJournal
  ( PristineJournalRefusal (..)
  , classifyPristineJournal
  , rootInitJournalObservation
  )
import Prodbox.Bootstrap.Broker.ProductionCryptoParameters
  ( productionPristineStorageProof
  )
import Prodbox.Bootstrap.Broker.ProductionEngine
  ( classifyProvisionerAccessorAbsenceHttpFailure
  , classifyProvisionerAccessorAbsenceListing
  , classifyProvisionerAccessorCleanupHttpFailure
  , classifyProvisionerAccessorCleanupListing
  , classifyProvisionerAccessorRevocationHttpFailure
  , classifyProvisionerAccessorRevocationListing
  , classifyProvisionerPolicyCoreReconcileFailure
  , classifyProvisionerPolicyPkiReconcileFailure
  , classifyProvisionerPolicyRepairHttpFailure
  , classifyRootAccessorAbsenceHttpFailure
  , classifyRootAccessorAbsenceListing
  , classifyRootAccessorInventoryHttpFailure
  , classifyRootAccessorInventoryListing
  , classifyRootAccessorRevocationHttpFailure
  , classifyRootAccessorRevocationListing
  , decideRootAccessorAbsenceProof
  )
import Prodbox.Bootstrap.Broker.ProductionSecretWorker
  ( InitializationCallOutcome (..)
  , InitializationFollowUp (..)
  , classifyInitializationAmbiguity
  , classifyInitializationCallOutcome
  , initializationUnobservedDiagnostic
  )
import Prodbox.Bootstrap.Broker.ProductionStore qualified as ProductionStore
import Prodbox.Bootstrap.Broker.Program
import Prodbox.Bootstrap.Broker.Protocol
import Prodbox.Bootstrap.Broker.Readiness (BrokerReadinessState (..))
import Prodbox.Bootstrap.Broker.Request qualified as Request
import Prodbox.Bootstrap.Broker.ResetEvidence qualified as ResetEvidence
import Prodbox.Bootstrap.Broker.Routes
import Prodbox.Bootstrap.Broker.SecretWorker
import Prodbox.Bootstrap.Broker.Server qualified as Server
import Prodbox.Bootstrap.Broker.Settings qualified as Settings
import Prodbox.Bootstrap.Broker.StoreBoundary
import Prodbox.Bootstrap.Broker.StoreBoundary qualified as Store
import Prodbox.Bootstrap.Broker.Types
import Prodbox.Cluster.FederationRegistration
  ( federationRegistrationCompletedIntent
  , federationRegistrationOperationDigest
  )
import Prodbox.ControlPlane.AuthorityClock
  ( AuthorityClockObservation (..)
  , clockUncertaintyFromMicros
  , operationDeadlineFromMicros
  , operationDeadlineMicros
  )
import Prodbox.ControlPlane.CapabilityKind (CapabilityOp)
import Prodbox.ControlPlane.CapabilityRef
  ( refCapabilityOp
  , refCoordinateDigest
  )
import Prodbox.ControlPlane.Coordinate
  ( CapabilityCoordinate
  , CoordinateDigest
  , coordinateDigest
  , mkAuthorityScope
  , mkCapabilityEndpoint
  , mkCoordinate
  , mkLogicalName
  , mkServiceIdentity
  )
import Prodbox.ControlPlane.Deadline
  ( Deadline
  , MonotonicInstant
  , RemainingDuration (..)
  , deadlineAtOffset
  , deadlineFromInstant
  , deadlineInstant
  , monotonicInstantFromMicros
  , monotonicInstantMicros
  )
import Prodbox.ControlPlane.Interpreter (realMonotonicNow)
import Prodbox.Http.Client (HttpError (..))
import Prodbox.Lifecycle.Lease
  ( OwnerNonce
  , authorityTimeFromMicros
  , mkOwnerNonce
  )
import Prodbox.Lifecycle.TargetCommitIntent (mkCredentialGeneration)
import Prodbox.Secret.VaultInventory qualified as VaultInventory
import Prodbox.Vault.Client qualified as Vault
import Prodbox.Vault.Reconcile qualified as VaultReconcile
import System.Timeout (timeout)
import TestSupport

main :: IO ()
main = mainWithSuite "BootstrapBrokerEnginePhysical" enginePhysicalSuite

enginePhysicalSuite :: SuiteBuilder ()
enginePhysicalSuite =
  describe "Sprint 2.33 physical Bootstrap Broker composition" $ do
    it
      "Sprint 2.147 leaves a timed-out applied Transit journal write unconfirmed"
      transitJournalDeadlineRegression
    it
      "Sprint 2.147 bounds the worker Transit journal observation"
      transitJournalReadDeadlineRegression
    it
      "Sprint 2.147 preserves the retained generation and bounds fence mutations"
      fenceReleasePermitRegression
    it
      "Sprint 2.147 grants one Transit claim when matching writers race"
      transitClaimRaceRegression
    it "Sprint 2.147 preserves the Transit journal wire encoding" $ do
      let fixtureDigest = mustRight (Request.mkRequestDigest (Text.replicate 64 "a"))
          generation = mustRight (mkVaultStorageGeneration "fixture-generation")
          cases =
            [
              ( "hQCCAHhAYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYYIAcmZpeHR1cmUtZ2VuZXJhdGlvbmtmaXh0dXJlLWtleQc="
              , ProductionStore.ProductionTransitRotationPlanned fixtureDigest generation "fixture-key" 7
              )
            ,
              ( "hgGCAHhAYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYYIAcmZpeHR1cmUtZ2VuZXJhdGlvbmtmaXh0dXJlLWtleQcI"
              , ProductionStore.ProductionTransitRotationApplied fixtureDigest generation "fixture-key" 7 8
              )
            ,
              ( "hQKCAHhAYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYYIAcmZpeHR1cmUtZ2VuZXJhdGlvbmtmaXh0dXJlLWtleQc="
              , ProductionStore.ProductionTransitRotationClaimed fixtureDigest generation "fixture-key" 7
              )
            ,
              ( "hgOCAHhAYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYYIAcmZpeHR1cmUtZ2VuZXJhdGlvbmtmaXh0dXJlLWtleQcI"
              , ProductionStore.ProductionTransitRotationCompleted fixtureDigest generation "fixture-key" 7 8
              )
            ]
      forM_ cases $ \(encoded, expected) -> do
        let bytes = LazyByteString.fromStrict (mustRight (Base64.decode encoded))
        deserialiseOrFail bytes `shouldBe` Right expected
        serialise expected `shouldBe` bytes

    it "Sprint 2.67 renders only the closed baseline stage at the protected route" $ do
      let stages = [minBound .. maxBound] :: [BaselinePhysicalStage]
          rendered = map renderBaselinePhysicalStage stages
          secret = "vault-body-and-token-must-not-be-rendered"
          failure =
            EngineBaselinePhysicalCallRefused
              BaselineInventoryStaleRootAccessors
              (EngineBoundaryRefused secret)
          protected = brokerEngineErrorDiagnostic BrokerVaultBaselineReconcile failure
          unrelated = brokerEngineErrorDiagnostic BrokerVaultStatus failure
      length stages `shouldBe` 16
      length (nub rendered) `shouldBe` length rendered
      protected `shouldContain` "baseline-stage=inventory-stale-root-accessors"
      protected `shouldContain` "boundary-refused"
      protected `shouldNotContain` Text.unpack secret
      unrelated `shouldNotContain` "baseline-stage="
      unrelated `shouldNotContain` Text.unpack secret
      engineErrorReply failure
        `shouldBe` (Server.BrokerReplyConflict, "{\"status\":\"boundary-refused\"}")

    it "Sprint 2.70 exhausts the payload-free root-accessor absence proof causes" $ do
      let operations = [minBound .. maxBound] :: [RootAccessorAbsenceProofHttpOperation]
          httpFailures =
            [ RootAccessorAbsenceHttpConnectionFailure
            , RootAccessorAbsenceHttpTimeout
            , RootAccessorAbsenceHttpStatus 503
            , RootAccessorAbsenceHttpDecode
            ]
          causes =
            [ RootAccessorAbsenceProjectedTokenUnavailable
            , RootAccessorAbsenceAuditorLoginInvalid
            , RootAccessorAbsenceAuditorCleanupUnavailable
            , RootAccessorAbsenceAuditorCleanupRefused
            , RootAccessorAbsenceAuditorCleanupAmbiguous
            , RootAccessorAbsenceObservedAccessorInvalid
            , RootAccessorAbsenceObservedInventoryTooLarge
            , RootAccessorAbsenceObservedInventoryDuplicate
            , RootAccessorAbsenceGenerationMismatch
            , RootAccessorAbsenceTargetPresent
            , RootAccessorAbsenceStableZeroMismatch
            ]
              ++ [ RootAccessorAbsenceHttpFailure operation httpFailure
                 | operation <- operations
                 , httpFailure <- httpFailures
                 ]
          rendered = map rootAccessorAbsenceProofCauseName causes
          failure cause =
            EngineBaselinePhysicalCallRefused
              BaselineProveCurrentRootAccessorAbsent
              (EngineBoundaryRootAccessorAbsenceProof cause)
          protected cause =
            brokerEngineErrorDiagnostic BrokerVaultBaselineReconcile (failure cause)
          unrelated cause = brokerEngineErrorDiagnostic BrokerVaultStatus (failure cause)
      length operations `shouldBe` 3
      length causes `shouldBe` 23
      length (nub rendered) `shouldBe` length rendered
      forM_ causes $ \cause -> do
        protected cause
          `shouldContain` ("root-accessor-absence-cause=" <> rootAccessorAbsenceProofCauseName cause)
        unrelated cause `shouldNotContain` "root-accessor-absence-cause="
      protected
        ( RootAccessorAbsenceHttpFailure
            RootAccessorAbsenceListAccessors
            (RootAccessorAbsenceHttpStatus 503)
        )
        `shouldBe` "bootstrap-broker refused /v1/bootstrap/vault/baseline/reconcile: EngineBaselinePhysicalCallRefused (baseline-stage=prove-current-root-accessor-absent; root-accessor-absence-cause=http/list-accessors/status-503)"
      engineErrorReply (failure RootAccessorAbsenceStableZeroMismatch)
        `shouldBe` (Server.BrokerReplyConflict, "{\"status\":\"boundary-refused\"}")
      engineErrorReply
        ( failure
            ( RootAccessorAbsenceHttpFailure
                RootAccessorAbsenceAuditorLogin
                RootAccessorAbsenceHttpTimeout
            )
        )
        `shouldBe` (Server.BrokerReplyServiceUnavailable, "{\"status\":\"boundary-unavailable\"}")

    it "Sprint 2.71 exhausts the payload-free root-accessor revocation causes" $ do
      let operations = [minBound .. maxBound] :: [RootAccessorRevocationHttpOperation]
          httpFailures =
            [ RootAccessorRevocationHttpConnectionFailure
            , RootAccessorRevocationHttpTimeout
            , RootAccessorRevocationHttpStatus 503
            , RootAccessorRevocationHttpDecode
            ]
          causes =
            [ RootAccessorRevocationProjectedTokenUnavailable
            , RootAccessorRevocationAuditorLoginInvalid
            , RootAccessorRevocationAuditorCleanupUnavailable
            , RootAccessorRevocationAuditorCleanupRefused
            , RootAccessorRevocationAuditorCleanupAmbiguous
            , RootAccessorRevocationTargetStillPresent
            ]
              ++ [ RootAccessorRevocationHttpFailure operation httpFailure
                 | operation <- operations
                 , httpFailure <- httpFailures
                 ]
          rendered = map rootAccessorRevocationCauseName causes
          failure cause =
            EngineBaselinePhysicalCallRefused
              BaselineRevokePostBaselineRootAccessor
              (EngineBoundaryRootAccessorRevocation cause)
          protected cause =
            brokerEngineErrorDiagnostic BrokerVaultBaselineReconcile (failure cause)
          unrelated cause = brokerEngineErrorDiagnostic BrokerVaultStatus (failure cause)
      length operations `shouldBe` 3
      length causes `shouldBe` 18
      length (nub rendered) `shouldBe` length rendered
      forM_ causes $ \cause -> do
        protected cause
          `shouldContain` ("root-accessor-revocation-cause=" <> rootAccessorRevocationCauseName cause)
        unrelated cause `shouldNotContain` "root-accessor-revocation-cause="
      protected
        ( RootAccessorRevocationHttpFailure
            RootAccessorRevocationRequest
            (RootAccessorRevocationHttpStatus 503)
        )
        `shouldBe` "bootstrap-broker refused /v1/bootstrap/vault/baseline/reconcile: EngineBaselinePhysicalCallRefused (baseline-stage=revoke-post-baseline-root-accessor; root-accessor-revocation-cause=http/revoke-accessor/status-503)"
      engineErrorReply (failure RootAccessorRevocationTargetStillPresent)
        `shouldBe` (Server.BrokerReplyConflict, "{\"status\":\"boundary-refused\"}")
      engineErrorReply
        ( failure
            ( RootAccessorRevocationHttpFailure
                RootAccessorRevocationListReadBack
                RootAccessorRevocationHttpTimeout
            )
        )
        `shouldBe` (Server.BrokerReplyServiceUnavailable, "{\"status\":\"boundary-unavailable\"}")

    it "Sprint 2.71 classifies revocation HTTP failures without retaining payloads" $ do
      let secret = "accessor-and-vault-body-must-not-cross"
      map
        classifyRootAccessorRevocationHttpFailure
        [ HttpConnectionFailure secret
        , HttpTimeout secret
        , HttpStatus 503 secret
        , HttpDecode secret
        ]
        `shouldBe` [ RootAccessorRevocationHttpConnectionFailure
                   , RootAccessorRevocationHttpTimeout
                   , RootAccessorRevocationHttpStatus 503
                   , RootAccessorRevocationHttpDecode
                   ]

    it "Sprint 2.76 treats only post-revocation LIST 404 as an empty accessor set" $ do
      let secret = "post-revocation-list-body-must-not-cross"
          listFailure httpFailure =
            Left
              ( RootAccessorRevocationHttpFailure
                  RootAccessorRevocationListReadBack
                  httpFailure
              )
      classifyRootAccessorRevocationListing
        (Right (Vault.TokenAccessorListing ["accessor-a"]))
        `shouldBe` Right ["accessor-a"]
      classifyRootAccessorRevocationListing (Left (HttpStatus 404 secret))
        `shouldBe` Right []
      map
        classifyRootAccessorRevocationListing
        [ Left (HttpConnectionFailure secret)
        , Left (HttpTimeout secret)
        , Left (HttpStatus 503 secret)
        , Left (HttpDecode secret)
        ]
        `shouldBe` [ listFailure RootAccessorRevocationHttpConnectionFailure
                   , listFailure RootAccessorRevocationHttpTimeout
                   , listFailure (RootAccessorRevocationHttpStatus 503)
                   , listFailure RootAccessorRevocationHttpDecode
                   ]

    it "Sprint 2.72 exhausts the payload-free root-accessor inventory causes" $ do
      let operations = [minBound .. maxBound] :: [RootAccessorInventoryHttpOperation]
          httpFailures =
            [ RootAccessorInventoryHttpConnectionFailure
            , RootAccessorInventoryHttpTimeout
            , RootAccessorInventoryHttpStatus 503
            , RootAccessorInventoryHttpDecode
            ]
          causes =
            [ RootAccessorInventoryProjectedTokenUnavailable
            , RootAccessorInventoryAuditorLoginInvalid
            , RootAccessorInventoryAuditorCleanupUnavailable
            , RootAccessorInventoryAuditorCleanupRefused
            , RootAccessorInventoryAuditorCleanupAmbiguous
            , RootAccessorInventoryObservedAccessorInvalid
            , RootAccessorInventoryObservedInventoryTooLarge
            , RootAccessorInventoryObservedInventoryDuplicate
            ]
              ++ [ RootAccessorInventoryHttpFailure operation httpFailure
                 | operation <- operations
                 , httpFailure <- httpFailures
                 ]
          rendered = map rootAccessorInventoryCauseName causes
          failure cause =
            EngineBaselinePhysicalCallRefused
              BaselineInventoryPostBaselineRootAccessors
              (EngineBoundaryRootAccessorInventory cause)
          protected cause =
            brokerEngineErrorDiagnostic BrokerVaultBaselineReconcile (failure cause)
          unrelated cause = brokerEngineErrorDiagnostic BrokerVaultStatus (failure cause)
      length operations `shouldBe` 3
      length causes `shouldBe` 20
      length (nub rendered) `shouldBe` length rendered
      forM_ causes $ \cause -> do
        protected cause
          `shouldContain` ("root-accessor-inventory-cause=" <> rootAccessorInventoryCauseName cause)
        unrelated cause `shouldNotContain` "root-accessor-inventory-cause="
      protected
        ( RootAccessorInventoryHttpFailure
            RootAccessorInventoryListAccessors
            (RootAccessorInventoryHttpStatus 503)
        )
        `shouldBe` "bootstrap-broker refused /v1/bootstrap/vault/baseline/reconcile: EngineBaselinePhysicalCallRefused (baseline-stage=inventory-post-baseline-root-accessors; root-accessor-inventory-cause=http/list-accessors/status-503)"
      engineErrorReply (failure RootAccessorInventoryObservedAccessorInvalid)
        `shouldBe` (Server.BrokerReplyConflict, "{\"status\":\"boundary-refused\"}")
      engineErrorReply
        ( failure
            ( RootAccessorInventoryHttpFailure
                RootAccessorInventoryAuditorLogin
                RootAccessorInventoryHttpTimeout
            )
        )
        `shouldBe` (Server.BrokerReplyServiceUnavailable, "{\"status\":\"boundary-unavailable\"}")
      engineErrorReply (failure RootAccessorInventoryAuditorCleanupAmbiguous)
        `shouldBe` (Server.BrokerReplyGatewayTimeout, "{\"status\":\"boundary-ambiguous\"}")

    it "Sprint 2.72 classifies inventory HTTP failures without retaining payloads" $ do
      let secret = "accessor-policy-and-vault-body-must-not-cross"
      map
        classifyRootAccessorInventoryHttpFailure
        [ HttpConnectionFailure secret
        , HttpTimeout secret
        , HttpStatus 503 secret
        , HttpDecode secret
        ]
        `shouldBe` [ RootAccessorInventoryHttpConnectionFailure
                   , RootAccessorInventoryHttpTimeout
                   , RootAccessorInventoryHttpStatus 503
                   , RootAccessorInventoryHttpDecode
                   ]

    it "Sprint 2.72 treats only inventory-list 404 as an empty inventory" $ do
      let secret = "inventory-list-body-must-not-cross"
      classifyRootAccessorInventoryListing
        (Right (Vault.TokenAccessorListing ["accessor-a"]))
        `shouldBe` Right ["accessor-a"]
      classifyRootAccessorInventoryListing (Left (HttpStatus 404 secret))
        `shouldBe` Right []
      map
        classifyRootAccessorInventoryListing
        [ Left (HttpConnectionFailure secret)
        , Left (HttpTimeout secret)
        , Left (HttpStatus 503 secret)
        , Left (HttpDecode secret)
        ]
        `shouldBe` map
          ( Left
              . RootAccessorInventoryHttpFailure
                RootAccessorInventoryListAccessors
          )
          [ RootAccessorInventoryHttpConnectionFailure
          , RootAccessorInventoryHttpTimeout
          , RootAccessorInventoryHttpStatus 503
          , RootAccessorInventoryHttpDecode
          ]

    it "Sprint 2.73 exhausts the payload-free provisioner-accessor cleanup causes" $ do
      let operations = [minBound .. maxBound] :: [ProvisionerAccessorCleanupHttpOperation]
          httpFailures =
            [ ProvisionerAccessorCleanupHttpConnectionFailure
            , ProvisionerAccessorCleanupHttpTimeout
            , ProvisionerAccessorCleanupHttpStatus 503
            , ProvisionerAccessorCleanupHttpDecode
            ]
          causes =
            [ ProvisionerAccessorCleanupProjectedTokenUnavailable
            , ProvisionerAccessorCleanupAuditorLoginInvalid
            , ProvisionerAccessorCleanupAuditorCleanupUnavailable
            , ProvisionerAccessorCleanupAuditorCleanupRefused
            , ProvisionerAccessorCleanupAuditorCleanupAmbiguous
            , ProvisionerAccessorCleanupAuditIdentityInvalid
            , ProvisionerAccessorCleanupVisibilityUnavailable
            , ProvisionerAccessorCleanupVisibilityRefused
            , ProvisionerAccessorCleanupVisibilityAmbiguous
            , ProvisionerAccessorCleanupStableAbsenceFailed
            , ProvisionerAccessorCleanupObservedAccessorInvalid
            , ProvisionerAccessorCleanupObservedInventoryTooLarge
            , ProvisionerAccessorCleanupObservedInventoryDuplicate
            ]
              ++ [ ProvisionerAccessorCleanupHttpFailure operation httpFailure
                 | operation <- operations
                 , httpFailure <- httpFailures
                 ]
          rendered = map provisionerAccessorCleanupCauseName causes
          failure cause =
            EngineBaselinePhysicalCallRefused
              BaselineCleanupProvisionerAccessors
              (EngineBoundaryProvisionerAccessorCleanup cause)
          protected cause =
            brokerEngineErrorDiagnostic BrokerVaultBaselineReconcile (failure cause)
          unrelated cause = brokerEngineErrorDiagnostic BrokerVaultStatus (failure cause)
      length operations `shouldBe` 7
      length causes `shouldBe` 41
      length (nub rendered) `shouldBe` length rendered
      forM_ causes $ \cause -> do
        protected cause
          `shouldContain` ("provisioner-accessor-cleanup-cause=" <> provisionerAccessorCleanupCauseName cause)
        unrelated cause `shouldNotContain` "provisioner-accessor-cleanup-cause="
      protected
        ( ProvisionerAccessorCleanupHttpFailure
            ProvisionerAccessorCleanupInitialListAccessors
            (ProvisionerAccessorCleanupHttpStatus 503)
        )
        `shouldBe` "bootstrap-broker refused /v1/bootstrap/vault/baseline/reconcile: EngineBaselinePhysicalCallRefused (baseline-stage=cleanup-provisioner-accessors; provisioner-accessor-cleanup-cause=http/initial-list-accessors/status-503)"
      engineErrorReply (failure ProvisionerAccessorCleanupStableAbsenceFailed)
        `shouldBe` (Server.BrokerReplyConflict, "{\"status\":\"boundary-refused\"}")
      engineErrorReply
        ( failure
            ( ProvisionerAccessorCleanupHttpFailure
                ProvisionerAccessorCleanupAuditLookupAccessor
                ProvisionerAccessorCleanupHttpTimeout
            )
        )
        `shouldBe` (Server.BrokerReplyServiceUnavailable, "{\"status\":\"boundary-unavailable\"}")
      engineErrorReply (failure ProvisionerAccessorCleanupVisibilityAmbiguous)
        `shouldBe` (Server.BrokerReplyGatewayTimeout, "{\"status\":\"boundary-ambiguous\"}")

    it "Sprint 2.73 treats only cleanup LIST 404 as empty without retaining HTTP payloads" $ do
      let secret = "provisioner-accessor-and-vault-body-must-not-cross"
          operation = ProvisionerAccessorCleanupInitialListAccessors
      map
        classifyProvisionerAccessorCleanupHttpFailure
        [ HttpConnectionFailure secret
        , HttpTimeout secret
        , HttpStatus 503 secret
        , HttpDecode secret
        ]
        `shouldBe` [ ProvisionerAccessorCleanupHttpConnectionFailure
                   , ProvisionerAccessorCleanupHttpTimeout
                   , ProvisionerAccessorCleanupHttpStatus 503
                   , ProvisionerAccessorCleanupHttpDecode
                   ]
      classifyProvisionerAccessorCleanupListing
        operation
        (Right (Vault.TokenAccessorListing ["accessor-a"]))
        `shouldBe` Right ["accessor-a"]
      classifyProvisionerAccessorCleanupListing
        operation
        (Left (HttpStatus 404 secret))
        `shouldBe` Right []
      classifyProvisionerAccessorCleanupListing
        ProvisionerAccessorCleanupAuditListAccessors
        (Left (HttpStatus 404 secret))
        `shouldBe` Right []
      map
        (classifyProvisionerAccessorCleanupListing operation)
        [ Left (HttpConnectionFailure secret)
        , Left (HttpTimeout secret)
        , Left (HttpStatus 503 secret)
        , Left (HttpDecode secret)
        ]
        `shouldBe` map
          (Left . ProvisionerAccessorCleanupHttpFailure operation)
          [ ProvisionerAccessorCleanupHttpConnectionFailure
          , ProvisionerAccessorCleanupHttpTimeout
          , ProvisionerAccessorCleanupHttpStatus 503
          , ProvisionerAccessorCleanupHttpDecode
          ]

    it "Sprint 2.75 exhausts the payload-free provisioner-accessor revocation causes" $ do
      let operations = [minBound .. maxBound] :: [ProvisionerAccessorRevocationHttpOperation]
          httpFailures =
            [ ProvisionerAccessorRevocationHttpConnectionFailure
            , ProvisionerAccessorRevocationHttpTimeout
            , ProvisionerAccessorRevocationHttpStatus 503
            , ProvisionerAccessorRevocationHttpDecode
            ]
          causes =
            [ ProvisionerAccessorRevocationProjectedTokenUnavailable
            , ProvisionerAccessorRevocationAuditorLoginInvalid
            , ProvisionerAccessorRevocationAuditorCleanupUnavailable
            , ProvisionerAccessorRevocationAuditorCleanupRefused
            , ProvisionerAccessorRevocationAuditorCleanupAmbiguous
            , ProvisionerAccessorRevocationTargetIdentityInvalid
            , ProvisionerAccessorRevocationTargetStillPresent
            , ProvisionerAccessorRevocationRoleAccessorStillPresent
            ]
              ++ [ ProvisionerAccessorRevocationHttpFailure operation httpFailure
                 | operation <- operations
                 , httpFailure <- httpFailures
                 ]
          rendered = map provisionerAccessorRevocationCauseName causes
          failure cause =
            EngineBaselinePhysicalCallRefused
              BaselineRevokeProvisionerAccessor
              (EngineBoundaryProvisionerAccessorRevocation cause)
          protected cause =
            brokerEngineErrorDiagnostic BrokerVaultBaselineReconcile (failure cause)
          unrelated cause = brokerEngineErrorDiagnostic BrokerVaultStatus (failure cause)
      length operations `shouldBe` 6
      length causes `shouldBe` 32
      length (nub rendered) `shouldBe` length rendered
      forM_ causes $ \cause -> do
        protected cause
          `shouldContain` ("provisioner-accessor-revocation-cause=" <> provisionerAccessorRevocationCauseName cause)
        unrelated cause `shouldNotContain` "provisioner-accessor-revocation-cause="
      protected
        ( ProvisionerAccessorRevocationHttpFailure
            ProvisionerAccessorRevocationInitialListAccessors
            (ProvisionerAccessorRevocationHttpStatus 503)
        )
        `shouldBe` "bootstrap-broker refused /v1/bootstrap/vault/baseline/reconcile: EngineBaselinePhysicalCallRefused (baseline-stage=revoke-provisioner-accessor; provisioner-accessor-revocation-cause=http/initial-list-accessors/status-503)"
      engineErrorReply (failure ProvisionerAccessorRevocationTargetStillPresent)
        `shouldBe` (Server.BrokerReplyConflict, "{\"status\":\"boundary-refused\"}")
      engineErrorReply
        ( failure
            ( ProvisionerAccessorRevocationHttpFailure
                ProvisionerAccessorRevocationInitialListAccessors
                ProvisionerAccessorRevocationHttpTimeout
            )
        )
        `shouldBe` (Server.BrokerReplyServiceUnavailable, "{\"status\":\"boundary-unavailable\"}")
      engineErrorReply
        ( failure
            ( ProvisionerAccessorRevocationHttpFailure
                ProvisionerAccessorRevocationTargetLookupAccessor
                ProvisionerAccessorRevocationHttpTimeout
            )
        )
        `shouldBe` (Server.BrokerReplyConflict, "{\"status\":\"boundary-refused\"}")
      engineErrorReply (failure ProvisionerAccessorRevocationAuditorCleanupAmbiguous)
        `shouldBe` (Server.BrokerReplyGatewayTimeout, "{\"status\":\"boundary-ambiguous\"}")

    it "Sprints 2.75/2.81 admit 404 only for revocation LIST operations" $ do
      let secret = "provisioner-accessor-and-vault-body-must-not-cross"
          operation = ProvisionerAccessorRevocationInitialListAccessors
      map
        classifyProvisionerAccessorRevocationHttpFailure
        [ HttpConnectionFailure secret
        , HttpTimeout secret
        , HttpStatus 503 secret
        , HttpDecode secret
        ]
        `shouldBe` [ ProvisionerAccessorRevocationHttpConnectionFailure
                   , ProvisionerAccessorRevocationHttpTimeout
                   , ProvisionerAccessorRevocationHttpStatus 503
                   , ProvisionerAccessorRevocationHttpDecode
                   ]
      classifyProvisionerAccessorRevocationListing
        operation
        (Right (Vault.TokenAccessorListing ["accessor-a"]))
        `shouldBe` Right ["accessor-a"]
      classifyProvisionerAccessorRevocationListing
        operation
        (Left (HttpStatus 404 secret))
        `shouldBe` Right []
      classifyProvisionerAccessorRevocationListing
        ProvisionerAccessorRevocationPostListAccessors
        (Left (HttpStatus 404 secret))
        `shouldBe` Right []
      classifyProvisionerAccessorRevocationListing
        ProvisionerAccessorRevocationTargetLookupAccessor
        (Left (HttpStatus 404 secret))
        `shouldBe` Left
          ( ProvisionerAccessorRevocationHttpFailure
              ProvisionerAccessorRevocationTargetLookupAccessor
              (ProvisionerAccessorRevocationHttpStatus 404)
          )

    it "Sprint 2.82 exhausts final provisioner-accessor absence causes" $ do
      let operations = [minBound .. maxBound] :: [ProvisionerAccessorAbsenceHttpOperation]
          httpFailures =
            [ ProvisionerAccessorAbsenceHttpConnectionFailure
            , ProvisionerAccessorAbsenceHttpTimeout
            , ProvisionerAccessorAbsenceHttpStatus 503
            , ProvisionerAccessorAbsenceHttpDecode
            ]
          causes =
            [ ProvisionerAccessorAbsenceProjectedTokenUnavailable
            , ProvisionerAccessorAbsenceAuditorLoginInvalid
            , ProvisionerAccessorAbsenceAuditorCleanupUnavailable
            , ProvisionerAccessorAbsenceAuditorCleanupRefused
            , ProvisionerAccessorAbsenceAuditorCleanupAmbiguous
            , ProvisionerAccessorAbsenceRoleAccessorStillPresent
            , ProvisionerAccessorAbsenceObservedAccessorInvalid
            , ProvisionerAccessorAbsenceObservedInventoryTooLarge
            , ProvisionerAccessorAbsenceObservedInventoryDuplicate
            ]
              ++ [ ProvisionerAccessorAbsenceHttpFailure operation httpFailure
                 | operation <- operations
                 , httpFailure <- httpFailures
                 ]
          rendered = map provisionerAccessorAbsenceCauseName causes
          failure cause =
            EngineBaselinePhysicalCallRefused
              BaselineProveProvisionerAccessorAbsent
              (EngineBoundaryProvisionerAccessorAbsence cause)
          protected cause =
            brokerEngineErrorDiagnostic BrokerVaultBaselineReconcile (failure cause)
          unrelated cause = brokerEngineErrorDiagnostic BrokerVaultStatus (failure cause)
      length operations `shouldBe` 3
      length causes `shouldBe` 21
      length (nub rendered) `shouldBe` length rendered
      forM_ causes $ \cause -> do
        protected cause
          `shouldContain` ("provisioner-accessor-absence-cause=" <> provisionerAccessorAbsenceCauseName cause)
        unrelated cause `shouldNotContain` "provisioner-accessor-absence-cause="
      protected
        ( ProvisionerAccessorAbsenceHttpFailure
            ProvisionerAccessorAbsenceListAccessors
            (ProvisionerAccessorAbsenceHttpStatus 404)
        )
        `shouldBe` "bootstrap-broker refused /v1/bootstrap/vault/baseline/reconcile: EngineBaselinePhysicalCallRefused (baseline-stage=prove-provisioner-accessor-absent; provisioner-accessor-absence-cause=http/list-accessors/status-404)"
      engineErrorReply (failure ProvisionerAccessorAbsenceRoleAccessorStillPresent)
        `shouldBe` (Server.BrokerReplyConflict, "{\"status\":\"boundary-refused\"}")
      engineErrorReply
        ( failure
            ( ProvisionerAccessorAbsenceHttpFailure
                ProvisionerAccessorAbsenceLookupAccessor
                ProvisionerAccessorAbsenceHttpTimeout
            )
        )
        `shouldBe` (Server.BrokerReplyServiceUnavailable, "{\"status\":\"boundary-unavailable\"}")
      engineErrorReply (failure ProvisionerAccessorAbsenceAuditorCleanupAmbiguous)
        `shouldBe` (Server.BrokerReplyGatewayTimeout, "{\"status\":\"boundary-ambiguous\"}")

    it "Sprint 2.82 admits only final absence LIST 404 without retaining payloads" $ do
      let secret = "provisioner-absence-vault-body-must-not-cross"
      map
        classifyProvisionerAccessorAbsenceHttpFailure
        [ HttpConnectionFailure secret
        , HttpTimeout secret
        , HttpStatus 404 secret
        , HttpDecode secret
        ]
        `shouldBe` [ ProvisionerAccessorAbsenceHttpConnectionFailure
                   , ProvisionerAccessorAbsenceHttpTimeout
                   , ProvisionerAccessorAbsenceHttpStatus 404
                   , ProvisionerAccessorAbsenceHttpDecode
                   ]
      classifyProvisionerAccessorAbsenceListing
        (Right (Vault.TokenAccessorListing ["accessor-a"]))
        `shouldBe` Right ["accessor-a"]
      classifyProvisionerAccessorAbsenceListing (Left (HttpStatus 404 secret))
        `shouldBe` Right []
      map
        classifyProvisionerAccessorAbsenceListing
        [ Left (HttpConnectionFailure secret)
        , Left (HttpTimeout secret)
        , Left (HttpStatus 503 secret)
        , Left (HttpDecode secret)
        ]
        `shouldBe` map
          ( Left
              . ProvisionerAccessorAbsenceHttpFailure
                ProvisionerAccessorAbsenceListAccessors
          )
          [ ProvisionerAccessorAbsenceHttpConnectionFailure
          , ProvisionerAccessorAbsenceHttpTimeout
          , ProvisionerAccessorAbsenceHttpStatus 503
          , ProvisionerAccessorAbsenceHttpDecode
          ]

    it "Sprint 2.74 exhausts the payload-free provisioner-policy application causes" $ do
      let httpFailures =
            [ Pgp.GeneratedRootCoreHttpConnectionFailure
            , Pgp.GeneratedRootCoreHttpTimeout
            , Pgp.GeneratedRootCoreHttpStatus 503
            , Pgp.GeneratedRootCoreHttpDecode
            ]
          coreHttpCauses =
            [ Pgp.GeneratedRootCoreHttpFailure operation httpFailure
            | operation <- [minBound .. maxBound]
            , httpFailure <- httpFailures
            ]
          coreOtherCauses =
            [ Pgp.GeneratedRootCoreMountTypeMismatch
            , Pgp.GeneratedRootCoreMountOptionMismatch
            , Pgp.GeneratedRootCoreAuthTypeMismatch
            , Pgp.GeneratedRootCoreTransitKeyTypeMismatch
            , Pgp.GeneratedRootCoreKubernetesRoleReadbackMismatch
            , Pgp.GeneratedRootCoreSecretBootstrapFailure
                (Pgp.GeneratedRootCoreSecretReadFailure Pgp.GeneratedRootCoreHttpConnectionFailure)
            , Pgp.GeneratedRootCoreSecretBootstrapFailure
                (Pgp.GeneratedRootCoreSecretReadFailure Pgp.GeneratedRootCoreHttpTimeout)
            , Pgp.GeneratedRootCoreSecretBootstrapFailure
                (Pgp.GeneratedRootCoreSecretReadFailure (Pgp.GeneratedRootCoreHttpStatus 503))
            , Pgp.GeneratedRootCoreSecretBootstrapFailure
                (Pgp.GeneratedRootCoreSecretReadFailure Pgp.GeneratedRootCoreHttpDecode)
            , Pgp.GeneratedRootCoreSecretBootstrapFailure
                Pgp.GeneratedRootCoreSecretWriteAppliedInvariant
            , Pgp.GeneratedRootCoreSecretBootstrapFailure
                Pgp.GeneratedRootCoreSecretWriteConflict
            , Pgp.GeneratedRootCoreSecretBootstrapFailure
                (Pgp.GeneratedRootCoreSecretWriteRefused 403)
            , Pgp.GeneratedRootCoreSecretBootstrapFailure
                Pgp.GeneratedRootCoreSecretWriteUnobservable
            , Pgp.GeneratedRootCoreSecretBootstrapFailure
                Pgp.GeneratedRootCoreSecretExternalFieldMissing
            ]
          pkiHttpCauses =
            [ Pgp.GeneratedRootPkiReconcileHttpFailure operation httpFailure
            | operation <- [minBound .. maxBound]
            , httpFailure <- httpFailures
            ]
          pkiObserveCauses =
            [ Pgp.GeneratedRootPkiReconcileObserveFailure
                (Pgp.GeneratedRootPkiObserveHttpFailure operation httpFailure)
            | operation <- [minBound .. maxBound]
            , httpFailure <- httpFailures
            ]
          pkiStatusCauses =
            map
              Pgp.GeneratedRootPkiReconcileReadBackNotExact
              [minBound .. maxBound]
          repairCauses =
            [ ProvisionerPolicyApplicationRepairAuthorityUnavailable
            , ProvisionerPolicyApplicationRepairReadBackMismatch
            ]
              ++ map ProvisionerPolicyApplicationRepairWriteHttp httpFailures
              ++ map ProvisionerPolicyApplicationRepairReadBackHttp httpFailures
          causes =
            ProvisionerPolicyApplicationTokenUnavailable
              : repairCauses
              ++ map ProvisionerPolicyApplicationCoreReconcile (coreHttpCauses ++ coreOtherCauses)
              ++ map
                ProvisionerPolicyApplicationPkiReconcile
                (pkiHttpCauses ++ pkiObserveCauses ++ pkiStatusCauses)
          rendered = map provisionerPolicyApplicationCauseName causes
          failure cause =
            EngineBaselinePhysicalCallRefused
              BaselineApplyProvisionerPolicy
              (EngineBoundaryProvisionerPolicyApplication cause)
          protected cause =
            brokerEngineErrorDiagnostic BrokerVaultBaselineReconcile (failure cause)
          unrelated cause = brokerEngineErrorDiagnostic BrokerVaultStatus (failure cause)
      length coreHttpCauses `shouldBe` 40
      length coreOtherCauses `shouldBe` 14
      length pkiHttpCauses `shouldBe` 12
      length pkiObserveCauses `shouldBe` 8
      length pkiStatusCauses `shouldBe` 3
      length causes `shouldBe` 88
      length (nub rendered) `shouldBe` length rendered
      forM_ causes $ \cause -> do
        protected cause
          `shouldContain` ("provisioner-policy-application-cause=" <> provisionerPolicyApplicationCauseName cause)
        unrelated cause `shouldNotContain` "provisioner-policy-application-cause="
        engineErrorReply (failure cause)
          `shouldBe` (Server.BrokerReplyServiceUnavailable, "{\"status\":\"boundary-unavailable\"}")
      protected
        ( ProvisionerPolicyApplicationCoreReconcile
            ( Pgp.GeneratedRootCoreHttpFailure
                Pgp.GeneratedRootCoreWritePolicy
                (Pgp.GeneratedRootCoreHttpStatus 403)
            )
        )
        `shouldBe` "bootstrap-broker refused /v1/bootstrap/vault/baseline/reconcile: EngineBaselinePhysicalCallRefused (baseline-stage=apply-provisioner-policy; provisioner-policy-application-cause=core-reconcile/http/write-policy/status-403)"
      protected
        (ProvisionerPolicyApplicationRepairWriteHttp (Pgp.GeneratedRootCoreHttpStatus 403))
        `shouldBe` "bootstrap-broker refused /v1/bootstrap/vault/baseline/reconcile: EngineBaselinePhysicalCallRefused (baseline-stage=apply-provisioner-policy; provisioner-policy-application-cause=repair-write/status-403)"

    it "Sprint 2.74 classifies every core and PKI failure without retaining payloads" $ do
      let secretText = "policy-and-vault-body-must-not-cross"
          secretString = Text.unpack secretText
          httpFailures =
            [ (HttpConnectionFailure secretString, Pgp.GeneratedRootCoreHttpConnectionFailure)
            , (HttpTimeout secretString, Pgp.GeneratedRootCoreHttpTimeout)
            , (HttpStatus 503 secretString, Pgp.GeneratedRootCoreHttpStatus 503)
            , (HttpDecode secretString, Pgp.GeneratedRootCoreHttpDecode)
            ]
          coreOperations =
            [ (VaultReconcile.VaultReconcileListMounts, Pgp.GeneratedRootCoreListMounts)
            , (VaultReconcile.VaultReconcileEnableMount, Pgp.GeneratedRootCoreEnableMount)
            , (VaultReconcile.VaultReconcileListAuthMethods, Pgp.GeneratedRootCoreListAuthMethods)
            , (VaultReconcile.VaultReconcileEnableAuthMethod, Pgp.GeneratedRootCoreEnableAuthMethod)
            ,
              ( VaultReconcile.VaultReconcileWriteKubernetesAuthConfig
              , Pgp.GeneratedRootCoreWriteKubernetesAuthConfig
              )
            , (VaultReconcile.VaultReconcileReadTransitKey, Pgp.GeneratedRootCoreReadTransitKey)
            , (VaultReconcile.VaultReconcileCreateTransitKey, Pgp.GeneratedRootCoreCreateTransitKey)
            , (VaultReconcile.VaultReconcileWritePolicy, Pgp.GeneratedRootCoreWritePolicy)
            , (VaultReconcile.VaultReconcileWriteKubernetesRole, Pgp.GeneratedRootCoreWriteKubernetesRole)
            , (VaultReconcile.VaultReconcileReadBackKubernetesRole, Pgp.GeneratedRootCoreReadBackKubernetesRole)
            ]
          path = VaultInventory.VaultSecretPath "secret" secretText
          coreOtherFailures =
            [
              ( VaultReconcile.VaultReconcileMountTypeMismatch secretText secretText secretText
              , Pgp.GeneratedRootCoreMountTypeMismatch
              )
            ,
              ( VaultReconcile.VaultReconcileMountOptionMismatch secretText secretText secretText (Just secretText)
              , Pgp.GeneratedRootCoreMountOptionMismatch
              )
            ,
              ( VaultReconcile.VaultReconcileAuthTypeMismatch secretText secretText secretText
              , Pgp.GeneratedRootCoreAuthTypeMismatch
              )
            ,
              ( VaultReconcile.VaultReconcileTransitKeyTypeMismatch secretText secretText secretText
              , Pgp.GeneratedRootCoreTransitKeyTypeMismatch
              )
            ,
              ( VaultReconcile.VaultReconcileKubernetesRoleReadbackMismatch secretText
              , Pgp.GeneratedRootCoreKubernetesRoleReadbackMismatch
              )
            ,
              ( VaultReconcile.VaultReconcileSecretBootstrapFailed
                  (VaultInventory.VaultSecretBootstrapReadFailed path (HttpDecode secretString))
              , Pgp.GeneratedRootCoreSecretBootstrapFailure
                  (Pgp.GeneratedRootCoreSecretReadFailure Pgp.GeneratedRootCoreHttpDecode)
              )
            ,
              ( VaultReconcile.VaultReconcileSecretBootstrapFailed
                  (VaultInventory.VaultSecretBootstrapWriteFailed path (Vault.VaultCasApplied 1))
              , Pgp.GeneratedRootCoreSecretBootstrapFailure
                  Pgp.GeneratedRootCoreSecretWriteAppliedInvariant
              )
            ,
              ( VaultReconcile.VaultReconcileSecretBootstrapFailed
                  (VaultInventory.VaultSecretBootstrapWriteFailed path (Vault.VaultCasConflict secretText))
              , Pgp.GeneratedRootCoreSecretBootstrapFailure
                  Pgp.GeneratedRootCoreSecretWriteConflict
              )
            ,
              ( VaultReconcile.VaultReconcileSecretBootstrapFailed
                  (VaultInventory.VaultSecretBootstrapWriteFailed path (Vault.VaultCasRefused 403 secretText))
              , Pgp.GeneratedRootCoreSecretBootstrapFailure
                  (Pgp.GeneratedRootCoreSecretWriteRefused 403)
              )
            ,
              ( VaultReconcile.VaultReconcileSecretBootstrapFailed
                  (VaultInventory.VaultSecretBootstrapWriteFailed path (Vault.VaultCasUnobservable secretText))
              , Pgp.GeneratedRootCoreSecretBootstrapFailure
                  Pgp.GeneratedRootCoreSecretWriteUnobservable
              )
            ,
              ( VaultReconcile.VaultReconcileSecretBootstrapFailed
                  (VaultInventory.VaultSecretBootstrapExternalFieldMissing path secretText)
              , Pgp.GeneratedRootCoreSecretBootstrapFailure
                  Pgp.GeneratedRootCoreSecretExternalFieldMissing
              )
            ]
          pkiOperations =
            [ (VaultReconcile.VaultPkiReconcileListIssuers, Pgp.GeneratedRootPkiReconcileListIssuers)
            ,
              ( VaultReconcile.VaultPkiReconcileGenerateInternalRoot
              , Pgp.GeneratedRootPkiReconcileGenerateInternalRoot
              )
            , (VaultReconcile.VaultPkiReconcileWriteRole, Pgp.GeneratedRootPkiReconcileWriteRole)
            ]
          pkiObserveOperations =
            [ (VaultReconcile.VaultPkiObserveListIssuers, Pgp.GeneratedRootPkiObserveListIssuers)
            , (VaultReconcile.VaultPkiObserveReadRole, Pgp.GeneratedRootPkiObserveReadRole)
            ]
          pkiStatuses =
            [ (VaultReconcile.VaultPkiBaselineAbsent, Pgp.GeneratedRootPkiBaselineAbsent)
            , (VaultReconcile.VaultPkiBaselineDrifted, Pgp.GeneratedRootPkiBaselineDrifted)
            , (VaultReconcile.VaultPkiBaselineReady, Pgp.GeneratedRootPkiBaselineReady)
            ]
      forM_ coreOperations $ \(operation, expectedOperation) ->
        forM_ httpFailures $ \(httpFailure, expectedHttpFailure) ->
          classifyProvisionerPolicyCoreReconcileFailure
            (VaultReconcile.VaultReconcileHttpError operation secretText httpFailure)
            `shouldBe` ProvisionerPolicyApplicationCoreReconcile
              (Pgp.GeneratedRootCoreHttpFailure expectedOperation expectedHttpFailure)
      forM_ httpFailures $ \(httpFailure, expectedHttpFailure) ->
        classifyProvisionerPolicyRepairHttpFailure httpFailure
          `shouldBe` expectedHttpFailure
      forM_ coreOtherFailures $ \(failure, expected) ->
        classifyProvisionerPolicyCoreReconcileFailure failure
          `shouldBe` ProvisionerPolicyApplicationCoreReconcile expected
      forM_ pkiOperations $ \(operation, expectedOperation) ->
        forM_ httpFailures $ \(httpFailure, expectedHttpFailure) ->
          classifyProvisionerPolicyPkiReconcileFailure
            (VaultReconcile.VaultPkiReconcileHttpError operation httpFailure)
            `shouldBe` ProvisionerPolicyApplicationPkiReconcile
              (Pgp.GeneratedRootPkiReconcileHttpFailure expectedOperation expectedHttpFailure)
      forM_ pkiObserveOperations $ \(operation, expectedOperation) ->
        forM_ httpFailures $ \(httpFailure, expectedHttpFailure) ->
          classifyProvisionerPolicyPkiReconcileFailure
            ( VaultReconcile.VaultPkiReconcileObserveFailed
                (VaultReconcile.VaultPkiObserveHttpError operation httpFailure)
            )
            `shouldBe` ProvisionerPolicyApplicationPkiReconcile
              ( Pgp.GeneratedRootPkiReconcileObserveFailure
                  (Pgp.GeneratedRootPkiObserveHttpFailure expectedOperation expectedHttpFailure)
              )
      forM_ pkiStatuses $ \(status, expectedStatus) ->
        classifyProvisionerPolicyPkiReconcileFailure
          (VaultReconcile.VaultPkiReconcileReadBackNotExact status)
          `shouldBe` ProvisionerPolicyApplicationPkiReconcile
            (Pgp.GeneratedRootPkiReconcileReadBackNotExact expectedStatus)

    it "Sprint 2.70 classifies HTTP payloads and distinguishes exact target absence from stable zero" $ do
      let secret = "token-and-vault-body-must-not-cross"
          generation = mustRight (mkVaultStorageGeneration "absence-proof-generation")
          otherGeneration = mustRight (mkVaultStorageGeneration "other-generation")
          targetAccessor = mustRight (mkRootPolicyAccessor "target-accessor")
          unrelatedAccessor = mustRight (mkRootPolicyAccessor "unrelated-accessor")
          target = mustRight (mkRootAccessorInventory generation [targetAccessor])
          absent = mustRight (mkRootAccessorInventory generation [])
          unrelated = mustRight (mkRootAccessorInventory generation [unrelatedAccessor])
          present = mustRight (mkRootAccessorInventory generation [targetAccessor])
          wrongGeneration = mustRight (mkRootAccessorInventory otherGeneration [])
      map
        classifyRootAccessorAbsenceHttpFailure
        [ HttpConnectionFailure secret
        , HttpTimeout secret
        , HttpStatus 503 secret
        , HttpDecode secret
        ]
        `shouldBe` [ RootAccessorAbsenceHttpConnectionFailure
                   , RootAccessorAbsenceHttpTimeout
                   , RootAccessorAbsenceHttpStatus 503
                   , RootAccessorAbsenceHttpDecode
                   ]
      decideRootAccessorAbsenceProof RootAccessorStableZeroRequired target absent
        `shouldBe` Right ()
      decideRootAccessorAbsenceProof RootAccessorStableZeroRequired target unrelated
        `shouldBe` Left RootAccessorAbsenceStableZeroMismatch
      decideRootAccessorAbsenceProof RootAccessorTargetsAbsentRequired target unrelated
        `shouldBe` Right ()
      decideRootAccessorAbsenceProof RootAccessorTargetsAbsentRequired target present
        `shouldBe` Left RootAccessorAbsenceTargetPresent
      decideRootAccessorAbsenceProof RootAccessorTargetsAbsentRequired target wrongGeneration
        `shouldBe` Left RootAccessorAbsenceGenerationMismatch

    it "Sprint 2.70 treats only accessor-list 404 as an empty inventory" $ do
      let secret = "accessor-list-body-must-not-cross"
      classifyRootAccessorAbsenceListing
        (Right (Vault.TokenAccessorListing ["accessor-a"]))
        `shouldBe` Right ["accessor-a"]
      classifyRootAccessorAbsenceListing (Left (HttpStatus 404 secret))
        `shouldBe` Right []
      map
        classifyRootAccessorAbsenceListing
        [ Left (HttpConnectionFailure secret)
        , Left (HttpTimeout secret)
        , Left (HttpStatus 403 secret)
        , Left (HttpDecode secret)
        ]
        `shouldBe` [ Left
                       ( RootAccessorAbsenceHttpFailure
                           RootAccessorAbsenceListAccessors
                           RootAccessorAbsenceHttpConnectionFailure
                       )
                   , Left
                       ( RootAccessorAbsenceHttpFailure
                           RootAccessorAbsenceListAccessors
                           RootAccessorAbsenceHttpTimeout
                       )
                   , Left
                       ( RootAccessorAbsenceHttpFailure
                           RootAccessorAbsenceListAccessors
                           (RootAccessorAbsenceHttpStatus 403)
                       )
                   , Left
                       ( RootAccessorAbsenceHttpFailure
                           RootAccessorAbsenceListAccessors
                           RootAccessorAbsenceHttpDecode
                       )
                   ]

    it "Sprint 2.68 renders every closed PGP cause only at the protected baseline route" $ do
      let causes =
            [ Pgp.PgpCompiledBurnRecipientMismatch
            , Pgp.PgpCompiledBurnPublicKeyMismatch
            , Pgp.PgpCompiledBurnPublicKeyDigestMismatch
            , Pgp.PgpRecipientGenerationFailed
            , Pgp.PgpRecipientSealFailed
            , Pgp.PgpRecipientPublicKeyNotCanonicalBase64
            , Pgp.PgpPreparedRecoveryRecipientMismatch
            , Pgp.PgpPreparedBurnRecipientMismatch
            , Pgp.PgpEncryptedShareRejected
            , Pgp.PgpGeneratedRootCiphertextRejected
            , Pgp.PgpGeneratedChildRecoveryCiphertextRejected
            , Pgp.PgpGeneratedRootSessionClosed
            , Pgp.PgpGeneratedRootSessionPermitMismatch
                BootstrapVaultSubmitUnsealShare
                BootstrapVaultInitialize
            , Pgp.PgpGeneratedRootSessionGenerationMismatch
            , Pgp.PgpGeneratedRootTokenRejected
            , Pgp.PgpGeneratedRootActionRefused
                Pgp.GeneratedRootObserveSelfAction
                Pgp.GeneratedRootObserveAccessorRequest
            , Pgp.PgpGeneratedRootActionPermitMismatch
                BootstrapVaultSubmitUnsealShare
                BootstrapVaultInitialize
            , Pgp.PgpGeneratedRootActionGenerationMismatch
            , Pgp.PgpGeneratedRootActionBindingMismatch
            , Pgp.PgpGeneratedRootActionFenceIdentityMismatch
            , Pgp.PgpGeneratedChildRecoverySessionClosed
            , Pgp.PgpGeneratedChildRecoverySessionPermitMismatch
                BootstrapVaultSubmitUnsealShare
                BootstrapVaultInitialize
            , Pgp.PgpGeneratedChildRecoverySessionGenerationMismatch
            , Pgp.PgpGeneratedChildRecoveryActionRefused
                Pgp.GeneratedChildRecoveryObserveSelfAction
            , Pgp.PgpGeneratedChildRecoveryActionPermitMismatch
                BootstrapVaultSubmitUnsealShare
                BootstrapVaultInitialize
            , Pgp.PgpGeneratedChildRecoveryActionBindingMismatch
            , Pgp.PgpGeneratedChildRecoveryActionGenerationMismatch
            , Pgp.PgpGeneratedChildRecoveryActionFenceIdentityMismatch
            , Pgp.PgpPasswordAeadFailed
            ]
          rendered = map Pgp.pgpBoundaryErrorName causes
          failure = EnginePgpBoundaryRefused Pgp.PgpGeneratedRootActionFenceIdentityMismatch
          protected = brokerEngineErrorDiagnostic BrokerVaultBaselineReconcile failure
          unrelated = brokerEngineErrorDiagnostic BrokerVaultStatus failure
          renderCoreCause cause =
            Pgp.pgpBoundaryErrorName
              ( Pgp.PgpGeneratedRootActionRefused
                  Pgp.GeneratedRootApplyBaselineAction
                  (Pgp.GeneratedRootApplyCoreReconcile cause)
              )
          corePrefix =
            "generated-root-action-refused/apply-baseline/core-reconcile/"
      length causes `shouldBe` 29
      length (nub rendered) `shouldBe` length rendered
      protected `shouldContain` "pgp-cause=generated-root-action-fence-identity-mismatch"
      unrelated `shouldNotContain` "pgp-cause="
      engineErrorReply failure
        `shouldBe` (Server.BrokerReplyConflict, "{\"status\":\"state-conflict\"}")
      map
        ( \(kind, stage) ->
            Pgp.pgpBoundaryErrorName
              (Pgp.PgpGeneratedRootActionRefused kind stage)
        )
        [ (Pgp.GeneratedRootObserveSelfAction, Pgp.GeneratedRootObserveAccessorRequest)
        ,
          ( Pgp.GeneratedRootApplyBaselineAction
          , Pgp.GeneratedRootApplyCoreReconcile
              Pgp.GeneratedRootCoreMountTypeMismatch
          )
        ,
          ( Pgp.GeneratedRootReadBackBaselineAction
          , Pgp.GeneratedRootReadBackPkiObserve
              ( Pgp.GeneratedRootPkiObserveHttpFailure
                  Pgp.GeneratedRootPkiObserveListIssuers
                  Pgp.GeneratedRootCoreHttpConnectionFailure
              )
          )
        , (Pgp.GeneratedRootRevokeSelfAction, Pgp.GeneratedRootRevokeAccessorRequest)
        ]
        `shouldBe` [ "generated-root-action-refused/observe-accessor/accessor-request"
                   , "generated-root-action-refused/apply-baseline/core-reconcile/mount-type-mismatch"
                   , "generated-root-action-refused/read-back-baseline/pki-observe/http/list-issuers/connection-failure"
                   , "generated-root-action-refused/revoke-accessor/accessor-request"
                   ]
      map
        (Pgp.pgpBoundaryErrorName . Pgp.PgpGeneratedChildRecoveryActionRefused)
        Pgp.allGeneratedChildRecoveryActionKinds
        `shouldBe` [ "generated-child-recovery-action-refused/observe-accessor"
                   , "generated-child-recovery-action-refused/apply-repair"
                   , "generated-child-recovery-action-refused/read-back-repair"
                   , "generated-child-recovery-action-refused/revoke-accessor"
                   ]
      forM_
        [ (Pgp.GeneratedRootCoreListMounts, "list-mounts")
        , (Pgp.GeneratedRootCoreEnableMount, "enable-mount")
        , (Pgp.GeneratedRootCoreListAuthMethods, "list-auth-methods")
        , (Pgp.GeneratedRootCoreEnableAuthMethod, "enable-auth-method")
        ,
          ( Pgp.GeneratedRootCoreWriteKubernetesAuthConfig
          , "write-kubernetes-auth-config"
          )
        , (Pgp.GeneratedRootCoreReadTransitKey, "read-transit-key")
        , (Pgp.GeneratedRootCoreCreateTransitKey, "create-transit-key")
        , (Pgp.GeneratedRootCoreWritePolicy, "write-policy")
        , (Pgp.GeneratedRootCoreWriteKubernetesRole, "write-kubernetes-role")
        ,
          ( Pgp.GeneratedRootCoreReadBackKubernetesRole
          , "read-back-kubernetes-role"
          )
        ]
        $ \(operation, expected) ->
          renderCoreCause
            ( Pgp.GeneratedRootCoreHttpFailure
                operation
                Pgp.GeneratedRootCoreHttpConnectionFailure
            )
            `shouldBe` ( corePrefix
                           <> "http/"
                           <> expected
                           <> "/connection-failure"
                       )
      map
        ( renderCoreCause
            . Pgp.GeneratedRootCoreHttpFailure Pgp.GeneratedRootCoreListMounts
        )
        [ Pgp.GeneratedRootCoreHttpConnectionFailure
        , Pgp.GeneratedRootCoreHttpTimeout
        , Pgp.GeneratedRootCoreHttpStatus 403
        , Pgp.GeneratedRootCoreHttpDecode
        ]
        `shouldBe` map
          (corePrefix <>)
          [ "http/list-mounts/connection-failure"
          , "http/list-mounts/timeout"
          , "http/list-mounts/status-403"
          , "http/list-mounts/decode"
          ]
      map
        renderCoreCause
        [ Pgp.GeneratedRootCoreMountTypeMismatch
        , Pgp.GeneratedRootCoreMountOptionMismatch
        , Pgp.GeneratedRootCoreAuthTypeMismatch
        , Pgp.GeneratedRootCoreTransitKeyTypeMismatch
        , Pgp.GeneratedRootCoreKubernetesRoleReadbackMismatch
        , Pgp.GeneratedRootCoreSecretBootstrapFailure
            ( Pgp.GeneratedRootCoreSecretReadFailure
                (Pgp.GeneratedRootCoreHttpStatus 403)
            )
        , Pgp.GeneratedRootCoreSecretBootstrapFailure
            Pgp.GeneratedRootCoreSecretWriteAppliedInvariant
        , Pgp.GeneratedRootCoreSecretBootstrapFailure
            Pgp.GeneratedRootCoreSecretWriteConflict
        , Pgp.GeneratedRootCoreSecretBootstrapFailure
            (Pgp.GeneratedRootCoreSecretWriteRefused 403)
        , Pgp.GeneratedRootCoreSecretBootstrapFailure
            Pgp.GeneratedRootCoreSecretWriteUnobservable
        , Pgp.GeneratedRootCoreSecretBootstrapFailure
            Pgp.GeneratedRootCoreSecretExternalFieldMissing
        ]
        `shouldBe` map
          (corePrefix <>)
          [ "mount-type-mismatch"
          , "mount-option-mismatch"
          , "auth-type-mismatch"
          , "transit-key-type-mismatch"
          , "kubernetes-role-readback-mismatch"
          , "secret-bootstrap/read/status-403"
          , "secret-bootstrap/write/applied-invariant"
          , "secret-bootstrap/write/conflict"
          , "secret-bootstrap/write/refused-status-403"
          , "secret-bootstrap/write/unobservable"
          , "secret-bootstrap/external-field-missing"
          ]

    it "Sprint 2.69 exhausts payload-free PKI operation, HTTP, observe, and status causes" $ do
      let applyPrefix = "generated-root-action-refused/apply-baseline/pki-reconcile/"
          readBackPrefix =
            "generated-root-action-refused/read-back-baseline/pki-observe/"
          renderApply cause =
            Pgp.pgpBoundaryErrorName
              ( Pgp.PgpGeneratedRootActionRefused
                  Pgp.GeneratedRootApplyBaselineAction
                  (Pgp.GeneratedRootApplyPkiReconcile cause)
              )
          renderObserve cause =
            Pgp.pgpBoundaryErrorName
              ( Pgp.PgpGeneratedRootActionRefused
                  Pgp.GeneratedRootReadBackBaselineAction
                  (Pgp.GeneratedRootReadBackPkiObserve cause)
              )
          observeReadRole =
            Pgp.GeneratedRootPkiObserveHttpFailure
              Pgp.GeneratedRootPkiObserveReadRole
      forM_
        [ (Pgp.GeneratedRootPkiReconcileListIssuers, "list-issuers")
        , (Pgp.GeneratedRootPkiReconcileGenerateInternalRoot, "generate-internal-root")
        , (Pgp.GeneratedRootPkiReconcileWriteRole, "write-role")
        ]
        $ \(operation, expected) ->
          renderApply
            ( Pgp.GeneratedRootPkiReconcileHttpFailure
                operation
                Pgp.GeneratedRootCoreHttpConnectionFailure
            )
            `shouldBe` (applyPrefix <> "http/" <> expected <> "/connection-failure")
      map
        ( renderApply
            . Pgp.GeneratedRootPkiReconcileHttpFailure
              Pgp.GeneratedRootPkiReconcileListIssuers
        )
        [ Pgp.GeneratedRootCoreHttpConnectionFailure
        , Pgp.GeneratedRootCoreHttpTimeout
        , Pgp.GeneratedRootCoreHttpStatus 403
        , Pgp.GeneratedRootCoreHttpDecode
        ]
        `shouldBe` map
          (applyPrefix <>)
          [ "http/list-issuers/connection-failure"
          , "http/list-issuers/timeout"
          , "http/list-issuers/status-403"
          , "http/list-issuers/decode"
          ]
      forM_
        [ (Pgp.GeneratedRootPkiObserveListIssuers, "list-issuers")
        , (Pgp.GeneratedRootPkiObserveReadRole, "read-role")
        ]
        $ \(operation, expected) ->
          renderObserve
            ( Pgp.GeneratedRootPkiObserveHttpFailure
                operation
                Pgp.GeneratedRootCoreHttpDecode
            )
            `shouldBe` (readBackPrefix <> "http/" <> expected <> "/decode")
      renderApply
        ( Pgp.GeneratedRootPkiReconcileObserveFailure
            (observeReadRole (Pgp.GeneratedRootCoreHttpStatus 500))
        )
        `shouldBe` (applyPrefix <> "observe/http/read-role/status-500")
      map
        ( renderApply
            . Pgp.GeneratedRootPkiReconcileReadBackNotExact
        )
        [ Pgp.GeneratedRootPkiBaselineAbsent
        , Pgp.GeneratedRootPkiBaselineDrifted
        , Pgp.GeneratedRootPkiBaselineReady
        ]
        `shouldBe` map
          (applyPrefix <>)
          [ "read-back-not-exact/absent"
          , "read-back-not-exact/drifted"
          , "read-back-not-exact/ready"
          ]
      map
        ( \status ->
            Pgp.pgpBoundaryErrorName
              ( Pgp.PgpGeneratedRootActionRefused
                  Pgp.GeneratedRootReadBackBaselineAction
                  (Pgp.GeneratedRootReadBackPkiStatus status)
              )
        )
        [ Pgp.GeneratedRootPkiBaselineAbsent
        , Pgp.GeneratedRootPkiBaselineDrifted
        , Pgp.GeneratedRootPkiBaselineReady
        ]
        `shouldBe` [ "generated-root-action-refused/read-back-baseline/pki-status/absent"
                   , "generated-root-action-refused/read-back-baseline/pki-status/drifted"
                   , "generated-root-action-refused/read-back-baseline/pki-status/ready"
                   ]

    it "Sprint 2.64 classifies Vault ambiguity without retaining error payloads" $ do
      let secret = "credential-and-vault-body-must-not-survive"
          cases =
            [ (HttpConnectionFailure secret, InitializationCallConnectionFailure)
            , (HttpTimeout secret, InitializationCallTimeout)
            , (HttpStatus 503 secret, InitializationCallHttpStatus 503)
            , (HttpDecode secret, InitializationCallResponseDecodeFailure)
            ]
      forM_ cases $ \(httpFailure, expected) -> do
        let cause = classifyInitializationAmbiguity httpFailure
        cause `shouldBe` expected
        initializationAmbiguityCauseName cause `shouldNotContain` secret

    describe "BOOTSTRAP-VAULT-INIT-PREAPPLICATION-REFUSAL-2026-10-22" $ do
      it "reports the actual pinned Vault refusal recording without its response body" $ do
        recording <-
          ByteString.readFile
            "test/qualification/BOOTSTRAP-VAULT-INIT-PREAPPLICATION-REFUSAL-2026-10-22.json"
        let status = do
              value <- eitherDecodeStrict' recording
              parseEither
                ( withObject "counterexample" $ \root -> do
                    law <- root .: "offline_law"
                    law .: "http_status"
                )
                value
        status `shouldBe` Right (400 :: Int)
        case status of
          Left failure -> expectationFailure failure
          Right code ->
            initializationUnobservedDiagnostic
              (InitializationCallHttpStatus code)
              InitializationStillUninitialized
              `shouldBe` "Vault initialization failed before application was observed; initialization-cause=http-status-400; follow-up=uninitialized"
      forM_
        [ (HttpConnectionFailure "private-error", InitializationCallConnectionFailure)
        , (HttpTimeout "private-error", InitializationCallTimeout)
        , (HttpStatus 400 "private-error", InitializationCallHttpStatus 400)
        , (HttpDecode "private-error", InitializationCallResponseDecodeFailure)
        ]
        $ \(failure, cause) ->
          it ("retains " ++ initializationAmbiguityCauseName cause ++ " across every follow-up") $ do
            let status initialized = Vault.SealStatus initialized True 3 5 0
            classifyInitializationCallOutcome failure (Right (status True))
              `shouldBe` InitializationApplied cause
            classifyInitializationCallOutcome failure (Right (status False))
              `shouldBe` InitializationUnobserved cause InitializationStillUninitialized
            classifyInitializationCallOutcome failure (Left "private-follow-up")
              `shouldBe` InitializationUnobserved cause InitializationFollowUpUnavailable
            forM_ [InitializationStillUninitialized, InitializationFollowUpUnavailable] $ \followUp -> do
              let diagnostic = initializationUnobservedDiagnostic cause followUp
              diagnostic `shouldContain` ("initialization-cause=" ++ initializationAmbiguityCauseName cause)
              diagnostic `shouldNotContain` "private-error"
              diagnostic `shouldNotContain` "private-follow-up"

    it "Sprint 2.64 appends classified ambiguity without changing the retained legacy wire" $ do
      LazyByteString.unpack (serialise ambiguousInitializationWorkerResult)
        `shouldBe` [129, 3]
      forM_
        [ InitializationObservedBeforeCall
        , InitializationCallConnectionFailure
        , InitializationCallTimeout
        , InitializationCallHttpStatus 409
        , InitializationCallResponseDecodeFailure
        , InitializationCauseUnclassified
        ]
        $ \cause -> do
          let durable = classifiedAmbiguousInitializationWorkerResult cause
          durableInitializationAmbiguityCause durable `shouldBe` Just cause
          secretWorkerDurableResultOperation durable
            `shouldBe` SecretWorkerInitialize

    it "Sprint 2.64 carries the cause to a protected diagnostic while the HTTP body stays generic" $
      withFixture $ \fixture -> do
        harness <-
          newHarness
            fixture
            ( ReturnClassifiedAppliedWithoutResponse
                (InitializationCallHttpStatus 502)
            )
            NoCrash
        engine <- requireEngine fixture harness
        let settings = requireSettings 30_455
        outcome <-
          invokeAdapter fixture settings engine BrokerVaultInitialize
        case outcome of
          Left (EngineInitializationAmbiguous _ cause) -> do
            cause `shouldBe` InitializationCallHttpStatus 502
            brokerEngineErrorDiagnostic
              BrokerVaultInitialize
              (EngineInitializationAmbiguous (fixtureAmbiguity fixture) cause)
              `shouldContain` "initialization-cause=http-status-502"
            brokerEngineErrorDiagnostic
              BrokerVaultResetAmbiguousInitialization
              (EngineInitializationAmbiguous (fixtureAmbiguity fixture) cause)
              `shouldNotContain` "initialization-cause="
          _ -> expectationFailure "expected classified initialization ambiguity"

        wireHarness <-
          newHarness
            fixture
            ( ReturnClassifiedAppliedWithoutResponse
                (InitializationCallHttpStatus 502)
            )
            NoCrash
        wireEngine <- requireEngine fixture wireHarness
        withPhysicalServer fixture wireEngine $ \wireSettings -> do
          let endpoint = Client.brokerEndpointFromSettings wireSettings
              context =
                Client.mkBrokerCallContext
                  (fixtureServiceIdentity fixture)
                  (mustRight (Request.mkIdempotencyKey "classified-init-ambiguity"))
                  (fixtureClientCredential fixture)
          response <-
            Client.initializeVault
              endpoint
              context
              (fixtureActions fixture BrokerVaultInitialize)
          response
            `shouldBe` Left
              ( Client.BrokerTransport
                  (HttpStatus 409 "{\"status\":\"state-conflict\"}")
              )

    describe "VAULT-RESET-GENERATION-CAS-LOST-PRODUCER-RECOVERY-2026-10-23" $ do
      it "retains all nineteen synthetic legacy phase encodings" $
        withFixture $ \fixture -> do
          bytes <-
            ByteString.readFile
              "test/qualification/VAULT-RESET-GENERATION-CAS-LOST-PRODUCER-RECOVERY-2026-10-23.json"
          expected <- either fail pure $ do
            value <- eitherDecodeStrict' bytes
            parseEither
              ( withObject "counterexample" $ \root -> do
                  codecs <- root .: "legacy_phase_codecs"
                  codecs .: "phase_sha256"
              )
              value
          let phases =
                [ RootInitPristine (fixturePristine fixture)
                , RootResetPristine (fixtureResetProof fixture)
                , RootInitializationAmbiguous (fixtureAmbiguity fixture)
                ]
                  ++ [phase fixture | (_, phase, _) <- rootInitializationContinuationCases]
              actual =
                Map.fromList
                  [ (show phase, TextEncoding.decodeUtf8 (hexSha256 (LazyByteString.toStrict (serialise phase))))
                  | phase <- phases
                  ]
          actual `shouldBe` (expected :: Map.Map String Text)
          Map.size actual `shouldBe` 19

      it "appends a bounded pending phase and forbids generic restart from forgetting it" $
        withFixture $ \fixture -> do
          let action = brokerActionDigest (fixtureActions fixture BrokerVaultResetAmbiguousInitialization)
              ambiguous =
                (newRootInitState (fixturePristine fixture))
                  { rootInitStatePhase = RootInitializationAmbiguous (fixtureAmbiguity fixture)
                  }
              armed =
                mustRight
                  (applyRootInitCommand ambiguous (BeginAmbiguousRootReset (fixtureResetProof fixture) action))
              encoded = serialise (rootInitStatePhase armed)
          ByteString.unpack (ByteString.take 2 (LazyByteString.toStrict encoded)) `shouldBe` [131, 19]
          deserialiseOrFail (serialise armed) `shouldBe` Right armed
          restartRootInit
            armed
            (RootObservedPreparedVaultInitializedWithoutResponse (fixturePrepared fixture))
            `shouldBe` Left RootInitResetInProgress
          InitEvidence.rootInitResetFromGeneration (rootInitStatePhase armed)
            `shouldBe` Just (rootInitStorageGeneration (resetAmbiguousBinding (fixtureResetProof fixture)))
          InitEvidence.rootInitResetActionDigest (rootInitStatePhase armed) `shouldBe` Just action

      it "keeps the existing reset-binding encoding and refuses foreign PVC or action" $
        withFixture $ \fixture -> do
          let action = brokerActionDigest (fixtureActions fixture BrokerVaultResetAmbiguousInitialization)
              ambiguity = fixtureAmbiguity fixture
              identity = "vault/data-vault-0/pvc-synthetic-1"
              commitment =
                TextEncoding.decodeUtf8
                  ( hexSha256
                      ( LazyByteString.toStrict
                          (serialise ("bootstrap-vault-storage-reset-v1" :: Text, ambiguity, action, identity :: Text))
                      )
                  )
              legacyBinding =
                RootInitBinding
                  (mustRight (mkBootstrapTransactionId ("reset-" <> commitment)))
                  (mustRight (mkVaultStorageGeneration ("vault-reset-" <> commitment)))
              old = ambiguousInitBinding ambiguity
              proof =
                mustRight
                  ( mkPristineResetProof
                      ambiguity
                      (productionPristineStorageProof legacyBinding)
                      (mkEstablishedStateAbsence old (digestOf 'a'))
                      (mkDurableInitResponseAbsence old (digestOf 'b'))
                      (mkBaselineStateAbsence old (digestOf 'c'))
                  )
          ResetEvidence.deriveRootResetBinding action ambiguity identity `shouldBe` Right legacyBinding
          ResetEvidence.rootResetIdentityMatches action proof identity `shouldBe` True
          ResetEvidence.rootResetIdentityMatches action proof "vault/data-vault-0/pvc-replacement"
            `shouldBe` False
          ResetEvidence.rootResetIdentityMatches (digestOf 'd') proof identity `shouldBe` False

      forM_ [False, True] $ \initialized ->
        it ("withdraws init at both exact pending bindings, initialized=" ++ show initialized) $
          withFixture $ \fixture -> do
            let proof = fixtureResetProof fixture
                action = brokerActionDigest (fixtureActions fixture BrokerVaultResetAmbiguousInitialization)
                snapshot =
                  (newRootInitState (fixturePristine fixture)) {rootInitStatePhase = RootResetInFlight proof action}
            forM_ [resetAmbiguousBinding proof, pristineStorageBinding (resetReplacementPristine proof)] $ \binding ->
              InitEvidence.classifyRootInitializationEvidence
                (productionPristineStorageProof binding)
                initialized
                (InitEvidence.RootInitJournalPresent (StoreVersion 2) snapshot)
                `shouldBe` Left InitEvidence.InitEvidenceAmbiguousNeedsReset

      it "makes production binding and admission agree at old and replacement generations" $
        withFixture $ \fixture -> do
          let proof = fixtureResetProof fixture
              action = brokerActionDigest (fixtureActions fixture BrokerVaultResetAmbiguousInitialization)
              old = resetAmbiguousBinding proof
              replacement = pristineStorageBinding (resetReplacementPristine proof)
              pending =
                (newRootInitState (fixturePristine fixture)) {rootInitStatePhase = RootResetInFlight proof action}
              requested = rootInitStorageGeneration old
          forM_ [old, replacement] $ \current -> do
            ProductionStore.rootInitReadMatches current pending `shouldBe` True
            ResetEvidence.classifyRootResetEvidence requested action current (Just pending)
              `shouldBe` Right (ResetEvidence.ResumeAuditedRootReset proof)
          ProductionStore.rootInitResetReadMatches requested pending `shouldBe` True
          ProductionStore.rootInitResetReadMatches (rootInitStorageGeneration replacement) pending
            `shouldBe` False
          let cancelled =
                pending
                  { rootInitStateDisposition =
                      CustodyCancellationRequested (mustRight (mkCancellationReason "reset safety-tail cancellation"))
                  }
          ResetEvidence.classifyRootResetEvidence requested action replacement (Just cancelled)
            `shouldBe` Right (ResetEvidence.ResumeAuditedRootReset proof)
          applyRootInitCommand cancelled (ResetAmbiguousRootInitialization proof)
            `shouldSatisfy` either (const False) rootInitIsResetPhase

      it "refuses missing, changed, cancelled-before-arm and unjournaled legacy state" $
        withFixture $ \fixture -> do
          let proof = fixtureResetProof fixture
              action = brokerActionDigest (fixtureActions fixture BrokerVaultResetAmbiguousInitialization)
              old = resetAmbiguousBinding proof
              replacement = pristineStorageBinding (resetReplacementPristine proof)
              ambiguous =
                (newRootInitState (fixturePristine fixture))
                  { rootInitStatePhase = RootInitializationAmbiguous (fixtureAmbiguity fixture)
                  }
              pending = ambiguous {rootInitStatePhase = RootResetInFlight proof action}
              requested = rootInitStorageGeneration old
              classify = ResetEvidence.classifyRootResetEvidence requested action
          classify old Nothing `shouldBe` Left ResetEvidence.ResetEvidenceJournalAbsent
          classify replacement (Just ambiguous)
            `shouldBe` Left ResetEvidence.ResetEvidenceUnjournaledGenerationAdvance
          classify
            old
            ( Just
                ambiguous
                  { rootInitStateDisposition =
                      CustodyCancellationRequested (mustRight (mkCancellationReason "reset safety-tail cancellation"))
                  }
            )
            `shouldBe` Left ResetEvidence.ResetEvidenceCancelledBeforeArm
          ResetEvidence.classifyRootResetEvidence requested (digestOf 'e') old (Just pending)
            `shouldBe` Left ResetEvidence.ResetEvidencePendingActionMismatch
          classify old (Just pending {rootInitStateBinding = replacement})
            `shouldBe` Left ResetEvidence.ResetEvidenceJournalInvalid

      it "reconstructs only complete durable request metadata and preserves public error classes" $
        withFixture $ \fixture -> do
          let proof = fixtureResetProof fixture
              old = rootInitStorageGeneration (resetAmbiguousBinding proof)
              current = rootInitStorageGeneration (pristineStorageBinding (resetReplacementPristine proof))
              action = brokerActionDigest (fixtureActions fixture BrokerVaultResetAmbiguousInitialization)
          ResetEvidence.rootResetClientBinding current (Just InitResetInFlight) (Just old) (Just action)
            `shouldBe` Right (ResetEvidence.ResumeRootResetRequest old action)
          ResetEvidence.rootResetClientBinding current (Just InitResetInFlight) Nothing (Just action)
            `shouldBe` Left ResetEvidence.ResetEvidencePendingGenerationAbsent
          ResetEvidence.rootResetClientBinding current (Just InitResetInFlight) (Just old) Nothing
            `shouldBe` Left ResetEvidence.ResetEvidencePendingActionAbsent
          let failure cause = EngineProgramEvidenceRefused (EngineBoundaryRootResetEvidence cause)
          engineErrorReply (failure (ResetEvidence.ResetEvidenceUnavailable ResetEvidence.ResetJournalRead))
            `shouldBe` (Server.BrokerReplyServiceUnavailable, "{\"status\":\"boundary-unavailable\"}")
          engineErrorReply (failure ResetEvidence.ResetEvidencePendingActionMismatch)
            `shouldBe` (Server.BrokerReplyConflict, "{\"status\":\"boundary-refused\"}")
          brokerEngineErrorDiagnostic
            BrokerVaultResetAmbiguousInitialization
            (failure ResetEvidence.ResetEvidencePendingActionMismatch)
            `shouldContain` "root-reset-evidence=ResetEvidencePendingActionMismatch"

      it "finishes only the already-armed safety tail after cancellation" $
        withFixture $ \fixture -> do
          harness <- newHarness fixture ReturnAppliedWithoutResponse NoCrash
          initialEngine <- requireProductionResetEngine fixture harness
          _ <- invokeAdapter fixture (requireSettings 30_451) initialEngine BrokerVaultInitialize
          modifyIORef' harness (armResetFault CrashAfterResetArmCas)
          _ <-
            invokeAdapter fixture (requireSettings 30_451) initialEngine BrokerVaultResetAmbiguousInitialization
          modifyIORef' harness cancelRootJournalForReset
          pending <- readIORef harness
          fresh <- requireProductionResetEngine fixture harness
          result <- invokeResetFromDurableObservation fixture (requireSettings 30_451) fresh pending
          result `shouldBeRouteSuccess` BrokerVaultResetAmbiguousInitialization
          after <- readIORef harness
          rootInitIsResetPristine fixture after `shouldBe` True
          assertCleanHarness after

      it "refuses cancellation before proof arming without a physical reset" $
        withFixture $ \fixture -> do
          harness <- newHarness fixture ReturnAppliedWithoutResponse NoCrash
          initialEngine <- requireProductionResetEngine fixture harness
          _ <- invokeAdapter fixture (requireSettings 30_451) initialEngine BrokerVaultInitialize
          modifyIORef' harness cancelRootJournalForReset
          before <- readIORef harness
          result <-
            invokeAdapter fixture (requireSettings 30_451) initialEngine BrokerVaultResetAmbiguousInitialization
          result `shouldSatisfy` isRootResetCancellationRefusal
          after <- readIORef harness
          let suffix = drop (length (harnessEvents before)) (harnessEvents after)
          suffix `shouldSatisfy` notElem (PhysicalMutated BootstrapVaultResetAmbiguousInitialization)
          suffix `shouldSatisfy` notElem (StoreMutated BootstrapStoreCasRootInitJournal)

      forM_ [ResetReadMissing, ResetReadActionChanges, ResetReadProofChanges] $ \fault ->
        it ("preserves state when reset evidence changes after admission: " ++ show fault) $
          withFixture $ \fixture -> do
            harness <- newHarness fixture ReturnAppliedWithoutResponse NoCrash
            setup <- requireProductionResetEngine fixture harness
            _ <- invokeAdapter fixture (requireSettings 30_451) setup BrokerVaultInitialize
            modifyIORef' harness (armResetFault CrashAfterResetArmCas)
            _ <- invokeAdapter fixture (requireSettings 30_451) setup BrokerVaultResetAmbiguousInitialization
            before <- readIORef harness
            changed <- requireProductionResetEngineWithFault fault fixture harness
            result <- invokeResetFromDurableObservation fixture (requireSettings 30_451) changed before
            result `shouldSatisfy` either (const True) (const False)
            after <- readIORef harness
            let suffix = drop (length (harnessEvents before)) (harnessEvents after)
            suffix `shouldSatisfy` notElem (PhysicalMutated BootstrapVaultResetAmbiguousInitialization)
            suffix `shouldSatisfy` notElem (StoreMutated BootstrapStoreAdvanceVaultStorageGeneration)
            suffix `shouldSatisfy` notElem (StoreMutated BootstrapStoreCreateRootInitJournal)
            length [() | InitVaultEffectApplied <- harnessEvents after] `shouldBe` 1

      forM_
        [ CrashAfterResetArmCas
        , CrashAfterResetGenerationAdvance
        , CrashAfterResetPreparationDelete
        , CrashAfterResetTerminalCas
        ]
        $ \fault ->
          it ("recovers the declared reset from durable evidence after " ++ show fault) $
            withFixture $ \fixture -> do
              harness <- newHarness fixture ReturnAppliedWithoutResponse NoCrash
              firstEngine <- requireProductionResetEngine fixture harness
              initial <- invokeAdapter fixture (requireSettings 30_451) firstEngine BrokerVaultInitialize
              initial `shouldSatisfy` isInitializationAmbiguous
              modifyIORef' harness (armResetFault fault)
              first <-
                invokeAdapter fixture (requireSettings 30_451) firstEngine BrokerVaultResetAmbiguousInitialization
              first `shouldSatisfy` isStoreUnavailable
              afterFirst <- readIORef harness
              (rootResetPending afterFirst || rootResetTerminal afterFirst) `shouldBe` True
              when (fault == CrashAfterResetArmCas) $
                length [() | PhysicalMutated BootstrapVaultResetAmbiguousInitialization <- harnessEvents afterFirst]
                  `shouldBe` 0
              if rootResetTerminal afterFirst
                then do
                  snapshot <-
                    maybe (fail "terminal reset journal absent") pure (storedValue (harnessRootJournal afterFirst))
                  ProductionStore.rootInitReadMatches (harnessRootBinding afterFirst) snapshot `shouldBe` True
                  InitEvidence.rootInitResetFromGeneration (rootInitStatePhase snapshot)
                    `shouldBe` Just (rootInitStorageGeneration (resetAmbiguousBinding (fixtureResetProof fixture)))
                else do
                  freshEngine <- requireProductionResetEngine fixture harness
                  replay <- invokeResetFromDurableObservation fixture (requireSettings 30_451) freshEngine afterFirst
                  replay `shouldBeRouteSuccess` BrokerVaultResetAmbiguousInitialization
              completed <- readIORef harness
              rootInitIsResetPristine fixture completed `shouldBe` True
              harnessPreparedEnvelope completed `shouldBe` Nothing
              length [() | InitVaultEffectApplied <- harnessEvents completed] `shouldBe` 1
              assertCleanHarness completed

    describe "HARNESS-RETAINED-INIT-RECOVERY-2026-10-22 status projection" $ do
      it "projects reset lineage only from the durable reset-pristine proof" $
        withFixture $ \fixture -> do
          let proof = fixtureResetProof fixture
              oldGeneration = rootInitStorageGeneration (resetAmbiguousBinding proof)
          InitEvidence.rootInitResetFromGeneration (RootResetPristine proof)
            `shouldBe` Just oldGeneration
          InitEvidence.rootInitResetFromGeneration (RootInitPristine (fixturePristine fixture))
            `shouldBe` Nothing
          forM_ rootInitializationContinuationCases $ \(_, phase, _) ->
            InitEvidence.rootInitResetFromGeneration (phase fixture) `shouldBe` Nothing
      it "carries the reset lineage through the actual public status codec" $
        withFixture $ \fixture -> do
          let proof = fixtureResetProof fixture
              oldGeneration = rootInitStorageGeneration (resetAmbiguousBinding proof)
              status =
                BootstrapStatus
                  { bootstrapStatusStorageGeneration =
                      rootInitStorageGeneration (pristineStorageBinding (resetReplacementPristine proof))
                  , bootstrapStatusInitialized = False
                  , bootstrapStatusSealed = True
                  , bootstrapStatusRecoveryCustodyDurable = False
                  , bootstrapStatusInitializationAmbiguous = False
                  , bootstrapStatusInitializationPhase = Just InitResetPristine
                  , bootstrapStatusInitializationResetFromGeneration =
                      InitEvidence.rootInitResetFromGeneration (RootResetPristine proof)
                  , bootstrapStatusInitializationResetActionDigest = Nothing
                  , bootstrapStatusRootSessionActive = False
                  , bootstrapStatusHandoffObserved = False
                  }
              encoded = encodeBrokerResponse (BrokerVaultStatusResponse status)
              decoded = do
                value <- eitherDecodeStrict' encoded
                parseEither
                  (withObject "Broker status" (.: "initialization_reset_from_generation"))
                  value
          decoded `shouldBe` Right (renderVaultStorageGeneration oldGeneration)

    describe "VAULT-INIT-AUTHORITATIVE-WORKER-SUPERSEDED-FENCE-2026-10-24" $ do
      forM_
        [ ReturnEncryptedInitResponse
        , ReturnAppliedWithoutResponse
        , ReturnClassifiedAppliedWithoutResponse (InitializationCallHttpStatus 400)
        ]
        $ \mode ->
          forM_ [CrashAfterInitEffectBeforeWorkerReceipt, CrashAfterInitWorkerReceiptCas] $ \crashPoint ->
            it ("recovers retained evidence under a fresh fence: " ++ show (mode, crashPoint)) $
              withFixture $ \fixture -> do
                harness <- newHarness fixture mode crashPoint
                firstEngine <- requireEngine fixture harness
                _ <- invokeAdapter fixture (requireSettings 30_449) firstEngine BrokerVaultInitialize
                before <- readIORef harness
                renewPhysicalFence harness
                engine <- requireProductionAdmissionEngine fixture harness ResumeSnapshotStable
                result <- invokeSuccessorInitialization fixture engine
                after <- readIORef harness
                case (mode, crashPoint) of
                  (ReturnEncryptedInitResponse, CrashAfterInitWorkerReceiptCas) -> do
                    result `shouldBeRouteSuccess` BrokerVaultInitialize
                    rootInitIsDurable fixture after `shouldBe` True
                  _ -> do
                    result `shouldSatisfy` isInitializationAmbiguous
                    physicalRootInitIsAmbiguous fixture after `shouldBe` True
                    let expectedCause = case (mode, crashPoint) of
                          (ReturnClassifiedAppliedWithoutResponse cause, CrashAfterInitWorkerReceiptCas) -> cause
                          _ -> InitializationCauseUnclassified
                    case result of
                      Left (EngineInitializationAmbiguous _ cause) -> cause `shouldBe` expectedCause
                      _ -> expectationFailure "expected exact retained ambiguity cause"
                let suffix = drop (length (harnessEvents before)) (harnessEvents after)
                length [() | InitVaultEffectApplied <- harnessEvents after] `shouldBe` 1
                length [() | WorkerAllocated SecretWorkerInitialize <- suffix] `shouldBe` 0
                length [() | WorkerExecuted SecretWorkerInitialize <- suffix] `shouldBe` 0
                length [() | StoreMutated BootstrapStoreCreateRootInitJournal <- suffix] `shouldBe` 0
                suffix `shouldSatisfy` elem (FenceAcquired 2)
                suffix `shouldSatisfy` notElem (PhysicalMutated BootstrapVaultResetAmbiguousInitialization)
                harnessFenceFloor after `shouldBe` 2
                harnessHeldFence after `shouldBe` Nothing
                assertCleanHarness after

      it "refuses contradictory positive response and worker evidence without retiring either" $
        withFixture $ \fixture -> do
          harness <- newHarness fixture ReturnAppliedWithoutResponse CrashAfterInitWorkerReceiptCas
          firstEngine <- requireEngine fixture harness
          _ <- invokeAdapter fixture (requireSettings 30_449) firstEngine BrokerVaultInitialize
          modifyIORef' harness $ \state ->
            state
              { harnessEncryptedResponse =
                  Just (Versioned (StoreVersion 1) storeDigest (fixtureEncryptedResponse fixture))
              }
          before <- readIORef harness
          renewPhysicalFence harness
          engine <- requireProductionAdmissionEngine fixture harness ResumeSnapshotStable
          result <- invokeSuccessorInitialization fixture engine
          case result of
            Left failure -> failure `shouldBe` EngineSecretWorkerRefused EngineSecretWorkerAuthoritativeResultMismatch
            Right _ -> expectationFailure "contradictory positive evidence must refuse"
          after <- readIORef harness
          harnessWorkerCheckpoint after `shouldBe` harnessWorkerCheckpoint before
          harnessEncryptedResponse after `shouldBe` harnessEncryptedResponse before
          let suffix = drop (length (harnessEvents before)) (harnessEvents after)
          suffix `shouldSatisfy` notElem (WorkerDiscarded SecretWorkerInitialize)
          length [() | InitVaultEffectApplied <- harnessEvents after] `shouldBe` 1

      it "refuses foreign binding, schema and recipient metadata in a durable worker response" $
        withFixture $ \fixture -> do
          let original = fixturePrepared fixture
              commitment = preparedInitRecipientCommitment original
              foreignCommitment =
                mustRight
                  ( mkInitRecipientCommitment
                      (initRecipientShareCount commitment)
                      (initRecipientThreshold commitment)
                      (initRecipientRecoveryPublicKeysBase64 commitment)
                      (initRecipientRecoveryFingerprint commitment)
                      (initRecipientBurnFingerprint commitment)
                      (digestOf '0')
                  )
              prepared proof schema recipients =
                mkPreparedInitEnvelope
                  proof
                  schema
                  (preparedInitSealedRecoveryPrivateKey original)
                  recipients
                  (preparedInitEnvelopeDigest original)
              variants =
                [
                  ( "binding"
                  , prepared
                      (resetReplacementPristine (fixtureResetProof fixture))
                      (preparedInitSchemaVersion original)
                      commitment
                  )
                , ("schema", prepared (fixturePristine fixture) (mustRight (mkBootstrapSchemaVersion 2)) commitment)
                ,
                  ( "recipient"
                  , prepared (fixturePristine fixture) (preparedInitSchemaVersion original) foreignCommitment
                  )
                ]
              originalReceipt = fixtureEncryptedResponse fixture
          foreignCommitment `shouldNotBe` commitment
          forM_ variants $ \(label, foreignPrepared) -> do
            harness <- newHarness fixture ReturnEncryptedInitResponse CrashAfterInitEffectBeforeWorkerReceipt
            firstEngine <- requireEngine fixture harness
            _ <- invokeAdapter fixture (requireSettings 30_449) firstEngine BrokerVaultInitialize
            request <- requireLastWorkerRequest harness
            let foreignReceipt =
                  mustRight
                    ( mkEncryptedInitResponseReceipt
                        foreignPrepared
                        (encryptedResponseShares originalReceipt)
                        (encryptedResponseBurnToken originalReceipt)
                        (encryptedResponseReceiptDigest originalReceipt)
                    )
                foreignCheckpoint =
                  mustRight
                    ( authoritativelyRecoveredWorkerCheckpoint
                        request
                        (encryptedInitializationWorkerResult foreignReceipt)
                    )
            modifyIORef' harness $ \state ->
              state
                { harnessWorkerCheckpoint =
                    Just (Versioned (StoreVersion 100) storeDigest foreignCheckpoint)
                }
            before <- readIORef harness
            renewPhysicalFence harness
            engine <- requireProductionAdmissionEngine fixture harness ResumeSnapshotStable
            result <- invokeSuccessorInitialization fixture engine
            case result of
              Left failure -> failure `shouldBe` EngineResponseEvidenceMismatch BrokerVaultInitialize
              Right _ -> expectationFailure ("foreign worker response admitted: " ++ label)
            after <- readIORef harness
            harnessRootJournal after `shouldBe` harnessRootJournal before
            harnessWorkerCheckpoint after `shouldBe` harnessWorkerCheckpoint before
            let suffix = drop (length (harnessEvents before)) (harnessEvents after)
            suffix `shouldSatisfy` notElem (WorkerDiscarded SecretWorkerInitialize)
            length [() | InitVaultEffectApplied <- harnessEvents after] `shouldBe` 1

      it "preserves unavailable response or worker evidence instead of producing ambiguity" $
        withFixture $ \fixture -> do
          harness <- newHarness fixture ReturnAppliedWithoutResponse NoCrash
          let ordinary = physicalStoreBoundary fixture harness
              unavailable =
                [ ordinary {Store.readEncryptedInitResponse = \_ -> pure (Left BootstrapStoreUnavailable)}
                , ordinary {Store.readSecretWorkerCheckpoint = pure (Left BootstrapStoreUnavailable)}
                ]
          forM_ unavailable $ \store -> do
            result <-
              InitRecovery.observeRootInitRecoveryEvidence
                store
                (pristineStorageBinding (fixturePristine fixture))
                (\_ -> pure (Right Nothing))
            result `shouldBe` Left BootstrapStoreUnavailable

      it "resumes the authoritative terminal checkpoint after its CAS reply is lost" $
        withFixture $ \fixture -> do
          harness <- newHarness fixture ReturnAppliedWithoutResponse CrashAfterInitEffectBeforeWorkerReceipt
          firstEngine <- requireEngine fixture harness
          _ <- invokeAdapter fixture (requireSettings 30_449) firstEngine BrokerVaultInitialize
          before <- readIORef harness
          modifyIORef' harness $ \state ->
            state
              { harnessCrashPoint = CrashAfterAuthoritativeWorkerCheckpointCas
              , harnessCrashTriggered = False
              }
          renewPhysicalFence harness
          secondEngine <- requireProductionAdmissionEngine fixture harness ResumeSnapshotStable
          second <- invokeSuccessorInitialization fixture secondEngine
          case second of
            Left (EngineSecretWorkerRefused (EngineSecretWorkerStoreRefused BootstrapStoreUnavailable)) -> pure ()
            _ -> expectationFailure "expected lost authoritative-worker CAS reply"
          middle <- readIORef harness
          initWorkerAuthoritativelyComplete middle `shouldBe` True
          fmap rootInitJournalPhaseForTest (storedValue (harnessRootJournal middle))
            `shouldBe` Just InitCallInFlight
          renewPhysicalFence harness
          thirdEngine <- requireProductionAdmissionEngine fixture harness ResumeSnapshotStable
          third <- invokeSuccessorInitialization fixture thirdEngine
          third `shouldSatisfy` isInitializationAmbiguous
          after <- readIORef harness
          physicalRootInitIsAmbiguous fixture after `shouldBe` True
          length [() | InitVaultEffectApplied <- harnessEvents after] `shouldBe` 1
          let recoveryEvents = drop (length (harnessEvents before)) (harnessEvents after)
          length [() | WorkerDiscarded SecretWorkerInitialize <- recoveryEvents] `shouldBe` 1
          harnessFenceFloor after `shouldBe` 3

      it "observes durable ambiguity after the root-journal CAS reply is lost" $
        withFixture $ \fixture -> do
          harness <- newHarness fixture ReturnAppliedWithoutResponse CrashAfterInitEffectBeforeWorkerReceipt
          firstEngine <- requireEngine fixture harness
          _ <- invokeAdapter fixture (requireSettings 30_449) firstEngine BrokerVaultInitialize
          before <- readIORef harness
          modifyIORef' harness $ \state ->
            state {harnessCrashPoint = CrashAfterRootAmbiguityCas, harnessCrashTriggered = False}
          renewPhysicalFence harness
          secondEngine <- requireProductionAdmissionEngine fixture harness ResumeSnapshotStable
          second <- invokeSuccessorInitialization fixture secondEngine
          second `shouldSatisfy` isStoreUnavailable
          middle <- readIORef harness
          physicalRootInitIsAmbiguous fixture middle `shouldBe` True
          initWorkerAuthoritativelyComplete middle `shouldBe` True
          thirdEngine <- requireProductionAdmissionEngine fixture harness ResumeSnapshotStable
          third <- invokeSuccessorInitialization fixture thirdEngine
          case third of
            Left
              ( EngineProgramEvidenceRefused
                  (EngineBoundaryRootInitializationEvidence InitEvidence.InitEvidenceAmbiguousNeedsReset)
                ) -> pure ()
            _ -> expectationFailure "durable ambiguity must retain the registered reset gate"
          after <- readIORef harness
          harnessRootJournal after `shouldBe` harnessRootJournal middle
          length [() | InitVaultEffectApplied <- harnessEvents after] `shouldBe` 1
          let recoveryEvents = drop (length (harnessEvents before)) (harnessEvents after)
          length [() | WorkerDiscarded SecretWorkerInitialize <- recoveryEvents] `shouldBe` 1

    describe "BOOTSTRAP-INITIALIZE-PROGRAM-EVIDENCE-REFUSAL-2026-10-22" $ do
      it "banks the refusal without claiming the planted journal was observed live" $ do
        bytes <-
          LazyByteString.readFile
            "test/qualification/BOOTSTRAP-INITIALIZE-PROGRAM-EVIDENCE-REFUSAL-2026-10-22.json"
        value <- either (fail . show) pure (eitherDecodeStrict' (LazyByteString.toStrict bytes))
        observed <-
          either fail pure $
            parseEither
              ( withObject "recording" $ \root -> do
                  provider <- root .: "observed_provider_behavior"
                  (,,)
                    <$> provider .: "http_status"
                    <*> provider .: "closed_engine_constructor"
                    <*> provider .: "live_journal_phase_observed"
              )
              value
        observed `shouldBe` (409 :: Int, "EngineProgramEvidenceRefused" :: Text, False)

      it "separates absent and exact pristine admission from initialized state" $
        withFixture $ \fixture -> do
          let proof = productionPristineStorageProof (pristineStorageBinding (fixturePristine fixture))
              cases =
                [ InitEvidence.RootInitJournalAbsent
                , InitEvidence.RootInitJournalPresent (StoreVersion 1) (newRootInitState proof)
                ]
          forM_ cases $ \observed -> do
            InitEvidence.classifyRootInitializationEvidence proof False observed
              `shouldBe` Right (BeginRootInitialization proof)
            InitEvidence.classifyRootInitializationEvidence proof True observed
              `shouldBe` Left (InitEvidence.InitEvidenceVaultStateMismatch InitPristine)

      forM_ rootInitializationContinuationCases $ \(label, makePhase, initialized) ->
        it ("admits the exact retained continuation: " ++ label) $
          withFixture $ \fixture -> do
            let proof = fixturePristine fixture
                state = (newRootInitState proof) {rootInitStatePhase = makePhase fixture}
                observation = InitEvidence.RootInitJournalPresent (StoreVersion 4) state
            rootInitInvariantViolations state `shouldBe` []
            case InitEvidence.classifyRootInitializationEvidence proof initialized observation of
              Right (ContinueRootInitialization evidence) -> do
                InitEvidence.rootInitResumeSnapshot evidence `shouldBe` state
                InitEvidence.rootInitResumeVersion evidence `shouldBe` StoreVersion 4
                InitEvidence.rootInitResumePristineCommitment evidence `shouldBe` proof
              other -> expectationFailure (show other)
            classifyPristineJournal
              (pristineStorageBinding proof)
              (StoreObjectPresent (StoreVersion 4) (digestOf 'd') state)
              `shouldBe` Left PristineJournalPhaseAdvanced
            let opposite = InitEvidence.classifyRootInitializationEvidence proof (not initialized) observation
            if rootInitJournalPhaseForTest state == InitCallInFlight
              then opposite `shouldSatisfy` isContinuationEvidence
              else
                opposite
                  `shouldBe` Left
                    (InitEvidence.InitEvidenceVaultStateMismatch (rootInitJournalPhaseForTest state))

      it "refuses foreign, inconsistent and cancelled snapshots" $
        withFixture $ \fixture -> do
          let proof = fixturePristine fixture
              replacement = resetReplacementPristine (fixtureResetProof fixture)
              state = (newRootInitState proof) {rootInitStatePhase = RootInitCallInFlight (fixturePrepared fixture)}
              observed value = InitEvidence.RootInitJournalPresent (StoreVersion 4) value
              classify = InitEvidence.classifyRootInitializationEvidence proof False
              cancelled =
                state
                  { rootInitStateDisposition =
                      CustodyCancellationRequested
                        (mustRight (mkCancellationReason "private-cancellation-sentinel"))
                  }
          classify (observed (state {rootInitStateBinding = pristineStorageBinding replacement}))
            `shouldBe` Left (InitEvidence.InitEvidencePristineRefused PristineJournalBindingMismatch)
          InitEvidence.classifyRootInitializationEvidence
            replacement
            False
            (observed (state {rootInitStateBinding = pristineStorageBinding replacement}))
            `shouldBe` Left InitEvidence.InitEvidenceJournalInvalid
          InitEvidence.classifyRootInitializationEvidence
            (productionPristineStorageProof (pristineStorageBinding proof))
            False
            (observed state)
            `shouldBe` Left (InitEvidence.InitEvidenceOriginalPristineMismatch InitCallInFlight)
          classify (observed cancelled) `shouldBe` Left InitEvidence.InitEvidenceCancelled
          InitEvidence.rootInitEvidenceCauseCode InitEvidence.InitEvidenceCancelled
            `shouldNotContain` "private-cancellation-sentinel"

      it "preserves ambiguity for explicit audited reset" $
        withFixture $ \fixture -> do
          let ambiguity = fixtureAmbiguity fixture
              proof = productionPristineStorageProof (ambiguousInitBinding ambiguity)
              snapshot = (newRootInitState proof) {rootInitStatePhase = RootInitializationAmbiguous ambiguity}
          forM_ [False, True] $ \initialized ->
            InitEvidence.classifyRootInitializationEvidence
              proof
              initialized
              (InitEvidence.RootInitJournalPresent (StoreVersion 4) snapshot)
              `shouldBe` Left InitEvidence.InitEvidenceAmbiguousNeedsReset

      it "round trips closed phases and refuses unknown phase text" $ do
        let phases = [minBound .. maxBound] :: [RootInitJournalPhase]
        map (InitEvidence.parseRootInitJournalPhase . InitEvidence.rootInitJournalPhaseText) phases
          `shouldBe` map Just phases
        InitEvidence.parseRootInitJournalPhase "private-unknown-phase" `shouldBe` Nothing
        map
          InitEvidence.rootInitializationPending
          [InitPristine, InitResetPristine, InitCustodyDurable, InitAmbiguous]
          `shouldBe` replicate 4 False
        InitEvidence.rootInitializationPending InitCallInFlight `shouldBe` True

      it "keeps refusal replies compatible and diagnoses only closed causes" $ do
        let failure cause = EngineProgramEvidenceRefused (EngineBoundaryRootInitializationEvidence cause)
            unavailable = InitEvidence.InitEvidenceUnavailable InitEvidence.InitStatusRead
            refused = InitEvidence.InitEvidenceVaultStateMismatch InitResponseWritten
        engineErrorReply (failure unavailable)
          `shouldBe` (Server.BrokerReplyServiceUnavailable, "{\"status\":\"boundary-unavailable\"}")
        engineErrorReply (failure refused)
          `shouldBe` (Server.BrokerReplyConflict, "{\"status\":\"boundary-refused\"}")
        brokerEngineErrorDiagnostic BrokerVaultInitialize (failure refused)
          `shouldContain` "InitEvidenceVaultStateMismatch InitResponseWritten"

      forM_ [CrashAfterInitEffectBeforeWorkerReceipt, CrashAfterInitWorkerReceiptCas] $ \crashPoint ->
        it ("reaches authoritative recovery through production admission after " ++ show crashPoint) $
          withFixture $ \fixture -> do
            harness <- newHarness fixture ReturnEncryptedInitResponse crashPoint
            firstEngine <- requireEngine fixture harness
            first <- invokeAdapter fixture (requireSettings 30_449) firstEngine BrokerVaultInitialize
            first `shouldSatisfy` either (const True) (const False)
            before <- readIORef harness
            case storedValue (harnessRootJournal before) of
              Just snapshot -> rootInitJournalPhaseForTest snapshot `shouldBe` InitCallInFlight
              Nothing -> expectationFailure "the failed schedule must retain its journal"
            engine <- requireProductionAdmissionEngine fixture harness ResumeSnapshotStable
            result <- invokeAdapter fixture (requireSettings 30_449) engine BrokerVaultInitialize
            after <- readIORef harness
            case crashPoint of
              CrashAfterInitEffectBeforeWorkerReceipt -> do
                result `shouldSatisfy` isInitializationAmbiguous
                physicalRootInitIsAmbiguous fixture after `shouldBe` True
              _ -> do
                result `shouldBeRouteSuccess` BrokerVaultInitialize
                rootInitIsDurable fixture after `shouldBe` True
                workerCheckpointIsComplete after `shouldBe` True
            length [() | InitVaultEffectApplied <- harnessEvents after] `shouldBe` 1
            assertCleanHarness after

      forM_ [CrashAfterInitEffectBeforeWorkerReceipt, CrashAfterInitWorkerReceiptCas] $ \crashPoint ->
        it
          ("keeps missing-response recovery ambiguous after " ++ show crashPoint)
          $ withFixture
          $ \fixture -> do
            harness <- newHarness fixture ReturnAppliedWithoutResponse crashPoint
            firstEngine <- requireEngine fixture harness
            _ <- invokeAdapter fixture (requireSettings 30_449) firstEngine BrokerVaultInitialize
            before <- readIORef harness
            engine <- requireProductionAdmissionEngine fixture harness ResumeSnapshotStable
            result <- invokeAdapter fixture (requireSettings 30_449) engine BrokerVaultInitialize
            result `shouldSatisfy` isInitializationAmbiguous
            after <- readIORef harness
            physicalRootInitIsAmbiguous fixture after `shouldBe` True
            length [() | InitVaultEffectApplied <- harnessEvents after] `shouldBe` 1
            let suffix = drop (length (harnessEvents before)) (harnessEvents after)
            length [() | StoreMutated BootstrapStoreCreateRootInitJournal <- suffix] `shouldBe` 0
            suffix `shouldSatisfy` notElem (PhysicalMutated BootstrapVaultResetAmbiguousInitialization)
            harnessHeldFence after `shouldBe` Nothing

      forM_
        [ (ResumeSnapshotDisappears, InitEvidence.InitEvidenceResumeAbsent)
        , (ResumeSnapshotVersionChanges, InitEvidence.InitEvidenceResumeChanged)
        ]
        $ \(fault, cause) ->
          it ("refuses a changed continuation without recreating or repeating init: " ++ show fault) $
            withFixture $ \fixture -> do
              harness <- newHarness fixture ReturnEncryptedInitResponse CrashAfterInitWorkerReceiptCas
              firstEngine <- requireEngine fixture harness
              _ <- invokeAdapter fixture (requireSettings 30_449) firstEngine BrokerVaultInitialize
              before <- readIORef harness
              engine <- requireProductionAdmissionEngine fixture harness fault
              result <- invokeAdapter fixture (requireSettings 30_449) engine BrokerVaultInitialize
              result `shouldSatisfy` isRootInitializationEvidenceFailure cause
              after <- readIORef harness
              let suffix = drop (length (harnessEvents before)) (harnessEvents after)
              length [() | StoreMutated BootstrapStoreCreateRootInitJournal <- suffix] `shouldBe` 0
              length [() | InitVaultEffectApplied <- harnessEvents after] `shouldBe` 1

    it "Sprint 2.54 classifies absent, exact retained, foreign, and progressed journals identically" $
      withFixture $ \fixture -> do
        let originalBinding = pristineStorageBinding (fixturePristine fixture)
            replacementBinding =
              pristineStorageBinding
                (resetReplacementPristine (fixtureResetProof fixture))
            originalExpected = productionPristineStorageProof originalBinding
            replacementExpected = productionPristineStorageProof replacementBinding
            oldBinding = ambiguousInitBinding (fixtureAmbiguity fixture)
            exactReset =
              mustRight
                ( mkPristineResetProof
                    (fixtureAmbiguity fixture)
                    replacementExpected
                    (mkEstablishedStateAbsence oldBinding (digestOf 'a'))
                    (mkDurableInitResponseAbsence oldBinding (digestOf 'b'))
                    (mkBaselineStateAbsence oldBinding (digestOf 'c'))
                )
            present state =
              StoreObjectPresent (StoreVersion 4) (digestOf 'd') state
            exactPristine = newRootInitState originalExpected
            exactResetPristine =
              (newRootInitState replacementExpected)
                { rootInitStatePhase = RootResetPristine exactReset
                }
            foreignProof =
              mkPristineStorageProof originalBinding (digestOf 'e')
            foreignPristine = newRootInitState foreignProof
            progressed =
              exactPristine
                { rootInitStatePhase =
                    RootPreparedWritePending (fixturePrepared fixture)
                }
            anotherBinding = newRootInitState replacementExpected
            cases =
              [
                ( "absent" :: Text
                , originalBinding
                , StoreObjectAbsent
                , Right originalExpected
                )
              ,
                ( "exact pristine"
                , originalBinding
                , present exactPristine
                , Right originalExpected
                )
              ,
                ( "exact reset pristine"
                , replacementBinding
                , present exactResetPristine
                , Right replacementExpected
                )
              ,
                ( "foreign proof"
                , originalBinding
                , present foreignPristine
                , Left PristineJournalProofMismatch
                )
              ,
                ( "progressed phase"
                , originalBinding
                , present progressed
                , Left PristineJournalPhaseAdvanced
                )
              ,
                ( "foreign binding"
                , originalBinding
                , present anotherBinding
                , Left PristineJournalBindingMismatch
                )
              ]
        forM_ cases $ \(label, binding, observation, expected) ->
          (label, classifyPristineJournal binding observation)
            `shouldBe` (label, expected)
    it "keeps the strict worker guard and distinct continuation admission wired" $ do
      controller <-
        Text.pack
          <$> readFile "src/Prodbox/Bootstrap/Broker/ProductionEngine.hs"
      worker <-
        Text.pack
          <$> readFile "src/Prodbox/Bootstrap/Broker/ProductionSecretWorker.hs"
      let functionRegion start finish source =
            fst (Text.breakOn finish (snd (Text.breakOn start source)))
          controllerRegion =
            functionRegion
              "\ninitializationEvidence settings store action = do"
              "\nresetEvidence"
              controller
          workerRegion =
            functionRegion
              "\nprepareInitialization settings store kubernetes binding request payload = do"
              "\nresumeInitialization"
              worker
      Text.count "classifyRootInitializationEvidence" controllerRegion
        `shouldBe` 1
      Text.count "classifyPristineJournal binding observation" workerRegion
        `shouldBe` 1
      Text.isInfixOf "StoreObjectPresent" workerRegion `shouldBe` False
    it "resumes root initialization under the same fence and durably completes exact PGP custody" $
      withFixture $ \fixture -> do
        harness <-
          newHarness fixture ReturnEncryptedInitResponse CrashAfterRootJournalCas
        engine <- requireEngine fixture harness
        let settings = requireSettings 30_444
        first <- invokeAdapter fixture settings engine BrokerVaultInitialize
        first `shouldSatisfy` isStoreUnavailable
        firstState <- readIORef harness
        harnessHeldFence firstState `shouldSatisfy` maybe False (const True)
        second <- invokeAdapter fixture settings engine BrokerVaultInitialize
        second `shouldSatisfy` isRouteSuccess BrokerVaultInitialize
        state <- readIORef harness
        rootInitIsDurable fixture state `shouldBe` True
        harnessPreparedEnvelope state `shouldBe` Nothing
        storedValue (harnessEncryptedResponse state)
          `shouldBe` Just (fixtureEncryptedResponse fixture)
        storedValue (harnessFinalBundle state)
          `shouldBe` Just (fixtureFinalBundle fixture)
        fenceLifecycleEvents (harnessEvents state)
          `shouldBe` [FenceAcquired 1, FenceResumed 1, FenceReleased 1]
        initRecipientEvents (harnessEvents state)
          `shouldBe` [ InitRecipientsObserved
                         ( initRecipientRecoveryPublicKeysBase64
                             ( preparedInitRecipientCommitment
                                 (fixturePrepared fixture)
                             )
                         )
                         (Settings.burnRecipientPublicKeyBase64 Settings.compiledBurnRecipient)
                         (expectedInitShareCount fixture)
                         (expectedInitThreshold fixture)
                     ]
        custodyPgpEvents (harnessEvents state)
          `shouldBe` [ "verify-compiled-burn"
                     , "prepare-recovery-recipient"
                     , "verify-compiled-burn"
                     , "resume-recovery-recipient"
                     , "verify-compiled-burn"
                     , "resume-recovery-recipient"
                     , "decrypt-recovery-shares"
                     , "seal-final-unlock-payload"
                     ]
        workerExecutionEvents (harnessEvents state)
          `shouldBe` [ SecretWorkerPrepareInitialization
                     , SecretWorkerResumeInitialization
                     , SecretWorkerInitialize
                     , SecretWorkerResumeInitialization
                     , SecretWorkerFinalizeInitialization
                     ]
        assertCleanHarness state
        assertCapabilityEvents fixture BrokerVaultInitialize 2 state

    it "distinguishes response loss before and after worker-result durability without replay" $
      withFixture $ \fixture ->
        forM_
          [ CrashAfterInitEffectBeforeWorkerReceipt
          , CrashAfterInitWorkerReceiptCas
          ]
          $ \crashPoint -> do
            harness <-
              newHarness fixture ReturnEncryptedInitResponse crashPoint
            firstEngine <- requireEngine fixture harness
            let settings = requireSettings 30_449
            first <-
              invokeAdapter
                fixture
                settings
                firstEngine
                BrokerVaultInitialize
            first `shouldSatisfy` either (const True) (const False)
            secondEngine <- requireEngine fixture harness
            second <-
              invokeAdapter
                fixture
                settings
                secondEngine
                BrokerVaultInitialize
            state <- readIORef harness
            case crashPoint of
              CrashAfterInitEffectBeforeWorkerReceipt -> do
                second `shouldSatisfy` isInitializationAmbiguous
                physicalRootInitIsAmbiguous fixture state `shouldBe` True
              _ -> do
                second `shouldBeRouteSuccess` BrokerVaultInitialize
                rootInitIsDurable fixture state `shouldBe` True
                workerCheckpointIsComplete state `shouldBe` True
            length [() | InitVaultEffectApplied <- harnessEvents state]
              `shouldBe` 1
            length
              [ ()
              | WorkerExecuted SecretWorkerInitialize <- harnessEvents state
              ]
              `shouldBe` 1
            assertCleanHarness state

    it "latches applied-without-response ambiguity, releases its fence, and performs audited reset" $
      withFixture $ \fixture -> do
        harness <- newHarness fixture ReturnAppliedWithoutResponse NoCrash
        engine <- requireEngine fixture harness
        let settings = requireSettings 30_445
        initialized <-
          invokeAdapter fixture settings engine BrokerVaultInitialize
        initialized `shouldSatisfy` isInitializationAmbiguous
        ambiguousState <- readIORef harness
        physicalRootInitIsAmbiguous fixture ambiguousState `shouldBe` True
        harnessHeldFence ambiguousState `shouldBe` Nothing
        reset <-
          invokeAdapter
            fixture
            settings
            engine
            BrokerVaultResetAmbiguousInitialization
        reset
          `shouldSatisfy` isRouteSuccess BrokerVaultResetAmbiguousInitialization
        state <- readIORef harness
        rootInitIsResetPristine fixture state `shouldBe` True
        harnessRootBinding state
          `shouldBe` pristineStorageBinding
            (resetReplacementPristine (fixtureResetProof fixture))
        fenceLifecycleEvents (harnessEvents state)
          `shouldBe` [ FenceAcquired 1
                     , FenceReleased 1
                     , FenceAcquired 2
                     , FenceReleased 2
                     ]
        harnessEvents state
          `shouldSatisfy` elem
            (PhysicalMutated BootstrapVaultResetAmbiguousInitialization)
        harnessBurnDecryptCount state `shouldBe` 0
        assertCleanHarness state

    it "replays an audited reset after losing the response to the storage-generation CAS" $
      withFixture $ \fixture -> do
        harness <- newHarness fixture ReturnAppliedWithoutResponse NoCrash
        engine <- requireEngine fixture harness
        let settings = requireSettings 30_451
        initialized <-
          invokeAdapter fixture settings engine BrokerVaultInitialize
        initialized `shouldSatisfy` isInitializationAmbiguous
        modifyIORef' harness $ \state ->
          state
            { harnessCrashPoint = CrashAfterResetGenerationAdvance
            , harnessCrashTriggered = False
            }
        first <-
          invokeAdapter
            fixture
            settings
            engine
            BrokerVaultResetAmbiguousInitialization
        first `shouldSatisfy` isStoreUnavailable
        afterFirst <- readIORef harness
        harnessRootBinding afterFirst
          `shouldBe` pristineStorageBinding
            (resetReplacementPristine (fixtureResetProof fixture))
        rootResetPending afterFirst `shouldBe` True
        harnessPreparedEnvelope afterFirst `shouldSatisfy` maybe False (const True)
        second <-
          invokeAdapter
            fixture
            settings
            engine
            BrokerVaultResetAmbiguousInitialization
        second
          `shouldSatisfy` isRouteSuccess BrokerVaultResetAmbiguousInitialization
        state <- readIORef harness
        rootInitIsResetPristine fixture state `shouldBe` True
        harnessPreparedEnvelope state `shouldBe` Nothing
        assertCleanHarness state

    it "replays an audited reset after losing the response to its terminal journal CAS" $
      withFixture $ \fixture -> do
        harness <- newHarness fixture ReturnAppliedWithoutResponse NoCrash
        engine <- requireEngine fixture harness
        let settings = requireSettings 30_452
        initialized <-
          invokeAdapter fixture settings engine BrokerVaultInitialize
        initialized `shouldSatisfy` isInitializationAmbiguous
        modifyIORef' harness $ \state ->
          state
            { harnessCrashPoint = CrashAfterResetTerminalCas
            , harnessCrashTriggered = False
            }
        before <- readIORef harness
        first <-
          invokeAdapter
            fixture
            settings
            engine
            BrokerVaultResetAmbiguousInitialization
        first `shouldSatisfy` isStoreUnavailable
        afterFirst <- readIORef harness
        rootInitIsResetPristine fixture afterFirst `shouldBe` True
        second <-
          invokeAdapter
            fixture
            settings
            engine
            BrokerVaultResetAmbiguousInitialization
        second
          `shouldSatisfy` isRouteSuccess BrokerVaultResetAmbiguousInitialization
        state <- readIORef harness
        rootInitIsResetPristine fixture state `shouldBe` True
        let resetEvents =
              [ ()
              | PhysicalMutated BootstrapVaultResetAmbiguousInitialization <-
                  drop (length (harnessEvents before)) (harnessEvents state)
              ]
        length resetEvents `shouldBe` 1
        assertCleanHarness state

    it "rejects a reset once root custody is established without reaching the physical reset boundary" $
      withFixture $ \fixture -> do
        harness <- newHarness fixture ReturnEncryptedInitResponse NoCrash
        engine <- requireEngine fixture harness
        let settings = requireSettings 30_449
        initialized <-
          invokeAdapter fixture settings engine BrokerVaultInitialize
        initialized `shouldSatisfy` isRouteSuccess BrokerVaultInitialize
        before <- readIORef harness
        reset <-
          invokeAdapter
            fixture
            settings
            engine
            BrokerVaultResetAmbiguousInitialization
        reset `shouldSatisfy` isResetOutsideAmbiguity
        state <- readIORef harness
        rootInitIsDurable fixture state `shouldBe` True
        harnessPhysicalMutationCount state
          `shouldBe` harnessPhysicalMutationCount before
        let resetEvents = drop (length (harnessEvents before)) (harnessEvents state)
        resetEvents
          `shouldSatisfy` notElem
            (PhysicalMutated BootstrapVaultResetAmbiguousInitialization)
        resetEvents
          `shouldSatisfy` notElem (StoreMutated BootstrapStoreCasRootInitJournal)
        assertCleanHarness state

    it "retains only the armed journal after a mismatched physical reset proof" $
      withFixture $ \fixture -> do
        harness <- newHarness fixture ReturnAppliedWithoutResponse NoCrash
        engine <- requireEngine fixture harness
        let settings = requireSettings 30_450
        initialized <-
          invokeAdapter fixture settings engine BrokerVaultInitialize
        initialized `shouldSatisfy` isInitializationAmbiguous
        modifyIORef' harness $ \state ->
          state
            { harnessResetProofOverride =
                Just (fixtureMismatchedResetProof fixture)
            }
        before <- readIORef harness
        reset <-
          invokeAdapter
            fixture
            settings
            engine
            BrokerVaultResetAmbiguousInitialization
        reset `shouldSatisfy` isResetEvidenceMismatch
        state <- readIORef harness
        rootResetPending state `shouldBe` True
        rootInitIsResetPristine fixture state `shouldBe` False
        harnessRootBinding state
          `shouldBe` ambiguousInitBinding (fixtureAmbiguity fixture)
        let resetEvents = drop (length (harnessEvents before)) (harnessEvents state)
        resetEvents
          `shouldSatisfy` elem
            (PhysicalMutated BootstrapVaultResetAmbiguousInitialization)
        length [() | StoreMutated BootstrapStoreCasRootInitJournal <- resetEvents] `shouldBe` 1
        resetEvents `shouldSatisfy` notElem (StoreMutated BootstrapStoreAdvanceVaultStorageGeneration)
        resetEvents `shouldSatisfy` notElem (StoreMutated BootstrapStoreDeletePreparedInitEnvelope)
        assertCleanHarness state

    it "closes unseal and baseline before the separately fenced Authority handoff" $
      withFixture $ \fixture -> do
        harness <- newHarness fixture ReturnEncryptedInitResponse NoCrash
        engine <- requireEngine fixture harness
        withPhysicalServer fixture engine $ \settings -> do
          let endpoint = Client.brokerEndpointFromSettings settings
              context =
                Client.mkBrokerCallContext
                  (fixtureServiceIdentity fixture)
                  (mustRight (Request.mkIdempotencyKey "physical-unseal"))
                  (fixtureClientCredential fixture)
          response <-
            Client.unsealVault
              endpoint
              context
              (fixtureActions fixture BrokerVaultUnseal)
          response `shouldSatisfy` either (const False) (const True)
        state <- readIORef harness
        workerLifecycleEvents (harnessEvents state)
          `shouldBe` [ WorkerAllocated SecretWorkerUnseal
                     , WorkerAttested SecretWorkerUnseal
                     , WorkerExecuted SecretWorkerUnseal
                     , WorkerSessionRevoked
                     , WorkerExited
                     , WorkerDeleted
                     , WorkerAbsent
                     ]
        postUnsealIsComplete fixture state `shouldBe` False
        workerCheckpointIsComplete state `shouldBe` True
        assertCleanHarness state
        assertCapabilityEvents fixture BrokerVaultUnseal 1 state
        let adapterSettings = requireSettings 30_445
        baseline <-
          invokeAdapter fixture adapterSettings engine BrokerVaultBaselineReconcile
        baseline `shouldBeRouteSuccess` BrokerVaultBaselineReconcile
        afterBaseline <- readIORef harness
        postUnsealIsComplete fixture afterBaseline `shouldBe` False
        workerExecutionEvents (harnessEvents afterBaseline)
          `shouldSatisfy` elem SecretWorkerCompleteGeneratedRoot
        workerLifecycleEvents (harnessEvents afterBaseline)
          `shouldSatisfy` elem (WorkerAllocated SecretWorkerCompleteGeneratedRoot)
        workerLifecycleEvents (harnessEvents afterBaseline)
          `shouldSatisfy` elem (WorkerAbsent)
        handoff <-
          invokeAdapter fixture adapterSettings engine BrokerPostUnsealHandoffReconcile
        handoff `shouldBeRouteSuccess` BrokerPostUnsealHandoffReconcile
        afterHandoff <- readIORef harness
        postUnsealIsComplete fixture afterHandoff `shouldBe` True
        assertCleanHarness afterHandoff

    it "refuses the handoff mutation before durable baseline and never contacts Authority" $
      withFixture $ \fixture -> do
        harness <- newHarness fixture ReturnEncryptedInitResponse NoCrash
        engine <- requireEngine fixture harness
        early <-
          invokeAdapter
            fixture
            (requireSettings 30_446)
            engine
            BrokerPostUnsealHandoffReconcile
        early `shouldSatisfy` isStoreReadBackMismatch
        state <- readIORef harness
        postUnsealIsComplete fixture state `shouldBe` False
        harnessEvents state `shouldSatisfy` all (not . isPostUnsealConsumerCall)

    it "recovers a lost generated-root scope with a new identity and finishes through provisioner login" $
      withFixture $ \fixture -> do
        harness <-
          newHarness fixture ReturnEncryptedInitResponse CrashAfterRootScopeCas
        engine <- requireEngine fixture harness
        let settings = requireSettings 30_446
        unsealed <-
          invokeAdapter fixture settings engine BrokerVaultUnseal
        unsealed `shouldSatisfy` isRouteSuccess BrokerVaultUnseal
        first <-
          invokeAdapter fixture settings engine BrokerVaultBaselineReconcile
        first `shouldSatisfy` isStoreUnavailable
        second <-
          invokeAdapter fixture settings engine BrokerVaultBaselineReconcile
        second `shouldBeRouteSuccess` BrokerVaultBaselineReconcile
        state <- readIORef harness
        rootSessionIsClosed state `shouldBe` True
        harnessRootScopeCounter state `shouldBe` 2
        length (harnessIssuedRootTokens state) `shouldBe` 2
        length (harnessRevokedRootTokens state) `shouldBe` 2
        rootSessionIdentities (harnessEvents state)
          `shouldBe` [ fixtureSessionId fixture
                     , fixtureRestartSessionId fixture
                     ]
        harnessEvents state
          `shouldSatisfy` elem (PhysicalMutated BootstrapVaultCancelGenerateRoot)
        harnessEvents state
          `shouldSatisfy` elem (PhysicalMutated BootstrapVaultLoginProvisioner)
        harnessEvents state
          `shouldSatisfy` elem (PhysicalMutated BootstrapVaultApplyBaseline)
        harnessEvents state
          `shouldSatisfy` elem (PhysicalMutated BootstrapVaultReadBackBaseline)
        harnessLiveRootAccessors state `shouldBe` []
        assertCleanHarness state

    it "journals one provisioner login attempt and cleans a response-lost accessor before its successor" $
      withFixture $ \fixture -> do
        harness <-
          newHarness
            fixture
            ReturnEncryptedInitResponse
            CrashAfterProvisionerLoginResponseLoss
        engine <- requireEngine fixture harness
        let settings = requireSettings 30_457
        unsealed <- invokeAdapter fixture settings engine BrokerVaultUnseal
        unsealed `shouldSatisfy` isRouteSuccess BrokerVaultUnseal
        first <-
          invokeAdapter fixture settings engine BrokerVaultBaselineReconcile
        first `shouldSatisfy` isPhysicalUnavailable
        first `shouldSatisfy` isBaselinePhysicalStage BaselineLoginProvisioner
        afterLoss <- readIORef harness
        harnessLiveProvisionerAccessors afterLoss
          `shouldBe` [provisionerLoginAccessor (fixtureProvisionerReceipt fixture)]
        storedValue (harnessRootSession afterLoss)
          `shouldSatisfy` maybe False provisionerLoginAttemptIsJournaled
        second <-
          invokeAdapter fixture settings engine BrokerVaultBaselineReconcile
        second `shouldBeRouteSuccess` BrokerVaultBaselineReconcile
        state <- readIORef harness
        harnessLiveProvisionerAccessors state `shouldBe` []
        storedValue (harnessRootSession state)
          `shouldSatisfy` maybe False provisionerSessionIsDurablyClosed
        let loginCount =
              length
                [ ()
                | PhysicalMutated BootstrapVaultLoginProvisioner <- harnessEvents state
                ]
            cleanupCount =
              length
                [ ()
                | PhysicalMutated BootstrapVaultInventoryProvisionerAccessors <- harnessEvents state
                ]
        loginCount `shouldBe` 2
        cleanupCount `shouldSatisfy` (>= 3)
        assertCleanHarness state

    it "recovers and cleans a journaled provisioner accessor after exception or cancellation" $
      withFixture $ \fixture ->
        forM_
          [ CrashAfterProvisionerLoginException
          , CrashAfterProvisionerLoginCancellation
          ]
          $ \crashPoint -> do
            harness <-
              newHarness fixture ReturnEncryptedInitResponse crashPoint
            engine <- requireEngine fixture harness
            let settings = requireSettings 30_458
            unsealed <- invokeAdapter fixture settings engine BrokerVaultUnseal
            unsealed `shouldSatisfy` isRouteSuccess BrokerVaultUnseal
            interrupted <-
              try
                (invokeAdapter fixture settings engine BrokerVaultBaselineReconcile)
                :: IO
                     ( Either
                         SomeException
                         (Either BrokerEngineError SomeBrokerResponse)
                     )
            case (crashPoint, interrupted) of
              (CrashAfterProvisionerLoginCancellation, Left exception) ->
                (fromException exception :: Maybe AsyncException)
                  `shouldBe` Just ThreadKilled
              (CrashAfterProvisionerLoginException, Left exception) ->
                (fromException exception :: Maybe AsyncException)
                  `shouldBe` Nothing
              _ -> expectationFailure "expected provisioner physical interruption"
            afterInterruption <- readIORef harness
            harnessLiveProvisionerAccessors afterInterruption
              `shouldBe` [provisionerLoginAccessor (fixtureProvisionerReceipt fixture)]
            storedValue (harnessRootSession afterInterruption)
              `shouldSatisfy` maybe False provisionerLoginAttemptIsJournaled
            recovered <-
              invokeAdapter fixture settings engine BrokerVaultBaselineReconcile
            recovered `shouldBeRouteSuccess` BrokerVaultBaselineReconcile
            state <- readIORef harness
            harnessLiveProvisionerAccessors state `shouldBe` []
            storedValue (harnessRootSession state)
              `shouldSatisfy` maybe False provisionerSessionIsDurablyClosed
            assertCleanHarness state

    it
      "prepares/finalizes child custody and crash-recovers one-time delivery through repair, revoke, and absence"
      $ withFixture
      $ \fixture -> do
        harness <-
          newHarness fixture ReturnEncryptedInitResponse CrashAfterChildScopeCas
        engine <- requireEngine fixture harness
        let settings = requireSettings 30_447
        prepared <-
          invokeAdapter fixture settings engine BrokerChildCustodyPrepare
        prepared `shouldBeRouteSuccess` BrokerChildCustodyPrepare
        finalized <-
          invokeAdapter fixture settings engine BrokerChildCustodyFinalize
        finalized `shouldBeRouteSuccess` BrokerChildCustodyFinalize
        first <-
          invokeAdapter fixture settings engine BrokerChildRecoveryDeliver
        first `shouldSatisfy` isStoreUnavailable
        second <-
          invokeAdapter fixture settings engine BrokerChildRecoveryDeliver
        second `shouldBeRouteSuccess` BrokerChildRecoveryDeliver
        state <- readIORef harness
        childCustodyIsDurable fixture state `shouldBe` True
        harnessChildReceipt state `shouldBe` Nothing
        physicalChildRecoveryIsComplete fixture state `shouldBe` True
        harnessRecoveryDelivery state `shouldBe` Nothing
        harnessChildScopeCounter state `shouldBe` 2
        length (harnessIssuedChildTokens state) `shouldBe` 2
        length (harnessRevokedChildTokens state) `shouldBe` 2
        harnessEvents state
          `shouldSatisfy` elem (PhysicalMutated BootstrapVaultConsumeChildRecovery)
        harnessEvents state
          `shouldSatisfy` elem (PhysicalMutated BootstrapVaultCancelGenerateRoot)
        harnessEvents state
          `shouldSatisfy` elem (PgpExecuted "child-action-apply")
        harnessEvents state
          `shouldSatisfy` elem (PgpExecuted "child-action-read-back")
        harnessEvents state
          `shouldSatisfy` elem (PgpExecuted "child-action-revoke")
        harnessLiveRootAccessors state `shouldBe` []
        assertCleanHarness state

    it "attests only the exact-generation target after independently observing it absent" $
      withFixture $ \fixture -> do
        harness <- newHarness fixture ReturnEncryptedInitResponse NoCrash
        let expectedGeneration =
              rootInitStorageGeneration
                (recoveryCustodyBinding (fixtureRecovery fixture))
            target = fixtureCurrentInventory fixture
            observationDigest = digestOf 'a'
            replacementGeneration =
              rootInitStorageGeneration
                ( pristineStorageBinding
                    (resetReplacementPristine (fixtureResetProof fixture))
                )
            wrongGenerationTarget =
              mustRight
                ( mkRootAccessorInventory
                    replacementGeneration
                    [fixtureCurrentAccessor fixture]
                )
        observed <-
          proveAccessorTargetsAbsent
            harness
            expectedGeneration
            RootAccessorTargetsAbsentRequired
            target
            observationDigest
        observed
          `shouldBe` Right
            (mkAccessorAbsenceAttestation target observationDigest)

        addRootAccessor harness (fixtureCurrentAccessor fixture)
        present <-
          proveAccessorTargetsAbsent
            harness
            expectedGeneration
            RootAccessorTargetsAbsentRequired
            target
            observationDigest
        present
          `shouldBe` Left
            (EngineBoundaryRefused "accessor-absence target is still present")

        wrongGeneration <-
          proveAccessorTargetsAbsent
            harness
            expectedGeneration
            RootAccessorTargetsAbsentRequired
            wrongGenerationTarget
            observationDigest
        wrongGeneration
          `shouldBe` Left
            (EngineBoundaryRefused "accessor-absence generation mismatch")

        modifyIORef' harness $ \state ->
          state {harnessAccessorObservationAvailable = False}
        unobservable <-
          proveAccessorTargetsAbsent
            harness
            expectedGeneration
            RootAccessorTargetsAbsentRequired
            target
            observationDigest
        unobservable
          `shouldBe` Left
            (EngineBoundaryUnavailable "accessor-absence inventory unavailable")

    it "performs no store or physical mutation when fresh fence authorization is refused" $
      withFixture $ \fixture -> do
        harness <- newHarness fixture ReturnEncryptedInitResponse NoCrash
        modifyIORef' harness $ \state ->
          state {harnessLeaseAvailable = False}
        engine <- requireEngine fixture harness
        outcome <-
          invokeAdapter
            fixture
            (requireSettings 30_448)
            engine
            BrokerVaultSeal
        outcome `shouldSatisfy` isFenceUseRefused
        state <- readIORef harness
        harnessPhysicalMutationCount state `shouldBe` 0
        harnessStoreMutationCount state `shouldBe` 0
        physicalAndStoreMutationEvents (harnessEvents state) `shouldBe` []
        harnessPermitViolations state `shouldBe` []

rootInitializationContinuationCases :: [(String, Fixture -> RootInitPhase, Bool)]
rootInitializationContinuationCases =
  [ ("prepared write pending", RootPreparedWritePending . fixturePrepared, False)
  , ("prepared written", RootPreparedWritten . fixturePrepared, False)
  , ("prepared read back", RootPreparedReadBack . fixturePrepared, False)
  , ("call pending", RootInitCallPending . fixturePrepared, False)
  , ("in flight before observed application", RootInitCallInFlight . fixturePrepared, False)
  , ("in flight after observed application", RootInitCallInFlight . fixturePrepared, True)
  ,
    ( "response capture pending"
    , \f -> RootEncryptedResponseCapturePending (fixturePrepared f) (fixtureEncryptedResponse f)
    , True
    )
  ,
    ( "response written"
    , \f -> RootEncryptedResponseWritten (fixturePrepared f) (fixtureEncryptedResponse f)
    , True
    )
  ,
    ( "response read back"
    , \f -> RootEncryptedResponseReadBack (fixturePrepared f) (fixtureEncryptedResponse f)
    , True
    )
  ,
    ( "final promotion pending"
    , \f ->
        RootFinalBundlePromotionPending
          (fixturePrepared f)
          (fixtureEncryptedResponse f)
          (fixtureFinalBundle f)
    , True
    )
  ,
    ( "final promoted"
    , \f -> RootFinalBundlePromoted (fixturePrepared f) (fixtureEncryptedResponse f) (fixtureFinalBundle f)
    , True
    )
  ,
    ( "final read back"
    , \f -> RootFinalBundleReadBack (fixturePrepared f) (fixtureEncryptedResponse f) (fixtureFinalBundle f)
    , True
    )
  ,
    ( "prepared deletion pending"
    , \f -> RootPreparedDeletionPending (fixturePrepared f) (fixtureFinalBundle f)
    , True
    )
  , ("prepared deleted", \f -> RootPreparedDeleted (fixturePrepared f) (fixtureFinalBundle f), True)
  , ("prepared absent", RootPreparedAbsent . fixtureFinalBundle, True)
  ,
    ( "custody acknowledgement pending"
    , RootRecoveryCustodyAcknowledgementPending . fixtureFinalBundle
    , True
    )
  ,
    ( "custody durable"
    , \f -> RootRecoveryCustodyDurable (fixtureFinalBundle f) (fixtureRecovery f)
    , True
    )
  ]

rootInitJournalPhaseForTest :: RootInitState -> RootInitJournalPhase
rootInitJournalPhaseForTest = InitEvidence.rootInitJournalPhase . rootInitStatePhase

isContinuationEvidence
  :: Either InitEvidence.RootInitializationEvidenceCause RootInitializationEvidence -> Bool
isContinuationEvidence outcome = case outcome of
  Right (ContinueRootInitialization _) -> True
  _ -> False

data InitializationResumeFault
  = ResumeSnapshotStable
  | ResumeSnapshotDisappears
  | ResumeSnapshotVersionChanges
  deriving (Eq, Show)

isRootInitializationEvidenceFailure
  :: InitEvidence.RootInitializationEvidenceCause
  -> Either BrokerEngineError SomeBrokerResponse
  -> Bool
isRootInitializationEvidenceFailure expected outcome = case outcome of
  Left (EngineProgramEvidenceRefused (EngineBoundaryRootInitializationEvidence actual)) -> actual == expected
  _ -> False

applyInitializationResumeFault :: InitializationResumeFault -> HarnessState -> HarnessState
applyInitializationResumeFault fault state = case fault of
  ResumeSnapshotStable -> state
  ResumeSnapshotDisappears -> state {harnessRootJournal = Nothing}
  ResumeSnapshotVersionChanges ->
    state
      { harnessRootJournal =
          fmap
            (\stored -> stored {versionedVersion = nextStoreVersion (versionedVersion stored)})
            (harnessRootJournal state)
      }

renewPhysicalFence :: Harness -> IO ()
renewPhysicalFence harness =
  modifyIORef' harness $ \state ->
    let floorValue = case harnessHeldFence state of
          Nothing -> harnessFenceFloor state
          Just held -> bootstrapFenceGenerationValue (bootstrapFenceGeneration held)
     in state
          { harnessFenceFloor = floorValue
          , harnessHeldFence = Nothing
          , harnessFenceOwnerNonce =
              mustRight (mkOwnerNonce ("physical-successor-owner-" <> Text.pack (show (floorValue + 1))))
          }

invokeSuccessorInitialization
  :: Fixture -> BrokerEngine IO -> IO (Either BrokerEngineError SomeBrokerResponse)
invokeSuccessorInitialization fixture engine =
  runEngineBrokerRequest
    engine
    ( (requestContext fixture)
        { Server.brokerRequestDeadline =
            deadlineFromInstant
              (monotonicInstantFromMicros (deadlineMicros fixtureRequestDeadline + 100))
        }
    )
    BrokerVaultInitialize
    (requestBody fixture (requireSettings 30_449) BrokerVaultInitialize)

requireProductionAdmissionEngine
  :: Fixture -> Harness -> InitializationResumeFault -> IO (BrokerEngine IO)
requireProductionAdmissionEngine fixture harness fault =
  case mkBrokerEngine (fixtureCapabilityRefs fixture) 128 boundary of
    Left failure -> fail failure
    Right engine -> pure engine
 where
  base = baseEngineBoundary fixture harness
  evidence =
    (evidenceBoundary fixture harness)
      { resolveRootInitializationEvidence = \_ -> do
          state <- readIORef harness
          pure $ case InitEvidence.classifyRootInitializationEvidence
            (fixturePristine fixture)
            (InitVaultEffectApplied `elem` harnessEvents state)
            (rootInitJournalObservation (versionedReadBack (harnessRootJournal state))) of
            Left cause -> Left (EngineBoundaryRootInitializationEvidence cause)
            Right admitted -> Right admitted
      }
  boundary =
    base
      { engineEvidenceBoundary = evidence
      , engineAcquireMutationFence = \reference route action requestDigest deadline -> do
          acquired <- engineAcquireMutationFence base reference route action requestDigest deadline
          case acquired of
            Left _ -> pure ()
            Right _ -> modifyIORef' harness (applyInitializationResumeFault fault)
          pure acquired
      }

-- This boundary uses the same admission kernel and binding predicates as the
-- production producer. Only physical identity/absence observation is a fixture.
requireProductionResetEngine :: Fixture -> Harness -> IO (BrokerEngine IO)
requireProductionResetEngine = requireProductionResetEngineWithFault ResetReadStable

data ResetReadFault = ResetReadStable | ResetReadMissing | ResetReadActionChanges | ResetReadProofChanges
  deriving (Eq, Show)

requireProductionResetEngineWithFault
  :: ResetReadFault -> Fixture -> Harness -> IO (BrokerEngine IO)
requireProductionResetEngineWithFault fault fixture harness =
  either fail pure (mkBrokerEngine (fixtureCapabilityRefs fixture) 128 boundary)
 where
  base = baseEngineBoundary fixture harness
  store = engineStoreBoundary base
  boundary =
    base
      { engineEvidenceBoundary =
          (engineEvidenceBoundary base)
            { resolveAmbiguousResetEvidence = admit
            }
      , engineAcquireMutationFence = \reference route action requestDigest deadline -> do
          acquired <- engineAcquireMutationFence base reference route action requestDigest deadline
          case acquired of
            Left _ -> pure ()
            Right _ -> modifyIORef' harness (alterResetRead fault fixture)
          pure acquired
      }
  admit action = do
    current <- observeVaultStorageGeneration store
    journal <- readRootInitJournalForReset store (brokerActionStorageGeneration action)
    case (current, journal) of
      (Left _, _) ->
        pure
          ( Left
              ( EngineBoundaryRootResetEvidence
                  (ResetEvidence.ResetEvidenceUnavailable ResetEvidence.ResetGenerationRead)
              )
          )
      (_, Left _) ->
        pure
          ( Left
              ( EngineBoundaryRootResetEvidence
                  (ResetEvidence.ResetEvidenceBindingMismatch ResetEvidence.ResetJournalRead)
              )
          )
      (Right binding, Right observed) -> do
        let snapshot = case observed of
              StoreObjectAbsent -> Nothing
              StoreObjectPresent _ _ value -> Just value
        case ResetEvidence.classifyRootResetEvidence
          (brokerActionStorageGeneration action)
          (brokerActionDigest action)
          binding
          snapshot of
          Left cause -> pure (Left (EngineBoundaryRootResetEvidence cause))
          Right (ResetEvidence.ResumeAuditedRootReset proof) -> pure (Right (resetAmbiguity proof, proof))
          Right (ResetEvidence.AuditAmbiguousRootReset ambiguity) -> do
            prepared <- readPreparedInitEnvelope store (ambiguousInitBinding ambiguity)
            pure $ case prepared of
              Right (StoreObjectPresent _ _ envelope)
                | preparedInitEnvelopeDigest envelope == ambiguousPreparedEnvelopeDigest ambiguity ->
                    Right (ambiguity, fixtureResetProof fixture)
              _ -> Left (EngineBoundaryRootResetEvidence ResetEvidence.ResetEvidencePreparedAbsent)

alterResetRead :: ResetReadFault -> Fixture -> HarnessState -> HarnessState
alterResetRead fault fixture state = case fault of
  ResetReadStable -> state
  ResetReadMissing -> state {harnessRootJournal = Nothing}
  ResetReadActionChanges -> changePending (\proof _ -> RootResetInFlight proof (digestOf 'e'))
  ResetReadProofChanges -> changePending (\_ action -> RootResetInFlight (fixtureMismatchedResetProof fixture) action)
 where
  changePending replace =
    state
      { harnessRootJournal = fmap update (harnessRootJournal state)
      }
   where
    update stored = case rootInitStatePhase (versionedValue stored) of
      RootResetInFlight proof action ->
        stored
          { versionedVersion = nextStoreVersion (versionedVersion stored)
          , versionedValue = (versionedValue stored) {rootInitStatePhase = replace proof action}
          }
      _ -> stored

invokeResetFromDurableObservation
  :: Fixture
  -> Settings.BootstrapBrokerSettings
  -> BrokerEngine IO
  -> HarnessState
  -> IO (Either BrokerEngineError SomeBrokerResponse)
invokeResetFromDurableObservation fixture settings engine state = do
  snapshot <-
    maybe (fail "reset recovery journal absent") pure (storedValue (harnessRootJournal state))
  let phase = rootInitStatePhase snapshot
      requested =
        mustRight
          ( ResetEvidence.rootResetRequestGeneration
              (rootInitStorageGeneration (harnessRootBinding state))
              (Just (InitEvidence.rootInitJournalPhase phase))
              (InitEvidence.rootInitResetFromGeneration phase)
          )
      original = fixtureActions fixture BrokerVaultResetAmbiguousInitialization
      reconstructed route
        | route == BrokerVaultResetAmbiguousInitialization =
            mkBrokerActionRequest requested (brokerActionDigest original)
        | otherwise = fixtureActions fixture route
  invokeAdapter
    fixture {fixtureActions = reconstructed}
    settings
    engine
    BrokerVaultResetAmbiguousInitialization

withFixture :: (Fixture -> Expectation) -> Expectation
withFixture assertion = case buildFixture of
  Left failure -> expectationFailure ("invalid physical fixture: " ++ failure)
  Right fixture -> assertion fixture

requireEngine :: Fixture -> Harness -> IO (BrokerEngine IO)
requireEngine fixture harness = case physicalEngine fixture harness of
  Left failure -> throwIO (userError failure)
  Right engine -> pure engine

-- The fixture retains the conditional write while withholding its response.
transitJournalDeadlineRegression :: Expectation
transitJournalDeadlineRegression = withSocketsDo $ bracket open Socket.close $ \listener -> do
  address <- Socket.getSocketName listener
  port <- case address of
    SockAddrInet value _ -> pure value
    _ -> fail "Transit deadline fixture requires IPv4"
  applied <- newIORef False
  let reply connection code body =
        SocketBytes.sendAll connection $
          ByteString8.pack
            ( "HTTP/1.1 "
                ++ code
                ++ "\r\nContent-Length: "
                ++ show (ByteString.length body)
                ++ "\r\nConnection: close\r\n\r\n"
            )
            <> body
      serveOne = bracket (Socket.accept listener) (Socket.close . fst) $ \(connection, _) -> do
        received <- receiveClaimHeaders connection ByteString.empty
        let (header, rest) = ByteString.breakSubstring "\r\n\r\n" received
            lowerHeader = ByteString8.map toLower header
        if "HEAD " `ByteString.isPrefixOf` header
          then reply connection "200 OK" ""
          else
            if "GET " `ByteString.isPrefixOf` header
              then
                if ".transit-rotation-v1" `ByteString.isInfixOf` header
                  then reply connection "404 Not Found" ""
                  else reply connection "200 OK" "<ListBucketResult/>"
              else
                if "PUT " `ByteString.isPrefixOf` header
                  then do
                    let lengthHeader = find ("content-length:" `ByteString.isPrefixOf`) (ByteString8.lines lowerHeader)
                        bodyLength =
                          lengthHeader
                            >>= (fmap fst . ByteString8.readInt . ByteString8.dropWhile (== ' ') . ByteString8.drop 15)
                    size <- maybe (fail "Transit deadline PUT lacks content length") pure bodyLength
                    _ <- receiveClaimBody connection size (ByteString.drop 4 rest)
                    writeIORef applied True
                    threadDelay 4_000_000
                  else fail "unexpected Transit deadline fixture method"
      rawConfig = settingsConfig port
      rawStore = Settings.bootstrap_store rawConfig
      config =
        rawConfig
          { Settings.bootstrap_store =
              rawStore {Settings.store_endpoint = Text.pack ("http://127.0.0.1:" ++ show port)}
          }
      settings = mustRight (Settings.validateBootstrapBrokerConfig config)
  Async.withAsync (forever serveOne) $ \server -> do
    Async.link server
    wall <- getPOSIXTime
    now <- realMonotonicNow
    let fence =
          mustRight $
            reloadBootstrapSessionFence
              1
              (mustRight (mkOwnerNonce "fixture-owner"))
              (digestOf 'a')
              (mustRight (Request.mkRequestDigest (Text.replicate 64 "b")))
              (mustRight (mkVaultStorageGeneration "fixture-vault"))
              (floor (wall * 1_000_000) + 30_000_000)
        request =
          mkSecretFreeWorkerRequest
            SecretWorkerRotateTransitKey
            (mustRight (mkWorkerPodUid "fixture-pod"))
            (mustRight (mkWorkerImageDigest ("sha256:" <> Text.replicate 64 "c")))
            (mustRight (mkWorkerServiceAccount "fixture-worker"))
            (mustRight (mkWorkerSessionId "fixture-session"))
            workerSessionNotIssued
            fence
        deadline = deadlineAtOffset now (RemainingDuration 1_000_000)
        clock =
          AuthorityTimeTrusted
            (authorityTimeFromMicros (floor (wall * 1_000_000)))
            (clockUncertaintyFromMicros 0)
        lease = BootstrapLeaseObserved (bootstrapLeaseBindingForFence fence) deadline "fixture-rv"
        permit =
          mustRight
            ( authorizeBootstrapStoreMutation
                now
                deadline
                clock
                fence
                (BootstrapFenceStoreHeld fence)
                lease
                BootstrapStorePlanTransitRotation
            )
    result <-
      timeout 2_500_000 $
        ProductionStore.planProductionTransitRotation settings permit request "prodbox-active-config" 7
    case result of
      Just (Left BootstrapStoreUnavailable) -> pure ()
      _ -> expectationFailure "timed-out Transit journal write was not reported unavailable"
    readIORef applied `shouldReturn` True
 where
  open = do
    listener <- Socket.socket AF_INET Stream defaultProtocol
    Socket.setSocketOption listener Socket.ReuseAddr 1
    Socket.bind listener (SockAddrInet 0 literalIpv4Loopback)
    Socket.listen listener 4
    pure listener

transitJournalReadDeadlineRegression :: Expectation
transitJournalReadDeadlineRegression = withSocketsDo $ bracket open Socket.close $ \listener -> do
  address <- Socket.getSocketName listener
  port <- case address of
    SockAddrInet value _ -> pure value
    _ -> fail "Transit deadline fixture requires IPv4"
  let serveOne = bracket (Socket.accept listener) (Socket.close . fst) $ \(connection, _) -> do
        received <- receiveClaimHeaders connection ByteString.empty
        let (header, _) = ByteString.breakSubstring "\r\n\r\n" received
        if "GET " `ByteString.isPrefixOf` header
          then threadDelay 4_000_000
          else fail "unexpected Transit read fixture method"
      rawConfig = settingsConfig port
      rawStore = Settings.bootstrap_store rawConfig
      config =
        rawConfig
          { Settings.bootstrap_store =
              rawStore {Settings.store_endpoint = Text.pack ("http://127.0.0.1:" ++ show port)}
          }
      settings = mustRight (Settings.validateBootstrapBrokerConfig config)
  Async.withAsync (forever serveOne) $ \server -> do
    Async.link server
    wall <- getPOSIXTime
    now <- realMonotonicNow
    let fence =
          mustRight $
            reloadBootstrapSessionFence
              1
              (mustRight (mkOwnerNonce "fixture-owner"))
              (digestOf 'a')
              (mustRight (Request.mkRequestDigest (Text.replicate 64 "b")))
              (mustRight (mkVaultStorageGeneration "fixture-vault"))
              (floor (wall * 1_000_000) + 30_000_000)
        request =
          mkSecretFreeWorkerRequest
            SecretWorkerRotateTransitKey
            (mustRight (mkWorkerPodUid "fixture-pod"))
            (mustRight (mkWorkerImageDigest ("sha256:" <> Text.replicate 64 "c")))
            (mustRight (mkWorkerServiceAccount "fixture-worker"))
            (mustRight (mkWorkerSessionId "fixture-session"))
            workerSessionNotIssued
            fence
        deadline = deadlineAtOffset now (RemainingDuration 1_000_000)
        clock =
          AuthorityTimeTrusted
            (authorityTimeFromMicros (floor (wall * 1_000_000)))
            (clockUncertaintyFromMicros 0)
        lease = BootstrapLeaseObserved (bootstrapLeaseBindingForFence fence) deadline "fixture-rv"
        permit =
          mustRight
            ( authorizeBootstrapStoreMutation
                now
                deadline
                clock
                fence
                (BootstrapFenceStoreHeld fence)
                lease
                BootstrapStorePlanTransitRotation
            )
        otherRequest =
          mkSecretFreeWorkerRequest
            SecretWorkerUnseal
            (mustRight (mkWorkerPodUid "fixture-pod"))
            (mustRight (mkWorkerImageDigest ("sha256:" <> Text.replicate 64 "c")))
            (mustRight (mkWorkerServiceAccount "fixture-worker"))
            (mustRight (mkWorkerSessionId "fixture-session"))
            workerSessionNotIssued
            fence
    ProductionStore.observeProductionTransitRotationJournalWithinPermit settings permit otherRequest
      `shouldReturn` Left BootstrapStoreBindingMismatch
    result <-
      timeout 2_500_000 $
        ProductionStore.observeProductionTransitRotationJournalWithinPermit settings permit request
    case result of
      Just (Left BootstrapStoreUnavailable) -> pure ()
      _ -> expectationFailure "timed-out Transit journal read was not reported unavailable"
 where
  open = do
    listener <- Socket.socket AF_INET Stream defaultProtocol
    Socket.setSocketOption listener Socket.ReuseAddr 1
    Socket.bind listener (SockAddrInet 0 literalIpv4Loopback)
    Socket.listen listener 4
    pure listener

-- Real production-store calls against a local in-memory S3 endpoint.
fenceReleasePermitRegression :: Expectation
fenceReleasePermitRegression = withSocketsDo $ bracket open Socket.close $ \listener -> do
  address <- Socket.getSocketName listener
  port <- case address of
    SockAddrInet value _ -> pure value
    _ -> fail "fence release fixture requires IPv4"
  objects <- newIORef Map.empty
  writes <- newIORef (0 :: Int)
  delayPut <- newIORef False
  delayDelete <- newIORef False
  deleteApplied <- newIORef False
  delayFenceRead <- newIORef False
  delayGenerationRead <- newIORef False
  delayJournalRead <- newIORef False
  delayWorkerResultRead <- newIORef False
  bucketMissing <- newIORef False
  requests <- newIORef (0 :: Int)
  let serveOne = bracket (Socket.accept listener) (Socket.close . fst) $ \(connection, _) -> do
        received <- receiveClaimHeaders connection ByteString.empty
        modifyIORef' requests (+ 1)
        let (header, rest) = ByteString.breakSubstring "\r\n\r\n" received
            lowerHeader = ByteString8.map toLower header
            path = case ByteString8.words header of
              _ : value : _ -> value
              _ -> ""
            reply code extra body =
              SocketBytes.sendAll connection $
                ByteString8.pack
                  ( "HTTP/1.1 "
                      ++ code
                      ++ "\r\nContent-Length: "
                      ++ show (ByteString.length body)
                      ++ "\r\nConnection: close\r\n"
                  )
                  <> extra
                  <> "\r\n"
                  <> body
        if "HEAD " `ByteString.isPrefixOf` header
          then do
            missing <- readIORef bucketMissing
            reply (if missing then "404 Not Found" else "200 OK") "" ""
          else
            if "GET " `ByteString.isPrefixOf` header
              then do
                missing <- readIORef bucketMissing
                if missing
                  then reply "404 Not Found" "" ""
                  else
                    if "bootstrap-session-fence" `ByteString.isInfixOf` path
                      || "vault-storage-generation" `ByteString.isInfixOf` path
                      || "prepared-init-envelope" `ByteString.isInfixOf` path
                      || "encrypted-init-response" `ByteString.isInfixOf` path
                      || "secret-worker-checkpoint.result-v1" `ByteString.isInfixOf` path
                      then do
                        delayed <- readIORef delayFenceRead
                        when (delayed && "bootstrap-session-fence" `ByteString.isInfixOf` path) $
                          threadDelay 2_000_000
                        delayedGeneration <- readIORef delayGenerationRead
                        when (delayedGeneration && "vault-storage-generation" `ByteString.isInfixOf` path) $
                          threadDelay 800_000
                        journalDelayed <- readIORef delayJournalRead
                        let isJournalPath =
                              "prepared-init-envelope" `ByteString.isInfixOf` path
                                || "encrypted-init-response" `ByteString.isInfixOf` path
                        when (journalDelayed && isJournalPath) (threadDelay 800_000)
                        resultDelayed <- readIORef delayWorkerResultRead
                        when (resultDelayed && "secret-worker-checkpoint.result-v1" `ByteString.isInfixOf` path) $
                          threadDelay 800_000
                        value <- Map.lookup path <$> readIORef objects
                        let respond = case value of
                              Nothing -> reply "404 Not Found" "" ""
                              Just body -> reply "200 OK" "ETag: \"fixture-etag\"\r\n" body
                        void (try respond :: IO (Either IOException ()))
                      else reply "200 OK" "" "<ListBucketResult/>"
              else
                if "PUT " `ByteString.isPrefixOf` header
                  then do
                    let lengthHeader = find ("content-length:" `ByteString.isPrefixOf`) (ByteString8.lines lowerHeader)
                        bodyLength =
                          lengthHeader
                            >>= (fmap fst . ByteString8.readInt . ByteString8.dropWhile (== ' ') . ByteString8.drop 15)
                    size <- maybe (fail "fence PUT lacks content length") pure bodyLength
                    body <- receiveClaimBody connection size (ByteString.drop 4 rest)
                    existing <- Map.member path <$> readIORef objects
                    if existing && "if-none-match: *" `ByteString.isInfixOf` lowerHeader
                      then reply "412 Precondition Failed" "" ""
                      else do
                        modifyIORef' objects (Map.insert path body)
                        modifyIORef' writes (+ 1)
                        delayed <- readIORef delayPut
                        if delayed
                          then do
                            threadDelay 2_000_000
                            void (try (reply "200 OK" "ETag: \"fixture-etag\"\r\n" "") :: IO (Either IOException ()))
                          else reply "200 OK" "ETag: \"fixture-etag\"\r\n" ""
                  else
                    if "DELETE " `ByteString.isPrefixOf` header
                      then do
                        modifyIORef' objects (Map.delete path)
                        writeIORef deleteApplied True
                        delayed <- readIORef delayDelete
                        when delayed (threadDelay 800_000)
                        void (try (reply "204 No Content" "" "") :: IO (Either IOException ()))
                      else fail "unexpected fence release fixture method"
      rawConfig = settingsConfig port
      rawStore = Settings.bootstrap_store rawConfig
      config =
        rawConfig
          { Settings.bootstrap_store =
              rawStore {Settings.store_endpoint = Text.pack ("http://127.0.0.1:" ++ show port)}
          }
      settings = mustRight (Settings.validateBootstrapBrokerConfig config)
  Async.withAsync (forever serveOne) $ \server -> do
    Async.link server
    wall <- getPOSIXTime
    now <- realMonotonicNow
    let wallMicros = floor (wall * 1_000_000)
        deadline = deadlineAtOffset now (RemainingDuration 20_000_000)
        storage = mustRight (mkVaultStorageGeneration "fixture-vault")
        ownerA = mustRight (mkOwnerNonce "owner-a")
        ownerB = mustRight (mkOwnerNonce "owner-b")
        fenceA =
          mustRight
            ( reloadBootstrapSessionFence
                1
                ownerA
                (digestOf 'a')
                (mustRight (Request.mkRequestDigest (Text.replicate 64 "b")))
                storage
                (wallMicros + 30_000_000)
            )
        requestB =
          mkBootstrapFenceAcquireRequest
            ownerB
            (bootstrapFenceActionDigest fenceA)
            (bootstrapFenceRequestDigest fenceA)
            storage
            (bootstrapFenceOperationDeadline fenceA)
        clock = AuthorityTimeTrusted (authorityTimeFromMicros wallMicros) (clockUncertaintyFromMicros 0)
        planB = case decideBootstrapFenceAcquire now deadline clock requestB (BootstrapFenceStoreVacant 0) of
          BootstrapFenceAcquireCas plan -> plan
          _ -> error "fixture fence B was not admitted"
        fenceB = fenceCasProposedFence planB
        reload generation owner action request generationStorage expiry =
          mustRight (reloadBootstrapSessionFence generation owner action request generationStorage expiry)
        requestDigestB = bootstrapFenceRequestDigest fenceB
        expiryB = wallMicros + 30_000_000
        mismatchedFences =
          [ reload 2 ownerB (digestOf 'a') requestDigestB storage expiryB
          , reload 1 ownerA (digestOf 'a') requestDigestB storage expiryB
          , reload 1 ownerB (digestOf 'c') requestDigestB storage expiryB
          , reload
              1
              ownerB
              (digestOf 'a')
              (mustRight (Request.mkRequestDigest (Text.replicate 64 "d")))
              storage
              expiryB
          , reload
              1
              ownerB
              (digestOf 'a')
              requestDigestB
              (mustRight (mkVaultStorageGeneration "other-vault"))
              expiryB
          , reload 1 ownerB (digestOf 'a') requestDigestB storage (expiryB + 1)
          ]
        permit fence =
          mustRight
            ( authorizeBootstrapStoreMutation
                now
                deadline
                clock
                fence
                (BootstrapFenceStoreHeld fence)
                (BootstrapLeaseObserved (bootstrapLeaseBindingForFence fence) deadline "fixture-rv")
                BootstrapStoreReleaseSessionFence
            )
    writeIORef bucketMissing True
    missingBucket <- ProductionStore.productionExistingBootstrapStoreBoundary settings
    case missingBucket of
      Left BootstrapStoreUnavailable -> pure ()
      _ -> expectationFailure "worker store created or accepted a missing bucket"
    readIORef writes `shouldReturn` 0
    writeIORef bucketMissing False
    missingGeneration <- ProductionStore.productionExistingBootstrapStoreBoundary settings
    case missingGeneration of
      Left BootstrapStoreReadBackMismatch -> pure ()
      _ -> expectationFailure "worker store created or accepted a missing generation"
    readIORef writes `shouldReturn` 0
    let fixtureFencePath = "/physical-engine-state/bootstrap-session-fence"
    modifyIORef' objects (Map.insert fixtureFencePath "opaque-retained-fence")
    opaqueFence <- ProductionStore.productionBootstrapStoreBoundary settings
    case opaqueFence of
      Left BootstrapStoreCorrupt -> pure ()
      _ -> expectationFailure "controller accepted an opaque fence with no generation"
    readIORef writes `shouldReturn` 0
    modifyIORef' objects (Map.delete fixtureFencePath)
    store <- mustRight <$> ProductionStore.productionBootstrapStoreBoundary settings
    generation <- mustRight <$> observeVaultStorageGeneration store
    workerStore <- mustRight <$> ProductionStore.productionExistingBootstrapStoreBoundary settings
    observeVaultStorageGeneration workerStore `shouldReturn` Right generation
    let generationPath = "/physical-engine-state/vault-storage-generation"
    savedGeneration <- Map.lookup generationPath <$> readIORef objects
    generationBytes <- maybe (fail "fixture generation object is missing") pure savedGeneration
    beforeMissing <- readIORef writes
    modifyIORef' objects (Map.delete generationPath)
    observeVaultStorageGeneration store `shouldReturn` Left BootstrapStoreReadBackMismatch
    workerMissing <- ProductionStore.productionExistingBootstrapStoreBoundary settings
    case workerMissing of
      Left BootstrapStoreReadBackMismatch -> pure ()
      _ -> expectationFailure "worker startup recreated a missing generation"
    readIORef writes `shouldReturn` beforeMissing
    modifyIORef' objects (Map.insert generationPath generationBytes)
    observeVaultStorageGeneration store `shouldReturn` Right generation
    generationNow <- realMonotonicNow
    let generationFence =
          mustRight
            ( reloadBootstrapSessionFence
                1
                ownerB
                (digestOf 'a')
                requestDigestB
                (rootInitStorageGeneration generation)
                (wallMicros + 30_000_000)
            )
        generationPermit at limit =
          mustRight
            ( authorizeBootstrapStoreMutation
                at
                limit
                clock
                generationFence
                (BootstrapFenceStoreHeld generationFence)
                (BootstrapLeaseObserved (bootstrapLeaseBindingForFence generationFence) deadline "fixture-rv")
                BootstrapStoreAdvanceVaultStorageGeneration
            )
        replacementGeneration =
          generation {rootInitStorageGeneration = mustRight (mkVaultStorageGeneration "fixture-next-vault")}
    advanceVaultStorageGeneration
      store
      (generationPermit generationNow deadline)
      generation
      replacementGeneration
      `shouldReturn` Right replacementGeneration
    observeVaultStorageGeneration store `shouldReturn` Right replacementGeneration
    modifyIORef' objects (Map.insert generationPath generationBytes)
    permitStart <- realMonotonicNow
    let shortLimit = deadlineAtOffset permitStart (RemainingDuration 200_000)
        journalState = newRootInitState (productionPristineStorageProof generation)
        journalPermit mutation =
          mustRight
            ( authorizeBootstrapStoreMutation
                permitStart
                shortLimit
                clock
                fenceB
                (BootstrapFenceStoreHeld fenceB)
                (BootstrapLeaseObserved (bootstrapLeaseBindingForFence fenceB) deadline "fixture-rv")
                mutation
            )
        -- The production generation is independently random; use its binding
        -- for the payload while the held fixture fence names its generation.
        journalBinding = (rootInitStateBinding journalState) {rootInitStorageGeneration = storage}
        journalValue = newRootInitState (productionPristineStorageProof journalBinding)
        workerRequestForFence fence =
          mkSecretFreeWorkerRequest
            SecretWorkerInitialize
            (mustRight (mkWorkerPodUid "fixture-pod"))
            (mustRight (mkWorkerImageDigest ("sha256:" <> Text.replicate 64 "c")))
            (mustRight (mkWorkerServiceAccount "fixture-worker"))
            (mustRight (mkWorkerSessionId "fixture-session"))
            workerSessionNotIssued
            fence
        workerRequest = workerRequestForFence fenceB
        recoveryFixture = mustRight buildFixture
        originalPrepared = fixturePrepared recoveryFixture
        originalResponse = fixtureEncryptedResponse recoveryFixture
        recoveryPrepared =
          mkPreparedInitEnvelope
            (mkPristineStorageProof journalBinding (preparedInitPristineObservationDigest originalPrepared))
            (preparedInitSchemaVersion originalPrepared)
            (preparedInitSealedRecoveryPrivateKey originalPrepared)
            (preparedInitRecipientCommitment originalPrepared)
            (preparedInitEnvelopeDigest originalPrepared)
        recoveryResponse =
          mustRight
            ( mkEncryptedInitResponseReceipt
                recoveryPrepared
                (encryptedResponseShares originalResponse)
                (encryptedResponseBurnToken originalResponse)
                (encryptedResponseReceiptDigest originalResponse)
            )
        workerResult = encryptedInitializationWorkerResult recoveryResponse
        workerReceipt =
          (workerReceiptFor workerRequest)
            { rawWorkerReceiptDigest =
                mustRight (ProductionStore.productionSecretWorkerReceiptDigest workerRequest workerResult)
            }
        timelyPublishPermit =
          mustRight
            ( authorizeBootstrapStoreMutation
                permitStart
                deadline
                clock
                fenceB
                (BootstrapFenceStoreHeld fenceB)
                (BootstrapLeaseObserved (bootstrapLeaseBindingForFence fenceB) deadline "fixture-rv")
                BootstrapStorePublishSecretWorkerResult
            )
    timelyPublication <-
      ProductionStore.publishProductionSecretWorkerResult
        settings
        timelyPublishPermit
        workerRequest
        workerReceipt
        workerResult
    case timelyPublication of
      Right _ -> pure ()
      Left failure -> expectationFailure ("timely worker publication failed: " ++ show failure)
    let recoveryStore =
          store
            { Store.readEncryptedInitResponse = \_ -> pure (Right StoreObjectAbsent)
            , Store.readSecretWorkerCheckpoint =
                pure
                  ( Right
                      (StoreObjectPresent (StoreVersion 1) (digestOf 'f') (noSecretWorkerReceipt workerRequest))
                  )
            }
        observePublished request = do
          observed <-
            ProductionStore.observeProductionSecretWorkerResultForRecovery
              deadline
              settings
              request
          pure (Just <$> observed)
    recovered <-
      InitRecovery.observeRootInitRecoveryEvidence recoveryStore journalBinding observePublished
    recovered `shouldBe` Right (InitRecovery.RootInitRecoveredWorkerResult workerResult)
    beforeExpiredRecovery <- readIORef requests
    ProductionStore.observeProductionSecretWorkerResultForRecovery
      (deadlineFromInstant permitStart)
      settings
      workerRequest
      `shouldReturn` Left BootstrapStoreUnavailable
    readIORef requests `shouldReturn` beforeExpiredRecovery
    recoveryReadStart <- realMonotonicNow
    let recoveryReadLimit = deadlineAtOffset recoveryReadStart (RemainingDuration 200_000)
    writeIORef delayWorkerResultRead True
    delayedRecovery <-
      timeout 1_000_000 $
        ProductionStore.observeProductionSecretWorkerResultForRecovery
          recoveryReadLimit
          settings
          workerRequest
    delayedRecovery `shouldBe` Just (Left BootstrapStoreUnavailable)
    threadDelay 900_000
    writeIORef delayWorkerResultRead False
    unavailableRecovery <-
      InitRecovery.observeRootInitRecoveryEvidence recoveryStore journalBinding $ \_ ->
        pure (Left BootstrapStoreUnavailable)
    unavailableRecovery `shouldBe` Left BootstrapStoreUnavailable
    let foreignOperationRequest =
          mkSecretFreeWorkerRequest
            SecretWorkerUnseal
            (mustRight (mkWorkerPodUid "foreign-pod"))
            (mustRight (mkWorkerImageDigest ("sha256:" <> Text.replicate 64 "c")))
            (mustRight (mkWorkerServiceAccount "fixture-worker"))
            (mustRight (mkWorkerSessionId "foreign-session"))
            workerSessionNotIssued
            fenceB
        foreignStore =
          recoveryStore
            { Store.readSecretWorkerCheckpoint =
                pure
                  ( Right
                      (StoreObjectPresent (StoreVersion 1) (digestOf 'f') (noSecretWorkerReceipt foreignOperationRequest))
                  )
            }
    foreignRecovery <-
      InitRecovery.observeRootInitRecoveryEvidence foreignStore journalBinding $ \_ ->
        fail "foreign operation must not trigger result observation"
    foreignRecovery `shouldBe` Left BootstrapStoreBindingMismatch
    wrongResult <-
      InitRecovery.observeRootInitRecoveryEvidence recoveryStore journalBinding $ \_ ->
        pure (Right (Just (finalizedInitializationWorkerResult (fixtureFinalBundle recoveryFixture))))
    wrongResult `shouldBe` Left BootstrapStoreBindingMismatch
    modifyIORef' objects (Map.delete "/physical-engine-state/secret-worker-checkpoint.result-v1")
    staleAbsence <-
      InitRecovery.observeRootInitRecoveryEvidence recoveryStore journalBinding $ \request -> do
        observed <- observePublished request
        published <-
          ProductionStore.publishProductionSecretWorkerResult
            settings
            timelyPublishPermit
            workerRequest
            workerReceipt
            workerResult
        case published of
          Right _ -> pure ()
          Left failure -> expectationFailure ("late fixture publication failed: " ++ show failure)
        pure observed
    staleAbsence `shouldBe` Left BootstrapStoreUnavailable
    retried <-
      InitRecovery.observeRootInitRecoveryEvidence recoveryStore journalBinding observePublished
    retried `shouldBe` Right (InitRecovery.RootInitRecoveredWorkerResult workerResult)
    beforeIdenticalRetry <- readIORef writes
    identicalRetry <-
      ProductionStore.publishProductionSecretWorkerResult
        settings
        timelyPublishPermit
        workerRequest
        workerReceipt
        workerResult
    identicalRetry `shouldBe` timelyPublication
    readIORef writes `shouldReturn` beforeIdenticalRetry
    beforeForeignRequests <- readIORef requests
    beforeForeignWrites <- readIORef writes
    forM_ mismatchedFences $ \foreignFence -> do
      let foreignRequest = workerRequestForFence foreignFence
          foreignReceipt =
            (workerReceiptFor foreignRequest)
              { rawWorkerReceiptDigest =
                  mustRight (ProductionStore.productionSecretWorkerReceiptDigest foreignRequest workerResult)
              }
      ProductionStore.publishProductionSecretWorkerResult
        settings
        timelyPublishPermit
        foreignRequest
        foreignReceipt
        workerResult
        `shouldReturn` Left BootstrapStoreBindingMismatch
    readIORef requests `shouldReturn` beforeForeignRequests
    readIORef writes `shouldReturn` beforeForeignWrites
    beforeMissingBucketWrite <- readIORef writes
    writeIORef bucketMissing True
    ProductionStore.publishProductionSecretWorkerResult
      settings
      timelyPublishPermit
      workerRequest
      workerReceipt
      workerResult
      `shouldReturn` Left BootstrapStoreUnavailable
    readIORef writes `shouldReturn` beforeMissingBucketWrite
    writeIORef bucketMissing False
    let replacementResult = classifiedAmbiguousInitializationWorkerResult InitializationObservedBeforeCall
        replacementReceipt =
          workerReceipt
            { rawWorkerReceiptDigest =
                mustRight (ProductionStore.productionSecretWorkerReceiptDigest workerRequest replacementResult)
            }
    beforeContradictoryWrite <- readIORef writes
    ProductionStore.publishProductionSecretWorkerResult
      settings
      timelyPublishPermit
      workerRequest
      replacementReceipt
      replacementResult
      `shouldReturn` Left BootstrapStoreVersionConflict
    readIORef writes `shouldReturn` beforeContradictoryWrite
    preserved <- ProductionStore.observeProductionSecretWorkerResult settings workerRequest
    case preserved of
      Right (Just recorded) ->
        ProductionStore.productionSecretWorkerResultValue recorded `shouldBe` workerResult
      _ -> expectationFailure "contradictory worker result displaced the original"
    let newerFence = reload 2 ownerB (digestOf 'a') requestDigestB storage expiryB
        newerRequest = workerRequestForFence newerFence
        newerReceipt =
          (workerReceiptFor newerRequest)
            { rawWorkerReceiptDigest =
                mustRight (ProductionStore.productionSecretWorkerReceiptDigest newerRequest workerResult)
            }
        newerPermit =
          mustRight
            ( authorizeBootstrapStoreMutation
                permitStart
                deadline
                clock
                newerFence
                (BootstrapFenceStoreHeld newerFence)
                (BootstrapLeaseObserved (bootstrapLeaseBindingForFence newerFence) deadline "fixture-rv")
                BootstrapStorePublishSecretWorkerResult
            )
    newerPublication <-
      ProductionStore.publishProductionSecretWorkerResult
        settings
        newerPermit
        newerRequest
        newerReceipt
        workerResult
    case newerPublication of
      Right _ -> pure ()
      Left failure -> expectationFailure ("newer worker publication failed: " ++ show failure)
    beforeStaleWrite <- readIORef writes
    ProductionStore.publishProductionSecretWorkerResult
      settings
      timelyPublishPermit
      workerRequest
      workerReceipt
      workerResult
      `shouldReturn` Left BootstrapStoreVersionConflict
    readIORef writes `shouldReturn` beforeStaleWrite
    retainedNewer <- ProductionStore.observeProductionSecretWorkerResult settings newerRequest
    case retainedNewer of
      Right (Just recorded) ->
        ProductionStore.productionSecretWorkerResultValue recorded `shouldBe` workerResult
      _ -> expectationFailure "stale worker displaced the newer result"
    createPermit <- evaluate (journalPermit BootstrapStoreCreateRootInitJournal)
    casPermit <- evaluate (journalPermit BootstrapStoreCasRootInitJournal)
    deletePermit <- evaluate (journalPermit BootstrapStoreDeletePreparedInitEnvelope)
    promotionPermit <- evaluate (journalPermit BootstrapStorePromoteFinalUnlockBundle)
    publishPermit <- evaluate (journalPermit BootstrapStorePublishSecretWorkerResult)
    expiredGenerationPermit <- evaluate (generationPermit permitStart shortLimit)
    threadDelay 300_000
    beforeExpiredJournal <- readIORef writes
    beforeExpiredRequests <- readIORef requests
    advanceVaultStorageGeneration store expiredGenerationPermit generation replacementGeneration
      `shouldReturn` Left BootstrapStoreUnavailable
    ProductionStore.publishProductionSecretWorkerResult
      settings
      publishPermit
      workerRequest
      workerReceipt
      workerResult
      `shouldReturn` Left BootstrapStoreUnavailable
    createRootInitJournal store createPermit journalValue `shouldReturn` Left BootstrapStoreUnavailable
    casRootInitJournal store casPermit (StoreVersion 1) journalValue
      `shouldReturn` Left BootstrapStoreUnavailable
    deletePreparedInitEnvelope store deletePermit journalBinding (StoreVersion 1)
      `shouldReturn` Left BootstrapStoreUnavailable
    let promotionFixture = mustRight buildFixture
    promoteFinalUnlockBundle
      store
      promotionPermit
      (fixtureEncryptedResponse promotionFixture)
      (fixtureFinalBundle promotionFixture)
      `shouldReturn` Left BootstrapStoreUnavailable
    readIORef writes `shouldReturn` beforeExpiredJournal
    readIORef requests `shouldReturn` beforeExpiredRequests
    generationReadStart <- realMonotonicNow
    let generationReadLimit = deadlineAtOffset generationReadStart (RemainingDuration 300_000)
    writeIORef delayGenerationRead True
    generationReadResult <-
      timeout 1_000_000 $
        advanceVaultStorageGeneration
          store
          (generationPermit generationReadStart generationReadLimit)
          generation
          replacementGeneration
    generationReadResult `shouldBe` Just (Left BootstrapStoreUnavailable)
    threadDelay 900_000
    writeIORef delayGenerationRead False
    readIORef writes `shouldReturn` beforeExpiredJournal
    delayedStart <- realMonotonicNow
    let delayedLimit = deadlineAtOffset delayedStart (RemainingDuration 300_000)
        delayedPermit mutation =
          mustRight
            ( authorizeBootstrapStoreMutation
                delayedStart
                delayedLimit
                clock
                fenceB
                (BootstrapFenceStoreHeld fenceB)
                (BootstrapLeaseObserved (bootstrapLeaseBindingForFence fenceB) deadline "fixture-rv")
                mutation
            )
    delayedDeletePermit <- evaluate (delayedPermit BootstrapStoreDeletePreparedInitEnvelope)
    writeIORef delayJournalRead True
    delayedDelete <-
      timeout
        1_000_000
        (deletePreparedInitEnvelope store delayedDeletePermit journalBinding (StoreVersion 1))
    delayedDelete `shouldBe` Just (Left BootstrapStoreUnavailable)
    threadDelay 900_000
    delayedPromotionStart <- realMonotonicNow
    let delayedPromotionLimit = deadlineAtOffset delayedPromotionStart (RemainingDuration 300_000)
        delayedPromotionPermit =
          mustRight
            ( authorizeBootstrapStoreMutation
                delayedPromotionStart
                delayedPromotionLimit
                clock
                fenceB
                (BootstrapFenceStoreHeld fenceB)
                (BootstrapLeaseObserved (bootstrapLeaseBindingForFence fenceB) deadline "fixture-rv")
                BootstrapStorePromoteFinalUnlockBundle
            )
    delayedPromotion <-
      timeout 1_000_000 $
        promoteFinalUnlockBundle
          store
          delayedPromotionPermit
          (fixtureEncryptedResponse promotionFixture)
          (fixtureFinalBundle promotionFixture)
    delayedPromotion `shouldBe` Just (Left BootstrapStoreUnavailable)
    threadDelay 900_000
    writeIORef delayJournalRead False
    readIORef writes `shouldReturn` beforeExpiredJournal
    let prepared = fixturePrepared promotionFixture
        preparedBinding = preparedInitBinding prepared
        preparedFence =
          mustRight
            ( reloadBootstrapSessionFence
                1
                ownerB
                (digestOf 'a')
                (mustRight (Request.mkRequestDigest (Text.replicate 64 "b")))
                (rootInitStorageGeneration preparedBinding)
                (wallMicros + 30_000_000)
            )
        preparePermit at limit mutation =
          mustRight
            ( authorizeBootstrapStoreMutation
                at
                limit
                clock
                preparedFence
                (BootstrapFenceStoreHeld preparedFence)
                (BootstrapLeaseObserved (bootstrapLeaseBindingForFence preparedFence) deadline "fixture-rv")
                mutation
            )
    prepareNow <- realMonotonicNow
    createdPrepared <-
      createPreparedInitEnvelope
        store
        (preparePermit prepareNow deadline BootstrapStoreCreatePreparedInitEnvelope)
        prepared
    preparedVersion <- case createdPrepared of
      Right (StoreWriteApplied version _ _) -> pure version
      _ -> fail "fixture prepared envelope was not created"
    deleteNow <- realMonotonicNow
    let deleteLimit = deadlineAtOffset deleteNow (RemainingDuration 300_000)
    writeIORef delayDelete True
    deleteResult <-
      timeout 1_000_000 $
        deletePreparedInitEnvelope
          store
          (preparePermit deleteNow deleteLimit BootstrapStoreDeletePreparedInitEnvelope)
          preparedBinding
          preparedVersion
    deleteResult `shouldBe` Just (Left BootstrapStoreUnavailable)
    readIORef deleteApplied `shouldReturn` True
    threadDelay 900_000
    writeIORef delayDelete False
    readPreparedInitEnvelope store preparedBinding `shouldReturn` Right StoreObjectAbsent
    readNow <- realMonotonicNow
    let readDeadline = deadlineAtOffset readNow (RemainingDuration 700_000)
        delayedReadPlan = case decideBootstrapFenceAcquire readNow readDeadline clock requestB (BootstrapFenceStoreVacant 0) of
          BootstrapFenceAcquireCas plan -> plan
          _ -> error "fixture delayed-read fence was not admitted"
    beforeRead <- readIORef writes
    writeIORef delayFenceRead True
    delayedRead <- timeout 1_500_000 (casBootstrapSessionFence store delayedReadPlan)
    case delayedRead of
      Just (Right (BootstrapFenceCasUnobservable _)) -> pure ()
      _ -> expectationFailure "delayed fence read did not return an unobservable CAS"
    readIORef writes `shouldReturn` beforeRead
    threadDelay 1_500_000
    writeIORef delayFenceRead False
    casResult <- casBootstrapSessionFence store planB
    casResult `shouldBe` Right (BootstrapFenceCasAppliedReadBack fenceB)
    beforeRestart <- readIORef writes
    modifyIORef' objects (Map.delete generationPath)
    retainedFence <- ProductionStore.productionBootstrapStoreBoundary settings
    case retainedFence of
      Left BootstrapStoreBindingMismatch -> pure ()
      _ -> expectationFailure "controller recreated a generation beside a retained fence"
    readIORef writes `shouldReturn` beforeRestart
    modifyIORef' objects (Map.insert generationPath generationBytes)
    before <- readIORef writes
    releaseBootstrapSessionFence store (permit fenceA) fenceB
      `shouldReturn` Left BootstrapStoreBindingMismatch
    forM_ mismatchedFences $ \otherFence ->
      releaseBootstrapSessionFence store (permit fenceB) otherFence
        `shouldReturn` Left BootstrapStoreBindingMismatch
    let earlier = monotonicInstantFromMicros (monotonicInstantMicros now - 1)
        expiredDeadline = deadlineFromInstant now
        expiredPermit =
          mustRight
            ( authorizeBootstrapStoreMutation
                earlier
                expiredDeadline
                clock
                fenceB
                (BootstrapFenceStoreHeld fenceB)
                (BootstrapLeaseObserved (bootstrapLeaseBindingForFence fenceB) expiredDeadline "fixture-rv")
                BootstrapStoreReleaseSessionFence
            )
    releaseBootstrapSessionFence store expiredPermit fenceB
      `shouldReturn` Left BootstrapStoreUnavailable
    readIORef writes `shouldReturn` before
    observeBootstrapSessionFence store `shouldReturn` Right (BootstrapFenceStoreHeld fenceB)
    releaseBootstrapSessionFence store (permit fenceB) fenceB
      `shouldReturn` Right (BootstrapFenceStoreVacant 1)
    later <- realMonotonicNow
    let nextDeadline = deadlineAtOffset later (RemainingDuration 700_000)
        planB2 = case decideBootstrapFenceAcquire later nextDeadline clock requestB (BootstrapFenceStoreVacant 1) of
          BootstrapFenceAcquireCas plan -> plan
          _ -> error "fixture fence B successor was not admitted"
        fenceB2 = fenceCasProposedFence planB2
    writeIORef delayPut True
    delayedCas <- timeout 1_500_000 (casBootstrapSessionFence store planB2)
    case delayedCas of
      Just (Right (BootstrapFenceCasUnobservable _)) -> pure ()
      _ -> expectationFailure "applied fence CAS did not remain unobservable"
    threadDelay 1_500_000
    writeIORef delayPut False
    observeBootstrapSessionFence store `shouldReturn` Right (BootstrapFenceStoreHeld fenceB2)
    permitNow <- realMonotonicNow
    let shortDeadline = deadlineAtOffset permitNow (RemainingDuration 1_000_000)
        shortPermit =
          mustRight
            ( authorizeBootstrapStoreMutation
                permitNow
                shortDeadline
                clock
                fenceB2
                (BootstrapFenceStoreHeld fenceB2)
                (BootstrapLeaseObserved (bootstrapLeaseBindingForFence fenceB2) shortDeadline "fixture-rv")
                BootstrapStoreReleaseSessionFence
            )
    writeIORef delayPut True
    timeout 2_500_000 (releaseBootstrapSessionFence store shortPermit fenceB2)
      `shouldReturn` Just (Left BootstrapStoreUnavailable)
    threadDelay 1_300_000
    observeBootstrapSessionFence store `shouldReturn` Right (BootstrapFenceStoreVacant 2)
    writeIORef delayPut False
    retiringWall <- getPOSIXTime
    retiringNow <- realMonotonicNow
    let retiringMicros = floor (retiringWall * 1_000_000)
        retiringClock = AuthorityTimeTrusted (authorityTimeFromMicros retiringMicros) (clockUncertaintyFromMicros 0)
        retiringRequest =
          mkBootstrapFenceAcquireRequest
            ownerB
            (digestOf 'a')
            requestDigestB
            storage
            (operationDeadlineFromMicros (retiringMicros + 3_000_000))
        retiringAcquire = case decideBootstrapFenceAcquire
          retiringNow
          (deadlineAtOffset retiringNow (RemainingDuration 5_000_000))
          retiringClock
          retiringRequest
          (BootstrapFenceStoreVacant 2) of
          BootstrapFenceAcquireCas plan -> plan
          _ -> error "fixture retiring fence was not admitted"
        retiringFence = fenceCasProposedFence retiringAcquire
    casBootstrapSessionFence store retiringAcquire
      `shouldReturn` Right (BootstrapFenceCasAppliedReadBack retiringFence)
    threadDelay 3_200_000
    retiredWall <- getPOSIXTime
    retiredNow <- realMonotonicNow
    let retiredClock =
          AuthorityTimeTrusted
            (authorityTimeFromMicros (floor (retiredWall * 1_000_000)))
            (clockUncertaintyFromMicros 0)
        retireDeadline = deadlineAtOffset retiredNow (RemainingDuration 700_000)
        retirePlan =
          mustRight
            ( decideBootstrapFenceRetire
                retiredNow
                retireDeadline
                retiredClock
                retiringFence
                BootstrapLeaseMissing
                (BootstrapFenceOwnerAbsent retiringFence (digestOf 'e'))
            )
    writeIORef delayPut True
    delayedRetire <- timeout 1_500_000 (casRetireBootstrapSessionFence store retirePlan)
    case delayedRetire of
      Just (Right (BootstrapFenceRetireCasUnobservable _)) -> pure ()
      _ -> expectationFailure "applied fence retirement did not remain unobservable"
    threadDelay 1_500_000
    observeBootstrapSessionFence store `shouldReturn` Right (BootstrapFenceStoreVacant 3)
 where
  open = do
    listener <- Socket.socket AF_INET Stream defaultProtocol
    Socket.setSocketOption listener Socket.ReuseAddr 1
    Socket.bind listener (SockAddrInet 0 literalIpv4Loopback)
    Socket.listen listener 4
    pure listener

-- Two readers are held until both have observed absence, so the loser must
-- encounter the real conditional-write conflict rather than an earlier read.
transitClaimRaceRegression :: Expectation
transitClaimRaceRegression = withSocketsDo $ bracket open Socket.close $ \listener -> do
  address <- Socket.getSocketName listener
  port <- case address of
    SockAddrInet value _ -> pure value
    _ -> fail "Transit claim fixture requires IPv4"
  stored <- newMVar Nothing
  initialReads <- newIORef (0 :: Int)
  bothRead <- newEmptyMVar
  writes <- newIORef (0 :: Int)
  conflicts <- newIORef (0 :: Int)
  vaultVersion <- newIORef (7 :: Int)
  vaultPosts <- newIORef (0 :: Int)
  let serveConnection connection = do
        request <- receiveClaimHeaders connection ByteString.empty
        let (header, rest) = ByteString.breakSubstring "\r\n\r\n" request
            lowerHeader = ByteString8.map toLower header
            reply code extra body =
              SocketBytes.sendAll connection $
                ByteString8.pack
                  ( "HTTP/1.1 "
                      ++ code
                      ++ "\r\nContent-Length: "
                      ++ show (ByteString.length body)
                      ++ "\r\nConnection: close\r\n"
                  )
                  <> extra
                  <> "\r\n"
                  <> body
        if "POST /v1/transit/keys/prodbox-active-config/rotate " `ByteString.isPrefixOf` header
          then do
            modifyIORef' vaultPosts (+ 1)
            modifyIORef' vaultVersion (+ 1)
            reply "204 No Content" "" ""
          else
            if "GET /v1/transit/keys/prodbox-active-config " `ByteString.isPrefixOf` header
              then do
                version <- readIORef vaultVersion
                reply
                  "200 OK"
                  ""
                  ( ByteString8.pack
                      ("{\"data\":{\"type\":\"aes256-gcm96\",\"latest_version\":" ++ show version ++ "}}")
                  )
              else
                if "HEAD " `ByteString.isPrefixOf` header
                  then reply "200 OK" "" ""
                  else
                    if "GET " `ByteString.isPrefixOf` header
                      then
                        if ".transit-rotation-v1" `ByteString.isInfixOf` header
                          then do
                            value <- readMVar stored
                            first <- atomicModifyIORef' initialReads $ \n -> (n + 1, n < 2)
                            when first $ do
                              count <- readIORef initialReads
                              when (count >= 2) (void (tryPutMVar bothRead ()))
                              released <- timeout 3_000_000 (readMVar bothRead)
                              when (released == Nothing) (fail "Transit claim readers did not meet")
                            case value of
                              Nothing -> reply "404 Not Found" "" ""
                              Just body -> reply "200 OK" "ETag: \"fixture-etag\"\r\n" body
                          else reply "200 OK" "" "<ListBucketResult/>"
                      else
                        if "PUT " `ByteString.isPrefixOf` header
                          then do
                            let lengthHeader = find ("content-length:" `ByteString.isPrefixOf`) (ByteString8.lines lowerHeader)
                                bodyLength =
                                  lengthHeader
                                    >>= (fmap fst . ByteString8.readInt . ByteString8.dropWhile (== ' ') . ByteString8.drop 15)
                            size <- maybe (fail "Transit claim PUT lacks content length") pure bodyLength
                            body <- receiveClaimBody connection size (ByteString.drop 4 rest)
                            applied <- modifyMVar stored $ \existing ->
                              if (existing == Nothing && "if-none-match: *" `ByteString.isInfixOf` lowerHeader)
                                || (existing /= Nothing && "if-match: \"fixture-etag\"" `ByteString.isInfixOf` lowerHeader)
                                then pure (Just body, True)
                                else pure (existing, False)
                            if applied
                              then do
                                modifyIORef' writes (+ 1)
                                reply "200 OK" "ETag: \"fixture-etag\"\r\n" ""
                              else do
                                modifyIORef' conflicts (+ 1)
                                reply "412 Precondition Failed" "" ""
                          else fail "unexpected Transit claim fixture method"
      serve = forever $ do
        (connection, _) <- Socket.accept listener
        void (forkIO (bracket (pure connection) Socket.close serveConnection))
      rawConfig = settingsConfig port
      rawStore = Settings.bootstrap_store rawConfig
      config =
        rawConfig
          { Settings.vault_address = Text.pack ("http://127.0.0.1:" ++ show port)
          , Settings.bootstrap_store =
              rawStore {Settings.store_endpoint = Text.pack ("http://127.0.0.1:" ++ show port)}
          }
      settings = mustRight (Settings.validateBootstrapBrokerConfig config)
  Async.withAsync serve $ \server -> do
    Async.link server
    wall <- getPOSIXTime
    now <- realMonotonicNow
    let fence =
          mustRight $
            reloadBootstrapSessionFence
              1
              (mustRight (mkOwnerNonce "fixture-owner"))
              (digestOf 'a')
              (mustRight (Request.mkRequestDigest (Text.replicate 64 "b")))
              (mustRight (mkVaultStorageGeneration "fixture-vault"))
              (floor (wall * 1_000_000) + 30_000_000)
        request =
          mkSecretFreeWorkerRequest
            SecretWorkerRotateTransitKey
            (mustRight (mkWorkerPodUid "fixture-pod"))
            (mustRight (mkWorkerImageDigest ("sha256:" <> Text.replicate 64 "c")))
            (mustRight (mkWorkerServiceAccount "fixture-worker"))
            (mustRight (mkWorkerSessionId "fixture-session"))
            workerSessionNotIssued
            fence
        deadline = deadlineAtOffset now (RemainingDuration 10_000_000)
        clock =
          AuthorityTimeTrusted
            (authorityTimeFromMicros (floor (wall * 1_000_000)))
            (clockUncertaintyFromMicros 0)
        lease = BootstrapLeaseObserved (bootstrapLeaseBindingForFence fence) deadline "fixture-rv"
        permit =
          mustRight
            ( authorizeBootstrapStoreMutation
                now
                deadline
                clock
                fence
                (BootstrapFenceStoreHeld fence)
                lease
                BootstrapStorePlanTransitRotation
            )
        claim = ProductionStore.planProductionTransitRotation settings permit request "prodbox-active-config" 7
        completionPermit =
          mustRight
            ( authorizeBootstrapStoreMutation
                now
                deadline
                clock
                fence
                (BootstrapFenceStoreHeld fence)
                lease
                BootstrapStoreCompleteTransitRotation
            )
        effectPermit effect =
          mustRight
            ( authorizeBootstrapVaultEffect
                now
                deadline
                clock
                fence
                (BootstrapFenceStoreHeld fence)
                lease
                effect
            )
        token = Vault.VaultToken "fixture-token"
    invalidClaim <- ProductionStore.planProductionTransitRotation settings permit request "" 7
    case invalidClaim of
      Left BootstrapStoreBindingMismatch -> pure ()
      _ -> expectationFailure "empty Transit claim was admitted"
    foreignKey <-
      ProductionStore.planProductionTransitRotation settings permit request "unregistered-key" 7
    case foreignKey of
      Left BootstrapStoreBindingMismatch -> pure ()
      _ -> expectationFailure "unregistered Transit key was admitted"
    readIORef initialReads `shouldReturn` 0
    result <- timeout 10_000_000 (Async.concurrently claim claim)
    fresh <- case result of
      Just (Right winner, Left BootstrapStoreVersionConflict) -> pure winner
      Just (Left BootstrapStoreVersionConflict, Right winner) -> pure winner
      _ -> fail "Transit claim race did not yield one fresh claimant"
    readIORef writes `shouldReturn` 1
    readIORef conflicts `shouldReturn` 1
    again <- claim
    case again of
      Left BootstrapStoreVersionConflict -> pure ()
      _ -> expectationFailure "an observed claim granted fresh authority"
    wrongEffect <-
      ProductionStore.dispatchProductionTransitRotation (effectPermit BootstrapVaultSeal) fresh token
    case wrongEffect of
      Left BootstrapStoreBindingMismatch -> pure ()
      _ -> expectationFailure "wrong Vault effect was admitted"
    readIORef vaultPosts `shouldReturn` 0
    dispatched <-
      Async.concurrently
        ( ProductionStore.dispatchProductionTransitRotation
            (effectPermit BootstrapVaultRotateTransitKey)
            fresh
            token
        )
        ( ProductionStore.dispatchProductionTransitRotation
            (effectPermit BootstrapVaultRotateTransitKey)
            fresh
            token
        )
    successful <- case dispatched of
      (Right winner, Left BootstrapStoreVersionConflict) -> pure winner
      (Left BootstrapStoreVersionConflict, Right winner) -> pure winner
      _ -> fail "copied claim did not yield exactly one Vault dispatch"
    readIORef vaultPosts `shouldReturn` 1
    writeIORef vaultVersion 10
    invalidConfirmation <-
      ProductionStore.confirmProductionTransitRotation
        (effectPermit BootstrapVaultRotateTransitKey)
        successful
        token
    case invalidConfirmation of
      Left BootstrapStoreReadBackMismatch -> pure ()
      _ -> expectationFailure "incorrect Vault version created a completion witness"
    readIORef writes `shouldReturn` 1
    preserved <- ProductionStore.observeProductionTransitRotationJournal settings
    case preserved of
      Right (StoreObjectPresent _ _ ProductionStore.ProductionTransitRotationClaimed {}) -> pure ()
      other -> expectationFailure ("invalid completion damaged claim: " ++ show other)
    writeIORef vaultVersion 8
    confirmed <-
      ProductionStore.confirmProductionTransitRotation
        (effectPermit BootstrapVaultRotateTransitKey)
        successful
        token
    witness <- case confirmed of
      Right value -> pure value
      Left failure -> fail (show failure)
    completed <- ProductionStore.completeProductionTransitRotation completionPermit witness
    case completed of
      Right ProductionStore.ProductionTransitRotationCompleted {} -> pure ()
      other -> expectationFailure ("valid completion did not succeed: " ++ show other)
    readIORef writes `shouldReturn` 2
    now2 <- realMonotonicNow
    let fence2 =
          mustRight $
            reloadBootstrapSessionFence
              2
              (mustRight (mkOwnerNonce "fixture-owner-2"))
              (digestOf 'a')
              (mustRight (Request.mkRequestDigest (Text.replicate 64 "d")))
              (mustRight (mkVaultStorageGeneration "fixture-vault"))
              (floor (wall * 1_000_000) + 30_000_000)
        request2 =
          mkSecretFreeWorkerRequest
            SecretWorkerRotateTransitKey
            (mustRight (mkWorkerPodUid "fixture-pod-2"))
            (mustRight (mkWorkerImageDigest ("sha256:" <> Text.replicate 64 "c")))
            (mustRight (mkWorkerServiceAccount "fixture-worker"))
            (mustRight (mkWorkerSessionId "fixture-session-2"))
            workerSessionNotIssued
            fence2
        deadline2 = deadlineAtOffset now2 (RemainingDuration 5_000_000)
        shortDeadline = deadlineAtOffset now2 (RemainingDuration 100_000)
        lease2 = BootstrapLeaseObserved (bootstrapLeaseBindingForFence fence2) deadline2 "fixture-rv-2"
        planPermit2 =
          mustRight
            ( authorizeBootstrapStoreMutation
                now2
                deadline2
                clock
                fence2
                (BootstrapFenceStoreHeld fence2)
                lease2
                BootstrapStorePlanTransitRotation
            )
        completionPermit2 =
          mustRight
            ( authorizeBootstrapStoreMutation
                now2
                deadline2
                clock
                fence2
                (BootstrapFenceStoreHeld fence2)
                lease2
                BootstrapStoreCompleteTransitRotation
            )
        effectPermit2 limit =
          mustRight
            ( authorizeBootstrapVaultEffect
                now2
                limit
                clock
                fence2
                (BootstrapFenceStoreHeld fence2)
                lease2
                BootstrapVaultRotateTransitKey
            )
    wrongFenceDispatch <-
      ProductionStore.dispatchProductionTransitRotation (effectPermit2 deadline2) fresh token
    case wrongFenceDispatch of
      Left BootstrapStoreBindingMismatch -> pure ()
      _ -> expectationFailure "a different fence authorized the claim"
    wrongFenceCompletion <- ProductionStore.completeProductionTransitRotation completionPermit2 witness
    wrongFenceCompletion `shouldBe` Left BootstrapStoreBindingMismatch
    secondClaim <-
      ProductionStore.planProductionTransitRotation
        settings
        planPermit2
        request2
        "prodbox-active-config"
        8
    fresh2 <- case secondClaim of
      Right value -> pure value
      Left failure -> fail (show failure)
    threadDelay 200_000
    expired <-
      ProductionStore.dispatchProductionTransitRotation (effectPermit2 shortDeadline) fresh2 token
    case expired of
      Left BootstrapStoreUnavailable -> pure ()
      _ -> expectationFailure "expired permit dispatched or produced a witness"
    retry <- ProductionStore.dispatchProductionTransitRotation (effectPermit2 deadline2) fresh2 token
    case retry of
      Left BootstrapStoreVersionConflict -> pure ()
      _ -> expectationFailure "an expired attempt reused its consumed claim"
    readIORef vaultPosts `shouldReturn` 1
 where
  open = do
    listener <- Socket.socket AF_INET Stream defaultProtocol
    Socket.setSocketOption listener Socket.ReuseAddr 1
    Socket.bind listener (SockAddrInet 0 literalIpv4Loopback)
    Socket.listen listener 8
    pure listener

receiveClaimHeaders :: Socket.Socket -> ByteString -> IO ByteString
receiveClaimHeaders connection bytes
  | "\r\n\r\n" `ByteString.isInfixOf` bytes = pure bytes
  | otherwise = do
      chunk <- SocketBytes.recv connection 4096
      if ByteString.null chunk
        then fail "Transit claim fixture ended before headers"
        else receiveClaimHeaders connection (bytes <> chunk)

receiveClaimBody :: Socket.Socket -> Int -> ByteString -> IO ByteString
receiveClaimBody connection size bytes
  | ByteString.length bytes >= size = pure (ByteString.take size bytes)
  | otherwise = do
      chunk <- SocketBytes.recv connection 4096
      if ByteString.null chunk
        then fail "Transit claim fixture ended before body"
        else receiveClaimBody connection size (bytes <> chunk)

requireSettings :: PortNumber -> Settings.BootstrapBrokerSettings
requireSettings port = mustRight (settingsForPort port)

isRouteSuccess
  :: BrokerRoute -> Either BrokerEngineError SomeBrokerResponse -> Bool
isRouteSuccess expected outcome = case outcome of
  Right _ -> expected `elem` allBrokerRoutes
  Left _ -> False

shouldBeRouteSuccess
  :: Either BrokerEngineError SomeBrokerResponse -> BrokerRoute -> Expectation
shouldBeRouteSuccess outcome expected = case outcome of
  Right _ -> expected `shouldSatisfy` (`elem` allBrokerRoutes)
  Left failure ->
    expectationFailure
      ( "expected successful "
          ++ show expected
          ++ ", but engine returned "
          ++ show failure
      )

isStoreUnavailable
  :: Either BrokerEngineError SomeBrokerResponse -> Bool
isStoreUnavailable outcome = case outcome of
  Left (EngineStoreRefused BootstrapStoreUnavailable) -> True
  _ -> False

isStoreReadBackMismatch
  :: Either BrokerEngineError SomeBrokerResponse -> Bool
isStoreReadBackMismatch outcome = case outcome of
  Left EngineStoreReadBackMismatch -> True
  _ -> False

isPostUnsealConsumerCall :: PhysicalEvent -> Bool
isPostUnsealConsumerCall event = case event of
  PhysicalObserved "post-unseal-consumer" -> True
  _ -> False

isPhysicalUnavailable
  :: Either BrokerEngineError SomeBrokerResponse -> Bool
isPhysicalUnavailable outcome = case outcome of
  Left (EnginePhysicalCallRefused (EngineBoundaryUnavailable _)) -> True
  Left (EngineBaselinePhysicalCallRefused _ (EngineBoundaryUnavailable _)) -> True
  _ -> False

isBaselinePhysicalStage
  :: BaselinePhysicalStage
  -> Either BrokerEngineError SomeBrokerResponse
  -> Bool
isBaselinePhysicalStage expected outcome = case outcome of
  Left (EngineBaselinePhysicalCallRefused observed _) -> observed == expected
  _ -> False

provisionerLoginAttemptIsJournaled :: RootSessionState -> Bool
provisionerLoginAttemptIsJournaled state =
  case rootSessionStateProvisioner state of
    Just provisioner -> case provisionerSessionPhase provisioner of
      ProvisionerLoginPending _ -> True
      _ -> False
    Nothing -> False

provisionerSessionIsDurablyClosed :: RootSessionState -> Bool
provisionerSessionIsDurablyClosed state =
  case rootSessionStateProvisioner state of
    Just provisioner -> provisionerSessionIsReady provisioner
    Nothing -> False

isInitializationAmbiguous
  :: Either BrokerEngineError SomeBrokerResponse -> Bool
isInitializationAmbiguous outcome = case outcome of
  Left (EngineInitializationAmbiguous _ _) -> True
  _ -> False

isFenceUseRefused
  :: Either BrokerEngineError SomeBrokerResponse -> Bool
isFenceUseRefused outcome = case outcome of
  Left (EngineFenceUseRefused _) -> True
  _ -> False

isResetOutsideAmbiguity
  :: Either BrokerEngineError SomeBrokerResponse -> Bool
isResetOutsideAmbiguity outcome = case outcome of
  Left (EngineCustodyTransitionRefused detail) ->
    detail == "reset requested outside ambiguous initialization"
  _ -> False

isResetEvidenceMismatch
  :: Either BrokerEngineError SomeBrokerResponse -> Bool
isResetEvidenceMismatch outcome = case outcome of
  Left (EngineResponseEvidenceMismatch route) ->
    route == BrokerVaultResetAmbiguousInitialization
  _ -> False

storedValue :: Maybe (Versioned value) -> Maybe value
storedValue = fmap versionedValue

rootInitIsDurable :: Fixture -> HarnessState -> Bool
rootInitIsDurable fixture state = case storedValue (harnessRootJournal state) of
  Just rootState -> case rootInitStatePhase rootState of
    RootRecoveryCustodyDurable bundle receipt ->
      bundle == fixtureFinalBundle fixture
        && receipt == fixtureRecovery fixture
    _ -> False
  Nothing -> False

isRootResetCancellationRefusal :: Either BrokerEngineError SomeBrokerResponse -> Bool
isRootResetCancellationRefusal result = case result of
  Left
    ( EngineProgramEvidenceRefused
        (EngineBoundaryRootResetEvidence ResetEvidence.ResetEvidenceCancelledBeforeArm)
      ) -> True
  _ -> False

cancelRootJournalForReset :: HarnessState -> HarnessState
cancelRootJournalForReset state = state {harnessRootJournal = fmap cancel (harnessRootJournal state)}
 where
  cancel stored =
    stored
      { versionedVersion = nextStoreVersion (versionedVersion stored)
      , versionedValue =
          mustRight
            ( applyRootInitCommand
                (versionedValue stored)
                (CancelRootInitialization (mustRight (mkCancellationReason "reset safety-tail cancellation")))
            )
      }

rootInitIsResetPhase :: RootInitState -> Bool
rootInitIsResetPhase state = case rootInitStatePhase state of
  RootResetPristine {} -> True
  _ -> False

armResetFault :: CrashPoint -> HarnessState -> HarnessState
armResetFault fault state = state {harnessCrashPoint = fault, harnessCrashTriggered = False}

rootResetPending :: HarnessState -> Bool
rootResetPending state = case storedValue (harnessRootJournal state) of
  Just snapshot -> case rootInitStatePhase snapshot of
    RootResetInFlight {} -> True
    _ -> False
  Nothing -> False

rootResetTerminal :: HarnessState -> Bool
rootResetTerminal state = case storedValue (harnessRootJournal state) of
  Just snapshot -> case rootInitStatePhase snapshot of
    RootResetPristine {} -> True
    _ -> False
  Nothing -> False

readBoundRootJournal
  :: Harness
  -> (RootInitState -> Bool)
  -> IO (Either StoreBoundaryError (StoreReadBack RootInitState))
readBoundRootJournal harness matches = do
  observed <- readSlot "root-init-journal" harnessRootJournal harness
  pure $ do
    value <- observed
    case value of
      StoreObjectAbsent -> Right StoreObjectAbsent
      StoreObjectPresent _ _ snapshot
        | null (rootInitInvariantViolations snapshot) && matches snapshot -> Right value
        | otherwise -> Left BootstrapStoreBindingMismatch

physicalRootInitIsAmbiguous :: Fixture -> HarnessState -> Bool
physicalRootInitIsAmbiguous fixture state = case storedValue (harnessRootJournal state) of
  Just rootState -> case rootInitStatePhase rootState of
    RootInitializationAmbiguous ambiguity ->
      ambiguity == fixtureAmbiguity fixture
    _ -> False
  Nothing -> False

rootInitIsResetPristine :: Fixture -> HarnessState -> Bool
rootInitIsResetPristine fixture state =
  case storedValue (harnessRootJournal state) of
    Just rootState -> case rootInitStatePhase rootState of
      RootResetPristine proof ->
        proof == fixtureResetProof fixture
      _ -> False
    Nothing -> False

postUnsealIsComplete :: Fixture -> HarnessState -> Bool
postUnsealIsComplete fixture state = case storedValue (harnessPostUnseal state) of
  Just handoff -> case postUnsealHandoffStatePhase handoff of
    PostUnsealHandoffObserved receipt ->
      receipt == fixtureHandoffReceipt fixture
    _ -> False
  Nothing -> False

rootSessionIsClosed :: HarnessState -> Bool
rootSessionIsClosed state = case storedValue (harnessRootSession state) of
  Just session -> case rootSessionStatePhase session of
    RootSessionClosed {} -> True
    _ -> False
  Nothing -> False

childCustodyIsDurable :: Fixture -> HarnessState -> Bool
childCustodyIsDurable fixture state = case storedValue (harnessChildCustody state) of
  Just custody -> case childCustodyStatePhase custody of
    ChildRecoveryCustodyDurable acknowledgement ->
      acknowledgement == fixtureParentAcknowledgement fixture
    _ -> False
  Nothing -> False

physicalChildRecoveryIsComplete :: Fixture -> HarnessState -> Bool
physicalChildRecoveryIsComplete fixture state =
  case storedValue (harnessChildRecovery state) of
    Just recovery -> case childRecoveryStatePhase recovery of
      ChildRecoveryDeliveryRevoked delivery _ repair _ ->
        delivery == fixtureChildDelivery fixture
          && childRecoveryDeliveryNonce delivery
            == fixtureDeliveryNonce fixture
          && repair == fixtureChildRepairReceipt fixture
      _ -> False
    Nothing -> False

workerCheckpointIsComplete :: HarnessState -> Bool
workerCheckpointIsComplete state =
  case ( harnessLastWorkerRequest state
       , storedValue (harnessWorkerCheckpoint state)
       ) of
    (Just request, Just checkpoint) ->
      case decideSecretWorkerRecovery
        request
        SecretWorkerControllerRestarted
        checkpoint of
        SecretWorkerRecoveryComplete _ -> True
        _ -> False
    _ -> False

initRecipientEvents :: [PhysicalEvent] -> [PhysicalEvent]
initRecipientEvents events =
  [event | event@InitRecipientsObserved {} <- events]

custodyPgpEvents :: [PhysicalEvent] -> [Text]
custodyPgpEvents events =
  [ label
  | PgpExecuted label <- events
  , label
      `elem` [ "verify-compiled-burn"
             , "prepare-recovery-recipient"
             , "resume-recovery-recipient"
             , "decrypt-recovery-shares"
             , "seal-final-unlock-payload"
             ]
  ]

workerExecutionEvents :: [PhysicalEvent] -> [SecretWorkerOperation]
workerExecutionEvents events =
  [operation | WorkerExecuted operation <- events]

workerLifecycleEvents :: [PhysicalEvent] -> [PhysicalEvent]
workerLifecycleEvents events =
  [ event
  | event <- events
  , case event of
      WorkerAllocated {} -> True
      WorkerAttested {} -> True
      WorkerExecuted {} -> True
      WorkerSessionRevoked -> True
      WorkerExited -> True
      WorkerDeleted -> True
      WorkerAbsent -> True
      _ -> False
  ]

fenceLifecycleEvents :: [PhysicalEvent] -> [PhysicalEvent]
fenceLifecycleEvents events =
  [ event
  | event <- events
  , case event of
      FenceAcquired {} -> True
      FenceResumed {} -> True
      FenceReleased {} -> True
      _ -> False
  ]

rootSessionIdentities :: [PhysicalEvent] -> [RootSessionId]
rootSessionIdentities events =
  [ mustRight (mkRootSessionId rendered)
  | PgpExecuted label <- events
  , Just rendered <- [Text.stripPrefix "root-action-observe:" label]
  ]

physicalAndStoreMutationEvents :: [PhysicalEvent] -> [PhysicalEvent]
physicalAndStoreMutationEvents events =
  [ event
  | event <- events
  , case event of
      PhysicalMutated {} -> True
      StoreMutated {} -> True
      _ -> False
  ]

assertCleanHarness :: HarnessState -> Expectation
assertCleanHarness state = do
  harnessPermitViolations state `shouldBe` []
  harnessBurnDecryptCount state `shouldBe` 0
  harnessLiveProvisionerAccessors state `shouldBe` []

assertCapabilityEvents
  :: Fixture -> BrokerRoute -> Int -> HarnessState -> Expectation
assertCapabilityEvents _fixture route invocationCount state = do
  let expected =
        replicate
          invocationCount
          ( brokerRouteCapabilityOp route
          , coordinateDigest (expectedCoordinate route)
          )
      admitted =
        [ (operation, digestValue)
        | CapabilityAdmitted operation digestValue <- harnessEvents state
        ]
      began =
        [ (operation, digestValue)
        | CapabilityBegan operation digestValue <- harnessEvents state
        ]
  admitted `shouldBe` expected
  began `shouldBe` expected

expectedCoordinate :: BrokerRoute -> CapabilityCoordinate
expectedCoordinate route = case route of
  BrokerVaultBaselineReconcile -> coordinate "physical-baseline"
  BrokerVaultPkiStatus -> coordinate "physical-pki"
  BrokerVaultPkiIssueTestCertificate -> coordinate "physical-pki"
  BrokerHealth -> coordinate "physical-observe"
  BrokerReadiness -> coordinate "physical-observe"
  BrokerVaultStatus -> coordinate "physical-observe"
  BrokerChildRecoveryObserve -> coordinate "physical-observe"
  _ -> coordinate "physical-mutate"

data PhysicalServer = PhysicalServer
  { physicalServerSettings :: !Settings.BootstrapBrokerSettings
  , physicalServerHandle :: !Server.BrokerServerHandle
  }

withPhysicalServer
  :: Fixture
  -> BrokerEngine IO
  -> (Settings.BootstrapBrokerSettings -> Expectation)
  -> Expectation
withPhysicalServer _fixture engine assertion =
  withSocketsDo $
    bracket
      (startPhysicalServer 8 engine)
      stopPhysicalServer
      (assertion . physicalServerSettings)

startPhysicalServer :: Int -> BrokerEngine IO -> IO PhysicalServer
startPhysicalServer remainingAttempts engine
  | remainingAttempts <= 0 =
      throwIO (userError "could not reserve physical loopback port")
  | otherwise = do
      port <- reserveEphemeralLoopbackPort
      let settings = requireSettings port
      started <-
        Server.startBrokerServer
          settings
          permissiveAuthenticator
          (engineBrokerInterpreter engine)
      case started of
        Right handle -> pure (PhysicalServer settings handle)
        Left Server.BrokerListenerUnavailable ->
          startPhysicalServer (remainingAttempts - 1) engine
        Left failure ->
          throwIO (userError (Server.renderBrokerServerError failure))

stopPhysicalServer :: PhysicalServer -> IO ()
stopPhysicalServer server = do
  Server.beginBrokerDrain (physicalServerHandle server)
  stopped <-
    timeout 2_000_000 (Server.waitBrokerServer (physicalServerHandle server))
  case stopped of
    Just _ -> pure ()
    Nothing -> do
      Server.forceBrokerDrain (physicalServerHandle server)
      void
        ( timeout
            2_000_000
            (Server.waitBrokerServer (physicalServerHandle server))
        )

permissiveAuthenticator :: Server.BrokerAuthenticator
permissiveAuthenticator =
  Server.BrokerAuthenticator $ \request ->
    pure (Right (Server.authenticationClaimedIdentity request))

reserveEphemeralLoopbackPort :: IO PortNumber
reserveEphemeralLoopbackPort =
  bracket
    (socket AF_INET Stream defaultProtocol)
    close
    ( \listener -> do
        bind listener (SockAddrInet 0 literalIpv4Loopback)
        address <- getSocketName listener
        case address of
          SockAddrInet port _
            | port /= 0 -> pure port
          _ -> throwIO (userError "ephemeral physical port was not IPv4")
    )

literalIpv4Loopback :: HostAddress
literalIpv4Loopback = tupleToHostAddress (127, 0, 0, 1)

data Fixture = Fixture
  { fixturePristine :: !PristineStorageProof
  , fixturePrepared :: !PreparedInitEnvelope
  , fixtureEncryptedResponse :: !EncryptedInitResponseReceipt
  , fixtureFinalBundle :: !FinalUnlockBundle
  , fixtureRecovery :: !RecoveryCustodyReceipt
  , fixtureAmbiguity :: !InitAmbiguity
  , fixtureResetProof :: !PristineResetProof
  , fixtureMismatchedResetProof :: !PristineResetProof
  , fixtureSessionId :: !RootSessionId
  , fixtureRestartSessionId :: !RootSessionId
  , fixtureStaleAccessor :: !RootPolicyAccessor
  , fixtureCurrentAccessor :: !RootPolicyAccessor
  , fixtureStaleInventory :: !RootAccessorInventory
  , fixtureCurrentInventory :: !RootAccessorInventory
  , fixtureBaselineReceipt :: !BaselineReadBackReceipt
  , fixtureProvisionerReceipt :: !ProvisionerLoginReceipt
  , fixtureHandoffReceipt :: !PostUnsealHandoffReceipt
  , fixtureChildBinding :: !ChildCustodyBinding
  , fixtureChildReceipt :: !ChildEncryptedReceipt
  , fixtureParentAcknowledgement :: !ParentCustodyAcknowledgement
  , fixtureDeliveryNonce :: !DeliveryNonce
  , fixtureChildAttestation :: !ChildAttestation
  , fixtureChildDelivery :: !ChildRecoveryDelivery
  , fixtureChildRepairReceipt :: !ChildRecoveryRepairReceipt
  , fixtureActions :: !(BrokerRoute -> BrokerActionRequest)
  , fixtureCapabilityRefs :: !BrokerCapabilityRefs
  , fixtureServiceIdentity :: !Request.BrokerServiceIdentity
  , fixtureClientCredential :: !Client.BrokerClientCredential
  , fixtureBurnRecipient :: !Pgp.VerifiedBurnRecipient
  }

buildFixture :: Either String Fixture
buildFixture = do
  transaction <- bootstrap (mkBootstrapTransactionId "physical-root")
  replacementTransaction <-
    bootstrap (mkBootstrapTransactionId "physical-root-next")
  mismatchedReplacementTransaction <-
    bootstrap (mkBootstrapTransactionId "physical-root-mismatch")
  generation <- bootstrap (mkVaultStorageGeneration "physical-storage")
  replacementGeneration <-
    bootstrap (mkVaultStorageGeneration "physical-storage-next")
  mismatchedReplacementGeneration <-
    bootstrap (mkVaultStorageGeneration "physical-storage-mismatch")
  schema <- bootstrap (mkBootstrapSchemaVersion 1)
  initDigest <- digest '1'
  preparedDigest <- digest '2'
  responseDigest <- digest '3'
  bundleDigest <-
    bootstrap
      ( mkArtifactDigest
          "b88bec05ff76c4c647cc782469ec8c8bba232b55484df9320ea50385bf045ebf"
      )
  acknowledgementDigest <- digest '5'
  recoveryFingerprint <-
    bootstrap (mkRecoveryRecipientFingerprint (Text.replicate 64 "a"))
  burnFingerprint <-
    bootstrap
      ( mkBurnRecipientFingerprint
          ( Settings.unBurnRecipientFingerprint
              ( Settings.burnRecipientFingerprint
                  Settings.compiledBurnRecipient
              )
          )
      )
  burnPublicKey <-
    pgp
      ( Pgp.mkBurnRecipientPublicKey
          ( Settings.burnRecipientPublicKeyBase64
              Settings.compiledBurnRecipient
          )
      )
  verifiedBurn <-
    pgp
      ( Pgp.mkVerifiedBurnRecipient
          Settings.compiledBurnRecipient
          burnPublicKey
          burnFingerprint
      )
  sealedPrivateKey <-
    bootstrap
      (mkSealedRecoveryRecipientPrivateKey "sealed-physical-private-key")
  let recoveryPublicKey = "cmVjb3ZlcnktcHVibGljLWtleQ=="
  commitment <-
    bootstrap
      ( mkInitRecipientCommitment
          1
          1
          [recoveryPublicKey]
          recoveryFingerprint
          burnFingerprint
          (Pgp.verifiedBurnRecipientPublicKeyDigest verifiedBurn)
      )
  encryptedShare <- bootstrap (mkPgpEncryptedShare "encrypted-share")
  burnCiphertext <- bootstrap (mkBurnTokenCiphertext "burn-only-ciphertext")
  recoveredShare <- bootstrap (mkRecoveredUnsealShare "recovered-share")
  bundleCiphertext <-
    bootstrap (mkPasswordAeadCiphertext "sealed-unlock-bundle")
  let binding = RootInitBinding transaction generation
      pristine = mkPristineStorageProof binding initDigest
      prepared =
        mkPreparedInitEnvelope
          pristine
          schema
          sealedPrivateKey
          commitment
          preparedDigest
  encryptedResponse <-
    bootstrap
      ( mkEncryptedInitResponseReceipt
          prepared
          [encryptedShare]
          burnCiphertext
          responseDigest
      )
  payload <-
    bootstrap
      (mkFinalUnlockBundlePayload encryptedResponse [recoveredShare])
  let finalBundle =
        mkFinalUnlockBundle payload bundleCiphertext bundleDigest
      recovery =
        mkRecoveryCustodyReceipt finalBundle acknowledgementDigest
      ambiguity = mkInitAmbiguity prepared
      replacementBinding =
        RootInitBinding replacementTransaction replacementGeneration
      replacementPristine =
        mkPristineStorageProof replacementBinding initDigest
      mismatchedReplacementBinding =
        RootInitBinding
          mismatchedReplacementTransaction
          mismatchedReplacementGeneration
      mismatchedReplacementPristine =
        mkPristineStorageProof mismatchedReplacementBinding initDigest
      establishedAbsence = mkEstablishedStateAbsence binding initDigest
      responseAbsence =
        mkDurableInitResponseAbsence binding responseDigest
      baselineAbsence = mkBaselineStateAbsence binding bundleDigest
  resetProof <-
    bootstrap
      ( mkPristineResetProof
          ambiguity
          replacementPristine
          establishedAbsence
          responseAbsence
          baselineAbsence
      )
  mismatchedResetProof <-
    bootstrap
      ( mkPristineResetProof
          ambiguity
          mismatchedReplacementPristine
          establishedAbsence
          responseAbsence
          baselineAbsence
      )
  sessionId <- bootstrap (mkRootSessionId "physical-root-session")
  restartSessionId <-
    bootstrap (mkRootSessionId "physical-root-session-restarted")
  staleAccessor <- bootstrap (mkRootPolicyAccessor "stale-root-accessor")
  currentAccessor <- bootstrap (mkRootPolicyAccessor "current-root-accessor")
  staleInventory <-
    bootstrap (mkRootAccessorInventory generation [staleAccessor])
  currentInventory <-
    bootstrap (mkRootAccessorInventory generation [currentAccessor])
  baselineReceipt <-
    bootstrap
      ( mkBaselineReadBackReceipt
          sessionId
          generation
          requiredRootBaselineTargets
          bundleDigest
      )
  provisionerAccessor <-
    bootstrap (mkProvisionerAccessor "physical-provisioner-accessor")
  provisionerReceipt <-
    bootstrap (mkProvisionerLoginReceipt generation provisionerAccessor 60)
  let handoffReceipt =
        mkPostUnsealHandoffReceipt
          generation
          PostUnsealLifecycleAuthority
          acknowledgementDigest
  childId <- bootstrap (mkChildId "physical-child")
  custodyGeneration <- bootstrap (mkCustodyGeneration 1)
  let childBinding =
        ChildCustodyBinding
          { childCustodyChildId = childId
          , childCustodyStorageGeneration = generation
          , childCustodyGeneration = custodyGeneration
          , childCustodyTransactionId = transaction
          }
  childReceipt <-
    bootstrap
      ( mkChildEncryptedReceipt
          childBinding
          [encryptedShare]
          burnCiphertext
          responseDigest
      )
  let parentAcknowledgement =
        mkParentCustodyAcknowledgement childReceipt acknowledgementDigest
  nonce <- bootstrap (mkDeliveryNonce "physical-child-delivery")
  let attestation = mkChildAttestation initDigest
  childPayload <-
    bootstrap
      (mkEncryptedChildRecoveryPayload "encrypted-child-recovery-payload")
  let delivery =
        mkChildRecoveryDelivery
          childBinding
          nonce
          attestation
          childPayload
          bundleDigest
      repairReceipt =
        mkChildRecoveryRepairReceipt delivery acknowledgementDigest
  serviceIdentity <-
    firstString (Request.mkBrokerServiceIdentity "physical-engine-test")
  credential <-
    firstString
      (Client.mkBrokerClientCredential "physical-engine-attestation")
  pure
    Fixture
      { fixturePristine = pristine
      , fixturePrepared = prepared
      , fixtureEncryptedResponse = encryptedResponse
      , fixtureFinalBundle = finalBundle
      , fixtureRecovery = recovery
      , fixtureAmbiguity = ambiguity
      , fixtureResetProof = resetProof
      , fixtureMismatchedResetProof = mismatchedResetProof
      , fixtureSessionId = sessionId
      , fixtureRestartSessionId = restartSessionId
      , fixtureStaleAccessor = staleAccessor
      , fixtureCurrentAccessor = currentAccessor
      , fixtureStaleInventory = staleInventory
      , fixtureCurrentInventory = currentInventory
      , fixtureBaselineReceipt = baselineReceipt
      , fixtureProvisionerReceipt = provisionerReceipt
      , fixtureHandoffReceipt = handoffReceipt
      , fixtureChildBinding = childBinding
      , fixtureChildReceipt = childReceipt
      , fixtureParentAcknowledgement = parentAcknowledgement
      , fixtureDeliveryNonce = nonce
      , fixtureChildAttestation = attestation
      , fixtureChildDelivery = delivery
      , fixtureChildRepairReceipt = repairReceipt
      , fixtureActions = actionForRoute generation
      , fixtureCapabilityRefs = capabilityRefs
      , fixtureServiceIdentity = serviceIdentity
      , fixtureClientCredential = credential
      , fixtureBurnRecipient = verifiedBurn
      }

actionForRoute
  :: VaultStorageGeneration -> BrokerRoute -> BrokerActionRequest
actionForRoute generation route =
  mkBrokerActionRequest generation (routeDigest route)

routeDigest :: BrokerRoute -> ArtifactDigest
routeDigest route =
  digestOf
    ( case route of
        BrokerHealth -> '0'
        BrokerReadiness -> '1'
        BrokerVaultStatus -> '2'
        BrokerVaultInitialize -> '3'
        BrokerVaultUnseal -> '4'
        BrokerVaultSeal -> '5'
        BrokerVaultRotateUnlockBundle -> '6'
        BrokerVaultRotateTransitKey -> '7'
        BrokerVaultBaselineReconcile -> '8'
        BrokerPostUnsealHandoffReconcile -> '8'
        BrokerVaultPkiStatus -> '9'
        BrokerVaultPkiIssueTestCertificate -> 'a'
        BrokerVaultResetAmbiguousInitialization -> 'b'
        BrokerChildCustodyPrepare -> 'c'
        BrokerChildCustodyFinalize -> 'd'
        BrokerChildRecoveryDeliver -> 'e'
        BrokerChildRecoveryObserve -> 'f'
    )

capabilityRefs :: BrokerCapabilityRefs
capabilityRefs =
  mkBrokerCapabilityRefs
    (coordinate "physical-observe")
    (coordinate "physical-mutate")
    (coordinate "physical-baseline")
    (coordinate "physical-pki")

coordinate :: Text -> CapabilityCoordinate
coordinate name =
  mkCoordinate
    (mustRight (mkServiceIdentity "bootstrap-broker"))
    (mustRight (mkAuthorityScope "home/prodbox"))
    (mustRight (mkCapabilityEndpoint "127.0.0.1:30444"))
    (mustRight (mkLogicalName name))
    (mustRight (mkCredentialGeneration 1))

data Versioned value = Versioned
  { versionedVersion :: !StoreVersion
  , versionedDigest :: !ArtifactDigest
  , versionedValue :: !value
  }
  deriving (Eq, Show)

data InitPhysicalMode
  = ReturnEncryptedInitResponse
  | ReturnAppliedWithoutResponse
  | ReturnClassifiedAppliedWithoutResponse !InitializationAmbiguityCause
  deriving (Eq, Show)

data CrashPoint
  = NoCrash
  | CrashAfterRootJournalCas
  | CrashAfterResetGenerationAdvance
  | CrashAfterResetArmCas
  | CrashAfterResetTerminalCas
  | CrashAfterResetPreparationDelete
  | CrashAfterInitEffectBeforeWorkerReceipt
  | CrashAfterInitWorkerReceiptCas
  | CrashAfterAuthoritativeWorkerCheckpointCas
  | CrashAfterRootAmbiguityCas
  | CrashAfterRecoveryDeliveryDelete
  | CrashAfterChildConsumeEffect
  | CrashAfterRootScopeCas
  | CrashAfterProvisionerLoginResponseLoss
  | CrashAfterProvisionerLoginException
  | CrashAfterProvisionerLoginCancellation
  | CrashAfterChildScopeCas
  deriving (Eq, Show)

data PhysicalEvent
  = CapabilityAdmitted !CapabilityOp !CoordinateDigest
  | CapabilityBegan !CapabilityOp !CoordinateDigest
  | FenceAcquired !Natural
  | FenceResumed !Natural
  | FenceObserved
  | FenceReleased !Natural
  | StoreRead !Text
  | StoreMutated !BootstrapStoreMutation
  | PhysicalObserved !Text
  | PhysicalMutated !BootstrapVaultEffect
  | InitRecipientsObserved ![Text] !Text !Natural !Natural
  | InitVaultEffectApplied
  | LocalExecuted !Text
  | WorkerAllocated !SecretWorkerOperation
  | WorkerAttested !SecretWorkerOperation
  | WorkerDiscarded !SecretWorkerOperation
  | WorkerExecuted !SecretWorkerOperation
  | WorkerSessionRevoked
  | WorkerExited
  | WorkerDeleted
  | WorkerAbsent
  | PgpExecuted !Text
  deriving (Eq, Show)

data HarnessState = HarnessState
  { harnessFenceFloor :: !Natural
  , harnessHeldFence :: !(Maybe BootstrapSessionFence)
  , harnessFenceOwnerNonce :: !OwnerNonce
  , harnessRootBinding :: !RootInitBinding
  , harnessRootJournal :: !(Maybe (Versioned RootInitState))
  , harnessPreparedEnvelope :: !(Maybe (Versioned PreparedInitEnvelope))
  , harnessEncryptedResponse
      :: !(Maybe (Versioned EncryptedInitResponseReceipt))
  , harnessFinalBundle :: !(Maybe (Versioned FinalUnlockBundle))
  , harnessRootSession :: !(Maybe (Versioned RootSessionState))
  , harnessChildReceipt :: !(Maybe (Versioned ChildEncryptedReceipt))
  , harnessChildCustody :: !(Maybe (Versioned ChildCustodyState))
  , harnessRecoveryDelivery :: !(Maybe (Versioned ChildRecoveryDelivery))
  , harnessChildRecovery :: !(Maybe (Versioned ChildRecoveryState))
  , harnessPostUnseal :: !(Maybe (Versioned PostUnsealHandoffState))
  , harnessWorkerCheckpoint
      :: !(Maybe (Versioned SecretWorkerDurableCheckpoint))
  , harnessLastWorkerRequest :: !(Maybe SecretFreeWorkerRequest)
  , harnessLastBaselineReceipt :: !(Maybe BaselineReadBackReceipt)
  , harnessEvents :: ![PhysicalEvent]
  , harnessPermitViolations :: ![Text]
  , harnessInitMode :: !InitPhysicalMode
  , harnessCrashPoint :: !CrashPoint
  , harnessCrashTriggered :: !Bool
  , harnessLeaseAvailable :: !Bool
  , harnessPhysicalMutationCount :: !Natural
  , harnessStoreMutationCount :: !Natural
  , harnessBurnDecryptCount :: !Natural
  , harnessLiveRootAccessors :: ![RootPolicyAccessor]
  , harnessLiveProvisionerAccessors :: ![ProvisionerAccessor]
  , harnessRootScopeCounter :: !Natural
  , harnessChildScopeCounter :: !Natural
  , harnessIssuedRootTokens :: ![ByteString]
  , harnessIssuedChildTokens :: ![ByteString]
  , harnessRevokedRootTokens :: ![ByteString]
  , harnessRevokedChildTokens :: ![ByteString]
  , harnessBaselineEvidenceCount :: !Natural
  , harnessResetProofOverride :: !(Maybe PristineResetProof)
  , harnessAccessorObservationAvailable :: !Bool
  , harnessConsumedRecoveryDelivery :: !(Maybe ChildRecoveryDelivery)
  , harnessChildConsumptionObservable :: !Bool
  , harnessChildConsumptionObservationOverride
      :: !(Maybe ChildRecoveryConsumptionObservation)
  }

type Harness = IORef HarnessState

newHarness
  :: Fixture -> InitPhysicalMode -> CrashPoint -> IO Harness
newHarness fixture initMode crashPoint =
  newIORef
    HarnessState
      { harnessFenceFloor = 0
      , harnessHeldFence = Nothing
      , harnessFenceOwnerNonce = fixtureOwnerNonce
      , harnessRootBinding = pristineStorageBinding (fixturePristine fixture)
      , harnessRootJournal = Nothing
      , harnessPreparedEnvelope = Nothing
      , harnessEncryptedResponse = Nothing
      , harnessFinalBundle = Nothing
      , harnessRootSession = Nothing
      , harnessChildReceipt = Nothing
      , harnessChildCustody = Nothing
      , harnessRecoveryDelivery = Nothing
      , harnessChildRecovery = Nothing
      , harnessPostUnseal = Nothing
      , harnessWorkerCheckpoint = Nothing
      , harnessLastWorkerRequest = Nothing
      , harnessLastBaselineReceipt = Nothing
      , harnessEvents = []
      , harnessPermitViolations = []
      , harnessInitMode = initMode
      , harnessCrashPoint = crashPoint
      , harnessCrashTriggered = False
      , harnessLeaseAvailable = True
      , harnessPhysicalMutationCount = 0
      , harnessStoreMutationCount = 0
      , harnessBurnDecryptCount = 0
      , harnessLiveRootAccessors = [fixtureStaleAccessor fixture]
      , harnessLiveProvisionerAccessors = []
      , harnessRootScopeCounter = 0
      , harnessChildScopeCounter = 0
      , harnessIssuedRootTokens = []
      , harnessIssuedChildTokens = []
      , harnessRevokedRootTokens = []
      , harnessRevokedChildTokens = []
      , harnessBaselineEvidenceCount = 0
      , harnessResetProofOverride = Nothing
      , harnessAccessorObservationAvailable = True
      , harnessConsumedRecoveryDelivery = Nothing
      , harnessChildConsumptionObservable = True
      , harnessChildConsumptionObservationOverride = Nothing
      }

recordEvent :: Harness -> PhysicalEvent -> IO ()
recordEvent harness event =
  modifyIORef' harness $ \state ->
    state {harnessEvents = harnessEvents state ++ [event]}

markCrashTriggered :: Harness -> IO ()
markCrashTriggered harness =
  modifyIORef' harness $ \state -> state {harnessCrashTriggered = True}

recordPermitViolation :: Harness -> Text -> IO ()
recordPermitViolation harness detail =
  modifyIORef' harness $ \state ->
    state
      { harnessPermitViolations =
          harnessPermitViolations state ++ [detail]
      }

readSlot
  :: Text
  -> (HarnessState -> Maybe (Versioned value))
  -> Harness
  -> IO (Either StoreBoundaryError (StoreReadBack value))
readSlot label project harness = do
  recordEvent harness (StoreRead label)
  state <- readIORef harness
  pure (Right (versionedReadBack (project state)))

versionedReadBack
  :: Maybe (Versioned value) -> StoreReadBack value
versionedReadBack stored = case stored of
  Nothing -> StoreObjectAbsent
  Just Versioned {versionedVersion, versionedDigest, versionedValue} ->
    StoreObjectPresent versionedVersion versionedDigest versionedValue

createSlot
  :: (Eq value)
  => Harness
  -> BootstrapStoreMutation
  -> BootstrapStoreMutationPermit
  -> (HarnessState -> Maybe (Versioned value))
  -> (Maybe (Versioned value) -> HarnessState -> HarnessState)
  -> value
  -> IO (Either StoreBoundaryError (StoreWriteResult value))
createSlot harness mutation permit project replace value = do
  authorized <- authorizeStoreMutation harness mutation permit
  if not authorized
    then pure (Left BootstrapStoreBindingMismatch)
    else do
      state <- readIORef harness
      case project state of
        Just existing ->
          pure (Right (StoreWriteConflict (versionedReadBack (Just existing))))
        Nothing -> do
          let stored = Versioned (StoreVersion 1) storeDigest value
          modifyIORef' harness (replace (Just stored))
          pure
            ( Right
                (StoreWriteApplied (StoreVersion 1) storeDigest value)
            )

casSlot
  :: (Eq value)
  => Harness
  -> BootstrapStoreMutation
  -> BootstrapStoreMutationPermit
  -> StoreVersion
  -> (HarnessState -> Maybe (Versioned value))
  -> (Maybe (Versioned value) -> HarnessState -> HarnessState)
  -> value
  -> IO (Either StoreBoundaryError (StoreWriteResult value))
casSlot harness mutation permit expectedVersion project replace value = do
  authorized <- authorizeStoreMutation harness mutation permit
  if not authorized
    then pure (Left BootstrapStoreBindingMismatch)
    else do
      state <- readIORef harness
      case project state of
        Just existing
          | versionedVersion existing == expectedVersion -> do
              let next = nextStoreVersion expectedVersion
                  stored = Versioned next storeDigest value
              modifyIORef' harness (replace (Just stored))
              shouldCrash <- consumeCrash harness mutation
              if shouldCrash
                then pure (Left BootstrapStoreUnavailable)
                else pure (Right (StoreWriteApplied next storeDigest value))
        existing ->
          pure
            ( Right
                (StoreWriteConflict (versionedReadBack existing))
            )

deleteSlot
  :: Harness
  -> BootstrapStoreMutation
  -> BootstrapStoreMutationPermit
  -> StoreVersion
  -> (HarnessState -> Maybe (Versioned value))
  -> (Maybe (Versioned value) -> HarnessState -> HarnessState)
  -> IO (Either StoreBoundaryError ())
deleteSlot harness mutation permit expectedVersion project replace = do
  authorized <- authorizeStoreMutation harness mutation permit
  if not authorized
    then pure (Left BootstrapStoreBindingMismatch)
    else do
      state <- readIORef harness
      case project state of
        Nothing -> pure (Right ())
        Just existing
          | versionedVersion existing == expectedVersion -> do
              modifyIORef' harness (replace Nothing)
              shouldCrash <- consumeCrash harness mutation
              if shouldCrash
                then pure (Left BootstrapStoreUnavailable)
                else pure (Right ())
          | otherwise -> pure (Left BootstrapStoreVersionConflict)

consumeCrash :: Harness -> BootstrapStoreMutation -> IO Bool
consumeCrash harness mutation = do
  state <- readIORef harness
  let mutationMatches = case harnessCrashPoint state of
        CrashAfterRootJournalCas ->
          mutation == BootstrapStoreCasRootInitJournal
        CrashAfterResetGenerationAdvance ->
          mutation == BootstrapStoreAdvanceVaultStorageGeneration
        CrashAfterResetArmCas ->
          mutation == BootstrapStoreCasRootInitJournal && rootResetPending state
        CrashAfterResetTerminalCas ->
          mutation == BootstrapStoreCasRootInitJournal && rootResetTerminal state
        CrashAfterResetPreparationDelete ->
          mutation == BootstrapStoreDeletePreparedInitEnvelope
        CrashAfterInitEffectBeforeWorkerReceipt -> False
        CrashAfterInitWorkerReceiptCas ->
          mutation == BootstrapStoreCasSecretWorkerCheckpoint
            && initWorkerAwaitingCleanup state
        CrashAfterAuthoritativeWorkerCheckpointCas ->
          mutation == BootstrapStoreCasSecretWorkerCheckpoint
            && initWorkerAuthoritativelyComplete state
        CrashAfterRootAmbiguityCas ->
          mutation == BootstrapStoreCasRootInitJournal
            && case storedValue (harnessRootJournal state) of
              Just journal -> case rootInitStatePhase journal of
                RootInitializationAmbiguous _ -> True
                _ -> False
              Nothing -> False
        CrashAfterRecoveryDeliveryDelete ->
          mutation == BootstrapStoreDeleteChildRecoveryDelivery
        CrashAfterChildConsumeEffect -> False
        CrashAfterRootScopeCas ->
          mutation == BootstrapStoreCasRootSessionJournal
            && PgpExecuted "root-action-observe" `elem` harnessEvents state
        CrashAfterProvisionerLoginResponseLoss -> False
        CrashAfterProvisionerLoginException -> False
        CrashAfterProvisionerLoginCancellation -> False
        CrashAfterChildScopeCas ->
          mutation == BootstrapStoreCasChildRecoveryJournal
            && PgpExecuted "child-action-observe" `elem` harnessEvents state
        NoCrash -> False
      shouldCrash =
        not (harnessCrashTriggered state)
          && mutationMatches
  if shouldCrash
    then do
      modifyIORef' harness $ \current ->
        current {harnessCrashTriggered = True}
      pure True
    else pure False

initWorkerAuthoritativelyComplete :: HarnessState -> Bool
initWorkerAuthoritativelyComplete state =
  case storedValue (harnessWorkerCheckpoint state) of
    Nothing -> False
    Just checkpoint -> case secretWorkerCheckpointRequest checkpoint of
      Left _ -> False
      Right request
        | secretWorkerRequestOperation request == SecretWorkerInitialize ->
            case decideSecretWorkerRecovery request SecretWorkerControllerRestarted checkpoint of
              SecretWorkerRecoveryAuthoritativeComplete _ -> True
              _ -> False
        | otherwise -> False

initWorkerAwaitingCleanup :: HarnessState -> Bool
initWorkerAwaitingCleanup state =
  case (harnessLastWorkerRequest state, storedValue (harnessWorkerCheckpoint state)) of
    (Just request, Just checkpoint)
      | secretWorkerRequestOperation request == SecretWorkerInitialize ->
          case decideSecretWorkerRecovery
            request
            SecretWorkerControllerRestarted
            checkpoint of
            SecretWorkerRecoveryRevokeSession {} -> True
            _ -> False
    _ -> False

authorizeStoreMutation
  :: Harness
  -> BootstrapStoreMutation
  -> BootstrapStoreMutationPermit
  -> IO Bool
authorizeStoreMutation harness expected permit = do
  state <- readIORef harness
  let valid =
        storeMutationPermitMutation permit == expected
          && maybe False (storePermitMatchesFence permit) (harnessHeldFence state)
  if valid
    then do
      recordEvent harness (StoreMutated expected)
      modifyIORef' harness $ \current ->
        current
          { harnessStoreMutationCount =
              harnessStoreMutationCount current + 1
          }
      pure True
    else do
      recordPermitViolation harness "store permit mismatch"
      pure False

storePermitMatchesFence
  :: BootstrapStoreMutationPermit -> BootstrapSessionFence -> Bool
storePermitMatchesFence permit fence =
  storeMutationPermitFenceGeneration permit == bootstrapFenceGeneration fence
    && storeMutationPermitOwnerNonce permit == bootstrapFenceOwnerNonce fence
    && storeMutationPermitActionDigest permit == bootstrapFenceActionDigest fence
    && storeMutationPermitRequestDigest permit == bootstrapFenceRequestDigest fence
    && storeMutationPermitStorageGeneration permit
      == bootstrapFenceStorageGeneration fence
    && storeMutationPermitOperationDeadline permit
      == bootstrapFenceOperationDeadline fence

physicalStoreBoundary
  :: Fixture -> Harness -> BootstrapStoreBoundary IO
physicalStoreBoundary fixture harness =
  unavailableBootstrapStoreBoundary
    { observeVaultStorageGeneration = do
        recordEvent harness (StoreRead "vault-storage-generation")
        state <- readIORef harness
        pure (Right (harnessRootBinding state))
    , advanceVaultStorageGeneration =
        \permit expected replacement -> do
          authorized <-
            authorizeStoreMutation
              harness
              BootstrapStoreAdvanceVaultStorageGeneration
              permit
          if not authorized
            then pure (Left BootstrapStoreBindingMismatch)
            else do
              state <- readIORef harness
              if harnessRootBinding state == expected
                then do
                  modifyIORef' harness $ \current ->
                    current {harnessRootBinding = replacement}
                  shouldCrash <-
                    consumeCrash
                      harness
                      BootstrapStoreAdvanceVaultStorageGeneration
                  if shouldCrash
                    then pure (Left BootstrapStoreUnavailable)
                    else pure (Right replacement)
                else
                  if harnessRootBinding state == replacement
                    then pure (Right replacement)
                    else pure (Left BootstrapStoreBindingMismatch)
    , readRootInitJournal =
        \binding -> readBoundRootJournal harness (ProductionStore.rootInitReadMatches binding)
    , readRootInitJournalForReset =
        \generation -> readBoundRootJournal harness (ProductionStore.rootInitResetReadMatches generation)
    , createRootInitJournal =
        \permit value ->
          createSlot
            harness
            BootstrapStoreCreateRootInitJournal
            permit
            harnessRootJournal
            setRootJournal
            value
    , casRootInitJournal =
        \permit version value ->
          casSlot
            harness
            BootstrapStoreCasRootInitJournal
            permit
            version
            harnessRootJournal
            setRootJournal
            value
    , readPreparedInitEnvelope =
        \_ ->
          readSlot
            "prepared-init-envelope"
            harnessPreparedEnvelope
            harness
    , createPreparedInitEnvelope =
        \permit value ->
          createSlot
            harness
            BootstrapStoreCreatePreparedInitEnvelope
            permit
            harnessPreparedEnvelope
            setPreparedEnvelope
            value
    , deletePreparedInitEnvelope =
        \permit _ version ->
          deleteSlot
            harness
            BootstrapStoreDeletePreparedInitEnvelope
            permit
            version
            harnessPreparedEnvelope
            setPreparedEnvelope
    , readEncryptedInitResponse =
        \_ ->
          readSlot
            "encrypted-init-response"
            harnessEncryptedResponse
            harness
    , createEncryptedInitResponse =
        \permit value ->
          createSlot
            harness
            BootstrapStoreCreateEncryptedInitResponse
            permit
            harnessEncryptedResponse
            setEncryptedResponse
            value
    , readFinalUnlockBundle =
        \_ -> readSlot "final-unlock-bundle" harnessFinalBundle harness
    , promoteFinalUnlockBundle =
        \permit response value ->
          if response /= fixtureEncryptedResponse fixture
            then pure (Left BootstrapStoreBindingMismatch)
            else
              createSlot
                harness
                BootstrapStorePromoteFinalUnlockBundle
                permit
                harnessFinalBundle
                setFinalBundle
                value
    , casFinalUnlockBundle =
        \permit version value ->
          casSlot
            harness
            BootstrapStoreCasFinalUnlockBundle
            permit
            version
            harnessFinalBundle
            setFinalBundle
            value
    , readRootSessionJournal =
        \_ -> readSlot "root-session-journal" harnessRootSession harness
    , createRootSessionJournal =
        \permit value ->
          createSlot
            harness
            BootstrapStoreCreateRootSessionJournal
            permit
            harnessRootSession
            setRootSession
            value
    , casRootSessionJournal =
        \permit version value ->
          casSlot
            harness
            BootstrapStoreCasRootSessionJournal
            permit
            version
            harnessRootSession
            setRootSession
            value
    , readChildEncryptedReceipt =
        \_ -> readSlot "child-encrypted-receipt" harnessChildReceipt harness
    , createChildEncryptedReceipt =
        \permit value ->
          createSlot
            harness
            BootstrapStoreCreateChildEncryptedReceipt
            permit
            harnessChildReceipt
            setChildReceipt
            value
    , deleteChildEncryptedReceipt =
        \permit _ version ->
          deleteSlot
            harness
            BootstrapStoreDeleteChildEncryptedReceipt
            permit
            version
            harnessChildReceipt
            setChildReceipt
    , readChildCustodyJournal =
        \_ -> readSlot "child-custody-journal" harnessChildCustody harness
    , createChildCustodyJournal =
        \permit value ->
          createSlot
            harness
            BootstrapStoreCreateChildCustodyJournal
            permit
            harnessChildCustody
            setChildCustody
            value
    , casChildCustodyJournal =
        \permit version value ->
          casSlot
            harness
            BootstrapStoreCasChildCustodyJournal
            permit
            version
            harnessChildCustody
            setChildCustody
            value
    , readChildRecoveryDelivery =
        \_ ->
          readSlot
            "child-recovery-delivery"
            harnessRecoveryDelivery
            harness
    , createChildRecoveryDelivery =
        \permit value ->
          createSlot
            harness
            BootstrapStoreCreateChildRecoveryDelivery
            permit
            harnessRecoveryDelivery
            setRecoveryDelivery
            value
    , deleteChildRecoveryDelivery =
        \permit _ version ->
          deleteSlot
            harness
            BootstrapStoreDeleteChildRecoveryDelivery
            permit
            version
            harnessRecoveryDelivery
            setRecoveryDelivery
    , readChildRecoveryJournal =
        \_ -> readSlot "child-recovery-journal" harnessChildRecovery harness
    , createChildRecoveryJournal =
        \permit value ->
          createSlot
            harness
            BootstrapStoreCreateChildRecoveryJournal
            permit
            harnessChildRecovery
            setChildRecovery
            value
    , casChildRecoveryJournal =
        \permit version value ->
          casSlot
            harness
            BootstrapStoreCasChildRecoveryJournal
            permit
            version
            harnessChildRecovery
            setChildRecovery
            value
    , readPostUnsealHandoff =
        \_ -> readSlot "post-unseal-handoff" harnessPostUnseal harness
    , createPostUnsealHandoff =
        \permit value ->
          createSlot
            harness
            BootstrapStoreCreatePostUnsealHandoff
            permit
            harnessPostUnseal
            setPostUnseal
            value
    , casPostUnsealHandoff =
        \permit version value ->
          casSlot
            harness
            BootstrapStoreCasPostUnsealHandoff
            permit
            version
            harnessPostUnseal
            setPostUnseal
            value
    , readSecretWorkerCheckpoint =
        readSlot
          "secret-worker-checkpoint"
          harnessWorkerCheckpoint
          harness
    , createSecretWorkerCheckpoint =
        \permit value ->
          createSlot
            harness
            BootstrapStoreCreateSecretWorkerCheckpoint
            permit
            harnessWorkerCheckpoint
            setWorkerCheckpoint
            value
    , casSecretWorkerCheckpoint =
        \permit version value ->
          casSlot
            harness
            BootstrapStoreCasSecretWorkerCheckpoint
            permit
            version
            harnessWorkerCheckpoint
            setWorkerCheckpoint
            value
    }

setRootJournal
  :: Maybe (Versioned RootInitState) -> HarnessState -> HarnessState
setRootJournal value state = state {harnessRootJournal = value}

setPreparedEnvelope
  :: Maybe (Versioned PreparedInitEnvelope) -> HarnessState -> HarnessState
setPreparedEnvelope value state = state {harnessPreparedEnvelope = value}

setEncryptedResponse
  :: Maybe (Versioned EncryptedInitResponseReceipt)
  -> HarnessState
  -> HarnessState
setEncryptedResponse value state = state {harnessEncryptedResponse = value}

setFinalBundle
  :: Maybe (Versioned FinalUnlockBundle) -> HarnessState -> HarnessState
setFinalBundle value state = state {harnessFinalBundle = value}

setRootSession
  :: Maybe (Versioned RootSessionState) -> HarnessState -> HarnessState
setRootSession value state = state {harnessRootSession = value}

setChildReceipt
  :: Maybe (Versioned ChildEncryptedReceipt) -> HarnessState -> HarnessState
setChildReceipt value state = state {harnessChildReceipt = value}

setChildCustody
  :: Maybe (Versioned ChildCustodyState) -> HarnessState -> HarnessState
setChildCustody value state = state {harnessChildCustody = value}

setRecoveryDelivery
  :: Maybe (Versioned ChildRecoveryDelivery) -> HarnessState -> HarnessState
setRecoveryDelivery value state = state {harnessRecoveryDelivery = value}

setChildRecovery
  :: Maybe (Versioned ChildRecoveryState) -> HarnessState -> HarnessState
setChildRecovery value state = state {harnessChildRecovery = value}

setPostUnseal
  :: Maybe (Versioned PostUnsealHandoffState)
  -> HarnessState
  -> HarnessState
setPostUnseal value state = state {harnessPostUnseal = value}

setWorkerCheckpoint
  :: Maybe (Versioned SecretWorkerDurableCheckpoint)
  -> HarnessState
  -> HarnessState
setWorkerCheckpoint value state = state {harnessWorkerCheckpoint = value}

evidenceBoundary :: Fixture -> Harness -> BrokerProgramEvidenceBoundary IO
evidenceBoundary fixture harness =
  BrokerProgramEvidenceBoundary
    { resolveRootInitializationEvidence =
        \_ -> pure (Right (BeginRootInitialization (fixturePristine fixture)))
    , resolveUnsealRecoveryCustody =
        \_ -> pure (Right (fixtureRecovery fixture))
    , resolveUnlockRotationCustody =
        \_ -> pure (Right (fixtureRecovery fixture))
    , resolveBaselineCustodyAndSession =
        \_ -> do
          state <- readIORef harness
          let invocation = harnessBaselineEvidenceCount state
              sessionId =
                if invocation == 0
                  then fixtureSessionId fixture
                  else fixtureRestartSessionId fixture
          modifyIORef' harness $ \current ->
            current
              { harnessBaselineEvidenceCount =
                  harnessBaselineEvidenceCount current + 1
              }
          pure
            ( Right
                (fixtureRecovery fixture, sessionId)
            )
    , resolveAmbiguousResetEvidence =
        \_ ->
          pure
            ( Right
                (fixtureAmbiguity fixture, fixtureResetProof fixture)
            )
    , resolveChildCustodyBinding =
        \_ -> pure (Right (fixtureChildBinding fixture))
    , resolveChildRecoveryDeliveryEvidence =
        \_ ->
          pure
            ( Right
                ( fixtureChildBinding fixture
                , fixtureDeliveryNonce fixture
                , fixtureChildAttestation fixture
                )
            )
    , resolveChildRecoveryObservation =
        \_ ->
          pure
            ( Right
                (fixtureChildBinding fixture, fixtureDeliveryNonce fixture)
            )
    }

baseEngineBoundary
  :: Fixture -> Harness -> BrokerEngineBoundary IO
baseEngineBoundary fixture harness =
  BrokerEngineBoundary
    { engineEvidenceBoundary = evidenceBoundary fixture harness
    , engineResolveRootInitCryptoParameters = \proof ->
        if proof == fixturePristine fixture
          then pure (Right (rootInitCryptoParameters fixture))
          else pure (Left (EngineBoundaryRefused "init crypto proof mismatch"))
    , engineAdmitCapability = \reference _program -> do
        recordEvent
          harness
          ( CapabilityAdmitted
              (refCapabilityOp reference)
              (refCoordinateDigest reference)
          )
        pure (Right ())
    , engineBeginCapabilityExecution = \reference _program -> do
        recordEvent
          harness
          ( CapabilityBegan
              (refCapabilityOp reference)
              (refCoordinateDigest reference)
          )
        pure (Right ())
    , engineAcquireMutationFence =
        acquireMutationFence harness
    , engineObserveFenceUse = observeFenceUse harness
    , engineReleaseMutationFence = releaseFence harness
    , engineRunPhysicalCall = runPhysicalCall fixture harness
    , engineRunLocalCall = runLocalCall fixture harness
    , engineSecretWorkerBoundary = Just (workerBoundary fixture harness)
    , enginePgpBoundary = Just (pgpBoundary fixture harness)
    , engineInMemoryBoundary = Nothing
    , engineStoreBoundary = physicalStoreBoundary fixture harness
    }

rootInitCryptoParameters :: Fixture -> RootInitCryptoParameters
rootInitCryptoParameters fixture =
  RootInitCryptoParameters
    { rootInitCryptoSchemaVersion =
        preparedInitSchemaVersion (fixturePrepared fixture)
    , rootInitCryptoCompiledBurnRecipient = Settings.compiledBurnRecipient
    , rootInitCryptoShareCount = expectedInitShareCount fixture
    , rootInitCryptoThreshold = expectedInitThreshold fixture
    , rootInitCryptoEnvelopeDigest =
        preparedInitEnvelopeDigest (fixturePrepared fixture)
    }

workerBoundary :: Fixture -> Harness -> BrokerSecretWorkerBoundary IO
workerBoundary fixture harness =
  BrokerSecretWorkerBoundary
    { brokerSecretWorkerDriverBoundary = workerDriverBoundary harness
    , runBrokerSecretWorkerPhysicalCall = \workerPermit running call ->
        finishSecretWorkerExecution
          workerPermit
          ( do
              request <- requireLastWorkerRequest harness
              recordEvent
                harness
                (WorkerExecuted (secretWorkerRequestOperation request))
              result <- runPhysicalCall fixture harness call
              pure ((workerReceiptFor request,) <$> result)
          )
          running
    }

workerDriverBoundary
  :: Harness -> EngineSecretWorkerBoundary IO EngineBoundaryError
workerDriverBoundary harness =
  EngineSecretWorkerBoundary
    { observeSecretWorkerMonotonicNow = pure (Right fixtureNow)
    , allocateSecretWorkerIntent = \operation fence -> do
        let request = workerRequestFor operation fence
        recordEvent harness (WorkerAllocated operation)
        pure (Right (secretWorkerRequestIntent request))
    , createSecretWorkerWorkload = \intent -> do
        let request =
              bindSecretWorkerIntent
                (mustRight (mkWorkerPodUid "physical-pod-created"))
                intent
        modifyIORef' harness $ \state ->
          state {harnessLastWorkerRequest = Just request}
        pure (Right request)
    , observeSecretWorkerAttestation = \request -> do
        recordEvent
          harness
          (WorkerAttested (secretWorkerRequestOperation request))
        pure
          ( Right
              (SecretWorkerAttestationObserved (workerAttestationFor request))
          )
    , discardUnreceiptedSecretWorker = \request _interruption -> do
        recordEvent
          harness
          (WorkerDiscarded (secretWorkerRequestOperation request))
        pure (Right ())
    , discardUnreceiptedSecretWorkerBefore = \_ request interruption ->
        discardUnreceiptedSecretWorker (workerDriverBoundary harness) request interruption
    , observeAuthoritativeRecoveryBefore = \_ action -> Just <$> action
    , withSecretWorkerCheckpointPermit =
        withWorkerCheckpointPermit harness
    , withSecretWorkerCheckpointPermitBefore = \_ ->
        withWorkerCheckpointPermit harness
    , readSecretWorkerCheckpoint =
        readSlot
          "secret-worker-checkpoint"
          harnessWorkerCheckpoint
          harness
    , createSecretWorkerCheckpoint = \permit value ->
        createSlot
          harness
          BootstrapStoreCreateSecretWorkerCheckpoint
          permit
          harnessWorkerCheckpoint
          setWorkerCheckpoint
          value
    , casSecretWorkerCheckpoint = \permit version value ->
        casSlot
          harness
          BootstrapStoreCasSecretWorkerCheckpoint
          permit
          version
          harnessWorkerCheckpoint
          setWorkerCheckpoint
          value
    , revokeSecretWorkerSession = \binding -> do
        recordEvent harness WorkerSessionRevoked
        pure (Right (SecretWorkerSessionRevoked binding))
    , observeSecretWorkerExit = \binding -> do
        recordEvent harness WorkerExited
        pure (Right (SecretWorkerProcessExited binding 0))
    , deleteSecretWorkerPod = \binding -> do
        recordEvent harness WorkerDeleted
        pure (Right (SecretWorkerPodDeleted binding))
    , observeSecretWorkerAbsence = \binding -> do
        recordEvent harness WorkerAbsent
        pure (Right (SecretWorkerPodAbsent binding))
    }

withWorkerCheckpointPermit
  :: Harness
  -> BootstrapSessionFence
  -> BootstrapStoreMutation
  -> (MonotonicInstant -> BootstrapStoreMutationPermit -> IO result)
  -> IO (Either EngineBoundaryError result)
withWorkerCheckpointPermit harness fence mutation continue = do
  observed <- observeFenceUse harness fence
  case observed of
    Left refusal -> pure (Left refusal)
    Right
      EngineFenceUseObservation
        { engineFenceMonotonicNow
        , engineFenceAuthorityClock
        , engineFenceStoreObservation
        , engineFenceLeaseObservation
        } ->
        case authorizeBootstrapStoreMutation
          engineFenceMonotonicNow
          fixtureRequestDeadline
          engineFenceAuthorityClock
          fence
          engineFenceStoreObservation
          engineFenceLeaseObservation
          mutation of
          Left refusal ->
            pure (Left (EngineBoundaryRefused (Text.pack (show refusal))))
          Right permit -> Right <$> continue engineFenceMonotonicNow permit

requireLastWorkerRequest
  :: Harness -> IO SecretFreeWorkerRequest
requireLastWorkerRequest harness = do
  state <- readIORef harness
  case harnessLastWorkerRequest state of
    Just request -> pure request
    Nothing -> throwIO (userError "physical worker ran without allocation")

workerRequestFor
  :: SecretWorkerOperation
  -> BootstrapSessionFence
  -> SecretFreeWorkerRequest
workerRequestFor operation fence =
  mkSecretFreeWorkerRequest
    operation
    (mustRight (mkWorkerPodUid ("physical-pod-" <> suffix)))
    ( mustRight
        (mkWorkerImageDigest ("sha256:" <> Text.replicate 64 "c"))
    )
    (mustRight (mkWorkerServiceAccount "physical-bootstrap-worker"))
    (mustRight (mkWorkerSessionId ("physical-session-" <> suffix)))
    (mustRight (mkWorkerSessionAccessor ("physical-accessor-" <> suffix)))
    fence
 where
  suffix =
    workerOperationLabel operation
      <> "-"
      <> Text.pack
        ( show
            ( bootstrapFenceGenerationValue
                (bootstrapFenceGeneration fence)
            )
        )

workerOperationLabel :: SecretWorkerOperation -> Text
workerOperationLabel operation = case operation of
  SecretWorkerPrepareInitialization -> "prepare-initialization"
  SecretWorkerResumeInitialization -> "resume-initialization"
  SecretWorkerInitialize -> "initialize"
  SecretWorkerFinalizeInitialization -> "finalize-initialization"
  SecretWorkerUnseal -> "unseal"
  SecretWorkerRotateUnlockBundle -> "rotate-unlock"
  SecretWorkerRotateTransitKey -> "rotate-transit"
  SecretWorkerCompleteGeneratedRoot -> "complete-generated-root"

workerAttestationFor
  :: SecretFreeWorkerRequest -> RawSecretWorkerAttestation
workerAttestationFor request =
  RawSecretWorkerAttestation
    { rawWorkerPodUid = secretWorkerRequestPodUid request
    , rawWorkerImageDigest = secretWorkerRequestImageDigest request
    , rawWorkerServiceAccount = secretWorkerRequestServiceAccount request
    , rawWorkerSessionId = secretWorkerRequestSessionId request
    , rawWorkerSessionAccessor = secretWorkerRequestSessionAccessor request
    , rawWorkerOperation = secretWorkerRequestOperation request
    , rawWorkerFenceGeneration = secretWorkerRequestFenceGeneration request
    , rawWorkerOwnerNonce = secretWorkerRequestOwnerNonce request
    , rawWorkerActionDigest = secretWorkerRequestActionDigest request
    , rawWorkerRequestDigest = secretWorkerRequestDigest request
    , rawWorkerStorageGeneration = secretWorkerRequestStorageGeneration request
    , rawWorkerOperationDeadline = secretWorkerRequestOperationDeadline request
    }

workerReceiptFor :: SecretFreeWorkerRequest -> RawSecretWorkerReceipt
workerReceiptFor request =
  RawSecretWorkerReceipt
    { rawWorkerReceiptOperation = secretWorkerRequestOperation request
    , rawWorkerReceiptPodUid = secretWorkerRequestPodUid request
    , rawWorkerReceiptSessionId = secretWorkerRequestSessionId request
    , rawWorkerReceiptSessionAccessor =
        secretWorkerRequestSessionAccessor request
    , rawWorkerReceiptRequestDigest = secretWorkerRequestDigest request
    , rawWorkerReceiptStorageGeneration =
        secretWorkerRequestStorageGeneration request
    , rawWorkerReceiptFenceGeneration =
        secretWorkerRequestFenceGeneration request
    , rawWorkerReceiptOutcome = workerOutcome (secretWorkerRequestOperation request)
    , rawWorkerReceiptDigest = digestOf 'd'
    }

workerOutcome :: SecretWorkerOperation -> SecretWorkerOutcome
workerOutcome operation = case operation of
  SecretWorkerPrepareInitialization -> SecretWorkerInitialized
  SecretWorkerResumeInitialization -> SecretWorkerInitialized
  SecretWorkerInitialize -> SecretWorkerInitialized
  SecretWorkerFinalizeInitialization -> SecretWorkerInitialized
  SecretWorkerUnseal -> SecretWorkerUnsealed
  SecretWorkerRotateUnlockBundle -> SecretWorkerUnlockBundleRotated
  SecretWorkerRotateTransitKey -> SecretWorkerTransitKeyRotated
  SecretWorkerCompleteGeneratedRoot -> SecretWorkerGeneratedRootCompleted

recipientsEnvelope :: Pgp.PreparedInitRecipients -> PreparedInitEnvelope
recipientsEnvelope =
  Pgp.preparedRecoveryEnvelope . Pgp.preparedInitRecoveryRecipient

fixtureSecretPayload :: Request.SecretPayload
fixtureSecretPayload =
  mustRight (Request.mkSecretPayload 4096 "physical-one-shot-password")

pgpResult
  :: Either Pgp.PgpBoundaryError result
  -> IO (Either EngineBoundaryError result)
pgpResult prepared = case prepared of
  Left refusal ->
    pure (Left (EngineBoundaryRefused (Text.pack (show refusal))))
  Right result -> pure (Right result)

pgpBoundary :: Fixture -> Harness -> Pgp.PgpBoundary IO
pgpBoundary fixture harness =
  Pgp.mkPgpBoundary
    (custodyPgpPrimitive fixture harness)
    (rootPgpPrimitive fixture harness)
    (childPgpPrimitive fixture harness)

custodyPgpPrimitive
  :: Fixture -> Harness -> Pgp.PgpCustodyPrimitiveBoundary IO
custodyPgpPrimitive fixture harness =
  Pgp.PgpCustodyPrimitiveBoundary
    { Pgp.primitiveVerifyCompiledBurnRecipient = \compiled -> do
        recordEvent harness (PgpExecuted "verify-compiled-burn")
        if compiled == Settings.compiledBurnRecipient
          then
            pure
              ( Right
                  ( Pgp.burnRecipientPublicKeyBase64
                      ( Pgp.verifiedBurnRecipientPublicKey
                          (fixtureBurnRecipient fixture)
                      )
                  , Pgp.verifiedBurnRecipientFingerprint
                      (fixtureBurnRecipient fixture)
                  )
              )
          else pure (Left Pgp.PgpCompiledBurnRecipientMismatch)
    , Pgp.primitivePrepareRecoveryRecipient =
        \secret proof schema burn shareCount threshold envelopeDigest -> do
          recordEvent harness (PgpExecuted "prepare-recovery-recipient")
          if not (ByteString.null secret)
            && proof == fixturePristine fixture
            && schema == preparedInitSchemaVersion (fixturePrepared fixture)
            && burn == fixtureBurnRecipient fixture
            && shareCount == expectedInitShareCount fixture
            && threshold == expectedInitThreshold fixture
            && envelopeDigest
              == preparedInitEnvelopeDigest (fixturePrepared fixture)
            then
              pure
                ( Right
                    ( fixtureRecoveryPublicKey fixture
                    , preparedInitRecoveryFingerprint (fixturePrepared fixture)
                    , fixturePrepared fixture
                    )
                )
            else pure (Left Pgp.PgpPreparedRecoveryRecipientMismatch)
    , Pgp.primitiveResumePreparedInitRecipients =
        \secret prepared burn -> do
          recordEvent harness (PgpExecuted "resume-recovery-recipient")
          if not (ByteString.null secret)
            && prepared == fixturePrepared fixture
            && burn == fixtureBurnRecipient fixture
            then
              pure
                ( Right
                    ( fixtureRecoveryPublicKey fixture
                    , preparedInitRecoveryFingerprint prepared
                    )
                )
            else pure (Left Pgp.PgpPreparedRecoveryRecipientMismatch)
    , Pgp.primitiveDecryptRecoveryShares =
        \secret recipients response -> do
          recordEvent harness (PgpExecuted "decrypt-recovery-shares")
          if not (ByteString.null secret)
            && Pgp.preparedRecoveryEnvelope
              (Pgp.preparedInitRecoveryRecipient recipients)
              == fixturePrepared fixture
            && response == fixtureEncryptedResponse fixture
            then pure (Right ["recovered-share"])
            else pure (Left Pgp.PgpEncryptedShareRejected)
    , Pgp.primitiveSealFinalUnlockPayload = \secret payload -> do
        recordEvent harness (PgpExecuted "seal-final-unlock-payload")
        if not (ByteString.null secret)
          && payload == fixtureFinalPayload fixture
          then pure (Right "sealed-unlock-bundle")
          else pure (Left Pgp.PgpPasswordAeadFailed)
    }

rootPgpPrimitive
  :: Fixture -> Harness -> Pgp.GeneratedRootPrimitiveBoundary IO
rootPgpPrimitive fixture harness =
  Pgp.mkGeneratedRootPrimitiveBoundary $ \consume -> do
    scopeNumber <- nextRootScope harness
    let encodedPublicKey = scopePublicKey "root-public" scopeNumber
    recordEvent
      harness
      (PgpExecuted ("root-scope-open:" <> encodedPublicKey))
    result <-
      consume
        encodedPublicKey
        (runRootScopedSession fixture harness scopeNumber)
    recordEvent harness (PgpExecuted "root-scope-closed")
    pure result

childPgpPrimitive
  :: Fixture
  -> Harness
  -> Pgp.GeneratedChildRecoveryPrimitiveBoundary IO
childPgpPrimitive fixture harness =
  Pgp.mkGeneratedChildRecoveryPrimitiveBoundary $ \consume -> do
    scopeNumber <- nextChildScope harness
    let encodedPublicKey = scopePublicKey "child-public" scopeNumber
    recordEvent
      harness
      (PgpExecuted ("child-scope-open:" <> encodedPublicKey))
    result <-
      consume
        encodedPublicKey
        (runChildScopedSession fixture harness scopeNumber)
    recordEvent harness (PgpExecuted "child-scope-closed")
    pure result

runRootScopedSession
  :: Fixture
  -> Harness
  -> Natural
  -> ByteString
  -> ( (forall result. Pgp.GeneratedRootAction result -> IO (Either Pgp.PgpBoundaryError result))
       -> IO (Either Pgp.PgpBoundaryError sessionResult)
     )
  -> IO (Either Pgp.PgpBoundaryError sessionResult)
runRootScopedSession fixture harness scopeNumber ciphertext useRunner = do
  decrypted <- decryptRootScope harness scopeNumber ciphertext
  case decrypted of
    Left refusal -> pure (Left refusal)
    Right token ->
      bracket
        (pure token)
        (closeRootToken harness)
        (\liveToken -> useRunner (runRootPgpAction fixture harness liveToken))

runChildScopedSession
  :: Fixture
  -> Harness
  -> Natural
  -> ByteString
  -> ( ( forall result
          . Pgp.GeneratedChildRecoveryAction result
         -> IO (Either Pgp.PgpBoundaryError result)
       )
       -> IO (Either Pgp.PgpBoundaryError sessionResult)
     )
  -> IO (Either Pgp.PgpBoundaryError sessionResult)
runChildScopedSession fixture harness scopeNumber ciphertext useRunner = do
  decrypted <- decryptChildScope harness scopeNumber ciphertext
  case decrypted of
    Left refusal -> pure (Left refusal)
    Right token ->
      bracket
        (pure token)
        (closeChildToken harness)
        (\liveToken -> useRunner (runChildPgpAction fixture harness liveToken))

closeRootToken :: Harness -> ByteString -> IO ()
closeRootToken harness token =
  modifyIORef' harness $ \current ->
    current
      { harnessRevokedRootTokens =
          appendUnique token (harnessRevokedRootTokens current)
      }

closeChildToken :: Harness -> ByteString -> IO ()
closeChildToken harness token =
  modifyIORef' harness $ \current ->
    current
      { harnessRevokedChildTokens =
          appendUnique token (harnessRevokedChildTokens current)
      }

appendUnique :: (Eq value) => value -> [value] -> [value]
appendUnique value values
  | value `elem` values = values
  | otherwise = values ++ [value]

nextRootScope :: Harness -> IO Natural
nextRootScope harness = do
  state <- readIORef harness
  let next = harnessRootScopeCounter state + 1
  modifyIORef' harness $ \current ->
    current {harnessRootScopeCounter = next}
  pure next

nextChildScope :: Harness -> IO Natural
nextChildScope harness = do
  state <- readIORef harness
  let next = harnessChildScopeCounter state + 1
  modifyIORef' harness $ \current ->
    current {harnessChildScopeCounter = next}
  pure next

scopePublicKey :: Text -> Natural -> Text
scopePublicKey label scopeNumber =
  TextEncoding.decodeUtf8
    ( Base64.encode
        ( TextEncoding.encodeUtf8
            (label <> "-" <> Text.pack (show scopeNumber))
        )
    )

decryptRootScope
  :: Harness
  -> Natural
  -> ByteString
  -> IO (Either Pgp.PgpBoundaryError ByteString)
decryptRootScope harness scopeNumber ciphertext
  | ciphertext /= "encrypted-root-token" =
      pure (Left Pgp.PgpGeneratedRootCiphertextRejected)
  | otherwise = do
      let token =
            TextEncoding.encodeUtf8
              ("root-token-" <> Text.pack (show scopeNumber))
      state <- readIORef harness
      if token `elem` harnessIssuedRootTokens state
        then pure (Left Pgp.PgpGeneratedRootSessionClosed)
        else do
          modifyIORef' harness $ \current ->
            current
              { harnessIssuedRootTokens =
                  harnessIssuedRootTokens current ++ [token]
              }
          recordEvent harness (PgpExecuted "root-ciphertext-decrypted")
          pure (Right token)

decryptChildScope
  :: Harness
  -> Natural
  -> ByteString
  -> IO (Either Pgp.PgpBoundaryError ByteString)
decryptChildScope harness scopeNumber ciphertext
  | ciphertext /= "encrypted-child-root-token" =
      pure (Left Pgp.PgpGeneratedChildRecoveryCiphertextRejected)
  | otherwise = do
      let token =
            TextEncoding.encodeUtf8
              ("child-token-" <> Text.pack (show scopeNumber))
      state <- readIORef harness
      if token `elem` harnessIssuedChildTokens state
        then pure (Left Pgp.PgpGeneratedChildRecoverySessionClosed)
        else do
          modifyIORef' harness $ \current ->
            current
              { harnessIssuedChildTokens =
                  harnessIssuedChildTokens current ++ [token]
              }
          recordEvent harness (PgpExecuted "child-ciphertext-decrypted")
          pure (Right token)

runRootPgpAction
  :: Fixture
  -> Harness
  -> ByteString
  -> Pgp.GeneratedRootAction result
  -> IO (Either Pgp.PgpBoundaryError result)
runRootPgpAction fixture harness token action = do
  state <- readIORef harness
  if token `notElem` harnessIssuedRootTokens state
    || token `elem` harnessRevokedRootTokens state
    then pure (Left Pgp.PgpGeneratedRootSessionClosed)
    else case action of
      Pgp.GeneratedRootObserveAccessor binding permit ->
        rootAction binding permit BootstrapVaultObserveGeneratedRootAccessor "root-action-observe" $ do
          addRootAccessor harness (fixtureCurrentAccessor fixture)
          pure (Right (fixtureCurrentAccessor fixture))
      Pgp.GeneratedRootApplyAllowlistedBaseline binding permit accessor ->
        rootAction binding permit BootstrapVaultApplyBaseline "root-action-apply" $ do
          if accessor == fixtureCurrentAccessor fixture
            then pure (Right ())
            else pure (Left Pgp.PgpGeneratedRootActionBindingMismatch)
      Pgp.GeneratedRootReadBackAllowlistedBaseline binding permit accessor ->
        rootAction binding permit BootstrapVaultReadBackBaseline "root-action-read-back" $ do
          if accessor == fixtureCurrentAccessor fixture
            then do
              let receipt = baselineReceiptFor fixture binding
              modifyIORef' harness $ \current ->
                current {harnessLastBaselineReceipt = Just receipt}
              pure (Right receipt)
            else pure (Left Pgp.PgpGeneratedRootActionBindingMismatch)
      Pgp.GeneratedRootRevokeAccessor binding permit accessor ->
        rootAction binding permit BootstrapVaultRevokeRootAccessor "root-action-revoke" $ do
          if accessor /= fixtureCurrentAccessor fixture
            then pure (Left Pgp.PgpGeneratedRootActionBindingMismatch)
            else do
              removeRootAccessor harness accessor
              addRootAccessor harness (fixtureStaleAccessor fixture)
              modifyIORef' harness $ \current ->
                current
                  { harnessRevokedRootTokens =
                      appendUnique token (harnessRevokedRootTokens current)
                  }
              pure (Right ())
 where
  rootAction binding permit effect label physical
    | rootSessionStorageGeneration binding
        /= rootInitStorageGeneration
          (recoveryCustodyBinding (fixtureRecovery fixture)) =
        pure (Left Pgp.PgpGeneratedRootActionBindingMismatch)
    | otherwise = do
        recordEvent
          harness
          ( PgpExecuted
              ( label
                  <> ":"
                  <> renderRootSessionId (rootSessionBindingId binding)
              )
          )
        -- Keep a stable short label for crash predicates and ordered checks.
        recordEvent harness (PgpExecuted label)
        authorized <- authorizePhysicalMutation harness effect permit
        if authorized
          then physical
          else
            pure
              ( Left
                  ( Pgp.PgpGeneratedRootActionRefused
                      (Pgp.generatedRootActionKind action)
                      (rootActionFailureStage action)
                  )
              )
  rootActionFailureStage
    :: Pgp.GeneratedRootAction actionResult
    -> Pgp.GeneratedRootActionFailureStage
  rootActionFailureStage current = case current of
    Pgp.GeneratedRootObserveAccessor {} -> Pgp.GeneratedRootObserveAccessorRequest
    Pgp.GeneratedRootApplyAllowlistedBaseline {} ->
      Pgp.GeneratedRootApplyCoreReconcile
        Pgp.GeneratedRootCoreMountTypeMismatch
    Pgp.GeneratedRootReadBackAllowlistedBaseline {} ->
      Pgp.GeneratedRootReadBackCoreReconcile
        Pgp.GeneratedRootCoreMountTypeMismatch
    Pgp.GeneratedRootRevokeAccessor {} -> Pgp.GeneratedRootRevokeAccessorRequest

runChildPgpAction
  :: Fixture
  -> Harness
  -> ByteString
  -> Pgp.GeneratedChildRecoveryAction result
  -> IO (Either Pgp.PgpBoundaryError result)
runChildPgpAction fixture harness token action = do
  state <- readIORef harness
  if token `notElem` harnessIssuedChildTokens state
    || token `elem` harnessRevokedChildTokens state
    then pure (Left Pgp.PgpGeneratedChildRecoverySessionClosed)
    else case action of
      Pgp.GeneratedChildRecoveryObserveAccessor delivery permit ->
        childAction delivery permit BootstrapVaultObserveGeneratedRootAccessor "child-action-observe" $ do
          addRootAccessor harness (fixtureCurrentAccessor fixture)
          pure (Right (fixtureCurrentAccessor fixture))
      Pgp.GeneratedChildRecoveryApplyAllowlistedRepair delivery permit accessor ->
        childAction delivery permit BootstrapVaultApplyBaseline "child-action-apply" $ do
          if accessor == fixtureCurrentAccessor fixture
            then pure (Right ())
            else pure (Left Pgp.PgpGeneratedChildRecoveryActionBindingMismatch)
      Pgp.GeneratedChildRecoveryReadBackAllowlistedRepair delivery permit accessor ->
        childAction delivery permit BootstrapVaultReadBackBaseline "child-action-read-back" $ do
          if accessor == fixtureCurrentAccessor fixture
            then pure (Right (fixtureChildRepairReceipt fixture))
            else pure (Left Pgp.PgpGeneratedChildRecoveryActionBindingMismatch)
      Pgp.GeneratedChildRecoveryRevokeAccessor delivery permit accessor ->
        childAction delivery permit BootstrapVaultRevokeRootAccessor "child-action-revoke" $ do
          if accessor /= fixtureCurrentAccessor fixture
            then pure (Left Pgp.PgpGeneratedChildRecoveryActionBindingMismatch)
            else do
              removeRootAccessor harness accessor
              modifyIORef' harness $ \current ->
                current
                  { harnessRevokedChildTokens =
                      appendUnique token (harnessRevokedChildTokens current)
                  }
              pure (Right ())
 where
  childAction delivery permit effect label physical
    | delivery /= fixtureChildDelivery fixture =
        pure (Left Pgp.PgpGeneratedChildRecoveryActionBindingMismatch)
    | otherwise = do
        recordEvent harness (PgpExecuted label)
        authorized <- authorizePhysicalMutation harness effect permit
        if authorized
          then physical
          else pure (Left Pgp.PgpGeneratedChildRecoveryActionBindingMismatch)

expectedInitShareCount :: Fixture -> Natural
expectedInitShareCount =
  initRecipientShareCount
    . preparedInitRecipientCommitment
    . fixturePrepared

expectedInitThreshold :: Fixture -> Natural
expectedInitThreshold =
  initRecipientThreshold
    . preparedInitRecipientCommitment
    . fixturePrepared

fixtureRecoveryPublicKey :: Fixture -> Text
fixtureRecoveryPublicKey fixture =
  case initRecipientRecoveryPublicKeysBase64
    (preparedInitRecipientCommitment (fixturePrepared fixture)) of
    [publicKey] -> publicKey
    _ -> error "physical fixture expected exactly one recovery recipient"

fixtureFinalPayload :: Fixture -> FinalUnlockBundlePayload
fixtureFinalPayload fixture =
  mustRight
    ( mkFinalUnlockBundlePayload
        (fixtureEncryptedResponse fixture)
        [mustRight (mkRecoveredUnsealShare "recovered-share")]
    )

baselineReceiptFor
  :: Fixture -> RootSessionBinding -> BaselineReadBackReceipt
baselineReceiptFor fixture binding =
  mustRight
    ( mkBaselineReadBackReceipt
        (rootSessionBindingId binding)
        (rootSessionStorageGeneration binding)
        requiredRootBaselineTargets
        (recoveryCustodyFinalBundleDigest (fixtureRecovery fixture))
    )

acquireMutationFence
  :: Harness
  -> capabilityReference
  -> BrokerRoute
  -> BrokerActionRequest
  -> Request.RequestDigest
  -> Deadline
  -> IO (Either EngineBoundaryError BootstrapSessionFence)
acquireMutationFence harness _reference _route action requestDigest deadline = do
  state <- readIORef harness
  case harnessHeldFence state of
    Just held
      | fenceMatchesRequest (harnessFenceOwnerNonce state) action requestDigest deadline held -> do
          recordEvent
            harness
            ( FenceResumed
                (bootstrapFenceGenerationValue (bootstrapFenceGeneration held))
            )
          pure (Right held)
      | otherwise ->
          pure (Left (EngineBoundaryRefused "overlapping physical fixture fence"))
    Nothing -> do
      let nextGeneration = harnessFenceFloor state + 1
          constructed =
            reloadBootstrapSessionFence
              nextGeneration
              (harnessFenceOwnerNonce state)
              (brokerActionDigest action)
              requestDigest
              (brokerActionStorageGeneration action)
              (deadlineMicros deadline)
      case constructed of
        Left refusal ->
          pure (Left (EngineBoundaryRefused (Text.pack (show refusal))))
        Right fence -> do
          modifyIORef' harness $ \current ->
            current {harnessHeldFence = Just fence}
          recordEvent harness (FenceAcquired nextGeneration)
          pure (Right fence)

fenceMatchesRequest
  :: OwnerNonce
  -> BrokerActionRequest
  -> Request.RequestDigest
  -> Deadline
  -> BootstrapSessionFence
  -> Bool
fenceMatchesRequest owner action requestDigest deadline fence =
  bootstrapFenceOwnerNonce fence == owner
    && bootstrapFenceActionDigest fence == brokerActionDigest action
    && bootstrapFenceRequestDigest fence == requestDigest
    && bootstrapFenceStorageGeneration fence
      == brokerActionStorageGeneration action
    && operationDeadlineMicros (bootstrapFenceOperationDeadline fence)
      == deadlineMicros deadline

observeFenceUse
  :: Harness
  -> BootstrapSessionFence
  -> IO (Either EngineBoundaryError EngineFenceUseObservation)
observeFenceUse harness expected = do
  recordEvent harness FenceObserved
  state <- readIORef harness
  pure $ case harnessHeldFence state of
    Just held
      | held == expected ->
          Right
            EngineFenceUseObservation
              { engineFenceMonotonicNow = fixtureNow
              , engineFenceAuthorityClock = fixtureAuthorityClock
              , engineFenceStoreObservation = BootstrapFenceStoreHeld held
              , engineFenceLeaseObservation =
                  if harnessLeaseAvailable state
                    then fixtureLease held
                    else BootstrapLeaseMissing
              }
    _ -> Left (EngineBoundaryRefused "physical fixture fence is not held")

releaseFence
  :: Harness
  -> BootstrapStoreMutationPermit
  -> BootstrapSessionFence
  -> IO (Either EngineBoundaryError BootstrapFenceStoreObservation)
releaseFence harness permit expected = do
  state <- readIORef harness
  let valid =
        storeMutationPermitMutation permit
          == BootstrapStoreReleaseSessionFence
          && harnessHeldFence state == Just expected
          && storePermitMatchesFence permit expected
      floorValue =
        bootstrapFenceGenerationValue (bootstrapFenceGeneration expected)
  if valid
    then do
      modifyIORef' harness $ \current ->
        current
          { harnessFenceFloor = floorValue
          , harnessHeldFence = Nothing
          , harnessStoreMutationCount =
              harnessStoreMutationCount current + 1
          }
      recordEvent harness (StoreMutated BootstrapStoreReleaseSessionFence)
      recordEvent harness (FenceReleased floorValue)
      pure (Right (BootstrapFenceStoreVacant floorValue))
    else do
      recordPermitViolation harness "release permit mismatch"
      pure (Left (EngineBoundaryRefused "physical fixture release mismatch"))

runPhysicalCall
  :: Fixture
  -> Harness
  -> BrokerPhysicalCall operation result
  -> IO (Either EngineBoundaryError result)
runPhysicalCall fixture harness call = case call of
  PhysicalHealth _ -> observe "health" True
  PhysicalReadiness _ -> observe "readiness" BrokerReadinessReady
  PhysicalObserveVaultStatus _ ->
    observe
      "vault-status"
      BootstrapStatus
        { bootstrapStatusStorageGeneration =
            rootInitStorageGeneration
              (recoveryCustodyBinding (fixtureRecovery fixture))
        , bootstrapStatusInitialized = True
        , bootstrapStatusSealed = False
        , bootstrapStatusRecoveryCustodyDurable = True
        , bootstrapStatusInitializationAmbiguous = False
        , bootstrapStatusInitializationPhase = Just InitCustodyDurable
        , bootstrapStatusInitializationResetFromGeneration = Nothing
        , bootstrapStatusInitializationResetActionDigest = Nothing
        , bootstrapStatusRootSessionActive = False
        , bootstrapStatusHandoffObserved = True
        }
  PhysicalPrepareRootInitRecipients _ permit proof parameters ->
    mutate permit BootstrapVaultInitialize $ do
      verified <-
        Pgp.verifyCompiledBurnRecipient
          (pgpBoundary fixture harness)
          (rootInitCryptoCompiledBurnRecipient parameters)
      case verified of
        Left refusal -> pgpRefused refusal
        Right burnRecipient -> do
          prepared <-
            Pgp.prepareRecoveryRecipient
              (pgpBoundary fixture harness)
              fixtureSecretPayload
              proof
              (rootInitCryptoSchemaVersion parameters)
              burnRecipient
              (rootInitCryptoShareCount parameters)
              (rootInitCryptoThreshold parameters)
              (rootInitCryptoEnvelopeDigest parameters)
          pgpResult prepared
  PhysicalResumeRootInitRecipients _ permit prepared compiledBurn ->
    mutate permit BootstrapVaultInitialize $ do
      verified <-
        Pgp.verifyCompiledBurnRecipient
          (pgpBoundary fixture harness)
          compiledBurn
      case verified of
        Left refusal -> pgpRefused refusal
        Right burnRecipient -> do
          resumed <-
            Pgp.resumePreparedInitRecipients
              (pgpBoundary fixture harness)
              fixtureSecretPayload
              prepared
              burnRecipient
          pgpResult resumed
  PhysicalInitializeVault _ permit recipients ->
    mutate permit BootstrapVaultInitialize $ do
      if recipientsEnvelope recipients /= fixturePrepared fixture
        then refused "prepared init recipients mismatch"
        else do
          recordEvent
            harness
            ( InitRecipientsObserved
                (Pgp.preparedInitRecoveryPublicKeysBase64 recipients)
                (Pgp.preparedInitBurnPublicKeyBase64 recipients)
                (Pgp.preparedInitRecipientShareCount recipients)
                (Pgp.preparedInitRecipientThreshold recipients)
            )
          state <- readIORef harness
          recordEvent harness InitVaultEffectApplied
          if harnessCrashPoint state
            == CrashAfterInitEffectBeforeWorkerReceipt
            && not (harnessCrashTriggered state)
            then do
              modifyIORef' harness $ \current ->
                current {harnessCrashTriggered = True}
              refused "init effect response lost before worker result CAS"
            else pure . Right $ case harnessInitMode state of
              ReturnEncryptedInitResponse ->
                RootInitEncryptedResponse (fixtureEncryptedResponse fixture)
              ReturnAppliedWithoutResponse ->
                RootInitAppliedWithoutResponse InitializationCauseUnclassified
              ReturnClassifiedAppliedWithoutResponse cause ->
                RootInitAppliedWithoutResponse cause
  PhysicalSealFinalUnlockBundle _ permit recipients response ->
    mutate permit BootstrapVaultInitialize $ do
      if recipientsEnvelope recipients /= fixturePrepared fixture
        || response /= fixtureEncryptedResponse fixture
        then refused "final bundle input mismatch"
        else do
          decrypted <-
            Pgp.decryptRecoveryShares
              (pgpBoundary fixture harness)
              fixtureSecretPayload
              recipients
              response
          case decrypted of
            Left refusal -> pgpRefused refusal
            Right shares -> case mkFinalUnlockBundlePayload response shares of
              Left refusal -> refused (Text.pack (show refusal))
              Right payload -> do
                sealed <-
                  Pgp.sealFinalUnlockPayload
                    (pgpBoundary fixture harness)
                    fixtureSecretPayload
                    payload
                case sealed of
                  Left refusal -> pgpRefused refusal
                  Right (ciphertext, digestValue) ->
                    pure (Right (mkFinalUnlockBundle payload ciphertext digestValue))
  PhysicalUnsealVault _ permit custody ->
    mutate permit BootstrapVaultSubmitUnsealShare $ do
      if custody == fixtureRecovery fixture
        then pure (Right (mutationReceipt permit))
        else refused "unseal custody mismatch"
  PhysicalSealVault _ permit ->
    mutate permit BootstrapVaultSeal (pure (Right (mutationReceipt permit)))
  PhysicalRotateUnlockBundle _ permit custody ->
    mutate permit BootstrapVaultRotateUnlockBundle $ do
      if custody == fixtureRecovery fixture
        then pure (Right (mutationReceipt permit))
        else refused "unlock rotation custody mismatch"
  PhysicalRotateTransitKey _ permit ->
    mutate
      permit
      BootstrapVaultRotateTransitKey
      (pure (Right (mutationReceipt permit)))
  PhysicalResetAmbiguousInitialization _ permit ambiguity proof ->
    mutate permit BootstrapVaultResetAmbiguousInitialization $ do
      if ambiguity == fixtureAmbiguity fixture
        && proof == fixtureResetProof fixture
        then do
          state <- readIORef harness
          let confirmedProof =
                fromMaybe proof (harnessResetProofOverride state)
          pure (Right confirmedProof)
        else refused "ambiguous reset evidence mismatch"
  PhysicalCancelIncompleteGenerateRoot _ permit _ ->
    mutate permit BootstrapVaultCancelGenerateRoot (pure (Right ()))
  PhysicalInventoryRootAccessors _ permit generation ->
    mutate permit BootstrapVaultInventoryRootAccessors $ do
      state <- readIORef harness
      case mkRootAccessorInventory generation (harnessLiveRootAccessors state) of
        Left refusal -> refused (Text.pack (show refusal))
        Right inventory -> pure (Right inventory)
  PhysicalRevokeRootAccessor _ permit accessor ->
    mutate permit BootstrapVaultRevokeRootAccessor $ do
      removeRootAccessor harness accessor
      pure (Right ())
  PhysicalProveRootAccessorsAbsent _ permit requirement inventory ->
    mutate permit BootstrapVaultInventoryRootAccessors $ do
      proveAccessorTargetsAbsent
        harness
        ( rootInitStorageGeneration
            (recoveryCustodyBinding (fixtureRecovery fixture))
        )
        requirement
        inventory
        (digestOf 'a')
  PhysicalStartGenerateRoot _ permit binding publicKey ->
    mutate permit BootstrapVaultStartGenerateRoot $ do
      recordEvent
        harness
        ( PgpExecuted
            ( "root-physical-key:"
                <> Pgp.generatedRootPublicKeyBase64 publicKey
            )
        )
      if rootSessionStorageGeneration binding
        == rootInitStorageGeneration
          (recoveryCustodyBinding (fixtureRecovery fixture))
        then pure (Right ())
        else refused "generated-root start binding mismatch"
  PhysicalAwaitGeneratedRootCiphertext _ permit binding ->
    mutate permit BootstrapVaultSubmitGenerateRootShare $ do
      if rootSessionStorageGeneration binding
        == rootInitStorageGeneration
          (recoveryCustodyBinding (fixtureRecovery fixture))
        then pure (Right fixtureGeneratedRootCiphertext)
        else refused "generated-root ciphertext binding mismatch"
  PhysicalCleanupProvisionerSessions _ permit generation ->
    mutate permit BootstrapVaultInventoryProvisionerAccessors $ do
      state <- readIORef harness
      case mkProvisionerAccessorInventory
        generation
        (harnessLiveProvisionerAccessors state) of
        Left refusal -> refused (Text.pack (show refusal))
        Right inventory -> do
          modifyIORef' harness $ \current ->
            current {harnessLiveProvisionerAccessors = []}
          pure
            ( Right
                (mkProvisionerAccessorAbsenceAttestation inventory (digestOf 'a'))
            )
  PhysicalLoginProvisioner _ permit generation ->
    mutate permit BootstrapVaultLoginProvisioner $ do
      if generation
        == rootInitStorageGeneration
          (recoveryCustodyBinding (fixtureRecovery fixture))
        then do
          modifyIORef' harness $ \state ->
            state
              { harnessLiveProvisionerAccessors =
                  [provisionerLoginAccessor (fixtureProvisionerReceipt fixture)]
              }
          state <- readIORef harness
          if not (harnessCrashTriggered state)
            then case harnessCrashPoint state of
              CrashAfterProvisionerLoginResponseLoss -> do
                markCrashTriggered harness
                unavailable "provisioner login response lost"
              CrashAfterProvisionerLoginException -> do
                markCrashTriggered harness
                throwIO (userError "provisioner login fixture exception")
              CrashAfterProvisionerLoginCancellation -> do
                markCrashTriggered harness
                throwIO ThreadKilled
              _ -> pure (Right (fixtureProvisionerReceipt fixture))
            else pure (Right (fixtureProvisionerReceipt fixture))
        else refused "provisioner login generation mismatch"
  PhysicalApplyProvisionerBaseline _ permit receipt ->
    mutate permit BootstrapVaultApplyBaseline $ do
      if receipt == fixtureProvisionerReceipt fixture
        then pure (Right ())
        else refused "provisioner apply receipt mismatch"
  PhysicalReadBackProvisionerBaseline _ permit receipt _ ->
    mutate permit BootstrapVaultReadBackBaseline $ do
      state <- readIORef harness
      if receipt /= fixtureProvisionerReceipt fixture
        then refused "provisioner read-back receipt mismatch"
        else case harnessLastBaselineReceipt state of
          Just baseline -> pure (Right baseline)
          Nothing -> refused "provisioner read-back preceded root baseline"
  PhysicalRevokeProvisionerSession _ permit receipt ->
    mutate permit BootstrapVaultRevokeProvisionerAccessor $ do
      if receipt /= fixtureProvisionerReceipt fixture
        then refused "provisioner revocation receipt mismatch"
        else do
          modifyIORef' harness $ \state ->
            state
              { harnessLiveProvisionerAccessors =
                  filter
                    (/= provisionerLoginAccessor receipt)
                    (harnessLiveProvisionerAccessors state)
              }
          pure (Right ())
  PhysicalProveProvisionerSessionAbsent _ permit receipt ->
    mutate permit BootstrapVaultInventoryProvisionerAccessors $ do
      state <- readIORef harness
      if receipt /= fixtureProvisionerReceipt fixture
        || provisionerLoginAccessor receipt
          `elem` harnessLiveProvisionerAccessors state
        then refused "provisioner accessor remains present"
        else case mkProvisionerAccessorInventory
          (provisionerLoginStorageGeneration receipt)
          [provisionerLoginAccessor receipt] of
          Left refusal -> refused (Text.pack (show refusal))
          Right inventory ->
            pure
              ( Right
                  (mkProvisionerAccessorAbsenceAttestation inventory (digestOf 'b'))
              )
  PhysicalObservePostUnsealConsumer _ binding consumer ->
    if binding == recoveryCustodyBinding (fixtureRecovery fixture)
      && consumer == PostUnsealLifecycleAuthority
      then observe "post-unseal-consumer" (Just (fixtureHandoffReceipt fixture))
      else refused "post-unseal binding mismatch"
  PhysicalObserveVaultPkiStatus _ ->
    observe "pki-status" VaultPkiBaselineReady
  PhysicalIssueVaultPkiTestCertificate _ permit _ ->
    mutate
      permit
      BootstrapVaultIssueTestCertificate
      (pure (Right (mutationReceipt permit)))
  PhysicalObserveChildRecoveryConsumption _ permit delivery ->
    observeWithPermit permit BootstrapVaultConsumeChildRecovery $ do
      observeChildRecoveryConsumption fixture harness delivery
  PhysicalConsumeChildRecovery _ permit delivery ->
    mutate permit BootstrapVaultConsumeChildRecovery $ do
      checked <- requireDelivery fixture delivery
      case checked of
        Left failure -> pure (Left failure)
        Right () -> do
          state <- readIORef harness
          case harnessConsumedRecoveryDelivery state of
            Just consumed
              | consumed /= delivery ->
                  refused "child recovery consumption key conflict"
            _ -> do
              modifyIORef' harness $ \current ->
                current {harnessConsumedRecoveryDelivery = Just delivery}
              if harnessCrashPoint state == CrashAfterChildConsumeEffect
                && not (harnessCrashTriggered state)
                then do
                  modifyIORef' harness $ \current ->
                    current {harnessCrashTriggered = True}
                  unavailable "child recovery consume response lost"
                else
                  pure
                    ( Right
                        ( mkChildRecoveryConsumptionObservation
                            delivery
                            ChildRecoveryConsumptionApplied
                            (digestOf 'd')
                        )
                    )
  PhysicalCancelChildIncompleteGenerateRoot _ permit delivery ->
    mutate permit BootstrapVaultCancelGenerateRoot $ do
      requireDelivery fixture delivery
  PhysicalInventoryChildRootAccessors _ permit binding ->
    mutate permit BootstrapVaultInventoryRootAccessors $ do
      if binding /= fixtureChildBinding fixture
        then refused "child inventory binding mismatch"
        else do
          state <- readIORef harness
          case mkRootAccessorInventory
            (childCustodyStorageGeneration binding)
            (harnessLiveRootAccessors state) of
            Left refusal -> refused (Text.pack (show refusal))
            Right inventory -> pure (Right inventory)
  PhysicalRevokeChildRootAccessor _ permit accessor ->
    mutate permit BootstrapVaultRevokeRootAccessor $ do
      removeRootAccessor harness accessor
      pure (Right ())
  PhysicalProveChildRootAccessorsAbsent _ permit requirement inventory ->
    mutate permit BootstrapVaultInventoryRootAccessors $ do
      proveAccessorTargetsAbsent
        harness
        (childCustodyStorageGeneration (fixtureChildBinding fixture))
        requirement
        inventory
        (digestOf 'b')
  PhysicalStartChildGenerateRoot _ permit delivery publicKey ->
    mutate permit BootstrapVaultStartGenerateRoot $ do
      checked <- requireDelivery fixture delivery
      recordEvent
        harness
        ( PgpExecuted
            ( "child-physical-key:"
                <> Pgp.generatedChildRecoveryPublicKeyBase64 publicKey
            )
        )
      pure (void checked)
  PhysicalAwaitChildGeneratedRootCiphertext _ permit delivery ->
    mutate permit BootstrapVaultSubmitGenerateRootShare $ do
      checked <- requireDelivery fixture delivery
      pure (fixtureGeneratedChildCiphertext <$ checked)
 where
  observe
    :: Text -> value -> IO (Either EngineBoundaryError value)
  observe label value = do
    recordEvent harness (PhysicalObserved label)
    pure (Right value)

  mutate
    :: BootstrapVaultEffectPermit
    -> BootstrapVaultEffect
    -> IO (Either EngineBoundaryError value)
    -> IO (Either EngineBoundaryError value)
  mutate permit expected action = do
    authorized <- authorizePhysicalMutation harness expected permit
    if authorized
      then action
      else refused "physical permit mismatch"

  observeWithPermit permit expected action = do
    authorized <- authorizePhysicalObservation harness expected permit
    if authorized
      then action
      else refused "physical observation permit mismatch"

  refused :: Text -> IO (Either EngineBoundaryError value)
  refused = pure . Left . EngineBoundaryRefused

  unavailable :: Text -> IO (Either EngineBoundaryError value)
  unavailable = pure . Left . EngineBoundaryUnavailable

  pgpRefused :: Pgp.PgpBoundaryError -> IO (Either EngineBoundaryError value)
  pgpRefused = refused . Text.pack . show

proveAccessorTargetsAbsent
  :: Harness
  -> VaultStorageGeneration
  -> RootAccessorAbsenceProofRequirement
  -> RootAccessorInventory
  -> ArtifactDigest
  -> IO (Either EngineBoundaryError AccessorAbsenceAttestation)
proveAccessorTargetsAbsent harness expectedGeneration requirement proofTarget digestValue = do
  state <- readIORef harness
  if not (harnessAccessorObservationAvailable state)
    then unavailable "accessor-absence inventory unavailable"
    else case mkRootAccessorInventory expectedGeneration (harnessLiveRootAccessors state) of
      Left _ -> refused "accessor-absence inventory invalid"
      Right current ->
        case decideRootAccessorAbsenceProof requirement proofTarget current of
          Right () -> pure (Right (mkAccessorAbsenceAttestation proofTarget digestValue))
          Left RootAccessorAbsenceGenerationMismatch ->
            refused "accessor-absence generation mismatch"
          Left RootAccessorAbsenceTargetPresent ->
            refused "accessor-absence target is still present"
          Left RootAccessorAbsenceStableZeroMismatch ->
            refused "accessor-absence stable zero mismatch"
          Left _ -> refused "accessor-absence proof refused"
 where
  unavailable = pure . Left . EngineBoundaryUnavailable
  refused = pure . Left . EngineBoundaryRefused

runLocalCall
  :: Fixture
  -> Harness
  -> BrokerLocalCall result
  -> IO (Either EngineBoundaryError result)
runLocalCall fixture harness call = case call of
  LocalRecoverRootInitCall binding _ -> do
    recordEvent harness (LocalExecuted "recover-root-init-call")
    if binding /= pristineStorageBinding (fixturePristine fixture)
      then refused "root init recovery binding mismatch"
      else do
        -- This in-memory worker completes synchronously; it has no later
        -- publication or remote effect after the simulated crash.
        observed <-
          InitRecovery.observeRootInitRecoveryEvidence
            (physicalStoreBoundary fixture harness)
            binding
            (\_ -> pure (Right Nothing))
        pure $ case observed of
          Left _ -> Left (EngineBoundaryUnavailable "root init recovery store unavailable")
          Right result -> Right result
  LocalAcknowledgeRecoveryCustody bundle -> do
    recordEvent harness (LocalExecuted "acknowledge-recovery-custody")
    if bundle == fixtureFinalBundle fixture
      then pure (Right (fixtureRecovery fixture))
      else refused "final bundle mismatch"
  LocalCaptureChildEncryptedReceipt binding -> do
    recordEvent harness (LocalExecuted "capture-child-encrypted-receipt")
    if binding == fixtureChildBinding fixture
      then pure (Right (fixtureChildReceipt fixture))
      else refused "child custody binding mismatch"
  LocalPrepareChildRecoveryDelivery binding nonce attestation -> do
    recordEvent harness (LocalExecuted "prepare-child-recovery-delivery")
    if binding == fixtureChildBinding fixture
      && nonce == fixtureDeliveryNonce fixture
      && attestation == fixtureChildAttestation fixture
      then pure (Right (fixtureChildDelivery fixture))
      else refused "child recovery delivery binding mismatch"
 where
  refused = pure . Left . EngineBoundaryRefused

authorizePhysicalMutation
  :: Harness
  -> BootstrapVaultEffect
  -> BootstrapVaultEffectPermit
  -> IO Bool
authorizePhysicalMutation harness expected permit = do
  state <- readIORef harness
  let valid =
        vaultEffectPermitEffect permit == expected
          && maybe False (vaultPermitMatchesFence permit) (harnessHeldFence state)
  if valid
    then do
      recordEvent harness (PhysicalMutated expected)
      modifyIORef' harness $ \current ->
        current
          { harnessPhysicalMutationCount =
              harnessPhysicalMutationCount current + 1
          }
      pure True
    else do
      recordPermitViolation harness "physical permit mismatch"
      pure False

authorizePhysicalObservation
  :: Harness
  -> BootstrapVaultEffect
  -> BootstrapVaultEffectPermit
  -> IO Bool
authorizePhysicalObservation harness expected permit = do
  state <- readIORef harness
  let valid =
        vaultEffectPermitEffect permit == expected
          && maybe False (vaultPermitMatchesFence permit) (harnessHeldFence state)
  if valid
    then do
      recordEvent harness (PhysicalObserved "child-recovery-consumption")
      pure True
    else do
      recordPermitViolation harness "physical observation permit mismatch"
      pure False

vaultPermitMatchesFence
  :: BootstrapVaultEffectPermit -> BootstrapSessionFence -> Bool
vaultPermitMatchesFence permit fence =
  vaultEffectPermitFenceGeneration permit == bootstrapFenceGeneration fence
    && vaultEffectPermitOwnerNonce permit == bootstrapFenceOwnerNonce fence
    && vaultEffectPermitActionDigest permit == bootstrapFenceActionDigest fence
    && vaultEffectPermitRequestDigest permit == bootstrapFenceRequestDigest fence
    && vaultEffectPermitStorageGeneration permit
      == bootstrapFenceStorageGeneration fence
    && vaultEffectPermitOperationDeadline permit
      == bootstrapFenceOperationDeadline fence

mutationReceipt :: BootstrapVaultEffectPermit -> BootstrapMutationReceipt
mutationReceipt permit =
  BootstrapMutationReceipt
    { bootstrapMutationDigest = vaultEffectPermitActionDigest permit
    , bootstrapMutationChanged = True
    }

requireDelivery
  :: Fixture -> ChildRecoveryDelivery -> IO (Either EngineBoundaryError ())
requireDelivery fixture delivery
  | delivery == fixtureChildDelivery fixture = pure (Right ())
  | otherwise =
      pure (Left (EngineBoundaryRefused "child recovery delivery mismatch"))

observeChildRecoveryConsumption
  :: Fixture
  -> Harness
  -> ChildRecoveryDelivery
  -> IO (Either EngineBoundaryError ChildRecoveryConsumptionObservation)
observeChildRecoveryConsumption fixture harness delivery = do
  checked <- requireDelivery fixture delivery
  case checked of
    Left failure -> pure (Left failure)
    Right () -> do
      state <- readIORef harness
      if not (harnessChildConsumptionObservable state)
        then
          pure
            ( Left
                (EngineBoundaryUnavailable "child recovery consumption unobservable")
            )
        else case harnessChildConsumptionObservationOverride state of
          Just observation -> pure (Right observation)
          Nothing -> case harnessConsumedRecoveryDelivery state of
            Nothing ->
              pure
                ( Right
                    ( mkChildRecoveryConsumptionObservation
                        delivery
                        ChildRecoveryConsumptionNotApplied
                        (digestOf 'c')
                    )
                )
            Just consumed
              | consumed == delivery ->
                  pure
                    ( Right
                        ( mkChildRecoveryConsumptionObservation
                            delivery
                            ChildRecoveryConsumptionApplied
                            (digestOf 'd')
                        )
                    )
              | otherwise ->
                  pure
                    ( Left
                        ( EngineBoundaryRefused
                            "child recovery consumption key conflict"
                        )
                    )

fixtureGeneratedRootCiphertext :: Pgp.GeneratedRootCiphertext
fixtureGeneratedRootCiphertext =
  mustRight (Pgp.mkGeneratedRootCiphertext "encrypted-root-token")

fixtureGeneratedChildCiphertext :: Pgp.GeneratedChildRecoveryCiphertext
fixtureGeneratedChildCiphertext =
  mustRight
    (Pgp.mkGeneratedChildRecoveryCiphertext "encrypted-child-root-token")

removeRootAccessor :: Harness -> RootPolicyAccessor -> IO ()
removeRootAccessor harness accessor =
  modifyIORef' harness $ \state ->
    state
      { harnessLiveRootAccessors =
          filter (/= accessor) (harnessLiveRootAccessors state)
      }

addRootAccessor :: Harness -> RootPolicyAccessor -> IO ()
addRootAccessor harness accessor =
  modifyIORef' harness $ \state ->
    state
      { harnessLiveRootAccessors =
          if accessor `elem` harnessLiveRootAccessors state
            then harnessLiveRootAccessors state
            else harnessLiveRootAccessors state ++ [accessor]
      }

fixtureOwnerNonce :: OwnerNonce
fixtureOwnerNonce = mustRight (mkOwnerNonce "physical-engine-owner")

fixtureNow :: MonotonicInstant
fixtureNow = monotonicInstantFromMicros 10

fixtureAuthorityClock :: AuthorityClockObservation
fixtureAuthorityClock =
  AuthorityTimeTrusted
    (authorityTimeFromMicros 100)
    (clockUncertaintyFromMicros 0)

fixtureLease :: BootstrapSessionFence -> BootstrapLeaseObservation
fixtureLease fence =
  BootstrapLeaseObserved
    (bootstrapLeaseBindingForFence fence)
    (deadlineFromInstant (monotonicInstantFromMicros 900_000))
    "physical-engine-lease-rv"

deadlineMicros :: Deadline -> Natural
deadlineMicros = monotonicInstantMicros . deadlineInstant

physicalEngine
  :: Fixture -> Harness -> Either String (BrokerEngine IO)
physicalEngine fixture harness =
  mkBrokerEngine
    (fixtureCapabilityRefs fixture)
    128
    (baseEngineBoundary fixture harness)

invokeAdapter
  :: Fixture
  -> Settings.BootstrapBrokerSettings
  -> BrokerEngine IO
  -> BrokerRoute
  -> IO (Either BrokerEngineError SomeBrokerResponse)
invokeAdapter fixture settings engine route =
  runEngineBrokerRequest
    engine
    (requestContext fixture)
    route
    (requestBody fixture settings route)

requestContext :: Fixture -> Server.BrokerRequestContext
requestContext fixture =
  Server.BrokerRequestContext
    { Server.brokerRequestAcceptedAt = fixtureNow
    , Server.brokerRequestDeadline = fixtureRequestDeadline
    , Server.brokerRequestCallerAddress = Settings.LoopbackIpv4
    , Server.brokerRequestAuthentication =
        Server.BrokerAuthenticatedRequest (fixtureServiceIdentity fixture)
    }

requestBody
  :: Fixture
  -> Settings.BootstrapBrokerSettings
  -> BrokerRoute
  -> Maybe Server.BrokerRequestBody
requestBody fixture settings route = case brokerRouteBodyRequirement route of
  BrokerBodyForbidden -> Nothing
  BrokerBodyRequired ->
    Just
      ( mustRight
          ( Server.mkBrokerRequestBody
              settings
              route
              (controllerBody fixture route)
          )
      )

controllerBody :: Fixture -> BrokerRoute -> ByteString
controllerBody fixture route
  | route == BrokerVaultPkiIssueTestCertificate =
      encodeBrokerControllerRequest
        ( mkBrokerPkiControllerRequest
            action
            (mustRight (mkPkiIssueRequest "physical.test.invalid" 60))
        )
  | route == BrokerChildCustodyFinalize =
      let completion =
            mustRight
              ( Fake.fakeFederationRegistrationCompletionForReceiptWithAcknowledgement
                  (fixtureChildReceipt fixture)
                  (fixtureParentAcknowledgement fixture)
              )
          finalizeAction =
            mkBrokerActionRequest
              (brokerActionStorageGeneration action)
              ( federationRegistrationOperationDigest
                  (federationRegistrationCompletedIntent completion)
              )
       in encodeBrokerControllerRequest
            (mkBrokerChildCustodyFinalizeRequest finalizeAction completion)
  | otherwise =
      encodeBrokerControllerRequest
        (mustRight (mkBrokerControllerRequest route action))
 where
  action = fixtureActions fixture route

fixtureRequestDeadline :: Deadline
fixtureRequestDeadline =
  deadlineAtOffset fixtureNow (RemainingDuration 800_000)

settingsForPort
  :: PortNumber -> Either String Settings.BootstrapBrokerSettings
settingsForPort port =
  case Settings.validateBootstrapBrokerConfig (settingsConfig port) of
    Left refusal -> Left (Settings.renderBootstrapBrokerSettingsError refusal)
    Right settings -> Right settings

settingsConfig :: PortNumber -> Settings.BootstrapBrokerConfigDhall
settingsConfig port =
  Settings.BootstrapBrokerConfigDhall
    { Settings.schemaVersion = 2
    , Settings.cluster_id = "physical-engine-cluster"
    , Settings.vault_address = "http://127.0.0.1:8200"
    , Settings.service_identity = "physical-engine-test"
    , Settings.parent_registration = Nothing
    , Settings.listener =
        Settings.BrokerListenerDhall
          { Settings.listen_host = "127.0.0.1"
          , Settings.listen_port = fromIntegral port
          }
    , Settings.bootstrap_store =
        Settings.BootstrapStoreDhall
          { Settings.store_endpoint = "http://127.0.0.1:9000"
          , Settings.store_bucket = "physical-engine-state"
          , Settings.vault_storage_generation_key = "vault-storage-generation"
          , Settings.bootstrap_session_fence_key = "bootstrap-session-fence"
          , Settings.prepared_init_envelope_key = "prepared-init-envelope"
          , Settings.encrypted_init_response_key = "encrypted-init-response"
          , Settings.final_unlock_bundle_key = "final-unlock-bundle"
          , Settings.child_custody_receipt_key = "child-custody-receipt"
          , Settings.child_recovery_delivery_key = "child-recovery-delivery"
          , Settings.root_init_journal_key = "root-init-journal"
          , Settings.root_session_journal_key = "root-session-journal"
          , Settings.child_custody_journal_key = "child-custody-journal"
          , Settings.child_recovery_journal_key = "child-recovery-journal"
          , Settings.post_unseal_handoff_key = "post-unseal-handoff"
          , Settings.secret_worker_checkpoint_key = "secret-worker-checkpoint"
          }
    , Settings.limits =
        Settings.BrokerLimitsDhall
          { Settings.queue_capacity = 16
          , Settings.max_request_body_bytes = 65_536
          , Settings.request_deadline_milliseconds = 5000
          , Settings.drain_deadline_milliseconds = 1000
          }
    }

nextStoreVersion :: StoreVersion -> StoreVersion
nextStoreVersion (StoreVersion version) = StoreVersion (version + 1)

storeDigest :: ArtifactDigest
storeDigest = digestOf 'f'

digest :: Char -> Either String ArtifactDigest
digest = bootstrap . mkArtifactDigest . repeatedHex

digestOf :: Char -> ArtifactDigest
digestOf = mustRight . mkArtifactDigest . repeatedHex

repeatedHex :: Char -> Text
repeatedHex character = Text.replicate 64 (Text.singleton character)

bootstrap :: (Show error) => Either error value -> Either String value
bootstrap = either (Left . show) Right

pgp :: (Show error) => Either error value -> Either String value
pgp = either (Left . show) Right

firstString :: Either String value -> Either String value
firstString = id

mustRight :: (Show error) => Either error value -> value
mustRight = either (error . show) id
