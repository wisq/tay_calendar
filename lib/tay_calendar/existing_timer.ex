defmodule TayCalendar.ExistingTimer do
  alias __MODULE__

  @enforce_keys [:id, :active, :time, :repeating, :weekdays, :climate_enabled, :charging_enabled]
  defstruct(@enforce_keys)

  @iso_weekdays ~w{MONDAY TUESDAY WEDNESDAY THURSDAY FRIDAY SATURDAY SUNDAY}
                |> Enum.with_index(1)
                |> Map.new()

  def from_api(%{
        "timerID" => id,
        "active" => active,
        "departureDateTime" => time,
        "frequency" => frequency,
        "chargeOption" => charging_enabled,
        "climatised" => climate_enabled,
        "weekDays" => weekdays
      }) do
    %ExistingTimer{
      id: id |> String.to_integer(),
      active: active,
      time: time |> Timex.parse!("{ISO:Extended}") |> DateTime.to_naive(),
      repeating: repeating?(frequency),
      weekdays: to_iso_week_numbers(weekdays),
      climate_enabled: climate_enabled,
      charging_enabled: charging_enabled
    }
  end

  def to_api(%ExistingTimer{} = timer) do
    %{
      "timerID" => timer.id |> Integer.to_string(),
      "active" => timer.active,
      "departureDateTime" => timer.time |> Timex.format!("{ISO:Extended:Z}"),
      "chargeOption" => timer.charging_enabled,
      "climatised" => timer.climate_enabled
    }
    |> put_api_frequency(timer)
  end

  defp repeating?("SINGLE"), do: false
  defp repeating?("CYCLIC"), do: true

  defp put_api_frequency(json, %ExistingTimer{repeating: false}) do
    json
    |> Map.merge(%{
      "frequency" => "SINGLE",
      "weekDays" => nil
    })
  end

  defp put_api_frequency(json, %ExistingTimer{repeating: true, weekdays: weekdays}) do
    json
    |> Map.merge(%{
      "frequency" => "SINGLE",
      "weekDays" =>
        @iso_weekdays
        |> Map.new(fn {name, number} ->
          {name, number in weekdays}
        end)
    })
  end

  defp to_iso_week_numbers(nil), do: nil

  defp to_iso_week_numbers(weekdays_map) do
    weekdays_map
    |> Enum.filter(fn {_, v} -> v == true end)
    |> Enum.map(fn {k, _} -> Map.fetch!(@iso_weekdays, k) end)
    |> Enum.sort()
  end

  def will_occur_at?(%ExistingTimer{repeating: false, time: ex_time}, %NaiveDateTime{} = at_time) do
    NaiveDateTime.truncate(ex_time, :second) == NaiveDateTime.truncate(at_time, :second)
  end

  def will_occur_at?(
        %ExistingTimer{repeating: true, time: ex_time, weekdays: days},
        %NaiveDateTime{} = at_time
      ) do
    NaiveDateTime.to_time(ex_time) == NaiveDateTime.to_time(at_time) &&
      (NaiveDateTime.to_date(at_time) |> Date.day_of_week()) in days
  end
end
