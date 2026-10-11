-- Referential integrity: credit records can never point at a missing job; a job with credit history cannot be deleted.
ALTER TABLE public.credit_reservations ADD CONSTRAINT credit_reservations_research_query_id_fkey
  FOREIGN KEY (research_query_id) REFERENCES public.research_queries(id) ON DELETE RESTRICT;
ALTER TABLE public.credit_ledger ADD CONSTRAINT credit_ledger_research_query_id_fkey
  FOREIGN KEY (research_query_id) REFERENCES public.research_queries(id) ON DELETE RESTRICT;

-- Database-level delete guard (applies to every role, incl. service role / admin cleanup).
-- Serialized with reserve/finalize/release via the same per-user advisory lock.
CREATE OR REPLACE FUNCTION public.guard_research_query_delete()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(OLD.user_id::text, 0));
  IF EXISTS (SELECT 1 FROM public.credit_reservations WHERE research_query_id = OLD.id)
     OR EXISTS (SELECT 1 FROM public.credit_ledger WHERE research_query_id = OLD.id) THEN
    RAISE EXCEPTION 'research job has credit history and cannot be deleted' USING ERRCODE = '23503';
  END IF;
  -- Re-read current state under the lock (OLD may be stale relative to a concurrent start).
  IF EXISTS (SELECT 1 FROM public.research_queries WHERE id = OLD.id AND (status = 'processing' OR (pipeline_version IS NOT NULL AND status NOT IN ('completed','failed')) OR pipeline_lease_until > now())) THEN
    RAISE EXCEPTION 'research job is in progress and cannot be deleted' USING ERRCODE = '55006';
  END IF;
  RETURN OLD;
END; $$;
REVOKE ALL ON FUNCTION public.guard_research_query_delete() FROM PUBLIC, anon, authenticated;
CREATE TRIGGER research_queries_delete_guard BEFORE DELETE ON public.research_queries
  FOR EACH ROW EXECUTE FUNCTION public.guard_research_query_delete();

-- Customers may only delete their own never-started jobs (the out-of-credits cleanup path).
DROP POLICY "Own queries delete" ON public.research_queries;
CREATE POLICY "Own unstarted queries delete" ON public.research_queries FOR DELETE TO authenticated
  USING (user_id = auth.uid() AND status = 'pending' AND pipeline_version IS NULL);

-- Reservation re-checks the job under the lock, so a concurrent delete either wins first (reserve raises) or is blocked.
-- (reserve_research_credit already takes the per-user lock before checking the job exists.)