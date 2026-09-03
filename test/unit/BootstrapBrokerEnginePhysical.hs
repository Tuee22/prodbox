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

import Codec.Serialise (serialise)
import Control.Exception
  ( AsyncException (ThreadKilled)
  , SomeException
  , bracket
  , fromException
  , throwIO
  , try
  )
import Control.Monad (forM_, void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  )
import Data.List (nub)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
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
import Numeric.Natural (Natural)
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
import Prodbox.Bootstrap.Broker.Model
import Prodbox.Bootstrap.Broker.PgpBoundary qualified as Pgp
import Prodbox.Bootstrap.Broker.PristineJournal
  ( PristineJournalRefusal (..)
  , classifyPristineJournal
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
  ( classifyInitializationAmbiguity
  )
import Prodbox.Bootstrap.Broker.Program
import Prodbox.Bootstrap.Broker.Protocol
import Prodbox.Bootstrap.Broker.Readiness (BrokerReadinessState (..))
import Prodbox.Bootstrap.Broker.Request qualified as Request
import Prodbox.Bootstrap.Broker.Routes
import Prodbox.Bootstrap.Broker.SecretWorker
import Prodbox.Bootstrap.Broker.Server qualified as Server
import Prodbox.Bootstrap.Broker.Settings qualified as Settings
import Prodbox.Bootstrap.Broker.StoreBoundary
import Prodbox.Bootstrap.Broker.Types
import Prodbox.Cluster.FederationRegistration
  ( federationRegistrationCompletedIntent
  , federationRegistrationOperationDigest
  )
import Prodbox.ControlPlane.AuthorityClock
  ( AuthorityClockObservation (..)
  , clockUncertaintyFromMicros
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
    it "Sprint 2.54 keeps both pristine consumers on the shared classifier" $ do
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
              "\npristineEvidence settings store action = do"
              "\nresetEvidence"
              controller
          workerRegion =
            functionRegion
              "\nprepareInitialization settings store kubernetes binding request payload = do"
              "\nresumeInitialization"
              worker
      Text.count "classifyPristineJournal binding observation" controllerRegion
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

    it "reconciles both init worker-journal loss windows without replay" $
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
            second `shouldBeRouteSuccess` BrokerVaultInitialize
            state <- readIORef harness
            rootInitIsDurable fixture state `shouldBe` True
            length [() | InitVaultEffectApplied <- harnessEvents state]
              `shouldBe` 1
            length
              [ ()
              | WorkerExecuted SecretWorkerInitialize <- harnessEvents state
              ]
              `shouldBe` 1
            workerCheckpointIsComplete state `shouldBe` True
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
        physicalRootInitIsAmbiguous fixture afterFirst `shouldBe` True
        harnessPreparedEnvelope afterFirst `shouldBe` Nothing
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
            { harnessCrashPoint = CrashAfterRootJournalCas
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

    it "rejects a mismatched physical reset proof without committing a root-journal CAS" $
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
        physicalRootInitIsAmbiguous fixture state `shouldBe` True
        harnessRootBinding state
          `shouldBe` ambiguousInitBinding (fixtureAmbiguity fixture)
        let resetEvents = drop (length (harnessEvents before)) (harnessEvents state)
        resetEvents
          `shouldSatisfy` elem
            (PhysicalMutated BootstrapVaultResetAmbiguousInitialization)
        resetEvents
          `shouldSatisfy` notElem (StoreMutated BootstrapStoreCasRootInitJournal)
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

withFixture :: (Fixture -> Expectation) -> Expectation
withFixture assertion = case buildFixture of
  Left failure -> expectationFailure ("invalid physical fixture: " ++ failure)
  Right fixture -> assertion fixture

requireEngine :: Fixture -> Harness -> IO (BrokerEngine IO)
requireEngine fixture harness = case physicalEngine fixture harness of
  Left failure -> throwIO (userError failure)
  Right engine -> pure engine

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
  | CrashAfterInitEffectBeforeWorkerReceipt
  | CrashAfterInitWorkerReceiptCas
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
        CrashAfterInitEffectBeforeWorkerReceipt -> False
        CrashAfterInitWorkerReceiptCas ->
          mutation == BootstrapStoreCasSecretWorkerCheckpoint
            && initWorkerAwaitingCleanup state
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
        \_ -> readSlot "root-init-journal" harnessRootJournal harness
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
    { resolvePristineStorageProof =
        \_ -> pure (Right (fixturePristine fixture))
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
    , withSecretWorkerCheckpointPermit =
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
      | fenceMatchesRequest action requestDigest deadline held -> do
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
              fixtureOwnerNonce
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
  :: BrokerActionRequest
  -> Request.RequestDigest
  -> Deadline
  -> BootstrapSessionFence
  -> Bool
fenceMatchesRequest action requestDigest deadline fence =
  bootstrapFenceOwnerNonce fence == fixtureOwnerNonce
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
  LocalRecoverRootInitCall binding -> do
    recordEvent harness (LocalExecuted "recover-root-init-call")
    state <- readIORef harness
    if binding /= pristineStorageBinding (fixturePristine fixture)
      then refused "root init recovery binding mismatch"
      else pure . Right $ case harnessInitMode state of
        ReturnEncryptedInitResponse ->
          RootInitRecoveredResponse (fixtureEncryptedResponse fixture)
        ReturnAppliedWithoutResponse -> RootInitRecoveredAmbiguity
        ReturnClassifiedAppliedWithoutResponse _ -> RootInitRecoveredAmbiguity
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
