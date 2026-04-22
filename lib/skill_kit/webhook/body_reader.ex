defmodule SkillKit.Webhook.BodyReader do
  @moduledoc """
  `Plug.Parsers` body-reader callback that stashes the raw request body
  in `conn.assigns.raw_body` before handing it off to the parser.

  Signature verification (HMAC over the raw bytes) can't run against a
  parsed body — by the time `Plug.Parsers` decodes the JSON, the exact
  byte sequence is gone. This reader captures the bytes first.

  Wire it up in the host app's Plug pipeline:

      plug Plug.Parsers,
        parsers: [:json, :urlencoded],
        body_reader: {SkillKit.Webhook.BodyReader, :read_body, []},
        json_decoder: Jason
  """

  @doc """
  Reads the request body and appends the chunk to `conn.assigns.raw_body`.

  Returns `{:ok, body, conn}` when the body has been fully read, or
  `{:more, partial, conn}` if more bytes remain — matching the
  `Plug.Conn.read_body/2` contract that `Plug.Parsers` expects.
  """
  @spec read_body(Plug.Conn.t(), Plug.opts()) ::
          {:ok, binary(), Plug.Conn.t()}
          | {:more, binary(), Plug.Conn.t()}
          | {:error, term()}
  def read_body(%Plug.Conn{} = conn, opts) do
    conn
    |> Plug.Conn.read_body(opts)
    |> stash_chunk(conn)
  end

  defp stash_chunk({:ok, body, conn}, original), do: {:ok, body, accumulate(original, conn, body)}

  defp stash_chunk({:more, partial, conn}, original),
    do: {:more, partial, accumulate(original, conn, partial)}

  defp stash_chunk({:error, _} = err, _original), do: err

  defp accumulate(original, conn, chunk) do
    existing = Map.get(original.assigns, :raw_body, "")
    Plug.Conn.assign(conn, :raw_body, existing <> chunk)
  end
end
