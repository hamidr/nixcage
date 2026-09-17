/*
 * The lifecycle of one microVM session (ADR-019): the guest unit that runs
 * argv, writes its exit status into the home share and powers off, and the
 * host side of enter that boots the VM, waits, reads the status and reports.
 * Constrains nixcage-session.service in modules/guest.nix and the microvm
 * branch of enter in modules/container.nix.
 *
 * The guest and the host each move on their own; either may die at any
 * point; an operator may stop the scope or rm the cage in between. The
 * promises checked: enter never reports argv's status unless that status
 * reached the host; a scope never exists without the record list joins it
 * with; a stop takes the scope away for good; enter never returns with the
 * VM still running.
 */
module microvm_session {
  // off: no VM. booting: kernel and init up to the session unit.
  // running: argv runs. written: status in the guest's page cache only.
  // synced: fsync returned, the host can read it. halted: powered off.
  var guest: str
  // machine-<name>.scope exists on the host.
  var scope: bool
  // The record enter writes before anything else of the session exists.
  var record: bool
  // The status file as the host sees it.
  var statusHost: bool
  // idle: no enter. waitReady: booted, waiting for READY=1 within the boot
  // timeout. waitExit: ready seen, waiting for the scope to go. grace:
  // status seen with the scope still alive. done: reported. dead: the
  // enter process died.
  var host: str
  // What enter reported: "" while it has not, "status" (argv's exit
  // status), "timeout" (124), "nostatus" (255).
  var report: str
  // A stop was issued for this session.
  var stopped: bool

  action init = all {
    guest' = "off",
    scope' = false,
    record' = false,
    statusHost' = false,
    host' = "idle",
    report' = "",
    stopped' = false,
  }

  // Refused on a running name (decision 7), so the scope must be gone.
  action enter = all {
    host == "idle",
    not(scope),
    record' = true,
    scope' = true,
    guest' = "booting",
    host' = "waitReady",
    statusHost' = false,
    report' = "",
    stopped' = false,
  }

  action guestReady = all {
    guest == "booting",
    guest' = "running",
    scope' = scope, record' = record, statusHost' = statusHost,
    host' = host, report' = report, stopped' = stopped,
  }

  action guestExit = all {
    guest == "running",
    guest' = "written",
    scope' = scope, record' = record, statusHost' = statusHost,
    host' = host, report' = report, stopped' = stopped,
  }

  // fsync returned: the bytes are on the host under the share's cache mode.
  action guestSync = all {
    guest == "written",
    guest' = "synced",
    statusHost' = true,
    scope' = scope, record' = record,
    host' = host, report' = report, stopped' = stopped,
  }

  // The unit powers off only after the sync; the scope goes with the VM.
  action guestHalt = all {
    guest == "synced",
    guest' = "halted",
    scope' = false,
    record' = record, statusHost' = statusHost,
    host' = host, report' = report, stopped' = stopped,
  }

  // The VM dies at any point before poweroff: kernel panic, OOM of qemu
  // itself, the host killing it. A status not yet synced is lost.
  action guestCrash = all {
    scope,
    guest' = "off",
    scope' = false,
    record' = record, statusHost' = statusHost,
    host' = host, report' = report, stopped' = stopped,
  }

  // READY=1 arrived within the boot timeout.
  action hostSeesReady = all {
    host == "waitReady",
    guest != "booting",
    scope,
    host' = "waitExit",
    guest' = guest, scope' = scope, record' = record,
    statusHost' = statusHost, report' = report, stopped' = stopped,
  }

  // No READY=1 within --boot-timeout: stop, exit 124. When the scope is
  // already gone the VM finished before READY was seen, and what it left
  // is read like any other exit.
  action hostBootTimeout = all {
    host == "waitReady",
    any {
      all { scope, scope' = false, guest' = "off", stopped' = true, host' = "done", report' = "timeout" },
      all { not(scope), scope' = scope, guest' = guest, stopped' = stopped, host' = "done",
            report' = if (statusHost) "status" else "nostatus" },
    },
    record' = record, statusHost' = statusHost,
  }

  // The scope is gone: the status is there or it is not.
  action hostSeesGone = all {
    host == "waitExit",
    not(scope),
    host' = "done",
    report' = if (statusHost) "status" else "nostatus",
    guest' = guest, scope' = scope, record' = record,
    statusHost' = statusHost, stopped' = stopped,
  }

  // The status is there and the VM is still up: give it 5 s to power off.
  action hostSeesStatus = all {
    host == "waitExit",
    scope,
    statusHost,
    host' = "grace",
    guest' = guest, scope' = scope, record' = record,
    statusHost' = statusHost, report' = report, stopped' = stopped,
  }

  action hostGraceOver = all {
    host == "grace",
    any {
      all { scope, scope' = false, guest' = "off", stopped' = true },
      all { not(scope), scope' = scope, guest' = guest, stopped' = stopped },
    },
    host' = "done",
    report' = "status",
    record' = record, statusHost' = statusHost,
  }

  // The enter process dies. The VM does not notice.
  action hostDies = all {
    host.in(Set("waitReady", "waitExit", "grace")),
    host' = "dead",
    guest' = guest, scope' = scope, record' = record,
    statusHost' = statusHost, report' = report, stopped' = stopped,
  }

  // Ready for the next enter of the same name.
  action hostReset = all {
    host.in(Set("done", "dead")),
    host' = "idle",
    guest' = guest, scope' = scope, record' = record,
    statusHost' = statusHost, report' = report, stopped' = stopped,
  }

  // The stop verb (ADR-012), from anyone, at any time the scope exists.
  action operatorStop = all {
    scope,
    scope' = false,
    guest' = "off",
    stopped' = true,
    record' = record, statusHost' = statusHost, host' = host, report' = report,
  }

  // rm refuses a running cage; the record goes with the cage.
  action operatorRm = all {
    not(scope),
    record,
    record' = false,
    guest' = guest, scope' = scope, statusHost' = statusHost,
    host' = host, report' = report, stopped' = stopped,
  }

  action step = any {
    enter,
    guestReady, guestExit, guestSync, guestHalt, guestCrash,
    hostSeesReady, hostBootTimeout, hostSeesGone, hostSeesStatus, hostGraceOver,
    hostDies, hostReset,
    operatorStop, operatorRm,
  }

  // enter reports argv's status only when that status reached the host.
  val successHasStatus = (report == "status") implies statusHost

  // A running VM always has the record list joins it with.
  val scopeHasRecord = scope implies record

  // Once stop was issued for a session, its scope is gone and stays gone.
  val stopConverges = stopped implies not(scope)

  // enter never returns with the VM still running.
  val doneMeansGone = (host == "done") implies not(scope)

  // A lost status is reported as lost, never as a success.
  val crashBeforeSyncIsNoStatus =
    (report == "nostatus") implies not(statusHost)
}
