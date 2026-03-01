import { createClient } from '@supabase/supabase-js';

// Lazy initialization of the middleware Supabase client
let middlewareSupabaseInstance = null;

/**
 * Get or create the middleware Supabase client
 * Uses service role key to bypass RLS (server-side only)
 */
export function getMiddlewareSupabaseClient() {
  if (!middlewareSupabaseInstance) {
    const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_MIDDLEWARE_URL;
    const serviceRoleKey = process.env.SUPABASE_MIDDLEWARE_SERVICE_ROLE_KEY;

    if (!serviceRoleKey) {
      throw new Error(
        'SUPABASE_MIDDLEWARE_SERVICE_ROLE_KEY is not set in environment variables.',
      );
    }

    if (!supabaseUrl) {
      throw new Error(
        'NEXT_PUBLIC_SUPABASE_MIDDLEWARE_URL is not set in environment variables.',
      );
    }

    middlewareSupabaseInstance = createClient(supabaseUrl, serviceRoleKey, {
      auth: {
        autoRefreshToken: false,
        persistSession: false,
      },
    });
  }

  return middlewareSupabaseInstance;
}
