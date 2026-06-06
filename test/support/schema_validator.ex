defmodule Stevedore.SchemaValidator do
  @moduledoc """
  Validate JSON documents Stevedore emits against the **authoritative** OCI image-spec JSON
  Schemas, vendored under `test/support/schema/` (see that dir's `SOURCE` for the pinned commit).

  Used by `Stevedore.SchemaValidityTest` (Step 9B) to prove that manifests, indexes, configs, and
  descriptors we serialize satisfy the spec's required-fields/type/constant rules — not just our
  own round-trip parsers.

  The OCI schemas are draft-04 and `$ref` each other across files by bare filename
  (`content-descriptor.json`, `defs-descriptor.json`, `defs.json`). `ex_json_schema` resolves a
  cross-file `$ref` by merging it against the referencing schema's `id` URL, then calling a global
  remote-schema resolver with the merged URL. `resolve_remote/1` maps that URL back to a vendored
  file by basename, so the whole graph resolves offline with no network and no edits to the
  upstream schema bytes.

  Validator: [ex_json_schema](https://hexdocs.pm/ex_json_schema) (`only: :test`). Kept out of the
  library's runtime to preserve the weightless-by-default invariant (AGENTS.md).
  """

  alias ExJsonSchema.{Schema, Validator}

  # Embed the vendored schema bytes at compile time, keyed by basename, so validation never
  # depends on the current working directory. Recompile if the vendored files change.
  @schema_dir Path.expand("schema", __DIR__)
  @schema_paths Path.wildcard(Path.join(@schema_dir, "*.json"))
  for path <- @schema_paths, do: @external_resource(path)

  @schemas (for path <- @schema_paths, into: %{} do
              {Path.basename(path), File.read!(path)}
            end)

  @doc """
  Validates `document` (a decoded JSON map) against the vendored schema file named `schema_file`
  (e.g. `"image-manifest-schema.json"`). Returns `:ok` or `{:error, errors}` where `errors` is a
  list of `{message, path}` tuples from `ExJsonSchema.Validator`.
  """
  @spec validate(String.t(), map()) :: :ok | {:error, [{String.t(), String.t()}]}
  def validate(schema_file, document) when is_binary(schema_file) and is_map(document) do
    ensure_resolver()
    Validator.validate(root(schema_file), document)
  end

  @doc "Convenience boolean form of `validate/2`."
  @spec valid?(String.t(), map()) :: boolean()
  def valid?(schema_file, document), do: validate(schema_file, document) == :ok

  @doc """
  Resolver invoked by `ex_json_schema` for cross-file `$ref`s. Maps the merged ref URL back to a
  vendored schema by basename. Public only because the library configures it as the global
  `:remote_schema_resolver`.
  """
  @spec resolve_remote(String.t()) :: map()
  def resolve_remote(url) do
    url |> URI.parse() |> Map.fetch!(:path) |> Path.basename() |> decode()
  end

  # Resolve each root schema once and cache the resolved form across the suite.
  @spec root(String.t()) :: Schema.Root.t()
  defp root(schema_file) do
    key = {__MODULE__, schema_file}

    case :persistent_term.get(key, nil) do
      nil ->
        resolved = schema_file |> decode() |> Schema.resolve()
        :persistent_term.put(key, resolved)
        resolved

      resolved ->
        resolved
    end
  end

  @spec decode(String.t()) :: map()
  defp decode(basename), do: JSON.decode!(Map.fetch!(@schemas, basename))

  # ex_json_schema reads the resolver from application env before resolving remote $refs; set it
  # idempotently so the validator is self-contained and order-independent.
  @spec ensure_resolver() :: :ok
  defp ensure_resolver do
    Application.put_env(:ex_json_schema, :remote_schema_resolver, &__MODULE__.resolve_remote/1)
  end
end
