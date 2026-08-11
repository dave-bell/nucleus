defmodule NucleusWeb.ScopeHookDemoLive do
  @moduledoc """
  A minimal LiveView for exercising `NucleusWeb.ScopeHook` in isolation,
  without depending on EN-7's router `live_session` wiring (not landed yet).

  Declares `on_mount {NucleusWeb.ScopeHook, :assign}` directly on the
  LiveView module. At mount time this has the same effect as EN-7 attaching
  the hook via `live_session ..., on_mount: ...` in the router — the hook
  itself does not know or care which one attached it.

  Renders through `Layouts.app`, the same layout every real page will use,
  so `test/nucleus_web/live/scope_hook_test.exs` can assert on the actual
  rendered output rather than on the hook's assign alone.
  """

  use NucleusWeb, :live_view

  on_mount {NucleusWeb.ScopeHook, :assign}

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <p id="scope-hook-demo-user">{Nucleus.Scope.audit_user(@current_scope)}</p>
      <p id="scope-hook-demo-source-ip">{@current_scope.source_ip}</p>
    </Layouts.app>
    """
  end
end
