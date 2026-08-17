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
  , providerDnsOwnerAuthority
  , publicARecordProgramOutcome
  , sesDnsOwnerAuthority
  , sesDnsProgramOutcome
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
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time.Clock (UTCTime)
import Data.Time.Clock.POSIX (getPOSIXTime, utcTimeToPOSIXSeconds)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Data.Vector qualified as Vector
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.Aws.CredentialHandle (baseCredentialHandleFromSettings)
import Prodbox.Aws.Native.Route53 qualified as NativeRoute53
import Prodbox.Aws.Native.Wire (httpSend)
import Prodbox.AwsEnvironment (awsCliSubprocessEnvironment)
import Prodbox.ControlPlane.AuthenticatedTransport
  ( AuthenticatedClientTransport
  )
import Prodbox.ControlPlane.EksClientAuthProjection
  ( encodeEksClientAuthEnvelope
  , validateEksClusterArnBinding
  )
import Prodbox.ControlPlane.EksClientAuthProjection.Internal
  ( mkEksClientAuthProjection
  , mkEksClientAuthPublicKey
  , sealEksClientAuthProjection
  )
import Prodbox.ControlPlane.ProviderCredentialSession.Internal
  ( ValidatedProviderCredentialSession
  , validateProviderCredentialSessionInternal
  , validatedProviderCredentialSessionBindingInternal
  , validatedProviderCredentialSessionCredentialsInternal
  )
import Prodbox.ControlPlane.ProviderNarrowSession
  ( ProviderEffectObservation (..)
  , ProviderIntentCapabilities (..)
  , ProviderMutation (..)
  , ProviderNarrowSessionRunner (..)
  , ProviderReadOnly (..)
  )
import Prodbox.Http.Client (renderHttpError)
import Prodbox.Infra.AwsEksTestStack (pulumiAwsProviderEnv)
import Prodbox.Lifecycle.Authority.Genesis (AuthorityEpoch)
import Prodbox.Lifecycle.DnsRecord
  ( AwsAccountId
  , DnsCoordinateError
  , DnsOwnerAuthority
  , DnsProgramResult (..)
  , DnsRecordBoundary (..)
  , DnsRecordCoordinate
  , DnsRecordObservation (..)
  , DnsRecordOwner (AwsLifecycleProviderDnsOwner, AwsSesDnsOwner)
  , DnsRecordProgram (EnsureDnsRecord)
  , DnsRecordSet
  , DnsRecordType (DnsRecordA, DnsRecordCname, DnsRecordMx, DnsRecordTxt)
  , HostedZoneId
  , OwnershipEpoch
  , authorizedDnsOwner
  , dnsCoordinateName
  , dnsCoordinateType
  , dnsOwnerAuthorityForProcess
  , dnsRecordSetValues
  , mkAwsAccountId
  , mkDnsRecordSet
  , mkDnsRecordValue
  , mkHostedZoneId
  , mkOwnershipEpoch
  , mkPublicARecordCoordinate
  , mkSesDkimCoordinate
  , mkSesInboundMxCoordinate
  , mkSesVerificationCoordinate
  , runDnsRecordProgram
  , sesDkimRecordName
  , sesInboundMxRecordName
  , sesVerificationRecordName
  )
import Prodbox.Lifecycle.DnsRecord.Route53 (nativeDnsRecordSet, nativeDnsRecordType)
import Prodbox.Lifecycle.EbsVolume qualified as EbsVolume
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( EksClientAuthRequest
  , EksClusterIdentityRequest
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
  , eksClusterIdentityRequestAccountId
  , eksClusterIdentityRequestClusterName
  , eksClusterIdentityRequestRegion
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
import Prodbox.Lifecycle.Teardown.ProviderAwsScopeAdapter.Internal
  ( encodeProviderAwsScopeEvidence
  )
import Prodbox.Pulumi.EncryptedBackend
  ( EncryptedBackendError
  , PulumiStackRef (..)
  , renderEncryptedBackendError
  , withAuthenticatedDecryptedStackEnvironment
  , withAuthenticatedObservedDecryptedStackEnvironment
  )
import Prodbox.Result (Result (..))
import Prodbox.Runtime.Role
  ( RuntimeRole (LifecycleAuthorityRuntime, ProviderWorkerRuntime)
  )
import Prodbox.Settings (Credentials (..))
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  )
import Prodbox.Substrate (Substrate (SubstrateAws))
import Prodbox.Vault.Client
  ( KvV2SecretMetadata (kvV2SecretMetadataCurrentVersion)
  , vaultKvReadExactVersionV2
  , vaultKvReadMetadataV2
  )
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
  , productionSessionAuthorityEpoch :: !(IO (Either Text AuthorityEpoch))
  -- ^ Sprint 4.72: the retained Authority epoch this process is acting
  -- under, read on demand. A DNS coordinate binds an ownership generation,
  -- and the only truthful source of one is the Authority the role already
  -- trusts — not a number carried in the request.
  }

