--
-- A daily summarised view of customer projects
--

{{ config(materialized='table') }}

with dates as (
    select * from {{ ref('dim_date') }}
),

-- ensure a row is produced for
-- every customer
-- on every report date
-- for every project_type
-- even when there are no projects for some customers
dimensions as (
	select
        distinct c.reference as customer_id, d.date_day, p.project_type
	from dates d
	cross join {{ ref('dim_customer') }} c
	cross join (
		select
			distinct p1.project_type
		from {{ ref('dim_project') }} p1
	) p
),

customers as (
     select * from {{ ref('dim_customer') }}
),

projects as (
     select * from {{ ref('dim_project') }}
),

project_snapshots as (
     select * from {{ ref('dim_project_snapshot') }}
),

workitems as (
    select * from {{ ref('fact_workitem') }}
),

workitem_stages as (
    select * from {{ ref('fact_workitem_stages') }}
),

workitem_stats as (
    select
        date_day, projects.customer_id, projects.project_type

        -- Total work items created on this report_date
        , count(distinct workitems.reference) as total_workitems

        -- Total projects recalled on this report_date
        , sum(case when workitems.tags ? 'Reactivation' then 1 else 0 end) as total_reactivated

    from dates
        left join workitems
            on workitems.created_on::date = date_day
        left join workitem_stages using (work_item_id)
        left join projects
            on projects.project_sk = workitems.project_sk
    group by date_day, projects.customer_id, projects.project_type
),

project_stats as (
    select
        date_day, customer_id, project_type

        -- projects created on a given date
        , count(reference) as total_created
        , sum(case when responseduedate is not null then 1 else 0 end) as total_with_response_sla
        , sum(case when fixduedate is not null then 1 else 0 end) as total_with_final_fix_sla
    from dates
        left join projects
            on projects.createdon::date = dates.date_day
    group by date_day, customer_id, project_type
),

projects_closed as (
    select
        date_day, customer_id, project_type
        -- projects closed on a given date
        , count(distinct reference) as total_closed
    from dates
        left join project_snapshots
            on project_snapshots.dbt_valid_from::date <= date_day 
		    and (project_snapshots.dbt_valid_to::date > date_day or project_snapshots.dbt_valid_to is null)
    where status != 'Active'
    and closedon::date = date_day
    group by date_day, customer_id, project_type
),

-- active projects on a given date
projects_aged_active_totals as (
    select
        date_day, customer_id, project_type
        , count(distinct reference) as total_open
        , sum(case when createdon > date_day - 7 then 1 else 0 end) as total_open_last_7days
        , sum(case when createdon > date_day - 14 then 1 else 0 end) as total_open_last_14days
        , sum(case when createdon < date_day - 7 then 1 else 0 end) as total_open_older_than_7days
        , sum(case when createdon < date_day - 14 then 1 else 0 end) as total_open_older_than_14days
        , sum(case when operationalstatus = 'Not Working' then 1 else 0 end) as total_not_working
        , sum(case when (createdon < date_day - 1 and operationalstatus = 'Not Working') then 1 else 0 end) as total_not_working_over_24_hrs
    from dates
        left join project_snapshots
            on project_snapshots.dbt_valid_from::date <= date_day 
		    and (project_snapshots.dbt_valid_to::date > date_day or project_snapshots.dbt_valid_to is null)
    where status = 'Active'
    group by date_day, customer_id, project_type
),

-- projects with a work item scheduled
projects_scheduled as (
    select
        date_day, projects.customer_id, project_type
        , count(distinct workitems.project_sk) as total_scheduled
    from dates
        left join workitems
            on workitems.schedule_start_date = dates.date_day
        left join projects
            on projects.project_sk = workitems.project_sk
    group by date_day, projects.customer_id, project_type
),

-- projects with a work item scheduled that has been attended
projects_attended as (
    select
        date_day, projects.customer_id, project_type
        , count(distinct workitems.project_sk) as total_attended
    from dates
        left join workitems
            on workitems.schedule_start_date = dates.date_day
        left join workitem_stages
            on workitem_stages.work_item_id = workitems.work_item_id 
        left join projects
            on projects.project_sk = workitems.project_sk
        where (preworking_timestamp::date = date_day or workitem_stages.quickclose_timestamp::date = date_day)
    group by date_day, projects.customer_id, project_type
),

