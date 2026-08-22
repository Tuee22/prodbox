{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 7.36: destroying one managed AWS identity is a single disposition
-- over its whole family, not a sequence of independent deletes.
--
-- The observed live state this module exists to make unreachable is a retained
-- SMTP principal present with zero access keys and an inline policy still
-- attached.  Two independent defects produced it, and both are the same shape.
--
--   * __The destroy short-circuited.__  Keys, then policy, then principal ran
--     inside one abandoning sequence, so a failure at any step left the
--     remainder unattempted and reported the whole disposition as failed
--     without saying which members survived.
--   * __The destroy named a policy the creator never wrote.__  The inline
--     policy was addressed by an authored constant while the registered
--     credential descriptor declares a different one, so the delete removed
--     nothing and the principal delete could then never succeed — IAM refuses
--     to delete a principal that still owns an inline policy.
--
-- Both are answered by the same rule: the family is enumerated from the
-- provider rather than authored, every member is attempted, and completion is
-- minted only from a read-back in which every member is independently absent.
-- A partial destroy therefore has no way to produce a completion value; it
-- produces a refusal naming exactly what survived, which is also what a retry
-- resumes from.
module Prodbox.Lifecycle.CredentialProvisioner.JointIamDisposition
  ( -- * The family
    IamFamilyMember (..)
  , iamFamilyMemberText

    -- * Authorization
  , JointIamDispositionAuthorization
  , mkJointIamDispositionAuthorization
  , jointIamDispositionClass
  , jointIamDispositionPrincipal
  , jointIamDispositionPolicyName
  , jointIamDispositionRole
  , jointIamDispositionFamily
  , jointIamDispositionOrder
  , JointIamDispositionError (..)

    -- * Observation and completion
  , IamMemberObservation (..)
  , JointIamDispositionRefusal (..)
  , renderJointIamDispositionRefusal
  , JointIamDispositionComplete
  , jointIamDispositionCompleteAuthorization
  , jointIamDispositionDigest
  , disposeJointIamFamily
  )
where

import Data.List (nub, sort)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass
  , awsCredentialDescriptor
  , awsCredentialDescriptorPolicy
  , awsCredentialDescriptorPrincipal
  )

-- | The closed set of IAM objects one managed credential class owns.
--
-- The inline-policy member is the principal's whole inline-policy set rather
-- than one named policy, because the name is exactly what drifted: a destroy
-- addressed by an authored name deletes nothing when the creator wrote another,
-- and IAM's own refusal to delete a principal that still owns a policy turns
-- that into a permanently stuck principal.
data IamFamilyMember
  = IamAccessKeyFamily
  | IamInlinePolicyFamily
  | IamPrincipal
  | IamAssumedRoleInlinePolicy
  | IamAssumedRole
  deriving (Bounded, Enum, Eq, Ord, Show)

iamFamilyMemberText :: IamFamilyMember -> Text
iamFamilyMemberText = \case
  IamAccessKeyFamily -> "access-key-family"
  IamInlinePolicyFamily -> "inline-policy-family"
  IamPrincipal -> "principal"
  IamAssumedRoleInlinePolicy -> "assumed-role-inline-policy"
  IamAssumedRole -> "assumed-role"

-- | The joint authorization to dispose of one credential class's whole IAM
-- family.
--
-- Opaque, and its principal and declared policy name are /derived/ from the
-- registered credential descriptor rather than accepted from the caller: an
-- authored coordinate is how the two halves of a lifecycle stop naming the same
-- object.
data JointIamDispositionAuthorization = JointIamDispositionAuthorization
  { internalJointIamClass :: !AwsCredentialClass
  , internalJointIamPrincipal :: !Text
  , internalJointIamPolicyName :: !Text
  , internalJointIamRole :: !(Maybe Text)
  }
  deriving (Eq, Show)

data JointIamDispositionError
  = JointIamPrincipalMissing !AwsCredentialClass
  | JointIamPolicyNameMissing !AwsCredentialClass
  | JointIamRoleNameEmpty
  deriving (Eq, Show)

