defmodule TayCalendar.TimerUtils do
  alias PorscheConnEx.Struct.Emobility.Timer

  @iso_weekdays ~w{Monday Tuesday Wednesday Thursday Friday Saturday Sunday}
                |> Enum.with_index(1)

  defp to_weekday_names(days) do
    @iso_weekdays
    |> Enum.filter(fn {_, index} -> index in days end)
    |> Enum.map(fn {name, _} -> name end)
  end

  def will_occur_at?(
        %Timer{repeating?: false, depart_time: ex_time},
        %NaiveDateTime{} = at_time
      ) do
    NaiveDateTime.truncate(ex_time, :second) == NaiveDateTime.truncate(at_time, :second)
  end

  def will_occur_at?(
        %Timer{repeating?: true, depart_time: ex_time, weekdays: days},
        %NaiveDateTime{} = at_time
      ) do
    NaiveDateTime.to_time(ex_time) == NaiveDateTime.to_time(at_time) &&
      (NaiveDateTime.to_date(at_time) |> Date.day_of_week()) in days
  end

  def describe(%Timer{repeating?: false} = timer) do
    {:ok, time} =
      timer.depart_time
      |> NaiveDateTime.truncate(:second)
      |> Timex.format("{ISOdate} {ISOtime}")

    "#{time} (#{describe_features(timer)})"
  end

  def describe(%Timer{repeating?: true} = timer) do
    {:ok, time} =
      timer.depart_time
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

  defp describe_features(%Timer{} = timer) do
    [
      if(timer.charge?, do: "charge to #{timer.target_charge}%", else: nil),
      if(timer.climate?, do: "climatise", else: nil)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end
end
