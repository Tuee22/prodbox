{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 5.28: sole owner of the throwaway Route 53 hosted zone the
-- @dns-aws@ canonical-suite validation creates.
--
-- Sprint 5.18 promised to register this zone by account, region, caller
-- reference, name, and operation, to read back its deletion, and to remove the
-- @create-hosted-zone@ carve-out from the create-site coverage lint. None of
-- that landed. The zone was created inline in @Prodbox.TestValidation@, deleted
-- only along the validation's own return path, and never observed absent — so a
-- mid-validation exception or a cancelled run left a billable hosted zone that
-- nothing swept and nothing reported.
--
-- The carve-out that made this legal justified itself by pointing at a
-- @bracketOnError@-wrapped capability probe in
-- @Prodbox.EffectInterpreter@. That probe no longer exists, which left the
-- carve-out protecting an unbracketed create.
--
-- This module is the registered owner: it holds the create verb, the delete
-- verb, the absence read-back, and the prefix sweep that the always-run cleanup
-- DAG calls whether or not the validation reached its own cleanup. Discovery is
-- by the @prodbox-dns-aws-@ name prefix, which is also the caller reference, so
-- a zone leaked by any path is still discoverable by identity rather than by
-- having been remembered in process memory.
module Prodbox.Infra.Route53ValidationZone
  ( validationHostedZoneNamePrefix
  , validationHostedZoneName
  , validationHostedZoneCallerReference
  , validationHostedZoneTagPairs
  , validationHostedZoneTagCommand
  , bareHostedZoneId
  , createValidationHostedZone
  , deleteValidationHostedZone
  , discoverValidationHostedZones
  , destroyValidationHostedZones
  , parseHostedZoneListing
  )
where

import Control.Monad (foldM, void)
import Data.Aeson (Value (Array, Object, String), eitherDecode, encode)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as LazyChar8
import Data.List (isInfixOf, isPrefixOf)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Prodbox.Lifecycle.OwnedResourceTags qualified as OwnedResourceTags
import Prodbox.Result (Result (..))
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessResult
  )
import System.Exit (ExitCode (..))

-- | Every zone this module creates is named and caller-referenced with this
-- prefix. It is the identity the sweep discovers by.
validationHostedZoneNamePrefix :: String
validationHostedZoneNamePrefix = "prodbox-dns-aws-"

validationHostedZoneName :: String -> String -> String
validationHostedZoneName nonce baseZoneName =
  validationHostedZoneNamePrefix ++ nonce ++ "." ++ baseZoneName

validationHostedZoneCallerReference :: String -> String
validationHostedZoneCallerReference nonce = validationHostedZoneNamePrefix ++ nonce

-- | Create the throwaway zone, author its owned tags, and return its
-- hosted-zone id.
--
-- Sprint 4.85: the zone was created carrying __no tag at all__. The terminal
-- escape audit decides over what its tag queries return, so an untagged zone is
-- returned by no query — a leaked billable hosted zone was structurally
-- invisible to the audit that exists to find it, while a clean verdict read
-- like a statement that it was gone. Route 53 hosted zones are taggable, the
-- Resource Groups Tagging API returns them from the global-service region, and
-- the registered IAM policy already grants @route53:ChangeTagsForResource@, so
-- nothing but the missing call stood in the way.
--
-- The tag set comes from 'OwnedResourceTags.codeCreatedAwsResourceTags' rather
-- than being written out here, so the writer and the audit's query catalog hold
-- one value; @prodbox dev check@ fails if a family here is outside that
-- catalog.
--
-- A tagging failure fails the create. The zone still exists at that point and
-- is deliberately __not__ deleted here: discovery is by the
-- 'validationHostedZoneNamePrefix' that is also its caller reference, so the
-- always-run sweep still removes it. Reporting the failure and leaving a
-- prefix-discoverable zone is strictly safer than reporting success with a zone
-- the audit cannot see.
createValidationHostedZone
  :: FilePath
  -> [(String, String)]
  -> String
  -> String
  -> IO (Either String String)
createValidationHostedZone repoRoot awsEnvironment zoneName callerReference = do
  createResult <-
    captureText
      repoRoot
      awsEnvironment
      [ "route53"
      , "create-hosted-zone"
      , "--name"
      , zoneName
      , "--caller-reference"
      , callerReference
      , "--query"
      , "HostedZone.Id"
      , "--output"
      , "text"
      ]
  case trim <$> createResult of
    Left err -> pure (Left err)
    Right hostedZoneId -> do
      tagged <- tagValidationHostedZone repoRoot awsEnvironment hostedZoneId
      pure (hostedZoneId <$ tagged)

-- | Author and read back the owned tags on one validation hosted zone.
--
-- The read-back is the point, for the same reason the delete has one: a
-- @change-tags-for-resource@ that returns success while the tags are absent
-- would leave the zone outside the audit's field of view while this function
-- reported it inside.
tagValidationHostedZone
  :: FilePath
  -> [(String, String)]
  -> String
  -> IO (Either String ())
