// supabaseClient.js
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// Proyecto CitasYa MVP (NO uses secret key en el front)
const SUPABASE_URL = 'https://dfrwfqciqhjgqufwordz.supabase.co';
const SUPABASE_ANON_KEY =
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImRmcndmcWNpcWhqZ3F1ZndvcmR6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjM1ODU3NzksImV4cCI6MjA3OTE2MTc3OX0.9g9ZFAxcAUq4MsXLVR_e7AMKK83-YjsEujiZ2KjAd0g';

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: {
    persistSession: true,
    autoRefreshToken: true,
    detectSessionInUrl: true,
  },
});
