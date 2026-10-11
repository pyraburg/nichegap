ALTER TABLE public.credit_ledger DROP CONSTRAINT credit_ledger_event_type_check;
ALTER TABLE public.credit_ledger ADD CONSTRAINT credit_ledger_event_type_check CHECK (event_type = ANY (ARRAY['monthly_allocation','topup_purchase','research_reservation','research_finalized','research_release','admin_adjustment','monthly_reset','monthly_expiry']));

-- Release returns the SAME credit type. A monthly credit released after its billing period rolled over is reinstated
-- as monthly (never purchased), flagged late_period, and expires at the next monthly reset / subscription expiry like any monthly credit.
CREATE OR REPLACE FUNCTION public.release_research_credit(_job uuid, _reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE r record; late boolean := false; uid uuid;
BEGIN
  SELECT user_id INTO uid FROM public.credit_reservations WHERE research_query_id = _job;
  IF uid IS NOT NULL THEN PERFORM pg_advisory_xact_lock(hashtextextended(uid::text, 0)); END IF;
  UPDATE public.credit_reservations SET status = 'released', released_at = now()
  WHERE research_query_id = _job AND status = 'reserved' RETURNING * INTO r;
  IF NOT FOUND THEN
    SELECT * INTO r FROM public.credit_reservations WHERE research_query_id = _job;
    RETURN jsonb_build_object('status', COALESCE(r.status, 'none'));
  END IF;
  IF r.credit_type = 'monthly' THEN
    late := EXISTS (SELECT 1 FROM public.credit_ledger WHERE user_id = r.user_id AND event_type IN ('monthly_allocation','monthly_reset','monthly_expiry') AND created_at > r.created_at);
  END IF;
  INSERT INTO public.credit_ledger (user_id, amount, credit_type, event_type, research_query_id, reservation_id, idempotency_key, metadata)
  VALUES (r.user_id, 1, r.credit_type, 'research_release', _job, r.id, 'release:' || r.id, jsonb_build_object('reason', _reason, 'late_period', late));
  RETURN jsonb_build_object('status', 'released', 'reservation_id', r.id, 'credit_type', r.credit_type, 'late_period', late);
END; $function$;

-- Finalize takes the same per-user lock so finalize/release are fully serialized.
CREATE OR REPLACE FUNCTION public.finalize_research_credit(_job uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE r record; uid uuid;
BEGIN
  SELECT user_id INTO uid FROM public.credit_reservations WHERE research_query_id = _job;
  IF uid IS NOT NULL THEN PERFORM pg_advisory_xact_lock(hashtextextended(uid::text, 0)); END IF;
  UPDATE public.credit_reservations SET status = 'finalized', finalized_at = now()
  WHERE research_query_id = _job AND status = 'reserved' RETURNING * INTO r;
  IF NOT FOUND THEN
    SELECT * INTO r FROM public.credit_reservations WHERE research_query_id = _job;
    RETURN jsonb_build_object('status', COALESCE(r.status, 'none'));
  END IF;
  INSERT INTO public.credit_ledger (user_id, amount, credit_type, event_type, research_query_id, reservation_id, idempotency_key)
  VALUES (r.user_id, 0, r.credit_type, 'research_finalized', _job, r.id, 'finalize:' || r.id);
  RETURN jsonb_build_object('status', 'finalized', 'reservation_id', r.id);
END; $function$;

-- End of paid subscription: remaining monthly credits expire; purchased credits untouched. Idempotent per key.
CREATE OR REPLACE FUNCTION public.expire_monthly_credits(_user uuid, _key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $function$
DECLARE b record;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended(_user::text, 0));
  IF EXISTS (SELECT 1 FROM public.credit_ledger WHERE idempotency_key = _key) THEN RETURN jsonb_build_object('status', 'duplicate'); END IF;
  SELECT * INTO b FROM public.credit_balance(_user);
  IF b.monthly <= 0 THEN RETURN jsonb_build_object('status', 'nothing_to_expire'); END IF;
  INSERT INTO public.credit_ledger (user_id, amount, credit_type, event_type, idempotency_key, metadata)
  VALUES (_user, -b.monthly, 'monthly', 'monthly_expiry', _key, jsonb_build_object('reason', 'subscription_ended'));
  RETURN jsonb_build_object('status', 'expired', 'amount', b.monthly);
END; $function$;
REVOKE ALL ON FUNCTION public.expire_monthly_credits(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.expire_monthly_credits(uuid, text) TO service_role;
REVOKE ALL ON FUNCTION public.release_research_credit(uuid, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.finalize_research_credit(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.release_research_credit(uuid, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.finalize_research_credit(uuid) TO service_role;