providerProductionNarrowSession
  :: VaultSession
  -> AuthenticatedClientTransport 'LifecycleAuthorityRuntime
  -> IO (Either Text AuthorityEpoch)
  -> ProviderNarrowSessionRunner IO ProviderProductionSession
providerProductionNarrowSession vaultSession authorityTransport readAuthorityEpoch =
  ProviderNarrowSessionRunner
    { withProviderNarrowSession = \_intent _deadline action -> do
        credentialSession <- readProviderCredentialSession vaultSession
        case credentialSession of
          Left detail -> pure (Left detail)
          Right resolved ->
            action
              (Just (validatedProviderCredentialSessionBindingInternal resolved))
              ProviderProductionSession
                { productionSessionCredentials =
                    validatedProviderCredentialSessionCredentialsInternal resolved
                , productionSessionAuthorityTransport = authorityTransport
                , productionSessionAuthorityEpoch = readAuthorityEpoch
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
    , observeTestEbsVolumesCapability = testEbsObservation
    , observeSpotPriceCapability = spotPriceObservation
    , observeOperationalIdentityCapability = operationalIdentityObservation
    , observeProviderAwsScopeCapability = providerAwsScopeObservation
    , observeProviderReadinessCapability = readinessObservation
    , issueEksClientAuthCapability = eksClientAuthObservation
    , observeEksClusterIdentityCapability = eksClusterIdentityObservation
    }

-- | Deep readiness for the production worker: the exact Provider Vault KV
-- object must be readable and those credentials must complete an STS identity
-- round trip. No ambient AWS source participates.
providerProductionReady :: VaultSession -> IO Bool
providerProductionReady vaultSession = do
  credentialSession <- readProviderCredentialSession vaultSession
  case credentialSession of
    Left _ -> pure False
    Right resolved -> do
      environment <-
        awsCliSubprocessEnvironment
          (validatedProviderCredentialSessionCredentialsInternal resolved)
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

readProviderCredentialSession
  :: VaultSession
  -> IO (Either Text ValidatedProviderCredentialSession)
readProviderCredentialSession session = do
  observed <-
    withSessionToken session $ \token -> do
      metadataResult <-
        vaultKvReadMetadataV2
          (sessionAddress session)
          token
          "secret"
          "aws/lifecycle-provider"
      case metadataResult of
        Left err -> pure (Left err)
        Right metadata -> do
          exactResult <-
            vaultKvReadExactVersionV2
              (sessionAddress session)
              token
              "secret"
              "aws/lifecycle-provider"
              (kvV2SecretMetadataCurrentVersion metadata)
          pure ((metadata,) <$> exactResult)
  pure $ case observed of
    Left err -> Left (Text.pack (renderHttpError err))
    Right (metadata, exact) ->
      first
        (Text.pack . show)
        (validateProviderCredentialSessionInternal metadata exact)

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

-- | Read-only, exact family observation for the lifecycle graph.  The
-- Provider session supplies the AWS account/region binding; the signed intent
-- supplies the cluster coordinate; and the evidence codec retains only the
-- bounded, client-side re-filtered volume identities.
testEbsObservation
  :: Text
  -> ProviderReadOnly IO ProviderProductionSession
testEbsObservation clusterName = ProviderReadOnly $ \session _ -> do
  environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
  observed <-
    EbsVolume.discoverEbsVolumes
      EbsVolume.EbsDiscoverInput
        { EbsVolume.ebsDiscoverEnvironment = environment
        , EbsVolume.ebsDiscoverWorkingDirectory = Nothing
        , EbsVolume.ebsDiscoverScope =
            EbsVolume.EbsPerRunTest (Text.unpack clusterName)
        }
  pure $ case observed of
    Left detail -> Left (Text.pack detail)
    Right volumes ->
      Right
        ( EbsVolume.renderTestScopedEbsObservation
            ( EbsVolume.testScopedEbsObservation
                (Text.unpack clusterName)
                volumes
            )
        )

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

-- | Exact account/region observation for lifecycle admission.  Account comes
-- only from a successful STS response under the scoped Provider session;
-- region comes from the same session's sealed Vault credentials.  The hidden
-- codec emits neither credentials nor the raw STS response.
providerAwsScopeObservation :: ProviderReadOnly IO ProviderProductionSession
providerAwsScopeObservation = ProviderReadOnly $ \session _ -> do
  let credentials = productionSessionCredentials session
  environment <- awsCliSubprocessEnvironment credentials
  output <- runAws environment ["sts", "get-caller-identity", "--output", "json"]
  pure $ do
    successful <- firstText (processStdout <$> commandSuccess output)
    root <- decodeObject successful
    account <- requireTextField "Account" root
    first
      (Text.pack . show)
      (encodeProviderAwsScopeEvidence account (region credentials))

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

-- | Exact EKS control-plane identity observation.  Only a successful
-- DescribeCluster response can produce an ARN.  Absence is recognized from
-- the exact AWS CLI error grammar for this named request; every other failure
-- remains unobservable at the Provider boundary.
eksClusterIdentityObservation
  :: EksClusterIdentityRequest
  -> ProviderReadOnly IO ProviderProductionSession
eksClusterIdentityObservation request = ProviderReadOnly $ \session _ -> do
  let credentials = productionSessionCredentials session
      requestedAccount = eksClusterIdentityRequestAccountId request
      requestedRegion = eksClusterIdentityRequestRegion request
      requestedCluster = eksClusterIdentityRequestClusterName request
  if Text.strip (region credentials) /= requestedRegion
    then pure (Left "EKS identity request region does not match the Provider session")
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
      pure $ do
        identity <- firstText (processStdout <$> commandSuccess identityOutput) >>= decodeObject
        account <- requireTextField "Account" identity
        if account == requestedAccount
          then Right ()
          else Left "EKS identity request account does not match the Provider session"
        case commandSuccess clusterOutput of
          Left _
            | exactEksClusterNotFound requestedCluster clusterOutput ->
                Right "registered EKS cluster is absent"
            | otherwise -> Left (Text.pack (commandDetail clusterOutput))
          Right successful -> do
            clusterRoot <- decodeObject (processStdout successful)
            cluster <- requireObjectField "cluster" clusterRoot
            clusterName <- requireTextField "name" cluster
            clusterArn <- requireTextField "arn" cluster
            if clusterName == requestedCluster
              then Right ()
              else Left "EKS describe-cluster returned the wrong cluster identity"
            firstShow
              ( validateEksClusterArnBinding
                  account
                  requestedRegion
                  requestedCluster
                  clusterArn
              )
            Right ("eks-cluster-arn:" <> clusterArn)

exactEksClusterNotFound :: Text -> ProcessOutput -> Bool
exactEksClusterNotFound clusterName output =
  processExitCode output /= ExitSuccess
    && Text.null (Text.strip (Text.pack (processStdout output)))
    && Text.strip (Text.pack (processStderr output))
      == ( "An error occurred (ResourceNotFoundException) when calling the DescribeCluster operation: "
             <> "No cluster found for name: "
             <> clusterName
             <> "."
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
    clusterArn <- requireTextField "arn" cluster
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
            clusterArn
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

-- | Sprint 4.72: the public A record is written through the typed DNS program.
--
-- The superseded body called @changeResourceRecordSets@ directly, so it carried
-- no owner value at all — and until this sprint __@DnsRecordProgram@ had no
-- production caller whatsoever__, which makes the claim it exists to support
-- narrower than it looked: it was exercised only by two unit suites. Routing
-- this writer through it is what makes the program load-bearing for the first
-- time, the same defect shape Sprint @1.82@ closed for the Tier-0 secret guard.
--
-- The coordinate's two non-request facts are __observed rather than asserted__.
-- The AWS account comes from @sts get-caller-identity@ — the account this
-- process is actually acting in — and the ownership epoch from the retained
-- Authority epoch the role already reads. Carrying either in the intent would
-- let a request /claim/ an account; observing them proves one.
applyPublicARecord
  :: ProviderProductionSession -> PublicARecordRef -> IO (Either Text ())
applyPublicARecord session ref = case route53ClientForSession session of
  Left detail -> pure (Left detail)
  Right client -> do
    prepared <- preparePublicARecordProgram session ref
    case prepared of
      Left detail -> pure (Left detail)
      Right (coordinate, values) -> do
        outcome <-
          runDnsRecordProgram
            (publicARecordDnsBoundary client coordinate ref)
            coordinate
            (EnsureDnsRecord providerDnsOwnerAuthority values)
        pure (publicARecordProgramOutcome outcome)

-- | The per-run public A-record authority this role holds.
--
-- @dnsOwnerAuthorityForProcess@ is total over @RuntimeRole \u00d7 Substrate@ and
-- the table decides which lanes the pair holds, so the Provider Worker cannot
-- name a lane it does not own — naming an owner and holding one are different
-- things ("Prodbox.Lifecycle.DnsRecord.Owner").
providerDnsOwnerAuthority :: DnsOwnerAuthority
providerDnsOwnerAuthority = heldDnsOwnerAuthority AwsLifecycleProviderDnsOwner

-- | The long-lived SES authority this role holds.
--
-- Sprint @4.73@: a separate lane rather than a second use of the one above,
-- because an owner decides the lifecycle class and the admissible record types,
-- and the SES records differ from the public A record on both.
sesDnsOwnerAuthority :: DnsOwnerAuthority
sesDnsOwnerAuthority = heldDnsOwnerAuthority AwsSesDnsOwner

heldDnsOwnerAuthority :: DnsRecordOwner -> DnsOwnerAuthority
heldDnsOwnerAuthority owner =
  case dnsOwnerAuthorityForProcess ProviderWorkerRuntime SubstrateAws owner of
    Just authority -> authority
    Nothing ->
      -- Unreachable: the minter's table is written out pair by pair and both
      -- lanes this module names are listed beside this pair. Adding a role or a
      -- substrate is a compile error there, not a silent `Nothing` here.
      error ("the Provider Worker holds no AWS DNS ownership for " <> show owner)

preparePublicARecordProgram
  :: ProviderProductionSession
  -> PublicARecordRef
  -> IO (Either Text (DnsRecordCoordinate, DnsRecordSet))
preparePublicARecordProgram session ref = do
  accountResult <- observeProviderAwsAccountId session
  case accountResult of
    Left detail -> pure (Left detail)
    Right account -> do
      epochResult <- productionSessionAuthorityEpoch session
      pure $ do
        epoch <- epochResult
        zone <- coordinateError (mkHostedZoneId (publicARecordHostedZoneId ref))
        coordinate <-
          coordinateError
            ( mkPublicARecordCoordinate
                account
                zone
                (publicARecordFqdn ref)
                (authorizedDnsOwner providerDnsOwnerAuthority)
                (mkOwnershipEpoch epoch)
            )
        values <- publicARecordValueSet (publicARecordTtl ref) (publicARecordValues ref)
        pure (coordinate, values)

publicARecordValueSet :: Natural -> [Text] -> Either Text DnsRecordSet
publicARecordValueSet ttl rawValues = do
  parsed <- traverse (coordinateError . mkDnsRecordValue DnsRecordA) rawValues
  case NonEmpty.nonEmpty parsed of
    Nothing -> Left "public A record intent carries no address"
    Just values -> coordinateError (mkDnsRecordSet ttl values)

coordinateError :: Either DnsCoordinateError value -> Either Text value
coordinateError = first (Text.pack . show)

-- | The Route 53 side of the program: one exact coordinate, observed and
-- mutated through the same client. @destroy@ is a real delete rather than a
-- refusal, because a boundary whose destroy cannot act would make the program's
-- absence read-back untestable against this lane.
publicARecordDnsBoundary
  :: NativeRoute53.Route53Client
  -> DnsRecordCoordinate
  -> PublicARecordRef
  -> DnsRecordBoundary IO
publicARecordDnsBoundary client coordinate ref =
  DnsRecordBoundary
    { dnsBoundaryCoordinate = coordinate
    , dnsBoundaryObserve = observe
    , dnsBoundaryEnsure = change NativeRoute53.Upsert
    , dnsBoundaryDestroy = change NativeRoute53.DeleteRecord
    }
 where
  zone = publicARecordHostedZoneId ref
  name = publicARecordFqdn ref

  observe = do
    observed <-
      NativeRoute53.listExactResourceRecordSet client zone name NativeRoute53.RecordA
    pure $ case observed of
      Left err -> DnsRecordUnobservable (nativeRoute53Error err)
      Right Nothing -> DnsRecordMissing
      Right (Just record) ->
        case publicARecordValueSet
          (fromIntegral (NativeRoute53.rrsTtl record))
          (NativeRoute53.rrsRecords record) of
          Left detail -> DnsRecordUnobservable detail
          Right values -> DnsRecordObserved values

  -- Sprint 4.73: the wire shape comes from the one shared renderer rather than
  -- a copy assembled here, so the name and type this lane writes are the
  -- coordinate's by construction.
  change action values = do
    changed <-
      NativeRoute53.changeResourceRecordSets
        client
        zone
        [(action, nativeDnsRecordSet coordinate values)]
    case changed of
      Left err -> pure (Left (nativeRoute53Error err))
      Right (changeId, status) -> awaitRoute53Change client changeId status

-- | Every arm is named. A refusal that reached this lane as a bare @Left@ would
-- lose which of the program's five distinct refusals occurred, and two of them
-- — an unauthorized owner and a coordinate mismatch — are the whole point of
-- routing through it.
publicARecordProgramOutcome :: DnsProgramResult -> Either Text ()
publicARecordProgramOutcome result = case result of
  DnsEnsureAlreadyConverged -> Right ()
  DnsEnsureAppliedAndReadBack -> Right ()
  DnsDestroyAlreadyAbsent -> Left "public A record ensure answered a destroy result"
  DnsDestroyAppliedAndReadBack -> Left "public A record ensure answered a destroy result"
  DnsProgramOwnerMismatch expected actual ->
    Left
      ( "public A record coordinate owner mismatch: expected "
          <> Text.pack (show expected)
          <> ", bound to "
          <> Text.pack (show actual)
      )
  DnsProgramOwnerUnauthorized held bound ->
    Left
      ( "this process holds "
          <> Text.pack (show held)
          <> " and the public A record coordinate is owned by "
          <> Text.pack (show bound)
      )
  DnsProgramCoordinateMismatch _ _ ->
    Left "public A record boundary is bound to a different coordinate"
  DnsProgramInitialObservationRefused observation ->
    Left ("public A record is unobservable before mutation: " <> Text.pack (show observation))
  DnsProgramMutationFailed detail _ -> Left detail
  DnsProgramPostconditionFailed observation ->
    Left ("public A record read-back did not converge: " <> Text.pack (show observation))

-- | The AWS account this Provider session is acting in, observed rather than
-- carried. A request that names its own account is an assertion; @sts
-- get-caller-identity@ is evidence.
observeProviderAwsAccountId
  :: ProviderProductionSession -> IO (Either Text AwsAccountId)
observeProviderAwsAccountId session = do
  environment <- awsCliSubprocessEnvironment (productionSessionCredentials session)
  output <- runAws environment ["sts", "get-caller-identity", "--output", "json"]
  pure $ case commandSuccess output of
    Left detail -> Left (Text.pack detail)
    Right _ -> case decodeObject (processStdout output) of
      Left detail -> Left detail
      Right root -> case KeyMap.lookup "Account" root of
        Just (String account) -> coordinateError (mkAwsAccountId account)
        _ -> Left "aws sts get-caller-identity returned no Account field"

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
      case sesDnsRecordPlans session inputs of
        Left detail -> pure (ProviderEffectUnobservable detail)
        Right plans -> observeSesDnsRecords session ref plans

-- | Sprint 4.73: the SES DNS records are written through the typed DNS program,
-- under an owner this process holds.
--
-- Sprint 4.72 routed the public A record the same way and measured why this
-- lane was not the same rerouting. Each of the three reasons is answered here
-- rather than deferred again:
--
--   * It writes three record types where @DnsRecordType@ defined two.
--     @DnsRecordCname@ and @DnsRecordMx@ now exist with their own canonical
--     value forms, and @ownerAcceptsType@ is total over the whole matrix, so
--     the SES lane's admissible types are a decision per pair rather than a
--     wildcard @False@.
--   * It wrote five records in one batched change with one propagation wait. A
--     coordinate is one name and one type, so the program necessarily submits
--     five changes; @ensureSesDnsLanes@ submits them all before awaiting any,
--     which keeps the propagation windows overlapping the way the batch's did.
--   * Its desired values are not known until the SES identity exists.
--     @ensureSesDnsInputs@ therefore still runs first and the coordinates are
--     built from its result, so the program's ensure always begins from a
--     conclusive observation.
applySesDns
  :: ProviderProductionSession
  -> SesDnsRef
  -> IO (Either Text ())
applySesDns session ref = do
  inputsResult <- ensureSesDnsInputs session ref
  case inputsResult >>= sesDnsRecordPlans session of
    Left detail -> pure (Left detail)
    Right plans ->
      case route53ClientForSession session of
        Left detail -> pure (Left detail)
        Right client -> do
          prepared <- prepareSesDnsLanes session ref plans
          case prepared of
            Left detail -> pure (Left detail)
            Right lanes -> ensureSesDnsLanes client (sesDnsHostedZoneId ref) lanes

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

-- | Which of the SES lane's records a plan is.
--
-- A closed sum rather than a rendered record, because the coordinate a lane
-- needs at apply time cannot be recovered from a rendered name: the DKIM lane's
-- coordinate is a function of its token.
data SesDnsLaneKind
  = SesVerificationLane
  | SesDkimLane !Text
  | SesInboundMxLane

data SesDnsRecordPlan = SesDnsRecordPlan
  { sesPlanKind :: !SesDnsLaneKind
  , sesPlanValues :: !DnsRecordSet
  }

-- | The one derivation of what the SES lane's records are.
--
-- The observation that decides whether an apply is needed and the ensure that
-- performs it both consume this, so they cannot disagree about a name, a TTL,
-- or a value — the drift a second renderer would reintroduce
-- (@chaos_hardening_doctrine.md § 23@).
sesDnsRecordPlans
  :: ProviderProductionSession
  -> SesDnsInputs
  -> Either Text [SesDnsRecordPlan]
sesDnsRecordPlans session inputs = do
  providerRegion <-
    if Text.null strippedRegion
      then Left "Provider AWS region is empty while rendering the SES MX target"
      else Right strippedRegion
  verification <-
    plan SesVerificationLane (route53TxtValue (sesDnsVerificationToken inputs))
  dkim <-
    traverse
      (\token -> plan (SesDkimLane token) (token <> ".dkim.amazonses.com."))
      (sesDnsDkimTokens inputs)
  inboundMx <-
    plan
      SesInboundMxLane
      ("10 inbound-smtp." <> providerRegion <> ".amazonaws.com.")
  pure (verification : dkim <> [inboundMx])
 where
  strippedRegion = Text.strip (region (productionSessionCredentials session))
  plan kind rawValue = do
    value <- coordinateError (mkDnsRecordValue (sesLaneRecordType kind) rawValue)
    values <- coordinateError (mkDnsRecordSet sesDnsRecordTtl (value NonEmpty.:| []))
    pure SesDnsRecordPlan {sesPlanKind = kind, sesPlanValues = values}

sesLaneRecordType :: SesDnsLaneKind -> DnsRecordType
sesLaneRecordType kind = case kind of
  SesVerificationLane -> DnsRecordTxt
  SesDkimLane _ -> DnsRecordCname
  SesInboundMxLane -> DnsRecordMx

-- | The record name a lane owns, from the single definition in
-- "Prodbox.Lifecycle.DnsRecord" that the coordinate constructors also use.
sesLaneRecordName :: SesDnsRef -> SesDnsLaneKind -> Either Text Text
sesLaneRecordName ref kind =
  coordinateError $ case kind of
    SesVerificationLane -> sesVerificationRecordName (sesDnsIdentityDomain ref)
    SesDkimLane token -> sesDkimRecordName token (sesDnsIdentityDomain ref)
    SesInboundMxLane -> sesInboundMxRecordName (sesDnsReceiveSubdomain ref)

observeSesDnsRecords
  :: ProviderProductionSession
  -> SesDnsRef
  -> [SesDnsRecordPlan]
  -> IO ProviderEffectObservation
observeSesDnsRecords session ref plans =
  case (route53ClientForSession session, traverse (sesLaneRecordName ref . sesPlanKind) plans) of
    (Left detail, _) -> pure (ProviderEffectUnobservable detail)
    (_, Left detail) -> pure (ProviderEffectUnobservable detail)
    (Right client, Right names) -> go names client (zip names plans)
 where
  go names _ [] =
    pure
      ( ProviderEffectSatisfied
          ( "ses-dns:"
              <> sesDnsHostedZoneId ref
              <> ":"
              <> Text.intercalate "," names
          )
      )
  go names client ((name, expected) : remaining) = do
    observed <-
      NativeRoute53.listExactResourceRecordSet
        client
        (sesDnsHostedZoneId ref)
        name
        (nativeDnsRecordType (sesLaneRecordType (sesPlanKind expected)))
    case observed of
      Left err -> pure (ProviderEffectUnobservable (nativeRoute53Error err))
      Right Nothing ->
        pure (ProviderEffectNeedsApply ("SES DNS record is absent: " <> name))
      Right (Just actual) ->
        case observedDnsRecordSet (sesLaneRecordType (sesPlanKind expected)) actual of
          -- A value the canonical form refuses is not evidence of absence and
          -- not evidence of a match; "cannot observe" stays its own answer.
          Left detail -> pure (ProviderEffectUnobservable detail)
          Right actualValues
            | actualValues == sesPlanValues expected -> go names client remaining
            | otherwise ->
                pure (ProviderEffectNeedsApply ("SES DNS record differs: " <> name))

-- | An observed Route 53 record set in the canonical form the desired set is
-- already in, so the comparison is exact equality rather than a second
-- normalizing comparator that could disagree with the constructor.
observedDnsRecordSet
  :: DnsRecordType
  -> NativeRoute53.ResourceRecordSet
  -> Either Text DnsRecordSet
observedDnsRecordSet recordType observed = do
  parsed <-
    traverse
      (coordinateError . mkDnsRecordValue recordType)
      (NativeRoute53.rrsRecords observed)
  values <-
    maybe
      (Left "Route 53 SES DNS record carried no values")
      Right
      (NonEmpty.nonEmpty parsed)
  recordSet <-
    coordinateError (mkDnsRecordSet (fromIntegral (NativeRoute53.rrsTtl observed)) values)
  -- A set that lost members to deduplication is not the response that was
  -- observed, and comparing the smaller set could report a duplicated record as
  -- converged. The home Gateway DNS observation has made this check since it
  -- was written; the two paths now agree.
  if Set.size (dnsRecordSetValues recordSet) == length (NativeRoute53.rrsRecords observed)
    then Right recordSet
    else Left "Route 53 SES DNS record carried duplicate values"

-- | Lift each plan to an exact coordinate.
--
-- The account and the ownership epoch are observed rather than carried, for the
-- reason Sprint 4.72 gives on the public A-record lane: a request that names
-- its own account is an assertion, and @sts get-caller-identity@ is evidence.
prepareSesDnsLanes
  :: ProviderProductionSession
  -> SesDnsRef
  -> [SesDnsRecordPlan]
  -> IO (Either Text [(DnsRecordCoordinate, DnsRecordSet)])
prepareSesDnsLanes session ref plans = do
  accountResult <- observeProviderAwsAccountId session
  case accountResult of
    Left detail -> pure (Left detail)
    Right account -> do
      epochResult <- productionSessionAuthorityEpoch session
      pure $ do
        epoch <- epochResult
        zone <- coordinateError (mkHostedZoneId (sesDnsHostedZoneId ref))
        traverse (lane account zone (mkOwnershipEpoch epoch)) plans
 where
  lane account zone epoch item = do
    coordinate <-
      coordinateError (sesLaneCoordinate ref account zone epoch (sesPlanKind item))
    pure (coordinate, sesPlanValues item)

sesLaneCoordinate
  :: SesDnsRef
  -> AwsAccountId
  -> HostedZoneId
  -> OwnershipEpoch
  -> SesDnsLaneKind
  -> Either DnsCoordinateError DnsRecordCoordinate
sesLaneCoordinate ref account zone epoch kind = case kind of
  SesVerificationLane ->
    mkSesVerificationCoordinate account zone (sesDnsIdentityDomain ref) owner epoch
  SesDkimLane token ->
    mkSesDkimCoordinate account zone token (sesDnsIdentityDomain ref) owner epoch
  SesInboundMxLane ->
    mkSesInboundMxCoordinate account zone (sesDnsReceiveSubdomain ref) owner epoch
 where
  owner = authorizedDnsOwner sesDnsOwnerAuthority

-- | Ensure every SES lane, then discharge propagation once.
--
-- The superseded body sent all five records in one @changeResourceRecordSets@
-- batch and waited for that single change to reach INSYNC. A coordinate is one
-- name and one type, so the typed program necessarily submits one change per
-- lane — and if each awaited inline, this lane would spend five propagation
-- windows in series where it used to spend one. Submitting first and awaiting
-- afterwards keeps the windows overlapping, which is the property the batch
-- had; what is added is a per-coordinate observation before the write and a
-- read-back after it, neither of which the batch performed at all.
--
-- Deferring the wait does not weaken the read-back.
-- @ListResourceRecordSets@ answers from the hosted zone's record data, which a
-- change updates when it is accepted, while PENDING and INSYNC describe
-- replication to the Route 53 name servers. The post-apply observation this
-- repository already performs reads the same way.
ensureSesDnsLanes
  :: NativeRoute53.Route53Client
  -> Text
  -> [(DnsRecordCoordinate, DnsRecordSet)]
  -> IO (Either Text ())
ensureSesDnsLanes client zone lanes = do
  pending <- newIORef []
  ensured <- ensureEach pending lanes
  case ensured of
    Left detail -> pure (Left detail)
    Right () -> readIORef pending >>= awaitPending
 where
  ensureEach _ [] = pure (Right ())
  ensureEach pending ((coordinate, values) : remaining) = do
    outcome <-
      runDnsRecordProgram
        (sesDnsRecordBoundary client zone pending coordinate)
        coordinate
        (EnsureDnsRecord sesDnsOwnerAuthority values)
    case sesDnsProgramOutcome coordinate outcome of
      Left detail -> pure (Left detail)
      Right () -> ensureEach pending remaining

  awaitPending [] = pure (Right ())
  awaitPending (changeId : remaining) = do
    completed <- awaitRoute53Change client changeId NativeRoute53.ChangePending
    case completed of
      Left detail -> pure (Left detail)
      Right () -> awaitPending remaining

sesDnsRecordBoundary
  :: NativeRoute53.Route53Client
  -> Text
  -> IORef [NativeRoute53.ChangeId]
  -> DnsRecordCoordinate
  -> DnsRecordBoundary IO
sesDnsRecordBoundary client zone pending coordinate =
  DnsRecordBoundary
    { dnsBoundaryCoordinate = coordinate
    , dnsBoundaryObserve = observe
    , dnsBoundaryEnsure = submit NativeRoute53.Upsert
    , dnsBoundaryDestroy = submit NativeRoute53.DeleteRecord
    }
 where
  observe = do
    observed <-
      NativeRoute53.listExactResourceRecordSet
        client
        zone
        (dnsCoordinateName coordinate)
        (nativeDnsRecordType (dnsCoordinateType coordinate))
    pure $ case observed of
      Left err -> DnsRecordUnobservable (nativeRoute53Error err)
      Right Nothing -> DnsRecordMissing
      Right (Just record) ->
        case observedDnsRecordSet (dnsCoordinateType coordinate) record of
          Left detail -> DnsRecordUnobservable detail
          Right values -> DnsRecordObserved values

  submit action values = do
    changed <-
      NativeRoute53.changeResourceRecordSets
        client
        zone
        [(action, nativeDnsRecordSet coordinate values)]
    case changed of
      Left err -> pure (Left (nativeRoute53Error err))
      Right (_, NativeRoute53.ChangeInsync) -> pure (Right ())
      Right (changeId, NativeRoute53.ChangePending) -> do
        modifyIORef' pending (changeId :)
        pure (Right ())

-- | Every arm is named, and each names the coordinate it refused.
--
-- Five lanes run in sequence, so a bare @Left@ would lose both which refusal
-- occurred and which record provoked it.
sesDnsProgramOutcome :: DnsRecordCoordinate -> DnsProgramResult -> Either Text ()
sesDnsProgramOutcome coordinate result = case result of
  DnsEnsureAlreadyConverged -> Right ()
  DnsEnsureAppliedAndReadBack -> Right ()
  DnsDestroyAlreadyAbsent -> refused "ensure answered a destroy result"
  DnsDestroyAppliedAndReadBack -> refused "ensure answered a destroy result"
  DnsProgramOwnerMismatch expected actual ->
    refused
      ( "coordinate owner mismatch: expected "
          <> Text.pack (show expected)
          <> ", bound to "
          <> Text.pack (show actual)
      )
  DnsProgramOwnerUnauthorized held bound ->
    refused
      ( "this process holds "
          <> Text.pack (show held)
          <> " and the coordinate is owned by "
          <> Text.pack (show bound)
      )
  DnsProgramCoordinateMismatch _ _ ->
    refused "boundary is bound to a different coordinate"
  DnsProgramInitialObservationRefused observation ->
    refused ("unobservable before mutation: " <> Text.pack (show observation))
  DnsProgramMutationFailed detail _ -> refused detail
  DnsProgramPostconditionFailed observation ->
    refused ("read-back did not converge: " <> Text.pack (show observation))
 where
  refused detail =
    Left ("SES DNS record " <> dnsCoordinateName coordinate <> ": " <> detail)

route53ClientForSession
  :: ProviderProductionSession
  -> Either Text NativeRoute53.Route53Client
route53ClientForSession session =
  case baseCredentialHandleFromSettings (productionSessionCredentials session) of
    Left err -> Left ("Provider AWS credential is invalid: " <> Text.pack (show err))
    Right handle -> Right (NativeRoute53.newRoute53Client handle httpSend)

awaitRoute53Change
  :: NativeRoute53.Route53Client
  -> NativeRoute53.ChangeId
  -> NativeRoute53.ChangeStatus
  -> IO (Either Text ())
awaitRoute53Change _ _ NativeRoute53.ChangeInsync = pure (Right ())
awaitRoute53Change client changeId NativeRoute53.ChangePending = do
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

route53TxtValue :: Text -> Text
route53TxtValue value = "\"" <> value <> "\""

nativeRoute53Error :: (Show errorValue) => errorValue -> Text
nativeRoute53Error = ("Route 53 SES DNS request failed: " <>) . Text.pack . show

sesDnsRecordTtl :: Natural
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
