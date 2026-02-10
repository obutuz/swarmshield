defmodule SwarmshieldWeb.PageController do
  use SwarmshieldWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
