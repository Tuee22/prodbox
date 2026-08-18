{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.50: the deterministic decommission inventory that the receipt is
-- bound to.
--
-- A 'DecommissionManifest' is the signed plan a total-teardown run commits to
-- before the point of no return: the ordered set of typed nodes it will destroy,
-- read back, and prove absent, tagged with the cluster identity it decommissions.
-- Its canonical digest ('decommissionManifestDigest') is the exact
-- 'Prodbox.Lifecycle.Decommission.Frame.FrameDigest' every receipt frame carries,
-- so a receipt can never be replayed against a different plan — reopening a
-- receipt under a manifest whose digest differs is a chain refusal, not a resume.
--
-- The manifest is opaque: it is only reachable through 'mkDecommissionManifest',
-- which rejects an empty or duplicated inventory, an invalid cluster identity, and
-- an invalid target reference, so a malformed plan cannot be digested or committed.
-- The typed-graph ordering over these nodes (TLS objects before the shared bucket,
-- SES IAM destroy/read-back before target/custody tombstones, backup and shared
-- bucket last) and the retained-Model-B receipt-commit are separate increments.
module Prodbox.Lifecycle.Decommission.Manifest
  ( DecommissionTargetGeneration
  , DecommissionTargetGenerationError (..)
  , mkDecommissionTargetGeneration
  , decommissionTargetGenerationValue
  , DecommissionLocalDataDisposition (..)
  , decommissionLocalDataDispositionText
  , DecommissionNode (..)
  , DecommissionSingletonNode (..)
  , DecommissionChoiceFamily (..)
  , DecommissionNodeFamily (..)
  , decommissionNodeFamily
  , decommissionNodeSingleton
  , singletonDecommissionNode
  , requiredSingletonDecommissionNodes
  , mandatoryDecommissionChoiceNodes
  , decommissionChoiceFamilyRepresentative
  , decommissionSingletonNodeBijection
  , decommissionChoiceFamilyBijection
  , DecommissionPlanCardinalityError (..)
  , renderDecommissionPlanCardinalityError
  , validateDecommissionPlanCardinality
  , DecommissionManifest
  , ManifestError (..)
  , currentManifestVersion
  , mkDecommissionManifest
  , manifestVersion
  , manifestClusterId
  , manifestNodes
  , decommissionNodeFrameId
  , decommissionManifestDigest
  , ManifestCodecError (..)
  , encodeDecommissionManifest
  , decodeDecommissionManifest
  , ManifestSigningKey
  , ManifestSigningKeyError (..)
  , mkManifestSigningKey
  , ManifestPublicKey
  , mkManifestPublicKey
  , manifestPublicKeyBytes
  , manifestPublicKeyDigest
  , manifestSigningPublicKey
  , ManifestSignature
  , manifestSignatureBytes
  , SignedDecommissionManifest
  , signDecommissionManifest
  , manifestSigningPayload
  , verifyExternallySignedDecommissionManifest
  , signedManifestPlan
  , signedManifestVerifierBinding
  , signedManifestPublicKey
  , signedManifestSignature
  , signedDecommissionManifestDigest
  , signedManifestSignatureDigest
  , SignedManifestVerificationError (..)
  , VerifiedDecommissionManifest
  , verifySignedDecommissionManifest
  , verifiedSignedManifest
  , verifiedManifestPlan
  , verifiedVerifierBinding
  , verifiedManifestDigest
  , SignedManifestCodecError (..)
  , encodeSignedDecommissionManifest
  , decodeSignedDecommissionManifest
  )
where

import Codec.Serialise (Serialise, deserialiseOrFail, serialise)
import Crypto.Error (CryptoFailable (CryptoFailed, CryptoPassed))
import Crypto.PubKey.Ed25519 qualified as Ed25519
import Data.ByteArray qualified as ByteArray
import Data.ByteString qualified as StrictByteString
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isControl)
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Lifecycle.Decommission.Frame
  ( FrameDigest
  , FrameNodeId
  , contentDigest
  , frameNodeIdForContent
  )
import Prodbox.Lifecycle.Decommission.Verifier
  ( VerifierBinding
  , VerifierBindingError
  , validateVerifierBinding
  )

-- | A positive credential generation authenticated by the signed manifest.
-- Opaque construction prevents a caller from adding an unversioned or zero
-- generation target node to a production plan.
newtype DecommissionTargetGeneration = DecommissionTargetGeneration Natural
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

data DecommissionTargetGenerationError
  = DecommissionTargetGenerationMustBePositive
  deriving stock (Eq, Show)

