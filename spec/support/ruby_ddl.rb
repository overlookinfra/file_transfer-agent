# frozen_string_literal: true

# Loads the Ruby DDL through the MCollective client library once per process,
# with a config whose libdir points at this module's files.
module RubyDDL
  def self.load(agent)
    @loaded ||= {}
    @loaded[agent] ||= begin
      require 'mcollective'
      require 'tempfile'

      config = Tempfile.new(['file_transfer-ddl', '.cfg'])
      config.puts "libdir = #{FILES_DIR}"
      config.puts 'logger_type = console'
      config.puts 'loglevel = error'
      config.close
      MCollective::Config.instance.loadconfig(config.path)
      MCollective::DDL.new(agent, :agent)
    end
  end
end
