{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 8.13: the retained SES SMTP family is requested by the harness, for
-- the suites that send an invite, and for no other suite.
--
-- The retained SES preparation dispatches only the five non-credential Provider
-- intents, and nothing submitted the Credential Provisioner permit that creates
-- the SMTP identity and delivers it to @secret/keycloak/smtp@. The first live
-- @keycloak-invite@ run of the 2026-10-08 campaign therefore reached Keycloak
-- with no SMTP server configured and failed when Keycloak tried to send. These
-- cases pin the request the harness builds and which suites build it; the
-- Provisioner, the custody and the delivery are exercised by their own suites.
module HarnessSesSmtp (harnessSesSmtpSuite) where

import Data.Either (isLeft)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.CLI.Command
  ( IntegrationSuite (..)
  , TestScope (..)
  )
import Prodbox.CLI.Rke2
  ( HarnessCredentialRequest (..)
  , harnessRetainedIntentIsLive
  , resolveHarnessCredentialIntent
  , sesSmtpCredentialRequest
  )
import Prodbox.ControlPlane.AuthorityBackupReconcileProduction
  ( GenesisAwsAdminIntentParameters (..)
  , compileNormalAwsAdminIntentForScope
  )
import Prodbox.ControlPlane.AwsAdminProvisionerClient
  ( AwsAdminProvisionerClient
  , AwsAdminProvisionerClientError (..)
  , mkAwsAdminProvisionerClient
  )
import Prodbox.ControlPlane.AwsAdminProvisionerEndpoint
  ( AwsAdminProvisionerChallenge (..)
  , AwsAdminProvisionerObservation (..)
  , AwsAdminProvisionerPhase (..)
  , AwsAdminProvisionerRequest (..)
  , AwsAdminProvisionerResponse (..)
  )
import Prodbox.ControlPlane.TargetMaterialRegistry (TargetSecretId (TargetSesSmtp))
import Prodbox.ControlPlane.TargetSecretAgentExecution (mkTargetAgentIdentity)
import Prodbox.Lifecycle.CredentialProvisioner.AwsAdminPermit
  ( AwsAdminPermitIntent
  , awsAdminPermitIntentAction
  , awsAdminPermitIntentDeadline
  , awsAdminPermitIntentGeneration
  , awsAdminPermitIntentOperationId
  , awsAdminPermitIntentPermitId
  , credentialIamParametersClass
  , credentialIamParametersRegion
  , credentialIamParametersSesIdentity
  , encodeAwsAdminPermitIntent
  , mkAuthorityBackupIamParameters
  )
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass (SesSmtpRetainedCustodyCredential)
  , OperatorMaterialAction (InstallOperatorMaterial)
  )
import Prodbox.Lifecycle.Lease (authorityTimeFromMicros)
import Prodbox.Substrate (Substrate (..))
import Prodbox.TestPlan
  ( NativeSuitePlan
  , TestExecutionMode (..)
  , TestExecutionPlan (..)
  , testExecutionPlan
  )
import Prodbox.TestRunner
  ( harnessSesSmtpApplies
  , harnessSesSmtpOperationScope
  )
import TestSupport

-- | The plan a named integration suite runs under, on one substrate.
suitePlanFor :: Substrate -> TestScope -> Maybe NativeSuitePlan
suitePlanFor substrate command =
  case testPlanExecutionMode (testExecutionPlan substrate command) of
    NativeSuite suitePlan -> Just suitePlan
    DelegatedSuite _ -> Nothing

appliesTo :: Substrate -> TestScope -> Maybe Bool
appliesTo substrate command = harnessSesSmtpApplies <$> suitePlanFor substrate command

harnessSesSmtpSuite :: SuiteBuilder ()
harnessSesSmtpSuite = do
  harnessSesSmtpRequestSuite
  harnessRetainedOperationSuite

