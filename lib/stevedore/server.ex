defmodule Stevedore.Server do
  @moduledoc """
  The standalone `/v2` registry server: a supervision tree of `Stevedore.Server.Uploads` and a
  Bandit HTTP listener serving `Stevedore.Plug`.

  Started explicitly via `Stevedore.start_link/1` — nothing here boots automatically, keeping the
  library weightless. Requires the optional `:bandit` dependency.

  ## Options

    * `:store` — filesystem root for registry data (required)
    * `:port` — listen port (default `5000`)
    * `:authorize` — the `Stevedore.Plug` authorize seam (default: read-only)
    * `:realm` — token realm for `WWW-Authenticate`
    * `:upload_ttl` — idle upload-session TTL in ms
    * `:name` — supervisor name
  """

  use Supervisor

  @doc "Starts the registry server supervision tree."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    ensure_bandit!()
    {name, opts} = Keyword.pop(opts, :name)
    Supervisor.start_link(__MODULE__, opts, sup_name(name))
  end

  @impl true
  def init(opts) do
    store = Keyword.fetch!(opts, :store)
    port = Keyword.get(opts, :port, 5000)
    uploads = Keyword.get(opts, :uploads, Stevedore.Server.Uploads)

    plug_opts =
      [store: store, uploads: uploads]
      |> put_if(:authorize, opts[:authorize])
      |> put_if(:realm, opts[:realm])

    uploads_opts = [name: uploads] |> put_if(:ttl, opts[:upload_ttl])

    children = [
      {Stevedore.Server.Uploads, uploads_opts},
      {Bandit, plug: {Stevedore.Plug, plug_opts}, port: port}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @spec sup_name(atom() | nil) :: keyword()
  defp sup_name(nil), do: []
  defp sup_name(name), do: [name: name]

  @spec put_if(keyword(), atom(), term()) :: keyword()
  defp put_if(opts, _key, nil), do: opts
  defp put_if(opts, key, value), do: Keyword.put(opts, key, value)

  @spec ensure_bandit!() :: :ok
  defp ensure_bandit! do
    unless Code.ensure_loaded?(Bandit) do
      raise RuntimeError,
            "Stevedore.Server requires the optional :bandit (and :plug) dependencies. " <>
              "Add {:bandit, \"~> 1.5\"} to your deps to run the registry server."
    end

    :ok
  end
end
