defmodule GenHerder do
  @moduledoc """
  A behaviour for avoiding the stampeding-herd problem.

  ## Rationale

  It often happens that various clients request the same compution-heavy
  data from a server in parallel, resulting in unnecessary computation.
  The situation, known as the stampeding-herd problem, can be mitigated
  by caching the result of the computation and returning it to all the
  clients that made the request. However, on a cold cache, each parallel
  request would still trigger the computation.

  `GenHerder` ensures that, for several concurrent identical calls, the
  result will be computed only once and returned to all the callers.

  ```mermaid
  sequenceDiagram
      participant Client1
      participant Client2
      participant Client3
      participant Server

      Note over Client1: Without GenHerder

      Client1 ->> +Server: Request Data
      Client2 ->> +Server: Request Data
      Client3 ->> +Server: Request Data

      Server -->> -Client3: Return Result
      Server -->> -Client2: Return Result
      Server -->> -Client1: Return Result

      Note over Client1: With GenHerder

      Client1 ->> +Server: Request Data
      Client2 ->> Server: Request Data
      Client3 ->> Server: Request Data

      Server -->> -Client3: Return Result
      Server -->> Client2: Return Result
      Server -->> Client1: Return Result
  ```

  The sequence diagram above illustrates the problem and how GenHerder
  solves it. The depiction is not entirely accurate, but you get the idea.


  ## Example

  `GenHerder` abstracts the only-once computation and requires only that
  the `c:handle_request/1` and `c:time_to_live/1` callbacks be
  implemented.

  Here is a simple fictitious token generator that just encodes requests
  as a result with a random component and expiry baked in.

  ```
  defmodule TokenGenerator do
    use GenHerder

    # Callbacks

    def handle_request(request) do
      # Simulate work
      Process.sleep(2000)

      # Simply encode the request and a random component as the token
      access_token =
        %{request: request, ref: make_ref()}
        |> :erlang.term_to_binary()
        |> Base.encode64()

      %{access_token: access_token, expires_in: 2000}
    end

    def time_to_live(%{expires_in: expires_in} = _result) do
      # Make it expire 10% earlier
      trunc(expires_in * 0.9)
    end
  end

  # Start the process
  {:ok, pid} = TokenGenerator.start_link()

  # Usage
  TokenGenerator.call(%{any: "kind", of: "data"})
  #=> %{access_token: ..., expires_in: 2000}
  ```

  No matter how many times `TokenGenerator.call/1` is called with the same
  arguments in parallel while the computation is ongoing and within the
  time-to-live, `c:handle_request/1` will be invoked only once.

  ## Caching

  The result is cached for as many milliseconds as returned by `c:time_to_live/1`.
  A TTL of `0` or smaller will cause the result to not be cached at all, but
  still be sent to all callers that made the request prior to its completion.

  `GenHerder` is not a general-purpose caching mechanism. It is advisable to set
  the TTL to 0 and use a dedicated caching solution instead.

  ## Supervision

  You would typically add implementations of the behaviour to your supervision
  tree.

  ```
  children = [
    TokenGenerator
  ]

  Supervisor.start_link(children, strategy: :one_for_all)
  ```

  It should be possible to start the GenHerder globally by providing the `:name`
  option as `{:global, :anything}` or by using a "`via` tuple". While
  this guarantees that only a single GenServer of a given module will be started,
  it does not guarantee the same in the event of a network split. It is up to
  you to decide whether the possibility of multiple GenHerders for the same module
  could result in inconsistencies in your app.

  ## Under the hood

  GenHerder employs a supervisor that supervises a GenServer and TaskSupervisor.

  The GenServer keeps track of all the processes that make a specific request. On
  incoming requests, if no such request was seen before (or has expired) a task
  is spawned (supervised by the TaskSupervisor) and the caller is appended to a
  list of callers. If a task has been spawned previously for the request, but
  has not completed, the caller is simply added to the list.

  When the task for a given request is completed, all the callers are notified and
  the result is cached for the duration of the TTL.

  If a request is made for a value that has already been computed, and is still
  in the cache, the result is simply returned.

  Expiry works by sending a message to the GenServer to drop the given result. There
  is no guarantee regarding how long the message might be held up in the message inbox.

  Since results are computed in tasks, computation does not block the GenServer.
  """

  @type request :: any
  @type result :: any
  @type time_to_live :: integer()

  @callback handle_request(request) :: result
  @callback time_to_live(result) :: time_to_live

  defmacro __using__(_opts) do
    impl = __CALLER__.module

    quote do
      @behaviour GenHerder

      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          type: :worker,
          restart: :permanent,
          shutdown: 500
        }
      end

      def start_link(opts \\ []) do
        children = [
          {Task.Supervisor, name: __MODULE__.IntGenHerder.Server.TaskSupervisor},
          __MODULE__.IntGenHerder.Server
        ]

        Supervisor.start_link(children, Keyword.put(opts, :strategy, :one_for_one))
      end

      def call(request, timeout \\ 5000) do
        GenServer.call(__MODULE__.IntGenHerder.Server, {:request, request}, timeout)
      end

      def expire(request, timeout \\ 5000) do
        GenServer.call(__MODULE__.IntGenHerder.Server, {:expire, request}, timeout)
      end

      defmodule IntGenHerder.Server do
        @moduledoc false
        use GenServer

        def start_link(opts \\ []) do
          GenServer.start_link(__MODULE__, [], Keyword.put(opts, :name, __MODULE__))
        end

        @impl true
        def init(_opts) do
          {:ok, %{}}
        end

        @impl true
        def handle_call({:request, request}, from, state) do
          case state[request] do
            # there is no request like this, schedule one
            nil ->
              task =
                Task.Supervisor.async_nolink(__MODULE__.TaskSupervisor, fn ->
                  {request, unquote(impl).handle_request(request)}
                end)

              {:noreply, Map.put(state, request, {:task, task, [from]})}

            # there is a pending request, add the caller to the waiting list
            {:task, task, froms} ->
              {:noreply, Map.put(state, request, {:task, task, [from | froms]})}

            # there is a cached result, reply immediately
            {:result, result} ->
              {:reply, result, state}

            {:result, result, timer} ->
              {:reply, result, state}
          end
        end

        @impl true
        def handle_call({:expire, request}, _from, state) do
          case state[request] do
            {:result, _result} ->
              {:reply, :ok, Map.delete(state, request)}

            {:result, _result, timer} ->
              Process.cancel_timer(timer)
              {:reply, :ok, Map.delete(state, request)}

            _ ->
              # Don't cancel scheduled tasks
              {:reply, :ok, state}
          end
        end

        @impl true
        def handle_info({ref, result}, state) when is_reference(ref) do
          handle_task_success(ref, result, state)
        end

        @impl true
        def handle_info({:DOWN, ref, _ref, _process, reason}, state) do
          handle_task_failure(ref, reason, state)
        end

        @impl true
        def handle_info({:result_expired, request}, state) do
          {:noreply, Map.delete(state, request)}
        end

        defp handle_task_success(ref, {request, result}, state) do
          # The task succeeded so we can cancel the monitoring and discard the DOWN message
          Process.demonitor(ref, [:flush])

          {{:task, _task, froms}, state} = Map.pop(state, request)

          state =
            case unquote(impl).time_to_live(result) do
              ttl when is_integer(ttl) and ttl <= 0 ->
                # Don't keep the result for future calls
                state

              ttl when is_integer(ttl) ->
                # Keep the result, and schedule its future removal
                timer = Process.send_after(self(), {:result_expired, request}, ttl)
                Map.put(state, request, {:result, result, timer})
            end

          # Send the result to everyone that asked for it
          for from <- froms do
            GenServer.reply(from, result)
          end

          {:noreply, state}
        end

        defp handle_task_failure(ref, reason, state) do
          {request, _task_and_froms} =
            Enum.find(state, fn
              {_request, {:task, task, _forms}} -> task.ref == ref
              _ -> false
            end)

          {{:task, _task, froms}, state} = Map.pop(state, request)

          # Send the result to everyone that asked for it
          for from <- froms do
            GenServer.reply(from, {:error, reason})
          end

          {:noreply, state}
        end
      end
    end
  end
end
