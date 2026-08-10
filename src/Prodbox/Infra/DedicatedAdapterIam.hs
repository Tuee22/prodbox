{-# LANGUAGE OverloadedStrings #-}

-- | Canonical coordinates for the two long-lived adapter IAM identities.
-- Creation and total decommission both consume this one registry.
module Prodbox.Infra.DedicatedAdapterIam
  ( DedicatedAdapterIamSpec (..)
  , authorityBackupIamUserName
  , authorityBackupIamPolicyName
  , tlsRetentionIamUserName
  , tlsRetentionIamPolicyName
  , dedicatedAdapterIamSpecs
  , configuredTlsRetentionPrefixes
  , validateDedicatedBucket
  , validateDedicatedPrefix
  )
where

import Data.Char (isAsciiLower)
import Data.Char qualified as Char
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Config.Basics (basicsClusterId)
import Prodbox.Config.FloorDhall (loadUnencryptedBasics)
import Prodbox.Infra.AwsEksTestStack (awsEksCanonicalClusterName)
import Prodbox.Lifecycle.CredentialProvisioner.OperatorMaterial
  ( AwsCredentialClass (AuthorityBackupStoreCredential, TlsRetentionStoreCredential)
  , AwsCredentialDescriptor
    ( awsCredentialDescriptorPolicy
    , awsCredentialDescriptorPrincipal
    )
  , awsCredentialDescriptor
  )
import Prodbox.PublicEdge (publicEdgeTlsRetentionKey)
import Prodbox.Settings
  ( ConfigFile (aws_substrate, domain)
  , ValidatedPublicEdge (..)
  , ValidatedServedHost (..)
  , validatedPublicEdgeFor
  )
import Prodbox.Substrate (Substrate (SubstrateAws, SubstrateHomeLocal))

authorityBackupIamUserName :: Text
authorityBackupIamUserName =
  awsCredentialDescriptorPrincipal
    (awsCredentialDescriptor AuthorityBackupStoreCredential)

tlsRetentionIamUserName :: Text
tlsRetentionIamUserName =
  awsCredentialDescriptorPrincipal
    (awsCredentialDescriptor TlsRetentionStoreCredential)

authorityBackupIamPolicyName :: Text
authorityBackupIamPolicyName =
  awsCredentialDescriptorPolicy
    (awsCredentialDescriptor AuthorityBackupStoreCredential)

tlsRetentionIamPolicyName :: Text
tlsRetentionIamPolicyName =
  awsCredentialDescriptorPolicy
    (awsCredentialDescriptor TlsRetentionStoreCredential)

data DedicatedAdapterIamSpec = DedicatedAdapterIamSpec
  { dedicatedIamUserName :: !Text
  , dedicatedIamPolicyName :: !Text
  , dedicatedIamVaultPath :: !Text
  , dedicatedIamPrefixes :: ![Text]
  }
  deriving (Eq, Show)

dedicatedAdapterIamSpecs :: FilePath -> ConfigFile -> IO [DedicatedAdapterIamSpec]
dedicatedAdapterIamSpecs repoRoot config = do
  basicsResult <- loadUnencryptedBasics repoRoot
  homeClusterId <- case basicsResult of
    Left err ->
      ioError
        ( userError
            ( "dedicated adapter IAM reconcile could not load the home cluster identity: "
                ++ err
            )
        )
    Right basics -> pure (Text.strip (basicsClusterId basics))
  tlsPrefixes <- either (ioError . userError) pure (configuredTlsRetentionPrefixes config)
  pure
    [ DedicatedAdapterIamSpec
        { dedicatedIamUserName = authorityBackupIamUserName
        , dedicatedIamPolicyName = authorityBackupIamPolicyName
        , dedicatedIamVaultPath = "aws/authority-backup-store"
        , dedicatedIamPrefixes =
            [ "authority-backup-store/" <> homeClusterId
            , "authority-backup-store/" <> Text.pack awsEksCanonicalClusterName
            ]
        }
    , DedicatedAdapterIamSpec
        { dedicatedIamUserName = tlsRetentionIamUserName
        , dedicatedIamPolicyName = tlsRetentionIamPolicyName
        , dedicatedIamVaultPath = "aws/tls-retention-store"
        , dedicatedIamPrefixes = tlsPrefixes
        }
    ]

-- Sprint 1.83: one parse of the public-edge projection supplies both served
-- hosts and both scope sets, and the AWS substrate's presence is the `Maybe` the
-- projection already carries rather than a second emptiness test over the raw
-- field.
configuredTlsRetentionPrefixes :: ConfigFile -> Either String [Text]
configuredTlsRetentionPrefixes config = do
  publicEdge <- validatedPublicEdgeFor (domain config) (aws_substrate config)
  let homePrefix =
        Text.pack
          ( publicEdgeTlsRetentionKey
              SubstrateHomeLocal
              (servedHostCertScopes (validatedHomeServedHost publicEdge))
          )
  Right $ case validatedAwsServedHost publicEdge of
    Nothing -> [homePrefix]
    Just awsServed ->
      [ homePrefix
      , Text.pack (publicEdgeTlsRetentionKey SubstrateAws (servedHostCertScopes awsServed))
      ]

validateDedicatedBucket :: Text -> Either String Text
validateDedicatedBucket raw =
  let value = Text.strip raw
      validCharacter character =
        isAsciiLower character || Char.isDigit character || character == '-' || character == '.'
      validEdge character = isAsciiLower character || Char.isDigit character
   in case (Text.uncons value, Text.unsnoc value) of
        (Just (first, _), Just (_, lastCharacter))
          | Text.length value >= 3
              && Text.length value <= 63
              && Text.all validCharacter value
              && validEdge first
              && validEdge lastCharacter
              && not (".." `Text.isInfixOf` value) ->
              Right value
        _ -> Left "invalid dedicated adapter S3 bucket"

validateDedicatedPrefix :: Text -> Either String Text
validateDedicatedPrefix raw =
  let value = Text.strip raw
      segments = Text.splitOn "/" value
      valid = case segments of
        ["authority-backup-store", clusterId] -> validPlainSegment clusterId
        ["public-edge-tls", substrate, scopeKey] ->
          substrate `elem` ["home-local", "aws"] && validScopeSegment scopeKey
        _ -> False
   in if Text.length value <= 1024 && valid
        then Right value
        else Left "invalid or unregistered dedicated adapter S3 prefix"

validPlainSegment :: Text -> Bool
validPlainSegment value =
  case (Text.uncons value, Text.unsnoc value) of
    (Just (first, _), Just (_, lastCharacter)) ->
      Text.length value <= 128
        && plainEdge first
        && plainEdge lastCharacter
        && Text.all (\character -> plainEdge character || character == '-') value
    _ -> False
 where
  plainEdge character = isAsciiLower character || Char.isDigit character

validScopeSegment :: Text -> Bool
validScopeSegment value =
  not (Text.null value) && Text.length value <= 512 && go value
 where
  go remaining = case Text.uncons remaining of
    Nothing -> True
    Just ('%', rest) -> case Text.splitAt 2 rest of
      (escape, suffix)
        | escape == "2A" || escape == "2C" -> go suffix
      _ -> False
    Just (character, rest) ->
      (isAsciiLower character || Char.isDigit character || character `elem` ['-', '.'])
        && go rest
