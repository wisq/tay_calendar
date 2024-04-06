defmodule TayCalendar.SchedulerTest do
  use ExUnit.Case, async: true

  alias TayCalendar.Scheduler
  alias TayCalendar.Google.API, as: Google

  alias TayCalendar.Test.DataFactory.Google, as: Factory
  alias TayCalendar.Test.{MockTimerManager, MockTravelTime}

  test "retrieves calendar events from Google" do
    calendar_ids =
      1..Enum.random(1..5)
      |> Enum.map(fn _ -> Factory.generate_calendar_id() end)

    {:ok, _} = start_scheduler(calendar_ids: calendar_ids)

    calendar_ids
    |> Enum.each(fn cal_id ->
      assert_receive {Google, pid, ref, request}
      url = URI.to_string(request.url)
      assert url == "https://www.googleapis.com/calendar/v3/calendars/#{cal_id}/events"

      events = 1..Enum.random(1..5) |> Enum.map(fn _ -> Factory.event(calendar_id: cal_id) end)
      send(pid, {Google, ref, {:ok, events}})
    end)
  end

  test "refreshes calendar events from Google" do
    calendar_id = Factory.generate_calendar_id()
    {:ok, _} = start_scheduler(events_interval: 1, calendar_ids: [calendar_id])

    for _ <- 1..3 do
      # Scheduler retrieves events for calendar:
      assert_receive {Google, pid, ref, req}
      assert req.url.path =~ calendar_id
      send(pid, {Google, ref, {:ok, []}})
    end
  end

  test "generates timers using default configuration" do
    {:ok, mock_tm} = start_timer_manager()

    before_seconds = Enum.random(1..7200)
    after_seconds = Enum.random(1..7200)

    {:ok, _} =
      start_scheduler(
        timer_manager: mock_tm,
        event_defaults: %{
          before: before_seconds |> to_interval(),
          after: after_seconds |> to_interval()
        }
      )

    events =
      [:past, :future, :now]
      |> Map.new(fn timing ->
        {timing, Factory.event(timing: timing)}
      end)

    assert_receive {Google, pid, ref, _}
    send(pid, {Google, ref, {:ok, Map.values(events)}})

    assert_receive {:timers, timers}
    # Expecting after-timer for now-event, and both timers for future-event.
    # All other timers are in the past and should be filtered out.
    assert Enum.count(timers) == 3
    by_event = timers |> Enum.group_by(& &1.event)

    assert [now_after] = by_event |> Map.fetch!(events.now)
    assert DateTime.diff(now_after.time, events.now.end_time) == after_seconds

    assert [future_before, future_after] = by_event |> Map.fetch!(events.future)
    assert DateTime.diff(events.future.start_time, future_before.time) == before_seconds
    assert DateTime.diff(future_after.time, events.future.end_time) == after_seconds
  end

  test "generates timers using per-event configuration" do
    {:ok, mock_tm} = start_timer_manager()

    {:ok, _} =
      start_scheduler(
        timer_manager: mock_tm,
        event_defaults: %{
          before: "10m",
          after: "off"
        }
      )

    before_seconds = Enum.random(1..7200)
    after_seconds = Enum.random(1..7200)

    desc_before = """
    #TayCalBefore: #{before_seconds |> to_interval()}
    #TayCalAfter: off
    """

    desc_after = """
    #TayCalAfter: #{after_seconds |> to_interval()}
    #TayCalBefore: off
    """

    [before_event, after_event] =
      events = [
        Factory.event(description: desc_before),
        Factory.event(description: desc_after)
      ]

    [timer1, timer2] =
      [
        before_event.start_time |> DateTime.add(-before_seconds, :second),
        after_event.end_time |> DateTime.add(after_seconds, :second)
      ]
      |> Enum.sort_by(&DateTime.to_unix/1)

    assert_receive {Google, pid, ref, _}
    send(pid, {Google, ref, {:ok, events}})

    assert_receive {:timers, timers}
    assert [%{time: ^timer1}, %{time: ^timer2}] = timers
  end

  test "handles charging directive" do
    {:ok, mock_tm} = start_timer_manager()

    {:ok, _} =
      start_scheduler(
        timer_manager: mock_tm,
        event_defaults: %{
          before: "1m",
          after: "1m"
        }
      )

    event = Factory.event(description: "#TayCalCharge: 95%")

    [timer1, timer2] =
      [
        event.start_time |> DateTime.add(-60, :second),
        event.end_time |> DateTime.add(60, :second)
      ]

    assert_receive {Google, pid, ref, _}
    send(pid, {Google, ref, {:ok, [event]}})

    assert_receive {:timers, timers}
    assert [%{time: ^timer1, charge: 95}, %{time: ^timer2}] = timers
  end

  test "handles charging default" do
    {:ok, mock_tm} = start_timer_manager()

    {:ok, _} =
      start_scheduler(
        timer_manager: mock_tm,
        event_defaults: %{
          before: "1m",
          after: "1m",
          charge: "50%"
        }
      )

    event = Factory.event()

    [timer1, timer2] =
      [
        event.start_time |> DateTime.add(-60, :second),
        event.end_time |> DateTime.add(60, :second)
      ]

    assert_receive {Google, pid, ref, _}
    send(pid, {Google, ref, {:ok, [event]}})

    assert_receive {:timers, timers}
    assert [%{time: ^timer1, charge: 50}, %{time: ^timer2}] = timers
  end

  test "adds travel time to timers" do
    {:ok, mock_tm} = start_timer_manager()
    {:ok, mock_travel} = start_travel_time()

    pre_travel = Enum.random(1..1800)
    post_travel = Enum.random(1..1800)
    before_str = to_interval(post_travel) <> " + travel + " <> to_interval(pre_travel)

    {:ok, _} =
      start_scheduler(
        timer_manager: mock_tm,
        travel_time: mock_travel,
        event_defaults: %{before: before_str}
      )

    event = Factory.event(location: Factory.generate_location())

    assert_receive {Google, pid, ref, _}
    send(pid, {Google, ref, {:ok, [event]}})

    assert_receive {MockTravelTime, pid, ref, request}
    assert request.calendar_id == event.calendar_id
    assert request.event_uid == event.ical_uid
    assert request.etag == event.etag
    assert request.start_time == event.start_time

    duration = Enum.random(1..1800) |> Timex.Duration.from_seconds()
    send(pid, {MockTravelTime, ref, {:ok, duration}})

    assert_receive {:timers, [timer]}

    assert timer.time ==
             event.start_time
             |> DateTime.add(-post_travel, :second)
             |> Timex.subtract(duration)
             |> DateTime.add(-pre_travel, :second)
             |> DateTime.truncate(:second)
  end

  defp start_timer_manager do
    me = self()
    on_push = fn timers -> send(me, {:timers, timers}) end

    {:ok, _pid} = start_supervised({MockTimerManager, on_push: on_push}, restart: :temporary)
  end

  defp start_travel_time do
    me = self()
    {:ok, _pid} = start_supervised({MockTravelTime, pid: me}, restart: :temporary)
  end

  defp start_scheduler(params) do
    config =
      [
        goth: {:mock, self()},
        calendar_ids: [Factory.generate_calendar_id()],
        travel_time: nil,
        timer_manager: nil
      ]
      |> Keyword.merge(params)

    {:ok, _pid} =
      start_supervised({Scheduler, config: config}, restart: :temporary)
  end

  defp to_interval(secs) do
    [
      h: secs |> div(3600),
      m: secs |> rem(3600) |> div(60),
      s: secs |> rem(60)
    ]
    |> Enum.reject(fn {_, value} -> value == 0 end)
    |> Enum.map(fn {unit, value} -> "#{value}#{unit}" end)
    |> Enum.join("")
  end
end
