defmodule Stevedore.Transport.Memory do
  @moduledoc """
  A read-only `Stevedore.Transport` backed by an in-memory `Stevedore.Image`
  or `Stevedore.Index`.

  Lets a freshly built or mutated image (or a multi-arch index) be a
  `Stevedore.copy/3` *source* without first writing it anywhere. For an index,
  the top-level ref serves the index manifest and each child image's manifest
  is addressable by digest — exactly what `copy`'s index walk expects. Write
  callbacks return `{:error, :read_only}`.
  """

  @behaviour Stevedore.Transport

  alias Stevedore.{Digest, Image, Index, Transport}

  defstruct [:image, :index]

  @type t :: %__MODULE__{image: Image.t() | nil, index: Index.t() | nil}

  @doc "Wraps an image as a read-only transport."
  @spec from_image(Image.t()) :: t()
  def from_image(%Image{} = image), do: %__MODULE__{image: image}

  @doc "Wraps a multi-arch index (and its child images) as a read-only transport."
  @spec from_index(Index.t()) :: t()
  def from_index(%Index{} = index), do: %__MODULE__{index: index}

  @impl true
  @spec get_manifest(t(), Transport.ref()) ::
          {:ok, Transport.fetched()} | {:error, :not_found}
  def get_manifest(%__MODULE__{index: %Index{} = index}, %Digest{} = digest) do
    # A child of the index, addressed by digest (how copy walks an index).
    if Digest.to_string(Index.digest(index)) == Digest.to_string(digest) do
      {:ok, fetched(index.manifest)}
    else
      with {:ok, image} <- Index.image(index, digest), do: {:ok, fetched(image.manifest)}
    end
  end

  def get_manifest(%__MODULE__{index: %Index{} = index}, _ref),
    do: {:ok, fetched(index.manifest)}

  def get_manifest(%__MODULE__{image: %Image{} = image}, _ref),
    do: {:ok, fetched(image.manifest)}

  @impl true
  @spec get_blob(t(), Digest.t()) :: {:ok, binary()} | {:error, :not_found}
  def get_blob(%__MODULE__{index: %Index{images: images}}, %Digest{} = digest) do
    Enum.find_value(images, {:error, :not_found}, fn image ->
      case Image.blob(image, digest) do
        {:ok, bytes} -> {:ok, bytes}
        {:error, :not_found} -> nil
      end
    end)
  end

  def get_blob(%__MODULE__{image: %Image{} = image}, %Digest{} = digest),
    do: Image.blob(image, digest)

  @impl true
  @spec has_blob?(t(), Digest.t()) :: boolean()
  def has_blob?(%__MODULE__{} = t, %Digest{} = digest),
    do: match?({:ok, _}, get_blob(t, digest))

  @impl true
  @spec put_manifest(t(), Transport.ref(), binary(), String.t()) :: {:error, :read_only}
  def put_manifest(_t, _ref, _raw, _media_type), do: {:error, :read_only}

  @impl true
  @spec put_blob(t(), Digest.t(), iodata()) :: {:error, :read_only}
  def put_blob(_t, _digest, _data), do: {:error, :read_only}

  @impl true
  @spec list_tags(t()) :: {:ok, []}
  def list_tags(%__MODULE__{}), do: {:ok, []}

  @impl true
  @spec delete(t(), Transport.ref()) :: {:error, :read_only}
  def delete(_t, _ref), do: {:error, :read_only}

  @spec fetched(Stevedore.Manifest.t()) :: Transport.fetched()
  defp fetched(manifest) do
    %{
      media_type: manifest.media_type,
      digest: manifest.digest,
      raw: manifest.raw,
      json: manifest.json
    }
  end
end
