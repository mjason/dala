defmodule Dala.Updater.ReleaseTest do
  use ExUnit.Case, async: true

  alias Dala.Updater.Release

  describe "platform/2" do
    test "maps supported native targets to release asset names" do
      assert Release.platform({:unix, :linux}, "x86_64-pc-linux-gnu") == "linux-x86_64"
      assert Release.platform({:unix, :darwin}, "aarch64-apple-darwin") == "macos-arm64"
      assert Release.platform({:unix, :darwin}, "arm64-apple-darwin") == "macos-arm64"
      assert Release.platform({:win32, :nt}, "x86_64-pc-windows") == "unsupported"
    end
  end

  describe "newer?/2" do
    test "table: version pairs" do
      cases = [
        # {latest, current, expected}
        {"1.2.3", "1.2.2", true},
        {"2.0.0", "1.9.9", true},
        {"1.2.3", "1.2.3", false},
        {"1.2.2", "1.2.3", false},
        {"1.0.0", "1.0.0-rc.1", true},
        {"1.0.0-rc.1", "1.0.0", false},
        # malformed on either side is never "newer"
        {"garbage", "1.0.0", false},
        {"1.0.0", "garbage", false},
        {"", "", false},
        {"1.2", "1.1", false},
        {"v1.2.3", "1.2.2", false}
      ]

      for {latest, current, expected} <- cases do
        assert Release.newer?(latest, current) == expected,
               "newer?(#{inspect(latest)}, #{inspect(current)}) expected #{expected}"
      end
    end
  end

  describe "server_release?/1" do
    test "table: tag prefix, draft and prerelease filtering" do
      cases = [
        {%{"tag_name" => "v1.2.3"}, true},
        {%{"tag_name" => "v1.2.3", "draft" => false, "prerelease" => false}, true},
        # client builds share the repo under another prefix
        {%{"tag_name" => "client-v1.2.3"}, false},
        # drafts and prereleases don't count
        {%{"tag_name" => "v1.2.3", "draft" => true}, false},
        {%{"tag_name" => "v1.2.3", "prerelease" => true}, false},
        # tag must be v<digit>…
        {%{"tag_name" => "version-1"}, false},
        {%{"tag_name" => "v"}, false},
        {%{"tag_name" => nil}, false},
        {%{}, false}
      ]

      for {release, expected} <- cases do
        assert Release.server_release?(release) == expected,
               "server_release?(#{inspect(release)}) expected #{expected}"
      end
    end
  end

  describe "asset_url/1" do
    test "finds the asset matching the server tarball suffix" do
      release = %{
        "tag_name" => "v1.2.3",
        "assets" => [
          %{"name" => "dala-client-v1.2.3-win.zip", "browser_download_url" => "http://x/win"},
          %{
            "name" => "dala-v1.2.3-#{Release.asset_suffix()}",
            "browser_download_url" => "http://x/linux"
          }
        ]
      }

      assert Release.asset_url(release) == {:ok, "http://x/linux"}
    end

    test "selects the macOS arm64 asset explicitly" do
      release = %{
        "tag_name" => "v1.2.3",
        "assets" => [
          %{
            "name" => "dala-v1.2.3-linux-x86_64.tar.gz",
            "browser_download_url" => "http://x/linux"
          },
          %{
            "name" => "dala-v1.2.3-macos-arm64.tar.gz",
            "browser_download_url" => "http://x/macos"
          }
        ]
      }

      assert Release.asset_url(release, "macos-arm64") == {:ok, "http://x/macos"}
    end

    test "errors when no asset matches the suffix" do
      release = %{"tag_name" => "v1.2.3", "assets" => [%{"name" => "readme.txt"}]}
      assert {:error, message} = Release.asset_url(release)
      assert message =~ "v1.2.3"
      assert message =~ Release.asset_suffix()
    end

    test "tolerates assets without a name" do
      release = %{"tag_name" => "v1.2.3", "assets" => [%{}]}
      assert {:error, _message} = Release.asset_url(release)
    end

    test "errors on malformed payloads" do
      assert Release.asset_url(%{}) == {:error, "malformed release payload"}

      assert Release.asset_url(%{"tag_name" => "v1", "assets" => "nope"}) ==
               {:error, "malformed release payload"}

      assert Release.asset_url(nil) == {:error, "malformed release payload"}
    end
  end
end
