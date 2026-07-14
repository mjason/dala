defmodule DalaWeb.VersionController do
  use DalaWeb, :controller

  @moduledoc """
  `GET /version` — the running server version as plain text.

  Public on purpose: after a Phoenix-socket reconnect the SPA compares this
  against the version embedded in its page meta (`dala-version`) to detect
  a server upgrade underneath a long-lived tab and offer a reload. The
  version string is not a secret — the unauthenticated sign-in page already
  serves the same fingerprinted assets.
  """

  def show(conn, _params) do
    text(conn, to_string(Application.spec(:dala, :vsn)))
  end
end
