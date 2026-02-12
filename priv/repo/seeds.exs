# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Swarmshield.Repo.insert!(%Swarmshield.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

Code.require_file("seeds/roles_and_permissions.exs", __DIR__)
Code.require_file("seeds/policy_rules.exs", __DIR__)
Code.require_file("seeds/demo_data.exs", __DIR__)
