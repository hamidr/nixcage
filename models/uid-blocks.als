/*
 * Constrains the uid block allocator in modules/principal-uid.sh (ADR-010).
 *
 * A principal is allocated a contiguous block of host uids. Blocks are
 * appended in allocation order and never reissued, and an entry written
 * before ADR-010 carries no size and reads as one. The two promises are that
 * no two principals' blocks overlap, and that no block leaves the declared
 * range.
 */
open util/ordering[Alloc]

sig Alloc {
  base: one Int,
  size: one Int
}

one sig Range {
  rbase: one Int,
  rsize: one Int
}

fact Sane {
  Range.rbase >= 0
  Range.rsize >= 1
  all a: Alloc | a.size >= 1
}

/* Alloy's integers wrap at the scope's bitwidth, and a wrapped sum would be a
 * counterexample about Alloy rather than about the allocator. */
fact NoOverflow {
  plus[Range.rbase, Range.rsize] > Range.rbase
  all a: Alloc | plus[a.base, a.size] > a.base
}

fun endOf[a: Alloc]: Int { plus[a.base, a.size] }

pred overlaps[a, b: Alloc] {
  a.base < endOf[b]
  b.base < endOf[a]
}

/* The cursor ADR-010 decides: a new block starts at or above every prior
 * block's end. Stated as a constraint rather than an assignment, so the model
 * checks the promise and not the arithmetic that implements it. */
pred cursorOverEnds {
  first.base = Range.rbase
  all a: Alloc - first | all e: a.prevs | a.base >= endOf[e]
}

/* The cursor before ADR-010, which stores no size and so advances by one from
 * the highest base. Kept here because it is the shape the design replaces. */
pred cursorOverBases {
  first.base = Range.rbase
  all a: Alloc - first | all e: a.prevs | a.base > e.base
}

/* The exhaustion guard ADR-010 needs: a block is admitted only if all of it
 * fits. */
pred guardOnEnds {
  all a: Alloc | endOf[a] =< plus[Range.rbase, Range.rsize]
}

/* The guard as written today, which tests the base alone. */
pred guardOnBases {
  all a: Alloc | a.base < plus[Range.rbase, Range.rsize]
}

assert BlocksNeverOverlap {
  cursorOverEnds implies (all disj a, b: Alloc | not overlaps[a, b])
}

assert BlocksStayInRange {
  (cursorOverEnds and guardOnEnds) implies
    (all a: Alloc | a.base >= Range.rbase and endOf[a] =< plus[Range.rbase, Range.rsize])
}

check BlocksNeverOverlap for 4 but 6 Int
check BlocksStayInRange for 4 but 6 Int

/* Both of these must be SAT, or the checks above are vacuous: they are the
 * two bugs the design exists to remove. */
pred OverlapUnderOldCursor {
  cursorOverBases
  some disj a, b: Alloc | overlaps[a, b]
}

pred EscapeUnderOldGuard {
  cursorOverEnds
  guardOnBases
  some a: Alloc | endOf[a] > plus[Range.rbase, Range.rsize]
}

run OverlapUnderOldCursor for 3 but 6 Int
run EscapeUnderOldGuard for 3 but 6 Int
