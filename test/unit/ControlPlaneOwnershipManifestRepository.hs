{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module ControlPlaneOwnershipManifestRepository
  ( controlPlaneOwnershipManifestRepositorySuite
  )
where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (isLeft)
import Data.IORef
  ( IORef
  , atomicModifyIORef'
  , modifyIORef'
  , newIORef
  , readIORef
  )
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientProviders (..)
  , AuthenticatedTransportBounds
  , mkAuthenticatedClientTransport
  , mkAuthenticatedTransportBounds
  )
import Prodbox.ControlPlane.AuthenticationRegistry
  ( callerMayCallRoute
  , trustedCallersForRoute
  )
import Prodbox.ControlPlane.CallerPrincipal
  ( CallerPrincipal (CallerOperatorCli, CallerService, CallerTestHarness)
  )
import Prodbox.ControlPlane.Client
  ( controlPlaneClientWithTransport
  , mkLifecycleAuthorityEndpoint
  )
import Prodbox.ControlPlane.Codec
  ( encodeControlPlaneRequest
  , encodeControlPlaneResponse
  )
import Prodbox.ControlPlane.Coordinate (AuthorityScope, mkAuthorityScope)
import Prodbox.ControlPlane.OwnershipManifestEndpoint
import Prodbox.ControlPlane.OwnershipManifestRepository
import Prodbox.ControlPlane.OwnershipManifestTransportClient
  ( lifecycleAuthorityOwnershipManifestAuthenticatedClient
  )
import Prodbox.ControlPlane.RequestAuthentication
  ( RequestNonce
  , RequestSigner
  , localRequestSigningCapability
  , mkRequestNonce
  , mkRequestSigner
  , mkSigningKeyGeneration
  )
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (LifecycleOwnershipManifest)
  )
import Prodbox.Http.ReplyStatus (ReplyStatus (..), replyStatusCode)
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.CheckpointAuthority
  ( LongLivedCheckpointAuthority
  , ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBCodec (..)
  , ModelBObjectVersion
  , ModelBObservation (..)
  , StoreLifetime (ClusterRetained)
  , mkLongLivedCheckpointAuthority
  , mkModelBObjectVersion
  , modelBObjectLogicalName
  )
import Prodbox.Lifecycle.Lease (AuthorityTime, authorityTimeFromMicros)
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.Observation
import Prodbox.Lifecycle.Teardown.OwnershipManifest
import Prodbox.Lifecycle.Teardown.Registry
  ( RegisteredIdentity
  , lifecycleRegistryRevision
  , lookupRegisteredIdentity
  , registeredIdentityCoordinateDigest
  )
import Prodbox.Runtime.Role
  ( RuntimeRole (LifecycleAuthorityRuntime, ProviderWorkerRuntime)
  )
import TestSupport

