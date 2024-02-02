defmodule TayCalendar do
  use Application
  require Logger

  alias TayCalendar.Secrets

  def start(_type, _args) do
    children =
      if Application.get_env(:tay_calendar, :start, true) do
        app_children()
      else
        []
      end

    opts = [strategy: :one_for_one, name: TayCalendar.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp app_children do
    [
      {Goth, name: TayCalendar.Supervisor.Goth, source: {:refresh_token, read_credentials(), []}},
      {TayCalendar.TravelTime,
       name: TayCalendar.Supervisor.TravelTime, goth: TayCalendar.Supervisor.Goth},
      {PorscheConnEx.Session,
       name: TayCalendar.Supervisor.PorscheSession,
       credentials: [
         username: Secrets.fetch!("PORSCHE_USERNAME"),
         password: Secrets.fetch!("PORSCHE_PASSWORD")
       ]},
      {TayCalendar.Stats, name: TayCalendar.Supervisor.Stats},
      {TayCalendar.OffPeakCharger,
       name: TayCalendar.Supervisor.OffPeakCharger,
       config:
         Application.get_env(:tay_calendar, :off_peak_charger, %{})
         |> Map.merge(%{
           session: TayCalendar.Supervisor.PorscheSession,
           vin: Secrets.fetch!("PORSCHE_VIN"),
           model: Secrets.fetch!("PORSCHE_MODEL")
         })},
      {TayCalendar.TimerManager,
       name: TayCalendar.Supervisor.TimerManager,
       config: [
         session: TayCalendar.Supervisor.PorscheSession,
         off_peak_charger: TayCalendar.Supervisor.OffPeakCharger,
         stats: TayCalendar.Supervisor.Stats,
         vin: Secrets.fetch!("PORSCHE_VIN"),
         model: Secrets.fetch!("PORSCHE_MODEL")
       ]},
      {TayCalendar.Scheduler,
       name: TayCalendar.Supervisor.Scheduler,
       config: [
         goth: TayCalendar.Supervisor.Goth,
         timer_manager: TayCalendar.Supervisor.TimerManager,
         travel_time: TayCalendar.Supervisor.TravelTime,
         calendar_ids: read_calendar_ids(),
         event_defaults: Application.fetch_env!(:tay_calendar, :event_defaults)
       ]}
    ]
  end

  def read_credentials do
    System.get_env("GOOGLE_AUTH_FILE", priv("credentials.json"))
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("web")
  end

  def read_calendar_ids do
    System.get_env("GOOGLE_CALENDAR_IDS_FILE", priv("calendar_ids.txt"))
    |> File.read!()
    |> String.trim()
    |> String.split("\n")
  end

  defp priv(file) do
    :code.priv_dir(:tay_calendar)
    |> String.Chars.to_string()
    |> Path.join(file)
  end
end
