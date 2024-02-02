defmodule TayCalendar.Test.MockTravelTime do
  use GenServer

  def start_link(opts) do
    {pid, opts} = Keyword.pop!(opts, :pid)
    GenServer.start_link(__MODULE__, pid, opts)
  end

  @impl true
  def init(pid) do
    {:ok, pid}
  end

  @impl true
  def handle_call({:get, calendar_id, event_uid, etag, start_time}, _from, pid) do
    ref = make_ref()

    send(
      pid,
      {__MODULE__, self(), ref,
       %{
         calendar_id: calendar_id,
         event_uid: event_uid,
         etag: etag,
         start_time: start_time
       }}
    )

    receive do
      {__MODULE__, ^ref, result} ->
        {:reply, result, pid}
    after
      1000 -> raise "no mock response received"
    end
  end
end
