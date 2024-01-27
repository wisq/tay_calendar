defmodule TayCalendar.OffPeakCharger do
  require Logger
  use GenServer

  alias TayCalendar.OffPeakCharger.Hours
  alias PorscheConnEx.Struct.Emobility
  alias PorscheConnEx.Struct.Emobility.ChargingProfile
  alias PorscheConnEx.Struct.Emobility.ChargingProfile.ChargingOptions

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
  def handle_cast({:emobility, %Emobility{} = emob}, %Config{} = config) do
    charge = emob.charging.percent

    cond do
      charge >= config.minimum_charge_off_peak ->
        Logger.info("#{@prefix} Charge is #{charge}%, no charging needed.")
        config.minimum_charge_on_peak

      Hours.is_off_peak?(config.off_peak_hours, config.timezone) ->
        Logger.info("#{@prefix} Charge is #{charge}%, and we're in off-peak hours.")
        config.minimum_charge_off_peak

      true ->
        Logger.info("#{@prefix} Charge is #{charge}%, but we're not in off-peak hours.")
        config.minimum_charge_on_peak
    end
    |> apply_profile_minimum(emob, config)

    {:noreply, config}
  end

  defp apply_profile_minimum(wanted, emob, config) do
    with {:ok, %ChargingProfile{} = profile} =
           find_profile(emob.charging_profiles, config.profile_name) do
      name = profile.name
      actual = profile.charging.minimum_charge

      if wanted != actual do
        Logger.info(
          "#{@prefix} Changing \"#{name}\" minimum charge from #{actual} to #{wanted} ..."
        )

        profile = %ChargingProfile{
          profile
          | charging: %ChargingOptions{profile.charging | minimum_charge: wanted}
        }

        case PorscheConnEx.Client.put_charging_profile(
               config.session,
               config.vin,
               config.model,
               profile
             ) do
          {:ok, _} -> Logger.info("#{@prefix} Profile \"#{name}\" update queued.")
          err -> Logger.error("#{@prefix} Error updating profile \"#{name}\": #{inspect(err)}")
        end
      end
    end
  end

  defp find_profile(profiles, name) do
    match = String.downcase(name)

    profiles
    |> Enum.find(fn %{name: n} ->
      String.downcase(n) == match
    end)
    |> then(fn
      %{} = profile -> {:ok, profile}
      nil -> {:error, :profile_not_found}
    end)
  end
end
