{-# LANGUAGE OverloadedStrings #-}

module LifecycleLease
  ( lifecycleLeaseSuite
  )
where

import Data.Aeson (eitherDecode, encode)
import Data.ByteString qualified as BS
import Data.IORef
  ( IORef
  , modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.Gateway.Client (authorityClockUrl)
import Prodbox.Gateway.ObjectStore
  ( AuthorityClockResponse (..)
  , AuthorityObjectCasRequest (..)
  , AuthorityObjectLeaseGuard (..)
  , AuthorityObjectPayloadError (..)
  , authorityControlObjectPayloadMaxBytes
  , authorityObjectPayloadLimit
  , authorityObjectRequestMaxBytes
  , authorityPulumiObjectPayloadMaxBytes
  , validateAuthorityObjectPayloadLength
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( AuthorityCoordinateError (..)
  , ModelBCasAdapter (..)
  , ModelBCasRequest (..)
  , ModelBCasResult (..)
  , ModelBLeaseGuard (..)
  , ModelBObservation (..)
  , checkpointAuthorityClusterId
  , mkLongLivedCheckpointAuthority
  , mkModelBObjectCoordinate
  , mkModelBObjectVersion
  , mkTargetClusterSecretSink
  , modelBObjectAuthority
  , modelBObjectLogicalName
  , targetSecretSinkIdentity
  , targetSecretSinkKvPath
  )
import Prodbox.Lifecycle.CheckpointAuthority qualified
import Prodbox.Lifecycle.CheckpointAuthorityStore
  ( ModelBCodec (..)
  , gatewayModelBCasAdapter
  )
import Prodbox.Lifecycle.Lease
  ( LeaseAcquireDecision (..)
  , LeaseCommitDecision (..)
  , LeaseIdentityError (..)
  , LeaseOwnershipStatus (..)
  , LeasePolicyError (..)
  , LeasePolicyField (..)
  , LeaseProjectionCodecError (..)
  , LeaseProjectionError (..)
  , LeaseRefusal (..)
  , LeaseReleaseDecision (..)
  , LeaseUseDecision (..)
  , LeaseValueError (..)
  , LeaseWork (..)
  , ProviderObservation (..)
  , QuiescenceRefusal (..)
  , RawLeasePolicy (..)
  , TimedProviderObservation (..)
  , addAuthorityDuration
  , authorityDurationFromMicros
  , authorityDurationMicros
  , authorityTimeFromMicros
  , authorityTimeMicros
  , authorizeLeaseWork
  , awsSessionExpiresAt
  , beginLeaseAcquire
  , confirmLeaseAcquired
  , decideFencedCommit
  , decideLeaseAcquire
  , decideLeaseRelease
  , decodeLeaseProjection
  , defaultSesLeasePolicy
  , deriveAwsSessionDeadline
  , encodeLeaseProjection
  , fencedCommitExpectedLeaseVersion
  , fencedCommitFencingToken
  , fencedCommitOwnerNonce
  , fencingTokenValue
  , leaseAcquireDeadline
  , leaseAcquireOwnerNonce
  , leaseGrantExpiresAt
  , leaseGrantFencingToken
  , leaseGrantSafeUseDeadline
  , leaseKeyAccount
  , leaseKeyRegion
  , leaseKeyResource
  , leaseObjectCoordinate
  , leasePolicyGrantTtl
  , leasePolicyProviderVisibilityGrace
  , leasePolicyReadinessBudget
  , leasePolicySmtpCommitBudget
  , leasePolicyTargetWriteGrace
  , leaseProjectionActiveGrant
  , leaseProjectionLastFencingToken
  , leaseProjectionMaximumEncodedBytes
  , leaseProjectionRecoveryPredecessor
  , leaseProjectionReleasedAt
  , leaseProjectionReleasedPredecessor
  , leaseRecoveryNotBefore
  , leaseUseDeadline
  , mkFencingToken
  , mkLeaseKey
  , mkLeasePolicy
  , mkLeaseProjection
  , mkOwnerNonce
  , modelBLeaseGuardFromPermit
  , ownerNonceText
  , proveStableProviderQuiescence
  , proveStableProviderQuiescenceFor
  , stableQuiescenceInventory
  , successorNotBefore
  )
import Prodbox.Lifecycle.Lease qualified
import Prodbox.Lifecycle.LeaseInterpreter
  ( LeaseAcquisition (..)
  , LeaseBoundedFailure (..)
  , LeaseExecutionError (..)
  , LeaseInterpreter (..)
  , acquireLeaseDetailedWith
  , acquireLeaseWith
  , fencedCommitPermitWith
  , leaseAcquisitionRecoveredPredecessor
  , releaseLeaseWith
  , runLeaseWorkWith
  )
import Prodbox.Lifecycle.LeaseRuntime
  ( LeaseAcquireBootstrapError (..)
  , LeaseIdentityDiscoveryError (..)
  , LeaseRuntimeConfigError (..)
  , LeaseSessionError (..)
  , beginProductionLeaseAcquireWith
  , discoverAwsSesLeaseKeyWith
  , generateSecureOwnerNonce
  , leaseScopedAwsCredentials
  , leaseScopedAwsExpiresAt
  , mintLeaseScopedAwsSessionWith
  , mintedAwsSession
  , mkProductionLeaseRuntime
  )
import Prodbox.Settings (Credentials (..))
import TestSupport

lifecycleLeaseSuite :: SuiteBuilder ()
lifecycleLeaseSuite =
  describe "Sprint 4.47 retained-resource lease and CAS" $ do
    it "validates a strict non-renewable transaction budget" $ do
      mkLeasePolicy rawPolicy {rawLeaseReconcileBudgetMicros = 0}
        `shouldBe` Left (LeasePolicyFieldMustBePositive LeaseReconcileBudgetField)
      mkLeasePolicy rawPolicy {rawLeaseGrantTtlMicros = 850}
        `shouldBe` Left (LeasePolicyGrantDoesNotOutliveTransaction 850 850)
      mkLeasePolicy rawPolicy {rawLeaseStableObservationCount = 1}
        `shouldBe` Left (LeasePolicyStableObservationCountTooSmall 1)
      authorityDurationMicros (leasePolicyGrantTtl defaultSesLeasePolicy)
        `shouldBe` 4200000000
      authorityDurationMicros (leasePolicyReadinessBudget defaultSesLeasePolicy)
        `shouldBe` 1800000000
      authorityDurationMicros (leasePolicySmtpCommitBudget defaultSesLeasePolicy)
        `shouldBe` 720000000
      authorityDurationMicros (leasePolicyTargetWriteGrace defaultSesLeasePolicy)
        `shouldBe` 300000000

    it "rejects invalid owner, key, duration, and fencing values" $ do
      mkOwnerNonce " " `shouldBe` Left (LeaseIdentityEmpty "owner_nonce")
      mkOwnerNonce "unsafe nonce"
        `shouldBe` Left (LeaseIdentityContainsUnsafeCharacter "owner_nonce" ' ')
      mkLeaseKey "123" "ca central 1" "aws-ses"
        `shouldBe` Left (LeaseIdentityContainsUnsafeCharacter "region" ' ')
      authorityDurationFromMicros 0 `shouldBe` Left AuthorityDurationMustBePositive
      mkFencingToken 0 `shouldBe` Left FencingTokenMustBePositive

    it "pins the explicit authority-clock wire contract" $ do
      let response = AuthorityClockResponse 123456789
      authorityClockUrl "https://gateway.example.test"
        `shouldBe` "https://gateway.example.test/v1/object-store/authority/time"
      (eitherDecode (encode response) :: Either String AuthorityClockResponse)
        `shouldBe` Right response

    it "round-trips the physical owner/fence guard without exposing payload bytes" $ do
      let wireGuard =
            AuthorityObjectLeaseGuard
              { authorityLeaseGuardLogicalName = "leases/123456789012/ca-central-1/aws-ses"
              , authorityLeaseGuardExpectedVersion = "lease-etag"
              , authorityLeaseGuardOwnerNonce = "owner-a"
              , authorityLeaseGuardFencingToken = 7
              }
          request =
            AuthorityObjectCasRequest
              { authorityObjectCasLogicalName = "target-commit-intents/123456789012/ca-central-1/aws-ses"
              , authorityObjectCasExpectedVersion = Just "intent-etag"
              , authorityObjectCasLeaseGuard = Just wireGuard
              , authorityObjectCasPayload = "sensitive-payload"
              , authorityObjectCasLoopbackNodePortVerified = True
              }
      (eitherDecode (encode request) :: Either String AuthorityObjectCasRequest)
        `shouldBe` Right request
      show request `shouldNotContain` "sensitive-payload"

    it "keeps control projections at 1 MiB while retaining the 64 MiB checkpoint class" $ do
      authorityObjectRequestMaxBytes `shouldBe` (64 * 1024 * 1024)
      authorityControlObjectPayloadMaxBytes `shouldBe` (1024 * 1024)
      authorityPulumiObjectPayloadMaxBytes `shouldBe` (64 * 1024 * 1024)
      authorityObjectPayloadLimit "leases/account/region/aws-ses"
        `shouldBe` authorityControlObjectPayloadMaxBytes
      authorityObjectPayloadLimit "target-commit-intents/account/region/aws-ses"
        `shouldBe` authorityControlObjectPayloadMaxBytes
      authorityObjectPayloadLimit "pulumi-stack/aws-ses"
        `shouldBe` authorityPulumiObjectPayloadMaxBytes
      validateAuthorityObjectPayloadLength
        "leases/account/region/aws-ses"
        authorityControlObjectPayloadMaxBytes
        `shouldBe` Right ()
      validateAuthorityObjectPayloadLength
        "leases/account/region/aws-ses"
        (authorityControlObjectPayloadMaxBytes + 1)
        `shouldBe` Left
          AuthorityObjectPayloadTooLarge
            { authorityPayloadLogicalName = "leases/account/region/aws-ses"
            , authorityPayloadObservedBytes = authorityControlObjectPayloadMaxBytes + 1
            , authorityPayloadMaximumBytes = authorityControlObjectPayloadMaxBytes
            }
      validateAuthorityObjectPayloadLength
        "pulumi-stack/aws-ses"
        authorityPulumiObjectPayloadMaxBytes
        `shouldBe` Right ()
      validateAuthorityObjectPayloadLength
        "pulumi-stack/aws-ses"
        (authorityPulumiObjectPayloadMaxBytes + 1)
        `shouldBe` Left
          AuthorityObjectPayloadTooLarge
            { authorityPayloadLogicalName = "pulumi-stack/aws-ses"
            , authorityPayloadObservedBytes = authorityPulumiObjectPayloadMaxBytes + 1
            , authorityPayloadMaximumBytes = authorityPulumiObjectPayloadMaxBytes
            }

    it "plans first acquisition as Model-B CAS and confirms only re-observed ownership" $ do
      let request = acquireRequest 1000 ownerA
      leaseAcquireDeadline request `shouldBe` at 1100
      case decideLeaseAcquire policy (at 1000) request Nothing ModelBMissing of
        LeaseAcquireCompareAndSwap (ModelBInitialize coordinate projection) -> do
          modelBObjectLogicalName coordinate `shouldBe` "leases/123456789012/ca-central-1/aws-ses"
          let grant = activeGrant projection
          fencingTokenValue (leaseGrantFencingToken grant) `shouldBe` 1
          leaseGrantExpiresAt grant `shouldBe` at 2000
          leaseGrantSafeUseDeadline grant `shouldBe` at 1750
          confirmLeaseAcquired policy (at 1001) request ModelBMissing
            `shouldBe` Left LeaseAuthorityMissing
          confirmLeaseAcquired policy (at 1001) request (observed "etag-1" projection)
            `shouldBe` Right grant
        other -> expectationFailure ("expected initialize CAS, got " ++ show other)

    it "bounds contention and never renews an idempotent acquisition" $ do
      let (_, projection, grant) = firstLease 1000 ownerA
          sameOwner = acquireRequest 1050 ownerA
          contender = acquireRequest 1050 ownerB
          observation = observed "etag-1" projection
      decideLeaseAcquire policy (at 1060) sameOwner Nothing observation
        `shouldBe` LeaseAcquireAlreadyOwned grant
      decideLeaseAcquire policy (at 1060) contender Nothing observation
        `shouldBe` LeaseAcquireContended grant
      decideLeaseAcquire policy (at 1150) contender Nothing observation
        `shouldBe` LeaseAcquireTimedOut (at 1150)

    it "authorizes only work that ends by the safe-use deadline" $ do
      let (_, projection, grant) = firstLease 1000 ownerA
          observation = observed "etag-1" projection
      case authorizeLeaseWork policy (at 1400) LeaseReadinessWork grant observation of
        LeaseUseAuthorized permit -> leaseUseDeadline permit `shouldBe` at 1700
        other -> expectationFailure ("expected readiness permit, got " ++ show other)
      authorizeLeaseWork policy (at 1500) LeaseReadinessWork grant observation
        `shouldBe` LeaseUseRefused
          (LeaseWorkWouldOutliveSafeUse LeaseReadinessWork (at 1800) (at 1750))
      authorizeLeaseWork policy (at 1750) LeaseSmtpCommitWork grant observation
        `shouldBe` LeaseUseRefused (LeaseSafeUseDeadlineReached (at 1750) (at 1750))

    it "caps a lease-scoped AWS session at grant expiry and refuses a too-short session" $ do
      let (_, projection, grant) = firstLease 1000 ownerA
          observation = observed "etag-1" projection
          longSession = duration 1200
          shortSession = duration 100
      case authorizeLeaseWork policy (at 1000) LeaseReconcileWork grant observation of
        LeaseUseRefused refusal -> expectationFailure ("unexpected refusal: " ++ show refusal)
        LeaseUseAuthorized permit -> do
          deriveAwsSessionDeadline longSession permit
            `shouldBe` Right (sessionDeadlineAt 2000 permit longSession)
          authorityTimeMicros
            (awsSessionExpiresAt (sessionDeadlineAt 2000 permit longSession))
            `shouldBe` 2000
          deriveAwsSessionDeadline shortSession permit
            `shouldBe` Left (LeaseAwsSessionTooShort (at 1100) (at 1200))

    it "refuses commits after loss, expiry, disappearance, or unobservability" $ do
      let (_, projection, grant) = firstLease 1000 ownerA
          current = observed "etag-1" projection
      case decideFencedCommit (at 1200) grant current of
        LeaseCommitAuthorized permit -> do
          fencedCommitFencingToken permit `shouldBe` leaseGrantFencingToken grant
          let coordinate = expectRight (leaseObjectCoordinate authority key)
              guard = modelBLeaseGuardFromPermit coordinate permit
          modelBLeaseGuardCoordinate guard `shouldBe` coordinate
          modelBLeaseGuardExpectedVersion guard
            `shouldBe` fencedCommitExpectedLeaseVersion permit
          modelBLeaseGuardOwnerNonceText guard
            `shouldBe` ownerNonceText (fencedCommitOwnerNonce permit)
          modelBLeaseGuardFencingTokenValue guard
            `shouldBe` fencingTokenValue (fencedCommitFencingToken permit)
        other -> expectationFailure ("expected fenced commit permit, got " ++ show other)
      decideFencedCommit (at 1750) grant current
        `shouldBe` LeaseCommitRefused (LeaseSafeUseDeadlineReached (at 1750) (at 1750))
      decideFencedCommit (at 1200) grant ModelBMissing
        `shouldBe` LeaseCommitRefused LeaseAuthorityMissing
      decideFencedCommit (at 1200) grant (ModelBUnobservable "timeout")
        `shouldBe` LeaseCommitRefused (LeaseAuthorityUnobservable "timeout")
      let successorProjection = replacementAfterRelease 1200 projection ownerA
          successorGrant = activeGrant successorProjection
      leaseGrantFencingToken successorGrant `shouldNotBe` leaseGrantFencingToken grant
      decideFencedCommit (at 2851) grant (observed "etag-3" successorProjection)
        `shouldBe` LeaseCommitRefused
          ( LeaseFenceMismatch
              (leaseGrantFencingToken grant)
              (leaseGrantFencingToken successorGrant)
          )

    it "uses owner-and-fence checked release and preserves its idempotent tombstone" $ do
      let (_, projection, grant) = firstLease 1000 ownerA
          coordinate = expectRight (leaseObjectCoordinate authority key)
      case decideLeaseRelease (at 1200) coordinate grant (observed "etag-1" projection) of
        LeaseReleaseCompareAndSwap (ModelBReplace _ _ released) -> do
          leaseProjectionActiveGrant released `shouldBe` Nothing
          leaseProjectionReleasedPredecessor released `shouldBe` Just grant
          leaseProjectionReleasedAt released `shouldBe` Just (at 1200)
          leaseProjectionLastFencingToken released `shouldBe` leaseGrantFencingToken grant
          decodeLeaseProjection policy (encodeLeaseProjection released)
            `shouldBe` Right released
          decideLeaseRelease (at 1201) coordinate grant (observed "etag-2" released)
            `shouldBe` LeaseReleaseAlreadyApplied
        other -> expectationFailure ("expected release CAS, got " ++ show other)
      decideLeaseRelease (at 2000) coordinate grant (observed "etag-1" projection)
        `shouldBe` LeaseReleaseRefused (LeaseGrantExpired (at 2000) (at 2000))

    it "drains a voluntarily released predecessor before issuing the successor fence" $ do
      let (_, projection, predecessor) = firstLease 1000 ownerA
          coordinate = expectRight (leaseObjectCoordinate authority key)
          released =
            case decideLeaseRelease (at 1200) coordinate predecessor (observed "etag-1" projection) of
              LeaseReleaseCompareAndSwap (ModelBReplace _ _ value) -> value
              other -> error ("expected released predecessor, got " ++ show other)
          recovery =
            expectJust
              (leaseProjectionRecoveryPredecessor policy released)
          notBefore = leaseRecoveryNotBefore recovery
          successorRequest = acquireRequest 1949 ownerB
          lateVisibility =
            [ settled 1950 ([] :: [Text])
            , settled 2050 ["late-provider-key"]
            ]
          stableVisibility :: [TimedProviderObservation [Text]]
          stableVisibility =
            [ settled 2050 ["late-provider-key"]
            , settled 2150 ["late-provider-key"]
            ]
      notBefore `shouldBe` at 1950
      decideLeaseAcquire
        policy
        (at 1949)
        successorRequest
        Nothing
        (observed "etag-2" released)
        `shouldBe` LeaseAcquireRecoveryRequired (at 1950)
      proveStableProviderQuiescenceFor policy recovery lateVisibility
        `shouldBe` Left QuiescenceInventoryChanged
      let expiryAnchoredWitness =
            expectRight
              ( proveStableProviderQuiescence
                  policy
                  predecessor
                  [settled 2750 ([] :: [Text]), settled 2850 []]
              )
      decideLeaseAcquire
        policy
        (at 2850)
        (acquireRequest 2850 ownerB)
        (Just expiryAnchoredWitness)
        (observed "etag-2" released)
        `shouldBe` LeaseAcquireRefused
          (LeaseRecoveryWitnessContextMismatch (at 1950) (at 2750))
      let witness =
            expectRight
              (proveStableProviderQuiescenceFor policy recovery stableVisibility)
          readyRequest = acquireRequest 2150 ownerB
      case decideLeaseAcquire
        policy
        (at 2150)
        readyRequest
        (Just witness)
        (observed "etag-2" released) of
        LeaseAcquireCompareAndSwap (ModelBReplace _ _ successor) -> do
          leaseProjectionReleasedPredecessor successor `shouldBe` Nothing
          fencingTokenValue (leaseGrantFencingToken (activeGrant successor))
            `shouldBe` 2
        other -> expectationFailure ("expected recovered successor CAS, got " ++ show other)

    it "rejects a decoded projection whose active grant does not own its last fence" $ do
      let (_, _, grant) = firstLease 1000 ownerA
          secondFence = expectRight (mkFencingToken 2)
      mkLeaseProjection secondFence (Just grant)
        `shouldBe` Left
          ( LeaseProjectionActiveFenceDoesNotMatchLast
              (leaseGrantFencingToken grant)
              secondFence
          )

    it "round-trips the canonical CBOR projection through validated domain constructors" $ do
      let (_, projection, grant) = firstLease 1000 ownerA
          encoded = encodeLeaseProjection projection
          incompatiblePolicy =
            expectRight (mkLeasePolicy rawPolicy {rawLeaseGrantTtlMicros = 1001})
      BS.length encoded `shouldSatisfy` (<= leaseProjectionMaximumEncodedBytes)
      encodeLeaseProjection projection `shouldBe` encoded
      decodeLeaseProjection policy encoded `shouldBe` Right projection
      decodeLeaseProjection incompatiblePolicy encoded
        `shouldBe` Left
          ( LeaseProjectionCodecProjectionInvalid
              ( LeaseGrantExpiryDoesNotMatchPolicy
                  (leaseGrantExpiresAt grant)
                  (at 2001)
              )
          )
      decodeLeaseProjection policy "not-cbor"
        `shouldSatisfy` isCodecDecodeFailure
      decodeLeaseProjection
        policy
        (BS.replicate (leaseProjectionMaximumEncodedBytes + 1) 0)
        `shouldBe` Left
          ( LeaseProjectionCodecTooLarge
              (leaseProjectionMaximumEncodedBytes + 1)
              leaseProjectionMaximumEncodedBytes
          )

    it "migrates active v1 lease CBOR and refuses the predecessor-free v1 release shape" $ do
      let activeV1 =
            BS.pack
              [ 132
              , 0
              , 1
              , 1
              , 129
              , 137
              , 0
              , 108
              , 49
              , 50
              , 51
              , 52
              , 53
              , 54
              , 55
              , 56
              , 57
              , 48
              , 49
              , 50
              , 108
              , 99
              , 97
              , 45
              , 99
              , 101
              , 110
              , 116
              , 114
              , 97
              , 108
              , 45
              , 49
              , 103
              , 97
              , 119
              , 115
              , 45
              , 115
              , 101
              , 115
              , 103
              , 111
              , 119
              , 110
              , 101
              , 114
              , 45
              , 97
              , 1
              , 0
              , 26
              , 250
              , 86
              , 234
              , 0
              , 26
              , 221
              , 186
              , 178
              , 0
              ]
          releasedV1 = BS.pack [132, 0, 1, 1, 128]
          request =
            expectRight
              (beginLeaseAcquire defaultSesLeasePolicy authority key ownerA (at 0))
          expected =
            case decideLeaseAcquire defaultSesLeasePolicy (at 0) request Nothing ModelBMissing of
              LeaseAcquireCompareAndSwap (ModelBInitialize _ value) -> value
              other -> error ("expected default projection, got " ++ show other)
      decodeLeaseProjection defaultSesLeasePolicy activeV1 `shouldBe` Right expected
      decodeLeaseProjection defaultSesLeasePolicy releasedV1
        `shouldBe` Left (LeaseProjectionCodecLegacyReleasedPredecessorMissing 1)

    it "computes successor grace from expiry, skew, cancellation, provider, and target-write bounds" $ do
      let (_, _, grant) = firstLease 1000 ownerA
      successorNotBefore policy grant `shouldBe` at 2750
      proveStableProviderQuiescence policy grant [settled 2750 ([] :: [Text])]
        `shouldBe` Left (QuiescenceInsufficientSamples 2 1)
      proveStableProviderQuiescence
        policy
        grant
        [settled 2749 ([] :: [Text]), settled 2849 []]
        `shouldBe` Left (QuiescenceBeforeSuccessorGrace (at 2749) (at 2750))
      proveStableProviderQuiescence
        policy
        grant
        [settled 2750 ([] :: [Text]), settled 2849 []]
        `shouldBe` Left (QuiescenceSamplesTooClose (at 2750) (at 2849) (duration 100))

    it "keeps canonical successor recovery reachable inside one bounded acquisition" $ do
      let firstRequest =
            expectRight
              (beginLeaseAcquire defaultSesLeasePolicy authority key ownerA (at 0))
          firstProjection =
            case decideLeaseAcquire
              defaultSesLeasePolicy
              (at 0)
              firstRequest
              Nothing
              ModelBMissing of
              LeaseAcquireCompareAndSwap (ModelBInitialize _ value) -> value
              other -> error ("expected canonical first lease, got " ++ show other)
          predecessor = activeGrant firstProjection
          secondRequest =
            expectRight
              ( beginLeaseAcquire
                  defaultSesLeasePolicy
                  authority
                  key
                  ownerB
                  (at 4200000000)
              )
          witness =
            expectRight
              ( proveStableProviderQuiescence
                  defaultSesLeasePolicy
                  predecessor
                  [ settled 5880000000 ([] :: [Text])
                  , settled 6180000000 []
                  ]
              )
      leaseGrantExpiresAt predecessor `shouldBe` at 4200000000
      successorNotBefore defaultSesLeasePolicy predecessor `shouldBe` at 5880000000
      leaseAcquireDeadline secondRequest `shouldBe` at 6300000000
      case decideLeaseAcquire
        defaultSesLeasePolicy
        (at 6180000000)
        secondRequest
        (Just witness)
        (observed "canonical-etag" firstProjection) of
        LeaseAcquireCompareAndSwap (ModelBReplace _ _ nextProjection) ->
          fencingTokenValue (leaseGrantFencingToken (activeGrant nextProjection))
            `shouldBe` 2
        other -> expectationFailure ("canonical recovery was unreachable: " ++ show other)

    it "refuses pending, unbounded, and unobservable provider observations" $ do
      let (_, _, grant) = firstLease 1000 ownerA
      proveStableProviderQuiescence policy grant [pending 2750 "updating", settled 2850 ([] :: [Text])]
        `shouldBe` Left (QuiescenceProviderPending "updating")
      proveStableProviderQuiescence
        policy
        grant
        [unbounded 2750 3 2, settled 2850 ([] :: [Text])]
        `shouldBe` Left (QuiescenceProviderUnbounded 3 2)
      proveStableProviderQuiescence
        policy
        grant
        [unobservable 2750 "denied", settled 2850 ([] :: [Text])]
        `shouldBe` Left (QuiescenceProviderUnobservable "denied")

    it "detects late-visible provider work before issuing a successor fence" $ do
      let (_, projection, predecessor) = firstLease 1000 ownerA
          changing :: [TimedProviderObservation [Text]]
          changing =
            [ settled 2750 ([] :: [Text])
            , settled 2850 ["late-provider-key"]
            ]
          stableLate :: [TimedProviderObservation [Text]]
          stableLate =
            [ settled 2850 ["late-provider-key"]
            , settled 2950 ["late-provider-key"]
            ]
      proveStableProviderQuiescence policy predecessor changing
        `shouldBe` Left QuiescenceInventoryChanged
      let witness = expectRight (proveStableProviderQuiescence policy predecessor stableLate)
          request = acquireRequest 2950 ownerB
      stableQuiescenceInventory witness `shouldBe` ["late-provider-key"]
      case decideLeaseAcquire
        policy
        (at 2950)
        request
        (Just witness)
        (observed "etag-1" projection) of
        LeaseAcquireCompareAndSwap (ModelBReplace _ _ nextProjection) ->
          fencingTokenValue (leaseGrantFencingToken (activeGrant nextProjection)) `shouldBe` 2
        other -> expectationFailure ("expected successor CAS, got " ++ show other)

    it
      "drives CAS conflict, re-observation, bounded action, commit, and release through a fake authority"
      $ do
        stateRef <- newFakeLeaseState (at 1000) ModelBMissing True
        let interpreter = fakeLeaseInterpreter stateRef
            request = acquireRequest 1000 ownerA
            coordinate = expectRight (leaseObjectCoordinate authority key)
        acquired <- acquireLeaseWith interpreter policy request
        case acquired of
          Left err -> expectationFailure ("acquisition failed: " ++ show err)
          Right grant -> do
            fencingTokenValue (leaseGrantFencingToken grant) `shouldBe` 1
            actionResult <-
              runLeaseWorkWith
                interpreter
                policy
                coordinate
                LeaseReconcileWork
                grant
                (\_ -> pure (Right ("bounded-ok" :: Text)))
            actionResult `shouldBe` Right "bounded-ok"
            permit <- fencedCommitPermitWith interpreter coordinate grant
            permit `shouldSatisfy` isCommitPermitFor grant
            releaseLeaseWith interpreter policy coordinate grant `shouldReturn` Right ()
            finalState <- readIORef stateRef
            case fakeLeaseObservation finalState of
              ModelBObserved _ projection ->
                leaseProjectionActiveGrant projection `shouldBe` Nothing
              other -> expectationFailure ("expected released projection, got " ++ show other)
            fakeLeaseCasAttempts finalState `shouldSatisfy` (>= 3)

    it "returns the released predecessor needed for successor target recovery" $ do
      let (_, projection, predecessor) = firstLease 1000 ownerA
          coordinate = expectRight (leaseObjectCoordinate authority key)
          released =
            case decideLeaseRelease (at 1200) coordinate predecessor (observed "etag-1" projection) of
              LeaseReleaseCompareAndSwap (ModelBReplace _ _ value) -> value
              other -> error ("expected release CAS, got " ++ show other)
      stateRef <- newFakeLeaseState (at 1951) (observed "etag-2" released) False
      acquired <-
        acquireLeaseDetailedWith
          (fakeLeaseInterpreter stateRef)
          policy
          (acquireRequest 1951 ownerB)
      case acquired of
        Left err -> expectationFailure ("successor acquisition failed: " ++ show err)
        Right acquisition -> do
          leaseAcquisitionRecoveredPredecessor acquisition
            `shouldBe` Just predecessor
          fencingTokenValue
            (leaseGrantFencingToken (leaseAcquisitionGrant acquisition))
            `shouldBe` 2
          finalState <- readIORef stateRef
          case fakeLeaseObservation finalState of
            ModelBObserved _ successor ->
              leaseProjectionReleasedPredecessor successor `shouldBe` Nothing
            other -> expectationFailure ("expected active successor, got " ++ show other)

    it "reacquires immediately after voluntary release inside the default 35-minute bound" $ do
      let firstRequest =
            expectRight
              (beginLeaseAcquire defaultSesLeasePolicy authority key ownerA (at 0))
          firstProjection =
            case decideLeaseAcquire
              defaultSesLeasePolicy
              (at 0)
              firstRequest
              Nothing
              ModelBMissing of
              LeaseAcquireCompareAndSwap (ModelBInitialize _ value) -> value
              other -> error ("expected default first lease, got " ++ show other)
          predecessor = activeGrant firstProjection
          coordinate = expectRight (leaseObjectCoordinate authority key)
          releasedAt = at 1000000
          released =
            case decideLeaseRelease
              releasedAt
              coordinate
              predecessor
              (observed "default-etag-1" firstProjection) of
              LeaseReleaseCompareAndSwap (ModelBReplace _ _ value) -> value
              other -> error ("expected default release, got " ++ show other)
          successorRequest =
            expectRight
              ( beginLeaseAcquire
                  defaultSesLeasePolicy
                  authority
                  key
                  ownerB
                  releasedAt
              )
          expectedFirstSample = at 1681000000
          expectedSecondSample = at 1981000000
      leaseAcquireDeadline successorRequest `shouldBe` at 2101000000
      leaseRecoveryNotBefore
        (expectJust (leaseProjectionRecoveryPredecessor defaultSesLeasePolicy released))
        `shouldBe` expectedFirstSample
      stateRef <- newFakeLeaseState releasedAt (observed "default-etag-2" released) False
      acquired <-
        acquireLeaseDetailedWith
          (fakeLeaseInterpreter stateRef)
          defaultSesLeasePolicy
          successorRequest
      case acquired of
        Left err -> expectationFailure ("default successor acquisition failed: " ++ show err)
        Right acquisition -> do
          leaseAcquisitionRecoveredPredecessor acquisition
            `shouldBe` Just predecessor
          fencingTokenValue
            (leaseGrantFencingToken (leaseAcquisitionGrant acquisition))
            `shouldBe` 2
      finalState <- readIORef stateRef
      fakeLeaseNow finalState `shouldBe` expectedSecondSample
      fakeLeaseNow finalState `shouldSatisfy` (< leaseAcquireDeadline successorRequest)

    it "surfaces ownership loss from the bounded runner and refuses the action result" $ do
      stateRef <- newFakeLeaseState (at 1000) ModelBMissing False
      let interpreter = fakeLeaseInterpreter stateRef
          request = acquireRequest 1000 ownerA
          coordinate = expectRight (leaseObjectCoordinate authority key)
      acquired <- acquireLeaseWith interpreter policy request
      case acquired of
        Left err -> expectationFailure ("acquisition failed: " ++ show err)
        Right grant -> do
          result <-
            runLeaseWorkWith
              interpreter
              policy
              coordinate
              LeaseReconcileWork
              grant
              ( \_ -> do
                  modifyIORef'
                    stateRef
                    (\state -> state {fakeLeaseObservation = ModelBUnobservable "lease-monitor-lost"})
                  pure (Right ("must-not-escape" :: Text))
              )
          result
            `shouldBe` Left
              ( LeaseExecutionBoundedFailure
                  ( LeaseBoundedOwnershipLost
                      (LeaseAuthorityUnobservable "lease-monitor-lost")
                  )
              )

    it "keeps retained authority and target sink coordinates non-interchangeable" $ do
      checkpointAuthorityClusterId authority `shouldBe` "home-control"
      targetSecretSinkIdentity targetSink `shouldBe` "aws-eks"
      targetSecretSinkKvPath targetSink `shouldBe` "keycloak/smtp"
      let checkpoint = expectRight (mkModelBObjectCoordinate authority "checkpoints/aws-ses")
      modelBObjectAuthority checkpoint `shouldBe` authority
      modelBObjectLogicalName checkpoint `shouldBe` "checkpoints/aws-ses"
      mkLongLivedCheckpointAuthority
        "home control"
        "https://gateway.example.test"
        "prodbox-state"
        "lifecycle"
        "transit/prodbox"
        `shouldBe` Left (AuthorityCoordinateContainsWhitespace "cluster_id")

    it "refuses a failed Model-B encoding before transport" $ do
      let coordinate =
            expectRight
              (mkModelBObjectCoordinate authority "target-commit/aws-ses")
          adapter =
            gatewayModelBCasAdapter
              authority
              ModelBCodec
                { encodeModelBValue = const (Left "projection exceeds bound")
                , decodeModelBValue = Right
                }
      modelBCompareAndSwap adapter (ModelBInitialize coordinate ("value" :: BS.ByteString))
        `shouldReturn` ModelBCasRefusedCorrupt "projection exceeds bound"

    it "discovers the aws-ses lease key without returning raw admin material" $ do
      let observeAccount credentials
            | secret_access_key credentials == "raw-admin-secret" =
                pure (Right "123456789012")
            | otherwise = pure (Left "wrong credential")
      discovered <- discoverAwsSesLeaseKeyWith observeAccount sampleAdminCredentials
      case discovered of
        Left err -> expectationFailure ("identity discovery failed: " ++ show err)
        Right discoveredKey -> do
          leaseKeyAccount discoveredKey `shouldBe` "123456789012"
          leaseKeyRegion discoveredKey `shouldBe` "ca-central-1"
          leaseKeyResource discoveredKey `shouldBe` "aws-ses"
      discoverAwsSesLeaseKeyWith
        (\_ -> pure (Right "1234-not-account"))
        sampleAdminCredentials
        `shouldReturn` Left (LeaseIdentityAccountMustBeTwelveDigits "1234-not-account")

    it "starts production acquisition from a secure nonce and explicit authority time" $ do
      generatedA <- generateSecureOwnerNonce
      generatedB <- generateSecureOwnerNonce
      generatedA `shouldSatisfy` isSecureNonce
      generatedB `shouldSatisfy` isSecureNonce
      generatedA `shouldNotBe` generatedB
      started <-
        beginProductionLeaseAcquireWith
          (pure (Right ownerA))
          (pure (Right (at 777)))
          defaultSesLeasePolicy
          authority
          key
      case started of
        Left err -> expectationFailure ("production acquire bootstrap failed: " ++ show err)
        Right request -> do
          leaseAcquireOwnerNonce request `shouldBe` ownerA
          leaseAcquireDeadline request `shouldBe` at 2100000777
      beginProductionLeaseAcquireWith
        (pure (Right ownerA))
        (pure (Left "clock unavailable"))
        defaultSesLeasePolicy
        authority
        key
        `shouldReturn` Left (LeaseAcquireClockUnobservable "clock unavailable")

    it "mints a temporally narrowed AWS session and rejects invalid STS lifetimes" $ do
      requestedSeconds <- newIORef (0 :: Natural)
      let permit = defaultLeaseUsePermit
          requested = duration 3600000000
          roleArn = "arn:aws:iam::123456789012:role/prodbox-ses-lease-session"
          mintWithin observedRoleArn _ sessionName durationSeconds = do
            observedRoleArn `shouldBe` roleArn
            sessionName `shouldSatisfy` (Text.isPrefixOf "prodbox-lease-")
            writeIORef requestedSeconds durationSeconds
            pure
              ( Right
                  ( mintedAwsSession
                      sampleMintedCredentials
                      (at 3500000000)
                  )
              )
      narrowed <-
        mintLeaseScopedAwsSessionWith
          (pure (Right (at 0)))
          mintWithin
          roleArn
          defaultSesLeasePolicy
          sampleAdminCredentials
          permit
          requested
      readIORef requestedSeconds `shouldReturn` 3540
      case narrowed of
        Left err -> expectationFailure ("session narrowing failed: " ++ show err)
        Right session -> do
          leaseScopedAwsCredentials session `shouldBe` sampleMintedCredentials
          leaseScopedAwsExpiresAt session `shouldBe` at 3500000000
          show session `shouldNotContain` "minted-session-secret"
      overlong <-
        mintLeaseScopedAwsSessionWith
          (pure (Right (at 0)))
          ( \_ _ _ _ ->
              pure
                ( Right
                    ( mintedAwsSession
                        sampleMintedCredentials
                        (at 3600000001)
                    )
                )
          )
          roleArn
          defaultSesLeasePolicy
          sampleAdminCredentials
          permit
          requested
      case overlong of
        Left err ->
          err `shouldBe` LeaseSessionOutlivesGrant (at 3600000001) (at 3600000000)
        Right _ -> expectationFailure "overlong STS response was accepted"
      tooShort <-
        mintLeaseScopedAwsSessionWith
          (pure (Right (at 0)))
          ( \_ _ _ _ ->
              pure
                ( Right
                    ( mintedAwsSession
                        sampleMintedCredentials
                        (at 899999999)
                    )
                )
          )
          roleArn
          defaultSesLeasePolicy
          sampleAdminCredentials
          permit
          requested
      tooShort
        `shouldSatisfy` isSessionBeforeWorkDeadline

    it "validates the production monitor poll interval" $ do
      mkProductionLeaseRuntime
        authority
        defaultSesLeasePolicy
        0
        (pure (ProviderQuiescent ()))
        `shouldSatisfy` isInvalidPollInterval

rawPolicy :: RawLeasePolicy
rawPolicy =
  RawLeasePolicy
    { rawLeaseAcquireTimeoutMicros = 100
    , rawLeaseGrantTtlMicros = 1000
    , rawLeaseReconcileBudgetMicros = 200
    , rawLeaseReadinessBudgetMicros = 300
    , rawLeaseSmtpCommitBudgetMicros = 100
    , rawLeaseCancellationGraceMicros = 100
    , rawLeaseClockSkewMicros = 50
    , rawLeaseSafetyMarginMicros = 100
    , rawLeaseProviderInFlightGraceMicros = 200
    , rawLeaseProviderVisibilityGraceMicros = 100
    , rawLeaseTargetWriteGraceMicros = 300
    , rawLeaseStableObservationCount = 2
    }

policy :: Prodbox.Lifecycle.Lease.LeasePolicy
policy = expectRight (mkLeasePolicy rawPolicy)

authority :: Prodbox.Lifecycle.CheckpointAuthority.LongLivedCheckpointAuthority
authority =
  expectRight
    ( mkLongLivedCheckpointAuthority
        "home-control"
        "https://gateway.example.test"
        "prodbox-state"
        "lifecycle"
        "transit/prodbox"
    )

targetSink :: Prodbox.Lifecycle.CheckpointAuthority.TargetClusterSecretSink
targetSink =
  expectRight
    ( mkTargetClusterSecretSink
        "aws-eks"
        "https://gateway.aws.example.test"
        "secret"
        "keycloak/smtp"
    )

key :: Prodbox.Lifecycle.Lease.LeaseKey
key = expectRight (mkLeaseKey "123456789012" "ca-central-1" "aws-ses")

ownerA :: Prodbox.Lifecycle.Lease.OwnerNonce
ownerA = expectRight (mkOwnerNonce "owner-a")

ownerB :: Prodbox.Lifecycle.Lease.OwnerNonce
ownerB = expectRight (mkOwnerNonce "owner-b")

at :: Natural -> Prodbox.Lifecycle.Lease.AuthorityTime
at = authorityTimeFromMicros

duration :: Natural -> Prodbox.Lifecycle.Lease.AuthorityDuration
duration = expectRight . authorityDurationFromMicros

acquireRequest
  :: Natural
  -> Prodbox.Lifecycle.Lease.OwnerNonce
  -> Prodbox.Lifecycle.Lease.LeaseAcquireRequest
acquireRequest started owner =
  expectRight (beginLeaseAcquire policy authority key owner (at started))

firstLease
  :: Natural
  -> Prodbox.Lifecycle.Lease.OwnerNonce
  -> ( Prodbox.Lifecycle.Lease.LeaseAcquireRequest
     , Prodbox.Lifecycle.Lease.LeaseProjection
     , Prodbox.Lifecycle.Lease.LeaseGrant
     )
firstLease started owner =
  let request = acquireRequest started owner
   in case decideLeaseAcquire policy (at started) request Nothing ModelBMissing of
        LeaseAcquireCompareAndSwap (ModelBInitialize _ projection) ->
          (request, projection, activeGrant projection)
        other -> error ("expected first lease CAS, got " ++ show other)

activeGrant :: Prodbox.Lifecycle.Lease.LeaseProjection -> Prodbox.Lifecycle.Lease.LeaseGrant
activeGrant projection =
  case leaseProjectionActiveGrant projection of
    Just grant -> grant
    Nothing -> error "expected active lease grant"

replacementAfterRelease
  :: Natural
  -> Prodbox.Lifecycle.Lease.LeaseProjection
  -> Prodbox.Lifecycle.Lease.OwnerNonce
  -> Prodbox.Lifecycle.Lease.LeaseProjection
replacementAfterRelease now projection nextOwner =
  let grant = activeGrant projection
      coordinate = expectRight (leaseObjectCoordinate authority key)
      released =
        case decideLeaseRelease (at now) coordinate grant (observed "etag-1" projection) of
          LeaseReleaseCompareAndSwap (ModelBReplace _ _ value) -> value
          other -> error ("expected release plan, got " ++ show other)
      recovery =
        expectJust
          (leaseProjectionRecoveryPredecessor policy released)
      notBefore = leaseRecoveryNotBefore recovery
      recoveredAt =
        addAuthorityDuration
          notBefore
          (leasePolicyProviderVisibilityGrace policy)
      witness =
        expectRight
          ( proveStableProviderQuiescenceFor
              policy
              recovery
              [ TimedProviderObservation notBefore (ProviderQuiescent ([] :: [Text]))
              , TimedProviderObservation recoveredAt (ProviderQuiescent [])
              ]
          )
      request = acquireRequest (authorityTimeMicros recoveredAt) nextOwner
   in case decideLeaseAcquire policy recoveredAt request (Just witness) (observed "etag-2" released) of
        LeaseAcquireCompareAndSwap (ModelBReplace _ _ value) -> value
        other -> error ("expected replacement plan, got " ++ show other)

observed
  :: Text
  -> value
  -> ModelBObservation value
observed version value = ModelBObserved (expectRight (mkModelBObjectVersion version)) value

settled :: Natural -> inventory -> TimedProviderObservation inventory
settled observedAt inventory =
  TimedProviderObservation (at observedAt) (ProviderQuiescent inventory)

pending :: Natural -> Text -> TimedProviderObservation inventory
pending observedAt detail =
  TimedProviderObservation (at observedAt) (ProviderPending detail)

unbounded :: Natural -> Natural -> Natural -> TimedProviderObservation inventory
unbounded observedAt actual maximumCardinality =
  TimedProviderObservation
    (at observedAt)
    (ProviderUnbounded actual maximumCardinality)

unobservable :: Natural -> Text -> TimedProviderObservation inventory
unobservable observedAt detail =
  TimedProviderObservation (at observedAt) (ProviderUnobservable detail)

-- The opaque deadline has no public constructor.  Re-derive it through the
-- same production function so equality assertions still exercise the value.
sessionDeadlineAt
  :: Natural
  -> Prodbox.Lifecycle.Lease.LeaseUsePermit
  -> Prodbox.Lifecycle.Lease.AuthorityDuration
  -> Prodbox.Lifecycle.Lease.AwsSessionDeadline
sessionDeadlineAt expected permit requested =
  case deriveAwsSessionDeadline requested permit of
    Right deadline
      | awsSessionExpiresAt deadline == at expected -> deadline
      | otherwise -> error "unexpected session deadline"
    Left refusal -> error ("unexpected session refusal: " ++ show refusal)

expectRight :: (Show errorValue) => Either errorValue value -> value
expectRight result =
  case result of
    Left err -> error ("unexpected Left: " ++ show err)
    Right value -> value

expectJust :: Maybe value -> value
expectJust maybeValue =
  case maybeValue of
    Nothing -> error "unexpected Nothing"
    Just value -> value

data FakeLeaseState = FakeLeaseState
  { fakeLeaseNow :: !Prodbox.Lifecycle.Lease.AuthorityTime
  , fakeLeaseObservation
      :: !(ModelBObservation Prodbox.Lifecycle.Lease.LeaseProjection)
  , fakeLeaseNextVersion :: !Natural
  , fakeLeaseConflictOnce :: !Bool
  , fakeLeaseCasAttempts :: !Int
  }

newFakeLeaseState
  :: Prodbox.Lifecycle.Lease.AuthorityTime
  -> ModelBObservation Prodbox.Lifecycle.Lease.LeaseProjection
  -> Bool
  -> IO (IORef FakeLeaseState)
newFakeLeaseState now observation conflictOnce =
  newIORef
    FakeLeaseState
      { fakeLeaseNow = now
      , fakeLeaseObservation = observation
      , fakeLeaseNextVersion = 1
      , fakeLeaseConflictOnce = conflictOnce
      , fakeLeaseCasAttempts = 0
      }

fakeLeaseInterpreter :: IORef FakeLeaseState -> LeaseInterpreter IO [Text]
fakeLeaseInterpreter stateRef =
  LeaseInterpreter
    { leaseInterpreterModelB = fakeLeaseAdapter stateRef
    , leaseInterpreterAuthorityNow = Right . fakeLeaseNow <$> readIORef stateRef
    , leaseInterpreterWaitUntil = \deadline ->
        Right
          <$> modifyIORef'
            stateRef
            (\state -> state {fakeLeaseNow = max deadline (fakeLeaseNow state)})
    , leaseInterpreterRecoverQuiescence = \leasePolicy predecessor -> do
        let visibility = leasePolicyProviderVisibilityGrace leasePolicy
            firstObservedAt = leaseRecoveryNotBefore predecessor
            finalObservedAt = addAuthorityDuration firstObservedAt visibility
        modifyIORef'
          stateRef
          ( \current ->
              current
                { fakeLeaseNow = max finalObservedAt (fakeLeaseNow current)
                }
          )
        pure
          ( proveStableProviderQuiescenceFor
              leasePolicy
              predecessor
              [ TimedProviderObservation firstObservedAt (ProviderQuiescent [])
              , TimedProviderObservation finalObservedAt (ProviderQuiescent [])
              ]
          )
    , leaseInterpreterRunBounded = fakeRunBounded stateRef
    }

fakeLeaseAdapter
  :: IORef FakeLeaseState
  -> ModelBCasAdapter IO Prodbox.Lifecycle.Lease.LeaseProjection
fakeLeaseAdapter stateRef =
  ModelBCasAdapter
    { modelBObserve = \_ -> fakeLeaseObservation <$> readIORef stateRef
    , modelBCompareAndSwap = \request -> do
        state <- readIORef stateRef
        let stateWithAttempt =
              state {fakeLeaseCasAttempts = fakeLeaseCasAttempts state + 1}
        if fakeLeaseConflictOnce state
          then do
            writeIORef
              stateRef
              (stateWithAttempt {fakeLeaseConflictOnce = False})
            pure (ModelBCasConflict (fakeLeaseObservation state))
          else case fakeCasDesired request (fakeLeaseObservation state) of
            Nothing -> do
              writeIORef stateRef stateWithAttempt
              pure (ModelBCasConflict (fakeLeaseObservation state))
            Just desired -> do
              let version =
                    expectRight
                      ( mkModelBObjectVersion
                          ("fake-etag-" <> Text.pack (show (fakeLeaseNextVersion state)))
                      )
                  nextState =
                    stateWithAttempt
                      { fakeLeaseObservation = ModelBObserved version desired
                      , fakeLeaseNextVersion = fakeLeaseNextVersion state + 1
                      }
              writeIORef stateRef nextState
              pure (ModelBCasApplied version desired)
    }

fakeCasDesired
  :: ModelBCasRequest value
  -> ModelBObservation current
  -> Maybe value
fakeCasDesired request observation =
  case request of
    ModelBInitialize _ desired ->
      case observation of
        ModelBMissing -> Just desired
        _ -> Nothing
    ModelBReplace _ expected desired ->
      case observation of
        ModelBObserved actual _
          | actual == expected -> Just desired
        _ -> Nothing
    ModelBInitializeGuarded _ _ desired ->
      case observation of
        ModelBMissing -> Just desired
        _ -> Nothing
    ModelBReplaceGuarded _ expected _ desired ->
      case observation of
        ModelBObserved actual _
          | actual == expected -> Just desired
        _ -> Nothing

fakeRunBounded
  :: IORef FakeLeaseState
  -> Prodbox.Lifecycle.Lease.AuthorityTime
  -> IO LeaseOwnershipStatus
  -> IO result
  -> IO (Either LeaseBoundedFailure result)
fakeRunBounded stateRef deadline ownershipProbe action = do
  before <- ownershipProbe
  case before of
    LeaseLost refusal -> pure (Left (LeaseBoundedOwnershipLost refusal))
    LeaseStillOwned -> do
      result <- action
      after <- ownershipProbe
      now <- fakeLeaseNow <$> readIORef stateRef
      pure $ case after of
        LeaseLost refusal -> Left (LeaseBoundedOwnershipLost refusal)
        LeaseStillOwned
          | now > deadline -> Left (LeaseBoundedDeadlineExceeded deadline)
          | otherwise -> Right result

isCommitPermitFor
  :: Prodbox.Lifecycle.Lease.LeaseGrant
  -> Either LeaseExecutionError Prodbox.Lifecycle.Lease.FencedCommitPermit
  -> Bool
isCommitPermitFor grant result =
  case result of
    Right permit -> fencedCommitFencingToken permit == leaseGrantFencingToken grant
    Left _ -> False

isCodecDecodeFailure
  :: Either LeaseProjectionCodecError Prodbox.Lifecycle.Lease.LeaseProjection
  -> Bool
isCodecDecodeFailure result =
  case result of
    Left (LeaseProjectionCodecDecodeFailed _) -> True
    _ -> False

sampleAdminCredentials :: Credentials
sampleAdminCredentials =
  Credentials
    { access_key_id = "AKIARAWADMINEXAMPLE"
    , secret_access_key = "raw-admin-secret"
    , session_token = Nothing
    , region = "ca-central-1"
    }

sampleMintedCredentials :: Credentials
sampleMintedCredentials =
  Credentials
    { access_key_id = "ASIAMINTEDEXAMPLE"
    , secret_access_key = "minted-session-secret"
    , session_token = Just "minted-session-token"
    , region = "ca-central-1"
    }

defaultLeaseUsePermit :: Prodbox.Lifecycle.Lease.LeaseUsePermit
defaultLeaseUsePermit =
  let request =
        expectRight
          (beginLeaseAcquire defaultSesLeasePolicy authority key ownerA (at 0))
      projection =
        case decideLeaseAcquire
          defaultSesLeasePolicy
          (at 0)
          request
          Nothing
          ModelBMissing of
          LeaseAcquireCompareAndSwap (ModelBInitialize _ value) -> value
          other -> error ("expected default lease initialize, got " ++ show other)
      grant = activeGrant projection
   in case authorizeLeaseWork
        defaultSesLeasePolicy
        (at 0)
        LeaseReconcileWork
        grant
        (observed "default-etag" projection) of
        LeaseUseAuthorized permit -> permit
        other -> error ("expected default reconcile permit, got " ++ show other)

isSecureNonce
  :: Either LeaseIdentityError Prodbox.Lifecycle.Lease.OwnerNonce
  -> Bool
isSecureNonce result =
  case result of
    Left _ -> False
    Right nonce -> Text.length (ownerNonceText nonce) == 43

isInvalidPollInterval
  :: Either LeaseRuntimeConfigError runtime -> Bool
isInvalidPollInterval result =
  case result of
    Left LeaseRuntimePollIntervalMustBePositive -> True
    _ -> False

isSessionBeforeWorkDeadline
  :: Either LeaseSessionError session -> Bool
isSessionBeforeWorkDeadline result =
  case result of
    Left
      ( LeaseSessionExpiresBeforeWorkDeadline
          expiresAt
          workDeadline
        ) ->
        expiresAt == at 899999999
          && workDeadline == at 900000000
    _ -> False
