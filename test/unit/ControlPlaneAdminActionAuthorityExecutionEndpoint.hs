{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneAdminActionAuthorityExecutionEndpoint
  ( controlPlaneAdminActionAuthorityExecutionEndpointSuite
  )
where

import Crypto.Error (CryptoFailable (..))
import Crypto.PubKey.Ed25519 qualified as Ed25519
import Data.ByteArray qualified as ByteArray
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.Text (Text)
import Prodbox.ControlPlane.AdminActionAuthorityExecutionEndpoint
  ( AdminActionAuthorityCommand (..)
  , AdminActionAuthorityExecutionBoundary (..)
  , AdminActionAuthorityRequest (..)
  , AdminActionAuthorityResponse (..)
  , AdminActionEffectRepository (..)
  , AdminActionEffectSnapshot (..)
  , AdminActionEffectState
  , AdminLegacyDestinationBoundary (..)
  , AdminLegacyDestinationObservation (..)
  , AdminLegacyDestinationPublication (..)
  , serveAdminActionAuthorityExecutionRequest
  )
import Prodbox.ControlPlane.Codec (encodeControlPlaneRequest)
import Prodbox.Lifecycle.AdminAction.Authority
  ( AdminActionAuthorityRepository
  )
import Prodbox.Lifecycle.AdminAction.Protocol
  ( AdminActionPlan (..)
  , AdminLegacyBackendPlan (..)
  , AdminQuotaRequest (..)
  , SignedAdminActionPermit
  , adminActionJobNameFor
  , adminActionPermitBackupDigest
  , adminActionPermitSigningPayload
  , adminActionRunnerServiceAccount
  , adminLegacyAwsSesDestinationCoordinate
  , adminLegacyAwsSesSourceCoordinate
  , mkAdminActionBackupReceipt
  , mkAdminActionJobBinding
  , mkAdminActionPermitCore
  , mkSignedAdminActionPermit
  )
import Prodbox.Lifecycle.AdminAction.QuotaJournal
  ( QuotaAttemptIntent (..)
  , QuotaExternalObservation (..)
  )
import Prodbox.Lifecycle.Decommission.AuthorityExport
  ( AuthorityManifestSigner (..)
  )
import Prodbox.Lifecycle.Decommission.Manifest
  ( ManifestPublicKey
  , mkManifestPublicKey
  )
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros)
import TestSupport

controlPlaneAdminActionAuthorityExecutionEndpointSuite :: SuiteBuilder ()
controlPlaneAdminActionAuthorityExecutionEndpointSuite =
  describe "runner-only Admin Action Authority execution endpoint" $ do
    it "persists migration preparation before publishing and requires source-absence evidence" $ do
      (repository, stateRef) <- freshRepository
      preparedBeforePublish <- newIORef False
      publications <- newIORef (0 :: Int)
      let permit = permitFor migrationPlan
          boundary =
            executionBoundary 1 $ \plan operation sourceBytes -> do
              (_, durableState) <- readIORef stateRef
              writeIORef preparedBeforePublish (isPresent durableState)
              modifyIORef' publications (+ 1)
              plan `shouldBe` migrationBackendPlan
              operation `shouldBe` operationId
              sourceBytes `shouldBe` legacySource
              pure
                ( AdminLegacyDestinationPublished
                    legacySourceDigest
                    "authority-checkpoint/aws-ses/1"
                )
      stored <- serve boundary repository permit (PublishAdminLegacyMigration legacySource)
      stored
        `shouldBe` AdminActionAuthorityMigrationStored "authority-checkpoint/aws-ses/1"
      readIORef preparedBeforePublish `shouldReturn` True
      readIORef publications `shouldReturn` 1

      completed <-
        serve
          boundary
          repository
          permit
          (ConfirmAdminLegacySourceAbsent "source-absent-after-authority-readback")
      case completed of
        AdminActionAuthorityMigrationCompleted readBack ->
          show readBack `shouldContain` "source-absent-after-authority-readback"
        other -> expectationFailure ("expected migration completion, got " <> show other)

      observed <- serve boundary repository permit ObserveAdminLegacyMigration
      observed `shouldBe` completed

    it "rejects a source digest mismatch before publication" $ do
      (repository, _) <- freshRepository
      publications <- newIORef (0 :: Int)
      let boundary =
            executionBoundary 1 $ \_ _ _ -> do
              modifyIORef' publications (+ 1)
              pure (AdminLegacyDestinationPublicationUnavailable "must-not-run")
      response <-
        serve
          boundary
          repository
          (permitFor migrationPlan)
          (PublishAdminLegacyMigration "different-checkpoint")
      response
        `shouldBe` AdminActionAuthorityRefused "legacy-source-digest-mismatch"
      readIORef publications `shouldReturn` 0

    it "persists an exact quota attempt before returning dispatch authority" $ do
      (repository, stateRef) <- freshRepository
      let permit = permitFor quotaPlan
          boundary = executionBoundary 1 unusedPublication
          missing =
            QuotaExternalObservation
              { quotaExternalRequest = quotaRequest
              , quotaExternalCurrentValue = 5
              , quotaExternalHistory = []
              }
      dispatched <-
        serve boundary repository permit (AdvanceAdminQuotaJournal [missing])
      intent <- case dispatched of
        AdminActionAuthorityQuotaDispatch value -> pure value
        other -> expectationFailure ("expected quota dispatch, got " <> show other) >> error "unreachable"
      (_, durableState) <- readIORef stateRef
      durableState `shouldSatisfy` isPresent

      completed <-
        serve
          boundary
          repository
          permit
          ( RecordAdminQuotaProviderResponse
              (quotaAttemptIdentity intent)
              "aws-quota-request-1"
              "PENDING"
          )
      case completed of
        AdminActionAuthorityQuotaCompleted [item] ->
          show item `shouldContain` "aws-quota-request-1"
        other -> expectationFailure ("expected quota completion, got " <> show other)
      serve boundary repository permit ObserveAdminQuotaJournal
        `shouldReturn` completed

    it "fails closed on signer generation, Pod binding, and Authority binding drift" $ do
      (repository, stateRef) <- freshRepository
      let permit = permitFor quotaPlan
          command = AdvanceAdminQuotaJournal [quotaObservation]
      serve (executionBoundary 2 unusedPublication) repository permit command
        `shouldReturn` AdminActionAuthorityRefused "authority-signer-generation-mismatch"
      serveRequest
        (executionBoundary 1 unusedPublication)
        repository
        ((requestFor permit command) {adminAuthorityRequestPodUid = "other-pod-uid"})
        `shouldReturn` AdminActionAuthorityRefused "permit-operation-pod-binding-mismatch"

      let foreignRequest =
            quotaRequest
              { adminQuotaRequestAuthorityEndpoint = "http://other-authority:8600"
              }
          foreignPermit = permitFor (AdminReconcileQuotaPlanAction [foreignRequest])
      serve
        (executionBoundary 1 unusedPublication)
        repository
        foreignPermit
        ( AdvanceAdminQuotaJournal
            [ quotaObservation {quotaExternalRequest = foreignRequest}
            ]
        )
        `shouldReturn` AdminActionAuthorityRefused "quota-authority-binding-mismatch"
      (_, durableState) <- readIORef stateRef
      durableState `shouldBe` Nothing