controlPlaneOwnershipManifestRepositorySuite :: SuiteBuilder ()
controlPlaneOwnershipManifestRepositorySuite =
  describe "Authority write-ahead ownership manifest repository" $ do
    it "binds a canonical immutable slot to every durable generation dimension" $ do
      let prepared = mustRight (prepareAuthorityOwnershipManifestWrite fixtureWrite)
          identity = authorityOwnershipManifestWriteIdentity prepared
          otherPrepared = mustRight (prepareAuthorityOwnershipManifestWrite otherWrite)
          otherIdentity = authorityOwnershipManifestWriteIdentity otherPrepared
      ownershipManifestAuthorityStackKey identity `shouldBe` AwsTestKey
      ownershipManifestAuthorityCoordinateDigest identity
        `shouldBe` registeredIdentityCoordinateDigest (mustIdentity AwsTestKey)
      ownershipManifestAuthoritySurface identity `shouldBe` Cascade
      ownershipManifestAuthorityRunScope identity
        `shouldBe` evidenceDurableRunScope fixtureCreationScope
      ownershipManifestAuthorityFoundation identity
        `shouldBe` evidenceLinuxRke2Foundation fixtureCreationScope
      ownershipManifestAuthorityAwsScope identity `shouldBe` fixtureAwsScope
      ownershipManifestAuthoritySubmissionKey identity
        `shouldSatisfy` Text.isPrefixOf "ownership-manifest-v1-"
      Text.length (ownershipManifestAuthoritySubmissionKey identity) `shouldBe` 86
      ownershipManifestAuthoritySubmissionKey otherIdentity
        `shouldNotBe` ownershipManifestAuthoritySubmissionKey identity
      ByteString.length (authorityOwnershipManifestWriteBytes prepared)
        `shouldSatisfy` (<= maximumDurableWriteAheadOwnershipManifestBytes)
      encodeModelBValue
        ownershipManifestModelBCodec
        (authorityOwnershipManifestWriteBytes prepared)
        `shouldBe` Right (authorityOwnershipManifestWriteBytes prepared)

    it "round-trips canonical identities and confirms only exact repository-owned client readback" $ do
      durable <- newDurableModelB False
      let prepared = mustRight (prepareAuthorityOwnershipManifestWrite fixtureWrite)
          identity = authorityOwnershipManifestWriteIdentity prepared
          identityBytes = encodeOwnershipManifestAuthorityIdentity identity
          writeBytes = authorityOwnershipManifestWriteBytes prepared
          client = lifecycleAuthorityOwnershipManifestClient (durableRepository durable)
      ByteString.length identityBytes
        `shouldSatisfy` (<= maximumOwnershipManifestAuthorityIdentityBytes)
      decodeOwnershipManifestAuthorityIdentity identityBytes `shouldBe` Right identity
      decodeOwnershipManifestAuthorityIdentity (ByteString.snoc identityBytes 0)
        `shouldSatisfy` isLeft
      decodeOwnershipManifestAuthorityIdentity
        (ByteString.replicate (maximumOwnershipManifestAuthorityIdentityBytes + 1) 0)
        `shouldSatisfy` isLeft
      confirmAuthorityOwnershipManifestWriteBytes identity writeBytes
        `shouldBe` Right prepared

      let otherIdentity =
            authorityOwnershipManifestWriteIdentity
              (mustRight (prepareAuthorityOwnershipManifestWrite otherWrite))
      confirmAuthorityOwnershipManifestWriteBytes otherIdentity writeBytes
        `shouldSatisfy` isWriteIdentityMismatch

      attemptOwnershipManifestWriteAheadCommit client fixtureWrite
        `shouldReturn` Right OwnershipManifestCommitCreated
      attemptOwnershipManifestWriteAheadCommit client fixtureWrite
        `shouldReturn` Right OwnershipManifestCommitExactReplay
      recovered <-
        readBackOwnershipManifestDecisionByIdentity
          client
          fixtureTarget
          identity
      assertObservationResult
        fixtureCleanupScope
        (OwnershipManifestPresent fixtureObservedVersion)
        recovered

      confirmOwnershipManifestDecisionReadBack
        fixtureTarget
        otherIdentity
        OwnershipManifestAuthorityReadBackMissing
        `shouldSatisfy` isIdentityMismatch
      assertDecisionClass
        ExpectAbsent
        ( confirmOwnershipManifestDecisionReadBack
            fixtureTarget
            identity
            OwnershipManifestAuthorityReadBackMissing
        )
      assertDecisionClass
        ExpectPartial
        ( confirmOwnershipManifestDecisionReadBack
            fixtureTarget
            identity
            ( OwnershipManifestAuthorityReadBackPartial
                (ObservationFailure (Text.replicate 2048 "p") :| [])
            )
        )
      assertDecisionClass
        ExpectUnobservable
        ( confirmOwnershipManifestDecisionReadBack
            fixtureTarget
            identity
            (OwnershipManifestAuthorityReadBackCorrupt "corrupt")
        )
      assertDecisionClass
        ExpectPresent
        ( confirmOwnershipManifestDecisionReadBack
            fixtureTarget
            identity
            ( OwnershipManifestAuthorityReadBackPresent
                fixtureModelBVersion
                writeBytes
            )
        )

    it "recovers response loss, exactly replays, and permits a later generation" $ do
      durable <- newDurableModelB True
      let repository = durableRepository durable
      attempted <- commitOwnershipManifestWriteAheadAttempt repository fixtureWrite
      attempted `shouldSatisfy` isResponseLost
      readIORef (durableWrites durable) `shouldReturn` 1

      recovered <-
        independentlyReadBackOwnershipManifestDecisionEvidence
          (durableRepository durable)
          fixtureTarget
      assertObservationResult
        fixtureCleanupScope
        (OwnershipManifestPresent fixtureObservedVersion)
        recovered

      replayed <- commitOwnershipManifestWriteAheadAttempt repository fixtureWrite
      replayed `shouldBe` Right OwnershipManifestCommitExactReplay

      nextGeneration <- commitOwnershipManifestWriteAheadAttempt repository otherWrite
      nextGeneration `shouldBe` Right OwnershipManifestCommitCreated
      readIORef (durableWrites durable) `shouldReturn` 2

      recoveredOther <-
        independentlyReadBackOwnershipManifestDecisionEvidence
          (durableRepository durable)
          otherTarget
      assertObservationResult
        otherCleanupScope
        (OwnershipManifestPresent fixtureObservedVersion)
        recoveredOther

    it "maps the full exact Authority read-back algebra without laundering absence" $ do
      let canonicalBytes =
            authorityOwnershipManifestWriteBytes
              (mustRight (prepareAuthorityOwnershipManifestWrite fixtureWrite))
          cases =
            [ (OwnershipManifestAuthorityReadBackMissing, ExpectAbsent)
            ,
              ( OwnershipManifestAuthorityReadBackPartial
                  (ObservationFailure (Text.replicate 2048 "p") :| [])
              , ExpectPartial
              )
            , (OwnershipManifestAuthorityReadBackCorrupt "authentication failed", ExpectUnobservable)
            ,
              ( OwnershipManifestAuthorityReadBackUnobservable
                  (ObservationFailure "Authority unavailable")
              , ExpectUnobservable
              )
            , (OwnershipManifestAuthorityReadBackUnbounded 2 1, ExpectUnobservable)
            ,
              ( OwnershipManifestAuthorityReadBackPresent
                  fixtureModelBVersion
                  (ByteString.singleton 0)
              , ExpectUnobservable
              )
            ,
              ( OwnershipManifestAuthorityReadBackPresent
                  fixtureModelBVersion
                  canonicalBytes
              , ExpectPresent
              )
            ]
      forM_ cases $ \(observation, expected) -> do
        result <-
          independentlyReadBackOwnershipManifestDecisionEvidence
            (fixedRepository observation)
            fixtureTarget
        assertDecisionClass expected result

    it "rejects cross-generation canonical payload substitution and invalid target identity" $ do
      let otherBytes =
            authorityOwnershipManifestWriteBytes
              (mustRight (prepareAuthorityOwnershipManifestWrite otherWrite))
      independentlyReadBackOwnershipManifestDecisionEvidence
        ( fixedRepository
            ( OwnershipManifestAuthorityReadBackPresent
                fixtureModelBVersion
                otherBytes
            )
        )
        fixtureTarget
        `shouldReturnSatisfying` isIdentityMismatch

      let invalidTargetResult =
            mkOwnershipManifestTarget
              CascadeSurface
              AwsTestKey
              ( scopeFor
                  "run/manifest-1"
                  "foundation/home"
                  "not a region"
                  ReconcileDesiredAbsent
              )
      case invalidTargetResult of
        Left err -> expectationFailure (show err)
        Right invalidTarget ->
          independentlyReadBackOwnershipManifestDecisionEvidence
            (fixedRepository OwnershipManifestAuthorityReadBackMissing)
            invalidTarget
            `shouldReturnSatisfying` isIdentityInvalid

    it "serves exact commit and raw independent Authority readback" $ do
      durable <- newDurableModelB False
      let repository = durableRepository durable
          prepared = mustRight (prepareAuthorityOwnershipManifestWrite fixtureWrite)
          identity = authorityOwnershipManifestWriteIdentity prepared
      committed <-
        serveOwnershipManifestEndpointRequest
          repository
          ( encodeControlPlaneRequest
              (ownershipManifestCommitWireRequest prepared)
          )
      ownershipManifestEndpointStatus committed `shouldBe` ReplyOk
      confirmOwnershipManifestCommitResponse
        identity
        ( mustRight
            ( decodeOwnershipManifestEndpointResponse
                (ownershipManifestEndpointBody committed)
            )
        )
        `shouldBe` Right OwnershipManifestCommitCreated

      readBack <-
        serveOwnershipManifestEndpointRequest
          repository
          ( encodeControlPlaneRequest
              (ownershipManifestReadBackWireRequest identity)
          )
      ownershipManifestEndpointStatus readBack `shouldBe` ReplyOk
      confirmOwnershipManifestReadBackResponse
        identity
        ( mustRight
            ( decodeOwnershipManifestEndpointResponse
                (ownershipManifestEndpointBody readBack)
            )
        )
        `shouldBe` Right
          ( OwnershipManifestAuthorityReadBackPresent
              fixtureModelBVersion
              (authorityOwnershipManifestWriteBytes prepared)
          )

    it "refuses malformed, oversized, wrong-version, and invalid-shape requests before storage" $ do
      durable <- newDurableModelB False
      let repository = durableRepository durable
          prepared = mustRight (prepareAuthorityOwnershipManifestWrite fixtureWrite)
          identity = authorityOwnershipManifestWriteIdentity prepared
          wrongVersion =
            (ownershipManifestReadBackWireRequest identity)
              { ownershipManifestWireRequestVersion =
                  ownershipManifestEndpointFormatVersion + 1
              }
          unexpectedPayload =
            (ownershipManifestReadBackWireRequest identity)
              { ownershipManifestWireRequestManifestBytes =
                  authorityOwnershipManifestWriteBytes prepared
              }
          attempts =
            [
              ( LazyByteString.replicate
                  (fromIntegral ownershipManifestEndpointMaximumBytes + 1)
                  0
              , OwnershipManifestWireRequestTooLarge
              )
            ,
              ( encodeControlPlaneRequest wrongVersion
              , OwnershipManifestWireRequestUnsupportedVersion
              )
            ,
              ( encodeControlPlaneRequest unexpectedPayload
              , OwnershipManifestWireUnexpectedPayload
              )
            , (LazyByteString.singleton 0, OwnershipManifestWireRequestInvalid)
            ]
      forM_ attempts $ \(request, expectedRefusal) -> do
        result <- serveOwnershipManifestEndpointRequest repository request
        ownershipManifestEndpointStatus result `shouldBe` ReplyBadRequest
        decodeOwnershipManifestEndpointResponse
          (ownershipManifestEndpointBody result)
          `shouldBe` Right
            ( OwnershipManifestWireRefused
                ownershipManifestEndpointFormatVersion
                expectedRefusal
            )
      readIORef (durableWrites durable) `shouldReturn` 0

    it "maps only authenticated exact Missing to Absent and preserves every failure class" $ do
      let prepared = mustRight (prepareAuthorityOwnershipManifestWrite fixtureWrite)
          identity = authorityOwnershipManifestWriteIdentity prepared
          identityBytes = encodeOwnershipManifestAuthorityIdentity identity
      commitClient <-
        authenticatedOwnershipClientFor
          ( OwnershipManifestWireCommitResult
              ownershipManifestEndpointFormatVersion
              identityBytes
              OwnershipManifestWireCommitCreated
          )
      attemptOwnershipManifestWriteAheadCommit commitClient fixtureWrite
        `shouldReturn` Right OwnershipManifestCommitCreated

      missingClient <-
        authenticatedOwnershipClientFor
          ( OwnershipManifestWireReadBackMissing
              ownershipManifestEndpointFormatVersion
              identityBytes
          )
      missing <-
        readBackOwnershipManifestDecisionByIdentity
          missingClient
          fixtureTarget
          identity
      assertDecisionClass ExpectAbsent missing

      partialClient <-
        authenticatedOwnershipClientFor
          ( OwnershipManifestWireReadBackPartial
              ownershipManifestEndpointFormatVersion
              identityBytes
              ["partial"]
          )
      partial <-
        readBackOwnershipManifestDecisionByIdentity
          partialClient
          fixtureTarget
          identity
      assertDecisionClass ExpectPartial partial

      corruptClient <-
        authenticatedOwnershipClientFor
          ( OwnershipManifestWireReadBackCorrupt
              ownershipManifestEndpointFormatVersion
              identityBytes
              "corrupt"
          )
      corrupt <-
        readBackOwnershipManifestDecisionByIdentity
          corruptClient
          fixtureTarget
          identity
      assertDecisionClass ExpectUnobservable corrupt

      unavailableClient <-
        authenticatedOwnershipClientFor
          ( OwnershipManifestWireUnavailable
              ownershipManifestEndpointFormatVersion
              (OwnershipManifestWireEndpointUnavailable "transport unavailable")
          )
      readBackOwnershipManifestDecisionByIdentity
        unavailableClient
        fixtureTarget
        identity
        `shouldReturnSatisfying` isIdentityUnobservable

      let otherIdentity =
            authorityOwnershipManifestWriteIdentity
              (mustRight (prepareAuthorityOwnershipManifestWrite otherWrite))
      mismatchedClient <-
        authenticatedOwnershipClientFor
          ( OwnershipManifestWireReadBackMissing
              ownershipManifestEndpointFormatVersion
              (encodeOwnershipManifestAuthorityIdentity otherIdentity)
          )
      readBackOwnershipManifestDecisionByIdentity
        mismatchedClient
        fixtureTarget
        identity
        `shouldReturnSatisfying` isIdentityMismatch

      trustedCallersForRoute LifecycleOwnershipManifest
        `shouldBe` [ CallerOperatorCli
                   , CallerTestHarness
                   , CallerService LifecycleAuthorityRuntime
                   ]
      callerMayCallRoute
        (CallerService LifecycleAuthorityRuntime)
        LifecycleOwnershipManifest
        `shouldBe` True
      callerMayCallRoute
        (CallerService ProviderWorkerRuntime)
        LifecycleOwnershipManifest
        `shouldBe` False

    it "checks the ownership protocol version on every response and cross-kind arm" $ do
      let prepared = mustRight (prepareAuthorityOwnershipManifestWrite fixtureWrite)
          identity = authorityOwnershipManifestWriteIdentity prepared
          identityBytes = encodeOwnershipManifestAuthorityIdentity identity
          manifestBytes = authorityOwnershipManifestWriteBytes prepared
          wrongVersion = ownershipManifestEndpointFormatVersion + 1
          responses =
            [ OwnershipManifestWireCommitResult
                wrongVersion
                identityBytes
                OwnershipManifestWireCommitCreated
            , OwnershipManifestWireReadBackPresent
                wrongVersion
                identityBytes
                "manifest-object-v1"
                manifestBytes
            , OwnershipManifestWireReadBackMissing wrongVersion identityBytes
            , OwnershipManifestWireReadBackPartial wrongVersion identityBytes ["partial"]
            , OwnershipManifestWireReadBackCorrupt wrongVersion identityBytes "corrupt"
            , OwnershipManifestWireReadBackUnobservable
                wrongVersion
                identityBytes
                "unobservable"
            , OwnershipManifestWireReadBackUnbounded wrongVersion identityBytes 2 1
            , OwnershipManifestWireRefused
                wrongVersion
                OwnershipManifestWireRequestInvalid
            , OwnershipManifestWireUnavailable
                wrongVersion
                (OwnershipManifestWireEndpointUnavailable "unavailable")
            ]
      forM_ responses $ \response -> do
        confirmOwnershipManifestCommitResponse identity response
          `shouldSatisfy` isEndpointVersionMismatch
        confirmOwnershipManifestReadBackResponse identity response
          `shouldSatisfy` isEndpointVersionMismatch

    it "keeps positive-complete minting behind the future opaque creation admission seam" $ do
      repositorySource <-
        readFile "src/Prodbox/ControlPlane/OwnershipManifestRepository.hs"
      repositorySource `shouldNotContain` "ValidatedCompleteOwnershipManifest"
      repositorySource
        `shouldNotContain` "bindObservedDurableWriteAheadOwnershipManifestForCleanup"
      repositorySource
        `shouldNotContain` "observedDurableWriteAheadOwnershipManifest"
      repositorySource `shouldNotContain` "KUBECONFIG"
      repositorySource `shouldNotContain` "publicIp"

      publicFacade <-
        readFile "src/Prodbox/Lifecycle/Teardown/OwnershipManifest.hs"
      publicFacade `shouldNotContain` "decodeDurableWriteAheadOwnershipManifest"
      let prepared = mustRight (prepareAuthorityOwnershipManifestWrite fixtureWrite)
          bytes = authorityOwnershipManifestWriteBytes prepared
      forM_
        [ "sensitive-bearer"
        , "https://sensitive.eks.amazonaws.com"
        , "sensitive-ca-plaintext"
        , "KUBECONFIG"
        ]
        ( \forbidden ->
            bytes
              `shouldSatisfy` (not . ByteString.isInfixOf (TextEncoding.encodeUtf8 forbidden))
        )

      decodeModelBValue ownershipManifestModelBCodec ByteString.empty
        `shouldSatisfy` isLeft
      decodeModelBValue
        ownershipManifestModelBCodec
        (ByteString.replicate (maximumDurableWriteAheadOwnershipManifestBytes + 1) 0)
        `shouldSatisfy` isLeft
      decodeModelBValue
        ownershipManifestModelBCodec
        (ByteString.snoc bytes 0)
        `shouldSatisfy` isLeft

