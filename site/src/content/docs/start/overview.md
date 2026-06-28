---
title: Overview
description: What Soma is and the mental model behind it.
---

Soma is an Erlang/OTP-native agent runtime. The core thesis: an agent run is
**not a function that calls tools in a loop** — it is a supervised OTP process
tree. Erlang/OTP provides the execution semantics (timeouts, cancellation,
monitoring, crash isolation, restart policy); the step list only says *what* to
run.

## The mental model

The actor model plus OTP supervision: every session, run, and tool call is an
actor — an isolated process with a private mailbox, communicating only by
message passing. OTP's supervision and monitors add the fault-tolerance layer
that is the actual point.

## Where to go next

This page is the seed of the docs. Later slices port the full documentation and
the architecture diagrams.
