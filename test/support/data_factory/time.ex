defmodule TayCalendar.Test.DataFactory.Time do
  @timezones [
    "America/Toronto",
    "America/Vancouver",
    "America/Regina",
    "Europe/Berlin",
    "Europe/London",
    "Asia/Tokyo",
    "Australia/Sydney"
  ]

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

  def now(tz \\ random_timezone()) do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> Timex.Timezone.convert(tz)
  end

  def generate_time_pair(timing, tz \\ random_timezone())

  def generate_time_pair(:past, tz) do
    before_now = @timing_minimum..@one_week |> Enum.random()
    duration = 1..@one_day |> Enum.random()

    end_time = now(tz) |> DateTime.add(-before_now, :second)
    start_time = end_time |> DateTime.add(-duration, :second)
    {start_time, end_time}
  end

  def generate_time_pair(:future, tz) do
    after_now = @timing_minimum..@one_week |> Enum.random()
    duration = 1..@one_day |> Enum.random()

    start_time = now(tz) |> DateTime.add(after_now, :second)
    end_time = start_time |> DateTime.add(duration, :second)
    {start_time, end_time}
  end

  def generate_time_pair(:now, tz) do
    before_now = 5..div(@one_day, 2) |> Enum.random()
    after_now = 5..div(@one_day, 2) |> Enum.random()

    now = now(tz)
    start_time = now |> DateTime.add(-before_now, :second)
    end_time = now |> DateTime.add(after_now, :second)
    {start_time, end_time}
  end

  def generate_time_pair(:random, tz) do
    [:past, :future, :now]
    |> Enum.random()
    |> generate_time_pair(tz)
  end

  def random_timezone, do: @timezones |> Enum.random()
end
