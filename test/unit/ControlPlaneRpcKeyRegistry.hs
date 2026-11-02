{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module ControlPlaneRpcKeyRegistry (rpcKeyRegistrySuite) where

import Codec.Serialise (Serialise, serialise)
import Control.Monad (foldM, forM_)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as Lazy
import Data.List (find)
import Data.Maybe (fromJust)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.AuthenticatedTransport
import Prodbox.ControlPlane.AuthenticationRegistry
import Prodbox.ControlPlane.AuthorityPeerContext (authorityPeerContextRequest)
import Prodbox.ControlPlane.Coordinate qualified as Coordinate
import Prodbox.ControlPlane.RequestAuthentication
import Prodbox.ControlPlane.Route
import Prodbox.ControlPlane.RpcKeyRegistry
import Prodbox.ControlPlane.RpcOwnBindingHint
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.Lease
import Prodbox.Runtime.Role (RuntimeRole (..))
import TestSupport

rpcKeyRegistrySuite :: SuiteBuilder ()
rpcKeyRegistrySuite = describe "Sprint 6.5 retained RPC key origins" $ do
  it "preserves every existing home caller slot in one complete seed" $ do
    let registry = seeded
    length (rpcKeyRegistryBindings registry) `shouldBe` length allCallerPrincipals
    forM_ allCallerPrincipals $ \principal -> do
      rpcKeyRegistryWatermark principal registry `shouldBe` Just 1
      let binding = must (lookupActiveRpcKey (origin principal homeScope homeVault) 1 registry)
      signingKeyGenerationValue (rpcKeyBindingGeneration binding) `shouldBe` 1
      rpcKeyBindingStatus binding `shouldBe` RpcKeyActive

  forM_ allCallerPrincipals $ \principal ->
    it ("refuses a partial legacy seed missing " ++ show principal) $
      seedLegacyRpcKeyRegistry
        homeScope
        ( filter
            ((/= principal) . controlPlaneSigningKeyPrincipal . rpcKeyOriginRef . rpcObservedOrigin)
            seedKeys
        )
        `shouldBe` Left RpcLegacySeedIncomplete

  it "refuses a duplicate caller in the legacy seed" $
    seedLegacyRpcKeyRegistry homeScope (seedKeys <> take 1 seedKeys)
      `shouldBe` Left RpcLegacySeedIncomplete

  it "refuses foreign scopes or independent Vaults in the home seed" $ do
    let replacement vault scope =
          observed agent scope vault 1 17
            : filter ((/= agent) . controlPlaneSigningKeyPrincipal . rpcKeyOriginRef . rpcObservedOrigin) seedKeys
    seedLegacyRpcKeyRegistry homeScope (replacement remoteVault homeScope)
      `shouldBe` Left RpcLegacySeedOriginInvalid
    seedLegacyRpcKeyRegistry homeScope (replacement homeVault remoteScope)
      `shouldBe` Left RpcLegacySeedOriginInvalid

  forM_
    [ ""
    , "not-a-uuid"
    , "00000000-0000-0000-0000-000000000000"
    , "11111111-1111-1111-1111-11111111111G"
    , "11111111-1111-1111-1111-11111111111A"
    ]
    $ \value ->
      it ("refuses invalid Vault incarnation " ++ show value) $
        mkRpcVaultIncarnation value `shouldBe` Left RpcVaultIncarnationInvalid

  forM_ [0, 2 ^ (64 :: Int)] $ \version ->
    it ("refuses out-of-range native version " ++ show version) $
      mkRpcObservedKey (origin agent homeScope homeVault) version (publicFor agent 17)
        `shouldBe` Left RpcNativeVersionInvalid

  it "refuses an invalid Ed25519 public key" $
    mkRpcObservedKey (origin agent homeScope homeVault) 1 (BS.replicate 31 1)
      `shouldBe` Left RpcPublicKeyInvalid

  it "refuses a role/key reference rewritten through a legacy record field" $ do
    let forged = (controlPlaneSigningKeyRefFor agent) {controlPlaneSigningKeyPrincipal = CallerOperatorCli}
        source = mkRpcKeyOrigin homeScope homeVault forged
    mkRpcObservedKey source 1 (publicFor agent 17) `shouldBe` Left RpcKeyReferenceInvalid

  it "separates independent native version-one keys without changing caller slots" $ do
    let (remote, registry) = must (registerRpcKey remoteKey seeded)
        home = must (lookupActiveRpcKey (origin agent homeScope homeVault) 1 registry)
        trust = must (registeredRpcRouteTrust LifecycleAuthorityRuntime 16 registry)
        keys =
          filter
            ((== agent) . trustedRequestCallerPrincipal)
            (routeTrustRegistryKeysFor LifecycleAuthorityPeerObserve trust)
        verifiedHome = verifiedWith trust 1 17
        verifiedRemote = verifiedWith trust 2 18
    rpcObservedNativeVersion (rpcKeyBindingObserved home) `shouldBe` 1
    rpcObservedNativeVersion (rpcKeyBindingObserved remote) `shouldBe` 1
    map (signingKeyGenerationValue . trustedRequestGeneration) keys `shouldBe` [1, 2]
    verifiedCallerSlotPrincipal (verifiedRequestCallerSlot verifiedRemote) `shouldBe` agent
    verifiedCallerSlotKeyGeneration (verifiedRequestCallerSlot verifiedRemote)
      `shouldBe` rpcKeyBindingGeneration remote
    verifiedRequestCallerSlot verifiedRemote `shouldNotBe` verifiedRequestCallerSlot verifiedHome

  it "allocates a later home rotation above an intervening remote registration" $ do
    let (_, withRemote) = must (registerRpcKey remoteKey seeded)
        (home, registry) = must (registerRpcKey (observed agent homeScope homeVault 2 19) withRemote)
    rpcObservedNativeVersion (rpcKeyBindingObserved home) `shouldBe` 2
    signingKeyGenerationValue (rpcKeyBindingGeneration home) `shouldBe` 3
    rpcKeyRegistryWatermark agent registry `shouldBe` Just 3

  it "admits both exact mapped keys under the frozen two-key causal ceiling" $ do
    let (remote, registry) = must (registerRpcKey remoteKey seeded)
        home = must (lookupActiveRpcKey (origin agent homeScope homeVault) 1 registry)
        trusted binding =
          must
            ( mkTrustedRequestKey
                agent
                (rpcKeyBindingGeneration binding)
                (rpcObservedPublicKey (rpcKeyBindingObserved binding))
            )
        entries =
          [(route, trusted home) | route <- routesForRole LifecycleAuthorityRuntime]
            <> [(LifecycleAuthorityPeerObserve, trusted remote)]
        trust = must (mkRouteTrustRegistry LifecycleAuthorityRuntime 2 entries)
    verifiedCallerSlotKeyGeneration (verifiedRequestCallerSlot (verifiedWith trust 2 18))
      `shouldBe` rpcKeyBindingGeneration remote

  it "uses retained watermarks independently for each caller principal" $ do
    let (_, withRemote) = must (registerRpcKey remoteKey seeded)
        (operator, registry) = must (registerRpcKey (observed CallerOperatorCli homeScope homeVault 2 20) withRemote)
    signingKeyGenerationValue (rpcKeyBindingGeneration operator) `shouldBe` 2
    rpcKeyRegistryWatermark agent registry `shouldBe` Just 2

  it "recovers an exact repeated registration without allocating another generation" $ do
    let (binding, registry) = must (registerRpcKey remoteKey seeded)
    registerRpcKey remoteKey registry `shouldBe` Right (binding, registry)

  it "refuses changed public bytes at the same native origin and version" $ do
    let (_, registry) = must (registerRpcKey remoteKey seeded)
    registerRpcKey (observed agent remoteScope remoteVault 1 19) registry
      `shouldBe` Left RpcKeyOriginAliased

  it "refuses copied public identities at another incarnation" $
    registerRpcKey (observed agent remoteScope remoteVault 1 17) seeded
      `shouldBe` Left RpcPublicKeyReused

  it "refuses a regressed native version even when that version was never registered" $ do
    let (_, registry) = must (registerRpcKey (observed agent remoteScope remoteVault 3 18) seeded)
    registerRpcKey (observed agent remoteScope remoteVault 2 19) registry
      `shouldBe` Left RpcNativeVersionRegressed

  it "retains retirement against delayed enrollment and never reuses the logical slot" $ do
    let (remote, registered) = must (registerRpcKey remoteKey seeded)
        retired = must (retireRpcKey agent (rpcKeyBindingGeneration remote) registered)
        (replacement, recovered) = must (registerRpcKey (observed agent remoteScope remoteVault 2 19) retired)
    registerRpcKey remoteKey retired `shouldBe` Left RpcKeyAlreadyRetired
    lookupActiveRpcKey (origin agent remoteScope remoteVault) 1 retired
      `shouldBe` Left RpcKeyAlreadyRetired
    retireRpcKey agent (rpcKeyBindingGeneration remote) retired `shouldBe` Right retired
    signingKeyGenerationValue (rpcKeyBindingGeneration replacement) `shouldBe` 3
    rpcKeyRegistryWatermark agent recovered `shouldBe` Just 3
    length (rpcKeyRegistryBindings recovered) `shouldBe` (length allCallerPrincipals + 2)

  it "does not project retired keys back into route trust" $ do
    let (remote, registered) = must (registerRpcKey remoteKey seeded)
        retired = must (retireRpcKey agent (rpcKeyBindingGeneration remote) registered)
        trust = must (registeredRpcRouteTrust LifecycleAuthorityRuntime 16 retired)
    map
      (signingKeyGenerationValue . trustedRequestGeneration)
      ( filter
          ((== agent) . trustedRequestCallerPrincipal)
          (routeTrustRegistryKeysFor LifecycleAuthorityPeerObserve trust)
      )
      `shouldBe` [1]

  it "refuses trust projection when an allowed caller has no active binding" $ do
    let home = must (lookupActiveRpcKey (origin agent homeScope homeVault) 1 seeded)
        retired = must (retireRpcKey agent (rpcKeyBindingGeneration home) seeded)
    case registeredRpcRouteTrust LifecycleAuthorityRuntime 16 retired of
      Left err -> err `shouldBe` RpcCallerWithoutActiveKey agent
      Right _ -> expectationFailure "missing caller was silently omitted"

  it "preserves the existing per-route key ceiling" $
    registeredRpcRouteTrust LifecycleAuthorityRuntime 1 seeded
      `shouldSatisfy` either (const True) (const False)

  it "round-trips canonical retained state including retired fences" $ do
    let (remote, registered) = must (registerRpcKey remoteKey seeded)
        retired = must (retireRpcKey agent (rpcKeyBindingGeneration remote) registered)
        encoded = must (encodeRpcKeyRegistry retired)
    BS.length encoded `shouldSatisfy` (<= rpcKeyRegistryMaximumBytes)
    decodeRpcKeyRegistry encoded `shouldBe` Right retired
    registerRpcKey remoteKey (must (decodeRpcKeyRegistry encoded)) `shouldBe` Left RpcKeyAlreadyRetired

  it "refuses corrupt, trailing and oversized retained bytes" $ do
    let encoded = must (encodeRpcKeyRegistry seeded)
    decodeRpcKeyRegistry "garbage" `shouldBe` Left RpcKeyRegistryWireInvalid
    decodeRpcKeyRegistry (encoded <> "trailing") `shouldBe` Left RpcKeyRegistryNonCanonical
    decodeRpcKeyRegistry (BS.replicate (rpcKeyRegistryMaximumBytes + 1) 0)
      `shouldBe` Left RpcKeyRegistryTooLarge

  it "refuses a superficially valid registry with missing legacy history" $
    decodeRpcKeyRegistry
      ( Lazy.toStrict
          ( serialise
              ( EmptyRegistryWire
                  1
                  "home"
                  [(callerPrincipalCode principal, 1) | principal <- allCallerPrincipals]
                  []
              )
          )
      )
      `shouldBe` Left RpcKeyRegistryInvariantInvalid

  it "refuses logical generation exhaustion without wrapping or borrowing a native number" $ do
    let largest = 2 ^ (64 :: Int) - 1
        keys =
          observed agent homeScope homeVault largest 17
            : filter ((/= agent) . controlPlaneSigningKeyPrincipal . rpcKeyOriginRef . rpcObservedOrigin) seedKeys
        registry = must (seedLegacyRpcKeyRegistry homeScope keys)
    rpcKeyRegistryWatermark agent registry `shouldBe` Just largest
    registerRpcKey remoteKey registry `shouldBe` Left RpcLogicalGenerationInvalid

  it "keeps retired records in the fixed 256-binding capacity charge" $ do
    let append registry version = do
          (binding, next) <- registerRpcKey (variedKey remoteScope version) registry
          retireRpcKey agent (rpcKeyBindingGeneration binding) next
        full = must (foldM append seeded [1 .. 244])
    length (rpcKeyRegistryBindings full) `shouldBe` 256
    registerRpcKey (variedKey remoteScope 245) full `shouldBe` Left RpcKeyRegistryCapacityReached

  it "refuses the byte ceiling independently of the binding-count ceiling" $ do
    let wide = must (Coordinate.mkAuthorityScope (Text.replicate 2048 "\x1f680"))
        append registry version = snd <$> registerRpcKey (variedKey wide version) registry
        almost = must (foldM append seeded [1 .. 15])
    length (rpcKeyRegistryBindings almost) `shouldBe` 27
    registerRpcKey (variedKey wide 16) almost `shouldBe` Left RpcKeyRegistryTooLarge

  describe "untrusted own-binding discovery data" $ do
    let principal = CallerOperatorCli
        homeOrigin = origin principal homeScope homeVault
        remoteOrigin = origin principal remoteScope remoteVault
        query = must (mkRpcOwnBindingQuery homeScope homeOrigin)
        remoteQuery = must (mkRpcOwnBindingQuery homeScope remoteOrigin)
        hint = must (selectRpcOwnBindingHint query seeded)
        remoteObserved = observed principal remoteScope remoteVault 1 120
        (remoteBinding, withRemote) = must (registerRpcKey remoteObserved seeded)
        remoteHint = must (selectRpcOwnBindingHint remoteQuery withRemote)
        (rotated, withRotation) =
          must (registerRpcKey (observed principal homeScope homeVault 2 121) withRemote)

    forM_ [CallerOperatorCli, CallerTestHarness] $ \caller ->
      it ("round-trips only the exact external caller origin for " ++ show caller) $ do
        let ownQuery = must (mkRpcOwnBindingQuery homeScope (origin caller homeScope homeVault))
            ownHint = must (selectRpcOwnBindingHint ownQuery seeded)
        decodeRpcOwnBindingQuery homeScope (encodeRpcOwnBindingQuery ownQuery) `shouldBe` Right ownQuery
        decodeRpcOwnBindingHint ownQuery (encodeRpcOwnBindingHint ownHint) `shouldBe` Right ownHint

    forM_ (filter (`notElem` [CallerOperatorCli, CallerTestHarness]) allCallerPrincipals) $ \caller ->
      it ("refuses discovery for principal " ++ show caller) $ do
        mkRpcOwnBindingQuery homeScope (origin caller homeScope homeVault)
          `shouldBe` Left RpcOwnBindingCallerRefused
        let bytes =
              "prodbox-rpc-own-binding/v1\NUL"
                <> Lazy.toStrict
                  ( serialise
                      ( OwnQueryWire
                          1
                          "home"
                          "home"
                          (rpcVaultIncarnationText homeVault)
                          (controlPlaneSigningKeyName (controlPlaneSigningKeyRefFor caller))
                      )
                  )
        decodeRpcOwnBindingQuery homeScope bytes `shouldBe` Left RpcOwnBindingCallerRefused

    it "refuses a legacy record-field rewrite of the native key reference" $ do
      let forged =
            (controlPlaneSigningKeyRefFor agent)
              { controlPlaneSigningKeyPrincipal = principal
              }
      mkRpcOwnBindingQuery homeScope (mkRpcKeyOrigin homeScope homeVault forged)
        `shouldBe` Left RpcOwnBindingOriginInvalid

    it "retains separate native version-one bindings across Vault origins" $ do
      rpcObservedNativeVersion (rpcOwnBindingHintObserved hint) `shouldBe` 1
      rpcObservedNativeVersion (rpcOwnBindingHintObserved remoteHint) `shouldBe` 1
      signingKeyGenerationValue (rpcOwnBindingHintGeneration hint) `shouldBe` 1
      signingKeyGenerationValue (rpcOwnBindingHintGeneration remoteHint) `shouldBe` 2
      confirmRpcOwnBindingHintRegistry remoteHint withRemote `shouldBe` Right remoteBinding

    it "selects the latest logical generation only within the exact native origin" $ do
      let selected = must (selectRpcOwnBindingHint query withRotation)
      rpcOwnBindingHintObserved selected `shouldBe` rpcKeyBindingObserved rotated
      signingKeyGenerationValue (rpcOwnBindingHintGeneration selected) `shouldBe` 3
      rpcObservedNativeVersion (rpcOwnBindingHintObserved selected) `shouldBe` 2
      selectRpcOwnBindingHint remoteQuery withRotation `shouldBe` Right remoteHint

    it "does not fall back to another Vault when every own binding has retired" $ do
      let retired = must (retireRpcKey principal (rpcOwnBindingHintGeneration hint) withRemote)
      selectRpcOwnBindingHint query retired
        `shouldBe` Left (RpcOwnBindingRegistryRefused RpcKeyBindingMissing)
      selectRpcOwnBindingHint remoteQuery retired `shouldBe` Right remoteHint

    it "rejects a hint retired between discovery and authenticated read-back" $ do
      let retired = must (retireRpcKey principal (rpcKeyBindingGeneration remoteBinding) withRemote)
      confirmRpcOwnBindingHintRegistry remoteHint retired
        `shouldBe` Left (RpcOwnBindingRegistryRefused RpcKeyBindingMissing)

    it "rejects a hint superseded between discovery and authenticated read-back" $
      confirmRpcOwnBindingHintRegistry hint withRotation `shouldBe` Left RpcOwnBindingChanged

    it "rejects a hint from another Authority scope before selection or decode" $ do
      let foreignQuery = must (mkRpcOwnBindingQuery remoteScope homeOrigin)
      selectRpcOwnBindingHint foreignQuery seeded `shouldBe` Left RpcOwnBindingScopeMismatch
      decodeRpcOwnBindingQuery remoteScope (encodeRpcOwnBindingQuery query)
        `shouldBe` Left RpcOwnBindingScopeMismatch
      decodeRpcOwnBindingHint foreignQuery (encodeRpcOwnBindingHint hint)
        `shouldBe` Left RpcOwnBindingScopeMismatch

    it "rejects a response for a different origin or external caller" $ do
      let harness = must (mkRpcOwnBindingQuery homeScope (origin CallerTestHarness homeScope homeVault))
      decodeRpcOwnBindingHint remoteQuery (encodeRpcOwnBindingHint hint)
        `shouldBe` Left RpcOwnBindingOriginInvalid
      decodeRpcOwnBindingHint harness (encodeRpcOwnBindingHint hint)
        `shouldBe` Left RpcOwnBindingOriginInvalid

    it "compares the independent native origin, version and public key" $ do
      let key = rpcOwnBindingHintObserved remoteHint
          public = rpcObservedPublicKey key
      confirmRpcOwnBindingHintNative remoteHint remoteOrigin (1, public) `shouldBe` Right ()
      confirmRpcOwnBindingHintNative remoteHint homeOrigin (1, public)
        `shouldBe` Left RpcOwnBindingNativeMismatch
      confirmRpcOwnBindingHintNative remoteHint remoteOrigin (2, public)
        `shouldBe` Left RpcOwnBindingNativeMismatch
      confirmRpcOwnBindingHintNative remoteHint remoteOrigin (1, publicFor principal 121)
        `shouldBe` Left RpcOwnBindingNativeMismatch

    it "treats a native-matching forged logical generation as untrusted data" $ do
      let key = rpcOwnBindingHintObserved hint
          wireQuery =
            OwnQueryWire
              1
              "home"
              "home"
              (rpcVaultIncarnationText homeVault)
              (controlPlaneSigningKeyName (controlPlaneSigningKeyRefFor principal))
          bytes =
            "prodbox-rpc-own-binding-response/v1\NUL"
              <> Lazy.toStrict (serialise (OwnHintWire 1 wireQuery 1 17 (rpcObservedPublicKey key)))
          forged = must (decodeRpcOwnBindingHint query bytes)
      confirmRpcOwnBindingHintNative forged homeOrigin (1, rpcObservedPublicKey key) `shouldBe` Right ()
      confirmRpcOwnBindingHintRegistry forged seeded `shouldBe` Left RpcOwnBindingChanged

    forM_ ["", "\NUL", "arbitrary-untrusted-bytes"] $ \garbage ->
      it ("rejects malformed discovery framing " ++ show garbage) $ do
        decodeRpcOwnBindingQuery homeScope garbage `shouldBe` Left RpcOwnBindingWireInvalid
        decodeRpcOwnBindingHint query garbage `shouldBe` Left RpcOwnBindingWireInvalid

    it "rejects noncanonical CBOR, truncated values and trailing bytes" $ do
      let noncanonical encoded =
            let (prefix, body) = BS.break (== 0) encoded
             in prefix <> BS.singleton 0 <> BS.pack [0x9f] <> BS.drop 2 body <> BS.singleton 0xff
          change bytes = [BS.init bytes, bytes <> "\NUL", noncanonical bytes]
      forM_ (change (encodeRpcOwnBindingQuery query)) $ \bytes ->
        decodeRpcOwnBindingQuery homeScope bytes `shouldBe` Left RpcOwnBindingWireInvalid
      forM_ (change (encodeRpcOwnBindingHint hint)) $ \bytes ->
        decodeRpcOwnBindingHint query bytes `shouldBe` Left RpcOwnBindingWireInvalid

    it "rejects oversized query and response before decoding" $ do
      decodeRpcOwnBindingQuery homeScope (BS.replicate (rpcOwnBindingQueryMaximumBytes + 1) 0)
        `shouldBe` Left RpcOwnBindingTooLarge
      decodeRpcOwnBindingHint query (BS.replicate (rpcOwnBindingHintMaximumBytes + 1) 0)
        `shouldBe` Left RpcOwnBindingTooLarge

    it "admits the existing maximum Unicode scope fields within the purpose bounds" $ do
      let wide = must (Coordinate.mkAuthorityScope (Text.replicate 2048 "\x1f680"))
          wideQuery = must (mkRpcOwnBindingQuery wide (origin principal wide homeVault))
          wideKeys =
            [ observed caller wide homeVault 1 (fromIntegral (callerPrincipalCode caller) + 31)
            | caller <- allCallerPrincipals
            ]
          wideRegistry = must (seedLegacyRpcKeyRegistry wide wideKeys)
          wideHint = must (selectRpcOwnBindingHint wideQuery wideRegistry)
          queryBytes = encodeRpcOwnBindingQuery wideQuery
          hintBytes = encodeRpcOwnBindingHint wideHint
      BS.length queryBytes `shouldSatisfy` (<= rpcOwnBindingQueryMaximumBytes)
      BS.length hintBytes `shouldSatisfy` (<= rpcOwnBindingHintMaximumBytes)
      decodeRpcOwnBindingQuery wide queryBytes `shouldBe` Right wideQuery
      decodeRpcOwnBindingHint wideQuery hintBytes `shouldBe` Right wideHint

    it "rejects invalid protocol versions and noncanonical validated scope fields" $ do
      let encoded version scope =
            "prodbox-rpc-own-binding/v1\NUL"
              <> Lazy.toStrict
                ( serialise
                    ( OwnQueryWire
                        version
                        scope
                        "home"
                        (rpcVaultIncarnationText homeVault)
                        (controlPlaneSigningKeyName (controlPlaneSigningKeyRefFor principal))
                    )
                )
      decodeRpcOwnBindingQuery homeScope (encoded 2 "home") `shouldBe` Left RpcOwnBindingWireInvalid
      decodeRpcOwnBindingQuery homeScope (encoded 1 " home ") `shouldBe` Left RpcOwnBindingWireInvalid

    forM_
      [ (0, 1, BS.replicate 32 1)
      , (2 ^ (64 :: Int), 1, BS.replicate 32 1)
      , (1, 0, BS.replicate 32 1)
      , (1, 2 ^ (64 :: Int), BS.replicate 32 1)
      , (1, 1, BS.replicate 31 1)
      ]
      $ \(native, logical, public) ->
        it ("refuses invalid version or public-key data " ++ show (native, logical, BS.length public)) $ do
          let wireQuery =
                OwnQueryWire
                  1
                  "home"
                  "home"
                  (rpcVaultIncarnationText homeVault)
                  (controlPlaneSigningKeyName (controlPlaneSigningKeyRefFor principal))
              bytes =
                "prodbox-rpc-own-binding-response/v1\NUL"
                  <> Lazy.toStrict (serialise (OwnHintWire 1 wireQuery native logical public))
          decodeRpcOwnBindingHint query bytes `shouldBe` Left RpcOwnBindingWireInvalid

data OwnQueryWire = OwnQueryWire !Word !Text !Text !Text !Text
  deriving stock (Generic)
  deriving anyclass (Serialise)
data OwnHintWire = OwnHintWire !Word !OwnQueryWire !Natural !Natural !BS.ByteString
  deriving stock (Generic)
  deriving anyclass (Serialise)

data EmptyRegistryWire = EmptyRegistryWire !Word !Text ![(Word, Natural)] ![EmptyBindingWire]
  deriving stock (Generic)
  deriving anyclass (Serialise)
data EmptyBindingWire = EmptyBindingWire
  deriving stock (Generic)
  deriving anyclass (Serialise)

must :: (Show error) => Either error value -> value
must = either (error . show) id
agent :: CallerPrincipal
agent = CallerService TargetSecretAgentRuntime
homeScope, remoteScope :: Coordinate.AuthorityScope
homeScope = must (Coordinate.mkAuthorityScope "home")
remoteScope = must (Coordinate.mkAuthorityScope "aws")
homeVault, remoteVault :: RpcVaultIncarnation
homeVault = must (mkRpcVaultIncarnation "11111111-1111-1111-1111-111111111111")
remoteVault = must (mkRpcVaultIncarnation "22222222-2222-2222-2222-222222222222")
origin :: CallerPrincipal -> Coordinate.AuthorityScope -> RpcVaultIncarnation -> RpcKeyOrigin
origin principal scope vault = mkRpcKeyOrigin scope vault (controlPlaneSigningKeyRefFor principal)
publicFor :: CallerPrincipal -> Int -> BS.ByteString
publicFor principal seed = requestSignerPublicKeyBytes (signerFor principal 1 seed)
signerFor :: CallerPrincipal -> Natural -> Int -> RequestSigner
signerFor principal generation seed =
  must
    ( mkRequestSigner
        principal
        (must (mkSigningKeyGeneration generation))
        (BS.replicate 32 (fromIntegral seed))
    )
observed
  :: CallerPrincipal
  -> Coordinate.AuthorityScope
  -> RpcVaultIncarnation
  -> Natural
  -> Int
  -> RpcObservedKey
observed principal scope vault native seed = must (mkRpcObservedKey (origin principal scope vault) native (publicFor principal seed))
seedKeys :: [RpcObservedKey]
seedKeys =
  [ observed
      principal
      homeScope
      homeVault
      1
      (if principal == agent then 17 else fromIntegral (callerPrincipalCode principal) + 31)
  | principal <- allCallerPrincipals
  ]
seeded :: RpcKeyRegistry
seeded = must (seedLegacyRpcKeyRegistry homeScope seedKeys)
remoteKey :: RpcObservedKey
remoteKey = observed agent remoteScope remoteVault 1 18
variedKey :: Coordinate.AuthorityScope -> Natural -> RpcObservedKey
variedKey scope version = must (mkRpcObservedKey (origin agent scope remoteVault) version public)
 where
  seed = BS.pack [fromIntegral (version `div` 256), fromIntegral version] <> BS.replicate 30 249
  public = requestSignerPublicKeyBytes (must (mkRequestSigner agent (must (mkSigningKeyGeneration 1)) seed))
verifiedWith :: RouteTrustRegistry -> Natural -> Int -> VerifiedControlPlaneRequest
verifiedWith trust generation seed = must (decodeAndVerifyControlPlaneRequest 65536 context (encodeSignedControlPlaneRequest signed))
 where
  key =
    fromJust
      ( find
          ((== must (mkSigningKeyGeneration generation)) . trustedRequestGeneration)
          ( filter
              ((== agent) . trustedRequestCallerPrincipal)
              (routeTrustRegistryKeysFor LifecycleAuthorityPeerObserve trust)
          )
      )
  deadline = authorityTimeFromMicros 2000
  nonce = must (mkRequestNonce (BS.replicate 16 1))
  context =
    mkPeerObservationVerificationContext
      key
      homeScope
      authorityEpochGenesis
      deadline
      nonce
      (authorityTimeFromMicros 1000)
      (must (authorityDurationFromMicros 10000))
  signed =
    must
      ( signControlPlaneRequest
          (signerFor agent generation seed)
          LifecycleAuthorityPeerObserve
          LifecycleAuthorityRuntime
          homeScope
          authorityEpochGenesis
          deadline
          nonce
          authorityPeerContextRequest
      )
