{-# LANGUAGE OverloadedStrings #-}

-- | State-independent repair of the registry's two EKS network families.
-- The full plan is private; its report is a bounded metadata projection.
module Prodbox.Lifecycle.AwsNetworkPurge
  ( NetworkPurgePlan
  , observeNetworkPurgePlan
  , networkPurgeDigest
  , networkPurgeAbsent
  , applyNetworkPurge
  , encodeNetworkPurgeReport
  , decodeNetworkPurgeReport
  , NetworkPurgeReport (..)
  , renderNetworkPurgeReport
  )
where

import Control.Monad (foldM)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (Value (..), eitherDecodeStrict', encode, object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Bifunctor (first)
import Data.ByteString qualified as ByteString
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Char (isControl, isDigit)
import Data.List (sortOn)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Vector qualified as Vector
import Numeric (showHex)
import Prodbox.Lifecycle.AwsNativeStackFamily
  ( AwsNativeStackFamilyRunner (..)
  , locateNetworkFamily
  , observeEksClusterAbsent
  )
import Prodbox.Lifecycle.AwsNetworkDependents
import Prodbox.Lifecycle.AwsNetworkFamily
import Prodbox.Lifecycle.AwsWait (AwsWaitEnvironment)
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
  ( ProviderNativeStackFamilyRef
  , providerNativeStackFamilyAccountId
  , providerNativeStackFamilyRegion
  )
import Prodbox.Lifecycle.Teardown.Registry (awsNetworkFamiliesForStack)
import Prodbox.Subprocess (ProcessOutput (..))
import System.Exit (ExitCode (..))

data NetworkPurgePlan = NetworkPurgePlan
  { planAccount :: !Text
  , planRegion :: !Text
  , planTarget :: !DependentsTarget
  , planFamilies :: ![(AwsNetworkFamily, [Dependent])]
  }
  deriving (Eq, Show)

observeNetworkPurgePlan
  :: (Monad m)
  => AwsRun m -> ProviderNativeStackFamilyRef -> m (Either Text NetworkPurgePlan)
observeNetworkPurgePlan _ _ | null registeredEksFamilies = pure (Left "network purge has no registered EKS families")
observeNetworkPurgePlan runner ref = do
  owners <- observeEksClusterAbsent (AwsNativeStackFamilyRunner runner)
  case owners of
    Left _ -> pure (Left "network purge could not prove EKS cluster absence")
    Right False -> pure (Left "network purge requires the EKS cluster to be positively absent")
    Right True -> do
      located <- locateNetworkFamily (AwsNativeStackFamilyRunner runner) EksVpcCniInterfaces
      case located of
        Left _ -> pure (Left "network purge requires exactly one VPC carrying both registered tags")
        Right Nothing -> pure (Left "network purge found no exact-tagged VPC; absence is unobservable for this repair")
        Right (Just target) -> do
          observations <- traverse (observeFamily target) registeredEksFamilies
          pure $
            NetworkPurgePlan
              (providerNativeStackFamilyAccountId ref)
              (providerNativeStackFamilyRegion ref)
              target
              <$> sequence observations
 where
  observeFamily target family = do
    observed <- observeNetworkFamily family runner target
    pure ((family,) . sortOn dependentIdentity <$> observed)

networkPurgeAbsent :: NetworkPurgePlan -> Bool
networkPurgeAbsent plan = not (null (planFamilies plan)) && all (null . snd) (planFamilies plan)

registeredEksFamilies :: [AwsNetworkFamily]
registeredEksFamilies = awsNetworkFamiliesForStack (networkFamilyPulumiStack EksVpcCniInterfaces)

networkPurgeDigest :: NetworkPurgePlan -> Text
networkPurgeDigest plan = Text.pack (concatMap hexByte (ByteString.unpack digest))
 where
  digest =
    SHA256.hash
      ( LazyByteString.toStrict
          ( encode
              ( object
                  [ "schema" .= ("prodbox-network-purge-plan/v1" :: Text)
                  , "account" .= planAccount plan
                  , "region" .= planRegion plan
                  , "vpc" .= dependentsTargetVpc (planTarget plan)
                  , "families"
                      .= [ object
                             [ "name" .= networkFamilyName family
                             , "predicate" .= networkFamilyPredicate family
                             , "members"
                                 .= [ object
                                        [ "kind" .= dependentKindLabel (dependentKind row)
                                        , "id" .= dependentIdentity row
                                        , "disposition" .= Text.pack (show (dependentDisposition row))
                                        ]
                                    | row <- rows
                                    ]
                             ]
                         | (family, rows) <- planFamilies plan
                         ]
                  ]
              )
          )
      )
  hexByte byte = case showHex byte "" of
    [one] -> ['0', one]
    two -> two

-- | Re-observe the entire plan before any effect. Each shared executor also
-- observes its predicate before deleting. The runner fence prevents a new
-- candidate discovered during convergence from escaping the confirmed set.
applyNetworkPurge
  :: (Monad m)
  => AwsRun m -> AwsWaitEnvironment m -> ProviderNativeStackFamilyRef -> Text -> m (Either Text ())
applyNetworkPurge runner waits ref expected = do
  observed <- observeNetworkPurgePlan runner ref
  case observed of
    Left detail -> pure (Left detail)
    Right plan
      | networkPurgeDigest plan /= expected ->
          pure (Left "network purge plan changed; render and confirm a new plan digest")
      | any (any unadmitted . snd) (planFamilies plan) ->
          pure (Left "network purge contains candidates outside the registered predicates")
      | otherwise -> foldM (clearFamily plan) (Right ()) (planFamilies plan)
 where
  unadmitted row = case dependentDisposition row of
    NotAdmitted _ -> True
    Admitted -> False
    HeldByService _ -> False
  clearFamily _ failed@(Left _) _ = pure failed
  clearFamily plan (Right ()) (family, rows) = do
    result <- clearNetworkFamily family (fencedRunner rows) waits (planTarget plan)
    pure $ do
      repaired <- result
      if null (repairRemaining repaired) && null (repairNotes repaired)
        then Right ()
        else Left "network purge did not prove its declared family absent; run purge-dependents again"
  fencedRunner rows arguments = case arguments of
    ["ec2", "delete-network-interface", "--network-interface-id", identifier] -> guarded DependentInterface identifier
    ["ec2", "delete-security-group", "--group-id", identifier] -> guarded DependentSecurityGroup identifier
    _ -> runner arguments
   where
    guarded kind identifier
      | any (\row -> dependentKind row == kind && dependentIdentity row == Text.pack identifier) rows =
          runner arguments
      | otherwise =
          pure (ProcessOutput (ExitFailure 1) "" "network purge candidate is outside the confirmed plan")

data NetworkPurgeReport = NetworkPurgeReport
  { purgeReportAccount :: !Text
  , purgeReportRegion :: !Text
  , purgeReportVpc :: !Text
  , purgeReportDigest :: !Text
  , purgeReportCounts :: ![(Text, Int)]
  , purgeReportDispositionCounts :: ![(Text, Int, Int, Int)]
  , purgeReportFirstIdentifiers :: ![Text]
  }
  deriving (Eq, Show)

encodeNetworkPurgeReport :: NetworkPurgePlan -> Either Text Text
encodeNetworkPurgeReport plan =
  let bytes =
        LazyByteString.toStrict
          ( encode
              ( object
                  [ "schema" .= ("prodbox-network-purge-report/v1" :: Text)
                  , "account" .= planAccount plan
                  , "region" .= planRegion plan
                  , "vpc" .= dependentsTargetVpc (planTarget plan)
                  , "digest" .= networkPurgeDigest plan
                  , "counts"
                      .= [ object
                             [ "family" .= networkFamilyName family
                             , "count" .= length rows
                             , "admitted" .= length [() | row <- rows, dependentDisposition row == Admitted]
                             , "held" .= length [() | row <- rows, HeldByService _ <- [dependentDisposition row]]
                             , "refused" .= length [() | row <- rows, NotAdmitted _ <- [dependentDisposition row]]
                             ]
                         | (family, rows) <- planFamilies plan
                         ]
                  , "first" .= take 8 [dependentIdentity row | (_, rows) <- planFamilies plan, row <- rows]
                  ]
              )
          )
   in if ByteString.length bytes <= 4096
        then Right (TextEncoding.decodeUtf8 bytes)
        else Left "network purge report exceeds its evidence bound"

decodeNetworkPurgeReport :: Text -> Text -> Text -> Either Text NetworkPurgeReport
decodeNetworkPurgeReport account region raw = do
  if ByteString.length (TextEncoding.encodeUtf8 raw) <= 4096
    then Right ()
    else Left "network purge evidence exceeds its bound"
  value <-
    first
      (const "network purge report is malformed")
      (eitherDecodeStrict' (TextEncoding.encodeUtf8 raw))
  fields <- asObject value
  schema <- textField "schema" fields
  actualAccount <- textField "account" fields
  actualRegion <- textField "region" fields
  if schema == "prodbox-network-purge-report/v1" && actualAccount == account && actualRegion == region
    then Right ()
    else Left "network purge evidence differs from the admitted scope"
  vpc <- textField "vpc" fields
  _ <- mkDependentsTarget vpc (networkFamilyCluster EksVpcCniInterfaces)
  digest <- textField "digest" fields
  if Text.length digest == 64 && Text.all (\c -> isDigit c || c `elem` ['a' .. 'f']) digest
    then Right ()
    else Left "network purge report digest is malformed"
  classifications <- traverse countRow =<< arrayField "counts" fields
  let counts = [(family, admitted + held + refused) | (family, admitted, held, refused) <- classifications]
  if not (null counts) && map fst counts == map networkFamilyName registeredEksFamilies
    then Right ()
    else Left "network purge report does not cover the registered families"
  identifiers <- traverse textValue =<< arrayField "first" fields
  if length identifiers == min 8 (sum (map snd counts))
    && all
      ( \identifier ->
          Text.length identifier <= 128 && not (Text.null identifier) && not (Text.any isControl identifier)
      )
      identifiers
    then Right ()
    else Left "network purge report identifiers are malformed"
  Right (NetworkPurgeReport account region vpc digest counts classifications identifiers)
 where
  asObject (Object fields) = Right fields
  asObject _ = Left "network purge report is not an object"
  textValue (String value) = Right value
  textValue _ = Left "network purge report text is missing"
  textField key fields = maybe (Left "network purge report field is missing") textValue (KeyMap.lookup key fields)
  arrayField key fields = case KeyMap.lookup key fields of
    Just (Array values) -> Right (Vector.toList values)
    _ -> Left "network purge report array is missing"
  countRow value = do
    fields <- asObject value
    family <- textField "family" fields
    total <- numberField "count" fields
    admitted <- numberField "admitted" fields
    held <- numberField "held" fields
    refused <- numberField "refused" fields
    if total == admitted + held + refused
      then Right (family, admitted, held, refused)
      else Left "network purge disposition counts differ from the family total"
  numberField key fields = case KeyMap.lookup key fields of
    Just (Number n) | n >= 0 && n <= 100000, let count = floor n, fromIntegral count == n -> Right count
    _ -> Left "network purge report count is malformed"

renderNetworkPurgeReport :: NetworkPurgeReport -> [Text]
renderNetworkPurgeReport report =
  [ "AWS_NETWORK_PURGE account="
      <> purgeReportAccount report
      <> " region="
      <> purgeReportRegion report
      <> " vpc="
      <> purgeReportVpc report
  , "plan-digest " <> purgeReportDigest report
  ]
    ++ [ family
           <> " admitted="
           <> number admitted
           <> " held="
           <> number held
           <> " refused="
           <> number refused
       | (family, admitted, held, refused) <- purgeReportDispositionCounts report
       ]
    ++ [ "first " <> Text.intercalate "," (purgeReportFirstIdentifiers report)
       | not (null (purgeReportFirstIdentifiers report))
       ]
 where
  number = Text.pack . show
