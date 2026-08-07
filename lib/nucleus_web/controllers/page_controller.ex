defmodule NucleusWeb.PageController do
  use NucleusWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
