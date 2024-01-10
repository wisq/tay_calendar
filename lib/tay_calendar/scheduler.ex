defmodule TayCalendar.Scheduler do
  require Logger
  use GenServer

  alias TayCalendar.Google
  alias TayCalendar.PendingTimer
  alias TayCalendar.TimerManager

  # Refresh calendars every hour
  @calendars_interval 3600_000
  # Refresh events every five minutes
  @events_interval 300_000
  # On failure, refresh after one minute
  @error_interval 60_000

  # Accept events that ended up to a day ago.
  # This allows us to maintain "after" timers for those events.
  @min_time_margin {-1, :day}
  # Look for events up to one week in advance.
  @max_time_margin {7, :day}

  defmodule Config do
    @enforce_keys [:goth, :timer_manager]
    defstruct(@enforce_keys)
  end

  defmodule State do
    @enforce_keys [:config]
    defstruct(
      config: nil,
      calendars: nil,
      timers: nil
    )
  end

  defmodule Parser do
    import NimbleParsec

    hours = integer(min: 1) |> string("h") |> post_traverse({:to_secs, []})
    minutes = integer(min: 1) |> string("m") |> post_traverse({:to_secs, []})
    seconds = integer(min: 1) |> string("s") |> post_traverse({:to_secs, []})
    time_unit = choice([hours, minutes, seconds])

    defparsec(
      :interval,
      time_unit
      |> repeat(
        optional(ignore(string(" ")))
        |> concat(time_unit)
      )
      |> eos()
    )

    def to_secs(rest, ["h", value], ctx, _, _), do: {rest, [value * 3600], ctx}
    def to_secs(rest, ["m", value], ctx, _, _), do: {rest, [value * 60], ctx}
    def to_secs(rest, ["s", value], ctx, _, _), do: {rest, [value], ctx}
  end

  def start_link(opts) do
    {config, opts} = Keyword.pop!(opts, :config)
    GenServer.start_link(__MODULE__, struct!(Config, config), opts)
  end

  @impl true
  def init(%Config{} = config) do
    state = %State{config: config}
    send(self(), :refresh_calendars)
    send(self(), :refresh_events)
    {:ok, state}
  end

  @impl true
  def handle_info(:refresh_calendars, state) do
    Logger.info("Refreshing calendars ...")

    case Google.Calendar.list(state.config.goth) do
      {:ok, cals} ->
        state = state |> update_calendars(cals)
        Process.send_after(self(), :refresh_calendars, @calendars_interval)
        {:noreply, state}

      {:error, err} ->
        Logger.warning("Failed to fetch calendar list: #{inspect(err)}")
        Process.send_after(self(), :refresh_calendars, @error_interval)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:refresh_events, %State{calendars: nil} = state) do
    Logger.warning("No calendar list yet, cannot fetch events.")
    Process.send_after(self(), :refresh_events, @error_interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh_events, state) do
    Logger.info("Refreshing events ...")
    now = DateTime.utc_now()

    {min_value, min_unit} = @min_time_margin
    {max_value, max_unit} = @max_time_margin

    opts = [
      singleEvents: true,
      timeMin: now |> DateTime.add(min_value, min_unit),
      timeMax: now |> DateTime.add(max_value, max_unit),
      orderBy: :startTime
    ]

    state.calendars
    |> Enum.reduce_while([], fn cal, acc ->
      case Google.Event.list(state.config.goth, cal.id, opts) do
        {:ok, events} ->
          {:cont, events ++ acc}

        {:error, err} ->
          Logger.warning("Failed to fetch events for #{inspect(cal.name)}: #{inspect(err)}")
          {:halt, :error}
      end
    end)
    |> then(fn
      events when is_list(events) ->
        Logger.info("Found #{Enum.count(events)} events.")
        state = state |> update_events(events)
        Process.send_after(self(), :refresh_events, @events_interval)
        {:noreply, state}

      :error ->
        Process.send_after(self(), :refresh_events, @error_interval)
        {:noreply, state}
    end)
  end

  defp update_calendars(state, calendars) do
    calendars = calendars |> Enum.sort_by(& &1.id)

    if calendars == state.calendars do
      Logger.info("Calendars are unchanged.")
      state
    else
      Logger.info("Using calendars: " <> describe_calendars(calendars))
      %State{state | calendars: calendars}
    end
  end

  defp update_events(state, events) do
    update_timers(state, events |> Enum.flat_map(&generate_timers/1))
  end

  defp update_timers(state, timers) do
    now = DateTime.utc_now()

    timers =
      timers
      |> Enum.sort_by(&PendingTimer.unix_time/1)
      |> Enum.drop_while(&PendingTimer.past?(&1, now))
      |> Enum.take(5)

    TimerManager.push(state.config.timer_manager, timers)

    if timers == state.timers do
      Logger.info("Timers are unchanged.")
      state
    else
      Logger.info("Upcoming timers: " <> describe_timers(timers))
      %State{state | timers: timers}
    end
  end

  defp generate_timers(%Google.Event{description: nil, name: name}) do
    Logger.debug("Event #{inspect(name)} has no description, skipping.")
    []
  end

  defp generate_timers(%Google.Event{description: desc} = event) when is_binary(desc) do
    desc
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(&handle_timer_description(&1, event))
  end

  defp handle_timer_description("#TayCalBefore: " <> arg, event) do
    with {:ok, secs} <- parse_interval(arg) do
      [
        %PendingTimer{
          event: event,
          time: event.start_time |> DateTime.add(-secs, :second)
        }
      ]
    else
      _ -> []
    end
  end

  defp handle_timer_description("#TayCalAfter: " <> arg, event) do
    with {:ok, secs} <- parse_interval(arg) do
      [
        %PendingTimer{
          event: event,
          time: event.end_time |> DateTime.add(secs, :second)
        }
      ]
    else
      _ -> []
    end
  end

  defp handle_timer_description("#TayCal" <> _ = opt, _) do
    Logger.error("Unknown directive: #{inspect(opt)}")
    []
  end

  defp handle_timer_description(_, _), do: []

  def parse_interval(str) do
    case Parser.interval(str) do
      {:ok, secs, "", _, _, _} ->
        {:ok, secs |> Enum.sum()}

      {:error, msg, rest, _, _, _} ->
        Logger.warning("Error parsing #{inspect(str)} as interval: #{msg} at #{inspect(rest)}")
        {:error, :bad_interval}
    end
  end

  defp describe_calendars([]), do: "(no calendars)"

  defp describe_calendars(calendars) do
    calendars
    |> Enum.map(fn cal ->
      "\n  - #{cal.name}: #{cal.description}"
    end)
    |> Enum.join()
  end

  defp describe_timers([]), do: "(no timers)"

  defp describe_timers(timers) do
    timers
    |> Enum.chunk_by(& &1.event.id)
    |> Enum.map(fn [%PendingTimer{event: event} | _] = chunk ->
      [
        "\n  - Event ",
        inspect(event.name),
        " ",
        describe_times(event.start_time, event.end_time)
        | describe_event_timers(chunk)
      ]
    end)
    |> IO.iodata_to_binary()
  end

  defp describe_event_timers(timers) do
    timers
    |> Enum.map(fn %PendingTimer{time: dt} ->
      {:ok, f} = Timex.format(dt, "{ISOdate} {ISOtime}")
      "\n    - timer at #{f}"
    end)
  end

  defp describe_times(dt1, dt2) do
    {:ok, date1} = Timex.format(dt1, "{ISOdate}")
    {:ok, date2} = Timex.format(dt2, "{ISOdate}")
    {:ok, time1} = Timex.format(dt1, "{ISOtime}")
    {:ok, time2} = Timex.format(dt2, "{ISOtime}")
    {:ok, zone1} = Timex.format(dt1, "{Zabbr}")
    {:ok, zone2} = Timex.format(dt2, "{Zabbr}")

    cond do
      date1 != date2 ->
        "from #{date1} #{time1} #{zone1} to #{date2} #{time2} #{zone2}"

      zone1 != zone2 ->
        "#{date1} from #{time1} #{zone1} to #{time2} #{zone2}"

      true ->
        "#{date1} from #{time1} to #{time2} #{zone2}"
    end
  end
end
