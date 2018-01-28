defmodule Farmbot.FarmEvent.Manager do
  @moduledoc """
  Manages execution of FarmEvents.

  ## Rules for FarmEvent execution.
  * Regimen
    * ignore `end_time`.
    * ignore calendar.
    * if start_time is more than 60 seconds passed due, assume it already started, and don't start it again.
  * Sequence
    * if `start_time` is late, check the calendar.
      * for each item in the calendar, check if it's event is more than 60 seconds in the past. if not, execute it.
    * if there is only one event in the calendar, ignore the `end_time`
  """

  # credo:disable-for-this-file Credo.Check.Refactor.FunctionArity

  use GenServer
  use Farmbot.Logger
  alias Farmbot.FarmEvent.Execution
  alias Farmbot.Repo.FarmEvent

  # @checkup_time 100
  @checkup_time 30_000

  def register_events(event_list) do
    GenServer.call(__MODULE__, {:register_events, event_list}, 10_000)
  end

  ## GenServer

  defmodule State do
    @moduledoc false
    defstruct [timer: nil, last_time_index: %{}, events: [], checkup: nil]
  end

  @doc false
  def start_link do
    GenServer.start_link(__MODULE__, [], [name: __MODULE__])
  end

  def init([]) do
    send self(), :checkup
    {:ok, struct(State)}
  end

  def terminate(reason, _state) do
    Logger.error 1, "FarmEvent Manager terminated: #{inspect reason}"
  end

  def handle_call({:register_events, events}, _, state) do
    maybe_farm_event_log "Reindexed FarmEvents"
    if match?({_, _}, state.checkup) do
      Process.exit(state.checkup |> elem(0), {:success, %{state | events: events}})
    end

    if state.timer do
      Process.cancel_timer(state.timer)
      timer = Process.send_after(self(), :checkup, @checkup_time)
      {:reply, :ok, %{state | events: events, timer: timer}}
    else
      {:reply, :ok, %{state | events: events}}
    end
  end

  def handle_info(:checkup, state) do
    checkup = spawn_monitor __MODULE__, :async_checkup, [self(), state]
    {:noreply, %{state | timer: nil, checkup: checkup}}
  end

  def handle_info({:DOWN, _, :process, _, {:success, new_state}}, _old_state) do
    timer = Process.send_after(self(), :checkup, @checkup_time)
    {:noreply, %{new_state | timer: timer, checkup: nil}}
  end

  def handle_info({:DOWN, _, :process, _, error}, state) do
    Logger.error 1, "Farmevent checkup process died: #{inspect error}"
    timer = Process.send_after(self(), :checkup, @checkup_time)
    {:noreply, %{state | timer: timer, checkup: nil}}
  end

  def async_checkup(_manager, state) do
    now = get_now()
    alias Farmbot.Repo.FarmEvent
    # maybe_farm_event_log "Rebuilding calendar."
    all_events = Enum.map(state.events, &FarmEvent.build_calendar(&1))
    # maybe_farm_event_log "Rebuilding calendar complete."

    # do checkup is the bulk of the work.
    {late_events, new} = do_checkup(all_events, now, state)

    #TODO(Connor) Conditionally start events based on some state info.
    unless Enum.empty?(late_events) do
      Logger.debug 3, "Time for events: #{inspect late_events} to run at: #{now.hour}:#{now.minute}"
      start_events(late_events, now)
    end
    exit({:success, %{new | events: all_events}})
  end

  defp do_checkup(list, time, late_events \\ [], state)

  defp do_checkup([], _now, late_events, state), do: {late_events, state}

  defp do_checkup([farm_event | rest], now, late_events, state) do
    # new_late will be a executable event (Regimen or Sequence.)
    {new_late_event, last_time} = check_event(farm_event, now, state.last_time_index[farm_event.id])

    # update state.
    new_state = %{state | last_time_index: Map.put(state.last_time_index, farm_event.id, last_time)}
    case new_late_event do
      # if `new_late_event` is nil, don't accumulate it.
      nil   -> do_checkup(rest, now, late_events, new_state)
      # if there is a new event, accumulate it.
      event -> do_checkup(rest, now, [event | late_events], new_state)
    end
  end

  defp check_event(%FarmEvent{} = f, now, last_time) do
    # Get the executable out of the database this may fail.
    # mod_list = ["Farmbot", "Repo", f.executable_type]
    mod      = Module.safe_concat([f.executable_type])

    event    = lookup(mod, f.executable_id)

    # build a local start time and end time
    start_time = Timex.parse! f.start_time, "{ISO:Extended}"
    end_time   = Timex.parse! f.end_time,   "{ISO:Extended}"
    # start_time = f.start_time
    # end_time = f.end_time
    # get local bool of if the event is started and finished.
    started?  = Timex.after? now, start_time
    finished? = Timex.after? now, end_time

    case f.executable_type do
      "Elixir.Farmbot.Repo.Regimen"  -> maybe_start_regimen(started?, start_time, last_time, event, now)
      "Elixir.Farmbot.Repo.Sequence" -> maybe_start_sequence(started?, finished?, f, last_time, event, now)
    end
  end

  defp maybe_start_regimen(started?, start_time, last_time, event, now)
  defp maybe_start_regimen(true = _started?, start_time, last_time, event, now) do
    case is_too_old?(now, start_time) do
      true  ->
        maybe_farm_event_log "regimen #{event.name} (#{event.id}) is too old to start or already started."
        {nil, last_time}
      false ->
        maybe_farm_event_log "regimen #{event.name} (#{event.id}) starting."
        {event, now}
    end
  end

  defp maybe_start_regimen(false = _started?, start_time, last_time, event, _) do
    maybe_farm_event_log "regimen #{event.name} (#{event.id}) is not started yet. (#{inspect start_time}) (#{inspect Timex.now()})"
    {nil, last_time}
  end

  defp lookup(module, sr_id) do
    case Farmbot.Repo.current_repo().get(module, sr_id) do
      nil -> raise "Could not find #{module} by id: #{sr_id}"
      item -> item
    end
  end

  # signals the start of a sequence based on the described logic.
  defp maybe_start_sequence(started?, finished?, farm_event, last_time, event, now)

  # We only want to check if the sequence is started, and not finished.
  defp maybe_start_sequence(true = _started?, false = _finished?, farm_event, last_time, event, now) do
    {run?, next_time} = should_run_sequence?(farm_event.calendar, last_time, now)
    case run? do
      true  -> {event, next_time}
      false -> {nil, last_time}
    end
  end

  # if `farm_event.time_unit` is "never" we can't use the `end_time`.
  # if we have no `last_time`, time to execute.
  defp maybe_start_sequence(true = _started?, _, %{time_unit: "never"} = f, nil = _last_time, event, now) do
    maybe_farm_event_log "Ignoring end_time."
    case should_run_sequence?(f.calendar, nil, now) do
      {true, next} -> {event, next}
      {false,   _} -> {nil,    nil}
    end
  end

  # if started is false, the event isn't ready to be executed.
  defp maybe_start_sequence(false = _started?, _fin, _farm_event, last_time, event, _now) do
    maybe_farm_event_log "sequence #{event.name} (#{event.id}) is not started yet."
    {nil, last_time}
  end

  # if the event is finished (but not a "never" time_unit), we don't execute.
  defp maybe_start_sequence(_started?, true = _finished?, _farm_event, last_time, event, _now) do
    maybe_farm_event_log "sequence #{event.name} (#{event.id}) is finished."
    {nil, last_time}
  end

  # Checks  if we shoudl run a sequence or not. returns {event | nil, time | nil}
  defp should_run_sequence?(calendar, last_time, now)

  # if there is no last time, check if time is passed now within 60 seconds.
  defp should_run_sequence?([first_time | _], nil, now) do

    maybe_farm_event_log "Checking sequence event that hasn't run before #{first_time}"
    # convert the first_time to a DateTime
    dt = Timex.parse! first_time, "{ISO:Extended}"
    # if now is after the time, we are in fact late
    if Timex.after?(now, dt) do
        {true, now}
     else
       # make sure to return nil as the last time because it stil hasnt executed yet.
       maybe_farm_event_log "Sequence Event not ready yet."
      {false, nil}
    end
  end

  defp should_run_sequence?(nil, last_time, now) do
    maybe_farm_event_log "Checking sequence with no calendar."
    if is_nil(last_time) do
      {true, now}
    else
      {false, last_time}
    end
  end

  defp should_run_sequence?(calendar, last_time, now) do
    # get rid of all the items that happened before last_time
    filtered_calendar = Enum.filter(calendar, fn(iso_time) ->
      dt = Timex.parse! iso_time, "{ISO:Extended}"
      # we only want this time if it happened after the last_time
      Timex.after?(dt, last_time)
    end)

    # if after filtering, there are events that need to be run
    # check if they are older than a minute ago,
    case filtered_calendar do
      [iso_time |  _] ->
        dt = Timex.parse! iso_time, "{ISO:Extended}"
        if Timex.after?(now, dt) do
          {true, dt}
          # too_old? = is_too_old?(now, dt)
          # if too_old?, do: {false, last_time}, else: {true, dt}
        else
          maybe_farm_event_log "Sequence Event not ready yet."
          {false, dt}
        end
      [] ->
        maybe_farm_event_log "No items in calendar."
        {false, last_time}
    end
  end

  # Enumeration is complete.
  defp start_events([], _now), do: :ok

  # Enumerate the events to be started.
  defp start_events([event | rest], now) do
    # Spawn to be non blocking here. Maybe link to this process?
    spawn fn() -> Execution.execute_event(event, now) end
    # Continue enumeration.
    start_events(rest, now)
  end

  # is then more than 1 minute in the past?
  defp is_too_old?(now, then) do
    time_str_fun = fn(dt) -> "#{dt.hour}:#{dt.minute}:#{dt.second}" end
    seconds = DateTime.to_unix(now, :second) - DateTime.to_unix(then, :second)
    c = seconds > 60 # not in MS here
    maybe_farm_event_log "is checking #{time_str_fun.(now)} - #{time_str_fun.(then)} = #{seconds} seconds ago. is_too_old? => #{c}"
    c
  end

  defp get_now(), do: Timex.now()

  defp maybe_farm_event_log(message) do
    if Application.get_env(:farmbot, :farm_event_debug_log) do
      Logger.debug 3, message
    else
      :ok
    end
  end

  @doc "Enable or disbale debug logs for farmevents."
  def debug_logs(bool \\ true) when is_boolean(bool) do
    Application.put_env(:farmbot, :farm_event_debug_log, bool)
  end
end
