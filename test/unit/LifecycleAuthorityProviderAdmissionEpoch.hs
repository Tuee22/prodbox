{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module LifecycleAuthorityProviderAdmissionEpoch
  ( lifecycleAuthorityProviderAdmissionEpochSuite
  )
where

import Control.Monad (filterM)
import Data.ByteString qualified as ByteString
import Data.Either (isLeft)
import Data.List (isInfixOf, isPrefixOf, sort)
import Data.Word (Word8)
import Prodbox.ControlPlane.AuthorityAdmissionEndpoint
  ( authorityAdmissionStateCodec
  )
import Prodbox.ControlPlane.CallerPrincipal (CallerPrincipal (CallerService))
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionAggregate
  , AuthorityAdmissionCommand (ApplyAuthorityGenesis)
  , AuthorityProviderSettlementDecision (..)
  , AuthorityProviderSubmissionDecision (..)
  , authorityAggregateProviderAdmissionEpochView
  , initialCleanInstallAuthority
  , initialCleanInstallAuthorityWithRegisteredClients
  , stepAuthorityAdmission
  , stepRegisteredProviderSettlement
  , stepRegisteredProviderSubmission
  )
import Prodbox.Lifecycle.Authority.ClientRegistry
  ( ClientSubmissionKey
  , RegisteredClientGeneration
  , RegisteredClientTable
  , clientPrincipalForCaller
  , mkClientSubmissionKey
  , mkRegisteredClientGeneration
  , mkRegisteredClientSlot
  , mkRegisteredClientSpec
  , mkRegisteredClientTable
  )
import Prodbox.Lifecycle.Authority.Genesis
  ( AuthorityGenesisCommand (..)
  , BackupReceipt (BackupReceipt)
  , GenesisPlan (GenesisPlan)
  , TargetAgentGenerationReceipt (TargetAgentGenerationReceipt)
  )
import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch
import Prodbox.Lifecycle.Authority.Submission
  ( OperationId
  , RequestDigest (RequestDigest)
  )
import Prodbox.Lifecycle.CheckpointAuthority
  ( ModelBCodec (decodeModelBValue, encodeModelBValue)
  )
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderIntent (ObserveOperationalIdentity)
  )
import Prodbox.Runtime.Role (RuntimeRole (ProviderWorkerRuntime))
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (takeExtension, (</>))
import TestSupport

