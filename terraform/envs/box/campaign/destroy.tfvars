# Placeholders for `tofu destroy`, which needs a value for every variable but
# destroys whatever the state holds, whatever these say. campaign.yml's down
# and the reaper use this file; up takes the dispatch's inputs.
instance_type  = "m9gd.2xlarge"
expires_at     = "2000-01-01T00:00:00Z"
forge_perf_sha = "0000000000000000000000000000000000000000"
campaign = {
  mode     = "calibration"
  set      = ""
  runs     = 1
  size     = "1GB"
  workers  = []
  duration = "1m"
}
