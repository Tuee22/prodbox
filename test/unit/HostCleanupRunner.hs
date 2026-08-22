module HostCleanupRunner
  ( hostCleanupRunnerSuite
  )
where

import Control.Monad (filterM)
import Data.Char (isAlphaNum)
import Data.List (sort)
import Prodbox.Lifecycle.HostCleanupRunner
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (takeExtension, (</>))
import TestSupport

hostCleanupRunnerSuite :: SuiteBuilder ()
hostCleanupRunnerSuite =
  describe "lifecycle-owned terminal host runner" $ do
    it
      "keeps exact success, response-loss replay, no-repeat, and lease fencing behind a fixed regression"
      $ do
        regression <- expectIoRight fixedHostCleanupRunnerRegression
        hostCleanupRunnerRegressionUnboundRefused regression `shouldBe` True
        hostCleanupRunnerRegressionFullTopology regression `shouldBe` True
        hostCleanupRunnerRegressionResponseLossRecovered regression `shouldBe` True
        hostCleanupRunnerRegressionConfirmedAbsenceNotRepeated regression
          `shouldBe` True
        hostCleanupRunnerRegressionWrongReadyRefused regression `shouldBe` True
        hostCleanupRunnerRegressionMissingCompletionRefused regression `shouldBe` True
        hostCleanupRunnerRegressionConcurrentLeaseFenced regression `shouldBe` True

    it "reaches the same completion one durable phase at a time" $ do
      -- Sprint 4.86: the compiled cascade graph reaches the destructive host
      -- boundary through separate nodes, so a node interpreter needs a caller
      -- that advances one phase.  Stepping is a different caller, not a
      -- different protocol: the same effects, the same completion, and the
      -- destructive uninstall still issued exactly once.
      regression <- expectIoRight fixedHostCleanupRunnerRegression
      hostCleanupRunnerRegressionSteppedTopology regression `shouldBe` True

    it "advances exactly one phase per step" $ do
      -- Without this the durable run would record one node as having performed
      -- every later node's effect, and a resume would have nothing left to
      -- attribute a failure to.
      regression <- expectIoRight fixedHostCleanupRunnerRegression
      hostCleanupRunnerRegressionStepStopsAtOnePhase regression `shouldBe` True

    it "exports no raw evidence remint input and keeps the read-back library-internal" $ do
      source <- readFile "src/Prodbox/Lifecycle/HostCleanupRunner.hs"
      facade <- exportedHeader source
      facade `shouldContain` "HostCleanupCompletionReadBack"
      facade `shouldNotContain` "CascadeCompletionReceiptObservation"
      facade `shouldNotContain` "mkLocalUninstallEvidence"
      facade `shouldNotContain` "mkCascadeCompleteEvidence"
      source `shouldNotContain` "DurableReadyToUninstallBinding"
      source `shouldNotContain` "decodeDurableReadyToUninstallBinding"
      source `shouldContain` "restoreObservedHostCleanupReady"
      source `shouldContain` "withHostCleanupExecutionLease"

    it "lets only the completion journal mint a completion read-back" $ do
      -- Sprint 4.86: the read-back's constructor is exported so its one
      -- producer -- the separate observation of the preserved cleanup journal
      -- -- can mint it.  What keeps that closed is not the export list but the
      -- record's own field: it carries a receipt observation whose type lives
      -- in a Cabal-hidden module, so no module outside this library can name
      -- the constructor at all.  This gate is therefore over the library, and
      -- a third producer has to be recorded here deliberately.
      --
      -- The match is over the name as a token rather than as a substring: a
      -- module that only calls the production arm
      -- `productionHostCleanupCompletionReadBack` never names the type, and a
      -- substring match reported it as a producer -- a gate reading its own
      -- spelling rather than the fact it exists to measure.
      sourceFiles <- haskellFiles "src"
      producers <- filterM (fileNames "HostCleanupCompletionReadBack") sourceFiles
      sort producers
        `shouldBe` [ "src/Prodbox/Lifecycle/HostCleanupCompletion.hs"
                   , "src/Prodbox/Lifecycle/HostCleanupRunner.hs"
                   ]

      -- Holding one still authorizes nothing.  The runner rebuilds the
      -- expected completion proof from the run's own readiness and absence
      -- evidence and refuses a read-back that does not equal it, so a
      -- fabricated record cannot close a run even inside the library.
      source <- readFile "src/Prodbox/Lifecycle/HostCleanupRunner.hs"
      source `shouldContain` "mkCascadeCompleteEvidence ready local receipt"
      source
        `shouldContain` "requireBinding\n    HostCleanupCompletionProofBinding\n    (hostCompletionReadBackEvidence readBack == expectedEvidence)"

expectIoRight :: (Show err) => IO (Either err value) -> IO value
expectIoRight action = do
  result <- action
  case result of
    Left err -> do
      expectationFailure (show err)
      error "unreachable"
    Right value -> pure value

haskellFiles :: FilePath -> IO [FilePath]
haskellFiles path = do
  isDirectory <- doesDirectoryExist path
  if isDirectory
    then do
      children <- listDirectory path
      concat <$> traverse (haskellFiles . (path </>)) children
    else pure [path | takeExtension path == ".hs"]

-- | Does the file name this identifier, rather than merely spell it inside a
-- longer one?
fileNames :: String -> FilePath -> IO Bool
fileNames needle path = do
  contents <- readFile path
  pure (needle `elem` words (map keepIdentifierCharacter contents))

keepIdentifierCharacter :: Char -> Char
keepIdentifierCharacter character
  | isAlphaNum character = character
  | character == '_' = character
  | character == '\'' = character
  | otherwise = ' '

exportedHeader :: String -> IO String
exportedHeader source = case break (== "where") (lines source) of
  (_, []) -> do
    expectationFailure "HostCleanupRunner export list has no where"
    pure ""
  (header, _) -> pure (unlines header)
