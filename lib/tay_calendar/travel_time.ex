defmodule TayCalendar.TravelTime do
  require Logger
  use GenServer

  @prefix "[#{inspect(__MODULE__)}]"

  # The Google Distance Matrix API only uses arrival_time for transit, not for driving.
  #
  # To work around this, we'll start by assuming departure time = arrival time,
  # then pick a new departure time based on how long that trip will take.
  #
  # We'll try up to `@max_passes` to get this right, but we'll stop if the current pass
  # return a result that is less than `@pass_max_delta` seconds difference than
  # the previous pass.
  @max_passes 5
  @pass_max_delta 60
  # Clean cache every hour.
  @cleanup_timer 3_600_000

  defmodule Entry do
    @enforce_keys [:origin, :destination, :arrival_time, :departure_time, :fetched_at]
    defstruct(@enforce_keys)

    # Refresh travel time one hour prior to departure.
    @refresh_before_depart 3_600

    def new(params) do
      params
      |> Keyword.put(:fetched_at, DateTime.utc_now())
      |> then(&struct!(__MODULE__, &1))
    end

    def is_expired?(%Entry{arrival_time: time}, now) do
      DateTime.compare(time, now) == :lt
    end

    def needs_refresh?(%Entry{departure_time: depart, fetched_at: fetched}) do
      cutoff = depart |> DateTime.add(-@refresh_before_depart, :second)

      cond do
        DateTime.compare(fetched, cutoff) == :gt ->
          # Entry was fetched after the cutoff, meaning it's already refreshed.
          false

        DateTime.compare(DateTime.utc_now(), cutoff) == :gt ->
          # It's now after the cutoff, so we should refresh.
          true

        true ->
          # It's not the cutoff yet, so no refresh needed.
          false
      end
    end

    def refresh(%Entry{} = entry, departure_time) do
      %Entry{entry | departure_time: departure_time, fetched_at: DateTime.utc_now()}
    end
  end

  defmodule Cache do
    def new, do: %{}

    def fetch(cache, origin, destination, arrival_time) do
      Map.fetch(cache, {origin, destination, arrival_time})
    end

    def put(
          cache,
          %Entry{origin: origin, destination: destination, arrival_time: arrival_time} = entry
        ) do
      key = {origin, destination, arrival_time}
      Map.put(cache, key, entry)
    end

    def cleanup(cache) do
      now = DateTime.utc_now()

      {discard, keep} =
        cache
        |> Map.split_with(fn {_, entry} ->
          Entry.is_expired?(entry, now)
        end)

      {Enum.count(discard), keep}
    end
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, nil, opts)
  end

  def get(pid, origin, destination, %DateTime{} = arrival_time)
      when is_binary(origin) and is_binary(destination) do
    if in_past?(arrival_time) do
      {:error, :arrival_time_in_past}
    else
      GenServer.call(pid, {:get, origin, destination, arrival_time})
    end
  end

  @impl true
  def init(nil) do
    Process.send_after(self(), :cleanup, @cleanup_timer)
    {:ok, Cache.new()}
  end

  @impl true
  def handle_call({:get, origin, destination, arrival_time}, _from, cache) do
    route = fn ->
      "#{inspect(origin)} to #{inspect(destination)} at #{arrival_time}"
    end

    case Cache.fetch(cache, origin, destination, arrival_time) do
      {:ok, %Entry{} = entry} ->
        time = entry.departure_time
        Logger.debug("#{@prefix} Found departure time #{time} in cache for #{route.()}.")

        if Entry.needs_refresh?(entry) do
          Logger.info("#{@prefix} Refreshing departure time for #{route.()} ...")

          case refresh_depart_time(entry) do
            {:ok, new_entry} ->
              time1 = entry.departure_time
              time2 = new_entry.departure_time
              Logger.info("#{@prefix} Refreshed time: #{time1} => #{time2}")
              {:reply, {:ok, time2}, Cache.put(cache, entry)}

            {:error, _} = err ->
              Logger.error("#{@prefix} Error refreshing: #{inspect(err)}")
              {:reply, {:ok, entry.departure_time}, cache}
          end
        else
          {:reply, {:ok, time}, cache}
        end

      :error ->
        Logger.info("#{@prefix} Fetching departure time for #{route.()} ...")

        case get_depart_time(origin, destination, arrival_time) do
          {:ok, entry} ->
            time = entry.departure_time
            Logger.info("#{@prefix} Retrieved departure time #{time}.")
            {:reply, {:ok, time}, Cache.put(cache, entry)}

          :error ->
            {:reply, :error, cache}
        end
    end
  end

  @impl true
  def handle_info(:cleanup, cache) do
    {count, cache} = Cache.cleanup(cache)
    Logger.info("#{@prefix} Expired #{count} entries from cache.")
    Process.send_after(self(), :cleanup, @cleanup_timer)
    {:noreply, cache}
  end

  defp get_depart_time(origin, destination, arrival_time) do
    1..@max_passes
    |> Enum.reduce_while(arrival_time, fn passno, time ->
      case query(origin, destination, time) do
        {:ok, secs} ->
          new_time = arrival_time |> DateTime.add(-secs, :second)
          Logger.debug("#{@prefix} Pass ##{passno}: #{secs} seconds")

          cond do
            in_past?(new_time) ->
              Logger.warning("Departure time is in the past: #{new_time}")
              {:halt, new_time}

            time_delta(time, new_time) < @pass_max_delta ->
              {:halt, new_time}

            true ->
              {:cont, new_time}
          end

        {:error, err} ->
          Logger.error("#{@prefix} Pass ##{passno}: failed!  #{inspect(err)}")
          {:halt, :error}
      end
    end)
    |> then(fn
      %DateTime{} = departure_time ->
        {:ok,
         Entry.new(
           origin: origin,
           destination: destination,
           arrival_time: arrival_time,
           departure_time: departure_time
         )}

      :error ->
        :error
    end)
  end

  defp refresh_depart_time(%Entry{} = entry) do
    # Unlike above, we refresh using a single-pass query.
    # We already have a pretty good grasp on the departure time,
    # and we're just refining it at this point.
    case query(entry.origin, entry.destination, entry.departure_time) do
      {:ok, secs} ->
        new_time = entry.arrival_time |> DateTime.add(-secs, :second)
        {:ok, Entry.refresh(entry, new_time)}

      {:error, _} = err ->
        err
    end
  end

  defp query(origin, destination, time) do
    case GoogleMaps.distance(origin, destination, departure_time: DateTime.to_unix(time)) do
      {:ok, %{"rows" => [%{"elements" => [%{"duration_in_traffic" => %{"value" => secs}}]}]}} ->
        {:ok, secs}
    end
  end

  defp in_past?(time) do
    # Add a bit of margin to account for possible request latency.
    cutoff = DateTime.utc_now() |> DateTime.add(15, :second)
    DateTime.compare(time, cutoff) == :lt
  end

  defp time_delta(t1, t2) do
    abs(DateTime.to_unix(t1) - DateTime.to_unix(t2))
  end
end
