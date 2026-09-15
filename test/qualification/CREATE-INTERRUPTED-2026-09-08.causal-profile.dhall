{ format_version = 1
, fixture_id = "CREATE-INTERRUPTED-2026-09-08"
, profile_id = "create-interrupted-causal-v1"
, profile_kind = "causal"
, background_load =
  { request_rate_per_second = 4
  , concurrent_clients = 2
  , payload_bytes = 1024
  }
, fault_schedule =
  [ "mint-run-marker"
  , "admit-create"
  , "commit-generation"
  , "commit-write-ahead-manifest"
  , "read-back-write-ahead-manifest"
  , "execute-admitted-create"
  , "append-observed-identities"
  ]
, fault_schedule_digest = "d7e516c4cfef8d9a1ed8a354aec44db90462271a981eab6c03df8ca4f150b5e6"
, independently_justified = False
, superseded_envelopes =
  [ { component = "legacy-create-submitter"
    , cpu_millis = 900
    , memory_mib = 1024
    , ephemeral_mib = 768
    , persistence_mib = 768
    }
  ]
, replacement_envelopes =
  [ { component = "lifecycle-authority"
    , cpu_millis = 350
    , memory_mib = 448
    , ephemeral_mib = 256
    , persistence_mib = 384
    }
  , { component = "provider-worker"
    , cpu_millis = 300
    , memory_mib = 320
    , ephemeral_mib = 256
    , persistence_mib = 192
    }
  , { component = "ownership-manifest-store"
    , cpu_millis = 250
    , memory_mib = 256
    , ephemeral_mib = 256
    , persistence_mib = 192
    }
  ]
, envelope_mapping =
  [ { superseded_component = "legacy-create-submitter"
    , replacement_components =
      [ "lifecycle-authority"
      , "provider-worker"
      , "ownership-manifest-store"
      ]
    }
  ]
}
