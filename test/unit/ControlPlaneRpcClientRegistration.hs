{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneRpcClientRegistration (rpcClientRegistrationSuite) where

import Codec.Serialise (deserialiseOrFail, serialise)
import Control.Monad (foldM, forM_)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.Either (isLeft)
import Data.IORef
import Data.Set qualified as Set
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedTransport qualified as Transport
import Prodbox.ControlPlane.AuthenticationRegistry
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
import Prodbox.ControlPlane.CallerPrincipal (callerPrincipalText)
import Prodbox.ControlPlane.Client qualified as Client
import Prodbox.ControlPlane.Codec
import Prodbox.ControlPlane.Coordinate qualified as Coordinate
import Prodbox.ControlPlane.RequestAuthentication
import Prodbox.ControlPlane.Route
import Prodbox.ControlPlane.RpcClientRegistration
import Prodbox.ControlPlane.RpcKeyRegistry
import Prodbox.ControlPlane.TargetResponseTrust
import Prodbox.Http.ReplyStatus (replyStatusCode)
import Prodbox.Lifecycle.Authority.Admission
import Prodbox.Lifecycle.Authority.ClientRegistry
import Prodbox.Lifecycle.Authority.Genesis
import Prodbox.Lifecycle.Authority.Migration
import Prodbox.Lifecycle.Authority.Submission
import Prodbox.Lifecycle.CheckpointAuthority
import Prodbox.Lifecycle.Lease
import Prodbox.Runtime.Role (RuntimeRole (..))
import TestSupport

rpcClientRegistrationSuite :: SuiteBuilder ()
rpcClientRegistrationSuite = describe "Sprint 6.5 origin-aware operation admission" $ do
  forM_ ["0", "01", "-1", "+1", "1/extra", "18446744073709551616"] $ \suffix ->
    it ("refuses a noncanonical origin principal suffix " <> show suffix) $
      mkClientPrincipal (callerPrincipalText agent <> "/rpc-origin/" <> suffix) `shouldSatisfy` isLeft

  it "selects a Target response key from the exact Authority snapshot and origin" $ do
    let snapshot = AuthorityAdmissionSnapshot (7 :: Int) seededAggregate
        origin = mkRpcKeyOrigin rootScope homeVault (controlPlaneSigningKeyRefFor agent)
        wrongRole =
          mkRpcKeyOrigin
            rootScope
            homeVault
            (controlPlaneSigningKeyRefFor (CallerService ProviderWorkerRuntime))
        wrongVault = mkRpcKeyOrigin rootScope remoteVault (controlPlaneSigningKeyRefFor agent)
        selected = must (selectTargetResponseTrust rootScope origin snapshot)
    authorityAdmissionRevision (targetResponseTrustSnapshot selected) `shouldBe` 7
    trustedRequestCallerPrincipal (targetResponseTrustKey selected) `shouldBe` agent
    signingKeyGenerationValue (trustedRequestGeneration (targetResponseTrustKey selected)) `shouldBe` 1
    trustedRequestPublicKeyBytes (targetResponseTrustKey selected)
      `shouldBe` requestSignerPublicKeyBytes (signer agent 1 17)
    selectTargetResponseTrust rootScope wrongRole snapshot `shouldSatisfy` isLeft
    selectTargetResponseTrust rootScope wrongVault snapshot `shouldSatisfy` isLeft
    selectTargetResponseTrust remoteScope origin snapshot `shouldSatisfy` isLeft
    selectTargetResponseTrust rootScope origin (AuthorityAdmissionSnapshot (7 :: Int) initialAggregate)
      `shouldSatisfy` isLeft
    let retired = must (retireAuthorityRpcKey agent (signingGeneration 1) seededAggregate)
    selectTargetResponseTrust rootScope origin (AuthorityAdmissionSnapshot (8 :: Int) retired)
      `shouldSatisfy` isLeft
    signingKeyGenerationValue (trustedRequestGeneration (targetResponseTrustKey selected)) `shouldBe` 1
    fixture <- newFixture seededAggregate
    observed <- readAuthorityAdmission (fixtureRepository fixture) >>= (pure . must)
    let pinned = must (selectTargetResponseTrust rootScope origin observed)
        revision = authorityAdmissionRevision (targetResponseTrustSnapshot pinned)
    compareAndSwapAuthorityAdmission (fixtureRepository fixture) revision retired
      `shouldReturn` Right ()
    stale <- compareAndSwapAuthorityAdmission (fixtureRepository fixture) revision seededAggregate
    stale `shouldSatisfy` isLeft
    readIORef (fixtureState fixture) `shouldReturn` retired

  it "accepts only a canonical role and positive origin generation" $ do
    clientPrincipalCaller remotePrincipal `shouldBe` Just agent
    mkClientPrincipal (clientPrincipalText remotePrincipal) `shouldBe` Right remotePrincipal
    mkClientPrincipal "unknown/rpc-origin/2" `shouldSatisfy` isLeft

  it "admits independent origins under the frozen two-client ceiling" $ do
    let (home, ledger1, table1) = reserve table2 (emptySubmissionLedger 4) 1 keyA
        (remote, _, _) = reserve table1 ledger1 2 keyA
    accepted home `shouldNotBe` accepted remote
    operationIdClient (accepted home) `shouldBe` ClientId "registered-slot/7/generation/1"
    registeredClientTableCapacity table2 `shouldBe` 2

  it "isolates same submission keys, digests and sequence cursors by origin" $ do
    let (home, ledger1, table1) = reserve table2 (emptySubmissionLedger 4) 1 keyA
        (remote, ledger2, tableNext) = reserve table1 ledger1 2 keyA
        (duplicate, _, _) = reserve tableNext ledger2 1 keyA
    operationIdSequence (accepted home) `shouldBe` ClientSequence 1
    operationIdSequence (accepted remote) `shouldBe` ClientSequence 1
    duplicate `shouldBe` RegisteredSubmissionDuplicate (accepted home)
    observeRegisteredSubmission ledger2 tableNext agent (generation 2) keyA
      `shouldBe` RegisteredSubmissionObserved (accepted remote) StatusInFlight

  it "retains earlier generation reservations while a stable origin slot rotates" $ do
    let (_, ledger1, table1) = reserve table3 (emptySubmissionLedger 4) 1 keyA
        desired =
          must (mkVersionedRegisteredClientTable 3 [homeSpec, remoteSpec, spec homePrincipal 7 3] Set.empty)
        rotated = must (reconcileRegisteredClientTable desired table1)
        (new, ledger2, next) = reserve rotated ledger1 3 keyA
        (old, _, _) = reserve next ledger2 1 keyA
    operationIdClient (accepted new) `shouldBe` ClientId "registered-slot/7/generation/3"
    old
      `shouldBe` RegisteredSubmissionDuplicate
        ( OperationId
            authorityEpochGenesis
            (ClientId "registered-slot/7/generation/1")
            (ClientSequence 1)
            digest
        )
    registeredClientReservationCount homePrincipal next `shouldBe` Just 2
    validateRegisteredClientTable ledger2 next `shouldBe` Right ()

  it "fences retired membership while retaining its reservations and charged capacity" $ do
    let (_, ledger, previous) = reserve table2 (emptySubmissionLedger 4) 2 keyA
        desired =
          must
            ( mkVersionedRegisteredClientTable
                2
                [homeSpec, remoteSpec]
                (Set.singleton (remotePrincipal, generation 2))
            )
        retired = must (reconcileRegisteredClientTable desired previous)
    reserve retired ledger 2 keyA `shouldBe` (RegisteredSubmissionRefusedUnregistered, ledger, retired)
    observeRegisteredSubmission ledger retired agent (generation 2) keyA
      `shouldBe` RegisteredSubmissionObserveRefusedUnregistered
    registeredClientReservationCount remotePrincipal retired `shouldBe` Just 1
    registeredClientTableSize retired `shouldBe` 2
    validateRegisteredClientTable ledger retired `shouldBe` Right ()

  it "refuses aliases for the same authenticated role and generation" $
    mkVersionedRegisteredClientTable 2 [homeSpec, spec remotePrincipal 1 1] Set.empty
      `shouldBe` Left (RegisteredClientCallerGenerationDuplicated agent (generation 1))

  it "refuses two origin principals claiming the same numeric slot" $
    mkVersionedRegisteredClientTable 2 [homeSpec, spec remotePrincipal 7 2] Set.empty
      `shouldBe` Left (RegisteredClientSlotDuplicated (must (mkRegisteredClientSlot 7)))

  it "refuses an origin changing slots between key generations" $
    mkVersionedRegisteredClientTable 2 [homeSpec, spec homePrincipal 8 3] Set.empty
      `shouldBe` Left (RegisteredClientPrincipalSlotChanged homePrincipal)

  it "counts historical generations against fixed capacity" $
    mkVersionedRegisteredClientTable 2 [homeSpec, remoteSpec, spec homePrincipal 7 3] Set.empty
      `shouldBe` Left (RegisteredClientTableOverCapacity 3 2)

  it "refuses retirement without an exact retained generation" $
    mkVersionedRegisteredClientTable
      2
      [homeSpec, remoteSpec]
      (Set.singleton (homePrincipal, generation 3))
      `shouldBe` Left (RegisteredClientRetirementMissing homePrincipal (generation 3))

  it "refuses history deletion, changed reservation limits and capacity changes" $ do
    let missing = must (mkVersionedRegisteredClientTable 2 [homeSpec] Set.empty)
        changed =
          must
            ( mkVersionedRegisteredClientTable
                2
                [ homeSpec
                , must (mkRegisteredClientSpec remotePrincipal (must (mkRegisteredClientSlot 1)) (generation 2) 5)
                ]
                Set.empty
            )
    reconcileRegisteredClientTable missing table2
      `shouldBe` Left (RegisteredClientDefinitionChanged remotePrincipal (generation 2))
    reconcileRegisteredClientTable changed table2
      `shouldBe` Left (RegisteredClientDefinitionChanged remotePrincipal (generation 2))
    reconcileRegisteredClientTable table3 table2 `shouldBe` Left RegisteredClientCapacityChanged

  it "never reactivates a retained retired generation" $ do
    let retired =
          must
            ( mkVersionedRegisteredClientTable
                2
                [homeSpec, remoteSpec]
                (Set.singleton (remotePrincipal, generation 2))
            )
    reconcileRegisteredClientTable table2 retired
      `shouldBe` Left (RegisteredClientRetirementRegressed remotePrincipal (generation 2))

  it "preserves the banked legacy table encodings and admitted aggregate bytes" $ do
    let legacyTable = must (mkRegisteredClientTable 4 [homeSpec])
        (_, _, reserved) = reserve legacyTable (emptySubmissionLedger 4) 1 (must (mkClientSubmissionKey "key"))
        oldReserved =
          reserveRegisteredSubmission
            authorityEpochGenesis
            (emptySubmissionLedger 4)
            legacyTable
            agent
            (generation 1)
            (must (mkClientSubmissionKey "key"))
            (RequestDigest "digest")
        aggregate = must (initialCleanInstallAuthorityWithRegisteredClients 4 8 legacyTable)
    Lazy.toStrict (serialise legacyTable) `shouldBe` legacyEmptyBytes
    Lazy.toStrict (serialise (third oldReserved)) `shouldBe` legacyReservedBytes
    Lazy.toStrict (serialise aggregate) `shouldBe` legacyAggregateBytes
    deserialiseOrFail (Lazy.fromStrict legacyEmptyBytes) `shouldBe` Right legacyTable
    registeredClientTableSize reserved `shouldBe` 1

  it "round-trips versioned retired history without reviving membership" $ do
    let retired =
          must
            ( mkVersionedRegisteredClientTable
                2
                [homeSpec, remoteSpec]
                (Set.singleton (remotePrincipal, generation 2))
            )
    deserialiseOrFail (serialise retired) `shouldBe` Right retired

  it "seeds the complete home RPC history without changing home operation identities" $ do
    let clients = authorityAggregateRegisteredClients seededAggregate
    forM_ (trustedCallersForRoute LifecycleOperationSubmit) $ \caller ->
      registeredClientIdForCaller caller (generation 1) clients
        `shouldBe` Just
          (ClientId ("registered-slot/" <> Text.pack (show (callerPrincipalCode caller)) <> "/generation/1"))
    validateAuthorityAdmissionAggregate 4 8 seededAggregate `shouldBe` Right ()

  it "refuses an implicit, partial or foreign Authority seed" $ do
    seedAuthorityRpcKeyRegistry remoteScope seeded initialAggregate
      `shouldBe` Left AuthorityRpcRegistrationScopeMismatch
    seedAuthorityRpcKeyRegistry
      rootScope
      (snd (must (registerRpcKey remoteKey seeded)))
      initialAggregate
      `shouldBe` Left AuthorityRpcRegistrationSeedRequired
    enrollAuthorityRpcKey remoteKey initialAggregate `shouldBe` Left AuthorityRpcRegistrationUnbound
    seedAuthorityRpcKeyRegistry rootScope seeded seededAggregate `shouldBe` Right seededAggregate

  it "registers remote and rotated home/remote keys with independent stable origin slots" $ do
    let remote = must (enrollAuthorityRpcKey remoteKey seededAggregate)
        remoteRotated = must (enrollAuthorityRpcKey (key agent remoteScope remoteVault 2 19) remote)
        homeRotated = must (enrollAuthorityRpcKey (key agent rootScope homeVault 2 20) remoteRotated)
        clients = authorityAggregateRegisteredClients homeRotated
        client g = registeredClientIdForCaller agent (generation g) clients
    client 1 `shouldBe` Just (ClientId "registered-slot/7/generation/1")
    client 2 `shouldBe` Just (ClientId "registered-slot/8/generation/2")
    client 3 `shouldBe` Just (ClientId "registered-slot/8/generation/3")
    client 4 `shouldBe` Just (ClientId "registered-slot/7/generation/4")
    registeredClientTableCapacity clients `shouldBe` 16

  it "retires one origin without retiring or reallocating another" $ do
    let withRemote = must (enrollAuthorityRpcKey remoteKey seededAggregate)
        retired = must (retireAuthorityRpcKey agent (signingGeneration 2) withRemote)
        clients = authorityAggregateRegisteredClients retired
    registeredClientIdForCaller agent (generation 1) clients
      `shouldBe` Just (ClientId "registered-slot/7/generation/1")
    registeredClientIdForCaller agent (generation 2) clients `shouldBe` Nothing
    enrollAuthorityRpcKey remoteKey retired
      `shouldBe` Left (AuthorityRpcRegistryInvalid RpcKeyAlreadyRetired)

  it "gives a recreated Vault an independent origin without recycling retired slots" $ do
    let withRemote = must (enrollAuthorityRpcKey remoteKey seededAggregate)
        retired = must (retireAuthorityRpcKey agent (signingGeneration 2) withRemote)
        successorVault = must (mkRpcVaultIncarnation "33333333-3333-3333-3333-333333333333")
        successor = must (enrollAuthorityRpcKey (key agent remoteScope successorVault 1 19) retired)
        clients = authorityAggregateRegisteredClients successor
    registeredClientIdForCaller agent (generation 2) clients `shouldBe` Nothing
    registeredClientIdForCaller agent (generation 3) clients
      `shouldBe` Just (ClientId "registered-slot/9/generation/3")
    registeredClientTableSize clients `shouldBe` 9

  it "charges retired and rotated RPC history against the unchanged authored ceiling" $ do
    let append state native =
          enrollAuthorityRpcKey (key agent remoteScope remoteVault native (200 + fromIntegral native)) state
        full = must (foldM append seededAggregate [1 .. 9])
        retired = must (retireAuthorityRpcKey agent (signingGeneration 2) full)
    registeredClientTableSize (authorityAggregateRegisteredClients retired) `shouldBe` 16
    append retired 10
      `shouldBe` Left
        ( AuthorityRpcClientProjectionInvalid
            (RpcClientTableInvalid (RegisteredClientTableOverCapacity 17 16))
        )

  it "refuses registration while ordinary admission is open or decommissioned" $ do
    enrollAuthorityRpcKey remoteKey (openAdmission seededAggregate)
      `shouldBe` Left AuthorityRpcRegistrationNotQuiesced
    let stopped = snd (freezeAuthorityForDecommission seededAggregate)
    enrollAuthorityRpcKey remoteKey stopped `shouldBe` Left AuthorityRpcRegistrationDecommissioned

  it "checks live operation quiescence independently of the migration gate" $ do
    let opened = openAdmission (must (enrollAuthorityRpcKey remoteKey seededAggregate))
        (_, submitted) = must (stepRegisteredAuthoritySubmission opened agent (generation 1) keyA digest)
        frozen = freezeMigration submitted
    enrollAuthorityRpcKey (key agent remoteScope remoteVault 2 19) frozen
      `shouldBe` Left AuthorityRpcRegistrationLiveOperations

  it "keeps the authored client ceiling when projecting more RPC history" $ do
    let previous =
          must
            ( mkRegisteredClientTable
                7
                (registeredClientTableSpecifications (authorityAggregateRegisteredClients initialAggregate))
            )
        registry = snd (must (registerRpcKey remoteKey seeded))
    projectRpcRegisteredClients 4 registry previous
      `shouldBe` Left (RpcClientTableInvalid (RegisteredClientTableOverCapacity 8 7))

  it "rejects a planted foreign origin in a reserved home slot" $ do
    let registry = snd (must (registerRpcKey remoteKey seeded))
        previous =
          must
            ( mkVersionedRegisteredClientTable
                16
                ( registeredClientTableSpecifications (authorityAggregateRegisteredClients initialAggregate)
                    <> [spec remotePrincipal 1 2]
                )
                Set.empty
            )
    validateRpcRegisteredClients registry previous `shouldBe` Left RpcClientProjectionMismatch

  it "pins registration scope, client bounds and legacy-runtime refusal in the canonical codec" $ do
    let state = must (enrollAuthorityRpcKey remoteKey seededAggregate)
        bytes = must (encodeModelBValue registeredCodec state)
        wrongRoot = authorityAdmissionStateCodecWithRegisteredRpc 524288 4 8 remoteScope 16 4
        wrongBound = authorityAdmissionStateCodecWithRegisteredRpc 524288 4 8 rootScope 15 4
        legacyCodec =
          authorityAdmissionStateCodecWithRegisteredClients
            524288
            4
            8
            (authorityAggregateRegisteredClients initialAggregate)
    decodeModelBValue registeredCodec bytes `shouldBe` Right state
    decodeModelBValue wrongRoot bytes `shouldSatisfy` isLeft
    decodeModelBValue wrongBound bytes `shouldSatisfy` isLeft
    decodeModelBValue legacyCodec bytes `shouldSatisfy` isLeft
    encodeModelBValue registeredCodec initialAggregate `shouldSatisfy` isLeft
    decodeModelBValue (authorityAdmissionStateCodecWithRegisteredRpc 32 4 8 rootScope 16 4) bytes
      `shouldSatisfy` isLeft
    decodeModelBValue registeredCodec (bytes <> "trailing") `shouldSatisfy` isLeft

  it "does not accept registered state relabeled with the legacy envelope version" $ do
    let bytes = must (encodeModelBValue registeredCodec seededAggregate)
        forged = BS.take 2 bytes <> BS.singleton 7 <> BS.drop 3 bytes
    BS.index bytes 2 `shouldBe` 8
    decodeModelBValue registeredCodec forged `shouldSatisfy` isLeft
    let legacy = must (encodeModelBValue (authorityAdmissionStateCodec 524288 4 8) initialAggregate)
        unboundV8 = BS.take 2 legacy <> BS.singleton 8 <> BS.drop 3 legacy
    BS.index legacy 2 `shouldBe` 7
    decodeModelBValue registeredCodec unboundV8 `shouldBe` Left "AuthorityAdmissionInvalid"

  it "submits and observes both origins through actual signed clients and verified endpoints" $ do
    fixture <- newFixture (openAdmission (must (enrollAuthorityRpcKey remoteKey seededAggregate)))
    home <- submitSigned fixture 1 17
    remote <- submitSigned fixture 2 18
    home `shouldNotBe` remote
    submitSigned fixture 1 17 `shouldReturn` home
    observeSigned fixture 2 18 `shouldReturn` AuthorityOperationObserved remote StatusInFlight
    observeSigned fixture 1 17 `shouldReturn` AuthorityOperationObserved home StatusInFlight

  it "confirms applied-but-response-lost submission from exact retained readback" $ do
    fixture <- newFixture (openAdmission (must (enrollAuthorityRpcKey remoteKey seededAggregate)))
    writeIORef (loseResponse fixture) True
    operation <- submitSigned fixture 2 18
    submitSigned fixture 2 18 `shouldReturn` operation
    readIORef (casCount fixture) `shouldReturn` 1

  it "does not turn a CAS conflict without the operation into acceptance" $ do
    fixture <- newFixture (openAdmission (must (enrollAuthorityRpcKey remoteKey seededAggregate)))
    let repository = (fixtureRepository fixture) {compareAndSwapAuthorityAdmission = \_ _ -> pure (Left "conflict")}
    result <- serveAuthorityOperationSubmit repository (verifiedSlot 2 18) keyA digest
    result
      `shouldSatisfy` isSubmissionWriteFailed
    readIORef (casCount fixture) `shouldReturn` 0

  it "keeps applied submission unresolved until an unavailable readback can be observed" $ do
    fixture <- newFixture (openAdmission (must (enrollAuthorityRpcKey remoteKey seededAggregate)))
    readCount <- newIORef (0 :: Int)
    let base = fixtureRepository fixture
        repository =
          base
            { readAuthorityAdmission = do
                count <- atomicModifyIORef' readCount (\value -> (value + 1, value + 1))
                if count == 1 then readAuthorityAdmission base else pure (Left "unobservable")
            }
    result <- serveAuthorityOperationSubmit repository (verifiedSlot 2 18) keyA digest
    result
      `shouldSatisfy` isSubmissionWriteFailed
    readIORef (casCount fixture) `shouldReturn` 1
    submitSigned fixture 2 18
      >>= ( \operation -> observeSigned fixture 2 18 `shouldReturn` AuthorityOperationObserved operation StatusInFlight
          )

  it "preserves operation identity across a codec-backed repository restart" $ do
    fixture <- newFixture (openAdmission (must (enrollAuthorityRpcKey remoteKey seededAggregate)))
    operation <- submitSigned fixture 2 18
    stored <- readIORef (fixtureState fixture)
    restarted <-
      newFixture
        (must (decodeModelBValue registeredCodec (must (encodeModelBValue registeredCodec stored))))
    submitSigned restarted 2 18 `shouldReturn` operation
    observeSigned restarted 1 17 `shouldReturn` AuthorityOperationUnknown

  it "does not initialize or mutate missing registered state" $ do
    calls <- newIORef (0 :: Int)
    let adapter =
          ModelBCasAdapter
            (\_ -> pure ModelBMissing)
            (\_ -> modifyIORef' calls (+ 1) >> pure (ModelBCasUnobservable "unexpected write"))
        repository = modelBExistingAuthorityAdmissionRepository adapter coordinate
    compareAndSwapAuthorityAdmission repository Nothing seededAggregate >>= (`shouldSatisfy` isLeft)
    result <- serveAuthorityOperationSubmit repository (verifiedSlot 1 17) keyA digest
    result
      `shouldSatisfy` isSubmissionReadFailed
    readIORef calls `shouldReturn` 0

  it "rejects a stale generation at admission even when an old trust snapshot authenticated it" $ do
    let retired =
          must
            ( retireAuthorityRpcKey
                agent
                (signingGeneration 2)
                (must (enrollAuthorityRpcKey remoteKey seededAggregate))
            )
    fixture <- newFixture (openAdmission retired)
    result <- serveAuthorityOperationSubmit (fixtureRepository fixture) (verifiedSlot 2 18) keyA digest
    result
      `shouldBe` AuthorityOperationSubmitDecided
        (AuthorityRegisteredSubmissionDecided RegisteredSubmissionRefusedUnregistered)
    readIORef (casCount fixture) `shouldReturn` 0

must :: (Show err) => Either err value -> value
must = either (error . show) id
third :: (a, b, c) -> c
third (_, _, value) = value
agent :: CallerPrincipal
agent = CallerService TargetSecretAgentRuntime
rootScope, remoteScope :: Coordinate.AuthorityScope
rootScope = must (Coordinate.mkAuthorityScope "home")
remoteScope = must (Coordinate.mkAuthorityScope "aws")
homeVault, remoteVault :: RpcVaultIncarnation
homeVault = must (mkRpcVaultIncarnation "11111111-1111-1111-1111-111111111111")
remoteVault = must (mkRpcVaultIncarnation "22222222-2222-2222-2222-222222222222")
generation :: Natural -> RegisteredClientGeneration
generation = must . mkRegisteredClientGeneration
signingGeneration :: Natural -> SigningKeyGeneration
signingGeneration = must . mkSigningKeyGeneration
signer :: CallerPrincipal -> Natural -> Int -> RequestSigner
signer caller logical seed = must (mkRequestSigner caller (signingGeneration logical) (BS.replicate 32 (fromIntegral seed)))
key
  :: CallerPrincipal
  -> Coordinate.AuthorityScope
  -> RpcVaultIncarnation
  -> Natural
  -> Int
  -> RpcObservedKey
key caller scope vault native seed =
  must
    ( mkRpcObservedKey
        (mkRpcKeyOrigin scope vault (controlPlaneSigningKeyRefFor caller))
        native
        (requestSignerPublicKeyBytes (signer caller 1 seed))
    )
seeded :: RpcKeyRegistry
seeded =
  must
    ( seedLegacyRpcKeyRegistry
        rootScope
        [ key
            caller
            rootScope
            homeVault
            1
            (if caller == agent then 17 else fromIntegral (callerPrincipalCode caller) + 31)
        | caller <- allCallerPrincipals
        ]
    )
remoteKey :: RpcObservedKey
remoteKey = key agent remoteScope remoteVault 1 18
homePrincipal, remotePrincipal :: ClientPrincipal
homePrincipal = clientPrincipalForCaller agent
remotePrincipal = must (clientPrincipalForRpcOrigin agent (generation 2))
spec :: ClientPrincipal -> Natural -> Natural -> RegisteredClientSpec
spec principal slot logical =
  must (mkRegisteredClientSpec principal (must (mkRegisteredClientSlot slot)) (generation logical) 4)
homeSpec, remoteSpec :: RegisteredClientSpec
homeSpec = spec homePrincipal 7 1
remoteSpec = spec remotePrincipal 1 2
table2, table3 :: RegisteredClientTable
table2 = must (mkVersionedRegisteredClientTable 2 [homeSpec, remoteSpec] Set.empty)
table3 = must (mkVersionedRegisteredClientTable 3 [homeSpec, remoteSpec] Set.empty)
keyA :: ClientSubmissionKey
keyA = must (mkClientSubmissionKey "same-submission")
digest :: RequestDigest
digest = RequestDigest "same-digest"
reserve
  :: RegisteredClientTable
  -> SubmissionLedger
  -> Natural
  -> ClientSubmissionKey
  -> (RegisteredSubmissionDecision, SubmissionLedger, RegisteredClientTable)
reserve table ledger logical requestKey =
  reserveRegisteredSubmission
    authorityEpochGenesis
    ledger
    table
    agent
    (generation logical)
    requestKey
    digest
initialAggregate, seededAggregate :: AuthorityAdmissionAggregate
initialAggregate =
  must
    ( initialCleanInstallAuthorityWithRegisteredClients
        4
        8
        ( must
            ( mkRegisteredClientTable
                16
                [ spec (clientPrincipalForCaller caller) (fromIntegral (callerPrincipalCode caller)) 1
                | caller <- trustedCallersForRoute LifecycleOperationSubmit
                ]
            )
        )
    )
seededAggregate = must (seedAuthorityRpcKeyRegistry rootScope seeded initialAggregate)
openAdmission :: AuthorityAdmissionAggregate -> AuthorityAdmissionAggregate
openAdmission =
  flip
    (foldl (\state command -> snd (stepAuthorityAdmission state (ApplyAuthorityGenesis command))))
    [ BeginGenesisEstablishment (GenesisPlan "rpc-genesis" "backup/rpc")
    , ObserveTargetAgentGeneration (TargetAgentGenerationReceipt "rpc-target")
    , ObserveBackupReceipt (BackupReceipt "rpc-backup")
    ]
freezeMigration :: AuthorityAdmissionAggregate -> AuthorityAdmissionAggregate
freezeMigration initial =
  foldl
    (\state command -> snd (stepAuthorityAdmission state command))
    initial
    ( [BeginAuthorityMigration]
        <> [ ApplyAuthorityMigrationImport (RecordProjectionImport projection ProjectionMissing)
           | projection <- [minBound .. maxBound]
           ]
        <> [ ApplyAuthorityMigrationImport CompleteProjectionImports
           , ApplyAuthorityMigration (VerifyShadow stamp)
           , ApplyAuthorityMigration (FreezeLegacy stamp)
           ]
    )
 where
  stamp = maybe (error "fixture digest") id (mkMigrationDigest "rpc-migration")
registeredCodec :: ModelBCodec AuthorityAdmissionAggregate
registeredCodec = authorityAdmissionStateCodecWithRegisteredRpc 524288 4 8 rootScope 16 4
coordinate :: ModelBObjectCoordinate 'ClusterRetained
coordinate =
  must
    ( mkClusterRetainedCoordinate
        (must (mkLongLivedCheckpointAuthority "home" "bucket" "authority" "kv"))
        "authority/admission"
    )
verifiedSlot :: Natural -> Int -> VerifiedCallerSlot
verifiedSlot logical seed =
  verifiedRequestCallerSlot
    (must (decodeAndVerifyControlPlaneRequest 65536 context (encodeSignedControlPlaneRequest signed)))
 where
  source = signer agent logical seed
  nonce = must (mkRequestNonce (BS.replicate 16 1))
  context =
    must
      ( mkRequestVerificationContext
          (trustedRequestKeyFromSigner source)
          LifecycleOperationSubmit
          LifecycleAuthorityRuntime
          rootScope
          authorityEpochGenesis
          deadline
          nonce
          now
          lifetime
      )
  signed =
    must
      ( signControlPlaneRequest
          source
          LifecycleOperationSubmit
          LifecycleAuthorityRuntime
          rootScope
          authorityEpochGenesis
          deadline
          nonce
          "fixture"
      )
now, deadline :: AuthorityTime
now = authorityTimeFromMicros 1000
deadline = authorityTimeFromMicros 2000000
lifetime :: AuthorityDuration
lifetime = must (authorityDurationFromMicros 3000000)

data Fixture = Fixture
  { fixtureState :: IORef AuthorityAdmissionAggregate
  , fixtureRepository :: AuthorityAdmissionRepository IO Natural
  , casCount :: IORef Int
  , loseResponse :: IORef Bool
  , nonceCounter :: IORef Int
  }
newFixture :: AuthorityAdmissionAggregate -> IO Fixture
newFixture initial = do
  state <- newIORef initial
  revision <- newIORef 1
  writes <- newIORef 0
  loss <- newIORef False
  nonces <- newIORef 0
  let repository =
        AuthorityAdmissionRepository
          { readAuthorityAdmission = do
              current <- readIORef state
              version <- readIORef revision
              pure
                ( Right
                    ( AuthorityAdmissionSnapshot
                        version
                        (must (decodeModelBValue registeredCodec (must (encodeModelBValue registeredCodec current))))
                    )
                )
          , compareAndSwapAuthorityAdmission = \expected next -> do
              current <- readIORef revision
              if current /= expected
                then pure (Left "conflict")
                else do
                  writeIORef
                    state
                    (must (decodeModelBValue registeredCodec (must (encodeModelBValue registeredCodec next))))
                  modifyIORef' revision (+ 1)
                  modifyIORef' writes (+ 1)
                  lost <- readIORef loss
                  writeIORef loss False
                  pure (if lost then Left "applied but response lost" else Right ())
          }
  pure (Fixture state repository writes loss nonces)

signedCall
  :: Fixture
  -> Natural
  -> Int
  -> Client.ControlPlaneRouteFor 'LifecycleAuthorityRuntime
  -> BS.ByteString
  -> IO Client.ControlPlaneResponse
signedCall fixture logical seed route body = do
  let bounds = must (Transport.mkAuthenticatedTransportBounds 65536 256 65000)
      server =
        Transport.AuthenticatedServerProviders
          (pure (Right rootScope))
          (pure (Right authorityEpochGenesis))
          (pure (Right now))
          ( do
              state <- readIORef (fixtureState fixture)
              pure
                ( Right
                    ( must
                        ( registeredRpcRouteTrust
                            LifecycleAuthorityRuntime
                            16
                            (maybe (error "fixture registry missing") id (authorityAggregateRpcKeyRegistry state))
                        )
                    )
                )
          )
      transport _ _ _ frame = do
        authenticated <-
          Transport.authenticateControlPlaneFrame
            bounds
            lifetime
            server
            LifecycleAuthorityRuntime
            (Client.controlPlaneRouteForValue route)
            (Lazy.fromStrict frame)
        let request = must authenticated
            slot = Transport.authenticatedServerCallerSlot request
            inner = Lazy.fromStrict (Transport.authenticatedServerInnerBody request)
        case Client.controlPlaneRouteForValue route of
          LifecycleOperationSubmit -> do
            result <- serveAuthorityOperationSubmitRequest 65536 (fixtureRepository fixture) slot inner
            pure
              ( Right
                  ( replyStatusCode (authorityOperationSubmitHttpStatus result)
                  , authorityOperationSubmitResponseBody result
                  )
              )
          LifecycleOperationObserve -> do
            result <- serveAuthorityOperationObserveRequest 65536 (fixtureRepository fixture) slot inner
            pure
              ( Right
                  ( replyStatusCode (authorityOperationObserveHttpStatus result)
                  , authorityOperationObserveResponseBody result
                  )
              )
          _ -> error "fixture route"
      providers =
        Transport.AuthenticatedClientProviders
          (pure (Right (localRequestSigningCapability (signer agent logical seed))))
          (pure (Right rootScope))
          (pure (Right authorityEpochGenesis))
          (pure (Right deadline))
          ( do
              number <- atomicModifyIORef' (nonceCounter fixture) (\value -> (value + 1, value + 1))
              pure (Right (must (mkRequestNonce (BS.replicate 16 (fromIntegral number)))))
          )
      client =
        must
          ( Client.controlPlaneClientWithTransport
              65536
              (must (Client.mkLifecycleAuthorityEndpoint "http://home.test"))
              transport
          )
  must
    <$> Transport.callAuthenticatedClientTransport
      (Transport.mkAuthenticatedClientTransport bounds providers client)
      route
      body
submitSigned :: Fixture -> Natural -> Int -> IO OperationId
submitSigned fixture logical seed = do
  response <-
    signedCall
      fixture
      logical
      seed
      Client.LifecycleOperationSubmitRoute
      ( Lazy.toStrict
          (encodeControlPlaneRequest (AuthorityOperationSubmitPayload "same-submission" "same-digest"))
      )
  case must (decodeControlPlaneResponse 65536 (Lazy.fromStrict (Client.controlPlaneResponseBody response))) of
    AuthorityOperationAccepted operation -> pure operation
    AuthorityOperationDuplicate operation -> pure operation
    other -> error (show other)
observeSigned :: Fixture -> Natural -> Int -> IO AuthorityOperationObserveResponse
observeSigned fixture logical seed = do
  response <-
    signedCall
      fixture
      logical
      seed
      Client.LifecycleOperationObserveRoute
      (Lazy.toStrict (encodeControlPlaneRequest (AuthorityOperationObservePayload "same-submission")))
  pure
    (must (decodeControlPlaneResponse 65536 (Lazy.fromStrict (Client.controlPlaneResponseBody response))))
accepted :: RegisteredSubmissionDecision -> OperationId
accepted (RegisteredSubmissionAccepted operation) = operation
accepted other = error (show other)

legacyEmptyBytes :: BS.ByteString
legacyEmptyBytes =
  BS.pack
    [ 131
    , 0
    , 4
    , 161
    , 130
    , 0
    , 120
    , 27
    , 115
    , 101
    , 114
    , 118
    , 105
    , 99
    , 101
    , 47
    , 116
    , 97
    , 114
    , 103
    , 101
    , 116
    , 45
    , 115
    , 101
    , 99
    , 114
    , 101
    , 116
    , 45
    , 97
    , 103
    , 101
    , 110
    , 116
    , 132
    , 0
    , 133
    , 0
    , 130
    , 0
    , 120
    , 27
    , 115
    , 101
    , 114
    , 118
    , 105
    , 99
    , 101
    , 47
    , 116
    , 97
    , 114
    , 103
    , 101
    , 116
    , 45
    , 115
    , 101
    , 99
    , 114
    , 101
    , 116
    , 45
    , 97
    , 103
    , 101
    , 110
    , 116
    , 130
    , 0
    , 7
    , 130
    , 0
    , 1
    , 4
    , 0
    , 160
    ]

legacyReservedBytes :: BS.ByteString
legacyReservedBytes =
  BS.pack
    [ 131
    , 0
    , 4
    , 161
    , 130
    , 0
    , 120
    , 27
    , 115
    , 101
    , 114
    , 118
    , 105
    , 99
    , 101
    , 47
    , 116
    , 97
    , 114
    , 103
    , 101
    , 116
    , 45
    , 115
    , 101
    , 99
    , 114
    , 101
    , 116
    , 45
    , 97
    , 103
    , 101
    , 110
    , 116
    , 132
    , 0
    , 133
    , 0
    , 130
    , 0
    , 120
    , 27
    , 115
    , 101
    , 114
    , 118
    , 105
    , 99
    , 101
    , 47
    , 116
    , 97
    , 114
    , 103
    , 101
    , 116
    , 45
    , 115
    , 101
    , 99
    , 114
    , 101
    , 116
    , 45
    , 97
    , 103
    , 101
    , 110
    , 116
    , 130
    , 0
    , 7
    , 130
    , 0
    , 1
    , 4
    , 1
    , 161
    , 130
    , 0
    , 99
    , 107
    , 101
    , 121
    , 132
    , 0
    , 130
    , 0
    , 1
    , 130
    , 0
    , 102
    , 100
    , 105
    , 103
    , 101
    , 115
    , 116
    , 130
    , 0
    , 1
    ]

legacyAggregateBytes :: BS.ByteString
legacyAggregateBytes =
  BS.pack
    [ 140
    , 0
    , 129
    , 0
    , 129
    , 0
    , 131
    , 0
    , 4
    , 160
    , 8
    , 160
    , 160
    , 131
    , 0
    , 4
    , 161
    , 130
    , 0
    , 120
    , 27
    , 115
    , 101
    , 114
    , 118
    , 105
    , 99
    , 101
    , 47
    , 116
    , 97
    , 114
    , 103
    , 101
    , 116
    , 45
    , 115
    , 101
    , 99
    , 114
    , 101
    , 116
    , 45
    , 97
    , 103
    , 101
    , 110
    , 116
    , 132
    , 0
    , 133
    , 0
    , 130
    , 0
    , 120
    , 27
    , 115
    , 101
    , 114
    , 118
    , 105
    , 99
    , 101
    , 47
    , 116
    , 97
    , 114
    , 103
    , 101
    , 116
    , 45
    , 115
    , 101
    , 99
    , 114
    , 101
    , 116
    , 45
    , 97
    , 103
    , 101
    , 110
    , 116
    , 130
    , 0
    , 7
    , 130
    , 0
    , 1
    , 4
    , 0
    , 160
    , 132
    , 0
    , 164
    , 103
    , 97
    , 119
    , 115
    , 45
    , 101
    , 107
    , 115
    , 128
    , 111
    , 97
    , 119
    , 115
    , 45
    , 101
    , 107
    , 115
    , 45
    , 115
    , 117
    , 98
    , 122
    , 111
    , 110
    , 101
    , 128
    , 103
    , 97
    , 119
    , 115
    , 45
    , 115
    , 101
    , 115
    , 128
    , 104
    , 97
    , 119
    , 115
    , 45
    , 116
    , 101
    , 115
    , 116
    , 128
    , 164
    , 103
    , 97
    , 119
    , 115
    , 45
    , 101
    , 107
    , 115
    , 128
    , 111
    , 97
    , 119
    , 115
    , 45
    , 101
    , 107
    , 115
    , 45
    , 115
    , 117
    , 98
    , 122
    , 111
    , 110
    , 101
    , 128
    , 103
    , 97
    , 119
    , 115
    , 45
    , 115
    , 101
    , 115
    , 128
    , 104
    , 97
    , 119
    , 115
    , 45
    , 116
    , 101
    , 115
    , 116
    , 128
    , 160
    , 129
    , 0
    , 129
    , 0
    , 129
    , 0
    ]

isSubmissionWriteFailed :: AuthorityOperationSubmitResult -> Bool
isSubmissionWriteFailed value = case value of
  AuthorityOperationSubmitWriteFailed _ -> True
  _ -> False

isSubmissionReadFailed :: AuthorityOperationSubmitResult -> Bool
isSubmissionReadFailed value = case value of
  AuthorityOperationSubmitReadFailed _ -> True
  _ -> False
