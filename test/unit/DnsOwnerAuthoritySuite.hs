{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 3.32: a DNS destroy consumes the authority the running process
-- holds, not a second caller-supplied copy of the coordinate's owner.
module DnsOwnerAuthoritySuite (dnsOwnerAuthoritySuite) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (isNothing)
import Data.Text qualified as Text
import Prodbox.CheckCode (dnsOwnerAuthorityInternalSourceViolations)
import Prodbox.ControlPlane.ProviderProduction
  ( providerDnsOwnerAuthority
  , publicARecordProgramOutcome
  , sesDnsOwnerAuthority
  , sesDnsProgramOutcome
  )
import Prodbox.Lifecycle.Authority.Genesis (authorityEpochGenesis)
import Prodbox.Lifecycle.DnsRecord
import Prodbox.Runtime.Role (RuntimeRole (..), allRuntimeRoles)
import Prodbox.Substrate (Substrate (..), allSubstrates)
import TestSupport

dnsOwnerAuthoritySuite :: SuiteBuilder ()
dnsOwnerAuthoritySuite =
  describe "Sprint 3.32 caller-bound DNS ownership authority" $ do
    it "mints an authority only for the two roles that own DNS, on their own substrate" $ do
      let minted =
            [ (role, substrate, authorizedDnsOwner authority)
            | role <- allRuntimeRoles
            , substrate <- allSubstrates
            , authority <- dnsOwnerAuthoritiesForProcess role substrate
            ]
      -- Sprint 4.73: the Provider Worker holds two lanes, not one. The public A
      -- record is per-run and the SES records live in the operator's retained
      -- parent zone, so one owner would have had to be wrong about the
      -- lifecycle class and about which record types the lane may write.
      minted
        `shouldBe` [ (GatewayRuntime, SubstrateHomeLocal, HomeGatewayDnsOwner)
                   , (ProviderWorkerRuntime, SubstrateAws, AwsLifecycleProviderDnsOwner)
                   , (ProviderWorkerRuntime, SubstrateAws, AwsSesDnsOwner)
                   ]

    it "Sprint 4.73: a lane a process does not hold is still unmintable" $ do
      -- Widening the range to a list did not widen who may hold a lane. Naming
      -- an owner remains different from holding one.
      dnsOwnerAuthorityForProcess ProviderWorkerRuntime SubstrateAws HomeGatewayDnsOwner
        `shouldSatisfy` isNothing
      dnsOwnerAuthorityForProcess GatewayRuntime SubstrateHomeLocal AwsSesDnsOwner
        `shouldSatisfy` isNothing
      dnsOwnerAuthorityForProcess GatewayRuntime SubstrateAws AwsLifecycleProviderDnsOwner
        `shouldSatisfy` isNothing
      fmap
        authorizedDnsOwner
        (dnsOwnerAuthorityForProcess ProviderWorkerRuntime SubstrateAws AwsSesDnsOwner)
        `shouldBe` Just AwsSesDnsOwner

    it "Sprint 4.73: the SES writer holds the SES lane and names its refusals" $ do
      authorizedDnsOwner sesDnsOwnerAuthority `shouldBe` AwsSesDnsOwner
      sesDnsProgramOutcome sesTxt DnsEnsureAlreadyConverged `shouldBe` Right ()
      sesDnsProgramOutcome sesTxt DnsEnsureAppliedAndReadBack `shouldBe` Right ()
      case sesDnsProgramOutcome
        sesTxt
        (DnsProgramOwnerUnauthorized AwsLifecycleProviderDnsOwner AwsSesDnsOwner) of
        Right () -> expectationFailure "an unauthorized owner was reported as success"
        Left detail -> do
          -- Five lanes run in sequence, so the refusal has to say which record
          -- provoked it as well as which refusal it was.
          unpackText detail `shouldContain` "_amazonses.example.com"
          unpackText detail `shouldContain` "AwsLifecycleProviderDnsOwner"
      case sesDnsProgramOutcome sesTxt (DnsProgramPostconditionFailed DnsRecordMissing) of
        Right () -> expectationFailure "a failed read-back was reported as success"
        Left detail -> unpackText detail `shouldContain` "read-back"

    it "Sprint 4.72: the Provider Worker's production writer holds the AWS owner" $ do
      -- Until this sprint `DnsRecordProgram` had NO production caller at all —
      -- it was exercised only by this suite and one other, so the guarantee it
      -- exists to provide bounded nothing that actually runs. The public A
      -- record writer now consumes the same compiled authority the minter
      -- produces for this role, and there is no second owner it could name.
      authorizedDnsOwner providerDnsOwnerAuthority `shouldBe` AwsLifecycleProviderDnsOwner

    it "Sprint 4.72: the writer distinguishes both ownership refusals from success" $ do
      -- A refusal reaching the provider lane as a bare `Left` would lose which
      -- of the program's refusals occurred, and the two ownership arms are the
      -- entire reason for routing through it.
      publicARecordProgramOutcome DnsEnsureAlreadyConverged `shouldBe` Right ()
      publicARecordProgramOutcome DnsEnsureAppliedAndReadBack `shouldBe` Right ()
      case publicARecordProgramOutcome
        (DnsProgramOwnerUnauthorized HomeGatewayDnsOwner AwsLifecycleProviderDnsOwner) of
        Right () -> expectationFailure "an unauthorized owner was reported as success"
        Left detail -> unpackText detail `shouldContain` "HomeGatewayDnsOwner"
      case publicARecordProgramOutcome
        (DnsProgramOwnerMismatch HomeGatewayDnsOwner AwsLifecycleProviderDnsOwner) of
        Right () -> expectationFailure "an owner mismatch was reported as success"
        Left detail -> unpackText detail `shouldContain` "mismatch"
      case publicARecordProgramOutcome (DnsProgramPostconditionFailed DnsRecordMissing) of
        Right () -> expectationFailure "a failed read-back was reported as success"
        Left detail -> unpackText detail `shouldContain` "read-back"

    it "covers every role/substrate pair, so a new role cannot default to holding nothing" $ do
      let pairs = [(role, substrate) | role <- allRuntimeRoles, substrate <- allSubstrates]
      length pairs `shouldBe` 14
      length (filter (\(role, substrate) -> mints role substrate) pairs) `shouldBe` 2

    it "puts neither cert-manager owner in the minter's range" $ do
      let reachable =
            map authorizedDnsOwner
              . concatMap (uncurry dnsOwnerAuthoritiesForProcess)
              $ [(role, substrate) | role <- allRuntimeRoles, substrate <- allSubstrates]
      filter (`elem` [HomeCertManagerDns01Owner, AwsCertManagerDns01Owner]) reachable
        `shouldBe` []
      -- Stated the other way round, so a new owner constructor shows up here.
      filter (`notElem` reachable) allDnsRecordOwners
        `shouldBe` [HomeCertManagerDns01Owner, AwsCertManagerDns01Owner]

    it "refuses a destroy whose held authority is not the coordinate's owner" $ do
      calls <- newIORef ([] :: [String])
      observations <- newIORef [DnsRecordObserved recordSet, DnsRecordMissing]
      -- The program and the boundary agree exactly: this is the case the
      -- coordinate-versus-boundary comparison admits, and the only thing that
      -- can refuse it is the process's own authority.
      result <-
        runDnsRecordProgram
          (boundary calls observations awsA)
          awsA
          (DestroyDnsRecord homeGatewayAuthority)
      result
        `shouldBe` DnsProgramOwnerUnauthorized HomeGatewayDnsOwner AwsLifecycleProviderDnsOwner
      readIORef calls `shouldReturn` []

    it "Sprint 3.33: refuses an ensure whose held authority is not the coordinate's owner" $ do
      calls <- newIORef ([] :: [String])
      observations <- newIORef [DnsRecordMissing, DnsRecordObserved recordSet]
      -- Program and boundary agree exactly, so the only thing that can refuse is
      -- the running process's own authority — and it refuses BEFORE the first
      -- observe, so an unauthorized writer never reaches Route 53 at all.
      result <-
        runDnsRecordProgram
          (boundary calls observations awsA)
          awsA
          (EnsureDnsRecord homeGatewayAuthority recordSet)
      result
        `shouldBe` DnsProgramOwnerUnauthorized HomeGatewayDnsOwner AwsLifecycleProviderDnsOwner
      readIORef calls `shouldReturn` []

    it "Sprint 3.33: ensures under the held authority and still reads back exactly" $ do
      calls <- newIORef ([] :: [String])
      observations <- newIORef [DnsRecordMissing, DnsRecordObserved recordSet]
      result <-
        runDnsRecordProgram
          (boundary calls observations homeA)
          homeA
          (EnsureDnsRecord homeGatewayAuthority recordSet)
      result `shouldBe` DnsEnsureAppliedAndReadBack
      readIORef calls `shouldReturn` ["observe", "ensure", "observe"]

    it "destroys under the held authority and still proves exact absence" $ do
      calls <- newIORef ([] :: [String])
      observations <- newIORef [DnsRecordObserved recordSet, DnsRecordMissing]
      result <-
        runDnsRecordProgram
          (boundary calls observations homeA)
          homeA
          (DestroyDnsRecord homeGatewayAuthority)
      result `shouldBe` DnsDestroyAppliedAndReadBack
      readIORef calls `shouldReturn` ["observe", "destroy", "observe"]

    it "still refuses a mis-bound boundary before it observes anything" $ do
      calls <- newIORef ([] :: [String])
      observations <- newIORef [DnsRecordObserved recordSet]
      result <-
        runDnsRecordProgram
          (boundary calls observations awsA)
          homeA
          (DestroyDnsRecord homeGatewayAuthority)
      result
        `shouldBe` DnsProgramOwnerMismatch HomeGatewayDnsOwner AwsLifecycleProviderDnsOwner
      readIORef calls `shouldReturn` []

    it "fails the build when any other production module names the minting representation" $ do
      let internalImport =
            "import Prodbox.Lifecycle.DnsRecord.Owner.Internal (DnsOwnerAuthority (..))\n"
      dnsOwnerAuthorityInternalSourceViolations
        ("src/Prodbox/Lifecycle/DnsRecord/Owner.hs", internalImport)
        `shouldBe` []
      dnsOwnerAuthorityInternalSourceViolations
        ("src/Prodbox/Lifecycle/DnsRecord/Owner/Internal.hs", internalImport)
        `shouldBe` []
      length
        ( dnsOwnerAuthorityInternalSourceViolations
            ("src/Prodbox/Gateway/Daemon.hs", internalImport)
        )
        `shouldBe` 1
      length
        ( dnsOwnerAuthorityInternalSourceViolations
            ("src/Prodbox/ControlPlane/ProviderProduction.hs", internalImport)
        )
        `shouldBe` 1
      dnsOwnerAuthorityInternalSourceViolations
        ("src/Prodbox/Gateway/Daemon.hs", "import Prodbox.Lifecycle.DnsRecord.Owner\n")
        `shouldBe` []

mints :: RuntimeRole -> Substrate -> Bool
mints role substrate = not (null (dnsOwnerAuthoritiesForProcess role substrate))

homeGatewayAuthority :: DnsOwnerAuthority
homeGatewayAuthority =
  case dnsOwnerAuthorityForProcess GatewayRuntime SubstrateHomeLocal HomeGatewayDnsOwner of
    Just authority -> authority
    Nothing -> error "the home gateway holds its own DNS ownership"

sesTxt :: DnsRecordCoordinate
sesTxt =
  accepted
    (mkSesVerificationCoordinate account zone "example.com" AwsSesDnsOwner epoch)

boundary
  :: IORef [String]
  -> IORef [DnsRecordObservation]
  -> DnsRecordCoordinate
  -> DnsRecordBoundary IO
boundary calls observations coordinate =
  DnsRecordBoundary
    { dnsBoundaryCoordinate = coordinate
    , dnsBoundaryObserve = modifyIORef' calls (++ ["observe"]) >> pop observations
    , dnsBoundaryEnsure = \_ -> modifyIORef' calls (++ ["ensure"]) >> pure (Right ())
    , dnsBoundaryDestroy = \_ -> modifyIORef' calls (++ ["destroy"]) >> pure (Right ())
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
homeA =
  accepted
    (mkPublicARecordCoordinate account zone "prodbox.example.com" HomeGatewayDnsOwner epoch)

awsA :: DnsRecordCoordinate
awsA =
  accepted
    (mkPublicARecordCoordinate account zone "aws.example.com" AwsLifecycleProviderDnsOwner epoch)

ipValue :: DnsRecordValue
ipValue = accepted (mkDnsRecordValue DnsRecordA "192.0.2.10")

recordSet :: DnsRecordSet
recordSet = accepted (mkDnsRecordSet 60 (ipValue :| []))

accepted :: (Show err) => Either err value -> value
accepted result = case result of
  Right value -> value
  Left err -> error (show err)

unpackText :: Text.Text -> String
unpackText = Text.unpack
