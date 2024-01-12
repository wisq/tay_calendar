defmodule TayCalendar.Test.MockTimerManager do
  use GenServer

  def start_link(opts) do
    {on_push, opts} = Keyword.pop!(opts, :on_push)
    GenServer.start_link(__MODULE__, on_push, opts)
  end

  @impl true
  def init(handler) do
    {:ok, handler}
  end

  @impl true
  def handle_cast({:push, timers}, handler) do
    handler.(timers)
    {:noreply, handler}
  end
end
