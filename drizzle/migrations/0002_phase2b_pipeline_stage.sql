ALTER TABLE public.research_queries
  ADD COLUMN IF NOT EXISTS stage TEXT NOT NULL DEFAULT 'keyword_demand'
  CHECK (stage IN ('keyword_demand', 'amazon_supply', 'complete'));

-- Existing completed jobs finished the keyword stage before Amazon existed.
UPDATE public.research_queries SET stage = 'complete' WHERE status = 'completed';
