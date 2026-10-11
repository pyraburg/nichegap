CREATE TABLE public.provider_fetch_locks (
  cache_key text PRIMARY KEY,
  holder_job uuid NOT NULL,
  lease_token uuid NOT NULL,
  lease_until timestamptz NOT NULL,
  claimed_at timestamptz NOT NULL DEFAULT now()
);
GRANT ALL ON public.provider_fetch_locks TO service_role;
ALTER TABLE public.provider_fetch_locks ENABLE ROW LEVEL SECURITY;

-- Atomic single-flight claim: returns a token if this caller may make the paid request, NULL if another live holder exists.
-- Expired leases (crashed workers) are taken over. One short statement; no transaction spans the HTTP call.
CREATE OR REPLACE FUNCTION public.claim_provider_fetch(_key text, _job uuid, _ttl_seconds integer)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE t uuid := gen_random_uuid(); got uuid;
BEGIN
  IF _ttl_seconds < 1 OR _ttl_seconds > 600 THEN RAISE EXCEPTION 'invalid ttl'; END IF;
  INSERT INTO public.provider_fetch_locks (cache_key, holder_job, lease_token, lease_until)
  VALUES (_key, _job, t, now() + make_interval(secs => _ttl_seconds))
  ON CONFLICT (cache_key) DO UPDATE
    SET holder_job = EXCLUDED.holder_job, lease_token = EXCLUDED.lease_token, lease_until = EXCLUDED.lease_until, claimed_at = now()
    WHERE public.provider_fetch_locks.lease_until < now()
  RETURNING lease_token INTO got;
  RETURN got;
END; $$;

-- Release only by the current holder (stale workers whose lease was taken over cannot release the new holder).
CREATE OR REPLACE FUNCTION public.release_provider_fetch(_key text, _token uuid)
RETURNS boolean LANGUAGE sql SECURITY DEFINER SET search_path TO 'public' AS $$
  WITH d AS (DELETE FROM public.provider_fetch_locks WHERE cache_key = _key AND lease_token = _token RETURNING 1)
  SELECT EXISTS (SELECT 1 FROM d)
$$;

REVOKE ALL ON FUNCTION public.claim_provider_fetch(text, uuid, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.release_provider_fetch(text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_provider_fetch(text, uuid, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.release_provider_fetch(text, uuid) TO service_role;