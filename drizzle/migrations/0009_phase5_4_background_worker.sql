CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;

-- Server-only token the scheduler presents to the pipeline worker route. No grants to anon/authenticated,
-- so it can never be read from a browser; only the database scheduler and service-role server code see it.
CREATE TABLE IF NOT EXISTS public.internal_worker_tokens (
  name text PRIMARY KEY,
  token text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
REVOKE ALL ON public.internal_worker_tokens FROM anon, authenticated;
GRANT ALL ON public.internal_worker_tokens TO service_role;
ALTER TABLE public.internal_worker_tokens ENABLE ROW LEVEL SECURITY;
INSERT INTO public.internal_worker_tokens (name, token)
VALUES ('pipeline_tick', encode(extensions.gen_random_bytes(32), 'hex'))
ON CONFLICT (name) DO NOTHING;

CREATE INDEX IF NOT EXISTS research_queries_pipeline_active_idx
  ON public.research_queries (created_at) WHERE status = 'processing' AND pipeline_version IS NOT NULL;