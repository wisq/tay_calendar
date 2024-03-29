defmodule TayCalendar.Google.API do
  def get(goth, params) do
    req(goth, params |> Keyword.put(:method, :get))
  end

  def post(goth, params) do
    req(goth, params |> Keyword.put(:method, :post))
  end

  defp req({:mock, pid}, params) do
    ref = make_ref()
    send(pid, {__MODULE__, self(), ref, Req.new(params)})

    receive do
      {__MODULE__, ^ref, result} ->
        result
    after
      1000 -> raise "no mock response received"
    end
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

  defp handle_response({:ok, %{status: 404}}), do: {:error, :not_found}
end
