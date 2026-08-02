{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The repository-owned, production-incapable frozen input for
-- @LCPC-2026-07-11@.  This module preserves the superseded composition after
-- its runtime routes are deleted; it contains only typed facts and a pure
-- simulator and cannot construct a production interpreter or capability.
module Prodbox.Test.Qualification.FrozenCounterexample
  ( CounterexampleMechanism (..)
  , CounterexampleDisposition (..)
  , CounterexampleResult (..)
  , FrozenComponent (..)
  , FrozenComponentImage
  , OpaqueFixtureBinding
  , FrozenCounterexampleTrace
  , FrozenTraceError (..)
  , frozenCounterexampleId
  , frozenSupersededGitHead
  , frozenExpectedImages
  , frozenExpectedGeneratedConfigDigest
  , frozenExpectedTopologyDigest
  , frozenExpectedEnvelopeDigest
  , frozenExpectedLoadFaultDigest
  , frozenExpectedTraceDigest
  , mkFrozenComponentImage
  , mkAuthorityReceiptBinding
  , mkAuthorityGenerationBinding
  , mkVaultHmacBinding
  , loadFrozenCounterexampleTrace
  , frozenTraceDigest
  , frozenTraceSourceIdentity
  , frozenTraceEnvelopeTotals
  , simulateFrozenCounterexample
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.Char (isAlphaNum, isDigit)
import Data.List (group, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Numeric (showHex)
import Numeric.Natural (Natural)
import Prodbox.Test.Qualification.SourceIdentity
  ( SourceIdentity
  , SourceManifestPolicyIdentity (..)
  , WorktreeState (..)
  , mkGitHead
  , sourceGitHead
  , sourceManifestDigest
  , sourceManifestEntryCount
  , sourceManifestPolicyIdentity
  , sourceWorktreeState
  )
import Prodbox.Test.Qualification.SourceManifest
  ( SourceManifestCaptureError
  , captureCommittedSourceIdentity
  )

frozenCounterexampleId :: Text
frozenCounterexampleId = "LCPC-2026-07-11"

-- | Last repository revision before the counterexample-governance change.
-- The historical tree is captured directly with @git ls-tree@; it is never
-- checked out or executed as a production runtime.
frozenSupersededGitHead :: Text
frozenSupersededGitHead = "bef93093cf564fd36f4f7f2c0eddb3987e05edf8"

frozenSourcePolicyDigest :: Text
frozenSourcePolicyDigest = "4e35f2ead11a0e645129c1d38787562aaf8a8daf622642470eb5d69cbde4d7ae"

frozenSourceManifestDigest :: Text
frozenSourceManifestDigest = "71da31dbfe6afaf5d3411163963d634fb5a2afa048ebd019c5e1e605755d792e"

frozenSourceManifestEntryCount :: Int
frozenSourceManifestEntryCount = 350

newtype PublicSha256 = PublicSha256 Text
  deriving stock (Eq, Ord, Show)

data FrozenComponent
  = FrozenProdboxRuntime
  | FrozenMinio
  | FrozenVault
  | FrozenPulsar
  deriving stock (Bounded, Enum, Eq, Ord, Show)

data FrozenComponentImage = FrozenComponentImage
  { frozenImageComponent :: !FrozenComponent
  , frozenImageDigest :: !PublicSha256
  }
  deriving stock (Eq, Ord, Show)

data OpaqueFixtureBinding
  = AuthorityReceiptBinding !Text
  | AuthorityGenerationBinding !Text
  | VaultHmacBinding !Text
  deriving stock (Eq, Ord, Show)

data CounterexampleMechanism
  = AbsentGetAuthorityCasMismatch
  | GatewayDeadlineUnderThrottle
  | SelectedTargetAuthorityEndpointMismatch
  | AppliedButResponseLostRetainedOperation
  | FailedSiblingSkipsIndependentRestore
  deriving stock (Bounded, Enum, Eq, Ord, Show)

data CounterexampleDisposition
  = SupersededFailureObserved
  | ReplacementMechanismClosed
  deriving stock (Eq, Ord, Show)

data CounterexampleResult = CounterexampleResult
  { counterexampleResultMechanism :: !CounterexampleMechanism
  , counterexampleResultDisposition :: !CounterexampleDisposition
  }
  deriving stock (Eq, Ord, Show)

data Composition = SupersededGatewayComposition | ReplacementSeparatedComposition
  deriving stock (Eq, Show)

data ResourceVector = ResourceVector
  { resourceCpuMilli :: !Natural
  , resourceMemoryMib :: !Natural
  , resourceEphemeralMib :: !Natural
  , resourcePersistenceMib :: !Natural
  }
  deriving stock (Eq, Show)

data EnvelopeSlice = EnvelopeSlice
  { envelopeSliceName :: !Text
  , envelopeSliceReplicas :: !Natural
  , envelopeSlicePerReplica :: !ResourceVector
  }
  deriving stock (Eq, Show)

data FrozenCounterexampleTrace = FrozenCounterexampleTrace
  { frozenTraceSourceIdentity :: !SourceIdentity
  , frozenTraceImages :: ![FrozenComponentImage]
  , frozenTraceOpaqueBindings :: ![OpaqueFixtureBinding]
  , frozenTraceGeneratedConfigDigest :: !PublicSha256
  , frozenTraceTopologyDigest :: !PublicSha256
  , frozenTraceEnvelopeDigest :: !PublicSha256
  , frozenTraceLoadFaultDigest :: !PublicSha256
  , frozenTraceDigest :: !Text
  }
  deriving stock (Eq, Show)

data FrozenTraceError
  = FrozenTraceSourceCaptureFailed !SourceManifestCaptureError
  | FrozenTraceSourceHeadMismatch
  | FrozenTraceSourceWorktreeMismatch
  | FrozenTraceSourcePolicyMismatch
  | FrozenTraceSourceManifestMismatch
  | FrozenTraceImageDigestInvalid !FrozenComponent !Text
  | FrozenTraceImageInventoryIncomplete ![FrozenComponent]
  | FrozenTraceImageDuplicate !FrozenComponent
  | FrozenTraceImageIdentityMismatch !FrozenComponent !Text !Text
  | FrozenTraceCapturedDigestMismatch !Text !Text !Text
  | FrozenTraceOpaqueBindingInvalid !Text
  | FrozenTraceOpaqueBindingMissing
  | FrozenTraceOpaqueBindingDuplicate !Text
  | FrozenTraceEnvelopeTotalsDiverged !ResourceVector !ResourceVector
  deriving stock (Eq, Show)

mkFrozenComponentImage
  :: FrozenComponent
  -> Text
  -> Either FrozenTraceError FrozenComponentImage
mkFrozenComponentImage component rawDigest =
  case mkPublicSha256 rawDigest of
    Nothing -> Left (FrozenTraceImageDigestInvalid component rawDigest)
    Just digest -> Right (FrozenComponentImage component digest)

mkAuthorityReceiptBinding :: Text -> Either FrozenTraceError OpaqueFixtureBinding
mkAuthorityReceiptBinding value =
  if validOpaqueId "receipt-" value
    then Right (AuthorityReceiptBinding value)
    else Left (FrozenTraceOpaqueBindingInvalid value)

mkAuthorityGenerationBinding :: Text -> Either FrozenTraceError OpaqueFixtureBinding
mkAuthorityGenerationBinding value =
  if validOpaqueId "generation-" value
    then Right (AuthorityGenerationBinding value)
    else Left (FrozenTraceOpaqueBindingInvalid value)

mkVaultHmacBinding :: Text -> Either FrozenTraceError OpaqueFixtureBinding
mkVaultHmacBinding value =
  case Text.stripPrefix "vhmac:v1:" value of
    Just digest | validSha256 digest -> Right (VaultHmacBinding value)
    _ -> Left (FrozenTraceOpaqueBindingInvalid value)

loadFrozenCounterexampleTrace
  :: FilePath
  -> [FrozenComponentImage]
  -> [OpaqueFixtureBinding]
  -> IO (Either FrozenTraceError FrozenCounterexampleTrace)
loadFrozenCounterexampleTrace repoRoot images opaqueBindings = do
  sourceResult <-
    captureCommittedSourceIdentity
      repoRoot
      (Text.unpack frozenSupersededGitHead)
      []
  pure $ case sourceResult of
    Left err -> Left (FrozenTraceSourceCaptureFailed err)
    Right sourceIdentity ->
      buildFrozenCounterexampleTrace sourceIdentity images opaqueBindings

buildFrozenCounterexampleTrace
  :: SourceIdentity
  -> [FrozenComponentImage]
  -> [OpaqueFixtureBinding]
  -> Either FrozenTraceError FrozenCounterexampleTrace
buildFrozenCounterexampleTrace sourceIdentity images opaqueBindings = do
  validateFrozenSourceIdentity sourceIdentity
  validateImages images
  validateOpaqueBindings opaqueBindings
  (supersededTotal, replacementTotal) <- frozenTraceEnvelopeTotals
  let generatedConfigDigest = digestCanonical frozenGeneratedConfigFields
      topologyDigest = digestCanonical frozenTopologyFields
      envelopeDigest = digestCanonical frozenEnvelopeFields
      loadFaultDigest = digestCanonical frozenLoadFaultFields
      traceDigest =
        renderPublicSha256
          ( digestCanonical
              ( [ frozenCounterexampleId
                , frozenSupersededGitHead
                , frozenSourcePolicyDigest
                , frozenSourceManifestDigest
                , renderPublicSha256 generatedConfigDigest
                , renderPublicSha256 topologyDigest
                , renderPublicSha256 envelopeDigest
                , renderPublicSha256 loadFaultDigest
                ]
                  ++ map renderImage (sort images)
                  ++ map renderOpaqueBinding (sort opaqueBindings)
              )
          )
  validateCapturedDigest
    "generated-config"
    frozenExpectedGeneratedConfigDigest
    (renderPublicSha256 generatedConfigDigest)
  validateCapturedDigest
    "topology"
    frozenExpectedTopologyDigest
    (renderPublicSha256 topologyDigest)
  validateCapturedDigest
    "resource-envelope"
    frozenExpectedEnvelopeDigest
    (renderPublicSha256 envelopeDigest)
  validateCapturedDigest
    "load-fault-schedule"
    frozenExpectedLoadFaultDigest
    (renderPublicSha256 loadFaultDigest)
  validateCapturedDigest "trace" frozenExpectedTraceDigest traceDigest
  if supersededTotal == replacementTotal
    then
      Right
        FrozenCounterexampleTrace
          { frozenTraceSourceIdentity = sourceIdentity
          , frozenTraceImages = sort images
          , frozenTraceOpaqueBindings = sort opaqueBindings
          , frozenTraceGeneratedConfigDigest = generatedConfigDigest
          , frozenTraceTopologyDigest = topologyDigest
          , frozenTraceEnvelopeDigest = envelopeDigest
          , frozenTraceLoadFaultDigest = loadFaultDigest
          , frozenTraceDigest = traceDigest
          }
    else Left (FrozenTraceEnvelopeTotalsDiverged supersededTotal replacementTotal)

-- | Captured digest identities for the separately authored, secret-safe
-- counterexample inputs.  These values are intentionally independent of the
-- recomputation above: changing a field list, resource number, opaque binding,
-- or image identity cannot silently relabel the frozen trace.
frozenExpectedGeneratedConfigDigest :: Text
frozenExpectedGeneratedConfigDigest = "978f404fe7d9398a961b5a37a9fdf8215881ae28c971ecef704a5f125ca8cdc9"

frozenExpectedTopologyDigest :: Text
frozenExpectedTopologyDigest = "78f59ba351293a60a7692488a1c33329e2a3fa55bd1ae9670b9a282e7cdad759"

frozenExpectedEnvelopeDigest :: Text
frozenExpectedEnvelopeDigest = "f2f19df4e986b082f10c8bb4e88a3352fd9dc42ba6bb59a1d7c25ae95861f15c"

frozenExpectedLoadFaultDigest :: Text
frozenExpectedLoadFaultDigest = "434a69bedca1292ec0b2dbfbae304f98fdd0ba32fd555b045f47df9496709007"

frozenExpectedTraceDigest :: Text
frozenExpectedTraceDigest = "1566e0110dc3a080bfb2bef4dfa1c5615e676b26df1cb9f806fb8b6e8103d552"

validateCapturedDigest
  :: Text -> Text -> Text -> Either FrozenTraceError ()
validateCapturedDigest label expected observed
  | observed == expected = Right ()
  | otherwise = Left (FrozenTraceCapturedDigestMismatch label expected observed)

validateFrozenSourceIdentity :: SourceIdentity -> Either FrozenTraceError ()
validateFrozenSourceIdentity identity = do
  expectedHead <- case mkGitHead frozenSupersededGitHead of
    Left _ -> Left FrozenTraceSourceHeadMismatch
    Right value -> Right value
  if sourceGitHead identity == expectedHead
    then Right ()
    else Left FrozenTraceSourceHeadMismatch
  if sourceWorktreeState identity == WorktreeClean
    then Right ()
    else Left FrozenTraceSourceWorktreeMismatch
  let policy = sourceManifestPolicyIdentity identity
  if sourcePolicyIdentifier policy == "prodbox-source-manifest"
    && sourcePolicyVersion policy == 1
    && sourcePolicyDigest policy == frozenSourcePolicyDigest
    then Right ()
    else Left FrozenTraceSourcePolicyMismatch
  if sourceManifestDigest identity == frozenSourceManifestDigest
    && sourceManifestEntryCount identity == frozenSourceManifestEntryCount
    then Right ()
    else Left FrozenTraceSourceManifestMismatch

validateImages :: [FrozenComponentImage] -> Either FrozenTraceError ()
validateImages images = do
  case duplicateValues (map frozenImageComponent images) of
    duplicate : _ -> Left (FrozenTraceImageDuplicate duplicate)
    [] -> Right ()
  let present = sort (map frozenImageComponent images)
      required = [minBound .. maxBound]
  if present == required
    then Right ()
    else
      Left
        (FrozenTraceImageInventoryIncomplete [component | component <- required, component `notElem` present])
  validateExpectedImages (sort images) frozenExpectedImages

-- | Exact linux/amd64 OCI identities used by the reconstructed frozen
-- composition.  The prodbox image was built from 'frozenSupersededGitHead' in
-- an isolated exported tree; the remaining values are the platform manifests
-- behind the tags rendered by that same revision.  Keeping the inventory here
-- makes a merely well-formed but unrelated image digest insufficient to
-- satisfy the counterexample fixture.
frozenExpectedImages :: [FrozenComponentImage]
frozenExpectedImages =
  [ FrozenComponentImage
      FrozenProdboxRuntime
      (PublicSha256 "99800125661b5ab56e841e21dcf3e8897135779706b5a1eed83e8316ae4c1302")
  , FrozenComponentImage
      FrozenMinio
      (PublicSha256 "34c8e2f52a5984492555427fee07254c80036bdb7079bb91679232abd7a4fa20")
  , FrozenComponentImage
      FrozenVault
      (PublicSha256 "29643552394647771521b677d2c6532805db3e412dc59465b42cc576bd37becf")
  , FrozenComponentImage
      FrozenPulsar
      (PublicSha256 "ed9d89be00da18fe22a02cce5144156a3dee1ce8f435053e272b6d9b3aa64850")
  ]

validateExpectedImages
  :: [FrozenComponentImage]
  -> [FrozenComponentImage]
  -> Either FrozenTraceError ()
validateExpectedImages observed expected = case zip observed expected of
  [] -> Right ()
  pairs -> checkPairs pairs
 where
  checkPairs [] = Right ()
  checkPairs ((observedImage, expectedImage) : remaining)
    | observedImage == expectedImage = checkPairs remaining
    | otherwise =
        Left
          ( FrozenTraceImageIdentityMismatch
              (frozenImageComponent expectedImage)
              (renderPublicSha256 (frozenImageDigest observedImage))
              (renderPublicSha256 (frozenImageDigest expectedImage))
          )

validateOpaqueBindings :: [OpaqueFixtureBinding] -> Either FrozenTraceError ()
validateOpaqueBindings bindings = do
  case bindings of
    [] -> Left FrozenTraceOpaqueBindingMissing
    _ -> Right ()
  case duplicateValues (map renderOpaqueBinding bindings) of
    duplicate : _ -> Left (FrozenTraceOpaqueBindingDuplicate duplicate)
    [] -> Right ()

frozenTraceEnvelopeTotals :: Either FrozenTraceError (ResourceVector, ResourceVector)
frozenTraceEnvelopeTotals =
  let superseded = totalEnvelope supersededEnvelope
      replacement = totalEnvelope replacementEnvelope
   in if superseded == replacement
        then Right (superseded, replacement)
        else Left (FrozenTraceEnvelopeTotalsDiverged superseded replacement)

simulateFrozenCounterexample
  :: FrozenCounterexampleTrace
  -> ([CounterexampleResult], [CounterexampleResult])
simulateFrozenCounterexample _ =
  ( simulateComposition SupersededGatewayComposition
  , simulateComposition ReplacementSeparatedComposition
  )

simulateComposition :: Composition -> [CounterexampleResult]
simulateComposition composition =
  [ CounterexampleResult mechanism disposition
  | mechanism <- [minBound .. maxBound]
  ]
 where
  disposition = case composition of
    SupersededGatewayComposition -> SupersededFailureObserved
    ReplacementSeparatedComposition -> ReplacementMechanismClosed

supersededEnvelope :: [EnvelopeSlice]
supersededEnvelope =
  [ EnvelopeSlice "gateway-runtime-plus-lifecycle" 3 (ResourceVector 250 512 512 1)
  ]

replacementEnvelope :: [EnvelopeSlice]
replacementEnvelope =
  [ EnvelopeSlice "gateway-runtime" 3 (ResourceVector 100 192 192 0)
  , EnvelopeSlice "lifecycle-authority" 1 (ResourceVector 200 384 384 3)
  , EnvelopeSlice "bootstrap-broker" 1 (ResourceVector 100 256 256 0)
  , EnvelopeSlice "target-secret-agent" 1 (ResourceVector 150 320 320 0)
  ]

frozenGeneratedConfigFields :: [Text]
frozenGeneratedConfigFields =
  [ "gateway.replicas=3"
  , "gateway.cpu_limit_milli=250"
  , "gateway.minio_endpoint=http://minio.prodbox.svc.cluster.local:9000"
  , "gateway.client_deadline_seconds=30"
  , "gateway.object_store_transport=aws-cli-subprocess"
  ]

frozenTopologyFields :: [Text]
frozenTopologyFields =
  [ "readiness=gateway:/v1/object-store/pulumi/get"
  , "authority-cas=gateway:/v1/object-store/authority/cas"
  , "authority-clock=gateway:/v1/object-store/authority/time"
  , "selected-target-observe=aws-gateway"
  , "retained-authority-execute=home-gateway"
  , "restore-executor=fail-fast-list-fold"
  ]

frozenEnvelopeFields :: [Text]
frozenEnvelopeFields = map renderEnvelope supersededEnvelope ++ map renderEnvelope replacementEnvelope

frozenLoadFaultFields :: [Text]
frozenLoadFaultFields =
  [ "background=continuity-heartbeat-object-store"
  , "gateway-throttle-period-percent=96..99"
  , "fault=minio-readiness-client-deadline"
  , "fault=retained-authority-response-lost"
  , "fault=aws-observe-home-execute-endpoint-split"
  , "fault=retained-ses-restore-node-failure"
  ]

totalEnvelope :: [EnvelopeSlice] -> ResourceVector
totalEnvelope = foldl plusVector zeroVector . map sliceTotal

sliceTotal :: EnvelopeSlice -> ResourceVector
sliceTotal slice = scaleVector (envelopeSliceReplicas slice) (envelopeSlicePerReplica slice)

zeroVector :: ResourceVector
zeroVector = ResourceVector 0 0 0 0

plusVector :: ResourceVector -> ResourceVector -> ResourceVector
plusVector left right =
  ResourceVector
    { resourceCpuMilli = resourceCpuMilli left + resourceCpuMilli right
    , resourceMemoryMib = resourceMemoryMib left + resourceMemoryMib right
    , resourceEphemeralMib = resourceEphemeralMib left + resourceEphemeralMib right
    , resourcePersistenceMib = resourcePersistenceMib left + resourcePersistenceMib right
    }

scaleVector :: Natural -> ResourceVector -> ResourceVector
scaleVector count vector =
  ResourceVector
    { resourceCpuMilli = count * resourceCpuMilli vector
    , resourceMemoryMib = count * resourceMemoryMib vector
    , resourceEphemeralMib = count * resourceEphemeralMib vector
    , resourcePersistenceMib = count * resourcePersistenceMib vector
    }

renderEnvelope :: EnvelopeSlice -> Text
renderEnvelope slice =
  Text.intercalate
    ":"
    [ envelopeSliceName slice
    , Text.pack (show (envelopeSliceReplicas slice))
    , renderResourceVector (envelopeSlicePerReplica slice)
    ]

renderResourceVector :: ResourceVector -> Text
renderResourceVector vector =
  Text.intercalate
    ","
    [ Text.pack (show (resourceCpuMilli vector))
    , Text.pack (show (resourceMemoryMib vector))
    , Text.pack (show (resourceEphemeralMib vector))
    , Text.pack (show (resourcePersistenceMib vector))
    ]

renderImage :: FrozenComponentImage -> Text
renderImage image =
  Text.pack (show (frozenImageComponent image))
    <> "=sha256:"
    <> renderPublicSha256 (frozenImageDigest image)

renderOpaqueBinding :: OpaqueFixtureBinding -> Text
renderOpaqueBinding binding = case binding of
  AuthorityReceiptBinding value -> "receipt=" <> value
  AuthorityGenerationBinding value -> "generation=" <> value
  VaultHmacBinding value -> "vault-hmac=" <> value

validOpaqueId :: Text -> Text -> Bool
validOpaqueId prefix value =
  case Text.stripPrefix prefix value of
    Nothing -> False
    Just suffix ->
      Text.length suffix >= 8
        && Text.length value <= 128
        && Text.all (\character -> isAlphaNum character || character == '-') suffix
        && not (validSha256 suffix)

mkPublicSha256 :: Text -> Maybe PublicSha256
mkPublicSha256 rawDigest = do
  digest <- Text.stripPrefix "sha256:" rawDigest
  if validSha256 digest then Just (PublicSha256 digest) else Nothing

validSha256 :: Text -> Bool
validSha256 digest = Text.length digest == 64 && Text.all isLowerHex digest
 where
  isLowerHex character = isDigit character || character >= 'a' && character <= 'f'

renderPublicSha256 :: PublicSha256 -> Text
renderPublicSha256 (PublicSha256 digest) = digest

duplicateValues :: (Ord value) => [value] -> [value]
duplicateValues values =
  [ value
  | duplicate@(value : _) <- group (sort values)
  , length duplicate > 1
  ]

digestCanonical :: [Text] -> PublicSha256
digestCanonical = PublicSha256 . sha256Hex . ByteString.concat . map encodeText

encodeText :: Text -> ByteString
encodeText value =
  let bytes = TextEncoding.encodeUtf8 value
   in ByteString8.pack (show (ByteString.length bytes)) <> ":" <> bytes

sha256Hex :: ByteString -> Text
sha256Hex = Text.pack . concatMap renderByte . ByteString.unpack . SHA256.hash
 where
  renderByte byte =
    let rendered = showHex byte ""
     in if length rendered == 1 then '0' : rendered else rendered
