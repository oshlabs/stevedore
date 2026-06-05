defmodule Stevedore.Transport.Memory do
  @moduledoc """
  A read-only `Stevedore.Transport` backed by an in-memory `Stevedore.Image`.

  Lets a freshly built or mutated image be a `Stevedore.copy/3` *source* without first writing it
  anywhere. Write callbacks return `{:error, :read_only}`.
  """

  @behaviour Stevedore.Transport

  alias Stevedore.{Digest, Image, Transport}

  @enforce_keys [:image]
  defstruct [:image]

  @type t :: %__MODULE__{image: Image.t()}

  @doc "Wraps an image as a read-only transport."
  @spec from_image(Image.t()) :: t()
  def from_image(%Image{} = image), do: %__MODULE__{image: image}

  @impl true
  @spec get_manifest(t(), Transport.ref()) :: {:ok, Transport.fetched()}
  def get_manifest(%__MODULE__{image: image}, _ref) do
    {:ok,
     %{
       media_type: image.manifest.media_type,
       digest: image.manifest.digest,
       raw: image.manifest.raw,
       json: image.manifest.json
     }}
  end

  @impl true
  @spec get_blob(t(), Digest.t()) :: {:ok, binary()} | {:error, :not_found}
  def get_blob(%__MODULE__{image: image}, %Digest{} = digest), do: Image.blob(image, digest)

  @impl true
  @spec has_blob?(t(), Digest.t()) :: boolean()
  def has_blob?(%__MODULE__{image: image}, %Digest{} = digest),
    do: match?({:ok, _}, Image.blob(image, digest))

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
end
