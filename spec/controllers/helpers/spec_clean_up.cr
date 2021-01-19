Spec.around_each do |spec|
  Clear::SQL.with_savepoint do
    spec.run
    Clear::SQL.rollback
  end
end
