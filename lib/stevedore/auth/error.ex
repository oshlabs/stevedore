defmodule Stevedore.Auth.Error do
  @moduledoc """
  A failure during registry authentication (token exchange or credential loading).
  """

  defexception [:reason, :status, :registry, :body]

  @type t :: %__MODULE__{
          reason: atom() | String.t(),
          status: non_neg_integer() | nil,
          registry: String.t() | nil,
          body: term()
        }

  @impl true
  @spec message(t()) :: String.t()
  def message(%__MODULE__{reason: reason, status: nil}),
    do: "auth error: #{format_reason(reason)}"

  def message(%__MODULE__{reason: reason, status: status, registry: registry}) do
    "auth error (#{status}) for #{registry || "registry"}: #{format_reason(reason)}"
  end

  @spec format_reason(term()) :: String.t()
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason), do: to_string(reason)
  defp format_reason(%{__exception__: true} = reason), do: Exception.message(reason)
  defp format_reason(reason), do: inspect(reason)
end
