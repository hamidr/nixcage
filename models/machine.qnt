/*
 * The lifecycle of one machine (ADR-026): a long-lived microVM that is a
 * nixcage host, started and stopped by the host alone, and the verbs a
 * caller forwards into it. Constrains `nixcage-container machine up|down`,
 * the machine's unit and its stop, and the --machine forward in
 * modules/container.nix.
 *
 * The guest is not trusted: it may hang (stop answering) or crash at any
 * step, and nothing the host must do waits on it. Two callers forward
 * concurrently with up and down; anyone may stop the unit from outside.
 * The promises checked: no forward is delivered to a machine that is not
 * ready; a machine that is off or failed has no qemu, tap, pin or share
 * daemon left, whatever the guest did; up never makes a second tap; no
 * cage outlives its qemu.
 *
 * Two switches name the design's two guards, so each can be turned off to
 * show the invariant it holds: USE_LOCK (down takes the machine's lock
 * exclusively, a forward holds it shared from its check to its delivery)
 * (up takes it too) and HOST_CLEANUP (the unit's stop removes the tap, pins and share daemons
 * on the host rather than asking the guest).
 */
module machine {
  pure val USE_LOCK = true
  pure val HOST_CLEANUP = true
  pure val CALLERS = Set("c1", "c2")
  pure val MAX_CAGES = 2

  // off, booting, ready, stopping, failed: the host's view of the unit.
  var unit: str
  var qemu: bool
  // The guest's nixcage-container answers over vsock.
  var answers: bool
  var taps: int
  var pins: bool
  var sharesd: bool
  var cages: int
  // idle, checked (saw ready, holds the shared lock), delivered.
  var fwd: str -> str
  // A down holds the lock exclusively.
  var downLock: bool
  // History: a forward reached a guest while the unit was not ready.
  var badDelivery: bool

  action init = all {
    unit' = "off",
    qemu' = false,
    answers' = false,
    taps' = 0,
    pins' = false,
    sharesd' = false,
    cages' = 0,
    fwd' = CALLERS.mapBy(c => "idle"),
    downLock' = false,
    badDelivery' = false,
  }

  val readers = CALLERS.filter(c => fwd.get(c) == "checked")

  // The unit's start: tap, pins and share daemons before qemu. It waits
  // for forwards in flight as down does: a check made against the last
  // boot must not be delivered to this one while it is still booting.
  action up = all {
    unit == "off" or unit == "failed",
    not(downLock),
    not(USE_LOCK) or readers.size() == 0,
    unit' = "booting",
    qemu' = true,
    answers' = false,
    taps' = taps + 1,
    pins' = true,
    sharesd' = true,
    cages' = 0,
    fwd' = fwd,
    downLock' = downLock,
    badDelivery' = badDelivery,
  }

  // up on a machine that is booting or ready returns and changes nothing.
  action upAgain = all {
    unit == "booting" or unit == "ready",
    unit' = unit, qemu' = qemu, answers' = answers, taps' = taps,
    pins' = pins, sharesd' = sharesd, cages' = cages, fwd' = fwd,
    downLock' = downLock, badDelivery' = badDelivery,
  }

  action guestAnswers = all {
    qemu,
    unit == "booting" or unit == "ready",
    answers' = true,
    unit' = unit, qemu' = qemu, taps' = taps, pins' = pins,
    sharesd' = sharesd, cages' = cages, fwd' = fwd,
    downLock' = downLock, badDelivery' = badDelivery,
  }

  action awaitReady = all {
    unit == "booting",
    answers,
    unit' = "ready",
    qemu' = qemu, answers' = answers, taps' = taps, pins' = pins,
    sharesd' = sharesd, cages' = cages, fwd' = fwd,
    downLock' = downLock, badDelivery' = badDelivery,
  }

  // The guest stops answering: a hang, or a guest that lies by silence.
  action guestHangs = all {
    answers,
    answers' = false,
    unit' = unit, qemu' = qemu, taps' = taps, pins' = pins,
    sharesd' = sharesd, cages' = cages, fwd' = fwd,
    downLock' = downLock, badDelivery' = badDelivery,
  }

  // qemu goes: a guest crash, an await that timed out, a down whose bound
  // expired, or a systemctl stop from anyone. Its cages go with it.
  action qemuDies = all {
    qemu,
    qemu' = false,
    answers' = false,
    cages' = 0,
    unit' = unit, taps' = taps, pins' = pins, sharesd' = sharesd,
    fwd' = fwd, downLock' = downLock, badDelivery' = badDelivery,
  }

