defmodule TayCalendar.Secrets do
  def fetch!(key) do
    case fetch(key) do
      {:ok, value} -> value
      :error -> raise "Must set #{key} in environment, or create .secrets/#{key}"
    end
  end

  def get(key, default \\ nil) do
    case fetch(key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  def fetch(key) do
    [
      &fetch_from_env/1,
      &fetch_from_secrets_dir/1
    ]
    |> Enum.find_value(:error, fn func ->
      case func.(key) do
        {:ok, value} -> {:ok, value}
        _ -> false
      end
    end)
  end

  defp fetch_from_env(key), do: System.fetch_env(key)

  defp fetch_from_secrets_dir(key) do
    case File.read(".secrets/#{key}") do
      {:ok, text} -> {:ok, text |> String.trim()}
      {:error, :enoent} -> :error
    end
  end
end
