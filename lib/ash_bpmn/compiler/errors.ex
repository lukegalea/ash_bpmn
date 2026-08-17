# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.Compiler.Errors do
  @moduledoc false

  @spec error(String.t(), String.t()) :: map()
  def error(path, message) do
    %{path: path, message: message}
  end

  @spec format_errors([map()]) :: String.t()
  def format_errors(errors) do
    Enum.map_join(errors, "\n", fn %{path: path, message: msg} -> "  [#{path}] #{msg}" end)
  end
end
