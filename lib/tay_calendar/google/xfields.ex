defmodule TayCalendar.Google.XFields do
  defmodule Block do
    @enforce_keys [:name, :contents]
    defstruct(@enforce_keys)
  end

  defmodule Property do
    @enforce_keys [:name, :value, :attributes]
    defstruct(@enforce_keys)
  end

  def parse(ical) do
    ical
    |> String.trim()
    |> String.split(~r/\n(?! )/)
    |> Enum.map(&unescape_line/1)
    |> parse_lines()
  end

  def most_recent_event([%Block{name: "VCALENDAR", contents: events}]) do
    events
    |> Enum.filter(fn
      %Block{name: "VEVENT"} -> true
      _ -> false
    end)
    |> Enum.max_by(fn event ->
      case event.contents |> Enum.find(fn %{name: n} -> n == "LAST-MODIFIED" end) do
        %{value: v} -> v
        _ -> raise "no LAST-MODIFIED found"
      end
    end)
  end

  def xfields_as_map(%Block{name: "VEVENT", contents: contents}) do
    contents
    |> Enum.map(fn
      %Property{name: "X-" <> _} = p -> {p.name, p}
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  defp unescape_line(line) do
    line
    |> String.trim()
    |> String.replace("\n ", "")
    |> String.replace("\\\\", "\\")
  end

  defp parse_lines([]), do: []

  defp parse_lines(["BEGIN:" <> name | rest]) do
    {block, rest} = Enum.split_while(rest, &(&1 != "END:#{name}"))

    block = %Block{
      name: name,
      contents: parse_lines(block)
    }

    rest =
      rest
      |> Enum.drop(1)
      |> parse_lines()

    [block | rest]
  end

  defp parse_lines([line | rest]) do
    [name_and_attrs, value] = String.split(line, ":", parts: 2)
    [name | attr_strs] = String.split(name_and_attrs, ";")

    attr_pairs =
      attr_strs
      |> Enum.map(fn attr ->
        [key, value] = String.split(attr, "=", parts: 2)
        {key, value}
      end)

    prop = %Property{
      name: name,
      attributes: attr_pairs,
      value: value
    }

    [prop | parse_lines(rest)]
  end
end
