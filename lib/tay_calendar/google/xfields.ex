defmodule TayCalendar.Google.XFields do
  defmodule Property do
    @enforce_keys [:name, :attributes, :value]
    defstruct(@enforce_keys)
  end

  def parse(ical) do
    ical
    |> String.trim()
    |> String.replace("\r\n", "\n")
    |> String.split(~r/\n(?! )/)
    |> Enum.map(&parse_line/1)
  end

  def as_map(lines) do
    lines
    |> Enum.filter(fn
      %Property{} -> true
      _ -> false
    end)
    |> Map.new(fn %Property{name: name} = prop -> {name, prop} end)
  end

  defp parse_line("X-" <> _ = line) do
    [name_and_attrs, value] = String.split(line, ":", parts: 2)
    [name | attr_strs] = String.split(name_and_attrs, ";")

    attr_pairs =
      attr_strs
      |> Enum.map(fn attr ->
        [key, value] = String.split(attr, "=", parts: 2)
        {key, value}
      end)

    %Property{
      name: name,
      attributes: attr_pairs,
      value: value
    }
  end

  defp parse_line(line), do: line
end
