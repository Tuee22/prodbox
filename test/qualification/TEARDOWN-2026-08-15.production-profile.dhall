{ format_version = 1
, fixture_id = "TEARDOWN-2026-08-15"
, profile_id = "teardown-production-v1"
, profile_kind = "production"
, background_load =
  { request_rate_per_second = 20
  , concurrent_clients = 4
  , payload_bytes = 2048
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
, independently_justified = True
, superseded_envelopes =
  [ { component = "legacy-cleanup-runner"
    , cpu_millis = 1600
    , memory_mib = 2048
    , ephemeral_mib = 2048
    , persistence_mib = 2048
    }
  ]
, replacement_envelopes =
  [ { component = "lifecycle-authority"
    , cpu_millis = 500
    , memory_mib = 640
    , ephemeral_mib = 512
    , persistence_mib = 1024
    }
  , { component = "provider-worker"
    , cpu_millis = 400
    , memory_mib = 512
    , ephemeral_mib = 512
    , persistence_mib = 256
    }
  , { component = "backup-adapter"
    , cpu_millis = 300
    , memory_mib = 384
    , ephemeral_mib = 512
    , persistence_mib = 512
    }
  , { component = "recovery-runner"
    , cpu_millis = 400
    , memory_mib = 512
    , ephemeral_mib = 512
    , persistence_mib = 256
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
