
alter table public.unit_production_queue
  add column request_key text,
  add column request_quantity bigint;

alter table public.unit_production_queue
  add constraint unit_production_queue_request_key_length_check
  check (
    request_key is null
    or char_length(request_key) between 8 and 128
  );

create unique index idx_unit_production_queue_player_request_key
  on public.unit_production_queue(player_id, request_key)
  where request_key is not null;

create or replace function public.nexora_start_unit_training_bulk(
  p_player_id bigint,
  p_city_id bigint,
  p_type text,
  p_requested_quantity bigint,
  p_request_key text
)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $function$
declare
  v_request_key text;
  v_existing public.unit_production_queue%rowtype;
  v_result jsonb;
  v_production_id bigint;
begin
  v_request_key := nullif(btrim(coalesce(p_request_key,'')),'');

  if v_request_key is null then
    return public.nexora_start_unit_training_bulk(
      p_player_id,
      p_city_id,
      p_type,
      p_requested_quantity
    );
  end if;

  if char_length(v_request_key) < 8 or char_length(v_request_key) > 128 then
    return jsonb_build_object(
      'success', false,
      'code', 'INVALID_REQUEST_KEY',
      'message', 'Geçersiz üretim istek anahtarı.'
    );
  end if;

  if p_player_id is null or p_player_id <= 0 then
    return jsonb_build_object(
      'success', false,
      'code', 'INVALID_PLAYER',
      'message', 'Geçersiz oyuncu.'
    );
  end if;

  -- Serialize idempotent unit-training requests for this player. The legacy
  -- four-argument function still owns all resource/capacity/city row locks.
  perform pg_advisory_xact_lock(p_player_id);

  select *
    into v_existing
    from public.unit_production_queue
   where player_id = p_player_id
     and request_key = v_request_key
   order by id
   limit 1;

  if v_existing.id is not null then
    if v_existing.city_id <> p_city_id
       or v_existing.unit_type is distinct from p_type
       or v_existing.request_quantity is distinct from p_requested_quantity then
      return jsonb_build_object(
        'success', false,
        'code', 'IDEMPOTENCY_KEY_REUSED',
        'message', 'Bu üretim istek anahtarı farklı bir işlem için zaten kullanılmış.'
      );
    end if;

    return jsonb_build_object(
      'success', true,
      'production', to_jsonb(v_existing),
      'requestedQuantity', v_existing.request_quantity,
      'acceptedQuantity', v_existing.quantity,
      'finishAt', v_existing.finish_at,
      'idempotentReplay', true
    );
  end if;

  v_result := public.nexora_start_unit_training_bulk(
    p_player_id,
    p_city_id,
    p_type,
    p_requested_quantity
  );

  if v_result is null
     or coalesce((v_result->>'success')::boolean,false) is not true then
    return v_result;
  end if;

  begin
    v_production_id := nullif(v_result->'production'->>'id','')::bigint;
  exception when others then
    raise exception 'Üretim kimliği doğrulanamadı.';
  end;

  if v_production_id is null or v_production_id <= 0 then
    raise exception 'Üretim kimliği doğrulanamadı.';
  end if;

  update public.unit_production_queue
     set request_key = v_request_key,
         request_quantity = p_requested_quantity
   where id = v_production_id
     and player_id = p_player_id
  returning * into v_existing;

  if v_existing.id is null then
    raise exception 'Üretim istek anahtarı kuyruğa kaydedilemedi.';
  end if;

  return v_result || jsonb_build_object(
    'production', to_jsonb(v_existing),
    'idempotentReplay', false
  );
end;
$function$;
