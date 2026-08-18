{-# LANGUAGE OverloadedStrings #-}

-- | Whether the terminal escape audit can see what this repository creates.
--
-- "Prodbox.Lifecycle.Teardown.RetainedInventory" supplies the two catalogs the
-- audit decides with: the retained matchers, and the queries whose union is the
-- audit's field of view.  Everything outside that union is not merely unmatched
-- — it is never returned at all, so an escapee there cannot become
-- 'Prodbox.Lifecycle.Teardown.Observation.TerminalAuditFoundEscapes'.  A clean
-- verdict over a field of view that excludes a resource says nothing about that
-- resource while reading exactly like a statement that it is gone.
--
-- The query catalog's completeness was therefore a load-bearing claim joined to
-- nothing: it is a list of tag families, and whether those families actually
-- cover the resources prodbox creates is a fact about the provisioning programs
-- under @pulumi\/@, which no code read.  Measuring it found the claim false —
-- every resource of the @aws-test@ substrate stack, and the EKS cluster, node
-- group, addon, and IAM identities of @aws-eks@, carried only a @Name@ tag, so
-- a leaked EC2 instance or EKS cluster was structurally invisible to the audit
-- that exists to find it.
--
-- This module is the join.  It classifies each declared resource into the
-- audit's field of view or out of it, and it is deliberately __total in the
-- refusing direction__: a resource type it does not recognize is a violation
-- rather than an assumption, so adding a resource type to a provisioning
-- program forces a deliberate statement about whether the audit can see it.
--
-- It answers one of the two questions reach turns on — /does the program
-- author a tag the audit asks for?/ — which is a fact about the provisioning
-- program and holds in every region.  The other — /was the query issued in a
-- region that answers for this service?/ — is a fact about the audited scope
-- and lives in "Prodbox.Lifecycle.Teardown.TaggingApiReach", where the
-- audit-time verdict consumes it.  Keeping them apart is deliberate: authoring
-- a tag is a correction to a program, while a region blind spot is a bound on
-- what a clean verdict may claim.
module Prodbox.Lifecycle.Teardown.AuditFieldOfView
  ( -- * Declared resources
    DeclaredAwsResource (..)
  , ProvisioningProgramParseError (..)
  , renderProvisioningProgramParseError
  , parseProvisioningProgram

    -- * The field of view
  , AuditFieldOfView (..)
  , classifyAuditFieldOfView
  , auditFieldOfViewViolations
  )
where

import Data.Char (isAlphaNum)
import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Lifecycle.Teardown.RetainedInventory
  ( TerminalAuditQuery (AuditQueryTagKey, AuditQueryTagPair)
  , auditQueryCoversTag
  , clusterOwnershipTagPrefix
  )
import Prodbox.Lifecycle.Teardown.TaggingApiReach
  ( TaggingApiReach (NotAnAwsResource, UntaggableByTaggingApi)
  , classifyTaggingApiReach
  )

-- | One resource a provisioning program declares, as parsed from its source.
--
-- The tag list is the tag set the program authors onto the resource, which is
-- the only thing that decides whether a discovery query can return it.
data DeclaredAwsResource = DeclaredAwsResource
  { declaredResourceProgram :: !Text
  -- ^ The provisioning program directory, for example @aws-eks@.
  , declaredResourceName :: !Text
  -- ^ The logical name the program gives the resource.
  , declaredResourceType :: !Text
  -- ^ The provider type token, for example @aws:ec2:Instance@.
  , declaredResourceTags :: ![(Text, Text)]
  -- ^ Authored tag key\/value pairs, in declaration order.
  }
  deriving (Eq, Ord, Show)

-- | Why a provisioning program could not be read as a resource declaration.
--
-- Every arm is a refusal rather than a recovery.  A program this parser cannot
-- read completely is a program whose resources cannot be checked, and silently
-- checking the subset it did understand would reproduce the defect the module
-- exists to close.
data ProvisioningProgramParseError
  = -- | The program declares no @resources:@ section.
    ProgramHasNoResourcesSection !Text
  | -- | The @resources:@ section declared no resource at all.  A program that
    -- parses to nothing is indistinguishable from a fully covered one, so it
    -- refuses instead.
    ProgramDeclaresNoResources !Text
  | -- | A declared resource carries no @type:@, so its reach is unknowable.
    ProgramResourceHasNoType !Text !Text
  | -- | One logical name was declared twice, so classification would not be a
    -- function of the name.
    ProgramResourceDeclaredTwice !Text !Text
  | -- | A @tags:@ block appeared at an indentation this parser does not model,
    -- so the tag set it read may be incomplete.
    ProgramTagBlockNotRecognized !Text !Int
  deriving (Eq, Show)

renderProvisioningProgramParseError :: ProvisioningProgramParseError -> String
renderProvisioningProgramParseError err = case err of
  ProgramHasNoResourcesSection program ->
    "pulumi/" ++ Text.unpack program ++ "/Main.yaml declares no `resources:` section."
  ProgramDeclaresNoResources program ->
    "pulumi/"
      ++ Text.unpack program
      ++ "/Main.yaml declares no resources; the terminal-audit field-of-view join "
      ++ "cannot treat an empty parse as full coverage."
  ProgramResourceHasNoType program name ->
    "pulumi/"
      ++ Text.unpack program
      ++ "/Main.yaml resource `"
      ++ Text.unpack name
      ++ "` declares no `type:`."
  ProgramResourceDeclaredTwice program name ->
    "pulumi/"
      ++ Text.unpack program
      ++ "/Main.yaml declares resource `"
      ++ Text.unpack name
      ++ "` more than once."
  ProgramTagBlockNotRecognized program indentation ->
    "pulumi/"
      ++ Text.unpack program
      ++ "/Main.yaml has a `tags:` block indented "
      ++ show indentation
      ++ " columns; the field-of-view parser only models resource-property tags."

-- | Where one declared resource sits relative to the audit's field of view.
data AuditFieldOfView
  = -- | A discovery query returns it, and this is the tag key that does.
    WithinAuditFieldOfView !Text
  | -- | Its type puts it outside: no tag surface, or not an AWS resource.
    OutsideFieldOfViewByType !TaggingApiReach
  | -- | Its type accepts tags the audit asks for, and it carries none of them.
    -- This is the defect arm: the resource exists, can be tagged, and is
    -- invisible to the audit anyway.
    OutsideFieldOfViewUntagged
  | -- | The type is unclassified, so its reach is unknown.
    FieldOfViewUnclassifiedType !Text
  deriving (Eq, Show)

classifyAuditFieldOfView
  :: [TerminalAuditQuery] -> DeclaredAwsResource -> AuditFieldOfView
classifyAuditFieldOfView queries resource =
  case classifyTaggingApiReach (declaredResourceType resource) of
    Nothing -> FieldOfViewUnclassifiedType (declaredResourceType resource)
    Just reach@(UntaggableByTaggingApi _) -> OutsideFieldOfViewByType reach
    Just reach@(NotAnAwsResource _) -> OutsideFieldOfViewByType reach
    Just _ ->
      case filter (auditQueryCoversTag queries) (declaredResourceTags resource) of
        (key, _) : _ -> WithinAuditFieldOfView key
        [] -> OutsideFieldOfViewUntagged

-- | The join.  Every taggable AWS resource the repository provisions must carry
-- a tag the terminal audit asks for; an unclassified type refuses.
auditFieldOfViewViolations :: [TerminalAuditQuery] -> [DeclaredAwsResource] -> [String]
auditFieldOfViewViolations queries resources =
  [ violation
  | resource <- resources
  , Just violation <- [violationFor resource]
  ]
 where
  violationFor resource = case classifyAuditFieldOfView queries resource of
    WithinAuditFieldOfView _ -> Nothing
    OutsideFieldOfViewByType _ -> Nothing
    FieldOfViewUnclassifiedType resourceType ->
      Just
        ( subject resource
            ++ " declares the unclassified provider type `"
            ++ Text.unpack resourceType
            ++ "`. Classify its Tagging API reach in "
            ++ "Prodbox.Lifecycle.Teardown.AuditFieldOfView before it ships."
        )
    OutsideFieldOfViewUntagged ->
      Just
        ( subject resource
            ++ " ("
            ++ Text.unpack (declaredResourceType resource)
            ++ ") carries no tag the terminal audit queries for"
            ++ renderAuthoredTags (declaredResourceTags resource)
            ++ ", so a leaked instance of it is outside the audit's field of "
            ++ "view and a clean verdict says nothing about it. Author one of: "
            ++ renderQueries queries
            ++ "."
        )

  subject resource =
    "pulumi/"
      ++ Text.unpack (declaredResourceProgram resource)
      ++ "/Main.yaml resource `"
      ++ Text.unpack (declaredResourceName resource)
      ++ "`"

  renderAuthoredTags [] = " (it authors no tags)"
  renderAuthoredTags tags =
    " (it authors "
      ++ Text.unpack (Text.intercalate ", " (map fst tags))
      ++ ")"

  renderQueries =
    Text.unpack . Text.intercalate ", " . nub . map renderQuery

  -- The cluster-ownership query carries whatever cluster name the catalog was
  -- evaluated at, and this message is about the family, so it renders the
  -- family rather than one binding's name.
  renderQuery query = case query of
    AuditQueryTagKey key
      | clusterOwnershipTagPrefix `Text.isPrefixOf` key ->
          clusterOwnershipTagPrefix <> "<cluster>"
      | otherwise -> key
    AuditQueryTagPair key value -> key <> "=" <> value

-- | Read one provisioning program's resource declarations.
--
-- The parser models exactly the committed shape — a column-zero @resources:@
-- section, two-column logical names, four-column @type:@, and a six-column
-- @tags:@ block of eight-column pairs — and refuses anything else rather than
-- reading past it.  It is a reader for a checked property, not a general YAML
-- loader; every shape it declines is a build failure that names the line.
parseProvisioningProgram
  :: Text
  -- ^ The program directory name.
  -> Text
  -- ^ The program source.
  -> Either ProvisioningProgramParseError [DeclaredAwsResource]
parseProvisioningProgram program source
  | not hasResourcesSection = Left (ProgramHasNoResourcesSection program)
  | otherwise = do
      _ <- unexpectedTagBlock
      declarations <- traverse declaration (resourceBlocks sectionLines)
      case duplicateNames declarations of
        name : _ -> Left (ProgramResourceDeclaredTwice program name)
        [] ->
          if null declarations
            then Left (ProgramDeclaresNoResources program)
            else Right declarations
 where
  sourceLines = Text.lines source

  -- Presence of the section and emptiness of its body are separate facts: a
  -- program that declares `resources:` and nothing under it must refuse as
  -- empty rather than as missing, because the two have different corrections.
  hasResourcesSection = "resources:" `elem` sourceLines

  sectionLines =
    case break (== "resources:") sourceLines of
      (_, _ : rest) -> takeWhile (not . startsTopLevelKey) rest
      _ -> []

  startsTopLevelKey line =
    not (Text.null line) && not (" " `Text.isPrefixOf` line)

  -- Every `tags:` in the section must be the six-column property form the
  -- classifier reads.  One at another depth means the committed shape moved and
  -- the tag sets read here may be partial.
  unexpectedTagBlock =
    case [ indentationOf line
         | line <- sectionLines
         , Text.strip line == "tags:"
         , indentationOf line /= tagBlockIndentation
         ] of
      indentation : _ -> Left (ProgramTagBlockNotRecognized program indentation)
      [] -> Right ()

  resourceBlocks [] = []
  resourceBlocks (line : rest) = case resourceName line of
    Nothing -> resourceBlocks rest
    Just name ->
      let (body, remaining) = break isResourceHeader rest
       in (name, body) : resourceBlocks remaining

  isResourceHeader line = case resourceName line of
    Nothing -> False
    Just _ -> True

  resourceName line
    | indentationOf line /= resourceIndentation = Nothing
    | not (":" `Text.isSuffixOf` stripped) = Nothing
    | Text.null name = Nothing
    | not (Text.all isLogicalNameCharacter name) = Nothing
    | otherwise = Just name
   where
    stripped = Text.strip line
    name = Text.dropEnd 1 stripped

  declaration (name, body) = case declaredType body of
    Nothing -> Left (ProgramResourceHasNoType program name)
    Just resourceType ->
      Right
        DeclaredAwsResource
          { declaredResourceProgram = program
          , declaredResourceName = name
          , declaredResourceType = resourceType
          , declaredResourceTags = declaredTags body
          }

  declaredType body =
    case [ Text.strip value
         | line <- body
         , indentationOf line == typeIndentation
         , Just value <- [Text.stripPrefix "type:" (Text.strip line)]
         ] of
      value : _ | not (Text.null value) -> Just value
      _ -> Nothing

  declaredTags body =
    case break isTagHeader body of
      (_, _ : rest) ->
        [ (Text.strip key, unquote (Text.strip (Text.drop 1 value)))
        | line <- takeWhile ((== tagPairIndentation) . indentationOf) rest
        , let (key, value) = Text.breakOn ":" line
        , not (Text.null value)
        ]
      _ -> []

  isTagHeader line =
    Text.strip line == "tags:" && indentationOf line == tagBlockIndentation

  duplicateNames declarations =
    [ name
    | name <- nub (map declaredResourceName declarations)
    , length (filter ((== name) . declaredResourceName) declarations) > 1
    ]

  unquote value
    | Text.length value >= 2
    , "\"" `Text.isPrefixOf` value
    , "\"" `Text.isSuffixOf` value =
        Text.dropEnd 1 (Text.drop 1 value)
    | otherwise = value

indentationOf :: Text -> Int
indentationOf = Text.length . Text.takeWhile (== ' ')

-- | A logical resource name.  Restricting the alphabet is what keeps an
-- indented comment that happens to end in a colon from being read as a resource
-- declaration with no type.
isLogicalNameCharacter :: Char -> Bool
isLogicalNameCharacter character =
  isAlphaNum character || character == '_' || character == '-'

resourceIndentation :: Int
resourceIndentation = 2

typeIndentation :: Int
typeIndentation = 4

tagBlockIndentation :: Int
tagBlockIndentation = 6

tagPairIndentation :: Int
tagPairIndentation = 8
