{-# LANGUAGE OverloadedStrings #-}

module EpochPromotionFixture
  ( epochTopologyFixture
  , epochTopologyFixtureDigest
  , epochPromotionCommands
  , preparedEpochCommands
  , committedEpochCommands
  , promotedEpochCommands
  , epochReadback
  , epochRequest
  , epochFixtureDigest
  , epochFixtureEpoch
  , importedFrozenEpochAggregate
  , importedFrozenEpochAggregateWithClients
  , applyEpochAggregateCommand
  )
where

import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Prodbox.Lifecycle.Authority.Admission
import Prodbox.Lifecycle.Authority.ClientRegistry (RegisteredClientTable)
import Prodbox.Lifecycle.Authority.EpochPromotion
import Prodbox.Lifecycle.Authority.EpochTopology
import Prodbox.Lifecycle.Authority.Genesis
import Prodbox.Lifecycle.Authority.Migration

epochFixtureDigest :: MigrationDigest
epochFixtureDigest = fromJust (mkMigrationDigest "epoch-promotion-shadow")

epochFixtureEpoch :: Word -> MigrationEpoch
epochFixtureEpoch = fromJust . mkMigrationEpoch

epochTopologyFixture :: EpochTopology
epochTopologyFixture =
  either (error . show) id (mkEpochTopology substrates scopes dns rows)
 where
  substrates = Set.fromList [CutoverHome, CutoverAws]
  scopes = Set.fromList [(CutoverHome, digest 'a'), (CutoverAws, digest 'b')]
  dns = Set.fromList [(CutoverHome, digest 'c'), (CutoverAws, digest 'd')]
  rows = Map.fromSet (const (digest 'e')) (requiredEpochTopologyBindings substrates scopes dns)
  digest character = fromJust (mkCutoverDigest (Text.replicate 64 (Text.singleton character)))

epochTopologyFixtureDigest :: CutoverDigest
epochTopologyFixtureDigest = epochTopologyDigest epochTopologyFixture

epochReadback :: EpochTopologyBinding -> EpochBindingReadback
epochReadback binding = EpochBindingReadback binding (fromJust (epochTopologyBindingDigest epochTopologyFixture binding))

epochRequest :: Word -> EpochPromotionAction -> MigrationCommand
epochRequest target action =
  ApplyPreparedEpochPromotion (EpochPromotionRequest target epochTopologyFixtureDigest action)

preparedEpochCommands :: Word -> Word -> [MigrationCommand]
preparedEpochCommands predecessor target =
  [ PrepareReplacementEpoch
      (epochFixtureEpoch predecessor)
      (epochFixtureEpoch target)
      epochTopologyFixture
  ]
    ++ [epochRequest target (ObservePreparedEpochBinding (epochReadback binding)) | binding <- bindings]
    ++ [ epochRequest target (ObserveOldEpochRejected (epochReadback binding) predecessor)
       | binding <- oldWriters
       ]

committedEpochCommands :: Word -> Word -> [MigrationCommand]
committedEpochCommands predecessor target =
  preparedEpochCommands predecessor target ++ [epochRequest target CommitFrozenEpoch]

promotedEpochCommands :: Word -> Word -> [MigrationCommand]
promotedEpochCommands predecessor target =
  committedEpochCommands predecessor target
    ++ [epochRequest target (ObservePromotedEpochBinding (epochReadback binding)) | binding <- bindings]
    ++ [ epochRequest target (ObserveOldEpochRejected (epochReadback binding) predecessor)
       | binding <- oldWriters
       ]

epochPromotionCommands :: Word -> Word -> [MigrationCommand]
epochPromotionCommands predecessor target =
  promotedEpochCommands predecessor target ++ [epochRequest target OpenEpochAdmission]

bindings :: [EpochTopologyBinding]
bindings = Set.toList (epochTopologyBindings epochTopologyFixture)

oldWriters :: [EpochTopologyBinding]
oldWriters = Set.toList (epochTopologyOldWriterBindings epochTopologyFixture)

importedFrozenEpochAggregate :: AuthorityAdmissionAggregate
importedFrozenEpochAggregate = initializeImportedEpoch (either (error . show) id (initialMigratingAuthority 4 8))

importedFrozenEpochAggregateWithClients :: RegisteredClientTable -> AuthorityAdmissionAggregate
importedFrozenEpochAggregateWithClients registry =
  initializeImportedEpoch
    (either (error . show) id (initialMigratingAuthorityWithRegisteredClients 4 8 registry))

initializeImportedEpoch :: AuthorityAdmissionAggregate -> AuthorityAdmissionAggregate
initializeImportedEpoch initial = foldl applyEpochAggregateCommand initial commands
 where
  commands =
    [ ApplyAuthorityGenesis (BeginGenesisEstablishment (GenesisPlan "epoch-proof" "backup-prefix"))
    , ApplyAuthorityGenesis
        (ObserveTargetAgentGeneration (TargetAgentGenerationReceipt "target-generation-1"))
    , ApplyAuthorityGenesis (ObserveBackupReceipt (BackupReceipt "backup-receipt-1"))
    ]
      ++ [ ApplyAuthorityMigrationImport (RecordProjectionImport projection ProjectionMissing)
         | projection <- [minBound .. maxBound]
         ]
      ++ [ ApplyAuthorityMigrationImport CompleteProjectionImports
         , ApplyAuthorityMigration (VerifyShadow epochFixtureDigest)
         , ApplyAuthorityMigration (FreezeLegacy epochFixtureDigest)
         ]

applyEpochAggregateCommand
  :: AuthorityAdmissionAggregate -> AuthorityAdmissionCommand -> AuthorityAdmissionAggregate
applyEpochAggregateCommand aggregate command = snd (stepAuthorityAdmission aggregate command)
