{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

-- | Production binding for the closed Provider Worker vocabulary.  The only
-- credential read is the Provider role's exact Vault KV object, scoped inside
-- the rank-2 session callback.  Pulumi execution selects from three compiled
-- non-SES programs rooted at @/opt/build/pulumi@ and accepts only their typed
-- configuration constructors.
module Prodbox.ControlPlane.ProviderProduction
  ( ProviderProductionSession
  , providerProductionNarrowSession
  , providerProductionCapabilities
  , providerProductionReady
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad qualified
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson
  ( Value (Array, Bool, Object, String)
  , eitherDecodeStrict'
  , encode
  , object
  , (.=)
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock (UTCTime)
import Data.Time.Clock.POSIX (getPOSIXTime, utcTimeToPOSIXSeconds)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Data.Vector qualified as Vector
import Numeric (showHex)
import Prodbox.Aws.CredentialHandle (baseCredentialHandleFromSettings)
import Prodbox.Aws.Native.Route53 qualified as NativeRoute53
import Prodbox.Aws.Native.Wire (httpSend)
import Prodbox.AwsEnvironment (awsCliSubprocessEnvironment)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientTransport
  )
import Prodbox.ControlPlane.EksClientAuthProjection
  ( encodeEksClientAuthEnvelope
  , mkEksClientAuthProjection
  , mkEksClientAuthPublicKey
  , sealEksClientAuthProjection
  )
import Prodbox.ControlPlane.ProviderNarrowSession
  ( ProviderEffectObservation (..)
  , ProviderIntentCapabilities (..)
  , ProviderMutation (..)
  , ProviderNarrowSessionRunner (..)
  , ProviderReadOnly (..)
  )
import Prodbox.Infra.AwsEksTestStack (pulumiAwsProviderEnv)
import Prodbox.Lifecycle.EbsVolume qualified as EbsVolume
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( EksClientAuthRequest
  , ProviderCheckpointRef
  , ProviderIntentCoordinate
  , ProviderReadinessProbe (..)
  , ProviderSpotPriceQuery
  , ProviderStackConfig (..)
  , ProviderStackRef
  , PublicARecordRef
  , SesBucketRef
  , SesDnsRef
  , SesIdentityRef
  , SesRuleSetRef
  , eksClientAuthRequestAccountId
  , eksClientAuthRequestClusterName
  , eksClientAuthRequestDestinationPublicKey
  , eksClientAuthRequestRegion
  , providerCheckpointRefText
  , providerSpotPriceInstanceType
  , providerSpotPriceProductDescription
  , providerStackRefText
  , publicARecordFqdn
  , publicARecordHostedZoneId
  , publicARecordTtl
  , publicARecordValues
  , sesBucketRefText
  , sesDnsHostedZoneId
  , sesDnsIdentityDomain
  , sesDnsReceiveSubdomain
  , sesIdentityRefText
  , sesRuleSetCaptureBucket
  , sesRuleSetRecipient
  , sesRuleSetRefText
  )
import Prodbox.Pulumi.EncryptedBackend
  ( EncryptedBackendError
  , PulumiStackRef (..)
  , renderEncryptedBackendError
  , withAuthenticatedDecryptedStackEnvironment
  , withAuthenticatedObservedDecryptedStackEnvironment
  )
import Prodbox.Result (Result (..))
import Prodbox.Runtime.Role (RuntimeRole (LifecycleAuthorityRuntime))
import Prodbox.Settings (Credentials (..))
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  )
import Prodbox.Vault.Client (vaultKvReadV2)
import Prodbox.Vault.Session
  ( VaultSession
  , sessionAddress
  , withSessionToken
  )
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Timeout (timeout)

data ProviderProductionSession = ProviderProductionSession
  { productionSessionCredentials :: !Credentials
  , productionSessionAuthorityTransport
      :: !(AuthenticatedClientTransport 'LifecycleAuthorityRuntime)
  }

providerProductionNarrowSession
  :: VaultSession
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> ProviderNarrowSessionRunner IO ProviderProductionSession
providerProductionNarrowSession vaultSession authorityTransport =
  ProviderNarrowSessionRunner
    { withProviderNarrowSession = \_intent _deadline action -> do
        credentials <- readProviderCredentials vaultSession
        case credentials of
          Left detail -> pure (Left detail)
          Right resolved ->
            action
              ProviderProductionSession
                { productionSessionCredentials = resolved
                , productionSessionAuthorityTransport = authorityTransport
                }
    }

providerProductionCapabilities
  :: ProviderIntentCapabilities IO ProviderProductionSession
providerProductionCapabilities =
  ProviderIntentCapabilities
    { reconcileRegisteredStackCapability = \ref _revision config ->
        pulumiMutation DesiredPresent ref config
    , destroyRegisteredStackCapability = \ref _revision config ->
        pulumiMutation DesiredAbsent ref config
    , observeRegisteredStackCapability = \ref ->
        ProviderReadOnly (\session _ -> observeStackRef session ref)
    , readBackRegisteredStackCapability = \ref ->
        ProviderReadOnly (\session _ -> observeStackRef session ref)
    , boundedScratchCheckpointCapability = scratchCheckpointMutation
    , reconcileSesSendingIdentityCapability = sesIdentityMutation
    , reconcileSesDkimCapability = sesDkimMutation
    , reconcileSesReceiptRulesCapability = sesReceiptRulesMutation
    , reconcileSesCaptureBucketCapability = sesCaptureBucketMutation
    , reconcileSesDnsCapability = sesDnsMutation
    , observePublicARecordCapability = publicARecordObservation
    , reconcilePublicARecordCapability = publicARecordMutation
    , reapTestEbsVolumesCapability = ebsReaperMutation
    , observeSpotPriceCapability = spotPriceObservation
    , observeOperationalIdentityCapability = operationalIdentityObservation
    , observeProviderReadinessCapability = readinessObservation
    , issueEksClientAuthCapability = eksClientAuthObservation
    }

-- | Deep readiness for the production worker: the exact Provider Vault KV
-- object must be readable and those credentials must complete an STS identity
-- round trip. No ambient AWS source participates.
providerProductionReady :: VaultSession -> IO Bool
providerProductionReady vaultSession = do
  credentialsResult <- readProviderCredentials vaultSession
  case credentialsResult of
    Left _ -> pure False
    Right credentials -> do
      environment <- awsCliSubprocessEnvironment credentials
      output <- runAws environment ["sts", "get-caller-identity", "--output", "json"]
      pure $ case commandSuccess output of
        Left _ -> False
        Right _ -> True

data DesiredState = DesiredPresent | DesiredAbsent

data CompiledStack = CompiledStack
  { compiledStackPulumiRef :: !PulumiStackRef
  , compiledStackProjectDirectory :: !FilePath
  , compiledStackConfiguration :: ![(String, String)]
  }

compiledStackFor
  :: ProviderStackRef
  -> ProviderStackConfig
  -> Either Text CompiledStack
compiledStackFor ref config = case (providerStackRefText ref, config) of
  ("aws-eks", AwsEksProviderStackConfig operatorCidr) ->
    Right
      ( stack
          "prodbox-aws-eks-test"
          "aws-eks-test"
          "aws-eks"
          [("operatorCidr", Text.unpack operatorCidr)]
      )
  ("aws-eks-subzone", AwsEksSubzoneProviderStackConfig parentZoneId subzoneName) ->
    Right
      ( stack
          "prodbox-aws-eks-subzone"
          "aws-eks-subzone"
          "aws-eks-subzone"
          [ ("parentZoneId", Text.unpack parentZoneId)
          , ("subzoneName", Text.unpack subzoneName)
          ]
      )
  ("aws-test", AwsTestProviderStackConfig operatorCidr) ->
    Right
      ( stack
          "prodbox-aws-test"
          "aws-test"
          "aws-test"
          [("operatorCidr", Text.unpack operatorCidr)]
      )
  _ -> Left "provider stack/config pair is not in the compiled non-SES registry"
 where
  stack project stackId subdirectory configuration =
    CompiledStack
      { compiledStackPulumiRef = PulumiStackRef project stackId
      , compiledStackProjectDirectory = providerBuildRoot </> "pulumi" </> subdirectory
      , compiledStackConfiguration = configuration
      }

providerBuildRoot :: FilePath
providerBuildRoot = "/opt/build"

pulumiMutation
  :: DesiredState
  -> ProviderStackRef
  -> ProviderStackConfig
  -> ProviderMutation IO ProviderProductionSession
pulumiMutation desired ref config =
  ProviderMutation
    { observeProviderMutation = \session _coordinate ->
        observeDesiredStack session desired ref config
    , applyProviderMutation = \session _coordinate ->
        applyDesiredStack session desired ref config
    }

observeDesiredStack
  :: ProviderProductionSession
  -> DesiredState
  -> ProviderStackRef
  -> ProviderStackConfig
  -> IO ProviderEffectObservation
observeDesiredStack session desired ref config =
  case compiledStackFor ref config of
    Left detail -> pure (ProviderEffectUnobservable detail)
    Right compiled -> do
      environment <- pulumiEnvironment (productionSessionCredentials session)
      observed <-
        withAuthenticatedObservedDecryptedStackEnvironment
          (productionSessionAuthorityTransport session)
          (compiledStackPulumiRef compiled)
          environment
          (observePulumiStack desired compiled)
      pure $ case observed of
        Left err -> ProviderEffectUnobservable (renderBackendError err)
        Right observation -> observation

applyDesiredStack
  :: ProviderProductionSession
  -> DesiredState
  -> ProviderStackRef
  -> ProviderStackConfig
  -> IO (Either Text ())
applyDesiredStack session desired ref config =
  case compiledStackFor ref config of
    Left detail -> pure (Left detail)
    Right compiled -> do
      environment <- pulumiEnvironment (productionSessionCredentials session)
      result <-
        withAuthenticatedDecryptedStackEnvironment
          (productionSessionAuthorityTransport session)
          (compiledStackPulumiRef compiled)
          environment
          (runPulumiMutation desired compiled)
      pure (either (Left . renderBackendError) (const (Right ())) result)

observePulumiStack
  :: DesiredState
  -> CompiledStack
  -> [(String, String)]
  -> IO (Either String ProviderEffectObservation)
observePulumiStack desired compiled environment = do
  login <- runPulumi compiled environment ["login", backendUrl environment]
  case commandSuccess login of
    Left detail -> pure (Right (ProviderEffectUnobservable (Text.pack detail)))
    Right _ -> do
      selected <-
        runPulumi
          compiled
          environment
          ["stack", "select", "--stack", stackName compiled, "--non-interactive"]
      case processExitCode selected of
        ExitFailure _
          | missingStack selected ->
              pure
                ( Right $ case desired of
                    DesiredPresent -> ProviderEffectNeedsApply "registered stack is absent"
                    DesiredAbsent -> ProviderEffectSatisfied "registered stack is absent"
                )
          | otherwise -> pure (Right (ProviderEffectUnobservable (Text.pack (commandDetail selected))))
        ExitSuccess -> case desired of
          DesiredAbsent -> pure (Right (ProviderEffectNeedsApply "registered stack is present"))
          DesiredPresent -> do
            preview <-
              runPulumi
                compiled
                environment
                [ "preview"
                , "--stack"
                , stackName compiled
                , "--expect-no-changes"
                , "--non-interactive"
                , "--color"
                , "never"
                ]
            pure $ case processExitCode preview of
              ExitSuccess -> Right (ProviderEffectSatisfied (stackEvidence selected))
              ExitFailure _
                | previewReportsChanges preview ->
                    Right (ProviderEffectNeedsApply "Pulumi preview reports changes")
                | otherwise -> Right (ProviderEffectUnobservable (Text.pack (commandDetail preview)))

runPulumiMutation
  :: DesiredState
  -> CompiledStack
  -> [(String, String)]
  -> IO (Either String ())
runPulumiMutation desired compiled environment = do
  login <- runPulumi compiled environment ["login", backendUrl environment]
  case commandSuccess login of
    Left detail -> pure (Left detail)
    Right _ -> case desired of
      DesiredPresent -> do
        selected <-
          runPulumi
            compiled
            environment
            ["stack", "select", "--stack", stackName compiled, "--create", "--non-interactive"]
        case commandSuccess selected of
          Left detail -> pure (Left detail)
          Right _ -> do
            configured <- setPulumiConfiguration compiled environment
            case configured of
              Left detail -> pure (Left detail)
              Right () ->
                do
                  updated <-
                    runPulumi
                      compiled
                      environment
                      ["up", "--stack", stackName compiled, "--yes", "--skip-preview", "--non-interactive"]
                  pure (Control.Monad.void (commandSuccess updated))
      DesiredAbsent -> do
        selected <-
          runPulumi
            compiled
            environment
            ["stack", "select", "--stack", stackName compiled, "--non-interactive"]
        if missingStack selected
          then pure (Right ())
          else case commandSuccess selected of
            Left detail -> pure (Left detail)
            Right _ -> do
              destroyed <-
                runPulumi
                  compiled
                  environment
                  ["destroy", "--stack", stackName compiled, "--yes", "--skip-preview", "--non-interactive"]
              case commandSuccess destroyed of
                Left detail -> pure (Left detail)
                Right _ -> do
                  removed <-
                    runPulumi
                      compiled
                      environment
                      ["stack", "rm", "--stack", stackName compiled, "--yes", "--non-interactive"]
                  pure (Control.Monad.void (commandSuccess removed))

setPulumiConfiguration
  :: CompiledStack
  -> [(String, String)]
  -> IO (Either String ())
setPulumiConfiguration compiled environment = go (compiledStackConfiguration compiled)
 where
  go [] = pure (Right ())
  go ((key, value) : remaining) = do
    output <-
      runPulumi
        compiled
        environment
        ["config", "set", "--stack", stackName compiled, key, value, "--non-interactive"]
    case commandSuccess output of
      Left detail -> pure (Left detail)
      Right _ -> go remaining

observeStackRef
  :: ProviderProductionSession
  -> ProviderStackRef
  -> IO (Either Text Text)
observeStackRef session ref =
  case defaultCompiledStack ref of
    Left detail -> pure (Left detail)
    Right compiled -> do
      environment <- pulumiEnvironment (productionSessionCredentials session)
      result <-
        withAuthenticatedObservedDecryptedStackEnvironment
          (productionSessionAuthorityTransport session)
          (compiledStackPulumiRef compiled)
          environment
          (readPulumiStack compiled)
      pure $ case result of
        Left err -> Left (renderBackendError err)
        Right evidence -> Right evidence

defaultCompiledStack :: ProviderStackRef -> Either Text CompiledStack
defaultCompiledStack ref = case providerStackRefText ref of
  "aws-eks" -> compiledStackFor ref (AwsEksProviderStackConfig "127.0.0.1/32")
  "aws-eks-subzone" ->
    compiledStackFor ref (AwsEksSubzoneProviderStackConfig "observation" "observation.invalid")
  "aws-test" -> compiledStackFor ref (AwsTestProviderStackConfig "127.0.0.1/32")
  _ -> Left "stack is not in the compiled non-SES registry"

readPulumiStack
  :: CompiledStack
  -> [(String, String)]
  -> IO (Either String Text)
readPulumiStack compiled environment = do
  login <- runPulumi compiled environment ["login", backendUrl environment]
  case commandSuccess login of
    Left detail -> pure (Left detail)
    Right _ -> do
      selected <-
        runPulumi
          compiled
          environment
          ["stack", "select", "--stack", stackName compiled, "--non-interactive"]
      if missingStack selected
        then pure (Right "registered stack is absent")
        else case commandSuccess selected of
          Left detail -> pure (Left detail)
          Right _ -> do
            output <-
              runPulumi compiled environment ["stack", "output", "--stack", stackName compiled, "--json"]
            pure (stackEvidence <$> commandSuccess output)

pulumiEnvironment :: Credentials -> IO [(String, String)]
pulumiEnvironment credentials = do
  inherited <- getEnvironment
  let select key = maybe [] (\value -> [(key, value)]) (lookup key inherited)
  pure
    ( concatMap select ["PATH", "HOME", "LANG", "TERM", "USER"]
        <> [ ("AWS_EC2_METADATA_DISABLED", "true")
           , ("PULUMI_SKIP_UPDATE_CHECK", "true")
           ]
        <> pulumiAwsProviderEnv credentials
    )

runPulumi
  :: CompiledStack
  -> [(String, String)]
  -> [String]
  -> IO ProcessOutput
runPulumi compiled environment arguments = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "/usr/local/bin/pulumi"
        , subprocessArguments = arguments
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Just (compiledStackProjectDirectory compiled)
        }
  pure $ case result of
    Success output -> output
    Failure detail -> ProcessOutput (ExitFailure 1) "" detail

commandSuccess :: ProcessOutput -> Either String ProcessOutput
commandSuccess output = case processExitCode output of
  ExitSuccess -> Right output
  ExitFailure _ -> Left (commandDetail output)

commandDetail :: ProcessOutput -> String
commandDetail output =
  let detail = processStderr output <> " " <> processStdout output
   in take 4096 detail

missingStack :: ProcessOutput -> Bool
missingStack = containsAny ["no stack named", "could not find stack", "stack not found"] . commandDetail

previewReportsChanges :: ProcessOutput -> Bool
previewReportsChanges =
  containsAny
    [ "no changes were expected but changes were proposed"
    , "error: no changes were expected"
    ]
    . commandDetail

containsAny :: [String] -> String -> Bool
containsAny needles haystack = any ((`Text.isInfixOf` lowered) . Text.pack) needles
 where
  lowered = Text.toLower (Text.pack haystack)

stackName :: CompiledStack -> String
stackName = Text.unpack . pulumiStackName . compiledStackPulumiRef

backendUrl :: [(String, String)] -> String
backendUrl environment = maybe "" id (lookup "PULUMI_BACKEND_URL" environment)

stackEvidence :: ProcessOutput -> Text
stackEvidence output =
  "sha256:" <> sha256Text (TextEncoding.encodeUtf8 (Text.pack (processStdout output)))

renderBackendError :: EncryptedBackendError -> Text
renderBackendError = Text.pack . renderEncryptedBackendError

sha256Text :: ByteString -> Text
sha256Text = Text.pack . concatMap renderByte . ByteString.unpack . SHA256.hash
 where
  renderByte byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits

readProviderCredentials :: VaultSession -> IO (Either Text Credentials)
readProviderCredentials session = do
  result <-
    withSessionToken session $ \token ->
      vaultKvReadV2 (sessionAddress session) token "secret" "aws/lifecycle-provider"
  pure $ case result of
    Left err -> Left (Text.pack (show err))
    Right fields -> credentialsFromFields fields

credentialsFromFields :: Map.Map Text Text -> Either Text Credentials
credentialsFromFields fields = do
  accessKey <- required "access_key_id"
  secretKey <- required "secret_access_key"
  awsRegion <- required "region"
  let token = nonEmpty =<< Map.lookup "session_token" fields
  Right
    Credentials
      { access_key_id = accessKey
      , secret_access_key = secretKey
      , session_token = token
      , region = awsRegion
      }
 where
  required key =
    maybe
      (Left ("provider credential field is missing: " <> key))
      Right
      (nonEmpty =<< Map.lookup key fields)
  nonEmpty value =
    let normalized = Text.strip value
     in if Text.null normalized then Nothing else Just normalized

ebsReaperMutation :: Text -> ProviderMutation IO ProviderProductionSession
ebsReaperMutation clusterName =
  ProviderMutation
    { observeProviderMutation = \session _ -> do
        environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
        observed <-
          EbsVolume.discoverEbsVolumes
            EbsVolume.EbsDiscoverInput
              { EbsVolume.ebsDiscoverEnvironment = environment
              , EbsVolume.ebsDiscoverWorkingDirectory = Nothing
              , EbsVolume.ebsDiscoverScope = EbsVolume.EbsPerRunTest (Text.unpack clusterName)
              }
        pure $ case observed of
          Left detail -> ProviderEffectUnobservable (Text.pack detail)
          Right [] -> ProviderEffectSatisfied "test-scoped EBS volumes are absent"
          Right _ -> ProviderEffectNeedsApply "test-scoped EBS volumes remain"
    , applyProviderMutation = \session _ -> do
        environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
        result <-
          EbsVolume.runTestScopedEbsReaper
            EbsVolume.TestEbsReaperInput
              { EbsVolume.testEbsReaperEnvironment = environment
              , EbsVolume.testEbsReaperWorkingDirectory = Nothing
              , EbsVolume.testEbsReaperClusterName = Text.unpack clusterName
              }
        pure (either (Left . Text.pack) (const (Right ())) result)
    }

spotPriceObservation
  :: ProviderSpotPriceQuery
  -> ProviderReadOnly IO ProviderProductionSession
spotPriceObservation query = ProviderReadOnly $ \session _ -> do
  environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
  output <-
    runAws
      environment
      [ "ec2"
      , "describe-spot-price-history"
      , "--instance-types"
      , Text.unpack (providerSpotPriceInstanceType query)
      , "--product-descriptions"
      , Text.unpack (providerSpotPriceProductDescription query)
      , "--max-results"
      , "1"
      , "--output"
      , "json"
      ]
  pure $ do
    successful <- firstText (Text.pack . processStdout <$> commandSuccess output)
    extractSpotPrice successful

extractSpotPrice :: Text -> Either Text Text
extractSpotPrice payload = case eitherDecodeStrict' (TextEncoding.encodeUtf8 payload) of
  Right (Object root) -> case KeyMap.lookup "SpotPriceHistory" root of
    Just (Array history) -> case Vector.toList history of
      Object entry : _ -> case KeyMap.lookup "SpotPrice" entry of
        Just (String price) | not (Text.null (Text.strip price)) -> Right ("spot-price:" <> price)
        _ -> Left "spot price response has no price"
      _ -> Left "spot price response has no history"
    Just _ -> Left "spot price response history is invalid"
    Nothing -> Left "spot price response has no history"
  _ -> Left "spot price response is invalid JSON"

operationalIdentityObservation :: ProviderReadOnly IO ProviderProductionSession
operationalIdentityObservation = ProviderReadOnly $ \session _ -> do
  environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
  output <- runAws environment ["sts", "get-caller-identity", "--output", "json"]
  pure $ do
    successful <- firstText (processStdout <$> commandSuccess output)
    root <- decodeObject successful
    arn <- requireTextField "Arn" root
    if Text.null (Text.strip arn) || Text.length arn > 2048
      then Left "STS identity ARN is absent or exceeds the evidence bound"
      else Right ("sts-identity:" <> arn)

readinessObservation
  :: ProviderReadinessProbe
  -> ProviderReadOnly IO ProviderProductionSession
readinessObservation probe = ProviderReadOnly $ \session _ -> do
  environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
  case probe of
    ProviderReadinessStsIdentity -> do
      output <- runAws environment ["sts", "get-caller-identity", "--output", "json"]
      pure ("provider-readiness:" <> stackEvidence output <$ firstText (commandSuccess output))
    ProviderReadinessRoute53Zone zoneId -> do
      output <-
        runAws environment ["route53", "get-hosted-zone", "--id", Text.unpack zoneId, "--output", "json"]
      pure $ do
        payload <- firstText (processStdout <$> commandSuccess output)
        if length payload > 2400
          then Left "Route 53 hosted-zone observation exceeds the evidence bound"
          else
            Right
              ( "provider-readiness-route53-json:"
                  <> TextEncoding.decodeUtf8
                    (Base64.encode (TextEncoding.encodeUtf8 (Text.pack payload)))
              )

eksClientAuthObservation
  :: EksClientAuthRequest
  -> ProviderReadOnly IO ProviderProductionSession
eksClientAuthObservation request = ProviderReadOnly $ \session _ -> do
  let credentials = productionSessionCredentials session
      requestedRegion = eksClientAuthRequestRegion request
      requestedCluster = eksClientAuthRequestClusterName request
  if Text.strip (region credentials) /= requestedRegion
    then pure (Left "EKS client-auth request region does not match the Provider session")
    else do
      environment <- awsCliSubprocessEnvironment credentials
      identityOutput <- runAws environment ["sts", "get-caller-identity", "--output", "json"]
      clusterOutput <-
        runAws
          environment
          [ "eks"
          , "describe-cluster"
          , "--region"
          , Text.unpack requestedRegion
          , "--name"
          , Text.unpack requestedCluster
          , "--output"
          , "json"
          ]
      tokenOutput <-
        runAws
          environment
          [ "eks"
          , "get-token"
          , "--region"
          , Text.unpack requestedRegion
          , "--cluster-name"
          , Text.unpack requestedCluster
          , "--output"
          , "json"
          ]
      now <- floor <$> getPOSIXTime
      case parseProjection now identityOutput clusterOutput tokenOutput of
        Left detail -> pure (Left detail)
        Right (projection, publicKey) -> do
          sealed <- sealEksClientAuthProjection publicKey projection
          pure $ do
            envelope <- firstShow sealed
            Right
              ( "eks-client-auth-envelope:"
                  <> TextEncoding.decodeUtf8 (Base64.encode (encodeEksClientAuthEnvelope envelope))
              )
 where
  parseProjection now identityOutput clusterOutput tokenOutput = do
    identity <- firstText (processStdout <$> commandSuccess identityOutput) >>= decodeObject
    account <- requireTextField "Account" identity
    if account == eksClientAuthRequestAccountId request
      then Right ()
      else Left "EKS client-auth request account does not match the Provider session"
    clusterRoot <- firstText (processStdout <$> commandSuccess clusterOutput) >>= decodeObject
    cluster <- requireObjectField "cluster" clusterRoot
    clusterName <- requireTextField "name" cluster
    endpoint <- requireTextField "endpoint" cluster
    certificateAuthority <- requireObjectField "certificateAuthority" cluster
    certificateAuthorityData <- requireTextField "data" certificateAuthority
    if clusterName == eksClientAuthRequestClusterName request
      then Right ()
      else Left "EKS describe-cluster returned the wrong cluster identity"
    tokenRoot <- firstText (processStdout <$> commandSuccess tokenOutput) >>= decodeObject
    status <- requireObjectField "status" tokenRoot
    bearer <- requireTextField "token" status
    expirationTimestamp <- requireTextField "expirationTimestamp" status
    expires <- parseEksTokenExpiration expirationTimestamp
    if expires <= now || expires > now + 900
      then Left "EKS client-auth bearer expiration is outside the short-lived bound"
      else Right ()
    projection <-
      firstShow
        ( mkEksClientAuthProjection
            account
            (eksClientAuthRequestRegion request)
            (eksClientAuthRequestClusterName request)
            endpoint
            certificateAuthorityData
            bearer
            expires
        )
    publicKey <-
      firstShow
        (mkEksClientAuthPublicKey (eksClientAuthRequestDestinationPublicKey request))
    Right (projection, publicKey)

parseEksTokenExpiration :: Text -> Either Text Integer
parseEksTokenExpiration raw =
  case parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" (Text.unpack raw) :: Maybe UTCTime of
    Nothing -> Left "EKS get-token returned an invalid expirationTimestamp"
    Just value -> Right (floor (utcTimeToPOSIXSeconds value))

firstShow :: (Show err) => Either err value -> Either Text value
firstShow = either (Left . Text.pack . show) Right

runAws :: [(String, String)] -> [String] -> IO ProcessOutput
runAws environment arguments = do
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "aws"
        , subprocessArguments = arguments
        , subprocessEnvironment = Just environment
        , subprocessWorkingDirectory = Nothing
        }
  pure $ case result of
    Success output -> output
    Failure detail -> ProcessOutput (ExitFailure 1) "" detail