mkDecommissionTargetGeneration
  :: Natural
  -> Either DecommissionTargetGenerationError DecommissionTargetGeneration
mkDecommissionTargetGeneration generation
  | generation == 0 = Left DecommissionTargetGenerationMustBePositive
  | otherwise = Right (DecommissionTargetGeneration generation)

decommissionTargetGenerationValue :: DecommissionTargetGeneration -> Natural
decommissionTargetGenerationValue (DecommissionTargetGeneration generation) = generation

-- | Sprint 4.85: the operator's explicit retain-or-delete decision for the
-- retained local data root, as a type.
--
-- The decision has no default and no third value. A total decommission that
-- destroyed every AWS resource class and uninstalled the home substrate still
-- leaves the manual PV host root on disk -- the root @nuke@ already names as
-- the first entry of its own deletion-root inventory, which is why the
-- external receipt and pinned runner are required to live outside it. Nothing
-- disposed of it, and nothing recorded what the operator wanted done with it.
--
-- Making it a value rather than a flag read at the effect boundary is what
-- lets it be signed: it is a parameter of the 'LocalDataDisposition' node, so
-- it enters the manifest digest, the frame node identity, and the plan the
-- operator approves. A receipt opened for a @retain@ run therefore cannot be
-- resumed as a @delete@ run -- the node IDs differ.
data DecommissionLocalDataDisposition
  = -- | Leave the retained local data root exactly as it is.
    RetainLocalData
  | -- | Delete the retained local data root and read back its absence.
    DeleteLocalData
  deriving stock (Bounded, Enum, Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

decommissionLocalDataDispositionText :: DecommissionLocalDataDisposition -> Text
decommissionLocalDataDispositionText disposition = case disposition of
  RetainLocalData -> "retain"
  DeleteLocalData -> "delete"

-- | A typed unit of decommission work. Singleton nodes name a unique resource
-- class; 'TargetGeneration' authenticates both the registered target reference
-- and its exact positive credential generation. A run may name several Agents,
-- but it cannot authorize two competing generations for one Agent reference.
data DecommissionNode
  = -- | Prove every SES consumer quiescent before destroying the provider.
    SesConsumerQuiescence
  | -- | Destroy and read back the SES provider stack.
    SesProviderStack
  | -- | Destroy and read back the external SMTP IAM family.
    SesSmtpIam
  | -- | Tombstone and read back one exact Target Secret Agent generation.
    TargetGeneration !Text !DecommissionTargetGeneration
  | -- | Tombstone and read back retained-home custody.
    RetainedCustody
  | -- | Delete the retained TLS objects and versions (never the shared bucket).
    TlsRetainedObjects
  | -- | Delete the TLS retention identity.
    TlsRetentionIdentity
  | -- | Prove every registered backup prefix absent before deleting backup state.
    BackupPrefixAbsenceProof
  | -- | Delete the backup objects and identity.
    BackupObjects
  | -- | Delete the shared object bucket — the last resource deletion.
    SharedObjectBucket
  | -- | Sprint 4.85: the final no-retention escape audit, which admits no
    -- retained carve-out and is the terminal node of the receipt graph.
    --
    -- It is appended rather than inserted: 'DecommissionNode' derives
    -- 'Serialise', and its constructor index feeds both
    -- 'decommissionNodeFrameId' and the signed manifest digest, so every
    -- existing node keeps its historical identity.
    FinalNoRetentionAudit
  | -- | Sprint 4.85: uninstall the home substrate and read back its absence.
    --
    -- It runs after the final audit, which is the order the compiled
    -- @TotalDecommission@ program emits, and after every other node in the
    -- plan -- a stronger condition than the \"every home-plane-dependent node
    -- is terminal\" readiness the doctrine requires, since the local plane is
    -- what the SES quiescence, target-generation, and retained-custody nodes
    -- are answered through.
    HomeSubstrateUninstall
  | -- | Sprint 4.85: apply the operator's explicit @.data@ retain-or-delete
    -- disposition and read back that it was honoured.
    --
    -- Unlike 'TargetGeneration' this node is mandatory and unique: exactly one
    -- disposition node belongs in a production plan, because there is exactly
    -- one retained local data root and a run that names none has silently
    -- decided to retain it. That cardinality is stated once, by
    -- 'decommissionNodeFamily', and checked by
    -- 'validateDecommissionPlanCardinality'.
    LocalDataDisposition !DecommissionLocalDataDisposition
  | -- | Sprint 4.85: prove, from the external receipt's own committed frames,
    -- that every other node of the plan is durably terminal.
    --
    -- The receipt records each node's intent, observation, and result. What it
    -- never recorded is that the __run__ converged: a receipt ending at the
    -- last node's result frame is byte-identical to one whose run crashed
    -- immediately after that frame, and @reportConverged@ exists only inside
    -- the process that produced it. This node is last in the derived order, so
    -- its own success frame is that missing declaration -- and it can only be
    -- written once the durable record already carries every other node's.
    DecommissionTerminalReceipt
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Serialise)

