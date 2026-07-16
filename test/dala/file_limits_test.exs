defmodule Dala.FileLimitsTest do
  use ExUnit.Case, async: false

  test "ships development-system defaults for every transfer surface" do
    assert Dala.FileLimits.drawer_upload_bytes() == 2 * 1024 * 1024 * 1024
    assert Dala.FileLimits.browser_attachment_bytes() == 512 * 1024 * 1024
    assert Dala.FileLimits.mcp_attachment_bytes() == 64 * 1024 * 1024
    assert Dala.FileLimits.managed_attachment_bytes() == 5 * 1024 * 1024 * 1024
    assert Dala.FileLimits.text_write_bytes() == 50 * 1024 * 1024
    assert Dala.FileLimits.preview_default_bytes() == 1024 * 1024
    assert Dala.FileLimits.preview_max_bytes() == 16 * 1024 * 1024
  end

  test "derives bounded parser budgets and human-readable quota messages" do
    assert Dala.FileLimits.multipart_request_bytes("/files/upload") >
             Dala.FileLimits.drawer_upload_bytes()

    assert Dala.FileLimits.json_request_bytes("/mcp") >
             Dala.FileLimits.mcp_attachment_bytes()

    assert Dala.FileLimits.request_too_large_message("/files/attachment") =~ "512 MB"
    assert Dala.FileLimits.format(5 * 1024 * 1024 * 1024) == "5 GB"
  end
end
