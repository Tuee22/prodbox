{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module SettingsProjection (settingsProjectionSuite) where

import Control.Monad (forM_, void)
import Data.Text qualified as Text
import Prodbox.Capacity.Config qualified as Capacity
import Prodbox.Cluster.Topology (unconfiguredClusterTopology)
import Prodbox.Config.Tier0 qualified as Tier0
import Prodbox.Settings qualified as S
import System.Directory (makeAbsolute)
import System.FilePath ((</>))
import Test.Tasty.HUnit
import TestSupport
  ( FixtureAwsRegion (..)
  , SuiteBuilder
  , describe
  , fixtureAwsRegion
  , it
  , syntheticConfigFile
  , syntheticProjectConfig
  )

contextInput :: S.DeploymentContextInput
contextInput =
  let context = Tier0.context syntheticProjectConfig
   in S.DeploymentContextInput
        (Tier0.cluster_id context)
        (Tier0.vault_address context)
        (Tier0.minio_endpoint context)
        (Tier0.rpc_registration context)
validCases :: [(String, S.ConfigFile)]
validCases =
  [ ("home", syntheticConfigFile)
  ,
    ( "populated"
    , syntheticConfigFile
        { S.aws = (S.aws syntheticConfigFile) {S.awsCredentialRegion = fixtureAwsRegion FixtureUsEast1}
        , S.route53 = S.Route53Section "ZHOME123"
        , S.aws_substrate =
            (S.aws_substrate syntheticConfigFile)
              { S.hosted_zone_id = "ZSUBSTRATE456"
              , S.subzone_name = "aws.synthetic.test.invalid"
              }
        , S.ses = S.SesSection "mail.synthetic.test.invalid" "inbound" "synthetic-capture-bucket"
        , S.acme = (S.acme syntheticConfigFile) {S.email = "operator@example.test"}
        , S.deployment =
            (S.deployment syntheticConfigFile) {S.bootstrap_public_ip_override = Just "192.0.2.8"}
        , S.pulumi_state_backend =
            S.PulumiStateBackendSection
              "synthetic-state-bucket"
              (fixtureAwsRegion FixtureCaCentral1)
              "state/pulumi"
        }
    )
  ,
    ( "normalized"
    , syntheticConfigFile
        { S.aws =
            (S.aws syntheticConfigFile)
              { S.awsCredentialRegion = "  " <> fixtureAwsRegion FixtureUsEast1 <> "  "
              }
        , S.route53 = S.Route53Section "  ZHOME123  "
        , S.ses = S.SesSection "  mail.synthetic.test.invalid  " " inbound " " synthetic-capture-bucket "
        , S.acme = (S.acme syntheticConfigFile) {S.email = " operator@example.test "}
        }
    )
  ]
faults :: [(String, S.ConfigFile -> S.ConfigFile)]
faults =
  [ ("served-host", \cfg -> cfg {S.domain = (S.domain cfg) {S.demo_fqdn = ""}})
  , ("ttl", \cfg -> cfg {S.domain = (S.domain cfg) {S.demo_ttl = 0}})
  , ("aws-region", \cfg -> cfg {S.aws = (S.aws cfg) {S.awsCredentialRegion = "bad region!"}})
  ,
    ( "substrate-zone"
    , \cfg -> cfg {S.aws_substrate = (S.aws_substrate cfg) {S.hosted_zone_id = "bad zone!"}}
    )
  , ("ses", \cfg -> cfg {S.ses = S.SesSection "not a domain" "" ""})
  ,
    ( "bootstrap-ip"
    , \cfg -> cfg {S.deployment = (S.deployment cfg) {S.bootstrap_public_ip_override = Just "bad ip!"}}
    )
  ,
    ( "capacity"
    , \cfg -> cfg {S.capacity = (S.capacity cfg) {Capacity.region_quota = Capacity.CapacityBudget 0 0 0}}
    )
  , ("topology", \cfg -> cfg {S.cluster_topology = unconfiguredClusterTopology})
  , ("storage", \cfg -> cfg {S.storage = S.StorageSection "../outside"})
  ,
    ( "backend"
    , \cfg -> cfg {S.pulumi_state_backend = S.PulumiStateBackendSection "Bad_Bucket" "" "pulumi"}
    )
  ,
    ( "components"
    , \cfg -> cfg {S.components = case S.components cfg of item : _ -> [item, item]; [] -> []}
    )
  , ("home-zone", \cfg -> cfg {S.route53 = S.Route53Section "bad zone!"})
  , ("acme", \cfg -> cfg {S.acme = (S.acme cfg) {S.email = "bad email!"}})
  ]

expectedFaults :: [(String, String)]
expectedFaults =
  [ ("served-host", "domain.demo_fqdn must not be empty")
  , ("ttl", "domain.demo_ttl must be between 30 and 86400")
  ,
    ( "aws-region"
    , "aws.region must be a valid AWS region (two-letter geography, location, and non-zero ordinal)"
    )
  ,
    ( "substrate-zone"
    , "aws_substrate.hosted_zone_id must look like a Route 53 hosted-zone id (for example Z1234)"
    )
  , ("ses", "ses.sender_domain must be a valid fully qualified domain name")
  , ("bootstrap-ip", "deployment.bootstrap_public_ip_override must be a valid IP address when set")
  , ("capacity", "capacity.node_budget must fit within capacity.region_quota")
  , ("topology", "cluster_topology machine_id must be non-empty")
  , ("storage", "storage.manual_pv_host_root must not contain a `..` segment")
  , ("backend", "pulumi_state_backend.bucket_name must be a valid S3 bucket name")
  , ("components", "components: Duplicate component node: cluster_base")
  , ("home-zone", "route53.zone_id must look like a Route 53 hosted-zone id (for example Z1234)")
  , ("acme", "acme.email must be an email address (a local part, one @, and a domain)")
  ]

settingsProjectionSuite :: SuiteBuilder ()
settingsProjectionSuite = describe "retained settings projections" $ do
  it "refuses an earlier invalid field without demanding storage path conversion" $ do
    let config =
          syntheticConfigFile
            { S.domain = (S.domain syntheticConfigFile) {S.demo_fqdn = ""}
            , S.storage = error "storage demanded before the earlier local refusal"
            }
    outcome <- S.validateConfigWithContext "/synthetic/prodbox" contextInput config
    void outcome @?= Left "domain.demo_fqdn must not be empty"

  it "preserves successful storage path resolution after semantic validation" $ do
    forM_ ["/synthetic/prodbox", "synthetic/prodbox"] $ \root ->
      forM_ ["data/volumes", " data/volumes ", "data//./volumes", "résumé/δ"] $ \path -> do
        let config = syntheticConfigFile {S.storage = S.StorageSection path}
        expected <- makeAbsolute (root </> Text.unpack path)
        outcome <- S.validateConfigWithContext root contextInput config
        fmap S.resolvedManualPvHostRoot outcome @?= Right expected

  it "preserves normalized coordinate and public-edge projections" $
    forM_ validCases $ \(_, config) -> do
      outcome <- S.validateConfigWithContext "/synthetic/prodbox" contextInput config
      case outcome of
        Left message -> assertFailure message
        Right settings -> do
          Right (S.validatedCoordinates settings) @?= S.validatedCoordinatesFor config
          Right (S.validatedPublicEdge settings)
            @?= S.validatedPublicEdgeFor (S.domain config) (S.aws_substrate config)
          S.validatedConfig settings @?= config
          Right (S.validatedDeploymentContext settings)
            @?= S.validatedDeploymentContextFor contextInput (S.cluster_topology config)
  it "keeps the first refusal for every single and paired malformed field" $ do
    map fst faults @?= map fst expectedFaults
    forM_ (zip [0 :: Int ..] (zip faults expectedFaults)) $ \(index, ((_, change), (_, message))) -> do
      let variants =
            change syntheticConfigFile
              : [change (later syntheticConfigFile) | (_, later) <- drop (index + 1) faults]
      forM_ variants $ \config -> do
        S.validateLocalConfig config @?= Left message
        outcome <- S.validateConfigWithContext "/synthetic/prodbox" contextInput config
        void outcome @?= Left message

  it "keeps standalone topology refusal and full context validation order" $ do
    let malformedContext = contextInput {S.contextInputClusterId = ""}
    S.validatedDeploymentContextFor malformedContext unconfiguredClusterTopology
      @?= Left "cluster_topology machine_id must be non-empty"
    forM_
      [ contextInput {S.contextInputClusterId = ""}
      , contextInput {S.contextInputVaultAddress = "invalid"}
      , contextInput {S.contextInputMinioEndpoint = "invalid"}
      ]
      $ \input -> do
        let expected = S.validatedDeploymentContextFor input (S.cluster_topology syntheticConfigFile)
        outcome <- S.validateConfigWithContext "/synthetic/prodbox" input syntheticConfigFile
        fmap S.validatedDeploymentContext outcome @?= expected

  it "checks endpoint schemes while retaining complete normalized Unicode endpoints" $ do
    let endpoints =
          [ ("http://a", True)
          , ("https://a", True)
          , ("HtTp://a", True)
          , ("HTTPS://a", True)
          , ("  HTTPS://İ.example/Σ/ß  ", True)
          , ("http://İ", True)
          , ("https://a/İΣß", True)
          , ("", False)
          , ("https://", False)
          , ("http://", False)
          , ("http:///a", False)
          , ("https:///a", False)
          , ("http:/a", False)
          , ("ftp://a", False)
          , ("httpsx://a", False)
          , ("İhttp://a", False)
          , ("HİTP://a", False)
          , ("https://a b", False)
          ]
    forM_ endpoints $ \(endpoint, accepted) ->
      forM_ [True, False] $ \vault -> do
        let input
              | vault = contextInput {S.contextInputVaultAddress = endpoint}
              | otherwise = contextInput {S.contextInputMinioEndpoint = endpoint}
        case S.validatedDeploymentContextFor input (S.cluster_topology syntheticConfigFile) of
          Left _ -> assertBool ("unexpected endpoint refusal: " ++ Text.unpack endpoint) (not accepted)
          Right context -> do
            assertBool ("unexpected endpoint acceptance: " ++ Text.unpack endpoint) accepted
            (if vault then S.deploymentVaultAddress context else S.deploymentMinioEndpoint context)
              @?= Text.strip endpoint
