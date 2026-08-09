{-# LANGUAGE GADTs #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 3.32: a DNS destroy consumes the authority the running process
-- holds, not a second caller-supplied copy of the coordinate's owner.
module DnsOwnerAuthoritySuite (dnsOwnerAuthoritySuite) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (mapMaybe)
import Prodbox.CheckCode (dnsOwnerAuthorityInternalSourceViolations)
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
            , Just authority <- [dnsOwnerAuthorityForProcess role substrate]
            ]
      minted
        `shouldBe` [ (GatewayRuntime, SubstrateHomeLocal, HomeGatewayDnsOwner)
                   , (ProviderWorkerRuntime, SubstrateAws, AwsLifecycleProviderDnsOwner)
                   ]

    it "covers every role/substrate pair, so a new role cannot default to holding nothing" $ do
      let pairs = [(role, substrate) | role <- allRuntimeRoles, substrate <- allSubstrates]
      length pairs `shouldBe` 14
      length (filter (\(role, substrate) -> mints role substrate) pairs) `shouldBe` 2

    it "puts neither cert-manager owner in the minter's range" $ do
      let reachable =
            mapMaybe
              (fmap authorizedDnsOwner . uncurry dnsOwnerAuthorityForProcess)
              [(role, substrate) | role <- allRuntimeRoles, substrate <- allSubstrates]
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
mints role substrate = case dnsOwnerAuthorityForProcess role substrate of
  Just _ -> True
  Nothing -> False

homeGatewayAuthority :: DnsOwnerAuthority
homeGatewayAuthority =
  case dnsOwnerAuthorityForProcess GatewayRuntime SubstrateHomeLocal of
    Just authority -> authority
    Nothing -> error "the home gateway holds its own DNS ownership"

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
