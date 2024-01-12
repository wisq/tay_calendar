defmodule TayCalendar.Test.DataFactory.Google do
  alias TayCalendar.Google.{Calendar, Event}

  @calendar_id_template "c_########@group.calendar.google.com"
  @event_id_template "_########"
  @hex [?0..?9, ?a..?f] |> Enum.flat_map(&Enum.to_list/1)
  @alphabet ?a..?z

  @one_day 86400
  @one_week 7 * @one_day

  # Future events should be at least 2 hours in the future,
  # and past events should be at least 2 hours in the past.
  #
  # This is because many tests use random "before" and "after" offsets that may
  # be up to 2 hours, and we don't want timers that should be omitted (because
  # they're in the past) to be included, or vice versa.
  @timing_minimum 7201

  @timezones [
    "America/Toronto",
    "America/Vancouver",
    "America/Regina",
    "Europe/Berlin",
    "Europe/London",
    "Asia/Tokyo",
    "Australia/Sydney"
  ]

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
    {start_time, end_time} = generate_time_pair(timing)

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

  defp generate_time_pair(timing, tz \\ random_timezone())

  defp generate_time_pair(:past, tz) do
    before_now = @timing_minimum..@one_week |> Enum.random()
    duration = 1..@one_day |> Enum.random()

    now = DateTime.utc_now() |> Timex.Timezone.convert(tz)
    end_time = now |> DateTime.add(-before_now, :second)
    start_time = end_time |> DateTime.add(-duration, :second)
    {start_time, end_time}
  end

  defp generate_time_pair(:future, tz) do
    after_now = @timing_minimum..@one_week |> Enum.random()
    duration = 1..@one_day |> Enum.random()

    now = DateTime.utc_now() |> Timex.Timezone.convert(tz)
    start_time = now |> DateTime.add(after_now, :second)
    end_time = start_time |> DateTime.add(duration, :second)
    {start_time, end_time}
  end

  defp generate_time_pair(:now, tz) do
    before_now = 5..div(@one_day, 2) |> Enum.random()
    after_now = 5..div(@one_day, 2) |> Enum.random()

    now = DateTime.utc_now() |> Timex.Timezone.convert(tz)
    start_time = now |> DateTime.add(-before_now, :second)
    end_time = now |> DateTime.add(after_now, :second)
    {start_time, end_time}
  end

  defp generate_time_pair(:random, tz) do
    [:past, :future, :now]
    |> Enum.random()
    |> generate_time_pair(tz)
  end

  defp random_timezone, do: @timezones |> Enum.random()
end
