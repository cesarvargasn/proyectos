-- ============================================================
-- Match Night — Admin participation
-- Run in Supabase SQL editor (after the other migrations)
-- ============================================================

-- Column to store the admin's chosen partner
ALTER TABLE event_state ADD COLUMN IF NOT EXISTS admin_partner_id uuid REFERENCES participants(id) ON DELETE SET NULL;

-- Make email nullable so the admin can join with just a name
ALTER TABLE participants ALTER COLUMN email DROP NOT NULL;
