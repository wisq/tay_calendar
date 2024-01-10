defmodule Mix.Tasks.Taycal.Calendar.Add do
  use Mix.Task

  alias TayCalendar.Google

  @moduledoc false

  @goth TayCalendar.Tasks.Goth
  @scopes [
    "https://www.googleapis.com/auth/calendar"
  ]

  def run([]) do
    Mix.raise("Usage: mix taycal.calendar.add <calendar ID>")
  end

  def run([cal_id]) do
    {:ok, _} = Application.ensure_all_started([:req, :goth])

    {:ok, _} =
      Goth.start_link(
        name: @goth,
        source: {
          :service_account,
          TayCalendar.read_credentials(),
          scopes: @scopes
        }
      )

    Google.API.post(@goth,
      url: "https://www.googleapis.com/calendar/v3/users/me/calendarList",
      json: %{id: cal_id}
    )
    |> IO.inspect()
  end
end
