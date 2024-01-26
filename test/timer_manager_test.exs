defmodule TayCalendar.TimerManagerTest do
  use ExUnit.Case, async: true

  alias TayCalendar.TimerManager
  alias TayCalendar.PendingTimer
  alias TayCalendar.Porsche

  alias PorscheConnEx.Struct.Emobility
  alias PorscheConnEx.Struct.Emobility.Timer

  alias TayCalendar.Test.DataFactory
  alias TayCalendar.Test.DataFactory.Google, as: EventFactory

  @vin "JN3MS37A9PW202929"
  @model "XX"

  test "with no timers, puts new timers in first slots" do
    {:ok, pid} = start_timer_manager(update_delay: 1)

    event = EventFactory.event()

    timers = [
      %PendingTimer{time: event.start_time |> DateTime.add(-123, :second), event: event},
      %PendingTimer{time: event.end_time |> DateTime.add(123, :second), event: event}
    ]

    TimerManager.push(pid, timers)

    assert_receive {Porsche, :emobility, pid, ref, {@vin, @model}}
    send(pid, {Porsche, ref, {:ok, emobility_response([])}})

    1..2
    |> Enum.each(fn _ ->
      assert_receive {Porsche, :put_timer, pid, ref, {@vin, @model, timer}}

      assert %Timer{
               id: id,
               active?: true,
               charge?: false,
               climate?: true,
               depart_time: depart_time,
               repeating?: false
             } = timer

      index = id - 1
      expected_time = Enum.at(timers, index).time |> to_naive_seconds()
      actual_time = depart_time |> to_naive_seconds()
      assert_in_delta(expected_time, actual_time, 30)

      send(pid, {Porsche, ref, {:ok, true}})
    end)
  end

  test "with existing timers, only replaces timers that do not match pending timers" do
    {:ok, pid} = start_timer_manager(update_delay: 1)

    event = EventFactory.event()

    pending = [
      %PendingTimer{time: event.start_time |> DateTime.add(-100, :second), event: event},
      %PendingTimer{time: event.start_time |> DateTime.add(-200, :second), event: event},
      %PendingTimer{time: event.start_time |> DateTime.add(-300, :second), event: event},
      %PendingTimer{time: event.end_time |> DateTime.add(100, :second), event: event},
      %PendingTimer{time: event.end_time |> DateTime.add(200, :second), event: event}
    ]

    existing =
      pending
      |> Enum.with_index(1)
      |> Enum.map(fn {p, i} ->
        PendingTimer.to_existing(p, i)
      end)

    TimerManager.push(pid, pending)
    assert_receive {Porsche, :emobility, pid, ref, {@vin, @model}}
    send(pid, {Porsche, ref, {:ok, existing |> emobility_response()}})
    # No timer updates.
    refute_receive {Porsche, :put_timer, _, _, _}

    # Now change one of the existing timers:
    changed_existing = existing |> List.update_at(0, fn t -> %Timer{t | active?: false} end)

    TimerManager.push(pid, pending)
    assert_receive {Porsche, :emobility, pid, ref, {@vin, @model}}
    send(pid, {Porsche, ref, {:ok, changed_existing |> emobility_response()}})

    assert_receive {Porsche, :put_timer, pid, ref, {@vin, @model, params}}
    assert params == existing |> Enum.at(0)
    send(pid, {Porsche, ref, {:ok, true}})

    refute_receive {Porsche, _, _, _, _}
  end

  test "with existing timers, leaves repeating timers alone" do
    {:ok, pid} = start_timer_manager(update_delay: 1)

    event = EventFactory.event()

    pending = [
      %PendingTimer{time: event.start_time |> DateTime.add(-123, :second), event: event},
      %PendingTimer{time: event.end_time |> DateTime.add(123, :second), event: event}
    ]

    time = ~N[2024-01-01 07:00:00]

    existing =
      1..4
      |> Enum.map(fn n ->
        DataFactory.timer(id: n, depart_time: time, repeating?: true)
      end)

    TimerManager.push(pid, pending)
    assert_receive {Porsche, :emobility, pid, ref, {@vin, @model}}
    send(pid, {Porsche, ref, {:ok, existing |> emobility_response()}})

    assert_receive {Porsche, :put_timer, pid, ref, {@vin, @model, params}}

    # Update slot 5, the only remaining slot:
    assert params ==
             pending
             |> Enum.at(0)
             |> PendingTimer.to_existing(5)

    send(pid, {Porsche, ref, {:ok, true}})

    # No further updates possible.
    refute_receive {Porsche, _, _, _, _}
  end

  test "with existing timers, deletes unwanted timers" do
    {:ok, pid} = start_timer_manager(update_delay: 1)

    event = EventFactory.event()

    pending = [
      %PendingTimer{time: event.start_time |> DateTime.add(-123, :second), event: event},
      %PendingTimer{time: event.end_time |> DateTime.add(123, :second), event: event}
    ]

    existing = [
      pending |> Enum.at(0) |> PendingTimer.to_existing(1),
      pending |> Enum.at(1) |> PendingTimer.to_existing(2),
      DataFactory.timer(id: 3)
    ]

    TimerManager.push(pid, pending)
    assert_receive {Porsche, :emobility, pid, ref, {@vin, @model}}
    send(pid, {Porsche, ref, {:ok, existing |> emobility_response()}})

    assert_receive {Porsche, :delete_timer, pid, ref, {@vin, @model, 3}}
    send(pid, {Porsche, ref, {:ok, true}})

    refute_receive {Porsche, _, _, _, _}
  end

  defp start_timer_manager(params) do
    config =
      [session: {:mock, self()}, vin: @vin, model: @model]
      |> Keyword.merge(params)

    {:ok, _} = start_supervised({TimerManager, config: config}, restart: :temporary)
  end

  defp emobility_response(timers) do
    %Emobility{
      timers: timers
    }
  end

  defp to_naive_seconds(%NaiveDateTime{} = ndt) do
    {secs, 0} = NaiveDateTime.to_gregorian_seconds(ndt)
    secs
  end

  defp to_naive_seconds(%DateTime{} = dt) do
    dt
    |> DateTime.to_naive()
    |> to_naive_seconds()
  end
end
