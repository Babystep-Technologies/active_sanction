# typed: strict
# frozen_string_literal: true

require "sorbet-runtime"

module ActiveSanction
  module Parsers
    class XmlRecords
      # The XML libraries this toolkit knows how to drive, and the seam a host
      # application swaps one for another through.
      #
      #   ActiveSanction.configure { |c| c.xml_backend = :nokogiri }
      #
      # ### The contract
      #
      # A backend is a class that answers `.available?` and, per pass, is built
      # with `table:` and the decoded `xml:` and answers two things:
      #
      #   backend.each_record { |record| ... }   # yields XmlRecords::Record
      #   backend.root                           # the document element's attributes
      #
      # It raises XmlRecords::MalformedDocument, with a line where its library
      # supplies one, when the payload stops being XML. Everything else --
      # paths, null resolution, warnings, Enumerable -- lives above it and is
      # written once, so a backend is only ever event translation. Registering
      # another is a public act:
      #
      #   ActiveSanction::Parsers::XmlRecords::Backends.register(:ox, MyOxBackend)
      #
      # ### Why the default is not chosen by what happens to be loaded
      #
      # It would be easy to prefer Nokogiri whenever a host has it, and #15
      # first asked for exactly that. It is the wrong default here. Snapshot
      # checksums a list's parsed content, and a screening decision is supposed
      # to be re-derivable months later in front of an examiner. If the parser
      # is picked by whether Rails happened to load Nokogiri, then two installs
      # of the same gem screening the same file can checksum apart, and the
      # thing that changed is invisible in every artifact either one keeps.
      #
      # So the default is REXML on every installation -- stdlib, no build step,
      # and the same answer everywhere -- and a host that wants libxml2's speed
      # says so out loud, in one line, where a reviewer can see it.
      module Backends
        DEFAULT = T.let(:rexml, Symbol)

        class << self
          extend T::Sig

          # A backend is a class answering the four methods the comment above
          # names, which is why these signatures say `T.untyped` where one
          # goes: registering another is a public act, and an out-of-repo
          # backend is not a subclass of anything here.

          sig { params(name: T.untyped, backend: T.untyped).returns(T.untyped) }
          def register(name, backend)
            registry[name.to_sym] = backend
          end

          sig { params(name: T.untyped).returns(T.untyped) }
          def resolve(name)
            backend = registry.fetch(name.to_sym) do
              raise ArgumentError,
                    "unknown XML backend #{name.inspect}. Registered: #{registry.keys.join(", ")}"
            end
            return backend if backend.available?

            raise ArgumentError, "the #{name.inspect} XML backend cannot run here: #{backend.unavailable_reason}"
          end

          # Every registered backend that could actually run in this process.
          sig { returns(T::Array[Symbol]) }
          def available = registry.select { |_, backend| backend.available? }.keys

          sig { returns(T::Hash[Symbol, T.untyped]) }
          def registry
            @registry ||= T.let({}, T.nilable(T::Hash[Symbol, T.untyped]))
          end

          # An element name with any namespace prefix removed, so a list that
          # grows an `xmlns` next quarter does not stop parsing. The prefix is
          # discarded rather than resolved: none of these publishers uses two
          # namespaces in one document, and an adapter written against
          # `INDIVIDUAL` should not have to be rewritten as `un:INDIVIDUAL`.
          sig { params(name: T.untyped).returns(String) }
          def local_name(name)
            string = name.to_s
            index = string.rindex(":")
            index.nil? ? string : string[(index + 1)..]
          end

          # Attribute keys are stripped the same way, so `xsi:type` is read as
          # `type` and a default-namespaced document reads like a plain one.
          sig { params(attributes: T.untyped).returns(T::Hash[String, String]) }
          def local_attributes(attributes)
            (attributes || {}).to_h { |key, value| [local_name(key), value.to_s] }
          end
        end
      end
    end
  end
end
