defmodule SymphonyElixir.Dotenv do
  @moduledoc """
  Minimal .env file loader. Reads KEY=VALUE pairs from a file and sets them
  as system environment variables. Existing env vars take precedence — a
  variable already set in the environment is never overwritten.

  Supports:
  - Blank lines and `#` comments
  - Unquoted, single-quoted, and double-quoted values
  - `export KEY=VALUE` prefix (ignored)
  - Inline comments after unquoted values
  """

  @spec load(Path.t()) :: :ok | {:error, :enoent}
  def load(path) do
    path = Path.expand(path)

    if File.regular?(path) do
      path
      |> File.read!()
      |> String.split("\n")
      |> Enum.each(&parse_and_set/1)

      :ok
    else
      {:error, :enoent}
    end
  end

  @spec load_from_workflow_dir(Path.t()) :: :ok
  def load_from_workflow_dir(workflow_path) do
    dir = Path.dirname(Path.expand(workflow_path))
    load(Path.join(dir, ".env"))
    :ok
  end

  defp parse_and_set(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" -> :ok
      String.starts_with?(trimmed, "#") -> :ok
      true -> do_parse(trimmed)
    end
  end

  defp do_parse(line) do
    # Strip optional "export " prefix
    line = strip_export(line)

    case String.split(line, "=", parts: 2) do
      [key, raw_value] ->
        key = String.trim(key)
        value = parse_value(raw_value)

        if key != "" and is_nil(System.get_env(key)) do
          System.put_env(key, value)
        end

      _ ->
        :ok
    end
  end

  defp strip_export("export " <> rest), do: rest
  defp strip_export(line), do: line

  defp parse_value(raw) do
    trimmed = String.trim(raw)

    cond do
      String.starts_with?(trimmed, "\"") -> extract_quoted(trimmed, "\"")
      String.starts_with?(trimmed, "'") -> extract_quoted(trimmed, "'")
      true -> strip_inline_comment(trimmed)
    end
  end

  defp extract_quoted(trimmed, quote_char) do
    inner = String.slice(trimmed, 1..-1//1)

    case String.split(inner, quote_char, parts: 2) do
      [content, _] -> content
      [content] -> content
    end
  end

  defp strip_inline_comment(value) do
    value
    |> String.split(~r/\s+#/, parts: 2)
    |> List.first()
    |> String.trim()
  end
end
