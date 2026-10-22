{-# LANGUAGE OverloadedStrings #-}

-- | Sprint 7.43: what a controller made, no create can record.
--
-- The declaration in "Prodbox.Lifecycle.Teardown.CreateRecordCoverage" is only
-- worth having while it is true, so these cases do two things. They check the
-- shipped table against the tree it describes, and they feed the checks a
-- mutated copy of that same tree and table, one mutation each, to prove every
-- rule can fail. A rule with no failing input is a comment.
--
-- Each group reads the corpus once and mutates it in memory, because reading
-- the tree is most of the cost and a mutation is free.
module CreateRecordCoverage
  ( createRecordCoverageSuite
  )
where

import Data.List (isInfixOf, sortOn)
import Data.Text qualified as Text
import Prodbox.CheckCode
  ( CreateRecordCorpus (..)
  , checkCreateRecordCoverage
  , createRecordCoverageViolations
  , manifestWriterIdentifiers
  , manifestWriterModules
  , maskHaskellCommentsAndLiterals
  , readCreateRecordCorpus
  )
import Prodbox.Lifecycle.Teardown.CreateRecordCoverage
import Prodbox.Lifecycle.Teardown.Model (RegisteredResourceKey (..))
import System.Directory (getCurrentDirectory)
import TestSupport

createRecordCoverageSuite :: SuiteBuilder ()
createRecordCoverageSuite =
  describe "Sprint 7.43 what a controller made, no create can record" $ do
    tableCases
    programRuleCases
    registryRuleCases
    nativeAndDestroyRuleCases
    writerCases
    maskingCases

tableCases :: SuiteBuilder ()
tableCases = do
  it "is true against the tree it describes" $ do
    repoRoot <- getCurrentDirectory
    findings <- checkCreateRecordCoverage repoRoot
    findings `shouldBe` []

  it "pins what the registry derives for every registered key" $ do
    -- A registry change that moves a key between these classes is a decision,
    -- so it must fail here before it can change the table's meaning silently.
    sortOn fst derivedRelationOfRegistry
      `shouldBe` [ (AwsEksKey, DerivedStack)
                 , (AwsEksSubzoneKey, DerivedStack)
                 , (AwsTestKey, DerivedStack)
                 , (AwsEbsPerRunTestKey, DerivedControllerFamily AwsEksKey)
                 , (AwsEbsProductionRetainedKey, DerivedStandalone)
                 , (AwsDnsValidationZoneKey, DerivedStandalone)
                 , (AwsDns01ChallengeRecordKey, DerivedStandalone)
                 , (AwsEksIamRoleFamilyKey, DerivedControllerFamily AwsEksKey)
                 , (AwsEksLoadBalancerControllerFamilyKey, DerivedControllerFamily AwsEksKey)
                 , (AwsEksVpcCniInterfacesKey, DerivedControllerFamily AwsEksKey)
                 , (AwsTestVpcCniInterfacesKey, DerivedControllerFamily AwsTestKey)
                 , (AwsEksClusterSecurityGroupsKey, DerivedControllerFamily AwsEksKey)
                 , (HomeDns01ChallengeRecordKey, DerivedStandalone)
                 , (SesInviteMailObjectsKey, DerivedStandalone)
                 , (AwsTestCanarySecurityGroupsKey, DerivedControllerFamily AwsTestKey)
                 ]

  it "projects the per-run programs from the table and keeps the retained one off the lane" $ do
    perRunProgramDirectories `shouldBe` ["aws-eks", "aws-eks-subzone", "aws-test"]
    let sesDecisions =
          [ (rowRelation row, rowRunScopeTag row)
          | row <- createRecordCoverage
          , rowSubject row == PulumiProgramCreator "aws-ses" "src/Prodbox/Infra/AwsSesStack.hs"
          ]
    -- The lane decision and the tag decision are two fields with two reasons.
    sesDecisions `shouldBe` [(OffWriteAheadLane BarNoRegisteredKey, Just RunScopeTagWithheld)]

  it "names the registered native IAM and test-canary creation boundaries" $
    nativeCreatorModules
      `shouldBe` [ "src/Prodbox/ControlPlane/ProviderProduction.hs"
                 , "src/Prodbox/Lifecycle/CredentialProvisioner/ProductionIam.hs"
                 ]

programRuleCases :: SuiteBuilder ()
programRuleCases = do
  it "refuses a program without a row, a row without a program, and a program listed twice" $ do
    corpus <- loadCorpus
    violations corpus `shouldBe` []
    violations corpus {corpusPulumiMain = ("aws-new", "name: aws-new\n") : corpusPulumiMain corpus}
      `shouldSatisfy` mentions "pulumi/aws-new has a Main.yaml but createRecordCoverage has no row"
    violations corpus {corpusPulumiMain = filter ((/= "aws-test") . fst) (corpusPulumiMain corpus)}
      `shouldSatisfy` mentions "names Pulumi program `aws-test`, which has no pulumi/aws-test/Main.yaml"
    createRecordCoverageViolations (firstRow (isProgram "aws-eks") : createRecordCoverage) corpus
      `shouldSatisfy` mentions "lists Pulumi program `aws-eks` more than once"

  it "holds a lane program to importing the submitter and calling it outside its import list" $ do
    corpus <- loadCorpus
    -- Only the call site changes: the import list still names the identifier.
    let stopsCalling =
          replaceAll "submitRegisteredStackCreation authentication" "somethingElse authentication"
    violations (editSource "src/Prodbox/Infra/AwsEksTestStack.hs" stopsCalling corpus)
      `shouldSatisfy` onlyFinding "does not import the submitter and call it outside the import list"
    -- The import and the call both go.
    violations
      ( editSource
          "src/Prodbox/Infra/AwsEksTestStack.hs"
          (replaceAll "submitRegisteredStackCreation" "somethingElse")
          corpus
      )
      `shouldSatisfy` mentions "does not import the submitter and call it outside the import list"

  it "refuses a retained program that later imports the submitter, in either spelling" $ do
    corpus <- loadCorpus
    let importing line = editSource "src/Prodbox/Infra/AwsSesStack.hs" (++ ("\n" ++ line ++ "\n")) corpus
    violations (importing "import Prodbox.ControlPlane.RegisteredStackCreationSubmitter")
      `shouldSatisfy` onlyFinding "now imports the submitter"
    violations
      (importing "import qualified Prodbox.ControlPlane.RegisteredStackCreationSubmitter as Submit")
      `shouldSatisfy` onlyFinding "now imports the submitter"

  it "refuses a lane row that names a different stack than its program creates" $ do
    corpus <- loadCorpus
    let swapped =
          [ case rowSubject row of
              PulumiProgramCreator "aws-eks" _ -> row {rowRelation = OnWriteAheadLane AwsTestKey}
              PulumiProgramCreator "aws-test" _ -> row {rowRelation = OnWriteAheadLane AwsEksKey}
              _ -> row
          | row <- createRecordCoverage
          ]
        findings = createRecordCoverageViolations swapped corpus
    findings `shouldSatisfy` mentions "pulumi/aws-eks/Pulumi.yaml declares `prodbox-aws-eks-test`"
    findings `shouldSatisfy` mentions "pulumi/aws-test/Pulumi.yaml declares `prodbox-aws-test`"

  it "refuses a run-scope tag decision that its program contradicts or that is missing" $ do
    corpus <- loadCorpus
    violations (editMain "aws-eks" (replaceAll "prodboxRunScope" "someOtherName") corpus)
      `shouldSatisfy` mentions "does not mention prodboxRunScope"
    violations (editMain "aws-ses" (++ "\n  prodbox.io/run-scope: ${prodboxRunScope}\n") corpus)
      `shouldSatisfy` mentions "mentions prodboxRunScope"
    let undecided =
          [ if isProgram "aws-eks" row then row {rowRunScopeTag = Nothing} else row
          | row <- createRecordCoverage
          ]
    createRecordCoverageViolations undecided corpus
      `shouldSatisfy` onlyFinding "program `aws-eks` has no run-scope tag decision"

  it "refuses a program declared inside another stack's manifest" $ do
    corpus <- loadCorpus
    let nested =
          [ if isProgram "aws-eks" row then row {rowRelation = DeclaredInStackManifest AwsTestKey} else row
          | row <- createRecordCoverage
          ]
    createRecordCoverageViolations nested corpus
      `shouldSatisfy` mentions "program `aws-eks` cannot be declared inside another stack's manifest"

registryRuleCases :: SuiteBuilder ()
registryRuleCases =
  it
    "refuses a key with no row, two rows or a relation the registry does not derive, and an unregistered key"
    $ do
      corpus <- loadCorpus
      let perRunVolumes = firstRow ((== RegisteredKeyCreator AwsEbsPerRunTestKey) . rowSubject)
          withoutRetainedEbs =
            [ row
            | row <- createRecordCoverage
            , rowSubject row /= RegisteredKeyCreator AwsEbsProductionRetainedKey
            ]
          wrongRelation =
            [ if rowSubject row == RegisteredKeyCreator AwsEbsPerRunTestKey
                then row {rowRelation = OffWriteAheadLane BarKeyIsNotStack}
                else row
            | row <- createRecordCoverage
            ]
          unregistered = perRunVolumes {rowSubject = RegisteredKeyCreator LocalLinuxRke2Key}
      createRecordCoverageViolations withoutRetainedEbs corpus
        `shouldSatisfy` mentions "registered key `aws-ebs-volumes-production-retained` has no createRecordCoverage row"
      createRecordCoverageViolations (perRunVolumes : createRecordCoverage) corpus
        `shouldSatisfy` mentions "registered key `aws-ebs-volumes-per-run-test` has more than one createRecordCoverage row"
      createRecordCoverageViolations wrongRelation corpus
        `shouldSatisfy` mentions "but the registry derives a family declared by the manifest of `aws-eks`"
      createRecordCoverageViolations (unregistered : createRecordCoverage) corpus
        `shouldSatisfy` mentions
          "createRecordCoverage has a row for `local-linux-rke2`, which is not a registered resource key"

nativeAndDestroyRuleCases :: SuiteBuilder ()
nativeAndDestroyRuleCases = do
  it "holds the native creators to their rows, through either native client" $ do
    corpus <- loadCorpus
    let productionIam = "src/Prodbox/Lifecycle/CredentialProvisioner/ProductionIam.hs"
        freshCreator marker create =
          ( "src/Prodbox/Fake/Creator.hs"
          , "module Prodbox.Fake.Creator where\nimport "
              ++ marker
              ++ "\nmake client = "
              ++ create
              ++ " client\n"
          )
        noRow =
          "src/Prodbox/Fake/Creator.hs creates through the registered native client but has no NativeClientCreator row"
    violations
      corpus {corpusSources = freshCreator "Prodbox.Aws.Native.Iam" "createRole" : corpusSources corpus}
      `shouldSatisfy` onlyFinding noRow
    violations
      corpus {corpusSources = freshCreator "Prodbox.Aws.Native.S3" "createBucket" : corpusSources corpus}
      `shouldSatisfy` onlyFinding noRow
    violations
      corpus
        { corpusSources =
            freshCreator "Prodbox.Lifecycle.AwsTestCanaryExecution" "plantTestVpcCanary" : corpusSources corpus
        }
      `shouldSatisfy` onlyFinding noRow
    -- The row's module stopped creating.
    violations
      ( editSource
          productionIam
          ( const
              "ensureProductionIamPrerequisites :: ()\nensureProductionIamPrerequisites = ()\ndestroyProductionIamIdentity :: ()\ndestroyProductionIamIdentity = ()\n"
          )
          corpus
      )
      `shouldSatisfy` onlyFinding "no longer creates through the registered native client"
    -- Still a native creator, but the cited entry point is gone.
    violations
      ( editSource
          productionIam
          ( const
              "import Prodbox.Aws.Native.Iam\ncreateRoleSomewhere client = createRole client\ndestroyProductionIamIdentity :: ()\ndestroyProductionIamIdentity = ()\n"
          )
          corpus
      )
      `shouldSatisfy` onlyFinding
        "ensureProductionIamPrerequisites` in src/Prodbox/Lifecycle/CredentialProvisioner/ProductionIam.hs, which does not define it"

  it "refuses a destroy path that does not exist, and a row that names none" $ do
    corpus <- loadCorpus
    let renamed =
          [ row {rowDestroy = [cite {citeIdentifier = "noSuchDestroy"} | cite <- rowDestroy row]}
          | row <- createRecordCoverage
          ]
        unnamed =
          [ if rowSubject row == RegisteredKeyCreator AwsDnsValidationZoneKey
              then row {rowDestroy = []}
              else row
          | row <- createRecordCoverage
          ]
    createRecordCoverageViolations renamed corpus
      `shouldSatisfy` mentions "is not defined at the top level of that module"
    createRecordCoverageViolations unnamed corpus
      `shouldSatisfy` onlyFinding "is off the write-ahead lane or declared inside a manifest and names no destroy path"

writerCases :: SuiteBuilder ()
writerCases =
  it "admits only the manifest's own modules to the identifiers that commit or append it" $ do
    corpus <- loadCorpus
    -- The client entry points and the repository operations beneath them: a
    -- writer through the repository layer must be as visible as one above it.
    manifestWriterIdentifiers
      `shouldBe` [ "attemptOwnershipManifestWriteAheadCommit"
                 , "attemptOwnershipManifestCompletionCommit"
                 , "appendObservedIdentitiesToWriteAheadManifest"
                 , "commitOwnershipManifestWriteAheadAttempt"
                 , "commitOwnershipManifestCompletionAttempt"
                 , "createOrReplayOwnershipManifest"
                 , "createOrReplayOwnershipManifestCompletion"
                 ]
    mapM_
      ( \identifier -> do
          let rogue =
                ( "src/Prodbox/Fake/Writer.hs"
                , "module Prodbox.Fake.Writer where\nwrite = " ++ identifier ++ "\n"
                )
          violations corpus {corpusSources = rogue : corpusSources corpus}
            `shouldSatisfy` onlyFinding ("references " ++ identifier)
      )
      manifestWriterIdentifiers
    -- The endpoint that applies a write is a committer today, so it is named,
    -- and every allowed module may reference every identifier.
    manifestWriterModules
      `shouldSatisfy` ("src/Prodbox/ControlPlane/OwnershipManifestEndpoint.hs" `elem`)
    let allowed =
          [ (path, "module Allowed where\n" ++ unlines manifestWriterIdentifiers)
          | path <- manifestWriterModules
          ]
        others = filter ((`notElem` manifestWriterModules) . fst) (corpusSources corpus)
    violations corpus {corpusSources = allowed ++ others} `shouldBe` []

maskingCases :: SuiteBuilder ()
maskingCases = do
  it "masks comments, string literals and character literals and keeps code and newlines" $ do
    let masked = maskHaskellCommentsAndLiterals
        visible = words . masked
    -- A dash pair inside a literal is not a comment.
    visible "run \"--flag\" createRole" `shouldBe` ["run", "createRole"]
    -- A block-comment opener inside a literal does not swallow the rest of the file.
    visible "x = \"{-\"\ncreateRole" `shouldBe` ["x", "=", "createRole"]
    -- A double quote as a character literal does not open a string.
    visible "f '\"' = createRole \"ignored\"" `shouldBe` ["f", "=", "createRole"]
    visible "f '\\'' g = createRole" `shouldBe` ["f", "g", "=", "createRole"]
    -- A quote in a comment does not open a string.
    visible "-- it says \"hello\nrealCode" `shouldBe` ["realCode"]
    visible "{- outer {- nested createRole -} still comment -} after" `shouldBe` ["after"]
    -- A dash operator is code, and a primed identifier is not a literal.
    visible "a --> createRole" `shouldBe` ["a", "-->", "createRole"]
    visible "go' \"text\" createRole" `shouldBe` ["go'", "createRole"]
    -- Line structure survives.
    length (lines (masked "a\n\"b\nc\"\n-- d\ne")) `shouldBe` 5
    -- A string gap closes at the backslash that follows it.
    visible "x = \"ab\\\n   \\cd\" createRole" `shouldBe` ["x", "=", "createRole"]

  it "does not let a message that names an identifier satisfy or trip a rule" $ do
    corpus <- loadCorpus
    let quoted = maskHaskellCommentsAndLiterals
        message identifier = "module Prodbox.Fake.Message where\nnote = \"" ++ identifier ++ " failed\"\n"
    -- A log line that names the committer is not a writer.
    violations
      corpus
        { corpusSources =
            ("src/Prodbox/Fake/Message.hs", quoted (message "attemptOwnershipManifestCompletionCommit"))
              : corpusSources corpus
        }
      `shouldBe` []
    -- A message that names the creator verb is not a creator, even beside a native import.
    violations
      corpus
        { corpusSources =
            ( "src/Prodbox/Fake/Message.hs"
            , quoted ("import Prodbox.Aws.Native.Iam\n" ++ message "createRole")
            )
              : corpusSources corpus
        }
      `shouldBe` []
    -- A message that names the submitter does not make a program call it.
    violations
      ( editSource
          "src/Prodbox/Infra/AwsEksTestStack.hs"
          ( \text ->
              replaceAll "submitRegisteredStackCreation authentication" "somethingElse authentication" text
                ++ quoted "\nnote = \"submitRegisteredStackCreation\"\n"
          )
          corpus
      )
      `shouldSatisfy` onlyFinding "does not import the submitter and call it outside the import list"

-- Helpers ----------------------------------------------------------------------

loadCorpus :: IO CreateRecordCorpus
loadCorpus = getCurrentDirectory >>= readCreateRecordCorpus

violations :: CreateRecordCorpus -> [String]
violations = createRecordCoverageViolations createRecordCoverage

-- | Any finding contains the text.
mentions :: String -> [String] -> Bool
mentions needle = any (needle `isInfixOf`)

-- | Exactly one finding, and it is the one the mutation earns, so a mutation
-- that happens to trip several rules cannot pass for the rule it targets.
onlyFinding :: String -> [String] -> Bool
onlyFinding needle findings = case findings of
  [only] -> needle `isInfixOf` only
  _ -> False

isProgram :: Text.Text -> CreateRecordRow -> Bool
isProgram directory row = case rowSubject row of
  PulumiProgramCreator name _ -> name == directory
  RegisteredKeyCreator _ -> False
  NativeClientCreator _ _ -> False

firstRow :: (CreateRecordRow -> Bool) -> CreateRecordRow
firstRow predicate = case filter predicate createRecordCoverage of
  row : _ -> row
  [] -> error "the shipped table has no such row"

editSource
  :: FilePath -> (String -> String) -> CreateRecordCorpus -> CreateRecordCorpus
editSource path edit corpus =
  corpus
    { corpusSources = [(p, if p == path then edit text else text) | (p, text) <- corpusSources corpus]
    }

editMain
  :: String -> (String -> String) -> CreateRecordCorpus -> CreateRecordCorpus
editMain directory edit corpus =
  corpus
    { corpusPulumiMain =
        [(d, if d == directory then edit text else text) | (d, text) <- corpusPulumiMain corpus]
    }

replaceAll :: String -> String -> String -> String
replaceAll needle replacement =
  Text.unpack . Text.replace (Text.pack needle) (Text.pack replacement) . Text.pack
