import express from "express";
import { createClient } from "@supabase/supabase-js";
import { readFile } from "fs/promises";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { Pool, Client } from "pg";
import { getMiddlewareSupabaseClient } from "../lib/middleware-client.js";
import { parseCookies } from "../lib/cookie-parser.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const router = express.Router();

/**
 * Generate a secure random password for database using Web Crypto API
 */
function generateSecurePassword(length = 32) {
  const uppercase = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
  const lowercase = "abcdefghijklmnopqrstuvwxyz";
  const numbers = "0123456789";
  const special = "!@#$%^&*()_+-=[]{}|;:,.<>?";
  const allChars = uppercase + lowercase + numbers + special;

  // Use Web Crypto API for secure random generation
  const randomValues = new Uint8Array(length);
  crypto.getRandomValues(randomValues);

  // Ensure at least one character from each set
  let password = "";
  password += uppercase[randomValues[0] % uppercase.length];
  password += lowercase[randomValues[1] % lowercase.length];
  password += numbers[randomValues[2] % numbers.length];
  password += special[randomValues[3] % special.length];

  // Fill the rest with random characters
  for (let i = 4; i < length; i++) {
    password += allChars[randomValues[i] % allChars.length];
  }

  // Shuffle the password to avoid predictable pattern
  const passwordArray = password.split("");
  for (let i = passwordArray.length - 1; i > 0; i--) {
    const randomIndex = randomValues[i % randomValues.length] % (i + 1);
    [passwordArray[i], passwordArray[randomIndex]] = [
      passwordArray[randomIndex],
      passwordArray[i],
    ];
  }

  return passwordArray.join("");
}

/**
 * Wait for database to be ready using pooler connection with active polling
 */
async function waitForDatabase(
  projectRef,
  databasePassword,
  region,
  maxRetries = 60,
  delayMs = 5000,
) {
  const regionMap = {
    "ap-south-1": "aws-1-ap-south-1.pooler.supabase.com",
    "ap-southeast-1": "aws-1-ap-southeast-1.pooler.supabase.com",
  };

  const host = regionMap[region] || `aws-1-${region}.pooler.supabase.com`;
  const port = 5432;
  const user = `postgres.${projectRef}`;
  const database = "postgres";

  let retries = 0;

  while (retries < maxRetries) {
    const client = new Client({
      host,
      port,
      user,
      password: databasePassword,
      database,
      ssl: {
        rejectUnauthorized: false,
      },
      connectionTimeoutMillis: 5000,
    });

    try {
      await client.connect();
      await client.query("SELECT 1");
      await client.end();
      console.log(`Database is ready! (after ${retries + 1} attempts)`);
      return;
    } catch (err) {
      retries++;
      try {
        await client.end();
      } catch {
        // Ignore cleanup errors
      }

      if (retries < maxRetries) {
        console.log(
          `Database not ready yet, retrying in ${delayMs}ms... (attempt ${retries}/${maxRetries})`,
        );
        await new Promise((resolve) => setTimeout(resolve, delayMs));
      } else {
        throw new Error(
          `Database not ready after ${maxRetries} attempts (${(maxRetries * delayMs) / 1000}s): ${err instanceof Error ? err.message : "Unknown error"}`,
        );
      }
    }
  }
}

/**
 * Push schema to tenant database using pooler PostgreSQL connection
 */
