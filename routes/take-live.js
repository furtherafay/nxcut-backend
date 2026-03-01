import express from 'express';
import { createClient } from '@supabase/supabase-js';
import { Pool } from 'pg';
import { getMiddlewareSupabaseClient } from '../lib/middleware-client.js';
import { parseCookies } from '../lib/cookie-parser.js';

const router = express.Router();

/**
 * Escape SQL string for INSERT statement
 */
function escapeSqlString(value) {
  if (value === null || value === undefined) {
    return 'NULL';
  }
  if (typeof value === 'boolean') {
    return value ? 'true' : 'false';
  }
  if (typeof value === 'number') {
    return value.toString();
  }
  // Escape single quotes by doubling them
  return `'${String(value).replace(/'/g, "''")}'`;
}

/**
 * Format INSERT statement for a row
 */
function formatInsertStatement(table, columns, row) {
  const values = columns.map((col) => escapeSqlString(row[col])).join(', ');
  return `INSERT INTO public.${table} (${columns.join(', ')}) VALUES (${values});`;
}

/**
 * Extract project reference from Supabase URL
 */
function extractProjectRef(supabaseUrl) {
  try {
    const url = new URL(supabaseUrl);
    const hostname = url.hostname;
    // Remove .supabase.co from hostname
    const projectRef = hostname.replace('.supabase.co', '');
    return projectRef;
  } catch (error) {
    throw new Error(`Invalid Supabase URL: ${supabaseUrl}`);
  }
}

/**
 * Execute SQL on tenant database using pooler connection
 */
async function executeSqlOnTenantDatabase(
  supabaseUrl,
  databasePassword,
  sql,
  region = 'ap-south-1',
) {
  const projectRef = extractProjectRef(supabaseUrl);

  // Map region to pooler host format: aws-{index}-{region}.pooler.supabase.com
  const regionMap = {
    'ap-south-1': 'aws-1-ap-south-1.pooler.supabase.com',
    'ap-southeast-1': 'aws-1-ap-southeast-1.pooler.supabase.com',
  };

  const host = regionMap[region] || `aws-1-${region}.pooler.supabase.com`;
  const port = 5432;
  const user = `postgres.${projectRef}`;
  const database = 'postgres';

  const connectionString = `postgresql://${user}:${encodeURIComponent(databasePassword)}@${host}:${port}/${database}`;

  const pool = new Pool({
    connectionString,
    ssl: {
      rejectUnauthorized: false,
    },
    connectionTimeoutMillis: 120000,
  });

  try {
    console.log('Executing SQL on tenant database...');
    await pool.query(sql);
    console.log('SQL executed successfully on tenant database');
  } catch (queryError) {
    throw new Error(
      `Failed to execute SQL on tenant database: ${queryError instanceof Error ? queryError.message : 'Unknown error'}`,
    );
  } finally {
    await pool.end();
  }
}

