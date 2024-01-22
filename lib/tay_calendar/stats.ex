defmodule TayCalendar.Stats do
  require Logger

  @prefix "taycal"

  def child_spec(opts) do
    opts = Keyword.put(opts, :name, __MODULE__)
    %{id: __MODULE__, start: {DogStatsd, :start_link, [%{}, opts]}}
  end

  def put_emobility(%{no_stats: true}), do: :noop

  def put_emobility(json) do
    [
      json |> Map.fetch!("batteryChargeStatus") |> battery_stats(),
      json |> Map.fetch!("directClimatisation") |> climate_stats(),
      json |> try_parse_emobility()
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
      "battery.charge.rate" => if(charge_mode == "OFF", do: 0, else: charge_rate),
      "battery.charge.full.minutes" => charge_full_mins || 0,
      "battery.range.km" => range_km
    }
  end

  defp climate_stats(%{"remainingClimatisationTime" => mins}) do
    %{"climate.minutes.left" => mins || 0}
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

  defp try_parse_emobility(json) do
    case PorscheConnEx.Struct.Emobility.load(json) do
      {:ok, _} ->
        Logger.info("Emobility parsed successfully.")
        %{"emobility.parse.success" => 1}

      err ->
        timestamp = DateTime.utc_now() |> DateTime.to_unix(:microsecond)
        filename = "/tmp/taycal/#{timestamp}.exs"

        case File.write(filename, {json, err} |> inspect(pretty: true)) do
          :ok -> Logger.warning("Got error parsing emobility, logged to #{filename}.")
          {:error, e} -> Logger.error("Got #{inspect(e)} writing to #{filename}.")
        end

        %{"emobility.parse.success" => 0}
    end
  end
end
