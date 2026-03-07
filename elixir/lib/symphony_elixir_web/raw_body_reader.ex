defmodule SymphonyElixirWeb.RawBodyReader do
  @moduledoc false

  alias Plug.Conn

  @spec read_body(Conn.t(), keyword()) :: {:ok, binary(), Conn.t()} | {:more, binary(), Conn.t()}
  def read_body(conn, opts) do
    case Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, body, Conn.assign(conn, :raw_body, body)}

      {:more, body, conn} ->
        read_remaining_body(conn, opts, [body])
    end
  end

  defp read_remaining_body(conn, opts, chunks) do
    case Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        full_body = [Enum.reverse(chunks), body] |> IO.iodata_to_binary()
        {:ok, full_body, Conn.assign(conn, :raw_body, full_body)}

      {:more, body, conn} ->
        read_remaining_body(conn, opts, [body | chunks])
    end
  end
end
