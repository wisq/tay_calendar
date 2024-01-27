defmodule TayCalendar.OffPeakChargerTest do
  use ExUnit.Case, async: true

  alias TayCalendar.OffPeakCharger
  alias TayCalendar.Porsche

  alias PorscheConnEx.Struct.Emobility

  alias TayCalendar.Test.DataFactory
  alias TayCalendar.Test.DataFactory.Time, as: TimeFactory

  @vin "JN3MS37A9PW202929"
  @model "XX"

  test "sets profile to off-peak charge target when in off-peak hours and below target" do
    charging_profiles = DataFactory.charging_profiles()
    selected_profile = Enum.random(charging_profiles)

    off_peak_charge = Enum.random(70..100) |> DataFactory.round_to(5)
    on_peak_charge = Enum.random(10..40) |> DataFactory.round_to(5)
    current_charge = Enum.random(41..69)

    {:ok, pid} =
      OffPeakCharger.start_link(
        config: %{
          enabled: true,
          session: {:mock, self()},
          vin: @vin,
          model: @model,
          profile_name: selected_profile.name,
          minimum_charge_off_peak: off_peak_charge,
          minimum_charge_on_peak: on_peak_charge,
          off_peak_hours: [every_day: :all_day],
          timezone: TimeFactory.random_timezone()
        }
      )

    OffPeakCharger.put_emobility(pid, %Emobility{
      charging: %Emobility.ChargeStatus{
        percent: current_charge
      },
      charging_profiles: charging_profiles
    })

    assert_receive {Porsche, :put_charging_profile, pid, ref, {@vin, @model, profile}}, 300
    send(pid, {Porsche, ref, {:ok, true}})

    assert profile.id == selected_profile.id
    assert profile.charging.minimum_charge == off_peak_charge
  end

  test "sets profile to on-peak charge target when not in off-peak hours" do
    charging_profiles = DataFactory.charging_profiles()
    selected_profile = Enum.random(charging_profiles)
    current_target = selected_profile.charging.minimum_charge

    off_peak_charge = Enum.random(70..100) |> DataFactory.round_to(5)
    on_peak_charge = Enum.random(10..40) |> DataFactory.round_to(5) |> avoid(current_target)
    current_charge = Enum.random(41..69)

    {:ok, pid} =
      OffPeakCharger.start_link(
        config: %{
          enabled: true,
          session: {:mock, self()},
          vin: @vin,
          model: @model,
          profile_name: selected_profile.name,
          minimum_charge_off_peak: off_peak_charge,
          minimum_charge_on_peak: on_peak_charge,
          off_peak_hours: [],
          timezone: TimeFactory.random_timezone()
        }
      )

    OffPeakCharger.put_emobility(pid, %Emobility{
      charging: %Emobility.ChargeStatus{
        percent: current_charge
      },
      charging_profiles: charging_profiles
    })

    assert_receive {Porsche, :put_charging_profile, pid, ref, {@vin, @model, profile}}, 300
    send(pid, {Porsche, ref, {:ok, true}})

    assert profile.id == selected_profile.id
    assert profile.charging.minimum_charge == on_peak_charge
  end

  test "sets profile to on-peak charge target when at or above off-peak charge target" do
    charging_profiles = DataFactory.charging_profiles()
    selected_profile = Enum.random(charging_profiles)
    current_target = selected_profile.charging.minimum_charge

    off_peak_charge = Enum.random(70..100) |> DataFactory.round_to(5)
    on_peak_charge = Enum.random(10..40) |> DataFactory.round_to(5) |> avoid(current_target)
    current_charge = off_peak_charge + Enum.random(0..1)

    {:ok, pid} =
      OffPeakCharger.start_link(
        config: %{
          enabled: true,
          session: {:mock, self()},
          vin: @vin,
          model: @model,
          profile_name: selected_profile.name,
          minimum_charge_off_peak: off_peak_charge,
          minimum_charge_on_peak: on_peak_charge,
          off_peak_hours: [every_day: :all_day],
          timezone: TimeFactory.random_timezone()
        }
      )

    OffPeakCharger.put_emobility(pid, %Emobility{
      charging: %Emobility.ChargeStatus{
        percent: current_charge
      },
      charging_profiles: charging_profiles
    })

    assert_receive {Porsche, :put_charging_profile, pid, ref, {@vin, @model, profile}}, 300
    send(pid, {Porsche, ref, {:ok, true}})

    assert profile.id == selected_profile.id
    assert profile.charging.minimum_charge == on_peak_charge
  end

  test "leaves profile alone if already set to correct value" do
    off_peak_charge = Enum.random(70..100) |> DataFactory.round_to(5)
    on_peak_charge = Enum.random(10..40) |> DataFactory.round_to(5)

    # Pick one of the three scenarios at random:
    {hours, current_charge, target_charge} =
      case Enum.random(1..3) do
        # In hours, below off-peak target, set to off-peak target.
        1 -> {[every_day: :all_day], Enum.random(0..69), off_peak_charge}
        # In hours, above off-peak target, set to on-peak target.
        2 -> {[every_day: :all_day], Enum.random(off_peak_charge..100), on_peak_charge}
        # Outside hours, any charge value, set to on-peak target.
        3 -> {[], Enum.random(0..100), on_peak_charge}
      end

    selected_profile = DataFactory.charging_profile(charging: [minimum_charge: target_charge])

    {:ok, pid} =
      OffPeakCharger.start_link(
        config: %{
          enabled: true,
          session: {:mock, self()},
          vin: @vin,
          model: @model,
          profile_name: selected_profile.name,
          minimum_charge_off_peak: off_peak_charge,
          minimum_charge_on_peak: on_peak_charge,
          off_peak_hours: hours,
          timezone: TimeFactory.random_timezone()
        }
      )

    OffPeakCharger.put_emobility(pid, %Emobility{
      charging: %Emobility.ChargeStatus{
        percent: current_charge
      },
      charging_profiles: [selected_profile]
    })

    refute_receive {Porsche, :put_charging_profile, _, _, _}, 300
  end

  # Avoid setting the on-peak target to the same as the current charge target.
  # This ensures we don't skip the put_charging_profile call.
  defp avoid(same, same) do
    [same - 5, same + 5]
    |> Enum.reject(fn n -> n < 0 end)
    |> Enum.random()
  end

  defp avoid(value, _avoid), do: value
end
