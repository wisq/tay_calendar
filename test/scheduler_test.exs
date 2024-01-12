defmodule TayCalendar.SchedulerTest do
  use ExUnit.Case, async: true

  alias TayCalendar.Scheduler
  alias TayCalendar.Google.API, as: Google

  alias TayCalendar.Test.DataFactory.Google, as: Factory
  alias TayCalendar.Test.{MockTimerManager, MockTravelTime}

  test "retrieves calendar list from Google" do
    {:ok, _} = start_scheduler()

    assert_receive {Google, _pid, _ref, request}
    url = URI.to_string(request.url)
    assert url == "https://www.googleapis.com/calendar/v3/users/me/calendarList"
  end

  test "retrieves calendar events from Google" do
    {:ok, _} = start_scheduler()

    assert_receive {Google, pid, ref, _}
    calendars = 1..Enum.random(1..5) |> Enum.map(fn _ -> Factory.calendar() end)
    send(pid, {Google, ref, {:ok, calendars}})

    calendars
    # Scheduler sorts calendars by ID.
    |> Enum.sort_by(& &1.id)
    |> Enum.each(fn calendar ->
      assert_receive {Google, pid, ref, request}
      url = URI.to_string(request.url)
      assert url == "https://www.googleapis.com/calendar/v3/calendars/#{calendar.id}/events"

      events = 1..Enum.random(1..5) |> Enum.map(fn _ -> Factory.event() end)
      send(pid, {Google, ref, {:ok, events}})
    end)
  end

  test "refreshes calendars from Google" do
    {:ok, _} = start_scheduler(calendars_interval: 1)

    calendar = Factory.calendar()

    # Scheduler retrieves calendar list:
    assert_receive {Google, pid, ref, req}
    assert req.url.path =~ ~r/calendarList$/
    send(pid, {Google, ref, {:ok, [calendar]}})

    # Scheduler retrieves events for calendar:
    assert_receive {Google, pid, ref, req}
    assert req.url.path =~ calendar.id
    send(pid, {Google, ref, {:ok, []}})

    for _ <- 1..3 do
      # Scheduler retrieves new calendar list:
      assert_receive {Google, pid, ref, req}
      assert req.url.path =~ ~r/calendarList$/
      send(pid, {Google, ref, {:ok, [calendar]}})
      # Does NOT retrieve new events (until next event refresh).
    end
  end

  test "refreshes calendar events from Google" do
    {:ok, _} = start_scheduler(events_interval: 1)

    calendar = Factory.calendar()

    # Scheduler retrieves calendar list:
    assert_receive {Google, pid, ref, req}
    assert req.url.path =~ ~r/calendarList$/
    send(pid, {Google, ref, {:ok, [calendar]}})

    for _ <- 1..3 do
      # Scheduler retrieves events for calendar:
      assert_receive {Google, pid, ref, req}
      assert req.url.path =~ calendar.id
      send(pid, {Google, ref, {:ok, []}})
      # Does NOT retreieve new calendars (until next calendar refresh).
    end
  end

  test "uses latest calendar ID(s) for events refresh" do
    {:ok, _} = start_scheduler(calendars_interval: 100, events_interval: 100)

    for _ <- 1..3 do
      calendars = 1..Enum.random(0..3)//1 |> Enum.map(fn _ -> Factory.calendar() end)

      # Scheduler retrieves calendar list:
      assert_receive {Google, pid, ref, req}, 200
      assert req.url.path =~ ~r/calendarList$/
      send(pid, {Google, ref, {:ok, calendars}})

      # Scheduler retrieves events for each calendar:
      calendars
      |> Enum.sort_by(& &1.id)
      |> Enum.each(fn calendar ->
        assert_receive {Google, pid, ref, req}, 200
        assert req.url.path =~ calendar.id
        send(pid, {Google, ref, {:ok, []}})
      end)
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
    send(pid, {Google, ref, {:ok, [Factory.calendar()]}})

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
    send(pid, {Google, ref, {:ok, [Factory.calendar()]}})

    assert_receive {Google, pid, ref, _}
    send(pid, {Google, ref, {:ok, events}})

    assert_receive {:timers, timers}
    assert [%{time: ^timer1}, %{time: ^timer2}] = timers
  end

  test "adds travel time to timers" do
    {:ok, mock_tm} = start_timer_manager()
    {:ok, mock_travel} = start_travel_time()

    garage = Factory.generate_location()
    pre_travel = Enum.random(1..1800)
    post_travel = Enum.random(1..1800)
    before_str = to_interval(post_travel) <> " + travel + " <> to_interval(pre_travel)

    {:ok, _} =
      start_scheduler(
        timer_manager: mock_tm,
        garage: garage,
        travel_time: mock_travel,
        event_defaults: %{before: before_str}
      )

    event = Factory.event(location: Factory.generate_location())

    assert_receive {Google, pid, ref, _}
    send(pid, {Google, ref, {:ok, [Factory.calendar()]}})

    assert_receive {Google, pid, ref, _}
    send(pid, {Google, ref, {:ok, [event]}})

    assert_receive {MockTravelTime, pid, ref, request}
    assert request.origin == garage
    assert request.destination == event.location
    assert request.arrival_time == event.start_time |> DateTime.add(-post_travel, :second)

    travel_secs = Enum.random(1..1800)
    travel_depart = request.arrival_time |> DateTime.add(-travel_secs, :second)
    send(pid, {MockTravelTime, ref, {:ok, travel_depart}})

    assert_receive {:timers, [timer]}
    assert timer.time == travel_depart |> DateTime.add(-pre_travel, :second)
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

  defp start_scheduler(params \\ []) do
    config =
      [
        goth: {:mock, self()},
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
