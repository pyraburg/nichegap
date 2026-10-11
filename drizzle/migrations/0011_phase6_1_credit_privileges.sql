-- Customers may only read their own credit rows; all writes go through service-role server functions.
REVOKE ALL ON public.credit_ledger FROM anon, authenticated;
REVOKE ALL ON public.credit_reservations FROM anon, authenticated;
GRANT SELECT ON public.credit_ledger TO authenticated;
GRANT SELECT ON public.credit_reservations TO authenticated;