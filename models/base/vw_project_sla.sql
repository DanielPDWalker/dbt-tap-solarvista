{{ config(materialized='table') }}
with workitems as (
    select * from {{ ref('fact_workitem') }}
),
workitem_stages as (
     select * from {{ ref('fact_workitem_stages') }} 
),
projects as (
     select * from {{ ref('dim_project') }} 
),
customers as (
     select * from {{ ref('dim_customer') }}
),
sites as (
     select * from {{ ref('dim_site') }}
),
territories as (
     select * from {{ ref('dim_territory') }}
),
dates as (
    select * from {{ ref('dim_date') }}
),
project_snapshot as (
    select * from {{ ref('dim_project_snapshot')}}
),
project_workitem_count as (
    select distinct
        projects.reference as project_id,
        workitems.count as total_workitems
    from workitems
    left join projects 
        on projects.project_sk = workitems.project_sk   
    group by projects.reference
),
project_workitem_active as (
    select distinct
        projects.reference as project_id,
        workitems.count as active_workitems
    from workitems, projects 
    where projects.project_sk = workitems.project_sk 
    and workitems.current_stage Not in ('Discarded','Closed','RemoteClosed','Rejected','Cancelled')
    group by projects.reference
),
project_reactivated as (
    select distinct
        projects.reference as project_id,
        min(workitems.created_on) AS ValueDate
    from workitems, projects 
    where projects.project_sk = workitems.project_sk 
    and workitems.tags ? 'Reactivation'
    group by projects.reference
),
project_firstfix_date as (
    select
        project_snapshot.reference as project_id,
        min(project_snapshot.closedon) as firstfix_date
    from project_snapshot
    group by project_snapshot.reference
),
project_sla as (
    select
        projects.project_sk
        , min(projects.closedon)
        , count(distinct projects.reference) as total_projects

        , min(workitems.customer_sk) as customer_sk
        , min(workitems.site_sk) as site_sk
        , min(workitems.territory_sk) as territory_sk
        , min(workitems.schedule_start_date) as schedule_start_date
        , min(project_reactivated.ValueDate) as reactivated_timestamp
        , min(workitem_stages.remoteclosed_timestamp) as remoteclosed_timestamp
        , min(workitem_stages.cancelled_timestamp) as cancelled_timestamp
        , min(workitem_stages.preworking_timestamp) as preworking_timestamp
        , min(project_firstfix_date.firstfix_date) as firstfix_date

        , (case
             -- Use PreWorking time as first response or closedon
             when min(workitem_stages.preworking_timestamp) is not null 
                then min(workitem_stages.preworking_timestamp)
                else min(projects.closedon)
         end ) as firstresponse_date
        -- finalfix_date used to calculate final fix SLAs, we only report on closedon
        , min(projects.closedon) as finalfix_date

	    , (case 
		     when min(projects.status) = 'Active' then 1 else 0
		 end) as is_open
        , (case
		     when min(projects.status) = 'Active' then 0 else 1 
		 end) as is_closed
	    , (case 
		     when min(projects.status) = 'Cancelled' then 1 
		 end) as is_cancelled
		, (case 
            when min(project_reactivated.ValueDate) is null then 1 else 0
         end) as is_firstfix
		, (case 
            when min(project_reactivated.ValueDate) is not null then 1 else 0
         end) as is_refix
    from projects
        left join workitems
            on workitems.project_sk = projects.project_sk
        left join workitem_stages
            on workitem_stages.work_item_id = workitems.work_item_id
        left join project_workitem_active on project_workitem_active.project_id = projects.reference
        left join project_reactivated on project_reactivated.project_id = projects.reference
        left join project_firstfix_date on project_firstfix_date.project_id = projects.reference
    group by projects.project_sk
),

