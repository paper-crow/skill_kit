---
name: phoenix_conventions
description: "Reference guide for Phoenix/LiveView code generation — conventions, patterns, and anti-patterns"
---
When generating Phoenix application code, follow these conventions strictly. This is a reference skill — activate it before writing any Elixir, Phoenix, or LiveView code.

## Project Structure

```
lib/
  my_app/                    # Business logic (contexts)
    accounts.ex              # Context module
    accounts/
      user.ex                # Schema
      user_token.ex          # Schema
  my_app_web/                # Web layer
    components/              # Function components (.ex with ~H sigils)
    controllers/             # Traditional controllers (rare — prefer LiveView)
    live/                    # LiveView modules + colocated templates
      dashboard_live.ex
      dashboard_live.html.heex
    layouts/                 # Root and app layouts
    router.ex
    endpoint.ex
```

## Contexts

Contexts are the public API for business logic. They are the boundary between web and domain.

- One context per bounded domain (Accounts, Catalog, Orders — not UserHelpers, Utilities)
- Context functions take and return plain data (structs, maps, lists) — never conn or socket
- Context functions handle their own Repo calls — callers never touch Repo directly
- Name context functions for what they do, not how: `Accounts.register_user/1` not `Accounts.insert_user_changeset/1`
- Return `{:ok, result}` or `{:error, changeset}` from mutations
- Return data directly from reads (not wrapped in ok tuples)

```elixir
defmodule MyApp.Catalog do
  alias MyApp.Catalog.Product
  alias MyApp.Repo

  def list_products do
    Repo.all(Product)
  end

  def get_product!(id) do
    Repo.get!(Product, id)
  end

  def create_product(attrs) do
    %Product{}
    |> Product.changeset(attrs)
    |> Repo.insert()
  end
end
```

## Schemas

- One schema per database table
- Schemas live inside their context directory
- Changesets are defined on the schema module, not the context
- Use `Ecto.Changeset` functions — never raw SQL in schemas

```elixir
defmodule MyApp.Catalog.Product do
  use Ecto.Schema
  import Ecto.Changeset

  schema "products" do
    field :name, :string
    field :price, :decimal
    field :description, :string

    belongs_to :category, MyApp.Catalog.Category

    timestamps()
  end

  def changeset(product, attrs) do
    product
    |> cast(attrs, [:name, :price, :description, :category_id])
    |> validate_required([:name, :price])
    |> validate_number(:price, greater_than: 0)
    |> assoc_constraint(:category)
  end
end
```

## LiveView

### Module Structure

```elixir
defmodule MyAppWeb.ProductLive.Index do
  use MyAppWeb, :live_view

  alias MyApp.Catalog

  @impl true
  def mount(_params, _session, socket) do
    products = Catalog.list_products()
    {:ok, assign(socket, :products, products)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    product = Catalog.get_product!(id)
    {:ok, _} = Catalog.delete_product(product)
    {:noreply, assign(socket, :products, Catalog.list_products())}
  end
end
```

### Colocated Templates

Always use colocated `.html.heex` files — never inline large templates in `render/1`. The template file must be adjacent to the LiveView module with matching name:

```
live/
  product_live/
    index.ex
    index.html.heex
    show.ex
    show.html.heex
```

Or for standalone LiveViews:

```
live/
  dashboard_live.ex
  dashboard_live.html.heex
```

### Function Components

Extract repeated UI patterns into function components. Define them in the LiveView module itself (private, with `defp`) for single-use components, or in a shared components module for reuse.

```elixir
attr :text, :string, required: true
attr :variant, :atom, default: :default

defp status_badge(assigns) do
  ~H"""
  <span class={["badge", badge_class(@variant)]}>
    {@text}
  </span>
  """
end

defp badge_class(:success), do: "badge-success"
defp badge_class(:warning), do: "badge-warning"
defp badge_class(_), do: "badge-default"
```

### Assigns

- Assign only what the template needs — no raw Ecto queries or large intermediate data
- Use `assign/3` for single values, multiple `assign/3` calls piped for several
- Compute derived values in the LiveView, not in the template

### Events

