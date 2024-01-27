defmodule TayCalendar.Test.DataFactory do
  alias PorscheConnEx.Struct.Emobility.Timer
  alias PorscheConnEx.Struct.Emobility.ChargingProfile

  @one_week 86400 * 7

  @alphanumeric [?A..?Z, ?a..?z, ?0..?9] |> Enum.flat_map(&Enum.to_list/1)

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

  def charging_profiles(count \\ Enum.random(1..5)) when count in 1..5 do
    names =
      Stream.repeatedly(&random_charging_profile_name/0)
      |> Stream.uniq()
      |> Enum.take(count)

    ids = 1..5 |> Enum.take_random(count)

    ids
    |> Enum.sort()
    |> Enum.zip(names)
    |> Enum.map(fn {id, name} ->
      charging_profile(id: id, name: name)
    end)
  end

  def charging_profile(attrs \\ []) do
    {options, attrs} = Keyword.pop(attrs, :charging, [])
    {position, attrs} = Keyword.pop(attrs, :position, [])

    %ChargingProfile{
      id: Enum.random(1..5),
      name: random_charging_profile_name(),
      active: [true, false] |> Enum.random(),
      charging: charging_profile_options(options),
      position: charging_profile_position(position)
    }
    |> struct!(attrs)
  end

  def charging_profile_options(attrs \\ []) do
    %ChargingProfile.ChargingOptions{
      minimum_charge: Enum.random(0..40) |> round_to(5),
      target_charge: 100,
      mode: [:smart, :preferred_time] |> Enum.random(),
      preferred_time_start: random_naive_minute() |> NaiveDateTime.to_time(),
      preferred_time_end: random_naive_minute() |> NaiveDateTime.to_time()
    }
    |> struct!(attrs)
  end

  def charging_profile_position(attrs \\ []) do
    %ChargingProfile.Position{
      latitude: Enum.random(-90_000_000..90_000_000) / 1_000_000,
      longitude: Enum.random(-180_000_000..180_000_000) / 1_000_000,
      radius: Enum.random(100..500) |> round_to(10)
    }
    |> struct!(attrs)
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

  def round_to(num, round), do: round(num / round) * round

  def random_charging_profile_name, do: Enum.random(5..20) |> random_alphanumeric()

  def random_alphanumeric(size) do
    1..size
    |> Enum.map(fn _ -> Enum.random(@alphanumeric) end)
    |> String.Chars.to_string()
  end
end
