{-# LANGUAGE OverloadedStrings #-}

module LifecycleAuthorityCutover
  ( lifecycleAuthorityCutoverSuite
  )
where

import Data.ByteString (ByteString)
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.ControlPlane.ProjectionImportEndpoint
import Prodbox.Lifecycle.Authority.Admission
  ( AuthorityAdmissionCommandRefusal (AuthorityMigrationNotStarted)
  )
import Prodbox.Lifecycle.Authority.Cutover
import Prodbox.Lifecycle.Authority.Migration
  ( MigrationAuthorityStatus (..)
  , MigrationCommand (..)
  , MigrationEpoch
  , MigrationImportCommand (..)
  , MigrationImportDecision (..)
  , MigrationProjection (..)
  , MigrationProjectionImport (ProjectionMissing)
  , MigrationState
  , initialMigrationState
  , migrationAuthorityStatus
  , mkMigrationEpoch
  , stepMigration
  , stepMigrationImport
  )
import Prodbox.Lifecycle.Authority.MigrationInterpreter
  ( MigrationRepository (..)
  , StoredMigration (..)
  )
import Prodbox.Lifecycle.Authority.ProjectionImport
import Prodbox.Lifecycle.CheckpointAuthority
  ( mkTargetClusterSecretSink
  )
import Prodbox.Lifecycle.Lease (defaultSesLeasePolicy)
import Prodbox.Lifecycle.TargetCommitIntent
  ( RegisteredTargetSet
  , mkRegisteredTargetSet
  )
import TestSupport

lifecycleAuthorityCutoverSuite :: SuiteBuilder ()
lifecycleAuthorityCutoverSuite =
  describe "Sprint 4.50 closed projection import and cutover" $ do
    it "accepts only projection-selection requests and completes all four imports" $ do
      stateRef <- newIORef Nothing
      revisionRef <- newIORef (0 :: Word)
      let repository = inMemoryRepository stateRef revisionRef
      mapM_
        ( \projection -> do
            result <-
              serveProjectionImportRequest
                4096
                4096
                codecConfig
                repository
                missingSource
                missingTarget
                (encodeProjectionImportRequest (ImportLegacyProjection projection))
            projectionImportEndpointHttpStatus result `shouldBe` 200
            projectionImportEndpointSummary result `shouldBe` "projection-import-accepted"
        )
        requiredCutoverProjections
      completed <-
        serveProjectionImportRequest
          4096
          4096
          codecConfig
          repository
          missingSource
          missingTarget
          (encodeProjectionImportRequest CompleteLegacyProjectionImports)
      projectionImportEndpointHttpStatus completed `shouldBe` 200
      projectionImportEndpointSummary completed `shouldBe` "projection-imports-accepted"

    it "refuses malformed import bytes before observing either store" $ do
      sourceReads <- newIORef (0 :: Int)
      targetReads <- newIORef (0 :: Int)
      let source =
            LegacyProjectionSource $ \_ -> do
              modifyIORef' sourceReads (+ 1)
              pure (LegacyProjectionMissing :: LegacyProjectionObservation Word)
          target =
            ProjectionImportTarget
              { observeImportedProjection = \_ -> do
                  modifyIORef' targetReads (+ 1)
                  pure (ProjectionTargetMissing :: ProjectionTargetObservation Word)
              , initializeImportedProjection = \_ _ ->
                  pure (ProjectionTargetWriteUnobservable "must not write")
              }
      stateRef <- newIORef Nothing
      revisionRef <- newIORef (0 :: Word)
      result <-
        serveProjectionImportRequest
          4096
          4096
          codecConfig
          (inMemoryRepository stateRef revisionRef)
          source
          target
          "not-cbor"
      projectionImportEndpointHttpStatus result `shouldBe` 400
      readIORef sourceReads `shouldReturn` 0
      readIORef targetReads `shouldReturn` 0

    it "preserves a typed aggregate refusal through the applicator endpoint" $ do
      appliedCommands <- newIORef []
      let applicator =
            mkMigrationImportCommandApplicator $ \command -> do
              modifyIORef' appliedCommands (command :)
              pure
                ( Left
                    ( MigrationImportAuthorityRefused
                        AuthorityMigrationNotStarted
                    )
                )
      result <-
        serveProjectionImportRequestWithApplicator
          4096
          codecConfig
          applicator
          missingSource
          missingTarget
          (encodeProjectionImportRequest (ImportLegacyProjection LeaseProjection))
      projectionImportEndpointHttpStatus result `shouldBe` 409
      projectionImportEndpointSummary result
        `shouldBe` "projection-import-authority-refused:not-started"
      readIORef appliedCommands
        `shouldReturn` [RecordProjectionImport LeaseProjection ProjectionMissing]

    it "runs import, stable shadow, suspend, freeze, every binding, activate, and exact readback" $ do
      shadow <- missingShadowProof
      stateRef <- newIORef initialMigrationState
      logRef <- newIORef ([] :: [String])
      boundary <- cutoverBoundary stateRef logRef (repeat shadow)
      result <-
        runAuthorityCutover
          boundary
          epoch
      result `shouldBe` Right (AuthorityCutoverActivated epoch (projectionShadowDigest shadow))
      readIORef logRef
        `shouldReturn` expectedCutoverLog
      (migrationAuthorityStatus <$> readIORef stateRef)
        `shouldReturn` MigrationReplacementWriterActive epoch

    it "fails closed before durable freeze when the post-suspend shadow digest moves" $ do
      initialShadow <- missingShadowProof
      changedShadow <- checkpointShadowProof
      stateRef <- newIORef initialMigrationState
      logRef <- newIORef ([] :: [String])
      boundary <- cutoverBoundary stateRef logRef [initialShadow, changedShadow]
      result <-
        runAuthorityCutover
          boundary
          epoch
      result
        `shouldBe` Left
          ( AuthorityCutoverShadowChanged
              CutoverPostSuspendShadow
              (projectionShadowDigest initialShadow)
              (projectionShadowDigest changedShadow)
          )
      (migrationAuthorityStatus <$> readIORef stateRef)
        `shouldReturn` MigrationLegacyWriterActive

    it "returns from exact active-epoch readback without replaying legacy effects" $ do
      shadow <- missingShadowProof
      active <- activatedState epoch
      stateRef <- newIORef active
      logRef <- newIORef ([] :: [String])
      boundary <- cutoverBoundary stateRef logRef (repeat shadow)
      result <-
        runAuthorityCutover
          boundary
          epoch
      result `shouldBe` Right (AuthorityCutoverAlreadyActive epoch)
      readIORef logRef `shouldReturn` ["observe-authority"]

cutoverBoundary
  :: IORef MigrationState
  -> IORef [String]
  -> [ProjectionShadowProof]
  -> IO (AuthorityCutoverBoundary IO)
cutoverBoundary stateRef logRef shadows = do
  shadowRef <- newIORef shadows
  pure
    AuthorityCutoverBoundary
      { cutoverObserveAuthority = do
          record "observe-authority"
          Right . migrationAuthorityStatus <$> readIORef stateRef
      , cutoverImportProjection = \projection -> do
          record ("import:" ++ show projection)
          applyImport (RecordProjectionImport projection ProjectionMissing)
      , cutoverCompleteImports = do
          record "imports:complete"
          applyImport CompleteProjectionImports
      , cutoverObserveShadow = do
          record "shadow"
          atomicModifyIORef' shadowRef nextShadow
      , cutoverSuspendLegacyWritersAndReadBack = \_ -> do
          record "legacy:suspend-readback"
          pure (Right ())
      , cutoverPrepareBindingAndReadBack = \binding -> do
          record ("binding:prepare-readback:" ++ show binding)
          pure (Right ())
      , cutoverApplyMigration = \command -> do
          record (migrationLogToken command)
          decision <- applyMigration command
          pure (Right decision)
      }
 where
  nextShadow remaining = case remaining of
    [] -> ([], Left "shadow fixture exhausted")
    next : rest -> (rest, Right next)
  record entry = modifyIORef' logRef (++ [entry])
  applyImport command = do
    state <- readIORef stateRef
    let (next, decision) = stepMigrationImport state command
    writeIORef stateRef next
    pure $ case decision of
      MigrationImportAccepted -> Right ()
      MigrationImportAlreadyApplied -> Right ()
      MigrationImportRefused refusal -> Left ("import refused: " <> showText refusal)
  applyMigration command =
    atomicModifyIORef' stateRef $ \state ->
      let (next, decision) = stepMigration state command
       in (next, decision)

migrationLogToken :: MigrationCommand -> String
migrationLogToken command = case command of
  VerifyShadow _ -> "migration:verify-shadow"
  FreezeLegacy _ -> "migration:freeze"
  PrepareBinding binding -> "migration:prepare:" ++ show binding
  ActivateReplacement _ -> "migration:activate"
  RequestLegacyRollback -> "migration:rollback"

missingShadowProof :: IO ProjectionShadowProof
missingShadowProof =
  mustRightIO
    (shadowCompareLegacyProjections codecConfig missingSource missingTarget)

checkpointShadowProof :: IO ProjectionShadowProof
checkpointShadowProof =
  mustRightIO
    ( shadowCompareLegacyProjections
        codecConfig
        checkpointSource
        checkpointTarget
    )

missingSource :: LegacyProjectionSource IO Word
missingSource =
  LegacyProjectionSource
    (\_ -> pure LegacyProjectionMissing)

missingTarget :: ProjectionImportTarget IO Word
missingTarget =
  ProjectionImportTarget
    { observeImportedProjection = \_ -> pure ProjectionTargetMissing
    , initializeImportedProjection = \_ _ ->
        pure (ProjectionTargetWriteUnobservable "unexpected initialize")
    }

checkpointSource :: LegacyProjectionSource IO Word
checkpointSource =
  LegacyProjectionSource $ \projection ->
    pure $ case projection of
      CheckpointProjection -> LegacyProjectionObserved 1 checkpointBytes
      _ -> LegacyProjectionMissing

checkpointTarget :: ProjectionImportTarget IO Word
checkpointTarget =
  ProjectionImportTarget
    { observeImportedProjection = \projection ->
        pure $ case projection of
          CheckpointProjection -> ProjectionTargetObserved 1 checkpointBytes
          _ -> ProjectionTargetMissing
    , initializeImportedProjection = \_ _ ->
        pure (ProjectionTargetWriteUnobservable "unexpected initialize")
    }

checkpointBytes :: ByteString
checkpointBytes = "{\"version\":3,\"deployment\":{}}"

codecConfig :: ProjectionImportCodecConfig
codecConfig =
  mustRight
    (mkProjectionImportCodecConfig defaultSesLeasePolicy registeredTargets 4096)

registeredTargets :: RegisteredTargetSet
registeredTargets =
  mustRight
    ( mkRegisteredTargetSet
        1
        [ mustRight
            ( mkTargetClusterSecretSink
                "home"
                "secret"
                "keycloak/smtp"
            )
        ]
    )

epoch :: MigrationEpoch
epoch = mustJust (mkMigrationEpoch 1)

activatedState
  :: MigrationEpoch
  -> IO MigrationState
activatedState targetEpoch = do
  shadow <- missingShadowProof
  let importCommands =
        [ RecordProjectionImport projection ProjectionMissing
        | projection <- requiredCutoverProjections
        ]
      imported = foldl applyImportState initialMigrationState importCommands
      completed = applyImportState imported CompleteProjectionImports
      digest = projectionShadowDigest shadow
      migrated =
        foldl
          apply
          completed
          ( [VerifyShadow digest, FreezeLegacy digest]
              ++ fmap PrepareBinding requiredCutoverBindings
              ++ [ActivateReplacement targetEpoch]
          )
  pure migrated
 where
  apply state command = fst (stepMigration state command)
  applyImportState state command = fst (stepMigrationImport state command)

expectedCutoverLog :: [String]
expectedCutoverLog =
  [ "observe-authority"
  ]
    ++ fmap ("import:" ++) (map show requiredCutoverProjections)
    ++ [ "imports:complete"
       , "shadow"
       , "migration:verify-shadow"
       , "legacy:suspend-readback"
       , "shadow"
       , "migration:freeze"
       , "observe-authority"
       , "shadow"
       ]
    ++ concatMap
      ( \binding ->
          [ "binding:prepare-readback:" ++ show binding
          , "migration:prepare:" ++ show binding
          ]
      )
      requiredCutoverBindings
    ++ [ "migration:activate"
       , "observe-authority"
       ]

inMemoryRepository
  :: IORef (Maybe (StoredMigration Word))
  -> IORef Word
  -> MigrationRepository IO Word
inMemoryRepository stateRef revisionRef =
  MigrationRepository
    { readMigrationState = Right <$> readIORef stateRef
    , compareAndSwapMigrationState = \expected bytes -> do
        current <- readIORef stateRef
        if fmap storedMigrationRevision current /= expected
          then pure (Right False)
          else do
            revision <- atomicModifyIORef' revisionRef (\value -> (value + 1, value + 1))
            writeIORef stateRef (Just (StoredMigration revision bytes))
            pure (Right True)
    }

mustRightIO :: IO (Either error value) -> IO value
mustRightIO action = do
  result <- action
  case result of
    Left _ -> fail "expected Right"
    Right value -> pure value

mustRight :: (Show error) => Either error value -> value
mustRight value = case value of
  Left err -> error (show err)
  Right result -> result

mustJust :: Maybe value -> value
mustJust value = case value of
  Nothing -> error "expected Just"
  Just result -> result

showText :: (Show value) => value -> Text
showText = Text.pack . show
