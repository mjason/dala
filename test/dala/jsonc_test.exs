defmodule Dala.JsoncTest do
  use ExUnit.Case, async: true

  alias Dala.Jsonc

  defp decode!(body), do: body |> Jsonc.strip() |> Jason.decode!()

  describe "strip/1" do
    test "plain JSON passes through unchanged" do
      body = ~s({"a": [1, 2], "b": "text"})
      assert Jsonc.strip(body) == body
    end

    test "removes // line comments" do
      body = """
      {
        // a comment
        "a": 1 // trailing comment
      }
      """

      assert decode!(body) == %{"a" => 1}
    end

    test "removes /* */ block comments, including multi-line ones" do
      body = """
      {
        /* one
           spanning
           lines */
        "a": /* inline */ 1
      }
      """

      assert decode!(body) == %{"a" => 1}
    end

    test "keeps comment-looking sequences inside strings" do
      body = ~s({"url": "https://example.com", "glob": "/* keep */"})
      assert decode!(body) == %{"url" => "https://example.com", "glob" => "/* keep */"}
    end

    test "handles escaped quotes inside strings" do
      body = ~s({"a": "say \\"hi\\" // not a comment"})
      assert decode!(body) == %{"a" => ~s(say "hi" // not a comment)}
    end

    test "removes trailing commas in objects and arrays" do
      body = """
      {
        "list": [1, 2, 3,],
        "map": {"k": "v",},
      }
      """

      assert decode!(body) == %{"list" => [1, 2, 3], "map" => %{"k" => "v"}}
    end

    test "line comments end at the newline, keeping the next line intact" do
      body = "{\n\"a\": 1, // c\n\"b\": 2\n}"
      assert decode!(body) == %{"a" => 1, "b" => 2}
    end

    test "survives UTF-8 content" do
      body = ~s({"prompt": "数据库调优 // 不是注释"} // 注释)
      assert decode!(body) == %{"prompt" => "数据库调优 // 不是注释"}
    end
  end
end
