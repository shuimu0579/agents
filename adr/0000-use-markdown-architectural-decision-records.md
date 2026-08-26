---
status: accepted
date: 2026-08-26
---

# Use Markdown Architectural Decision Records

## Context and Problem Statement

We need a durable place for architecturally significant choices in this repository — context, rejected options, and consequences — so later humans and agents neither blindly accept nor blindly reverse them.

Which format, location, and lifecycle should those records follow?

## Considered Options

* MADR (Markdown Architectural Decision Records), minimal template, in `adr/` at the repo root
* MADR under `docs/decisions/` or `docs/adr/` (next to generated API/site docs)
* Nygard five-section template only (Title / Context / Decision / Status / Consequences)
* Wiki / chat / long design docs with no numbered log
* bureau:adr pages in a personal canon (human approval gate, not this repo)

## Decision Outcome

Chosen option: "MADR minimal in `adr/` at the repo root", because it diffs with the code, stays out of generated `docs/` trees, and forces considered options into the open.

### Consequences

* Good, because one file captures one choice and can be superseded without rewriting history
* Good, because agents can read the log before changing structure, dependencies, or interfaces
* Bad, because writing an ADR has a cost — over-recording will make the log unread
* Neutral, because diagrams, RFCs, and `AGENTS.md` still describe *what* the system is; ADRs explain *why not otherwise*

### Confirmation

* Log directory `adr/` exists and holds `NNNN-title-with-dashes.md` files
* New structurally significant PRs that lack a matching ADR are called out in review
* A later ADR that changes course adds a new file and marks the old one `superseded`; it does not edit the old Decision Outcome