fixtureWrite
  , otherWrite
    :: OwnershipManifestWrite 'WriteAheadOwnership 'Cascade
fixtureWrite = writeFor fixtureCreationScope
otherWrite = writeFor otherCreationScope

writeFor
  :: ObservationEvidenceScope
  -> OwnershipManifestWrite 'WriteAheadOwnership 'Cascade
writeFor scope =
  initialWriteAheadManifestWrite
    (mustRight (mkWriteAheadManifestIntent CascadeSurface AwsTestKey scope))

fixtureTarget, otherTarget :: OwnershipManifestTarget 'Cascade
fixtureTarget =
  mustRight (mkOwnershipManifestTarget CascadeSurface AwsTestKey fixtureCleanupScope)
otherTarget =
  mustRight (mkOwnershipManifestTarget CascadeSurface AwsTestKey otherCleanupScope)

fixtureCreationScope
  , fixtureCleanupScope
  , otherCreationScope
  , otherCleanupScope
    :: ObservationEvidenceScope
fixtureCreationScope =
  scopeFor
    "run/manifest-1"
    "foundation/home"
    (fixtureAwsRegion FixtureCaCentral1)
    ReconcileDesiredPresent
fixtureCleanupScope =
  scopeFor
    "run/manifest-1"
    "foundation/home"
    (fixtureAwsRegion FixtureCaCentral1)
    ReconcileDesiredAbsent
