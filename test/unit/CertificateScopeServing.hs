{-# LANGUAGE OverloadedStrings #-}

module CertificateScopeServing (certificateScopeServingSuite) where

import Data.Set qualified as Set
import Prodbox.Test.CertificateScopeServing
import TestSupport

certificateScopeServingSuite :: SuiteBuilder ()
certificateScopeServingSuite =
  describe "Sprint 5.22 exact presented-certificate SAN validation" $ do
    it "parses DNS SANs canonically while ignoring non-DNS SANs" $
      parsePresentedDnsSans
        "X509v3 Subject Alternative Name:\n    DNS:API.Example.COM, DNS:*.example.com., IP Address:192.0.2.1"
        `shouldBe` Right (Set.fromList ["api.example.com", "*.example.com"])

    it "accepts the exact configured scope independent of SAN order" $
      validatePresentedDnsSans
        ["*.example.com", "api.example.com"]
        "DNS:api.example.com, DNS:*.example.com"
        `shouldBe` Right ()

    it "rejects a merely covering certificate with a non-exact SAN set" $
      validatePresentedDnsSans
        ["api.example.com"]
        "DNS:api.example.com, DNS:*.example.com"
        `shouldBe` Left
          ( PresentedCertificateScopeMismatch
              (Set.fromList ["api.example.com"])
              (Set.fromList ["api.example.com", "*.example.com"])
          )

    it "rejects a certificate without DNS SAN evidence" $
      validatePresentedDnsSans ["api.example.com"] "IP Address:192.0.2.1"
        `shouldBe` Left PresentedCertificateHasNoDnsSans
