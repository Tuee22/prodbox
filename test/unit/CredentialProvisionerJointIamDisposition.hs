{-# LANGUAGE OverloadedStrings #-}

module CredentialProvisionerJointIamDisposition
  ( credentialProvisionerJointIamDispositionSuite
  )
where

import Data.Functor.Identity (Identity (Identity), runIdentity)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Prodbox.Infra.AwsSesDecommission
  ( awsSesSmtpJointAuthorization
  , deleteInlinePolicyArguments
  , listInlinePolicyArguments
  , observeAwsSesSmtpIamWith
  , parseSmtpInlinePolicyNames
  )
import Prodbox.Lifecycle.CredentialProvisioner.JointIamDisposition
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass (..)
  , awsCredentialDescriptor
  , awsCredentialDescriptorPolicy
  , awsCredentialDescriptorPrincipal
  )
import Prodbox.Lifecycle.ResidueStatus
  ( ResidueStatus (ResidueAbsent, ResiduePresent, ResidueUnreachable)
  )
import Prodbox.Result (Result (Success))
import Prodbox.Subprocess (ProcessOutput (..), Subprocess (..))
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import TestSupport

credentialProvisionerJointIamDispositionSuite :: SuiteBuilder ()
credentialProvisionerJointIamDispositionSuite =
  describe "Sprint 7.36 joint IAM family disposition" $ do
    it "derives the principal and policy name from the registered descriptor" $ do
      -- An authored coordinate is how the two halves of a lifecycle stop naming
      -- the same object, which is exactly what happened: the SMTP destroy named
      -- a policy the descriptor does not declare.
      jointIamDispositionPrincipal sesAuthorization
        `shouldBe` awsCredentialDescriptorPrincipal
          (awsCredentialDescriptor SesSmtpRetainedCustodyCredential)
      jointIamDispositionPolicyName sesAuthorization
        `shouldBe` awsCredentialDescriptorPolicy
          (awsCredentialDescriptor SesSmtpRetainedCustodyCredential)
      jointIamDispositionPolicyName sesAuthorization
        `shouldNotBe` "prodbox-ses-smtp-policy"

    it "covers role members only for a class that owns a role" $ do
      jointIamDispositionFamily sesAuthorization
        `shouldBe` [IamAccessKeyFamily, IamInlinePolicyFamily, IamPrincipal]
      jointIamDispositionFamily providerAuthorization
        `shouldBe` [ IamAccessKeyFamily
                   , IamInlinePolicyFamily
                   , IamPrincipal
                   , IamAssumedRoleInlinePolicy
                   , IamAssumedRole
                   ]
      -- The order is the family, so a member added to one cannot be omitted
      -- from the other.
      jointIamDispositionOrder providerAuthorization
        `shouldBe` jointIamDispositionFamily providerAuthorization

    it "completes only when every member is independently absent" $ do
      fmap
        jointIamDispositionCompleteAuthorization
        (disposeJointIamFamily sesAuthorization (allAbsent sesAuthorization))
        `shouldBe` Right sesAuthorization

    it "names every surviving member rather than the first" $ do
      -- The surviving set is what a retry resumes from, so reporting one member
      -- and abandoning the rest is the defect, not the report.
      disposeJointIamFamily
        sesAuthorization
        [ (IamAccessKeyFamily, IamMemberAbsent)
        , (IamInlinePolicyFamily, IamMemberPresent)
        , (IamPrincipal, IamMemberPresent)
        ]
        `shouldBe` Left
          (JointIamMemberStillPresent (IamInlinePolicyFamily :| [IamPrincipal]))

    it "refuses a member nothing answered for" $ do
      -- A silent member is not an absent one.
      disposeJointIamFamily
        sesAuthorization
        [ (IamAccessKeyFamily, IamMemberAbsent)
        , (IamPrincipal, IamMemberAbsent)
        ]
        `shouldBe` Left (JointIamMemberUnobserved (IamInlinePolicyFamily :| []))

    it "refuses a foreign member and a duplicated one" $ do
      disposeJointIamFamily
        sesAuthorization
        (allAbsent sesAuthorization ++ [(IamAssumedRole, IamMemberAbsent)])
        `shouldBe` Left (JointIamMemberForeign (IamAssumedRole :| []))
      disposeJointIamFamily
        sesAuthorization
        (allAbsent sesAuthorization ++ [(IamPrincipal, IamMemberAbsent)])
        `shouldBe` Left (JointIamMemberForeign (IamPrincipal :| []))

    it "keeps unobservable distinct from surviving" $ do
      -- They license different next steps: fix the read-back, or retry the
      -- destroy.
      disposeJointIamFamily
        sesAuthorization
        [ (IamAccessKeyFamily, IamMemberAbsent)
        , (IamInlinePolicyFamily, IamMemberUnobservable "listing refused")
        , (IamPrincipal, IamMemberAbsent)
        ]
        `shouldBe` Left
          (JointIamMemberUnobservable ((IamInlinePolicyFamily, "listing refused") :| []))

    it "digests two families distinctly" $ do
      fmap jointIamDispositionDigest (complete sesAuthorization)
        `shouldNotBe` fmap jointIamDispositionDigest (complete providerAuthorization)
      fmap jointIamDispositionDigest (complete providerAuthorization)
        `shouldNotBe` fmap jointIamDispositionDigest (complete otherRoleAuthorization)

    it "deletes the inline policy IAM reports rather than an authored name" $ do
      deleteInlinePolicyArguments "whatever-the-creator-wrote"
        `shouldContain` ["whatever-the-creator-wrote"]
      listInlinePolicyArguments `shouldContain` ["list-user-policies"]

    it "reads an inline-policy listing and refuses a truncated one" $ do
      parseSmtpInlinePolicyNames policyListingPayload
        `shouldBe` Right ["prodbox-ses-smtp-send"]
      parseSmtpInlinePolicyNames truncatedPolicyListingPayload
        `shouldSatisfy` isLeftResult
      parseSmtpInlinePolicyNames "{}" `shouldSatisfy` isLeftResult
      parseSmtpInlinePolicyNames "[]" `shouldSatisfy` isLeftResult

    it "reports the SMTP family absent only when every member is" $ do
      -- The old read-back asked only whether the principal was there. This is
      -- the live residue the sprint exists to make unreachable: no principal,
      -- no keys, but an inline policy still attached.
      runIdentity (observeAwsSesSmtpIamWith (fakeAws absentFamily) "." [])
        `shouldBe` ResidueAbsent
      runIdentity (observeAwsSesSmtpIamWith (fakeAws strandedPolicy) "." [])
        `shouldSatisfy` isPresentResidue
      runIdentity (observeAwsSesSmtpIamWith (fakeAws unobservablePolicies) "." [])
        `shouldSatisfy` isUnreachableResidue

