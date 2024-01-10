defmodule TayCalendar.Stats do
  require Logger

  @prefix "taycal"

  def child_spec(opts) do
    opts = Keyword.put(opts, :name, __MODULE__)
    %{id: __MODULE__, start: {DogStatsd, :start_link, [%{}, opts]}}
  end

  def put_emobility(json) do
    [
      json |> Map.fetch!("batteryChargeStatus") |> battery_stats(),
      json |> Map.fetch!("directClimatisation") |> climate_stats()
    ]
    |> Enum.reduce(&Map.merge/2)
    |> record_stats()
  end

  defp battery_stats(%{
         "stateOfChargeInPercentage" => charge_percent,
         "chargingMode" => charge_mode,
         "chargingPower" => charge_rate,
         "remainingERange" => %{"valueInKilometers" => range_km},
         "remainingChargeTimeUntil100PercentInMinutes" => charge_full_mins
       }) do
    %{
      "battery.charge.percent" => charge_percent,
      "battery.charge.rate" => if(charge_mode == "OFF", do: nil, else: charge_rate),
      "battery.charge.full.minutes" => charge_full_mins,
      "battery.range.km" => range_km
    }
  end

  defp climate_stats(%{"remainingClimatisationTime" => mins}) do
    %{"climate.minutes.left" => mins}
  end

  defp record_stats(map) do
    DogStatsd.batch(__MODULE__, fn batch ->
      map
      |> Enum.reject(fn {_, value} -> is_nil(value) end)
      |> Enum.each(fn {key, value} ->
        batch.gauge(__MODULE__, "#{@prefix}.#{key}", value)
      end)
    end)
  end
end