async function pushSchemaToDatabase(
  projectRef,
  databasePassword,
  schemaFilePath,
  region = "ap-south-1",
) {
  const regionMap = {
    "ap-south-1": "aws-1-ap-south-1.pooler.supabase.com",
    "ap-southeast-1": "aws-1-ap-southeast-1.pooler.supabase.com",
  };

  const host = regionMap[region] || `aws-1-${region}.pooler.supabase.com`;
  const port = 5432;
  const user = `postgres.${projectRef}`;
  const database = "postgres";

  // Wait for database to be ready before pushing schema
  console.log("Waiting for database to be ready...");
  await waitForDatabase(projectRef, databasePassword, region);

  // Read the schema file
  let schemaSQL;
  try {
    schemaSQL = await readFile(schemaFilePath, "utf-8");
  } catch (fileError) {
    throw new Error(
      `Failed to read schema file at ${schemaFilePath}: ${fileError instanceof Error ? fileError.message : "Unknown error"}`,
    );
  }

  // Use pooler connection with Pool for schema execution
  const connectionString = `postgresql://${user}:${encodeURIComponent(databasePassword)}@${host}:${port}/${database}`;

  const pool = new Pool({
    connectionString,
    ssl: {
      rejectUnauthorized: false,
    },
    connectionTimeoutMillis: 120000,
  });

  try {
    console.log("Executing schema using pooler connection...");
    await pool.query(schemaSQL);
    console.log("Schema executed successfully");
  } catch (queryError) {
    throw new Error(
      `Failed to execute schema: ${queryError instanceof Error ? queryError.message : "Unknown error"}`,
    );
  } finally {
    await pool.end();
  }
}

/**
 * Fetch API keys from Supabase Management API
 */
async function fetchProjectApiKeys(projectRef, accessToken) {
  const response = await fetch(
    `https://api.supabase.com/v1/projects/${projectRef}/api-keys`,
    {
      headers: {
        Authorization: `Bearer ${accessToken}`,
      },
    },
  );

  if (!response.ok) {
    throw new Error(
      `Failed to fetch API keys: ${response.status} ${response.statusText}`,
    );
  }

  const apiKeys = await response.json();

  // Find anon and service_role keys
  const anonKey = apiKeys.find(
    (key) => key.name === "anon" && key.type === "legacy",
  )?.api_key;
  const serviceRoleKey = apiKeys.find(
    (key) => key.name === "service_role" && key.type === "legacy",
  )?.api_key;

  if (!anonKey || !serviceRoleKey) {
    throw new Error("Failed to find anon or service_role API keys");
  }

  return { anonKey, serviceRoleKey };
}

/**
 * Create auth user in tenant database
 */
async function createAuthUserInTenant(
  tenantSupabaseUrl,
  serviceRoleKey,
  email,
  password,
) {
  const tenantSupabase = createClient(tenantSupabaseUrl, serviceRoleKey, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  });

  const { error } = await tenantSupabase.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
  });

  if (error) {
    throw new Error(`Failed to create auth user: ${error.message}`);
  }
}

/**
 * Escape SQL string for INSERT statement
 */
function escapeSqlString(value) {
  if (value === null || value === undefined) {
    return "NULL";
  }
  if (typeof value === "boolean") {
    return value ? "true" : "false";
  }
  if (typeof value === "number") {
    return value.toString();
  }
  // Escape single quotes by doubling them
  return `'${String(value).replace(/'/g, "''")}'`;
}

/**
 * Format INSERT statement for a row
 */
function formatInsertStatement(table, columns, row) {
  const values = columns.map((col) => escapeSqlString(row[col])).join(", ");
  return `INSERT INTO public.${table} (${columns.join(", ")}) VALUES (${values});`;
}

/**
 * Extract project reference from Supabase URL
 */
function extractProjectRef(supabaseUrl) {
  try {
    const url = new URL(supabaseUrl);
    const hostname = url.hostname;
    // Remove .supabase.co from hostname
    const projectRef = hostname.replace(".supabase.co", "");
    return projectRef;
  } catch (error) {
    throw new Error(`Invalid Supabase URL: ${supabaseUrl}`);
  }
}

/**
 * Fetch and push tenant data to tenant database
 */
