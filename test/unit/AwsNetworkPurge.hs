{-# LANGUAGE OverloadedStrings #-}

module AwsNetworkPurge (awsNetworkPurgeSuite) where

import AwsWaitPolling (newVirtualWorld, roomyWaitEnvironment)
import Data.IORef (modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Prodbox.Infra.AwsStackRepair (runNetworkPurgeVia)
import Prodbox.Lifecycle.AwsAudit (AuditVerdict (..), auditExitCode)
import Prodbox.Lifecycle.AwsNetworkPurge
import Prodbox.Lifecycle.ProviderWorker.ProviderWork
import Prodbox.Subprocess (ProcessOutput (..))
import System.Exit (ExitCode (..))
import TestSupport

awsNetworkPurgeSuite :: SuiteBuilder ()
awsNetworkPurgeSuite = describe "Sprint 4.112 confirmed EKS network repair" $ do
  it "plans both registry families, binds the full scope, and mutates nothing" $ do
    calls <- newIORef []
    plan <-
      expectRight
        =<< observeNetworkPurgePlan (\args -> modifyIORef' calls (++ [args]) >> pure (response args)) planRef
    networkPurgeAbsent plan `shouldBe` False
    Text.length (networkPurgeDigest plan) `shouldBe` 64
    evidence <- expectRight (encodeNetworkPurgeReport plan)
    report <- expectRight (decodeNetworkPurgeReport account region evidence)
    purgeReportCounts report
      `shouldBe` [("aws-eks-vpc-cni-interfaces", 1), ("aws-eks-cluster-security-groups", 1)]
    decodeNetworkPurgeReport "000000000000" region evidence `shouldSatisfy` isLeft
    commands <- readIORef calls
    commands `shouldSatisfy` all (not . any (Text.isPrefixOf "delete-" . Text.pack))

  it "refuses a present, empty-success or unobservable cluster before enumerating candidates" $ do
    mapM_
      ( \cluster -> do
          calls <- newIORef []
          observed <-
            observeNetworkPurgePlan
              ( \args ->
                  modifyIORef' calls (++ [args])
                    >> pure (if "describe-cluster" `elem` args then cluster else response args)
              )
              planRef
          observed `shouldSatisfy` isLeft
          (length <$> readIORef calls) `shouldReturn` 1
      )
      [success "{}", success "", failure "AccessDenied", failure "network failure"]

  it "refuses missing, ambiguous, wrong-tagged and unreadable VPC roots" $ do
    mapM_
      ( \vpcs -> do
          result <-
            observeNetworkPurgePlan
              (\args -> pure (if "describe-vpcs" `elem` args then vpcs else response args))
              planRef
          result `shouldSatisfy` isLeft
      )
      [ success "[]"
      , success ("[" ++ vpcRow ++ "," ++ vpcRow ++ "]")
      , success "[{\"id\":\"vpc-0123456789abcdef0\",\"tags\":[]}]"
      , failure "AccessDenied"
      ]

  it "refuses changed candidates and wrong digests before the first delete" $ do
    plan <- expectRight =<< observeNetworkPurgePlan (pure . response) planRef
    mapM_
      ( \(digest, change) -> do
          effects <- newIORef []
          world <- newVirtualWorld
          let runner args = do
                if any (`elem` args) ["delete-network-interface", "delete-security-group"]
                  then modifyIORef' effects (++ [args])
                  else pure ()
                pure (if change && "describe-network-interfaces" `elem` args then success "[]" else response args)
          applyNetworkPurge runner (roomyWaitEnvironment world) planRef digest `shouldReturnSatisfy` isLeft
          readIORef effects `shouldReturn` []
      )
      [(Text.replicate 64 "0", False), (networkPurgeDigest plan, True)]

  it "rejects an unadmitted candidate before touching either family" $ do
    effects <- newIORef []
    world <- newVirtualWorld
    let runner args = do
          if any (`elem` args) ["delete-network-interface", "delete-security-group"]
            then modifyIORef' effects (++ [args])
            else pure ()
          pure
            ( if "describe-network-interfaces" `elem` args
                then success (Text.unpack (Text.replace "aws-K8S-example" "foreign" (Text.pack interfaces)))
                else response args
            )
    plan <- expectRight =<< observeNetworkPurgePlan runner planRef
    applyNetworkPurge runner (roomyWaitEnvironment world) planRef (networkPurgeDigest plan)
      `shouldReturnSatisfy` isLeft
    readIORef effects `shouldReturn` []

  it "uses the shared executors in interface/group order and converges after a partial delete" $ do
    present <- newIORef (True, True)
    effects <- newIORef []
    world <- newVirtualWorld
    let runner args = do
          (hasInterface, hasGroup) <- readIORef present
          case args of
            ["ec2", "delete-network-interface", "--network-interface-id", identifier] -> do
              modifyIORef' effects (++ [identifier]); writeIORef present (False, hasGroup); pure (success "")
            ["ec2", "delete-security-group", "--group-id", identifier] -> do
              modifyIORef' effects (++ [identifier]); writeIORef present (hasInterface, False); pure (success "")
            _ ->
              pure $
                if ("describe-network-interfaces" `elem` args && not hasInterface)
                  || ("describe-security-groups" `elem` args && not hasGroup)
                  then success "[]"
                  else response args
    first <- expectRight =<< observeNetworkPurgePlan runner planRef
    applyNetworkPurge runner (roomyWaitEnvironment world) planRef (networkPurgeDigest first)
      `shouldReturn` Right ()
    readIORef effects `shouldReturn` ["eni-0123456789abcdef0", "sg-0123456789abcdef0"]
    closed <- expectRight =<< observeNetworkPurgePlan runner planRef
    networkPurgeAbsent closed `shouldBe` True
    -- An interrupted run may have already deleted the interface. Re-plan the
    -- remaining group, rather than treating the original digest as current.
    writeIORef present (False, True)
    remaining <- expectRight =<< observeNetworkPurgePlan runner planRef
    networkPurgeDigest remaining `shouldNotBe` networkPurgeDigest first
    applyNetworkPurge runner (roomyWaitEnvironment world) planRef (networkPurgeDigest remaining)
      `shouldReturn` Right ()

  it "keeps requester-managed and attached interfaces held by the service without forcing them" $ do
    mapM_
      ( \replacement -> do
          world <- newVirtualWorld
          effects <- newIORef []
          let held = Text.unpack (replacement (Text.pack interfaces))
              runner args = do
                if "delete-network-interface" `elem` args then modifyIORef' effects (++ [args]) else pure ()
                pure (if "describe-network-interfaces" `elem` args then success held else response args)
          plan <- expectRight =<< observeNetworkPurgePlan runner planRef
          applyNetworkPurge runner (roomyWaitEnvironment world) planRef (networkPurgeDigest plan)
            `shouldReturnSatisfy` isLeft
          readIORef effects `shouldReturn` []
      )
      [Text.replace "\"managed\":false" "\"managed\":true", Text.replace "available" "in-use"]

  it "fences a newly discovered candidate inside the shared executor to the confirmed identities" $ do
    observations <- newIORef (0 :: Int)
    effects <- newIORef []
    world <- newVirtualWorld
    let runner args
          | "describe-network-interfaces" `elem` args = do
              modifyIORef' observations (+ 1)
              count <- readIORef observations
              let extra = Text.replace "eni-0123456789abcdef0" "eni-abcdef01234567890" (Text.pack interfaces)
              pure
                (success (if count <= 2 then interfaces else init interfaces ++ "," ++ drop 1 (Text.unpack extra)))
          | ["ec2", "delete-network-interface", "--network-interface-id", identifier] <- args =
              modifyIORef' effects (++ [identifier]) >> pure (success "")
          | otherwise = pure (response args)
    plan <- expectRight =<< observeNetworkPurgePlan runner planRef
    applyNetworkPurge runner (roomyWaitEnvironment world) planRef (networkPurgeDigest plan)
      `shouldReturnSatisfy` isLeft
    deleted <- readIORef effects
    deleted `shouldSatisfy` (not . null)
    deleted `shouldSatisfy` all (== "eni-0123456789abcdef0")

  it "plans with one request and licenses apply only from a second independent observation" $ do
    plan <- expectRight =<< observeNetworkPurgePlan (pure . response) planRef
    evidence <- expectRight (encodeNetworkPurgeReport plan)
    absent <-
      expectRight
        =<< observeNetworkPurgePlan
          ( \args ->
              pure
                ( if any (`elem` args) ["describe-network-interfaces", "describe-security-groups"]
                    then success "[]"
                    else response args
                )
          )
          planRef
    clean <- expectRight (encodeNetworkPurgeReport absent)
    calls <- newIORef []
    let dispatch answer intent = modifyIORef' calls (++ [intent]) >> pure (Right answer)
        dispatchClosing answer intent = do
          previous <- readIORef calls
          modifyIORef' calls (++ [intent])
          pure $ case intent of
            ObserveNativeStackFamily {} | null previous -> Right evidence
            ObserveNativeStackFamily {} -> Right answer
            _ -> Right "mutation receipt"
    planned <- runNetworkPurgeVia (dispatch evidence) account region config NetworkPurgePlan
    fmap fst planned `shouldBe` Right Nothing
    (length <$> readIORef calls) `shouldReturn` 1
    writeIORef calls []
    applied <-
      runNetworkPurgeVia
        (dispatchClosing clean)
        account
        region
        config
        (NetworkPurgeApply (networkPurgeDigest plan))
    fmap fst applied `shouldBe` Right (Just AuditClean)
    (length <$> readIORef calls) `shouldReturn` 3
    residue <-
      runNetworkPurgeVia
        (dispatch evidence)
        account
        region
        config
        (NetworkPurgeApply (networkPurgeDigest plan))
    fmap (fmap auditExitCode . fst) residue `shouldBe` Right (Just (ExitFailure 4))
    let unobservableDispatch intent = case intent of
          ObserveNativeStackFamily {} -> pure (Left "unobservable")
          _ -> pure (Right "mutation receipt")
        refusedDispatch intent = case intent of
          ReapNativeStackFamily {} -> modifyIORef' calls (++ [intent]) >> pure (Left "stale digest")
          _ -> dispatchClosing clean intent
    failed <-
      runNetworkPurgeVia
        unobservableDispatch
        account
        region
        config
        (NetworkPurgeApply (networkPurgeDigest plan))
    failed `shouldBe` Left "unobservable"
    writeIORef calls []
    refused <-
      runNetworkPurgeVia
        refusedDispatch
        account
        region
        config
        (NetworkPurgeApply (networkPurgeDigest plan))
    refused
      `shouldBe` Left "network purge apply was refused; the independent network-family read-back is Clean"
    writeIORef calls []
    substituted <-
      runNetworkPurgeVia
        (dispatchClosing (Text.replace "vpc-0123456789abcdef0" "vpc-abcdef01234567890" clean))
        account
        region
        config
        (NetworkPurgeApply (networkPurgeDigest plan))
    substituted `shouldBe` Left "network purge VPC changed before the independent read-back"
    writeIORef calls []
    stale <-
      runNetworkPurgeVia
        (dispatch evidence)
        account
        region
        config
        (NetworkPurgeApply (Text.replicate 64 "0"))
    stale `shouldBe` Left "network purge plan changed; render and confirm a new plan digest"
    (length <$> readIORef calls) `shouldReturn` 1

account, region :: Text
account = "123456789012"
region = Text.pack (fixtureAwsRegion FixtureCaCentral1)

planRef :: ProviderNativeStackFamilyRef
planRef = mustRight (mkProviderNetworkPurgeRef account region NetworkPurgePlan)

config :: ProviderStackConfig
config = mustRight (mkAwsEksProviderStackConfig "127.0.0.1/32")

response :: [String] -> ProcessOutput
response args
  | "describe-cluster" `elem` args =
      failure
        "An error occurred (ResourceNotFoundException) when calling the DescribeCluster operation: No cluster found"
  | "describe-vpcs" `elem` args = success ("[" ++ vpcRow ++ "]")
  | "describe-network-interfaces" `elem` args = success interfaces
  | "describe-security-groups" `elem` args = success groups
  | otherwise = failure ("unexpected command: " ++ unwords args)

vpcRow, interfaces, groups :: String
vpcRow =
  "{\"id\":\"vpc-0123456789abcdef0\",\"tags\":[{\"Key\":\"Name\",\"Value\":\"aws-eks-test-vpc\"},{\"Key\":\"prodbox.io/managed-by\",\"Value\":\"prodbox\"}]}"
interfaces =
  "[{\"id\":\"eni-0123456789abcdef0\",\"vpc\":\"vpc-0123456789abcdef0\",\"status\":\"available\",\"managed\":false,\"type\":\"interface\",\"description\":\"aws-K8S-example\",\"owner\":null,\"cluster\":null}]"
groups =
  "[{\"id\":\"sg-0123456789abcdef0\",\"vpc\":\"vpc-0123456789abcdef0\",\"name\":\"eks-cluster-sg-aws-eks-test-cluster-123\",\"cluster\":\"aws-eks-test-cluster\"}]"

success :: String -> ProcessOutput
success body = ProcessOutput ExitSuccess body ""

failure :: String -> ProcessOutput
failure = ProcessOutput (ExitFailure 1) ""

expectRight :: (Show err) => Either err value -> IO value
expectRight result = case result of
  Right value -> pure value
  Left detail -> expectationFailure (show detail) >> fail "expected network plan"

isLeft :: Either err value -> Bool
isLeft result = case result of Left _ -> True; Right _ -> False

shouldReturnSatisfy :: (Show a) => IO a -> (a -> Bool) -> IO ()
shouldReturnSatisfy action predicate = action >>= (`shouldSatisfy` predicate)

mustRight :: (Show err) => Either err value -> value
mustRight result = case result of
  Right value -> value
  Left detail -> error ("invalid network-purge fixture: " ++ show detail)
