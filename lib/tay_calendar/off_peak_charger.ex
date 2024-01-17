defmodule TayCalendar.OffPeakCharger do
  require Logger
  use GenServer

  @prefix "[#{inspect(__MODULE__)}]"

  defmodule Config do
    @enforce_keys [
      :session,
      :vin,
      :model,
      :enabled,
      :profile_name,
      :minimum_charge_off_peak,
      :minimum_charge_on_peak,
      :off_peak_hours,
      :timezone
    ]
    defstruct(@enforce_keys)

    def new(%{enabled: true} = params) do
      struct!(__MODULE__, params)
    end

    def new(_) do
      struct(__MODULE__, %{enabled: false})
    end
  end

  def start_link(opts) do
    {config, opts} = Keyword.pop!(opts, :config)
    GenServer.start_link(__MODULE__, Config.new(config), opts)
  end

  def put_emobility(pid, json) do
    GenServer.cast(pid, {:emobility, json})
  end

  @impl true
  def init(%Config{} = config) do
    {:ok, config}
  end

  @impl true
  def handle_cast({:emobility, _}, %Config{enabled: false} = config) do
    {:noreply, config}
  end

  @impl true
  def handle_cast({:emobility, json}, %Config{} = config) do
    with {:ok, charge} <- charge_percent(json) do
      cond do
        charge >= config.minimum_charge_off_peak ->
          Logger.info("#{@prefix} Charge is #{charge}%, no charging needed.")
          config.minimum_charge_on_peak

        is_off_peak?(config) ->
          Logger.info("#{@prefix} Charge is #{charge}%, and we're in off-peak hours.")
          config.minimum_charge_off_peak

        true ->
          Logger.info("#{@prefix} Charge is #{charge}%, but we're not in off-peak hours.")
          config.minimum_charge_on_peak
      end
      |> apply_profile_minimum(json, config)
    end

    {:noreply, config}
  end

  defp charge_percent(%{"batteryChargeStatus" => %{"stateOfChargeInPercentage" => charge}}) do
    {:ok, charge}
  end

  defp is_off_peak?(%Config{off_peak_hours: hours, timezone: tz}) do
    now = DateTime.utc_now() |> Timex.Timezone.convert(tz)
    dow = Date.day_of_week(now)
    time = DateTime.to_time(now)

    hours
    |> Enum.any?(fn {day, times} ->
      day_matches?(day, dow) && within_times?(time, times)
    end)
  end

  defp day_matches?(:monday, dow), do: dow == 1
  defp day_matches?(:tuesday, dow), do: dow == 2
  defp day_matches?(:wednesday, dow), do: dow == 3
  defp day_matches?(:thursday, dow), do: dow == 4
  defp day_matches?(:friday, dow), do: dow == 5
  defp day_matches?(:saturday, dow), do: dow == 6
  defp day_matches?(:sunday, dow), do: dow == 7
  defp day_matches?(:weekdays, dow), do: dow in 1..5
  defp day_matches?(:weekends, dow), do: dow in 6..7

  defp within_times?(_, :all_day), do: true

  defp within_times?(time, {t1, t2}) do
    case Time.compare(t1, t2) do
      # If t1 < t2, then check if time is between t1 and t2.
      :lt -> Time.compare(time, t1) == :gt && Time.compare(time, t2) == :lt
      # If t1 > t2, then this is an overnight period (e.g. 6pm to 6am).
      # Check if time is before t2 (start of day), or later than t1 (end of day).
      :gt -> Time.compare(time, t2) == :lt || Time.compare(time, t1) == :gt
    end
  end

  defp apply_profile_minimum(wanted, json, config) do
    with {:ok, profile} = find_profile(json, config.profile_name) do
      %{"profileName" => name, "chargingOptions" => %{"minimumChargeLevel" => actual}} = profile

      if wanted != actual do
        Logger.info(
          "#{@prefix} Changing \"#{name}\" minimum charge from #{actual} to #{wanted} ..."
        )

        profile = put_in(profile, ["chargingOptions", "minimumChargeLevel"], wanted)

        PorscheConnEx.Client.put_profile(config.session, config.vin, config.model, profile)
        |> then(fn
          {:ok, _} -> Logger.info("#{@prefix} Profile \"#{name}\" updated.")
          err -> Logger.error("#{@prefix} Error updating profile \"#{name}\": #{inspect(err)}")
        end)
      end
    end
  end

  defp find_profile(%{"chargingProfiles" => %{"profiles" => profiles}}, name) do
    profiles
    |> Enum.find(fn %{"profileName" => n} ->
      String.downcase(n) == String.downcase(name)
    end)
    |> then(fn
      %{} = profile -> {:ok, profile}
      nil -> {:error, :profile_not_found}
    end)
  end
end
