{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Data.Bits (xor)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Word (Word8)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.Coordinate
  ( AuthorityScope
  , CoordinateError (CoordinateFieldHasWhitespace)
  , mkAuthorityScope
  )
import Prodbox.ControlPlane.RequestAuthentication
import Prodbox.ControlPlane.Route
  ( ControlPlaneRoute (..)
  , allControlPlaneRoutes
  , controlPlaneRouteRole
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityEpoch
  , authorityEpochGenesis
  , nextAuthorityEpoch
  )
import Prodbox.Lifecycle.Lease
  ( AuthorityDuration
  , AuthorityTime
  , authorityDurationFromMicros
  , authorityTimeFromMicros
  )
import Prodbox.Runtime.Role
  ( RuntimeRole (..)
  )
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit
  ( assertBool
  , assertFailure
  , testCase
  , (@?=)
  )
import Test.Tasty.QuickCheck (testProperty)

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "Sprint 4.50 control-plane request authentication"
    [ constructorTests
    , canonicalEnvelopeTests
    , bindingMismatchTests
    , malformedEnvelopeTests
    , propertyTests
    ]

constructorTests :: TestTree
constructorTests =
  testGroup
    "opaque constructors"
    [ testCase "bounds nonces and requires a positive signing-key generation" $ do
        mkRequestNonce (ByteString.replicate 15 0)
          @?= Left (RequestNonceTooShort 15 16)
        mkRequestNonce (ByteString.replicate 65 0)
          @?= Left (RequestNonceTooLong 65 64)
        requestNonceBytes nonceA @?= ByteString.pack [0 .. 15]
        mkSigningKeyGeneration 0
          @?= Left SigningKeyGenerationMustBePositive
        signingKeyGenerationValue generationOne @?= 1
    , testCase "rejects malformed Ed25519 private and public key material" $ do
        case mkRequestSigner
          (CallerService LifecycleAuthorityRuntime)
          generationOne
          (ByteString.replicate 31 0) of
          Left err -> err @?= RequestSecretKeyInvalid
          Right _ -> assertFailure "expected an invalid private key refusal"
        case mkTrustedRequestKey
          (CallerService LifecycleAuthorityRuntime)
          generationOne
          (ByteString.replicate 31 0) of
          Left err -> err @?= RequestPublicKeyInvalid
          Right _ -> assertFailure "expected an invalid public key refusal"
    , testCase "rejects route/callee disagreement before signing or verification" $ do
        signControlPlaneRequest
          signer
          ProviderWorkApply
          AuthorityBackupRuntime
          scopeA
          authorityEpochGenesis
          deadline
          nonceA
          body
          @?= Left
            ( RequestRouteCalleeMismatch
                ProviderWorkApply
                AuthorityBackupRuntime
                ProviderWorkerRuntime
            )
        case mkRequestVerificationContext
          trusted
          ProviderWorkApply
          AuthorityBackupRuntime
          scopeA
          authorityEpochGenesis
          deadline
          nonceA
          now
          maximumLifetime of
          Left err ->
            err
              @?= RequestRouteCalleeMismatch
                ProviderWorkApply
                AuthorityBackupRuntime
                ProviderWorkerRuntime
          Right _ -> assertFailure "expected a route/callee refusal"
    ]

canonicalEnvelopeTests :: TestTree
canonicalEnvelopeTests =
  testGroup
    "canonical signed envelope"
    [ testCase "verifies and exposes every exact authenticated binding" $ do
        verified <- verify fixtureContext fixtureRequest
        verifiedRequestRoute verified @?= ProviderWorkApply
        verifiedRequestCallerPrincipal verified
          @?= CallerService LifecycleAuthorityRuntime
        verifiedRequestCalleeRole verified @?= ProviderWorkerRuntime
        verifiedRequestAuthorityScope verified @?= scopeA
        verifiedRequestAuthorityEpoch verified @?= authorityEpochGenesis
        verifiedRequestDeadline verified @?= deadline
        verifiedRequestNonce verified @?= nonceA
        verifiedRequestSigningKeyGeneration verified @?= generationOne
        verifiedRequestBody verified @?= body
    , testCase "round-trips every closed route identity and its owning callee" $
        mapM_ verifyRoute allControlPlaneRoutes
    , testCase "assigns the authority-control route its non-renumbering stable code 14" $ do
        let request =
              signedRequest
                signer
                LifecycleAuthorityControl
                LifecycleAuthorityRuntime
                scopeA
                authorityEpochGenesis
                deadline
                nonceA
                body
            wire = decodeTestWire (encodeSignedControlPlaneRequest request)
        testWireRoute (testWireClaims wire) @?= 14
    , testCase "assigns the retained-SES-lease route its non-renumbering stable code 15" $ do
        let request =
              signedRequest
                signer
                LifecycleRetainedSesLease
                LifecycleAuthorityRuntime
                scopeA
                authorityEpochGenesis
                deadline
                nonceA
                body
            wire = decodeTestWire (encodeSignedControlPlaneRequest request)
        testWireRoute (testWireClaims wire) @?= 15
    , testCase "assigns decommission routes additive stable codes 16 and 17" $ do
        let authorityRequest =
              signedRequest
                signer
                LifecycleAuthorityDecommissionExport
                LifecycleAuthorityRuntime
                scopeA
                authorityEpochGenesis
                deadline
                nonceA
                body
            targetRequest =
              signedRequest
                signer
                TargetSecretDecommissionTombstone
                TargetSecretAgentRuntime
                scopeA
                authorityEpochGenesis
                deadline
                nonceA
                body
        testWireRoute
          (testWireClaims (decodeTestWire (encodeSignedControlPlaneRequest authorityRequest)))
          @?= 16
        testWireRoute
          (testWireClaims (decodeTestWire (encodeSignedControlPlaneRequest targetRequest)))
          @?= 17
    , testCase "assigns the Pulumi-checkpoint route additive stable code 18" $ do
        let request =
              signedRequest
                signer
                LifecyclePulumiCheckpoint
                LifecycleAuthorityRuntime
                scopeA
                authorityEpochGenesis
                deadline
                nonceA
                body
        testWireRoute
          (testWireClaims (decodeTestWire (encodeSignedControlPlaneRequest request)))
          @?= 18
    , testCase "assigns additive stop, Target inventory, and custody codes 19 through 21" $ do
        let requests =
              [ signedRequest
                  signer
                  LifecycleAuthorityDecommissionStop
                  LifecycleAuthorityRuntime
                  scopeA
                  authorityEpochGenesis
                  deadline
                  nonceA
                  body
              , signedRequest
                  signer
                  TargetSecretDecommissionInventory
                  TargetSecretAgentRuntime
                  scopeA
                  authorityEpochGenesis
                  deadline
                  nonceA
                  body
              , signedRequest
                  signer
                  TargetSecretDecommissionCustodyTombstone
                  TargetSecretAgentRuntime
                  scopeA
                  authorityEpochGenesis
                  deadline
                  nonceA
                  body
              ]
        fmap
          (testWireRoute . testWireClaims . decodeTestWire . encodeSignedControlPlaneRequest)
          requests
          @?= [19, 20, 21]
    , testCase "round-trips every closed caller principal under an independently pinned key" $
        mapM_ verifyCaller allCallerPrincipals
    , testCase "assigns stable service, operator CLI, and test-harness caller codes" $ do
        callerPrincipalCode (CallerService LifecycleAuthorityRuntime) @?= 3
        callerPrincipalCode CallerOperatorCli @?= 100
        callerPrincipalCode CallerTestHarness @?= 101
        mapM_
          (\principal -> callerPrincipalFromCode (callerPrincipalCode principal) @?= Just principal)
          allCallerPrincipals
    , testCase "is deterministic and never serializes the private signing seed" $ do
        let first = encodeSignedControlPlaneRequest fixtureRequest
            second =
              encodeSignedControlPlaneRequest
                ( signedRequest
                    signer
                    ProviderWorkApply
                    ProviderWorkerRuntime
                    scopeA
                    authorityEpochGenesis
                    deadline
                    nonceA
                    body
                )
            encoded = LazyByteString.toStrict first
        first @?= second
        assertBool
          "private key seed leaked into the request"
          (not (signingSeed `ByteString.isInfixOf` encoded))
    , testCase "changes the authenticated envelope for deadline, nonce, route, scope, epoch, or body" $ do
        let variants =
              [ signedRequest
                  signer
                  ProviderWorkApply
                  ProviderWorkerRuntime
                  scopeA
                  authorityEpochGenesis
                  deadlineB
                  nonceA
                  body
              , signedRequest
                  signer
                  ProviderWorkApply
                  ProviderWorkerRuntime
                  scopeA
                  authorityEpochGenesis
                  deadline
                  nonceB
                  body
              , signedRequest
                  signer
                  ProviderWorkObserve
                  ProviderWorkerRuntime
                  scopeA
                  authorityEpochGenesis
                  deadline
                  nonceA
                  body
              , signedRequest
                  signer
                  ProviderWorkApply
                  ProviderWorkerRuntime
                  scopeB
                  authorityEpochGenesis
                  deadline
                  nonceA
                  body
              , signedRequest
                  signer
                  ProviderWorkApply
                  ProviderWorkerRuntime
                  scopeA
                  (nextAuthorityEpoch authorityEpochGenesis)
                  deadline
                  nonceA
                  body
              , signedRequest
                  signer
                  ProviderWorkApply
                  ProviderWorkerRuntime
                  scopeA
                  authorityEpochGenesis
                  deadline
                  nonceA
                  "other-body"
              ]
            encoded = encodeSignedControlPlaneRequest fixtureRequest
        mapM_
          ( \variant ->
              assertBool
                "binding did not change canonical bytes"
                (encodeSignedControlPlaneRequest variant /= encoded)
          )
          variants
    , testCase "accepts an independently reconstructed trusted public key" $ do
        reconstructed <-
          mustRightIO
            ( mkTrustedRequestKey
                (CallerService LifecycleAuthorityRuntime)
                generationOne
                (requestSignerPublicKeyBytes signer)
            )
        context <-
          contextFor
            reconstructed
            ProviderWorkApply
            ProviderWorkerRuntime
            scopeA
            authorityEpochGenesis
            deadline
            nonceA
            now
            maximumLifetime
        _ <- verify context fixtureRequest
        pure ()
    ]
 where
  verifyRoute route = do
    let callee = controlPlaneRouteRole route
        request = signedRequest signer route callee scopeA authorityEpochGenesis deadline nonceA body
    context <-
      contextFor trusted route callee scopeA authorityEpochGenesis deadline nonceA now maximumLifetime
    verified <- verify context request
    verifiedRequestRoute verified @?= route
    verifiedRequestCalleeRole verified @?= callee
  verifyCaller caller = do
    let callerSigner = signerFor caller generationOne
        callerTrust = trustedRequestKeyFromSigner callerSigner
        request =
          signedRequest
            callerSigner
            ProviderWorkApply
            ProviderWorkerRuntime
            scopeA
            authorityEpochGenesis
            deadline
            nonceA
            body
    context <-
      contextFor
        callerTrust
        ProviderWorkApply
        ProviderWorkerRuntime
        scopeA
        authorityEpochGenesis
        deadline
        nonceA
        now
        maximumLifetime
    verified <- verify context request
    verifiedRequestCallerPrincipal verified @?= caller

bindingMismatchTests :: TestTree
bindingMismatchTests =
  testGroup
    "authenticated binding refusals"
    [ testCase "rejects a caller-principal substitution" $ do
        let otherSigner = signerFor (CallerService GatewayRuntime) generationOne
            request =
              signedRequest
                otherSigner
                ProviderWorkApply
                ProviderWorkerRuntime
                scopeA
                authorityEpochGenesis
                deadline
                nonceA
                body
        verifyError fixtureContext request
          @?= RequestCallerPrincipalMismatch
            (CallerService LifecycleAuthorityRuntime)
            (CallerService GatewayRuntime)
    , testCase "rejects a signing-key generation substitution" $ do
        let otherSigner = signerFor (CallerService LifecycleAuthorityRuntime) generationTwo
            request =
              signedRequest
                otherSigner
                ProviderWorkApply
                ProviderWorkerRuntime
                scopeA
                authorityEpochGenesis
                deadline
                nonceA
                body
        verifyError fixtureContext request
          @?= RequestSigningKeyGenerationMismatch generationOne generationTwo
    , testCase "rejects cross-role replay at another callee" $ do
        let request =
              signedRequest
                signer
                TargetMaterialObserve
                TargetSecretAgentRuntime
                scopeA
                authorityEpochGenesis
                deadline
                nonceA
                body
        context <-
          contextFor
            trusted
            AuthorityBackupObserve
            AuthorityBackupRuntime
            scopeA
            authorityEpochGenesis
            deadline
            nonceA
            now
            maximumLifetime
        verifyError context request
          @?= RequestCalleeRoleMismatch AuthorityBackupRuntime TargetSecretAgentRuntime
    , testCase "rejects method/path substitution through the typed route identity" $ do
        context <-
          contextFor
            trusted
            ProviderWorkObserve
            ProviderWorkerRuntime
            scopeA
            authorityEpochGenesis
            deadline
            nonceA
            now
            maximumLifetime
        verifyError context fixtureRequest
          @?= RequestRouteMismatch ProviderWorkObserve ProviderWorkApply
    , testCase "rejects authority-scope and active-epoch mismatch" $ do
        scopeContext <-
          contextFor
            trusted
            ProviderWorkApply
            ProviderWorkerRuntime
            scopeB
            authorityEpochGenesis
            deadline
            nonceA
            now
            maximumLifetime
        verifyError scopeContext fixtureRequest
          @?= RequestAuthorityScopeMismatch scopeB scopeA
        epochContext <-
          contextFor
            trusted
            ProviderWorkApply
            ProviderWorkerRuntime
            scopeA
            (nextAuthorityEpoch authorityEpochGenesis)
            deadline
            nonceA
            now
            maximumLifetime
        verifyError epochContext fixtureRequest
          @?= RequestAuthorityEpochMismatch (nextAuthorityEpoch authorityEpochGenesis) authorityEpochGenesis
    , testCase "rejects absolute-deadline and nonce/request-id mismatch" $ do
        deadlineContext <-
          contextFor
            trusted
            ProviderWorkApply
            ProviderWorkerRuntime
            scopeA
            authorityEpochGenesis
            deadlineB
            nonceA
            now
            maximumLifetime
        verifyError deadlineContext fixtureRequest
          @?= RequestDeadlineMismatch deadlineB deadline
        nonceContext <-
          contextFor
            trusted
            ProviderWorkApply
            ProviderWorkerRuntime
            scopeA
            authorityEpochGenesis
            deadline
            nonceB
            now
            maximumLifetime
        verifyError nonceContext fixtureRequest
          @?= RequestNonceMismatch nonceB nonceA
    , testCase "rejects an expired or policy-excessive absolute deadline" $ do
        expiredContext <-
          contextFor
            trusted
            ProviderWorkApply
            ProviderWorkerRuntime
            scopeA
            authorityEpochGenesis
            deadline
            nonceA
            deadline
            maximumLifetime
        verifyError expiredContext fixtureRequest
          @?= RequestDeadlineExpired deadline deadline
        shortLifetime <- mustRightIO (authorityDurationFromMicros 500)
        excessiveContext <-
          contextFor
            trusted
            ProviderWorkApply
            ProviderWorkerRuntime
            scopeA
            authorityEpochGenesis
            deadline
            nonceA
            now
            shortLifetime
        verifyError excessiveContext fixtureRequest
          @?= RequestDeadlineExceedsMaximumLifetime deadline (authorityTimeFromMicros 1500)
    , testCase "rejects body substitution even though the signed digest remains authentic" $ do
        let wire = decodeTestWire (encodeSignedControlPlaneRequest fixtureRequest)
            tampered = wire {testWireBody = "different-body"}
        decodeAndVerifyControlPlaneRequest maximumEnvelopeBytes fixtureContext (serialise tampered)
          @?= Left RequestBodyDigestMismatch
    , testCase "rejects signature substitution" $ do
        let wire = decodeTestWire (encodeSignedControlPlaneRequest fixtureRequest)
            tampered = wire {testWireSignature = flipLastByte (testWireSignature wire)}
        decodeAndVerifyControlPlaneRequest maximumEnvelopeBytes fixtureContext (serialise tampered)
          @?= Left RequestAuthenticationFailed
    , testCase "rejects signed-claim tampering for deadline and nonce" $ do
        let wire = decodeTestWire (encodeSignedControlPlaneRequest fixtureRequest)
            claims = testWireClaims wire
            deadlineTampered = wire {testWireClaims = claims {testWireDeadlineMicros = 2500}}
            nonceTampered = wire {testWireClaims = claims {testWireNonce = ByteString.replicate 16 99}}
        tamperedDeadlineContext <-
          contextFor
            trusted
            ProviderWorkApply
            ProviderWorkerRuntime
            scopeA
            authorityEpochGenesis
            (authorityTimeFromMicros 2500)
            nonceA
            now
            maximumLifetime
        decodeAndVerifyControlPlaneRequest
          maximumEnvelopeBytes
          tamperedDeadlineContext
          (serialise deadlineTampered)
          @?= Left RequestAuthenticationFailed
        tamperedNonceContext <-
          contextFor
            trusted
            ProviderWorkApply
            ProviderWorkerRuntime
            scopeA
            authorityEpochGenesis
            deadline
            (mustRight (mkRequestNonce (ByteString.replicate 16 99)))
            now
            maximumLifetime
        decodeAndVerifyControlPlaneRequest
          maximumEnvelopeBytes
          tamperedNonceContext
          (serialise nonceTampered)
          @?= Left RequestAuthenticationFailed
    ]

malformedEnvelopeTests :: TestTree
malformedEnvelopeTests =
  testGroup
    "bounded canonical and semantic decoder"
    [ testCase "rejects negative/oversize bounds and malformed bytes" $ do
        decodeAndVerifyControlPlaneRequest
          (-1)
          fixtureContext
          (encodeSignedControlPlaneRequest fixtureRequest)
          @?= Left RequestEnvelopeTooLarge
        decodeAndVerifyControlPlaneRequest 1 fixtureContext (encodeSignedControlPlaneRequest fixtureRequest)
          @?= Left RequestEnvelopeTooLarge
        decodeAndVerifyControlPlaneRequest maximumEnvelopeBytes fixtureContext "not-cbor"
          @?= Left RequestEnvelopeInvalid
    , testCase "rejects a decodable non-canonical CBOR integer" $ do
        let nonCanonical = makeSchemaVersionNonCanonical (encodeSignedControlPlaneRequest fixtureRequest)
        decodeAndVerifyControlPlaneRequest maximumEnvelopeBytes fixtureContext nonCanonical
          @?= Left RequestEnvelopeNonCanonical
    , testCase "rejects protocol and schema substitution" $ do
        verifyMalformed (updateClaims (\claims -> claims {testWireProtocol = "other-protocol"}))
          @?= Left RequestProtocolMismatch
        verifyMalformed (updateClaims (\claims -> claims {testWireSchema = 2}))
          @?= Left (RequestSchemaUnsupported 2)
    , testCase "rejects unknown route, caller-principal, and callee-role codes" $ do
        verifyMalformed (updateClaims (\claims -> claims {testWireRoute = 99}))
          @?= Left (RequestRouteIdentityInvalid 99)
        verifyMalformed (updateClaims (\claims -> claims {testWireCallerPrincipal = 99}))
          @?= Left (RequestCallerPrincipalInvalid 99)
        verifyMalformed (updateClaims (\claims -> claims {testWireCalleeRole = 99}))
          @?= Left (RequestCalleeRoleInvalid 99)
    , testCase "rejects malformed scope, zero epoch, nonce, and key generation" $ do
        verifyMalformed (updateClaims (\claims -> claims {testWireAuthorityScope = "bad scope"}))
          @?= Left (RequestAuthorityScopeInvalid (CoordinateFieldHasWhitespace "authority_scope"))
        verifyMalformed (updateClaims (\claims -> claims {testWireAuthorityEpoch = 0}))
          @?= Left RequestAuthorityEpochInvalid
        verifyMalformed (updateClaims (\claims -> claims {testWireNonce = ByteString.replicate 15 0}))
          @?= Left (RequestNonceSemanticInvalid (RequestNonceTooShort 15 16))
        verifyMalformed (updateClaims (\claims -> claims {testWireSigningKeyGeneration = 0}))
          @?= Left (RequestSigningKeyGenerationSemanticInvalid SigningKeyGenerationMustBePositive)
    , testCase "rejects malformed digest/signature widths and route/callee inconsistency" $ do
        verifyMalformed (updateClaims (\claims -> claims {testWireBodyDigest = ByteString.replicate 31 0}))
          @?= Left (RequestBodyDigestWidthInvalid 31 32)
        verifyMalformed (baseTestWire {testWireSignature = ""})
          @?= Left RequestSignatureInvalid
        verifyMalformed (updateClaims (\claims -> claims {testWireCalleeRole = 5}))
          @?= Left
            ( RequestRouteCalleeBindingInvalid
                ProviderWorkApply
                AuthorityBackupRuntime
                ProviderWorkerRuntime
            )
    ]

propertyTests :: TestTree
propertyTests =
  testGroup
    "properties"
    [ testProperty
        "decode(encode(sign(body))) exposes the exact bounded body"
        bodyRoundTripProperty
    , testProperty
        "signing and canonical encoding are deterministic"
        deterministicSigningProperty
    ]

bodyRoundTripProperty :: [Word8] -> Bool
bodyRoundTripProperty octets =
  let arbitraryBody = ByteString.pack octets
      request =
        signedRequest
          signer
          ProviderWorkApply
          ProviderWorkerRuntime
          scopeA
          authorityEpochGenesis
          deadline
          nonceA
          arbitraryBody
   in case decodeAndVerifyControlPlaneRequest
        maximumEnvelopeBytes
        fixtureContext
        (encodeSignedControlPlaneRequest request) of
        Left _ -> False
        Right verified -> verifiedRequestBody verified == arbitraryBody

deterministicSigningProperty :: [Word8] -> Bool
deterministicSigningProperty octets =
  let arbitraryBody = ByteString.pack octets
      first =
        signedRequest
          signer
          ProviderWorkApply
          ProviderWorkerRuntime
          scopeA
          authorityEpochGenesis
          deadline
          nonceA
          arbitraryBody
      second =
        signedRequest
          signer
          ProviderWorkApply
          ProviderWorkerRuntime
          scopeA
          authorityEpochGenesis
          deadline
          nonceA
          arbitraryBody
   in encodeSignedControlPlaneRequest first == encodeSignedControlPlaneRequest second

-- These test-only wire mirrors intentionally freeze the primitive canonical
-- compatibility surface without exposing an unverified decoder from the library.
data TestClaimsWire = TestClaimsWire
  { testWireProtocol :: !Text
  , testWireSchema :: !Word
  , testWireRoute :: !Word
  , testWireCallerPrincipal :: !Word
  , testWireCalleeRole :: !Word
  , testWireAuthorityScope :: !Text
  , testWireAuthorityEpoch :: !Natural
  , testWireDeadlineMicros :: !Natural
  , testWireNonce :: !ByteString
  , testWireSigningKeyGeneration :: !Natural
  , testWireBodyDigest :: !ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data TestSignedWire = TestSignedWire
  { testWireClaims :: !TestClaimsWire
  , testWireBody :: !ByteString
  , testWireSignature :: !ByteString
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

baseTestWire :: TestSignedWire
baseTestWire = decodeTestWire (encodeSignedControlPlaneRequest fixtureRequest)

updateClaims :: (TestClaimsWire -> TestClaimsWire) -> TestSignedWire
updateClaims transform =
  baseTestWire {testWireClaims = transform (testWireClaims baseTestWire)}

verifyMalformed :: TestSignedWire -> Either RequestAuthenticationError VerifiedControlPlaneRequest
verifyMalformed =
  decodeAndVerifyControlPlaneRequest maximumEnvelopeBytes fixtureContext . serialise

decodeTestWire :: LazyByteString.ByteString -> TestSignedWire
decodeTestWire encoded = case deserialiseOrFail encoded of
  Left err -> error (show err)
  Right wire -> wire

makeSchemaVersionNonCanonical :: LazyByteString.ByteString -> LazyByteString.ByteString
makeSchemaVersionNonCanonical encoded =
  LazyByteString.fromStrict
    (prefix <> protocolEncoding <> "\x18\x01" <> ByteString.drop (ByteString.length needle) suffix)
 where
  strict = LazyByteString.toStrict encoded
  protocolEncoding = LazyByteString.toStrict (serialise ("prodbox-control-plane-request" :: Text))
  needle = protocolEncoding <> "\x01"
  (prefix, suffix) = ByteString.breakSubstring needle strict

flipLastByte :: ByteString -> ByteString
flipLastByte bytes =
  ByteString.snoc
    (ByteString.init bytes)
    (ByteString.last bytes `xor` 0xFF)

verify
  :: RequestVerificationContext
  -> SignedControlPlaneRequest
  -> IO VerifiedControlPlaneRequest
verify context request =
  mustRightIO
    ( decodeAndVerifyControlPlaneRequest
        maximumEnvelopeBytes
        context
        (encodeSignedControlPlaneRequest request)
    )

verifyError
  :: RequestVerificationContext
  -> SignedControlPlaneRequest
  -> RequestAuthenticationError
verifyError context request =
  case decodeAndVerifyControlPlaneRequest
    maximumEnvelopeBytes
    context
    (encodeSignedControlPlaneRequest request) of
    Left err -> err
    Right _ -> error "expected request authentication to fail"

signedRequest
  :: RequestSigner
  -> ControlPlaneRoute
  -> RuntimeRole
  -> AuthorityScope
  -> AuthorityEpoch
  -> AuthorityTime
  -> RequestNonce
  -> ByteString
  -> SignedControlPlaneRequest
signedRequest requestSigner route callee scope epoch requestDeadline nonce requestBody =
  mustRight
    ( signControlPlaneRequest
        requestSigner
        route
        callee
        scope
        epoch
        requestDeadline
        nonce
        requestBody
    )

contextFor
  :: TrustedRequestKey
  -> ControlPlaneRoute
  -> RuntimeRole
  -> AuthorityScope
  -> AuthorityEpoch
  -> AuthorityTime
  -> RequestNonce
  -> AuthorityTime
  -> AuthorityDuration
  -> IO RequestVerificationContext
contextFor key route callee scope epoch requestDeadline nonce currentTime maximumLifetimeBound =
  mustRightIO
    ( mkRequestVerificationContext
        key
        route
        callee
        scope
        epoch
        requestDeadline
        nonce
        currentTime
        maximumLifetimeBound
    )

signerFor :: CallerPrincipal -> SigningKeyGeneration -> RequestSigner
signerFor principal generation = mustRight (mkRequestSigner principal generation signingSeed)

signer :: RequestSigner
signer = signerFor (CallerService LifecycleAuthorityRuntime) generationOne

trusted :: TrustedRequestKey
trusted = trustedRequestKeyFromSigner signer

fixtureRequest :: SignedControlPlaneRequest
fixtureRequest =
  signedRequest
    signer
    ProviderWorkApply
    ProviderWorkerRuntime
    scopeA
    authorityEpochGenesis
    deadline
    nonceA
    body

fixtureContext :: RequestVerificationContext
fixtureContext =
  mustRight
    ( mkRequestVerificationContext
        trusted
        ProviderWorkApply
        ProviderWorkerRuntime
        scopeA
        authorityEpochGenesis
        deadline
        nonceA
        now
        maximumLifetime
    )

scopeA :: AuthorityScope
scopeA = mustRight (mkAuthorityScope "cluster-a")

scopeB :: AuthorityScope
scopeB = mustRight (mkAuthorityScope "cluster-b")

generationOne :: SigningKeyGeneration
generationOne = mustRight (mkSigningKeyGeneration 1)

generationTwo :: SigningKeyGeneration
generationTwo = mustRight (mkSigningKeyGeneration 2)

nonceA :: RequestNonce
nonceA = mustRight (mkRequestNonce (ByteString.pack [0 .. 15]))

nonceB :: RequestNonce
nonceB = mustRight (mkRequestNonce (ByteString.pack [16 .. 31]))

now :: AuthorityTime
now = authorityTimeFromMicros 1000

deadline :: AuthorityTime
deadline = authorityTimeFromMicros 2000

deadlineB :: AuthorityTime
deadlineB = authorityTimeFromMicros 2500

maximumLifetime :: AuthorityDuration
maximumLifetime = mustRight (authorityDurationFromMicros 5000)

body :: ByteString
body = "canonical-inner-request"

signingSeed :: ByteString
signingSeed = ByteString.pack [0 .. 31]

maximumEnvelopeBytes :: Int
maximumEnvelopeBytes = 65536

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Left err -> error (show err)
  Right value -> value

mustRightIO :: (Show err) => Either err value -> IO value
mustRightIO result = case result of
  Left err -> fail (show err)
  Right value -> pure value
