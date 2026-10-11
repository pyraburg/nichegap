CREATE TABLE public.pipeline_worker_heartbeats (
  name text PRIMARY KEY,
  last_started_at timestamptz,
  last_success_at timestamptz,
  last_error_at timestamptz,
  last_error text,
  last_jobs integer,
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT ALL ON public.pipeline_worker_heartbeats TO service_role;
ALTER TABLE public.pipeline_worker_heartbeats ENABLE ROW LEVEL SECURITY;

-- Internal health snapshot (service role only). Includes the scheduler's latest HTTP result so a
-- missing/undeployed worker endpoint (e.g. 404) is visible even though the worker itself never runs.
CREATE OR REPLACE FUNCTION public.pipeline_worker_health()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT jsonb_build_object(
    'now', now(),
    'heartbeat', (SELECT to_jsonb(h) FROM public.pipeline_worker_heartbeats h WHERE name = 'pipeline_tick'),
    'scheduler_active', (SELECT bool_or(active) FROM cron.job WHERE jobname = 'nichegap-pipeline-tick'),
    'last_scheduler_http', (SELECT jsonb_build_object('status', status_code, 'at', created, 'error', error_msg) FROM net._http_response ORDER BY created DESC LIMIT 1),
    'scheduler_http_failures_1h', (SELECT count(*) FROM net._http_response WHERE created > now() - interval '1 hour' AND (status_code IS NULL OR status_code >= 300)),
    'queued_jobs', (SELECT count(*) FROM public.research_queries WHERE status = 'pending' AND pipeline_version IS NULL),
    'processing_jobs', (SELECT count(*) FROM public.research_queries WHERE status = 'processing' AND pipeline_version IS NOT NULL),
    'oldest_processing_started_at', (SELECT min(started_at) FROM public.research_queries WHERE status = 'processing' AND pipeline_version IS NOT NULL),
    'stale_locks', (SELECT count(*) FROM public.research_queries WHERE pipeline_lease_until IS NOT NULL AND pipeline_lease_until < now()),
    'stale_fetch_locks', (SELECT count(*) FROM public.provider_fetch_locks WHERE lease_until < now()),
    'needs_attention_jobs', (SELECT count(*) FROM public.research_queries WHERE status = 'failed' AND pipeline_version IS NOT NULL),
    'pending_provider_costs', (SELECT count(*) FROM public.external_api_usage WHERE provider = 'apify' AND cache_hit = false AND cost_status <> 'final' AND provider_run_id IS NOT NULL)
  )
$$;
REVOKE ALL ON FUNCTION public.pipeline_worker_health() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pipeline_worker_health() TO service_role;