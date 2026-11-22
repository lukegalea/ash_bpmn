# SPDX-FileCopyrightText: 2026 Luke Galea
# SPDX-License-Identifier: MIT

defmodule AshBpmn.TestRepo.Migrations.CreateTenantTestSubjects do
  @moduledoc """
  A subject that belongs to a tenant, for the tests that a timer's moment is read in the
  instance's tenant and never another's.
  """

  use Ecto.Migration

  def up do
    create table(:tenant_bpmn_test_subjects, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :name, :text, null: false
      add :notice_at, :utc_datetime_usec
      add :organization_id, :uuid, null: false
      add :inserted_at, :utc_datetime_usec, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end
  end

  def down do
    drop table(:tenant_bpmn_test_subjects)
  end
end
