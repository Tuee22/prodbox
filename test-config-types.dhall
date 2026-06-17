-- test-config-types.dhall
-- Version-controlled schema for the TEST-HARNESS-ONLY cleartext fixture.
--
-- This schema is committed; the file that imports it (`test-config.dhall`) is
-- git-ignored and is supplied only by the test harness or an operator-driven
-- automation run. It carries two test-only cleartext values:
--
--   * `vault_operator_password` — the unlock-bundle password the harness uses
--     to drive the non-interactive Vault unlock path that a real operator
--     would type on a TTY.
--   * `aws_admin_for_test_simulation` — the EPHEMERAL admin AWS credential the
--     harness feeds into the same interactive admin prompt the operator would
--     answer, so the suite-level IAM bring-up runs non-interactively.
--
-- These values are NEVER part of `prodbox-config(-types).dhall` and are NEVER
-- written to Vault. They exist solely to simulate the operator prompt.
--
-- Usage:
--   let TestConfig = ./test-config-types.dhall
--   in  TestConfig::{ vault_operator_password = "...", aws_admin_for_test_simulation = TestConfig.default.aws_admin_for_test_simulation // { ... } }

{ Type =
    { vault_operator_password : Text
    , aws_admin_for_test_simulation :
        { access_key_id : Text
        , secret_access_key : Text
        , session_token : Optional Text
        , region : Text
        }
    }
, default =
    { vault_operator_password = ""
    , aws_admin_for_test_simulation =
        { access_key_id = ""
        , secret_access_key = ""
        , session_token = None Text
        , region = ""
        }
    }
}
