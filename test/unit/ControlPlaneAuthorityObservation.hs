{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneAuthorityObservation (controlPlaneAuthorityObservationSuite) where

import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Maybe (fromJust)
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( AuthorityAdmissionRepository (..)
  , AuthorityAdmissionSnapshot (..)
  )
import Prodbox.ControlPlane.AuthorityObservationClient
import Prodbox.ControlPlane.AuthorityObservationEndpoint as AuthorityEndpoint
import Prodbox.ControlPlane.Client
import Prodbox.ControlPlane.Codec
  ( decodeControlPlaneResponse
  , encodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.Lifecycle.Authority.Admission
  ( initialCleanInstallAuthority
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityAdmissionState (GenesisFrozen)
  , authorityEpochFromValue
  )
import Prodbox.Lifecycle.Authority.Migration
  ( MigrationAuthorityStatus (..)
  , MigrationBinding
  , MigrationCommand (..)
  , encodeMigrationState
  , initialMigrationState
  , mkMigrationDigest
  , mkMigrationEpoch
  , stepMigration
  )
import Prodbox.Lifecycle.Authority.MigrationInterpreter
  ( MigrationRepository (..)
  , StoredMigration (..)
  )
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros)
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
import TestSupport

controlPlaneAuthorityObservationSuite :: SuiteBuilder ()
controlPlaneAuthorityObservationSuite =
  describe "Sprint 4.50 Lifecycle Authority identity/epoch/clock observation" $ do
    it "serves a canonical active replacement epoch and authority time" $ do
      request <- accepted (mkLifecycleAuthorityObserveRequest "cluster-a")
      result <-
        serveLifecycleAuthorityObserveRequest
          4096
          "cluster-a"
          (pure (Right 123456))
          (constantRepository (Just (StoredMigration 7 (encodeMigrationState activeState))))
          (encodeControlPlaneRequest request)
      authorityObservationHttpStatus result `shouldBe` 200
      decoded
        (authorityObservationResponseBody result)
        `shouldBe` Right
          LifecycleAuthorityObservation
            { observedAuthorityServiceIdentity = lifecycleAuthorityServiceIdentity
            , observedAuthorityScope = "cluster-a"
            , observedAuthorityWriterStatus = MigrationReplacementWriterActive epoch7
            , observedAuthorityAdmission = Nothing
            , observedAuthorityTimeMicros = 123456
            }

    it "fails closed on scope mismatch before reading state or clock" $ do
      stateRead <- newIORef False
      clockRead <- newIORef False
      request <- accepted (mkLifecycleAuthorityObserveRequest "other-cluster")
      let repository =
            MigrationRepository
              { readMigrationState = writeIORef stateRead True >> pure (Right Nothing)
              , compareAndSwapMigrationState = \_ _ -> pure (Right False)
              }
      result <-
        serveLifecycleAuthorityObserveRequest
          4096
          "cluster-a"
          (writeIORef clockRead True >> pure (Right 1))
          repository
          (encodeControlPlaneRequest request)
      result `shouldBe` AuthorityEndpoint.AuthorityObservationScopeMismatch
      readIORef stateRead `shouldReturn` False
      readIORef clockRead `shouldReturn` False

    it "projects the exact retained admission state while clean-install admission is frozen" $ do
      aggregate <- accepted (initialCleanInstallAuthority 4 8)
      request <- accepted (mkLifecycleAuthorityObserveRequest "cluster-a")
      result <-
        serveLifecycleAuthorityAggregateObserveRequest
          4096
          "cluster-a"
          (pure (Right 123456))
          AuthorityAdmissionRepository
            { readAuthorityAdmission =
                pure (Right (AuthorityAdmissionSnapshot (1 :: Word) aggregate))
            , compareAndSwapAuthorityAdmission = \_ _ ->
                pure (Left "observation must not write")
            }
          (encodeControlPlaneRequest request)
      result
        `shouldBe` AuthorityObservationSucceeded
          LifecycleAuthorityObservation
            { observedAuthorityServiceIdentity = lifecycleAuthorityServiceIdentity
            , observedAuthorityScope = "cluster-a"
            , observedAuthorityWriterStatus = MigrationWritersQuiesced
            , observedAuthorityAdmission = Just GenesisFrozen
            , observedAuthorityTimeMicros = 123456
            }

    it "keeps missing, corrupt, and unobservable migration states distinct" $ do
      request <- accepted (mkLifecycleAuthorityObserveRequest "cluster-a")
      missing <- serve (constantRepository Nothing) request
      case missing of
        AuthorityObservationSucceeded observation ->
          observedAuthorityWriterStatus observation `shouldBe` MigrationLegacyWriterActive
        other -> expectationFailure ("expected legacy-writer observation, got " ++ show other)
      corrupt <- serve (constantRepository (Just (StoredMigration 1 "not-cbor"))) request
      corrupt `shouldBe` AuthorityObservationStateCorrupt
      unavailable <-
        serve
          ( MigrationRepository
              { readMigrationState = pure (Left "store unavailable")
              , compareAndSwapMigrationState = \_ _ -> pure (Right False)
              }
          )
          request
      unavailable `shouldBe` AuthorityObservationReadFailed "store unavailable"

    it "client validates role identity and scope before exposing epoch/time" $ do
      client <- clientReturning goodObservation
      result <- observeActiveLifecycleAuthority client "cluster-a"
      case result of
        Left err -> expectationFailure ("expected active observation, got " ++ show err)
        Right observation -> do
          activeLifecycleAuthorityEpoch observation
            `shouldBe` fromJust (authorityEpochFromValue 7)
          activeLifecycleAuthorityTime observation
            `shouldBe` authorityTimeFromMicros 123456
      wrongIdentity <-
        clientReturning
          goodObservation {observedAuthorityServiceIdentity = "target-secret-agent"}
      observeActiveLifecycleAuthority wrongIdentity "cluster-a"
        `shouldReturn` Left
          ( AuthorityObservationServiceIdentityMismatch
              lifecycleAuthorityServiceIdentity
              "target-secret-agent"
          )

    it "client refuses a legacy/quiesced writer instead of manufacturing an epoch" $ do
      legacy <-
        clientReturning
          goodObservation {observedAuthorityWriterStatus = MigrationLegacyWriterActive}
      observeActiveLifecycleAuthority legacy "cluster-a"
        `shouldReturn` Left AuthorityObservationLegacyWriterActive
      quiesced <-
        clientReturning
          goodObservation {observedAuthorityWriterStatus = MigrationWritersQuiesced}
      observeActiveLifecycleAuthority quiesced "cluster-a"
        `shouldReturn` Left AuthorityObservationWritersQuiesced
 where
  digest = fromJust (mkMigrationDigest "authority-observation-v1")
  epoch7 = fromJust (mkMigrationEpoch 7)
  activeState =
    foldl
      apply
      initialMigrationState
      ( [VerifyShadow digest, FreezeLegacy digest]
          ++ fmap PrepareBinding ([minBound .. maxBound] :: [MigrationBinding])
          ++ [ActivateReplacement epoch7]
      )
  apply state command = fst (stepMigration state command)
  decoded body =
    decodeControlPlaneResponse 4096 (LazyByteString.fromStrict body)
  serve repository request =
    serveLifecycleAuthorityObserveRequest
      4096
      "cluster-a"
      (pure (Right 123456))
      repository
      (encodeControlPlaneRequest request)
  goodObservation =
    LifecycleAuthorityObservation
      { observedAuthorityServiceIdentity = lifecycleAuthorityServiceIdentity
      , observedAuthorityScope = "cluster-a"
      , observedAuthorityWriterStatus = MigrationReplacementWriterActive epoch7
      , observedAuthorityAdmission = Nothing
      , observedAuthorityTimeMicros = 123456
      }

constantRepository
  :: Maybe (StoredMigration Word)
  -> MigrationRepository IO Word
constantRepository stored =
  MigrationRepository
    { readMigrationState = pure (Right stored)
    , compareAndSwapMigrationState = \_ _ -> pure (Right False)
    }

clientReturning
  :: LifecycleAuthorityObservation
  -> IO (ControlPlaneClient 'LifecycleAuthorityRuntime)
clientReturning observation = do
  endpoint <- accepted (mkLifecycleAuthorityEndpoint "http://lifecycle-authority:8600")
  accepted
    ( controlPlaneClientWithTransport
        authorityObservationMaximumResponseBytes
        endpoint
        ( \_ _ _ _ ->
            pure
              ( Right
                  ( 200
                  , LazyByteString.toStrict (encodeControlPlaneResponse observation)
                  )
              )
        )
    )

accepted :: (Show err) => Either err value -> IO value
accepted result = case result of
  Left err -> fail (show err)
  Right value -> pure value
