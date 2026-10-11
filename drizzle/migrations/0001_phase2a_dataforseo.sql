ALTER TABLE public.research_data
  ADD COLUMN IF NOT EXISTS target_country text,
  ADD COLUMN IF NOT EXISTS language text,
  ADD COLUMN IF NOT EXISTS normalized_query text,
  ADD COLUMN IF NOT EXISTS cache_hit boolean NOT NULL DEFAULT false;

CREATE INDEX IF NOT EXISTS research_data_cache_idx
  ON public.research_data (provider, data_type, normalized_query, target_country, language, expires_at);

CREATE TABLE public.external_api_usage (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  research_query_id uuid REFERENCES public.research_queries(id) ON DELETE SET NULL,
  provider text NOT NULL,
  endpoint text NOT NULL,
  cost numeric,
  currency text NOT NULL DEFAULT 'USD',
  cache_hit boolean NOT NULL DEFAULT false,
  status text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT ALL ON public.external_api_usage TO service_role;
ALTER TABLE public.external_api_usage ENABLE ROW LEVEL SECURITY;
-- No policies for anon/authenticated: internal cost log, written and read by server code only.