async function fetchAndPushTenantData(
  tenantId,
  tenantSupabaseUrl,
  databasePassword,
  region,
) {
  const middlewareSupabase = getMiddlewareSupabaseClient();
  const sqlStatements = [];

  // LOCATIONS
  const { data: locations, error: locationsError } = await middlewareSupabase
    .from("locations")
    .select("id, created_at, name, updated_at")
    .eq("tenant_id", tenantId);

  if (locationsError) {
    throw new Error(`Failed to fetch locations: ${locationsError.message}`);
  }

  if (locations && locations.length > 0) {
    locations.forEach((loc) => {
      sqlStatements.push(
        formatInsertStatement(
          "locations",
          ["id", "created_at", "name", "updated_at"],
          loc,
        ),
      );
    });
  }

  // CLIENTS
  const { data: clients, error: clientsError } = await middlewareSupabase
    .from("clients")
    .select(
      "id, created_at, dob, email, first_name, last_name, location_id, notes, phone, updated_at",
    )
    .eq("tenant_id", tenantId);

  if (clientsError) {
    throw new Error(`Failed to fetch clients: ${clientsError.message}`);
  }

  if (clients && clients.length > 0) {
    clients.forEach((client) => {
      sqlStatements.push(
        formatInsertStatement(
          "clients",
          [
            "id",
            "created_at",
            "dob",
            "email",
            "first_name",
            "last_name",
            "location_id",
            "notes",
            "phone",
            "updated_at",
          ],
          client,
        ),
      );
    });
  }

  // CATEGORIES
  const { data: categories, error: categoriesError } = await middlewareSupabase
    .from("categories")
    .select(
      `
    id,
    created_at,
    name,
    "photoUrl"
  `,
    )
    .eq("tenant_id", tenantId);

  if (categoriesError) {
    throw new Error(`Failed to fetch categories: ${categoriesError.message}`);
  }

  if (categories && categories.length > 0) {
    categories.forEach((category) => {
      sqlStatements.push(
        formatInsertStatement(
          "categories",
          ["id", "created_at", "name", '"photoUrl"'],
          category,
        ),
      );
    });
  }

  // SERVICE TEMPLATES
  // const { data: serviceTemplates, error: serviceTemplatesError } =
  //   await middlewareSupabase
  //     .from("service_templates")
  //     .select(
  //       `
  //   id,
  //   name,
  //   description,
  //   category,
  //   master_category,
  //   base_duration_minutes,
  //   created_at,
  //   updated_at
  // `,
  //     )
  //     .eq("tenant_id", tenantId); // Remove this if templates are global

  // if (serviceTemplatesError) {
  //   throw new Error(
  //     `Failed to fetch service_templates: ${serviceTemplatesError.message}`,
  //   );
  // }

  // if (serviceTemplates && serviceTemplates.length > 0) {
  //   serviceTemplates.forEach((template) => {
  //     sqlStatements.push(
  //       formatInsertStatement(
  //         "service_templates",
  //         [
  //           "id",
  //           "name",
  //           "description",
  //           "category",
  //           "master_category",
  //           "base_duration_minutes",
  //           "created_at",
  //           "updated_at",
  //         ],
  //         template,
  //       ),
  //     );
  //   });
  // }

  // SERVICES
  const { data: services, error: servicesError } = await middlewareSupabase
    .from("services")
    .select(
      `
  id,
  available_for,
  available_online,
  category,
  commissions,
  created_at,
  description,
  duration_minutes,
  extra_time,
  master_category,
  name,
  online_booking,
  price,
  resource,
  service_id,
  sku,
  tax,
  treatment_type,
  updated_at,
  use,
  voucher_sales
`,
    )
    .eq("tenant_id", tenantId);

  if (servicesError) {
    throw new Error(`Failed to fetch services: ${servicesError.message}`);
  }

  if (services && services.length > 0) {
    services.forEach((service) => {
      sqlStatements.push(
        formatInsertStatement(
          "services",
          [
            "id",
            "available_for",
            "available_online",
            "category",
            "commissions",
            "created_at",
            "description",
            "duration_minutes",
            "extra_time",
            "master_category",
            "name",
            "online_booking",
            "price",
            "resource",
            "service_id",
            "sku",
            "tax",
            "treatment_type",
            "updated_at",
            "use",
            "voucher_sales",
          ],
          service,
        ),
      );
    });
  }

  // MEMBERSHIPS
  const { data: memberships, error: membershipsError } =
    await middlewareSupabase
      .from("memberships")
      .select(
        "id, created_at, description, name, price, service_id, total_sessions, updated_at",
      )
      .eq("tenant_id", tenantId);

  if (membershipsError) {
    throw new Error(`Failed to fetch memberships: ${membershipsError.message}`);
  }

  if (memberships && memberships.length > 0) {
    memberships.forEach((membership) => {
      sqlStatements.push(
        formatInsertStatement(
          "memberships",
          [
            "id",
            "created_at",
            "description",
            "name",
            "price",
            "service_id",
            "total_sessions",
            "updated_at",
          ],
          membership,
        ),
      );
    });
  }

  // VOUCHERS
  const { data: vouchers, error: vouchersError } = await middlewareSupabase
    .from("vouchers")
    .select(
      "id, created_at, created_by, description, discount_percentage, expiry_date, is_active, name, price, updated_at, updated_by, voucher_code",
    )
    .eq("tenant_id", tenantId);

  if (vouchersError) {
    throw new Error(`Failed to fetch vouchers: ${vouchersError.message}`);
  }

  if (vouchers && vouchers.length > 0) {
    vouchers.forEach((voucher) => {
      sqlStatements.push(
        formatInsertStatement(
          "vouchers",
          [
            "id",
            "created_at",
            "created_by",
            "description",
            "discount_percentage",
            "expiry_date",
            "is_active",
            "name",
            "price",
            "updated_at",
            "updated_by",
            "voucher_code",
          ],
          voucher,
        ),
      );
    });
  }

  // CLIENT MEMBERSHIPS
  const { data: clientMemberships, error: clientMembershipsError } =
    await middlewareSupabase
      .from("client_memberships")
      .select(
        "id, client_id, created_at, membership_id, purchase_date, purchase_sale_id, service_id, total_sessions, updated_at",
      )
      .eq("tenant_id", tenantId);

  if (clientMembershipsError) {
    throw new Error(
      `Failed to fetch client_memberships: ${clientMembershipsError.message}`,
    );
  }

  if (clientMemberships && clientMemberships.length > 0) {
    clientMemberships.forEach((cm) => {
      sqlStatements.push(
        formatInsertStatement(
          "client_memberships",
          [
            "id",
            "client_id",
            "created_at",
            "membership_id",
            "purchase_date",
            "purchase_sale_id",
            "service_id",
            "total_sessions",
            "updated_at",
          ],
          cm,
        ),
      );
    });
  }

  // CLIENT VOUCHERS
  const { data: clientVouchers, error: clientVouchersError } =
    await middlewareSupabase
      .from("client_vouchers")
      .select(
        "id, client_id, created_at, discount_percentage, original_value, purchase_date, purchase_sale_id, updated_at, voucher_code, voucher_id, client_voucher_code",
      )
      .eq("tenant_id", tenantId);

  if (clientVouchersError) {
    throw new Error(
      `Failed to fetch client_vouchers: ${clientVouchersError.message}`,
    );
  }

  if (clientVouchers && clientVouchers.length > 0) {
    clientVouchers.forEach((cv) => {
      sqlStatements.push(
        formatInsertStatement(
          "client_vouchers",
          [
            "id",
            "client_id",
            "created_at",
            "discount_percentage",
            "original_value",
            "purchase_date",
            "purchase_sale_id",
            "updated_at",
            "voucher_code",
            "voucher_id",
            "client_voucher_code",
          ],
          cv,
        ),
      );
    });
  }

  // PAYMENT METHODS
  const { data: paymentMethods, error: paymentMethodsError } =
    await middlewareSupabase
      .from("payment_methods")
      .select("id, created_at, is_active, name")
      .eq("tenant_id", tenantId);

  if (paymentMethodsError) {
    throw new Error(
      `Failed to fetch payment_methods: ${paymentMethodsError.message}`,
    );
  }

  if (paymentMethods && paymentMethods.length > 0) {
    paymentMethods.forEach((pm) => {
      sqlStatements.push(
        `INSERT INTO public.payment_methods (id, created_at, is_active, name) VALUES (${pm.id}, ${escapeSqlString(pm.created_at)}, ${escapeSqlString(pm.is_active)}, ${escapeSqlString(pm.name)}, false);`,
      );
    });
  }

  // TEAM MEMBERS
  const { data: teamMembers, error: teamMembersError } =
    await middlewareSupabase
      .from("team_members")
      .select(
        'id, tenant_id, calendar_color, created_at, email, first_name, image_url, is_active, "isAdmin", last_name, location_id, notes, "order", phone_number, team_member_id, updated_at, visible_to_clients',
      )
      .eq("tenant_id", tenantId);

  if (teamMembersError) {
    throw new Error(
      `Failed to fetch team_members: ${teamMembersError.message}`,
    );
  }

  if (teamMembers && teamMembers.length > 0) {
    teamMembers.forEach((tm) => {
      sqlStatements.push(
        formatInsertStatement(
          "team_members",
          [
            "id",
            "tenant_id",
            "calendar_color",
            "created_at",
            "email",
            "first_name",
            "image_url",
            "is_active",
            '"isAdmin"',
            "last_name",
            "location_id",
            "notes",
            '"order"',
            "phone_number",
            "team_member_id",
            "updated_at",
            "visible_to_clients",
          ],
          tm,
        ),
      );
    });
  }

  // Execute the SQL on the tenant's database if there's data to push
  const sql = sqlStatements.join("\n\n");
  if (sql.trim()) {
    const projectRef = extractProjectRef(tenantSupabaseUrl);
    const regionMap = {
      "ap-south-1": "aws-1-ap-south-1.pooler.supabase.com",
      "ap-southeast-1": "aws-1-ap-southeast-1.pooler.supabase.com",
    };

    const host = regionMap[region] || `aws-1-${region}.pooler.supabase.com`;
    const port = 5432;
    const user = `postgres.${projectRef}`;
    const database = "postgres";

    const connectionString = `postgresql://${user}:${encodeURIComponent(databasePassword)}@${host}:${port}/${database}`;

    const pool = new Pool({
      connectionString,
      ssl: {
        rejectUnauthorized: false,
      },
      connectionTimeoutMillis: 120000,
    });

    try {
      console.log("Pushing tenant data to database...");
      await pool.query(sql);
      console.log("Tenant data pushed successfully");
    } catch (queryError) {
      throw new Error(
        `Failed to push tenant data: ${queryError instanceof Error ? queryError.message : "Unknown error"}`,
      );
    } finally {
      await pool.end();
    }
  }
}

