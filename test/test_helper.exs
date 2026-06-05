# `:external` tests hit real registries (Docker Hub, ghcr). Run them with:
#   mix test --include external
ExUnit.configure(exclude: [:external])
ExUnit.start()
