{-# LANGUAGE OverloadedStrings #-}

-- | The part of a qualification cycle's identity a process can recompute from
-- the repository alone.
--
-- The cycle runner computes these before it begins a cycle and the observer
-- computes them again afterwards, so both go through this one function and
-- cannot compute them two ways. It reads the bootstrap seed config, never the
-- in-force one: the in-force config lives in the Lifecycle Authority, which is
-- gone once the cascade has uninstalled the cluster.
module Prodbox.Test.CascadeQualificationLocal
  ( LocalRecomputeError (..)
  , renderLocalRecomputeError
  , recomputeLocalParts
  , recaptureExecutableKey
  , executableBinaryDigest
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.Bifunctor (first)
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Numeric (showHex)
import Prodbox.Settings
  ( renderConfigDhall
  , validateAndLoadBootstrapSettings
  , validatedConfig
  , validatedResourcePlan
  )
import Prodbox.Test.Qualification.CascadeCycleIdentity
  ( CycleIdentityParts
  , IdentityComponent (..)
  , IdentityKey
  , RecomputedLocalParts (..)
  , canonicalKeyPolicy
  , identityComponentName
  , identityKeyOfParts
  , refreshSourceParts
  )
import Prodbox.Test.Qualification.Evidence (PublicEvidenceDigest, hashPublicEvidence)
import Prodbox.Test.Qualification.SourceManifest (captureSourceIdentityPair)
import Prodbox.Test.Qualification.TeardownCounterexample
  ( TeardownTraceFixture (CanonicalTeardownTrace)
  , frozenTeardownCausalProfile
  , frozenTeardownExternalStateRows
  , frozenTeardownInterruptionSchedule
  , frozenTeardownProductionProfile
  , loadTeardownCounterexampleFixture
  )
import System.Environment (getExecutablePath)
import System.IO.Error (tryIOError)

-- | Why a part could not be recomputed, naming the component it belongs to. A
-- caller refuses on this; there is no state in which a part is "unchecked".
data LocalRecomputeError = LocalRecomputeUnavailable !IdentityComponent !Text
  deriving (Eq, Show)

renderLocalRecomputeError :: LocalRecomputeError -> String
renderLocalRecomputeError (LocalRecomputeUnavailable component detail) =
  "could not recompute the "
    ++ Text.unpack (identityComponentName component)
    ++ " of the qualification identity: "
    ++ Text.unpack detail

-- | Recompute the source, the generated config, the resource envelope and the
-- load and fault digest. The formulas are the ones the version-1 writer used
-- inline, so a digest here equals what a cycle has always recorded.
recomputeLocalParts :: FilePath -> IO (Either LocalRecomputeError RecomputedLocalParts)
recomputeLocalParts repoRoot = do
  sourceResult <- captureSourceIdentityPair repoRoot []
  settingsResult <- validateAndLoadBootstrapSettings repoRoot
  fixtureResult <- loadTeardownCounterexampleFixture repoRoot CanonicalTeardownTrace
  pure $ do
    (fullSource, executableSource) <-
      first
        (LocalRecomputeUnavailable ComponentSource . Text.pack . show)
        sourceResult
    settings <-
      first
        (LocalRecomputeUnavailable ComponentGeneratedConfig . Text.pack)
        settingsResult
    fixture <-
      first
        (LocalRecomputeUnavailable ComponentLoadFault . Text.pack . show)
        fixtureResult
    Right
      RecomputedLocalParts
        { localExecutableSource = executableSource
        , localFullSource = fullSource
        , localGeneratedConfig =
            hashPublicEvidence (Text.pack (renderConfigDhall (validatedConfig settings)))
        , localResourceEnvelope = digestShown (validatedResourcePlan settings)
        , localLoadFault =
            digestShown
              ( frozenTeardownExternalStateRows fixture
              , frozenTeardownInterruptionSchedule fixture
              , frozenTeardownCausalProfile fixture
              , frozenTeardownProductionProfile fixture
              )
        }
 where
  digestShown :: (Show value) => value -> PublicEvidenceDigest
  digestShown = hashPublicEvidence . Text.pack . show

-- | The key the executable source has now, for the parts a cycle began with.
--
-- A cycle certifies the tree it began on. After the candidate has run, the
-- source is captured again and only the source-derived parts are refreshed, so
-- a key that differs from the one the cycle began with says the executable
-- source moved while the cascade ran, and nothing else.
recaptureExecutableKey
  :: FilePath -> CycleIdentityParts -> IO (Either LocalRecomputeError IdentityKey)
recaptureExecutableKey repoRoot parts = do
  captured <- captureSourceIdentityPair repoRoot []
  pure $ do
    (_, executableSource) <-
      first (LocalRecomputeUnavailable ComponentSource . Text.pack . show) captured
    Right (identityKeyOfParts (refreshSourceParts canonicalKeyPolicy executableSource parts))

-- | The digest of the running executable, recorded beside a cycle and never keyed.
-- The cycle certifies the tree at its beginning, not the binary that ran, and
-- the built binary a developer runs is not refreshed by a build, so a receipt
-- says whether the observer's binary is the cycle's.
executableBinaryDigest :: IO (Maybe Text)
executableBinaryDigest = do
  pathResult <- tryIOError getExecutablePath
  case pathResult of
    Left _ -> pure Nothing
    Right path -> do
      bytesResult <- tryIOError (ByteString.readFile path)
      pure (either (const Nothing) (Just . hexOf . SHA256.hash) bytesResult)
 where
  hexOf = Text.pack . concatMap renderByte . ByteString.unpack
  renderByte byte = case showHex byte "" of
    [digit] -> ['0', digit]
    digits -> digits
