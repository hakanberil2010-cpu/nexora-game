-- TERYNDIS 081 Trade Delivery Cron
-- Finalizes due trade deliveries independently of trade-page polling.
-- Keeps the 015 design intact by processing at most one transaction per cron run,
-- so every finalize call remains its own database transaction.

BEGIN;

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;

SELECT cron.schedule(
  'teryndis-trade-delivery',
  '10 seconds',
  $cron$
  SELECT public.nexora_trade_finalize_transaction(due.id)
  FROM (
    SELECT id
    FROM public.trade_transactions
    WHERE status IN ('in_transit','blocked')
      AND (
        (
          status = 'in_transit'
          AND COALESCE(delivery_at, created_at) <= now()
        )
        OR
        (
          status = 'blocked'
          AND COALESCE(delivery_retry_at, delivery_at, created_at) <= now()
        )
      )
    ORDER BY
      CASE WHEN status = 'in_transit' THEN 0 ELSE 1 END,
      CASE
        WHEN status = 'blocked'
          THEN COALESCE(delivery_retry_at, delivery_at, created_at)
        ELSE COALESCE(delivery_at, created_at)
      END,
      id
    LIMIT 1
  ) due;
  $cron$
);

COMMIT;
