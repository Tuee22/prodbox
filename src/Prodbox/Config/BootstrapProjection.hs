{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | An authored bootstrap projection. It supplies candidate coordinates only;
-- it does not establish ownership, resource absence, or permission for effects.
module Prodbox.Config.BootstrapProjection
  ( BootstrapProjection
  , BootstrapProjectionError (..)
  , bootstrapScope
  , bootstrapKindPlan
  , bootstrapRootGeneration
  , bootstrapRuntimeSocket
  , validSocketPath
  , bootstrapNodeArtifact
  , bootstrapKindTool
  , ArtifactDeclaration (..)
  , BootstrapDraft (..)
  , BootstrapDraftPublicationError (..)
  , BootstrapDraftRecovery (..)
  , renderBootstrapDraft
  , renderBootstrapProjection
  , publishBootstrapDraft
  , recoverBootstrapDraft
  , prepareBootstrapRoot
  , readBootstrapProjection
  , decodeOptionalBootstrapSource
  , renderBootstrapTypesDhall
  )
where

import Control.Exception (IOException, try)
import Data.Either.Validation (Validation (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Dhall qualified
import Dhall.Core qualified as Core
import Numeric.Natural (Natural)
import Prodbox.Capacity.LegacyDhall qualified as LegacyDhall
import Prodbox.Config.DeploymentScope
  ( DeploymentEnvironment (..)
  , DeploymentScope
  , DeploymentScopeError
  , FreshScopeResult
  , ScopeGenerationObservation (..)
  , deploymentScope
  , observeScopeGeneration
  , prepareFreshScopeWithConfig
  , scopeApiPort
  , scopeEnvironment
  , scopeIdentifier
  , scopeProjectAnchor
  , scopeRoot
  , validArtifactDeclaration
  , validRootGeneration
  )
import Prodbox.Config.KindPlan
  ( KindPlan
  , KindPlanError
  , PublicationMapping (..)
  , kindPlan
  , kindPlanMappings
  , kindPlanNodeImage
  )
import Prodbox.Config.SelectedDhall
  ( SelectedDhallError
  , SelectedDhallPublication (..)
  , publishNewSelectedDhall
  , readSelectedDhall
  , recoverSelectedDhall
  , validateSelectedDhallSource
  )
import Prodbox.Settings.Coordinate (ipLiteralText, mkIpLiteral)
import System.Directory (makeAbsolute)
import System.FilePath (isAbsolute, normalise, splitDirectories, takeDirectory, takeFileName, (</>))

data BootstrapProjection = BootstrapProjection
  { bootstrapScope :: !DeploymentScope
  , bootstrapKindPlan :: !KindPlan
  , bootstrapRootGeneration :: !Text
  , bootstrapRuntimeSocket :: !FilePath
  , bootstrapNodeArtifact :: !(Maybe ArtifactDeclaration)
  , bootstrapKindTool :: !(Maybe ArtifactDeclaration)
  }
  deriving (Eq, Show)

data ArtifactDeclaration = ArtifactDeclaration
  { artifactPath :: !FilePath
  , artifactDigest :: !String
  , artifactMaximumBytes :: !Integer
  }
  deriving (Eq, Show)

-- | Non-secret fields needed to author the version-3 bootstrap projection.
-- Rendering is not validation; callers must pass the resulting document
-- through 'decodeOptionalBootstrapSource' before publication.
data BootstrapDraft = BootstrapDraft
  { draftProjectAnchor :: !Text
  , draftRuntimeSocket :: !Text
  , draftEnvironment :: !Text
  , draftDeploymentId :: !Text
  , draftRootGeneration :: !Text
  , draftApiPort :: !Natural
  , draftNodeImage :: !Text
  , draftHttpHostPort :: !Natural
  , draftHttpNodePort :: !Natural
  , draftHttpsHostPort :: !Natural
  , draftHttpsNodePort :: !Natural
  , draftListenAddress :: !Text
  , draftNodePath :: !Text
  , draftNodeDigest :: !Text
  , draftNodeMaximumBytes :: !Natural
  , draftKindPath :: !Text
  , draftKindDigest :: !Text
  , draftKindMaximumBytes :: !Natural
  }
  deriving (Eq, Show)

data BootstrapDraftPublicationError
  = BootstrapDraftInvalid !BootstrapProjectionError
  | BootstrapDraftUnsafeDestination
  | BootstrapDraftRootUnavailable
  | BootstrapDraftRootChanged !SelectedDhallPublication
  | BootstrapDraftPublication !SelectedDhallPublication
  deriving (Eq, Show)

data BootstrapDraftRecovery = BootstrapRecoveryPublished | BootstrapRecoveryAlreadyMatches
  deriving (Eq, Show)

-- | Validate the exact rendered document and publish it only to the selected
-- non-secret configuration path. The document must be in its own root's
-- config directory; no deployment or cluster effect is performed here.
publishBootstrapDraft :: FilePath -> BootstrapDraft -> IO (Either BootstrapDraftPublicationError ())
publishBootstrapDraft selected draft = do
  result <- runBootstrapPublication publishNewSelectedDhall selected draft
  pure $ case result of
    Left failure -> Left failure
    Right SelectedDhallPublished -> Right ()
    Right outcome -> Left (BootstrapDraftPublication outcome)

recoverBootstrapDraft
  :: FilePath -> BootstrapDraft -> IO (Either BootstrapDraftPublicationError BootstrapDraftRecovery)
recoverBootstrapDraft selected draft = do
  result <- runBootstrapPublication recoverSelectedDhall selected draft
  pure $ case result of
    Left failure -> Left failure
    Right SelectedDhallPublished -> Right BootstrapRecoveryPublished
    Right SelectedDhallAlreadyMatches -> Right BootstrapRecoveryAlreadyMatches
    Right outcome -> Left (BootstrapDraftPublication outcome)

runBootstrapPublication
  :: (FilePath -> Text -> IO SelectedDhallPublication)
  -> FilePath
  -> BootstrapDraft
  -> IO (Either BootstrapDraftPublicationError SelectedDhallPublication)
runBootstrapPublication publish selected draft = do
  validated <- validateDraftDestination selected draft
  case validated of
    Left failure -> pure (Left failure)
    Right (scope, absolute) -> do
      initial <- draftRootMatches scope draft
      if not initial
        then pure (Left BootstrapDraftRootUnavailable)
        else do
          outcome <- publish absolute (renderBootstrapDraft draft)
          final <- draftRootMatches scope draft
          pure $
            if not final
              then Left (BootstrapDraftRootChanged outcome)
              else Right outcome

-- | Only the exact validated destination may request fresh enrollment.
-- An existing or incomplete root is returned unchanged for explicit recovery.
prepareBootstrapRoot
  :: FilePath -> BootstrapDraft -> IO (Either BootstrapDraftPublicationError FreshScopeResult)
prepareBootstrapRoot selected draft = do
  validated <- validateDraftDestination selected draft
  case validated of
    Left failure -> pure (Left failure)
    Right (scope, _) -> Right <$> prepareFreshScopeWithConfig scope (Text.unpack (draftRootGeneration draft))

validateDraftDestination
  :: FilePath -> BootstrapDraft -> IO (Either BootstrapDraftPublicationError (DeploymentScope, FilePath))
validateDraftDestination selected draft = do
  decoded <- decodeOptionalBootstrapSource selected (renderBootstrapDraft draft)
  case decoded of
    Left failure -> pure (Left (BootstrapDraftInvalid failure))
    Right Nothing -> pure (Left (BootstrapDraftInvalid BootstrapDecodeError))
    Right (Just projection) -> do
      location <- try (makeAbsolute selected)
      let scope = bootstrapScope projection
      pure $ case location of
        Left (_ :: IOException) -> Left BootstrapDraftUnsafeDestination
        Right absolute
          | normalise absolute /= absolute || takeFileName absolute /= "prodbox.dhall" ->
              Left BootstrapDraftUnsafeDestination
          | takeDirectory absolute /= scopeRoot scope </> "config" ->
              Left BootstrapDraftUnsafeDestination
          | otherwise -> Right (scope, absolute)

draftRootMatches :: DeploymentScope -> BootstrapDraft -> IO Bool
draftRootMatches scope draft =
  (== Right ScopeGenerationMatches)
    <$> observeScopeGeneration scope (Text.unpack (draftRootGeneration draft))

-- Dhall's encoder quotes and escapes every Text value; values cannot insert
-- imports or expressions into the rendered document.
renderBootstrapDraft :: BootstrapDraft -> Text
renderBootstrapDraft draft =
  Text.unlines
    [ "{ bootstrap ="
    , "  { schema_version = 3"
    , textField "project_anchor" (draftProjectAnchor draft)
    , textField "runtime_socket" (draftRuntimeSocket draft)
    , textField "environment" (draftEnvironment draft)
    , textField "deployment_id" (draftDeploymentId draft)
    , textField "root_generation" (draftRootGeneration draft)
    , naturalField "api_port" (draftApiPort draft)
    , textField "node_image" (draftNodeImage draft)
    , naturalField "http_host_port" (draftHttpHostPort draft)
    , naturalField "http_node_port" (draftHttpNodePort draft)
    , naturalField "https_host_port" (draftHttpsHostPort draft)
    , naturalField "https_node_port" (draftHttpsNodePort draft)
    , textField "listen_address" (draftListenAddress draft)
    , artifactField
        "node_artifact"
        (draftNodePath draft)
        (draftNodeDigest draft)
        (draftNodeMaximumBytes draft)
    , artifactField
        "kind_tool"
        (draftKindPath draft)
        (draftKindDigest draft)
        (draftKindMaximumBytes draft)
    , "  }"
    , "}"
    ]
 where
  textField name value = "  , " <> name <> " = " <> textValue value
  naturalField name value = "  , " <> name <> " = " <> Text.pack (show value)
  artifactField name path digest limit =
    "  , "
      <> name
      <> " = { path = "
      <> textValue path
      <> ", digest = "
      <> textValue digest
      <> ", maximum_bytes = "
      <> Text.pack (show limit)
      <> " }"
  textValue value = Core.pretty (Core.denote (Dhall.embed (Dhall.inject :: Dhall.Encoder Text) value))

-- | Render only the already validated non-secret bootstrap projection. The
-- kind family needs both artifact declarations; older incomplete projections
-- are refused rather than supplied with invented values.
renderBootstrapProjection :: BootstrapProjection -> Maybe Text
renderBootstrapProjection projection = do
  node <- bootstrapNodeArtifact projection
  tool <- bootstrapKindTool projection
  let scope = bootstrapScope projection
      plan = bootstrapKindPlan projection
      (http, https) = kindPlanMappings plan
      natural = fromIntegral
      environment = case scopeEnvironment scope of Production -> "production"; Test -> "test"
  if publicationListenAddress http /= publicationListenAddress https
    || artifactMaximumBytes node <= 0
    || artifactMaximumBytes tool <= 0
    then Nothing
    else
      pure
        ( renderBootstrapDraft
            BootstrapDraft
              { draftProjectAnchor = Text.pack (scopeProjectAnchor scope)
              , draftRuntimeSocket = Text.pack (bootstrapRuntimeSocket projection)
              , draftEnvironment = environment
              , draftDeploymentId = Text.pack (scopeIdentifier scope)
              , draftRootGeneration = bootstrapRootGeneration projection
              , draftApiPort = natural (scopeApiPort scope)
              , draftNodeImage = Text.pack (kindPlanNodeImage plan)
              , draftHttpHostPort = natural (publicationHostPort http)
              , draftHttpNodePort = natural (publicationNodePort http)
              , draftHttpsHostPort = natural (publicationHostPort https)
              , draftHttpsNodePort = natural (publicationNodePort https)
              , draftListenAddress = ipLiteralText (publicationListenAddress http)
              , draftNodePath = Text.pack (artifactPath node)
              , draftNodeDigest = Text.pack (artifactDigest node)
              , draftNodeMaximumBytes = fromInteger (artifactMaximumBytes node)
              , draftKindPath = Text.pack (artifactPath tool)
              , draftKindDigest = Text.pack (artifactDigest tool)
              , draftKindMaximumBytes = fromInteger (artifactMaximumBytes tool)
              }
        )

data BootstrapProjectionError
  = BootstrapSourceError !SelectedDhallError
  | BootstrapDecodeError
  | BootstrapUnsupportedVersion
  | BootstrapInvalidEnvironment
  | BootstrapInvalidGeneration
  | BootstrapInvalidPort
  | BootstrapInvalidListenAddress
  | BootstrapInvalidRuntimeSocket
  | BootstrapInvalidArtifact
  | BootstrapInvalidKindTool
  | BootstrapContextUnobservable
  | BootstrapContextIdentityMismatch
  | BootstrapInvalidScope !DeploymentScopeError
  | BootstrapInvalidKindPlan !KindPlanError
  deriving (Eq, Show)

data AuthoredBootstrap
  = AuthoredBootstrap
      !Natural
      !Text
      !Text
      !Text
      !Text
      !Text
      !Natural
      !Text
      !Natural
      !Natural
      !Natural
      !Natural
      !Text

bootstrapDecoder :: Dhall.Decoder AuthoredBootstrap
bootstrapDecoder = Dhall.record bootstrapFields

bootstrapDecoderV2 :: Dhall.Decoder AuthoredBootstrap
bootstrapDecoderV2 = Dhall.record $ const <$> bootstrapFields <*> Dhall.field "node_artifact" artifactDecoder

bootstrapDecoderV3 :: Dhall.Decoder AuthoredBootstrap
bootstrapDecoderV3 =
  Dhall.record $
    (\fields _ _ -> fields)
      <$> bootstrapFields
      <*> Dhall.field "node_artifact" artifactDecoder
      <*> Dhall.field "kind_tool" artifactDecoder

-- | Structural field types come from the exact decoders used above. Semantic
-- constraints such as version numbers, digests and disjoint paths are checked
-- separately by 'decodeOptionalBootstrapSource'.
renderBootstrapTypesDhall :: Either String Text
renderBootstrapTypesDhall = do
  first <- renderType bootstrapDecoder
  second <- renderType bootstrapDecoderV2
  third <- renderType bootstrapDecoderV3
  pure $
    Text.unlines
      [ "-- Generated from the versioned bootstrap decoders by prodbox config schema."
      , "-- These types describe fields only; prodbox config validate checks semantic constraints."
      , "{ Version1 = " <> first
      , ", Version2 = " <> second
      , ", Version3 = " <> third
      , "}"
      ]
 where
  renderType decoder = case Dhall.expected decoder of
    Success value -> Right (Core.pretty value)
    Failure _ -> Left "Cannot derive bootstrap schema from its decoder."

artifactDecoder :: Dhall.Decoder (Text, Text, Natural)
artifactDecoder =
  Dhall.record $
    (,,)
      <$> Dhall.field "path" Dhall.auto
      <*> Dhall.field "digest" Dhall.auto
      <*> Dhall.field "maximum_bytes" Dhall.auto

bootstrapFields :: Dhall.RecordDecoder AuthoredBootstrap
bootstrapFields =
  AuthoredBootstrap
    <$> Dhall.field "schema_version" Dhall.auto
    <*> Dhall.field "project_anchor" Dhall.auto
    <*> Dhall.field "runtime_socket" Dhall.auto
    <*> Dhall.field "environment" Dhall.auto
    <*> Dhall.field "deployment_id" Dhall.auto
    <*> Dhall.field "root_generation" Dhall.auto
    <*> Dhall.field "api_port" Dhall.auto
    <*> Dhall.field "node_image" Dhall.auto
    <*> Dhall.field "http_host_port" Dhall.auto
    <*> Dhall.field "http_node_port" Dhall.auto
    <*> Dhall.field "https_host_port" Dhall.auto
    <*> Dhall.field "https_node_port" Dhall.auto
    <*> Dhall.field "listen_address" Dhall.auto

-- | Parse only the bootstrap field from the same selected source snapshot.
-- Other fields are not decoded as application, AWS, SES, or ACME settings.
readBootstrapProjection :: FilePath -> IO (Either BootstrapProjectionError BootstrapProjection)
readBootstrapProjection path = do
  selected <- readSelectedDhall path
  case selected of
    Left failure -> pure (Left (BootstrapSourceError failure))
    Right source -> do
      parsed <- decodeOptionalBootstrapSource path source
      pure $ parsed >>= maybe (Left BootstrapDecodeError) Right

-- | Validate a bootstrap field when present in the supplied selected-source
-- snapshot. An absent field is distinct from a present but malformed field.
decodeOptionalBootstrapSource
  :: FilePath -> Text -> IO (Either BootstrapProjectionError (Maybe BootstrapProjection))
decodeOptionalBootstrapSource path source = case validateSelectedDhallSource source of
  Left failure -> pure (Left (BootstrapSourceError failure))
  Right () -> do
    parsed <- LegacyDhall.decodeDhallRecordFieldFromSource bootstrapDecoder "bootstrap" path source
    second <- case parsed of
      Right (Just (fields, Nothing))
        | "bootstrap" `elem` fields ->
            LegacyDhall.decodeDhallRecordFieldFromSource bootstrapDecoderV2 "bootstrap" path source
      _ -> pure parsed
    alternative <- case second of
      Right (Just (fields, Nothing))
        | "bootstrap" `elem` fields ->
            LegacyDhall.decodeDhallRecordFieldFromSource bootstrapDecoderV3 "bootstrap" path source
      _ -> pure second
    case alternative of
      Right (Just (fields, decoded))
        | "bootstrap" `notElem` fields -> pure (Right Nothing)
        | otherwise -> case decoded of
            Nothing -> pure (Left BootstrapDecodeError)
            Just authored -> case validateBootstrap authored of
              Left failure -> pure (Left failure)
              Right projection -> do
                artifact <- decodeArtifact path source authored
                tool <- decodeKindTool path source authored
                case (artifact, tool) of
                  (Left failure, _) -> pure (Left failure)
                  (_, Left failure) -> pure (Left failure)
                  (Right (Just declaration), Right (Just kindTool))
                    | artifactPath declaration == artifactPath kindTool -> pure (Left BootstrapInvalidKindTool)
                  (Right declaration, Right kindTool) ->
                    checkContext fields (projection {bootstrapNodeArtifact = declaration, bootstrapKindTool = kindTool})
      _ -> pure (Left BootstrapDecodeError)
 where
  checkContext fields projection
    | "context" `notElem` fields = pure (Right (Just projection))
    | otherwise = do
        contextId <-
          LegacyDhall.decodeDhallSourceProjection
            Dhall.auto
            LegacyDhall.CompleteDocument
            path
            ("(\n" <> source <> "\n).context.cluster_id")
        pure $ case contextId of
          Left _ -> Left BootstrapContextUnobservable
          Right identity
            | identity == Text.pack (scopeIdentifier (bootstrapScope projection)) -> Right (Just projection)
            | otherwise -> Left BootstrapContextIdentityMismatch

-- The version 1 format predates retained archive declarations. Version 2
-- requires one, and a version 1 declaration is refused instead of ignored.
decodeArtifact
  :: FilePath
  -> Text
  -> AuthoredBootstrap
  -> IO (Either BootstrapProjectionError (Maybe ArtifactDeclaration))
decodeArtifact path source (AuthoredBootstrap version _ _ _ _ _ _ _ _ _ _ _ _) = do
  let nested = "(\n" <> source <> "\n).bootstrap"
  result <- LegacyDhall.decodeDhallRecordFieldFromSource artifactDecoder "node_artifact" path nested
  pure $ case result of
    Right (Just (fields, decoded))
      | version == 1 && "node_artifact" `notElem` fields -> Right Nothing
      | version == 2 || version == 3 -> case decoded of
          Just (artifact, digest, maximumBytes)
            | validArtifactDeclaration
                (Text.unpack artifact)
                (Text.unpack digest)
                (toInteger (maximumBytes :: Natural)) ->
                Right
                  (Just (ArtifactDeclaration (Text.unpack artifact) (Text.unpack digest) (toInteger maximumBytes)))
          _ -> Left BootstrapInvalidArtifact
    _ -> Left BootstrapInvalidArtifact

decodeKindTool
  :: FilePath
  -> Text
  -> AuthoredBootstrap
  -> IO (Either BootstrapProjectionError (Maybe ArtifactDeclaration))
decodeKindTool path source (AuthoredBootstrap version _ _ _ _ _ _ _ _ _ _ _ _) = do
  let nested = "(\n" <> source <> "\n).bootstrap"
  result <- LegacyDhall.decodeDhallRecordFieldFromSource artifactDecoder "kind_tool" path nested
  pure $ case result of
    Right (Just (fields, decoded))
      | version `elem` [1, 2] && "kind_tool" `notElem` fields -> Right Nothing
      | version == 3 -> case decoded of
          Just (artifact, digest, maximumBytes)
            | validArtifactDeclaration (Text.unpack artifact) (Text.unpack digest) (toInteger maximumBytes)
                && maximumBytes <= 128 * 1024 * 1024 ->
                Right
                  (Just (ArtifactDeclaration (Text.unpack artifact) (Text.unpack digest) (toInteger maximumBytes)))
          _ -> Left BootstrapInvalidKindTool
    _ -> Left BootstrapInvalidKindTool

validateBootstrap :: AuthoredBootstrap -> Either BootstrapProjectionError BootstrapProjection
validateBootstrap
  ( AuthoredBootstrap
      version
      anchor
      runtimeSocket
      environment
      identifier
      generation
      api
      image
      httpHost
      httpNode
      httpsHost
      httpsNode
      address
    ) = do
    if version `elem` [1, 2, 3] then Right () else Left BootstrapUnsupportedVersion
    if validSocketPath (Text.unpack runtimeSocket) then Right () else Left BootstrapInvalidRuntimeSocket
    selectedEnvironment <- case environment of
      "production" -> Right Production
      "test" -> Right Test
      _ -> Left BootstrapInvalidEnvironment
    if validRootGeneration (Text.unpack generation) then Right () else Left BootstrapInvalidGeneration
    apiPort <- port api
    httpHostPort <- port httpHost
    httpNodePort <- port httpNode
    httpsHostPort <- port httpsHost
    httpsNodePort <- port httpsNode
    listen <- either (const (Left BootstrapInvalidListenAddress)) Right (mkIpLiteral address)
    scope <-
      either
        (Left . BootstrapInvalidScope)
        Right
        (deploymentScope (Text.unpack anchor) selectedEnvironment (Text.unpack identifier) apiPort)
    plan <-
      either (Left . BootstrapInvalidKindPlan) Right $
        kindPlan
          scope
          (Text.unpack image)
          (PublicationMapping httpHostPort httpNodePort listen)
          (PublicationMapping httpsHostPort httpsNodePort listen)
    pure (BootstrapProjection scope plan generation (Text.unpack runtimeSocket) Nothing Nothing)
   where
    port value
      | value > 0 && value <= 65535 = Right (fromIntegral value)
      | otherwise = Left BootstrapInvalidPort

validSocketPath :: FilePath -> Bool
validSocketPath path =
  isAbsolute path
    && length path <= 4096
    && normalise path == path
    && all (`notElem` path) ['\0', '\n', '\r', '?', '#']
    && all (`notElem` [".", ".."]) (splitDirectories path)
