drop policy scenarios_delete on public.scenarios;
create policy scenarios_delete on public.scenarios for delete to authenticated
  using ((owner_id=(select auth.uid()) and visibility<>'official' and public.project_role(project_id)<>'viewer')
         or public.project_role(project_id) in ('owner','admin'));
