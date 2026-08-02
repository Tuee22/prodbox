{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module DecommissionControlPlaneClient (decommissionControlPlaneClientSuite) where

import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as Char8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
import Data.Text qualified as Text
import Data.Word (Word8)
import Prodbox.ControlPlane.AuthenticatedRoleInterpreter
import Prodbox.ControlPlane.AuthenticatedTransport
import Prodbox.ControlPlane.CallerPrincipal (CallerPrincipal (CallerOperatorCli))
import Prodbox.ControlPlane.Client
import Prodbox.ControlPlane.Codec (encodeControlPlaneRequest)
import Prodbox.ControlPlane.Coordinate (AuthorityScope, mkAuthorityScope)
import Prodbox.ControlPlane.DecommissionClient
import Prodbox.ControlPlane.RequestAuthentication
  ( RequestSigner
  , localRequestSigningCapability
  , mkRequestNonce
  , mkRequestSigner
  , mkSigningKeyGeneration
  , trustedRequestKeyFromSigner
  )
import Prodbox.ControlPlane.RequestReplay
import Prodbox.ControlPlane.RoleInterpreters
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (..)
  , controlPlaneRoutePath
  , routesForRole
  )
import Prodbox.ControlPlane.Server
  ( RoleInterpreter
  , serveControlPlaneRequest
  )
import Prodbox.ControlPlane.TargetMaterialRegistry
  ( TargetSecretId (TargetSesSmtp)
  , TargetSecretPayload (..)
  , compiledTargetSecretSink
  )
import Prodbox.ControlPlane.TrustedTargetSink (mkTrustedTargetSink)
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.CheckpointAuthority
  ( TargetClusterSecretSink
  )
import Prodbox.Lifecycle.Decommission.AuthorityExport
import Prodbox.Lifecycle.Decommission.AuthorityStop
import Prodbox.Lifecycle.Decommission.Frame
  ( FrameAttemptId
  , FrameDigest
  , FrameNodeId
  , contentDigest
  , mkFrameAttemptId
  )
import Prodbox.Lifecycle.Decommission.Manifest
import Prodbox.Lifecycle.Decommission.NodeEffect
  ( NodeOperation (..)
  , runRetainedCustodyTombstoneCapability
  , runTargetGenerationTombstoneCapability
  )
import Prodbox.Lifecycle.Decommission.RetainedCustodyTombstone
import Prodbox.Lifecycle.Decommission.TargetInventory
import Prodbox.Lifecycle.Decommission.TargetTombstone
import Prodbox.Lifecycle.Decommission.Verifier
import Prodbox.Lifecycle.Lease
  ( AuthorityDuration
  , AuthorityTime
  , authorityDurationFromMicros
  , authorityTimeFromMicros
  , mkFencingToken
  , mkOwnerNonce
  )
import Prodbox.Lifecycle.ResidueStatus (ResidueStatus (..))
import Prodbox.Lifecycle.TargetCommitIntent
  ( TargetSinkObservation (..)
  , TargetSinkRecord (..)
  , TargetSinkVersion
  , mkCredentialGeneration
  , mkTargetSinkVersion
  , mkTargetValueDigest
  )
import Prodbox.Runtime.Role
  ( RuntimeRole (LifecycleAuthorityRuntime, TargetSecretAgentRuntime)
  )
import TestSupport