router.post("/", async (req, res) => {
  try {
    // Verify admin authentication
    const cookies = parseCookies(req.headers.cookie);
    const adminSession = cookies.admin_session;

    if (!adminSession) {
      return res.status(401).json({ error: "Unauthorized" });
    }

    // Verify the session is valid and user is super admin
    const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_MIDDLEWARE_URL;
    const anonKey =
      process.env.NEXT_PUBLIC_SUPABASE_MIDDLEWARE_ANON_KEY ||
      process.env.SUPABASE_MIDDLEWARE_SERVICE_ROLE_KEY;

    if (!supabaseUrl || !anonKey) {
      return res.status(500).json({ error: "Server configuration error" });
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
      return res.status(401).json({ error: "Unauthorized" });
    }

    // Verify super admin status
    const isSuperAdmin =
      user.user_metadata?.is_super_admin === true ||
      user.app_metadata?.role === "super_admin";

    if (!isSuperAdmin) {
      return res
        .status(403)
        .json({ error: "Forbidden. Super admin access required." });
    }

    // Get tenant ID from request body
    const { tenantId } = req.body;

    if (!tenantId) {
      return res.status(400).json({ error: "Tenant ID is required" });
    }

    // Check for required environment variables
    const accessToken = process.env.SUPABASE_ACCESS_TOKEN;
    const orgId = process.env.SUPABASE_ORG_ID;

    if (!accessToken || !orgId) {
      return res.status(500).json({
        error: "Server configuration error",
        message:
          "SUPABASE_ACCESS_TOKEN and SUPABASE_ORG_ID must be set in environment variables.",
      });
    }

    // Fetch tenant config
    const middlewareSupabase = getMiddlewareSupabaseClient();
    const { data: tenant, error: tenantError } = await middlewareSupabase
      .from("tenants")
      .select(
        "id, name, salon_name, salon_slug, supabase_url, supabase_anon_key, database_password, is_live, email, password",
      )
      .eq("id", tenantId)
      .single();

    if (tenantError || !tenant) {
      return res.status(404).json({ error: "Tenant not found" });
    }

    // Check if tenant already has a Supabase project
    if (tenant.supabase_url) {
      // If is_live is not "ready" or "live", update it to "ready"
      if (tenant.is_live !== "ready" && tenant.is_live !== "live") {
        const { error: updateError } = await middlewareSupabase
          .from("tenants")
          .update({ is_live: "ready" })
          .eq("id", tenantId);

        if (updateError) {
          return res.status(500).json({
            error: "Failed to update tenant status",
            details: updateError.message,
          });
        }
      }

      return res.json({
        success: true,
        message: "Tenant already has a Supabase project",
        tenantId: tenant.id,
        projectUrl: tenant.supabase_url,
      });
    }

    // Generate or use existing database password
    let databasePassword = tenant.database_password;
    if (!databasePassword) {
      databasePassword = generateSecurePassword(32);
      // Store the password in the database before creating the project
      const { error: passwordUpdateError } = await middlewareSupabase
        .from("tenants")
        .update({ database_password: databasePassword })
        .eq("id", tenantId);

      if (passwordUpdateError) {
        return res.status(500).json({
          error: "Failed to store database password",
          details: passwordUpdateError.message,
        });
      }
    }

    // Create Supabase project using Management API
    const projectName = `tenant-${tenant.salon_name || tenant.name}`
      .toLowerCase()
      .replace(/[^a-z0-9-]/g, "-")
      .replace(/-+/g, "-")
      .replace(/^-|-$/g, "");

    const createProjectResponse = await fetch(
      "https://api.supabase.com/v1/projects",
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          name: projectName,
          organization_id: orgId,
          region: "ap-south-1",
          plan: "free",
          db_pass: databasePassword,
        }),
      },
    );

    if (!createProjectResponse.ok) {
      let errorText;
      try {
        const errorJson = await createProjectResponse.json();
        errorText =
          errorJson.message || errorJson.error || JSON.stringify(errorJson);
      } catch {
        errorText = await createProjectResponse.text();
      }
      return res.status(400).json({
        error: "Failed to create Supabase project",
        details: errorText,
        status: createProjectResponse.status,
      });
    }

    const projectData = await createProjectResponse.json();

    // Extract project details
    const projectRef = projectData.ref;
    const projectId = projectData.id;
    const tenantSupabaseUrl = `https://${projectRef}.supabase.co`;

    // Step 1: Push schema to the new database
    const projectRegion = projectData.region || "ap-south-1";
    try {
      const schemaFilePath = join(
        __dirname,
        "..",
        "migrations",
        "202601120002_init_schema.sql",
      );
      await pushSchemaToDatabase(
        projectRef,
        databasePassword,
        schemaFilePath,
        projectRegion,
      );
      console.log("Schema pushed successfully");
    } catch (schemaError) {
      console.error("Failed to push schema:", schemaError);
      return res.status(500).json({
        error: "Failed to push schema to database",
        details:
          schemaError instanceof Error ? schemaError.message : "Unknown error",
      });
    }

    // Step 2: Fetch API keys from Supabase Management API
    let tenantAnonKey;
    let tenantServiceRoleKey;

    try {
      const apiKeys = await fetchProjectApiKeys(projectRef, accessToken);
      tenantAnonKey = apiKeys.anonKey;
      tenantServiceRoleKey = apiKeys.serviceRoleKey;
      console.log("API keys fetched successfully");
    } catch (apiKeyError) {
      console.error("Failed to fetch API keys:", apiKeyError);
      return res.status(500).json({
        error: "Failed to fetch API keys",
        details:
          apiKeyError instanceof Error ? apiKeyError.message : "Unknown error",
      });
    }

    // Step 3: Update tenant record with project details and API keys
    const { error: updateError } = await middlewareSupabase
      .from("tenants")
      .update({
        supabase_url: tenantSupabaseUrl,
        supabase_anon_key: tenantAnonKey,
        supabase_service_role_key: tenantServiceRoleKey,
      })
      .eq("id", tenantId);

    if (updateError) {
      return res.status(500).json({
        error: "Project created but failed to update tenant record",
        details: updateError.message,
      });
    }

    // Step 4: Create auth user in tenant database
    if (tenant.email && tenant.password && tenantServiceRoleKey) {
      try {
        await createAuthUserInTenant(
          tenantSupabaseUrl,
          tenantServiceRoleKey,
          tenant.email,
          tenant.password,
        );
        console.log("Auth user created successfully");
      } catch (authUserError) {
        console.error("Failed to create auth user:", authUserError);
        // Log but don't fail - user can be created manually if needed
      }
    } else {
      console.warn(
        "Skipping auth user creation: missing email, password, or service role key",
      );
    }

    // Step 5: Insert into tenant_auth_members
    if (tenant.email) {
      const { data: usersList, error: listUsersError } =
        await middlewareSupabase.auth.admin.listUsers();

      if (listUsersError) {
        console.error(
          "Failed to list users from middleware auth:",
          listUsersError,
        );
      } else {
        const tenantAuthUser = usersList?.users?.find(
          (u) => u.email?.toLowerCase() === tenant.email?.toLowerCase(),
        );

        if (tenantAuthUser) {
          const { error: authMemberError } = await middlewareSupabase
            .from("tenant_auth_members")
            .insert({
              tenant_id: tenantId,
              supabase_user_id: tenantAuthUser.id,
              user_email: tenant.email,
            });

          if (authMemberError) {
            console.error(
              "Failed to create tenant_auth_members entry:",
              authMemberError,
            );
          }
        } else {
          console.warn(
            `No user found in middleware auth with email: ${tenant.email}`,
          );
        }
      }
    }

    // Step 6: Fetch and push tenant data to the new database
    try {
      console.log("Fetching and pushing tenant data...");
      await fetchAndPushTenantData(
        tenantId,
        tenantSupabaseUrl,
        databasePassword,
        projectRegion,
      );
      console.log("Tenant data pushed successfully");
    } catch (dataPushError) {
      console.error("Failed to push tenant data:", dataPushError);
      return res.status(500).json({
        error: "Failed to push tenant data to database",
        details:
          dataPushError instanceof Error
            ? dataPushError.message
            : "Unknown error",
      });
    }

    // Step 7: Update tenant status to 'live' after everything is complete
    const { error: statusUpdateError } = await middlewareSupabase
      .from("tenants")
      .update({ is_live: "live" })
      .eq("id", tenantId);

    if (statusUpdateError) {
      console.error(
        "Failed to update tenant status to live:",
        statusUpdateError,
      );
    }

    return res.json({
      success: true,
      message: "Tenant taken live successfully",
      tenantId: tenant.id,
      project: {
        id: projectId,
        ref: projectRef,
        name: projectName,
        url: tenantSupabaseUrl,
        status: projectData.status,
      },
    });
  } catch (error) {
    const errorMessage =
      error instanceof Error ? error.message : "Unknown error";

    return res.status(500).json({
      error: "Internal server error",
      details: errorMessage,
    });
  }
});

export default router;
