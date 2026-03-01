

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "http" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE TYPE "public"."appointment_status" AS ENUM (
    'scheduled',
    'completed',
    'paid',
    'void',
    'cancelled'
);


ALTER TYPE "public"."appointment_status" OWNER TO "postgres";


CREATE TYPE "public"."payment_method" AS ENUM (
    'cash',
    'card',
    'online',
    'voucher',
    'membership',
    'mixed',
    'pending',
    'courtesy'
);


ALTER TYPE "public"."payment_method" OWNER TO "postgres";


CREATE TYPE "public"."payment_method_tip" AS ENUM (
    'cash',
    'card'
);


ALTER TYPE "public"."payment_method_tip" OWNER TO "postgres";


CREATE TYPE "public"."permission_level" AS ENUM (
    'Low',
    'Medium',
    'High',
    'Admin'
);


ALTER TYPE "public"."permission_level" OWNER TO "postgres";


CREATE TYPE "public"."product_stock_update" AS (
	"product_id" "text",
	"quantity" integer
);


ALTER TYPE "public"."product_stock_update" OWNER TO "postgres";


CREATE TYPE "public"."sale_item_type" AS ENUM (
    'service',
    'product',
    'membership',
    'voucher'
);


ALTER TYPE "public"."sale_item_type" OWNER TO "postgres";


CREATE TYPE "public"."sale_status" AS ENUM (
    'void',
    'completed'
);


ALTER TYPE "public"."sale_status" OWNER TO "postgres";


CREATE TYPE "public"."sale_type" AS ENUM (
    'items',
    'services'
);


ALTER TYPE "public"."sale_type" OWNER TO "postgres";


CREATE TYPE "public"."voucher_status" AS ENUM (
    'active',
    'revoked'
);


ALTER TYPE "public"."voucher_status" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cash_movement_summary"("p_location_ids" "text"[], "p_start" timestamp with time zone, "p_end" timestamp with time zone) RETURNS TABLE("location_id" "text", "payment_type" "text", "payment_collected" numeric)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN QUERY
  WITH payments AS (
    SELECT 
        s.location_id,
        spm.payment_method::text AS payment_method,
        spm.payment_method_id,
        SUM(spm.amount::numeric) AS total_amount
    FROM sale_payment_methods spm
    INNER JOIN sales s 
        ON spm.sale_id = s.id
    WHERE s.location_id = ANY(p_location_ids)
      AND s.created_at >= p_start
      AND s.created_at <  p_end
      AND spm.is_voided = FALSE
      AND s.is_voided = FALSE
    GROUP BY s.location_id, spm.payment_method, spm.payment_method_id
  ),
  tips AS (
    SELECT 
        s.location_id,
        st.payment_method_id,
        SUM(st.amount::numeric) AS total_tip
    FROM sale_tips st
    INNER JOIN sales s 
        ON st.sale_id = s.id
    WHERE s.location_id = ANY(p_location_ids)
      AND s.created_at >= p_start
      AND s.created_at <  p_end
      AND st.is_voided = FALSE
      AND s.is_voided = FALSE
    GROUP BY s.location_id, st.payment_method_id
  )
  SELECT 
      p.location_id,
      p.payment_method AS payment_type,
      (p.total_amount + COALESCE(t.total_tip, 0)) AS payment_collected
  FROM payments p
  LEFT JOIN tips t
    ON t.location_id = p.location_id
   AND t.payment_method_id = p.payment_method_id
  ORDER BY p.location_id, p.payment_method;
END;
$$;


