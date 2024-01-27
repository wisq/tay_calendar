defmodule TayCalendar.OffPeakCharger.HoursTest do
  use ExUnit.Case, async: true

  alias TayCalendar.OffPeakCharger.Hours
  alias TayCalendar.Test.DataFactory.Time, as: TimeFactory

  test "peak hours with daytime peak hours" do
    hours = [
      monday: {~T[01:00:00], ~T[03:00:00]},
      tuesday: {~T[02:00:00], ~T[04:00:00]},
      wednesday: {~T[03:00:00], ~T[05:00:00]},
      thursday: {~T[04:00:00], ~T[06:00:00]},
      friday: {~T[05:00:00], ~T[07:00:00]},
      saturday: {~T[06:00:00], ~T[08:00:00]},
      sunday: {~T[07:00:00], ~T[09:00:00]},
      weekdays: {~T[16:00:00], ~T[20:00:00]},
      weekends: {~T[19:00:00], ~T[23:00:00]}
    ]

    assert hours_by_day(hours) == %{
             1 => [1, 2, 16, 17, 18, 19],
             2 => [2, 3, 16, 17, 18, 19],
             3 => [3, 4, 16, 17, 18, 19],
             4 => [4, 5, 16, 17, 18, 19],
             5 => [5, 6, 16, 17, 18, 19],
             6 => [6, 7, 19, 20, 21, 22],
             7 => [7, 8, 19, 20, 21, 22]
           }
  end

  test "peak hours with overnight peak hours" do
    hours = [
      monday: {~T[21:00:00], ~T[05:00:00]},
      friday: {~T[20:00:00], ~T[04:00:00]},
      sunday: {~T[19:00:00], ~T[03:00:00]},
      weekdays: {~T[23:00:00], ~T[02:00:00]},
      weekends: {~T[22:00:00], ~T[01:00:00]}
    ]

    assert hours_by_day(hours) == %{
             # Monday (own rule): Before 05:00 or after 21:00.
             1 => [0, 1, 2, 3, 4, 21, 22, 23],
             # Tuesday, Wednesday, Thursday (weekday rule): Before 02:00 or after 23:00.
             2 => [0, 1, 23],
             3 => [0, 1, 23],
             4 => [0, 1, 23],
             # Friday (own rule): Before 04:00 or after 20:00.
             5 => [0, 1, 2, 3, 20, 21, 22, 23],
             # Saturday (weekend rule): Before 01:00 or after 22:00.
             6 => [0, 22, 23],
             # Sunday (own rule): Before 04:00 or after 20:00.
             7 => [0, 1, 2, 19, 20, 21, 22, 23]
           }
  end

  test "peak hours with multiple rules per day" do
    hours = [
      monday: {~T[01:00:00], ~T[02:00:00]},
      monday: {~T[03:00:00], ~T[04:00:00]},
      monday: {~T[05:00:00], ~T[06:00:00]}
    ]

    assert %{
             1 => [1, 3, 5],
             2 => []
           } = hours_by_day(hours)
  end

  test "peak hours all day long" do
    hours = [
      monday: :all_day,
      weekends: :all_day
    ]

    all_hours = 0..23 |> Enum.to_list()

    assert %{
             1 => ^all_hours,
             2 => [],
             6 => ^all_hours,
             7 => ^all_hours
           } = hours_by_day(hours)
  end

  test "peak hours every day" do
    hours = [
      every_day: {~T[05:00:00], ~T[07:00:00]}
    ]

    assert %{
             1 => [5, 6],
             2 => [5, 6],
             3 => [5, 6],
             4 => [5, 6],
             5 => [5, 6],
             6 => [5, 6],
             7 => [5, 6]
           } = hours_by_day(hours)
  end

  defp hours_by_day(hours) do
    1..7
    |> Map.new(fn day ->
      {:ok, date} = Date.new(2024, 1, day)

      0..23
      |> Enum.filter(fn hour ->
        {:ok, time} = Time.new(hour, 30, 0)
        {:ok, ndt} = NaiveDateTime.new(date, time)
        Hours.is_off_peak?(hours, TimeFactory.random_timezone(), ndt)
      end)
      |> then(fn list -> {day, list} end)
    end)
  end
end
