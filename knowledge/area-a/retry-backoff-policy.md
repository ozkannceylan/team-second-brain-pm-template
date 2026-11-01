---
title: "service-x Outbound Webhook Retry and Jitter Policy"
domain: "area-a"
type: "runbook"
owner: "@ORG/maintainers"
status: "verified"
last_verified: "2026-11-01"
locked: false
publish: true
sources:
  - "inbox/issue-42.md"
  - "https://github.com/ORG/REPO/issues/42"
superseded_by: null
related_cards:
  - "https://github.com/ORG/REPO/issues/42"
---

# `service-x` Outbound Webhook Retry and Jitter Policy

> **Worked Example Page:** This page demonstrates the closed loop between a completed board card (`Issue #42` in [`docs/workflow.md`](../../docs/workflow.md#worked-example-pair-issue-card-42--curated-knowledge-page), whose `Knowledge link` field is set to `knowledge/area-a/retry-backoff-policy.md`) and a human-verified Second Brain page (`related_cards` above).

## Summary

`service-x` delivers event webhooks to downstream consumers in `area-a`. Fixed-interval retries caused synchronized retry storms after downstream blips (`Issue #42`). All outbound webhook workers must use **capped exponential backoff with full jitter**.

## Operational Rules

1. **Backoff Formula:**
   - Base delay: `2 seconds`
   - Multiplier: `2^attempt` (attempts `1..5`)
   - Maximum cap: `60 seconds`
   - Jitter: **Full jitter (`±25%` uniform random offset)** so concurrent workers never retry on the same millisecond.
2. **Retryable vs. Terminal Responses:**
   - **Retry:** Network timeouts, connection resets, and HTTP `429`, `502`, `503`, `504`.
   - **Do NOT Retry (fail immediately to dead-letter queue):** HTTP `400`, `401`, `403`, `404`, `422`.
3. **Request Timeout:** Per-attempt timeout must not exceed `5 seconds`.

## Verification & Rollback

- Check worker retry histogram via metric `service_x_webhook_retry_delay_seconds`.
- If downstream queue latency exceeds `120s`, pause automatic retries via runtime flag `SERVICE_X_RETRY_MAX_ATTEMPTS=1` and open a `[Blocker]` card on the team board.

## Contradictions and open questions

- None currently open. *(Resolved `2026-11-01` via Issue `#42`: replaced legacy 5-second fixed retry interval with exponential backoff + jitter.)*