firstText :: Either String value -> Either Text value
firstText = either (Left . Text.pack) Right

scratchCheckpointMutation
  :: ProviderCheckpointRef
  -> ProviderMutation IO ProviderProductionSession
scratchCheckpointMutation checkpointRef =
  ProviderMutation
    { observeProviderMutation = observeScratchCheckpoint checkpointRef
    , applyProviderMutation = applyScratchCheckpoint checkpointRef
    }

observeScratchCheckpoint
  :: ProviderCheckpointRef
  -> ProviderProductionSession
  -> ProviderIntentCoordinate
  -> IO ProviderEffectObservation
observeScratchCheckpoint checkpointRef session _ =
  case checkpointStackFor checkpointRef of
    Left detail -> pure (ProviderEffectUnobservable detail)
    Right stackRef -> do
      environment <- pulumiEnvironment (productionSessionCredentials session)
      observed <-
        withAuthenticatedObservedDecryptedStackEnvironment
          (productionSessionAuthorityTransport session)
          stackRef
          environment
          verifyScratchEnvironment
      pure $ case observed of
        Left err -> ProviderEffectUnobservable (renderBackendError err)
        Right () -> ProviderEffectSatisfied "checkpoint hydrated into bounded RAM scratch"

applyScratchCheckpoint
  :: ProviderCheckpointRef
  -> ProviderProductionSession
  -> ProviderIntentCoordinate
  -> IO (Either Text ())
