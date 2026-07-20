defmodule Colloq.Repo.Migrations.BotsToFullTrust do
  use Ecto.Migration

  @moduledoc """
  Puts every bot account at full trust.

  Trust levels model a person earning standing by participating; a system
  account has nothing to earn, and treating one like a newcomer caused real
  bugs. `sofascorebot` sat at TL1, which put it in the TL0/TL1 spam-detector
  cohort — and because a bot answers the same question with the same words,
  the duplicate-content rule hid its own replies five separate times.

  TL1 also withheld `can_edit_posts` and `can_upload_images` and imposed a
  per-topic tag cap, none of which make sense for a system account.

  Bot creation now stamps TL4 (`Colloq.Bots.create_persona_user/2`,
  `Colloq.Accounts.register_bot/1`), and the BOT flair is what excludes them
  from spam screening and trust promotion. This brings existing rows in line.
  """

  def up do
    execute("UPDATE users SET trust_level = 4 WHERE flair = 'BOT' AND trust_level < 4")
  end

  def down do
    # The prior levels varied per bot (1 and 2 were both in use) and aren't
    # recoverable, so this restores the value bot creation used to assign.
    execute("UPDATE users SET trust_level = 2 WHERE flair = 'BOT'")
  end
end
