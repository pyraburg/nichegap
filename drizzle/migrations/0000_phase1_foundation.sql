CREATE OR REPLACE FUNCTION public.set_updated_at() RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END; $$;

CREATE TABLE public.profiles (
  id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email text,
  full_name text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT, INSERT, UPDATE ON public.profiles TO authenticated;
GRANT ALL ON public.profiles TO service_role;
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Own profile select" ON public.profiles FOR SELECT TO authenticated USING (id = auth.uid());
CREATE POLICY "Own profile insert" ON public.profiles FOR INSERT TO authenticated WITH CHECK (id = auth.uid());
CREATE POLICY "Own profile update" ON public.profiles FOR UPDATE TO authenticated USING (id = auth.uid()) WITH CHECK (id = auth.uid());
CREATE TRIGGER profiles_updated_at BEFORE UPDATE ON public.profiles FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

CREATE OR REPLACE FUNCTION public.handle_new_user() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.profiles (id, email, full_name)
  VALUES (NEW.id, NEW.email, NEW.raw_user_meta_data->>'full_name')
  ON CONFLICT (id) DO NOTHING;
  RETURN NEW;
END; $$;
CREATE TRIGGER on_auth_user_created AFTER INSERT ON auth.users FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

CREATE TABLE public.research_queries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  query text NOT NULL,
  target_country text NOT NULL DEFAULT 'US',
  language text NOT NULL DEFAULT 'en',
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','processing','completed','failed')),
  created_at timestamptz NOT NULL DEFAULT now(),
  started_at timestamptz,
  completed_at timestamptz,
  error_message text
);
CREATE INDEX research_queries_user_idx ON public.research_queries(user_id, created_at DESC);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.research_queries TO authenticated;
GRANT ALL ON public.research_queries TO service_role;
ALTER TABLE public.research_queries ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Own queries select" ON public.research_queries FOR SELECT TO authenticated USING (user_id = auth.uid());
CREATE POLICY "Own queries insert" ON public.research_queries FOR INSERT TO authenticated WITH CHECK (user_id = auth.uid() AND status = 'pending');
CREATE POLICY "Own queries delete" ON public.research_queries FOR DELETE TO authenticated USING (user_id = auth.uid());

CREATE OR REPLACE FUNCTION public.owns_research_query(_query_id uuid) RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.research_queries WHERE id = _query_id AND user_id = auth.uid())
$$;

CREATE TABLE public.research_data (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  research_query_id uuid NOT NULL REFERENCES public.research_queries(id) ON DELETE CASCADE,
  provider text NOT NULL,
  data_type text NOT NULL,
  source_query text,
  raw_data jsonb,
  processed_data jsonb,
  collected_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX research_data_query_idx ON public.research_data(research_query_id);
GRANT SELECT ON public.research_data TO authenticated;
GRANT ALL ON public.research_data TO service_role;
ALTER TABLE public.research_data ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Read data via own query" ON public.research_data FOR SELECT TO authenticated USING (public.owns_research_query(research_query_id));

CREATE TABLE public.opportunities (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  research_query_id uuid NOT NULL REFERENCES public.research_queries(id) ON DELETE CASCADE,
  title text,
  description text,
  demand_score numeric,
  competition_opportunity_score numeric,
  purchase_intent_score numeric,
  trend_score numeric,
  opportunity_score numeric,
  score_version text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX opportunities_query_idx ON public.opportunities(research_query_id);
GRANT SELECT ON public.opportunities TO authenticated;
GRANT ALL ON public.opportunities TO service_role;
ALTER TABLE public.opportunities ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Read opportunities via own query" ON public.opportunities FOR SELECT TO authenticated USING (public.owns_research_query(research_query_id));

CREATE TABLE public.reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  research_query_id uuid NOT NULL REFERENCES public.research_queries(id) ON DELETE CASCADE,
  opportunity_id uuid REFERENCES public.opportunities(id) ON DELETE SET NULL,
  status text NOT NULL DEFAULT 'draft',
  report_data jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX reports_user_idx ON public.reports(user_id);
GRANT SELECT ON public.reports TO authenticated;
GRANT ALL ON public.reports TO service_role;
ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Read own reports" ON public.reports FOR SELECT TO authenticated USING (user_id = auth.uid() AND public.owns_research_query(research_query_id));
CREATE TRIGGER reports_updated_at BEFORE UPDATE ON public.reports FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();