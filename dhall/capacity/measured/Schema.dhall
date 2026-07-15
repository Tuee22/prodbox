-- Sprint 1.65: the committed measured-capacity profile type.
--
-- A committed profile records, for one authored workload, the sampling evidence,
-- CPU demand, memory high-water marks, backend latency, the digest of the
-- profiled hot-path source, and the capture time. `prodbox dev check`'s
-- conformance tier certifies each authored Guaranteed-QoS envelope against its
-- committed profile: the authored CPU must be at least measured `cpu_p99_milli`
-- × 4/3, `throttled_periods_ppm` must not exceed 20000 while a CPU cap is
-- authored, the measured memory high-water × 4/3 must not exceed the authored
-- memory limit, and the profile must not be stale (`hot_path_digest` mismatch or
-- `recorded_at` older than 30 days). Every comparison is one-sided, so a measured
-- improvement never fails.
--
-- Field names match the `MeasuredResourceProfile` accessors in
-- `src/Prodbox/Capacity/MeasuredProfile.hs` (generic FromDhall) and
-- `documents/engineering/resource_scaling_doctrine.md` § 2F. No real profile is
-- committed yet; the recorder that produces the first one is owned by Sprint
-- 5.21. Committed profiles live beside this file as
-- `dhall/capacity/measured/<profile_id>.dhall`.
{ profile_id : Text
, recorded_at : Natural
, hot_path_digest : Text
, sample_window_seconds : Natural
, sample_count : Natural
, cpu_p95_milli : Natural
, cpu_p99_milli : Natural
, throttled_periods_ppm : Natural
, rss_high_water_mib : Natural
, heap_high_water_bytes : Natural
, object_store_op_p99_millis : Natural
}