mkJointIamDispositionAuthorization
  :: AwsCredentialClass
  -> Maybe Text
  -- ^ the assumed role this class owns, when it owns one
  -> Either JointIamDispositionError JointIamDispositionAuthorization
mkJointIamDispositionAuthorization credentialClass role = do
  let descriptor = awsCredentialDescriptor credentialClass
      principal = awsCredentialDescriptorPrincipal descriptor
      policyName = awsCredentialDescriptorPolicy descriptor
  if Text.null principal
    then Left (JointIamPrincipalMissing credentialClass)
    else Right ()
  if Text.null policyName
    then Left (JointIamPolicyNameMissing credentialClass)
    else Right ()
  case role of
    Just value | Text.null value -> Left JointIamRoleNameEmpty
    _ -> Right ()
  Right
    JointIamDispositionAuthorization
      { internalJointIamClass = credentialClass
      , internalJointIamPrincipal = principal
      , internalJointIamPolicyName = policyName
      , internalJointIamRole = role
      }

jointIamDispositionClass :: JointIamDispositionAuthorization -> AwsCredentialClass
jointIamDispositionClass = internalJointIamClass

jointIamDispositionPrincipal :: JointIamDispositionAuthorization -> Text
jointIamDispositionPrincipal = internalJointIamPrincipal

-- | The inline policy name the /creator/ writes, derived from the registered
-- descriptor.
--
-- The destroy does not address the family by this name — it enumerates — but
-- the name still belongs to the authorization, because a creator and a
-- destroyer that disagree about it is the defect this module records.
jointIamDispositionPolicyName :: JointIamDispositionAuthorization -> Text
jointIamDispositionPolicyName = internalJointIamPolicyName

jointIamDispositionRole :: JointIamDispositionAuthorization -> Maybe Text
jointIamDispositionRole = internalJointIamRole

-- | The members this authorization covers.  A class owning no assumed role has
-- no role members, so a read-back for one is foreign rather than missing.
jointIamDispositionFamily :: JointIamDispositionAuthorization -> [IamFamilyMember]
jointIamDispositionFamily authorization =
  [ member
  | member <- [minBound .. maxBound]
  , roleMemberAdmitted member
  ]
 where
  roleMemberAdmitted member = case member of
    IamAssumedRoleInlinePolicy -> hasRole
    IamAssumedRole -> hasRole
    _ -> True
  hasRole = case internalJointIamRole authorization of
    Nothing -> False
    Just _ -> True

-- | The order the members must be attempted in.
--
-- It is forced rather than chosen: IAM refuses to delete a principal that still
-- owns access keys or an inline policy, and a role that still owns one, so the
-- dependent members precede their owner.  It is derived from the family, so a
-- member added to the family cannot be omitted from the order.
jointIamDispositionOrder :: JointIamDispositionAuthorization -> [IamFamilyMember]
jointIamDispositionOrder = jointIamDispositionFamily

-- | What an exact-coordinate read-back found for one member.
--
-- Unobservable is not absence and is not presence: it is the third answer the
-- whole lifecycle turns on, and it refuses distinctly below.
data IamMemberObservation
  = IamMemberAbsent
  | IamMemberPresent
  | IamMemberUnobservable !Text
  deriving (Eq, Show)

data JointIamDispositionRefusal
  = -- | The read-back said nothing about a member of the family.  A silent
    -- member is not an absent one.
    JointIamMemberUnobserved !(NonEmpty IamFamilyMember)
  | -- | A read-back for a member this authorization does not cover, or two
    -- read-backs for one member.
    JointIamMemberForeign !(NonEmpty IamFamilyMember)
  | -- | Every member was observed and some survived.  Naming all of them, not
    -- the first, is what makes a partial destroy resumable rather than opaque.
    JointIamMemberStillPresent !(NonEmpty IamFamilyMember)
  | JointIamMemberUnobservable !(NonEmpty (IamFamilyMember, Text))
  deriving (Eq, Show)