-- Daily stats summarised by customer, type
daily_stats as (
    select
        dimensions.date_day
        , dimensions.customer_id
        , dimensions.project_type

        -- Total projects created on this report_date
        , sum(project_stats.total_created) as total_created
        -- Total projects closed on this report_date
        , sum(projects_closed.total_closed) as total_closed
        -- Total projects that are to be included in response sla calculation
        , sum(project_stats.total_with_response_sla) as total_with_response_sla
        -- Total projects that are to be included in final fix sla calculation
        , sum(project_stats.total_with_final_fix_sla) as total_with_final_fix_sla

        -- Work item based stats
        , sum(workitem_stats.total_workitems) as total_workitems
        , sum(workitem_stats.total_reactivated) as total_reactivated

        -- Rolling totals of active projects on this date
        , sum(projects_aged_active_totals.total_open) as total_open
        , sum(projects_aged_active_totals.total_open_last_7days) as total_open_last_7days
        , sum(projects_aged_active_totals.total_open_last_14days) as total_open_last_14days
        , sum(projects_aged_active_totals.total_open_older_than_7days) as total_open_older_than_7days
        , sum(projects_aged_active_totals.total_open_older_than_14days) as total_open_older_than_14days
        , sum(projects_attended.total_attended) as total_attended
        , sum(projects_scheduled.total_scheduled) as total_scheduled
        , sum(projects_aged_active_totals.total_not_working) as total_not_working
        , sum(projects_aged_active_totals.total_not_working_over_24_hrs) as total_not_working_over_24_hrs

    from dimensions
        left join project_stats
            on project_stats.date_day = dimensions.date_day
            and project_stats.customer_id = dimensions.customer_id
            and project_stats.project_type = dimensions.project_type
        left join workitem_stats
            on workitem_stats.date_day = dimensions.date_day
            and workitem_stats.customer_id = dimensions.customer_id
            and workitem_stats.project_type = dimensions.project_type
        left join projects_closed
            on projects_closed.date_day = dimensions.date_day
            and projects_closed.customer_id = dimensions.customer_id
            and projects_closed.project_type = dimensions.project_type
        left join projects_aged_active_totals
            on projects_aged_active_totals.date_day = dimensions.date_day
            and projects_aged_active_totals.customer_id = dimensions.customer_id
            and projects_aged_active_totals.project_type = dimensions.project_type
        left join projects_scheduled
            on projects_scheduled.date_day = dimensions.date_day
            and projects_scheduled.customer_id = dimensions.customer_id
            and projects_scheduled.project_type = dimensions.project_type
        left join projects_attended
            on projects_attended.date_day = dimensions.date_day
            and projects_attended.customer_id = dimensions.customer_id
            and projects_attended.project_type = dimensions.project_type
    group by dimensions.date_day
        , dimensions.customer_id
        , dimensions.project_type
),

final as (
    select
        daily_stats.date_day as report_date
        , dates.date_year as report_year
        , dates.date_month_of_year as report_month
        , dates.date_day_of_month as report_day
        , daily_stats.customer_id
        , daily_stats.project_type

        , daily_stats.total_created as total_projects  -- deprecated, remove from reports
        , daily_stats.total_created
        , daily_stats.total_closed
        , daily_stats.total_workitems
        , daily_stats.total_reactivated
        , daily_stats.total_open
        , daily_stats.total_open as total_rolling_open  -- deprecated, remove from reports
        , daily_stats.total_open_last_7days
        , daily_stats.total_open_last_14days
        , daily_stats.total_open_older_than_7days
        , daily_stats.total_open_older_than_14days
        , daily_stats.total_scheduled
        , daily_stats.total_attended
        , daily_stats.total_not_working
        , daily_stats.total_not_working_over_24_hrs

        , daily_stats.total_with_response_sla
        , 0 as total_response_within_sla  -- deprecated, remove from reports
        , 0 as total_response_missed_sla  -- deprecated, remove from reports
        , 0 as avg_first_response_hours  -- deprecated, remove from reports
        , 0 as response_sla_percent  -- deprecated, remove from reports

        , daily_stats.total_with_final_fix_sla
        , 0 as total_final_fix_within_sla  -- deprecated, remove from reports
        , 0 as total_final_fix_missed_sla  -- deprecated, remove from reports
        , 0 as avg_final_fix_hours  -- deprecated, remove from reports
        , 0 as final_fix_sla_percent  -- deprecated, remove from reports

        , customers.name as customer_name
        , dates.*

    from daily_stats
        left join customers on customers.reference = daily_stats.customer_id
        left join dates using (date_day)
)

select * from final
