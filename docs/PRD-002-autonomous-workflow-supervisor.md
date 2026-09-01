---
id: PRD-002
title: A supervisor that runs declared workflows across cages
status: proposed
date: 2026-09-01
status_date: 2026-09-01
summary: declared workflows dispatch caged agent runs under gates and caps, so runs start without a human
depends_on: [PRD-001]
supersedes: []
superseded_by: []
phases_total: 5
phases_done: 0
---

## Problem

Every unit of work in nixcage starts with a person opening a terminal. That is
fine for one project and wrong for the shape the tool has grown into: several
projects, each isolated, each with an agent that could be working, all waiting
on the same human to type the same command.

The cost is not typing. It is that the operator becomes the scheduler. Work
that is ready to run waits until they remember it. A finished run sits idle
until they notice. Two projects that could progress in parallel progress in
sequence, at the speed of one person's attention. The mailbox in PRD-001 makes
the work visible and durable, and then stops: it deliberately refuses to let a
message start anything.

Nothing about the isolation boundary requires a human present. A cage exists so
an agent cannot reach the host, not so a person must watch it. What is missing
is the piece that decides what runs, starts it, waits for it, and records the
result, with the operator setting the policy instead of executing it.

## Users

- **The operator.** Declares what should happen and under what limits, then
  reviews. They stop being the thing that starts runs and become the thing that
  approves them. They are still the only trust domain.
- **The agent in a cage.** Receives work it did not have to be asked for
  interactively, and returns a result. It gains no new authority: it cannot
  start a run, its own or anyone else's.

## Goals

1. Work that is ready to run starts without the operator starting it.
2. The operator can say, in one reviewable place, what should run, when, for
   which projects, and how far it may go.
3. Every run is visible while it happens, interruptible, and inspectable
   afterwards.
4. Nothing runs past a limit the operator set, and nothing runs at all past a
   point where they said they wanted to look first.
5. No agent gains the ability to start work in another project.

## Non-goals

- **Dispatch from inside a cage.** A caged agent can request, never start. This
  is the line that keeps a mail bug from becoming unattended spend across every
  project, and it is not negotiable within this PRD.
- **Agent-authored workflows.** Agents may not edit the workflow declarations.
  A workflow that an agent can rewrite is a workflow that provides no
  containment.
- **Workflow files in projects.** A project stays free of nixcage-specific
  files. Workflows are the operator's, declared once, applied by selector.
- **A CI replacement.** This runs agent sessions on a developer's own machine
  against their own projects. It is not a build service, has no artifacts
  store, and makes no durability promises a CI system would.
- **Multi-machine scheduling.** One operator, one machine.
- **Cost prediction.** The system enforces a budget it can measure; it does not
  estimate one in advance.

## Success criteria

- A workflow declared once runs repeatedly without further typing, and the
  operator can name what ran yesterday without reconstructing it.
- Two projects that were both ready progress in the same wall-clock window.
- A run stopped by a gate stays stopped until the operator answers, and answers
  can be given hours later without losing the run.
- A misbehaving workflow exhausts its budget and stops instead of running until
  someone notices the bill.
- Over a week, the operator's role in ordinary progress is approving and
  reviewing, not starting.
- No dispatch ever originates inside a cage, and this is verifiable from the
  record rather than assumed.

## Requirements

### Declaring a workflow

- The operator declares workflows in one reviewable place they already own,
  version-controlled, using the configuration system nixcage already uses. No
  second configuration language.
- A declaration is data, never a script. Nothing a message contains can become
  part of a declaration, and no value from a mailbox body is ever interpolated
  into a command line.
- A declaration says: what triggers it, which projects it applies to, what runs
  in the cage, whether a human gate applies and where, what limits bound it,
  what counts as finished, and what is recorded.
- Changing a declaration takes effect without rebuilding or restarting the
  shared VM, because that would interrupt every running session.
- A declaration that cannot be satisfied (unknown project, missing workflow it
  depends on) is rejected when read, not when it fires.

### Running

- A run executes inside the target project's cage, through the ordinary
  non-interactive entry path. The supervisor gains no privilege inside a cage
  that an interactive session does not have.
- The prompt or instruction for a run reaches the agent as data, by file or
  standard input, never as part of a command the host shell parses.
- The operator can see a run while it is happening, attach to it, and stop it.
- A run ends when the agent settles, and the supervisor learns this from the
  session's reported state rather than by guessing from output.
- Every run records what workflow started it, why, against which project, when,
  and how it ended.

### Gates

- A gate stops the run and waits. The operator's answer may come minutes or
  hours later; a waiting run survives that.
- A waiting run is visibly waiting, distinguishable at a glance from one that is
  working and one that has finished.
- The operator can approve, reject, or amend at a gate, and a rejection is
  recorded with the run rather than discarding it silently.
- A gate that is never answered blocks that run forever and does not consume
  the concurrency it is holding. Whether an unanswered gate should ever expire
  is left open below.

### Limits