-- | Sprint 4.85: the closed enumeration of the singleton half of
-- 'DecommissionNode'.
--
-- Every singleton node is mandatory — a manifest that omits one authorizes a
-- decommission that provably leaves that resource class behind — and the
-- verifier enforces that by comparing the signed node list against a required
-- set. That required set was a hand-authored list of nine, joined to nothing,
-- so a newly added singleton constructor would have been silently optional:
-- the verifier would accept a manifest that never names it, and the run would
-- report success having never executed it.
--
-- This enumeration is the join. It is a separate type rather than a
-- restructuring of 'DecommissionNode' on purpose: 'DecommissionNode' derives
-- 'Serialise', and its serialization feeds both 'decommissionNodeFrameId' and
-- the signed manifest digest, so changing its constructor shape would change
-- every historical frame ID and manifest signature — a Standard-P identity
-- change for a check that needs none.
--
-- 'TargetGeneration' is deliberately absent: it is parameterized by a target
-- reference and generation, so a run names as many as it has Agents and none
-- is individually mandatory.
data DecommissionSingletonNode
  = SingletonSesConsumerQuiescence
  | SingletonSesProviderStack
  | SingletonSesSmtpIam
  | SingletonRetainedCustody
  | SingletonTlsRetainedObjects
  | SingletonTlsRetentionIdentity
  | SingletonBackupPrefixAbsenceProof
  | SingletonBackupObjects
  | SingletonSharedObjectBucket
  | SingletonFinalNoRetentionAudit
  | SingletonHomeSubstrateUninstall
  | SingletonDecommissionTerminalReceipt
  deriving stock (Bounded, Enum, Eq, Ord, Show)

-- | Sprint 4.85: the closed enumeration of the mandatory __parameterized__
-- node families.
--
-- A family here is mandatory and unique like a singleton, but its node carries
-- a decision drawn from a closed universe, so the node itself cannot be listed
-- among the required constructors. Without this classification the only
-- cardinality the plan verifier could express was \"every singleton is
-- present\", and a mandatory node with a parameter would have been silently
-- optional -- exactly the defect the singleton enumeration was introduced to
-- close, one constructor shape further along.
data DecommissionChoiceFamily
  = -- | The operator's explicit @.data@ retain-or-delete disposition.
    LocalDataDispositionFamily
  deriving stock (Bounded, Enum, Eq, Ord, Show)

-- | How many nodes of its kind a valid production plan contains, and why.
--
-- This is the single node-cardinality classifier. 'decommissionNodeSingleton'
-- is a projection of it rather than a second @case@, so the required-singleton
-- list and the mandatory-choice list cannot disagree about one node.
data DecommissionNodeFamily
  = -- | Exactly one node, carrying no parameters.
    MandatorySingletonFamily !DecommissionSingletonNode
  | -- | Exactly one node, carrying a decision from a closed universe.
    MandatoryChoiceFamily !DecommissionChoiceFamily
  | -- | Zero or more nodes, one per live Target Secret Agent reference.
    PerAgentTargetFamily
  deriving stock (Eq, Ord, Show)

-- | Total over the closed node universe, so adding a 'DecommissionNode'
-- constructor is an exhaustiveness failure until its cardinality is
-- deliberately stated.
decommissionNodeFamily :: DecommissionNode -> DecommissionNodeFamily
decommissionNodeFamily node = case node of
  SesConsumerQuiescence -> MandatorySingletonFamily SingletonSesConsumerQuiescence
  SesProviderStack -> MandatorySingletonFamily SingletonSesProviderStack
  SesSmtpIam -> MandatorySingletonFamily SingletonSesSmtpIam
  TargetGeneration _ _ -> PerAgentTargetFamily
  RetainedCustody -> MandatorySingletonFamily SingletonRetainedCustody
  TlsRetainedObjects -> MandatorySingletonFamily SingletonTlsRetainedObjects
  TlsRetentionIdentity -> MandatorySingletonFamily SingletonTlsRetentionIdentity
  BackupPrefixAbsenceProof -> MandatorySingletonFamily SingletonBackupPrefixAbsenceProof
  BackupObjects -> MandatorySingletonFamily SingletonBackupObjects
  SharedObjectBucket -> MandatorySingletonFamily SingletonSharedObjectBucket
  FinalNoRetentionAudit -> MandatorySingletonFamily SingletonFinalNoRetentionAudit
  HomeSubstrateUninstall -> MandatorySingletonFamily SingletonHomeSubstrateUninstall
  LocalDataDisposition _ -> MandatoryChoiceFamily LocalDataDispositionFamily
  DecommissionTerminalReceipt ->
    MandatorySingletonFamily SingletonDecommissionTerminalReceipt

