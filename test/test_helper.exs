# Heavy suites are excluded by default so `mix test` stays hermetic and offline. Opt in per tag:
#   mix test --include external      # real registries (Docker Hub, ghcr, registry:2, zot)
#   mix test --include conformance   # boots the server + runs the OCI distribution-spec suite (Go)
#   mix test --include interop       # produce/consume against skopeo/crane/cosign/podman/...
# See docs/TESTING.md for the full taxonomy.
ExUnit.configure(exclude: [:external, :conformance, :interop])
ExUnit.start()
