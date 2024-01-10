defmodule TayCalendar.PendingTimer do
  alias __MODULE__
  alias TayCalendar.ExistingTimer

  @enforce_keys [:time, :event]
  defstruct(@enforce_keys)

  def unix_time(%PendingTimer{time: time}) do
    time |> DateTime.to_unix()
  end

  def past?(%PendingTimer{time: then}, now \\ DateTime.utc_now()) do
    case DateTime.compare(then, now) do
      :lt -> true
      :eq -> false
      :gt -> false
    end
  end

  def is_covered_by?(%PendingTimer{} = pending, %ExistingTimer{} = existing) do
    existing |> ExistingTimer.will_occur_at?(pending.time |> DateTime.to_naive()) &&
      existing.active && existing.climate_enabled
  end

  def to_existing(%PendingTimer{} = pending, id) do
    %ExistingTimer{
      id: id,
      active: true,
      time: pending.time |> DateTime.to_naive(),
      repeating: false,
      weekdays: nil,
      climate_enabled: true,
      charging_enabled: false,
      charge_target: 85
    }
  end
end