-- | The singleton node one 'DecommissionNode' is, if it is one. A projection
-- of 'decommissionNodeFamily'.
decommissionNodeSingleton :: DecommissionNode -> Maybe DecommissionSingletonNode
decommissionNodeSingleton node = case decommissionNodeFamily node of
  MandatorySingletonFamily singleton -> Just singleton
  MandatoryChoiceFamily _ -> Nothing
  PerAgentTargetFamily -> Nothing

-- | The 'DecommissionNode' one singleton is. The inverse of
-- 'decommissionNodeSingleton' on its singleton domain; their round trip is
-- proved by 'decommissionSingletonNodeBijection'.
singletonDecommissionNode :: DecommissionSingletonNode -> DecommissionNode
singletonDecommissionNode singleton = case singleton of
  SingletonSesConsumerQuiescence -> SesConsumerQuiescence
  SingletonSesProviderStack -> SesProviderStack
  SingletonSesSmtpIam -> SesSmtpIam
  SingletonRetainedCustody -> RetainedCustody
  SingletonTlsRetainedObjects -> TlsRetainedObjects
  SingletonTlsRetentionIdentity -> TlsRetentionIdentity
  SingletonBackupPrefixAbsenceProof -> BackupPrefixAbsenceProof
  SingletonBackupObjects -> BackupObjects
  SingletonSharedObjectBucket -> SharedObjectBucket
  SingletonFinalNoRetentionAudit -> FinalNoRetentionAudit
  SingletonHomeSubstrateUninstall -> HomeSubstrateUninstall
  SingletonDecommissionTerminalReceipt -> DecommissionTerminalReceipt

-- | Every mandatory singleton node, derived from the closed enumeration rather
-- than authored beside it.
requiredSingletonDecommissionNodes :: [DecommissionNode]
requiredSingletonDecommissionNodes =
  map singletonDecommissionNode [minBound .. maxBound]

-- | Both directions of the singleton join, as a value.
--
-- A one-directional map would let the two drift: a singleton whose
-- 'singletonDecommissionNode' image classifies back as a /different/ singleton
-- would still produce a nine-element required list, and the verifier would
-- demand the wrong nodes.
decommissionSingletonNodeBijection :: Bool
decommissionSingletonNodeBijection =
  all
    ( \singleton ->
        decommissionNodeSingleton (singletonDecommissionNode singleton)
          == Just singleton
    )
    [minBound .. maxBound]

-- | Sprint 4.85: every mandatory choice node for one operator decision,
-- derived from the closed family enumeration.
--
-- The inner @case@ is what carries the exhaustiveness pressure: a second
-- mandatory choice family cannot be added without saying which node it
-- contributes for a given decision, and the decision universe it draws from.
mandatoryDecommissionChoiceNodes
  :: DecommissionLocalDataDisposition -> [DecommissionNode]
mandatoryDecommissionChoiceNodes disposition =
  [nodeFor family | family <- [minBound .. maxBound]]
 where
  nodeFor family = case family of
    LocalDataDispositionFamily -> LocalDataDisposition disposition

-- | One node standing for a mandatory choice family, for layout and
-- measurement only.
--
-- A representative is never signed and never executed: it names the family's
-- position in a rendered plan and its semantic tag in the parity measurement,
-- both of which are the same for every decision in the family. Every signed
-- plan node comes from 'mandatoryDecommissionChoiceNodes' under the operator's
-- actual decision instead.
decommissionChoiceFamilyRepresentative
  :: DecommissionChoiceFamily -> DecommissionNode
decommissionChoiceFamilyRepresentative family = case family of
  LocalDataDispositionFamily -> LocalDataDisposition RetainLocalData

-- | Both directions of the choice-family join, as a value.
decommissionChoiceFamilyBijection :: Bool
decommissionChoiceFamilyBijection =
  all
    ( \family ->
        decommissionNodeFamily (decommissionChoiceFamilyRepresentative family)
          == MandatoryChoiceFamily family
    )
    [minBound .. maxBound]

