{ format_version = 1
, fixture_id = "TEARDOWN-2026-08-15"
, profile_id = "teardown-causal-v1"
, profile_kind = "causal"
, background_load =
  { request_rate_per_second = 4
  , concurrent_clients = 2
  , payload_bytes = 1024
  }
, fault_schedule =
  [ "register-run"
  , "commit-observation-intent"
  , "commit-mutation-intent"
  , "commit-mutation-outcome"
  , "commit-independent-readback"
  , "commit-pre-uninstall-report"
  , "commit-report-backup"
  , "commit-terminal-report"
  ]
, fault_schedule_digest = "849389ad7efa705da5e4133de3258564cec1fe80acf57e8ed45eafb10c19b219"
, independently_justified = False
, superseded_envelopes =
  [ { component = "legacy-cleanup-runner"
    , cpu_millis = 1000
    , memory_mib = 1024
    , ephemeral_mib = 1024
    , persistence_mib = 1024
    }
  ]
, replacement_envelopes =
  [ { component = "lifecycle-authority"
    , cpu_millis = 300
    , memory_mib = 300
    , ephemeral_mib = 256
    , persistence_mib = 512
    }
  , { component = "provider-worker"
    , cpu_millis = 250
    , memory_mib = 256
    , ephemeral_mib = 256
    , persistence_mib = 128
    }
  , { component = "backup-adapter"
    , cpu_millis = 200
    , memory_mib = 212
    , ephemeral_mib = 256
    , persistence_mib = 256
    }
  , { component = "recovery-runner"
    , cpu_millis = 250
    , memory_mib = 256
    , ephemeral_mib = 256
    , persistence_mib = 128
    }
  ]
, envelope_mapping =
  [ { superseded_component = "legacy-cleanup-runner"
    , replacement_components =
      [ "lifecycle-authority"
      , "provider-worker"
      , "backup-adapter"
      , "recovery-runner"
      ]
    }
  ]
}
