defmodule Honeybadger.Client do
  @moduledoc false

  use GenServer

  require Logger

  @headers [
    {"Accept", "application/json"},
    {"Content-Type", "application/json"},
    {"User-Agent", "Honeybadger Elixir"}
  ]
  @max_connections 20
  @notices_endpoint "/v1/notices"

  # State

  @type t :: %{
          api_key: binary(),
          enabled: boolean(),
          headers: [{binary(), binary()}],
          proxy: binary(),
          proxy_auth: {binary(), binary()},
          url: binary()
        }

  defstruct [:api_key, :enabled, :headers, :proxy, :proxy_auth, :url]

  # API

  @doc false
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, new(opts), name: __MODULE__)
  end

  @doc false
  @spec new(Keyword.t()) :: t()
  def new(opts) do
    %__MODULE__{
      enabled: enabled?(opts),
      api_key: get_env(opts, :api_key),
      headers: build_headers(opts),
      proxy: get_env(opts, :proxy),
      proxy_auth: get_env(opts, :proxy_auth),
      url: get_env(opts, :origin) <> @notices_endpoint
    }
  end

  @doc false
  @spec send_notice(map()) :: :ok | {:error, term()}
  def send_notice(notice) when is_map(notice) do
    if pid = Process.whereis(__MODULE__) do
      GenServer.cast(pid, {:notice, notice})
    else
      Logger.warn(fn ->
        "[Honeybadger] Unable to notify, the :honeybadger client isn't running"
      end)
    end
  end

  @doc """
  Check whether reporting is enabled for the current environment.

  ## Example

      iex> Honeybadger.Client.enabled?(environment_name: :dev, exclude_envs: [:test, :dev])
      false

      iex> Honeybadger.Client.enabled?(environment_name: "dev", exclude_envs: [:test, :dev])
      false

      iex> Honeybadger.Client.enabled?(environment_name: :dev, exclude_envs: [:test])
      true

      iex> Honeybadger.Client.enabled?(environment_name: "unexpected", exclude_envs: [:test])
      true
  """
  @spec enabled?(Keyword.t()) :: boolean
  def enabled?(opts) do
    env_name = get_env(opts, :environment_name)
    excluded = get_env(opts, :exclude_envs)

    not maybe_to_atom(env_name) in excluded
  end

  # Callbacks

  @impl GenServer
  def init(%__MODULE__{} = state) do
    warn_if_incomplete_env(state)
    warn_in_dev_mode(state)

    :ok = :hackney_pool.start_pool(__MODULE__, max_connections: @max_connections)

    {:ok, state}
  end

  @impl GenServer
  def terminate(_reason, _state) do
    :ok = :hackney_pool.stop_pool(__MODULE__)
  end

  @impl GenServer
  def handle_cast({:notice, _notice}, %{enabled: false} = state) do
    {:noreply, state}
  end

  def handle_cast({:notice, _notice}, %{api_key: nil} = state) do
    {:noreply, state}
  end

  def handle_cast({:notice, notice}, %{enabled: true} = state) do
    payload = Poison.encode!(notice)

    opts =
      state
      |> Map.take([:proxy, :proxy_auth])
      |> Enum.into(Keyword.new())
      |> Keyword.put(:pool, __MODULE__)

    case :hackney.post(state.url, state.headers, payload, opts) do
      {:ok, code, _headers, ref} when code >= 200 and code <= 399 ->
        body = body_from_ref(ref)
        Logger.debug(fn -> "[Honeybadger] API success: #{inspect(body)}" end)

      {:ok, code, _headers, ref} when code >= 400 and code <= 504 ->
        body = body_from_ref(ref)
        Logger.error(fn -> "[Honeybadger] API failure: #{inspect(body)}" end)

      {:error, reason} ->
        Logger.error(fn -> "[Honeybadger] connection error: #{inspect(reason)}" end)
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(message, state) do
    Logger.info(fn -> "[Honeybadger] unexpected message: #{inspect(message)}" end)

    {:noreply, state}
  end

  # Helpers

  defp body_from_ref(ref) do
    ref
    |> :hackney.body()
    |> elem(1)
  end

  defp build_headers(opts) do
    [{"X-API-Key", get_env(opts, :api_key)}] ++ @headers
  end

  defp get_env(opts, key) do
    Keyword.get(opts, key, Honeybadger.get_env(key))
  end

  defp maybe_to_atom(value) when is_binary(value), do: String.to_atom(value)
  defp maybe_to_atom(value), do: value

  @mandatory_keys ~w(api_key environment_name)a
  defp warn_if_incomplete_env(%{enabled: true}) do
    for key <- @mandatory_keys do
      unless Honeybadger.get_env(key) do
        Logger.error(fn -> "mandatory :honeybadger config key #{key} not set" end)
      end
    end
  end

  defp warn_if_incomplete_env(_state), do: :ok

  defp warn_in_dev_mode(%{enabled: false}) do
    Logger.warn(fn ->
      "[Honeybadger] Development mode is enabled. Data will not be reported until you deploy your app."
    end)
  end

  defp warn_in_dev_mode(_state), do: :ok
end
