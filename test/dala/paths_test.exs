defmodule Dala.PathsTest do
  use ExUnit.Case, async: true

  alias Dala.Paths

  defp tmp_dir!(context) do
    base =
      Dala.TestPlatform.normalize_path(
        Path.join(
          System.tmp_dir!(),
          "dala-paths-#{context}-#{System.unique_integer([:positive])}"
        )
      )

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    base
  end

  describe "expand_user/1" do
    test "expands a bare ~ to the home directory" do
      assert Dala.TestPlatform.same_path?(Paths.expand_user("~"), System.user_home())
    end

    test "expands ~/rest against the home directory" do
      assert Dala.TestPlatform.same_path?(
               Paths.expand_user("~/some/dir"),
               Path.join(System.user_home(), "some/dir")
             )
    end

    test "expands relative paths to absolute ones" do
      assert Paths.expand_user("foo/bar") == Path.expand("foo/bar")
      assert Path.type(Paths.expand_user("foo/bar")) == :absolute
    end

    test "normalizes absolute paths" do
      assert Paths.expand_user("/tmp/a/../b/.") == Path.expand("/tmp/b")
    end
  end

  describe "home/1" do
    test "joins a relative path under the home directory" do
      assert Paths.home(".config/thing") == Path.join(System.user_home(), ".config/thing")
    end
  end

  describe "comparison_key_for_os/2" do
    test "normalizes Windows separators and case deterministically" do
      assert Paths.comparison_key_for_os(~S(C:\Work\Project), {:win32, :nt}) ==
               "c:/work/project"

      assert Paths.comparison_key_for_os("c:/work/project", {:win32, :nt}) ==
               "c:/work/project"
    end

    test "uses Windows simple Unicode casing without full-case expansions" do
      assert Paths.comparison_key_for_os("safe/\u03c3", {:win32, :nt}) ==
               Paths.comparison_key_for_os("SAFE/\u03c2", {:win32, :nt})

      assert Paths.comparison_key_for_os("safe/\u1f80", {:win32, :nt}) ==
               Paths.comparison_key_for_os("SAFE/\u1f88", {:win32, :nt})

      refute Paths.comparison_key_for_os("safe/\u00df", {:win32, :nt}) ==
               Paths.comparison_key_for_os("SAFE/SS", {:win32, :nt})
    end

    test "preserves case on Unix" do
      assert Paths.comparison_key_for_os("/Work/Project", {:unix, :linux}) == "/Work/Project"
    end
  end

  describe "git_toplevel/1" do
    test "returns the repository toplevel from a nested directory" do
      repo = tmp_dir!("git")
      {_, 0} = System.cmd("git", ["init", "--quiet", repo])
      nested = Path.join(repo, "a/b")
      File.mkdir_p!(nested)

      # Compare via git's own report so symlinked temp dirs don't matter.
      assert Paths.git_toplevel(nested) == Paths.git_toplevel(repo)
      assert String.ends_with?(Paths.git_toplevel(nested), Path.basename(repo))
    end

    test "returns nil outside any repository" do
      dir = tmp_dir!("nogit")
      assert Paths.git_toplevel(dir) == nil
    end
  end

  describe "walk_up/2" do
    test "returns the first truthy result walking upward" do
      base = tmp_dir!("walk")
      File.mkdir_p!(Path.join(base, "a/b/c"))
      File.write!(Path.join(base, "a/marker"), "")

      found =
        Paths.walk_up(Path.join(base, "a/b/c"), fn dir ->
          path = Path.join(dir, "marker")
          if File.regular?(path), do: path
        end)

      assert Dala.TestPlatform.same_path?(found, Path.join(base, "a/marker"))
    end

    test "checks the starting directory itself" do
      base = tmp_dir!("walk-start")
      File.write!(Path.join(base, "marker"), "")

      assert Paths.walk_up(base, fn dir ->
               if File.regular?(Path.join(dir, "marker")), do: dir
             end) == base
    end

    test "stops at the git toplevel (inclusive) without escaping the repo" do
      base = tmp_dir!("walk-git")
      # marker ABOVE the repo must not be found from inside it
      File.write!(Path.join(base, "marker"), "")
      repo = Path.join(base, "repo")
      File.mkdir_p!(Path.join(repo, "sub"))
      {_, 0} = System.cmd("git", ["init", "--quiet", repo])

      assert Paths.walk_up(Path.join(repo, "sub"), fn dir ->
               if File.regular?(Path.join(dir, "marker")), do: dir
             end) == nil

      # but a marker AT the toplevel is found (the stop dir is checked)
      File.write!(Path.join(repo, "marker"), "")

      found =
        Paths.walk_up(Path.join(repo, "sub"), fn dir ->
          if File.regular?(Path.join(dir, "marker")), do: dir
        end)

      assert File.regular?(Path.join(found, "marker"))
      assert File.dir?(Path.join(found, ".git"))
    end

    @tag skip: not Dala.TestPlatform.windows?()
    test "recognizes the git boundary across Windows short and long path aliases" do
      base =
        Path.join([
          System.fetch_env!("LOCALAPPDATA"),
          "Temp",
          "dala-paths-walk-git-short-path-#{System.unique_integer([:positive])}"
        ])

      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf!(base) end)
      File.write!(Path.join(base, "marker"), "")
      repo = Path.join(base, "repository-long-name")
      File.mkdir_p!(Path.join(repo, "sub"))
      {_, 0} = System.cmd("git", ["init", "--quiet", repo])

      command = "for %I in (\"#{repo}\") do @echo %~sI"
      {short_repo, 0} = System.cmd("cmd.exe", ["/D", "/S", "/C", command])

      assert Paths.walk_up(Path.join(String.trim(short_repo), "sub"), fn dir ->
               if File.regular?(Path.join(dir, "marker")), do: dir
             end) == nil
    end

    test "returns nil at the filesystem root when nothing matches" do
      base = tmp_dir!("walk-none")
      assert Paths.walk_up(base, fn _dir -> nil end) == nil
    end
  end
end
