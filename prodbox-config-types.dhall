-- prodbox-config-types.dhall
-- Version-controlled schema with defaults.
-- User config (`prodbox-config.dhall`) imports this and overrides required fields.
--
-- Usage:
--   let Config = ./prodbox-config-types.dhall
--   in  Config::{ aws = Config.default.aws // { access_key_id = "AKIA...", ... }, ... }
--   After editing a committed repo-root config file, rerun
--   `dhall freeze --all --inplace prodbox-config.dhall` so the import keeps its
--   required `sha256:` annotation.

{ Type =
    { aws :
        { access_key_id : Text
        , secret_access_key : Text
        , session_token : Optional Text
        , region : Text
        }
    , aws_admin_for_test_simulation :
        { access_key_id : Text
        , secret_access_key : Text
        , session_token : Optional Text
        , region : Text
        }
    , route53 : { zone_id : Text }
    , aws_substrate :
        { hosted_zone_id : Text
        , subzone_name : Text
        }
    , ses :
        { sender_domain : Text
        , receive_subdomain : Text
        , capture_bucket : Text
        }
    , domain :
        { demo_fqdn : Text
        , demo_ttl : Natural
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
        , public_edge_advertisement_mode : Optional Text
        , public_edge_bgp_peers :
            Optional
              ( List
                  { peer_name : Text
                  , peer_address : Text
                  , peer_asn : Natural
                  , my_asn : Natural
                  , ebgp_multi_hop : Optional Bool
                  }
              )
        , envoy_gateway_controller_replicas : Optional Natural
        , envoy_gateway_data_plane_replicas : Optional Natural
        , api_replicas : Optional Natural
        , websocket_replicas : Optional Natural
        }
    , storage :
        { manual_pv_host_root : Text
        }
    }
, default =
    { aws =
        { access_key_id = ""
        , secret_access_key = ""
        , session_token = None Text
        , region = "us-east-1"
        }
    , aws_admin_for_test_simulation =
        { access_key_id = ""
        , secret_access_key = ""
        , session_token = None Text
        , region = ""
        }
    , route53 = { zone_id = "" }
    , aws_substrate =
        { hosted_zone_id = ""
        , subzone_name = ""
        }
    , ses =
        { sender_domain = ""
        , receive_subdomain = ""
        , capture_bucket = ""
        }
    , domain =
        { demo_fqdn = "test.resolvefintech.com"
        , demo_ttl = 60
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
        , public_edge_advertisement_mode = Some "l2"
        , public_edge_bgp_peers =
            None
              ( List
                  { peer_name : Text
                  , peer_address : Text
                  , peer_asn : Natural
                  , my_asn : Natural
                  , ebgp_multi_hop : Optional Bool
                  }
              )
        , envoy_gateway_controller_replicas = Some 1
        , envoy_gateway_data_plane_replicas = Some 1
        , api_replicas = Some 2
        , websocket_replicas = Some 2
        }
    , storage =
        { manual_pv_host_root = ".data"
        }
    }
}