applyScratchCheckpoint checkpointRef session _ =
  case checkpointStackFor checkpointRef of
    Left detail -> pure (Left detail)
    Right stackRef -> do
      environment <- pulumiEnvironment (productionSessionCredentials session)
      result <-
        withAuthenticatedDecryptedStackEnvironment
          (productionSessionAuthorityTransport session)
          stackRef
          environment
          verifyScratchEnvironment
      pure (either (Left . renderBackendError) (const (Right ())) result)

checkpointStackFor :: ProviderCheckpointRef -> Either Text PulumiStackRef
checkpointStackFor checkpointRef =
  case providerCheckpointRefText checkpointRef of
    "aws-eks" -> Right (PulumiStackRef "prodbox-aws-eks-test" "aws-eks-test")
    "aws-eks-subzone" -> Right (PulumiStackRef "prodbox-aws-eks-subzone" "aws-eks-subzone")
    "aws-test" -> Right (PulumiStackRef "prodbox-aws-test" "aws-test")
    _ -> Left "checkpoint is not in the compiled Provider scratch registry"

verifyScratchEnvironment :: [(String, String)] -> IO (Either String ())
verifyScratchEnvironment environment =
  pure $ case lookup "PULUMI_BACKEND_URL" environment of
    Just value
      | "file://" `Text.isPrefixOf` Text.pack value -> Right ()
    _ -> Left "Authority checkpoint hydration did not supply a RAM file backend"

