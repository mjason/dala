defmodule Dala.Updater.Release do
  @moduledoc """
  Pure release-selection logic behind `Dala.Updater`: version comparison,
  server-release filtering and asset lookup, split out so it can be tested
  without talking to GitHub.
  """

  @doc "Native release platform for an OS/ERTS architecture pair."
  def platform(os_type \\ :os.type(), architecture \\ :erlang.system_info(:system_architecture))

  def platform({:unix, :linux}, architecture) do
    if String.contains?(to_string(architecture), "x86_64"),
      do: "linux-x86_64",
      else: "unsupported"
  end

  def platform({:unix, :darwin}, architecture) do
    arch = to_string(architecture)

    if String.contains?(arch, "aarch64") or String.contains?(arch, "arm64"),
      do: "macos-arm64",
      else: "unsupported"
  end

  def platform(_os_type, _architecture), do: "unsupported"

  def asset_suffix(platform \\ platform()), do: "#{platform}.tar.gz"

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

  @doc "Download URL of the release's server tarball asset for this platform."
  def asset_url(release, platform \\ platform())

  def asset_url(%{"assets" => assets, "tag_name" => tag}, platform) when is_list(assets) do
    suffix = asset_suffix(platform)

    case Enum.find(assets, &String.ends_with?(&1["name"] || "", suffix)) do
      %{"browser_download_url" => url} -> {:ok, url}
      _ -> {:error, "release #{tag} has no #{suffix} asset"}
    end
  end

  def asset_url(_release, _platform), do: {:error, "malformed release payload"}
end
