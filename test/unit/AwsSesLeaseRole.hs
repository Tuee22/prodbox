{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE OverloadedStrings #-}

module AwsSesLeaseRole
  ( awsSesLeaseRoleSuite
  )
where

import Data.Aeson
  ( Value (..)
  , eitherDecode
  , encode
  , object
  , (.=)
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy.Char8 qualified as BL8
import Data.IORef
  ( modifyIORef'
  , newIORef
  , readIORef
  , writeIORef
  )
import Data.List (find)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Prodbox.Infra.AwsSesLeaseRole
  ( AwsSesLeaseRoleCommandFailure (..)
  , AwsSesLeaseRoleDrift (..)
  , AwsSesLeaseRoleError (..)
  , AwsSesLeaseRoleObservation (..)
  , AwsSesLeaseRolePolicyScope
  , AwsSesLeaseRoleValueError (..)
  , awsSesLeaseOperationalUserArn
  , awsSesLeaseOperationalUserName
  , awsSesLeaseRoleArn
  , awsSesLeaseRoleAssumeStatement
  , awsSesLeaseRoleInlinePolicy
  , awsSesLeaseRoleInlinePolicyName
  , awsSesLeaseRoleMaxSessionDurationSeconds
  , awsSesLeaseRoleName
  , awsSesLeaseRoleTrustPolicy
  , classifyAwsSesLeaseRoleCommandResult
  , deleteAwsSesLeaseRoleWith
  , ensureAwsSesLeaseRoleWith
  , mkAwsSesLeaseRolePolicyScope
  , observeAwsSesLeaseRoleWith
  )
import Prodbox.Result (Result (..))
import Prodbox.Subprocess
  ( ProcessOutput (..)
  , Subprocess (..)
  )
import System.Exit (ExitCode (..))
import TestSupport

awsSesLeaseRoleSuite :: SuiteBuilder ()
awsSesLeaseRoleSuite =
  describe "bounded AWS SES lease-session role" $ do
    it "pins the fixed role, exact account ARN, trust principal, and one-hour session bound" $ do
      awsSesLeaseOperationalUserName `shouldBe` "prodbox"
      awsSesLeaseRoleName `shouldBe` "prodbox-ses-lease-session"
      awsSesLeaseRoleInlinePolicyName
        `shouldBe` "prodbox-ses-lease-session-inline"
      awsSesLeaseRoleMaxSessionDurationSeconds `shouldBe` 3600
      awsSesLeaseRoleArn accountId
        `shouldBe` Right
          "arn:aws:iam::123456789012:role/prodbox-ses-lease-session"
      awsSesLeaseOperationalUserArn accountId
        `shouldBe` Right "arn:aws:iam::123456789012:user/prodbox"
      awsSesLeaseRoleArn "12345678901"
        `shouldBe` Left
          (AwsSesLeaseRoleAccountIdMustBeTwelveDigits "12345678901")
      awsSesLeaseRoleArn "12345678901x"
        `shouldBe` Left
          (AwsSesLeaseRoleAccountIdMustBeTwelveDigits "12345678901x")
      awsSesLeaseRoleArn "１２３４５６７８９０１２"
        `shouldBe` Left
          ( AwsSesLeaseRoleAccountIdMustBeTwelveDigits
              "１２３４５６７８９０１２"
          )
      awsSesLeaseRoleTrustPolicy accountId
        `shouldBe` Right exactTrustPolicy
      awsSesLeaseRoleAssumeStatement accountId
        `shouldBe` Right
          ( object
              [ "Sid" .= ("AssumeAwsSesLeaseRole" :: Text)
              , "Effect" .= ("Allow" :: Text)
              , "Action" .= (["sts:AssumeRole"] :: [Text])
              , "Resource"
                  .= ( "arn:aws:iam::123456789012:role/"
                         <> awsSesLeaseRoleName
                     )
              ]
          )

    it "renders a least-privilege policy bounded to the exact user, zone, and capture bucket" $ do
      let policy = awsSesLeaseRoleInlinePolicy scopeWithoutLegacy
          statements = policyStatements policy
          actions = concatMap statementActions statements
          resources = mapMaybe statementResource statements
      statementSids policy
        `shouldBe` [ "StsIdentity"
                   , "Route53RecordLifecycle"
                   , "Route53ChangePolling"
                   , "SesLifecycle"
                   , "CaptureBucketLifecycle"
                   , "CaptureObjectLifecycle"
                   , "SmtpIamUserLifecycle"
                   ]
      statementResourceFor "Route53RecordLifecycle" policy
        `shouldBe` Just "arn:aws:route53:::hostedzone/Z123EXACT"
      statementResourceFor "CaptureBucketLifecycle" policy
        `shouldBe` Just "arn:aws:s3:::prodbox-ses-capture"
      statementResourceFor "CaptureObjectLifecycle" policy
        `shouldBe` Just "arn:aws:s3:::prodbox-ses-capture/*"
      statementResourceFor "SmtpIamUserLifecycle" policy
        `shouldBe` Just
          "arn:aws:iam::123456789012:user/prodbox-ses-smtp"
      statementActionsFor "StsIdentity" policy
        `shouldBe` ["sts:GetCallerIdentity"]
      statementActionsFor "Route53RecordLifecycle" policy
        `shouldBe` [ "route53:ChangeResourceRecordSets"
                   , "route53:GetHostedZone"
                   , "route53:ListResourceRecordSets"
                   ]
      statementActionsFor "SmtpIamUserLifecycle" policy
        `shouldSatisfy` elem "iam:CreateAccessKey"
      statementActionsFor "SmtpIamUserLifecycle" policy
        `shouldSatisfy` elem "iam:DeleteAccessKey"
      statementActionsFor "SesLifecycle" policy
        `shouldSatisfy` elem "ses:GetEmailIdentity"
      statementActionsFor "SesLifecycle" policy
        `shouldSatisfy` elem "ses:VerifyDomainIdentity"
      statementActionsFor "CaptureBucketLifecycle" policy
        `shouldSatisfy` elem "s3:PutBucketPolicy"
      statementActionsFor "CaptureObjectLifecycle" policy
        `shouldSatisfy` elem "s3:DeleteObjectVersion"
      actions `shouldSatisfy` all (not . Text.isSuffixOf ":*")
      filter (Text.isPrefixOf "arn:aws:iam::") resources
        `shouldBe` ["arn:aws:iam::123456789012:user/prodbox-ses-smtp"]
      resources
        `shouldSatisfy` notElem "arn:aws:route53:::hostedzone/*"
      statementResourceFor "LegacyStateBucketLifecycle" policy
        `shouldBe` Nothing

    it "adds only the configured legacy state bucket and rejects unsafe bucket inputs" $ do
      let policy = awsSesLeaseRoleInlinePolicy scopeWithLegacy
      statementResourceFor "LegacyStateBucketLifecycle" policy
        `shouldBe` Just "arn:aws:s3:::prodbox-legacy-state"
      statementResourceFor "LegacyStateObjectLifecycle" policy
        `shouldBe` Just "arn:aws:s3:::prodbox-legacy-state/*"
      mkAwsSesLeaseRolePolicyScope
        accountId
        "Z123EXACT"
        "Bad_Bucket"
        Nothing
        `shouldBe` Left (AwsSesLeaseRoleCaptureBucketInvalid "Bad_Bucket")
      mkAwsSesLeaseRolePolicyScope
        accountId
        "Z123EXACT"
        "192.168.0.1"
        Nothing
        `shouldBe` Left
          (AwsSesLeaseRoleCaptureBucketInvalid "192.168.0.1")
      mkAwsSesLeaseRolePolicyScope
        accountId
        "Z123EXACT"
        "prodbox-ses-capture"
        (Just "Bad_Legacy")
        `shouldBe` Left
          (AwsSesLeaseRoleLegacyStateBucketInvalid "Bad_Legacy")

    it "distinguishes not-found, already-exists, denial, network, start, and other command failures" $ do
      classifyAwsSesLeaseRoleCommandResult noSuchEntityResult
        `shouldBe` Left
          (AwsSesLeaseRoleNotFound noSuchEntityDetail)
      classifyAwsSesLeaseRoleCommandResult alreadyExistsResult
        `shouldBe` Left
          (AwsSesLeaseRoleAlreadyExists alreadyExistsDetail)
      classifyAwsSesLeaseRoleCommandResult accessDeniedResult
        `shouldBe` Left
          (AwsSesLeaseRoleAccessDenied accessDeniedDetail)
      classifyAwsSesLeaseRoleCommandResult networkFailureResult
        `shouldBe` Left
          (AwsSesLeaseRoleNetworkFailure networkFailureDetail)
      classifyAwsSesLeaseRoleCommandResult (Failure "aws executable missing")
        `shouldBe` Left
          (AwsSesLeaseRoleProcessStartFailure "aws executable missing")
      classifyAwsSesLeaseRoleCommandResult
        (failedProcess "unexpected service failure")
        `shouldBe` Left
          (AwsSesLeaseRoleOtherCommandFailure "unexpected service failure")

    it "observes exact authoritative state and treats missing policy as drift" $ do
      (present, presentSpecs, presentRemaining) <-
        runScripted
          [ successfulProcess exactRoleJson
          , successfulProcess exactRolePolicyJson
          ]
          ( \runner ->
              observeAwsSesLeaseRoleWith runner "/repo" environment scopeWithLegacy
          )
      present `shouldBe` AwsSesLeaseRolePresent
      length presentRemaining `shouldBe` 0
      map commandName presentSpecs
        `shouldBe` ["iam get-role", "iam get-role-policy"]
      assertExactSubprocessEnvelope presentSpecs
      Text.pack (show present)
        `shouldSatisfy` (not . Text.isInfixOf secretSentinel)

      (missingPolicy, missingPolicySpecs, missingPolicyRemaining) <-
        runScripted
          [successfulProcess exactRoleJson, noSuchEntityResult]
          ( \runner ->
              observeAwsSesLeaseRoleWith runner "/repo" environment scopeWithLegacy
          )
      missingPolicy
        `shouldBe` AwsSesLeaseRoleDrifted
          [AwsSesLeaseRoleInlinePolicyMissing]
      length missingPolicyRemaining `shouldBe` 0
      map commandName missingPolicySpecs
        `shouldBe` ["iam get-role", "iam get-role-policy"]

      (absent, absentSpecs, absentRemaining) <-
        runScripted
          [noSuchEntityResult]
          ( \runner ->
              observeAwsSesLeaseRoleWith runner "/repo" environment scopeWithLegacy
          )
      absent `shouldBe` AwsSesLeaseRoleAbsent
      length absentRemaining `shouldBe` 0
      map commandName absentSpecs `shouldBe` ["iam get-role"]

    it "keeps malformed, denial, and network observations fail-closed and typed" $ do
      malformed <- observeOnce (successfulProcess "not-json")
      malformed `shouldSatisfy` isMalformedObservation
      denied <- observeOnce accessDeniedResult
      denied
        `shouldBe` AwsSesLeaseRoleUnobservable
          ( AwsSesLeaseRoleCommandError
              (AwsSesLeaseRoleAccessDenied accessDeniedDetail)
          )
      network <- observeOnce networkFailureResult
      network
        `shouldBe` AwsSesLeaseRoleUnobservable
          ( AwsSesLeaseRoleCommandError
              (AwsSesLeaseRoleNetworkFailure networkFailureDetail)
          )
      let driftedRole =
            roleJson
              (object [])
              7200
              awsSesLeaseRoleName
              exactRoleArn
      (drifted, _, remaining) <-
        runScripted
          [successfulProcess driftedRole, noSuchEntityResult]
          ( \runner ->
              observeAwsSesLeaseRoleWith runner "/repo" environment scopeWithLegacy
          )
      length remaining `shouldBe` 0
      drifted
        `shouldBe` AwsSesLeaseRoleDrifted
          [ AwsSesLeaseRoleTrustPolicyDrift
          , AwsSesLeaseRoleMaxSessionDurationDrift 7200
          , AwsSesLeaseRoleInlinePolicyMissing
          ]

    it "idempotently creates-or-updates every role control and authoritatively re-observes" $ do
      (result, specs, remaining) <-
        runScripted
          [ noSuchEntityResult
          , alreadyExistsResult
          , successfulProcess ""
          , successfulProcess ""
          , successfulProcess ""
          , successfulProcess exactRoleJson
          , successfulProcess exactRolePolicyJson
          ]
          ( \runner ->
              ensureAwsSesLeaseRoleWith runner "/repo" environment scopeWithLegacy
          )
      result `shouldBe` Right ()
      length remaining `shouldBe` 0
      map commandName specs
        `shouldBe` [ "iam get-role"
                   , "iam create-role"
                   , "iam update-assume-role-policy"
                   , "iam update-role"
                   , "iam put-role-policy"
                   , "iam get-role"
                   , "iam get-role-policy"
                   ]
      assertExactSubprocessEnvelope specs
      case findCommand "iam create-role" specs of
        Nothing -> expectationFailure "missing create-role command"
        Just spec -> do
          jsonArgument "--assume-role-policy-document" spec
            `shouldBe` Just exactTrustPolicy
          argumentAfter "--max-session-duration" spec `shouldBe` Just "3600"
      case findCommand "iam update-assume-role-policy" specs of
        Nothing -> expectationFailure "missing update-assume-role-policy command"
        Just spec ->
          jsonArgument "--policy-document" spec
            `shouldBe` Just exactTrustPolicy
      case findCommand "iam update-role" specs of
        Nothing -> expectationFailure "missing update-role command"
        Just spec ->
          argumentAfter "--max-session-duration" spec `shouldBe` Just "3600"
      case findCommand "iam put-role-policy" specs of
        Nothing -> expectationFailure "missing put-role-policy command"
        Just spec -> do
          argumentAfter "--policy-name" spec
            `shouldBe` Just (Text.unpack awsSesLeaseRoleInlinePolicyName)
          jsonArgument "--policy-document" spec
            `shouldBe` Just (awsSesLeaseRoleInlinePolicy scopeWithLegacy)

    it "updates an existing role without recreating it and fails a drifted postcondition" $ do
      let wrongPolicyJson = rolePolicyJson (object [])
      (result, specs, remaining) <-
        runScripted
          [ successfulProcess exactRoleJson
          , successfulProcess wrongPolicyJson
          , successfulProcess ""
          , successfulProcess ""
          , successfulProcess ""
          , successfulProcess exactRoleJson
          , successfulProcess wrongPolicyJson
          ]
          ( \runner ->
              ensureAwsSesLeaseRoleWith runner "/repo" environment scopeWithLegacy
          )
      length remaining `shouldBe` 0
      map commandName specs
        `shouldBe` [ "iam get-role"
                   , "iam get-role-policy"
                   , "iam update-assume-role-policy"
                   , "iam update-role"
                   , "iam put-role-policy"
                   , "iam get-role"
                   , "iam get-role-policy"
                   ]
      result `shouldSatisfy` isDriftedPostcondition

    it "deletes policy then role idempotently, re-observes absence, and propagates denial" $ do
      (deleted, deleteSpecs, deleteRemaining) <-
        runScripted
          [ successfulProcess exactRoleJson
          , successfulProcess exactRolePolicyJson
          , noSuchEntityResult
          , successfulProcess ""
          , noSuchEntityResult
          ]
          ( \runner ->
              deleteAwsSesLeaseRoleWith runner "/repo" environment scopeWithLegacy
          )
      deleted `shouldBe` Right ()
      length deleteRemaining `shouldBe` 0
      map commandName deleteSpecs
        `shouldBe` [ "iam get-role"
                   , "iam get-role-policy"
                   , "iam delete-role-policy"
                   , "iam delete-role"
                   , "iam get-role"
                   ]
      assertExactSubprocessEnvelope deleteSpecs

      (alreadyAbsent, absentSpecs, absentRemaining) <-
        runScripted
          [noSuchEntityResult]
          ( \runner ->
              deleteAwsSesLeaseRoleWith runner "/repo" environment scopeWithLegacy
          )
      alreadyAbsent `shouldBe` Right ()
      length absentRemaining `shouldBe` 0
      map commandName absentSpecs `shouldBe` ["iam get-role"]

      (denied, deniedSpecs, deniedRemaining) <-
        runScripted
          [ successfulProcess exactRoleJson
          , successfulProcess exactRolePolicyJson
          , accessDeniedResult
          ]
          ( \runner ->
              deleteAwsSesLeaseRoleWith runner "/repo" environment scopeWithLegacy
          )
      denied
        `shouldBe` Left
          ( AwsSesLeaseRoleCommandError
              (AwsSesLeaseRoleAccessDenied accessDeniedDetail)
          )
      length deniedRemaining `shouldBe` 0
      map commandName deniedSpecs
        `shouldBe` [ "iam get-role"
                   , "iam get-role-policy"
                   , "iam delete-role-policy"
                   ]

accountId :: Text
accountId = "123456789012"

exactRoleArn :: Text
exactRoleArn = "arn:aws:iam::123456789012:role/prodbox-ses-lease-session"

environment :: [(String, String)]
environment =
  [ ("AWS_REGION", "ca-central-1")
  , ("AWS_SECRET_ACCESS_KEY", Text.unpack secretSentinel)
  ]

secretSentinel :: Text
secretSentinel = "must-not-appear-in-show"

scopeWithoutLegacy :: AwsSesLeaseRolePolicyScope
scopeWithoutLegacy =
  expectRight
    ( mkAwsSesLeaseRolePolicyScope
        accountId
        "/hostedzone/Z123EXACT"
        "prodbox-ses-capture"
        Nothing
    )

scopeWithLegacy :: AwsSesLeaseRolePolicyScope
scopeWithLegacy =
  expectRight
    ( mkAwsSesLeaseRolePolicyScope
        accountId
        "Z123EXACT"
        "prodbox-ses-capture"
        (Just "prodbox-legacy-state")
    )

exactTrustPolicy :: Value
exactTrustPolicy =
  object
    [ "Version" .= ("2012-10-17" :: Text)
    , "Statement"
        .= [ object
               [ "Sid" .= ("OperationalUserTrust" :: Text)
               , "Effect" .= ("Allow" :: Text)
               , "Principal"
                   .= object
                     [ "AWS" .= ("arn:aws:iam::123456789012:user/prodbox" :: Text)
                     ]
               , "Action" .= ("sts:AssumeRole" :: Text)
               ]
           ]
    ]

exactRoleJson :: String
exactRoleJson =
  roleJson
    exactTrustPolicy
    3600
    awsSesLeaseRoleName
    exactRoleArn

roleJson :: Value -> Int -> Text -> Text -> String
roleJson trust maximumSeconds roleName roleArn =
  BL8.unpack
    ( encode
        ( object
            [ "Role"
                .= object
                  [ "RoleName" .= roleName
                  , "Arn" .= roleArn
                  , "AssumeRolePolicyDocument" .= trust
                  , "MaxSessionDuration" .= maximumSeconds
                  ]
            ]
        )
    )

exactRolePolicyJson :: String
exactRolePolicyJson =
  rolePolicyJson (awsSesLeaseRoleInlinePolicy scopeWithLegacy)

rolePolicyJson :: Value -> String
rolePolicyJson policy =
  BL8.unpack
    ( encode
        ( object
            [ "RoleName" .= awsSesLeaseRoleName
            , "PolicyName" .= awsSesLeaseRoleInlinePolicyName
            , "PolicyDocument" .= policy
            ]
        )
    )

noSuchEntityDetail :: Text
noSuchEntityDetail =
  "An error occurred (NoSuchEntity) when calling the GetRole operation"

noSuchEntityResult :: Result ProcessOutput
noSuchEntityResult = failedProcess (Text.unpack noSuchEntityDetail)

alreadyExistsDetail :: Text
alreadyExistsDetail =
  "An error occurred (EntityAlreadyExists) when calling CreateRole"

alreadyExistsResult :: Result ProcessOutput
alreadyExistsResult = failedProcess (Text.unpack alreadyExistsDetail)

accessDeniedDetail :: Text
accessDeniedDetail =
  "An error occurred (AccessDenied) when calling the GetRole operation"

accessDeniedResult :: Result ProcessOutput
accessDeniedResult = failedProcess (Text.unpack accessDeniedDetail)

networkFailureDetail :: Text
networkFailureDetail =
  "Could not connect to the endpoint URL: https://iam.amazonaws.com"

networkFailureResult :: Result ProcessOutput
networkFailureResult = failedProcess (Text.unpack networkFailureDetail)

successfulProcess :: String -> Result ProcessOutput
successfulProcess stdout =
  Success
    ProcessOutput
      { processExitCode = ExitSuccess
      , processStdout = stdout
      , processStderr = ""
      }

failedProcess :: String -> Result ProcessOutput
failedProcess stderr =
  Success
    ProcessOutput
      { processExitCode = ExitFailure 1
      , processStdout = ""
      , processStderr = stderr
      }

runScripted
  :: [Result ProcessOutput]
  -> ((Subprocess -> IO (Result ProcessOutput)) -> IO result)
  -> IO (result, [Subprocess], [Result ProcessOutput])
runScripted responses action = do
  remainingRef <- newIORef responses
  seenRef <- newIORef []
  let runner spec = do
        modifyIORef' seenRef (spec :)
        remaining <- readIORef remainingRef
        case remaining of
          [] -> pure (Failure "unexpected extra aws command")
          result : rest -> do
            writeIORef remainingRef rest
            pure result
  result <- action runner
  seen <- reverse <$> readIORef seenRef
  remaining <- readIORef remainingRef
  pure (result, seen, remaining)

observeOnce :: Result ProcessOutput -> IO AwsSesLeaseRoleObservation
observeOnce response = do
  (observation, _, _) <-
    runScripted
      [response]
      ( \runner ->
          observeAwsSesLeaseRoleWith runner "/repo" environment scopeWithLegacy
      )
  pure observation

assertExactSubprocessEnvelope :: [Subprocess] -> IO ()
assertExactSubprocessEnvelope specs = do
  map subprocessPath specs `shouldBe` replicate (length specs) "aws"
  map subprocessEnvironment specs
    `shouldBe` replicate (length specs) (Just environment)
  map subprocessWorkingDirectory specs
    `shouldBe` replicate (length specs) (Just "/repo")

commandName :: Subprocess -> String
commandName = unwords . take 2 . subprocessArguments

findCommand :: String -> [Subprocess] -> Maybe Subprocess
findCommand expected = find ((== expected) . commandName)

argumentAfter :: String -> Subprocess -> Maybe String
argumentAfter flag spec =
  case dropWhile (/= flag) (subprocessArguments spec) of
    _ : value : _ -> Just value
    _ -> Nothing

jsonArgument :: String -> Subprocess -> Maybe Value
jsonArgument flag spec = do
  raw <- argumentAfter flag spec
  either (const Nothing) Just (eitherDecode (BL8.pack raw))

policyStatements :: Value -> [Value]
policyStatements policy = case lookupValue "Statement" policy of
  Just (Array statements) -> Vector.toList statements
  _ -> []

statementSids :: Value -> [Text]
statementSids = mapMaybe (lookupText "Sid") . policyStatements

statementActions :: Value -> [Text]
statementActions statement = case lookupValue "Action" statement of
  Just (Array actions) -> mapMaybe valueText (Vector.toList actions)
  Just (String action) -> [action]
  _ -> []

statementResource :: Value -> Maybe Text
statementResource = lookupText "Resource"

statementFor :: Text -> Value -> Maybe Value
statementFor sid = find ((== Just sid) . lookupText "Sid") . policyStatements

statementActionsFor :: Text -> Value -> [Text]
statementActionsFor sid policy =
  maybe [] statementActions (statementFor sid policy)

statementResourceFor :: Text -> Value -> Maybe Text
statementResourceFor sid policy =
  statementFor sid policy >>= statementResource

lookupValue :: Text -> Value -> Maybe Value
lookupValue key value = case value of
  Object fields -> KeyMap.lookup (Key.fromText key) fields
  _ -> Nothing

lookupText :: Text -> Value -> Maybe Text
lookupText key value = lookupValue key value >>= valueText

valueText :: Value -> Maybe Text
valueText value = case value of
  String textValue -> Just textValue
  _ -> Nothing

isMalformedObservation :: AwsSesLeaseRoleObservation -> Bool
isMalformedObservation observation = case observation of
  AwsSesLeaseRoleUnobservable (AwsSesLeaseRoleMalformedResponse _) -> True
  _ -> False

isDriftedPostcondition :: Either AwsSesLeaseRoleError () -> Bool
isDriftedPostcondition result = case result of
  Left (AwsSesLeaseRolePostconditionFailed detail) ->
    "remains drifted" `Text.isInfixOf` detail
  _ -> False

expectRight :: (Show errorValue) => Either errorValue value -> value
expectRight result = case result of
  Left err -> error ("unexpected Left: " ++ show err)
  Right value -> value