sesIdentityMutation :: SesIdentityRef -> ProviderMutation IO ProviderProductionSession
sesIdentityMutation ref =
  ProviderMutation
    { observeProviderMutation = \session _ -> observeSesIdentity session ref
    , applyProviderMutation = \session _ ->
        applySingleAwsCommand
          session
          ["ses", "verify-domain-identity", "--domain", Text.unpack (sesIdentityRefText ref)]
    }

observeSesIdentity
  :: ProviderProductionSession
  -> SesIdentityRef
  -> IO ProviderEffectObservation
observeSesIdentity session ref = do
  environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
  output <-
    runAws
      environment
      [ "ses"
      , "get-identity-verification-attributes"
      , "--identities"
      , Text.unpack (sesIdentityRefText ref)
      , "--output"
      , "json"
      ]
  pure $ case commandSuccess output of
    Left detail -> ProviderEffectUnobservable (Text.pack detail)
    Right _ -> case decodeObject (processStdout output) of
      Left detail -> ProviderEffectUnobservable detail
      Right root -> case KeyMap.lookup "VerificationAttributes" root of
        Just (Object attributes) ->
          case KeyMap.lookup (Key.fromText (sesIdentityRefText ref)) attributes of
            Nothing -> ProviderEffectNeedsApply "SES sending identity is absent"
            Just (Object identity)
              | Just (String token) <- KeyMap.lookup "VerificationToken" identity
              , not (Text.null (Text.strip token)) ->
                  ProviderEffectSatisfied (providerAwsEvidence "ses-identity" [output])
            _ -> ProviderEffectUnobservable "SES sending identity response is malformed"
        _ -> ProviderEffectUnobservable "SES verification attributes are missing"