ALTER FUNCTION "public"."cash_movement_summary"("p_location_ids" "text"[], "p_start" timestamp with time zone, "p_end" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."decrement_product_stock"("stock_updates" "public"."product_stock_update"[]) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  update_record product_stock_update;
  current_stock INTEGER;
BEGIN
  -- Loop through each product stock update
  FOREACH update_record IN ARRAY stock_updates
  LOOP
    -- Get current stock for the product
    SELECT total_stock INTO current_stock
    FROM products
    WHERE id = update_record.product_id;
    
    -- Check if product exists and has sufficient stock
    IF current_stock IS NULL THEN
      RAISE EXCEPTION 'Product with ID % does not exist', update_record.product_id;
    END IF;
    
    IF current_stock < update_record.quantity THEN
      RAISE EXCEPTION 'Insufficient stock for product %. Available: %, Requested: %', 
        update_record.product_id, current_stock, update_record.quantity;
    END IF;
    
    -- Decrement the stock
    UPDATE products
    SET 
      total_stock = total_stock - update_record.quantity,
      updated_at = NOW()
    WHERE id = update_record.product_id;
    
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."decrement_product_stock"("stock_updates" "public"."product_stock_update"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_clients_by_ids"("ids" "text"[]) RETURNS "void"
    LANGUAGE "sql"
    AS $$
  DELETE FROM clients
  WHERE id = ANY(ids);
$$;


ALTER FUNCTION "public"."delete_clients_by_ids"("ids" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_if_voucher_null"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  if NEW.voucher_id is null then
    return null; -- cancel insert/update if voucher_id is null
  end if;
  return NEW;
end;
$$;


ALTER FUNCTION "public"."delete_if_voucher_null"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."demo_get_filtered_sales_dynamic"("p_start_date" "date" DEFAULT NULL::"date", "p_end_date" "date" DEFAULT NULL::"date", "p_sale_types" "text"[] DEFAULT NULL::"text"[], "p_payment_methods" "text"[] DEFAULT NULL::"text"[], "p_staff_ids" "text"[] DEFAULT NULL::"text"[], "p_location_ids" "text"[] DEFAULT NULL::"text"[], "p_limit" integer DEFAULT NULL::integer, "p_offset" integer DEFAULT 0) RETURNS TABLE("date" "text", "appt_date" "text", "sale_no" "text", "location" "text", "type" "text", "item" "text", "category" "text", "client" "text", "team_member" "text", "channel" "text", "service_price" numeric, "discount_percent" numeric, "gross_sales" numeric, "item_discounts" numeric, "cart_discounts" numeric, "total_discounts" numeric, "refunds" numeric, "net_sales" numeric, "tax" numeric, "total_sales" numeric)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
    WITH sale_items_data AS (
        SELECT
            s.id AS sale_id,
            s.appointment_id,
            s.created_at AS sale_created_at,

            /* 🔥 MERGED PAYMENT METHOD STRING (card,online) */
            (
                SELECT STRING_AGG(x.payment_method, ',' ORDER BY x.payment_method)
                FROM (
                    SELECT DISTINCT pm.payment_method::text AS payment_method
                    FROM sale_payment_methods pm
                    WHERE pm.sale_id = s.id AND pm.payment_method::text != 'courtesy'
                ) x
            ) AS payment_method,

            (
                SELECT ARRAY_AGG(x.payment_method)
                FROM (
                    SELECT DISTINCT pm.payment_method::text AS payment_method
                    FROM sale_payment_methods pm
                    WHERE pm.sale_id = s.id AND pm.payment_method::text != 'courtesy'
                ) x
            ) AS payment_method_array,

            s.sale_type::text AS sale_type,
            s.subtotal,
            s.tax_amount,
            s.total_amount,
            si.id AS sale_item_id,
            si.item_type::text AS item_type,
            si.item_name,
            si.unit_price,
            si.total_price AS item_total_price,
            si.discount_amount AS item_discount,
            si.appointment_service_id,

            COALESCE(si.staff_id, sis.staff_id) AS staff_id,
            s.client_id,
            s.location_id AS sale_location_id,

            CASE 
                WHEN si.item_type::text = 'service' 
                     AND si.appointment_service_id IS NOT NULL 
                THEN asp.service_category 
            END AS service_category,

            CASE 
                WHEN si.item_type::text = 'service' 
                     AND si.appointment_service_id IS NOT NULL 
                THEN COALESCE(asp.original_price, si.total_price)
                ELSE si.total_price 
            END AS service_price_amount,

            CASE 
                WHEN si.item_type::text = 'service' 
                     AND si.appointment_service_id IS NOT NULL 
                THEN COALESCE(asp.voucher_discount::numeric, 0)
                ELSE 0 
            END AS voucher_discount_amount,

            CASE 
                WHEN si.item_type::text = 'service' 
                     AND si.appointment_service_id IS NOT NULL 
                THEN COALESCE(asp.discount_percentage::numeric, 0)
                ELSE 0 
            END AS discount_percentage

        FROM sales s
        JOIN sale_items si ON si.sale_id = s.id
        LEFT JOIN sale_item_staff sis ON sis.sale_item_id = si.id
        LEFT JOIN appointment_service_pricing asp 
               ON asp.appointment_service_id = si.appointment_service_id 
              AND si.item_type::text = 'service'

        WHERE (p_start_date IS NULL OR s.created_at::DATE >= p_start_date)
          AND (p_end_date IS NULL OR s.created_at::DATE <= p_end_date)

          AND (p_sale_types IS NULL 
               OR si.item_type::text = ANY(p_sale_types)
               OR (si.item_type::text = 'service' AND 'services' = ANY(p_sale_types))
               OR (si.item_type::text = 'product' AND 'items' = ANY(p_sale_types)))

          AND (p_staff_ids IS NULL 
               OR COALESCE(si.staff_id, sis.staff_id, s.receptionist_id::text) = ANY(p_staff_ids))

          /* 🔥 Filter using merged array (overlap match) */
          AND (
                p_payment_methods IS NULL 
                OR (
                    SELECT ARRAY_AGG(DISTINCT pm.payment_method::text)
                    FROM sale_payment_methods pm
                    WHERE pm.sale_id = s.id
                      AND pm.payment_method::text != 'courtesy'
                ) && p_payment_methods
              )

          AND (p_location_ids IS NULL 
               OR s.location_id::text = ANY(p_location_ids))

          AND s.is_voided = false
          AND si.is_voided = false
    ),

    calculated_data AS (
        SELECT *,
            0.00::numeric AS membership_discounts,
            voucher_discount_amount AS voucher_discounts_calc,
            CASE WHEN discount_percentage > 0 
                 THEN ROUND((service_price_amount * discount_percentage / 100.0), 2)
                 ELSE COALESCE(item_discount, 0) END AS cart_discounts_calc
        FROM sale_items_data
    ),

    final_calculated_data AS (
        SELECT *,
            CASE 
                WHEN (membership_discounts + voucher_discount_amount + cart_discounts_calc) = 0 
                THEN COALESCE(service_price_amount - item_total_price, 0)
                ELSE (membership_discounts + voucher_discount_amount + cart_discounts_calc)
            END AS total_discounts_calc,

            (service_price_amount - 
                CASE 
                    WHEN (membership_discounts + voucher_discount_amount + cart_discounts_calc) = 0 
                    THEN COALESCE(service_price_amount - item_total_price, 0)
                    ELSE (membership_discounts + voucher_discount_amount + cart_discounts_calc)
                END
            ) AS gross_sales_calc
        FROM calculated_data
    ),

    tax_calculated_data AS (
        SELECT *,
            ROUND(gross_sales_calc * 0.95, 2) AS net_sales_calc,
            ROUND(gross_sales_calc - (gross_sales_calc * 0.95), 2) AS tax_calc
        FROM final_calculated_data
    )

    SELECT
        to_char(cd.sale_created_at, 'DD Mon YYYY, HH12:MIam'),
        to_char(a.appointment_date, 'DD Mon YYYY, HH12:MIam'),
        cd.sale_id::text,

        CASE
            WHEN cd.item_type = 'service'
            THEN COALESCE(l.name, 'Unknown - ID: ' || COALESCE(tm.location_id::text, a.location_id::text, 'NULL'))
            ELSE COALESCE(loc_sale.name, 'Unknown - ID: ' || COALESCE(cd.sale_location_id::text,'NULL'))
        END AS location,

        CASE
            WHEN cd.item_type = 'service' THEN 'services'
            WHEN cd.item_type = 'product' THEN 'items'
            ELSE cd.item_type
        END AS type,

        cd.item_name AS item,

        CASE
            WHEN cd.item_type = 'service' THEN COALESCE(cd.service_category,'Unknown Category')
            ELSE cd.item_type END AS category,

        CASE
            WHEN cd.item_type = 'service' THEN COALESCE(cl.first_name,'Walk-In')
            ELSE COALESCE(cl_direct.first_name,'Walk-In')
        END AS client,

        CASE
            WHEN cd.item_type = 'voucher' THEN COALESCE(loc_sale.name, 'Unknown Location')
            ELSE COALESCE(tm.first_name || ' ' || tm.last_name,'Receptionist')
        END AS team_member,

        /* 🔥 Output merged payment methods */
        cd.payment_method AS channel,

        cd.service_price_amount AS service_price,
        (cd.voucher_discount_amount + cd.discount_percentage) AS discount_percent,
        cd.gross_sales_calc AS gross_sales,
        cd.membership_discounts AS item_discounts,
        cd.cart_discounts_calc AS cart_discounts,
        cd.total_discounts_calc AS total_discounts,
        0.00::numeric AS refunds,
        cd.net_sales_calc AS net_sales,
        cd.tax_calc AS tax,
        ROUND(cd.net_sales_calc + cd.tax_calc, 2) AS total_sales

    FROM tax_calculated_data cd
    LEFT JOIN appointments a ON a.id = cd.appointment_id
    LEFT JOIN clients cl ON cl.id = a.client_id
    LEFT JOIN clients cl_direct ON cl_direct.id = cd.client_id
    LEFT JOIN team_members tm ON tm.id = cd.staff_id
    LEFT JOIN locations l ON l.id = COALESCE(tm.location_id, a.location_id)
    LEFT JOIN locations loc_sale ON loc_sale.id = cd.sale_location_id

    ORDER BY cd.sale_created_at DESC, cd.sale_id DESC, cd.sale_item_id
    LIMIT p_limit OFFSET p_offset;

END;
$$;


ALTER FUNCTION "public"."demo_get_filtered_sales_dynamic"("p_start_date" "date", "p_end_date" "date", "p_sale_types" "text"[], "p_payment_methods" "text"[], "p_staff_ids" "text"[], "p_location_ids" "text"[], "p_limit" integer, "p_offset" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."gen_alphanum_id"("len" integer DEFAULT 16) RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    chars CONSTANT TEXT := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    out   TEXT := '';
BEGIN
    FOR i IN 1..len LOOP
        out := out || substr(chars, floor(random()*36)::INT + 1, 1);
    END LOOP;
    RETURN out;
END;
$$;


ALTER FUNCTION "public"."gen_alphanum_id"("len" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_appointments_next_7_days"() RETURNS TABLE("day_label" "text", "appointment_count" integer, "detailed_day_appointments" "text", "amount_expected" numeric)
    LANGUAGE "sql"
    AS $$
WITH days AS (
    SELECT 
        generate_series(
            CURRENT_DATE, 
            CURRENT_DATE + INTERVAL '6 days', 
            INTERVAL '1 day'
        )::date AS day
),

services AS (
    SELECT
        appointment_date::date AS day,
        staff_name,
        service_name,
        original_price
    FROM appointment_service_pricing
    WHERE appointment_date >= CURRENT_DATE
      AND appointment_date < CURRENT_DATE + INTERVAL '7 days'
      AND staff_name IS NOT NULL
),

staff_summary AS (
    SELECT
        day,
        staff_name,
        COUNT(*) AS appointment_count,
        STRING_AGG('• ' || service_name, E'\n') AS services_list,
        SUM(original_price) AS staff_amount
    FROM services
    GROUP BY day, staff_name
),

day_details AS (
    SELECT
        day,
        STRING_AGG(
            staff_name || ' – ' || appointment_count || ' appointments' ||
            E'\n' || services_list,
            E'\n\n'
            ORDER BY staff_name
        ) AS detailed_day_appointments,
        SUM(staff_amount) AS amount_expected
    FROM staff_summary
    GROUP BY day
)

SELECT
    to_char(d.day, 'DD Mon') AS day_label,
    COUNT(a.id) AS appointment_count,
    CASE 
        WHEN dd.detailed_day_appointments IS NULL THEN NULL
        ELSE dd.detailed_day_appointments || 
             E'\n\nTotal amount expected: AED ' || dd.amount_expected
    END AS detailed_day_appointments,
    dd.amount_expected
FROM days d
LEFT JOIN appointments a
    ON a.appointment_date::date = d.day
    AND a.appointment_date >= CURRENT_DATE
    AND a.appointment_date < CURRENT_DATE + INTERVAL '7 days'
LEFT JOIN day_details dd
    ON dd.day = d.day
GROUP BY d.day, dd.detailed_day_appointments, dd.amount_expected
ORDER BY d.day;
$$;


ALTER FUNCTION "public"."get_appointments_next_7_days"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_duplicate_clients"() RETURNS TABLE("id" "text", "first_name" "text", "last_name" "text", "phone" "text")
    LANGUAGE "sql"
    AS $$
  SELECT c.id, c.first_name, c.last_name, c.phone
  FROM clients c
  JOIN (
    SELECT phone
    FROM clients
    WHERE phone IS NOT NULL
    GROUP BY phone
    HAVING COUNT(*) > 1
  ) dups
  ON c.phone = dups.phone
  ORDER BY c.phone, c.created_at;
$$;


ALTER FUNCTION "public"."get_duplicate_clients"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_filtered_sales_dynamic"("p_start_date" "date" DEFAULT NULL::"date", "p_end_date" "date" DEFAULT NULL::"date", "p_sale_types" "text"[] DEFAULT NULL::"text"[], "p_payment_methods" "text"[] DEFAULT NULL::"text"[], "p_staff_ids" "text"[] DEFAULT NULL::"text"[], "p_location_ids" "text"[] DEFAULT NULL::"text"[], "p_limit" integer DEFAULT NULL::integer, "p_offset" integer DEFAULT 0) RETURNS TABLE("date" "text", "appt_date" "text", "sale_no" "text", "location" "text", "type" "text", "item" "text", "category" "text", "client" "text", "team_member" "text", "channel" "text", "service_price" numeric, "discount_percent" numeric, "gross_sales" numeric, "item_discounts" numeric, "cart_discounts" numeric, "total_discounts" numeric, "refunds" numeric, "net_sales" numeric, "tax" numeric, "total_sales" numeric)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
    WITH sale_items_data AS (
        SELECT
            s.id AS sale_id,
            s.appointment_id,
            s.created_at AS sale_created_at,
            s.payment_method,
            s.sale_type::text AS sale_type,
            s.subtotal,
            s.tax_amount,
            s.total_amount,
            si.id AS sale_item_id,
            si.item_type::text AS item_type,
            si.item_name,
            si.unit_price,
            si.total_price AS item_total_price,
            si.discount_amount AS item_discount,
            si.appointment_service_id,
            COALESCE(si.staff_id, sis.staff_id) AS staff_id,
            s.client_id,
            s.location_id AS sale_location_id,
            -- Get service category from appointment_service_pricing for services
            CASE WHEN si.item_type::text = 'service' AND si.appointment_service_id IS NOT NULL THEN
                asp.service_category
            ELSE NULL END AS service_category,
            -- Get original price from appointment_service_pricing for services
            CASE WHEN si.item_type::text = 'service' AND si.appointment_service_id IS NOT NULL THEN
                COALESCE(asp.original_price, si.total_price)
            ELSE si.total_price END AS service_price_amount,
            -- Get voucher discount and discount percentage from appointment_service_pricing for services
            CASE WHEN si.item_type::text = 'service' AND si.appointment_service_id IS NOT NULL THEN
                COALESCE(asp.voucher_discount::numeric, 0)
            ELSE 0::numeric END AS voucher_discount_amount,
            CASE WHEN si.item_type::text = 'service' AND si.appointment_service_id IS NOT NULL THEN
                COALESCE(asp.discount_percentage::numeric, 0)
            ELSE 0::numeric END AS discount_percentage
        FROM sales s
        JOIN sale_items si ON si.sale_id = s.id
        LEFT JOIN sale_item_staff sis ON sis.sale_item_id = si.id
        LEFT JOIN appointment_service_pricing asp ON asp.appointment_service_id = si.appointment_service_id 
            AND si.item_type::text = 'service'
        WHERE (p_start_date IS NULL OR s.created_at::DATE >= p_start_date)
          AND (p_end_date IS NULL OR s.created_at::DATE <= p_end_date)
          AND (p_sale_types IS NULL OR 
               si.item_type::text = ANY(p_sale_types) OR 
               (si.item_type::text = 'service' AND 'services' = ANY(p_sale_types)) OR
               (si.item_type::text = 'product' AND 'items' = ANY(p_sale_types)))
          AND (p_staff_ids IS NULL OR COALESCE(si.staff_id, sis.staff_id, s.receptionist_id::text) = ANY(p_staff_ids))
          AND (p_payment_methods IS NULL OR s.payment_method::text = ANY(p_payment_methods))
          AND (p_location_ids IS NULL OR s.location_id::text = ANY(p_location_ids))
          AND s.is_voided = false
          AND si.is_voided = false
          AND s.payment_method::text != 'courtesy'
    ),
    calculated_data AS (
        SELECT 
            *,
            -- No automatic membership discounts - use actual discounts from appointment_service_pricing
            0.00::numeric AS membership_discounts,
            -- Voucher discount from appointment_service_pricing
            voucher_discount_amount AS voucher_discounts_calc,
            -- Calculate cart discounts from discount percentage from appointment_service_pricing
            CASE WHEN discount_percentage > 0 THEN
                ROUND((service_price_amount * discount_percentage / 100.0), 2)
            ELSE COALESCE(item_discount, 0) END AS cart_discounts_calc
        FROM sale_items_data
    ),
    final_calculated_data AS (
        SELECT 
            *,
            -- Total discounts = membership + voucher + cart discounts
            (membership_discounts + voucher_discount_amount + cart_discounts_calc) AS total_discounts_calc,
            -- Gross sales = service price - total discounts
            (service_price_amount - (membership_discounts + voucher_discount_amount + cart_discounts_calc)) AS gross_sales_calc
        FROM calculated_data
    ),
    tax_calculated_data AS (
        SELECT 
            *,
            -- Net sale = gross sale * 0.95
            ROUND(gross_sales_calc * 0.95, 2) AS net_sales_calc,
            -- Tax = gross sale - net sale (5% of gross sale)
            ROUND(gross_sales_calc - (gross_sales_calc * 0.95), 2) AS tax_calc
        FROM final_calculated_data
    )
    SELECT
        to_char(cd.sale_created_at, 'DD Mon YYYY, HH12:MIam') AS date,
        to_char(a.appointment_date, 'DD Mon YYYY, HH12:MIam') AS appt_date,
        cd.sale_id::text AS sale_no,
        CASE
            WHEN cd.item_type = 'service' THEN COALESCE(l.name, 'Unknown - ID: ' || COALESCE(tm.location_id::text, a.location_id::text,'NULL'))
            ELSE COALESCE(loc_sale.name, 'Unknown - ID: ' || COALESCE(cd.sale_location_id::text,'NULL'))
        END AS location,
        -- Map item_type to display names
        CASE
            WHEN cd.item_type = 'service' THEN 'services'
            WHEN cd.item_type = 'product' THEN 'items'
            ELSE cd.item_type
        END AS type,
        cd.item_name AS item,
        CASE
            WHEN cd.item_type = 'service' THEN COALESCE(cd.service_category,'Unknown Category')
            ELSE cd.item_type
        END AS category,
        CASE
            WHEN cd.item_type = 'service' THEN COALESCE(cl.first_name,'Walk-In')
            ELSE COALESCE(cl_direct.first_name,'Walk-In')
        END AS client,
        CASE
            WHEN cd.item_type = 'voucher' THEN COALESCE(loc_sale.name, 'Unknown Location')
            ELSE COALESCE(tm.first_name || ' ' || tm.last_name,'Receptionist')
        END AS team_member,
        -- Show 'voucher' as channel if item type is voucher, otherwise show payment method
        CASE
            WHEN cd.item_type = 'voucher' THEN 'voucher'
            ELSE         cd.payment_method::text
        END AS channel,
        cd.service_price_amount AS service_price,
        -- Add voucher_discount % and discount_percentage % from appointment_service_pricing
        (cd.voucher_discount_amount + cd.discount_percentage) AS discount_percent,
        cd.gross_sales_calc AS gross_sales,
        cd.membership_discounts AS item_discounts,
        cd.cart_discounts_calc AS cart_discounts,
        cd.total_discounts_calc AS total_discounts,
        0.00::numeric AS refunds,
        cd.net_sales_calc AS net_sales,
        cd.tax_calc AS tax,
        ROUND(cd.net_sales_calc + cd.tax_calc, 2) AS total_sales
    FROM tax_calculated_data cd
    LEFT JOIN appointments a ON a.id = cd.appointment_id
    LEFT JOIN clients cl ON cl.id = a.client_id
    LEFT JOIN clients cl_direct ON cl_direct.id = cd.client_id
    LEFT JOIN team_members tm ON tm.id = cd.staff_id
    LEFT JOIN locations l ON l.id = COALESCE(tm.location_id, a.location_id)
    LEFT JOIN locations loc_sale ON loc_sale.id = cd.sale_location_id
    ORDER BY cd.sale_created_at DESC, cd.sale_id DESC, cd.sale_item_id
    LIMIT p_limit OFFSET p_offset;
END;
$$;


ALTER FUNCTION "public"."get_filtered_sales_dynamic"("p_start_date" "date", "p_end_date" "date", "p_sale_types" "text"[], "p_payment_methods" "text"[], "p_staff_ids" "text"[], "p_location_ids" "text"[], "p_limit" integer, "p_offset" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_filtered_sales_from_log"("p_start_date" "date" DEFAULT NULL::"date", "p_end_date" "date" DEFAULT NULL::"date", "p_sale_types" "text"[] DEFAULT NULL::"text"[], "p_staff_names" "text"[] DEFAULT NULL::"text"[], "p_location_names" "text"[] DEFAULT NULL::"text"[], "p_payment_methods" "text"[] DEFAULT NULL::"text"[]) RETURNS TABLE("date" "text", "appt_date" "text", "sale_no" "text", "location" "text", "type" "text", "item" "text", "category" "text", "client" "text", "team_member" "text", "channel" "text", "service_price" numeric, "discount_percent" numeric, "gross_sales" numeric, "item_discounts" numeric, "cart_discounts" numeric, "total_discounts" numeric, "refunds" numeric, "net_sales" numeric, "tax" numeric, "total_sales" numeric)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN QUERY
  WITH base_sales_log AS (
    -- Get data from your existing sales log report function
    SELECT * FROM run_sales_log_report(
      location_filter := p_location_names,
      start_date_param := p_start_date,
      end_date_param := p_end_date
    )
  ),
  
  filtered_sales AS (
    SELECT bsl.*
    FROM base_sales_log bsl
    WHERE 
      -- Filter by sale types
      (p_sale_types IS NULL OR bsl.type = ANY(p_sale_types))
      
      -- Filter by staff names
      AND (p_staff_names IS NULL OR bsl.team_member = ANY(p_staff_names))
      
      -- Filter by location names  
      AND (p_location_names IS NULL OR bsl.location = ANY(p_location_names))
      
      -- Filter by payment methods (if this field exists in your log)
      AND (p_payment_methods IS NULL OR 
           COALESCE(bsl.payment_method, 'Unknown') = ANY(p_payment_methods))
  )
  
  SELECT 
    fs.date,
    fs.appt_date,
    fs.sale_no,
    fs.location,
    fs.type,
    fs.item,
    fs.category,
    fs.client,
    fs.team_member,
    fs.channel,
    fs.service_price,
    fs.discount_percent,
    fs.gross_sales,
    fs.item_discounts,
    fs.cart_discounts,
    fs.total_discounts,
    fs.refunds,
    fs.net_sales,
    fs.tax,
    fs.total_sales
  FROM filtered_sales fs
  ORDER BY fs.date DESC;
  
END;
$$;


ALTER FUNCTION "public"."get_filtered_sales_from_log"("p_start_date" "date", "p_end_date" "date", "p_sale_types" "text"[], "p_staff_names" "text"[], "p_location_names" "text"[], "p_payment_methods" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_filtered_sales_from_log_enhanced"("p_start_date" "date" DEFAULT NULL::"date", "p_end_date" "date" DEFAULT NULL::"date", "p_sale_types" "text"[] DEFAULT NULL::"text"[], "p_staff_names" "text"[] DEFAULT NULL::"text"[], "p_location_names" "text"[] DEFAULT NULL::"text"[], "p_payment_methods" "text"[] DEFAULT NULL::"text"[], "p_include_services" boolean DEFAULT true, "p_include_items" boolean DEFAULT true) RETURNS TABLE("date" "text", "appt_date" "text", "sale_no" "text", "location" "text", "type" "text", "item" "text", "category" "text", "client" "text", "team_member" "text", "channel" "text", "service_price" numeric, "discount_percent" numeric, "gross_sales" numeric, "item_discounts" numeric, "cart_discounts" numeric, "total_discounts" numeric, "refunds" numeric, "net_sales" numeric, "tax" numeric, "total_sales" numeric, "item_type" "text")
    LANGUAGE "plpgsql"
    AS $$BEGIN
  RETURN QUERY
  WITH base_sales_log AS (
    SELECT * FROM run_sales_log_report(
      location_filter := p_location_names,
      start_date_param := p_start_date,
      end_date_param := p_end_date
    )
  ),
  
  -- If your run_sales_log_report doesn't include items, we need to supplement it
  additional_item_sales AS (
    SELECT 
      s.created_at::TEXT as date,
      COALESCE(s.appointment_date, s.created_at)::TEXT as appt_date,
      COALESCE(s.sale_no, s.id::TEXT) as sale_no,
      COALESCE(l.name, s.location_name, 'Unknown Location') as location,
      s.type,
      COALESCE(i.name, 'Unknown Item') as item,
      COALESCE(i.category, 'Retail') as category,
      COALESCE(s.client_name, 'Walk-in') as client,
      COALESCE(st.name, s.staff_name, 'Unknown Staff') as team_member,
      COALESCE(s.channel, 'At Checkout') as channel,
      COALESCE(si.unit_price, 0)::DECIMAL as service_price,
      COALESCE(s.discount_percent, 0)::DECIMAL as discount_percent,

      COALESCE(s.gross_amount, s.total_amount, 0)::DECIMAL as gross_sales,

      -- ✅ Zero discount if category is Voucher, Membership, or Gift Card
      CASE 
        WHEN i.category IN ('Voucher', 'Membership', 'Gift Card') THEN 0
        ELSE COALESCE(s.discount_amount * 0.5, 0)::DECIMAL
      END as item_discounts,

      CASE 
        WHEN i.category IN ('Voucher', 'Membership', 'Gift Card') THEN 0
        ELSE COALESCE(s.discount_amount * 0.5, 0)::DECIMAL
      END as cart_discounts,

      CASE 
        WHEN i.category IN ('Voucher', 'Membership', 'Gift Card') THEN 0
        ELSE COALESCE(s.total_discount, s.discount_amount, 0)::DECIMAL
      END as total_discounts,

      COALESCE(s.refund_amount, 0)::DECIMAL as refunds,

      -- ✅ Net sales recalculated (gross - discounts)
      CASE 
        WHEN i.category IN ('Voucher', 'Membership', 'Gift Card') 
        THEN COALESCE(s.gross_amount, s.total_amount, 0)
        ELSE COALESCE(s.net_amount, s.total_amount - COALESCE(s.total_discount, 0), 0)
      END::DECIMAL as net_sales,

      COALESCE(s.tax_amount, 0)::DECIMAL as tax,
      COALESCE(s.final_amount, s.total_amount, 0)::DECIMAL as total_sales,
      'Item'::TEXT as item_type
    FROM sales s
    LEFT JOIN sale_items si ON s.id = si.sale_id
    LEFT JOIN items i ON si.item_id = i.id
    LEFT JOIN staff st ON s.staff_id = st.id AND st.active = true
    LEFT JOIN locations l ON s.location_id = l.id AND l.active = true
    WHERE 
      si.item_id IS NOT NULL
      AND (p_start_date IS NULL OR s.created_at::DATE >= p_start_date)
      AND (p_end_date IS NULL OR s.created_at::DATE <= p_end_date)
      AND p_include_items = TRUE
  ),
  
  -- Combine base log (services) with additional items
  combined_sales AS (
    -- Services from existing log
    SELECT 
      bsl.*,
      'Service'::TEXT as item_type
    FROM base_sales_log bsl
    WHERE p_include_services = TRUE
    
    UNION ALL
    
    -- Items from additional query
    SELECT 
      ais.date,
      ais.appt_date,
      ais.sale_no,
      ais.location,
      ais.type,
      ais.item,
      ais.category,
      ais.client,
      ais.team_member,
      ais.channel,
      ais.service_price,
      ais.discount_percent,
      ais.gross_sales,
      ais.item_discounts,
      ais.cart_discounts,
      ais.total_discounts,
      ais.refunds,
      ais.net_sales,
      ais.tax,
      ais.total_sales,
      ais.item_type
    FROM additional_item_sales ais
  ),
  
  filtered_sales AS (
    SELECT cs.*
    FROM combined_sales cs
    WHERE 
      -- Filter by sale types
      (p_sale_types IS NULL OR cs.type = ANY(p_sale_types))
      
      -- Filter by staff names
      AND (p_staff_names IS NULL OR cs.team_member = ANY(p_staff_names))
      
      -- Filter by location names  
      AND (p_location_names IS NULL OR cs.location = ANY(p_location_names))
      
      -- Filter by payment methods
      AND (p_payment_methods IS NULL OR 
           COALESCE(cs.payment_method, 'Unknown') = ANY(p_payment_methods))
  )
  
  SELECT 
    fs.date,
    fs.appt_date,
    fs.sale_no,
    fs.location,
    fs.type,
    fs.item,
    fs.category,
    fs.client,
    fs.team_member,
    fs.channel,
    fs.service_price,
    fs.discount_percent,
    fs.gross_sales,
    fs.item_discounts,
    fs.cart_discounts,
    fs.total_discounts,
    fs.refunds,
    fs.net_sales,
    fs.tax,
    fs.total_sales,
    fs.item_type
  FROM filtered_sales fs
  ORDER BY fs.date DESC;
  
END;$$;


ALTER FUNCTION "public"."get_filtered_sales_from_log_enhanced"("p_start_date" "date", "p_end_date" "date", "p_sale_types" "text"[], "p_staff_names" "text"[], "p_location_names" "text"[], "p_payment_methods" "text"[], "p_include_services" boolean, "p_include_items" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_location_sales_summary"("p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_locations" "text"[] DEFAULT NULL::"text"[]) RETURNS TABLE("location_id" "text", "location_name" "text", "total_sales_amount" numeric, "services_amount" numeric, "items_amount" numeric, "other_amount" numeric, "transaction_count" bigint, "avg_transaction_value" numeric, "services_percentage" numeric, "items_percentage" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
    RETURN QUERY
    WITH base_sales AS (
        SELECT 
            s.id AS sale_id,
            s.location_id,
            s.total_amount,
            l.name AS location_name
        FROM sales s
        INNER JOIN locations l ON s.location_id = l.id
        WHERE 
            s.created_at BETWEEN p_start_date AND p_end_date
            AND NOT s.is_voided
            AND (p_locations IS NULL OR s.location_id = ANY(p_locations))
    ),
    
    categorized_amounts AS (
        SELECT 
            bs.location_id,
            bs.location_name,
            bs.sale_id,
            bs.total_amount AS sale_total,
            SUM(CASE 
                WHEN si.item_type::TEXT = 'service' THEN si.total_price 
                ELSE 0 
            END) AS services_amount,
            SUM(CASE 
                WHEN si.item_type::TEXT = 'product' THEN si.total_price 
                ELSE 0 
            END) AS items_amount,
            SUM(CASE 
                WHEN si.item_type::TEXT NOT IN ('service', 'product') THEN si.total_price 
                ELSE 0 
            END) AS other_amount
        FROM base_sales bs
        INNER JOIN sale_items si ON bs.sale_id = si.sale_id
        WHERE NOT si.is_voided
        GROUP BY bs.location_id, bs.location_name, bs.sale_id, bs.total_amount
    )
    
    SELECT 
        ca.location_id,
        ca.location_name,
        ROUND(SUM(ca.sale_total), 2) AS total_sales_amount,
        ROUND(SUM(ca.services_amount), 2) AS services_amount,
        ROUND(SUM(ca.items_amount), 2) AS items_amount,
        ROUND(SUM(ca.other_amount), 2) AS other_amount,
        COUNT(ca.sale_id) AS transaction_count,
        ROUND(AVG(ca.sale_total), 2) AS avg_transaction_value,
        CASE 
            WHEN SUM(ca.sale_total) > 0 
            THEN ROUND((SUM(ca.services_amount) / SUM(ca.sale_total)) * 100, 2)
            ELSE 0 
        END AS services_percentage,
        CASE 
            WHEN SUM(ca.sale_total) > 0 
            THEN ROUND((SUM(ca.items_amount) / SUM(ca.sale_total)) * 100, 2)
            ELSE 0 
        END AS items_percentage
    FROM categorized_amounts ca
    GROUP BY ca.location_id, ca.location_name
    ORDER BY total_sales_amount DESC;
    
END;
$$;


ALTER FUNCTION "public"."get_location_sales_summary"("p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_locations" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_location_sales_totals"("p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_locations" "text"[] DEFAULT NULL::"text"[]) RETURNS TABLE("location_id" "text", "location_name" "text", "total_sales_amount" numeric, "transaction_count" bigint, "avg_transaction_value" numeric, "card_amount" numeric, "cash_amount" numeric, "online_amount" numeric, "other_amount" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$BEGIN
    RETURN QUERY
    WITH base_sales AS (
        SELECT 
            s.id AS sale_id,
            s.location_id,
            s.created_at,
            l.name AS location_name
        FROM sales s
        INNER JOIN locations l ON s.location_id = l.id
        WHERE 
            s.created_at BETWEEN p_start_date AND p_end_date
            AND NOT s.is_voided
            AND (p_locations IS NULL OR s.location_id = ANY(p_locations))
    ),
    
    payment_breakdown AS (
        SELECT 
            bs.location_id,
            bs.location_name,
            bs.sale_id,
            SUM(CASE 
                WHEN spm.payment_method::TEXT = 'card' THEN spm.amount 
                ELSE 0 
            END) AS card_amount,
            SUM(CASE 
                WHEN spm.payment_method::TEXT = 'cash' THEN spm.amount 
                ELSE 0 
            END) AS cash_amount,
            SUM(CASE 
                WHEN spm.payment_method::TEXT = 'online' THEN spm.amount 
                ELSE 0 
            END) AS online_amount,            
            SUM(spm.amount) AS total_amount
        FROM base_sales bs
        INNER JOIN sale_payment_methods spm ON bs.sale_id = spm.sale_id
        WHERE NOT spm.is_voided
        GROUP BY bs.location_id, bs.location_name, bs.sale_id
    )
    
    SELECT 
        pb.location_id,
        pb.location_name,
        ROUND(SUM(pb.total_amount), 2) AS total_sales_amount,
        COUNT(pb.sale_id) AS transaction_count,
        ROUND(AVG(pb.total_amount), 2) AS avg_transaction_value,
        ROUND(SUM(pb.card_amount), 2) AS card_amount,
        ROUND(SUM(pb.cash_amount), 2) AS cash_amount,
        ROUND(SUM(pb.online_amount), 2) AS online_amount,
        0::numeric AS other_amount
    FROM payment_breakdown pb
    GROUP BY pb.location_id, pb.location_name
    ORDER BY total_sales_amount DESC;
    
END;$$;


ALTER FUNCTION "public"."get_location_sales_totals"("p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_locations" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_payment_totals"("start_ts" timestamp with time zone, "end_ts" timestamp with time zone) RETURNS TABLE("payment_method" "text", "total_with_tips" numeric, "total_amount" numeric, "total_tips" numeric)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN QUERY
  SELECT
    spm.payment_method,
    SUM(spm.amount) + SUM(s.tip_amount) AS total_with_tips,
    SUM(spm.amount) AS total_amount,
    SUM(s.tip_amount) AS total_tips
  FROM public.sale_payment_methods spm
  INNER JOIN public.sales s
    ON spm.sale_id = s.id
  WHERE s.created_at >= start_ts
    AND s.created_at < end_ts
    AND spm.is_voided = false
    AND s.is_voided = false
  GROUP BY spm.payment_method;
END;
$$;


ALTER FUNCTION "public"."get_payment_totals"("start_ts" timestamp with time zone, "end_ts" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_payment_transactions"("p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_date_type" "text" DEFAULT 'payment_date'::"text", "p_locations" "text"[] DEFAULT NULL::"text"[], "p_team_members" "text"[] DEFAULT NULL::"text"[], "p_transaction_types" "text"[] DEFAULT NULL::"text"[], "p_payment_methods" "text"[] DEFAULT NULL::"text"[], "p_payment_amount_from" numeric DEFAULT NULL::numeric, "p_payment_amount_to" numeric DEFAULT NULL::numeric, "p_exclude_gift_card_redemptions" boolean DEFAULT false, "p_exclude_upfront_payment_redemptions" boolean DEFAULT false, "p_limit" integer DEFAULT 1000, "p_offset" integer DEFAULT 0) RETURNS TABLE("payment_date" "text", "payment_no" "text", "sale_date" "text", "sale_no" "text", "appointment_ref" "text", "client_name" "text", "location_name" "text", "team_member_name" "text", "transaction_type" "text", "payment_method" "text", "amount" numeric, "total_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    total_records BIGINT;
BEGIN
    -- Validate input parameters
    IF p_start_date IS NULL OR p_end_date IS NULL THEN
        RAISE EXCEPTION 'Start date and end date are required';
    END IF;

    IF p_start_date > p_end_date THEN
        RAISE EXCEPTION 'Start date cannot be after end date';
    END IF;

    IF p_date_type NOT IN ('payment_date', 'sale_date') THEN
        RAISE EXCEPTION 'Date type must be either payment_date or sale_date';
    END IF;

    -- Count total records
    WITH filtered_sales AS (
        SELECT DISTINCT s.id
        FROM sales s
        INNER JOIN sale_payment_methods spm ON s.id = spm.sale_id
        WHERE 
            CASE 
                WHEN p_date_type = 'sale_date' THEN s.created_at BETWEEN p_start_date AND p_end_date
                ELSE spm.created_at BETWEEN p_start_date AND p_end_date
            END
            AND NOT s.is_voided
            AND NOT spm.is_voided
            AND (p_locations IS NULL OR s.location_id = ANY(p_locations))
    )
    SELECT COUNT(*) INTO total_records FROM filtered_sales;

    -- Return payment transactions
    RETURN QUERY
    WITH payment_transactions AS (
        SELECT 
            s.id AS sale_id,
            s.created_at AS sale_created_at,
            s.appointment_id,
            s.client_id,
            s.location_id,
            s.sale_type,
            s.total_amount AS sale_total,
            spm.id AS payment_id,
            spm.payment_method AS payment_method_enum,
            spm.amount AS payment_amount,
            spm.created_at AS payment_created_at,
            CASE 
                WHEN s.sale_type::TEXT = 'refund' THEN 'Refund'
                WHEN s.sale_type::TEXT = 'upfront_payment' THEN 'Upfront payment'
                ELSE 'Sale'
            END AS trans_type,
            (
                SELECT si.staff_id
                FROM sale_items si
                WHERE si.sale_id = s.id 
                  AND si.staff_id IS NOT NULL 
                  AND NOT si.is_voided
                ORDER BY si.created_at
                LIMIT 1
            ) AS primary_staff_id
        FROM sales s
        INNER JOIN sale_payment_methods spm ON s.id = spm.sale_id
        WHERE 
            CASE 
                WHEN p_date_type = 'sale_date' THEN s.created_at BETWEEN p_start_date AND p_end_date
                ELSE spm.created_at BETWEEN p_start_date AND p_end_date
            END
            AND NOT s.is_voided
            AND NOT spm.is_voided
    ),
    pre_filtered_transactions AS (
        SELECT
            pt.*,
            COALESCE(c.first_name || ' ' || c.last_name, 'Walk-in') AS client_full_name,
            COALESCE(l.name, 'Unknown Location') AS location_name,
            COALESCE(tm.first_name || ' ' || tm.last_name, 'No staff assigned') AS team_member_full_name,
            CASE pt.payment_method_enum::TEXT
                WHEN 'card' THEN 'Card'
                WHEN 'cash' THEN 'Cash'
                WHEN 'courtesy' THEN 'Courtesy'
                WHEN 'online' THEN 'Online'
                WHEN 'gift_card' THEN 'Gift Card'
                ELSE INITCAP(pt.payment_method_enum::TEXT)
            END AS payment_method_display
        FROM payment_transactions pt
        LEFT JOIN clients c ON pt.client_id = c.id
        LEFT JOIN locations l ON pt.location_id = l.id
        LEFT JOIN team_members tm ON pt.primary_staff_id = tm.id
    ),
    filtered_transactions AS (
        SELECT *
        FROM pre_filtered_transactions pft
        WHERE 1=1
            AND (p_locations IS NULL OR pft.location_id = ANY(p_locations))
            AND (p_team_members IS NULL OR pft.primary_staff_id = ANY(p_team_members))
            AND (p_transaction_types IS NULL OR pft.trans_type = ANY(p_transaction_types))
            AND (p_payment_methods IS NULL OR pft.payment_method_display = ANY(p_payment_methods))
            AND (p_payment_amount_from IS NULL OR pft.payment_amount >= p_payment_amount_from)
            AND (p_payment_amount_to IS NULL OR pft.payment_amount <= p_payment_amount_to)
            AND (NOT p_exclude_gift_card_redemptions OR pft.payment_method_enum::TEXT != 'gift_card')
            AND (NOT p_exclude_upfront_payment_redemptions OR pft.trans_type != 'Upfront payment')
    )
    SELECT 
        TO_CHAR(ft.payment_created_at AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Dubai', 'DD/MM/YYYY') AS payment_date,
        'P' || LPAD(ft.payment_id::TEXT, 6, '0') AS payment_no,
        TO_CHAR(ft.sale_created_at AT TIME ZONE 'UTC' AT TIME ZONE 'Asia/Dubai', 'DD/MM/YYYY') AS sale_date,
        ft.sale_id::TEXT AS sale_no,
        CASE 
            WHEN ft.appointment_id IS NOT NULL THEN 'A' || LPAD(ft.appointment_id::TEXT, 6, '0')
            ELSE NULL
        END AS appointment_ref,
        ft.client_full_name AS client_name,
        ft.location_name AS location_name,
        ft.team_member_full_name AS team_member_name,
        ft.trans_type AS transaction_type,
        ft.payment_method_display AS payment_method,
        ft.payment_amount AS amount,
        total_records AS total_count
    FROM filtered_transactions ft
    ORDER BY 
        CASE p_date_type 
            WHEN 'sale_date' THEN ft.sale_created_at
            ELSE ft.payment_created_at
        END DESC,
        ft.sale_id DESC,
        ft.payment_id DESC
    LIMIT p_limit OFFSET p_offset;

EXCEPTION
    WHEN OTHERS THEN
        RAISE EXCEPTION 'Error in get_payment_transactions: %', SQLERRM;
END;
$$;


ALTER FUNCTION "public"."get_payment_transactions"("p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_date_type" "text", "p_locations" "text"[], "p_team_members" "text"[], "p_transaction_types" "text"[], "p_payment_methods" "text"[], "p_payment_amount_from" numeric, "p_payment_amount_to" numeric, "p_exclude_gift_card_redemptions" boolean, "p_exclude_upfront_payment_redemptions" boolean, "p_limit" integer, "p_offset" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_sales_analytics_by_location_chart"("p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_locations" "text"[] DEFAULT NULL::"text"[], "p_payment_methods" "text"[] DEFAULT NULL::"text"[]) RETURNS TABLE("location_id" "text", "location_name" "text", "payment_method" "text", "transaction_count" bigint, "total_amount" numeric, "avg_transaction_amount" numeric, "percentage_of_location_total" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  -- Validate input parameters
  IF p_start_date IS NULL OR p_end_date IS NULL THEN
    RAISE EXCEPTION 'Start date and end date are required';
  END IF;

  IF p_start_date > p_end_date THEN
    RAISE EXCEPTION 'Start date cannot be after end date';
  END IF;

  RETURN QUERY
  WITH base_sales AS (
    SELECT
      s.id AS sale_id,
      s.location_id,
      s.created_at,
      s.total_amount AS sale_total,
      l.name AS location_name
    FROM sales s
    INNER JOIN locations l ON s.location_id = l.id
    WHERE
      s.created_at BETWEEN p_start_date AND p_end_date
      AND NOT s.is_voided
      AND (p_locations IS NULL OR s.location_id = ANY(p_locations))
  ),

  payment_methods_with_sales AS (
    SELECT
      bs.sale_id,
      bs.location_id,
      bs.location_name,
      bs.sale_total,
      spm.amount AS payment_amount,
      CASE spm.payment_method::TEXT
        WHEN 'card' THEN 'Card'
        WHEN 'cash' THEN 'Cash'
        WHEN 'online' THEN 'Online'
        WHEN 'courtesy' THEN 'Courtesy'
        WHEN 'gift_card' THEN 'Gift Card'
        WHEN 'voucher' THEN 'Voucher'
        WHEN 'membership' THEN 'Membership'
        ELSE INITCAP(spm.payment_method::TEXT)
      END AS payment_method_display
    FROM base_sales bs
    INNER JOIN sale_payment_methods spm ON bs.sale_id = spm.sale_id
    WHERE
      NOT spm.is_voided
      AND (
        p_payment_methods IS NULL
        OR CASE spm.payment_method::TEXT
          WHEN 'card' THEN 'Card'
          WHEN 'cash' THEN 'Cash'
          WHEN 'online' THEN 'Online'
          WHEN 'courtesy' THEN 'Courtesy'
          WHEN 'gift_card' THEN 'Gift Card'
          WHEN 'voucher' THEN 'Voucher'
          WHEN 'membership' THEN 'Membership'
          ELSE INITCAP(spm.payment_method::TEXT)
        END = ANY(p_payment_methods)
      )
  ),

  location_totals AS (
    SELECT
      location_id,
      SUM(payment_amount) AS location_total_amount
    FROM payment_methods_with_sales
    GROUP BY location_id
  ),

  aggregated_results AS (
    SELECT
      pmws.location_id,
      pmws.location_name,
      pmws.payment_method_display,
      COUNT(DISTINCT pmws.sale_id) AS transaction_count,
      SUM(pmws.payment_amount) AS total_amount,
      AVG(pmws.payment_amount) AS avg_transaction_amount,
      CASE
        WHEN lt.location_total_amount > 0
        THEN ROUND((SUM(pmws.payment_amount) / lt.location_total_amount) * 100, 2)
        ELSE 0
      END AS percentage_of_location_total
    FROM payment_methods_with_sales pmws
    INNER JOIN location_totals lt ON pmws.location_id = lt.location_id
    GROUP BY
      pmws.location_id,
      pmws.location_name,
      pmws.payment_method_display,
      lt.location_total_amount
  )

  SELECT
    ar.location_id,
    ar.location_name,
    ar.payment_method_display AS payment_method,
    ar.transaction_count,
    ROUND(ar.total_amount, 2),
    ROUND(ar.avg_transaction_amount, 2),
    ar.percentage_of_location_total
  FROM aggregated_results ar
  ORDER BY
    ar.location_name,
    ar.total_amount DESC;

EXCEPTION
  WHEN OTHERS THEN
    RAISE EXCEPTION
      'Error in get_sales_analytics_by_location_chart: %',
      SQLERRM;
END;
$$;


ALTER FUNCTION "public"."get_sales_analytics_by_location_chart"("p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_locations" "text"[], "p_payment_methods" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_sales_log_filter_options"("p_start_date" "date" DEFAULT NULL::"date", "p_end_date" "date" DEFAULT NULL::"date") RETURNS TABLE("sale_types" "text"[], "staff_members" "text"[], "locations" "text"[], "channels" "text"[], "categories" "text"[])
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN QUERY
  WITH log_data AS (
    SELECT * FROM run_sales_log_report(
      location_filter := NULL,
      start_date_param := COALESCE(p_start_date, CURRENT_DATE - INTERVAL '1 year'),
      end_date_param := COALESCE(p_end_date, CURRENT_DATE)
    )
  )
  SELECT 
    -- Available sale types
    ARRAY_AGG(DISTINCT ld.type ORDER BY ld.type) FILTER (WHERE ld.type IS NOT NULL) as sale_types,
    
    -- Available team members
    ARRAY_AGG(DISTINCT ld.team_member ORDER BY ld.team_member) FILTER (WHERE ld.team_member IS NOT NULL) as staff_members,
    
    -- Available locations
    ARRAY_AGG(DISTINCT ld.location ORDER BY ld.location) FILTER (WHERE ld.location IS NOT NULL) as locations,
    
    -- Available channels
    ARRAY_AGG(DISTINCT ld.channel ORDER BY ld.channel) FILTER (WHERE ld.channel IS NOT NULL) as channels,
    
    -- Available categories
    ARRAY_AGG(DISTINCT ld.category ORDER BY ld.category) FILTER (WHERE ld.category IS NOT NULL) as categories
    
  FROM log_data ld;
END;
$$;


ALTER FUNCTION "public"."get_sales_log_filter_options"("p_start_date" "date", "p_end_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_sales_log_filter_options_enhanced"("p_start_date" "date" DEFAULT NULL::"date", "p_end_date" "date" DEFAULT NULL::"date") RETURNS TABLE("sale_types" "text"[], "staff_members" "text"[], "locations" "text"[], "channels" "text"[], "categories" "text"[], "items" "text"[], "services" "text"[])
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN QUERY
  WITH log_data AS (
    SELECT * FROM run_sales_log_report(
      location_filter := NULL,
      start_date_param := COALESCE(p_start_date, CURRENT_DATE - INTERVAL '1 year'),
      end_date_param := COALESCE(p_end_date, CURRENT_DATE)
    )
  ),
  
  -- Get additional item data not in the log
  item_data AS (
    SELECT DISTINCT
      i.name as item_name,
      i.category,
      'Item' as item_type
    FROM sales s
    LEFT JOIN sale_items si ON s.id = si.sale_id
    LEFT JOIN items i ON si.item_id = i.id
    WHERE 
      i.id IS NOT NULL
      AND (p_start_date IS NULL OR s.created_at::DATE >= p_start_date)
      AND (p_end_date IS NULL OR s.created_at::DATE <= p_end_date)
  )
  
  SELECT 
    -- Available sale types
    ARRAY_AGG(DISTINCT ld.type ORDER BY ld.type) FILTER (WHERE ld.type IS NOT NULL) as sale_types,
    
    -- Available team members
    ARRAY_AGG(DISTINCT ld.team_member ORDER BY ld.team_member) FILTER (WHERE ld.team_member IS NOT NULL) as staff_members,
    
    -- Available locations
    ARRAY_AGG(DISTINCT ld.location ORDER BY ld.location) FILTER (WHERE ld.location IS NOT NULL) as locations,
    
    -- Available channels
    ARRAY_AGG(DISTINCT ld.channel ORDER BY ld.channel) FILTER (WHERE ld.channel IS NOT NULL) as channels,
    
    -- Available categories (from both log and items)
    ARRAY_AGG(DISTINCT cat ORDER BY cat) FILTER (WHERE cat IS NOT NULL) as categories,
    
    -- Available items (retail items only)
    ARRAY_AGG(DISTINCT id.item_name ORDER BY id.item_name) FILTER (WHERE id.item_name IS NOT NULL) as items,
    
    -- Available services (from log, assuming these are services)
    ARRAY_AGG(DISTINCT ld.item ORDER BY ld.item) FILTER (WHERE ld.item IS NOT NULL AND ld.category NOT LIKE '%Retail%') as services
    
  FROM log_data ld
  CROSS JOIN (
    SELECT UNNEST(ARRAY[ld.category] || COALESCE(ARRAY_AGG(id.category), ARRAY[]::TEXT[])) as cat
    FROM item_data id
  ) categories
  CROSS JOIN item_data id;
  
END;
$$;


ALTER FUNCTION "public"."get_sales_log_filter_options_enhanced"("p_start_date" "date", "p_end_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_sales_performance_daily_pivot"("p_start_date" "date" DEFAULT NULL::"date", "p_end_date" "date" DEFAULT NULL::"date", "p_sale_types" "text"[] DEFAULT NULL::"text"[], "p_payment_methods" "text"[] DEFAULT NULL::"text"[], "p_staff_ids" "text"[] DEFAULT NULL::"text"[], "p_location_ids" "text"[] DEFAULT NULL::"text"[]) RETURNS TABLE("sale_date" "date", "services" numeric, "membership_services" numeric, "products" numeric, "total_sales" numeric, "total_appointments" numeric)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
    WITH base AS (
        SELECT *
        FROM get_filtered_sales_dynamic(
            p_start_date := p_start_date,
            p_end_date   := p_end_date,
            p_sale_types := p_sale_types,
            p_payment_methods := p_payment_methods,
            p_staff_ids  := p_staff_ids,
            p_location_ids := p_location_ids,
            p_limit := NULL,
            p_offset := 0
        )
    )
    SELECT
        cd.date::DATE AS sale_date,
        -- Services (non-membership)
        COALESCE(SUM(
            CASE WHEN cd.type='services' AND cd.channel!='membership' THEN cd.total_sales ELSE 0 END
        ),0) AS services,

        -- Membership services (use service_price)
        COALESCE(SUM(
            CASE WHEN cd.type='services' AND cd.channel='membership' THEN cd.service_price ELSE 0 END
        ),0) AS membership_services,

        -- Products (exclude vouchers)
        COALESCE(SUM(
            CASE WHEN cd.type='items' AND (cd.category IS NULL OR cd.category!='voucher') THEN cd.total_sales ELSE 0 END
        ),0) AS products,

        -- Total sales (services + membership + products only)
        COALESCE(SUM(
            CASE 
                WHEN cd.type='services' AND cd.channel='membership' THEN cd.service_price
                WHEN cd.type='services' AND cd.channel!='membership' THEN cd.total_sales
                WHEN cd.type='items' AND (cd.category IS NULL OR cd.category!='voucher') THEN cd.total_sales
                ELSE 0
            END
        ),0) AS total_sales,

        -- Total unique service appointments
        COUNT(DISTINCT CASE WHEN cd.type='services' THEN cd.sale_no END)::NUMERIC AS total_appointments

    FROM base cd
    GROUP BY sale_date
    ORDER BY sale_date DESC;
END;
$$;


ALTER FUNCTION "public"."get_sales_performance_daily_pivot"("p_start_date" "date", "p_end_date" "date", "p_sale_types" "text"[], "p_payment_methods" "text"[], "p_staff_ids" "text"[], "p_location_ids" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_sales_performance_daily_summary"("p_start_date" "date" DEFAULT NULL::"date", "p_end_date" "date" DEFAULT NULL::"date", "p_sale_types" "text"[] DEFAULT NULL::"text"[], "p_payment_methods" "text"[] DEFAULT NULL::"text"[], "p_staff_ids" "text"[] DEFAULT NULL::"text"[], "p_location_ids" "text"[] DEFAULT NULL::"text"[]) RETURNS TABLE("sale_date" "date", "type" "text", "total_gross" numeric, "total_discounts" numeric, "total_net_sales" numeric, "total_tax" numeric, "total_sales" numeric)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
    WITH base AS (
        SELECT *
        FROM get_filtered_sales_dynamic(
            p_start_date := p_start_date,
            p_end_date   := p_end_date,
            p_sale_types := p_sale_types,
            p_payment_methods := p_payment_methods,
            p_staff_ids  := p_staff_ids,
            p_location_ids := p_location_ids,
            p_limit := NULL,
            p_offset := 0
        )
    )
    SELECT 
        cd.sale_created_at::DATE AS sale_date,
        CASE 
            WHEN cd.type = 'services' AND cd.channel = 'membership' THEN 'membership_services'
            WHEN cd.type = 'services' THEN 'services'
            WHEN cd.type = 'items' AND LOWER(cd.category) <> 'voucher' THEN 'products'
            ELSE NULL
        END AS type,
        COALESCE(SUM(
            CASE 
                WHEN cd.type='services' AND cd.channel='membership' THEN cd.service_price
                ELSE cd.gross_sales
            END
        ),0) AS total_gross,
        COALESCE(SUM(cd.total_discounts),0) AS total_discounts,
        COALESCE(SUM(
            CASE 
                WHEN cd.type='services' AND cd.channel='membership' THEN cd.service_price
                ELSE cd.net_sales
            END
        ),0) AS total_net_sales,
        COALESCE(SUM(cd.tax),0) AS total_tax,
        COALESCE(SUM(
            CASE 
                WHEN cd.type='services' AND cd.channel='membership' THEN cd.service_price
                ELSE cd.total_sales
            END
        ),0) AS total_sales
    FROM base cd
    WHERE NOT (
        (cd.type = 'items' AND LOWER(cd.category) = 'voucher')
        OR LOWER(cd.type) = 'voucher'
    )
    GROUP BY sale_date, type
    HAVING type IS NOT NULL
    ORDER BY sale_date DESC, type;
END;
$$;


ALTER FUNCTION "public"."get_sales_performance_daily_summary"("p_start_date" "date", "p_end_date" "date", "p_sale_types" "text"[], "p_payment_methods" "text"[], "p_staff_ids" "text"[], "p_location_ids" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_sales_performance_summary"("p_start_date" "date" DEFAULT NULL::"date", "p_end_date" "date" DEFAULT NULL::"date", "p_sale_types" "text"[] DEFAULT NULL::"text"[], "p_payment_methods" "text"[] DEFAULT NULL::"text"[], "p_staff_ids" "text"[] DEFAULT NULL::"text"[], "p_location_ids" "text"[] DEFAULT NULL::"text"[]) RETURNS TABLE("type" "text", "total_gross" numeric, "total_discounts" numeric, "total_net_sales" numeric, "total_tax" numeric, "total_sales" numeric)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
    WITH base AS (
        SELECT *
        FROM get_filtered_sales_dynamic(
            p_start_date := p_start_date,
            p_end_date   := p_end_date,
            p_sale_types := p_sale_types,
            p_payment_methods := p_payment_methods,
            p_staff_ids  := p_staff_ids,
            p_location_ids := p_location_ids,
            p_limit := NULL,
            p_offset := 0
        )
    )
    SELECT 
        CASE 
            WHEN b.type = 'services' AND b.channel = 'membership' THEN 'membership_services'
            WHEN b.type = 'services' THEN 'services'
            WHEN b.type = 'items' AND b.category = 'voucher' THEN 'vouchers'
            WHEN b.type = 'items' THEN 'products'
            ELSE b.type
        END AS type,
        COALESCE(SUM(
            CASE 
                WHEN b.type='services' AND b.channel='membership' THEN b.service_price
                ELSE b.gross_sales
            END
        ),0) AS total_gross,
        COALESCE(SUM(b.total_discounts),0) AS total_discounts,
        COALESCE(SUM(
            CASE 
                WHEN b.type='services' AND b.channel='membership' THEN b.service_price
                ELSE b.net_sales
            END
        ),0) AS total_net_sales,
        COALESCE(SUM(b.tax),0) AS total_tax,
        COALESCE(SUM(
            CASE 
                WHEN b.type='services' AND b.channel='membership' THEN b.service_price
                ELSE b.total_sales
            END
        ),0) AS total_sales
    FROM base b
    GROUP BY 1
    ORDER BY 1;
END;
$$;


ALTER FUNCTION "public"."get_sales_performance_summary"("p_start_date" "date", "p_end_date" "date", "p_sale_types" "text"[], "p_payment_methods" "text"[], "p_staff_ids" "text"[], "p_location_ids" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_sales_report"("p_start" timestamp with time zone, "p_end" timestamp with time zone, "p_location_ids" "uuid"[]) RETURNS TABLE("location_id" "uuid", "location_name" "text", "total_sales_amount" numeric, "transaction_count" integer, "avg_transaction_value" numeric, "card_amount" numeric, "cash_amount" numeric, "online_amount" numeric, "payment_method_count" integer, "other_amount" numeric)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
    RETURN QUERY
    WITH base_sales AS (
        SELECT 
            s.id AS sale_id,
            s.location_id,
            s.created_at,
            l.name AS location_name
        FROM sales s
        INNER JOIN locations l ON s.location_id = l.id
        WHERE 
            s.created_at BETWEEN p_start AND p_end
            AND NOT s.is_voided
            AND (p_location_ids IS NULL OR s.location_id = ANY(p_location_ids))
    ),

    filtered_payment_methods AS (
        SELECT *
        FROM (
            SELECT 
                spm.sale_id,
                spm.payment_method::TEXT AS payment_method,
                s.location_id AS location_id
            FROM sale_payment_methods spm
            INNER JOIN sales s ON spm.sale_id = s.id
            WHERE 
                NOT spm.is_voided
                AND spm.payment_method::TEXT NOT IN ('voucher', 'membership', 'courtesy')
                AND s.created_at BETWEEN p_start AND p_end
                AND (p_location_ids IS NULL OR s.location_id = ANY(p_location_ids))
        ) AS sub
    ),

    methods_per_location AS (
        SELECT 
            fp.location_id,
            COUNT(DISTINCT fp.payment_method) AS payment_method_count
        FROM filtered_payment_methods fp
        GROUP BY fp.location_id
    ),

    payment_breakdown AS (
        SELECT 
            bs.location_id,
            bs.location_name,
            bs.sale_id,
            SUM(CASE WHEN spm.payment_method::TEXT = 'card' THEN spm.amount ELSE 0 END) AS card_amount,
            SUM(CASE WHEN spm.payment_method::TEXT = 'cash' THEN spm.amount ELSE 0 END) AS cash_amount,
            SUM(CASE WHEN spm.payment_method::TEXT = 'online' THEN spm.amount ELSE 0 END) AS online_amount,
            SUM(spm.amount) AS total_amount
        FROM base_sales bs
        INNER JOIN sale_payment_methods spm 
            ON bs.sale_id = spm.sale_id
            AND spm.payment_method::TEXT NOT IN ('voucher', 'membership', 'courtesy')
            AND NOT spm.is_voided
        GROUP BY bs.location_id, bs.location_name, bs.sale_id
    )

    SELECT 
        pb.location_id,
        pb.location_name,
        ROUND(SUM(pb.total_amount), 2) AS total_sales_amount,
        CAST(COUNT(pb.sale_id) AS INTEGER) AS transaction_count,
        ROUND(AVG(pb.total_amount), 2) AS avg_transaction_value,
        ROUND(SUM(pb.card_amount), 2) AS card_amount,
        ROUND(SUM(pb.cash_amount), 2) AS cash_amount,
        ROUND(SUM(pb.online_amount), 2) AS online_amount,
        CAST(dmpl.payment_method_count AS INTEGER) AS payment_method_count,
        0::numeric AS other_amount
    FROM payment_breakdown pb
    LEFT JOIN methods_per_location dmpl ON pb.location_id = dmpl.location_id
    GROUP BY pb.location_id, pb.location_name, dmpl.payment_method_count
    ORDER BY total_sales_amount DESC;
END;
$$;


ALTER FUNCTION "public"."get_sales_report"("p_start" timestamp with time zone, "p_end" timestamp with time zone, "p_location_ids" "uuid"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_staff_revenue_report"("start_date" "date", "end_date" "date", "location_ids" "text"[] DEFAULT NULL::"text"[]) RETURNS TABLE("staff_id" "text", "staff_name" "text", "location_name" "text", "total_appointments" bigint, "total_service_value" numeric, "total_revenue_after_discount" numeric)
    LANGUAGE "sql"
    AS $$
WITH appointment_service_totals AS (
  SELECT
    aps.staff_id AS staff_id,            -- keep as text
    aps.appointment_id AS appointment_id, -- keep as text
    SUM(aps.price) AS staff_service_total
  FROM appointment_services aps
  WHERE aps.staff_id IS NOT NULL
    AND aps.appointment_id IS NOT NULL
  GROUP BY aps.staff_id, aps.appointment_id
),
appointment_totals AS (
  SELECT
    ab.appointment_id,
    ab.staff_id,
    SUM(ab.staff_service_total) AS appointment_total,
    COALESCE(cv.discount_percentage, 0) AS voucher_discount
  FROM appointment_service_totals ab
  JOIN appointments a ON a.id::text = ab.appointment_id  -- cast UUID to text
  LEFT JOIN sales s ON s.appointment_id::text = a.id::text
  LEFT JOIN client_vouchers cv ON cv.client_id::text = a.client_id::text
  WHERE a.status = 'paid'
    AND a.appointment_date BETWEEN start_date AND end_date
    AND (s.payment_method IS NULL OR s.payment_method <> 'courtesy')
  GROUP BY ab.appointment_id, ab.staff_id, cv.discount_percentage
),
appointment_with_discounts AS (
  SELECT
    ast.staff_id,
    ast.appointment_id,
    ast.staff_service_total,
    at.voucher_discount,
    at.appointment_total,
    (ast.staff_service_total * (1 - at.voucher_discount / 100.0)) AS final_revenue
  FROM appointment_service_totals ast
  JOIN appointment_totals at
    ON at.appointment_id = ast.appointment_id
   AND at.staff_id = ast.staff_id
)
SELECT
  awd.staff_id,
  COALESCE(tm.first_name || ' ' || tm.last_name, 'Unknown Staff') AS staff_name,
  COALESCE(l.name, 'Unknown Location') AS location_name,
  COUNT(DISTINCT awd.appointment_id) AS total_appointments,
  SUM(awd.staff_service_total) AS total_service_value,
  SUM(awd.final_revenue) AS total_revenue_after_discount
FROM appointment_with_discounts awd
LEFT JOIN team_members tm ON tm.id::text = awd.staff_id  -- cast UUID to text
LEFT JOIN locations l ON l.id::text = tm.location_id     -- cast UUID to text
WHERE location_ids IS NULL OR tm.location_id::text = ANY(location_ids)
GROUP BY awd.staff_id, tm.first_name, tm.last_name, l.name
HAVING COUNT(DISTINCT awd.appointment_id) > 0
ORDER BY total_revenue_after_discount DESC;
$$;


ALTER FUNCTION "public"."get_staff_revenue_report"("start_date" "date", "end_date" "date", "location_ids" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_team_member_monthly_sales"("p_month" integer, "p_year" integer, "p_team_member_name" "text" DEFAULT NULL::"text") RETURNS TABLE("team_member" "text", "team_member_id" "text", "this_month_sales" numeric, "last_month_sales" numeric)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_current_month_start DATE;
    v_current_month_end DATE;
    v_previous_month_start DATE;
    v_previous_month_end DATE;
BEGIN
    -- Calculate date ranges for current month
    v_current_month_start := make_date(p_year, p_month, 1);
    v_current_month_end := (v_current_month_start + INTERVAL '1 month' - INTERVAL '1 day')::DATE;
    
    -- Calculate date ranges for previous month
    v_previous_month_start := (v_current_month_start - INTERVAL '1 month')::DATE;
    v_previous_month_end := (v_current_month_start - INTERVAL '1 day')::DATE;

    RETURN QUERY
    WITH sale_items_data AS (
        SELECT
            s.id AS sale_id,
            s.appointment_id,
            s.created_at AS sale_created_at,
            s.payment_method,
            si.item_type::text AS item_type,
            si.appointment_service_id,
            COALESCE(si.staff_id, sis.staff_id) AS staff_id,
            -- Get original price from appointment_service_pricing for services
            CASE WHEN si.item_type::text = 'service' AND si.appointment_service_id IS NOT NULL THEN
                COALESCE(asp.original_price, si.total_price)
            ELSE si.total_price END AS service_price_amount,
            -- Get voucher discount for services
            CASE WHEN si.item_type::text = 'service' AND si.appointment_service_id IS NOT NULL THEN
                COALESCE(asp.voucher_discount::numeric, 0)
            ELSE 0::numeric END AS voucher_discount_amount,
            -- Get discount percentage for services
            CASE WHEN si.item_type::text = 'service' AND si.appointment_service_id IS NOT NULL THEN
                COALESCE(asp.discount_percentage::numeric, 0)
            ELSE 0::numeric END AS discount_percentage,
            COALESCE(si.discount_amount, 0) AS item_discount
        FROM sales s
        JOIN sale_items si ON si.sale_id = s.id
        LEFT JOIN sale_item_staff sis ON sis.sale_item_id = si.id
        LEFT JOIN appointment_service_pricing asp ON asp.appointment_service_id = si.appointment_service_id 
            AND si.item_type::text = 'service'
        WHERE s.created_at::DATE BETWEEN v_previous_month_start AND v_current_month_end
          AND s.is_voided = false
          AND si.is_voided = false
          AND s.payment_method::text != 'courtesy'  -- Exclude courtesy payment method
          AND si.item_type::text NOT IN ('voucher', 'membership')  -- Exclude vouchers and membership items
          AND s.sale_type::text IN ('services', 'items')  -- Only include services and items sale types
          AND s.sale_type::text != 'membership'  -- Explicitly exclude membership sale type
    ),
    calculated_data AS (
        SELECT 
            *,
            -- Calculate cart discounts from discount percentage
            CASE WHEN discount_percentage > 0 THEN
                ROUND((service_price_amount * discount_percentage / 100.0), 2)
            ELSE item_discount END AS cart_discounts_calc
        FROM sale_items_data
    ),
    final_calculated_data AS (
        SELECT 
            *,
            -- Total discounts = voucher + cart discounts (no membership discount)
            (voucher_discount_amount + cart_discounts_calc) AS total_discounts_calc,
            -- Gross sales = service price - total discounts
            (service_price_amount - (voucher_discount_amount + cart_discounts_calc)) AS gross_sales_calc
        FROM calculated_data
    ),
    tax_calculated_data AS (
        SELECT 
            *,
            -- Net sale = gross sale * 0.95
            ROUND(gross_sales_calc * 0.95, 2) AS net_sales_calc,
            -- Tax = gross sale - net sale (5% of gross sale)
            ROUND(gross_sales_calc - (gross_sales_calc * 0.95), 2) AS tax_calc
        FROM final_calculated_data
    ),
    sales_with_team AS (
        SELECT
            cd.*,
            tm.id AS tm_id,
            COALESCE(tm.first_name || ' ' || tm.last_name, 'Receptionist') AS tm_name,
            ROUND(cd.net_sales_calc + cd.tax_calc, 2) AS total_sale_amount
        FROM tax_calculated_data cd
        LEFT JOIN team_members tm ON tm.id = cd.staff_id
    ),
    current_month_totals AS (
        SELECT
            tm_id,
            tm_name,
            SUM(total_sale_amount) AS current_total
        FROM sales_with_team
        WHERE sale_created_at::DATE BETWEEN v_current_month_start AND v_current_month_end
        GROUP BY tm_id, tm_name
    ),
    previous_month_totals AS (
        SELECT
            tm_id,
            tm_name,
            SUM(total_sale_amount) AS previous_total
        FROM sales_with_team
        WHERE sale_created_at::DATE BETWEEN v_previous_month_start AND v_previous_month_end
        GROUP BY tm_id, tm_name
    ),
    combined_totals AS (
        SELECT
            COALESCE(c.tm_id, p.tm_id) AS member_id,
            COALESCE(c.tm_name, p.tm_name) AS member_name,
            COALESCE(c.current_total, 0) AS this_month,
            COALESCE(p.previous_total, 0) AS last_month
        FROM current_month_totals c
        FULL OUTER JOIN previous_month_totals p ON c.tm_id = p.tm_id
    )
    SELECT
        ct.member_name AS team_member,
        COALESCE(ct.member_id::text, 'N/A') AS team_member_id,
        ROUND(ct.this_month, 2) AS this_month_sales,
        ROUND(ct.last_month, 2) AS last_month_sales
    FROM combined_totals ct
    WHERE (p_team_member_name IS NULL OR LOWER(ct.member_name) LIKE LOWER('%' || p_team_member_name || '%'))
      AND (ct.this_month > 0 OR ct.last_month > 0)  -- Only show team members with sales
    ORDER BY ct.this_month DESC;
END;
$$;


ALTER FUNCTION "public"."get_team_member_monthly_sales"("p_month" integer, "p_year" integer, "p_team_member_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_tips_summary"("start_date" timestamp with time zone, "end_date" timestamp with time zone, "location_ids" "text"[] DEFAULT NULL::"text"[]) RETURNS TABLE("staff_id" "text", "team_member" "text", "collected_tips" numeric)
    LANGUAGE "sql" SECURITY DEFINER
    AS $$
  (
    -- First row: grand total
    SELECT 
      NULL::TEXT AS staff_id,
      'Total' AS team_member,
      COALESCE(SUM(st.amount), 0) AS collected_tips
    FROM team_members tm
    LEFT JOIN sale_tips st 
      ON tm.id = st.staff_id
     AND st.is_voided = false
     AND st.created_at >= start_date
     AND st.created_at <= end_date
    LEFT JOIN sales s 
      ON st.sale_id = s.id
    WHERE tm.is_active = true
      AND (location_ids IS NULL OR tm.location_id = ANY(location_ids))
      AND (location_ids IS NULL OR s.location_id IS NULL OR s.location_id = ANY(location_ids))
  )
  UNION ALL
  (
    -- Subsequent rows: per team member
    SELECT 
      tm.id AS staff_id,
      tm.first_name || ' ' || tm.last_name AS team_member,
      COALESCE(SUM(st.amount), 0) AS collected_tips
    FROM team_members tm
    LEFT JOIN sale_tips st 
      ON tm.id = st.staff_id
     AND st.is_voided = false
     AND st.created_at >= start_date
     AND st.created_at <= end_date
    LEFT JOIN sales s 
      ON st.sale_id = s.id
    WHERE tm.is_active = true
      AND (location_ids IS NULL OR tm.location_id = ANY(location_ids))
      AND (location_ids IS NULL OR s.location_id IS NULL OR s.location_id = ANY(location_ids))
    GROUP BY tm.id, tm.first_name, tm.last_name
    HAVING SUM(st.amount) > 0
    ORDER BY collected_tips DESC
  );
$$;


ALTER FUNCTION "public"."get_tips_summary"("start_date" timestamp with time zone, "end_date" timestamp with time zone, "location_ids" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_total_sales_per_location"("p_start" timestamp without time zone, "p_end" timestamp without time zone, "p_location_ids" "text"[]) RETURNS TABLE("location_id" "text", "location_name" "text", "total_sales_amount" numeric, "total_sales_all_methods" numeric, "redeem_amount" numeric, "transaction_count" integer, "avg_transaction_value" numeric, "card_amount" numeric, "cash_amount" numeric, "online_amount" numeric, "payment_method_count" integer, "other_amount" numeric)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    RETURN QUERY
    WITH base_sales AS (
        SELECT 
            s.id AS sale_id,
            s.location_id,
            s.created_at,
            l.name AS location_name
        FROM sales s
        INNER JOIN locations l ON s.location_id = l.id
        WHERE 
            s.created_at BETWEEN p_start AND p_end
            AND NOT s.is_voided
            AND (p_location_ids IS NULL OR s.location_id = ANY(p_location_ids))
    ),

    filtered_payment_methods AS (
        SELECT 
            spm.sale_id,
            spm.payment_method::TEXT AS payment_method,
            s.location_id
        FROM sale_payment_methods spm
        INNER JOIN sales s ON spm.sale_id = s.id
        WHERE 
            NOT spm.is_voided
            AND spm.payment_method::TEXT NOT IN ('voucher', 'membership', 'courtesy')
            AND s.created_at BETWEEN p_start AND p_end
            AND (p_location_ids IS NULL OR s.location_id = ANY(p_location_ids))
    ),

    methods_per_location AS (
        SELECT 
            fp.location_id,
            COUNT(DISTINCT fp.payment_method) AS payment_method_count
        FROM filtered_payment_methods fp
        GROUP BY fp.location_id
    ),

    payment_breakdown AS (
        SELECT 
            bs.location_id,
            bs.location_name,
            bs.sale_id,
            SUM(CASE WHEN spm.payment_method::TEXT = 'card' THEN spm.amount ELSE 0 END) AS card_amount,
            SUM(CASE WHEN spm.payment_method::TEXT = 'cash' THEN spm.amount ELSE 0 END) AS cash_amount,
            SUM(CASE WHEN spm.payment_method::TEXT = 'online' THEN spm.amount ELSE 0 END) AS online_amount,
            -- total excluding voucher/membership/courtesy
            SUM(CASE WHEN spm.payment_method::TEXT NOT IN ('voucher','membership','courtesy') 
                     THEN spm.amount ELSE 0 END) AS total_amount,
            -- total including all methods
            SUM(spm.amount) AS total_amount_all_methods,
            -- redeem column
            SUM(CASE WHEN spm.payment_method::TEXT IN ('voucher','membership','courtesy') 
                     THEN spm.amount ELSE 0 END) AS redeem_amount
        FROM base_sales bs
        INNER JOIN sale_payment_methods spm 
            ON bs.sale_id = spm.sale_id
            AND NOT spm.is_voided
        GROUP BY bs.location_id, bs.location_name, bs.sale_id
    )

    SELECT 
        pb.location_id,
        pb.location_name,
        ROUND(SUM(pb.total_amount), 2) AS total_sales_amount,
        ROUND(SUM(pb.total_amount_all_methods), 2) AS total_sales_all_methods,
        ROUND(SUM(pb.redeem_amount), 2) AS redeem_amount,
        CAST(COUNT(pb.sale_id) AS INTEGER) AS transaction_count,
        ROUND(AVG(pb.total_amount), 2) AS avg_transaction_value,
        ROUND(SUM(pb.card_amount), 2) AS card_amount,
        ROUND(SUM(pb.cash_amount), 2) AS cash_amount,
        ROUND(SUM(pb.online_amount), 2) AS online_amount,
        CAST(dmpl.payment_method_count AS INTEGER) AS payment_method_count,
        0::numeric AS other_amount
    FROM payment_breakdown pb
    LEFT JOIN methods_per_location dmpl ON pb.location_id = dmpl.location_id
    GROUP BY pb.location_id, pb.location_name, dmpl.payment_method_count
    ORDER BY total_sales_amount DESC;
END;
$$;


ALTER FUNCTION "public"."get_total_sales_per_location"("p_start" timestamp without time zone, "p_end" timestamp without time zone, "p_location_ids" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_admin_status"("user_email" "text") RETURNS TABLE("email" "text", "is_admin" boolean, "location_id" "text", "created_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  RETURN QUERY
  SELECT 
    auth.users.email::TEXT,
    (auth.users.raw_user_meta_data->>'is_admin')::BOOLEAN as is_admin,
    (auth.users.raw_user_meta_data->>'location_id')::TEXT as location_id,
    auth.users.created_at
  FROM auth.users 
  WHERE auth.users.email = user_email;
  
  -- Check if user exists
  IF NOT FOUND THEN
    RAISE EXCEPTION 'User with email % not found', user_email;
  END IF;
END;
$$;


ALTER FUNCTION "public"."get_user_admin_status"("user_email" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."make_user_admin"("user_email" "text") RETURNS TABLE("email" "text", "is_admin" boolean, "updated_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  -- Update the user's metadata to set is_admin to true
  UPDATE auth.users 
  SET 
    raw_user_meta_data = jsonb_set(
      COALESCE(raw_user_meta_data, '{}'::jsonb),
      '{is_admin}',
      'true'::jsonb
    ),
    updated_at = NOW()
  WHERE auth.users.email = user_email;
  
  -- Check if any rows were affected
  IF NOT FOUND THEN
    RAISE EXCEPTION 'User with email % not found', user_email;
  END IF;
  
  -- Return the updated user info
  RETURN QUERY
  SELECT 
    auth.users.email::TEXT,
    (auth.users.raw_user_meta_data->>'is_admin')::BOOLEAN as is_admin,
    auth.users.updated_at
  FROM auth.users 
  WHERE auth.users.email = user_email;
END;
$$;


ALTER FUNCTION "public"."make_user_admin"("user_email" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."make_user_staff"("user_email" "text") RETURNS TABLE("email" "text", "is_admin" boolean, "updated_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  -- Update the user's metadata to set is_admin to false
  UPDATE auth.users 
  SET 
    raw_user_meta_data = jsonb_set(
      COALESCE(raw_user_meta_data, '{}'::jsonb),
      '{is_admin}',
      'false'::jsonb
    ),
    updated_at = NOW()
  WHERE auth.users.email = user_email;
  
  -- Check if any rows were affected
  IF NOT FOUND THEN
    RAISE EXCEPTION 'User with email % not found', user_email;
  END IF;
  
  -- Return the updated user info
  RETURN QUERY
  SELECT 
    auth.users.email::TEXT,
    (auth.users.raw_user_meta_data->>'is_admin')::BOOLEAN as is_admin,
    auth.users.updated_at
  FROM auth.users 
  WHERE auth.users.email = user_email;
END;
$$;


ALTER FUNCTION "public"."make_user_staff"("user_email" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."notify_new_appointment"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
  client_full_name text;
  location_name text;
  service_name text;
  staff_name text;
begin
  -- Get client name
  select first_name || ' ' || last_name
  into client_full_name
  from clients
  where id = new.client_id;

  -- Get location name (used also as reception_name)
  select name
  into location_name
  from locations
  where id = new.location_id;

  -- Get service and staff name
  select asp.service_name, asp.staff_name
  into service_name, staff_name
  from appointment_service_pricing asp
  where asp.appointment_id = new.id
  limit 1;

  -- Call Edge Function to send push notification
  perform
    net.http_post(
      url := 'https://ddhntljaamudkquaryrj.supabase.co/functions/v1/push',
      headers := jsonb_build_object(
      'Content-Type', 'application/json'
     ),
      body := jsonb_build_object(
        'title', 'New appointment',
        'body', to_char(new.created_at, 'YYYY-MM-DD HH24:MI:SS') || ' ' ||
                coalesce(service_name, '') || ' for ' ||
                coalesce(client_full_name, '') || ' with ' ||
                coalesce(staff_name, '') || ' booked by ' ||
                coalesce(location_name, ''),
        'data', jsonb_build_object(
          'type', new.status,
          'appointmentId', new.id,
          'location', location_name
        )
      )
    );
end;
$$;


ALTER FUNCTION "public"."notify_new_appointment"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."run_sales_log_report"("location_filter" "text"[], "start_date_param" "date", "end_date_param" "date") RETURNS TABLE("date" "text", "appt_date" "text", "sale_no" "text", "location" "text", "type" "text", "item" "text", "category" "text", "client" "text", "team_member" "text", "channel" "text", "service_price" numeric, "discount_percent" numeric, "gross_sales" numeric, "item_discounts" numeric, "cart_discounts" numeric, "total_discounts" numeric, "refunds" numeric, "net_sales" numeric, "tax" numeric, "total_sales" numeric)
    LANGUAGE "sql"
    AS $$WITH appointment_discounts AS (
    SELECT
      a.id AS appointment_id,
      a.appointment_date,
      s.id AS sale_id,
      s.created_at AS sale_created_at,
      s.payment_method,
      COALESCE(cv1.discount_percentage, 0) AS cart_discount
    FROM appointments a
    JOIN sales s ON s.appointment_id = a.id
    LEFT JOIN client_vouchers cv1 ON cv1.client_id = a.client_id
    WHERE a.status = 'paid'
      AND a.appointment_date BETWEEN start_date_param AND end_date_param
  ),

  service_lines AS (
    SELECT
      aps.appointment_id,
      aps.staff_id,
      aps.service_id,
      aps.price AS service_price,
      ad.cart_discount,
      ad.sale_id,
      ad.sale_created_at,
      ad.payment_method
    FROM appointment_services aps
    JOIN appointment_discounts ad ON ad.appointment_id = aps.appointment_id
  )

  SELECT
    to_char(sl.sale_created_at, 'DD Mon YYYY, HH12:MIam') AS date,
    to_char(a.appointment_date, 'DD Mon YYYY, HH12:MIam') AS appt_date,
    sl.sale_id AS sale_no,
    COALESCE(l.name, 'Unknown') AS location,
    'Service' AS type,
    svc.name AS item,
    svc.category AS category,
    COALESCE(cl.first_name, 'Walk-In') AS client,
    COALESCE(tm.first_name || ' ' || tm.last_name, 'Unknown Staff') AS team_member,
    sl.payment_method AS channel,
    sl.service_price AS service_price,
    COALESCE(sl.cart_discount, 0) AS discount_percent,
    ROUND((sl.service_price / 1.05)::numeric, 2) AS gross_sales,

    CASE 
      WHEN sl.payment_method = 'membership' THEN ROUND((sl.service_price / 1.05)::numeric, 2)
      ELSE 0.00::numeric 
    END AS item_discounts,

    CASE 
      WHEN sl.payment_method = 'membership' THEN 0.00::numeric
      ELSE ROUND(((sl.service_price / 1.05)::numeric) * (COALESCE(sl.cart_discount, 0)::numeric / 100.0), 2)
    END AS cart_discounts,

    CASE 
      WHEN sl.payment_method = 'membership' THEN ROUND((sl.service_price / 1.05)::numeric, 2)
      ELSE ROUND(((sl.service_price / 1.05)::numeric) * (COALESCE(sl.cart_discount, 0)::numeric / 100.0), 2)
    END AS total_discounts,

    0.00::numeric AS refunds,

    CASE 
      WHEN sl.payment_method = 'membership' THEN 0.00::numeric
      ELSE ROUND(
        (sl.service_price / 1.05)::numeric -
        ((sl.service_price / 1.05)::numeric * (COALESCE(sl.cart_discount, 0)::numeric / 100.0)),
        2
      )
    END AS net_sales,

    CASE 
      WHEN sl.payment_method = 'membership' THEN 0.00::numeric
      ELSE ROUND(
        sl.service_price::numeric - (
          ((sl.service_price / 1.05)::numeric * (COALESCE(sl.cart_discount, 0)::numeric / 100.0)) +
          ((sl.service_price / 1.05)::numeric - 
          ((sl.service_price / 1.05)::numeric * (COALESCE(sl.cart_discount, 0)::numeric / 100.0)))
        ),
        2
      )
    END AS tax,

    CASE 
      WHEN sl.payment_method = 'membership' THEN 0.00::numeric
      ELSE ROUND(
        (
          (sl.service_price / 1.05)::numeric -
          ((sl.service_price / 1.05)::numeric * (COALESCE(sl.cart_discount, 0)::numeric / 100.0))
        ) + (
          sl.service_price::numeric - (
            ((sl.service_price / 1.05)::numeric * (COALESCE(sl.cart_discount, 0)::numeric / 100.0)) +
            ((sl.service_price / 1.05)::numeric - 
            ((sl.service_price / 1.05)::numeric * (COALESCE(sl.cart_discount, 0)::numeric / 100.0)))
          )
        ),
        2
      )
    END AS total_sales

  FROM service_lines sl
  JOIN services svc ON svc.id = sl.service_id
  LEFT JOIN appointments a ON a.id = sl.appointment_id
  LEFT JOIN clients cl ON cl.id = a.client_id
  LEFT JOIN team_members tm ON tm.id = sl.staff_id
  LEFT JOIN locations l ON l.id = tm.location_id
  WHERE location_filter IS NULL OR tm.location_id::text = ANY(location_filter)
  ORDER BY sl.sale_created_at, sl.sale_id;$$;


ALTER FUNCTION "public"."run_sales_log_report"("location_filter" "text"[], "start_date_param" "date", "end_date_param" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_used_sessions"("p_client_id" "text", "p_membership_id" "text", "p_purchase_sale_id" bigint, "p_target_sessions" integer) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_client_membership_id TEXT;
    v_current_count        INTEGER;
    v_diff                 INTEGER;
BEGIN
    -- find the client_membership row
    SELECT id INTO v_client_membership_id
    FROM client_memberships
    WHERE client_id = p_client_id
      AND membership_id = p_membership_id
      AND purchase_sale_id = p_purchase_sale_id
    LIMIT 1;

    IF v_client_membership_id IS NULL THEN
        RAISE EXCEPTION 'No matching client_membership found.';
    END IF;

    -- count current non-voided usage
    SELECT COUNT(*) INTO v_current_count
    FROM membership_usage
    WHERE client_membership_id = v_client_membership_id
      AND is_voided = FALSE;

    v_diff := p_target_sessions - v_current_count;

    -- If v_diff < 0 => we need to void some rows (void the most recent ones)
    IF v_diff < 0 THEN
        WITH to_void AS (
            SELECT ctid
            FROM membership_usage
            WHERE client_membership_id = v_client_membership_id
              AND is_voided = FALSE
            -- change ORDER BY to created_at ASC if you want to void the oldest instead
            ORDER BY created_at DESC, ctid
            LIMIT (-v_diff)
        )
        UPDATE membership_usage mu
        SET is_voided = TRUE
        FROM to_void
        WHERE mu.ctid = to_void.ctid;

    -- If v_diff > 0 => insert extra usage rows
    ELSIF v_diff > 0 THEN
        FOR i IN 1..v_diff LOOP
            INSERT INTO membership_usage (client_membership_id, created_at)
            VALUES (v_client_membership_id, NOW());
            -- If membership_usage has other NOT NULL columns, add them here.
        END LOOP;
    END IF;
END;
$$;


ALTER FUNCTION "public"."set_used_sessions"("p_client_id" "text", "p_membership_id" "text", "p_purchase_sale_id" bigint, "p_target_sessions" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_used_sessions"("p_client_id" "text", "p_membership_id" "text", "p_purchase_sale_id" bigint, "p_target_sessions" integer, "p_sale_item_id" "text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_client_membership_id TEXT;
    v_current_count        INTEGER;
    v_diff                 INTEGER;
BEGIN
    -- 1. Find the specific client_memberships record
    SELECT id INTO v_client_membership_id
    FROM client_memberships
    WHERE client_id = p_client_id
      AND membership_id = p_membership_id
      AND purchase_sale_id = p_purchase_sale_id
    LIMIT 1;

    IF v_client_membership_id IS NULL THEN
        RAISE EXCEPTION 'No matching client_membership found.';
    END IF;

    -- 2. Count current non-voided usage
    SELECT COUNT(*)
      INTO v_current_count
    FROM membership_usage
    WHERE client_membership_id = v_client_membership_id
      AND is_voided = FALSE;

    v_diff := p_target_sessions - v_current_count;

    -- 3. If we need fewer: void extra rows (void most recent first)
    IF v_diff < 0 THEN
        WITH to_void AS (
            SELECT ctid
            FROM membership_usage
            WHERE client_membership_id = v_client_membership_id
              AND is_voided = FALSE
            ORDER BY created_at DESC, ctid
            LIMIT (-v_diff)
        )
        UPDATE membership_usage mu
           SET is_voided = TRUE
          FROM to_void
         WHERE mu.ctid = to_void.ctid;

    -- 4. If we need more: insert extra rows with the provided sale_item_id
    ELSIF v_diff > 0 THEN
        FOR i IN 1..v_diff LOOP
            INSERT INTO membership_usage (
                client_membership_id,
                sale_item_id,
                created_at,
                is_voided
            )
            VALUES (
                v_client_membership_id,
                p_sale_item_id,   -- required value
                NOW(),
                FALSE
            );
        END LOOP;
    END IF;
END;
$$;


ALTER FUNCTION "public"."set_used_sessions"("p_client_id" "text", "p_membership_id" "text", "p_purchase_sale_id" bigint, "p_target_sessions" integer, "p_sale_item_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_used_sessions"("p_client_id" "text", "p_membership_id" "text", "p_purchase_sale_id" bigint, "p_sale_item_id" "text", "p_target_sessions" integer) RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    v_client_membership_id TEXT;
    v_current_count        INTEGER;
    v_diff                 INTEGER;
BEGIN
    -- find the client_membership row
    SELECT id INTO v_client_membership_id
    FROM client_memberships
    WHERE client_id = p_client_id
      AND membership_id = p_membership_id
      AND purchase_sale_id = p_purchase_sale_id
    LIMIT 1;

    IF v_client_membership_id IS NULL THEN
        RAISE EXCEPTION 'No matching client_membership found.';
    END IF;

    -- count current non-voided usage
    SELECT COUNT(*) INTO v_current_count
    FROM membership_usage
    WHERE client_membership_id = v_client_membership_id
      AND is_voided = FALSE;

    v_diff := p_target_sessions - v_current_count;

    -- If v_diff < 0 => we need to void some rows (void the most recent ones)
    IF v_diff < 0 THEN
        WITH to_void AS (
            SELECT ctid
            FROM membership_usage
            WHERE client_membership_id = v_client_membership_id
              AND is_voided = FALSE
            -- change ORDER BY to created_at ASC if you want to void the oldest instead
            ORDER BY created_at DESC, ctid
            LIMIT (-v_diff)
        )
        UPDATE membership_usage mu
        SET is_voided = TRUE
        FROM to_void
        WHERE mu.ctid = to_void.ctid;

    -- If v_diff > 0 => insert extra usage rows
    ELSIF v_diff > 0 THEN
        FOR i IN 1..v_diff LOOP
            INSERT INTO membership_usage (client_membership_id, created_at)
            VALUES (v_client_membership_id, NOW());
            -- If membership_usage has other NOT NULL columns, add them here.
        END LOOP;
    END IF;
END;
$$;


ALTER FUNCTION "public"."set_used_sessions"("p_client_id" "text", "p_membership_id" "text", "p_purchase_sale_id" bigint, "p_sale_item_id" "text", "p_target_sessions" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_timestamp"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
   NEW.updated_at = NOW();
   RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_timestamp"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_updated_at_column"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_updated_at_column"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."void_sale_associations"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$BEGIN
    -- Only proceed if the sale is being voided (changed from false to true)
    IF OLD.is_voided = false AND NEW.is_voided = true THEN
        
        -- Void all sale items for this sale
        UPDATE sale_items 
        SET is_voided = true 
        WHERE sale_id = NEW.id AND is_voided = false;
        
        -- Void all sale payment methods for this sale
        UPDATE sale_payment_methods 
        SET is_voided = true 
        WHERE sale_id = NEW.id AND is_voided = false;
        
        -- Void all sale tips for this sale
        UPDATE sale_tips 
        SET is_voided = true 
        WHERE sale_id = NEW.id AND is_voided = false;
        
        -- Void all voucher usage for this sale
        UPDATE voucher_usage 
        SET is_voided = true 
        WHERE sale_id = NEW.id AND is_voided = false;
        
        -- Void all membership usage records linked to sale items of this sale
        UPDATE membership_usage 
        SET is_voided = true 
        WHERE sale_item_id IN (
            SELECT id FROM sale_items WHERE sale_id = NEW.id
        ) AND is_voided = false;
        
        -- Void the associated appointment if it exists
        UPDATE appointments 
        SET status = 'void'
        WHERE id = NEW.appointment_id 
        AND NEW.appointment_id IS NOT NULL 
        AND status != 'void';
        
    END IF;
    
    RETURN NEW;
END;$$;


ALTER FUNCTION "public"."void_sale_associations"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."activity_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "type" "text" NOT NULL,
    "ref_id" "uuid",
    "message" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."activity_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."appointment_services" (
    "id" "text" DEFAULT "public"."gen_alphanum_id"() NOT NULL,
    "appointment_id" "text",
    "service_id" "text" NOT NULL,
    "staff_id" "text",
    "start_time" time without time zone NOT NULL,
    "end_time" time without time zone NOT NULL,
    "price" numeric NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "voucher_discount" double precision,
    "original_staff_id" "text"
);


ALTER TABLE "public"."appointment_services" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."appointments" (
    "id" "text" DEFAULT "public"."gen_alphanum_id"() NOT NULL,
    "client_id" "text",
    "appointment_date" "date" NOT NULL,
    "status" "public"."appointment_status" DEFAULT 'scheduled'::"public"."appointment_status",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "location_id" "text",
    "isOnline" boolean DEFAULT false
);


ALTER TABLE "public"."appointments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sale_items" (
    "id" "text" DEFAULT "public"."gen_alphanum_id"() NOT NULL,
    "item_type" "public"."sale_item_type" NOT NULL,
    "item_id" "text" NOT NULL,
    "item_name" "text" NOT NULL,
    "quantity" integer DEFAULT 1,
    "unit_price" numeric NOT NULL,
    "discount_amount" numeric DEFAULT 0,
    "total_price" numeric NOT NULL,
    "staff_id" "text",
    "appointment_service_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "sale_id" bigint,
    "is_voided" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."sale_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."services" (
    "id" "text" DEFAULT "public"."gen_alphanum_id"() NOT NULL,
    "name" "text" NOT NULL,
    "category" "text" NOT NULL,
    "description" "text",
    "price" numeric(10,2) NOT NULL,
    "duration_minutes" integer NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "extra_time" "text",
    "tax" "text",
    "treatment_type" "text" NOT NULL,
    "resource" "text",
    "online_booking" "text",
    "available_for" "text",
    "voucher_sales" "text",
    "commissions" "text",
    "service_id" "text",
    "sku" "text",
    "use" "text",
    "available_online" boolean DEFAULT false NOT NULL,
    "master_category" "text"
);


ALTER TABLE "public"."services" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."team_members" (
    "id" "text" DEFAULT "public"."gen_alphanum_id"() NOT NULL,
    "phone_number" "text" NOT NULL,
    "email" "text" NOT NULL,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "first_name" "text" NOT NULL,
    "last_name" "text" NOT NULL,
    "calendar_color" "text" DEFAULT '#6366f1'::"text" NOT NULL,
    "team_member_id" "text",
    "notes" "text",
    "visible_to_clients" boolean DEFAULT true NOT NULL,
    "image_url" "text",
    "location_id" "text",
    "order" bigint,
    "isAdmin" boolean
);


ALTER TABLE "public"."team_members" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."appointment_service_pricing" AS
 SELECT "aps"."id" AS "appointment_service_id",
    "aps"."appointment_id",
    "aps"."service_id",
    "s"."name" AS "service_name",
    "s"."category" AS "service_category",
    "s"."duration_minutes",
    "aps"."staff_id",
    (("tm"."first_name" || ' '::"text") || "tm"."last_name") AS "staff_name",
    "aps"."start_time",
    "aps"."end_time",
    "s"."price" AS "original_price",
    "si"."unit_price" AS "final_price",
    "aps"."voucher_discount",
    "si"."discount_amount",
    ("s"."price" - "si"."unit_price") AS "total_discount",
        CASE
            WHEN ("s"."price" > (0)::numeric) THEN "round"(((("s"."price" - "si"."unit_price") / "s"."price") * (100)::numeric), 2)
            ELSE (0)::numeric
        END AS "discount_percentage",
    "si"."quantity",
    "si"."total_price",
    "si"."sale_id",
    "si"."is_voided",
    "aps"."created_at",
    "a"."created_at" AS "appointment_created_at",
    "a"."appointment_date",
    "a"."status" AS "appointment_status"
   FROM (((("public"."appointment_services" "aps"
     JOIN "public"."services" "s" ON (("aps"."service_id" = "s"."id")))
     LEFT JOIN "public"."team_members" "tm" ON (("aps"."staff_id" = "tm"."id")))
     LEFT JOIN "public"."appointments" "a" ON (("aps"."appointment_id" = "a"."id")))
     LEFT JOIN "public"."sale_items" "si" ON ((("aps"."id" = "si"."appointment_service_id") AND ("si"."is_voided" = false))))
  ORDER BY "aps"."appointment_id", "aps"."start_time";


ALTER VIEW "public"."appointment_service_pricing" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."client_memberships" (
    "id" "text" DEFAULT "public"."gen_alphanum_id"() NOT NULL,
    "client_id" "text" NOT NULL,
    "membership_id" "text" NOT NULL,
    "service_id" "text" NOT NULL,
    "purchase_date" "date" DEFAULT "now"() NOT NULL,
    "total_sessions" numeric NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "purchase_sale_id" bigint
);


ALTER TABLE "public"."client_memberships" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."membership_usage" (
    "id" "text" DEFAULT "public"."gen_alphanum_id"() NOT NULL,
    "client_membership_id" "text" NOT NULL,
    "sale_item_id" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "is_voided" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."membership_usage" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."client_memberships_with_usage" AS
 SELECT "cm"."id",
    "cm"."client_id",
    "cm"."membership_id",
    "cm"."service_id",
    "cm"."total_sessions",
    "cm"."purchase_date",
    "cm"."purchase_sale_id",
    "cm"."created_at",
    "cm"."updated_at",
    COALESCE("usage"."used_sessions", (0)::bigint) AS "used_sessions",
    ("cm"."total_sessions" - (COALESCE("usage"."used_sessions", (0)::bigint))::numeric) AS "remaining_sessions"
   FROM ("public"."client_memberships" "cm"
     LEFT JOIN ( SELECT "membership_usage"."client_membership_id",
            "count"(*) AS "used_sessions"
           FROM "public"."membership_usage"
          WHERE ("membership_usage"."is_voided" = false)
          GROUP BY "membership_usage"."client_membership_id") "usage" ON (("cm"."id" = "usage"."client_membership_id")));


ALTER VIEW "public"."client_memberships_with_usage" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."clients" (
    "id" "text" DEFAULT "public"."gen_alphanum_id"() NOT NULL,
    "first_name" "text" NOT NULL,
    "email" "text",
    "phone" "text",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "last_name" "text" NOT NULL,
    "dob" "date",
    "location_id" "text"
);


ALTER TABLE "public"."clients" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."sales_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."sales_id_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sales" (
    "appointment_id" "text",
    "client_id" "text",
    "subtotal" numeric NOT NULL,
    "tax_amount" numeric DEFAULT 0 NOT NULL,
    "voucher_discount" numeric DEFAULT 0 NOT NULL,
    "membership_discount" numeric DEFAULT 0 NOT NULL,
    "tip_amount" numeric DEFAULT 0 NOT NULL,
    "total_amount" numeric NOT NULL,
    "payment_method" "public"."payment_method" NOT NULL,
    "is_voided" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "notes" "text",
    "sale_type" "public"."sale_type" NOT NULL,
    "id" bigint DEFAULT "nextval"('"public"."sales_id_seq"'::"regclass") NOT NULL,
    "discount_amount" numeric DEFAULT '0'::numeric NOT NULL,
    "location_id" "text",
    "manual_discount" numeric DEFAULT '0'::numeric,
    "voucher_code" "text",
    "receptionist_id" "uuid",
    "receptionist_name" "text",
    "payment_method_id" integer,
    CONSTRAINT "sales_services_appointment_required" CHECK ((("sale_type" <> 'services'::"public"."sale_type") OR ("appointment_id" IS NOT NULL)))
);


ALTER TABLE "public"."sales" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."client_sales_summary" AS
 SELECT "c"."id" AS "client_id",
    "c"."first_name",
    "c"."last_name",
    "c"."email",
    "c"."phone",
    COALESCE("sum"("s"."total_amount"), (0)::numeric) AS "total_sales",
    "count"("s"."id") AS "total_transactions"
   FROM ("public"."clients" "c"
     LEFT JOIN "public"."sales" "s" ON ((("c"."id" = "s"."client_id") AND ("s"."is_voided" = false))))
  GROUP BY "c"."id", "c"."first_name", "c"."last_name", "c"."email", "c"."phone";


ALTER VIEW "public"."client_sales_summary" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."client_vouchers" (
    "id" "text" DEFAULT "public"."gen_alphanum_id"() NOT NULL,
    "client_id" "text",
    "voucher_id" "text",
    "purchase_date" "date" DEFAULT "now"() NOT NULL,
    "original_value" numeric NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "voucher_code" "text" NOT NULL,
    "purchase_sale_id" bigint,
    "discount_percentage" real DEFAULT '10'::real NOT NULL,
    "status" "public"."voucher_status",
    "client_voucher_code" "text"
);


ALTER TABLE "public"."client_vouchers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."voucher_usage" (
    "id" "text" DEFAULT "public"."gen_alphanum_id"() NOT NULL,
    "client_voucher_id" "text" NOT NULL,
    "sale_id" integer NOT NULL,
    "amount_used" numeric NOT NULL,
    "discount_applied" numeric DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "is_voided" boolean DEFAULT false NOT NULL
);


ALTER TABLE "public"."voucher_usage" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."client_vouchers_with_usage" AS
 SELECT "cv"."id",
    "cv"."client_id",
    "cv"."voucher_id",
    "cv"."original_value",
    "cv"."voucher_code",
    "cv"."purchase_date",
    "cv"."purchase_sale_id",
    "cv"."created_at",
    "cv"."updated_at",
    "cv"."discount_percentage",
    COALESCE("usage"."total_used", (0)::numeric) AS "total_used",
    COALESCE("usage"."total_discount_applied", (0)::numeric) AS "total_discount_applied",
    ("cv"."original_value" - COALESCE("usage"."total_used", (0)::numeric)) AS "remaining_balance"
   FROM ("public"."client_vouchers" "cv"
     LEFT JOIN ( SELECT "voucher_usage"."client_voucher_id",
            "sum"("voucher_usage"."amount_used") AS "total_used",
            "sum"("voucher_usage"."discount_applied") AS "total_discount_applied"
           FROM "public"."voucher_usage"
          WHERE ("voucher_usage"."is_voided" = false)
          GROUP BY "voucher_usage"."client_voucher_id") "usage" ON (("cv"."id" = "usage"."client_voucher_id")));


ALTER VIEW "public"."client_vouchers_with_usage" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."clients_archive" (
    "id" "text" NOT NULL,
    "first_name" "text",
    "last_name" "text",
    "phone" "text",
    "email" "text",
    "dob" "date",
    "notes" "text",
    "location_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "archived_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."clients_archive" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."commission_calculations" (
    "id" "text" DEFAULT "public"."gen_alphanum_id"() NOT NULL,
    "team_member_id" "text" NOT NULL,
    "service_id" "text" NOT NULL,
    "sale_item_id" "text" NOT NULL,
    "sale_id" bigint NOT NULL,
    "commission_amount" numeric DEFAULT 0 NOT NULL,
    "commission_rate" numeric DEFAULT 0 NOT NULL,
    "commission_type" "text" NOT NULL,
    "tier_applied" integer,
    "sales_amount" numeric NOT NULL,
    "calculation_date" timestamp with time zone DEFAULT "now"(),
    "sales_period_start" "date" NOT NULL,
    "sales_period_end" "date" NOT NULL,
    "is_paid" boolean DEFAULT false NOT NULL,
    "paid_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "commission_calculations_commission_type_check" CHECK (("commission_type" = ANY (ARRAY['fixed'::"text", 'tiered'::"text"])))
);


ALTER TABLE "public"."commission_calculations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."device_push_tokens" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "expo_push_token" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "platform" "text",
    "environment" "text",
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."device_push_tokens" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."employee_shifts" (
    "id" integer NOT NULL,
    "team_member_id" character varying(50) NOT NULL,
    "team_member_name" character varying(255) NOT NULL,
    "location_id" "text",
    "start_date" "date" NOT NULL,
    "end_date" "date",
    "weekly_schedule" "jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    "updated_at" timestamp with time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE "public"."employee_shifts" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."employee_shifts_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."employee_shifts_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."employee_shifts_id_seq" OWNED BY "public"."employee_shifts"."id";



CREATE TABLE IF NOT EXISTS "public"."global_working_hours" (
    "id" integer NOT NULL,
    "location_id" "text",
    "day_of_week" integer NOT NULL,
    "start_time" time without time zone,
    "end_time" time without time zone,
    "is_closed" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "global_working_hours_day_of_week_check" CHECK ((("day_of_week" >= 0) AND ("day_of_week" <= 6)))
);


ALTER TABLE "public"."global_working_hours" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."global_working_hours_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."global_working_hours_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."global_working_hours_id_seq" OWNED BY "public"."global_working_hours"."id";



CREATE TABLE IF NOT EXISTS "public"."locations" (
    "id" "text" DEFAULT "public"."gen_alphanum_id"() NOT NULL,
    "name" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "photosUrl" "text"[]
);


ALTER TABLE "public"."locations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."memberships" (
    "id" "text" DEFAULT "public"."gen_alphanum_id"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "service_id" "text" NOT NULL,
    "total_sessions" integer NOT NULL,
    "price" numeric(10,2) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "memberships_price_check" CHECK (("price" >= (0)::numeric)),
    CONSTRAINT "memberships_total_sessions_check" CHECK (("total_sessions" > 0))
);


ALTER TABLE "public"."memberships" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text" NOT NULL,
    "body" "text" NOT NULL,
    "type" "text",
    "appointment_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "sale_id" bigint
);


ALTER TABLE "public"."notifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payment_methods" (
    "id" integer NOT NULL,
    "name" "text" NOT NULL,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp without time zone DEFAULT "now"()
);


ALTER TABLE "public"."payment_methods" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."payment_methods_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."payment_methods_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."payment_methods_id_seq" OWNED BY "public"."payment_methods"."id";



CREATE TABLE IF NOT EXISTS "public"."products" (
    "id" "text" DEFAULT "public"."gen_alphanum_id"() NOT NULL,
    "product_name" "text" NOT NULL,
    "sku" "text",
    "additional_skus" "text"[],
    "barcode" "text",
    "short_description" "text",
    "description" "text",
    "measure_type" "text",
    "measure_value" numeric(10,3),
    "cost_price" numeric(10,2),
    "full_price" numeric(10,2),
    "tax_rate" "text",
    "category" "text",
    "brand" "text",
    "supplier" "text",
    "total_stock" integer DEFAULT 0 NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "created_by" "text",
    "updated_by" "text"
);


ALTER TABLE "public"."products" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sale_item_staff" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "sale_item_id" "text",
    "staff_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."sale_item_staff" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sale_payment_methods" (
    "id" "text" DEFAULT "public"."gen_alphanum_id"() NOT NULL,
    "sale_id" integer NOT NULL,
    "payment_method" "public"."payment_method" NOT NULL,
    "amount" numeric(10,2) NOT NULL,
    "is_voided" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "payment_method_id" integer
);


ALTER TABLE "public"."sale_payment_methods" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sale_tips" (
    "id" "text" DEFAULT "public"."gen_alphanum_id"() NOT NULL,
    "staff_id" "text",
    "amount" numeric NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "sale_id" bigint,
    "payment_method_tip" "public"."payment_method_tip",
    "is_voided" boolean DEFAULT false NOT NULL,
    "payment_method_id" integer
);


ALTER TABLE "public"."sale_tips" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."settings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "location_id" "text",
    "setting_key" "text" NOT NULL,
    "setting_value" boolean DEFAULT false NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."team_member_commission" (
    "id" "text" DEFAULT "public"."gen_alphanum_id"() NOT NULL,
    "team_member_id" "text" NOT NULL,
    "is_enabled" boolean DEFAULT true NOT NULL,
    "commission_type" "text" NOT NULL,
    "rate_type" "text" DEFAULT 'percentage'::"text" NOT NULL,
    "default_rate" numeric DEFAULT 0 NOT NULL,
    "sales_period" "text" DEFAULT 'monthly'::"text" NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "team_member_commission_commission_type_check" CHECK (("commission_type" = ANY (ARRAY['fixed_rate'::"text", 'tiered'::"text"]))),
    CONSTRAINT "team_member_commission_rate_type_check" CHECK (("rate_type" = ANY (ARRAY['percentage'::"text", 'fixed_amount'::"text"]))),
    CONSTRAINT "team_member_commission_sales_period_check" CHECK (("sales_period" = ANY (ARRAY['daily'::"text", 'weekly'::"text", 'monthly'::"text", 'yearly'::"text"])))
);


ALTER TABLE "public"."team_member_commission" OWNER TO "postgres";


COMMENT ON TABLE "public"."team_member_commission" IS 'Team member commission settings - supports both fixed rate and tiered structure';



CREATE TABLE IF NOT EXISTS "public"."team_member_commission_tiers" (
    "id" "text" DEFAULT "public"."gen_alphanum_id"() NOT NULL,
    "team_member_commission_id" "text" NOT NULL,
    "tier_number" integer NOT NULL,
    "tier_name" "text" NOT NULL,
    "range_from" numeric DEFAULT 0 NOT NULL,
    "range_to" numeric,
    "commission_rate" numeric DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "check_tier_range_validity" CHECK ((("range_from" >= (0)::numeric) AND (("range_to" IS NULL) OR ("range_to" > "range_from"))))
);


ALTER TABLE "public"."team_member_commission_tiers" OWNER TO "postgres";


COMMENT ON TABLE "public"."team_member_commission_tiers" IS 'Tiers for tiered commission structure (like Tier 1: AED 0-1000 earns 5%)';



CREATE TABLE IF NOT EXISTS "public"."temp_clients" (
    "id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "phone" "text"
);


ALTER TABLE "public"."temp_clients" OWNER TO "postgres";


ALTER TABLE "public"."temp_clients" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."temp_clients_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."vouchers" (
    "name" character varying(255) NOT NULL,
    "price" numeric(10,2) NOT NULL,
    "description" "text",
    "voucher_code" "text" NOT NULL,
    "is_active" boolean DEFAULT true,
    "expiry_date" timestamp with time zone DEFAULT "now"(),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" integer,
    "updated_by" integer,
    "id" "text" DEFAULT "public"."gen_alphanum_id"() NOT NULL,
    "discount_percentage" real DEFAULT '10'::real NOT NULL,
    CONSTRAINT "vouchers_price_check" CHECK (("price" >= (0)::numeric))
);


ALTER TABLE "public"."vouchers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."working_hours" (
    "id" bigint NOT NULL,
    "date" "date",
    "start_time" time without time zone,
    "end_time" time without time zone
);


ALTER TABLE "public"."working_hours" OWNER TO "postgres";


ALTER TABLE "public"."working_hours" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."working_hours_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE ONLY "public"."employee_shifts" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."employee_shifts_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."global_working_hours" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."global_working_hours_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."payment_methods" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."payment_methods_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."activity_log"
    ADD CONSTRAINT "activity_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."appointment_services"
    ADD CONSTRAINT "appointment_services_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."appointments"
    ADD CONSTRAINT "appointments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."client_memberships"
    ADD CONSTRAINT "client_memberships_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."client_vouchers"
    ADD CONSTRAINT "client_vouchers_client_voucher_code_key" UNIQUE ("client_voucher_code");



ALTER TABLE ONLY "public"."client_vouchers"
    ADD CONSTRAINT "client_vouchers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."client_vouchers"
    ADD CONSTRAINT "client_vouchers_voucher_code_key" UNIQUE ("voucher_code");



ALTER TABLE ONLY "public"."clients_archive"
    ADD CONSTRAINT "clients_archive_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."clients"
    ADD CONSTRAINT "clients_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."commission_calculations"
    ADD CONSTRAINT "commission_calculations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."device_push_tokens"
    ADD CONSTRAINT "device_push_tokens_expo_push_token_key" UNIQUE ("expo_push_token");



ALTER TABLE ONLY "public"."device_push_tokens"
    ADD CONSTRAINT "device_push_tokens_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."employee_shifts"
    ADD CONSTRAINT "employee_shifts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."global_working_hours"
    ADD CONSTRAINT "global_working_hours_location_id_day_of_week_key" UNIQUE ("location_id", "day_of_week");



ALTER TABLE ONLY "public"."global_working_hours"
    ADD CONSTRAINT "global_working_hours_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."locations"
    ADD CONSTRAINT "locations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."membership_usage"
    ADD CONSTRAINT "membership_usage_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."memberships"
    ADD CONSTRAINT "memberships_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payment_methods"
    ADD CONSTRAINT "payment_methods_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."payment_methods"
    ADD CONSTRAINT "payment_methods_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."products"
    ADD CONSTRAINT "products_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sale_item_staff"
    ADD CONSTRAINT "sale_item_staff_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sale_item_staff"
    ADD CONSTRAINT "sale_item_staff_sale_item_id_staff_id_key" UNIQUE ("sale_item_id", "staff_id");



ALTER TABLE ONLY "public"."sale_items"
    ADD CONSTRAINT "sale_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sale_payment_methods"
    ADD CONSTRAINT "sale_payment_methods_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sale_tips"
    ADD CONSTRAINT "sale_tips_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sales"
    ADD CONSTRAINT "sales_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."services"
    ADD CONSTRAINT "services_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."settings"
    ADD CONSTRAINT "settings_location_id_setting_key_key" UNIQUE ("location_id", "setting_key");



ALTER TABLE ONLY "public"."settings"
    ADD CONSTRAINT "settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."team_member_commission"
    ADD CONSTRAINT "team_member_commission_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."team_member_commission_tiers"
    ADD CONSTRAINT "team_member_commission_tiers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."team_members"
    ADD CONSTRAINT "team_members_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."temp_clients"
    ADD CONSTRAINT "temp_clients_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."team_member_commission"
    ADD CONSTRAINT "unique_team_member" UNIQUE ("team_member_id");



ALTER TABLE ONLY "public"."team_member_commission_tiers"
    ADD CONSTRAINT "unique_tier_per_member" UNIQUE ("team_member_commission_id", "tier_number");



ALTER TABLE ONLY "public"."voucher_usage"
    ADD CONSTRAINT "voucher_usage_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."vouchers"
    ADD CONSTRAINT "vouchers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."vouchers"
    ADD CONSTRAINT "vouchers_voucher_code_key" UNIQUE ("voucher_code");



ALTER TABLE ONLY "public"."working_hours"
    ADD CONSTRAINT "working_hours_pkey" PRIMARY KEY ("id");



CREATE UNIQUE INDEX "device_push_tokens_token_uidx" ON "public"."device_push_tokens" USING "btree" ("expo_push_token");



CREATE INDEX "idx_appointments_date" ON "public"."appointments" USING "btree" ("appointment_date");



CREATE INDEX "idx_global_working_hours_location_day" ON "public"."global_working_hours" USING "btree" ("location_id", "day_of_week");



CREATE INDEX "idx_memberships_service_id" ON "public"."memberships" USING "btree" ("service_id");



CREATE INDEX "idx_products_barcode" ON "public"."products" USING "btree" ("barcode") WHERE ("barcode" IS NOT NULL);



CREATE INDEX "idx_products_brand" ON "public"."products" USING "btree" ("brand");



CREATE INDEX "idx_products_category" ON "public"."products" USING "btree" ("category");



CREATE INDEX "idx_products_is_active" ON "public"."products" USING "btree" ("is_active");



CREATE INDEX "idx_products_sku" ON "public"."products" USING "btree" ("sku");



CREATE INDEX "idx_products_supplier" ON "public"."products" USING "btree" ("supplier");



CREATE INDEX "idx_sale_payment_methods_is_voided" ON "public"."sale_payment_methods" USING "btree" ("is_voided");



CREATE INDEX "idx_sale_payment_methods_payment_method" ON "public"."sale_payment_methods" USING "btree" ("payment_method");



CREATE INDEX "idx_sale_payment_methods_sale_id" ON "public"."sale_payment_methods" USING "btree" ("sale_id");



CREATE INDEX "idx_settings_location_key" ON "public"."settings" USING "btree" ("location_id", "setting_key");



CREATE INDEX "idx_team_member_commission_is_enabled" ON "public"."team_member_commission" USING "btree" ("is_enabled");



CREATE INDEX "idx_team_member_commission_team_member_id" ON "public"."team_member_commission" USING "btree" ("team_member_id");



CREATE INDEX "idx_team_member_commission_tiers_commission_id" ON "public"."team_member_commission_tiers" USING "btree" ("team_member_commission_id");



CREATE INDEX "idx_team_member_commission_tiers_tier_number" ON "public"."team_member_commission_tiers" USING "btree" ("tier_number");



CREATE INDEX "idx_vouchers_expiry_date" ON "public"."vouchers" USING "btree" ("expiry_date");



CREATE INDEX "idx_vouchers_is_active" ON "public"."vouchers" USING "btree" ("is_active");



CREATE INDEX "idx_vouchers_voucher_code" ON "public"."vouchers" USING "btree" ("voucher_code");



CREATE INDEX "notifications_sale_id_idx" ON "public"."notifications" USING "btree" ("sale_id");



CREATE OR REPLACE TRIGGER "client_vouchers_delete_null_voucher" BEFORE INSERT OR UPDATE ON "public"."client_vouchers" FOR EACH ROW EXECUTE FUNCTION "public"."delete_if_voucher_null"();



CREATE OR REPLACE TRIGGER "trg_device_push_tokens_updated_at" BEFORE UPDATE ON "public"."device_push_tokens" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_void_sale_associations" AFTER UPDATE ON "public"."sales" FOR EACH ROW EXECUTE FUNCTION "public"."void_sale_associations"();



CREATE OR REPLACE TRIGGER "update_appointments_timestamp" BEFORE UPDATE ON "public"."appointments" FOR EACH ROW EXECUTE FUNCTION "public"."update_timestamp"();



CREATE OR REPLACE TRIGGER "update_clients_timestamp" BEFORE UPDATE ON "public"."clients" FOR EACH ROW EXECUTE FUNCTION "public"."update_timestamp"();



CREATE OR REPLACE TRIGGER "update_memberships_timestamp" BEFORE UPDATE ON "public"."memberships" FOR EACH ROW EXECUTE FUNCTION "public"."update_timestamp"();



CREATE OR REPLACE TRIGGER "update_products_timestamp" BEFORE UPDATE ON "public"."products" FOR EACH ROW EXECUTE FUNCTION "public"."update_timestamp"();



CREATE OR REPLACE TRIGGER "update_services_timestamp" BEFORE UPDATE ON "public"."services" FOR EACH ROW EXECUTE FUNCTION "public"."update_timestamp"();



CREATE OR REPLACE TRIGGER "update_team_members_timestamp" BEFORE UPDATE ON "public"."team_members" FOR EACH ROW EXECUTE FUNCTION "public"."update_timestamp"();



CREATE OR REPLACE TRIGGER "update_vouchers_updated_at" BEFORE UPDATE ON "public"."vouchers" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



ALTER TABLE ONLY "public"."appointment_services"
    ADD CONSTRAINT "appointment_services_appointment_id_fkey" FOREIGN KEY ("appointment_id") REFERENCES "public"."appointments"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."appointment_services"
    ADD CONSTRAINT "appointment_services_original_staff_id_fkey" FOREIGN KEY ("original_staff_id") REFERENCES "public"."team_members"("id");



ALTER TABLE ONLY "public"."appointment_services"
    ADD CONSTRAINT "appointment_services_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "public"."services"("id");



ALTER TABLE ONLY "public"."appointment_services"
    ADD CONSTRAINT "appointment_services_staff_id_fkey" FOREIGN KEY ("staff_id") REFERENCES "public"."team_members"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."appointments"
    ADD CONSTRAINT "appointments_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."appointments"
    ADD CONSTRAINT "appointments_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id") ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE ONLY "public"."client_memberships"
    ADD CONSTRAINT "client_memberships_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients"("id");



ALTER TABLE ONLY "public"."client_memberships"
    ADD CONSTRAINT "client_memberships_membership_id_fkey" FOREIGN KEY ("membership_id") REFERENCES "public"."memberships"("id");



ALTER TABLE ONLY "public"."client_memberships"
    ADD CONSTRAINT "client_memberships_purchase_sale_id_fkey" FOREIGN KEY ("purchase_sale_id") REFERENCES "public"."sales"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."client_memberships"
    ADD CONSTRAINT "client_memberships_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "public"."services"("id");



ALTER TABLE ONLY "public"."client_vouchers"
    ADD CONSTRAINT "client_vouchers_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."client_vouchers"
    ADD CONSTRAINT "client_vouchers_purchase_sale_id_fkey" FOREIGN KEY ("purchase_sale_id") REFERENCES "public"."sales"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."client_vouchers"
    ADD CONSTRAINT "client_vouchers_voucher_id_fkey" FOREIGN KEY ("voucher_id") REFERENCES "public"."vouchers"("id") ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE ONLY "public"."clients"
    ADD CONSTRAINT "clients_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id") ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE ONLY "public"."commission_calculations"
    ADD CONSTRAINT "commission_calculations_sale_id_fkey" FOREIGN KEY ("sale_id") REFERENCES "public"."sales"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."commission_calculations"
    ADD CONSTRAINT "commission_calculations_sale_item_id_fkey" FOREIGN KEY ("sale_item_id") REFERENCES "public"."sale_items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."commission_calculations"
    ADD CONSTRAINT "commission_calculations_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "public"."services"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."commission_calculations"
    ADD CONSTRAINT "commission_calculations_team_member_id_fkey" FOREIGN KEY ("team_member_id") REFERENCES "public"."team_members"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."employee_shifts"
    ADD CONSTRAINT "employee_shifts_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."global_working_hours"
    ADD CONSTRAINT "global_working_hours_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."membership_usage"
    ADD CONSTRAINT "membership_usage_client_membership_id_fkey" FOREIGN KEY ("client_membership_id") REFERENCES "public"."client_memberships"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."membership_usage"
    ADD CONSTRAINT "membership_usage_sale_item_id_fkey" FOREIGN KEY ("sale_item_id") REFERENCES "public"."sale_items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."memberships"
    ADD CONSTRAINT "memberships_service_id_fkey" FOREIGN KEY ("service_id") REFERENCES "public"."services"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sale_item_staff"
    ADD CONSTRAINT "sale_item_staff_sale_item_id_fkey" FOREIGN KEY ("sale_item_id") REFERENCES "public"."sale_items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sale_item_staff"
    ADD CONSTRAINT "sale_item_staff_staff_id_fkey" FOREIGN KEY ("staff_id") REFERENCES "public"."team_members"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sale_items"
    ADD CONSTRAINT "sale_items_appointment_service_id_fkey" FOREIGN KEY ("appointment_service_id") REFERENCES "public"."appointment_services"("id");



ALTER TABLE ONLY "public"."sale_items"
    ADD CONSTRAINT "sale_items_sale_id_fkey" FOREIGN KEY ("sale_id") REFERENCES "public"."sales"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sale_items"
    ADD CONSTRAINT "sale_items_staff_id_fkey" FOREIGN KEY ("staff_id") REFERENCES "public"."team_members"("id");



ALTER TABLE ONLY "public"."sale_payment_methods"
    ADD CONSTRAINT "sale_payment_methods_payment_method_id_fkey" FOREIGN KEY ("payment_method_id") REFERENCES "public"."payment_methods"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."sale_payment_methods"
    ADD CONSTRAINT "sale_payment_methods_sale_id_fkey" FOREIGN KEY ("sale_id") REFERENCES "public"."sales"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sale_tips"
    ADD CONSTRAINT "sale_tips_payment_method_id_fkey" FOREIGN KEY ("payment_method_id") REFERENCES "public"."payment_methods"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."sale_tips"
    ADD CONSTRAINT "sale_tips_sale_id_fkey" FOREIGN KEY ("sale_id") REFERENCES "public"."sales"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sale_tips"
    ADD CONSTRAINT "sale_tips_staff_id_fkey" FOREIGN KEY ("staff_id") REFERENCES "public"."team_members"("id");



ALTER TABLE ONLY "public"."sales"
    ADD CONSTRAINT "sales_appointment_id_fkey" FOREIGN KEY ("appointment_id") REFERENCES "public"."appointments"("id");



ALTER TABLE ONLY "public"."sales"
    ADD CONSTRAINT "sales_client_id_fkey" FOREIGN KEY ("client_id") REFERENCES "public"."clients"("id") ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE ONLY "public"."sales"
    ADD CONSTRAINT "sales_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id") ON UPDATE CASCADE ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."sales"
    ADD CONSTRAINT "sales_payment_method_id_fkey" FOREIGN KEY ("payment_method_id") REFERENCES "public"."payment_methods"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."settings"
    ADD CONSTRAINT "settings_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."team_member_commission"
    ADD CONSTRAINT "team_member_commission_team_member_id_fkey" FOREIGN KEY ("team_member_id") REFERENCES "public"."team_members"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."team_member_commission_tiers"
    ADD CONSTRAINT "team_member_commission_tiers_commission_fkey" FOREIGN KEY ("team_member_commission_id") REFERENCES "public"."team_member_commission"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."employee_shifts"
    ADD CONSTRAINT "team_member_shifts_employee_id_fkey" FOREIGN KEY ("team_member_id") REFERENCES "public"."team_members"("id");



ALTER TABLE ONLY "public"."team_members"
    ADD CONSTRAINT "team_members_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id") ON UPDATE CASCADE ON DELETE SET NULL;



ALTER TABLE ONLY "public"."voucher_usage"
    ADD CONSTRAINT "voucher_usage_client_voucher_id_fkey" FOREIGN KEY ("client_voucher_id") REFERENCES "public"."client_vouchers"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."voucher_usage"
    ADD CONSTRAINT "voucher_usage_sale_id_fkey" FOREIGN KEY ("sale_id") REFERENCES "public"."sales"("id") ON DELETE CASCADE;



CREATE POLICY "Admins can manage global working hours" ON "public"."global_working_hours" USING ((EXISTS ( SELECT 1
   FROM "public"."team_members" "tm"
  WHERE (("tm"."id" = ("auth"."uid"())::"text") AND ("tm"."isAdmin" = true)))));



CREATE POLICY "Allow authenticated users to delete working hours" ON "public"."working_hours" FOR DELETE TO "authenticated" USING (true);



CREATE POLICY "Allow authenticated users to insert working hours" ON "public"."working_hours" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Allow authenticated users to read working hours" ON "public"."working_hours" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow authenticated users to update working hours" ON "public"."working_hours" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Authenticated users can read global working hours" ON "public"."global_working_hours" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated users can view global working hours" ON "public"."global_working_hours" FOR SELECT USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "Enable all access for all users" ON "public"."appointments" USING (true) WITH CHECK (true);



CREATE POLICY "Enable all access for all users" ON "public"."memberships" USING (true) WITH CHECK (true);



CREATE POLICY "Enable all access for all users" ON "public"."products" USING (true) WITH CHECK (true);



CREATE POLICY "Enable all access for all users" ON "public"."services" USING (true) WITH CHECK (true);



CREATE POLICY "Enable all access for all users" ON "public"."team_members" USING (true) WITH CHECK (true);



CREATE POLICY "Enable all access for all users" ON "public"."vouchers" USING (true) WITH CHECK (true);



CREATE POLICY "Enable all access for auth users" ON "public"."locations" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Enable all access for auth users" ON "public"."membership_usage" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Enable all for all users" ON "public"."clients" USING (true) WITH CHECK (true);



CREATE POLICY "Enable all for authenticated users only" ON "public"."appointment_services" TO "authenticated" USING (("auth"."uid"() IS NOT NULL)) WITH CHECK (true);



CREATE POLICY "Enable all for authenticated users only" ON "public"."client_memberships" TO "authenticated" USING (("auth"."uid"() IS NOT NULL)) WITH CHECK (true);



CREATE POLICY "Enable all for authenticated users only" ON "public"."client_vouchers" TO "authenticated" USING (("auth"."uid"() IS NOT NULL)) WITH CHECK (true);



CREATE POLICY "Enable all for authenticated users only" ON "public"."sale_items" TO "authenticated" USING (("auth"."uid"() IS NOT NULL)) WITH CHECK (true);



CREATE POLICY "Enable all for authenticated users only" ON "public"."sale_tips" TO "authenticated" USING (("auth"."uid"() IS NOT NULL)) WITH CHECK (true);



CREATE POLICY "Enable all for authenticated users only" ON "public"."sales" TO "authenticated" USING (("auth"."uid"() IS NOT NULL)) WITH CHECK (true);



CREATE POLICY "Enable all operations for authenticated users" ON "public"."sale_payment_methods" USING (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Only admins can delete global working hours" ON "public"."global_working_hours" FOR DELETE USING ((((("auth"."jwt"() ->> 'user_metadata'::"text"))::"jsonb" ->> 'is_admin'::"text") = 'true'::"text"));



CREATE POLICY "Only admins can insert global working hours" ON "public"."global_working_hours" FOR INSERT WITH CHECK ((((("auth"."jwt"() ->> 'user_metadata'::"text"))::"jsonb" ->> 'is_admin'::"text") = 'true'::"text"));



CREATE POLICY "Only admins can update global working hours" ON "public"."global_working_hours" FOR UPDATE USING ((((("auth"."jwt"() ->> 'user_metadata'::"text"))::"jsonb" ->> 'is_admin'::"text") = 'true'::"text")) WITH CHECK ((((("auth"."jwt"() ->> 'user_metadata'::"text"))::"jsonb" ->> 'is_admin'::"text") = 'true'::"text"));



ALTER TABLE "public"."activity_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."client_memberships" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."clients" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."device_push_tokens" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."global_working_hours" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "insert notifications (testing)" ON "public"."notifications" FOR INSERT WITH CHECK (true);



CREATE POLICY "insert tokens" ON "public"."device_push_tokens" FOR INSERT WITH CHECK (true);



ALTER TABLE "public"."membership_usage" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."memberships" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."products" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "read notifications" ON "public"."notifications" FOR SELECT USING (true);



CREATE POLICY "read tokens" ON "public"."device_push_tokens" FOR SELECT USING (true);



ALTER TABLE "public"."sale_payment_methods" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."temp_clients" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."vouchers" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."working_hours" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";









GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";

























































































































































GRANT ALL ON FUNCTION "public"."bytea_to_text"("data" "bytea") TO "postgres";
GRANT ALL ON FUNCTION "public"."bytea_to_text"("data" "bytea") TO "anon";
GRANT ALL ON FUNCTION "public"."bytea_to_text"("data" "bytea") TO "authenticated";
GRANT ALL ON FUNCTION "public"."bytea_to_text"("data" "bytea") TO "service_role";



GRANT ALL ON FUNCTION "public"."cash_movement_summary"("p_location_ids" "text"[], "p_start" timestamp with time zone, "p_end" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."cash_movement_summary"("p_location_ids" "text"[], "p_start" timestamp with time zone, "p_end" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."cash_movement_summary"("p_location_ids" "text"[], "p_start" timestamp with time zone, "p_end" timestamp with time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."decrement_product_stock"("stock_updates" "public"."product_stock_update"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."decrement_product_stock"("stock_updates" "public"."product_stock_update"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."decrement_product_stock"("stock_updates" "public"."product_stock_update"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."delete_clients_by_ids"("ids" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."delete_clients_by_ids"("ids" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_clients_by_ids"("ids" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."delete_if_voucher_null"() TO "anon";
GRANT ALL ON FUNCTION "public"."delete_if_voucher_null"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_if_voucher_null"() TO "service_role";



GRANT ALL ON FUNCTION "public"."demo_get_filtered_sales_dynamic"("p_start_date" "date", "p_end_date" "date", "p_sale_types" "text"[], "p_payment_methods" "text"[], "p_staff_ids" "text"[], "p_location_ids" "text"[], "p_limit" integer, "p_offset" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."demo_get_filtered_sales_dynamic"("p_start_date" "date", "p_end_date" "date", "p_sale_types" "text"[], "p_payment_methods" "text"[], "p_staff_ids" "text"[], "p_location_ids" "text"[], "p_limit" integer, "p_offset" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."demo_get_filtered_sales_dynamic"("p_start_date" "date", "p_end_date" "date", "p_sale_types" "text"[], "p_payment_methods" "text"[], "p_staff_ids" "text"[], "p_location_ids" "text"[], "p_limit" integer, "p_offset" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."gen_alphanum_id"("len" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."gen_alphanum_id"("len" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."gen_alphanum_id"("len" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_appointments_next_7_days"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_appointments_next_7_days"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_appointments_next_7_days"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_duplicate_clients"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_duplicate_clients"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_duplicate_clients"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_filtered_sales_dynamic"("p_start_date" "date", "p_end_date" "date", "p_sale_types" "text"[], "p_payment_methods" "text"[], "p_staff_ids" "text"[], "p_location_ids" "text"[], "p_limit" integer, "p_offset" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_filtered_sales_dynamic"("p_start_date" "date", "p_end_date" "date", "p_sale_types" "text"[], "p_payment_methods" "text"[], "p_staff_ids" "text"[], "p_location_ids" "text"[], "p_limit" integer, "p_offset" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_filtered_sales_dynamic"("p_start_date" "date", "p_end_date" "date", "p_sale_types" "text"[], "p_payment_methods" "text"[], "p_staff_ids" "text"[], "p_location_ids" "text"[], "p_limit" integer, "p_offset" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_filtered_sales_from_log"("p_start_date" "date", "p_end_date" "date", "p_sale_types" "text"[], "p_staff_names" "text"[], "p_location_names" "text"[], "p_payment_methods" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."get_filtered_sales_from_log"("p_start_date" "date", "p_end_date" "date", "p_sale_types" "text"[], "p_staff_names" "text"[], "p_location_names" "text"[], "p_payment_methods" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_filtered_sales_from_log"("p_start_date" "date", "p_end_date" "date", "p_sale_types" "text"[], "p_staff_names" "text"[], "p_location_names" "text"[], "p_payment_methods" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_filtered_sales_from_log_enhanced"("p_start_date" "date", "p_end_date" "date", "p_sale_types" "text"[], "p_staff_names" "text"[], "p_location_names" "text"[], "p_payment_methods" "text"[], "p_include_services" boolean, "p_include_items" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."get_filtered_sales_from_log_enhanced"("p_start_date" "date", "p_end_date" "date", "p_sale_types" "text"[], "p_staff_names" "text"[], "p_location_names" "text"[], "p_payment_methods" "text"[], "p_include_services" boolean, "p_include_items" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_filtered_sales_from_log_enhanced"("p_start_date" "date", "p_end_date" "date", "p_sale_types" "text"[], "p_staff_names" "text"[], "p_location_names" "text"[], "p_payment_methods" "text"[], "p_include_services" boolean, "p_include_items" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_location_sales_summary"("p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_locations" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."get_location_sales_summary"("p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_locations" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_location_sales_summary"("p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_locations" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_location_sales_totals"("p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_locations" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."get_location_sales_totals"("p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_locations" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_location_sales_totals"("p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_locations" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_payment_totals"("start_ts" timestamp with time zone, "end_ts" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."get_payment_totals"("start_ts" timestamp with time zone, "end_ts" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_payment_totals"("start_ts" timestamp with time zone, "end_ts" timestamp with time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_payment_transactions"("p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_date_type" "text", "p_locations" "text"[], "p_team_members" "text"[], "p_transaction_types" "text"[], "p_payment_methods" "text"[], "p_payment_amount_from" numeric, "p_payment_amount_to" numeric, "p_exclude_gift_card_redemptions" boolean, "p_exclude_upfront_payment_redemptions" boolean, "p_limit" integer, "p_offset" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_payment_transactions"("p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_date_type" "text", "p_locations" "text"[], "p_team_members" "text"[], "p_transaction_types" "text"[], "p_payment_methods" "text"[], "p_payment_amount_from" numeric, "p_payment_amount_to" numeric, "p_exclude_gift_card_redemptions" boolean, "p_exclude_upfront_payment_redemptions" boolean, "p_limit" integer, "p_offset" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_payment_transactions"("p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_date_type" "text", "p_locations" "text"[], "p_team_members" "text"[], "p_transaction_types" "text"[], "p_payment_methods" "text"[], "p_payment_amount_from" numeric, "p_payment_amount_to" numeric, "p_exclude_gift_card_redemptions" boolean, "p_exclude_upfront_payment_redemptions" boolean, "p_limit" integer, "p_offset" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_sales_analytics_by_location_chart"("p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_locations" "text"[], "p_payment_methods" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."get_sales_analytics_by_location_chart"("p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_locations" "text"[], "p_payment_methods" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_sales_analytics_by_location_chart"("p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_locations" "text"[], "p_payment_methods" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_sales_log_filter_options"("p_start_date" "date", "p_end_date" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."get_sales_log_filter_options"("p_start_date" "date", "p_end_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_sales_log_filter_options"("p_start_date" "date", "p_end_date" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_sales_log_filter_options_enhanced"("p_start_date" "date", "p_end_date" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."get_sales_log_filter_options_enhanced"("p_start_date" "date", "p_end_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_sales_log_filter_options_enhanced"("p_start_date" "date", "p_end_date" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_sales_performance_daily_pivot"("p_start_date" "date", "p_end_date" "date", "p_sale_types" "text"[], "p_payment_methods" "text"[], "p_staff_ids" "text"[], "p_location_ids" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."get_sales_performance_daily_pivot"("p_start_date" "date", "p_end_date" "date", "p_sale_types" "text"[], "p_payment_methods" "text"[], "p_staff_ids" "text"[], "p_location_ids" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_sales_performance_daily_pivot"("p_start_date" "date", "p_end_date" "date", "p_sale_types" "text"[], "p_payment_methods" "text"[], "p_staff_ids" "text"[], "p_location_ids" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_sales_performance_daily_summary"("p_start_date" "date", "p_end_date" "date", "p_sale_types" "text"[], "p_payment_methods" "text"[], "p_staff_ids" "text"[], "p_location_ids" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."get_sales_performance_daily_summary"("p_start_date" "date", "p_end_date" "date", "p_sale_types" "text"[], "p_payment_methods" "text"[], "p_staff_ids" "text"[], "p_location_ids" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_sales_performance_daily_summary"("p_start_date" "date", "p_end_date" "date", "p_sale_types" "text"[], "p_payment_methods" "text"[], "p_staff_ids" "text"[], "p_location_ids" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_sales_performance_summary"("p_start_date" "date", "p_end_date" "date", "p_sale_types" "text"[], "p_payment_methods" "text"[], "p_staff_ids" "text"[], "p_location_ids" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."get_sales_performance_summary"("p_start_date" "date", "p_end_date" "date", "p_sale_types" "text"[], "p_payment_methods" "text"[], "p_staff_ids" "text"[], "p_location_ids" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_sales_performance_summary"("p_start_date" "date", "p_end_date" "date", "p_sale_types" "text"[], "p_payment_methods" "text"[], "p_staff_ids" "text"[], "p_location_ids" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_sales_report"("p_start" timestamp with time zone, "p_end" timestamp with time zone, "p_location_ids" "uuid"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."get_sales_report"("p_start" timestamp with time zone, "p_end" timestamp with time zone, "p_location_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_sales_report"("p_start" timestamp with time zone, "p_end" timestamp with time zone, "p_location_ids" "uuid"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_staff_revenue_report"("start_date" "date", "end_date" "date", "location_ids" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."get_staff_revenue_report"("start_date" "date", "end_date" "date", "location_ids" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_staff_revenue_report"("start_date" "date", "end_date" "date", "location_ids" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_team_member_monthly_sales"("p_month" integer, "p_year" integer, "p_team_member_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_team_member_monthly_sales"("p_month" integer, "p_year" integer, "p_team_member_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_team_member_monthly_sales"("p_month" integer, "p_year" integer, "p_team_member_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_tips_summary"("start_date" timestamp with time zone, "end_date" timestamp with time zone, "location_ids" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."get_tips_summary"("start_date" timestamp with time zone, "end_date" timestamp with time zone, "location_ids" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_tips_summary"("start_date" timestamp with time zone, "end_date" timestamp with time zone, "location_ids" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_total_sales_per_location"("p_start" timestamp without time zone, "p_end" timestamp without time zone, "p_location_ids" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."get_total_sales_per_location"("p_start" timestamp without time zone, "p_end" timestamp without time zone, "p_location_ids" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_total_sales_per_location"("p_start" timestamp without time zone, "p_end" timestamp without time zone, "p_location_ids" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_admin_status"("user_email" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_admin_status"("user_email" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_admin_status"("user_email" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."http"("request" "public"."http_request") TO "postgres";
GRANT ALL ON FUNCTION "public"."http"("request" "public"."http_request") TO "anon";
GRANT ALL ON FUNCTION "public"."http"("request" "public"."http_request") TO "authenticated";
GRANT ALL ON FUNCTION "public"."http"("request" "public"."http_request") TO "service_role";



GRANT ALL ON FUNCTION "public"."http_delete"("uri" character varying) TO "postgres";
GRANT ALL ON FUNCTION "public"."http_delete"("uri" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."http_delete"("uri" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_delete"("uri" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."http_delete"("uri" character varying, "content" character varying, "content_type" character varying) TO "postgres";
GRANT ALL ON FUNCTION "public"."http_delete"("uri" character varying, "content" character varying, "content_type" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."http_delete"("uri" character varying, "content" character varying, "content_type" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_delete"("uri" character varying, "content" character varying, "content_type" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."http_get"("uri" character varying) TO "postgres";
GRANT ALL ON FUNCTION "public"."http_get"("uri" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."http_get"("uri" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_get"("uri" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."http_get"("uri" character varying, "data" "jsonb") TO "postgres";
GRANT ALL ON FUNCTION "public"."http_get"("uri" character varying, "data" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."http_get"("uri" character varying, "data" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_get"("uri" character varying, "data" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."http_head"("uri" character varying) TO "postgres";
GRANT ALL ON FUNCTION "public"."http_head"("uri" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."http_head"("uri" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_head"("uri" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."http_header"("field" character varying, "value" character varying) TO "postgres";
GRANT ALL ON FUNCTION "public"."http_header"("field" character varying, "value" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."http_header"("field" character varying, "value" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_header"("field" character varying, "value" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."http_list_curlopt"() TO "postgres";
GRANT ALL ON FUNCTION "public"."http_list_curlopt"() TO "anon";
GRANT ALL ON FUNCTION "public"."http_list_curlopt"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_list_curlopt"() TO "service_role";



GRANT ALL ON FUNCTION "public"."http_patch"("uri" character varying, "content" character varying, "content_type" character varying) TO "postgres";
GRANT ALL ON FUNCTION "public"."http_patch"("uri" character varying, "content" character varying, "content_type" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."http_patch"("uri" character varying, "content" character varying, "content_type" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_patch"("uri" character varying, "content" character varying, "content_type" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."http_post"("uri" character varying, "data" "jsonb") TO "postgres";
GRANT ALL ON FUNCTION "public"."http_post"("uri" character varying, "data" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."http_post"("uri" character varying, "data" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_post"("uri" character varying, "data" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."http_post"("uri" character varying, "content" character varying, "content_type" character varying) TO "postgres";
GRANT ALL ON FUNCTION "public"."http_post"("uri" character varying, "content" character varying, "content_type" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."http_post"("uri" character varying, "content" character varying, "content_type" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_post"("uri" character varying, "content" character varying, "content_type" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."http_put"("uri" character varying, "content" character varying, "content_type" character varying) TO "postgres";
GRANT ALL ON FUNCTION "public"."http_put"("uri" character varying, "content" character varying, "content_type" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."http_put"("uri" character varying, "content" character varying, "content_type" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_put"("uri" character varying, "content" character varying, "content_type" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."http_reset_curlopt"() TO "postgres";
GRANT ALL ON FUNCTION "public"."http_reset_curlopt"() TO "anon";
GRANT ALL ON FUNCTION "public"."http_reset_curlopt"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_reset_curlopt"() TO "service_role";



GRANT ALL ON FUNCTION "public"."http_set_curlopt"("curlopt" character varying, "value" character varying) TO "postgres";
GRANT ALL ON FUNCTION "public"."http_set_curlopt"("curlopt" character varying, "value" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."http_set_curlopt"("curlopt" character varying, "value" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."http_set_curlopt"("curlopt" character varying, "value" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."make_user_admin"("user_email" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."make_user_admin"("user_email" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."make_user_admin"("user_email" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."make_user_staff"("user_email" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."make_user_staff"("user_email" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."make_user_staff"("user_email" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."notify_new_appointment"() TO "anon";
GRANT ALL ON FUNCTION "public"."notify_new_appointment"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."notify_new_appointment"() TO "service_role";



GRANT ALL ON FUNCTION "public"."run_sales_log_report"("location_filter" "text"[], "start_date_param" "date", "end_date_param" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."run_sales_log_report"("location_filter" "text"[], "start_date_param" "date", "end_date_param" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."run_sales_log_report"("location_filter" "text"[], "start_date_param" "date", "end_date_param" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_used_sessions"("p_client_id" "text", "p_membership_id" "text", "p_purchase_sale_id" bigint, "p_target_sessions" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."set_used_sessions"("p_client_id" "text", "p_membership_id" "text", "p_purchase_sale_id" bigint, "p_target_sessions" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_used_sessions"("p_client_id" "text", "p_membership_id" "text", "p_purchase_sale_id" bigint, "p_target_sessions" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."set_used_sessions"("p_client_id" "text", "p_membership_id" "text", "p_purchase_sale_id" bigint, "p_target_sessions" integer, "p_sale_item_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."set_used_sessions"("p_client_id" "text", "p_membership_id" "text", "p_purchase_sale_id" bigint, "p_target_sessions" integer, "p_sale_item_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_used_sessions"("p_client_id" "text", "p_membership_id" "text", "p_purchase_sale_id" bigint, "p_target_sessions" integer, "p_sale_item_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_used_sessions"("p_client_id" "text", "p_membership_id" "text", "p_purchase_sale_id" bigint, "p_sale_item_id" "text", "p_target_sessions" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."set_used_sessions"("p_client_id" "text", "p_membership_id" "text", "p_purchase_sale_id" bigint, "p_sale_item_id" "text", "p_target_sessions" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_used_sessions"("p_client_id" "text", "p_membership_id" "text", "p_purchase_sale_id" bigint, "p_sale_item_id" "text", "p_target_sessions" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."text_to_bytea"("data" "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."text_to_bytea"("data" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."text_to_bytea"("data" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."text_to_bytea"("data" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_timestamp"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_timestamp"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_timestamp"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "service_role";



GRANT ALL ON FUNCTION "public"."urlencode"("string" "bytea") TO "postgres";
GRANT ALL ON FUNCTION "public"."urlencode"("string" "bytea") TO "anon";
GRANT ALL ON FUNCTION "public"."urlencode"("string" "bytea") TO "authenticated";
GRANT ALL ON FUNCTION "public"."urlencode"("string" "bytea") TO "service_role";



GRANT ALL ON FUNCTION "public"."urlencode"("data" "jsonb") TO "postgres";
GRANT ALL ON FUNCTION "public"."urlencode"("data" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."urlencode"("data" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."urlencode"("data" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."urlencode"("string" character varying) TO "postgres";
GRANT ALL ON FUNCTION "public"."urlencode"("string" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."urlencode"("string" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."urlencode"("string" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."void_sale_associations"() TO "anon";
GRANT ALL ON FUNCTION "public"."void_sale_associations"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."void_sale_associations"() TO "service_role";


















GRANT ALL ON TABLE "public"."activity_log" TO "anon";
GRANT ALL ON TABLE "public"."activity_log" TO "authenticated";
GRANT ALL ON TABLE "public"."activity_log" TO "service_role";



GRANT ALL ON TABLE "public"."appointment_services" TO "anon";
GRANT ALL ON TABLE "public"."appointment_services" TO "authenticated";
GRANT ALL ON TABLE "public"."appointment_services" TO "service_role";



GRANT ALL ON TABLE "public"."appointments" TO "anon";
GRANT ALL ON TABLE "public"."appointments" TO "authenticated";
GRANT ALL ON TABLE "public"."appointments" TO "service_role";



GRANT ALL ON TABLE "public"."sale_items" TO "anon";
GRANT ALL ON TABLE "public"."sale_items" TO "authenticated";
GRANT ALL ON TABLE "public"."sale_items" TO "service_role";



GRANT ALL ON TABLE "public"."services" TO "anon";
GRANT ALL ON TABLE "public"."services" TO "authenticated";
GRANT ALL ON TABLE "public"."services" TO "service_role";



GRANT ALL ON TABLE "public"."team_members" TO "anon";
GRANT ALL ON TABLE "public"."team_members" TO "authenticated";
GRANT ALL ON TABLE "public"."team_members" TO "service_role";



GRANT ALL ON TABLE "public"."appointment_service_pricing" TO "anon";
GRANT ALL ON TABLE "public"."appointment_service_pricing" TO "authenticated";
GRANT ALL ON TABLE "public"."appointment_service_pricing" TO "service_role";



GRANT ALL ON TABLE "public"."client_memberships" TO "anon";
GRANT ALL ON TABLE "public"."client_memberships" TO "authenticated";
GRANT ALL ON TABLE "public"."client_memberships" TO "service_role";



GRANT ALL ON TABLE "public"."membership_usage" TO "anon";
GRANT ALL ON TABLE "public"."membership_usage" TO "authenticated";
GRANT ALL ON TABLE "public"."membership_usage" TO "service_role";



GRANT ALL ON TABLE "public"."client_memberships_with_usage" TO "anon";
GRANT ALL ON TABLE "public"."client_memberships_with_usage" TO "authenticated";
GRANT ALL ON TABLE "public"."client_memberships_with_usage" TO "service_role";



GRANT ALL ON TABLE "public"."clients" TO "anon";
GRANT ALL ON TABLE "public"."clients" TO "authenticated";
GRANT ALL ON TABLE "public"."clients" TO "service_role";



GRANT ALL ON SEQUENCE "public"."sales_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."sales_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."sales_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."sales" TO "anon";
GRANT ALL ON TABLE "public"."sales" TO "authenticated";
GRANT ALL ON TABLE "public"."sales" TO "service_role";



GRANT ALL ON TABLE "public"."client_sales_summary" TO "anon";
GRANT ALL ON TABLE "public"."client_sales_summary" TO "authenticated";
GRANT ALL ON TABLE "public"."client_sales_summary" TO "service_role";



GRANT ALL ON TABLE "public"."client_vouchers" TO "anon";
GRANT ALL ON TABLE "public"."client_vouchers" TO "authenticated";
GRANT ALL ON TABLE "public"."client_vouchers" TO "service_role";



GRANT ALL ON TABLE "public"."voucher_usage" TO "anon";
GRANT ALL ON TABLE "public"."voucher_usage" TO "authenticated";
GRANT ALL ON TABLE "public"."voucher_usage" TO "service_role";



GRANT ALL ON TABLE "public"."client_vouchers_with_usage" TO "anon";
GRANT ALL ON TABLE "public"."client_vouchers_with_usage" TO "authenticated";
GRANT ALL ON TABLE "public"."client_vouchers_with_usage" TO "service_role";



GRANT ALL ON TABLE "public"."clients_archive" TO "anon";
GRANT ALL ON TABLE "public"."clients_archive" TO "authenticated";
GRANT ALL ON TABLE "public"."clients_archive" TO "service_role";



GRANT ALL ON TABLE "public"."commission_calculations" TO "anon";
GRANT ALL ON TABLE "public"."commission_calculations" TO "authenticated";
GRANT ALL ON TABLE "public"."commission_calculations" TO "service_role";



GRANT ALL ON TABLE "public"."device_push_tokens" TO "anon";
GRANT ALL ON TABLE "public"."device_push_tokens" TO "authenticated";
GRANT ALL ON TABLE "public"."device_push_tokens" TO "service_role";



GRANT ALL ON TABLE "public"."employee_shifts" TO "anon";
GRANT ALL ON TABLE "public"."employee_shifts" TO "authenticated";
GRANT ALL ON TABLE "public"."employee_shifts" TO "service_role";



GRANT ALL ON SEQUENCE "public"."employee_shifts_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."employee_shifts_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."employee_shifts_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."global_working_hours" TO "anon";
GRANT ALL ON TABLE "public"."global_working_hours" TO "authenticated";
GRANT ALL ON TABLE "public"."global_working_hours" TO "service_role";



GRANT ALL ON SEQUENCE "public"."global_working_hours_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."global_working_hours_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."global_working_hours_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."locations" TO "anon";
GRANT ALL ON TABLE "public"."locations" TO "authenticated";
GRANT ALL ON TABLE "public"."locations" TO "service_role";



GRANT ALL ON TABLE "public"."memberships" TO "anon";
GRANT ALL ON TABLE "public"."memberships" TO "authenticated";
GRANT ALL ON TABLE "public"."memberships" TO "service_role";



GRANT ALL ON TABLE "public"."notifications" TO "anon";
GRANT ALL ON TABLE "public"."notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."notifications" TO "service_role";



GRANT ALL ON TABLE "public"."payment_methods" TO "anon";
GRANT ALL ON TABLE "public"."payment_methods" TO "authenticated";
GRANT ALL ON TABLE "public"."payment_methods" TO "service_role";



GRANT ALL ON SEQUENCE "public"."payment_methods_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."payment_methods_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."payment_methods_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."products" TO "anon";
GRANT ALL ON TABLE "public"."products" TO "authenticated";
GRANT ALL ON TABLE "public"."products" TO "service_role";



GRANT ALL ON TABLE "public"."sale_item_staff" TO "anon";
GRANT ALL ON TABLE "public"."sale_item_staff" TO "authenticated";
GRANT ALL ON TABLE "public"."sale_item_staff" TO "service_role";



GRANT ALL ON TABLE "public"."sale_payment_methods" TO "anon";
GRANT ALL ON TABLE "public"."sale_payment_methods" TO "authenticated";
GRANT ALL ON TABLE "public"."sale_payment_methods" TO "service_role";



GRANT ALL ON TABLE "public"."sale_tips" TO "anon";
GRANT ALL ON TABLE "public"."sale_tips" TO "authenticated";
GRANT ALL ON TABLE "public"."sale_tips" TO "service_role";



GRANT ALL ON TABLE "public"."settings" TO "anon";
GRANT ALL ON TABLE "public"."settings" TO "authenticated";
GRANT ALL ON TABLE "public"."settings" TO "service_role";



GRANT ALL ON TABLE "public"."team_member_commission" TO "anon";
GRANT ALL ON TABLE "public"."team_member_commission" TO "authenticated";
GRANT ALL ON TABLE "public"."team_member_commission" TO "service_role";



GRANT ALL ON TABLE "public"."team_member_commission_tiers" TO "anon";
GRANT ALL ON TABLE "public"."team_member_commission_tiers" TO "authenticated";
GRANT ALL ON TABLE "public"."team_member_commission_tiers" TO "service_role";



GRANT ALL ON TABLE "public"."temp_clients" TO "anon";
GRANT ALL ON TABLE "public"."temp_clients" TO "authenticated";
GRANT ALL ON TABLE "public"."temp_clients" TO "service_role";



GRANT ALL ON SEQUENCE "public"."temp_clients_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."temp_clients_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."temp_clients_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."vouchers" TO "anon";
GRANT ALL ON TABLE "public"."vouchers" TO "authenticated";
GRANT ALL ON TABLE "public"."vouchers" TO "service_role";



GRANT ALL ON TABLE "public"."working_hours" TO "anon";
GRANT ALL ON TABLE "public"."working_hours" TO "authenticated";
GRANT ALL ON TABLE "public"."working_hours" TO "service_role";



GRANT ALL ON SEQUENCE "public"."working_hours_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."working_hours_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."working_hours_id_seq" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";






