harnessSesSmtpRequestSuite :: SuiteBuilder ()
harnessSesSmtpRequestSuite =
  describe "Sprint 8.13 the harness installs the retained SES SMTP family for invite suites" $ do
    it "requests the retained-custody class, delivered to the SMTP Target Secret, in the stable scope" $ do
      case sesSmtpCredentialRequest harnessSesSmtpOperationScope region account identity of
        Left detail -> expectationFailure (show detail)
        Right request -> do
          harnessCredentialClass request `shouldBe` SesSmtpRetainedCustodyCredential
          harnessCredentialTarget request `shouldBe` TargetSesSmtp
          harnessCredentialScope request `shouldBe` harnessSesSmtpOperationScope
          credentialIamParametersClass (harnessCredentialIamParameters request)
            `shouldBe` SesSmtpRetainedCustodyCredential
          credentialIamParametersRegion (harnessCredentialIamParameters request) `shouldBe` region
          credentialIamParametersSesIdentity (harnessCredentialIamParameters request)
            `shouldBe` Just identity

    it "strips the configured sending identity and refuses one the IAM program does not accept" $ do
      fmap
        (credentialIamParametersSesIdentity . harnessCredentialIamParameters)
        (sesSmtpCredentialRequest harnessSesSmtpOperationScope region account ("  " <> identity <> "\n"))
        `shouldBe` Right (Just identity)
      sesSmtpCredentialRequest harnessSesSmtpOperationScope region account ""
        `shouldSatisfy` isLeft
      sesSmtpCredentialRequest harnessSesSmtpOperationScope region account "Mixed.Case.Example.Test"
        `shouldSatisfy` isLeft
      sesSmtpCredentialRequest harnessSesSmtpOperationScope region account "bad_label.example.test"
        `shouldSatisfy` isLeft

    it "refuses an account that is not twelve digits and a region the policy cannot name" $ do
      sesSmtpCredentialRequest harnessSesSmtpOperationScope region "12345" identity
        `shouldSatisfy` isLeft
      sesSmtpCredentialRequest harnessSesSmtpOperationScope "US West 2" account identity
        `shouldSatisfy` isLeft

    it "uses one scope for every suite, so a rerun finds the completed operation" $
      harnessSesSmtpOperationScope `shouldBe` "test-harness:retained-ses-smtp:r2"

    it "applies to the home suites that send an invite and to no other suite" $ do
      appliesTo SubstrateHomeLocal (TestIntegration IntegrationKeycloakInvite) `shouldBe` Just True
      appliesTo SubstrateHomeLocal TestAll `shouldBe` Just True
      appliesTo SubstrateHomeLocal (TestIntegration IntegrationAll) `shouldBe` Just True
      mapM_
        ( \target ->
            appliesTo SubstrateHomeLocal (TestIntegration target) `shouldBe` Just False
        )
        [ IntegrationAwsIam
        , IntegrationDnsAws
        , IntegrationPublicDns
        , IntegrationChartsVscode
        , IntegrationSealedVault
        ]

    it "leaves the AWS substrate's own sink to Sprint 7.47" $ do
      appliesTo SubstrateAws (TestIntegration IntegrationKeycloakInvite) `shouldBe` Just False
      appliesTo SubstrateAws TestAll `shouldBe` Just False
 where
  region = fixtureAwsRegion FixtureUsWest2
  account = "123456789012"
  identity = "mail.example.test"

-- | Sprint 5.54: the Authority admits an unfinished operation only for
-- byte-identical intent until its deadline and for a replacement draft after it,
-- and a completed one only for the intent it completed. The harness resubmitted
-- whatever intent the Authority retained, so an operation left unfinished by a
-- worker refusal could never be retried past its thirty-minute window: the
-- 2026-10-12 @keycloak-invite@ run, after the IAM tag read-back refused the SMTP
-- user, was answered @prepared-target/deadline-expired@ by the Authority for the
-- intent the harness had itself submitted two hours earlier.
harnessRetainedOperationSuite :: SuiteBuilder ()
harnessRetainedOperationSuite =
  describe
    "Sprint 5.54 a harness credential whose retained operation expired is replaced, not resubmitted"
    $ do
      it "resubmits a completed operation always, and an unfinished one only while its deadline is ahead" $ do
        let live = harnessRetainedIntentIsLive 1000
        live AwsAdminProvisionerCompleted (retainedIntentExpiring 1) `shouldBe` True
        live AwsAdminProvisionerCompleted (retainedIntentExpiring 5000) `shouldBe` True
        mapM_
          ( \phase -> do
              live phase (retainedIntentExpiring 1001) `shouldBe` True
              -- The Authority treats a deadline equal to its clock as passed.
              live phase (retainedIntentExpiring 1000) `shouldBe` False
              live phase (retainedIntentExpiring 999) `shouldBe` False
          )
          unfinishedPhases

      it "submits the retained intent unchanged when the operation completed or can still be resumed" $ do
        let retained = retainedIntentExpiring 5000
        mapM_
          ( \(phase, now) -> do
              resolved <-
                resolveHarnessCredentialIntent
                  (clientObserving phase retained)
                  (parametersExpiring 90000)
                  smtpRequest
                  Nothing
                  now
              resolved `shouldBe` Right retained
          )
          [ (AwsAdminProvisionerCompleted, 7000)
          , (AwsAdminProvisionerAuthorized, 4000)
          , (AwsAdminProvisionerPrepared, 4999)
          ]

      it
        "replaces an unfinished operation whose deadline passed with the draft a first request would send"
        $ do
          let retained = retainedIntentExpiring 5000
          mapM_
            ( \phase -> do
                resolved <-
                  resolveHarnessCredentialIntent
                    (clientObserving phase retained)
                    (parametersExpiring 90000)
                    smtpRequest
                    Nothing
                    7000
                resolved `shouldBe` Right (retainedIntentExpiring 90000)
                -- Every immutable binding the Authority compares is the retained one;
                -- only the deadline moves, and it moves past the clock.
                fmap awsAdminPermitIntentOperationId resolved
                  `shouldBe` Right (awsAdminPermitIntentOperationId retained)
                fmap awsAdminPermitIntentPermitId resolved
                  `shouldBe` Right (awsAdminPermitIntentPermitId retained)
                fmap awsAdminPermitIntentGeneration resolved
                  `shouldBe` Right (awsAdminPermitIntentGeneration retained)
                fmap awsAdminPermitIntentAction resolved
                  `shouldBe` Right (awsAdminPermitIntentAction retained)
                fmap awsAdminPermitIntentDeadline resolved
                  `shouldBe` Right (authorityTimeFromMicros 90000)
            )
            unfinishedPhases

      it "compiles the first draft when the Authority holds no such operation" $ do
        resolved <-
          resolveHarnessCredentialIntent
            clientWithoutOperation
            (parametersExpiring 90000)
            smtpRequest
            Nothing
            7000
        resolved `shouldBe` Right (retainedIntentExpiring 90000)

      it "still refuses a retained operation that names another Target generation, expired or not" $ do
        let otherGeneration = retainedIntentGenerationExpiring 2 5000
        mapM_
          ( \now -> do
              resolved <-
                resolveHarnessCredentialIntent
                  (clientObserving AwsAdminProvisionerAuthorized otherGeneration)
                  (parametersExpiring 90000)
                  smtpRequest
                  Nothing
                  now
              resolved `shouldSatisfy` isLeft
          )
          [4000, 7000]