sesDkimMutation :: SesIdentityRef -> ProviderMutation IO ProviderProductionSession
sesDkimMutation ref =
  ProviderMutation
    { observeProviderMutation = \session _ -> observeSesDkim session ref
    , applyProviderMutation = \session _ ->
        applySingleAwsCommand
          session
          ["ses", "verify-domain-dkim", "--domain", Text.unpack (sesIdentityRefText ref)]
    }

observeSesDkim
  :: ProviderProductionSession
  -> SesIdentityRef
  -> IO ProviderEffectObservation
observeSesDkim session ref = do
  environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
  output <-
    runAws
      environment
      [ "ses"
      , "get-identity-dkim-attributes"
      , "--identities"
      , Text.unpack (sesIdentityRefText ref)
      , "--output"
      , "json"
      ]
  pure $ case commandSuccess output of
    Left detail -> ProviderEffectUnobservable (Text.pack detail)
    Right _ -> case decodeObject (processStdout output) of
      Left detail -> ProviderEffectUnobservable detail
      Right root -> case KeyMap.lookup "DkimAttributes" root of
        Just (Object attributes) ->
          case KeyMap.lookup (Key.fromText (sesIdentityRefText ref)) attributes of
            Nothing -> ProviderEffectNeedsApply "SES DKIM identity is absent"
            Just (Object identity)
              | Just (Array tokens) <- KeyMap.lookup "DkimTokens" identity
              , not (Vector.null tokens)
              , all nonEmptyString (Vector.toList tokens) ->
                  ProviderEffectSatisfied (providerAwsEvidence "ses-dkim" [output])
            _ -> ProviderEffectUnobservable "SES DKIM response is malformed"
        _ -> ProviderEffectUnobservable "SES DKIM attributes are missing"

-- | Exact Route 53 ownership for the SES identity and receive lane. Pulumi is
-- deliberately absent from this mutation: the signed intent fixes the zone
-- and names, while the sealed Provider credential fixes the regional inbound
-- endpoint.
sesDnsMutation :: SesDnsRef -> ProviderMutation IO ProviderProductionSession
sesDnsMutation ref =
  ProviderMutation
    { observeProviderMutation = \session _ -> observeSesDns session ref
    , applyProviderMutation = \session _ -> applySesDns session ref
    }

publicARecordObservation
  :: PublicARecordRef -> ProviderReadOnly IO ProviderProductionSession
publicARecordObservation ref = ProviderReadOnly $ \session _ -> do
  observed <- observePublicARecord session ref
  pure $ case observed of
    ProviderEffectSatisfied evidence -> Right evidence
    ProviderEffectNeedsApply evidence -> Right evidence
    ProviderEffectUnobservable detail -> Left detail

publicARecordMutation
  :: PublicARecordRef -> ProviderMutation IO ProviderProductionSession
publicARecordMutation ref =
  ProviderMutation
    { observeProviderMutation = \session _ -> observePublicARecord session ref
    , applyProviderMutation = \session _ -> applyPublicARecord session ref
    }

observePublicARecord
  :: ProviderProductionSession -> PublicARecordRef -> IO ProviderEffectObservation
observePublicARecord session ref = case route53ClientForSession session of
  Left detail -> pure (ProviderEffectUnobservable detail)
  Right client -> do
    observed <-
      NativeRoute53.listExactResourceRecordSet
        client
        (publicARecordHostedZoneId ref)
        (publicARecordFqdn ref)
        NativeRoute53.RecordA
    pure $ case observed of
      Left err -> ProviderEffectUnobservable (nativeRoute53Error err)
      Right Nothing -> ProviderEffectNeedsApply "public-a-values:"
      Right (Just record) ->
        let values = NativeRoute53.rrsRecords record
            evidence = "public-a-values:" <> Text.intercalate "," values
         in if NativeRoute53.rrsTtl record == fromIntegral (publicARecordTtl ref)
              && values == publicARecordValues ref
              then ProviderEffectSatisfied evidence
              else ProviderEffectNeedsApply evidence

applyPublicARecord
  :: ProviderProductionSession -> PublicARecordRef -> IO (Either Text ())
applyPublicARecord session ref = case route53ClientForSession session of
  Left detail -> pure (Left detail)
  Right client -> do
    changed <-
      NativeRoute53.changeResourceRecordSets
        client
        (publicARecordHostedZoneId ref)
        [
          ( NativeRoute53.Upsert
          , NativeRoute53.ResourceRecordSet
              { NativeRoute53.rrsName = publicARecordFqdn ref
              , NativeRoute53.rrsType = NativeRoute53.RecordA
              , NativeRoute53.rrsTtl = fromIntegral (publicARecordTtl ref)
              , NativeRoute53.rrsRecords = publicARecordValues ref
              }
          )
        ]
    case changed of
      Left err -> pure (Left (nativeRoute53Error err))
      Right (changeId, status) -> awaitSesDnsChange client changeId status

data SesDnsInputs = SesDnsInputs
  { sesDnsVerificationToken :: !Text
  , sesDnsDkimTokens :: ![Text]
  }

observeSesDns
  :: ProviderProductionSession
  -> SesDnsRef
  -> IO ProviderEffectObservation
observeSesDns session ref = do
  inputsResult <- readSesDnsInputs session ref
  case inputsResult of
    Left detail -> pure (ProviderEffectUnobservable detail)
    Right Nothing ->
      pure
        ( ProviderEffectNeedsApply
            "SES identity or DKIM tokens are absent before DNS reconciliation"
        )
    Right (Just inputs) ->
      case desiredSesDnsRecords session ref inputs of
        Left detail -> pure (ProviderEffectUnobservable detail)
        Right desired -> observeSesDnsRecords session ref desired

applySesDns
  :: ProviderProductionSession
  -> SesDnsRef
  -> IO (Either Text ())
applySesDns session ref = do
  inputsResult <- ensureSesDnsInputs session ref
  case inputsResult >>= desiredSesDnsRecords session ref of
    Left detail -> pure (Left detail)
    Right desired ->
      case route53ClientForSession session of
        Left detail -> pure (Left detail)
        Right client -> do
          changed <-
            NativeRoute53.changeResourceRecordSets
              client
              (sesDnsHostedZoneId ref)
              [(NativeRoute53.Upsert, record) | record <- desired]
          case changed of
            Left err -> pure (Left (nativeRoute53Error err))
            Right (changeId, status) ->
              awaitSesDnsChange client changeId status

ensureSesDnsInputs
  :: ProviderProductionSession
  -> SesDnsRef
  -> IO (Either Text SesDnsInputs)
ensureSesDnsInputs session ref = do
  existing <- readSesDnsInputs session ref
  case existing of
    Left detail -> pure (Left detail)
    Right (Just inputs) -> pure (Right inputs)
    Right Nothing -> do
      identityResult <-
        applySingleAwsCommand
          session
          [ "ses"
          , "verify-domain-identity"
          , "--domain"
          , Text.unpack (sesDnsIdentityDomain ref)
          ]
      case identityResult of
        Left detail -> pure (Left detail)
        Right () -> do
          dkimResult <-
            applySingleAwsCommand
              session
              [ "ses"
              , "verify-domain-dkim"
              , "--domain"
              , Text.unpack (sesDnsIdentityDomain ref)
              ]
          case dkimResult of
            Left detail -> pure (Left detail)
            Right () -> do
              refreshed <- readSesDnsInputs session ref
              pure $ case refreshed of
                Left detail -> Left detail
                Right Nothing ->
                  Left "SES identity or DKIM tokens remained absent after reconcile"
                Right (Just inputs) -> Right inputs

readSesDnsInputs
  :: ProviderProductionSession
  -> SesDnsRef
  -> IO (Either Text (Maybe SesDnsInputs))
