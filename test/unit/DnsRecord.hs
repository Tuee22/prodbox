{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

module DnsRecord (dnsRecordSuite) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Prodbox.Lifecycle.Authority.Genesis
  ( authorityEpochGenesis
  , nextAuthorityEpoch
  )
import Prodbox.Lifecycle.DnsRecord
import Prodbox.Lifecycle.ResourceClass (LifecycleClass (..))
import Prodbox.Runtime.Role (RuntimeRole (..))
import Prodbox.Substrate (Substrate (..))
import TestSupport

dnsRecordSuite :: SuiteBuilder ()
dnsRecordSuite =
  describe "exact registered DNS record programs" $ do
    it "binds public A records to exact owner/type/account/zone/name/epoch" $ do
      dnsCoordinateName homeA `shouldBe` "prodbox.example.com"
      dnsCoordinateType homeA `shouldBe` DnsRecordA
      dnsCoordinateOwner homeA `shouldBe` HomeGatewayDnsOwner
      awsAccountIdText (dnsCoordinateAccount homeA) `shouldBe` "123456789012"
      hostedZoneIdText (dnsCoordinateZone homeA) `shouldBe` "Z123EXAMPLE"
      ownershipEpochValue (dnsCoordinateEpoch homeA) `shouldBe` 1
      dnsRecordLifecycleClass homeA `shouldBe` LongLived
      dnsRecordLifecycleClass awsA `shouldBe` PerRun

    it "derives DNS01 TXT coordinates from Certificate and Challenge UIDs" $
      case dns01 of
        Dns01ChallengeRegistration _ _ coordinate -> do
          dnsCoordinateName coordinate `shouldBe` "_acme-challenge.prodbox.example.com"
          dnsCoordinateType coordinate `shouldBe` DnsRecordTxt
          dnsCoordinateOwner coordinate `shouldBe` HomeCertManagerDns01Owner
        _ -> expectationFailure "expected DNS01 registration"

    it "makes wrong owner/type combinations and invalid values unconstructible" $ do
      mkPublicARecordCoordinate account zone "prodbox.example.com" HomeCertManagerDns01Owner epoch
        `shouldBe` Left (DnsOwnerTypeMismatch HomeCertManagerDns01Owner DnsRecordA)
      mkDnsRecordValue DnsRecordA "999.0.0.1" `shouldSatisfy` isLeft
      mkDnsRecordValue DnsRecordA "01.2.3.4" `shouldSatisfy` isLeft
      mkDnsRecordValue DnsRecordTxt "" `shouldBe` Left DnsRecordValueEmpty

    it "Sprint 4.73: decides every owner/type pair rather than defaulting" $ do
      -- The superseded rule ended in a wildcard `False`, so the two record
      -- types added for the SES lane would have been rejected for every owner
      -- without anyone deciding that. Stating the whole matrix as data here
      -- means a new owner or type shows up as a failure, not as a silent
      -- rejection.
      let matrix =
            [ (owner, recordType)
            | owner <- allDnsRecordOwners
            , recordType <- allDnsRecordTypes
            , ownerAcceptsType owner recordType
            ]
      (length allDnsRecordOwners * length allDnsRecordTypes) `shouldBe` 20
      matrix
        `shouldBe` [ (HomeGatewayDnsOwner, DnsRecordA)
                   , (AwsLifecycleProviderDnsOwner, DnsRecordA)
                   , (AwsSesDnsOwner, DnsRecordTxt)
                   , (AwsSesDnsOwner, DnsRecordCname)
                   , (AwsSesDnsOwner, DnsRecordMx)
                   , (HomeCertManagerDns01Owner, DnsRecordTxt)
                   , (AwsCertManagerDns01Owner, DnsRecordTxt)
                   ]

    it "Sprint 4.73: binds the three SES coordinates to their exact names" $ do
      dnsCoordinateName sesVerification `shouldBe` "_amazonses.example.com"
      dnsCoordinateType sesVerification `shouldBe` DnsRecordTxt
      dnsCoordinateName sesDkim `shouldBe` "abc123._domainkey.example.com"
      dnsCoordinateType sesDkim `shouldBe` DnsRecordCname
      dnsCoordinateName sesInboundMx `shouldBe` "mail.example.com"
      dnsCoordinateType sesInboundMx `shouldBe` DnsRecordMx
      -- The SES records live in the operator's retained parent zone, so the
      -- owner that carries them must not classify them with the per-run
      -- provider lane.
      dnsRecordLifecycleClass sesVerification `shouldBe` LongLived
      dnsRecordLifecycleClass sesDkim `shouldBe` LongLived
      dnsRecordLifecycleClass sesInboundMx `shouldBe` LongLived
      -- The public A-record lane keeps its own owner, and neither lane can
      -- borrow the other's record types.
      mkSesVerificationCoordinate account zone "example.com" AwsLifecycleProviderDnsOwner epoch
        `shouldBe` Left (DnsOwnerTypeMismatch AwsLifecycleProviderDnsOwner DnsRecordTxt)
      mkPublicARecordCoordinate account zone "aws.example.com" AwsSesDnsOwner epoch
        `shouldBe` Left (DnsOwnerTypeMismatch AwsSesDnsOwner DnsRecordA)
      mkSesDkimCoordinate account zone "not a token" "example.com" AwsSesDnsOwner epoch
        `shouldBe` Left (SesDkimTokenInvalid "not a token")

    it "Sprint 4.73: gives CNAME and MX values one canonical spelling" $ do
      -- Route 53 echoes back either spelling of the same name, so canonicalizing
      -- in the constructor is what lets the read-back stay exact equality: a
      -- record that is already correct must not read as drift and provoke a
      -- rewrite.
      let cname = mkDnsRecordValue DnsRecordCname
          mx = mkDnsRecordValue DnsRecordMx
      cname "abc123.dkim.amazonses.com." `shouldBe` cname "ABC123.dkim.AmazonSES.com"
      fmap dnsRecordValueText (cname "abc123.dkim.amazonses.com")
        `shouldBe` Right "abc123.dkim.amazonses.com."
      mx "10 inbound-smtp.us-west-2.amazonaws.com."
        `shouldBe` mx "10 inbound-smtp.us-west-2.amazonaws.com"
      fmap dnsRecordValueText (mx "10 inbound-smtp.us-west-2.amazonaws.com")
        `shouldBe` Right "10 inbound-smtp.us-west-2.amazonaws.com."
      -- A TXT value keeps its exact bytes, quotes included.
      fmap dnsRecordValueText (mkDnsRecordValue DnsRecordTxt "\"Token\"")
        `shouldBe` Right "\"Token\""
      cname "-leading.example.com" `shouldSatisfy` isLeft
      cname "example..com" `shouldSatisfy` isLeft
      mx "inbound-smtp.us-west-2.amazonaws.com." `shouldSatisfy` isLeft
      mx "65536 inbound-smtp.us-west-2.amazonaws.com." `shouldSatisfy` isLeft
      mx "010 inbound-smtp.us-west-2.amazonaws.com." `shouldSatisfy` isLeft

    it "ensures with exact authoritative read-back and exact idempotency" $ do
      observations <- newIORef [DnsRecordMissing, DnsRecordObserved recordSet]
      calls <- newIORef ([] :: [String])
      result <-
        runDnsRecordProgram
          (boundary calls observations homeA)
          homeA
          (EnsureDnsRecord homeGatewayAuthority recordSet)
      result `shouldBe` DnsEnsureAppliedAndReadBack
      readIORef calls `shouldReturn` ["observe", "ensure", "observe"]

      alreadyCalls <- newIORef ([] :: [String])
      already <- newIORef [DnsRecordObserved recordSet]
      idempotent <-
        runDnsRecordProgram
          (boundary alreadyCalls already homeA)
          homeA
          (EnsureDnsRecord homeGatewayAuthority recordSet)
      idempotent `shouldBe` DnsEnsureAlreadyConverged
      readIORef alreadyCalls `shouldReturn` ["observe"]

    it "destroys only under the registered owner and proves exact absence" $ do
      observations <- newIORef [DnsRecordObserved recordSet, DnsRecordMissing]
      calls <- newIORef ([] :: [String])
      result <-
        runDnsRecordProgram
          (boundary calls observations homeA)
          homeA
          (DestroyDnsRecord homeGatewayAuthority)
      result `shouldBe` DnsDestroyAppliedAndReadBack
      readIORef calls `shouldReturn` ["observe", "destroy", "observe"]

      wrongOwnerCalls <- newIORef ([] :: [String])
      wrongOwnerObservations <- newIORef [DnsRecordObserved recordSet]
      refused <-
        runDnsRecordProgram
          (boundary wrongOwnerCalls wrongOwnerObservations awsA)
          homeA
          (DestroyDnsRecord homeGatewayAuthority)
      refused
        `shouldBe` DnsProgramOwnerMismatch HomeGatewayDnsOwner AwsLifecycleProviderDnsOwner
      readIORef wrongOwnerCalls `shouldReturn` []

    it "refuses a same-owner boundary bound to a different authority epoch" $ do
      calls <- newIORef ([] :: [String])
      observations <- newIORef [DnsRecordObserved recordSet]
      let otherHome =
            accepted
              ( mkPublicARecordCoordinate
                  account
                  zone
                  "prodbox.example.com"
                  HomeGatewayDnsOwner
                  (mkOwnershipEpoch (nextAuthorityEpoch authorityEpochGenesis))
              )
      result <-
        runDnsRecordProgram
          (boundary calls observations otherHome)
          homeA
          (EnsureDnsRecord homeGatewayAuthority recordSet)
      result `shouldBe` DnsProgramCoordinateMismatch homeA otherHome
      readIORef calls `shouldReturn` []

    it "treats TTL drift as drift even when the record values match" $ do
      calls <- newIORef ([] :: [String])
      let stale = accepted (mkDnsRecordSet 300 (ipValue :| []))
      observations <- newIORef [DnsRecordObserved stale, DnsRecordObserved recordSet]
      result <-
        runDnsRecordProgram
          (boundary calls observations homeA)
          homeA
          (EnsureDnsRecord homeGatewayAuthority recordSet)
      result `shouldBe` DnsEnsureAppliedAndReadBack
      readIORef calls `shouldReturn` ["observe", "ensure", "observe"]
      dnsRecordSetValues recordSet `shouldBe` Set.singleton ipValue
      dnsRecordSetTtl recordSet `shouldBe` 60

    it "never converts endpoint-unready, unobservable, or failed mutation into absence" $ do
      mapM_
        ( \observation -> do
            calls <- newIORef ([] :: [String])
            observations <- newIORef [observation]
            result <-
              runDnsRecordProgram
                (boundary calls observations homeA)
                homeA
                (DestroyDnsRecord homeGatewayAuthority)
            result `shouldBe` DnsProgramInitialObservationRefused observation
            readIORef calls `shouldReturn` ["observe"]
        )
        [DnsRecordEndpointUnready "warming", DnsRecordUnobservable "forbidden"]
      calls <- newIORef ([] :: [String])
      observations <-
        newIORef [DnsRecordObserved recordSet, DnsRecordUnobservable "api down"]
      result <-
        runDnsRecordProgram
          (boundaryWithMutation calls observations homeA (Left "delete failed"))
          homeA
          (DestroyDnsRecord homeGatewayAuthority)
      result
        `shouldBe` DnsProgramMutationFailed "delete failed" (DnsRecordUnobservable "api down")
      readIORef calls `shouldReturn` ["observe", "destroy", "observe"]

boundary
  :: IORef [String]
  -> IORef [DnsRecordObservation]
  -> DnsRecordCoordinate
  -> DnsRecordBoundary IO
boundary calls observations coordinate =
  boundaryWithMutation calls observations coordinate (Right ())

boundaryWithMutation
  :: IORef [String]
  -> IORef [DnsRecordObservation]
  -> DnsRecordCoordinate
  -> Either Text ()
  -> DnsRecordBoundary IO
boundaryWithMutation calls observations coordinate mutation =
  DnsRecordBoundary
    { dnsBoundaryCoordinate = coordinate
    , dnsBoundaryObserve = modifyIORef' calls (++ ["observe"]) >> pop observations
    , dnsBoundaryEnsure = \_ -> modifyIORef' calls (++ ["ensure"]) >> pure mutation
    , dnsBoundaryDestroy = \_ -> modifyIORef' calls (++ ["destroy"]) >> pure mutation
    }

pop :: IORef [DnsRecordObservation] -> IO DnsRecordObservation
pop ref = do
  values <- readIORef ref
  case values of
    value : remaining -> modifyIORef' ref (const remaining) >> pure value
    [] -> pure (DnsRecordUnobservable "fixture exhausted")

account :: AwsAccountId
account = accepted (mkAwsAccountId "123456789012")

zone :: HostedZoneId
zone = accepted (mkHostedZoneId "Z123EXAMPLE")

epoch :: OwnershipEpoch
epoch = mkOwnershipEpoch authorityEpochGenesis

homeA :: DnsRecordCoordinate
homeA = accepted (mkPublicARecordCoordinate account zone "prodbox.example.com" HomeGatewayDnsOwner epoch)

homeGatewayAuthority :: DnsOwnerAuthority
homeGatewayAuthority =
  case dnsOwnerAuthorityForProcess GatewayRuntime SubstrateHomeLocal HomeGatewayDnsOwner of
    Just authority -> authority
    Nothing -> error "the home gateway holds its own DNS ownership"

sesVerification :: DnsRecordCoordinate
sesVerification =
  accepted (mkSesVerificationCoordinate account zone "example.com" AwsSesDnsOwner epoch)

sesDkim :: DnsRecordCoordinate
sesDkim =
  accepted (mkSesDkimCoordinate account zone "abc123" "example.com" AwsSesDnsOwner epoch)

sesInboundMx :: DnsRecordCoordinate
sesInboundMx =
  accepted (mkSesInboundMxCoordinate account zone "mail.example.com" AwsSesDnsOwner epoch)

awsA :: DnsRecordCoordinate
awsA =
  accepted
    (mkPublicARecordCoordinate account zone "aws.example.com" AwsLifecycleProviderDnsOwner epoch)

dns01 :: DnsRecordRegistration
dns01 =
  accepted
    ( mkDns01ChallengeRegistration
        account
        zone
        "prodbox.example.com"
        HomeCertManagerDns01Owner
        epoch
        (accepted (mkKubernetesUid "certificate-uid"))
        (accepted (mkKubernetesUid "challenge-uid"))
    )

ipValue :: DnsRecordValue
ipValue = accepted (mkDnsRecordValue DnsRecordA "192.0.2.10")

recordSet :: DnsRecordSet
recordSet = accepted (mkDnsRecordSet 60 (ipValue :| []))

accepted :: (Show err) => Either err value -> value
accepted result = case result of
  Right value -> value
  Left err -> error (show err)

isLeft :: Either left right -> Bool
isLeft result = case result of
  Left _ -> True
  Right _ -> False
