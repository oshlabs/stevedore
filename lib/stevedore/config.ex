defmodule Stevedore.Config do
  @moduledoc """
  A parsed OCI image configuration.

  The config carries the runtime defaults (entrypoint, cmd, env, user, working dir, labels), the
  target `os`/`architecture`, and the `rootfs.diff_ids` — the digests of each layer's
  **uncompressed** tar, which are distinct from the (compressed) layer descriptor digests in the
  manifest. The decoded `json` and `raw` bytes are retained for digest-stable re-emission.

  Spec: [OCI image-spec, config](https://github.com/opencontainers/image-spec/blob/main/config.md).
  """

  alias Stevedore.Digest

  @enforce_keys [:raw, :json]
  defstruct [
    :raw,
    :json,
    :os,
    :architecture,
    :user,
    :working_dir,
    :entrypoint,
    :cmd,
    :env,
    :labels,
    :history,
    rootfs_diff_ids: []
  ]

  @type t :: %__MODULE__{
          raw: binary(),
          json: map(),
          os: String.t() | nil,
          architecture: String.t() | nil,
          user: String.t() | nil,
          working_dir: String.t() | nil,
          entrypoint: [String.t()] | nil,
          cmd: [String.t()] | nil,
          env: [String.t()] | nil,
          labels: %{optional(String.t()) => String.t()} | nil,
          history: [map()] | nil,
          rootfs_diff_ids: [Digest.t()]
        }

  @doc """
  Parses raw image-config bytes.

  ## Examples

      iex> raw = ~s({"architecture":"amd64","os":"linux",
      ...>   "config":{"Entrypoint":["/bin/sh"],"Env":["PATH=/bin"]},
      ...>   "rootfs":{"type":"layers","diff_ids":["sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"]}})
      iex> {:ok, config} = Stevedore.Config.parse(raw)
      iex> {config.architecture, config.entrypoint, hd(config.rootfs_diff_ids).algorithm}
      {"amd64", ["/bin/sh"], :sha256}
  """
  @spec parse(binary()) :: {:ok, t()} | {:error, {:bad_input, term()}}
  def parse(raw) when is_binary(raw) do
    case JSON.decode(raw) do
      {:ok, json} when is_map(json) ->
        inner = json["config"] || %{}

        with {:ok, diff_ids} <- parse_diff_ids(get_in(json, ["rootfs", "diff_ids"]) || []) do
          {:ok,
           %__MODULE__{
             raw: raw,
             json: json,
             os: json["os"],
             architecture: json["architecture"],
             user: inner["User"],
             working_dir: inner["WorkingDir"],
             entrypoint: inner["Entrypoint"],
             cmd: inner["Cmd"],
             env: inner["Env"],
             labels: inner["Labels"],
             history: json["history"],
             rootfs_diff_ids: diff_ids
           }}
        end

      _ ->
        {:error, {:bad_input, "config is not a JSON object"}}
    end
  end

  @spec parse_diff_ids([String.t()]) :: {:ok, [Digest.t()]} | {:error, {:bad_input, term()}}
  defp parse_diff_ids(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case Digest.parse(id) do
        {:ok, digest} -> {:cont, {:ok, [digest | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defimpl Inspect do
    def inspect(%Stevedore.Config{} = c, _opts) do
      "#Stevedore.Config<#{platform(c)}#{plural(length(c.rootfs_diff_ids), "layer")}>"
    end

    defp platform(%Stevedore.Config{os: nil, architecture: nil}), do: ""

    defp platform(%Stevedore.Config{os: os, architecture: arch}),
      do: "#{os || "?"}/#{arch || "?"}, "

    defp plural(1, noun), do: "1 #{noun}"
    defp plural(n, noun), do: "#{n} #{noun}s"
  end
end