readSesDnsInputs session ref = do
  environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
  identityOutput <-
    runAws
      environment
      [ "ses"
      , "get-identity-verification-attributes"
      , "--identities"
      , Text.unpack (sesDnsIdentityDomain ref)
      , "--output"
      , "json"
      ]
  dkimOutput <-
    runAws
      environment
      [ "ses"
      , "get-identity-dkim-attributes"
      , "--identities"
      , Text.unpack (sesDnsIdentityDomain ref)
      , "--output"
      , "json"
      ]
  pure $ do
    _ <- firstText (commandSuccess identityOutput)
    _ <- firstText (commandSuccess dkimOutput)
    identityRoot <- decodeObject (processStdout identityOutput)
    dkimRoot <- decodeObject (processStdout dkimOutput)
    verificationToken <-
      optionalSesIdentityText
        "VerificationAttributes"
        "VerificationToken"
        (sesDnsIdentityDomain ref)
        identityRoot
    dkimTokens <-
      optionalSesIdentityTextArray
        "DkimAttributes"
        "DkimTokens"
        (sesDnsIdentityDomain ref)
        dkimRoot
    case (verificationToken, dkimTokens) of
      (Nothing, _) -> Right Nothing
      (_, Nothing) -> Right Nothing
      (Just token, Just tokens)
        | length tokens == 3 ->
            Right
              ( Just
                  SesDnsInputs
                    { sesDnsVerificationToken = token
                    , sesDnsDkimTokens = tokens
                    }
              )
        | otherwise -> Left "SES DKIM response did not contain exactly three tokens"

optionalSesIdentityText
  :: Text
  -> Text
  -> Text
  -> KeyMap.KeyMap Value
  -> Either Text (Maybe Text)
optionalSesIdentityText collectionName fieldName identity root =
  case KeyMap.lookup (Key.fromText collectionName) root of
    Just (Object attributes) ->
      case KeyMap.lookup (Key.fromText identity) attributes of
        Nothing -> Right Nothing
        Just (Object value) -> case KeyMap.lookup (Key.fromText fieldName) value of
          Just (String textValue)
            | not (Text.null (Text.strip textValue)) -> Right (Just textValue)
          _ -> Left ("SES " <> fieldName <> " field is malformed")
        _ -> Left ("SES " <> collectionName <> " identity is malformed")
    _ -> Left ("SES " <> collectionName <> " collection is missing")

optionalSesIdentityTextArray
  :: Text
  -> Text
  -> Text
  -> KeyMap.KeyMap Value
  -> Either Text (Maybe [Text])
optionalSesIdentityTextArray collectionName fieldName identity root =
  case KeyMap.lookup (Key.fromText collectionName) root of
    Just (Object attributes) ->
      case KeyMap.lookup (Key.fromText identity) attributes of
        Nothing -> Right Nothing
        Just (Object value) -> case KeyMap.lookup (Key.fromText fieldName) value of
          Just (Array rawValues) ->
            let values = [textValue | String textValue <- Vector.toList rawValues]
             in if length values == Vector.length rawValues
                  && all (not . Text.null . Text.strip) values
                  then Right (Just values)
                  else Left ("SES " <> fieldName <> " field is malformed")
          _ -> Left ("SES " <> fieldName <> " field is malformed")
        _ -> Left ("SES " <> collectionName <> " identity is malformed")
    _ -> Left ("SES " <> collectionName <> " collection is missing")

desiredSesDnsRecords
  :: ProviderProductionSession
  -> SesDnsRef
  -> SesDnsInputs
  -> Either Text [NativeRoute53.ResourceRecordSet]
desiredSesDnsRecords session ref inputs = do
  let providerRegion = Text.strip (region (productionSessionCredentials session))
  if Text.null providerRegion
    then Left "Provider AWS region is empty while rendering the SES MX target"
    else
      Right
        ( verificationRecord
            : map dkimRecord (sesDnsDkimTokens inputs)
              <> [mxRecord providerRegion]
        )
 where
  verificationRecord =
    NativeRoute53.ResourceRecordSet
      { NativeRoute53.rrsName = "_amazonses." <> sesDnsIdentityDomain ref
      , NativeRoute53.rrsType = NativeRoute53.RecordTXT
      , NativeRoute53.rrsTtl = sesDnsRecordTtl
      , NativeRoute53.rrsRecords = [route53TxtValue (sesDnsVerificationToken inputs)]
      }
  dkimRecord token =
    NativeRoute53.ResourceRecordSet
      { NativeRoute53.rrsName = token <> "._domainkey." <> sesDnsIdentityDomain ref
      , NativeRoute53.rrsType = NativeRoute53.RecordCNAME
      , NativeRoute53.rrsTtl = sesDnsRecordTtl
      , NativeRoute53.rrsRecords = [token <> ".dkim.amazonses.com."]
      }
  mxRecord providerRegion =
    NativeRoute53.ResourceRecordSet
      { NativeRoute53.rrsName = sesDnsReceiveSubdomain ref
      , NativeRoute53.rrsType = NativeRoute53.RecordMX
      , NativeRoute53.rrsTtl = sesDnsRecordTtl
      , NativeRoute53.rrsRecords =
          ["10 inbound-smtp." <> providerRegion <> ".amazonaws.com."]
      }

observeSesDnsRecords
  :: ProviderProductionSession
  -> SesDnsRef
  -> [NativeRoute53.ResourceRecordSet]
  -> IO ProviderEffectObservation
observeSesDnsRecords session ref desired =
  case route53ClientForSession session of
    Left detail -> pure (ProviderEffectUnobservable detail)
    Right client -> go client desired
 where
  go _ [] =
    pure
      ( ProviderEffectSatisfied
          ( "ses-dns:"
              <> sesDnsHostedZoneId ref
              <> ":"
              <> Text.intercalate "," (map NativeRoute53.rrsName desired)
          )
      )
  go client (expected : remaining) = do
    observed <-
      NativeRoute53.listExactResourceRecordSet
        client
        (sesDnsHostedZoneId ref)
        (NativeRoute53.rrsName expected)
        (NativeRoute53.rrsType expected)
    case observed of
      Left err -> pure (ProviderEffectUnobservable (nativeRoute53Error err))
      Right Nothing ->
        pure
          ( ProviderEffectNeedsApply
              ("SES DNS record is absent: " <> NativeRoute53.rrsName expected)
          )
      Right (Just actual)
        | exactSesDnsRecord expected actual -> go client remaining
        | otherwise ->
            pure
              ( ProviderEffectNeedsApply
                  ("SES DNS record differs: " <> NativeRoute53.rrsName expected)
              )

route53ClientForSession
  :: ProviderProductionSession
  -> Either Text NativeRoute53.Route53Client
route53ClientForSession session =
  case baseCredentialHandleFromSettings (productionSessionCredentials session) of
    Left err -> Left ("Provider AWS credential is invalid: " <> Text.pack (show err))
    Right handle -> Right (NativeRoute53.newRoute53Client handle httpSend)

awaitSesDnsChange
  :: NativeRoute53.Route53Client
  -> NativeRoute53.ChangeId
  -> NativeRoute53.ChangeStatus
  -> IO (Either Text ())
awaitSesDnsChange _ _ NativeRoute53.ChangeInsync = pure (Right ())
awaitSesDnsChange client changeId NativeRoute53.ChangePending = do
  completed <- timeout sesDnsChangeTimeoutMicros (poll sesDnsChangePollLimit)
  pure $ case completed of
    Nothing -> Left "Route 53 SES DNS change timed out before INSYNC"
    Just result -> result
 where
  poll attempts
    | attempts <= (0 :: Int) = pure (Left "Route 53 SES DNS change remained PENDING")
    | otherwise = do
        threadDelay sesDnsChangePollDelayMicros
        observed <- NativeRoute53.getChange client changeId
        case observed of
          Left err -> pure (Left (nativeRoute53Error err))
          Right NativeRoute53.ChangeInsync -> pure (Right ())
          Right NativeRoute53.ChangePending -> poll (attempts - 1)

exactSesDnsRecord
  :: NativeRoute53.ResourceRecordSet
  -> NativeRoute53.ResourceRecordSet
  -> Bool
