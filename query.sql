-- выборка метаданных схемы базы данных для генерации документации
with raw_metadata as (
    -- сбор информации о комментариях к схемам базы данных
    select 
        n.nspname::text as schema_name,
        'schema'::text as object_type,
        n.nspname::text as object_name,
        ''::text as arguments_sql,
        ''::text as result_type_sql,
        ''::text as columns_sql,
        ''::text as indexes_sql,
        ''::text as triggers_sql,
        ''::text as constraints_sql,
        ''::text as policies_sql,
        coalesce(obj_description(n.oid, 'pg_namespace'), ''::text) as comment,
        0 as sort_order
    from pg_catalog.pg_namespace n
    where n.nspname = any($1)
      and obj_description(n.oid, 'pg_namespace') is not null
      and obj_description(n.oid, 'pg_namespace') <> ''

    union all

    -- сбор информации о функциях и процедурах в схемах
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
                else E'\n    ' || regexp_replace(btrim(pg_get_function_arguments(p.oid)), ',\s*', ',' || E'\n' || '    ', 'g') || E'\n'
            end,
            ''
        )::text as arguments_sql,
        coalesce(
            case 
                when pg_get_function_result(p.oid) ilike 'table(%' then
                    'table (' || E'\n' || '    ' || 
                    regexp_replace(
                        btrim(substring(pg_get_function_result(p.oid) from position('(' in pg_get_function_result(p.oid)) + 1 for length(pg_get_function_result(p.oid)) - position('(' in pg_get_function_result(p.oid)) - 1)),
                        ',\s*', 
                        ',' || E'\n' || '    ', 
                        'g'
                    ) || 
                    E'\n' || ')'
                else 
                    lower(pg_get_function_result(p.oid))
            end,
            ''
        )::text as result_type_sql,
        ''::text as columns_sql,
        ''::text as indexes_sql,
        ''::text as triggers_sql,
        ''::text as constraints_sql,
        ''::text as policies_sql,
        coalesce(obj_description(p.oid, 'pg_proc'), ''::text) as comment,
        3 as sort_order
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = any($1)
      and ($2::boolean or pg_get_function_result(p.oid) <> 'trigger')

    union all

    -- сбор информации о пользовательских типах данных enum и domain
    select 
        n.nspname::text as schema_name,
        case t.typtype
            when 'e' then 'enum'
            when 'd' then 'domain'
            else 'type'
        end::text as object_type,
        t.typname::text as object_name,
        ''::text as arguments_sql,
        ''::text as result_type_sql,
        coalesce(types.definition_sql, '')::text as columns_sql,
        ''::text as indexes_sql,
        ''::text as triggers_sql,
        ''::text as constraints_sql,
        ''::text as policies_sql,
        coalesce(obj_description(t.oid, 'pg_type'), ''::text) as comment,
        case t.typtype 
            when 'e' then 1 
            when 'd' then 2 
            else 3 
        end as sort_order
    from pg_catalog.pg_type t
    join pg_catalog.pg_namespace n on n.oid = t.typnamespace
    left join lateral (
        select case 
            when t.typtype = 'e' then 
                E'(\n' || string_agg('    ' || quote_literal(e.enumlabel), ',' || E'\n' order by e.enumsortorder) || E'\n' || ')'
            when t.typtype = 'd' then 
                lower(format_type(t.typbasetype, t.typtypmod)) || 
                case when t.typnotnull then ' not null' else '' end ||
                case when t.typdefault is not null then ' default ' || t.typdefault else '' end
            else ''
        end as definition_sql
        from pg_catalog.pg_type sub
        left join pg_catalog.pg_enum e on e.enumtypid = sub.oid
        where sub.oid = t.oid
    ) types on true
    where n.nspname = any($1)
      and (t.typrelid = 0 or (select c.relkind from pg_catalog.pg_class c where c.oid = t.typrelid) = 'c')
      and t.typtype in ('e', 'd')
      and (
          (t.typtype = 'e' and $3::boolean) or 
          (t.typtype = 'd' and $4::boolean)
      )

    union all

    -- сбор информации о представлениях базы данных
    select 
        n.nspname::text as schema_name,
        'view'::text as object_type,
        c.relname::text as object_name,
        ''::text as arguments_sql,
        ''::text as result_type_sql,
        coalesce(
            case 
                when cols.columns_sql is not null and cols.columns_sql <> '' then
                    '(' || E'\n' || cols.columns_sql || E'\n' || ')'
                else ''
            end, 
            ''
        )::text as columns_sql,
        ''::text as indexes_sql,
        ''::text as triggers_sql,
        ''::text as constraints_sql,
        ''::text as policies_sql,
        coalesce(obj_description(c.oid, 'pg_class'), ''::text) as comment,
        3 as sort_order
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    left join lateral (
        select string_agg(
            format('    %I %s%s', 
                a.attname, 
                lower(format_type(a.atttypid, a.atttypmod)),
                case 
                    when col_description(c.oid, a.attnum) is not null and col_description(c.oid, a.attnum) <> '' 
                    then range_agg.comma || ' -- ' || col_description(c.oid, a.attnum)
                    else range_agg.comma 
                end
            ),
            E'\n' 
            order by a.attnum
        ) as columns_sql
        from pg_catalog.pg_attribute a
        cross join lateral (
            select case 
                when a.attnum < (select max(attnum) from pg_catalog.pg_attribute where attrelid = c.oid and attnum > 0 and not attisdropped) 
                then ',' 
                else '' 
            end as comma
        ) range_agg
        where a.attrelid = c.oid 
          and a.attnum > 0 
          and not a.attisdropped
    ) cols on true
    where n.nspname = any($1)
      and c.relkind = 'v'

    union all

    -- сбор информации о таблицах, нежурналируемых таблицах и гипертаблицах
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
                '(' || E'\n' || 
                coalesce(cols.columns_sql, '') || 
                E'\n' || ')' || E'\n' ||
                'with (' || E'\n' ||
                opts.options_block ||
                E'\n' || ')'
            else 
                '(' || E'\n' || 
                coalesce(cols.columns_sql, '') || 
                E'\n' || ')'
        end::text as columns_sql,
        case when $5::boolean then coalesce(idxs.indexes_sql, ''::text) else ''::text end as indexes_sql,
        coalesce(trig.triggers_sql, ''::text) as triggers_sql,
        case when $6::boolean then coalesce(constr.constraints_sql, ''::text) else ''::text end as constraints_sql,
        coalesce(pol.policies_sql, ''::text) as policies_sql,
        coalesce(obj_description(c.oid, 'pg_class'), ''::text) as comment,
        3 as sort_order
    from pg_catalog.pg_class c
    join pg_catalog.pg_namespace n on n.oid = c.relnamespace
    left join lateral (
        select string_agg(
            format('    %I %s%s', 
                a.attname, 
                lower(format_type(a.atttypid, a.atttypmod)),
                case 
                    when col_description(c.oid, a.attnum) is not null and col_description(c.oid, a.attnum) <> '' 
                    then range_agg.comma || ' -- ' || col_description(c.oid, a.attnum)
                    else range_agg.comma 
                end
            ),
            E'\n' 
            order by a.attnum
        ) as columns_sql
        from pg_catalog.pg_attribute a
        cross join lateral (
            select case 
                when a.attnum < (select max(attnum) from pg_catalog.pg_attribute where attrelid = c.oid and attnum > 0 and not attisdropped) 
                then ',' 
                else '' 
            end as comma
        ) range_agg
        where a.attrelid = c.oid 
          and a.attnum > 0 
          and not a.attisdropped
    ) cols on true
    left join lateral (
        select string_agg(
            format('constraint %I %s', 
                con.conname,
                regexp_replace(
                    regexp_replace(
                        regexp_replace(
                            regexp_replace(lower(pg_get_constraintdef(con.oid)), '^\s*check\s*\(', E'\n    check (' , 'i'),
                            '\s+check\s+\(', E'\n    check (' , 'i'
                        ),
                        '\s+foreign key\s+\(', E'\n    foreign key (' , 'i'
                    ),
                    '\s+references\s+', E'\n    references ' , 'i'
                )
            ),
            ',' || E'\n'
            order by con.contype, con.conname
        ) as constraints_sql
        from pg_catalog.pg_constraint con
        where con.conrelid = c.oid
    ) constr on true
    left join lateral (
        select string_agg(
            case when obj_description(p.oid, 'pg_policy') is not null then '-- ' || obj_description(p.oid, 'pg_policy') || E'\n' else '' end ||
            '    create policy ' || format('%I', p.polname) || ' on ' || format('%I.%I', n.nspname, c.relname) ||
            case when p.polpermissive = false then ' restrictive' else ' permissive' end ||
            case when p.polroles is not null then ' for ' || (select string_agg(rolname, ', ') from pg_catalog.pg_roles where oid = any(p.polroles)) else '' end ||
            case when p.polqual is not null then E'\n' || '        using (' || pg_get_expr(p.polqual, p.polrelid) || ')' else '' end ||
            case when p.polwithcheck is not null then E'\n' || '        with check (' || pg_get_expr(p.polwithcheck, p.polrelid) || ')' else '' end,
            E'\n' || E'\n'
        ) as policies_sql
        from pg_catalog.pg_policy p
        where p.polrelid = c.oid
    ) pol on true
    left join lateral (
        select string_agg(
            case 
                when obj_description(i.indexrelid, 'pg_class') is not null and obj_description(i.indexrelid, 'pg_class') <> '' 
                then '-- ' || obj_description(i.indexrelid, 'pg_class') || E'\n' 
                else '' 
            end ||
            regexp_replace(
                regexp_replace(
                    regexp_replace(
                        regexp_replace(lower(pg_get_indexdef(i.indexrelid)), '^create\s+', '', 'i'), 
                        '\s+using\s+', 
                        E'\n    using ', 
                        'i'
                    ),
                    '\s+on\s+', 
                    E'\n    on ', 
                    'i'
                ),
                '\s+(with|where)\s+',
                E'\n    \\1 ',
                'gi'
            ),
            E'\n' || E'\n'
        ) as indexes_sql
        from pg_catalog.pg_index i
        where i.indrelid = c.oid
    ) idxs on true
    left join lateral (
        select string_agg(
            case 
                when obj_description(t.oid, 'pg_trigger') is not null and obj_description(t.oid, 'pg_trigger') <> '' 
                then '-- ' || obj_description(t.oid, 'pg_trigger') || E'\n' 
                else '' 
            end ||
            regexp_replace(
                regexp_replace(
                    regexp_replace(
                        regexp_replace(
                            regexp_replace(lower(pg_get_triggerdef(t.oid)), '^create\s+', '', 'i'),
                            '\s+(before|after|instead of)\s+', 
                            E'\n    ' || E'\\1' || ' ', 
                            'i'
                        ),
                        '\s+on\s+', 
                        E'\n    on ', 
                        'i'
                    ),
                    '\s+(for each|execute|when)\s+', 
                    E'\n    ' || E'\\1' || ' ', 
                    'gi'
                ),
                '\s+when\s+\(',
                E'\n    when (',
                'gi'
            ),
            E'\n' || E'\n'
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
        select string_agg('    ' || opt.line, ',' || E'\n' order by opt.sort_order) as options_block
        from (
            select 1 as sort_order, unnest(c.reloptions) as line
            where c.reloptions is not null
            
            union all
            
            select sort_order, line 
            from (
                values 
                    (2, case when h_check.hypertable_name is not null then 'tsdb.hypertable' end),
                    (3, case when h_check.hypertable_name is not null then format('tsdb.partition_command = %L', d.column_name) end),
                    (4, case when h_check.hypertable_name is not null then format('tsdb.chunk_interval = %L', d.time_interval::text) end),
                    (5, case when j.job_id is not null then format('tsdb.retention = %L', j.config->>'drop_after') end),
                    (6, case when comp.hypertable_name is not null then 'tsdb.compress' end),
                    (7, case when comp.seg_cols is not null and comp.seg_cols != '' then format('tsdb.segmentby = %L', comp.seg_cols) end),
                    (8, case when comp.ord_cols is not null and comp.ord_cols != '' then format('tsdb.orderby = %L', comp.ord_cols) end)
            ) as v(sort_order, line)
            where line is not null
        ) opt
    ) opts on true
    where n.nspname = any($1)
      and c.relkind = 'r'
)
select 
    schema_name,
    object_type,
    object_name,
    arguments_sql,
    result_type_sql,
    columns_sql,
    indexes_sql,
    triggers_sql,
    constraints_sql,
    policies_sql,
    comment
from raw_metadata
order by 
    schema_name, 
    sort_order, 
    object_name;