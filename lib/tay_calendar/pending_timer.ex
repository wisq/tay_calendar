defmodule TayCalendar.PendingTimer do
  alias __MODULE__
  alias PorscheConnEx.Struct.Emobility.Timer
  alias TayCalendar.TimerUtils

  @enforce_keys [:time, :event]
  defstruct(
    time: nil,
    event: nil,
    charge: nil
  )

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

  def is_covered_by?(%PendingTimer{} = pending, %Timer{} = existing) do
    existing |> TimerUtils.will_occur_at?(pending.time |> to_existing_time()) &&
      existing.enabled? && existing.climate?
  end

  def to_existing(%PendingTimer{} = timer, id) do
    %Timer{
      id: id,
      enabled?: true,
      depart_time: timer.time |> to_existing_time(),
      repeating?: false,
      charge?: !is_nil(timer.charge),
      climate?: true,
      target_charge: timer.charge
    }
  end

  def to_existing_time(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> round_to_minute()
    |> DateTime.to_naive()
  end

  defp round_to_minute(%DateTime{} = dt) do
    seconds = dt |> DateTime.to_unix() |> rem(60)

    if seconds <= 30 do
      dt |> DateTime.add(-seconds, :second)
    else
      dt |> DateTime.add(60 - seconds, :second)
    end
  end
end
