{-# LANGUAGE OverloadedStrings #-}

-- | The closed test-VPC plant and peer-rule repair. The registered native
-- families own every interruption prefix. All candidates are read and checked
-- before any mutation, and retries discover exact tagged shapes before creating.
module Prodbox.Lifecycle.AwsTestCanaryExecution
  ( CanaryPlantSnapshot
  , canaryPlantComplete
  , CanaryDependencyProbe (..)
  , observeTestVpcCanary
  , plantTestVpcCanary
  , clearTestCanaryReferences
  , canarySecurityGroupsQuery
  ) where

import Control.Monad (forM, forM_, unless, void)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT (..), runExceptT, throwE)
import Data.Aeson (ToJSON, Value (..), eitherDecodeStrict', encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bifunctor (first)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List (nub)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Vector qualified as Vector
import Prodbox.Aws.CliError (awsCliServiceErrorMatches)
import Prodbox.Lifecycle.AwsTestCanary
import Prodbox.Subprocess (ProcessOutput (..))
import System.Exit (ExitCode (..))

type AwsRun m = [String] -> m ProcessOutput

-- EC2 optional rule arrays may be omitted. The installed CLI loopback
-- recording pins their normalization while identity/ownership fields remain
-- required by the decoder.
canarySecurityGroupsQuery :: String
canarySecurityGroupsQuery =
  "SecurityGroups[].{id:GroupId,vpc:VpcId,name:GroupName,tags:Tags,ingress:not_null(IpPermissions[].{protocol:IpProtocol,from:FromPort,to:ToPort,peers:not_null(UserIdGroupPairs[].GroupId, `[]`),ipv4:not_null(IpRanges[].CidrIp, `[]`),ipv6:not_null(Ipv6Ranges[].CidrIpv6, `[]`),prefixes:not_null(PrefixListIds[].PrefixListId, `[]`)}, `[]`)}"

data Group = Group !Text !CanaryGroupShape ![Text]
  deriving (Eq, Show)

data CanaryPlantSnapshot = CanaryPlantSnapshot ![Group] !(Maybe Text)
  deriving (Eq, Show)

-- Raw errors are returned only to the recording scrubber at the interpreter
-- boundary. They are never rendered as an ordinary failure or evidence value.
data CanaryDependencyProbe = CanaryDependencyProbe
  { canaryProbeShape :: !CanaryGroupShape
  , canaryProbeOutput :: !ProcessOutput
  }
  deriving (Eq, Show)

canaryPlantComplete :: CanaryPlantSnapshot -> Bool
canaryPlantComplete (CanaryPlantSnapshot groups interface) =
  case ( groupByShape groups InterfaceHeldGroup
       , groupByShape groups MutualLeftGroup
       , groupByShape groups MutualRightGroup
       , interface
       ) of
    (Just (Group _ _ []), Just (Group left _ [leftPeer]), Just (Group right _ [rightPeer]), Just _) ->
      leftPeer == right && rightPeer == left
    _ -> False

observeTestVpcCanary
  :: (Monad m) => AwsRun m -> TestVpcCanaryRequest -> m (Either Text CanaryPlantSnapshot)
observeTestVpcCanary run request = runExceptT $ do
  checkVpcAndSubnet run request
  groups <- readGroups run request
  interface <- readInterface run request groups
  pure (CanaryPlantSnapshot groups interface)

plantTestVpcCanary
  :: (Monad m) => AwsRun m -> TestVpcCanaryRequest -> m (Either Text [CanaryDependencyProbe])
plantTestVpcCanary run request = runExceptT $ do
  -- The complete initial read rejects a hostile partial shape before even
  -- stamping the VPC. The durable caller has already registered both families.
  initial <- ExceptT (observeTestVpcCanary run request)
  let CanaryPlantSnapshot initialGroups _ = initial
      binding = testCanaryBinding request
  successful run "mark-vpc" $
    ["ec2", "create-tags", "--resources", unpack (testCanaryVpc request), "--tags"]
      ++ map tagArgument (canaryVpcMarkerTags binding)
  groups <- forM [minBound .. maxBound] $ \shape ->
    ensureGroup run request initialGroups shape
  void (ensureInterface run request groups)
  ensureReference run request groups MutualLeftGroup MutualRightGroup
  ensureReference run request groups MutualRightGroup MutualLeftGroup
  confirmed <- ExceptT (observeTestVpcCanary run request)
  unless
    (canaryPlantComplete confirmed)
    (throwE "test canary read-back did not confirm every planted shape")
  forM [InterfaceHeldGroup, MutualLeftGroup] $ \shape -> do
    Group identity _ _ <- requireGroup groups shape
    output <- lift (run ["ec2", "delete-security-group", "--group-id", unpack identity])
    unless
      (awsCliServiceErrorMatches "DependencyViolation" "DeleteSecurityGroup" output)
      ( throwE
          "test canary dependency probe did not return the exact DeleteSecurityGroup DependencyViolation"
      )
    pure (CanaryDependencyProbe shape output)

checkVpcAndSubnet :: (Monad m) => AwsRun m -> TestVpcCanaryRequest -> ExceptT Text m ()
checkVpcAndSubnet run request = do
  vpcs <-
    listing
      run
      "canary VPC"
      [ "ec2"
      , "describe-vpcs"
      , "--vpc-ids"
      , unpack (testCanaryVpc request)
      , "--query"
      , "Vpcs[].{id:VpcId,tags:Tags}"
      , "--output"
      , "json"
      ]
  row <- exactlyOne "canary VPC" vpcs
  identity <- textField "id" row
  unless (identity == testCanaryVpc request) (throwE "test canary VPC read-back named another VPC")
  tags <- tagsField row
  let binding = testCanaryBinding request
      required =
        [ ("Name", "aws-test-vpc")
        , ("prodbox.io/managed-by", "prodbox")
        , ("prodbox.io/run-scope", testCanaryStackRunScope binding)
        , ("prodbox.io/submission", testCanaryStackSubmission binding)
        ]
  unless
    (all (\(key, value) -> Map.lookup key (Map.fromList tags) == Just value) required)
    (throwE "test canary VPC ownership does not match the creating stack run")
  frozen <- checked (first renderTestCanaryError (canaryBindingFromVpcTags tags))
  unless
    (frozen `elem` [Nothing, Just binding])
    (throwE "test canary VPC is already bound to another registered run")
  subnets <-
    listing
      run
      "canary subnet"
      [ "ec2"
      , "describe-subnets"
      , "--subnet-ids"
      , unpack (testCanarySubnet request)
      , "--query"
      , "Subnets[].{id:SubnetId,vpc:VpcId}"
      , "--output"
      , "json"
      ]
  subnet <- exactlyOne "canary subnet" subnets
  subnetId <- textField "id" subnet
  subnetVpc <- textField "vpc" subnet
  unless
    (subnetId == testCanarySubnet request && subnetVpc == testCanaryVpc request)
    (throwE "test canary subnet is not the exact subnet in the owned VPC")

readGroups :: (Monad m) => AwsRun m -> TestVpcCanaryRequest -> ExceptT Text m [Group]
readGroups run request = readGroupsBound run (testCanaryVpc request) (testCanaryBinding request)

readGroupsBound :: (Monad m) => AwsRun m -> Text -> TestCanaryBinding -> ExceptT Text m [Group]
readGroupsBound run expectedVpc binding = do
  rows <-
    listing
      run
      "canary groups"
      [ "ec2"
      , "describe-security-groups"
      , "--filters"
      , "Name=vpc-id,Values=" ++ unpack (expectedVpc)
      , "--query"
      , canarySecurityGroupsQuery
      , "--output"
      , "json"
      ]
  candidates <- fmap concat $ forM rows $ \row -> do
    name <- textField "name" row
    tags <- tagsField row
    if not (isCanaryGroupCandidate name tags)
      then pure []
      else do
        shape <- case [candidate | candidate <- [minBound .. maxBound], name == canaryGroupName binding candidate] of
          [candidate] -> pure candidate
          _ -> throwE "test canary group is outside the closed name/shape list"
        identity <-
          textField "id" row
            >>= checked . first renderTestCanaryError . validateCanaryEc2Identifier CanarySecurityGroup
        vpc <- textField "vpc" row
        checked
          (first renderTestCanaryError (checkCanaryGroup binding (expectedVpc) shape vpc name tags))
        ingress <- ingressPeers row
        pure [Group identity shape ingress]
  unless
    (length (nub [shape | Group _ shape _ <- candidates]) == length candidates)
    (throwE "test canary group shape has duplicate candidates")
  unless
    (length (nub [identity | Group identity _ _ <- candidates]) == length candidates)
    (throwE "test canary group projection repeats an identifier")
  forM candidates $ \group@(Group _ shape peers) -> do
    let expected = case shape of
          InterfaceHeldGroup -> Nothing
          MutualLeftGroup -> groupByShape candidates MutualRightGroup
          MutualRightGroup -> groupByShape candidates MutualLeftGroup
    case (peers, expected) of
      ([], _) -> pure group
      ([peer], Just (Group expectedId _ _)) | peer == expectedId -> pure group
      _ -> throwE "test canary group carries an unowned ingress rule"

-- A caller's admitted family is a ceiling. Fresh VPC markers and complete
-- group projections independently bind each rule. A later stack reconcile
-- may refresh the main run tag; the dedicated frozen markers remain exact.
clearTestCanaryReferences
  :: (Monad m) => AwsRun m -> Text -> [Text] -> m (Either Text ())
clearTestCanaryReferences _ _ [] = pure (Right ())
clearTestCanaryReferences run expectedVpc admittedIds = runExceptT $ do
  rows <-
    listing
      run
      "canary cleanup VPC"
      [ "ec2"
      , "describe-vpcs"
      , "--vpc-ids"
      , unpack expectedVpc
      , "--query"
      , "Vpcs[].{id:VpcId,tags:Tags}"
      , "--output"
      , "json"
      ]
  row <- exactlyOne "canary cleanup VPC" rows
  observedVpc <- textField "id" row
  tags <- tagsField row
  unless
    ( observedVpc == expectedVpc
        && lookup "Name" tags == Just "aws-test-vpc"
        && lookup "prodbox.io/managed-by" tags == Just "prodbox"
    )
    (throwE "canary peer cleanup VPC does not match the registered test VPC")
  found <- checked (first renderTestCanaryError (canaryBindingFromVpcTags tags))
  binding <- maybe (throwE "canary peer cleanup has no exact frozen run binding") pure found
  groups <- readGroupsBound run expectedVpc binding
  unless
    (all (\(Group identity _ _) -> identity `elem` admittedIds) groups)
    (throwE "canary peer cleanup found a member outside the freshly admitted family")
  forM_ groups $ \(Group identity _ peers) -> forM_ peers $ \peer -> do
    unless (peer `elem` admittedIds) (throwE "canary peer rule points outside the admitted family")
    output <-
      lift $
        run
          [ "ec2"
          , "revoke-security-group-ingress"
          , "--group-id"
          , unpack identity
          , "--ip-permissions"
          , jsonArgument
              [ object
                  [ "IpProtocol" .= ("tcp" :: Text)
                  , "FromPort" .= (443 :: Int)
                  , "ToPort" .= (443 :: Int)
                  , "UserIdGroupPairs" .= [object ["GroupId" .= peer]]
                  ]
              ]
          ]
    confirmed <- readGroupsBound run expectedVpc binding
    unless
      (any (\(Group current _ remaining) -> current == identity && peer `notElem` remaining) confirmed)
      (throwE (operationFailure "revoke canary peer reference" output))

ingressPeers :: (Monad m) => Value -> ExceptT Text m [Text]
ingressPeers row = do
  permissions <- arrayField "ingress" row
  forM permissions $ \permission -> do
    protocol <- textField "protocol" permission
    from <- field "from" permission
    to <- field "to" permission
    peers <- arrayField "peers" permission
    ipv4 <- arrayField "ipv4" permission
    ipv6 <- arrayField "ipv6" permission
    prefixes <- arrayField "prefixes" permission
    unless
      ( protocol == "tcp"
          && from == Number 443
          && to == Number 443
          && null ipv4
          && null ipv6
          && null prefixes
      )
      (throwE "test canary group ingress is outside the closed TCP/443 peer rule")
    case peers of
      [String peer] -> checked (first renderTestCanaryError (validateCanaryEc2Identifier CanarySecurityGroup peer))
      _ -> throwE "test canary group ingress does not name exactly one group"

readInterface
  :: (Monad m) => AwsRun m -> TestVpcCanaryRequest -> [Group] -> ExceptT Text m (Maybe Text)
readInterface run request groups = do
  rows <-
    listing
      run
      "canary interface"
      [ "ec2"
      , "describe-network-interfaces"
      , "--filters"
      , "Name=vpc-id,Values=" ++ unpack (testCanaryVpc request)
      , "Name=tag:prodbox.io/test-canary-run,Values=" ++ unpack (testCanaryRunScope binding)
      , "--query"
      , "NetworkInterfaces[].{id:NetworkInterfaceId,vpc:VpcId,subnet:SubnetId,status:Status,managed:RequesterManaged,attachment:Attachment,description:Description,groups:Groups[].GroupId,tags:TagSet}"
      , "--output"
      , "json"
      ]
  case rows of
    [] -> pure Nothing
    [row] -> do
      identity <-
        textField "id" row
          >>= checked . first renderTestCanaryError . validateCanaryEc2Identifier CanaryInterface
      vpc <- textField "vpc" row
      subnet <- textField "subnet" row
      status <- textField "status" row
      description <- textField "description" row
      managed <- field "managed" row
      attachment <- field "attachment" row
      held <- requireGroup groups InterfaceHeldGroup
      groupIds <- arrayField "groups" row
      tags <- tagsField row
      let Group heldId _ _ = held
      unless
        ( vpc == testCanaryVpc request
            && subnet == testCanarySubnet request
            && status == "available"
            && managed == Bool False
            && attachment == Null
            && description == canaryInterfaceDescription binding
            && groupIds == [String heldId]
            && all
              (\(key, value) -> Map.lookup key (Map.fromList tags) == Just value)
              (canaryInterfaceTags binding)
            && not (any (Text.isPrefixOf "kubernetes.io/cluster/" . fst) tags)
        )
        (throwE "test canary interface does not match its exact unattached CNI shape")
      pure (Just identity)
    _ -> throwE "test canary interface has multiple candidates"
 where
  binding = testCanaryBinding request

ensureGroup
  :: (Monad m) => AwsRun m -> TestVpcCanaryRequest -> [Group] -> CanaryGroupShape -> ExceptT Text m Group
ensureGroup run request groups shape = case groupByShape groups shape of
  Just existing -> pure existing
  Nothing -> do
    let binding = testCanaryBinding request
    -- A lost response does not justify a second create. The exact unique name
    -- and tag read-back may prove that this first call landed.
    output <-
      lift $
        run
          [ "ec2"
          , "create-security-group"
          , "--vpc-id"
          , unpack (testCanaryVpc request)
          , "--group-name"
          , unpack (canaryGroupName binding shape)
          , "--description"
          , "prodbox closed network-dependency canary"
          , "--tag-specifications"
          , tagSpecification "security-group" (canaryGroupTags binding shape)
          , "--output"
          , "json"
          ]
    observed <- readGroups run request
    case groupByShape observed shape of
      Just found -> pure found
      Nothing -> throwE (operationFailure "create canary group" output)

ensureInterface :: (Monad m) => AwsRun m -> TestVpcCanaryRequest -> [Group] -> ExceptT Text m Text
ensureInterface run request groups = do
  existing <- readInterface run request groups
  case existing of
    Just identity -> pure identity
    Nothing -> do
      Group held _ _ <- requireGroup groups InterfaceHeldGroup
      let binding = testCanaryBinding request
      output <-
        lift $
          run
            [ "ec2"
            , "create-network-interface"
            , "--subnet-id"
            , unpack (testCanarySubnet request)
            , "--groups"
            , unpack held
            , "--description"
            , unpack (canaryInterfaceDescription binding)
            , "--client-token"
            , unpack (testCanaryClientToken request)
            , "--tag-specifications"
            , tagSpecification "network-interface" (canaryInterfaceTags binding)
            , "--output"
            , "json"
            ]
      observed <- readInterface run request groups
      case observed of
        Just identity -> pure identity
        Nothing -> throwE (operationFailure "create canary interface" output)

ensureReference
  :: (Monad m)
  => AwsRun m
  -> TestVpcCanaryRequest
  -> [Group]
  -> CanaryGroupShape
  -> CanaryGroupShape
  -> ExceptT Text m ()
ensureReference run request groups sourceShape peerShape = do
  Group source _ peers <- requireGroup groups sourceShape
  Group peer _ _ <- requireGroup groups peerShape
  unless (peers == [peer]) $ do
    output <-
      lift $
        run
          [ "ec2"
          , "authorize-security-group-ingress"
          , "--group-id"
          , unpack source
          , "--ip-permissions"
          , jsonArgument
              [ object
                  [ "IpProtocol" .= ("tcp" :: Text)
                  , "FromPort" .= (443 :: Int)
                  , "ToPort" .= (443 :: Int)
                  , "UserIdGroupPairs" .= [object ["GroupId" .= peer]]
                  ]
              ]
          ]
    observed <- readGroups run request
    case groupByShape observed sourceShape of
      Just (Group identity _ [observedPeer]) | identity == source && observedPeer == peer -> pure ()
      _ -> throwE (operationFailure "authorize canary peer reference" output)

groupByShape :: [Group] -> CanaryGroupShape -> Maybe Group
groupByShape groups shape = case [group | group@(Group _ candidate _) <- groups, candidate == shape] of
  [group] -> Just group
  _ -> Nothing

requireGroup :: (Monad m) => [Group] -> CanaryGroupShape -> ExceptT Text m Group
requireGroup groups shape = maybe (throwE "test canary is missing a closed group shape") pure (groupByShape groups shape)

listing :: (Monad m) => AwsRun m -> Text -> [String] -> ExceptT Text m [Value]
listing run label arguments = do
  output <- lift (run arguments)
  unless (processExitCode output == ExitSuccess) (throwE (operationFailure label output))
  let bytes = TextEncoding.encodeUtf8 (Text.pack (processStdout output))
  unless
    (ByteString.length bytes <= canaryInventoryMaximumBytes)
    (throwE "test canary inventory exceeds its byte bound")
  value <- checked (first (const "test canary inventory is not JSON") (eitherDecodeStrict' bytes))
  case value of
    Array rows | Vector.length rows <= canaryInventoryMaximumRows -> pure (Vector.toList rows)
    _ -> throwE "test canary inventory is not a bounded complete array"

successful :: (Monad m) => AwsRun m -> Text -> [String] -> ExceptT Text m ()
successful run label arguments = do
  output <- lift (run arguments)
  unless (processExitCode output == ExitSuccess) (throwE (operationFailure label output))

operationFailure :: Text -> ProcessOutput -> Text
operationFailure label output = case processExitCode output of
  ExitSuccess -> label <> " was not confirmed by exact provider read-back"
  ExitFailure code -> label <> " failed (exit " <> Text.pack (show code) <> "); registered cleanup remains required"

exactlyOne :: (Monad m) => Text -> [Value] -> ExceptT Text m Value
exactlyOne label rows = case rows of
  [row] -> pure row
  _ -> throwE (label <> " did not return exactly one recorded object")

field :: (Monad m) => Text -> Value -> ExceptT Text m Value
field key value = case value of
  Object fields ->
    maybe
      (throwE "test canary inventory omitted a required projection")
      pure
      (KeyMap.lookup (Key.fromText key) fields)
  _ -> throwE "test canary inventory member is not an object"

textField :: (Monad m) => Text -> Value -> ExceptT Text m Text
textField key row = do
  value <- field key row
  case value of
    String text -> pure text
    _ -> throwE "test canary inventory string projection has another type"

arrayField :: (Monad m) => Text -> Value -> ExceptT Text m [Value]
arrayField key row = do
  value <- field key row
  case value of
    Array values -> pure (Vector.toList values)
    _ -> throwE "test canary inventory array projection has another type"

tagsField :: (Monad m) => Value -> ExceptT Text m [(Text, Text)]
tagsField row = do
  value <- field "tags" row
  tags <- case value of
    Null -> pure []
    Array values | Vector.length values <= canaryInventoryMaximumTags ->
      forM (Vector.toList values) $ \tag -> (,) <$> textField "Key" tag <*> textField "Value" tag
    _ -> throwE "test canary inventory tags exceed their bound or have another type"
  unless
    (length (nub (map fst tags)) == length tags)
    (throwE "test canary inventory has duplicate tag keys")
  pure tags

checked :: (Monad m) => Either Text a -> ExceptT Text m a
checked = ExceptT . pure

tagArgument :: (Text, Text) -> String
tagArgument (key, value) = "Key=" ++ unpack key ++ ",Value=" ++ unpack value

tagSpecification :: Text -> [(Text, Text)] -> String
tagSpecification resource tags =
  jsonArgument
    [ object
        [ "ResourceType" .= resource
        , "Tags" .= [object ["Key" .= key, "Value" .= value] | (key, value) <- tags]
        ]
    ]

jsonArgument :: (ToJSON a) => a -> String
jsonArgument = Text.unpack . TextEncoding.decodeUtf8 . LazyByteString.toStrict . encode

unpack :: Text -> String
unpack = Text.unpack
