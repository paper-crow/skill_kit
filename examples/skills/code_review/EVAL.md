## flags a real bug in a numbered list
### Prompt
Review this function:

```elixir
def average(nums) do
  Enum.sum(nums) / length(nums)
end
```

### Expect
The review is formatted as a numbered list of findings and calls out the
unhandled empty-list case (division by zero / `ArgumentError` when `nums` is
`[]`). It does not respond with "LGTM".

## approves clean code with LGTM
### Prompt
Review this function:

```elixir
@doc "Returns the user's display name, falling back to their email."
def display_name(%User{name: nil, email: email}), do: email

def display_name(%User{name: name, email: email}) do
  case String.trim(name) do
    "" -> email
    trimmed -> trimmed
  end
end
```

### Expect
The review finds no substantive issues and signals approval with "LGTM" rather
than inventing problems.
