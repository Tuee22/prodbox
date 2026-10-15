-- | Sprint 8.14: the Keycloak consumer script speaks the @kcadm@ that ships in the
-- Keycloak image, and says which step it failed in.
--
-- The invite step called @kcadm.sh put@. There is no such command: @kcadm@ has
-- @config@, @create@, @get@, @update@, @delete@, @get-roles@, @add-roles@,
-- @remove-roles@ and @set-password@, and a PUT of an endpoint that is not a
-- resource is @update --no-merge@. The script is a string the host sends into the
-- Pod, no test ran it, and the failure it produced came back as a constant, so the
-- first live invite stopped there without a reason. Checked against the pinned
-- @keycloak:26.0.0@ on 2026-10-12: @kcadm.sh put ...@ answers @Unmatched
-- arguments@, and @kcadm.sh update users/<id>/execute-actions-email -n -b '[...]'@
-- reaches the endpoint.
module KeycloakConsumerScript (keycloakConsumerScriptSuite) where

import Data.Char (isAlphaNum)
import Data.List (isInfixOf, nub, sort, stripPrefix, tails)
import Prodbox.UsersAdmin
  ( consumerFailureDiagnostic
  , keycloakConsumerScript
  , keycloakConsumerStageTokens
  )
import TestSupport

keycloakConsumerScriptSuite :: SuiteBuilder ()
keycloakConsumerScriptSuite =
  describe "Sprint 8.14 the Keycloak consumer script speaks the kcadm that ships in the image" $ do
    it "names only kcadm commands that exist" $ do
      unknownKcadmVerbs keycloakConsumerScript `shouldBe` []
      keycloakConsumerScript `shouldSatisfy` (not . isInfixOf "${KCADM} put")

    it "flags the line it replaced, so the check is not vacuous" $
      unknownKcadmVerbs oldInviteLine `shouldBe` ["put"]

    it "sends the invite action email as an unmerged update of the endpoint" $ do
      keycloakConsumerScript
        `shouldSatisfy` isInfixOf
          "${KCADM} update \"users/${user_id}/execute-actions-email\" -r \"${realm}\""
      keycloakConsumerScript
        `shouldSatisfy` isInfixOf
          "-n -b '[\"VERIFY_EMAIL\",\"UPDATE_PASSWORD\"]'"

    it "announces every stage it can fail in, from one closed list" $ do
      sort (nub (stageCalls keycloakConsumerScript)) `shouldBe` sort keycloakConsumerStageTokens
      nub keycloakConsumerStageTokens `shouldBe` keycloakConsumerStageTokens

    it "reports the last stage it announced and the exit status, and nothing else it printed" $ do
      let stderrText =
            unlines
              [ "prodbox-stage=login/admin"
              , "prodbox-stage=invite/create-user"
              , "prodbox-stage=invite/send-actions-email"
              , "Unmatched arguments from index 0: 'put' 'users/9799e876/execute-actions-email'"
              ]
          message = consumerFailureDiagnostic 1 stderrText
      message `shouldSatisfy` isInfixOf "invite/send-actions-email"
      message `shouldSatisfy` isInfixOf "exit 1"
      message `shouldSatisfy` (not . isInfixOf "Unmatched")
      message `shouldSatisfy` (not . isInfixOf "9799e876")

    it "repeats no stage the script does not announce" $ do
      consumerFailureDiagnostic 2 "prodbox-stage=not/a-stage\nsomething else\n"
        `shouldBe` "see Keycloak consumer Pod logs (exit 2)"
      consumerFailureDiagnostic 3 "  prodbox-stage=invite/create-user extra\n"
        `shouldBe` "see Keycloak consumer Pod logs (exit 3)"
      consumerFailureDiagnostic 4 "\n  \n"
        `shouldBe` "consumer returned no diagnostic (exit 4)"

-- | The commands of the @kcadm.sh@ in the pinned Keycloak image.
kcadmCommands :: [String]
kcadmCommands =
  [ "config"
  , "create"
  , "get"
  , "update"
  , "delete"
  , "get-roles"
  , "add-roles"
  , "remove-roles"
  , "set-password"
  ]

-- | The words that follow @${KCADM} @ in a script and are not kcadm commands.
unknownKcadmVerbs :: String -> [String]
unknownKcadmVerbs script =
  [ verb
  | verb <- kcadmVerbsIn script
  , verb `notElem` kcadmCommands
  ]

kcadmVerbsIn :: String -> [String]
kcadmVerbsIn script =
  [ takeWhile (\character -> isAlphaNum character || character == '-') rest
  | candidate <- tails script
  , Just rest <- [stripPrefix "${KCADM} " candidate]
  ]

-- | The tokens of the @stage <token>@ lines of a script (the function
-- definition and the diagnostics are not calls).
stageCalls :: String -> [String]
stageCalls script =
  [ token
  | line <- lines script
  , "stage" : token : _ <- [words line]
  ]

-- | The invite line as it was before the repair.
oldInviteLine :: String
oldInviteLine =
  "    ${KCADM} put \"users/${user_id}/execute-actions-email\" -r \"${realm}\" --config \"${KCADM_CONFIG}\" -b '[\"VERIFY_EMAIL\",\"UPDATE_PASSWORD\"]' >/dev/null"
