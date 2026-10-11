CREATE TABLE public.ai_analyses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  research_query_id uuid NOT NULL REFERENCES public.research_queries(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  analysis_version text NOT NULL,
  packet_version text NOT NULL,
  evidence_packet_hash text NOT NULL,
  provider text NOT NULL,
  model text NOT NULL,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','running','completed','failed','rejected')),
  evidence_packet jsonb,
  raw_output jsonb,
  validated_output jsonb,
  validation_report jsonb,
  error_message text,
  created_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz
);
GRANT SELECT ON public.ai_analyses TO authenticated;
GRANT ALL ON public.ai_analyses TO service_role;
ALTER TABLE public.ai_analyses ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Read own ai analyses" ON public.ai_analyses FOR SELECT TO authenticated
  USING (user_id = auth.uid() AND public.owns_research_query(research_query_id));
-- Idempotency/cache: one analysis per job + evidence hash + analysis version + model.
CREATE UNIQUE INDEX ai_analyses_cache_key ON public.ai_analyses (research_query_id, evidence_packet_hash, analysis_version, model);

CREATE TABLE public.ai_usage (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  ai_analysis_id uuid REFERENCES public.ai_analyses(id) ON DELETE SET NULL,
  research_query_id uuid REFERENCES public.research_queries(id) ON DELETE SET NULL,
  user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  provider text NOT NULL,
  model text NOT NULL,
  analysis_version text NOT NULL,
  evidence_packet_hash text NOT NULL,
  request_id text,
  status text NOT NULL CHECK (status IN ('started','completed','failed','timeout','cache_hit','refused_ceiling')),
  input_tokens integer,
  cached_input_tokens integer,
  output_tokens integer,
  cost_usd numeric,
  cost_status text NOT NULL DEFAULT 'unknown' CHECK (cost_status IN ('final','estimated','unknown')),
  created_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz
);
GRANT ALL ON public.ai_usage TO service_role;
ALTER TABLE public.ai_usage ENABLE ROW LEVEL SECURITY;
-- No user policies: usage/cost records are server-only.