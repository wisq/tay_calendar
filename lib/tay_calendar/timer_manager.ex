defmodule TayCalendar.TimerManager do
  require Logger
  use GenServer

  alias TayCalendar.Porsche
  alias TayCalendar.{ExistingTimer, PendingTimer}
  alias TayCalendar.{Stats, OffPeakCharger}

  defmodule Config do
    @enforce_keys [:session, :vin, :model]
    defstruct(
      session: nil,
      off_peak_charger: nil,
      vin: nil,
      model: nil,
      # If planning fails, retry after 30 secs.
      error_retry: 30_000,
      # Pause for 10 secs between timer updates.
      update_delay: 10_000
    )
  end

  defmodule State do
    @enforce_keys [:config]
    defstruct(
      config: nil,
      to_plan: nil,
      to_update: nil
    )
  end

  @timer_slots 1..5

  defmodule Slot do
    @enforce_keys [:id, :timer, :available, :priority, :action]
    defstruct(@enforce_keys)
    alias __MODULE__

    @prio_free 10
    @prio_unused 9
    @prio_repeat 0

    def free(id) do
      %Slot{
        id: id,
        timer: nil,
        available: true,
        priority: @prio_free,
        action: :keep
      }
    end

    def existing(id, %ExistingTimer{repeating: true} = timer, _priority) do
      %Slot{
        id: id,
        timer: timer,
        available: false,
        priority: @prio_repeat,
        action: :keep
      }
    end

    def existing(id, %ExistingTimer{repeating: false} = timer, priority) do
      %Slot{
        id: id,
        timer: timer,
        available: true,
        priority: priority || @prio_unused,
        action: :delete
      }
    end

    def keep(%Slot{} = slot) do
      %Slot{slot | action: :keep, available: false}
    end

    def replace(%Slot{} = slot, %PendingTimer{} = timer) do
      %Slot{
        slot
        | timer: PendingTimer.to_existing(timer, slot.id),
          action: :replace,
          available: false
      }
    end

    def sort_key(%Slot{priority: prio, id: id}), do: {-prio, id}

    def describe_timer(%Slot{timer: nil}), do: "(nil)"
    def describe_timer(%Slot{timer: timer}), do: ExistingTimer.describe(timer)
  end

  def start_link(opts) do
    {config, opts} = Keyword.pop!(opts, :config)
    GenServer.start_link(__MODULE__, struct!(Config, config), opts)
  end

  def push(pid, timers) do
    GenServer.cast(pid, {:push, timers})
  end

  @impl true
  def init(%Config{} = config) do
    {:ok, %State{config: config}}
  end

  @impl true
  def handle_cast({:push, timers}, state) when is_list(timers) do
    {:noreply, %State{state | to_plan: timers}, {:continue, :plan}}
  end

  @impl true
  def handle_continue(:plan, state) do
    with {:ok, existing} <- existing_timers(state.config) do
      Logger.info("Vehicle timers: " <> describe_existing_timers(existing))
      to_update = plan_update(state.to_plan, existing)
      {:noreply, %State{state | to_plan: nil, to_update: to_update}, {:continue, :update}}
    else
      err ->
        Logger.error("Error while planning update: #{inspect(err)}")
        {:noreply, state, state.config.error_retry}
    end
  end

  @impl true
  def handle_continue(:update, state) do
    case state.to_update do
      [] ->
        Logger.info("No pending timer updates.")
        {:noreply, %State{state | to_update: nil}}

      ups ->
        Logger.info("Pending updates: #{Enum.count(ups)} remaining.")
        {:noreply, state, state.config.update_delay}
    end
  end

  @impl true
  def handle_info(:timeout, %State{to_plan: to_plan} = state) when is_list(to_plan) do
    {:noreply, state, {:continue, :plan}}
  end

  @impl true
  def handle_info(:timeout, %State{to_update: to_update} = state) when is_list(to_update) do
    if Enum.empty?(to_update) do
      Logger.info("Timer update is complete.")
      {:noreply, %State{state | to_update: nil}}
    else
      [slot | rest] = to_update |> Enum.shuffle()

      case update_slot(slot, state.config) do
        :ok ->
          {:noreply, %State{state | to_update: rest}, {:continue, :update}}

        :error ->
          {:noreply, state, {:continue, :update}}
      end
    end
  end

  defp existing_timers(config) do
    with {:ok, body} <- Porsche.emobility(config.session, config.vin, config.model) do
      Stats.put_emobility(body)
      OffPeakCharger.put_emobility(config.off_peak_charger, body)

      case Map.fetch(body, "timers") do
        {:ok, timers} when is_list(timers) -> {:ok, timers |> Enum.map(&ExistingTimer.from_api/1)}
        :error -> {:error, :timers_unavailable}
      end
    end
  end

  defp describe_existing_timers([]), do: "(no timers)"

  defp describe_existing_timers(timers) do
    timers
    |> Enum.map(fn t ->
      "\n  - ##{t.id}: #{ExistingTimer.describe(t)}"
    end)
    |> Enum.join()
  end

  defp plan_update(wanted, existing) do
    priorities =
      existing
      |> Map.new(fn exis ->
        wanted
        |> Enum.with_index()
        |> Enum.find(fn {pend, _} -> PendingTimer.is_covered_by?(pend, exis) end)
        |> then(fn
          {_, index} -> {exis.id, index}
          nil -> {exis.id, nil}
        end)
      end)

    slots =
      @timer_slots
      |> Enum.map(fn id ->
        case Enum.find(existing, &(&1.id == id)) do
          nil -> Slot.free(id)
          timer -> Slot.existing(id, timer, Map.fetch!(priorities, timer.id))
        end
      end)
      |> Enum.sort_by(&Slot.sort_key/1)

    wanted
    |> Enum.reduce_while(slots, &put_timer_into_slot/2)
    |> Enum.reject(&(&1.action == :keep))
  end

  defp put_timer_into_slot(%PendingTimer{} = timer, slots) do
    case slots
         |> Enum.find_index(fn
           %Slot{timer: nil} -> false
           %Slot{timer: existing} -> PendingTimer.is_covered_by?(timer, existing)
         end) do
      nil -> put_into_first_slot(timer, slots)
      index -> {:cont, slots |> List.update_at(index, &Slot.keep/1)}
    end
  end

  defp put_into_first_slot(%PendingTimer{} = timer, slots) do
    case slots |> Enum.find_index(& &1.available) do
      nil -> {:halt, slots}
      index -> {:cont, slots |> List.update_at(index, &Slot.replace(&1, timer))}
    end
  end

  defp update_slot(%Slot{action: :replace} = slot, config) do
    Logger.info("Replacing ##{slot.id} with #{Slot.describe_timer(slot)} ...")
    api_timer = slot.timer |> ExistingTimer.to_api()

    case Porsche.put_timer(config.session, config.vin, config.model, api_timer) do
      {:ok, _} ->
        Logger.info("Slot ##{slot.id} replaced.")
        :ok

      {:error, err} ->
        Logger.info("Error replacing slot ##{slot.id}: #{inspect(err)}")
        :error
    end
  end

  defp update_slot(%Slot{action: :delete} = slot, config) do
    Logger.info("Deleting slot ##{slot.id}, was #{Slot.describe_timer(slot)} ...")

    case Porsche.delete_timer(config.session, config.vin, config.model, slot.id) do
      {:ok, _} ->
        Logger.info("Slot ##{slot.id} deleted.")
        :ok

      {:error, err} ->
        Logger.info("Error deleting slot ##{slot.id}: #{inspect(err)}")
        :error
    end
  end
end
