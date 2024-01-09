defmodule TayCalendar.Google.API do
  def get(goth, params) do
    req(goth, params |> Keyword.put(:method, :get))
  end

  defp req(goth, params) do
    {:ok, token} = Goth.fetch(goth)

    Req.new(params)
    |> Req.Request.put_header("authorization", "#{token.type} #{token.token}")
    |> Req.request()
    |> handle_response()
  end

  defp handle_response({:ok, %{status: 200, body: body}}) when is_map(body) or is_list(body),
    do: {:ok, body}
end
