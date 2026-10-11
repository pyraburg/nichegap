CREATE TABLE public.billing_subscriptions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  provider text NOT NULL DEFAULT 'lemonsqueezy',
  provider_subscription_id text NOT NULL UNIQUE,
  provider_customer_id text,
  variant_id text,
  status text NOT NULL,
  cancelled boolean NOT NULL DEFAULT false,
  renews_at timestamptz,
  ends_at timestamptz,
  test_mode boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT ALL ON public.billing_subscriptions TO service_role;
ALTER TABLE public.billing_subscriptions ENABLE ROW LEVEL SECURITY;
CREATE INDEX billing_subscriptions_user_idx ON public.billing_subscriptions(user_id);

CREATE TABLE public.billing_webhook_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  event_key text NOT NULL UNIQUE,
  event_name text NOT NULL,
  user_id uuid,
  outcome text NOT NULL,
  test_mode boolean,
  received_at timestamptz NOT NULL DEFAULT now()
);
GRANT ALL ON public.billing_webhook_events TO service_role;
ALTER TABLE public.billing_webhook_events ENABLE ROW LEVEL SECURITY;

-- Customer-safe plan view: no provider IDs.
CREATE OR REPLACE FUNCTION public.get_my_plan()
RETURNS TABLE(status text, cancelled boolean, renews_at timestamptz, ends_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT s.status, s.cancelled, s.renews_at, s.ends_at FROM public.billing_subscriptions s
  WHERE s.user_id = auth.uid() ORDER BY s.updated_at DESC LIMIT 1
$$;
REVOKE ALL ON FUNCTION public.get_my_plan() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_my_plan() TO authenticated;