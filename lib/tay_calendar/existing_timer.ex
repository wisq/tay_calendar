defmodule TayCalendar.ExistingTimer do
  alias __MODULE__

  @enforce_keys [
    :id,
    :time
  ]
  defstruct(
    id: nil,
    time: nil,
    active: true,
    repeating: false,
    weekdays: nil,
    climate_enabled: true,
    charging_enabled: false,
    charge_target: 85
  )

  @iso_weekdays ~w{MONDAY TUESDAY WEDNESDAY THURSDAY FRIDAY SATURDAY SUNDAY}
                |> Enum.with_index(1)
                |> Map.new()

  def from_api(%{
        "timerID" => id,
        "active" => active,
        "departureDateTime" => time,
        "frequency" => frequency,
        "weekDays" => weekdays,
        "chargeOption" => charging_enabled,
        "climatised" => climate_enabled,
        "targetChargeLevel" => charge_target
      }) do
    %ExistingTimer{
      id: id |> String.to_integer(),
      active: active,
      time: time |> Timex.parse!("{ISO:Extended}") |> DateTime.to_naive(),
      repeating: repeating?(frequency),
      weekdays: to_iso_weekday_numbers(weekdays),
      climate_enabled: climate_enabled,
      charging_enabled: charging_enabled,
      charge_target: charge_target
    }
  end

  def to_api(%ExistingTimer{} = timer) do
    %{
      "timerID" => timer.id |> Integer.to_string(),
      "active" => timer.active,
      "departureDateTime" => timer.time |> Timex.format!("{ISO:Extended:Z}"),
      "climatised" => timer.climate_enabled,
      "chargeOption" => timer.charging_enabled,
      "targetChargeLevel" => timer.charge_target
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
      "frequency" => "CYCLIC",
      "weekDays" =>
        @iso_weekdays
        |> Map.new(fn {name, number} ->
          {name, number in weekdays}
        end)
    })
  end

  defp to_iso_weekday_numbers(nil), do: nil

  defp to_iso_weekday_numbers(weekdays_map) do
    weekdays_map
    |> Enum.filter(fn {_, v} -> v == true end)
    |> Enum.map(fn {k, _} -> Map.fetch!(@iso_weekdays, k) end)
    |> Enum.sort()
  end

  defp to_weekday_names(days) do
    @iso_weekdays
    |> Enum.filter(fn {_, index} -> index in days end)
    |> Enum.map(fn {name, _} -> String.capitalize(name) end)
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

  def describe(%ExistingTimer{repeating: false} = timer) do
    {:ok, time} =
      timer.time
      |> NaiveDateTime.truncate(:second)
      |> Timex.format("{ISOdate} {ISOtime}")

    "#{time} (#{describe_features(timer)})"
  end

  def describe(%ExistingTimer{repeating: true} = timer) do
    {:ok, time} =
      timer.time
      |> NaiveDateTime.truncate(:second)
      |> Timex.format("{ISOtime}")

    days =
      case timer.weekdays do
        [1, 2, 3, 4, 5, 6, 7] -> "every day"
        [1, 2, 3, 4, 5] -> "weekdays"
        days -> to_weekday_names(days) |> Enum.join("/")
      end

    "#{days} at #{time} (#{describe_features(timer)})"
  end

  defp describe_features(%ExistingTimer{} = timer) do
    [
      if(timer.charging_enabled, do: "charge to #{timer.charge_target}%", else: nil),
      if(timer.climate_enabled, do: "climatise", else: nil)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end
end