lifecycleAuthorityProviderAdmissionEpochSuite :: SuiteBuilder ()
lifecycleAuthorityProviderAdmissionEpochSuite =
  describe "Lifecycle Provider admission epoch" $ do
    it "decodes the exact canonical v6 bytes as LegacyServingUnbound" $ do
      ByteString.length legacyV6Fixture `shouldBe` 119
      ByteString.take 3 legacyV6Fixture `shouldBe` ByteString.pack [0x83, 0x00, 0x06]
      migrated <-
        expectRightIO
          (decodeModelBValue fixtureCodec legacyV6Fixture)
      migrated `shouldBe` expectRight (initialCleanInstallAuthority 1 1)
      authorityAggregateProviderAdmissionEpochView migrated
        `shouldBe` ProviderAdmissionLegacyServingUnbound

    it "writes canonical v7 and refuses older, newer, noncanonical, and bounded input" $ do
      initial <- expectRightIO (initialCleanInstallAuthority 1 1)
      encoded <- expectRightIO (encodeModelBValue fixtureCodec initial)
      encoded `shouldNotBe` legacyV6Fixture
      decodeModelBValue fixtureCodec encoded `shouldBe` Right initial
      encodeModelBValue fixtureCodec initial `shouldBe` Right encoded
      decodeModelBValue fixtureCodec (replaceByte 2 0x05 legacyV6Fixture)
        `shouldSatisfy` isUnsupportedVersion 5
      decodeModelBValue fixtureCodec (replaceByte 2 0x08 legacyV6Fixture)
        `shouldSatisfy` isUnsupportedVersion 8
      decodeModelBValue fixtureCodec (ByteString.snoc encoded 0)
        `shouldSatisfy` isLeft
      decodeModelBValue (authorityAdmissionStateCodec 1 1 1) legacyV6Fixture
        `shouldSatisfy` isLeft

    it "keeps legacy submissions compatible with exact duplicate and settlement replay" $ do
      closed <-
        expectRightIO
          (initialCleanInstallAuthorityWithRegisteredClients 4 4 registry)
      let initial = openAdmission closed
      authorityAggregateProviderAdmissionEpochView initial
        `shouldBe` ProviderAdmissionLegacyServingUnbound
      (accepted, pending) <-
        expectRightIO
          ( stepRegisteredProviderSubmission
              initial
              providerCaller
              providerGeneration
              providerSubmissionKey
              providerDigest
              ObserveOperationalIdentity
          )
      operation <- acceptedOperation accepted
      stepRegisteredProviderSubmission
        pending
        providerCaller
        providerGeneration
        providerSubmissionKey
        providerDigest
        ObserveOperationalIdentity
        `shouldBe` Right
          ( AuthorityProviderSubmissionDuplicatePending operation
          , pending
          )
      (settled, completed) <-
        expectRightIO
          ( stepRegisteredProviderSettlement
              providerCaller
              providerGeneration
              operation
              ObserveOperationalIdentity
              "canonical-terminal-evidence"
              pending
          )
      settled `shouldBe` AuthorityProviderSettlementCompleted
      stepRegisteredProviderSubmission
        completed
        providerCaller
        providerGeneration
        providerSubmissionKey
        providerDigest
        ObserveOperationalIdentity
        `shouldBe` Right
          ( AuthorityProviderSubmissionDuplicateCompleted
              operation
              "canonical-terminal-evidence"
          , completed
          )

    it "covers hidden serving, pending, Frozen, and Revoked shapes without returning them" $ do
      regression <- expectRightIO fixedProviderAdmissionEpochRegression
      providerAdmissionEpochRegressionLegacyPreserved regression `shouldBe` True
      providerAdmissionEpochRegressionServingPermitsFresh regression `shouldBe` True
      providerAdmissionEpochRegressionFrozenRefusesFresh regression `shouldBe` True
      providerAdmissionEpochRegressionRevokedRefusesFresh regression `shouldBe` True
      providerAdmissionEpochRegressionNoPendingClassified regression `shouldBe` True
      providerAdmissionEpochRegressionOwnedPendingClassified regression `shouldBe` True
      providerAdmissionEpochRegressionUnownedPendingClassified regression `shouldBe` True
      providerAdmissionEpochRegressionFrozenShapeValidated regression `shouldBe` True
      providerAdmissionEpochRegressionRevokedShapeValidated regression `shouldBe` True
      providerAdmissionEpochRegressionInvalidGenerationRefused regression `shouldBe` True
      providerAdmissionEpochRegressionNonCanonicalBindingRefused regression `shouldBe` True

    it "exports no generation, reservation, freeze transition, or receipt minter" $ do
      facade <-
        readFile
          "src/Prodbox/Lifecycle/Authority/ProviderAdmissionEpoch.hs"
      admission <-
        readFile "src/Prodbox/Lifecycle/Authority/Admission.hs"
      let header = moduleHeader facade
          forbidden =
            [ "ProviderAdmissionEpoch (.."
            , "ProviderCredentialGeneration"
            , "CascadeAuditFreezeBinding"
            , "ReservedCascadeAuditSubmission"
            , "ProviderCredentialRevocationReceipt"
            , "servingProviderAdmissionEpoch"
            , "mkCascadeAuditFreezeBinding"
            , "stepProviderAdmissionCascade"
            , "credentialRevokedProviderAdmissionEpoch"
            ]
      mapM_ (header `shouldNotContain`) forbidden
      admission `shouldNotContain` "stepProviderAdmissionCascade"
      admission `shouldNotContain` "ReservedCascadeAuditSubmission"
      admission `shouldContain` "RegisteredSubmissionFresh"
      admission `shouldContain` "providerAdmissionFreshSubmissionRefusalInternal"
      doesFileExist "src/Prodbox/ControlPlane/ProviderAdmissionFreeze.hs"
        `shouldReturn` False
      doesFileExist "src/Prodbox/ControlPlane/ProviderAdmissionFreeze/Internal.hs"
        `shouldReturn` False

    it "keeps the epoch implementation package-private with exact production ownership" $ do
      importers <-
        sourceImporters
          "src"
          "import Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch.Internal"
      importers
        `shouldBe` [ "src/Prodbox/Lifecycle/Authority/Admission.hs"
                   , "src/Prodbox/Lifecycle/Authority/ProviderAdmissionEpoch.hs"
                   ]
      cabal <- readFile "prodbox.cabal"
      let (libraryExposed, privateAndTests) =
            break (== "    other-modules:") (lines cabal)
          libraryPrivate =
            takeWhile (not . isPrefixOf "test-suite ") privateAndTests
          internalModule =
            "Prodbox.Lifecycle.Authority.ProviderAdmissionEpoch.Internal"
      unlines libraryExposed `shouldNotContain` internalModule
      unlines libraryPrivate `shouldContain` internalModule

