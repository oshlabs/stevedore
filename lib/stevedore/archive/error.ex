defmodule Stevedore.Archive.Error do
  @moduledoc """
  An error raised or returned while reading or writing a tar archive.

  One error struct for the archive subsystem (per the project error conventions in `AGENTS.md`):
  context-rich failures carry a `reason` and, where useful, the byte `offset` at which parsing
  failed.
  """

  defexception [:reason, :offset]

  @type t :: %__MODULE__{reason: atom() | String.t(), offset: non_neg_integer() | nil}

  @impl true
  @spec message(t()) :: String.t()
  def message(%__MODULE__{reason: reason, offset: nil}), do: "archive error: #{reason}"

  def message(%__MODULE__{reason: reason, offset: offset}),
    do: "archive error at byte #{offset}: #{reason}"
end
