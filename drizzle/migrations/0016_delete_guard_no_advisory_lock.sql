-- Rely on row locks + FK RESTRICT for serialization (an advisory lock here could deadlock with a reservation's FK check).
CREATE OR REPLACE FUNCTION public.guard_research_query_delete()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.credit_reservations WHERE research_query_id = OLD.id)
     OR EXISTS (SELECT 1 FROM public.credit_ledger WHERE research_query_id = OLD.id) THEN
    RAISE EXCEPTION 'research job has credit history and cannot be deleted' USING ERRCODE = '23503';
  END IF;
  IF OLD.status = 'processing' OR (OLD.pipeline_version IS NOT NULL AND OLD.status NOT IN ('completed','failed')) OR OLD.pipeline_lease_until > now() THEN
    RAISE EXCEPTION 'research job is in progress and cannot be deleted' USING ERRCODE = '55006';
  END IF;
  RETURN OLD;
END; $$;
REVOKE ALL ON FUNCTION public.guard_research_query_delete() FROM PUBLIC, anon, authenticated;