fixtureCodec :: ModelBCodec AuthorityAdmissionAggregate
fixtureCodec = authorityAdmissionStateCodec 4096 1 1

legacyV6Fixture :: ByteString.ByteString
legacyV6Fixture =
  hexBytes
    "8300068b0081008100830001a001a0a0830001a08400a4676177732d656b73806f6177732d656b732d7375627a6f6e6580676177732d73657380686177732d7465737480a4676177732d656b73806f6177732d656b732d7375627a6f6e6580676177732d73657380686177732d7465737480a081008100"

providerCaller :: CallerPrincipal
providerCaller = CallerService ProviderWorkerRuntime

providerGeneration :: RegisteredClientGeneration
providerGeneration = expectRight (mkRegisteredClientGeneration 1)

providerSubmissionKey :: ClientSubmissionKey
providerSubmissionKey = expectRight (mkClientSubmissionKey "provider-epoch/replay")

providerDigest :: RequestDigest
providerDigest = RequestDigest "provider-epoch-replay-digest"

registry :: RegisteredClientTable
registry =
  expectRight (mkRegisteredClientTable 1 [spec])
 where
  slot = expectRight (mkRegisteredClientSlot 1)
  spec =
    expectRight
      ( mkRegisteredClientSpec
          (clientPrincipalForCaller providerCaller)
          slot
          providerGeneration
          4
      )

openAdmission :: AuthorityAdmissionAggregate -> AuthorityAdmissionAggregate
openAdmission initial =
  foldl
    (\aggregate command -> snd (stepAuthorityAdmission aggregate (ApplyAuthorityGenesis command)))
    initial
    [ BeginGenesisEstablishment
        (GenesisPlan "provider-epoch-genesis" "authority-backup/provider-epoch")
    , ObserveTargetAgentGeneration
        (TargetAgentGenerationReceipt "provider-epoch-target-generation")
    , ObserveBackupReceipt (BackupReceipt "provider-epoch-backup")
    ]

acceptedOperation
  :: AuthorityProviderSubmissionDecision
  -> IO OperationId
acceptedOperation decision = case decision of
  AuthorityProviderSubmissionAccepted operation -> pure operation
  other ->
    expectationFailure ("expected Provider admission, got " <> show other)
      >> fail "unreachable"

replaceByte
  :: Int -> Word8 -> ByteString.ByteString -> ByteString.ByteString
replaceByte index replacement bytes =
  ByteString.take index bytes
    <> ByteString.singleton replacement
    <> ByteString.drop (index + 1) bytes

isUnsupportedVersion :: Int -> Either String value -> Bool
isUnsupportedVersion version result = case result of
  Left err -> ("AuthorityAdmissionUnsupportedVersion " <> show version) `isInfixOf` err
  Right _ -> False

hexBytes :: String -> ByteString.ByteString
hexBytes input = ByteString.pack (go input)
 where
  go [] = []
  go (high : low : rest) = (16 * nibble high + nibble low) : go rest
  go _ = error "odd-length fixed hex fixture"

  nibble character
    | character >= '0' && character <= '9' = fromIntegral (fromEnum character - fromEnum '0')
    | character >= 'a' && character <= 'f' =
        fromIntegral (10 + fromEnum character - fromEnum 'a')
    | otherwise = error "non-hex fixed fixture"

moduleHeader :: String -> String
moduleHeader = unlines . takeWhile (/= "where") . lines

sourceImporters :: FilePath -> String -> IO [FilePath]
sourceImporters root importNeedle = do
  paths <- haskellFiles root
  sort <$> filterM (fileContains importNeedle) paths

haskellFiles :: FilePath -> IO [FilePath]
haskellFiles path = do
  isDirectory <- doesDirectoryExist path
  if isDirectory
    then do
      children <- listDirectory path
      concat <$> traverse (haskellFiles . (path </>)) children
    else pure [path | takeExtension path == ".hs"]

fileContains :: String -> FilePath -> IO Bool
fileContains needle path = do
  contents <- readFile path
  pure (needle `isInfixOf` contents)

expectRight :: (Show err) => Either err value -> value
expectRight result = case result of
  Left err -> error ("unexpected fixture failure: " <> show err)
  Right value -> value

expectRightIO :: (Show err) => Either err value -> IO value
expectRightIO result = case result of
  Left err ->
    expectationFailure ("unexpected fixture failure: " <> show err)
      >> fail "unreachable"
  Right value -> pure value
