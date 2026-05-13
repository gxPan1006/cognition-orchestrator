defmodule CognitionWeb.ObservabilityApiController do
  @moduledoc """
  JSON API for Cognition observability data.
  """

  use Phoenix.Controller, formats: [:json]

  alias Cognition.Linear.Client, as: LinearClient
  alias CognitionWeb.{Endpoint, Presenter}
  alias Plug.Conn

  @spec state(Conn.t(), map()) :: Conn.t()
  def state(conn, _params) do
    json(conn, Presenter.state_payload(orchestrator(), snapshot_timeout_ms()))
  end

  @spec issue(Conn.t(), map()) :: Conn.t()
  def issue(conn, %{"issue_identifier" => issue_identifier}) do
    case Presenter.issue_payload(issue_identifier, orchestrator(), snapshot_timeout_ms()) do
      {:ok, payload} ->
        json(conn, payload)

      {:error, :issue_not_found} ->
        error_response(conn, 404, "issue_not_found", "Issue not found")
    end
  end

  @spec refresh(Conn.t(), map()) :: Conn.t()
  def refresh(conn, _params) do
    case Presenter.refresh_payload(orchestrator()) do
      {:ok, payload} ->
        conn
        |> put_status(202)
        |> json(payload)

      {:error, :unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec linear_graphql(Conn.t(), map()) :: Conn.t()
  def linear_graphql(conn, params) do
    with {:ok, query} <- fetch_linear_query(params),
         {:ok, variables} <- fetch_linear_variables(params),
         {:ok, response} <- linear_client_module().graphql(query, variables) do
      json(conn, response)
    else
      {:error, :missing_query} ->
        error_response(conn, 400, "missing_query", "Request body must include a non-empty `query` string")

      {:error, :invalid_variables} ->
        error_response(conn, 400, "invalid_variables", "`variables` must be a JSON object when provided")

      {:error, :missing_linear_api_token} ->
        error_response(conn, 500, "missing_linear_api_token", "Cognition has no Linear API token configured")

      {:error, {:linear_api_status, status}} ->
        error_response(conn, 502, "linear_api_status", "Linear GraphQL responded with HTTP #{status}")

      {:error, {:linear_api_request, reason}} ->
        error_response(conn, 502, "linear_api_request", "Linear GraphQL request failed: #{inspect(reason)}")

      {:error, reason} ->
        error_response(conn, 500, "linear_graphql_failed", "Linear GraphQL request failed: #{inspect(reason)}")
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  @spec not_found(Conn.t(), map()) :: Conn.t()
  def not_found(conn, _params) do
    error_response(conn, 404, "not_found", "Route not found")
  end

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp fetch_linear_query(params) when is_map(params) do
    case Map.get(params, "query") do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp fetch_linear_query(_params), do: {:error, :missing_query}

  defp fetch_linear_variables(params) when is_map(params) do
    case Map.get(params, "variables") do
      nil -> {:ok, %{}}
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp fetch_linear_variables(_params), do: {:ok, %{}}

  defp linear_client_module do
    Application.get_env(:cognition, :linear_client_module, LinearClient)
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || Cognition.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end
end
