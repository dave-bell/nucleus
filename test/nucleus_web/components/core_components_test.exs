defmodule NucleusWeb.CoreComponentsTest do
  use NucleusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias NucleusWeb.CoreComponents

  defp doc(html), do: LazyHTML.from_fragment(html)

  describe "modal/1" do
    @tag :unit
    test "renders role=\"dialog\" and aria-modal" do
      html = render_component(&CoreComponents.modal/1, modal_assigns())

      dialog = doc(html) |> LazyHTML.query(~s([role="dialog"][aria-modal="true"]))

      assert LazyHTML.attribute(dialog, "id") == ["confirm-modal-container"]
    end

    @tag :unit
    test "renders backdrop and close controls with stable ids" do
      html = render_component(&CoreComponents.modal/1, modal_assigns())
      d = doc(html)

      # The outer full-screen element doubles as the backdrop — clicking it
      # (outside the modal-box) triggers phx-click-away.
      assert LazyHTML.query(d, "#confirm-modal") |> LazyHTML.attribute("data-cancel") != []
      assert LazyHTML.query(d, "#confirm-modal-close") |> LazyHTML.attribute("phx-click") != []
    end

    @tag :unit
    test "renders the title slot when given" do
      html =
        render_component(
          &CoreComponents.modal/1,
          modal_assigns(title: [%{inner_block: fn _, _ -> "Are you sure?" end}])
        )

      assert doc(html) |> LazyHTML.query("#confirm-modal-title") |> LazyHTML.text() =~
               "Are you sure?"
    end
  end

  defp modal_assigns(overrides \\ []) do
    Keyword.merge(
      [id: "confirm-modal", inner_block: [%{inner_block: fn _, _ -> "Modal content" end}]],
      overrides
    )
  end

  describe "copy_button/1" do
    @tag :unit
    test "renders the colocated hook attribute, a unique id, and the value in a data attribute" do
      html = render_component(&CoreComponents.copy_button/1, id: "copy-arn", value: "arn:aws:1")

      button = doc(html) |> LazyHTML.query("#copy-arn")

      assert [hook] = LazyHTML.attribute(button, "phx-hook")
      assert hook =~ "CopyButton"
      assert LazyHTML.attribute(button, "data-value") == ["arn:aws:1"]
      assert LazyHTML.attribute(button, "id") == ["copy-arn"]
    end
  end

  describe "empty_state/1" do
    @tag :unit
    test "renders its action slot when given" do
      html =
        render_component(&CoreComponents.empty_state/1, %{
          id: "no-secrets",
          message: "No secrets yet",
          action: [%{inner_block: fn _, _ -> "Create secret" end}]
        })

      d = doc(html)
      assert LazyHTML.text(d) =~ "No secrets yet"
      assert LazyHTML.text(d) =~ "Create secret"
    end

    @tag :unit
    test "omits the action wrapper when no action slot is given" do
      html =
        render_component(&CoreComponents.empty_state/1, %{
          id: "no-secrets",
          message: "No secrets yet",
          action: []
        })

      d = doc(html)
      assert LazyHTML.text(d) =~ "No secrets yet"
      assert LazyHTML.query(d, "#no-secrets > div") |> Enum.to_list() == []
    end
  end

  describe "badge/1" do
    @tag :unit
    test "renders each variant" do
      for variant <- ~w(neutral info success warning error) do
        html =
          render_component(&CoreComponents.badge/1, %{
            variant: variant,
            inner_block: [%{inner_block: fn _, _ -> "Active" end}]
          })

        badge = doc(html) |> LazyHTML.query(".badge")
        assert LazyHTML.attribute(badge, "class") |> Enum.at(0) =~ "badge-#{variant}"
      end
    end
  end

  describe "card/1" do
    @tag :unit
    test "renders its content inside a card" do
      html =
        render_component(&CoreComponents.card/1, %{
          inner_block: [%{inner_block: fn _, _ -> "Panel content" end}]
        })

      assert doc(html) |> LazyHTML.text() =~ "Panel content"
    end
  end
end