decommissionControlPlaneClientSuite :: SuiteBuilder ()
decommissionControlPlaneClientSuite =
  describe "Sprint 4.50 authenticated decommission clients" $ do
    it "exports and independently verifies the Authority manifest through its authenticated route" $ do
      observedUrl <- newIORef Nothing
      providers <- freshClientProviders
      interpreter <-
        freshAuthenticatedInterpreter
          LifecycleAuthorityRuntime
          ( lifecycleAuthorityDecommissionAuthenticatedHandler
              65536
              ( LifecycleAuthorityDecommissionProvisioned
                  authorityRepository
                  authorityManifestSigner
                  manifestSignerDigest
                  authorityStopRepository
              )
              availableBaseHandler
          )
      endpoint <- accepted (mkLifecycleAuthorityEndpoint "http://lifecycle-authority:8600")
      client <-
        accepted
          ( controlPlaneClientWithTransport
              authorityDecommissionMaximumResponseBytes
              endpoint
              ( authorityTransport
                  observedUrl
                  interpreter
              )
          )
      result <-
        requestAuthorityDecommissionManifest
          transportBounds
          providers
          client
          manifestSignerDigest
          verifier
      result `shouldBe` Right verifiedManifest
      readIORef observedUrl
        `shouldReturn` Just
          "http://lifecycle-authority:8600/v1/authority/decommission/export"

    it
      "keeps target observation read-only and destroys only the signed generation through the authenticated route"
      $ do
        observations <-
          newIORef
            [ TargetSinkObserved targetVersion targetRecord
            , TargetSinkObserved targetVersion targetRecord
            , TargetSinkMissing
            , TargetSinkMissing
            ]
        deletes <- newIORef (0 :: Int)
        observedUrls <- newIORef []
        registry <- targetRegistry observations deletes
        providers <- freshClientProviders
        interpreter <-
          freshAuthenticatedInterpreter
            TargetSecretAgentRuntime
            ( targetSecretAgentDecommissionAuthenticatedHandler
                65536
                ( TargetSecretAgentDecommissionProvisioned
                    manifestSignerDigest
                    registry
                    fixtureTargetInventory
                    fixtureRetainedCustodyBoundary
                )
                availableBaseHandler
            )
        endpoint <- accepted (mkTargetSecretAgentEndpoint "http://target-secret-agent:8600")
        client <-
          accepted
            ( controlPlaneClientWithTransport
                targetGenerationTombstoneMaximumResponseBytes
                endpoint
                (targetTransport observedUrls interpreter)
            )
        let capability =
              targetGenerationTombstoneCapability
                transportBounds
                providers
                client
                verifiedManifest
            operation =
              runTargetGenerationTombstoneCapability capability "ses-smtp" targetGeneration
            nodeId = decommissionNodeFrameId targetNode
            attemptId = mustJust (mkFrameAttemptId "attempt-1")
        firstObservation <- nodeReadBack operation nodeId attemptId
        firstObservation `shouldSatisfy` isPresent
        readIORef deletes `shouldReturn` 0
        nodeDestroy operation nodeId attemptId `shouldReturn` Right ()
        nodeReadBack operation nodeId attemptId `shouldReturn` ResidueAbsent
        readIORef deletes `shouldReturn` 1
        readIORef observedUrls
          `shouldReturn` replicate
            3
            "http://target-secret-agent:8600/v1/target-secret/decommission/tombstone"

    it "uses distinct authenticated routes for secret-free inventory and retained custody" $ do
      observedUrls <- newIORef []
      observations <- newIORef [TargetSinkMissing]
      deletes <- newIORef (0 :: Int)
      registry <- targetRegistry observations deletes
      providers <- freshClientProviders
      interpreter <-
        freshAuthenticatedInterpreter
          TargetSecretAgentRuntime
          ( targetSecretAgentDecommissionAuthenticatedHandler
              65536
              ( TargetSecretAgentDecommissionProvisioned
                  manifestSignerDigest
                  registry
                  fixtureTargetInventory
                  fixtureRetainedCustodyBoundary
              )
              availableBaseHandler
          )
      endpoint <- accepted (mkTargetSecretAgentEndpoint "http://target-secret-agent:8600")
      client <-
        accepted
          ( controlPlaneClientWithTransport
              targetGenerationTombstoneMaximumResponseBytes
              endpoint
              (targetRoleTransport observedUrls interpreter)
          )
      let transport = mkAuthenticatedClientTransport transportBounds providers client
      requestTargetDecommissionInventory transport
        `shouldReturn` Right
          TargetDecommissionInventory
            { targetDecommissionInventoryReference = "ses-smtp"
            , targetDecommissionInventoryGeneration = Nothing
            }
      let custodyOperation =
            runRetainedCustodyTombstoneCapability
              (retainedCustodyTombstoneCapability transport verifiedCustodyManifest)
      nodeReadBack custodyOperation custodyNodeId fixtureAttemptId
        `shouldReturn` ResidueAbsent
      readIORef observedUrls
        `shouldReturn` [ "http://target-secret-agent:8600/v1/target-secret/decommission/inventory"
                       , "http://target-secret-agent:8600/v1/target-secret/decommission/retained-custody"
                       ]

    it "keeps both decommission routes explicitly unavailable until production inputs are provisioned" $ do
      authorityProviders <- freshClientProviders
      authorityInterpreter <-
        freshAuthenticatedInterpreter
          LifecycleAuthorityRuntime
          ( lifecycleAuthorityDecommissionAuthenticatedHandler
              65536
              (LifecycleAuthorityDecommissionUnprovisioned "Authority repository and signer are not installed")
              availableBaseHandler
          )
      authorityEndpoint <-
        accepted (mkLifecycleAuthorityEndpoint "http://lifecycle-authority:8600")
      authorityClient <-
        accepted
          ( controlPlaneClientWithTransport
              authorityDecommissionMaximumResponseBytes
              authorityEndpoint
              (authorityTransportDiscardUrl authorityInterpreter)
          )
      authorityResult <-
        requestAuthorityDecommissionManifest
          transportBounds
          authorityProviders
          authorityClient
          manifestSignerDigest
          verifier
      authorityResult
        `shouldBe` Left
          ( AuthorityDecommissionHttpStatus
              503
              "authority-decommission-export-unprovisioned\n"
          )
      serveReadyz authorityInterpreter LifecycleAuthorityRuntime
        `shouldReturn` (503, "not-ready\n")

      targetProviders <- freshClientProviders
      targetInterpreter <-
        freshAuthenticatedInterpreter
          TargetSecretAgentRuntime
          ( targetSecretAgentDecommissionAuthenticatedHandler
              65536
              (TargetSecretAgentDecommissionUnprovisioned "Target signer trust and registry are not installed")
              availableBaseHandler
          )
      targetEndpoint <-
        accepted (mkTargetSecretAgentEndpoint "http://target-secret-agent:8600")
      targetClient <-
        accepted
          ( controlPlaneClientWithTransport
              targetGenerationTombstoneMaximumResponseBytes
              targetEndpoint
              (targetTransportDiscardUrls targetInterpreter)
          )
      targetResponse <-
        callAuthenticatedControlPlane
          transportBounds
          targetProviders
          targetClient
          TargetSecretDecommissionTombstoneRoute
          (targetTombstoneRequestBody ObserveTargetGenerationAbsence)
      targetResponse
        `shouldBe` Right
          ( ControlPlaneResponse
              503
              "target-generation-tombstone-unprovisioned\n"
          )
      serveReadyz targetInterpreter TargetSecretAgentRuntime
        `shouldReturn` (503, "not-ready\n")

