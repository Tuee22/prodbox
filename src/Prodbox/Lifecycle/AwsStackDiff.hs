{-# LANGUAGE OverloadedStrings #-}

-- | A names-only projection of the pinned Pulumi PreviewDigest schema.
-- Schema: pulumi/pulumi v3.228.0, pkg/display/json.go. Values, configuration,
-- provider references and diagnostics have no field in the resulting type.
module Prodbox.Lifecycle.AwsStackDiff
  ( PreviewOperation (..)
  , PreviewChange (..)
  , StackPreview
  , stackPreviewChanges
  , decodePulumiStackPreview
  , encodeStackPreviewEvidence
  , decodeStackPreviewEvidence
  , renderStackPreview
  )
where

import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isControl)
import Data.List (sortOn)
import Data.Scientific (toBoundedInteger)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Vector qualified as Vector
import Prodbox.Lifecycle.ProviderWorker.Evidence (maximumStackPreviewEvidenceBytes)
import Prodbox.Subprocess (ProcessOutput (..))
import System.Exit (ExitCode (ExitSuccess))

data PreviewOperation
  = PreviewSame
  | PreviewCreate
  | PreviewUpdate
  | PreviewDelete
  | PreviewReplace
  | PreviewCreateReplacement
  | PreviewDeleteReplaced
  | PreviewRead
  | PreviewReadReplacement
  | PreviewRefresh
  | PreviewDiscard
  | PreviewDiscardReplaced
  | PreviewRemovePendingReplace
  | PreviewImport
  | PreviewImportReplacement
  deriving (Bounded, Enum, Eq, Ord, Show)

data PreviewChange = PreviewChange
  { previewResourceUrn :: !Text
  , previewResourceOperation :: !PreviewOperation
  , previewResourceProperties :: ![Text]
  }
  deriving (Eq, Show)

newtype StackPreview = StackPreview {stackPreviewChanges :: [PreviewChange]}
  deriving (Eq, Show)

operationText :: PreviewOperation -> Text
operationText operation = case operation of
  PreviewSame -> "same"
  PreviewCreate -> "create"
  PreviewUpdate -> "update"
  PreviewDelete -> "delete"
  PreviewReplace -> "replace"
  PreviewCreateReplacement -> "create-replacement"
  PreviewDeleteReplaced -> "delete-replaced"
  PreviewRead -> "read"
  PreviewReadReplacement -> "read-replacement"
  PreviewRefresh -> "refresh"
  PreviewDiscard -> "discard"
  PreviewDiscardReplaced -> "discard-replaced"
  PreviewRemovePendingReplace -> "remove-pending-replace"
  PreviewImport -> "import"
  PreviewImportReplacement -> "import-replacement"

parseOperation :: Text -> Either Text PreviewOperation
parseOperation value =
  maybe
    (Left "Pulumi preview operation is unsupported")
    Right
    (lookup value [(operationText operation, operation) | operation <- [minBound .. maxBound]])

decodePulumiStackPreview :: ProcessOutput -> Either Text StackPreview
decodePulumiStackPreview output
  | processExitCode output /= ExitSuccess = Left "Pulumi preview did not complete successfully"
  | otherwise = do
      root <- decodeObject (Text.pack (processStdout output))
      case KeyMap.lookup "maybeCorrupt" root of
        Nothing -> Right ()
        Just (Bool False) -> Right ()
        _ -> Left "Pulumi preview did not establish a usable checkpoint"
      summary <- case KeyMap.lookup "changeSummary" root of
        Just (Object values) -> Right values
        _ -> Left "Pulumi preview has no complete change summary"
      mapM_ validateSummary (KeyMap.toList summary)
      validateDiagnostics (KeyMap.lookup "diagnostics" root)
      steps <- optionalArray "steps" root
      if null steps && any (/= Number 0) (KeyMap.elems summary)
        then Left "Pulumi preview summary has no resource steps"
        else Right ()
      changes <- traverse decodeStep steps
      Right
        ( StackPreview
            ( sortOn
                (\change -> (previewResourceUrn change, previewResourceOperation change))
                [change | change <- changes, previewResourceOperation change /= PreviewSame]
            )
        )
 where
  validateSummary (key, value) = do
    _ <- parseOperation (Key.toText key)
    case value of
      Number count | Just total <- (toBoundedInteger count :: Maybe Int), total >= 0 -> Right ()
      _ -> Left "Pulumi preview summary count is malformed"
  validateDiagnostics Nothing = Right ()
  validateDiagnostics (Just Null) = Right ()
  validateDiagnostics (Just (Array values)) = mapM_ validateDiagnostic values
  validateDiagnostics _ = Left "Pulumi preview diagnostics are malformed"
  validateDiagnostic (Object row) = case KeyMap.lookup "severity" row of
    Just (String "error") -> Left "Pulumi preview reported an error"
    Just (String _) -> Right ()
    Nothing -> Right ()
    _ -> Left "Pulumi preview diagnostic severity is malformed"
  validateDiagnostic _ = Left "Pulumi preview diagnostic is malformed"

