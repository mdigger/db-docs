select 
    n.nspname::text as schema_name,
    case p.prokind
        when 'f' then 'function'
        when 'p' then 'procedure'
        else 'function'
    end::text as object_type,
    p.proname::text as object_name,
    coalesce(
        case 
            when btrim(pg_get_function_arguments(p.oid)) = '' then ''
            else regexp_replace(pg_get_function_arguments(p.oid), ',\s*', ',' || chr(10) || '    ', 'g')
        end,
        ''
    )::text as arguments_sql,
    coalesce(
        case 
            when pg_get_function_result(p.oid) ilike 'table(%' then
                'table (' || chr(10) || '    ' || 
                regexp_replace(
                    btrim(substring(pg_get_function_result(p.oid) from position('(' in pg_get_function_result(p.oid)) + 1 for length(pg_get_function_result(p.oid)) - position('(' in pg_get_function_result(p.oid)) - 1)),
                    ',\s*', 
                    ',' || chr(10) || '    ', 
                    'g'
                ) || 
                chr(10) || ')'
            else 
                lower(pg_get_function_result(p.oid))
        end,
        ''
    )::text as result_type_sql,
    ''::text as columns_sql,
    ''::text as indexes_sql,
    ''::text as triggers_sql,
    coalesce(obj_description(p.oid, 'pg_proc'), ''::text) as comment
from pg_catalog.pg_proc p
join pg_catalog.pg_namespace n on n.oid = p.pronamespace
where n.nspname = any($1)
  and ($2::boolean or pg_get_function_result(p.oid) <> 'trigger')

union all

select 
    n.nspname::text as schema_name,
    'view'::text as object_type,
    c.relname::text as object_name,
    ''::text as arguments_sql,
    ''::text as result_type_sql,
    coalesce(cols.columns_sql, '')::text as columns_sql,
    ''::text as indexes_sql,
    ''::text as triggers_sql,
    coalesce(obj_description(c.oid, 'pg_class'), ''::text) as comment
from pg_catalog.pg_class c
join pg_catalog.pg_namespace n on n.oid = c.relnamespace
left join lateral (
    select string_agg(
        format('%I %s', a.attname, lower(format_type(a.atttypid, a.atttypmod))) ||
        case 
            when col_description(c.oid, a.attnum) is not null and col_description(c.oid, a.attnum) <> '' 
            then ' -- ' || col_description(c.oid, a.attnum) 
            else '' 
        end,
        ',' || chr(10) || '    ' 
        order by a.attnum
    ) as columns_sql
    from pg_catalog.pg_attribute a
    where a.attrelid = c.oid 
      and a.attnum > 0 
      and not a.attisdropped
) cols on true
where n.nspname = any($1)
  and c.relkind = 'v'

union all

select 
    n.nspname::text as schema_name,
    case 
        when c.relpersistence = 'u' then 'unlogged table'
        when h_check.hypertable_name is not null then 'hypertable'
        else 'table'
    end::text as object_type,
    c.relname::text as object_name,
    ''::text as arguments_sql,
    ''::text as result_type_sql,
    case 
        when opts.options_block is not null and opts.options_block <> '' then
            '(' || chr(10) || coalesce(cols.columns_sql, '') || chr(10) || ')' || chr(10) ||
            'with (' || chr(10) ||
            opts.options_block ||
            chr(10) || ')'
        else 
            '(' || chr(10) || coalesce(cols.columns_sql, '') || chr(10) || ')'
    end::text as columns_sql,
    coalesce(idxs.indexes_sql, ''::text) as indexes_sql,
    coalesce(trig.triggers_sql, ''::text) as triggers_sql,
    coalesce(obj_description(c.oid, 'pg_class'), ''::text) as comment
