defmodule TayCalendar.Test.DataFactory.Google do
  alias TayCalendar.Google.{Calendar, Event}
  alias TayCalendar.Test.DataFactory.Time, as: TimeFactory

  @calendar_id_template "c_########@group.calendar.google.com"
  @event_id_template "_########"
  @hex [?0..?9, ?a..?f] |> Enum.flat_map(&Enum.to_list/1)
  @alphabet ?a..?z

  def calendar(attrs \\ []) do
    %Calendar{
      id: generate_calendar_id(),
      name: generate_name(),
      description: generate_description()
    }
    |> struct!(attrs)
  end

  def event(attrs \\ []) do
    {timing, attrs} = Keyword.pop(attrs, :timing, :future)
    {start_time, end_time} = TimeFactory.generate_time_pair(timing)

    %Event{
      id: generate_event_id(),
      name: generate_name(),
      location: maybe(&generate_location/0),
      description: maybe(&generate_description/0),
      start_time: start_time,
      end_time: end_time
    }
    |> struct!(attrs)
  end

  defp maybe(fun, default \\ nil, chance \\ 0.5) do
    if :rand.uniform() <= chance do
      fun.()
    else
      default
    end
  end

  defp generate_calendar_id do
    @calendar_id_template |> String.replace("#", fn _ -> Enum.random(@hex) end)
  end

  defp generate_event_id do
    @event_id_template |> String.replace("#", fn _ -> Enum.random(@hex) end)
  end

  defp generate_name, do: Enum.random(10..20) |> generate_alpha()
  defp generate_description, do: Enum.random(20..40) |> generate_alpha()
  def generate_location, do: Enum.random(20..30) |> generate_alpha()

  defp generate_alpha(length) do
    1..length
    |> Enum.map(fn _ -> Enum.random(@alphabet) end)
    |> String.Chars.to_string()
  end
end
