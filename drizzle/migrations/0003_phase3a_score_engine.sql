ALTER TABLE public.opportunities
  ADD COLUMN IF NOT EXISTS score_confidence text,
  ADD COLUMN IF NOT EXISTS evidence_completeness_percent numeric,
  ADD COLUMN IF NOT EXISTS score_breakdown jsonb,
  ADD COLUMN IF NOT EXISTS score_classification text,
  ADD COLUMN IF NOT EXISTS evidence_hash text,
  ADD COLUMN IF NOT EXISTS scored_at timestamptz;

ALTER TABLE public.opportunities
  ADD CONSTRAINT opportunities_score_confidence_check
  CHECK (score_confidence IS NULL OR score_confidence IN ('high','medium','low','insufficient'));

CREATE INDEX IF NOT EXISTS opportunities_query_scored_idx ON public.opportunities (research_query_id, scored_at DESC);

CREATE TABLE public.score_runs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  research_query_id uuid NOT NULL REFERENCES public.research_queries(id) ON DELETE CASCADE,
  opportunity_id uuid REFERENCES public.opportunities(id) ON DELETE SET NULL,
  score_version text NOT NULL,
  evidence_hash text NOT NULL,
  evidence_research_data_ids uuid[] NOT NULL,
  result jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.score_runs TO authenticated;
GRANT ALL ON public.score_runs TO service_role;
ALTER TABLE public.score_runs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Read score runs via own query" ON public.score_runs
  FOR SELECT TO authenticated USING (public.owns_research_query(research_query_id));

-- Audit rows are immutable, even for the service role.
CREATE OR REPLACE FUNCTION public.prevent_score_run_mutation()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN RAISE EXCEPTION 'score_runs are immutable'; END; $$;
CREATE TRIGGER score_runs_immutable BEFORE UPDATE ON public.score_runs
  FOR EACH ROW EXECUTE FUNCTION public.prevent_score_run_mutation();