defmodule TayCalendar.Google.Event do
  defp list_url(calendar_id) do
    "https://www.googleapis.com/calendar/v3/calendars/#{calendar_id}/events"
  end

  alias TayCalendar.Google.API

  @enforce_keys [:id, :name, :description, :location, :start_time, :end_time]
  defstruct(@enforce_keys)

  def list(goth, calendar_id, params \\ []) do
    params =
      params
      |> Keyword.replace_lazy(:timeMin, &DateTime.to_iso8601/1)
      |> Keyword.replace_lazy(:timeMax, &DateTime.to_iso8601/1)

    with {:ok, %{"items" => items}} <-
           API.get(goth,
             url: list_url(calendar_id),
             params: params
           ) do
      {:ok, items |> Enum.map(&from_json/1)}
    end
  end

  defp from_json(
         %{
           "id" => id,
           "summary" => name,
           "start" => start_time,
           "end" => end_time
         } = event
       ) do
    %__MODULE__{
      id: id,
      name: name,
      location: event |> Map.get("location"),
      description: event |> Map.get("description"),
      start_time: start_time |> parse_time(),
      end_time: end_time |> parse_time()
    }
  end

  defp parse_time(%{"dateTime" => time, "timeZone" => zone}) do
    Timex.parse!(time, "{ISO:Extended}")
    |> Timex.Timezone.convert(zone)
  end
end
