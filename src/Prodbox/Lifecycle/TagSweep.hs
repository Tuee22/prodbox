{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 4.11: postflight tag-sweep helpers for destructive
-- lifecycle commands. The doctrine in
-- @documents/engineering/lifecycle_reconciliation_doctrine.md § 6@
-- mandates that every destructive lifecycle command end with a call
-- to 'discoverClusterTaggedAwsResources' (and, for the long-lived
-- classes, the equivalent long-lived-tag query). A non-empty result
-- is a hard failure.
--
-- This sprint introduces the Pulumi-tracked residue path only.
-- Sprint 4.12 extends the scan to the full cluster-tag query
-- (@kubernetes.io/cluster/<cluster-name>@ + @prodbox.io/*@) once the
-- K8s drain phase lands.
module Prodbox.Lifecycle.TagSweep
  ( TaggedResource (..)
  , TagSweepInput (..)
  , discoverClusterTaggedAwsResources
  , renderTagSweepRefusal
  )
where

import Data.Aeson
  ( Value (..)
  , eitherDecode
  )
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Prodbox.Result (Result (..))
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  )
import System.Exit (ExitCode (..))

-- | Input to the tag-sweep discoverer. The caller supplies the
-- @aws@-CLI environment (operational @aws.*@ or admin credentials)
-- and the tag-filter expressions. Two filter classes are supported:
-- the @kubernetes.io/cluster/<cluster-name>@ family (EKS-tagged AWS
-- resources surface here) and the prodbox-owned @prodbox.io/*@ tag
-- family.
data TagSweepInput = TagSweepInput
  { tagSweepEnvironment :: [(String, String)]
  , tagSweepClusterName :: Maybe String
  -- ^ Used to build the @kubernetes.io/cluster/<name>@ filter when
  -- the operator has named the cluster.
  , tagSweepWorkingDirectory :: Maybe FilePath
  }
  deriving (Eq, Show)

-- | One AWS resource returned by the tag-sweep. Holds the resource's
-- ARN and the tag key that caused it to surface (used in the refusal
-- message so operators can see *why* each resource counted).
data TaggedResource = TaggedResource
  { taggedResourceArn :: String
  , taggedResourceMatchedTagKey :: String
  }
  deriving (Eq, Show)

-- | Query the AWS Resource Tagging API for any resource carrying a
-- prodbox-owned tag. Returns @Right []@ when the sweep is clean.
-- A non-empty list is a hard failure for any destructive lifecycle
-- command's postflight; the caller composes 'renderTagSweepRefusal'
-- to produce the stderr block.
discoverClusterTaggedAwsResources
  :: TagSweepInput -> IO (Either String [TaggedResource])
discoverClusterTaggedAwsResources input = do
  let filterArgs = tagFilterArgs input
  result <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "aws"
        , subprocessArguments =
            [ "resourcegroupstaggingapi"
            , "get-resources"
            , "--output"
            , "json"
            ]
              ++ filterArgs
        , subprocessEnvironment = Just (tagSweepEnvironment input)
        , subprocessWorkingDirectory = tagSweepWorkingDirectory input
        }
  pure $ case result of
    Failure err -> Left ("failed to start `aws resourcegroupstaggingapi`: " ++ err)
    Success output ->
      case processExitCode output of
        ExitFailure _ ->
          Left
            ( "aws resourcegroupstaggingapi get-resources failed: "
                ++ processStderr output
                ++ processStdout output
            )
        ExitSuccess -> parseTagSweepPayload (processStdout output)

tagFilterArgs :: TagSweepInput -> [String]
tagFilterArgs input =
  let clusterFilter = case tagSweepClusterName input of
        Nothing -> []
        Just name ->
          [ "--tag-filters"
          , "Key=kubernetes.io/cluster/" ++ name
          ]
      prodboxFilter =
        [ "--tag-filters"
        , "Key=prodbox.io/managed-by,Values=prodbox"
        ]
   in clusterFilter ++ prodboxFilter

parseTagSweepPayload :: String -> Either String [TaggedResource]
parseTagSweepPayload payload = do
  value <- eitherDecode (BL8.pack payload) :: Either String Value
  case value of
    Object obj -> case KeyMap.lookup "ResourceTagMappingList" obj of
      Just (Array entries) ->
        pure (concatMap parseEntry (Vector.toList entries))
      _ -> Right []
    _ -> Right []
 where
  parseEntry :: Value -> [TaggedResource]
  parseEntry entry = case entry of
    Object obj ->
      case KeyMap.lookup "ResourceARN" obj of
        Just (String arnText) ->
          let arn = Text.unpack arnText
              tagList = case KeyMap.lookup "Tags" obj of
                Just (Array tags) -> Vector.toList tags
                _ -> []
           in [ TaggedResource arn (Text.unpack key)
              | Object tagObj <- tagList
              , Just (String key) <- [KeyMap.lookup "Key" tagObj]
              ]
        _ -> []
    _ -> []

renderTagSweepRefusal :: [TaggedResource] -> String
renderTagSweepRefusal resources =
  unlines
    ( [ "Postflight tag sweep refused: AWS resources carrying prodbox or"
      , "cluster tags still exist after the destructive command completed."
      , ""
      , "These resources escaped the per-stack destroys and the K8s drain"
      , "phase; manual cleanup is required before the operator can claim"
      , "the teardown finished cleanly:"
      , ""
      ]
        ++ map renderResource resources
    )
 where
  renderResource resource =
    "  - "
      ++ taggedResourceArn resource
      ++ " (matched tag: "
      ++ taggedResourceMatchedTagKey resource
      ++ ")"
