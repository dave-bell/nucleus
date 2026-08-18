# ADR-0012: Secret Reveal in a Modal, and Icon-Only Copy Affordances

## Status

Accepted — 2026-08-18

Decided as a direct UI correction to SEC-S4's implementation, on user report
rather than a GitHub issue — the row was unusable at real path/ARN/value
lengths. Supersedes two of `0011-secret-reveal-stream-reinsertion-and-audit-test-fallback.md`'s
mechanics (the `%{key => Secret.t()}` shape and the reveal/hide
`stream_insert/3`) while keeping its guarantee. Builds on
`0006-application-shell-and-live-session-composition.md` (daisyUI retained,
which is what makes `.modal` and `.tooltip` available) and
`0008-test-strategy.md` (the recorded browser-gap convention this ticket adds
to).

## Context

SEC-S3 and SEC-S4 shipped a Secrets table with six columns — Key, Path, ARN,
Last modified, Value, Actions — three copy buttons per row, and a revealed
value rendered inline in the Value cell. Two problems only visible against
real data:

1. **Every copy button carried its visible label.** "Copy path", "Copy ARN",
   and "Copy value" were text nodes inside the buttons, and the label was the
   widest part of each one. Three of them per row consumed more horizontal
   space than the values they sat beside, which were already truncated with
   `max-w-xs` to fit.
2. **The Value column had nowhere near enough room for a revealed value.** A
   connection string or a signing key is long. Rendered inline in a table
   cell it either wrapped the row to several lines or pushed everything else
   out of view. The column also cost width permanently, in every row,
   including the (overwhelmingly common) unrevealed case where all it showed
   was a mask.

Three questions had to be settled to fix this:

- Where does a revealed plaintext value actually go, if not a table cell?
- If it goes in a modal, `NucleusWeb.CoreComponents.modal/1` toggles
  visibility with daisyUI's `modal-open` **class** — which means the inner
  block is in the DOM, and readable in the page source, while the modal is
  "closed". Acceptable for SEC-A09's creation form; not acceptable for
  plaintext secret material.
- `SEC-A03` says "the control changes to 'Hide'" and `SEC-A04` says "the user
  activates 'Hide'". Behind a modal backdrop, a per-row Hide control is
  unreachable. What plays the part `SEC-A04` describes?

## Decision

### The label becomes a tooltip; the button becomes icon-only by default

`copy_button/1` no longer renders `<span>{@label}</span>`. The label still
reaches assistive technology through `aria-label`, still reaches the hook's
`aria-live` announcement through `data-label`, and now reaches a sighted user
through daisyUI's `.tooltip` + `data-tip` — CSS `content: attr(data-tip)` on
a pseudo-element, so the label text is never a DOM node competing for layout
width. daisyUI's `.tooltip` also matches `:has(:focus-visible)`, so the
tooltip appears on keyboard focus, not only hover.