from pg_catalog.pg_class c
join pg_catalog.pg_namespace n on n.oid = c.relnamespace
left join lateral (
    select string_agg(
        '    ' || format('%I %s', a.attname, lower(format_type(a.atttypid, a.atttypmod))) ||
        case 
            when col_description(c.oid, a.attnum) is not null and col_description(c.oid, a.attnum) <> '' 
            then ' -- ' || col_description(c.oid, a.attnum) 
            else '' 
        end,
        ',' || chr(10) 
        order by a.attnum
    ) as columns_sql
    from pg_catalog.pg_attribute a
    where a.attrelid = c.oid 
      and a.attnum > 0 
      and not a.attisdropped
) cols on true
left join lateral (
    select string_agg(
        case 
            when obj_description(i.indexrelid, 'pg_class') is not null and obj_description(i.indexrelid, 'pg_class') <> '' 
            then '-- ' || obj_description(i.indexrelid, 'pg_class') || chr(10) 
            else '' 
        end ||
        regexp_replace(
            regexp_replace(
                regexp_replace(lower(pg_get_indexdef(i.indexrelid)), '^create\s+', '', 'i'), 
                '\s+using\s+', 
                chr(10) || '    using ', 
                'i'
            ),
            '\s+\(', 
            chr(10) || '    (', 
            'g'
        ),
        chr(10) || chr(10)
    ) as indexes_sql
    from pg_catalog.pg_index i
    where i.indrelid = c.oid
) idxs on true
left join lateral (
    select string_agg(
        case 
            when obj_description(t.oid, 'pg_trigger') is not null and obj_description(t.oid, 'pg_trigger') <> '' 
            then '-- ' || obj_description(t.oid, 'pg_trigger') || chr(10) 
            else '' 
        end ||
        regexp_replace(
            regexp_replace(
                regexp_replace(
                    regexp_replace(lower(pg_get_triggerdef(t.oid)), '^create\s+', '', 'i'),
                    '\s+(before|after|instead of)\s+', 
                    chr(10) || '    ' || E'\\1' || ' ', 
                    'i'
                ),
                '\s+on\s+', 
                chr(10) || '    on ', 
                'i'
            ),
            '\s+(for each|execute)\s+', 
            chr(10) || '    ' || E'\\1' || ' ', 
            'gi'
        ),
        chr(10) || chr(10)
    ) as triggers_sql
    from pg_catalog.pg_trigger t
    where t.tgrelid = c.oid
      and not t.tgisinternal
) trig on true
left join timescaledb_information.hypertables h_check on h_check.hypertable_schema = n.nspname and h_check.hypertable_name = c.relname
left join timescaledb_information.dimensions d on d.hypertable_schema = n.nspname and d.hypertable_name = c.relname and lower(d.dimension_type) = 'time'
left join timescaledb_information.jobs j on j.hypertable_schema = n.nspname and j.hypertable_name = c.relname and j.proc_name = 'policy_retention'
left join (
    select cs.hypertable_schema, cs.hypertable_name, 
           string_agg(cs.attname, ', ' order by cs.segmentby_column_index) as seg_cols,
           string_agg(cs.attname, ', ' order by cs.orderby_column_index) as ord_cols
    from timescaledb_information.compression_settings cs
    group by cs.hypertable_schema, cs.hypertable_name
) comp on comp.hypertable_schema = n.nspname and comp.hypertable_name = c.relname
left join lateral (
    select string_agg('    ' || opt.line, ',' || chr(10) order by opt.sort_order) as options_block
    from (
        select 1 as sort_order, unnest(c.reloptions) as line
        where c.reloptions is not null
        
        union all
        
        select sort_order, line 
        from (
            values 
                (2, case when h_check.hypertable_name is not null then 'tsdb.hypertable' end),
                (3, case when h_check.hypertable_name is not null then format('tsdb.partition_column = %L', d.column_name) end),
                (4, case when h_check.hypertable_name is not null then format('tsdb.chunk_interval = %L', d.time_interval::text) end),
                (5, case when j.job_id is not null then format('tsdb.retention = %L', j.config->>'drop_after') end),
                (6, case when comp.hypertable_name is not null then 'tsdb.compress' end),
                (7, case when comp.seg_cols is not null then format('tsdb.segmentby = %L', comp.seg_cols) end),
                (8, case when comp.ord_cols is not null then format('tsdb.orderby = %L', comp.ord_cols) end)
        ) as v(sort_order, line)
        where line is not null
    ) opt
) opts on true
where n.nspname = any($1)
  and c.relkind = 'r'

order by schema_name, object_name;