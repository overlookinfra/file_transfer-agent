# frozen_string_literal: true

module MCollective
  module Util
    module FileTransfer
      # The checks on a string from outside before it becomes part of a
      # local path. They say whether an entry name that a node listed or a
      # node identity can be one component of a path on this platform,
      # which component of a path on a node is its last, whether such a
      # path names a directory, and how a path from a process without a
      # locale is read. Nothing else.
      module LocalPath
        # A name Windows treats as a device rather than a file, with or
        # without an extension.
        WINDOWS_RESERVED_NAMES = /\A(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?\z/i

        # A backslash is refused because it is a path separator on Windows,
        # which is also why the DDL refuses it in a name. Control characters,
        # the C1 range included, are refused because the agent refuses them
        # in a name and the DDL refuses a newline in a path, and because a
        # terminal acts on them instead of showing them.
        #
        # @param name [Object] The string, as a node listed it or as an identity
        # @return [Boolean]
        def self.plain_name?(name)
          return false unless name.is_a?(String) && !name.empty? && name.valid_encoding?
          return false if ['.', '..'].include?(name)
          return false if name.match?(%r{[/\\[:cntrl:]]})
          return true unless Gem.win_platform?

          !name.include?(':') && !name.match?(WINDOWS_RESERVED_NAMES) && !name.end_with?('.', ' ')
        end

        # Whether a path that a node listed under a directory is plain names
        # joined by slashes, so it can become a local path under the
        # destination.
        #
        # @param path [Object] The relative path, as a node listed it
        # @return [Boolean]
        def self.plain_relative_path?(path)
          path.is_a?(String) && path.valid_encoding? && !path.empty? && path.split('/', -1).all? { |component| plain_name?(component) }
        end

        # The last component of a path on a node. A path that starts with
        # a slash is a POSIX path, where a backslash is part of a name. Any
        # other path is a Windows one, which Windows splits at either
        # separator, whatever this host is.
        #
        # @param path [String]
        # @return [String] Empty for a path without a component, such as a root
        def self.last_component(path)
          separator = path.start_with?('/') ? '/' : %r{[/\\]}
          path.split(separator).last.to_s
        end

        # Whether a path on a node names a directory by ending in a
        # separator, read the way last_component reads the path.
        #
        # @param path [String]
        # @return [Boolean]
        def self.names_directory?(path)
          path.end_with?('/') || (!path.start_with?('/') && path.end_with?('\\'))
        end

        # A process without a locale tags paths as plain bytes, and Find
        # tags every entry the way that its root is tagged, so a path
        # tagged that way is read as UTF-8.
        #
        # @param path [String]
        # @return [String] The same path tagged UTF-8
        def self.as_utf8(path)
          return path unless [Encoding::BINARY, Encoding::US_ASCII].include?(path.encoding)

          path.dup.force_encoding(Encoding::UTF_8)
        end
      end
    end
  end
end