migrationPlan :: AdminActionPlan
migrationPlan = AdminMigrateLegacyBackendPlanAction migrationBackendPlan

migrationBackendPlan :: AdminLegacyBackendPlan
migrationBackendPlan =
  AdminLegacyBackendPlan
    { adminLegacyAuthorityScope = authorityScope
    , adminLegacyAuthorityEndpoint = authorityEndpoint
    , adminLegacySourceCoordinate = adminLegacyAwsSesSourceCoordinate
    , adminLegacyDestinationCoordinate = adminLegacyAwsSesDestinationCoordinate
    , adminLegacySourceDigest = legacySourceDigest
    }

quotaPlan :: AdminActionPlan
quotaPlan = AdminReconcileQuotaPlanAction [quotaRequest]

quotaRequest :: AdminQuotaRequest
quotaRequest =
  AdminQuotaRequest
    { adminQuotaRequestAuthorityScope = authorityScope
    , adminQuotaRequestAuthorityEndpoint = authorityEndpoint
    , adminQuotaRequestServiceCode = "vpc"
    , adminQuotaRequestCode = "L-F678F1CE"
    , adminQuotaRequestRegion = "ca-central-1"
    , adminQuotaRequestDesiredValue = "10"
    }

quotaObservation :: QuotaExternalObservation
quotaObservation =
  QuotaExternalObservation
    { quotaExternalRequest = quotaRequest
    , quotaExternalCurrentValue = 5
    , quotaExternalHistory = []
    }

serve
  :: AdminActionAuthorityExecutionBoundary IO
  -> AdminActionEffectRepository IO Int
  -> SignedAdminActionPermit
  -> AdminActionAuthorityCommand
  -> IO AdminActionAuthorityResponse
serve boundary repository permit command =
  serveRequest boundary repository (requestFor permit command)

serveRequest
  :: AdminActionAuthorityExecutionBoundary IO
  -> AdminActionEffectRepository IO Int
  -> AdminActionAuthorityRequest
  -> IO AdminActionAuthorityResponse
serveRequest boundary repository request =
  serveAdminActionAuthorityExecutionRequest
    1048576
    boundary
    ( \candidateOperation ->
        if candidateOperation == operationId
          then Right repository
          else Left "unknown operation"
    )
    ( const
        ( Left "unused completion repository"
            :: Either Text (AdminActionAuthorityRepository IO Int)
        )
    )
    (encodeControlPlaneRequest request)

