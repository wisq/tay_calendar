defmodule TayCalendar.Stats do
  require Logger

  @prefix "taycal"

  alias PorscheConnEx.Struct.Emobility
  alias PorscheConnEx.Struct.Emobility.ChargeStatus
  alias PorscheConnEx.Struct.Emobility.DirectClimate

  def child_spec(opts) do
    opts = Keyword.put(opts, :name, __MODULE__)
    %{id: __MODULE__, start: {DogStatsd, :start_link, [%{}, opts]}}
  end

  def put_emobility(%{no_stats: true}), do: :noop

  def put_emobility(%Emobility{} = emob) do
    [
      emob.charging |> charge_stats(),
      emob.direct_climate |> climate_stats()
    ]
    |> Enum.reduce(&Map.merge/2)
    |> record_stats()
  end

  defp charge_stats(%ChargeStatus{
         percent: percent,
         mode: mode,
         kilowatts: rate_kw,
         remaining_electric_range: %{km: range_km},
         minutes_to_full: full_mins
       }) do
    %{
      "battery.charge.percent" => percent,
      "battery.charge.rate" => if(mode == "OFF", do: 0, else: rate_kw),
      "battery.charge.full.minutes" => full_mins || 0,
      "battery.range.km" => range_km
    }
  end

  defp climate_stats(%DirectClimate{remaining_minutes: mins}) do
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
end
