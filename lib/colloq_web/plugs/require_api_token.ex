defmodule ColloqWeb.Plugs.RequireApiToken do
  @moduledoc """
  Bearer-token auth for the external JSON API (`/api/v1`).

  These endpoints exist for webhook integrations and external services, so they
  must never be reachable by anonymous traffic — and they deliberately do NOT
  use the browser session: the `:api` pipeline has no CSRF protection, so any
  state-changing session endpoint here would be CSRF-able. External callers
  send `Authorization: Bearer <API_V1_TOKEN>`; the comparison is constant-time.

  Fail-closed: if `API_V1_TOKEN` is not configured, every request is rejected.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    expected = Application.get_env(:colloq, :api_v1_token)
    provided = bearer_token(conn)

    if is_binary(expected) and expected != "" and is_binary(provided) and
         Plug.Crypto.secure_compare(provided, expected) do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(401, ~s({"error":"unauthorized"}))
      |> halt()
    end
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> token
      _ -> nil
    end
  end
end
