-- One paid multi-query community run per research job + endpoint version (duplicate-execution lock).
CREATE UNIQUE INDEX IF NOT EXISTS external_api_usage_community_multi_once
  ON public.external_api_usage (research_query_id, endpoint)
  WHERE cache_hit = false AND endpoint LIKE 'actor:%#community_multi_v1';