- Concurrency is capped globally: the machine runs at most N agent sessions at
  once regardless of how many workflows want to.
- Budget is capped per workflow: each workflow has its own allowance, and
  exhausting one stops that workflow without touching the others.
- Dispatch depth is capped: a run that leads to another run cannot chain past a
  declared depth. Depth is counted from the trigger, not per workflow.
- Reaching any cap stops cleanly, records why, and tells the operator. It never
  fails silently and never partially applies.

### Requesting what a cage cannot install

- A cage installs its own tooling through its project's own flake or `.envrc`,
  which needs nothing from this system.
- For the four things a cage cannot reach -- a tool in the shared container
  profile, a secret mapping, a new workspace root, VM sizing -- the agent sends
  a request through the mailbox and the operator applies it. The supervisor
  neither applies such requests nor is required for them.

## Constraints

- Dispatch, waiting, and gating all happen on the host, outside every cage.
- The supervisor assumes no particular coding agent. Which agent a project runs
  is a property of that project's own devShell, not of nixcage or of a
  workflow, so a run is described by the command it starts and by the lifecycle
  state that command's session reports.
- An agent that accumulates its own skills or extensions does so inside the
  cage's persistent home, which is that actor's private state. The supervisor
  treats it as opaque: it neither reads it, seeds it, nor reasons about it.
- The supervisor runs inside its own terminal-multiplexer session rather than a
  stray shell, because the multiplexer's own contract forbids controlling a
  session from outside it.
- The system depends on a terminal multiplexer that can run headless, start a
  command in a pane, report and wait on agent lifecycle state, and accept
  externally reported state. herdr 0.8.0 satisfies all four, verified.
- Everything the supervisor knows about a run is recoverable after a restart:
  the multiplexer's sessions persist, and the record lives with the mailbox.

## Risks

- **The prompt path is a host-side injection surface.** Running a command in a
  pane means writing a command line on the host, outside every cage. A mailbox
  body that reaches that string is host execution. Passing prompts by file is
  the containment, and it is a requirement rather than a style preference.
- **The supervisor is not itself caged.** It runs on the host with the
  operator's privileges. It is small on purpose, and its inputs are declarations
  the operator wrote plus message metadata, never message bodies.
- **Unattended runs can sign as the operator.** ADR-008 gives a cage the
  forwarded ssh-agent, so a run can produce commits and tags that verify as
  them, and can authenticate to any host their keys open. Autonomy plus that
  grant means signed commits with no human in the loop at any point. Revisiting
  ADR-008 for a cage-only signing key is a live question this PRD raises but
  does not decide.
- **Every dispatched session carries the operator's API keys.** Fan-out
  multiplies exposure, not only spend.
- **Loops.** A workflow whose result triggers itself is the obvious failure.
  Depth caps bound it; they do not prevent someone declaring it.

## Open questions

- What unit is the budget measured in, and where does the measurement come
  from? Runs and wall-clock are observable from outside the cage; tokens and
  cost are not, unless the agent reports them. An agent offering a structured
  event stream or an RPC channel could supply them, which would make the
  allowance real rather than a run count. Since the agent is a per-project
  choice, the budget mechanism has to work with whatever a project runs, and
  degrade to a run count when nothing better is available.
- Should an unanswered gate ever expire, and into what -- rejection, or an
  indefinite hold that the operator prunes by hand?
- Where does a run's output land? A branch in the project, a worktree of its
  own, or only the mailbox record. This decides whether the supervisor needs to
  create worktrees at all.
- What happens when a workflow targets a project the operator currently has
  open? Refuse, queue behind them, or run concurrently in a second session.
- Is a trigger allowed to be a schedule, or only a mailbox condition? A
  schedule makes the system useful with an empty mailbox and widens the
  unattended surface at the same time.

## Phases

Ordered so that containment exists before autonomy does.

1. **A declared workflow runs once, started by hand.** Declaration is read and
   validated, a run executes in the target cage, the supervisor waits for the
   settled state and records the result. No trigger, no autonomy.
2. **Gates.** A run stops where the declaration says, waits visibly, and
   resumes or ends on the operator's answer, with the answer recorded.
3. **Limits.** Global concurrency, per-workflow budget, and dispatch depth,
   each stopping cleanly and reporting why.
4. **Triggers.** Mailbox conditions start runs without the operator. This is
   the phase that makes the system autonomous, and it lands only on top of the
   three before it.
5. **The record.** What ran, why, under which workflow, with what result, and
   the check that no dispatch originated inside a cage.

## Design gates

The Formal Modeling Gate fires on three counts: a dispatch lifecycle with more
than three states crossing process boundaries, a scheduling and allocation
problem under global concurrency and per-workflow budgets, and invariants
spanning workflow runs and mailbox messages. A Quint model under `models/` is
written and run before implementation, checking at minimum: no run proceeds
past a gate that was never answered; dispatch depth never exceeds its cap;
concurrent runs never exceed the global cap; a workflow that exhausts its
budget starts no further run; and every dispatched run eventually records a
result or is recorded as cancelled.
