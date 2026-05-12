# The Ralph Loop

A "Ralph loop" is the dumbest agent that converges: send the same prompt
to the same model, over and over, until it says it's done. Named after
Ralph Wiggum — no planning, no memory, just persistence. Geoffrey Huntley
popularized the pattern; it's a few lines of code wrapped around one
piece of disk.

This guide is mostly about that piece of disk.

## The pattern in one sentence

A `TODO.md` lives on disk; a loop hands the LLM the same prompt each
iteration; the LLM reads `TODO.md`, does the top item, marks it done,
commits, and the loop runs again until `TODO.md` is empty.

The interesting part isn't the loop. It's why `TODO.md` makes a
stateless loop converge on a non-trivial outcome.

## Why a file, not a conversation

The LLM has no memory between iterations — and in the strictest version
of Ralph, it has no memory *within* the run either (each iteration is a
fresh agent). State has to live somewhere durable. A conversation buffer
is the wrong place:

| Conversation | Filesystem |
|---|---|
| Bounded by context window | Unbounded |
| Lossy under compaction | Lossless |
| Dies with the process | Survives crashes |
| Opaque to humans | `cat TODO.md` |
| Not diffable | `git diff` |

If iteration 7 crashes mid-edit, iteration 8 reads `TODO.md` and resumes.
There is no "resume" code to write. The filesystem *is* the resume.

## The five-step contract

Each iteration does exactly this, in order:

1. **Read** `TODO.md`.
2. **Pick** the top unchecked item.
3. **Do** it — edit code, run tests, whatever the item requires.
4. **Mark** it `[x]`. Append any new subtasks discovered along the way.
5. **Commit** with the item text as the commit message.

Step 4's second clause is the one most readers gloss over. The list
typically *grows* for the first several iterations as the agent uncovers
complexity, then shrinks. A reader expecting monotonic burndown will
think it's broken on iteration 3. It isn't — Ralph is discovering the
shape of the problem.

This is also why the prompt is the same every iteration: there is
nothing iteration-specific to say. The contract is the prompt.

## What a good `TODO.md` entry looks like

Items have to be **verifiable**, **single-iteration-sized**, and
**ordered by dependency**.

```markdown
## MVP

- [ ] Add `Foo.parse/1` that turns a binary into `{:ok, %Foo{}}` or `{:error, term}`
- [ ] Add unit tests covering empty input, malformed input, and the happy path
- [ ] Wire `Foo.parse/1` into the existing `Bar.ingest/1` pipeline
- [ ] Update the `Bar` doctest to reflect the new return shape

## FUTURE

- streaming parser
- benchmarks
```

What goes wrong without this discipline:

- **"Fix the API"** — too vague. The agent thrashes, marks it done
  without doing much, or expands it into ten items it then half-finishes.
- **"Rename `foo` to `bar` in `lib/x.ex` line 42"** — too small. That's a
  code review note, not an iteration.
- **Items in arbitrary order** — Ralph picks the top item, so dependency
  order is enforced by list order. If item 3 depends on item 5, you'll
  watch Ralph break item 3, give up, and mark it done anyway.

Keep nice-to-haves out of `## MVP`. Put them in `## FUTURE` (or a
separate `FUTURE.md`). Otherwise Ralph will keep finding work forever —
see *Livelock* below.

## Git is the backstop

Commit-per-iteration is non-negotiable. Three reasons:

1. **Bisect.** When the build breaks on iteration 23, you want
   `git bisect` to land on the exact iteration that broke it.
2. **Revert.** A bad iteration is one `git revert` away from gone. If
   five iterations stacked on top of each other in a single commit, you
   have to untangle them by hand.
3. **Audit.** The commit log *is* the record of what Ralph did. Every
   step has a message (the TODO item), a diff, and a timestamp.

The prompt should require it. If Ralph forgets to commit, the next
iteration sees a dirty tree and `mix test` fails — which surfaces the
problem instead of hiding it.

## Failure modes

### Livelock by infinite subtasks

The agent keeps appending "while I'm in here, I should also..." items.
The list never shrinks.

**Fix:** A hard-coded `## MVP` section with an explicit definition of
done. The prompt says "DONE means every line under `## MVP` starts with
`[x]`." Items the agent thinks of beyond that go to `## FUTURE` and
don't count.

### Premature DONE

The agent declares done with items still unchecked, because the prompt
said "say DONE when you're finished" and the LLM decided it was tired.