unfinishedPhases :: [AwsAdminProvisionerPhase]
unfinishedPhases =
  [ AwsAdminProvisionerPrepared
  , AwsAdminProvisionerAttested
  , AwsAdminProvisionerAuthorized
  ]

smtpRequest :: HarnessCredentialRequest
smtpRequest =
  either
    (error . Text.unpack)
    id
    ( sesSmtpCredentialRequest
        harnessSesSmtpOperationScope
        (fixtureAwsRegion FixtureUsWest2)
        "123456789012"
        "mail.example.test"
    )

parametersExpiring :: Natural -> GenesisAwsAdminIntentParameters
parametersExpiring deadline =
  GenesisAwsAdminIntentParameters
    { genesisIntentIamParameters =
        mustRightValue
          ( mkAuthorityBackupIamParameters
              (fixtureAwsRegion FixtureUsWest2)
              "prodbox-retained"
              ["authority-backup-store/home"]
          )
    , genesisIntentImageDigest = "sha256:" <> Text.replicate 64 "a"
    , genesisIntentAuthorityScope = "home"
    , genesisIntentAuthorityEndpoint =
        "http://lifecycle-authority.lifecycle-authority.svc:8600"
    , genesisIntentSelectedAgent =
        mustRightValue
          (mkTargetAgentIdentity ("home@sha256:" <> Text.replicate 64 "b"))
    , genesisIntentDeadline = authorityTimeFromMicros deadline
    }

-- | The intent the Authority retained for the harness's first SMTP request, with
-- the given deadline: exactly what a first request compiles.
retainedIntentExpiring :: Natural -> AwsAdminPermitIntent
retainedIntentExpiring = retainedIntentGenerationExpiring 1

retainedIntentGenerationExpiring :: Natural -> Natural -> AwsAdminPermitIntent
retainedIntentGenerationExpiring generation deadline =
  mustRightValue
    ( compileNormalAwsAdminIntentForScope
        (parametersExpiring deadline)
        (harnessCredentialScope smtpRequest)
        (harnessCredentialClass smtpRequest)
        InstallOperatorMaterial
        generation
        (harnessCredentialIamParameters smtpRequest)
    )

-- | An Authority that answers every observation with the one retained intent in
-- the given phase. Only the canonical intent and the phase are read.
clientObserving
  :: AwsAdminProvisionerPhase -> AwsAdminPermitIntent -> AwsAdminProvisionerClient IO
clientObserving phase retained =
  mkAwsAdminProvisionerClient $ \call -> pure $ case call of
    ObserveAwsAdminProvisioning _ ->
      Right
        ( AwsAdminProvisioningObserved
            AwsAdminProvisionerObservation
              { awsAdminObservedChallenge = challenge
              , awsAdminObservedPhase = phase
              , awsAdminObservedPermit = Nothing
              , awsAdminObservedReceipt = Nothing
              }
        )
    _ -> Left AwsAdminProvisionerClientUnexpectedResponse
 where
  challenge =
    AwsAdminProvisionerChallenge
      { awsAdminChallengeOperationId = "operation"
      , awsAdminChallengePermitId = "permit"
      , awsAdminChallengeRequestDigest = "digest"
      , awsAdminChallengeGeneration = 1
      , awsAdminChallengeTarget = TargetSesSmtp
      , awsAdminChallengeJobName = "job"
      , awsAdminChallengeImageDigest = "sha256:" <> Text.replicate 64 "a"
      , awsAdminChallengeServiceAccount = "account"
      , awsAdminChallengeAuthorityScope = "home"
      , awsAdminChallengeAuthorityEndpoint = "endpoint"
      , awsAdminChallengeDeadlineMicros = 0
      , awsAdminChallengeCanonicalIntent = encodeAwsAdminPermitIntent retained
      }

clientWithoutOperation :: AwsAdminProvisionerClient IO
clientWithoutOperation =
  mkAwsAdminProvisionerClient $ \_ ->
    pure (Left (AwsAdminProvisionerClientRefused "operation-not-found"))

mustRightValue :: (Show err) => Either err value -> value
mustRightValue = either (error . show) id
