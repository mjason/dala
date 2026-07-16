defmodule Dala.Terminal.AttachmentsTest do
  use ExUnit.Case, async: false

  setup do
    root =
      Path.join(System.tmp_dir!(), "dala-attachments-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    previous_data_dir = Application.fetch_env!(:dala, :data_dir)
    previous_limits = Application.get_env(:dala, :file_limits, %{})
    Application.put_env(:dala, :data_dir, root)

    on_exit(fn ->
      Application.put_env(:dala, :data_dir, previous_data_dir)
      Application.put_env(:dala, :file_limits, previous_limits)
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "cleanup removes expired directories but preserves fresh ones", %{root: root} do
    stale = Path.join(root, "stale")
    fresh = Path.join(root, "fresh")
    File.mkdir_p!(stale)
    File.mkdir_p!(fresh)
    now = System.os_time(:second)
    File.touch!(stale, now - 25 * 60 * 60)

    Dala.Terminal.Attachments.cleanup_expired(root, now)

    refute File.exists?(stale)
    assert File.dir?(fresh)
  end

  test "validate_path rejects directories and symlinks", %{root: root} do
    regular = Path.join(root, "regular.txt")
    link = Path.join(root, "link.txt")
    File.write!(regular, "x")
    File.ln_s!(regular, link)

    assert {:ok, ^regular} = Dala.Terminal.Attachments.validate_path(regular)
    assert {:error, directory_error} = Dala.Terminal.Attachments.validate_path(root)
    assert directory_error =~ "not a regular file"
    assert {:error, link_error} = Dala.Terminal.Attachments.validate_path(link)
    assert link_error =~ "not a regular file"
  end

  test "browser uploads enforce per-file and managed-storage quotas", %{root: root} do
    source = Path.join(root, "source.bin")
    File.write!(source, "xx")

    upload = %Plug.Upload{
      path: source,
      filename: "source.bin",
      content_type: "application/octet-stream"
    }

    Application.put_env(:dala, :file_limits, %{
      browser_attachment_bytes: 1,
      managed_attachment_bytes: 10
    })

    assert {:error, message} = Dala.Terminal.Attachments.store_upload(upload)
    assert message =~ "too large"
    assert message =~ "1 bytes"

    Application.put_env(:dala, :file_limits, %{
      browser_attachment_bytes: 10,
      managed_attachment_bytes: 1
    })

    assert {:error, message} = Dala.Terminal.Attachments.store_upload(upload)
    assert message =~ "storage limit exceeded"
  end
end
