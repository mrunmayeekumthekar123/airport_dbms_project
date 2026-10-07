-- Airport Control System (4 tables: crew, passenger, flight, terminal)
-- Run this whole file once in Supabase > SQL Editor. Safe to re-run: it resets everything.

drop table if exists terminal, passenger, flight, crew, airline cascade;

create table crew (
  crew_id      int primary key,
  name         text not null,
  role         text not null,
  airline_id   int,
  phone_number text check (phone_number ~ '^[0-9]{10}$')
);

-- flight doubles as the airline table: airline_id is unique, so other tables can reference it
create table flight (
  flight_id       text not null,
  airline_id      int  not null unique,
  airline_name    text not null,
  terminal_number int,
  capacity        int  not null check (capacity > 0),
  crew_id         int,
  destination     text,
  arrival_time    timestamp,
  primary key (flight_id, airline_id)
);

create table passenger (
  passenger_id     int primary key,
  name             text not null,
  passport_details text not null unique,
  airline_id       int,
  seat_number      text,
  phone_number     text check (phone_number ~ '^[0-9]{10}$'),
  dob              date check (dob <= current_date)
);

create table terminal (
  terminal_no int primary key,
  flight_id   text,
  status      text not null default 'Free'
              check (status in ('Occupied','Free','Expecting Arrival','Under Maintenance')),
  airline_id  int
);

-- ---------- data: crew 40, flight 30, passenger 45, terminal 40 ----------
insert into crew
select i,
  (array['Rahul','Priya','Amit','Sneha','Vikram','Anjali','Rohan','Neha','Karan','Pooja'])[i%10+1] || ' ' ||
  (array['Sharma','Patel','Singh','Iyer','Nair','Kulkarni','Mehta','Joshi'])[i%8+1],
  (array['Pilot','Co-pilot','Cabin Crew','Flight Engineer'])[i%4+1],
  (i-1)%30+1,
  '9' || lpad(((i*7654321) % 1000000000)::text, 9, '0')
from generate_series(1,40) i;

with a as (
  select i,
    (array['Air India','IndiGo','SpiceJet','Vistara','Akasa Air','Air India Express','Alliance Air',
           'Emirates','Qatar Airways','Etihad','Singapore Airlines','Lufthansa','British Airways',
           'Air France','KLM','Turkish Airlines','Thai Airways','Cathay Pacific','Qantas','Delta',
           'United','American Airlines','Air Canada','Japan Airlines','Korean Air','Saudia',
           'Oman Air','Gulf Air','Kuwait Airways','Swiss'])[i] as n,
    (array['AI','6E','SG','UK','QP','IX','9I','EK','QR','EY','SQ','LH','BA','AF','KL','TK','TG',
           'CX','QF','DL','UA','AA','AC','JL','KE','SV','WY','GF','KU','LX'])[i] as code
  from generate_series(1,30) i)
insert into flight (flight_id, airline_id, airline_name, terminal_number, capacity, crew_id, destination, arrival_time)
select code || (100 + i*7), i, n, i, 150 + (i%6)*30, i,
  (array['Delhi','Mumbai','Dubai','London','Singapore','Paris','Doha','Bangkok','Tokyo',
         'Frankfurt','Sydney','Toronto','Seoul','Riyadh','Muscat'])[i%15+1],
  timestamp '2026-10-05 06:00' + i * interval '47 minutes'
from a;

insert into passenger
select i,
  (array['Aarav','Diya','Ishaan','Meera','Kabir','Tara','Arjun','Nisha','Dev','Riya'])[i*3%10+1] || ' ' ||
  (array['Reddy','Gupta','Desai','Menon','Bose','Verma','Kapoor','Rao'])[i*5%8+1],
  'P' || lpad(((i*1234567) % 10000000)::text, 7, '0'),
  (i-1)%30+1,
  (i%30+1) || (array['A','B','C','D','E','F'])[i%6+1],
  '8' || lpad(((i*9876543) % 1000000000)::text, 9, '0'),
  date '1965-03-01' + i*331
from generate_series(1,45) i;

-- terminals 1-30 each serve one flight, 31-35 are free, 36-40 under maintenance
insert into terminal
select i,
  case when i <= 30 then f.flight_id end,
  case when i <= 30 then (case when i%2=0 then 'Occupied' else 'Expecting Arrival' end)
       when i <= 35 then 'Free' else 'Under Maintenance' end,
  case when i <= 30 then i end
from generate_series(1,40) i
left join flight f on f.airline_id = i;

-- ---------- foreign keys (added after the data because flight and crew refer to each other) ----------
alter table flight    add foreign key (crew_id)    references crew(crew_id)     on delete set null;
alter table crew      add foreign key (airline_id) references flight(airline_id) on delete set null;
alter table passenger add foreign key (airline_id) references flight(airline_id) on delete set null;
alter table terminal  add foreign key (flight_id, airline_id)
                      references flight(flight_id, airline_id) on delete set null;

-- ---------- let the website (anon key) read and write ----------
do $$
declare t text;
begin
  foreach t in array array['crew','passenger','flight','terminal'] loop
    execute format('alter table %I enable row level security', t);
    execute format('create policy open_all on %I for all to anon using (true) with check (true)', t);
    execute format('grant all on %I to anon', t);
  end loop;
end $$;


-- ================= PART 2: controller login =================
-- Passwords are handled by Supabase Auth (hashed). This table holds the controller's profile.

drop function if exists handle_new_controller() cascade;
drop table if exists controller cascade;

create table controller (
  controller_id uuid primary key references auth.users(id) on delete cascade,
  full_name     text not null,
  employee_id   text not null unique,
  email         text not null unique,
  phone_number  text not null check (phone_number ~ '^[0-9]{10}$'),
  shift         text not null default 'Morning' check (shift in ('Morning','Evening','Night')),
  created_at    timestamptz not null default now()
);

-- trigger: when someone registers, a controller row is created automatically from the form data
create function handle_new_controller() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into controller (controller_id, full_name, employee_id, email, phone_number, shift)
  values (new.id,
          new.raw_user_meta_data->>'full_name',
          new.raw_user_meta_data->>'employee_id',
          new.email,
          new.raw_user_meta_data->>'phone_number',
          coalesce(nullif(new.raw_user_meta_data->>'shift',''), 'Morning'));
  return new;
end $$;

create trigger on_controller_signup after insert on auth.users
for each row execute function handle_new_controller();

-- a controller can only see and edit their own profile
alter table controller enable row level security;
create policy own_profile_read   on controller for select to authenticated using (controller_id = auth.uid());
create policy own_profile_update on controller for update to authenticated
  using (controller_id = auth.uid()) with check (controller_id = auth.uid());
grant select, update on controller to authenticated;

-- airport tables: only logged-in controllers can read or write (anonymous visitors get nothing)
do $$
declare t text;
begin
  foreach t in array array['crew','passenger','flight','terminal'] loop
    execute format('drop policy if exists open_all on %I', t);
    execute format('drop policy if exists staff_only on %I', t);
    execute format('create policy staff_only on %I for all to authenticated using (true) with check (true)', t);
    execute format('grant all on %I to authenticated', t);
  end loop;
end $$;