-- | Sprint 4.85: a production plan's node cardinality is wrong in one of three
-- ways.
data DecommissionPlanCardinalityError
  = -- | A mandatory singleton node the plan never names.
    DecommissionPlanSingletonMissing !DecommissionSingletonNode
  | -- | A mandatory choice family the plan never names, so the decision it
    -- carries was never made or never signed.
    DecommissionPlanChoiceMissing !DecommissionChoiceFamily
  | -- | More than one node of a mandatory choice family, so the plan carries
    -- two competing decisions for one operation.
    DecommissionPlanChoiceAmbiguous
      !DecommissionChoiceFamily
      ![DecommissionNode]
  deriving stock (Eq, Show)

renderDecommissionPlanCardinalityError
  :: DecommissionPlanCardinalityError -> Text
renderDecommissionPlanCardinalityError err = case err of
  DecommissionPlanSingletonMissing singleton ->
    "the plan omits mandatory decommission node "
      <> Text.pack (show (singletonDecommissionNode singleton))
  DecommissionPlanChoiceMissing family ->
    "the plan omits the mandatory decommission decision "
      <> Text.pack (show family)
  DecommissionPlanChoiceAmbiguous family nodes ->
    "the plan carries competing decommission decisions for "
      <> Text.pack (show family)
      <> ": "
      <> Text.pack (show nodes)

-- | Check a node inventory against every cardinality 'decommissionNodeFamily'
-- states.
--
-- The per-Agent family is deliberately unconstrained here: a run names as many
-- target generations as it has Agents, and the production-specific \"exactly
-- one Agent for this cluster identity\" rule belongs to the caller that knows
-- the cluster identity.
validateDecommissionPlanCardinality
  :: [DecommissionNode] -> Either [DecommissionPlanCardinalityError] ()
validateDecommissionPlanCardinality nodes =
  case missingSingletons ++ choiceViolations of
    [] -> Right ()
    errors -> Left errors
 where
  missingSingletons =
    [ DecommissionPlanSingletonMissing singleton
    | singleton <- [minBound .. maxBound]
    , singletonDecommissionNode singleton `notElem` nodes
    ]
  choiceViolations =
    [ violation
    | family <- [minBound .. maxBound] :: [DecommissionChoiceFamily]
    , let present =
            [ node
            | node <- nodes
            , decommissionNodeFamily node == MandatoryChoiceFamily family
            ]
    , violation <- case present of
        [] -> [DecommissionPlanChoiceMissing family]
        [_] -> []
        several -> [DecommissionPlanChoiceAmbiguous family several]
    ]

