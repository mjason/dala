defmodule DalaWeb.FileDownloadTokenTest do
  use ExUnit.Case, async: true

  alias DalaWeb.FileDownloadToken

  test "a token validates for its own path and nothing else" do
    token = FileDownloadToken.sign("/home/me/report.csv")

    assert FileDownloadToken.valid_for?(token, "/home/me/report.csv")
    refute FileDownloadToken.valid_for?(token, "/home/me/other.csv")
    refute FileDownloadToken.valid_for?(token, "/etc/passwd")
  end

  test "a tampered or non-token string never validates" do
    refute FileDownloadToken.valid_for?("garbage", "/home/me/report.csv")
    refute FileDownloadToken.valid_for?("", "/home/me/report.csv")

    token = FileDownloadToken.sign("/home/me/report.csv")
    refute FileDownloadToken.valid_for?(token <> "x", "/home/me/report.csv")
  end

  test "an expired token is rejected" do
    # Sign with a timestamp older than max_age so verify() sees it expired.
    stale =
      Phoenix.Token.sign(DalaWeb.Endpoint, "file download v1", "/home/me/report.csv",
        signed_at: System.system_time(:second) - (FileDownloadToken.max_age() + 60)
      )

    refute FileDownloadToken.valid_for?(stale, "/home/me/report.csv")
  end

  test "non-binary inputs are safely false" do
    refute FileDownloadToken.valid_for?(nil, "/x")
    refute FileDownloadToken.valid_for?(123, "/x")
  end
end