otherCreationScope =
  scopeFor
    "run/manifest-2"
    "foundation/home"
    (fixtureAwsRegion FixtureCaCentral1)
    ReconcileDesiredPresent
otherCleanupScope =
  scopeFor
    "run/manifest-2"
    "foundation/home"
    (fixtureAwsRegion FixtureCaCentral1)
    ReconcileDesiredAbsent

scopeFor :: Text -> Text -> Text -> LifecycleOperation -> ObservationEvidenceScope
scopeFor runScope foundation region operation =
  mkObservationEvidenceScope
    Cascade
    lifecycleRegistryRevision
    (DurableObservationRunScope runScope)
    (LinuxRke2FoundationId foundation)
    (Just (AwsScope (AwsAccountId "111122223333") (AwsRegion region)))
    operation

fixtureAwsScope :: AwsScope
fixtureAwsScope = AwsScope (AwsAccountId "111122223333") (AwsRegion (fixtureAwsRegion FixtureCaCentral1))

data DurableModelB = DurableModelB
  { durableAdapter :: !(ModelBCasAdapter 'ClusterRetained IO ByteString)
  , durableWrites :: !(IORef Int)
  }

newDurableModelB :: Bool -> IO DurableModelB
newDurableModelB loseFirstResponse = do
  valuesRef <- newIORef Map.empty
  writesRef <- newIORef 0
  loseRef <- newIORef loseFirstResponse
  let compareAndSwap request = case request of
        ModelBInitialize coordinate bytes -> do
          let key = modelBObjectLogicalName coordinate
          values <- readIORef valuesRef
          case Map.lookup key values of
            Just (version, existing) ->
              pure (ModelBCasConflict (ModelBObserved version existing))
            Nothing -> do
              modifyIORef'
                valuesRef
                (Map.insert key (fixtureModelBVersion, bytes))
              modifyIORef' writesRef (+ 1)
              lose <- atomicModifyIORef' loseRef (False,)
              pure $
                if lose
                  then ModelBCasUnobservable "response lost after apply"
                  else ModelBCasApplied fixtureModelBVersion bytes
        ModelBReplace {} -> unexpected "replace"
        ModelBInitializeGuarded {} -> unexpected "guarded initialize"
        ModelBReplaceGuarded {} -> unexpected "guarded replace"
      adapter =
        ModelBCasAdapter
          { modelBObserve = \coordinate -> do
              values <- readIORef valuesRef
              pure $ case Map.lookup (modelBObjectLogicalName coordinate) values of
                Nothing -> ModelBMissing
                Just (version, bytes) -> ModelBObserved version bytes
          , modelBCompareAndSwap = compareAndSwap
          }
  pure (DurableModelB adapter writesRef)
 where
  unexpected name = pure (ModelBCasUnobservable ("unexpected " <> name))

durableRepository :: DurableModelB -> OwnershipManifestRepository IO
durableRepository durable =
  modelBOwnershipManifestRepository fixtureAuthority (durableAdapter durable)

fixedRepository
  :: OwnershipManifestAuthorityReadBack -> OwnershipManifestRepository IO
fixedRepository observation =
  OwnershipManifestRepository
    { createOrReplayOwnershipManifest =
        const (pure OwnershipManifestCommitExactReplay)
    , independentlyReadBackOwnershipManifest = const (pure observation)
    }

fixtureAuthority :: LongLivedCheckpointAuthority
fixtureAuthority =
  mustRight
    ( mkLongLivedCheckpointAuthority
        "home-linux-rke2"
        "prodbox-authority"
        "authority"
        "secret/lifecycle"
    )

fixtureModelBVersion :: ModelBObjectVersion
fixtureModelBVersion = mustRight (mkModelBObjectVersion "manifest-object-v1")

fixtureObservedVersion :: OwnershipManifestVersion
fixtureObservedVersion = OwnershipManifestVersion "manifest-object-v1"

authenticatedOwnershipClientFor
  :: OwnershipManifestWireResponse
  -> IO (OwnershipManifestClient IO)
authenticatedOwnershipClientFor response = do
  endpoint <-
    mustRightIO
      (mkLifecycleAuthorityEndpoint "http://lifecycle-authority:8600")
  rawClient <-
    mustRightIO
      ( controlPlaneClientWithTransport
          ownershipManifestEndpointResponseMaximumBytes
          endpoint
          ( \method _ url _ -> do
              method `shouldBe` "POST"
              url
                `shouldBe` "http://lifecycle-authority:8600/v1/authority/ownership-manifest"
              pure
                ( Right
                    ( replyStatusCode
                        (ownershipManifestWireResponseStatus response)
                    , LazyByteString.toStrict
                        (encodeControlPlaneResponse response)
                    )
                )
          )
      )
  pure
    ( lifecycleAuthorityOwnershipManifestAuthenticatedClient
        ( mkAuthenticatedClientTransport
            ownershipTransportBounds
            ownershipClientProviders
            rawClient
        )
    )

ownershipTransportBounds :: AuthenticatedTransportBounds
ownershipTransportBounds =
  mustRight (mkAuthenticatedTransportBounds (256 * 1024) 256 (250 * 1024))

ownershipClientProviders :: AuthenticatedClientProviders IO
ownershipClientProviders =
  AuthenticatedClientProviders
    { provideAuthenticatedClientSigner =
        pure (Right (localRequestSigningCapability ownershipRequestSigner))
    , provideAuthenticatedClientScope = pure (Right ownershipAuthorityScope)
    , provideAuthenticatedClientEpoch = pure (Right authorityEpochGenesis)
    , provideAuthenticatedClientDeadline = pure (Right ownershipDeadline)
    , provideAuthenticatedClientNonce = pure (Right ownershipRequestNonce)
    }

ownershipRequestSigner :: RequestSigner
ownershipRequestSigner =
  mustRight
    ( mkRequestSigner
        (CallerService LifecycleAuthorityRuntime)
        (mustRight (mkSigningKeyGeneration 1))
        (ByteString.pack [0 .. 31])
    )

ownershipRequestNonce :: RequestNonce
ownershipRequestNonce = mustRight (mkRequestNonce (ByteString.pack [32 .. 47]))

ownershipAuthorityScope :: AuthorityScope
ownershipAuthorityScope = mustRight (mkAuthorityScope "cluster-a")

ownershipDeadline :: AuthorityTime
ownershipDeadline = authorityTimeFromMicros 2000

data ExpectedDecisionClass
  = ExpectAbsent
  | ExpectPartial
  | ExpectUnobservable
  | ExpectPresent

assertDecisionClass
  :: ExpectedDecisionClass
  -> Either OwnershipManifestRepositoryError OwnershipManifestDecisionEvidence
  -> Expectation
assertDecisionClass expected result = case (expected, fmap ownershipManifestDecisionView result) of
  (ExpectAbsent, Right (OwnershipManifestDecisionObservation observation)) ->
    ownershipManifestResult observation `shouldBe` OwnershipManifestAbsent
  (ExpectPartial, Right (OwnershipManifestDecisionObservation observation)) ->
    case ownershipManifestResult observation of
      OwnershipManifestPartial (ObservationFailure detail :| []) ->
        Text.length detail
          `shouldSatisfy` \detailLength ->
            detailLength > 0 && detailLength <= 1024
      other -> expectationFailure ("expected bounded partial, got " <> show other)
  (ExpectUnobservable, Right (OwnershipManifestDecisionObservation observation)) ->
    case ownershipManifestResult observation of
      OwnershipManifestUnobservable _ -> pure ()
      other -> expectationFailure ("expected unobservable, got " <> show other)
  (ExpectPresent, Right (OwnershipManifestDecisionObservation observation)) ->
    ownershipManifestResult observation
      `shouldBe` OwnershipManifestPresent fixtureObservedVersion
  (_, Right OwnershipManifestDecisionComplete {}) ->
    expectationFailure "durable bytes laundered a complete ownership proof"
  (_, Left err) -> expectationFailure ("unexpected repository error: " <> show err)

assertObservationResult
  :: ObservationEvidenceScope
  -> OwnershipManifestResult
  -> Either OwnershipManifestRepositoryError OwnershipManifestDecisionEvidence
  -> Expectation
assertObservationResult expectedScope expected result = case fmap ownershipManifestDecisionView result of
  Left err -> expectationFailure (show err)
  Right (OwnershipManifestDecisionObservation observation) -> do
    ownershipManifestStackKey observation `shouldBe` AwsTestKey
    ownershipManifestEvidenceScope observation `shouldBe` expectedScope
    ownershipManifestResult observation `shouldBe` expected
  Right OwnershipManifestDecisionComplete {} ->
    expectationFailure "repository minted a complete ownership proof"

isResponseLost
  :: Either OwnershipManifestRepositoryError OwnershipManifestCommitResult -> Bool
isResponseLost result = case result of
  Right OwnershipManifestCommitResponseLost {} -> True
  _ -> False

isIdentityMismatch
  :: Either OwnershipManifestRepositoryError OwnershipManifestDecisionEvidence -> Bool
isIdentityMismatch result = case result of
  Left OwnershipManifestRepositoryIdentityMismatch {} -> True
  _ -> False

isWriteIdentityMismatch
  :: Either OwnershipManifestRepositoryError AuthorityOwnershipManifestWrite -> Bool
isWriteIdentityMismatch result = case result of
  Left OwnershipManifestRepositoryIdentityMismatch {} -> True
  _ -> False

isIdentityInvalid
  :: Either OwnershipManifestRepositoryError OwnershipManifestDecisionEvidence -> Bool
isIdentityInvalid result = case result of
  Left OwnershipManifestRepositoryIdentityInvalid {} -> True
  _ -> False

isIdentityUnobservable
  :: Either OwnershipManifestRepositoryError OwnershipManifestDecisionEvidence -> Bool
isIdentityUnobservable result = case result of
  Left OwnershipManifestRepositoryUnobservable {} -> True
  _ -> False

isEndpointVersionMismatch
  :: Either OwnershipManifestEndpointResponseError value -> Bool
isEndpointVersionMismatch result = case result of
  Left OwnershipManifestEndpointResponseVersionMismatch {} -> True
  _ -> False

shouldReturnSatisfying :: IO value -> (value -> Bool) -> Expectation
shouldReturnSatisfying action predicate = do
  value <- action
  value `shouldSatisfy` predicate

mustIdentity :: RegisteredResourceKey -> RegisteredIdentity
mustIdentity key = case lookupRegisteredIdentity key of
  Nothing -> error ("missing registered identity: " <> show key)
  Just identity -> identity

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value

mustRightIO :: (Show err) => Either err value -> IO value
mustRightIO result = case result of
  Left err -> fail (show err)
  Right value -> pure value
