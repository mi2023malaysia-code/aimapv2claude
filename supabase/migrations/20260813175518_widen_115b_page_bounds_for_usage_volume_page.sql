-- The wizard gained a new page (Tool & Skill Usage Volume) inserted before
-- Monthly Time & Cost, so the wizard now runs pages 1-8 (was 1-7) and the
-- locked/submitted state is now page 9 (was 8). Widen the page-number
-- constraints and the two RPCs that hardcode the old bounds to match.

alter table public."115b_assessment_drafts"
  drop constraint "115b_assessment_drafts_current_page_check";

alter table public."115b_assessment_drafts"
  add constraint "115b_assessment_drafts_current_page_check"
  check (current_page between 1 and 8);

alter table public."115b_assessment_submissions"
  drop constraint "115b_assessment_submissions_current_page_check";

update public."115b_assessment_submissions"
  set current_page = 9
  where current_page <> 9;

alter table public."115b_assessment_submissions"
  alter column current_page set default 9;

alter table public."115b_assessment_submissions"
  add constraint "115b_assessment_submissions_current_page_check"
  check (current_page = 9);

create or replace function public.save_115b_assessment_draft(
  p_resume_token uuid,
  p_current_page integer,
  p_answers jsonb,
  p_app_version text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_last_saved_at timestamptz;
begin
  if p_resume_token is null then
    raise exception 'Resume token is required';
  end if;

  if p_current_page < 1 or p_current_page > 8 then
    raise exception 'Current page must be between 1 and 8';
  end if;

  if p_answers is null or jsonb_typeof(p_answers) <> 'object' then
    raise exception 'Answers must be a JSON object';
  end if;

  if octet_length(p_answers::text) > 524288 then
    raise exception 'Draft payload is too large';
  end if;

  if nullif(trim(p_app_version), '') is null then
    raise exception 'App version is required';
  end if;

  insert into public."115b_assessment_drafts" (
    resume_token,
    current_page,
    answers,
    app_version,
    status,
    last_saved_at,
    expires_at
  )
  values (
    p_resume_token,
    p_current_page,
    p_answers,
    left(p_app_version, 80),
    'draft',
    now(),
    now() + interval '30 days'
  )
  on conflict (resume_token)
  do update set
    current_page = excluded.current_page,
    answers = excluded.answers,
    app_version = excluded.app_version,
    last_saved_at = now(),
    expires_at = now() + interval '30 days'
  where public."115b_assessment_drafts".status = 'draft'
  returning id, last_saved_at into v_id, v_last_saved_at;

  if v_id is null then
    raise exception 'Draft is no longer editable';
  end if;

  return jsonb_build_object(
    'id', v_id,
    'last_saved_at', v_last_saved_at
  );
end;
$$;

create or replace function public.submit_115b_assessment(
  p_submission_id uuid,
  p_resume_token uuid,
  p_payload jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_draft_id uuid;
  v_name text;
  v_email text;
  v_score integer;
  v_level integer;
  v_band text;
  v_answers jsonb;
  v_submitted_at timestamptz;
begin
  if p_submission_id is null then
    raise exception 'Submission ID is required';
  end if;

  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'Submission payload must be a JSON object';
  end if;

  if octet_length(p_payload::text) > 1048576 then
    raise exception 'Submission payload is too large';
  end if;

  v_name := nullif(trim(p_payload ->> 'name'), '');
  v_email := nullif(trim(p_payload ->> 'email'), '');
  v_score := coalesce(nullif(p_payload ->> 'fluency_score', '')::integer, 0);
  v_level := coalesce(nullif(p_payload ->> 'fluency_level', '')::integer, 0);
  v_band := nullif(p_payload ->> 'band_key', '');
  v_answers := p_payload -> 'answers';
  v_submitted_at := coalesce(
    nullif(p_payload ->> 'submitted_at', '')::timestamptz,
    now()
  );

  if v_name is null or char_length(v_name) > 80 then
    raise exception 'A valid name is required';
  end if;

  if v_email is null or char_length(v_email) > 120 then
    raise exception 'A valid email is required';
  end if;

  if v_score < 1 or v_score > 100 then
    raise exception 'Fluency score must be between 1 and 100';
  end if;

  if v_level < 1 or v_level > 7 then
    raise exception 'Fluency level must be between 1 and 7';
  end if;

  if v_band not in ('beginner', 'intermediate', 'advanced') then
    raise exception 'Invalid fluency band';
  end if;

  if v_answers is null or jsonb_typeof(v_answers) <> 'object' then
    raise exception 'Answers snapshot is required';
  end if;

  select id
  into v_draft_id
  from public."115b_assessment_drafts"
  where resume_token = p_resume_token
  limit 1;

  insert into public."115b_assessment_submissions" (
    id,
    source_draft_id,
    name,
    email,
    phone,
    consent_given,
    stage,
    current_page,
    answers,
    fluency_score,
    fluency_level,
    band_key,
    track_key,
    paid,
    page_timestamps,
    app_version,
    submitted_at
  )
  values (
    p_submission_id,
    v_draft_id,
    left(v_name, 80),
    left(v_email, 120),
    nullif(left(coalesce(p_payload ->> 'phone', ''), 40), ''),
    coalesce((p_payload ->> 'consent_given')::boolean, true),
    'submitted',
    9,
    v_answers,
    v_score,
    v_level,
    v_band,
    nullif(left(coalesce(p_payload ->> 'track_key', ''), 60), ''),
    coalesce((p_payload ->> 'paid')::boolean, false),
    coalesce(p_payload -> 'page_timestamps', '{}'::jsonb),
    left(coalesce(nullif(p_payload ->> 'app_version', ''), 'unknown'), 80),
    v_submitted_at
  )
  on conflict (id) do nothing;

  update public."115b_assessment_drafts"
  set status = 'completed',
      last_saved_at = now()
  where resume_token = p_resume_token
    and status = 'draft';

  return p_submission_id;
end;
$$;
