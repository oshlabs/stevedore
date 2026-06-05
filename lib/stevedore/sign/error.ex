defmodule Stevedore.Sign.Error do
  @moduledoc "A failure while signing an image."

  defexception [:reason]

  @type t :: %__MODULE__{reason: atom() | String.t()}

  @impl true
  @spec message(t()) :: String.t()
  def message(%__MODULE__{reason: reason}) when is_binary(reason), do: "sign error: #{reason}"
  def message(%__MODULE__{reason: reason}), do: "sign error: #{inspect(reason)}"
end
