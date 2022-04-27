class MigrateUserID
  include Clear::Migration

  def change(direction)
    direction.up do
      # ensure all user_id fields are prefixed
      execute("UPDATE bookings SET user_id = 'user-' + user_id WHERE user_id NOT LIKE 'user-%'")
      execute("UPDATE bookings SET approver_id = 'user-' + user_id WHERE approver_id IS NOT NULL AND approver_id NOT LIKE 'user-%'")
    end
  end
end
