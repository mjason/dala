defmodule Dala.Updater.Release do
  @moduledoc """
  Pure release-selection logic behind `Dala.Updater`: version comparison,
  server-release filtering and asset lookup, split out so it can be tested
  without talking to GitHub.
  """

  @asset_suffix "linux-x86_64.tar.gz"

  def asset_suffix, do: @asset_suffix

  @doc "True when `latest` and `current` parse as versions and `latest` is strictly newer."
  def newer?(latest, current) do
    match?({:ok, _}, Version.parse(latest)) and
      match?({:ok, _}, Version.parse(current)) and
      Version.compare(latest, current) == :gt
  end

  @doc """
  True for a published SERVER release. Server and desktop-client releases
  share the repo but use distinct tag prefixes (`v*` vs `client-v*`), and
  drafts/prereleases don't count.
  """
  def server_release?(release) do
    is_binary(release["tag_name"]) and release["tag_name"] =~ ~r/^v\d/ and
      release["draft"] != true and release["prerelease"] != true
  end

  @doc "Download URL of the release's server tarball asset."
  def asset_url(%{"assets" => assets, "tag_name" => tag} = _release) when is_list(assets) do
    case Enum.find(assets, &String.ends_with?(&1["name"] || "", @asset_suffix)) do
      %{"browser_download_url" => url} -> {:ok, url}
      _ -> {:error, "release #{tag} has no #{@asset_suffix} asset"}
    end
  end

  def asset_url(_), do: {:error, "malformed release payload"}
end
