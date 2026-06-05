defmodule Stevedore.Verify.Error do
  @moduledoc "A failure while verifying image signatures against a policy."

  defexception [:reason]

  @type t :: %__MODULE__{reason: atom() | String.t()}

  @impl true
  @spec message(t()) :: String.t()
  def message(%__MODULE__{reason: :no_valid_signature}),
    do: "verify error: no signature satisfied the policy"

  def message(%__MODULE__{reason: reason}) when is_binary(reason), do: "verify error: #{reason}"
  def message(%__MODULE__{reason: reason}), do: "verify error: #{inspect(reason)}"
end
