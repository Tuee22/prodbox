-- prodbox-config-types.dhall
-- Version-controlled schema with defaults.
-- User config (`prodbox-config.dhall`) imports this and overrides required fields.
--
-- Usage:
--   let Config = ./prodbox-config-types.dhall
--   in  Config::{ aws = Config.default.aws // { region = "us-west-2" }, ... }

let SecretRef =
      < Vault : { mount : Text, path : Text, field : Text }
      | TransitKey : Text
      | Prompt : { name : Text, purpose : Text }
      | TestPlaintext : Text
      >

in
{ SecretRef = SecretRef
, Type =
    { aws :
        { access_key_id : SecretRef
        , secret_access_key : SecretRef
        , session_token : Optional SecretRef
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
        , eab_key_id : Optional SecretRef
        , eab_hmac_key : Optional SecretRef
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
    , pulumi_state_backend :
        { bucket_name : Text
        , region : Text
        , key_prefix : Text
        }
    }
, default =
    { aws =
        { access_key_id =
            SecretRef.Vault { mount = "secret", path = "gateway/gateway/aws", field = "access_key_id" }
        , secret_access_key =
            SecretRef.Vault { mount = "secret", path = "gateway/gateway/aws", field = "secret_access_key" }
        , session_token = None SecretRef
        , region = "us-east-1"
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
        , server = "https://acme.zerossl.com/v2/DV90"
        , eab_key_id =
            Some (SecretRef.Vault { mount = "secret", path = "acme/eab", field = "key_id" })
        , eab_hmac_key =
            Some (SecretRef.Vault { mount = "secret", path = "acme/eab", field = "hmac_key" })
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
    , pulumi_state_backend =
        { bucket_name = ""
        , region = ""
        , key_prefix = "pulumi/"
        }
    }
}
