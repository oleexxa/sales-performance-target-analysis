-- step 1: fix inconsistent letter casing in category
-- step 2: check how many duplicate transaction_id rows are fully
-- identical (all columns match, after fixing category)

with fixed_transactions as (
    select
        *
        ,concat(upper(left(trim(category), 1)), lower(substring(trim(category), 2))) as category_fixed
    from sales_transactions_raw
)
select count(*) from (
    select
        transaction_id
        ,transaction_date
        ,store_id
        ,product_id
        ,quantity
        ,unit_price
        ,discount_pct
        ,total_value
        ,channel
        ,category_fixed
    from fixed_transactions
    group by
        transaction_id
        ,transaction_date
        ,store_id
        ,product_id
        ,quantity
        ,unit_price
        ,discount_pct
        ,total_value
        ,channel
        ,category_fixed
    having count(*) > 1
) as full_duplicates;
-- result: 1936 full duplicates


-- step 3: save deduplicated data as a new table
-- (rn = 1 keeps exactly one copy per group)

create table sales_transactions_step1 as
with fixed_transactions as (
    select
        *
        ,concat(upper(left(trim(category), 1)), lower(substring(trim(category), 2))) as category_fixed
    from sales_transactions_raw
),
numbered as (
    select
        *
        ,row_number() over (
            partition by
                transaction_id, transaction_date, store_id, product_id,
                quantity, unit_price, discount_pct, total_value, channel,
                category_fixed
            order by transaction_id
        ) as rn
    from fixed_transactions
)
select * from numbered where rn = 1;
-- result: removes the 1936 full duplicates confirmed above
-- -> 141326 - 1936 = 139390 rows


-- step 4: count nulls in every column (reusable check)

select
    sum(case when quantity is null then 1 else 0 end)      as quantity_nulls,
    sum(case when unit_price is null then 1 else 0 end)    as unit_price_nulls,
    sum(case when discount_pct is null then 1 else 0 end)  as discount_pct_nulls,
    sum(case when total_value is null then 1 else 0 end)   as total_value_nulls
from sales_transactions_step1;
-- result: quantity ~1412, unit_price ~1413, discount_pct ~1413, rest 0


-- step 5: check whether missing values overlap in the same rows

select
    count(*)
from sales_transactions_step1
where quantity is null and unit_price is null and discount_pct is null;
-- result: 0 -> they don't, they're independent (not one big systemic gap)


-- step 6: check if missing quantity concentrates in a specific store,
-- as a percentage (not raw count) to avoid misleading conclusions

select
    store_id
    ,count(*) as total_transactions
    ,sum(case when quantity is null then 1 else 0 end) as missing_quantity
    ,round(sum(case when quantity is null then 1 else 0 end) * 100.0 / count(*), 2) as missing_pct
from sales_transactions_step1
group by store_id
order by missing_pct desc;
-- result: evenly spread ~1-1.2% everywhere -> random, not systemic

-- decision: keep NULLs as-is (safe threshold, random distribution),
-- exclude from calculations where needed rather than deleting or imputing


-- step 7: merge the 153 "hard" duplicate pairs (same transaction_id,
-- different values) into one row each. MIN/MAX ignore NULLs automatically,
-- handling both missing values and the quantity outlier case (MIN picks
-- the smaller, more realistic value)

create table sales_transactions_step2 as
select
    transaction_id
    ,max(transaction_date)  as transaction_date
    ,max(store_id)          as store_id
    ,max(product_id)        as product_id
    ,min(quantity)          as quantity
    ,max(unit_price)        as unit_price
    ,max(discount_pct)      as discount_pct
    ,max(total_value)       as total_value
    ,max(channel)           as channel
    ,max(category)          as category
    ,max(category_fixed)    as category_fixed
from sales_transactions_step1
group by transaction_id;
-- result: 139390 - 306 + 153 = 139237 rows (verified)


-- step 8: verify the merge didn't create internally inconsistent rows
-- (total_value should still match quantity * unit_price * discount for
-- every previously-duplicated transaction)

select
    count(*)
