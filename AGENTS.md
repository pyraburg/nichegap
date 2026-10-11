<!-- LOVABLE:BEGIN -->
> [!IMPORTANT]
> This project is connected to [Lovable](https://lovable.dev). Avoid rewriting
> published git history — force pushing, or rebasing/amending/squashing commits
> that are already pushed — as it rewrites history on Lovable's side and the
> user will likely lose their project history.
>
> Commits you push to the connected branch sync back to Lovable and show up in
> the editor, so keep the branch in a working state.
<!-- LOVABLE:END -->

- Accounts and research jobs use Lovable Cloud; signed-in pages live under `src/routes/_authenticated/`. Why: brief requires per-user data with RLS.
- `/` is a public landing page only; the legacy browser-key workspace and its unauthenticated AI proxy were removed, and every `createServerFn` must use `requireSupabaseAuth` and fetch only fixed provider hosts (guarded by `security.test.ts`). Why: prevents SSRF/abuse.
- research_data, opportunities, reports are read-only for users; only server code (service role) writes them. Why: prevents fabricated/forged results and scores.
- DataForSEO calls run only in server code (`src/lib/nichegap/*.server.ts` via authenticated server functions), with atomic status claims and a 30-day research_data cache checked first. Why: credentials stay server-side and paid calls are never duplicated.

- Customer-facing journey pages (`/dashboard`, `/research`, `/research/new`, `/research/$id`) derive progress only from persisted backend facts via pure `src/lib/nichegap/journey.ts` and read data as the signed-in user (RLS); provider names, costs, IDs and raw errors never render there, and technical evidence tools live on the internal `/lab` page. Why: customers see an honest, simple workflow without internals.
- Research jobs run through `src/lib/nichegap/pipeline/pipeline_v1.ts` (pure, versioned stage machine) executed by `pipeline.server.ts` under a DB lease on `research_queries`; each stage reuses evidence already stored for the job before any paid call, failed stages only rerun via bounded user retry. Why: automation must be resumable and never double-charge.
- Internal admin-only views check `has_role(uid,'admin')` from `user_roles` on the server. Why: roles must never live on profiles or the client.
- Pipeline progression is driven only by the background worker route `/api/public/pipeline-tick` (pg_cron every minute, idle-guarded in SQL, bearer token from server-only `internal_worker_tokens`); browsers only start/retry (queue) and display status. Why: research must continue with no page open, without browser-driven or unbounded loops.
- Research Credits live in an append-only `credit_ledger` (balance = SUM by credit type) with one `credit_reservations` row per credit-billed job; all credit movement goes through service-role-only SECURITY DEFINER SQL functions serialized by a per-user advisory lock, reserved once in `startPipeline` and finalized only at full pipeline completion. Why: concurrent requests can never spend the same credit and worker retries never re-charge.
- Scoring, report, AI and community rules live in the `AGENTS.md` inside `src/lib/nichegap/{scoring,report,ai,community}/`. Why: they apply only to those modules.
- Payments use Lemon Squeezy only: variant→credit mapping lives server-side in `src/lib/nichegap/billing/lemonsqueezy_v1.ts`, and only signature-verified webhooks (`/api/public/lemonsqueezy-webhook`) write payment credits via ledger idempotency keys (ls_order:/ls_invoice:). Why: checkout redirects and browser input must never grant credits.
- Credit charging decisions live only in pure `src/lib/nichegap/credit_policy_v1.ts` (complete→finalize, retryable failure→keep reserved, exhausted attempts→release same credit type); the score never affects charging. Why: customers pay for completed reports only and technical failures never cost a credit.
- `research_queries.billing` is `legacy` (pre-credit, free), `credit` (customer inserts must be this) or `validation`; validation jobs are (admin-created via `validation.functions.ts`, never reserve credits, same pipeline and ceilings); metrics are pure in `src/lib/nichegap/validation/validation_v1.ts` and QA ratings live only in `validation_reviews`. Why: launch validation must not touch customer credits or scores.
- Research jobs with any credit record or in progress can't be deleted by anyone (DB trigger + FK RESTRICT); customers may delete only their own unstarted pending jobs. Why: deletion must never orphan credits or audit history.
- Amazon-stage execution lives in pure `src/lib/nichegap/amazon_collect_v1.ts` (batched cache lookup, concurrency cap, in-flight-aware DataForSEO ceiling) and cross-job duplicate paid requests are prevented by short DB leases per cache key (`claim_provider_fetch`/`release_provider_fetch`, service-role only). Why: parallel jobs must never pay twice and no transaction may span a provider HTTP call.
