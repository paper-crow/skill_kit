## names boolean functions with a ? suffix
### Prompt
Write an Elixir function that returns whether a list is empty.

### Expect
The function it writes is named with a trailing `?` (e.g. `empty?/1`), following
the convention that boolean-returning functions end in `?`.

## pattern matches in function heads
### Prompt
Write an Elixir function `handle/1` that returns the value from an `{:ok, value}`
tuple and `nil` from an `{:error, _}` tuple.

### Expect
The function distinguishes the two cases by pattern matching in the function
heads (two `def handle/1` clauses), rather than using a `case` or `if` inside a
single clause.
