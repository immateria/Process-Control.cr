module ProcessControl::Spawn
  # Start the Unix target as a new session and process-group leader.
  class Session < Extension
    def name : String
      "spawn.session"
    end
  end
end