stats as (
    select
        distinct projects.reference as project_id,
        projects.closedon::date as report_date,
        EXTRACT(YEAR FROM projects.closedon)::integer as report_year,
        EXTRACT(MONTH FROM projects.closedon)::integer as report_month,
        EXTRACT(DAY FROM projects.closedon)::integer as report_day,

        projects.project_sk,
        customer_id,
        site_id,
        territory_sk,
        schedule_start_date,
        reactivated_timestamp,
        remoteclosed_timestamp,
        cancelled_timestamp,
        preworking_timestamp,
        firstresponse_date,
        firstfix_date,
        finalfix_date,
        is_open,
        is_closed,
        is_cancelled,
        is_firstfix,
        is_refix,

        total_projects,
        total_workitems as total_workitems,
        active_workitems as active_workitems,

        -- Compute "Response" SLA by comparing project 'responseduedate' with 'PreWorking' stage
        {{ dbt_utils.datediff('responseduedate', 'firstresponse_date', 'hour') }} as response_hours,
		(case 
            when projects.responseduedate is null then 0
            when is_cancelled = 1 then 1 
            when firstresponse_date is null and {{ dbt_utils.datediff('projects.responseduedate', 'now()', 'hour') }} <= 0 then 1
            when {{ dbt_utils.datediff('projects.responseduedate', 'firstresponse_date', 'hour') }} <= 0 then 1
            else 0
         end) as response_within_sla,
		(case 
            when projects.responseduedate is null then 0
            when is_cancelled = 1 then 0
            when firstresponse_date is null and {{ dbt_utils.datediff('projects.responseduedate', 'now()', 'hour') }} > 0 then 1
            when {{ dbt_utils.datediff('projects.responseduedate', 'firstresponse_date', 'hour') }} > 0 then 1
            else 0
         end) as response_missed_sla,
        -- Compute "Final Fix" SLA by comparing project 'fixduedate' with project 'finalfix_date'
        {{ dbt_utils.datediff('projects.fixduedate', 'finalfix_date', 'hour') }} as final_fix_hours,
		(case 
            when projects.fixduedate is null then 0
            when is_cancelled = 1 then 1
            when finalfix_date is null and {{ dbt_utils.datediff('projects.fixduedate', 'now()', 'hour') }} <= 0 then 1
            when {{ dbt_utils.datediff('projects.fixduedate', 'finalfix_date', 'hour') }} <= 0 then 1
            else 0
         end) as final_fix_within_sla,
		(case 
            when projects.fixduedate is null then 0
            when is_cancelled = 1 then 0
            when finalfix_date is null and {{ dbt_utils.datediff('projects.fixduedate', 'now()', 'hour') }} > 0 then 1
            when {{ dbt_utils.datediff('projects.fixduedate', 'finalfix_date', 'hour') }} > 0 then 1
            else 0
         end) as final_fix_missed_sla

    from projects
        left join project_sla
            on project_sla.project_sk = projects.project_sk
        left join project_workitem_count on project_workitem_count.project_id = projects.reference
        left join project_workitem_active on project_workitem_active.project_id = projects.reference
    where closedon is not null
),

final as (
    select
        stats.project_id,
        stats.report_date,
        stats.report_year,
        stats.report_month,
        stats.report_day,
        stats.schedule_start_date,
        stats.reactivated_timestamp,
        stats.remoteclosed_timestamp,
        stats.cancelled_timestamp, -- deprecated, update reports to remove this
        stats.preworking_timestamp, -- deprecated, update vw_daily_projects to use dim project snapshot and remove this
        stats.firstresponse_date,
        stats.firstresponse_date as first_response, -- deprecated, update reports to remove this
        stats.firstfix_date,
        stats.finalfix_date,
        stats.finalfix_date as final_fix, -- deprecated, update reports to remove this
        stats.is_open,
        stats.is_closed,
        stats.is_cancelled,
        stats.is_firstfix,
        stats.is_refix,
        stats.total_projects, -- deprecated, update reports to remove this (it's just a count(*))
        stats.total_workitems,
        stats.active_workitems,
        stats.response_hours,
        stats.response_within_sla,
        stats.response_missed_sla,
        stats.final_fix_hours,
        stats.final_fix_within_sla,
        stats.final_fix_missed_sla,

        dates.day_of_month,
        dates.day_of_year,
        dates.day_of_week,
        dates.day_of_week_name,
        dates.week_key,
        dates.week_of_year,
        territories.reference as territory_id,
        territories.name as territory_name,
        sites.reference as site_id,
        sites.name as site_name,
        customers.reference as customer_id,
        customers.name as customer_name,
        projects.createdon,
        projects.closedon,
        projects.appliedfixsla,
        projects.appliedresponsesla,
        projects.project_type,
        projects.problemtype,
        projects.status as project_status,
        projects.responseduedate,
        projects.responseduedate as responsedue_date,  -- deprecated, update reports to remove this
        projects.fixduedate,
        projects.fixduedate as fixdue_date  -- deprecated, update reports to remove this

    from stats
        left join dates on dates.date_day = stats.report_date
        left join projects on projects.project_sk = stats.project_sk
        left join customers on customers.reference = stats.customer_id
        left join sites on sites.reference = stats.site_id
        left join territories on territories.territory_sk = stats.territory_sk
)
select * from final
