defmodule TayCalendar.OffPeakCharger.Hours do
  def is_off_peak?(hours, tz, now \\ DateTime.utc_now()) do
    now = now |> Timex.Timezone.convert(tz)
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
end
