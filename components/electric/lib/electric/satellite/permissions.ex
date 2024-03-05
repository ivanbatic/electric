defmodule Electric.Satellite.Permissions do
  @moduledoc """
  Provides functions for validating writes from satellites and filtering reads from pg against a
  set of permissions.

  A `#{inspect(__MODULE__)}` struct is generated from a set of protobuf permissions definitions --
  a list of `SatPerms.Grant` structs direct from the DDLX ingest, and a list of `SatPerms.Role`
  structs generated by the DDLX assign triggers.

  The protobuf data is compiled into a set of lookup tables to make permissions checks as
  performant as possible.

  ## Key data structures

  - `Permissions.roles`: a map of `{relation(), privilege()} => assigned_roles()` which allows for
    a quick retrieval of all grants and associated roles for a given action.

    An example might look like:

    ```
    %{
      {{"public", "issues"}, :UPDATE} => %{
        scoped: [
          %Permissions.RoleGrant{role: %Permissions.Role{}, grant: %Permissions.Grant{}},
          %Permissions.RoleGrant{...}
        ],
        unscoped: [
          %Permissions.RoleGrant{role: %Permissions.Role{}, grant: %Permissions.Grant{}},
          %Permissions.RoleGrant{...}
        ]
      },
      {{"public", "issues"}, :INSERT} => %{
        scoped: [
          %Permissions.RoleGrant{...}
        ],
        unscoped: [
          %Permissions.RoleGrant{...}
        ]
      }
      # etc
    }
    ```

    Compiling this lookup table is the main job of the `update/3` function.

  - `%RoleGrant{}`: this struct holds a role and grant where the role provides the grant and the
    grant provides the rights.

  - `assigned_roles()`: A set of scoped and unscoped `RoleGrant` structs. "Unscoped" means that
    the role assignment applies globally and is not rooted on any element of the data.

  ## Applying permissions

  The DDLX system defines a user's roles via `ELECTRIC ASSIGN` statements and then grants those
  roles rights via `ELECTRIC GRANT` statements.

  We translate those `ASSIGN` and `GRANT` statements to actual permissions by first finding which
  roles a user has that apply to the change (insert, update, delete) in question and then
  validating that the grants for those roles allow the change.

  ## Validating writes

  The `validate_write/2` function takes a `Permissions` struct and a transaction and verifies that
  all the writes in the transaction are allowed according to the current permissions rules.

  If any change in the transaction fails the permissions check then the whole transaction is
  rejected.

  The permissions resolution process goes something like this:

  ### 1. Find scoped and unscoped `RoleGrant` instances for the change

  The `assigned_roles()` table is retrieved from the `Permissions.roles` attribute for the given
  change. This allows for quick verification that the user has some kind of permission to perform
  the action.

  If the `assigned_roles()` for a change is `nil` then we know immediately that the user does not
  have the right to make the given change and can bail immediately and return an error.

  Once we have a set of scoped and unscoped roles for a change, then we can test each one to check
  that the role applies to the change (always in the case of unscoped roles, depending on the
  change's position in the data for scoped roles) then test that any conditions on the grant are
  met.

  If the `assigned_roles()` table has any unscoped grants then we can jump to verifying that at
  least one of the grant rules allows for the change (see "Verifying Grants").

  If no unscoped roles/grants match the change or none of the unscoped grant rules allow the
  change then we try to find scoped roles for the change.

  ### 2. Match roles to the scope of the change

  The `Permissions.graph` attribute provides an two implementations of the `Permissions.Graph`
  behaviour, one for the write path and one for the read. The `Permissions.Graph` behaviour allows
  for traversing the tree and finding the associated scope root entry for any node.

  With these we can match a change to a set of scoped roles and then verify their associated
  grants.

  The write graph is complicated by the need to buffer client writes in order to verify
  permissions against new scopes that they may have created.

  ### 3. Look for applicable transient permissions

  If no scoped roles match the change then there might be a matching transient permission. We find
  these by supplying the list of (scoped) Roles we have to the `Transient.for_roles/3` lookup
  function which will match the role's DDLX assignment id and the id of its scope root to the set
  of transient permissions available.

  For every transient permission we have access to, we can then verify the grants for the
  associated role.

  ### 4. Verifying Grants

  Grants can limit the allowed changes by:

  - They can limit the columns allowed. So e.g. you can `GRANT UPDATE (title) ON table TO role` to
    only allow `role` to update the `title` column of a table.

    With a grant of this style if you attempt to write to any other column, the write will be
    rejected.

  - They can have an optional `CHECK` expression that tests the content of the change against some
    function and will reject the write if that check fails.

  ### 5. Allowing the write

  Because the permissions system is at the moment additive, if *any* of the grants succeeds then
  the write is allowed.

  If no role-grant pairs are found that match the change or the conditions on all the matching
  grants fail, then the write is denied and the entire transaction is rejected.

  ### Special cases

  1. An update that moves a row between authentication scopes is treated like an update in the
  original scope and an update in the new scope. The user must have permission for both the update
  and the (pseudo) update for the change to be allowed.

  ## Filtering reads

  The `filter_read/2` function takes a `Permissions` and `Changes.Transaction` structs and filters
  the changes in the transaction according to the current permissions rules.

  The permissions verification process is the same as for verifying writes, except that the lookup
  in step 1 of that process always looks for permission to `:SELECT` on the relation in the
  change.

  ## Pending work

  1. `CHECK` clauses in GRANT statements are not validated at the moment

  2. Column subsetting in DDLX GRANT statements is ignored for the read path
  """
  use Electric.Satellite.Protobuf

  alias Electric.Postgres.Extension.SchemaLoader
  alias Electric.Replication.Changes

  alias Electric.Satellite.Permissions.{
    Eval,
    Grant,
    Graph,
    Read,
    Role,
    Transient,
    Trigger,
    WriteBuffer
  }

  alias Electric.Satellite.{Auth, SatPerms}

  require Logger

  defmodule RoleGrant do
    # links a role to its corresponding grant
    @moduledoc false

    defstruct [:role, :grant]

    @type t() :: %__MODULE__{
            grant: Grant.t(),
            role: Role.t()
          }
  end

  defmodule MoveOut do
    # A message to the shapes system that the update encapsulated here has been moved out of the
    # user's permissions tree and should be deleted from their device.
    @moduledoc false

    defstruct [:change, :scope_path, :relation, :id]
  end

  defmodule ScopeMove do
    # A pseudo-change that we can use to verify that a user has permissions to move a row from
    # scope a to scope b. We create an instance of this struct with the updated row data, treat it
    # as though it were an update and then verify that the user has the required permission.
    # See `expand_change/2`, `required_permission/1` and `Graph.scope_id/3` for use.
    @moduledoc false

    defstruct [:relation, :record]

    @type t() :: %__MODULE__{
            relation: Electric.Postgres.relation(),
            record: Changes.record()
          }
  end

  defstruct [
    :roles,
    :scoped_roles,
    :auth,
    :scopes,
    :write_buffer,
    :triggers,
    :intermediate_roles,
    :grants,
    source: %{rules: %{grants: [], assigns: []}, roles: [], schema: nil},
    transient_lut: Transient
  ]

  @type change() :: Changes.change()
  @type tx() :: Changes.Transaction.t()
  @type lsn() :: Electric.Postgres.Lsn.t()
  @type mode() :: :read | :write
  @type relation() :: Electric.Postgres.relation()
  @type privilege() :: :INSERT | :UPDATE | :DELETE | :SELECT
  @type table_permission() :: {relation(), privilege()}
  @type id() :: Electric.Postgres.pk()
  @type scope_id() :: id()
  @type scope() :: {relation, scope_id()}
  @type scoped_change() :: {change(), scope()}
  @type assigned_roles() :: %{unscoped: [RoleGrant.t()], scoped: [RoleGrant.t()]}
  @type role_lookup() :: %{optional(table_permission()) => assigned_roles()}

  @type move_out() :: %MoveOut{
          change: change(),
          scope_path: Graph.scope_path_information(),
          relation: relation(),
          id: scope_id()
        }

  @type empty() :: %__MODULE__{
          auth: Auth.t(),
          transient_lut: Transient.lut()
        }

  @type t() :: %__MODULE__{
          roles: role_lookup(),
          grants: [Grant.t()],
          source: %{
            rules: %{
              grants: [%SatPerms.Grant{}],
              assigns: [%SatPerms.Assign{}]
            },
            roles: [%SatPerms.Role{}],
            schema: SchemaLoader.Version.t()
          },
          auth: Auth.t(),
          transient_lut: Transient.lut(),
          write_buffer: WriteBuffer.t(),
          scopes: [relation()],
          scoped_roles: %{relation => [Role.t()]},
          triggers: Trigger.triggers()
        }

  @doc """
  Configure a new empty permissions configuration with the given auth token, scope resolver and
  (optionally) a transient permissions lookup table name.

  Use `update/3` to add actual role and grant information.

  Arguments:

  - `auth` is the `#{Auth}` struct received from the connection auth
  - `transient_lut` (default: `#{Transient}`) is the name of the ETS table holding active
    transient permissions
  """
  @spec new(Auth.t(), Transient.lut()) :: empty()
  def new(%Auth{} = auth, transient_lut_name \\ Transient) do
    %__MODULE__{
      auth: auth,
      write_buffer: WriteBuffer.new(auth),
      transient_lut: transient_lut_name
    }
  end

  @doc """
  Build a permissions struct that can be used to filter changes from the replication stream.

  Arguments:

  - `grants` should be a list of `%SatPerms.Grant{}` protobuf structs
  - `roles` should be a list of `%SatPerms.Role{}` protobuf structs

  """
  @spec update(empty() | t(), SchemaLoader.Version.t(), %SatPerms.Rules{}, [%SatPerms.Role{}]) ::
          t()
  def update(%__MODULE__{} = perms, schema_version, rules, roles) do
    update(perms, schema: schema_version, rules: rules, roles: roles)
  end

  def update(%__MODULE__{} = perms, attrs) when is_list(attrs) do
    perms
    |> update_schema(Keyword.get(attrs, :schema))
    |> update_rules(Keyword.get(attrs, :rules))
    |> update_roles(Keyword.get(attrs, :roles))
    |> rebuild()
  end

  defp update_schema(perms, nil) do
    perms
  end

  defp update_schema(perms, %SchemaLoader.Version{} = schema_version) do
    %{perms | source: %{perms.source | schema: schema_version}}
  end

  defp update_roles(perms, nil) do
    perms
  end

  defp update_roles(perms, roles) when is_list(roles) do
    %{perms | source: %{perms.source | roles: roles}}
  end

  defp update_rules(perms, nil) do
    perms
  end

  defp update_rules(perms, %{grants: _, assigns: _} = rules) do
    %{perms | source: %{perms.source | rules: Map.take(rules, [:grants, :assigns])}}
  end

  defp rebuild(perms) do
    %{roles: roles, rules: rules, schema: schema_version} = perms.source

    assigned_roles = build_roles(roles, perms.auth, rules.assigns)
    scoped_roles = compile_scopes(assigned_roles)
    evaluator = Eval.new(schema_version, perms.auth)
    grants = Enum.map(rules.grants, &Grant.new(&1, evaluator))

    triggers = Trigger.assign_triggers(rules.assigns, schema_version, &trigger_callback/3)

    %{
      perms
      | roles: build_role_grants(assigned_roles, grants),
        scoped_roles: scoped_roles,
        grants: grants,
        scopes: Map.keys(scoped_roles),
        triggers: triggers
    }
  end

  @doc """
  Generate list of `#{Permissions.Role}` structs for all our currently assigned roles plus the
  `Anyone` and `Authenticated` roles (if applicable).
  """
  @spec assigned_roles(t()) :: [Role.t()]
  def assigned_roles(perms) do
    build_roles(perms.source.roles, perms.auth, perms.source.rules.assigns)
  end

  @doc """
  Pass the transaction to the write buffer so it can reset itself when its pending writes have
  completed the loop back from pg and are now in the underlying shape graph.
  """
  @spec receive_transaction(t(), Changes.Transaction.t()) :: t()
  def receive_transaction(perms, %Changes.Transaction{} = tx) do
    Map.update!(perms, :write_buffer, &WriteBuffer.receive_transaction(&1, perms.scopes, tx))
  end

  def build_role_grants(roles, grants) do
    roles
    |> Stream.map(&{&1, Role.matching_grants(&1, grants)})
    |> Stream.reject(fn {_role, grants} -> Enum.empty?(grants) end)
    |> Stream.flat_map(&invert_role_lookup/1)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(&classify_roles/1)
  end

  # For every `{table, privilege}` tuple we have a set of roles that the current user has.
  # If any of those roles are global, then it's equvilent to saying that the user can perform
  # `privilege` on `table` no matter what the scope. This function analyses the roles for a
  # given `{table, privilege}` and makes that test efficient by allowing for prioritising the
  # unscoped grant test.
  defp classify_roles({grant_perm, role_grants}) do
    {scoped, unscoped} =
      Enum.split_with(role_grants, &Role.has_scope?(&1.role))

    {grant_perm, %{scoped: scoped, unscoped: unscoped}}
  end

  # expand the grants into a list of `{{relation, privilege}, %RoleGrant{}}`
  # so that we can create a LUT of table and required privilege to role
  defp invert_role_lookup({role, grants}) do
    Stream.map(grants, fn grant ->
      {{grant.table, grant.privilege}, %RoleGrant{grant: grant, role: role}}
    end)
  end

  defp compile_scopes(roles) do
    roles
    |> Stream.filter(&Role.has_scope?/1)
    |> Stream.map(fn %{scope: {relation, _}} = role -> {relation, role} end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new()
  end

  defp build_roles(roles, auth, assigns) do
    # after a global (rules) permission change, we copy across all users' permissions without
    # modification. if an assign is removed this may leave users with serialised roles with no
    # corresponding assign. so we should filter a user's roles based on the set of existing
    # assigns
    assign_ids = MapSet.new(assigns, & &1.id)

    roles
    |> Stream.filter(&MapSet.member?(assign_ids, &1.assign_id))
    |> Enum.map(&Role.new/1)
    |> add_authenticated(auth)
    |> add_anyone()
  end

  defp add_anyone(roles) do
    [%Role.Anyone{} | roles]
  end

  defp add_authenticated(roles, %Auth{user_id: nil}) do
    roles
  end

  defp add_authenticated(roles, %Auth{user_id: user_id}) do
    [%Role.Authenticated{user_id: user_id} | roles]
  end

  @doc """
  Filters the `changes` in a transaction coming out from postgres to the satellite clients.

  Removes any changes that the client doesn't have permissions to see and a list of
  `%Permissions.MoveOut{}` structs representing changes in the current tx that were made
  unreadable by the actions within that tx.

  E.g. if a transaction contains an update the moves a row out of its previously visible scope
  into a scope that the user doesn't have permissions to read, then this update will itself be
  filtered out by the new permissions scope it represents but included in the list of move-out
  messages.
  """
  @spec filter_read(t(), Graph.impl(), tx()) :: {tx(), [move_out()]}
  def filter_read(%__MODULE__{} = perms, graph, %Changes.Transaction{} = tx) do
    Read.filter_read(perms, graph, tx)
  end

  def validate_read(change, perms, graph, lsn) do
    if role_grants = Map.get(perms.roles, {change.relation, :SELECT}) do
      role_grant_for_change(role_grants, perms, graph, change, lsn, :read)
    end
  end

  @doc """
  Verify that all the writes in a transaction from satellite are allowed given the user's
  permissions.
  """
  @spec validate_write(t(), Graph.impl(), tx()) :: {:ok, t()} | {:error, String.t()}
  def validate_write(%__MODULE__{} = perms, graph, %Changes.Transaction{} = tx) do
    tx.changes
    |> Stream.flat_map(&expand_change(&1, perms, graph))
    |> validate_all_writes(perms, graph, tx.lsn)
  end

  defp expand_change(%Changes.UpdatedRecord{} = change, perms, graph) do
    if modifies_scope_fk?(change, perms, graph) do
      # expand an update that modifies a foreign key into the original update plus a
      # pseudo-update into the scope defined by the updated foreign key
      move = %ScopeMove{
        relation: change.relation,
        record: change.record
      }

      [change, move]
    else
      [change]
    end
  end

  defp expand_change(change, _perms, _graph) do
    [change]
  end

  defp modifies_scope_fk?(change, perms, graph) do
    Enum.any?(perms.scopes, &(!match?([], Graph.modified_fks(graph, &1, change))))
  end

  defp validate_all_writes(changes, perms, graph, lsn) do
    with {:ok, write_buffer} <- validate_writes_with_scope(changes, perms, graph, lsn) do
      {:ok, %{perms | write_buffer: write_buffer}}
    end
  end

  defp validate_writes_with_scope(changes, perms, graph, lsn) do
    %{write_buffer: write_buffer} = perms

    write_buffer = WriteBuffer.with_upstream(write_buffer, graph)

    Enum.reduce_while(
      changes,
      {:ok, write_buffer},
      fn change, {:ok, write_buffer} ->
        case verify_write(change, perms, write_buffer, lsn) do
          {:error, _} = error ->
            {:halt, error}

          %{role: role, grant: grant} = _role_grant ->
            Logger.debug(
              "role #{inspect(role)} grant #{inspect(grant)} gives permission for #{inspect(change)}"
            )

            write_buffer =
              write_buffer
              |> Graph.apply_change(perms.scopes, change)
              |> apply_triggers(change, perms)

            {:cont, {:ok, write_buffer}}
        end
      end
    )
  end

  defp apply_triggers(write_buffer, change, perms) do
    %{auth: %{user_id: user_id}} = perms

    {[^change | effects], _user_id} =
      Trigger.apply(change, perms.triggers, user_id)

    update_transient_roles(effects, perms, write_buffer)
  end

  defp trigger_callback(event, _change, user_id) do
    case event do
      {e, %{user_id: ^user_id} = role} when e in [:insert, :delete] ->
        {[{e, Role.new(role)}], user_id}

      # update nothing to do with us
      {e, _role} when e in [:insert, :delete] ->
        {[], user_id}

      # update keeps role belonging  to our user
      {:update, %{user_id: ^user_id}, %{user_id: ^user_id} = new} ->
        {[{:update, Role.new(new)}], user_id}

      # update has moved role to new user
      {:update, %{user_id: ^user_id} = old, _new} ->
        {[{:delete, Role.new(old)}], user_id}

      # update has moved role us
      {:update, _old, %{user_id: ^user_id} = new} ->
        {[{:insert, Role.new(new)}], user_id}

      # update nothing to do with us
      {:update, _old, _new} ->
        {[], user_id}

      :passthrough ->
        {[], user_id}
    end
  end

  @spec verify_write(change(), t(), Graph.impl(), lsn()) :: RoleGrant.t() | {:error, String.t()}
  defp verify_write(change, perms, graph, lsn) do
    action = required_permission(change)

    role_grant =
      perms.roles
      |> Map.get(action)
      |> include_transient_roles(action, graph)
      |> role_grant_for_change(perms, graph, change, lsn, :write)

    role_grant || permission_error(action)
  end

  defp include_transient_roles(grants, action, write_buffer) do
    WriteBuffer.transient_roles(write_buffer, grants, action)
  end

  @spec role_grant_for_change(nil, t(), Graph.impl(), change(), lsn(), mode()) :: nil
  defp role_grant_for_change(nil, _perms, _scope, _change, _lsn, _mode) do
    nil
  end

  @spec role_grant_for_change(assigned_roles(), t(), Graph.impl(), change(), lsn(), mode()) ::
          RoleGrant.t() | nil
  defp role_grant_for_change(grants, perms, graph, change, lsn, mode) do
    %{unscoped: unscoped_role_grants, scoped: scoped_role_grants} = grants

    Stream.concat([
      unscoped_role_grants,
      scoped_role_grants(scoped_role_grants, perms, graph, change, lsn),
      transient_role_grants(scoped_role_grants, perms, graph, change, lsn)
    ])
    |> find_grant_allowing_change(change, mode)
  end

  defp scoped_role_grants(role_grants, _perms, graph, change, _lsn) do
    Stream.filter(role_grants, fn
      %{role: %{scope: {scope_table, scope_id}}} ->
        # filter out roles whose scope doesn't match
        #   - lookup their root id from the change
        #   - then reject roles that don't match the {table, pk_id}

        change_in_scope?(graph, scope_table, scope_id, change)
    end)
  end

  defp transient_role_grants(role_grants, perms, graph, change, lsn) do
    role_grants
    |> Transient.for_roles(lsn, perms.transient_lut)
    |> Stream.flat_map(fn {role_grant, %Transient{target_relation: relation, target_id: id} = tdp} ->
      if change_in_scope?(graph, relation, id, change) do
        Logger.debug(fn ->
          "Using transient permission #{inspect(tdp)} for #{inspect(change)}"
        end)

        [role_grant]
      else
        []
      end
    end)
  end

  @spec find_grant_allowing_change(Enum.t(), change(), :write) :: RoleGrant.t() | nil
  defp find_grant_allowing_change(role_grants, change, :write) do
    role_grants
    |> Enum.find(fn %{grant: grant} ->
      # ensure that change is compatible with grant conditions
      # note that we're allowing the change if *any* grant allows it
      change_matches_columns?(grant, change) && change_passes_check?(grant, change)
    end)
  end

  @spec find_grant_allowing_change([RoleGrant.t()], change(), :read) ::
          RoleGrant.t() | nil
  defp find_grant_allowing_change(role_grants, change, :read) do
    Enum.find(
      role_grants,
      fn %{grant: grant} -> change_passes_check?(grant, change) end
    )
  end

  defp change_matches_columns?(grant, %Changes.NewRecord{} = insert) do
    Grant.columns_valid?(grant, Map.keys(insert.record))
  end

  defp change_matches_columns?(grant, %Changes.UpdatedRecord{} = update) do
    Grant.columns_valid?(grant, update.changed_columns)
  end

  defp change_matches_columns?(_grant, _deleted_record) do
    true
  end

  defp change_passes_check?(%{check: nil}, _change) do
    true
  end

  defp change_passes_check?(grant, change) do
    Eval.execute!(grant.check, change)
  end

  defp change_in_scope?(graph, scope_relation, scope_id, change) do
    graph
    |> Graph.scope_id(scope_relation, change)
    |> Enum.any?(&(elem(&1, 0) == scope_id))
  end

  defp required_permission(%change{relation: relation}) do
    case change do
      Changes.NewRecord -> {relation, :INSERT}
      Changes.UpdatedRecord -> {relation, :UPDATE}
      Changes.DeletedRecord -> {relation, :DELETE}
      # We treat moving a record between permissions scope as requiring UPDATE permissions on both
      # the original and new permissions scopes.
      ScopeMove -> {relation, :UPDATE}
    end
  end

  defp permission_error({relation, privilege}) do
    action =
      case privilege do
        :INSERT -> "INSERT INTO "
        :DELETE -> "DELETE FROM "
        :UPDATE -> "UPDATE "
      end

    {:error,
     "permissions: user does not have permission to " <>
       action <> Electric.Utils.inspect_relation(relation)}
  end

  def update_transient_roles(role_changes, %__MODULE__{} = perms, write_buffer) do
    WriteBuffer.update_transient_roles(write_buffer, role_changes, perms.grants)
  end
end