exactSesDnsRecord expected actual =
  canonicalDnsName (NativeRoute53.rrsName actual)
    == canonicalDnsName (NativeRoute53.rrsName expected)
    && NativeRoute53.rrsType actual == NativeRoute53.rrsType expected
    && NativeRoute53.rrsTtl actual == NativeRoute53.rrsTtl expected
    && map (canonicalDnsValue (NativeRoute53.rrsType expected)) (NativeRoute53.rrsRecords actual)
      == map (canonicalDnsValue (NativeRoute53.rrsType expected)) (NativeRoute53.rrsRecords expected)

canonicalDnsName :: Text -> Text
canonicalDnsName = Text.toLower . Text.dropWhileEnd (== '.') . Text.strip

canonicalDnsValue :: NativeRoute53.RecordType -> Text -> Text
canonicalDnsValue recordType raw = case recordType of
  NativeRoute53.RecordCNAME -> canonicalDnsName raw
  NativeRoute53.RecordMX ->
    case Text.words (Text.strip raw) of
      [priority, target] -> priority <> " " <> canonicalDnsName target
      _ -> Text.strip raw
  _ -> Text.strip raw

route53TxtValue :: Text -> Text
route53TxtValue value = "\"" <> value <> "\""

nativeRoute53Error :: (Show errorValue) => errorValue -> Text
nativeRoute53Error = ("Route 53 SES DNS request failed: " <>) . Text.pack . show

sesDnsRecordTtl :: Int
sesDnsRecordTtl = 300

sesDnsChangePollLimit :: Int
sesDnsChangePollLimit = 30

sesDnsChangePollDelayMicros :: Int
sesDnsChangePollDelayMicros = 1000000

sesDnsChangeTimeoutMicros :: Int
sesDnsChangeTimeoutMicros = 35000000

sesReceiptRulesMutation
  :: SesRuleSetRef
  -> ProviderMutation IO ProviderProductionSession
sesReceiptRulesMutation ref =
  ProviderMutation
    { observeProviderMutation = \session _ -> observeSesReceiptRules session ref
    , applyProviderMutation = \session _ -> applySesReceiptRules session ref
    }

observeSesReceiptRules
  :: ProviderProductionSession
  -> SesRuleSetRef
  -> IO ProviderEffectObservation
observeSesReceiptRules session ref = do
  environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
  let ruleSetName = Text.unpack (sesRuleSetRefText ref)
  ruleSet <-
    runAws
      environment
      ["ses", "describe-receipt-rule-set", "--rule-set-name", ruleSetName, "--output", "json"]
  case commandSuccess ruleSet of
    Left _
      | knownAwsAbsent ruleSet ->
          pure (ProviderEffectNeedsApply "SES receipt rule set is absent")
      | otherwise -> pure (ProviderEffectUnobservable (Text.pack (commandDetail ruleSet)))
    Right _ -> do
      rule <-
        runAws
          environment
          [ "ses"
          , "describe-receipt-rule"
          , "--rule-set-name"
          , ruleSetName
          , "--rule-name"
          , sesReceiveRuleName
          , "--output"
          , "json"
          ]
      case commandSuccess rule of
        Left _
          | knownAwsAbsent rule ->
              pure (ProviderEffectNeedsApply "SES capture receipt rule is absent")
          | otherwise -> pure (ProviderEffectUnobservable (Text.pack (commandDetail rule)))
        Right _ -> case exactSesReceiptRule ref (processStdout rule) of
          Left detail -> pure (ProviderEffectUnobservable detail)
          Right False -> pure (ProviderEffectNeedsApply "SES capture receipt rule differs")
          Right True -> do
            active <-
              runAws environment ["ses", "describe-active-receipt-rule-set", "--output", "json"]
            pure $ case commandSuccess active of
              Left detail -> ProviderEffectUnobservable (Text.pack detail)
              Right _ -> case activeSesRuleSetName (processStdout active) of
                Left detail -> ProviderEffectUnobservable detail
                Right (Just actual)
                  | actual == sesRuleSetRefText ref ->
                      ProviderEffectSatisfied
                        (providerAwsEvidence "ses-receipt-rules" [ruleSet, rule, active])
                Right _ -> ProviderEffectNeedsApply "SES receipt rule set is not active"

applySesReceiptRules
  :: ProviderProductionSession
  -> SesRuleSetRef
  -> IO (Either Text ())
applySesReceiptRules session ref = do
  environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
  let ruleSetName = Text.unpack (sesRuleSetRefText ref)
  created <-
    runAws environment ["ses", "create-receipt-rule-set", "--rule-set-name", ruleSetName]
  case commandSuccess created of
    Left detail
      | not (knownAwsAlreadyExists created) -> pure (Left (Text.pack detail))
    _ -> do
      existing <-
        runAws
          environment
          [ "ses"
          , "describe-receipt-rule"
          , "--rule-set-name"
          , ruleSetName
          , "--rule-name"
          , sesReceiveRuleName
          , "--output"
          , "json"
          ]
      ruleVerb <- case commandSuccess existing of
        Right _ -> pure (Right "update-receipt-rule")
        Left _
          | knownAwsAbsent existing -> pure (Right "create-receipt-rule")
          | otherwise -> pure (Left (Text.pack (commandDetail existing)))
      case ruleVerb of
        Left detail -> pure (Left detail)
        Right verb -> do
          ruleResult <-
            runAws
              environment
              [ "ses"
              , verb
              , "--rule-set-name"
              , ruleSetName
              , "--rule"
              , jsonArgument (desiredSesReceiptRule ref)
              ]
          case commandSuccess ruleResult of
            Left detail -> pure (Left (Text.pack detail))
            Right _ -> do
              active <-
                runAws
                  environment
                  ["ses", "set-active-receipt-rule-set", "--rule-set-name", ruleSetName]
              pure (Control.Monad.void (firstText (commandSuccess active)))

sesCaptureBucketMutation
  :: SesBucketRef
  -> ProviderMutation IO ProviderProductionSession
sesCaptureBucketMutation ref =
  ProviderMutation
    { observeProviderMutation = \session _ -> observeSesCaptureBucket session ref
    , applyProviderMutation = \session _ -> applySesCaptureBucket session ref
    }

observeSesCaptureBucket
  :: ProviderProductionSession
  -> SesBucketRef
  -> IO ProviderEffectObservation
observeSesCaptureBucket session ref = do
  environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
  let bucket = Text.unpack (sesBucketRefText ref)
  headBucket <- runAws environment ["s3api", "head-bucket", "--bucket", bucket]
  case commandSuccess headBucket of
    Left _
      | knownAwsAbsent headBucket ->
          pure (ProviderEffectNeedsApply "SES capture bucket is absent")
      | otherwise -> pure (ProviderEffectUnobservable (Text.pack (commandDetail headBucket)))
    Right _ -> do
      policy <-
        runAws environment ["s3api", "get-bucket-policy", "--bucket", bucket, "--output", "json"]
      case commandSuccess policy of
        Left _
          | knownAwsAbsent policy ->
              pure (ProviderEffectNeedsApply "SES capture bucket policy is absent")
          | otherwise -> pure (ProviderEffectUnobservable (Text.pack (commandDetail policy)))
        Right _ -> case exactSesBucketPolicy ref (processStdout policy) of
          Left detail -> pure (ProviderEffectUnobservable detail)
          Right False -> pure (ProviderEffectNeedsApply "SES capture bucket policy differs")
          Right True -> do
            readiness <-
              runAws
                environment
                [ "s3api"
                , "head-object"
                , "--bucket"
                , bucket
                , "--key"
                , sesCaptureReadinessKey
                ]
            pure $ case commandSuccess readiness of
              Left _
                | knownAwsAbsent readiness ->
                    ProviderEffectNeedsApply "SES capture readiness object is absent"
                | otherwise -> ProviderEffectUnobservable (Text.pack (commandDetail readiness))
              Right _ ->
                ProviderEffectSatisfied
                  (providerAwsEvidence "ses-capture-bucket" [headBucket, policy, readiness])

applySesCaptureBucket
  :: ProviderProductionSession
  -> SesBucketRef
  -> IO (Either Text ())