requestFor :: SignedAdminActionPermit -> AdminActionAuthorityCommand -> AdminActionAuthorityRequest
requestFor permit command =
  AdminActionAuthorityRequest
    { adminAuthorityRequestPermit = permit
    , adminAuthorityRequestOperationId = operationId
    , adminAuthorityRequestPodName = podName
    , adminAuthorityRequestPodUid = podUid
    , adminAuthorityRequestCommand = command
    }

executionBoundary
  :: Int
  -> (AdminLegacyBackendPlan -> Text -> ByteString -> IO AdminLegacyDestinationPublication)
  -> AdminActionAuthorityExecutionBoundary IO
executionBoundary signerGeneration publication =
  AdminActionAuthorityExecutionBoundary
    { adminExecutionAuthoritySigner =
        AuthorityManifestSigner
          { readAuthorityManifestPublicKey = pure (Right (fromIntegral signerGeneration, publicKey))
          , signAuthorityManifestPayload = \_ -> pure (Left "signing is not used")
          }
    , adminExecutionCurrentTime = pure (Right (authorityTimeFromMicros 2000))
    , adminExecutionLocalAuthorityScope = authorityScope
    , adminExecutionLocalAuthorityEndpoint = authorityEndpoint
    , adminExecutionLegacyDestination =
        AdminLegacyDestinationBoundary
          { observeAdminLegacyDestination = \_ -> pure AdminLegacyDestinationMissing
          , publishAdminLegacySource = publication
          }
    }

unusedPublication
  :: AdminLegacyBackendPlan
  -> Text
  -> ByteString
  -> IO AdminLegacyDestinationPublication
unusedPublication _ _ _ =
  pure (AdminLegacyDestinationPublicationUnavailable "unused")

freshRepository
  :: IO
       ( AdminActionEffectRepository IO Int
       , IORef (Int, Maybe AdminActionEffectState)
       )
freshRepository = do
  stateRef <- newIORef (0, Nothing)
  let repository =
        AdminActionEffectRepository
          { readAdminActionEffect = do
              (revision, state) <- readIORef stateRef
              pure
                ( Right
                    AdminActionEffectSnapshot
                      { adminActionEffectRevision = fmap (const revision) state
                      , adminActionEffectObservedState = state
                      }
                )
          , compareAndSwapAdminActionEffect = \expected next -> do
              (revision, current) <- readIORef stateRef
              let actual = fmap (const revision) current
              if expected == actual
                then writeIORef stateRef (revision + 1, Just next) >> pure (Right ())
                else pure (Left "fixture CAS conflict")
          }
  pure (repository, stateRef)

permitFor :: AdminActionPlan -> SignedAdminActionPermit
permitFor plan =
  acceptedPure $ do
    core <-
      mkAdminActionPermitCore
        operationId
        authorityScope
        authorityEndpoint
        plan
        "admin-permit-nonce"
        (authorityTimeFromMicros 10000)
        imageDigest
    backup <-
      mkAdminActionBackupReceipt
        core
        "authority-backup/admin-operation"
        (adminActionPermitBackupDigest core)
        "checkpoint-version-1"
    binding <-
      mkAdminActionJobBinding
        core
        (adminActionJobNameFor core)
        "job-uid-1"
        podName
        podUid
        imageDigest
        adminActionRunnerServiceAccount
        "service-account-uid-1"
        (authorityTimeFromMicros 1000)
    let signature =
          ByteArray.convert
            ( Ed25519.sign
                privateKey
                ed25519PublicKey
                (adminActionPermitSigningPayload 1 core backup binding)
            )
    mkSignedAdminActionPermit 1 core backup binding signature

privateKey :: Ed25519.SecretKey
privateKey = case Ed25519.secretKey (ByteString.pack [0 .. 31]) of
  CryptoPassed value -> value
  CryptoFailed err -> error (show err)

ed25519PublicKey :: Ed25519.PublicKey
ed25519PublicKey = Ed25519.toPublic privateKey

publicKey :: ManifestPublicKey
publicKey =
  acceptedPure (mkManifestPublicKey (ByteArray.convert ed25519PublicKey))

operationId :: Text
operationId = "admin-operation-1"

authorityScope :: Text
authorityScope = "home"

authorityEndpoint :: Text
authorityEndpoint = "http://lifecycle-authority:8600"

podName :: Text
podName = "admin-action-pod-1"

podUid :: Text
podUid = "admin-action-pod-uid-1"

imageDigest :: Text
imageDigest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

legacySource :: ByteString
legacySource = "legacy-checkpoint"

legacySourceDigest :: Text
legacySourceDigest = "6a92d259624feaa2b7fdd850423cc1499fa95febd92df55dc8bc2cc1911f92e3"

acceptedPure :: (Show err) => Either err value -> value
acceptedPure result = case result of
  Left err -> error (show err)
  Right value -> value

isPresent :: Maybe value -> Bool
isPresent value = case value of
  Just _ -> True
  Nothing -> False