-- | The deterministic signed inventory. Opaque: build it through
-- 'mkDecommissionManifest'.
data DecommissionManifest = DecommissionManifest
  { manifestVersion :: !Word
  , manifestClusterId :: !Text
  , manifestNodes :: ![DecommissionNode]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

data ManifestError
  = ManifestClusterIdInvalid
  | ManifestNodesEmpty
  | ManifestNodesDuplicated
  | ManifestTargetRefInvalid
  | ManifestTargetRefDuplicated
  | ManifestTargetGenerationInvalid
  deriving stock (Eq, Show)

currentManifestVersion :: Word
currentManifestVersion = 1

-- | Build a validated manifest: a non-empty, duplicate-free node inventory under a
-- well-formed cluster identity, with every target reference well-formed.
mkDecommissionManifest
  :: Text
  -> [DecommissionNode]
  -> Either ManifestError DecommissionManifest
mkDecommissionManifest clusterId nodes
  | not (validIdentifier clusterId) = Left ManifestClusterIdInvalid
  | null nodes = Left ManifestNodesEmpty
  | any invalidTargetReference nodes = Left ManifestTargetRefInvalid
  | any invalidTargetGeneration nodes = Left ManifestTargetGenerationInvalid
  | targetReferences /= nub targetReferences = Left ManifestTargetRefDuplicated
  | nub nodes /= nodes = Left ManifestNodesDuplicated
  | otherwise =
      Right
        DecommissionManifest
          { manifestVersion = currentManifestVersion
          , manifestClusterId = Text.strip clusterId
          , manifestNodes = nodes
          }
 where
  targetReferences = [reference | TargetGeneration reference _ <- nodes]
  invalidTargetReference node = case node of
    TargetGeneration reference _ -> not (validIdentifier reference)
    _ -> False
  invalidTargetGeneration node = case node of
    TargetGeneration _ generation -> decommissionTargetGenerationValue generation == 0
    _ -> False

-- | The canonical digest that binds a receipt to this exact plan.
decommissionManifestDigest :: DecommissionManifest -> FrameDigest
decommissionManifestDigest =
  contentDigest . LazyByteString.toStrict . serialise

-- | The receipt identity of a manifest node.  It is derived from the node's
-- canonical typed representation rather than supplied as unrelated text, so all
-- attempts for one exact coordinate share an ID and two different coordinates
-- cannot be accidentally journaled under one human-selected label.
decommissionNodeFrameId :: DecommissionNode -> FrameNodeId
decommissionNodeFrameId =
  frameNodeIdForContent . LazyByteString.toStrict . serialise

data ManifestCodecError
  = ManifestEnvelopeTooLarge
  | ManifestEnvelopeInvalid
  | ManifestEnvelopeUnsupportedVersion
  | ManifestEnvelopeNonCanonical
  | ManifestEnvelopeSemanticInvalid !ManifestError
  deriving stock (Eq, Show)

-- | Canonical manifest bytes. The manifest is its own versioned envelope (it
-- carries 'manifestVersion'), so a separate wrapper is unnecessary.
encodeDecommissionManifest :: DecommissionManifest -> ByteString
encodeDecommissionManifest = serialise

-- | Decode a manifest from @maximumBytes@-bounded canonical bytes, refusing
-- oversize, non-canonical, and unsupported-version input before it can be
-- committed or resumed.
decodeDecommissionManifest
  :: Int -> ByteString -> Either ManifestCodecError DecommissionManifest
decodeDecommissionManifest maximumBytes bytes
  | maximumBytes < 0 = Left ManifestEnvelopeTooLarge
  | LazyByteString.length bytes > fromIntegral maximumBytes = Left ManifestEnvelopeTooLarge
  | otherwise =
      case deserialiseOrFail bytes of
        Left _ -> Left ManifestEnvelopeInvalid
        Right manifest
          | manifestVersion manifest /= currentManifestVersion ->
              Left ManifestEnvelopeUnsupportedVersion
          | serialise manifest /= bytes -> Left ManifestEnvelopeNonCanonical
          | otherwise ->
              case mkDecommissionManifest (manifestClusterId manifest) (manifestNodes manifest) of
                Left err -> Left (ManifestEnvelopeSemanticInvalid err)
                Right validated
                  | validated == manifest -> Right validated
                  | otherwise -> Left ManifestEnvelopeNonCanonical

validIdentifier :: Text -> Bool
validIdentifier value =
  not (Text.null trimmed)
    && Text.length trimmed <= 128
    && not (Text.any isControl trimmed)
 where
  trimmed = Text.strip value

-- | Authority signing material.  It is intentionally neither serialisable nor
-- showable, so no manifest, receipt, or diagnostic can accidentally contain the
-- private key.
newtype ManifestSigningKey = ManifestSigningKey Ed25519.SecretKey

data ManifestSigningKeyError
  = ManifestSigningKeyInvalid
  deriving stock (Eq, Show)

mkManifestSigningKey
  :: StrictByteString.ByteString
  -> Either ManifestSigningKeyError ManifestSigningKey
mkManifestSigningKey bytes = case Ed25519.secretKey bytes of
  CryptoFailed _ -> Left ManifestSigningKeyInvalid
  CryptoPassed key -> Right (ManifestSigningKey key)

newtype ManifestPublicKey = ManifestPublicKey StrictByteString.ByteString
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

manifestPublicKeyBytes :: ManifestPublicKey -> StrictByteString.ByteString
manifestPublicKeyBytes (ManifestPublicKey bytes) = bytes

-- | Validate public Authority signing material obtained from a non-exportable
-- signing service (for example Vault Transit).  The private key never crosses
-- this boundary.
mkManifestPublicKey
  :: StrictByteString.ByteString
  -> Either SignedManifestVerificationError ManifestPublicKey
mkManifestPublicKey bytes = do
  _ <- parsePublicKey (ManifestPublicKey bytes)
  Right (ManifestPublicKey bytes)

manifestPublicKeyDigest :: ManifestPublicKey -> FrameDigest
manifestPublicKeyDigest = contentDigest . manifestPublicKeyBytes

manifestSigningPublicKey :: ManifestSigningKey -> ManifestPublicKey
manifestSigningPublicKey (ManifestSigningKey key) =
  ManifestPublicKey (ByteArray.convert (Ed25519.toPublic key))

newtype ManifestSignature = ManifestSignature StrictByteString.ByteString
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

manifestSignatureBytes :: ManifestSignature -> StrictByteString.ByteString
manifestSignatureBytes (ManifestSignature bytes) = bytes

data UnsignedCompleteManifest = UnsignedCompleteManifest
  { unsignedCompleteVersion :: !Word
  , unsignedCompletePlan :: !DecommissionManifest
  , unsignedCompleteVerifier :: !VerifierBinding
  , unsignedCompleteSigner :: !ManifestPublicKey
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

-- | The complete, authenticated teardown authority.  Its canonical signed bytes
-- bind the plan, exact exported runner path/build/dependencies, schema and
-- interpreter registry, plus the public signer identity.
data SignedDecommissionManifest = SignedDecommissionManifest
  { signedManifestUnsigned :: !UnsignedCompleteManifest
  , signedManifestSignature :: !ManifestSignature
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Serialise)

currentSignedManifestVersion :: Word
currentSignedManifestVersion = 1

signDecommissionManifest
  :: ManifestSigningKey
  -> DecommissionManifest
  -> VerifierBinding
  -> SignedDecommissionManifest
signDecommissionManifest signingKey@(ManifestSigningKey privateKey) plan verifier =
  let public = Ed25519.toPublic privateKey
      publicKey = manifestSigningPublicKey signingKey
      unsigned =
        UnsignedCompleteManifest
          { unsignedCompleteVersion = currentSignedManifestVersion
          , unsignedCompletePlan = plan
          , unsignedCompleteVerifier = verifier
          , unsignedCompleteSigner = publicKey
          }
      signature = Ed25519.sign privateKey public (canonicalUnsignedBytes unsigned)
   in SignedDecommissionManifest
        { signedManifestUnsigned = unsigned
        , signedManifestSignature = ManifestSignature (ByteArray.convert signature)
        }

-- | Canonical bytes an external Authority signer must sign.  Keeping this
-- function beside 'signDecommissionManifest' guarantees the in-process test
-- signer and the production non-exportable signer use exactly one framing.
manifestSigningPayload
  :: DecommissionManifest
  -> VerifierBinding
  -> ManifestPublicKey
  -> StrictByteString.ByteString
manifestSigningPayload plan verifier publicKey =
  canonicalUnsignedBytes
    UnsignedCompleteManifest
      { unsignedCompleteVersion = currentSignedManifestVersion
      , unsignedCompletePlan = plan
      , unsignedCompleteVerifier = verifier
      , unsignedCompleteSigner = publicKey
      }

-- | Authenticate a signature returned by a non-exportable Authority signing
-- service.  Success returns the same opaque verified value used by every
-- retained commit, receipt, and runner gate; malformed key/signature bytes or a
-- signature over any other plan/binding are refused here.
verifyExternallySignedDecommissionManifest
  :: DecommissionManifest
  -> VerifierBinding
  -> ManifestPublicKey
  -> StrictByteString.ByteString
  -> Either SignedManifestVerificationError VerifiedDecommissionManifest
verifyExternallySignedDecommissionManifest plan verifier publicKey signatureBytes =
  verifySignedDecommissionManifest
    (manifestPublicKeyDigest publicKey)
    SignedDecommissionManifest
      { signedManifestUnsigned =
          UnsignedCompleteManifest
            { unsignedCompleteVersion = currentSignedManifestVersion
            , unsignedCompletePlan = plan
            , unsignedCompleteVerifier = verifier
            , unsignedCompleteSigner = publicKey
            }
      , signedManifestSignature = ManifestSignature signatureBytes
      }

signedManifestPlan :: SignedDecommissionManifest -> DecommissionManifest
signedManifestPlan = unsignedCompletePlan . signedManifestUnsigned

signedManifestVerifierBinding :: SignedDecommissionManifest -> VerifierBinding
signedManifestVerifierBinding = unsignedCompleteVerifier . signedManifestUnsigned

signedManifestPublicKey :: SignedDecommissionManifest -> ManifestPublicKey
signedManifestPublicKey = unsignedCompleteSigner . signedManifestUnsigned

signedDecommissionManifestDigest :: SignedDecommissionManifest -> FrameDigest
signedDecommissionManifestDigest =
  contentDigest . LazyByteString.toStrict . serialise

signedManifestSignatureDigest :: SignedDecommissionManifest -> FrameDigest
signedManifestSignatureDigest = contentDigest . manifestSignatureBytes . signedManifestSignature

data SignedManifestVerificationError
  = SignedManifestUnsupportedVersion
  | SignedManifestPlanInvalid !ManifestError
  | SignedManifestVerifierBindingInvalid !VerifierBindingError
  | SignedManifestPublicKeyInvalid
  | SignedManifestSignatureInvalid
  | SignedManifestSignerDigestMismatch
  | SignedManifestAuthenticationFailed
  deriving stock (Eq, Show)

newtype VerifiedDecommissionManifest = VerifiedDecommissionManifest SignedDecommissionManifest
  deriving stock (Eq, Show)

verifySignedDecommissionManifest
  :: FrameDigest
  -> SignedDecommissionManifest
  -> Either SignedManifestVerificationError VerifiedDecommissionManifest
verifySignedDecommissionManifest expectedSignerDigest signed = do
  let unsigned = signedManifestUnsigned signed
      plan = unsignedCompletePlan unsigned
  if unsignedCompleteVersion unsigned == currentSignedManifestVersion
    then pure ()
    else Left SignedManifestUnsupportedVersion
  validatedPlan <-
    either
      (Left . SignedManifestPlanInvalid)
      Right
      (mkDecommissionManifest (manifestClusterId plan) (manifestNodes plan))
  if validatedPlan == plan
    then pure ()
    else Left SignedManifestAuthenticationFailed
  _ <-
    either
      (Left . SignedManifestVerifierBindingInvalid)
      Right
      (validateVerifierBinding (unsignedCompleteVerifier unsigned))
  public <- parsePublicKey (unsignedCompleteSigner unsigned)
  signature <- parseSignature (signedManifestSignature signed)
  if manifestPublicKeyDigest (unsignedCompleteSigner unsigned) == expectedSignerDigest
    then pure ()
    else Left SignedManifestSignerDigestMismatch
  if Ed25519.verify public (canonicalUnsignedBytes unsigned) signature
    then Right (VerifiedDecommissionManifest signed)
    else Left SignedManifestAuthenticationFailed

verifiedSignedManifest :: VerifiedDecommissionManifest -> SignedDecommissionManifest
verifiedSignedManifest (VerifiedDecommissionManifest signed) = signed

verifiedManifestPlan :: VerifiedDecommissionManifest -> DecommissionManifest
verifiedManifestPlan = signedManifestPlan . verifiedSignedManifest

verifiedVerifierBinding :: VerifiedDecommissionManifest -> VerifierBinding
verifiedVerifierBinding = signedManifestVerifierBinding . verifiedSignedManifest

verifiedManifestDigest :: VerifiedDecommissionManifest -> FrameDigest
verifiedManifestDigest = signedDecommissionManifestDigest . verifiedSignedManifest

data SignedManifestCodecError
  = SignedManifestEnvelopeTooLarge
  | SignedManifestEnvelopeInvalid
  | SignedManifestEnvelopeNonCanonical
  | SignedManifestEnvelopeVerificationFailed !SignedManifestVerificationError
  deriving stock (Eq, Show)

encodeSignedDecommissionManifest :: SignedDecommissionManifest -> ByteString
encodeSignedDecommissionManifest = serialise

decodeSignedDecommissionManifest
  :: Int
  -> FrameDigest
  -> ByteString
  -> Either SignedManifestCodecError SignedDecommissionManifest
decodeSignedDecommissionManifest maximumBytes expectedSigner bytes
  | maximumBytes < 0 = Left SignedManifestEnvelopeTooLarge
  | LazyByteString.length bytes > fromIntegral maximumBytes = Left SignedManifestEnvelopeTooLarge
  | otherwise = case deserialiseOrFail bytes of
      Left _ -> Left SignedManifestEnvelopeInvalid
      Right signed
        | serialise signed /= bytes -> Left SignedManifestEnvelopeNonCanonical
        | otherwise ->
            case verifySignedDecommissionManifest expectedSigner signed of
              Left err -> Left (SignedManifestEnvelopeVerificationFailed err)
              Right verified -> Right (verifiedSignedManifest verified)

canonicalUnsignedBytes :: UnsignedCompleteManifest -> StrictByteString.ByteString
canonicalUnsignedBytes = LazyByteString.toStrict . serialise

parsePublicKey
  :: ManifestPublicKey
  -> Either SignedManifestVerificationError Ed25519.PublicKey
parsePublicKey (ManifestPublicKey bytes) = case Ed25519.publicKey bytes of
  CryptoFailed _ -> Left SignedManifestPublicKeyInvalid
  CryptoPassed key -> Right key

parseSignature
  :: ManifestSignature
  -> Either SignedManifestVerificationError Ed25519.Signature
parseSignature (ManifestSignature bytes) = case Ed25519.signature bytes of
  CryptoFailed _ -> Left SignedManifestSignatureInvalid
  CryptoPassed signature -> Right signature