from sales_transactions_step2 s2
where       s2.quantity is not null
        and s2.unit_price is not null
        and s2.discount_pct is not null
        and round(s2.total_value, 2) <> round(s2.quantity * s2.unit_price * (1 - s2.discount_pct / 100), 2)
        and s2.transaction_id in
            (
              select
                transaction_id
              from sales_transactions_step1
              group by transaction_id
              having count(*) > 1
            );
-- result: 0 mismatches -> merge is safe


-- step 9: safety check before converting transaction_date to a real DATE
-- (covers 4 known formats: YYYY-MM-DD, DD/MM/YYYY, MM-DD-YYYY, DD.MM.YYYY)

select count(*) from (
    select
        case
            when transaction_date regexp '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
                then str_to_date(transaction_date, '%Y-%m-%d')
            when transaction_date regexp '^[0-9]{2}/[0-9]{2}/[0-9]{4}$'
                then str_to_date(transaction_date, '%d/%m/%Y')
            when transaction_date regexp '^[0-9]{2}-[0-9]{2}-[0-9]{4}$'
                then str_to_date(transaction_date, '%m-%d-%Y')
            when transaction_date regexp '^[0-9]{2}\\.[0-9]{2}\\.[0-9]{4}$'
                then str_to_date(transaction_date, '%d.%m.%Y')
            else null
        end as fixed_date
    from sales_transactions_step2
) as check_conversion
where fixed_date is null;
-- result: 0 -> every date converts cleanly, no format left unhandled


-- step 10: save the table with transaction_date converted to a real DATE

create table sales_transactions_step3 as
select
    transaction_id
    ,case
        when transaction_date regexp '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
            then str_to_date(transaction_date, '%Y-%m-%d')
        when transaction_date regexp '^[0-9]{2}/[0-9]{2}/[0-9]{4}$'
            then str_to_date(transaction_date, '%d/%m/%Y')
        when transaction_date regexp '^[0-9]{2}-[0-9]{2}-[0-9]{4}$'
            then str_to_date(transaction_date, '%m-%d-%Y')
        when transaction_date regexp '^[0-9]{2}\\.[0-9]{2}\\.[0-9]{4}$'
            then str_to_date(transaction_date, '%d.%m.%Y')
        else null
    end as  transaction_date, store_id, product_id, quantity, unit_price, discount_pct, total_value,
            channel, category, category_fixed
from sales_transactions_step2;
-- result: 139237 rows (unchanged)


-- step 11: check total_value consistency against quantity * unit_price * discount

select
    count(*)
from sales_transactions_step3
where   quantity is not null
    and unit_price is not null
    and discount_pct is not null
    and round(total_value, 2) <> round(quantity * unit_price * (1 - discount_pct / 100), 2);
-- result: 1336 rows inconsistent (~1%)


-- step 12: investigate the size of the discrepancies (not just count)

select
    quantity
    ,unit_price
    ,discount_pct
    ,total_value
    ,round(quantity * unit_price * (1 - discount_pct / 100), 2) as calculated_value
from sales_transactions_step3
where   quantity is not null
    and unit_price is not null
    and discount_pct is not null
    and round(total_value, 2) <> round(quantity * unit_price * (1 - discount_pct / 100), 2)
order by abs(total_value - (quantity * unit_price * (1 - discount_pct / 100))) desc
limit 20;
-- result: huge mismatches (~150x), all traced to quantity = 150


-- step 13: check the full distribution of quantity to find all outliers

select
    quantity
    ,count(*) as how_many
from sales_transactions_step3
where quantity is not null
group by quantity
order by quantity desc
limit 15;
-- result: three implausible spike values -> 150 (76x), 99 (85x), 50 (80x),
-- clearly separated from the realistic range (1-5 units)


-- step 14: build the final clean table
-- - null out the 3 known implausible quantity values (241 rows total);
--   total_value stays correct in these rows, so only quantity is unreliable
-- - drop the old raw category, rename category_fixed -> category

create table sales_transactions_clean as
select
    transaction_id
    ,transaction_date
    ,store_id
    ,product_id
    ,case when quantity in (150, 99, 50) then null else quantity end as quantity
    ,unit_price
    ,discount_pct
    ,total_value
    ,channel
    ,category_fixed as category
from sales_transactions_step3;
-- result: 139237 rows