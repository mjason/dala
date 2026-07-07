defmodule DalaWeb.AshTypescriptRpcController do
  use DalaWeb, :controller

  def run(conn, params) do
    result = AshTypescript.Rpc.run_action(:dala, conn, params)
    json(conn, result)
  end

  def validate(conn, params) do
    result = AshTypescript.Rpc.validate_action(:dala, conn, params)
    json(conn, result)
  end
end
