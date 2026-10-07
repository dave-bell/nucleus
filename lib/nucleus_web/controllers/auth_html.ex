defmodule NucleusWeb.AuthHTML do
  @moduledoc """
  The pages an unauthenticated visitor sees (`AUTH-A01`, `AUTH-A04`): sign-in,
  generic failure, and access denied.

  They do not use `Layouts.app`: that shell needs a signed-in user's scope, the
  environment list and the identity menu, none of which exist before sign-in.
  They share the root layout and a minimal centred card.

  The failure page is deliberately generic. Why a sign-in failed (a state
  mismatch, a bad token) is for the audit trail, not for the person at the
  keyboard.
  """

  use NucleusWeb, :html

  embed_templates "auth_html/*"

  attr :title, :string, required: true
  attr :id, :string, required: true
  slot :inner_block, required: true

  defp auth_card(assigns) do
    ~H"""
    <main class="min-h-screen grid place-items-center bg-base-200 p-6">
      <div id={@id} class="card w-full max-w-sm bg-base-100 shadow-xl">
        <div class="card-body items-center text-center gap-4">
          <span class="text-sm font-semibold uppercase tracking-widest text-base-content/60">
            Nucleus
          </span>
          <h1 class="card-title text-2xl">{@title}</h1>
          {render_slot(@inner_block)}
        </div>
      </div>
    </main>
    """
  end
end
