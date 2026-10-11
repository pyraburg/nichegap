-- Phase 6.1: Research Credit ledger + reservations. Balances are derived from an immutable ledger.

-- Existing jobs are legacy/pre-credit (never charged); new rows default to credit billing.
ALTER TABLE public.research_queries ADD COLUMN IF NOT EXISTS billing text NOT NULL DEFAULT 'legacy';
ALTER TABLE public.research_queries ALTER COLUMN billing SET DEFAULT 'credit';
DROP POLICY IF EXISTS "Own queries insert" ON public.research_queries;
CREATE POLICY "Own queries insert" ON public.research_queries FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid() AND status = 'pending' AND billing = 'credit' AND pipeline_version IS NULL);

CREATE TABLE public.credit_reservations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  research_query_id uuid NOT NULL UNIQUE,
  idempotency_key text NOT NULL UNIQUE,
  credit_type text NOT NULL CHECK (credit_type IN ('monthly', 'purchased')),
  amount integer NOT NULL DEFAULT 1 CHECK (amount = 1),
  status text NOT NULL DEFAULT 'reserved' CHECK (status IN ('reserved', 'finalized', 'released')),
  created_at timestamptz NOT NULL DEFAULT now(),
  finalized_at timestamptz,
  released_at timestamptz
);
GRANT SELECT ON public.credit_reservations TO authenticated;
GRANT ALL ON public.credit_reservations TO service_role;
ALTER TABLE public.credit_reservations ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Read own reservations" ON public.credit_reservations FOR SELECT TO authenticated USING (user_id = auth.uid());

CREATE TABLE public.credit_ledger (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  amount integer NOT NULL,
  credit_type text NOT NULL CHECK (credit_type IN ('monthly', 'purchased')),
  event_type text NOT NULL CHECK (event_type IN ('monthly_allocation', 'topup_purchase', 'research_reservation', 'research_finalized', 'research_release', 'admin_adjustment', 'monthly_reset')),
  research_query_id uuid,
  reservation_id uuid,
  idempotency_key text NOT NULL UNIQUE,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (amount <> 0 OR event_type = 'research_finalized')
);
CREATE INDEX credit_ledger_user_idx ON public.credit_ledger (user_id, created_at);
GRANT SELECT ON public.credit_ledger TO authenticated;
GRANT ALL ON public.credit_ledger TO service_role;
ALTER TABLE public.credit_ledger ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Read own ledger" ON public.credit_ledger FOR SELECT TO authenticated USING (user_id = auth.uid());

CREATE OR REPLACE FUNCTION public.prevent_ledger_mutation()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN RAISE EXCEPTION 'credit_ledger is append-only'; END; $$;
CREATE TRIGGER credit_ledger_immutable BEFORE UPDATE OR DELETE ON public.credit_ledger
  FOR EACH ROW EXECUTE FUNCTION public.prevent_ledger_mutation();

