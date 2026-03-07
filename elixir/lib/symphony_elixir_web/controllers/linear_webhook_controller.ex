defmodule SymphonyElixirWeb.LinearWebhookController do
  @moduledoc """
  Receives Linear webhook deliveries and triggers an immediate orchestrator refresh.
  """

  use Phoenix.Controller, formats: [:json]

  alias Plug.Conn
  alias SymphonyElixir.{Config, Orchestrator}
  alias SymphonyElixirWeb.Endpoint

  @max_clock_skew_ms 60_000

  @spec ingest(Conn.t(), map()) :: Conn.t()
  def ingest(conn, params) do
    with :ok <- require_enabled(),
         {:ok, secret} <- fetch_secret(),
         :ok <- verify_signature(conn, secret),
         :ok <- verify_timestamp(params),
         {:ok, refresh_payload} <- request_orchestrator_refresh() do
      json(conn, refresh_payload)
    else
      {:error, :webhook_disabled} ->
        error_response(conn, 404, "linear_webhook_disabled", "Linear webhook is not enabled")

      {:error, :missing_webhook_secret} ->
        error_response(
          conn,
          503,
          "linear_webhook_secret_missing",
          "Linear webhook secret is missing"
        )

      {:error, :invalid_signature} ->
        error_response(conn, 401, "invalid_signature", "Invalid Linear webhook signature")

      {:error, :invalid_timestamp} ->
        error_response(conn, 400, "invalid_payload", "Invalid Linear webhook timestamp")

      {:error, :stale_timestamp} ->
        error_response(conn, 401, "stale_timestamp", "Linear webhook timestamp is outside tolerance")

      {:error, :orchestrator_unavailable} ->
        error_response(conn, 503, "orchestrator_unavailable", "Orchestrator is unavailable")
    end
  end

  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    error_response(conn, 405, "method_not_allowed", "Method not allowed")
  end

  defp require_enabled do
    if Config.linear_webhook_enabled?(), do: :ok, else: {:error, :webhook_disabled}
  end

  defp fetch_secret do
    case Config.linear_webhook_secret() do
      secret when is_binary(secret) and secret != "" -> {:ok, secret}
      _ -> {:error, :missing_webhook_secret}
    end
  end

  defp verify_signature(conn, secret) do
    received_signature = conn |> Conn.get_req_header("linear-signature") |> List.first()
    raw_body = Map.get(conn.assigns, :raw_body, "")
    expected_signature = :crypto.mac(:hmac, :sha256, secret, raw_body) |> Base.encode16(case: :lower)

    if secure_compare_signatures(received_signature, expected_signature) do
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp verify_timestamp(%{"webhookTimestamp" => timestamp}) do
    with {:ok, timestamp_ms} <- parse_millisecond_timestamp(timestamp),
         true <- timestamp_within_tolerance?(timestamp_ms) do
      :ok
    else
      :error -> {:error, :invalid_timestamp}
      false -> {:error, :stale_timestamp}
    end
  end

  defp verify_timestamp(_params), do: {:error, :invalid_timestamp}

  defp parse_millisecond_timestamp(value) when is_integer(value), do: {:ok, value}

  defp parse_millisecond_timestamp(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> {:ok, parsed}
      _ -> :error
    end
  end

  defp parse_millisecond_timestamp(_value), do: :error

  defp timestamp_within_tolerance?(timestamp_ms) when is_integer(timestamp_ms) do
    now_ms = System.system_time(:millisecond)
    abs(now_ms - timestamp_ms) <= @max_clock_skew_ms
  end

  defp secure_compare_signatures(received_signature, expected_signature)
       when is_binary(received_signature) do
    normalized_received_signature = received_signature |> String.trim() |> String.downcase()

    byte_size(normalized_received_signature) == byte_size(expected_signature) and
      Plug.Crypto.secure_compare(normalized_received_signature, expected_signature)
  end

  defp secure_compare_signatures(_received_signature, _expected_signature), do: false

  defp request_orchestrator_refresh do
    case Orchestrator.request_refresh(orchestrator()) do
      :unavailable ->
        {:error, :orchestrator_unavailable}

      refresh_payload when is_map(refresh_payload) ->
        {:ok,
         refresh_payload
         |> Map.put(:source, "linear_webhook")
         |> Map.update(:requested_at, nil, &to_iso8601/1)}
    end
  end

  defp to_iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp to_iso8601(value), do: value

  defp error_response(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(%{error: %{code: code, message: message}})
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end
end
