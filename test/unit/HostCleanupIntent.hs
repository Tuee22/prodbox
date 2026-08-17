{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

module HostCleanupIntent
  ( hostCleanupIntentSuite
  )
where

import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric.Natural (Natural)
import Prodbox.ControlPlane.CapabilityKind (CapabilityKind (ManagedDestroy))
import Prodbox.ControlPlane.CapabilityRef (CapabilityRef, mkCapabilityRef)
import Prodbox.ControlPlane.Coordinate
  ( CapabilityCoordinate
  , mkAuthorityScope
  , mkCapabilityEndpoint
  , mkCoordinate
  , mkLogicalName
  , mkServiceIdentity
  )
import Prodbox.Lifecycle.CleanupRun
import Prodbox.Lifecycle.HostCleanupIntent
import Prodbox.Lifecycle.TargetCommitIntent
  ( CredentialGeneration
  , mkCredentialGeneration
  )
import Prodbox.Lifecycle.Teardown.Model
  ( AwsAccountId (..)
  , AwsRegion (..)
  , AwsScope (..)
  , CleanupSurface (..)
  , DurableObservationRunScope (..)
  , LifecycleOperation (..)
  , LinuxRke2FoundationId (..)
  , ObservationEvidenceScope
  , RegistryRevision (..)
  , mkObservationEvidenceScope
  )
import System.Directory
  ( createFileLink
  , doesFileExist
  )
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files
  ( accessModes
  , fileMode
  , getFileStatus
  , intersectFileModes
  , ownerModes
  , ownerReadMode
  , ownerWriteMode
  , setFileMode
  , unionFileModes
  )
import TestSupport

hostCleanupIntentSuite :: SuiteBuilder ()
hostCleanupIntentSuite =
  describe "host-durable cleanup intent" $ do
    it "binds the full secret-free cascade observation scope to the cleanup run" $ do
      hostCleanupObservationEvidenceScope fixtureScope `shouldBe` fixtureEvidence fixtureRunId
      hostCleanupFoundationId fixtureScope `shouldBe` LinuxRke2FoundationId "home-rke2"
      hostCleanupObservationRunScope fixtureScope
        `shouldBe` DurableObservationRunScope (cleanupRunIdText fixtureRunId)
      mkHostCleanupScope
        fixtureRunId
        (mkEvidence LocalOnly ReconcileDesiredAbsent fixtureRunId fixtureAwsScope)
        `shouldBe` Left (HostCleanupIntentScopeSurfaceMismatch LocalOnly)
      mkHostCleanupScope
        fixtureRunId
        (mkEvidence Cascade ReconcileDesiredPresent fixtureRunId fixtureAwsScope)
        `shouldBe` Left (HostCleanupIntentScopeOperationMismatch ReconcileDesiredPresent)
      mkHostCleanupScope
        fixtureRunId
        (mkEvidence Cascade ReconcileDesiredAbsent otherRunId fixtureAwsScope)
        `shouldBe` Left HostCleanupIntentScopeRunIdMismatch
      mkHostCleanupScope
        fixtureRunId
        ( mkEvidence
            Cascade
            ReconcileDesiredAbsent
            fixtureRunId
            (Just (AwsScope (AwsAccountId "not-an-account") (AwsRegion "us-east-1")))
        )
        `shouldSatisfy` isIdentityInvalid

    it "round-trips one bounded canonical versioned envelope with its full CleanupRun" $ do
      let encoded = expectRight (encodeHostCleanupIntent fixtureIntent)
      hostCleanupIntentFormatVersion `shouldBe` 2
      ByteString.length encoded `shouldSatisfy` (<= maximumHostCleanupIntentBytes)
      decodeHostCleanupIntent encoded `shouldBe` Right fixtureIntent
      decodeHostCleanupIntent (ByteString.snoc encoded 0)
        `shouldBe` Left HostCleanupIntentNonCanonical
      decodeHostCleanupIntent (ByteString.take (ByteString.length encoded - 1) encoded)
        `shouldSatisfy` isDecodeFailure
      decodeHostCleanupIntent (ByteString.replicate (maximumHostCleanupIntentBytes + 1) 0)
        `shouldBe` Left
          ( HostCleanupIntentEncodedTooLarge
              (maximumHostCleanupIntentBytes + 1)
              maximumHostCleanupIntentBytes
          )
      hostCleanupRun (expectRight (decodeHostCleanupIntent encoded)) `shouldBe` fixtureRun

    it "keeps opaque Ready persistence, phase replay, and retirement behind one fixed regression" $ do
      regression <- expectIoRight fixedHostCleanupIntentRegression
      hostCleanupIntentRegressionBoundCodec regression `shouldBe` True
      hostCleanupIntentRegressionBoundPreparationRefused regression `shouldBe` True
      hostCleanupIntentRegressionReadyReadBack regression `shouldBe` True
      hostCleanupIntentRegressionPhaseReplay regression `shouldBe` True
      hostCleanupIntentRegressionRetirementReplay regression `shouldBe` True

    it "rejects explicit run and graph bindings that disagree with the encoded CleanupRun" $ do
      mkHostCleanupIntent
        otherRunId
        (cleanupRunGraphDigest fixtureRun)
        fixtureRun
        fixtureScope
        fixtureTerminal
        `shouldBe` Left HostCleanupIntentRunIdMismatch
      mkHostCleanupIntent
        fixtureRunId
        (cleanupRunGraphDigest alternateRun)
        fixtureRun
        fixtureScope
        fixtureTerminal
        `shouldBe` Left HostCleanupIntentGraphDigestMismatch

    it "does not advance an unbound intent into an authority-bearing phase" $ do
      advanceHostCleanupIntent HostCleanupAuthorityAccepted Nothing fixtureIntent
        `shouldBe` Left
          (HostCleanupIntentReadyBindingRequired HostCleanupAuthorityAccepted)

    it "prepares, fsync-publishes, positively reads back, and reopens the exact intent" $
      withSystemTempDirectory "prodbox-host-cleanup-prepare" $ \retainedRoot -> do
        let store = storeUnder retainedRoot
        observeHostCleanupIntent store `shouldReturn` Right Nothing
        prepared <- expectIoRight (prepareHostCleanupIntent store fixtureIntent)
        prepared `shouldBe` fixtureIntent
        prepareHostCleanupIntent store fixtureIntent `shouldReturn` Right fixtureIntent
        let reopenedStore = storeUnder retainedRoot
        observeHostCleanupIntent reopenedStore `shouldReturn` Right (Just fixtureIntent)
        bytes <- ByteString.readFile (hostCleanupIntentPath store)
        bytes `shouldBe` expectRight (encodeHostCleanupIntent fixtureIntent)
        activeStatus <- getFileStatus (hostCleanupIntentPath store)
        (fileMode activeStatus `intersectFileModes` accessModes)
          `shouldBe` (ownerReadMode `unionFileModes` ownerWriteMode)
        directoryStatus <- getFileStatus (takeDirectory (hostCleanupIntentPath store))
        (fileMode directoryStatus `intersectFileModes` accessModes)
          `shouldBe` ownerModes

    it "never replaces a stale active run, graph, scope, terminal identity, or phase" $
      withSystemTempDirectory "prodbox-host-cleanup-conflicts" $ \retainedRoot -> do
        let store = storeUnder retainedRoot
            scopeConflict =
              expectRight
                ( mkHostCleanupScope
                    fixtureRunId
                    ( mkObservationEvidenceScope
                        Cascade
                        (RegistryRevision "registry-v1")
                        (DurableObservationRunScope (cleanupRunIdText fixtureRunId))
                        (LinuxRke2FoundationId "other-rke2")
                        fixtureAwsScope
                        ReconcileDesiredAbsent
                    )
                )
            differentScopeIntent =
              expectRight
                ( mkHostCleanupIntent
                    fixtureRunId
                    (cleanupRunGraphDigest fixtureRun)
                    fixtureRun
                    scopeConflict
                    fixtureTerminal
                )
            differentTerminalIntent =
              expectRight
                ( mkHostCleanupIntent
                    fixtureRunId
                    (cleanupRunGraphDigest fixtureRun)
                    fixtureRun
                    fixtureScope
                    ( mkHostCleanupTerminalIdentity
                        (expectRight (mkCleanupOperationId "run-1/other-terminal"))
                        (expectRight (mkHostTerminalPermitId "permit-run-1-other"))
                    )
                )
            alternateIntent = intentForRun alternateRun fixtureScope
            otherIntent = intentForRun otherRun otherScope
        _ <- expectIoRight (prepareHostCleanupIntent store fixtureIntent)
        prepareHostCleanupIntent store differentScopeIntent
          `shouldReturn` Left HostCleanupIntentActiveConflict
        prepareHostCleanupIntent store differentTerminalIntent
          `shouldReturn` Left HostCleanupIntentActiveConflict
        prepareHostCleanupIntent store alternateIntent
          `shouldReturn` Left HostCleanupIntentActiveConflict
        prepareHostCleanupIntent store otherIntent
          `shouldReturn` Left HostCleanupIntentActiveConflict
        observeHostCleanupIntent store `shouldReturn` Right (Just fixtureIntent)

    it "fails closed on noncanonical, oversized, permissive-mode, and symlinked files" $ do
      withSystemTempDirectory "prodbox-host-cleanup-corrupt" $ \retainedRoot -> do
        let store = storeUnder retainedRoot
        _ <- expectIoRight (prepareHostCleanupIntent store fixtureIntent)
        encoded <- ByteString.readFile (hostCleanupIntentPath store)
        ByteString.writeFile (hostCleanupIntentPath store) (ByteString.snoc encoded 0)
        observeHostCleanupIntent store `shouldSatisfyIO` isNonCanonical
      withSystemTempDirectory "prodbox-host-cleanup-oversized" $ \retainedRoot -> do
        let store = storeUnder retainedRoot
        _ <- expectIoRight (prepareHostCleanupIntent store fixtureIntent)
        ByteString.writeFile
          (hostCleanupIntentPath store)
          (ByteString.replicate (maximumHostCleanupIntentBytes + 1) 0)
        observeHostCleanupIntent store `shouldSatisfyIO` isEncodedTooLarge
      withSystemTempDirectory "prodbox-host-cleanup-mode" $ \retainedRoot -> do
        let store = storeUnder retainedRoot
        _ <- expectIoRight (prepareHostCleanupIntent store fixtureIntent)
        setFileMode (hostCleanupIntentPath store) ownerModes
        observeHostCleanupIntent store `shouldReturn` Left HostCleanupIntentFileModeInvalid
      withSystemTempDirectory "prodbox-host-cleanup-symlink" $ \retainedRoot -> do
        let store = storeUnder retainedRoot
            outside = retainedRoot </> "outside"
        observeHostCleanupIntent store `shouldReturn` Right Nothing
        ByteString.writeFile outside "do-not-touch"
        createFileLink outside (hostCleanupIntentPath store)
        observeHostCleanupIntent store `shouldSatisfyIO` isIoFailure
        ByteString.readFile outside `shouldReturn` "do-not-touch"

    it "opens the atomic temporary with nofollow and leaves a symlink target untouched" $
      withSystemTempDirectory "prodbox-host-cleanup-temp-symlink" $ \retainedRoot -> do
        let store = storeUnder retainedRoot
            outside = retainedRoot </> "outside"
            temporary = takeDirectory (hostCleanupIntentPath store) </> ".active-v1.cbor.tmp"
        observeHostCleanupIntent store `shouldReturn` Right Nothing
        ByteString.writeFile outside "preserve-me"
        createFileLink outside temporary
        prepareHostCleanupIntent store fixtureIntent `shouldSatisfyIO` isIoFailure
        ByteString.readFile outside `shouldReturn` "preserve-me"
        doesFileExist (hostCleanupIntentPath store) `shouldReturn` False

    it "rejects unsafe retained roots and bounded identity inputs" $ do
      mkHostCleanupIntentStore "relative/path"
        `shouldBe` Left (HostCleanupIntentStoreInvalid "retained root must be absolute")
      mkHostCleanupIntentStore "/"
        `shouldBe` Left
          ( HostCleanupIntentStoreInvalid
              "retained root must not be the filesystem root"
          )
      mkHostTerminalPermitId "" `shouldSatisfy` isIdentityInvalid
      mkHostTerminalPermitId ("x" <> Text.replicate 160 "x")
        `shouldSatisfy` isIdentityInvalid

storeUnder :: FilePath -> HostCleanupIntentStore
storeUnder = expectRight . mkHostCleanupIntentStore

fixtureIntent :: HostCleanupIntent
fixtureIntent = intentForRun fixtureRun fixtureScope

intentForRun :: CleanupRun -> HostCleanupScope -> HostCleanupIntent
intentForRun run scope =
  expectRight
    ( mkHostCleanupIntent
        (cleanupRunId run)
        (cleanupRunGraphDigest run)
        run
        scope
        fixtureTerminal
    )

fixtureScope, otherScope :: HostCleanupScope
fixtureScope = expectRight (mkHostCleanupScope fixtureRunId (fixtureEvidence fixtureRunId))
otherScope = expectRight (mkHostCleanupScope otherRunId (fixtureEvidence otherRunId))

fixtureEvidence :: CleanupRunId -> ObservationEvidenceScope
fixtureEvidence runId =
  mkEvidence Cascade ReconcileDesiredAbsent runId fixtureAwsScope

mkEvidence
  :: CleanupSurface
  -> LifecycleOperation
  -> CleanupRunId
  -> Maybe AwsScope
  -> ObservationEvidenceScope
mkEvidence surface operation runId awsScope =
  mkObservationEvidenceScope
    surface
    (RegistryRevision "registry-v1")
    (DurableObservationRunScope (cleanupRunIdText runId))
    (LinuxRke2FoundationId "home-rke2")
    awsScope
    operation

fixtureAwsScope :: Maybe AwsScope
fixtureAwsScope = Just (AwsScope (AwsAccountId "111122223333") (AwsRegion "ca-central-1"))

fixtureTerminal :: HostCleanupTerminalIdentity
fixtureTerminal =
  mkHostCleanupTerminalIdentity
    (expectRight (mkCleanupOperationId "run-1/destroy"))
    (expectRight (mkHostTerminalPermitId "permit-run-1"))

fixtureRun, alternateRun, otherRun :: CleanupRun
fixtureRun = cleanupRunFor fixtureRunId "cleanup/fixture-graph"
alternateRun = cleanupRunFor fixtureRunId "cleanup/alternate-graph"
otherRun = cleanupRunFor otherRunId "cleanup/other-run"

fixtureRunId, otherRunId :: CleanupRunId
fixtureRunId = expectRight (mkCleanupRunId "run-1")
otherRunId = expectRight (mkCleanupRunId "run-2")

cleanupRunFor :: CleanupRunId -> Text -> CleanupRun
cleanupRunFor runId logical =
  expectRight
    ( newCleanupRun
        runId
        ( expectRight
            ( mkCleanupGraph
                [ mkCleanupNodePlan
                    (destroyRef logical)
                    (expectRight (mkCleanupNodeId "destroy"))
                    (expectRight (mkCleanupOperationId (cleanupRunIdText runId <> "/destroy")))
                    []
                ]
            )
        )
        (expectRight (mkCleanupOwnerId "host-cleanup-runner"))
        0
        100
    )

generation :: Natural -> CredentialGeneration
generation = expectRight . mkCredentialGeneration

coordinate :: Text -> CapabilityCoordinate
coordinate logical =
  mkCoordinate
    (expectRight (mkServiceIdentity "test-harness"))
    (expectRight (mkAuthorityScope "home/prodbox"))
    (expectRight (mkCapabilityEndpoint "authority:8443"))
    (expectRight (mkLogicalName logical))
    (generation 1)

destroyRef :: Text -> CapabilityRef 'ManagedDestroy
destroyRef = mkCapabilityRef . coordinate

expectRight :: (Show errorType) => Either errorType value -> value
expectRight = either (error . show) id

expectIoRight :: (Show errorType) => IO (Either errorType value) -> IO value
expectIoRight action = expectRight <$> action

shouldSatisfyIO :: IO value -> (value -> Bool) -> IO ()
shouldSatisfyIO action predicate = action >>= (`shouldSatisfy` predicate)

isIdentityInvalid :: Either HostCleanupIntentError value -> Bool
isIdentityInvalid result = case result of
  Left HostCleanupIntentIdentityInvalid {} -> True
  _ -> False

isDecodeFailure :: Either HostCleanupIntentError value -> Bool
isDecodeFailure result = case result of
  Left HostCleanupIntentDecodeInvalid {} -> True
  _ -> False

isNonCanonical :: Either HostCleanupIntentError value -> Bool
isNonCanonical result = case result of
  Left HostCleanupIntentNonCanonical -> True
  _ -> False

isEncodedTooLarge :: Either HostCleanupIntentError value -> Bool
isEncodedTooLarge result = case result of
  Left HostCleanupIntentEncodedTooLarge {} -> True
  _ -> False

isIoFailure :: Either HostCleanupIntentError value -> Bool
isIoFailure result = case result of
  Left HostCleanupIntentIoFailure {} -> True
  _ -> False