The tooltip goes on a **wrapper `<span>`**, never on the button itself. The
button carries `phx-update="ignore"` (ADR-0011's companion decision, so the
hook's icon-swap state survives a patch), and hover/tooltip state on an
ignored element is exactly the kind of thing that stops surviving one.

A new `show_label` attribute opts the visible text back in for somewhere with
room for it, and suppresses the tooltip when it does — a tooltip restating
text already on screen is noise. The reveal modal's action row is the only
current caller.

### The Value column is deleted outright — plaintext *and* mask

Not replaced with a narrower mask, or a truncated preview. Removed. A mask is
only ever a promise that nothing leaked, and one that has to keep being
careful not to encode the real value's length — SEC-S2 wrote a test
specifically to hold that line. A column that does not exist makes no promise
to break and costs no width. The reveal control in the Actions column is the
only affordance the value needs.

### A revealed value renders in a modal that only exists while it is open

`<.modal>` is wrapped in `:if={@revealed}` and passed `show={true}`, rather
than left permanently mounted and toggled with `modal-open`. This is a
deliberate departure from how `modal/1` was designed to be used, for one
reason: a class toggle only stops markup being *painted*. The plaintext would
sit in the DOM, and in the page source, from the moment the modal existed.
Wrapping it means the value is written into a payload only when the modal is
actually drawn, and the element — with the value inside it — is **removed**
on dismissal, not merely unpainted. `show={true}` follows from that: an
element that only exists while open is always inserted already-open, via the
component's `phx-mounted`.

`modal/1`'s own doc now records this as a supported second usage, so
`SEC-S6`'s creation form does not have to rediscover which shape it wants.

### `:revealed` narrows from a map to a single secret, and nothing re-streams

ADR-0011 made `:revealed` a `%{key => Secret.t()}` map so several rows could
be revealed at once, and re-streamed each row on reveal and hide because the
row's own markup depended on that state. A modal shows one secret; the map
becomes a single `Secret` or `nil`. Because no row markup depends on
`@revealed` any more, `AGENTS.md`'s stream-re-insertion rule no longer
applies to a reveal at all, and both handlers drop their `stream_insert/3`.
`to_secret_ref/1` and `dom_id/1`'s `%Secret{}` clause go with them.

ADR-0011's actual guarantee is strengthened, not weakened: the stream still
only ever carries `SecretRef` structs with no `value` field, and now it is
never re-inserted for a reveal, so a plaintext value cannot reach stream
state even by a mistake in the conversion that no longer exists.

### The row's control always reads "View"; the modal's dismiss controls are `SEC-A04`'s "Hide"

`SEC-A03`'s "the control changes to 'Hide'" is not implemented literally.
While the modal is open, the row is behind a backdrop and its control cannot
be clicked, so a "Hide" label there would be state nobody can act on — and
the moment the modal is dismissed the state is gone anyway. The modal's four
dismissal routes (the X, the Close button, Escape, a backdrop click) are the
hide affordance, and they satisfy what `SEC-A04` actually asks for: the value
is no longer displayed. `@tag action: "SEC-A04"` is claimed on that basis.

### Close pushes `"hide"` directly; the other three routes go through `data-cancel`

`on_cancel={JS.push("hide")}` wires the X, Escape, and the backdrop, which
`modal/1` funnels through its own `data-cancel` attribute. The Close button
does **not** route through `data-cancel` — it pushes `"hide"` as a plain
event. It needs no client-side work that `phx-remove` does not already do
(removing the element runs the component's `hide_modal/2`, so `pop_focus`
restores focus by either path), and a plain event is one `render_click/1` a
test can actually drive, where a `JS.exec/2` command chain is not. That is
what lets `SEC-A04`'s outcome — plaintext leaves the DOM — be proven in
`Phoenix.LiveViewTest` at all, rather than joining Escape and the backdrop in
the browser-gap list.

## Consequences

### Positive

- The row fits: five columns, three icon-only buttons, and no permanently
  reserved space for a value almost never on screen.
- A revealed value gets a modal's width and its own scroll region, instead of
  a table cell's.
- Strictly less plaintext exposure than before. Previously a revealed value
  lived in a cell that stayed in the DOM until the user clicked Hide or
  navigated; now it exists only while a dialog is open, and at most one value
  exists at a time rather than one per revealed row.
- `SEC-A04`'s outcome is now proven by an executable test (the Close button)
  where before it was proven by a toggle click. The three JS-command routes
  are recorded gaps, not silent ones.
- `SEC-S6`'s creation form inherits both a documented modal shape and an
  icon-only/labelled copy button, with no new component work.

### Negative

- `SEC-A03`'s "control changes to 'Hide'" clause is not literally
  implemented, and the test that asserted it is gone. Anyone reconciling the
  wiki against the code will find this ADR and not an obvious answer in the
  template.
- Two more browser-only gaps (Escape, backdrop click) join the `SEC-A13` set
  in `living-notes.md`. They are wired identically to the X, which is itself
  only proven as wiring, so a `modal/1` regression in any of the three would
  not be caught until a driver exists.
- Reading a second secret is now two more clicks than before (dismiss, then
  reveal), where the old table allowed two values side by side. Nobody asked
  for side-by-side comparison, but it was possible and now is not.
- `modal/1` has two legitimate usages — mounted-and-toggled, and
  conditionally-rendered — and picking the wrong one for secret material is a
  silent leak rather than a visible bug. Mitigated only by documentation.

## Alternatives considered

**Keep the Value column, and truncate the revealed value with a "show full"
affordance.** Rejected — a truncated secret is worse than no secret: it looks
copyable and is not, which is the exact failure mode SEC-S3's `data-value`
truncation-guard test was written to prevent. It also keeps the column's
width cost in every unrevealed row.

**Keep `modal/1` mounted and rely on `modal-open` for visibility, as
designed.** Rejected — this is the whole reason the modal is conditional. The
plaintext would be present in the DOM and in view-source while the dialog was
closed, so "reveal" would stop meaning anything: the value would be there
from the first reveal until navigation, exactly the exposure the modal was
supposed to shorten.

**Fetch the value from a JS hook when the modal mounts, so the plaintext is
never in a LiveView payload at all.** Rejected — the value has to cross the
socket regardless, and this would add a second fetch path outside
`Nucleus.Secrets.reveal/3`, bypassing its key validation and its
`secret_viewed` audit emit. ADR-0007 is explicit that `Path.build/2` has a
single construction site; a second reveal path is the same mistake one layer
up. Conditional rendering achieves the stated goal — plaintext in the DOM
only while the dialog is drawn — without a second door into the store.

**Keep the per-row Hide toggle for literal `SEC-A03` conformance, and
re-stream rows as ADR-0011 does.** Rejected — it keeps `stream_insert/3` and
a `%{key => Secret.t()}` map alive to render a label that is behind a
backdrop, unclickable, and discarded on dismissal. Conformance to the letter
of the clause at the cost of dead UI and retained machinery.

**Use the native `title` attribute for the copy label instead of daisyUI's
tooltip.** Rejected — `title` has a ~1s browser-controlled delay, no styling,
and inconsistent screen-reader treatment alongside `aria-label`. The
neighbouring path/ARN spans already use `title` for their truncated text;
adding a second `title` on the button inside the same cell reads as one
tooltip fighting another.

## References

- `docs/adr/0011-secret-reveal-stream-reinsertion-and-audit-test-fallback.md`
  — the reveal mechanics this partially supersedes; its `SecretRef`-only
  stream guarantee is retained and strengthened
- `docs/adr/0010-secrets-listing-gate-collapse-and-dom-ids.md` — the
  ARN-hashed row ids the reveal control's id is still derived from
- `docs/adr/0008-test-strategy.md` — the recorded-browser-gap convention the
  Escape/backdrop/focus tests follow
- `docs/adr/0006-application-shell-and-live-session-composition.md` — daisyUI
  retained, which is what `.modal` and `.tooltip` depend on
- `docs/adr/0007-secrets-store-adapter.md` — the single-construction-site
  reasoning behind rejecting a client-side fetch path
- `AGENTS.md` — the stream re-insertion rule, and the
  colocated-hook/`phx-update="ignore"` rules the tooltip wrapper works around
- Wiki [Secrets](https://github.com/dave-bell/nucleus/wiki/Secrets)
  `SEC-A01`–`A05`, `SEC-A13`
