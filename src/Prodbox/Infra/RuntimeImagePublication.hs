{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Runtime publication ends only after CRI can name the exact repository
-- manifest. A config-only Docker archive is not that observation: containerd
-- may later replace its public image reference with a repository digest.
module Prodbox.Infra.RuntimeImagePublication
  ( RuntimeImageExpectation
  , RuntimeRegistryReference
  , runtimeRegistryManifestUrl
  , decodeRuntimeRegistryReference
  , RuntimeImageObservation
  , RuntimePublicationReady
  , RuntimeReferenceDecision (..)
  , RuntimeReadPhase (..)
  , RuntimeReadFailure (..)
  , RuntimeExpectationFailure (..)
  , RuntimeManifestFetchResult (..)
  , RuntimePublicationError (..)
  , RuntimePublicationEffects (..)
  , runtimeImageTagReference
  , runtimeImageManifestReference
  , runtimeImageConfigDigest
  , decodeRuntimeImageExpectation
  , decodeRuntimeImageObservation
  , decideRuntimeImageReference
  , reconcileRuntimeImageReference
  , renderRuntimePublicationError
  )
where

import Data.Aeson (FromJSON (..), eitherDecodeStrict', withObject, (.:))
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as ByteStringChar8
import Data.Char (isAsciiUpper)
import Data.List (nub, stripPrefix)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.ContainerImage qualified as ContainerImage

-- These identities name different layers. No constructor converts one digest
-- into the other; the CRI readback must positively bind them.
data RuntimeImageExpectation = RuntimeImageExpectation
  { runtimeImageTagReference :: !String
  , runtimeImageConfigDigest :: !String
  , runtimeImageManifestReference :: !String
  }
  deriving stock (Eq, Show)

newtype RuntimeRegistryReference = RuntimeRegistryReference String
  deriving stock (Eq, Show)

data RuntimeImageObservation = RuntimeImageObservation
  { observedConfigDigest :: !String
  , observedTags :: ![String]
  , observedRepositoryReferences :: ![String]
  }
  deriving stock (Eq, Show)

newtype RuntimePublicationReady = RuntimePublicationReady RuntimeImageExpectation
  deriving stock (Eq, Show)

data RuntimeExpectationFailure
  = RuntimeImageTagInvalid
  | RuntimeHostPlatformUnsupported
  | RuntimeManifestConfigInvalid
  | RuntimeManifestObservationUnavailable
  | RuntimeManifestBodyUnavailable
  | RuntimeManifestBodyInvalid
  | RuntimeManifestDigestMismatch
  | RuntimeManifestObservationInvalid
  | RuntimeManifestMissing
  | RuntimeManifestAmbiguous
  deriving stock (Eq, Show)

data RuntimeReadFailure
  = RuntimeCRIUnavailable
  | RuntimeCRIDeadlineElapsed
  | RuntimeCRIMalformed
  | RuntimeCRIConfigMismatch
  | RuntimeCRITagBindingMismatch
  | RuntimeCRIReferenceMismatch
  | RuntimeCRIReferenceAmbiguous
  | RuntimeCRIReferenceNotVisible
  deriving stock (Eq, Show)

data RuntimeReadPhase = BeforeManifestRegistration | AfterManifestRegistration
  deriving stock (Eq, Show)

data RuntimeReferenceDecision
  = RuntimeReferenceReady !RuntimePublicationReady
  | RuntimeReferenceNeedsFetch
  | RuntimeReferenceRefused !RuntimeReadFailure
  deriving stock (Eq, Show)

data RuntimeManifestFetchResult
  = RuntimeManifestFetched
  | RuntimeManifestFetchExited !Int
  | RuntimeManifestFetchUnobservable
  deriving stock (Eq, Show)

data RuntimePublicationError
  = RuntimeExpectationRefused !RuntimeExpectationFailure
  | RuntimeObservationRefused !RuntimeReadPhase !RuntimeReadFailure
  | RuntimeRegistrationNotProven !RuntimeManifestFetchResult !RuntimeReadFailure
  deriving stock (Eq, Show)

data RuntimePublicationEffects m = RuntimePublicationEffects
  { observeRuntimeImage :: RuntimeReadPhase -> m (Either RuntimeReadFailure RuntimeImageObservation)
  , fetchRuntimeManifest :: RuntimeImageExpectation -> m RuntimeManifestFetchResult
  , waitBeforeRuntimeReadRetry :: m ()
  }

-- | Docker's local .Id is deliberately absent: its layer depends on the
-- daemon's image store. Only the exact published manifest supplies the config
-- commitment, after its descriptor bytes match the observed registry digest.
decodeRuntimeRegistryReference
  :: String -> String -> Either RuntimeExpectationFailure RuntimeRegistryReference
decodeRuntimeRegistryReference reference repositoryOutput = do
  case stripPrefix (runtimeRepository ++ ":") reference of
    Just tag@(first : remaining)
      | length tag <= 128 && validTagStart first && all validTagCharacter remaining -> Right ()
    _ -> Left RuntimeImageTagInvalid
  references <- case eitherDecodeStrict' (utf8 repositoryOutput) of
    Right values -> Right values
    Left _ -> Left RuntimeManifestObservationInvalid
  digests <- case repositoryDigests references of
    Left _ -> Left RuntimeManifestObservationInvalid
    Right values -> Right values
  case digests of
    [] -> Left RuntimeManifestMissing
    [value] -> Right (RuntimeRegistryReference value)
    _ -> Left RuntimeManifestAmbiguous

decodeRuntimeImageExpectation
  :: String -> String -> ByteString -> Either RuntimeExpectationFailure RuntimeImageExpectation
decodeRuntimeImageExpectation reference repositoryOutput body = do
  pinned@(RuntimeRegistryReference manifestDigest) <-
    decodeRuntimeRegistryReference reference repositoryOutput
  decoded <- case eitherDecodeStrict' body of
    Left _ -> Left RuntimeManifestBodyInvalid
    Right value -> Right value
  if manifestSchema decoded == 2
    && manifestMediaType decoded `elem` manifestMediaTypes
    && manifestConfigMediaType decoded `elem` configMediaTypes
    then Right ()
    else Left RuntimeManifestBodyInvalid
  let config = manifestConfigDigest decoded
  if validDigest config then Right () else Left RuntimeManifestConfigInvalid
  if "sha256:" ++ ByteStringChar8.unpack (hexSha256 body) == manifestDigest
    then Right ()
    else Left RuntimeManifestDigestMismatch
  pure (RuntimeImageExpectation reference config (runtimeReferenceText pinned))

runtimeReferenceText :: RuntimeRegistryReference -> String
runtimeReferenceText (RuntimeRegistryReference digest) = runtimeRepository ++ "@" ++ digest

runtimeRegistryManifestUrl :: RuntimeRegistryReference -> String
runtimeRegistryManifestUrl (RuntimeRegistryReference digest) =
  let (registry, repositoryPath) = break (== '/') runtimeRepository
   in "http://" ++ registry ++ "/v2" ++ repositoryPath ++ "/manifests/" ++ digest

data RuntimeManifest = RuntimeManifest
  { manifestSchema :: !Int
  , manifestMediaType :: !String
  , manifestConfigMediaType :: !String
  , manifestConfigDigest :: !String
  }

instance FromJSON RuntimeManifest where
  parseJSON = withObject "Runtime image manifest" $ \root -> do
    config <- root .: "config"
    RuntimeManifest
      <$> root .: "schemaVersion"
      <*> root .: "mediaType"
      <*> config .: "mediaType"
      <*> config .: "digest"

manifestMediaTypes, configMediaTypes :: [String]
manifestMediaTypes =
  [ "application/vnd.docker.distribution.manifest.v2+json"
  , "application/vnd.oci.image.manifest.v1+json"
  ]
configMediaTypes =
  [ "application/vnd.docker.container.image.v1+json"
  , "application/vnd.oci.image.config.v1+json"
  ]

-- | A missing/null field is an unavailable proof, never an empty reference set.
instance FromJSON RuntimeImageObservation where
  parseJSON = withObject "CRI image inspection" $ \root -> do
    status <- root .: "status"
    RuntimeImageObservation
      <$> status .: "id"
      <*> status .: "repoTags"
      <*> status .: "repoDigests"

decodeRuntimeImageObservation :: ByteString -> Either RuntimeReadFailure RuntimeImageObservation
decodeRuntimeImageObservation body = case eitherDecodeStrict' body of
  Left _ -> Left RuntimeCRIMalformed
  Right observed
    | validDigest (observedConfigDigest observed) -> Right observed
    | otherwise -> Left RuntimeCRIMalformed

decideRuntimeImageReference
  :: RuntimeImageExpectation -> RuntimeImageObservation -> RuntimeReferenceDecision
decideRuntimeImageReference expected observed
  | observedConfigDigest observed /= runtimeImageConfigDigest expected =
      RuntimeReferenceRefused RuntimeCRIConfigMismatch
  | runtimeImageTagReference expected `notElem` observedTags observed =
      RuntimeReferenceRefused RuntimeCRITagBindingMismatch
  | otherwise = case repositoryDigests (observedRepositoryReferences observed) of
      Left _ -> RuntimeReferenceRefused RuntimeCRIMalformed
      Right [] -> RuntimeReferenceNeedsFetch
      Right [digest]
        | runtimeRepository ++ "@" ++ digest == runtimeImageManifestReference expected ->
            RuntimeReferenceReady (RuntimePublicationReady expected)
        | otherwise -> RuntimeReferenceRefused RuntimeCRIReferenceMismatch
      Right _ -> RuntimeReferenceRefused RuntimeCRIReferenceAmbiguous

-- | One registration at most. Each phase has three finite observations under
-- the interpreter's shared absolute deadline. A lost reply can be adopted only
-- by the same complete closing proof; acknowledgement alone admits nothing.
reconcileRuntimeImageReference
  :: (Monad m)
  => RuntimePublicationEffects m
  -> RuntimeImageExpectation
  -> m (Either RuntimePublicationError RuntimePublicationReady)
reconcileRuntimeImageReference effects expected = do
  initial <- observeUntil BeforeManifestRegistration FirstRead
  case initial of
    RuntimeReferenceReady ready -> pure (Right ready)
    RuntimeReferenceRefused cause ->
      pure (Left (RuntimeObservationRefused BeforeManifestRegistration cause))
    RuntimeReferenceNeedsFetch -> do
      fetched <- fetchRuntimeManifest effects expected
      closing <- observeUntil AfterManifestRegistration FirstRead
      pure $ case closing of
        RuntimeReferenceReady ready -> Right ready
        RuntimeReferenceNeedsFetch ->
          Left (RuntimeRegistrationNotProven fetched RuntimeCRIReferenceNotVisible)
        RuntimeReferenceRefused cause -> Left (RuntimeRegistrationNotProven fetched cause)
 where
  observeUntil phase attempt = do
    result <- observeRuntimeImage effects phase
    let decision = either RuntimeReferenceRefused (decideRuntimeImageReference expected) result
    case decision of
      RuntimeReferenceReady _ -> pure decision
      RuntimeReferenceRefused RuntimeCRIDeadlineElapsed -> pure decision
      RuntimeReferenceNeedsFetch
        | phase == BeforeManifestRegistration -> pure decision
      _ -> case nextRead attempt of
        Nothing -> pure decision
        Just following -> do
          waitBeforeRuntimeReadRetry effects
          observeUntil phase following

data RuntimeReadAttempt = FirstRead | SecondRead | ThirdRead

nextRead :: RuntimeReadAttempt -> Maybe RuntimeReadAttempt
nextRead attempt = case attempt of
  FirstRead -> Just SecondRead
  SecondRead -> Just ThirdRead
  ThirdRead -> Nothing

renderRuntimePublicationError :: RuntimePublicationError -> String
renderRuntimePublicationError failure = case failure of
  RuntimeExpectationRefused cause -> "expectation/" ++ show cause
  RuntimeObservationRefused phase cause -> "observation/" ++ show phase ++ "/" ++ show cause
  RuntimeRegistrationNotProven result cause -> "registration/" ++ show result ++ "/" ++ show cause

runtimeRepository :: String
runtimeRepository = ContainerImage.harborRuntimeImageRepository

repositoryDigests :: [String] -> Either () [String]
repositoryDigests = fmap nub . foldr collect (Right [])
 where
  collect reference remaining = case stripPrefix (runtimeRepository ++ "@") reference of
    Nothing -> remaining
    Just digest
      | validDigest digest -> (digest :) <$> remaining
      | otherwise -> Left ()

validDigest :: String -> Bool
validDigest digest = case stripPrefix "sha256:" digest of
  Just hex -> length hex == 64 && all isHex hex
  Nothing -> False
 where
  isHex character = (character >= '0' && character <= '9') || (character >= 'a' && character <= 'f')

validTagStart :: Char -> Bool
validTagStart character =
  (character >= 'a' && character <= 'z')
    || isAsciiUpper character
    || (character >= '0' && character <= '9')
    || character == '_'

validTagCharacter :: Char -> Bool
validTagCharacter character =
  (character >= 'a' && character <= 'z')
    || isAsciiUpper character
    || (character >= '0' && character <= '9')
    || character `elem` ("_.-" :: String)

utf8 :: String -> ByteString
utf8 = TextEncoding.encodeUtf8 . Text.pack
