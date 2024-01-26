defmodule TayCalendar.Stats do
  use GenServer
  require Logger

  @prefix "taycal"

  alias PorscheConnEx.Struct.Emobility
  alias PorscheConnEx.Struct.Emobility.ChargeStatus
  alias PorscheConnEx.Struct.Emobility.DirectClimate

  def start_link(opts) do
    GenServer.start_link(__MODULE__, nil, opts)
  end

  def put_emobility(pid, %Emobility{} = emob) do
    GenServer.cast(pid, {:emobility, emob})
  end

  @impl true
  def init(_) do
    {:ok, _dd_pid} = DogStatsd.start_link(%{})
  end

  @impl true
  def handle_cast({:emobility, %Emobility{} = emob}, dd_pid) do
    [
      emob.charging |> charge_stats(),
      emob.direct_climate |> climate_stats()
    ]
    |> Enum.reduce(&Map.merge/2)
    |> record_stats(dd_pid)

    {:noreply, dd_pid}
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

  defp record_stats(map, dd_pid) do
    DogStatsd.batch(dd_pid, fn batch ->
      map
      |> Enum.reject(fn {_, value} -> is_nil(value) end)
      |> Enum.each(fn {key, value} ->
        batch.gauge(dd_pid, "#{@prefix}.#{key}", value)
      end)
    end)
  end
end
