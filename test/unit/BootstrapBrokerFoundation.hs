{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 2.33 foundation conformance: the closed runtime-role split, the
-- Bootstrap Broker's finite route/config surfaces, and its secret-safe bounded
-- request admission lane.
module BootstrapBrokerFoundation
  ( bootstrapBrokerFoundationSuite
  )
where

import Control.Monad (forM_)
import Crypto.Hash.SHA1 qualified as SHA1
import Data.Aeson (eitherDecode, encode, object, toJSON, (.=))
import Data.Bits (shiftR, (.&.))
import Data.ByteString (ByteString)
import Data.ByteString qualified as StrictByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Char8 qualified as ByteString
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.Either (isLeft, isRight)
import Data.List (nub)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Word (Word8)
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.Bootstrap.Broker (renderBootstrapBrokerStartPlan)
import Prodbox.Bootstrap.Broker.Admission qualified as Admission
import Prodbox.Bootstrap.Broker.PgpBoundary qualified as Pgp
import Prodbox.Bootstrap.Broker.Program qualified as Program
import Prodbox.Bootstrap.Broker.Request qualified as Request
import Prodbox.Bootstrap.Broker.Routes qualified as Routes
import Prodbox.Bootstrap.Broker.Settings
import Prodbox.Bootstrap.Broker.Types qualified as BrokerTypes
import Prodbox.Bootstrap.Broker.VaultWire
  ( EncryptedVaultInitResponse
  , encryptedVaultInitBurnToken
  , encryptedVaultInitShares
  )
import Prodbox.CheckCode
  ( bootstrapBrokerIsolationViolations
  , secretPayloadInternalSourceViolations
  )
import Prodbox.ControlPlane.CapabilityKind (CapabilityOp (..))
import Prodbox.ControlPlane.Deadline qualified as Deadline
import Prodbox.Http.Client (HttpError)
import Prodbox.Runtime.Role qualified as Role
import Prodbox.Vault.Client
  ( GenerateRootResponse
  , TokenAccessorListing (..)
  , VaultAddress
  , defaultInitRequest
  , initRequestWithPgpRecipientsLegacy
  , vaultInitEncrypted
  )
import TestSupport

bootstrapBrokerFoundationSuite :: SuiteBuilder ()
bootstrapBrokerFoundationSuite = do
  runtimeRoleSuite
  brokerRouteSuite
  brokerSettingsSuite
  brokerRequestSuite
  brokerAdmissionSuite
  brokerIsolationLintSuite
  brokerProtocolBoundarySuite

targetVaultInitAcceptsPreparedRecipients
  :: VaultAddress
  -> Pgp.PreparedInitRecipients
  -> IO (Either HttpError EncryptedVaultInitResponse)
targetVaultInitAcceptsPreparedRecipients = vaultInitEncrypted

brokerProtocolBoundarySuite :: SuiteBuilder ()
brokerProtocolBoundarySuite =
  describe "Sprint 2.33 typed Vault/PGP protocol boundary" $ do
    it "keeps the Standard-P raw recipient builder explicitly legacy" $ do
      let recipients = ["share-a", "share-b", "share-c", "share-d", "share-e"]
      case initRequestWithPgpRecipientsLegacy recipients "burn-public" defaultInitRequest of
        Left err -> expectationFailure err
        Right request ->
          toJSON request
            `shouldBe` object
              [ "secret_shares" .= (5 :: Natural)
              , "secret_threshold" .= (3 :: Natural)
              , "pgp_keys" .= recipients
              , "root_token_pgp_key" .= ("burn-public" :: Text)
              ]
    it "refuses a PGP share-recipient count mismatch or empty burn recipient" $ do
      initRequestWithPgpRecipientsLegacy ["only-one"] "burn" defaultInitRequest
        `shouldSatisfy` isLeft
      initRequestWithPgpRecipientsLegacy (replicate 5 "share") " " defaultInitRequest
        `shouldSatisfy` isLeft
    it "types the target Vault-init path by prepared recipient evidence" $
      targetVaultInitAcceptsPreparedRecipients `seq`
        pure ()
    it "keeps the legacy default wire shape free of PGP fields" $ do
      let encoded = LazyByteString.unpack (encode defaultInitRequest)
      encoded `shouldNotContain` "pgp_keys"
      encoded `shouldNotContain` "root_token_pgp_key"
    it "decodes generated-root progress but redacts its encrypted result and ignores OTP" $ do
      let decoded =
            eitherDecode
              "{\"started\":true,\"nonce\":\"n\",\"progress\":3,\"required\":3,\"complete\":true,\"encoded_token\":\"cipher-secret\",\"otp\":\"forbidden-otp\",\"pgp_fingerprint\":\"fp\"}"
              :: Either String GenerateRootResponse
      case decoded of
        Left err -> expectationFailure err
        Right response -> do
          show response `shouldNotContain` "cipher-secret"
          show response `shouldNotContain` "forbidden-otp"
    it "decodes only non-secret token accessors" $ do
      eitherDecode "{\"data\":{\"keys\":[\"a\",\"b\"]}}"
        `shouldBe` Right (TokenAccessorListing ["a", "b"])
    it "decodes init outputs only as canonical opaque PGP ciphertext" $ do
      let decoded =
            eitherDecode
              "{\"keys_base64\":[\"Y2lwaGVyLXNoYXJl\"],\"root_token\":\"YnVybi10b2tlbi1jaXBoZXI=\"}"
              :: Either String EncryptedVaultInitResponse
      case decoded of
        Left err -> expectationFailure err
        Right response -> do
          fmap BrokerTypes.pgpEncryptedShareBytes (encryptedVaultInitShares response)
            `shouldBe` [12]
          BrokerTypes.burnTokenCiphertextBytes (encryptedVaultInitBurnToken response)
            `shouldBe` 17
          show response `shouldNotContain` "cipher-share"
          show response `shouldNotContain` "burn-token-cipher"
      ( eitherDecode
          "{\"keys_base64\":[\"not canonical\"],\"root_token\":\"c2VjcmV0\"}"
          :: Either String EncryptedVaultInitResponse
        )
        `shouldSatisfy` isLeft
      ( eitherDecode
          "{\"keys_base64\":[\"YQ==\"],\"recovery_keys_base64\":[\"Yg==\"],\"root_token\":\"Yw==\"}"
          :: Either String EncryptedVaultInitResponse
        )
        `shouldSatisfy` isLeft
      forM_
        [ "{\"keys_base64\":[\"YQ==\"],\"root_token\":\"Yw==\",\"keys\":[\"plaintext-share\"]}"
        , "{\"keys_base64\":[\"YQ==\"],\"root_token\":\"Yw==\",\"recovery_keys\":[\"plaintext-share\"]}"
        , "{\"keys_base64\":[\"YQ==\"],\"root_token\":\"Yw==\",\"unexpected\":true}"
        ]
        $ \payload ->
          (eitherDecode payload :: Either String EncryptedVaultInitResponse)
            `shouldSatisfy` isLeft
    it "bounds opaque PGP boundary values and redacts ciphertext" $ do
      Pgp.mkRecoveryRecipientPublicKey "cHVibGljLWtleQ=="
        `shouldSatisfy` isRight
      Pgp.mkRecoveryRecipientPublicKey "" `shouldSatisfy` isLeft
      Pgp.mkRecoveryRecipientPublicKey "not canonical"
        `shouldSatisfy` isLeft
      let ciphertext = Pgp.mkGeneratedRootCiphertext (ByteString.pack "cipher-secret")
      show ciphertext `shouldNotContain` "cipher-secret"
    it "binds prepared init to the exact compiled burn public-key value and pins" $ do
      let exactPublicValue = burnRecipientPublicKeyBase64 compiledBurnRecipient
          exactPublicKey = mustRight (Pgp.mkBurnRecipientPublicKey exactPublicValue)
          observedFingerprint =
            mustRight
              ( BrokerTypes.mkBurnRecipientFingerprint
                  ( Text.toLower
                      (unBurnRecipientFingerprint (burnRecipientFingerprint compiledBurnRecipient))
                  )
              )
          verified =
            mustRight
              ( Pgp.mkVerifiedBurnRecipient
                  compiledBurnRecipient
                  exactPublicKey
                  observedFingerprint
              )
          expectedDigest =
            Text.drop
              (Text.length "sha256:")
              ( unBurnRecipientPublicKeyDigest
                  (burnRecipientPublicKeyDigest compiledBurnRecipient)
              )
      Pgp.burnRecipientPublicKeyBase64
        (Pgp.verifiedBurnRecipientPublicKey verified)
        `shouldBe` exactPublicValue
      BrokerTypes.renderArtifactDigest
        (Pgp.verifiedBurnRecipientPublicKeyDigest verified)
        `shouldBe` expectedDigest
      Pgp.mkVerifiedBurnRecipient
        compiledBurnRecipient
        (mustRight (Pgp.mkBurnRecipientPublicKey "cHVibGljLWtleQ=="))
        observedFingerprint
        `shouldBe` Left Pgp.PgpCompiledBurnPublicKeyMismatch
    it "pins a certified OpenPGP v4 burn entity with one encryption subkey" $ do
      let publicBytes =
            mustRight
              ( Base64.decode
                  ( TextEncoding.encodeUtf8
                      (burnRecipientPublicKeyBase64 compiledBurnRecipient)
                  )
              )
          packets = mustRight (parseOpenPgpPackets publicBytes)
      StrictByteString.length publicBytes `shouldBe` 1772
      fmap fst packets `shouldBe` [6, 13, 2, 14, 2]
      Text.toLower
        (unBurnRecipientFingerprint (burnRecipientFingerprint compiledBurnRecipient))
        `shouldBe` burnRecipientExpectedPrimaryFingerprint
      case packets of
        [ (6, primaryKey)
          , (13, userIdentity)
          , (2, userIdentityCertification)
          , (14, encryptionSubkey)
          , (2, subkeyBinding)
          ] -> do
            userIdentity
              `shouldBe` TextEncoding.encodeUtf8 burnRecipientExpectedUserIdentity
            StrictByteString.take 4 userIdentityCertification
              `shouldBe` StrictByteString.pack [4, 0x13, 1, 10]
            userIdentityCertification
              `shouldSatisfy` StrictByteString.isInfixOf
                (StrictByteString.pack [2, 27, 1])
            StrictByteString.take 4 subkeyBinding
              `shouldBe` StrictByteString.pack [4, 0x18, 1, 10]
            subkeyBinding
              `shouldSatisfy` StrictByteString.isInfixOf
                (StrictByteString.pack [2, 27, 0x0c])
            openPgpV4Fingerprint primaryKey
              `shouldBe` Right burnRecipientExpectedPrimaryFingerprint
            openPgpV4Fingerprint encryptionSubkey
              `shouldBe` Right burnRecipientExpectedEncryptionSubkeyFingerprint
        _ -> expectationFailure "unexpected burn-recipient packet topology"
      BrokerTypes.mkBurnRecipientFingerprint
        burnRecipientExpectedPrimaryFingerprint
        `shouldSatisfy` isRight
      BrokerTypes.mkBurnRecipientFingerprint (Text.replicate 64 "b")
        `shouldSatisfy` isLeft
      BrokerTypes.mkBurnRecipientFingerprint
        (Text.toUpper burnRecipientExpectedPrimaryFingerprint)
        `shouldSatisfy` isLeft
    it "ends generated-root token authority at revoke-self before auditor absence proof" $ do
      Pgp.allGeneratedRootActionKinds
        `shouldBe` [ Pgp.GeneratedRootObserveSelfAction
                   , Pgp.GeneratedRootApplyBaselineAction
                   , Pgp.GeneratedRootReadBackBaselineAction
                   , Pgp.GeneratedRootRevokeSelfAction
                   ]
      Pgp.allGeneratedChildRecoveryActionKinds
        `shouldBe` [ Pgp.GeneratedChildRecoveryObserveSelfAction
                   , Pgp.GeneratedChildRecoveryApplyRepairAction
                   , Pgp.GeneratedChildRecoveryReadBackRepairAction
                   , Pgp.GeneratedChildRecoveryRevokeSelfAction
                   ]
      source <- readFile "src/Prodbox/Bootstrap/Broker/PgpBoundary.hs"
      source `shouldNotContain` "GeneratedRootInventoryAccessors"
      source `shouldNotContain` "GeneratedRootProveAccessorAbsent"
      source `shouldNotContain` "GeneratedChildRecoveryInventoryAccessors"
      source `shouldNotContain` "GeneratedChildRecoveryProveAccessorAbsent"
      source `shouldNotContain` "generatedRootSessionTokenBytes"
      source `shouldNotContain` "GeneratedRootSessionToken (..)"
      source `shouldNotContain` "GeneratedChildRecoverySessionToken (..)"
    it "indexes programs by exactly the four broker capabilities" $ do
      Program.brokerProgramCapabilityOp Program.ObserveBootstrapStatus
        `shouldBe` OpVaultBootstrapObserve
      Program.brokerProgramCapabilityOp Program.SealVault
        `shouldBe` OpVaultBootstrapMutate
      Program.brokerProgramCapabilityOp Program.ObserveVaultPkiStatus
        `shouldBe` OpVaultPkiOperate
    it "bounds the compiled PKI test issuance surface" $ do
      let maximumName =
            Text.intercalate
              "."
              [ Text.replicate 63 "a"
              , Text.replicate 63 "b"
              , Text.replicate 63 "c"
              , Text.replicate 61 "d"
              ]
          malformedNames =
            [ ""
            , "single-label"
            , "*.resolvefintech.com"
            , "127.0.0.1"
            , "bad..resolvefintech.com"
            , "-bad.resolvefintech.com"
            , "bad-.resolvefintech.com"
            , "bad\n.resolvefintech.com"
            , Text.replicate 64 "a" <> ".resolvefintech.com"
            , maximumName <> "e"
            ]
      ( Program.pkiIssueCommonName
          <$> Program.mkPkiIssueRequest "  TEST.ResolveFintech.COM  " 300
        )
        `shouldBe` Right "test.resolvefintech.com"
      Program.mkPkiIssueRequest maximumName 3600 `shouldSatisfy` isRight
      forM_ malformedNames $ \name ->
        Program.mkPkiIssueRequest name 300 `shouldSatisfy` isLeft
      Program.mkPkiIssueRequest "test.resolvefintech.com" 0 `shouldSatisfy` isLeft
      Program.mkPkiIssueRequest "test.resolvefintech.com" 3601 `shouldSatisfy` isLeft

brokerIsolationLintSuite :: SuiteBuilder ()
brokerIsolationLintSuite =
  describe "Sprint 2.33 broker/gateway isolation lint" $ do
    it "accepts isolated target registries plus the registered rollback adapter" $
      bootstrapBrokerIsolationViolations isolatedSources `shouldBe` []
    it "rejects a bootstrap route reintroduced into the Gateway registry" $
      bootstrapBrokerIsolationViolations
        (replaceSource gatewayRoutesPath "RouteBootstrapVaultEnsure = \"/v1/bootstrap/vault/ensure\"")
        `shouldSatisfy` (not . null)
    it "rejects a generic object-store escape in the Broker registry" $
      bootstrapBrokerIsolationViolations
        (replaceSource brokerRoutesPath "escape = \"/v1/object-store/get\"")
        `shouldSatisfy` (not . null)
    it "rejects secret-bearing target-client metadata before the rollback boundary" $
      bootstrapBrokerIsolationViolations
        ( replaceSource
            brokerClientPath
            ( "x-prodbox-service-identity x-prodbox-transport-credential idempotency-key "
                ++ "x-prodbox-request-sha256 requestDigestForBytes unlock_password "
                ++ "-- Standard-P rollback adapter"
            )
        )
        `shouldSatisfy` (not . null)
    it "rejects a marker-only daemon bridge without topology-gated dispatch" $
      bootstrapBrokerIsolationViolations
        ( replaceSource
            gatewayDaemonPath
            "LEGACY-ESCAPE[gateway-hosted-authority-routes] legacyGatewayBootstrapRouteForPath"
        )
        `shouldSatisfy` (not . null)
    it "rejects a pre-Vault credential literal in any Gateway module" $
      bootstrapBrokerIsolationViolations
        (("src/Prodbox/Gateway/Unexpected.hs", "field = \"unlock_password\"") : isolatedSources)
        `shouldSatisfy` (not . null)
    it "rejects SecretPayload internals or its byte eliminator in any controller module" $
      secretPayloadInternalSourceViolations
        ( "src/Prodbox/Bootstrap/Broker/Controller.hs"
        , "import Prodbox.Bootstrap.Broker.Request.Internal; leak = withSecretPayloadBytes"
        )
        `shouldSatisfy` (not . null)
 where
  gatewayRoutesPath = "src/Prodbox/Gateway/Routes.hs"
  gatewayDaemonPath = "src/Prodbox/Gateway/Daemon.hs"
  brokerClientPath = "src/Prodbox/Bootstrap/Broker/Client.hs"
  brokerRoutesPath = "src/Prodbox/Bootstrap/Broker/Routes.hs"
  isolatedSources =
    [ (gatewayRoutesPath, "data GatewayRoute = RouteHealthz")
    , ("src/Prodbox/Gateway/Client.hs", "statusUrl = \"/v1/state\"")
    ,
      ( gatewayDaemonPath
      , "handleParsedRequest rawRequest LegacyModelBEmitter legacyGatewayBootstrapRouteForPath runLegacyGatewayBootstrapRequest JournalLeaseEmitter dispatchPatternRoute"
      )
    ,
      ( brokerClientPath
      , "x-prodbox-service-identity x-prodbox-transport-credential idempotency-key x-prodbox-request-sha256 requestDigestForBytes -- Standard-P rollback adapter"
      )
    , (brokerRoutesPath, "status = \"/v1/bootstrap/vault/status\"")
    ,
      ( "src/Prodbox/Bootstrap/Broker/LegacyAdapter.hs"
      , "data LegacyGatewayBootstrapRoute = LegacyGatewayVaultEnsure; runLegacyGatewayBootstrapRequest = bootstrapObjectStoreConfigWithEndpoint unlockBundleInitialRootToken; old = \"unlock_password\"; new = \"new_unlock_password\""
      )
    ]
  replaceSource path replacement =
    [ if candidatePath == path then (candidatePath, replacement) else source
    | source@(candidatePath, _) <- isolatedSources
    ]

runtimeRoleSuite :: SuiteBuilder ()
runtimeRoleSuite =
  describe "Sprint 2.33 closed runtime-role identities" $ do
    it "enumerates exactly the Bootstrap Broker and Gateway runtime roles" $
      Role.allRuntimeRoles `shouldBe` [Role.BootstrapBroker, Role.GatewayRuntime]

    it "maps roles and config identities through a total bijection" $
      do
        let identities = [minBound .. maxBound]
        identities `shouldBe` [Role.BootstrapBrokerConfig, Role.GatewayRuntimeConfig]
        forM_ Role.allRuntimeRoles $ \role ->
          Role.runtimeConfigIdentityRole (Role.runtimeRoleConfigIdentity role)
            `shouldBe` role
        forM_ identities $ \identity ->
          Role.runtimeRoleConfigIdentity (Role.runtimeConfigIdentityRole identity)
            `shouldBe` identity

    it "pins one canonical name and mounted config path per role" $ do
      let cases =
            [
              ( Role.BootstrapBroker
              , Role.BootstrapBrokerConfig
              , "bootstrap-broker"
              , "bootstrap-broker-config-v1"
              , "/etc/bootstrap-broker/config"
              , "/etc/bootstrap-broker/config/config.dhall"
              )
            ,
              ( Role.GatewayRuntime
              , Role.GatewayRuntimeConfig
              , "gateway-runtime"
              , "gateway-runtime-config-v1"
              , "/etc/gateway/config"
              , "/etc/gateway/config/config.dhall"
              )
            ]
      forM_ cases $ \(role, identity, roleName, identityName, mountDirectory, mountPath) -> do
        Role.runtimeRoleConfigIdentity role `shouldBe` identity
        Role.runtimeRoleName role `shouldBe` roleName
        Role.runtimeConfigIdentityName identity `shouldBe` identityName
        Role.runtimeConfigMountDirectory identity `shouldBe` mountDirectory
        Role.runtimeConfigFileName identity `shouldBe` "config.dhall"
        Role.runtimeConfigMountPath identity `shouldBe` mountPath

brokerRouteSuite :: SuiteBuilder ()
brokerRouteSuite =
  describe "Sprint 2.33 closed Bootstrap Broker route registry" $ do
    it "enumerates all fifteen routes exactly once" $ do
      length Routes.allBrokerRoutes `shouldBe` 15
      Routes.allBrokerRoutes
        `shouldBe` [minBound .. maxBound]
      length (nub Routes.allBrokerRoutes)
        `shouldBe` length Routes.allBrokerRoutes

    it "assigns a unique fixed path and method/path inverse to every route" $ do
      let paths = map Routes.brokerRoutePath Routes.allBrokerRoutes
      length (nub paths) `shouldBe` length paths
      forM_ Routes.allBrokerRoutes $ \route -> do
        let method = Routes.brokerRouteMethod route
            path = Routes.brokerRoutePath route
        Routes.brokerRouteForPath path `shouldBe` Just route
        Routes.brokerRouteForRequest method path `shouldBe` Just route
        Routes.brokerRouteForRequest (otherBrokerMethod method) path `shouldBe` Nothing

    it "rejects partial, variable, and unregistered route paths" $ do
      forM_
        [ ""
        , "/"
        , "/v1/bootstrap/vault"
        , "/v1/bootstrap/vault/status/extra"
        , "/v1/bootstrap/vault/{path}"
        , "/v1/bootstrap/vault/:path"
        , "/v1/not-registered"
        ]
        $ \path -> Routes.brokerRouteForPath path `shouldBe` Nothing

    it "projects every route to exactly the four broker capability operations" $ do
      Set.fromList (map Routes.brokerRouteOperationClass Routes.allBrokerRoutes)
        `shouldBe` Set.fromList [minBound .. maxBound]
      Set.fromList (map Routes.brokerRouteCapabilityOp Routes.allBrokerRoutes)
        `shouldBe` Set.fromList
          [ OpVaultBootstrapObserve
          , OpVaultBootstrapMutate
          , OpVaultBaselineReconcile
          , OpVaultPkiOperate
          ]

    it "keeps generic and non-bootstrap authority nouns out of every path" $ do
      let forbiddenFragments =
            [ "/kv"
            , "/secret/"
            , "target-secret"
            , "minio"
            , "object"
            , "mesh"
            , "/dns"
            , "route53"
            , "pulumi"
            , "/ses"
            , "provider"
            , "authority"
            , "credential"
            , "coordinate"
            , "command"
            , "generic"
            , "url"
            ]
      forM_ Routes.allBrokerRoutes $ \route -> do
        let path = Routes.brokerRoutePath route
        forM_ forbiddenFragments $ \fragment ->
          Text.unpack (Text.toLower (Text.pack path))
            `shouldNotContain` Text.unpack (Text.toLower (Text.pack fragment))
        forM_ ("{}:*" :: String) $ \variableMarker ->
          (variableMarker `elem` path) `shouldBe` False

    it "pins body and mutation metadata for the complete registry" $
      forM_ Routes.allBrokerRoutes $ \route -> do
        let mutationClass = Routes.brokerRouteMutationClass route
        case mutationClass of
          Routes.BrokerReadOnly ->
            Routes.brokerRouteIsMutation route `shouldBe` False
          Routes.BrokerMutating -> do
            Routes.brokerRouteIsMutation route `shouldBe` True
            Routes.brokerRouteMethod route `shouldBe` Routes.BrokerPost
            Routes.brokerRouteBodyRequirement route `shouldBe` Routes.BrokerBodyRequired

brokerSettingsSuite :: SuiteBuilder ()
brokerSettingsSuite =
  describe "Sprint 2.33 Broker-only Dhall settings" $ do
    it "validates the complete schema and injects the compiled burn recipient" $ do
      let settings = mustRight (validateBootstrapBrokerConfig validBrokerConfig)
      brokerSchemaVersion settings `shouldBe` supportedBootstrapBrokerSchemaVersion
      brokerClusterId settings `shouldBe` "cluster-a"
      brokerVaultAddress settings `shouldBe` "http://127.0.0.1:8200"
      brokerServiceIdentity settings `shouldBe` "gateway-service"
      brokerListenAddress (brokerListener settings) `shouldBe` LoopbackIpv4
      brokerListenPort (brokerListener settings) `shouldBe` 8443
      brokerQueueCapacity (brokerLimits settings) `shouldBe` 8
      brokerBurnRecipient settings `shouldBe` compiledBurnRecipient
      Text.null
        (unBurnRecipientFingerprint (burnRecipientFingerprint compiledBurnRecipient))
        `shouldBe` False
      unBurnRecipientPublicKeyDigest
        (burnRecipientPublicKeyDigest compiledBurnRecipient)
        `shouldSatisfy` Text.isPrefixOf "sha256:"

    it "accepts only the two literal loopback listeners" $ do
      let ipv6Config =
            validBrokerConfig
              { listener = (listener validBrokerConfig) {listen_host = "::1"}
              }
      brokerListenAddress
        (brokerListener (mustRight (validateBootstrapBrokerConfig ipv6Config)))
        `shouldBe` LoopbackIpv6
      forM_ ["localhost", "0.0.0.0", "::", " 127.0.0.1 "] $ \host ->
        validateBootstrapBrokerConfig
          validBrokerConfig {listener = (listener validBrokerConfig) {listen_host = host}}
          `shouldBe` Left (BrokerListenerNotLoopback host)

    it "rejects every empty authored text field" $ do
      let cases =
            [ (ClusterIdField, \config -> config {cluster_id = "  "})
            , (VaultAddressField, \config -> config {vault_address = ""})
            , (ServiceIdentityField, \config -> config {service_identity = ""})
            , (StoreEndpointField, mapStore (\store -> store {store_endpoint = ""}))
            , (StoreBucketField, mapStore (\store -> store {store_bucket = ""}))
            ,
              ( VaultStorageGenerationKeyField
              , mapStore (\store -> store {vault_storage_generation_key = ""})
              )
            ,
              ( BootstrapSessionFenceKeyField
              , mapStore (\store -> store {bootstrap_session_fence_key = ""})
              )
            ,
              ( PreparedInitEnvelopeKeyField
              , mapStore (\store -> store {prepared_init_envelope_key = ""})
              )
            ,
              ( EncryptedInitResponseKeyField
              , mapStore (\store -> store {encrypted_init_response_key = ""})
              )
            ,
              ( FinalUnlockBundleKeyField
              , mapStore (\store -> store {final_unlock_bundle_key = ""})
              )
            ,
              ( ChildCustodyReceiptKeyField
              , mapStore (\store -> store {child_custody_receipt_key = ""})
              )
            ,
              ( ChildRecoveryDeliveryKeyField
              , mapStore (\store -> store {child_recovery_delivery_key = ""})
              )
            ,
              ( RootInitJournalKeyField
              , mapStore (\store -> store {root_init_journal_key = ""})
              )
            ,
              ( RootSessionJournalKeyField
              , mapStore (\store -> store {root_session_journal_key = ""})
              )
            ,
              ( ChildCustodyJournalKeyField
              , mapStore (\store -> store {child_custody_journal_key = ""})
              )
            ,
              ( ChildRecoveryJournalKeyField
              , mapStore (\store -> store {child_recovery_journal_key = ""})
              )
            ,
              ( PostUnsealHandoffKeyField
              , mapStore (\store -> store {post_unseal_handoff_key = ""})
              )
            ,
              ( SecretWorkerCheckpointKeyField
              , mapStore (\store -> store {secret_worker_checkpoint_key = ""})
              )
            ]
      forM_ cases $ \(field, invalidate) ->
        validateBootstrapBrokerConfig (invalidate validBrokerConfig)
          `shouldBe` Left (BrokerConfigFieldEmpty field)

    it "rejects schema, port, bound, and storage-key violations" $ do
      validateBootstrapBrokerConfig validBrokerConfig {schemaVersion = 2}
        `shouldBe` Left (BrokerSchemaVersionMismatch 1 2)
      forM_ [0, 65536] $ \port ->
        validateBootstrapBrokerConfig
          validBrokerConfig {listener = (listener validBrokerConfig) {listen_port = port}}
          `shouldBe` Left (BrokerListenerPortOutOfRange port)
      forM_ invalidLimitCases $ \(limitName, maximumValue, observed, invalidate) ->
        validateBootstrapBrokerConfig (invalidate validBrokerConfig)
          `shouldBe` Left (BrokerLimitOutOfRange limitName maximumValue observed)
      let duplicateStore =
            (bootstrap_store validBrokerConfig)
              { child_recovery_delivery_key = child_custody_receipt_key (bootstrap_store validBrokerConfig)
              }
      validateBootstrapBrokerConfig validBrokerConfig {bootstrap_store = duplicateStore}
        `shouldBe` Left BrokerStorageKeysNotDistinct

    it "decodes the literal mounted Dhall schema end to end" $ do
      result <- decodeBootstrapBrokerConfigDhall validBrokerConfigDhall
      case result of
        Left err -> expectationFailure (renderBootstrapBrokerSettingsError err)
        Right settings -> do
          brokerClusterId settings `shouldBe` "cluster-a"
          brokerListenAddress (brokerListener settings) `shouldBe` LoopbackIpv4

    it "renders a deterministic secret-free role plan" $ do
      let rendered =
            renderBootstrapBrokerStartPlan
              "/etc/bootstrap-broker/config/config.dhall"
              (mustRight (validateBootstrapBrokerConfig validBrokerConfig))
      rendered `shouldContain` "BOOTSTRAP_BROKER_START_PLAN"
      rendered `shouldContain` "RUNTIME_ROLE=bootstrap-broker"
      rendered `shouldContain` "LISTENER=127.0.0.1:8443"
      rendered `shouldContain` "BOUNDARY_ADAPTERS=fail-closed"
      forM_ ["password", "root_token", "private_key", "recovery_share"] $ \secretField ->
        Text.unpack (Text.toLower (Text.pack rendered)) `shouldNotContain` secretField

    it "rejects missing and credential-bearing Dhall shapes" $ do
      missing <-
        decodeBootstrapBrokerConfigDhall
          (Text.replace ", service_identity = \"gateway-service\"" "" validBrokerConfigDhall)
      credentialBearing <-
        decodeBootstrapBrokerConfigDhall
          ( Text.replace
              ", listener ="
              ", root_token = \"must-not-be-configurable\"\n, listener ="
              validBrokerConfigDhall
          )
      missing `shouldSatisfy` isLeft
      credentialBearing `shouldSatisfy` isLeft

brokerRequestSuite :: SuiteBuilder ()
brokerRequestSuite =
  describe "Sprint 2.33 secret-safe Broker requests" $ do
    it "accepts only exact literal loopback addresses" $ do
      Request.mkLoopbackAddress "127.0.0.1"
        `shouldSatisfy` either (const False) ((== "127.0.0.1") . Request.renderLoopbackAddress)
      Request.mkLoopbackAddress "::1"
        `shouldSatisfy` either (const False) ((== "::1") . Request.renderLoopbackAddress)
      forM_ ["localhost", "0.0.0.0", " 127.0.0.1 ", "::ffff:127.0.0.1"] $ \address ->
        Request.mkLoopbackAddress address `shouldSatisfy` isLeft

    it "bounds and canonicalizes service identities and idempotency keys" $ do
      Request.renderBrokerServiceIdentity
        (mustRight (Request.mkBrokerServiceIdentity " gateway/service-1 "))
        `shouldBe` "gateway/service-1"
      Request.renderIdempotencyKey
        (mustRight (Request.mkIdempotencyKey "request:one"))
        `shouldBe` "request:one"
      Request.renderBrokerServiceIdentity
        (mustRight (Request.mkBrokerServiceIdentity (Text.replicate 128 "i")))
        `shouldBe` Text.replicate 128 "i"
      Request.renderIdempotencyKey
        (mustRight (Request.mkIdempotencyKey (Text.replicate 128 "k")))
        `shouldBe` Text.replicate 128 "k"
      forM_
        [ Request.mkBrokerServiceIdentity ""
        , Request.mkBrokerServiceIdentity (Text.replicate 129 "a")
        , Request.mkBrokerServiceIdentity "identity with spaces"
        ]
        $ \result -> result `shouldSatisfy` isLeft
      forM_
        [ Request.mkIdempotencyKey ""
        , Request.mkIdempotencyKey (Text.replicate 129 "k")
        , Request.mkIdempotencyKey "key?query"
        ]
        $ \result -> result `shouldSatisfy` isLeft

    it "accepts only canonical lowercase SHA-256 request digests" $ do
      Request.renderRequestDigest testRequestDigest `shouldBe` Text.replicate 64 "a"
      forM_
        [ Text.replicate 63 "a"
        , Text.replicate 65 "a"
        , Text.replicate 64 "A"
        , Text.replicate 63 "a" <> "g"
        , " " <> Text.replicate 64 "a"
        ]
        $ \digest -> Request.mkRequestDigest digest `shouldSatisfy` isLeft

    it "bounds and redacts opaque secret bytes without a byte projection" $ do
      Request.mkSecretPayload 16 ByteString.empty `shouldSatisfy` isLeft
      Request.mkSecretPayload 3 "four" `shouldSatisfy` isLeft
      let secret = mustRight (Request.mkSecretPayload 4 "burn")
      Request.secretPayloadLength secret `shouldBe` 4
      show secret `shouldContain` "<redacted:4 bytes>"
      show secret `shouldNotContain` "burn"

    it "mints one absolute deadline from receipt time and the original budget" $ do
      let request = requestFor Request.EnsureVaultInitialized Request.HttpPost 4 Nothing
      Deadline.monotonicInstantMicros
        (Deadline.deadlineInstant (Request.requestAbsoluteDeadline request))
        `shouldBe` 11000
      Request.requestCarriesSecret request `shouldBe` False
      Request.requestCarriesSecret
        (requestFor Request.BrokerHealth Request.HttpGet 0 Nothing)
        `shouldBe` False

brokerAdmissionSuite :: SuiteBuilder ()
brokerAdmissionSuite =
  describe "Sprint 2.33 bounded Broker admission" $ do
    it "rejects every zero admission bound"
      $ forM_
        [ Admission.mkAdmissionLimits 0 2 100 50 25
        , Admission.mkAdmissionLimits 64 0 100 50 25
        , Admission.mkAdmissionLimits 64 2 0 50 25
        , Admission.mkAdmissionLimits 64 2 100 0 25
        , Admission.mkAdmissionLimits 64 2 100 50 0
        ]
      $ \result -> result `shouldSatisfy` isLeft

    it "admits the canonical method/body/secret shape for every operation" $
      do
        map (\(operation, _, _) -> operation) operationContracts
          `shouldBe` [minBound .. maxBound]
        forM_ operationContracts $ \(operation, method, contract) -> do
          let request = canonicalRequest operation method contract
              (lane, result) = admitToEmpty request
          result `shouldSatisfy` isNewAdmission
          Admission.queuedAdmissions lane `shouldBe` 1
          Admission.activeAdmissions lane `shouldBe` 0

    it "rejects the wrong method for every operation" $
      forM_ operationContracts $ \(operation, method, contract) ->
        assertRefusal
          Admission.RefuseMethod
          (canonicalRequest operation (otherHttpMethod method) contract)

    it "enforces every body and secret contract" $
      forM_ operationContracts $ \(operation, method, contract) -> do
        let bodyContract = contract
        case bodyContract of
          ExpectNoBody -> do
            assertRefusal
              Admission.RefuseBodyForbidden
              (requestFor operation method 1 Nothing)
            assertRefusal
              Admission.RefuseBodyForbidden
              (requestFor operation method 4 (Just testSecret))
          ExpectBody -> do
            assertRefusal
              Admission.RefuseBodyRequired
              (requestFor operation method 0 Nothing)
            assertRefusal
              Admission.RefuseSecretForbidden
              (requestFor operation method 4 (Just testSecret))
    it "rejects caller, body-bound, and secret content-length mismatches" $ do
      let wrongIdentityRequest =
            (canonicalRequest Request.BrokerHealth Request.HttpGet ExpectNoBody)
              { Request.brokerRequestMetadata =
                  (Request.brokerRequestMetadata testHealthRequest)
                    { Request.requestCallerIdentity = alternateServiceIdentity
                    }
              }
      assertRefusal Admission.RefuseWrongServiceIdentity wrongIdentityRequest
      assertRefusal
        (Admission.RefuseBodyTooLarge 65 64)
        (requestFor Request.ReconcileVaultBaseline Request.HttpPost 65 Nothing)
      assertRefusal
        (Admission.RefuseContentLengthMismatch 3 4)
        (requestFor Request.EnsureVaultInitialized Request.HttpPost 3 (Just testSecret))

    it "resumes exact queued/running requests and returns completed responses" $ do
      let request = canonicalRequest Request.ReconcileVaultBaseline Request.HttpPost ExpectBody
          (queuedLane, ticket) = mustNewAdmission (admitToEmpty request)
          (sameQueuedLane, queuedReplay) =
            Admission.admitRequest testNow testServiceIdentity testLimits queuedLane request
      sameQueuedLane `shouldBe` queuedLane
      queuedReplay `shouldBe` Admission.AdmissionAccepted (Admission.AdmissionResumeQueued ticket)
      runningLane <- mustRightIO (Admission.startAdmission ticket queuedLane)
      Admission.queuedAdmissions runningLane `shouldBe` 0
      Admission.activeAdmissions runningLane `shouldBe` 1
      let (sameRunningLane, runningReplay) =
            Admission.admitRequest testNow testServiceIdentity testLimits runningLane request
      sameRunningLane `shouldBe` runningLane
      runningReplay `shouldBe` Admission.AdmissionAccepted (Admission.AdmissionResumeRunning ticket)
      completedLane <- mustRightIO (Admission.completeAdmission ticket responseDigest runningLane)
      Admission.activeAdmissions completedLane `shouldBe` 0
      let (sameCompletedLane, completedReplay) =
            Admission.admitRequest testNow testServiceIdentity testLimits completedLane request
      sameCompletedLane `shouldBe` completedLane
      completedReplay
        `shouldBe` Admission.AdmissionAccepted (Admission.AdmissionReturnCached responseDigest)

    it "refuses idempotency-key rebinding by digest or operation" $ do
      let request = canonicalRequest Request.ReconcileVaultBaseline Request.HttpPost ExpectBody
          (queuedLane, _) = mustNewAdmission (admitToEmpty request)
          changedDigest =
            request
              { Request.brokerRequestMetadata =
                  (Request.brokerRequestMetadata request)
                    { Request.requestDigest = responseDigest
                    }
              }
          changedOperation = request {Request.brokerRequestOperation = Request.CommitChildInitCustody}
      snd (Admission.admitRequest testNow testServiceIdentity testLimits queuedLane changedDigest)
        `shouldBe` Admission.AdmissionRefused Admission.RefuseIdempotencyConflict
      snd (Admission.admitRequest testNow testServiceIdentity testLimits queuedLane changedOperation)
        `shouldBe` Admission.AdmissionRefused Admission.RefuseIdempotencyConflict

    it "cancels only running tickets and permits the exact request to retry" $ do
      let request = canonicalRequest Request.EnsureVaultUnsealed Request.HttpPost ExpectBody
          (queuedLane, ticket) = mustNewAdmission (admitToEmpty request)
      Admission.cancelAdmission ticket queuedLane `shouldSatisfy` isLeft
      runningLane <- mustRightIO (Admission.startAdmission ticket queuedLane)
      cancelledLane <- mustRightIO (Admission.cancelAdmission ticket runningLane)
      Admission.activeAdmissions cancelledLane `shouldBe` 0
      let (retriedLane, retryResult) =
            Admission.admitRequest testNow testServiceIdentity testLimits cancelledLane request
      retryResult `shouldSatisfy` isNewAdmission
      Admission.queuedAdmissions retriedLane `shouldBe` 1

    it "bounds occupancy and emits a deterministic saturation retry hint" $ do
      let oneSlotLimits = mustRight (Admission.mkAdmissionLimits 64 1 100 50 25)
          first = canonicalRequest Request.BrokerHealth Request.HttpGet ExpectNoBody
          second =
            withRequestKey
              "second-request"
              (canonicalRequest Request.BrokerReadiness Request.HttpGet ExpectNoBody)
          (fullLane, _) =
            Admission.admitRequest testNow testServiceIdentity oneSlotLimits Admission.emptyAdmissionLane first
          (sameLane, result) =
            Admission.admitRequest testNow testServiceIdentity oneSlotLimits fullLane second
      sameLane `shouldBe` fullLane
      result
        `shouldBe` Admission.AdmissionRefused
          (Admission.RefuseSaturated (Deadline.RetryAfter 200))

    it "uses one strict absolute deadline for queue, service, read-back, and serialization" $ do
      let exactBudget = withRequestBudget 175 testHealthRequest
          oneMicroSlack = withRequestBudget 176 testHealthRequest
          expired = withRequestBudget 10 testHealthRequest
      snd
        ( Admission.admitRequest
            testNow
            testServiceIdentity
            testLimits
            Admission.emptyAdmissionLane
            exactBudget
        )
        `shouldBe` Admission.AdmissionRefused
          (Admission.RefuseDeadlineInfeasible (Deadline.RemainingDuration 0))
      snd
        ( Admission.admitRequest
            testNow
            testServiceIdentity
            testLimits
            Admission.emptyAdmissionLane
            oneMicroSlack
        )
        `shouldSatisfy` isNewAdmission
      snd
        ( Admission.admitRequest
            (Deadline.monotonicInstantFromMicros 11000)
            testServiceIdentity
            testLimits
            Admission.emptyAdmissionLane
            expired
        )
        `shouldBe` Admission.AdmissionRefused Admission.RefuseDeadlineExpired

    it "drains absorptively for fresh work while exact replays remain observable" $ do
      let request = canonicalRequest Request.BrokerHealth Request.HttpGet ExpectNoBody
          (queuedLane, ticket) = mustNewAdmission (admitToEmpty request)
          drainingEmpty = Admission.beginDraining Admission.emptyAdmissionLane
          drainingQueued = Admission.beginDraining queuedLane
          fresh = withRequestKey "fresh-after-drain" request
      snd (Admission.admitRequest testNow testServiceIdentity testLimits drainingEmpty fresh)
        `shouldBe` Admission.AdmissionRefused Admission.RefuseDraining
      snd (Admission.admitRequest testNow testServiceIdentity testLimits drainingQueued request)
        `shouldBe` Admission.AdmissionAccepted (Admission.AdmissionResumeQueued ticket)
      Admission.beginDraining drainingQueued `shouldBe` drainingQueued

    it "rejects forged or out-of-order lifecycle tickets without changing counts" $ do
      let request = canonicalRequest Request.BrokerHealth Request.HttpGet ExpectNoBody
          (queuedLane, ticket) = mustNewAdmission (admitToEmpty request)
          forged = ticket {Admission.ticketRequestDigest = responseDigest}
      Admission.startAdmission forged queuedLane `shouldSatisfy` isLeft
      Admission.completeAdmission ticket responseDigest queuedLane `shouldSatisfy` isLeft
      runningLane <- mustRightIO (Admission.startAdmission ticket queuedLane)
      Admission.startAdmission ticket runningLane `shouldSatisfy` isLeft
      completedLane <- mustRightIO (Admission.completeAdmission ticket responseDigest runningLane)
      Admission.completeAdmission ticket responseDigest completedLane `shouldSatisfy` isLeft
      Admission.queuedAdmissions completedLane `shouldBe` 0
      Admission.activeAdmissions completedLane `shouldBe` 0

data ExpectedBodyContract
  = ExpectNoBody
  | ExpectBody
  deriving (Eq, Show)

operationContracts :: [(Request.BrokerOperationTag, Request.HttpMethod, ExpectedBodyContract)]
operationContracts =
  [ (Request.BrokerHealth, Request.HttpGet, ExpectNoBody)
  , (Request.BrokerReadiness, Request.HttpGet, ExpectNoBody)
  , (Request.ObserveBootstrapStatus, Request.HttpGet, ExpectNoBody)
  , (Request.EnsureVaultInitialized, Request.HttpPost, ExpectBody)
  , (Request.EnsureVaultUnsealed, Request.HttpPost, ExpectBody)
  , (Request.SealVault, Request.HttpPost, ExpectBody)
  , (Request.RotateUnlockBundle, Request.HttpPost, ExpectBody)
  , (Request.RotateTransitKey, Request.HttpPost, ExpectBody)
  , (Request.RecoverAmbiguousInitialization, Request.HttpPost, ExpectBody)
  , (Request.ReconcileVaultBaseline, Request.HttpPost, ExpectBody)
  , (Request.ObserveVaultPki, Request.HttpGet, ExpectNoBody)
  , (Request.IssueVaultPkiTestCertificate, Request.HttpPost, ExpectBody)
  , (Request.CommitChildInitCustody, Request.HttpPost, ExpectBody)
  , (Request.DeliverChildRecovery, Request.HttpPost, ExpectBody)
  , (Request.ObserveChildRecoveryDelivery, Request.HttpPost, ExpectBody)
  ]

canonicalRequest
  :: Request.BrokerOperationTag
  -> Request.HttpMethod
  -> ExpectedBodyContract
  -> Request.BrokerRequest
canonicalRequest operation method contract =
  case contract of
    ExpectNoBody -> requestFor operation method 0 Nothing
    ExpectBody -> requestFor operation method 4 Nothing

requestFor
  :: Request.BrokerOperationTag
  -> Request.HttpMethod
  -> Natural
  -> Maybe Request.SecretPayload
  -> Request.BrokerRequest
requestFor operation method contentLength secret =
  Request.BrokerRequest
    { Request.brokerRequestOperation = operation
    , Request.brokerRequestMethod = method
    , Request.brokerRequestMetadata =
        Request.RequestMetadata
          { Request.requestIdempotencyKey = testIdempotencyKey
          , Request.requestDigest = testRequestDigest
          , Request.requestCallerIdentity = testServiceIdentity
          , Request.requestCallerAddress = testLoopbackAddress
          , Request.requestContentLength = contentLength
          , Request.requestReceivedAt = Deadline.monotonicInstantFromMicros 1000
          , Request.requestBudget = Deadline.RemainingDuration 10000
          }
    , Request.brokerRequestSecret = secret
    }

withRequestKey :: Text -> Request.BrokerRequest -> Request.BrokerRequest
withRequestKey key request =
  request
    { Request.brokerRequestMetadata =
        (Request.brokerRequestMetadata request)
          { Request.requestIdempotencyKey = mustRight (Request.mkIdempotencyKey key)
          }
    }

withRequestBudget :: Natural -> Request.BrokerRequest -> Request.BrokerRequest
withRequestBudget budget request =
  request
    { Request.brokerRequestMetadata =
        (Request.brokerRequestMetadata request)
          { Request.requestBudget = Deadline.RemainingDuration budget
          }
    }

testHealthRequest :: Request.BrokerRequest
testHealthRequest = requestFor Request.BrokerHealth Request.HttpGet 0 Nothing

testServiceIdentity :: Request.BrokerServiceIdentity
testServiceIdentity = mustRight (Request.mkBrokerServiceIdentity "gateway-service")

alternateServiceIdentity :: Request.BrokerServiceIdentity
alternateServiceIdentity = mustRight (Request.mkBrokerServiceIdentity "wrong-service")

testIdempotencyKey :: Request.IdempotencyKey
testIdempotencyKey = mustRight (Request.mkIdempotencyKey "request-one")

testRequestDigest :: Request.RequestDigest
testRequestDigest = mustRight (Request.mkRequestDigest (Text.replicate 64 "a"))

responseDigest :: Request.RequestDigest
responseDigest = mustRight (Request.mkRequestDigest (Text.replicate 64 "b"))

testLoopbackAddress :: Request.LoopbackAddress
testLoopbackAddress = mustRight (Request.mkLoopbackAddress "127.0.0.1")

testSecret :: Request.SecretPayload
testSecret = mustRight (Request.mkSecretPayload 64 "burn")

testNow :: Deadline.MonotonicInstant
testNow = Deadline.monotonicInstantFromMicros 1000

testLimits :: Admission.AdmissionLimits
testLimits = mustRight (Admission.mkAdmissionLimits 64 2 100 50 25)

admitToEmpty :: Request.BrokerRequest -> (Admission.AdmissionLane, Admission.AdmissionResult)
admitToEmpty =
  Admission.admitRequest
    testNow
    testServiceIdentity
    testLimits
    Admission.emptyAdmissionLane

assertRefusal :: Admission.AdmissionRefusal -> Request.BrokerRequest -> Expectation
assertRefusal expected request = do
  let (lane, result) = admitToEmpty request
  lane `shouldBe` Admission.emptyAdmissionLane
  result `shouldBe` Admission.AdmissionRefused expected

isNewAdmission :: Admission.AdmissionResult -> Bool
isNewAdmission result =
  case result of
    Admission.AdmissionAccepted (Admission.AdmissionNew _) -> True
    _ -> False

mustNewAdmission
  :: (Admission.AdmissionLane, Admission.AdmissionResult)
  -> (Admission.AdmissionLane, Admission.AdmissionTicket)
mustNewAdmission (lane, result) =
  case result of
    Admission.AdmissionAccepted (Admission.AdmissionNew ticket) -> (lane, ticket)
    _ -> error ("expected a new admission, got " ++ show result)

otherHttpMethod :: Request.HttpMethod -> Request.HttpMethod
otherHttpMethod method =
  case method of
    Request.HttpGet -> Request.HttpPost
    Request.HttpPost -> Request.HttpGet

otherBrokerMethod :: Routes.BrokerHttpMethod -> Routes.BrokerHttpMethod
otherBrokerMethod method =
  case method of
    Routes.BrokerGet -> Routes.BrokerPost
    Routes.BrokerPost -> Routes.BrokerGet

validBrokerConfig :: BootstrapBrokerConfigDhall
validBrokerConfig =
  BootstrapBrokerConfigDhall
    { schemaVersion = 1
    , cluster_id = "cluster-a"
    , vault_address = "http://127.0.0.1:8200"
    , service_identity = "gateway-service"
    , listener =
        BrokerListenerDhall
          { listen_host = "127.0.0.1"
          , listen_port = 8443
          }
    , bootstrap_store =
        BootstrapStoreDhall
          { store_endpoint = "http://127.0.0.1:9000"
          , store_bucket = "bootstrap-state"
          , vault_storage_generation_key = "vault-storage-generation"
          , bootstrap_session_fence_key = "bootstrap-session-fence"
          , prepared_init_envelope_key = "prepared-init-envelope"
          , encrypted_init_response_key = "encrypted-init-response"
          , final_unlock_bundle_key = "final-unlock-bundle"
          , child_custody_receipt_key = "child-custody-receipt"
          , child_recovery_delivery_key = "child-recovery-delivery"
          , root_init_journal_key = "root-init-journal"
          , root_session_journal_key = "root-session-journal"
          , child_custody_journal_key = "child-custody-journal"
          , child_recovery_journal_key = "child-recovery-journal"
          , post_unseal_handoff_key = "post-unseal-handoff"
          , secret_worker_checkpoint_key = "secret-worker-checkpoint"
          }
    , limits =
        BrokerLimitsDhall
          { queue_capacity = 8
          , max_request_body_bytes = 4096
          , request_deadline_milliseconds = 30000
          , drain_deadline_milliseconds = 5000
          }
    }

mapStore
  :: (BootstrapStoreDhall -> BootstrapStoreDhall)
  -> BootstrapBrokerConfigDhall
  -> BootstrapBrokerConfigDhall
mapStore update config =
  config {bootstrap_store = update (bootstrap_store config)}

invalidLimitCases
  :: [ ( BrokerLimitName
       , Natural
       , Natural
       , BootstrapBrokerConfigDhall -> BootstrapBrokerConfigDhall
       )
     ]
invalidLimitCases =
  [
    ( QueueCapacityLimit
    , maximumBrokerQueueCapacity
    , 0
    , mapLimits (\value -> value {queue_capacity = 0})
    )
  ,
    ( QueueCapacityLimit
    , maximumBrokerQueueCapacity
    , maximumBrokerQueueCapacity + 1
    , mapLimits (\value -> value {queue_capacity = maximumBrokerQueueCapacity + 1})
    )
  ,
    ( RequestBodyBytesLimit
    , maximumBrokerRequestBodyBytes
    , 0
    , mapLimits (\value -> value {max_request_body_bytes = 0})
    )
  ,
    ( RequestBodyBytesLimit
    , maximumBrokerRequestBodyBytes
    , maximumBrokerRequestBodyBytes + 1
    , mapLimits
        (\value -> value {max_request_body_bytes = maximumBrokerRequestBodyBytes + 1})
    )
  ,
    ( RequestDeadlineMillisecondsLimit
    , maximumBrokerRequestDeadlineMilliseconds
    , 0
    , mapLimits (\value -> value {request_deadline_milliseconds = 0})
    )
  ,
    ( RequestDeadlineMillisecondsLimit
    , maximumBrokerRequestDeadlineMilliseconds
    , maximumBrokerRequestDeadlineMilliseconds + 1
    , mapLimits
        ( \value ->
            value
              { request_deadline_milliseconds =
                  maximumBrokerRequestDeadlineMilliseconds + 1
              }
        )
    )
  ,
    ( DrainDeadlineMillisecondsLimit
    , maximumBrokerDrainDeadlineMilliseconds
    , 0
    , mapLimits (\value -> value {drain_deadline_milliseconds = 0})
    )
  ,
    ( DrainDeadlineMillisecondsLimit
    , maximumBrokerDrainDeadlineMilliseconds
    , maximumBrokerDrainDeadlineMilliseconds + 1
    , mapLimits
        ( \value ->
            value
              { drain_deadline_milliseconds =
                  maximumBrokerDrainDeadlineMilliseconds + 1
              }
        )
    )
  ]

mapLimits
  :: (BrokerLimitsDhall -> BrokerLimitsDhall)
  -> BootstrapBrokerConfigDhall
  -> BootstrapBrokerConfigDhall
mapLimits update config = config {limits = update (limits config)}

validBrokerConfigDhall :: Text
validBrokerConfigDhall =
  Text.unlines
    [ "{ schemaVersion = 1"
    , ", cluster_id = \"cluster-a\""
    , ", vault_address = \"http://127.0.0.1:8200\""
    , ", service_identity = \"gateway-service\""
    , ", listener = { listen_host = \"127.0.0.1\", listen_port = 8443 }"
    , ", bootstrap_store ="
    , "    { store_endpoint = \"http://127.0.0.1:9000\""
    , "    , store_bucket = \"bootstrap-state\""
    , "    , vault_storage_generation_key = \"vault-storage-generation\""
    , "    , bootstrap_session_fence_key = \"bootstrap-session-fence\""
    , "    , prepared_init_envelope_key = \"prepared-init-envelope\""
    , "    , encrypted_init_response_key = \"encrypted-init-response\""
    , "    , final_unlock_bundle_key = \"final-unlock-bundle\""
    , "    , child_custody_receipt_key = \"child-custody-receipt\""
    , "    , child_recovery_delivery_key = \"child-recovery-delivery\""
    , "    , root_init_journal_key = \"root-init-journal\""
    , "    , root_session_journal_key = \"root-session-journal\""
    , "    , child_custody_journal_key = \"child-custody-journal\""
    , "    , child_recovery_journal_key = \"child-recovery-journal\""
    , "    , post_unseal_handoff_key = \"post-unseal-handoff\""
    , "    , secret_worker_checkpoint_key = \"secret-worker-checkpoint\""
    , "    }"
    , ", limits ="
    , "    { queue_capacity = 8"
    , "    , max_request_body_bytes = 4096"
    , "    , request_deadline_milliseconds = 30000"
    , "    , drain_deadline_milliseconds = 5000"
    , "    }"
    , "}"
    ]

mustRight :: (Show errorValue) => Either errorValue value -> value
mustRight result =
  case result of
    Left err -> error ("expected Right, got Left " ++ show err)
    Right value -> value

mustRightIO :: (Show errorValue) => Either errorValue value -> IO value
mustRightIO result =
  case result of
    Left err -> expectationFailure ("expected Right, got Left " ++ show err) >> error "unreachable"
    Right value -> pure value

burnRecipientExpectedUserIdentity :: Text
burnRecipientExpectedUserIdentity =
  "Prodbox Burn Recipient v1 <burn-recipient-v1@prodbox.invalid>"

burnRecipientExpectedPrimaryFingerprint :: Text
burnRecipientExpectedPrimaryFingerprint =
  "f0debca077828f2a82813f420020e4e04a4dd831"

burnRecipientExpectedEncryptionSubkeyFingerprint :: Text
burnRecipientExpectedEncryptionSubkeyFingerprint =
  "00792271f13cc02116c1914993ceed49504f7a21"

parseOpenPgpPackets :: ByteString -> Either String [(Word8, ByteString)]
parseOpenPgpPackets bytes =
  case StrictByteString.uncons bytes of
    Nothing -> Right []
    Just (header, remainder)
      | header .&. 0x80 == 0 -> Left "OpenPGP packet is missing its CTB bit"
      | header .&. 0x40 /= 0 ->
          Left "compiled burn recipient unexpectedly uses a new-format packet header"
      | otherwise -> do
          let tag = (header `shiftR` 2) .&. 0x0f
          (bodyLength, afterLength) <-
            parseOpenPgpOldLength (header .&. 0x03) remainder
          let (body, remainingPackets) =
                StrictByteString.splitAt bodyLength afterLength
          if StrictByteString.length body /= bodyLength
            then Left "truncated OpenPGP packet body"
            else ((tag, body) :) <$> parseOpenPgpPackets remainingPackets

parseOpenPgpOldLength :: Word8 -> ByteString -> Either String (Int, ByteString)
parseOpenPgpOldLength lengthKind bytes =
  case lengthKind of
    0 -> case StrictByteString.uncons bytes of
      Nothing -> Left "truncated one-octet OpenPGP packet length"
      Just (first, remainder) -> Right (fromIntegral first, remainder)
    1 -> case StrictByteString.unpack (StrictByteString.take 2 bytes) of
      [first, second] ->
        Right
          ( fromIntegral first * 256 + fromIntegral second
          , StrictByteString.drop 2 bytes
          )
      _ -> Left "truncated two-octet OpenPGP packet length"
    2 -> case StrictByteString.unpack (StrictByteString.take 4 bytes) of
      [first, second, third, fourth] ->
        Right
          ( fromIntegral first * 16777216
              + fromIntegral second * 65536
              + fromIntegral third * 256
              + fromIntegral fourth
          , StrictByteString.drop 4 bytes
          )
      _ -> Left "truncated four-octet OpenPGP packet length"
    _ -> Left "indeterminate old-format OpenPGP packet length is forbidden"

openPgpV4Fingerprint :: ByteString -> Either String Text
openPgpV4Fingerprint packetBody
  | StrictByteString.null packetBody = Left "empty OpenPGP public-key packet"
  | StrictByteString.head packetBody /= 4 = Left "OpenPGP public key is not version 4"
  | packetLength > 65535 = Left "OpenPGP public-key packet exceeds v4 framing"
  | otherwise =
      Right
        ( Text.pack
            ( concatMap
                byteHex
                ( StrictByteString.unpack
                    ( SHA1.hash
                        ( StrictByteString.pack
                            [ 0x99
                            , fromIntegral (packetLength `div` 256)
                            , fromIntegral (packetLength `mod` 256)
                            ]
                            <> packetBody
                        )
                    )
                )
            )
        )
 where
  packetLength = StrictByteString.length packetBody
  byteHex value = case showHex value "" of
    [digit] -> ['0', digit]
    digits -> digits
