-- prodbox-config-types.dhall
-- Version-controlled schema with defaults.
-- User config (`prodbox-config.dhall`) imports this and overrides required fields.
--
-- Usage:
--   let Config = ./prodbox-config-types.dhall
--   in  Config::{ aws = Config.default.aws // { access_key_id = "AKIA...", ... }, ... }

{ Type =
    { aws :
        { access_key_id : Text
        , secret_access_key : Text
        , session_token : Optional Text
        , region : Text
        }
    , route53 : { zone_id : Text }
    , domain :
        { demo_fqdn : Text
        , demo_ttl : Natural
        , vscode_fqdn : Optional Text
        }
    , acme :
        { email : Text
        , server : Text
        , eab_key_id : Optional Text
        , eab_hmac_key : Optional Text
        }
    , deployment :
        { dev_mode : Bool
        , bootstrap_public_ip_override : Optional Text
        , pulumi_enable_dns_bootstrap : Bool
        }
    }
, default =
    { aws =
        { access_key_id = ""
        , secret_access_key = ""
        , session_token = None Text
        , region = "us-east-1"
        }
    , route53 = { zone_id = "" }
    , domain =
        { demo_fqdn = "demo.example.com"
        , demo_ttl = 60
        , vscode_fqdn = None Text
        }
    , acme =
        { email = ""
        , server = "https://acme-v02.api.letsencrypt.org/directory"
        , eab_key_id = None Text
        , eab_hmac_key = None Text
        }
    , deployment =
        { dev_mode = True
        , bootstrap_public_ip_override = None Text
        , pulumi_enable_dns_bootstrap = True
        }
    }
}
