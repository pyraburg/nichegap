ALTER TABLE public.reports
  ADD COLUMN IF NOT EXISTS score_run_id uuid REFERENCES public.score_runs(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS report_version text,
  ADD COLUMN IF NOT EXISTS generated_at timestamptz,
  ADD COLUMN IF NOT EXISTS finalized_at timestamptz;

CREATE INDEX IF NOT EXISTS reports_query_generated_idx ON public.reports (research_query_id, generated_at DESC);

-- Finalized reports are immutable snapshots.
CREATE OR REPLACE FUNCTION public.prevent_final_report_mutation()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  IF OLD.status = 'final' THEN
    RAISE EXCEPTION 'finalized reports are immutable; create a new report instead';
  END IF;
  RETURN NEW;
END; $$;
CREATE TRIGGER reports_final_immutable BEFORE UPDATE ON public.reports
  FOR EACH ROW EXECUTE FUNCTION public.prevent_final_report_mutation();