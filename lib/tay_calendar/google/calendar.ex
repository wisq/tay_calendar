defmodule TayCalendar.Google.Calendar do
  @list_url "https://www.googleapis.com/calendar/v3/users/me/calendarList"

  @enforce_keys [:id, :name, :description]
  defstruct(@enforce_keys)

  alias TayCalendar.Google.API

  def list(goth) do
    with {:ok, %{"items" => items}} <- API.get(goth, url: @list_url) do
      {:ok, items |> Enum.map(&from_json/1)}
    end
  end

  defp from_json(%{"id" => id, "summary" => name, "description" => desc}) do
    %__MODULE__{
      id: id,
      name: name,
      description: desc
    }
  end
end
