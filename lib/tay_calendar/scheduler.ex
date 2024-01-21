defmodule TayCalendar.Scheduler do
  require Logger
  use GenServer

  alias TayCalendar.Google
  alias TayCalendar.PendingTimer
  alias TayCalendar.TimerManager
  alias TayCalendar.TravelTime

  # On failure, refresh after one minute.
  @error_interval 60_000

  # Accept events that ended up to a day ago.
  # This allows us to maintain "after" timers for those events.
  @min_time_margin {-1, :day}
  # Look for events up to one week in advance.
  @max_time_margin {7, :day}

  defmodule Config do
    @event_defaults %{
      before: "off",
      after: "off"
    }

    @enforce_keys [:goth, :timer_manager]
    defstruct(
      goth: nil,
      timer_manager: nil,
      garage: nil,
      travel_time: nil,
      calendars_interval: 3600_000,
      events_interval: 300_000,
      event_defaults: %{}
    )

    def new(params) do
      struct!(Config, params)
      |> Map.update!(:event_defaults, &Map.merge(@event_defaults, &1))
    end
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

    interval =
      times(choice([hours, minutes, seconds]), min: 1)
      |> post_traverse({:sum, []})

    defparsec(:interval, interval |> eos())

    defp to_secs(rest, ["h", value], ctx, _, _), do: {rest, [value * 3600], ctx}
    defp to_secs(rest, ["m", value], ctx, _, _), do: {rest, [value * 60], ctx}
    defp to_secs(rest, ["s", value], ctx, _, _), do: {rest, [value], ctx}

    defp sum(rest, secs, ctx, _, _), do: {rest, [Enum.sum(secs)], ctx}
  end

  def start_link(opts) do
    {config, opts} = Keyword.pop!(opts, :config)
    GenServer.start_link(__MODULE__, Config.new(config), opts)
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
        Process.send_after(self(), :refresh_calendars, state.config.calendars_interval)
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
        state = update_events(events, state)
        Process.send_after(self(), :refresh_events, state.config.events_interval)
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

  defp update_events(events, state) do
    events
    |> Enum.flat_map(fn event ->
      state.config.event_defaults
      |> Map.merge(read_config(event.description))
      |> generate_timers(event, state)
    end)
    |> update_timers(state)
  end

  defp update_timers(timers, state) do
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

  defp read_config(nil), do: %{}

  defp read_config(description) do
    description
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.flat_map(fn
      "#TayCalBefore: " <> arg ->
        [{:before, arg}]

      "#TayCalAfter: " <> arg ->
        [{:after, arg}]

      "#TayCal" <> _ = opt ->
        Logger.error("Unknown directive: #{inspect(opt)}")
        []

      _ ->
        []
    end)
    |> Map.new()
  end

  defp generate_timers(options, event, state) do
    [
      before: &generate_before_timer/3,
      after: &generate_after_timer/3
    ]
    |> Enum.flat_map(fn {label, fun} ->
      case fun.(options, event, state) do
        :disabled ->
          []

        {:ok, %PendingTimer{} = timer} ->
          [timer]

        {:error, :arrival_time_in_past} ->
          # This happens when we try to request a departure time for an
          # already-passed arrival time.  The timer will definitely be in the
          # past anyway, so we can ignore it.
          []

        {:error, err} ->
          Logger.error("Error generating #{label} timer: #{inspect(err)}")
          []
      end
    end)
  end

  defp generate_before_timer(%{before: nil}, _, _), do: :disabled
  defp generate_before_timer(%{before: "off"}, _, _), do: :disabled

  defp generate_before_timer(%{before: margin}, event, state) do
    offset_fun = fn term, time ->
      case term do
        "travel" ->
          get_departure_time(
            state.config.travel_time,
            state.config.garage,
            event.location,
            time
          )

        _ ->
          with {:ok, secs} <- parse_interval(term) do
            {:ok, time |> DateTime.add(-secs, :second)}
          end
      end
    end

    with {:ok, time} <- event.start_time |> apply_offsets(margin, offset_fun) do
      {:ok, %PendingTimer{time: time, event: event}}
    end
  end

  defp get_departure_time(_, nil, _, _) do
    {:error, "Garage not set, travel time not available."}
  end

  defp get_departure_time(_, _, nil, _) do
    {:error, "Event location not set, travel time not available."}
  end

  defp get_departure_time(pid, garage, destination, time) do
    TravelTime.get(pid, garage, destination, time)
  end

  defp generate_after_timer(%{after: nil}, _, _), do: :disabled
  defp generate_after_timer(%{after: "off"}, _, _), do: :disabled

  defp generate_after_timer(%{after: margin}, event, _state) do
    offset_fun = fn term, time ->
      with {:ok, secs} <- parse_interval(term) do
        {:ok, time |> DateTime.add(secs, :second)}
      end
    end

    with {:ok, time} <- event.end_time |> apply_offsets(margin, offset_fun) do
      {:ok, %PendingTimer{time: time, event: event}}
    end
  end

  defp apply_offsets(time, margin, offset_fun) do
    margin
    |> String.replace(~r/\s+/, "")
    |> String.split("+")
    |> Enum.reduce_while({:ok, time}, fn term, {:ok, time} ->
      case offset_fun.(term, time) do
        {:ok, %DateTime{} = new_time} -> {:cont, {:ok, new_time}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp parse_interval(str) do
    case Parser.interval(str) do
      {:ok, [secs], "", _, _, _} ->
        {:ok, secs}

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
