defmodule DalaWeb.ChannelCase do
  @moduledoc """
  This module defines the test case to be used by channel tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import DalaWeb.ChannelCase

      @endpoint DalaWeb.Endpoint
    end
  end

  setup tags do
    Dala.DataCase.setup_sandbox(tags)
    :ok
  end
end