decodeStep :: Value -> Either Text PreviewChange
decodeStep (Object row) = do
  urn <- textField "urn" row >>= validateUrn
  operation <- textField "op" row >>= parseOperation
  reasons <- optionalNames "diffReasons" row
  replacements <- optionalNames "replaceReasons" row
  detailed <- case KeyMap.lookup "detailedDiff" row of
    Nothing -> Right []
    Just Null -> Right []
    Just (Object values) -> traverse validatePropertyDiff (KeyMap.toList values)
    _ -> Left "Pulumi preview detailed diff is malformed"
  stateNames <- case operation of
    PreviewSame -> Right []
    PreviewUpdate -> Right []
    PreviewReplace -> Right []
    PreviewRefresh -> Right []
    PreviewRemovePendingReplace -> Right []
    PreviewCreate -> inputNames "newState" row
    PreviewCreateReplacement -> inputNames "newState" row
    PreviewRead -> inputNames "newState" row
    PreviewReadReplacement -> inputNames "newState" row
    PreviewImport -> inputNames "newState" row
    PreviewImportReplacement -> inputNames "newState" row
    PreviewDelete -> inputNames "oldState" row
    PreviewDeleteReplaced -> inputNames "oldState" row
    PreviewDiscard -> inputNames "oldState" row
    PreviewDiscardReplaced -> inputNames "oldState" row
  Right
    ( PreviewChange
        urn
        operation
        (Set.toAscList (Set.fromList (reasons <> replacements <> detailed <> stateNames)))
    )
decodeStep _ = Left "Pulumi preview step is malformed"

validatePropertyDiff :: (Key.Key, Value) -> Either Text Text
validatePropertyDiff (name, Object value) = do
  case KeyMap.lookup "kind" value of
    Just (String kind)
      | kind `elem` ["add", "add-replace", "delete", "delete-replace", "update", "update-replace"] ->
          Right ()
    _ -> Left "Pulumi preview property change kind is malformed"
  validateName (Key.toText name)
validatePropertyDiff _ = Left "Pulumi preview property diff is malformed"

inputNames :: Key.Key -> KeyMap.KeyMap Value -> Either Text [Text]
inputNames key row = case KeyMap.lookup key row of
  Nothing -> Right []
  Just Null -> Right []
  Just (Object state) -> case KeyMap.lookup "inputs" state of
    Nothing -> Right []
    Just Null -> Right []
    Just (Object values) -> traverse (validateName . Key.toText) (KeyMap.keys values)
    _ -> Left "Pulumi preview inputs are malformed"
  _ -> Left "Pulumi preview resource state is malformed"

optionalNames :: Key.Key -> KeyMap.KeyMap Value -> Either Text [Text]
optionalNames key row = optionalArray key row >>= traverse name
 where
  name (String value) = validateName value
  name _ = Left "Pulumi preview property name is malformed"

optionalArray :: Key.Key -> KeyMap.KeyMap Value -> Either Text [Value]
optionalArray key row = case KeyMap.lookup key row of
  Nothing -> Right []
  Just Null -> Right []
  Just (Array values) -> Right (Vector.toList values)
  _ -> Left "Pulumi preview list is malformed"

textField :: Key.Key -> KeyMap.KeyMap Value -> Either Text Text
textField key row = case KeyMap.lookup key row of
  Just (String value) -> Right value
  _ -> Left "Pulumi preview required text field is absent"

validateName :: Text -> Either Text Text
validateName value
  | Text.null value || Text.length value > 1024 || Text.any isControl value =
      Left "Pulumi preview identifier is not bounded printable text"
  | otherwise = Right value

validateUrn :: Text -> Either Text Text
validateUrn value
  | "urn:pulumi:" `Text.isPrefixOf` value = validateName value
  | otherwise = Left "Pulumi preview resource URN is malformed"

decodeObject :: Text -> Either Text (KeyMap.KeyMap Value)
decodeObject input
  | Text.length input > 2 * 1024 * 1024 = Left "Pulumi preview exceeded its decode bound"
  | otherwise = case eitherDecodeStrict' (TextEncoding.encodeUtf8 input) of
      Right (Object value) -> Right value
      _ -> Left "Pulumi preview output is not a JSON object"

encodeStackPreviewEvidence :: Text -> StackPreview -> Either Text Text
encodeStackPreviewEvidence stack preview =
  let encoded =
        LazyByteString.toStrict
          ( encode
              ( object
                  [ "schema" .= ("prodbox-stack-preview/v1" :: Text)
                  , "stack" .= stack
                  , "changes" .= map changeValue (stackPreviewChanges preview)
                  ]
              )
          )
   in if ByteString.length encoded > maximumStackPreviewEvidenceBytes
        then Left "redacted Pulumi preview exceeded its evidence bound"
        else Right (TextEncoding.decodeUtf8 encoded)
 where
  changeValue change =
    object
      [ "resource" .= previewResourceUrn change
      , "operation" .= operationText (previewResourceOperation change)
      , "properties" .= previewResourceProperties change
      ]

decodeStackPreviewEvidence :: Text -> Text -> Either Text StackPreview
decodeStackPreviewEvidence expectedStack evidence = do
  row <- decodeObject evidence
  schema <- textField "schema" row
  stack <- textField "stack" row
  if schema == "prodbox-stack-preview/v1" && stack == expectedStack
    then Right ()
    else Left "redacted Pulumi preview binding differs"
  values <- case KeyMap.lookup "changes" row of
    Just (Array changes) -> Right (Vector.toList changes)
    _ -> Left "redacted Pulumi preview changes are absent"
  StackPreview <$> traverse changeFromWire values
 where
  changeFromWire (Object row) = do
    urn <- textField "resource" row >>= validateUrn
    operation <- textField "operation" row >>= parseOperation
    properties <- optionalNames "properties" row
    Right (PreviewChange urn operation properties)
  changeFromWire _ = Left "redacted Pulumi preview change is malformed"

renderStackPreview :: Text -> StackPreview -> [Text]
renderStackPreview stack preview =
  ( "AWS_STACK_DIFF stack="
      <> stack
      <> " steps="
      <> Text.pack (show (length (stackPreviewChanges preview)))
  )
    : [ operationText (previewResourceOperation change)
          <> " "
          <> previewResourceUrn change
          <> " properties="
          <> Text.intercalate "," (previewResourceProperties change)
      | change <- stackPreviewChanges preview
      ]
