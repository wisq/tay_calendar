defmodule TayCalendar.Porsche do
  alias PorscheConnEx.Client

  def emobility({:mock, pid}, vin, model), do: mock(pid, :emobility, {vin, model})
  def emobility(session, vin, model), do: Client.emobility(session, vin, model)

  def delete_timer({:mock, pid}, vin, model, id), do: mock(pid, :delete_timer, {vin, model, id})
  def delete_timer(session, vin, model, id), do: Client.delete_timer(session, vin, model, id)

  def put_timer({:mock, pid}, vin, model, timer), do: mock(pid, :put_timer, {vin, model, timer})
  def put_timer(session, vin, model, timer), do: Client.put_timer(session, vin, model, timer)

  def put_charging_profile({:mock, pid}, vin, model, profile),
    do: mock(pid, :put_charging_profile, {vin, model, profile})

  def put_charging_profile(session, vin, model, profile),
    do: Client.put_charging_profile(session, vin, model, profile)

  defp mock(pid, function, args) do
    ref = make_ref()
    send(pid, {__MODULE__, function, self(), ref, args})

    receive do
      {__MODULE__, ^ref, result} ->
        result
    after
      1000 -> raise "no mock response received"
    end
  end
end
