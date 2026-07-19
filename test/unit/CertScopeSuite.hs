{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 2.35: pure proofs for the certificate-scope algebra — the wildcard
-- boundary semantics (apex / single-label / deeper), the 'impliedBy' partial-order
-- laws, 'mkScopeSet' rejection of undelegated-zone wildcards, 'bindListener'
-- rejection of uncovered hosts, and coverage preservation under the
-- narrower-or-equal order (the restore-vs-reissue soundness). No cluster required.
module CertScopeSuite
  ( certScopeSuite
  )
where

import Data.Either (isLeft, isRight)
import Data.Text (Text)
import Prodbox.Tls.CertScope
import Test.Tasty.QuickCheck (Gen, elements, forAll, sublistOf)
import TestSupport

fq :: Text -> Fqdn
fq = either (error . renderScopeError) id . mkFqdn

zn :: Text -> DelegatedZone
zn = either (error . renderScopeError) id . mkDelegatedZone

-- | The delegated zones the generators anchor wildcards at.
poolZones :: [DelegatedZone]
poolZones =
  [ zn "resolvefintech.com"
  , zn "test.resolvefintech.com"
  , zn "aws.resolvefintech.com"
  ]

-- | Hosts spanning apex, single-label, and multi-label boundaries under the pool
-- zones, plus a disjoint zone.
poolHosts :: [Fqdn]
poolHosts =
  [ fq "resolvefintech.com" -- apex of a pool zone
  , fq "vscode.resolvefintech.com" -- single label under the parent
  , fq "api.test.resolvefintech.com" -- single label under a subzone
  , fq "a.b.resolvefintech.com" -- two labels deep
  , fq "test.resolvefintech.com" -- exact served host (also apex of a pool zone)
  , fq "unrelated.example.org" -- disjoint
  ]

genScope :: Gen CertScope
genScope =
  elements $
    map ScopeExact poolHosts ++ map ScopeWildcard poolZones

-- | A scope set drawn from the pool; every wildcard is anchored at a pool zone,
-- so 'mkScopeSet' always succeeds here.
genScopeSet :: Gen CertScopeSet
genScopeSet = do
  scopes <- sublistOf (map ScopeExact poolHosts ++ map ScopeWildcard poolZones)
  pure (either (error . renderScopeError) id (mkScopeSet poolZones scopes))

parent :: DelegatedZone
parent = zn "resolvefintech.com"

certScopeSuite :: SuiteBuilder ()
certScopeSuite =
  describe "Sprint 2.35 certificate-scope algebra" $ do
    describe "name smart constructors" $ do
      it "rejects an empty name" $ isLeft (mkFqdn "") `shouldBe` True
      it "rejects a wildcard in a plain name" $
        isLeft (mkFqdn "*.resolvefintech.com") `shouldBe` True
      it "rejects a single-label name" $ isLeft (mkFqdn "localhost") `shouldBe` True
      it "rejects a label with a leading hyphen" $
        isLeft (mkFqdn "-bad.resolvefintech.com") `shouldBe` True
      it "lowercases and accepts a valid name" $
        (fqdnText <$> mkFqdn "VSCode.Resolvefintech.COM")
          `shouldBe` Right "vscode.resolvefintech.com"

    describe "wildcard coverage boundary" $ do
      it "covers a single-label child" $
        covers (ScopeWildcard parent) (fq "vscode.resolvefintech.com") `shouldBe` True
      it "does NOT cover the apex" $
        covers (ScopeWildcard parent) (fq "resolvefintech.com") `shouldBe` False
      it "does NOT cover a two-label-deep name" $
        covers (ScopeWildcard parent) (fq "a.b.resolvefintech.com") `shouldBe` False
      it "an exact scope covers only itself" $ do
        covers (ScopeExact (fq "test.resolvefintech.com")) (fq "test.resolvefintech.com")
          `shouldBe` True
        covers (ScopeExact (fq "test.resolvefintech.com")) (fq "x.test.resolvefintech.com")
          `shouldBe` False

    describe "impliedBy structural cases" $ do
      it "an exact host is implied by a covering wildcard" $
        scopeImpliedBy (ScopeExact (fq "vscode.resolvefintech.com")) (ScopeWildcard parent)
          `shouldBe` True
      it "*.a.z is NOT implied by *.z" $
        scopeImpliedBy
          (ScopeWildcard (zn "aws.resolvefintech.com"))
          (ScopeWildcard parent)
          `shouldBe` False
      it "a wildcard is never implied by an exact scope" $
        scopeImpliedBy (ScopeWildcard parent) (ScopeExact (fq "vscode.resolvefintech.com"))
          `shouldBe` False

    describe "mkScopeSet / bindListener illegal states" $ do
      it "rejects a wildcard anchored at an undelegated zone" $
        mkScopeSet [parent] [ScopeWildcard (zn "notdelegated.example")]
          `shouldBe` Left (WildcardZoneNotDelegated "notdelegated.example")
      it "accepts a wildcard anchored at a delegated zone" $
        isRight (mkScopeSet [parent] [ScopeWildcard parent]) `shouldBe` True
      it "canonicalizes: dedup and order are input-independent" $
        mkScopeSet
          poolZones
          [ScopeWildcard parent, ScopeExact (fq "test.resolvefintech.com"), ScopeWildcard parent]
          `shouldBe` mkScopeSet
            poolZones
            [ScopeExact (fq "test.resolvefintech.com"), ScopeWildcard parent]
      it "bindListener rejects an uncovered host" $ do
        let scopeSet = either (error . renderScopeError) id (mkScopeSet [parent] [ScopeWildcard parent])
        bindListener scopeSet (fq "unrelated.example.org")
          `shouldBe` Left (HostNotCovered "unrelated.example.org")
      it "bindListener admits a covered host" $ do
        let scopeSet = either (error . renderScopeError) id (mkScopeSet [parent] [ScopeWildcard parent])
        bindListener scopeSet (fq "vscode.resolvefintech.com") `shouldBe` Right ()

    describe "dnsNames / retention-key projection" $ do
      it "projects independent exacts and wildcards to a canonical dnsNames list" $ do
        let scopeSet =
              either (error . renderScopeError) id $
                mkScopeSet
                  poolZones
                  [ScopeWildcard (zn "aws.resolvefintech.com"), ScopeExact (fq "test.resolvefintech.com")]
        certScopeSetDnsNames scopeSet
          `shouldBe` ["test.resolvefintech.com", "*.aws.resolvefintech.com"]
        renderCertScopeSet scopeSet `shouldBe` "test.resolvefintech.com,*.aws.resolvefintech.com"
      it "reduces a redundant exact subsumed by a wildcard (minimal SANs)" $ do
        -- vscode.resolvefintech.com is a single-label child of resolvefintech.com,
        -- so *.resolvefintech.com subsumes it; only the wildcard survives.
        let scopeSet =
              either (error . renderScopeError) id $
                mkScopeSet poolZones [ScopeWildcard parent, ScopeExact (fq "vscode.resolvefintech.com")]
        certScopeSetDnsNames scopeSet `shouldBe` ["*.resolvefintech.com"]

    describe "partial-order laws (property)" $ do
      propertyTest "impliedBy is reflexive" $
        forAll genScopeSet $
          \s -> impliedBy s s
      propertyTest "impliedBy is transitive" $
        forAll genScopeSet $ \a ->
          forAll genScopeSet $ \b ->
            forAll genScopeSet $ \c ->
              not (impliedBy a b && impliedBy b c) || impliedBy a c
      propertyTest "impliedBy is antisymmetric on canonical sets" $
        forAll genScopeSet $ \a ->
          forAll genScopeSet $ \b ->
            not (impliedBy a b && impliedBy b a) || a == b
      propertyTest "coverage is preserved by widening (restore-vs-reissue soundness)" $
        forAll genScopeSet $ \narrower ->
          forAll genScopeSet $ \wider ->
            forAll (elements poolHosts) $ \host ->
              not (impliedBy narrower wider && scopeSetCovers narrower host)
                || scopeSetCovers wider host
      propertyTest "a single scope always implies itself" $
        forAll genScope $
          \scope -> scopeImpliedBy scope scope