renderJointIamDispositionRefusal :: JointIamDispositionRefusal -> Text
renderJointIamDispositionRefusal = \case
  JointIamMemberUnobserved members ->
    "joint IAM disposition read-back said nothing about "
      <> renderMembers members
  JointIamMemberForeign members ->
    "joint IAM disposition read-back named members outside this family: "
      <> renderMembers members
  JointIamMemberStillPresent members ->
    "joint IAM disposition is incomplete; these members are still present: "
      <> renderMembers members
  JointIamMemberUnobservable failures ->
    "joint IAM disposition could not observe "
      <> Text.intercalate
        ", "
        [ iamFamilyMemberText member <> " (" <> detail <> ")"
        | (member, detail) <- NonEmpty.toList failures
        ]
 where
  renderMembers members =
    Text.intercalate
      ", "
      (map iamFamilyMemberText (NonEmpty.toList members))

-- | The sole evidence that one credential class's IAM family is gone.
--
-- Opaque and unconstructible except through 'disposeJointIamFamily', so no
-- caller can present a partial destroy as a completed one.
data JointIamDispositionComplete = JointIamDispositionComplete
  { internalJointIamCompleteAuthorization :: !JointIamDispositionAuthorization
  , internalJointIamCompleteMembers :: ![IamFamilyMember]
  }
  deriving (Eq, Show)

jointIamDispositionCompleteAuthorization
  :: JointIamDispositionComplete -> JointIamDispositionAuthorization
jointIamDispositionCompleteAuthorization =
  internalJointIamCompleteAuthorization

-- | The canonical digest of one complete disposition.
--
-- It names the class, the principal, the declared policy name, the role when
-- there is one, and every member proved absent, so two dispositions over
-- different families cannot share a digest and a widened family changes it.
jointIamDispositionDigest :: JointIamDispositionComplete -> Text
jointIamDispositionDigest complete =
  TextEncoding.decodeUtf8 (hexSha256 (TextEncoding.encodeUtf8 canonical))
 where
  authorization = internalJointIamCompleteAuthorization complete
  canonical =
    Text.intercalate
      "\NUL"
      ( "joint-iam-disposition/v1"
          : Text.pack (show (internalJointIamClass authorization))
          : internalJointIamPrincipal authorization
          : internalJointIamPolicyName authorization
          : maybe "role:none" ("role:" <>) (internalJointIamRole authorization)
          : map iamFamilyMemberText (internalJointIamCompleteMembers complete)
      )

-- | Decide one disposition over the whole family at once.
--
-- Total over the family: a member with no observation refuses, an observation
-- for a member outside the family refuses, and completion needs every member
-- independently absent.  The three refusals are distinct because they license
-- different next steps — fix the read-back, fix the caller, or retry the
-- destroy.
disposeJointIamFamily
  :: JointIamDispositionAuthorization
  -> [(IamFamilyMember, IamMemberObservation)]
  -> Either JointIamDispositionRefusal JointIamDispositionComplete
disposeJointIamFamily authorization observations = do
  case NonEmpty.nonEmpty foreign' of
    Just members -> Left (JointIamMemberForeign members)
    Nothing -> Right ()
  case NonEmpty.nonEmpty unobserved of
    Just members -> Left (JointIamMemberUnobserved members)
    Nothing -> Right ()
  case NonEmpty.nonEmpty unobservable of
    Just failures -> Left (JointIamMemberUnobservable failures)
    Nothing -> Right ()
  case NonEmpty.nonEmpty present of
    Just members -> Left (JointIamMemberStillPresent members)
    Nothing -> Right ()
  Right
    JointIamDispositionComplete
      { internalJointIamCompleteAuthorization = authorization
      , internalJointIamCompleteMembers = family
      }
 where
  family = jointIamDispositionFamily authorization
  observed = map fst observations
  duplicated = nub [member | member <- observed, count member > 1]
  count member = length (filter (== member) observed)
  foreign' =
    sort (nub ([member | member <- observed, member `notElem` family] ++ duplicated))
  unobserved = [member | member <- family, member `notElem` observed]
  unobservable =
    [ (member, detail)
    | member <- family
    , Just (IamMemberUnobservable detail) <- [lookup member observations]
    ]
  present =
    [ member
    | member <- family
    , Just IamMemberPresent <- [lookup member observations]
    ]