tagValidationHostedZone repoRoot awsEnvironment hostedZoneId = do
  tagResult <-
    captureText
      repoRoot
      awsEnvironment
      (validationHostedZoneTagCommand hostedZoneId)
  case tagResult of
    Left err ->
      pure
        ( Left
            ( "Route 53 hosted zone "
                ++ hostedZoneId
                ++ " could not be tagged, so the terminal escape audit would "
                ++ "never return it: "
                ++ err
            )
        )
    Right _ -> do
      listed <-
        captureText
          repoRoot
          awsEnvironment
          [ "route53"
          , "list-tags-for-resource"
          , "--resource-type"
          , "hostedzone"
          , "--resource-id"
          , bareHostedZoneId hostedZoneId
          , "--output"
          , "json"
          ]
      pure $ case listed of
        Left err ->
          Left
            ( "Route 53 hosted zone "
                ++ hostedZoneId
                ++ " tags could not be read back: "
                ++ err
            )
        Right rendered
          | all (tagPresentIn rendered) validationHostedZoneTagPairs -> Right ()
          | otherwise ->
              Left
                ( "Route 53 hosted zone "
                    ++ hostedZoneId
                    ++ " does not read back every owned tag after "
                    ++ "change-tags-for-resource reported success."
                )
 where
  tagPresentIn rendered (key, value) =
    key `isInfixOf` rendered && value `isInfixOf` rendered

-- | The exact @change-tags-for-resource@ invocation, as data, so a unit case
-- can pin its shape without an AWS call.
validationHostedZoneTagCommand :: String -> [String]
validationHostedZoneTagCommand hostedZoneId =
  [ "route53"
  , "change-tags-for-resource"
  , "--resource-type"
  , "hostedzone"
  , "--resource-id"
  , bareHostedZoneId hostedZoneId
  , "--add-tags"
  ]
    ++ [ "Key=" ++ key ++ ",Value=" ++ value
       | (key, value) <- validationHostedZoneTagPairs
       ]

-- | The owned tag families this zone carries, as @String@ pairs.
validationHostedZoneTagPairs :: [(String, String)]
validationHostedZoneTagPairs =
  [ (Text.unpack key, Text.unpack value)
  | (key, value) <-
      OwnedResourceTags.codeCreatedAwsResourceTags
        OwnedResourceTags.DnsValidationHostedZone
  ]

-- | @create-hosted-zone@ returns @\/hostedzone\/ZONEID@, while the tagging
-- API takes the bare id. Stripping the prefix here keeps every caller free to
-- pass whichever form it holds.
bareHostedZoneId :: String -> String
bareHostedZoneId hostedZoneId =
  case reverse (takeWhile (/= '/') (reverse hostedZoneId)) of
    "" -> hostedZoneId
    bare -> bare

-- | Delete a zone and prove it absent. The read-back is the point: a
-- @delete-hosted-zone@ that returns success while the zone survives (a retried
-- change batch, an eventually-consistent read) would otherwise be recorded as
-- cleanup.
deleteValidationHostedZone
  :: FilePath
  -> [(String, String)]
  -> String
  -> IO (Either String ())
deleteValidationHostedZone repoRoot awsEnvironment hostedZoneId = do
  deleteResult <-
    captureText
      repoRoot
      awsEnvironment
      ["route53", "delete-hosted-zone", "--id", hostedZoneId]
  case deleteResult of
    Left err -> pure (Left err)
    Right _ -> observeAbsent
 where
  observeAbsent = do
    getResult <-
      captureText
        repoRoot
        awsEnvironment
        ["route53", "get-hosted-zone", "--id", hostedZoneId, "--output", "json"]
    pure $ case getResult of
      Left err
        -- Absence is proved only by the API saying the zone does not exist.
        -- Any other failure -- throttling, a dropped connection, an expired
        -- credential -- means the zone could not be observed, and
        -- cannot-observe is never absence
        -- (lifecycle_reconciliation_doctrine.md section 3.1).
        | zoneNotFound err -> Right ()
        | otherwise ->
            Left
              ( "Route 53 hosted zone "
                  ++ hostedZoneId
                  ++ " could not be observed after delete-hosted-zone: "
                  ++ err
              )
      Right _ ->
        Left
          ( "Route 53 hosted zone "
              ++ hostedZoneId
              ++ " still resolves after delete-hosted-zone reported success."
          )

  zoneNotFound err = any (`isInfixOf` err) ["NoSuchHostedZone", "HostedZoneNotFound"]

-- | Every validation-owned hosted zone currently present, as
-- @(hostedZoneId, zoneName)@ pairs.
discoverValidationHostedZones
  :: FilePath
  -> [(String, String)]
  -> IO (Either String [(String, String)])