authorityTransport
  :: IORef (Maybe String)
  -> RoleInterpreter IO
  -> ControlPlaneTransport
authorityTransport observedUrl =
  servingTransport
    LifecycleAuthorityRuntime
    LifecycleAuthorityDecommissionExport
    (writeIORef observedUrl . Just)

authorityTransportDiscardUrl :: RoleInterpreter IO -> ControlPlaneTransport
authorityTransportDiscardUrl =
  servingTransport
    LifecycleAuthorityRuntime
    LifecycleAuthorityDecommissionExport
    (const (pure ()))

targetTransport
  :: IORef [String]
  -> RoleInterpreter IO
  -> ControlPlaneTransport
targetTransport observedUrls =
  servingTransport
    TargetSecretAgentRuntime
    TargetSecretDecommissionTombstone
    (\url -> modifyIORef' observedUrls (<> [url]))

targetTransportDiscardUrls :: RoleInterpreter IO -> ControlPlaneTransport
targetTransportDiscardUrls =
  servingTransport
    TargetSecretAgentRuntime
    TargetSecretDecommissionTombstone
    (const (pure ()))

targetRoleTransport
  :: IORef [String]
  -> RoleInterpreter IO
  -> ControlPlaneTransport
targetRoleTransport observedUrls interpreter method _headers url body = do
  method `shouldBe` "POST"
  modifyIORef' observedUrls (<> [url])
  let path = drop (length targetEndpointPrefix) url
  response <-
    serveControlPlaneRequest
      interpreter
      TargetSecretAgentRuntime
      ( ByteString.concat
          [ method
          , " "
          , Char8.pack path
          , " HTTP/1.1\r\nContent-Length: "
          , Char8.pack (show (ByteString.length body))
          , "\r\n\r\n"
          , body
          ]
      )
  pure (Right response)
 where
  targetEndpointPrefix :: String
  targetEndpointPrefix = "http://target-secret-agent:8600"

servingTransport
  :: RuntimeRole
  -> ControlPlaneRoute
  -> (String -> IO ())
  -> RoleInterpreter IO
  -> ControlPlaneTransport
servingTransport role route observeUrl interpreter method _headers url body = do
  method `shouldBe` "POST"
  observeUrl url
  response <-
    serveControlPlaneRequest
      interpreter
      role
      ( ByteString.concat
          [ method
          , " "
          , Char8.pack (controlPlaneRoutePath route)
          , " HTTP/1.1\r\nContent-Length: "
          , Char8.pack (show (ByteString.length body))
          , "\r\n\r\n"
          , body
          ]
      )
  pure (Right response)

authorityRepository :: AuthorityDecommissionExportRepository IO
authorityRepository =
  AuthorityDecommissionExportRepository
    { freezeAuthorityAdmission = pure (Right ())
    , readAuthorityDecommissionPlan = pure (Right manifest)
    , commitAuthorityDecommissionManifest = const (pure (Right ()))
    }

authorityStopRepository :: AuthorityDecommissionStopRepository IO
authorityStopRepository =
  AuthorityDecommissionStopRepository
    { readCommittedDecommissionManifest = pure (Right Nothing)
    , commitAuthorityPermanentStop = \_ _ -> pure (Left "not invoked by export fixture")
    }

authorityManifestSigner :: AuthorityManifestSigner IO
authorityManifestSigner =
  AuthorityManifestSigner
    { readAuthorityManifestPublicKey = pure (Right (1, manifestPublicKey))
    , signAuthorityManifestPayload = \payload ->
        if payload == manifestSigningPayload manifest verifier manifestPublicKey
          then pure (Right (1, manifestSignatureBytes (signedManifestSignature signedManifest)))
          else pure (Left "unexpected signing payload")
    }

targetRegistry
  :: IORef [TargetSinkObservation TargetSecretPayload]
  -> IORef Int
  -> IO (TargetGenerationTombstoneRegistry IO TargetSecretPayload)
targetRegistry observations deletes = do
  remaining <- newIORef =<< readIORef observations
  let observe = do
        values <- readIORef remaining
        case values of
          [] -> pure (TargetSinkUnobservable "fixture exhausted")
          value : rest -> writeIORef remaining rest >> pure value
      trusted =
        mkTrustedTargetSink
          targetSink
          observe
          (\_ _ -> pure (Left "CAS forbidden"))
      boundary =
        mkTargetGenerationTombstoneBoundary trusted $ do
          modifyIORef' deletes (+ 1)
          pure (Right ())
      binding = mustRight (mkTargetGenerationTombstoneBinding "ses-smtp" boundary)
  pure (mustRight (mkTargetGenerationTombstoneRegistry [binding]))

fixtureTargetInventory
  :: TargetDecommissionInventoryBoundary IO TargetSecretPayload
fixtureTargetInventory =
  targetDecommissionInventoryBoundary
    ( mkTrustedTargetSink
        targetSink
        (pure TargetSinkMissing)
        (\_ _ -> pure (Left "inventory fixture is read-only"))
    )

fixtureRetainedCustodyBoundary :: RetainedCustodyBoundary IO
fixtureRetainedCustodyBoundary =
  mustRight
    ( mkRetainedCustodyBoundary
        [ absentCustody RetainedHomeSesSmtpSource
        , absentCustody RetainedHomeAcmeEabSource
        ]
    )
 where
  absentCustody kind =
    retainedCustodyEntryBoundary
      kind
      (pure RetainedCustodyAbsent)
      (pure (Left "absent custody fixture must not destroy"))

data FakeReplayState = FakeReplayState
  { fakeReplayRevision :: !Int
  , fakeReplayProjection :: !RequestReplayProjection
  }

freshAuthenticatedInterpreter
  :: RuntimeRole
  -> AuthenticatedRoleHandler IO
  -> IO (RoleInterpreter IO)
freshAuthenticatedInterpreter role handler = do
  state <- newIORef (FakeReplayState 0 (initialRequestReplayProjection replayLimits))
  attemptCounter <- newIORef (0 :: Int)
  let providers =
        AuthenticatedRoleProviders
          { authenticatedRoleServerProviders = serverProvidersForRole role
          , provideAuthenticatedReplayAttempt = do
              attempt <- atomicModifyIORef' attemptCounter (\current -> (current + 1, current))
              pure
                ( Right
                    ( mustRight
                        (mkReplayAttemptId (uniqueBytes 1 attempt))
                    )
                )
          }
  pure
    ( authenticatedRoleInterpreter
        transportBounds
        maximumLifetime
        providers
        role
        replayCasAttempts
        replayLimits
        (fakeReplayRepository state)
        handler
    )

fakeReplayRepository
  :: IORef FakeReplayState
  -> RequestReplayRepository IO Int
fakeReplayRepository state =
  RequestReplayRepository
    { readRequestReplayProjection = do
        observed <- readIORef state
        pure
          ( Right
              RequestReplaySnapshot
                { requestReplayRevision = fakeReplayRevision observed
                , requestReplaySnapshotProjection = fakeReplayProjection observed
                }
          )
    , compareAndSwapRequestReplayProjection = \expected projection ->
        atomicModifyIORef' state $ \observed ->
          if fakeReplayRevision observed == expected
            then
              ( FakeReplayState
                  { fakeReplayRevision = expected + 1
                  , fakeReplayProjection = projection
                  }
              , RequestReplayCasApplied
              )
            else (observed, RequestReplayCasConflict)
    }

freshClientProviders :: IO (AuthenticatedClientProviders IO)
freshClientProviders = do
  nonceCounter <- newIORef (0 :: Int)
  pure
    AuthenticatedClientProviders
      { provideAuthenticatedClientSigner =
          pure (Right (localRequestSigningCapability requestSigner))
      , provideAuthenticatedClientScope = pure (Right authorityScope)
      , provideAuthenticatedClientEpoch = pure (Right authorityEpochGenesis)
      , provideAuthenticatedClientDeadline = pure (Right deadline)
      , provideAuthenticatedClientNonce = do
          nonce <- atomicModifyIORef' nonceCounter (\current -> (current + 1, current))
          pure (Right (mustRight (mkRequestNonce (uniqueBytes 0 nonce))))
      }

uniqueBytes :: Word8 -> Int -> ByteString.ByteString
uniqueBytes prefix counter =
  ByteString.replicate 15 prefix
    <> ByteString.singleton (fromIntegral counter)

availableBaseHandler :: AuthenticatedRoleHandler IO
availableBaseHandler =
  AuthenticatedRoleHandler
    { authenticatedHandlerReadyz = pure True
    , authenticatedHandlerHandle = \_ _ _ -> pure Nothing
    }

serverProvidersForRole :: RuntimeRole -> AuthenticatedServerProviders IO
serverProvidersForRole role =
  AuthenticatedServerProviders
    { provideAuthenticatedServerScope = pure (Right authorityScope)
    , provideAuthenticatedServerEpoch = pure (Right authorityEpochGenesis)
    , provideAuthenticatedServerTime = pure (Right now)
    , provideAuthenticatedServerTrustRegistry = pure (Right (trustRegistryForRole role))
    }

transportBounds :: AuthenticatedTransportBounds
transportBounds = mustRight (mkAuthenticatedTransportBounds 131072 256 130000)

replayLimits :: RequestReplayLimits
replayLimits =
  mustRight
    ( mkRequestReplayLimits
        16
        131072
        (mustRight (authorityDurationFromMicros 100))
    )

replayCasAttempts :: ReplayCasAttempts
replayCasAttempts = mustRight (mkReplayCasAttempts 3)

maximumLifetime :: AuthorityDuration
maximumLifetime = mustRight (authorityDurationFromMicros 5000)

now :: AuthorityTime
now = authorityTimeFromMicros 1000

deadline :: AuthorityTime
deadline = authorityTimeFromMicros 2000

requestSigner :: RequestSigner
requestSigner =
  mustRight
    ( mkRequestSigner
        CallerOperatorCli
        (mustRight (mkSigningKeyGeneration 1))
        (ByteString.pack [64 .. 95])
    )

authorityScope :: AuthorityScope
authorityScope = mustRight (mkAuthorityScope "home")

trustRegistryForRole :: RuntimeRole -> RouteTrustRegistry
trustRegistryForRole role =
  mustRight
    ( mkRouteTrustRegistry
        role
        1
        [ (route, trustedRequestKeyFromSigner requestSigner)
        | route <- routesForRole role
        ]
    )

manifest :: DecommissionManifest
manifest = mustRight (mkDecommissionManifest "home" [targetNode])

targetNode :: DecommissionNode
targetNode = TargetGeneration "ses-smtp" targetGeneration

targetGeneration :: DecommissionTargetGeneration
targetGeneration = mustRight (mkDecommissionTargetGeneration 7)

manifestSigningKey :: ManifestSigningKey
manifestSigningKey = mustRight (mkManifestSigningKey (ByteString.pack [0 .. 31]))

manifestPublicKey :: ManifestPublicKey
manifestPublicKey = manifestSigningPublicKey manifestSigningKey

manifestSignerDigest :: FrameDigest
manifestSignerDigest = manifestPublicKeyDigest manifestPublicKey

signedManifest :: SignedDecommissionManifest
signedManifest = signDecommissionManifest manifestSigningKey manifest verifier

verifiedManifest :: VerifiedDecommissionManifest
verifiedManifest = mustRight (verifySignedDecommissionManifest manifestSignerDigest signedManifest)

verifiedCustodyManifest :: VerifiedDecommissionManifest
verifiedCustodyManifest =
  mustRight
    ( verifySignedDecommissionManifest
        manifestSignerDigest
        (signDecommissionManifest manifestSigningKey custodyManifest verifier)
    )

custodyManifest :: DecommissionManifest
custodyManifest = mustRight (mkDecommissionManifest "home" [RetainedCustody])

custodyNodeId :: FrameNodeId
custodyNodeId = decommissionNodeFrameId RetainedCustody

fixtureAttemptId :: FrameAttemptId
fixtureAttemptId = mustJust (mkFrameAttemptId "attempt-custody")

verifier :: VerifierBinding
verifier = verifierBindingOf artifactPath artifact

artifactPath :: ExternalArtifactPath
artifactPath = mustRight (mkExternalArtifactPath "/tmp/prodbox-export/decommission-runner")

artifact :: VerifierArtifact
artifact = mustRight (mkVerifierArtifact "runner-build-v1" "dependency-v1" metadata)

metadata :: VerifierMetadata
metadata =
  mustRight
    ( mkVerifierMetadata
        (contentDigest "dependency-v1")
        1
        (contentDigest "manifest-schema-v1")
        1
        (contentDigest "interpreter-registry-v1")
    )

targetSink :: TargetClusterSecretSink
targetSink = mustRight (compiledTargetSecretSink TargetSesSmtp)

targetVersion :: TargetSinkVersion
targetVersion = mustRight (mkTargetSinkVersion "7")

targetRecord :: TargetSinkRecord TargetSecretPayload
targetRecord =
  TargetSinkRecord
    { targetSinkRecordOwnerNonce = mustRight (mkOwnerNonce "owner-1")
    , targetSinkRecordFencingToken = mustRight (mkFencingToken 1)
    , targetSinkRecordGeneration = mustRight (mkCredentialGeneration 7)
    , targetSinkRecordDigest = mustRight (mkTargetValueDigest (Text.replicate 64 "a"))
    , targetSinkRecordPayload =
        SesSmtpMaterial
          { sesSmtpHost = "email-smtp.ca-central-1.amazonaws.com"
          , sesSmtpPort = "587"
          , sesSmtpFrom = "noreply@example.com"
          , sesSmtpFromDisplayName = "Prodbox"
          , sesSmtpReplyTo = "support@example.com"
          , sesSmtpUsername = "smtp-user"
          , sesSmtpPassword = "payload"
          }
    }

targetTombstoneRequestBody
  :: TargetGenerationTombstoneAction
  -> ByteString.ByteString
targetTombstoneRequestBody action =
  LazyByteString.toStrict
    ( encodeControlPlaneRequest
        TargetGenerationTombstoneRequest
          { targetTombstoneManifest = verifiedSignedManifest verifiedManifest
          , targetTombstoneCommand =
              TargetGenerationTombstoneCommand
                { targetTombstoneReference = "ses-smtp"
                , targetTombstoneGeneration = targetGeneration
                }
          , targetTombstoneAction = action
          }
    )

serveReadyz
  :: RoleInterpreter IO
  -> RuntimeRole
  -> IO (Int, ByteString.ByteString)
serveReadyz interpreter role =
  serveControlPlaneRequest interpreter role "GET /readyz HTTP/1.1\r\n\r\n"

isPresent :: ResidueStatus -> Bool
isPresent status = case status of
  ResiduePresent _ -> True
  _ -> False

accepted :: (Show err) => Either err value -> IO value
accepted result = case result of
  Left err -> fail (show err)
  Right value -> pure value

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value

mustJust :: Maybe value -> value
mustJust result = case result of
  Nothing -> error "invalid decommission client fixture"
  Just value -> value