-- Balance per credit type, derived from the ledger (reservations are already debited).
CREATE OR REPLACE FUNCTION public.credit_balance(_user uuid)
RETURNS TABLE (monthly integer, purchased integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(SUM(amount) FILTER (WHERE credit_type = 'monthly'), 0)::int,
         COALESCE(SUM(amount) FILTER (WHERE credit_type = 'purchased'), 0)::int
  FROM public.credit_ledger WHERE user_id = _user
$$;

-- The only balance read customers can call: their own, via auth.uid().
CREATE OR REPLACE FUNCTION public.get_my_credit_balance()
RETURNS TABLE (monthly integer, purchased integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT b.monthly, b.purchased FROM public.credit_balance(auth.uid()) b
$$;

-- Credits in (monthly allocation, top-up, admin adjustment). Idempotent on key.
CREATE OR REPLACE FUNCTION public.grant_research_credits(_user uuid, _amount integer, _type text, _event text, _key text, _metadata jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE b record; existing uuid; new_id uuid;
BEGIN
  IF _event NOT IN ('monthly_allocation', 'topup_purchase', 'admin_adjustment') THEN RAISE EXCEPTION 'invalid grant event %', _event; END IF;
  IF _amount = 0 OR (_amount < 0 AND _event <> 'admin_adjustment') THEN RAISE EXCEPTION 'invalid amount'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(_user::text, 0));
  SELECT id INTO existing FROM public.credit_ledger WHERE idempotency_key = _key;
  IF FOUND THEN RETURN jsonb_build_object('status', 'duplicate', 'ledger_id', existing); END IF;
  IF _amount < 0 THEN
    SELECT * INTO b FROM public.credit_balance(_user);
    IF (CASE WHEN _type = 'monthly' THEN b.monthly ELSE b.purchased END) + _amount < 0 THEN RAISE EXCEPTION 'adjustment would make balance negative'; END IF;
  END IF;
  INSERT INTO public.credit_ledger (user_id, amount, credit_type, event_type, idempotency_key, metadata)
  VALUES (_user, _amount, _type, _event, _key, COALESCE(_metadata, '{}'::jsonb)) RETURNING id INTO new_id;
  RETURN jsonb_build_object('status', 'granted', 'ledger_id', new_id);
END; $$;

-- Subscription period refresh: unused monthly credits expire, then the new allocation is added. Idempotent per period.
CREATE OR REPLACE FUNCTION public.allocate_monthly_credits(_user uuid, _amount integer, _period_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE b record; k text := 'monthly:' || _user || ':' || _period_key;
BEGIN
  IF _amount <= 0 THEN RAISE EXCEPTION 'invalid amount'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(_user::text, 0));
  IF EXISTS (SELECT 1 FROM public.credit_ledger WHERE idempotency_key = k) THEN RETURN jsonb_build_object('status', 'duplicate'); END IF;
  SELECT * INTO b FROM public.credit_balance(_user);
  IF b.monthly > 0 THEN
    INSERT INTO public.credit_ledger (user_id, amount, credit_type, event_type, idempotency_key, metadata)
    VALUES (_user, -b.monthly, 'monthly', 'monthly_reset', 'monthly_reset:' || _user || ':' || _period_key, jsonb_build_object('period', _period_key));
  END IF;
  INSERT INTO public.credit_ledger (user_id, amount, credit_type, event_type, idempotency_key, metadata)
  VALUES (_user, _amount, 'monthly', 'monthly_allocation', k, jsonb_build_object('period', _period_key));
  RETURN jsonb_build_object('status', 'allocated', 'expired', GREATEST(b.monthly, 0));
END; $$;

-- Reserve exactly one credit for one research job (monthly first). Serialized per user; idempotent per job.
CREATE OR REPLACE FUNCTION public.reserve_research_credit(_user uuid, _job uuid, _key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r record; b record; t text; rid uuid;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(_user::text, 0));
  IF NOT EXISTS (SELECT 1 FROM public.research_queries WHERE id = _job AND user_id = _user AND billing = 'credit') THEN
    RAISE EXCEPTION 'job not eligible for credit reservation';
  END IF;
  SELECT * INTO r FROM public.credit_reservations WHERE research_query_id = _job OR idempotency_key = _key LIMIT 1;
  IF FOUND THEN
    IF r.research_query_id <> _job OR r.user_id <> _user THEN RAISE EXCEPTION 'idempotency key reused'; END IF;
    RETURN jsonb_build_object('status', r.status, 'reservation_id', r.id, 'credit_type', r.credit_type, 'existing', true);
  END IF;
  SELECT * INTO b FROM public.credit_balance(_user);
  IF b.monthly + b.purchased < 1 THEN RETURN jsonb_build_object('status', 'insufficient'); END IF;
  t := CASE WHEN b.monthly >= 1 THEN 'monthly' ELSE 'purchased' END;
  INSERT INTO public.credit_reservations (user_id, research_query_id, idempotency_key, credit_type)
  VALUES (_user, _job, _key, t) RETURNING id INTO rid;
  INSERT INTO public.credit_ledger (user_id, amount, credit_type, event_type, research_query_id, reservation_id, idempotency_key)
  VALUES (_user, -1, t, 'research_reservation', _job, rid, 'reserve:' || rid);
  RETURN jsonb_build_object('status', 'reserved', 'reservation_id', rid, 'credit_type', t, 'existing', false);
END; $$;

CREATE OR REPLACE FUNCTION public.finalize_research_credit(_job uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r record;
BEGIN
  UPDATE public.credit_reservations SET status = 'finalized', finalized_at = now()
  WHERE research_query_id = _job AND status = 'reserved' RETURNING * INTO r;
  IF NOT FOUND THEN
    SELECT * INTO r FROM public.credit_reservations WHERE research_query_id = _job;
    RETURN jsonb_build_object('status', COALESCE(r.status, 'none'));
  END IF;
  INSERT INTO public.credit_ledger (user_id, amount, credit_type, event_type, research_query_id, reservation_id, idempotency_key)
  VALUES (r.user_id, 0, r.credit_type, 'research_finalized', _job, r.id, 'finalize:' || r.id);
  RETURN jsonb_build_object('status', 'finalized', 'reservation_id', r.id);
END; $$;

CREATE OR REPLACE FUNCTION public.release_research_credit(_job uuid, _reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r record;
BEGIN
  UPDATE public.credit_reservations SET status = 'released', released_at = now()
  WHERE research_query_id = _job AND status = 'reserved' RETURNING * INTO r;
  IF NOT FOUND THEN
    SELECT * INTO r FROM public.credit_reservations WHERE research_query_id = _job;
    RETURN jsonb_build_object('status', COALESCE(r.status, 'none'));
  END IF;
  INSERT INTO public.credit_ledger (user_id, amount, credit_type, event_type, research_query_id, reservation_id, idempotency_key, metadata)
  VALUES (r.user_id, 1, r.credit_type, 'research_release', _job, r.id, 'release:' || r.id, jsonb_build_object('reason', _reason));
  RETURN jsonb_build_object('status', 'released', 'reservation_id', r.id);
END; $$;

-- Only server code (service role) may move credits. Customers can only read their own balance.
REVOKE ALL ON FUNCTION public.credit_balance(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.grant_research_credits(uuid, integer, text, text, text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.allocate_monthly_credits(uuid, integer, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.reserve_research_credit(uuid, uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.finalize_research_credit(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.release_research_credit(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.get_my_credit_balance() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_credit_balance() TO authenticated;
GRANT EXECUTE ON FUNCTION public.credit_balance(uuid), public.grant_research_credits(uuid, integer, text, text, text, jsonb),
  public.allocate_monthly_credits(uuid, integer, text), public.reserve_research_credit(uuid, uuid, text),
  public.finalize_research_credit(uuid), public.release_research_credit(uuid, text) TO service_role;