discoverValidationHostedZones repoRoot awsEnvironment = do
  listResult <-
    captureText
      repoRoot
      awsEnvironment
      ["route53", "list-hosted-zones", "--output", "json"]
  pure (listResult >>= parseHostedZoneListing)

-- | Pure projection of an @aws route53 list-hosted-zones@ payload down to the
-- validation-owned zones. Exposed for unit tests.
parseHostedZoneListing :: String -> Either String [(String, String)]
parseHostedZoneListing payload =
  case eitherDecode (LazyChar8.pack payload) of
    Left err -> Left ("Unable to decode hosted-zone listing: " ++ err)
    Right value -> Right (ownedZones value)
 where
  ownedZones value =
    [ (zoneId, zoneName)
    | Object zone <- zoneEntries value
    , Just (String zoneIdText) <- [KeyMap.lookup (Key.fromString "Id") zone]
    , let zoneId = Text.unpack zoneIdText
    , Just (String zoneNameText) <- [KeyMap.lookup (Key.fromString "Name") zone]
    , let zoneName = Text.unpack zoneNameText
    , validationHostedZoneNamePrefix `isPrefixOf` zoneName
    ]

  zoneEntries value = case value of
    Object payloadObject ->
      case KeyMap.lookup (Key.fromString "HostedZones") payloadObject of
        Just (Array zones) -> Vector.toList zones
        _ -> []
    _ -> []

-- | The registered destroy action: sweep every validation-owned zone, deleting
-- its record sets first (Route 53 refuses to delete a non-empty zone), and
-- aggregate rather than short-circuit so one stuck zone cannot hide the others.
destroyValidationHostedZones :: FilePath -> [(String, String)] -> IO ExitCode
destroyValidationHostedZones repoRoot awsEnvironment = do
  discovered <- discoverValidationHostedZones repoRoot awsEnvironment
  case discovered of
    -- Cannot observe is never silently treated as absent
    -- (lifecycle_reconciliation_doctrine.md section 3.1).
    Left _ -> pure (ExitFailure 1)
    Right zones -> foldM destroyOne ExitSuccess zones
 where
  destroyOne accumulated (hostedZoneId, _) = do
    pruned <- pruneRecordSets hostedZoneId
    deleted <- deleteValidationHostedZone repoRoot awsEnvironment hostedZoneId
    pure $ case (accumulated, pruned, deleted) of
      (ExitSuccess, Right (), Right ()) -> ExitSuccess
      _ -> ExitFailure 1

  -- Delete every non-SOA/NS record so the zone becomes deletable.
  pruneRecordSets hostedZoneId = do
    listed <-
      captureText
        repoRoot
        awsEnvironment
        [ "route53"
        , "list-resource-record-sets"
        , "--hosted-zone-id"
        , hostedZoneId
        , "--query"
        , "ResourceRecordSets[?Type != 'SOA' && Type != 'NS']"
        , "--output"
        , "json"
        ]
    case listed of
      Left err -> pure (Left err)
      Right payload -> case eitherDecode (LazyChar8.pack payload) of
        Left err -> pure (Left ("Unable to decode record sets: " ++ err))
        Right (Array records)
          | Vector.null records -> pure (Right ())
          | otherwise -> deleteBatch hostedZoneId (Vector.toList records)
        Right _ -> pure (Right ())

  deleteBatch hostedZoneId records = do
    let changeBatch = renderDeleteBatch records
    result <-
      captureText
        repoRoot
        awsEnvironment
        [ "route53"
        , "change-resource-record-sets"
        , "--hosted-zone-id"
        , hostedZoneId
        , "--change-batch"
        , changeBatch
        ]
    pure (void result)

  renderDeleteBatch records =
    LazyChar8.unpack
      ( "{\"Changes\":["
          <> LazyChar8.intercalate "," (map renderDelete records)
          <> "]}"
      )

  renderDelete record =
    "{\"Action\":\"DELETE\",\"ResourceRecordSet\":" <> encode record <> "}"

captureText :: FilePath -> [(String, String)] -> [String] -> IO (Either String String)
captureText repoRoot awsEnvironment arguments = do
  outputResult <-
    captureSubprocessResult
      Subprocess
        { subprocessPath = "aws"
        , subprocessArguments = arguments
        , subprocessEnvironment = Just awsEnvironment
        , subprocessWorkingDirectory = Just repoRoot
        }
  pure $ case outputResult of
    Failure err -> Left err
    Success output -> case processExitCode output of
      ExitSuccess -> Right (processStdout output)
      ExitFailure code ->
        Left
          ( "aws "
              ++ unwords arguments
              ++ " failed with exit code "
              ++ show code
              ++ ": "
              ++ processStderr output
          )

trim :: String -> String
trim = dropWhile (`elem` whitespace) . reverse . dropWhile (`elem` whitespace) . reverse
 where
  whitespace = " \n\r\t" :: String
