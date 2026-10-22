{-# LANGUAGE OverloadedStrings #-}

module CredentialSuccessor (credentialSuccessorSuite) where

import Control.Monad (forM_, unless)
import Data.ByteString qualified as ByteString
import Data.Text qualified as Text
import Prodbox.ControlPlane.CredentialSuccessorRegression
import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch
import TestSupport

credentialSuccessorSuite :: SuiteBuilder ()
credentialSuccessorSuite = describe "Sprint 6.5 credential successor foundation" $ do
  modelCases "mutation reservation" fixedProviderCredentialMutationReservationRegression
  modelCases "immutable lineage" fixedProviderCredentialLineageRegression
  modelCases "ordinary retirement" fixedOrdinaryProviderCredentialRetirementRegression
  modelCases "revoke fence" fixedProviderCredentialMutationFenceRegression
  modelCases "cleanup child" fixedProviderCredentialCleanupRegression
  it "requires private publication and independent Agent observers before aggregate completion" $ do
    installed <- readArchiveFixture "install"
    rotated <- readArchiveFixture "rotate"
    revoked <- readArchiveFixture "revoke"
    foreignArchive <- readArchiveFixture "foreign"
    cases <-
      either
        (ioError . userError . Text.unpack)
        pure
        ( fixedCredentialSuccessorRegression
            (CredentialSuccessorRegressionFixtures installed rotated revoked foreignArchive)
        )
    cases `shouldSatisfy` (not . null)
    forM_ cases assertCase
 where
  modelCases name result = describe name $ case result of
    Left detail -> it "constructs the fixed model fixture" (ioError (userError (Text.unpack detail)))
    Right cases -> forM_ cases modelCase
  modelCase (name, passed) = it (Text.unpack name) (passed `shouldBe` True)
  assertCase (name, passed) = unless passed (expectationFailure (Text.unpack name))

readArchiveFixture :: String -> IO ProviderCredentialLineageArchive
readArchiveFixture name = do
  bytes <- ByteString.readFile ("test/fixtures/credential-successor/" <> name <> "-archive.cbor")
  either (ioError . userError . Text.unpack) pure (decodeProviderCredentialLineageArchive bytes)
