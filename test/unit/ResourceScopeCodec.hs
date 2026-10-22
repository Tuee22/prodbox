{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module ResourceScopeCodec (resourceScopeCodecSuite) where

import Codec.CBOR.Read (deserialiseFromBytes)
import Codec.CBOR.Term (Term (..), decodeTerm, encodeTerm)
import Codec.CBOR.Write (toLazyByteString)
import Codec.Serialise (deserialiseOrFail, serialise)
import Data.ByteString (ByteString)
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Either (isLeft)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Prodbox.Lifecycle.CleanupRun (cleanupGraphDigest, mkCleanupRunId)
import Prodbox.Lifecycle.DnsRecord (HostedZoneId, mkHostedZoneId)
import Prodbox.Lifecycle.Teardown.Graph
  ( compileDesiredAbsenceGraphWithBindings
  , compiledDesiredAbsenceGraph
  , compiledDesiredAbsenceObservationScope
  )
import Prodbox.Lifecycle.Teardown.Model
import Prodbox.Lifecycle.Teardown.ResourceScopeBindings
import Prodbox.Lifecycle.Teardown.RetainedNames
import Prodbox.Lifecycle.Teardown.ScopeCodec
import Prodbox.Settings.Coordinate (mkS3BucketName)
import TestSupport

resourceScopeCodecSuite :: SuiteBuilder ()
resourceScopeCodecSuite = describe "Sprint 5.53 durable cleanup scope codec" $ do
  it "seals home DNS, mail and retained names into the complete cascade program" $ do
    let run = must (mkCleanupRunId "full-bound-cascade")
        names =
          must (mkRetainedNameBinding "fixture-state" "fixture-capture-mail" "example.test" "fixture-cluster")
        home = must (mkHomeDns01Scope parentZone ("auth.example.test" :| []))
        mail =
          must
            ( mkInviteMailScope
                (must (mkS3BucketName "fixture-capture-mail"))
                (ValidationInviteDomain "receive.example.test")
            )
        original = mkResourceScopeBindingsWithAudit (Just home) (Just mail) names
        changed =
          mkResourceScopeBindingsWithAudit
            (Just home)
            ( Just
                ( must
                    ( mkInviteMailScope
                        (must (mkS3BucketName "fixture-capture-mail"))
                        (ValidationInviteDomain "other.example.test")
                    )
                )
            )
            names
        compile selected =
          must
            ( compileDesiredAbsenceGraphWithBindings
                run
                (LinuxRke2FoundationId "home-rke2")
                (Just (AwsScope (AwsAccountId "123456789012") (AwsRegion (fixtureAwsRegion FixtureCaCentral1))))
                (Just substrateZone)
                (Just selected)
                CascadeSurface
            )
        program = compile original
    evidenceResourceScopeBindings (compiledDesiredAbsenceObservationScope program)
      `shouldBe` Just original
    cleanupGraphDigest (compiledDesiredAbsenceGraph program)
      `shouldNotBe` cleanupGraphDigest (compiledDesiredAbsenceGraph (compile changed))
  it "preserves both parent and substrate zones with the exact mail binding" $ do
    decodeScope (serialise (scopeToWire boundScope)) `shouldBe` Right boundScope
    evidenceAwsDnsZone boundScope `shouldBe` Just substrateZone
    fmap homeDns01HostedZone (evidenceResourceScopeBindings boundScope >>= resourceScopeHomeDns01)
      `shouldBe` Just parentZone
  it "retains the measured historical encoding and identity without inventing bindings" $ do
    let bytes = LazyByteString.fromStrict (must (Base64.decode legacyBase64))
    decodeScope bytes `shouldBe` Right legacyScope
    serialise (scopeToWire legacyScope) `shouldBe` bytes
    evidenceResourceScopeBindings legacyScope `shouldBe` Nothing
    scopeIdentityText legacyScope `shouldBe` legacyIdentity
  it "retains the exact audit names across recovery and binds each into the scope identity" $ do
    let home =
          resourceScopeHomeDns01
            (bindings parentZone "auth.example.test" "fixture-capture-mail" "test-abc123@receive.example.test")
        mail =
          resourceScopeInviteMail
            (bindings parentZone "auth.example.test" "fixture-capture-mail" "test-abc123@receive.example.test")
        names =
          must (mkRetainedNameBinding "fixture-state" "fixture-capture-mail" "example.test" "fixture-cluster")
        audited value = withBindings (mkResourceScopeBindingsWithAudit home mail value)
        alternatives =
          [ must (mkRetainedNameBinding "another-state" "fixture-capture-mail" "example.test" "fixture-cluster")
          , must (mkRetainedNameBinding "fixture-state" "another-capture-mail" "example.test" "fixture-cluster")
          , must
              ( mkRetainedNameBinding
                  "fixture-state"
                  "fixture-capture-mail"
                  "another.example.test"
                  "fixture-cluster"
              )
          , must (mkRetainedNameBinding "fixture-state" "fixture-capture-mail" "example.test" "another-cluster")
          ]
    decodeScope (serialise (scopeToWire (audited names))) `shouldBe` Right (audited names)
    evidenceResourceScopeBindings (scopeForTerminalAudit (audited names))
      `shouldBe` evidenceResourceScopeBindings (audited names)
    mapM_
      (\value -> scopeIdentityText (audited value) `shouldSatisfy` (/= scopeIdentityText (audited names)))
      alternatives
  it "distinguishes known empty coordinates from an unbound historical scope" $ do
    let empty = withBindings emptyResourceScopeBindings
    decodeScope (serialise (scopeToWire empty)) `shouldBe` Right empty
    scopeIdentityText empty `shouldSatisfy` (/= scopeIdentityText legacyScope)
  it "binds every resource coordinate into the identity" $ do
    let alternatives =
          [ bindings otherZone "auth.example.test" "fixture-capture-mail" "test-abc123@receive.example.test"
          , bindings parentZone "api.example.test" "fixture-capture-mail" "test-abc123@receive.example.test"
          , bindings parentZone "auth.example.test" "another-capture-mail" "test-abc123@receive.example.test"
          , bindings parentZone "auth.example.test" "fixture-capture-mail" "test-def456@receive.example.test"
          ]
    mapM_
      (\value -> scopeIdentityText (withBindings value) `shouldSatisfy` (/= scopeIdentityText boundScope))
      alternatives
  it "preserves all bound coordinates through terminal audit and manifest re-scoping" $
    mapM_
      ( \rescope ->
          evidenceResourceScopeBindings (rescope boundScope)
            `shouldBe` evidenceResourceScopeBindings boundScope
      )
      [scopeForTerminalAudit, scopeForCascadeTerminalAudit, scopeForOwnershipManifestCleanupReadBack]
  it "refuses unknown scope tags and incomplete extension fields" $ do
    let term = scopeTerm
    decodeScope (toLazyByteString (encodeTerm (replaceIndex 0 (TInt 99) term))) `shouldSatisfy` isLeft
    case term of
      TList fields -> decodeScope (toLazyByteString (encodeTerm (TList (init fields)))) `shouldSatisfy` isLeft
      _ -> expectationFailure "fixture scope is not a CBOR list"
  it "refuses a mail selector outside the closed selector set" $ do
    let invalid =
          modifyBindings
            (replaceIndex 2 (TList [TString "fixture-capture-mail", TInt 2, TString "receive.example.test"]))
            scopeTerm
    decodeScope (toLazyByteString (encodeTerm invalid)) `shouldSatisfy` isLeft
  it "refuses noncanonical DNS coordinates instead of silently changing scope" $ do
    let invalid =
          modifyBindings
            ( replaceIndex
                1
                (TList [TString "ZPARENTEXAMPLE", TList [TString "_acme-challenge.AUTH.example.test."]])
            )
            scopeTerm
    decodeScope (toLazyByteString (encodeTerm invalid)) `shouldSatisfy` isLeft
  it "rejects the DNS array bound before reading its elements" $ do
    let invalid =
          modifyBindings
            ( replaceIndex
                1
                ( TList
                    [TString "ZPARENTEXAMPLE", TList (replicate 12 (TString "_acme-challenge.auth.example.test."))]
                )
            )
            scopeTerm
    decodeScope (toLazyByteString (encodeTerm invalid)) `shouldSatisfy` isLeft
 where
  scopeTerm = snd (must (deserialiseFromBytes decodeTerm (serialise (scopeToWire boundScope))))

replaceIndex :: Int -> Term -> Term -> Term
replaceIndex selected replacement term = case term of
  TList values -> TList [if index == selected then replacement else value | (index, value) <- zip [0 ..] values]
  _ -> term

modifyBindings :: (Term -> Term) -> Term -> Term
modifyBindings change term = case term of
  TList values -> TList (init values <> [change (last values)])
  _ -> term

decodeScope :: LazyByteString.ByteString -> Either String ObservationEvidenceScope
decodeScope bytes = do
  wire <- either (Left . show) Right (deserialiseOrFail bytes)
  either (Left . show) Right (scopeFromWire wire)

legacyScope :: ObservationEvidenceScope
legacyScope =
  mkObservationEvidenceScopeWithDnsZone
    ExplicitPerRun
    (RegistryRevision "lifecycle-registry/v1")
    (DurableObservationRunScope "fixture-cleanup-run")
    (LinuxRke2FoundationId "fixture-home")
    (Just (AwsScope (AwsAccountId "123456789012") (AwsRegion (fixtureAwsRegion FixtureCaCentral1))))
    substrateZone
    ReconcileDesiredAbsent

withBindings :: ResourceScopeBindings -> ObservationEvidenceScope
withBindings value =
  observationEvidenceScopeFromFields
    (observationEvidenceScopeFields legacyScope) {scopeFieldResourceBindings = Just value}

boundScope :: ObservationEvidenceScope
boundScope =
  withBindings
    (bindings parentZone "auth.example.test" "fixture-capture-mail" "test-abc123@receive.example.test")

bindings :: HostedZoneId -> Text -> Text -> Text -> ResourceScopeBindings
bindings zone name bucket recipient =
  mkResourceScopeBindings
    (Just (must (mkHomeDns01Scope zone (name :| []))))
    (Just (must (mkInviteMailScope (must (mkS3BucketName bucket)) (ExactInviteRecipient recipient))))

parentZone, otherZone, substrateZone :: HostedZoneId
parentZone = must (mkHostedZoneId "ZPARENTEXAMPLE")
otherZone = must (mkHostedZoneId "ZOTHEREXAMPLE")
substrateZone = must (mkHostedZoneId "Z0123456789ABCDEFGHIJ")

legacyBase64 :: ByteString
legacyBase64 =
  "iQACdWxpZmVjeWNsZS1yZWdpc3RyeS92MXNmaXh0dXJlLWNsZWFudXAtcnVubGZpeHR1cmUtaG9tZYFsMTIzNDU2Nzg5MDEygWxjYS1jZW50cmFsLTGBdVowMTIzNDU2Nzg5QUJDREVGR0hJSgA="
legacyIdentity :: Text
legacyIdentity =
  "14:ExplicitPerRun21:lifecycle-registry/v119:fixture-cleanup-run12:fixture-home11:aws/present12:12345678901212:ca-central-112:zone/present21:Z0123456789ABCDEFGHIJ22:ReconcileDesiredAbsent"

must :: (Show error) => Either error value -> value
must = either (error . show) id
