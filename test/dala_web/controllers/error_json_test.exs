defmodule DalaWeb.ErrorJSONTest do
  use DalaWeb.ConnCase, async: true

  test "renders 404" do
    assert DalaWeb.ErrorJSON.render("404.json", %{}) == %{errors: %{detail: "Not Found"}}
  end

  test "renders 500" do
    assert DalaWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end

  test "renders a clear 413 quota error" do
    reason = DalaWeb.RequestTooLargeError.exception(path: "/files/upload")
    assert %{error: message} = DalaWeb.ErrorJSON.render("413.json", %{reason: reason})
    assert message =~ "2 GB"
  end
end
