defmodule Stevedore.CLI do
  @moduledoc """
  Shared helpers for the `mix stevedore.*` task shells: starting the app, unwrapping verb results
  into task success/failure, and rendering errors consistently (reusing subsystem
  `Exception.message/1`).

  The tasks themselves are thin — all behavior lives in the library.
  """

  @doc "Ensures the application and its dependencies are started (for the registry tasks)."
  @spec start_app() :: :ok
  def start_app do
    Mix.Task.run("app.start")
    :ok
  end

  @doc """
  Unwraps a verb result, raising a `Mix.Error` (non-zero exit) on failure with a formatted
  message.
  """
  @spec unwrap!(:ok | {:ok, term()} | {:error, term()}) :: term()
  def unwrap!(:ok), do: :ok
  def unwrap!({:ok, value}), do: value
  def unwrap!({:error, reason}), do: Mix.raise(format_error(reason))

  @doc "Formats an error term into a one-line message."
  @spec format_error(term()) :: String.t()
  def format_error(%{__exception__: true} = error), do: Exception.message(error)
  def format_error({:bad_input, reason}), do: "invalid input: #{render(reason)}"
  def format_error(reason) when is_atom(reason), do: to_string(reason)
  def format_error(reason) when is_binary(reason), do: reason
  def format_error(reason), do: inspect(reason)

  defp render(reason) when is_binary(reason), do: reason
  defp render(reason), do: inspect(reason)
end
