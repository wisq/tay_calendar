defmodule TayCalendar.Test.DataFactory do
  alias PorscheConnEx.Struct.Emobility.Timer

  @one_week 86400 * 7

  def timer(attrs \\ []) do
    %Timer{
      id: Enum.random(1..5),
      active?: random_boolean(),
      depart_time: random_naive_minute(),
      repeating?: random_boolean(),
      climate?: random_boolean(),
      charge?: random_boolean(),
      target_charge: Enum.random(1..100) |> round_to(5)
    }
    |> struct!(attrs)
    |> set_weekdays()
  end

  defp set_weekdays(%Timer{repeating?: false, weekdays: nil} = t), do: t
  defp set_weekdays(%Timer{repeating?: true, weekdays: wd} = t) when not is_nil(wd), do: t

  defp set_weekdays(%Timer{repeating?: true, weekdays: nil} = t) do
    %Timer{t | weekdays: 1..7 |> Enum.take_random(Enum.random(1..7))}
  end

  defp random_boolean, do: [true, false] |> Enum.random()

  defp random_naive_minute do
    now = DateTime.utc_now() |> DateTime.to_unix()
    unix = now + Enum.random(1..@one_week)

    unix
    |> round_to(60)
    |> DateTime.from_unix!()
    |> DateTime.to_naive()
  end

  defp round_to(num, round), do: round(num / round) * round
end