  // The unit's stop, run by systemd once qemu is gone.
  action reap = all {
    not(qemu),
    unit == "booting" or unit == "ready" or unit == "stopping",
    unit' = if (unit == "stopping") "off" else "failed",
    taps' = if (HOST_CLEANUP or answers) 0 else taps,
    pins' = if (HOST_CLEANUP or answers) false else pins,
    sharesd' = if (HOST_CLEANUP or answers) false else sharesd,
    downLock' = false,
    qemu' = qemu, answers' = answers, cages' = cages, fwd' = fwd,
    badDelivery' = badDelivery,
  }

  action downBegin = all {
    unit == "booting" or unit == "ready",
    not(downLock),
    not(USE_LOCK) or readers.size() == 0,
    unit' = "stopping",
    downLock' = true,
    qemu' = qemu, answers' = answers, taps' = taps, pins' = pins,
    sharesd' = sharesd, cages' = cages, fwd' = fwd,
    badDelivery' = badDelivery,
  }

  // down asks the guest to stop its cages; a guest that does not answer is
  // not asked, and qemuDies ends it when the bound expires.
  action downAsks = all {
    unit == "stopping",
    answers,
    cages' = 0,
    unit' = unit, qemu' = qemu, answers' = answers, taps' = taps,
    pins' = pins, sharesd' = sharesd, fwd' = fwd,
    downLock' = downLock, badDelivery' = badDelivery,
  }

  action fwdCheck(c: str): bool = all {
    fwd.get(c) == "idle",
    unit == "ready",
    not(USE_LOCK) or not(downLock),
    fwd' = fwd.set(c, "checked"),
    unit' = unit, qemu' = qemu, answers' = answers, taps' = taps,
    pins' = pins, sharesd' = sharesd, cages' = cages,
    downLock' = downLock, badDelivery' = badDelivery,
  }

  action fwdDeliver(c: str): bool = all {
    fwd.get(c) == "checked",
    answers,
    fwd' = fwd.set(c, "delivered"),
    cages' = if (cages < MAX_CAGES) cages + 1 else cages,
    badDelivery' = badDelivery or unit != "ready",
    unit' = unit, qemu' = qemu, answers' = answers, taps' = taps,
    pins' = pins, sharesd' = sharesd, downLock' = downLock,
  }

  // The connection is refused or times out: the caller gets an error.
  action fwdFail(c: str): bool = all {
    fwd.get(c) == "checked",
    not(answers),
    fwd' = fwd.set(c, "idle"),
    unit' = unit, qemu' = qemu, answers' = answers, taps' = taps,
    pins' = pins, sharesd' = sharesd, cages' = cages,
    downLock' = downLock, badDelivery' = badDelivery,
  }

  action fwdDone(c: str): bool = all {
    fwd.get(c) == "delivered",
    fwd' = fwd.set(c, "idle"),
    unit' = unit, qemu' = qemu, answers' = answers, taps' = taps,
    pins' = pins, sharesd' = sharesd, cages' = cages,
    downLock' = downLock, badDelivery' = badDelivery,
  }

  action step = any {
    up, upAgain, guestAnswers, awaitReady, guestHangs, qemuDies, reap,
    downBegin, downAsks,
    nondet c = CALLERS.oneOf()
    any { fwdCheck(c), fwdDeliver(c), fwdFail(c), fwdDone(c) },
  }

  val noDeliveryUnlessReady = not(badDelivery)
  val offMeansClean =
    (unit == "off" or unit == "failed") implies
      not(qemu) and taps == 0 and not(pins) and not(sharesd)
  val oneTap = taps <= 1
  val noCageWithoutQemu = cages > 0 implies qemu
  // A forward's check never survives into another boot: it is delivered or
  // fails against the boot it saw ready.
  val noCheckAcrossBoot =
    CALLERS.forall(c => fwd.get(c) == "checked" implies
      (unit == "ready" or unit == "failed"))
  val all_invariants =
    noDeliveryUnlessReady and offMeansClean and oneTap and noCageWithoutQemu
      and noCheckAcrossBoot

  // Witnesses: each must be reachable, or the invariants hold vacuously.
  val witnessReady = unit != "ready"
  val witnessCage = cages == 0
  val witnessStopping = unit != "stopping"
  val witnessFailed = unit != "failed"
}
