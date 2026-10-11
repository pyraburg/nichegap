ALTER TABLE public.external_api_usage
  ADD COLUMN IF NOT EXISTS provider_run_id text,
  ADD COLUMN IF NOT EXISTS cost_status text NOT NULL DEFAULT 'final',
  ADD COLUMN IF NOT EXISTS cost_source text,
  ADD COLUMN IF NOT EXISTS intermediate_cost numeric,
  ADD COLUMN IF NOT EXISTS cost_finalized_at timestamptz,
  ADD COLUMN IF NOT EXISTS reconcile_attempts integer NOT NULL DEFAULT 0;
ALTER TABLE public.external_api_usage DROP CONSTRAINT IF EXISTS external_api_usage_cost_status_check;
ALTER TABLE public.external_api_usage ADD CONSTRAINT external_api_usage_cost_status_check
  CHECK (cost_status IN ('final','pending','unknown'));
CREATE UNIQUE INDEX IF NOT EXISTS external_api_usage_provider_run_uniq
  ON public.external_api_usage (provider, provider_run_id) WHERE provider_run_id IS NOT NULL AND cache_hit = false;
-- Backfill the controlled test row's run id so it can be reconciled.
UPDATE public.external_api_usage SET provider_run_id = 'dzQxxdFgPWoSQ4wJw', cost_status = 'pending', intermediate_cost = cost
  WHERE id = '6e9de4d7-68a4-4b42-a243-256f2a478b54' AND provider_run_id IS NULL;