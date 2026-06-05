defmodule Stevedore.Mutate do
  @moduledoc """
  Rewrite an assembled `Stevedore.Image` — config, annotations, tag, base, or layer set — without
  re-pulling layers where possible. Every mutation recomputes the dependent digests through
  `Stevedore.Image.assemble/3`; bytes that don't change keep their digests.

  Spec: crane `mutate`/`rebase`/`flatten` semantics
  (<https://github.com/google/go-containerregistry/tree/main/cmd/crane>) and OCI image-spec
  `config.md`/`layer.md`.
  """

  alias Stevedore.{Archive, Config, Image, Layer}

  @doc """
  Rewrites the runtime config. `changes` is a map of `:entrypoint`/`:cmd`/`:env`/`:user`/
  `:working_dir`/`:labels` (labels are merged, the rest replaced) or a `(Config.t -> Config.t)`
  function. Layers are untouched.
  """
  @spec config(Image.t(), map() | (Config.t() -> Config.t())) :: Image.t()
  def config(%Image{} = image, changes) do
    runtime = apply_changes(image.config, image.config.json["config"] || %{}, changes)
    config_json = Map.put(image.config.json, "config", runtime)
    {:ok, image} = Image.assemble(config_json, Image.layers(image), reassemble_opts(image))
    image
  end

  @doc "Merges `annotations` into the manifest's annotations. Config and layers are untouched."
  @spec annotations(Image.t(), map()) :: Image.t()
  def annotations(%Image{} = image, annotations) do
    merged = Map.merge(Image.annotations(image) || %{}, annotations)
    manifest_json = Map.put(image.manifest.json, "annotations", merged)
    raw = JSON.encode!(manifest_json)
    {:ok, manifest} = Stevedore.Manifest.parse(raw, image.manifest.media_type)
    %{image | manifest: manifest}
  end

  @doc "Sets the tag the image will be written under by a subsequent copy."
  @spec retag(Image.t(), String.t()) :: Image.t()
  def retag(%Image{} = image, tag), do: %{image | tag: tag}

  @doc """
  Rebases `image` from `old_base` onto `new_base`: the bottom layers matching `old_base` are
  swapped for `new_base`'s layers, keeping the application layers on top. Fails with
  `:base_mismatch` if `image` doesn't actually start with `old_base`'s layers.
  """
  @spec rebase(Image.t(), Image.t(), Image.t()) :: {:ok, Image.t()} | {:error, :base_mismatch}
  def rebase(%Image{} = image, %Image{} = old_base, %Image{} = new_base) do
    image_layers = Image.layers(image)
    old_layers = Image.layers(old_base)
    new_layers = Image.layers(new_base)
    n = length(old_layers)

    if diff_ids(Enum.take(image_layers, n)) == diff_ids(old_layers) do
      combined = new_layers ++ Enum.drop(image_layers, n)
      Image.assemble(image.config.json, combined, reassemble_opts(image))
    else
      {:error, :base_mismatch}
    end
  end

  @doc """
  Flattens all layers into a single layer, applying whiteouts (`.wh.<name>` deletions and
  `.wh..wh..opq` opaque dirs) so the result is the effective filesystem. The runtime config is
  preserved.
  """
  @spec flatten(Image.t(), keyword()) :: {:ok, Image.t()} | {:error, term()}
  def flatten(%Image{} = image, opts \\ []) do
    with {:ok, entries} <- Layer.merged_entries(image) do
      tar = Archive.write!(entries)

      Stevedore.Build.image([tar], image.config,
        format: Image.format(image),
        compression: Keyword.get(opts, :compression, :gzip),
        platform: [
          os: image.config.os || "linux",
          architecture: image.config.architecture || "amd64"
        ]
      )
    end
  end

  # --- config changes ---

  @spec apply_changes(Config.t(), map(), map() | function()) :: map()
  defp apply_changes(_config, runtime, changes) when is_map(changes) do
    runtime
    |> put_if("Entrypoint", changes[:entrypoint])
    |> put_if("Cmd", changes[:cmd])
    |> put_if("Env", changes[:env])
    |> put_if("User", changes[:user])
    |> put_if("WorkingDir", changes[:working_dir])
    |> merge_labels(changes[:labels])
  end

  defp apply_changes(config, _runtime, fun) when is_function(fun, 1) do
    runtime_from_config(fun.(config))
  end

  @spec runtime_from_config(Config.t()) :: map()
  defp runtime_from_config(%Config{} = config) do
    %{}
    |> put_if("Entrypoint", config.entrypoint)
    |> put_if("Cmd", config.cmd)
    |> put_if("Env", config.env)
    |> put_if("User", config.user)
    |> put_if("WorkingDir", config.working_dir)
    |> put_if("Labels", config.labels)
  end

  defp merge_labels(runtime, nil), do: runtime

  defp merge_labels(runtime, labels),
    do: Map.put(runtime, "Labels", Map.merge(runtime["Labels"] || %{}, labels))

  # --- helpers ---

  defp diff_ids(layers), do: Enum.map(layers, &to_string(&1.diff_id))

  defp reassemble_opts(image),
    do: [format: Image.format(image), annotations: Image.annotations(image)]

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
