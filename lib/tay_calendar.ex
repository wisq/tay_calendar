defmodule TayCalendar do
  use Application
  require Logger

  alias TayCalendar.Secrets

  @scopes [
    "https://www.googleapis.com/auth/calendar.readonly",
    "https://www.googleapis.com/auth/calendar.events.readonly"
  ]

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
      TayCalendar.Stats,
      {TayCalendar.TravelTime, name: TayCalendar.Supervisor.TravelTime},
      {Goth,
       name: TayCalendar.Supervisor.Goth,
       source: {
         :service_account,
         read_credentials(),
         scopes: @scopes
       }},
      {PorscheConnEx.Session,
       name: TayCalendar.Supervisor.PorscheSession,
       credentials: [
         username: Secrets.fetch!("PORSCHE_USERNAME"),
         password: Secrets.fetch!("PORSCHE_PASSWORD")
       ]},
      {TayCalendar.TimerManager,
       name: TayCalendar.Supervisor.TimerManager,
       config: [
         session: TayCalendar.Supervisor.PorscheSession,
         vin: Secrets.fetch!("PORSCHE_VIN"),
         model: Secrets.fetch!("PORSCHE_MODEL")
       ]},
      {TayCalendar.Scheduler,
       name: TayCalendar.Supervisor.Scheduler,
       config: [
         goth: TayCalendar.Supervisor.Goth,
         timer_manager: TayCalendar.Supervisor.TimerManager,
         travel_time: TayCalendar.Supervisor.TravelTime,
         garage: Secrets.get("GARAGE_LOCATION")
       ]}
    ]
  end

  def read_credentials do
    System.get_env("GOOGLE_AUTH_FILE", priv("credentials.json"))
    |> File.read!()
    |> Jason.decode!()
  end

  defp priv(file) do
    :code.priv_dir(:tay_calendar)
    |> String.Chars.to_string()
    |> Path.join(file)
  end
end
