defmodule Colloq.RecentLoginsTest do
  use Colloq.DataCase, async: true

  alias Colloq.Accounts

  defp login(user, ip, at) do
    user
    |> Ecto.Changeset.change(last_ip: ip, last_login_at: at)
    |> Repo.update!()
  end

  test "returns most recent logins first" do
    now = DateTime.utc_now()
    a = login(insert(:user), "1.1.1.1", DateTime.add(now, -3600))
    b = login(insert(:user), "2.2.2.2", now)

    assert [first, second | _] = Accounts.recent_logins()
    assert first.id == b.id
    assert second.id == a.id
  end

  test "skips users who never logged in" do
    insert(:user)
    logged_in = login(insert(:user), "1.1.1.1", DateTime.utc_now())

    ids = Accounts.recent_logins() |> Enum.map(& &1.id)
    assert logged_in.id in ids
    assert length(ids) == 1
  end

  test "shared_ip_count reflects how many accounts use that IP" do
    now = DateTime.utc_now()
    login(insert(:user), "9.9.9.9", now)
    login(insert(:user), "9.9.9.9", DateTime.add(now, -60))
    login(insert(:user), "9.9.9.9", DateTime.add(now, -120))
    solo = login(insert(:user), "5.5.5.5", DateTime.add(now, -180))

    by_id = Accounts.recent_logins() |> Map.new(&{&1.id, &1.shared_ip_count})

    # Every account on the shared address reports the full group size.
    shared = for {_id, c} <- by_id, c == 3, do: c
    assert length(shared) == 3
    assert by_id[solo.id] == 1
  end

  test "respects the limit" do
    now = DateTime.utc_now()
    for i <- 1..5, do: login(insert(:user), "1.2.3.#{i}", DateTime.add(now, -i * 60))

    assert length(Accounts.recent_logins(3)) == 3
  end
end
