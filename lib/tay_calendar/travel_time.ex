defmodule TayCalendar.TravelTime do
  require Logger
  use GenServer

  alias TayCalendar.Google.Event
  alias TayCalendar.Google.XFields

  @prefix "[#{inspect(__MODULE__)}]"
  @server_url "https://apidata.googleusercontent.com"
  # Clean cache every hour.
  @cleanup_timer 3_600_000

  defmodule Entry do
    @enforce_keys [:etag, :start_time, :duration]
    defstruct(@enforce_keys)

    def is_expired?(%Entry{start_time: time}, now) do
      DateTime.compare(time, now) == :lt
    end
  end

  defmodule Cache do
    @prefix "[#{inspect(__MODULE__)}]"

    def new, do: %{}

    def fetch(cache, calendar_id, event_uid, etag) do
      key = cache_key(calendar_id, event_uid)

      case Map.fetch(cache, key) do
        {:ok, %Entry{etag: ^etag, duration: duration}} ->
          {:ok, duration}

        {:ok, %Entry{}} ->
          Logger.debug("#{@prefix} Etag has changed, cache entry is invalid.")
          :error

        :error ->
          :error
      end
    end

    def put(cache, calendar_id, event_uid, %Entry{} = entry) do
      key = cache_key(calendar_id, event_uid)
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

    defp cache_key(calendar_id, event_uid), do: {calendar_id, event_uid}
  end

  defmodule State do
    @enforce_keys [:goth]
    defstruct(
      goth: nil,
      cache: Cache.new()
    )
  end

  def start_link(opts) do
    {goth, opts} = Keyword.pop!(opts, :goth)
    GenServer.start_link(__MODULE__, goth, opts)
  end

  def get(pid, %Event{
        calendar_id: calendar_id,
        ical_uid: event_uid,
        etag: etag,
        start_time: start_time
      }) do
    GenServer.call(pid, {:get, calendar_id, event_uid, etag, start_time})
  end

  @impl true
  def init(goth) do
    Process.send_after(self(), :cleanup, @cleanup_timer)
    {:ok, %State{goth: goth}}
  end

  @impl true
  def handle_call({:get, calendar_id, event_uid, etag, start_time}, _from, state) do
    case Cache.fetch(state.cache, calendar_id, event_uid, etag) do
      {:ok, duration} ->
        Logger.debug(
          "#{@prefix} Found travel time #{inspect(duration)} in cache for #{event_uid}."
        )

        {:reply, {:ok, duration}, state}

      :error ->
        Logger.debug("#{@prefix} Fetching travel time for #{event_uid} ...")

        case get_travel_time(state.goth, calendar_id, event_uid) do
          {:ok, duration} ->
            Logger.info("#{@prefix} Found travel time: #{inspect(duration)}")
            entry = %Entry{duration: duration, etag: etag, start_time: start_time}
            cache = Cache.put(state.cache, calendar_id, event_uid, entry)
            {:reply, {:ok, duration}, %State{state | cache: cache}}

          {:error, _} = err ->
            {:reply, err, state}
        end
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    {count, cache} = Cache.cleanup(state.cache)
    Logger.info("#{@prefix} Expired #{count} entries from cache.")
    Process.send_after(self(), :cleanup, @cleanup_timer)
    {:noreply, %State{state | cache: cache}}
  end

  defp get_travel_time(goth, calendar_id, event_uid) do
    url = event_url(calendar_id, event_uid)

    # We ignore CalDAV's etag because it's different than the JSON API's etag.
    #
    # This is fine because, in the rare case that the event has changed
    # inbetween when the JSON API retrieves it and when we retrieve it, we'll
    # have the more up-to-date data anyway.
    #
    # The next time the scheduler refreshes, it'll pick up the new etag, ask us
    # about it, and we'll refresh the cache.  It's a needless refresh, but it
    # won't do any harm.
    with {:ok, client} <- caldav_client(goth),
         {:ok, ical, _etag} <- CalDAVClient.Event.get(client, url) do
      xfields =
        ical
        |> XFields.parse()
        |> XFields.as_map()

      case Map.fetch(xfields, "X-APPLE-TRAVEL-DURATION") do
        {:ok, %XFields.Property{value: value}} ->
          case Timex.Parse.Duration.Parsers.ISO8601Parser.parse(value) do
            {:ok, duration} ->
              {:ok, duration}

            {:error, err} ->
              Logger.error("Failed to parse duration #{inspect(value)}: #{err}")
              # Cache duration as nil, because it's not going to get better.
              {:ok, nil}
          end

        :error ->
          # Cache duration as nil, because it's not going to get better.
          {:ok, nil}
      end
    end
  end

  defp caldav_client(goth) do
    with {:ok, token} <- Goth.fetch(goth) do
      {:ok,
       %CalDAVClient.Client{
         auth: %CalDAVClient.Auth.Bearer{token: token.token},
         server_url: @server_url
       }}
    end
  end

  defp event_url(calendar_id, event_uid) do
    "#{@server_url}/caldav/v2/#{calendar_id}/events/#{event_uid}.ics"
  end
end
