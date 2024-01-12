defmodule TayCalendar.TravelTime do
  require Logger
  use GenServer

  @prefix "[#{inspect(__MODULE__)}]"

  # Refresh travel time one hour prior to departure.
  # @refresh_before_depart 3_600
  # Clean cache every hour.
  @cleanup_timer 3_600_000

  defmodule Entry do
    @enforce_keys [:origin, :destination, :arrival_time, :departure_time, :fetched_at]
    defstruct(@enforce_keys)

    def new(params) do
      params
      |> Keyword.put(:fetched_at, DateTime.utc_now())
      |> then(&struct!(__MODULE__, &1))
    end

    def is_expired?(%Entry{arrival_time: time}, now) do
      DateTime.compare(time, now) == :lt
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
        Logger.info("#{@prefix} Found departure time #{time} in cache for #{route.()}.")
        {:reply, {:ok, time}, cache}

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
    # The Google Distance Matrix API only uses arrival_time for transit, not for driving.
    #
    # To work around this, we'll start by assuming departure time = arrival time,
    # then pick a new departure time based on how long that trip will take.
    #
    # We'll try three times, by which time the departure time should be pretty stable.
    1..3
    |> Enum.reduce_while(arrival_time, fn passno, time ->
      case query(origin, destination, time) do
        {:ok, secs} ->
          new_time = arrival_time |> DateTime.add(-secs, :second)
          Logger.debug("#{@prefix} Pass ##{passno}: #{secs} seconds")

          if in_past?(new_time) do
            Logger.warning("Departure time is in the past: #{new_time}")
            {:halt, new_time}
          else
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
end