router.post('/', async (req, res) => {
  try {
    // Verify admin authentication
    const cookies = parseCookies(req.headers.cookie);
    const adminSession = cookies.admin_session;

    if (!adminSession) {
      return res.status(401).json({ error: 'Unauthorized' });
    }

    // Verify the session is valid and user is super admin
    const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_MIDDLEWARE_URL;
    const anonKey =
      process.env.NEXT_PUBLIC_SUPABASE_MIDDLEWARE_ANON_KEY ||
      process.env.SUPABASE_MIDDLEWARE_SERVICE_ROLE_KEY;

    if (!supabaseUrl || !anonKey) {
      return res.status(500).json({ error: 'Server configuration error' });
    }

    const client = createClient(supabaseUrl, anonKey, {
      global: {
        headers: {
          Authorization: `Bearer ${adminSession}`,
        },
      },
    });

    const {
      data: { user },
      error: authError,
    } = await client.auth.getUser(adminSession);

    if (authError || !user) {
      return res.status(401).json({ error: 'Unauthorized' });
    }

    // Verify super admin status
    const isSuperAdmin =
      user.user_metadata?.is_super_admin === true ||
      user.app_metadata?.role === 'super_admin';

    if (!isSuperAdmin) {
      return res
        .status(403)
        .json({ error: 'Forbidden. Super admin access required.' });
    }

    // Get tenant ID from request body
    const { tenantId } = req.body;

    if (!tenantId) {
      return res.status(400).json({ error: 'Tenant ID is required' });
    }

    // Fetch tenant config to verify tenant exists
    const middlewareSupabase = getMiddlewareSupabaseClient();
    const { data: tenant, error: tenantError } = await middlewareSupabase
      .from('tenants')
      .select('id, name, supabase_url, database_password')
      .eq('id', tenantId)
      .single();

    if (tenantError || !tenant) {
      return res.status(404).json({ error: 'Tenant not found' });
    }

    // Check if tenant has a Supabase project
    if (!tenant.supabase_url) {
      return res.status(400).json({
        error: 'Tenant does not have a Supabase project yet',
      });
    }

    // Fetch data from middleware database using Supabase client
    const sqlStatements = [];

    try {
      // LOCATIONS
      const { data: locations, error: locationsError } = await middlewareSupabase
        .from('locations')
        .select('id, created_at, name, updated_at')
        .eq('tenant_id', tenantId);

      if (locationsError) {
        throw new Error(`Failed to fetch locations: ${locationsError.message}`);
      }

      if (locations && locations.length > 0) {
        locations.forEach((loc) => {
          sqlStatements.push(
            formatInsertStatement(
              'locations',
              ['id', 'created_at', 'name', 'updated_at'],
              loc,
            ),
          );
        });
      }

      // CLIENTS
      const { data: clients, error: clientsError } = await middlewareSupabase
        .from('clients')
        .select(
          'id, created_at, dob, email, first_name, last_name, location_id, notes, phone, updated_at',
        )
        .eq('tenant_id', tenantId);

      if (clientsError) {
        throw new Error(`Failed to fetch clients: ${clientsError.message}`);
      }

      if (clients && clients.length > 0) {
        clients.forEach((client) => {
          sqlStatements.push(
            formatInsertStatement(
              'clients',
              [
                'id',
                'created_at',
                'dob',
                'email',
                'first_name',
                'last_name',
                'location_id',
                'notes',
                'phone',
                'updated_at',
              ],
              client,
            ),
          );
        });
      }

      // MEMBERSHIPS
      const { data: memberships, error: membershipsError } =
        await middlewareSupabase
          .from('memberships')
          .select(
            'id, created_at, description, name, price, service_id, total_sessions, updated_at',
          )
          .eq('tenant_id', tenantId);

      if (membershipsError) {
        throw new Error(
          `Failed to fetch memberships: ${membershipsError.message}`,
        );
      }

      if (memberships && memberships.length > 0) {
        memberships.forEach((membership) => {
          sqlStatements.push(
            formatInsertStatement(
              'memberships',
              [
                'id',
                'created_at',
                'description',
                'name',
                'price',
                'service_id',
                'total_sessions',
                'updated_at',
              ],
              membership,
            ),
          );
        });
      }

      // VOUCHERS
      const { data: vouchers, error: vouchersError } = await middlewareSupabase
        .from('vouchers')
        .select(
          'id, created_at, created_by, description, discount_percentage, expiry_date, is_active, name, price, updated_at, updated_by, voucher_code',
        )
        .eq('tenant_id', tenantId);

      if (vouchersError) {
        throw new Error(`Failed to fetch vouchers: ${vouchersError.message}`);
      }

      if (vouchers && vouchers.length > 0) {
        vouchers.forEach((voucher) => {
          sqlStatements.push(
            formatInsertStatement(
              'vouchers',
              [
                'id',
                'created_at',
                'created_by',
                'description',
                'discount_percentage',
                'expiry_date',
                'is_active',
                'name',
                'price',
                'updated_at',
                'updated_by',
                'voucher_code',
              ],
              voucher,
            ),
          );
        });
      }

      // CLIENT MEMBERSHIPS
      const { data: clientMemberships, error: clientMembershipsError } =
        await middlewareSupabase
          .from('client_memberships')
          .select(
            'id, client_id, created_at, membership_id, purchase_date, purchase_sale_id, service_id, total_sessions, updated_at',
          )
          .eq('tenant_id', tenantId);

      if (clientMembershipsError) {
        throw new Error(
          `Failed to fetch client_memberships: ${clientMembershipsError.message}`,
        );
      }

      if (clientMemberships && clientMemberships.length > 0) {
        clientMemberships.forEach((cm) => {
          sqlStatements.push(
            formatInsertStatement(
              'client_memberships',
              [
                'id',
                'client_id',
                'created_at',
                'membership_id',
                'purchase_date',
                'purchase_sale_id',
                'service_id',
                'total_sessions',
                'updated_at',
              ],
              cm,
            ),
          );
        });
      }

      // CLIENT VOUCHERS
      const { data: clientVouchers, error: clientVouchersError } =
        await middlewareSupabase
          .from('client_vouchers')
          .select(
            'id, client_id, created_at, discount_percentage, original_value, purchase_date, purchase_sale_id, updated_at, voucher_code, voucher_id, client_voucher_code',
          )
          .eq('tenant_id', tenantId);

      if (clientVouchersError) {
        throw new Error(
          `Failed to fetch client_vouchers: ${clientVouchersError.message}`,
        );
      }

      if (clientVouchers && clientVouchers.length > 0) {
        clientVouchers.forEach((cv) => {
          sqlStatements.push(
            formatInsertStatement(
              'client_vouchers',
              [
                'id',
                'client_id',
                'created_at',
                'discount_percentage',
                'original_value',
                'purchase_date',
                'purchase_sale_id',
                'updated_at',
                'voucher_code',
                'voucher_id',
                'client_voucher_code',
              ],
              cv,
            ),
          );
        });
      }

      // PAYMENT METHODS
      const { data: paymentMethods, error: paymentMethodsError } =
        await middlewareSupabase
          .from('payment_methods')
          .select('id, created_at, is_active, name')
          .eq('tenant_id', tenantId);

      if (paymentMethodsError) {
        throw new Error(
          `Failed to fetch payment_methods: ${paymentMethodsError.message}`,
        );
      }

      if (paymentMethods && paymentMethods.length > 0) {
        paymentMethods.forEach((pm) => {
          sqlStatements.push(
            `INSERT INTO public.payment_methods (id, created_at, is_active, name, is_default) VALUES (${pm.id}, ${escapeSqlString(pm.created_at)}, ${escapeSqlString(pm.is_active)}, ${escapeSqlString(pm.name)}, false);`,
          );
        });
      }

      const sql = sqlStatements.join('\n\n');

      // TEAM MEMBERS
      const { data: teamMembers, error: teamMembersError } =
        await middlewareSupabase
          .from('team_members')
          .select(
            'id, tenant_id, calendar_color, created_at, email, first_name, image_url, is_active, "isAdmin", last_name, location_id, notes, "order", phone_number, team_member_id, updated_at, visible_to_clients',
          )
          .eq('tenant_id', tenantId);

      if (teamMembersError) {
        throw new Error(
          `Failed to fetch team_members: ${teamMembersError.message}`,
        );
      }

      if (teamMembers && teamMembers.length > 0) {
        teamMembers.forEach((tm) => {
          sqlStatements.push(
            formatInsertStatement(
              'team_members',
              [
                'id',
                'tenant_id',
                'calendar_color',
                'created_at',
                'email',
                'first_name',
                'image_url',
                'is_active',
                '"isAdmin"',
                'last_name',
                'location_id',
                'notes',
                '"order"',
                'phone_number',
                'team_member_id',
                'updated_at',
                'visible_to_clients',
              ],
              tm,
            ),
          );
        });
      }

      // Execute the SQL on the tenant's database
      if (tenant.supabase_url && tenant.database_password && sql.trim()) {
        try {
          // Extract project ref to get region from project API
          const projectRef = extractProjectRef(tenant.supabase_url);

          // Try to get region from project API, fallback to default
          let region = 'ap-south-1'; // Default
          try {
            const accessToken = process.env.SUPABASE_ACCESS_TOKEN;
            if (accessToken) {
              const projectResponse = await fetch(
                `https://api.supabase.com/v1/projects/${projectRef}`,
                {
                  headers: {
                    Authorization: `Bearer ${accessToken}`,
                  },
                },
              );
              if (projectResponse.ok) {
                const projectData = await projectResponse.json();
                region = projectData.region || 'ap-south-1';
              }
            }
          } catch (regionError) {
            console.warn(
              'Could not fetch region from API, using default:',
              regionError,
            );
          }

          await executeSqlOnTenantDatabase(
            tenant.supabase_url,
            tenant.database_password,
            sql,
            region,
          );

          // Update tenant status to 'live' after successfully pushing data
          const { error: statusUpdateError } = await middlewareSupabase
            .from('tenants')
            .update({ is_live: 'live' })
            .eq('id', tenantId);

          if (statusUpdateError) {
            console.error('Failed to update tenant status:', statusUpdateError);
          }

          return res.json({
            success: true,
            sql: sql,
            message: 'Tenant data fetched and pushed to database successfully',
          });
        } catch (executeError) {
          console.error(
            'Failed to execute SQL on tenant database:',
            executeError,
          );
          // Return the SQL even if execution fails, so user can run it manually
          return res.json({
            success: true,
            sql: sql,
            warning: 'SQL generated but failed to execute automatically',
            error:
              executeError instanceof Error
                ? executeError.message
                : 'Unknown error',
          });
        }
      }

      return res.json({
        success: true,
        sql: sql,
      });
    } catch (dbError) {
      console.error('Database query error:', dbError);
      return res.status(500).json({
        error: 'Failed to fetch tenant data',
        details: dbError instanceof Error ? dbError.message : 'Unknown error',
      });
    }
  } catch (error) {
    console.error('Unexpected error fetching tenant data:', error);
    return res.status(500).json({
      error: 'Internal server error',
      details: error instanceof Error ? error.message : 'Unknown error',
    });
  }
});

export default router;
