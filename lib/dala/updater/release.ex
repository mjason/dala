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

  def platform({:win32, :nt}, architecture) do
    if String.contains?(to_string(architecture), "x86_64"),
      do: "windows-x86_64",
      else: "unsupported"
  end

  def platform(_os_type, _architecture), do: "unsupported"

  def asset_suffix(platform \\ platform())
  def asset_suffix("windows-x86_64"), do: "windows-x86_64.zip"
  def asset_suffix(platform), do: "#{platform}.tar.gz"

  def release_executable("windows-x86_64"), do: "bin/dala.bat"
  def release_executable(_platform), do: "bin/dala"

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
  def server_release?(release) when is_map(release) do
    is_binary(release["tag_name"]) and release["tag_name"] =~ ~r/^v\d/ and
      release["draft"] != true and release["prerelease"] != true
  end

  def server_release?(_release), do: false

  @doc "Download URL of the release's server tarball asset for this platform."
  def asset_url(release, platform \\ platform())

  def asset_url(%{"assets" => assets, "tag_name" => tag}, platform) when is_list(assets) do
    suffix = asset_suffix(platform)

    case Enum.find(assets, fn asset ->
           name = asset_name(asset)
           is_binary(name) and String.ends_with?(name, suffix)
         end) do
      %{"browser_download_url" => url} when is_binary(url) -> {:ok, url}
      _ -> {:error, "release #{tag} has no #{suffix} asset"}
    end
  end

  def asset_url(_release, _platform), do: {:error, "malformed release payload"}

  @doc "Download URLs for a server archive and its published SHA-256 file."
  def verified_asset_urls(release, platform \\ platform())

  def verified_asset_urls(%{"assets" => assets, "tag_name" => tag}, platform)
      when is_list(assets) do
    suffix = asset_suffix(platform)

    with %{"name" => name, "browser_download_url" => archive_url} <-
           Enum.find(assets, fn asset ->
             name = asset_name(asset)
             is_binary(name) and String.ends_with?(name, suffix)
           end),
         true <- is_binary(archive_url),
         %{"browser_download_url" => checksum_url} <-
           Enum.find(assets, fn asset -> asset_name(asset) == name <> ".sha256" end),
         true <- is_binary(checksum_url) do
      {:ok, %{archive: archive_url, checksum: checksum_url}}
    else
      nil -> {:error, "release #{tag} is missing #{suffix} or its SHA-256 asset"}
      false -> {:error, "release #{tag} has malformed #{suffix} assets"}
      _ -> {:error, "release #{tag} has malformed #{suffix} assets"}
    end
  end

  def verified_asset_urls(_release, _platform), do: {:error, "malformed release payload"}

  @doc "Parse the first lowercase or uppercase SHA-256 token from a checksum file."
  def checksum_sha256(body) when is_binary(body) do
    case body |> String.trim() |> String.split(~r/\s+/, parts: 2) do
      [hash | _] when byte_size(hash) == 64 ->
        if String.match?(hash, ~r/\A[0-9a-fA-F]{64}\z/),
          do: {:ok, String.downcase(hash)},
          else: {:error, "malformed SHA-256 checksum"}

      _ ->
        {:error, "malformed SHA-256 checksum"}
    end
  end

  def checksum_sha256(_body), do: {:error, "malformed SHA-256 checksum"}

  defp asset_name(%{"name" => name}) when is_binary(name), do: name
  defp asset_name(_asset), do: nil
end
