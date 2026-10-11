COMMENT ON COLUMN public.research_queries.billing IS 'legacy (pre-credit, never charged) | credit (customer, 1 Research Credit) | validation (admin-created internal test, never charged)';

CREATE TABLE public.validation_reviews (
  research_query_id uuid PRIMARY KEY REFERENCES public.research_queries(id) ON DELETE CASCADE,
  rating text NOT NULL CHECK (rating IN ('good','questionable','poor')),
  notes text CHECK (char_length(notes) <= 4000),
  reviewer_id uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
GRANT SELECT ON public.validation_reviews TO authenticated;
GRANT ALL ON public.validation_reviews TO service_role;
ALTER TABLE public.validation_reviews ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Admins read validation reviews" ON public.validation_reviews FOR SELECT TO authenticated USING (public.has_role(auth.uid(), 'admin'));
CREATE TRIGGER validation_reviews_updated_at BEFORE UPDATE ON public.validation_reviews FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();