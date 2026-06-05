defmodule Stevedore.Registry.Error do
  @moduledoc """
  A failure talking to a registry's Distribution v2 API.

  Carries the HTTP `status`, the `registry`/`repository` in play, and the registry's JSON error
  body (`{"errors":[...]}`) when one was returned.
  """

  defexception [:reason, :status, :registry, :repository, :body]

  @type t :: %__MODULE__{
          reason: atom() | String.t(),
          status: non_neg_integer() | nil,
          registry: String.t() | nil,
          repository: String.t() | nil,
          body: term()
        }

  @impl true
  @spec message(t()) :: String.t()
  def message(%__MODULE__{} = e) do
    target = [e.registry, e.repository] |> Enum.reject(&is_nil/1) |> Enum.join("/")
    status = if e.status, do: " (HTTP #{e.status})", else: ""
    "registry error#{status} for #{target}: #{format_reason(e.reason)}"
  end

  @spec format_reason(term()) :: String.t()
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason), do: to_string(reason)
  defp format_reason(%{__exception__: true} = reason), do: Exception.message(reason)
  defp format_reason(reason), do: inspect(reason)
end
