defmodule TayCalendar.OffPeakCharger do
  require Logger
  use GenServer

  alias TayCalendar.OffPeakCharger.Hours

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

        Hours.is_off_peak?(config.off_peak_hours, config.timezone) ->
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