- `handle_event/3` for user interactions (clicks, form submissions)
- `handle_info/2` for server-side messages (PubSub, Process messages)
- `handle_params/3` for URL changes (live_patch navigation)
- Pattern match on event names and params — don't use catch-all clauses that silently swallow events

### Navigation

- `push_navigate/2` for full LiveView mount (new page)
- `push_patch/2` for URL update within the same LiveView (handle_params)
- `push_event/3` for client-side JavaScript hooks

## Templates (HEEx)

- Use `{@assign}` for outputting values (not `<%= %>`)
- Use `:if` / `:for` attributes instead of `<%= if %>` blocks
- Use function components (`<.component />`) instead of raw HTML partials
- Use data attributes with Tailwind `data-[]` selectors for conditional styling — never interpolate class names

```heex
<%!-- BAD: interpolated classes break Tailwind purging --%>
<div class={["mt-4", if(@active, do: "bg-blue-500", else: "")]}>

<%!-- GOOD: data attributes with Tailwind data-[] selectors --%>
<div data-active={"#{@active}"} class="mt-4 data-[active=true]:bg-blue-500">
```

```heex
<div :if={@products != []} class="grid grid-cols-3 gap-4">
  <.product_card :for={product <- @products} product={product} />
</div>

<div :if={@products == []} class="text-center text-gray-500">
  No products found
</div>
```

## JavaScript Hooks

When LiveView needs client-side behavior, use hooks:

```javascript
const MyHook = {
  mounted() {
    // Element added to DOM
  },
  updated() {
    // Element re-rendered by LiveView
  },
  destroyed() {
    // Element removed from DOM — clean up listeners, timers
  },
};
```

- Hooks are registered in `app.js` and attached via `phx-hook="MyHook"`
- Use `this.el` to access the DOM element
- Use `this.pushEvent("event_name", payload)` to send events to the server
- Use `this.handleEvent("event_name", callback)` to receive server push events
- Clean up event listeners and timers in `destroyed()`

## CSS / Tailwind

- Use Tailwind utility classes for all styling
- Custom CSS only for things Tailwind can't express (keyframe animations, complex selectors)
- Define design tokens as CSS custom properties for theming
- Register custom animations in `tailwind.config.js` so they're available as utilities (`animate-*`)
- Never use inline `style` attributes for static styling — only for dynamic computed values (animation delays)

## Testing

### LiveView Tests

```elixir
defmodule MyAppWeb.ProductLive.IndexTest do
  use MyAppWeb.ConnCase
  import Phoenix.LiveViewTest

  test "lists products", %{conn: conn} do
    product = insert(:product, name: "Widget")
    {:ok, _view, html} = live(conn, "/products")
    assert html =~ "Widget"
  end

  test "deletes product", %{conn: conn} do
    product = insert(:product)
    {:ok, view, _html} = live(conn, "/products")

    view |> element("button", "Delete") |> render_click()
    refute render(view) =~ product.name
  end
end
```

### Context Tests

```elixir
defmodule MyApp.CatalogTest do
  use MyApp.DataCase

  alias MyApp.Catalog

  describe "create_product/1" do
    test "with valid attrs creates a product" do
      attrs = %{name: "Widget", price: Decimal.new("9.99")}
      assert {:ok, product} = Catalog.create_product(attrs)
      assert product.name == "Widget"
    end

    test "with invalid attrs returns error changeset" do
      assert {:error, changeset} = Catalog.create_product(%{})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end
  end
end
```

## Anti-Patterns

Do not generate code with these patterns:

- **Fat controllers/LiveViews**: Business logic belongs in contexts, not in `handle_event` or controllers
- **Repo calls in LiveViews**: Always go through a context function
- **God contexts**: A context named "Helpers" or "Utils" that does everything — split by domain
- **Nested conditionals in templates**: Extract to function components or compute in the LiveView
- **Raw SQL in application code**: Use Ecto queries; raw SQL only in migrations when necessary
- **Passing conn/socket to contexts**: Contexts work with plain data only
- **Inline styles for static values**: Use Tailwind classes
- **Interpolated CSS classes**: Use data attributes with `data-[]` selectors instead
- **Large inline templates**: Extract to colocated .html.heex files
- **Catch-all event handlers**: Pattern match specifically; let unhandled events crash visibly
