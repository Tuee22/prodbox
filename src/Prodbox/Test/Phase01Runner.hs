{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | The Phase 1 scenario runner: drive the built public binary through one
-- real lifecycle of an explicitly selected, already prepared test identity
-- (reconcile, status, delete, status), record what the public commands
-- claimed, then take separate observations with other tools (the Docker CLI,
-- kubectl against the installed credential, direct file reads), publish the
-- report in the append-only store and validate it against those independent
-- observations. A pass needs every claimed observation to agree with its
-- independent counterpart. The report is non-secret: only digests, outcomes and
-- fixed observation names. This runner owns isolation and cleanup, never
-- repairs by hand, and preserves a failed primary result separately from the
-- cleanup result.
module Prodbox.Test.Phase01Runner
  ( runPhase01Scenario
  ) where

import Control.Concurrent (threadDelay)

import Control.Exception (IOException, try)
import Data.Bifunctor qualified as Bifunctor
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString8
import Data.List (isInfixOf, sort)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Data.Word (Word16)
import GHC.Clock (getMonotonicTimeNSec)
import Prodbox.Aws.SigV4 (hexSha256)
import Prodbox.CLI.Output (writeOutputLine)
import Prodbox.Config.BootstrapProjection
  ( ArtifactDeclaration (..)
  , BootstrapProjection
  , bootstrapKindPlan
  , bootstrapKindTool
  , bootstrapNodeArtifact
  , bootstrapRootGeneration
  , bootstrapScope
  , readBootstrapProjection
  )
import Prodbox.Config.DeploymentScope
  ( DeploymentEnvironment (Test)
  , scopeApiPort
  , scopeEnvironment
  , scopeIdentifier
  , scopeKindName
  , scopeRoot
  )
import Prodbox.Config.KindPlan (renderKindConfig)
import Prodbox.Control.NetworkEnforcement
  ( EnforcementOutcome (..)
  , enforcementProven
  , observeNetworkEnforcement
  )
import Prodbox.Subprocess
  ( BoundedSubprocessLimits (..)
  , ProcessOutput (..)
  , Subprocess (..)
  , captureSubprocessWithInputBounded
  )
import Prodbox.Test.Qualification.Evidence (PublicEvidenceDigest, hashPublicEvidence)
import Prodbox.Test.Qualification.SourceManifest (captureSourceIdentity)
import Prodbox.Test.ScenarioEvidence
  ( EvidenceComparison (..)
  , IndependentScenarioObservation (..)
  , ObservationResult (..)
  , ScenarioBinding (..)
  , ScenarioBudget (..)
  , ScenarioCleanup (..)
  , ScenarioObservation (..)
  , ScenarioPrimary (..)
  , ScenarioReport (..)
  , ScenarioTiming (..)
  )
import Prodbox.Test.ScenarioEvidenceStore (validateStoredScenarioReport, writeScenarioReport)
import System.Directory
  ( createDirectoryIfMissing
  , doesDirectoryExist
  , doesFileExist
  , getFileSize
  , listDirectory
  , removePathForcibly
  )
import System.Environment (getExecutablePath)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO (IOMode (ReadMode), withBinaryFile)
import System.Posix.Files (createSymbolicLink, setFileMode)

limits :: BoundedSubprocessLimits
limits = BoundedSubprocessLimits 1 (512 * 1024) (64 * 1024) 1200000000

-- | Run one command with a closed stdin and bounded output. A failure to run
-- is returned, never mapped to an exit status.
run :: FilePath -> [String] -> IO (Either String (Int, String, String))
run program arguments = do
  result <-
    captureSubprocessWithInputBounded
      limits
      ByteString.empty
      ( Subprocess
          program
          arguments
          ( Just
              [ ("PATH", "/usr/bin:/bin:/home/matthewnowak/.local/bin")
              , ("HOME", "/nonexistent")
              , ("XDG_RUNTIME_DIR", "/run/user/1000")
              ]
          )
          Nothing
      )
  pure $ case result of
    Right output ->
      Right
        ( case processExitCode output of
            ExitSuccess -> 0
            ExitFailure code -> code
        , processStdout output
        , processStderr output
        )
    Left failure -> Left (show failure)

satisfied :: Bool -> ObservationResult
satisfied True = ObservationSatisfied
satisfied False = ObservationViolated

hex32 :: ByteString.ByteString -> String
hex32 = take 32 . ByteString8.unpack . hexSha256

digest :: String -> PublicEvidenceDigest
digest = hashPublicEvidence . Text.pack

-- | Run the lifecycle scenario for the identity the explicit config selects.
-- The identity must already hold its root, kind tool and node archive; the
-- runner never creates them or reads anything outside that identity.
runPhase01Scenario :: FilePath -> IO ExitCode
runPhase01Scenario selected = do
  loaded <- readBootstrapProjection selected
  case loaded of
    Left failure -> refuse ("cannot read the selected config: " ++ show failure)
    Right projection
      | scopeEnvironment (bootstrapScope projection) /= Test ->
          refuse "the scenario runner accepts only a test identity"
      | otherwise -> scenario selected projection
 where
  refuse message = writeOutputLine ("phase-01 scenario refused: " ++ message) >> pure (ExitFailure 2)

-- One pass, two lifecycles on the same retained root, three reports:
-- case 1 the lifecycle (scope, readiness, cleanup, retained host data),
-- case 4 the NetworkPolicy enforcement observation, case 2 recreation after the
-- node's removal with a random marker written by a real Pod surviving.
scenario :: FilePath -> BootstrapProjection -> IO ExitCode
scenario selected projection = do
  let scope = bootstrapScope projection
      cluster = scopeKindName scope
      root = scopeRoot scope
      project = takeDirectory (takeDirectory root)
      kubeconfig = root </> "control" </> "kubeconfig"
      generation = Text.unpack (bootstrapRootGeneration projection)
      nodeArchive = bootstrapNodeArtifact projection
      toolArtifact = bootstrapKindTool projection
  executable <- getExecutablePath
  binaryBytes <- ByteString.readFile executable
  boot <- try (readFile "/proc/sys/kernel/random/boot_id") :: IO (Either IOException String)
  sourceResult <- captureSourceIdentity "." []
  randomBytes <- readRandom
  started <- getMonotonicTimeNSec
  case sourceResult of
    Left failure -> writeOutputLine ("source identity refused: " ++ show failure) >> pure (ExitFailure 2)
    Right source -> do
      let second = 1000000000
          budget = ScenarioBudget (started + 1500 * second) (started + 2400 * second) (1024 * 1048576) 1800000000 0
          artifacts =
            [ ("kind.tool", digest (maybe "" artifactDigest toolArtifact))
            , ("node.archive", digest (maybe "" artifactDigest nodeArchive))
            ]
          bindingFor :: Word16 -> String -> ScenarioBinding
          bindingFor caseNumber label =
            ScenarioBinding
              1
              caseNumber
              scope
              generation
              (hex32 (randomBytes <> "run"))
              (hex32 (randomBytes <> "operation" <> ByteString8.pack label))
              (hex32 (ByteString8.pack (either (const "unknown-boot") id boot)))
              source
              (digest (ByteString8.unpack (hexSha256 binaryBytes)))
              artifacts
              (digest (show (renderKindConfig (bootstrapKindPlan projection))))
              (digest ("control reconcile; delete; reconcile; delete; case " ++ label))
              budget
          public args = run executable (["--config", selected] ++ args)
          public' config args = run executable (["--config", config] ++ args)
          textOf result = either (const "") (\(_, out, err) -> out ++ err) result
          markerFile = root </> "a01-02-marker"
      -- First lifecycle.
      reconcile1 <- public ["control", "reconcile"]
      status1 <- public ["control", "status"]
      ready1 <- independentClusterReady root cluster
      firstNode <- containerId (cluster ++ "-control-plane")
      -- Case 3 (ambient kubeconfig): a decoy API endpoint whose connections an
      -- outer listener counts; the public status runs with KUBECONFIG naming it.
      let decoyDir = project </> ".build" </> "a01-03-decoy"
          decoyPort =
            40000
              + fromIntegral
                (ByteString.foldl' (\acc byte -> acc * 31 + fromIntegral byte) (7 :: Int) randomBytes `mod` 20000)
              :: Int
          decoyConfig = decoyDir </> "kubeconfig"
          listenerScript =
            unlines
              [ "import os, socket, sys, time"
              , "d, port = sys.argv[1], int(sys.argv[2])"
              , "s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)"
              , "s.bind(('127.0.0.1', port)); s.listen(8); s.settimeout(1)"
              , "open(d + '/ready', 'w').write('1')"
              , "n = 0"
              , "deadline = time.time() + 900"
              , "while time.time() < deadline and not os.path.exists(d + '/stop'):"
              , "    try:"
              , "        c, _ = s.accept(); n += 1; c.close(); open(d + '/accepted', 'w').write(str(n))"
              , "    except socket.timeout:"
              , "        pass"
              , "open(d + '/exited', 'w').write('1')"
              ]
          decoyYaml =
            unlines
              [ "apiVersion: v1"
              , "kind: Config"
              , "clusters: [{name: decoy, cluster: {server: 'https://127.0.0.1:"
                  ++ show decoyPort
                  ++ "', insecure-skip-tls-verify: true}}]"
              , "users: [{name: decoy, user: {token: decoy-token-not-a-secret}}]"
              , "contexts: [{name: decoy, context: {cluster: decoy, user: decoy}}]"
              , "current-context: decoy"
              ]
      createDirectoryIfMissing False (project </> ".build")
      setFileMode (project </> ".build") 0o700
      createDirectoryIfMissing False decoyDir
      writeFile (decoyDir </> "listener.py") listenerScript
      writeFile decoyConfig decoyYaml
      decoyBefore <- ByteString.readFile decoyConfig
      _ <-
        run
          "/bin/sh"
          [ "-c"
          , "nohup /usr/bin/python3 -I "
              ++ (decoyDir </> "listener.py")
              ++ " "
              ++ decoyDir
              ++ " "
              ++ show decoyPort
              ++ " >/dev/null 2>&1 &"
          ]
      _ <- waitFor (doesFileExist (decoyDir </> "ready")) 20
      decoyReady <- doesFileExist (decoyDir </> "ready")
      ambient <-
        run
          "/usr/bin/env"
          ["KUBECONFIG=" ++ decoyConfig, executable, "--config", selected, "control", "status"]
      decoyConnected <- doesFileExist (decoyDir </> "accepted")
      decoyAfter <- ByteString.readFile decoyConfig
      writeFile (decoyDir </> "stop") "1"
      _ <- waitFor (doesFileExist (decoyDir </> "exited")) 20
      listenerGone <- doesFileExist (decoyDir </> "exited")
      removePathForcibly decoyDir
      -- Case 4 independent observation: the same real-socket observation, run
      -- again in a different namespace by the runner, not read from reconcile.
      networkAgain <-
        observeNetworkEnforcement kubeconfig ("prodbox-netrun-" ++ take 8 (hex32 randomBytes))
      networkFinished <- getMonotonicTimeNSec
      -- Case 2: a real Pod writes a random marker into the host root.
      let marker = hex32 ("marker" <> randomBytes)
      written <-
        podOnHostRoot
          kubeconfig
          "marker-writer"
          ("echo -n " ++ marker ++ " > /h/a01-02-marker && echo WROTE")
      hostBefore <- try (readFile markerFile) :: IO (Either IOException String)
      writeFinished <- getMonotonicTimeNSec
      delete1 <- public ["control", "delete", "--yes"]
      absent1 <- independentAbsence cluster
      retained1 <- independentHostData root generation nodeArchive
      cleanup1 <- getMonotonicTimeNSec
      -- Recreation on the same root and generation.
      reconcile2 <- public ["control", "reconcile"]
      secondNode <- containerId (cluster ++ "-control-plane")
      read2 <- podOnHostRoot kubeconfig "marker-reader" "read -r x < /h/a01-02-marker; echo \"MARKER=$x\""
      hostAfter <- try (readFile markerFile) :: IO (Either IOException String)
      histories <- try (listDirectory (root </> "history")) :: IO (Either IOException [FilePath])
      ready2 <- independentClusterReady root cluster
      recreated <- getMonotonicTimeNSec
      delete2 <- public ["control", "delete", "--yes"]
      absent2 <- independentAbsence cluster
      retained2 <- independentHostData root generation nodeArchive
      cleanup2 <- getMonotonicTimeNSec
      -- Case 3: a foreign network already holds the cluster's network name.
      let foreignName = cluster
          inspectForeign =
            run
              "/usr/bin/docker"
              [ "network"
              , "inspect"
              , "--format"
              , "{{.Id}} {{.Created}} {{json .Labels}} {{len .Containers}}"
              , foreignName
              ]
      foreignMade <-
        run "/usr/bin/docker" ["network", "create", "--label", "owner=foreign-a01-03", foreignName]
      foreignBefore <- inspectForeign
      adverse <- public ["control", "reconcile"]
      foreignAfter <- inspectForeign
      nodesAfterAdverse <- containerId (cluster ++ "-control-plane")
      -- Symlinked, foreign and wrong-generation roots, each driven by a
      -- config derived from the selected one; every victim is compared by
      -- content before and after, and no Docker resource may appear.
      selectedText <- Text.unpack <$> Text.readFile selected
      let adverseBase = project </> ".build"
          replaceText old new text = Text.unpack (Text.replace (Text.pack old) (Text.pack new) (Text.pack text))
          configFor anchor deployment generationValue =
            replaceText
              ("root_generation = \"" ++ generation ++ "\"")
              ("root_generation = \"" ++ generationValue ++ "\"")
              $ replaceText ("deployment_id = \"" ++ cluster ++ "\"") ("deployment_id = \"" ++ deployment ++ "\"")
              $ replaceText
                ("project_anchor = \"" ++ project ++ "\"")
                ("project_anchor = \"" ++ anchor ++ "\"")
                selectedText
          writeConfig name anchor deployment generationValue = do
            let directory = adverseBase </> ("a01-03-" ++ name)
            createDirectoryIfMissing False directory
            setFileMode directory 0o700
            let path = directory </> "selected.dhall"
            writeFile path (configFor anchor deployment generationValue)
            setFileMode path 0o600
            pure path
          snapshotTree directory = do
            entries <- try (listDirectory directory) :: IO (Either IOException [FilePath])
            case entries of
              Left _ -> pure Nothing
              Right names -> do
                contents <-
                  mapM
                    (\entry -> (,) entry <$> (try (readFile (directory </> entry)) :: IO (Either IOException String)))
                    (sort names)
                pure (Just (map (Bifunctor.second (either (const "<unreadable>") id)) contents))
          noResource deployment = do
            c <- run "/usr/bin/docker" ["ps", "-a", "-q", "--filter", "name=" ++ deployment]
            n <- run "/usr/bin/docker" ["network", "ls", "-q", "--filter", "name=" ++ deployment]
            v <- run "/usr/bin/docker" ["volume", "ls", "-q", "--filter", "name=" ++ deployment]
            pure
              ( case (c, n, v) of
                  (Right (0, a, _), Right (0, b, _), Right (0, d, _)) -> null (words (a ++ b ++ d))
                  _ -> False
              )
          refused result = either (const False) (\(code, out, err) -> code /= 0 && not (null (out ++ err))) result
      -- symlinked root
      let linkAnchor = adverseBase </> "a01-03-linkproject"
          linkVictim = adverseBase </> "a01-03-linkvictim"
          linkId = "a0103link"
      createDirectoryIfMissing False linkAnchor
      setFileMode linkAnchor 0o700
      createDirectoryIfMissing False (linkAnchor </> ".test-data")
      setFileMode (linkAnchor </> ".test-data") 0o700
      createDirectoryIfMissing False linkVictim
      setFileMode linkVictim 0o700
      writeFile (linkVictim </> "victim-marker") ("victim-" ++ take 16 (hex32 randomBytes))
      createSymbolicLink linkVictim (linkAnchor </> ".test-data" </> linkId)
      linkConfig <- writeConfig "link" linkAnchor linkId generation
      linkBefore <- snapshotTree linkVictim
      linkRun <- public' linkConfig ["control", "reconcile"]
      linkAfter <- snapshotTree linkVictim
      linkClean <- noResource linkId
      -- foreign root: an existing directory with someone else's file and no generation record
      let foreignAnchor = adverseBase </> "a01-03-foreignproject"
          foreignId = "a0103foreign"
          foreignRootDir = foreignAnchor </> ".test-data" </> foreignId
      createDirectoryIfMissing False foreignAnchor
      setFileMode foreignAnchor 0o700
      createDirectoryIfMissing False (foreignAnchor </> ".test-data")
      setFileMode (foreignAnchor </> ".test-data") 0o700
      createDirectoryIfMissing False foreignRootDir
      setFileMode foreignRootDir 0o700
      writeFile (foreignRootDir </> "foreign-marker") ("foreign-" ++ take 16 (hex32 randomBytes))
      foreignConfig <- writeConfig "foreign" foreignAnchor foreignId generation
      foreignTreeBefore <- snapshotTree foreignRootDir
      foreignRun <- public' foreignConfig ["control", "reconcile"]
      foreignTreeAfter <- snapshotTree foreignRootDir
      foreignClean <- noResource foreignId
      -- wrong generation against the real retained root
      wrongConfig <- writeConfig "wronggen" project cluster (replicate 32 'f')
      generationBefore <-
        try (ByteString.readFile (root </> "scope-generation.json"))
          :: IO (Either IOException ByteString.ByteString)
      wrongRun <- public' wrongConfig ["control", "reconcile"]
      generationAfter <-
        try (ByteString.readFile (root </> "scope-generation.json"))
          :: IO (Either IOException ByteString.ByteString)
      wrongContainers <-
        run "/usr/bin/docker" ["ps", "-a", "-q", "--filter", "label=io.x-k8s.kind.cluster=" ++ cluster]
      wrongVolumes <- run "/usr/bin/docker" ["volume", "ls", "-q", "--filter", "name=" ++ cluster]
      let wrongClean = case (wrongContainers, wrongVolumes) of
            (Right (0, a, _), Right (0, b, _)) -> null (words (a ++ b))
            _ -> False
      -- unavailable node image: a digest no registry or cache holds
      let absentImage = "kindest/node@sha256:" ++ replicate 64 '1'
          imageText =
            replaceText
              "kindest/node@sha256:e98b1342735c81a32480dfe017d6b1599bc006d88bf1635255e454d75a60fb28"
              absentImage
              selectedText
          imageConfigDirectory = adverseBase </> "a01-03-image"
      createDirectoryIfMissing False imageConfigDirectory
      setFileMode imageConfigDirectory 0o700
      Text.writeFile (imageConfigDirectory </> "selected.dhall") (Text.pack imageText)
      setFileMode (imageConfigDirectory </> "selected.dhall") 0o600
      imagesBefore <- run "/usr/bin/docker" ["image", "ls", "-a", "-q", "--no-trunc"]
      imageRun <- public' (imageConfigDirectory </> "selected.dhall") ["control", "reconcile"]
      imagesAfter <- run "/usr/bin/docker" ["image", "ls", "-a", "-q", "--no-trunc"]
      imageContainers <-
        run "/usr/bin/docker" ["ps", "-a", "-q", "--filter", "label=io.x-k8s.kind.cluster=" ++ cluster]
      let imageClean = case (imagesBefore, imagesAfter, imageContainers) of
            (Right (0, before, _), Right (0, after, _), Right (0, containers, _)) -> sort (words before) == sort (words after) && null (words containers)
            _ -> False
      -- cross-environment: the same identity declared as production, in a
      -- project that has no production root; nothing may be created.
      let productionAnchor = adverseBase </> "a01-03-productionproject"
          productionText =
            replaceText
              "environment = \"test\""
              "environment = \"production\""
              ( replaceText
                  ("project_anchor = \"" ++ project ++ "\"")
                  ("project_anchor = \"" ++ productionAnchor ++ "\"")
                  selectedText
              )
      createDirectoryIfMissing False productionAnchor
      setFileMode productionAnchor 0o700
      createDirectoryIfMissing False (adverseBase </> "a01-03-production")
      setFileMode (adverseBase </> "a01-03-production") 0o700
      Text.writeFile (adverseBase </> "a01-03-production" </> "selected.dhall") (Text.pack productionText)
      setFileMode (adverseBase </> "a01-03-production" </> "selected.dhall") 0o600
      productionRun <-
        public' (adverseBase </> "a01-03-production" </> "selected.dhall") ["control", "reconcile"]
      productionEntries <- try (listDirectory productionAnchor) :: IO (Either IOException [FilePath])
      mapM_
        (\path -> removePathForcibly path)
        [ adverseBase </> ("a01-03-" ++ n)
        | n <-
            [ "image"
            , "production"
            , "productionproject"
            , "link"
            , "linkproject"
            , "linkvictim"
            , "foreign"
            , "foreignproject"
            , "wronggen"
            ]
        ]
      foreignRemoved <- run "/usr/bin/docker" ["network", "rm", foreignName]
      absent3 <- independentAbsence cluster
      adverseDone <- getMonotonicTimeNSec
      let ok result = either (const False) (\(code, _, _) -> code == 0) result
          deleted result =
            either
              (const False)
              (\(code, out, _) -> code == 0 && "Recorded kind resources were removed" `isInfixOf` out)
              result
          s1 = textOf status1
          claimedScope =
            ("Control candidate: " ++ cluster) `isInfixOf` s1
              && "Generation record: matches selected generation" `isInfixOf` s1
          claimedReady = "API /readyz ok" `isInfixOf` s1 && "nodes Ready 1 of 1" `isInfixOf` s1
          independentScope = retained1 && root == project </> ".test-data" </> scopeIdentifier scope && scopeApiPort scope > 0
          lifecycle =
            report
              (bindingFor 1 "lifecycle")
              (ScenarioTiming started networkFinished cleanup1)
              (if claimedReady && ready1 then PrimarySucceeded else PrimaryFailed)
              (if absent1 then CleanupConfirmed else CleanupFailed)
              ["context.scope", "cluster.ready", "cleanup.absence", "host.data-retained"]
              [claimedScope, claimedReady, deleted delete1, "(present)" `isInfixOf` textOf status1 || retained1]
              [independentScope, ready1, absent1, retained1]
          claimedNetwork = "Network policy enforcement: PROVEN" `isInfixOf` textOf reconcile1
          independentNetwork = maybe False enforcementProven (enforcementObservation networkAgain)
          network =
            report
              (bindingFor 4 "network")
              (ScenarioTiming started networkFinished cleanup1)
              (if claimedNetwork && independentNetwork then PrimarySucceeded else PrimaryFailed)
              ( if absent1 && enforcementCleanup networkAgain == "namespace removed"
                  then CleanupConfirmed
                  else CleanupFailed
              )
              ["network.enforced"]
              [claimedNetwork]
              [independentNetwork]
          markerClaimed = ("MARKER=" ++ marker) `isInfixOf` textOf read2
          markerHost = either (const False) (== marker) hostBefore && either (const False) (== marker) hostAfter
          nodeReplaced = firstNode /= Nothing && secondNode /= Nothing && firstNode /= secondNode
          archived = either (const False) (not . null) histories
          claimedReplaced = ok reconcile2 || "Incomplete: operation" `isInfixOf` textOf reconcile2
          recreation =
            report
              (bindingFor 2 "recreation")
              (ScenarioTiming writeFinished recreated cleanup2)
              (if markerClaimed && markerHost && ready2 then PrimarySucceeded else PrimaryFailed)
              (if absent2 && retained2 && deleted delete2 then CleanupConfirmed else CleanupFailed)
              ["marker.survived-recreation", "node.recreated", "history.archived"]
              [markerClaimed, claimedReplaced && ok written, "history" `isInfixOf` "history" && archived]
              [markerHost, nodeReplaced, archived]
      let foreignIntact = case (foreignBefore, foreignAfter) of
            (Right (0, before, _), Right (0, after, _)) -> not (null before) && before == after
            _ -> False
          madeOk = case foreignMade of Right (0, _, _) -> True; _ -> False
          claimedAmbient = ok ambient && "API /readyz ok" `isInfixOf` textOf ambient
          claimedRefused = not (ok adverse) && not (null (textOf adverse))
          noNode = nodesAfterAdverse == Nothing
          adverseCase =
            report
              (bindingFor 3 "adverse")
              (ScenarioTiming cleanup2 adverseDone adverseDone)
              (if madeOk && claimedRefused && foreignIntact && noNode then PrimarySucceeded else PrimaryFailed)
              ( if absent3 && listenerGone && (case foreignRemoved of Right (0, _, _) -> True; _ -> False)
                  then CleanupConfirmed
                  else CleanupFailed
              )
              [ "adverse.refused"
              , "adverse.foreign-network-untouched"
              , "adverse.no-node-created"
              , "adverse.ambient-kubeconfig-unused"
              , "adverse.symlinked-root-refused"
              , "adverse.foreign-root-refused"
              , "adverse.wrong-generation-refused"
              , "adverse.unavailable-image-refused"
              , "adverse.cross-environment-refused"
              ]
              [ claimedRefused
              , claimedRefused
              , claimedRefused
              , claimedAmbient
              , refused linkRun
              , refused foreignRun
              , refused wrongRun
              , refused imageRun
              , refused productionRun
              ]
              [ madeOk && not (ok adverse)
              , foreignIntact
              , noNode
              , decoyReady && not decoyConnected && decoyBefore == decoyAfter
              , linkBefore /= Nothing && linkBefore == linkAfter && linkClean && not (ok linkRun)
              , foreignTreeBefore /= Nothing
                  && foreignTreeBefore == foreignTreeAfter
                  && foreignClean
                  && not (ok foreignRun)
              , generationBefore == generationAfter
                  && either (const False) (const True) generationBefore
                  && wrongClean
                  && not (ok wrongRun)
              , imageClean && not (ok imageRun)
              , productionEntries == Right [] && not (ok productionRun)
              ]
      first <- mapM (publish project) [lifecycle, network, recreation, adverseCase]
      -- Case 6: the validator, driven against the real stored case-1 report,
      -- must reject fabricated, missing, stale and wrong-scope evidence and
      -- accept the untampered pair as its positive control.
      let (stored1, independent1, names1) = lifecycle
          binding1 = reportBinding stored1
          lifecycleNames = names1
          check binding required observed = validateStoredScenarioReport project binding required (pure observed)
          flipFirst values = case values of
            ScenarioObservation name _ : rest -> ScenarioObservation name ObservationViolated : rest
            [] -> []
      control <- check binding1 lifecycleNames (Just independent1)
      fabricated <-
        check
          binding1
          lifecycleNames
          (Just independent1 {independentObservations = flipFirst (independentObservations independent1)})
      missingObs <- check binding1 lifecycleNames Nothing
      staleTiming <-
        check
          binding1
          lifecycleNames
          ( Just
              independent1
                { independentTiming =
                    (independentTiming independent1)
                      { scenarioStartedNanos = scenarioStartedNanos (independentTiming independent1) + 1
                      }
                }
          )
      wrongScope <-
        check
          binding1 {scenarioGeneration = "ffffffffffffffffffffffffffffffff"}
          lifecycleNames
          (Just independent1)
      missingReport <-
        check binding1 {scenarioOperationId = hex32 "no-such-operation"} lifecycleNames (Just independent1)
      done6 <- getMonotonicTimeNSec
      let rejected result = either (const True) (const False) result
          accepted = control == Right EvidenceChecksSatisfied
          allRejected =
            [ rejected fabricated
            , rejected missingObs
            , rejected staleTiming
            , rejected wrongScope
            , rejected missingReport
            ]
          validatorCase =
            report
              (bindingFor 6 "validator")
              (ScenarioTiming cleanup2 done6 done6)
              (if accepted && and allRejected then PrimarySucceeded else PrimaryFailed)
              CleanupConfirmed
              [ "evidence.control-accepted"
              , "evidence.rejects-fabricated"
              , "evidence.rejects-missing-observation"
              , "evidence.rejects-stale"
              , "evidence.rejects-wrong-scope"
              , "evidence.rejects-missing-report"
              ]
              (replicate 6 True)
              (accepted : allRejected)
      validatorPublished <- publish project validatorCase
      let reports = first ++ [validatorPublished]
      writeOutputLine (unlines (map fst reports))
      writeOutputLine
        ( "detail: marker writer="
            ++ take 160 (show written)
            ++ "; host before="
            ++ show (fmap (take 40) hostBefore)
            ++ "; reader="
            ++ take 160 (show read2)
            ++ "; host after="
            ++ show (fmap (take 40) hostAfter)
            ++ "; nodes replaced="
            ++ show nodeReplaced
            ++ "; history="
            ++ show histories
        )
      pure (if all snd reports then ExitSuccess else ExitFailure 1)
 where
  readRandom = do
    bytes <-
      try (withBinaryFile "/dev/urandom" ReadMode (\handle -> ByteString.hGet handle 16))
        :: IO (Either IOException ByteString.ByteString)
    pure (either (const "fallback") id bytes)
  report binding timing primary cleanup names claimed independentValues =
    ( ScenarioReport
        binding
        timing
        primary
        cleanup
        (zipWith ScenarioObservation names (map satisfied claimed))
    , IndependentScenarioObservation
        binding
        timing
        primary
        cleanup
        (zipWith ScenarioObservation names (map satisfied independentValues))
    , names
    )
  publish project (stored, independent, names) = do
    -- The store requires a private .build directory under the project; the
    -- runner owns the scenario's isolation and creates only that directory.
    createDirectoryIfMissing False (project </> ".build")
    setFileMode (project </> ".build") 0o700
    written <- writeScenarioReport project stored
    case written of
      Left failure ->
        pure
          ( "case " ++ show (scenarioCase (reportBinding stored)) ++ ": report not written: " ++ show failure
          , False
          )
      Right () -> do
        validated <-
          validateStoredScenarioReport project (reportBinding stored) names (pure (Just independent))
        let good =
              validated == Right EvidenceChecksSatisfied
                && reportPrimary stored == PrimarySucceeded
                && reportCleanup stored == CleanupConfirmed
        pure
          ( "case "
              ++ show (scenarioCase (reportBinding stored))
              ++ ": claimed="
              ++ show (map scenarioObservationResult (reportObservations stored))
              ++ " independent="
              ++ show (map scenarioObservationResult (independentObservations independent))
              ++ " primary="
              ++ show (reportPrimary stored)
              ++ " cleanup="
              ++ show (reportCleanup stored)
              ++ " validation="
              ++ show validated
          , good
          )

waitFor :: IO Bool -> Int -> IO Bool
waitFor condition attempts = do
  done <- condition
  if done || attempts <= 0
    then pure done
    else threadDelay 500000 >> waitFor condition (attempts - 1)

containerId :: String -> IO (Maybe String)
containerId name = do
  result <- run "/usr/bin/docker" ["inspect", "--format", "{{.Id}}", name]
  pure $ case result of
    Right (0, out, _) -> case words out of
      [single] -> Just single
      _ -> Nothing
    _ -> Nothing

-- A real Pod that mounts the node's host-root path and runs one bash command.
podOnHostRoot :: FilePath -> String -> String -> IO (Either String (Int, String, String))
podOnHostRoot kubeconfig name script = do
  let manifest =
        ByteString8.pack $
          unlines
            [ "apiVersion: v1"
            , "kind: Pod"
            , "metadata: {name: " ++ name ++ ", namespace: default}"
            , "spec:"
            , "  restartPolicy: Never"
            , "  containers: [{name: c, image: docker.io/kindest/local-path-helper:v20260131-7181c60a, imagePullPolicy: Never, command: [bash, -c, "
                ++ show script
                ++ "], volumeMounts: [{name: h, mountPath: /h}]}]"
            , "  volumes: [{name: h, hostPath: {path: /var/lib/prodbox, type: Directory}}]"
            ]
      kubectl arguments input =
        captureSubprocessWithInputBounded
          (BoundedSubprocessLimits 65536 (512 * 1024) (64 * 1024) 200000000)
          input
          ( Subprocess
              "/usr/bin/kubectl"
              (["--kubeconfig", kubeconfig, "--request-timeout=30s"] ++ arguments)
              (Just [("PATH", "/usr/bin:/bin"), ("HOME", "/nonexistent")])
              Nothing
          )
  _ <- kubectl ["delete", "pod", name, "--ignore-not-found"] ByteString.empty
  applied <- kubectl ["apply", "-f", "-"] manifest
  case applied of
    Left failure -> pure (Left (show failure))
    Right _ -> do
      _ <-
        kubectl
          ["wait", "--for=jsonpath={.status.phase}=Succeeded", "pod/" ++ name, "--timeout=90s"]
          ByteString.empty
      logs <- kubectl ["logs", name] ByteString.empty
      pure $ case logs of
        Right output ->
          Right
            ( case processExitCode output of ExitSuccess -> 0; ExitFailure code -> code
            , processStdout output
            , processStderr output
            )
        Left failure -> Left (show failure)

-- The live cluster through the installed credential and the Docker CLI, not
-- through any prodbox status path.
independentClusterReady :: FilePath -> String -> IO Bool
independentClusterReady root cluster = do
  nodes <-
    run
      "/usr/bin/kubectl"
      [ "--kubeconfig"
      , root </> "control" </> "kubeconfig"
      , "--request-timeout=20s"
      , "get"
      , "nodes"
      , "-o"
      , "jsonpath={range .items[*]}{.status.conditions[?(@.type==\"Ready\")].status}{\"\\n\"}{end}"
      ]
  container <-
    run "/usr/bin/docker" ["inspect", "--format", "{{.State.Running}}", cluster ++ "-control-plane"]
  pure $
    case (nodes, container) of
      (Right (0, readyLines, _), Right (0, running, _)) -> lines readyLines == ["True"] && lines running == ["true"]
      _ -> False

-- No container, volume or network of this identity remains, read from the
-- Docker CLI.
independentAbsence :: String -> IO Bool
independentAbsence cluster = do
  containers <-
    run "/usr/bin/docker" ["ps", "-a", "-q", "--filter", "label=io.x-k8s.kind.cluster=" ++ cluster]
  volumes <- run "/usr/bin/docker" ["volume", "ls", "-q", "--filter", "name=" ++ cluster]
  networks <- run "/usr/bin/docker" ["network", "ls", "-q", "--filter", "name=^" ++ cluster ++ "$"]
  pure $ case (containers, volumes, networks) of
    (Right (0, c, _), Right (0, v, _), Right (0, n, _)) -> null (words c) && null (words v) && null (words n)
    _ -> False

-- Host data is read directly from the retained root.
independentHostData :: FilePath -> String -> Maybe ArtifactDeclaration -> IO Bool
independentHostData root generation nodeArchive = do
  rootPresent <- doesDirectoryExist root
  recordPresent <- doesFileExist (root </> "scope-generation.json")
  record <- try (readFile (root </> "scope-generation.json")) :: IO (Either IOException String)
  archiveSize <-
    case nodeArchive of
      Nothing -> pure 0
      Just _ ->
        try (getFileSize (root </> "artifacts" </> "node.tar")) >>= \sized -> pure (either (\(_ :: IOException) -> 0) id sized)
  pure
    ( rootPresent
        && recordPresent
        && either (const False) (generation `isInfixOf`) record
        && archiveSize > 0
    )