sesAuthorization :: JointIamDispositionAuthorization
sesAuthorization = mustRight awsSesSmtpJointAuthorization

providerAuthorization :: JointIamDispositionAuthorization
providerAuthorization =
  mustRight
    ( mkJointIamDispositionAuthorization
        LifecycleProviderCredential
        (Just "prodbox-lifecycle-provider-role")
    )

otherRoleAuthorization :: JointIamDispositionAuthorization
otherRoleAuthorization =
  mustRight
    ( mkJointIamDispositionAuthorization
        LifecycleProviderCredential
        (Just "prodbox-lifecycle-provider-role-two")
    )

allAbsent
  :: JointIamDispositionAuthorization -> [(IamFamilyMember, IamMemberObservation)]
allAbsent authorization =
  [(member, IamMemberAbsent) | member <- jointIamDispositionFamily authorization]

complete
  :: JointIamDispositionAuthorization
  -> Either JointIamDispositionRefusal JointIamDispositionComplete
complete authorization =
  disposeJointIamFamily authorization (allAbsent authorization)

policyListingPayload :: String
policyListingPayload =
  "{\"PolicyNames\":[\"prodbox-ses-smtp-send\"],\"IsTruncated\":false}"

truncatedPolicyListingPayload :: String
truncatedPolicyListingPayload =
  "{\"PolicyNames\":[\"prodbox-ses-smtp-send\"],\"IsTruncated\":true}"

-- | A fake @aws@ boundary keyed on the subcommand the caller issued.
fakeAws
  :: (String -> ProcessOutput) -> Subprocess -> Identity (Result ProcessOutput)
fakeAws respond subprocess =
  Identity (Success (respond (subcommand (subprocessArguments subprocess))))
 where
  subcommand arguments = case arguments of
    _ : command : _ -> command
    _ -> ""

noSuchEntity :: ProcessOutput
noSuchEntity =
  ProcessOutput
    { processExitCode = ExitFailure 254
    , processStdout = ""
    , processStderr =
        "An error occurred (NoSuchEntity) when calling the operation: \
        \The user with name prodbox-ses-smtp cannot be found."
    }

absentFamily :: String -> ProcessOutput
absentFamily = const noSuchEntity

-- | No principal, no keys, and an inline policy still attached.
strandedPolicy :: String -> ProcessOutput
strandedPolicy command = case command of
  "list-user-policies" ->
    ProcessOutput
      { processExitCode = ExitSuccess
      , processStdout = policyListingPayload
      , processStderr = ""
      }
  _ -> noSuchEntity

unobservablePolicies :: String -> ProcessOutput
unobservablePolicies command = case command of
  "list-user-policies" ->
    ProcessOutput
      { processExitCode = ExitFailure 254
      , processStdout = ""
      , processStderr =
          "An error occurred (AccessDenied) when calling the ListUserPolicies operation"
      }
  _ -> noSuchEntity

isPresentResidue :: ResidueStatus -> Bool
isPresentResidue status = case status of
  ResiduePresent _ -> True
  _ -> False

isUnreachableResidue :: ResidueStatus -> Bool
isUnreachableResidue status = case status of
  ResidueUnreachable _ -> True
  _ -> False

isLeftResult :: Either left right -> Bool
isLeftResult result = case result of
  Left _ -> True
  Right _ -> False

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Right value -> value
  Left err -> error ("expected Right, got " <> show err)
