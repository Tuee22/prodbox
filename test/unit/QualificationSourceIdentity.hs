{-# LANGUAGE OverloadedStrings #-}

module QualificationSourceIdentity (qualificationSourceIdentitySuite) where

import Data.ByteString.Char8 qualified as BS8
import Data.Either (isLeft)
import Data.Text (Text)
import Prodbox.CheckCode (qualificationIsolationViolations)
import Prodbox.Test.Qualification.SourceIdentity
import Test.Tasty.HUnit (assertBool, (@?=))
import TestSupport (SuiteBuilder, describe, it)

qualificationSourceIdentitySuite :: SuiteBuilder ()
qualificationSourceIdentitySuite =
  describe "qualification source identity" $ do
    it "binds HEAD, dirty flag, policy, and deterministic manifest" $ do
      headId <- acceptedHead
      let candidates =
            [ regular "src/Prodbox/App.hs" 0o644 "module Prodbox.App where"
            , regular "DEVELOPMENT_PLAN/README.md" 0o644 "# Development plan"
            ]
      first <- acceptedIdentity headId WorktreeDirty [] candidates
      second <- acceptedIdentity headId WorktreeDirty [] (reverse candidates)
      first @?= second
      sourceWorktreeState first @?= WorktreeDirty
      sourceManifestEntryCount first @?= 2
      sourcePolicyIdentifier (sourceManifestPolicyIdentity first)
        @?= canonicalSourceManifestPolicyId
      sourcePolicyVersion (sourceManifestPolicyIdentity first)
        @?= canonicalSourceManifestPolicyVersion
    it "AWS-lifecycle scope: only listed modules and Pulumi programs move the identity" $ do
      headId <- acceptedHead
      let scoped = "src/Prodbox/Lifecycle/AwsStackDestroy.hs"
          pulumi = "pulumi/aws-eks/Main.yaml"
          base =
            [ regular scoped 0o644 "destroy v1"
            , regular pulumi 0o644 "program v1"
            , regular "src/Prodbox/App.hs" 0o644 "app v1"
            , regular "DEVELOPMENT_PLAN/README.md" 0o644 "plan v1"
            , regular "test/unit/Other.hs" 0o644 "test v1"
            ]
          scopedIdentity = either (fail . show) pure . mkAwsLifecycleSourceIdentity headId WorktreeDirty []
          replaceBytes path new =
            map (\c -> if sourceCandidatePath c == path then c {sourceCandidateBytes = new} else c) base
      baseline <- scopedIdentity base
      listed <- scopedIdentity (replaceBytes scoped "destroy v2")
      program <- scopedIdentity (replaceBytes pulumi "program v2")
      unlisted <- scopedIdentity (replaceBytes "src/Prodbox/App.hs" "app v2")
      document <- scopedIdentity (replaceBytes "DEVELOPMENT_PLAN/README.md" "plan v2")
      outsideTest <- scopedIdentity (replaceBytes "test/unit/Other.hs" "test v2")
      assertBool
        "listed module participates"
        (sourceManifestDigest baseline /= sourceManifestDigest listed)
      assertBool
        "Pulumi program participates"
        (sourceManifestDigest baseline /= sourceManifestDigest program)
      sourceManifestDigest baseline @?= sourceManifestDigest unlisted
      sourceManifestDigest baseline @?= sourceManifestDigest document
      sourceManifestDigest baseline @?= sourceManifestDigest outsideTest
      sourceManifestEntryCount baseline @?= 2
      sourcePolicyIdentifier (sourceManifestPolicyIdentity baseline)
        @?= awsLifecycleSourceManifestPolicyId
      full <- acceptedIdentity headId WorktreeDirty [] base
      assertBool
        "scoped policy digest differs from the full one"
        ( sourcePolicyDigest (sourceManifestPolicyIdentity baseline)
            /= sourcePolicyDigest (sourceManifestPolicyIdentity full)
        )
      assertBool "scope paths are recognised" (all isAwsLifecycleScopePath awsLifecycleScopePaths)
      assertBool "an unlisted module is outside" (not (isAwsLifecycleScopePath "src/Prodbox/App.hs"))
    it "AWS-lifecycle scope refuses an excluded candidate and an empty scope" $ do
      headId <- acceptedHead
      assertBool
        "secret candidate refused"
        ( isLeft
            (mkAwsLifecycleSourceIdentity headId WorktreeDirty [] [regular "test-secrets.dhall" 0o600 "s"])
        )
      assertBool
        "no scoped path is empty"
        ( isLeft
            (mkAwsLifecycleSourceIdentity headId WorktreeDirty [] [regular "src/Prodbox/App.hs" 0o644 "a"])
        )
    it "content and mode drift change the source manifest" $ do
      headId <- acceptedHead
      baseline <- acceptedIdentity headId WorktreeClean [] [regular "src/A.hs" 0o644 "a"]
      contentDrift <- acceptedIdentity headId WorktreeClean [] [regular "src/A.hs" 0o644 "b"]
      modeDrift <- acceptedIdentity headId WorktreeClean [] [regular "src/A.hs" 0o755 "a"]
      assertBool
        "content participates"
        (sourceManifestDigest baseline /= sourceManifestDigest contentDrift)
      assertBool "mode participates" (sourceManifestDigest baseline /= sourceManifestDigest modeDrift)
    it "configured secret roots participate in policy identity" $ do
      headId <- acceptedHead
      first <- acceptedIdentity headId WorktreeClean ["private-a"] [regular "src/A.hs" 0o644 "a"]
      second <- acceptedIdentity headId WorktreeClean ["private-b"] [regular "src/A.hs" 0o644 "a"]
      assertBool
        "policy changes"
        ( sourcePolicyDigest (sourceManifestPolicyIdentity first)
            /= sourcePolicyDigest (sourceManifestPolicyIdentity second)
        )
    it "secret, runtime, and build candidates are hard refusals" $ do
      headId <- acceptedHead
      let rejectedPaths =
            [ "test-secrets.dhall"
            , "secrets/operator-token"
            , ".build/prodbox"
            , "dist-newstyle/cache/plan.json"
            , "src/operator.pem"
            , "private-root/material.txt"
            ]
      mapM_
        ( \path ->
            assertBool
              ("expected exclusion: " <> show path)
              (isLeft (mkSourceIdentity headId WorktreeDirty ["private-root"] [regular path 0o600 "secret"]))
        )
        rejectedPaths
    it "classifies schema/code inputs positively and secrets before byte capture" $ do
      classifySourcePath [] "src/Prodbox/App.hs" @?= Right SourcePathAdmitted
      classifySourcePath [] "dhall/cluster/Schema.dhall" @?= Right SourcePathAdmitted
      classifySourcePath [] "test/fixture.env" @?= Right SourcePathOutsideAllowlist
      classifySourcePath [] "test/fixture.pem" @?= Right SourcePathExcludedByPolicy
      classifySourcePath ["private-root"] "private-root/material.txt"
        @?= Right SourcePathExcludedByPolicy
    it "unallowlisted, absolute, traversing, and duplicate paths refuse" $ do
      headId <- acceptedHead
      let rejected =
            [ [regular "assets/blob.bin" 0o644 "x"]
            , [regular "/src/A.hs" 0o644 "x"]
            , [regular "src/../A.hs" 0o644 "x"]
            , [regular "src/A.hs" 0o644 "x", regular "src/A.hs" 0o644 "x"]
            ]
      mapM_
        (assertBool "candidate set must refuse" . isLeft . mkSourceIdentity headId WorktreeClean [])
        rejected
    it "Git HEAD requires a complete lowercase SHA-1 or SHA-256 hex value" $ do
      assertBool "short" (isLeft (mkGitHead "abc"))
      assertBool "uppercase" (isLeft (mkGitHead "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))
    it "cannot be imported by a production module or capability registry" $ do
      qualificationIsolationViolations
        [ ("src/Prodbox/Test/Fixture.hs", "import Prodbox.Test.Qualification.SourceIdentity")
        , ("src/Prodbox/Runtime/Role.hs", "import Prodbox.Runtime.Other")
        ]
        @?= []
      qualificationIsolationViolations
        [("src/Prodbox/ControlPlane/Runtime.hs", "import Prodbox.Test.Qualification.SourceIdentity")]
        @?= ["src/Prodbox/ControlPlane/Runtime.hs imports the test-only Prodbox.Test.Qualification namespace."]

acceptedHead :: IO GitHead
acceptedHead =
  case mkGitHead "0123456789abcdef0123456789abcdef01234567" of
    Right value -> pure value
    Left err -> fail (show err)

acceptedIdentity :: GitHead -> WorktreeState -> [Text] -> [SourceCandidate] -> IO SourceIdentity
acceptedIdentity headId worktree roots candidates =
  case mkSourceIdentity headId worktree roots candidates of
    Right value -> pure value
    Left err -> fail (show err)

regular :: Text -> Word -> BS8.ByteString -> SourceCandidate
regular path mode bytes =
  SourceCandidate
    { sourceCandidatePath = path
    , sourceCandidateType = ManifestRegularFile
    , sourceCandidateMode = fromIntegral mode
    , sourceCandidateBytes = bytes
    }
