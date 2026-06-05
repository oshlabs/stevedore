defmodule Stevedore do
  @moduledoc """
  A library-first, daemonless OCI toolkit for Elixir — everything you can do to a container
  image **except run it**.

  Stevedore handles OCI artifacts *at rest* (as bytes): fetch, inspect, copy, mirror, build,
  modify, analyze, sign, verify, and serve images. Running them (namespaces, mounts, cgroups)
  is out of scope.

  ## Layers

  The library is a pure core with optional shells (see the design in `PLAN.md`):

    * **Core data types** — `Stevedore.Reference`, `Stevedore.Digest`, `Stevedore.MediaType`,
      and `Stevedore.Archive` (tar/gzip). Pure functions over data, no processes, no heavy deps.
    * **The `Stevedore.Store` seam** — content-addressed blob I/O for on-disk transports, with
      `Stevedore.Store.Local` and `Stevedore.Store.Memory` implementations.

  Higher-level verbs (`inspect/2`, `copy/3`, …) and transports arrive in later phases. See
  `docs/EXAMPLES.md` for a tour of the target API and `docs/REFERENCES.md` for the specs
  implemented.

  Nothing here starts a process; adding `:stevedore` as a dependency is weightless.
  """
end