applySesCaptureBucket session ref = do
  let credentials = productionSessionCredentials session
      awsRegion = Text.unpack (region credentials)
      bucket = Text.unpack (sesBucketRefText ref)
      createArguments =
        ["s3api", "create-bucket", "--bucket", bucket]
          <> if awsRegion == "us-east-1"
            then []
            else ["--create-bucket-configuration", "LocationConstraint=" <> awsRegion]
  environment <- awsCliSubprocessEnvironment credentials
  created <- runAws environment createArguments
  case commandSuccess created of
    Left detail
      | not (knownAwsAlreadyOwned created) -> pure (Left (Text.pack detail))
    _ -> do
      policy <-
        runAws
          environment
          [ "s3api"
          , "put-bucket-policy"
          , "--bucket"
          , bucket
          , "--policy"
          , jsonArgument (desiredSesBucketPolicy ref)
          ]
      case commandSuccess policy of
        Left detail -> pure (Left (Text.pack detail))
        Right _ -> do
          readiness <-
            runAws
              environment
              [ "s3api"
              , "put-object"
              , "--bucket"
              , bucket
              , "--key"
              , sesCaptureReadinessKey
              , "--body"
              , "/dev/null"
              , "--content-type"
              , "text/plain"
              ]
          pure (Control.Monad.void (firstText (commandSuccess readiness)))

applySingleAwsCommand
  :: ProviderProductionSession
  -> [String]
  -> IO (Either Text ())
applySingleAwsCommand session arguments = do
  environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
  output <- runAws environment arguments
  pure (Control.Monad.void (firstText (commandSuccess output)))

sesReceiveRuleName :: String
sesReceiveRuleName = "prodbox-capture-all-mail"

sesCaptureKeyPrefix :: Text
sesCaptureKeyPrefix = "inbound/"

sesCaptureReadinessKey :: String
sesCaptureReadinessKey = "inbound/.prodbox-readiness-capability-probe"

desiredSesReceiptRule :: SesRuleSetRef -> Value
desiredSesReceiptRule ref =
  object
    [ "Name" .= Text.pack sesReceiveRuleName
    , "Enabled" .= True
    , "TlsPolicy" .= ("Optional" :: Text)
    , "ScanEnabled" .= True
    , "Recipients" .= [sesRuleSetRecipient ref]
    , "Actions"
        .= [ object
               [ "S3Action"
                   .= object
                     [ "BucketName" .= sesBucketRefText (sesRuleSetCaptureBucket ref)
                     , "ObjectKeyPrefix" .= sesCaptureKeyPrefix
                     ]
               ]
           ]
    ]

exactSesReceiptRule :: SesRuleSetRef -> String -> Either Text Bool
exactSesReceiptRule ref payload = do
  root <- decodeObject payload
  rule <- requireObjectField "Rule" root
  name <- requireTextField "Name" rule
  enabled <- requireBoolField "Enabled" rule
  scanEnabled <- requireBoolField "ScanEnabled" rule
  tlsPolicy <- requireTextField "TlsPolicy" rule
  recipients <- requireTextArrayField "Recipients" rule
  actions <- case KeyMap.lookup "Actions" rule of
    Just (Array values) -> Right (Vector.toList values)
    _ -> Left "SES receipt rule actions are malformed"
  exactAction <- case actions of
    [Object action] -> do
      s3Action <- requireObjectField "S3Action" action
      bucket <- requireTextField "BucketName" s3Action
      prefix <- requireTextField "ObjectKeyPrefix" s3Action
      Right
        ( bucket == sesBucketRefText (sesRuleSetCaptureBucket ref)
            && prefix == sesCaptureKeyPrefix
        )
    _ -> Right False
  pure
    ( name == Text.pack sesReceiveRuleName
        && enabled
        && scanEnabled
        && tlsPolicy == "Optional"
        && recipients == [sesRuleSetRecipient ref]
        && exactAction
    )

activeSesRuleSetName :: String -> Either Text (Maybe Text)
activeSesRuleSetName payload = do
  root <- decodeObject payload
  case KeyMap.lookup "Metadata" root of
    Nothing -> Right Nothing
    Just (Object metadata) -> Just <$> requireTextField "Name" metadata
    _ -> Left "active SES receipt rule metadata is malformed"

desiredSesBucketPolicy :: SesBucketRef -> Value
desiredSesBucketPolicy ref =
  object
    [ "Version" .= ("2012-10-17" :: Text)
    , "Statement"
        .= [ object
               [ "Sid" .= ("AllowSESPuts" :: Text)
               , "Effect" .= ("Allow" :: Text)
               , "Principal" .= object ["Service" .= ("ses.amazonaws.com" :: Text)]
               , "Action" .= ("s3:PutObject" :: Text)
               , "Resource" .= ("arn:aws:s3:::" <> sesBucketRefText ref <> "/*")
               ]
           ]
    ]

exactSesBucketPolicy :: SesBucketRef -> String -> Either Text Bool
exactSesBucketPolicy ref payload = do
  root <- decodeObject payload
  encodedPolicy <- requireTextField "Policy" root
  policy <- case eitherDecodeStrict' (TextEncoding.encodeUtf8 encodedPolicy) of
    Left _ -> Left "SES capture bucket policy is invalid JSON"
    Right value -> Right value
  Right (policy == desiredSesBucketPolicy ref)

decodeObject :: String -> Either Text (KeyMap.KeyMap Value)
decodeObject payload = case eitherDecodeStrict' (TextEncoding.encodeUtf8 (Text.pack payload)) of
  Right (Object value) -> Right value
  _ -> Left "AWS response is invalid JSON"

requireObjectField :: Key.Key -> KeyMap.KeyMap Value -> Either Text (KeyMap.KeyMap Value)
requireObjectField key value = case KeyMap.lookup key value of
  Just (Object nested) -> Right nested
  _ -> Left ("AWS response object field is missing: " <> Key.toText key)

requireTextField :: Key.Key -> KeyMap.KeyMap Value -> Either Text Text
requireTextField key value = case KeyMap.lookup key value of
  Just (String textValue) -> Right textValue
  _ -> Left ("AWS response text field is missing: " <> Key.toText key)

requireBoolField :: Key.Key -> KeyMap.KeyMap Value -> Either Text Bool
requireBoolField key value = case KeyMap.lookup key value of
  Just (Bool boolValue) -> Right boolValue
  _ -> Left ("AWS response boolean field is missing: " <> Key.toText key)

requireTextArrayField :: Key.Key -> KeyMap.KeyMap Value -> Either Text [Text]
requireTextArrayField key value = case KeyMap.lookup key value of
  Just (Array values) -> traverse requireStringValue (Vector.toList values)
  _ -> Left ("AWS response array field is missing: " <> Key.toText key)
 where
  requireStringValue item = case item of
    String textValue -> Right textValue
    _ -> Left ("AWS response array contains a non-text value: " <> Key.toText key)

nonEmptyString :: Value -> Bool
nonEmptyString value = case value of
  String textValue -> not (Text.null (Text.strip textValue))
  _ -> False

jsonArgument :: Value -> String
jsonArgument =
  Text.unpack . TextEncoding.decodeUtf8 . LazyByteString.toStrict . encode

knownAwsAbsent :: ProcessOutput -> Bool
knownAwsAbsent =
  containsAny
    [ "notfound"
    , "not found"
    , "nosuchbucket"
    , "nosuchkey"
    , "receiptrulesetdoesnotexist"
    , "rule does not exist"
    , "cannot be found"
    ]
    . commandDetail

knownAwsAlreadyExists :: ProcessOutput -> Bool
knownAwsAlreadyExists =
  containsAny ["alreadyexists", "already exists"] . commandDetail

knownAwsAlreadyOwned :: ProcessOutput -> Bool
knownAwsAlreadyOwned =
  containsAny ["bucketalreadyownedbyyou", "already owned by you"] . commandDetail

providerAwsEvidence :: Text -> [ProcessOutput] -> Text
providerAwsEvidence label outputs =
  label
    <> ":sha256:"
    <> sha256Text
      ( TextEncoding.encodeUtf8
          (Text.intercalate "\NUL" (Text.pack . processStdout <$> outputs))
      )
