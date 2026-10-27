# frozen_string_literal: true

module MCollective
  module Util
    module FileTransfer
      # Checks on strings from nodes and callers before they become part
      # of a local path. Nothing here touches the filesystem.
      module LocalPath
        # A backslash is refused since it separates paths on Windows. Control
        # characters are refused because a terminal acts on them instead of
        # showing them, and the DDL already refuses a newline in a path. On
        # Windows, a device name, with or without an extension, a colon,
        # and a trailing dot or space are refused too.
        #
        # @param name [Object] The string, as a node listed it or as an identity
        # @return [Boolean]
        def self.plain_name?(name)
          return false unless name.is_a?(String) && !name.empty? && name.valid_encoding?
          return false if ['.', '..'].include?(name)
          return false if name.match?(%r{[/\\[:cntrl:]]})
          return true unless Gem.win_platform?

          !name.include?(':') && !name.match?(/\A(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?\z/i) && !name.end_with?('.', ' ')
        end

        # Whether a path a node listed under a directory is plain names joined
        # by slashes, so it can become a local path under the destination.
        #
        # @param path [Object] The relative path, as a node listed it
        # @return [Boolean]
        def self.plain_relative_path?(path)
          path.is_a?(String) && path.valid_encoding? && !path.empty? && path.split('/', -1).all? { |component| plain_name?(component) }
        end

        # The last component of a path on a node. A path starting with a
        # slash is POSIX, where a backslash is part of a name. Any other is a
        # Windows path, split at either separator whatever this host is.
        #
        # @param path [String]
        # @return [String] Empty for a path without a component, such as a root
        def self.last_component(path)
          separator = path.start_with?('/') ? '/' : %r{[/\\]}
          path.split(separator).last.to_s
        end

        # Whether a node's path ends in a separator, read as in last_component.
        #
        # @param path [String]
        # @return [Boolean]
        def self.names_directory?(path)
          path.end_with?('/') || (!path.start_with?('/') && path.end_with?('\\'))
        end

        # A process without a locale tags paths as plain bytes, and Find tags
        # each entry like its root, so such a path is read as UTF-8.
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