**Fix:** Make the sentinel mechanically checkable. Not "when you're
done" but "when `grep -c '^- \[ \]' TODO.md` returns 0 *and* `mix test`
exits 0."

### Phantom completion

The agent marks an item `[x]` without doing the work. The diff for that
iteration is just the checkbox flip.

**Fix:** Two layers. First, the prompt requires the commit to include
the work, not just the checkbox. Second, the loop runs `mix test`
between iterations and refuses to proceed on red. (A verifier subagent
that reads the commit diff against the item text is the next step up.)

### The wrong thing, correctly

Tests pass. Feature is wrong. Ralph cannot detect this — there's no
ground truth in the loop.

**Fix:** Human checkpoints, or a grader subagent that compares the diff
to the original spec. Ralph is for narrow, well-specified work; it is
not for "build me a product."

## Where `TODO.md` comes from

This is where most Ralph attempts fall over. Bad input, bad output.

Two reasonable starting points:

- **Human-written.** You sit down for fifteen minutes and write
  twenty checkboxes. This is the most reliable mode and the one Geoffrey
  Huntley uses for production work.
- **Planning pass.** A separate agent (or Ralph's iteration 0 with a
  different prompt) decomposes a goal into checkboxes. Cheap, but the
  list quality is only as good as the planner; budget time to edit it
  by hand before kicking off the loop.

Either way, **read the list before you run Ralph**. It will get done.
You want it to be the thing you actually wanted.

## The loop itself

For completeness — it's footnote-sized. Using `SkillKit.send_message/2`
on a single long-running agent (cheap; conversation accumulates but
`TODO.md` is the source of truth):

```elixir
defmodule Ralph do
  alias SkillKit.Event.Error, as: EventError
  alias SkillKit.Types.AssistantMessage

  @prompt """
  Read TODO.md. Pick the top item under `## MVP` whose box is unchecked.
  Do it. Mark it [x]. Append any subtasks you discovered to `## MVP`.
  Stage and commit your work; the commit message is the item text.

  Reply with exactly the word DONE if and only if every line under
  `## MVP` starts with `[x]` AND `mix test` exits 0.
  """

  def run(source) do
    {:ok, agent} = SkillKit.start_agent(source, tools: [{SkillKit.Tools.Shell, cwd: "."}])
    result = loop(agent, 1)
    SkillKit.stop_agent(agent)
    result
  end

  defp loop(agent, iter) do
    IO.puts("--- iter #{iter} ---")
    :ok = SkillKit.send_message(agent, @prompt)

    receive do
      %AssistantMessage{content: "DONE" <> _} -> :done
      %AssistantMessage{} -> loop(agent, iter + 1)
      %EventError{reason: reason} -> {:error, reason}
    end
  end
end
```

The classic-Ralph variant — fresh agent every iteration, zero
conversational memory — swaps the body of `loop/2` to call
`SkillKit.start_agent`, `send_message_sync`, and `stop_agent` per turn.
More expensive (a full supervision tree per iteration) but each
iteration is provably independent.

There is no `Stream.take(50)`. There is no `:timer.minutes(10)`. The
exit conditions are the `DONE` sentinel, an `%Error{}` event, or you
hitting Ctrl-C because you ran out of API budget.

## Pacing

Don't put rate limiting in the loop. The loop is sequential — one
request in flight at a time — and `Anthropic.Client` already retries
429s with `Retry-After` honored (`lib/anthropic/client.ex:45`). That's
enough for a single Ralph.

The shape that needs more is *many concurrent Ralphs sharing an API
key*. There is no centralized LLM gateway in SkillKit today; each agent
hits the provider directly. If you fan out, expect collisions on the
shared budget and plan accordingly (separate keys, or build the
gateway).

## When not to use Ralph

- **Tasks without a verifier.** If `mix test` can't tell you it's
  working, Ralph can't either. You'll get green checkboxes and broken
  code.
- **Tasks that need taste.** Ralph optimizes for "ship the item." It
  will not push back, redesign, or notice the spec is wrong.
- **Tasks you haven't spec'd.** The entire premise is that `TODO.md`
  encodes intent. If you can't write the list, Ralph can't run it.

Ralph is a hammer for the narrow case where the work decomposes into
checkboxes a test suite can grade. Inside that case it is remarkably
effective. Outside it, it is an expensive way to produce a clean
commit history of wrong code.
