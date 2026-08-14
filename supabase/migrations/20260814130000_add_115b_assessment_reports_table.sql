-- The final roadmap/report was previously smuggled into the submissions
-- table by nesting it inside the `answers` jsonb column (answers.roadmap),
-- which left `answers` holding a doubly-wrapped object instead of the raw
-- survey answers. Give the generated report its own table and have the
-- submit RPC write to both in one call.

create table public."115b_assessment_reports" (
  id uuid primary key default gen_random_uuid(),
  submission_id uuid not null unique
    references public."115b_assessment_submissions"(id) on delete cascade,
  band_key text not null
    check (band_key in ('beginner', 'intermediate', 'advanced')),
  track_key text,
  fluency_score smallint not null
    check (fluency_score between 1 and 100),
  fluency_level smallint not null
    check (fluency_level between 1 and 7),
  roadmap jsonb not null
    check (jsonb_typeof(roadmap) = 'object'),
  app_version text not null,
  created_at timestamptz not null default now()
);

alter table public."115b_assessment_reports" enable row level security;

revoke all on table public."115b_assessment_reports" from anon, authenticated;

create policy "115b_reports_no_direct_client_access"
on public."115b_assessment_reports"
for all
to anon, authenticated
using (false)
with check (false);

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
  v_track text;
  v_answers jsonb;
  v_roadmap jsonb;
  v_submitted_at timestamptz;
  v_app_version text;
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
  v_roadmap := p_payload -> 'roadmap';
  v_app_version := left(coalesce(nullif(p_payload ->> 'app_version', ''), 'unknown'), 80);
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

  if v_roadmap is null or jsonb_typeof(v_roadmap) <> 'object' then
    raise exception 'Roadmap report is required';
  end if;

  v_track := nullif(left(coalesce(p_payload ->> 'track_key', ''), 60), '');

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
    v_track,
    coalesce((p_payload ->> 'paid')::boolean, false),
    coalesce(p_payload -> 'page_timestamps', '{}'::jsonb),
    v_app_version,
    v_submitted_at
  )
  on conflict (id) do nothing;

  insert into public."115b_assessment_reports" (
    submission_id,
    band_key,
    track_key,
    fluency_score,
    fluency_level,
    roadmap,
    app_version
  )
  values (
    p_submission_id,
    v_band,
    v_track,
    v_score,
    v_level,
    v_roadmap,
    v_app_version
  )
  on conflict (submission_id) do update set
    band_key = excluded.band_key,
    track_key = excluded.track_key,
    fluency_score = excluded.fluency_score,
    fluency_level = excluded.fluency_level,
    roadmap = excluded.roadmap,
    app_version = excluded.app_version;

  update public."115b_assessment_drafts"
  set status = 'completed',
      last_saved_at = now()
  where resume_token = p_resume_token
    and status = 'draft';

  return p_submission_id;
end;
$$;
