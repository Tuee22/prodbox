{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

module ProviderScopeFixture (completedScope, fixtureAccount) where

import Codec.Serialise (Serialise, serialise)
import Data.ByteString.Base64 qualified as Base64
import Data.ByteString.Lazy qualified as Lazy
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Word (Word16)
import GHC.Generics (Generic)
import Numeric.Natural (Natural)
import Prodbox.Aws.Region (canonicalRegressionAwsRegion)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.ControlPlane.CallerPrincipal (CallerPrincipal (CallerOperatorCli))
import Prodbox.Lifecycle.Authority.Admission
import Prodbox.Lifecycle.Authority.ClientRegistry
import Prodbox.Lifecycle.Authority.Genesis
import Prodbox.Lifecycle.Authority.Submission (OperationId, RequestDigest (RequestDigest))
import Prodbox.Lifecycle.ProviderWorker.ProviderWork (providerIntentCoordinateText)
import Prodbox.Lifecycle.Teardown.ProviderAwsScopeAdapter
  ( providerAwsScopeIntent
  , providerAwsScopeIntentCoordinate
  )

data FixtureReceipt = FixtureReceipt !Word16 !Text !Natural !Text !Text !Text
  deriving stock (Generic)
  deriving anyclass (Serialise)

fixtureAccount :: Text
fixtureAccount = "123456789012"

completedScope :: (OperationId, AuthorityAdmissionAggregate, Text)
completedScope = checked `seq` (operation, completed, receipt)
 where
  generation = mustRight (mkRegisteredClientGeneration 1)
  spec =
    mustRight
      ( mkRegisteredClientSpec
          (clientPrincipalForCaller CallerOperatorCli)
          (mustRight (mkRegisteredClientSlot 1))
          generation
          16
      )
  clients = mustRight (mkRegisteredClientTable 2 [spec])
  initial = mustRight (initialCleanInstallAuthorityWithRegisteredClients 8 16 clients)
  opened =
    foldl
      (\aggregate command -> snd (stepAuthorityAdmission aggregate command))
      initial
      [ ApplyAuthorityGenesis (BeginGenesisEstablishment (GenesisPlan "scope-genesis" "backup-prefix"))
      , ApplyAuthorityGenesis
          (ObserveTargetAgentGeneration (TargetAgentGenerationReceipt "target-generation-1"))
      , ApplyAuthorityGenesis (ObserveBackupReceipt (BackupReceipt "backup-receipt-1"))
      ]
  key = mustRight (mkClientSubmissionKey "provider-aws-scope/fixture")
  (decision, pending) =
    mustRight
      ( stepRegisteredProviderSubmission
          opened
          CallerOperatorCli
          generation
          key
          (RequestDigest (Text.replicate 64 "b"))
          providerAwsScopeIntent
          ProviderOperationUnownedByCleanupRun
      )
  operation = case decision of
    AuthorityProviderSubmissionAccepted accepted -> accepted
    other -> error ("scope admission failed: " <> show other)
  operationText = Text.decodeUtf8 (hexSha256 (Lazy.toStrict (serialise operation)))
  wire =
    FixtureReceipt
      1
      operationText
      7
      (providerIntentCoordinateText providerAwsScopeIntentCoordinate)
      fixtureAccount
      canonicalRegressionAwsRegion
  receipt =
    "provider-aws-scope-receipt-v1:" <> Text.decodeUtf8 (Base64.encode (Lazy.toStrict (serialise wire)))
  (settled, completed) =
    mustRight
      ( stepRegisteredProviderSettlement
          CallerOperatorCli
          generation
          operation
          providerAwsScopeIntent
          receipt
          pending
      )
  -- Force the settlement decision before returning the fixture.
  checked = case settled of
    AuthorityProviderSettlementCompleted -> ()
    other -> error ("scope settlement failed: " <> show other)

mustRight :: (Show err) => Either err value -> value
mustRight = either (error . show) id
