# Spot Box Lifecycle

Back to the [README](../README.md).

The watchdog and the reaper deal with boxes from the outside. [`spot/`](../spot/)
is the other half: what runs **on** an ephemeral build box so that work is not
lost when AWS reclaims it on two minutes' notice, or when the idle timer
terminates it.

    spot/preserve.sh          push committed work; write a crash dump to S3
    spot/spot-watch.sh        watch IMDS for the reclaim notice
    spot/idle-shutdown.sh     preserve + self-terminate after an idle period
    spot/install-box.sh       install those three and their systemd units
    spot/restore-autosave.sh  list and recover dumps, from your machine
    spot/test-preserve.sh     ten cases against a throwaway repo and a stub aws

A crash dump is a **git bundle** in S3, not a branch: it keeps full history and
is `git fetch`-able, while being reachable from no ref, so it can be deleted or
expired by a lifecycle rule. Committed work still goes to the project's branch
as an ordinary push. The reasoning, the two incidents that motivated it, and the
recovery runbook are in [`spot/README.md`](../spot/README.md).

It is project-independent — every setting comes from the environment, see
[`spot/spot.env.example`](../spot/spot.env.example) — and it pairs with the lease
above: a box registers a lease at launch, an actively-working Claude beats it,
and `spot/` is what saves the work when the box goes away regardless.
